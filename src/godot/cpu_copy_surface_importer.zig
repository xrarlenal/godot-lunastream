//! cpu_copy_surface_importer.zig — Windows CPU-copy import path.
//!
//! The fallback importer for the common case: a stock Vulkan RenderingDevice
//! driver on any Godot version, where neither zero-copy path is reachable (the
//! DXGI Vulkan import is not ported, and the D3D12 path needs the d3d12 RD
//! driver). Hardware decode is untouched — the MF backend's DXGI device manager
//! still drives the decoder — and this adds a GPU->CPU readback so the decoded
//! NV12/P010 surface reaches Godot RD as ordinary R8/RG8 (8-bit) or R16/RG16
//! (10-bit) textures instead of an aliased import.
//!
//! This is the ONE import path that violates the zero-copy contract, by design.
//!
//! The readback ring, in detail: each import() writes into ring slot
//! (frame % ring_depth) via CopySubresourceRegion (GPU-side, no CPU copy), then
//! reads back the slot written ring_depth-1 frames ago — the oldest occupied
//! slot, whose GPU copy has had that many frames to drain, so Map() reads
//! resident data instead of stalling the render thread. During the first
//! ring_depth-1 frames after initialize() no slot is old enough (has_data is
//! false) and import() returns an invalid PlaneTextures; the present pipeline
//! presents nothing until the ring fills. This same accounting means every
//! frame presented on this path — not just during startup — is the pixel
//! content from ring_depth-1 frames earlier: a fixed, permanent presentation
//! lag traded for never stalling on Map().
//!
//! Mapping an NV12/P010 staging texture returns ONE pointer for the whole
//! resource: the Y plane's rows start at pData with stride RowPitch, and the
//! interleaved UV plane starts immediately after all Y rows, at
//! pData + RowPitch * height, using the SAME RowPitch. Both planes are copied
//! row-by-row into tightly packed buffers because RowPitch is generally wider
//! than a plane's exact byte width (driver row alignment) while texture_update
//! expects tightly packed data.
//!
//! P010 bit justification: each 10-bit sample is stored left-justified in a
//! 16-bit word (value = code << 6), the opposite of CoreVideo's x420 (the AVF
//! backend's 10-bit format, right-justified in the low 10 bits). The shared
//! present shader assumes the x420 convention (code = sampled * 65535), so the
//! 10-bit packing path shifts every sample right by 6 while copying, producing
//! the same right-justified layout on both platforms.

const std = @import("std");

const core = @import("core");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const Rid = godot.builtin.Rid;
const PackedByteArray = godot.builtin.PackedByteArray;

const win = @import("win");
const com = win.com;
const dxgi = win.dxgi;
const d3d11 = win.d3d11;

// Row packing and plane-texture creation are platform-neutral; they now live
// in plane_copy.zig so the software-decode importer can share them instead of
// duplicating the stride/row handling on every platform.
const pc = @import("plane_copy.zig");

const si = @import("platform_surface.zig");
const PlaneTextures = si.PlaneTextures;
const ImportResult = si.ImportResult;

const wic = @import("windows_import_common.zig");
const CachedTex2D = wic.CachedTex2D;

const log = std.log.scoped(.native_video_cpu_copy_import);

/// Ring depth matches PresentPipeline's frame latency: the same number of
/// rendered frames every other import path's transient surfaces survive before
/// retirement.
const readback_ring_depth: usize = 3;

const ReadbackSlot = struct {
    staging: CachedTex2D = .{},
    has_data: bool = false, // true once a CopySubresourceRegion has targeted it
    // The display-aperture crop THIS slot's frame carried, captured at write
    // time. The read side resolves it against `staging`'s own (aligned)
    // dimensions rather than whatever crop the CURRENT call() received, since
    // the slot being read back was written by an earlier, different import()
    // call -- see the ring-buffer accounting in the module doc comment.
    metadata: si.PresentationMetadata = .{},
};

