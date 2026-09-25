// -----------------------------------------------------------------------
// ffsw_shim.c — FFmpeg 解封装 + 软件解码的 C 实现。
//
// 本文件分步实现（0010）：
//   [x] 句柄生命周期、打开源、读取流信息与色域标签
//   [x] 解码循环与 CPU NV12 打包（8-bit）
//   [ ] 10-bit（yuv420p10le / P010 右对齐）—— 0011
//
// 刻意先做前半：打开源这一步要走真实的 libavformat ABI，能不能编译、能不能
// 从真实源里读出宽高/帧率/色域，是后半个功能的前提。先在真实头文件上编译
// 通过，再往里填解码。
//
// 解码这一段只做"把解码器的输出重新打包成 NV12"，**不做色域换算**：色域矩阵、
// 码值范围、位深对齐由 core 的色彩层（0006）与共享 GLSL compute 负责，硬解与
// 软解两条路共用同一份。这里多做一步换算就等于让两条路各有一套颜色。
// -----------------------------------------------------------------------
#include "ffsw_shim.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/pixdesc.h>
#include <libavutil/rational.h>
#include <libswscale/swscale.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 一个 CPU NV12 槽位。y 与 uv 两块分别紧凑分配（无行填充），跨帧复用：
// 稳定态下取帧与归还都不分配内存。
typedef struct {
	unsigned char *y;
	unsigned char *uv;
	size_t y_cap;
	size_t uv_cap;
	int in_use;
	int width;
	int height;
	int uv_row; // 交织 CbCr 平面的一行字节数（偶数宽度下等于 width）
} nv_ffsw_slot;

struct nv_ffsw_backend {
	AVFormatContext *fmt;
	AVCodecContext *dec;
	AVPacket *pkt;
	AVFrame *frame;
	struct SwsContext *sws;
	enum AVPixelFormat sws_src_fmt;
	enum AVPixelFormat sws_dst_fmt;
	int sws_src_w;
	int sws_src_h;

	int video_stream_index;

	// 解码状态机：读到流尾 → 送 flush 哨兵（draining）→ 排空（eof）。
	int draining;
	int eof;
	// 手上有一个包还没能送进解码器（解码器输入满）。它必须留着下次再送，
	// 否则那个包里的帧就永远丢了。
	int pkt_pending;
	int pkt_is_flush;
	// 已经解出来、只是上一轮没拿到槽位的那一帧。留着它，槽位耗尽的 NONE
	// 才是纯背压（可重试），而不是丢帧。
	int frame_pending;

	// 读取阶段遇到的硬错误（网络超时等）。0 = 没有。
	//
	// 它与"读到流尾"必须分开：文件读完是干净的 NONE，源死掉是 FAIL——
	// 后者要让调用方去重开（0008 的重连状态机就是为这件事存在的）。
	int stream_error;
	int64_t io_timeout_us;

	// 被丢掉的坏包数。实时网络上它是常态（UDP 丢包、拼接错位），所以丢一个
	// 包绝不能变成"整条流失败"——但也不能装作没发生，因此计数待查。
	long long damaged_packets;

	// 打开时记下的编码分类（省得为了打印一行字再连一次源）。
	nv_ffsw_codec_class codec_class;

	int width;
	int height;
	// 源没给时间戳时的兜底帧间隔（秒），由帧率推得。
	double fallback_interval;
	double duration_seconds;
	nv_ffsw_colorimetry color;

	nv_ffsw_slot slots[NV_FFSW_SLOT_COUNT];
	int slot_cursor;

	long long frames_out;
	double last_pts;
	int have_last_pts;

	char last_error[256];
};

// 流结束时的收场。定义在文件末尾，但解码路径的错误分支要用到它。
static nv_ffsw_result report_end(nv_ffsw_backend *handle);

static void set_error(nv_ffsw_backend *handle, const char *what) {
	if (handle == NULL) return;
	snprintf(handle->last_error, sizeof(handle->last_error), "%s", what);
}

// FFmpeg 的色域枚举 -> 本 shim 的标签。数值必须与 backend.zig/color.zig 对齐。
static int map_matrix(enum AVColorSpace cs) {
	switch (cs) {
	case AVCOL_SPC_BT709:
		return NV_FFSW_MATRIX_BT709;
	case AVCOL_SPC_BT470BG:
	case AVCOL_SPC_SMPTE170M:
		return NV_FFSW_MATRIX_BT601;
	case AVCOL_SPC_BT2020_NCL:
	case AVCOL_SPC_BT2020_CL:
		return NV_FFSW_MATRIX_BT2020;
	default:
		return NV_FFSW_MATRIX_UNSPECIFIED;
	}
}

