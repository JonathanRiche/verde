//! Browser dock rendering for the native shell.

const std = @import("std");
const palette = @import("palette");
const sdl = @import("zsdl3");

const app_state = @import("../state.zig");
const browser_runtime = @import("../browser/mod.zig");
const colors = @import("colors.zig");
const theme = @import("theme.zig");

// Nerd Font Symbols codicon glyphs. Codepoints match the Microsoft Codicons
// table (https://microsoft.github.io/vscode-codicons/dist/codicon.html) and
// are present in SymbolsNerdFontMono-Regular.ttf.
const NF_COD_ARROW_LEFT = "\u{EA9B}";
const NF_COD_ARROW_RIGHT = "\u{EA9C}";
const NF_COD_REFRESH = "\u{EB37}";
const NF_COD_INSPECT = "\u{EBD1}";
const NF_COD_CHEVRON_DOWN = "\u{EAB4}";
const NF_COD_CLOSE = "\u{EA76}";

const TOOLBAR_HEIGHT: f32 = 52.0;
const TOOLBAR_BUTTON_SIZE: f32 = 34.0;
const TOOLBAR_BUTTON_RADIUS: f32 = 8.0;
const TOOLBAR_ICON_SIZE: f32 = 15.0;
const TOOLBAR_CHEVRON_SIZE: f32 = 11.0;
const TOOLBAR_GAP: f32 = 6.0;
const TOOLBAR_DROPDOWN_WIDTH: f32 = 20.0;
const TOOLBAR_FIELD_MIN_WIDTH: f32 = 120.0;

const BrowserHitKind = enum {
    address,
    back,
    forward,
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
var palette_context_menu_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var palette_mouse_pos: [2]f32 = .{ -1.0, -1.0 };

/// Renders the browser dock that manages the in-app browser pane and bridge controls.
pub fn renderDockAt(state: *app_state.AppState, rect: palette.Rect) void {
    if (!state.isBrowserVisible()) return;
    palette_hit_count = 0;
    palette_toolbar_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
    palette_menu_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
    palette_context_menu_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };

    const toolbar_height = theme.scaledUi(TOOLBAR_HEIGHT);
    renderPaneCanvas(state, .{
        .x = rect.x,
        .y = rect.y + toolbar_height,
        .w = rect.w,
        .h = @max(rect.h - toolbar_height, theme.scaledUi(180.0)),
    });
    renderToolbar(state, rect);
    renderBrowserContextMenu(state);
}

pub fn handlePaletteMouseMotion(state: *app_state.AppState, x: f32, y: f32) void {
    palette_mouse_pos = .{ x, y };
    // Drag-to-extend the URL-bar selection. We re-find the address hit rect
    // each frame (the toolbar may have re-laid out) so the cursor stays
    // accurate even if the field moves under the pointer.
    if (state.browser_address_drag_active and state.browser_address_focused) {
        if (findHit(.address)) |hit| {
            state.browser_address_cursor = cursorForAddressPoint(state, hit.rect, x);
        }
    }
}

fn findHit(kind: BrowserHitKind) ?BrowserHit {
    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        if (palette_hits[index].kind == kind) return palette_hits[index];
    }
    return null;
}

pub fn triggerPaletteToolbarHit(state: *app_state.AppState, name: []const u8) bool {
    const kind = toolbarHitKindByName(name) orelse return false;
    const hit = findHit(kind) orelse return false;
    return handlePaletteMouseButton(
        state,
        hit.rect.x + hit.rect.w * 0.5,
        hit.rect.y + hit.rect.h * 0.5,
        true,
        1,
    );
}

fn toolbarHitKindByName(name: []const u8) ?BrowserHitKind {
    if (std.mem.eql(u8, name, "address")) return .address;
    if (std.mem.eql(u8, name, "back")) return .back;
    if (std.mem.eql(u8, name, "forward")) return .forward;
    if (std.mem.eql(u8, name, "navigate") or std.mem.eql(u8, name, "reload")) return .navigate;
    if (std.mem.eql(u8, name, "inspect-toggle")) return .inspect_toggle;
    if (std.mem.eql(u8, name, "inspect-menu")) return .inspect_mode_menu;
    if (std.mem.eql(u8, name, "inspect-point")) return .inspect_mode_point;
    if (std.mem.eql(u8, name, "inspect-draw-box")) return .inspect_mode_draw_box;
    if (std.mem.eql(u8, name, "inspect-draw-freeform")) return .inspect_mode_draw_freeform;
    if (std.mem.eql(u8, name, "close")) return .close;
    return null;
}

