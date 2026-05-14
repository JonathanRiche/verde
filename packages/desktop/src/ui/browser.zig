//! Browser dock rendering for the native shell.

const std = @import("std");
const palette = @import("palette");
const sdl = @import("zsdl3");

const app_state = @import("../state.zig");
const browser_runtime = @import("../browser/mod.zig");
const colors = @import("colors.zig");
const theme = @import("theme.zig");

const BrowserHitKind = enum {
    address,
    navigate,
    inspect_toggle,
    inspect_mode_menu,
    inspect_mode_point,
    inspect_mode_draw_box,
    inspect_mode_draw_freeform,
    close,
};

const BrowserHit = struct {
    rect: palette.Rect,
    kind: BrowserHitKind,
};

var palette_hits: [16]BrowserHit = undefined;
var palette_hit_count: usize = 0;
var palette_toolbar_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var palette_menu_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var palette_mouse_pos: [2]f32 = .{ -1.0, -1.0 };

/// Renders the browser dock that manages the in-app browser pane and bridge controls.
pub fn renderDockAt(state: *app_state.AppState, rect: palette.Rect) void {
    if (!state.isBrowserVisible()) return;
    palette_hit_count = 0;
    palette_toolbar_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
    palette_menu_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };

    const toolbar_height = theme.scaledUi(52.0);
    renderPaneCanvas(state, .{
        .x = rect.x,
        .y = rect.y + toolbar_height,
        .w = rect.w,
        .h = @max(rect.h - toolbar_height, theme.scaledUi(180.0)),
    });
    renderToolbar(state, rect);
}

pub fn handlePaletteMouseMotion(x: f32, y: f32) void {
    palette_mouse_pos = .{ x, y };
}

pub fn handlePaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, down: bool) bool {
    if (!state.isBrowserVisible()) return false;
    palette_mouse_pos = .{ x, y };

    if (!down) {
        return rectContainsPoint(palette_toolbar_rect, x, y) or
            (state.browser_inspector_menu_open and rectContainsPoint(palette_menu_rect, x, y));
    }

    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_hits[index];
        if (!rectContainsPoint(hit.rect, x, y)) continue;

        switch (hit.kind) {
            .address => {
                focusAddress(state);
                state.browser_address_cursor = cursorForAddressPoint(state, hit.rect, x);
            },
            .navigate => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                state.navigateBrowserFromAddress();
            },
            .inspect_toggle => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                if (state.canUseBrowserInspector()) state.toggleBrowserInspector();
            },
            .inspect_mode_menu => {
                blurAddress(state);
                if (state.canUseBrowserInspector()) {
                    state.browser_inspector_menu_open = !state.browser_inspector_menu_open;
                }
            },
            .inspect_mode_point => selectInspectorMode(state, .point),
            .inspect_mode_draw_box => selectInspectorMode(state, .draw_box),
            .inspect_mode_draw_freeform => selectInspectorMode(state, .draw_freeform),
            .close => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                state.closeBrowser();
            },
        }
        state.noteInteraction();
        return true;
    }

    if (rectContainsPoint(palette_toolbar_rect, x, y) or
        (state.browser_inspector_menu_open and rectContainsPoint(palette_menu_rect, x, y)))
    {
        blurAddress(state);
        if (!rectContainsPoint(palette_menu_rect, x, y)) {
            state.browser_inspector_menu_open = false;
        }
        return true;
    }

    blurAddress(state);
    state.browser_inspector_menu_open = false;
    return false;
}

pub fn handlePaletteTextInput(state: *app_state.AppState, text: []const u8) bool {
    if (!state.browser_address_focused) return false;
    insertAddressText(state, text);
    state.noteInteraction();
    return true;
}

