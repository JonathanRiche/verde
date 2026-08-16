const std = @import("std");
const builtin = @import("builtin");
const palette = @import("palette");
const sdl = @import("zsdl3");

const app_state = @import("../state.zig");
const browser_texture = @import("../browser/texture.zig");
const stb_image = @import("../media/stb_image.zig");
const text_measure = @import("text_measure.zig");
const theme = @import("theme.zig");

pub const Backend = enum {
    sdl_gpu,
};

pub const Renderer = struct {
    requested_backend: Backend,
    active_backend: Backend,
    window: ?*sdl.Window = null,
    gpu: ?palette.renderer.Renderer = null,
    gpu_ui_font: ?*palette.sdl.Font = null,
    gpu_ui_bold_font: ?*palette.sdl.Font = null,
    gpu_prose_font: ?*palette.sdl.Font = null,
    gpu_prose_bold_font: ?*palette.sdl.Font = null,
    gpu_prose_italic_font: ?*palette.sdl.Font = null,
    gpu_prose_bold_italic_font: ?*palette.sdl.Font = null,
    gpu_mono_font: ?*palette.sdl.Font = null,
    gpu_icon_font: ?*palette.sdl.Font = null,
    gpu_mono_symbols_font: ?*palette.sdl.Font = null,
    gpu_symbols_font: ?*palette.sdl.Font = null,
    gpu_symbols_alt_font: ?*palette.sdl.Font = null,
    gpu_emoji_font: ?*palette.sdl.Font = null,
    gpu_ttf_initialized: bool = false,
    next_texture_id: u32 = 1,

    pub const InitOptions = struct {
        requested_backend: Backend,
        window: *sdl.Window,
        ui_font_path: [:0]const u8,
        ui_bold_font_path: [:0]const u8,
        prose_font_path: [:0]const u8,
        prose_bold_font_path: [:0]const u8,
        prose_italic_font_path: [:0]const u8,
        prose_bold_italic_font_path: [:0]const u8,
        mono_font_path: [:0]const u8,
        icon_font_path: [:0]const u8,
        /// Optional coverage fallback for `mono`. Typically Verde's embedded
        /// JetBrains Mono Nerd, used when the user's chosen terminal mono has
        /// sparse Dingbats/Arrows coverage (CaskaydiaMono etc.). Null disables
        /// the fallback.
        mono_symbols_font_path: ?[:0]const u8 = null,
        /// Optional dedicated symbols face (Noto Sans Symbols 2) used as the
        /// final coverage stage for Dingbats / Misc Symbols glyphs that
        /// neither the primary mono nor mono_symbols carry. Null disables.
        symbols_font_path: ?[:0]const u8 = null,
        /// Optional secondary symbols face (Noto Sans Symbols, original) that
        /// complements `symbols` with numbered dingbats (❶❷..❿ / ➀➁..➓) and
        /// other blocks Symbols 2 omits. Null disables.
        symbols_alt_font_path: ?[:0]const u8 = null,
        /// Optional monochrome emoji face (Noto Emoji) for emoji-styled
        /// Dingbats (✨/✅/❌/➕/❤) and 4-byte emoji (🔥/📦) that the
        /// symbols face excludes. Null disables.
        emoji_font_path: ?[:0]const u8 = null,
    };

    pub fn init(options: InitOptions) !Renderer {
        return try initSdlGpu(options);
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
        result.gpu_ui_font = try palette.sdl.ttfOpenFont(options.ui_font_path, 16.0);
        result.gpu_ui_bold_font = try palette.sdl.ttfOpenFont(options.ui_bold_font_path, 16.0);
        result.gpu_prose_font = try palette.sdl.ttfOpenFont(options.prose_font_path, 16.0);
        result.gpu_prose_bold_font = try palette.sdl.ttfOpenFont(options.prose_bold_font_path, 16.0);
        result.gpu_prose_italic_font = try palette.sdl.ttfOpenFont(options.prose_italic_font_path, 16.0);
        result.gpu_prose_bold_italic_font = try palette.sdl.ttfOpenFont(options.prose_bold_italic_font_path, 16.0);
        result.gpu_mono_font = try palette.sdl.ttfOpenFont(options.mono_font_path, 16.0);
        result.gpu_icon_font = try palette.sdl.ttfOpenFont(options.icon_font_path, 16.0);
        if (options.mono_symbols_font_path) |path| {
            result.gpu_mono_symbols_font = palette.sdl.ttfOpenFont(path, 16.0) catch null;
        }
        if (options.symbols_font_path) |path| {
            result.gpu_symbols_font = palette.sdl.ttfOpenFont(path, 16.0) catch null;
        }
        if (options.symbols_alt_font_path) |path| {
            result.gpu_symbols_alt_font = palette.sdl.ttfOpenFont(path, 16.0) catch null;
        }
        if (options.emoji_font_path) |path| {
            result.gpu_emoji_font = palette.sdl.ttfOpenFont(path, 16.0) catch null;
        }
        result.gpu = try palette.renderer.Renderer.init(.{
            .debug_mode = builtin.mode == .Debug,
            .shader_formats = palette.renderer.ShaderFormat.defaultForTarget(builtin.os.tag),
            .shader_packages = palette.renderer.ShaderSource.packagesForTarget(builtin.os.tag),
        });
        try result.gpu.?.configureGpuTextWithAllRoleFonts(.{
            .ui = result.gpu_ui_font.?,
            .ui_bold = result.gpu_ui_bold_font.?,
            .prose = result.gpu_prose_font.?,
            .prose_bold = result.gpu_prose_bold_font.?,
            .prose_italic = result.gpu_prose_italic_font.?,
            .prose_bold_italic = result.gpu_prose_bold_italic_font.?,
            .mono = result.gpu_mono_font,
            .icon = result.gpu_icon_font,
            .mono_symbols = result.gpu_mono_symbols_font,
            .symbols = result.gpu_symbols_font,
            .symbols_alt = result.gpu_symbols_alt_font,
            .emoji = result.gpu_emoji_font,
        });
        text_measure.configure(.{
            .ui = result.gpu_ui_font.?,
            .ui_bold = result.gpu_ui_bold_font.?,
            .prose = result.gpu_prose_font.?,
            .prose_bold = result.gpu_prose_bold_font.?,
            .prose_italic = result.gpu_prose_italic_font.?,
            .prose_bold_italic = result.gpu_prose_bold_italic_font.?,
            .mono = result.gpu_mono_font.?,
            .icon = result.gpu_icon_font.?,
        });
        try result.gpu.?.claimWindow(@ptrCast(options.window));
        return result;
    }

    pub fn configureTextMeasureRenderer(self: *Renderer) void {
        if (self.active_backend == .sdl_gpu) {
            if (self.gpu) |*gpu| text_measure.configureRenderer(gpu);
        }
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.active_backend == .sdl_gpu) {
            // SDL_GPU teardown can block indefinitely on some Linux/NVIDIA/Wayland
            // close paths. The process is exiting, so prefer prompt shutdown and let
            // the OS/driver reclaim GPU resources.
            self.* = undefined;
            return;
        }
        text_measure.clear();
        if (self.gpu) |*gpu| {
            if (self.window) |window| gpu.releaseWindow(@ptrCast(window));
            gpu.deinit();
        }
        if (self.gpu_emoji_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_symbols_alt_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_symbols_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_mono_symbols_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_icon_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_mono_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_prose_bold_italic_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_prose_italic_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_prose_bold_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_prose_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_ui_bold_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_ui_font) |font| palette.sdl.ttfCloseFont(font);
        if (self.gpu_ttf_initialized) palette.sdl.ttfQuit();
        self.* = undefined;
    }

    pub fn usingFallback(self: *const Renderer) bool {
        return self.requested_backend != self.active_backend;
    }

    pub fn activeBackend(self: *const Renderer) Backend {
        return self.active_backend;
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

    pub fn releaseTextureCallback(context: ?*anyopaque, texture_id: c_uint) void {
        releasePaneTextureCallback(context, texture_id);
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
    ) !palette.renderer.WindowRenderOutcome {
        _ = framebuffer_width;
        _ = framebuffer_height;
        return try self.renderSdlGpuBatch(allocator, batch);
    }

    fn renderSdlGpuBatch(self: *Renderer, allocator: std.mem.Allocator, batch: *const palette.RenderBatch) !palette.renderer.WindowRenderOutcome {
        const window = self.window orelse return error.SdlGpuWindowMissing;
        return try self.gpu.?.renderWindow(
            allocator,
            @ptrCast(window),
            batch,
            .{
                .r = theme.background()[0],
                .g = theme.background()[1],
                .b = theme.background()[2],
                .a = theme.background()[3],
            },
        );
    }

    pub fn lastSdlGpuFrameStats(self: *const Renderer) ?palette.renderer.FrameStats {
        if (self.active_backend != .sdl_gpu) return null;
        return self.gpu.?.lastFrameStats();
    }
};
