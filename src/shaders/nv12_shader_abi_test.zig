//! 着色器推送常量的 ABI 守卫。
//!
//! `core/push_constants.zig` 的结构体与 `nv12_to_rgba.comp` 里的 `push_constant`
//! 块是 CPU 与 GPU 之间的 ABI：顺序或类型对不上，画面就会以"颜色不对、画面错位"
//! 这类最难自证的形态出问题，而编译器两边都不会报错。
//!
//! 所以这里把着色器当**文本**读进来（`@embedFile`），解析出 push_constant 块里的
//! 字段名与类型，按顺序与 Zig 结构体逐项比对。它只读文本，不需要 GPU，因此属于
//! `zig build test`。

const std = @import("std");
const testing = std.testing;

const core = @import("core");
const Nv12PushConstants = core.push_constants.Nv12PushConstants;

const shader_src = @embedFile("nv12_to_rgba.comp");

/// 取出 `layout(push_constant ...) uniform Params { ... } params;` 之间的正文。
fn pushConstantBlock(src: []const u8) []const u8 {
    const head = "layout(push_constant";
    const open = std.mem.indexOf(u8, src, head) orelse return "";
    const brace = std.mem.indexOfScalarPos(u8, src, open, '{') orelse return "";
    const close = std.mem.indexOfScalarPos(u8, src, brace, '}') orelse return "";
    return src[brace + 1 .. close];
}

/// 从一行声明里取"字段名"：`float foo;`、`float foo = 0.0;` 都要认。
fn fieldNameOf(line: []const u8) ?[]const u8 {
    // 去掉行内注释。
    const no_comment = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
    const trimmed = std.mem.trim(u8, no_comment, " \t\r");
    if (trimmed.len == 0 or !std.mem.endsWith(u8, trimmed, ";")) return null;
    var decl = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r");
    // 去掉初始化部分（`= 0.0`）。
    if (std.mem.indexOfScalar(u8, decl, '=')) |eq| decl = std.mem.trim(u8, decl[0..eq], " \t\r");
    // 最后一个空白之后就是字段名。
    var name: []const u8 = decl;
    if (std.mem.lastIndexOfAny(u8, decl, " \t")) |sp| name = decl[sp + 1 ..];
    return if (name.len == 0) null else name;
}

/// 取一行声明的类型（第一个空白之前）。
fn fieldTypeOf(line: []const u8) ?[]const u8 {
    const no_comment = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
    const trimmed = std.mem.trim(u8, no_comment, " \t\r");
    if (trimmed.len == 0 or !std.mem.endsWith(u8, trimmed, ";")) return null;
    const sp = std.mem.indexOfAny(u8, trimmed, " \t") orelse return null;
    return trimmed[0..sp];
}

test "着色器里有 push_constant 块，且字段数不为零（守卫本身别失效）" {
    const block = pushConstantBlock(shader_src);
    try testing.expect(block.len > 0);
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, block, '\n');
    while (lines.next()) |line| {
        if (fieldNameOf(line) != null) count += 1;
    }
    try testing.expect(count > 0);
}

test "着色器 push_constant 的字段与 core 结构体逐项同名同序" {
    const block = pushConstantBlock(shader_src);
    const zig_fields = @typeInfo(Nv12PushConstants).@"struct".fields;

    var index: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const name = fieldNameOf(line) orelse continue;
        try testing.expect(index < zig_fields.len);
        try testing.expectEqualStrings(zig_fields[index].name, name);
        index += 1;
    }
    try testing.expectEqual(zig_fields.len, index);
}

test "着色器侧每个字段都是 float，Zig 侧每个字段都是 f32" {
    const block = pushConstantBlock(shader_src);
    var lines = std.mem.tokenizeScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const ty = fieldTypeOf(line) orelse continue;
        try testing.expectEqualStrings("float", ty);
    }
    inline for (@typeInfo(Nv12PushConstants).@"struct".fields) |field| {
        try testing.expectEqual(f32, field.type);
    }
}

test "整个结构体是 48 字节且是 16 的倍数（Vulkan 的推送常量要求）" {
    try testing.expectEqual(@as(usize, 48), @sizeOf(Nv12PushConstants));
    try testing.expectEqual(@as(usize, 0), @sizeOf(Nv12PushConstants) % 16);
}
