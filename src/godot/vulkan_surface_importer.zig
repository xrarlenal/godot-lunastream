//! vulkan_surface_importer.zig — Linux: VAAPI dma-buf → RD plane textures.
//!
//! Takes a hardware-decoded VAAPI surface (exported as a dma-buf by
//! ffva_shim.c) and produces the two Godot RenderingDevice plane textures the
//! shared NV12→RGB compute pass samples — luma (R8/R16) and chroma (RG8/RG16).
//! The pixel data never touches CPU memory: the dma-buf is imported as an
//! external VkImage on Godot's own VkDevice, and vkCmdCopyImage moves plane 0/1
//! into the two RD textures on the GPU (cropping macroblock padding on the way).
//!
//! Why not RenderingDevice.textureCreateFromExtension (the macOS path)? On the
//! Vulkan RD driver that API cannot select the plane (aspectMask) of a
//! multi-planar image, so an NV12 import binds both planes to one view and
//! samples the wrong surface (upstream Godot proposals #13969/#15116, unmerged).
//! This importer therefore creates its own external image and copies out of it;
//! all Vulkan-side work lives in src/ffva/vk_import_shim.c and this file is just
//! the Godot-side glue (driver resources, RD textures, lifetimes).
//!
//! Plane textures are recycled in a small ring (plane_ring_depth): the copy into
//! them runs on Godot's own queue every frame, so a slot is only rewritten once
//! the frame that sampled it is comfortably retired — the same latency argument
//! the present pipeline's RGBA ring and retire-ring rely on.

const std = @import("std");

const core = @import("core");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const RdTextureFormat = godot.class.RdTextureFormat;
const RdTextureView = godot.class.RdTextureView;
const Rid = godot.builtin.Rid;

const si = @import("platform_surface.zig");
const PlaneTextures = si.PlaneTextures;

const log = std.log.scoped(.native_video_vk_import);

/// Frames a plane-texture pair is held before it is rewritten. Matches the
/// present pipeline's retire depth without importing it (that would be a module
/// cycle).
const plane_ring_depth = 3;

// -----------------------------------------------------------------------
// C ABI — mirrors ffva_shim.h / vk_import_shim.h by hand (no @cImport).
// -----------------------------------------------------------------------
const Importer = opaque {};

const Result = enum(c_int) {
    fail = -1,
    none = 0,
    ok = 1,
};

const c_colorimetry = extern struct {
    matrix: c_int,
    primaries: c_int,
    transfer: c_int,
    range: c_int,
    bit_depth: c_int,
};

const c_open_info = extern struct {
    duration_seconds: f64,
    width: c_int,
    height: c_int,
    has_video: c_int,
    color: c_colorimetry,
};

/// Per-frame dma-buf description (nv_ffva_frame). `object_fds` are owned by the
/// shim and closed by nv_ffva_frame_release.
const c_frame = extern struct {
    pts_seconds: f64,
    width: c_int,
    height: c_int,
    crop_x: c_int,
    crop_y: c_int,
    surface_width: c_int,
    surface_height: c_int,
    pixel_format: c_int,
    drm_fourcc: u32,
    plane_count: c_int,
    object_count: c_int,
    object_fds: [4]c_int,
    plane_object: [4]u32,
    offsets: [4]u32,
    pitches: [4]u32,
    modifiers: [4]u64,
    color: c_colorimetry,
    owner: ?*anyopaque,
};

const AbiProbe = extern struct {
    sizeof_colorimetry: usize,
    off_colorimetry: [5]usize,

    sizeof_open_info: usize,
    off_open_info: [5]usize, // duration_seconds, width, height, has_video, color

    sizeof_frame: usize,
    off_frame: [16]usize, // pts_seconds .. modifiers
};

/// Numeric tags shared with ffva_shim.h / core.backend.PixelFormat.
const PixelFormatTag = enum(c_int) {
    unknown = 0,
    nv12 = 1,
    x420 = 2,
    bgra8 = 3,
};

extern fn nv_ffva_abi_probe_fill(out: *AbiProbe) void;
extern fn nv_vk_import_create(
    vk_instance: u64,
    vk_physical_device: u64,
    vk_device: u64,
    vk_queue: u64,
    queue_family_index: u32,
) ?*Importer;
extern fn nv_vk_import_destroy(importer: ?*Importer) void;
extern fn nv_vk_import_frame(
    importer: *Importer,
    frame: *const c_frame,
    luma_image: u64,
    luma_width: c_int,
    luma_height: c_int,
    chroma_image: u64,
    chroma_width: c_int,
    chroma_height: c_int,
) Result;

fn structMatchesAbi(comptime T: type, expected_size: usize, expected_offsets: []const usize) bool {
    if (expected_size != @sizeOf(T)) return false;
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len != expected_offsets.len) return false;
    inline for (fields, 0..) |field, i| {
        if (@offsetOf(T, field.name) != expected_offsets[i]) return false;
    }
    return true;
}

