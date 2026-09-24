//! core 模块根：与 Godot 无关的纯逻辑。
//!
//! 这一层不引用任何 Godot 或平台 SDK 类型，因此它的单元测试不需要引擎、
//! 不需要 GPU、也不需要在目标平台上跑——`zig build test` 在任何机器上都能验证。
//! 解码后端与呈现导入器都以这一层为契约。

const std = @import("std");

/// 语义化版本，与仓库 tag 同步。
pub const version = "0.0.0";

pub const clock = @import("clock.zig");
pub const frame_queue = @import("frame_queue.zig");
pub const closure = @import("closure.zig");
pub const retire_ring = @import("retire_ring.zig");
pub const present_selector = @import("present_selector.zig");
pub const color = @import("color.zig");
pub const sys_clock = @import("sys_clock.zig");
pub const backend = @import("backend.zig");
pub const decode_scheduler = @import("decode_scheduler.zig");
pub const playback_state = @import("playback_state.zig");

test "core 模块可以编译并被引用" {
    try std.testing.expect(version.len > 0);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("decode_scheduler_test.zig");
}
