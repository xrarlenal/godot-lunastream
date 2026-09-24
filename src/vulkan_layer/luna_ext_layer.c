// -----------------------------------------------------------------------
// luna_ext_layer.c — Vulkan Layer：为 Godot 的 Vulkan 设备注入外部内存扩展。
//
// Godot 创建设备时不会启用 dma-buf 外部内存扩展，也没有 API 可以请求，
// 导致 Linux 上无法把 VAAPI 解码的显存表面导入 Godot 的 RenderingDevice。
// 本 layer 按 Vulkan-Loader 的标准 layer 接口实现，在 vkCreateDevice 的链式
// 回调里把这些扩展加入 enabledExtensionNames。
//
// 关键实现点（对齐 loader 自带的 test_layer）：
//   * instance/device 的创建链都用 VkLayerInstanceCreateInfo /
//     VkLayerDeviceCreateInfo + VK_LAYER_LINK_INFO 取下一层的
//     pfnNextGetInstanceProcAddr / pfnNextGetDeviceProcAddr，并先把链指针
//     前移再调用下一层，避免递归；
//   * 创建成功后用 loader 生成的 layer_init_instance_dispatch_table /
//     layer_init_device_dispatch_table 建立我们自己的 dispatch table；
//   * GetInstanceProcAddr / GetDeviceProcAddr 只拦截自己包装的函数，其余
//     转发给下一层（用从链里拿到的 next 指针，而不是再 dlopen loader）。
//
// 启用方式（显式 layer）：
//   VK_LAYER_PATH=<包含 luna_ext_layer.json 的目录>
//   VK_INSTANCE_LAYERS=VK_LAYER_LUNA_external_memory
// 扩展的 CORE 级回调（vulkan_layer_setup.zig）会自动设置这两个环境变量。
// -----------------------------------------------------------------------
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vk_dispatch_table_helper.h"

#define LUNA_LAYER_NAME "VK_LAYER_LUNA_external_memory"

static const char *kRequiredExtensions[] = {
	"VK_KHR_external_memory",
	"VK_KHR_external_memory_fd",
	"VK_EXT_external_memory_dma_buf",
	"VK_EXT_image_drm_format_modifier",
	"VK_EXT_queue_family_foreign",
};
static const size_t kRequiredExtensionCount =
	sizeof(kRequiredExtensions) / sizeof(kRequiredExtensions[0]);

static VkLayerInstanceDispatchTable g_instance_dispatch;
static VkLayerDispatchTable g_device_dispatch;
static PFN_vkGetInstanceProcAddr g_next_gipa = NULL;
static PFN_vkGetDeviceProcAddr g_next_gdpa = NULL;
static VkInstance g_instance = VK_NULL_HANDLE;
static int g_logged_device = 0;

static VkLayerInstanceCreateInfo *instance_chain(
		const VkInstanceCreateInfo *create_info, VkLayerFunction function) {
	VkLayerInstanceCreateInfo *info =
		(VkLayerInstanceCreateInfo *)create_info->pNext;
	while (info != NULL) {
		if (info->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
				info->function == function) {
			return info;
		}
		info = (VkLayerInstanceCreateInfo *)info->pNext;
	}
	return NULL;
}

static VkLayerDeviceCreateInfo *device_chain(
		const VkDeviceCreateInfo *create_info, VkLayerFunction function) {
	VkLayerDeviceCreateInfo *info =
		(VkLayerDeviceCreateInfo *)create_info->pNext;
	while (info != NULL) {
		if (info->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
				info->function == function) {
			return info;
		}
		info = (VkLayerDeviceCreateInfo *)info->pNext;
	}
	return NULL;
}

static int already_enabled(const VkDeviceCreateInfo *info, const char *name) {
	for (uint32_t i = 0; i < info->enabledExtensionCount; i++) {
		if (info->ppEnabledExtensionNames[i] != NULL &&
				strcmp(info->ppEnabledExtensionNames[i], name) == 0) {
			return 1;
		}
	}
	return 0;
}

