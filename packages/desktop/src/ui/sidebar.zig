//! Project rail rendering for the native shell.

const std = @import("std");
const palette = @import("palette");
const theme = @import("theme.zig");
const colors = @import("colors.zig");
const runtime = @import("runtime.zig");
const native_state = @import("../state.zig");
const Provider = native_state.Provider;

const log = std.log.scoped(.native_ui_sidebar);

const SidebarHitKind = enum {
    collapse,
    expand,
    add_project,
    new_thread,
    project_row,
    thread_row,
    toggle_threads,
};

const SidebarHit = struct {
    rect: palette.Rect,
    kind: SidebarHitKind,
    project_index: usize = 0,
    thread_index: usize = 0,
};

var palette_hits: [512]SidebarHit = undefined;
var palette_hit_count: usize = 0;
var palette_sidebar_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var sidebar_scroll_y: f32 = 0.0;
var sidebar_max_scroll_y: f32 = 0.0;

/// Renders the sidebar with Palette-owned drawing and retained hit regions.
pub fn renderPalette(state: *runtime.AppState, rect: palette.Rect) void {
    palette_sidebar_rect = rect;
    palette_hit_count = 0;

    queuePaletteRect(state, rect, paletteColor(theme.COLOR_PANEL));
    queuePaletteRect(state, .{
        .x = rect.x + rect.w - theme.scaledUi(1.0),
        .y = rect.y,
        .w = theme.scaledUi(1.0),
        .h = rect.h,
    }, paletteColor(colors.DARK_BLUE));

    if (state.isSidebarCollapsed()) {
        renderPaletteCollapsedSidebar(state, rect);
    } else {
        renderPaletteExpandedSidebar(state, rect);
    }
}

pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32) void {
    var new_hover: ?native_state.SidebarThreadHover = null;
    if (!state.isSidebarCollapsed() and rectContainsPoint(palette_sidebar_rect, x, y)) {
        var index = palette_hit_count;
        while (index > 0) {
            index -= 1;
            const hit = palette_hits[index];
            if (hit.kind != .thread_row) continue;
            if (!rectContainsPoint(hit.rect, x, y)) continue;
            new_hover = .{ .project_index = hit.project_index, .thread_index = hit.thread_index };
            break;
        }
    }

    if (state.sidebar_thread_hover == null and new_hover == null) return;

    var changed = false;
    if (state.sidebar_thread_hover) |ho| {
        if (new_hover) |nw| {
            changed = ho.project_index != nw.project_index or ho.thread_index != nw.thread_index;
        } else changed = true;
    } else {
        changed = new_hover != null;
    }
    if (!changed) return;

    state.sidebar_thread_hover = new_hover;
    state.markDirty();
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) return rectContainsPoint(palette_sidebar_rect, x, y);
    if (!rectContainsPoint(palette_sidebar_rect, x, y)) return false;

    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_hits[index];
        if (!rectContainsPoint(hit.rect, x, y)) continue;

        switch (hit.kind) {
            .collapse => state.setSidebarCollapsed(true),
            .expand => state.setSidebarCollapsed(false),
            .add_project => {
                state.show_project_creator = true;
                state.setSidebarCollapsed(false);
                state.setSidebarNotice("");
                state.browseForProjectDirectory();
            },
            .new_thread => {
                if (state.projects.items.len > 0) state.createThreadForProject(@min(hit.project_index, state.projects.items.len - 1));
            },
            .project_row => {
                if (hit.project_index < state.projects.items.len) {
                    state.noteInteraction();
                    state.selected_project_index = hit.project_index;
                    state.projects.items[hit.project_index].collapsed = !state.projects.items[hit.project_index].collapsed;
                    state.syncRenameBuffer();
                    state.requestTranscriptScrollToBottom();
                    state.markDirty();
                }
            },
            .thread_row => {
                if (hit.project_index < state.projects.items.len and hit.thread_index < state.projects.items[hit.project_index].threads.items.len) {
                    state.noteInteraction();
                    state.selected_project_index = hit.project_index;
                    state.projects.items[hit.project_index].selected_thread_index = hit.thread_index;
                    state.requestComposerFocus();
                    state.syncRenameBuffer();
                }
            },
            .toggle_threads => {
                if (hit.project_index < state.projects.items.len) {
                    state.projects.items[hit.project_index].thread_list_expanded = !state.projects.items[hit.project_index].thread_list_expanded;
                    state.markDirty();
                }
            },
        }
        return true;
    }
    return true;
}

