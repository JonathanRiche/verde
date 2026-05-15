//! Palette-only terminal dock shell.

const std = @import("std");
const ghostty_vt = @import("../vendor/ghostty_vt.zig");
const palette = @import("palette");
const sdl = @import("zsdl3");

const app_state = @import("../state.zig");
const colors = @import("colors.zig");
const theme = @import("theme.zig");

const MAX_PANE_HITS = 64;
const MAX_TAB_HITS = 32;
const TERMINAL_CONTEXT_MENU_WIDTH: f32 = 180.0;
const TERMINAL_CONTEXT_MENU_ROW_HEIGHT: f32 = 30.0;
const TERMINAL_CONTEXT_MENU_PAD: f32 = 6.0;

const TerminalContextMenuKind = enum {
    pane,
    tab,
};

const TerminalContextMenuAction = enum {
    new_tab,
    new_claude_tab,
    new_opencode_tab,
    new_codex_tab,
    new_cursor_tab,
    new_custom_tab,
    rename_tab,
    close_tab,
    split_up,
    split_down,
    split_left,
    split_right,
    close_pane,
};

const TerminalGlyphKind = enum {
    text,
    icon,
    powerline,
};

const PaneHit = struct {
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    rect: palette.Rect = .{},
};

const TerminalCellCoord = struct {
    x: usize = 0,
    y: usize = 0,
};

const TerminalSelection = struct {
    active: bool = false,
    dragging: bool = false,
    moved: bool = false,
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    anchor: TerminalCellCoord = .{},
    focus: TerminalCellCoord = .{},
};

const TabHit = struct {
    dock_id: u32 = 0,
    index: usize = 0,
    rect: palette.Rect = .{},
};

const PaneHitTarget = struct {
    dock_id: u32,
    pane_id: u32,
};

const TabHitTarget = struct {
    dock_id: u32,
    index: usize,
};

const ContextMenuHit = struct {
    action: TerminalContextMenuAction = .new_tab,
    rect: palette.Rect = .{},
    enabled: bool = false,
};

const TerminalHitCache = struct {
    pane_count: usize = 0,
    panes: [MAX_PANE_HITS]PaneHit = [_]PaneHit{.{}} ** MAX_PANE_HITS,
    tab_count: usize = 0,
    tabs: [MAX_TAB_HITS]TabHit = [_]TabHit{.{}} ** MAX_TAB_HITS,
    menu_open: bool = false,
    menu_kind: TerminalContextMenuKind = .pane,
    menu_pane_id: u32 = 0,
    menu_tab_index: usize = 0,
    menu_anchor: palette.Rect = .{},
    menu_panel: palette.Rect = .{},
    menu_count: usize = 0,
    menu_hits: [14]ContextMenuHit = [_]ContextMenuHit{.{}} ** 14,
    dock_id: u32 = 0,
};

var hit_cache: TerminalHitCache = .{};
var selection_state: TerminalSelection = .{};

pub fn renderDock(state: *app_state.AppState, width: f32, height: f32) void {
    renderDockAt(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height });
}

pub fn renderDockAt(state: *app_state.AppState, rect: palette.Rect) void {
    resetHitCache();
    renderDockAtForDock(state, rect, 0);
}

pub fn paneHeaderHeight() f32 {
    return 0.0;
}

pub fn renderDockAtForDock(state: *app_state.AppState, rect: palette.Rect, dock_id: u32) void {
    renderDockAtForDockWithReserve(state, rect, dock_id, 0.0);
}

pub fn renderDockAtForDockWithReserve(state: *app_state.AppState, rect: palette.Rect, dock_id: u32, _: f32) void {
    if (state.projects.items.len == 0) return;
    hit_cache.menu_count = 0;
    hit_cache.dock_id = dock_id;
    var dock = state.currentProjectTerminalDockMutable(dock_id) orelse return;
    const dock_bg = if (dock.activeRenderState()) |render_state| rgbPaletteColor(render_state.colors.background, 1.0) else paletteColor(colors.rgba(9, 12, 13, 255));
    queueRounded(state, rect, dock_bg, 0.0);
    queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), 0.0, 1.0);

    if (dock.activeTab()) |tab| {
        renderPaneNode(state, dock, tab.root, rect);
    } else {
        renderStatus(state, rect, "Starting shell...");
    }
    renderContextMenu(state, dock, rect);
    if (dock.takeFocusRequest()) {
        state.requestTerminalDockFocus(dock_id);
    }
}

pub fn handlePaletteKeyDown(state: *app_state.AppState, event: *const sdl.KeyboardEvent) bool {
    if (!terminalCopyShortcut(event) or !selection_state.active) return false;
    return copySelectionToClipboard(state);
}

pub fn handlePaletteMouseMotion(state: *app_state.AppState, x: f32, y: f32) bool {
    if (!selection_state.dragging) return false;
    updateSelectionFocus(state, x, y) orelse return true;
    selection_state.moved = true;
    state.markDirty();
    return true;
}

