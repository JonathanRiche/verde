//! Minimal native shell prototype for the desktop chat workflow.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const palette = @import("palette");
const sdl = @import("zsdl3");

const app_config = @import("config.zig");
const browser_runtime = @import("browser/mod.zig");
const browser_texture = @import("browser/texture.zig");
const chat_threads = @import("chat/threads.zig");
const cli = @import("cli.zig");
const live_ipc = @import("ipc/server.zig");
const keybinds = @import("keybinds.zig");
const profiler = @import("profiler.zig");
const runtime_log = @import("runtime_log.zig");
const stb_image = @import("stb_image.zig");
const utils = @import("utils.zig");
const ui_layout = @import("ui/layout.zig");
const workspace_panes_ui = @import("ui/workspace_panes.zig");
const sidebar_ui = @import("ui/sidebar.zig");
const chat_panel_ui = @import("ui/chat_panel.zig");
const browser_ui = @import("ui/browser.zig");
const debug_ui = @import("ui/debug.zig");
const terminal_panel_ui = @import("ui/terminal_panel.zig");
const palette_frame_renderer = @import("ui/palette_frame_renderer.zig");
const ui_theme = @import("ui/theme.zig");
const colors = @import("ui/colors.zig");

const native_state = @import("state.zig");
const AppState = native_state.AppState;
const Storage = native_state.Storage;

const log = native_state.log;

extern fn SDL_GetWindowSizeInPixels(window: *sdl.Window, w: ?*c_int, h: ?*c_int) bool;
extern fn SDL_GetWindowProperties(window: *sdl.Window) sdl.PropertiesID;
extern fn SDL_GetWindowFlags(window: *sdl.Window) sdl.Window.Flags;
extern fn SDL_GetModState() sdl.Keymod;
extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) bool;
extern fn SDL_ShowWindow(window: *sdl.Window) bool;
extern fn SDL_RaiseWindow(window: *sdl.Window) bool;
extern fn SDL_SetWindowFocusable(window: *sdl.Window, focusable: bool) bool;
extern fn SDL_SyncWindow(window: *sdl.Window) bool;
extern fn SDL_WaitEventTimeout(event: *sdl.Event, timeout_ms: c_int) bool;
extern fn SDL_TextInputActive(window: *sdl.Window) bool;

pub const std_options: std.Options = .{
    .enable_segfault_handler = true,
    .logFn = runtime_log.logFn,
};

pub const panic = std.debug.FullPanic(runtime_log.panicFn);

const DEFAULT_FONT_SIZE: f32 = ui_theme.DEFAULT_FONT_SIZE;
const DEFAULT_WINDOW_WIDTH: c_int = 1360;
const DEFAULT_WINDOW_HEIGHT: c_int = 860;
const MIN_WINDOW_WIDTH: c_int = 960;
const MIN_WINDOW_HEIGHT: c_int = 680;
const MAX_WINDOW_WIDTH: c_int = 1520;
const MAX_WINDOW_HEIGHT: c_int = 980;
const ACTIVE_WAIT_TIMEOUT_MS: c_int = 16;
const IDLE_WAIT_TIMEOUT_MS: c_int = 50;
const MOUSE_MOTION_RENDER_INTERVAL_MS: i64 = 33;
const MACOS_CMD_W_CLOSE_SUPPRESS_MS: i64 = 750;
var linux_wayland_browser_host: browser_runtime.LinuxWaylandHost = .{};
const PALETTE_GPU_UI_FONT_PATHS = [_][:0]const u8{
    "src/assets/fonts/CalSans-Regular.ttf",
    "packages/desktop/src/assets/fonts/CalSans-Regular.ttf",
};
const PALETTE_GPU_UI_BOLD_FONT_PATHS = [_][:0]const u8{
    "src/assets/fonts/NotoSans-Bold.ttf",
    "packages/desktop/src/assets/fonts/NotoSans-Bold.ttf",
};
const PALETTE_GPU_PROSE_FONT_PATHS = [_][:0]const u8{
    "src/assets/fonts/NotoSans-Regular.ttf",
    "packages/desktop/src/assets/fonts/NotoSans-Regular.ttf",
};
const PALETTE_GPU_PROSE_BOLD_FONT_PATHS = [_][:0]const u8{
    "src/assets/fonts/NotoSans-Bold.ttf",
    "packages/desktop/src/assets/fonts/NotoSans-Bold.ttf",
};
const PALETTE_GPU_PROSE_ITALIC_FONT_PATHS = [_][:0]const u8{
    "src/assets/fonts/NotoSans-Italic.ttf",
    "packages/desktop/src/assets/fonts/NotoSans-Italic.ttf",
};
const PALETTE_GPU_PROSE_BOLD_ITALIC_FONT_PATHS = [_][:0]const u8{
    "src/assets/fonts/NotoSans-BoldItalic.ttf",
    "packages/desktop/src/assets/fonts/NotoSans-BoldItalic.ttf",
};
const PALETTE_GPU_ICON_FONT_PATHS = [_][:0]const u8{
    "src/assets/fonts/SymbolsNerdFontMono-Regular.ttf",
    "packages/desktop/src/assets/fonts/SymbolsNerdFontMono-Regular.ttf",
};
const PALETTE_GPU_MONO_FONT_PATHS = [_][:0]const u8{
    "src/assets/fonts/JetBrainsMonoNerdFont-Regular.ttf",
    "packages/desktop/src/assets/fonts/JetBrainsMonoNerdFont-Regular.ttf",
};

const CAL_SANS_BYTES = @embedFile("assets/fonts/CalSans-Regular.ttf");
const NOTO_SANS_REGULAR_BYTES = @embedFile("assets/fonts/NotoSans-Regular.ttf");
const NOTO_SANS_BOLD_BYTES = @embedFile("assets/fonts/NotoSans-Bold.ttf");
const NOTO_SANS_ITALIC_BYTES = @embedFile("assets/fonts/NotoSans-Italic.ttf");
const NOTO_SANS_BOLD_ITALIC_BYTES = @embedFile("assets/fonts/NotoSans-BoldItalic.ttf");
const CODICON_BYTES = @embedFile("assets/fonts/Codicon.ttf");
const NERD_SYMBOLS_BYTES = @embedFile("assets/fonts/SymbolsNerdFontMono-Regular.ttf");

var macos_cmd_w_pane_close_until_ms: i64 = 0;
var macos_launch_close_suppress_until_ms: i64 = 0;
var macos_last_text_input_timestamp_ns: u64 = 0;
var macos_last_text_input_len: usize = 0;
var macos_last_text_input: [64]u8 = std.mem.zeroes([64]u8);
const MACOS_DUPLICATE_TEXT_INPUT_SUPPRESS_NS: u64 = 30 * std.time.ns_per_ms;
const MACOS_LAUNCH_CLOSE_SUPPRESS_MS: i64 = 650;

