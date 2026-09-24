//! 色彩层：把解码器给出的色域标签，变成"这一帧该按什么公式换算成 RGB"。
//!
//! 为什么单独成一个模块：这一步算错的表现是"画面颜色不对"，而颜色不对比闪烁、
//! 卡顿都难定位——人眼没有绝对色标，看到偏色只会怀疑素材。所以把公式、范围、
//! 位深这三件事全部做成纯函数，用 ITU 参考值逐条钉死。
//!
//! ## 三件容易错的事
//!
//! 1. **色域矩阵**：BT.601（标清）、BT.709（高清）、BT.2020（超高清）的 YCbCr
//!    系数不同。用错的表现是肤色偏绿或偏品红。选定依据来自解码器上报的标签，
//!    不是猜。
//! 2. **范围**：视频范围（limited）与全范围（full）的 Y/C 基准不同。8-bit 视频
//!    范围的黑是 16 不是 0，白是 235 不是 255；当成全范围处理会整体发灰。
//! 3. **位深与码值对齐**：10-bit 码值可能右对齐放在 16-bit 容器里
//!    （FFmpeg 软解的 `yuv420p10le`），也可能左对齐（VAAPI 的 P010 dma-buf、
//    CoreVideo 的 x420）。后者要多右移 6 位才能还原成 10-bit 码值。这一条在
//    源工程里是逐字节校验过的，本模块保留了同样的两种约定并逐码值验证。
//!
//! ## 与 GLSL 的关系
//!
//! 真正跑在 GPU 上的换算在 compute shader 里。本模块是**同一套公式的 CPU 侧
//! 表述**，作用是：给 shader 一个可对照的正确答案，并在没有 GPU 的机器上验证
//! 这些公式。shader 落地时会补一条"两边的常数必须相等"的测试——那需要 shader
//! 文本存在，所以放在 shader 那一步。

const std = @import("std");

/// 亮度分量与色度分量之间的换算系数（ITU-R 定义）。
pub const Coefficients = struct {
    /// 红色差权重。
    kr: f64,
    /// 蓝色差权重。
    kb: f64,
    /// 绿色差权重；恒等于 `1 - kr - kb`，由构造器算出，不手写。
    kg: f64,
    /// Cb 对蓝的增益（`2(1-kb)`）。
    b_cb: f64,
    /// Cr 对红的增益（`2(1-kr)`）。
    r_cr: f64,
    /// Cb 对绿的增益。
    g_cb: f64,
    /// Cr 对绿的增益。
    g_cr: f64,

    fn fromKrkB(kr: f64, kb: f64) Coefficients {
        const kg = 1.0 - kr - kb;
        return .{
            .kr = kr,
            .kb = kb,
            .kg = kg,
            .b_cb = 2.0 * (1.0 - kb),
            .r_cr = 2.0 * (1.0 - kr),
            .g_cb = -2.0 * kb * (1.0 - kb) / kg,
            .g_cr = -2.0 * kr * (1.0 - kr) / kg,
        };
    }

    /// 标清：ITU-R BT.601-7。
    pub fn bt601() Coefficients {
        return fromKrkB(0.299, 0.114);
    }

    /// 高清：ITU-R BT.709-6。
    pub fn bt709() Coefficients {
        return fromKrkB(0.2126, 0.0722);
    }

    /// 超高清：ITU-R BT.2020-2。
    pub fn bt2020() Coefficients {
        return fromKrkB(0.2627, 0.0593);
    }
};

/// 色域。`unspecified` 表示解码器没给标签，由调用方决定兜底（通常按 BT.709）。
pub const ColorMatrix = enum(u8) {
    unspecified = 0,
    bt709 = 1,
    bt601 = 2,
    bt2020 = 3,

    pub fn coefficients(self: ColorMatrix) ?Coefficients {
        return switch (self) {
            .unspecified => null,
            .bt709 => Coefficients.bt709(),
            .bt601 => Coefficients.bt601(),
            .bt2020 => Coefficients.bt2020(),
        };
    }
};

