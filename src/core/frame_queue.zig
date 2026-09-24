//! 有界帧队列：单生产者 / 单消费者的无锁环形队列。
//!
//! 用途：解码线程（生产者）把解好的帧交给呈现线程（消费者）。这条通道必须是
//! 有界的——无界队列在弱网下会无限堆积，把"丢帧"变成"内存增长 + 延迟越来越
//! 大"，而直播流唯一正确的背压就是丢掉最旧的帧。
//!
//! ## 契约
//!
//! - **恰好一个线程调用 `push()`，恰好一个线程调用 `pop()` / `peek()`**；
//! - `push()` 永不阻塞：队列满时返回 `false`，由生产者决定丢谁；
//! - `pop()` 在空队列上返回 `null`；
//! - `capacity` 必须是 2 的幂且 ≥ 2；
//! - **可用槽位是 `capacity - 1`**，空与满靠这两个下标区分，因此不引入共享计数器。
//!
//! ## 内存模型
//!
//! 生产者的 `tail.store(.release)` 与消费者的 `tail.load(.acquire)` 配对，
//! 保证写进槽位的元素对消费者可见；反向的 `head` 同理。读自己的下标用
//! `.monotonic` 就够了——那个下标只有本线程会写。两个下标各自独占一条
//! cache line，避免生产者与消费者之间的伪共享。

const std = @import("std");

pub fn FrameQueue(comptime T: type, comptime capacity: usize) type {
    comptime {
        if (capacity < 2) @compileError("容量至少为 2（1 个槽位无法区分空与满）");
        if (!std.math.isPowerOfTwo(capacity)) @compileError("容量必须是 2 的幂");
    }

    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        /// 实际可存放的元素个数。留一个空槽用于区分"空"与"满"。
        pub const usable_capacity: usize = capacity - 1;

        head: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0),
        storage: [capacity]T = undefined,

        pub const init: Self = .{};

        fn nextIndex(index: usize) usize {
            return (index + 1) & mask;
        }

        /// 生产者入队。满时返回 false，**不覆盖旧元素**——丢谁由调用方决定，
        /// 因为"丢最旧的"还是"丢最新的"取决于场景，队列不该替它做主。
        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.load(.monotonic);
            const next = nextIndex(tail);
            if (next == self.head.load(.acquire)) {
                @branchHint(.unlikely);
                return false;
            }
            self.storage[tail] = item;
            self.tail.store(next, .release);
            return true;
        }

        /// 消费者取出队首元素。空队列返回 null。
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            if (head == self.tail.load(.acquire)) return null;
            const item = self.storage[head];
            self.head.store(nextIndex(head), .release);
            return item;
        }

        /// 窥视队首但不取出。空队列返回 null。
        ///
        /// 返回的指针在下一次触碰该槽位的 `push()` / `pop()` 之前有效：
        /// 需要什么就读什么，然后 `pop()`。仅限消费者线程调用。
        pub fn peek(self: *Self) ?*T {
            const head = self.head.load(.monotonic);
            if (head == self.tail.load(.acquire)) return null;
            return &self.storage[head];
        }

        /// 窥视队首之后的下一个元素（即"若现在 pop，接下来会拿到的那个"），
        /// 用于在取帧前先看一眼下一帧的时间戳。元素不足两个时返回 null。
        pub fn peekNext(self: *Self) ?*T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null;
            const second = nextIndex(head);
            if (second == tail) return null;
            return &self.storage[second];
        }

        /// 队列是否为空。仅消费者线程调用时可靠。
        pub fn empty(self: *const Self) bool {
            return self.head.load(.acquire) == self.tail.load(.acquire);
        }

        /// 队列是否已满（`push()` 会失败）。仅生产者线程调用时可靠。
        pub fn full(self: *const Self) bool {
            const tail = self.tail.load(.monotonic);
            return nextIndex(tail) == self.head.load(.acquire);
        }
    };
}

// ---------------------------------------------------------------------------
// 测试：单线程语义
// ---------------------------------------------------------------------------

/// 队列的真实载荷形状：带时间戳与序号的帧。
const FakeFrame = struct {
    pts: f64,
    seq: u32,
};

test "可用槽位是容量减一" {
    try std.testing.expectEqual(@as(usize, 3), FrameQueue(i32, 4).usable_capacity);
    try std.testing.expectEqual(@as(usize, 63), FrameQueue(i32, 64).usable_capacity);
}

test "初始状态为空且未满" {
    var q: FrameQueue(i32, 4) = .init;
    try std.testing.expect(q.empty());
    try std.testing.expect(!q.full());
    try std.testing.expectEqual(@as(?i32, null), q.pop());
}

test "push 与 pop 往返同一个值" {
    var q: FrameQueue(i32, 4) = .init;
    try std.testing.expect(q.push(42));
    try std.testing.expectEqual(@as(?i32, 42), q.pop());
    try std.testing.expect(q.empty());
}

test "保持先进先出顺序" {
    var q: FrameQueue(u32, 8) = .init;
    var i: u32 = 0;
    while (i < FrameQueue(u32, 8).usable_capacity) : (i += 1) {
        try std.testing.expect(q.push(i));
    }
    i = 0;
    while (i < FrameQueue(u32, 8).usable_capacity) : (i += 1) {
        try std.testing.expectEqual(@as(?u32, i), q.pop());
    }
}

test "承载真实载荷形状（带时间戳的帧）且字段不丢失" {
    var q: FrameQueue(FakeFrame, 8) = .init;
    try std.testing.expect(q.push(.{ .pts = 1.5, .seq = 7 }));
    try std.testing.expect(q.push(.{ .pts = 1.5417, .seq = 8 }));
    const first = q.pop().?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), first.pts, 1e-9);
    try std.testing.expectEqual(@as(u32, 7), first.seq);
    const second = q.pop().?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.5417), second.pts, 1e-9);
    try std.testing.expectEqual(@as(u32, 8), second.seq);
}

