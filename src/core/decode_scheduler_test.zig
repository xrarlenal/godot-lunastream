//! 解码调度器的测试。全部用假后端，不需要 GPU、不需要摄像头、不需要 Godot。
//!
//! 这一层守的是并发契约，所以测试重点不是"能不能出帧"，而是：
//!   * 每路流**串行**解码（假后端记录并发进入次数，必须始终为 1）；
//!   * 多路流共享**固定数量**的 worker（加流不加线程）；
//!   * 注销**阻塞到在途的一轮结束**，并释放所有仍缓冲的帧；
//!   * 同步调试模式不创建线程，但仍然遵守同一套契约。

const std = @import("std");
const testing = std.testing;

const sys_clock = @import("sys_clock.zig");
const backend_mod = @import("backend.zig");
const sched_mod = @import("decode_scheduler.zig");

const Backend = backend_mod.Backend;
const VideoFrame = backend_mod.VideoFrame;
const DecodeScheduler = sched_mod.DecodeScheduler;
const StreamHandle = sched_mod.StreamHandle;

/// 假后端：按 PTS 递增吐固定数量的帧，并记录并发进入次数与释放次数。
const FakeBackend = struct {
    total_frames: i32,
    emitted: i32 = 0,
    closed: bool = false,
    freed: bool = false,
    /// 重连用例要看"后端到底被开过/关过几次"。
    opens: i32 = 0,
    closes: i32 = 0,

    /// 每次 `next_video_frame` 的进入/离开并发计数。每路流串行的话，
    /// 最大值必须恒为 1。
    in_flight: std.atomic.Value(i32) = .init(0),
    max_in_flight: std.atomic.Value(i32) = .init(0),

    /// 帧被 release 的次数（帧是队列里的副本，所以闭包指向这里）。
    releases: std.atomic.Value(i32) = .init(0),

    fn bump(p: ?*anyopaque) void {
        const counter: *std.atomic.Value(i32) = @ptrCast(@alignCast(p.?));
        _ = counter.fetchAdd(1, .monotonic);
    }

    fn open(p: *anyopaque, url: []const u8) bool {
        const self: *@This() = @ptrCast(@alignCast(p));
        self.opens += 1;
        // 真实后端重开之后是从头开始的一路流，所以计数器也要归零——否则
        // "重开能不能重新出帧"这件事在假后端上根本测不出来。
        self.emitted = 0;
        return url.len > 0;
    }
    fn close(p: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(p));
        self.closed = true;
        self.closes += 1;
    }
    fn deinit(p: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(p));
        self.freed = true;
    }
    fn duration(_: *anyopaque) f64 {
        return 0.0;
    }
    fn width(_: *anyopaque) i32 {
        return 960;
    }
    fn height(_: *anyopaque) i32 {
        return 540;
    }
    fn colorimetryOf(_: *anyopaque) backend_mod.Colorimetry {
        return backend_mod.Colorimetry.bt709_defaults;
    }
    fn next(p: *anyopaque) ?VideoFrame {
        const self: *@This() = @ptrCast(@alignCast(p));

        const now = self.in_flight.fetchAdd(1, .acq_rel) + 1;
        defer _ = self.in_flight.fetchSub(1, .acq_rel);
        // 记录见过的最大并发。用 CAS 保证只增不减。
        var seen = self.max_in_flight.load(.monotonic);
        while (now > seen) {
            if (self.max_in_flight.cmpxchgWeak(seen, now, .monotonic, .monotonic)) |actual| {
                seen = actual;
            } else break;
        }

        if (self.emitted >= self.total_frames) return null;
        const pts: f64 = @as(f64, @floatFromInt(self.emitted)) / 30.0;
        self.emitted += 1;
        return .{
            .pts_seconds = pts,
            .width = 960,
            .height = 540,
            .pixel_format = .nv12,
            .release_hook = .{ .ctx = &self.releases, .func = bump },
        };
    }

    const vtable: Backend.VTable = .{
        .open = open,
        .close = close,
        .deinit = deinit,
        .duration_seconds = duration,
        .video_width = width,
        .video_height = height,
        .colorimetry = colorimetryOf,
        .next_video_frame = next,
    };

    fn backend(self: *@This()) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// 在超时前尽量取帧，取到就立刻释放。返回实际取到的帧数。
