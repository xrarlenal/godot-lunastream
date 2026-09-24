//! 表面导入器的公共形状：把"解码帧 → 可采样的 GPU 纹理"这件事抽象成一张 vtable，
//! 让呈现管线不必知道帧是从 CPU 传上来的（软解），还是被零拷贝别名进来的
//! （Metal / D3D12 / Vulkan 硬解）。
//!
//! 形状与 `core/backend.zig` 的解码后端一致（ptr + vtable）：这样测试与分发都能
//! 用同一个模式写，读代码的人也只学一次。
//!
//! ## 为什么"释放"用 core 的 VoidClosure
//!
//! 两条路径的归还对象完全不同（CPU 路径要还纹理池的槽位，平台路径要告诉解码池
//! "这块原生表面用完了"），但**形状**一样：无参、无返回、调用一次。0004 的
//! `VoidClosure` 正好是这个形状，且它本来就带着"帧用完以后调用"的语义
//! （`core/backend.zig` 的 `VideoFrame.release_hook` 就是它）。

const std = @import("std");

const godot = @import("godot");
const Rid = godot.builtin.Rid;

const core = @import("core");
const Spec = core.texture_pool.Spec;
const VoidClosure = core.closure.VoidClosure;
const VideoFrame = core.backend.VideoFrame;

/// 导入结果里纹理的摆法。两条路径的差别就集中在这里。
pub const PlaneSet = union(enum) {
    /// 一块纹理同时带着亮度与色度（平台 NV12 导入的常见形态）。
    interleaved_single: Rid,
    /// 两块：亮度 + 交织 CbCr（CPU 上传路径，见 cpu_frame_importer.zig）。
    luma_chroma: struct { luma: Rid, chroma: Rid },

    /// 供着色器绑定用的纹理列表（顺序固定：亮度在前）。
    pub fn toArray(self: PlaneSet) [2]?Rid {
        return switch (self) {
            .interleaved_single => |rid| .{ rid, null },
            .luma_chroma => |pair| .{ pair.luma, pair.chroma },
        };
    }
};

/// 一次导入的结果。
pub const Surface = struct {
    spec: Spec,
    planes: PlaneSet,
    /// 着色器在读这一帧之前要把 16 位样值**右移**多少位（0 或 6）。
    ///
    /// 为什么需要它：本仓库的软解路径在 shim 里就把 10-bit 统一成右对齐了
    /// （0011：P010 左对齐 → 原地右移 6 位），所以 CPU 上传路径恒为 0。但平台路径
    /// 拿到的原生表面不归我们管：VAAPI 的 P010 与 CoreVideo 的 x420 都是**左对齐**
    /// （码值在高位、低 6 位是零），只能用右移位还原。
    ///
    /// 这是从源工程搬平台导入器时才看清的一条：**左对齐不是"另一种像素格式"，而是
    /// 同一份数据的一个移位**，所以它属于"帧的元数据"，不属于"格式"。
    raw_code_shift: u32 = 0,
    /// 消费者用完必须调 `release()`。
    release_hook: VoidClosure,

    pub fn release(self: Surface) void {
        self.release_hook.call();
    }
};

pub const Error = error{
    /// 这帧不是本导入器能吃的（分发器负责在调用前判对，真发生了就是接线错误）。
    UnsupportedFrame,
    /// 帧还没准备好（平台侧资源尚未就绪，下一帧再试即可）。
    NotReady,
    /// 帧本身是坏的（尺寸/格式不合法）。丢掉这一帧，不必换架构。
    BadFrame,
    /// 这一帧失败但属于暂时性（驱动忙、等待超时）。**不要**据此降级整条会话。
    TransientFailure,
    /// 这台机器/这个渲染驱动**根本不支持**这条零拷贝路径（例如 Windows 上 Godot
    /// 跑在与解码器不同的适配器上）。
    ///
    /// 与 `TransientFailure` 的区别是这一步的要点，也是从源工程学来的：只有
    /// "能力不可用"才允许选择器**永久**放弃这条路径并降级到 CPU 拷贝。两者混在
    /// 一起的后果是——网络或驱动的一次抖动，就把整条会话从零拷贝降成每帧读回，
    /// 而使用者只会看到"性能莫名其妙掉了"。
    CapabilityUnavailable,
    /// 没有可用的 RenderingDevice（`--headless`）。
    NoRenderingDevice,
    /// 纹理池取满：消费者没归还，属于背压。
    PoolExhausted,
    /// 创建或上传纹理失败。
    ImportFailed,
    OutOfMemory,
};

pub const SurfaceImporter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 导入一帧。调用方保证 `frame.surface_kind` 与本导入器匹配。
        import_frame: *const fn (*anyopaque, frame: VideoFrame) Error!Surface,
        /// 释放实现自身（已经发出去的表面由各自的 release_hook 负责）。
        deinit: *const fn (*anyopaque) void,
    };

    pub fn importFrame(self: SurfaceImporter, frame: VideoFrame) Error!Surface {
        return self.vtable.import_frame(self.ptr, frame);
    }

    pub fn deinit(self: SurfaceImporter) void {
        self.vtable.deinit(self.ptr);
    }
};
