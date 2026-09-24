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

## 排查记录：着色器在引擎里编不过（**已解决**）

第一版在引擎里报：

```
ERROR: Can't create a shader from an errored bytecode. Check errors in source bytecode.
```

**根因：着色器源码里不能写 `#[compute]`。** 那是 Godot 的 Shader 资源（GDShader）那套
的写法；而 `RenderingDevice.shaderCompileSpirvFromSource` 会把源码**原样**交给 glslang，
glslang 不认这个标记，于是在第一行就报预处理错误——Godot 只把它塞进
`RdShaderSpirv` 的阶段错误里，对外只剩上面那句没头没尾的话。

定位它的关键一步不是改代码，而是**换一个能看到报错的编译器**：本机有
`glslangValidator`（Homebrew 装的），把同一份 GLSL 去掉首行标记后交给它：

```bash
tail -n +2 src/shaders/nv12_to_rgba.comp > /tmp/nv12.comp
glslangValidator -V --target-env vulkan1.1 /tmp/nv12.comp   # 通过
```

glslang 说 GLSL 本身没问题 → 差异只可能在我喂给引擎的那份文本与它不同 → 只差
`#[compute]` 一行 → 去掉即通过。

顺带记两条这次的教训：

- `RdShaderSpirv.getStageCompileError()` 返回的是 gdzig 的 `String`，它**没有到切片的
  转换入口**（`toUtf8Buffer()` / `toAsciiBuffer()` 返回 `PackedByteArray`，再经
  `indexConst(0)` 才拿得到字节）。要长期依赖这条报错，得先把这段转换写上。
- 期间还试过"把 `#[compute]` 与 `#version` 提到最前两行"——那是个**错误假设**，
  失败原因与位置无关。留下这条是为了说明：报错文本拿不到时，改代码就是掷骰子，
  先换能说话的编译器才是对的。

## 验证状态

| 项 | 状态 |
|---|---|
| 推送常量与色彩层的一致性 | ✅ 单测覆盖（`zig build test`） |
| 着色器与推送常量的 ABI | ✅ 单测覆盖（4 项） |
| 引擎内 GLSL→SPIR-V | ✅ 通过（去掉 `#[compute]` 之后） |
| 稳定输出纹理（RID 跨帧不变） | ✅ 自检断言 |
| 端到端出画（读回 RGBA 与 core 期望比对） | ✅ **逐像素一致，最大偏差 0/255** |

```bash
zig build test                        # 138/138（128 core + 6 ffsw ABI + 4 着色器 ABI）
zig build godot-importer-selftest     # 53/53（新增 10 项：呈现管线 6 项 + 读回比对）
```

自检用的图案是"亮度渐变 + 色度恒为中性 128"：色度常量经过任何线性滤波还是它自己，
所以 GLSL 里那步 4:2:0 双线性上采样不引入不确定量，每个像素的期望值能在 Zig 侧用
core 的色彩层精确算出来。于是这两条断言同时钉住：**中性灰在整条管线上不偏色**，
以及**逐像素亮度与 core 的数学一致**。

## 还差什么（本功能点尚未完成）

- 资源加载器：`file = "rtsp://..."` 这类 URL 的识别与文档化。
- 目前呈现只支持"两块平面"（`luma_chroma`）；平台路径若只给一块交织纹理
  （`interleaved_single`）还没有对应的着色器分支。
- 分辨率变化时还没有重建管线（现在假设尺寸固定）。
- 平台导入器在播放类里还没挂上（macOS 的 Metal 导入器需要硬解帧，见 0015 的已知限制）。
- 退出时仍有 `ObjectDB instances leaked at exit`（0022 的老账，见下）。

## 播放接线与端到端验证（已完成）

`src/godot/luna_video_stream_playback.zig` 把零件串成一条链路：

```
ffsw 后端 → DecodeScheduler → DispatchingImporter → PresentPipeline → Texture2DRD
```

每个渲染帧 `_update` 走一遍"取一帧 → 导入 → 呈现 → 重指 Texture2DRD"；音频相关的
三个虚函数如实返回"没有音频"，`_seek` 是空操作——与"视频源不是播放器"的定位一致。
`LunaVideoStream._instantiatePlayback()` 现在真的返回它。

**验证方式是"真的播一段流"**（`zig build godot-playback-smoke`）：