static int map_primaries(enum AVColorPrimaries pr) {
	switch (pr) {
	case AVCOL_PRI_BT709:
		return NV_FFSW_PRIM_BT709;
	case AVCOL_PRI_BT470BG:
		return NV_FFSW_PRIM_BT601_625;
	case AVCOL_PRI_SMPTE170M:
		return NV_FFSW_PRIM_BT601_525;
	case AVCOL_PRI_BT2020:
		return NV_FFSW_PRIM_BT2020;
	default:
		return NV_FFSW_PRIM_UNSPECIFIED;
	}
}

static int map_transfer(enum AVColorTransferCharacteristic tr) {
	switch (tr) {
	case AVCOL_TRC_BT709:
		return NV_FFSW_TRANSFER_BT709;
	case AVCOL_TRC_GAMMA22:
		return NV_FFSW_TRANSFER_GAMMA22;
	case AVCOL_TRC_GAMMA28:
		return NV_FFSW_TRANSFER_GAMMA28;
	case AVCOL_TRC_SMPTE2084:
		return NV_FFSW_TRANSFER_PQ;
	case AVCOL_TRC_ARIB_STD_B67:
		return NV_FFSW_TRANSFER_HLG;
	default:
		return NV_FFSW_TRANSFER_UNSPECIFIED;
	}
}

static int map_range(enum AVColorRange r) {
	return r == AVCOL_RANGE_JPEG ? NV_FFSW_RANGE_FULL : NV_FFSW_RANGE_VIDEO;
}

// 编码 id -> 分类。0009 的选择器只关心"这个平台的后端有没有实现它"，
// 所以这里只需要分成 H264 / HEVC / 其它三类。
static nv_ffsw_codec_class classify(enum AVCodecID id) {
	switch (id) {
	case AV_CODEC_ID_H264:
		return NV_FFSW_CODEC_H264;
	case AV_CODEC_ID_HEVC:
		return NV_FFSW_CODEC_HEVC;
	case AV_CODEC_ID_NONE:
		return NV_FFSW_CODEC_UNKNOWN;
	default:
		return NV_FFSW_CODEC_OTHER;
	}
}

// 比特深度：解码器给出的格式决定 8 还是 10。
static int bit_depth_of(enum AVPixelFormat fmt) {
	const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(fmt);
	if (desc == NULL) return 8;
	return desc->comp[0].depth > 8 ? 10 : 8;
}

// --- 槽位环 ---------------------------------------------------------------

// 取一个空槽位：从游标处轮转扫描，取不到返回 NULL（调用方如实回 NONE）。
// 轮转而不是固定复用 0 号槽，是为了让"还没归还"的几块缓冲自然错开，
// 免得一块缓冲被反复改写、把消费者手上那份踩掉。
static nv_ffsw_slot *slot_acquire(nv_ffsw_backend *handle) {
	for (int i = 0; i < NV_FFSW_SLOT_COUNT; i++) {
		const int idx = (handle->slot_cursor + i) % NV_FFSW_SLOT_COUNT;
		if (!handle->slots[idx].in_use) {
			handle->slot_cursor = (idx + 1) % NV_FFSW_SLOT_COUNT;
			handle->slots[idx].in_use = 1;
			return &handle->slots[idx];
		}
	}
	return NULL;
}

// 归还槽位。幂等：重复归还是空操作，不会把别人正在写的槽位抢回来。
static void slot_release(nv_ffsw_slot *slot) {
	if (slot == NULL) return;
	slot->in_use = 0;
}

