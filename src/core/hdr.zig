//! HDR：传输函数与色调映射（core 层，纯数学）。
//!
//! 这一层要解决的是"10-bit 片源解出来了，但它的亮度还没被正确映射到 SDR 输出"：
//!
//! | 输入 | 要做什么 |
//! |---|---|
//! | PQ（SMPTE ST 2084，HDR10） | 电信号 → 绝对亮度（0..10000 nits） |
//! | HLG（BT.2100） | 电信号 → 场景线性光 |
//! | BT.2020 原色 | 换算到 BT.709（否则广色域素材会整体偏色） |
//! | 任意 HDR 亮度 | 色调映射到 SDR 的 [0,1] |
//!
//! 为什么放在 core 而不是着色器里：这些是**有标准答案的数学**，可以逐条对照标准值
//! 验证；一旦搬进 GLSL，就只能靠肉眼看画面——而"亮度映射不对"恰恰是最难看出来的
//! 一类问题（人眼对绝对亮度没有标尺）。着色器那边只接受这里算出来的常数。
//!
//! ## 刻意不做的事
//!
//! - **不做 OOTF（HLG 的系统伽马）**：它取决于显示端的峰值亮度与观看环境，属于
//!   显示端策略而不是解码端的职责；这里只给出标准的逆 OETF 部分并写明。
//! - **不做色域映射的感知模型**：BT.2020 → BT.709 只做线性矩阵 + 负值钳位，
//!   因为"把广色域压进窄色域"的感知做法（如 CAM16 / 色度自适应）需要显示端信息。

const std = @import("std");

/// SMPTE ST 2084（PQ）的常数，按标准写成有理数再算，避免手抄小数。
pub const pq = struct {
    pub const m1: f64 = 2610.0 / 16384.0;
    pub const m2: f64 = 2523.0 / 4096.0 * 128.0;
    pub const c1: f64 = 3424.0 / 4096.0;
    pub const c2: f64 = 2413.0 / 4096.0 * 32.0;
    pub const c3: f64 = 2392.0 / 4096.0 * 32.0;
    /// PQ 能表示的最大亮度（nits）。
    pub const peak_nits: f64 = 10000.0;

    /// 电信号 → **相对**亮度（0..1，1 代表 10000 nits）。
    pub fn toRelativeLuminance(e: f64) f64 {
        if (e <= 0.0) return 0.0;
        const p = std.math.pow(f64, e, 1.0 / m2);
        const num = @max(p - c1, 0.0);
        const den = c2 - c3 * p;
        if (den <= 0.0) return 1.0;
        return std.math.pow(f64, num / den, 1.0 / m1);
    }

    /// 相对亮度 → 电信号（逆函数，给回写与自检用）。
    pub fn fromRelativeLuminance(l: f64) f64 {
        if (l <= 0.0) return 0.0;
        const p = std.math.pow(f64, l, m1);
        const num = c1 + c2 * p;
        const den = 1.0 + c3 * p;
        return std.math.pow(f64, num / den, m2);
    }
};

/// BT.2100 的 HLG。
pub const hlg = struct {
    pub const a: f64 = 0.17883277;
    pub const b: f64 = 1.0 - 4.0 * a; // 0.28466892
    pub const c: f64 = 0.5 - a * std.math.log(f64, std.math.e, 4.0 * a); // 0.55991073

    /// 电信号 → 场景线性（0..1）。**不含 OOTF**（见文件头说明）。
    pub fn toSceneLinear(e: f64) f64 {
        if (e <= 0.0) return 0.0;
        if (e <= 0.5) return e * e / 3.0;
        return (std.math.exp((e - c) / a) + b) / 12.0;
    }

    pub fn fromSceneLinear(l: f64) f64 {
        if (l <= 0.0) return 0.0;
        if (l <= 1.0 / 12.0) return @sqrt(3.0 * l);
        return a * std.math.log(f64, std.math.e, 12.0 * l - b) + c;
    }
};

/// BT.709 的 OETF 的逆（电信号 → 线性），用来把 SDR 参考白放进同一条曲线比较。
pub fn bt709ToLinear(e: f64) f64 {
    if (e <= 0.0) return 0.0;
    if (e < 0.081) return e / 4.5;
    return std.math.pow(f64, (e + 0.099) / 1.099, 1.0 / 0.45);
}

pub fn linearToBt709(l: f64) f64 {
    if (l <= 0.0) return 0.0;
    if (l < 0.018) return 4.5 * l;
    return 1.099 * std.math.pow(f64, l, 0.45) - 0.099;
}

