//! 解码器选择与硬解名额预算。
//!
//! 每路流可以指定 `auto` / `hardware` / `software` 三档，加上一个**全局**的硬解
//! 会话名额上限。之所以需要"名额"，是因为真正稀缺的资源不是 GPU 利用率，而是
//! **并发解码会话数**——它才是会真失败的资源，也是运维能理解和能调的旋钮。
//!
//! ## 三档语义（关键：不是"回退"，是"格式兜底"与"溢出"）
//!
//! | 档位 | 行为 |
//! |---|---|
//! | `hardware` | 只用硬解。失败就是失败，**绝不悄悄落软解**；名额满也照样占（显式指令优先） |
//! | `software` | 只用软解，不占名额 |
//! | `auto` | 编码不在平台白名单 → 软解（**格式兜底**）；在白名单但名额已满 → 软解并标记 `hardware_saturated` |
//!
//! 三者的差别不是措辞：`auto` 走软解时会如实上报"这是溢出还是格式不支持"，
//! 而 `hardware` 档永远不会给用户一个"看起来是硬解其实是软解"的假象。
//!
//! ## 刻意不做自动回切
//!
//! 因名额满而走了软解的 `auto` 通道，即使之后名额空出来也不会自己切回硬解——
//! 要等下次 open/重连重新评估。自动回切会让两路流在名额临界点附近来回抖动，
//! 代价远大于收益。
//!
//! 来源说明：本模块按源工程 `Docs/7-软硬解混合.md` §5/§5.1 记录的语义重建
//! （该文档即其设计契约），不是逐行搬运。

const std = @import("std");

pub const DecoderChoice = enum(u8) {
    auto = 0,
    hardware = 1,
    software = 2,

    /// 越界值返回 null，由调用方保持原值——脚本传错值不该把通道卡在未定义状态。
    pub fn fromInt(value: i64) ?DecoderChoice {
        return switch (value) {
            0 => .auto,
            1 => .hardware,
            2 => .software,
            else => null,
        };
    }
};

/// 编码格式分类。硬解白名单按它判断，而不是按具体 codec id——
/// 白名单关心的是"这个平台的后端实现了没有"。
pub const CodecClass = enum(u8) { h264, hevc, mpeg4, vp9, av1, mjpeg, unknown };

pub const Platform = enum { macos, windows, linux, other };

/// 平台硬解后端**实际实现**的编码。这是编译期常量表，不是能力探测：
/// 写在这里的每一条都对应一个真写过的后端实现。
pub fn hardwareWhitelist(platform: Platform) []const CodecClass {
    return switch (platform) {
        // ffvt：自管 VideoToolbox，只实现了 H.264。
        .macos => &.{.h264},
        // ffd3d（D3D11VA）与 ffva（VAAPI）。
        .windows, .linux => &.{ .h264, .hevc },
        .other => &.{},
    };
}

pub fn isHardwareSupported(platform: Platform, codec: CodecClass) bool {
    for (hardwareWhitelist(platform)) |c| {
        if (c == codec) return true;
    }
    return false;
}

/// 全局硬解名额预算。进程级共享——它只有在所有通道共用一份时才有意义。
pub const HardwareBudget = struct {
    limit: usize = 4,
    in_use: usize = 0,

    pub const min_limit: usize = 1;

    pub fn init(limit: usize) HardwareBudget {
        return .{ .limit = @max(limit, min_limit) };
    }

    /// `auto` 档申请名额：满了返回 false，由调用方落软解。
    pub fn tryAcquire(self: *HardwareBudget) bool {
        if (self.in_use >= self.limit) return false;
        self.in_use += 1;
        return true;
    }

    /// `hardware` 档申请名额：**无条件成功**，允许 `in_use > limit`。
    /// 显式指令不被拒绝，但计数保持诚实——运维能从上报里看出超额了。
    pub fn acquireForced(self: *HardwareBudget) void {
        self.in_use += 1;
    }

    /// 饱和减法：重复释放不会回绕成一个巨大的数（那会永久饿死后续通道）。
    pub fn release(self: *HardwareBudget) void {
        self.in_use -|= 1;
    }

    pub fn available(self: *const HardwareBudget) usize {
        return self.limit -| self.in_use;
    }

    pub fn setLimit(self: *HardwareBudget, limit: usize) void {
        self.limit = @max(limit, min_limit);
    }
};

pub const DecidedBackend = enum { hardware, software };

pub const Decision = struct {
    backend: DecidedBackend,
    /// 仅对 `auto` 有意义：true 表示"本来能用硬解，但名额满了"。
    /// 用它把"溢出"与"格式不支持"在上报里区分开。
    hardware_saturated: bool = false,
};

/// `auto` 的决策：白名单 → 名额 → 硬解；任一不满足则软解。
///
/// 成功拿到硬解时**已经占用了名额**，调用方必须在重新 open 前、open 中途失败时、
/// 以及销毁时释放（漏一处就会永久饿死后续通道）。
pub fn decideAuto(platform: Platform, codec: CodecClass, budget: *HardwareBudget) Decision {
    if (!isHardwareSupported(platform, codec)) {
        // 格式兜底：不是"硬解失败"，是这个平台的后端根本没实现它。
        return .{ .backend = .software };
    }
    if (!budget.tryAcquire()) {
        return .{ .backend = .software, .hardware_saturated = true };
    }
    return .{ .backend = .hardware };
}

