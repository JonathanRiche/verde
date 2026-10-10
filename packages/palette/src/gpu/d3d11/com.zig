//! Hand-written Direct3D 11 / DXGI COM bindings (only what the renderer uses).
//!
//! Each interface is an opaque object whose first word points at its vtable; methods call
//! the vtable slot by index. Slot numbers come from the mingw-w64 headers shipped with Zig
//! (`lib/libc/include/any-windows-any/{d3d11,dxgi,dxgi1_2,dxgi1_3}.h`, the `...Vtbl` structs,
//! counting IUnknown's three methods first); `tools/` has no generator because the list is
//! short. Structs mirror the C layouts field for field.
const std = @import("std");

pub const HRESULT = i32;
pub const BOOL = i32;
pub const UINT = u32;
pub const HANDLE = *anyopaque;

pub const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const POINT = extern struct { x: i32, y: i32 };

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub const Error = error{ D3D11Failed, DeviceRemoved, OutOfMemory };

pub fn check(hr: HRESULT) Error!void {
    if (hr >= 0) return;
    const u: u32 = @bitCast(hr);
    if (u == DXGI_ERROR_DEVICE_REMOVED or u == DXGI_ERROR_DEVICE_RESET) return error.DeviceRemoved;
    if (u == E_OUTOFMEMORY) return error.OutOfMemory;
    std.log.scoped(.d3d11).debug("HRESULT 0x{x:0>8}", .{u});
    return error.D3D11Failed;
}

pub const E_OUTOFMEMORY: u32 = 0x8007000E;
pub const S_FALSE: HRESULT = 1;
pub const DXGI_ERROR_WAS_STILL_DRAWING: u32 = 0x887A000A;
pub const DXGI_ERROR_DEVICE_REMOVED: u32 = 0x887A0005;
pub const DXGI_ERROR_DEVICE_RESET: u32 = 0x887A0007;
pub const DXGI_STATUS_OCCLUDED: HRESULT = 0x087A0001;

// ---- Constants ------------------------------------------------------------------------------

pub const DXGI_FORMAT = enum(u32) {
    unknown = 0,
    r32g32b32a32_float = 2,
    r32g32b32a32_uint = 3,
    r8g8b8a8_unorm = 28,
    r8_unorm = 61,
    b8g8r8a8_unorm = 87,
    _,
};

pub const USAGE_DEFAULT: u32 = 0;
pub const USAGE_IMMUTABLE: u32 = 1;
pub const USAGE_DYNAMIC: u32 = 2;
pub const USAGE_STAGING: u32 = 3;

pub const BIND_VERTEX_BUFFER: u32 = 0x1;
pub const BIND_CONSTANT_BUFFER: u32 = 0x4;
pub const BIND_SHADER_RESOURCE: u32 = 0x8;
pub const BIND_RENDER_TARGET: u32 = 0x20;

pub const CPU_ACCESS_WRITE: u32 = 0x10000;
pub const CPU_ACCESS_READ: u32 = 0x20000;
pub const RESOURCE_MISC_GENERATE_MIPS: u32 = 0x1;

pub const MAP_READ: u32 = 1;
pub const MAP_WRITE: u32 = 2;
pub const MAP_WRITE_DISCARD: u32 = 4;
pub const MAP_WRITE_NO_OVERWRITE: u32 = 5;
pub const MAP_FLAG_DO_NOT_WAIT: u32 = 0x100000;

pub const FILTER_MIN_MAG_MIP_POINT: u32 = 0;
pub const FILTER_MIN_MAG_MIP_LINEAR: u32 = 0x15;
pub const FILTER_ANISOTROPIC: u32 = 0x55;
pub const TEXTURE_ADDRESS_CLAMP: u32 = 3;
pub const COMPARISON_NEVER: u32 = 1;
pub const FLOAT32_MAX: f32 = 3.402823466e+38;

pub const BLEND_ONE: u32 = 2;
pub const BLEND_INV_SRC_ALPHA: u32 = 6;
pub const BLEND_OP_ADD: u32 = 1;
pub const COLOR_WRITE_ENABLE_ALL: u8 = 0xf;

