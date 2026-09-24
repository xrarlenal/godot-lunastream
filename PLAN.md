# LunaStream · 项目规划

> 状态：**规划稿（v0.1）**。本仓库目前还没有代码，代码源已经存在，等待迁入——
> 见第 4 节的"能力基线"。
>
> 一句话：把已经在 macOS / Windows / Linux 三平台跑通的"网络视频流 → GPU 纹理"
> 链路，从它原来的宿主工程（LunaFusion）里提炼成一个可以独立发布的 Godot 4 GDExtension。

---

## 1. 项目身份（名字信息）

| 项 | 值 |
|---|---|
| 中文名 | 露娜视频流（暂定） |
| 英文 / 项目名 | **LunaStream** |
| 仓库名 | `godot-lunastream` |
| 本地目录 | `~/Primary Project/godot-lunastream` |
| 插件安装目录 | `addons/lunastream/` |
| 类名前缀 | `Luna` |
| 入口符号 | `lunastream_init` |
| 一句话定位 | 让 Godot 的 `VideoStreamPlayer` 能直接播 `rtsp://`、`http://`，硬件解码、GPU 零拷贝、不依赖任何外部运行时 |
| 目标引擎 | Godot 4.6+（Forward+ / Mobile，即 RenderingDevice 渲染器） |
| 实现语言 | Zig 0.16.0（扩展主体）+ C（Vulkan Layer、解码 shim）+ GLSL（颜色转换 compute） |
| 许可证 | 插件本体 MIT；随包 FFmpeg 为 LGPL（动态链接、可替换） |
| 代码来源 | 骨架来自 `claytercek/godot-native-video`（MIT）；网络流与三平台硬解为本工程原创，现托管在 LunaFusion 的 `third_party/native_video/` |
| 当前状态 | 核心链路已实现并在 macOS 实机验证；Linux 编译链接通过、待真机；对外发布未就绪（见第 8 节） |

### 1.1 命名取舍

为什么要改名：现有代码里同时存在 `native_video`（扩展）、`luna_layer`（Vulkan Layer）、
`VK_LAYER_LUNA_external_memory`（Layer 名）三套来源不同的命名，其中 `native_video`
直接沿用上游仓库名，对外会造成"这是不是同一个项目"的歧义；而 "native" 一词对
使用者没有任何信息量。

| 候选 | 优点 | 缺点 |
|---|---|---|
| **LunaStream**（推荐） | 与既有品牌（LunaFusion / luna_layer）同源，命名一致 | 单看名字不知道是"视频"，靠仓库名的 `godot-` 前缀补足搜索 |
| `godot-stream-video` | 搜索命中最好 | 无品牌，与既有工程脱节 |
| `VideoBridge` | 中性、好记 | "桥"的语义暗示它做转发，与实际定位（视频源）有偏差 |
| 保留 `native_video` | 零改名成本 | 与上游同名、语义空洞，公开后更难改 |

改名的窗口只有一次：**类名是用户代码里要写的字符串**，公开后再改就是破坏性变更。
建议在 P0 阶段一次性完成，之后不再动。

### 1.2 命名落点（现状 → 目标）

| 位置 | 现状 | 目标 |
|---|---|---|
| 扩展目录 | `addons/native_video/` | `addons/lunastream/` |
| 入口符号 | `native_video_init` | `lunastream_init` |
| 资源类 | `NativeVideoStream` | `LunaVideoStream` |
| 播放类 | `NativeVideoStreamPlayback` | `LunaVideoStreamPlayback` |
| 加载器 | `NativeVideoResourceFormatLoader` | `LunaVideoResourceFormatLoader` |
| 动态库 | `libnative_video.so` / `native_video.dll` / `libnative_video.dylib` | `liblunastream.*` / `lunastream.dll` |
| Vulkan Layer 名 | `VK_LAYER_LUNA_external_memory` | `VK_LAYER_LUNA_dmabuf_external_memory` |
| Layer 文件 | `luna_layer/libluna_ext_layer.so` | `lib/dmabuf_layer/libluna_dmabuf_layer.so` |
| Layer 环境变量 | `LUNA_EXTERNAL_MEMORY_LAYER` | `LUNA_DMABUF_LAYER` |