pub fn handlePaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, button: u8, down: bool) bool {
    if (state.projects.items.len == 0) return false;
    if (button == 1) {
        if (down) {
            if (startSelection(state, x, y)) return true;
        } else if (selection_state.dragging) {
            _ = updateSelectionFocus(state, x, y);
            selection_state.dragging = false;
            if (!selection_state.moved) selection_state.active = false;
            state.markDirty();
            return true;
        }
    }
    if (!down) return false;
    if (button == 1 and hit_cache.menu_open) {
        const dock = state.currentProjectTerminalDockMutable(hit_cache.dock_id) orelse return false;
        var i: usize = 0;
        while (i < hit_cache.menu_count) : (i += 1) {
            const hit = hit_cache.menu_hits[i];
            if (!hit.enabled or !rectContains(hit.rect, x, y)) continue;
            performContextMenuAction(state, dock, hit.action);
            hit_cache.menu_open = false;
            state.markDirty();
            return true;
        }
        if (!rectContains(hit_cache.menu_panel, x, y)) {
            hit_cache.menu_open = false;
            state.markDirty();
            return true;
        }
        return true;
    }

    if (button == 1) {
        if (tabAtPoint(x, y)) |target| {
            hit_cache.dock_id = target.dock_id;
            var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
            dock.selectTab(target.index);
            focusTerminal(state);
            if (dock.consumeWorkspaceChange()) state.markDirty();
            hit_cache.menu_open = false;
            return true;
        }
        if (paneAtPoint(x, y)) |target| {
            hit_cache.dock_id = target.dock_id;
            var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
            dock.focusPane(target.pane_id);
            focusTerminal(state);
            clearSelection();
            if (dock.consumeWorkspaceChange()) state.markDirty();
            hit_cache.menu_open = false;
            return true;
        }
        return false;
    }

    if (button == 3) {
        if (tabAtPoint(x, y)) |target| {
            hit_cache.dock_id = target.dock_id;
            var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
            dock.selectTab(target.index);
            focusTerminal(state);
            openContextMenu(.tab, target.index, 0, x, y);
            if (dock.consumeWorkspaceChange()) state.markDirty();
            return true;
        }
        if (paneAtPoint(x, y)) |target| {
            hit_cache.dock_id = target.dock_id;
            var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
            dock.focusPane(target.pane_id);
            focusTerminal(state);
            clearSelection();
            openContextMenu(.pane, 0, target.pane_id, x, y);
            if (dock.consumeWorkspaceChange()) state.markDirty();
            return true;
        }
    }
    return false;
}

pub fn handlePaletteWheel(state: *app_state.AppState, x: f32, y: f32, wheel_y: f32) bool {
    if (wheel_y == 0.0 or state.projects.items.len == 0) return false;
    if (paneAtPoint(x, y)) |target| {
        hit_cache.dock_id = target.dock_id;
        var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
        dock.focusPane(target.pane_id);
        focusTerminal(state);
        hit_cache.menu_open = false;
        if (dock.handleWheel(state.allocator, target.pane_id, wheel_y)) {
            state.markDirty();
        }
        if (dock.consumeWorkspaceChange()) state.markDirty();
        return true;
    }
    return false;
}

fn renderTabs(state: *app_state.AppState, dock: anytype, header: palette.Rect) void {
    const tab_h = theme.scaledUi(24.0);
    var x = header.x + theme.scaledUi(92.0);
    for (dock.tabs.items, 0..) |_, index| {
        var title_buf: [96]u8 = undefined;
        const label = dock.tabTitle(index, &title_buf);
        const tab_w = theme.clampf(@as(f32, @floatFromInt(label.len)) * theme.scaledUi(7.0) + theme.scaledUi(24.0), theme.scaledUi(72.0), theme.scaledUi(180.0));
        const tab_rect = palette.Rect{ .x = x, .y = header.y + theme.scaledUi(5.0), .w = tab_w, .h = tab_h };
        appendTabHit(index, tab_rect);
        if (index == dock.active_tab_index) queueRounded(state, tab_rect, paletteColor(colors.rgba(23, 30, 32, 255)), theme.scaledUi(6.0));
        queueText(state, .{ .x = tab_rect.x + theme.scaledUi(10.0), .y = tab_rect.y + theme.scaledUi(4.0), .w = tab_rect.w - theme.scaledUi(20.0), .h = tab_rect.h }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), tab_rect);
        x += tab_w + theme.scaledUi(6.0);
        if (x > header.x + header.w - theme.scaledUi(80.0)) break;
    }
}

fn renderPaneNode(state: *app_state.AppState, dock: anytype, node: anytype, rect: palette.Rect) void {
    switch (node.*) {
        .leaf => |leaf| renderPane(state, dock, leaf.id, rect),
        .split => |split| {
            if (split.axis == .vertical) {
                const split_x = rect.x + rect.w * split.ratio;
                renderPaneNode(state, dock, split.first, .{ .x = rect.x, .y = rect.y, .w = split_x - rect.x, .h = rect.h });
                renderPaneNode(state, dock, split.second, .{ .x = split_x, .y = rect.y, .w = rect.x + rect.w - split_x, .h = rect.h });
                queueRect(state, .{ .x = split_x - theme.scaledUi(0.5), .y = rect.y, .w = theme.scaledUi(1.0), .h = rect.h }, paletteColor(theme.COLOR_PANEL_MUTED));
            } else {
                const split_y = rect.y + rect.h * split.ratio;
                renderPaneNode(state, dock, split.first, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = split_y - rect.y });
                renderPaneNode(state, dock, split.second, .{ .x = rect.x, .y = split_y, .w = rect.w, .h = rect.y + rect.h - split_y });
                queueRect(state, .{ .x = rect.x, .y = split_y - theme.scaledUi(0.5), .w = rect.w, .h = theme.scaledUi(1.0) }, paletteColor(theme.COLOR_PANEL_MUTED));
            }
        },
    }
}

fn renderPane(state: *app_state.AppState, dock: anytype, pane_id: u32, rect: palette.Rect) void {
    appendPaneHit(pane_id, rect);
    dock.resizePaneToFit(state.allocator, pane_id, rect.w, rect.h) catch {};
    const focused = if (dock.activePaneConst()) |active| active.id == pane_id and state.terminal_focused else false;
    const render_state = dock.renderStateForPane(pane_id) orelse {
        var status_buf: [192]u8 = undefined;
        queueRect(state, rect, paletteColor(colors.rgba(7, 10, 11, 255)));
        renderStatus(state, rect, dock.statusText(&status_buf));
        return;
    };
    renderViewport(state, pane_id, render_state, rect);
    if (focused) queueBorder(state, rect, paletteColor(theme.COLOR_SECONDARY_GREEN), 0.0, theme.scaledUi(1.0));
}

