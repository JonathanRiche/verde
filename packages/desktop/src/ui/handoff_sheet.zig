//! Inline chat-handoff sheet.
//!
//! Replaces the former centered handoff modal: the sheet is a compact card
//! docked to the bottom of the *source* pane (GUI chat or agent TUI) over a
//! pane-local scrim, so the thread being handed off stays visible while the
//! rest of the window stays live. Every choice is a select field with a
//! popover menu, the defaults are already valid, and Enter prepares the draft
//! immediately. Rendered from workspace_panes' pane traversal; hit targets are
//! appended to the shared palette modal-hit list from refreshPaletteModalHits
//! and dispatched by the PaletteModalAction handlers in layout.zig.

const std = @import("std");
const palette = @import("palette");
const sdl = @import("zsdl3");
const runtime = @import("runtime.zig");
const chat_panel = @import("chat_panel.zig");
const handoff_controller = @import("../state/handoff_controller.zig");
const text_measure = @import("text_measure.zig");
const theme = @import("theme.zig");
const utils = @import("../utils.zig");

const log = std.log.scoped(.native_shell);

const Menu = handoff_controller.Menu;

// Above composer pins/file search but below real modals (2000): the sheet is
// pane-local chrome, not a window-blocking modal.
const HANDOFF_SHEET_Z: i32 = 300;

const PROVIDERS = handoff_controller.TARGET_PROVIDERS;
const SURFACE_LABELS = [2][]const u8{ "Gui chat", "Agent tui" };
const CONTEXT_LABELS = [3][]const u8{ "Summary", "Recent messages", "Full transcript" };
const NEW_THREAD_LABEL = "New thread";
const CANCEL_LABEL = "Cancel";
const PREPARE_LABEL = "Prepare draft  ↵";
const MENUS = [_]Menu{ .surface, .provider, .thread, .context };
/// Thread menus list at most this many compatible threads; the rest stay
/// reachable through the most-recent default. Keeps the popover inside a
/// short pane without adding a scrolling list.
const MAX_THREAD_OPTIONS: usize = 8;
const MAX_MENU_OPTIONS: usize = MAX_THREAD_OPTIONS + 1;

// Card geometry (CSS px, scaled at use). On chat panes the card takes the
// composer's content column so it sits on the same axis as the prompt box;
// terminal panes have no composer, so the card uses the pane width instead.
const CARD_MARGIN_CSS: f32 = 12.0;
const CARD_PAD_CSS: f32 = 16.0;
const SELECT_H_CSS: f32 = 30.0;
const SELECT_GAP_CSS: f32 = 6.0;
const SELECT_PAD_X_CSS: f32 = 10.0;
const SELECT_CARET_W_CSS: f32 = 16.0;
/// Provider mark slot inside selects and menu rows; matches the composer's
/// model pill so the same logo bitmaps read at the same size.
const PROVIDER_LOGO_CSS: f32 = 16.0;
const PROVIDER_LOGO_GAP_CSS: f32 = 6.0;
const SELECT_MIN_THREAD_W_CSS: f32 = 120.0;
const MENU_ITEM_H_CSS: f32 = 28.0;
const MENU_PAD_CSS: f32 = 4.0;
const MENU_MIN_W_CSS: f32 = 180.0;
const BUTTON_H_CSS: f32 = 30.0;
const BUTTON_PAD_X_CSS: f32 = 16.0;
const BUTTON_MIN_W_CSS: f32 = 84.0;
const PREVIEW_LINE_H_CSS: f32 = 15.0;
const PREVIEW_LINES: f32 = 6.0;
const SELECT_FONT_CSS: f32 = 12.5;
const TITLE_FONT_CSS: f32 = 14.0;
const HINT_FONT_CSS: f32 = 11.5;
const MONO_FONT_CSS: f32 = 11.0;

const SheetLayout = struct {
    card: palette.Rect,
    header_y: f32,
    selects: [MENUS.len]palette.Rect,
    /// Present only while the preview is expanded.
    preview: ?palette.Rect,
    preview_toggle: palette.Rect,
    cancel: palette.Rect,
    prepare: palette.Rect,
    /// Popover for the open select, if any.
    menu: ?MenuLayout,
};

const MenuLayout = struct {
    kind: Menu,
    frame: palette.Rect,
    items: [MAX_MENU_OPTIONS]palette.Rect,
    count: usize,
};

