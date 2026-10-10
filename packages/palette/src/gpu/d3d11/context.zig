//! D3D11 device + immediate context, submission serials (event queries) and memory stats.
const std = @import("std");
const com = @import("com.zig");
const core = @import("../core.zig");

pub const ContextOptions = struct {
    /// Accepted for API parity with the Vulkan backend (a DRM device id); ignored.
    preferred_device: ?u64 = null,
    /// Create the device with D3D11_CREATE_DEVICE_DEBUG (needs the SDK layers installed).
    debug: bool = false,
    /// Use the WARP software rasterizer instead of the hardware adapter.
    warp: bool = false,
};

pub const Caps = struct {
    feature_level: u32 = 0,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    /// DXGI_FEATURE_PRESENT_ALLOW_TEARING (variable refresh displays).
    allow_tearing: bool = false,
    software: bool = false,
};

const query_ring = 8;

pub const Context = struct {
    gpa: std.mem.Allocator,
    device: *com.Device,
    dc: *com.DeviceContext,
    factory: *com.DXGIFactory2,
    caps: Caps = .{},
    memory: core.MemoryStats = .{},

    /// Serial of the last submitted frame (0 = none).
    submit_serial: u64 = 0,
    completed_serial: u64 = 0,
    queries: [query_ring]?*com.Query = @splat(null),
    query_serials: [query_ring]u64 = @splat(0),

    pub fn init(gpa: std.mem.Allocator, options: ContextOptions) !*Context {
        const levels = [_]u32{ com.FEATURE_LEVEL_11_1, com.FEATURE_LEVEL_11_0, com.FEATURE_LEVEL_10_1, com.FEATURE_LEVEL_10_0 };
        var flags: u32 = com.CREATE_DEVICE_BGRA_SUPPORT;
        if (options.debug) flags |= com.CREATE_DEVICE_DEBUG;
        var device: ?*com.Device = null;
        var dc: ?*com.DeviceContext = null;
        var level: u32 = 0;
        const driver: u32 = if (options.warp) com.DRIVER_TYPE_WARP else com.DRIVER_TYPE_HARDWARE;
        var hr = com.D3D11CreateDevice(null, driver, null, flags, &levels, levels.len, com.SDK_VERSION, &device, &level, &dc);
        // Pre-11.1 runtimes reject FEATURE_LEVEL_11_1 in the list.
        if (hr == @as(com.HRESULT, @bitCast(@as(u32, 0x80070057)))) hr = com.D3D11CreateDevice(null, driver, null, flags, levels[1..].ptr, levels.len - 1, com.SDK_VERSION, &device, &level, &dc);
        if (!com.succeeded(hr) or device == null or dc == null) return error.NoSuitableGpu;
        errdefer {
            _ = dc.?.Release();
            _ = device.?.Release();
        }

        // device -> IDXGIDevice -> adapter -> IDXGIFactory2 (the factory that made the device).
        var dxgi_dev_raw: ?*anyopaque = null;
        try com.check(device.?.QueryInterface(&com.IID_IDXGIDevice1, &dxgi_dev_raw));
        const dxgi_dev: *com.DXGIDevice = @ptrCast(@alignCast(dxgi_dev_raw.?));
        defer _ = dxgi_dev.Release();
        // Keep at most one frame queued in the driver (low latency; the swapchain's
        // waitable object adds its own limit).
        _ = dxgi_dev.SetMaximumFrameLatency(1);
        var adapter: ?*com.DXGIAdapter = null;
        try com.check(dxgi_dev.GetAdapter(&adapter));
        defer _ = adapter.?.Release();
        var caps: Caps = .{ .feature_level = level, .software = options.warp };
        var desc: com.DXGI_ADAPTER_DESC = undefined;
        if (com.succeeded(adapter.?.GetDesc(&desc))) {
            caps.vendor_id = desc.VendorId;
            caps.device_id = desc.DeviceId;
            // Microsoft Basic Render Driver.
            if (desc.VendorId == 0x1414 and desc.DeviceId == 0x8c) caps.software = true;
        }
        var factory_raw: ?*anyopaque = null;
        if (!com.succeeded(adapter.?.GetParent(&com.IID_IDXGIFactory2, &factory_raw)) or factory_raw == null) return error.NoSuitableGpu;
        const factory: *com.DXGIFactory2 = @ptrCast(@alignCast(factory_raw.?));
        errdefer _ = factory.Release();
        {
            var f5: ?*anyopaque = null;
            if (com.succeeded(factory.QueryInterface(&com.IID_IDXGIFactory5, &f5)) and f5 != null) {
                const factory5: *com.DXGIFactory5 = @ptrCast(@alignCast(f5.?));
                var allow: com.BOOL = 0;
                if (com.succeeded(factory5.CheckFeatureSupport(com.DXGI_FEATURE_PRESENT_ALLOW_TEARING, &allow, @sizeOf(com.BOOL)))) caps.allow_tearing = allow != 0;
                _ = factory5.Release();
            }
        }

        const self = try gpa.create(Context);
        self.* = .{ .gpa = gpa, .device = device.?, .dc = dc.?, .factory = factory, .caps = caps };
        return self;
    }

    pub fn deinit(self: *Context) void {
        for (&self.queries) |*q| com.clear(q);
        self.dc.ClearState();
        self.dc.Flush();
        _ = self.factory.Release();
        _ = self.dc.Release();
        _ = self.device.Release();
        self.gpa.destroy(self);
    }

    // ---- Serials ----------------------------------------------------------------------------

    /// Ends a submission: issues an event query tagged with the next serial.
    pub fn submit(self: *Context) u64 {
        self.submit_serial += 1;
        const serial = self.submit_serial;
        const slot: usize = @intCast(serial % query_ring);
        if (self.queries[slot] == null) {
            const desc: com.QUERY_DESC = .{ .Query = com.QUERY_EVENT };
            _ = self.device.CreateQuery(&desc, &self.queries[slot]);
        } else if (self.query_serials[slot] > self.completed_serial) {
            // Reusing an unfinished query: its serial is now unobservable, wait for it.
            self.waitSlot(slot);
        }
        if (self.queries[slot]) |q| {
            self.dc.End(q);
            self.query_serials[slot] = serial;
        } else {
            self.query_serials[slot] = 0;
        }
        return serial;
    }

    fn queryDone(self: *Context, slot: usize, flush: bool) bool {
        const q = self.queries[slot] orelse return true;
        var done: com.BOOL = 0;
        const hr = self.dc.GetData(q, &done, @sizeOf(com.BOOL), if (flush) 0 else 1); // 1 = DO_NOT_FLUSH
        return hr == 0 or !com.succeeded(hr);
    }

    fn waitSlot(self: *Context, slot: usize) void {
        const serial = self.query_serials[slot];
        while (!self.queryDone(slot, true)) std.atomic.spinLoopHint();
        self.markCompleted(serial);
    }

    pub fn markCompleted(self: *Context, serial: u64) void {
        if (serial > self.completed_serial) self.completed_serial = serial;
    }

    /// Non-blocking: advances `completed_serial` over finished submissions.
    pub fn pollCompleted(self: *Context) void {
        var best = self.completed_serial;
        for (self.query_serials, 0..) |s, i| {
            if (s > best and self.queryDone(i, false)) best = s;
        }
        // Event queries complete in order: everything up to the newest finished one is done.
        self.markCompleted(best);
    }

    /// Blocks until submission `serial` finished.
    pub fn waitSerial(self: *Context, serial: u64) void {
        if (serial == 0 or serial <= self.completed_serial) return;
        const slot: usize = @intCast(serial % query_ring);
        if (self.query_serials[slot] == serial) {
            self.waitSlot(slot);
            return;
        }
        // Older than the ring: the newest query covers it.
        const newest: usize = @intCast(self.submit_serial % query_ring);
        self.waitSlot(newest);
    }

    // ---- Resources --------------------------------------------------------------------------

    pub fn track(self: *Context, bytes: u64, host_visible: bool) void {
        self.memory.allocation_count += 1;
        if (host_visible) self.memory.host_visible_bytes += bytes else self.memory.device_local_bytes += bytes;
    }

    pub fn untrack(self: *Context, bytes: u64, host_visible: bool) void {
        self.memory.allocation_count -|= 1;
        if (host_visible) self.memory.host_visible_bytes -|= bytes else self.memory.device_local_bytes -|= bytes;
    }

    pub fn createTexture(self: *Context, desc: com.TEXTURE2D_DESC, init_data: ?[*]const com.SUBRESOURCE_DATA) !*com.Texture2D {
        var tex: ?*com.Texture2D = null;
        try com.check(self.device.CreateTexture2D(&desc, init_data, &tex));
        self.track(textureBytes(desc), desc.Usage == com.USAGE_STAGING or desc.Usage == com.USAGE_DYNAMIC);
        return tex.?;
    }

    pub fn destroyTexture(self: *Context, tex: *com.Texture2D) void {
        var desc: com.TEXTURE2D_DESC = undefined;
        tex.GetDesc(&desc);
        self.untrack(textureBytes(desc), desc.Usage == com.USAGE_STAGING or desc.Usage == com.USAGE_DYNAMIC);
        _ = tex.Release();
    }

    pub fn createBuffer(self: *Context, desc: com.BUFFER_DESC) !*com.Buffer {
        var buf: ?*com.Buffer = null;
        try com.check(self.device.CreateBuffer(&desc, null, &buf));
        self.track(desc.ByteWidth, desc.Usage == com.USAGE_DYNAMIC);
        return buf.?;
    }

    pub fn destroyBuffer(self: *Context, buf: *com.Buffer, desc: com.BUFFER_DESC) void {
        self.untrack(desc.ByteWidth, desc.Usage == com.USAGE_DYNAMIC);
        _ = buf.Release();
    }

    pub fn srv(self: *Context, tex: *com.Texture2D) !*com.ShaderResourceView {
        var view: ?*com.ShaderResourceView = null;
        try com.check(self.device.CreateShaderResourceView(tex.resource(), null, &view));
        return view.?;
    }
};

fn textureBytes(desc: com.TEXTURE2D_DESC) u64 {
    const bpp: u64 = if (desc.Format == .r8_unorm) 1 else 4;
    var total: u64 = 0;
    var w: u64 = desc.Width;
    var h: u64 = desc.Height;
    var level: u32 = 0;
    const levels = if (desc.MipLevels == 0) 1 else desc.MipLevels;
    while (level < levels) : (level += 1) {
        total += w * h * bpp;
        w = @max(w / 2, 1);
        h = @max(h / 2, 1);
    }
    return total;
}
