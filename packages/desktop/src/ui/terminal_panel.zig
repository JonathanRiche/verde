const std = @import("std");
const ghostty_vt = @import("../vendor/ghostty_vt.zig");
const zgui = @import("zgui");

const app_state = @import("../state.zig");
const terminal = @import("../terminal/terminal.zig");
const colors = @import("colors.zig");
const theme = @import("theme.zig");

pub fn renderDock(state: *app_state.AppState, width: f32, height: f32) void {
    if (state.projects.items.len == 0) return;

    var dock = state.currentProjectTerminalMutable();
    const dock_bg = dockBackgroundColor(dock);
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 0.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = dock_bg });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    _ = zgui.beginChild("TerminalDock", .{
        .w = width,
        .h = height,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
    });
    defer zgui.endChild();

    renderHeader(dock);
    zgui.separator();

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = dock_bg });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 1 });
    }

    if (dock.takeFocusRequest()) {
        zgui.setNextWindowFocus();
    }

    _ = zgui.beginChild("TerminalDockViewport", .{
        .w = 0.0,
        .h = 0.0,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
        },
    });
    defer zgui.endChild();

    dock.resizeToFit(
        state.allocator,
        zgui.getContentRegionAvail()[0],
        zgui.getContentRegionAvail()[1],
    ) catch |err| {
        app_state.log.warn("failed to resize terminal dock: {s}", .{@errorName(err)});
    };

    state.terminal_focused = zgui.isWindowFocused(.{}) or
        (zgui.isWindowHovered(.{}) and zgui.isMouseClicked(.left));

    if (dock.renderState()) |render_state| {
        renderViewport(render_state);
    } else {
        zgui.textColored(theme.COLOR_TEXT_MUTED, "Starting shell...", .{});
    }
}

fn dockBackgroundColor(dock: *const terminal.Dock) [4]f32 {
    if (dock.renderState()) |render_state| {
        return rgbToVec4(render_state.colors.background, 1.0);
    }
    return colors.rgba(0, 0, 0, 255);
}

fn renderHeader(dock: *const terminal.Dock) void {
    zgui.setCursorPosX(0.0);
    if (theme.heading_font) |font| {
        zgui.pushFont(font, 17);
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{dock.title()});
        zgui.popFont();
    } else {
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{dock.title()});
    }
}

fn renderViewport(render_state: *const ghostty_vt.RenderState) void {
    if (render_state.rows == 0 or render_state.cols == 0) {
        zgui.textColored(theme.COLOR_TEXT_MUTED, "Waiting for terminal frame...", .{});
        return;
    }

    const draw_list = zgui.getWindowDrawList();
    const origin = zgui.getCursorScreenPos();
    const avail = zgui.getContentRegionAvail();
    const width = @max(avail[0], 1.0);
    const height = @max(avail[1], 1.0);
    const cols_f = @as(f32, @floatFromInt(render_state.cols));
    const rows_f = @as(f32, @floatFromInt(render_state.rows));
    const cell_width = width / cols_f;
    const cell_height = height / rows_f;
    const text_font = theme.terminal_font orelse zgui.getFont();
    const base_cell_width = @as(f32, @floatFromInt(terminal.CELL_PIXEL_WIDTH));
    const base_cell_height = @as(f32, @floatFromInt(terminal.CELL_PIXEL_HEIGHT));
    const geometry_scale = @min(cell_width / base_cell_width, cell_height / base_cell_height);
    const text_size = if (theme.terminal_font != null)
        @max(theme.terminal_font_size * geometry_scale, 10.0)
    else
        @max(@min(cell_height * 0.74, cell_width * 1.45), 10.0);
    const text_offset_y = @max((cell_height - text_size) * 0.12, 0.0);
    const text_offset_x = 0.0;

    const clip_min = origin;
    const clip_max = .{ origin[0] + width, origin[1] + height };
    draw_list.pushClipRect(.{
        .pmin = clip_min,
        .pmax = clip_max,
        .intersect_with_current = true,
    });
    defer draw_list.popClipRect();

    draw_list.addRectFilled(.{
        .pmin = clip_min,
        .pmax = clip_max,
        .col = rgbToU32(render_state.colors.background, 1.0),
    });

    const row_data = render_state.row_data.slice();
    const rows = row_data.items(.raw);
    const row_cells = row_data.items(.cells);
    const row_selections = row_data.items(.selection);

    for (row_cells, rows, row_selections, 0..) |cells, row, selection, y| {
        _ = row;
        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);
        const row_styles = cells_slice.items(.style);
        const row_graphemes = cells_slice.items(.grapheme);
        const row_y = origin[1] + @as(f32, @floatFromInt(y)) * cell_height;

        for (raw_cells, 0..) |raw_cell, x| {
            const cell_x = origin[0] + @as(f32, @floatFromInt(x)) * cell_width;
            const cell_span = @as(f32, @floatFromInt(cellWidthCells(raw_cell)));
            const cell_rect_min = .{ cell_x, row_y };
            const cell_rect_max = .{ cell_x + cell_width * cell_span, row_y + cell_height };
            const cell_style = resolvedStyle(raw_cell, row_styles[x]);
            var bg = cell_style.bg(&raw_cell, &render_state.colors.palette) orelse render_state.colors.background;
            var fg = cell_style.fg(.{
                .default = render_state.colors.foreground,
                .palette = &render_state.colors.palette,
            });
            var draw_cursor_overlay = false;

            if (selection) |range| {
                if (x >= range[0] and x <= range[1]) {
                    bg = blendRgb(bg, render_state.colors.foreground, 0.22);
                }
            }

            if (render_state.cursor.viewport) |cursor_vp| {
                if (cursor_vp.x == x and cursor_vp.y == y and render_state.cursor.visible) {
                    draw_cursor_overlay = true;
                    if (render_state.cursor.visual_style == .block) {
                        const cursor_fill = render_state.colors.cursor orelse render_state.colors.foreground;
                        bg = blendRgb(bg, cursor_fill, 0.62);
                        fg = render_state.colors.background;
                    }
                }
            }

            if (!rgbEql(bg, render_state.colors.background) or rawCellNeedsFill(raw_cell)) {
                draw_list.addRectFilled(.{
                    .pmin = cell_rect_min,
                    .pmax = cell_rect_max,
                    .col = rgbToU32(bg, 1.0),
                });
            }

            if (draw_cursor_overlay and render_state.cursor.visual_style != .block) {
                drawCursor(render_state, draw_list, cell_rect_min, cell_rect_max);
            }
        }

        for (raw_cells, 0..) |raw_cell, x| {
            const cell_x = origin[0] + @as(f32, @floatFromInt(x)) * cell_width;
            const cell_span = @as(f32, @floatFromInt(cellWidthCells(raw_cell)));
            const cell_rect_min = .{ cell_x, row_y };
            const cell_rect_max = .{ cell_x + cell_width * cell_span, row_y + cell_height };
            const cell_style = resolvedStyle(raw_cell, row_styles[x]);
            var fg = cell_style.fg(.{
                .default = render_state.colors.foreground,
                .palette = &render_state.colors.palette,
            });

            if (render_state.cursor.viewport) |cursor_vp| {
                if (cursor_vp.x == x and cursor_vp.y == y and render_state.cursor.visible and render_state.cursor.visual_style == .block) {
                    fg = render_state.colors.background;
                }
            }

            if (!raw_cell.hasText() or raw_cell.wide == .spacer_tail) continue;

            var text_buf: [128]u8 = undefined;
            const text = cellText(raw_cell, row_graphemes[x], &text_buf) orelse continue;
            const glyph_clip_rect: ?[4]f32 = if (glyphNeedsRelaxedClip(raw_cell.codepoint()))
                null
            else
                .{
                    cell_rect_min[0],
                    cell_rect_min[1],
                    cell_rect_max[0],
                    cell_rect_max[1],
                };
            draw_list.addTextExtendedUnformatted(
                .{ cell_rect_min[0] + text_offset_x, cell_rect_min[1] + text_offset_y },
                rgbToU32(fg, 1.0),
                text,
                .{
                    .font = text_font,
                    .font_size = text_size,
                    .cpu_fine_clip_rect = if (glyph_clip_rect) |rect|
                        @as([*]const [4]f32, @ptrCast(&rect))
                    else
                        null,
                },
            );
        }
    }
}

