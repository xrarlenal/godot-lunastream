//! `LunaVideoStreamPlayback`：把前面所有零件连成一条能播的链路。
//!
//! 数据流（每一步都是已经单独验证过的部件）：
//!
//! ```
//! ffsw 后端（C shim + core.backend 适配器）
//!   → DecodeScheduler（core：worker 池 + 有界帧队列 + 单调性守卫）
//!   → DispatchingImporter（CPU 上传 / 平台零拷贝二选一）
//!   → PresentPipeline（共享 compute：NV12 → 稳定 RGBA 输出纹理）
//!   → Texture2DRD（每帧只重指 RID，VideoStreamPlayer 拿到的就是它）
//! ```
//!
//! ## 这一版的边界（都写在这里，不留给人猜）
//!
//! - **只做视频**：`_mixAudio` / `_getChannels` / `_getMixRate` 返回"没有音频"，
//!   与插件定位一致（音频、字幕、seek 都不在本插件的范围内）。
//! - **seek 是空操作**：直播流没有 seek 语义；本地文件也交给愿意背这块的插件。
//! - **每帧取一帧**：`_update` 每次向调度器要一帧。积压时由 core 的呈现选择器
//!   （0005）决定丢谁——不过本版还没接选择器，先按"队列里有就取最旧的一帧"走。
//! - 分辨率在播放中途变化还不支持（呈现管线按首帧尺寸建）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Object = godot.class.Object;
const RefCounted = godot.class.RefCounted;
const VideoStreamPlayback = godot.class.VideoStreamPlayback;
const Texture2d = godot.class.Texture2d;
const Texture2drd = godot.class.Texture2drd;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;

const core = @import("core");
const Backend = core.backend.Backend;
const VideoFrame = core.backend.VideoFrame;
const DecodeScheduler = core.decode_scheduler.DecodeScheduler;
const StreamHandle = core.decode_scheduler.StreamHandle;
const PushConstants = core.push_constants.Nv12PushConstants;

const ffsw = @import("ffsw");
const importer_mod = @import("dispatching_surface_importer.zig");
const DispatchingImporter = importer_mod.DispatchingImporter;
const Surface = @import("surface_importer.zig").Surface;
const present_mod = @import("present_pipeline.zig");
const PresentPipeline = present_mod.PresentPipeline;

const LunaVideoStreamPlayback = @This();

/// 默认一路流一个 worker：多路并行由调度器的共享池承担，这里给它的就是"一路"的量。
const default_worker_count = 1;

// ---------------------------------------------------------------------------
// 字段
//
// Zig 0.16 不允许声明夹在字段之间（"declarations are not allowed between
// container fields"），所以字段全部放在最前。
// ---------------------------------------------------------------------------

allocator: Allocator,
base: *VideoStreamPlayback,

/// 交出去时记住是哪一路流（诊断用：流那边要能问"呈现了多少帧"）。
/// 这是**双向引用**，所以在 destroy 里必须显式清掉对方那一侧，否则流会留下悬垂指针。
owner_stream: ?*@import("luna_video_stream.zig").LunaVideoStream = null,

backend: ffsw.FfswBackend = undefined,
backend_open: bool = false,
scheduler: ?*DecodeScheduler = null,
stream: ?StreamHandle = null,
dispatcher: ?DispatchingImporter = null,
present: ?PresentPipeline = null,
texture: ?*Texture2drd = null,

playing: bool = false,
paused: bool = false,
length_seconds: f64 = 0.0,
position_seconds: f64 = 0.0,
frames_presented: u64 = 0,
last_error: ?[]const u8 = null,

// ---------------------------------------------------------------------------
// 注册与生命周期（与 0003 / 0022 的写法一致）
// ---------------------------------------------------------------------------