/// Renders the handoff sheet docked inside `pane_rect` when a handoff is
/// active for that pane. Safe to call for every pane; it no-ops otherwise.
pub fn renderForPane(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, pane_rect: palette.Rect) void {
    if (!state.handoff_controller.sheet_open) return;
    if (state.handoff_controller.source_pane_id != pane_id) return;
    if (state.handoff_controller.project_index >= state.project_controller.projects.items.len) {
        state.cancelHandoff();
        return;
    }

    const previous_z = state.palette_overlay_batch.setZIndex(HANDOFF_SHEET_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    // Pane-local scrim: dims only the source pane so the sheet reads as
    // focused without blocking the rest of the window.
    roundedRect(state, pane_rect, theme.scrim(0.42), 0.0, pane_rect);
    const layout = computeLayout(state, pane_rect);
    drawSheet(state, &layout);
    if (layout.menu) |*menu| drawMenu(state, menu, pane_rect);
}

/// Registers the sheet's hit targets against the pane rect recorded by the
/// previous frame's workspace render. Called from refreshPaletteModalHits
/// before SDL input is processed; render must not register hits because that
/// list is cleared after render and before input.
pub fn registerHitsForPane(state: *runtime.AppState, pane_rect: palette.Rect) void {
    if (!state.handoff_controller.sheet_open) return;
    if (state.handoff_controller.project_index >= state.project_controller.projects.items.len) return;
    registerHits(state, pane_rect, &computeLayout(state, pane_rect));
}

/// Opens the select at `index` (MENUS order) or closes it when already open.
pub fn toggleMenu(state: *runtime.AppState, index: usize) void {
    if (index >= MENUS.len) return;
    const menu = MENUS[index];
    state.handoff_controller.focus_index = index;
    if (state.handoff_controller.menu == menu) {
        state.setHandoffMenu(null);
    } else {
        openMenu(state, menu);
    }
}

fn openMenu(state: *runtime.AppState, menu: Menu) void {
    state.handoff_controller.menu_highlight = menuSelectedIndex(state, menu);
    state.setHandoffMenu(menu);
}

/// Keyboard model: Tab/Shift+Tab and Left/Right move between selects;
/// Up/Down open the focused select and walk its options; Space toggles it;
/// Enter inside an open menu applies the highlighted option. Enter with no
/// menu open is left to the caller, which prepares the draft.
pub fn handleKeyDown(state: *runtime.AppState, event: *const sdl.KeyboardEvent) bool {
    const controller = &state.handoff_controller;
    const shift = (keymodBits(event.mod) & sdl.Keymod.shift) != 0;
    switch (event.key) {
        .tab => {
            moveFocus(state, if (shift) -1 else 1);
            return true;
        },
        .left => {
            moveFocus(state, -1);
            return true;
        },
        .right => {
            moveFocus(state, 1);
            return true;
        },
        .up, .down => {
            const delta: i32 = if (event.key == .up) -1 else 1;
            if (controller.menu) |menu| {
                const count = menuOptionCount(state, menu);
                if (count == 0) return true;
                const current: i32 = @intCast(@min(controller.menu_highlight, count - 1));
                controller.menu_highlight = @intCast(@mod(current + delta, @as(i32, @intCast(count))));
                state.markDirty();
            } else {
                openMenu(state, MENUS[@min(controller.focus_index, MENUS.len - 1)]);
            }
            return true;
        },
        .space => {
            toggleMenu(state, controller.focus_index);
            return true;
        },
        .@"return", .kp_enter => {
            if (controller.menu != null) {
                applyMenuOption(state, controller.menu_highlight);
                return true;
            }
            return false;
        },
        else => return false,
    }
}

fn moveFocus(state: *runtime.AppState, delta: i32) void {
    const controller = &state.handoff_controller;
    const current: i32 = @intCast(@min(controller.focus_index, MENUS.len - 1));
    controller.focus_index = @intCast(@mod(current + delta, @as(i32, @intCast(MENUS.len))));
    // Moving focus closes an open menu; the next Up/Down reopens on the new field.
    state.setHandoffMenu(null);
    state.markDirty();
}

fn keymodBits(modifier_state: sdl.Keymod) u16 {
    return @as(*const u16, @ptrCast(&modifier_state)).*;
}

/// Applies option `index` of the open select and closes the menu.
pub fn applyMenuOption(state: *runtime.AppState, index: usize) void {
    const menu = state.handoff_controller.menu orelse return;
    state.setHandoffMenu(null);
    switch (menu) {
        .surface => state.setHandoffTargetSurface(if (index == 0) .gui_chat else .tui),
        .provider => if (index < PROVIDERS.len) state.setHandoffTargetProvider(PROVIDERS[index]),
        .thread => if (index == 0) {
            state.setHandoffUseExisting(false);
        } else if (state.handoffCompatibleTargetThreadAt(index - 1)) |thread_index| {
            state.selectHandoffExistingTarget(thread_index);
        },
        .context => state.setHandoffContextMode(switch (index) {
            0 => .summary,
            1 => .recent,
            else => .full,
        }),
    }
}

// The card docks to the pane bottom, capped in width and centered. Collapsed
// it is header + one select row + footer; the preview adds a fixed block
// only while expanded, and the card clips instead of overlapping its footer
// when the pane is too short.
fn computeLayout(state: *runtime.AppState, pane_rect: palette.Rect) SheetLayout {
    const margin = theme.scaledUi(CARD_MARGIN_CSS);
    const pad = theme.scaledUi(CARD_PAD_CSS);
    const select_h = theme.scaledUi(SELECT_H_CSS);
    const select_gap = theme.scaledUi(SELECT_GAP_CSS);
    const button_h = theme.scaledUi(BUTTON_H_CSS);
    const header_h = theme.scaledUi(20.0);
    const block_gap = theme.scaledUi(12.0);
    const preview_h = theme.scaledUi(PREVIEW_LINE_H_CSS) * PREVIEW_LINES + theme.scaledUi(12.0);

    const column = sheetColumn(state, pane_rect);
    var card_h = pad + header_h + block_gap + select_h + block_gap + button_h + pad;
    if (state.handoff_controller.preview_expanded) card_h += preview_h + block_gap;
    const available_h = pane_rect.h - margin * 2.0;
    card_h = @min(card_h, @max(available_h, theme.scaledUi(160.0)));

    const card: palette.Rect = .{
        .x = column.x,
        .y = pane_rect.y + pane_rect.h - margin - card_h,
        .w = column.w,
        .h = card_h,
    };
    const content_x = card.x + pad;
    const content_w = card.w - pad * 2.0;

    var y = card.y + pad;
    const header_y = y;
    y += header_h + block_gap;

    // Select row: fixed-choice selects take their measured width; the thread
    // select flexes into the remainder because thread titles are unbounded.
    var selects: [MENUS.len]palette.Rect = undefined;
    var fixed_w: f32 = 0.0;
    for (MENUS, 0..) |menu, index| {
        selects[index].w = if (menu == .thread) 0.0 else selectWidth(state, menu);
        fixed_w += selects[index].w;
    }
    const gaps_w = select_gap * @as(f32, @floatFromInt(MENUS.len - 1));
    var thread_w = content_w - fixed_w - gaps_w;
    const min_thread_w = theme.scaledUi(SELECT_MIN_THREAD_W_CSS);
    // On narrow panes shrink the fixed selects proportionally so the thread
    // select keeps a readable floor; labels then truncate inside.
    var scale: f32 = 1.0;
    if (thread_w < min_thread_w and fixed_w > 0.0) {
        scale = @max((content_w - gaps_w - min_thread_w) / fixed_w, 0.35);
        thread_w = content_w - fixed_w * scale - gaps_w;
    }
    var cursor = content_x;
    for (MENUS, 0..) |menu, index| {
        const w = if (menu == .thread) thread_w else selects[index].w * scale;
        selects[index] = .{ .x = cursor, .y = y, .w = w, .h = select_h };
        cursor += w + select_gap;
    }
    y += select_h + block_gap;

    var preview: ?palette.Rect = null;
    if (state.handoff_controller.preview_expanded) {
        preview = .{ .x = content_x, .y = y, .w = content_w, .h = preview_h };
        y += preview_h + block_gap;
    }

    const button_y = y;
    const prepare_w = buttonWidth(PREPARE_LABEL);
    const cancel_w = buttonWidth(CANCEL_LABEL);
    const prepare: palette.Rect = .{ .x = content_x + content_w - prepare_w, .y = button_y, .w = prepare_w, .h = button_h };
    const cancel: palette.Rect = .{ .x = prepare.x - theme.scaledUi(8.0) - cancel_w, .y = button_y, .w = cancel_w, .h = button_h };
    const preview_toggle: palette.Rect = .{
        .x = content_x,
        .y = button_y,
        .w = @max(cancel.x - theme.scaledUi(12.0) - content_x, theme.scaledUi(60.0)),
        .h = button_h,
    };

    var layout: SheetLayout = .{
        .card = card,
        .header_y = header_y,
        .selects = selects,
        .preview = preview,
        .preview_toggle = preview_toggle,
        .cancel = cancel,
        .prepare = prepare,
        .menu = null,
    };
    if (state.handoff_controller.menu) |menu| layout.menu = computeMenuLayout(state, menu, layout.selects[menuIndex(menu)], pane_rect);
    return layout;
}

/// Horizontal span of the card: the chat composer's column when the source
/// pane is a chat, otherwise the pane inset by the card margin.
fn sheetColumn(state: *runtime.AppState, pane_rect: palette.Rect) struct { x: f32, w: f32 } {
    const kind = state.workspacePaneKindById(state.handoff_controller.source_pane_id);
    if (kind == .chat) {
        const column = chat_panel.chatContentColumn(pane_rect.x, pane_rect.w);
        return .{ .x = column.x, .w = column.w };
    }
    const margin = theme.scaledUi(CARD_MARGIN_CSS);
    return .{ .x = pane_rect.x + margin, .w = @max(pane_rect.w - margin * 2.0, theme.scaledUi(220.0)) };
}

// Popover opens upward from its select (the sheet sits at the pane bottom)
// and falls back to opening downward when the pane above is too short.
fn computeMenuLayout(state: *runtime.AppState, kind: Menu, anchor: palette.Rect, pane_rect: palette.Rect) MenuLayout {
    const item_h = theme.scaledUi(MENU_ITEM_H_CSS);
    const menu_pad = theme.scaledUi(MENU_PAD_CSS);
    const count = menuOptionCount(state, kind);
    var width = @max(anchor.w, theme.scaledUi(MENU_MIN_W_CSS));
    var option_index: usize = 0;
    while (option_index < count) : (option_index += 1) {
        var label_buf: [256]u8 = undefined;
        var natural = text_measure.textWidth(.ui, theme.scaledUi(SELECT_FONT_CSS), menuOptionLabel(state, kind, option_index, &label_buf)) + theme.scaledUi(SELECT_PAD_X_CSS) * 2.0 + theme.scaledUi(20.0);
        if (kind == .provider) natural += theme.scaledUi(PROVIDER_LOGO_CSS) + theme.scaledUi(PROVIDER_LOGO_GAP_CSS);
        width = @max(width, natural);
    }
    width = @min(width, pane_rect.w - theme.scaledUi(CARD_MARGIN_CSS) * 2.0);
    const height = item_h * @as(f32, @floatFromInt(count)) + menu_pad * 2.0;
    const x = theme.clampf(anchor.x, pane_rect.x + theme.scaledUi(CARD_MARGIN_CSS), pane_rect.x + pane_rect.w - theme.scaledUi(CARD_MARGIN_CSS) - width);
    const above_y = anchor.y - theme.scaledUi(4.0) - height;
    const y = if (above_y >= pane_rect.y + theme.scaledUi(4.0)) above_y else anchor.y + anchor.h + theme.scaledUi(4.0);
    const frame: palette.Rect = .{ .x = x, .y = y, .w = width, .h = height };

    var items: [MAX_MENU_OPTIONS]palette.Rect = undefined;
    option_index = 0;
    while (option_index < count) : (option_index += 1) {
        items[option_index] = .{
            .x = frame.x + menu_pad,
            .y = frame.y + menu_pad + item_h * @as(f32, @floatFromInt(option_index)),
            .w = frame.w - menu_pad * 2.0,
            .h = item_h,
        };
    }
    return .{ .kind = kind, .frame = frame, .items = items, .count = count };
}

fn menuIndex(menu: Menu) usize {
    for (MENUS, 0..) |candidate, index| {
        if (candidate == menu) return index;
    }
    unreachable;
}

fn menuOptionCount(state: *runtime.AppState, menu: Menu) usize {
    return switch (menu) {
        .surface => SURFACE_LABELS.len,
        .provider => PROVIDERS.len,
        .context => CONTEXT_LABELS.len,
        .thread => blk: {
            var count: usize = 0;
            while (count < MAX_THREAD_OPTIONS and state.handoffCompatibleTargetThreadAt(count) != null) : (count += 1) {}
            break :blk count + 1;
        },
    };
}

fn menuOptionLabel(state: *runtime.AppState, menu: Menu, index: usize, buf: *[256]u8) []const u8 {
    return switch (menu) {
        .surface => SURFACE_LABELS[@min(index, SURFACE_LABELS.len - 1)],
        .provider => providerLabel(PROVIDERS[@min(index, PROVIDERS.len - 1)]),
        .context => CONTEXT_LABELS[@min(index, CONTEXT_LABELS.len - 1)],
        .thread => blk: {
            if (index == 0) break :blk NEW_THREAD_LABEL;
            const thread_index = state.handoffCompatibleTargetThreadAt(index - 1) orelse break :blk "";
            const project = &state.project_controller.projects.items[state.handoff_controller.project_index];
            const title = project.threads.items[thread_index].title;
            break :blk std.fmt.bufPrint(buf, "{s}", .{title}) catch title;
        },
    };
}

fn menuSelectedIndex(state: *runtime.AppState, menu: Menu) usize {
    const controller = &state.handoff_controller;
    return switch (menu) {
        .surface => if (controller.target_surface == .gui_chat) 0 else 1,
        .provider => blk: {
            for (PROVIDERS, 0..) |provider, index| {
                if (provider == controller.target_provider) break :blk index;
            }
            break :blk 0;
        },
        .context => switch (controller.context_mode) {
            .summary => 0,
            .recent => 1,
            .full => 2,
        },
        .thread => blk: {
            if (!controller.use_existing) break :blk 0;
            const target = controller.target_thread_index orelse break :blk 0;
            var n: usize = 0;
            while (state.handoffCompatibleTargetThreadAt(n)) |thread_index| : (n += 1) {
                if (thread_index == target) break :blk n + 1;
            }
            break :blk 0;
        },
    };
}

/// The caption shown inside a select before its value.
fn menuCaption(menu: Menu) []const u8 {
    return switch (menu) {
        .surface => "To",
        .provider => "Provider",
        .thread => "Thread",
        .context => "Context",
    };
}

/// Current value shown inside a select.
fn menuValueLabel(state: *runtime.AppState, menu: Menu) []const u8 {
    return switch (menu) {
        .surface => SURFACE_LABELS[menuSelectedIndex(state, .surface)],
        .provider => providerLabel(state.handoff_controller.target_provider),
        .context => CONTEXT_LABELS[menuSelectedIndex(state, .context)],
        .thread => if (state.handoff_controller.use_existing) state.handoffExistingTargetLabel() else NEW_THREAD_LABEL,
    };
}

// Fixed-choice selects are sized for their widest option so the row does not
// jump when the value changes.
fn selectWidth(state: *runtime.AppState, menu: Menu) f32 {
    const font_size = theme.scaledUi(SELECT_FONT_CSS);
    const caption_w = text_measure.textWidth(.ui, theme.scaledUi(HINT_FONT_CSS), menuCaption(menu));
    var widest: f32 = 0.0;
    const count = menuOptionCount(state, menu);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var label_buf: [256]u8 = undefined;
        widest = @max(widest, text_measure.textWidth(.ui, font_size, menuOptionLabel(state, menu, index, &label_buf)));
    }
    const logo_w = if (menu == .provider) theme.scaledUi(PROVIDER_LOGO_CSS) + theme.scaledUi(PROVIDER_LOGO_GAP_CSS) else 0.0;
    return theme.scaledUi(SELECT_PAD_X_CSS) * 2.0 + caption_w + theme.scaledUi(8.0) + logo_w + widest + theme.scaledUi(SELECT_CARET_W_CSS);
}

