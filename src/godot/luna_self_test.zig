//! `LunaSelfTest` —— 引擎侧自检的驱动面（诊断用，不属于插件对外 API）。
//!
//! 为什么需要它：呈现层的对象（CPU 帧导入器、纹理池）**只能**在真正有渲染上
//! 下文的引擎里验证——gdzig 自带的测试桥是 `--headless` 的（没有 RenderingDevice），
//! core 的单测更够不着。所以这条路是：GDScript 场景调 `run()` / `verify()` 拿回
//! 逐行结果，再按 0003 的老规矩以退出码报告。
//!
//! **类名来自文件名**：gdzig 用 `@typeName(@This())` 取短名再按 casez 的 "type"
//! 规则转成 Godot 类名，而文件根类型名就是文件名（去掉 .zig）。所以本文件叫
//! `luna_self_test.zig`，注册出来的类才是 `LunaSelfTest`——第一版叫
//! `self_test.zig`，结果注册成了 `SelfTest`（实测确认）。
//!
//! ## 为什么必须分成两次调用（run / verify）
//!
//! 主线程拿到的 RenderingDevice 是**非本地设备**：`textureUpdate` 只是把命令记进
//! 当前命令缓冲，真正的上传要等引擎在**帧末提交**。`submit()`/`sync()` 在非本地
//! 设备上会直接报 "Only local devices can submit and sync."（实测）。
//!
//! 所以验证必然跨帧：`run()` 负责导入与结构/池语义检查，GDScript 等一帧，
//! `verify()` 再做回读比对。第一版想在一帧里读完，读到的是更新之前的纹理——
//! 尺寸对、内容全零（src[0..8]=000102…，back 全 0）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Object = godot.class.Object;
const RefCounted = godot.class.RefCounted;
const RenderingServer = godot.class.RenderingServer;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const PackedByteArray = godot.builtin.PackedByteArray;

const core = @import("core");

const importer_mod = @import("cpu_frame_importer.zig");
const CpuFrameImporter = importer_mod.CpuFrameImporter;
const ImportedSurface = importer_mod.ImportedSurface;
const kPoolDepth = importer_mod.kPoolDepth;
const Spec = core.texture_pool.Spec;
const CpuPlanes = core.backend.CpuPlanes;

const LunaSelfTest = @This();

/// 结果文本缓冲：每行一条 `PASS ...` / `FAIL ...`。
const Report = struct {
    buf: []u8,
    len: usize = 0,
    failures: usize = 0,

    fn add(self: *Report, ok: bool, comptime fmt: []const u8, args: anytype) void {
        if (!ok) self.failures += 1;
        const written = std.fmt.bufPrint(self.buf[self.len..], "{s} " ++ fmt ++ "\n", .{
            if (ok) "PASS" else "FAIL",
        } ++ args) catch return;
        self.len += written.len;
    }

    fn note(self: *Report, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.buf[self.len..], fmt ++ "\n", args) catch return;
        self.len += written.len;
    }

    fn text(self: *Report) String {
        return String.fromUtf8(self.buf[0..self.len]) catch String.empty;
    }
};

// ---------------------------------------------------------------------------
// 字段与注册
// ---------------------------------------------------------------------------

allocator: Allocator,
base: *RefCounted,

/// 跨帧保留：待回读的两帧的纹理，以及它们对应的"应该是什么"。
importer: CpuFrameImporter = undefined,
importer_ready: bool = false,
luma: ?[]u8 = null,
chroma: ?[]u8 = null,
luma10: ?[]u8 = null,
spec8: Spec = .{ .width = 64, .height = 48, .bit_depth = 8 },
spec10: Spec = .{ .width = 32, .height = 24, .bit_depth = 10 },
first: ImportedSurface = undefined,
ten: ImportedSurface = undefined,
have_first: bool = false,
have_ten: bool = false,