pub fn handlePaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    if (!state.isBrowserVisible()) return false;
    palette_mouse_pos = .{ x, y };

    if (state.browser_context_menu_open) {
        if (!down) {
            return rectContainsPoint(palette_context_menu_rect, x, y);
        }
        if (rectContainsPoint(palette_context_menu_rect, x, y)) {
            if (browserContextMenuItemAtPoint(state, x, y)) |item| {
                if (item.enabled and !item.separator and !item.submenu) {
                    state.activateBrowserContextMenuItem(item.index);
                }
            }
            state.noteInteraction();
            return true;
        }
        state.dismissBrowserContextMenu();
        if (!state.browserPaneContains(x, y)) return true;
    }

    if (down and (rectContainsPoint(palette_toolbar_rect, x, y) or
        (state.browser_inspector_menu_open and rectContainsPoint(palette_menu_rect, x, y))))
    {
        if (state.currentProjectVisibleBrowserPaneId()) |pane_id| {
            _ = state.focusCurrentProjectWorkspacePane(pane_id);
        }
    }

    if (!down) {
        state.browser_address_drag_active = false;
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
                const address = state.browserState().addressInput();
                const offset = cursorForAddressPoint(state, hit.rect, x);
                if (clicks >= 3) {
                    // Triple-click: select the whole URL — single-line field,
                    // no need for a line scan.
                    state.browser_address_cursor = address.len;
                    state.browser_address_selection_anchor = 0;
                    state.browser_address_drag_active = false;
                } else if (clicks == 2) {
                    const bounds = wordBoundsAt(address, offset);
                    state.browser_address_selection_anchor = bounds.start;
                    state.browser_address_cursor = bounds.end;
                    state.browser_address_drag_active = false;
                } else {
                    state.browser_address_cursor = offset;
                    state.browser_address_selection_anchor = offset;
                    state.browser_address_drag_active = true;
                }
            },
            .back => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                state.navigateBrowserHistory(-1);
            },
            .forward => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                state.navigateBrowserHistory(1);
            },
            .navigate => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                state.navigateOrReloadBrowserFromAddress();
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
    _ = deleteAddressSelection(state);
    insertAddressText(state, text);
    state.noteInteraction();
    return true;
}

pub fn handlePaletteKeyDown(state: *app_state.AppState, event: *const sdl.KeyboardEvent) bool {
    if (!state.browser_address_focused) return false;
    if (!event.down) return true;

    const primary = isPrimaryModifierPressed(event.mod);
    const shift = isShiftPressed(event.mod);
    const address_len = state.browserState().addressInput().len;
    switch (event.key) {
        .@"return", .kp_enter => {
            blurAddress(state);
            state.navigateBrowserFromAddress();
        },
        .escape => blurAddress(state),
        .left => {
            const target = state.browser_address_cursor -| 1;
            moveAddressCursor(state, target, shift);
        },
        .right => {
            const target = @min(state.browser_address_cursor + 1, address_len);
            moveAddressCursor(state, target, shift);
        },
        .home => moveAddressCursor(state, 0, shift),
        .end => moveAddressCursor(state, address_len, shift),
        .backspace, .kp_backspace => {
            if (!deleteAddressSelection(state)) deleteAddressBackward(state);
        },
        .delete => {
            if (!deleteAddressSelection(state)) deleteAddressForward(state);
        },
        .a => {
            if (primary) {
                state.browser_address_selection_anchor = 0;
                state.browser_address_cursor = address_len;
            }
        },
        .c => {
            if (primary) copyAddressSelection(state);
        },
        .x => {
            if (primary) {
                copyAddressSelection(state);
                _ = deleteAddressSelection(state);
            }
        },
        .v => {
            if (primary) pasteIntoAddress(state);
        },
        else => return true,
    }
    state.noteInteraction();
    return true;
}

