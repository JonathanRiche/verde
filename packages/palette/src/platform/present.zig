//! Presentation contract between the GPU renderer (src/gpu) and the window system
//! (src/platform/wayland). Palette does not link libwayland, so Vulkan's VK_KHR_wayland_surface
//! (which needs a libwayland `wl_display*`) is not used. Instead the renderer allocates
//! exportable images, exports them as dma-bufs, and the platform layer wraps them in
//! `wl_buffer`s via zwp_linux_dmabuf_v1 and presents them itself. This also gives Palette full
//! control over buffer count, damage, and frame pacing.
//!
//! STATUS: contract.

const std = @import("std");

/// DRM fourcc codes (drm_fourcc.h). Only the ones Palette renders into are listed.
pub const Fourcc = enum(u32) {
    argb8888 = fourcc('A', 'R', '2', '4'),
    xrgb8888 = fourcc('X', 'R', '2', '4'),
    abgr8888 = fourcc('A', 'B', '2', '4'),
    xbgr8888 = fourcc('X', 'B', '2', '4'),
    _,
};

pub fn fourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}

pub const modifier_linear: u64 = 0;
pub const modifier_invalid: u64 = 0x00ffffffffffffff;

/// A (format, modifier) pair the compositor can import.
pub const FormatModifier = struct {
    format: Fourcc,
    modifier: u64,
};

/// What the compositor told us about dma-buf support (zwp_linux_dmabuf_v1 feedback, v4+).
pub const DmabufFeedback = struct {
    /// dev_t of the device the compositor prefers buffers to be allocated on.
    main_device: ?u64 = null,
    formats: []const FormatModifier = &.{},
};

pub const max_planes = 4;

pub const DmabufPlane = struct {
    fd: std.posix.fd_t,
    offset: u32,
    stride: u32,
};

/// One exported image. The GPU side owns the fds and closes them on destroy; the platform side
/// dup()s nothing — it sends the fds over the socket (SCM_RIGHTS copies them).
pub const DmabufImage = struct {
    width: u32,
    height: u32,
    format: Fourcc,
    modifier: u64,
    plane_count: u8,
    planes: [max_planes]DmabufPlane,
};

/// A damaged region in *buffer* (device pixel) coordinates.
pub const DamageRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Opaque handle for a buffer registered with the window. Returned by
/// `Window.importDmabuf` and passed back to `Window.present`.
pub const BufferId = enum(u32) { invalid = 0, _ };
