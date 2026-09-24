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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Registry = godot.extension.Registry;
const Object = godot.class.Object;
const RefCounted = godot.class.RefCounted;
const RenderingDevice = godot.class.RenderingDevice;
const RenderingServer = godot.class.RenderingServer;
const RdTextureFormat = godot.class.RdTextureFormat;
const RdTextureView = godot.class.RdTextureView;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const PackedByteArray = godot.builtin.PackedByteArray;
const Rid = godot.builtin.Rid;

const core = @import("core");

const importer_mod = @import("cpu_frame_importer.zig");
const CpuFrameImporter = importer_mod.CpuFrameImporter;
const kPoolDepth = importer_mod.kPoolDepth;
const surface_mod = @import("surface_importer.zig");
const Surface = surface_mod.Surface;
const dispatcher_mod = @import("dispatching_surface_importer.zig");
const DispatchingImporter = dispatcher_mod.DispatchingImporter;
const present_mod = @import("present_pipeline.zig");
const PresentPipeline = present_mod.PresentPipeline;
/// Metal 零拷贝用例只在 macOS 上存在。非 macOS 上这两处换成占位类型，让"字段声明"
/// 在别的目标上也说得通；**真正用到它们的代码都在 comptime 分支里**，因此不会被
/// 分析、也不会在链接期留下对 macOS 桥符号的引用（第一版没这么写，结果 Windows
/// 交叉编译在链接时报 `undefined symbol: nv_cv_metal_view_destroy`）。
const metal_supported = builtin.os.tag == .macos;

const metal_mod = if (metal_supported) @import("metal_surface_importer.zig") else struct {
    pub const MetalSurfaceImporter = struct {};
};

const bridge = if (metal_supported) @cImport({
    @cInclude("cv_metal_bridge.h");
}) else struct {};
const Spec = core.texture_pool.Spec;
const CpuPlanes = core.backend.CpuPlanes;
const VideoFrame = core.backend.VideoFrame;

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
/// 自检自己创建的**本地** RenderingDevice（我们建的，就得我们销毁）。
local_rd: ?*RenderingDevice = null,
luma: ?[]u8 = null,
chroma: ?[]u8 = null,
luma10: ?[]u8 = null,
spec8: Spec = .{ .width = 64, .height = 48, .bit_depth = 8 },
spec10: Spec = .{ .width = 32, .height = 24, .bit_depth = 10 },
first: Surface = undefined,
ten: Surface = undefined,
have_first: bool = false,
have_ten: bool = false,

/// 分发器用例（0014）：同一个接口下，CPU 帧走 CPU 路径，平台帧被明确拒绝。
dispatcher: DispatchingImporter = undefined,
dispatcher_ready: bool = false,
dispatched: Surface = undefined,
have_dispatched: bool = false,

/// Metal 零拷贝用例（0015）：自己造一块 IOSurface 支撑的 CVPixelBuffer 喂进去。
metal: ?metal_mod.MetalSurfaceImporter = null,
metal_surface: Surface = undefined,
have_metal_surface: bool = false,
metal_luma_expect: ?[]u8 = null,
metal_chroma_expect: ?[]u8 = null,

