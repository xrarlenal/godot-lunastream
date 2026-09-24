# 平台导入器的移植说明（0016 / 0017）

> 状态：**代码已搬入，Zig/C 两侧已能为两个目标平台交叉编译通过；适配层与随包 Layer
> 的产物接线、以及真机运行仍未做。**

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
| `src/godot/plane_copy.zig` | 同名 | 平面拷贝辅助（CPU 拷贝回退路径要用） |
| `src/win/com.zig` | `src/mf/win/com.zig` | 手写的 COM/IUnknown/ComPtr/HRESULT 与 Win32 句柄辅助 |
| `src/win/dxgi.zig` | `src/mf/win/dxgi.zig` | DXGI 资源接口与 DXGI_FORMAT 子集（共享句柄导出要用） |
| `src/win/d3d11.zig` | `src/mf/win/d3d11.zig` | D3D11 设备/上下文/纹理/fence 与互操作用的描述符结构 |
| `src/win/d3d12.zig` | `src/mf/win/d3d12.zig` | 零拷贝导入器打开共享句柄要用的三个 D3D12 接口 |
| `src/win/d3dcompiler.zig` | `src/mf/win/d3dcompiler.zig` | 运行期 HLSL 编译（平面拆分 compute） |
| `src/win/root.zig` | `src/mf/win.zig`（收敛） | 聚合根，**去掉了 `mf` 子模块**——本仓库不要 MF 解码后端 |

### 两处刻意的不同

1. **聚合根去掉 `mf`**：源工程的 `win.zig` 还导出 Media Foundation 绑定；本仓库按
   PLAN §5.5 不要 MF 解码后端，而平台导入器只用得到 COM 与 D3D 部分，所以
   `src/win/root.zig` 只导出五个子模块。
2. **Windows 绑定是手写的、不 `@cImport`**（源工程写在 `win.zig` 里的硬规矩：每个
   OS 类型、GUID、COM 接口都照 mingw-w64 头逐个誊写，vtable 按槽位顺序完整列出）。
   本仓库 macOS 那一侧走的是另一条路——Objective-C 薄桥加 Zig 侧 `@cImport` 自己的头。
   两条路都能走通，差别只在"ABI 风险由谁承担"，这里照搬源工程的选择。

带 `.reference` 后缀的两份是刻意不改名的：它们既不是本仓库的接口（0014 已经定了自己的
`surface_importer.SurfaceImporter`），也不是本仓库的实现，放在旁边只为对照——**它们
不参与编译**，文件名里也写明了这一点。

## 要做哪些接缝适配（下一步的具体工作）

1. **接口对齐**。源工程的导入器实现的是它的 `si.ImportResult`；本仓库 0014 定的是
   `Surface { spec, planes, release_hook }` + `Error`。适配点是每个导入器的
   `import()` 返回处与 `deinit()`，不涉及内部算法。

   搬的时候才发现它的词汇表**比 0014 的更有表达力**，有两处值得吸收：
   - `ImportResult` 五种结果（`success / not_ready / bad_frame / transient_failure /
     capability_unavailable`），其中只有 `capability_unavailable` 允许 Windows 的选择器
     **永久放弃** D3D12——"暂时失败"与"能力不可用"必须分开，否则一次抖动就会把整条
     会话降级；
   - `raw_code_shift`（每帧 0 或 6）：VAAPI 的 P010 与 CoreVideo 的 x420 是**左对齐**，
     要在着色器里右移 6 位还原；本仓库软解路径在 shim 里就统一成右对齐了，所以这条
     只在平台路径上需要。
2. **选择器合并**。源工程有 `importer_selector.zig`；本仓库 0014 已有
   `dispatching_surface_importer.zig`。把平台导入器挂进后者，不再引入第二个选择器。
3. **模块接线**。源工程里平台导入器写的是 `@import("mf").win`，本仓库没有 `mf` 模块，
   改成 `@import("win")`（build.zig 里声明一个只在 Windows 目标下存在的模块，
   root 为 `src/win/root.zig`）；同时把它们对 `surface_importer.zig` 的引用指向本仓库
   的词汇表（或按上面第 1 条吸收其表达力）。
