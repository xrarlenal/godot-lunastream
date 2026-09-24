// -----------------------------------------------------------------------
// vk_import_shim.c — dma-buf → Godot 纹理的 GPU 内导入（Linux）。
//
// 一段命令缓冲、两块纹理、零 CPU 拷贝：
//
//   VAAPI 解码表面（dma-buf, DRM format modifier）
//        │  vkCreateImage + VkImportMemoryFdInfoKHR（同一块显存，只是换了个句柄）
//        ▼
//   外部 nvk_VkImage（多平面 NV12 / P010，plane layout 来自 vaExportSurfaceHandle）
//        │  vkCmdCopyImage（plane0→luma、plane1→chroma，顺带裁掉宏块对齐的边）
//        ▼
//   Godot 自己的两张纹理（R8/R16、RG8/RG16），交给既有的 NV12→RGB compute pass
//
// 关键设计：
//   * 用 Godot 自己的 nvk_VkDevice / nvk_VkQueue（RenderingDevice.get_driver_resource），
//     不再新建设备：省掉一次跨设备共享，提交顺序也与 Godot 一致；
//   * 每帧提交后 fence 等待：返回时纹理内容已就绪，Godot 可以马上采样；
//   * dma-buf 按 (dev, ino) 缓存已导入的 nvk_VkImage（VAAPI 的 surface 是固定池，
//     同一个 buffer 会反复出现），避免每帧重建 image/import；
//   * 不依赖 <vulkan/vulkan.h>：目标机不需要 Vulkan SDK，交叉编译也不需要
//     （见文件末尾的 NV_VK_IMPORT_ABI_CHECK，本机可对着真头文件静态校验布局）。
//
// 状态：静态布局与编译已校验；尚未在真实 Linux + VAAPI 机器上跑通。
// -----------------------------------------------------------------------
#include "vk_import_shim.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// =======================================================================
// 最小 Vulkan ABI（数值抄自 vulkan_core.h，末尾有静态校验）
// =======================================================================
typedef uint32_t nvk_VkFlags;
typedef uint64_t nvk_VkDeviceSize;

typedef struct VkInstance_T *nvk_VkInstance;
typedef struct VkPhysicalDevice_T *nvk_VkPhysicalDevice;
typedef struct VkDevice_T *nvk_VkDevice;
typedef struct VkQueue_T *nvk_VkQueue;
typedef struct VkCommandBuffer_T *nvk_VkCommandBuffer;
typedef uint64_t nvk_VkImage;
typedef uint64_t nvk_VkDeviceMemory;
typedef uint64_t nvk_VkFence;
typedef uint64_t nvk_VkCommandPool;
typedef uint64_t nvk_VkSemaphore;

typedef int32_t nvk_VkResult;
#define NV_VK_SUCCESS 0
#define NV_VK_TIMEOUT 2
#define NV_VK_TRUE 1

// --- VkStructureType ---
#define NV_VK_STRUCTURE_TYPE_SUBMIT_INFO 4
#define NV_VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO 5
#define NV_VK_STRUCTURE_TYPE_FENCE_CREATE_INFO 8
#define NV_VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO 14
#define NV_VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO 39
#define NV_VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO 40
#define NV_VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO 42
#define NV_VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER 45
#define NV_VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO 1000127001
#define NV_VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO 1000072001
#define NV_VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR 1000074000
#define NV_VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT 1000158004

// --- VkFormat ---
#define NV_VK_FORMAT_R8_UNORM 9
#define NV_VK_FORMAT_R8G8_UNORM 16
#define NV_VK_FORMAT_R16_UNORM 70
#define NV_VK_FORMAT_R16G16_UNORM 77
#define NV_VK_FORMAT_G8_B8R8_2PLANE_420_UNORM 1000156003
#define NV_VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 1000156013

// --- 其它枚举 / 位 ---
#define NV_VK_IMAGE_TYPE_2D 1
#define NV_VK_SAMPLE_COUNT_1_BIT 0x00000001u
#define NV_VK_IMAGE_TILING_LINEAR 1
#define NV_VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT 1000158000
#define NV_VK_SHARING_MODE_EXCLUSIVE 0
#define NV_VK_IMAGE_LAYOUT_UNDEFINED 0
#define NV_VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL 5
#define NV_VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL 6
#define NV_VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 7
#define NV_VK_IMAGE_USAGE_TRANSFER_SRC_BIT 0x00000001u
#define NV_VK_IMAGE_ASPECT_COLOR_BIT 0x00000001u
#define NV_VK_IMAGE_ASPECT_PLANE_0_BIT 0x00000010u
#define NV_VK_IMAGE_ASPECT_PLANE_1_BIT 0x00000020u
#define NV_VK_PIPELINE_STAGE_TRANSFER_BIT 0x00001000u
#define NV_VK_PIPELINE_STAGE_ALL_COMMANDS_BIT 0x00010000u
#define NV_VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT 0x00000001u
#define NV_VK_ACCESS_TRANSFER_READ_BIT 0x00000800u
#define NV_VK_ACCESS_TRANSFER_WRITE_BIT 0x00001000u
#define NV_VK_ACCESS_SHADER_READ_BIT 0x00000020u
#define NV_VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT 0x00000001u
#define NV_VK_QUEUE_GRAPHICS_BIT 0x00000001u
#define NV_VK_COMMAND_BUFFER_LEVEL_PRIMARY 0
#define NV_VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT 0x00000002u
#define NV_VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT 0x00000200u
#define NV_VK_DRM_FORMAT_MOD_LINEAR 0ull
#define NV_VK_DRM_FORMAT_MOD_INVALID 0x00ffffffffffffffull

// --- 结构体（字段顺序/类型与 vulkan_core.h 一致） ---
typedef struct {
	uint32_t aspectMask;
	uint32_t mipLevel;
	uint32_t arrayLayer;
} nvk_VkImageSubresource;

// 拷贝/清屏用的是 VkImageSubresourceLayers（比 VkImageSubresource 多一个
// layerCount），两者不能混用——混用会让 srcOffset/extent 整体错位。
typedef struct {
	uint32_t aspectMask;
	uint32_t mipLevel;
	uint32_t baseArrayLayer;
	uint32_t layerCount;
} nvk_VkImageSubresourceLayers;

typedef struct {
	int32_t x, y, z;
} nvk_VkOffset3D;

typedef struct {
	uint32_t width, height, depth;
} nvk_VkExtent3D;

typedef struct {
	uint32_t aspectMask;
	uint32_t baseMipLevel;
	uint32_t levelCount;
	uint32_t baseArrayLayer;
	uint32_t layerCount;
} nvk_VkImageSubresourceRange;

typedef struct {
	nvk_VkDeviceSize offset;
	nvk_VkDeviceSize size;
	nvk_VkDeviceSize rowPitch;
	nvk_VkDeviceSize arrayPitch;
	nvk_VkDeviceSize depthPitch;
} nvk_VkSubresourceLayout;