// 让槽位装得下 w x h 的半平面 4:2:0。跨帧复用，尺寸不变时不分配——稳定态下
// 取帧与归还都不碰堆。
//
// bytes_per_sample 把 8-bit（NV12）与 10-bit（每个样值 16 位容器）统一到同一套
// 算术里：两者的平面布局完全一样，只差每个样值的字节数。
static int slot_reserve(nv_ffsw_slot *slot, int w, int h, int bytes_per_sample) {
	const size_t y_size = (size_t)w * (size_t)h * (size_t)bytes_per_sample;
	// 交织 CbCr 平面：半分辨率、每像素对 2 个样值，所以一行
	// ((w+1)/2) * 2 * 字节数 ——偶数宽度下正好是 w * 字节数
	//（与头文件里"8-bit 时 stride == width、10-bit 时 == width * 2"一致）。
	const int uv_row = ((w + 1) / 2) * 2 * bytes_per_sample;
	const size_t uv_size = (size_t)uv_row * (size_t)((h + 1) / 2);

	if (slot->y_cap < y_size) {
		unsigned char *grown = realloc(slot->y, y_size);
		if (grown == NULL) return -1;
		slot->y = grown;
		slot->y_cap = y_size;
	}
	if (slot->uv_cap < uv_size) {
		unsigned char *grown = realloc(slot->uv, uv_size);
		if (grown == NULL) return -1;
		slot->uv = grown;
		slot->uv_cap = uv_size;
	}
	slot->width = w;
	slot->height = h;
	slot->uv_row = uv_row;
	return 0;
}

// 把 MSB 对齐的 16 位样值原地改成右对齐（每个样值右移 6 位）。
//
// 为什么需要它：本项目对 10-bit 的约定是**右对齐**（10 位有效码值放在 16 位容器
// 的低位），而 ffmpeg 里 4:2:0 的半平面 16 位容器只有 P010——它是 MSB 对齐的
// （`1023 << 6`）。另一个候选 NV20 虽然右对齐，但它是 **4:2:2**（色度只做水平
// 下采样），与 4:2:0 的平面布局不同，不能拿来用。
//
// 代价是这一步唯一的额外内存遍历：1.5 * w * h 个样值。换来的是帧布局只有一种
// 约定，消费者不必再问"这帧是 P010 还是右对齐"。
static void right_align_in_place(nv_ffsw_slot *slot, int w, int h) {
	const size_t y_samples = (size_t)w * (size_t)h;
	uint16_t *y = (uint16_t *)slot->y;
	for (size_t i = 0; i < y_samples; i++) {
		y[i] = (uint16_t)(y[i] >> 6);
	}

	// 两个平面都是紧凑的，所以整个平面可以当成一个数组走。
	const size_t uv_samples = (size_t)(slot->uv_row / 2) * (size_t)((h + 1) / 2);
	uint16_t *uv = (uint16_t *)slot->uv;
	for (size_t i = 0; i < uv_samples; i++) {
		uv[i] = (uint16_t)(uv[i] >> 6);
	}
}

// --- 解码器 ---------------------------------------------------------------

static int open_decoder(nv_ffsw_backend *handle, const AVStream *stream) {
	const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
	if (codec == NULL) {
		set_error(handle, "no decoder for this codec");
		return -1;
	}
	handle->dec = avcodec_alloc_context3(codec);
	if (handle->dec == NULL) {
		set_error(handle, "avcodec_alloc_context3 failed");
		return -1;
	}
	if (avcodec_parameters_to_context(handle->dec, stream->codecpar) < 0) {
		set_error(handle, "avcodec_parameters_to_context failed");
		return -1;
	}
	// 帧时间戳按流的时间基给；不设它，best_effort_timestamp 的换算就是错的。
	handle->dec->pkt_timebase = stream->time_base;
	// 一路流一个解码器，多路并行已经由 core 的 worker 池承担（每路流一个
	// worker）。这里再开解码器内部线程等于与 worker 池抢核。
	handle->dec->thread_count = 1;
	if (avcodec_open2(handle->dec, codec, NULL) < 0) {
		set_error(handle, "avcodec_open2 failed");
		return -1;
	}
	return 0;
}

