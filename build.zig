const std = @import("std");
const Build = std.Build;

/// LunaStream 构建入口。
///
/// 现阶段只搭建 core（与 Godot 无关的纯 Zig 逻辑）的构建与测试。
/// GDExtension 目标（需要 gdzig 绑定与 Godot 头文件）在推进表中的
/// "VideoStream / VideoStreamPlayback / 资源加载器"那一步接入，见 docs/ROADMAP.md。
pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    // 与源工程一致的取值方式：0.16 的 standardOptimizeOption 语义与这里不同，
    // 显式声明默认值可以让 `zig build test` 在本地与 CI 上行为一致。
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "优化模式") orelse .ReleaseSafe;

    // --- core：纯 Zig，无 Godot、无 RenderingDevice、无平台 SDK 类型 ---
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_tests = b.addTest(.{ .root_module = core_mod });

    const test_step = b.step("test", "运行 core 单元测试（不需要 Godot）");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
}
