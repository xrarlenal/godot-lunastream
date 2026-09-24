//! d3d11.zig — Direct3D 11 device/context/texture surface used by the video
//! interop path. Transcribed from d3d11.h, d3d11_3.h (which is where mingw-w64
//! declares ID3D11Fence and ID3D11DeviceContext4), d3dcommon.h, dxgiformat.h.
//!
//! The inheritance chains here are deep (ID3D11Device5 : Device4 : Device3 :
//! Device2 : Device1 : Device). Rather than restate every slot, the higher
//! vtables EMBED the lower vtable as their first field — extern-struct layout
//! makes that byte-identical to flattening, and it keeps the slot arithmetic
//! honest. Only the methods the port actually calls are typed; every other
//! slot is an opaque pointer placeholder that preserves index position.

const std = @import("std");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const ULONG = com.ULONG;
const UINT = com.UINT;
const DWORD = com.DWORD;
const BOOL = com.BOOL;
const WINBOOL = com.WINBOOL;
const HANDLE = com.HANDLE;
const HMODULE = com.HMODULE;
const LPCWSTR = com.LPCWSTR;
const DXGI_FORMAT = dxgi.DXGI_FORMAT;

pub const UINT64 = u64;

// Opaque resource/view/shader types — the port only ever holds and forwards
// these pointers, never introspects them.
pub const ID3D11Resource = opaque {};
pub const ID3D11Buffer = opaque {};
pub const ID3D11ComputeShader = opaque {};
pub const ID3D11ClassLinkage = opaque {};
pub const ID3D11ClassInstance = opaque {};
pub const ID3D11UnorderedAccessView = opaque {};
pub const ID3D11ShaderResourceView = opaque {};

// ---------------------------------------------------------------------------
// Enums / flags (d3d11.h, d3dcommon.h)
// ---------------------------------------------------------------------------
pub const D3D_DRIVER_TYPE = i32;
pub const D3D_DRIVER_TYPE_UNKNOWN: D3D_DRIVER_TYPE = 0;
pub const D3D_DRIVER_TYPE_HARDWARE: D3D_DRIVER_TYPE = 1;
// Software rasterizer fallback (d3dcommon.h) — used where no GPU is present,
// e.g. CI runners.
pub const D3D_DRIVER_TYPE_WARP: D3D_DRIVER_TYPE = 5;

pub const D3D_FEATURE_LEVEL = i32;
pub const D3D_FEATURE_LEVEL_11_0: D3D_FEATURE_LEVEL = 0xb000;
pub const D3D_FEATURE_LEVEL_11_1: D3D_FEATURE_LEVEL = 0xb100;

pub const D3D11_USAGE = i32;
pub const D3D11_USAGE_DEFAULT: D3D11_USAGE = 0;
pub const D3D11_USAGE_STAGING: D3D11_USAGE = 3;

pub const D3D11_MAP = i32;
pub const D3D11_MAP_READ: D3D11_MAP = 1;

pub const D3D11_SRV_DIMENSION = i32;
pub const D3D11_SRV_DIMENSION_TEXTURE2D: D3D11_SRV_DIMENSION = 4;

pub const D3D11_UAV_DIMENSION = i32;
pub const D3D11_UAV_DIMENSION_TEXTURE2D: D3D11_UAV_DIMENSION = 4;

pub const D3D11_SDK_VERSION: UINT = 7;

// Bind flags
pub const D3D11_BIND_CONSTANT_BUFFER: UINT = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: UINT = 0x8;
pub const D3D11_BIND_RENDER_TARGET: UINT = 0x20;
pub const D3D11_BIND_UNORDERED_ACCESS: UINT = 0x80;
// CPU access
pub const D3D11_CPU_ACCESS_READ: UINT = 0x20000;
// Misc resource flags
pub const D3D11_RESOURCE_MISC_SHARED: UINT = 0x2;
pub const D3D11_RESOURCE_MISC_SHARED_NTHANDLE: UINT = 0x800;
// Create-device flags
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: UINT = 0x20;
pub const D3D11_CREATE_DEVICE_VIDEO_SUPPORT: UINT = 0x800;
// Fence flags (d3d11_3.h)
pub const D3D11_FENCE_FLAG_SHARED: UINT = 0x2;

