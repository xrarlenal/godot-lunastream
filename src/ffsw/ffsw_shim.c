// -----------------------------------------------------------------------
// ffsw_shim.c — FFmpeg 解封装 + 软件解码的 C 实现。
//
// 本文件分两步落地（0010）：
//   [x] 句柄生命周期、打开源、读取流信息与色域标签
//   [ ] 解码与打包 CPU NV12（含 10-bit 分支）—— 下一步
//
// 刻意先做前半：打开源这一步要走真实的 libavformat ABI，能不能编译、能不能
// 从真实源里读出宽高/帧率/色域，是后半个功能的前提。先在真实头文件上编译
// 通过，再往里填解码。
// -----------------------------------------------------------------------
#include "ffsw_shim.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/pixdesc.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct nv_ffsw_backend {
	AVFormatContext *fmt;
	AVCodecContext *dec;
	int video_stream_index;

	int width;
	int height;
	double duration_seconds;
	nv_ffsw_colorimetry color;

	char last_error[256];
};

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

nv_ffsw_backend *nv_ffsw_create(void) {
	nv_ffsw_backend *handle = calloc(1, sizeof(nv_ffsw_backend));
	if (handle == NULL) return NULL;
	handle->video_stream_index = -1;
	handle->color.bit_depth = 8;
	handle->color.range = NV_FFSW_RANGE_VIDEO;
	return handle;
}

void nv_ffsw_close(nv_ffsw_backend *handle) {
	if (handle == NULL) return;
	if (handle->dec != NULL) {
		avcodec_free_context(&handle->dec);
	}
	if (handle->fmt != NULL) {
		avformat_close_input(&handle->fmt);
	}
	handle->video_stream_index = -1;
	handle->width = 0;
	handle->height = 0;
	handle->duration_seconds = 0.0;
}

void nv_ffsw_destroy(nv_ffsw_backend *handle) {
	if (handle == NULL) return;
	nv_ffsw_close(handle);
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

const char *nv_ffsw_last_error(nv_ffsw_backend *handle) {
	if (handle == NULL) return "";
	return handle->last_error;
}

// 打开源并读流信息。只做 demux 侧的准备工作：这一步不开解码器，
// 解码器在下一步填进 next_video_frame 的实现里。
nv_ffsw_result nv_ffsw_open(nv_ffsw_backend *handle, const char *url_or_path, nv_ffsw_open_info *out_info) {
	if (handle == NULL || url_or_path == NULL) {
		set_error(handle, "open: null handle or url");
		return NV_FFSW_FAIL;
	}

	nv_ffsw_close(handle);

	int err = avformat_open_input(&handle->fmt, url_or_path, NULL, NULL);
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

nv_ffsw_codec_class nv_ffsw_probe(const char *url_or_path, nv_ffsw_open_info *out_info) {
	nv_ffsw_backend *handle = nv_ffsw_create();
	if (handle == NULL) return NV_FFSW_CODEC_UNKNOWN;

	nv_ffsw_codec_class klass = NV_FFSW_CODEC_UNKNOWN;
	if (nv_ffsw_open(handle, url_or_path, out_info) == NV_FFSW_OK) {
		AVStream *stream = handle->fmt->streams[handle->video_stream_index];
		klass = classify(stream->codecpar->codec_id);
		if (out_info != NULL && stream->avg_frame_rate.num > 0) {
			// 位深留给解码后的帧覆盖；这里只报告容器能说清的部分。
		}
	}
	nv_ffsw_destroy(handle);
	return klass;
}

// 解码与打包见下一步。在此之前明确返回 NONE（"干净地没有帧"），
// 而不是 FAIL —— 后端尚未实现不等于源有问题。
nv_ffsw_result nv_ffsw_next_video_frame(nv_ffsw_backend *handle, nv_ffsw_video_frame *out) {
	if (handle == NULL || out == NULL) {
		set_error(handle, "next_video_frame: null argument");
		return NV_FFSW_FAIL;
	}
	if (handle->fmt == NULL) {
		set_error(handle, "next_video_frame: no source open");
		return NV_FFSW_FAIL;
	}
	_Static_assert(sizeof(enum AVCodecID) >= 1, "ffmpeg headers present");
	// 未实现：见文件头注释。
	set_error(handle, "decode not implemented yet (0010 step 2)");
	return NV_FFSW_NONE;
}

void nv_ffsw_frame_release(void *owner) {
	// 槽位环在下一步引入；当前没有帧出队，故为空操作。
	(void)owner;
}
