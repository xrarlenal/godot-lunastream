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
const RefCounted = godot.class.RefCounted;
const VideoStream = godot.class.VideoStream;
const VideoStreamPlayback = godot.class.VideoStreamPlayback;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;

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
    class.addMethod("release_creator_ref", .auto);
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

/// 交还创建期持有的那份引用（修 0022：实例泄漏）。
///
/// gdzig 的约定是"创建方持有一份引用"（见 `variant.zig` 的注释），但走 Godot 的
/// `ClassDB.instantiate` 创建扩展类时，引擎自己还会加一份，引用计数停在 2 ——
/// 脚本那份释放后还剩 1，对象永不销毁。
///
/// **时序是这件事的关键**：引擎的引用要等 `ClassDB.instantiate` 返回之后才加上，
/// 而 `POSTINITIALIZE` 早于它（在创建回调链内部直接 unreference 会让计数归零、
/// 对象被销毁，表现为 Godot 挂死——这是实测过的，见功能文档）。
/// 所以这里只安排一次延迟调用，真正交还发生在引擎引用就位之后。
pub fn _notification(self: *LunaVideoStream, what: i32, reversed: bool) void {
    _ = reversed;
    if (what == Object.NOTIFICATION_POSTINITIALIZE) {
        _ = self.base.callDeferred(StringName.fromLatin1("release_creator_ref", false), .{});
    }
}

/// 由上面的 deferred 调用触发：此时引擎已持有自己的引用，可以安全交还创建方那份。
pub fn releaseCreatorRef(self: *LunaVideoStream) void {
    _ = RefCounted.upcast(self.base).unreference();
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
