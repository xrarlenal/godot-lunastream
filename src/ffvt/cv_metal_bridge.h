// -----------------------------------------------------------------------
// cv_metal_bridge.h —— CoreVideo 与 Metal 之间的最小桥（仅 macOS）。
//
// 两个用途，刻意放在一起但分开命名：
//
//   1. 生产路径（nv_cv_metal_view_*）：从解码器给的 CVPixelBufferRef 取出平面的
//      MTLTexture 视图。CVMetalTextureCache 做的是零拷贝——它把 IOSurface 包装成
//      MTLTexture，不复制一个字节。Godot 侧再用 texture_create_from_extension
//      把这个 MTLTexture 别名成自己的纹理 RID，于是"网口 → 解码 → 纹理"这条路上
//      没有 CPU 读回。
//
//   2. 验证路径（nv_cv_probe_*）：造一块已知内容的 NV12 像素缓冲。本仓库还没有
//      硬解后端（ffvt 尚未落地），所以 Metal 导入器需要一块"自己造出来的输入"才能
//      在真机上验证；这块输入是 IOSurface 支撑的，也就是零拷贝路径真正会走的那种
//      缓冲，而不是普通内存。
//
// 约定：所有指针都是不透明句柄；调用方只负责配对 create / destroy。
// -----------------------------------------------------------------------
#ifndef LUNASTREAM_CV_METAL_BRIDGE_H
#define LUNASTREAM_CV_METAL_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// --- 1. 验证路径：造一块已知内容的 NV12 像素缓冲 ---

typedef struct nv_cv_probe nv_cv_probe;

// 造一块 w x h 的 NV12（420YpCbCr8BiPlanarVideoRange）像素缓冲。返回 NULL 表示
// 创建失败。它必须由 IOSurface 支撑——只有那种缓冲才能被 Metal 零拷贝别名。
nv_cv_probe *nv_cv_probe_create(int width, int height);
void nv_cv_probe_destroy(nv_cv_probe *probe);

// 亮度平面的可写首地址与行距。
unsigned char *nv_cv_probe_luma(nv_cv_probe *probe);
int nv_cv_probe_luma_stride(nv_cv_probe *probe);

// 交织 CbCr 平面的可写首地址与行距。
unsigned char *nv_cv_probe_chroma(nv_cv_probe *probe);
int nv_cv_probe_chroma_stride(nv_cv_probe *probe);

int nv_cv_probe_width(nv_cv_probe *probe);
int nv_cv_probe_height(nv_cv_probe *probe);

// 拿到底层 CVPixelBufferRef（不转移所有权，probe 销毁前一直有效）。
void *nv_cv_probe_pixel_buffer(nv_cv_probe *probe);

// --- 2. 生产路径：像素缓冲 → 两块 MTLTexture 视图 ---

typedef struct {
	// id<MTLTexture>：亮度平面（R8）与交织色度平面（RG8）。
	void *luma_texture;
	void *chroma_texture;
	int width;
	int height;
	// 私有：CVMetalTextureRef 与缓存，销毁时必须还回去。
	void *luma_ref;
	void *chroma_ref;
	void *cache;
} nv_cv_metal_view;

// 为一帧像素缓冲建立 Metal 视图。不复制数据：视图直接指向 IOSurface。
// 返回 0 成功、-1 失败（此时 out 未定义）。
int nv_cv_metal_view_create(void *pixel_buffer, nv_cv_metal_view *out);

// 释放视图（以及它持有的 CVMetalTextureRef）。可重复调用。
void nv_cv_metal_view_destroy(nv_cv_metal_view *view);

#ifdef __cplusplus
}
#endif

#endif // LUNASTREAM_CV_METAL_BRIDGE_H
