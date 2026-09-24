//! GDExtension 入口。
//!
//! gdzig 生成的 entrypoint 会在引擎各初始化级别调用这里的 `register()` /
//! `unregister()`。入口符号名由 build.zig 的 `entry_symbol` 指定
//! （当前为 `lunastream_init`），必须与 `lunastream.gdextension` 里写的一致。

const std = @import("std");

const godot = @import("godot");
const Registry = godot.extension.Registry;

const LunaVideoStream = @import("luna_video_stream.zig");
const LunaSelfTest = @import("luna_self_test.zig");

const builtin = @import("builtin");

comptime {
    // 平台导入器只在各自的目标上参与编译。它们是 0016 / 0017 的载体，从源工程
    // 搬入，尚未在本仓库的真机上验证（见 docs/platform-port.md）。放在 comptime
    // 里引用是为了让"交叉编译能不能过"成为一条真实可跑的检查，而不是靠人记得手动编。
    if (builtin.os.tag == .windows) {
        _ = @import("windows_surface_importer.zig");
        _ = @import("platform_importer_adapter.zig");
    } else if (builtin.os.tag == .linux) {
        _ = @import("vulkan_surface_importer.zig");
        _ = @import("platform_importer_adapter.zig");
    } else if (builtin.os.tag == .macos) {
        // 解码后端 ffsw（C shim + core 后端适配器）：引擎里真正解码走的就是它。
        _ = @import("ffsw");
    }
}

pub fn register(r: *Registry) void {
    r.addModule(LunaVideoStream);
    r.addModule(LunaSelfTest);
}

pub fn unregister(r: *Registry) void {
    r.removeModule(LunaSelfTest);
    r.removeModule(LunaVideoStream);
}