fn moveAddressCursor(state: *app_state.AppState, target: usize, shift: bool) void {
    if (shift) {
        if (state.browser_address_selection_anchor == null) {
            state.browser_address_selection_anchor = state.browser_address_cursor;
        }
    } else {
        clearAddressSelection(state);
    }
    state.browser_address_cursor = target;
}

fn copyAddressSelection(state: *app_state.AppState) void {
    const address = state.browserState().addressInput();
    const sel = addressSelectionRange(state, address) orelse return;
    const slice = address[sel.start..sel.end];
    if (slice.len == 0) return;
    const z = state.allocator.dupeZ(u8, slice) catch return;
    defer state.allocator.free(z);
    sdl.setClipboardText(z) catch |err| {
        app_state.log.warn("failed to copy URL bar selection: {s}", .{@errorName(err)});
    };
}

fn pasteIntoAddress(state: *app_state.AppState) void {
    const text = state.readClipboardTextForPaste() orelse return;
    defer state.allocator.free(text);
    if (text.len == 0) return;
    _ = deleteAddressSelection(state);
    // Strip control chars (newlines from multi-line clipboard contents); the
    // URL field is single-line.
    var sanitized: [4096]u8 = undefined;
    var n: usize = 0;
    for (text) |b| {
        if (b == '\n' or b == '\r' or b == '\t') continue;
        if (n >= sanitized.len) break;
        sanitized[n] = b;
        n += 1;
    }
    insertAddressText(state, sanitized[0..n]);
}

fn isShiftPressed(modifier_state: sdl.Keymod) bool {
    const bits = @as(*const u16, @ptrCast(&modifier_state)).*;
    return (bits & sdl.Keymod.shift) != 0;
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
    // Variable-width rendering on the `.ui` font role. Caret math goes
    // through `paletteUiTextPrefixWidth` which measures with the same role,
    // so glyph positions and the caret align to the same pixel. Plain
    // `batch.text()` would fall back to the renderer's default font and
    // re-introduce the drift.
    state.palette_overlay_batch.roleText(
        state.allocator,
        rect,
        stable_value,
        color,
        font_size,
        .ui,
        null,
        clip,
    ) catch |err| {
        app_state.log.warn("failed to queue browser palette text: {s}", .{@errorName(err)});
    };
}

fn stablePaletteText(state: *app_state.AppState, value: []const u8) ![]const u8 {
    return try state.palette_frame_text_arena.allocator().dupe(u8, value);
}

