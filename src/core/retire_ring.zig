//! 帧回收环：解码表面的**生命周期保险**，也是整个项目里唯一防止 use-after-free
//! 的机制。
//!
//! ## 要解决的问题
//!
//! 解码器交给我们一块表面（macOS 的 `CVPixelBuffer` / `IOSurface`、Windows 的
//! `ID3D11Texture2D`、Linux 的 dma-buf）。我们把它导入 GPU、跑一遍呈现 pass
//! 采样它。**采样命令下发之后，GPU 可能还要过好几帧才真正读完这块内存**。
//! 如果解码后端此时就把表面回收复用，GPU 读到的就是已经被写坏的内存——画面
//! 撕裂、花屏，严重时直接崩。
//!
//! ## 解法：按帧计数，不用平台围栏
//!
//! 刻意**不用**各平台的 GPU fence（Metal 的 `MTLSharedEvent`、D3D12 的
//! `ID3D12Fence`、Vulkan 的 semaphore）。原因是三套 fence 语义各不相同，而它们
//! 要防的误差只有一两帧。这里改用一条有界环：每块表面停满 **N 个已渲染帧**后
//! 才执行释放闭包。N 取值覆盖 Godot 的帧延迟上界即可。
//!
//! 好处是这一层变成**纯逻辑**：不碰 Godot、不碰 RenderingDevice、不碰任何平台
//! 类型，因此可以在任何机器上单测——而它守的是内存安全，最需要被测试锁死。
//!
//! ## 契约
//!
//! - 每块表面恰好停放 N 帧，且**恰好释放一次**；
//! - 容量固定为 N 个槽位，稳定态下呈现路径上**零堆分配**；
//! - 调用时序固定：每渲染帧先 `advance()`，再 `retain()`；
//! - 不可复制（复制会让同一块表面被释放两次）。

const std = @import("std");
const VoidClosure = @import("closure.zig").VoidClosure;

pub fn RetireRing(comptime N: usize) type {
    comptime {
        if (N < 1) @compileError("回收延迟至少为 1 帧");
    }

    return struct {
        const Self = @This();

        // 恰好 N 个槽位：每帧停一块，环写满后第 N 次 advance() 回到的那个槽位，
        // 正是"已经活过 N 帧"的那块表面。
        const capacity: usize = N;

        slots: [capacity]VoidClosure = @splat(.{}),
        head: usize = 0,

        pub const init: Self = .{};

        /// 停车：把这块表面的释放闭包停放 N 帧。每呈现一帧调用一次，
        /// 且必须在同帧的 `advance()` **之后**。
        /// 空的闭包被接受并忽略（例如没有原生表面的测试帧）。
        pub fn retain(self: *Self, release: VoidClosure) void {
            // 当前写槽位就是 head：advance() 已经把它上一轮的内容老化释放掉了，
            // 所以这里必定是空的。
            self.slots[self.head] = release;
        }

        /// 老化一帧：把"已经活过 N 帧"的那个槽位释放掉，恰好一次。
        /// 每渲染帧调用一次，且在同帧的 `retain()` **之前**。
        pub fn advance(self: *Self) void {
            self.head = (self.head + 1) % capacity;
            // head 现在指向 N 帧前填的那个槽位。先释放再被覆盖，保证那块表面
            // 只在 GPU 已经读了 N 帧之后才被放掉。
            self.releaseSlot(self.head);
        }

        /// 立即释放所有仍在停车的表面（停止播放 / 销毁通道时用）。
        /// 按 FIFO（最旧优先）顺序释放，与稳定态老化的顺序一致。
        /// 释放后环内不再持有任何东西；**幂等**。
        pub fn drain(self: *Self) void {
            for (0..capacity) |k| {
                self.releaseSlot((self.head + 1 + k) % capacity);
            }
        }

        /// 当前停着几块表面（测试与上报用）。
        pub fn liveCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (!slot.isEmpty()) n += 1;
            }
            return n;
        }

        /// 配置的延迟帧数 N。
        pub fn latencyFrames() usize {
            return N;
        }

        /// 析构：把还停着的表面全部释放，不留泄漏。
        pub fn deinit(self: *Self) void {
            self.drain();
        }

        fn releaseSlot(self: *Self, i: usize) void {
            const slot = self.slots[i];
            if (slot.isEmpty()) return;
            // 先清空再调用：万一闭包内部又碰到了这个环（重入），
            // 也不会把它自己二次释放。
            self.slots[i] = .{};
            slot.call();
        }
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

