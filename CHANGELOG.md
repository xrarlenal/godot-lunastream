# 变更记录

## 0.1.0 — 首个公开版本

**LunaStream 是一个极薄的视频源**：让 Godot 4.6+ 的 `VideoStreamPlayer` 直接播
`rtsp://` / `http(s)://` / 本地文件，硬件解码、GPU 零拷贝、不依赖任何外部运行时。

### 能力

- **接入方式**：`VideoStreamPlayer.stream = 一个 LunaVideoStream`；`file` 可以是路径
  或 URI（Godot 官方对 `VideoStream.file` 的定义就是"路径或 URI"）。工程内的媒体文件
  还可以直接 `load("res://clip.mp4")`（自带资源加载器）。
- **解码**：FFmpeg 解封装 + 软解（`ffsw`）；硬解后端按平台接入（macOS 的 Metal 零拷贝
  已实现并验证；Windows 的 D3D12 与 Linux 的 Vulkan/dma-buf 已移植，见下表）。
- **呈现**：共享 compute 把 NV12 / 右对齐 16 位半平面转成 RGBA，输出到一块**稳定**的
  `Texture2DRD`（每帧只重指 RID，引用它的材质不会失效）。
- **HDR**：PQ / HLG 传输函数 + 色调映射 + BT.2020→BT.709，逐像素与 core 的数学对齐。
- **状态与统计**：`state_changed` / `frame_ready` / `stats_updated` 三个信号，
  `get_state()` / `get_stats()`；停滞判定与指数退避重连（重连动作由 worker 在自己的
  租约里执行，不与解码抢后端）；停滞阈值与重连参数可调。
- **纹理直给**：`stream.get_texture()`，3D 用户不必为了拿纹理塞一个 Control 节点。

### 平台

| 平台 | 驱动 | 硬解 | 零拷贝 | 状态 |
|---|---|---|---|---|
| macOS（Apple Silicon 实测） | Metal | VideoToolbox | 是 | **已实现并验证**（M1 Pro / Godot 4.6.2） |
| Windows | D3D12 | D3D11VA | 是 | 代码已移植、交叉编译通过；**待真机验证** |
| Windows | Vulkan | D3D11VA | 否（一次读回） | 同上（降级路径如实上报） |
| Linux x86_64 | Vulkan | VAAPI | 是（依赖随包 Vulkan Layer） | 代码已移植、交叉编译通过；**待真机验证** |

### 许可

插件本体 MIT；随包 FFmpeg 为 **LGPL** 构建（动态链接、可替换），不含任何 GPL 组件。
`tools/check-licenses.sh` 会在打包后扫描一遍，发现 GPL 依赖就让打包失败。

### 已知限制

- 只做视频：音频、字幕、seek、Android/iOS 都明确不做（定位是"源"，不是播放器）。
- 硬解后端与真实摄像头的联调以真机为准（macOS 侧 Metal 导入器已用自造
  `CVPixelBuffer` 逐字节验证）。
- 单块打包纹理（`interleaved_single`）那条分支试过、已撤回——它没有生产者，详见
  `docs/features/0018-present-pipeline.md`。
- 退出时会有一小组 RD 辅助对象留在 ObjectDB 里（不影响正确性，根因在 gdzig 边界，
  见 `docs/features/0022-gdzig-instance-leak.md`）。