pub fn handlePaletteWheel(x: f32, y: f32, wheel_y: f32) bool {
    if (wheel_y == 0.0 or !rectContainsPoint(palette_sidebar_rect, x, y)) return false;
    sidebar_scroll_y = theme.clampf(sidebar_scroll_y - wheel_y * theme.scaledUi(64.0), 0.0, sidebar_max_scroll_y);
    return true;
}

fn renderPaletteExpandedSidebar(state: *runtime.AppState, rect: palette.Rect) void {
    const pad_x = theme.scaledUi(25.0);
    const rail_w = @max(rect.w - pad_x * 2.0, theme.scaledUi(140.0));
    var y = rect.y + theme.scaledUi(31.0) - sidebar_scroll_y;
    const x = rect.x + pad_x;
    const clip = rect;

    queuePaletteLogoMark(state, .{ .x = x, .y = y, .w = theme.scaledUi(42.0), .h = theme.scaledUi(42.0) });
    queuePaletteText(state, .{ .x = x + theme.scaledUi(54.0), .y = y + theme.scaledUi(4.0), .w = theme.scaledUi(130.0), .h = theme.scaledUi(38.0) }, "verde", paletteColor(theme.COLOR_WHITE), theme.heading_font_size, clip);

    const toggle_rect: palette.Rect = .{ .x = rect.x + rect.w - pad_x - theme.scaledUi(28.0), .y = y + theme.scaledUi(6.0), .w = theme.scaledUi(28.0), .h = theme.scaledUi(28.0) };
    queuePaletteButton(state, toggle_rect, "<", false);
    addPaletteHit(toggle_rect, .collapse, 0, 0);

    y += theme.scaledUi(92.0);
    queuePaletteText(state, .{ .x = x, .y = y, .w = theme.scaledUi(130.0), .h = theme.scaledUi(24.0) }, "PROJECTS", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(16.0), clip);
    const add_rect: palette.Rect = .{ .x = rect.x + rect.w - pad_x - theme.scaledUi(28.0), .y = y - theme.scaledUi(2.0), .w = theme.scaledUi(28.0), .h = theme.scaledUi(28.0) };
    queuePaletteButton(state, add_rect, "+", true);
    addPaletteHit(add_rect, .add_project, 0, 0);
    y += theme.scaledUi(38.0);

    var project_index: usize = 0;
    while (project_index < state.projects.items.len) : (project_index += 1) {
        const project = &state.projects.items[project_index];
        const selected = state.selected_project_index == project_index;
        const collapsed = project.collapsed;
        const row_h = theme.scaledUi(28.0);
        const action_w = theme.scaledUi(32.0);
        const row_rect: palette.Rect = .{ .x = x, .y = y, .w = rail_w - action_w - theme.scaledUi(6.0), .h = row_h };
        const project_visible = rowVisible(row_rect, rect);
        if (project_visible and selected) queuePaletteRoundedRect(state, row_rect, paletteColor(colors.CHAT_BLACK), theme.scaledUi(6.0));
        if (project_visible) addPaletteHit(row_rect, .project_row, project_index, 0);

        const cy = y + row_h * 0.5;
        var tx = x + theme.scaledUi(2.0);
        if (project_visible) queuePaletteChevron(state, tx, cy, theme.COLOR_TEXT_SUBTLE, collapsed);
        tx += theme.scaledUi(10.0);
        if (project_visible) queuePaletteFolderIcon(state, tx, cy, theme.scaledUi(14.0), theme.scaledUi(10.0), if (selected) theme.COLOR_SECONDARY_GREEN else theme.COLOR_TEXT_SUBTLE, selected);
        tx += theme.scaledUi(20.0);
        if (project_visible) queuePaletteText(state, .{ .x = tx, .y = y + theme.scaledUi(4.0), .w = row_rect.x + row_rect.w - tx, .h = row_h }, project.label, paletteColor(if (selected) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(15.0), row_rect);

        const new_rect: palette.Rect = .{ .x = rect.x + rect.w - pad_x - action_w, .y = y, .w = action_w, .h = row_h };
        if (project_visible) {
            queuePaletteEditGlyph(state, .{ new_rect.x, new_rect.y }, new_rect.w, new_rect.h, theme.COLOR_TEXT_MUTED);
            addPaletteHit(new_rect, .new_thread, project_index, 0);
        }
        y += row_h + theme.scaledUi(4.0);

        if (!collapsed) {
            var saved_buf: [32]u8 = undefined;
            const saved = std.fmt.bufPrint(&saved_buf, "{d} saved chats", .{project.committedThreadCountCached(state.allocator)}) catch "saved chats";
            const saved_rect: palette.Rect = .{ .x = x + theme.scaledUi(24.0), .y = y, .w = rail_w - theme.scaledUi(24.0), .h = theme.scaledUi(22.0) };
            if (rowVisible(saved_rect, rect)) queuePaletteText(state, saved_rect, saved, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(14.0), clip);
            y += theme.scaledUi(24.0);

            const sorted_indices = project.sortedCommittedThreadIndices(state.allocator);
            const show_all = project.thread_list_expanded or sorted_indices.len <= runtime.SIDEBAR_VISIBLE_THREAD_LIMIT;
            const visible_count = if (show_all) sorted_indices.len else @min(sorted_indices.len, runtime.SIDEBAR_VISIBLE_THREAD_LIMIT);
            for (sorted_indices[0..visible_count]) |thread_index| {
                if (thread_index >= project.threads.items.len) break;
                const thread = &project.threads.items[thread_index];
                const thread_rect: palette.Rect = .{
                    .x = x + theme.scaledUi(24.0),
                    .y = y,
                    .w = rail_w - theme.scaledUi(42.0),
                    .h = theme.scaledUi(26.0),
                };
                if (rowVisible(thread_rect, rect)) renderPaletteThreadRow(state, project_index, thread_index, thread, thread_rect, clip);
                y += theme.scaledUi(28.0);
            }
            if (sorted_indices.len > runtime.SIDEBAR_VISIBLE_THREAD_LIMIT) {
                const show_rect: palette.Rect = .{ .x = x + theme.scaledUi(12.0), .y = y + theme.scaledUi(2.0), .w = rail_w - theme.scaledUi(24.0), .h = theme.scaledUi(32.0) };
                if (rowVisible(show_rect, rect)) {
                    queuePaletteRoundedRect(state, show_rect, paletteColor(theme.COLOR_SECONDARY_GREEN), theme.scaledUi(8.0));
                    const label = if (project.thread_list_expanded) "Show less" else "Show more";
                    const show_pad_x = theme.scaledUi(14.0);
                    const font_size = theme.scaledUi(14.0);
                    queuePaletteText(state, .{
                        .x = show_rect.x + show_pad_x,
                        .y = show_rect.y + (show_rect.h - font_size * 1.25) * 0.5,
                        .w = show_rect.w - show_pad_x * 2.0,
                        .h = font_size * 1.25,
                    }, label, paletteColor(theme.COLOR_WHITE), font_size, show_rect);
                    addPaletteHit(show_rect, .toggle_threads, project_index, 0);
                }
                y += theme.scaledUi(40.0);
            }
        }
        y += theme.scaledUi(8.0);
    }

    sidebar_max_scroll_y = @max(0.0, y + sidebar_scroll_y - rect.y - rect.h + theme.scaledUi(24.0));
    sidebar_scroll_y = theme.clampf(sidebar_scroll_y, 0.0, sidebar_max_scroll_y);
    if (sidebar_max_scroll_y > 1.0) {
        const track: palette.Rect = .{ .x = rect.x + rect.w - theme.scaledUi(4.0), .y = rect.y + theme.scaledUi(12.0), .w = theme.scaledUi(3.0), .h = rect.h - theme.scaledUi(24.0) };
        const thumb_h = @max(theme.scaledUi(34.0), track.h * (track.h / (track.h + sidebar_max_scroll_y)));
        const thumb_y = track.y + (track.h - thumb_h) * (sidebar_scroll_y / sidebar_max_scroll_y);
        queuePaletteRoundedRect(state, track, paletteColor(colors.rgba(35, 42, 46, 120)), theme.scaledUi(2.0));
        queuePaletteRoundedRect(state, .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, paletteColor(colors.rgba(145, 163, 170, 200)), theme.scaledUi(2.0));
    }
}

fn renderPaletteCollapsedSidebar(state: *runtime.AppState, rect: palette.Rect) void {
    const button = theme.scaledUi(36.0);
    const x = rect.x + (rect.w - button) * 0.5;
    var y = rect.y + theme.scaledUi(30.0);
    queuePaletteLogoMark(state, .{ .x = x + theme.scaledUi(2.0), .y = y, .w = theme.scaledUi(32.0), .h = theme.scaledUi(32.0) });
    y += theme.scaledUi(62.0);
    const expand_rect: palette.Rect = .{ .x = x, .y = y, .w = button, .h = theme.scaledUi(30.0) };
    queuePaletteButton(state, expand_rect, ">", false);
    addPaletteHit(expand_rect, .expand, 0, 0);
    y += theme.scaledUi(40.0);
    const new_rect: palette.Rect = .{ .x = x, .y = y, .w = button, .h = theme.scaledUi(30.0) };
    queuePaletteEditGlyph(state, .{ new_rect.x, new_rect.y }, new_rect.w, new_rect.h, theme.COLOR_TEXT_MUTED);
    addPaletteHit(new_rect, .new_thread, state.selected_project_index, 0);
    y += theme.scaledUi(40.0);
    const add_rect: palette.Rect = .{ .x = x, .y = y, .w = button, .h = theme.scaledUi(30.0) };
    queuePaletteButton(state, add_rect, "+", true);
    addPaletteHit(add_rect, .add_project, 0, 0);
}

fn queuePaletteRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch |err| {
        log.warn("failed to queue sidebar palette rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, green: bool) void {
    queuePaletteRoundedRect(state, rect, paletteColor(if (green) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_ALT), theme.scaledUi(8.0));
    const font_size = theme.scaledUi(16.0);
    const text_width = @as(f32, @floatFromInt(label.len)) * font_size * 0.55;
    queuePaletteText(state, .{
        .x = rect.x + (rect.w - text_width) * 0.5,
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = @max(text_width, theme.scaledUi(4.0)),
        .h = font_size * 1.25,
    }, label, paletteColor(theme.COLOR_WHITE), font_size, rect);
}

fn renderPaletteThreadRow(state: *runtime.AppState, project_index: usize, thread_index: usize, thread: anytype, rect: palette.Rect, clip: palette.Rect) void {
    const project = &state.projects.items[project_index];
    const selected = state.selected_project_index == project_index and project.selected_thread_index == thread_index;
    const hovered = if (state.sidebar_thread_hover) |h| h.project_index == project_index and h.thread_index == thread_index else false;
    if (selected) {
        queuePaletteRoundedRect(state, rect, paletteColor(colors.DARK_BLUE), theme.scaledUi(4.0));
    } else if (hovered) {
        queuePaletteRoundedRect(state, rect, paletteColor(theme.lighten(colors.CHAT_BLACK, 0.14)), theme.scaledUi(4.0));
    }
    addPaletteHit(rect, .thread_row, project_index, thread_index);

    queuePaletteProviderGlyph(state, thread.provider, rect.x + theme.scaledUi(8.0), rect.y + rect.h * 0.5, clip);
    var time_buf: [24]u8 = undefined;
    const relative_time = formatRelativeTime(&time_buf, thread.last_activity_at);
    var title_buf = std.mem.zeroes([64:0]u8);
    const title_chars: usize = @intFromFloat(@max((rect.w - theme.scaledUi(84.0)) / theme.scaledUi(7.0), 8.0));
    const row_label = truncatedThreadTitle(&title_buf, thread.title, title_chars);

    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(24.0),
        .y = rect.y + theme.scaledUi(4.0),
        .w = rect.w - theme.scaledUi(86.0),
        .h = rect.h,
    }, row_label, paletteColor(if (selected) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), clip);
    queuePaletteText(state, .{
        .x = rect.x + rect.w - theme.scaledUi(60.0),
        .y = rect.y + theme.scaledUi(4.0),
        .w = theme.scaledUi(58.0),
        .h = rect.h,
    }, relative_time, paletteColor(colors.TIME_LABEL), theme.scaledUi(14.0), clip);
}