---

## 2. 定位与边界

### 2.1 做什么

一件事：**把网络/LAN 上的视频流变成 Godot 里可采样的 GPU 纹理**，并保证
"网口 → 解码 → 纹理"这条链路上没有 CPU 读回、没有落盘、没有外部进程。

### 2.2 不做什么

| 不做 | 原因 |
|---|---|
| 音频、字幕、章节、播放速度 | 那是播放器的职责；本插件是"源"，不是"播放器" |
| seek / 逐帧步进 | 直播流没有 seek 语义；本地文件 seek 交给愿意背这块的插件 |
| Android / iOS | 另有 MediaCodec / SurfaceTexture 长链，收益比不成立 |
| 投影融合、边缘羽化、几何校正 | 属于上层应用（留在 LunaFusion） |
| 格式全兼容 | 只承诺硬解白名单 + FFmpeg 软解能覆盖的部分，不做"什么都能播" |

### 2.3 与社区现有方案的分工

| 方案 | 定位 | 差异 |
|---|---|---|
| `xiSage/godot-vlc` | 完整播放器（libVLC 内核） | 全格式、有音频字幕；但 Linux/Android 走 CPU 上传，需 glibc ≥ 2.35，无 macOS，无 arm64 Linux |
| `VersaYT/godot_mpv` | libmpv 封装 | 仅本地与 http，CPU 拷贝，无硬解策略概念 |
| **LunaStream** | 极薄的视频源 | 三平台硬解零拷贝、无外部运行时、每路可独立选解码器；功能面刻意更窄 |

---

## 3. 技术栈

### 3.1 分层

| 层 | 技术 | 说明 |
|---|---|---|
| 语言 / 绑定 | Zig 0.16.0 + `gdzig`（pinned 提交） | 编译期生成 Godot 绑定，无 C++ 运行时；构建期需一份 Godot 可执行文件用于 dump 头 |
| 解封装 | FFmpeg `libavformat` | 只做 demux；RTSP 强制 TCP 承载，可配 connect/read 超时 |
| 硬解（macOS） | VideoToolbox（自管 `VTDecompressionSession`） | 只做硬解、不用播放器模式；当前仅 H.264 |
| 硬解（Windows） | libavcodec + D3D11VA | H.264 / HEVC |
| 硬解（Linux） | libavcodec + VAAPI | H.264 / HEVC（视驱动）；导出 dma-buf |
| 软解（三平台） | FFmpeg `libavcodec`（自研 `ffsw` 后端） | 格式兜底；覆盖 h264/hevc/mpeg4/vp9/av1/mjpeg，含 10-bit |
| 呈现（macOS） | Metal + `RenderingDevice.texture_create_from_extension` | `CVPixelBuffer` 直接导入，零拷贝 |
| 呈现（Windows） | D3D12 驱动 + 共享 NT 句柄 + 共享 fence | D3D11 解码纹理 → Godot D3D12 设备，零拷贝；Vulkan 驱动下降级为一次读回 |
| 呈现（Linux） | Vulkan 外部内存 + dma-buf + **自研 Vulkan Layer** | VAAPI `vaExportSurfaceHandle(DRM_PRIME_2)` → dma-buf fd → `VkImportMemoryFdInfoKHR`；设备扩展由随包 Layer 在 `vkCreateDevice` 链上注入 |
| 颜色转换 | 共享 GLSL compute（NV12/P010 → RGBA） | 硬解/软解两条路共用同一份 shader 与 push constant |
| Godot 集成 | `VideoStream` / `VideoStreamPlayback` / `ResourceFormatLoader` | 与 `VideoStreamPlayer` 兼容；输出稳定的 `Texture2DRD` |
| 调度 | 进程共享有界 worker 池 + 帧队列 + 呈现选择器 + retire ring | 每路流串行解码，多路共享线程，不一线程一路视频 |
| 构建 | `zig build`（三平台） | macOS 用 `lipo` 出 universal；Windows 用 Zig 自带 mingw 交叉编译；Linux 出 x86_64 |
| CI | GitHub Actions（test / release-build / release-please） | 骨架已由上游带来，需扩充为三平台解码门槛 |