// 给解码器喂输入。返回 1 = 有进展（可以接着 receive）、0 = 输入已经到底、
// -1 = 硬错误。
static int feed_decoder(nv_ffsw_backend *handle) {
	for (;;) {
		if (!handle->pkt_pending) {
			if (handle->draining) return 0; // 哨兵已送过，解码器不再要输入
			const int r = av_read_frame(handle->fmt, handle->pkt);
			if (r < 0) {
				// 流尾与读错误（超时等）都要先把解码器排空——它缓冲里可能还有
				// 解好的帧，直接判失败会把那几帧丢掉。但两者**分开记账**：
				// 文件读完是干净的结束，源中途死掉是要重开的失败。
				if (r != AVERROR_EOF) handle->stream_error = r;
				handle->pkt_is_flush = 1;
				handle->pkt_pending = 1;
			} else if (handle->pkt->stream_index != handle->video_stream_index) {
				av_packet_unref(handle->pkt); // 只解视频，别的流直接放掉
				continue;
			} else {
				handle->pkt_is_flush = 0;
				handle->pkt_pending = 1;
			}
		}

		const int s = avcodec_send_packet(handle->dec, handle->pkt_is_flush ? NULL : handle->pkt);
		if (s == AVERROR(EAGAIN)) {
			// 解码器输入满：包留在手上，等调用方 receive 腾出空间再送。
			return 1;
		}
		if (s == AVERROR_EOF) {
			// 它已经排空过了，后面的输入不会再要。
			av_packet_unref(handle->pkt);
			handle->pkt_pending = 0;
			handle->draining = 1;
			return 0;
		}
		if (s < 0) {
			if (s == AVERROR_INVALIDDATA) {
				// 坏包在实时源上是常态（UDP 丢包、TS 拼接错位）。丢掉它继续，
				// 否则一个坏包就能把整条通道打死——实测在 UDP 推流中途接入时
				// 就是这样：0 帧、直接 FAIL。
				handle->damaged_packets++;
				av_packet_unref(handle->pkt);
				handle->pkt_pending = 0;
				return 1;
			}
			char msg[96];
			snprintf(msg, sizeof(msg), "avcodec_send_packet failed (%d)", s);
			set_error(handle, msg);
			av_packet_unref(handle->pkt);
			handle->pkt_pending = 0;
			return -1;
		}
		av_packet_unref(handle->pkt);
		handle->pkt_pending = 0;
		if (handle->pkt_is_flush) handle->draining = 1;
		return 1;
	}
}

// 同尺寸、只换像素布局的转换上下文：不做缩放。
//
// 用 SWS_BICUBIC 是刻意的：它就是 ffmpeg 命令行在不给 `-sws_flags` 时的默认值，
// 所以"与 ffmpeg 自己的解码逐字节对照"这条验证对 4:4:4 / 4:2:2 源也能成立
// （4:2:0 源根本不发生色度重采样，这个标志不影响结果）。
//
// dst_fmt 必须进缓存键：8-bit 与 10-bit 是两种输出格式，同一个上下文换不了。
static int ensure_sws(nv_ffsw_backend *handle, enum AVPixelFormat src_fmt, enum AVPixelFormat dst_fmt,
                      int w, int h) {
	const int same = handle->sws != NULL && handle->sws_src_fmt == src_fmt && handle->sws_dst_fmt == dst_fmt;
	if (same && handle->sws_src_w == w && handle->sws_src_h == h) return 0;
	if (handle->sws != NULL) {
		sws_freeContext(handle->sws);
		handle->sws = NULL;
	}
	handle->sws = sws_getContext(w, h, src_fmt, w, h, dst_fmt, SWS_BICUBIC, NULL, NULL, NULL);
	if (handle->sws == NULL) return -1;
	handle->sws_src_fmt = src_fmt;
	handle->sws_dst_fmt = dst_fmt;
	handle->sws_src_w = w;
	handle->sws_src_h = h;
	return 0;
}