pub const FILL_SOLID: u32 = 3;
pub const CULL_NONE: u32 = 1;

pub const INPUT_PER_INSTANCE_DATA: u32 = 1;
pub const PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: u32 = 5;

pub const DRIVER_TYPE_HARDWARE: u32 = 1;
pub const DRIVER_TYPE_WARP: u32 = 5;
pub const SDK_VERSION: u32 = 7;
pub const CREATE_DEVICE_DEBUG: u32 = 0x2;
pub const CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
pub const FEATURE_LEVEL_10_0: u32 = 0xa000;
pub const FEATURE_LEVEL_10_1: u32 = 0xa100;
pub const FEATURE_LEVEL_11_0: u32 = 0xb000;
pub const FEATURE_LEVEL_11_1: u32 = 0xb100;

pub const QUERY_EVENT: u32 = 0;

pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SCALING_STRETCH: u32 = 0;
pub const DXGI_SCALING_NONE: u32 = 1;
pub const DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL: u32 = 3;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;
pub const DXGI_ALPHA_MODE_UNSPECIFIED: u32 = 0;
pub const DXGI_ALPHA_MODE_IGNORE: u32 = 3;
pub const DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: u32 = 0x40;
pub const DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING: u32 = 0x800;
pub const DXGI_MWA_NO_ALT_ENTER: u32 = 0x2;
pub const DXGI_PRESENT_DO_NOT_WAIT: u32 = 0x8;
pub const DXGI_PRESENT_TEST: u32 = 0x1;

// ---- Structs --------------------------------------------------------------------------------

pub const SAMPLE_DESC = extern struct { Count: u32 = 1, Quality: u32 = 0 };

pub const BUFFER_DESC = extern struct {
    ByteWidth: u32,
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
    StructureByteStride: u32 = 0,
};

pub const TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32 = 1,
    ArraySize: u32 = 1,
    Format: DXGI_FORMAT,
    SampleDesc: SAMPLE_DESC = .{},
    Usage: u32 = USAGE_DEFAULT,
    BindFlags: u32 = 0,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
};

pub const SUBRESOURCE_DATA = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: u32,
    SysMemSlicePitch: u32 = 0,
};

pub const MAPPED_SUBRESOURCE = extern struct {
    pData: ?[*]u8 = null,
    RowPitch: u32 = 0,
    DepthPitch: u32 = 0,
};

pub const INPUT_ELEMENT_DESC = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: u32 = 0,
    Format: DXGI_FORMAT,
    InputSlot: u32 = 0,
    AlignedByteOffset: u32,
    InputSlotClass: u32 = INPUT_PER_INSTANCE_DATA,
    InstanceDataStepRate: u32 = 1,
};

pub const SAMPLER_DESC = extern struct {
    Filter: u32,
    AddressU: u32 = TEXTURE_ADDRESS_CLAMP,
    AddressV: u32 = TEXTURE_ADDRESS_CLAMP,
    AddressW: u32 = TEXTURE_ADDRESS_CLAMP,
    MipLODBias: f32 = 0,
    MaxAnisotropy: u32 = 1,
    ComparisonFunc: u32 = COMPARISON_NEVER,
    BorderColor: [4]f32 = .{ 0, 0, 0, 0 },
    MinLOD: f32 = 0,
    MaxLOD: f32 = FLOAT32_MAX,
};

pub const RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL = 0,
    SrcBlend: u32 = BLEND_ONE,
    DestBlend: u32 = 1, // ZERO
    BlendOp: u32 = BLEND_OP_ADD,
    SrcBlendAlpha: u32 = BLEND_ONE,
    DestBlendAlpha: u32 = 1,
    BlendOpAlpha: u32 = BLEND_OP_ADD,
    RenderTargetWriteMask: u8 = COLOR_WRITE_ENABLE_ALL,
};

pub const BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL = 0,
    IndependentBlendEnable: BOOL = 0,
    RenderTarget: [8]RENDER_TARGET_BLEND_DESC = @splat(.{}),
};

