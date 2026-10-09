//! Files view of the right side panel: an explorer over the workspace's
//! folders. Opening a file shows it in its own workspace tab.
//!
//! Hook contract with `side_panel.zig`, which owns the panel chrome, routes
//! input here only while this view is selected, and passes body-local rects:
//! - `render` draws into `rect` (the panel body) each frame. `focused` is
//!   true while the panel body owns the keyboard.
//! - `handleMouseButton` / `handleMouseMotion` / `handleWheel` get window
//!   coordinates already known to lie in the body (button-up and motion also
//!   arrive while a drag that started here is in progress). Return true when
//!   consumed; the panel swallows body clicks either way.
//! - `handleKey` / `handleTextInput` run only while the body is focused.
//!   Return false to let the panel and app shortcuts see the key.
//! - `wantsTextInput` keeps SDL text input on while a field here is focused.
//! - `systemCursorAt` picks the pointer shape over the body.
//! - `resetHitCache` runs at the start of every panel render.
//!
//! Model and IO: `state/file_explorer.zig` (tree, filter results) driven by
//! `state/file_viewer_controller.zig` (`workspace.files.list` per expanded
//! folder, `workspace.files.search` for the filter). Roots are the
//! workspace home plus its verde.toml folders; the home root starts
//! expanded. `.git` is never listed and ignored entries are dimmed.
//!
//! Keys (tree): Up/Down/PgUp/PgDn/Home/End move; Right expands or enters a
//! folder; Left collapses or goes to the parent; Enter opens a file or
//! toggles a folder; F5 refreshes; typing (or Ctrl+F) edits the filter.
//! Keys (filter): editing per `text_edit.zig`; Down/Enter move into the
//! results; Escape clears, then leaves the field.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");
const file_icons = @import("file_icons.zig");
const text_edit = @import("text_edit.zig");
const platform_runtime = @import("platform_runtime");
const file_explorer = @import("../state/file_explorer.zig");

const AppState = runtime.AppState;
const Explorer = file_explorer.Explorer;
const Row = file_explorer.Row;

// Geometry tokens (CSS px).
const PAD_UI: f32 = 10.0;
const FILTER_ROW_UI: f32 = 40.0;
const FILTER_H_UI: f32 = 28.0;
const ROW_UI: f32 = 26.0;
const INDENT_UI: f32 = 14.0;
const CHEVRON_UI: f32 = 14.0;
const ICON_SLOT_UI: f32 = 18.0;
const LABEL_FONT_UI: f32 = 13.0;
const NOTE_FONT_UI: f32 = 12.0;
const ICON_FONT_UI: f32 = 14.0;
const WHEEL_ROWS: f32 = 3.0;
const IGNORED_ALPHA: u8 = 110;

const NF_CHEVRON_RIGHT = "\u{eab6}";
const NF_CHEVRON_DOWN = "\u{eab4}";
const NF_FOLDER_OPEN = "\u{eaf7}";
const NF_ROOT = "\u{ea62}";
const NF_SEARCH = "\u{ea6d}";
const NF_REFRESH = "\u{eb37}";
const NF_CLOSE = "\u{ea76}";

// ------------------------------------------------------------------
// View state (UI thread only)
// ------------------------------------------------------------------

var filter: text_edit.Field = .{ .max_bytes = 256 };
var filter_focused: bool = false;
var filter_drag: bool = false;
/// Workspace the filter text belongs to; switching workspaces clears it.
var filter_workspace: std.ArrayList(u8) = .empty;

var body_rect: palette.Rect = .{};
var filter_rect: palette.Rect = .{};
var filter_text_rect: palette.Rect = .{};
var filter_scroll_x: f32 = 0.0;
var clear_rect: ?palette.Rect = null;
var refresh_rect: palette.Rect = .{};
var list_rect: palette.Rect = .{};
var row_h: f32 = 1.0;
var max_scroll: f32 = 0.0;
var mouse: [2]f32 = .{ -1.0, -1.0 };
/// Reused per-frame key scratch (page-backed; never shrunk).
var render_key: std.ArrayList(u8) = .empty;
var select_key: std.ArrayList(u8) = .empty;

pub fn resetHitCache() void {
    clear_rect = null;
}

fn currentExplorer(state: *AppState) ?*Explorer {
    const explorer = state.fileExplorer() orelse return null;
    syncFilterWorkspace(state, explorer);
    ensureRows(state, explorer);
    return explorer;
}

/// The filter is per view, not per workspace: drop it when the selected
/// workspace changes so a stale query never filters another tree.
fn syncFilterWorkspace(state: *AppState, explorer: *Explorer) void {
    if (std.mem.eql(u8, filter_workspace.items, explorer.workspace_id)) return;
    filter_workspace.clearRetainingCapacity();
    filter_workspace.appendSlice(std.heap.page_allocator, explorer.workspace_id) catch {};
    filter.clear();
    filter_focused = false;
    filter_scroll_x = 0.0;
    state.fileExplorerSetQuery("");
}

