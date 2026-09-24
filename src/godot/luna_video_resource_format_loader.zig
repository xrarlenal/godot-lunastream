//! `LunaVideoResourceFormatLoader`：让 `load("res://clip.mp4")` 直接得到一路视频源。
//!
//! 没有它，使用者必须先 `ClassDB.instantiate("LunaVideoStream")` 再手工赋 `file`
//! ——那是"能跑但不像 API"（PLAN 5.3 的原话）。
//!
//! ## 注册时机（这一步踩过坑，写清楚）
//!
//! `ResourceLoader.add_resource_format_loader(s)` 必须在**类已经注册进引擎之后**调用。
//! 在 `extension.register()` 里直接调会同时得到两条报错：
//!
//! ```
//! ERROR: Cannot get class 'LunaVideoResourceFormatLoader'.
//! ERROR: Failed to retrieve non-existent singleton 'ResourceLoader'.
//! ```
//!
//! 前者是"我要交给引擎的对象，它的类还没注册"；后者是 gdzig 在那个时点还没拿到
//! `ResourceLoader` 单例（`globalGetSingleton` 返回空，而调用点用 `.?` 硬解）。
//!
//! 正确做法是走 gdzig 的**分级回调**：`registry.addCallbacks(LoaderLifecycle, ...)`，
// 它的 `.scene` 级回调在"本级的类注册完成之后"触发（见 gdzig 的 `Registry.enter`）。
//! 源工程同样是这么做的（它们的 `LoaderLifecycle`）。
//!
//! ## 关于 URL
//!
//! **网络 URL 不走加载器**：`rtsp://` / `udp://` / http 由使用者直接设 `file`——这正是
//! Godot 官方对 `VideoStream.file` 的定义（"The video file path **or URI** that this
//! VideoStream resource handles"）。加载器只解决"工程内的媒体文件"这一半。

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const ResourceFormatLoader = godot.class.ResourceFormatLoader;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const PackedStringArray = godot.builtin.PackedStringArray;
const Variant = godot.builtin.Variant;

const LunaVideoStream = @import("luna_video_stream.zig").LunaVideoStream;

const LunaVideoResourceFormatLoader = @This();

/// 认识的容器扩展名。列表按"FFmpeg 能解封装 + 软解能出帧"来列：容器不是瓶颈
/// （ffsw 走 libavformat），真正的限制在编码（h264/hevc/mpeg4/vp9/av1/mjpeg）。
const recognized_extensions = [_][:0]const u8{
    "mp4", "mov",  "m4v", "mkv",  "webm", "ts",   "m2ts", "mpg",
    "mpeg", "avi", "flv", "wmv",  "mp2",  "mpg2",
};

allocator: Allocator,
base: *ResourceFormatLoader,

pub fn register(r: *Registry) void {
    r.addClass(LunaVideoResourceFormatLoader, r.allocator, .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(LunaVideoResourceFormatLoader);
}

pub fn create(allocator: *Allocator) !*LunaVideoResourceFormatLoader {
    const self = try allocator.create(LunaVideoResourceFormatLoader);
    self.* = .{ .allocator = allocator.*, .base = .init() };
    self.base.setInstance(LunaVideoResourceFormatLoader, self);
    return self;
}

pub fn destroy(self: *LunaVideoResourceFormatLoader, allocator: *Allocator) void {
    self.base.destroy();
    allocator.destroy(self);
}

/// 分级生命周期：在 `.scene` 级把加载器交给引擎（此时类已注册、单例已存在）。
pub const LoaderLifecycle = struct {
    allocator: Allocator,
    loader: ?*LunaVideoResourceFormatLoader = null,

    pub fn enter(self: *LoaderLifecycle, level: godot.extension.InitializationLevel) void {
        if (level != .scene) return;
        const loader = LunaVideoResourceFormatLoader.create(&self.allocator) catch return;
        self.loader = loader;
        ResourceLoader.addResourceFormatLoader(loader.base, .{});
    }

    pub fn exit(self: *LoaderLifecycle, level: godot.extension.InitializationLevel) void {
        if (level != .scene) return;
        if (self.loader) |loader| {
            ResourceLoader.removeResourceFormatLoader(loader.base);
            // 交还创建期那份引用；引擎在 remove 时已经放掉它自己那份。
            if (loader.base.unreference()) loader.base.destroy();
            self.loader = null;
        }
    }
};

const ResourceLoader = godot.class.ResourceLoader;

pub fn _getRecognizedExtensions(self: *LunaVideoResourceFormatLoader) PackedStringArray {
    _ = self;
    var extensions = PackedStringArray.init();
    inline for (recognized_extensions) |ext| {
        var text = String.fromLatin1(ext);
        defer text.deinit();
        _ = extensions.pushBack(text);
    }
    return extensions;
}

pub fn _handlesType(self: *LunaVideoResourceFormatLoader, type_name: StringName) bool {
    _ = self;
    var text = String.fromStringName(type_name);
    defer text.deinit();
    var buf: [128]u8 = undefined;
    const name = text.toUtf8Buf(buf[0..]);
    return std.mem.eql(u8, name, "VideoStream") or std.mem.eql(u8, name, "LunaVideoStream");
}

pub fn _getResourceType(self: *LunaVideoResourceFormatLoader, path: String) String {
    _ = self;
    var ext = path.getExtension();
    defer ext.deinit();
    var lower = ext.toLower();
    defer lower.deinit();
    var buf: [16]u8 = undefined;
    const text = lower.toUtf8Buf(buf[0..]);
    inline for (recognized_extensions) |known| {
        if (std.mem.eql(u8, text, known)) return String.fromLatin1("LunaVideoStream");
    }
    return String.empty;
}

/// 只记下路径：真正的打开推迟到播放实现被创建时（`_instantiatePlayback`），
/// 这样"在编辑器里加载资源"不会顺手把摄像头的连接占上。
pub fn _load(
    self: *LunaVideoResourceFormatLoader,
    path: String,
    original_path: String,
    use_sub_threads: bool,
    cache_mode: i32,
) Variant {
    _ = original_path;
    _ = use_sub_threads;
    _ = cache_mode;
    const stream = LunaVideoStream.create(&self.allocator) catch return Variant.nil;
    stream.base.setFile(path);
    return Variant.init(*LunaVideoStream, stream);
}