pub const RASTERIZER_DESC = extern struct {
    FillMode: u32 = FILL_SOLID,
    CullMode: u32 = CULL_NONE,
    FrontCounterClockwise: BOOL = 0,
    DepthBias: i32 = 0,
    DepthBiasClamp: f32 = 0,
    SlopeScaledDepthBias: f32 = 0,
    DepthClipEnable: BOOL = 1,
    ScissorEnable: BOOL = 1,
    MultisampleEnable: BOOL = 0,
    AntialiasedLineEnable: BOOL = 0,
};

pub const VIEWPORT = extern struct {
    TopLeftX: f32 = 0,
    TopLeftY: f32 = 0,
    Width: f32,
    Height: f32,
    MinDepth: f32 = 0,
    MaxDepth: f32 = 1,
};

pub const BOX = extern struct { left: u32, top: u32, front: u32 = 0, right: u32, bottom: u32, back: u32 = 1 };

pub const QUERY_DESC = extern struct { Query: u32, MiscFlags: u32 = 0 };

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: u32,
    Height: u32,
    Format: DXGI_FORMAT,
    Stereo: BOOL = 0,
    SampleDesc: SAMPLE_DESC = .{},
    BufferUsage: u32 = DXGI_USAGE_RENDER_TARGET_OUTPUT,
    BufferCount: u32,
    Scaling: u32,
    SwapEffect: u32,
    AlphaMode: u32,
    Flags: u32,
};

pub const DXGI_PRESENT_PARAMETERS = extern struct {
    DirtyRectsCount: u32 = 0,
    pDirtyRects: ?[*]const RECT = null,
    pScrollRect: ?*const RECT = null,
    pScrollOffset: ?*const POINT = null,
};

pub const DXGI_ADAPTER_DESC = extern struct {
    Description: [128]u16,
    VendorId: u32,
    DeviceId: u32,
    SubSysId: u32,
    Revision: u32,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: extern struct { low: u32, high: i32 },
};

// ---- IIDs -----------------------------------------------------------------------------------

