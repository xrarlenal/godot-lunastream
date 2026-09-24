//! 有界纹理池：软解帧的 CPU 平面要上传进 RD 纹理，**分配决策**在这一层，
//! 引擎侧只按决策创建 / 上传 / 释放。
//!
//! ## 为什么要有池
//!
//! 若每帧都 `texture_create` + `texture_free`，等于每帧一次 GPU 资源分配：驱动
//! 侧有锁，还会打断命令缓冲的连续性。直播流每秒钟来 25～60 帧，正确形态是
//! **固定一组纹理轮流用**，稳定态零分配。
//!
//! ## 与 0004 回收环的分工
//!
//! 两者互补：回收环管"这块表面什么时候能还"（时间），池管"还给谁"（空间）。
//! 池的容量必须 ≥ 同一时刻可能存活的表面数，也就是
//! `decode_scheduler.requiredPoolDepth(队列可用深度, frame_latency)`——池比实际
//! 需要的小，`acquire` 就会返回 null（背压），帧被丢掉；比需要的大，只是白占
//! 显存。
//!
//! ## 规格（宽高 / 位深）变化
//!
//! 规格一变，已创建的纹理都不能再用（尺寸或像素格式对不上），必须整体作废。
//! 但"作废"不等于"立刻销毁"：消费者手上可能还有引用（回收环里扣着的帧），
//! 所以这里把变化分成三种情形交给调用方处置，见 `SpecChange`。

const std = @import("std");
const testing = std.testing;

/// 一帧 CPU 平面的规格。
pub const Spec = struct {
    width: u32,
    height: u32,
    /// 8 或 10。10 的样值占 16 位容器（右对齐，见 ffsw shim 的约定）。
    bit_depth: u8 = 8,

    pub fn eql(a: Spec, b: Spec) bool {
        return a.width == b.width and a.height == b.height and a.bit_depth == b.bit_depth;
    }

    /// 每个样值的字节数。
    pub fn bytesPerSample(self: Spec) u32 {
        return if (self.bit_depth > 8) 2 else 1;
    }

    /// 亮度平面一行多少字节（**紧凑无填充**，与 shim 的约定一致）。
    pub fn lumaRowBytes(self: Spec) u32 {
        return self.width * self.bytesPerSample();
    }

    /// 交织 CbCr 平面一行多少字节：半分辨率、每像素对两个样值。
    pub fn chromaRowBytes(self: Spec) u32 {
        return ((self.width + 1) / 2) * 2 * self.bytesPerSample();
    }

    pub fn lumaBytes(self: Spec) usize {
        return @as(usize, self.lumaRowBytes()) * self.height;
    }

    pub fn chromaBytes(self: Spec) usize {
        return @as(usize, self.chromaRowBytes()) * ((self.height + 1) / 2);
    }
};

/// 一次取用。`fresh = true` 表示这个槽位还没有纹理，调用方必须先创建再上传。
pub const Lease = struct {
    index: usize,
    fresh: bool,
};

/// 设置规格的结果。调用方据此决定旧纹理怎么处置。
pub const SpecChange = enum {
    /// 规格没变，什么都不用做。
    unchanged,
    /// 规格变了，且当前没有任何槽位在用：旧纹理可以立刻销毁。
    changed_idle,
    /// 规格变了，但有槽位还在用：**不能**立刻销毁，否则消费者手上会变成悬垂
    /// 引用。调用方应当把旧纹理留到"最后一个旧租约归还"或句柄销毁时再释放。
    changed_busy,
};