fn drainUpTo(sched: *DecodeScheduler, stream: StreamHandle, want: usize, timeout_ms: i64) usize {
    var got: usize = 0;
    const deadline = sys_clock.milliTimestamp() + timeout_ms;
    while (got < want and sys_clock.milliTimestamp() < deadline) {
        if (sched.nextFrame(stream)) |f| {
            f.release();
            got += 1;
        } else {
            sys_clock.sleep(1 * std.time.ns_per_ms);
        }
    }
    return got;
}

test "requiredPoolDepth = 队列可用深度 + 在呈现的 1 帧 + 回收环扣住的帧" {
    try testing.expectEqual(@as(usize, 3), sched_mod.requiredPoolDepth(0, 2));
    try testing.expectEqual(@as(usize, 8), sched_mod.requiredPoolDepth(5, 2));
    try testing.expectEqual(@as(usize, 10), sched_mod.requiredPoolDepth(7, 2));
}

test "worker 数量被钳到至少 1，并如实上报" {
    const s = try DecodeScheduler.init(testing.allocator, 0, false);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.workerCount());
    try testing.expect(!s.isSynchronous());
}

test "注册后能按顺序取到帧（PTS 单调递增）" {
    var fake = FakeBackend{ .total_frames = 5 };
    const s = try DecodeScheduler.init(testing.allocator, 1, false);
    defer s.deinit();

    const stream = try s.registerStream(fake.backend());
    try testing.expectEqual(@as(usize, 5), drainUpTo(s, stream, 5, 2000));
    try testing.expect(fake.emitted >= 5);

    s.unregisterStream(stream);
}

test "每路流串行解码：假后端观测到的最大并发恒为 1" {
    var fake = FakeBackend{ .total_frames = 500 };
    const s = try DecodeScheduler.init(testing.allocator, 3, false);
    defer s.deinit();

    const stream = try s.registerStream(fake.backend());
    _ = drainUpTo(s, stream, 20, 500);
    // 再给池子一点时间在后台反复泵。
    sys_clock.sleep(50 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i32, 1), fake.max_in_flight.load(.monotonic));

    s.unregisterStream(stream);
}

test "取走一帧会触发补货，直到后端的帧被取完" {
    var fake = FakeBackend{ .total_frames = 12 };
    const s = try DecodeScheduler.init(testing.allocator, 1, false);
    defer s.deinit();

    const stream = try s.registerStream(fake.backend());
    // 队列容量只有 7 个可用槽位，12 帧必须靠"取走→补货"才能全部拿到。
    try testing.expectEqual(@as(usize, 12), drainUpTo(s, stream, 12, 3000));

    s.unregisterStream(stream);
}

test "后端报 EOS 之后进入 atEnd，且不再请求新帧" {
    var fake = FakeBackend{ .total_frames = 3 };
    const s = try DecodeScheduler.init(testing.allocator, 1, false);
    defer s.deinit();

    const stream = try s.registerStream(fake.backend());
    try testing.expectEqual(@as(usize, 3), drainUpTo(s, stream, 3, 2000));

    const deadline = sys_clock.milliTimestamp() + 1000;
    while (!s.atEnd(stream) and sys_clock.milliTimestamp() < deadline) {
        sys_clock.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(s.atEnd(stream));
    // EOS 之后不应再把后端吐空转到底（帧数不会超过总数）。
    sys_clock.sleep(20 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i32, 3), fake.emitted);

    s.unregisterStream(stream);
}

