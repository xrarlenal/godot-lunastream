// -----------------------------------------------------------------------
// ffsw_shim.h — FFmpeg 解封装 + **软件解码**的纯 C ABI。
//
// 与三个硬解 shim（ffvt / ffd3d / ffva）平级：FFmpeg 在这里既解封装也解码，
// 每帧打包成普通系统内存里的 NV12（一张亮度平面 + 一张交织 CbCr 平面）。
// 没有系统句柄可以别名，所以呈现管线对这些帧做上传而不是导入——上传之后
// 的一切（NV12→RGB compute、色域处理、输出环）与零拷贝路径完全共用同一份代码。
//
// 之所以与硬解后端并存：三个硬解后端覆盖的编码很窄（ffvt 只有 H.264，
// ffd3d/ffva 是 H.264/HEVC），MPEG4/VP9/AV1/MJPEG 源原本**完全没有通路**；
// 而且软解是可以显式选择的通道策略，不是"硬解失败后的静默降级"——
// 同进程里可以由调用方决定一路硬解、一路软解并行。
//
// 只做视频（无音频）、无 seek，与三个兄弟 shim 同契约。
//
// 下面枚举的数值必须与 core/backend.zig 的标签一致，Zig 侧才能 @enumFromInt 直转。
// -----------------------------------------------------------------------
#ifndef LUNASTREAM_FFSW_SHIM_H
#define LUNASTREAM_FFSW_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- 色域标签（镜像 backend.zig / color.zig 的枚举数值） ---
enum {
	NV_FFSW_MATRIX_UNSPECIFIED = 0,
	NV_FFSW_MATRIX_BT709 = 1,
	NV_FFSW_MATRIX_BT601 = 2,
	NV_FFSW_MATRIX_BT2020 = 3,
};
enum {
	NV_FFSW_PRIM_UNSPECIFIED = 0,
	NV_FFSW_PRIM_BT709 = 1,
	NV_FFSW_PRIM_BT601_625 = 2,
	NV_FFSW_PRIM_BT601_525 = 3,
	NV_FFSW_PRIM_BT2020 = 4,
};
enum {
	NV_FFSW_TRANSFER_UNSPECIFIED = 0,
	NV_FFSW_TRANSFER_BT709 = 1,
	NV_FFSW_TRANSFER_GAMMA22 = 2,
	NV_FFSW_TRANSFER_GAMMA28 = 3,
	NV_FFSW_TRANSFER_PQ = 4,
	NV_FFSW_TRANSFER_HLG = 5,
};
enum {
	NV_FFSW_RANGE_VIDEO = 0,
	NV_FFSW_RANGE_FULL = 1,
};

// 源携带的编码family。这正是 0009 的解码器选择器要读的东西：分类不在平台硬解
// 白名单里，`auto` 就直接送软解，而不是"先试硬解再失败"。
typedef enum {
	NV_FFSW_CODEC_UNKNOWN = 0,
	NV_FFSW_CODEC_H264 = 1,
	NV_FFSW_CODEC_HEVC = 2,
	NV_FFSW_CODEC_OTHER = 3, // mpeg4 / vp9 / av1 / mjpeg / 其它
} nv_ffsw_codec_class;

// 三态返回码，与三个兄弟 shim 同语义：
//   FAIL = 硬失败（需要重开）；
//   NONE = 干净的软结果（流结束，或暂时没有帧）；
//   OK   = 成功。
typedef enum {
	NV_FFSW_FAIL = -1,
	NV_FFSW_NONE = 0,
	NV_FFSW_OK = 1,
} nv_ffsw_result;

// 内部槽位环的容量。依据是 core 的表面数量公式
// `requiredPoolDepth(队列可用槽位, frame_latency) = 队列 + 1 + 回收环`：
//
//   DecodeAheadQueue 可用槽位 = 8 - 1 = 7
//   正在转换/呈现的 1 帧
//   回收环（呈现后再停 N 帧）取上限 4
//   → 7 + 1 + 4 = 12
//
// 取 12 是为了让**正确归还帧的消费者不会撞到上限**：槽位耗尽返回 NONE，
// 但只要有消费者忘了调 nv_ffsw_frame_release，环就会枯竭并让这条流停帧——
// 这是刻意的，它把"忘了归还"变成可复现的现象，而不是默默泄漏。
#define NV_FFSW_SLOT_COUNT 12

// 不透明句柄：nv_ffsw_create 创建，nv_ffsw_destroy 释放。
typedef struct nv_ffsw_backend nv_ffsw_backend;

