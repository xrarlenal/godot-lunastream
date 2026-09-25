//! `LunaVideoStream` —— 继承 Godot 的 `VideoStream`，而不是自造节点类型。
//!
//! 这样 `VideoStreamPlayer` 的一切行为（播放、暂停、纹理获取）都是白拿的，
//! 用户代码也不必为一个视频源多挂一层节点。Godot 官方文档里 `VideoStream.file`
//! 的说明原文就是 "The video file path **or URI** that this VideoStream resource
//! handles"——引擎自己就为网络流留了位置。
//!
//! 本步（0003）的边界：只证明"类能注册、属性与方法的绑定能用"。
//! `_instantiate_playback()` 返回 null，真正的播放实现落在 VideoStream 集成那一步。

/// 公开类型名：播放实现要能命名它（两者是双向引用的关系）。类名仍来自**文件名**
/// （gdzig 取 `@typeName` 的短名），所以这里加 `pub` 不影响注册出来的 Godot 类名。
pub const LunaVideoStream = @This();

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
const Dictionary = godot.builtin.Dictionary;
const Variant = godot.builtin.Variant;
const Texture2d = godot.class.Texture2d;

const core = @import("core");
const LunaVideoStreamPlayback = @import("luna_video_stream_playback.zig");

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
/// 这一步只做"存储 + 绑定"——先确认枚举属性在 GDScript 侧读写正常，
/// 真正的决策逻辑（含硬解名额预算）由后端选择器那一步接线。
decoder_choice: i64 = 0,

/// 最近一次交给 VideoStreamPlayer 的播放实例（诊断用）。
/// 它是**借来的指针**：真正的所有权在引擎那边，播放实例销毁时会把它清成 null
///（见 LunaVideoStreamPlayback.destroy），所以这里读之前先判空、并且只读它的计数。
last_playback: ?*LunaVideoStreamPlayback = null,

// ---------------------------------------------------------------------------
// 注册
// ---------------------------------------------------------------------------

pub fn register(r: *Registry) void {
    const class = r.createClass(LunaVideoStream, r.allocator, .auto);
    class.addMethod("ping", .auto);
    class.addMethod("release_creator_ref", .auto);
    // 诊断入口：自检脚本通过流来问"最近一路流呈现了多少帧 / 有没有报错"。
    // 为什么不问 VideoStreamPlayer：Godot 4.6 没有暴露 get_stream_playback()。
    class.addMethod("get_frames_presented", .auto);
    class.addMethod("get_last_error", .auto);
    // 0020：纹理直给。`stream.get_texture()` 拿到的就是呈现管线那块**稳定**的输出纹理，
    // 于是 3D 用户可以直接 `material.set_shader_parameter("video", stream.get_texture())`，
    // 不必为了拿纹理先往场景树里放一个 Control。
    class.addMethod("get_texture", .auto);
    // 0019：状态与统计（把 GDScript 里那 150 行样板搬进扩展的那一半）。
    class.addMethod("get_state", .auto);
    class.addMethod("get_stats", .auto);
    class.addMethod("emit_state_changed", .auto);
    class.addMethod("emit_frame_ready", .auto);
    class.addMethod("emit_stats_updated", .auto);
    // 0019：把重连/停滞的可调参数暴露出来。**刻意用方法而不是属性**：gdzig 的属性
    // 注册要求 getter/setter 命名严格配对（`prop` → `setProp` / `getProp`），
    // 方法名是我们自己定的、语义更直白，也不会因为命名约定变化而静默失效。
    class.addMethod("set_stall_timeout_ms", .auto);
    class.addMethod("get_stall_timeout_ms", .auto);
    class.addMethod("set_reconnect_max_attempts", .auto);
    class.addMethod("get_reconnect_max_attempts", .auto);
    class.addMethod("set_reconnect_backoff_max_ms", .auto);
    class.addMethod("get_reconnect_backoff_max_ms", .auto);
    // 0023 的接线：输出档位（SDR 默认；HDR 时按帧的传输函数做 PQ/HLG → SDR 的映射）。
    class.addMethod("set_output_mode", .auto);
    class.addMethod("get_output_mode", .auto);
    // 信号的名字来自**结构体名**（gdzig 用 casez 的 signal 规则转换），字段就是参数。
    class.addSignal(StateChanged);
    class.addSignal(FrameReady);
    class.addSignal(StatsUpdated);
    class.addProperty("decoder", .{
        .hint = .property_hint_enum,
        .hint_string = String.fromLatin1("auto,hardware,software"),
    });
}

