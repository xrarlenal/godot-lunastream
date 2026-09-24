//! 着色器源码的唯一来源。
//!
//! 为什么要单独一个模块：Zig 的 `@embedFile` **不能跨出模块根目录**（实测报
//! `embed of file outside package path`）。着色器在 `src/shaders/`，而消费者在
//! `src/godot/`（呈现管线）与 `src/shaders/nv12_shader_abi_test.zig`（ABI 守卫），
//! 所以让它自己成为一个模块、两边都 import 它——这样源码也只有一份。

pub const nv12_to_rgba = @embedFile("nv12_to_rgba.comp");