/// 统计释放次数用的闭包上下文。
const Counter = struct {
    hits: i32 = 0,

    fn bump(p: ?*anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(p.?));
        self.hits += 1;
    }

    fn hook(self: *Counter) VoidClosure {
        return .{ .ctx = self, .func = bump };
    }
};

test "表面恰好停放 N 帧后释放一次" {
    const N = 3;
    var ring: RetireRing(N) = .init;
    var counter: Counter = .{};

    // 第 0 帧：停车。
    ring.advance();
    ring.retain(counter.hook());
    try std.testing.expectEqual(@as(usize, 1), ring.liveCount());

    // 接下来 N-1 帧它必须还活着。
    var frame: usize = 1;
    while (frame < N) : (frame += 1) {
        ring.advance();
        ring.retain(.{});
        try std.testing.expectEqual(@as(i32, 0), counter.hits);
        try std.testing.expectEqual(@as(usize, 1), ring.liveCount());
    }

    // 停放后的第 N 次 advance()：释放。
    ring.advance();
    try std.testing.expectEqual(@as(i32, 1), counter.hits);
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());

    // 再走很久也不会被二次释放。
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        ring.advance();
        ring.retain(.{});
    }
    try std.testing.expectEqual(@as(i32, 1), counter.hits);
}

test "延迟为 1 时下一帧即释放" {
    var ring: RetireRing(1) = .init;
    var counter: Counter = .{};
    ring.advance();
    ring.retain(counter.hook());
    try std.testing.expectEqual(@as(usize, 1), ring.liveCount());
    ring.advance();
    try std.testing.expectEqual(@as(i32, 1), counter.hits);
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());
}

test "每帧各停一块时按 FIFO 顺序释放，且各恰好一次" {
    const N = 2;
    const frames = 20;
    var ring: RetireRing(N) = .init;

    var order = std.ArrayList(i32).empty;
    defer order.deinit(std.testing.allocator);

    const Seq = struct {
        list: *std.ArrayList(i32),
        value: i32,

        fn release(p: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            self.list.append(std.testing.allocator, self.value) catch unreachable;
        }
    };

    var ctxs: [frames]Seq = undefined;
    var i: i32 = 0;
    while (i < frames) : (i += 1) {
        ctxs[@intCast(i)] = .{ .list = &order, .value = i };
        ring.advance();
        ring.retain(.{ .ctx = &ctxs[@intCast(i)], .func = Seq.release });
    }
    ring.drain();

    try std.testing.expectEqual(@as(usize, frames), order.items.len);
    i = 0;
    while (i < frames) : (i += 1) {
        try std.testing.expectEqual(i, order.items[@intCast(i)]);
    }
}

test "稳定态下同时停放的表面数不超过 N（有界，不随帧数增长）" {
    const N = 4;
    var ring: RetireRing(N) = .init;
    var counters: [8]Counter = @splat(.{});

    var frame: usize = 0;
    while (frame < 200) : (frame += 1) {
        ring.advance();
        ring.retain(counters[frame % counters.len].hook());
        try std.testing.expect(ring.liveCount() <= N);
    }
}

test "drain 释放全部且幂等" {
    var ring: RetireRing(4) = .init;
    var counter: Counter = .{};

    var i: i32 = 0;
    while (i < 3) : (i += 1) {
        ring.advance();
        ring.retain(counter.hook());
    }
    try std.testing.expectEqual(@as(i32, 0), counter.hits);

    ring.drain();
    try std.testing.expectEqual(@as(i32, 3), counter.hits);
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());

    // 第二次 drain 不得重复释放。
    ring.drain();
    try std.testing.expectEqual(@as(i32, 3), counter.hits);
}

test "deinit 释放未到期的表面（没有泄漏）" {
    var counter: Counter = .{};
    {
        var ring: RetireRing(3) = .init;
        ring.advance();
        ring.retain(counter.hook());
        try std.testing.expectEqual(@as(i32, 0), counter.hits);
        ring.deinit();
    }
    try std.testing.expectEqual(@as(i32, 1), counter.hits);
}

test "空闭包被接受且不占槽位" {
    var ring: RetireRing(3) = .init;
    ring.advance();
    ring.retain(.{});
    try std.testing.expectEqual(@as(usize, 0), ring.liveCount());
}

test "latencyFrames 如实报告配置值" {
    try std.testing.expectEqual(@as(usize, 1), RetireRing(1).latencyFrames());
    try std.testing.expectEqual(@as(usize, 5), RetireRing(5).latencyFrames());
}
