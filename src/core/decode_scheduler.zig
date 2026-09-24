//! 有界共享 worker 池：所有流共用一个固定大小的线程池，把解码提前做在呈现之前。
//!
//! ## 要解决的问题
//!
//! 一个场景里可能挂着十几路视频。每路开一个解码线程不可扩展；而在主线程上
//! 就地解码又会阻塞呈现。这里取中间：固定数量（默认 3 个）的 worker 线程，
//! 被所有流共享，按轮转把每路流的解码队列填到上限。
//!
//! ## 线程契约（这一层的承重墙）
//!
//! - **worker 数量固定**，与流的数量无关。加流不会加线程。
//! - **每路流串行解码**：任一时刻最多一个 worker 碰某路流的后端与队列。这是靠
//!   每路一个 `busy` 标志实现的——一条流只会被交给一个 worker，且在那个 worker
//!   完成本轮之前不会重新入队。由此：
//!     - `FrameQueue` 的 SPSC 契约成立：生产者始终只有一个（当前持有该流的
//!       worker），消费者只有一个（主线程），生产者之间永远不重叠；
//!     - 每路流的帧顺序是确定的——按后端给帧的顺序入队，线性播放时即 PTS 单调。
//! - **后端只被当前持有它的 worker 触碰**。`unregisterStream` 会阻塞到在途的
//!   那一轮结束，所以流在中途被销毁也不会导致 use-after-free。
//! - **worker 不碰任何 Godot / RenderingDevice API**。呈现与 GPU pass 始终在
//!   主线程，由它来取队列。
//!
//! ## 表面数量（验收条件）
//!
//! 解码池必须至少开 `pool_depth + frame_latency` 块表面，才能保证"同一时刻可能
//! 存活的每一块表面都有自己的后备存储"：排在队列里的、正在转换/呈现的、以及
//! 还被回收环扣着的。见 `requiredPoolDepth`。
//!
//! ## 强制同步模式（调试用）
//!
//! `force_synchronous` 置位时不创建任何 worker 线程，解码就在调用者（主线程）
//! 线程上同步跑完。这样"解码→转换→呈现"的生命周期 bug 可以在没有任何线程交接
//! 的确定性条件下复现。该模式只在 Debug / ReleaseSafe 下编译进来，ReleaseFast
//! 里被强制为 false，避免发布版误走同步路径。
//!
//! ## 所有权
//!
//! `StreamHandle = *DecodeStream`，`DecodeStream` 只由调度器拥有：注册时分配，
//! 注销时（以及析构时清理残留）释放。不需要引用计数，因为注销返回时已经和所有
//! worker 排好序——流被标记为死、在途的那一轮被等完、并从就绪表里摘掉——所以
//! 注销之后句柄立即失效，调用方也都是这么用的。

const std = @import("std");
const builtin = @import("builtin");

const backend_mod = @import("backend.zig");
const frame_queue = @import("frame_queue.zig");
const sys_clock = @import("sys_clock.zig");

const log = std.log.scoped(.decode_scheduler);

pub const Backend = backend_mod.Backend;
pub const VideoFrame = backend_mod.VideoFrame;

/// 强制同步模式是否编译进本构建。只在 Debug / ReleaseSafe 下可用。
pub const force_sync_available: bool = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    else => false,
};

/// 每路流解码预读环的容量。`FrameQueue` 的实际可用槽位是容量减一。
pub const kDecodeAheadCapacity: usize = 8;

/// worker 线程数的默认上界。刻意取小：解码是硬件辅助且每路串行的，
/// 少量 worker 就能公平地服务很多路流。
pub const kDefaultWorkerCount: usize = 3;

/// 一路流的解码预读队列类型：一个生产者（持有该流的 worker），
/// 一个消费者（主线程）。
pub const DecodeAheadQueue = frame_queue.FrameQueue(VideoFrame, kDecodeAheadCapacity);