/// Rows point into listing arenas; rebuild before any use after a change.
fn ensureRows(state: *AppState, explorer: *Explorer) void {
    if (!explorer.rows_dirty) return;
    if (explorer.search.query.len > 0) {
        explorer.flattenMatches() catch {};
    } else {
        explorer.flatten(state.fileViewerRoots()) catch {};
    }
}

fn filtering(explorer: *const Explorer) bool {
    return explorer.search.query.len > 0;
}

// ------------------------------------------------------------------
// Rendering
// ------------------------------------------------------------------

pub fn render(state: *AppState, rect: palette.Rect, focused: bool) void {
    // Region: filter row, divider, then the scrolling tree (or matches).
    body_rect = rect;
    const explorer = currentExplorer(state) orelse return;
    state.fileExplorerNoteRendered(explorer, platform_runtime.unixTimestampMs());
    ensureRows(state, explorer);
    if (!focused) filter_focused = false;

    var y = rect.y;
    renderFilterRow(state, rect, y, focused);
    y += theme.scaledUi(FILTER_ROW_UI);
    const stroke = @max(@round(theme.scaledUi(1.0)), 1.0);
    queueRect(state, .{ .x = rect.x, .y = y, .w = rect.w, .h = stroke }, theme.borderMuted(), rect);
    y += stroke;
    list_rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = @max(rect.y + rect.h - y, 0.0) };
    row_h = theme.scaledUi(ROW_UI);

    const roots = state.fileViewerRoots();
    if (roots.len == 0 and !filtering(explorer)) {
        max_scroll = 0.0;
        const roots_state = state.fileViewerRootsState();
        if (roots_state.status != .failed) {
            _ = renderNote(state, list_rect, "Loading folders…", theme.COLOR_TEXT_MUTED);
            return;
        }
        // Failed fetch: say why, and let a click (or F5 / refresh) retry.
        const message = if (roots_state.message.len > 0) roots_state.message else "Could not load this workspace's folders.";
        const used = renderNote(state, list_rect, message, theme.danger());
        _ = renderNote(state, .{ .x = list_rect.x, .y = list_rect.y + used - theme.scaledUi(PAD_UI), .w = list_rect.w, .h = @max(list_rect.h - used, 0.0) }, "Click here or press F5 to retry.", theme.COLOR_TEXT_SUBTLE);
        return;
    }
    renderRows(state, explorer, roots, focused and !filter_focused);
}