// 把 handle->frame 里的解码帧打包进槽位，并填好 out。
//
// 只重排布局（YUV → NV12），**不做色域换算**：矩阵、码值范围、位深对齐都在
// core 的色彩层与共享 GLSL compute 里做，硬解与软解共用同一份。
static nv_ffsw_result pack_frame(nv_ffsw_backend *handle, nv_ffsw_slot *slot, nv_ffsw_video_frame *out) {
	AVFrame *f = handle->frame;

	const int depth = bit_depth_of((enum AVPixelFormat)f->format);
	if (depth != 8 && depth != 10) {
		// 12-bit（yuv420p12le / P012）不在承诺范围内：宁可明确失败，也不悄悄
		// 截成 10 位——那是把动态范围砍掉一段而使用者看不出来。
		set_error(handle, "only 8-bit and 10-bit software decode are supported");
		return NV_FFSW_FAIL;
	}
	const int bytes_per_sample = depth > 8 ? 2 : 1;
	// 10-bit 先让 swscale 出 P010（4:2:0 半平面、16 位容器、MSB 对齐），
	// 再原地右移 6 位变成本项目约定的右对齐。布局与 NV12 完全同构，只是每个
	// 样值占 2 字节。
	// （三个目标平台都是小端，所以固定 LE；将来要上大端才需要在这里分叉。）
	const enum AVPixelFormat dst_fmt = depth > 8 ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;

	const int w = f->width;
	const int h = f->height;
	if (w <= 0 || h <= 0) {
		set_error(handle, "decoded frame has no size");
		return NV_FFSW_FAIL;
	}
	if (slot_reserve(slot, w, h, bytes_per_sample) != 0) {
		set_error(handle, "out of memory for NV12 slot");
		return NV_FFSW_FAIL;
	}
	if (ensure_sws(handle, (enum AVPixelFormat)f->format, dst_fmt, w, h) != 0) {
		set_error(handle, "sws_getContext failed");
		return NV_FFSW_FAIL;
	}

	uint8_t *dst[4] = { slot->y, slot->uv, NULL, NULL };
	const int y_row = w * bytes_per_sample;
	const int dst_stride[4] = { y_row, slot->uv_row, 0, 0 };
	const int scaled = sws_scale(handle->sws, (const uint8_t *const *)f->data, f->linesize, 0, h, dst, dst_stride);
	if (scaled <= 0) {
		set_error(handle, "sws_scale failed");
		return NV_FFSW_FAIL;
	}
	if (depth > 8) right_align_in_place(slot, w, h);

	// 容器上的尺寸可能与解码后的显示尺寸不同（宏块对齐 / 裁剪）。以帧为准，
	// 让之后的 video_width/height 与真实输出一致。
	if (w != handle->width || h != handle->height) {
		handle->width = w;
		handle->height = h;
	}

	// 逐帧色域：帧上明确写了的值优先（比容器更贴近实际），否则沿用容器。
	nv_ffsw_colorimetry c = handle->color;
	if (f->colorspace != AVCOL_SPC_UNSPECIFIED) c.matrix = map_matrix(f->colorspace);
	if (f->color_primaries != AVCOL_PRI_UNSPECIFIED) c.primaries = map_primaries(f->color_primaries);
	if (f->color_trc != AVCOL_TRC_UNSPECIFIED) c.transfer = map_transfer(f->color_trc);
	if (f->color_range != AVCOL_RANGE_UNSPECIFIED) c.range = map_range(f->color_range);
	c.bit_depth = depth;

	int64_t ts = f->best_effort_timestamp;
	if (ts == AV_NOPTS_VALUE) ts = f->pts;
	double pts;
	if (ts == AV_NOPTS_VALUE) {
		// 源没给时间戳（部分裸流）：按帧率往前推，保持单调。
		pts = handle->have_last_pts ? handle->last_pts + handle->fallback_interval : 0.0;
	} else {
		pts = (double)ts * av_q2d(handle->fmt->streams[handle->video_stream_index]->time_base);
	}
	handle->last_pts = pts;
	handle->have_last_pts = 1;
	handle->frames_out++;

	out->y = slot->y;
	out->uv = slot->uv;
	out->y_stride = y_row;
	out->uv_stride = slot->uv_row;
	out->width = w;
	out->height = h;
	out->bit_depth = depth;
	out->pts_seconds = pts;
	out->color = c;
	out->owner = slot;
	return NV_FFSW_OK;
}

nv_ffsw_backend *nv_ffsw_create(void) {
	nv_ffsw_backend *handle = calloc(1, sizeof(nv_ffsw_backend));
	if (handle == NULL) return NULL;
	handle->video_stream_index = -1;
	handle->color.bit_depth = 8;
	handle->color.range = NV_FFSW_RANGE_VIDEO;
	handle->fallback_interval = 1.0 / 25.0; // 帧率未知时的兜底
	handle->io_timeout_us = 5000000;        // 5 秒：能收场，又不至于误杀慢源
	return handle;
}

void nv_ffsw_set_io_timeout_us(nv_ffsw_backend *handle, int64_t microseconds) {
	if (handle == NULL) return;
	handle->io_timeout_us = microseconds < 0 ? 0 : microseconds;
}

