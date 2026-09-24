//! CPU 与呈现着色器之间的推送常量。
//!
//! 布局是 ABI：**字段顺序与类型必须与 `src/shaders/nv12_to_rgba.comp` 里的
//! `push_constant` 块逐字对应**，由 `src/shaders/nv12_shader_abi_test.zig` 守着
//! （它解析着色器源码、比对字段名顺序与总字节数）。
//!
//! 为什么把着色器的数学全部做成推送常量：这样 core/color.zig 里的归一化与矩阵是
//! **唯一**的数学定义，着色器只做乘加。代价是每帧多传 48 字节，收益是 CPU 与 GPU
//! 不会各自漂移——源工程为此专门写过"解析着色器源码比对手抄常数"的测试，这里从
//! 结构上就不需要那种测试了。

const std = @import("std");
const color = @import("color.zig");

pub const Nv12PushConstants = extern struct {
    /// 码值 = 纹理样值 * sample_scale。8 位是 255，10 位是 65535；左对齐的容器
    /// （P010 / x420）还要再除以 2^shift，所以这里直接给"除完"的值。
    sample_scale: f32,
    luma_offset: f32,
    luma_gain: f32,
    chroma_offset: f32,
    chroma_gain: f32,
    r_cr: f32,
    g_cb: f32,
    g_cr: f32,
    b_cb: f32,
    /// 补到 48 字节：Vulkan 要求推送常量大小是 16 的倍数。
    pad0: f32 = 0.0,
    pad1: f32 = 0.0,
    pad2: f32 = 0.0,

    /// 由色彩标签 + 位深 + 容器的对齐方式算出全部常数。
    ///
    /// `raw_code_shift` 是"解码器给的样值相对有效码值左移了多少位"：右对齐是 0，
    /// P010 / x420 是 6。移位在这里折进 sample_scale（等价于先右移再归一），
    /// 因为 `floor(raw / 2^s)` 与 `raw / 2^s` 对 10 位码值在浮点里是一回事
    /// （有效码值只有 10 位，除完仍是整数）。
    pub fn fromColorimetry(
        bit_depth: u8,
        matrix: color.ColorMatrix,
        range: color.ColorRange,
        raw_code_shift: u5,
    ) Nv12PushConstants {
        const layout: color.SampleLayout = if (bit_depth >= 10)
            color.SampleLayout.right_justified_10
        else
            color.SampleLayout.right_justified_8;

        const luma = color.lumaAffine(layout, range);
        const chroma = color.chromaAffine(layout, range);
        // 未指定色域时按 BT.709 处理：与 backend.Colorimetry 的约定一致
        // （"全未指定时按 BT.709 视频范围处理"）。
        const coeffs = (matrix.coefficients() orelse color.Coefficients.bt709());

        const container_max: f64 = if (bit_depth >= 10) 65535.0 else 255.0;
        const shift_divisor: f64 = @floatFromInt(@as(u32, 1) << raw_code_shift);

        return .{
            .sample_scale = @floatCast(container_max / shift_divisor),
            .luma_offset = @floatCast(luma.offset),
            .luma_gain = @floatCast(luma.gain),
            .chroma_offset = @floatCast(chroma.offset),
            .chroma_gain = @floatCast(chroma.gain),
            .r_cr = @floatCast(coeffs.r_cr),
            .g_cb = @floatCast(coeffs.g_cb),
            .g_cr = @floatCast(coeffs.g_cr),
            .b_cb = @floatCast(coeffs.b_cb),
        };
    }
};

test "推送常量是 48 字节、字段按 4 字节排布（GPU 侧的 ABI 前提）" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Nv12PushConstants));
    try std.testing.expectEqual(@as(usize, 48 % 16), @sizeOf(Nv12PushConstants) % 16);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Nv12PushConstants, "sample_scale"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Nv12PushConstants, "luma_offset"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Nv12PushConstants, "b_cb"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(Nv12PushConstants, "pad0"));
}

test "8 位视频范围 BT.709：常数就是标准值" {
    const pc = Nv12PushConstants.fromColorimetry(8, .bt709, .video, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 255.0), pc.sample_scale, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), pc.luma_offset, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 219.0), pc.luma_gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0), pc.chroma_offset, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 224.0), pc.chroma_gain, 1e-6);

    const bt709 = color.Coefficients.bt709();
    try std.testing.expectApproxEqAbs(@as(f32, @floatCast(bt709.r_cr)), pc.r_cr, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, @floatCast(bt709.b_cb)), pc.b_cb, 1e-6);
}

test "10 位右对齐：容器满量程 65535，归一化常数按位深放大" {
    const pc = Nv12PushConstants.fromColorimetry(10, .bt709, .video, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 65535.0), pc.sample_scale, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0), pc.luma_offset, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 876.0), pc.luma_gain, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 512.0), pc.chroma_offset, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 896.0), pc.chroma_gain, 1e-6);
}

test "左对齐容器（P010 / x420）：移位折进 sample_scale，其余常数与右对齐一致" {
    const shifted = Nv12PushConstants.fromColorimetry(10, .bt709, .video, 6);
    const plain = Nv12PushConstants.fromColorimetry(10, .bt709, .video, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 65535.0 / 64.0), shifted.sample_scale, 1e-3);
    try std.testing.expectApproxEqAbs(plain.luma_offset, shifted.luma_offset, 1e-6);
    try std.testing.expectApproxEqAbs(plain.luma_gain, shifted.luma_gain, 1e-6);
    try std.testing.expectApproxEqAbs(plain.chroma_offset, shifted.chroma_offset, 1e-6);
}

test "未指定色域时退回 BT.709（与 backend.Colorimetry 的约定一致）" {
    const unspecified = Nv12PushConstants.fromColorimetry(8, .unspecified, .video, 0);
    const bt709 = Nv12PushConstants.fromColorimetry(8, .bt709, .video, 0);
    try std.testing.expectApproxEqAbs(bt709.r_cr, unspecified.r_cr, 1e-9);
    try std.testing.expectApproxEqAbs(bt709.g_cr, unspecified.g_cr, 1e-9);
}

test "全范围与视频范围给出不同的归一化常数（这就是画面发灰的来源）" {
    const video = Nv12PushConstants.fromColorimetry(8, .bt709, .video, 0);
    const full = Nv12PushConstants.fromColorimetry(8, .bt709, .full, 0);

    // 全范围：偏置 0、满量程 255；视频范围：偏置 16、满量程 219。
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), full.luma_offset, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), (255.0 - full.luma_offset) * full.luma_gain, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), (235.0 - video.luma_offset) * video.luma_gain, 1e-5);
    try std.testing.expect(video.luma_gain != full.luma_gain);

    // 同一个码值在两种范围下给出不同亮度——这正是"把视频范围当全范围解"会发灰的原因。
    // 差多少：128 在视频范围是 (128-16)/219 ≈ 0.511，在全范围是 128/255 ≈ 0.502，
    // 约 0.009 —— 小到肉眼容易放过，所以用这条测试把它钉住。
    const code: f32 = 128.0;
    const as_video = (code - video.luma_offset) * video.luma_gain;
    const as_full = (code - full.luma_offset) * full.luma_gain;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0094), @abs(as_video - as_full), 0.001);
}
