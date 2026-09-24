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

    // --- 着色器源码模块（0018） ---
    // `@embedFile` 不能跨出模块根目录，所以着色器自己是一个模块；呈现管线与 ABI
    // 守卫都从它取源码，源码因此只有一份。
    const shaders_mod = b.createModule(.{
        .root_source_file = b.path("src/shaders/shader_sources.zig"),
        .target = target,
        .optimize = optimize,
    });


    // --- 着色器推送常量的 ABI 守卫（0018） ---
    // 同样只 @embedFile 读文本再与 core 的结构体比对，不需要 GPU / Godot。
    const shader_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/shaders/nv12_shader_abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "shaders", .module = shaders_mod },
        },
    });
    const shader_abi_tests = b.addTest(.{ .root_module = shader_abi_mod });
    test_step.dependOn(&b.addRunArtifact(shader_abi_tests).step);

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

    // --- decode-smoke：不需要 Godot 的解码烟测（可直接喂 URL） ---
    //
    // 与 ffsw-selftest 分工不同：那个断言"解出来的对不对"，这个回答"这条源能不能
    // 解、解得快不快"，并且把它从"Godot 里能不能出画"里摘出来。硬性判据只有一条：
    // 一帧都没解出来就是失败；计时只作为观测（机器负载会让它抖，不该进判据）。
    //
    // 默认跑一个生成的 960x540 片源；要用在真实源上就直接调用构建产物：
    //   <zig-out 或 .zig-cache 里的 decode_smoke> rtsp://192.168.1.64:8554/stream --frames 300
    const smoke_step = b.step("decode-smoke", "解码烟测：不需要 Godot，可直接喂 URL（默认跑生成的片源）");

    const smoke_exe = b.addExecutable(.{
        .name = "decode_smoke",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    smoke_exe.root_module.addCSourceFiles(.{
        .files = &.{ "src/ffsw/ffsw_shim.c", "src/ffsw/decode_smoke.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    smoke_exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ ffmpeg_prefix, "include" }) });
    smoke_exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ ffmpeg_prefix, "lib" }) });
    for ([_][]const u8{ "avformat", "avcodec", "avutil", "swscale" }) |lib| {
        smoke_exe.root_module.linkSystemLibrary(lib, .{});
    }

    // 片源用 mpeg4（内置编码器）而不是 libx264：这一步要能在任何装了 FFmpeg 的
    // 机器上跑。想看 H.264 的性能基线，自己生成一段再喂给同一个二进制即可。
    const smoke_clip = b.pathJoin(&.{ ffsw_work, "smoke_960x540.mp4" });
    const smoke_gen = b.addSystemCommand(&.{
        "ffmpeg", "-y", "-v", "error",
        "-f",    "lavfi",
        "-i",    "testsrc=size=960x540:rate=30:duration=2",
        "-c:v",  "mpeg4",
        "-q:v",  "4",
        smoke_clip,
    });
    smoke_gen.step.dependOn(&ffsw_mkdir.step);

    const smoke_run = b.addRunArtifact(smoke_exe);
    smoke_run.stdio = .inherit;
    smoke_run.addArg(smoke_clip);
    smoke_run.step.dependOn(&smoke_gen.step);
    smoke_step.dependOn(&smoke_run.step);

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
            .{ .name = "shaders", .module = shaders_mod },
        },
    });

    // --- 解码后端 ffsw：C shim 编进扩展 + 链 FFmpeg（0018 的接线前置） ---
    //
    // 这一层以前只在离线自检与烟测里被链过，扩展本身没有它，所以引擎里根本解不了码。
    // 只在 macOS 目标上接：这条 dev 路径用的是 Homebrew 的 FFmpeg，随包分发（含 LGPL
    // 重编）是 0021 的事；Windows / Linux 的交叉编译不该被本机的 FFmpeg 布局绑住。
    if (target.result.os.tag == .macos) {
        const ffsw_mod = b.createModule(.{
            .root_source_file = b.path("src/ffsw/ffsw_backend.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "core", .module = core_mod }},
        });
        ffsw_mod.addIncludePath(b.path("src/ffsw"));
        ext_mod.addImport("ffsw", ffsw_mod);

        ext_mod.addIncludePath(b.path("src/ffsw"));
        ext_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ ffmpeg_prefix, "include" }) });
        ext_mod.addCSourceFile(.{
            .file = b.path("src/ffsw/ffsw_shim.c"),
            .flags = &.{"-std=c11"},
        });
        ext_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ ffmpeg_prefix, "lib" }) });
        for ([_][]const u8{ "avformat", "avcodec", "avutil", "swscale" }) |lib| {
            ext_mod.linkSystemLibrary(lib, .{});
        }

        // 适配器的离线烟测：不需要 Godot，直接通过 core 的后端接口解一段流。
        const backend_smoke_step = b.step("ffsw-backend-smoke", "解码后端适配器的离线烟测（不需要 Godot）");
        const backend_smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/ffsw/backend_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "ffsw", .module = ffsw_mod },
            },
        });
        backend_smoke_mod.addIncludePath(b.path("src/ffsw"));
        const backend_smoke_exe = b.addExecutable(.{
            .name = "backend_smoke",
            .root_module = backend_smoke_mod,
        });
        backend_smoke_exe.root_module.addCSourceFile(.{
            .file = b.path("src/ffsw/ffsw_shim.c"),
            .flags = &.{"-std=c11"},
        });
        backend_smoke_exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ ffmpeg_prefix, "include" }) });
        backend_smoke_exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ ffmpeg_prefix, "lib" }) });
        for ([_][]const u8{ "avformat", "avcodec", "avutil", "swscale" }) |lib| {
            backend_smoke_exe.root_module.linkSystemLibrary(lib, .{});
        }
        const backend_smoke_run = b.addRunArtifact(backend_smoke_exe);
        backend_smoke_run.stdio = .inherit;
        // 复用 ffsw-selftest 生成的片源，避免再拉一条 ffmpeg 调用出来。
        backend_smoke_run.addArg(b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "ffsw-selftest", "clip8.mp4" }));
        backend_smoke_run.step.dependOn(&gen8.step);
        backend_smoke_step.dependOn(&backend_smoke_run.step);

    }

    // 平台导入器需要的原生桥。头文件在所有平台都可见（自检要引用它的类型），
    // 但只有 macOS 才编译 Objective-C 实现并链框架——Windows / Linux 各有自己的
    // 平台导入器（0016 / 0017）。
    ext_mod.addIncludePath(b.path("src/ffvt"));
    if (target.result.os.tag == .macos) {
        ext_mod.addCSourceFile(.{
            .file = b.path("src/ffvt/cv_metal_bridge.m"),
            .flags = &.{ "-fno-objc-arc" },
        });
        for ([_][]const u8{ "Metal", "CoreVideo", "CoreGraphics", "Foundation" }) |framework| {
            ext_mod.linkFramework(framework, .{});
        }
    }

    // Windows 平台导入器（0016，从源工程搬入）依赖一层手写的 COM/D3D 绑定。
    // 只在 Windows 目标下把它挂成模块——别的平台既不编译也不解析这些文件。
    if (target.result.os.tag == .windows) {
        const win_mod = b.createModule(.{
            .root_source_file = b.path("src/win/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        ext_mod.addImport("win", win_mod);
    }

    // Linux 侧的原生 shim（0017，从源工程搬入）：dma-buf → VkImage 的导入。
    // 它**不链 libvulkan**（自己用 dlopen 解析 loader），所以这里只需要 Vulkan 头。
    // 头文件路径按机器给：默认取 Homebrew 的 /usr/local/include，可用
    // -Dvulkan-include=<dir> 覆盖（CI 上用系统包或 vcpkg 时就要覆盖）。
    if (target.result.os.tag == .linux) {
        const vulkan_include = b.option([]const u8, "vulkan-include", "Vulkan 头文件目录（Linux 目标编译 vk shim 用）") orelse "/usr/local/include";
        ext_mod.addIncludePath(b.path("src/ffva"));
        ext_mod.addIncludePath(.{ .cwd_relative = vulkan_include });
        ext_mod.addCSourceFile(.{
            .file = b.path("src/ffva/vk_import_shim.c"),
            .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
        });
        ext_mod.linkSystemLibrary("dl", .{});

        // 随包的 Vulkan Layer（0017）：Godot 自己的 Vulkan 后端不在 vkCreateDevice
        // 上启用 dma-buf 需要的那些设备扩展，插件从外部又插不进手，所以只能随包发一个
        // 标准 Layer 去补这一步。产物与清单必须同目录（清单里的 library_path 是相对
        // 自己的），装到扩展目录下的 luna_layer/——vulkan_layer_setup.zig 就是按这个
        // 相对位置在运行时找它的。
        const layer_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        layer_mod.addCSourceFile(.{
            .file = b.path("src/vulkan_layer/luna_ext_layer.c"),
            .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
        });
        layer_mod.addIncludePath(.{ .cwd_relative = vulkan_include });
        layer_mod.linkSystemLibrary("dl", .{});

        const layer = b.addLibrary(.{
            .name = "luna_ext_layer",
            .root_module = layer_mod,
            .linkage = .dynamic,
        });
        const layer_dir = "../example/gdextension-smoke/addons/lunastream/luna_layer";
        b.default_step.dependOn(&b.addInstallArtifact(layer, .{
            .dest_dir = .{ .override = .{ .custom = layer_dir } },
        }).step);
        b.default_step.dependOn(&b.addInstallFileWithDir(
            b.path("src/vulkan_layer/luna_ext_layer.json"),
            .{ .custom = layer_dir },
            "luna_ext_layer.json",
        ).step);
    }

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

    // --- 引擎侧自检：呈现层（CPU 导入器 + 纹理池） ---
    //
    // 需要**带渲染上下文**的 Godot：headless 下连 RenderingDevice 都没有，而这一步
    // 要真的创建纹理、上传、回读比对。所以它不加 --headless，会短暂开一个窗口。
    // 加 --quit-after 只是保底：脚本自己会 quit，万一脚本崩了就靠这个上限收场
    //（之前 GDScript 解析失败过一次，进程就那么一直挂着）。
    const godot_bin = opt_godot_path orelse "/Applications/Godot.app/Contents/MacOS/Godot";
    const importer_step = b.step("godot-importer-selftest", "引擎侧 CPU 导入器自检（需要带渲染上下文的 Godot）");
    const run_importer = b.addSystemCommand(&.{
        godot_bin,
        "--path",
        "example/gdextension-smoke",
        "--quit-after",
        "600",
        "res://importer_smoke.tscn",
    });
    run_importer.stdio = .inherit;
    run_importer.step.dependOn(&install.step);
    importer_step.dependOn(&run_importer.step);

    // --- 播放烟测（0018）：真的播一段流 ---
    //
    // 与上面那个的分工：importer-selftest 验证"导入器与呈现管线单独正确"，
    // 这个验证"接起来之后 VideoStreamPlayer 真的能播"。
    // 同样需要带渲染上下文的 Godot（呈现管线要 RenderingDevice），所以不加 --headless。
    // 片源路径用 `--` 传给脚本（Godot 的 OS.get_cmdline_user_args()），
    // 复用 ffsw-selftest 生成的那个片源。
    const playback_step = b.step("godot-playback-smoke", "播放烟测：真的播一段流（需要带渲染上下文的 Godot）");
    const run_playback = b.addSystemCommand(&.{
        godot_bin,
        "--path",
        "example/gdextension-smoke",
        "--quit-after",
        "1800",
        "res://playback_smoke.tscn",
        "--",
    });
    run_playback.addArg(b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "ffsw-selftest", "clip8.mp4" }));
    run_playback.stdio = .inherit;
    run_playback.step.dependOn(&install.step);
    run_playback.step.dependOn(&gen8.step);
    playback_step.dependOn(&run_playback.step);
}