fn renderViewport(state: *app_state.AppState, pane_id: u32, render_state: *const ghostty_vt.RenderState, rect: palette.Rect) void {
    if (render_state.rows == 0 or render_state.cols == 0) return;
    const cols_f = @as(f32, @floatFromInt(render_state.cols));
    const rows_f = @as(f32, @floatFromInt(render_state.rows));
    const cell_w = @max(rect.w / cols_f, 1.0);
    const cell_h = @max(rect.h / rows_f, 1.0);
    const font_size = terminalFontSizeForCell(cell_w, cell_h);
    const text_y_offset = @max((cell_h - font_size) * 0.34, 0.0);

    queueRect(state, rect, rgbPaletteColor(render_state.colors.background, 1.0));
    const row_data = render_state.row_data.slice();
    const row_cells = row_data.items(.cells);
    const row_selections = row_data.items(.selection);

    for (row_cells, row_selections, 0..) |cells, selection, y| {
        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);
        const row_styles = cells_slice.items(.style);
        const row_graphemes = cells_slice.items(.grapheme);
        const row_y = rect.y + @as(f32, @floatFromInt(y)) * cell_h;
        if (row_y > rect.y + rect.h) break;

        for (raw_cells, 0..) |raw_cell, x| {
            const span = @as(f32, @floatFromInt(cellWidthCells(raw_cell)));
            const cell_rect = terminalCellRect(rect, cell_w, cell_h, x, y, span);
            const cell_style = styleForCell(raw_cell, row_styles, x);
            var bg = cell_style.bg(&raw_cell, &render_state.colors.palette) orelse render_state.colors.background;
            var fg = cell_style.fg(.{ .default = render_state.colors.foreground, .palette = &render_state.colors.palette, .bold = .bright });

            if (selection) |range| {
                if (x >= range[0] and x <= range[1]) bg = blendRgb(bg, render_state.colors.foreground, 0.22);
            }
            if (selectionCoversCell(hit_cache.dock_id, pane_id, x, y)) {
                bg = blendRgb(bg, render_state.colors.foreground, 0.32);
            }
            if (render_state.cursor.viewport) |cursor| {
                if (cursor.x == x and cursor.y == y and render_state.cursor.visible) {
                    if (render_state.cursor.visual_style == .block) {
                        const cursor_fill = render_state.colors.cursor orelse render_state.colors.foreground;
                        bg = blendRgb(bg, cursor_fill, 0.62);
                        fg = render_state.colors.background;
                    } else {
                        drawCursor(state, render_state, cell_rect);
                    }
                }
            }

            if (!rgbEql(bg, render_state.colors.background) or rawCellNeedsFill(raw_cell)) {
                queueRect(state, cell_rect, rgbPaletteColor(bg, 1.0));
            }
            if (!raw_cell.hasText() or raw_cell.wide == .spacer_tail) continue;
            var text_buf: [128]u8 = undefined;
            const text = cellText(raw_cell, graphemesForCell(raw_cell, row_graphemes, x), &text_buf) orelse continue;
            const glyph_kind = terminalGlyphKind(raw_cell.codepoint());
            if (glyph_kind == .powerline) {
                queuePowerlineGlyph(state, cell_rect, raw_cell.codepoint(), rgbPaletteColor(fg, foregroundAlpha(cell_style)), rect);
                continue;
            }
            if (queueTerminalCellGeometry(state, cell_rect, raw_cell.codepoint(), rgbPaletteColor(fg, foregroundAlpha(cell_style)), rect)) {
                continue;
            }
            const text_rect = terminalTextRect(cell_rect, text_y_offset, glyph_kind);
            const draw_font_size = terminalTextFontSize(font_size, glyph_kind);
            queueTerminalText(state, .{
                .x = text_rect.x,
                .y = text_rect.y,
                .w = text_rect.w,
                .h = text_rect.h,
            }, text, rgbPaletteColor(fg, foregroundAlpha(cell_style)), draw_font_size, if (glyph_kind != .text or glyphNeedsRelaxedClip(raw_cell.codepoint())) rect else cell_rect, glyph_kind);
        }
    }
}

fn renderStatus(state: *app_state.AppState, rect: palette.Rect, label: []const u8) void {
    queueText(state, .{
        .x = rect.x + theme.scaledUi(16.0),
        .y = rect.y + theme.scaledUi(18.0),
        .w = rect.w - theme.scaledUi(32.0),
        .h = theme.scaledUi(24.0),
    }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), rect);
}