fn renderFilterRow(state: *AppState, rect: palette.Rect, y: f32, focused: bool) void {
    const pad = theme.scaledUi(PAD_UI);
    const row = theme.scaledUi(FILTER_ROW_UI);
    const field_h = theme.scaledUi(FILTER_H_UI);
    const button = field_h;
    const field_y = y + (row - field_h) * 0.5;
    refresh_rect = .{ .x = rect.x + rect.w - pad - button, .y = field_y, .w = button, .h = button };
    const refresh_hovered = contains(refresh_rect, mouse[0], mouse[1]);
    if (refresh_hovered) queueRounded(state, refresh_rect, theme.withAlpha(theme.COLOR_PANEL_MUTED, 220), theme.scaledUi(6.0), rect);
    queueIcon(state, refresh_rect, NF_REFRESH, if (refresh_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED, theme.scaledUi(ICON_FONT_UI), rect);

    filter_rect = .{ .x = rect.x + pad, .y = field_y, .w = @max(refresh_rect.x - theme.scaledUi(6.0) - rect.x - pad, 0.0), .h = field_h };
    const active = focused and filter_focused;
    const radius = theme.scaledUi(6.0);
    // Bordered field: border shape with the fill inset by one pixel.
    queueRounded(state, filter_rect, if (active) theme.withAlpha(theme.accent(), 200) else theme.borderMuted(), radius, rect);
    const inset = @max(@round(theme.scaledUi(1.0)), 1.0);
    queueRounded(state, .{ .x = filter_rect.x + inset, .y = filter_rect.y + inset, .w = filter_rect.w - inset * 2.0, .h = filter_rect.h - inset * 2.0 }, theme.COLOR_PANEL_ALT, @max(radius - inset, 0.0), rect);

    const icon_slot = theme.scaledUi(26.0);
    queueIcon(state, .{ .x = filter_rect.x, .y = filter_rect.y, .w = icon_slot, .h = filter_rect.h }, NF_SEARCH, theme.COLOR_TEXT_SUBTLE, theme.scaledUi(12.5), rect);
    var text_right = filter_rect.x + filter_rect.w - theme.scaledUi(8.0);
    if (filter.value().len > 0) {
        const clear: palette.Rect = .{ .x = filter_rect.x + filter_rect.w - icon_slot, .y = filter_rect.y, .w = icon_slot, .h = filter_rect.h };
        clear_rect = clear;
        const hovered = contains(clear, mouse[0], mouse[1]);
        queueIcon(state, clear, NF_CLOSE, if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE, theme.scaledUi(12.0), rect);
        text_right = clear.x;
    }
    filter_text_rect = .{ .x = filter_rect.x + icon_slot, .y = filter_rect.y, .w = @max(text_right - filter_rect.x - icon_slot, 0.0), .h = filter_rect.h };
    const font = theme.scaledUi(LABEL_FONT_UI);
    const text_h = font * 1.4;
    const text_y = filter_text_rect.y + (filter_text_rect.h - text_h) * 0.5;
    const text_clip = intersect(filter_text_rect, rect);
    const value = filter.value();
    if (value.len == 0) {
        queueText(state, .{ .x = filter_text_rect.x, .y = text_y, .w = filter_text_rect.w, .h = text_h }, "Filter files", theme.COLOR_TEXT_SUBTLE, font, .ui, text_clip);
        if (active) queueRect(state, .{ .x = filter_text_rect.x, .y = text_y + theme.scaledUi(2.0), .w = @max(@round(theme.scaledUi(1.0)), 1.0), .h = text_h - theme.scaledUi(4.0) }, theme.COLOR_WHITE, text_clip);
        filter_scroll_x = 0.0;
        return;
    }
    // Keep the caret visible by scrolling the text horizontally.
    const caret_x = prefixWidth(value, filter.cursor, font);
    const visible_w = filter_text_rect.w - theme.scaledUi(2.0);
    if (caret_x - filter_scroll_x > visible_w) filter_scroll_x = caret_x - visible_w;
    if (caret_x < filter_scroll_x) filter_scroll_x = caret_x;
    const total_w = prefixWidth(value, value.len, font);
    filter_scroll_x = std.math.clamp(filter_scroll_x, 0.0, @max(total_w - visible_w, 0.0));
    const origin = filter_text_rect.x - filter_scroll_x;
    if (active) if (filter.selection()) |range| {
        const x0 = origin + prefixWidth(value, range.start, font);
        const x1 = origin + prefixWidth(value, range.end, font);
        queueRect(state, .{ .x = x0, .y = text_y, .w = x1 - x0, .h = text_h }, theme.withAlpha(theme.selection(), 140), text_clip);
    };
    queueText(state, .{ .x = origin, .y = text_y, .w = total_w + 1.0, .h = text_h }, value, theme.COLOR_WHITE, font, .ui, text_clip);
    if (active) queueRect(state, .{ .x = origin + caret_x, .y = text_y + theme.scaledUi(2.0), .w = @max(@round(theme.scaledUi(1.0)), 1.0), .h = text_h - theme.scaledUi(4.0) }, theme.COLOR_WHITE, text_clip);
}

fn renderRows(state: *AppState, explorer: *Explorer, roots: []const file_explorer.Root, keyboard: bool) void {
    const rows = explorer.rows.items;
    const content_h = @as(f32, @floatFromInt(rows.len)) * row_h + theme.scaledUi(6.0);
    max_scroll = @max(content_h - list_rect.h, 0.0);
    explorer.scroll_y = std.math.clamp(explorer.scroll_y, 0.0, max_scroll);
    const selected = selectedIndex(explorer, roots);
    const first: usize = @intFromFloat(@max(@floor(explorer.scroll_y / row_h), 0.0));
    const count: usize = @intFromFloat(@ceil(list_rect.h / row_h) + 1.0);
    const last = @min(first + count, rows.len);
    const hovered = rowAt(explorer, mouse[0], mouse[1]);
    var index = first;
    while (index < last) : (index += 1) {
        const rect = rowRect(explorer, index);
        if (selected == index) {
            queueRect(state, rect, if (keyboard) theme.withAlpha(theme.accent(), 70) else theme.withAlpha(theme.COLOR_PANEL_MUTED, 200), list_rect);
        } else if (hovered == index and isActionable(rows[index])) {
            queueRect(state, rect, theme.withAlpha(theme.COLOR_PANEL_MUTED, 130), list_rect);
        }
        renderRow(state, explorer, roots, rows[index], rect);
    }
}

fn renderRow(state: *AppState, explorer: *Explorer, roots: []const file_explorer.Root, row: Row, rect: palette.Rect) void {
    const pad = theme.scaledUi(PAD_UI);
    const font = theme.scaledUi(LABEL_FONT_UI);
    const icon_font = theme.scaledUi(ICON_FONT_UI);
    const chevron = theme.scaledUi(CHEVRON_UI);
    const icon_slot = theme.scaledUi(ICON_SLOT_UI);
    const gap = theme.scaledUi(5.0);
    var x = rect.x + pad + @as(f32, @floatFromInt(row.depth)) * theme.scaledUi(INDENT_UI);
    const right = rect.x + rect.w - pad;
    const text_h = font * 1.4;
    const text_y = rect.y + (rect.h - text_h) * 0.5;
    const key_buf = &render_key;
    switch (row.kind) {
        .root => {
            if (row.root_index >= roots.len) return;
            const root = roots[row.root_index];
            file_explorer.makeKey(key_buf, root.id, "") catch return;
            const open = explorer.isExpanded(key_buf.items);
            queueIcon(state, .{ .x = x, .y = rect.y, .w = chevron, .h = rect.h }, if (open) NF_CHEVRON_DOWN else NF_CHEVRON_RIGHT, theme.COLOR_TEXT_MUTED, theme.scaledUi(12.0), list_rect);
            x += chevron + gap * 0.5;
            queueIcon(state, .{ .x = x, .y = rect.y, .w = icon_slot, .h = rect.h }, NF_ROOT, theme.accent(), icon_font, list_rect);
            x += icon_slot + gap;
            const name_w = @min(text_measure.textWidth(.ui_bold, font, root.name), @max(right - x, 0.0));
            const name = elideEnd(state, root.name, font, .ui_bold, @max(right - x, 0.0));
            queueText(state, .{ .x = x, .y = text_y, .w = name_w + 1.0, .h = text_h }, name, theme.COLOR_WHITE, font, .ui_bold, list_rect);
            if (loadingKey(explorer, key_buf.items)) renderSpinnerDot(state, rect, right);
        },
        .entry => {
            const entry = row.entry orelse return;
            const is_dir = entry.kind == .directory;
            var open = false;
            if (is_dir and row.root_index < roots.len) {
                file_explorer.makeKey(key_buf, roots[row.root_index].id, entry.path) catch return;
                open = explorer.isExpanded(key_buf.items);
            }
            if (is_dir) queueIcon(state, .{ .x = x, .y = rect.y, .w = chevron, .h = rect.h }, if (open) NF_CHEVRON_DOWN else NF_CHEVRON_RIGHT, theme.COLOR_TEXT_MUTED, theme.scaledUi(12.0), list_rect);
            x += chevron + gap * 0.5;
            const icon = if (is_dir) file_icons.folder else file_icons.forFile(entry.name);
            const glyph = if (is_dir and open) NF_FOLDER_OPEN else icon.glyph;
            var icon_color = theme.legibleOn(icon.color, theme.COLOR_PANEL);
            var text_color = theme.COLOR_TEXT_MUTED;
            if (!is_dir) text_color = theme.raise(theme.COLOR_TEXT_MUTED, 0.1);
            if (entry.ignored) {
                icon_color = theme.withAlpha(icon_color, IGNORED_ALPHA);
                text_color = theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 170);
            }
            queueIcon(state, .{ .x = x, .y = rect.y, .w = icon_slot, .h = rect.h }, glyph, icon_color, icon_font, list_rect);
            x += icon_slot + gap;
            const label = if (entry.symlink) std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s} \u{2192}", .{entry.name}) catch entry.name else entry.name;
            const shown = elideEnd(state, label, font, .ui, @max(right - x, 0.0));
            queueText(state, .{ .x = x, .y = text_y, .w = @max(right - x, 0.0), .h = text_h }, shown, text_color, font, .ui, list_rect);
            if (is_dir and loadingKey(explorer, key_buf.items)) renderSpinnerDot(state, rect, right);
        },
        .match => {
            const name = std.fs.path.basename(row.text);
            const icon = file_icons.forFile(name);
            queueIcon(state, .{ .x = x, .y = rect.y, .w = icon_slot, .h = rect.h }, icon.glyph, theme.legibleOn(icon.color, theme.COLOR_PANEL), icon_font, list_rect);
            x += icon_slot + gap;
            const name_w = @min(text_measure.textWidth(.ui, font, name), @max(right - x, 0.0));
            queueText(state, .{ .x = x, .y = text_y, .w = name_w + 1.0, .h = text_h }, elideEnd(state, name, font, .ui, @max(right - x, 0.0)), theme.raise(theme.COLOR_TEXT_MUTED, 0.1), font, .ui, list_rect);
            x += name_w + gap * 1.5;
            const directory = std.fs.path.dirname(row.text) orelse "";
            if (directory.len > 0 and x < right) {
                const small = theme.scaledUi(NOTE_FONT_UI);
                const small_h = small * 1.4;
                queueText(state, .{ .x = x, .y = rect.y + (rect.h - small_h) * 0.5, .w = right - x, .h = small_h }, elideStart(state, directory, small, right - x), theme.COLOR_TEXT_SUBTLE, small, .ui, list_rect);
            }
        },
        .loading, .failed, .truncated, .empty => {
            x += chevron + gap * 0.5;
            const small = theme.scaledUi(NOTE_FONT_UI);
            const small_h = small * 1.4;
            const message: []const u8 = switch (row.kind) {
                .loading => if (filtering(explorer)) "Searching…" else "Loading…",
                .failed => if (row.text.len > 0) row.text else "Could not list this folder.",
                .truncated => if (filtering(explorer)) "More matches not shown; refine the filter." else "More entries not shown.",
                .empty => if (filtering(explorer)) "No matching files." else "Empty folder",
                else => "",
            };
            const color = if (row.kind == .failed) theme.danger() else theme.COLOR_TEXT_SUBTLE;
            queueText(state, .{ .x = x, .y = rect.y + (rect.h - small_h) * 0.5, .w = @max(right - x, 0.0), .h = small_h }, elideEnd(state, message, small, .ui, @max(right - x, 0.0)), color, small, .ui, list_rect);
        },
    }
}