fn rowVisible(row: palette.Rect, viewport: palette.Rect) bool {
    return row.y + row.h >= viewport.y and row.y <= viewport.y + viewport.h;
}

fn addPaletteHit(rect: palette.Rect, kind: SidebarHitKind, project_index: usize, thread_index: usize) void {
    if (palette_hit_count >= palette_hits.len) return;
    palette_hits[palette_hit_count] = .{
        .rect = rect,
        .kind = kind,
        .project_index = project_index,
        .thread_index = thread_index,
    };
    palette_hit_count += 1;
}

fn rectContainsPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn queuePaletteRoundedRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch |err| {
        log.warn("failed to queue sidebar palette rounded rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch |err| {
        log.warn("failed to queue sidebar palette border: {s}", .{@errorName(err)});
    };
}

fn queuePaletteFolderIcon(state: *runtime.AppState, x: f32, center_y: f32, width: f32, height: f32, color: [4]f32, filled: bool) void {
    const tab_rect: palette.Rect = .{
        .x = x,
        .y = center_y - height * 0.5 - theme.scaledUi(2.0),
        .w = width * 0.4,
        .h = theme.scaledUi(3.0),
    };
    const body_rect: palette.Rect = .{
        .x = x,
        .y = center_y - height * 0.5,
        .w = width,
        .h = height,
    };
    const palette_color = paletteColor(color);
    queuePaletteRoundedRect(state, tab_rect, palette_color, theme.scaledUi(1.0));
    if (filled) {
        queuePaletteRoundedRect(state, body_rect, palette_color, theme.scaledUi(1.5));
    } else {
        queuePaletteBorder(state, body_rect, palette_color, theme.scaledUi(1.5), theme.scaledUi(1.4));
    }
}