pub const CpuCopySurfaceImporter = struct {
    allocator: std.mem.Allocator,
    rd: ?*RenderingDevice = null,

    // Bound lazily on the first import(), straight from the decoder texture —
    // no device of our own, no adapter matching: the readback runs on the SAME
    // device the decoder texture already lives on.
    device: ?*d3d11.ID3D11Device = null,
    context: ?*d3d11.ID3D11DeviceContext = null,

    ring: [readback_ring_depth]ReadbackSlot = @splat(.{}),
    frame_index: u64 = 0,
    source_width: com.UINT = 0,
    source_height: com.UINT = 0,
    source_format: dxgi.DXGI_FORMAT = dxgi.DXGI_FORMAT_UNKNOWN,
    initialized: bool = false,

    // Session-scoped: every frame actually imported through this path, honest
    // accounting for the one importer allowed to violate the zero-copy
    // contract. Persists across a mid-flight D3D12->CPU-copy degrade, since
    // the WindowsSurfaceImporter wrapper keeps reusing the same instance for
    // the rest of the session once it switches over.
    cpu_copy_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) CpuCopySurfaceImporter {
        return .{ .allocator = allocator };
    }

    /// Always succeeds for a non-null RD: unlike the zero-copy importers this
    /// path needs no particular RD driver or GPU extension — texture_create /
    /// texture_update are driver-agnostic.
    pub fn initialize(self: *CpuCopySurfaceImporter, rd: *RenderingDevice) bool {
        self.rd = rd;
        self.initialized = true;
        return true;
    }

    pub fn isInitialized(self: *const CpuCopySurfaceImporter) bool {
        return self.initialized;
    }

    /// Import the NV12/P010 ID3D11Texture2D (opaque handle == ID3D11Texture2D*)
    /// into two RD plane textures via a GPU->CPU readback, CROPPED to `crop`
    /// (the frame's display aperture -- see core.backend.CropRect). Returns an
    /// A typed failure on error, or `not_ready` while the readback ring warms.
    pub fn import(self: *CpuCopySurfaceImporter, frame_info: core.backend.VideoFrame) ImportResult {
        var out: PlaneTextures = .{};
        if (!self.initialized) return .transient_failure;
        const handle = frame_info.native_handle orelse return .bad_frame;
        const decoded: *d3d11.ID3D11Texture2D = @ptrCast(@alignCast(handle));

        // Lazily bind to the SAME device the decoder texture lives on.
        if (self.device == null) {
            const bound = wic.bindDecoderDevice(decoded) orelse {
                log.err("CPU-copy importer: ID3D11Texture2D.GetDevice failed.", .{});
                return .transient_failure;
            };
            self.device = bound.device;
            self.context = bound.context;
        }
        const device = self.device.?;
        const context = self.context.?;

        var src_desc: d3d11.D3D11_TEXTURE2D_DESC = undefined;
        decoded.GetDesc(&src_desc);
        _ = wic.detectBitDepth(src_desc.Format) orelse {
            log.err("CPU-copy importer: decoder texture is not NV12 or P010.", .{});
            return .bad_frame;
        };
        const width: com.UINT = src_desc.Width;
        const height: com.UINT = src_desc.Height;

        // A ring generation has one physical shape/format. Never allow a slot
        // from the previous generation to emerge beside metadata from a new
        // decoder configuration.
        if (width != self.source_width or height != self.source_height or src_desc.Format != self.source_format) {
            for (&self.ring) |*slot| {
                slot.staging.release();
                slot.has_data = false;
                slot.metadata = .{};
            }
            self.frame_index = 0;
            self.source_width = width;
            self.source_height = height;
            self.source_format = src_desc.Format;
        }

        const frame = self.frame_index;
        self.frame_index += 1;
        const write_slot = frame % readback_ring_depth;
        const read_slot = (frame + 1) % readback_ring_depth;

        // --- Queue this frame's GPU-side readback into the ring slot with the
        // most time left before it is read. No CPU copy here.
        const write = &self.ring[@as(usize, @intCast(write_slot))];
        if (!write.staging.ensure(device, width, height, src_desc.Format, d3d11.D3D11_USAGE_STAGING, 0, d3d11.D3D11_CPU_ACCESS_READ)) {
            log.err("CPU-copy importer: staging texture create failed.", .{});
            return .transient_failure;
        }
        context.CopySubresourceRegion(
            write.staging.texture.?.asResource(),
            0,
            0,
            0,
            0,
            decoded.asResource(),
            @intCast(frame_info.plane_slice),
            null,
        );
        write.has_data = true;
        write.metadata = si.PresentationMetadata.fromFrame(frame_info);

        // --- Read back the oldest slot. Still warming up: nothing old enough.
        const read = &self.ring[@as(usize, @intCast(read_slot))];
        if (!read.has_data) return .not_ready;

        var mapped = std.mem.zeroes(d3d11.D3D11_MAPPED_SUBRESOURCE);
        if (com.FAILED(context.Map(read.staging.texture.?.asResource(), 0, d3d11.D3D11_MAP_READ, 0, &mapped))) {
            log.err("CPU-copy importer: staging texture Map failed.", .{});
            return .transient_failure;
        }

        // Aligned (possibly macroblock-padded) dimensions of the physical
        // readback -- the crop is resolved against THESE, and against the
        // crop THIS slot's frame carried (read.crop), not the crop passed to
        // the current call.
        const aligned_width: com.UINT = read.staging.width;
        const aligned_height: com.UINT = read.staging.height;
        const rc = wic.resolveCrop(read.metadata.crop, aligned_width, aligned_height);
        const read_is_10bit = wic.detectBitDepth(read.staging.format) orelse {
            context.Unmap(read.staging.texture.?.asResource(), 0);
            return .bad_frame;
        };
        const row_pitch: usize = mapped.RowPitch;

        const luma_src: [*]const u8 = @ptrCast(mapped.pData.?);
        const chroma_src: [*]const u8 = luma_src + row_pitch * @as(usize, aligned_height);

        var luma_bytes: PackedByteArray = undefined;
        var chroma_bytes: PackedByteArray = undefined;
        if (read_is_10bit) {
            luma_bytes = pc.packRows10bit(luma_src, row_pitch, rc.luma_x, rc.luma_y, rc.luma_width, rc.luma_height);
            // Interleaved U16+V16 per chroma sample.
            chroma_bytes = pc.packRows10bit(chroma_src, row_pitch, @as(usize, rc.chroma_x) * 2, rc.chroma_y, @as(usize, rc.chroma_width) * 2, rc.chroma_height);
        } else {
            luma_bytes = pc.packRows8bit(luma_src, row_pitch, rc.luma_x, rc.luma_y, rc.luma_width, rc.luma_height);
            // Interleaved U8+V8 per chroma sample.
            chroma_bytes = pc.packRows8bit(chroma_src, row_pitch, @as(usize, rc.chroma_x) * 2, rc.chroma_y, @as(usize, rc.chroma_width) * 2, rc.chroma_height);
        }
        defer luma_bytes.deinit();
        defer chroma_bytes.deinit();

        context.Unmap(read.staging.texture.?.asResource(), 0);

        // --- Ordinary texture_create + texture_update — no aliased import.
        const rd = self.rd.?;
        const luma_fmt = si.planeFormat(read_is_10bit, false);
        const chroma_fmt = si.planeFormat(read_is_10bit, true);

        const luma = pc.createPlane(rd, luma_fmt, @intCast(rc.luma_width), @intCast(rc.luma_height));
        const chroma = pc.createPlane(rd, chroma_fmt, @intCast(rc.chroma_width), @intCast(rc.chroma_height));
        if (!luma.isValid() or !chroma.isValid()) {
            si.freePlaneRids(rd, luma, chroma);
            log.err("CPU-copy importer: texture_create failed.", .{});
            return .transient_failure;
        }
        if (rd.textureUpdate(luma, 0, luma_bytes) != .ok or rd.textureUpdate(chroma, 0, chroma_bytes) != .ok) {
            si.freePlaneRids(rd, luma, chroma);
            log.err("CPU-copy importer: texture_update failed.", .{});
            return .transient_failure;
        }

        const release = si.boxPlaneRelease(self.allocator, rd, luma, chroma) catch {
            si.freePlaneRids(rd, luma, chroma);
            return .transient_failure;
        };

        out.luma = luma;
        out.chroma = chroma;
        out.width = @intCast(rc.luma_width);
        out.height = @intCast(rc.luma_height);
        out.metadata = read.metadata;
        out.release = release;
        // Honest accounting: this is the one import path allowed to violate
        // the zero-copy contract, so every frame it actually hands back counts.
        self.cpu_copy_count += 1;
        return .{ .success = out };
    }

    /// Frames imported through this CPU-copy path so far this session.
    pub fn cpuCopyCount(self: *const CpuCopySurfaceImporter) u64 {
        return self.cpu_copy_count;
    }

    pub fn deinit(self: *CpuCopySurfaceImporter) void {
        for (&self.ring) |*slot| slot.staging.release();
        if (self.context) |c| {
            com.release(c);
            self.context = null;
        }
        if (self.device) |d| {
            com.release(d);
            self.device = null;
        }
        self.initialized = false;
    }
};
