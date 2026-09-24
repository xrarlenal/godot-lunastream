//! 导入器运行时分发：一帧交给谁导入，取决于**它是什么形状的帧**。
//!
//! | 帧的 `surface_kind` | 谁来导 | 说明 |
//! |---|---|---|
//! | `cpu_nv12` | CPU 上传导入器 | 软解路径：帧在系统内存里，必须拷一次 |
//! | `native_surface` | 平台导入器（Metal / D3D12 / Vulkan） | 硬解路径：句柄别名，零拷贝 |
//!
//! ## 不做静默回退
//!
//! 平台帧**没有** CPU 平面可以上传，所以"平台导入器缺失时退回 CPU 路径"这件事
//! 根本不存在。这里的选择是明确拒绝（`UnsupportedFrame`）并由调用方去换档位——
//! 与 0009 的"`hardware` 档绝不悄悄落软解"是同一条原则：用户拿不到"看起来是
//! 硬解其实是软解"的假象。
//!
//! ## 为什么分发要记数
//!
//! `cpu` / `platform` / `rejected` 三个计数是给 0019 的 `get_stats()` 用的：
//! 用户在弱网或多路场景下最想问的就是"这一路到底走的是哪条路径"，而这个答案
//! 必须来自实际发生的分发，而不是来自配置意图。

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;

const core = @import("core");
const VideoFrame = core.backend.VideoFrame;

const importer_iface = @import("surface_importer.zig");
const Surface = importer_iface.Surface;
const SurfaceImporter = importer_iface.SurfaceImporter;
const Error = importer_iface.Error;

const CpuFrameImporter = @import("cpu_frame_importer.zig").CpuFrameImporter;
const CpuOptions = @import("cpu_frame_importer.zig").Options;

pub const Stats = struct {
    /// 交给 CPU 上传路径的帧数。
    cpu: u64,
    /// 交给平台导入器（零拷贝）的帧数。
    platform: u64,
    /// 因为"是平台帧但没有平台导入器"被拒绝的帧数。
    rejected: u64,
};

pub const DispatchingImporter = struct {
    allocator: Allocator,
    cpu: CpuFrameImporter,
    /// 平台导入器在 0015-0017 落地后挂进来；在此之前 `native_surface` 帧会被拒绝。
    platform: ?SurfaceImporter = null,
    served_cpu: u64 = 0,
    served_platform: u64 = 0,
    rejected: u64 = 0,

    pub fn init(allocator: Allocator, cpu_options: CpuOptions) Error!DispatchingImporter {
        const cpu = try CpuFrameImporter.init(allocator, cpu_options);
        return .{ .allocator = allocator, .cpu = cpu };
    }

    /// 用指定的 RenderingDevice 构造（自检需要，理由见 CpuFrameImporter.initWithDevice）。
    pub fn initWithDevice(allocator: Allocator, rd: *RenderingDevice, cpu_options: CpuOptions) Error!DispatchingImporter {
        const cpu = try CpuFrameImporter.initWithDevice(allocator, rd, cpu_options);
        return .{ .allocator = allocator, .cpu = cpu };
    }

    pub fn setPlatform(self: *DispatchingImporter, importer: SurfaceImporter) void {
        self.platform = importer;
    }

    pub fn importFrame(self: *DispatchingImporter, frame: VideoFrame) Error!Surface {
        switch (frame.surface_kind) {
            .cpu_nv12 => {
                const surface = try self.cpu.importFrame(frame);
                self.served_cpu += 1;
                return surface;
            },
            .native_surface => {
                const platform = self.platform orelse {
                    self.rejected += 1;
                    return Error.UnsupportedFrame;
                };
                const surface = try platform.importFrame(frame);
                self.served_platform += 1;
                return surface;
            },
        }
    }

    pub fn stats(self: *const DispatchingImporter) Stats {
        return .{
            .cpu = self.served_cpu,
            .platform = self.served_platform,
            .rejected = self.rejected,
        };
    }

    pub fn deinit(self: *DispatchingImporter) void {
        if (self.platform) |platform| platform.deinit();
        self.cpu.deinit();
    }
};
