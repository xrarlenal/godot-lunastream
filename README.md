# LunaStream

让 Godot 的 `VideoStreamPlayer` 直接播 `rtsp://`、`http(s)://` 与本地文件：**硬件解码、
GPU 零拷贝、不依赖任何外部运行时**（不带 VLC / mpv / FFmpeg 进程）。

> 状态：**0.1.0**。macOS 已实现并验证；Windows / Linux 的零拷贝路径已移植并通过
> 交叉编译，待真机验证（见下表与 [CHANGELOG](CHANGELOG.md)）。

## 这是什么

一个极薄的视频**源**，不是播放器。它只负责把网络/LAN 上的视频流变成 Godot 里可采样的
GPU 纹理，并保证"网口 → 解码 → 纹理"这条链路上没有 CPU 读回、没有落盘、没有外部进程。

音频、字幕、章节、seek、Android / iOS 都明确不做——那些是播放器的职责，属于上层应用。

## 用法

```gdscript
var player := VideoStreamPlayer.new()
var stream := LunaVideoStream.new()
stream.file = "rtsp://192.168.1.64:8554/stream"   # 也可以是本地路径或 http(s)
player.stream = stream
add_child(player)
player.play()
```

工程内的媒体文件还可以直接当资源加载（自带资源加载器，认识 mp4 / mov / mkv / webm /
ts / avi 等容器）：

```gdscript
var stream := load("res://clip.mp4") as VideoStream
```

### 3D 用户：不必为了拿纹理塞一个 Control

```gdscript
stream.texture    # 或 stream.get_texture()
material.set_shader_parameter("video", stream.get_texture())
```

### 状态与统计

```gdscript
stream.state_changed.connect(func(state): print("状态 -> ", state))
stream.frame_ready.connect(func(): pass)
stream.stats_updated.connect(func(stats): print(stats))

stream.set_output_mode(1)          # 1 = HDR（按帧的传输函数做 PQ/HLG 色调映射）
stream.set_stall_timeout_ms(2000)  # 多久没新帧算停滞
stream.set_reconnect_max_attempts(8)
```

状态取值与 `core.playback_state.State` 一致：`0 idle / 1 opening / 2 playing /
3 stalled / 4 failed / 5 off`。

## 安装

把 `addons/lunastream/` 整个目录拷进工程的 `addons/` 下即可（自包含：扩展动态库 +
随包 FFmpeg + 清单；Linux 还带随包的 Vulkan Layer）。发布包由
`tools/release.sh` 生成，随包 FFmpeg 是 **LGPL** 构建。

## 平台支持

| 平台 | 驱动 | 硬解 | 零拷贝 | 状态 |
|---|---|---|---|---|
| macOS | Metal | VideoToolbox | 是 | **已实现并验证**（Apple M1 Pro / Godot 4.6.2） |
| Windows | D3D12 | D3D11VA | 是 | 已移植、交叉编译通过；待真机验证 |
| Windows | Vulkan | D3D11VA | 否（每帧一次读回，会如实上报） | 同上 |
| Linux x86_64 | Vulkan | VAAPI | 是（依赖随包 Layer） | 已移植、交叉编译通过；待真机验证 |
| 任意 | Compatibility（OpenGL） | — | — | 不支持（没有 CPU 呈现路径） |
| 任意 | `--headless` | 可解码 | 无纹理 | 只有解码与状态机在跑 |

## 它是怎么工作的

```
rtsp:// · http(s):// · 本地文件
          │  libavformat（只解封装；RTSP 强制 TCP，可配超时）
          ▼
     解码后端（ffsw 软解 / 平台硬解）
          │  软解给 CPU 平面；硬解给可别名的原生表面
          ▼
     导入器（运行时按帧的形状分发：CPU 上传 / Metal 零拷贝 / D3D12 / Vulkan dma-buf）
          ▼
     NV12/P010 → RGBA 的共享 compute（数学只在 core 里定义一次）
          ▼
     稳定的 Texture2DRD  →  VideoStreamPlayer / ShaderMaterial
```

设计上有两条贯穿始终的原则，都在文档里写明了理由：**能进 core 的逻辑都进 core**
（因此大部分正确性可以在任何机器上 `zig build test` 验证），**能机器验证的绝不靠肉眼**
（着色器与 ffmpeg 的输出逐字节比对、HDR 与 core 的数学逐像素比对）。

## 构建与验证

需要 **Zig 0.16.0**（精确版本）与一份 Godot 4.6；硬解路径另需 FFmpeg 的开发包。

```bash
zig build test                        # core 单测 + C ABI 守卫（不需要 Godot）
zig build ffsw-selftest               # 解码端到端自检（与 ffmpeg 逐字节比对）
zig build ffsw-backend-smoke          # 解码后端适配器烟测（不需要 Godot）
zig build decode-smoke                # 解码烟测，可直接喂 URL
zig build godot-importer-selftest     # 导入器 + 呈现管线（需要带渲染上下文的 Godot）
zig build godot-playback-smoke        # 真的播一段流（同上）
tools/check-licenses.sh               # 许可门槛（GPL 依赖即失败）
tools/release.sh                      # 打发布包（用自编的 LGPL FFmpeg）
```

## 文档

- [PLAN.md](PLAN.md) — 项目规划：定位、技术栈、里程碑、风险
- [docs/ROADMAP.md](docs/ROADMAP.md) — 功能点推进表（编号即提交序）
- [docs/features/](docs/features/) — 每个功能点一篇：做了什么、为什么、怎么验证、已知限制
- [docs/licensing.md](docs/licensing.md) — 随包组件的许可清单与门槛
- [docs/platform-port.md](docs/platform-port.md) — Windows / Linux 平台代码的来源与验证边界

## 许可证

插件本体 MIT。随包分发的 FFmpeg 为 LGPL（动态链接、可替换），不含任何 GPL 组件。
详见 [docs/licensing.md](docs/licensing.md)。
