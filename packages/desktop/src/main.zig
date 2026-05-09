//! Minimal native shell prototype for the desktop chat workflow.

const std = @import("std");
const builtin = @import("builtin");

const sdl = @import("zsdl3");

const app_config = @import("config.zig");
const browser_runtime = @import("browser/mod.zig");
const chat_threads = @import("chat/threads.zig");
const keybinds = @import("keybinds.zig");
const profiler = @import("profiler.zig");
const runtime_log = @import("runtime_log.zig");
const stb_image = @import("stb_image.zig");
const utils = @import("utils.zig");
const ui_layout = @import("ui/layout.zig");
const sidebar_ui = @import("ui/sidebar.zig");
const chat_panel_ui = @import("ui/chat_panel.zig");
const browser_ui = @import("ui/browser.zig");
const debug_ui = @import("ui/debug.zig");
const palette_gl_renderer = @import("ui/palette_gl_renderer.zig");
const ui_theme = @import("ui/theme.zig");
const colors = @import("ui/colors.zig");

const native_state = @import("state.zig");
const AppState = native_state.AppState;
const Storage = native_state.Storage;

const log = native_state.log;

extern fn SDL_GetWindowSizeInPixels(window: *sdl.Window, w: ?*c_int, h: ?*c_int) bool;
extern fn SDL_WaitEventTimeout(event: *sdl.Event, timeout_ms: c_int) bool;
extern fn SDL_TextInputActive(window: *sdl.Window) bool;

pub const std_options: std.Options = .{
    .enable_segfault_handler = true,
    .logFn = runtime_log.logFn,
};

pub const panic = std.debug.FullPanic(runtime_log.panicFn);

const GL_COLOR_BUFFER_BIT: u32 = 0x0000_4000;
const GL_MULTISAMPLE: u32 = 0x809D;

const DEFAULT_FONT_SIZE: f32 = ui_theme.DEFAULT_FONT_SIZE;
const DEFAULT_WINDOW_WIDTH: c_int = 1360;
const DEFAULT_WINDOW_HEIGHT: c_int = 860;
const MIN_WINDOW_WIDTH: c_int = 960;
const MIN_WINDOW_HEIGHT: c_int = 680;
const MAX_WINDOW_WIDTH: c_int = 1520;
const MAX_WINDOW_HEIGHT: c_int = 980;
const ACTIVE_WAIT_TIMEOUT_MS: c_int = 16;
const IDLE_WAIT_TIMEOUT_MS: c_int = 50;

const CAL_SANS_BYTES = @embedFile("assets/fonts/CalSans-Regular.ttf");
const NOTO_SANS_BOLD_BYTES = @embedFile("assets/fonts/NotoSans-Bold.ttf");
const NOTO_SANS_ITALIC_BYTES = @embedFile("assets/fonts/NotoSans-Italic.ttf");
const NOTO_SANS_BOLD_ITALIC_BYTES = @embedFile("assets/fonts/NotoSans-BoldItalic.ttf");
const CODICON_BYTES = @embedFile("assets/fonts/Codicon.ttf");
const NERD_SYMBOLS_BYTES = @embedFile("assets/fonts/SymbolsNerdFontMono-Regular.ttf");

extern fn glClearColor(red: f32, green: f32, blue: f32, alpha: f32) void;
extern fn glClear(mask: u32) void;
extern fn glViewport(x: c_int, y: c_int, width: c_int, height: c_int) void;
extern fn glEnable(cap: u32) void;