typedef struct {
	int matrix;    // NV_FFSW_MATRIX_*
	int primaries; // NV_FFSW_PRIM_*
	int transfer;  // NV_FFSW_TRANSFER_*
	int range;     // NV_FFSW_RANGE_*
	int bit_depth; // 8 或 10。open 时协商，因此帧到达前只是最佳猜测；
	               // nv_ffsw_video_frame.bit_depth 携带真实值并逐帧覆盖它。
} nv_ffsw_colorimetry;

typedef struct {
	double duration_seconds; // 直播源无时长时为 0
	int width;               // 显示宽（已裁掉宏块对齐的边）
	int height;
	int has_video;           // 解析到视频流时为 1
	nv_ffsw_colorimetry color; // 协商得到的色域
} nv_ffsw_open_info;

// 一帧软件解码结果，位于 CPU 内存。
//
// `y` / `uv` 指向后端持有的存储，在把 `owner` 交给 nv_ffsw_frame_release 之前
// 一直有效。两个平面**紧凑打包无行填充**，所以 8-bit 时 stride == width、
// 10-bit 时 stride == width * 2；仍然逐帧上报 stride，是为了让布局日后可以
// 换成带填充的版本而不用改调用方。
//
// 10-bit 一律是**右对齐**：10 位有效码值放在 16 位容器的低位（实测 ffmpeg 的
// `nv20le` 就是这个约定，最大样值 1023）。它和 P010 的左对齐（`1023 << 6`）
// 是两种约定，core 的 color.zig 两种都能还原，但本 shim 只发右对齐这一种。
typedef struct {
	const unsigned char *y;   // 亮度平面
	const unsigned char *uv;  // 交织 CbCr 平面
	int y_stride;             // 字节/行
	int uv_stride;
	int width;                // 显示尺寸
	int height;
	int bit_depth;            // 8 或 10
	double pts_seconds;
	nv_ffsw_colorimetry color;

	// 槽位句柄。槽位环由 shim 内部维护，帧出队时不分配内存；
	// 归还只是把槽位放回环里。
	void *owner;
} nv_ffsw_video_frame;

// 轻量探测：只 open_input + 读流信息，**不开解码器**。
// `auto` 档要靠它拿编码分类来决定走硬解还是软解。
nv_ffsw_codec_class nv_ffsw_probe(const char *url_or_path, nv_ffsw_open_info *out_info);

nv_ffsw_backend *nv_ffsw_create(void);
void nv_ffsw_destroy(nv_ffsw_backend *handle);

// 打开源。out_info 可为 NULL。
nv_ffsw_result nv_ffsw_open(nv_ffsw_backend *handle, const char *url_or_path, nv_ffsw_open_info *out_info);

// 网络连接/读取超时（微秒），默认 5 000 000（5 秒）。必须在 nv_ffsw_open 之前
// 调用；传 0 表示交回 FFmpeg 的默认行为（可能永久阻塞）。
//
// 这个旋钮不是"调优项"而是"能不能收场"：实测把 UDP 推流停掉之后，没有超时的
// av_read_frame 会让解码线程一直挂着不返回。有超时之后，源死掉会变成一次
// 可上报的读错误，而不是一个不动的进程。
void nv_ffsw_set_io_timeout_us(nv_ffsw_backend *handle, int64_t microseconds);

// 关闭当前源但保留句柄（重新 open 前调用）。可重复调用。
void nv_ffsw_close(nv_ffsw_backend *handle);

double nv_ffsw_duration_seconds(nv_ffsw_backend *handle);
int nv_ffsw_video_width(nv_ffsw_backend *handle);
int nv_ffsw_video_height(nv_ffsw_backend *handle);
nv_ffsw_colorimetry nv_ffsw_colorimetry_of(nv_ffsw_backend *handle);

// 到目前为止被丢掉的坏包数。实时网络源上非零是正常的（UDP 丢包、TS 拼接
// 错位）；它只做观测，不代表流已经坏了。
long long nv_ffsw_damaged_packet_count(nv_ffsw_backend *handle);

// 取下一帧。OK / NONE（结束或暂无帧）/ FAIL（错误）。
// 槽位耗尽时返回 NONE，调度器会重试——与硬解后端语义一致。
nv_ffsw_result nv_ffsw_next_video_frame(nv_ffsw_backend *handle, nv_ffsw_video_frame *out);

// 归还一帧的槽位。frames 用完后必须调用，否则槽位环会枯竭。
void nv_ffsw_frame_release(void *owner);

// 最近一次错误，供日志使用；无错误时返回空串。
const char *nv_ffsw_last_error(nv_ffsw_backend *handle);

#ifdef __cplusplus
}
#endif

#endif // LUNASTREAM_FFSW_SHIM_H
