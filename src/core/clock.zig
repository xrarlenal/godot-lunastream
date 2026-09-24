//! 媒体时钟：播放位置的唯一时间来源。
//!
//! 解码调度、呈现选择、重连退避、状态上报四者都以这里的时间为准。所有时间量
//! 都是秒（f64），因为媒体 PTS 需要这个精度来表达数小时长度的内容。
//!
//! ## 与源工程的差异
//!
//! 源工程 `third_party/native_video/src/core/clock.zig` 由三个类型组成：
//! `MonotonicClock`（无声片源）、`AudioMasterClock`（以音频采样消耗为准）、
//! `ClockBridge`（运行时切换主导方）。本插件定位是"视频**源**"，网络流后端
//! （ffvt / ffd3d / ffva / ffsw）本身就不解码音频，因此这里只复刻
//! 单调推进这一条路径，并把它命名为 `MediaClock`。
//!
//! 若将来把带音频的本地文件路径（源工程的 avf / mf 后端）也迁进来，本模块
//! 需要扩展出"可切换主导方"的形态；届时按同一流程单独提一次功能点，而不是
//! 现在就把用不到的分支铺进来。

const std = @import("std");

/// 单调推进的媒体时钟。
///
/// 语义要点（每条都由 clock.zig 内的单元测试锁定）：
///
/// - `advance()` 只在未暂停且 delta > 0 时推进，因此时间**永不倒流**；
/// - `seekTo()` 是显式的绝对定位，**允许回拨**（seek 的语义就是回拨）；
/// - `reanchor()` 只允许向前，用于断流重连后新帧的时间戳比本地时间略旧时
///   对齐位置——它绝不能把播放位置拽回去，否则画面会跳回旧帧。
pub const MediaClock = struct {
    time: f64 = 0.0,
    paused: bool = false,

    pub fn init(initial_seconds: f64) MediaClock {
        return .{ .time = initial_seconds, .paused = false };
    }

    /// 当前媒体时间（秒）。
    pub fn mediaTime(self: *const MediaClock) f64 {
        return self.time;
    }

    /// 按渲染 delta 推进媒体时间。暂停中、或 delta 非正时为空操作。
    pub fn advance(self: *MediaClock, delta_seconds: f64) void {
        if (!self.paused and delta_seconds > 0.0) {
            self.time += delta_seconds;
        }
    }

    /// 显式绝对定位（seek）。允许回拨。
    pub fn seekTo(self: *MediaClock, time_seconds: f64) void {
        self.time = time_seconds;
    }

    /// 向前重新锚定。仅当目标时间晚于当前时间时生效。
    ///
    /// 返回是否真的发生了重新锚定，便于调用方决定要不要打日志——重连时
    /// "锚定被忽略"与"锚定生效"是两种应当被区分开的现场。
    pub fn reanchor(self: *MediaClock, time_seconds: f64) bool {
        if (time_seconds <= self.time) return false;
        self.time = time_seconds;
        return true;
    }

    pub fn setPaused(self: *MediaClock, paused: bool) void {
        self.paused = paused;
    }

    pub fn isPaused(self: *const MediaClock) bool {
        return self.paused;
    }
};