/// 呈现管线用例（0018）：喂一帧已知图案，跑 compute，再把 RGBA 读回来比对。
present: ?PresentPipeline = null,
present_surface: Surface = undefined,
have_present_surface: bool = false,
present_luma: ?[]u8 = null,
present_chroma: ?[]u8 = null,
present_spec: Spec = .{ .width = 32, .height = 24, .bit_depth = 8 },

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
    self.local_rd = local_rd;
    self.importer_ready = true;

    if (self.preparePlanes(&report)) {
        self.importReadbackFrames(&report);
        self.checkPoolSemantics(&report);
        self.checkDispatcher(&report);
        self.checkMetalImport(&report);
        self.checkPresentPipeline(&report);
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
    report.add(self.importer.rd.textureIsValid(lumaRid(self.first)), "亮度纹理 RID 有效", .{});
    report.add(self.importer.rd.textureIsValid(chromaRid(self.first)), "色度纹理 RID 有效", .{});

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
    report.add(self.importer.rd.textureIsValid(lumaRid(self.ten)), "10-bit 换了 16 位容器的新纹理，RID 有效", .{});
    report.add(
        self.importer.rd.textureIsValid(lumaRid(self.first)),
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
    report.add(lumaRid(a).getId() != lumaRid(b).getId(), "第一帧未归还时，第二帧换另一块纹理（不覆盖在用纹理）", .{});
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
    report.add(lumaRid(c).getId() == lumaRid(b).getId(), "复用的正是刚归还的那一块（轮转而不是线性增长）", .{});
    c.release();

    // 取满：不归还地一直取，直到池说"没有了"。
    var held: [kPoolDepth]Surface = undefined;
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
    const stale_y = lumaRid(a);
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

/// 运行时分发（0014）：对外只有一张接口，走哪条路由帧的 `surface_kind` 决定。
fn checkDispatcher(self: *LunaSelfTest, report: *Report) void {
    self.dispatcher = DispatchingImporter.initWithDevice(
        self.allocator,
        self.importer.rd,
        .{ .cpu_readback = true },
    ) catch |err| {
        report.add(false, "建分发器（{s}）", .{@errorName(err)});
        return;
    };
    self.dispatcher_ready = true;

    const cpu_frame: VideoFrame = .{
        .width = @intCast(self.spec8.width),
        .height = @intCast(self.spec8.height),
        .pixel_format = .nv12,
        .surface_kind = .cpu_nv12,
        .cpu = .{
            .y = self.luma.?.ptr,
            .uv = self.chroma.?.ptr,
            .y_stride = self.spec8.lumaRowBytes(),
            .uv_stride = self.spec8.chromaRowBytes(),
            .bit_depth = 8,
        },
    };

    self.dispatched = self.dispatcher.importFrame(cpu_frame) catch |err| {
        report.add(false, "分发 CPU 帧（{s}）", .{@errorName(err)});
        return;
    };
    self.have_dispatched = true;

    const after_cpu = self.dispatcher.stats();
    report.add(after_cpu.cpu == 1, "CPU 帧被分给 CPU 上传路径（cpu 计数 {d}）", .{after_cpu.cpu});
    report.add(after_cpu.platform == 0 and after_cpu.rejected == 0, "此时平台计数与拒绝计数都还是 0（platform={d} rejected={d}）", .{
        after_cpu.platform, after_cpu.rejected,
    });
    report.add(self.dispatched.planes == .luma_chroma, "CPU 路径交出的是「亮度 + 交织色度」两块纹理", .{});
    report.add(self.dispatched.raw_code_shift == 0, "CPU 上传路径的移位是 0（0011 已在 shim 里统一右对齐）", .{});
    report.add(self.dispatched.spec.eql(self.spec8), "分发结果带着帧自己的规格（{d}x{d}）", .{
        self.dispatched.spec.width, self.dispatched.spec.height,
    });

    // 平台帧：没有平台导入器时必须**明确拒绝**，而不是"想办法"退回 CPU 路径——
    // 平台帧根本没有 CPU 平面可上传（与 0009 的"hardware 档绝不悄悄落软解"同源）。
    const native_frame: VideoFrame = .{
        .width = @intCast(self.spec8.width),
        .height = @intCast(self.spec8.height),
        .pixel_format = .nv12,
        .surface_kind = .native_surface,
        .native_handle = null,
    };
    const native_refused = if (self.dispatcher.importFrame(native_frame)) |_| false else |err| err == error.UnsupportedFrame;
    report.add(native_refused, "平台帧在缺平台导入器时被明确拒绝（UnsupportedFrame）", .{});

    const after_native = self.dispatcher.stats();
    report.add(after_native.rejected == 1, "拒绝被如实计数（rejected={d}）", .{after_native.rejected});
    report.add(after_native.cpu == 1, "拒绝平台帧时没有偷偷走 CPU 路径（cpu 计数仍为 {d}）", .{
        after_native.cpu,
    });
}

/// 呈现管线（0018）：喂一帧已知图案，跑一遍 NV12 到 RGBA 的 compute。
///
/// 图案刻意取"亮度渐变 + 色度恒为中性 128"：这样 GLSL 里色度的双线性上采样不会
/// 引入不确定量（常量经过任何线性滤波还是它自己），于是每个像素的期望值都能在
/// Zig 侧用 core 的色彩层精确算出来。参数化中"中性灰不偏色"那条老性质，在这里以
/// 整条管线（推送常量 + 着色器 + 输出纹理）的形式被复验一遍。
fn checkPresentPipeline(self: *LunaSelfTest, report: *Report) void {
    const spec = self.present_spec;
    const luma = self.allocator.alloc(u8, spec.lumaBytes()) catch return;
    const chroma = self.allocator.alloc(u8, spec.chromaBytes()) catch return;
    self.present_luma = luma;
    self.present_chroma = chroma;

    // 亮度落在视频范围的 16..235 之内（越界会被 clamp，期望就失真了）。
    var row: usize = 0;
    while (row < spec.height) : (row += 1) {
        var col: usize = 0;
        while (col < spec.width) : (col += 1) {
            luma[row * spec.width + col] = @intCast(16 + (col * 3 + row * 2) % 200);
        }
    }
    @memset(chroma, 128);

    const planes: CpuPlanes = .{
        .y = luma.ptr,
        .uv = chroma.ptr,
        .y_stride = spec.lumaRowBytes(),
        .uv_stride = spec.chromaRowBytes(),
        .bit_depth = 8,
    };
    self.present_surface = self.importer.import(spec, planes) catch |err| {
        report.add(false, "呈现用例：导入图案（{s}）", .{@errorName(err)});
        return;
    };
    self.have_present_surface = true;
    report.add(self.present_surface.raw_code_shift == 0, "呈现用例的帧是右对齐（移位 0）", .{});

    self.present = PresentPipeline.init(
        self.allocator,
        self.importer.rd,
        spec.width,
        spec.height,
        .{ .enable_readback = true },
    ) catch |err| {
        report.add(false, "建呈现管线（{s}）", .{@errorName(err)});
        return;
    };
    const pipeline = &self.present.?;
    report.add(pipeline.shader.isValid(), "着色器从 GLSL 编译成功（SPIR-V 到 shader RID）", .{});
    report.add(pipeline.pipeline.isValid(), "compute 管线创建成功", .{});
    report.add(pipeline.outputTexture().isValid(), "稳定的输出纹理已创建", .{});

    const pc = core.push_constants.Nv12PushConstants.fromColorimetry(8, .bt709, .video, 0);
    const first = pipeline.present(self.present_surface, pc) catch |err| {
        report.add(false, "第一次 present（{s}）", .{@errorName(err)});
        return;
    };
    const second = pipeline.present(self.present_surface, pc) catch |err| {
        report.add(false, "第二次 present（{s}）", .{@errorName(err)});
        return;
    };
    report.add(
        second.getId() == first.getId(),
        "输出纹理跨帧稳定（RID 不变）——引用它的材质不会失效",
        .{},
    );
    report.add(pipeline.presents == 2, "派发计数 {d}", .{pipeline.presents});

    // 分辨率变化：换一个尺寸再呈现一次。输出纹理的尺寸在创建时定死，所以管线必须
    // 重建它——否则新尺寸的帧会被裁掉或拉伸。判据是"输出 RID 变了、管线尺寸跟上了"。
    const bigger: Spec = .{ .width = 48, .height = 32, .bit_depth = 8 };
    const bigger_luma = self.allocator.alloc(u8, bigger.lumaBytes()) catch return;
    const bigger_chroma = self.allocator.alloc(u8, bigger.chromaBytes()) catch return;
    defer {
        self.allocator.free(bigger_luma);
        self.allocator.free(bigger_chroma);
    }
    @memset(bigger_luma, 100);
    @memset(bigger_chroma, 128);
    const bigger_planes: CpuPlanes = .{
        .y = bigger_luma.ptr,
        .uv = bigger_chroma.ptr,
        .y_stride = bigger.lumaRowBytes(),
        .uv_stride = bigger.chromaRowBytes(),
        .bit_depth = 8,
    };
    const bigger_surface = self.importer.import(bigger, bigger_planes) catch |err| {
        report.add(false, "换分辨率用例：导入（{s}）", .{@errorName(err)});
        return;
    };
    defer bigger_surface.release();

    const before_rid = pipeline.outputTexture();
    const resized_output = pipeline.present(bigger_surface, pc) catch |err| {
        report.add(false, "换分辨率用例：present（{s}）", .{@errorName(err)});
        return;
    };
    report.add(
        resized_output.getId() != before_rid.getId(),
        "换分辨率后输出纹理被重建（RID 变了）",
        .{},
    );
    report.add(
        pipeline.width == bigger.width and pipeline.height == bigger.height,
        "管线尺寸跟上新分辨率（{d}x{d}）",
        .{ pipeline.width, pipeline.height },
    );

    // 把现场恢复成原尺寸那一帧：逐像素回读在下一帧做，读的是输出纹理的**最终**内容。
    // 少了这一步，回读拿到的是新尺寸那帧，已有的那条亮度比对会因为"画面完全变了"而红
    //（实测：最大偏差 98/255）。
    _ = pipeline.present(self.present_surface, pc) catch {};
}

/// 把呈现输出读回来，与 core 的色彩层算出的期望值逐像素比对（必须在下一帧做，
/// 理由见文件头的说明）。
fn verifyPresentOutput(self: *LunaSelfTest, report: *Report) void {
    const spec = self.present_spec;
    const pipeline = self.present orelse return;
    const rd = pipeline.rd;
    const pixels = @as(usize, spec.width) * spec.height;
    const want_bytes = pixels * 4;

    const staging = createStagingTexture(rd, spec.width, spec.height, .data_format_r8g8b8a8_unorm);
    defer if (rd.textureIsValid(staging)) rd.freeRid(staging);

    rd.submit();
    rd.sync();
    const copied = rd.textureCopy(
        pipeline.outputTexture(),
        staging,
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = @floatFromInt(spec.width), .y = @floatFromInt(spec.height), .z = 1 },
        0,
        0,
        0,
        0,
    ) == .ok;
    report.add(copied, "把呈现输出拷进暂存纹理", .{});

    rd.submit();
    rd.sync();
    var rgba = rd.textureGetData(staging, 0);
    defer rgba.deinit();
    report.add(
        rgba.size() == @as(i64, @intCast(want_bytes)),
        "RGBA 回读字节数 == 宽 x 高 x 4（实际 {d}）",
        .{rgba.size()},
    );
    if (rgba.size() != @as(i64, @intCast(want_bytes))) return;

    const base: [*]const u8 = @ptrFromInt(@intFromPtr(rgba.indexConst(0)));
    const layout = core.color.SampleLayout.right_justified_8;
    var gray_ok = true;
    var worst: u32 = 0;
    var row: usize = 0;
    while (row < spec.height) : (row += 1) {
        var col: usize = 0;
        while (col < spec.width) : (col += 1) {
            const at = (row * spec.width + col) * 4;
            const r = base[at];
            const g = base[at + 1];
            const b = base[at + 2];
            if (r != g or g != b) gray_ok = false;

            const code: f64 = @floatFromInt(self.present_luma.?[row * spec.width + col]);
            const y_norm = std.math.clamp(
                core.color.normalizeLuma(code, layout, .video),
                0.0,
                1.0,
            );
            const want: u32 = @intFromFloat(@round(y_norm * 255.0));
            const got: u32 = r;
            const diff = if (got > want) got - want else want - got;
            if (diff > worst) worst = diff;
        }
    }

    report.add(gray_ok, "每个像素都是中性灰（色度 128 在整条管线上不偏色）", .{});
    report.add(worst <= 2, "逐像素亮度与 core 色彩层的期望值一致（最大偏差 {d}/255，容差 2）", .{worst});
}

/// Metal 零拷贝（0015）：自己造一块 IOSurface 支撑的 CVPixelBuffer 喂进分发器。
///
/// 为什么能"自己造"：本仓库还没有硬解后端（ffvt 未落地），而这个导入器吃的正是
/// 硬解帧的形状（native_surface + CVPixelBuffer）。造假输入的代价只是几十行桥代码，
/// 换来的是零拷贝路径能在真机上被验证——包括"与像素缓冲行距不一致"这种一上手就会
/// 踩到的坑。
fn checkMetalImport(self: *LunaSelfTest, report: *Report) void {
    if (comptime metal_supported) {
        checkMetalImportMac(self, report);
    } else {
        report.note("跳过 Metal 零拷贝用例（当前平台不是 macOS）", .{});
    }
}

fn checkMetalImportMac(self: *LunaSelfTest, report: *Report) void {
    if (!self.dispatcher_ready) {
        report.add(false, "分发器没建起来，Metal 用例无法挂上去", .{});
        return;
    }

    const width: u32 = 64;
    const height: u32 = 48;
    const probe = bridge.nv_cv_probe_create(@intCast(width), @intCast(height)) orelse {
        report.add(false, "造一块 IOSurface 支撑的 NV12 像素缓冲", .{});
        return;
    };
    defer bridge.nv_cv_probe_destroy(probe);
    report.add(true, "造出 IOSurface 支撑的 NV12 像素缓冲（{d}x{d}）", .{ width, height });

    const luma = bridge.nv_cv_probe_luma(probe);
    const chroma = bridge.nv_cv_probe_chroma(probe);
    if (luma == null or chroma == null) {
        report.add(false, "两个平面都可写（缓冲已锁定）", .{});
        return;
    }
    report.add(true, "两个平面都可写（缓冲已锁定）", .{});
    const luma_stride: usize = @intCast(bridge.nv_cv_probe_luma_stride(probe));
    const chroma_stride: usize = @intCast(bridge.nv_cv_probe_chroma_stride(probe));

    // 期望值按**紧凑**布局留一份（纹理那边就是紧凑的），于是"缓冲行距与纹理行距
    // 不同"这件事被真正验证：别名若把行距搞错，逐行比对会立刻红。
    const luma_expect = self.allocator.alloc(u8, @as(usize, width) * height) catch return;
    const chroma_expect = self.allocator.alloc(u8, @as(usize, width) * (height / 2)) catch return;
    self.metal_luma_expect = luma_expect;
    self.metal_chroma_expect = chroma_expect;

    var row: usize = 0;
    while (row < height) : (row += 1) {
        var col: usize = 0;
        while (col < width) : (col += 1) {
            const value: u8 = @truncate(row * 3 + col);
            luma[row * luma_stride + col] = value;
            luma_expect[row * width + col] = value;
        }
    }
    row = 0;
    while (row < height / 2) : (row += 1) {
        var col: usize = 0;
        while (col < width) : (col += 1) {
            const value: u8 = @truncate(row * 5 + col * 2 + 1);
            chroma[row * chroma_stride + col] = value;
            chroma_expect[row * width + col] = value;
        }
    }
    report.note("像素缓冲行距：亮度 {d}、色度 {d}（纹理侧是紧凑的 {d}）", .{
        luma_stride, chroma_stride, width,
    });

    self.metal = metal_mod.MetalSurfaceImporter.initWithDevice(
        self.allocator,
        self.importer.rd,
        .{ .cpu_readback = true },
    ) catch |err| {
        report.add(false, "建 Metal 导入器（{s}）", .{@errorName(err)});
        return;
    };
    // 挂到分发器上：这一段同时验证 0014 的平台路由确实把帧送了过来。
    self.dispatcher.setPlatform(self.metal.?.asSurfaceImporter());

    const frame: VideoFrame = .{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = .nv12,
        .surface_kind = .native_surface,
        .native_handle = bridge.nv_cv_probe_pixel_buffer(probe),
        .cpu = .{ .bit_depth = 8 },
    };
    const before = self.dispatcher.stats();
    self.metal_surface = self.dispatcher.importFrame(frame) catch |err| {
        report.add(false, "把原生帧交给 Metal 导入器（{s}）", .{@errorName(err)});
        return;
    };
    self.have_metal_surface = true;

    const after = self.dispatcher.stats();
    report.add(after.platform == before.platform + 1, "原生帧被分给 Metal 导入器（platform 计数 {d}）", .{
        after.platform,
    });
    report.add(after.cpu == before.cpu, "走平台路径时没有动 CPU 计数（仍 {d}）", .{after.cpu});
    report.add(self.metal_surface.planes == .luma_chroma, "Metal 路径交出亮度 + 交织色度两块纹理", .{});
    report.add(self.metal_surface.raw_code_shift == 0, "Metal 8-bit 路径的移位是 0（8-bit 与移位无关）", .{});
    const metal_stats = self.metal.?.stats();
    report.add(metal_stats.in_flight == 1 and metal_stats.textures == 2, "导入器记账：在飞 {d} 帧、创建 {d} 块纹理", .{
        metal_stats.in_flight, metal_stats.textures,
    });
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

    var y_back = self.importer.rd.textureGetData(lumaRid(self.first), 0);
    defer y_back.deinit();
    var uv_back = self.importer.rd.textureGetData(chromaRid(self.first), 0);
    defer uv_back.deinit();
    var y10_back = self.importer.rd.textureGetData(lumaRid(self.ten), 0);
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

    // 分发器交出来的那块走的是同一条上传路径，同样要能逐字节读回。
    if (self.have_dispatched) {
        var dispatched_back = self.dispatcher.cpu.rd.textureGetData(lumaRid(self.dispatched), 0);
        defer dispatched_back.deinit();
        report.add(equalBytes(dispatched_back, y_want), "分发路径交出的纹理同样逐字节一致", .{});
    }

    if (comptime metal_supported) {
        verifyMetalSurface(self, &report, y_want);
    }

    if (self.have_present_surface) verifyPresentOutput(self, &report);

    report.note("第一阶段创建纹理 {d} 块、上传平面 {d} 次、孤儿 {d} 块", .{
        self.importer.stats().created,
        self.importer.stats().uploads,
        self.importer.stats().orphans,
    });

    self.teardown();
    report.note("TOTAL_FAILURES={d}", .{report.failures});
    return report.text();
}

/// Metal 零拷贝的像素级验证（只在 macOS 上被分析）。
///
/// **不能**直接 `textureGetData` 那块别名进来的纹理：Godot 的 Metal 驱动在
/// `drivers/metal/rendering_device_driver_metal.mm:585` 直接拒绝（实测，日志里会打出
/// 这条 driver 报错）并返回空数组——第一版就是这样"读回全零"。绕法是先在 GPU 内部
/// 把它拷到一块 Godot 自己创建的暂存纹理（带 CAN_COPY_TO / CAN_COPY_FROM / CPU_READ），
/// 再读暂存纹理。这条路也正是将来呈现管线要走的路：真出画时也是先算再读。
fn verifyMetalSurface(self: *LunaSelfTest, report: *Report, y_want: []const u8) void {
    if (!self.have_metal_surface) return;

    const width: u32 = 64;
    const height: u32 = 48;
    const luma_staging = createStagingTexture(self.importer.rd, width, height, .data_format_r8_unorm);
    const chroma_staging = createStagingTexture(self.importer.rd, width / 2, height / 2, .data_format_r8g8_unorm);
    defer {
        if (self.importer.rd.textureIsValid(luma_staging)) self.importer.rd.freeRid(luma_staging);
        if (self.importer.rd.textureIsValid(chroma_staging)) self.importer.rd.freeRid(chroma_staging);
    }

    self.importer.rd.submit();
    self.importer.rd.sync();
    const copied_luma = self.importer.rd.textureCopy(
        lumaRid(self.metal_surface),
        luma_staging,
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = @floatFromInt(width), .y = @floatFromInt(height), .z = 1 },
        0,
        0,
        0,
        0,
    ) == .ok;
    const copied_chroma = self.importer.rd.textureCopy(
        chromaRid(self.metal_surface),
        chroma_staging,
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = @floatFromInt(width / 2), .y = @floatFromInt(height / 2), .z = 1 },
        0,
        0,
        0,
        0,
    ) == .ok;
    report.add(copied_luma and copied_chroma, "把别名纹理拷进暂存纹理（GPU 内部拷贝）", .{});

    self.importer.rd.submit();
    self.importer.rd.sync();
    var metal_luma = self.importer.rd.textureGetData(luma_staging, 0);
    defer metal_luma.deinit();
    var metal_chroma = self.importer.rd.textureGetData(chroma_staging, 0);
    defer metal_chroma.deinit();
    report.add(equalBytes(metal_luma, self.metal_luma_expect.?), "Metal 零拷贝：亮度平面逐字节一致", .{});
    report.add(equalBytes(metal_chroma, self.metal_chroma_expect.?), "Metal 零拷贝：色度平面逐字节一致", .{});
    _ = y_want;
}

