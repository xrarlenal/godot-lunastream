//! 呈现选择器：现在屏幕上应该是哪一帧？
//!
//! 解码线程会提前解出若干帧并按 PTS 排好队。每个渲染 tick，播放控制拿着
//! 主时钟时间问这里一个问题：队首那一帧该显示、该等、还是该丢？
//!
//! 这是"跟不跟得上"的核心判定，所以它被隔离成纯函数放在 core：不碰 Godot、
//! 不碰时钟本体，输入是几个数，输出是三个动作之一——因此可以被穷举验证。
//!
//! ## 策略：早到就等（hold-early），迟到就丢（drop-late）
//!
//! | 动作 | 条件 | 含义 |
//! |---|---|---|
//! | `hold` | 队首 PTS 还在未来 | 还没轮到它，保持当前画面继续等 |
//! | `show` | 队首已到期，且**后继还没到期** | 队首就是此刻最新的一帧，上屏 |
//! | `drop` | 队首已到期，且后继**也已经到期** | 队首已经陈旧，丢掉它去追实时 |
//!
//! ## 两条被刻意保护的边界
//!
//! **绝不空屏**：只剩一个到期帧时，即使它已迟到接近一个帧间隔，也仍然 `show`
//! 而不是 `drop`——一帧在上屏期间本来就会横跨约一个帧间隔，落后一点点是正常的。
//! 只有当存在"更新且同样到期"的帧可以替代它时才丢。
//!
//! **绝不永久落后**：一旦积压，连续 `drop` 会在**同一个 tick 内**把积压收敛到
//! 只剩一帧。这正是弱网下"回放变慢动作"的解药：丢掉旧的、直接跳到实时。

const std = @import("std");

pub const PresentAction = enum {
    /// 队首未到期——保持当前画面，本帧不上屏新内容。
    hold,
    /// 队首陈旧（存在更新的到期帧）——丢掉队首，重新判定。
    drop,
    /// 队首就是此刻该显示的帧——上屏。
    show,
};

/// 判定队首该被如何处理。
///
/// - `head_pts`：队首帧的 PTS（秒）；队列为空时为 null。
/// - `next_pts`：紧随其后的那一帧的 PTS；用于前瞻，没有则为 null。
/// - `now`：主时钟的媒体时间（秒）。
/// - `frame_interval`：名义帧间隔（1/fps，秒）。仅用于给"到期"留一点容差；
///   传 <= 0 时改用极小的兜底容差。
pub fn selectPresentAction(
    head_pts: ?f64,
    next_pts: ?f64,
    now: f64,
    frame_interval: f64,
) PresentAction {
    const head = head_pts orelse {
        // 一帧都还没解出来：保持屏幕上的内容不动。
        return .hold;
    };

    // 留一点容差：PTS 因为取整或时钟粒度落在 now 之后一丁点时仍算"到期"，
    // 否则会被白白多等一个 tick。
    const eps = if (frame_interval > 0.0) frame_interval * 0.5 else 1e-6;

    if (head > now + eps) return .hold; // 真的还没到：早到就等。

    // 队首已到期。若后继也已到期，说明队首陈旧——丢掉它去追实时；
    // 否则队首就是最新到期帧，显示它。
    if (next_pts) |next| {
        if (next <= now + eps) return .drop;
    }
    return .show;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

/// 除特别说明外，测试统一用 30 fps 的帧间隔。
const test_fps: f64 = 30.0;
const test_interval: f64 = 1.0 / test_fps;

test "队列为空时保持当前画面" {
    try std.testing.expectEqual(PresentAction.hold, selectPresentAction(null, null, 1.0, test_interval));
}

test "队首在未来时保持当前画面（早到就等）" {
    // now = 0.50，队首 0.60，超出半个帧间隔的容差 → hold。
    try std.testing.expectEqual(PresentAction.hold, selectPresentAction(0.60, null, 0.50, test_interval));
}

test "正好到期的唯一一帧上屏" {
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(0.50, null, 0.50, test_interval));
}

test "轻微迟到但唯一的到期帧仍然上屏（绝不空屏）" {
    const now = 0.50;
    const head = now - 0.6 * test_interval; // 迟到约 0.6 个帧间隔
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(head, null, now, test_interval));
}

test "队首陈旧且后继也已到期时丢掉队首（迟到就丢）" {
    // now = 1.00，队首 0.90 已陈旧，后继 0.96 也已到期 → drop。
    try std.testing.expectEqual(PresentAction.drop, selectPresentAction(0.90, 0.96, 1.00, test_interval));
}

test "队首到期而后继还在未来时显示队首" {
    // now = 1.00，队首 0.99 到期，后继 1.20 在未来 → show。
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(0.99, 1.20, 1.00, test_interval));
}

test "落在半个帧间隔容差内算到期" {
    const now = 0.50;
    const head = now + 0.4 * test_interval; // 容差是 0.5 个帧间隔
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(head, null, now, test_interval));
}

test "帧间隔传 0 或负数时仍能判定（兜底容差）" {
    // 没有可用帧间隔时也不该把"正好到期"判成未到。
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(0.50, null, 0.50, 0.0));
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(0.50, null, 0.50, -1.0));
    // 明显在未来仍然 hold。
    try std.testing.expectEqual(PresentAction.hold, selectPresentAction(0.51, null, 0.50, 0.0));
}

test "乱序队列会让判定倒退（钉住上游的单调序契约）" {
    // 这里比较的是"每个 PTS 与 now"，从不比较队首与后继的大小。所以如果队列里
    // 后继的 PTS 反而比队首小（B 帧，或后端泄漏了解码顺序），选择器会先丢掉
    // 较新的队首，再显示较旧的后继——播放位置凭空后退一格。
    // 这条测试把"必须保证单调序"这个上游契约钉在这里：这不是选择器能修的问题，
    // 而是队列不允许出现这种输入。
    const now = 1.00;
    try std.testing.expectEqual(PresentAction.drop, selectPresentAction(0.90, 0.80, now, test_interval));
    try std.testing.expectEqual(PresentAction.show, selectPresentAction(0.80, null, now, test_interval));
}

test "连续 drop 在一个 tick 内把积压收敛到一帧" {
    // 队列 [0.80, 0.85, 0.90, 0.95]，now = 1.00：
    // 应当一路 drop 到只剩最新的到期帧 0.95，然后 show。
    const pts = [_]f64{ 0.80, 0.85, 0.90, 0.95 };
    const now = 1.00;
    var i: usize = 0;
    var drops: i32 = 0;
    while (true) {
        const head: ?f64 = if (i < pts.len) pts[i] else null;
        const next: ?f64 = if (i + 1 < pts.len) pts[i + 1] else null;
        switch (selectPresentAction(head, next, now, test_interval)) {
            .drop => {
                drops += 1;
                i += 1;
            },
            .show => {
                try std.testing.expectEqual(@as(usize, 3), i); // 幸存者是 0.95
                break;
            },
            .hold => return error.backlog_should_be_collapsed_not_held,
        }
    }
    try std.testing.expectEqual(@as(i32, 3), drops);
}

test "积压消化完之后队列空一帧时保持画面而非丢帧" {
    // 上一条的延续：收敛到 0.95 之后，下一个 tick 队列是空的，
    // 此时必须 hold（保持刚显示的帧），不能把它丢掉造成空屏。
    try std.testing.expectEqual(PresentAction.hold, selectPresentAction(null, null, 1.05, test_interval));
}
