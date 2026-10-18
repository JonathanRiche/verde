//! Helpers for importing foreign dma-bufs (browser frames from a WebKit helper process,
//! video decoders) as sampled images: DRM fourcc -> Vulkan format mapping, the per-buffer
//! cache key, dma-buf sync_file ioctls and the (format, modifier) list a producer may use.
//! The renderer side (cache, barriers, semaphores) lives in renderer.zig.

const std = @import("std");
const linux = std.os.linux;
const vk = @import("vk.zig");
const context = @import("context.zig");
const present = @import("../../platform/present.zig");

const Context = context.Context;

pub extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn dup(fd: c_int) c_int;

pub const Mapping = struct {
    format: vk.Format,
    /// X formats: alpha channel is undefined, sample it as 1.
    alpha_one: bool,
};

/// DRM fourccs name the packed little-endian word: XR24 = [B, G, R, X] in memory.
pub fn mapFourcc(f: present.Fourcc) ?Mapping {
    return switch (f) {
        .argb8888 => .{ .format = .b8g8r8a8_unorm, .alpha_one = false },
        .xrgb8888 => .{ .format = .b8g8r8a8_unorm, .alpha_one = true },
        .abgr8888 => .{ .format = .r8g8b8a8_unorm, .alpha_one = false },
        .xbgr8888 => .{ .format = .r8g8b8a8_unorm, .alpha_one = true },
        _ => null,
    };
}

pub const importable_fourccs = [_]present.Fourcc{ .xrgb8888, .argb8888, .xbgr8888, .abgr8888 };

/// Usage of imported images: sampled by the UI pass; transfer_src for readback tools/tests.
pub const usage: vk.Flags = vk.ImageUsageFlags.sampled | vk.ImageUsageFlags.transfer_src;

/// Identity of the buffer behind a dma-buf fd: (st_dev, st_ino) of the dma-buf inode, which
/// is shared by every fd/dup of the same buffer, across processes. 0 when statx fails.
pub fn bufferKey(fd: c_int) u64 {
    var stx: linux.Statx = undefined;
    const at_empty_path: u32 = 0x1000;
    const rc = linux.statx(fd, "", at_empty_path, .{ .INO = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return 0;
    const dev: u64 = (@as(u64, stx.dev_major) << 20) ^ stx.dev_minor;
    var h = std.hash.Wyhash.init(0x70616c65);
    h.update(std.mem.asBytes(&dev));
    h.update(std.mem.asBytes(&stx.ino));
    const k = h.final();
    return if (k == 0) 1 else k;
}

pub fn sameBuffer(a: c_int, b: c_int) bool {
    if (a == b) return true;
    const ka = bufferKey(a);
    return ka != 0 and ka == bufferKey(b);
}

// ---- dma-buf sync_file ioctls (linux/dma-buf.h, kernel >= 6.0) ----------------------------

pub const DmaBufSyncFile = extern struct {
    flags: u32,
    fd: i32,
};
pub const dma_buf_sync_read: u32 = 1;
pub const dma_buf_sync_write: u32 = 2;
/// _IOWR('b', 2, struct dma_buf_export_sync_file)
pub const dma_buf_ioctl_export_sync_file: c_ulong = 0xC0086202;
/// _IOW('b', 3, struct dma_buf_import_sync_file)
pub const dma_buf_ioctl_import_sync_file: c_ulong = 0x40086203;

/// Fences a reader must wait for (the producer's pending writes) as a sync_file, or -1.
pub fn exportReadFence(dmabuf_fd: c_int) c_int {
    var req: DmaBufSyncFile = .{ .flags = dma_buf_sync_read, .fd = -1 };
    if (ioctl(dmabuf_fd, dma_buf_ioctl_export_sync_file, &req) != 0) return -1;
    return req.fd;
}

/// Adds `fence` (not consumed) as a read fence, so implicit-sync writers wait for our sampling.
pub fn attachReadFence(dmabuf_fd: c_int, fence: c_int) bool {
    var req: DmaBufSyncFile = .{ .flags = dma_buf_sync_read, .fd = fence };
    return ioctl(dmabuf_fd, dma_buf_ioctl_import_sync_file, &req) == 0;
}

// ---- Supported (format, modifier) pairs ---------------------------------------------------

/// Whether `modifier` (or LINEAR without modifier support) can be imported for sampling.
pub fn importSupported(ctx: *Context, format: vk.Format, modifier: u64) bool {
    if (!ctx.caps.dmabuf_export or ctx.vkd.vkGetMemoryFdPropertiesKHR == null) return false;
    const mod_info: vk.PhysicalDeviceImageDrmFormatModifierInfoEXT = .{ .drmFormatModifier = modifier, .sharingMode = .exclusive };
    const ext_info: vk.PhysicalDeviceExternalImageFormatInfo = .{
        .pNext = if (ctx.caps.drm_format_modifier) &mod_info else null,
        .handleType = vk.ExternalMemoryHandleTypeFlags.dma_buf_ext,
    };
    if (!ctx.caps.drm_format_modifier and modifier != present.modifier_linear) return false;
    const info: vk.PhysicalDeviceImageFormatInfo2 = .{
        .pNext = &ext_info,
        .format = format,
        .type = .@"2d",
        .tiling = if (ctx.caps.drm_format_modifier) .drm_format_modifier_ext else .linear,
        .usage = usage,
    };
    var ext_props: vk.ExternalImageFormatProperties = .{ .externalMemoryProperties = .{} };
    var props: vk.ImageFormatProperties2 = .{ .pNext = &ext_props, .imageFormatProperties = undefined };
    if (ctx.vki.vkGetPhysicalDeviceImageFormatProperties2(ctx.physical, &info, &props) != .success) return false;
    return ext_props.externalMemoryProperties.externalMemoryFeatures & vk.ExternalMemoryFeatureFlags.importable != 0;
}

/// Appends every (fourcc, modifier) this device can import and sample, preferred first per
/// format (driver order), LINEAR always included when supported. For producer handshakes.
pub fn appendImportFormats(ctx: *Context, gpa: std.mem.Allocator, out: *std.ArrayList(present.FormatModifier)) !void {
    for (importable_fourccs) |fcc| {
        const m = mapFourcc(fcc).?;
        if (!ctx.caps.drm_format_modifier) {
            if (importSupported(ctx, m.format, present.modifier_linear))
                try out.append(gpa, .{ .format = fcc, .modifier = present.modifier_linear });
            continue;
        }
        var list: vk.DrmFormatModifierPropertiesListEXT = .{};
        var props: vk.FormatProperties2 = .{ .pNext = &list, .formatProperties = .{} };
        ctx.vki.vkGetPhysicalDeviceFormatProperties2(ctx.physical, m.format, &props);
        const mods = try gpa.alloc(vk.DrmFormatModifierPropertiesEXT, list.drmFormatModifierCount);
        defer gpa.free(mods);
        list.pDrmFormatModifierProperties = mods.ptr;
        ctx.vki.vkGetPhysicalDeviceFormatProperties2(ctx.physical, m.format, &props);
        for (mods[0..list.drmFormatModifierCount]) |p| {
            if (p.drmFormatModifierTilingFeatures & vk.FormatFeatureFlags.sampled_image == 0) continue;
            if (!importSupported(ctx, m.format, p.drmFormatModifier)) continue;
            try out.append(gpa, .{ .format = fcc, .modifier = p.drmFormatModifier });
        }
    }
}
