//! Minimal native shell prototype for the desktop chat workflow.

const std = @import("std");

const sdl = @import("zsdl3");
const zgui = @import("zgui");

const app_config = @import("config.zig");
const chat_threads = @import("chat/threads.zig");
const keybinds = @import("keybinds.zig");
const utils = @import("utils.zig");
const ui_layout = @import("ui/layout.zig");
const ui_theme = @import("ui/theme.zig");
const colors = @import("ui/colors.zig");

// Re-export the state-owned types that the generic UI modules expect on `Impl`.
const native_state = @import("state.zig");
const AccessMode = native_state.AccessMode;
pub const AppState = native_state.AppState;
pub const ChatImageAttachment = native_state.ChatImageAttachment;
pub const ChatRole = native_state.ChatRole;
const ChatThread = native_state.ChatThread;
const ModelOption = native_state.ModelOption;
const Provider = native_state.Provider;
const ReasoningOption = native_state.ReasoningOption;
const Storage = native_state.Storage;
const CODEX_MODEL_OPTIONS = native_state.CODEX_MODEL_OPTIONS;
const CODEX_REASONING_OPTIONS = native_state.CODEX_REASONING_OPTIONS;
const OPENCODE_MODEL_OPTIONS = native_state.OPENCODE_MODEL_OPTIONS;

pub const log = native_state.log;
pub const providerLabel = utils.providerLabel;
pub const PERSISTED_DIFF_MARKER = utils.PERSISTED_DIFF_MARKER;
pub const IMAGE_MODAL_ID: [:0]const u8 = native_state.IMAGE_MODAL_ID;
pub const PROJECT_RENAME_MODAL_ID: [:0]const u8 = "ProjectRenameModal";
pub const SIDEBAR_VISIBLE_THREAD_LIMIT: usize = 6;