test "多路流共享同一个池：加流不加线程" {
    var fake_a = FakeBackend{ .total_frames = 20 };
    var fake_b = FakeBackend{ .total_frames = 20 };
    const s = try DecodeScheduler.init(testing.allocator, 2, false);
    defer s.deinit();
    const workers_before = s.workerCount();

    const a = try s.registerStream(fake_a.backend());
    const b = try s.registerStream(fake_b.backend());
    try testing.expectEqual(workers_before, s.workerCount());

    try testing.expect(drainUpTo(s, a, 5, 2000) == 5);
    try testing.expect(drainUpTo(s, b, 5, 2000) == 5);

    s.unregisterStream(a);
    s.unregisterStream(b);
}

test "注销会释放队列里所有缓冲帧并关闭后端" {
    var fake = FakeBackend{ .total_frames = 1000 };
    const s = try DecodeScheduler.init(testing.allocator, 1, false);
    defer s.deinit();

    const stream = try s.registerStream(fake.backend());
    // 等池子把队列填满（容量 8 → 可用 7），期间一帧都不取。
    sys_clock.sleep(60 * std.time.ns_per_ms);
    try testing.expect(fake.emitted >= 1);

    s.unregisterStream(stream);

    // 队列里剩下的帧必须被逐个释放，后端必须被关闭并释放。
    try testing.expect(fake.releases.load(.monotonic) >= 1);
    try testing.expect(fake.closed);
    try testing.expect(fake.freed);
}

test "deinit 会清理没有注销的流（不给调用方留泄漏）" {
    var fake = FakeBackend{ .total_frames = 1000 };
    const s = try DecodeScheduler.init(testing.allocator, 1, false);

    _ = try s.registerStream(fake.backend());
    sys_clock.sleep(40 * std.time.ns_per_ms);

    s.deinit();
    try testing.expect(fake.closed);
    try testing.expect(fake.freed);
}

test "同步调试模式不创建线程，但仍然遵守契约并能出帧" {
    var fake = FakeBackend{ .total_frames = 4 };
    const s = try DecodeScheduler.init(testing.allocator, 3, true);
    defer s.deinit();

    try testing.expect(s.isSynchronous());
    try testing.expectEqual(@as(usize, 0), s.workerCount());

    const stream = try s.registerStream(fake.backend());
    try testing.expectEqual(@as(usize, 4), drainUpTo(s, stream, 4, 1000));
    try testing.expectEqual(@as(i32, 1), fake.max_in_flight.load(.monotonic));

    s.unregisterStream(stream);
}

test "peekHeadPts / peekNextPts 与队列内容一致且不消费" {
    var fake = FakeBackend{ .total_frames = 4 };
    const s = try DecodeScheduler.init(testing.allocator, 1, false);
    defer s.deinit();

    const stream = try s.registerStream(fake.backend());
    try testing.expectEqual(@as(usize, 4), drainUpTo(s, stream, 4, 2000));

    // 队列已被取空：两个 peek 都应为 null。
    try testing.expect(s.peekHeadPts(stream) == null);
    try testing.expect(s.peekNextPts(stream) == null);
    s.unregisterStream(stream);
}

test "peek 拿到的是队首与第二个元素，且不会把它们取走" {
    var fake = FakeBackend{ .total_frames = 6 };
    const s = try DecodeScheduler.init(testing.allocator, 1, false);
    defer s.deinit();

    const stream = try s.registerStream(fake.backend());
    // 等至少两帧就位。
    const deadline = sys_clock.milliTimestamp() + 2000;
    while (s.peekNextPts(stream) == null and sys_clock.milliTimestamp() < deadline) {
        sys_clock.sleep(1 * std.time.ns_per_ms);
    }

    const head = s.peekHeadPts(stream).?;
    const next = s.peekNextPts(stream).?;
    try testing.expectEqual(@as(f64, 0.0), head);
    try testing.expect(next > head);

    // peek 之后队首不变。
    try testing.expectEqual(head, s.peekHeadPts(stream).?);

    s.unregisterStream(stream);
}