pub fn register(r: *Registry) void {
    const class = r.createClass(LunaSelfTest, r.allocator, .auto);
    class.addMethod("run", .auto);
    class.addMethod("verify", .auto);
    // 必须注册：`_notification` 里安排的就是这个名字的延迟调用。
    class.addMethod("release_creator_ref", .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(LunaSelfTest);
}

pub fn create(allocator: *Allocator) !*LunaSelfTest {
    const self = try allocator.create(LunaSelfTest);
    self.* = .{ .allocator = allocator.*, .base = .init() };
    self.base.setInstance(LunaSelfTest, self);
    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *LunaSelfTest {
    const self = allocator.create(LunaSelfTest) catch @panic("OOM");
    self.* = .{ .allocator = allocator.*, .base = @ptrCast(obj) };
    self.base.setInstance(LunaSelfTest, self);
    return self;
}

pub fn destroy(self: *LunaSelfTest, allocator: *Allocator) void {
    Object.upcast(self.base).destroy();
    allocator.destroy(self);
}

/// 与 0022 的修法同源：交还创建期那份引用（引擎自己还会加一份）。
pub fn _notification(self: *LunaSelfTest, what: i32, reversed: bool) void {
    _ = reversed;
    if (what == Object.NOTIFICATION_POSTINITIALIZE) {
        _ = self.base.callDeferred(StringName.fromLatin1("release_creator_ref", true), .{});
    }
}

pub fn releaseCreatorRef(self: *LunaSelfTest) void {
    _ = RefCounted.upcast(self.base).unreference();
}

// ---------------------------------------------------------------------------
// 第一阶段：导入 + 结构 + 池语义
// ---------------------------------------------------------------------------

var report_buf: [8192]u8 = undefined;

pub fn run(self: *LunaSelfTest) String {
    var report = Report{ .buf = &report_buf };

    // 用**本地** RenderingDevice：只有它能在需要时 submit/sync，回读才拿得到刚写上
    // 去的字节（见 cpu_frame_importer.initWithDevice 的注释）。
    const local_rd = RenderingServer.createLocalRenderingDevice() orelse {
        report.note("拿不到本地 RenderingDevice：自检需要在带渲染上下文的引擎里跑", .{});
        report.note("TOTAL_FAILURES=1", .{});
        return report.text();
    };
    self.importer = CpuFrameImporter.initWithDevice(self.allocator, local_rd, .{ .cpu_readback = true }) catch |err| {
        report.note("没有可用的 RenderingDevice（{s}）：呈现层自检只能在带渲染上下文的引擎里跑", .{
            @errorName(err),
        });
        report.note("TOTAL_FAILURES=1", .{});
        return report.text();
    };
    self.importer_ready = true;

    if (self.preparePlanes(&report)) {
        self.importReadbackFrames(&report);
        self.checkPoolSemantics(&report);
    }

    report.note("TOTAL_FAILURES={d}", .{report.failures});
    return report.text();
}

/// 造两帧可验证的假平面（8-bit 与 10-bit），把"应该是什么"留在字段里等下一帧回读。
fn preparePlanes(self: *LunaSelfTest, report: *Report) bool {
    const y8 = self.allocator.alloc(u8, self.spec8.lumaBytes()) catch return false;
    const uv8 = self.allocator.alloc(u8, self.spec8.chromaBytes()) catch return false;
    const y10 = self.allocator.alloc(u8, self.spec10.lumaBytes()) catch return false;
    self.luma = y8;
    self.chroma = uv8;
    self.luma10 = y10;

    for (y8, 0..) |*b, i| b.* = @truncate(i);
    for (uv8, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    for (y10, 0..) |*b, i| b.* = @truncate(i * 3 + 1);

    report.add(y8.len == 64 * 48 and uv8.len == 64 * 24, "假平面尺寸符合紧凑 NV12（{d} + {d} 字节）", .{
        y8.len, uv8.len,
    });
    report.add(y10.len == 32 * 2 * 24, "10-bit 亮度平面用 16 位容器（{d} 字节）", .{y10.len});
    return true;
}

/// 导入两帧（8-bit 与 10-bit）供下一帧回读。第二帧带规格变化，于是走"有帧在用
/// 时不立刻销毁旧纹理"的孤儿路径——旧 RID 仍然有效，正是回读需要的。
fn importReadbackFrames(self: *LunaSelfTest, report: *Report) void {
    const planes8: CpuPlanes = .{
        .y = self.luma.?.ptr,
        .uv = self.chroma.?.ptr,
        .y_stride = self.spec8.lumaRowBytes(),
        .uv_stride = self.spec8.chromaRowBytes(),
        .bit_depth = 8,
    };
    const created_before = self.importer.stats().created;
    self.first = self.importer.import(self.spec8, planes8) catch |err| {
        report.add(false, "导入 8-bit 帧（{s}）", .{@errorName(err)});
        return;
    };
    self.have_first = true;
    const after_first = self.importer.stats().created;
    report.add(after_first == created_before + 2, "首次导入新建两块纹理（亮度 + 色度），实测 {d} 块", .{
        after_first - created_before,
    });
    report.add(self.importer.rd.textureIsValid(self.first.y), "亮度纹理 RID 有效", .{});
    report.add(self.importer.rd.textureIsValid(self.first.uv), "色度纹理 RID 有效", .{});

    const planes10: CpuPlanes = .{
        .y = self.luma10.?.ptr,
        .uv = self.luma10.?.ptr,
        .y_stride = self.spec10.lumaRowBytes(),
        .uv_stride = self.spec10.chromaRowBytes(),
        .bit_depth = 10,
    };
    self.ten = self.importer.import(self.spec10, planes10) catch |err| {
        report.add(false, "导入 10-bit 帧（{s}）", .{@errorName(err)});
        return;
    };
    self.have_ten = true;
    report.add(self.importer.rd.textureIsValid(self.ten.y), "10-bit 换了 16 位容器的新纹理，RID 有效", .{});
    report.add(
        self.importer.rd.textureIsValid(self.first.y),
        "规格在帧仍被持有时变化：旧纹理没有被销毁（留作孤儿，等销毁时释放）",
        .{},
    );
    report.add(self.importer.stats().orphans == 2, "被留成孤儿的旧纹理恰好 2 块（实测 {d}）", .{
        self.importer.stats().orphans,
    });
}

/// 池语义：并发要开新槽、归还后必须复用、取满要报背压、空闲时换规格要立刻释放。
/// 用一个**独立**的导入器，免得搅乱上面两帧的回读状态。
fn checkPoolSemantics(self: *LunaSelfTest, report: *Report) void {
    var pool_importer = CpuFrameImporter.init(self.allocator, .{}) catch return;
    defer pool_importer.deinit();

    const spec: Spec = .{ .width = 64, .height = 48, .bit_depth = 8 };
    const planes: CpuPlanes = .{
        .y = self.luma.?.ptr,
        .uv = self.chroma.?.ptr,
        .y_stride = spec.lumaRowBytes(),
        .uv_stride = spec.chromaRowBytes(),
        .bit_depth = 8,
    };

    const a = pool_importer.import(spec, planes) catch |err| {
        report.add(false, "池用例：首次导入（{s}）", .{@errorName(err)});
        return;
    };
    const b = pool_importer.import(spec, planes) catch |err| {
        report.add(false, "池用例：并发第二帧（{s}）", .{@errorName(err)});
        a.release();
        return;
    };
    report.add(a.y.getId() != b.y.getId(), "第一帧未归还时，第二帧换另一块纹理（不覆盖在用纹理）", .{});
    report.add(pool_importer.stats().created == 4, "并发两帧对应两个槽位（共 {d} 块纹理）", .{
        pool_importer.stats().created,
    });

    b.release();
    const created_before_reuse = pool_importer.stats().created;
    const c = pool_importer.import(spec, planes) catch |err| {
        report.add(false, "池用例：归还后重新导入（{s}）", .{@errorName(err)});
        a.release();
        return;
    };
    report.add(
        pool_importer.stats().created == created_before_reuse,
        "归还后的槽位被复用，没有新建纹理（仍 {d} 块）",
        .{pool_importer.stats().created},
    );
    report.add(c.y.getId() == b.y.getId(), "复用的正是刚归还的那一块（轮转而不是线性增长）", .{});
    c.release();

    // 取满：不归还地一直取，直到池说"没有了"。
    var held: [kPoolDepth]ImportedSurface = undefined;
    var held_count: usize = 0;
    while (held_count < kPoolDepth) : (held_count += 1) {
        held[held_count] = pool_importer.import(spec, planes) catch |err| {
            report.add(err == error.PoolExhausted, "池取满后报 PoolExhausted（而不是覆盖在用纹理）", .{});
            break;
        };
    }
    report.add(held_count > 0, "取满时手上又拿到 {d} 帧", .{held_count});
    for (held[0..held_count]) |surface| surface.release();
    a.release();
    report.add(pool_importer.stats().in_use == 0, "全部归还后在用为 0（实测 {d}）", .{
        pool_importer.stats().in_use,
    });

    // 空闲时换规格：旧纹理应当**立刻**释放，而不是留成孤儿。
    const stale_y = a.y;
    const generation_before = pool_importer.generation();
    const spec_changed: Spec = .{ .width = 32, .height = 24, .bit_depth = 8 };
    const changed_planes: CpuPlanes = .{
        .y = self.luma.?.ptr,
        .uv = self.chroma.?.ptr,
        .y_stride = spec_changed.lumaRowBytes(),
        .uv_stride = spec_changed.chromaRowBytes(),
        .bit_depth = 8,
    };
    const resized = pool_importer.import(spec_changed, changed_planes) catch |err| {
        report.add(false, "池用例：换规格后导入（{s}）", .{@errorName(err)});
        return;
    };
    report.add(pool_importer.generation() == generation_before + 1, "换规格让代数 +1（{d} -> {d}）", .{
        generation_before, pool_importer.generation(),
    });
    report.add(!pool_importer.rd.textureIsValid(stale_y), "空闲时换规格：旧纹理已立刻释放", .{});
    report.add(pool_importer.stats().orphans == 0, "空闲时换规格不留孤儿（实测 {d}）", .{
        pool_importer.stats().orphans,
    });
    resized.release();
}

// ---------------------------------------------------------------------------
// 第二阶段：回读比对（必须在引擎提交过一帧之后）
// ---------------------------------------------------------------------------

pub fn verify(self: *LunaSelfTest) String {
    var report = Report{ .buf = &report_buf };

    if (!self.importer_ready or !self.have_first or !self.have_ten) {
        report.add(false, "第一阶段没有跑成功，无法回读", .{});
        report.note("TOTAL_FAILURES={d}", .{report.failures});
        return report.text();
    }

    const y_want = self.luma.?;
    const uv_want = self.chroma.?;
    const y10_want = self.luma10.?;

    // 本地设备：可以显式提交并等 GPU 完成，所以这一帧就能读到刚上传的字节。
    self.importer.rd.submit();
    self.importer.rd.sync();

    var y_back = self.importer.rd.textureGetData(self.first.y, 0);
    defer y_back.deinit();
    var uv_back = self.importer.rd.textureGetData(self.first.uv, 0);
    defer uv_back.deinit();
    var y10_back = self.importer.rd.textureGetData(self.ten.y, 0);
    defer y10_back.deinit();

    report.add(y_back.size() == @as(i64, @intCast(y_want.len)), "亮度回读字节数 == {d}（实际 {d}）", .{
        y_want.len, y_back.size(),
    });
    report.add(uv_back.size() == @as(i64, @intCast(uv_want.len)), "色度回读字节数 == {d}（实际 {d}）", .{
        uv_want.len, uv_back.size(),
    });
    report.add(y10_back.size() == @as(i64, @intCast(y10_want.len)), "10-bit 亮度回读字节数 == {d}（实际 {d}）", .{
        y10_want.len, y10_back.size(),
    });
    report.add(equalBytes(y_back, y_want), "8-bit 亮度平面：上传什么就回读什么（逐字节）", .{});
    report.add(equalBytes(uv_back, uv_want), "8-bit 色度平面：上传什么就回读什么（逐字节）", .{});
    report.add(equalBytes(y10_back, y10_want), "10-bit 亮度平面：逐字节回读一致", .{});

    report.note("第一阶段创建纹理 {d} 块、上传平面 {d} 次、孤儿 {d} 块", .{
        self.importer.stats().created,
        self.importer.stats().uploads,
        self.importer.stats().orphans,
    });

    self.teardown();
    report.note("TOTAL_FAILURES={d}", .{report.failures});
    return report.text();
}

fn teardown(self: *LunaSelfTest) void {
    if (self.have_first) {
        self.first.release();
        self.have_first = false;
    }
    if (self.have_ten) {
        self.ten.release();
        self.have_ten = false;
    }
    if (self.importer_ready) {
        self.importer.deinit();
        self.importer_ready = false;
    }
    if (self.luma) |b| {
        self.allocator.free(b);
        self.luma = null;
    }
    if (self.chroma) |b| {
        self.allocator.free(b);
        self.chroma = null;
    }
    if (self.luma10) |b| {
        self.allocator.free(b);
        self.luma10 = null;
    }
}

/// 逐字节比较一个回读结果。
///
/// **不能把 `PackedByteArray.ptr()` 当数据指针**：gdzig 的 PackedByteArray 是不透明
/// 包装（`_: [16]u8` 里放 CowData 句柄），`ptr()` 返回的是**包装自己的地址**。
/// GDExtension 的 C API 也没有"取整块数据指针"的入口，只有逐下标
/// `packed_byte_array_operator_index`；Godot 的 PackedByteArray 底层是连续存储
/// （CowData<u8>），所以取下标 0 的地址再按长度读是成立的——这是对"连续"这一实现
/// 事实的依赖，因此只在这一处（和导入器的 writeBase）出现并写明。
fn equalBytes(got: PackedByteArray, want: []const u8) bool {
    if (got.size() != @as(i64, @intCast(want.len))) return false;
    if (want.len == 0) return true;
    const base: [*]const u8 = @ptrFromInt(@intFromPtr(got.indexConst(0)));
    return std.mem.eql(u8, base[0..want.len], want);
}