/// Small accent dot at the row's right edge while its folder refreshes.
fn renderSpinnerDot(state: *AppState, rect: palette.Rect, right: f32) void {
    const dot = theme.scaledUi(5.0);
    queueRounded(state, .{ .x = right - dot, .y = rect.y + (rect.h - dot) * 0.5, .w = dot, .h = dot }, theme.withAlpha(theme.accent(), 200), dot * 0.5, list_rect);
}

/// Word-wrapped note at the top of `rect`; returns the height it used
/// (top padding plus its lines).
fn renderNote(state: *AppState, rect: palette.Rect, message: []const u8, color: [4]f32) f32 {
    const font = theme.scaledUi(NOTE_FONT_UI);
    const pad = theme.scaledUi(PAD_UI) * 1.5;
    const line_h = font * 1.4;
    const max_w = @max(rect.w - pad * 2.0, 1.0);
    var y = rect.y + pad;
    var start: usize = 0;
    while (start < message.len) {
        // Longest run of whole words that fits; a lone long word is cut.
        var end = message.len;
        if (text_measure.textWidth(.ui, font, message[start..]) > max_w) {
            end = start;
            var cursor = start;
            while (cursor < message.len) {
                const space = std.mem.indexOfScalarPos(u8, message, cursor, ' ') orelse message.len;
                if (text_measure.textWidth(.ui, font, message[start..space]) > max_w) break;
                end = space;
                cursor = space + 1;
            }
            if (end == start) {
                end = start;
                while (end < message.len) {
                    const next = text_edit.nextBoundary(message, end);
                    if (end > start and text_measure.textWidth(.ui, font, message[start..next]) > max_w) break;
                    end = next;
                }
            }
        }
        queueText(state, .{ .x = rect.x + pad, .y = y, .w = max_w, .h = line_h }, message[start..end], color, font, .ui, rect);
        y += line_h;
        start = end;
        while (start < message.len and message[start] == ' ') start += 1;
    }
    return y - rect.y;
}