/// Panics if the C frame struct drifted from the mirror above. Called once from
/// initialize() in debug builds — a silent mismatch would read dma-buf fds and
/// plane offsets out of the wrong bytes.
pub fn assertAbi() void {
    var probe: AbiProbe = undefined;
    nv_ffva_abi_probe_fill(&probe);
    const ok = structMatchesAbi(c_colorimetry, probe.sizeof_colorimetry, &probe.off_colorimetry) and
        structMatchesAbi(c_open_info, probe.sizeof_open_info, &probe.off_open_info) and
        structMatchesAbi(c_frame, probe.sizeof_frame, &probe.off_frame);
    if (!ok) @panic("ffva ABI drift: shim struct layout no longer matches vulkan_surface_importer.zig's c_* mirrors");
}

/// One recycled pair of RD plane textures: ordinary Godot textures created with
/// SAMPLING | CAN_COPY_TO, so the importer's queue can write them (TRANSFER_DST)
/// and Godot's NV12→RGB compute pass can sample them (SAMPLED).
const PlaneSlot = struct {
    luma: Rid = si.rid_invalid,
    chroma: Rid = si.rid_invalid,
    width: i32 = 0,
    height: i32 = 0,
};

pub const VulkanSurfaceImporter = struct {
    allocator: std.mem.Allocator,
    rd: ?*RenderingDevice = null,
    importer: ?*Importer = null,
    slots: [plane_ring_depth]PlaneSlot = @splat(.{}),
    next_slot: usize = 0,
    /// Bit shift to right-justify the raw plane samples the present shader
    /// reads (see core.push_constants). P010 dma-bufs from VAAPI keep their
    /// 10-bit code values in the HIGH bits of each 16-bit word, so a 10-bit
    /// frame needs `code >> 6`; 8-bit frames need none.
    raw_code_shift: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) VulkanSurfaceImporter {
        return .{ .allocator = allocator };
    }

    /// Bind to Godot's Vulkan device. Returns false when the RD is not Vulkan
    /// (then there is no dma-buf import path) or the importer refuses to start.
    pub fn initialize(self: *VulkanSurfaceImporter, rd: *RenderingDevice) bool {
        if (self.importer != null) return true;
        if (@import("builtin").mode == .Debug) assertAbi();

        const instance = rd.getDriverResource(.driver_resource_topmost_object, si.rid_invalid, 0);
        const physical = rd.getDriverResource(.driver_resource_physical_device, si.rid_invalid, 0);
        const device = rd.getDriverResource(.driver_resource_logical_device, si.rid_invalid, 0);
        // Godot's own main queue: copying on it keeps our submission ordered
        // with Godot's, so no cross-queue synchronization is needed. Zero means
        // this Godot build does not expose it and the shim picks its own queue.
        const queue = rd.getDriverResource(.driver_resource_command_queue, si.rid_invalid, 0);
        const family = rd.getDriverResource(.driver_resource_queue_family, si.rid_invalid, 0);
        if (device == 0 or physical == 0 or instance == 0) {
            log.err("RD is not Vulkan (or exposes no driver resources); dma-buf import unavailable.", .{});
            return false;
        }

        const importer = nv_vk_import_create(
            instance,
            physical,
            device,
            queue,
            @truncate(family),
        ) orelse {
            log.err("Vulkan dma-buf importer failed to start (see stderr for the Vulkan error).", .{});
            return false;
        };

        self.rd = rd;
        self.importer = importer;
        log.info("Vulkan dma-buf import ready (queue family {d}, {s} queue).", .{
            @as(u32, @truncate(family)),
            if (queue != 0) "Godot's" else "own",
        });
        return true;
    }

    /// RD texture RIDs for the next plane pair, created (or rebuilt after a
    /// resolution change) as needed. Returns null on failure.
    fn planeSlot(self: *VulkanSurfaceImporter, width: i32, height: i32) ?*PlaneSlot {
        const rd = self.rd orelse return null;

        // Resolution change: drop every slot, they are all the wrong size.
        if (self.slots[self.next_slot].width != 0 and
            (self.slots[self.next_slot].width != width or self.slots[self.next_slot].height != height))
        {
            for (&self.slots) |*slot| {
                si.freePlaneRids(rd, slot.luma, slot.chroma);
                slot.* = .{};
            }
            self.next_slot = 0;
        }

        const slot = &self.slots[self.next_slot];
        self.next_slot = (self.next_slot + 1) % plane_ring_depth;
        if (slot.luma.isValid() and slot.chroma.isValid() and slot.width == width and slot.height == height) {
            return slot;
        }

        si.freePlaneRids(rd, slot.luma, slot.chroma);
        slot.* = .{ .width = width, .height = height };

        const is_10bit = self.raw_code_shift != 0;
        const chroma_width = @divTrunc(width + 1, 2);
        const chroma_height = @divTrunc(height + 1, 2);
        slot.luma = createPlaneTexture(rd, si.planeFormat(is_10bit, false), width, height) orelse {
            slot.* = .{};
            return null;
        };
        slot.chroma = createPlaneTexture(rd, si.planeFormat(is_10bit, true), chroma_width, chroma_height) orelse {
            si.freePlaneRids(rd, slot.luma, si.rid_invalid);
            slot.* = .{};
            return null;
        };
        return slot;
    }

    /// Import one decoded frame into RD plane textures. The dma-buf copy is
    /// submitted and fenced before returning, so the textures are ready for the
    /// compute pass the caller dispatches next.
    pub fn import(self: *VulkanSurfaceImporter, frame_info: core.backend.VideoFrame) si.ImportResult {
        var out: PlaneTextures = .{};
        const importer = self.importer orelse return .transient_failure;
        const handle = frame_info.native_handle orelse return .bad_frame;
        const frame: *const c_frame = @ptrCast(@alignCast(handle));
        const rd = self.rd orelse return .transient_failure;

        // Only the two hardware biplanar formats this importer understands.
        const is_10bit = switch (frame.pixel_format) {
            @intFromEnum(PixelFormatTag.nv12) => false,
            @intFromEnum(PixelFormatTag.x420) => true,
            else => {
                log.err("unsupported decoder pixel format {d}.", .{frame.pixel_format});
                return .bad_frame;
            },
        };
        self.raw_code_shift = if (is_10bit) 6 else 0;

        const width = frame_info.width;
        const height = frame_info.height;
        if (width <= 0 or height <= 0) return .bad_frame;

        const slot = self.planeSlot(width, height) orelse {
            log.err("plane texture creation failed for {}x{}.", .{ width, height });
            return .transient_failure;
        };

        const luma_image = rd.getDriverResource(.driver_resource_texture, slot.luma, 0);
        const chroma_image = rd.getDriverResource(.driver_resource_texture, slot.chroma, 0);
        if (luma_image == 0 or chroma_image == 0) {
            log.err("RD did not yield a VkImage for the plane textures.", .{});
            return .transient_failure;
        }

        const result = nv_vk_import_frame(
            importer,
            frame,
            luma_image,
            width,
            height,
            chroma_image,
            @divTrunc(width + 1, 2),
            @divTrunc(height + 1, 2),
        );
        if (result != .ok) {
            // A frame that will not import is not a capability failure by
            // itself: a torn-down VAAPI surface pool or a decoder hiccup can
            // fail one frame. Report it as transient so the session continues.
            return .transient_failure;
        }

        // The copy already cropped to the display aperture, so there is no
        // crop rect left for the present shader to apply.
        out.luma = slot.luma;
        out.chroma = slot.chroma;
        out.width = width;
        out.height = height;
        out.metadata = si.PresentationMetadata.fromFrame(frame_info);
        out.metadata.crop = .{};
        out.metadata.raw_code_shift = self.raw_code_shift;
        // Plane textures outlive the frame: they are recycled by the importer's
        // own ring, so nothing to release here.
        out.release = .{};
        return .{ .success = out };
    }

    /// Zero: Linux never copies pixels through CPU memory.
    pub fn cpuCopyCount(self: *const VulkanSurfaceImporter) u64 {
        _ = self;
        return 0;
    }

    /// Free the plane-texture ring and the Vulkan importer. Called from the
    /// present pipeline's shutdown after the retire-ring has drained.
    pub fn deinit(self: *VulkanSurfaceImporter) void {
        if (self.rd) |rd| {
            for (&self.slots) |*slot| {
                si.freePlaneRids(rd, slot.luma, slot.chroma);
                slot.* = .{};
            }
        }
        if (self.importer) |importer| {
            nv_vk_import_destroy(importer);
            self.importer = null;
        }
        self.rd = null;
    }
};