void nv_ffsw_close(nv_ffsw_backend *handle) {
	if (handle == NULL) return;
	if (handle->sws != NULL) {
		sws_freeContext(handle->sws);
		handle->sws = NULL;
	}
	handle->sws_src_fmt = AV_PIX_FMT_NONE;
	handle->sws_dst_fmt = AV_PIX_FMT_NONE;
	handle->sws_src_w = 0;
	handle->sws_src_h = 0;
	if (handle->frame != NULL) av_frame_free(&handle->frame);
	if (handle->pkt != NULL) av_packet_free(&handle->pkt);
	if (handle->dec != NULL) {
		avcodec_free_context(&handle->dec);
	}
	if (handle->fmt != NULL) {
		avformat_close_input(&handle->fmt);
	}

	// 槽位缓冲留着复用（destroy 才释放），但归属必须回到"没人持有"：
	// close 之后旧帧的 owner 立即失效——与三个兄弟 shim 同契约。
	for (int i = 0; i < NV_FFSW_SLOT_COUNT; i++) {
		handle->slots[i].in_use = 0;
	}
	handle->slot_cursor = 0;
	handle->draining = 0;
	handle->eof = 0;
	handle->pkt_pending = 0;
	handle->pkt_is_flush = 0;
	handle->frame_pending = 0;
	handle->stream_error = 0;
	handle->damaged_packets = 0;
	handle->frames_out = 0;
	handle->last_pts = 0.0;
	handle->have_last_pts = 0;
	handle->video_stream_index = -1;
	handle->width = 0;
	handle->height = 0;
	handle->duration_seconds = 0.0;
}

void nv_ffsw_destroy(nv_ffsw_backend *handle) {
	if (handle == NULL) return;
	nv_ffsw_close(handle);
	for (int i = 0; i < NV_FFSW_SLOT_COUNT; i++) {
		free(handle->slots[i].y);
		free(handle->slots[i].uv);
	}
	free(handle);
}

double nv_ffsw_duration_seconds(nv_ffsw_backend *handle) {
	return handle == NULL ? 0.0 : handle->duration_seconds;
}

int nv_ffsw_video_width(nv_ffsw_backend *handle) {
	return handle == NULL ? 0 : handle->width;
}

int nv_ffsw_video_height(nv_ffsw_backend *handle) {
	return handle == NULL ? 0 : handle->height;
}

nv_ffsw_colorimetry nv_ffsw_colorimetry_of(nv_ffsw_backend *handle) {
	nv_ffsw_colorimetry empty;
	memset(&empty, 0, sizeof(empty));
	empty.bit_depth = 8;
	empty.range = NV_FFSW_RANGE_VIDEO;
	return handle == NULL ? empty : handle->color;
}

long long nv_ffsw_damaged_packet_count(nv_ffsw_backend *handle) {
	return handle == NULL ? 0 : handle->damaged_packets;
}

const char *nv_ffsw_last_error(nv_ffsw_backend *handle) {
	if (handle == NULL) return "";
	return handle->last_error;
}

// 源没给时间戳时的兜底帧间隔：优先平均帧率，其次标称帧率，最后 25 fps。
static double fallback_interval_of(const AVStream *stream) {
	AVRational r = stream->avg_frame_rate;
	if (r.num <= 0 || r.den <= 0) r = stream->r_frame_rate;
	if (r.num <= 0 || r.den <= 0) return 1.0 / 25.0;
	const double fps = (double)r.num / (double)r.den;
	if (fps <= 0.0) return 1.0 / 25.0;
	return 1.0 / fps;
}

// URL 是否走 RTSP（大小写不敏感）。
static int is_rtsp_url(const char *url) {
	return strncasecmp(url, "rtsp://", 7) == 0 || strncasecmp(url, "rtsps://", 8) == 0;
}

// 哪些协议认 `timeout` / `stimeout` 这两个"连接/会话超时"旋钮。
//
// 这件事不能无脑对所有协议都设：**`rtmp://` 里的 `timeout` 是 `listen_timeout`**
//（监听模式用的那个），塞进去之后打开请求会变成
//   tcp://host:1935?listen&listen_timeout=<乱数>
// 于是连不上——实测 `rtmp://95.67.11.153/klive/stream` 就是被我们自己的选项打死
// 的，而且报错只说 "Cannot open connection"，看不出是选项干的。
//
// 超时这件事本身交给 `rw_timeout` 就够：那是 I/O 层的通用旋钮，TCP 也照它办，
// 且**不会改协议的语义**。所以策略是：rw_timeout 人人有份，这两个只给列出来的协议。
static int wants_protocol_timeouts(const char *url) {
	return is_rtsp_url(url) ||
	       strncasecmp(url, "udp://", 6) == 0 ||
	       strncasecmp(url, "rtp://", 6) == 0;
}

