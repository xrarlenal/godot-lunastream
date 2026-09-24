//! 平台导入器 → 本仓库导入接口的适配层（0016 / 0017 的接缝）。
//!
//! 为什么要有这一层：Windows 与 Linux 的导入器是从源工程**逐字节搬来**的（见
//! docs/platform-port.md），它们说的是源工程的词汇表（`platform_surface.zig` 的
//! `ImportResult` / `PlaneTextures`）；而本仓库 0014 给呈现管线定的接口是
//! `surface_importer.Surface` / `Error`。把两千行已验证代码改写成另一套词汇表是
//! 没有收益的风险，所以在外面套这一层——**只有这个文件知道两套词汇表**。
//!
//! 最要紧的映射是失败分类：源工程的 `ImportResult` 把"暂时失败"与"能力不可用"分开，
//! 而只有后者允许选择器永久放弃这条零拷贝路径。这里原样保留这个区别（映射到
//! `Error.TransientFailure` 与 `Error.CapabilityUnavailable`），不让它在接缝处丢掉。

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;

const core = @import("core");
const VideoFrame = core.backend.VideoFrame;
const Spec = core.texture_pool.Spec;

const importer_iface = @import("surface_importer.zig");
const Surface = importer_iface.Surface;
const SurfaceImporter = importer_iface.SurfaceImporter;
const Error = importer_iface.Error;

// 源工程的词汇表（纯 Zig，任何平台都能 import；只有下面那份"平台导入器本体"是
// 按目标平台二选一的）。
const plat = @import("platform_surface.zig");

/// 按目标平台选一个平台导入器本体。macOS 上没有（那条路是 0015 的 Metal 导入器，
/// 已经用本仓库的接口实现），所以这里给一个空结构占位，让本文件在任何平台上都能解析；
/// 真正用到 `inner` 的代码都在 `comptime` 分支里。
const Inner = if (builtin.os.tag == .windows)
    @import("windows_surface_importer.zig").WindowsSurfaceImporter
else if (builtin.os.tag == .linux)
    @import("vulkan_surface_importer.zig").VulkanSurfaceImporter
else
    struct {};

pub const PlatformImporterAdapter = struct {
    inner: Inner,

    pub fn init(allocator: Allocator) PlatformImporterAdapter {
        return .{ .inner = Inner.init(allocator) };
    }

    /// 把 Godot 的 RenderingDevice 交给平台导入器（它要在上面开共享句柄 / 导入
    /// dma-buf）。返回 false 表示这台机器上这条路走不通——调用方应当据此选择
    /// 降级，而不是等到每帧 import 都失败。
    pub fn initialize(self: *PlatformImporterAdapter, rd: *RenderingDevice) bool {
        return self.inner.initialize(rd);
    }

    /// 以本仓库的接口暴露出去，交给 0014 的分发器。
    pub fn asSurfaceImporter(self: *PlatformImporterAdapter) SurfaceImporter {
        return .{ .ptr = self, .vtable = &.{
            .import_frame = importFrameVtable,
            .deinit = deinitVtable,
        } };
    }

    fn importFrameVtable(ptr: *anyopaque, frame: VideoFrame) Error!Surface {
        const self: *PlatformImporterAdapter = @ptrCast(@alignCast(ptr));
        return self.importFrame(frame);
    }

    fn deinitVtable(ptr: *anyopaque) void {
        const self: *PlatformImporterAdapter = @ptrCast(@alignCast(ptr));
        self.inner.deinit();
    }

    pub fn importFrame(self: *PlatformImporterAdapter, frame: VideoFrame) Error!Surface {
        return mapResult(self.inner.import(frame));
    }
};

/// 把源工程的结果翻译成本仓库的 `Surface` 或错误。
fn mapResult(result: plat.ImportResult) Error!Surface {
    return switch (result) {
        .success => |planes| .{
            .spec = .{
                .width = @intCast(planes.width),
                .height = @intCast(planes.height),
                .bit_depth = if (planes.metadata.color.bit_depth >= 10) 10 else 8,
            },
            .planes = .{ .luma_chroma = .{ .luma = planes.luma, .chroma = planes.chroma } },
            // 平台表面可能是左对齐的 16 位容器（VAAPI 的 P010、CoreVideo 的 x420），
            // 着色器读之前要右移这个位数。本仓库的 CPU 上传路径恒为 0（0011 在 shim
            // 里已经右对齐），所以这个字段是平台路径专属的信息。
            .raw_code_shift = planes.metadata.raw_code_shift,
            .release_hook = planes.release,
        },
        // 下面四种刻意分开：只有 capability_unavailable 允许调用方**永久**放弃这条
        // 零拷贝路径。混在一起的后果是驱动或网络抖动一次就把整条会话降级成每帧读回。
        .not_ready => Error.NotReady,
        .bad_frame => Error.BadFrame,
        .transient_failure => Error.TransientFailure,
        .capability_unavailable => Error.CapabilityUnavailable,
    };
}
