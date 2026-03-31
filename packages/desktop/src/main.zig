//! Minimal native shell prototype for the desktop chat workflow.

const std = @import("std");

const sdl = @import("zsdl3");
const zgui = @import("zgui");

const app_config = @import("config.zig");
const chat_threads = @import("chat/threads.zig");
const keybinds = @import("keybinds.zig");
const stb_image = @import("stb_image.zig");
const utils = @import("utils.zig");
const ui_layout = @import("ui/layout.zig");
const ui_theme = @import("ui/theme.zig");
const colors = @import("ui/colors.zig");

const native_state = @import("state.zig");
const AppState = native_state.AppState;
const Storage = native_state.Storage;

const log = native_state.log;

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
const CODICON_BYTES = @embedFile("assets/fonts/Codicon.ttf");
const NERD_SYMBOLS_BYTES = @embedFile("assets/fonts/SymbolsNerdFontMono-Regular.ttf");

extern fn SDL_GetPrimaryDisplay() sdl.DisplayId;
extern fn SDL_CreateSurfaceFrom(
    width: c_int,
    height: c_int,
    format: sdl.PixelFormatEnum,
    pixels: ?*anyopaque,
    pitch: c_int,
) ?*sdl.Surface;
extern fn SDL_SetWindowIcon(window: *sdl.Window, icon: *sdl.Surface) bool;
extern fn SDL_GetDisplayUsableBounds(display_id: sdl.DisplayId, rect: *SdlRect) bool;
extern fn SDL_WaitEventTimeout(event: *sdl.Event, timeoutMS: c_int) bool;
extern fn SDL_GetWindowSizeInPixels(window: *sdl.Window, w: ?*c_int, h: ?*c_int) bool;
extern fn SDL_GetWindowDisplayScale(window: *sdl.Window) f32;
extern fn SDL_SetWindowPosition(window: *sdl.Window, x: c_int, y: c_int) bool;
extern fn SDL_StartTextInput(window: *sdl.Window) bool;
extern fn SDL_StopTextInput(window: *sdl.Window) bool;
extern fn glClearColor(red: f32, green: f32, blue: f32, alpha: f32) void;
extern fn glClear(mask: u32) void;

const SdlRect = extern struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

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
    _ = SDL_SetWindowPosition(window, initial_window_frame.x, initial_window_frame.y);
    _ = SDL_StartTextInput(window);
    defer _ = SDL_StopTextInput(window);
    installWindowIcon(window);

    const gl_context = try sdl.gl.createContext(window);
    defer sdl.gl.destroyContext(gl_context);
    try sdl.gl.makeCurrent(window, gl_context);
    try sdl.gl.setSwapInterval(1);

    const loaded_app_config = app_config.loadAppConfig(allocator) catch |err| blk: {
        log.warn("failed to load app config: {s}", .{@errorName(err)});
        break :blk app_config.AppConfig{ .font_size = DEFAULT_FONT_SIZE };
    };

    // Initialize the core ImGui/zgui context and allocate its global state.
    zgui.init(allocator);
    defer zgui.deinit();
    // Install the font atlas used by the desktop UI before the backend starts rendering.
    ui_theme.installFonts(
        CAL_SANS_BYTES[0..CAL_SANS_BYTES.len],
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
    var keyboard = try keybinds.NativeKeyboardConfig.load(allocator);
    defer keyboard.deinit();

    var running = true;
    while (running) {
        running = processEvents(&state, &keyboard);
        state.pollPicker();
        state.pollSend();
        state.pollTerminals();

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
    const surface = SDL_CreateSurfaceFrom(
        loaded.width,
        loaded.height,
        .abgr8888,
        @ptrCast(loaded.pixels),
        pitch,
    ) orelse {
        log.warn("failed to create SDL surface for window icon", .{});
        return;
    };
    defer surface.destroy();

    if (!SDL_SetWindowIcon(window, surface)) {
        log.warn("failed to set window icon", .{});
    }
}

fn initialWindowFrame() WindowFrame {
    const display_id = SDL_GetPrimaryDisplay();
    if (display_id == .invalid) {
        return .{
            .x = sdl.Window.pos_centered,
            .y = sdl.Window.pos_centered,
            .w = DEFAULT_WINDOW_WIDTH,
            .h = DEFAULT_WINDOW_HEIGHT,
        };
    }

    var usable_bounds: SdlRect = undefined;
    if (!SDL_GetDisplayUsableBounds(display_id, &usable_bounds)) {
        return .{
            .x = sdl.Window.pos_centered,
            .y = sdl.Window.pos_centered,
            .w = DEFAULT_WINDOW_WIDTH,
            .h = DEFAULT_WINDOW_HEIGHT,
        };
    }

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
    const scale = SDL_GetWindowDisplayScale(window);
    if (!std.math.isFinite(scale) or scale <= 0.0) return 1.0;
    return clampf(scale, 1.0, 2.5);
}

fn clampInt(value: c_int, min_value: c_int, max_value: c_int) c_int {
    return @max(min_value, @min(value, max_value));
}

fn clampf(value: f32, min_value: f32, max_value: f32) f32 {
    return @max(min_value, @min(value, max_value));
}

fn processEvents(state: *AppState, keyboard: *keybinds.NativeKeyboardConfig) bool {
    var event: sdl.Event = undefined;

    if (!sdl.pollEvent(&event)) {
        if (!SDL_WaitEventTimeout(&event, eventWaitTimeoutMs(state))) {
            return true;
        }
        if (!handleEvent(state, keyboard, &event)) return false;
    } else {
        if (!handleEvent(state, keyboard, &event)) return false;
    }

    while (sdl.pollEvent(&event)) {
        if (!handleEvent(state, keyboard, &event)) return false;
    }

    return true;
}

fn eventWaitTimeoutMs(state: *AppState) c_int {
    return if (state.hasPendingStream() or state.isPickerPending() or state.hasActiveTerminalSessions())
        ACTIVE_WAIT_TIMEOUT_MS
    else
        IDLE_WAIT_TIMEOUT_MS;
}

fn handleEvent(state: *AppState, keyboard: *keybinds.NativeKeyboardConfig, event: *sdl.Event) bool {
    _ = zgui.backend.processEvent(event);
    switch (event.type) {
        .quit => return false,
        .key_down => {
            const action = keyboard.actionForEvent(&event.key);
            if (action == .toggle_terminal) {
                handleKeyboardAction(state, keyboard, .toggle_terminal);
                return true;
            }
            if (state.handleTerminalKeyDown(&event.key)) {
                return true;
            }
            if (shouldPasteClipboardImage(state, &event.key)) {
                state.attachClipboardImageToCurrentDraft();
                return true;
            }
            if (handleFileSearchNavigation(state, &event.key)) {
                return true;
            }
            if (action) |resolved_action| {
                handleKeyboardAction(state, keyboard, resolved_action);
            }
        },
        .text_input => {
            if (state.handleTerminalTextInput(event.text.text)) {
                return true;
            }
        },
        else => {},
    }
    return true;
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
        .toggle_terminal => state.toggleCurrentProjectTerminal(),
    }
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
