//! CPU 帧导入器：把软解出来的 CPU 平面上传进 RenderingDevice 纹理，并按 core 的
//! 纹理池轮换复用。它是 `surface_importer.SurfaceImporter` 的软解实现。
//!
//! ## 为什么必须"上传"
//!
//! 软解帧在系统内存里，**没有可别名的系统句柄**（对比硬解：CVPixelBuffer、
//! ID3D11Texture2D、dma-buf 都能直接导入成 GPU 纹理），所以这条路上必然有一次
//! CPU→GPU 拷贝。这一步的全部优化空间只剩两件事：
//!
//! 1. **别每次新建纹理**——交给 core 的 `TexturePool` 轮换（稳定态零分配）；
//! 2. **拷贝本身别多做**——行距与紧凑布局一致时直接整块上传。
//!
//! ## 两块纹理，不是一个
//!
//! NV12 / 右对齐 16 位半平面的天然形状就是"一张全分辨率亮度 + 一张半分辨率交织
//! 色度"，所以这里对应两张 RD 纹理：
//!
//! | 平面 | 8-bit | 10-bit | 纹理宽高 |
//! |---|---|---|---|
//! | 亮度 | `R8_UNORM` | `R16_UNORM` | `width × height` |
//! | 色度 | `R8G8_UNORM` | `R16G16_UNORM` | `width/2 × height/2` |
//!
//! 这样每张纹理的行宽都恰好等于平面的一行字节数（8-bit 色度：`w/2 * 2 = w`；
//! 10-bit 色度：`w/2 * 4 = 2w`），上传就是整块搬运。
//!
//! ## 线程约定
//!
//! 所有 RenderingDevice 调用都必须在主线程（与 0007 的约定一致：worker 只解码，
//! 呈现与 GPU pass 在主线程）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const RenderingServer = godot.class.RenderingServer;
const RdTextureFormat = godot.class.RdTextureFormat;
const RdTextureView = godot.class.RdTextureView;
const Rid = godot.builtin.Rid;
const PackedByteArray = godot.builtin.PackedByteArray;

const core = @import("core");
const pool_mod = core.texture_pool;
const Spec = pool_mod.Spec;
const TexturePool = pool_mod.TexturePool;
const CpuPlanes = core.backend.CpuPlanes;
const VideoFrame = core.backend.VideoFrame;

const importer_iface = @import("surface_importer.zig");
const Surface = importer_iface.Surface;
const SurfaceImporter = importer_iface.SurfaceImporter;
const Error = importer_iface.Error;

/// 池深度：与 core 的表面数量公式同源
/// （`requiredPoolDepth(队列可用 7, frame_latency 4) = 7 + 1 + 4`）。
pub const kPoolDepth: usize = 12;

pub const Options = struct {
    /// 让纹理可以被 `textureGetData` 读回 CPU。
    ///
    /// 打开它会同时置两个用途位，两个都是读回的必要条件：
    ///   * `CAN_COPY_FROM`——引擎文档写明"texture requires the
    ///     TEXTURE_USAGE_CAN_COPY_FROM_BIT to be retrieved"，少了它
    ///     `textureGetData` 只返回空的 PackedByteArray（实测 size = 0）；
    ///   * `CPU_READ`——常驻系统内存，读回更快（Godot 注释原文）。
    ///
    /// 默认**关**：这两个位对生产路径都只是白白的带宽/内存代价。自检要验证
    /// "上传的字节确实原样进了纹理"，所以它开着。
    cpu_readback: bool = false,
};

pub const Stats = struct {
    /// 累计创建过的纹理数（含已被作废的）。
    created: u64,
    /// 当前在用槽位数。
    in_use: usize,
    /// 当前代数下已创建的槽位数（= 当前持有的纹理对数）。
    allocated: usize,
    /// 因规格变化被留到销毁时才释放的旧纹理数。
    orphans: usize,
    /// 累计上传的平面数（亮度 + 色度各算一次）。
    uploads: u64,
};