fn queuePaletteIcon(
    state: *app_state.AppState,
    rect: palette.Rect,
    glyph: []const u8,
    font_size: f32,
    color: palette.Color,
) void {
    const stable_value = stablePaletteText(state, glyph) catch |err| {
        app_state.log.warn("failed to retain browser palette icon: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.roleText(
        state.allocator,
        snapRect(rect),
        stable_value,
        color,
        font_size,
        .icon,
        null,
        null,
    ) catch |err| {
        app_state.log.warn("failed to queue browser palette icon: {s}", .{@errorName(err)});
    };
}

fn snapRect(rect: palette.Rect) palette.Rect {
    return .{ .x = @round(rect.x), .y = @round(rect.y), .w = @round(rect.w), .h = @round(rect.h) };
}

/// Centers a square `font_size`×`font_size` icon rect inside `button_rect`.
fn iconRectForButton(button_rect: palette.Rect, font_size: f32) palette.Rect {
    return .{
        .x = button_rect.x + (button_rect.w - font_size) * 0.5,
        .y = button_rect.y + (button_rect.h - font_size) * 0.5,
        .w = font_size,
        .h = font_size,
    };
}

/// Renders a single icon toolbar button with consistent state styling. The
/// caller controls the base color (so the accent refresh button can stay green
/// while the neutral nav buttons share a single palette).
fn renderToolbarIconButton(
    state: *app_state.AppState,
    rect: palette.Rect,
    glyph: []const u8,
    base_color: [4]f32,
    icon_color: [4]f32,
    hovered: bool,
    disabled: bool,
) void {
    const bg = if (disabled)
        theme.darken(base_color, 0.04)
    else if (hovered)
        theme.lighten(base_color, 0.10)
    else
        base_color;
    queuePaletteRoundedRect(state, rect, paletteColor(bg), theme.scaledUi(TOOLBAR_BUTTON_RADIUS));
    const icon_size = theme.scaledUi(TOOLBAR_ICON_SIZE);
    queuePaletteIcon(state, iconRectForButton(rect, icon_size), glyph, icon_size, paletteColor(icon_color));
}

/// Renders the inspector toggle and its mode dropdown as a single split-button
/// unit: one shared rounded background, a hairline divider, and per-segment
/// hover pills. This avoids the visual mismatch of two abutting rounded rects.
fn renderInspectorSplitButton(
    state: *app_state.AppState,
    inspect_rect: palette.Rect,
    dropdown_rect: palette.Rect,
    base_color: [4]f32,
    icon_color: [4]f32,
    inspect_hovered: bool,
    dropdown_hovered: bool,
    disabled: bool,
) void {
    const combined: palette.Rect = .{
        .x = inspect_rect.x,
        .y = inspect_rect.y,
        .w = inspect_rect.w + dropdown_rect.w,
        .h = inspect_rect.h,
    };
    const bg = if (disabled) theme.darken(base_color, 0.04) else base_color;
    queuePaletteRoundedRect(state, combined, paletteColor(bg), theme.scaledUi(TOOLBAR_BUTTON_RADIUS));

    if (!disabled and (inspect_hovered or dropdown_hovered)) {
        const pill_inset = theme.scaledUi(2.0);
        const pill_radius = theme.scaledUi(TOOLBAR_BUTTON_RADIUS - 2.0);
        const hover_color = paletteColor(theme.lighten(base_color, 0.10));
        const seg = if (inspect_hovered) inspect_rect else dropdown_rect;
        queuePaletteRoundedRect(state, .{
            .x = seg.x + pill_inset,
            .y = seg.y + pill_inset,
            .w = seg.w - pill_inset * 2.0,
            .h = seg.h - pill_inset * 2.0,
        }, hover_color, pill_radius);
    }

    // Hairline divider between the segments, inset vertically so it reads as
    // a separator rather than a hard edge.
    const divider_inset = theme.scaledUi(8.0);
    queuePaletteRect(state, snapRect(.{
        .x = dropdown_rect.x,
        .y = inspect_rect.y + divider_inset,
        .w = theme.scaledUi(1.0),
        .h = inspect_rect.h - divider_inset * 2.0,
    }), paletteColor(theme.withAlpha(theme.background(), 70)));

    const icon_size = theme.scaledUi(TOOLBAR_ICON_SIZE);
    queuePaletteIcon(state, iconRectForButton(inspect_rect, icon_size), NF_COD_INSPECT, icon_size, paletteColor(icon_color));
    const chevron_size = theme.scaledUi(TOOLBAR_CHEVRON_SIZE);
    queuePaletteIcon(state, iconRectForButton(dropdown_rect, chevron_size), NF_COD_CHEVRON_DOWN, chevron_size, paletteColor(icon_color));
}

/// Renders the compact browser toolbar with URL entry and primary actions.
fn renderToolbar(state: *app_state.AppState, dock_rect: palette.Rect) void {
    const toolbar_height = theme.scaledUi(TOOLBAR_HEIGHT);
    const button_size = theme.scaledUi(TOOLBAR_BUTTON_SIZE);
    const dropdown_width = theme.scaledUi(TOOLBAR_DROPDOWN_WIDTH);
    const pad_x = theme.scaledUi(10.0);
    const pad_y = (toolbar_height - button_size) * 0.5;
    const gap = theme.scaledUi(TOOLBAR_GAP);
    const avail = @max(dock_rect.w - pad_x * 2.0, theme.scaledUi(180.0));

    // Layout: [field] [back][fwd][refresh] [inspect|menu] [close]
    // Five neutral buttons + one split button (= 1.5 button widths) + 5 gaps.
    const buttons_width = button_size * 5.0 + (button_size + dropdown_width) + gap * 5.0;
    const field_width = @max(avail - buttons_width, theme.scaledUi(TOOLBAR_FIELD_MIN_WIDTH));

    palette_toolbar_rect = .{ .x = dock_rect.x, .y = dock_rect.y, .w = dock_rect.w, .h = toolbar_height };
    queuePaletteRect(state, palette_toolbar_rect, paletteColor(theme.background()));

    const address_rect: palette.Rect = .{
        .x = dock_rect.x + pad_x,
        .y = dock_rect.y + pad_y,
        .w = field_width,
        .h = button_size,
    };
    renderPaletteAddressField(state, address_rect);
    addPaletteHit(address_rect, .address);

    var cursor_x = address_rect.x + address_rect.w + gap;

    const neutral_base = theme.COLOR_PANEL_ALT;
    const neutral_icon = theme.COLOR_WHITE;

    const back_rect: palette.Rect = .{ .x = cursor_x, .y = address_rect.y, .w = button_size, .h = button_size };
    renderToolbarIconButton(state, back_rect, NF_COD_ARROW_LEFT, neutral_base, neutral_icon, rectHovered(back_rect), false);
    addPaletteHit(back_rect, .back);
    cursor_x += button_size + gap;

    const forward_rect: palette.Rect = .{ .x = cursor_x, .y = address_rect.y, .w = button_size, .h = button_size };
    renderToolbarIconButton(state, forward_rect, NF_COD_ARROW_RIGHT, neutral_base, neutral_icon, rectHovered(forward_rect), false);
    addPaletteHit(forward_rect, .forward);
    cursor_x += button_size + gap;

    // Refresh / navigate: accent color signals the primary action in the row.
    const navigate_rect: palette.Rect = .{ .x = cursor_x, .y = address_rect.y, .w = button_size, .h = button_size };
    renderToolbarIconButton(state, navigate_rect, NF_COD_REFRESH, theme.COLOR_SECONDARY_GREEN, theme.COLOR_WHITE, rectHovered(navigate_rect), false);
    addPaletteHit(navigate_rect, .navigate);
    cursor_x += button_size + gap;

    const can_use_inspector = state.canUseBrowserInspector();
    const inspector_active = state.isBrowserInspectorEnabled();
    const inspector_mode = state.browserInspectorMode();
    const inspector_base = if (inspector_active) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_ALT;
    const inspector_icon = if (can_use_inspector) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE;

    const inspect_rect: palette.Rect = .{ .x = cursor_x, .y = address_rect.y, .w = button_size, .h = button_size };
    const inspect_menu_rect: palette.Rect = .{ .x = inspect_rect.x + inspect_rect.w, .y = address_rect.y, .w = dropdown_width, .h = button_size };
    renderInspectorSplitButton(
        state,
        inspect_rect,
        inspect_menu_rect,
        inspector_base,
        inspector_icon,
        can_use_inspector and rectHovered(inspect_rect),
        can_use_inspector and rectHovered(inspect_menu_rect),
        !can_use_inspector,
    );
    addPaletteHit(inspect_rect, .inspect_toggle);
    addPaletteHit(inspect_menu_rect, .inspect_mode_menu);
    if (!can_use_inspector) state.browser_inspector_menu_open = false;
    if (state.browser_inspector_menu_open) {
        renderInspectorModeMenu(state, inspect_menu_rect, inspector_mode);
    }
    cursor_x = inspect_menu_rect.x + inspect_menu_rect.w + gap;

    const close_rect: palette.Rect = .{ .x = cursor_x, .y = address_rect.y, .w = button_size, .h = button_size };
    renderToolbarIconButton(state, close_rect, NF_COD_CLOSE, neutral_base, neutral_icon, rectHovered(close_rect), false);
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
    queuePaletteRoundedRect(state, palette_menu_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(12.0));
    queuePaletteBorder(state, palette_menu_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(12.0), theme.scaledUi(1.0));

    var y = palette_menu_rect.y + pad;
    renderInspectorModeMenuRow(state, .{ .x = palette_menu_rect.x + pad, .y = y, .w = palette_menu_rect.w - pad * 2.0, .h = row_height }, "Point", inspector_mode == .point, .inspect_mode_point);
    y += row_height;
    renderInspectorModeMenuRow(state, .{ .x = palette_menu_rect.x + pad, .y = y, .w = palette_menu_rect.w - pad * 2.0, .h = row_height }, "Draw Box", inspector_mode == .draw_box, .inspect_mode_draw_box);
    y += row_height;
    renderInspectorModeMenuRow(state, .{ .x = palette_menu_rect.x + pad, .y = y, .w = palette_menu_rect.w - pad * 2.0, .h = row_height }, "Draw Freeform", inspector_mode == .draw_freeform, .inspect_mode_draw_freeform);
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

fn renderBrowserContextMenu(state: *app_state.AppState) void {
    if (!state.browser_context_menu_open or state.browser_context_menu_items.items.len == 0) return;
    const menu_width = theme.scaledUi(230.0);
    const row_height = theme.scaledUi(30.0);
    const separator_height = theme.scaledUi(9.0);
    const pad = theme.scaledUi(6.0);
    var content_height = pad * 2.0;
    for (state.browser_context_menu_items.items) |item| {
        content_height += if (item.separator) separator_height else row_height;
    }

    var x = state.browser_context_menu_anchor_x;
    var y = state.browser_context_menu_anchor_y;
    const min_x = state.browser_pane_min[0] + theme.scaledUi(4.0);
    const min_y = state.browser_pane_min[1] + theme.scaledUi(4.0);
    const max_x = state.browser_pane_max[0] - menu_width - theme.scaledUi(4.0);
    const max_y = state.browser_pane_max[1] - content_height - theme.scaledUi(4.0);
    x = theme.clampf(x, min_x, @max(min_x, max_x));
    y = theme.clampf(y, min_y, @max(min_y, max_y));
    palette_context_menu_rect = .{ .x = x, .y = y, .w = menu_width, .h = content_height };

    queuePaletteRoundedRect(state, palette_context_menu_rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 245)), theme.scaledUi(8.0));
    queuePaletteBorder(state, palette_context_menu_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), theme.scaledUi(1.0));

    var row_y = palette_context_menu_rect.y + pad;
    for (state.browser_context_menu_items.items) |item| {
        if (item.separator) {
            queuePaletteRect(state, snapRect(.{
                .x = palette_context_menu_rect.x + pad,
                .y = row_y + separator_height * 0.5,
                .w = palette_context_menu_rect.w - pad * 2.0,
                .h = theme.scaledUi(1.0),
            }), paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 180)));
            row_y += separator_height;
            continue;
        }

        const row_rect: palette.Rect = .{
            .x = palette_context_menu_rect.x + pad,
            .y = row_y,
            .w = palette_context_menu_rect.w - pad * 2.0,
            .h = row_height,
        };
        const usable = item.enabled and !item.submenu;
        if (rectHovered(row_rect) and usable) {
            queuePaletteRoundedRect(state, row_rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(5.0));
        }
        queuePaletteText(state, .{
            .x = row_rect.x + theme.scaledUi(8.0),
            .y = row_rect.y + (row_rect.h - theme.scaledUi(13.0) * 1.25) * 0.5,
            .w = row_rect.w - theme.scaledUi(16.0),
            .h = theme.scaledUi(13.0) * 1.25,
        }, item.label, paletteColor(if (usable) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), row_rect);
        row_y += row_height;
    }
}