fn loadingKey(explorer: *const Explorer, key: []const u8) bool {
    const listing = explorer.dir(key) orelse return false;
    return listing.loading and listing.status == .ready;
}

fn rowRect(explorer: *const Explorer, index: usize) palette.Rect {
    return .{
        .x = list_rect.x,
        .y = list_rect.y + theme.scaledUi(3.0) + @as(f32, @floatFromInt(index)) * row_h - explorer.scroll_y,
        .w = list_rect.w,
        .h = row_h,
    };
}

fn rowAt(explorer: *const Explorer, x: f32, y: f32) ?usize {
    if (!contains(list_rect, x, y)) return null;
    const offset = (y - list_rect.y - theme.scaledUi(3.0) + explorer.scroll_y) / row_h;
    if (offset < 0) return null;
    const index: usize = @intFromFloat(@floor(offset));
    return if (index < explorer.rows.items.len) index else null;
}

fn isActionable(row: Row) bool {
    return switch (row.kind) {
        .root, .entry, .match, .failed => true,
        else => false,
    };
}

// ------------------------------------------------------------------
// Selection and actions
// ------------------------------------------------------------------

/// Selection key of a row: tree rows use the listing key, matches a 0x01
/// prefix plus the path. Null for note rows.
fn rowKey(buffer: *std.ArrayList(u8), roots: []const file_explorer.Root, row: Row) ?[]const u8 {
    const allocator = std.heap.page_allocator;
    switch (row.kind) {
        .root => {
            if (row.root_index >= roots.len) return null;
            file_explorer.makeKey(buffer, roots[row.root_index].id, "") catch return null;
        },
        .entry => {
            const entry = row.entry orelse return null;
            if (row.root_index >= roots.len) return null;
            file_explorer.makeKey(buffer, roots[row.root_index].id, entry.path) catch return null;
        },
        .match => {
            buffer.clearRetainingCapacity();
            buffer.append(allocator, 1) catch return null;
            buffer.appendSlice(allocator, row.text) catch return null;
        },
        else => return null,
    }
    return buffer.items;
}

fn selectedIndex(explorer: *const Explorer, roots: []const file_explorer.Root) ?usize {
    const selected = explorer.selected orelse return null;
    for (explorer.rows.items, 0..) |row, index| {
        const key = rowKey(&select_key, roots, row) orelse continue;
        if (std.mem.eql(u8, key, selected)) return index;
    }
    return null;
}

fn selectRow(explorer: *Explorer, roots: []const file_explorer.Root, index: usize) void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.heap.page_allocator);
    const key = rowKey(&buffer, roots, explorer.rows.items[index]) orelse return;
    explorer.select(key);
    revealRow(explorer, index);
}