fn renderContextMenu(state: *app_state.AppState, dock: anytype, dock_rect: palette.Rect) void {
    if (!hit_cache.menu_open) return;
    const mx = state.palette_mouse_x;
    const my = state.palette_mouse_y;
    const mouse_ok = state.palette_mouse_in_workspace;

    var actions: [14]TerminalContextMenuAction = undefined;
    var labels: [14][]const u8 = undefined;
    var enabled: [14]bool = undefined;
    var count: usize = 0;

    actions[count] = .new_tab;
    labels[count] = "New Tab";
    enabled[count] = true;
    count += 1;
    actions[count] = .new_claude_tab;
    labels[count] = "New Claude Tab";
    enabled[count] = true;
    count += 1;
    actions[count] = .new_opencode_tab;
    labels[count] = "New OpenCode Tab";
    enabled[count] = true;
    count += 1;
    actions[count] = .new_codex_tab;
    labels[count] = "New Codex Tab";
    enabled[count] = true;
    count += 1;
    actions[count] = .new_cursor_tab;
    labels[count] = "New Cursor Tab";
    enabled[count] = true;
    count += 1;
    if (state.hasCustomTerminalLaunchProfile()) {
        actions[count] = .new_custom_tab;
        labels[count] = state.customTerminalLaunchProfileLabel();
        enabled[count] = true;
        count += 1;
    }
    if (hit_cache.menu_kind == .tab) {
        actions[count] = .rename_tab;
        labels[count] = "Rename Tab";
        enabled[count] = true;
        count += 1;
        actions[count] = .close_tab;
        labels[count] = "Close Tab";
        enabled[count] = dock.tabs.items.len > 1;
        count += 1;
    } else {
        actions[count] = .split_up;
        labels[count] = "Split Up";
        enabled[count] = true;
        count += 1;
        actions[count] = .split_down;
        labels[count] = "Split Down";
        enabled[count] = true;
        count += 1;
        actions[count] = .split_left;
        labels[count] = "Split Left";
        enabled[count] = true;
        count += 1;
        actions[count] = .split_right;
        labels[count] = "Split Right";
        enabled[count] = true;
        count += 1;
        actions[count] = .close_pane;
        labels[count] = "Close Pane";
        enabled[count] = true;
        count += 1;
    }

    const menu_w = theme.scaledUi(TERMINAL_CONTEXT_MENU_WIDTH);
    const pad = theme.scaledUi(TERMINAL_CONTEXT_MENU_PAD);
    const row_h = theme.scaledUi(TERMINAL_CONTEXT_MENU_ROW_HEIGHT);
    const menu_h = pad * 2.0 + row_h * @as(f32, @floatFromInt(count));
    var menu_x = hit_cache.menu_anchor.x;
    var menu_y = hit_cache.menu_anchor.y;
    if (menu_x + menu_w > dock_rect.x + dock_rect.w) menu_x = dock_rect.x + dock_rect.w - menu_w - theme.scaledUi(4.0);
    if (menu_y + menu_h > dock_rect.y + dock_rect.h) menu_y = dock_rect.y + dock_rect.h - menu_h - theme.scaledUi(4.0);
    menu_x = @max(dock_rect.x + theme.scaledUi(4.0), menu_x);
    menu_y = @max(dock_rect.y + theme.scaledUi(4.0), menu_y);
    hit_cache.menu_panel = .{ .x = menu_x, .y = menu_y, .w = menu_w, .h = menu_h };

    queueRounded(state, hit_cache.menu_panel, paletteColor(colors.rgba(24, 28, 30, 255)), theme.scaledUi(8.0));
    queueBorder(state, hit_cache.menu_panel, paletteColor(colors.rgba(74, 84, 88, 255)), theme.scaledUi(8.0), theme.scaledUi(1.0));

    hit_cache.menu_count = count;
    var i: usize = 0;
    var y = menu_y + pad;
    while (i < count) : (i += 1) {
        const row = palette.Rect{ .x = menu_x + pad, .y = y, .w = menu_w - pad * 2.0, .h = row_h };
        hit_cache.menu_hits[i] = .{ .action = actions[i], .rect = row, .enabled = enabled[i] };
        const hovered = mouse_ok and enabled[i] and rectContains(row, mx, my);
        if (hovered) queueRounded(state, row, paletteColor(colors.rgba(44, 52, 54, 255)), theme.scaledUi(6.0));
        queueText(state, .{
            .x = row.x + theme.scaledUi(10.0),
            .y = row.y + theme.scaledUi(6.0),
            .w = row.w - theme.scaledUi(20.0),
            .h = row.h,
        }, labels[i], paletteColor(if (enabled[i]) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), hit_cache.menu_panel);
        y += row_h;
    }
}

fn performContextMenuAction(state: *app_state.AppState, dock: anytype, action: TerminalContextMenuAction) void {
    switch (action) {
        .new_tab => dock.createTab(state.allocator) catch |err| app_state.log.warn("failed to create terminal tab: {s}", .{@errorName(err)}),
        .new_claude_tab => dock.createTabWithProfile(state.allocator, .{ .kind = .claude, .label = "Claude" }) catch |err| app_state.log.warn("failed to create Claude terminal tab: {s}", .{@errorName(err)}),
        .new_opencode_tab => dock.createTabWithProfile(state.allocator, .{ .kind = .opencode, .label = "OpenCode" }) catch |err| app_state.log.warn("failed to create OpenCode terminal tab: {s}", .{@errorName(err)}),
        .new_codex_tab => dock.createTabWithProfile(state.allocator, .{ .kind = .codex, .label = "Codex" }) catch |err| app_state.log.warn("failed to create Codex terminal tab: {s}", .{@errorName(err)}),
        .new_cursor_tab => dock.createTabWithProfile(state.allocator, .{ .kind = .cursor, .label = "Cursor" }) catch |err| app_state.log.warn("failed to create Cursor terminal tab: {s}", .{@errorName(err)}),
        .new_custom_tab => if (state.firstCustomTerminalLaunchProfile()) |profile| {
            dock.createTabWithProfile(state.allocator, profile) catch |err| app_state.log.warn("failed to create custom terminal tab: {s}", .{@errorName(err)});
        },
        .rename_tab => if (dock.activeTab()) |tab| dock.beginRenameTab(tab.id),
        .close_tab => dock.closeTab(state.allocator, hit_cache.menu_tab_index) catch |err| app_state.log.warn("failed to close terminal tab: {s}", .{@errorName(err)}),
        .split_up => dock.splitActivePane(state.allocator, .up) catch |err| app_state.log.warn("failed to split terminal pane up: {s}", .{@errorName(err)}),
        .split_down => dock.splitActivePane(state.allocator, .down) catch |err| app_state.log.warn("failed to split terminal pane down: {s}", .{@errorName(err)}),
        .split_left => dock.splitActivePane(state.allocator, .left) catch |err| app_state.log.warn("failed to split terminal pane left: {s}", .{@errorName(err)}),
        .split_right => dock.splitActivePane(state.allocator, .right) catch |err| app_state.log.warn("failed to split terminal pane right: {s}", .{@errorName(err)}),
        .close_pane => dock.closeActivePaneOrTab(state.allocator) catch |err| app_state.log.warn("failed to close terminal pane: {s}", .{@errorName(err)}),
    }
    focusTerminal(state);
    if (dock.consumeWorkspaceChange()) state.markDirty();
}

fn focusTerminal(state: *app_state.AppState) void {
    state.requestTerminalDockFocus(hit_cache.dock_id);
}

fn startSelection(state: *app_state.AppState, x: f32, y: f32) bool {
    const target = paneAtPoint(x, y) orelse return false;
    const coord = cellAtPoint(state, target, x, y) orelse return false;
    hit_cache.dock_id = target.dock_id;
    var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
    dock.focusPane(target.pane_id);
    focusTerminal(state);
    selection_state = .{
        .active = true,
        .dragging = true,
        .moved = false,
        .dock_id = target.dock_id,
        .pane_id = target.pane_id,
        .anchor = coord,
        .focus = coord,
    };
    hit_cache.menu_open = false;
    if (dock.consumeWorkspaceChange()) state.markDirty();
    state.markDirty();
    return true;
}

fn updateSelectionFocus(state: *app_state.AppState, x: f32, y: f32) ?void {
    const target = PaneHitTarget{ .dock_id = selection_state.dock_id, .pane_id = selection_state.pane_id };
    selection_state.focus = cellAtPoint(state, target, x, y) orelse return null;
}

