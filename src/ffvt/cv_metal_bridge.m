// -----------------------------------------------------------------------
// cv_metal_bridge.m —— CoreVideo 与 Metal 之间的桥（Objective-C，仅 macOS）。
//
// 为什么是 .m 而不是 .c：MTLCreateSystemDefaultDevice() 返回 id<MTLDevice>，而
// CVMetalTextureCacheCreate 要的就是这个类型。用 C 文件调它们得自己摆弄
// objc_msgSend，不如老老实实用 Objective-C——这个桥的全部代码就这么多，
// 语言转换的代价比 ObjC 运行时更贵。
//
// 不用 ARC：这里管的全是 CF 风格对象（CFRelease / CVPixelBufferRelease /
// CVMetalTextureRelease），手工管理更清楚，也避免跨语言边界时引用计数语义
// 被编译器改写。
// -----------------------------------------------------------------------
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#include "cv_metal_bridge.h"

#include <stdlib.h>

struct nv_cv_probe {
	CVPixelBufferRef buffer;
	int width;
	int height;
	int luma_stride;
	int chroma_stride;
};

nv_cv_probe *nv_cv_probe_create(int width, int height) {
	if (width <= 0 || height <= 0) return NULL;

	// IOSurface 支撑是必要条件：没有它，Metal 没法把这块内存包装成纹理，
	// 也就无所谓零拷贝。真机上 420YpCbCr8BiPlanar 默认就是 IOSurface 支撑的。
	NSDictionary *attrs = @{
		(id)kCVPixelBufferIOSurfacePropertiesKey : @{},
		(id)kCVPixelBufferMetalCompatibilityKey : @YES,
	};
	CVPixelBufferRef buffer = NULL;
	const CVReturn rc = CVPixelBufferCreate(kCFAllocatorDefault, (size_t)width, (size_t)height,
	                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
	                                        (__bridge CFDictionaryRef)attrs, &buffer);
	if (rc != kCVReturnSuccess || buffer == NULL) return NULL;

	nv_cv_probe *probe = calloc(1, sizeof(nv_cv_probe));
	if (probe == NULL) {
		CVPixelBufferRelease(buffer);
		return NULL;
	}
	probe->buffer = buffer;
	probe->width = width;
	probe->height = height;

	// 锁定之后才能拿基地址（这样才能往平面里写测试内容）。
	if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
		free(probe);
		CVPixelBufferRelease(buffer);
		return NULL;
	}
	probe->luma_stride = (int)CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
	probe->chroma_stride = (int)CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
	return probe;
}

void nv_cv_probe_destroy(nv_cv_probe *probe) {
	if (probe == NULL) return;
	if (probe->buffer != NULL) {
		CVPixelBufferUnlockBaseAddress(probe->buffer, 0);
		CVPixelBufferRelease(probe->buffer);
	}
	free(probe);
}

unsigned char *nv_cv_probe_luma(nv_cv_probe *probe) {
	if (probe == NULL) return NULL;
	return (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(probe->buffer, 0);
}

int nv_cv_probe_luma_stride(nv_cv_probe *probe) {
	return probe == NULL ? 0 : probe->luma_stride;
}

unsigned char *nv_cv_probe_chroma(nv_cv_probe *probe) {
	if (probe == NULL) return NULL;
	return (unsigned char *)CVPixelBufferGetBaseAddressOfPlane(probe->buffer, 1);
}

int nv_cv_probe_chroma_stride(nv_cv_probe *probe) {
	return probe == NULL ? 0 : probe->chroma_stride;
}

int nv_cv_probe_width(nv_cv_probe *probe) {
	return probe == NULL ? 0 : probe->width;
}

int nv_cv_probe_height(nv_cv_probe *probe) {
	return probe == NULL ? 0 : probe->height;
}

void *nv_cv_probe_pixel_buffer(nv_cv_probe *probe) {
	return probe == NULL ? NULL : (void *)probe->buffer;
}

int nv_cv_metal_view_create(void *pixel_buffer, nv_cv_metal_view *out) {
	if (pixel_buffer == NULL || out == NULL) return -1;
	CVPixelBufferRef buffer = (CVPixelBufferRef)pixel_buffer;

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	if (device == nil) return -1;

	CVMetalTextureCacheRef cache = NULL;
	if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &cache) != kCVReturnSuccess ||
	    cache == NULL) {
		return -1;
	}

	const size_t width = CVPixelBufferGetWidth(buffer);
	const size_t height = CVPixelBufferGetHeight(buffer);

	CVMetalTextureRef luma = NULL;
	CVMetalTextureRef chroma = NULL;
	// 平面 0 = 亮度（R8），平面 1 = 交织 CbCr（RG8）。这两个 MTLTexture 直接指向
	// IOSurface 的对应平面——没有拷贝。
	if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, NULL,
	                                              MTLPixelFormatR8Unorm, width, height, 0,
	                                              &luma) != kCVReturnSuccess ||
	    luma == NULL) {
		CFRelease(cache);
		return -1;
	}
	if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, NULL,
	                                              MTLPixelFormatRG8Unorm, width / 2, height / 2, 1,
	                                              &chroma) != kCVReturnSuccess ||
	    chroma == NULL) {
		CFRelease(luma);
		CFRelease(cache);
		return -1;
	}

	out->luma_texture = (void *)CVMetalTextureGetTexture(luma);
	out->chroma_texture = (void *)CVMetalTextureGetTexture(chroma);
	out->width = (int)width;
	out->height = (int)height;
	out->luma_ref = (void *)luma;
	out->chroma_ref = (void *)chroma;
	out->cache = (void *)cache;
	return 0;
}

void nv_cv_metal_view_destroy(nv_cv_metal_view *view) {
	if (view == NULL) return;
	if (view->luma_ref != NULL) CFRelease((CVMetalTextureRef)view->luma_ref);
	if (view->chroma_ref != NULL) CFRelease((CVMetalTextureRef)view->chroma_ref);
	if (view->cache != NULL) CFRelease((CVMetalTextureCacheRef)view->cache);
	view->luma_ref = NULL;
	view->chroma_ref = NULL;
	view->cache = NULL;
	view->luma_texture = NULL;
	view->chroma_texture = NULL;
}