/// 按档位决策。`hardware` 档会无条件占用名额；`software` 档不碰名额。
pub fn decide(choice: DecoderChoice, platform: Platform, codec: CodecClass, budget: *HardwareBudget) Decision {
    return switch (choice) {
        .software => .{ .backend = .software },
        .hardware => blk: {
            budget.acquireForced();
            break :blk .{ .backend = .hardware };
        },
        .auto => decideAuto(platform, codec, budget),
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "越界的档位值返回 null（调用方保持原值）" {
    try testing.expectEqual(DecoderChoice.auto, DecoderChoice.fromInt(0).?);
    try testing.expectEqual(DecoderChoice.software, DecoderChoice.fromInt(2).?);
    try testing.expect(DecoderChoice.fromInt(99) == null);
    try testing.expect(DecoderChoice.fromInt(-1) == null);
}

test "硬解白名单与三个后端的实现一致" {
    try testing.expect(isHardwareSupported(.macos, .h264));
    try testing.expect(!isHardwareSupported(.macos, .hevc)); // ffvt 只做 H.264
    try testing.expect(isHardwareSupported(.windows, .hevc));
    try testing.expect(isHardwareSupported(.linux, .hevc));
    try testing.expect(!isHardwareSupported(.windows, .av1));
    try testing.expect(!isHardwareSupported(.other, .h264));
}

test "auto：编码不在白名单时走软解，且不算名额溢出" {
    var budget = HardwareBudget.init(4);
    const d = decideAuto(.macos, .hevc, &budget);
    try testing.expectEqual(DecidedBackend.software, d.backend);
    try testing.expect(!d.hardware_saturated); // 是格式不支持，不是名额满
    try testing.expectEqual(@as(usize, 0), budget.in_use);
}

test "auto：白名单内且有名额时走硬解并占用名额" {
    var budget = HardwareBudget.init(4);
    const d = decideAuto(.windows, .h264, &budget);
    try testing.expectEqual(DecidedBackend.hardware, d.backend);
    try testing.expectEqual(@as(usize, 1), budget.in_use);
}

test "auto：名额满时溢出到软解并如实标记" {
    var budget = HardwareBudget.init(1);
    try testing.expectEqual(DecidedBackend.hardware, decideAuto(.windows, .h264, &budget).backend);
    const second = decideAuto(.windows, .h264, &budget);
    try testing.expectEqual(DecidedBackend.software, second.backend);
    try testing.expect(second.hardware_saturated); // 是名额满，不是格式不支持
    try testing.expectEqual(@as(usize, 1), budget.in_use);
}

test "释放名额后新的通道能重新拿到硬解" {
    var budget = HardwareBudget.init(1);
    _ = decideAuto(.windows, .h264, &budget);
    budget.release();
    try testing.expectEqual(@as(usize, 0), budget.in_use);
    try testing.expectEqual(@as(usize, 1), budget.available());
    try testing.expectEqual(DecidedBackend.hardware, decideAuto(.windows, .h264, &budget).backend);
}

test "hardware 档无视名额：允许超额且不降级" {
    var budget = HardwareBudget.init(1);
    const d = decide(.hardware, .linux, .hevc, &budget);
    try testing.expectEqual(DecidedBackend.hardware, d.backend);
    // 再要一个：仍然给硬解（显式指令优先），计数保持诚实。
    const d2 = decide(.hardware, .linux, .hevc, &budget);
    try testing.expectEqual(DecidedBackend.hardware, d2.backend);
    try testing.expectEqual(@as(usize, 2), budget.in_use);
    try testing.expectEqual(@as(usize, 0), budget.available());
}

test "hardware 档即使格式不在白名单也不降级（只由 open 结果决定成败）" {
    var budget = HardwareBudget.init(4);
    const d = decide(.hardware, .macos, .av1, &budget);
    try testing.expectEqual(DecidedBackend.hardware, d.backend);
}

test "software 档不占名额" {
    var budget = HardwareBudget.init(4);
    const d = decide(.software, .windows, .h264, &budget);
    try testing.expectEqual(DecidedBackend.software, d.backend);
    try testing.expectEqual(@as(usize, 0), budget.in_use);
}

test "名额下限被钳到 1，设为 0 被忽略" {
    var budget = HardwareBudget.init(0);
    try testing.expectEqual(HardwareBudget.min_limit, budget.limit);
    budget.setLimit(0);
    try testing.expectEqual(HardwareBudget.min_limit, budget.limit);
    budget.setLimit(3);
    try testing.expectEqual(@as(usize, 3), budget.limit);
}

test "重复释放不会回绕（饱和减法）" {
    var budget = HardwareBudget.init(2);
    budget.release();
    budget.release();
    try testing.expectEqual(@as(usize, 0), budget.in_use);
    // 回绕的话这里会变成一个巨大的数，后续通道再也拿不到硬解。
    try testing.expect(budget.tryAcquire());
}
