//! Browser texture metadata shared between the runtime backend and Palette renderer.

const std = @import("std");
const platform_runtime = @import("platform_runtime");

const EXTERNAL_BROWSER_UPLOAD_INTERVAL_MS = 33;

pub const PixelFormat = enum {
    rgba,
    bgra,
};

pub const UploadResult = enum {
    uploaded,
    deferred,
};

/// One caller-owned CPU copy of the most recent browser frame, used for
/// screenshot crops (e.g. inspector design-mode selections).
pub const CopiedFrame = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    /// Tightly packed `width * height * 4` bytes owned by the caller.
    pixels: []u8,

    pub fn deinit(self: *const CopiedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
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

/// One plane of a foreign dma-buf frame. The fd is borrowed for the call.
pub const DmabufPlane = struct {
    fd: c_int = -1,
    offset: u32 = 0,
    stride: u32 = 0,
};

/// Changed texels since the producer's previous frame.
pub const DamageRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// A (DRM fourcc, modifier) pair the renderer can sample.
pub const DmabufFormat = struct {
    fourcc: u32,
    modifier: u64,
};

/// A browser frame shared as a dma-buf (Linux zero-copy path).
pub const DmabufFrame = struct {
    width: u32,
    height: u32,
    fourcc: u32,
    modifier: u64,
    plane_count: u8,
    planes: [4]DmabufPlane = @splat(.{}),
    /// Producer render-done sync_file; ownership moves to the importer. -1 = implicit sync.
    acquire_fence: c_int = -1,
    /// Empty = the whole frame changed.
    damage: []const DamageRect = &.{},
};

pub const DmabufImportResult = struct {
    texture_id: c_uint,
    /// Import cache key of the buffer; hand it back through `releaseFence` once the
    /// texture shows a different buffer.
    key: u64,
};

/// Renderer hooks for zero-copy browser frames. The GUI registers them when its GPU
/// backend can import dma-bufs; browser code stays renderer-agnostic.
pub const DmabufImporter = struct {
    context: ?*anyopaque,
    /// Appends the importable (fourcc, modifier) pairs.
    formats: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(DmabufFormat)) anyerror!void,
    /// Binds `frame` to `texture_id` (0 = allocate an id).
    import: *const fn (context: ?*anyopaque, texture_id: c_uint, frame: DmabufFrame) anyerror!DmabufImportResult,
    /// Sync_file (caller owns) that signals once the GPU stopped sampling `key`, or -1.
    release_fence: *const fn (context: ?*anyopaque, key: u64) c_int,
    /// Drops the cached import of `key` (the producer reallocated its buffers).
    forget: *const fn (context: ?*anyopaque, key: u64) void,
    /// Reads `texture_id` back to the CPU (screenshots); RGBA, caller-owned.
    readback: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, texture_id: c_uint, width: u32, height: u32) anyerror!CopiedFrame,
};

var dmabuf_importer: ?DmabufImporter = null;

pub fn configureDmabufImporter(importer: ?DmabufImporter) void {
    dmabuf_importer = importer;
}

/// The registered zero-copy importer, or null when frames must be copied.
pub fn dmabufImporter() ?DmabufImporter {
    return dmabuf_importer;
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
    pub fn uploadRgba(self: *PaneTexture, width: u32, height: u32, pixels: []const u8) !UploadResult {
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(pixels.len == width * height * 4);

        return try self.uploadPixels(width, height, .rgba, pixels, true);
    }

    /// Uploads one BGRA frame into the pane texture without an intermediate CPU-side swizzle.
    pub fn uploadBgra(self: *PaneTexture, width: u32, height: u32, pixels: []const u8) !UploadResult {
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(pixels.len == width * height * 4);

        return try self.uploadPixels(width, height, .bgra, pixels, true);
    }

    /// Uploads a BGRA frame whose backend already owns frame pacing.
    pub fn uploadBgraImmediately(self: *PaneTexture, width: u32, height: u32, pixels: []const u8) !UploadResult {
        std.debug.assert(width > 0 and height > 0);
        std.debug.assert(pixels.len == width * height * 4);
        return try self.uploadPixels(width, height, .bgra, pixels, false);
    }

    // Reuses the existing texture storage when the browser viewport size stays stable.
    fn uploadPixels(self: *PaneTexture, width: u32, height: u32, format: PixelFormat, pixels: []const u8, allow_throttle: bool) !UploadResult {
        const upload_fn = external_upload_fn orelse return error.TextureUnavailable;
        if (allow_throttle and self.texture_id != 0 and shouldThrottleExternalUpload(self.last_upload_ms)) return .deferred;
        try upload_fn(external_upload_context, self, width, height, format, pixels);
        return .uploaded;
    }
};

fn shouldThrottleExternalUpload(last_upload_ms: i64) bool {
    return shouldThrottleExternalUploadAt(last_upload_ms, monotonicTimestampMs());
}

fn shouldThrottleExternalUploadAt(last_upload_ms: i64, now_ms: i64) bool {
    if (last_upload_ms == 0) return false;
    return now_ms - last_upload_ms < EXTERNAL_BROWSER_UPLOAD_INTERVAL_MS;
}

fn monotonicTimestampMs() i64 {
    return @intCast(@divTrunc(platform_runtime.monotonicTimestampNs(), std.time.ns_per_ms));
}
