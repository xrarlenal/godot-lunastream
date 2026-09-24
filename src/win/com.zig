//! com.zig — COM plumbing and generic Win32 glue for the Media Foundation port.
//!
//! Everything here is hand-declared. This repo forbids `@cImport`: every OS
//! type, function, and interface vtable is transcribed by hand from the
//! mingw-w64 headers Zig ships (see the module doc in win.zig for the rules).
//! That keeps the ABI surface auditable and sidesteps a class of MinGW
//! import-library gaps (e.g. `GUID_NULL` and the DirectX IID symbols are
//! missing from the mingw import libs — so we never reference them; every GUID
//! this port needs is a Zig `const` with a literal value instead).
//!
//! Design choices for Zig:
//!  - COM interfaces are `extern struct { lpVtbl: *const Vtbl }`, mirroring the
//!    C-ABI view MinGW emits. The Vtbl lists EVERY slot in declared order
//!    (parent interface methods first); methods this port never calls are kept
//!    as opaque `*const anyopaque` slots so the slot index of the methods we DO
//!    call is exact. Never reorder or drop a slot.
//!  - Lifetime is managed with `ComPtr(T)`: a thin move-only wrapper that calls
//!    `Release` on `deinit`. It mirrors the spirit of the C++ `ComPtr`/`com_raii`
//!    but leans on Zig `defer`/`errdefer` at call sites rather than RAII.

const std = @import("std");
const windows = std.os.windows;

const log = std.log.scoped(.mf_com);

pub const GUID = windows.GUID;
pub const HRESULT = i32;
pub const HANDLE = ?*anyopaque;
pub const HMODULE = ?*anyopaque;
pub const HWND = ?*anyopaque;
pub const BOOL = i32;
pub const WINBOOL = i32;
pub const DWORD = u32;
pub const WORD = u16;
pub const UINT = u32;
pub const ULONG = u32;
pub const WCHAR = u16;
pub const LPCWSTR = ?[*:0]const u16;
pub const LPWSTR = ?[*:0]u16;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

// ---------------------------------------------------------------------------
// HRESULT helpers. HRESULT is a signed 32-bit code; the sign bit is the
// failure flag, so FAILED/SUCCEEDED are just a sign test (matches winerror.h's
// SUCCEEDED/FAILED macros).
// ---------------------------------------------------------------------------
pub inline fn SUCCEEDED(hr: HRESULT) bool {
    return hr >= 0;
}
pub inline fn FAILED(hr: HRESULT) bool {
    return hr < 0;
}

/// Canonical HRESULT check: turns a failed HRESULT into `error.ComFailure`.
/// Zig errors can't carry a payload, so the HRESULT itself is logged here
/// (in hex) before it's lost to the caller.
pub fn check(hr: HRESULT) error{ComFailure}!void {
    if (FAILED(hr)) {
        log.err("HRESULT 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.ComFailure;
    }
}

pub const S_OK: HRESULT = 0;
// S_FALSE: CoInitializeEx returns this when COM is already initialised on the
// calling thread — treated as success by the port.
pub const S_FALSE: HRESULT = 1;
// _HRESULT_TYPEDEF_(0xC00D36B3): source-reader stream-enumeration terminator.
pub const MF_E_INVALIDSTREAMNUMBER: HRESULT = @bitCast(@as(u32, 0xC00D36B3));
// CoInitializeEx returns this when the thread already has an incompatible
// COM apartment (e.g. STA) set on it.
pub const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

// ---------------------------------------------------------------------------
// IUnknown — root of every COM interface. Its three slots (QueryInterface,
// AddRef, Release) lead every derived vtable in this exact order.
// ---------------------------------------------------------------------------
pub const IUnknown = extern struct {
    lpVtbl: *const Vtbl,
    const Self = @This();

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) ULONG,
        Release: *const fn (*Self) callconv(.winapi) ULONG,
    };

    pub inline fn AddRef(self: *Self) ULONG {
        return self.lpVtbl.AddRef(self);
    }
};

/// Query `src` for interface `T` (whose IID is `T.IID`), returning a typed
/// pointer or null. Any COM interface pointer with an `lpVtbl` first field can
/// be reinterpreted as `*IUnknown` for the call — that is exactly the C-ABI
/// layout MinGW emits.
pub fn queryInterface(comptime T: type, src: anytype) ?*T {
    var out: ?*anyopaque = null;
    const unk: *IUnknown = @ptrCast(src);
    if (FAILED(unk.lpVtbl.QueryInterface(unk, &T.IID, &out))) return null;
    return @ptrCast(@alignCast(out));
}

/// Release any COM interface pointer through its IUnknown identity. Every COM
/// interface in this port begins with `lpVtbl`, so casting to `*IUnknown` and
/// calling the vtable's Release slot is always sound (mirrors ComPtr.reset,
/// which used to inline this before every per-type Release wrapper collapsed
/// into this one function).
pub fn release(p: anytype) void {
    // @alignCast: opaque interface types (ID3D12Resource, the D3D11
    // view/buffer/shader handles) have alignment 1, but a live COM pointer is
    // really vtable-aligned, so the upcast to *IUnknown is sound.
    const unk: *IUnknown = @ptrCast(@alignCast(p));
    _ = unk.lpVtbl.Release(unk);
}

