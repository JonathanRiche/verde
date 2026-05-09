//! Browser texture metadata shared between the runtime backend and the ImGui pane.

const std = @import("std");

const GL_TEXTURE_2D = 0x0DE1;
const GL_RGBA = 0x1908;
const GL_BGRA = 0x80E1;
const GL_UNSIGNED_BYTE = 0x1401;
const GL_LINEAR = 0x2601;
const GL_TEXTURE_MIN_FILTER = 0x2801;
const GL_TEXTURE_MAG_FILTER = 0x2800;
const GL_TEXTURE_WRAP_S = 0x2802;
const GL_TEXTURE_WRAP_T = 0x2803;
const GL_CLAMP_TO_EDGE = 0x812F;
const GL_UNPACK_ALIGNMENT = 0x0CF5;
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

extern fn glGenTextures(n: c_int, textures: [*]c_uint) void;
extern fn glBindTexture(target: c_uint, texture: c_uint) void;
extern fn glDeleteTextures(n: c_int, textures: [*]const c_uint) void;
extern fn glPixelStorei(pname: c_uint, param: c_int) void;
extern fn glTexParameteri(target: c_uint, pname: c_uint, param: c_int) void;
extern fn glTexImage2D(target: c_uint, level: c_int, internalformat: c_int, width: c_int, height: c_int, border: c_int, format: c_uint, type_: c_uint, pixels: ?*const anyopaque) void;
extern fn glTexSubImage2D(target: c_uint, level: c_int, xoffset: c_int, yoffset: c_int, width: c_int, height: c_int, format: c_uint, type_: c_uint, pixels: ?*const anyopaque) void;

/// Tracks the OpenGL texture that backs one browser pane.
pub const PaneTexture = struct {
    texture_id: c_uint = 0,
    width: u32 = 0,
    height: u32 = 0,
    dirty: bool = false,
    last_upload_ms: i64 = 0,

    /// Releases the underlying OpenGL texture if one exists.
    pub fn deinit(self: *PaneTexture) void {
        if (self.texture_id != 0) {
            if (external_release_fn) |release_fn| {
                release_fn(external_upload_context, self.texture_id);
            } else {
                const textures = [_]c_uint{self.texture_id};
                glDeleteTextures(1, &textures);
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

    /// Uploads one RGBA frame into the pane texture, creating the GL texture on first use.
    pub fn uploadRgba(self: *PaneTexture, width: u32, height: u32, pixels: []const u8) !void {
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(pixels.len == width * height * 4);

        try self.uploadPixels(width, height, GL_RGBA, pixels);
    }

    /// Uploads one BGRA frame into the pane texture without an intermediate CPU-side swizzle.
    pub fn uploadBgra(self: *PaneTexture, width: u32, height: u32, pixels: []const u8) !void {
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(pixels.len == width * height * 4);

        try self.uploadPixels(width, height, GL_BGRA, pixels);
    }

    // Reuses the existing texture storage when the browser viewport size stays stable.
    fn uploadPixels(self: *PaneTexture, width: u32, height: u32, format: c_uint, pixels: []const u8) !void {
        if (external_upload_fn) |upload_fn| {
            if (self.texture_id != 0 and shouldThrottleExternalUpload(self.last_upload_ms)) return;
            const external_format: PixelFormat = if (format == GL_BGRA) .bgra else .rgba;
            try upload_fn(external_upload_context, self, width, height, external_format, pixels);
            return;
        }

        if (self.texture_id == 0) {
            var textures = [_]c_uint{0};
            glGenTextures(1, &textures);
            self.texture_id = textures[0];
            if (self.texture_id == 0) return error.TextureUnavailable;
        }

        glBindTexture(GL_TEXTURE_2D, self.texture_id);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        if (self.width != width or self.height != height) {
            glTexImage2D(
                GL_TEXTURE_2D,
                0,
                GL_RGBA,
                @intCast(width),
                @intCast(height),
                0,
                format,
                GL_UNSIGNED_BYTE,
                pixels.ptr,
            );
        } else {
            glTexSubImage2D(
                GL_TEXTURE_2D,
                0,
                0,
                0,
                @intCast(width),
                @intCast(height),
                format,
                GL_UNSIGNED_BYTE,
                pixels.ptr,
            );
        }
        glBindTexture(GL_TEXTURE_2D, 0);
        self.update(self.texture_id, width, height, true);
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