// ---------------------------------------------------------------------------
// Plain structs (d3d11.h)
// ---------------------------------------------------------------------------
pub const DXGI_SAMPLE_DESC = extern struct {
    Count: UINT,
    Quality: UINT,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: UINT,
    Height: UINT,
    MipLevels: UINT,
    ArraySize: UINT,
    Format: DXGI_FORMAT,
    SampleDesc: DXGI_SAMPLE_DESC,
    Usage: D3D11_USAGE,
    BindFlags: UINT,
    CPUAccessFlags: UINT,
    MiscFlags: UINT,
};

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: UINT,
    Usage: D3D11_USAGE,
    BindFlags: UINT,
    CPUAccessFlags: UINT,
    MiscFlags: UINT,
    StructureByteStride: UINT,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: ?*const anyopaque,
    SysMemPitch: UINT,
    SysMemSlicePitch: UINT,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque,
    RowPitch: UINT,
    DepthPitch: UINT,
};

pub const D3D11_BOX = extern struct {
    left: UINT,
    top: UINT,
    front: UINT,
    right: UINT,
    bottom: UINT,
    back: UINT,
};

// ---------------------------------------------------------------------------
// View descriptors with unions (d3d11_3.h / d3d11.h). The union spans every
// view dimension; only the Texture2D arm is used. The union is padded to its
// true largest member so the overall struct size matches the C layout — the
// biggest SRV1 arm is D3D11_TEX2D_ARRAY_SRV1 (5 UINT = 20 bytes) and the
// biggest UAV arm is 3 UINT = 12 bytes.
// ---------------------------------------------------------------------------
pub const D3D11_TEX2D_SRV1 = extern struct {
    MostDetailedMip: UINT,
    MipLevels: UINT,
    PlaneSlice: UINT,
};

pub const D3D11_SHADER_RESOURCE_VIEW_DESC1 = extern struct {
    Format: DXGI_FORMAT,
    ViewDimension: D3D11_SRV_DIMENSION,
    u: extern union {
        Texture2D: D3D11_TEX2D_SRV1,
        _max: [20]u8,
    },
};

pub const D3D11_TEX2D_UAV = extern struct {
    MipSlice: UINT,
};

pub const D3D11_UNORDERED_ACCESS_VIEW_DESC = extern struct {
    Format: DXGI_FORMAT,
    ViewDimension: D3D11_UAV_DIMENSION,
    u: extern union {
        Texture2D: D3D11_TEX2D_UAV,
        _max: [12]u8,
    },
};

comptime {
    std.debug.assert(@sizeOf(D3D11_TEXTURE2D_DESC) == 44);
    std.debug.assert(@sizeOf(D3D11_SHADER_RESOURCE_VIEW_DESC1) == 28);
    std.debug.assert(@sizeOf(D3D11_UNORDERED_ACCESS_VIEW_DESC) == 20);
}

