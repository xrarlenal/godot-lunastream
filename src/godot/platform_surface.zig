//! surface_importer.zig — platform-neutral vocabulary for surface import.
//!
//! The zero-copy present pipeline imports a hardware-decoded biplanar
//! Y'CbCr surface (NV12 8-bit, or P010/x420 10-bit) into Godot's
//! RenderingDevice as two plane textures WITHOUT any CPU copy, then runs
//! the single NV12->RGB compute pass. The concrete importer lives in
//! metal_surface_importer.zig on macOS (CVPixelBuffer IOSurface -> MTLTexture
//! via CVMetalTextureCache -> RenderingDevice.textureCreateFromExtension); on
//! Windows, a D3D12 zero-copy importer and a CPU-copy fallback are chosen at
//! runtime by importer_selector from the active RenderingDevice driver
//! and Godot version; on Linux, vulkan_surface_importer.zig imports the
//! decoder's dma-buf (VAAPI) on Godot's own Vulkan device. A further Windows
//! path — a Vulkan external-memory / DXGI shared-handle zero-copy importer — is
//! a known limitation: it is not ported, blocked on an upstream Godot
//! texture-import aspect fix (see importer_selector's module doc comment).
//!
//! This module holds the types shared across that module boundary — the
//! PlaneTextures import result and the small RID/closure helpers — so the
//! present pipeline never reaches into CoreVideo/Metal directly. Zig has no
//! capturing closures, so teardown hooks are ctx + fn-pointer Closures.

const std = @import("std");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const Rid = godot.builtin.Rid;

const core = @import("core");

pub const PresentationMetadata = struct {
    pts_seconds: f64 = 0.0,
    width: i32 = 0,
    height: i32 = 0,
    pixel_format: core.backend.PixelFormat = .unknown,
    crop: core.backend.CropRect = .{},
    color: core.backend.Colorimetry = .{},
    /// Bits to shift the raw 16-bit plane samples RIGHT by before the present
    /// shader treats them as Y'CbCr code values (see core.push_constants).
    /// 0 = already right-justified 10-bit-in-16 (D3D11VA/D3D12 path rescales to
    /// this, the CPU-copy path packs this way). 6 = the decoder's 10-bit code
    /// values sit in the high bits of each word (VAAPI P010 dma-bufs, and
    /// CoreVideo's x420/xf20 biplanar surfaces), so they must be shifted down.
    /// Irrelevant for 8-bit frames.
    raw_code_shift: u32 = 0,

    pub fn fromFrame(frame: core.backend.VideoFrame) PresentationMetadata {
        return .{
            .pts_seconds = frame.pts_seconds,
            .width = frame.width,
            .height = frame.height,
            .pixel_format = frame.pixel_format,
            .crop = frame.crop,
            .color = frame.color,
        };
    }
};

/// An invalid (zero) RID for struct-field defaults. isValid() is false.
pub const rid_invalid: Rid = std.mem.zeroes(Rid);

/// Release/sync hook for an imported surface: ctx + fn pointer, shared with
/// every other type-erased callback in the codebase.
pub const Closure = core.backend.VoidClosure;

/// Heap-boxes `value` and returns a Closure whose thunk runs `teardown`
/// against the boxed value, then frees the box. Every heap-boxed-teardown
/// closure in the present pipeline goes through here, so the allocate /
/// teardown / free ordering lives in exactly one place.
pub fn boxClosure(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime teardown: fn (*@TypeOf(value)) void,
) !Closure {
    const Box = struct {
        allocator: std.mem.Allocator,
        value: @TypeOf(value),

        fn run(ctx: ?*anyopaque) void {
            const box: *@This() = @ptrCast(@alignCast(ctx.?));
            teardown(&box.value);
            box.allocator.destroy(box);
        }
    };
    const box = try allocator.create(Box);
    box.* = .{ .allocator = allocator, .value = value };
    return .{ .ctx = box, .func = Box.run };
}

// -----------------------------------------------------------------------
// PlaneTextures — the import result for one frame.
//
// The two imported plane textures, plus a release closure that tears down
// everything created during the import (RD RIDs + native wrapper objects).
// The caller invokes release() exactly once; the present pipeline parks it in
// the retire-ring for N rendered frames so the GPU is done sampling before the
// wrappers are freed.
// -----------------------------------------------------------------------
pub const PlaneTextures = struct {
    luma: Rid = rid_invalid, // R8 (8-bit) or R16 (10-bit), full resolution
    chroma: Rid = rid_invalid, // RG8 (8-bit) or RG16 (10-bit), half resolution
    width: i32 = 0, // luma (frame) width
    height: i32 = 0, // luma (frame) height
    metadata: PresentationMetadata = .{},

    /// Frees the RD texture RIDs and releases the native import wrappers. Call
    /// exactly once (the retire-ring does this after N frames).
    release: Closure = .{},

    pub fn valid(self: PlaneTextures) bool {
        return self.luma.isValid() and self.chroma.isValid();
    }

    /// Abandon an imported frame and consume its release hook exactly once.
    pub fn discard(self: *PlaneTextures) void {
        const release = self.release;
        self.release = .{};
        release.call();
    }
};

/// Typed import outcome. Only `capability_unavailable` authorizes the Windows
/// selector to permanently abandon D3D12; malformed or transient frames must
/// not silently change the session's presentation architecture.
pub const ImportResult = union(enum) {
    success: PlaneTextures,
    not_ready,
    bad_frame,
    transient_failure,
    capability_unavailable,
};

/// Frees whichever of the two plane RIDs are valid. Shared by importers'
/// failure paths (one RID created, the other failed) and their release
/// closures.
pub fn freePlaneRids(rd: *RenderingDevice, luma: Rid, chroma: Rid) void {
    if (luma.isValid()) rd.freeRid(luma);
    if (chroma.isValid()) rd.freeRid(chroma);
}

/// The RD plane-texture DataFormat for one plane: r8/r16 for luma, rg8/rg16
/// for chroma, selected by bit depth. Every importer that materialises
/// ordinary right-justified R/RG plane textures (CPU-copy, D3D12, Metal)
/// picks its formats through here.
pub fn planeFormat(is_10bit: bool, is_chroma: bool) RenderingDevice.DataFormat {
    return if (is_chroma)
        (if (is_10bit) .data_format_r16g16_unorm else .data_format_r8g8_unorm)
    else
        (if (is_10bit) .data_format_r16_unorm else .data_format_r8_unorm);
}

/// Release payload for the common case: two RD plane RIDs and nothing else
/// (no native import wrapper to tear down). Importers with extra teardown
/// work (D3D12's shared resources, Metal's CVMetalTexture wrappers) box
/// their own richer release value instead.
const PlaneReleaseValue = struct {
    rd: *RenderingDevice,
    luma: Rid,
    chroma: Rid,
};

fn planeReleaseTeardown(v: *PlaneReleaseValue) void {
    freePlaneRids(v.rd, v.luma, v.chroma);
}

/// Box a release Closure that just frees the two plane RIDs via
/// freePlaneRids. Shared by every importer whose plane textures need no
/// other teardown.
pub fn boxPlaneRelease(allocator: std.mem.Allocator, rd: *RenderingDevice, luma: Rid, chroma: Rid) !Closure {
    return boxClosure(allocator, PlaneReleaseValue{ .rd = rd, .luma = luma, .chroma = chroma }, planeReleaseTeardown);
}