/// BT.2020 原色 → BT.709 原色的线性矩阵。
///
/// 行和都是 1（白点不变），这是它最有用的一条自检：如果抄错了任何一个系数，
/// 行和就不为 1，纯白会变成偏色——而那正是最难肉眼发现的一类错。
pub const bt2020_to_bt709: [3][3]f64 = .{
    .{ 1.6605, -0.5876, -0.0728 },
    .{ -0.1246, 1.1329, -0.0083 },
    .{ -0.0182, -0.1006, 1.1187 },
};

pub const Rgb = struct { r: f64, g: f64, b: f64 };

/// 广色域 → BT.709。负值钳到 0（窄色域装不下的颜色只能裁掉；感知映射不在本层）。
pub fn bt2020ToBt709(rgb: Rgb) Rgb {
    const m = bt2020_to_bt709;
    return .{
        .r = @max(0.0, m[0][0] * rgb.r + m[0][1] * rgb.g + m[0][2] * rgb.b),
        .g = @max(0.0, m[1][0] * rgb.r + m[1][1] * rgb.g + m[1][2] * rgb.b),
        .b = @max(0.0, m[2][0] * rgb.r + m[2][1] * rgb.g + m[2][2] * rgb.b),
    };
}

/// 色调映射的参数。
pub const ToneMap = struct {
    /// 素材的参考峰值亮度（nits）。HDR10 常见 1000；PQ 上限 10000。
    peak_nits: f64 = 1000.0,
    /// 映射到 SDR 白点（1.0）的输入亮度（nits）。取 peak 表示"峰值压到白"，
    /// 取更小的值会让高光更早饱和、整体更亮。
    white_nits: f64 = 1000.0,

    /// 扩展 Reinhard 曲线：`x(1 + x/w²)/(1 + x)`。
    ///
    /// 选它的理由是可验证：`x=0 → 0`、`x=w → 1`、单调递增、且 w=1 时退化成
    /// `x(1+x)/(1+x) = x`（即"峰值等于白点时不动它"）。这三条都能直接写成测试。
    pub fn apply(self: ToneMap, luminance_nits: f64) f64 {
        if (luminance_nits <= 0.0) return 0.0;
        if (self.white_nits <= 0.0 or self.peak_nits <= 0.0) return 0.0;
        // 扩展 Reinhard：x 按**峰值**归一，w = 白点/峰值。
        // 三条性质都是可验证的：x=w（白点）→ 1；w=1（峰值即白点）→ 恒等；
        // 峰值以上被钳在 1。前两条正是"白点映射到 SDR 白、峰值不溢出"的保证。
        const x = luminance_nits / self.peak_nits;
        const w = self.white_nits / self.peak_nits;
        if (w <= 0.0) return 0.0;
        const w2 = w * w;
        const out = (x * (1.0 + x / w2)) / (1.0 + x);
        // 超过声明峰值的内容（理论上不该有）钳在白点，不让它溢出。
        return @min(out, 1.0);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "PQ 的端点：0 是黑，1 是 10000 nits" {
    try testing.expectEqual(@as(f64, 0.0), pq.toRelativeLuminance(0.0));
    try testing.expectApproxEqAbs(@as(f64, 1.0), pq.toRelativeLuminance(1.0), 1e-3);
}

test "PQ 单调递增，且在整段上可逆" {
    var prev: f64 = -1.0;
    var e: f64 = 0.0;
    while (e <= 1.0) : (e += 0.01) {
        const l = pq.toRelativeLuminance(e);
        try testing.expect(l > prev);
        prev = l;
        // 逆函数要能原样还原（这是"曲线没抄错"最直接的证据）。
        try testing.expectApproxEqAbs(e, pq.fromRelativeLuminance(l), 1e-9);
    }
}

test "PQ 在 10% 电信号处大约只有 0.3 nits（这正是它把暗部摊开的原因）" {
    // ST 2084 的 0.1 ≈ 3.2e-5 相对亮度，也就是约 0.32 nits——比"线性解释"低四个
    // 数量级。这个数字我是先算错成 6 nits 才回来改的，所以把量级写进注释。
    const l = pq.toRelativeLuminance(0.1);
    try testing.expect(l > 1e-6 and l < 1e-3);
    try testing.expectApproxEqAbs(0.32, l * pq.peak_nits, 0.05);
}

test "HLG：0.5 是曲线分段点，1.0 接近 1（场景线性）" {
    try testing.expectEqual(@as(f64, 0.0), hlg.toSceneLinear(0.0));
    try testing.expectApproxEqAbs(1.0 / 12.0, hlg.toSceneLinear(0.5), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), hlg.toSceneLinear(1.0), 2e-3);
}

test "HLG 单调且可逆" {
    var prev: f64 = -1.0;
    var e: f64 = 0.0;
    while (e <= 1.0) : (e += 0.01) {
        const l = hlg.toSceneLinear(e);
        try testing.expect(l > prev);
        prev = l;
        try testing.expectApproxEqAbs(e, hlg.fromSceneLinear(l), 1e-9);
    }
}

test "BT.709 OETF 的逆：0 与 1 不动，0.5 落在已知值附近" {
    try testing.expectEqual(@as(f64, 0.0), bt709ToLinear(0.0));
    try testing.expectApproxEqAbs(@as(f64, 1.0), bt709ToLinear(1.0), 1e-9);
    // 0.5 的电信号对应约 0.26 的线性光——SDR 的中灰不是 50% 光。
    try testing.expectApproxEqAbs(@as(f64, 0.26), bt709ToLinear(0.5), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 0.5), linearToBt709(bt709ToLinear(0.5)), 1e-9);
}

