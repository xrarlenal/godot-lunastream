#!/bin/sh
# 把插件装进这个 demo：构建 → 打包 → 拷 addons/lunastream。
#
# 为什么要打包（而不是直接拷 zig build 的产物）：随包的 FFmpeg 动态库在
# dist/addons/lunastream 里，两个必须在同一目录才能被找到（清单里的 library_path
# 是相对的）。
#
# 用法：example/demo-net-stream/setup.sh
#   GODOT_PATH        Godot 可执行文件（生成绑定用）
#   LGPL_FFMPEG_PREFIX 自编的 LGPL FFmpeg（默认 ~/.local/opt/ffmpeg-lgpl）

set -eu

godot_path="${GODOT_PATH:-/Applications/Godot.app/Contents/MacOS/Godot}"
ffmpeg_prefix="${LGPL_FFMPEG_PREFIX:-$HOME/.local/opt/ffmpeg-lgpl}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
demo_addons="$repo_root/example/demo-net-stream/addons"

cd "$repo_root"

if [ ! -d "$ffmpeg_prefix" ]; then
	echo "找不到 LGPL FFmpeg：$ffmpeg_prefix" >&2
	echo "先跑 tools/build-ffmpeg-lgpl.sh，或用 LGPL_FFMPEG_PREFIX 指定。" >&2
	exit 2
fi

echo "1/3 构建扩展"
zig build -Dgodot-path="$godot_path" -Dffmpeg-prefix="$ffmpeg_prefix"

echo "2/3 组装自包含目录"
FFMPEG_PREFIX="$ffmpeg_prefix" tools/package-addon.sh >/dev/null

echo "3/3 装进 demo"
mkdir -p "$demo_addons"
rm -rf "$demo_addons/lunastream"
cp -R dist/addons/lunastream "$demo_addons/lunastream"
ls "$demo_addons/lunastream"