// ---------------------------------------------------------------------------
// ID3D11Device (base, 43 slots). Typed: the create calls the port issues.
// ---------------------------------------------------------------------------
pub const ID3D11Device = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{DB6F6DDB-AC77-4E88-8253-819DF9BBF140}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        CreateBuffer: *const fn (*Self, *const D3D11_BUFFER_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Buffer) callconv(.winapi) HRESULT,
        CreateTexture1D: *const anyopaque,
        CreateTexture2D: *const fn (*Self, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Texture2D) callconv(.winapi) HRESULT,
        CreateTexture3D: *const anyopaque,
        CreateShaderResourceView: *const anyopaque,
        CreateUnorderedAccessView: *const fn (*Self, *ID3D11Resource, ?*const D3D11_UNORDERED_ACCESS_VIEW_DESC, *?*ID3D11UnorderedAccessView) callconv(.winapi) HRESULT,
        CreateRenderTargetView: *const anyopaque,
        CreateDepthStencilView: *const anyopaque,
        CreateInputLayout: *const anyopaque,
        CreateVertexShader: *const anyopaque,
        CreateGeometryShader: *const anyopaque,
        CreateGeometryShaderWithStreamOutput: *const anyopaque,
        CreatePixelShader: *const anyopaque,
        CreateHullShader: *const anyopaque,
        CreateDomainShader: *const anyopaque,
        CreateComputeShader: *const fn (*Self, *const anyopaque, usize, ?*ID3D11ClassLinkage, *?*ID3D11ComputeShader) callconv(.winapi) HRESULT,
        CreateClassLinkage: *const anyopaque,
        CreateBlendState: *const anyopaque,
        CreateDepthStencilState: *const anyopaque,
        CreateRasterizerState: *const anyopaque,
        CreateSamplerState: *const anyopaque,
        CreateQuery: *const anyopaque,
        CreatePredicate: *const anyopaque,
        CreateCounter: *const anyopaque,
        CreateDeferredContext: *const anyopaque,
        OpenSharedResource: *const anyopaque,
        CheckFormatSupport: *const anyopaque,
        CheckMultisampleQualityLevels: *const anyopaque,
        CheckCounterInfo: *const anyopaque,
        CheckCounter: *const anyopaque,
        CheckFeatureSupport: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetFeatureLevel: *const anyopaque,
        GetCreationFlags: *const anyopaque,
        GetDeviceRemovedReason: *const anyopaque,
        GetImmediateContext: *const fn (*Self, *?*ID3D11DeviceContext) callconv(.winapi) void,
        SetExceptionMode: *const anyopaque,
        GetExceptionMode: *const anyopaque,
    };

    pub inline fn CreateBuffer(self: *Self, desc: *const D3D11_BUFFER_DESC, init: ?*const D3D11_SUBRESOURCE_DATA, out: *?*ID3D11Buffer) HRESULT {
        return self.lpVtbl.CreateBuffer(self, desc, init, out);
    }
    pub inline fn CreateTexture2D(self: *Self, desc: *const D3D11_TEXTURE2D_DESC, init: ?*const D3D11_SUBRESOURCE_DATA, out: *?*ID3D11Texture2D) HRESULT {
        return self.lpVtbl.CreateTexture2D(self, desc, init, out);
    }
    pub inline fn CreateUnorderedAccessView(self: *Self, res: *ID3D11Resource, desc: ?*const D3D11_UNORDERED_ACCESS_VIEW_DESC, out: *?*ID3D11UnorderedAccessView) HRESULT {
        return self.lpVtbl.CreateUnorderedAccessView(self, res, desc, out);
    }
    pub inline fn CreateComputeShader(self: *Self, bytecode: *const anyopaque, len: usize, linkage: ?*ID3D11ClassLinkage, out: *?*ID3D11ComputeShader) HRESULT {
        return self.lpVtbl.CreateComputeShader(self, bytecode, len, linkage, out);
    }
    pub inline fn GetImmediateContext(self: *Self, out: *?*ID3D11DeviceContext) void {
        return self.lpVtbl.GetImmediateContext(self, out);
    }
};

