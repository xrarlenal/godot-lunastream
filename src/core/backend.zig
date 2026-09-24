//! 解码后端接口：worker 池与平台解码器之间的契约。
//!
//! 形状是 ptr + vtable（与 `std.mem.Allocator` 同构），因此调度器不需要知道
//! 背后是 VideoToolbox、D3D11VA、VAAPI 还是 FFmpeg 软解。测试用假后端只需实现
//! 这张表，就能在没有 GPU、没有摄像头的机器上验证调度逻辑。
//!
//! ## 与源工程的差异（video-only）
//!
//! 源工程的接口还包含音频（`audio_track_*` / `next_audio_chunk`）与 seek。
//! 本插件的后端（ffvt / ffd3d / ffva / ffsw）只解视频，直播流也没有 seek 语义，
//! 所以这两组方法没有进来。若将来迁入带音频的本地文件路径，它们会作为独立
//! 功能点补上，而不是现在预埋。

const std = @import("std");
const color = @import("color.zig");
const VoidClosure = @import("closure.zig").VoidClosure;

/// 解码表面类型。
pub const PixelFormat = enum(u8) {
    unknown = 0,
    /// YUV 4:2:0 半平面，8-bit（亮度平面 + 交织 UV 平面）。
    nv12,
    /// YUV 4:2:0 半平面，10-bit（16-bit 容器：R16 + RG16）。
    x420,
    /// 打包 BGRA，8bpc——软解回退用。
    bgra8,
};

/// 解码帧的像素在哪里。
pub const SurfaceKind = enum(u8) {
    /// GPU 常驻句柄（CVPixelBuffer / ID3D11Texture2D / dma-buf），
    /// 由平台导入器零拷贝别名进 RenderingDevice。
    native_surface = 0,
    /// 普通系统内存里的 NV12，由后端拥有，用 `CpuPlanes` 描述。
    /// 没有系统句柄可以别名，因此必然有一次 CPU→GPU 上传。
    cpu_nv12 = 1,
};

/// `SurfaceKind.cpu_nv12` 帧的平面指针。
///
/// 布局与着色器从 GPU 表面拿到的一致：一张全分辨率亮度平面 + 一张半分辨率
/// 交织 CbCr 平面。行距可以大于平面宽度（行对齐），所以消费者必须逐行拷贝成
/// 紧凑缓冲再交给 `texture_update`。
pub const CpuPlanes = struct {
    y: ?[*]const u8 = null,
    uv: ?[*]const u8 = null,
    y_stride: u32 = 0,
    uv_stride: u32 = 0,
    bit_depth: u8 = 8, // 8 = u8 样本；10 = u16 样本
};

/// 解码表面里的显示区域（亮度像素计）。
///
/// 部分硬解器会把后备纹理按宏块对齐分配（例如宽 853 的内容解进宽 864 的纹理），
/// 真实显示尺寸另行上报，所以裁剪矩形必须随帧传递。
pub const CropRect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

/// 一帧的色域信息。全未指定时按 BT.709 视频范围处理（着色器侧的约定）。
pub const Colorimetry = struct {
    matrix: color.ColorMatrix = .unspecified,
    primaries: color.ColorPrimaries = .unspecified,
    transfer: color.TransferFunction = .unspecified,
    range: color.ColorRange = .video,
    bit_depth: i32 = 8,

    /// 协商得到的默认约定：BT.709 视频范围 8-bit。
    pub const bt709_defaults: Colorimetry = .{
        .matrix = .bt709,
        .primaries = .bt709,
        .transfer = .bt709,
        .range = .video,
        .bit_depth = 8,
    };
};

/// 一帧解码结果。
pub const VideoFrame = struct {
    /// 呈现时间戳（秒）。
    pts_seconds: f64 = 0.0,
    width: i32 = 0,
    height: i32 = 0,
    pixel_format: PixelFormat = .unknown,
    surface_kind: SurfaceKind = .native_surface,

    /// 平台原生句柄。含义由后端决定（CVPixelBuffer / ID3D11Texture2D /
    /// dma-buf 描述块），导入器与后端必须成对理解它。
    native_handle: ?*anyopaque = null,

    /// `surface_kind == .cpu_nv12` 时的平面描述。
    cpu: CpuPlanes = .{},

    /// 后备纹理里的有效显示区域。
    crop: CropRect = .{},

    /// 由解码器上报的色域信息。
    color: Colorimetry = .{},

    /// 消费者用完这帧后调用，让解码池回收表面。没有原生表面时为空闭包。
    release_hook: VoidClosure = .{},

    /// 消费者用完这帧时调用。
    pub fn release(self: VideoFrame) void {
        self.release_hook.call();
    }
};