fn buttonWidth(label: []const u8) f32 {
    const natural = text_measure.textWidth(.ui, theme.scaledUi(13.0), label) + theme.scaledUi(BUTTON_PAD_X_CSS) * 2.0;
    return @max(natural, theme.scaledUi(BUTTON_MIN_W_CSS));
}

fn drawSheet(state: *runtime.AppState, layout: *const SheetLayout) void {
    const project = &state.project_controller.projects.items[state.handoff_controller.project_index];
    const card = layout.card;
    const clip = card;
    const pad = theme.scaledUi(CARD_PAD_CSS);
    const radius = theme.scaledUi(12.0);
    const content_x = card.x + pad;
    const content_w = card.w - pad * 2.0;

    // Card surface derives from the always-dark theme background (not
    // panel_alt, which omarchy themes may source from light terminal
    // colors) so the text tokens keep their contrast, matching the palette.
    roundedRect(state, card, theme.lighten(theme.background(), 0.04), radius, clip);
    border(state, card, theme.COLOR_PANEL_MUTED, radius, theme.scaledUi(1.0), clip);

    // Header: bold title, source in muted text on the same line, key hints right.
    const header_h = theme.scaledUi(20.0);
    const title = "Handoff";
    const title_size = theme.scaledUi(TITLE_FONT_CSS);
    const title_w = text_measure.textWidth(.ui_bold, title_size, title);
    labelText(state, .{ .x = content_x, .y = layout.header_y, .w = title_w + theme.scaledUi(2.0), .h = header_h }, title, theme.COLOR_WHITE, title_size, .ui_bold, clip);
    const hint = "Tab / ↑↓ choose    Enter prepare    Esc cancel";
    const hint_size = theme.scaledUi(HINT_FONT_CSS);
    const hint_w = text_measure.textWidth(.ui, hint_size, hint);
    labelText(state, .{ .x = content_x + content_w - hint_w, .y = layout.header_y + theme.scaledUi(2.0), .w = hint_w + theme.scaledUi(2.0), .h = header_h }, hint, theme.COLOR_TEXT_SUBTLE, hint_size, .ui, clip);
    var source_buf: [512]u8 = undefined;
    const source = std.fmt.bufPrint(&source_buf, "from {s} · pane {d} · {s}", .{
        project.label,
        state.handoff_controller.source_pane_id,
        providerLabel(state.handoff_controller.source_provider),
    }) catch "from the source pane";
    const source_x = content_x + title_w + theme.scaledUi(8.0);
    var source_label_buf: [512]u8 = undefined;
    const source_label = truncatedLabel(&source_label_buf, source, content_x + content_w - hint_w - theme.scaledUi(16.0) - source_x, theme.scaledUi(12.0));
    labelText(state, .{ .x = source_x, .y = layout.header_y + theme.scaledUi(1.0), .w = text_measure.textWidth(.ui, theme.scaledUi(12.0), source_label) + theme.scaledUi(2.0), .h = header_h }, source_label, theme.COLOR_TEXT_MUTED, theme.scaledUi(12.0), .ui, clip);

    const mouse_x = state.transcript_controller.palette_mouse_x;
    const mouse_y = state.transcript_controller.palette_mouse_y;
    for (MENUS, layout.selects, 0..) |menu, rect, index| {
        const open = state.handoff_controller.menu == menu;
        const focused = state.handoff_controller.focus_index == index;
        drawSelect(state, rect, menu, open, focused, pointInRect(mouse_x, mouse_y, rect), clip);
    }

    if (layout.preview) |preview| drawPreview(state, preview, clip);

    drawPreviewToggle(state, layout.preview_toggle, pointInRect(mouse_x, mouse_y, layout.preview_toggle), clip);
    drawSecondaryButton(state, layout.cancel, CANCEL_LABEL, clip);
    drawActionButton(state, layout.prepare, PREPARE_LABEL, clip);
}

