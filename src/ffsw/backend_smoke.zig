//! ffsw 后端适配器的离线烟测：不需要 Godot，直接通过 `core.backend.Backend` 接口
//! 打开一段流并把帧全部解出来。
//!
//! 为什么值得单独一条：适配器是"扩展里真正跑解码时走的那个对象"——它的 vtable 转发、
//! C 帧到 `VideoFrame` 的翻译、以及 `release_hook` 接槽位归还，这三件事只有在真解一段
//! 流的时候才会被走到。core 的调度器测试用的是假后端，覆盖不到这里。
//!
//! 用法：`backend_smoke <视频文件或 URL>`

const std = @import("std");

const core = @import("core");
const ffsw = @import("ffsw");

pub fn main(init: std.process.Init) !u8 {
    // Zig 0.16 的入口把参数放在 `Init` 里（`std.process.argsAlloc` 那套已经没了）。
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("用法: backend_smoke <视频文件或 URL>\n", .{});
        return 2;
    }
    const path = args[1];

    var adapter = ffsw.FfswBackend.init() catch |err| {
        std.debug.print("创建后端失败: {s}\n", .{@errorName(err)});
        return 1;
    };
    const backend = adapter.backend();
    defer backend.deinit();

    if (!backend.open(path)) {
        std.debug.print("打开失败: {s}\n", .{path});
        return 1;
    }
    defer backend.close();

    const width = backend.videoWidth();
    const height = backend.videoHeight();
    const duration = backend.durationSeconds();
    const color = backend.colorimetry();
    std.debug.print("尺寸 {d}x{d}  时长 {d:.3}s  matrix={d} range={d} depth={d}\n", .{
        width, height, duration, @intFromEnum(color.matrix), @intFromEnum(color.range), color.bit_depth,
    });

    var frames: usize = 0;
    var first_pts: f64 = 0.0;
    var last_pts: f64 = 0.0;
    var monotonic = true;
    var bytes: u64 = 0;
    while (backend.nextVideoFrame()) |frame| {
        defer frame.release();
        if (frames == 0) first_pts = frame.pts_seconds;
        if (frame.pts_seconds < last_pts) monotonic = false;
        last_pts = frame.pts_seconds;
        // 通过接口拿到的帧必须是"CPU 平面"形状——这正是软解路径的契约。
        if (frame.surface_kind != .cpu_nv12) {
            std.debug.print("帧的 surface_kind 不是 cpu_nv12\n", .{});
            return 1;
        }
        const y = frame.cpu.y orelse return 1;
        const uv = frame.cpu.uv orelse return 1;
        _ = y;
        _ = uv;
        bytes += @as(u64, frame.cpu.y_stride) * @as(u64, @intCast(frame.height));
        bytes += @as(u64, frame.cpu.uv_stride) * @as(u64, @intCast(@divTrunc(frame.height + 1, 2)));
        frames += 1;
    }

    std.debug.print("解出 {d} 帧，PTS {d:.3} -> {d:.3}s，净载荷 {d} 字节\n", .{
        frames, first_pts, last_pts, bytes,
    });
    std.debug.print("PTS 单调: {s}\n", .{if (monotonic) "是" else "否"});

    if (frames == 0) {
        std.debug.print("SMOKE=FAIL（一帧都没解出来）\n", .{});
        return 1;
    }
    std.debug.print("SMOKE=PASS\n", .{});
    return 0;
}