fn teardown(self: *LunaSelfTest) void {
    if (self.present) |*pipeline| {
        pipeline.deinit();
        self.present = null;
    }
    if (self.have_present_surface) {
        self.present_surface.release();
        self.have_present_surface = false;
    }
    if (self.present_luma) |b| {
        self.allocator.free(b);
        self.present_luma = null;
    }
    if (self.present_chroma) |b| {
        self.allocator.free(b);
        self.present_chroma = null;
    }
    if (self.have_metal_surface) {
        self.metal_surface.release();
        self.have_metal_surface = false;
    }
    if (comptime metal_supported) {
        if (self.metal) |*importer| {
            importer.deinit();
            self.metal = null;
        }
    }
    if (self.metal_luma_expect) |b| {
        self.allocator.free(b);
        self.metal_luma_expect = null;
    }
    if (self.metal_chroma_expect) |b| {
        self.allocator.free(b);
        self.metal_chroma_expect = null;
    }
    if (self.have_dispatched) {
        self.dispatched.release();
        self.have_dispatched = false;
    }
    if (self.dispatcher_ready) {
        self.dispatcher.deinit();
        self.dispatcher_ready = false;
    }
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
    // 本地 RenderingDevice **释放不了**：gdzig 的绑定里没有 `free_rendering_device`
    //（Godot 文档要求用它销毁本地设备），而 RenderingDevice 的基类是 `Object` 而不是
    // `RefCounted`，所以也没法走 `unreference()`。实测它因此固定在退出时的泄漏清单里
    // 占一条（`Leaked instance: RenderingDevice:…`）。这是绑定缺口，记在 0022 文档里；
    // 正式代码不用本地设备（只有自检用），所以影响限于测试进程。
    self.local_rd = null;
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

/// CPU 上传路径的纹理摆法是"亮度 + 交织色度"，这里把取用点收敛成两个小助手，
/// 免得每个断言里都写一遍 union 的字段路径。
fn lumaRid(surface: Surface) Rid {
    return surface.planes.luma_chroma.luma;
}

fn chromaRid(surface: Surface) Rid {
    return surface.planes.luma_chroma.chroma;
}

/// 自检用的暂存纹理：Godot 自己创建的、可拷贝来源也可是拷贝目标、还能被 CPU 读回。
/// 用来绕开"Metal 驱动不给读别名进来的纹理"这条限制（见 verify 里的注释）。
fn createStagingTexture(rd: *RenderingDevice, width: u32, height: u32, format: RenderingDevice.DataFormat) Rid {
    const fmt = RdTextureFormat.init();
    defer _ = fmt.unreference();
    const view = RdTextureView.init();
    defer _ = view.unreference();
    fmt.setWidth(width);
    fmt.setHeight(height);
    fmt.setFormat(format);
    fmt.setUsageBits(.{
        .texture_usage_sampling_bit = true,
        .texture_usage_can_copy_to_bit = true,
        .texture_usage_can_copy_from_bit = true,
        .texture_usage_cpu_read_bit = true,
    });
    return rd.textureCreate(fmt, view, .{});
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