fn clearSelection() void {
    selection_state = .{};
}

fn cellAtPoint(state: *app_state.AppState, target: PaneHitTarget, x: f32, y: f32) ?TerminalCellCoord {
    const rect = paneRect(target.dock_id, target.pane_id) orelse return null;
    const dock = state.currentProjectTerminalDock(target.dock_id) orelse return null;
    const render_state = dock.renderStateForPane(target.pane_id) orelse return null;
    if (render_state.cols == 0 or render_state.rows == 0) return null;
    const cell_w = @max(rect.w / @as(f32, @floatFromInt(render_state.cols)), 1.0);
    const cell_h = @max(rect.h / @as(f32, @floatFromInt(render_state.rows)), 1.0);
    const clamped_x = theme.clampf(x, rect.x, rect.x + rect.w - 1.0);
    const clamped_y = theme.clampf(y, rect.y, rect.y + rect.h - 1.0);
    const cell_x = theme.clampf(@floor((clamped_x - rect.x) / cell_w), 0.0, @as(f32, @floatFromInt(render_state.cols - 1)));
    const cell_y = theme.clampf(@floor((clamped_y - rect.y) / cell_h), 0.0, @as(f32, @floatFromInt(render_state.rows - 1)));
    return .{ .x = @intFromFloat(cell_x), .y = @intFromFloat(cell_y) };
}

fn paneRect(dock_id: u32, pane_id: u32) ?palette.Rect {
    var i: usize = 0;
    while (i < hit_cache.pane_count) : (i += 1) {
        const hit = hit_cache.panes[i];
        if (hit.dock_id == dock_id and hit.pane_id == pane_id) return hit.rect;
    }
    return null;
}

fn selectionCoversCell(dock_id: u32, pane_id: u32, x: usize, y: usize) bool {
    if (!selection_state.active or selection_state.dock_id != dock_id or selection_state.pane_id != pane_id) return false;
    const start = selectionStart();
    const end = selectionEnd();
    if (y < start.y or y > end.y) return false;
    if (start.y == end.y) return x >= start.x and x <= end.x;
    if (y == start.y) return x >= start.x;
    if (y == end.y) return x <= end.x;
    return true;
}

fn selectionStart() TerminalCellCoord {
    return if (coordLessThan(selection_state.focus, selection_state.anchor)) selection_state.focus else selection_state.anchor;
}

fn selectionEnd() TerminalCellCoord {
    return if (coordLessThan(selection_state.focus, selection_state.anchor)) selection_state.anchor else selection_state.focus;
}

fn coordLessThan(a: TerminalCellCoord, b: TerminalCellCoord) bool {
    return a.y < b.y or (a.y == b.y and a.x < b.x);
}

fn copySelectionToClipboard(state: *app_state.AppState) bool {
    const dock = state.currentProjectTerminalDock(selection_state.dock_id) orelse return true;
    const render_state = dock.renderStateForPane(selection_state.pane_id) orelse return true;
    const text = selectedRenderStateText(state.allocator, render_state) catch |err| {
        app_state.log.warn("failed to build terminal selection clipboard text: {s}", .{@errorName(err)});
        return true;
    };
    defer state.allocator.free(text);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return true;

    const clipboard_text = state.allocator.dupeZ(u8, text) catch return true;
    defer state.allocator.free(clipboard_text);
    sdl.setClipboardText(clipboard_text) catch |err| {
        app_state.log.warn("failed to set terminal selection clipboard text: {s}", .{@errorName(err)});
    };
    return true;
}

fn selectedRenderStateText(allocator: std.mem.Allocator, render_state: *const ghostty_vt.RenderState) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const start = selectionStart();
    const end = selectionEnd();
    const row_data = render_state.row_data.slice();
    const row_cells = row_data.items(.cells);
    var y = start.y;
    while (y <= end.y and y < row_cells.len) : (y += 1) {
        const cells_slice = row_cells[y].slice();
        const raw_cells = cells_slice.items(.raw);
        if (raw_cells.len == 0) continue;
        const row_graphemes = cells_slice.items(.grapheme);
        const row_start = if (y == start.y) start.x else 0;
        const row_end = if (y == end.y) @min(end.x, raw_cells.len - 1) else raw_cells.len - 1;

        var row: std.ArrayList(u8) = .empty;
        defer row.deinit(allocator);

        var x = row_start;
        while (x <= row_end and x < raw_cells.len) : (x += 1) {
            const raw_cell = raw_cells[x];
            if (raw_cell.wide == .spacer_tail) continue;
            if (!raw_cell.hasText()) {
                try row.append(allocator, ' ');
                continue;
            }

            var text_buf: [128]u8 = undefined;
            const text = cellText(raw_cell, graphemesForCell(raw_cell, row_graphemes, x), &text_buf) orelse " ";
            try row.appendSlice(allocator, text);
            if (raw_cell.wide == .wide and x < row_end) try row.append(allocator, ' ');
        }

        try output.appendSlice(allocator, std.mem.trimEnd(u8, row.items, " \t"));
        if (y < end.y) try output.append(allocator, '\n');
    }

    return output.toOwnedSlice(allocator);
}

fn openContextMenu(kind: TerminalContextMenuKind, tab_index: usize, pane_id: u32, x: f32, y: f32) void {
    hit_cache.menu_open = true;
    hit_cache.menu_kind = kind;
    hit_cache.menu_tab_index = tab_index;
    hit_cache.menu_pane_id = pane_id;
    hit_cache.menu_anchor = .{ .x = x, .y = y, .w = 1.0, .h = 1.0 };
}

pub fn resetHitCache() void {
    hit_cache.pane_count = 0;
    hit_cache.tab_count = 0;
    hit_cache.menu_count = 0;
}

fn appendPaneHit(pane_id: u32, rect: palette.Rect) void {
    if (hit_cache.pane_count >= MAX_PANE_HITS) return;
    hit_cache.panes[hit_cache.pane_count] = .{ .dock_id = hit_cache.dock_id, .pane_id = pane_id, .rect = rect };
    hit_cache.pane_count += 1;
}

