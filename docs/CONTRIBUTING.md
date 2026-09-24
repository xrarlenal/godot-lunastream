# 开发约定

本仓库按"一个功能点一次提交"的节奏推进。复刻源工程（LunaFusion 的
`third_party/native_video/`）时，不整体搬代码，而是逐个功能点重写、逐个验证。

## 四条铁律

每完成一个功能点，提交必须同时包含这三样，缺一不可：

1. **实现代码** —— 该功能点的全部代码
2. **单元测试** —— 针对该功能点的测试，随代码同一次提交
3. **功能文档** —— `docs/features/NNNN-<slug>.md`，说明这次提交做了什么

并且：**一次提交只做一件事**。功能点没做完不开新提交，做完就立刻提交。

## 提交信息

采用 Conventional Commits 前缀 + 中文描述：

```
feat(core): 单调时钟与播放时钟推进
test(core): 帧队列的容量与背压语义
fix(ffsw): 修正 P010 右对齐归一化
chore: 初始化仓库骨架
```

scope 用目录名：`core` / `ffsw` / `ffvt` / `godot` / `vk` / `docs`。

## 验证

```bash
# core 单元测试：不需要 Godot、不需要 GPU、跨平台可跑
zig build test
```

后续功能点会依次加入 `zig build decode-smoke`（不需要 Godot 的真流解码烟测）
与扩展构建。**任何提交都必须让 `zig build test` 保持通过。**

## 工具链

| 工具 | 版本 | 用途 |
|---|---|---|
| Zig | **0.16.0**（精确版本） | 构建与测试 |
| Godot | 4.6.x | 第 19 个功能点起的绑定生成与实机验证 |

Zig 0.16.0 下载：`https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz`

## 目录约定

```
build.zig              构建入口
src/core/              纯逻辑：无 Godot、无平台 SDK（单元测试的主战场）
src/<backend>/         解码后端：每个平台一个目录
src/godot/             GDExtension 集成层
docs/features/         每个功能点一篇文档
docs/CONTRIBUTING.md   本文件
```

## 功能文档模板

见 `docs/features/TEMPLATE.md`。
