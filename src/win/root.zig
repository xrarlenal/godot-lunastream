//! Windows 绑定的聚合根（**从源工程搬入，只做了一处收敛**）。
//!
//! 源工程里这些文件挂在 `src/mf/win/` 下，聚合根是 `src/mf/win.zig`，同时导出
//! `com / mf / dxgi / d3d11 / d3d12 / d3dcompiler`。本仓库**不要 Media Foundation
//! 解码后端**（PLAN §5.5 明确把 mf 列为待精简项），而平台导入器只用得到其中的
//! COM 与 D3D 部分，所以这里的聚合根只导出五个子模块，**不含 `mf`**：
//! `com / dxgi / d3d11 / d3d12 / d3dcompiler`。
//!
//! 顺带记下源工程的一条硬规矩（写在它们的 `win.zig` 里）：Windows 绑定**全部手写**，
//! 任何地方都不 `@cImport`——每个 OS 类型、GUID、函数、COM 接口都照着 Zig 自带的
//! mingw-w64 头逐个誊写，接口的 vtable 按 C 头里的槽位顺序完整列出（不用的方法留成
//! 不透明占位，保证槽位下标不漂）。这与本仓库 macOS 那一侧的做法不同：那边是用
//! Objective-C 薄桥（`src/ffvt/cv_metal_bridge.m`）把 CoreVideo/Metal 包起来，
//! 再由 Zig 侧 `@cImport` 自己的头文件。两条路都能走通，差别在于"谁来承担 ABI 风险"。

pub const com = @import("com.zig");
pub const dxgi = @import("dxgi.zig");
pub const d3d11 = @import("d3d11.zig");
pub const d3d12 = @import("d3d12.zig");
pub const d3dcompiler = @import("d3dcompiler.zig");