/// 表面数量下限：队列里排着的 + 正在呈现的 1 帧 + 回收环扣着的。
pub fn requiredPoolDepth(queue_usable_depth: usize, frame_latency: usize) usize {
    return queue_usable_depth + 1 + frame_latency;
}

/// 每路流的解码状态，由调度器拥有。
///
/// 所有可变的调度状态都由调度器的互斥锁保护；`queue` 自身是无锁的 SPSC。
pub const DecodeStream = struct {
    backend: ?Backend = null,
    queue: DecodeAheadQueue = .{},

    /// 该流正排在就绪队列里等 worker。
    queued: bool = false,
    /// 某个 worker 正持有这条流（本轮解码在途）。**任一时刻至多一个 worker
    /// 持有某条流**，这正是 `FrameQueue` 单生产者契约的来源。
    busy: bool = false,
    /// 消费者取走了一帧（或刚注册），所以本轮结束后应当重新入队补货。
    wants_more: bool = false,

    /// 后端报告了流结束。置位后不再请求新帧。
    eos: bool = false,

    /// 注销开始时置位，好让醒来的 worker 不再开始新一轮。只写一次、从不清除，
    /// 因此用原子而不是互斥锁保护的字段：热路径上每帧都要读它，用 acquire
    /// 免锁读，避免每帧抢一次锁。
    dead: std.atomic.Value(bool) = .init(false),

    /// 入队边界的单调性守卫。呈现选择器假设帧按 PTS 非递减入队，
    /// 这里记录最近一次入队的 PTS，用于发现违反该假设的后端。
    /// 只由当前持有该流的生产者路径触碰（每路串行），所以不需要同步。
    last_enqueued_pts: ?f64 = null,
    pts_regressed_warned: bool = false,
};

pub const StreamHandle = *DecodeStream;