const WindowFrame = struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (builtin.mode == .Debug) _ = debug_allocator.deinit();
    }
    const allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

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

    try sdl.gl.setAttribute(.context_major_version, 3);
    try sdl.gl.setAttribute(.context_minor_version, 3);
    try sdl.gl.setAttribute(.doublebuffer, 1);
    // Default framebuffer MSAA: smooths vector edges (composer send/stop, rounded UI).
    try sdl.gl.setAttribute(.multisamplebuffers, 1);
    try sdl.gl.setAttribute(.multisamplesamples, 4);
    switch (@import("builtin").os.tag) {
        .macos => try sdl.gl.setAttribute(.context_profile_mask, @intFromEnum(sdl.gl.Profile.core)),
        else => {},
    }

    const initial_window_frame = initialWindowFrame();
    const window = try sdl.Window.create(
        "verde",
        initial_window_frame.w,
        initial_window_frame.h,
        .{
            .resizable = true,
            .high_pixel_density = true,
            .opengl = true,
        },
    );
    defer window.destroy();
    window.setPosition(initial_window_frame.x, initial_window_frame.y) catch {};
    sdl.startTextInput(window) catch {};
    defer sdl.stopTextInput(window) catch {};
    installWindowIcon(window);

    const gl_context = try sdl.gl.createContext(window);
    defer sdl.gl.destroyContext(gl_context);
    try sdl.gl.makeCurrent(window, gl_context);
    glEnable(GL_MULTISAMPLE);
    try sdl.gl.setSwapInterval(1);

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
    var palette_renderer = palette_gl_renderer.Renderer.init();
    defer palette_renderer.deinit(allocator);

    var ui_scale = currentWindowDisplayScale(window);
    // Apply the global ImGui style after the display scale is known.
    ui_theme.applyTheme(ui_scale);

    var state = try AppState.init(allocator, &storage, loaded_app_config);
    defer state.deinit();
    state.openBrowserOnLaunchIfRequested();
    state.startOpencodeModelOptionsRefresh();
    var keyboard = try keybinds.NativeKeyboardConfig.load(allocator);
    defer keyboard.deinit();

    log.info("verde main loop starting", .{});
    defer log.info("verde main loop exiting", .{});

    var running = true;
    var needs_render = true;
    var last_framebuffer_width: c_int = 0;
    var last_framebuffer_height: c_int = 0;
    while (running) {
        var frame_sample = profiler.FrameSample{};
        syncWindowTextInput(window, &state);
        var had_event = false;
        var event_wait_ns: u64 = 0;
        var input_fb_w: c_int = 0;
        var input_fb_h: c_int = 0;
        getWindowSizeInPixels(window, &input_fb_w, &input_fb_h);
        ui_layout.refreshPaletteModalHits(&state, @floatFromInt(input_fb_w), @floatFromInt(input_fb_h));
        running = processEvents(window, &state, &keyboard, ui_scale, &had_event, &frame_sample, &event_wait_ns);
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
            }
        }.run, .{&state});
        recordSpan(&frame_sample, .poll_send, struct {
            fn run(app_state: *AppState) void {
                app_state.pollSend();
            }
        }.run, .{&state});
        recordSpan(&frame_sample, .poll_browser, struct {
            fn run(app_state: *AppState) void {
                app_state.pollBrowser();
            }
        }.run, .{&state});
        recordSpan(&frame_sample, .poll_terminals, struct {
            fn run(app_state: *AppState) void {
                app_state.pollTerminals();
            }
        }.run, .{&state});

        var observed_fb_width: c_int = 0;
        var observed_fb_height: c_int = 0;
        getWindowSizeInPixels(window, &observed_fb_width, &observed_fb_height);
        const framebuffer_size_changed = observed_fb_width != last_framebuffer_width or observed_fb_height != last_framebuffer_height;
        if (framebuffer_size_changed) {
            last_framebuffer_width = observed_fb_width;
            last_framebuffer_height = observed_fb_height;
        }

        needs_render = needs_render or had_event or framebuffer_size_changed or appNeedsContinuousFrames(&state);
        if (!needs_render) {
            profiler.recordFrame(frame_sample);
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
                glViewport(0, 0, framebuffer_width.*, framebuffer_height.*);
            }
        }.run, .{ window, &fb_width, &fb_height, &ui_scale });
        state.palette_overlay_batch.clear();
        state.palette_frame_text.clearRetainingCapacity();

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

        glClearColor(ui_theme.COLOR_BLACK[0], ui_theme.COLOR_BLACK[1], ui_theme.COLOR_BLACK[2], 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
        recordSpan(&frame_sample, .draw_backend, struct {
            fn run(
                palette_command_renderer: *palette_gl_renderer.Renderer,
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
        try sdl.gl.swapWindow(window);
        frame_sample.add(.swap_window, profiler.elapsedNs(swap_start));
        frame_sample.rendered = true;
        profiler.recordFrame(frame_sample);
    }
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
    had_event: *bool,
    frame_sample: *profiler.FrameSample,
    waited_ns: *u64,
) bool {
    had_event.* = false;
    var event: sdl.Event = undefined;

    if (!sdl.pollEvent(&event)) {
        const wait_start = profiler.nowNs();
        if (!SDL_WaitEventTimeout(&event, eventWaitTimeoutMs(state))) {
            waited_ns.* +|= profiler.elapsedNs(wait_start);
            return true;
        }
        waited_ns.* +|= profiler.elapsedNs(wait_start);
        had_event.* = true;
        if (!processOneEvent(window, state, keyboard, ui_scale, &event, frame_sample)) return false;
    } else {
        had_event.* = true;
        if (!processOneEvent(window, state, keyboard, ui_scale, &event, frame_sample)) return false;
    }

    while (sdl.pollEvent(&event)) {
        had_event.* = true;
        if (!processOneEvent(window, state, keyboard, ui_scale, &event, frame_sample)) return false;
    }

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
    frame_sample.add(.event_handling, profiler.elapsedNs(start));
    return keep_running;
}

fn appNeedsContinuousFrames(state: *AppState) bool {
    return state.hasAnyPendingSends() or
        state.isPickerPending() or
        state.isBrowserVisible() or
        state.hasVisibleTerminalSessions() or
        state.transcriptMarkdownSelectionDragging() or
        state.transcriptScrollAnimating();
}

fn eventWaitTimeoutMs(state: *AppState) c_int {
    return if (state.hasAnyPendingSends() or state.isPickerPending() or state.isBrowserVisible() or state.hasVisibleTerminalSessions() or state.transcriptMarkdownSelectionDragging() or state.transcriptScrollAnimating())
        ACTIVE_WAIT_TIMEOUT_MS
    else
        IDLE_WAIT_TIMEOUT_MS;
}

fn handleEvent(window: *sdl.Window, state: *AppState, keyboard: *keybinds.NativeKeyboardConfig, ui_scale: f32, event: *sdl.Event) bool {
    switch (event.type) {
        .quit => return false,
        .key_down => {
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input sdl key_down key=0x{x} scancode={} focused={} visible={}",
                    .{ @intFromEnum(event.key.key), @intFromEnum(event.key.scancode), state.isBrowserPaneFocused(), state.isBrowserVisible() },
                );
            }
            const action = keyboard.actionForEvent(&event.key);
            const paste_shortcut = shouldPasteClipboardImage(state, &event.key);
            logPasteShortcutEvent(state, &event.key, paste_shortcut);
            if (paste_shortcut) {
                if (state.attachClipboardImageToCurrentDraft()) return true;
                if (state.pasteClipboardTextIntoPaletteComposer()) return true;
            }
            if (ui_layout.handlePaletteKeyDown(state, &event.key)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (handleFontSizeShortcut(state, &event.key)) {
                return true;
            }
            if (action == .toggle_terminal or action == .toggle_browser or action == .toggle_sidebar or action == .new_thread) {
                handleKeyboardAction(state, keyboard, action.?);
                return true;
            }
            if (browser_ui.handlePaletteKeyDown(state, &event.key)) {
                syncWindowTextInput(window, state);
                return true;
            }
            if (handleBrowserKeyboardEvent(state, &event.key)) {
                return true;
            }
            const terminal_key_handled = state.handleTerminalKeyDown(keyboard, &event.key);
            state.noteTerminalKeyRouting(&event.key, terminal_key_handled);
            if (terminal_key_handled) {
                return true;
            }
            if (handleFileSearchNavigation(state, &event.key)) {
                return true;
            }
            if (handlePendingThreadFollowupShortcut(state, &event.key)) {
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
            if (state.routePaletteComposerKeyDown(&event.key)) {
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
            if (handleBrowserKeyboardEvent(state, &event.key)) {
                return true;
            }
        },
        .text_input => {
            const text_input = std.mem.sliceTo(event.text.text, 0);
            if (browserInputDebugEnabled()) {
                log.info(
                    "browser-input sdl text_input text=\"{s}\" focused={} visible={}",
                    .{ text_input, state.isBrowserPaneFocused(), state.isBrowserVisible() },
                );
            }
            if (ui_layout.handlePaletteTextInput(state, text_input)) {
                syncWindowTextInput(window, state);
                return true;
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
            if (state.routePaletteComposerTextInput(text_input)) {
                return true;
            }
        },
        .mouse_motion => {
            state.notePaletteWorkspaceMouseMotion(event.motion.x, event.motion.y);
            ui_layout.updateThreadImportModalHover(state, event.motion.x, event.motion.y);
            chat_panel_ui.handleTranscriptPaletteMouseMotion(state);
            browser_ui.handlePaletteMouseMotion(event.motion.x, event.motion.y);
            sidebar_ui.handlePaletteMouseMotion(state, event.motion.x, event.motion.y);
            if (state.routePaletteComposerMouseMotion(&event.motion, ui_scale)) {
                return true;
            }
            _ = state.handleBrowserMouse(browserMouseMotionEvent(&event.motion));
        },
        .mouse_button_down, .mouse_button_up => {
            if (event.button.button == 1 and ui_layout.handlePaletteMouseButton(state, event.button.x, event.button.y, event.button.down)) {
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
            if (event.button.button == 1 and browser_ui.handlePaletteMouseButton(state, event.button.x, event.button.y, event.button.down)) {
                syncWindowTextInput(window, state);
                return true;
            }
            const handled = state.handleBrowserMouse(browserMouseButtonEvent(&event.button));
            if (!handled and event.button.down) {
                state.unfocusBrowserPane();
            }
            if (handled) {
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
    if (!state.isBrowserPaneFocused() and !state.palette_composer.focused and !state.browser_address_focused and state.palette_modal_text_focus == .none) return;
    if (SDL_TextInputActive(window)) return;
    sdl.startTextInput(window) catch {};
    if (browserInputDebugEnabled()) {
        log.info("browser-input forced SDL_StartTextInput for browser pane focus", .{});
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
    if (!event.down or event.repeat) return false;
    if (event.scancode != .v and event.key != .v) return false;
    return isPrimaryModifierPressed(event.mod);
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
    }
}

fn handleFontSizeShortcut(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (!event.down or event.repeat) return false;
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