typedef struct {
	uint32_t sType;
	const void *pNext;
	nvk_VkFlags flags;
	int32_t imageType;
	int32_t format;
	nvk_VkExtent3D extent;
	uint32_t mipLevels;
	uint32_t arrayLayers;
	nvk_VkFlags samples;
	int32_t tiling;
	nvk_VkFlags usage;
	int32_t sharingMode;
	uint32_t queueFamilyIndexCount;
	const uint32_t *pQueueFamilyIndices;
	int32_t initialLayout;
} nvk_VkImageCreateInfo;

typedef struct {
	uint32_t sType;
	const void *pNext;
	nvk_VkFlags handleTypes;
} nvk_VkExternalMemoryImageCreateInfo;

typedef struct {
	uint32_t sType;
	const void *pNext;
	uint64_t drmFormatModifier;
	uint32_t drmFormatModifierPlaneCount;
	const nvk_VkSubresourceLayout *pPlaneLayouts;
} nvk_VkImageDrmFormatModifierExplicitCreateInfoEXT;

typedef struct {
	nvk_VkDeviceSize size;
	nvk_VkDeviceSize alignment;
	uint32_t memoryTypeBits;
} nvk_VkMemoryRequirements;

typedef struct {
	uint32_t sType;
	const void *pNext;
	nvk_VkDeviceSize allocationSize;
	uint32_t memoryTypeIndex;
} nvk_VkMemoryAllocateInfo;

typedef struct {
	uint32_t sType;
	const void *pNext;
	nvk_VkImage image;
	uint64_t buffer;
} nvk_VkMemoryDedicatedAllocateInfo;

typedef struct {
	uint32_t sType;
	const void *pNext;
	uint32_t handleType;
	int fd;
} nvk_VkImportMemoryFdInfoKHR;

typedef struct {
	uint32_t sType;
	const void *pNext;
	nvk_VkFlags srcAccessMask;
	nvk_VkFlags dstAccessMask;
	int32_t oldLayout;
	int32_t newLayout;
	uint32_t srcQueueFamilyIndex;
	uint32_t dstQueueFamilyIndex;
	nvk_VkImage image;
	nvk_VkImageSubresourceRange subresourceRange;
} nvk_VkImageMemoryBarrier;

typedef struct {
	nvk_VkImageSubresourceLayers srcSubresource;
	nvk_VkOffset3D srcOffset;
	nvk_VkImageSubresourceLayers dstSubresource;
	nvk_VkOffset3D dstOffset;
	nvk_VkExtent3D extent;
} nvk_VkImageCopy;

typedef struct {
	uint32_t sType;
	const void *pNext;
	nvk_VkFlags flags;
	uint32_t queueFamilyIndex;
} nvk_VkCommandPoolCreateInfo;

typedef struct {
	uint32_t sType;
	const void *pNext;
	nvk_VkCommandPool commandPool;
	int32_t level;
	uint32_t commandBufferCount;
} nvk_VkCommandBufferAllocateInfo;

typedef struct {
	uint32_t sType;
	const void *pNext;
	nvk_VkFlags flags;
	const void *pInheritanceInfo;
} nvk_VkCommandBufferBeginInfo;

typedef struct {
	uint32_t sType;
	const void *pNext;
	nvk_VkFlags flags;
} nvk_VkFenceCreateInfo;

typedef struct {
	uint32_t sType;
	const void *pNext;
	uint32_t waitSemaphoreCount;
	const nvk_VkSemaphore *pWaitSemaphores;
	const nvk_VkFlags *pWaitDstStageMask;
	uint32_t commandBufferCount;
	const nvk_VkCommandBuffer *pCommandBuffers;
	uint32_t signalSemaphoreCount;
	const nvk_VkSemaphore *pSignalSemaphores;
} nvk_VkSubmitInfo;

typedef struct {
	nvk_VkFlags propertyFlags;
	uint32_t heapIndex;
} nvk_VkMemoryType;

typedef struct {
	nvk_VkDeviceSize size;
	nvk_VkFlags flags;
} nvk_VkMemoryHeap;

typedef struct {
	uint32_t memoryTypeCount;
	nvk_VkMemoryType memoryTypes[32];
	uint32_t memoryHeapCount;
	nvk_VkMemoryHeap memoryHeaps[16];
} nvk_VkPhysicalDeviceMemoryProperties;

typedef struct {
	nvk_VkFlags queueFlags;
	uint32_t queueCount;
	uint32_t timestampValidBits;
	nvk_VkExtent3D minImageTransferGranularity;
} nvk_VkQueueFamilyProperties;

// --- 函数指针类型 ---
// NVK_DEV_FN 只用于第一个参数是 nvk_VkDevice 的那批；命令缓冲级与队列级的函数
// 第一个参数分别是 nvk_VkCommandBuffer / nvk_VkQueue，单独声明。
#define NVK_DEV_FN(ret, name, ...) typedef ret (*nvk_pfn_##name)(nvk_VkDevice, __VA_ARGS__)
typedef void *(*nvk_pfn_vkGetInstanceProcAddr)(nvk_VkInstance, const char *);
typedef void *(*nvk_pfn_vkGetDeviceProcAddr)(nvk_VkDevice, const char *);

NVK_DEV_FN(nvk_VkResult, vkCreateImage, const nvk_VkImageCreateInfo *, const void *, nvk_VkImage *);
NVK_DEV_FN(void, vkDestroyImage, nvk_VkImage, const void *);
NVK_DEV_FN(void, vkGetImageMemoryRequirements, nvk_VkImage, nvk_VkMemoryRequirements *);
NVK_DEV_FN(nvk_VkResult, vkAllocateMemory, const nvk_VkMemoryAllocateInfo *, const void *, nvk_VkDeviceMemory *);
NVK_DEV_FN(void, vkFreeMemory, nvk_VkDeviceMemory, const void *);
NVK_DEV_FN(nvk_VkResult, vkBindImageMemory, nvk_VkImage, nvk_VkDeviceMemory, nvk_VkDeviceSize);
NVK_DEV_FN(void, vkGetDeviceQueue, uint32_t, uint32_t, nvk_VkQueue *);
NVK_DEV_FN(nvk_VkResult, vkCreateFence, const nvk_VkFenceCreateInfo *, const void *, nvk_VkFence *);
NVK_DEV_FN(void, vkDestroyFence, nvk_VkFence, const void *);
NVK_DEV_FN(nvk_VkResult, vkWaitForFences, uint32_t, const nvk_VkFence *, uint32_t, uint64_t);
NVK_DEV_FN(nvk_VkResult, vkResetFences, uint32_t, const nvk_VkFence *);
NVK_DEV_FN(nvk_VkResult, vkCreateCommandPool, const nvk_VkCommandPoolCreateInfo *, const void *, nvk_VkCommandPool *);
NVK_DEV_FN(void, vkDestroyCommandPool, nvk_VkCommandPool, const void *);
NVK_DEV_FN(nvk_VkResult, vkAllocateCommandBuffers, const nvk_VkCommandBufferAllocateInfo *, nvk_VkCommandBuffer *);
NVK_DEV_FN(void, vkFreeCommandBuffers, nvk_VkCommandPool, uint32_t, const nvk_VkCommandBuffer *);