/// 码值范围。
pub const ColorRange = enum(u8) {
    /// 视频范围（limited）：Y ∈ [16,235]、C ∈ [16,240]（8-bit 计）。
    video,
    /// 全范围（full）：Y ∈ [0,255]、C ∈ [0,255]（8-bit 计）。
    full,
};

/// 色彩原色（未指定时按 BT.709 处理）。目前只作为标签随帧传递，
/// 广色域换算与 HDR 一起做（见推进表的 HDR 条目）。
pub const ColorPrimaries = enum(u8) {
    unspecified = 0,
    bt709 = 1,
    bt601_625 = 2, // EBU 3213-E (PAL)
    bt601_525 = 3, // SMPTE C (NTSC)
    bt2020 = 4,
};

/// 传输函数（光电转换曲线的类型标签）。
pub const TransferFunction = enum(u8) {
    unspecified = 0,
    bt709 = 1,
    gamma22 = 2,
    gamma28 = 3,
    smpte2084 = 4, // PQ
    hlg = 5,
};

/// 有效位深。
///
/// 做成枚举而不是 `u8`：这样"12 位深"这种不支持的取值根本无法被表达，
/// 也就不需要在每个 switch 里写一个走不到的兜底分支。
pub const BitDepth = enum(u8) {
    eight = 8,
    ten = 10,

    /// 有效码值的最大值（8-bit → 255，10-bit → 1023）。
    pub fn maxCode(self: BitDepth) f64 {
        return switch (self) {
            .eight => 255.0,
            .ten => 1023.0,
        };
    }

    /// 视频范围的常数（16/235/128/240）按位深等比放大：
    /// 10-bit 就是 64/940/512/960。
    pub fn scale(self: BitDepth) f64 {
        return switch (self) {
            .eight => 1.0,
            .ten => 4.0,
        };
    }

    /// 色度的中性点码值：`2^(位深-1)`，即 8-bit 的 128、10-bit 的 512。
    ///
    /// 注意它**不等于** `maxCode() / 2`（255/2 = 127.5）。差这半格看着无所谓，
    /// 但会让"中性灰"解出 0.002 的偏色，在纯灰画面上能被看出来。
    pub fn midCode(self: BitDepth) f64 {
        return switch (self) {
            .eight => 128.0,
            .ten => 512.0,
        };
    }
};

/// 码值在容器里的摆放方式。
///
/// 这一层存在的唯一原因是 10-bit 有两种约定，而它们只差一次移位，
/// 弄错的表现是画面整体发暗（多移了一位）或对比度减半（少移了一位）。
pub const SampleLayout = struct {
    /// 有效位深。
    bit_depth: BitDepth = .eight,
    /// 把容器里的原始码值右移多少位还原成有效码值。
    /// 右对齐（`yuv420p10le`）为 0；左对齐（P010 / x420）为 6。
    code_shift: u5 = 0,

    pub const right_justified_8: SampleLayout = .{ .bit_depth = .eight, .code_shift = 0 };
    pub const right_justified_10: SampleLayout = .{ .bit_depth = .ten, .code_shift = 0 };
    pub const left_justified_10: SampleLayout = .{ .bit_depth = .ten, .code_shift = 6 };

    /// 有效码值的最大值（8-bit → 255，10-bit → 1023）。
    pub fn maxCode(self: SampleLayout) f64 {
        return self.bit_depth.maxCode();
    }

    /// 把容器原始码值还原成有效码值。
    pub fn decode(self: SampleLayout, raw_code: f64) f64 {
        return @floor(raw_code) / @as(f64, @floatFromInt(@as(u32, 1) << self.code_shift));
    }
};

/// 归一化后的 RGB（[0,1]，未夹取——超黑/超白会被保留，夹取由输出端做）。
pub const Rgb = struct { r: f64, g: f64, b: f64 };

