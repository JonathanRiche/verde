//! Palette-only terminal dock shell.

const std = @import("std");
const palette = @import("palette");

const app_state = @import("../state.zig");
const colors = @import("colors.zig");
const theme = @import("theme.zig");

pub fn renderDock(state: *app_state.AppState, width: f32, height: f32) void {
    renderDockAt(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height });
}

pub fn renderDockAt(state: *app_state.AppState, rect: palette.Rect) void {
    if (state.projects.items.len == 0) return;
    var dock = state.currentProjectTerminalMutable();
    queueRounded(state, rect, paletteColor(colors.rgba(9, 12, 13, 255)), 0.0);
    queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), 0.0, 1.0);

    const header = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = theme.scaledUi(34.0) };
    queueRect(state, header, paletteColor(theme.COLOR_PANEL));
    queueText(state, .{
        .x = header.x + theme.scaledUi(14.0),
        .y = header.y + theme.scaledUi(8.0),
        .w = header.w - theme.scaledUi(28.0),
        .h = theme.scaledUi(20.0),
    }, "Terminal", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), header);

    const body = palette.Rect{ .x = rect.x, .y = header.y + header.h, .w = rect.w, .h = @max(rect.h - header.h, 1.0) };
    renderTabs(state, dock, header);
    if (dock.activeTab()) |tab| {
        renderPaneNode(state, dock, tab.root, body);
    } else {
        renderStatus(state, body, "Starting shell...");
    }
    if (dock.takeFocusRequest()) state.terminal_focused = true;
}

fn renderTabs(state: *app_state.AppState, dock: anytype, header: palette.Rect) void {
    const tab_h = theme.scaledUi(24.0);
    var x = header.x + theme.scaledUi(92.0);
    for (dock.tabs.items, 0..) |_, index| {
        var title_buf: [96]u8 = undefined;
        const label = dock.tabTitle(index, &title_buf);
        const tab_w = theme.clampf(@as(f32, @floatFromInt(label.len)) * theme.scaledUi(7.0) + theme.scaledUi(24.0), theme.scaledUi(72.0), theme.scaledUi(180.0));
        const tab_rect = palette.Rect{ .x = x, .y = header.y + theme.scaledUi(5.0), .w = tab_w, .h = tab_h };
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
    dock.resizePaneToFit(state.allocator, pane_id, rect.w, rect.h) catch {};
    const focused = if (dock.activePaneConst()) |active| active.id == pane_id and state.terminal_focused else false;
    queueRect(state, rect, paletteColor(colors.rgba(7, 10, 11, 255)));
    if (focused) queueBorder(state, rect, paletteColor(theme.COLOR_SECONDARY_GREEN), 0.0, theme.scaledUi(1.0));

    const render_state = dock.renderStateForPane(pane_id) orelse {
        var status_buf: [192]u8 = undefined;
        renderStatus(state, rect, dock.statusText(&status_buf));
        return;
    };
    const font_size = @max(theme.scaledUi(12.0) * dock.font_scale, theme.scaledUi(9.0));
    const cell_w = @max(font_size * 0.58, 1.0);
    const line_h = @max(font_size * 1.28, 1.0);
    const row_slice = render_state.row_data.slice();
    for (row_slice.items(.cells), 0..) |cells, row_index| {
        const y = rect.y + theme.scaledUi(8.0) + @as(f32, @floatFromInt(row_index)) * line_h;
        if (y > rect.y + rect.h - line_h) break;
        const line = terminalLineText(state, cells) catch continue;
        queueFixedText(state, .{ .x = rect.x + theme.scaledUi(10.0), .y = y, .w = rect.w - theme.scaledUi(20.0), .h = line_h }, line, paletteColor(theme.COLOR_WHITE), font_size, rect);
    }
    if (focused and render_state.cursor.visible) {
        if (render_state.cursor.viewport) |cursor| {
            queueRect(state, .{
                .x = rect.x + theme.scaledUi(10.0) + @as(f32, @floatFromInt(cursor.x)) * cell_w,
                .y = rect.y + theme.scaledUi(8.0) + @as(f32, @floatFromInt(cursor.y)) * line_h,
                .w = @max(cell_w, theme.scaledUi(6.0)),
                .h = theme.scaledUi(2.0),
            }, paletteColor(theme.COLOR_SECONDARY_GREEN));
        }
    }
}

fn terminalLineText(state: *app_state.AppState, cells: anytype) ![]const u8 {
    const start = state.palette_frame_text.items.len;
    const raw_cells = cells.slice().items(.raw);
    var end = raw_cells.len;
    while (end > 0 and raw_cells[end - 1].codepoint() == 0) end -= 1;
    for (raw_cells[0..end]) |cell| {
        const cp = cell.codepoint();
        if (cp == 0) {
            try state.palette_frame_text.append(state.allocator, ' ');
        } else {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch 0;
            if (len > 0) try state.palette_frame_text.appendSlice(state.allocator, buf[0..len]);
        }
    }
    return state.palette_frame_text.items[start..];
}

fn renderStatus(state: *app_state.AppState, rect: palette.Rect, label: []const u8) void {
    queueText(state, .{
        .x = rect.x + theme.scaledUi(16.0),
        .y = rect.y + theme.scaledUi(18.0),
        .w = rect.w - theme.scaledUi(32.0),
        .h = theme.scaledUi(24.0),
    }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), rect);
}

fn stableText(state: *app_state.AppState, value: []const u8) []const u8 {
    const start = state.palette_frame_text.items.len;
    state.palette_frame_text.appendSlice(state.allocator, value) catch return "";
    return state.palette_frame_text.items[start .. start + value.len];
}

fn queueRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch {};
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

fn queueFixedText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.fixedText(state.allocator, rect, stableText(state, value), color, font_size, clip, .{}, font_size * 0.58, font_size * 1.28, false) catch {};
}

fn paletteColor(color: [4]f32) palette.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}
