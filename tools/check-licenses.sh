#!/bin/sh
# 许可门槛：扫描随包分发物，确认没有任何 GPL 组件被带进来。
#
# 为什么这是一条**门槛**而不是文档提醒：PLAN 第 8.1 节把"随包 macOS 动态库是
# Homebrew 的 GPL 构建（含 libx264 / libx265 / SvtAv1Enc）"列为**发布 blocker**。
# 人手检查会在某次"先发出去再说"里失守，脚本不会。
#
# 用法：tools/check-licenses.sh [要检查的目录，默认 dist/addons/lunastream]
# 判据：任何被链接进来的 GPL 组件 → 打印出来并退出码 1。

set -eu

target_dir="${1:-dist/addons/lunastream}"

if [ ! -d "$target_dir" ]; then
	echo "找不到目录：$target_dir" >&2
	echo "先跑 tools/package-addon.sh 打一份出来，或把要检查的目录作为第一个参数传进来。" >&2
	exit 2
fi

# 已知的 GPL 组件（FFmpeg 的 GPL 构建会把这些链进来）。
gpl_markers="libx264 libx265 libxvid SvtAv1Enc libvidstab libaribb24 libcdio libdvdnav libdvdread frei0r"

failures=0
found_any=0

for lib in "$target_dir"/*.dylib "$target_dir"/*.so "$target_dir"/*.dll "$target_dir"/luna_layer/*.so "$target_dir"/luna_layer/*.dylib; do
	[ -e "$lib" ] || continue
	found_any=1
	# macOS 用 otool，Linux 用 ldd/readelf；两者都只是"把依赖列出来"。
	if command -v otool >/dev/null 2>&1; then
		deps="$(otool -L "$lib" 2>/dev/null || true)"
	else
		deps="$(ldd "$lib" 2>/dev/null || true)"
	fi
	for marker in $gpl_markers; do
		if printf '%s\n' "$deps" | grep -q "$marker"; then
			echo "GPL 组件：$lib 链接了 $marker"
			failures=$((failures + 1))
		fi
	done
done

if [ "$found_any" -eq 0 ]; then
	echo "目录里没有任何动态库：$target_dir" >&2
	exit 2
fi

if [ "$failures" -ne 0 ]; then
	echo ""
	echo "许可检查失败：发现 $failures 处 GPL 依赖。"
	echo "处置：用 tools/build-ffmpeg-lgpl.sh 重编一份 LGPL 的 FFmpeg，再重新打包。"
	exit 1
fi

echo "许可检查通过：$target_dir 里没有 GPL 组件。"
