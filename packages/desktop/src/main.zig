//! Minimal native shell prototype for the desktop chat workflow.

const std = @import("std");

const sdl = @import("zsdl3");
const zgui = @import("zgui");

const app_config = @import("config.zig");
const browser_runtime = @import("browser/mod.zig");
const chat_threads = @import("chat/threads.zig");
const keybinds = @import("keybinds.zig");
const runtime_log = @import("runtime_log.zig");
const stb_image = @import("stb_image.zig");
const utils = @import("utils.zig");
const ui_layout = @import("ui/layout.zig");
const ui_theme = @import("ui/theme.zig");
const colors = @import("ui/colors.zig");

const native_state = @import("state.zig");
const AppState = native_state.AppState;
const Storage = native_state.Storage;

const log = native_state.log;

pub const std_options: std.Options = .{
    .enable_segfault_handler = true,
};

pub const panic = std.debug.FullPanic(runtime_log.panicFn);

const GL_COLOR_BUFFER_BIT: u32 = 0x0000_4000;

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

const WindowFrame = struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    try sdl.setAppMetadata("verde Native", "0.0.0", "com.verde.native");
    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit();

    var storage = try Storage.init(allocator);
    defer storage.deinit();
    runtime_log.init(storage.pref_path) catch |err| {
        log.warn("failed to initialize runtime logging: {s}", .{@errorName(err)});
    };
    if (runtime_log.stderrLogPath()) |path| {
        log.info("runtime stderr redirected to {s}", .{path});
    }

    try sdl.gl.setAttribute(.context_major_version, 3);
    try sdl.gl.setAttribute(.context_minor_version, 3);
    try sdl.gl.setAttribute(.doublebuffer, 1);
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
    try sdl.gl.setSwapInterval(1);

    const loaded_app_config = app_config.loadAppConfig(allocator) catch |err| blk: {
        log.warn("failed to load app config: {s}", .{@errorName(err)});
        break :blk app_config.AppConfig{ .font_size = DEFAULT_FONT_SIZE };
    };

    //NOTE: Initialize the core ImGui/zgui context and allocate its global state.
    zgui.init(allocator);
    defer zgui.deinit();
    // Install the font atlas used by the desktop UI before the backend starts rendering.
    ui_theme.installFonts(
        CAL_SANS_BYTES[0..CAL_SANS_BYTES.len],
        NOTO_SANS_BOLD_BYTES[0..NOTO_SANS_BOLD_BYTES.len],
        NOTO_SANS_ITALIC_BYTES[0..NOTO_SANS_ITALIC_BYTES.len],
        NOTO_SANS_BOLD_ITALIC_BYTES[0..NOTO_SANS_BOLD_ITALIC_BYTES.len],
        CODICON_BYTES[0..CODICON_BYTES.len],
        NERD_SYMBOLS_BYTES[0..NERD_SYMBOLS_BYTES.len],
        loaded_app_config.font_size,
    );
    // Bind ImGui to the SDL window and OpenGL context so frames can be drawn.
    zgui.backend.init(window, gl_context);
    defer zgui.backend.deinit();

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
    while (running) {
        syncWindowTextInput(window, &state);
        var had_event = false;
        running = processEvents(window, &state, &keyboard, &had_event);
        state.pollPicker();
        state.pollOpencodeModelOptionsCache();
        state.pollSend();
        state.pollBrowser();
        state.pollTerminals();

        needs_render = needs_render or had_event or appNeedsContinuousFrames(&state);
        if (!needs_render) {
            continue;
        }
        needs_render = false;

        var fb_width: c_int = 0;
        var fb_height: c_int = 0;
        getWindowSizeInPixels(window, &fb_width, &fb_height);

        const next_ui_scale = currentWindowDisplayScale(window);
        if (@abs(next_ui_scale - ui_scale) > 0.01) {
            ui_scale = next_ui_scale;
            ui_theme.applyTheme(ui_scale);
        }

        // Begin a fresh ImGui frame for the current framebuffer size.
        zgui.backend.newFrame(@intCast(fb_width), @intCast(fb_height));
        // Render the root application layout for this frame.
        ui_layout.renderRoot(&state, @floatFromInt(fb_width), @floatFromInt(fb_height));
        state.flushIfDirty();

        glClearColor(ui_theme.COLOR_BLACK[0], ui_theme.COLOR_BLACK[1], ui_theme.COLOR_BLACK[2], 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
        zgui.backend.draw();
        try sdl.gl.swapWindow(window);
    }
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
    window.getSizeInPixels(w, h) catch {
        window.getSize(w, h) catch {
            if (w) |width| width.* = DEFAULT_WINDOW_WIDTH;
            if (h) |height| height.* = DEFAULT_WINDOW_HEIGHT;
        };
    };
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

fn processEvents(window: *sdl.Window, state: *AppState, keyboard: *keybinds.NativeKeyboardConfig, had_event: *bool) bool {
    had_event.* = false;
    var event: sdl.Event = undefined;

    if (!sdl.pollEvent(&event)) {
        if (!sdl.waitEventTimeout(&event, eventWaitTimeoutMs(state))) {
            return true;
        }
        had_event.* = true;
        normalizeMouseEventCoordinates(window, &event);
        if (!handleEvent(window, state, keyboard, &event)) return false;
    } else {
        had_event.* = true;
        normalizeMouseEventCoordinates(window, &event);
        if (!handleEvent(window, state, keyboard, &event)) return false;
    }

    while (sdl.pollEvent(&event)) {
        had_event.* = true;
        normalizeMouseEventCoordinates(window, &event);
        if (!handleEvent(window, state, keyboard, &event)) return false;
    }

    return true;
}

fn appNeedsContinuousFrames(state: *AppState) bool {
    return state.hasAnyPendingSends() or
        state.isPickerPending() or
        state.hasVisibleTerminalSessions() or
        state.transcriptMarkdownSelectionDragging();
}

fn eventWaitTimeoutMs(state: *AppState) c_int {
    return if (state.hasAnyPendingSends() or state.isPickerPending() or state.hasVisibleTerminalSessions() or state.transcriptMarkdownSelectionDragging())
        ACTIVE_WAIT_TIMEOUT_MS
    else
        IDLE_WAIT_TIMEOUT_MS;
}

fn handleEvent(window: *sdl.Window, state: *AppState, keyboard: *keybinds.NativeKeyboardConfig, event: *sdl.Event) bool {
    _ = zgui.backend.processEvent(event);
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
            if (action == .toggle_terminal or action == .toggle_browser or action == .toggle_sidebar or action == .new_thread) {
                handleKeyboardAction(state, keyboard, action.?);
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
            if (shouldPasteClipboardImage(state, &event.key)) {
                state.attachClipboardImageToCurrentDraft();
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
            const browser_text_handled = state.handleBrowserKey(.{
                .key_code = 0,
                .text = text_input,
                .pressed = true,
            });
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
            _ = state.handleBrowserMouse(browserMouseMotionEvent(&event.motion));
        },
        .mouse_button_down, .mouse_button_up => {
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
            const handled = state.handleBrowserMouse(browserMouseButtonEvent(&event.button));
            if (!handled and event.button.down) {
                state.unfocusBrowserPane();
            }
            syncWindowTextInput(window, state);
            if (handled) {
                return true;
            }
        },
        .mouse_wheel => {
            if (state.handleBrowserMouse(browserMouseWheelEvent(&event.wheel))) {
                return true;
            }
        },
        else => {},
    }
    return true;
}

fn browserInputDebugEnabled() bool {
    return std.posix.getenv("VERDE_CEF_INPUT_DEBUG") != null;
}

fn syncWindowTextInput(window: *sdl.Window, state: *AppState) void {
    if (!state.isBrowserPaneFocused()) return;
    if (sdl.textInputActive(window)) return;
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
    if (!state.composer_focused) return false;
    if (!event.down or event.repeat) return false;
    if (event.scancode != .v) return false;
    return isCtrlPressed();
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

fn isCtrlPressed() bool {
    const keyboard_state = sdl.getKeyboardState();
    return keyboard_state[@intFromEnum(sdl.Scancode.lctrl)] or keyboard_state[@intFromEnum(sdl.Scancode.rctrl)];
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

fn canHandleTranscriptScrollAction(state: *const AppState) bool {
    if (state.projects.items.len == 0) return false;
    if (state.isBrowserPaneFocused()) return false;
    if (state.terminal_focused) return false;
    return !zgui.io.getWantCaptureKeyboard();
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
