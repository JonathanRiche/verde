//! D3D11 render targets: an offscreen texture with CPU readback (goldens, tools) and a
//! flip-model swapchain for windows.
const std = @import("std");
const com = @import("com.zig");
const renderer_mod = @import("renderer.zig");
const draw = @import("../../draw.zig");
const damage = @import("../damage.zig");

const Renderer = renderer_mod.Renderer;
const Target = renderer_mod.Target;

// ---- Offscreen ------------------------------------------------------------------------------

pub const Offscreen = struct {
    renderer: *Renderer,
    target: Target,
    texture: *com.Texture2D,
    readback: ?*com.Texture2D = null,

    pub fn init(r: *Renderer, width: u32, height: u32) !Offscreen {
        const ctx = r.ctx;
        const tex = try ctx.createTexture(.{ .Width = width, .Height = height, .Format = renderer_mod.target_format, .BindFlags = com.BIND_RENDER_TARGET | com.BIND_SHADER_RESOURCE }, null);
        errdefer ctx.destroyTexture(tex);
        var rtv: ?*com.RenderTargetView = null;
        try com.check(ctx.device.CreateRenderTargetView(tex.resource(), null, &rtv));
        return .{ .renderer = r, .target = .{ .rtv = rtv, .width = width, .height = height }, .texture = tex };
    }

    pub fn deinit(self: *Offscreen) void {
        const ctx = self.renderer.ctx;
        com.clear(&self.target.rtv);
        ctx.destroyTexture(self.texture);
        if (self.readback) |rb| ctx.destroyTexture(rb);
    }

    pub fn render(self: *Offscreen, batch: *const draw.RenderBatch, options: renderer_mod.FrameOptions) !renderer_mod.FrameResult {
        return self.renderer.render(&self.target, batch, options);
    }

    /// Copies the last frame out as tightly packed straight RGBA8 (synchronous; the texture
    /// is BGRA, premultiplied; opaque clears make premultiplied == straight).
    pub fn readRgba(self: *Offscreen, out: []u8) !void {
        const ctx = self.renderer.ctx;
        const w = self.target.width;
        const h = self.target.height;
        std.debug.assert(out.len >= @as(usize, w) * h * 4);
        if (self.readback == null) self.readback = try ctx.createTexture(.{ .Width = w, .Height = h, .Format = renderer_mod.target_format, .Usage = com.USAGE_STAGING, .CPUAccessFlags = com.CPU_ACCESS_READ }, null);
        const rb = self.readback.?;
        ctx.dc.CopyResource(rb.resource(), self.texture.resource());
        var mapped: com.MAPPED_SUBRESOURCE = .{};
        try com.check(ctx.dc.Map(rb.resource(), 0, com.MAP_READ, 0, &mapped));
        defer ctx.dc.Unmap(rb.resource(), 0);
        swizzleRows(out, mapped.pData.?, mapped.RowPitch, w, h);
    }
};

/// BGRA rows with `pitch` -> tightly packed RGBA.
pub fn swizzleRows(out: []u8, src: [*]const u8, pitch: usize, w: u32, h: u32) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = src + y * pitch;
        const dst = out[y * @as(usize, w) * 4 ..];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            dst[x * 4 + 0] = row[x * 4 + 2];
            dst[x * 4 + 1] = row[x * 4 + 1];
            dst[x * 4 + 2] = row[x * 4 + 0];
            dst[x * 4 + 3] = row[x * 4 + 3];
        }
    }
}

// ---- Swapchain ------------------------------------------------------------------------------

pub const SwapchainOptions = struct {
    /// 2 or 3 back buffers.
    buffers: u8 = 2,
    /// Present without vsync where the display supports tearing (VRR). Off by default.
    allow_tearing: bool = false,
    /// Render straight into the back buffer with damage = union over the buffer's age and
    /// Present1 dirty rects (flip-sequential keeps back buffer contents). When false, every
    /// presented frame is a full redraw.
    partial_redraw: bool = true,
};

