//! 播放状态机与重连退避策略：一路流的"现在处于什么状态、下一步该做什么"。
//!
//! ## 为什么这一层就是 0008 的全部
//!
//! 源工程的 `playback_controller` 除了状态机，还管音频混音与拖动 scrubbing——
//! 而本插件只解视频、直播流没有 seek 语义，那两块在 0005/0007 的说明里已经
//! 分别去掉了。剩下的、且真正需要在 core 里有唯一权威答案的，就是这套状态迁移
//! 与重连节奏。它也是原 LunaFusion 里散在 GDScript 中那约 150 行样板的核心。
//!
//! ## 状态
//!
//! ```
//! idle ──beginOpen──▶ opening ──firstFrame──▶ playing
//!   ▲                    │                     │
//!   │                 onFailure             noFrameFor(stall_after)
//!   │                    ▼                     ▼
//!   └──── stop ────── failed ◀──retry──── stalled
//! ```
//!
//! - `playing`：有帧在持续到达。
//! - `stalled`：有一阵子没有新帧了（弱网、摄像头掉线），但还没判定为失败。
//! - `failed`：重连次数用尽。**这是一个终态**——不再自动重试，需要外部显式
//!   `beginOpen` 才会重新开始。
//!
//! ## 重连节奏
//!
//! 指数退避：首次 1.5 秒，每次翻倍，封顶 8 秒（默认值）。上限 8 次。
//! 退避间隔与尝试次数都是纯函数式推进的，所以可以在没有网络、没有时钟的
//! 情况下把整条时间线跑一遍验证。

const std = @import("std");

pub const State = enum {
    /// 还没开始。
    idle,
    /// 已发起连接，一帧都没拿到。
    opening,
    /// 帧在持续到达。
    playing,
    /// 曾正常，但已有一阵子没有新帧。
    stalled,
    /// 重连次数用尽。终态。
    failed,
    /// 用户显式停止。
    off,
};

/// 重连与停滞判定的参数。
pub const Policy = struct {
    /// 多久没有新帧算"停滞"。
    stall_after_ms: i64 = 2000,
    /// 首次重试的等待时间。
    backoff_initial_ms: i64 = 1500,
    /// 退避的封顶值。
    backoff_max_ms: i64 = 8000,
    /// 最多尝试重连几次。
    max_attempts: u32 = 8,
};