pub fn handlePaletteKeyDown(state: *app_state.AppState, event: *const sdl.KeyboardEvent) bool {
    if (!state.browser_address_focused) return false;
    if (!event.down) return true;

    const primary = isPrimaryModifierPressed(event.mod);
    switch (event.key) {
        .@"return", .kp_enter => {
            blurAddress(state);
            state.navigateBrowserFromAddress();
        },
        .escape => blurAddress(state),
        .left => state.browser_address_cursor -|= 1,
        .right => state.browser_address_cursor = @min(state.browser_address_cursor + 1, state.browserState().addressInput().len),
        .home => state.browser_address_cursor = 0,
        .end => state.browser_address_cursor = state.browserState().addressInput().len,
        .backspace, .kp_backspace => deleteAddressBackward(state),
        .delete => deleteAddressForward(state),
        .a => {
            if (primary) {
                state.browser_address_cursor = state.browserState().addressInput().len;
            }
        },
        else => return true,
    }
    state.noteInteraction();
    return true;
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn queuePaletteRoundedRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch |err| {
        app_state.log.warn("failed to queue browser palette rounded rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch |err| {
        app_state.log.warn("failed to queue browser palette rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteTriangle(state: *app_state.AppState, p0: palette.draw.Vec2, p1: palette.draw.Vec2, p2: palette.draw.Vec2, color: palette.Color) void {
    state.palette_overlay_batch.triangle(state.allocator, p0, p1, p2, color) catch |err| {
        app_state.log.warn("failed to queue browser palette triangle: {s}", .{@errorName(err)});
    };
}

fn queuePaletteBorder(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch |err| {
        app_state.log.warn("failed to queue browser palette border: {s}", .{@errorName(err)});
    };
}

fn queuePaletteText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stablePaletteText(state, value) catch |err| {
        app_state.log.warn("failed to retain browser palette text: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.fixedText(
        state.allocator,
        rect,
        stable_value,
        color,
        font_size,
        clip,
        .{},
        font_size * 0.55,
        font_size * 1.25,
        false,
    ) catch |err| {
        app_state.log.warn("failed to queue browser palette text: {s}", .{@errorName(err)});
    };
}

fn stablePaletteText(state: *app_state.AppState, value: []const u8) ![]const u8 {
    return try state.palette_frame_text_arena.allocator().dupe(u8, value);
}

fn renderPaletteToolbarButton(
    state: *app_state.AppState,
    rect: palette.Rect,
    label: []const u8,
    base_color: [4]f32,
    hover_color: [4]f32,
    active_color: [4]f32,
    text_color: [4]f32,
    hovered: bool,
    active: bool,
) void {
    const bg = if (active) active_color else if (hovered) hover_color else base_color;
    const font_size = theme.scaledUi(14.0);
    const label_width = @as(f32, @floatFromInt(label.len)) * font_size * 0.55;
    queuePaletteRoundedRect(state, rect, paletteColor(bg), theme.scaledUi(8.0));
    queuePaletteText(state, .{
        .x = rect.x + @max((rect.w - label_width) * 0.5, 0.0),
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = rect.w,
        .h = font_size * 1.25,
    }, label, paletteColor(text_color), font_size, rect);
}

/// Renders the compact browser toolbar with URL entry and primary actions.
fn renderToolbar(state: *app_state.AppState, dock_rect: palette.Rect) void {
    const navigate_icon = ">";
    const close_icon = "x";
    const toolbar_height = theme.scaledUi(52.0);
    const button_size = theme.scaledUi(36.0);
    const inspect_menu_button_width = theme.scaledUi(22.0);
    const pad_x = theme.scaledUi(10.0);
    const pad_y = theme.scaledUi(8.0);
    const avail = @max(dock_rect.w - pad_x * 2.0, theme.scaledUi(180.0));
    const gap = theme.scaledUi(8.0);
    const field_width = @max(avail - button_size * 3.0 - inspect_menu_button_width - gap * 3.0, theme.scaledUi(180.0));
    palette_toolbar_rect = .{ .x = dock_rect.x, .y = dock_rect.y, .w = dock_rect.w, .h = toolbar_height };
    queuePaletteRect(state, palette_toolbar_rect, paletteColor(colors.rgba(18, 20, 25, 255)));

    const address_rect: palette.Rect = .{ .x = dock_rect.x + pad_x, .y = dock_rect.y + pad_y, .w = field_width, .h = button_size };
    renderPaletteAddressField(state, address_rect);
    addPaletteHit(address_rect, .address);

    const navigate_rect: palette.Rect = .{ .x = address_rect.x + address_rect.w + gap, .y = address_rect.y, .w = button_size, .h = button_size };
    renderPaletteToolbarButton(
        state,
        navigate_rect,
        navigate_icon,
        theme.COLOR_SECONDARY_GREEN,
        theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.10),
        theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10),
        theme.COLOR_WHITE,
        rectHovered(navigate_rect),
        false,
    );
    addPaletteHit(navigate_rect, .navigate);

    const can_use_inspector = state.canUseBrowserInspector();
    const inspector_active = state.isBrowserInspectorEnabled();
    const inspector_mode = state.browserInspectorMode();
    const inspector_button_color = if (inspector_active) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_ALT;
    const inspector_hover_color = if (inspector_active) theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.08) else theme.lighten(theme.COLOR_PANEL_ALT, 0.08);
    const inspector_active_color = if (inspector_active) theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) else theme.lighten(theme.COLOR_PANEL_ALT, 0.14);
    const inspect_rect: palette.Rect = .{ .x = navigate_rect.x + navigate_rect.w + gap, .y = address_rect.y, .w = button_size, .h = button_size };
    renderPaletteToolbarButton(
        state,
        inspect_rect,
        "",
        inspector_button_color,
        inspector_hover_color,
        inspector_active_color,
        if (can_use_inspector) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE,
        can_use_inspector and rectHovered(inspect_rect),
        false,
    );
    drawCursorIcon(state, centeredIconRect(inspect_rect), paletteColor(if (can_use_inspector) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE));
    addPaletteHit(inspect_rect, .inspect_toggle);

    const inspect_menu_rect: palette.Rect = .{ .x = inspect_rect.x + inspect_rect.w, .y = address_rect.y, .w = inspect_menu_button_width, .h = button_size };
    renderPaletteToolbarButton(
        state,
        inspect_menu_rect,
        "",
        inspector_button_color,
        inspector_hover_color,
        inspector_active_color,
        if (can_use_inspector) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE,
        can_use_inspector and rectHovered(inspect_menu_rect),
        false,
    );
    drawCaretDownIcon(
        state,
        centeredIconRect(inspect_menu_rect),
        paletteColor(if (can_use_inspector) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE),
    );
    addPaletteHit(inspect_menu_rect, .inspect_mode_menu);
    if (!can_use_inspector) state.browser_inspector_menu_open = false;
    if (state.browser_inspector_menu_open) {
        renderInspectorModeMenu(state, inspect_menu_rect, inspector_mode);
    }

    const close_rect: palette.Rect = .{ .x = inspect_menu_rect.x + inspect_menu_rect.w + gap, .y = address_rect.y, .w = button_size, .h = button_size };
    renderPaletteToolbarButton(
        state,
        close_rect,
        close_icon,
        theme.COLOR_PANEL_ALT,
        theme.lighten(theme.COLOR_PANEL_ALT, 0.08),
        theme.lighten(theme.COLOR_PANEL_ALT, 0.14),
        theme.COLOR_WHITE,
        rectHovered(close_rect),
        false,
    );
    addPaletteHit(close_rect, .close);
}