fn drawCursor(
    render_state: *const ghostty_vt.RenderState,
    draw_list: zgui.DrawList,
    pmin: [2]f32,
    pmax: [2]f32,
) void {
    const cursor_rgb = render_state.colors.cursor orelse render_state.colors.foreground;
    const cursor_col = rgbToU32(cursor_rgb, 0.95);
    switch (render_state.cursor.visual_style) {
        .block => draw_list.addRectFilled(.{
            .pmin = pmin,
            .pmax = pmax,
            .col = cursor_col,
        }),
        .block_hollow => draw_list.addRect(.{
            .pmin = pmin,
            .pmax = pmax,
            .col = cursor_col,
            .thickness = 1.5,
        }),
        .bar => draw_list.addRectFilled(.{
            .pmin = pmin,
            .pmax = .{ pmin[0] + @max((pmax[0] - pmin[0]) * 0.12, 2.0), pmax[1] },
            .col = cursor_col,
        }),
        .underline => draw_list.addRectFilled(.{
            .pmin = .{ pmin[0], pmax[1] - @max((pmax[1] - pmin[1]) * 0.1, 2.0) },
            .pmax = pmax,
            .col = cursor_col,
        }),
    }
}

fn rgbToVec4(rgb: ghostty_vt.RGB, alpha: f32) [4]f32 {
    return .{
        @as(f32, @floatFromInt(rgb.r)) / 255.0,
        @as(f32, @floatFromInt(rgb.g)) / 255.0,
        @as(f32, @floatFromInt(rgb.b)) / 255.0,
        alpha,
    };
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

fn resolvedStyle(cell: ghostty_vt.Cell, maybe_style: ghostty_vt.Style) ghostty_vt.Style {
    return switch (cell.content_tag) {
        .bg_color_palette, .bg_color_rgb => maybe_style,
        else => if (cell.hasStyling()) maybe_style else .{},
    };
}

fn cellText(
    raw_cell: ghostty_vt.Cell,
    graphemes: []const u21,
    buffer: []u8,
) ?[]const u8 {
    if (!raw_cell.hasText()) return null;

    var index: usize = 0;
    index += std.unicode.utf8Encode(raw_cell.codepoint(), buffer[index..]) catch return null;
    if (raw_cell.hasGrapheme()) {
        for (graphemes) |cp| {
            index += std.unicode.utf8Encode(cp, buffer[index..]) catch break;
            if (index >= buffer.len) break;
        }
    }
    return buffer[0..index];
}

fn glyphNeedsRelaxedClip(cp: u21) bool {
    return switch (cp) {
        0xe0a0...0xe0d7,
        0xe5fa...0xe7ff,
        0xf000...0xf8ff,
        0xf0000...0xf20ff,
        => true,
        else => false,
    };
}

fn rgbToU32(rgb: ghostty_vt.color.RGB, alpha: f32) u32 {
    return zgui.colorConvertFloat4ToU32(.{
        @as(f32, @floatFromInt(rgb.r)) / 255.0,
        @as(f32, @floatFromInt(rgb.g)) / 255.0,
        @as(f32, @floatFromInt(rgb.b)) / 255.0,
        alpha,
    });
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