/// Create one plane texture: a plain 2D texture with SAMPLING (the compute pass
/// samples it) and CAN_COPY_TO (the importer's own transfer writes it).
fn createPlaneTexture(rd: *RenderingDevice, format: RenderingDevice.DataFormat, width: i32, height: i32) ?Rid {
    const tf = RdTextureFormat.init();
    defer if (tf.unreference()) tf.destroy();
    tf.setFormat(format);
    tf.setWidth(@intCast(width));
    tf.setHeight(@intCast(height));
    tf.setDepth(1);
    tf.setArrayLayers(1);
    tf.setMipmaps(1);
    tf.setTextureType(.texture_type_2d);
    tf.setUsageBits(.{
        .texture_usage_sampling_bit = true,
        // Both bits map to VK_IMAGE_USAGE_TRANSFER_DST_BIT in Godot's Vulkan
        // driver; asking for both makes the copy legal even if one of the
        // mappings changes (a missing TRANSFER_DST is undefined behaviour, not
        // an error, so it would fail silently with Vulkan validation off).
        .texture_usage_can_copy_to_bit = true,
        .texture_usage_can_update_bit = true,
    });

    const view = RdTextureView.init();
    defer if (view.unreference()) view.destroy();

    const rid = rd.textureCreate(tf, view, .{});
    if (!rid.isValid()) return null;
    return rid;
}