// ---------------------------------------------------------------------------
// ID3D11Device3 : Device2 : Device1 : Device. Embeds the base vtable, then the
// Device1 (7) + Device2 (4) + Device3 (11) additions. Typed: CreateShaderResourceView1.
// ---------------------------------------------------------------------------
pub const ID3D11Device3 = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{A05C8C37-D2C6-4732-B3A0-9CE0B0DC9AE6}");

    pub const Vtbl = extern struct {
        base: ID3D11Device.Vtbl,
        // ID3D11Device1
        GetImmediateContext1: *const anyopaque,
        CreateDeferredContext1: *const anyopaque,
        CreateBlendState1: *const anyopaque,
        CreateRasterizerState1: *const anyopaque,
        CreateDeviceContextState: *const anyopaque,
        OpenSharedResource1: *const anyopaque,
        OpenSharedResourceByName: *const anyopaque,
        // ID3D11Device2
        GetImmediateContext2: *const anyopaque,
        CreateDeferredContext2: *const anyopaque,
        GetResourceTiling: *const anyopaque,
        CheckMultisampleQualityLevels1: *const anyopaque,
        // ID3D11Device3
        CreateTexture2D1: *const anyopaque,
        CreateTexture3D1: *const anyopaque,
        CreateRasterizerState2: *const anyopaque,
        CreateShaderResourceView1: *const fn (*Self, *ID3D11Resource, ?*const D3D11_SHADER_RESOURCE_VIEW_DESC1, *?*ID3D11ShaderResourceView) callconv(.winapi) HRESULT,
        CreateUnorderedAccessView1: *const anyopaque,
        CreateRenderTargetView1: *const anyopaque,
        CreateQuery1: *const anyopaque,
        GetImmediateContext3: *const anyopaque,
        CreateDeferredContext3: *const anyopaque,
        WriteToSubresource: *const anyopaque,
        ReadFromSubresource: *const anyopaque,
    };

    pub inline fn CreateShaderResourceView1(self: *Self, res: *ID3D11Resource, desc: ?*const D3D11_SHADER_RESOURCE_VIEW_DESC1, out: *?*ID3D11ShaderResourceView) HRESULT {
        return self.lpVtbl.CreateShaderResourceView1(self, res, desc, out);
    }
};