4. **构建接线**（源工程 `build.zig` 第 77/240–283/398–460 行是参照）：
   - Windows：编译上面的 Windows 源 + 链 `dxgi` / `d3d12` / `ole32` / `d3dcompiler_47`；
   - Linux：编译 `ffva` 的 vk shim，另出一个 `luna_ext_layer` 动态库 + `luna_ext_layer.json`，
     并给扩展加 `$ORIGIN/libs/linux64` 的 rpath；
   - 两者都要保证**其它平台不编译这些文件**。
5. **交叉编译检查**（本机可做的部分）：
   `zig build -Dtarget=x86_64-windows-gnu` 与 `-Dtarget=x86_64-linux-gnu`，至少在
   macOS 上把 Zig 侧与 C 侧编过一遍（Zig 自带 mingw-w64 头，Windows 侧可用；
   Linux 侧的 VAAPI/Vulkan 头是否齐备要实测）。

### 已经做完的（本步）

- **模块接线**：`src/win/root.zig` 作为 Windows 模块挂上（去掉 `mf` 子模块）；
  平台导入器对 `surface_importer.zig` 的引用指向 `platform_surface.zig`（源工程那份
  词汇表，逐字节搬入）——接缝处将来加一层适配，而不是把它们改写进本仓库 0014 的
  词汇表（那是两千行已验证代码的无谓风险）。
- **参与编译**：`extension.zig` 里用 comptime 分支按目标引用对应的平台导入器。这一步
  把"交叉编译能不能过"变成一条真能跑的检查，而不是靠人记得手动编。
- **Linux 的 C 侧**：`vk_import_shim.c` 编进扩展（它不链 libvulkan，自己 `dlopen`
  解析 loader，所以只需要 Vulkan 头），并链 `dl`；Vulkan 头目录可用
  `-Dvulkan-include` 覆盖。另外搬入 `ffva_shim.h`——它是 VAAPI 解码 shim 的**纯 C ABI
  头**（只 include `stddef`/`stdint`，不含 `va/va.h`），vk shim 需要它。

### 还没做完的

- **随包 Vulkan Layer 的产物接线**：`luna_ext_layer.c` 要单独编成 `.so`，连同
  `luna_ext_layer.json` 装到扩展能找得到的位置（源工程用的是 `$ORIGIN/libs/linux64`
  rpath），`vulkan_layer_setup.zig` 才找得到它。本步没有动它，因为它在 macOS 上既不能
  编也不该装。
- **接缝适配层**：`platform_surface.PlaneTextures/ImportResult` ↔ 本仓库 0014 的
  `Surface/Error` 的那一层映射（约二十行，含四种失败的对应关系）。
- **真机运行**：见下表。

## 验证状态（必须说清楚）

| 事项 | 状态 |
|---|---|
| 源工程里的 Windows / Linux 实现 | **已在该工程的真机上验证过**（项目所有者确认） |
| 搬进本仓库的这份代码 | **已能为两个目标平台交叉编译通过**（编译期证据，见下） |
| 运行期验证 | **仍未做**：需要 Windows / Linux 真机。在此之前推进表不会把这两项标成已完成 |

交叉编译证据（本机 macOS 上执行）：

```bash
zig build -Dtarget=x86_64-windows-gnu   # → lunastream.dll（663 KB，含 D3D12 导入器与手写 COM/D3D 绑定）
zig build -Dtarget=x86_64-linux-gnu     # → liblunastream.so（400 KB，含 vk_import_shim）
```

这条证据的边界也要写清楚：它证明**能编、能链**，不证明运行时正确——接口对不上、
驱动行为差异、共享句柄细节都要真机才看得见。所以文档里不出现"已验证"这个词来描述
这两步在本仓库的状态。

这条差别必须留着：SKILL 的红线是"不写未验证的结论"。沿用源工程的验证结论是合理的
（那是同一份算法与同一条路径），但不能因此说成"本仓库已验证"。