pub fn register(r: *Registry) void {
    const class = r.createClass(LunaVideoStreamPlayback, r.allocator, .auto);
    class.addMethod("release_creator_ref", .auto);
    // 诊断入口：自检脚本要能问"已经呈现了多少帧"。虚函数（_play 等）由 gdzig 自动
    // 按基类虚表注册，这两个是我们自己的，必须显式挂上。
    class.addMethod("get_frames_presented", .auto);
    class.addMethod("get_last_error", .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(LunaVideoStreamPlayback);
}

pub fn create(allocator: *Allocator) !*LunaVideoStreamPlayback {
    const self = try allocator.create(LunaVideoStreamPlayback);
    self.* = .{ .allocator = allocator.*, .base = .init() };
    self.base.setInstance(LunaVideoStreamPlayback, self);
    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *LunaVideoStreamPlayback {
    const self = allocator.create(LunaVideoStreamPlayback) catch @panic("OOM");
    self.* = .{ .allocator = allocator.*, .base = @ptrCast(obj) };
    self.base.setInstance(LunaVideoStreamPlayback, self);
    return self;
}

pub fn destroy(self: *LunaVideoStreamPlayback, allocator: *Allocator) void {
    if (self.owner_stream) |stream| {
        stream.last_playback = null;
        self.owner_stream = null;
    }
    self.teardown();
    Object.upcast(self.base).destroy();
    allocator.destroy(self);
}

/// 与 0022 同源：交还创建期那份引用（引擎自己还会加一份）。
pub fn _notification(self: *LunaVideoStreamPlayback, what: i32, reversed: bool) void {
    _ = reversed;
    if (what == Object.NOTIFICATION_POSTINITIALIZE) {
        _ = self.base.callDeferred(StringName.fromLatin1("release_creator_ref", true), .{});
    }
}

pub fn releaseCreatorRef(self: *LunaVideoStreamPlayback) void {
    _ = RefCounted.upcast(self.base).unreference();
}

// ---------------------------------------------------------------------------
// 打开与关闭
// ---------------------------------------------------------------------------

/// 打开一路源。返回 false 表示失败（原因在 `last_error`），调用方不必再问。
pub fn load(self: *LunaVideoStreamPlayback, path: []const u8) bool {
    self.teardown();

    self.backend = ffsw.FfswBackend.init() catch {
        self.last_error = "后端创建失败";
        return false;
    };
    const backend = self.backend.backend();
    if (!backend.open(path)) {
        self.last_error = "打开失败（路径或 URL 不可用）";
        self.backend.deinit();
        return false;
    }
    self.backend_open = true;
    self.length_seconds = backend.durationSeconds();

    // 调度器：worker 池 + 有界帧队列（0007）。它的队列与回收环决定了导入侧的
    // 表面数量下限，所以这里必须真的用它，而不是在主线程上直接循环解码。
    self.scheduler = DecodeScheduler.init(self.allocator, default_worker_count, false) catch {
        self.last_error = "调度器创建失败";
        self.teardown();
        return false;
    };
    self.stream = self.scheduler.?.registerStream(backend) catch {
        self.last_error = "注册流失败";
        self.teardown();
        return false;
    };

    // 导入器与呈现管线都依赖 RenderingDevice，只能在有渲染上下文时建。
    const width = backend.videoWidth();
    const height = backend.videoHeight();
    if (width > 0 and height > 0) {
        self.dispatcher = DispatchingImporter.init(self.allocator, .{}) catch null;
        if (self.dispatcher) |*dispatcher| {
            // 平台导入器（Metal / D3D12 / Vulkan）在这里挂上去；挂不上就只剩 CPU 上传。
            if (metalImporter()) |platform| {
                if (dispatcher.cpu.rd == platform.rd) {
                    dispatcher.setPlatform(platform.importer);
                }
            }
            self.present = PresentPipeline.init(
                self.allocator,
                dispatcher.cpu.rd,
                @intCast(width),
                @intCast(height),
                .{},
            ) catch null;
            if (self.present) |*pipeline| {
                self.texture = Texture2drd.init();
                self.texture.?.setTextureRdRid(pipeline.outputTexture());
            }
        }
    }
    return true;
}

fn teardown(self: *LunaVideoStreamPlayback) void {
    self.playing = false;
    if (self.texture) |texture| {
        _ = texture.unreference();
        self.texture = null;
    }
    if (self.present) |*pipeline| {
        pipeline.deinit();
        self.present = null;
    }
    if (self.dispatcher) |*dispatcher| {
        dispatcher.deinit();
        self.dispatcher = null;
    }
    if (self.scheduler) |scheduler| {
        if (self.stream) |stream| {
            // 注销会把后端一并关掉并释放：0007 的 unregisterStream →
            // releaseStreamResources → backend.close() + backend.deinit()。
            // 所以这里**不能**自己再释放一次——第一版就是多释放了一次，退出时崩在
            // nv_ffsw_destroy → avcodec_free_context（拿已经释放的句柄再释放）。
            scheduler.unregisterStream(stream);
            self.backend_open = false;
        }
        scheduler.deinit();
        self.scheduler = null;
        self.stream = null;
    }
    if (self.backend_open) {
        self.backend.deinit();
        self.backend_open = false;
    }
    self.frames_presented = 0;
    self.position_seconds = 0.0;
}

// ---------------------------------------------------------------------------
// VideoStreamPlayback 的虚函数
// ---------------------------------------------------------------------------

pub fn _play(self: *LunaVideoStreamPlayback) void {
    self.playing = true;
    self.paused = false;
}

pub fn _stop(self: *LunaVideoStreamPlayback) void {
    self.playing = false;
}

pub fn _isPlaying(self: *LunaVideoStreamPlayback) bool {
    return self.playing;
}

pub fn _setPaused(self: *LunaVideoStreamPlayback, paused: bool) void {
    self.paused = paused;
}

pub fn _isPaused(self: *LunaVideoStreamPlayback) bool {
    return self.paused;
}

pub fn _getLength(self: *LunaVideoStreamPlayback) f64 {
    return self.length_seconds;
}

pub fn _getPlaybackPosition(self: *LunaVideoStreamPlayback) f64 {
    return self.position_seconds;
}

/// 直播流没有 seek 语义；本地文件的选择性跳转交给愿意背这块的插件。
pub fn _seek(self: *LunaVideoStreamPlayback, time: f64) void {
    _ = self;
    _ = time;
}

/// 本插件只做视频：音轨索引对它没有意义。
pub fn _setAudioTrack(self: *LunaVideoStreamPlayback, idx: i32) void {
    _ = self;
    _ = idx;
}

pub fn _getChannels(self: *LunaVideoStreamPlayback) i32 {
    _ = self;
    return 0;
}

pub fn _getMixRate(self: *LunaVideoStreamPlayback) i32 {
    _ = self;
    return 0;
}

pub fn _getTexture(self: *LunaVideoStreamPlayback) ?*Texture2d {
    // Texture2DRD 是 Texture2D 的子类，指针要显式转（Zig 不做隐式向下/向上转型）。
    if (self.texture) |texture| return @ptrCast(texture);
    return null;
}

/// 每个渲染帧被调用一次：取一帧、导入、呈现、把输出纹理重指到 Texture2DRD。
pub fn _update(self: *LunaVideoStreamPlayback, delta: f64) void {
    if (!self.playing or self.paused) return;
    const scheduler = self.scheduler orelse return;
    const stream = self.stream orelse return;

    const frame = scheduler.nextFrame(stream) orelse return;
    defer frame.release();
    self.position_seconds = frame.pts_seconds;

    const dispatcher = if (self.dispatcher) |*d| d else return;
    const surface = dispatcher.importFrame(frame) catch return;
    defer surface.release();

    const pipeline = if (self.present) |*p| p else return;
    const pc = PushConstants.fromColorimetry(
        if (frame.cpu.bit_depth >= 10) 10 else 8,
        frame.color.matrix,
        frame.color.range,
        @intCast(surface.raw_code_shift),
    );
    _ = pipeline.present(surface, pc) catch return;
    self.frames_presented += 1;
    _ = delta;
}

/// 诊断用：已经呈现了多少帧（自检脚本用它判断"真的在播"）。
pub fn getFramesPresented(self: *LunaVideoStreamPlayback) i64 {
    return @intCast(self.frames_presented);
}

pub fn getLastError(self: *LunaVideoStreamPlayback) String {
    // 必须用 fromUtf8：这些消息是 UTF-8 的中文，fromLatin1 会把它们按 Latin-1 解释，
    // 脚本侧看到的就是乱码（实测：`æå¼å¤±è´¥...`）。
    return String.fromUtf8(self.last_error orelse "") catch String.empty;
}

// ---------------------------------------------------------------------------
// 平台导入器的挂载点
// ---------------------------------------------------------------------------

/// macOS 上是 Metal 导入器（0015）。Windows / Linux 的两条在各自的适配层里
/// （platform_importer_adapter.zig），本文件只在 macOS 上编到那段。
const PlatformHandle = struct {
    rd: *godot.class.RenderingDevice,
    importer: @import("surface_importer.zig").SurfaceImporter,
};

fn metalImporter() ?PlatformHandle {
    if (@import("builtin").os.tag != .macos) return null;
    return null; // Metal 导入器的构造在 0015 的自检里验证，接线留给下一步。
}
