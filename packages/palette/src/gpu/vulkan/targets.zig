//! Render targets: an offscreen image with CPU readback, and a small set of exportable
//! dma-buf images for zero-copy presentation through the Wayland dma-buf protocol.
//!
//! Dma-buf sync (no WSI): before rendering into a buffer the compositor may still be reading,
//! its implicit fences are exported as a sync_file (DMA_BUF_IOCTL_EXPORT_SYNC_FILE) and
//! imported as a temporary semaphore wait. After submitting, a SYNC_FD semaphore signalled by
//! the submission is exported and attached to the dma-buf as its write fence
//! (DMA_BUF_IOCTL_IMPORT_SYNC_FILE), so the compositor's implicit sync waits for our
//! rendering without any CPU stall. Kernels/drivers without those paths fall back to a CPU
//! fence wait before handing the buffer over.

const std = @import("std");
const vk = @import("vk.zig");
const context = @import("context.zig");
const renderer_mod = @import("renderer.zig");
const present = @import("../../platform/present.zig");
const draw = @import("../../draw.zig");

const Context = context.Context;
const Renderer = renderer_mod.Renderer;
const Target = renderer_mod.Target;

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;

fn createFramebuffer(r: *Renderer, view: vk.ImageView, width: u32, height: u32) !vk.Framebuffer {
    const info: vk.FramebufferCreateInfo = .{
        .renderPass = r.renderPass(),
        .attachmentCount = 1,
        .pAttachments = @ptrCast(&view),
        .width = width,
        .height = height,
        .layers = 1,
    };
    var fb: vk.Framebuffer = .null_handle;
    try vk.check(r.ctx.vkd.vkCreateFramebuffer(r.ctx.device, &info, null, &fb));
    return fb;
}

fn createView(ctx: *Context, image: vk.Image) !vk.ImageView {
    const info: vk.ImageViewCreateInfo = .{
        .image = image,
        .viewType = .@"2d",
        .format = renderer_mod.target_format,
        .components = .{},
        .subresourceRange = .{ .aspectMask = vk.ImageAspectFlags.color, .levelCount = 1, .layerCount = 1 },
    };
    var view: vk.ImageView = .null_handle;
    try vk.check(ctx.vkd.vkCreateImageView(ctx.device, &info, null, &view));
    return view;
}

// ---- Offscreen --------------------------------------------------------------------------