test "入队单调性守卫：PTS 回退时置位一次性告警闩锁" {
    var stream = sched_mod.DecodeStream{};

    sched_mod.checkEnqueueMonotonic(&stream, 1.0);
    try testing.expect(!stream.pts_regressed_warned);

    sched_mod.checkEnqueueMonotonic(&stream, 1.5);
    try testing.expect(!stream.pts_regressed_warned);

    // 回退：闩锁置位。
    sched_mod.checkEnqueueMonotonic(&stream, 1.2);
    try testing.expect(stream.pts_regressed_warned);
    try testing.expectEqual(@as(f64, 1.2), stream.last_enqueued_pts.?);

    // 基线继续更新，但闩锁不会被重复触发（每条流只告警一次）。
    sched_mod.checkEnqueueMonotonic(&stream, 1.1);
    try testing.expect(stream.pts_regressed_warned);
    try testing.expectEqual(@as(f64, 1.1), stream.last_enqueued_pts.?);
}

// ---------------------------------------------------------------------------
// 0019：断流重连的"重开请求"
// ---------------------------------------------------------------------------

test "重开请求登记后，由持有租约的线程执行 close + open（同步模式可确定性验证）" {
    // 同步模式：执行者就是调用线程，测试因此没有时序不确定性。
    const sched = try DecodeScheduler.init(testing.allocator, 1, true);
    defer sched.deinit();

    var fake: FakeBackend = .{ .total_frames = 3 };
    const stream = try sched.registerStream(fake.backend());
    // 注册**不**负责开源：按契约，调用方先 open 再把已经开好的后端交给调度器
    //（播放实现就是这么做的）。所以此时 opens 仍是 0。
    try testing.expectEqual(@as(i32, 0), fake.opens);

    // 先把三帧取干净：队列空且后端 EOS。
    var taken: i32 = 0;
    while (sched.nextFrame(stream)) |frame| {
        frame.release();
        taken += 1;
    }
    try testing.expectEqual(@as(i32, 3), taken);

    // 请求重开：同步模式下它会就地泵一轮，于是后端应当看到一次 close + 一次 open。
    try sched.requestReopen(stream, "rtsp://camera/again");
    try testing.expectEqual(@as(i32, 1), fake.closes);
    try testing.expectEqual(@as(i32, 1), fake.opens);
}

test "重开请求会清掉 eos（否则队列空了会被当成流到头）" {
    const sched = try DecodeScheduler.init(testing.allocator, 1, true);
    defer sched.deinit();

    // 重开之后假后端会从头再吐一遍（open 里把 emitted 归零），所以这里给两帧，
    // 才能验到"重开后队列里又有东西、不再被判成流到头"。
    var fake: FakeBackend = .{ .total_frames = 2 };
    const stream = try sched.registerStream(fake.backend());
    // 把这两帧取干净 → 应当处于 EOS。
    while (sched.nextFrame(stream)) |frame| frame.release();
    try testing.expect(sched.atEnd(stream));

    try sched.requestReopen(stream, "udp://127.0.0.1:1234");
    try testing.expect(!sched.atEnd(stream));
}

test "连续重开只保留最后一次的路径（不泄漏前一次的副本）" {
    const sched = try DecodeScheduler.init(testing.allocator, 1, true);
    defer sched.deinit();

    var fake: FakeBackend = .{ .total_frames = 1 };
    const stream = try sched.registerStream(fake.backend());
    try sched.requestReopen(stream, "rtsp://first");
    try sched.requestReopen(stream, "rtsp://second");
    // 两次都执行过（同步模式下每次 requestReopen 都会泵一轮）。
    try testing.expectEqual(@as(i32, 2), fake.opens);
    try testing.expectEqual(@as(i32, 2), fake.closes);
    // 用测试分配器：泄漏一处都会被 testing.allocator 在结束时抓到。
}
