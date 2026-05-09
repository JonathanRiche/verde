const std = @import("std");
const builtin = @import("builtin");
const palette = @import("palette");
const sdl = @import("zsdl3");

const app_state = @import("../state.zig");
const browser_texture = @import("../browser/texture.zig");
const palette_gl_renderer = @import("palette_gl_renderer.zig");
const stb_image = @import("../stb_image.zig");

pub const Backend = enum {
    gl,
    sdl_gpu,
};

pub const Renderer = struct {
    requested_backend: Backend,
    active_backend: Backend,
    window: ?*sdl.Window = null,
    gl: ?palette_gl_renderer.Renderer = null,
    gpu: ?palette.renderer.Renderer = null,
    gpu_font: ?*palette.sdl.Font = null,
    gpu_ttf_initialized: bool = false,
    next_texture_id: u32 = 1,

    pub const InitOptions = struct {
        requested_backend: Backend,
        window: *sdl.Window,
        font_path: [:0]const u8,
    };

    pub fn init(options: InitOptions) !Renderer {
        return switch (options.requested_backend) {
            .gl => .{
                .requested_backend = .gl,
                .active_backend = .gl,
                .window = options.window,
                .gl = palette_gl_renderer.Renderer.init(),
            },
            .sdl_gpu => try initSdlGpu(options),
        };
    }

    fn initSdlGpu(options: InitOptions) !Renderer {
        var result: Renderer = .{
            .requested_backend = .sdl_gpu,
            .active_backend = .sdl_gpu,
            .window = options.window,
        };
        errdefer result.deinit(std.heap.smp_allocator);

        try palette.sdl.ttfInit();
        result.gpu_ttf_initialized = true;
        result.gpu_font = try palette.sdl.ttfOpenFont(options.font_path, 16.0);
        result.gpu = try palette.renderer.Renderer.init(.{
            .debug_mode = builtin.mode == .Debug,
            .shader_formats = palette.renderer.ShaderFormat.defaultForTarget(builtin.os.tag),
            .shader_packages = palette.renderer.ShaderSource.packagesForTarget(builtin.os.tag),
            .font = result.gpu_font,
        });
        try result.gpu.?.claimWindow(@ptrCast(options.window));
        return result;
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        if (self.gpu) |*gpu| {
            if (self.window) |window| gpu.releaseWindow(@ptrCast(window));
            gpu.deinit();
        }
        if (self.gpu_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_ttf_initialized) palette.sdl.ttfQuit();
        if (self.gl) |*gl| gl.deinit(allocator);
        self.* = undefined;
    }

    pub fn usingFallback(self: *const Renderer) bool {
        return self.requested_backend != self.active_backend;
    }

    pub fn activeBackend(self: *const Renderer) Backend {
        return self.active_backend;
    }

    pub fn usesOpenGl(self: *const Renderer) bool {
        return self.active_backend == .gl;
    }

    pub fn uploadLoadedTextureCallback(context: ?*anyopaque, loaded: stb_image.LoadedImage) ?app_state.CachedImageTexture {
        const renderer: *Renderer = @ptrCast(@alignCast(context orelse return null));
        return renderer.uploadLoadedTexture(loaded);
    }

    pub fn uploadLoadedTexture(self: *Renderer, loaded: stb_image.LoadedImage) ?app_state.CachedImageTexture {
        if (self.active_backend != .sdl_gpu) return null;
        const id = self.nextTextureId();

        const width: u32 = @intCast(loaded.width);
        const height: u32 = @intCast(loaded.height);
        self.gpu.?.uploadTexture(id, width, height, .rgba8, .image, loaded.pixels[0 .. @as(usize, width) * @as(usize, height) * 4]) catch return null;
        return .{
            .texture_id = id,
            .width = loaded.width,
            .height = loaded.height,
            .valid = true,
            .backend = .external,
        };
    }

    pub fn uploadPaneTextureCallback(context: ?*anyopaque, pane_texture: *browser_texture.PaneTexture, width: u32, height: u32, format: browser_texture.PixelFormat, pixels: []const u8) !void {
        const renderer: *Renderer = @ptrCast(@alignCast(context orelse return error.SdlGpuTextureUnavailable));
        if (renderer.active_backend != .sdl_gpu) return error.SdlGpuTextureUnavailable;
        const texture_id = if (pane_texture.texture_id == 0) renderer.nextTextureId() else pane_texture.texture_id;
        const gpu_format: palette.renderer.Renderer.TextureFormat = switch (format) {
            .rgba => .rgba8,
            .bgra => .bgra8,
        };
        try renderer.gpu.?.uploadTexture(texture_id, width, height, gpu_format, .browser, pixels);
        pane_texture.update(texture_id, width, height, true);
    }

    pub fn releasePaneTextureCallback(context: ?*anyopaque, texture_id: c_uint) void {
        const renderer: *Renderer = @ptrCast(@alignCast(context orelse return));
        if (renderer.active_backend != .sdl_gpu) return;
        renderer.gpu.?.releaseTexture(texture_id);
    }

    fn nextTextureId(self: *Renderer) u32 {
        const id = self.next_texture_id;
        self.next_texture_id +%= 1;
        if (self.next_texture_id == 0) self.next_texture_id = 1;
        return id;
    }

    pub fn renderBatch(
        self: *Renderer,
        allocator: std.mem.Allocator,
        batch: *const palette.RenderBatch,
        framebuffer_width: f32,
        framebuffer_height: f32,
    ) !void {
        switch (self.active_backend) {
            .gl => try self.gl.?.renderBatch(allocator, batch, framebuffer_width, framebuffer_height),
            .sdl_gpu => try self.renderSdlGpuBatch(allocator, batch),
        }
    }

    fn renderSdlGpuBatch(self: *Renderer, allocator: std.mem.Allocator, batch: *const palette.RenderBatch) !void {
        const window = self.window orelse return error.SdlGpuWindowMissing;
        try self.gpu.?.renderWindow(
            allocator,
            @ptrCast(window),
            batch,
            .{ .r = 0.0235, .g = 0.0235, .b = 0.0275, .a = 1.0 },
        );
    }

    pub fn lastSdlGpuFrameStats(self: *const Renderer) ?palette.renderer.FrameStats {
        if (self.active_backend != .sdl_gpu) return null;
        return self.gpu.?.lastFrameStats();
    }
};