pub const Machine = struct {
    policy: Policy = .{},
    state: State = .idle,
    /// 已经重连了几次（首帧到达时归零）。
    attempts: u32 = 0,
    /// 下一次重试前应等待的毫秒数。
    backoff_ms: i64 = 0,
    /// 上一次"状态变更依据"的时刻（收到帧、或进入当前状态）。
    last_frame_ms: i64 = 0,
    /// 下一次允许重试的时刻。
    next_retry_ms: i64 = 0,

    pub fn init(policy: Policy) Machine {
        return .{ .policy = policy, .backoff_ms = policy.backoff_initial_ms };
    }

    /// 发起（或重新发起）连接。
    pub fn beginOpen(self: *Machine, now_ms: i64) void {
        self.state = .opening;
        self.last_frame_ms = now_ms;
    }

    /// 第一帧到达：连接成功。尝试次数归零，退避回到初始值。
    pub fn onFirstFrame(self: *Machine, now_ms: i64) void {
        self.state = .playing;
        self.attempts = 0;
        self.backoff_ms = self.policy.backoff_initial_ms;
        self.last_frame_ms = now_ms;
    }

    /// 又来了新帧。
    ///
    /// 只要帧到了就是"在出画"——不管此前是疑似停滞（`stalled`）还是已经在
    /// 重连途中（`opening`），都立刻回到 `playing` 并把重连计数归零。
    /// 漏掉 `opening` 这一支的表现是：重连明明成功了，状态却一直显示"连接中"。
    pub fn onFrame(self: *Machine, now_ms: i64) void {
        self.last_frame_ms = now_ms;
        switch (self.state) {
            .stalled, .opening => {
                self.state = .playing;
                self.attempts = 0;
                self.backoff_ms = self.policy.backoff_initial_ms;
            },
            else => {},
        }
    }

    /// 时间推进。返回是否**应该现在就发起重连**。
    ///
    /// 停滞判定优先于重连：先把状态如实降级为 `stalled`，再按退避窗口决定
    /// 要不要真的重连。`failed` 与 `off` 是终态，不再产生重连请求。
    pub fn tick(self: *Machine, now_ms: i64) bool {
        switch (self.state) {
            .failed, .off, .idle => return false,
            .opening, .playing => {
                if (now_ms - self.last_frame_ms >= self.policy.stall_after_ms) {
                    self.state = .stalled;
                    self.next_retry_ms = now_ms;
                } else {
                    return false;
                }
            },
            .stalled => {},
        }

        if (now_ms < self.next_retry_ms) return false;

        if (self.attempts >= self.policy.max_attempts) {
            self.state = .failed;
            return false;
        }

        self.attempts += 1;
        // 指数退避，封顶。下一帧到达后 onFirstFrame 会把这一切清零。
        self.backoff_ms = @min(self.backoff_ms * 2, self.policy.backoff_max_ms);
        self.next_retry_ms = now_ms + self.backoff_ms;
        self.state = .opening;
        self.last_frame_ms = now_ms;
        return true;
    }

    /// 显式停止。
    pub fn stop(self: *Machine) void {
        self.state = .off;
    }

    pub fn isTerminal(self: *const Machine) bool {
        return self.state == .failed or self.state == .off;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn machine() Machine {
    return Machine.init(.{});
}

test "初始状态是 idle，且不产生重连请求" {
    var m = machine();
    try testing.expectEqual(State.idle, m.state);
    try testing.expect(!m.tick(10_000));
}

test "发起连接后进入 opening" {
    var m = machine();
    m.beginOpen(0);
    try testing.expectEqual(State.opening, m.state);
}

test "首帧到达进入 playing 并把尝试次数清零" {
    var m = machine();
    m.beginOpen(0);
    m.attempts = 3; // 模拟此前重连过
    m.onFirstFrame(100);
    try testing.expectEqual(State.playing, m.state);
    try testing.expectEqual(@as(u32, 0), m.attempts);
    try testing.expectEqual(m.policy.backoff_initial_ms, m.backoff_ms);
}

test "持续有帧就一直 playing" {
    var m = machine();
    m.beginOpen(0);
    m.onFirstFrame(0);
    var t: i64 = 0;
    while (t < 10_000) : (t += 500) {
        m.onFrame(t);
        try testing.expect(!m.tick(t));
        try testing.expectEqual(State.playing, m.state);
    }
}

test "超过停滞阈值后降级为 stalled 并请求重连" {
    var m = machine();
    m.beginOpen(0);
    m.onFirstFrame(0);
    // 阈值内不动作。
    try testing.expect(!m.tick(m.policy.stall_after_ms - 1));
    try testing.expectEqual(State.playing, m.state);
    // 越过阈值：先降级，再按退避窗口决定重连。
    try testing.expect(m.tick(m.policy.stall_after_ms));
    try testing.expectEqual(State.opening, m.state);
    try testing.expectEqual(@as(u32, 1), m.attempts);
}

test "重连间隔指数退避并封顶" {
    var m = machine();
    m.beginOpen(0);
    m.onFirstFrame(0);
    var now = m.policy.stall_after_ms;
    _ = m.tick(now);
    // 第一次退避后是 2×初始值（首次 tick 已把 backoff 翻倍过一次）。
    const expected = [_]i64{ 3000, 6000, 8000, 8000 };
    for (expected) |want| {
        try testing.expectEqual(want, m.backoff_ms);
        now = m.next_retry_ms;
        // 重新进入停滞才能再触发一次重连。
        _ = m.tick(now + m.policy.stall_after_ms);
        now = m.next_retry_ms;
    }
    try testing.expectEqual(m.policy.backoff_max_ms, m.backoff_ms);
}

test "尝试次数用尽后进入 failed，且不再重连" {
    const p = Policy{ .stall_after_ms = 100, .backoff_initial_ms = 10, .backoff_max_ms = 20, .max_attempts = 3 };
    var m = Machine.init(p);
    m.beginOpen(0);
    m.onFirstFrame(0);

    var now: i64 = 0;
    while (!m.isTerminal()) {
        now += p.stall_after_ms;
        _ = m.tick(now);
        now = m.next_retry_ms;
    }
    try testing.expectEqual(State.failed, m.state);
    try testing.expectEqual(@as(u32, 3), m.attempts);
    // 终态之后再也不请求重连。
    try testing.expect(!m.tick(now + 1_000_000));
}

test "重连成功后回到 playing 并重置退避" {
    var m = machine();
    m.beginOpen(0);
    m.onFirstFrame(0);
    _ = m.tick(m.policy.stall_after_ms);
    try testing.expectEqual(@as(u32, 1), m.attempts);

    m.onFirstFrame(m.next_retry_ms + 50);
    try testing.expectEqual(State.playing, m.state);
    try testing.expectEqual(@as(u32, 0), m.attempts);
    try testing.expectEqual(m.policy.backoff_initial_ms, m.backoff_ms);
}

test "停滞中的帧到达会立刻恢复 playing" {
    var m = machine();
    m.beginOpen(0);
    m.onFirstFrame(0);
    _ = m.tick(m.policy.stall_after_ms);
    try testing.expectEqual(State.opening, m.state); // tick 已发起重连
    m.onFrame(m.policy.stall_after_ms + 1);
    try testing.expectEqual(State.playing, m.state);
}

test "显式停止进入 off 终态" {
    var m = machine();
    m.beginOpen(0);
    m.onFirstFrame(0);
    m.stop();
    try testing.expectEqual(State.off, m.state);
    try testing.expect(m.isTerminal());
    try testing.expect(!m.tick(1_000_000));
}

test "failed 是终态：只有外部重新 beginOpen 才能再开始" {
    const p = Policy{ .stall_after_ms = 10, .backoff_initial_ms = 1, .backoff_max_ms = 1, .max_attempts = 1 };
    var m = Machine.init(p);
    m.beginOpen(0);
    m.onFirstFrame(0);
    _ = m.tick(10);
    _ = m.tick(m.next_retry_ms + 100);
    try testing.expectEqual(State.failed, m.state);

    m.beginOpen(999);
    try testing.expectEqual(State.opening, m.state);
    try testing.expect(!m.isTerminal());
}