// ---------------------------------------------------------------------------
// 信号（0019）
//
// 为什么信号挂在**流**上：GDScript 用户手里拿的是流（放进 VideoStreamPlayer 的那个
// 资源），而播放实现是引擎内部创建的——所以状态变化由播放实现回调到流，再从这里发出。
// ---------------------------------------------------------------------------

/// `state_changed(state)`：状态机每次迁移都发一次（IDLE/OPENING/PLAYING/STALLED/
/// FAILED/OFF，数值与 core.playback_state.State 一致）。
pub const StateChanged = struct { state: i64 };
/// `frame_ready()`：新的一帧被呈现（首帧与后续每帧都会发）。
pub const FrameReady = struct {};
/// `stats_updated(stats)`：低频（约 1 Hz）推送一份统计。
pub const StatsUpdated = struct { stats: Dictionary };

pub fn emitStateChanged(self: *LunaVideoStream, state: i64) void {
    _ = self.base.call(StringName.fromLatin1("emit_signal", true), .{
        Variant.init(String, String.fromLatin1("state_changed")),
        Variant.init(i64, state),
    });
}

pub fn emitFrameReady(self: *LunaVideoStream) void {
    _ = self.base.call(StringName.fromLatin1("emit_signal", true), .{
        Variant.init(String, String.fromLatin1("frame_ready")),
    });
}

pub fn emitStatsUpdated(self: *LunaVideoStream, stats: Dictionary) void {
    _ = self.base.call(StringName.fromLatin1("emit_signal", true), .{
        Variant.init(String, String.fromLatin1("stats_updated")),
        Variant.init(Dictionary, stats),
    });
}

/// 当前状态（与 core 的 State 数值一致）。
pub fn getState(self: *LunaVideoStream) i64 {
    if (self.last_playback) |playback| return playback.currentState();
    return 0; // idle
}

/// 一份统计快照。使用者不必自己拼状态机——这是 0019 的目标。
pub fn getStats(self: *LunaVideoStream) Dictionary {
    if (self.last_playback) |playback| return playback.buildStats();
    return Dictionary.init();
}

/// 0020：呈现管线那块稳定输出纹理。没有在播时返回 null。
pub fn getTexture(self: *LunaVideoStream) ?*Texture2d {
    if (self.last_playback) |playback| return playback.getTexture();
    return null;
}

// ---------------------------------------------------------------------------
// 0019 的可调参数（写进 core 状态机的 Policy）
// ---------------------------------------------------------------------------

pub fn setStallTimeoutMs(self: *LunaVideoStream, ms: i64) void {
    if (self.last_playback) |playback| playback.machine.policy.stall_after_ms = ms;
}

pub fn getStallTimeoutMs(self: *LunaVideoStream) i64 {
    if (self.last_playback) |playback| return playback.machine.policy.stall_after_ms;
    return 2000;
}

pub fn setReconnectMaxAttempts(self: *LunaVideoStream, attempts: i64) void {
    if (attempts < 0) return;
    if (self.last_playback) |playback| {
        playback.machine.policy.max_attempts = @intCast(attempts);
    }
}

pub fn getReconnectMaxAttempts(self: *LunaVideoStream) i64 {
    if (self.last_playback) |playback| return @intCast(playback.machine.policy.max_attempts);
    return 8;
}