// ---------------------------------------------------------------------------
// ID3D11Device5 : Device4 : Device3. Embeds Device3 vtable then Device4 (2) +
// Device5 (2) additions. Typed: CreateFence.
// ---------------------------------------------------------------------------
pub const ID3D11Device5 = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{8FFDE202-A0E7-45DF-9E01-E837801B5EA0}");

    pub const Vtbl = extern struct {
        d3: ID3D11Device3.Vtbl,
        // ID3D11Device4
        RegisterDeviceRemovedEvent: *const anyopaque,
        UnregisterDeviceRemoved: *const anyopaque,
        // ID3D11Device5
        OpenSharedFence: *const anyopaque,
        CreateFence: *const fn (*Self, UINT64, UINT, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub inline fn CreateFence(self: *Self, initial_value: UINT64, flags: UINT, riid: *const GUID, out: *?*anyopaque) HRESULT {
        return self.lpVtbl.CreateFence(self, initial_value, flags, riid, out);
    }
};

// ---------------------------------------------------------------------------
// ID3D11DeviceContext (base, 115 slots). Typed: the copy/compute/map calls.
// ---------------------------------------------------------------------------
pub const ID3D11DeviceContext = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{C0BFA96C-E089-44FB-8EAF-26F8796190DA}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        VSSetConstantBuffers: *const anyopaque,
        PSSetShaderResources: *const anyopaque,
        PSSetShader: *const anyopaque,
        PSSetSamplers: *const anyopaque,
        VSSetShader: *const anyopaque,
        DrawIndexed: *const anyopaque,
        Draw: *const anyopaque,
        Map: *const fn (*Self, *ID3D11Resource, UINT, D3D11_MAP, UINT, *D3D11_MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT,
        Unmap: *const fn (*Self, *ID3D11Resource, UINT) callconv(.winapi) void,
        PSSetConstantBuffers: *const anyopaque,
        IASetInputLayout: *const anyopaque,
        IASetVertexBuffers: *const anyopaque,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const anyopaque,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const anyopaque,
        VSSetShaderResources: *const anyopaque,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const anyopaque,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const anyopaque,
        OMSetDepthStencilState: *const anyopaque,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const fn (*Self, UINT, UINT, UINT) callconv(.winapi) void,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const anyopaque,
        RSSetViewports: *const anyopaque,
        RSSetScissorRects: *const anyopaque,
        CopySubresourceRegion: *const fn (*Self, *ID3D11Resource, UINT, UINT, UINT, UINT, *ID3D11Resource, UINT, ?*const D3D11_BOX) callconv(.winapi) void,
        CopyResource: *const anyopaque,
        UpdateSubresource: *const fn (*Self, *ID3D11Resource, UINT, ?*const D3D11_BOX, *const anyopaque, UINT, UINT) callconv(.winapi) void,
        CopyStructureCount: *const anyopaque,
        ClearRenderTargetView: *const anyopaque,
        ClearUnorderedAccessViewUint: *const anyopaque,
        ClearUnorderedAccessViewFloat: *const anyopaque,
        ClearDepthStencilView: *const anyopaque,
        GenerateMips: *const anyopaque,
        SetResourceMinLOD: *const anyopaque,
        GetResourceMinLOD: *const anyopaque,
        ResolveSubresource: *const anyopaque,
        ExecuteCommandList: *const anyopaque,
        HSSetShaderResources: *const anyopaque,
        HSSetShader: *const anyopaque,
        HSSetSamplers: *const anyopaque,
        HSSetConstantBuffers: *const anyopaque,
        DSSetShaderResources: *const anyopaque,
        DSSetShader: *const anyopaque,
        DSSetSamplers: *const anyopaque,
        DSSetConstantBuffers: *const anyopaque,
        CSSetShaderResources: *const fn (*Self, UINT, UINT, [*]const ?*ID3D11ShaderResourceView) callconv(.winapi) void,
        CSSetUnorderedAccessViews: *const fn (*Self, UINT, UINT, [*]const ?*ID3D11UnorderedAccessView, ?[*]const UINT) callconv(.winapi) void,
        CSSetShader: *const fn (*Self, ?*ID3D11ComputeShader, ?[*]const ?*ID3D11ClassInstance, UINT) callconv(.winapi) void,
        CSSetSamplers: *const anyopaque,
        CSSetConstantBuffers: *const fn (*Self, UINT, UINT, [*]const ?*ID3D11Buffer) callconv(.winapi) void,
        VSGetConstantBuffers: *const anyopaque,
        PSGetShaderResources: *const anyopaque,
        PSGetShader: *const anyopaque,
        PSGetSamplers: *const anyopaque,
        VSGetShader: *const anyopaque,
        PSGetConstantBuffers: *const anyopaque,
        IAGetInputLayout: *const anyopaque,
        IAGetVertexBuffers: *const anyopaque,
        IAGetIndexBuffer: *const anyopaque,
        GSGetConstantBuffers: *const anyopaque,
        GSGetShader: *const anyopaque,
        IAGetPrimitiveTopology: *const anyopaque,
        VSGetShaderResources: *const anyopaque,
        VSGetSamplers: *const anyopaque,
        GetPredication: *const anyopaque,
        GSGetShaderResources: *const anyopaque,
        GSGetSamplers: *const anyopaque,
        OMGetRenderTargets: *const anyopaque,
        OMGetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMGetBlendState: *const anyopaque,
        OMGetDepthStencilState: *const anyopaque,
        SOGetTargets: *const anyopaque,
        RSGetState: *const anyopaque,
        RSGetViewports: *const anyopaque,
        RSGetScissorRects: *const anyopaque,
        HSGetShaderResources: *const anyopaque,
        HSGetShader: *const anyopaque,
        HSGetSamplers: *const anyopaque,
        HSGetConstantBuffers: *const anyopaque,
        DSGetShaderResources: *const anyopaque,
        DSGetShader: *const anyopaque,
        DSGetSamplers: *const anyopaque,
        DSGetConstantBuffers: *const anyopaque,
        CSGetShaderResources: *const anyopaque,
        CSGetUnorderedAccessViews: *const anyopaque,
        CSGetShader: *const anyopaque,
        CSGetSamplers: *const anyopaque,
        CSGetConstantBuffers: *const anyopaque,
        ClearState: *const anyopaque,
        Flush: *const fn (*Self) callconv(.winapi) void,
        GetType: *const anyopaque,
        GetContextFlags: *const anyopaque,
        FinishCommandList: *const anyopaque,
    };

    pub inline fn Map(self: *Self, res: *ID3D11Resource, subresource: UINT, map_type: D3D11_MAP, flags: UINT, out: *D3D11_MAPPED_SUBRESOURCE) HRESULT {
        return self.lpVtbl.Map(self, res, subresource, map_type, flags, out);
    }
    pub inline fn Unmap(self: *Self, res: *ID3D11Resource, subresource: UINT) void {
        return self.lpVtbl.Unmap(self, res, subresource);
    }
    pub inline fn Dispatch(self: *Self, x: UINT, y: UINT, z: UINT) void {
        return self.lpVtbl.Dispatch(self, x, y, z);
    }
    pub inline fn CopySubresourceRegion(self: *Self, dst: *ID3D11Resource, dst_sub: UINT, x: UINT, y: UINT, z: UINT, src: *ID3D11Resource, src_sub: UINT, box: ?*const D3D11_BOX) void {
        return self.lpVtbl.CopySubresourceRegion(self, dst, dst_sub, x, y, z, src, src_sub, box);
    }
    pub inline fn UpdateSubresource(self: *Self, res: *ID3D11Resource, sub: UINT, box: ?*const D3D11_BOX, data: *const anyopaque, row_pitch: UINT, depth_pitch: UINT) void {
        return self.lpVtbl.UpdateSubresource(self, res, sub, box, data, row_pitch, depth_pitch);
    }
    pub inline fn CSSetShaderResources(self: *Self, start: UINT, count: UINT, views: [*]const ?*ID3D11ShaderResourceView) void {
        return self.lpVtbl.CSSetShaderResources(self, start, count, views);
    }
    pub inline fn CSSetUnorderedAccessViews(self: *Self, start: UINT, count: UINT, views: [*]const ?*ID3D11UnorderedAccessView, counts: ?[*]const UINT) void {
        return self.lpVtbl.CSSetUnorderedAccessViews(self, start, count, views, counts);
    }
    pub inline fn CSSetShader(self: *Self, shader: ?*ID3D11ComputeShader, instances: ?[*]const ?*ID3D11ClassInstance, num_instances: UINT) void {
        return self.lpVtbl.CSSetShader(self, shader, instances, num_instances);
    }
    pub inline fn CSSetConstantBuffers(self: *Self, start: UINT, count: UINT, buffers: [*]const ?*ID3D11Buffer) void {
        return self.lpVtbl.CSSetConstantBuffers(self, start, count, buffers);
    }
    pub inline fn Flush(self: *Self) void {
        return self.lpVtbl.Flush(self);
    }
};

