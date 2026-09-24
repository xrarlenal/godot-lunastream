# 平台导入器的移植说明（0016 / 0017）

> 状态：**代码已搬入，接缝适配与目标平台交叉编译待做。**

## 为什么是"搬"而不是"重写"

SKILL.md 第八条写的是"源工程的代码是复刻参考，不是直接搬运的对象：逐功能点重写、
重新验证"。**这一条在 Windows / Linux 两步上被项目所有者明确放宽**：这两条路径已在
源工程（`VideoAnd3DSceneFusion/third_party/native_video`）的真机上验证过，重写一遍
只会引入新风险而不会带来新证据，因此按"移植 + 只改接缝 + 目标平台交叉编译"处理。

macOS 那两步（0013 CPU 导入器、0015 Metal 导入器）**没有**放宽：它们仍然是在本仓库
里逐个功能点重写、逐个验证的，理由也一样——本机能验证，就没有理由不复刻。

## 搬进来的是什么

全部来自 `VideoAnd3DSceneFusion/third_party/native_video`（只读，未做任何写入）。

| 本仓库路径 | 源工程路径 | 用途 |
|---|---|---|
| `src/godot/d3d12_surface_importer.zig` | 同名 | Windows D3D12 零拷贝：D3D11 解码纹理 → 共享 NT 句柄 + 共享 fence → Godot 的 D3D12 设备 |
| `src/godot/windows_surface_importer.zig` | 同名 | Windows 侧包装：跨适配器失败时降到 CPU 拷贝（并把降级如实上报） |
| `src/godot/windows_import_common.zig` | 同名 | Windows 两份导入器共用的部分 |
| `src/godot/cpu_copy_surface_importer.zig` | 同名 | CPU 读回回退路径（Windows + Vulkan 驱动时用） |
| `src/godot/vulkan_surface_importer.zig` | 同名 | Linux Vulkan：dma-buf → Godot 的 VkDevice |
| `src/godot/vulkan_layer_setup.zig` | 同名 | 运行时找随包 Layer 并设置 `VK_LAYER_PATH` / `VK_INSTANCE_LAYERS` |
| `src/ffva/vk_import_shim.c` / `.h` | 同名 | dma-buf → VkImage 的导入 shim（不链 libvulkan，自己解析 loader） |
| `src/vulkan_layer/luna_ext_layer.c` / `.json` | 同名 | 自研 Vulkan Layer：在 `vkCreateDevice` 链上注入 dma-buf 设备扩展 |
| `src/vulkan_layer/vk_dispatch_table_helper.h` / `vk_layer_dispatch_table.h` | 同名 | Layer 需要的生成式分发表 |
| `src/godot/surface_importer.reference.zig` | `surface_importer.zig` | **参考用**：源工程的导入接口形状（不参与编译） |
| `src/godot/present_pipeline.reference.zig` | `present_pipeline.zig` | **参考用**：源工程的呈现管线（不参与编译） |

带 `.reference` 后缀的两份是刻意不改名的：它们既不是本仓库的接口（0014 已经定了自己的
`surface_importer.SurfaceImporter`），也不是本仓库的实现，放在旁边只为对照——**它们
不参与编译**，文件名里也写明了这一点。

## 要做哪些接缝适配（下一步的具体工作）

1. **接口对齐**。源工程的导入器实现的是它的 `si.ImportResult`；本仓库 0014 定的是
   `Surface { spec, planes, release_hook }` + `Error`。适配点是每个导入器的
   `import()` 返回处与 `deinit()`，不涉及内部算法。
2. **选择器合并**。源工程有 `importer_selector.zig`；本仓库 0014 已有
   `dispatching_surface_importer.zig`。把平台导入器挂进后者，不再引入第二个选择器。
3. **构建接线**（源工程 `build.zig` 第 77/240–283/398–460 行是参照）：
   - Windows：编译上面的 Windows 源 + 链 `dxgi` / `d3d12` / `ole32` / `d3dcompiler_47`；
   - Linux：编译 `ffva` 的 vk shim，另出一个 `luna_ext_layer` 动态库 + `luna_ext_layer.json`，
     并给扩展加 `$ORIGIN/libs/linux64` 的 rpath；
   - 两者都要保证**其它平台不编译这些文件**。
4. **交叉编译检查**（本机可做的部分）：
   `zig build -Dtarget=x86_64-windows-gnu` 与 `-Dtarget=x86_64-linux-gnu`，至少在
   macOS 上把 Zig 侧与 C 侧编过一遍（Zig 自带 mingw-w64 头，Windows 侧可用；
   Linux 侧的 VAAPI/Vulkan 头是否齐备要实测）。

## 验证状态（必须说清楚）

| 事项 | 状态 |
|---|---|
| 源工程里的 Windows / Linux 实现 | **已在该工程的真机上验证过**（项目所有者确认） |
| 搬进本仓库的这份代码 | **尚未**在本仓库编译或运行过 |
| 计划中的可做验证 | 目标平台交叉编译通过（编译期证据，不是运行期证据） |
| 运行期再验证 | 需要 Windows / Linux 真机；在那之前，推进表里这两项的状态只写到"移植 + 交叉编译"，**不会**标成已完成 |

这条差别必须留着：SKILL 的红线是"不写未验证的结论"。沿用源工程的验证结论是合理的
（那是同一份算法与同一条路径），但不能因此说成"本仓库已验证"。
