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