fn queuePaletteChevron(state: *runtime.AppState, x: f32, center_y: f32, color: [4]f32, collapsed: bool) void {
    const font_size = theme.scaledUi(12.0);
    const glyph = if (collapsed) ">" else "v";
    queuePaletteText(state, .{
        .x = x - theme.scaledUi(4.0),
        .y = center_y - font_size * 0.58,
        .w = theme.scaledUi(12.0),
        .h = font_size * 1.25,
    }, glyph, paletteColor(color), font_size, null);
}

fn queuePaletteEditGlyph(state: *runtime.AppState, start: [2]f32, width: f32, height: f32, color: [4]f32) void {
    if (state.thread_edit_texture) |cached| {
        const size = @min(width, height) * 0.68;
        const rect: palette.Rect = .{
            .x = start[0] + (width - size) * 0.5,
            .y = start[1] + (height - size) * 0.5,
            .w = size,
            .h = size,
        };
        if (queuePaletteImage(state, rect, cached, paletteColor(color), null)) return;
    }

    const font_size = theme.scaledUi(18.0);
    const label = "+";
    const text_width = font_size * 0.5;
    queuePaletteText(state, .{
        .x = start[0] + (width - text_width) * 0.5,
        .y = start[1] + (height - font_size) * 0.5,
        .w = text_width,
        .h = font_size * 1.25,
    }, label, paletteColor(color), font_size, null);
}