// A select shows "Caption  Value ▾"; open state borrows the accent so the
// popover reads as attached to it.
fn drawSelect(state: *runtime.AppState, rect: palette.Rect, menu: Menu, open: bool, focused: bool, hovered: bool, clip: palette.Rect) void {
    const radius = theme.scaledUi(7.0);
    roundedRect(state, rect, if (hovered or open) controlHoverSurface() else controlSurface(), radius, clip);
    // Open and keyboard-focused fields share the accent ring so the key
    // model is discoverable; focus is drawn thinner than open.
    const ring = if (open) theme.withAlpha(theme.accent(), 170) else if (focused) theme.withAlpha(theme.accent(), 120) else theme.withAlpha(theme.COLOR_WHITE, if (hovered) 40 else 24);
    border(state, rect, ring, radius, theme.scaledUi(1.0), clip);

    const pad_x = theme.scaledUi(SELECT_PAD_X_CSS);
    const caret_w = theme.scaledUi(SELECT_CARET_W_CSS);
    const caption = menuCaption(menu);
    const caption_size = theme.scaledUi(HINT_FONT_CSS);
    const caption_w = text_measure.textWidth(.ui, caption_size, caption);
    const value_size = theme.scaledUi(SELECT_FONT_CSS);
    const inner = intersect(clip, rect);
    var x = rect.x + pad_x;
    labelText(state, .{ .x = x, .y = rect.y + (rect.h - caption_size * 1.25) * 0.5, .w = caption_w + theme.scaledUi(2.0), .h = caption_size * 1.25 }, caption, theme.COLOR_TEXT_SUBTLE, caption_size, .ui, inner);
    x += caption_w + theme.scaledUi(8.0);
    if (menu == .provider) {
        x += drawProviderLogo(state, state.handoff_controller.target_provider, x, rect.y, rect.h, inner);
    }

    const value_max_w = @max(rect.x + rect.w - caret_w - x, theme.scaledUi(12.0));
    var value_buf: [256]u8 = undefined;
    const value = truncatedLabel(&value_buf, menuValueLabel(state, menu), value_max_w, value_size);
    const value_w = @min(text_measure.textWidth(.ui, value_size, value), value_max_w);
    labelText(state, .{ .x = x, .y = rect.y + (rect.h - value_size * 1.25) * 0.5, .w = value_w + theme.scaledUi(2.0), .h = value_size * 1.25 }, value, theme.COLOR_WHITE, value_size, .ui, inner);

    drawCaret(state, .{ .x = rect.x + rect.w - caret_w, .y = rect.y, .w = caret_w - theme.scaledUi(4.0), .h = rect.h }, open, if (hovered or open) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED, inner);
}