/// 解码后端。每个入口都是必需的——测试用的假后端由测试自己补齐，
/// 不靠"默认实现"兜底，免得漏实现的方法在运行期才被发现。
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (*anyopaque, url_or_path: []const u8) bool,
        close: *const fn (*anyopaque) void,
        /// close + 释放实现本身。
        deinit: *const fn (*anyopaque) void,

        duration_seconds: *const fn (*anyopaque) f64,
        video_width: *const fn (*anyopaque) i32,
        video_height: *const fn (*anyopaque) i32,

        /// 整条流的协商色域。
        colorimetry: *const fn (*anyopaque) Colorimetry,

        /// 取下一帧；返回 null 表示流结束或出错。
        next_video_frame: *const fn (*anyopaque) ?VideoFrame,
    };

    pub fn open(self: Backend, url_or_path: []const u8) bool {
        return self.vtable.open(self.ptr, url_or_path);
    }
    pub fn close(self: Backend) void {
        self.vtable.close(self.ptr);
    }
    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
    pub fn durationSeconds(self: Backend) f64 {
        return self.vtable.duration_seconds(self.ptr);
    }
    pub fn videoWidth(self: Backend) i32 {
        return self.vtable.video_width(self.ptr);
    }
    pub fn videoHeight(self: Backend) i32 {
        return self.vtable.video_height(self.ptr);
    }
    pub fn colorimetry(self: Backend) Colorimetry {
        return self.vtable.colorimetry(self.ptr);
    }
    pub fn nextVideoFrame(self: Backend) ?VideoFrame {
        return self.vtable.next_video_frame(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "色域的默认值是全未指定 + 视频范围 + 8-bit" {
    const c: Colorimetry = .{};
    try testing.expectEqual(color.ColorMatrix.unspecified, c.matrix);
    try testing.expectEqual(color.ColorPrimaries.unspecified, c.primaries);
    try testing.expectEqual(color.TransferFunction.unspecified, c.transfer);
    try testing.expectEqual(color.ColorRange.video, c.range);
    try testing.expectEqual(@as(i32, 8), c.bit_depth);
}

test "协商默认值是 BT.709 视频范围" {
    const c = Colorimetry.bt709_defaults;
    try testing.expectEqual(color.ColorMatrix.bt709, c.matrix);
    try testing.expectEqual(color.ColorPrimaries.bt709, c.primaries);
    try testing.expectEqual(color.TransferFunction.bt709, c.transfer);
    try testing.expectEqual(color.ColorRange.video, c.range);
}

test "VideoFrame.release 调用释放闭包，空闭包安全" {
    var hits: i32 = 0;
    const Ctx = struct {
        fn bump(p: ?*anyopaque) void {
            const n: *i32 = @ptrCast(@alignCast(p.?));
            n.* += 1;
        }
    };

    const f: VideoFrame = .{ .release_hook = .{ .ctx = &hits, .func = Ctx.bump } };
    f.release();
    try testing.expectEqual(@as(i32, 1), hits);

    // 没有原生表面的帧（例如测试帧）用空闭包，release 不应崩。
    const empty: VideoFrame = .{};
    empty.release();
}

test "假后端可以通过 vtable 走完整条调用链" {
    const Fake = struct {
        frames_left: i32 = 2,
        closed: bool = false,
        freed: bool = false,

        fn open(_: *anyopaque, url: []const u8) bool {
            return std.mem.startsWith(u8, url, "rtsp://");
        }
        fn close(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.closed = true;
        }
        fn deinit(p: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.freed = true;
        }
        fn duration(_: *anyopaque) f64 {
            return 12.5;
        }
        fn width(_: *anyopaque) i32 {
            return 960;
        }
        fn height(_: *anyopaque) i32 {
            return 540;
        }
        fn colorimetryOf(_: *anyopaque) Colorimetry {
            return Colorimetry.bt709_defaults;
        }
        fn next(p: *anyopaque) ?VideoFrame {
            const self: *@This() = @ptrCast(@alignCast(p));
            if (self.frames_left <= 0) return null;
            self.frames_left -= 1;
            return .{ .pts_seconds = @floatFromInt(self.frames_left), .width = 960, .height = 540 };
        }

        const vtable: Backend.VTable = .{
            .open = open,
            .close = close,
            .deinit = deinit,
            .duration_seconds = duration,
            .video_width = width,
            .video_height = height,
            .colorimetry = colorimetryOf,
            .next_video_frame = next,
        };

        fn backend(self: *@This()) Backend {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    var fake: Fake = .{};
    const b = fake.backend();

    try testing.expect(b.open("rtsp://192.168.1.10/stream"));
    try testing.expect(!b.open("bogus"));
    try testing.expectEqual(@as(i32, 960), b.videoWidth());
    try testing.expectEqual(@as(i32, 540), b.videoHeight());
    try testing.expectEqual(@as(f64, 12.5), b.durationSeconds());
    try testing.expectEqual(color.ColorMatrix.bt709, b.colorimetry().matrix);

    var decoded: i32 = 0;
    while (b.nextVideoFrame()) |f| {
        decoded += 1;
        try testing.expectEqual(@as(i32, 960), f.width);
    }
    try testing.expectEqual(@as(i32, 2), decoded);

    b.close();
    try testing.expect(fake.closed);
    b.deinit();
    try testing.expect(fake.freed);
}