fn renderInspectorModeMenu(state: *app_state.AppState, anchor: palette.Rect, inspector_mode: browser_runtime.InspectorMode) void {
    const menu_width = theme.scaledUi(180.0);
    const row_height = theme.scaledUi(32.0);
    const pad = theme.scaledUi(8.0);
    palette_menu_rect = .{
        .x = anchor.x + anchor.w - menu_width,
        .y = anchor.y + anchor.h + theme.scaledUi(6.0),
        .w = menu_width,
        .h = row_height * 3.0 + pad * 2.0,
    };
    queuePaletteRoundedRect(state, palette_menu_rect, paletteColor(colors.rgba(26, 28, 34, 255)), theme.scaledUi(12.0));
    queuePaletteBorder(state, palette_menu_rect, paletteColor(colors.rgba(66, 68, 78, 255)), theme.scaledUi(12.0), theme.scaledUi(1.0));

    var y = palette_menu_rect.y + pad;
    renderInspectorModeMenuRow(state, .{ .x = palette_menu_rect.x + pad, .y = y, .w = palette_menu_rect.w - pad * 2.0, .h = row_height }, "Point", inspector_mode == .point, .inspect_mode_point);
    y += row_height;
    renderInspectorModeMenuRow(state, .{ .x = palette_menu_rect.x + pad, .y = y, .w = palette_menu_rect.w - pad * 2.0, .h = row_height }, "Draw Box", inspector_mode == .draw_box, .inspect_mode_draw_box);
    y += row_height;
    renderInspectorModeMenuRow(state, .{ .x = palette_menu_rect.x + pad, .y = y, .w = palette_menu_rect.w - pad * 2.0, .h = row_height }, "Draw Freeform", inspector_mode == .draw_freeform, .inspect_mode_draw_freeform);
}