/// Draws the provider's logo vertically centered in a row starting at `x`
/// and returns the horizontal advance (slot + gap). Falls back to the
/// provider initial when the bitmap is unavailable so alignment never shifts.
fn drawProviderLogo(state: *runtime.AppState, provider: runtime.Provider, x: f32, row_y: f32, row_h: f32, clip: palette.Rect) f32 {
    const slot = theme.scaledUi(PROVIDER_LOGO_CSS);
    const slot_rect: palette.Rect = .{ .x = x, .y = row_y + (row_h - slot) * 0.5, .w = slot, .h = slot };
    if (providerLogo(state, provider)) |cached| {
        const r = utils.snapImageRectToPixels(utils.imageRectContain(cached.width, cached.height, slot_rect.x, slot_rect.y, slot_rect.w, slot_rect.h));
        queueImage(state, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, cached, clip);
    } else {
        const initial = providerLabel(provider)[0..1];
        centeredLabel(state, slot_rect, initial, theme.COLOR_TEXT_MUTED, theme.scaledUi(11.0), clip);
    }
    return slot + theme.scaledUi(PROVIDER_LOGO_GAP_CSS);
}

fn providerLogo(state: *runtime.AppState, provider: runtime.Provider) ?runtime.CachedImageTexture {
    const cached = state.providerLogoTexture(provider) orelse return null;
    if (!cached.valid or cached.texture_id == 0) return null;
    return cached;
}

