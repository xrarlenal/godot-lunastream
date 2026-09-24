//! importer_selector — pure-function importer selection for Windows.
//!
//! On Windows, RenderingDevice can run Godot's Vulkan or D3D12 driver, and
//! this project links two SurfaceImporter implementations: a D3D12
//! zero-copy path and a CPU-copy fallback. The choice between them depends
//! only on the active RenderingDevice driver name and the Godot engine
//! version, so it is expressed here as a pure function with zero Godot
//! dependencies — selectable and testable on any host, no RenderingDevice
//! or platform SDK required, even though it lives alongside the Godot-layer
//! importers it chooses between. windows_surface_importer.zig is the
//! singleton-reading factory shell that calls this from live Godot/
//! RenderingServer state.
//!
//! main's C++ port also carried a third importer, a Vulkan external-memory
//! path through DXGI shared handles (zero-copy from the Vulkan driver). It
//! was hard-disabled there (a texture_create_from_extension aspect bug
//! mis-binds NV12 planes until an upstream Godot fix lands) and is not
//! ported here: this build only ever chooses between the D3D12 path and the
//! CPU-copy fallback. Vulkan on Windows always takes CPU-copy.

const std = @import("std");

/// The two Windows import paths this build supports.
pub const ImporterKind = enum {
    // D3D12 RD driver, Godot >= 4.5: the D3D12 zero-copy path.
    // Unavailable before 4.5 because texture_create_from_extension is
    // unimplemented for the D3D12 RD driver.
    d3d12,

    // Fallback for everything else (including the Vulkan RD driver): a CPU
    // readback from the decoder's D3D11 NV12 texture into RD R8/RG8
    // textures via texture_update.
    cpu_copy,
};

/// Decide which Windows import path to instantiate.
///
///   driver_name — the RenderingDevice driver name ("d3d12", "vulkan", or
///                 anything else), matched by exact equality.
///   godot_major — Engine version major (e.g., 4 for Godot 4.x).
///   godot_minor — Engine version minor (e.g., 5 for "4.5").
///
/// Pure function of its inputs: no singletons, no platform API calls, no
/// side effects.
pub fn selectImporter(driver_name: []const u8, godot_major: i32, godot_minor: i32) ImporterKind {
    if (std.mem.eql(u8, driver_name, "d3d12")) {
        if (godot_major > 4 or (godot_major == 4 and godot_minor >= 5)) {
            return .d3d12;
        }
        return .cpu_copy;
    }
    return .cpu_copy;
}

// =======================================================================
// D3D12 driver
// =======================================================================

test "D3D12 on Godot 4.5 selects D3D12 importer" {
    try std.testing.expectEqual(ImporterKind.d3d12, selectImporter("d3d12", 4, 5));
}

test "D3D12 on Godot 4.6 selects D3D12 importer" {
    try std.testing.expectEqual(ImporterKind.d3d12, selectImporter("d3d12", 4, 6));
}

test "D3D12 on Godot 5.0 selects D3D12 importer" {
    try std.testing.expectEqual(ImporterKind.d3d12, selectImporter("d3d12", 5, 0));
}

test "D3D12 on Godot 4.4 falls back to CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("d3d12", 4, 4));
}

test "D3D12 on Godot 4.0 falls back to CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("d3d12", 4, 0));
}

test "D3D12 on Godot 3.x falls back to CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("d3d12", 3, 17));
}

// =======================================================================
// Vulkan (non-D3D12) driver always falls back to CPU copy, at any version
// (the DXGI zero-copy path is not ported — see module doc comment).
// =======================================================================

test "Vulkan driver selects CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("vulkan", 4, 5));
}

test "Vulkan driver, any version, selects CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("vulkan", 4, 0));
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("vulkan", 4, 4));
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("vulkan", 4, 100));
}

// =======================================================================
// Unknown or future driver names fall to CPU copy.
// =======================================================================

test "Unknown driver name selects CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("metal", 4, 5));
}

test "Empty driver name selects CPU copy" {
    try std.testing.expectEqual(ImporterKind.cpu_copy, selectImporter("", 4, 5));
}