// 打开源时用的协议选项。
//
// 两件事是刻意的：
//   * **超时**：实时源必须能收场。没有超时的 av_read_frame 会把解码线程永久
//     挂住——实测把 UDP 推流停掉之后进程就在那里不动了。rw_timeout 是协议层
//     的通用旋钮，timeout / stimeout 分别覆盖 udp+rtsp 与旧版 rtsp 的写法
//     （只给这些协议，理由见 wants_protocol_timeouts）。
//   * **RTSP 一律走 TCP**：UDP 承载在丢包下会让帧碎片化，而且不少摄像机默认
//     就是 UDP。代价是重传带来的延迟抖动，对"稳定出画"这个目标更划算。
static AVDictionary *build_open_options(const nv_ffsw_backend *handle, const char *url_or_path) {
	AVDictionary *opts = NULL;
	if (handle->io_timeout_us > 0) {
		char buf[32];
		snprintf(buf, sizeof(buf), "%lld", (long long)handle->io_timeout_us);
		av_dict_set(&opts, "rw_timeout", buf, 0);
		if (wants_protocol_timeouts(url_or_path)) {
			av_dict_set(&opts, "timeout", buf, 0);
			av_dict_set(&opts, "stimeout", buf, 0);
		}
	}
	if (is_rtsp_url(url_or_path)) {
		av_dict_set(&opts, "rtsp_transport", "tcp", 0);
	}
	return opts;
}