const WindowFrame = struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub fn main(init: std.process.Init) void {
    mainInner(init) catch |err| {
        runtime_log.diagnostic("fatal startup error: {s}", .{@errorName(err)});
        std.debug.print("fatal startup error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn mainInner(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (builtin.mode == .Debug) _ = debug_allocator.deinit();
    }
    const allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    switch (try cli.dispatch(allocator, init.io, init.minimal.args)) {
        .handled => return,
        .launch_app => {},
    }

    _ = SDL_SetHint("SDL_VIDEO_WAYLAND_SCALE_TO_DISPLAY", "1");
    if (builtin.os.tag == .macos) {
        _ = SDL_SetHint("SDL_MAC_BACKGROUND_APP", "0");
        _ = SDL_SetHint("SDL_WINDOW_ACTIVATE_WHEN_SHOWN", "1");
        _ = SDL_SetHint("SDL_WINDOW_ACTIVATE_WHEN_RAISED", "1");
        _ = SDL_SetHint("SDL_QUIT_ON_LAST_WINDOW_CLOSE", "0");
    }
    try sdl.setAppMetadata("verde Native", "0.0.0", "com.verde.native");
    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit();

    var storage = try Storage.init(allocator);
    defer storage.deinit();
    runtime_log.init(init.io, storage.pref_path) catch |err| {
        log.warn("failed to initialize runtime logging: {s}", .{@errorName(err)});
    };
    if (runtime_log.stderrLogPath()) |path| {
        log.info("runtime stderr redirected to {s}", .{path});
    }

    const requested_renderer_backend = configuredPaletteRendererBackend();

    const initial_window_frame = initialWindowFrame();
    const window = try sdl.Window.create(
        "verde",
        initial_window_frame.w,
        initial_window_frame.h,
        .{
            .resizable = true,
            .high_pixel_density = true,
        },
    );
    defer window.destroy();
    window.setPosition(initial_window_frame.x, initial_window_frame.y) catch {};
    activateMacosHostWindow(window);
    if (builtin.os.tag == .macos) {
        macos_launch_close_suppress_until_ms = currentTimeMillis() + MACOS_LAUNCH_CLOSE_SUPPRESS_MS;
        verde_macos_host_window_install_close_monitor(nativeBrowserHostWindow(window));
    }
    defer sdl.stopTextInput(window) catch {};
    installWindowIcon(window);

    const loaded_app_config = app_config.loadAppConfig(allocator) catch |err| blk: {
        log.warn("failed to load app config: {s}", .{@errorName(err)});
        break :blk app_config.AppConfig{ .font_size = DEFAULT_FONT_SIZE };
    };

    // Install the font metrics used by the Palette desktop UI.
    ui_theme.installFonts(
        CAL_SANS_BYTES[0..CAL_SANS_BYTES.len],
        NOTO_SANS_BOLD_BYTES[0..NOTO_SANS_BOLD_BYTES.len],
        NOTO_SANS_ITALIC_BYTES[0..NOTO_SANS_ITALIC_BYTES.len],
        NOTO_SANS_BOLD_ITALIC_BYTES[0..NOTO_SANS_BOLD_ITALIC_BYTES.len],
        CODICON_BYTES[0..CODICON_BYTES.len],
        NERD_SYMBOLS_BYTES[0..NERD_SYMBOLS_BYTES.len],
        loaded_app_config.font_size,
    );
    const palette_gpu_ui_font_path = try paletteGpuFontPath(
        allocator,
        storage.pref_path,
        "CalSans-Regular.ttf",
        CAL_SANS_BYTES[0..],
        &PALETTE_GPU_UI_FONT_PATHS,
    );
    defer allocator.free(palette_gpu_ui_font_path);
    const palette_gpu_ui_bold_font_path = try paletteGpuFontPath(
        allocator,
        storage.pref_path,
        "NotoSans-Bold.ttf",
        NOTO_SANS_BOLD_BYTES[0..],
        &PALETTE_GPU_UI_BOLD_FONT_PATHS,
    );
    defer allocator.free(palette_gpu_ui_bold_font_path);
    const palette_gpu_prose_font_path = try paletteGpuFontPath(
        allocator,
        storage.pref_path,
        "NotoSans-Regular.ttf",
        NOTO_SANS_REGULAR_BYTES[0..],
        &PALETTE_GPU_PROSE_FONT_PATHS,
    );
    defer allocator.free(palette_gpu_prose_font_path);
    const palette_gpu_prose_bold_font_path = try paletteGpuFontPath(
        allocator,
        storage.pref_path,
        "NotoSans-Bold.ttf",
        NOTO_SANS_BOLD_BYTES[0..],
        &PALETTE_GPU_PROSE_BOLD_FONT_PATHS,
    );
    defer allocator.free(palette_gpu_prose_bold_font_path);
    const palette_gpu_prose_italic_font_path = try paletteGpuFontPath(
        allocator,
        storage.pref_path,
        "NotoSans-Italic.ttf",
        NOTO_SANS_ITALIC_BYTES[0..],
        &PALETTE_GPU_PROSE_ITALIC_FONT_PATHS,
    );
    defer allocator.free(palette_gpu_prose_italic_font_path);
    const palette_gpu_prose_bold_italic_font_path = try paletteGpuFontPath(
        allocator,
        storage.pref_path,
        "NotoSans-BoldItalic.ttf",
        NOTO_SANS_BOLD_ITALIC_BYTES[0..],
        &PALETTE_GPU_PROSE_BOLD_ITALIC_FONT_PATHS,
    );
    defer allocator.free(palette_gpu_prose_bold_italic_font_path);
    const palette_gpu_mono_font_path = try ghosttyMonoFontPath(allocator) orelse try paletteGpuFontPath(
        allocator,
        storage.pref_path,
        "JetBrainsMonoNerdFont-Regular.ttf",
        @embedFile("assets/fonts/JetBrainsMonoNerdFont-Regular.ttf")[0..],
        &PALETTE_GPU_MONO_FONT_PATHS,
    );
    defer allocator.free(palette_gpu_mono_font_path);
    const palette_gpu_icon_font_path = try paletteGpuFontPath(
        allocator,
        storage.pref_path,
        "SymbolsNerdFontMono-Regular.ttf",
        NERD_SYMBOLS_BYTES[0..],
        &PALETTE_GPU_ICON_FONT_PATHS,
    );
    defer allocator.free(palette_gpu_icon_font_path);
    var palette_renderer = try palette_frame_renderer.Renderer.init(.{
        .requested_backend = requested_renderer_backend,
        .window = window,
        .ui_font_path = palette_gpu_ui_font_path,
        .ui_bold_font_path = palette_gpu_ui_bold_font_path,
        .prose_font_path = palette_gpu_prose_font_path,
        .prose_bold_font_path = palette_gpu_prose_bold_font_path,
        .prose_italic_font_path = palette_gpu_prose_italic_font_path,
        .prose_bold_italic_font_path = palette_gpu_prose_bold_italic_font_path,
        .mono_font_path = palette_gpu_mono_font_path,
        .icon_font_path = palette_gpu_icon_font_path,
    });
    defer palette_renderer.deinit(allocator);
    if (palette_renderer.usingFallback()) {
        log.warn("requested SDL_GPU palette renderer, falling back to GL until texture interop is available", .{});
    }
    if (palette_renderer.activeBackend() == .sdl_gpu) {
        browser_texture.configureExternalUploader(
            &palette_renderer,
            palette_frame_renderer.Renderer.uploadPaneTextureCallback,
            palette_frame_renderer.Renderer.releasePaneTextureCallback,
        );
    }
    defer browser_texture.configureExternalUploader(null, null, null);
    runtime_log.diagnostic("palette renderer active backend={s}", .{@tagName(palette_renderer.activeBackend())});

    var ui_scale = currentWindowDisplayScale(window);
    // Apply the global ImGui style after the display scale is known.
    ui_theme.applyTheme(ui_scale);

    var state = try AppState.init(allocator, &storage, loaded_app_config, .{
        .gl_texture_uploads_enabled = false,
        .browser_textures_enabled = palette_renderer.activeBackend() == .sdl_gpu,
        .texture_upload_context = if (palette_renderer.activeBackend() == .sdl_gpu) &palette_renderer else null,
        .texture_upload_fn = if (palette_renderer.activeBackend() == .sdl_gpu) palette_frame_renderer.Renderer.uploadLoadedTextureCallback else null,
    });
    defer state.deinit();
    state.attachBrowserHostWindow(nativeBrowserHostWindow(window));
    state.openBrowserOnLaunchIfRequested();
    state.restorePersistedBrowserPaneOnLaunch();
    state.startOpencodeModelOptionsRefresh();
    state.startCursorModelOptionsRefresh();
    var live_server: ?live_ipc.LiveServer = live_ipc.LiveServer.init(allocator, storage.pref_path) catch |err| blk: {
        log.warn("failed to initialize live-control server: {s}", .{@errorName(err)});
        break :blk null;
    };
    if (live_server) |*server| {
        server.start() catch |err| {
            log.warn("failed to start live-control server: {s}", .{@errorName(err)});
            server.deinit();
            live_server = null;
        };
    }
    defer if (live_server) |*server| server.deinit();
    var keyboard = try keybinds.NativeKeyboardConfig.load(allocator);
    defer keyboard.deinit();

    log.info("verde main loop starting", .{});
    defer log.info("verde main loop exiting", .{});

    var running = true;
    var needs_render = true;
    var last_mouse_motion_render_ms: i64 = 0;
    const frame_profile_logging = frameProfileLoggingEnabled();
    var last_frame_profile_log_ms: i64 = 0;
    var last_framebuffer_width: c_int = 0;
    var last_framebuffer_height: c_int = 0;
    while (running) {
        if (macosHostWindowRequestedClose(window, &state)) {
            running = false;
            break;
        }
        var frame_sample = profiler.FrameSample{};
        syncWindowTextInput(window, &state);
        var event_flags = EventFlags{};
        var event_wait_ns: u64 = 0;
        var input_fb_w: c_int = 0;
        var input_fb_h: c_int = 0;
        getWindowSizeInPixels(window, &input_fb_w, &input_fb_h);
        ui_layout.refreshPaletteModalHits(&state, @floatFromInt(input_fb_w), @floatFromInt(input_fb_h));
        running = processEvents(window, &state, &keyboard, ui_scale, &event_flags, &frame_sample, &event_wait_ns);
        frame_sample.waited_ns = event_wait_ns;
        recordSpan(&frame_sample, .poll_picker, struct {
            fn run(app_state: *AppState) void {
                app_state.processDeferredProjectDirectoryBrowse();
            }
        }.run, .{&state});
        recordSpan(&frame_sample, .poll_picker, struct {
            fn run(app_state: *AppState) void {
                app_state.pollPicker();
            }
        }.run, .{&state});
        recordSpan(&frame_sample, .poll_models, struct {
            fn run(app_state: *AppState) void {
                app_state.pollOpencodeModelOptionsCache();
                app_state.pollClaudeModelOptionsCache();
                app_state.pollCursorModelOptionsCache();
            }
        }.run, .{&state});
        var send_needs_render = false;
        recordSpan(&frame_sample, .poll_send, struct {
            fn run(app_state: *AppState, changed: *bool) void {
                changed.* = app_state.pollSend();
            }
        }.run, .{ &state, &send_needs_render });
        var browser_needs_render = false;
        recordSpan(&frame_sample, .poll_browser, struct {
            fn run(app_state: *AppState, changed: *bool) void {
                changed.* = app_state.pollBrowser();
            }
        }.run, .{ &state, &browser_needs_render });
        var terminal_needs_render = false;
        recordSpan(&frame_sample, .poll_terminals, struct {
            fn run(app_state: *AppState, changed: *bool) void {
                changed.* = app_state.pollTerminals();
            }
        }.run, .{ &state, &terminal_needs_render });
        if (live_server) |*server| {
            if (server.processPending(&state)) needs_render = true;
        }

        var observed_fb_width: c_int = 0;
        var observed_fb_height: c_int = 0;
        getWindowSizeInPixels(window, &observed_fb_width, &observed_fb_height);
        const framebuffer_size_changed = observed_fb_width != last_framebuffer_width or observed_fb_height != last_framebuffer_height;
        if (framebuffer_size_changed) {
            const observed_scale = currentWindowDisplayScale(window);
            var logical_w: c_int = 0;
            var logical_h: c_int = 0;
            window.getSize(&logical_w, &logical_h) catch {};
            runtime_log.diagnostic("framebuffer size changed: pixel {d}x{d} logical {d}x{d} scale {d:.3} (prev pixel {d}x{d})", .{
                observed_fb_width,
                observed_fb_height,
                logical_w,
                logical_h,
                observed_scale,
                last_framebuffer_width,
                last_framebuffer_height,
            });
            last_framebuffer_width = observed_fb_width;
            last_framebuffer_height = observed_fb_height;
        }

        const continuous_frames = appNeedsContinuousFrames(&state);
        const event_needs_render = event_flags.has_non_mouse_motion or
            shouldRenderMouseMotion(event_flags.has_mouse_motion, continuous_frames, &last_mouse_motion_render_ms);
        needs_render = needs_render or send_needs_render or browser_needs_render or terminal_needs_render or event_needs_render or framebuffer_size_changed or continuous_frames;
        if (!needs_render) {
            profiler.recordFrame(frame_sample);
            maybeLogFrameProfile(frame_profile_logging, &last_frame_profile_log_ms, &palette_renderer);
            continue;
        }
        needs_render = false;

        var fb_width: c_int = 0;
        var fb_height: c_int = 0;
        recordSpan(&frame_sample, .render_setup, struct {
            fn run(
                app_window: *sdl.Window,
                framebuffer_width: *c_int,
                framebuffer_height: *c_int,
                current_scale: *f32,
            ) void {
                getWindowSizeInPixels(app_window, framebuffer_width, framebuffer_height);

                const next_ui_scale = currentWindowDisplayScale(app_window);
                if (@abs(next_ui_scale - current_scale.*) > 0.01) {
                    current_scale.* = next_ui_scale;
                    ui_theme.applyTheme(current_scale.*);
                }
            }
        }.run, .{ window, &fb_width, &fb_height, &ui_scale });
        var window_screen_x: c_int = 0;
        var window_screen_y: c_int = 0;
        window.getPosition(&window_screen_x, &window_screen_y) catch {};
        state.noteAppWindowFrame(window_screen_x, window_screen_y, ui_scale);
        state.palette_overlay_batch.clear();
        state.palette_frame_text.clearRetainingCapacity();
        _ = state.palette_frame_text_arena.reset(.retain_capacity);
        state.code_copy_buttons.clearRetainingCapacity();
        state.card_toggle_hits.clearRetainingCapacity();

        recordSpan(&frame_sample, .render_root, struct {
            fn run(app_state: *AppState, framebuffer_width: c_int, framebuffer_height: c_int) void {
                ui_layout.renderRoot(app_state, @floatFromInt(framebuffer_width), @floatFromInt(framebuffer_height));
            }
        }.run, .{ &state, fb_width, fb_height });
        recordSpan(&frame_sample, .flush_dirty, struct {
            fn run(app_state: *AppState) void {
                app_state.flushIfDirty();
            }
        }.run, .{&state});

        recordSpan(&frame_sample, .draw_backend, struct {
            fn run(
                palette_command_renderer: *palette_frame_renderer.Renderer,
                app_state: *AppState,
                allocator_arg: std.mem.Allocator,
                framebuffer_width: c_int,
                framebuffer_height: c_int,
            ) void {
                palette_command_renderer.renderBatch(
                    allocator_arg,
                    &app_state.palette_overlay_batch,
                    @floatFromInt(framebuffer_width),
                    @floatFromInt(framebuffer_height),
                ) catch |err| log.warn("failed to render palette overlay batch: {s}", .{@errorName(err)});
            }
        }.run, .{ &palette_renderer, &state, allocator, fb_width, fb_height });
        const swap_start = profiler.nowNs();
        frame_sample.add(.swap_window, profiler.elapsedNs(swap_start));
        frame_sample.rendered = true;
        profiler.recordFrame(frame_sample);
        maybeLogFrameProfile(frame_profile_logging, &last_frame_profile_log_ms, &palette_renderer);
    }
}

fn configuredPaletteRendererBackend() palette_frame_renderer.Backend {
    return switch (build_options.palette_renderer) {
        .sdl_gpu => .sdl_gpu,
    };
}

fn paletteGpuFontPath(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    file_name: []const u8,
    bytes: []const u8,
    dev_candidates: []const [:0]const u8,
) ![:0]u8 {
    for (dev_candidates) |candidate| {
        if (std.c.access(candidate.ptr, std.c.R_OK) != 0) continue;
        return try allocator.dupeZ(u8, candidate);
    }

    return try installBundledFont(allocator, pref_path, file_name, bytes);
}

fn ghosttyMonoFontPath(allocator: std.mem.Allocator) !?[:0]u8 {
    const family = try ghosttyFontFamily(allocator) orelse return null;
    defer allocator.free(family);
    return try fontPathForFamily(allocator, family);
}

fn ghosttyFontFamily(allocator: std.mem.Allocator) !?[]u8 {
    const home = std.c.getenv("HOME") orelse return null;
    const config_path = try std.fs.path.join(allocator, &.{ std.mem.span(home), ".config", "ghostty", "config" });
    defer allocator.free(config_path);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), config_path, allocator, .limited(128 * 1024)) catch return null;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const no_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index| raw_line[0..index] else raw_line;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t\r");
        if (!std.mem.eql(u8, key, "font-family")) continue;
        return try allocator.dupe(u8, unquoteGhosttyValue(line[equals + 1 ..]));
    }
    return null;
}