typedef nvk_VkResult (*nvk_pfn_vkBeginCommandBuffer)(nvk_VkCommandBuffer, const nvk_VkCommandBufferBeginInfo *);
typedef nvk_VkResult (*nvk_pfn_vkEndCommandBuffer)(nvk_VkCommandBuffer);
typedef nvk_VkResult (*nvk_pfn_vkResetCommandBuffer)(nvk_VkCommandBuffer, nvk_VkFlags);
typedef void (*nvk_pfn_vkCmdPipelineBarrier)(nvk_VkCommandBuffer, nvk_VkFlags, nvk_VkFlags, nvk_VkFlags,
		uint32_t, const void *, uint32_t, const void *, uint32_t, const nvk_VkImageMemoryBarrier *);
typedef void (*nvk_pfn_vkCmdCopyImage)(nvk_VkCommandBuffer, nvk_VkImage, int32_t, nvk_VkImage, int32_t,
		uint32_t, const nvk_VkImageCopy *);
typedef nvk_VkResult (*nvk_pfn_vkQueueSubmit)(nvk_VkQueue, uint32_t, const nvk_VkSubmitInfo *, nvk_VkFence);
typedef nvk_VkResult (*nvk_pfn_vkQueueWaitIdle)(nvk_VkQueue);

typedef void (*nvk_pfn_vkGetPhysicalDeviceMemoryProperties)(nvk_VkPhysicalDevice, nvk_VkPhysicalDeviceMemoryProperties *);
typedef void (*nvk_pfn_vkGetPhysicalDeviceQueueFamilyProperties)(nvk_VkPhysicalDevice, uint32_t *, nvk_VkQueueFamilyProperties *);

#undef NVK_DEV_FN

// =======================================================================
// dma-buf 缓存：VAAPI 的 surface 是固定池，同一个 buffer 每帧都会再来一次。
// 命中缓存就复用它已经导入好的 nvk_VkImage（不再 vkCreateImage / import）。
// 键取 (dev, ino) + modifier + 两个平面的 offset/pitch + 表面尺寸/格式；
// 满了就淘汰最久没用过的那个（LRU），命中的按帧序号刷新时间戳。
// =======================================================================
#define NV_VK_CACHE_SLOTS 8

typedef struct {
	int used;
	uint64_t dev;
	uint64_t ino;
	uint64_t modifier;
	uint32_t offsets[2];
	uint32_t pitches[2];
	uint32_t surface_width;
	uint32_t surface_height;
	int32_t vk_format;
	uint64_t last_used;
	nvk_VkImage image;
	nvk_VkDeviceMemory memory;
} nv_vk_cached_image;

struct nv_vk_importer {
	nvk_VkDevice device;
	nvk_VkPhysicalDevice physical_device;
	nvk_VkQueue queue;
	uint32_t queue_family_index;

	nvk_VkCommandPool command_pool;
	nvk_VkCommandBuffer command_buffer;
	nvk_VkFence fence;
	int fence_pending;

	nvk_pfn_vkCreateImage create_image;
	nvk_pfn_vkDestroyImage destroy_image;
	nvk_pfn_vkGetImageMemoryRequirements get_image_memory_requirements;
	nvk_pfn_vkAllocateMemory allocate_memory;
	nvk_pfn_vkFreeMemory free_memory;
	nvk_pfn_vkBindImageMemory bind_image_memory;
	nvk_pfn_vkGetDeviceQueue get_device_queue;
	nvk_pfn_vkCreateFence create_fence;
	nvk_pfn_vkDestroyFence destroy_fence;
	nvk_pfn_vkWaitForFences wait_for_fences;
	nvk_pfn_vkResetFences reset_fences;
	nvk_pfn_vkCreateCommandPool create_command_pool;
	nvk_pfn_vkDestroyCommandPool destroy_command_pool;
	nvk_pfn_vkAllocateCommandBuffers allocate_command_buffers;
	nvk_pfn_vkFreeCommandBuffers free_command_buffers;
	nvk_pfn_vkBeginCommandBuffer begin_command_buffer;
	nvk_pfn_vkEndCommandBuffer end_command_buffer;
	nvk_pfn_vkResetCommandBuffer reset_command_buffer;
	nvk_pfn_vkCmdPipelineBarrier cmd_pipeline_barrier;
	nvk_pfn_vkCmdCopyImage cmd_copy_image;
	nvk_pfn_vkQueueSubmit queue_submit;
	nvk_pfn_vkQueueWaitIdle queue_wait_idle;

	nvk_pfn_vkGetPhysicalDeviceMemoryProperties get_memory_properties;
	nvk_pfn_vkGetPhysicalDeviceQueueFamilyProperties get_queue_family_properties;

	nv_vk_cached_image cache[NV_VK_CACHE_SLOTS];
	uint64_t frame_counter;
};

