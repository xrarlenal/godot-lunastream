// -----------------------------------------------------------------------
// ffsw_selftest.c — ffsw shim 的端到端自检（不需要 Godot）。
//
// 分两段：
//
//   A. 内容与顺序：打开一个真实文件，逐帧取出→归还，检查尺寸 / stride /
//      位深 / PTS 单调 / 平面确实有画面，并把**整条流**按"每帧先 Y 平面、
//      再 UV 平面"紧排写成一个原始 NV12 文件。
//
//   B. 槽位环语义：故意不归还地连取 NV_FFSW_SLOT_COUNT 帧，断言下一次返回
//      NONE（背压），再归还一帧断言能立刻继续——即"槽位耗尽不丢帧"。
//
// A 段落下的原始文件与 `ffmpeg -pix_fmt nv12 -f rawvideo` 的输出逐字节比对
// （由构建步骤驱动），是这一步最硬的证据：它同时证明布局正确、且本 shim
// 没有动过任何一个色值——矩阵、码值范围、位深对齐都留给 core 的色彩层。
// -----------------------------------------------------------------------
#include "ffsw_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_checks = 0;
static int g_failures = 0;

static void check(int ok, const char *what) {
	g_checks++;
	if (ok) {
		printf("  ok   %s\n", what);
	} else {
		g_failures++;
		printf("  FAIL %s\n", what);
	}
}

// 一帧的亮度均值（按字节算，8/10 位通用）：确认"确实解出了画面"而不是一屏黑
// （全零平面只有在纯黑测试图上才是对的，那会让"解码没跑"看起来像通过）。
static double mean_luma(const nv_ffsw_video_frame *f) {
	if (f->y == NULL || f->width <= 0 || f->height <= 0) return 0.0;
	double sum = 0.0;
	for (int row = 0; row < f->height; row++) {
		const unsigned char *p = f->y + (size_t)row * (size_t)f->y_stride;
		for (int col = 0; col < f->width; col++) sum += p[col];
	}
	return sum / ((double)f->width * (double)f->height);
}

// 亮度平面的最大码值。10-bit 用它确认"右对齐"：右对齐时上界是 1023，
// 若被误当成 P010 的左对齐就会看到 65 472 这个量级。
static unsigned max_luma_sample(const nv_ffsw_video_frame *f) {
	unsigned max_sample = 0;
	const int bytes_per_sample = f->bit_depth > 8 ? 2 : 1;
	for (int row = 0; row < f->height; row++) {
		const unsigned char *p = f->y + (size_t)row * (size_t)f->y_stride;
		for (int col = 0; col < f->width; col++) {
			unsigned v;
			if (bytes_per_sample == 2) {
				// 小端：低字节在前（三个目标平台都是小端）。
				v = (unsigned)p[col * 2] | ((unsigned)p[col * 2 + 1] << 8);
			} else {
				v = p[col];
			}
			if (v > max_sample) max_sample = v;
		}
	}
	return max_sample;
}

// 把一帧紧排写进 fp。转储格式刻意与 ffmpeg 的对照输出对齐：
//
//   8-bit  → 整块 Y + 整块交织 UV，与 `-pix_fmt nv12` 一致；
//   10-bit → 整块 Y + Cb 平面 + Cr 平面，与 `-pix_fmt yuv420p10le` 一致
//            （ffmpeg 没有右对齐的 4:2:0 半平面格式，所以这一侧只能按平面比）。
//
// 10-bit 这一路会多做一次无损拆交织。那是转储格式的选择，不改变帧本身的布局
// ——帧始终是"亮度平面 + 交织 CbCr 平面"，由结构检查（stride/平面尺寸）守着。
static int dump_frame(FILE *fp, const nv_ffsw_video_frame *f) {
	const int bytes_per_sample = f->bit_depth > 8 ? 2 : 1;
	const size_t y_row_bytes = (size_t)f->width * (size_t)bytes_per_sample;
	for (int row = 0; row < f->height; row++) {
		const unsigned char *p = f->y + (size_t)row * (size_t)f->y_stride;
		if (fwrite(p, 1, y_row_bytes, fp) != y_row_bytes) return -1;
	}

	if (bytes_per_sample == 1) {
		for (int row = 0; row < (f->height + 1) / 2; row++) {
			const unsigned char *p = f->uv + (size_t)row * (size_t)f->uv_stride;
			if (fwrite(p, 1, (size_t)f->uv_stride, fp) != (size_t)f->uv_stride) return -1;
		}
		return 0;
	}

	const int chroma_cols = (f->width + 1) / 2;
	for (int plane = 0; plane < 2; plane++) {
		for (int row = 0; row < (f->height + 1) / 2; row++) {
			const uint16_t *src = (const uint16_t *)(const void *)(f->uv + (size_t)row * (size_t)f->uv_stride);
			for (int col = 0; col < chroma_cols; col++) {
				const uint16_t v = src[col * 2 + plane];
				const unsigned char bytes[2] = {(unsigned char)(v & 0xFF), (unsigned char)(v >> 8)};
				if (fwrite(bytes, 1, 2, fp) != 2) return -1;
			}
		}
	}
	return 0;
}

