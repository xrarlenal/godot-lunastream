# LunaStream

[简体中文](README-cn.md)

A Godot 4 GDExtension for playing **RTSP / RTMP / HTTP(S) streams and local video
files** through `VideoStreamPlayer`. If you are looking for *godot rtsp*, *godot ip
camera* or *godot play mp4* support: Godot's built-in `VideoStreamPlayer` only handles
Theora, and this extension gives it a `VideoStream` implementation for the formats you
actually use — with no external player process involved.

Copy the `addons/lunastream/` directory from a release package into your Godot project.
That directory is self-contained — the extension library, the GDExtension manifest and
the bundled FFmpeg libraries are all in it (the Linux build also ships a Vulkan layer).
Release packages are produced by `tools/release.sh`; the bundled FFmpeg is an LGPL
build and can be replaced.

```gdscript
var stream := LunaVideoStream.new()
stream.file = "rtsp://192.168.1.64:8554/stream"

var player := VideoStreamPlayer.new()
player.stream = stream
add_child(player)
player.play()
```

`file` accepts a path or a URI; both take the same code path. Media files inside the
project can also be loaded as resources (a resource loader is included, recognising
mp4 / mov / mkv / webm / ts / avi containers):

```gdscript
var stream := load("res://clip.mp4") as VideoStream
```

In 3D there is no need for a `Control` node just to get hold of a texture: every frame
is presented to a `Texture2DRD` that a material can sample directly.

```gdscript
var texture: Texture2D = stream.get_texture()
material.set_shader_parameter("video", texture)
```

Status and statistics:

```gdscript
stream.state_changed.connect(func(state: int) -> void: print("state ", state))
stream.stats_updated.connect(func(stats: Dictionary) -> void: print(stats))

stream.set_stall_timeout_ms(2000)      # how long without a new frame counts as a stall
stream.set_reconnect_max_attempts(8)   # reconnect attempts before giving up
stream.set_output_mode(1)              # 1 = HDR, per-frame PQ / HLG tone mapping
```

`state` follows `core.playback_state.State`: `0` idle, `1` opening, `2` playing,
`3` stalled, `4` failed, `5` off.

## Platform support

| Platform | Rendering driver | Decoding | Frame → texture | Status |
|---|---|---|---|---|
| macOS | Metal | FFmpeg software | CPU upload / Metal importer | Playback verified locally (M1 Pro, Godot 4.6.2) |
| Windows | D3D12 | FFmpeg software | D3D12 importer ported | Cross-compiles; not yet run on hardware |
| Linux x86_64 | Vulkan | FFmpeg software | dma-buf importer and bundled layer ported | Cross-compiles; not yet run on hardware |

Forward+ or Mobile is required, since the presentation pipeline is built on
RenderingDevice; Compatibility (OpenGL) has no presentation path. The hardware decoders
are not implemented yet, so the decoding column is FFmpeg software decoding on every
platform. What is in place is the **frame import** stage, which wraps the native surface
produced by a decoder (CoreVideo / D3D12 / dma-buf) into a Godot texture.

## Layout

```
rtsp:// · rtmp:// · http(s):// · local files
        │  libavformat demuxing (RTSP over TCP, with timeouts)
        ▼
   FFmpeg decoding to NV12 / P010
        │
        ▼
   frame import: CPU upload, or a platform surface (Metal / D3D12 / Vulkan dma-buf)
        │
        ▼
   NV12 / P010 → RGBA compute shader (shared by both import paths)
        │
        ▼
   Texture2DRD  →  VideoStreamPlayer / ShaderMaterial
```

Everything that does not depend on the engine or on a GPU — the playback clock, the
frame queue, the state machine, reconnect scheduling and the colour maths — lives in
`src/core/` and can be tested on any machine. Platform code lives in `src/ffsw/` (FFmpeg
decoding), `src/ffvt/` (macOS CoreVideo / Metal), `src/ffva/` (Linux Vulkan dma-buf),
`src/win/` (Windows D3D12) and `src/vulkan_layer/`.

## Building

Zig 0.16.0 and Godot 4.6 are required.

```bash
zig build test                     # core unit tests, no Godot or GPU
zig build ffsw-selftest            # end-to-end decode self-test, byte-compared with ffmpeg
zig build decode-smoke             # decode smoke test, takes a URL
zig build godot-importer-selftest  # importer and presentation pipeline, needs Godot with a rendering context
zig build godot-playback-smoke     # playback smoke test, same requirement
tools/check-licenses.sh            # license gate, fails on any GPL dependency
tools/release.sh                   # build a release package
```

## Example

`example/demo-net-stream/` is a 2D project that pulls a network stream and hands it to
`VideoStreamPlayer`, showing the playback state and statistics on screen.

![RTSP playback](https://ghproxy.net/https://raw.githubusercontent.com/xrarlenal/godot-lunastream/main/example/demo-net-stream/screenshots/01-rtsp-playing.png)

![HTTPS playback](https://ghproxy.net/https://raw.githubusercontent.com/xrarlenal/godot-lunastream/main/example/demo-net-stream/screenshots/02-https-public.png)

```bash
example/demo-net-stream/setup.sh                                   # build the addon into the project
example/demo-net-stream/serve-rtsp.sh                              # serve an RTSP stream on this machine
/Applications/Godot.app/Contents/MacOS/Godot --path example/demo-net-stream
```

Command-line options and the remaining screenshot are in
[example/demo-net-stream/README.md](example/demo-net-stream/README.md).

## Documentation

- [PLAN.md](PLAN.md) — project plan: scope, toolchain, milestones, risks (Chinese)
- [docs/ROADMAP.md](docs/ROADMAP.md) — feature list, numbered in commit order (Chinese)
- [docs/features/](docs/features/) — one document per feature: what it does, why, how it was verified, known limits (Chinese)
- [docs/licensing.md](docs/licensing.md) — licenses of the bundled components and the gate (Chinese)
- [docs/platform-port.md](docs/platform-port.md) — origin and verification status of the Windows / Linux code (Chinese)

## License

The plugin itself is MIT. The bundled FFmpeg is an LGPL build (dynamically linked and
replaceable) and contains no GPL components; see [docs/licensing.md](docs/licensing.md).
