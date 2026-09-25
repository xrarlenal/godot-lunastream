# LunaStream

[English](README.md)

Godot 4 的 GDExtension：让 `VideoStreamPlayer` 能播 **RTSP / RTMP / HTTP(S) 流与本地视频
文件**。如果你在找 *Godot 播 RTSP*、*Godot 显示 IP 摄像头*、*Godot 播 MP4* 的方案——
Godot 自带的 `VideoStreamPlayer` 只认 Theora，这个扩展补上了真正会用到的那几种格式，
工程里不需要外挂播放器进程。

把发布包里的 `addons/lunastream/` 整个目录复制进你的 Godot 工程即可。这个目录是
自包含的——扩展动态库、GDExtension 清单与随包的 FFmpeg 动态库都在里面，Linux 版本
还带一个 Vulkan Layer。发布包由 `tools/release.sh` 生成，随包的 FFmpeg 是 LGPL
构建，可以自行替换。

```gdscript
var stream := LunaVideoStream.new()
stream.file = "rtsp://192.168.1.64:8554/stream"

var player := VideoStreamPlayer.new()
player.stream = stream
add_child(player)
player.play()
```

`file` 接受路径或 URI，两者走同一条链路。工程目录内的媒体文件也可以直接按资源加载
（自带资源加载器，识别 mp4 / mov / mkv / webm / ts / avi 等容器）：

```gdscript
var stream := load("res://clip.mp4") as VideoStream
```

3D 场景里不必为了取纹理而放一个 `Control` 节点，每帧都呈现在一张 `Texture2DRD` 上，
直接当材质贴图采样即可：

```gdscript
var texture: Texture2D = stream.get_texture()
material.set_shader_parameter("video", texture)
```

状态与统计：

```gdscript
stream.state_changed.connect(func(state: int) -> void: print("状态 ", state))
stream.stats_updated.connect(func(stats: Dictionary) -> void: print(stats))

stream.set_stall_timeout_ms(2000)      # 多久收不到新帧算停滞
stream.set_reconnect_max_attempts(8)   # 重连尝试次数上限
stream.set_output_mode(1)              # 1 = HDR，按帧的传输函数做 PQ / HLG 色调映射
```

`state` 的取值与 `core.playback_state.State` 一致：`0` idle、`1` opening、`2` playing、
`3` stalled、`4` failed、`5` off。

## 平台

| 平台 | 渲染驱动 | 解码 | 帧 → 纹理 | 状态 |
|---|---|---|---|---|
| macOS | Metal | FFmpeg 软解 | CPU 上传 / Metal 导入器 | 播放链路已在本机验证（Godot 4.6.2） |
| Windows | D3D12 | FFmpeg 软解 | D3D12 导入器已移植 | 交叉编译通过，待真机验证 |
| Linux x86_64 | Vulkan | FFmpeg 软解 | dma-buf 导入器与随包 Layer 已移植 | 交叉编译通过，待真机验证 |

渲染器要求 Forward+ 或 Mobile，呈现管线建立在 RenderingDevice 上；Compatibility
（OpenGL）没有对应的呈现路径。各平台的硬解后端尚未实现，上表的解码一列都是 FFmpeg
软解，已经就位的是帧导入部分——把解码器给出的原生表面（CoreVideo / D3D12 / dma-buf）
包装成 Godot 纹理。

## 组成

```
rtsp:// · rtmp:// · http(s):// · 本地文件
        │  libavformat 解封装（RTSP 走 TCP，可配超时）
        ▼
   FFmpeg 解码，输出 NV12 / P010
        │
        ▼
   帧导入：CPU 上传，或平台原生表面（Metal / D3D12 / Vulkan dma-buf）
        │
        ▼
   NV12 / P010 → RGBA 的 compute shader（两条导入路径共用）
        │
        ▼
   Texture2DRD  →  VideoStreamPlayer / ShaderMaterial
```

与引擎、GPU 无关的逻辑（播放时钟、帧队列、状态机、重连调度、色彩数学）在
`src/core/`；平台相关的部分在 `src/ffsw/`（FFmpeg 解码）、`src/ffvt/`（macOS 的
CoreVideo / Metal）、`src/ffva/`（Linux 的 Vulkan dma-buf）、`src/win/`（Windows 的
D3D12）以及 `src/vulkan_layer/`。

## 构建

需要 Zig 0.16.0 与 Godot 4.6。

```bash
zig build test                     # core 单测，不需要 Godot 与 GPU
zig build ffsw-selftest            # 解码端到端自检，与 ffmpeg 的输出逐字节比对
zig build decode-smoke             # 解码烟测，可以直接喂 URL
zig build godot-importer-selftest  # 导入器与呈现管线，需要带渲染上下文的 Godot
zig build godot-playback-smoke     # 播放烟测，同上
tools/check-licenses.sh            # 许可门槛，发现 GPL 依赖即失败
tools/release.sh                   # 生成发布包
```

## 示例

`example/demo-net-stream/` 是一个可以直接运行的 2D 工程，把网络流拉下来交给
`VideoStreamPlayer` 播放，界面上显示状态与统计。

![本机 RTSP 拉流播放](https://ghproxy.net/https://raw.githubusercontent.com/xrarlenal/godot-lunastream/main/example/demo-net-stream/screenshots/01-rtsp-playing.png)

![公网 https 直接播放](https://ghproxy.net/https://raw.githubusercontent.com/xrarlenal/godot-lunastream/main/example/demo-net-stream/screenshots/02-https-public.png)

```bash
example/demo-net-stream/setup.sh                                   # 把插件装进这个工程
example/demo-net-stream/serve-rtsp.sh                              # 在本机起一路 RTSP 流
/Applications/Godot.app/Contents/MacOS/Godot --path example/demo-net-stream
```

命令行参数与其余截图见 [example/demo-net-stream/README.md](example/demo-net-stream/README.md)。

## 文档

- [PLAN.md](PLAN.md) — 项目规划：定位、技术栈、里程碑与风险
- [docs/ROADMAP.md](docs/ROADMAP.md) — 功能点推进表，编号即提交顺序
- [docs/features/](docs/features/) — 每个功能点一篇：做了什么、为什么、怎么验证、已知限制
- [docs/licensing.md](docs/licensing.md) — 随包组件的许可清单与门槛
- [docs/platform-port.md](docs/platform-port.md) — Windows / Linux 平台代码的来源与验证边界

## 许可证

插件本体为 MIT。随包分发的 FFmpeg 是 LGPL 构建（动态链接，可替换），其中不含任何
GPL 组件；清单与检查方式见 [docs/licensing.md](docs/licensing.md)。