```
PASS  拿到了视频纹理（Texture2DRD）
PASS  纹理尺寸来自片源  320x240
PASS  呈现的帧数在增长  frames=10（跑了 11 帧）
PASS  播放位置在推进  0.36
PASS  没有报错
RESULT=PASS（退出码 0）
```

### 这一步修掉的三个真问题

1. **后端被释放两次**（退出时 SIGSEGV/ABRT，崩在 `nv_ffsw_destroy → avcodec_free_context`）。
   根因：0007 的 `unregisterStream` 会走到 `releaseStreamResources`，里面已经
   `backend.close() + backend.deinit()`，而我在 `teardown` 里又释放了一次。现在注销时
   把所有权交出去，只有"开了但没注册"才自己释放。
   中途我按**错误判断**加过"对象不释放 + magic 守卫"的临时处置；定位到真因后已撤回，
   并在注释里写清为什么会误判（崩溃栈只指到 avcodec_free_context，看不出是谁调了两次）。
2. **相对路径**：构建步骤传的是相对仓库根的路径，而 Godot 会 chdir 到工程目录，
   于是打开失败。脚本里折算成绝对路径。
3. **中文错误文本变乱码**：`String.fromLatin1` 会在把 UTF-8 字节按 Latin-1 解释，
   改用 `String.fromUtf8`。

### 一个接口事实（值得记）

Godot 4.6 **没有**暴露 `VideoStreamPlayer.get_stream_playback()`，所以诊断入口
（`get_frames_presented` / `get_last_error`）挂在 `LunaVideoStream` 上：流记住自己交出去
的播放实例，两侧 `destroy` 都会把对方那个指针清掉（双向引用必须两边都清，否则就是
悬垂指针）。同一模式在 0013 的 `ImportedSurface.release` 上也用过。

### 仍然在的账

退出时那条 `ObjectDB instances leaked at exit` 还在（0022）。本步没有碰它——它是
独立条目，且**不影响播放正确性**（播放本身已经逐项验证过）。

## 资源加载器：试过，暂时撤回（附证据）

目标是让 `load("res://clip.mp4")` 直接得到一路 `LunaVideoStream`（PLAN 5.3 说的
"能跑但不像 API" 那件事）。实现本身照源工程的 `native_video_resource_format_loader.zig`
写完了（`_getRecognizedExtensions` / `_handlesType` / `_getResourceType` / `_load`），
但在注册这一步撞墙，实测两条引擎报错：

```
ERROR: Cannot get class 'LunaVideoResourceFormatLoader'.
ERROR: Failed to retrieve non-existent singleton 'ResourceLoader'.
```

也就是说：**在扩展注册的时机（场景级）拿不到 `ResourceLoader` 单例**，而类注册也没
生效。源工程为此专门写了一个 `LoaderLifecycle`（按初始化级别挂钩、在合适的级别创建
实例并 `add_resource_format_loader`）——说明这件事对时机有要求，不是随手在 `register()`
里调一下就行。

处置：**撤回**（而不是留一个会让扩展带错误启动的版本）。现在 `file = "rtsp://..."`
与 `file = "res://..."` 两条路都仍然可用（直接赋值），只是少了"用 `load()` 拿资源"
这一种写法。

下一步要做的事：照源工程那样实现按级别的生命周期钩子，把加载器挂在
`SERVERS` 级（`ResourceLoader` 单例那时已经存在），再在自检里加一条
`ResourceLoader.exists("res://clip.mp4")` + `load()` 类型断言。
- **重连已接线**（0019）：状态机的退避窗口到期后，播放实现调调度器的
  `requestReopen`，由**持有租约的 worker**在自己的租约里执行 `close + open`——
  主线程绝不直接碰后端（会与正在解码的 worker 抢同一份 FFmpeg 上下文）。
  调度器侧有 3 项单测（登记即执行、清 eos、连续重开只保留最后一份路径副本）。

  **暴露出来、还没做的一件事**：重开之后源的 PTS 会从头开始，于是 core 的单调性
  守卫会告警（实测：`0.0000s 出现在 0.0667s 之后`），而 0001 里那个专为这件事写的
  `MediaClock.reanchor`（只向前、不跳回旧帧）**还没接进播放链路**——现在播放实现
  直接拿帧的 PTS 当播放位置，没有时钟。接上时钟 + 重连后 reanchor 是下一步。
