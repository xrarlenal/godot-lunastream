//! windows_surface_importer.zig — the Windows surface importer the present
//! pipeline uses, shaped exactly like MetalSurfaceImporter.
//!
//! Windows can run Godot's Vulkan or D3D12 RenderingDevice driver, and this
//! build links two concrete importers: a D3D12 zero-copy path and a CPU-copy
//! fallback. The choice depends only on the active RD driver name and the Godot
//! version, so at initialize() this thin wrapper reads both from Godot's
//! singletons (RenderingServer + Engine), asks the pure
//! importer_selector.selectImporter which path to take, instantiates that
//! concrete importer, and delegates every later call to it. This is the ONE
//! place the driver/version selection happens — the present pipeline stays
//! platform- and driver-agnostic.
//!
//! The DXGI Vulkan zero-copy path the C++ port also carried is not ported (see
//! importer_selector's module doc comment); Vulkan on Windows always takes the
//! CPU-copy fallback here.

const std = @import("std");

const core = @import("core");

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const RenderingServer = godot.class.RenderingServer;
const Engine = godot.class.Engine;
const String = godot.builtin.String;
const Dictionary = godot.builtin.Dictionary;
const Variant = godot.builtin.Variant;

const importer_selector = @import("importer_selector.zig");
const selectImporter = importer_selector.selectImporter;
const ImporterKind = importer_selector.ImporterKind;

const si = @import("surface_importer.zig");
const ImportResult = si.ImportResult;

const D3D12SurfaceImporter = @import("d3d12_surface_importer.zig").D3D12SurfaceImporter;
const CpuCopySurfaceImporter = @import("cpu_copy_surface_importer.zig").CpuCopySurfaceImporter;

const log = std.log.scoped(.native_video_windows_import);

/// The active concrete importer, chosen at initialize().
const Concrete = union(enum) {
    d3d12: D3D12SurfaceImporter,
    cpu_copy: CpuCopySurfaceImporter,
};