fn queueImage(state: *runtime.AppState, rect: palette.Rect, texture: runtime.CachedImageTexture, clip: palette.Rect) void {
    state.palette_overlay_batch.image(state.allocator, snapRect(rect), palette.TextureId.init(texture.texture_id), .{
        .x = 0.0,
        .y = 0.0,
        .w = 1.0,
        .h = 1.0,
    }, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }, clip) catch |err| {
        log.warn("failed to queue handoff sheet logo: {s}", .{@errorName(err)});
    };
}

// Small chevron drawn from two rotated bars is not available in the batch;
// use the glyph so it inherits the UI face's hinting.
fn drawCaret(state: *runtime.AppState, rect: palette.Rect, open: bool, color: [4]f32, clip: palette.Rect) void {
    const glyph = if (open) "▴" else "▾";
    const size = theme.scaledUi(11.0);
    const w = text_measure.textWidth(.ui, size, glyph);
    labelText(state, .{ .x = rect.x + (rect.w - w) * 0.5, .y = rect.y + (rect.h - size * 1.25) * 0.5, .w = w + theme.scaledUi(2.0), .h = size * 1.25 }, glyph, color, size, .ui, clip);
}

fn drawMenu(state: *runtime.AppState, menu: *const MenuLayout, pane_clip: palette.Rect) void {
    const radius = theme.scaledUi(8.0);
    roundedRect(state, menu.frame, theme.lighten(theme.background(), 0.08), radius, pane_clip);
    border(state, menu.frame, theme.withAlpha(theme.COLOR_WHITE, 34), radius, theme.scaledUi(1.0), pane_clip);

    const mouse_x = state.transcript_controller.palette_mouse_x;
    const mouse_y = state.transcript_controller.palette_mouse_y;
    const selected = menuSelectedIndex(state, menu.kind);
    const highlight = @min(state.handoff_controller.menu_highlight, menu.count -| 1);
    const font_size = theme.scaledUi(SELECT_FONT_CSS);
    const pad_x = theme.scaledUi(SELECT_PAD_X_CSS);
    const mark_w = theme.scaledUi(16.0);
    for (menu.items[0..menu.count], 0..) |item, index| {
        const hovered = pointInRect(mouse_x, mouse_y, item) or index == highlight;
        const is_selected = index == selected;
        if (hovered) {
            roundedRect(state, item, controlHoverSurface(), theme.scaledUi(5.0), pane_clip);
        } else if (is_selected) {
            roundedRect(state, item, theme.withAlpha(theme.accent(), 40), theme.scaledUi(5.0), pane_clip);
        }
        if (is_selected) {
            const mark = "✓";
            const mark_size = theme.scaledUi(11.0);
            labelText(state, .{ .x = item.x + pad_x, .y = item.y + (item.h - mark_size * 1.25) * 0.5, .w = mark_w, .h = mark_size * 1.25 }, mark, theme.accent(), mark_size, .ui, pane_clip);
        }
        var label_buf: [256]u8 = undefined;
        const raw = menuOptionLabel(state, menu.kind, index, &label_buf);
        var text_x = item.x + pad_x + mark_w;
        if (menu.kind == .provider and index < PROVIDERS.len) {
            text_x += drawProviderLogo(state, PROVIDERS[index], text_x, item.y, item.h, pane_clip);
        }
        var fit_buf: [256]u8 = undefined;
        const label = truncatedLabel(&fit_buf, raw, item.x + item.w - pad_x - text_x, font_size);
        const color = if (hovered or is_selected) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
        labelText(state, .{ .x = text_x, .y = item.y + (item.h - font_size * 1.25) * 0.5, .w = text_measure.textWidth(.ui, font_size, label) + theme.scaledUi(2.0), .h = font_size * 1.25 }, label, color, font_size, .ui, pane_clip);
    }
}