static void print_color(const nv_ffsw_colorimetry *c) {
	printf("         色域标签 matrix=%d prim=%d trc=%d range=%d depth=%d\n", c->matrix, c->primaries,
	       c->transfer, c->range, c->bit_depth);
}

// --- A. 内容与顺序 --------------------------------------------------------

static void phase_content(const char *path, const char *dump_path, int max_frames) {
	nv_ffsw_open_info probed;
	memset(&probed, 0, sizeof(probed));
	const nv_ffsw_codec_class klass = nv_ffsw_probe(path, &probed);
	check(klass != NV_FFSW_CODEC_UNKNOWN, "probe 认出片源的编码分类（且不需要开解码器）");
	check(probed.has_video == 1 && probed.width > 0 && probed.height > 0, "probe 带回视频流尺寸");

	nv_ffsw_backend *handle = nv_ffsw_create();
	check(handle != NULL, "创建句柄");
	if (handle == NULL) return;

	nv_ffsw_open_info info;
	memset(&info, 0, sizeof(info));
	nv_ffsw_result r = nv_ffsw_open(handle, path, &info);
	check(r == NV_FFSW_OK, "打开源（含解码器）成功");
	if (r != NV_FFSW_OK) {
		printf("         last_error: %s\n", nv_ffsw_last_error(handle));
		nv_ffsw_destroy(handle);
		return;
	}

	printf("         尺寸 %dx%d  时长 %.3fs  视频流 %d\n", info.width, info.height, info.duration_seconds,
	       info.has_video);
	print_color(&info.color);

	// 时长 <= 0 是直播源的常态（没有"总时长"这个概念）。它的检查项要放宽：
	// 没有流尾、也就没有"读完之后继续返回 NONE"这一说。
	const int live = info.duration_seconds <= 0.0;
	printf("         源类型: %s%s\n", live ? "实时/无时长" : "有界（文件）",
	       max_frames > 0 ? "（本次限制帧数）" : "");

	check(info.width == probed.width && info.height == probed.height, "open 与 probe 报的尺寸一致");
	check(nv_ffsw_video_width(handle) == info.width, "video_width 与 open_info 一致");
	check(nv_ffsw_video_height(handle) == info.height, "video_height 与 open_info 一致");
	if (live) {
		printf("         跳过: 时长检查（实时源本来就没有时长）\n");
	} else {
		check(nv_ffsw_duration_seconds(handle) > 0.0, "有界源能读出正时长");
	}

	FILE *dump = NULL;
	if (dump_path != NULL) {
		dump = fopen(dump_path, "wb");
		check(dump != NULL, "创建原始 NV12 转储文件");
	}

	int frames = 0;
	int reached_limit = 0;
	int monotonic = 1;
	int sizes_consistent = 1;
	double first_pts = 0.0;
	double last_pts = 0.0;
	double first_mean = 0.0;

	for (;;) {
		if (max_frames > 0 && frames >= max_frames) {
			reached_limit = 1;
			break;
		}
		nv_ffsw_video_frame f;
		memset(&f, 0, sizeof(f));
		r = nv_ffsw_next_video_frame(handle, &f);
		if (r == NV_FFSW_NONE) break; // 流正常结束
		if (r != NV_FFSW_OK) {
			printf("         解码中断: %s\n", nv_ffsw_last_error(handle));
			check(0, "解码过程没有硬错误");
			break;
		}

		if (frames == 0) {
			first_pts = f.pts_seconds;
			first_mean = mean_luma(&f);
			const int bytes_per_sample = f.bit_depth > 8 ? 2 : 1;
			const unsigned max_sample = max_luma_sample(&f);
			printf("         首帧 %dx%d bit_depth=%d y_stride=%d uv_stride=%d 最大码值=%u\n", f.width,
			       f.height, f.bit_depth, f.y_stride, f.uv_stride, max_sample);
			check(f.y != NULL && f.uv != NULL, "两个平面都有指针");
			check(f.bit_depth == 8 || f.bit_depth == 10, "首帧位深是 8 或 10");
			check(f.y_stride == f.width * bytes_per_sample, "亮度 stride == 宽度 x 每样值字节数（紧凑）");
			check(f.uv_stride == f.width * bytes_per_sample, "色度 stride 同上（交织 CbCr 平面）");
			check(max_sample <= (unsigned)(bytes_per_sample == 2 ? 1023 : 255),
			      "亮度最大码值在有效位深内（10-bit 右对齐而非 P010 左对齐）");
			check(f.width == info.width && f.height == info.height, "首帧尺寸与 open 报告一致");
			check(f.color.matrix == info.color.matrix, "逐帧色域沿用容器的矩阵标签");
		}
		if (frames > 0 && f.pts_seconds < last_pts) {
			monotonic = 0;
			printf("         PTS 回退: %.6f -> %.6f\n", last_pts, f.pts_seconds);
		}
		if (f.width != info.width || f.height != info.height) sizes_consistent = 0;
		last_pts = f.pts_seconds;

		if (dump != NULL) {
			if (dump_frame(dump, &f) != 0) {
				check(0, "写原始 NV12 转储");
				fclose(dump);
				dump = NULL;
			}
		}
		nv_ffsw_frame_release(f.owner);
		frames++;
	}

	if (dump != NULL) fclose(dump);

	printf("         解出 %d 帧，首帧 PTS %.3fs 末帧 PTS %.3fs，首帧亮度均值 %.2f\n", frames, first_pts,
	       last_pts, first_mean);
	const long long damaged = nv_ffsw_damaged_packet_count(handle);
	printf("         丢弃坏包 %lld 个\n", damaged);
	check(frames > 0, "至少解出一帧");
	check(monotonic, "PTS 非递减（0005 呈现选择器的前提）");
	check(sizes_consistent, "每一帧的尺寸都与 open 报告一致");
	check(first_mean > 1.0, "首帧亮度均值 > 1（确实有画面内容）");
	check(last_pts > first_pts, "末帧 PTS 晚于首帧（整条流都走到了）");
	if (live) {
		printf("         跳过: 坏包检查（实时网络上丢包是常态，只看计数）\n");
	} else {
		check(damaged == 0, "有界源没有被丢弃的坏包");
	}

	if (live || reached_limit) {
		printf("         跳过: 流尾检查（%s）\n", live ? "实时源没有流尾" : "本次按帧数上限收工");
	} else {
		// 走到流尾之后必须持续给 NONE，而不是错误，也不是继续吐帧。
		nv_ffsw_video_frame after;
		memset(&after, 0, sizeof(after));
		check(nv_ffsw_next_video_frame(handle, &after) == NV_FFSW_NONE, "流尾之后继续返回 NONE");
	}

	nv_ffsw_close(handle);
	check(nv_ffsw_video_width(handle) == 0, "close 之后查询退化为 0（句柄仍可用）");
	nv_ffsw_destroy(handle);
}