/// 单调挂钟时间戳（毫秒）。
///
/// 播放控制器与重连退避都要消费挂钟时间，而裸 f64 无法表达"这两个数来自同一
/// 时钟"这个契约。用类型把契约固定下来：构造必须显式，且不提供逆转换，值不会
/// 悄悄退化成普通数字。
pub const WallClockMs = struct {
    ms: f64 = 0.0,

    pub fn init(milliseconds: f64) WallClockMs {
        return .{ .ms = milliseconds };
    }

    /// 两个时间戳之间的毫秒差（负值表示 b 早于 a）。
    pub fn since(self: WallClockMs, earlier: WallClockMs) f64 {
        return self.ms - earlier.ms;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "初始位置为零" {
    const clock = MediaClock.init(0.0);
    try std.testing.expectEqual(0.0, clock.mediaTime());
    try std.testing.expect(!clock.isPaused());
}

test "初始位置可以被指定" {
    const clock = MediaClock.init(12.5);
    try std.testing.expectEqual(12.5, clock.mediaTime());
}

test "advance 按 delta 累加" {
    var clock = MediaClock.init(0.0);
    clock.advance(0.016);
    clock.advance(0.016);
    try std.testing.expectApproxEqAbs(@as(f64, 0.032), clock.mediaTime(), 1e-9);
}

test "暂停时 advance 不推进" {
    var clock = MediaClock.init(1.0);
    clock.setPaused(true);
    clock.advance(0.5);
    try std.testing.expectEqual(1.0, clock.mediaTime());
    try std.testing.expect(clock.isPaused());
}

test "解除暂停后继续累加" {
    var clock = MediaClock.init(1.0);
    clock.setPaused(true);
    clock.advance(0.5);
    clock.setPaused(false);
    clock.advance(0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), clock.mediaTime(), 1e-9);
}

test "负 delta 与零 delta 都不推进（时间不倒流）" {
    var clock = MediaClock.init(5.0);
    clock.advance(-1.0);
    clock.advance(0.0);
    try std.testing.expectEqual(5.0, clock.mediaTime());
}

test "seekTo 允许回拨" {
    var clock = MediaClock.init(30.0);
    clock.seekTo(2.0);
    try std.testing.expectEqual(2.0, clock.mediaTime());
}

test "reanchor 只向前：回拨请求被忽略" {
    var clock = MediaClock.init(10.0);
    const moved = clock.reanchor(4.0);
    try std.testing.expect(!moved);
    try std.testing.expectEqual(10.0, clock.mediaTime());
}

test "reanchor 向前时生效并报告已锚定" {
    var clock = MediaClock.init(10.0);
    const moved = clock.reanchor(10.5);
    try std.testing.expect(moved);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), clock.mediaTime(), 1e-9);
}

test "reanchor 与当前相同不算锚定" {
    var clock = MediaClock.init(10.0);
    try std.testing.expect(!clock.reanchor(10.0));
    try std.testing.expectEqual(10.0, clock.mediaTime());
}

test "暂停状态下 reanchor 仍然生效（它改的是绝对位置，不是推进）" {
    var clock = MediaClock.init(1.0);
    clock.setPaused(true);
    try std.testing.expect(clock.reanchor(3.0));
    try std.testing.expectEqual(3.0, clock.mediaTime());
    try std.testing.expect(clock.isPaused());
}

test "WallClockMs 承载原始值并支持求差" {
    const a = WallClockMs.init(1000.0);
    const b = WallClockMs.init(1250.5);
    try std.testing.expectEqual(1000.0, a.ms);
    try std.testing.expectApproxEqAbs(@as(f64, 250.5), b.since(a), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -250.5), a.since(b), 1e-9);
}

test "WallClockMs 默认值为零" {
    const w: WallClockMs = .{};
    try std.testing.expectEqual(0.0, w.ms);
}

test "重连场景：源的 PTS 从头开始，播放位置不倒退（0024）" {
    var clock = MediaClock.init(0.0);

    // 第一段：播放到 5 秒附近（每帧 40ms，模拟 25fps）。
    var pts: f64 = 5.0;
    while (pts < 5.1) : (pts += 0.04) {
        clock.advance(0.04);
        _ = clock.reanchor(pts);
    }
    const before_reconnect = clock.mediaTime();
    try std.testing.expect(before_reconnect >= 5.0);

    // 断流重连：新的源从 0 开始给 PTS。
    // 这正是 0019 的重连路径上实测会发生的（core 的单调性守卫会告警）。
    try std.testing.expect(!clock.reanchor(0.0)); // 回拨被忽略
    try std.testing.expect(!clock.reanchor(0.04));
    try std.testing.expect(clock.mediaTime() >= before_reconnect);

    // 时钟继续按渲染 delta 走，于是画面恢复后位置继续向前，不会卡在旧值上。
    clock.advance(0.04);
    try std.testing.expect(clock.mediaTime() > before_reconnect);
}