fn browserContextMenuItemAtPoint(state: *app_state.AppState, x: f32, y: f32) ?app_state.BrowserContextMenuItem {
    if (!rectContainsPoint(palette_context_menu_rect, x, y)) return null;
    const row_height = theme.scaledUi(30.0);
    const separator_height = theme.scaledUi(9.0);
    const pad = theme.scaledUi(6.0);
    var row_y = palette_context_menu_rect.y + pad;
    for (state.browser_context_menu_items.items) |item| {
        const height = if (item.separator) separator_height else row_height;
        if (!item.separator and y >= row_y and y <= row_y + height) return item;
        row_y += height;
    }
    return null;
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
        paletteColor(if (focused) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_MUTED),
        theme.scaledUi(8.0),
        theme.scaledUi(1.0),
    );

    // Draw selection highlight underneath the text so glyphs read over it.
    if (focused) {
        if (addressSelectionRange(state, address)) |sel| {
            const x0 = text_rect.x + app_state.paletteUiTextPrefixWidth(address, font_size, sel.start);
            const x1 = text_rect.x + app_state.paletteUiTextPrefixWidth(address, font_size, sel.end);
            const clamped_x0 = @max(x0, text_rect.x);
            const clamped_x1 = @min(x1, text_rect.x + text_rect.w);
            if (clamped_x1 > clamped_x0) {
                queuePaletteRect(state, .{
                    .x = clamped_x0,
                    .y = text_rect.y,
                    .w = clamped_x1 - clamped_x0,
                    .h = text_rect.h,
                }, paletteColor(theme.withAlpha(theme.selection(), 200)));
            }
        }
    }

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

