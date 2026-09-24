//! ffsw_shim.h 的 C ABI 标签与 core 枚举的一致性守卫。
//!
//! 这个 shim 的契约是"标签数值由 C 侧发出、Zig 侧 `@enumFromInt` 直收"，
//! 所以两边的数值一旦漂移，**编译期不会报错**，只会让帧带着错误的色域标签
//! 一路走到着色器——表现是颜色不对，而人眼没有绝对色标，很难自证。
//!
//! 因此这里把头文件当文本读进来（`@embedFile`），逐项比对数值，并且检查
//! "core 枚举有多少个成员，头文件里就有多少个对应标签"——后者防的是
//! "core 加了成员、shim 忘了跟"这种只在新特性上才暴露的漏改。
//!
//! 只读文本，不需要 FFmpeg、不需要 GPU，因此它属于 `zig build test`。

const std = @import("std");
const testing = std.testing;

const color = @import("core").color;

const header_src = @embedFile("ffsw_shim.h");

/// 在头文件文本里找一个 `NAME = 123` 形式的整数字面量。
fn findLabel(src: []const u8, name: []const u8) !i64 {
    var lines = std.mem.tokenizeScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, name)) continue;
        const rest = trimmed[name.len..];
        // 整词匹配：名字后面必须紧跟空白或 `=`，否则 NV_A 会命中 NV_AB。
        if (rest.len == 0) continue;
        if (rest[0] != ' ' and rest[0] != '\t' and rest[0] != '=') continue;

        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        const after = std.mem.trim(u8, rest[eq + 1 ..], " \t\r");
        var end: usize = 0;
        while (end < after.len and std.ascii.isDigit(after[end])) : (end += 1) {}
        if (end == 0) continue;
        return std.fmt.parseInt(i64, after[0..end], 10);
    }
    return error.LabelNotFound;
}

/// 数一数头文件里以 `prefix` 开头的标签个数。
fn countByPrefix(src: []const u8, prefix: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, prefix) and std.mem.indexOfScalar(u8, trimmed, '=') != null) {
            n += 1;
        }
    }
    return n;
}

fn expectLabel(name: []const u8, expected: u8) !void {
    const got = try findLabel(header_src, name);
    try testing.expectEqual(@as(i64, @intCast(expected)), got);
}

test "色域矩阵标签与 color.ColorMatrix 逐项一致" {
    try expectLabel("NV_FFSW_MATRIX_UNSPECIFIED", @intFromEnum(color.ColorMatrix.unspecified));
    try expectLabel("NV_FFSW_MATRIX_BT709", @intFromEnum(color.ColorMatrix.bt709));
    try expectLabel("NV_FFSW_MATRIX_BT601", @intFromEnum(color.ColorMatrix.bt601));
    try expectLabel("NV_FFSW_MATRIX_BT2020", @intFromEnum(color.ColorMatrix.bt2020));
}

test "色彩原色标签与 color.ColorPrimaries 逐项一致" {
    try expectLabel("NV_FFSW_PRIM_UNSPECIFIED", @intFromEnum(color.ColorPrimaries.unspecified));
    try expectLabel("NV_FFSW_PRIM_BT709", @intFromEnum(color.ColorPrimaries.bt709));
    try expectLabel("NV_FFSW_PRIM_BT601_625", @intFromEnum(color.ColorPrimaries.bt601_625));
    try expectLabel("NV_FFSW_PRIM_BT601_525", @intFromEnum(color.ColorPrimaries.bt601_525));
    try expectLabel("NV_FFSW_PRIM_BT2020", @intFromEnum(color.ColorPrimaries.bt2020));
}

// 这一条就是这个守卫存在的理由：传输函数是唯一一处"名字对不上"的组
// （core 叫 smpte2084，C 侧叫 PQ），于是最容易被按顺序编号猜错。
// 最初的实现正是把它编成了 PQ=2 / HLG=3，而 core 里 2/3 是 gamma22/gamma28——
// 结果是 PQ 片源在 Zig 侧被读成 gamma22，颜色默默错掉。
test "传输函数标签与 color.TransferFunction 逐项一致" {
    try expectLabel("NV_FFSW_TRANSFER_UNSPECIFIED", @intFromEnum(color.TransferFunction.unspecified));
    try expectLabel("NV_FFSW_TRANSFER_BT709", @intFromEnum(color.TransferFunction.bt709));
    try expectLabel("NV_FFSW_TRANSFER_GAMMA22", @intFromEnum(color.TransferFunction.gamma22));
    try expectLabel("NV_FFSW_TRANSFER_GAMMA28", @intFromEnum(color.TransferFunction.gamma28));
    try expectLabel("NV_FFSW_TRANSFER_PQ", @intFromEnum(color.TransferFunction.smpte2084));
    try expectLabel("NV_FFSW_TRANSFER_HLG", @intFromEnum(color.TransferFunction.hlg));
}

test "码值范围标签与 color.ColorRange 逐项一致" {
    try expectLabel("NV_FFSW_RANGE_VIDEO", @intFromEnum(color.ColorRange.video));
    try expectLabel("NV_FFSW_RANGE_FULL", @intFromEnum(color.ColorRange.full));
}

// 漏改守卫：core 加了枚举成员而头文件没跟，上面的逐项比对是发现不了的
// （它只检查"写了的那几个对不对"）。所以再按组数个数。
test "头文件的标签数量与 core 枚举成员数一一对应" {
    try testing.expectEqual(
        @typeInfo(color.ColorMatrix).@"enum".fields.len,
        countByPrefix(header_src, "NV_FFSW_MATRIX_"),
    );
    try testing.expectEqual(
        @typeInfo(color.ColorPrimaries).@"enum".fields.len,
        countByPrefix(header_src, "NV_FFSW_PRIM_"),
    );
    try testing.expectEqual(
        @typeInfo(color.TransferFunction).@"enum".fields.len,
        countByPrefix(header_src, "NV_FFSW_TRANSFER_"),
    );
    try testing.expectEqual(
        @typeInfo(color.ColorRange).@"enum".fields.len,
        countByPrefix(header_src, "NV_FFSW_RANGE_"),
    );
}

// 解析器自身的守卫：写错了名字必须报错，而不是静默返回某个值。
test "找不到的标签名会报错（解析器不静默通过）" {
    try testing.expectError(error.LabelNotFound, findLabel(header_src, "NV_FFSW_MATRIX_BT709_TYPO"));
    // 前缀命中但整词不同的名字不能被误判成同一个标签。
    try testing.expectError(error.LabelNotFound, findLabel(header_src, "NV_FFSW_MATRIX_BT7"));
}