/// 所有流共享的 worker 池。一个实例服务多路流。
pub const DecodeScheduler = struct {
    allocator: std.mem.Allocator,

    workers: std.ArrayList(std.Thread) = .empty,

    /// 需要解码预读的流。由互斥锁保护，worker 在条件变量上等待；
    /// 一条流在队列里最多出现一次（靠它的 queued 标志保证）。
    mu: sys_clock.Mutex = .{},
    cv: sys_clock.Condition = .{},
    ready: std.ArrayList(StreamHandle) = .empty,
    ready_head: usize = 0,
    shutting_down: bool = false,

    /// 保留所有已注册流的句柄：注销时要和在途工作排序，析构时要清理残留。
    registered: std.ArrayList(StreamHandle) = .empty,

    synchronous: bool = false,

    /// 创建调度器（堆分配、按指针持有）：worker 线程捕获调度器指针，
    /// 所以它必须待在稳定地址上。
    ///
    /// `worker_count` 会被钳到 ≥ 1。`force_synchronous` 只在 Debug / ReleaseSafe
    /// 下生效。
    pub fn init(
        allocator: std.mem.Allocator,
        worker_count: usize,
        force_synchronous: bool,
    ) !*DecodeScheduler {
        const self = try allocator.create(DecodeScheduler);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .synchronous = if (force_sync_available) force_synchronous else false,
        };

        if (self.synchronous) return self; // 同步模式下没有 worker 线程。

        const n = @max(@as(usize, 1), worker_count);
        try self.workers.ensureTotalCapacityPrecise(allocator, n);
        errdefer {
            // 已经起来的 worker 要先停掉再放弃。
            self.mu.lock();
            self.shutting_down = true;
            self.mu.unlock();
            self.cv.broadcast();
            for (self.workers.items) |t| t.join();
            self.workers.deinit(allocator);
        }
        for (0..n) |_| {
            const t = try std.Thread.spawn(.{}, workerMain, .{self});
            self.workers.appendAssumeCapacity(t);
        }
        return self;
    }

    pub fn deinit(self: *DecodeScheduler) void {
        {
            self.mu.lock();
            self.shutting_down = true;
            self.mu.unlock();
        }
        self.cv.broadcast();
        for (self.workers.items) |t| t.join();
        self.workers.deinit(self.allocator);

        // 释放那些活过了绑定的流里仍缓冲着的帧（防御性：规矩的调用方会先注销）。
        var leftover: std.ArrayList(StreamHandle) = .empty;
        {
            self.mu.lock();
            leftover = self.registered;
            self.registered = .empty;
            self.mu.unlock();
        }
        for (leftover.items) |s| {
            self.releaseStreamResources(s);
            self.allocator.destroy(s);
        }
        leftover.deinit(self.allocator);
        self.ready.deinit(self.allocator);

        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// 注册一路流。调度器接管后端的所有权，并开始预读进它的队列。
    /// 注册即自动通知，解码预读立刻开始。
    pub fn registerStream(self: *DecodeScheduler, backend: Backend) !StreamHandle {
        errdefer {
            backend.close();
            backend.deinit();
        }
        const stream = try self.allocator.create(DecodeStream);
        stream.* = .{ .backend = backend };
        {
            self.mu.lock();
            self.registered.append(self.allocator, stream) catch |e| {
                self.mu.unlock();
                self.allocator.destroy(stream);
                return e;
            };
            stream.wants_more = true;
            self.mu.unlock();
        }
        self.notify(stream);
        return stream;
    }

    /// 注销一路流。阻塞到该流在途的那一轮结束，然后释放所有仍缓冲的帧
    /// （逐个执行释放闭包）、关掉后端、释放流。返回后句柄立即失效。
    pub fn unregisterStream(self: *DecodeScheduler, stream: StreamHandle) void {
        {
            self.mu.lock();
            // 标记为死，让 worker 不再开始新一轮；并等待本流在途的那一轮结束
            // （busy 落下）——保证没有任何 worker 还在碰它的后端/队列。
            stream.dead.store(true, .release);
            stream.wants_more = false;
            // 同步模式下没有 worker，busy 只可能由调用线程置位，这里会立即返回。
            while (stream.busy) self.cv.wait(&self.mu);

            removeHandle(&self.registered, stream);
            self.removeReadyLocked(stream);
            stream.queued = false;
            self.mu.unlock();
        }

        // 现在可以安全触碰后端与队列了：dead 已置位、busy 已落下，
        // 不会再有 worker 处理这条流。
        self.releaseStreamResources(stream);
        self.allocator.destroy(stream);
    }

    /// 消费者（主线程）取下一帧。预读队列暂时为空时返回 null。
    /// 返回的帧归调用方所有，最终必须执行它的 `release()`。
    pub fn nextFrame(self: *DecodeScheduler, stream: StreamHandle) ?VideoFrame {
        const f = stream.queue.pop();
        if (f != null) {
            // 取走一帧就空出一个槽位，请池子补货。
            {
                self.mu.lock();
                if (!stream.dead.load(.monotonic)) stream.wants_more = true;
                self.mu.unlock();
            }
            self.notify(stream);
        }
        return f;
    }

    /// 流是否已经到头（后端报 EOS 且队列已空）。
    pub fn atEnd(self: *DecodeScheduler, stream: StreamHandle) bool {
        _ = self;
        return stream.eos and stream.queue.empty();
    }

    /// 队列头部的 PTS（供呈现选择器决策，不取走帧）。
    pub fn peekHeadPts(self: *DecodeScheduler, stream: StreamHandle) ?f64 {
        _ = self;
        return if (stream.queue.peek()) |f| f.pts_seconds else null;
    }

    /// 队列第二个元素的 PTS（前瞻用）。
    pub fn peekNextPts(self: *DecodeScheduler, stream: StreamHandle) ?f64 {
        _ = self;
        return if (stream.queue.peekNext()) |f| f.pts_seconds else null;
    }

    /// 实际创建的 worker 线程数（同步模式恒为 0）。
    pub fn workerCount(self: *const DecodeScheduler) usize {
        return self.workers.items.len;
    }

    pub fn isSynchronous(self: *const DecodeScheduler) bool {
        return self.synchronous;
    }

    // ------------------------------------------------------------------
    // 内部实现
    // ------------------------------------------------------------------

    fn releaseStreamResources(self: *DecodeScheduler, stream: StreamHandle) void {
        _ = self;
        while (stream.queue.pop()) |f| f.release();
        if (stream.backend) |b| {
            b.close();
            b.deinit();
            stream.backend = null;
        }
    }

    /// 结束一次独占租约，并与"是否需要重新入队"原子地一起完成。
    /// busy 一旦落下，等在注销里的线程就可能销毁这条流，所以本函数刻意是该
    /// 持有者最后一次触碰这条流。
    fn finishClaim(self: *DecodeScheduler, stream: StreamHandle) void {
        if (self.synchronous) {
            // 同步模式：在同一份租约里把待办工作做完，避免释放租约之后再递归
            // 通知一遍。
            self.mu.lock();
            const pump_more = !stream.dead.load(.monotonic) and stream.wants_more;
            stream.wants_more = false;
            self.mu.unlock();
            if (pump_more) self.pumpStream(stream);
        }

        self.mu.lock();
        stream.busy = false;
        const wake = if (self.synchronous) false else self.enqueueLocked(stream);
        self.mu.unlock();
        self.cv.broadcast();
        if (wake) self.cv.signal();
    }

    /// 标记某路流需要预读，并唤醒一个 worker（异步）或就地泵一轮（同步）。
    /// **幂等**：已经排队或正在解码的流不会被重复入队——这就是每路流串行的保证。
    fn notify(self: *DecodeScheduler, stream: StreamHandle) void {
        if (self.synchronous) {
            // 同步模式：在调用线程上就地泵一轮。仍然占用 busy，
            // 这样"每路只有一个生产者"的契约在没有 worker 时也成立，
            // 注销路径等的就是它。
            {
                self.mu.lock();
                if (stream.dead.load(.monotonic) or stream.busy or !stream.wants_more) {
                    self.mu.unlock();
                    return;
                }
                stream.busy = true;
                stream.wants_more = false;
                self.mu.unlock();
            }
            self.pumpStream(stream);
            {
                self.mu.lock();
                stream.busy = false;
                self.mu.unlock();
            }
            self.cv.broadcast();
            return;
        }

        var wake = false;
        {
            self.mu.lock();
            wake = self.enqueueLocked(stream);
            self.mu.unlock();
        }
        if (wake) self.cv.signal();
    }

    /// 若该流有资格（活着、想要更多、既没排队也没被占用）就入队一轮解码。
    /// queued/busy 这一对守卫保证一条流永远不会同时交给两个 worker，
    /// 也就保证了每路流串行解码。入队时消耗掉 wants_more 这份需求。
    /// 调用方需持有互斥锁；返回值表示是否入队（唤醒在锁外做）。
    fn enqueueLocked(self: *DecodeScheduler, stream: StreamHandle) bool {
        if (stream.dead.load(.monotonic) or stream.queued or stream.busy or !stream.wants_more) return false;
        stream.wants_more = false;
        stream.queued = true;
        self.ready.append(self.allocator, stream) catch @panic("DecodeScheduler OOM");
        return true;
    }

    /// 从就绪队列取下一路流并标记为 busy。排队期间被销毁的流在这里被跳过，
    /// 所以返回 null 只有一种含义：正在关停且队列已空。
    fn takeReadyStream(self: *DecodeScheduler) ?StreamHandle {
        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            while (!self.shutting_down and self.ready.items.len == 0) self.cv.wait(&self.mu);
            if (self.shutting_down and self.ready.items.len == 0) return null;
            const stream = self.ready.items[self.ready_head];
            self.ready_head += 1;
            if (self.ready_head == self.ready.items.len) {
                self.ready.clearRetainingCapacity();
                self.ready_head = 0;
            }
            stream.queued = false;
            if (stream.dead.load(.monotonic)) continue;
            stream.busy = true;
            return stream;
        }
    }

    /// 移除是冷路径。worker 的热路径出队只推进游标，因此这里是摊还 O(1)，
    /// 不必每取一条就搬动整个就绪表。
    fn removeReadyLocked(self: *DecodeScheduler, stream: StreamHandle) void {
        var idx = self.ready_head;
        while (idx < self.ready.items.len) : (idx += 1) {
            if (self.ready.items[idx] == stream) {
                _ = self.ready.orderedRemove(idx);
                if (self.ready_head == self.ready.items.len) {
                    self.ready.clearRetainingCapacity();
                    self.ready_head = 0;
                }
                return;
            }
        }
    }

    fn workerMain(self: *DecodeScheduler) void {
        while (true) {
            const stream = self.takeReadyStream() orelse return;

            self.pumpStream(stream);

            {
                self.mu.lock();
                stream.busy = false;
                // 如果我们在解码期间消费者又提出了需求，就重新入队，
                // 让各路流轮转得到服务，而不是一条流饿死别人。
                _ = self.enqueueLocked(stream);
                self.mu.unlock();
            }
            // 唤醒等注销的线程（busy 刚落下），并在需要时唤醒一个 worker。
            self.cv.broadcast();
        }
    }

    /// 为 `stream` 解码一轮：从它的后端取帧进它的队列，直到队列满或 EOS。
    /// 调用方必须持有该流的 busy 租约，因此这里是它队列的唯一生产者、
    /// 也是它后端的唯一触碰者。
    fn pumpStream(self: *DecodeScheduler, stream: StreamHandle) void {
        const backend = if (stream.backend) |*b| b else return;

        while (!stream.queue.full()) {
            // 热路径上免锁读一次写一次的 dead 标志（acquire 与注销里的
            // release 配对），不必每帧抢一次锁。
            if (stream.dead.load(.acquire)) return;
            const maybe_frame = backend.nextVideoFrame();
            if (maybe_frame == null) {
                self.mu.lock();
                stream.eos = true;
                self.mu.unlock();
                return;
            }
            const frame = maybe_frame.?;
            checkEnqueueMonotonic(stream, frame.pts_seconds);
            if (!stream.queue.push(frame)) {
                // 与容量赛跑输了（单生产者下不该发生）：把帧还回去以免泄漏。
                frame.release();
                return;
            }
        }
    }
};