### 3.2 数据流

```
  rtsp:// · http(s):// · 本地路径
            │
            ▼   libavformat（仅 demux）
   ┌────────┴─────────┐
   │                  │
   ▼                  ▼
 平台硬解后端        ffsw 软解后端
 ffvt/ffd3d/ffva    libavcodec（CPU，NV12）
   │                  │
   │ GPU 原生表面      │ CPU 平面
   ▼                  ▼
 平台表面导入器     CPU 帧导入器（轮换纹理池）
   └────────┬─────────┘
            ▼
   NV12/P010 → RGBA compute（同一份 shader）
            ▼
   稳定的 Texture2DRD（每帧只重指 RID）
            ▼
   VideoStreamPlayer._get_texture()  →  Control / MeshInstance / ShaderMaterial
```

### 3.3 平台矩阵

| 平台 | 驱动 / 渲染器 | 硬解 | 零拷贝 | 备注 |
|---|---|---|---|---|
| macOS | Metal | VideoToolbox（H.264） | 是 | HEVC 走软解；universal 二进制 |
| Windows | **D3D12** | D3D11VA | 是 | 推荐路径 |
| Windows | Vulkan | D3D11VA | 否 | 每帧一次 GPU→CPU 读回；会在统计里如实上报 |
| Linux x86_64 | Vulkan | VAAPI | 是 | 依赖随包 Vulkan Layer |
| Linux arm64 | Vulkan | VAAPI | 待定 | 本规划降级为可选（原信创目标遗留） |
| 任意 | Compatibility（OpenGL） | — | — | 不支持：没有 CPU 呈现路径 |
| 任意 | `--headless` | 可解码 | 无纹理 | 无 RenderingDevice，仅解码与状态机运行 |

---

## 4. 能力基线（已实现，待迁入本仓库）

以下功能**不是规划，是已经在 LunaFusion 的 `third_party/native_video/` 中跑通的代码**。
P0 阶段的任务之一就是把它整体迁入本仓库。下表路径为迁入后的仓库内路径。

### 4.1 视频源与协议

| 功能 | 位置 |
|---|---|
| 网络流接入：`rtsp://` / `http(s)://` / `udp://` 等 FFmpeg 支持的协议 | `src/ff*/` 各 shim |
| RTSP 强制 TCP 承载 | 各 shim 的 `rtsp_transport` 选项 |
| 本地文件走同一管线（复用硬解后端） | `openBackendForPath(path)` |
| 与 `VideoStreamPlayer` drop-in 兼容 | `NativeVideoStream._instantiate_playback()` |

> 注：Godot 基类属性 `VideoStream.file` 的官方文档本身就写作
> "The video file path **or URI** that this `VideoStream` resource handles"，
> 这是本插件"不做新节点也能用"的接口依据。

### 4.2 解码后端与策略

| 功能 | 位置 |
|---|---|
| 四路解码后端：`ffvt` / `ffd3d` / `ffva` / `ffsw` | `src/ffvt`、`src/ffd3d`、`src/ffva`、`src/ffsw` |
| 每通道解码器策略 `自动 / 硬解 / 软解`，硬解档失败**不静默降级** | `src/godot/backend_selector.zig` |
| 全局硬解会话名额预算（`auto` 超额溢出到软解） | `HardwareBudget`，默认上限 4，下限 1 |
| 决策不做自动回切（避免临界点抖动） | 同上 |
| 实际生效后端如实上报（`get_decode_info()`） | `native_video_stream.zig` |
| 软解格式覆盖：h264 / hevc / mpeg4 / vp9 / av1 / mjpeg | `ffsw` |
| 10-bit：`yuv420p10le` / `P010`，统一右对齐 16-bit | 已逐字节校验 |

