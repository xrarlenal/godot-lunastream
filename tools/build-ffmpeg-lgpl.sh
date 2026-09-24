#!/bin/sh
# 编一份 **LGPL** 的 FFmpeg（本项目随包用的就是它）。
#
# 为什么必须自己编：Homebrew 的 FFmpeg 是 GPL 构建（带 libx264 / libx265 / SvtAv1Enc），
# 随包分发会把整个插件拖进 GPL。PLAN 第 8.1 节把它列为**发布 blocker**。
#
# 配置要点（每条都有理由）：
#   --disable-gpl            没有它就可能链进 GPL 组件
#   --disable-nonfree
#   --enable-shared --disable-static   动态链接才满足 LGPL 的"可替换"要求
#   --disable-programs      不需要命令行工具
#   --disable-doc --disable-avdevice --disable-avfilter --disable-postproc
#                           只留 demux + decode
#   --enable-decoder=h264,hevc,mpeg4,vp9,av1,mjpeg
#                           与 ffsw 的能力白名单一致（软解兜底的范围）
#   --enable-demuxer=...    常见容器 + 网络协议（rtsp/http/udp 由 protocol 提供）
#
# 用法：tools/build-ffmpeg-lgpl.sh [安装前缀]
#
# **路径不能带空格**：FFmpeg 的构建脚本不会给自己的参数加引号，前缀里有空格时
# `-install_name` 会被拆成两半，链接阶段报
#   clang: error: no such file or directory: 'Project/godot-lunastream/dist/...'
# 而本仓库默认就在 `~/Primary Project/...` 下，所以默认前缀刻意放到家目录的私有目录里
#（实测：放在仓库里必失败，且报错信息完全不提"空格"两个字）。

set -eu

prefix="${1:-${HOME}/.local/opt/ffmpeg-lgpl}"
workdir="${FFMPEG_BUILD_DIR:-${HOME}/.local/opt/ffmpeg-lgpl-build}"
version="${FFMPEG_VERSION:-7.1}"

mkdir -p "$workdir"
cd "$workdir"

if [ ! -d "ffmpeg-$version" ]; then
	echo "下载 FFmpeg $version ..."
	curl -L -o "ffmpeg-$version.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz"
	tar xf "ffmpeg-$version.tar.xz"
fi

cd "ffmpeg-$version"

./configure \
	--prefix="$prefix" \
	--disable-gpl \
	--disable-nonfree \
	--disable-static \
	--enable-shared \
	--disable-programs \
	--disable-doc \
	--disable-avdevice \
	--disable-avfilter \
	--disable-postproc \
	--disable-encoders \
	--disable-muxers \
	--enable-decoder=h264 \
	--enable-decoder=hevc \
	--enable-decoder=mpeg4 \
	--enable-decoder=vp9 \
	--enable-decoder=av1 \
	--enable-decoder=mjpeg \
	--disable-iconv \
	--disable-sdl2

make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
make install

echo "LGPL FFmpeg 安装到：$prefix"
echo "接着：FFMPEG_PREFIX=$prefix tools/package-addon.sh"
