//! windows_import_common.zig — scaffolding shared by the two Windows
//! surface importers (cpu_copy_surface_importer.zig and
//! d3d12_surface_importer.zig): binding to the decoder's own D3D11 device,
//! the "cached texture, recreate on size/format change" pattern, and NV12/
//! P010 format detection. Pure D3D11/DXGI plumbing — no RenderingDevice, no
//! Godot types — so it stays a plain sibling of surface_importer.zig rather
//! than depending on it.

const std = @import("std");

const win = @import("mf").win;
const com = win.com;
const dxgi = win.dxgi;
const d3d11 = win.d3d11;

const core = @import("core");

/// The decoder texture's own device + immediate context, both AddRef'd by
/// the GetDevice/GetImmediateContext calls below. The caller releases both
/// (com.release) in its own teardown.
pub const DecoderDevice = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
};

/// Bind to the SAME device the decoder texture lives on: D3D11 resources are
/// per-device, so every op that touches `decoded` (CopySubresourceRegion,
/// view creation, ...) must run on this device, never a separately created
/// one. Returns null if GetDevice fails (a torn-down or foreign texture) —
/// the caller logs with its own module-scoped message.
pub fn bindDecoderDevice(decoded: *d3d11.ID3D11Texture2D) ?DecoderDevice {
    var dev: ?*d3d11.ID3D11Device = null;
    decoded.GetDevice(&dev);
    const device = dev orelse return null;
    var ctx: ?*d3d11.ID3D11DeviceContext = null;
    device.GetImmediateContext(&ctx);
    const context = ctx orelse return null;
    return .{ .device = device, .context = context };
}

/// NV12 (8-bit) or P010 (10-bit) — the only two decoder surface formats the
/// Windows importers accept. Returns null for anything else; the caller logs
/// and bails.
pub fn detectBitDepth(format: dxgi.DXGI_FORMAT) ?bool {
    return switch (format) {
        dxgi.DXGI_FORMAT_P010 => true,
        dxgi.DXGI_FORMAT_NV12 => false,
        else => null,
    };
}

/// A D3D11Texture2D recreated only when its size or format changes —
/// the "cached staging/intermediate texture" pattern both Windows importers
/// use (cpu_copy's per-slot readback staging texture, d3d12's blit
/// intermediate). Owns the texture; release() (or a fresh ensure() call)
/// frees the previous one before replacing it.
pub const CachedTex2D = struct {
    texture: ?*d3d11.ID3D11Texture2D = null,
    width: com.UINT = 0,
    height: com.UINT = 0,
    format: dxgi.DXGI_FORMAT = dxgi.DXGI_FORMAT_UNKNOWN,

    /// Reuse `texture` if it already matches width/height/format; otherwise
    /// release it and create a fresh one with the given usage/bind/CPU-access
    /// flags. Returns true once `texture` is ready to use; false (texture
    /// left null) if CreateTexture2D failed — the caller logs.
    pub fn ensure(
        self: *CachedTex2D,
        device: *d3d11.ID3D11Device,
        width: com.UINT,
        height: com.UINT,
        format: dxgi.DXGI_FORMAT,
        usage: d3d11.D3D11_USAGE,
        bind_flags: com.UINT,
        cpu_access_flags: com.UINT,
    ) bool {
        if (self.texture != null and self.width == width and self.height == height and self.format == format) {
            return true;
        }
        self.release();
        var desc = std.mem.zeroes(d3d11.D3D11_TEXTURE2D_DESC);
        desc.Width = width;
        desc.Height = height;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = format;
        desc.SampleDesc.Count = 1;
        desc.Usage = usage;
        desc.BindFlags = bind_flags;
        desc.CPUAccessFlags = cpu_access_flags;
        var tex: ?*d3d11.ID3D11Texture2D = null;
        if (com.FAILED(device.CreateTexture2D(&desc, null, &tex))) {
            self.width = 0;
            self.height = 0;
            self.format = dxgi.DXGI_FORMAT_UNKNOWN;
            return false;
        }
        self.texture = tex;
        self.width = width;
        self.height = height;
        self.format = format;
        return true;
    }

    pub fn release(self: *CachedTex2D) void {
        if (self.texture) |t| {
            com.release(t);
            self.texture = null;
        }
    }
};

/// A VideoFrame.crop rect resolved against the decoder's actual (possibly
/// macroblock-aligned) luma texture dimensions, plus its derived chroma crop.
/// Both Windows importers copy/sample only this rect out of the decoder
/// texture, so decoder padding never reaches the plane textures the present
/// shader samples.
pub const ResolvedCrop = struct {
    luma_x: com.UINT,
    luma_y: com.UINT,
    luma_width: com.UINT,
    luma_height: com.UINT,
    chroma_x: com.UINT,
    chroma_y: com.UINT,
    chroma_width: com.UINT,
    chroma_height: com.UINT,
};

/// Resolve `crop` (a VideoFrame's display-aperture rect) against the
/// decoder's actual luma texture size. `crop.width == 0` -- the
/// core.backend.CropRect "no crop metadata" sentinel -- and any
/// out-of-bounds rect both fall back to the full aligned texture (the exact
/// pre-crop-support behavior); a valid rect is clamped so it never reads past
/// the texture edge. The chroma crop halves every field with a floor
/// division, per CropRect's doc-commented half-pixel policy for 4:2:0
/// subsampling.
pub fn resolveCrop(crop: core.backend.CropRect, aligned_width: com.UINT, aligned_height: com.UINT) ResolvedCrop {
    const luma_width = if (crop.width > 0 and crop.width <= aligned_width) crop.width else aligned_width;
    const luma_height = if (crop.height > 0 and crop.height <= aligned_height) crop.height else aligned_height;
    const luma_x = @min(crop.x, aligned_width - luma_width);
    const luma_y = @min(crop.y, aligned_height - luma_height);
    return .{
        .luma_x = luma_x,
        .luma_y = luma_y,
        .luma_width = luma_width,
        .luma_height = luma_height,
        .chroma_x = luma_x / 2,
        .chroma_y = luma_y / 2,
        .chroma_width = luma_width / 2,
        .chroma_height = luma_height / 2,
    };
}