/// 入队边界上的单调性防护。
///
/// 帧应当按 PTS 非递减的顺序进入队列：呈现选择器会丢弃"后继也已到期"的队首，
/// 所以一个按解码顺序给帧的后端（例如没有做 B 帧重排的 H.264 源）会让选择器
/// 反复抖动，画面一格向前一格向后。与其无声地出错，不如在首次发现 PTS 回退时
/// 打一条一次性告警，然后更新基线。
///
/// 它只是诊断：从不重排、从不丢帧，管线照旧按后端给的顺序走。
/// 调用方必须是该流唯一的生产者（busy 租约保证这一点）。公开出来是为了让
/// "单调序"这个契约可以被单测。
pub fn checkEnqueueMonotonic(stream: StreamHandle, pts: f64) void {
    if (stream.last_enqueued_pts) |prev| {
        if (pts < prev and !stream.pts_regressed_warned) {
            stream.pts_regressed_warned = true;
            log.warn(
                "视频 PTS 在入队边界回退：{d:.4}s 出现在 {d:.4}s 之后且没有 seek——帧不在呈现顺序上，播放会抖动",
                .{ pts, prev },
            );
        }
    }
    stream.last_enqueued_pts = pts;
}

fn removeHandle(list: *std.ArrayList(StreamHandle), stream: StreamHandle) void {
    for (list.items, 0..) |s, idx| {
        if (s == stream) {
            _ = list.orderedRemove(idx);
            return;
        }
    }
}