fn centeredIconRect(rect: palette.Rect) palette.Rect {
    const size = @min(rect.w, rect.h) * 0.54;
    return .{
        .x = rect.x + (rect.w - size) * 0.5,
        .y = rect.y + (rect.h - size) * 0.5,
        .w = size,
        .h = size,
    };
}

/// Small ▼ for the inspector mode split button (Unicode caret is often absent from the UI font).
fn drawCaretDownIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    const cx = rect.x + rect.w * 0.5;
    const tip_y = rect.y + rect.h * 0.72;
    const wing_y = rect.y + rect.h * 0.30;
    const left_x = rect.x + rect.w * 0.20;
    const right_x = rect.x + rect.w * 0.80;
    queuePaletteTriangle(
        state,
        .{ .x = cx, .y = tip_y },
        .{ .x = left_x, .y = wing_y },
        .{ .x = right_x, .y = wing_y },
        color,
    );
}

fn drawCursorIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    const points = [_]palette.draw.Vec2{
        .{ .x = rect.x + rect.w * 0.16, .y = rect.y + rect.h * 0.06 },
        .{ .x = rect.x + rect.w * 0.16, .y = rect.y + rect.h * 0.88 },
        .{ .x = rect.x + rect.w * 0.42, .y = rect.y + rect.h * 0.64 },
        .{ .x = rect.x + rect.w * 0.58, .y = rect.y + rect.h * 0.96 },
        .{ .x = rect.x + rect.w * 0.74, .y = rect.y + rect.h * 0.88 },
        .{ .x = rect.x + rect.w * 0.58, .y = rect.y + rect.h * 0.58 },
        .{ .x = rect.x + rect.w * 0.88, .y = rect.y + rect.h * 0.58 },
    };
    queuePaletteTriangle(state, points[0], points[1], points[2], color);
    queuePaletteTriangle(state, points[0], points[2], points[6], color);
    queuePaletteTriangle(state, points[2], points[3], points[4], color);
    queuePaletteTriangle(state, points[2], points[4], points[5], color);
}

fn renderInspectorModeMenuRow(state: *app_state.AppState, rect: palette.Rect, label: []const u8, selected: bool, kind: BrowserHitKind) void {
    const hovered = rectHovered(rect);
    if (selected or hovered) {
        queuePaletteRoundedRect(
            state,
            rect,
            paletteColor(if (selected) theme.COLOR_SECONDARY_GREEN else theme.lighten(theme.COLOR_PANEL_ALT, 0.08)),
            theme.scaledUi(6.0),
        );
    }

    const marker = if (selected) "* " else "  ";
    var row_buf = std.mem.zeroes([64]u8);
    const row_label = std.fmt.bufPrint(&row_buf, "{s}{s}", .{ marker, label }) catch label;
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(8.0),
        .y = rect.y + (rect.h - theme.scaledUi(14.0) * 1.25) * 0.5,
        .w = rect.w - theme.scaledUi(16.0),
        .h = theme.scaledUi(14.0) * 1.25,
    }, row_label, paletteColor(if (selected) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), rect);
    addPaletteHit(rect, kind);
}