fn queuePaletteLogoMark(state: *runtime.AppState, rect: palette.Rect) void {
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    if (state.logo_texture) |cached| {
        const dims = runtime.scaledImageSize(cached.width, cached.height, rect.w, rect.h);
        const image_rect: palette.Rect = .{
            .x = rect.x + (rect.w - dims[0]) * 0.5,
            .y = rect.y + (rect.h - dims[1]) * 0.5,
            .w = dims[0],
            .h = dims[1],
        };
        if (queuePaletteImage(state, image_rect, cached, paletteColor(theme.COLOR_WHITE), null)) return;
    }

    const mark_color = paletteColor(theme.COLOR_GREEN);
    const thickness = theme.scaledUi(3.0);
    queuePaletteBorder(state, rect, mark_color, theme.scaledUi(6.0), thickness);
    queuePaletteRect(state, .{
        .x = rect.x + rect.w * 0.5 - thickness * 0.5,
        .y = rect.y + rect.h * 0.25,
        .w = thickness,
        .h = rect.h * 0.5,
    }, mark_color);
    queuePaletteRect(state, .{
        .x = rect.x + rect.w * 0.25,
        .y = rect.y + rect.h * 0.5 - thickness * 0.5,
        .w = rect.w * 0.5,
        .h = thickness,
    }, mark_color);
}

fn queuePaletteText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stablePaletteText(state, value) catch |err| {
        log.warn("failed to retain sidebar palette text: {s}", .{@errorName(err)});
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
        log.warn("failed to queue sidebar palette text: {s}", .{@errorName(err)});
    };
}

