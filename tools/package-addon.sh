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

# 只带**本平台**的产物。示例工程的 addons/ 里可能同时躺着交叉编译出来的
# lunastream.dll / liblunastream.so（那是别的平台、且没在真机上验证过），
# 把它们打进 macOS 的发布包只会误导使用者。
case "$(uname -s)" in
Darwin)
	host_kind="macOS"
	lib_glob="*.dylib"
	;;
Linux)
	host_kind="Linux"
	lib_glob="*.so"
	;;
*)
	host_kind="Windows"
	lib_glob="*.dll"
	;;
esac
echo "平台：${host_kind}（只带 ${lib_glob}）"

if [ ! -d "$source_dir" ]; then
	echo "找不到构建产物目录：$source_dir（先跑一次 zig build）" >&2
	exit 2
fi

rm -rf "$out_dir"
mkdir -p "$out_dir"

# 1. 扩展本体与清单（清单里的库路径是相对的，必须同目录）。
for f in "$source_dir"/$lib_glob "$source_dir"/*.gdextension; do
	[ -e "$f" ] || continue
	cp "$f" "$out_dir/"
done

# 2. 随包的 Vulkan Layer（**只对 Linux 有意义**）——清单与 .so 必须同目录，
#    所以整个 luna_layer/ 一起带；别的平台带了只是噪音（且会让人以为要用它）。
if [ "$host_kind" = "Linux" ] && [ -d "$source_dir/luna_layer" ]; then
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

# 3b. 依赖闭包：把上面这几个库**自己还需要**的 FFmpeg 库也补进来。
# 实测踩过：libavformat 依赖 libswresample，而上面那份清单里没有它——包在开发机上能跑
#（前缀里有），换台机器就是 "Library not loaded"。所以扫一遍依赖，缺什么补什么。
list_deps() {
	if command -v otool >/dev/null 2>&1; then
		otool -L "$1" 2>/dev/null
	else
		ldd "$1" 2>/dev/null
	fi
}

for _pass in 1 2 3; do
	_added=0
	for _lib in "$out_dir"/*.dylib "$out_dir"/*.so "$out_dir"/luna_layer/*.so; do
		[ -e "$_lib" ] || continue
		for _dep in $(list_deps "$_lib" | awk '{print $1}' | grep -E 'lib(av|sw)'); do
			_name="$(basename "$_dep")"
			[ -e "$out_dir/$_name" ] && continue
			for _cand in "$ffmpeg_prefix/lib/$_name" "$ffmpeg_prefix"/lib/*-linux-gnu/"$_name"; do
				if [ -e "$_cand" ]; then
					cp "$_cand" "$out_dir/"
					echo "补依赖：${_name}（${_lib} 需要）"
					_added=1
					break
				fi
			done
		done
	done
	[ "$_added" -eq 0 ] && break
done

# 3c. 自包含性检查：产物里不允许出现指向本机路径的依赖。
# macOS 的共享库把路径记死在 Mach-O 里，这正是"开发机跑得通、别人加载不了"的来源。
if command -v otool >/dev/null 2>&1; then
	_absolute="$(for _lib in "$out_dir"/*.dylib; do
		[ -e "$_lib" ] || continue
		otool -L "$_lib" | awk 'NR>1 {print $1}'
	done | grep -E '^/' | grep -vE '^/(usr/lib|System)/' || true)"
elif command -v ldd >/dev/null 2>&1; then
	_absolute=""
else
	_absolute=""
fi
if [ -n "$_absolute" ]; then
	echo "" >&2
	echo "打包中止：产物里还有指向本机路径的依赖，换台机器会加载失败：" >&2
	printf '  %s\n' $_absolute >&2
	echo "macOS 上多半是 FFmpeg 的 install name 没指到 @loader_path（见 tools/build-ffmpeg-lgpl.sh）。" >&2
	exit 1
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