fn renderPaletteAddressField(state: *app_state.AppState, rect: palette.Rect) void {
    const focused = state.browser_address_focused;
    const address = state.browserState().addressInput();
    const text = if (address.len == 0 and !focused) "https://example.com" else address;
    const font_size = theme.scaledUi(14.0);
    const pad_x = theme.scaledUi(10.0);
    const text_rect: palette.Rect = .{
        .x = rect.x + pad_x,
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = rect.w - pad_x * 2.0,
        .h = font_size * 1.25,
    };
    queuePaletteRoundedRect(
        state,
        rect,
        paletteColor(if (focused) theme.lighten(theme.COLOR_PANEL_ALT, 0.10) else theme.COLOR_PANEL_ALT),
        theme.scaledUi(8.0),
    );
    queuePaletteBorder(
        state,
        rect,
        paletteColor(if (focused) theme.COLOR_SECONDARY_GREEN else colors.rgba(66, 68, 78, 255)),
        theme.scaledUi(8.0),
        theme.scaledUi(1.0),
    );
    queuePaletteText(
        state,
        text_rect,
        text,
        paletteColor(if (address.len == 0 and !focused) theme.COLOR_TEXT_SUBTLE else theme.COLOR_WHITE),
        font_size,
        rect,
    );

    if (focused) {
        const cursor = @min(state.browser_address_cursor, address.len);
        const prefix_w = app_state.paletteUiTextPrefixWidth(address, font_size, cursor);
        const caret_x = text_rect.x + prefix_w;
        queuePaletteRect(state, .{
            .x = @min(caret_x, rect.x + rect.w - pad_x - theme.scaledUi(1.5)),
            .y = text_rect.y + theme.scaledUi(1.0),
            .w = theme.scaledUi(1.5),
            .h = text_rect.h - theme.scaledUi(2.0),
        }, paletteColor(theme.COLOR_WHITE));
    }
}

fn addPaletteHit(rect: palette.Rect, kind: BrowserHitKind) void {
    if (palette_hit_count >= palette_hits.len) return;
    palette_hits[palette_hit_count] = .{ .rect = rect, .kind = kind };
    palette_hit_count += 1;
}

fn rectHovered(rect: palette.Rect) bool {
    return rectContainsPoint(rect, palette_mouse_pos[0], palette_mouse_pos[1]);
}

fn rectContainsPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn focusAddress(state: *app_state.AppState) void {
    state.browser_address_focused = true;
    state.terminal_focused = false;
    state.composer_focused = false;
    state.unfocusBrowserPane();
    state.browser_inspector_menu_open = false;
    state.browser_address_cursor = @min(state.browser_address_cursor, state.browserState().addressInput().len);
}

fn blurAddress(state: *app_state.AppState) void {
    state.browser_address_focused = false;
    state.browser_address_cursor = @min(state.browser_address_cursor, state.browserState().addressInput().len);
}

fn selectInspectorMode(state: *app_state.AppState, mode: browser_runtime.InspectorMode) void {
    blurAddress(state);
    state.setBrowserInspectorMode(mode);
    state.browser_inspector_menu_open = false;
}

fn addressIndexForClick(address: []const u8, font_size: f32, rel: f32) usize {
    if (address.len == 0 or rel <= 0.0) return 0;
    const total = app_state.paletteUiTextPrefixWidth(address, font_size, address.len);
    if (rel >= total) return address.len;

    var i: usize = 0;
    while (i < address.len) {
        const step = std.unicode.utf8ByteSequenceLength(address[i]) catch 1;
        const next = @min(i + step, address.len);
        const w_before = app_state.paletteUiTextPrefixWidth(address, font_size, i);
        const w_after = app_state.paletteUiTextPrefixWidth(address, font_size, next);
        if (w_after > rel) {
            return if (rel - w_before <= w_after - rel) i else next;
        }
        i = next;
    }
    return address.len;
}

fn cursorForAddressPoint(state: *app_state.AppState, rect: palette.Rect, x: f32) usize {
    const font_size = theme.scaledUi(14.0);
    const pad_x = theme.scaledUi(10.0);
    const address = state.browserState().addressInput();
    const rel = @max(x - rect.x - pad_x, 0.0);
    return @min(addressIndexForClick(address, font_size, rel), address.len);
}

