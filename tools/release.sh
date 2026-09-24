#!/bin/sh
# 打一个发布包：dist/lunastream-<版本>.zip
#
# 做的事（每一步都有理由）：
#   1. 用**自编的 LGPL FFmpeg** 重新构建扩展——随包分发不能带 GPL 构建（PLAN 8.1）；
#   2. 组装自包含目录（扩展 + 清单 + 随包 Layer + FFmpeg 运行库 + 许可清单）；
#   3. 跑许可门槛（package-addon.sh 内部会做，这里显式再跑一次，好让失败点清楚）；
#   4. 打 zip。
#
# 用法：tools/release.sh [版本号]
#
# 需要：Zig 0.16.0 在 PATH 上；GODOT_PATH 指向 Godot 可执行文件；
#      LGPL FFmpeg 在 $LGPL_FFMPEG_PREFIX（默认 ~/.local/opt/ffmpeg-lgpl，
#      没有就先跑 tools/build-ffmpeg-lgpl.sh）。

set -eu

version="${1:-0.1.0}"
godot_path="${GODOT_PATH:-/Applications/Godot.app/Contents/MacOS/Godot}"
ffmpeg_prefix="${LGPL_FFMPEG_PREFIX:-$HOME/.local/opt/ffmpeg-lgpl}"
dist_dir="dist/lunastream-$version"

if [ ! -d "$ffmpeg_prefix" ]; then
	echo "找不到 LGPL FFmpeg：$ffmpeg_prefix" >&2
	echo "先跑 tools/build-ffmpeg-lgpl.sh，或用 LGPL_FFMPEG_PREFIX 指定。" >&2
	exit 2
fi

echo "1/4 用 LGPL FFmpeg 构建扩展（${ffmpeg_prefix}）"
zig build -Dgodot-path="$godot_path" -Dffmpeg-prefix="$ffmpeg_prefix" --summary all

echo "2/4 组装自包含目录"
FFMPEG_PREFIX="$ffmpeg_prefix" tools/package-addon.sh >/dev/null

echo "3/4 许可门槛"
tools/check-licenses.sh dist/addons/lunastream

echo "4/4 打 zip"
rm -rf "$dist_dir"
mkdir -p "$dist_dir"
cp -R dist/addons/lunastream "$dist_dir/lunastream"
cp README.md CHANGELOG.md "$dist_dir/"
cp docs/licensing.md "$dist_dir/LICENSING.md"
# 先删掉旧的 zip：`zip` 是**增量更新**语义，不删的话上一次的条目会留在包里
#（实测：交叉编译留下的 .dll/.so 就是这么混进 macOS 发布包的）。
rm -f "dist/lunastream-$version.zip"
( cd dist && zip -qr "lunastream-$version.zip" "lunastream-$version" )

echo ""
echo "发布包：dist/lunastream-${version}.zip"
ls -la "dist/lunastream-$version.zip"