pub const IID_ID3D11Texture2D: GUID = .{ .a = 0x6f15aaf2, .b = 0xd208, .c = 0x4e89, .d = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };
pub const IID_IDXGIDevice: GUID = .{ .a = 0x54ec77fa, .b = 0x1377, .c = 0x44e6, .d = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
pub const IID_IDXGIDevice1: GUID = .{ .a = 0x77db970f, .b = 0x6276, .c = 0x48ba, .d = .{ 0xba, 0x28, 0x07, 0x01, 0x43, 0xb4, 0x39, 0x2c } };
pub const IID_IDXGIFactory2: GUID = .{ .a = 0x50c83a1c, .b = 0xe072, .c = 0x4c48, .d = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
pub const IID_IDXGISwapChain2: GUID = .{ .a = 0xa8be2ac4, .b = 0x199f, .c = 0x4946, .d = .{ 0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7 } };
/// IDXGIFactory5 (CheckFeatureSupport for tearing).
pub const IID_IDXGIFactory5: GUID = .{ .a = 0x7632e1f5, .b = 0xee65, .c = 0x4dca, .d = .{ 0x87, 0xfd, 0x84, 0xcd, 0x75, 0xf8, 0x83, 0x8d } };

// ---- Interfaces -----------------------------------------------------------------------------

/// Common layout of every COM object.
fn Interface(comptime Self: type) type {
    return struct {
        inline fn slot(self: *Self, comptime i: usize, comptime F: type) *const F {
            return @ptrCast(@alignCast(self.vtbl[i]));
        }
        pub fn Release(self: *Self) u32 {
            return slot(self, 2, fn (*Self) callconv(.winapi) u32)(self);
        }
        pub fn AddRef(self: *Self) u32 {
            return slot(self, 1, fn (*Self) callconv(.winapi) u32)(self);
        }
        pub fn QueryInterface(self: *Self, iid: *const GUID, out: *?*anyopaque) HRESULT {
            return slot(self, 0, fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT)(self, iid, out);
        }
    };
}

pub fn release(obj: anytype) void {
    if (obj) |o| _ = o.Release();
}

/// Releases and nulls an optional interface field.
pub fn clear(field: anytype) void {
    if (field.*) |o| _ = o.Release();
    field.* = null;
}

const Vtbl = [*]const *const anyopaque;

pub const Unknown = extern struct {
    vtbl: Vtbl,
    const I = Interface(Unknown);
    pub const Release = I.Release;
};

pub const Device = extern struct {
    vtbl: Vtbl,
    const I = Interface(Device);
    pub const Release = I.Release;
    pub const QueryInterface = I.QueryInterface;
    const s = I.slot;

    pub fn CreateBuffer(self: *Device, desc: *const BUFFER_DESC, data: ?*const SUBRESOURCE_DATA, out: *?*Buffer) HRESULT {
        return s(self, 3, fn (*Device, *const BUFFER_DESC, ?*const SUBRESOURCE_DATA, *?*Buffer) callconv(.winapi) HRESULT)(self, desc, data, out);
    }
    pub fn CreateTexture2D(self: *Device, desc: *const TEXTURE2D_DESC, data: ?[*]const SUBRESOURCE_DATA, out: *?*Texture2D) HRESULT {
        return s(self, 5, fn (*Device, *const TEXTURE2D_DESC, ?[*]const SUBRESOURCE_DATA, *?*Texture2D) callconv(.winapi) HRESULT)(self, desc, data, out);
    }
    pub fn CreateShaderResourceView(self: *Device, res: *Resource, desc: ?*const anyopaque, out: *?*ShaderResourceView) HRESULT {
        return s(self, 7, fn (*Device, *Resource, ?*const anyopaque, *?*ShaderResourceView) callconv(.winapi) HRESULT)(self, res, desc, out);
    }
    pub fn CreateRenderTargetView(self: *Device, res: *Resource, desc: ?*const anyopaque, out: *?*RenderTargetView) HRESULT {
        return s(self, 9, fn (*Device, *Resource, ?*const anyopaque, *?*RenderTargetView) callconv(.winapi) HRESULT)(self, res, desc, out);
    }
    pub fn CreateInputLayout(self: *Device, elems: [*]const INPUT_ELEMENT_DESC, n: u32, bytecode: [*]const u8, len: usize, out: *?*InputLayout) HRESULT {
        return s(self, 11, fn (*Device, [*]const INPUT_ELEMENT_DESC, u32, [*]const u8, usize, *?*InputLayout) callconv(.winapi) HRESULT)(self, elems, n, bytecode, len, out);
    }
    pub fn CreateVertexShader(self: *Device, bytecode: [*]const u8, len: usize, linkage: ?*anyopaque, out: *?*VertexShader) HRESULT {
        return s(self, 12, fn (*Device, [*]const u8, usize, ?*anyopaque, *?*VertexShader) callconv(.winapi) HRESULT)(self, bytecode, len, linkage, out);
    }
    pub fn CreatePixelShader(self: *Device, bytecode: [*]const u8, len: usize, linkage: ?*anyopaque, out: *?*PixelShader) HRESULT {
        return s(self, 15, fn (*Device, [*]const u8, usize, ?*anyopaque, *?*PixelShader) callconv(.winapi) HRESULT)(self, bytecode, len, linkage, out);
    }
    pub fn CreateBlendState(self: *Device, desc: *const BLEND_DESC, out: *?*BlendState) HRESULT {
        return s(self, 20, fn (*Device, *const BLEND_DESC, *?*BlendState) callconv(.winapi) HRESULT)(self, desc, out);
    }
    pub fn CreateRasterizerState(self: *Device, desc: *const RASTERIZER_DESC, out: *?*RasterizerState) HRESULT {
        return s(self, 22, fn (*Device, *const RASTERIZER_DESC, *?*RasterizerState) callconv(.winapi) HRESULT)(self, desc, out);
    }
    pub fn CreateSamplerState(self: *Device, desc: *const SAMPLER_DESC, out: *?*SamplerState) HRESULT {
        return s(self, 23, fn (*Device, *const SAMPLER_DESC, *?*SamplerState) callconv(.winapi) HRESULT)(self, desc, out);
    }
    pub fn CreateQuery(self: *Device, desc: *const QUERY_DESC, out: *?*Query) HRESULT {
        return s(self, 24, fn (*Device, *const QUERY_DESC, *?*Query) callconv(.winapi) HRESULT)(self, desc, out);
    }
    pub fn GetFeatureLevel(self: *Device) u32 {
        return s(self, 37, fn (*Device) callconv(.winapi) u32)(self);
    }
    pub fn GetDeviceRemovedReason(self: *Device) HRESULT {
        return s(self, 39, fn (*Device) callconv(.winapi) HRESULT)(self);
    }
    pub fn GetImmediateContext(self: *Device, out: *?*DeviceContext) void {
        s(self, 40, fn (*Device, *?*DeviceContext) callconv(.winapi) void)(self, out);
    }
};

pub const DeviceContext = extern struct {
    vtbl: Vtbl,
    const I = Interface(DeviceContext);
    pub const Release = I.Release;
    const s = I.slot;

    pub fn VSSetConstantBuffers(self: *DeviceContext, start: u32, n: u32, bufs: [*]const ?*Buffer) void {
        s(self, 7, fn (*DeviceContext, u32, u32, [*]const ?*Buffer) callconv(.winapi) void)(self, start, n, bufs);
    }
    pub fn PSSetShaderResources(self: *DeviceContext, start: u32, n: u32, views: [*]const ?*ShaderResourceView) void {
        s(self, 8, fn (*DeviceContext, u32, u32, [*]const ?*ShaderResourceView) callconv(.winapi) void)(self, start, n, views);
    }
    pub fn PSSetShader(self: *DeviceContext, sh: ?*PixelShader) void {
        s(self, 9, fn (*DeviceContext, ?*PixelShader, ?*const anyopaque, u32) callconv(.winapi) void)(self, sh, null, 0);
    }
    pub fn PSSetSamplers(self: *DeviceContext, start: u32, n: u32, samplers: [*]const ?*SamplerState) void {
        s(self, 10, fn (*DeviceContext, u32, u32, [*]const ?*SamplerState) callconv(.winapi) void)(self, start, n, samplers);
    }
    pub fn VSSetShader(self: *DeviceContext, sh: ?*VertexShader) void {
        s(self, 11, fn (*DeviceContext, ?*VertexShader, ?*const anyopaque, u32) callconv(.winapi) void)(self, sh, null, 0);
    }
    pub fn Map(self: *DeviceContext, res: *Resource, sub: u32, map_type: u32, flags: u32, out: *MAPPED_SUBRESOURCE) HRESULT {
        return s(self, 14, fn (*DeviceContext, *Resource, u32, u32, u32, *MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT)(self, res, sub, map_type, flags, out);
    }
    pub fn Unmap(self: *DeviceContext, res: *Resource, sub: u32) void {
        s(self, 15, fn (*DeviceContext, *Resource, u32) callconv(.winapi) void)(self, res, sub);
    }
    pub fn PSSetConstantBuffers(self: *DeviceContext, start: u32, n: u32, bufs: [*]const ?*Buffer) void {
        s(self, 16, fn (*DeviceContext, u32, u32, [*]const ?*Buffer) callconv(.winapi) void)(self, start, n, bufs);
    }
    pub fn IASetInputLayout(self: *DeviceContext, layout: ?*InputLayout) void {
        s(self, 17, fn (*DeviceContext, ?*InputLayout) callconv(.winapi) void)(self, layout);
    }
    pub fn IASetVertexBuffers(self: *DeviceContext, start: u32, n: u32, bufs: [*]const ?*Buffer, strides: [*]const u32, offsets: [*]const u32) void {
        s(self, 18, fn (*DeviceContext, u32, u32, [*]const ?*Buffer, [*]const u32, [*]const u32) callconv(.winapi) void)(self, start, n, bufs, strides, offsets);
    }
    pub fn DrawInstanced(self: *DeviceContext, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
        s(self, 21, fn (*DeviceContext, u32, u32, u32, u32) callconv(.winapi) void)(self, vertices, instances, first_vertex, first_instance);
    }
    pub fn IASetPrimitiveTopology(self: *DeviceContext, topo: u32) void {
        s(self, 24, fn (*DeviceContext, u32) callconv(.winapi) void)(self, topo);
    }
    pub fn Begin(self: *DeviceContext, q: *Query) void {
        s(self, 27, fn (*DeviceContext, *Query) callconv(.winapi) void)(self, q);
    }
    pub fn End(self: *DeviceContext, q: *Query) void {
        s(self, 28, fn (*DeviceContext, *Query) callconv(.winapi) void)(self, q);
    }
    pub fn GetData(self: *DeviceContext, q: *Query, data: ?*anyopaque, size: u32, flags: u32) HRESULT {
        return s(self, 29, fn (*DeviceContext, *Query, ?*anyopaque, u32, u32) callconv(.winapi) HRESULT)(self, q, data, size, flags);
    }
    pub fn OMSetRenderTargets(self: *DeviceContext, n: u32, views: ?[*]const ?*RenderTargetView, dsv: ?*anyopaque) void {
        s(self, 33, fn (*DeviceContext, u32, ?[*]const ?*RenderTargetView, ?*anyopaque) callconv(.winapi) void)(self, n, views, dsv);
    }
    pub fn OMSetBlendState(self: *DeviceContext, state: ?*BlendState, factor: ?*const [4]f32, mask: u32) void {
        s(self, 35, fn (*DeviceContext, ?*BlendState, ?*const [4]f32, u32) callconv(.winapi) void)(self, state, factor, mask);
    }
    pub fn RSSetState(self: *DeviceContext, state: ?*RasterizerState) void {
        s(self, 43, fn (*DeviceContext, ?*RasterizerState) callconv(.winapi) void)(self, state);
    }
    pub fn RSSetViewports(self: *DeviceContext, n: u32, vps: [*]const VIEWPORT) void {
        s(self, 44, fn (*DeviceContext, u32, [*]const VIEWPORT) callconv(.winapi) void)(self, n, vps);
    }
    pub fn RSSetScissorRects(self: *DeviceContext, n: u32, rects: [*]const RECT) void {
        s(self, 45, fn (*DeviceContext, u32, [*]const RECT) callconv(.winapi) void)(self, n, rects);
    }
    pub fn CopySubresourceRegion(self: *DeviceContext, dst: *Resource, dst_sub: u32, x: u32, y: u32, z: u32, src: *Resource, src_sub: u32, box: ?*const BOX) void {
        s(self, 46, fn (*DeviceContext, *Resource, u32, u32, u32, u32, *Resource, u32, ?*const BOX) callconv(.winapi) void)(self, dst, dst_sub, x, y, z, src, src_sub, box);
    }
    pub fn CopyResource(self: *DeviceContext, dst: *Resource, src: *Resource) void {
        s(self, 47, fn (*DeviceContext, *Resource, *Resource) callconv(.winapi) void)(self, dst, src);
    }
    pub fn UpdateSubresource(self: *DeviceContext, dst: *Resource, sub: u32, box: ?*const BOX, data: *const anyopaque, row_pitch: u32, depth_pitch: u32) void {
        s(self, 48, fn (*DeviceContext, *Resource, u32, ?*const BOX, *const anyopaque, u32, u32) callconv(.winapi) void)(self, dst, sub, box, data, row_pitch, depth_pitch);
    }
    pub fn ClearRenderTargetView(self: *DeviceContext, view: *RenderTargetView, color: *const [4]f32) void {
        s(self, 50, fn (*DeviceContext, *RenderTargetView, *const [4]f32) callconv(.winapi) void)(self, view, color);
    }
    pub fn GenerateMips(self: *DeviceContext, view: *ShaderResourceView) void {
        s(self, 54, fn (*DeviceContext, *ShaderResourceView) callconv(.winapi) void)(self, view);
    }
    pub fn ClearState(self: *DeviceContext) void {
        s(self, 110, fn (*DeviceContext) callconv(.winapi) void)(self);
    }
    pub fn Flush(self: *DeviceContext) void {
        s(self, 111, fn (*DeviceContext) callconv(.winapi) void)(self);
    }
};

/// ID3D11Resource / ID3D11Buffer / ID3D11Texture2D share the resource prefix; views,
/// states and shaders only need Release.
pub const Resource = extern struct {
    vtbl: Vtbl,
    pub const Release = Interface(Resource).Release;
};
pub const Buffer = extern struct {
    vtbl: Vtbl,
    pub const Release = Interface(Buffer).Release;
    pub fn resource(self: *Buffer) *Resource {
        return @ptrCast(self);
    }
};
pub const Texture2D = extern struct {
    vtbl: Vtbl,
    pub const Release = Interface(Texture2D).Release;
    pub fn resource(self: *Texture2D) *Resource {
        return @ptrCast(self);
    }
    pub fn GetDesc(self: *Texture2D, out: *TEXTURE2D_DESC) void {
        Interface(Texture2D).slot(self, 10, fn (*Texture2D, *TEXTURE2D_DESC) callconv(.winapi) void)(self, out);
    }
};
fn Plain(comptime _: anytype) type {
    return extern struct {
        vtbl: Vtbl,
        const Self = @This();
        pub fn Release(self: *Self) u32 {
            return Interface(Self).slot(self, 2, fn (*Self) callconv(.winapi) u32)(self);
        }
    };
}
pub const ShaderResourceView = Plain(.srv);
pub const RenderTargetView = Plain(.rtv);
pub const InputLayout = Plain(.layout);
pub const VertexShader = Plain(.vs);
pub const PixelShader = Plain(.ps);
pub const BlendState = Plain(.blend);
pub const RasterizerState = Plain(.raster);
pub const SamplerState = Plain(.sampler);
pub const Query = Plain(.query);

pub const DXGIDevice = extern struct {
    vtbl: Vtbl,
    const I = Interface(DXGIDevice);
    pub const Release = I.Release;
    pub const QueryInterface = I.QueryInterface;
    pub fn GetAdapter(self: *DXGIDevice, out: *?*DXGIAdapter) HRESULT {
        return I.slot(self, 7, fn (*DXGIDevice, *?*DXGIAdapter) callconv(.winapi) HRESULT)(self, out);
    }
    /// IDXGIDevice1::SetMaximumFrameLatency (slot 12).
    pub fn SetMaximumFrameLatency(self: *DXGIDevice, n: u32) HRESULT {
        return I.slot(self, 12, fn (*DXGIDevice, u32) callconv(.winapi) HRESULT)(self, n);
    }
};

pub const DXGIAdapter = extern struct {
    vtbl: Vtbl,
    const I = Interface(DXGIAdapter);
    pub const Release = I.Release;
    pub fn GetParent(self: *DXGIAdapter, iid: *const GUID, out: *?*anyopaque) HRESULT {
        return I.slot(self, 6, fn (*DXGIAdapter, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT)(self, iid, out);
    }
    pub fn GetDesc(self: *DXGIAdapter, out: *DXGI_ADAPTER_DESC) HRESULT {
        return I.slot(self, 8, fn (*DXGIAdapter, *DXGI_ADAPTER_DESC) callconv(.winapi) HRESULT)(self, out);
    }
};

pub const DXGIFactory2 = extern struct {
    vtbl: Vtbl,
    const I = Interface(DXGIFactory2);
    pub const Release = I.Release;
    pub const QueryInterface = I.QueryInterface;
    pub fn MakeWindowAssociation(self: *DXGIFactory2, hwnd: HANDLE, flags: u32) HRESULT {
        return I.slot(self, 8, fn (*DXGIFactory2, HANDLE, u32) callconv(.winapi) HRESULT)(self, hwnd, flags);
    }
    pub fn CreateSwapChainForHwnd(self: *DXGIFactory2, device: *Unknown, hwnd: HANDLE, desc: *const DXGI_SWAP_CHAIN_DESC1, fullscreen: ?*const anyopaque, output: ?*anyopaque, out: *?*SwapChain) HRESULT {
        return I.slot(self, 15, fn (*DXGIFactory2, *Unknown, HANDLE, *const DXGI_SWAP_CHAIN_DESC1, ?*const anyopaque, ?*anyopaque, *?*SwapChain) callconv(.winapi) HRESULT)(self, device, hwnd, desc, fullscreen, output, out);
    }
};

/// IDXGIFactory5::CheckFeatureSupport (slot 28).
pub const DXGIFactory5 = extern struct {
    vtbl: Vtbl,
    const I = Interface(DXGIFactory5);
    pub const Release = I.Release;
    pub fn CheckFeatureSupport(self: *DXGIFactory5, feature: u32, data: *anyopaque, size: u32) HRESULT {
        return I.slot(self, 28, fn (*DXGIFactory5, u32, *anyopaque, u32) callconv(.winapi) HRESULT)(self, feature, data, size);
    }
};
pub const DXGI_FEATURE_PRESENT_ALLOW_TEARING: u32 = 0;

/// IDXGISwapChain1 (+ IDXGISwapChain2 slots when queried as such).
pub const SwapChain = extern struct {
    vtbl: Vtbl,
    const I = Interface(SwapChain);
    pub const Release = I.Release;
    pub const QueryInterface = I.QueryInterface;
    pub fn Present(self: *SwapChain, sync: u32, flags: u32) HRESULT {
        return I.slot(self, 8, fn (*SwapChain, u32, u32) callconv(.winapi) HRESULT)(self, sync, flags);
    }
    pub fn GetBuffer(self: *SwapChain, index: u32, iid: *const GUID, out: *?*anyopaque) HRESULT {
        return I.slot(self, 9, fn (*SwapChain, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT)(self, index, iid, out);
    }
    pub fn ResizeBuffers(self: *SwapChain, count: u32, w: u32, h: u32, format: DXGI_FORMAT, flags: u32) HRESULT {
        return I.slot(self, 13, fn (*SwapChain, u32, u32, u32, DXGI_FORMAT, u32) callconv(.winapi) HRESULT)(self, count, w, h, format, flags);
    }
    pub fn Present1(self: *SwapChain, sync: u32, flags: u32, params: *const DXGI_PRESENT_PARAMETERS) HRESULT {
        return I.slot(self, 22, fn (*SwapChain, u32, u32, *const DXGI_PRESENT_PARAMETERS) callconv(.winapi) HRESULT)(self, sync, flags, params);
    }
    /// IDXGISwapChain2 only.
    pub fn SetMaximumFrameLatency(self: *SwapChain, n: u32) HRESULT {
        return I.slot(self, 31, fn (*SwapChain, u32) callconv(.winapi) HRESULT)(self, n);
    }
    /// IDXGISwapChain2 only.
    pub fn GetFrameLatencyWaitableObject(self: *SwapChain) ?HANDLE {
        return I.slot(self, 33, fn (*SwapChain) callconv(.winapi) ?HANDLE)(self);
    }
};

// ---- Entry points ---------------------------------------------------------------------------

pub extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*DXGIAdapter,
    driver_type: u32,
    software: ?*anyopaque,
    flags: u32,
    levels: ?[*]const u32,
    n_levels: u32,
    sdk_version: u32,
    device: ?*?*Device,
    level: ?*u32,
    context: ?*?*DeviceContext,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObjectEx(h: HANDLE, ms: u32, alertable: BOOL) callconv(.winapi) u32;

test "COM structs match the C layouts" {
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(TEXTURE2D_DESC));
    try std.testing.expectEqual(@as(usize, 52), @sizeOf(SAMPLER_DESC));
    try std.testing.expectEqual(@as(usize, 8 + 8 * 32), @sizeOf(BLEND_DESC));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(RASTERIZER_DESC));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(DXGI_SWAP_CHAIN_DESC1));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(BUFFER_DESC));
    try std.testing.expectEqual(@sizeOf(usize) + 24, @sizeOf(INPUT_ELEMENT_DESC));
}