fn fontPathForFamily(allocator: std.mem.Allocator, family: []const u8) !?[:0]u8 {
    var compact = std.ArrayList(u8).empty;
    defer compact.deinit(allocator);
    for (family) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '-' or byte == '_') continue;
        try compact.append(allocator, byte);
    }

    const compact_name = compact.items;
    const candidates = [_][]const u8{
        "/usr/share/fonts/TTF",
        "/usr/local/share/fonts",
    };
    for (candidates) |dir| {
        const path = try allocFontCandidatePath(allocator, dir, compact_name);
        if (std.c.access(path.ptr, std.c.R_OK) == 0) return path;
        allocator.free(path);
    }

    const home = std.c.getenv("HOME") orelse return null;
    const home_slice = std.mem.span(home);
    const local_candidates = [_][]const u8{
        ".local/share/fonts",
        ".fonts",
    };
    for (local_candidates) |dir| {
        const parent = try std.fs.path.join(allocator, &.{ home_slice, dir });
        defer allocator.free(parent);
        const path = try allocFontCandidatePath(allocator, parent, compact_name);
        if (std.c.access(path.ptr, std.c.R_OK) == 0) return path;
        allocator.free(path);
    }
    return null;
}

fn allocFontCandidatePath(allocator: std.mem.Allocator, dir: []const u8, compact_name: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}-Regular.ttf", .{ dir, compact_name });
    defer allocator.free(path);
    return try allocator.dupeZ(u8, path);
}

fn unquoteGhosttyValue(raw_value: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw_value, " \t\r");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') value = value[1 .. value.len - 1];
    return value;
}

fn installBundledFont(
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    file_name: []const u8,
    bytes: []const u8,
) ![:0]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    var pref_dir = try std.Io.Dir.openDirAbsolute(threaded.io(), pref_path, .{});
    defer pref_dir.close(threaded.io());
    try pref_dir.createDirPath(threaded.io(), "fonts");

    const path = try std.fs.path.join(allocator, &.{ pref_path, "fonts", file_name });
    defer allocator.free(path);

    var file = try std.Io.Dir.createFileAbsolute(threaded.io(), path, .{ .truncate = true });
    defer file.close(threaded.io());
    try file.writeStreamingAll(threaded.io(), bytes);

    return try allocator.dupeZ(u8, path);
}

const EventFlags = struct {
    has_mouse_motion: bool = false,
    has_non_mouse_motion: bool = false,
};

fn frameProfileLoggingEnabled() bool {
    return std.c.getenv("VERDE_FRAME_PROFILE_LOG") != null;
}

fn maybeLogFrameProfile(enabled: bool, last_log_ms: *i64, palette_renderer: *const palette_frame_renderer.Renderer) void {
    if (!enabled) return;
    const now_ms: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    if (last_log_ms.* != 0 and now_ms - last_log_ms.* < 1000) return;
    last_log_ms.* = now_ms;

    const snapshot = profiler.snapshot();
    if (snapshot.count == 0) return;
    const sections = recentRenderedSectionStats();
    runtime_log.diagnostic(
        "frame-profile backend={s} samples={d} avg_ms={d:.2} max_ms={d:.2} slow={d} hitch={d} latest_ms={d:.2} rendered={d} render_root_avg_ms={d:.2} draw_backend_avg_ms={d:.2} poll_terminals_avg_ms={d:.2}",
        .{
            @tagName(palette_renderer.activeBackend()),
            snapshot.count,
            profiler.nsToMs(snapshot.avg_active_ns),
            profiler.nsToMs(snapshot.max_active_ns),
            snapshot.slow_count,
            snapshot.hitch_count,
            profiler.nsToMs(snapshot.latest.active_ns),
            sections.rendered_count,
            profiler.nsToMs(sections.render_root_avg_ns),
            profiler.nsToMs(sections.draw_backend_avg_ns),
            profiler.nsToMs(sections.poll_terminals_avg_ns),
        },
    );
    if (palette_renderer.lastSdlGpuFrameStats()) |stats| {
        if (stats.hasWork()) logSdlGpuFrameStats(stats);
    }
}