// ---------------------------------------------------------------------------
// ID3D11DeviceContext4 : Context3 : Context2 : Context1 : DeviceContext.
// Embeds the base (115 slots) then the 34 Context1..4 additions. Typed: Signal.
// ---------------------------------------------------------------------------
pub const ID3D11DeviceContext4 = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{917600DA-F58C-4C33-98D8-3E15B390FA24}");

    pub const Vtbl = extern struct {
        base: ID3D11DeviceContext.Vtbl,
        // ID3D11DeviceContext1
        CopySubresourceRegion1: *const anyopaque,
        UpdateSubresource1: *const anyopaque,
        DiscardResource: *const anyopaque,
        DiscardView: *const anyopaque,
        VSSetConstantBuffers1: *const anyopaque,
        HSSetConstantBuffers1: *const anyopaque,
        DSSetConstantBuffers1: *const anyopaque,
        GSSetConstantBuffers1: *const anyopaque,
        PSSetConstantBuffers1: *const anyopaque,
        CSSetConstantBuffers1: *const anyopaque,
        VSGetConstantBuffers1: *const anyopaque,
        HSGetConstantBuffers1: *const anyopaque,
        DSGetConstantBuffers1: *const anyopaque,
        GSGetConstantBuffers1: *const anyopaque,
        PSGetConstantBuffers1: *const anyopaque,
        CSGetConstantBuffers1: *const anyopaque,
        SwapDeviceContextState: *const anyopaque,
        ClearView: *const anyopaque,
        DiscardView1: *const anyopaque,
        // ID3D11DeviceContext2
        UpdateTileMappings: *const anyopaque,
        CopyTileMappings: *const anyopaque,
        CopyTiles: *const anyopaque,
        UpdateTiles: *const anyopaque,
        ResizeTilePool: *const anyopaque,
        TiledResourceBarrier: *const anyopaque,
        IsAnnotationEnabled: *const anyopaque,
        SetMarkerInt: *const anyopaque,
        BeginEventInt: *const anyopaque,
        EndEvent: *const anyopaque,
        // ID3D11DeviceContext3
        Flush1: *const anyopaque,
        SetHardwareProtectionState: *const anyopaque,
        GetHardwareProtectionState: *const anyopaque,
        // ID3D11DeviceContext4
        Signal: *const fn (*Self, *ID3D11Fence, UINT64) callconv(.winapi) HRESULT,
        Wait: *const anyopaque,
    };

    pub inline fn Signal(self: *Self, fence: *ID3D11Fence, value: UINT64) HRESULT {
        return self.lpVtbl.Signal(self, fence, value);
    }
};