const SelectionRange = struct { start: usize, end: usize };

/// Returns the normalized selection range if the URL bar has a non-empty
/// selection. The anchor + cursor form the unordered endpoints; this returns
/// them in order so callers don't have to worry about direction.
fn addressSelectionRange(state: *app_state.AppState, address: []const u8) ?SelectionRange {
    const anchor = state.browser_address_selection_anchor orelse return null;
    const cursor = @min(state.browser_address_cursor, address.len);
    const a = @min(anchor, address.len);
    if (a == cursor) return null;
    return .{ .start = @min(a, cursor), .end = @max(a, cursor) };
}

fn clearAddressSelection(state: *app_state.AppState) void {
    state.browser_address_selection_anchor = null;
}

fn deleteAddressSelection(state: *app_state.AppState) bool {
    const browser_state = state.browserState();
    const address = browser_state.addressInput();
    const sel = addressSelectionRange(state, address) orelse return false;
    const buffer = browser_state.addressBuffer();
    const current_len = address.len;
    std.mem.copyForwards(u8, buffer[sel.start .. current_len - (sel.end - sel.start)], buffer[sel.end..current_len]);
    buffer[current_len - (sel.end - sel.start)] = 0;
    state.browser_address_cursor = sel.start;
    clearAddressSelection(state);
    return true;
}