fn revealRow(explorer: *Explorer, index: usize) void {
    const top = theme.scaledUi(3.0) + @as(f32, @floatFromInt(index)) * row_h;
    if (top < explorer.scroll_y) explorer.scroll_y = top;
    if (top + row_h > explorer.scroll_y + list_rect.h) explorer.scroll_y = top + row_h - list_rect.h;
    explorer.scroll_y = @max(explorer.scroll_y, 0.0);
}

/// Activates a row: folders toggle, files and matches open in a tab.
fn activateRow(state: *AppState, explorer: *Explorer, roots: []const file_explorer.Root, index: usize) void {
    const row = explorer.rows.items[index];
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.heap.page_allocator);
    switch (row.kind) {
        .root => {
            const key = rowKey(&buffer, roots, row) orelse return;
            state.fileExplorerSetExpanded(key, !explorer.isExpanded(key));
        },
        .entry => {
            const entry = row.entry orelse return;
            if (entry.kind == .directory) {
                const key = rowKey(&buffer, roots, row) orelse return;
                state.fileExplorerSetExpanded(key, !explorer.isExpanded(key));
            } else {
                const rel = std.heap.page_allocator.dupe(u8, entry.path) catch return;
                defer std.heap.page_allocator.free(rel);
                state.fileExplorerOpen(row.root_index, rel);
            }
        },
        .match => {
            const rel = std.heap.page_allocator.dupe(u8, row.text) catch return;
            defer std.heap.page_allocator.free(rel);
            state.fileExplorerOpen(homeRootIndex(roots) orelse return, rel);
        },
        .failed => state.fileExplorerRefresh(),
        else => {},
    }
    state.markDirty();
}

fn homeRootIndex(roots: []const file_explorer.Root) ?usize {
    for (roots, 0..) |root, index| {
        if (std.mem.eql(u8, root.id, "home")) return index;
    }
    return if (roots.len > 0) 0 else null;
}

/// Right: expand a folder, or step into an expanded one.
fn expandOrEnter(state: *AppState, explorer: *Explorer, roots: []const file_explorer.Root, index: usize) void {
    const row = explorer.rows.items[index];
    const is_folder = row.kind == .root or (row.kind == .entry and row.entry.?.kind == .directory);
    if (!is_folder) return;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.heap.page_allocator);
    const key = rowKey(&buffer, roots, row) orelse return;
    if (!explorer.isExpanded(key)) {
        state.fileExplorerSetExpanded(key, true);
        return;
    }
    if (index + 1 < explorer.rows.items.len and explorer.rows.items[index + 1].depth > row.depth) selectRow(explorer, roots, index + 1);
}

/// Left: collapse an expanded folder, else select the parent row.
fn collapseOrParent(state: *AppState, explorer: *Explorer, roots: []const file_explorer.Root, index: usize) void {
    const row = explorer.rows.items[index];
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.heap.page_allocator);
    const is_folder = row.kind == .root or (row.kind == .entry and row.entry.?.kind == .directory);
    if (is_folder) {
        const key = rowKey(&buffer, roots, row) orelse return;
        if (explorer.isExpanded(key)) {
            state.fileExplorerSetExpanded(key, false);
            return;
        }
    }
    if (row.depth == 0) return;
    var parent = index;
    while (parent > 0) {
        parent -= 1;
        if (explorer.rows.items[parent].depth < row.depth) {
            selectRow(explorer, roots, parent);
            return;
        }
    }
}

// ------------------------------------------------------------------
// Input
// ------------------------------------------------------------------

pub fn handleMouseButton(state: *AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    mouse = .{ x, y };
    if (!down) {
        filter_drag = false;
        return true;
    }
    const explorer = currentExplorer(state) orelse return true;
    if (contains(refresh_rect, x, y)) {
        state.fileExplorerRefresh();
        return true;
    }
    if (clear_rect) |rect| if (contains(rect, x, y)) {
        filter.clear();
        filter_focused = true;
        state.fileExplorerSetQuery("");
        return true;
    };
    if (contains(filter_rect, x, y)) {
        filter_focused = true;
        const offset = filterOffsetAt(x);
        if (clicks >= 3) {
            filter.selectAll();
        } else if (clicks == 2) {
            filter.selectWordAt(offset);
        } else {
            filter.moveTo(offset, false);
            filter.anchor = offset;
            filter_drag = true;
        }
        state.markDirty();
        return true;
    }
    filter_focused = false;
    const roots = state.fileViewerRoots();
    if (roots.len == 0 and contains(list_rect, x, y) and state.fileViewerRootsState().status == .failed) {
        state.fileExplorerRefresh();
        return true;
    }
    const index = rowAt(explorer, x, y) orelse {
        state.markDirty();
        return true;
    };
    selectRow(explorer, roots, index);
    activateRow(state, explorer, roots, index);
    return true;
}