### 4.3 GPU 呈现与零拷贝

| 功能 | 位置 |
|---|---|
| macOS `CVPixelBuffer` → Metal 外部纹理 | `src/godot/metal_surface_importer.zig` |
| Windows D3D11 → D3D12 共享句柄 + fence，NV12 平面拆分 compute | `src/godot/d3d12_surface_importer.zig` |
| Windows Vulkan 驱动下的 CPU 读回回退（并计次上报） | `src/godot/cpu_copy_surface_importer.zig` |
| Linux VAAPI dma-buf → Vulkan 外部 image | `src/ffva/vk_import_shim.c` |
| **自研 Vulkan Layer：在 `vkCreateDevice` 链上注入 dma-buf 设备扩展** | `src/vulkan_layer/luna_ext_layer.c` |
| 按 `(dev, ino)` 缓存 dma-buf → VkImage，避免每帧重建 | `vk_import_shim.c` |
| 软解帧的 CPU 平面导入（轮换纹理池，稳态不新建纹理） | `src/godot/cpu_frame_importer.zig` |
| 平台/CPU 导入运行时分发（同一 `SurfaceImporter` 接口） | `src/godot/dispatching_surface_importer.zig` |
| 稳定的 `Texture2DRD` 输出（每帧只重指 RID） | `src/godot/present_pipeline.zig` |

> Linux 这一条是全项目最难被复制的部分：Godot 的 Vulkan 后端只在设备创建时把
> `VK_KHR_external_memory_fd` 注册为可选（源码注释明确写着 "We don't actually
> use this extension"），`VK_EXT_external_memory_dma_buf` 与
> `VK_EXT_image_drm_format_modifier` 完全没有；而这两个扩展只能在
> `vkCreateDevice` 时启用，插件从外部无法插手。因此只能随包发一个标准 Vulkan
> Layer 来补这一步。

### 4.4 调度、同步与色彩

| 功能 | 位置 |
|---|---|
| 进程共享有界 worker 池（默认 3 线程，每路流串行） | `src/core/decode_scheduler.zig` |
| 主时钟与音画同步（含无声片源的单调回退） | `src/core/clock.zig`、`playback_controller.zig` |
| 到帧早/晚的呈现策略（drop-late / hold-early） | `src/core/present_selector.zig`、`sink_latency.zig` |
| 帧生命周期回收（retire ring） | `src/core/retire_ring.zig` |
| HDR / 色域矩阵与位深归一化（共享 push constant） | `src/core/hdr_color_math.zig`、`shaders/` |
| 自适应拖动 scrubbing（快速拖动走关键帧） | `src/core/scrubber.zig` |

### 4.5 Godot 侧 API（现状）

| 成员 | 类型 | 说明 |
|---|---|---|
| `file` | 属性（基类） | 视频文件路径或 URI |
| `decoder` | 属性（枚举） | `auto` / `hardware` / `software` |
| `output_mode` | 属性（枚举） | `SDR` / `HDR` |
| `get_decode_info()` | 方法 | 实际生效的后端名、是否硬解、请求的策略 |
| `get_hardware_budget_info()` | 方法 | `limit / in_use / available` |
| `set_hardware_budget()` / `get_hardware_budget()` | 方法 | 进程级名额预算 |
| `hdr_decode_supported()` | 方法 | 当前平台是否支持 10-bit 硬解导入 |
| `get_audio_tracks()` | 方法 | 音轨元数据探测（本地文件路径） |

### 4.6 质量与工具链