pub const PresentResult = enum {
    presented,
    /// Batch unchanged and the buffer already showed it: nothing submitted or presented.
    unchanged,
    /// The window is fully occluded or minimised (DXGI_STATUS_OCCLUDED): the frame was
    /// dropped; repaint after the next `window_shown` / resize.
    occluded,
};

/// Flip-model swapchain (DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL, BGRA8) on an HWND with a frame
/// latency waitable object (`waitable`, signalled when the compositor can take a frame:
/// the platform layer waits on it to emit `frame` events, so idle windows cost 0% CPU).
///
/// D3D11 renames buffer 0 to the current back buffer after every Present, so one RTV works;
/// with N buffers the back buffer holds the frame presented N presents ago. Each slot keeps
/// its damage-history frame (`Target.last_frame`), which gives the encoder the buffer age.
pub const Swapchain = struct {
    renderer: *Renderer,
    swapchain: *com.SwapChain,
    waitable: ?com.HANDLE = null,
    options: SwapchainOptions,
    flags: u32,
    width: u32,
    height: u32,
    buffer_count: u32,
    rtv: ?*com.RenderTargetView = null,
    slots: [3]Target = @splat(.{}),
    presents: u64 = 0,
    dirty_rects: [damage.max_rects]com.RECT = undefined,

    pub fn init(r: *Renderer, hwnd: *anyopaque, width: u32, height: u32, options: SwapchainOptions) !Swapchain {
        const ctx = r.ctx;
        const count: u32 = std.math.clamp(options.buffers, 2, 3);
        var flags: u32 = com.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
        if (options.allow_tearing and ctx.caps.allow_tearing) flags |= com.DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING;
        const desc: com.DXGI_SWAP_CHAIN_DESC1 = .{
            .Width = @max(width, 1),
            .Height = @max(height, 1),
            .Format = renderer_mod.target_format,
            .BufferCount = count,
            .Scaling = com.DXGI_SCALING_NONE,
            .SwapEffect = com.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            .AlphaMode = com.DXGI_ALPHA_MODE_IGNORE,
            .Flags = flags,
        };
        var sc: ?*com.SwapChain = null;
        var hr = ctx.factory.CreateSwapChainForHwnd(@ptrCast(ctx.device), hwnd, &desc, null, null, &sc);
        if (!com.succeeded(hr)) {
            // Older systems: DXGI_SCALING_NONE needs Windows 8; fall back to STRETCH.
            var d2 = desc;
            d2.Scaling = com.DXGI_SCALING_STRETCH;
            hr = ctx.factory.CreateSwapChainForHwnd(@ptrCast(ctx.device), hwnd, &d2, null, null, &sc);
        }
        try com.check(hr);
        errdefer _ = sc.?.Release();
        // Alt+Enter exclusive fullscreen is not used (borderless fullscreen is the window's job).
        _ = ctx.factory.MakeWindowAssociation(hwnd, com.DXGI_MWA_NO_ALT_ENTER);
        var self: Swapchain = .{
            .renderer = r,
            .swapchain = sc.?,
            .options = options,
            .flags = flags,
            .width = desc.Width,
            .height = desc.Height,
            .buffer_count = count,
        };
        var sc2: ?*anyopaque = null;
        if (com.succeeded(sc.?.QueryInterface(&com.IID_IDXGISwapChain2, &sc2)) and sc2 != null) {
            const s2: *com.SwapChain = @ptrCast(@alignCast(sc2.?));
            _ = s2.SetMaximumFrameLatency(1);
            self.waitable = s2.GetFrameLatencyWaitableObject();
            _ = s2.Release();
        }
        try self.createView();
        return self;
    }

    pub fn deinit(self: *Swapchain) void {
        self.renderer.ctx.dc.OMSetRenderTargets(0, null, null);
        com.clear(&self.rtv);
        if (self.waitable) |h| _ = com.CloseHandle(h);
        _ = self.swapchain.Release();
    }

    fn createView(self: *Swapchain) !void {
        var buf: ?*anyopaque = null;
        try com.check(self.swapchain.GetBuffer(0, &com.IID_ID3D11Texture2D, &buf));
        const tex: *com.Texture2D = @ptrCast(@alignCast(buf.?));
        defer _ = tex.Release();
        try com.check(self.renderer.ctx.device.CreateRenderTargetView(tex.resource(), null, &self.rtv));
        for (&self.slots) |*s| s.* = .{ .width = self.width, .height = self.height };
    }

    pub fn resize(self: *Swapchain, width: u32, height: u32) !void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        if (w == self.width and h == self.height) return;
        const dc = self.renderer.ctx.dc;
        dc.OMSetRenderTargets(0, null, null);
        com.clear(&self.rtv);
        dc.ClearState();
        dc.Flush();
        try com.check(self.swapchain.ResizeBuffers(0, w, h, .unknown, self.flags));
        self.width = w;
        self.height = h;
        self.presents = 0;
        try self.createView();
    }

    /// Contents of every buffer are undefined (e.g. after occlusion): next frame is full.
    pub fn invalidate(self: *Swapchain) void {
        for (&self.slots) |*s| s.invalidate();
    }

    /// Blocks until the swapchain can accept a frame (or `timeout_ms`). Returns false on
    /// timeout. Hosts that use the platform's `frame` events never need to call this.
    pub fn waitReady(self: *Swapchain, timeout_ms: u32) bool {
        const h = self.waitable orelse return true;
        return com.WaitForSingleObjectEx(h, timeout_ms, 1) == 0;
    }

    /// True while the window is still occluded (Present with DXGI_PRESENT_TEST: nothing is
    /// presented). Lets a host skip rendering until the window can be seen again.
    pub fn stillOccluded(self: *Swapchain) bool {
        return self.swapchain.Present(0, com.DXGI_PRESENT_TEST) == com.DXGI_STATUS_OCCLUDED;
    }

    /// Bytes of the back buffers (BGRA8).
    pub fn bufferBytes(self: *const Swapchain) u64 {
        return @as(u64, self.width) * self.height * 4 * self.buffer_count;
    }

    pub fn render(self: *Swapchain, batch: *const draw.RenderBatch, options: renderer_mod.FrameOptions) !struct { result: PresentResult, frame: renderer_mod.FrameResult } {
        const slot = &self.slots[@intCast(self.presents % self.buffer_count)];
        slot.rtv = self.rtv;
        slot.width = self.width;
        slot.height = self.height;
        var opts = options;
        if (!self.options.partial_redraw) opts.force_full = true;
        const res = try self.renderer.render(slot, batch, opts);
        if (res.stats.skipped) {
            // The batch is unchanged *and* this buffer already shows it; the screen shows the
            // previous present, which is the same batch.
            return .{ .result = .unchanged, .frame = res };
        }
        // Every other buffer's history is unaffected; this one now holds the new frame.
        var params: com.DXGI_PRESENT_PARAMETERS = .{};
        if (!res.stats.full_redraw and self.presents >= self.buffer_count) {
            var n: u32 = 0;
            for (res.damage) |d| {
                if (d.w <= 0 or d.h <= 0) continue;
                self.dirty_rects[n] = .{ .left = d.x, .top = d.y, .right = d.x + d.w, .bottom = d.y + d.h };
                n += 1;
            }
            if (n > 0) {
                params.DirtyRectsCount = n;
                params.pDirtyRects = &self.dirty_rects;
            }
        }
        const tearing = (self.flags & com.DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING) != 0;
        const hr = self.swapchain.Present1(if (tearing) 0 else 1, if (tearing) 0x200 else 0, &params); // 0x200 = DXGI_PRESENT_ALLOW_TEARING
        if (hr == com.DXGI_STATUS_OCCLUDED) {
            self.invalidate();
            self.presents += 1;
            return .{ .result = .occluded, .frame = res };
        }
        try com.check(hr);
        self.presents += 1;
        return .{ .result = .presented, .frame = res };
    }
};