pub const WindowsSurfaceImporter = struct {
    allocator: std.mem.Allocator,
    concrete: ?Concrete = null,
    // Kept so the runtime CPU-copy fallback can bind a fresh importer.
    rd: ?*RenderingDevice = null,
    pub fn init(allocator: std.mem.Allocator) WindowsSurfaceImporter {
        return .{ .allocator = allocator };
    }

    /// Read driver name + Godot version from the singletons, select the import
    /// path, instantiate it, and bind it to RD. Returns whatever the concrete
    /// importer's initialize() returns. If the D3D12 path is selected but its
    /// importer cannot bind a D3D12 device, degrade to the CPU-copy path.
    pub fn initialize(self: *WindowsSurfaceImporter, rd: *RenderingDevice) bool {
        if (self.concrete != null) return self.isInitialized();
        self.rd = rd;

        var driver_buf: [64]u8 = undefined;
        var driver_str = RenderingServer.getCurrentRenderingDriverName();
        defer driver_str.deinit();
        const driver = driver_str.toUtf8Buf(driver_buf[0..]);

        const major, const minor = readGodotVersion();
        const kind = selectImporter(driver, major, minor);
        log.info("selected {s} import path (driver \"{s}\", Godot {d}.{d}).", .{ @tagName(kind), driver, major, minor });

        switch (kind) {
            .d3d12 => {
                self.concrete = .{ .d3d12 = D3D12SurfaceImporter.init(self.allocator) };
                if (self.concrete.?.d3d12.initialize(rd)) return true;
                // Could not bind Godot's D3D12 device; fall back permanently.
                log.warn("D3D12 importer failed to initialize; falling back to CPU-copy import.", .{});
                return self.degradeToCpuCopy(rd);
            },
            .cpu_copy => {
                self.concrete = .{ .cpu_copy = CpuCopySurfaceImporter.init(self.allocator) };
                return self.concrete.?.cpu_copy.initialize(rd);
            },
        }
    }

    pub fn isInitialized(self: *const WindowsSurfaceImporter) bool {
        const c = self.concrete orelse return false;
        return switch (c) {
            .d3d12 => |*imp| imp.isInitialized(),
            .cpu_copy => |*imp| imp.isInitialized(),
        };
    }

    pub fn import(self: *WindowsSurfaceImporter, frame_info: core.backend.VideoFrame) ImportResult {
        const c = &(self.concrete orelse return .transient_failure);
        switch (c.*) {
            .d3d12 => |*imp| {
                const result = imp.import(frame_info);
                switch (result) {
                    .capability_unavailable => {},
                    else => return result,
                }
                log.warn("D3D12 zero-copy capability unavailable; falling back to CPU-copy import permanently.", .{});
                const rd = self.rd orelse return .transient_failure;
                if (!self.degradeToCpuCopy(rd)) return .transient_failure;
                return self.concrete.?.cpu_copy.import(frame_info);
            },
            .cpu_copy => |*imp| return imp.import(frame_info),
        }
    }

    /// Tear down the current D3D12 importer and switch `self.concrete` to a
    /// freshly constructed CPU-copy importer bound to `rd`, for the rest of
    /// this importer's life. Called both when initialize() can't bind a D3D12
    /// device and when the first import() finds the zero-copy pipeline can't
    /// come up (cross-adapter OpenSharedHandle failure).
    ///
    /// Atomic in the sense that matters: `self.concrete` never holds the
    /// torn-down D3D12 importer once this returns. On failure (cpu_copy itself
    /// won't initialize — should not happen; texture_create/texture_update
    /// need no particular RD driver) `self.concrete` is left null rather than
    /// pointing at an importer that lies about being usable, so callers must
    /// go through isInitialized()/import(), both of which treat a null
    /// concrete as "not ready" rather than crashing.
    fn degradeToCpuCopy(self: *WindowsSurfaceImporter, rd: *RenderingDevice) bool {
        if (self.concrete) |*c| {
            if (c.* == .d3d12) c.d3d12.deinit();
        }
        self.concrete = null;
        var cpu_copy = CpuCopySurfaceImporter.init(self.allocator);
        if (!cpu_copy.initialize(rd)) return false;
        self.concrete = .{ .cpu_copy = cpu_copy };
        return true;
    }

    /// Frames imported through the CPU-copy path so far this session — the
    /// one sanctioned exception to the zero-copy contract, counted honestly
    /// whether this session ran CPU-copy from the start or degraded into it
    /// mid-flight from a failed D3D12 zero-copy attempt.
    pub fn cpuCopyCount(self: *const WindowsSurfaceImporter) u64 {
        const c = &(self.concrete orelse return 0);
        return switch (c.*) {
            .d3d12 => 0,
            .cpu_copy => |*imp| imp.cpu_copy_count,
        };
    }

    pub fn deinit(self: *WindowsSurfaceImporter) void {
        if (self.concrete) |*c| {
            switch (c.*) {
                .d3d12 => |*imp| imp.deinit(),
                .cpu_copy => |*imp| imp.deinit(),
            }
            self.concrete = null;
        }
    }
};

/// Read Godot's major/minor from the Engine singleton's version_info dictionary.
/// Missing/non-integer fields fall back to 0, which selectImporter treats as a
/// pre-4.5 engine (CPU-copy).
fn readGodotVersion() struct { i32, i32 } {
    var vi = Engine.getVersionInfo();
    defer vi.deinit();
    return .{ versionField(&vi, "major"), versionField(&vi, "minor") };
}

fn versionField(vi: *const Dictionary, comptime name: [:0]const u8) i32 {
    var key = String.fromLatin1(name);
    defer key.deinit();
    var key_v = Variant.init(String, key);
    defer key_v.deinit();
    var value = vi.get(key_v, .{});
    defer value.deinit();
    return @intCast(value.as(i64) orelse 0);
}