const RenderedSectionStats = struct {
    rendered_count: usize = 0,
    render_root_avg_ns: u64 = 0,
    draw_backend_avg_ns: u64 = 0,
    poll_terminals_avg_ns: u64 = 0,
};

fn recentRenderedSectionStats() RenderedSectionStats {
    const count = profiler.frameCount();
    if (count == 0) return .{};

    var rendered_count: usize = 0;
    var render_root_sum: u128 = 0;
    var draw_backend_sum: u128 = 0;
    var poll_terminals_sum: u128 = 0;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const frame = profiler.frameAt(index) orelse continue;
        if (!frame.rendered) continue;
        rendered_count += 1;
        render_root_sum += frame.sectionNs(.render_root);
        draw_backend_sum += frame.sectionNs(.draw_backend);
        poll_terminals_sum += frame.sectionNs(.poll_terminals);
    }
    if (rendered_count == 0) return .{};
    return .{
        .rendered_count = rendered_count,
        .render_root_avg_ns = @intCast(render_root_sum / rendered_count),
        .draw_backend_avg_ns = @intCast(draw_backend_sum / rendered_count),
        .poll_terminals_avg_ns = @intCast(poll_terminals_sum / rendered_count),
    };
}

fn logSdlGpuFrameStats(stats: palette.renderer.FrameStats) void {
    runtime_log.diagnostic(
        "sdlgpu-stage batch_build_ms={d:.2} solid_upload_ms={d:.2} image_prepare_ms={d:.2} image_upload_ms={d:.2} browser_upload_ms={d:.2} text_prepare_ms={d:.2} text_upload_ms={d:.2} submit_present_ms={d:.2} image_uploads={d}/{d} browser_uploads={d}/{d}",
        .{
            profiler.nsToMs(stats.batch_build_ns),
            profiler.nsToMs(stats.solid_upload_ns),
            profiler.nsToMs(stats.image_prepare_ns),
            profiler.nsToMs(stats.image_upload_ns),
            profiler.nsToMs(stats.browser_upload_ns),
            profiler.nsToMs(stats.text_prepare_ns),
            profiler.nsToMs(stats.text_upload_ns),
            profiler.nsToMs(stats.submit_present_ns),
            stats.image_upload_count,
            stats.image_upload_bytes,
            stats.browser_upload_count,
            stats.browser_upload_bytes,
        },
    );
}

fn recordSpan(frame_sample: *profiler.FrameSample, section: profiler.Section, comptime function: anytype, args: anytype) void {
    const start = profiler.nowNs();
    @call(.auto, function, args);
    frame_sample.add(section, profiler.elapsedNs(start));
}

fn installWindowIcon(window: *sdl.Window) void {
    const loaded = stb_image.loadFromMemory(native_state.VERDE_LOGO_BYTES) catch |err| {
        log.warn("failed to decode window icon: {s}", .{@errorName(err)});
        return;
    };
    defer loaded.deinit();

    const pitch = std.math.mul(c_int, loaded.width, loaded.channels) catch {
        log.warn("failed to compute window icon pitch", .{});
        return;
    };
    const surface = sdl.createSurfaceFrom(
        loaded.width,
        loaded.height,
        .abgr8888,
        @ptrCast(loaded.pixels),
        pitch,
    ) catch {
        log.warn("failed to create SDL surface for window icon", .{});
        return;
    };
    defer surface.destroy();

    window.setIcon(surface) catch {
        log.warn("failed to set window icon", .{});
    };
}

fn initialWindowFrame() WindowFrame {
    const display_id = sdl.getPrimaryDisplay();
    if (display_id == .invalid) {
        return .{
            .x = sdl.Window.pos_centered,
            .y = sdl.Window.pos_centered,
            .w = DEFAULT_WINDOW_WIDTH,
            .h = DEFAULT_WINDOW_HEIGHT,
        };
    }

    var usable_bounds: sdl.Rect = undefined;
    sdl.getDisplayUsableBounds(display_id, &usable_bounds) catch {
        return .{
            .x = sdl.Window.pos_centered,
            .y = sdl.Window.pos_centered,
            .w = DEFAULT_WINDOW_WIDTH,
            .h = DEFAULT_WINDOW_HEIGHT,
        };
    };

    const width = clampInt(@intFromFloat(@as(f32, @floatFromInt(usable_bounds.w)) * 0.72), MIN_WINDOW_WIDTH, @min(MAX_WINDOW_WIDTH, usable_bounds.w - 40));
    const height = clampInt(@intFromFloat(@as(f32, @floatFromInt(usable_bounds.h)) * 0.74), MIN_WINDOW_HEIGHT, @min(MAX_WINDOW_HEIGHT, usable_bounds.h - 40));
    const x = usable_bounds.x + @divTrunc(usable_bounds.w - width, 2);
    const y = usable_bounds.y + @divTrunc(usable_bounds.h - height, 2);
    return .{ .x = x, .y = y, .w = width, .h = height };
}

fn getWindowSizeInPixels(window: *sdl.Window, w: ?*c_int, h: ?*c_int) void {
    if (!SDL_GetWindowSizeInPixels(window, w, h)) {
        window.getSize(w, h) catch {
            if (w) |width| width.* = DEFAULT_WINDOW_WIDTH;
            if (h) |height| height.* = DEFAULT_WINDOW_HEIGHT;
        };
    }
}

fn currentWindowDisplayScale(window: *sdl.Window) f32 {
    const scale = window.getDisplayScale() catch return 1.0;
    if (!std.math.isFinite(scale) or scale <= 0.0) return 1.0;
    return clampf(scale, 1.0, 2.5);
}

fn nativeBrowserHostWindow(window: *sdl.Window) ?*anyopaque {
    const property_name: [:0]const u8 = switch (builtin.os.tag) {
        .macos => "SDL.window.cocoa.window",
        .windows => "SDL.window.win32.hwnd",
        .linux => {
            const properties = SDL_GetWindowProperties(window);
            const wayland_display = sdl.getPointerProperty(properties, "SDL.window.wayland.display", null);
            const wayland_surface = sdl.getPointerProperty(properties, "SDL.window.wayland.surface", null);
            if (wayland_display != null and wayland_surface != null) {
                linux_wayland_browser_host = .{
                    .display = wayland_display,
                    .surface = wayland_surface,
                };
                return &linux_wayland_browser_host;
            }
            const x11_window = sdl.getNumberProperty(properties, "SDL.window.x11.window", 0);
            if (x11_window <= 0) return null;
            return @ptrFromInt(@as(usize, @intCast(x11_window)));
        },
        else => return null,
    };
    const properties = SDL_GetWindowProperties(window);
    return sdl.getPointerProperty(properties, property_name, null);
}

fn clampInt(value: c_int, min_value: c_int, max_value: c_int) c_int {
    return @max(min_value, @min(value, max_value));
}

fn clampf(value: f32, min_value: f32, max_value: f32) f32 {
    return @max(min_value, @min(value, max_value));
}

// Keeps SDL mouse coordinates in the same framebuffer space used by the ImGui root layout.
fn normalizeMouseEventCoordinates(window: *sdl.Window, event: *sdl.Event) void {
    var logical_width: c_int = 0;
    var logical_height: c_int = 0;
    window.getSize(&logical_width, &logical_height) catch return;

    var pixel_width: c_int = 0;
    var pixel_height: c_int = 0;
    getWindowSizeInPixels(window, &pixel_width, &pixel_height);

    if (logical_width <= 0 or logical_height <= 0 or pixel_width <= 0 or pixel_height <= 0) return;

    const scale_x = @as(f32, @floatFromInt(pixel_width)) / @as(f32, @floatFromInt(logical_width));
    const scale_y = @as(f32, @floatFromInt(pixel_height)) / @as(f32, @floatFromInt(logical_height));
    if (@abs(scale_x - 1.0) < 0.01 and @abs(scale_y - 1.0) < 0.01) return;

    switch (event.type) {
        .mouse_motion => {
            event.motion.x *= scale_x;
            event.motion.y *= scale_y;
            event.motion.xrel *= scale_x;
            event.motion.yrel *= scale_y;
        },
        .mouse_button_down, .mouse_button_up => {
            event.button.x *= scale_x;
            event.button.y *= scale_y;
        },
        .mouse_wheel => {
            event.wheel.mouse_x *= scale_x;
            event.wheel.mouse_y *= scale_y;
        },
        else => {},
    }
}

fn processEvents(
    window: *sdl.Window,
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    ui_scale: f32,
    event_flags: *EventFlags,
    frame_sample: *profiler.FrameSample,
    waited_ns: *u64,
) bool {
    event_flags.* = .{};
    var event: sdl.Event = undefined;

    if (!sdl.pollEvent(&event)) {
        const wait_start = profiler.nowNs();
        if (!SDL_WaitEventTimeout(&event, eventWaitTimeoutMs(state))) {
            waited_ns.* +|= profiler.elapsedNs(wait_start);
            return true;
        }
        waited_ns.* +|= profiler.elapsedNs(wait_start);
        noteEventForRender(&event, event_flags);
        if (!processOneEvent(window, state, keyboard, ui_scale, &event, frame_sample)) return false;
    } else {
        noteEventForRender(&event, event_flags);
        if (!processOneEvent(window, state, keyboard, ui_scale, &event, frame_sample)) return false;
    }

    while (sdl.pollEvent(&event)) {
        noteEventForRender(&event, event_flags);
        if (!processOneEvent(window, state, keyboard, ui_scale, &event, frame_sample)) return false;
    }

    return true;
}