test "pop 空队列返回 null" {
    var q: FrameQueue(i32, 4) = .init;
    try std.testing.expectEqual(@as(?i32, null), q.pop());
    try std.testing.expectEqual(@as(?i32, null), q.pop());
}

test "peek 不消费，peekNext 在元素不足时返回 null" {
    var q: FrameQueue(i32, 8) = .init;
    try std.testing.expectEqual(@as(?*i32, null), q.peek());
    try std.testing.expectEqual(@as(?*i32, null), q.peekNext());

    try std.testing.expect(q.push(10));
    try std.testing.expectEqual(@as(i32, 10), q.peek().?.*);
    try std.testing.expectEqual(@as(?*i32, null), q.peekNext());

    try std.testing.expect(q.push(20));
    try std.testing.expectEqual(@as(i32, 10), q.peek().?.*);
    try std.testing.expectEqual(@as(i32, 20), q.peekNext().?.*);
    // peek 两次之后队列内容不变
    try std.testing.expect(!q.empty());
    try std.testing.expectEqual(@as(?i32, 10), q.pop());
    try std.testing.expectEqual(@as(i32, 20), q.peek().?.*);
    try std.testing.expectEqual(@as(?*i32, null), q.peekNext());
}

test "满时 push 失败且不会覆盖已有元素" {
    var q: FrameQueue(i32, 4) = .init; // 可用 3 个槽位
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expect(q.push(3));
    try std.testing.expect(q.full());
    try std.testing.expect(!q.push(4));
    // 失败的那次不能污染队列：三个元素仍按原序可读
    try std.testing.expectEqual(@as(?i32, 1), q.pop());
    try std.testing.expectEqual(@as(?i32, 2), q.pop());
    try std.testing.expectEqual(@as(?i32, 3), q.pop());
}

test "pop 腾出空间后可以继续 push" {
    var q: FrameQueue(i32, 4) = .init;
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expect(q.push(3));
    try std.testing.expect(q.full());
    _ = q.pop();
    try std.testing.expect(!q.full());
    try std.testing.expect(q.push(99));
    try std.testing.expect(q.full());
}

test "环形回绕多轮后顺序仍然正确" {
    var q: FrameQueue(u32, 4) = .init; // 可用 3 个槽位
    var round: u32 = 0;
    while (round < 5) : (round += 1) {
        var i: u32 = 0;
        while (i < FrameQueue(u32, 4).usable_capacity) : (i += 1) {
            try std.testing.expect(q.push(round * 10 + i));
        }
        i = 0;
        while (i < FrameQueue(u32, 4).usable_capacity) : (i += 1) {
            try std.testing.expectEqual(@as(?u32, round * 10 + i), q.pop());
        }
        try std.testing.expect(q.empty());
    }
}

test "队列移交堆分配的所有权" {
    var q: FrameQueue(?*i32, 4) = .init;
    const p = try std.testing.allocator.create(i32);
    p.* = 7;
    try std.testing.expect(q.push(p));
    const taken = q.pop().?;
    try std.testing.expectEqual(@as(i32, 7), taken.?.*);
    std.testing.allocator.destroy(taken.?);
}

// ---------------------------------------------------------------------------
// 测试：SPSC 并发
// ---------------------------------------------------------------------------

test "SPSC 并发下不丢帧、不重帧、总量守恒" {
    const total: u32 = 50_000;
    var q: FrameQueue(u32, 64) = .init;

    var consumed_count = std.atomic.Value(u32).init(0);
    var produced_sum = std.atomic.Value(u64).init(0);
    var consumed_sum = std.atomic.Value(u64).init(0);

    const Ctx = struct {
        q: *FrameQueue(u32, 64),
        consumed_count: *std.atomic.Value(u32),
        produced_sum: *std.atomic.Value(u64),
        consumed_sum: *std.atomic.Value(u64),
        total: u32,

        fn producer(ctx: @This()) void {
            var i: u32 = 0;
            while (i < ctx.total) : (i += 1) {
                while (!ctx.q.push(i)) {
                    // 队列满：按生产者的背压策略忙等让出 CPU。
                    std.Thread.yield() catch {};
                }
                _ = ctx.produced_sum.fetchAdd(i, .monotonic);
            }
        }

        fn consumer(ctx: @This()) void {
            while (ctx.consumed_count.load(.monotonic) < ctx.total) {
                if (ctx.q.pop()) |v| {
                    _ = ctx.consumed_sum.fetchAdd(v, .monotonic);
                    _ = ctx.consumed_count.fetchAdd(1, .monotonic);
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    const ctx: Ctx = .{
        .q = &q,
        .consumed_count = &consumed_count,
        .produced_sum = &produced_sum,
        .consumed_sum = &consumed_sum,
        .total = total,
    };

    const producer_thread = try std.Thread.spawn(.{}, Ctx.producer, .{ctx});
    const consumer_thread = try std.Thread.spawn(.{}, Ctx.consumer, .{ctx});
    producer_thread.join();
    consumer_thread.join();

    // 三个不变量：全部消费、数量守恒、序号的算术和守恒（后者同时排除
    // "丢掉一个又重复一个"这种数量相同但内容错位的失败模式）。
    try std.testing.expectEqual(total, consumed_count.load(.monotonic));
    try std.testing.expectEqual(produced_sum.load(.monotonic), consumed_sum.load(.monotonic));
    try std.testing.expect(q.empty());
}