fn appendTabHit(index: usize, rect: palette.Rect) void {
    if (hit_cache.tab_count >= MAX_TAB_HITS) return;
    hit_cache.tabs[hit_cache.tab_count] = .{ .dock_id = hit_cache.dock_id, .index = index, .rect = rect };
    hit_cache.tab_count += 1;
}

fn paneAtPoint(x: f32, y: f32) ?PaneHitTarget {
    var i: usize = 0;
    while (i < hit_cache.pane_count) : (i += 1) {
        const hit = hit_cache.panes[i];
        if (rectContains(hit.rect, x, y)) return .{ .dock_id = hit.dock_id, .pane_id = hit.pane_id };
    }
    return null;
}

fn tabAtPoint(x: f32, y: f32) ?TabHitTarget {
    var i: usize = 0;
    while (i < hit_cache.tab_count) : (i += 1) {
        const hit = hit_cache.tabs[i];
        if (rectContains(hit.rect, x, y)) return .{ .dock_id = hit.dock_id, .index = hit.index };
    }
    return null;
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h;
}

fn terminalCopyShortcut(event: *const sdl.KeyboardEvent) bool {
    if (!event.down or event.repeat) return false;
    if (event.scancode != .c and event.key != .c) return false;
    return modifierPressed(event.mod, sdl.Keymod.ctrl) and
        modifierPressed(event.mod, sdl.Keymod.shift) and
        !modifierPressed(event.mod, sdl.Keymod.alt) and
        !modifierPressed(event.mod, sdl.Keymod.gui);
}

fn modifierPressed(state: sdl.Keymod, mask: u16) bool {
    const state_bits = @as(*const u16, @ptrCast(&state)).*;
    return (state_bits & mask) != 0;
}

fn drawCursor(state: *app_state.AppState, render_state: *const ghostty_vt.RenderState, rect: palette.Rect) void {
    const color = rgbPaletteColor(render_state.colors.cursor orelse render_state.colors.foreground, 0.95);
    switch (render_state.cursor.visual_style) {
        .block => queueRect(state, rect, color),
        .block_hollow => queueBorder(state, rect, color, 0.0, theme.scaledUi(1.5)),
        .bar => queueRect(state, .{ .x = rect.x, .y = rect.y, .w = @max(rect.w * 0.12, theme.scaledUi(2.0)), .h = rect.h }, color),
        .underline => queueRect(state, .{ .x = rect.x, .y = rect.y + rect.h - @max(rect.h * 0.1, theme.scaledUi(2.0)), .w = rect.w, .h = @max(rect.h * 0.1, theme.scaledUi(2.0)) }, color),
    }
}

fn rawCellNeedsFill(cell: ghostty_vt.Cell) bool {
    return switch (cell.content_tag) {
        .bg_color_palette, .bg_color_rgb => true,
        else => false,
    };
}

fn cellWidthCells(cell: ghostty_vt.Cell) u2 {
    return switch (cell.wide) {
        .wide => 2,
        else => 1,
    };
}

fn styleForCell(cell: ghostty_vt.Cell, styles: []const ghostty_vt.Style, index: usize) ghostty_vt.Style {
    return switch (cell.content_tag) {
        .bg_color_palette => .{ .bg_color = .{ .palette = @intCast(cell.content.color_palette) } },
        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
            .r = cell.content.color_rgb.r,
            .g = cell.content.color_rgb.g,
            .b = cell.content.color_rgb.b,
        } } },
        else => if (cell.hasStyling()) styles[index] else .{},
    };
}

fn graphemesForCell(cell: ghostty_vt.Cell, graphemes: []const []const u21, index: usize) []const u21 {
    return if (cell.hasGrapheme()) graphemes[index] else &.{};
}

fn cellText(raw_cell: ghostty_vt.Cell, graphemes: []const u21, buffer: []u8) ?[]const u8 {
    if (!raw_cell.hasText()) return null;
    var index: usize = 0;
    index += std.unicode.utf8Encode(raw_cell.codepoint(), buffer[index..]) catch return null;
    if (raw_cell.hasGrapheme()) {
        for (graphemes) |cp| {
            if (index >= buffer.len) break;
            index += std.unicode.utf8Encode(cp, buffer[index..]) catch break;
        }
    }
    return buffer[0..index];
}

fn glyphNeedsRelaxedClip(cp: u21) bool {
    return switch (cp) {
        0xe0a0...0xe0af,
        0xe5fa...0xe7ff,
        0xf000...0xf8ff,
        0xf0000...0xf20ff,
        => true,
        else => false,
    };
}

fn foregroundAlpha(style: ghostty_vt.Style) f32 {
    return if (style.flags.faint) 0.55 else 1.0;
}

fn rgbEql(a: ghostty_vt.color.RGB, b: ghostty_vt.color.RGB) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

fn blendRgb(a: ghostty_vt.color.RGB, b: ghostty_vt.color.RGB, amount: f32) ghostty_vt.color.RGB {
    const t = theme.clampf(amount, 0.0, 1.0);
    return .{
        .r = blendChannel(a.r, b.r, t),
        .g = blendChannel(a.g, b.g, t),
        .b = blendChannel(a.b, b.b, t),
    };
}

fn blendChannel(a: u8, b: u8, t: f32) u8 {
    const lhs = @as(f32, @floatFromInt(a));
    const rhs = @as(f32, @floatFromInt(b));
    return @intFromFloat(lhs + (rhs - lhs) * t);
}

fn terminalCellRect(rect: palette.Rect, cell_w: f32, cell_h: f32, x: usize, y: usize, span: f32) palette.Rect {
    const x0 = @round(rect.x + @as(f32, @floatFromInt(x)) * cell_w);
    const x1 = @round(rect.x + (@as(f32, @floatFromInt(x)) + span) * cell_w);
    const y0 = @round(rect.y + @as(f32, @floatFromInt(y)) * cell_h);
    const y1 = @round(rect.y + (@as(f32, @floatFromInt(y)) + 1.0) * cell_h);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(x1 - x0, 1.0),
        .h = @max(y1 - y0, 1.0),
    };
}

