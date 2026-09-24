//! plane_copy.zig — platform-neutral helpers for materialising plane textures.
//!
//! Two things every "pixels are already in reach" import path needs:
//!   * rows that arrive with a driver-aligned stride must be re-packed
//!     tightly, because RenderingDevice.texture_update expects tightly packed
//!     data and a source row (a mapped staging texture's RowPitch, or a
//!     decoder buffer's padded line) is generally wider than its exact width;
//!   * the resulting plane textures are ordinary sampling + can-update textures.
//!
//! These used to live inside cpu_copy_surface_importer.zig, but that file is
//! Windows-only (it imports the hand-written MF/D3D11 bindings), which locked
//! them away from the software-decode importer — which needs exactly the same
//! row packing on every platform. Both now live here. No platform SDK is
//! imported, so anything can use them.

const RenderingDevice = @import("godot").class.RenderingDevice;
const RdTextureFormat = @import("godot").class.RdTextureFormat;
const RdTextureView = @import("godot").class.RdTextureView;
const Rid = @import("godot").builtin.Rid;
const PackedByteArray = @import("godot").builtin.PackedByteArray;

/// Pack 8-bit plane rows tightly, cropped to `row_bytes` bytes per row
/// starting at byte offset `x_offset`, for `rows` rows starting at row
/// `y_offset` (the pitch may exceed the tight row width even before cropping).
pub fn packRows8bit(src: [*]const u8, row_pitch: usize, x_offset: usize, y_offset: usize, row_bytes: usize, rows: usize) PackedByteArray {
    var out = PackedByteArray.init();
    _ = out.resize(@intCast(row_bytes * rows));
    const dst: [*]u8 = @ptrCast(out.index(0));
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const src_row = src + (y + y_offset) * row_pitch + x_offset;
        @memcpy(dst[y * row_bytes ..][0..row_bytes], src_row[0..row_bytes]);
    }
    return out;
}

/// Pack 10-bit (P010) plane rows tightly AND shift each 16-bit sample right by
/// 6, converting P010's left-justified layout to the right-justified 10-bit-in-
/// 16 layout the shared present shader expects (matching macOS x420). Cropped
/// to `samples_per_row` 16-bit samples per row starting at sample offset
/// `x_offset`, for `rows` rows starting at row `y_offset`.
pub fn packRows10bit(src: [*]const u8, row_pitch: usize, x_offset: usize, y_offset: usize, samples_per_row: usize, rows: usize) PackedByteArray {
    var out = PackedByteArray.init();
    _ = out.resize(@intCast(samples_per_row * rows * @sizeOf(u16)));
    const dst: [*]u16 = @ptrCast(@alignCast(out.index(0)));
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const src_row: [*]const u8 = src + (y + y_offset) * row_pitch;
        const dst_row = dst + y * samples_per_row;
        var x: usize = 0;
        while (x < samples_per_row) : (x += 1) {
            // Read the little-endian 16-bit sample without assuming alignment.
            const sx = x + x_offset;
            const lo = src_row[sx * 2];
            const hi = src_row[sx * 2 + 1];
            const sample: u16 = (@as(u16, hi) << 8) | @as(u16, lo);
            dst_row[x] = sample >> 6;
        }
    }
    return out;
}

/// Pack 16-bit plane rows tightly, cropping to `samples_per_row` samples per
/// row starting at sample offset `x_offset`, for `rows` rows starting at row
/// `y_offset`. Each little-endian sample is shifted RIGHT by `shift` — pass 6
/// for P010's left-justified layout, 0 for an already right-justified source
/// (which is what the software decoder produces).
///
/// Split from packRows10bit (which hardcodes the P010 shift) so the software
/// path can state its own convention instead of being bent to match a hardware
/// one.
pub fn packRows16bit(
    src: [*]const u8,
    row_pitch: usize,
    x_offset: usize,
    y_offset: usize,
    samples_per_row: usize,
    rows: usize,
    shift: u4,
) PackedByteArray {
    var out = PackedByteArray.init();
    _ = out.resize(@intCast(samples_per_row * rows * @sizeOf(u16)));
    const dst: [*]u16 = @ptrCast(@alignCast(out.index(0)));
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const src_row: [*]const u8 = src + (y + y_offset) * row_pitch;
        const dst_row = dst + y * samples_per_row;
        var x: usize = 0;
        while (x < samples_per_row) : (x += 1) {
            // Read the little-endian 16-bit sample without assuming alignment.
            const sx = x + x_offset;
            const lo = src_row[sx * 2];
            const hi = src_row[sx * 2 + 1];
            const sample: u16 = (@as(u16, hi) << 8) | @as(u16, lo);
            dst_row[x] = sample >> shift;
        }
    }
    return out;
}

/// Create one RD plane texture (sampling + can-update) at w x h, in `format`.
pub fn createPlane(rd: *RenderingDevice, format: RenderingDevice.DataFormat, w: i64, h: i64) Rid {
    const tf = RdTextureFormat.init();
    defer if (tf.unreference()) tf.destroy();
    tf.setFormat(format);
    tf.setWidth(@intCast(w));
    tf.setHeight(@intCast(h));
    tf.setDepth(1);
    tf.setArrayLayers(1);
    tf.setMipmaps(1);
    tf.setTextureType(.texture_type_2d);
    tf.setUsageBits(.{ .texture_usage_sampling_bit = true, .texture_usage_can_update_bit = true });

    const view = RdTextureView.init();
    defer if (view.unreference()) view.destroy();

    return rd.textureCreate(tf, view, .{});
}