// ---------------------------------------------------------------------------
// ID3D11Texture2D : ID3D11Resource : ID3D11DeviceChild : IUnknown.
// ---------------------------------------------------------------------------
pub const ID3D11Texture2D = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{6F15AAF2-D208-4E89-9AB4-489535D34F9C}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        GetDevice: *const fn (*Self, *?*ID3D11Device) callconv(.winapi) void,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetType: *const anyopaque,
        SetEvictionPriority: *const anyopaque,
        GetEvictionPriority: *const anyopaque,
        GetDesc: *const fn (*Self, *D3D11_TEXTURE2D_DESC) callconv(.winapi) void,
    };

    pub inline fn GetDevice(self: *Self, out: *?*ID3D11Device) void {
        return self.lpVtbl.GetDevice(self, out);
    }
    pub inline fn GetDesc(self: *Self, desc: *D3D11_TEXTURE2D_DESC) void {
        return self.lpVtbl.GetDesc(self, desc);
    }
    /// Reinterpret as the ID3D11Resource base (same COM identity) for the
    /// resource-typed Create*View / Copy calls.
    pub inline fn asResource(self: *Self) *ID3D11Resource {
        return @ptrCast(self);
    }
};

// ---------------------------------------------------------------------------
// ID3D10Multithread : IUnknown (declared in d3d10.h but implemented by the
// D3D11 device). Only SetMultithreadProtected is used.
// ---------------------------------------------------------------------------
pub const ID3D10Multithread = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{9B7E4E00-342C-4106-A19F-4F2704F689F0}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        Enter: *const anyopaque,
        Leave: *const anyopaque,
        SetMultithreadProtected: *const fn (*Self, WINBOOL) callconv(.winapi) WINBOOL,
        GetMultithreadProtected: *const anyopaque,
    };

    pub inline fn SetMultithreadProtected(self: *Self, protect: WINBOOL) WINBOOL {
        return self.lpVtbl.SetMultithreadProtected(self, protect);
    }
};

// ---------------------------------------------------------------------------
// ID3D11Fence : ID3D11DeviceChild : IUnknown (d3d11_3.h). Only CreateSharedHandle.
// ---------------------------------------------------------------------------
pub const ID3D11Fence = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{AFFDE9D1-1DF7-4BB7-8A34-0F46251DAB80}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        CreateSharedHandle: *const fn (*Self, ?*anyopaque, DWORD, LPCWSTR, *HANDLE) callconv(.winapi) HRESULT,
        GetCompletedValue: *const anyopaque,
        SetEventOnCompletion: *const anyopaque,
    };

    pub inline fn CreateSharedHandle(self: *Self, attrs: ?*anyopaque, access: DWORD, name: LPCWSTR, handle: *HANDLE) HRESULT {
        return self.lpVtbl.CreateSharedHandle(self, attrs, access, name, handle);
    }
};

pub extern "d3d11" fn D3D11CreateDevice(
    pAdapter: ?*anyopaque,
    DriverType: D3D_DRIVER_TYPE,
    Software: HMODULE,
    Flags: UINT,
    pFeatureLevels: ?[*]const D3D_FEATURE_LEVEL,
    FeatureLevels: UINT,
    SDKVersion: UINT,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*D3D_FEATURE_LEVEL,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;
