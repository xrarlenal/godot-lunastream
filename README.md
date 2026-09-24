# LunaStream

Godot 4 的网络视频源扩展：让 `VideoStreamPlayer` 能直接播 `rtsp://`、`http://`，
硬件解码、GPU 零拷贝、不依赖任何外部运行时。

> **状态：规划阶段。** 本仓库尚未迁入代码，能力基线见 [PLAN.md](PLAN.md)。
> 代码目前托管在 LunaFusion 工程的 `third_party/native_video/`，P0 阶段迁入。

## 这是什么

一个极薄的视频**源**，不是播放器。它只负责把网络/LAN 上的视频流变成 Godot 里
可采样的 GPU 纹理，并保证"网口 → 解码 → 纹理"这条链路上没有 CPU 读回、没有落盘、
没有外部进程。

```gdscript
var player := VideoStreamPlayer.new()
var stream := LunaVideoStream.new()
stream.file = "rtsp://192.168.1.64:8554/stream"
player.stream = stream
```

## 关键技术

- **解封装**：FFmpeg `libavformat`（只 demux，RTSP 走 TCP）
- **硬解**：VideoToolbox（macOS）/ D3D11VA（Windows）/ VAAPI（Linux）
- **软解**：FFmpeg `libavcodec`，作为显式可选路径与硬解并行
- **零拷贝呈现**：Metal 外部纹理 / D3D12 共享句柄 / Vulkan dma-buf 外部内存
- **Linux 关键一步**：随包一个 Vulkan Layer，在 `vkCreateDevice` 链上注入
  dma-buf 设备扩展（Godot 自身不启用这些扩展，且插件从外部无法插手）

## 平台支持

| 平台 | 驱动 | 硬解 | 零拷贝 |
|---|---|---|---|
| macOS | Metal | VideoToolbox | 是 |
| Windows | D3D12 | D3D11VA | 是 |
| Windows | Vulkan | D3D11VA | 否（CPU 读回） |
| Linux x86_64 | Vulkan | VAAPI | 是（依赖随包 Layer） |

## 文档

- [PLAN.md](PLAN.md) — 项目规划：命名、技术栈、能力基线、里程碑、风险

## 许可证

插件本体 MIT。随包分发的 FFmpeg 为 LGPL（动态链接、可替换），不含任何 GPL 组件。