pub fn TexturePool(comptime capacity: usize) type {
    if (capacity == 0) @compileError("纹理池容量必须 ≥ 1");

    return struct {
        const Self = @This();

        pub const slot_count = capacity;

        /// 当前规格。null 表示还没定过规格（首次 setSpec 会算作变化）。
        spec: ?Spec = null,
        /// 规格代数：每作废一次 +1。引擎侧用它给纹理打标，便于排查"这帧用的是
        /// 哪一代纹理"。
        generation: u32 = 0,
        /// 当前代数下已经创建过纹理的槽位数：`[0, allocated)` 是有效的。
        allocated: usize = 0,
        in_use: [capacity]bool = @splat(false),
        /// 轮转游标：从上次用过的槽位之后开始找，避免固定复用同一个槽位把
        /// 消费者还捏着的那块盖掉。
        cursor: usize = 0,

        /// 声明本帧的规格。返回旧纹理该怎么处置（见 `SpecChange`）。
        pub fn setSpec(self: *Self, spec: Spec) SpecChange {
            if (self.spec) |current| {
                if (current.eql(spec)) return .unchanged;
            }

            const busy = self.inUseCount() > 0;
            self.spec = spec;
            self.generation +%= 1;
            self.allocated = 0;
            self.in_use = @splat(false);
            self.cursor = 0;
            return if (busy) .changed_busy else .changed_idle;
        }

        /// 取一个槽位。已创建过纹理的槽位优先轮转复用；都用着就退而求其次开一个
        /// 新的（`fresh = true`）；连容量都用完了返回 null——这是背压，不是错误。
        pub fn acquire(self: *Self) ?Lease {
            var i: usize = 0;
            while (i < self.allocated) : (i += 1) {
                const index = (self.cursor + i) % self.allocated;
                if (!self.in_use[index]) {
                    self.in_use[index] = true;
                    self.cursor = (index + 1) % capacity;
                    return .{ .index = index, .fresh = false };
                }
            }

            if (self.allocated < capacity) {
                const index = self.allocated;
                self.allocated += 1;
                self.in_use[index] = true;
                self.cursor = (index + 1) % capacity;
                return .{ .index = index, .fresh = true };
            }
            return null;
        }

        /// 归还槽位。幂等：重复归还、越界归都是空操作（越界会返回 false，
        /// 供调用方记账——它意味着有代码路径把别人的槽位还回来了）。
        pub fn release(self: *Self, index: usize) bool {
            if (index >= capacity) return false;
            self.in_use[index] = false;
            return true;
        }

        pub fn inUseCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.in_use) |used| {
                if (used) n += 1;
            }
            return n;
        }

        /// 已经创建过纹理的槽位数（= 引擎侧持有多少个纹理对）。
        pub fn allocatedCount(self: *const Self) usize {
            return self.allocated;
        }
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const TestPool = TexturePool(4);
const spec8: Spec = .{ .width = 640, .height = 360, .bit_depth = 8 };
const spec10: Spec = .{ .width = 640, .height = 360, .bit_depth = 10 };

test "首次取用要求新建纹理，之后同一槽位复用不再新建" {
    var pool: TestPool = .{};
    try testing.expectEqual(SpecChange.changed_idle, pool.setSpec(spec8));

    const first = pool.acquire().?;
    try testing.expect(first.fresh);
    try testing.expectEqual(@as(usize, 1), pool.allocatedCount());
    try testing.expect(pool.release(first.index));

    const second = pool.acquire().?;
    try testing.expect(!second.fresh);
    try testing.expectEqual(first.index, second.index);
    try testing.expectEqual(@as(usize, 1), pool.allocatedCount());
}

test "连续取用会轮转到不同槽位（不是反复用同一个）" {
    var pool: TestPool = .{};
    _ = pool.setSpec(spec8);

    const a = pool.acquire().?;
    const b = pool.acquire().?;
    const c = pool.acquire().?;
    try testing.expect(a.index != b.index);
    try testing.expect(b.index != c.index);
    try testing.expect(a.index != c.index);
    try testing.expect(a.fresh and b.fresh and c.fresh);
    try testing.expectEqual(@as(usize, 3), pool.allocatedCount());
    try testing.expectEqual(@as(usize, 3), pool.inUseCount());
}

test "容量用尽时返回 null（背压），归还后立刻恢复" {
    var pool: TestPool = .{};
    _ = pool.setSpec(spec8);

    var leases: [TestPool.slot_count]Lease = undefined;
    for (&leases) |*lease| lease.* = pool.acquire().?;
    try testing.expectEqual(@as(?Lease, null), pool.acquire());
    try testing.expectEqual(@as(usize, TestPool.slot_count), pool.inUseCount());

    try testing.expect(pool.release(leases[0].index));
    const again = pool.acquire().?;
    try testing.expectEqual(leases[0].index, again.index);
    try testing.expect(!again.fresh);
}