// Footer-left disclosure: "▸ Preview · 9.1 KB · model gpt-5" toggles the
// package preview block. It doubles as the model readout so the collapsed
// sheet still shows what the draft will target.
fn drawPreviewToggle(state: *runtime.AppState, rect: palette.Rect, hovered: bool, clip: palette.Rect) void {
    const expanded = state.handoff_controller.preview_expanded;
    var buf: [256]u8 = undefined;
    const bytes = state.handoffPreviewText().len;
    const label = if (bytes >= 1024)
        std.fmt.bufPrint(&buf, "{s} Preview · {d:.1} KB · model {s}", .{ if (expanded) "▾" else "▸", @as(f32, @floatFromInt(bytes)) / 1024.0, state.handoffTargetModelLabel() }) catch "Preview"
    else
        std.fmt.bufPrint(&buf, "{s} Preview · {d} B · model {s}", .{ if (expanded) "▾" else "▸", bytes, state.handoffTargetModelLabel() }) catch "Preview";
    const font_size = theme.scaledUi(HINT_FONT_CSS);
    var fit_buf: [256]u8 = undefined;
    const fitted = truncatedLabel(&fit_buf, label, rect.w, font_size);
    const w = text_measure.textWidth(.ui, font_size, fitted);
    labelText(state, .{ .x = rect.x, .y = rect.y + (rect.h - font_size * 1.25) * 0.5, .w = w + theme.scaledUi(2.0), .h = font_size * 1.25 }, fitted, if (hovered or expanded) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED, font_size, .ui, clip);
}

fn drawPreview(state: *runtime.AppState, rect: palette.Rect, clip: palette.Rect) void {
    const radius = theme.scaledUi(8.0);
    const inset = theme.scaledUi(10.0);
    roundedRect(state, rect, theme.darken(theme.background(), 0.02), radius, clip);
    border(state, rect, theme.withAlpha(theme.COLOR_PANEL_MUTED, 190), radius, theme.scaledUi(1.0), clip);

    // Preview body renders the package in the mono face so it reads like the
    // draft the target will receive; lines clip inside the preview box.
    const body_clip = intersect(clip, .{ .x = rect.x, .y = rect.y + theme.scaledUi(6.0), .w = rect.w, .h = rect.h - theme.scaledUi(12.0) });
    const line_h = theme.scaledUi(PREVIEW_LINE_H_CSS);
    var lines = std.mem.splitScalar(u8, state.handoffPreviewText(), '\n');
    var line_y = body_clip.y;
    while (lines.next()) |line| {
        if (line_y >= body_clip.y + body_clip.h) break;
        if (line.len > 0) {
            labelText(state, .{ .x = rect.x + inset, .y = line_y, .w = rect.w - inset * 2.0, .h = line_h }, line, theme.COLOR_TEXT_MUTED, theme.scaledUi(MONO_FONT_CSS), .mono, body_clip);
        }
        line_y += line_h;
    }
}

// --- Buttons (theme-derived colors only, matching Settings). ---

fn controlSurface() [4]f32 {
    return theme.mix(theme.background(), theme.COLOR_WHITE, 0.14);
}

fn controlHoverSurface() [4]f32 {
    return theme.mix(theme.background(), theme.COLOR_WHITE, 0.20);
}

fn drawSecondaryButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, clip: palette.Rect) void {
    const hovered = pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, rect);
    const radius = theme.scaledUi(7.0);
    roundedRect(state, rect, if (hovered) controlHoverSurface() else controlSurface(), radius, clip);
    border(state, rect, theme.withAlpha(theme.COLOR_WHITE, 30), radius, theme.scaledUi(1.0), clip);
    centeredLabel(state, rect, label, theme.COLOR_WHITE, theme.scaledUi(13.0), clip);
}

fn drawActionButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, clip: palette.Rect) void {
    const hovered = pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, rect);
    const accent = theme.accent();
    const fill = if (hovered) theme.mix(accent, theme.foregroundOn(accent), 0.10) else accent;
    roundedRect(state, rect, fill, theme.scaledUi(7.0), clip);
    centeredLabel(state, rect, label, theme.foregroundOn(fill), theme.scaledUi(13.0), clip);
}