fn noteEventForRender(event: *const sdl.Event, flags: *EventFlags) void {
    if (event.type == .mouse_motion and noMouseButtonsPressed(event.motion.state)) {
        flags.has_mouse_motion = true;
        return;
    }
    flags.has_non_mouse_motion = true;
}

fn noMouseButtonsPressed(state: sdl.MouseButtonFlags) bool {
    return state.left == 0 and state.middle == 0 and state.right == 0 and state.x1 == 0 and state.x2 == 0;
}

fn shouldRenderMouseMotion(has_mouse_motion: bool, continuous_frames: bool, last_render_ms: *i64) bool {
    if (!has_mouse_motion or continuous_frames) return false;
    const now_ms: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    if (last_render_ms.* != 0 and now_ms - last_render_ms.* < MOUSE_MOTION_RENDER_INTERVAL_MS) return false;
    last_render_ms.* = now_ms;
    return true;
}

fn processOneEvent(
    window: *sdl.Window,
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    ui_scale: f32,
    event: *sdl.Event,
    frame_sample: *profiler.FrameSample,
) bool {
    const start = profiler.nowNs();
    normalizeMouseEventCoordinates(window, event);
    switch (event.type) {
        .mouse_motion, .mouse_button_down, .mouse_button_up, .mouse_wheel => {
            var input_fb_w: c_int = 0;
            var input_fb_h: c_int = 0;
            getWindowSizeInPixels(window, &input_fb_w, &input_fb_h);
            ui_layout.refreshPaletteModalHits(state, @floatFromInt(input_fb_w), @floatFromInt(input_fb_h));
        },
        else => {},
    }
    const keep_running = handleEvent(window, state, keyboard, ui_scale, event);
    if (!keep_running) {
        runtime_log.diagnostic("event requested shutdown type={s}", .{@tagName(event.type)});
    }
    frame_sample.add(.event_handling, profiler.elapsedNs(start));
    return keep_running;
}

fn appNeedsContinuousFrames(state: *AppState) bool {
    return state.isPickerPending() or
        state.transcriptMarkdownSelectionDragging() or
        workspace_panes_ui.isFocusAnimating() or
        ui_layout.isSidebarAnimating();
}

fn eventWaitTimeoutMs(state: *AppState) c_int {
    return if (state.isPickerPending() or state.isBrowserVisible() or state.transcriptMarkdownSelectionDragging() or workspace_panes_ui.isFocusAnimating() or ui_layout.isSidebarAnimating())
        ACTIVE_WAIT_TIMEOUT_MS
    else
        IDLE_WAIT_TIMEOUT_MS;
}