/// 把亮度码值归一化到 [0,1]。
pub fn normalizeLuma(code: f64, layout: SampleLayout, range: ColorRange) f64 {
    const value = layout.decode(code);
    return switch (range) {
        .full => value / layout.maxCode(),
        .video => blk: {
            // 视频范围的 16/235 按位深等比放大：10-bit 就是 64/940。
            const scale = layout.bit_depth.scale();
            const black = 16.0 * scale;
            const white = 235.0 * scale;
            break :blk (value - black) / (white - black);
        },
    };
}

/// 把色度码值归一化到 [-0.5,0.5]。
pub fn normalizeChroma(code: f64, layout: SampleLayout, range: ColorRange) f64 {
    const value = layout.decode(code);
    return switch (range) {
        // 全范围的满量程是 maxCode，中性点在 midCode。
        .full => (value - layout.bit_depth.midCode()) / layout.maxCode(),
        .video => blk: {
            const scale = layout.bit_depth.scale();
            const mid = 128.0 * scale;
            const peak = 240.0 * scale;
            // 色度的满量程是 (peak - mid) 的两倍：从中点到上界与下界对称。
            break :blk (value - mid) / (2.0 * (peak - mid));
        },
    };
}

/// YCbCr → RGB（全范围、已归一化的输入）。
pub fn ycbcrToRgb(y: f64, cb: f64, cr: f64, coeffs: Coefficients) Rgb {
    return .{
        .r = y + coeffs.r_cr * cr,
        .g = y + coeffs.g_cb * cb + coeffs.g_cr * cr,
        .b = y + coeffs.b_cb * cb,
    };
}

/// 归一化的**仿射**形式：`归一值 = (码值 - offset) * gain`。
///
/// 存在的理由：`normalizeLuma` / `normalizeChroma` 里那些 switch 与除法的结果，
/// 对码值来说就是一条直线（视频范围是减黑再加满量程，全范围是直接缩放到满量程）。
/// 而 GPU 侧只想做"一次乘加"，不该把 switch 搬到 shader 里——那样数学就有两份，
/// 迟早会漂移。
///
/// 所以 CPU 把这条直线算出来，shader 只执行它；下面那组测试钉住"仿射形式与逐码值
/// 函数给出同一个结果"，将来 shader 落地时再加一条"GLSL 里的常数与这里一致"。
///
/// **只对右对齐（`code_shift == 0`）的输入成立**：左对齐（P010 / x420）是"先右移再
/// 归一"，整体不是一个关于容器码值的纯仿射函数。本插件的软解路径统一右对齐（见
/// ffsw shim 的约定），所以呈现侧的推送常量按右对齐算；将来接 VAAPI 的 P010 时，
/// 要么在导入侧先归一，要么把右移位也写进 shader。
pub const Affine = struct {
    offset: f64,
    gain: f64,

    pub fn apply(self: Affine, code: f64) f64 {
        return (code - self.offset) * self.gain;
    }
};

/// 亮度的仿射归一化常数。
pub fn lumaAffine(layout: SampleLayout, range: ColorRange) Affine {
    switch (range) {
        .full => return .{ .offset = 0.0, .gain = 1.0 / layout.maxCode() },
        .video => {
            const scale = layout.bit_depth.scale();
            const black = 16.0 * scale;
            const white = 235.0 * scale;
            return .{ .offset = black, .gain = 1.0 / (white - black) };
        },
    }
}

/// 色度的仿射归一化常数。
pub fn chromaAffine(layout: SampleLayout, range: ColorRange) Affine {
    const mid = layout.bit_depth.midCode();
    switch (range) {
        .full => return .{ .offset = mid, .gain = 1.0 / layout.maxCode() },
        .video => {
            const scale = layout.bit_depth.scale();
            const peak = 240.0 * scale;
            return .{ .offset = mid, .gain = 1.0 / (2.0 * (peak - mid)) };
        },
    }
}

