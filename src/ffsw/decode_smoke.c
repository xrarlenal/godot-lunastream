// -----------------------------------------------------------------------
// decode_smoke.c — 解码烟测工具：不需要 Godot，可直接喂 URL 或本地文件。
//
// 与 ffsw_selftest 的分工：
//
//   ffsw_selftest  断言"解出来的对不对"（结构、单调性、槽位环语义、
//                  与 ffmpeg 逐字节对照），是构建门禁；
//   decode_smoke   回答"这条源能不能解、解得快不快"——把"解码能不能跑"
//                  从"Godot 里能不能出画"里摘出来，前者可以进 CI。
//
// 判据只有一条硬的：**一帧都没解出来就是失败**（退出码非 0）。其余是观测：
// 协商色域、帧数、耗时、每帧毫秒、坏包数、PTS 区间、结束方式（流尾 / 读失败）。
// 计时不做断言——机器负载会让它抖，把抖动写进判据只会制造假红灯。
// -----------------------------------------------------------------------
#include "ffsw_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static const char *codec_class_name(nv_ffsw_codec_class k) {
	switch (k) {
	case NV_FFSW_CODEC_H264:
		return "H264";
	case NV_FFSW_CODEC_HEVC:
		return "HEVC";
	case NV_FFSW_CODEC_OTHER:
		return "OTHER";
	default:
		return "UNKNOWN";
	}
}

int main(int argc, char **argv) {
	const char *path = NULL;
	int max_frames = 0;
	int64_t timeout_us = 5000000;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
			max_frames = atoi(argv[++i]);
			if (max_frames < 0) max_frames = 0;
		} else if (strcmp(argv[i], "--timeout-us") == 0 && i + 1 < argc) {
			timeout_us = strtoll(argv[++i], NULL, 10);
		} else if (path == NULL) {
			path = argv[i];
		} else {
			fprintf(stderr, "多余的参数: %s\n", argv[i]);
			return 2;
		}
	}
	if (path == NULL) {
		fprintf(stderr, "用法: decode_smoke <视频文件或 URL> [--frames N] [--timeout-us 微秒]\n");
		fprintf(stderr, "  后端: ffsw（FFmpeg 软解）。硬解变体随 0015-0017 加入。\n");
		return 2;
	}

	nv_ffsw_backend *handle = nv_ffsw_create();
	if (handle == NULL) {
		fprintf(stderr, "创建句柄失败\n");
		return 1;
	}
	nv_ffsw_set_io_timeout_us(handle, timeout_us);

	nv_ffsw_open_info info;
	memset(&info, 0, sizeof(info));
	const double t_open_start = now_ms();
	const nv_ffsw_result opened = nv_ffsw_open(handle, path, &info);
	const double t_open_ms = now_ms() - t_open_start;
	if (opened != NV_FFSW_OK) {
		fprintf(stderr, "打开失败: %s\n", nv_ffsw_last_error(handle));
		nv_ffsw_destroy(handle);
		return 1;
	}

	// 分类从已打开的句柄上取，不再调 probe——probe 会自己开一次源，对摄像头
	// 等于多占一路连接（有些设备会拒绝第二路）。
	const nv_ffsw_codec_class klass = nv_ffsw_open_codec_class(handle);

	printf("源          : %s\n", path);
	printf("打开耗时    : %.2f ms\n", t_open_ms);
	printf("尺寸/时长   : %dx%d  %.3f s（0 = 实时源无时长）\n", info.width, info.height,
	       info.duration_seconds);
	printf("编码分类    : %s\n", codec_class_name(klass));
	printf("色域标签    : matrix=%d prim=%d trc=%d range=%d depth=%d\n", info.color.matrix,
	       info.color.primaries, info.color.transfer, info.color.range, info.color.bit_depth);

	int frames = 0;
	int bit_depth = 0;
	int width = 0;
	int height = 0;
	double first_pts = 0.0;
	double last_pts = 0.0;
	int pts_monotonic = 1;
	size_t payload_bytes = 0;
	const double t0 = now_ms();

	for (;;) {
		if (max_frames > 0 && frames >= max_frames) break;

		nv_ffsw_video_frame f;
		memset(&f, 0, sizeof(f));
		const nv_ffsw_result r = nv_ffsw_next_video_frame(handle, &f);
		if (r == NV_FFSW_NONE) break;
		if (r != NV_FFSW_OK) {
			fprintf(stderr, "取帧失败: %s\n", nv_ffsw_last_error(handle));
			nv_ffsw_destroy(handle);
			return 1;
		}
		if (frames == 0) {
			first_pts = f.pts_seconds;
			width = f.width;
			height = f.height;
			bit_depth = f.bit_depth;
		}
		if (frames > 0 && f.pts_seconds < last_pts) pts_monotonic = 0;
		last_pts = f.pts_seconds;
		// 真正会被上传的字节数（两个平面、按行距算），用来给带宽一个量级。
		payload_bytes += (size_t)f.height * (size_t)f.y_stride;
		payload_bytes += (size_t)((f.height + 1) / 2) * (size_t)f.uv_stride;
		nv_ffsw_frame_release(f.owner);
		frames++;
	}

	const double decode_ms = now_ms() - t0;
	const long long damaged = nv_ffsw_damaged_packet_count(handle);

	printf("解出帧数    : %d%s\n", frames, max_frames > 0 ? "（按 --frames 上限收工）" : "");
	if (frames > 0) {
		printf("首帧        : %dx%d bit_depth=%d\n", width, height, bit_depth);
		printf("PTS 区间    : %.3f -> %.3f s（%s）\n", first_pts, last_pts,
		       pts_monotonic ? "非递减" : "**有回退**");
		printf("净载荷      : %.1f MiB（%.1f MiB/s）\n", (double)payload_bytes / (1024.0 * 1024.0),
		       decode_ms > 0.0 ? (double)payload_bytes / (1024.0 * 1024.0) / (decode_ms / 1000.0) : 0.0);
	}
	printf("解码耗时    : %.2f ms（%.3f ms/帧）\n", decode_ms,
	       frames > 0 ? decode_ms / (double)frames : 0.0);
	printf("丢弃坏包    : %lld\n", damaged);
	printf("结束方式    : %s\n",
	       nv_ffsw_last_error(handle)[0] == '\0' ? "读到流尾（干净结束）" : nv_ffsw_last_error(handle));

	nv_ffsw_destroy(handle);

	if (frames == 0) {
		fprintf(stderr, "SMOKE=FAIL（一帧都没解出来）\n");
		return 1;
	}
	printf("SMOKE=PASS\n");
	return 0;
}