fn stablePaletteText(state: *runtime.AppState, value: []const u8) ![]const u8 {
    const start = state.palette_frame_text.items.len;
    try state.palette_frame_text.appendSlice(state.allocator, value);
    return state.palette_frame_text.items[start .. start + value.len];
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn queuePaletteImage(state: *runtime.AppState, rect: palette.Rect, cached: native_state.CachedImageTexture, tint: palette.Color, clip: ?palette.Rect) bool {
    if (!cached.valid or cached.texture_id == 0 or rect.w <= 0.0 or rect.h <= 0.0) return false;
    state.palette_overlay_batch.image(
        state.allocator,
        rect,
        palette.TextureId.init(cached.texture_id),
        .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 },
        tint,
        clip,
    ) catch |err| {
        log.warn("failed to queue sidebar palette image: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

/// Truncates a thread title for narrow sidebar rows.
fn truncatedThreadTitle(buffer: *[64:0]u8, value: []const u8, max_len: usize) [:0]const u8 {
    const bounded_max = @min(buffer.len - 1, max_len);
    if (value.len <= bounded_max) return std.fmt.bufPrintZ(buffer, "{s}", .{value}) catch value[0..bounded_max :0];
    if (bounded_max <= 3) return "...";
    const prefix_len = bounded_max - 3;
    @memcpy(buffer[0..prefix_len], value[0..prefix_len]);
    @memcpy(buffer[prefix_len..bounded_max], "...");
    buffer[bounded_max] = 0;
    return buffer[0..bounded_max :0];
}

fn unixTimestampMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn unixTimestampSeconds() i64 {
    return @divTrunc(unixTimestampMs(), std.time.ms_per_s);
}

/// Formats a relative timestamp for sidebar metadata.
fn formatRelativeTime(buffer: []u8, timestamp: i64) []const u8 {
    if (timestamp <= 0) return "—";
    const now = unixTimestampSeconds();
    const elapsed = @max(0, now - timestamp);
    if (elapsed < 60) return "now";
    if (elapsed < 3600) {
        const minutes = @divFloor(elapsed, 60);
        return std.fmt.bufPrint(buffer, "{d}m", .{minutes}) catch "…";
    }
    if (elapsed < 86_400) {
        const hours = @divFloor(elapsed, 3600);
        return std.fmt.bufPrint(buffer, "{d}h", .{hours}) catch "…";
    }
    const days = @divFloor(elapsed, 86_400);
    return std.fmt.bufPrint(buffer, "{d}d", .{days}) catch "…";
}

fn queuePaletteProviderGlyph(state: *runtime.AppState, provider: Provider, x: f32, center_y: f32, clip: palette.Rect) void {
    const image_size = theme.scaledUi(13.0);
    const image_rect: palette.Rect = .{
        .x = x,
        .y = center_y - image_size * 0.5,
        .w = image_size,
        .h = image_size,
    };
    const texture = switch (provider) {
        .codex => state.codex_logo_texture,
        .opencode => state.opencode_logo_texture,
    };
    if (texture) |cached| {
        if (queuePaletteImage(state, image_rect, cached, paletteColor(theme.COLOR_WHITE), clip)) return;
    }

    const label = switch (provider) {
        .codex => "C",
        .opencode => "O",
    };
    const font_size = theme.scaledUi(11.0);
    queuePaletteText(state, .{
        .x = x,
        .y = center_y - font_size * 0.55,
        .w = theme.scaledUi(14.0),
        .h = font_size * 1.25,
    }, label, paletteColor(theme.COLOR_TEXT_SUBTLE), font_size, null);
}

/// Queues a small speech bubble icon for thread rows.
fn queuePaletteChatBubbleIcon(state: anytype, x: f32, center_y: f32, color: [4]f32) void {
    const bw = theme.scaledUi(11.0); // bubble width
    const bh = theme.scaledUi(8.0); // bubble height
    const r = theme.scaledUi(2.0); // corner rounding
    const bubble_top = center_y - bh * 0.5 - theme.scaledUi(1.0);
    const palette_color = paletteColor(color);

    queuePaletteRoundedRect(state, .{
        .x = x,
        .y = bubble_top,
        .w = bw,
        .h = bh,
    }, palette_color, r);
    queuePaletteRect(state, .{
        .x = x + theme.scaledUi(2.5),
        .y = bubble_top + bh - theme.scaledUi(0.5),
        .w = theme.scaledUi(3.0),
        .h = theme.scaledUi(2.5),
    }, palette_color);
}