pub fn handleMouseMotion(state: *AppState, x: f32, y: f32) bool {
    const previous = mouse;
    mouse = .{ x, y };
    if (filter_drag) {
        filter.moveTo(filterOffsetAt(x), true);
        state.markDirty();
        return true;
    }
    // Repaint only when the hovered target changes.
    const explorer = state.fileExplorer() orelse return false;
    const before = rowAt(explorer, previous[0], previous[1]);
    const after = rowAt(explorer, x, y);
    const buttons_changed = contains(refresh_rect, previous[0], previous[1]) != contains(refresh_rect, x, y) or
        (if (clear_rect) |rect| contains(rect, previous[0], previous[1]) != contains(rect, x, y) else false);
    if (before != after or buttons_changed) state.markDirty();
    return true;
}

pub fn handleWheel(state: *AppState, x: f32, y: f32, wheel_y: f32) bool {
    _ = x;
    _ = y;
    const explorer = currentExplorer(state) orelse return false;
    const next = std.math.clamp(explorer.scroll_y - wheel_y * WHEEL_ROWS * row_h, 0.0, max_scroll);
    if (next != explorer.scroll_y) {
        explorer.scroll_y = next;
        state.markDirty();
    }
    return true;
}

pub fn handleKey(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (!event.down) return false;
    const explorer = currentExplorer(state) orelse return false;
    const mod = text_edit.modBits(event.mod);
    const primary = (mod & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
    if (filter_focused) return handleFilterKey(state, explorer, event);
    if (primary and event.key == .f) {
        filter_focused = true;
        filter.selectAll();
        state.markDirty();
        return true;
    }
    if (primary) return false;
    if (event.key == .f5) {
        state.fileExplorerRefresh();
        return true;
    }
    const roots = state.fileViewerRoots();
    const rows = explorer.rows.items;
    if (rows.len == 0) return false;
    const current = selectedIndex(explorer, roots);
    const page_rows: usize = @intFromFloat(@max(@floor(list_rect.h / row_h) - 1.0, 1.0));
    switch (event.key) {
        .down => moveSelection(explorer, roots, if (current) |index| index + 1 else 0, 1),
        .up => moveSelection(explorer, roots, if (current) |index| index -| 1 else 0, -1),
        .pagedown => moveSelection(explorer, roots, @min((current orelse 0) + page_rows, rows.len - 1), -1),
        .pageup => moveSelection(explorer, roots, (current orelse 0) -| page_rows, 1),
        .home => moveSelection(explorer, roots, 0, 1),
        .end => moveSelection(explorer, roots, rows.len - 1, -1),
        .right => if (current) |index| expandOrEnter(state, explorer, roots, index),
        .left => if (current) |index| collapseOrParent(state, explorer, roots, index),
        .@"return", .kp_enter => if (current) |index| activateRow(state, explorer, roots, index),
        .f5 => state.fileExplorerRefresh(),
        .backspace => {
            if (filter.value().len == 0) return false;
            filter_focused = true;
            return handleFilterKey(state, explorer, event);
        },
        else => return false,
    }
    state.markDirty();
    return true;
}

/// Selects the nearest selectable row from `start`, stepping by `step`
/// past note rows.
fn moveSelection(explorer: *Explorer, roots: []const file_explorer.Root, start: usize, step: i2) void {
    const rows = explorer.rows.items;
    if (rows.len == 0) return;
    var index: isize = @intCast(@min(start, rows.len - 1));
    while (index >= 0 and index < rows.len) : (index += step) {
        const row = rows[@intCast(index)];
        if (row.kind == .root or row.kind == .entry or row.kind == .match) {
            selectRow(explorer, roots, @intCast(index));
            return;
        }
    }
}

fn handleFilterKey(state: *AppState, explorer: *Explorer, event: *const sdl.KeyboardEvent) bool {
    switch (event.key) {
        .down, .@"return", .kp_enter => {
            // Into the results: select (Enter also opens) the first match.
            filter_focused = false;
            const roots = state.fileViewerRoots();
            moveSelection(explorer, roots, 0, 1);
            if (event.key != .down) if (selectedIndex(explorer, roots)) |index| activateRow(state, explorer, roots, index);
            state.markDirty();
            return true;
        },
        .escape => {
            if (filter.value().len > 0) {
                filter.clear();
                state.fileExplorerSetQuery("");
            } else filter_focused = false;
            state.markDirty();
            return true;
        },
        .up, .tab => {
            if (event.key == .tab) return false;
            return true;
        },
        else => {},
    }
    const result = filter.handleKeyWithClipboard(state, event.key, event.mod) catch return true;
    switch (result) {
        .unhandled => {
            // Printable keys arrive as text input; swallow them here so app
            // shortcuts on plain letters don't fire while typing.
            const mod = text_edit.modBits(event.mod);
            return (mod & (sdl.Keymod.ctrl | sdl.Keymod.gui | sdl.Keymod.alt)) == 0;
        },
        .changed => state.fileExplorerSetQuery(filter.value()),
        .moved, .submit, .cancel => {},
    }
    state.markDirty();
    return true;
}

pub fn handleTextInput(state: *AppState, text: []const u8) bool {
    // Typing anywhere in the view edits the filter.
    if (!filter_focused) {
        filter_focused = true;
        filter.moveTo(filter.value().len, false);
    }
    const changed = filter.insert(state.allocator, text) catch return true;
    if (changed) state.fileExplorerSetQuery(filter.value());
    state.markDirty();
    return true;
}

pub fn wantsTextInput(state: *AppState) bool {
    _ = state;
    // On whenever the body has the keyboard, so typing starts the filter.
    return true;
}

pub fn systemCursorAt(state: *AppState, x: f32, y: f32) ?sdl.SystemCursor {
    if (contains(refresh_rect, x, y)) return .pointer;
    if (clear_rect) |rect| if (contains(rect, x, y)) return .pointer;
    if (contains(filter_rect, x, y)) return .text;
    const explorer = state.fileExplorer() orelse return null;
    const index = rowAt(explorer, x, y) orelse return null;
    if (index < explorer.rows.items.len and isActionable(explorer.rows.items[index])) return .pointer;
    return null;
}

fn filterOffsetAt(x: f32) usize {
    const font = theme.scaledUi(LABEL_FONT_UI);
    return text_edit.offsetAtX(filter.value(), x - filter_text_rect.x + filter_scroll_x, font, measurePrefix);
}

fn measurePrefix(font: f32, text: []const u8, end: usize) f32 {
    return text_measure.textPrefixWidth(.ui, text, font, end);
}

fn prefixWidth(text: []const u8, end: usize, font: f32) f32 {
    if (end == 0) return 0.0;
    return text_measure.textPrefixWidth(.ui, text, font, @min(end, text.len));
}

// ------------------------------------------------------------------
// Drawing helpers
// ------------------------------------------------------------------

/// `value` cut at the end with "…" to fit `max_w` (frame arena).
fn elideEnd(state: *AppState, value: []const u8, font: f32, role: palette.FontRole, max_w: f32) []const u8 {
    if (max_w <= 0.0) return "";
    if (text_measure.textWidth(role, font, value) <= max_w) return value;
    const ellipsis = "…";
    const budget = max_w - text_measure.textWidth(role, font, ellipsis);
    var end: usize = 0;
    var fit: usize = 0;
    while (end < value.len) {
        end = text_edit.nextBoundary(value, end);
        if (text_measure.textPrefixWidth(role, value, font, end) > budget) break;
        fit = end;
    }
    return std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s}{s}", .{ value[0..fit], ellipsis }) catch value;
}

