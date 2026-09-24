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
const LunaVideoStreamPlayback = @import("luna_video_stream_playback.zig");
const LunaVideoResourceFormatLoader = @import("luna_video_resource_format_loader.zig");

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
    r.addModule(LunaVideoStreamPlayback);
    r.addModule(LunaVideoResourceFormatLoader);

    // 加载器交给引擎的时机**不能**在这里：类还没注册完（会报 Cannot get class），
    // 那时 gdzig 也还没拿到 ResourceLoader 单例。走分级回调，在 .scene 级做。
    r.addCallbacks(
        LunaVideoResourceFormatLoader.LoaderLifecycle,
        .{ .allocator = r.allocator },
        .{},
    );
}

pub fn unregister(r: *Registry) void {
    r.removeModule(LunaVideoStreamPlayback);
    r.removeModule(LunaSelfTest);
    r.removeModule(LunaVideoStream);
    r.removeModule(LunaVideoResourceFormatLoader);
}
