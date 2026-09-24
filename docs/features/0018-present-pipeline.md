# 0018 · 呈现管线（进行中）

| 项 | 值 |
|---|---|
| 状态 | **进行中**：着色器、推送常量与管线代码已落地；**引擎内的 GLSL→SPIR-V 没通过**，自检暂未接入判据 |
| 阶段 | P0 |
| 依赖 | 0013（CPU 导入器）、0014（分发）、0015（Metal 导入器） |

## 这个功能点要做什么

把"导入进 GPU 的两块平面"变成"可上屏的 RGBA 纹理"：

```
导入结果（亮度 + 交织色度，两块纹理）
        │  nv12_to_rgba.comp（共享 GLSL compute）
        ▼
稳定输出纹理（RGBA8，RID 跨帧不变）
        │
        ▼
VideoStreamPlayer.get_video_texture()
```

## 已经落地的三块

### 1. 着色器 `src/shaders/nv12_to_rgba.comp`

NV12 / 右对齐 16 位半平面 → RGBA 的 compute。**刻意不含任何数值常数**：归一化与
YCbCr→RGB 的四个系数全部从推送常量进来，而那些常数由 core 的色彩层算。代价是每帧
多传 48 字节，收益是 CPU 与 GPU 的数学只有一份——0006 里"以后要写一条解析着色器源码、
比对两边常数的测试"那笔欠账，从结构上就不需要了。

### 2. 推送常量 `src/core/push_constants.zig`

48 字节的 `extern struct` + `fromColorimetry(位深, 矩阵, 范围, raw_code_shift)`。
左对齐容器（P010 / x420）的右移折进 `sample_scale`（`65535 / 2^shift`）。

### 3. ABI 守卫 `src/shaders/nv12_shader_abi_test.zig`

把着色器当**文本**读进来，解析 `push_constant` 块的字段名与类型，按顺序与 Zig 结构体
逐项比对，并检查"着色器侧全 float、Zig 侧全 f32、48 字节且是 16 的倍数"。这是 CPU/GPU
之间的 ABI——顺序错了编译器两边都不报，只会变成"颜色不对、画面错位"。

`@embedFile` **不能跨出模块根目录**（实测报 `embed of file outside package path`），
所以着色器自己成了一个模块（`src/shaders/shader_sources.zig`），呈现管线与 ABI 守卫
都从它取源码。

### 4. 管线 `src/godot/present_pipeline.zig`

建 shader（GLSL→SPIR-V→RID）、compute 管线、采样器（线性 + 边缘钳位）、**稳定的
RGBA8 输出纹理**（`storage` + `sampling`，可选 `can_copy_from` 供自检读回）、按
`(luma, chroma)` 缓存 uniform set（软解导入器复用纹理，命中率高），以及 `present()`
的完整派发序列。

## 已知问题：着色器在引擎里编不过（本步的卡点）

自检里那两段（`checkPresentPipeline` / `verifyPresentOutput`）**已经写好但暂未接入
判据**，因为实测：

```
ERROR: Can't create a shader from an errored bytecode. Check errors in source bytecode.
[importer] FAIL 建呈现管线（ShaderCompileFailed）
```

即 `shaderCompileSpirvFromSource` 返回的对象里 compute 阶段带着编译错误。已经做过的
排查与排除：

| 项 | 结果 |
|---|---|
| `#[compute]` / `#version 450` 的位置 | 已提到文件最前两行（原先在一串注释之后），**仍然失败** |
| 错误信息 | Godot 不把 GLSL 报错打到 stderr；`RdShaderSpirv.getStageCompileError()` 返回的是 gdzig 的 `String`，而它**没有到切片的转换入口**，所以拿不到具体文本 |
| 自检环境 | 呈现管线目前建在**本地** RenderingDevice 上（0013 的读回限制所致）——"本地设备是否带 glslang"是下一个要排除的假设 |

**下一步（按顺序）**：

1. 拿到 Godot 的 GLSL 报错文本。两条路：给 `String` 补一个到切片的转换（例如经
   `PackedByteArray`），或在 Godot 编辑器里手工编同一份 `.comp` 看报错。
2. 按报错修 GLSL；若确认是"本地设备没有 glslang"，则把呈现管线建在主设备上，
   另外解决"主设备的输出纹理读不回来"（0013 已经记录过这个限制）——可能要改成
   "在主设备上跑 compute、经 texture_copy 拷到本地设备读回"。
3. 接线后重新跑 `zig build godot-importer-selftest`，并把这两段从 `comptime` 引用
   改回真正的判据。

在这之前，**不把这两段算作通过**：`RESULT=PASS` 里没有它们的位置（代码仍参与编译，
接口一变就会红）。

## 验证状态

| 项 | 状态 |
|---|---|
| 推送常量与色彩层的一致性 | ✅ 单测覆盖（`zig build test`） |
| 着色器与推送常量的 ABI | ✅ 单测覆盖（4 项） |
| 引擎内 GLSL→SPIR-V | ❌ **未通过**（见上） |
| 端到端出画（读回 RGBA 与 core 期望比对） | ⏸ 代码已写好，待上面两条解决后接入判据 |

```bash
zig build test                        # 138/138（128 core + 6 ffsw ABI + 4 着色器 ABI）
zig build godot-importer-selftest     # 43/43（0013/0014/0015 的既有检查，未受影响）
```
