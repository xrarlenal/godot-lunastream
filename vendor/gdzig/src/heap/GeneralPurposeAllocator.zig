//! A wrapper around multiple allocator implementations based on the build target.
//!
//! | Target                         | Implementation            |
//! | ------------------------------ | ------------------------- |
//! | Testing                        | `std.heap.DebugAllocator` |
//! | WebAssembly                    | `gdzig.engine_allocator`  |
//! | `.ReleaseSafe`/`.Debug`        | `std.heap.DebugAllocator` |
//! | `.ReleaseFast`/`.ReleaseSmall` | Passthrough               |
//!
//! ## Usage
//!
//! ```zig
//! var gpa: GeneralPurposeAllocator = .init;
//! ```
//!

const GeneralPurposeAllocator = @This();

const Strategy = enum { testing, wasm, safe, fast };

const strategy: Strategy = if (builtin.is_test)
    .testing
else if (builtin.target.cpu.arch.isWasm())
    .wasm
else switch (builtin.mode) {
    .ReleaseSafe, .Debug => .safe,
    .ReleaseFast, .ReleaseSmall => .fast,
};

const Impl = switch (strategy) {
    .testing => DebugAllocator(.{
        .stack_trace_frames = if (std.debug.sys_can_stack_trace) 10 else 0,
        .resize_stack_traces = true,
        .canary = @truncate(0x2731e675c3a701ba),
    }),
    .safe => DebugAllocator(.{}),
    .fast, .wasm => void,
};

pub const init: GeneralPurposeAllocator = .{};

impl: Impl = switch (strategy) {
    .testing, .safe => .{ .backing_allocator = engine_allocator },
    .fast, .wasm => {},
},

pub fn allocator(self: *GeneralPurposeAllocator) Allocator {
    return switch (strategy) {
        inline .testing, .safe => self.impl.allocator(),
        .fast, .wasm => engine_allocator,
    };
}

pub fn deinit(self: *GeneralPurposeAllocator) std.heap.Check {
    return switch (strategy) {
        .safe => self.impl.deinit(),
        inline else => .ok,
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator;
const builtin = @import("builtin");

const gdzig = @import("gdzig");
const engine_allocator = gdzig.heap.engine_allocator;
