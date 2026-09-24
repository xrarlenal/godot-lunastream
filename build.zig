const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");

/// LunaStream 构建入口。
///
/// 两个构建目标刻意分开：
///
/// - `zig build test` —— 只跑 core 单元测试，**不需要 Godot**，任何机器都能跑；
/// - `zig build`      —— 构建 GDExtension 并安装进示例工程，需要生成绑定。
///
/// 这个划分保证"逻辑对不对"与"绑定能不能用"是两件可以分别定位的事。
pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    // 与源工程一致的取值方式：0.16 的 standardOptimizeOption 语义与这里不同，
    // 显式声明默认值可以让 `zig build test` 在本地与 CI 上行为一致。
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "优化模式") orelse .ReleaseSafe;

    // 生成绑定需要一份 Godot：显式 -Dgodot-path > 环境变量 GODOT_PATH >
    // 交给 gdzig 按版本号下载（首次构建需要联网）。
    const env_godot = b.graph.environ_map.get("GODOT_PATH");
    const opt_godot_path = b.option([]const u8, "godot-path", "Godot 可执行文件路径（生成绑定用）") orelse env_godot;
    const opt_godot_version = b.option([]const u8, "godot-version", "下载指定版本的 Godot 用于生成绑定") orelse "4.6";
    // 精度必须与加载本扩展的 Godot 一致：gdzig 把 Variant/real_t 的内存布局
    // 在编译期定死，float 扩展加载进 double 引擎是布局不匹配。
    const opt_precision = b.option([]const u8, "precision", "浮点精度：float 或 double") orelse "float";

    // --- core：纯 Zig，无 Godot、无 RenderingDevice、无平台 SDK 类型 ---
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_tests = b.addTest(.{ .root_module = core_mod });

    const test_step = b.step("test", "运行 core 单元测试（不需要 Godot）");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // --- ffsw shim 的 C ABI 标签守卫 ---
    // 只 `@embedFile` 读头文件文本再与 core 枚举比对，因此同样不需要 FFmpeg、
    // 不需要 Godot，放在 `test` 步骤里对任何机器都成立。
    const ffsw_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/ffsw/ffsw_shim_abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core_mod }},
    });
    const ffsw_abi_tests = b.addTest(.{ .root_module = ffsw_abi_mod });
    test_step.dependOn(&b.addRunArtifact(ffsw_abi_tests).step);

    // --- ffsw shim：用真实 FFmpeg 编译，并跑端到端解码自检 ---
    //
    // 刻意与 `test` 分开：这一步需要 FFmpeg 的开发包（头文件 + 库）与 ffmpeg
    // 命令行（生成测试片源、产出对照用的 NV12），因此不属于"任何机器都能跑"
    // 的那一类。它换来的是这个 shim 最硬的证据：自检把**整条流**写成原始 NV12，
    // 与 ffmpeg 自己解的同一份逐字节比对。
    const ffmpeg_prefix = b.option([]const u8, "ffmpeg-prefix", "FFmpeg 安装前缀（头文件在 <prefix>/include，库在 <prefix>/lib）") orelse "/opt/homebrew";
    const ffsw_step = b.step("ffsw-selftest", "编译 ffsw shim 并跑端到端解码自检（需要 FFmpeg）");

    const ffsw_exe = b.addExecutable(.{
        .name = "ffsw_selftest",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    ffsw_exe.root_module.addCSourceFiles(.{
        .files = &.{ "src/ffsw/ffsw_shim.c", "src/ffsw/ffsw_selftest.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    ffsw_exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ ffmpeg_prefix, "include" }) });
    ffsw_exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ ffmpeg_prefix, "lib" }) });
    for ([_][]const u8{ "avformat", "avcodec", "avutil", "swscale" }) |lib| {
        ffsw_exe.root_module.linkSystemLibrary(lib, .{});
    }

    const ffsw_work = b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "ffsw-selftest" });
    const ffsw_mkdir = b.addSystemCommand(&.{ "mkdir", "-p", ffsw_work });

    // 场景一：8-bit 4:2:0（mpeg4 是内置编码器，不依赖外部库）。对照格式 nv12。
    const clip8 = b.pathJoin(&.{ ffsw_work, "clip8.mp4" });
    const dump8 = b.pathJoin(&.{ ffsw_work, "shim_nv12.raw" });
    const ref8 = b.pathJoin(&.{ ffsw_work, "ffmpeg_nv12.raw" });

    const gen8 = b.addSystemCommand(&.{
        "ffmpeg", "-y", "-v", "error",
        "-f",    "lavfi",
        "-i",    "testsrc=size=320x240:rate=25:duration=2",
        "-c:v",  "mpeg4",
        "-q:v",  "3",
        clip8,
    });
    gen8.step.dependOn(&ffsw_mkdir.step);

    const run8 = b.addRunArtifact(ffsw_exe);
    run8.stdio = .inherit;
    run8.addArg(clip8);
    run8.addArg("--dump");
    run8.addArg(dump8);
    run8.step.dependOn(&gen8.step);

    // 对照：同样的片源、同样的目标格式，交给 ffmpeg 自己解一遍。
    const ref_cmd8 = b.addSystemCommand(&.{
        "ffmpeg", "-y", "-v", "error",
        "-i",     clip8,
        "-pix_fmt", "nv12",
        "-fps_mode", "passthrough",
        "-f",         "rawvideo",
        ref8,
    });
    ref_cmd8.step.dependOn(&run8.step);

    const cmp8 = b.addSystemCommand(&.{ "cmp", dump8, ref8 });
    cmp8.step.dependOn(&ref_cmd8.step);
    ffsw_step.dependOn(&cmp8.step);

    // 场景二：10-bit 4:2:0。ffv1 也是内置编解码器（不依赖 libx264 的 10-bit 构建），
    // 对照格式是平面 10-bit——ffmpeg 没有"右对齐的 4:2:0 半平面"格式，所以这一侧
    // 只能按平面比（自检的转储会做一次无损拆交织，见 ffsw_selftest.c 的注释）。
    const clip10 = b.pathJoin(&.{ ffsw_work, "clip10.mkv" });
    const dump10 = b.pathJoin(&.{ ffsw_work, "shim_yuv420p10le.raw" });
    const ref10 = b.pathJoin(&.{ ffsw_work, "ffmpeg_yuv420p10le.raw" });

    const gen10 = b.addSystemCommand(&.{
        "ffmpeg", "-y", "-v", "error",
        "-f",       "lavfi",
        "-i",       "testsrc=size=320x240:rate=25:duration=2",
        "-pix_fmt", "yuv420p10le",
        "-c:v",     "ffv1",
        clip10,
    });
    gen10.step.dependOn(&ffsw_mkdir.step);

    const run10 = b.addRunArtifact(ffsw_exe);
    run10.stdio = .inherit;
    run10.addArg(clip10);
    run10.addArg("--dump");
    run10.addArg(dump10);
    run10.step.dependOn(&gen10.step);

    const ref_cmd10 = b.addSystemCommand(&.{
        "ffmpeg", "-y", "-v", "error",
        "-i",       clip10,
        "-pix_fmt", "yuv420p10le",
        "-fps_mode", "passthrough",
        "-f",         "rawvideo",
        ref10,
    });
    ref_cmd10.step.dependOn(&run10.step);

    const cmp10 = b.addSystemCommand(&.{ "cmp", dump10, ref10 });
    cmp10.step.dependOn(&ref_cmd10.step);
    ffsw_step.dependOn(&cmp10.step);

    // --- GDExtension：gdzig 绑定 + 扩展入口 ---
    const gdzig_dep = if (opt_godot_path) |godot_path| b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .precision = opt_precision,
        .@"godot-path" = godot_path,
    }) else b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .precision = opt_precision,
        .@"godot-version" = opt_godot_version,
    });

    const ext_mod = b.createModule(.{
        .root_source_file = b.path("src/godot/extension.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "godot", .module = gdzig_dep.module("gdzig") },
            .{ .name = "core", .module = core_mod },
        },
    });

    const extension = gdzig.addExtension(b, .{
        .name = "lunastream",
        .root_module = ext_mod,
        .entry_symbol = "lunastream_init",
        // 目前只需要 SCENE 级：类注册发生在这一级。Linux 的 dma-buf 那一层
        // 需要 CORE 级（必须在引擎建 VkInstance 之前挂上 Layer），等那时再改。
        .minimum_initialization_level = .scene,
        .target = target,
        .optimize = optimize,
    }) orelse return;

    if (optimize != .Debug) {
        extension.compile.root_module.strip = true;
        extension.compile.link_gc_sections = true;
    }

    // 装进示例工程的 addons/ 下——清单里的库路径是相对清单自己的，
    // 所以清单与产物必须同目录。
    const install = b.addInstallFileWithDir(
        extension.output,
        .{ .custom = "../example/gdextension-smoke/addons/lunastream" },
        extension.filename,
    );
    b.default_step.dependOn(&install.step);

    const extension_step = b.step("extension", "构建 GDExtension 并安装进示例工程");
    extension_step.dependOn(&install.step);
}
