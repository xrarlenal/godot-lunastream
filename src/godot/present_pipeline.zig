//! 呈现管线：把导入进 GPU 的两块平面（亮度 + 交织色度）跑一遍 NV12 到 RGBA 的
//! compute，写进一块**稳定的输出纹理**。
//!
//! 为什么输出纹理要稳定：`VideoStreamPlayer` 拿的是纹理 RID，只要它变了，所有引用
//! 它的材质都要跟着重建。所以这里每帧只往同一块输出纹理里写，RID 自始至终不变——这
//! 正是 PLAN 里"稳定的 Texture2DRD（每帧只重指 RID）"那句话的落点。
//!
//! 数学全在推送常量里（见 core/push_constants.zig 与 src/shaders/nv12_to_rgba.comp），
//! 这里只负责建管线、绑资源、派发。

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const RenderingDevice = godot.class.RenderingDevice;
const RdShaderSource = godot.class.RdShaderSource;
const RdUniform = godot.class.RdUniform;
const RdSamplerState = godot.class.RdSamplerState;
const RdTextureFormat = godot.class.RdTextureFormat;
const RdTextureView = godot.class.RdTextureView;
const Rid = godot.builtin.Rid;
const Array = godot.builtin.Array;
const Variant = godot.builtin.Variant;
const String = godot.builtin.String;
const PackedByteArray = godot.builtin.PackedByteArray;

const core = @import("core");
const PushConstants = core.push_constants.Nv12PushConstants;

const importer_iface = @import("surface_importer.zig");
const Surface = importer_iface.Surface;

const shaders = @import("shaders");

/// 着色器源码在编译期嵌进二进制：它是实现的一部分，不该依赖运行时的文件布局。
const shader_src = shaders.nv12_to_rgba;

/// compute 着色器里的 local_size_x/y，派发时用它把分辨率向上取整。
const workgroup = 8;

pub const Options = struct {
    /// 让输出纹理可以被读回 CPU（自检用）。生产路径不需要，开着只是白花带宽。
    enable_readback: bool = false,
};

pub const Error = error{
    ShaderCompileFailed,
    PipelineCreateFailed,
    UniformSetCreateFailed,
    TextureCreateFailed,
    UnsupportedPlaneSet,
    OutOfMemory,
};

