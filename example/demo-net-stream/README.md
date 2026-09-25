# LunaStream 网络流演示（2D）

一个可以直接运行的 2D 工程：把一路网络流交给 `VideoStreamPlayer` 播放，界面上显示
播放状态、帧数与播放位置。它用的插件就是本仓库的 LunaStream。

```bash
example/demo-net-stream/setup.sh   # 构建插件并装进本工程，需要 Zig 0.16.0 与 Godot 4.6
/Applications/Godot.app/Contents/MacOS/Godot --path example/demo-net-stream
```

启动后自动播放 `main.gd` 中 `DEFAULT_URLS` 的第一条地址（本机 RTSP）。顶部是地址栏与
播放、停止按钮，左下角的状态行依次显示状态、收到的帧数、实际呈现的帧数与播放位置。

三张截图都出自这个工程，片源是 Blender 基金会的 Sintel 预告片。

**本机 RTSP**（`rtsp://127.0.0.1:8554/live`，源为 854×480）：

![本机 RTSP 播放中](https://ghproxy.net/https://raw.githubusercontent.com/xrarlenal/godot-lunastream/main/example/demo-net-stream/screenshots/01-rtsp-playing.png)

**公网 https**（`https://media.w3.org/2010/05/sintel/trailer.mp4`）：

![公网 HTTPS 直接播放](https://ghproxy.net/https://raw.githubusercontent.com/xrarlenal/godot-lunastream/main/example/demo-net-stream/screenshots/02-https-public.png)

**源不可达**（地址填错或服务没起来时，状态行给出错误信息）：

![源不可达时的界面](https://ghproxy.net/https://raw.githubusercontent.com/xrarlenal/godot-lunastream/main/example/demo-net-stream/screenshots/03-failed-source.png)

公网上可用的 RTSP 公开源很少，本机起一条最省事。需要
[MediaMTX](https://github.com/bluenviron/mediamtx/releases)（单个可执行文件，选
darwin_arm64 那个包）与带 libx264 的 ffmpeg：

```bash
# 片源，任何视频文件都可以
curl -L -o /tmp/sintel-trailer.mp4 https://media.w3.org/2010/05/sintel/trailer.mp4

# 启动服务并循环推流
MEDIAMTX_BIN=~/Downloads/mediamtx DEMO_CLIP=/tmp/sintel-trailer.mp4 \
  example/demo-net-stream/serve-rtsp.sh
# → RTSP 流已就绪：rtsp://127.0.0.1:8554/live
```

不指定 `DEMO_CLIP` 时，脚本会自己生成一段测试画面，离线也能运行。

`main.gd` 的 `DEFAULT_URLS` 里另有几条公网 RTMP 地址，都是实测能打开的（H.264，插件
只取视频轨），失效后换一条填进顶栏即可：

| 地址 | 分辨率 |
|---|---|
| `rtmp://95.67.11.153/klive/stream` | 1920×1080 |
| `rtmp://212.92.13.108/live/livestream1` | 960×540 |
| `rtmp://stream1.antenaplay.ro/live/MireasaExtra` | 854×480 |

命令行参数：

| 参数 | 作用 |
|---|---|
| `--url <地址>` | 起始地址，默认取 `DEFAULT_URLS[0]` |
| `--seconds <n>` | 运行 n 秒后退出，并打印 `RESULT=PASS` 或 `RESULT=FAIL` |
| `--snapshot <路径>` | 等到有画面（30 帧；始终没有画面则 6 秒）后保存一张 PNG 并退出 |
| `--snapshot-after <n>` | 把截图推迟到第 n 秒 |
| `--decoder <档位>` | `auto`、`hardware` 或 `software`，对应插件的 `decoder` 属性 |
| `--no-autoplay` | 不自动播放，只打开界面 |

```bash
godot --path example/demo-net-stream -- --seconds 12
# [demo] frames=… state=2 (playing) … / [demo] RESULT=PASS
```

这些跑法不能加 `--headless`：呈现管线建立在 RenderingDevice 上，无头模式下拿不到可用
的渲染上下文，帧数会始终为 0，因此都会短暂弹出窗口。

## 已知限制

- 没有声音：插件只输出视频，工程把音频驱动设成了 Dummy。
- 公网慢源可能连不上：插件的单次连接预算是 5 秒，握手更慢的源会报"打开失败"，
  局域网摄像机不受影响。