fn terminalTextRect(rect: palette.Rect, y_offset: f32, glyph_kind: TerminalGlyphKind) palette.Rect {
    return switch (glyph_kind) {
        .text => .{ .x = rect.x, .y = rect.y + y_offset, .w = rect.w, .h = rect.h },
        .icon => .{
            .x = rect.x - rect.w * 0.04,
            .y = rect.y + y_offset - rect.h * 0.04,
            .w = rect.w * 1.10,
            .h = rect.h * 1.08,
        },
        .powerline => .{
            .x = rect.x - rect.w * 0.16,
            .y = rect.y + y_offset - rect.h * 0.18,
            .w = rect.w * 1.42,
            .h = rect.h * 1.28,
        },
    };
}

fn terminalTextFontSize(font_size: f32, glyph_kind: TerminalGlyphKind) f32 {
    return switch (glyph_kind) {
        .text => font_size,
        .icon => font_size * 0.92,
        .powerline => font_size * 1.18,
    };
}

fn terminalFontSizeForCell(cell_w: f32, cell_h: f32) f32 {
    const by_height = cell_h * 0.95;
    const by_width = cell_w * 1.9;
    return theme.clampf(@min(by_height, by_width), 8.0, cell_h * 1.05);
}

fn stableText(state: *app_state.AppState, value: []const u8) []const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch "";
}

fn queueRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch {};
}

fn queueClippedRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, clip: ?palette.Rect) void {
    if (clip) |clip_rect| {
        state.palette_overlay_batch.rectClipped(state.allocator, rect, color, clip_rect) catch {};
    } else {
        queueRect(state, rect, color);
    }
}

fn queueTriangle(state: *app_state.AppState, p0: palette.draw.Vec2, p1: palette.draw.Vec2, p2: palette.draw.Vec2, color: palette.Color, clip: ?palette.Rect) void {
    if (clip) |clip_rect| {
        state.palette_overlay_batch.triangleClipped(state.allocator, p0, p1, p2, color, clip_rect) catch {};
    } else {
        state.palette_overlay_batch.triangle(state.allocator, p0, p1, p2, color) catch {};
    }
}

fn queueRounded(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch {};
}

fn queueBorder(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch {};
}

fn queueText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.text(state.allocator, rect, stableText(state, value), color, font_size, clip) catch {};
}

fn queueTerminalText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect, glyph_kind: TerminalGlyphKind) void {
    const font_role: ?palette.FontRole = switch (glyph_kind) {
        .text => .mono,
        .icon, .powerline => .icon,
    };
    if (glyph_kind == .text) {
        state.palette_overlay_batch.fixedRoleText(
            state.allocator,
            rect,
            stableText(state, value),
            color,
            font_size,
            font_role,
            null,
            clip,
            .{},
            rect.w,
            rect.h,
            false,
        ) catch {};
        return;
    }
    state.palette_overlay_batch.roleText(state.allocator, rect, stableText(state, value), color, font_size, font_role, null, clip) catch {};
}

fn queuePowerlineGlyph(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) void {
    const bleed = theme.scaledUi(0.2);
    const left = rect.x - bleed;
    const right = rect.x + rect.w + bleed;
    const top = rect.y;
    const bottom = rect.y + rect.h;
    const mid_y = rect.y + rect.h * 0.5;
    switch (cp) {
        0xe0b0, 0xe0b4, 0xe0b8, 0xe0bc, 0xe0c0, 0xe0c4 => queueTriangle(
            state,
            .{ .x = left, .y = top },
            .{ .x = left, .y = bottom },
            .{ .x = right, .y = mid_y },
            color,
            clip,
        ),
        0xe0b2, 0xe0b6, 0xe0ba, 0xe0be, 0xe0c2, 0xe0c6 => queueTriangle(
            state,
            .{ .x = right, .y = top },
            .{ .x = right, .y = bottom },
            .{ .x = left, .y = mid_y },
            color,
            clip,
        ),
        else => queueTerminalText(state, terminalTextRect(rect, 0.0, .icon), "?", color, rect.h, clip, .icon),
    }
}

fn queueTerminalCellGeometry(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    if (queueBlockElement(state, rect, cp, color, clip)) return true;
    if (queueBoxDrawing(state, rect, cp, color, clip)) return true;
    if (queueBraillePattern(state, rect, cp, color, clip)) return true;
    if (queueMiscSymbol(state, rect, cp, color, clip)) return true;
    return false;
}

