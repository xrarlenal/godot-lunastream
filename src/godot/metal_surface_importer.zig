//! Metal 呈现导入器（macOS 零拷贝）。
//!
//! 硬解帧在 macOS 上是 `CVPixelBuffer`（IOSurface 支撑）。CVMetalTextureCache 能把
//! 它包装成两个 MTLTexture 视图（平面 0 = 亮度 R8，平面 1 = 交织 CbCr RG8），
//! **一个字节都不复制**；Godot 侧再用 `texture_create_from_extension` 把这两个
//! MTLTexture 别名成自己的纹理 RID。于是"网口 → 解码 → 纹理"这条路上没有 CPU 读回，
//! 这正是本插件相对 CPU 上传路径的核心差异。
//!
//! ## 所有权：零拷贝意味着"帧不能提前还"
//!
//! CPU 路径可以上传完就把解码帧还掉（数据已经拷进纹理了）；这里不行——纹理**就是**
//! 那块 IOSurface。所以导入器在这一步**接管**该帧的释放责任：消费者只调
//! `Surface.release()`，导入器在释放纹理视图的同时调用帧自带的 `release_hook`
//! 把原生表面还给解码池。两处各还一半，绝不会双重释放。
//!
//! ## 同时可存在的帧数
//!
//! 与 CPU 路径同理（0004 回收环 + 队列深度），这里用一张定长表记住"哪些帧的视图
//! 还在飞"。取满时返回 `PoolExhausted`（背压），不覆盖。

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const RenderingServer = godot.class.RenderingServer;
const Rid = godot.builtin.Rid;

const core = @import("core");
const VideoFrame = core.backend.VideoFrame;
const VoidClosure = core.closure.VoidClosure;
const Spec = core.texture_pool.Spec;

const importer_iface = @import("surface_importer.zig");
const Surface = importer_iface.Surface;
const SurfaceImporter = importer_iface.SurfaceImporter;
const Error = importer_iface.Error;

const bridge = @cImport({
    @cInclude("cv_metal_bridge.h");
});

/// 同时在飞的零拷贝帧上限。与 CPU 路径的池深度同源，取同一数量级即可——它约束的是
/// "还没被 GPU 消费完的帧"，而回收环本来就会把延迟压到几帧。
pub const kMaxInFlight: usize = 12;

pub const Options = struct {
    /// 让别名进来的纹理可以被读回 CPU（自检用；理由见 cpu_frame_importer.Options）。
    cpu_readback: bool = false,
};

pub const Stats = struct {
    /// 累计导入的帧数。
    imports: u64,
    /// 累计创建的扩展纹理对数。
    textures: u64,
    /// 当前在飞的帧数。
    in_flight: usize,
    /// 因为取满而拒绝的次数（背压）。
    exhausted: u64,
    /// 因为帧形状不对而拒绝的次数。
    unsupported: u64,
};