pub fn setReconnectBackoffMaxMs(self: *LunaVideoStream, ms: i64) void {
    if (ms <= 0) return;
    if (self.last_playback) |playback| playback.machine.policy.backoff_max_ms = ms;
}

pub fn getReconnectBackoffMaxMs(self: *LunaVideoStream) i64 {
    if (self.last_playback) |playback| return playback.machine.policy.backoff_max_ms;
    return 8000;
}

/// 0 = SDR（默认），1 = HDR。非法值被忽略（保持上一个合法值）。
pub fn setOutputMode(self: *LunaVideoStream, mode: i64) void {
    if (mode != 0 and mode != 1) return;
    if (self.last_playback) |playback| playback.output_mode = mode;
}

pub fn getOutputMode(self: *LunaVideoStream) i64 {
    if (self.last_playback) |playback| return playback.output_mode;
    return 0;
}

/// 最近一路流已经呈现的帧数；没有播放实例时是 0。
pub fn getFramesPresented(self: *LunaVideoStream) i64 {
    if (self.last_playback) |playback| return playback.getFramesPresented();
    return 0;
}

/// 最近一路流的错误文本；没有播放实例时是空串。
pub fn getLastError(self: *LunaVideoStream) String {
    if (self.last_playback) |playback| return playback.getLastError();
    return String.fromUtf8("") catch String.empty;
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
    // 双向引用的另一半：流先被释放时，必须把播放实例里指回来的那个指针清掉，
    // 否则播放实例后来销毁时会对着一块已经释放的内存写 null（实测直接 ABRT）。
    if (self.last_playback) |playback| {
        playback.owner_stream = null;
        self.last_playback = null;
    }
    // 这里**不能**写 `self.base.destroy()`（源工程与 gdzig 的示例都是这么写的）。
    //
    // 原因：gdzig 为具体类生成的 `destroy` 带一层守卫——
    //     if (destroy_meta.engine_destroying) return;   // 引擎正在销毁 → 直接返回
    //     raw.objectDestroy(self.ptr());
    // 而销毁回调 `destroyImpl` 在调用我们之前就把 `engine_destroying` 置了 true。
    // 于是 `base.destroy()` 会直接 return，`raw.objectDestroy` 永远不执行，
    // 请求引擎释放对象这件事从未发生——对象留在 ObjectDB 里，退出时报实例泄漏。
    //
    // `Object` 的 `destroy` 是无守卫的直通版本（class/Object.mixin.zig），
    // 正好是这里需要的：由我们负责把引擎对象真正删掉。
    Object.upcast(self.base).destroy();
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
        // is_static = true：这是编译期字面量，生命周期覆盖整个进程。
        // 传 false 等于声明"我自己负责析构"，而 gdzig 的注释写明静态字面量
        // 不该被析构——传错会在退出时报 "Orphan StringName"。
        _ = self.base.callDeferred(StringName.fromLatin1("release_creator_ref", true), .{});
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
    // 从基类拿 `file`（官方文档写明它可以是路径**或 URI**），交给播放实现去打开。
    const path_string = self.base.getFile();
    const path = path_string.toAsciiBuffer();
    if (path.size() <= 0) return null;

    const playback = LunaVideoStreamPlayback.create(&self.allocator) catch return null;
    playback.owner_stream = self;
    self.last_playback = playback;
    // 把 C 侧的字节转成切片：`toAsciiBuffer()` 出来的 PackedByteArray 去掉结尾的 0。
    const raw: [*]const u8 = @ptrFromInt(@intFromPtr(path.indexConst(0)));
    const len: usize = @intCast(path.size());
    const slice = if (len > 0 and raw[len - 1] == 0) raw[0 .. len - 1] else raw[0..len];
    if (!playback.load(slice)) {
        // 打开失败也要把对象交给引擎（它自己会显示"播放失败"），并把原因留在
        // get_last_error 里；返回 null 会让 VideoStreamPlayer 直接报错退出。
        return playback.base;
    }
    return playback.base;
}