| 功能 | 说明 |
|---|---|
| 单元测试 | `zig build test`，237 通过 / 1 跳过 |
| 无 Godot 的解码烟测 | `zig build decode-smoke`、`decode-smoke-sw`，可直接喂 URL |
| 软解性能基线 | H.264 960×540 单帧 0.49 ms；其余格式实测数据见 LunaFusion 工程文档 `Docs/7-软硬解混合.md` |
| 10-bit 逐字节校验 | 与 FFmpeg 原始输出完全一致 |
| 演示工程 | 随源码的 `project/`，迁入后作为本仓库的 example |
| 三平台编译 | macOS 已跑；Windows / Linux 待 CI 或对应机器 |

---

## 5. 规划中的功能（产品化）

这是"从能跑的代码变成插件"的缺口，也是本阶段的核心工作。

### 5.1 事件与状态机（最高优先级）

现状：扩展**没有任何信号**（`src/godot/` 全库 `addSignal` 命中 0 处），只有回读式
接口。结果是每个使用者都要自己写"连接中 / 正常 / 停滞 / 掉线 + 指数退避重连"的
状态机——LunaFusion 侧就是这么写的，`scripts/channels/video_channel.gd` 里为此存在
约 150 行样板代码。

| 计划项 | 说明 |
|---|---|
| 信号 `state_changed(state)` | 状态：`IDLE / OPENING / PLAYING / STALLED / FAILED` |
| 信号 `frame_ready()` | 首帧与新帧到达 |
| 信号 `stats_updated(dict)` | 低频（如 1 Hz）推送统计 |
| 属性 `reconnect` / `reconnect_max_attempts` / `reconnect_backoff_max` | 把退避重连内置 |
| 属性 `stall_timeout` | 多久无新帧判定为停滞 |
| 方法 `get_stats()` | `{backend, hardware, cpu_copy, fps, decoded, dropped, reconnects, last_error}` |

目标：使用者代码从 150 行降到 3 行。这是本插件与"一段能跑的 C ABI"的分界线。

### 5.2 纹理直给

现状：`present_pipeline.zig` 已经维护一个稳定的 `Texture2DRD`，但只能通过
`VideoStreamPlayer.get_video_texture()` 取得——3D 用户必须先往场景树里放一个
Control 节点。

计划：直接暴露 `stream.texture`，让 `ShaderMaterial.set_shader_parameter("video",
stream.texture)` 成立，无需任何 UI 节点。实现成本接近于零。

### 5.3 URL 载入 API

现状：`ResourceFormatLoader` 只按扩展名识别 `mp4 / mov / m4v`，网络 URL 必须手工
`ClassDB.instantiate("NativeVideoStream")` 再赋 `file`，属于"能跑但不像 API"。

计划：明确 `file = "rtsp://…"` 为受支持用法并写进文档，同时提供
`LunaVideoStream.from_url(url)` 之类的便捷构造；评估是否让加载器识别协议前缀。

### 5.4 平台与文档

| 计划项 | 说明 |
|---|---|
| 平台矩阵表进 README | 第 3.3 节的表直接对外，含"Windows+Vulkan 是 CPU 回退"这类坏消息 |
| `cpu_copy` 一次性警告 | 首次走读回路径时打印一次，避免用户误以为拿到零拷贝 |
| Layer 行为文档化 | 明确写出插件会设置 `VK_LAYER_PATH` / `VK_INSTANCE_LAYERS`（追加而非覆盖），以及和用户自有 Layer 共存的方式 |

### 5.5 精简（评估项）

上游的 `src/avf/`（AVFoundation）与 `src/mf/`（Media Foundation，含 `mf/win/*`）
合计约 3500 行，占 `src` 六分之一，服务的是"本地文件 + 音频 + seek"。
`ffvt/ffd3d/ffva` 已能覆盖本地路径，因此这两套对"视频源"定位属于冗余，且是
跨机器维护成本最高的部分（Windows COM/MTA 约束、AVFoundation 版本差异）。