pub const ChangedFileEntry = struct {
    path: []const u8,
    additions: i64,
    deletions: i64,
    patch: ?[]const u8 = null,
};

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
extern fn SDL_GetDisplayUsableBounds(display_id: sdl.DisplayId, rect: *SdlRect) bool;
extern fn SDL_WaitEventTimeout(event: *sdl.Event, timeoutMS: c_int) bool;
extern fn SDL_GetWindowSizeInPixels(window: *sdl.Window, w: ?*c_int, h: ?*c_int) bool;
extern fn SDL_GetWindowDisplayScale(window: *sdl.Window) f32;
extern fn SDL_SetWindowPosition(window: *sdl.Window, x: c_int, y: c_int) bool;
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

    const gl_context = try sdl.gl.createContext(window);
    defer sdl.gl.destroyContext(gl_context);
    try sdl.gl.makeCurrent(window, gl_context);
    try sdl.gl.setSwapInterval(1);

    const ui_config = app_config.loadAppConfig(allocator) catch |err| blk: {
        log.warn("failed to load app config: {s}", .{@errorName(err)});
        break :blk app_config.AppConfig{ .font_size = DEFAULT_FONT_SIZE };
    };

    zgui.init(allocator);
    defer zgui.deinit();
    ui_theme.installFonts(
        CAL_SANS_BYTES[0..CAL_SANS_BYTES.len],
        CODICON_BYTES[0..CODICON_BYTES.len],
        NERD_SYMBOLS_BYTES[0..NERD_SYMBOLS_BYTES.len],
        ui_config.font_size,
    );
    zgui.backend.init(window, gl_context);
    defer zgui.backend.deinit();

    var ui_scale = currentWindowDisplayScale(window);
    ui_theme.applyTheme(ui_scale);

    var state = try AppState.init(allocator, &storage);
    defer state.deinit();
    var keyboard = try keybinds.NativeKeyboardConfig.load(allocator);
    defer keyboard.deinit();

    var running = true;
    while (running) {
        running = processEvents(&state, &keyboard);
        state.pollPicker();
        state.pollSend();

        var fb_width: c_int = 0;
        var fb_height: c_int = 0;
        getWindowSizeInPixels(window, &fb_width, &fb_height);

        const next_ui_scale = currentWindowDisplayScale(window);
        if (@abs(next_ui_scale - ui_scale) > 0.01) {
            ui_scale = next_ui_scale;
            ui_theme.applyTheme(ui_scale);
        }

        zgui.backend.newFrame(@intCast(fb_width), @intCast(fb_height));
        ui_layout.renderRoot(@This(), &state, @floatFromInt(fb_width), @floatFromInt(fb_height));
        state.flushIfDirty();

        glClearColor(ui_theme.COLOR_BLACK[0], ui_theme.COLOR_BLACK[1], ui_theme.COLOR_BLACK[2], 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
        zgui.backend.draw();
        try sdl.gl.swapWindow(window);
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
    return if (state.hasPendingStream() or state.isPickerPending()) ACTIVE_WAIT_TIMEOUT_MS else IDLE_WAIT_TIMEOUT_MS;
}

fn handleEvent(state: *AppState, keyboard: *keybinds.NativeKeyboardConfig, event: *sdl.Event) bool {
    _ = zgui.backend.processEvent(event);
    switch (event.type) {
        .quit => return false,
        .key_down => {
            if (shouldPasteClipboardImage(state, &event.key)) {
                state.attachClipboardImageToCurrentDraft();
                return true;
            }
            if (handleFileSearchNavigation(state, &event.key)) {
                return true;
            }
            const action = keyboard.actionForEvent(&event.key) orelse return true;
            handleKeyboardAction(state, keyboard, action);
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
    keyboard.deinit();
    keyboard.* = next_keyboard;
    state.setSidebarNotice("App and keybinds refreshed.");
}

pub fn scaledImageSize(width: i32, height: i32, max_width: f32, max_height: f32) [2]f32 {
    if (width <= 0 or height <= 0) return .{ max_width, max_height };
    const width_f: f32 = @floatFromInt(width);
    const height_f: f32 = @floatFromInt(height);
    const scale = @min(max_width / width_f, max_height / height_f);
    return .{ width_f * scale, height_f * scale };
}

pub fn textureRefFromGlId(texture_id: c_uint) zgui.TextureRef {
    return .{
        .tex_data = null,
        .tex_id = @enumFromInt(@as(u64, texture_id)),
    };
}

pub fn formatByteSize(buffer: *[32:0]u8, size: usize) [:0]const u8 {
    @memset(buffer, 0);
    if (size >= 1024 * 1024) {
        _ = std.fmt.bufPrintZ(buffer, "{d:.1} MB", .{@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0)}) catch {};
    } else if (size >= 1024) {
        _ = std.fmt.bufPrintZ(buffer, "{d:.1} KB", .{@as(f64, @floatFromInt(size)) / 1024.0}) catch {};
    } else {
        _ = std.fmt.bufPrintZ(buffer, "{d} B", .{size}) catch {};
    }
    return std.mem.sliceTo(buffer, 0);
}

/// Renders the provider/model controls that sit under the shared composer UI.
pub fn renderComposerPickers(state: *AppState) void {
    const thread = state.currentThreadMutable();

    const transparent = colors.rgba(0, 0, 0, 0);
    const picker_text_color = colors.rgba(160, 164, 180, 255);
    const picker_hover_bg = colors.rgba(50, 52, 60, 255);
    const separator_color = colors.rgba(60, 62, 72, 255);

    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = 8.0 });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 8.0, 6.0 } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = transparent });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = picker_hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = picker_hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .popup_bg, .c = colors.rgba(26, 27, 32, 250) });
    zgui.pushStyleColor4f(.{ .idx = .header, .c = colors.rgba(42, 44, 52, 255) });
    zgui.pushStyleColor4f(.{ .idx = .header_hovered, .c = colors.rgba(52, 54, 64, 255) });
    zgui.pushStyleColor4f(.{ .idx = .header_active, .c = colors.rgba(58, 60, 70, 255) });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = picker_text_color });
    defer {
        zgui.popStyleColor(.{ .count = 8 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    const model_preview = chat_threads.selectedModelLabel(ModelOption, thread, OPENCODE_MODEL_OPTIONS[0..], CODEX_MODEL_OPTIONS[0..]);
    var model_preview_buf = std.mem.zeroes([80:0]u8);
    const model_label = std.fmt.bufPrintZ(&model_preview_buf, "{s} v", .{model_preview}) catch "Model v";
    zgui.setNextItemWidth(composerPickerTextWidth(model_preview) + 36.0);
    if (zgui.beginCombo("##model-picker", .{
        .preview_value = model_label,
        .flags = .{ .no_arrow_button = true },
    })) {
        defer zgui.endCombo();

        zgui.pushStyleColor4f(.{ .idx = .text, .c = ui_theme.COLOR_TEXT_SUBTLE });
        zgui.textUnformatted("Provider");
        zgui.popStyleColor(.{ .count = 1 });
        inline for (@typeInfo(Provider).@"enum".fields) |field| {
            const candidate: Provider = @enumFromInt(field.value);
            var row_buf = std.mem.zeroes([48:0]u8);
            const row_label = comboRowLabel(&row_buf, chat_threads.providerLabel(candidate), candidate == thread.provider);
            if (zgui.selectable(row_label, .{ .selected = candidate == thread.provider, .h = 28.0 })) {
                if (thread.provider != candidate) {
                    thread.provider = candidate;
                    if (thread.provider_thread_id) |thread_id| {
                        state.allocator.free(thread_id);
                    }
                    thread.provider_thread_id = null;
                    if (thread.model_ref) |model_ref| {
                        state.allocator.free(model_ref);
                    }
                    thread.model_ref = null;
                    thread.reasoning_effort = null;
                    thread.fast_mode = .off;
                    state.markDirty();
                }
            }
        }

        zgui.separator();
        zgui.pushStyleColor4f(.{ .idx = .text, .c = ui_theme.COLOR_TEXT_SUBTLE });
        zgui.textUnformatted("Model");
        zgui.popStyleColor(.{ .count = 1 });
        for (chat_threads.modelOptions(ModelOption, thread.provider, OPENCODE_MODEL_OPTIONS[0..], CODEX_MODEL_OPTIONS[0..])) |option| {
            const is_selected = if (option.value) |value|
                thread.model_ref != null and std.mem.eql(u8, thread.model_ref.?, value)
            else
                thread.model_ref == null;
            var row_buf = std.mem.zeroes([96:0]u8);
            const row_label = comboRowLabel(&row_buf, option.label, is_selected);
            if (zgui.selectable(row_label, .{ .selected = is_selected, .h = 28.0 })) {
                setThreadModelRef(state, thread, option.value);
            }
        }
    }

    if (thread.provider != .codex) return;

    zgui.sameLine(.{ .spacing = 6.0 });
    zgui.textColored(separator_color, "|", .{});

    zgui.sameLine(.{ .spacing = 6.0 });
    const reasoning_preview = chat_threads.selectedReasoningLabel(ReasoningOption, thread, CODEX_REASONING_OPTIONS[0..]);
    var reasoning_buf = std.mem.zeroes([80:0]u8);
    const reasoning_label = std.fmt.bufPrintZ(&reasoning_buf, "{s} v", .{reasoning_preview}) catch "Reasoning v";
    zgui.setNextItemWidth(composerPickerTextWidth(reasoning_preview) + 36.0);
    if (zgui.beginCombo("##reasoning-picker", .{
        .preview_value = reasoning_label,
        .flags = .{ .no_arrow_button = true },
    })) {
        defer zgui.endCombo();
        for (CODEX_REASONING_OPTIONS) |option| {
            const is_selected = if (option.value) |value|
                thread.reasoning_effort != null and thread.reasoning_effort.? == value
            else
                thread.reasoning_effort == null;
            var row_buf = std.mem.zeroes([96:0]u8);
            const row_label = comboRowLabel(&row_buf, option.label, is_selected);
            if (zgui.selectable(row_label, .{ .selected = is_selected, .h = 28.0 })) {
                thread.reasoning_effort = option.value;
                state.markDirty();
            }
        }
    }

    zgui.sameLine(.{ .spacing = 6.0 });
    zgui.textColored(separator_color, "|", .{});

    zgui.sameLine(.{ .spacing = 6.0 });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = transparent });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = picker_hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = picker_hover_bg });
    const fast_label: [:0]const u8 = if (thread.fast_mode == .on) "Fast" else "Chat";
    if (zgui.button(fast_label, .{ .w = 0.0, .h = 0.0 })) {
        thread.fast_mode = if (thread.fast_mode == .on) .off else .on;
        state.markDirty();
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{ .spacing = 6.0 });
    zgui.textColored(separator_color, "|", .{});

    zgui.sameLine(.{ .spacing = 6.0 });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = transparent });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = picker_hover_bg });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = picker_hover_bg });
    const access_label: [:0]const u8 = chat_threads.accessModeLabel(thread.access_mode);
    if (zgui.button(access_label, .{ .w = 0.0, .h = 0.0 })) {
        const new_mode: AccessMode = if (thread.access_mode == .full_access) .supervised else .full_access;
        if (thread.access_mode != new_mode) {
            thread.access_mode = new_mode;
            if (thread.provider_thread_id) |thread_id| {
                state.allocator.free(thread_id);
            }
            thread.provider_thread_id = null;
            state.markDirty();
        }
    }
    zgui.popStyleColor(.{ .count = 3 });
}

pub fn isSendPending(state: *AppState) bool {
    state.send_state.mutex.lock();
    defer state.send_state.mutex.unlock();
    return state.send_state.status == .pending;
}

fn composerPickerTextWidth(label: []const u8) f32 {
    return zgui.calcTextSize(label, .{})[0];
}

fn setThreadModelRef(state: *AppState, thread: *ChatThread, value: ?[:0]const u8) void {
    if (thread.model_ref) |existing| {
        state.allocator.free(existing);
        thread.model_ref = null;
    }

    thread.model_ref = if (value) |next|
        state.allocator.dupeZ(u8, next) catch null
    else
        null;
    state.markDirty();
}

fn comboRowLabel(buffer: []u8, label: []const u8, selected: bool) [:0]const u8 {
    return std.fmt.bufPrintZ(buffer, "{s} {s}", .{ if (selected) ">" else " ", label }) catch " row";
}