fn queueBlockElement(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    const eighth = rect.h / 8.0;
    const eighth_w = rect.w / 8.0;
    switch (cp) {
        0x2580 => queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h * 0.5 }, color, clip),
        0x2581...0x2587 => {
            const rows = @as(f32, @floatFromInt(cp - 0x2580));
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h - eighth * rows, .w = rect.w, .h = eighth * rows }, color, clip);
        },
        0x2588 => queueClippedRect(state, rect, color, clip),
        0x2589...0x258f => {
            const cols = @as(f32, @floatFromInt(8 - (cp - 0x2588)));
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = eighth_w * cols, .h = rect.h }, color, clip);
        },
        0x2590 => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y, .w = rect.w * 0.5, .h = rect.h }, color, clip),
        0x2594 => queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @max(eighth, 1.0) }, color, clip),
        0x2595 => queueClippedRect(state, .{ .x = rect.x + rect.w - @max(eighth_w, 1.0), .y = rect.y, .w = @max(eighth_w, 1.0), .h = rect.h }, color, clip),
        0x2596 => queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip),
        0x2597 => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip),
        0x2598 => queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip),
        0x2599 => {
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w * 0.5, .h = rect.h }, color, clip);
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259a => {
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259b => {
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259c => {
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259d => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip),
        0x259e => {
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259f => {
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y, .w = rect.w * 0.5, .h = rect.h }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        else => return false,
    }
    return true;
}

fn queueBoxDrawing(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    if (cp < 0x2500 or cp > 0x257f) return false;
    const stroke = @max(@round(@min(rect.w, rect.h) * 0.105), 1.0);
    const cx = rect.x + rect.w * 0.5 - stroke * 0.5;
    const cy = rect.y + rect.h * 0.5 - stroke * 0.5;
    switch (cp) {
        0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x254c, 0x254d => queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w, .h = stroke }, color, clip),
        0x2502, 0x2503, 0x2506, 0x2507, 0x250a, 0x250b, 0x254e, 0x254f => queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h }, color, clip),
        0x250c...0x250f, 0x256d => {
            queueClippedRect(state, .{ .x = cx, .y = cy, .w = stroke, .h = rect.h * 0.5 + stroke * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = cx, .y = cy, .w = rect.w * 0.5 + stroke * 0.5, .h = stroke }, color, clip);
        },
        0x2510...0x2513, 0x256e => {
            queueClippedRect(state, .{ .x = cx, .y = cy, .w = stroke, .h = rect.h * 0.5 + stroke * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w * 0.5 + stroke * 0.5, .h = stroke }, color, clip);
        },
        0x2514...0x2517, 0x2570 => {
            queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h * 0.5 + stroke * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = cx, .y = cy, .w = rect.w * 0.5 + stroke * 0.5, .h = stroke }, color, clip);
        },
        0x2518...0x251b, 0x256f => {
            queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h * 0.5 + stroke * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w * 0.5 + stroke * 0.5, .h = stroke }, color, clip);
        },
        0x251c...0x254b => {
            queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w, .h = stroke }, color, clip);
        },
        0x2571 => queueDiagonalGlyph(state, rect, color, clip, true),
        0x2572 => queueDiagonalGlyph(state, rect, color, clip, false),
        0x2573 => {
            queueDiagonalGlyph(state, rect, color, clip, true);
            queueDiagonalGlyph(state, rect, color, clip, false);
        },
        0x2574 => queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w * 0.5, .h = stroke }, color, clip),
        0x2575 => queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h * 0.5 }, color, clip),
        0x2576 => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = cy, .w = rect.w * 0.5, .h = stroke }, color, clip),
        0x2577 => queueClippedRect(state, .{ .x = cx, .y = rect.y + rect.h * 0.5, .w = stroke, .h = rect.h * 0.5 }, color, clip),
        0x2578 => queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w * 0.5, .h = stroke * 1.4 }, color, clip),
        0x2579 => queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke * 1.4, .h = rect.h * 0.5 }, color, clip),
        0x257a => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = cy, .w = rect.w * 0.5, .h = stroke * 1.4 }, color, clip),
        0x257b => queueClippedRect(state, .{ .x = cx, .y = rect.y + rect.h * 0.5, .w = stroke * 1.4, .h = rect.h * 0.5 }, color, clip),
        0x257c...0x257f => {
            queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w, .h = stroke }, color, clip);
            queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h }, color, clip);
        },
        else => return false,
    }
    return true;
}

fn queueDiagonalGlyph(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, clip: ?palette.Rect, rising: bool) void {
    const steps: usize = 8;
    const step_w = rect.w / @as(f32, @floatFromInt(steps));
    const step_h = rect.h / @as(f32, @floatFromInt(steps));
    for (0..steps) |i| {
        const fi = @as(f32, @floatFromInt(i));
        const y_index = if (rising) steps - 1 - i else i;
        queueClippedRect(state, .{
            .x = rect.x + fi * step_w,
            .y = rect.y + @as(f32, @floatFromInt(y_index)) * step_h,
            .w = @max(step_w, 1.0),
            .h = @max(step_h, 1.0),
        }, color, clip);
    }
}

fn queueBraillePattern(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    if (cp < 0x2800 or cp > 0x28ff) return false;
    const bits = cp - 0x2800;
    if (bits == 0) return true;
    const dot_w = @max(@floor(rect.w / 3.0), 1.0);
    const dot_h = @max(@floor(rect.h / 5.0), 1.0);
    const x0 = rect.x + rect.w * 0.18;
    const x1 = rect.x + rect.w * 0.62;
    const ys = [_]f32{
        rect.y + rect.h * 0.08,
        rect.y + rect.h * 0.32,
        rect.y + rect.h * 0.56,
        rect.y + rect.h * 0.80,
    };
    const dots = [_]struct { bit: u8, x: f32, y: f32 }{
        .{ .bit = 0, .x = x0, .y = ys[0] },
        .{ .bit = 1, .x = x0, .y = ys[1] },
        .{ .bit = 2, .x = x0, .y = ys[2] },
        .{ .bit = 6, .x = x0, .y = ys[3] },
        .{ .bit = 3, .x = x1, .y = ys[0] },
        .{ .bit = 4, .x = x1, .y = ys[1] },
        .{ .bit = 5, .x = x1, .y = ys[2] },
        .{ .bit = 7, .x = x1, .y = ys[3] },
    };
    for (dots) |dot| {
        if ((bits & (@as(u21, 1) << @intCast(dot.bit))) == 0) continue;
        queueClippedRect(state, .{ .x = dot.x, .y = dot.y, .w = dot_w, .h = dot_h }, color, clip);
    }
    return true;
}

fn queueMiscSymbol(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    const inset_x = rect.w * 0.12;
    const inset_y = rect.h * 0.20;
    const left = rect.x + inset_x;
    const right = rect.x + rect.w - inset_x;
    const top = rect.y + inset_y;
    const bottom = rect.y + rect.h - inset_y;
    const mid_y = rect.y + rect.h * 0.5;
    switch (cp) {
        0x23f5 => queueTriangle(
            state,
            .{ .x = left, .y = top },
            .{ .x = left, .y = bottom },
            .{ .x = right, .y = mid_y },
            color,
            clip,
        ),
        0x23f4 => queueTriangle(
            state,
            .{ .x = right, .y = top },
            .{ .x = right, .y = bottom },
            .{ .x = left, .y = mid_y },
            color,
            clip,
        ),
        else => return false,
    }
    return true;
}

fn paletteColor(color: [4]f32) palette.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

fn rgbPaletteColor(rgb: ghostty_vt.color.RGB, alpha: f32) palette.Color {
    return .{
        .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
        .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
        .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
        .a = alpha,
    };
}

fn terminalGlyphKind(cp: u21) TerminalGlyphKind {
    return switch (cp) {
        0xe0b0...0xe0c8,
        0xe0ca,
        0xe0cc...0xe0d2,
        0xe0d4,
        0xe0d6...0xe0d7,
        => .powerline,
        else => .text,
    };
}