// 打开源并读流信息。with_decoder = 0 时只做准备（探测用）：`auto` 档靠一次
// 轻量探测拿编码分类来决定走硬解还是软解，不该为此付一次解码器初始化。
static nv_ffsw_result open_source(nv_ffsw_backend *handle, const char *url_or_path,
                                  nv_ffsw_open_info *out_info, int with_decoder) {
	if (handle == NULL || url_or_path == NULL) {
		set_error(handle, "open: null handle or url");
		return NV_FFSW_FAIL;
	}

	nv_ffsw_close(handle);

	AVDictionary *opts = build_open_options(handle, url_or_path);
	int err = avformat_open_input(&handle->fmt, url_or_path, NULL, &opts);
	av_dict_free(&opts);
	if (err < 0) {
		set_error(handle, "avformat_open_input failed");
		return NV_FFSW_FAIL;
	}

	err = avformat_find_stream_info(handle->fmt, NULL);
	if (err < 0) {
		set_error(handle, "avformat_find_stream_info failed");
		nv_ffsw_close(handle);
		return NV_FFSW_FAIL;
	}

	int index = av_find_best_stream(handle->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
	if (index < 0) {
		set_error(handle, "no video stream");
		nv_ffsw_close(handle);
		return NV_FFSW_FAIL;
	}
	handle->video_stream_index = index;

	AVStream *stream = handle->fmt->streams[index];
	handle->codec_class = classify(stream->codecpar->codec_id);
	handle->width = stream->codecpar->width;
	handle->height = stream->codecpar->height;

	if (handle->fmt->duration != AV_NOPTS_VALUE && handle->fmt->duration > 0) {
		handle->duration_seconds = (double)handle->fmt->duration / (double)AV_TIME_BASE;
	} else {
		handle->duration_seconds = 0.0; // 直播源无时长
	}

	handle->color.matrix = map_matrix(stream->codecpar->color_space);
	handle->color.primaries = map_primaries(stream->codecpar->color_primaries);
	handle->color.transfer = map_transfer(stream->codecpar->color_trc);
	handle->color.range = map_range(stream->codecpar->color_range);
	handle->color.bit_depth = 8; // 真实位深由解码后的帧覆盖
	handle->fallback_interval = fallback_interval_of(stream);

	// 容器里的像素格式只是最佳猜测（有些编码器到首个关键帧才说清），
	// 真正的位深由解码后的帧给出并逐帧覆盖。
	if (stream->codecpar->format >= 0) {
		handle->color.bit_depth = bit_depth_of((enum AVPixelFormat)stream->codecpar->format);
	}

	if (with_decoder) {
		handle->pkt = av_packet_alloc();
		handle->frame = av_frame_alloc();
		if (handle->pkt == NULL || handle->frame == NULL) {
			set_error(handle, "alloc packet/frame failed");
			nv_ffsw_close(handle);
			return NV_FFSW_FAIL;
		}
		if (open_decoder(handle, stream) != 0) {
			nv_ffsw_close(handle);
			return NV_FFSW_FAIL;
		}
	}

	if (out_info != NULL) {
		memset(out_info, 0, sizeof(*out_info));
		out_info->duration_seconds = handle->duration_seconds;
		out_info->width = handle->width;
		out_info->height = handle->height;
		out_info->has_video = 1;
		out_info->color = handle->color;
	}
	return NV_FFSW_OK;
}

// 正式打开：连解码器一起备好（这是"能出帧"的路径）。
nv_ffsw_result nv_ffsw_open(nv_ffsw_backend *handle, const char *url_or_path, nv_ffsw_open_info *out_info) {
	return open_source(handle, url_or_path, out_info, 1);
}

nv_ffsw_codec_class nv_ffsw_probe(const char *url_or_path, nv_ffsw_open_info *out_info) {
	nv_ffsw_backend *handle = nv_ffsw_create();
	if (handle == NULL) return NV_FFSW_CODEC_UNKNOWN;

	nv_ffsw_codec_class klass = NV_FFSW_CODEC_UNKNOWN;
	if (open_source(handle, url_or_path, out_info, 0) == NV_FFSW_OK) {
		AVStream *stream = handle->fmt->streams[handle->video_stream_index];
		klass = classify(stream->codecpar->codec_id);
		if (out_info != NULL && stream->avg_frame_rate.num > 0) {
			// 位深留给解码后的帧覆盖；这里只报告容器能说清的部分。
		}
	}
	nv_ffsw_destroy(handle);
	return klass;
}

nv_ffsw_codec_class nv_ffsw_open_codec_class(nv_ffsw_backend *handle) {
	return handle == NULL ? NV_FFSW_CODEC_UNKNOWN : handle->codec_class;
}

nv_ffsw_result nv_ffsw_next_video_frame(nv_ffsw_backend *handle, nv_ffsw_video_frame *out) {
	if (handle == NULL || out == NULL) {
		set_error(handle, "next_video_frame: null argument");
		return NV_FFSW_FAIL;
	}
	if (handle->fmt == NULL || handle->dec == NULL) {
		set_error(handle, "next_video_frame: no source open");
		return NV_FFSW_FAIL;
	}

	// 已经排空的流：文件读完是干净的 NONE，源中途死掉是要重开的 FAIL。
	if (handle->eof) return report_end(handle);

	int stalls = 0;
	for (;;) {
		// 上一轮已经解出来、只是当时没有空槽位的那帧先交付。留着它，
		// 槽位耗尽的 NONE 才是纯背压（可重试）而不是丢帧。
		if (handle->frame_pending) {
			nv_ffsw_slot *slot = slot_acquire(handle);
			if (slot == NULL) return NV_FFSW_NONE;
			const nv_ffsw_result packed = pack_frame(handle, slot, out);
			if (packed != NV_FFSW_OK) {
				slot_release(slot);
				return packed;
			}
			handle->frame_pending = 0;
			av_frame_unref(handle->frame);
			return NV_FFSW_OK;
		}

		const int r = avcodec_receive_frame(handle->dec, handle->frame);
		if (r == 0) {
			handle->frame_pending = 1;
			continue; // 回到环顶去拿槽位并打包
		}
		if (r == AVERROR_EOF) {
			handle->eof = 1;
			return report_end(handle);
		}
		if (r != AVERROR(EAGAIN)) {
			char msg[96];
			snprintf(msg, sizeof(msg), "avcodec_receive_frame failed (%d)", r);
			set_error(handle, msg);
			return NV_FFSW_FAIL;
		}

		// EAGAIN：解码器要更多输入才能出下一帧。
		const int fed = feed_decoder(handle);
		if (fed < 0) return NV_FFSW_FAIL;
		// 输入到底后 receive 只可能给 EOF 或最后一帧；这里再兜一次，
		// 免得解码器行为异常时把调用方转进死循环。
		if (fed == 0 && ++stalls > 1) {
			handle->eof = 1;
			return report_end(handle);
		}
	}
}

void nv_ffsw_frame_release(void *owner) {
	slot_release((nv_ffsw_slot *)owner);
}

// 流结束时的收场：干净读完给 NONE，读到硬错误（超时等）给 FAIL 并写明原因。
// 这两个结果对调用方意味着完全不同的动作——继续等，还是重开。
static nv_ffsw_result report_end(nv_ffsw_backend *handle) {
	if (handle->stream_error == 0) return NV_FFSW_NONE;
	char msg[96];
	snprintf(msg, sizeof(msg), "read failed (%d)", handle->stream_error);
	set_error(handle, msg);
	return NV_FFSW_FAIL;
}