/// Move-only owner of a COM interface pointer. `deinit`/`reset` release once.
/// Not RAII: pair construction with `defer p.deinit()` or hand ownership off
/// with `take()`.
pub fn ComPtr(comptime T: type) type {
    return struct {
        ptr: ?*T = null,
        const Self = @This();

        pub fn init(p: ?*T) Self {
            return .{ .ptr = p };
        }
        pub fn get(self: Self) ?*T {
            return self.ptr;
        }
        /// Address of the inner pointer for `**T` out-params (e.g. Create*),
        /// after releasing any current occupant.
        pub fn put(self: *Self) *?*T {
            self.reset();
            return &self.ptr;
        }
        /// Relinquish ownership without releasing.
        pub fn take(self: *Self) ?*T {
            const p = self.ptr;
            self.ptr = null;
            return p;
        }
        pub fn reset(self: *Self) void {
            if (self.ptr) |p| {
                release(p);
                self.ptr = null;
            }
        }
        pub fn deinit(self: *Self) void {
            self.reset();
        }
    };
}

// ---------------------------------------------------------------------------
// COM apartment lifecycle (ole32).
// ---------------------------------------------------------------------------
// COINIT_MULTITHREADED == COINITBASE_MULTITHREADED == 0x0 (objbase.h).
pub const COINIT_MULTITHREADED: DWORD = 0x0;

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

// APTTYPE / APTTYPEQUALIFIER (objidl.h): the calling thread's COM apartment,
// queried via CoGetApartmentType. Used to assert the COM apartment thread we
// spawn really is MTA (see com_executor.zig).
pub const APTTYPE = i32;
pub const APTTYPE_CURRENT: APTTYPE = -1;
pub const APTTYPE_STA: APTTYPE = 0;
pub const APTTYPE_MTA: APTTYPE = 1;
pub const APTTYPE_NA: APTTYPE = 2;
pub const APTTYPE_MAINSTA: APTTYPE = 3;
pub const APTTYPEQUALIFIER = i32;
pub extern "ole32" fn CoGetApartmentType(
    pAptType: *APTTYPE,
    pAptQualifier: *APTTYPEQUALIFIER,
) callconv(.winapi) HRESULT;

// ---------------------------------------------------------------------------
// PROPVARIANT. Full 24-byte x64 layout (propidl.h): a 8-byte header followed
// by a value union. This port only ever reads VT_UI8 (uhVal, presentation
// duration) and VT_LPWSTR (pwszVal, stream language/name), and only ever
// writes VT_I8 via InitPropVariantFromInt64 (seek position). The union is
// padded to the true 16-byte max member so the struct size matches the header.
// ---------------------------------------------------------------------------
pub const VT_I8: WORD = 20;
pub const VT_UI8: WORD = 21;
pub const VT_LPWSTR: WORD = 31;

pub const PROPVARIANT = extern struct {
    vt: WORD,
    wReserved1: WORD = 0,
    wReserved2: WORD = 0,
    wReserved3: WORD = 0,
    val: extern union {
        hVal: i64, // LARGE_INTEGER.QuadPart (VT_I8)
        uhVal: u64, // ULARGE_INTEGER.QuadPart (VT_UI8)
        pwszVal: ?[*:0]u16, // VT_LPWSTR
        _pad: [16]u8,
    },

    pub fn zeroed() PROPVARIANT {
        return .{ .vt = 0, .val = .{ ._pad = [_]u8{0} ** 16 } };
    }
};

comptime {
    // x64: 8-byte header + 16-byte value union = 24 bytes.
    std.debug.assert(@sizeOf(PROPVARIANT) == 24);
    std.debug.assert(@offsetOf(PROPVARIANT, "val") == 8);
}

// PropVariantClear lives in ole32.dll (not propsys) — so no propsys link.
pub extern "ole32" fn PropVariantClear(pvar: *PROPVARIANT) callconv(.winapi) HRESULT;
// InitPropVariantFromInt64 is a header inline in the SDK but exported by
// propsys; to avoid a propsys dependency the port fills VT_I8 by hand. Provided
// here as a helper rather than an extern.
pub fn initPropVariantFromInt64(value: i64) PROPVARIANT {
    var pv = PROPVARIANT.zeroed();
    pv.vt = VT_I8;
    pv.val = .{ .hVal = value };
    return pv;
}

// ---------------------------------------------------------------------------
// Misc Win32 (kernel32): handles, events, waits, code-page and locale
// conversion used for path and language-tag normalisation.
// ---------------------------------------------------------------------------
pub const CP_UTF8: UINT = 65001;
pub const LOCALE_SISO639LANGNAME2: DWORD = 0x00000067;
pub const LOCALE_NAME_MAX_LENGTH: usize = 85;
pub const GENERIC_ALL: DWORD = 0x10000000;
pub const WAIT_OBJECT_0: DWORD = 0x0;
pub const WAIT_FAILED: DWORD = 0xFFFFFFFF;
pub const INFINITE: DWORD = 0xFFFFFFFF;

pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: LPCWSTR,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;

pub extern "kernel32" fn MultiByteToWideChar(
    CodePage: UINT,
    dwFlags: DWORD,
    lpMultiByteStr: [*]const u8,
    cbMultiByte: c_int,
    lpWideCharStr: ?[*]u16,
    cchWideChar: c_int,
) callconv(.winapi) c_int;

pub extern "kernel32" fn WideCharToMultiByte(
    CodePage: UINT,
    dwFlags: DWORD,
    lpWideCharStr: [*]const u16,
    cchWideChar: c_int,
    lpMultiByteStr: ?[*]u8,
    cbMultiByte: c_int,
    lpDefaultChar: ?[*]const u8,
    lpUsedDefaultChar: ?*BOOL,
) callconv(.winapi) c_int;

pub extern "kernel32" fn GetLocaleInfoEx(
    lpLocaleName: LPCWSTR,
    LCType: DWORD,
    lpLCData: ?[*]u16,
    cchData: c_int,
) callconv(.winapi) c_int;