test "亮度仿射常数与逐码值归一化在两种位深、两种范围下完全一致" {
    const cases = .{
        .{ SampleLayout.right_justified_8, ColorRange.video },
        .{ SampleLayout.right_justified_8, ColorRange.full },
        .{ SampleLayout.right_justified_10, ColorRange.video },
        .{ SampleLayout.right_justified_10, ColorRange.full },
    };
    inline for (cases) |case| {
        const layout = case[0];
        const range = case[1];
        const affine = lumaAffine(layout, range);
        var code: f64 = 0;
        while (code <= layout.maxCode()) : (code += 1) {
            try std.testing.expectApproxEqAbs(normalizeLuma(code, layout, range), affine.apply(code), 1e-12);
        }
    }
}

test "色度仿射常数与逐码值归一化在两种位深、两种范围下完全一致" {
    const cases = .{
        .{ SampleLayout.right_justified_8, ColorRange.video },
        .{ SampleLayout.right_justified_8, ColorRange.full },
        .{ SampleLayout.right_justified_10, ColorRange.video },
        .{ SampleLayout.right_justified_10, ColorRange.full },
    };
    inline for (cases) |case| {
        const layout = case[0];
        const range = case[1];
        const affine = chromaAffine(layout, range);
        var code: f64 = 0;
        while (code <= layout.maxCode()) : (code += 1) {
            try std.testing.expectApproxEqAbs(normalizeChroma(code, layout, range), affine.apply(code), 1e-12);
        }
    }
}

// 这两条把"即将写进推送常量的具体数字"钉死。注意归一化的增益是**满量程的倒数**：
// 8 位视频范围的亮度是 (v - 16) / 219，色度是 (v - 128) / 224（色度从中点到上界是
// 112，而满量程是它的两倍 = 224）。10 位按位深等比放大：64 / 876 与 512 / 896。
//
// 别把它与 RGB 矩阵里的 255/219 混起来——那是"归一化之后再乘的系数"，两者不是一回事
// （这条注释就是我被自己绊了一跤之后加的：第一版测试期望写的正是 255/219）。
test "8 位视频范围的仿射常数是标准值（黑电平 16、满量程 219）" {
    const luma = lumaAffine(.right_justified_8, .video);
    try std.testing.expectApproxEqAbs(@as(f64, 16.0), luma.offset, 1e-12);
    try std.testing.expectApproxEqAbs(1.0 / 219.0, luma.gain, 1e-12);

    const chroma = chromaAffine(.right_justified_8, .video);
    try std.testing.expectApproxEqAbs(@as(f64, 128.0), chroma.offset, 1e-12);
    try std.testing.expectApproxEqAbs(1.0 / 224.0, chroma.gain, 1e-12);
}