pub const MetalSurfaceImporter = struct {
    const Entry = struct {
        owner: *MetalSurfaceImporter = undefined,
        view: bridge.nv_cv_metal_view = undefined,
        luma: Rid = undefined,
        chroma: Rid = undefined,
        frame_release: VoidClosure = .{},
        in_use: bool = false,
    };

    allocator: Allocator,
    rd: *RenderingDevice,
    options: Options = .{},
    entries: [kMaxInFlight]Entry = @splat(.{}),
    imports: u64 = 0,
    textures: u64 = 0,
    exhausted: u64 = 0,
    unsupported: u64 = 0,

    pub fn init(allocator: Allocator, options: Options) Error!MetalSurfaceImporter {
        const rd = RenderingServer.getRenderingDevice() orelse return Error.NoRenderingDevice;
        return initWithDevice(allocator, rd, options);
    }

    pub fn initWithDevice(allocator: Allocator, rd: *RenderingDevice, options: Options) Error!MetalSurfaceImporter {
        return .{ .allocator = allocator, .rd = rd, .options = options };
    }

    pub fn asSurfaceImporter(self: *MetalSurfaceImporter) SurfaceImporter {
        return .{ .ptr = self, .vtable = &.{
            .import_frame = importFrameVtable,
            .deinit = deinitVtable,
        } };
    }

    fn importFrameVtable(ptr: *anyopaque, frame: VideoFrame) Error!Surface {
        const self: *MetalSurfaceImporter = @ptrCast(@alignCast(ptr));
        return self.importFrame(frame);
    }

    fn deinitVtable(ptr: *anyopaque) void {
        const self: *MetalSurfaceImporter = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    pub fn importFrame(self: *MetalSurfaceImporter, frame: VideoFrame) Error!Surface {
        if (frame.surface_kind != .native_surface) {
            self.unsupported += 1;
            return Error.UnsupportedFrame;
        }
        const handle = frame.native_handle orelse {
            self.unsupported += 1;
            return Error.UnsupportedFrame;
        };
        if (frame.width <= 0 or frame.height <= 0) {
            self.unsupported += 1;
            return Error.UnsupportedFrame;
        }

        const index = self.acquireEntry() orelse {
            self.exhausted += 1;
            return Error.PoolExhausted;
        };
        const entry = &self.entries[index];
        entry.* = .{ .owner = self, .frame_release = frame.release_hook };

        // 零拷贝：拿到指向 IOSurface 的两个 MTLTexture 视图。
        if (bridge.nv_cv_metal_view_create(handle, &entry.view) != 0) {
            entry.* = .{};
            return Error.ImportFailed;
        }

        const width: u32 = @intCast(frame.width);
        const height: u32 = @intCast(frame.height);
        const usage: RenderingDevice.TextureUsageBits = .{
            .texture_usage_sampling_bit = true,
            .texture_usage_can_copy_from_bit = self.options.cpu_readback,
            .texture_usage_cpu_read_bit = self.options.cpu_readback,
        };

        entry.luma = self.rd.textureCreateFromExtension(
            .texture_type_2d,
            .data_format_r8_unorm,
            .texture_samples_1,
            usage,
            @intFromPtr(entry.view.luma_texture),
            width,
            height,
            1,
            1,
            .{},
        );
        entry.chroma = self.rd.textureCreateFromExtension(
            .texture_type_2d,
            .data_format_r8g8_unorm,
            .texture_samples_1,
            usage,
            @intFromPtr(entry.view.chroma_texture),
            (width + 1) / 2,
            (height + 1) / 2,
            1,
            1,
            .{},
        );
        if (!self.rd.textureIsValid(entry.luma) or !self.rd.textureIsValid(entry.chroma)) {
            if (self.rd.textureIsValid(entry.luma)) self.rd.freeRid(entry.luma);
            if (self.rd.textureIsValid(entry.chroma)) self.rd.freeRid(entry.chroma);
            bridge.nv_cv_metal_view_destroy(&entry.view);
            entry.* = .{};
            return Error.ImportFailed;
        }

        entry.in_use = true;
        self.imports += 1;
        self.textures += 2;

        const spec: Spec = .{
            .width = width,
            .height = height,
            .bit_depth = if (frame.cpu.bit_depth >= 10) 10 else 8,
        };
        return .{
            .spec = spec,
            .planes = .{ .luma_chroma = .{ .luma = entry.luma, .chroma = entry.chroma } },
            .release_hook = .{ .ctx = entry, .func = releaseEntry },
        };
    }

    pub fn stats(self: *const MetalSurfaceImporter) Stats {
        var in_flight: usize = 0;
        for (&self.entries) |*entry| {
            if (entry.in_use) in_flight += 1;
        }
        return .{
            .imports = self.imports,
            .textures = self.textures,
            .in_flight = in_flight,
            .exhausted = self.exhausted,
            .unsupported = self.unsupported,
        };
    }

    pub fn deinit(self: *MetalSurfaceImporter) void {
        for (&self.entries) |*entry| {
            if (!entry.in_use) continue;
            self.releaseEntryResources(entry);
        }
    }

    fn acquireEntry(self: *MetalSurfaceImporter) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (!entry.in_use) return index;
        }
        return null;
    }

    fn releaseEntryResources(self: *MetalSurfaceImporter, entry: *Entry) void {
        if (self.rd.textureIsValid(entry.luma)) self.rd.freeRid(entry.luma);
        if (self.rd.textureIsValid(entry.chroma)) self.rd.freeRid(entry.chroma);
        bridge.nv_cv_metal_view_destroy(&entry.view);
        // 纹理视图没了，这才把帧还给解码池（零拷贝路径的所有权移交，见文件头注释）。
        entry.frame_release.call();
        entry.* = .{};
    }

    fn releaseEntry(ctx: ?*anyopaque) void {
        const entry: *Entry = @ptrCast(@alignCast(ctx.?));
        if (!entry.in_use) return; // 重复释放是空操作
        entry.owner.releaseEntryResources(entry);
    }
};