fn handleEvent(window: *sdl.Window, state: *AppState, keyboard: *keybinds.NativeKeyboardConfig, ui_scale: f32, event: *sdl.Event) bool {
    switch (event.type) {
        .quit => {
            runtime_log.diagnostic("shutdown requested by SDL quit event", .{});
            return false;
        },
        .window_close_requested => {
            const keep_running = handleWindowCloseRequested(window, state);
            runtime_log.diagnostic("window close requested keep_running={} window_id={d}", .{ keep_running, @intFromEnum(event.window.window_id) });
            return keep_running;
        },
        .window_hidden, .window_minimized => {
            state.suspendBrowserForHostWindowHidden();
        },
        .window_shown, .window_restored => {
            state.resumeBrowserAfterHostWindowShown();
        },
        .key_down => {
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input sdl key_down key=0x{x} scancode={} focused={} visible={}",
                    .{ @intFromEnum(event.key.key), @intFromEnum(event.key.scancode), state.isBrowserPaneFocused(), state.isBrowserVisible() },
                );
            }
            if (terminal_panel_ui.handlePaletteKeyDown(state, &event.key)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.terminal_focused and terminalOwnedShortcut(&event.key)) {
                const terminal_key_handled = state.handleTerminalKeyDown(keyboard, &event.key);
                state.noteTerminalKeyRouting(&event.key, terminal_key_handled);
                if (terminal_key_handled) {
                    return true;
                }
            }
            const action = keyboard.actionForEvent(&event.key);
            const paste_shortcut = shouldPasteClipboardImage(state, &event.key);
            logPasteShortcutEvent(state, &event.key, paste_shortcut);
            if (paste_shortcut) {
                // Browser URL bar + modal text inputs handle their own paste
                // further down the chain. Don't intercept here when one of
                // them owns focus.
                if (!state.browser_address_focused and state.palette_modal_text_focus == .none) {
                    if (state.attachClipboardImageToCurrentDraft()) return true;
                    if (state.pasteClipboardTextIntoPaletteComposer()) return true;
                }
            }
            if (ui_layout.handlePaletteKeyDown(state, &event.key)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.routePaletteComposerKeyDown(&event.key)) {
                syncWindowTextInput(window, state);
                return true;
            }
            // Pane-level bindings must stay app-owned even when a native webview
            // or embedded terminal has keyboard focus.
            if (action) |resolved_workspace_action| {
                if (isWorkspacePaneAction(resolved_workspace_action)) {
                    noteMacosWorkspaceCloseShortcut(&event.key, resolved_workspace_action);
                    handleKeyboardAction(state, keyboard, resolved_workspace_action);
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            const native_browser_focused = state.isNativeBrowserSurfaceFocused();
            if (native_browser_focused) {
                state.browser_address_focused = false;
            }
            if (macosNativeBrowserShouldOwnKeyboard(state)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (!native_browser_focused and browser_ui.handlePaletteKeyDown(state, &event.key)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (handleBrowserSelectAllShortcut(state, &event.key)) {
                return true;
            }
            if (handleBrowserCopyCutShortcut(state, &event.key)) {
                return true;
            }
            if (handleBrowserClipboardShortcut(state, &event.key)) {
                return true;
            }
            if (native_browser_focused and !state.palette_composer.focused) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.isBrowserPaneFocused() and handleBrowserKeyboardEvent(state, &event.key)) {
                return true;
            }
            if (action) |resolved_app_action| switch (resolved_app_action) {
                .toggle_terminal,
                .toggle_browser,
                .toggle_sidebar,
                .toggle_sidebar_hidden,
                .new_thread,
                => {
                    handleKeyboardAction(state, keyboard, resolved_app_action);
                    return true;
                },
                else => {},
            };
            const terminal_key_handled = state.handleTerminalKeyDown(keyboard, &event.key);
            state.noteTerminalKeyRouting(&event.key, terminal_key_handled);
            if (terminal_key_handled) {
                return true;
            }
            if (handleFontSizeShortcut(state, &event.key)) {
                return true;
            }
            if (handleBrowserKeyboardEvent(state, &event.key)) {
                return true;
            }
            if (handleFileSearchNavigation(state, &event.key)) {
                return true;
            }
            if (handlePendingThreadFollowupShortcut(state, &event.key)) {
                return true;
            }
            if (handleWorkspaceContextMenuShortcut(state, &event.key)) {
                return true;
            }
            if (handleComposerFocusShortcut(state, &event.key)) {
                return true;
            }
            if (handleTranscriptMarkdownCopyShortcut(state, &event.key)) {
                return true;
            }
            if (handleTranscriptMarkdownSelectAllShortcut(state, &event.key)) {
                return true;
            }
            if (event.key.repeat) {
                if (keyboard.transcriptScrollActionForEvent(&event.key)) |repeat_action| {
                    handleKeyboardAction(state, keyboard, repeat_action);
                    return true;
                }
            }
            if (action) |resolved_action| {
                handleKeyboardAction(state, keyboard, resolved_action);
            }
        },
        .key_up => {
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input sdl key_up key=0x{x} scancode={} focused={} visible={}",
                    .{ @intFromEnum(event.key.key), @intFromEnum(event.key.scancode), state.isBrowserPaneFocused(), state.isBrowserVisible() },
                );
            }
            if (state.isNativeBrowserSurfaceFocused()) {
                state.browser_address_focused = false;
                syncWindowTextInput(window, state);
                return true;
            }
            if (macosNativeBrowserShouldOwnKeyboard(state)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (handleBrowserKeyboardEvent(state, &event.key)) {
                return true;
            }
        },
        .text_input => {
            const text_input = std.mem.sliceTo(event.text.text, 0);
            if (suppressDuplicateMacosTextInput(text_input, event.text.timestamp)) return true;
            if (ui_layout.handlePaletteTextInput(state, text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.routePaletteComposerTextInput(text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            const native_browser_focused = state.isNativeBrowserSurfaceFocused();
            if (native_browser_focused) {
                state.browser_address_focused = false;
                syncWindowTextInput(window, state);
                return true;
            }
            if (macosNativeBrowserShouldOwnKeyboard(state)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input sdl text_input text=\"{s}\" timestamp={} focused={} native_focused={} visible={}",
                    .{ text_input, event.text.timestamp, state.isBrowserPaneFocused(), native_browser_focused, state.isBrowserVisible() },
                );
            }
            const browser_text_handled = state.handleBrowserKey(.{
                .key_code = 0,
                .text = text_input,
                .pressed = true,
            });
            if (browser_ui.handlePaletteTextInput(state, text_input)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (browser_text_handled) {
                return true;
            }
            const terminal_text_handled = state.handleTerminalTextInput(event.text.text);
            state.noteTerminalTextRouting(text_input, terminal_text_handled);
            if (terminal_text_handled) {
                return true;
            }
        },
        .mouse_motion => {
            if (sidebar_ui.finishThreadDragIfMouseReleased(state, event.motion.x, event.motion.y, event.motion.state)) {
                syncWindowTextInput(window, state);
                return true;
            }
            state.notePaletteWorkspaceMouseMotion(event.motion.x, event.motion.y);
            ui_layout.updateThreadImportModalHover(state, event.motion.x, event.motion.y);
            chat_panel_ui.handleTranscriptPaletteMouseMotion(state);
            ui_layout.handlePaletteMouseMotion(state, event.motion.x, event.motion.y);
            if (terminal_panel_ui.handlePaletteMouseMotion(state, event.motion.x, event.motion.y)) {
                return true;
            }
            if (workspace_panes_ui.handlePaletteMouseMotion(state, event.motion.x, event.motion.y)) {
                return true;
            }
            browser_ui.handlePaletteMouseMotion(state, event.motion.x, event.motion.y);
            sidebar_ui.handlePaletteMouseMotion(state, event.motion.x, event.motion.y);
            if (state.routePaletteComposerMouseMotion(&event.motion, ui_scale)) {
                return true;
            }
            _ = state.handleBrowserMouse(browserMouseMotionEvent(&event.motion));
        },
        .mouse_button_down, .mouse_button_up => {
            if (event.button.button == 1 and sidebar_ui.hasActiveThreadDrag()) {
                if (sidebar_ui.handlePaletteMouseButton(state, event.button.x, event.button.y, event.button.down)) {
                    syncWindowTextInput(window, state);
                    return true;
                }
            }
            if (event.button.button == 1 and ui_layout.handlePaletteMouseButton(state, event.button.x, event.button.y, event.button.down, event.button.clicks)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (event.button.button == 1 and debug_ui.handlePaletteMouseButton(state, event.button.x, event.button.y, event.button.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input sdl mouse_button down={} button={} x={d:.1} y={d:.1} contains={} focused={}",
                    .{
                        event.button.down,
                        event.button.button,
                        event.button.x,
                        event.button.y,
                        state.browserPaneContains(event.button.x, event.button.y),
                        state.isBrowserPaneFocused(),
                    },
                );
            }
            if (event.button.button == 1 and browser_ui.handlePaletteMouseButton(state, event.button.x, event.button.y, event.button.down, event.button.clicks)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (event.button.down and macosBrowserClickWillFocusNativeSurface(state, event.button.x, event.button.y)) {
                if (SDL_TextInputActive(window)) {
                    sdl.stopTextInput(window) catch {};
                }
            }
            const handled = state.handleBrowserMouse(browserMouseButtonEvent(&event.button));
            if (!handled and event.button.down) {
                state.unfocusBrowserPane();
            }
            if (handled) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (event.button.button == 1 and event.button.down and state.sidebar_context_menu_open and
                !sidebar_ui.pointerOverSidebar(event.button.x, event.button.y))
            {
                state.closeSidebarContextMenu();
            }
            if (event.button.down and event.button.button == sidebar_ui.palette_mouse_button_secondary and
                sidebar_ui.handlePaletteSecondaryMouseButton(state, event.button.x, event.button.y, event.button.down))
            {
                syncWindowTextInput(window, state);
                return true;
            }
            // Workspace header (Open / Browser) must run before the sidebar rail so hits are never
            // swallowed by expanded sidebar geometry or rail chrome.
            if (event.button.button == 1 and chat_panel_ui.handleWorkspaceHeaderPaletteMouseButton(
                state,
                event.button.x,
                event.button.y,
                event.button.down,
            )) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (workspace_panes_ui.handlePaletteMouseButton(state, event.button.x, event.button.y, event.button.button, event.button.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (event.button.button == 1 and sidebar_ui.handlePaletteMouseButton(state, event.button.x, event.button.y, event.button.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (event.button.button == 1 and chat_panel_ui.handleFileSearchPaletteMouseButton(state, event.button.x, event.button.y, event.button.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (event.button.button == 1 and chat_panel_ui.handleTranscriptPaletteMouseButton(
                state,
                event.button.x,
                event.button.y,
                event.button.down,
                event.button.clicks,
            )) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (event.button.button == 1 and state.handleComposerDraftImageClearMouseButton(event.button.x, event.button.y, event.button.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (terminal_panel_ui.handlePaletteMouseButton(state, event.button.x, event.button.y, event.button.button, event.button.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (state.routePaletteComposerMouseButton(&event.button, ui_scale)) {
                syncWindowTextInput(window, state);
                return true;
            }
            syncWindowTextInput(window, state);
        },
        .mouse_wheel => {
            if (sidebar_ui.handlePaletteWheel(event.wheel.mouse_x, event.wheel.mouse_y, event.wheel.y)) {
                return true;
            }
            // Terminal panes route wheel input by the event coordinates, so let
            // them claim scroll before chat/composer hit caches can consume it.
            if (terminal_panel_ui.handlePaletteWheel(state, event.wheel.mouse_x, event.wheel.mouse_y, event.wheel.y)) {
                return true;
            }
            if (chat_panel_ui.handleTranscriptPaletteWheel(state, event.wheel.mouse_x, event.wheel.mouse_y, event.wheel.y)) {
                return true;
            }
            if (state.routePaletteComposerWheel(&event.wheel, ui_scale)) {
                return true;
            }
            if (state.handleComposerWheel(&event.wheel)) {
                return true;
            }
            if (state.handleBrowserMouse(browserMouseWheelEvent(&event.wheel))) {
                return true;
            }
        },
        else => {},
    }
    return true;
}

fn browserInputDebugEnabled() bool {
    return std.c.getenv("VERDE_CEF_INPUT_DEBUG") != null;
}

fn syncWindowTextInput(window: *sdl.Window, state: *AppState) void {
    if (macosNativeBrowserShouldOwnKeyboard(state)) {
        if (SDL_TextInputActive(window)) {
            sdl.stopTextInput(window) catch {};
        }
        return;
    }
    const needs_sdl_text_input = state.terminal_focused or
        state.palette_composer.focused or
        state.browser_address_focused or
        state.palette_modal_text_focus != .none or
        (state.isBrowserPaneFocused() and !macosNativeBrowserShouldOwnKeyboard(state));
    if (!needs_sdl_text_input) {
        if (SDL_TextInputActive(window)) {
            sdl.stopTextInput(window) catch {};
        }
        return;
    }
    if (SDL_TextInputActive(window)) return;
    sdl.startTextInput(window) catch {};
    if (browserInputDebugEnabled()) {
        log.info("browser-input enabled SDL text input for Verde-owned text focus", .{});
    }
}

fn handleBrowserKeyboardEvent(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    const key_code = browserKeyCodeForEvent(event) orelse return false;
    return state.handleBrowserKey(.{
        .key_code = key_code,
        .pressed = event.down,
        .ctrl = isKeymodPressed(event.mod, sdl.Keymod.ctrl),
        .shift = isKeymodPressed(event.mod, sdl.Keymod.shift),
        .alt = isKeymodPressed(event.mod, sdl.Keymod.alt),
        .super = isKeymodPressed(event.mod, sdl.Keymod.gui),
    });
}

fn handleBrowserClipboardShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (state.isNativeBrowserSurfaceFocused()) return false;
    if (!state.isBrowserPaneFocused()) return false;
    if (!event.down or event.repeat) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (isKeymodPressed(event.mod, sdl.Keymod.alt)) return false;
    if (event.scancode != .v and event.key != .v) return false;

    const text = state.readClipboardTextForPaste() orelse return true;
    defer state.allocator.free(text);
    if (text.len == 0) return true;
    _ = state.handleBrowserKey(.{
        .key_code = 0,
        .text = text,
        .pressed = true,
        .ctrl = isKeymodPressed(event.mod, sdl.Keymod.ctrl),
        .shift = isKeymodPressed(event.mod, sdl.Keymod.shift),
        .alt = isKeymodPressed(event.mod, sdl.Keymod.alt),
        .super = isKeymodPressed(event.mod, sdl.Keymod.gui),
    });
    return true;
}

fn handleBrowserSelectAllShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (state.isNativeBrowserSurfaceFocused()) return false;
    if (!state.isBrowserPaneFocused()) return false;
    if (!event.down or event.repeat) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (isKeymodPressed(event.mod, sdl.Keymod.alt) or isKeymodPressed(event.mod, sdl.Keymod.shift)) return false;
    if (event.scancode != .a and event.key != .a) return false;
    state.selectAllBrowserFocusedElement();
    return true;
}

fn handleBrowserCopyCutShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (state.isNativeBrowserSurfaceFocused()) return false;
    if (!state.isBrowserPaneFocused()) return false;
    if (!event.down or event.repeat) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (isKeymodPressed(event.mod, sdl.Keymod.alt) or isKeymodPressed(event.mod, sdl.Keymod.shift)) return false;
    const copy = event.scancode == .c or event.key == .c;
    const cut = event.scancode == .x or event.key == .x;
    if (!copy and !cut) return false;
    state.copyBrowserFocusedSelection(cut);
    return true;
}

fn browserMouseMotionEvent(event: *const sdl.MouseMotionEvent) browser_runtime.MouseEvent {
    return .{
        .x = event.x,
        .y = event.y,
    };
}

fn browserMouseButtonEvent(event: *const sdl.MouseButtonEvent) browser_runtime.MouseEvent {
    return .{
        .x = event.x,
        .y = event.y,
        .button = switch (event.button) {
            1 => .left,
            2 => .middle,
            3 => .right,
            4 => .back,
            5 => .forward,
            else => null,
        },
        .pressed = event.down,
    };
}

fn browserMouseWheelEvent(event: *const sdl.MouseWheelEvent) browser_runtime.MouseEvent {
    return .{
        .x = event.mouse_x,
        .y = event.mouse_y,
        .wheel_x = event.x,
        .wheel_y = event.y,
    };
}

fn browserKeyCodeForEvent(event: *const sdl.KeyboardEvent) ?u32 {
    return switch (event.key) {
        .@"return", .kp_enter => 0xff0d,
        .backspace, .kp_backspace => 0xff08,
        .tab, .kp_tab => 0xff09,
        .escape => 0xff1b,
        .delete => 0xffff,
        .home => 0xff50,
        .left => 0xff51,
        .up => 0xff52,
        .right => 0xff53,
        .down => 0xff54,
        .pageup => 0xff55,
        .pagedown => 0xff56,
        .end => 0xff57,
        else => {
            // Chromium expects raw key down/up around printable text input, while SDL's
            // text_input event still carries the actual composed UTF-8 characters.
            const key_code = @intFromEnum(event.key);
            if (key_code > 0 and key_code <= 0x7f) return key_code;
            const modifiers = keymodBits(event.mod);
            if ((modifiers & (sdl.Keymod.ctrl | sdl.Keymod.alt | sdl.Keymod.gui)) == 0) return null;
            return key_code;
        },
    };
}

fn isKeymodPressed(modifier_state: sdl.Keymod, flag: u16) bool {
    return (keymodBits(modifier_state) & flag) != 0;
}

fn keymodBits(modifier_state: sdl.Keymod) u16 {
    return @as(*const u16, @ptrCast(&modifier_state)).*;
}

fn shouldPasteClipboardImage(state: *const AppState, event: *const sdl.KeyboardEvent) bool {
    if (state.isBrowserPaneFocused() or state.browser_address_focused or state.palette_modal_text_focus != .none) return false;
    if (state.terminal_focused) return false;
    if (!event.down or event.repeat) return false;
    if (event.scancode != .v and event.key != .v) return false;
    return isPrimaryModifierPressed(event.mod);
}

fn terminalOwnedShortcut(event: *const sdl.KeyboardEvent) bool {
    if (!event.down) return false;
    const ctrl = isKeymodPressed(event.mod, sdl.Keymod.ctrl);
    const shift = isKeymodPressed(event.mod, sdl.Keymod.shift);
    if (!shift or isKeymodPressed(event.mod, sdl.Keymod.alt) or isKeymodPressed(event.mod, sdl.Keymod.gui)) return false;
    return switch (event.scancode) {
        .c, .v, .pageup, .pagedown => ctrl or event.scancode == .pageup or event.scancode == .pagedown,
        .up, .down, .home, .end => ctrl,
        else => false,
    };
}

fn logPasteShortcutEvent(state: *const AppState, event: *const sdl.KeyboardEvent, matched: bool) void {
    if (event.scancode != .v and event.key != .v) return;
    const mod_bits = keymodBits(event.mod);
    runtime_log.diagnostic(
        "paste key event key={s} scancode={s} down={} repeat={} mod=0x{x} matched={} composer_focused={} palette_composer_focused={} browser_focused={} address_focused={} modal_focus={s}",
        .{
            @tagName(event.key),
            @tagName(event.scancode),
            event.down,
            event.repeat,
            mod_bits,
            matched,
            state.composer_focused,
            state.palette_composer.focused,
            state.isBrowserPaneFocused(),
            state.browser_address_focused,
            @tagName(state.palette_modal_text_focus),
        },
    );
}

fn handleFileSearchNavigation(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (!state.composer_focused) return false;
    if (!state.hasActiveFileSearch()) return false;
    if (!event.down or event.repeat) return false;

    if (event.scancode == .up or (event.scancode == .p and isCtrlPressed())) {
        return state.moveFileSearchSelection(-1);
    }
    if (event.scancode == .down or (event.scancode == .n and isCtrlPressed())) {
        return state.moveFileSearchSelection(1);
    }
    return false;
}

fn handlePendingThreadFollowupShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (!state.composer_focused) return false;
    if (!state.hasPendingStream()) return false;
    if (!event.down or event.repeat) return false;
    if (event.scancode != .tab) return false;
    if (isKeymodPressed(event.mod, sdl.Keymod.ctrl) or
        isKeymodPressed(event.mod, sdl.Keymod.alt) or
        isKeymodPressed(event.mod, sdl.Keymod.gui) or
        isKeymodPressed(event.mod, sdl.Keymod.shift))
    {
        return false;
    }

    state.queueOrSteerDraftDuringSend();
    return true;
}

fn handleWorkspaceContextMenuShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (event.scancode != .application and
        !(event.scancode == .f10 and isKeymodPressed(event.mod, sdl.Keymod.shift)))
    {
        return false;
    }
    if (isKeymodPressed(event.mod, sdl.Keymod.ctrl) or
        isKeymodPressed(event.mod, sdl.Keymod.alt) or
        isKeymodPressed(event.mod, sdl.Keymod.gui))
    {
        return false;
    }
    return workspace_panes_ui.openFocusedChatPaneContextMenu(state);
}

fn handleComposerFocusShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (state.composer_focused) return false;
    if (!state.isTranscriptFocused()) return false;
    if (!event.down or event.repeat) return false;
    if (event.scancode != .tab) return false;
    if (isKeymodPressed(event.mod, sdl.Keymod.ctrl) or
        isKeymodPressed(event.mod, sdl.Keymod.alt) or
        isKeymodPressed(event.mod, sdl.Keymod.gui) or
        isKeymodPressed(event.mod, sdl.Keymod.shift))
    {
        return false;
    }

    state.requestComposerFocus();
    return true;
}

fn handleTranscriptMarkdownSelectAllShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (!event.down or event.repeat) return false;
    const key_is_a = event.key == .a or event.scancode == .a;
    if (!key_is_a) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (state.composer_focused) return false;
    if (state.terminal_focused) return false;
    if (state.isBrowserPaneFocused()) return false;
    const over_transcript = state.palette_mouse_in_workspace and
        chat_panel_ui.pointerOverTranscript(state.palette_mouse_x, state.palette_mouse_y);
    if (!state.transcript_focused and !state.transcriptMarkdownSelectionActive() and !over_transcript) {
        return false;
    }
    if (!chat_panel_ui.selectAllTranscriptMarkdownInThread(state)) return false;
    state.markDirty();
    return true;
}

fn handleTranscriptMarkdownCopyShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (!event.down or event.repeat) return false;
    if (event.key != .c) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    if (state.composer_focused) return false;
    if (state.terminal_focused) return false;
    if (state.isBrowserPaneFocused()) return false;
    if (!state.transcriptMarkdownSelectionActive()) return false;

    const maybe = chat_panel_ui.transcriptMarkdownSelectionPlainText(state) catch return false;
    const plain = maybe orelse return false;
    defer state.allocator.free(plain);
    const z = state.allocator.dupeZ(u8, plain) catch return false;
    defer state.allocator.free(z);
    sdl.setClipboardText(z) catch |err| {
        log.warn("failed to set transcript markdown selection clipboard: {s}", .{@errorName(err)});
        return true;
    };
    state.markDirty();
    return true;
}

fn isCtrlPressed() bool {
    const keyboard_state = sdl.getKeyboardState();
    return keyboard_state[@intFromEnum(sdl.Scancode.lctrl)] or keyboard_state[@intFromEnum(sdl.Scancode.rctrl)];
}

fn isPrimaryModifierPressed(modifier_state: sdl.Keymod) bool {
    if (builtin.os.tag != .macos) {
        return isCtrlPressed() or isKeymodPressed(modifier_state, sdl.Keymod.ctrl);
    }

    return isKeymodPressed(modifier_state, sdl.Keymod.gui);
}

fn handleKeyboardAction(
    state: *AppState,
    keyboard: *keybinds.NativeKeyboardConfig,
    action: keybinds.NativeKeyboardAction,
) void {
    switch (action) {
        .refresh => reloadApplication(state, keyboard),
        .open_default => state.runDefaultOpenAction(),
        .new_thread => state.createThreadForProject(state.selected_project_index),
        .toggle_sidebar => state.toggleSidebarCollapsed(),
        .toggle_sidebar_hidden => state.toggleSidebarHidden(),
        .toggle_browser => state.toggleBrowser(),
        .toggle_terminal => state.toggleCurrentProjectTerminal(),
        .chat_up => if (canHandleTranscriptScrollAction(state)) {
            state.requestTranscriptLineScroll(-1);
        },
        .chat_down => if (canHandleTranscriptScrollAction(state)) {
            state.requestTranscriptLineScroll(1);
        },
        .chat_page_up => if (canHandleTranscriptScrollAction(state)) {
            state.requestTranscriptPageScroll(-1);
        },
        .chat_page_down => if (canHandleTranscriptScrollAction(state)) {
            state.requestTranscriptPageScroll(1);
        },
        .workspace_split_chat_vertical => _ = state.splitFocusedWorkspacePaneWithChatAxis(.vertical),
        .workspace_split_chat_horizontal => _ = state.splitFocusedWorkspacePaneWithChatAxis(.horizontal),
        .workspace_split_terminal_vertical => _ = state.splitFocusedWorkspacePaneWithTerminalAxis(.vertical),
        .workspace_split_terminal_horizontal => _ = state.splitFocusedWorkspacePaneWithTerminalAxis(.horizontal),
        .workspace_toggle_maximize => _ = state.toggleFocusedWorkspacePaneMaximized(),
        .workspace_minimize => _ = state.minimizeFocusedWorkspacePane(),
        .workspace_close => _ = state.closeFocusedWorkspacePane(),
        .workspace_focus_left => _ = workspace_panes_ui.focusPaneInDirection(state, .left),
        .workspace_focus_right => _ = workspace_panes_ui.focusPaneInDirection(state, .right),
        .workspace_focus_up => _ = workspace_panes_ui.focusPaneInDirection(state, .up),
        .workspace_focus_down => _ = workspace_panes_ui.focusPaneInDirection(state, .down),
        .workspace_grow_left => _ = workspace_panes_ui.growPaneInDirection(state, .left),
        .workspace_grow_right => _ = workspace_panes_ui.growPaneInDirection(state, .right),
        .workspace_grow_up => _ = workspace_panes_ui.growPaneInDirection(state, .up),
        .workspace_grow_down => _ = workspace_panes_ui.growPaneInDirection(state, .down),
    }
}

fn isWorkspacePaneAction(action: keybinds.NativeKeyboardAction) bool {
    return switch (action) {
        .workspace_focus_left,
        .workspace_focus_right,
        .workspace_focus_up,
        .workspace_focus_down,
        .workspace_grow_left,
        .workspace_grow_right,
        .workspace_grow_up,
        .workspace_grow_down,
        .workspace_split_chat_vertical,
        .workspace_split_chat_horizontal,
        .workspace_split_terminal_vertical,
        .workspace_split_terminal_horizontal,
        .workspace_toggle_maximize,
        .workspace_minimize,
        .workspace_close,
        => true,
        else => false,
    };
}

extern fn SDL_HideWindow(window: *sdl.Window) bool;
extern fn verde_macos_host_window_install_close_monitor(ns_window: ?*anyopaque) void;
extern fn verde_macos_host_window_order_out(ns_window: ?*anyopaque) void;
extern fn verde_macos_host_window_should_close(ns_window: ?*anyopaque) bool;

fn handleWindowCloseRequested(window: *sdl.Window, state: *AppState) bool {
    if (builtin.os.tag == .macos) {
        const now_ms = currentTimeMillis();
        if (macos_cmd_w_pane_close_until_ms >= now_ms) {
            macos_cmd_w_pane_close_until_ms = 0;
            return true;
        }
        if (isKeymodPressed(SDL_GetModState(), sdl.Keymod.gui)) {
            _ = state.closeFocusedWorkspacePane();
            return true;
        }
        if (macos_launch_close_suppress_until_ms >= now_ms) {
            macos_launch_close_suppress_until_ms = 0;
            runtime_log.diagnostic("ignoring window close request during macOS launch grace", .{});
            return true;
        }
        if (!verde_macos_host_window_should_close(nativeBrowserHostWindow(window))) {
            runtime_log.diagnostic("ignoring unsolicited macOS window close request", .{});
            return true;
        }
    }
    if (builtin.os.tag == .macos) {
        _ = state.browser_state.controller.hide() catch {};
        verde_macos_host_window_order_out(nativeBrowserHostWindow(window));
        _ = SDL_HideWindow(window);
    }
    if (builtin.os.tag == .linux) {
        const window_flags = SDL_GetWindowFlags(window);
        if (!window_flags.input_focus or !window_flags.mouse_focus or window_flags.hidden or window_flags.minimized or window_flags.occluded) {
            runtime_log.diagnostic(
                "ignoring linux window close request focus={} mouse_focus={} hidden={} minimized={} occluded={}",
                .{ window_flags.input_focus, window_flags.mouse_focus, window_flags.hidden, window_flags.minimized, window_flags.occluded },
            );
            return true;
        }
    }
    return false;
}

fn macosHostWindowRequestedClose(window: *sdl.Window, state: *AppState) bool {
    if (builtin.os.tag != .macos) return false;
    const host_window = nativeBrowserHostWindow(window);
    if (!verde_macos_host_window_should_close(host_window)) return false;
    _ = state.browser_state.controller.hide() catch {};
    verde_macos_host_window_order_out(host_window);
    _ = SDL_HideWindow(window);
    runtime_log.diagnostic("shutdown requested by macOS close button monitor", .{});
    return true;
}

fn noteMacosWorkspaceCloseShortcut(event: *const sdl.KeyboardEvent, action: keybinds.NativeKeyboardAction) void {
    if (builtin.os.tag != .macos or action != .workspace_close) return;
    if (event.key != .w) return;
    if (!isKeymodPressed(event.mod, sdl.Keymod.gui)) return;
    if (isKeymodPressed(event.mod, sdl.Keymod.ctrl) or
        isKeymodPressed(event.mod, sdl.Keymod.alt) or
        isKeymodPressed(event.mod, sdl.Keymod.shift))
    {
        return;
    }
    macos_cmd_w_pane_close_until_ms = currentTimeMillis() + MACOS_CMD_W_CLOSE_SUPPRESS_MS;
}

fn currentTimeMillis() i64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    return (@as(i64, @intCast(tv.sec)) * std.time.ms_per_s) + @divTrunc(@as(i64, @intCast(tv.usec)), std.time.us_per_ms);
}

fn activateMacosHostWindow(window: *sdl.Window) void {
    if (builtin.os.tag != .macos) return;
    _ = SDL_SetWindowFocusable(window, true);
    _ = SDL_ShowWindow(window);
    _ = SDL_RaiseWindow(window);
    _ = SDL_SyncWindow(window);
}

fn suppressDuplicateMacosTextInput(text: []const u8, timestamp_ns: u64) bool {
    if (builtin.os.tag != .macos) return false;
    const previous = macos_last_text_input[0..macos_last_text_input_len];
    const duplicate = text.len == previous.len and
        timestamp_ns != 0 and
        macos_last_text_input_timestamp_ns != 0 and
        timestamp_ns >= macos_last_text_input_timestamp_ns and
        timestamp_ns - macos_last_text_input_timestamp_ns <= MACOS_DUPLICATE_TEXT_INPUT_SUPPRESS_NS and
        std.mem.eql(u8, text, previous);

    macos_last_text_input_timestamp_ns = timestamp_ns;
    macos_last_text_input_len = @min(text.len, macos_last_text_input.len);
    @memcpy(macos_last_text_input[0..macos_last_text_input_len], text[0..macos_last_text_input_len]);

    if (duplicate) {
        runtime_log.diagnostic("suppressed duplicate macOS text_input text=\"{s}\" timestamp={}", .{ text, timestamp_ns });
    }
    return duplicate;
}

fn macosNativeBrowserShouldOwnKeyboard(state: *AppState) bool {
    if (builtin.os.tag != .macos) return false;
    if (!state.isBrowserVisible() or !state.isBrowserPaneFocused()) return false;
    if (!state.browserPaneUsesNativeKeyboardSurface()) return false;
    if (state.palette_composer.focused or state.composer_focused) return false;
    if (state.browser_address_focused or state.palette_modal_text_focus != .none) return false;
    return true;
}

fn macosBrowserClickWillFocusNativeSurface(state: *const AppState, x: f32, y: f32) bool {
    if (builtin.os.tag != .macos) return false;
    if (!state.isBrowserVisible()) return false;
    if (!state.browserPaneUsesNativeKeyboardSurface()) return false;
    if (state.palette_modal_text_focus != .none) return false;
    return state.browserPaneContains(x, y);
}

fn handleFontSizeShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (!event.down or event.repeat) return false;
    if (state.terminal_focused) return false;
    if (!isPrimaryModifierPressed(event.mod)) return false;
    const delta: f32 = switch (event.key) {
        .plus, .kp_plus, .equals => 1.0,
        .minus, .kp_minus => -1.0,
        else => return false,
    };
    const current = state.app_config.font_size;
    const next = clampf(current + delta, 11.0, 24.0);
    if (@abs(next - current) < 0.01) return true;
    state.app_config.font_size = next;
    ui_theme.installFonts(
        CAL_SANS_BYTES[0..CAL_SANS_BYTES.len],
        NOTO_SANS_BOLD_BYTES[0..NOTO_SANS_BOLD_BYTES.len],
        NOTO_SANS_ITALIC_BYTES[0..NOTO_SANS_ITALIC_BYTES.len],
        NOTO_SANS_BOLD_ITALIC_BYTES[0..NOTO_SANS_BOLD_ITALIC_BYTES.len],
        CODICON_BYTES[0..CODICON_BYTES.len],
        NERD_SYMBOLS_BYTES[0..NERD_SYMBOLS_BYTES.len],
        next,
    );
    state.markDirty();
    return true;
}

fn canHandleTranscriptScrollAction(state: *const AppState) bool {
    if (state.projects.items.len == 0) return false;
    if (state.isBrowserPaneFocused()) return false;
    if (state.terminal_focused) return false;
    return !state.composer_focused and state.palette_modal_text_focus == .none;
}

fn reloadApplication(state: *AppState, keyboard: *keybinds.NativeKeyboardConfig) void {
    state.reloadFromStorage() catch |err| {
        log.err("failed to refresh native app state: {s}", .{@errorName(err)});
        state.setSidebarNotice("Refresh failed.");
        return;
    };

    const next_keyboard = keybinds.NativeKeyboardConfig.load(state.allocator) catch |err| {
        log.err("failed to refresh native keybinds: {s}", .{@errorName(err)});
        state.setSidebarNotice("App refreshed, but keybinds failed to reload.");
        return;
    };
    const next_app_config = app_config.loadAppConfig(state.allocator) catch |err| {
        log.err("failed to refresh native app config: {s}", .{@errorName(err)});
        keyboard.deinit();
        keyboard.* = next_keyboard;
        state.setSidebarNotice("App refreshed, but config failed to reload.");
        return;
    };
    keyboard.deinit();
    keyboard.* = next_keyboard;
    state.replaceAppConfig(next_app_config);
    state.setSidebarNotice("App, config, and keybinds refreshed.");
}

test {
    _ = @import("providers/claude.zig");
}
