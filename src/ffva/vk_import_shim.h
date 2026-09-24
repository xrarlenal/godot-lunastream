// -----------------------------------------------------------------------
// vk_import_shim.h — 把 VAAPI 解码出的 dma-buf 平面导入 Godot 的 Vulkan 设备，
// 在 GPU 内把两个平面分别拷进 Godot 的两张纹理（luma / chroma）。
//
// 为什么不用 RenderingDevice.texture_create_from_extension：
//   该 API 不能选择多平面 image 的 plane（aspectMask），导入 NV12 时两个平面会
//   被绑成同一个 view，拿到的是错的画面（上游 Godot 提案 #15116 未合入）。
//   这里改用 Godot 自己的 VkDevice 创建**外部 image**（dma-buf 内存导入 +
//   DRM format modifier），再用 vkCmdCopyImage 把 plane0/plane1 分别拷进 Godot
//   自己建的两张单平面纹理（R8/R16、RG8/RG16）。拷贝发生在同一个 GPU 上，
//   数据全程不落 CPU；裁剪（宏块对齐多出来的边）也在这次拷贝里完成。
//
// 之后 Godot 那条既有的 NV12→RGB compute pass 照常采样这两张纹理，所以 Linux
// 与 Windows/macOS 共用同一份颜色管线（SDR/HDR、色域、范围全都不用重写）。
//
// 设备/队列/目标纹理都由 Zig 侧通过 RenderingDevice.get_driver_resource 取出后
// 传入；优先级是复用 Godot 自己的 queue（同一 queue 天然和 Godot 的提交有序，
// 也省掉跨 queue 同步），取不到时才自己找 graphics 队列。
// -----------------------------------------------------------------------
#ifndef NV_VK_IMPORT_SHIM_H
#define NV_VK_IMPORT_SHIM_H

#include <stdint.h>

#include "ffva_shim.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct nv_vk_importer nv_vk_importer;

// vk_instance / vk_physical_device / vk_device：RenderingDevice 的
//   TOPMOST_OBJECT / PHYSICAL_DEVICE / LOGICAL_DEVICE。
// vk_queue / queue_family_index：RenderingDevice 的 COMMAND_QUEUE 与 QUEUE_FAMILY；
//   传 0 表示「取不到」，importer 自己找一个带 graphics 位的队列族。
// 返回 NULL 表示 Vulkan 加载失败/必要的 device 级函数取不到（调用方退回软路径）。
nv_vk_importer *nv_vk_import_create(uint64_t vk_instance, uint64_t vk_physical_device,
		uint64_t vk_device, uint64_t vk_queue, uint32_t queue_family_index);

void nv_vk_import_destroy(nv_vk_importer *importer);

// 把一帧 dma-buf 的两个平面拷进 Godot 的两张纹理：
//   luma_image   —— R8  (8-bit NV12) / R16 (10-bit P010)，尺寸 luma_width x luma_height
//   chroma_image —— R8G8(8-bit NV12) / R16G16(10-bit P010)，尺寸 chroma_width x chroma_height
// 尺寸必须是调用方实际创建的纹理尺寸；chroma 一般为 ceil(luma/2)，plane 的拷贝
// extent 就按这里给的尺寸（源图像是宏块对齐的 surface，多出来的边不拷）。
// 提交后等待 fence 完成再返回：返回 NV_FFVA_OK 时画面已经在 Godot 的纹理里，
// 调用方可以立刻让 Godot 采样。NV_FFVA_FAIL 表示失败（原因写 stderr）。
nv_ffva_result nv_vk_import_frame(nv_vk_importer *importer, const nv_ffva_frame *frame,
		uint64_t luma_image, int luma_width, int luma_height,
		uint64_t chroma_image, int chroma_width, int chroma_height);

#ifdef __cplusplus
}
#endif

#endif // NV_VK_IMPORT_SHIM_H