pub const Offscreen = struct {
    renderer: *Renderer,
    target: Target,
    allocation: context.Allocation,
    readback: Context.Buffer,

    pub fn init(r: *Renderer, width: u32, height: u32) !Offscreen {
        const ctx = r.ctx;
        const vkd = &ctx.vkd;
        const info: vk.ImageCreateInfo = .{
            .imageType = .@"2d",
            .format = renderer_mod.target_format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.SampleCountFlags.@"1",
            .tiling = .optimal,
            .usage = vk.ImageUsageFlags.color_attachment | vk.ImageUsageFlags.transfer_src,
            .sharingMode = .exclusive,
            .initialLayout = .undefined,
        };
        var image: vk.Image = .null_handle;
        try vk.check(vkd.vkCreateImage(ctx.device, &info, null, &image));
        errdefer vkd.vkDestroyImage(ctx.device, image, null);
        var reqs: vk.MemoryRequirements = undefined;
        vkd.vkGetImageMemoryRequirements(ctx.device, image, &reqs);
        const allocation = try ctx.allocate(reqs, vk.MemoryPropertyFlags.device_local, 0, null);
        errdefer ctx.free(allocation);
        try vk.check(vkd.vkBindImageMemory(ctx.device, image, allocation.memory, 0));
        const view = try createView(ctx, image);
        errdefer vkd.vkDestroyImageView(ctx.device, view, null);
        const fb = try createFramebuffer(r, view, width, height);
        errdefer vkd.vkDestroyFramebuffer(ctx.device, fb, null);
        const readback = try ctx.createBuffer(@as(u64, width) * height * 4, vk.BufferUsageFlags.transfer_dst, vk.MemoryPropertyFlags.host_visible, vk.MemoryPropertyFlags.host_cached);
        return .{
            .renderer = r,
            .target = .{
                .image = image,
                .view = view,
                .framebuffer = fb,
                .width = width,
                .height = height,
            },
            .allocation = allocation,
            .readback = readback,
        };
    }

    pub fn deinit(self: *Offscreen) void {
        const ctx = self.renderer.ctx;
        self.renderer.waitSerial(self.target.last_serial) catch {};
        ctx.vkd.vkDestroyFramebuffer(ctx.device, self.target.framebuffer, null);
        ctx.vkd.vkDestroyImageView(ctx.device, self.target.view, null);
        ctx.vkd.vkDestroyImage(ctx.device, self.target.image, null);
        ctx.free(self.allocation);
        ctx.destroyBuffer(self.readback);
    }

    pub fn render(self: *Offscreen, batch: *const draw.RenderBatch, options: renderer_mod.FrameOptions) !renderer_mod.FrameResult {
        return self.renderer.render(&self.target, batch, options);
    }

    /// Copies the last frame out as tightly packed straight RGBA8 (synchronous; the image is
    /// BGRA, premultiplied; opaque clears make premultiplied == straight).
    pub fn readRgba(self: *Offscreen, out: []u8) !void {
        const n = @as(usize, self.target.width) * self.target.height * 4;
        std.debug.assert(out.len >= n);
        try self.renderer.readback(&self.target, self.readback.buffer);
        self.renderer.ctx.invalidate(self.readback.allocation);
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

// ---- Dma-buf ------------------------------------------------------------------------------

pub const DmabufOptions = struct {
    /// 2 (double buffering) or 3.
    count: u8 = 2,
    /// Advertise XRGB8888 (window is opaque) instead of ARGB8888.
    @"opaque": bool = true,
    /// Compositor feedback: allowed (format, modifier) pairs. Empty = LINEAR only.
    feedback: present.DmabufFeedback = .{},
    /// Ignore modifiers and allocate LINEAR images (debugging / exotic compositors).
    force_linear: bool = false,
};

pub const SyncMode = enum {
    /// Explicit GPU->compositor sync via sync_file attached to the dma-buf (no CPU wait).
    sync_file,
    /// CPU waits on the frame fence before the buffer is handed over.
    fence_wait,
};

pub const DmabufTarget = struct {
    base: Target = .{},
    memory: context.Allocation = .{},
    image: present.DmabufImage = undefined,
    /// Held by the compositor (attached and not yet released).
    busy: bool = false,
    wait_semaphore: vk.Semaphore = .null_handle,
    signal_semaphore: vk.Semaphore = .null_handle,
    /// Free for the platform layer (e.g. its BufferId).
    user_data: u64 = 0,
};

const max_targets = 3;

pub const DmabufTargets = struct {
    renderer: *Renderer,
    targets: [max_targets]DmabufTarget = @splat(.{}),
    count: u8,
    width: u32 = 0,
    height: u32 = 0,
    format: present.Fourcc,
    modifier: u64 = present.modifier_linear,
    sync: SyncMode = .fence_wait,
    options: DmabufOptions,
    /// Candidate modifiers (driver ∩ compositor) for this format.
    modifiers: std.ArrayList(u64) = .empty,

    pub fn init(r: *Renderer, width: u32, height: u32, options: DmabufOptions) !DmabufTargets {
        const ctx = r.ctx;
        if (!ctx.caps.dmabuf_export) return error.DmabufUnsupported;
        var self: DmabufTargets = .{
            .renderer = r,
            .count = std.math.clamp(options.count, 1, max_targets),
            .format = if (options.@"opaque") .xrgb8888 else .argb8888,
            .options = options,
        };
        errdefer self.deinit();
        self.sync = if (ctx.caps.sync_fd_export and ctx.caps.sync_fd_import) .sync_file else .fence_wait;
        try self.chooseModifiers();
        try self.resize(width, height);
        return self;
    }

    pub fn deinit(self: *DmabufTargets) void {
        self.destroyImages();
        self.modifiers.deinit(self.renderer.gpa);
    }

    fn chooseModifiers(self: *DmabufTargets) !void {
        const ctx = self.renderer.ctx;
        const gpa = self.renderer.gpa;
        self.modifiers.clearRetainingCapacity();
        // Compositor list for our format (fall back to the alpha/opaque twin if needed).
        const fb = self.options.feedback;
        var wanted = self.format;
        if (!formatListed(fb, wanted)) {
            const twin: present.Fourcc = if (wanted == .xrgb8888) .argb8888 else .xrgb8888;
            if (formatListed(fb, twin)) wanted = twin;
        }
        self.format = wanted;
        if (self.options.force_linear or !ctx.caps.drm_format_modifier or fb.formats.len == 0) return;

        var list: vk.DrmFormatModifierPropertiesListEXT = .{};
        var props: vk.FormatProperties2 = .{ .pNext = &list, .formatProperties = .{} };
        ctx.vki.vkGetPhysicalDeviceFormatProperties2(ctx.physical, renderer_mod.target_format, &props);
        const mods = try gpa.alloc(vk.DrmFormatModifierPropertiesEXT, list.drmFormatModifierCount);
        defer gpa.free(mods);
        list.pDrmFormatModifierProperties = mods.ptr;
        ctx.vki.vkGetPhysicalDeviceFormatProperties2(ctx.physical, renderer_mod.target_format, &props);

        for (mods[0..list.drmFormatModifierCount]) |m| {
            if (m.drmFormatModifierTilingFeatures & vk.FormatFeatureFlags.color_attachment == 0) continue;
            var allowed = false;
            for (fb.formats) |f| {
                if (f.format == wanted and f.modifier == m.drmFormatModifier) allowed = true;
            }
            if (!allowed) continue;
            if (!self.modifierExportable(m.drmFormatModifier)) continue;
            try self.modifiers.append(gpa, m.drmFormatModifier);
        }
    }

    fn formatListed(fb: present.DmabufFeedback, f: present.Fourcc) bool {
        for (fb.formats) |x| if (x.format == f) return true;
        return false;
    }

    fn modifierExportable(self: *DmabufTargets, modifier: u64) bool {
        const ctx = self.renderer.ctx;
        const mod_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{ .drmFormatModifier = modifier, .sharingMode = .exclusive };
        const ext_info: vk.PhysicalDeviceExternalImageFormatInfo = .{ .pNext = &mod_info, .handleType = vk.ExternalMemoryHandleTypeFlags.dma_buf_ext };
        const info: vk.PhysicalDeviceImageFormatInfo2 = .{
            .pNext = &ext_info,
            .format = renderer_mod.target_format,
            .type = .@"2d",
            .tiling = .drm_format_modifier_ext,
            .usage = vk.ImageUsageFlags.color_attachment | vk.ImageUsageFlags.transfer_src,
        };
        var ext_props: vk.ExternalImageFormatProperties = .{ .externalMemoryProperties = .{} };
        var props: vk.ImageFormatProperties2 = .{ .pNext = &ext_props, .imageFormatProperties = undefined };
        const r = ctx.vki.vkGetPhysicalDeviceImageFormatProperties2(ctx.physical, &info, &props);
        if (r != .success) return false;
        return ext_props.externalMemoryProperties.externalMemoryFeatures & vk.ExternalMemoryFeatureFlags.exportable != 0;
    }

    fn destroyImages(self: *DmabufTargets) void {
        const r = self.renderer;
        const ctx = r.ctx;
        _ = ctx.vkd.vkDeviceWaitIdle(ctx.device);
        ctx.markCompleted(ctx.submit_serial);
        for (self.targets[0..self.count]) |*t| {
            if (t.base.image == .null_handle) continue;
            for (t.image.planes[0..t.image.plane_count]) |p| _ = close(p.fd);
            ctx.vkd.vkDestroyFramebuffer(ctx.device, t.base.framebuffer, null);
            ctx.vkd.vkDestroyImageView(ctx.device, t.base.view, null);
            ctx.vkd.vkDestroyImage(ctx.device, t.base.image, null);
            ctx.free(t.memory);
            if (t.wait_semaphore != .null_handle) ctx.vkd.vkDestroySemaphore(ctx.device, t.wait_semaphore, null);
            if (t.signal_semaphore != .null_handle) ctx.vkd.vkDestroySemaphore(ctx.device, t.signal_semaphore, null);
            t.* = .{};
        }
    }

    /// Recreates all buffers at a new size. The platform must re-import every buffer.
    pub fn resize(self: *DmabufTargets, width: u32, height: u32) !void {
        self.destroyImages();
        self.width = width;
        self.height = height;
        for (self.targets[0..self.count]) |*t| try self.createTarget(t);
    }

    fn createTarget(self: *DmabufTargets, t: *DmabufTarget) !void {
        const r = self.renderer;
        const ctx = r.ctx;
        const vkd = &ctx.vkd;
        const use_modifiers = self.modifiers.items.len > 0;
        const linear_only = [_]u64{present.modifier_linear};
        const mod_list: vk.ImageDrmFormatModifierListCreateInfoEXT = .{
            .drmFormatModifierCount = if (use_modifiers) @intCast(self.modifiers.items.len) else 1,
            .pDrmFormatModifiers = if (use_modifiers) self.modifiers.items.ptr else &linear_only,
        };
        const tiling: vk.ImageTiling = if (ctx.caps.drm_format_modifier) .drm_format_modifier_ext else .linear;
        const ext_info: vk.ExternalMemoryImageCreateInfo = .{
            .pNext = if (tiling == .drm_format_modifier_ext) &mod_list else null,
            .handleTypes = vk.ExternalMemoryHandleTypeFlags.dma_buf_ext,
        };
        const info: vk.ImageCreateInfo = .{
            .pNext = &ext_info,
            .imageType = .@"2d",
            .format = renderer_mod.target_format,
            .extent = .{ .width = self.width, .height = self.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.SampleCountFlags.@"1",
            .tiling = tiling,
            .usage = vk.ImageUsageFlags.color_attachment | vk.ImageUsageFlags.transfer_src,
            .sharingMode = .exclusive,
            .initialLayout = .undefined,
        };
        var image: vk.Image = .null_handle;
        try vk.check(vkd.vkCreateImage(ctx.device, &info, null, &image));
        t.base.image = image;

        var modifier: u64 = present.modifier_linear;
        if (tiling == .drm_format_modifier_ext) {
            var mp: vk.ImageDrmFormatModifierPropertiesEXT = .{};
            try vk.check(vkd.vkGetImageDrmFormatModifierPropertiesEXT.?(ctx.device, image, &mp));
            modifier = mp.drmFormatModifier;
        }
        self.modifier = modifier;

        var reqs: vk.MemoryRequirements = undefined;
        vkd.vkGetImageMemoryRequirements(ctx.device, image, &reqs);
        const export_info: vk.ExportMemoryAllocateInfo = .{ .handleTypes = vk.ExternalMemoryHandleTypeFlags.dma_buf_ext };
        const dedicated: vk.MemoryDedicatedAllocateInfo = .{ .pNext = &export_info, .image = image, .buffer = .null_handle };
        t.memory = try ctx.allocate(reqs, 0, vk.MemoryPropertyFlags.device_local, &dedicated);
        try vk.check(vkd.vkBindImageMemory(ctx.device, image, t.memory.memory, 0));
        t.base.view = try createView(ctx, image);
        t.base.framebuffer = try createFramebuffer(r, t.base.view, self.width, self.height);
        t.base.width = self.width;
        t.base.height = self.height;
        t.base.final_layout = .general;
        t.base.foreign = true;
        t.base.foreign_family = if (ctx.caps.queue_family_foreign) vk.queue_family_foreign_ext else vk.queue_family_external;

        // Export: one fd for the allocation, dup'd per plane.
        const fd_info: vk.MemoryGetFdInfoKHR = .{ .memory = t.memory.memory, .handleType = vk.ExternalMemoryHandleTypeFlags.dma_buf_ext };
        var fd: c_int = -1;
        try vk.check(vkd.vkGetMemoryFdKHR.?(ctx.device, &fd_info, &fd));
        const plane_count: u8 = if (tiling == .drm_format_modifier_ext) self.planeCount(modifier) else 1;
        t.image = .{
            .width = self.width,
            .height = self.height,
            .format = self.format,
            .modifier = modifier,
            .plane_count = plane_count,
            .planes = undefined,
        };
        const plane_aspects = [_]vk.Flags{
            vk.ImageAspectFlags.memory_plane_0_ext, vk.ImageAspectFlags.memory_plane_1_ext,
            vk.ImageAspectFlags.memory_plane_2_ext, vk.ImageAspectFlags.memory_plane_3_ext,
        };
        for (0..plane_count) |i| {
            const sub: vk.ImageSubresource = .{ .aspectMask = if (tiling == .drm_format_modifier_ext) plane_aspects[i] else vk.ImageAspectFlags.color };
            var layout: vk.SubresourceLayout = .{};
            vkd.vkGetImageSubresourceLayout(ctx.device, image, &sub, &layout);
            t.image.planes[i] = .{
                .fd = if (i == 0) fd else dup(fd),
                .offset = @intCast(layout.offset),
                .stride = @intCast(layout.rowPitch),
            };
        }

        // Semaphores for the sync_file path.
        if (self.sync == .sync_file) {
            const export_sem: vk.ExportSemaphoreCreateInfo = .{ .handleTypes = vk.ExternalSemaphoreHandleTypeFlags.sync_fd };
            const sig_info: vk.SemaphoreCreateInfo = .{ .pNext = &export_sem };
            try vk.check(vkd.vkCreateSemaphore(ctx.device, &sig_info, null, &t.signal_semaphore));
            const wait_info: vk.SemaphoreCreateInfo = .{};
            try vk.check(vkd.vkCreateSemaphore(ctx.device, &wait_info, null, &t.wait_semaphore));
        }
    }

    fn planeCount(self: *DmabufTargets, modifier: u64) u8 {
        const ctx = self.renderer.ctx;
        var list: vk.DrmFormatModifierPropertiesListEXT = .{};
        var props: vk.FormatProperties2 = .{ .pNext = &list, .formatProperties = .{} };
        ctx.vki.vkGetPhysicalDeviceFormatProperties2(ctx.physical, renderer_mod.target_format, &props);
        var buf: [64]vk.DrmFormatModifierPropertiesEXT = undefined;
        list.drmFormatModifierCount = @min(list.drmFormatModifierCount, buf.len);
        list.pDrmFormatModifierProperties = &buf;
        ctx.vki.vkGetPhysicalDeviceFormatProperties2(ctx.physical, renderer_mod.target_format, &props);
        for (buf[0..list.drmFormatModifierCount]) |m| {
            if (m.drmFormatModifier == modifier) return @intCast(@min(m.drmFormatModifierPlaneCount, present.max_planes));
        }
        return 1;
    }

    /// A buffer the compositor does not hold, preferring the most recently drawn one (the
    /// smallest buffer age, i.e. the least to repaint). Null when all are busy.
    pub fn acquire(self: *DmabufTargets) ?*DmabufTarget {
        var best: ?*DmabufTarget = null;
        for (self.targets[0..self.count]) |*t| {
            if (t.busy) continue;
            if (best == null or t.base.last_frame > best.?.base.last_frame) best = t;
        }
        return best;
    }

    /// Renders into `t` and attaches the completion fence. Unless `result.stats.skipped`,
    /// the buffer is now busy until `release(t)`; present `exported(t)` with `result.damage`.
    pub fn render(self: *DmabufTargets, t: *DmabufTarget, batch: *const draw.RenderBatch, options: renderer_mod.FrameOptions) !renderer_mod.FrameResult {
        const r = self.renderer;
        const ctx = r.ctx;
        t.base.wait_semaphore = .null_handle;
        t.base.signal_semaphore = .null_handle;
        var imported_wait = false;
        if (self.sync == .sync_file and t.base.last_serial != 0) {
            // Wait for the compositor's outstanding reads (implicit fences) on the GPU.
            var req: DmaBufSyncFile = .{ .flags = dma_buf_sync_write, .fd = -1 };
            if (ioctl(t.image.planes[0].fd, dma_buf_ioctl_export_sync_file, &req) == 0 and req.fd >= 0) {
                const import: vk.ImportSemaphoreFdInfoKHR = .{
                    .semaphore = t.wait_semaphore,
                    .flags = vk.SemaphoreImportFlags.temporary,
                    .handleType = vk.ExternalSemaphoreHandleTypeFlags.sync_fd,
                    .fd = req.fd,
                };
                if (ctx.vkd.vkImportSemaphoreFdKHR.?(ctx.device, &import) == .success) {
                    imported_wait = true;
                } else _ = close(req.fd);
            }
        }
        if (imported_wait) t.base.wait_semaphore = t.wait_semaphore;
        if (self.sync == .sync_file) t.base.signal_semaphore = t.signal_semaphore;

        const result = r.render(&t.base, batch, options) catch |err| {
            if (imported_wait) {
                // The temporary payload stays pending; reset by waiting idle.
                _ = ctx.vkd.vkDeviceWaitIdle(ctx.device);
            }
            return err;
        };
        if (result.stats.skipped) {
            // Nothing submitted: a temporary import would linger; consume it with an empty submit.
            if (imported_wait) {
                const stage: vk.Flags = vk.PipelineStageFlags.all_commands;
                const submit: vk.SubmitInfo = .{ .waitSemaphoreCount = 1, .pWaitSemaphores = @ptrCast(&t.wait_semaphore), .pWaitDstStageMask = @ptrCast(&stage) };
                _ = ctx.vkd.vkQueueSubmit(ctx.queue, 1, @ptrCast(&submit), .null_handle);
            }
            return result;
        }

        var attached = false;
        if (self.sync == .sync_file) {
            const get: vk.SemaphoreGetFdInfoKHR = .{ .semaphore = t.signal_semaphore, .handleType = vk.ExternalSemaphoreHandleTypeFlags.sync_fd };
            var fd: c_int = -1;
            if (ctx.vkd.vkGetSemaphoreFdKHR.?(ctx.device, &get, &fd) == .success and fd >= 0) {
                var req: DmaBufSyncFile = .{ .flags = dma_buf_sync_write, .fd = fd };
                attached = ioctl(t.image.planes[0].fd, dma_buf_ioctl_import_sync_file, &req) == 0;
                _ = close(fd);
            }
            if (!attached) self.sync = .fence_wait; // kernel without IMPORT_SYNC_FILE (< 6.0)
        }
        if (!attached) try r.waitSerial(result.serial);
        t.busy = true;
        return result;
    }

    pub fn exported(_: *const DmabufTargets, t: *const DmabufTarget) present.DmabufImage {
        return t.image;
    }

    /// The compositor released the buffer (wl_buffer.release).
    pub fn release(_: *DmabufTargets, t: *DmabufTarget) void {
        t.busy = false;
    }

    pub fn find(self: *DmabufTargets, user_data: u64) ?*DmabufTarget {
        for (self.targets[0..self.count]) |*t| if (t.user_data == user_data) return t;
        return null;
    }
};

const DmaBufSyncFile = extern struct {
    flags: u32,
    fd: i32,
};
const dma_buf_sync_write: u32 = 2;
/// _IOWR('b', 2, struct dma_buf_export_sync_file)
const dma_buf_ioctl_export_sync_file: c_ulong = 0xC0086202;
/// _IOW('b', 3, struct dma_buf_import_sync_file)
const dma_buf_ioctl_import_sync_file: c_ulong = 0x40086203;
