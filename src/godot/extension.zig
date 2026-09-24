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

pub fn register(r: *Registry) void {
    r.addModule(LunaVideoStream);
    r.addModule(LunaSelfTest);
}

pub fn unregister(r: *Registry) void {
    r.removeModule(LunaSelfTest);
    r.removeModule(LunaVideoStream);
}