pub const PresentPipeline = struct {
    allocator: Allocator,
    rd: *RenderingDevice,
    options: Options = .{},
    width: u32,
    height: u32,
    shader: Rid = undefined,
    pipeline: Rid = undefined,
    sampler: Rid = undefined,
    /// 稳定的输出纹理：RGBA8，每帧只往它里面写，RID 不变。
    output: Rid = undefined,
    /// 缓存一组（亮度, 色度）对应的 uniform set。软解导入器会复用纹理，所以这个
    /// 缓存命中率很高；只有换了纹理对才重建。
    uniform_set: Rid = undefined,
    cached_luma: Rid = undefined,
    cached_chroma: Rid = undefined,
    presents: u64 = 0,

    pub fn init(
        allocator: Allocator,
        rd: *RenderingDevice,
        width: u32,
        height: u32,
        options: Options,
    ) Error!PresentPipeline {
        var self: PresentPipeline = .{
            .allocator = allocator,
            .rd = rd,
            .options = options,
            .width = width,
            .height = height,
        };

        // 1) GLSL 到 SPIR-V 再到 shader RID。Godot 自带 glslang，所以运行期编得动。
        const source = RdShaderSource.init();
        defer _ = source.unreference();
        const stage_src = String.fromUtf8(shader_src) catch return Error.ShaderCompileFailed;
        source.setLanguage(.shader_language_glsl);
        source.setStageSource(.shader_stage_compute, stage_src);

        const spirv = rd.shaderCompileSpirvFromSource(source, .{}) orelse
            return Error.ShaderCompileFailed;
        defer _ = spirv.unreference();

        // `shaderCompileSpirvFromSource` 在 GLSL 有错时**不会返回 null**——它返回一个
        // 带着错误信息的对象，直接 shaderCreateFromSpirv 只会得到一句
        // "Can't create a shader from an errored bytecode"。所以这里必须把阶段的
        // 编译错误读出来打到日志里，否则排查时只能看到那句没头没尾的话。
        const compile_error = spirv.getStageCompileError(.shader_stage_compute);
        if (!compile_error.isEmpty()) {
            // 只报"编译失败"与阶段名：gdzig 的 String 没有到切片的转换入口，取不到
            // 具体信息。要看 GLSL 的报错，用 Godot 编辑器打开同一份 .comp 手工编一次。
            std.log.err("nv12_to_rgba.comp 编译失败（compute 阶段）", .{});
            return Error.ShaderCompileFailed;
        }
        self.shader = rd.shaderCreateFromSpirv(spirv, .{});
        if (!self.shader.isValid()) return Error.ShaderCompileFailed;

        // 2) compute 管线。
        self.pipeline = rd.computePipelineCreate(self.shader, .{});
        if (!self.pipeline.isValid()) return Error.PipelineCreateFailed;

        // 3) 采样器：线性过滤加边缘钳位。色度是半分辨率，线性采样才是正确的 4:2:0
        //    上采样味道（最近邻会给出明显锯齿）。
        const sampler_state = RdSamplerState.init();
        defer _ = sampler_state.unreference();
        sampler_state.setMagFilter(.sampler_filter_linear);
        sampler_state.setMinFilter(.sampler_filter_linear);
        sampler_state.setMipFilter(.sampler_filter_linear);
        sampler_state.setRepeatU(.sampler_repeat_mode_clamp_to_edge);
        sampler_state.setRepeatV(.sampler_repeat_mode_clamp_to_edge);
        sampler_state.setRepeatW(.sampler_repeat_mode_clamp_to_edge);
        self.sampler = rd.samplerCreate(sampler_state);
        if (!self.sampler.isValid()) return Error.TextureCreateFailed;

        // 4) 输出纹理：RGBA8、可被存储图像写入、也可被采样。
        self.output = self.createOutputTexture() catch return Error.TextureCreateFailed;
        return self;
    }

    pub fn deinit(self: *PresentPipeline) void {
        if (self.uniform_set.isValid()) self.rd.freeRid(self.uniform_set);
        if (self.output.isValid()) self.rd.freeRid(self.output);
        if (self.sampler.isValid()) self.rd.freeRid(self.sampler);
        if (self.pipeline.isValid()) self.rd.freeRid(self.pipeline);
        if (self.shader.isValid()) self.rd.freeRid(self.shader);
        self.uniform_set = .init();
        self.output = .init();
        self.sampler = .init();
        self.pipeline = .init();
        self.shader = .init();
    }

    /// 输出纹理的 RID：`VideoStreamPlayer` 拿到的就是它，跨帧不变。
    pub fn outputTexture(self: *const PresentPipeline) Rid {
        return self.output;
    }

    /// 跑一遍 compute，把这一帧写进输出纹理，返回输出纹理 RID（稳定）。
    pub fn present(self: *PresentPipeline, surface: Surface, pc: PushConstants) Error!Rid {
        const pair = switch (surface.planes) {
            .luma_chroma => |p| p,
            // 平台路径若只给一块交织纹理，本步还没做那条分支（见文档的已知限制）。
            .interleaved_single => return Error.UnsupportedPlaneSet,
        };

        if (!self.uniform_set.isValid() or
            self.cached_luma.getId() != pair.luma.getId() or
            self.cached_chroma.getId() != pair.chroma.getId())
        {
            try self.rebuildUniformSet(pair.luma, pair.chroma);
        }

        const list = self.rd.computeListBegin();
        self.rd.computeListBindComputePipeline(list, self.pipeline);
        self.rd.computeListBindUniformSet(list, self.uniform_set, 0);
        var pc_bytes = pushConstantBytes(pc);
        defer pc_bytes.deinit();
        self.rd.computeListSetPushConstant(list, pc_bytes, @sizeOf(PushConstants));
        self.rd.computeListDispatch(
            list,
            (self.width + workgroup - 1) / workgroup,
            (self.height + workgroup - 1) / workgroup,
            1,
        );
        self.rd.computeListEnd();
        self.presents += 1;
        return self.output;
    }

    // -----------------------------------------------------------------------
    // 内部
    // -----------------------------------------------------------------------

    fn createOutputTexture(self: *PresentPipeline) !Rid {
        const fmt = RdTextureFormat.init();
        defer _ = fmt.unreference();
        const view = RdTextureView.init();
        defer _ = view.unreference();
        fmt.setWidth(self.width);
        fmt.setHeight(self.height);
        fmt.setFormat(.data_format_r8g8b8a8_unorm);
        fmt.setUsageBits(.{
            .texture_usage_sampling_bit = true,
            .texture_usage_storage_bit = true,
            .texture_usage_can_copy_from_bit = self.options.enable_readback,
            .texture_usage_cpu_read_bit = self.options.enable_readback,
        });
        return self.rd.textureCreate(fmt, view, .{});
    }

    fn rebuildUniformSet(self: *PresentPipeline, luma: Rid, chroma: Rid) Error!void {
        if (self.uniform_set.isValid()) {
            self.rd.freeRid(self.uniform_set);
            self.uniform_set = .init();
        }

        const u_luma = RdUniform.init();
        defer _ = u_luma.unreference();
        u_luma.setUniformType(.uniform_type_sampler_with_texture);
        u_luma.setBinding(0);
        u_luma.addId(self.sampler);
        u_luma.addId(luma);

        const u_chroma = RdUniform.init();
        defer _ = u_chroma.unreference();
        u_chroma.setUniformType(.uniform_type_sampler_with_texture);
        u_chroma.setBinding(1);
        u_chroma.addId(self.sampler);
        u_chroma.addId(chroma);

        const u_out = RdUniform.init();
        defer _ = u_out.unreference();
        u_out.setUniformType(.uniform_type_image);
        u_out.setBinding(2);
        u_out.addId(self.output);

        var uniforms: Array = .init();
        defer uniforms.deinit();
        uniforms.pushBack(Variant.init(*RdUniform, u_luma));
        uniforms.pushBack(Variant.init(*RdUniform, u_chroma));
        uniforms.pushBack(Variant.init(*RdUniform, u_out));

        self.uniform_set = self.rd.uniformSetCreate(uniforms, self.shader, 0);
        if (!self.uniform_set.isValid()) return Error.UniformSetCreateFailed;
        self.cached_luma = luma;
        self.cached_chroma = chroma;
    }
};

/// 把推送常量按字节交给 RD。
///
/// 每次 present 新建一个 48 字节的 PackedByteArray，这是本步已知的一点小开销。
/// 先做对：等呈现管线接上真实播放、有了帧率数据，再决定要不要复用固定缓冲。
fn pushConstantBytes(pc: PushConstants) PackedByteArray {
    var buf = PackedByteArray.init();
    const bytes = std.mem.asBytes(&pc);
    if (buf.resize(@intCast(bytes.len)) < 0) return buf;
    const dst: [*]u8 = @ptrFromInt(@intFromPtr(buf.index(0)));
    @memcpy(dst[0..bytes.len], bytes);
    return buf;
}
