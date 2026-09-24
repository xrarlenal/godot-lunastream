//! d3d12.zig — the sliver of Direct3D 12 the zero-copy surface importer needs.
//! Transcribed from d3d12.h.
//!
//! The D3D12 device is not created here — Godot's RenderingDevice hands it to
//! the importer. All the port does on the D3D12 side is open shared NT handles
//! exported from D3D11 (textures and a fence) and wait on the fence. So only
//! three interfaces appear, each with almost every slot collapsed to an opaque
//! placeholder.

const std = @import("std");
const com = @import("com.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const ULONG = com.ULONG;
const UINT64 = u64;
const HANDLE = com.HANDLE;

// ID3D12Resource is only ever held and handed back to Godot as a raw handle;
// no method is called on it.
pub const ID3D12Resource = opaque {};

// ---------------------------------------------------------------------------
// ID3D12Device : ID3D12Object : IUnknown (44 slots). Typed: OpenSharedHandle
// (slot 32).
// ---------------------------------------------------------------------------
pub const ID3D12Device = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{189819F1-1DB6-4B57-BE54-1821339B85F7}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        SetName: *const anyopaque,
        GetNodeCount: *const anyopaque,
        CreateCommandQueue: *const anyopaque,
        CreateCommandAllocator: *const anyopaque,
        CreateGraphicsPipelineState: *const anyopaque,
        CreateComputePipelineState: *const anyopaque,
        CreateCommandList: *const anyopaque,
        CheckFeatureSupport: *const anyopaque,
        CreateDescriptorHeap: *const anyopaque,
        GetDescriptorHandleIncrementSize: *const anyopaque,
        CreateRootSignature: *const anyopaque,
        CreateConstantBufferView: *const anyopaque,
        CreateShaderResourceView: *const anyopaque,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const anyopaque,
        CreateDepthStencilView: *const anyopaque,
        CreateSampler: *const anyopaque,
        CopyDescriptors: *const anyopaque,
        CopyDescriptorsSimple: *const anyopaque,
        GetResourceAllocationInfo: *const anyopaque,
        GetCustomHeapProperties: *const anyopaque,
        CreateCommittedResource: *const anyopaque,
        CreateHeap: *const anyopaque,
        CreatePlacedResource: *const anyopaque,
        CreateReservedResource: *const anyopaque,
        CreateSharedHandle: *const anyopaque,
        OpenSharedHandle: *const fn (*Self, HANDLE, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        OpenSharedHandleByName: *const anyopaque,
        MakeResident: *const anyopaque,
        Evict: *const anyopaque,
        CreateFence: *const anyopaque,
        GetDeviceRemovedReason: *const anyopaque,
        GetCopyableFootprints: *const anyopaque,
        CreateQueryHeap: *const anyopaque,
        SetStablePowerState: *const anyopaque,
        CreateCommandSignature: *const anyopaque,
        GetResourceTiling: *const anyopaque,
        GetAdapterLuid: *const anyopaque,
    };

    pub inline fn OpenSharedHandle(self: *Self, handle: HANDLE, riid: *const GUID, out: *?*anyopaque) HRESULT {
        return self.lpVtbl.OpenSharedHandle(self, handle, riid, out);
    }
};

// ---------------------------------------------------------------------------
// ID3D12Fence : ID3D12Pageable : ID3D12DeviceChild : ID3D12Object : IUnknown.
// Typed: GetCompletedValue (slot 8), SetEventOnCompletion (slot 9).
// ---------------------------------------------------------------------------
pub const ID3D12Fence = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{0A753DCF-C4D8-4B91-ADF6-BE5A60D95A76}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        SetName: *const anyopaque,
        GetDevice: *const anyopaque,
        GetCompletedValue: *const fn (*Self) callconv(.winapi) UINT64,
        SetEventOnCompletion: *const fn (*Self, UINT64, HANDLE) callconv(.winapi) HRESULT,
        Signal: *const anyopaque,
    };

    pub inline fn GetCompletedValue(self: *Self) UINT64 {
        return self.lpVtbl.GetCompletedValue(self);
    }
    pub inline fn SetEventOnCompletion(self: *Self, value: UINT64, event: HANDLE) HRESULT {
        return self.lpVtbl.SetEventOnCompletion(self, value, event);
    }
};

pub const IID_ID3D12Resource = GUID.parse("{696442BE-A72E-4059-BC79-5B5C98040FAD}");