fn insertAddressText(state: *app_state.AppState, text: []const u8) void {
    if (text.len == 0) return;
    const browser_state = state.browserState();
    const buffer = browser_state.addressBuffer();
    const current_len = browser_state.addressInput().len;
    const cursor = @min(state.browser_address_cursor, current_len);
    const available = if (buffer.len > current_len) buffer.len - current_len else 0;
    const insert_len = @min(text.len, available);
    if (insert_len == 0) return;

    std.mem.copyBackwards(u8, buffer[cursor + insert_len .. current_len + insert_len], buffer[cursor..current_len]);
    @memcpy(buffer[cursor .. cursor + insert_len], text[0..insert_len]);
    buffer[current_len + insert_len] = 0;
    state.browser_address_cursor = cursor + insert_len;
}

fn deleteAddressBackward(state: *app_state.AppState) void {
    const browser_state = state.browserState();
    const buffer = browser_state.addressBuffer();
    const current_len = browser_state.addressInput().len;
    const cursor = @min(state.browser_address_cursor, current_len);
    if (cursor == 0) return;
    std.mem.copyForwards(u8, buffer[cursor - 1 .. current_len - 1], buffer[cursor..current_len]);
    buffer[current_len - 1] = 0;
    state.browser_address_cursor = cursor - 1;
}

fn deleteAddressForward(state: *app_state.AppState) void {
    const browser_state = state.browserState();
    const buffer = browser_state.addressBuffer();
    const current_len = browser_state.addressInput().len;
    const cursor = @min(state.browser_address_cursor, current_len);
    if (cursor >= current_len) return;
    std.mem.copyForwards(u8, buffer[cursor .. current_len - 1], buffer[cursor + 1 .. current_len]);
    buffer[current_len - 1] = 0;
    state.browser_address_cursor = cursor;
}

fn isPrimaryModifierPressed(modifier_state: sdl.Keymod) bool {
    const bits = @as(*const u16, @ptrCast(&modifier_state)).*;
    return (bits & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
}

/// Renders the in-app browser pane canvas or the current scaffold placeholder.
fn renderPaneCanvas(state: *app_state.AppState, pane_rect: palette.Rect) void {
    const browser_state = state.browserState();
    const pane_hovered = rectHovered(pane_rect);
    const width_px: u32 = @intFromFloat(@max(pane_rect.w, 1.0));
    const height_px: u32 = @intFromFloat(@max(pane_rect.h, 1.0));
    const input_size = .{ @as(f32, @floatFromInt(width_px)), @as(f32, @floatFromInt(height_px)) };
    browser_state.controller.resizePane(width_px, height_px) catch {};

    queuePaletteRect(state, pane_rect, paletteColor(colors.rgba(9, 11, 16, 255)));

    if (browser_state.controller.paneTexture()) |pane_texture| {
        if (pane_texture.isReady()) {
            // Fill the pane so the preview uses the full column (resizePane already matches pane_rect size).
            state.noteBrowserPaneRegion(
                .{ pane_rect.x, pane_rect.y },
                .{ pane_rect.x + pane_rect.w, pane_rect.y + pane_rect.h },
                input_size,
                pane_hovered,
            );
            state.palette_overlay_batch.image(
                state.allocator,
                .{ .x = pane_rect.x, .y = pane_rect.y, .w = pane_rect.w, .h = pane_rect.h },
                palette.TextureId.init(pane_texture.texture_id),
                .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 },
                paletteColor(theme.COLOR_WHITE),
                null,
            ) catch {};
            return;
        }
    }

    // Fall back to the full pane bounds while the browser frame has not arrived yet.
    state.noteBrowserPaneRegion(
        .{ pane_rect.x, pane_rect.y },
        .{ pane_rect.x + pane_rect.w, pane_rect.y + pane_rect.h },
        input_size,
        pane_hovered,
    );

    renderPanePlaceholder();
}

/// Keeps the pane visually blank until the first browser frame arrives.
fn renderPanePlaceholder() void {}