fn isWordChar(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_' or b == '-';
}

fn wordBoundsAt(address: []const u8, offset: usize) SelectionRange {
    if (address.len == 0) return .{ .start = 0, .end = 0 };
    var start = @min(offset, address.len);
    var end = start;
    while (start > 0 and isWordChar(address[start - 1])) start -= 1;
    while (end < address.len and isWordChar(address[end])) end += 1;
    // Empty run (clicked on a non-word boundary) — fall back to selecting the
    // single byte under the cursor so a double-click still produces a visible
    // selection.
    if (start == end and end < address.len) end += 1;
    return .{ .start = start, .end = end };
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
    state.blurPaletteComposer();
    state.unfocusBrowserPane();
    state.browser_inspector_menu_open = false;
    state.browser_address_cursor = @min(state.browser_address_cursor, state.browserState().addressInput().len);
}

fn blurAddress(state: *app_state.AppState) void {
    state.browser_address_focused = false;
    state.browser_address_cursor = @min(state.browser_address_cursor, state.browserState().addressInput().len);
    state.browser_address_drag_active = false;
    clearAddressSelection(state);
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
    const input_size = state.browserPaneInputSize(pane_rect.w, pane_rect.h);
    state.noteBrowserPaneRegion(
        .{ pane_rect.x, pane_rect.y },
        .{ pane_rect.x + pane_rect.w, pane_rect.y + pane_rect.h },
        input_size,
        pane_hovered,
    );

    queuePaletteRect(state, pane_rect, paletteColor(theme.background()));

    if (browser_state.controller.paneTexture()) |pane_texture| {
        if (pane_texture.isReady()) {
            state.palette_overlay_batch.image(
                state.allocator,
                snapRect(pane_rect),
                palette.TextureId.init(pane_texture.texture_id),
                .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 },
                paletteColor(theme.COLOR_WHITE),
                null,
            ) catch {};
            return;
        }
    }

    // Fall back to the full pane bounds while the browser frame has not arrived yet.
    renderPanePlaceholder();
}

/// Keeps the pane visually blank until the first browser frame arrives.
fn renderPanePlaceholder() void {}
