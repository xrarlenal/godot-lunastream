//! d3dcompiler.zig — runtime HLSL compilation of the NV12/P010 plane-split
//! compute shader. Transcribed from d3dcompiler.h and d3dcommon.h (ID3DBlob).

const com = @import("com.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const ULONG = com.ULONG;
const UINT = com.UINT;

// D3DCOMPILE_OPTIMIZATION_LEVEL3 (d3dcompiler.h).
pub const D3DCOMPILE_OPTIMIZATION_LEVEL3: UINT = 0x00008000;

// ---------------------------------------------------------------------------
// ID3DBlob (a.k.a. ID3D10Blob) : IUnknown — a byte bag returned by D3DCompile
// for both the bytecode and any error text. GetBufferPointer/GetBufferSize.
// ---------------------------------------------------------------------------
pub const ID3DBlob = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();
    pub const IID = GUID.parse("{8BA5FB08-5195-40E2-AC58-0D989C3A0102}");

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
        GetBufferPointer: *const fn (*Self) callconv(.winapi) ?*anyopaque,
        GetBufferSize: *const fn (*Self) callconv(.winapi) usize,
    };

    pub inline fn GetBufferPointer(self: *Self) ?*anyopaque {
        return self.lpVtbl.GetBufferPointer(self);
    }
    pub inline fn GetBufferSize(self: *Self) usize {
        return self.lpVtbl.GetBufferSize(self);
    }
};

// D3D_SHADER_MACRO / ID3DInclude are always passed null by the port, so they
// stay opaque here.
pub extern "d3dcompiler_47" fn D3DCompile(
    pSrcData: *const anyopaque,
    SrcDataSize: usize,
    pSourceName: ?[*:0]const u8,
    pDefines: ?*const anyopaque,
    pInclude: ?*anyopaque,
    pEntrypoint: ?[*:0]const u8,
    pTarget: ?[*:0]const u8,
    Flags1: UINT,
    Flags2: UINT,
    ppCode: *?*ID3DBlob,
    ppErrorMsgs: *?*ID3DBlob,
) callconv(.winapi) HRESULT;