// -----------------------------------------------------------------------
// loader 与函数解析
// -----------------------------------------------------------------------
static nvk_pfn_vkGetInstanceProcAddr load_instance_proc_addr(void) {
	static int tried = 0;
	static nvk_pfn_vkGetInstanceProcAddr cached = NULL;
	if (tried) {
		return cached;
	}
	tried = 1;

	void *lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
	if (lib == NULL) {
		lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
	}
	if (lib != NULL) {
		cached = (nvk_pfn_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
	}
	if (cached == NULL) {
		// Godot 已经把 loader 载进进程了，退一步直接从全局符号表取
		cached = (nvk_pfn_vkGetInstanceProcAddr)dlsym(RTLD_DEFAULT, "vkGetInstanceProcAddr");
	}
	return cached;
}

static int resolve_device_functions(nv_vk_importer *imp, nvk_pfn_vkGetDeviceProcAddr gdpa) {
#define NVK_RESOLVE(field, name)                                                       \
	do {                                                                                \
		imp->field = (nvk_pfn_##name)gdpa(imp->device, #name);                           \
		if (imp->field == NULL) {                                                        \
			fprintf(stderr, "[vk_import] missing device function: %s\n", #name);          \
			return 0;                                                                     \
		}                                                                                 \
	} while (0)

	NVK_RESOLVE(create_image, vkCreateImage);
	NVK_RESOLVE(destroy_image, vkDestroyImage);
	NVK_RESOLVE(get_image_memory_requirements, vkGetImageMemoryRequirements);
	NVK_RESOLVE(allocate_memory, vkAllocateMemory);
	NVK_RESOLVE(free_memory, vkFreeMemory);
	NVK_RESOLVE(bind_image_memory, vkBindImageMemory);
	NVK_RESOLVE(get_device_queue, vkGetDeviceQueue);
	NVK_RESOLVE(create_fence, vkCreateFence);
	NVK_RESOLVE(destroy_fence, vkDestroyFence);
	NVK_RESOLVE(wait_for_fences, vkWaitForFences);
	NVK_RESOLVE(reset_fences, vkResetFences);
	NVK_RESOLVE(create_command_pool, vkCreateCommandPool);
	NVK_RESOLVE(destroy_command_pool, vkDestroyCommandPool);
	NVK_RESOLVE(allocate_command_buffers, vkAllocateCommandBuffers);
	NVK_RESOLVE(free_command_buffers, vkFreeCommandBuffers);
	NVK_RESOLVE(begin_command_buffer, vkBeginCommandBuffer);
	NVK_RESOLVE(end_command_buffer, vkEndCommandBuffer);
	NVK_RESOLVE(reset_command_buffer, vkResetCommandBuffer);
	NVK_RESOLVE(cmd_pipeline_barrier, vkCmdPipelineBarrier);
	NVK_RESOLVE(cmd_copy_image, vkCmdCopyImage);
	NVK_RESOLVE(queue_submit, vkQueueSubmit);
	NVK_RESOLVE(queue_wait_idle, vkQueueWaitIdle);

#undef NVK_RESOLVE
	return 1;
}

static int pick_memory_type(nv_vk_importer *imp, uint32_t type_bits) {
	if (imp->get_memory_properties != NULL) {
		nvk_VkPhysicalDeviceMemoryProperties props;
		memset(&props, 0, sizeof(props));
		imp->get_memory_properties(imp->physical_device, &props);
		int fallback = -1;
		uint32_t count = props.memoryTypeCount < 32 ? props.memoryTypeCount : 32;
		for (uint32_t i = 0; i < count; i++) {
			if ((type_bits & (1u << i)) == 0) {
				continue;
			}
			if (props.memoryTypes[i].propertyFlags & NV_VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) {
				return (int)i;
			}
			if (fallback < 0) {
				fallback = (int)i;
			}
		}
		return fallback;
	}
	for (uint32_t i = 0; i < 32; i++) {
		if (type_bits & (1u << i)) {
			return (int)i;
		}
	}
	return -1;
}

static uint32_t drm_format_to_vk_format(uint32_t drm_fourcc) {
	switch (drm_fourcc) {
		case 0x3231564E: /* NV12 */
			return NV_VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;
		case 0x30313050: /* P010 */
			return NV_VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16;
		default:
			return 0;
	}
}

// =======================================================================
// 生命周期
// =======================================================================
nv_vk_importer *nv_vk_import_create(uint64_t vk_instance, uint64_t vk_physical_device,
		uint64_t vk_device, uint64_t vk_queue, uint32_t queue_family_index) {
	if (vk_device == 0 || vk_physical_device == 0) {
		return NULL;
	}

	nvk_pfn_vkGetInstanceProcAddr gipa = load_instance_proc_addr();
	if (gipa == NULL) {
		fprintf(stderr, "[vk_import] vkGetInstanceProcAddr not found; is libvulkan loaded?\n");
		return NULL;
	}
	nvk_pfn_vkGetDeviceProcAddr gdpa = (nvk_pfn_vkGetDeviceProcAddr)
		gipa((nvk_VkInstance)(uintptr_t)vk_instance, "vkGetDeviceProcAddr");
	if (gdpa == NULL) {
		return NULL;
	}

	nv_vk_importer *imp = (nv_vk_importer *)calloc(1, sizeof(nv_vk_importer));
	if (imp == NULL) {
		return NULL;
	}
	imp->device = (nvk_VkDevice)(uintptr_t)vk_device;
	imp->physical_device = (nvk_VkPhysicalDevice)(uintptr_t)vk_physical_device;
	imp->queue = (nvk_VkQueue)(uintptr_t)vk_queue;
	imp->queue_family_index = queue_family_index;

	if (!resolve_device_functions(imp, gdpa)) {
		free(imp);
		return NULL;
	}

	nvk_VkInstance instance = (nvk_VkInstance)(uintptr_t)vk_instance;
	imp->get_memory_properties = (nvk_pfn_vkGetPhysicalDeviceMemoryProperties)
		gipa(instance, "vkGetPhysicalDeviceMemoryProperties");
	imp->get_queue_family_properties = (nvk_pfn_vkGetPhysicalDeviceQueueFamilyProperties)
		gipa(instance, "vkGetPhysicalDeviceQueueFamilyProperties");

	// Godot 没给出队列（或给的是 0）时，自己找一个带 graphics 位的队列族。
	if (imp->queue == NULL) {
		if (imp->get_queue_family_properties == NULL) {
			fprintf(stderr, "[vk_import] no queue given and cannot query queue families\n");
			free(imp);
			return NULL;
		}
		uint32_t count = 0;
		imp->get_queue_family_properties(imp->physical_device, &count, NULL);
		if (count == 0) {
			free(imp);
			return NULL;
		}
		nvk_VkQueueFamilyProperties *families =
			(nvk_VkQueueFamilyProperties *)calloc(count, sizeof(*families));
		if (families == NULL) {
			free(imp);
			return NULL;
		}
		imp->get_queue_family_properties(imp->physical_device, &count, families);
		int chosen = -1;
		for (uint32_t i = 0; i < count; i++) {
			if (families[i].queueCount > 0 &&
					(families[i].queueFlags & NV_VK_QUEUE_GRAPHICS_BIT)) {
				chosen = (int)i;
				break;
			}
		}
		free(families);
		if (chosen < 0) {
			fprintf(stderr, "[vk_import] no graphics queue family found\n");
			free(imp);
			return NULL;
		}
		imp->queue_family_index = (uint32_t)chosen;
		imp->get_device_queue(imp->device, imp->queue_family_index, 0, &imp->queue);
		if (imp->queue == NULL) {
			free(imp);
			return NULL;
		}
	}

	nvk_VkCommandPoolCreateInfo pool_info;
	memset(&pool_info, 0, sizeof(pool_info));
	pool_info.sType = NV_VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
	pool_info.flags = NV_VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	pool_info.queueFamilyIndex = imp->queue_family_index;
	if (imp->create_command_pool(imp->device, &pool_info, NULL, &imp->command_pool) != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkCreateCommandPool failed\n");
		free(imp);
		return NULL;
	}

	nvk_VkCommandBufferAllocateInfo buffer_info;
	memset(&buffer_info, 0, sizeof(buffer_info));
	buffer_info.sType = NV_VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
	buffer_info.commandPool = imp->command_pool;
	buffer_info.level = NV_VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	buffer_info.commandBufferCount = 1;
	if (imp->allocate_command_buffers(imp->device, &buffer_info, &imp->command_buffer) != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkAllocateCommandBuffers failed\n");
		imp->destroy_command_pool(imp->device, imp->command_pool, NULL);
		free(imp);
		return NULL;
	}

	nvk_VkFenceCreateInfo fence_info;
	memset(&fence_info, 0, sizeof(fence_info));
	fence_info.sType = NV_VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
	if (imp->create_fence(imp->device, &fence_info, NULL, &imp->fence) != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkCreateFence failed\n");
		imp->free_command_buffers(imp->device, imp->command_pool, 1, &imp->command_buffer);
		imp->destroy_command_pool(imp->device, imp->command_pool, NULL);
		free(imp);
		return NULL;
	}

	fprintf(stderr, "[vk_import] ready (queue family %u, %s queue)\n",
		imp->queue_family_index, vk_queue != 0 ? "Godot's" : "discovered");
	return imp;
}

static void destroy_cached_image(nv_vk_importer *imp, nv_vk_cached_image *entry) {
	if (entry->image != 0) {
		imp->destroy_image(imp->device, entry->image, NULL);
		entry->image = 0;
	}
	if (entry->memory != 0) {
		imp->free_memory(imp->device, entry->memory, NULL);
		entry->memory = 0;
	}
	entry->used = 0;
}

void nv_vk_import_destroy(nv_vk_importer *imp) {
	if (imp == NULL) {
		return;
	}
	// 正在飞的命令先做完，再销毁它引用的 image。
	if (imp->fence_pending) {
		imp->wait_for_fences(imp->device, 1, &imp->fence, NV_VK_TRUE, 2000000000ull);
		imp->fence_pending = 0;
	}
	imp->queue_wait_idle(imp->queue);
	for (int i = 0; i < NV_VK_CACHE_SLOTS; i++) {
		destroy_cached_image(imp, &imp->cache[i]);
	}
	if (imp->fence != 0) {
		imp->destroy_fence(imp->device, imp->fence, NULL);
	}
	if (imp->command_pool != 0) {
		imp->destroy_command_pool(imp->device, imp->command_pool, NULL);
	}
	free(imp);
}

// =======================================================================
// 缓存查找 / 写入
// =======================================================================
static int dma_buf_identity(int fd, uint64_t *dev, uint64_t *ino) {
	struct stat st;
	if (fstat(fd, &st) != 0) {
		return 0;
	}
	*dev = (uint64_t)st.st_dev;
	*ino = (uint64_t)st.st_ino;
	return 1;
}

static int cache_key_matches(const nv_vk_cached_image *entry, uint64_t dev, uint64_t ino,
		const nv_ffva_frame *frame, int32_t vk_format) {
	if (!entry->used || entry->dev != dev || entry->ino != ino ||
			entry->modifier != frame->modifiers[0] || entry->vk_format != vk_format ||
			entry->surface_width != (uint32_t)frame->surface_width ||
			entry->surface_height != (uint32_t)frame->surface_height) {
		return 0;
	}
	for (int i = 0; i < 2; i++) {
		if (entry->offsets[i] != frame->offsets[i] || entry->pitches[i] != frame->pitches[i]) {
			return 0;
		}
	}
	return 1;
}

static nv_vk_cached_image *cache_lookup_or_evict(nv_vk_importer *imp, uint64_t dev, uint64_t ino,
		const nv_ffva_frame *frame, int32_t vk_format) {
	for (int i = 0; i < NV_VK_CACHE_SLOTS; i++) {
		if (cache_key_matches(&imp->cache[i], dev, ino, frame, vk_format)) {
			return &imp->cache[i];
		}
	}
	nv_vk_cached_image *victim = &imp->cache[0];
	for (int i = 0; i < NV_VK_CACHE_SLOTS; i++) {
		if (!imp->cache[i].used) {
			victim = &imp->cache[i];
			break;
		}
		if (imp->cache[i].last_used < victim->last_used) {
			victim = &imp->cache[i];
		}
	}
	destroy_cached_image(imp, victim);
	return victim;
}

// =======================================================================
// 创建 / 导入外部 image
// =======================================================================
static int create_external_image(nv_vk_importer *imp, const nv_ffva_frame *frame,
		int32_t vk_format, nv_vk_cached_image *entry, int *out_fd) {
	const uint32_t surface_width = (uint32_t)frame->surface_width;
	const uint32_t surface_height = (uint32_t)frame->surface_height;

	// plane 布局：offset/pitch 来自 vaExportSurfaceHandle，size 按 pitch x 高兜底
	// （显式 modifier 建 image 时实现只知道 offset 与 rowPitch 就够）。
	nvk_VkSubresourceLayout layouts[2];
	memset(layouts, 0, sizeof(layouts));
	layouts[0].offset = frame->offsets[0];
	layouts[0].rowPitch = frame->pitches[0];
	layouts[0].size = (nvk_VkDeviceSize)frame->pitches[0] * surface_height;
	layouts[1].offset = frame->offsets[1];
	layouts[1].rowPitch = frame->pitches[1];
	layouts[1].size = (nvk_VkDeviceSize)frame->pitches[1] * ((surface_height + 1) / 2);

	uint64_t modifier = frame->modifiers[0];
	if (modifier == NV_VK_DRM_FORMAT_MOD_INVALID) {
		// 导出方没给 modifier（隐式线性布局），按 LINEAR 处理
		modifier = NV_VK_DRM_FORMAT_MOD_LINEAR;
	}

	nvk_VkImageDrmFormatModifierExplicitCreateInfoEXT modifier_info;
	memset(&modifier_info, 0, sizeof(modifier_info));
	modifier_info.sType = NV_VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT;
	modifier_info.drmFormatModifier = modifier;
	modifier_info.drmFormatModifierPlaneCount = 2;
	modifier_info.pPlaneLayouts = layouts;

	const int linear = (modifier == NV_VK_DRM_FORMAT_MOD_LINEAR);

	nvk_VkExternalMemoryImageCreateInfo external_info;
	memset(&external_info, 0, sizeof(external_info));
	external_info.sType = NV_VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
	// A LINEAR dma-buf must use ordinary linear tiling; the DRM-format-modifier
	// explicit plane layout is only valid for tiled modifiers and some drivers
	// (e.g. the 芯动 XDX Vulkan driver) reject it with
	// VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT.
	external_info.pNext = linear ? NULL : &modifier_info;
	external_info.handleTypes = NV_VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;

	nvk_VkImageCreateInfo image_info;
	memset(&image_info, 0, sizeof(image_info));
	image_info.sType = NV_VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
	image_info.pNext = &external_info;
	image_info.imageType = NV_VK_IMAGE_TYPE_2D;
	image_info.format = vk_format;
	image_info.extent.width = surface_width;
	image_info.extent.height = surface_height;
	image_info.extent.depth = 1;
	image_info.mipLevels = 1;
	image_info.arrayLayers = 1;
	image_info.samples = NV_VK_SAMPLE_COUNT_1_BIT;
	image_info.tiling = linear ? NV_VK_IMAGE_TILING_LINEAR :
		NV_VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
	image_info.usage = NV_VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
	image_info.sharingMode = NV_VK_SHARING_MODE_EXCLUSIVE;
	image_info.initialLayout = NV_VK_IMAGE_LAYOUT_UNDEFINED;

	nvk_VkImage image = 0;
	nvk_VkResult result = imp->create_image(imp->device, &image_info, NULL, &image);
	if (result != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkCreateImage failed (%d) for %ux%u modifier 0x%llx linear=%d\n",
			(int)result, surface_width, surface_height,
			(unsigned long long)modifier, linear);
		return 0;
	}

	// 显存导入：同一块 dma-buf，只是换成 Vulkan 句柄。失败时 fd 仍归调用方。
	int fd = dup(frame->object_fds[0]);
	if (fd < 0) {
		fprintf(stderr, "[vk_import] dup dma-buf fd failed\n");
		imp->destroy_image(imp->device, image, NULL);
		return 0;
	}

	nvk_VkMemoryRequirements requirements;
	memset(&requirements, 0, sizeof(requirements));
	imp->get_image_memory_requirements(imp->device, image, &requirements);
	int memory_type = pick_memory_type(imp, requirements.memoryTypeBits);
	if (memory_type < 0) {
		fprintf(stderr, "[vk_import] no memory type for dma-buf import\n");
		close(fd);
		imp->destroy_image(imp->device, image, NULL);
		return 0;
	}

	nvk_VkMemoryDedicatedAllocateInfo dedicated;
	memset(&dedicated, 0, sizeof(dedicated));
	dedicated.sType = NV_VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
	dedicated.image = image;

	nvk_VkImportMemoryFdInfoKHR import_info;
	memset(&import_info, 0, sizeof(import_info));
	import_info.sType = NV_VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR;
	import_info.pNext = &dedicated;
	import_info.handleType = NV_VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
	import_info.fd = fd;

	nvk_VkMemoryAllocateInfo allocate_info;
	memset(&allocate_info, 0, sizeof(allocate_info));
	allocate_info.sType = NV_VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	allocate_info.pNext = &import_info;
	allocate_info.allocationSize = requirements.size;
	allocate_info.memoryTypeIndex = (uint32_t)memory_type;

	nvk_VkDeviceMemory memory = 0;
	result = imp->allocate_memory(imp->device, &allocate_info, NULL, &memory);
	if (result != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkAllocateMemory(import fd) failed (%d)\n", (int)result);
		close(fd);
		imp->destroy_image(imp->device, image, NULL);
		return 0;
	}
	// 到这里 fd 的所有权已经交给 Vulkan（vkFreeMemory 时由驱动关闭）。

	result = imp->bind_image_memory(imp->device, image, memory, 0);
	if (result != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkBindImageMemory failed (%d)\n", (int)result);
		imp->free_memory(imp->device, memory, NULL);
		imp->destroy_image(imp->device, image, NULL);
		return 0;
	}

	*out_fd = fd;
	entry->image = image;
	entry->memory = memory;
	return 1;
}

// =======================================================================
// 每帧：导入 + 拷贝进 Godot 纹理
// =======================================================================
nv_ffva_result nv_vk_import_frame(nv_vk_importer *imp, const nv_ffva_frame *frame,
		uint64_t luma_image, int luma_width, int luma_height,
		uint64_t chroma_image, int chroma_width, int chroma_height) {
	if (imp == NULL || frame == NULL || luma_image == 0 || chroma_image == 0) {
		return NV_FFVA_FAIL;
	}
	if (frame->plane_count < 2 || frame->object_count < 1) {
		fprintf(stderr, "[vk_import] frame has no usable dma-buf planes\n");
		return NV_FFVA_FAIL;
	}
	if (frame->plane_object[0] != frame->plane_object[1]) {
		// 两个平面在不同 dma-buf object 里（分层导出）：需要建两张单平面外部
		// image，暂未实现——先报错，不要偷偷拷错。
		fprintf(stderr, "[vk_import] luma/chroma live in different dma-buf objects; unsupported\n");
		return NV_FFVA_FAIL;
	}
	if (frame->surface_width < luma_width || frame->surface_height < luma_height) {
		fprintf(stderr, "[vk_import] surface %dx%d smaller than requested %dx%d\n",
			frame->surface_width, frame->surface_height, luma_width, luma_height);
		return NV_FFVA_FAIL;
	}
	if (chroma_width <= 0 || chroma_height <= 0 || luma_width <= 0 || luma_height <= 0) {
		return NV_FFVA_FAIL;
	}

	uint32_t vk_format = drm_format_to_vk_format(frame->drm_fourcc);
	if (vk_format == 0) {
		fprintf(stderr, "[vk_import] unsupported DRM fourcc 0x%08x\n", frame->drm_fourcc);
		return NV_FFVA_FAIL;
	}

	uint64_t dev = 0;
	uint64_t ino = 0;
	if (!dma_buf_identity(frame->object_fds[0], &dev, &ino)) {
		fprintf(stderr, "[vk_import] fstat(dma-buf) failed\n");
		return NV_FFVA_FAIL;
	}

	nv_vk_cached_image *entry = cache_lookup_or_evict(imp, dev, ino, frame, (int32_t)vk_format);
	if (entry->image == 0) {
		int fd = -1;
		if (!create_external_image(imp, frame, (int32_t)vk_format, entry, &fd)) {
			entry->used = 0;
			return NV_FFVA_FAIL;
		}
		entry->used = 1;
		entry->dev = dev;
		entry->ino = ino;
		entry->modifier = frame->modifiers[0];
		entry->surface_width = (uint32_t)frame->surface_width;
		entry->surface_height = (uint32_t)frame->surface_height;
		entry->vk_format = (int32_t)vk_format;
		entry->offsets[0] = frame->offsets[0];
		entry->offsets[1] = frame->offsets[1];
		entry->pitches[0] = frame->pitches[0];
		entry->pitches[1] = frame->pitches[1];
	}
	imp->frame_counter++;
	entry->last_used = imp->frame_counter;

	// ---- 录制 ----
	// 上一帧的 fence 可能还没被取走：先等它，再复用命令缓冲。
	if (imp->fence_pending) {
		nvk_VkResult waited = imp->wait_for_fences(imp->device, 1, &imp->fence, NV_VK_TRUE,
			2000000000ull);
		if (waited != NV_VK_SUCCESS) {
			fprintf(stderr, "[vk_import] previous submit not finished (%d); waiting on queue\n",
				(int)waited);
			imp->queue_wait_idle(imp->queue);
		}
		imp->fence_pending = 0;
	}
	imp->reset_fences(imp->device, 1, &imp->fence);
	imp->reset_command_buffer(imp->command_buffer, 0);

	nvk_VkCommandBufferBeginInfo begin_info;
	memset(&begin_info, 0, sizeof(begin_info));
	begin_info.sType = NV_VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
	if (imp->begin_command_buffer(imp->command_buffer, &begin_info) != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkBeginCommandBuffer failed\n");
		return NV_FFVA_FAIL;
	}

	const int src_crop_x = frame->crop_x > 0 ? frame->crop_x : 0;
	const int src_crop_y = frame->crop_y > 0 ? frame->crop_y : 0;

	// 源 image：UNDEFINED -> TRANSFER_SRC（内容由 dma-buf 提供，不复用旧布局）
	nvk_VkImageMemoryBarrier src_barrier;
	memset(&src_barrier, 0, sizeof(src_barrier));
	src_barrier.sType = NV_VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
	src_barrier.srcAccessMask = 0;
	src_barrier.dstAccessMask = NV_VK_ACCESS_TRANSFER_READ_BIT;
	src_barrier.oldLayout = NV_VK_IMAGE_LAYOUT_UNDEFINED;
	src_barrier.newLayout = NV_VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	src_barrier.srcQueueFamilyIndex = imp->queue_family_index;
	src_barrier.dstQueueFamilyIndex = imp->queue_family_index;
	src_barrier.image = entry->image;
	src_barrier.subresourceRange.aspectMask =
		NV_VK_IMAGE_ASPECT_PLANE_0_BIT | NV_VK_IMAGE_ASPECT_PLANE_1_BIT;
	src_barrier.subresourceRange.levelCount = 1;
	src_barrier.subresourceRange.layerCount = 1;
	imp->cmd_pipeline_barrier(imp->command_buffer,
		NV_VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, NV_VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
		0, NULL, 0, NULL, 1, &src_barrier);

	// 目标纹理：Godot 建的时候是 UNDEFINED，这里转到 TRANSFER_DST 再拷
	nvk_VkImageMemoryBarrier dst_barriers[2];
	memset(dst_barriers, 0, sizeof(dst_barriers));
	const uint64_t dst_images[2] = { luma_image, chroma_image };
	for (int i = 0; i < 2; i++) {
		dst_barriers[i].sType = NV_VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
		dst_barriers[i].srcAccessMask = 0;
		dst_barriers[i].dstAccessMask = NV_VK_ACCESS_TRANSFER_WRITE_BIT;
		dst_barriers[i].oldLayout = NV_VK_IMAGE_LAYOUT_UNDEFINED;
		dst_barriers[i].newLayout = NV_VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		dst_barriers[i].srcQueueFamilyIndex = imp->queue_family_index;
		dst_barriers[i].dstQueueFamilyIndex = imp->queue_family_index;
		dst_barriers[i].image = dst_images[i];
		dst_barriers[i].subresourceRange.aspectMask = NV_VK_IMAGE_ASPECT_COLOR_BIT;
		dst_barriers[i].subresourceRange.levelCount = 1;
		dst_barriers[i].subresourceRange.layerCount = 1;
	}
	imp->cmd_pipeline_barrier(imp->command_buffer,
		NV_VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, NV_VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
		0, NULL, 0, NULL, 2, dst_barriers);

	// 两次拷贝（plane0→luma、plane1→chroma），源用 surface 坐标并裁到显示尺寸
	nvk_VkImageCopy copies[2];
	memset(copies, 0, sizeof(copies));
	copies[0].srcSubresource.aspectMask = NV_VK_IMAGE_ASPECT_PLANE_0_BIT;
	copies[0].srcOffset.x = src_crop_x;
	copies[0].srcOffset.y = src_crop_y;
	copies[0].dstSubresource.aspectMask = NV_VK_IMAGE_ASPECT_COLOR_BIT;
	copies[0].extent.width = (uint32_t)luma_width;
	copies[0].extent.height = (uint32_t)luma_height;
	copies[0].extent.depth = 1;
	copies[1].srcSubresource.aspectMask = NV_VK_IMAGE_ASPECT_PLANE_1_BIT;
	copies[1].srcOffset.x = src_crop_x / 2;
	copies[1].srcOffset.y = src_crop_y / 2;
	copies[1].dstSubresource.aspectMask = NV_VK_IMAGE_ASPECT_COLOR_BIT;
	copies[1].extent.width = (uint32_t)chroma_width;
	copies[1].extent.height = (uint32_t)chroma_height;
	copies[1].extent.depth = 1;
	imp->cmd_copy_image(imp->command_buffer, entry->image,
		NV_VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, (nvk_VkImage)luma_image,
		NV_VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copies[0]);
	imp->cmd_copy_image(imp->command_buffer, entry->image,
		NV_VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, (nvk_VkImage)chroma_image,
		NV_VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copies[1]);

	// 目标纹理交给 Godot 采样：TRANSFER_DST -> SHADER_READ_ONLY。
	// （Godot 只知道自己建纹理时的布局，不会替我们做这次转换。）
	for (int i = 0; i < 2; i++) {
		dst_barriers[i].srcAccessMask = NV_VK_ACCESS_TRANSFER_WRITE_BIT;
		dst_barriers[i].dstAccessMask = NV_VK_ACCESS_SHADER_READ_BIT;
		dst_barriers[i].oldLayout = NV_VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
		dst_barriers[i].newLayout = NV_VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
	}
	imp->cmd_pipeline_barrier(imp->command_buffer,
		NV_VK_PIPELINE_STAGE_TRANSFER_BIT, NV_VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0,
		0, NULL, 0, NULL, 2, dst_barriers);

	if (imp->end_command_buffer(imp->command_buffer) != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkEndCommandBuffer failed\n");
		return NV_FFVA_FAIL;
	}

	nvk_VkSubmitInfo submit_info;
	memset(&submit_info, 0, sizeof(submit_info));
	submit_info.sType = NV_VK_STRUCTURE_TYPE_SUBMIT_INFO;
	submit_info.commandBufferCount = 1;
	submit_info.pCommandBuffers = &imp->command_buffer;

	nvk_VkResult result = imp->queue_submit(imp->queue, 1, &submit_info, imp->fence);
	if (result != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkQueueSubmit failed (%d)\n", (int)result);
		return NV_FFVA_FAIL;
	}
	imp->fence_pending = 1;

	// 返回前等 GPU 做完：调用方马上就会让 Godot 采样这两张纹理。
	result = imp->wait_for_fences(imp->device, 1, &imp->fence, NV_VK_TRUE, 2000000000ull);
	if (result != NV_VK_SUCCESS) {
		fprintf(stderr, "[vk_import] vkWaitForFences failed/timeout (%d)\n", (int)result);
		imp->queue_wait_idle(imp->queue);
	}
	imp->fence_pending = 0;
	return NV_FFVA_OK;
}

// =======================================================================
// ABI 校验（可选）：本机有 vulkan 头文件时用来静态核对上面的结构体/常量。
//   zig cc -DNV_VK_IMPORT_ABI_CHECK -DNV_VK_IMPORT_ABI_CHECK_ONLY -c vk_import_shim.c
// 不进构建产物；只在开发机上跑。
// =======================================================================
#ifdef NV_VK_IMPORT_ABI_CHECK
#include <vulkan/vulkan_core.h>

#define NVK_STATIC_ASSERT(cond, tag) _Static_assert((cond), #tag)

NVK_STATIC_ASSERT(sizeof(nvk_VkImageSubresource) == sizeof(VkImageSubresource), image_subresource_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkImageSubresourceLayers) == sizeof(VkImageSubresourceLayers), subresource_layers_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkOffset3D) == sizeof(VkOffset3D), offset3d_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkExtent3D) == sizeof(VkExtent3D), extent3d_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkImageSubresourceRange) == sizeof(VkImageSubresourceRange), range_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkSubresourceLayout) == sizeof(VkSubresourceLayout), subresource_layout_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkImageCreateInfo) == sizeof(VkImageCreateInfo), image_create_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkExternalMemoryImageCreateInfo) == sizeof(VkExternalMemoryImageCreateInfo), external_image_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkImageDrmFormatModifierExplicitCreateInfoEXT) ==
		sizeof(VkImageDrmFormatModifierExplicitCreateInfoEXT), drm_modifier_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkMemoryRequirements) == sizeof(VkMemoryRequirements), memory_requirements_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkMemoryAllocateInfo) == sizeof(VkMemoryAllocateInfo), memory_allocate_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkMemoryDedicatedAllocateInfo) == sizeof(VkMemoryDedicatedAllocateInfo), dedicated_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkImportMemoryFdInfoKHR) == sizeof(VkImportMemoryFdInfoKHR), import_fd_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkImageMemoryBarrier) == sizeof(VkImageMemoryBarrier), image_barrier_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkImageCopy) == sizeof(VkImageCopy), image_copy_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkCommandPoolCreateInfo) == sizeof(VkCommandPoolCreateInfo), pool_info_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkCommandBufferAllocateInfo) == sizeof(VkCommandBufferAllocateInfo), buffer_info_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkCommandBufferBeginInfo) == sizeof(VkCommandBufferBeginInfo), begin_info_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkFenceCreateInfo) == sizeof(VkFenceCreateInfo), fence_info_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkSubmitInfo) == sizeof(VkSubmitInfo), submit_info_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkPhysicalDeviceMemoryProperties) == sizeof(VkPhysicalDeviceMemoryProperties), mem_props_size);