/// Centers `value` in `rect` using measured width, truncating with an
/// ellipsis when the control is narrower than the label.
fn centeredLabel(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: [4]f32, font_size: f32, clip: palette.Rect) void {
    const inner_w = @max(rect.w - theme.scaledUi(8.0), theme.scaledUi(4.0));
    var label_buf: [160]u8 = undefined;
    const label = truncatedLabel(&label_buf, value, inner_w, font_size);
    const text_w = @min(text_measure.textWidth(.ui, font_size, label), inner_w);
    const text_h = font_size * 1.25;
    labelText(state, .{
        .x = rect.x + (rect.w - text_w) * 0.5,
        .y = rect.y + (rect.h - text_h) * 0.5,
        .w = text_w + theme.scaledUi(2.0),
        .h = text_h,
    }, label, color, font_size, .ui, intersect(clip, rect));
}

/// Truncates `label` with a trailing ellipsis so it fits `max_w` using
/// Palette text metrics, cutting only at UTF-8 codepoint boundaries.
fn truncatedLabel(buffer: []u8, label: []const u8, max_w: f32, font_size: f32) []const u8 {
    const ellipsis = "…";
    const bounded = label[0..@min(label.len, buffer.len - ellipsis.len)];
    if (bounded.len == label.len and text_measure.textWidth(.ui, font_size, bounded) <= max_w) return label;
    const ellipsis_w = text_measure.textWidth(.ui, font_size, ellipsis);
    var end: usize = 0;
    var fit_end: usize = 0;
    while (end < bounded.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(bounded[end]) catch 1;
        const next = @min(end + cp_len, bounded.len);
        if (text_measure.textPrefixWidth(.ui, bounded, font_size, next) + ellipsis_w > max_w) break;
        fit_end = next;
        end = next;
    }
    @memcpy(buffer[0..fit_end], bounded[0..fit_end]);
    @memcpy(buffer[fit_end .. fit_end + ellipsis.len], ellipsis);
    return buffer[0 .. fit_end + ellipsis.len];
}

fn labelText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: [4]f32, font_size: f32, role: palette.FontRole, clip: palette.Rect) void {
    const stable_value = state.palette_frame_text_arena.allocator().dupe(u8, value) catch return;
    state.palette_overlay_batch.roleText(
        state.allocator,
        snapRect(rect),
        stable_value,
        paletteColor(color),
        font_size,
        role,
        null,
        clip,
    ) catch |err| {
        log.warn("failed to queue handoff sheet text: {s}", .{@errorName(err)});
    };
}

// --- Hit registration and small helpers. ---

fn registerHits(state: *runtime.AppState, pane_rect: palette.Rect, layout: *const SheetLayout) void {
    // Later hits win. With a menu open, anything outside the popover just
    // closes it (standard select behaviour); otherwise the scrim dismisses
    // the sheet and the card body swallows clicks meant for it.
    if (layout.menu) |menu| {
        appendHit(state, pane_rect, .handoff_menu_close, 0);
        appendHit(state, layout.selects[menuIndex(menu.kind)], .handoff_menu_toggle, menuIndex(menu.kind));
        appendHit(state, menu.frame, .modal_block, 0);
        for (menu.items[0..menu.count], 0..) |item, index| appendHit(state, item, .handoff_menu_option, index);
        return;
    }
    appendHit(state, pane_rect, .modal_dismiss, 0);
    appendHit(state, layout.card, .modal_block, 0);
    for (layout.selects, 0..) |rect, index| appendHit(state, rect, .handoff_menu_toggle, index);
    appendHit(state, layout.preview_toggle, .handoff_preview_toggle, 0);
    appendHit(state, layout.cancel, .handoff_cancel, 0);
    appendHit(state, layout.prepare, .handoff_prepare, 0);
}

fn appendHit(state: *runtime.AppState, rect: palette.Rect, action: runtime.PaletteModalAction, index: usize) void {
    state.palette_modal_hits.append(state.allocator, .{ .rect = rect, .action = action, .index = index }) catch |err| {
        log.warn("failed to retain handoff sheet hit: {s}", .{@errorName(err)});
    };
}

fn providerLabel(provider: runtime.Provider) []const u8 {
    return switch (provider) {
        .codex => "Codex",
        .opencode => "OpenCode",
        .claude => "Claude",
        .cursor => "Cursor",
        .pi => "Pi",
        .fx => "FX",
        .grok => "Grok",
        .muse => "Muse",
    };
}

fn pointInRect(x: f32, y: f32, rect: palette.Rect) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn intersect(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
}

fn snapRect(rect: palette.Rect) palette.Rect {
    return .{ .x = @round(rect.x), .y = @round(rect.y), .w = @round(rect.w), .h = @round(rect.h) };
}

fn roundedRect(state: *runtime.AppState, rect: palette.Rect, color: [4]f32, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, paletteColor(color), radius, clip) catch |err| {
        log.warn("failed to queue handoff sheet rect: {s}", .{@errorName(err)});
    };
}

fn border(state: *runtime.AppState, rect: palette.Rect, color: [4]f32, radius: f32, width: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.rectBorderClipped(state.allocator, rect, paletteColor(color), radius, width, clip) catch |err| {
        log.warn("failed to queue handoff sheet border: {s}", .{@errorName(err)});
    };
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

test "menu order maps back to its own index" {
    for (MENUS, 0..) |menu, index| {
        try std.testing.expectEqual(index, menuIndex(menu));
    }
}

test "truncated labels keep the ellipsis inside the buffer" {
    var buf: [8]u8 = undefined;
    const out = truncatedLabel(&buf, "a very long thread title", 0.0, 12.0);
    try std.testing.expect(out.len <= buf.len);
    try std.testing.expect(std.mem.endsWith(u8, out, "…"));
}
