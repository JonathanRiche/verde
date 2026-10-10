//! Metal render targets: an offscreen texture with CPU readback (goldens, tools) and the
//! window target behind a CAMetalLayer.
//!
//! Window presentation keeps one persistent private BGRA8 backbuffer per window. Partial
//! redraws (damage) only touch the scissored rects of that texture; every presented frame
//! then blits the whole backbuffer into the layer's next drawable (`framebufferOnly = NO`)
//! and presents it, in the same command buffer. Drawables rotate (and the layer may hand out
//! a fresh one at any time), so they never hold the retained contents themselves.
const std = @import("std");
const draw = @import("../../draw.zig");
const mtl = @import("mtl.zig");
const renderer_mod = @import("renderer.zig");

const objc = mtl.objc;
const Id = mtl.Id;
const NSUInteger = mtl.NSUInteger;
const send = mtl.send;
const Renderer = renderer_mod.Renderer;
const Target = renderer_mod.Target;

// ---- Offscreen --------------------------------------------------------------------------

pub const Offscreen = struct {
    renderer: *Renderer,
    target: Target,
    readback: renderer_mod.Buffer,

    pub fn init(r: *Renderer, width: u32, height: u32) !Offscreen {
        const pool = objc.Pool.push();
        defer pool.pop();
        const tex = try r.ctx.createTargetTexture(width, height);
        errdefer r.ctx.destroyTargetTexture(tex);
        const readback = try r.ctx.createBuffer(@as(usize, width) * height * 4, mtl.ResourceOptions.shared_default);
        return .{ .renderer = r, .target = .{ .texture = tex, .width = width, .height = height }, .readback = readback };
    }

    pub fn deinit(self: *Offscreen) void {
        self.renderer.waitSerial(self.target.last_serial) catch {};
        self.renderer.ctx.destroyTargetTexture(self.target.texture.?);
        self.renderer.ctx.destroyBuffer(&self.readback);
    }

    pub fn render(self: *Offscreen, batch: *const draw.RenderBatch, options: renderer_mod.FrameOptions) !renderer_mod.FrameResult {
        return self.renderer.render(&self.target, batch, options);
    }

    /// Copies the last frame out as tightly packed straight RGBA8 (synchronous; the texture
    /// is BGRA, premultiplied; opaque clears make premultiplied == straight).
    pub fn readRgba(self: *Offscreen, out: []u8) !void {
        const n = @as(usize, self.target.width) * self.target.height * 4;
        std.debug.assert(out.len >= n);
        try self.renderer.readback(&self.target, self.readback);
        const src = self.readback.bytes()[0..n];
        var i: usize = 0;
        while (i < n) : (i += 4) {
            out[i + 0] = src[i + 2];
            out[i + 1] = src[i + 1];
            out[i + 2] = src[i + 0];
            out[i + 3] = src[i + 3];
        }
    }
};

// ---- CAMetalLayer -------------------------------------------------------------------------

pub const LayerOptions = struct {
    @"opaque": bool = true,
    /// Present inside the CoreAnimation transaction (synchronised with window resizes; costs
    /// latency). Off by default.
    presents_with_transaction: bool = false,
    /// Tag the layer as sRGB so WindowServer colour-matches it on wide-gamut (P3) displays,
    /// matching what the colours mean everywhere else (Wayland, goldens). Off = untagged
    /// (device colours: oversaturated on P3 panels).
    srgb_colorspace: bool = true,
};

