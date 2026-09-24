// -----------------------------------------------------------------------
// ffva_shim.h — FFmpeg demux + VAAPI hardware decode shim (Linux).
//
// FFmpeg 负责 RTSP/文件 demux；VAAPI 负责解码。解码输出保留在 GPU/VPU 显存里，
// 通过 vaExportSurfaceHandle(DRM_PRIME_2) 导出 dma-buf（带 DRM format modifier），
// 交给 Vulkan importer 导入（不经过 CPU）。
//
// 导出的是 DRM 的「object / layer / plane」三级描述：一个 dma-buf object 里可以
// 有多个 layer，每个 layer 有多个 plane（NV12 = 1 layer 2 plane，通常都在同一个
// object 里）。这里把每个 object 的 fd dup 一份、每个 plane 的 offset/pitch 以及
// 所属 layer 的 format modifier 都搬到 nv_ffva_frame 里，让 importer 能自己组
// VkImageDrmFormatModifierExplicitCreateInfoEXT 的 plane layout。
//
// 只声明用到的最小 VAAPI ABI（不依赖 libva 头文件），与项目其它 shim 一致。
// -----------------------------------------------------------------------
#ifndef NV_FFVA_SHIM_H
#define NV_FFVA_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Colorimetry tag values（与 core/backend.zig 枚举数值一致） ---
enum {
	NV_FFVA_MATRIX_UNSPECIFIED = 0,
	NV_FFVA_MATRIX_BT709 = 1,
	NV_FFVA_MATRIX_BT601 = 2,
	NV_FFVA_MATRIX_BT2020 = 3,
};
enum {
	NV_FFVA_PRIM_UNSPECIFIED = 0,
	NV_FFVA_PRIM_BT709 = 1,
	NV_FFVA_PRIM_BT601_625 = 2,
	NV_FFVA_PRIM_BT601_525 = 3,
	NV_FFVA_PRIM_BT2020 = 4,
	NV_FFVA_PRIM_DCI_P3 = 5,
};
enum {
	NV_FFVA_TRANSFER_UNSPECIFIED = 0,
	NV_FFVA_TRANSFER_BT709 = 1,
	NV_FFVA_TRANSFER_PQ = 2,
	NV_FFVA_TRANSFER_HLG = 3,
};
enum {
	NV_FFVA_RANGE_UNSPECIFIED = 0,
	NV_FFVA_RANGE_VIDEO = 1,
	NV_FFVA_RANGE_FULL = 2,
};
enum {
	NV_FFVA_PIXFMT_UNKNOWN = 0,
	NV_FFVA_PIXFMT_NV12 = 1,
	NV_FFVA_PIXFMT_X420 = 2,
	NV_FFVA_PIXFMT_BGRA8 = 3,
};

typedef enum {
	NV_FFVA_FAIL = -1,
	NV_FFVA_NONE = 0,
	NV_FFVA_OK = 1,
} nv_ffva_result;

typedef struct {
	int matrix;
	int primaries;
	int transfer;
	int range;
	int bit_depth;
} nv_ffva_colorimetry;

typedef struct {
	double duration_seconds;
	int width;
	int height;
	int has_video;
	nv_ffva_colorimetry color;
} nv_ffva_open_info;

// 一帧解码结果：dma-buf 描述（最多 4 个 object / 4 个 plane）。
// object_fds[] 是 shim dup 出来的 fd，所有权在 shim；调用方用完必须调用
// nv_ffva_frame_release（它会把 fds 关掉、释放 AVFrame，从而把 VAAPI surface
// 还给解码器的 surface pool）。
typedef struct {
	double pts_seconds;

	// 显示尺寸（裁剪后要显示的区域）与它在解码表面里的左上角。
	int width;
	int height;
	int crop_x;
	int crop_y;

	// 解码表面的实际尺寸：dma-buf 按它分配，>= width/height（宏块对齐会多出边）。
	// VkImage 必须按这个尺寸创建，拷贝时再裁到 width/height。
	int surface_width;
	int surface_height;

	int pixel_format;       // NV_FFVA_PIXFMT_*
	uint32_t drm_fourcc;    // DRM_FORMAT_NV12 / DRM_FORMAT_P010 ...
	int plane_count;
	int object_count;
	int object_fds[4];      // 每个 DRM object 一个 dup 的 dma-buf fd（-1 = 空）
	uint32_t plane_object[4]; // 每个 plane 属于哪个 object（object_fds 的下标）
	uint32_t offsets[4];
	uint32_t pitches[4];
	uint64_t modifiers[4];  // 每个 plane 所属 layer 的 DRM format modifier
	nv_ffva_colorimetry color;
	void *owner;            // AVFrame*（shim 内部管理）
} nv_ffva_frame;

// --- ABI 探针（ffvt_shim.h 的同款做法：Zig 侧的 struct 镜像在这里校验） ---
typedef struct {
	size_t sizeof_colorimetry;
	size_t off_colorimetry[5];

	size_t sizeof_open_info;
	size_t off_open_info[5]; // duration_seconds, width, height, has_video, color

	size_t sizeof_frame;
	size_t off_frame[16]; // pts_seconds .. owner，见 ffva_shim.c
} nv_ffva_abi_probe;

void nv_ffva_abi_probe_fill(nv_ffva_abi_probe *out);

// --- Lifecycle ---
void *nv_ffva_create(void);
void nv_ffva_destroy(void *handle);

nv_ffva_result nv_ffva_open(void *handle, const char *url_or_path, nv_ffva_open_info *info);
void nv_ffva_close(void *handle);

// 取下一帧：NV_FFVA_OK 填好 *out；NV_FFVA_NONE 表示流结束/无新帧；NV_FFVA_FAIL 表示错误。
nv_ffva_result nv_ffva_next_frame(void *handle, nv_ffva_frame *out);

// 释放一帧（关闭 dup 的 fd、释放 AVFrame）。
void nv_ffva_frame_release(nv_ffva_frame *frame);

#ifdef __cplusplus
}
#endif

#endif // NV_FFVA_SHIM_H
