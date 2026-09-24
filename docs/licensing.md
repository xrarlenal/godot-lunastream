# 许可：随包分发物里有什么，以及为什么不能是 GPL

> 结论先说：**现在这份包是干净的**——`tools/check-licenses.sh` 在 `dist/addons/lunastream`
> 上通过（0 处 GPL 依赖）。在这之前它是失败状态，而且失败得有理由（见下）。

## 随包的东西

| 组件 | 来源 | 许可证 | 可否替换 |
|---|---|---|---|
| LunaStream 扩展本体（`liblunastream.*` / `lunastream.dll`） | 本项目 | MIT | — |
| FFmpeg：`libavformat` / `libavcodec` / `libavutil` / `libswscale` | **LGPL 构建**，由 `tools/build-ffmpeg-lgpl.sh` 产出 | LGPL-2.1-or-later | 可以：动态链接，替换同名库即可 |
| `luna_ext_layer`（Linux 随包 Vulkan Layer） | 本项目 | MIT | — |

## 为什么"必须是 LGPL 构建"是硬约束

PLAN 第 8.1 节把它列为**发布 blocker**，理由是具体的：Homebrew 的 FFmpeg 是 **GPL**
构建（链了 libx264 / libx265 / SvtAv1Enc）。随包分发它，等于把整个插件拖进 GPL——
而本插件的定位是 MIT 的工具，用户不会接受这个意外。

**实测证据**（`tools/package-addon.sh` 拿 Homebrew 的库打一份，再跑许可检查）：

```
GPL 组件：dist/addons/lunastream/libavcodec.63.dylib 链接了 libx264
GPL 组件：dist/addons/lunastream/libavcodec.63.dylib 链接了 libx265
GPL 组件：dist/addons/lunastream/libavcodec.63.dylib 链接了 SvtAv1Enc
... （共 12 处）
许可检查失败：发现 12 处 GPL 依赖。
```

## 工具链（三步，都在 `tools/`）

```bash
# 1) 编一份 LGPL 的 FFmpeg（约 1.5 分钟，本机实测 82 秒）
tools/build-ffmpeg-lgpl.sh                      # 默认装到 ~/.local/opt/ffmpeg-lgpl

# 2) 用它对扩展重新构建，再打包（脚本内部会跑一次许可检查）
zig build -Dgodot-path=<Godot> -Dffmpeg-prefix=~/.local/opt/ffmpeg-lgpl
FFMPEG_PREFIX=~/.local/opt/ffmpeg-lgpl tools/package-addon.sh

# 3) 打包完成后（脚本已自动跑）——也可以单独跑
tools/check-licenses.sh dist/addons/lunastream
```

**打包这一步自己就是门槛**：`package-addon.sh` 末尾 `exec` 到许可检查，发现 GPL 依赖
就整体失败。人手检查会在某次"先发出去再说"里失守，脚本不会。

### LGPL 构建的配置要点

`--disable-gpl --disable-nonfree` 是底线；`--enable-shared --disable-static` 是 LGPL
"用户可替换该库"这条要求的实现方式；其余（`--disable-programs/avdevice/avfilter/
postproc/encoders/muxers`）只留 demux + decode，把体积和攻击面砍到与插件职责一致。
解码器白名单与 `ffsw` 的能力范围对齐（h264 / hevc / mpeg4 / vp9 / av1 / mjpeg）。

### 一条必须记下来的坑：路径里不能有空格

FFmpeg 的构建脚本不给自己的参数加引号。前缀带空格时链接阶段报的是
`clang: error: no such file or directory: 'Project/godot-lunastream/dist/...'`——
**完全不提"空格"两个字**，看着像文件缺失。而本仓库默认就在 `~/Primary Project/...`
下，所以脚本的默认前缀刻意放到 `~/.local/opt/ffmpeg-lgpl`（无空格）。
（实测：前缀放在仓库里必失败。）

## 验证状态

| 项 | 结果 |
|---|---|
| LGPL FFmpeg 构建 | ✅ 本机编成并安装（`~/.local/opt/ffmpeg-lgpl`） |
| 用它重建扩展 | ✅ `zig build -Dffmpeg-prefix=<lgpl>` 通过 |
| 功能没退化 | ✅ `zig build godot-playback-smoke` RESULT=PASS（真播一段流） |
| 打包产物许可检查 | ✅ 通过（0 处 GPL 依赖；换 Homebrew 那份则 12 处，门槛会拦） |
| Windows / Linux 的随包 | ⏳ 同一套脚本可复用（Windows 用 mingw 交叉编译，Linux 用系统 FFmpeg 或同法自编） |
