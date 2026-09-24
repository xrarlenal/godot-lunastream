//! `LunaVideoStream` —— 继承 Godot 的 `VideoStream`，而不是自造节点类型。
//!
//! 这样 `VideoStreamPlayer` 的一切行为（播放、暂停、纹理获取）都是白拿的，
//! 用户代码也不必为一个视频源多挂一层节点。Godot 官方文档里 `VideoStream.file`
//! 的说明原文就是 "The video file path **or URI** that this VideoStream resource
//! handles"——引擎自己就为网络流留了位置。
//!
//! 本步（0003）的边界：只证明"类能注册、属性与方法的绑定能用"。
//! `_instantiate_playback()` 返回 null，真正的播放实现落在 VideoStream 集成那一步。

const LunaVideoStream = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Object = godot.class.Object;
const VideoStream = godot.class.VideoStream;
const VideoStreamPlayback = godot.class.VideoStreamPlayback;
const String = godot.builtin.String;

const core = @import("core");

// ---------------------------------------------------------------------------
// 字段
//
// Zig 0.16 不允许声明夹在字段之间（"declarations are not allowed between
// container fields"），所以所有字段必须连续地放在最前面，函数一律写在后面。
// ---------------------------------------------------------------------------

allocator: Allocator,
base: *VideoStream,

/// 解码器策略：`auto` / `hardware` / `software`。
///
/// 这一步只落地"存储 + 绑定"——先确认枚举属性在 GDScript 侧读写正常，
/// 真正的决策逻辑（含硬解名额预算）由后端选择器那一步接线。
decoder_choice: i64 = 0,

// ---------------------------------------------------------------------------
// 注册
// ---------------------------------------------------------------------------

pub fn register(r: *Registry) void {
    const class = r.createClass(LunaVideoStream, r.allocator, .auto);
    class.addMethod("ping", .auto);
    class.addProperty("decoder", .{
        .hint = .property_hint_enum,
        .hint_string = String.fromLatin1("auto,hardware,software"),
    });
}

pub fn unregister(r: *Registry) void {
    r.removeClass(LunaVideoStream);
}

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

pub fn create(allocator: *Allocator) !*LunaVideoStream {
    const self = try allocator.create(LunaVideoStream);
    self.* = .{
        .allocator = allocator.*,
        .base = .init(),
    };
    self.base.setInstance(LunaVideoStream, self);
    return self;
}

/// 引擎侧已经存在的对象（例如从 .tres 恢复出来）绑定回 Zig 结构。
pub fn recreate(allocator: *Allocator, obj: *Object) *LunaVideoStream {
    const self = allocator.create(LunaVideoStream) catch @panic("OOM");
    self.* = .{
        .allocator = allocator.*,
        .base = @ptrCast(obj),
    };
    self.base.setInstance(LunaVideoStream, self);
    return self;
}

pub fn destroy(self: *LunaVideoStream, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

/// 自检用：返回插件标识与版本，用来证明"扩展已加载、类可实例化、方法绑定可用"。
pub fn ping(self: *LunaVideoStream) String {
    _ = self;
    return String.fromLatin1("lunastream/" ++ core.version);
}

/// 越界值被忽略，保持上一个合法值——脚本传错值时不该把通道卡在一个未定义状态。
pub fn setDecoder(self: *LunaVideoStream, mode: i64) void {
    if (mode < 0 or mode > 2) return;
    self.decoder_choice = mode;
}

pub fn getDecoder(self: *LunaVideoStream) i64 {
    return self.decoder_choice;
}

/// `VideoStream` 的必填虚函数。
///
/// 本步返回 null：类可实例化、绑定可用是这一步要证明的事；播放实现见
/// docs/ROADMAP.md 的"VideoStream / VideoStreamPlayback / 资源加载器"。
pub fn _instantiatePlayback(self: *LunaVideoStream) ?*VideoStreamPlayback {
    _ = self;
    return null;
}