NVK_STATIC_ASSERT(sizeof(nvk_VkQueueFamilyProperties) == sizeof(VkQueueFamilyProperties), queue_family_size);

NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_SUBMIT_INFO == VK_STRUCTURE_TYPE_SUBMIT_INFO, st_submit);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO == VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, st_alloc);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_FENCE_CREATE_INFO == VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, st_fence);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO == VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, st_image);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO == VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, st_pool);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO == VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, st_cb_alloc);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO == VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, st_cb_begin);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER == VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, st_barrier);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO == VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, st_dedicated);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO == VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, st_external);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR == VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, st_import_fd);
NVK_STATIC_ASSERT(NV_VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT ==
		VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT, st_drm_modifier);

NVK_STATIC_ASSERT(NV_VK_FORMAT_R8_UNORM == VK_FORMAT_R8_UNORM, fmt_r8);
NVK_STATIC_ASSERT(NV_VK_FORMAT_R8G8_UNORM == VK_FORMAT_R8G8_UNORM, fmt_r8g8);
NVK_STATIC_ASSERT(NV_VK_FORMAT_R16_UNORM == VK_FORMAT_R16_UNORM, fmt_r16);
NVK_STATIC_ASSERT(NV_VK_FORMAT_R16G16_UNORM == VK_FORMAT_R16G16_UNORM, fmt_r16g16);
NVK_STATIC_ASSERT(NV_VK_FORMAT_G8_B8R8_2PLANE_420_UNORM == VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, fmt_nv12);
NVK_STATIC_ASSERT(NV_VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 ==
		VK_FORMAT_G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16, fmt_p010);

