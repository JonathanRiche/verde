//! Browser texture metadata shared between the runtime backend and Palette renderer.

const std = @import("std");

const EXTERNAL_BROWSER_UPLOAD_INTERVAL_MS = 33;

pub const PixelFormat = enum {
    rgba,
    bgra,
};

pub const ExternalUploadFn = *const fn (context: ?*anyopaque, texture: *PaneTexture, width: u32, height: u32, format: PixelFormat, pixels: []const u8) anyerror!void;
pub const ExternalReleaseFn = *const fn (context: ?*anyopaque, texture_id: c_uint) void;

var external_upload_context: ?*anyopaque = null;
var external_upload_fn: ?ExternalUploadFn = null;
var external_release_fn: ?ExternalReleaseFn = null;

pub fn configureExternalUploader(context: ?*anyopaque, upload_fn: ?ExternalUploadFn, release_fn: ?ExternalReleaseFn) void {
    external_upload_context = context;
    external_upload_fn = upload_fn;
    external_release_fn = release_fn;
}

/// Tracks the renderer texture that backs one browser pane.
pub const PaneTexture = struct {
    texture_id: c_uint = 0,
    width: u32 = 0,
    height: u32 = 0,
    dirty: bool = false,
    last_upload_ms: i64 = 0,

    /// Releases the underlying renderer texture if one exists.
    pub fn deinit(self: *PaneTexture) void {
        if (self.texture_id != 0) {
            if (external_release_fn) |release_fn| {
                release_fn(external_upload_context, self.texture_id);
            }
        }
        self.clear();
    }

    /// Clears the texture metadata when no browser frame is available.
    pub fn clear(self: *PaneTexture) void {
        self.* = .{};
    }

    /// Updates the texture dimensions without assuming how the pixels were uploaded.
    pub fn update(self: *PaneTexture, texture_id: c_uint, width: u32, height: u32, dirty: bool) void {
        self.texture_id = texture_id;
        self.width = width;
        self.height = height;
        self.dirty = dirty;
        self.last_upload_ms = monotonicTimestampMs();
    }

    /// Reports whether the pane has a valid GPU texture to present.
    pub fn isReady(self: *const PaneTexture) bool {
        return self.texture_id != 0 and self.width > 0 and self.height > 0;
    }

    /// Uploads one RGBA frame into the pane texture.
    pub fn uploadRgba(self: *PaneTexture, width: u32, height: u32, pixels: []const u8) !void {
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(pixels.len == width * height * 4);

        try self.uploadPixels(width, height, .rgba, pixels);
    }

    /// Uploads one BGRA frame into the pane texture without an intermediate CPU-side swizzle.
    pub fn uploadBgra(self: *PaneTexture, width: u32, height: u32, pixels: []const u8) !void {
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(pixels.len == width * height * 4);

        try self.uploadPixels(width, height, .bgra, pixels);
    }

    // Reuses the existing texture storage when the browser viewport size stays stable.
    fn uploadPixels(self: *PaneTexture, width: u32, height: u32, format: PixelFormat, pixels: []const u8) !void {
        const upload_fn = external_upload_fn orelse return error.TextureUnavailable;
        if (self.texture_id != 0 and shouldThrottleExternalUpload(self.last_upload_ms)) return;
        try upload_fn(external_upload_context, self, width, height, format, pixels);
    }
};

fn shouldThrottleExternalUpload(last_upload_ms: i64) bool {
    if (last_upload_ms == 0) return false;
    return monotonicTimestampMs() - last_upload_ms < EXTERNAL_BROWSER_UPLOAD_INTERVAL_MS;
}

fn monotonicTimestampMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}