pub const CpuFrameImporter = struct {
    const Slot = struct {
        // `Rid.init()` 是运行期调用（不能当字段默认值），所以用 `valid` 作为
        // 唯一的"这块槽位有纹理"判据，两个 RID 只在 valid 为真时被读。
        y: Rid = undefined,
        uv: Rid = undefined,
        valid: bool = false,
    };

    /// 归还凭据。`Surface.release_hook` 只有"一个上下文指针 + 一个函数指针"，
    /// 没有地方放 `self`，所以每个槽位自带一张凭据：上下文指向它，函数从它身上
    /// 取得"哪个导入器、哪个槽位"。
    ///
    /// 用槽位自带的凭据而不是每帧分配：**取帧与归还都在稳定态零分配**，
    /// 且凭据地址在槽位生命周期内稳定（槽位被独占持有）。
    const Ticket = struct {
        owner: *CpuFrameImporter = undefined,
        slot: usize = 0,
    };

    allocator: Allocator,
    rd: *RenderingDevice,
    options: Options = .{},
    pool: TexturePool(kPoolDepth) = .{},
    slots: [kPoolDepth]Slot = @splat(.{}),
    tickets: [kPoolDepth]Ticket = @splat(.{}),
    /// 规格变化时有槽位在用：旧纹理不能立刻销毁（消费者手上可能是它），
    /// 留到 deinit 统一释放。这在真实使用里是罕见路径（分辨率/位深在流中途换），
    /// 所以用定长数组就够，且**记数**而不是假装没发生。
    orphans: [kPoolDepth]Rid = undefined,
    orphan_count: usize = 0,
    created_textures: u64 = 0,
    uploads: u64 = 0,

    /// 建纹理时用的**可复用**描述符对象。
    ///
    /// 0022 的实测：gdzig 用 `classdbConstructObject` + `initRef()` 造出来的这类辅助
    /// 对象，引用计数归零后仍会留在 ObjectDB 里（退出时报泄漏）。每建一块纹理就新建
    /// 一对，泄漏数就随槽位数涨（12 槽 = 12 对）。复用一个对象后它只泄漏一份，
    /// 而且省掉了每次创建的引擎调用。
    format: *RdTextureFormat = undefined,
    view: *RdTextureView = undefined,

    /// 用主线程的（非本地）RenderingDevice 构造——生产路径用这个。
    pub fn init(allocator: Allocator, options: Options) Error!CpuFrameImporter {
        const rd = RenderingServer.getRenderingDevice() orelse return Error.NoRenderingDevice;
        return initWithDevice(allocator, rd, options);
    }

    /// 用指定的 RenderingDevice 构造。
    ///
    /// 存在的理由：自检要"上传后读回比对"，而**非本地设备的 `textureUpdate` 结果
    /// 读不回来**——它只是把命令记进引擎的命令缓冲，`submit()`/`sync()` 在非本地
    /// 设备上又会被拒绝（"Only local devices can submit and sync."），跨帧再读也是
    /// 全零。本地设备没有这个限制，所以自检用一个本地设备来验证上传路径。
    ///
    /// 代价要说清楚：本地设备的用例证明的是导入器**逻辑**（布局、槽位、上传调用）
    /// 正确，不证明主设备上一样；主设备上的正确性要到呈现管线那一步用"出画"来验。
    pub fn initWithDevice(allocator: Allocator, rd: *RenderingDevice, options: Options) Error!CpuFrameImporter {
        // 描述符对象在这里建一次、之后反复改写（见字段注释：少建 = 少泄漏）。
        return .{
            .allocator = allocator,
            .rd = rd,
            .options = options,
            .format = RdTextureFormat.init(),
            .view = RdTextureView.init(),
        };
    }

    pub fn deinit(self: *CpuFrameImporter) void {
        _ = self.format.unreference();
        _ = self.view.unreference();
        for (&self.slots) |*slot| {
            if (slot.valid) {
                self.freeRid(slot.y);
                self.freeRid(slot.uv);
                slot.* = .{};
            }
        }
        for (self.orphans[0..self.orphan_count]) |rid| self.freeRid(rid);
        self.orphan_count = 0;
        self.pool = .{};
    }

    /// 让本导入器以接口形式暴露（分发器与呈现管线只认接口）。
    pub fn asSurfaceImporter(self: *CpuFrameImporter) SurfaceImporter {
        return .{ .ptr = self, .vtable = &.{
            .import_frame = importFrameVtable,
            .deinit = deinitVtable,
        } };
    }

    fn importFrameVtable(ptr: *anyopaque, frame: VideoFrame) Error!Surface {
        const self: *CpuFrameImporter = @ptrCast(@alignCast(ptr));
        return self.importFrame(frame);
    }

    fn deinitVtable(ptr: *anyopaque) void {
        const self: *CpuFrameImporter = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// 接口入口：从解码帧里取 CPU 平面。
    pub fn importFrame(self: *CpuFrameImporter, frame: VideoFrame) Error!Surface {
        if (frame.surface_kind != .cpu_nv12) return Error.UnsupportedFrame;
        const spec: Spec = .{
            .width = @intCast(frame.width),
            .height = @intCast(frame.height),
            .bit_depth = frame.cpu.bit_depth,
        };
        return self.import(spec, frame.cpu);
    }

    /// 导入一帧。返回的 `Surface` 必须在用完后 `release()`。
    pub fn import(self: *CpuFrameImporter, spec: Spec, planes: CpuPlanes) Error!Surface {
        if (spec.width == 0 or spec.height == 0) return Error.ImportFailed;
        const y_ptr = planes.y orelse return Error.ImportFailed;
        const uv_ptr = planes.uv orelse return Error.ImportFailed;

        switch (self.pool.setSpec(spec)) {
            .unchanged => {},
            .changed_idle => self.freeAllSlots(),
            .changed_busy => self.orphanAllSlots(),
        }

        const lease = self.pool.acquire() orelse return Error.PoolExhausted;
        const slot = &self.slots[lease.index];
        if (lease.fresh) {
            slot.y = self.createTexture(spec, false);
            slot.uv = self.createTexture(spec, true);
            slot.valid = true;
        }

        self.uploadLuma(slot.y, spec, y_ptr, planes.y_stride) catch |err| {
            _ = self.pool.release(lease.index);
            return err;
        };
        self.uploadChroma(slot.uv, spec, uv_ptr, planes.uv_stride) catch |err| {
            _ = self.pool.release(lease.index);
            return err;
        };

        const ticket = &self.tickets[lease.index];
        ticket.* = .{ .owner = self, .slot = lease.index };

        return .{
            .spec = spec,
            .planes = .{ .luma_chroma = .{ .luma = slot.y, .chroma = slot.uv } },
            .release_hook = .{ .ctx = ticket, .func = releaseTicket },
        };
    }

    pub fn stats(self: *const CpuFrameImporter) Stats {
        return .{
            .created = self.created_textures,
            .in_use = self.pool.inUseCount(),
            .allocated = self.pool.allocatedCount(),
            .orphans = self.orphan_count,
            .uploads = self.uploads,
        };
    }

    /// 当前规格代数（每次作废 +1，用来在排查时分辨"这帧用的是哪一代纹理"）。
    pub fn generation(self: *const CpuFrameImporter) u32 {
        return self.pool.generation;
    }

    // -----------------------------------------------------------------------
    // 内部
    // -----------------------------------------------------------------------

    fn releaseTicket(ctx: ?*anyopaque) void {
        const ticket: *Ticket = @ptrCast(@alignCast(ctx.?));
        _ = ticket.owner.pool.release(ticket.slot);
    }

    fn freeRid(self: *CpuFrameImporter, rid: Rid) void {
        if (rid.isValid()) self.rd.freeRid(rid);
    }

    fn freeAllSlots(self: *CpuFrameImporter) void {
        for (&self.slots) |*slot| {
            if (slot.valid) {
                self.freeRid(slot.y);
                self.freeRid(slot.uv);
                slot.* = .{};
            }
        }
    }

    fn orphanAllSlots(self: *CpuFrameImporter) void {
        for (&self.slots) |*slot| {
            if (!slot.valid) continue;
            self.pushOrphan(slot.y);
            self.pushOrphan(slot.uv);
            slot.* = .{};
        }
    }

    fn pushOrphan(self: *CpuFrameImporter, rid: Rid) void {
        if (!rid.isValid()) return;
        if (self.orphan_count >= self.orphans.len) {
            // 极端路径（流中途反复换规格，且每次都还有帧在飞）。宁可留着不释放，
            // 也不能释放可能还在被采样的纹理；留痕以便排查。
            std.log.warn("cpu_frame_importer: 孤儿纹理表已满，{d} 块留到销毁时释放", .{self.orphan_count});
            return;
        }
        self.orphans[self.orphan_count] = rid;
        self.orphan_count += 1;
    }

    fn createTexture(self: *CpuFrameImporter, spec: Spec, is_chroma: bool) Rid {
        self.format.setWidth(if (is_chroma) (spec.width + 1) / 2 else spec.width);
        self.format.setHeight(if (is_chroma) (spec.height + 1) / 2 else spec.height);
        self.format.setFormat(if (is_chroma) self.chromaFormat(spec) else self.lumaFormat(spec));
        self.format.setUsageBits(.{
            .texture_usage_sampling_bit = true,
            .texture_usage_can_update_bit = true,
            .texture_usage_can_copy_from_bit = self.options.cpu_readback,
            .texture_usage_cpu_read_bit = self.options.cpu_readback,
        });

        self.created_textures += 1;
        return self.rd.textureCreate(self.format, self.view, .{});
    }

    fn lumaFormat(_: *const CpuFrameImporter, spec: Spec) RenderingDevice.DataFormat {
        return if (spec.bit_depth > 8)
            RenderingDevice.DataFormat.data_format_r16_unorm
        else
            RenderingDevice.DataFormat.data_format_r8_unorm;
    }

    fn chromaFormat(_: *const CpuFrameImporter, spec: Spec) RenderingDevice.DataFormat {
        return if (spec.bit_depth > 8)
            RenderingDevice.DataFormat.data_format_r16g16_unorm
        else
            RenderingDevice.DataFormat.data_format_r8g8_unorm;
    }

    fn uploadLuma(
        self: *CpuFrameImporter,
        rid: Rid,
        spec: Spec,
        data: [*]const u8,
        stride: u32,
    ) Error!void {
        try self.uploadPlane(rid, data, spec.lumaRowBytes(), stride, spec.height);
    }

    fn uploadChroma(
        self: *CpuFrameImporter,
        rid: Rid,
        spec: Spec,
        data: [*]const u8,
        stride: u32,
    ) Error!void {
        try self.uploadPlane(rid, data, spec.chromaRowBytes(), stride, (spec.height + 1) / 2);
    }

    /// 上传一个平面。行距等于紧凑行宽时整块搬运；否则逐行拷贝到紧凑暂存区
    /// （契约允许行距大于行宽，虽然当前 shim 给的是紧凑布局）。
    fn uploadPlane(
        self: *CpuFrameImporter,
        rid: Rid,
        data: [*]const u8,
        row_bytes: u32,
        stride: u32,
        rows: u32,
    ) Error!void {
        var buf = PackedByteArray.init();
        defer buf.deinit();

        const tight_bytes = @as(usize, row_bytes) * rows;
        const total = if (stride == row_bytes) tight_bytes else @as(usize, stride) * rows;
        if (buf.resize(@intCast(total)) < 0) return Error.ImportFailed;
        const dst = writeBase(&buf);

        if (stride == row_bytes) {
            @memcpy(dst[0..tight_bytes], data[0..tight_bytes]);
        } else {
            var row: u32 = 0;
            while (row < rows) : (row += 1) {
                const src_row = data + @as(usize, row) * stride;
                const dst_row = dst + @as(usize, row) * row_bytes;
                @memcpy(dst_row[0..row_bytes], src_row[0..row_bytes]);
            }
        }

        // textureUpdate 返回的是 Godot 的 Error 枚举（不是 Zig 错误集）。
        if (self.rd.textureUpdate(rid, 0, buf) != .ok) return Error.ImportFailed;
        self.uploads += 1;
    }
};

/// 取 PackedByteArray 的可写数据基址。
///
/// **为什么不能直接用 `ptr()`**：gdzig 的 `PackedByteArray` 是不透明包装
/// （`_: [16]u8`，里面放的是 CowData 的句柄），`ptr()` 返回的是**包装自己的
/// 地址**，不是字节数据的地址。第一版把 `ptr()` 当缓冲区用，往 16 字节的结构里
/// 写几万字节，实测直接 SIGSEGV。
///
/// GDExtension 的 C API 也没有"取整块数据指针"的入口，只有逐下标的
/// `packed_byte_array_operator_index`。Godot 的 PackedByteArray 底层是连续存储
/// （`CowData<u8>`），所以「取下标 0 的地址 + 按长度写」成立——但这是对"连续"
/// 这一实现事实的依赖，因此在这里单点封装并写明：万一上游换成非连续表示，
/// 只有这一处需要改。
fn writeBase(buf: *PackedByteArray) [*]u8 {
    // 单元素指针 → 多项指针：Zig 不允许直接 @ptrCast，走一次整数转换。
    return @ptrFromInt(@intFromPtr(buf.index(0)));
}

comptime {
    // 池深度必须与 core 的公式同源，改了这边忘了那边会在运行期变成"莫名其妙的背压"。
    const required = core.decode_scheduler.requiredPoolDepth(
        core.decode_scheduler.kDecodeAheadCapacity - 1,
        4,
    );
    if (kPoolDepth < required) {
        @compileError("纹理池深度不能小于 core 的表面数量公式算出的下限");
    }
}
