#!/bin/sh
# 在本机起一条 RTSP 流给 demo 用：mediamtx（服务）+ ffmpeg（循环推流）。
#
# 为什么要这个：RTSP 是插件原生支持的协议，但公网上现成的 RTSP 测试流基本绝迹了
#（公开列表里的 IP 全连不通）。本机造一条，验证的就是插件自己的 RTSP 路径：
# TCP 承载、demux、解码、呈现，一条都不少。
#
# 需要：mediamtx（单文件，https://github.com/bluenviron/mediamtx/releases）
#      与带 libx264 的 ffmpeg（只用来**造源**，跟插件无关）。
#
# 用法：example/demo-net-stream/serve-rtsp.sh
#   MEDIAMTX_BIN      mediamtx 可执行文件路径（默认依次找 ./mediamtx 与脚本同目录）
#   DEMO_WORK_DIR     工作目录（默认 /tmp/lunastream-demo-rtsp）
#   DEMO_STREAM_PATH  流路径（默认 live → rtsp://127.0.0.1:8554/live）
#   DEMO_CLIP         推哪段视频（默认自己生成一段测试图案；给个真实片源更好看，
#                     例如：DEMO_CLIP=/tmp/sintel-trailer.mp4）

set -eu

work_dir="${DEMO_WORK_DIR:-/tmp/lunastream-demo-rtsp}"
stream_path="${DEMO_STREAM_PATH:-live}"
clip="$work_dir/clip.mp4"
url="rtsp://127.0.0.1:8554/$stream_path"

mediamtx_bin="${MEDIAMTX_BIN:-}"
if [ -z "$mediamtx_bin" ]; then
	for candidate in ./mediamtx "$(dirname "$0")/mediamtx"; do
		if [ -x "$candidate" ]; then
			mediamtx_bin="$candidate"
			break
		fi
	done
fi
if [ -z "$mediamtx_bin" ]; then
	echo "找不到 mediamtx。下载一个单文件即可：" >&2
	echo "  https://github.com/bluenviron/mediamtx/releases → darwin_arm64 tar.gz" >&2
	echo "  解出来放到仓库根目录，或用 MEDIAMTX_BIN=<路径> 指定。" >&2
	exit 2
fi

# 统一成绝对路径：下面会把工作目录切到 work_dir，相对路径会失效。
case "$mediamtx_bin" in
/*) ;;
*) mediamtx_bin="$(cd "$(dirname "$mediamtx_bin")" && pwd)/$(basename "$mediamtx_bin")" ;;
esac

mkdir -p "$work_dir"

# mediamtx 从 1.15 起**必须显式配置路径**：不配置的话，推流方会收到
# "400 Bad Request"，日志里写的是 `path 'live' is not configured`
#（实测：不带配置直接跑，就是这个错）。所以生成一份最小配置给它。
if [ ! -f "$work_dir/mediamtx.yml" ]; then
	cat > "$work_dir/mediamtx.yml" <<'YML'
# LunaStream demo 用的最小配置：放行任意路径的推流。
paths:
  all_others:
YML
fi

# 推上去的片源：默认自己生成一段测试图案（离线也能跑）。想看正常画面就喂一段
# 真实的视频文件进来：
#   curl -L -o /tmp/sintel-trailer.mp4 https://media.w3.org/2010/05/sintel/trailer.mp4
#   DEMO_CLIP=/tmp/sintel-trailer.mp4 example/demo-net-stream/serve-rtsp.sh
#
# 生成测试片时用 h264 是有意的：插件的硬解白名单认它（macOS 走 VideoToolbox），
# 换成 mpeg4 就只会走 CPU 软解。不过下面推流一律 `-c copy`，不会重编码——
# 喂什么编码就是什么编码，所以别喂 mpeg4 还说自己在验硬解。
if [ -n "${DEMO_CLIP:-}" ]; then
	if [ ! -f "$DEMO_CLIP" ]; then
		echo "DEMO_CLIP 指向的文件不存在：$DEMO_CLIP" >&2
		exit 2
	fi
	clip="$DEMO_CLIP"
elif [ ! -f "$clip" ]; then
	echo "生成测试片：$clip（想看真实画面就设 DEMO_CLIP=<视频文件>）"
	ffmpeg -y -v error -f lavfi -i "testsrc=size=960x540:rate=30:duration=6" \
		-c:v libx264 -pix_fmt yuv420p -g 60 "$clip"
fi

mtx_pid=""
push_pid=""
cleanup() {
	if [ -n "$push_pid" ]; then kill "$push_pid" 2>/dev/null || true; fi
	if [ -n "$mtx_pid" ]; then kill "$mtx_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

"$mediamtx_bin" "$work_dir/mediamtx.yml" > "$work_dir/mediamtx.log" 2>&1 &
mtx_pid=$!
sleep 2

ffmpeg -re -stream_loop -1 -v error -i "$clip" -c copy -f rtsp "$url" \
	> "$work_dir/push.log" 2>&1 &
push_pid=$!
sleep 3

echo "RTSP 流已就绪：$url"
echo "日志：$work_dir/mediamtx.log / $work_dir/push.log"
echo "按 Ctrl-C 结束（会一并停掉 mediamtx 与推流）"
wait "$push_pid"