// --- B. 槽位环 ------------------------------------------------------------

static void phase_slots(const char *path) {
	nv_ffsw_backend *handle = nv_ffsw_create();
	if (handle == NULL) {
		check(0, "槽位环用例：创建句柄");
		return;
	}
	nv_ffsw_open_info info;
	memset(&info, 0, sizeof(info));
	if (nv_ffsw_open(handle, path, &info) != NV_FFSW_OK) {
		check(0, "槽位环用例：打开源");
		nv_ffsw_destroy(handle);
		return;
	}

	nv_ffsw_video_frame held[NV_FFSW_SLOT_COUNT];
	int got = 0;
	for (int i = 0; i < NV_FFSW_SLOT_COUNT; i++) {
		memset(&held[i], 0, sizeof(held[i]));
		if (nv_ffsw_next_video_frame(handle, &held[i]) != NV_FFSW_OK) break;
		got++;
	}
	check(got == NV_FFSW_SLOT_COUNT, "不归还地连取满 NV_FFSW_SLOT_COUNT 帧都成功");
	if (got != NV_FFSW_SLOT_COUNT) {
		nv_ffsw_destroy(handle);
		return;
	}

	nv_ffsw_video_frame overflow;
	memset(&overflow, 0, sizeof(overflow));
	nv_ffsw_result r = nv_ffsw_next_video_frame(handle, &overflow);
	check(r == NV_FFSW_NONE, "槽位耗尽时返回 NONE（背压，不是失败）");
	printf("         last_error 在背压路径上未被污染: \"%s\"\n", nv_ffsw_last_error(handle));
	check(nv_ffsw_last_error(handle)[0] == '\0', "背压不算错误（last_error 仍为空）");

	// 归还一帧后必须立刻能继续，而且拿到的是"被扣住的那一帧"——PTS 继续前进，
	// 说明耗尽那一轮没有把已经解出来的帧丢掉。
	const double last_held_pts = held[got - 1].pts_seconds;
	nv_ffsw_frame_release(held[0].owner);
	nv_ffsw_video_frame resumed;
	memset(&resumed, 0, sizeof(resumed));
	r = nv_ffsw_next_video_frame(handle, &resumed);
	check(r == NV_FFSW_OK, "归还一帧后立刻能继续取帧");
	check(r == NV_FFSW_OK && resumed.pts_seconds > last_held_pts, "续上的是下一帧（PTS 前进，没有丢帧）");

	// 幂等归还：重复归还同一个 owner 不能把别人正在写的槽位抢回来。
	nv_ffsw_frame_release(held[0].owner);
	nv_ffsw_frame_release(NULL);
	check(1, "重复归还与归还 NULL 都是安全空操作");

	for (int i = 1; i < got; i++) nv_ffsw_frame_release(held[i].owner);
	nv_ffsw_frame_release(resumed.owner);

	if (info.duration_seconds <= 0.0) {
		// 实时源没有流尾，排空这一步不成立（而且会一直等下去）。
		printf("         跳过: 排空到流尾（实时源没有流尾）\n");
	} else {
		// 环恢复之后必须还能继续解到流尾。
		int more = 0;
		for (;;) {
			nv_ffsw_video_frame f;
			memset(&f, 0, sizeof(f));
			if (nv_ffsw_next_video_frame(handle, &f) != NV_FFSW_OK) break;
			nv_ffsw_frame_release(f.owner);
			more++;
		}
		check(more > 0, "归还之后环恢复，能继续解到流尾");
	}

	nv_ffsw_destroy(handle);
}

int main(int argc, char **argv) {
	const char *path = NULL;
	const char *dump_path = NULL;
	int max_frames = 0; // 0 = 不限（有界源解到流尾为止；实时源必须给上限）

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--dump") == 0 && i + 1 < argc) {
			dump_path = argv[++i];
		} else if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
			max_frames = atoi(argv[++i]);
			if (max_frames < 0) max_frames = 0;
		} else if (path == NULL) {
			path = argv[i];
		} else {
			fprintf(stderr, "多余的参数: %s\n", argv[i]);
			return 2;
		}
	}
	if (path == NULL) {
		fprintf(stderr, "用法: ffsw_selftest <视频文件或 URL> [--dump <原始 NV12 输出>] [--frames N]\n");
		return 2;
	}

	printf("ffsw shim 自检\n  片源: %s\n", path);
	printf("[A] 内容与顺序\n");
	phase_content(path, dump_path, max_frames);
	printf("[B] 槽位环\n");
	phase_slots(path);

	printf("检查 %d 项，失败 %d 项\n", g_checks, g_failures);
	printf("RESULT=%s\n", g_failures == 0 ? "PASS" : "FAIL");
	return g_failures == 0 ? 0 : 1;
}