test "BT.2020 → BT.709 的矩阵行和为 1（白点不变，抄错就会露）" {
    for (bt2020_to_bt709) |row| {
        try testing.expectApproxEqAbs(@as(f64, 1.0), row[0] + row[1] + row[2], 5e-4);
    }
}

test "BT.2020 的纯白映射到 BT.709 的纯白" {
    const white = bt2020ToBt709(.{ .r = 1.0, .g = 1.0, .b = 1.0 });
    try testing.expectApproxEqAbs(@as(f64, 1.0), white.r, 5e-4);
    try testing.expectApproxEqAbs(@as(f64, 1.0), white.g, 5e-4);
    try testing.expectApproxEqAbs(@as(f64, 1.0), white.b, 5e-4);
}

test "BT.2020 的纯绿在 BT.709 里会越界（负值被钳掉），这是色域收窄的固有代价" {
    const green = bt2020ToBt709(.{ .r = 0.0, .g = 1.0, .b = 0.0 });
    try testing.expect(green.g > 1.0); // 更饱和的绿在窄色域里装不下
    try testing.expectEqual(@as(f64, 0.0), green.r); // 负值被钳到 0
}

test "色调映射：0 进 0 出、峰值进白点、且单调递增" {
    const tm: ToneMap = .{ .peak_nits = 1000.0, .white_nits = 1000.0 };
    try testing.expectEqual(@as(f64, 0.0), tm.apply(0.0));
    try testing.expectApproxEqAbs(@as(f64, 1.0), tm.apply(1000.0), 1e-9);

    var prev: f64 = -1.0;
    var nits: f64 = 0.0;
    while (nits <= 1000.0) : (nits += 10.0) {
        const out = tm.apply(nits);
        try testing.expect(out > prev);
        prev = out;
    }
}

test "峰值等于白点时曲线是恒等（不动 SDR 素材）" {
    const tm: ToneMap = .{ .peak_nits = 1000.0, .white_nits = 1000.0 };
    var nits: f64 = 0.0;
    while (nits <= 1000.0) : (nits += 25.0) {
        try testing.expectApproxEqAbs(nits / 1000.0, tm.apply(nits), 1e-9);
    }
}

test "超过峰值的亮度被压到 1 以内（不会溢出白点）" {
    const tm: ToneMap = .{ .peak_nits = 1000.0, .white_nits = 1000.0 };
    try testing.expect(tm.apply(4000.0) <= 1.0);
    try testing.expect(tm.apply(10000.0) <= 1.0);
    // 单调不减：超过峰值之后都被钳在白点，所以是"不降"而不是"严格增"。
    try testing.expect(tm.apply(10000.0) >= tm.apply(4000.0));
}

test "峰值比白点更亮时（真实的 HDR 情形）：峰值映射到 1，中间亮度被压得比线性低" {
    const tm: ToneMap = .{ .peak_nits = 4000.0, .white_nits = 1000.0 };
    try testing.expectApproxEqAbs(@as(f64, 1.0), tm.apply(4000.0), 1e-9);
    // 白点（1000 nits）映射到 SDR 白：这是这条曲线的定义性性质。
    try testing.expectApproxEqAbs(@as(f64, 1.0), tm.apply(1000.0), 1e-9);
    // 白点低于峰值时，中低亮度被**抬高**（否则画面整体会发灰）：
    // 500 nits 按峰值线性只有 0.125，这里应当明显更亮，但仍在 0.5 以下。
    const mid = tm.apply(500.0);
    try testing.expect(mid > 500.0 / 4000.0);
    try testing.expect(mid < 0.5);
}
