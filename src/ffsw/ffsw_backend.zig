//! `core.backend.Backend` 的 ffsw 实现：把 C ABI（`ffsw_shim.h`）映射成 core 的解码
//! 后端接口，让解码调度器（0007）与 worker 池完全不必知道背后是 FFmpeg。
//!
//! 这一层刻意做得极薄：它只做三件事——转发调用、把 C 的帧结构翻译成
//! `core.backend.VideoFrame`、把"归还槽位"接到 `release_hook` 上。
//!
//! 为什么归还必须走 release_hook：shim 里帧的存储是**槽位环**（12 槽，稳定态零分配），
//! 消费者不归还就会把环用干、那条流停帧（这是 0010 刻意设计成可复现的现象）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("core");
const Backend = core.backend.Backend;
const VideoFrame = core.backend.VideoFrame;
const VoidClosure = core.closure.VoidClosure;

pub const shim = @cImport({
    @cInclude("ffsw_shim.h");
});

pub const FfswBackend = struct {
    handle: *shim.nv_ffsw_backend,

    pub fn init() !FfswBackend {
        const handle = shim.nv_ffsw_create() orelse return error.OutOfMemory;
        // 默认 5 秒读写超时：实时源死掉时要能收场（0010 的实测结论）。
        shim.nv_ffsw_set_io_timeout_us(handle, 5_000_000);
        return .{ .handle = handle };
    }

    pub fn backend(self: *FfswBackend) Backend {
        return .{ .ptr = self, .vtable = &.{
            .open = openFn,
            .close = closeFn,
            .deinit = deinitFn,
            .duration_seconds = durationFn,
            .video_width = widthFn,
            .video_height = heightFn,
            .colorimetry = colorimetryFn,
            .next_video_frame = nextFrameFn,
        } };
    }
};

fn selfFrom(ptr: *anyopaque) *FfswBackend {
    return @ptrCast(@alignCast(ptr));
}

fn openFn(ptr: *anyopaque, url_or_path: []const u8) bool {
    const self = selfFrom(ptr);
    // C 侧要 C 字符串：这里用栈上缓冲，路径/URL 超过 4 KiB 直接判失败（比截断安全）。
    var buf: [4096]u8 = undefined;
    if (url_or_path.len + 1 > buf.len) return false;
    @memcpy(buf[0..url_or_path.len], url_or_path);
    buf[url_or_path.len] = 0;
    const result = shim.nv_ffsw_open(self.handle, @ptrCast(&buf), null);
    return result == shim.NV_FFSW_OK;
}

fn closeFn(ptr: *anyopaque) void {
    shim.nv_ffsw_close(selfFrom(ptr).handle);
}

fn deinitFn(ptr: *anyopaque) void {
    const self = selfFrom(ptr);
    shim.nv_ffsw_destroy(self.handle);
}

fn durationFn(ptr: *anyopaque) f64 {
    return shim.nv_ffsw_duration_seconds(selfFrom(ptr).handle);
}

fn widthFn(ptr: *anyopaque) i32 {
    return shim.nv_ffsw_video_width(selfFrom(ptr).handle);
}

fn heightFn(ptr: *anyopaque) i32 {
    return shim.nv_ffsw_video_height(selfFrom(ptr).handle);
}

fn colorimetryFn(ptr: *anyopaque) core.backend.Colorimetry {
    const c = shim.nv_ffsw_colorimetry_of(selfFrom(ptr).handle);
    return .{
        .matrix = @enumFromInt(@as(u8, @intCast(c.matrix))),
        .primaries = @enumFromInt(@as(u8, @intCast(c.primaries))),
        .transfer = @enumFromInt(@as(u8, @intCast(c.transfer))),
        .range = @enumFromInt(@as(u8, @intCast(c.range))),
        .bit_depth = c.bit_depth,
    };
}

/// 取下一帧。`null` 表示流结束或出错——这与 core 的 vtable 约定一致（`?VideoFrame`）。
fn nextFrameFn(ptr: *anyopaque) ?VideoFrame {
    const self = selfFrom(ptr);
    var frame: shim.nv_ffsw_video_frame = undefined;
    if (shim.nv_ffsw_next_video_frame(self.handle, &frame) != shim.NV_FFSW_OK) return null;
    if (frame.y == null or frame.uv == null) return null;

    return .{
        .pts_seconds = frame.pts_seconds,
        .width = frame.width,
        .height = frame.height,
        .pixel_format = if (frame.bit_depth > 8) .x420 else .nv12,
        .surface_kind = .cpu_nv12,
        .cpu = .{
            .y = frame.y,
            .uv = frame.uv,
            .y_stride = @intCast(frame.y_stride),
            .uv_stride = @intCast(frame.uv_stride),
            .bit_depth = @intCast(frame.bit_depth),
        },
        .color = .{
            .matrix = @enumFromInt(@as(u8, @intCast(frame.color.matrix))),
            .primaries = @enumFromInt(@as(u8, @intCast(frame.color.primaries))),
            .transfer = @enumFromInt(@as(u8, @intCast(frame.color.transfer))),
            .range = @enumFromInt(@as(u8, @intCast(frame.color.range))),
            .bit_depth = frame.color.bit_depth,
        },
        // 归还槽位：ctx 就是 shim 给的槽位句柄，函数指针无状态。
        .release_hook = .{ .ctx = frame.owner, .func = releaseOwner },
    };
}

fn releaseOwner(owner: ?*anyopaque) void {
    shim.nv_ffsw_frame_release(owner);
}
