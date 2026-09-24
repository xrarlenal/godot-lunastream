//! vulkan_layer_setup.zig — 在引擎建 VkInstance 之前挂上自带的 Vulkan Layer。
//!
//! Linux 的零拷贝导入需要 Godot 的 Vulkan 设备启用 dma-buf 外部内存扩展
//! （VK_KHR_external_memory_fd / VK_EXT_external_memory_dma_buf /
//! VK_EXT_image_drm_format_modifier），而这些扩展只能在 vkCreateDevice 时启用。
//! Godot 没有提供开关，所以随扩展带一个 Vulkan Layer
//! （src/vulkan_layer/luna_ext_layer.c），它拦截 vkCreateDevice 把这些扩展加进去。
//!
//! Layer 必须在 loader 建 instance 之前被"看见"：本模块在 GDExtension 的 CORE
//! 初始化级别（servers/RenderingDevice 之前）设置
//!   1. VK_LAYER_PATH 指向 <扩展目录>/luna_layer（清单 + .so 就放那里）
//!   2. VK_INSTANCE_LAYERS 里加上 VK_LAYER_LUNA_external_memory——VK_LAYER_PATH
//!      里的 layer 属于"显式 layer"，只有被点名才会启用（清单里的
//!      enable_environment 只对 implicit layer 目录生效，所以这里两条都设，
//!      用户把清单拷到 /usr/share/vulkan/implicit_layer.d 时也能自动生效）
//! 找不到自带 layer 时只打日志、不做任何事：没有硬解导入路径时引擎照常启动。
//! 注意：显式 layer 装不上（.so 架构不对/依赖缺失）会让 vkCreateInstance 直接
//! 失败，所以这里先确认清单和 .so 都在，再往环境变量里写。
//!
//! 备选（部署时不想让扩展改环境变量）：启动 Godot 前自己导出
//!   VK_LAYER_PATH=<addons/native_video/luna_layer>
//!   LUNA_EXTERNAL_MEMORY_LAYER=1

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.native_video_vk_layer);

const DlInfo = extern struct {
    dli_fname: ?[*:0]const u8 = null,
    dli_fbase: ?*anyopaque = null,
    dli_sname: ?[*:0]const u8 = null,
    dli_saddr: ?*anyopaque = null,
};

extern fn dladdr(addr: ?*const anyopaque, info: *DlInfo) c_int;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn access(path: [*:0]const u8, mode: c_int) c_int;

/// Directory holding this shared object, or null when dladdr cannot say.
fn extensionDir(buf: []u8) ?[]const u8 {
    var info: DlInfo = .{};
    if (dladdr(@ptrCast(&extensionDir), &info) == 0) return null;
    const name_ptr = info.dli_fname orelse return null;
    const name = std.mem.span(name_ptr);
    // Absolute paths only: a bare soname cannot be resolved to a directory.
    if (name.len == 0 or name[0] != '/') return null;
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return null;
    if (slash >= buf.len) return null;
    @memcpy(buf[0..slash], name[0..slash]);
    return buf[0..slash];
}

/// Prepend `dir` to a colon-separated path list in `name` (creating it when
/// unset), keeping whatever the environment already had.
fn prependPath(name: [*:0]const u8, dir: []const u8) bool {
    var buf: [8 * 1024]u8 = undefined;
    const existing = if (getenv(name)) |v| std.mem.span(v) else "";
    const value = if (existing.len == 0)
        std.fmt.bufPrintZ(&buf, "{s}", .{dir}) catch return false
    else
        std.fmt.bufPrintZ(&buf, "{s}:{s}", .{ dir, existing }) catch return false;
    return setenv(name, value.ptr, 1) == 0;
}

/// True when the colon-separated list in `name` already contains `item`.
fn pathListHas(name: [*:0]const u8, item: []const u8) bool {
    const existing = if (getenv(name)) |v| std.mem.span(v) else return false;
    var it = std.mem.splitScalar(u8, existing, ':');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}

const layer_name = "VK_LAYER_LUNA_external_memory";
const layer_lib = "libluna_ext_layer.so";

/// Called once at CORE initialization level (before the engine creates its
/// Vulkan instance). No-op off Linux or when the bundled layer is absent.
pub fn enableBundledLayer() void {
    if (comptime builtin.os.tag != .linux) return;

    var dir_buf: [4096]u8 = undefined;
    const dir = extensionDir(&dir_buf) orelse {
        log.warn("cannot locate this extension's directory; dma-buf layer not enabled.", .{});
        return;
    };

    var manifest_buf: [4200]u8 = undefined;
    const manifest = std.fmt.bufPrintZ(&manifest_buf, "{s}/luna_layer/luna_ext_layer.json", .{dir}) catch return;
    // F_OK (0) — plain existence check, via libc so this module needs no Io
    // instance (std.fs.cwd() is gone in Zig 0.16's std).
    if (access(manifest.ptr, 0) != 0) {
        log.info("bundled Vulkan layer not installed ({s} missing); " ++
            "hardware-decode import will be unavailable until it is.", .{manifest});
        return;
    }

    var layer_dir_buf: [4200]u8 = undefined;
    const layer_dir = std.fmt.bufPrint(&layer_dir_buf, "{s}/luna_layer", .{dir}) catch return;
    var lib_buf: [4260]u8 = undefined;
    const lib_path = std.fmt.bufPrintZ(&lib_buf, "{s}/{s}", .{ layer_dir, layer_lib }) catch return;
    if (access(lib_path.ptr, 0) != 0) {
        log.info("bundled Vulkan layer is missing {s}; hardware-decode import unavailable.", .{lib_path});
        return;
    }

    if (!prependPath("VK_LAYER_PATH", layer_dir)) {
        log.err("setting VK_LAYER_PATH failed; dma-buf layer not enabled.", .{});
        return;
    }
    // Explicit layers found via VK_LAYER_PATH only load when named here.
    if (!pathListHas("VK_INSTANCE_LAYERS", layer_name) and
        !prependPath("VK_INSTANCE_LAYERS", layer_name))
    {
        log.err("setting VK_INSTANCE_LAYERS failed; dma-buf layer not enabled.", .{});
        return;
    }
    // Matches enable_environment in luna_ext_layer.json, for deployments that
    // copy the manifest into the loader's implicit-layer directory instead.
    _ = setenv("LUNA_EXTERNAL_MEMORY_LAYER", "1", 1);
    log.info("Vulkan dma-buf layer enabled from {s}.", .{layer_dir});
}