test "稳态：跑很多轮取用/归还，创建过的纹理数不超过容量" {
    var pool: TestPool = .{};
    _ = pool.setSpec(spec8);

    var created: usize = 0;
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        // 每轮最多同时持有两个（模拟"队列 + 呈现中"），与真实节奏同形。
        const a = pool.acquire().?;
        if (a.fresh) created += 1;
        const b = pool.acquire().?;
        if (b.fresh) created += 1;
        _ = pool.release(a.index);
        _ = pool.release(b.index);
    }
    try testing.expect(created <= TestPool.slot_count);
    try testing.expectEqual(@as(usize, 2), pool.allocatedCount());
    try testing.expectEqual(@as(usize, 0), pool.inUseCount());
}

test "重复归还与越界归还都是空操作（越界会被报出来）" {
    var pool: TestPool = .{};
    _ = pool.setSpec(spec8);

    const lease = pool.acquire().?;
    try testing.expect(pool.release(lease.index));
    try testing.expect(pool.release(lease.index)); // 幂等
    try testing.expectEqual(@as(usize, 0), pool.inUseCount());
    try testing.expect(!pool.release(TestPool.slot_count + 3));
}

test "规格未变时不动槽位" {
    var pool: TestPool = .{};
    _ = pool.setSpec(spec8);
    const lease = pool.acquire().?;
    try testing.expectEqual(SpecChange.unchanged, pool.setSpec(.{ .width = 640, .height = 360 }));
    try testing.expectEqual(@as(usize, 1), pool.allocatedCount());
    try testing.expectEqual(@as(usize, 1), pool.inUseCount());
    _ = pool.release(lease.index);
}

test "位深变化也算规格变化（8-bit 的纹理不能被 10-bit 帧复用）" {
    var pool: TestPool = .{};
    _ = pool.setSpec(spec8);
    _ = pool.acquire().?;

    try testing.expectEqual(SpecChange.changed_busy, pool.setSpec(spec10));
    try testing.expectEqual(@as(usize, 0), pool.allocatedCount());
    try testing.expectEqual(@as(usize, 0), pool.inUseCount());
    try testing.expectEqual(@as(u32, 2), pool.generation);

    const fresh = pool.acquire().?;
    try testing.expect(fresh.fresh);
}

test "空闲时改变规格：调用方可以立刻销毁旧纹理" {
    var pool: TestPool = .{};
    _ = pool.setSpec(spec8);
    const lease = pool.acquire().?;
    _ = pool.release(lease.index);

    try testing.expectEqual(SpecChange.changed_idle, pool.setSpec(spec10));
}

test "平面尺寸算术：8/10 位都是紧凑布局，色度半分辨率" {
    try testing.expectEqual(@as(u32, 640), spec8.lumaRowBytes());
    try testing.expectEqual(@as(usize, 640 * 360), spec8.lumaBytes());
    try testing.expectEqual(@as(u32, 640), spec8.chromaRowBytes());
    try testing.expectEqual(@as(usize, 640 * 180), spec8.chromaBytes());

    try testing.expectEqual(@as(u32, 1280), spec10.lumaRowBytes());
    try testing.expectEqual(@as(usize, 1280 * 360), spec10.lumaBytes());
    try testing.expectEqual(@as(u32, 1280), spec10.chromaRowBytes());
    try testing.expectEqual(@as(usize, 1280 * 180), spec10.chromaBytes());
}

test "奇数尺寸时色度行按像素对向上取整" {
    const odd: Spec = .{ .width = 641, .height = 361, .bit_depth = 8 };
    try testing.expectEqual(@as(u32, 642), odd.chromaRowBytes());
    try testing.expectEqual(@as(usize, 642 * 181), odd.chromaBytes());
}