建议：**迁入时先整体带上（保证功能不回退），冻结为 legacy，观察一个发布周期后再删**。
删除后 `core` 里的音频栈（`audio_ring` / `channel_mixer` / `canonical_mix_format` /
`audio_delivery` / `audio_telemetry`）也一并失去服务对象，可一并精简。

---

## 6. 里程碑

| 阶段 | 目标 | 内容 | 完成判据 |
|---|---|---|---|
| **P0 立项目标** | 新仓库能跑起来 | 代码迁入；LGPL 化；命名统一（第 1.2 节）；三平台 CI；README 平台矩阵；5 行 demo | 干净的机器上 `install + 5 行 GDScript` 能出画；许可检查通过 |
| **P1 产品化** | 能被别人用起来 | 信号与重连状态机进扩展；`get_stats()`；`stream.texture`；URL 用法文档化 | 官方 demo 不再需要任何自写状态机 |
| **P2 精简** | 更薄 | 冻结/删除 `avf` + `mf` 与音频栈；评估 worker 池可配 | 代码量与维护面下降，功能无回归 |
| **P3 传播** | 有人用 | 上 Godot Asset Library；发布 dma-buf + 自研 Vulkan Layer 的技术文章 | 有可复现的第三方使用记录 |

---

## 7. 交付物

| 交付物 | 说明 |
|---|---|
| `addons/lunastream/` 压缩包 | 自包含插件：动态库 + FFmpeg 运行库 + Vulkan Layer + 清单 |
| 演示工程 | 本地文件 + RTSP + 多路并排，展示 `CPU 软解 / GPU 硬解` 与统计输出 |
| README | 定位、安装、平台矩阵、已知限制、许可说明 |
| 许可清单 | 每个动态库的来源、许可证、可否替换 |
| 技术文档 | 三平台零拷贝链路原理（含 Vulkan Layer 一节） |

---

## 8. 工程约束与风险

### 8.1 发布前必须解决

| 项 | 现状 | 处置 |
|---|---|---|
| **许可** | 随包 macOS 动态库目前是 Homebrew **GPL** 构建（含 libx264 / libx265 / SvtAv1Enc） | 必须重跑 LGPL 构建脚本；CI 增加产物链接库扫描，防止回退。**这是发布 blocker，不是优化项** |
| 构建可复现 | 依赖 Zig 0.16.0 精确版本 + pinned `gdzig` | 容器化 CI + README 一条命令；不重写为 godot-cpp（2 万行代价大于收益） |
| 命名 | 三套来源混用 | P0 一次性统一 |

### 8.2 风险

| 风险 | 影响 | 对策 |
|---|---|---|
| Zig 0.16 + pre-1.0 的 `gdzig` 是硬约束，贡献者门槛高 | 社区贡献少 | 用无 Godot 的 `decode-smoke` 降低参与门槛；文档写清工具链 |
| Windows Vulkan 驱动只能 CPU 回退 | 用户误判性能 | 平台矩阵 + `cpu_copy` 上报与警告 |
| Linux 零拷贝需要随包 Layer 改环境变量 | 在他人流水线里可能表现为玄学问题 | 文档前置说明；`.so` 或清单缺失时静默降级不报错 |
| Linux 真机未验证 | 承诺兑现风险 | P0 阶段必须在真实 Linux + 支持 VAAPI 的 GPU 上跑通一次 |
| Godot 上游可能自研视频解码（已有相关提案与 PR 在动） | 长期被替代 | 保持"零拷贝 + 多平台 + 无外部运行时"的差异，不做格式全覆盖 |

---

## 9. 一句话总结

砍到只剩"网络视频 → GPU 纹理"一条线，把重连与状态机从 GDScript 搬进扩展，
用三平台无 Godot 的解码烟测把 CI 变成发布门槛。