/// `value` cut at the start with "…" (keeps the nearest folders visible).
fn elideStart(state: *AppState, value: []const u8, font: f32, max_w: f32) []const u8 {
    if (max_w <= 0.0) return "";
    if (text_measure.textWidth(.ui, font, value) <= max_w) return value;
    const ellipsis = "…";
    const budget = max_w - text_measure.textWidth(.ui, font, ellipsis);
    var start: usize = value.len;
    while (start > 0) {
        const previous = text_edit.prevBoundary(value, start);
        if (text_measure.textWidth(.ui, font, value[previous..]) > budget) break;
        start = previous;
    }
    return std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s}{s}", .{ ellipsis, value[start..] }) catch value;
}

fn contains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}

fn intersect(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
}

fn snap(rect: palette.Rect) palette.Rect {
    return .{ .x = @round(rect.x), .y = @round(rect.y), .w = @round(rect.w), .h = @round(rect.h) };
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn queueRect(state: *AppState, rect: palette.Rect, fill: [4]f32, clip: palette.Rect) void {
    state.palette_overlay_batch.rectClipped(state.allocator, snap(rect), paletteColor(fill), clip) catch {};
}

fn queueRounded(state: *AppState, rect: palette.Rect, fill: [4]f32, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, snap(rect), paletteColor(fill), radius, clip) catch {};
}

fn queueText(state: *AppState, rect: palette.Rect, value: []const u8, fill: [4]f32, font: f32, role: palette.FontRole, clip: palette.Rect) void {
    if (value.len == 0 or rect.w <= 0.0) return;
    const stable = state.palette_frame_text_arena.allocator().dupe(u8, value) catch return;
    state.palette_overlay_batch.roleText(state.allocator, rect, stable, paletteColor(fill), font, role, null, clip) catch {};
}

fn queueIcon(state: *AppState, rect: palette.Rect, glyph: []const u8, fill: [4]f32, font: f32, clip: palette.Rect) void {
    const glyph_w = text_measure.textWidth(.icon, font, glyph);
    const glyph_h = font * 1.3;
    queueText(state, .{
        .x = rect.x + (rect.w - glyph_w) * 0.5,
        .y = rect.y + (rect.h - glyph_h) * 0.5,
        .w = @max(glyph_w, 1.0),
        .h = glyph_h,
    }, glyph, fill, font, .icon, clip);
}