static int device_supports(VkPhysicalDevice physical_device, const char *name) {
	if (g_instance_dispatch.EnumerateDeviceExtensionProperties == NULL) {
		return 0;
	}
	uint32_t count = 0;
	if (g_instance_dispatch.EnumerateDeviceExtensionProperties(
			physical_device, NULL, &count, NULL) != VK_SUCCESS || count == 0) {
		return 0;
	}
	VkExtensionProperties *props =
		(VkExtensionProperties *)malloc(sizeof(VkExtensionProperties) * count);
	if (props == NULL) {
		return 0;
	}
	int found = 0;
	if (g_instance_dispatch.EnumerateDeviceExtensionProperties(
			physical_device, NULL, &count, props) == VK_SUCCESS) {
		for (uint32_t i = 0; i < count; i++) {
			if (strcmp(props[i].extensionName, name) == 0) {
				found = 1;
				break;
			}
		}
	}
	free(props);
	return found;
}

// -----------------------------------------------------------------------
// 拦截入口
// -----------------------------------------------------------------------
static VKAPI_ATTR VkResult VKAPI_CALL luna_CreateInstance(
		const VkInstanceCreateInfo *create_info,
		const VkAllocationCallbacks *allocator,
		VkInstance *instance_out) {
	VkLayerInstanceCreateInfo *chain =
		instance_chain(create_info, VK_LAYER_LINK_INFO);
	if (chain == NULL || chain->u.pLayerInfo == NULL) {
		fprintf(stderr, "[%s] missing instance chain info\n", LUNA_LAYER_NAME);
		return VK_ERROR_INITIALIZATION_FAILED;
	}
	PFN_vkGetInstanceProcAddr next_gipa =
		chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
	// Advance the chain before calling down, so the loader does not call us
	// again for this creation.
	chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;

	PFN_vkCreateInstance next_create_instance =
		(PFN_vkCreateInstance)next_gipa(NULL, "vkCreateInstance");
	if (next_create_instance == NULL) {
		return VK_ERROR_INITIALIZATION_FAILED;
	}
	VkResult result = next_create_instance(create_info, allocator, instance_out);
	if (result == VK_SUCCESS) {
		g_instance = *instance_out;
		g_next_gipa = next_gipa;
		layer_init_instance_dispatch_table(*instance_out, &g_instance_dispatch,
			next_gipa);
		fprintf(stderr, "[%s] instance created\n", LUNA_LAYER_NAME);
	}
	return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL luna_CreateDevice(
		VkPhysicalDevice physical_device,
		const VkDeviceCreateInfo *create_info,
		const VkAllocationCallbacks *allocator,
		VkDevice *device_out) {
	VkLayerDeviceCreateInfo *chain =
		device_chain(create_info, VK_LAYER_LINK_INFO);
	if (chain == NULL || chain->u.pLayerInfo == NULL) {
		fprintf(stderr, "[%s] missing device chain info\n", LUNA_LAYER_NAME);
		return VK_ERROR_INITIALIZATION_FAILED;
	}
	PFN_vkGetInstanceProcAddr next_gipa =
		chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
	PFN_vkGetDeviceProcAddr next_gdpa =
		chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
	chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;

	PFN_vkCreateDevice next_create_device =
		(PFN_vkCreateDevice)next_gipa(g_instance, "vkCreateDevice");
	if (next_create_device == NULL || create_info == NULL) {
		return VK_ERROR_INITIALIZATION_FAILED;
	}

	// 调试开关：LUNA_EXT_LIMIT=N 只加前 N 个扩展，便于在目标机上二分定位。
	size_t limit = kRequiredExtensionCount;
	const char *limit_env = getenv("LUNA_EXT_LIMIT");
	if (limit_env != NULL) {
		int v = atoi(limit_env);
		if (v >= 0 && (size_t)v <= kRequiredExtensionCount) {
			limit = (size_t)v;
		}
	}

	const char *to_add[kRequiredExtensionCount];
	uint32_t add_count = 0;
	for (size_t i = 0; i < limit; i++) {
		const char *name = kRequiredExtensions[i];
		if (!already_enabled(create_info, name) &&
				device_supports(physical_device, name)) {
			to_add[add_count++] = name;
		}
	}

	const char **names = NULL;
	VkDeviceCreateInfo modified = *create_info;
	if (add_count > 0) {
		uint32_t total = create_info->enabledExtensionCount + add_count;
		names = (const char **)malloc(sizeof(const char *) * total);
		if (names == NULL) {
			return next_create_device(physical_device, create_info, allocator,
				device_out);
		}
		uint32_t n = 0;
		for (uint32_t i = 0; i < create_info->enabledExtensionCount; i++) {
			names[n++] = create_info->ppEnabledExtensionNames[i];
		}
		for (uint32_t i = 0; i < add_count; i++) {
			fprintf(stderr, "[%s] enabling %s\n", LUNA_LAYER_NAME, to_add[i]);
			names[n++] = to_add[i];
		}
		modified.enabledExtensionCount = n;
		modified.ppEnabledExtensionNames = names;
	}

	VkResult result = next_create_device(physical_device, &modified, allocator,
		device_out);
	free(names);

	if (result == VK_SUCCESS) {
		g_next_gdpa = next_gdpa;
		layer_init_device_dispatch_table(*device_out, &g_device_dispatch,
			next_gdpa);
		if (!g_logged_device) {
			g_logged_device = 1;
			fprintf(stderr,
				"[%s] device created with external memory extensions\n",
				LUNA_LAYER_NAME);
		}
	} else {
		fprintf(stderr, "[%s] device creation failed (%d)\n", LUNA_LAYER_NAME,
			(int)result);
	}
	return result;
}

// -----------------------------------------------------------------------
// Layer 接口分发
// -----------------------------------------------------------------------
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL luna_GetDeviceProcAddr(
		VkDevice device, const char *name) {
	if (name == NULL) {
		return NULL;
	}
	if (strcmp(name, "vkGetDeviceProcAddr") == 0) {
		return (PFN_vkVoidFunction)luna_GetDeviceProcAddr;
	}
	if (g_next_gdpa != NULL) {
		return g_next_gdpa(device, name);
	}
	return NULL;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL luna_GetInstanceProcAddr(
		VkInstance instance, const char *name) {
	if (name == NULL) {
		return NULL;
	}
	if (strcmp(name, "vkCreateInstance") == 0) {
		return (PFN_vkVoidFunction)luna_CreateInstance;
	}
	if (strcmp(name, "vkCreateDevice") == 0) {
		return (PFN_vkVoidFunction)luna_CreateDevice;
	}
	if (strcmp(name, "vkGetInstanceProcAddr") == 0) {
		return (PFN_vkVoidFunction)luna_GetInstanceProcAddr;
	}
	if (strcmp(name, "vkGetDeviceProcAddr") == 0) {
		return (PFN_vkVoidFunction)luna_GetDeviceProcAddr;
	}
	if (g_next_gipa != NULL) {
		return g_next_gipa(instance, name);
	}
	return NULL;
}

VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(
		VkNegotiateLayerInterface *interface_struct) {
	if (interface_struct == NULL ||
			interface_struct->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) {
		return VK_ERROR_INITIALIZATION_FAILED;
	}
	if (interface_struct->loaderLayerInterfaceVersion >= 2) {
		interface_struct->loaderLayerInterfaceVersion = 2;
		interface_struct->pfnGetInstanceProcAddr = luna_GetInstanceProcAddr;
		interface_struct->pfnGetDeviceProcAddr = luna_GetDeviceProcAddr;
		interface_struct->pfnGetPhysicalDeviceProcAddr = NULL;
	}
	fprintf(stderr, "[%s] layer negotiated\n", LUNA_LAYER_NAME);
	return VK_SUCCESS;
}