NVK_STATIC_ASSERT(NV_VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT == VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, tiling_drm);
NVK_STATIC_ASSERT(NV_VK_SAMPLE_COUNT_1_BIT == VK_SAMPLE_COUNT_1_BIT, samples_1);
NVK_STATIC_ASSERT(NV_VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, layout_src);
NVK_STATIC_ASSERT(NV_VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, layout_dst);
NVK_STATIC_ASSERT(NV_VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, layout_shader);
NVK_STATIC_ASSERT(NV_VK_IMAGE_ASPECT_PLANE_0_BIT == VK_IMAGE_ASPECT_PLANE_0_BIT, aspect_p0);
NVK_STATIC_ASSERT(NV_VK_IMAGE_ASPECT_PLANE_1_BIT == VK_IMAGE_ASPECT_PLANE_1_BIT, aspect_p1);
NVK_STATIC_ASSERT(NV_VK_IMAGE_USAGE_TRANSFER_SRC_BIT == VK_IMAGE_USAGE_TRANSFER_SRC_BIT, usage_src);
NVK_STATIC_ASSERT(NV_VK_PIPELINE_STAGE_ALL_COMMANDS_BIT == VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, stage_all);
NVK_STATIC_ASSERT(NV_VK_ACCESS_SHADER_READ_BIT == VK_ACCESS_SHADER_READ_BIT, access_shader_read);
NVK_STATIC_ASSERT(NV_VK_ACCESS_TRANSFER_READ_BIT == VK_ACCESS_TRANSFER_READ_BIT, access_transfer_read);
NVK_STATIC_ASSERT(NV_VK_ACCESS_TRANSFER_WRITE_BIT == VK_ACCESS_TRANSFER_WRITE_BIT, access_transfer_write);
NVK_STATIC_ASSERT(NV_VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT == VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, handle_dmabuf);
NVK_STATIC_ASSERT(NV_VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT == VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, mem_device_local);
NVK_STATIC_ASSERT(NV_VK_QUEUE_GRAPHICS_BIT == VK_QUEUE_GRAPHICS_BIT, queue_graphics);
NVK_STATIC_ASSERT(NV_VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT == VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, pool_reset);
// NV_VK_DRM_FORMAT_MOD_LINEAR / INVALID 是 DRM 侧的常量（drm_fourcc.h），
// Vulkan 头文件里没有对应符号，所以这里只钉住数值本身：
NVK_STATIC_ASSERT(NV_VK_DRM_FORMAT_MOD_LINEAR == 0ull, mod_linear_is_zero);
NVK_STATIC_ASSERT(NV_VK_SUCCESS == VK_SUCCESS, result_success);
NVK_STATIC_ASSERT(NV_VK_TIMEOUT == VK_TIMEOUT, result_timeout);
NVK_STATIC_ASSERT(NV_VK_TRUE == VK_TRUE, bool_true);
NVK_STATIC_ASSERT(NV_VK_IMAGE_TYPE_2D == VK_IMAGE_TYPE_2D, image_type_2d);
NVK_STATIC_ASSERT(NV_VK_SHARING_MODE_EXCLUSIVE == VK_SHARING_MODE_EXCLUSIVE, exclusive);
NVK_STATIC_ASSERT(NV_VK_IMAGE_TILING_LINEAR == VK_IMAGE_TILING_LINEAR, tiling_linear);
NVK_STATIC_ASSERT(NV_VK_IMAGE_LAYOUT_UNDEFINED == VK_IMAGE_LAYOUT_UNDEFINED, layout_undefined);
NVK_STATIC_ASSERT(NV_VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT == VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, stage_top);
NVK_STATIC_ASSERT(NV_VK_PIPELINE_STAGE_TRANSFER_BIT == VK_PIPELINE_STAGE_TRANSFER_BIT, stage_transfer);
NVK_STATIC_ASSERT(NV_VK_COMMAND_BUFFER_LEVEL_PRIMARY == VK_COMMAND_BUFFER_LEVEL_PRIMARY, cb_primary);
#endif // NV_VK_IMPORT_ABI_CHECK
