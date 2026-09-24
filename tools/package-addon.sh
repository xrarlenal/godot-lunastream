#!/bin/sh
# 打一份自包含的插件包：dist/addons/lunastream/
#
# 里面要有：扩展动态库 + 清单 +（Linux）随包 Vulkan Layer + 依赖的 FFmpeg 运行库
# + 许可清单。PLAN 第 7 节把"自包含插件"列为交付物。
#
# 用法：tools/package-addon.sh [产物目录，默认 example/gdextension-smoke/addons/lunastream]
#
# 说明：本脚本只做"组装"。FFmpeg 那份 LGPL 构建由 tools/build-ffmpeg-lgpl.sh 产出；
# 这里默认带上 <ffmpeg-prefix>/lib 下的 FFmpeg 动态库，并**在组装后跑一次许可检查**
# ——打包这一步自己就该是门槛，而不是等人想起来再查。

set -eu

source_dir="${1:-example/gdextension-smoke/addons/lunastream}"
ffmpeg_prefix="${FFMPEG_PREFIX:-/opt/homebrew}"
out_dir="dist/addons/lunastream"

if [ ! -d "$source_dir" ]; then
	echo "找不到构建产物目录：$source_dir（先跑一次 zig build）" >&2
	exit 2
fi

rm -rf "$out_dir"
mkdir -p "$out_dir"

# 1. 扩展本体与清单（清单里的库路径是相对的，必须同目录）。
for f in "$source_dir"/*.dylib "$source_dir"/*.so "$source_dir"/*.dll "$source_dir"/*.gdextension; do
	[ -e "$f" ] || continue
	cp "$f" "$out_dir/"
done

# 2. 随包的 Vulkan Layer（Linux）——清单与 .so 必须同目录，所以整个 luna_layer/ 一起带。
if [ -d "$source_dir/luna_layer" ]; then
	mkdir -p "$out_dir/luna_layer"
	cp "$source_dir"/luna_layer/* "$out_dir/luna_layer/" 2>/dev/null || true
fi

# 3. FFmpeg 运行库。只带 FFmpeg 自己的库，不带它的第三方依赖（那些由系统提供）。
if [ -d "$ffmpeg_prefix/lib" ]; then
	for lib in "$ffmpeg_prefix"/lib/libavformat.*.dylib "$ffmpeg_prefix"/lib/libavcodec.*.dylib \
		"$ffmpeg_prefix"/lib/libavutil.*.dylib "$ffmpeg_prefix"/lib/libswscale.*.dylib \
		"$ffmpeg_prefix"/lib/libavformat.so.* "$ffmpeg_prefix"/lib/libavcodec.so.* \
		"$ffmpeg_prefix"/lib/libavutil.so.* "$ffmpeg_prefix"/lib/libswscale.so.*; do
		[ -e "$lib" ] || continue
		cp "$lib" "$out_dir/"
	done
fi

# 4. 许可清单（逐库来源与许可证）。
cat > "$out_dir/LICENSES.md" <<'EOF'
# 随包分发的第三方组件

| 组件 | 来源 | 许可证 | 可否替换 |
|---|---|---|---|
| LunaStream 扩展本体（liblunastream.*） | 本项目 | MIT | — |
| FFmpeg（libavformat / libavcodec / libavutil / libswscale） | **LGPL 构建**（由 tools/build-ffmpeg-lgpl.sh 产出） | LGPL-2.1-or-later | 可以：动态链接，替换同名库即可 |
| luna_ext_layer（Linux 随包 Vulkan Layer） | 本项目 | MIT | — |

**不含任何 GPL 组件**：本包刻意不链接 libx264 / libx265 / SvtAv1Enc 等 GPL 编码器
（它们只在编码时需要，而本插件只解码）。`tools/check-licenses.sh` 会在打包后扫描一遍，
一旦发现 GPL 依赖就让打包失败——这是 PLAN 第 8.1 节的发布 blocker，不能靠人记得查。
EOF

echo "打包完成：$out_dir"
ls -la "$out_dir"

# 5. 打完立刻验许可（打包自己就该是门槛）。
exec "$(dirname "$0")/check-licenses.sh" "$out_dir"