test "10 位视频范围的仿射常数按位深等比放大（64 / 512，满量程 876 / 896）" {
    const luma = lumaAffine(.right_justified_10, .video);
    try std.testing.expectApproxEqAbs(@as(f64, 64.0), luma.offset, 1e-12);
    try std.testing.expectApproxEqAbs(1.0 / 876.0, luma.gain, 1e-12);

    const chroma = chromaAffine(.right_justified_10, .video);
    try std.testing.expectApproxEqAbs(@as(f64, 512.0), chroma.offset, 1e-12);
    try std.testing.expectApproxEqAbs(1.0 / 896.0, chroma.gain, 1e-12);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const tol: f64 = 1e-9;

fn approx(a: f64, b: f64, tolerance: f64) bool {
    return @abs(a - b) <= tolerance;
}

test "BT.601 系数与 ITU-R BT.601-7 一致" {
    const c = Coefficients.bt601();
    try std.testing.expect(approx(c.kr, 0.299, tol));
    try std.testing.expect(approx(c.kb, 0.114, tol));
    try std.testing.expect(approx(c.kg, 0.587, 1e-6));
    try std.testing.expect(approx(c.r_cr, 1.402, 1e-6));
    try std.testing.expect(approx(c.b_cb, 1.772, 1e-6));
    try std.testing.expect(approx(c.g_cb, -0.344136, 1e-5));
    try std.testing.expect(approx(c.g_cr, -0.714136, 1e-5));
}

test "BT.709 系数与 ITU-R BT.709-6 一致" {
    const c = Coefficients.bt709();
    try std.testing.expect(approx(c.kr, 0.2126, tol));
    try std.testing.expect(approx(c.kb, 0.0722, tol));
    try std.testing.expect(approx(c.kg, 0.7152, 1e-6));
    try std.testing.expect(approx(c.r_cr, 1.5748, 1e-6));
    try std.testing.expect(approx(c.b_cb, 1.8556, 1e-6));
    try std.testing.expect(approx(c.g_cb, -0.187324, 1e-5));
    try std.testing.expect(approx(c.g_cr, -0.468124, 1e-5));
}

test "BT.2020 系数与 ITU-R BT.2020-2 一致" {
    const c = Coefficients.bt2020();
    try std.testing.expect(approx(c.kr, 0.2627, tol));
    try std.testing.expect(approx(c.kb, 0.0593, tol));
    try std.testing.expect(approx(c.kg, 0.6780, 1e-6));
    try std.testing.expect(approx(c.r_cr, 1.4746, 1e-6));
    try std.testing.expect(approx(c.b_cb, 1.8814, 1e-6));
}

test "Kg 恒等于 1-Kr-Kb（三条色域的构造约束）" {
    const all = [_]Coefficients{ Coefficients.bt601(), Coefficients.bt709(), Coefficients.bt2020() };
    for (all) |c| {
        try std.testing.expect(approx(c.kg, 1.0 - c.kr - c.kb, 1e-12));
    }
}

test "未指定色域时返回 null 而不是猜一个" {
    try std.testing.expect(ColorMatrix.unspecified.coefficients() == null);
    try std.testing.expect(ColorMatrix.bt709.coefficients() != null);
}

test "8-bit 视频范围白点 (235,128,128) 解码为纯白" {
    const layout = SampleLayout.right_justified_8;
    const y = normalizeLuma(235.0, layout, .video);
    const cb = normalizeChroma(128.0, layout, .video);
    const cr = normalizeChroma(128.0, layout, .video);
    const rgb = ycbcrToRgb(y, cb, cr, Coefficients.bt709());
    try std.testing.expect(approx(rgb.r, 1.0, 1e-9));
    try std.testing.expect(approx(rgb.g, 1.0, 1e-9));
    try std.testing.expect(approx(rgb.b, 1.0, 1e-9));
}

test "8-bit 视频范围黑点 (16,128,128) 解码为纯黑" {
    const layout = SampleLayout.right_justified_8;
    const y = normalizeLuma(16.0, layout, .video);
    const cb = normalizeChroma(128.0, layout, .video);
    const cr = normalizeChroma(128.0, layout, .video);
    const rgb = ycbcrToRgb(y, cb, cr, Coefficients.bt709());
    try std.testing.expect(approx(rgb.r, 0.0, 1e-9));
    try std.testing.expect(approx(rgb.g, 0.0, 1e-9));
    try std.testing.expect(approx(rgb.b, 0.0, 1e-9));
}

test "8-bit 全范围白点与黑点" {
    const layout = SampleLayout.right_justified_8;
    const yw = normalizeLuma(255.0, layout, .full);
    const yb = normalizeLuma(0.0, layout, .full);
    try std.testing.expect(approx(yw, 1.0, 1e-12));
    try std.testing.expect(approx(yb, 0.0, 1e-12));
    // 全范围的色度中性点在 128。
    try std.testing.expect(approx(normalizeChroma(128.0, layout, .full), 0.0, 1e-12));
}

test "视频范围与全范围对同一个 Y 值给出不同亮度（这就是发灰的来源）" {
    const layout = SampleLayout.right_justified_8;
    const video = normalizeLuma(128.0, layout, .video);
    const full = normalizeLuma(128.0, layout, .full);
    try std.testing.expect(!approx(video, full, 1e-3));
    try std.testing.expect(video > full); // 视频范围把 128 抬得更高
}

test "色度中性点在两种范围下都解码为 0" {
    try std.testing.expect(approx(normalizeChroma(128.0, SampleLayout.right_justified_8, .video), 0.0, 1e-12));
    try std.testing.expect(approx(normalizeChroma(512.0, SampleLayout.right_justified_10, .video), 0.0, 1e-12));
    try std.testing.expect(approx(normalizeChroma(512.0, SampleLayout.right_justified_10, .full), 0.0, 1e-12));
}

test "10-bit 视频范围白点与黑点" {
    const layout = SampleLayout.right_justified_10;
    try std.testing.expect(approx(normalizeLuma(940.0, layout, .video), 1.0, 1e-12));
    try std.testing.expect(approx(normalizeLuma(64.0, layout, .video), 0.0, 1e-12));
}

test "10-bit 右对齐与左对齐（P010）逐码值还原一致" {
    // 0..1023 全部扫一遍：两种约定必须还原出同一个有效码值。
    const right = SampleLayout.right_justified_10;
    const left = SampleLayout.left_justified_10;
    var code: u32 = 0;
    while (code <= 1023) : (code += 1) {
        const c: f64 = @floatFromInt(code);
        try std.testing.expect(approx(right.decode(c), c, 1e-12));
        // 左对齐：容器里放的是 code << 6。
        const container: f64 = @floatFromInt(code << 6);
        try std.testing.expect(approx(left.decode(container), c, 1e-12));
        // 归一化结果也必须一致。
        try std.testing.expect(approx(
            normalizeLuma(c, right, .video),
            normalizeLuma(container, left, .video),
            1e-12,
        ));
    }
}

test "10-bit 左对齐在容器里的最大值正好是 16-bit 上界附近" {
    // 1023 << 6 = 65472，接近 65535：这正是 P010 的填充方式。
    const container: f64 = @floatFromInt(@as(u32, 1023) << 6);
    try std.testing.expect(approx(container, 65472.0, 1e-12));
}

test "BT.2020 与 BT.709 对同一 YCbCr 给出不同 RGB（UHD 与 HD 的差异）" {
    const layout = SampleLayout.right_justified_8;
    const y = normalizeLuma(160.0, layout, .video);
    const cb = normalizeChroma(100.0, layout, .video);
    const cr = normalizeChroma(180.0, layout, .video);
    const hd = ycbcrToRgb(y, cb, cr, Coefficients.bt709());
    const uhd = ycbcrToRgb(y, cb, cr, Coefficients.bt2020());
    try std.testing.expect(!approx(hd.r, uhd.r, 1e-6));
    try std.testing.expect(!approx(hd.g, uhd.g, 1e-6));
    try std.testing.expect(!approx(hd.b, uhd.b, 1e-6));
}

test "红色主导的 YCbCr 解出 R 分量为最大" {
    const layout = SampleLayout.right_justified_8;
    const y = normalizeLuma(128.0, layout, .video);
    const cb = normalizeChroma(90.0, layout, .video); // 低 Cb → 偏红
    const cr = normalizeChroma(200.0, layout, .video);
    const rgb = ycbcrToRgb(y, cb, cr, Coefficients.bt601());
    try std.testing.expect(rgb.r > rgb.g);
    try std.testing.expect(rgb.r > rgb.b);
}

test "把对齐方式解释反了会整体发暗（记录失效模式）" {
    // 真实码值 940 是 10-bit 视频范围的白点。它若被当成 P010 的容器值，
    // 会先右移 6 位变成 14.6875 —— 比视频范围的黑（64）还低，归一化后为负，
    // 画面整体掉进黑里。这就是"忘了 code_shift"的量化表现。
    const wrongly = SampleLayout.left_justified_10.decode(940.0);
    try std.testing.expect(approx(wrongly, 14.6875, 1e-9));

    const y_correct = normalizeLuma(940.0, SampleLayout.right_justified_10, .video);
    const y_wrong = normalizeLuma(940.0, SampleLayout.left_justified_10, .video);
    try std.testing.expect(approx(y_correct, 1.0, 1e-12));
    try std.testing.expect(y_wrong < 0.0);
}