pub const LayerTarget = struct {
    renderer: *Renderer,
    layer: Id,
    backbuffer: Target,
    /// Frames whose drawable was unavailable (layer offscreen / zero size).
    missed_drawables: u64 = 0,
    presented: u64 = 0,
    /// Set while a frame is recorded: the drawable acquired by `present`.
    present_failed: bool = false,

    /// `layer` is the window's `CAMetalLayer *` (`platform.Window.nativeHandles().metal_layer`).
    /// `width` x `height` is the drawable size in pixels (points x backingScaleFactor).
    pub fn init(r: *Renderer, layer: *anyopaque, pixel_width: u32, pixel_height: u32, options: LayerOptions) !LayerTarget {
        const pool = objc.Pool.push();
        defer pool.pop();
        const l: Id = @ptrCast(layer);
        send(void, l, "setDevice:", .{r.ctx.device});
        send(void, l, "setPixelFormat:", .{renderer_mod.target_format});
        send(void, l, "setFramebufferOnly:", .{objc.NO});
        send(void, l, "setOpaque:", .{if (options.@"opaque") objc.YES else objc.NO});
        send(void, l, "setPresentsWithTransaction:", .{if (options.presents_with_transaction) objc.YES else objc.NO});
        if (options.srgb_colorspace) setSrgb(l);
        var self: LayerTarget = .{ .renderer = r, .layer = objc.retain(l), .backbuffer = .{} };
        errdefer objc.release(l);
        try self.resize(pixel_width, pixel_height);
        return self;
    }

    pub fn deinit(self: *LayerTarget) void {
        self.renderer.waitSerial(self.backbuffer.last_serial) catch {};
        if (self.backbuffer.texture) |t| self.renderer.ctx.destroyTargetTexture(t);
        objc.release(self.layer);
    }

    pub fn width(self: *const LayerTarget) u32 {
        return self.backbuffer.width;
    }

    pub fn height(self: *const LayerTarget) u32 {
        return self.backbuffer.height;
    }

    /// New drawable size: replaces the backbuffer (the next frame is a full redraw).
    pub fn resize(self: *LayerTarget, w: u32, h: u32) !void {
        const ww = @max(w, 1);
        const hh = @max(h, 1);
        if (self.backbuffer.texture != null and ww == self.backbuffer.width and hh == self.backbuffer.height) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const tex = try self.renderer.ctx.createTargetTexture(ww, hh);
        if (self.backbuffer.texture) |old| {
            // In-flight frames retain the old texture through their command buffers.
            self.renderer.ctx.destroyTargetTexture(old);
        }
        self.backbuffer = .{ .texture = tex, .width = ww, .height = hh };
        send(void, self.layer, "setDrawableSize:", .{mtl.CGSize{ .width = @floatFromInt(ww), .height = @floatFromInt(hh) }});
    }

    /// Renders into the backbuffer and, unless the frame was skipped, presents it.
    pub fn render(self: *LayerTarget, batch: *const draw.RenderBatch, options: renderer_mod.FrameOptions) !renderer_mod.FrameResult {
        self.present_failed = false;
        const res = try self.renderer.renderWith(&self.backbuffer, batch, options, .{ .ctx = self, .run = presentPass });
        if (!res.stats.skipped) {
            if (self.present_failed) self.missed_drawables += 1 else self.presented += 1;
        }
        return res;
    }

    fn setSrgb(l: Id) void {
        const create = objc.cSymbol(*const fn (?*const anyopaque) callconv(.c) ?*anyopaque, "CGColorSpaceCreateWithName") orelse return;
        const release = objc.cSymbol(*const fn (?*anyopaque) callconv(.c) void, "CGColorSpaceRelease") orelse return;
        const name = objc.cSymbol(*const ?*const anyopaque, "kCGColorSpaceSRGB") orelse return;
        const cs = create(name.*) orelse return;
        defer release(cs);
        send(void, l, "setColorspace:", .{cs}); // the layer retains it
    }

    fn presentPass(ctx: *anyopaque, cmd: Id, target: *Target) void {
        const self: *LayerTarget = @ptrCast(@alignCast(ctx));
        // May block (up to a second) when all drawables are in use; display-link pacing
        // keeps at most ~2 in flight.
        const drawable = send(?Id, self.layer, "nextDrawable", .{}) orelse {
            self.present_failed = true;
            return;
        };
        const dst = send(Id, drawable, "texture", .{});
        const dw: u32 = @intCast(send(NSUInteger, dst, "width", .{}));
        const dh: u32 = @intCast(send(NSUInteger, dst, "height", .{}));
        const blit = send(Id, cmd, "blitCommandEncoder", .{});
        mtl.copyTextureRegion(blit, target.texture.?, dst, 0, 0, @min(dw, target.width), @min(dh, target.height));
        send(void, blit, "endEncoding", .{});
        send(void, cmd, "presentDrawable:", .{drawable});
    }
};
