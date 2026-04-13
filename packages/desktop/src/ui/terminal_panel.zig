const std = @import("std");
const ghostty_vt = @import("../vendor/ghostty_vt.zig");
const zgui = @import("zgui");

const app_state = @import("../state.zig");
const terminal = @import("../terminal/terminal.zig");
const colors = @import("colors.zig");
const theme = @import("theme.zig");

const RENAME_TAB_POPUP_ID: [:0]const u8 = "TerminalRenameTabPopup";

const RenderContext = struct {
    state: *app_state.AppState,
    dock: *terminal.Dock,
    hitbox_focused: bool = false,
    hitbox_active: bool = false,
    clicked: bool = false,
};

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
    renderTabStrip(state, dock);
    zgui.separator();
    renderRenameTabPopup(state, dock, width, height);

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = dock_bg });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 1 });
    }

    const focus_requested = dock.takeFocusRequest();
    _ = zgui.beginChild("TerminalDockWorkspaceArea", .{
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

    const window_focused = zgui.isWindowFocused(.{});
    var context: RenderContext = .{
        .state = state,
        .dock = dock,
    };

    if (dock.activeTab()) |tab| {
        const origin = zgui.getCursorScreenPos();
        const avail = zgui.getContentRegionAvail();
        renderPaneNode(&context, tab.root, origin, .{
            @max(avail[0], 1.0),
            @max(avail[1], 1.0),
        });
    } else {
        zgui.textColored(theme.COLOR_TEXT_MUTED, "Starting shell...", .{});
    }

    state.noteTerminalViewportDebug(
        window_focused,
        context.hitbox_focused,
        context.hitbox_active,
        context.clicked,
        focus_requested,
    );
    if (focus_requested or window_focused or context.hitbox_active or context.hitbox_focused or context.clicked) {
        state.terminal_focused = true;
        state.composer_focused = false;
    }
}

fn dockBackgroundColor(dock: *const terminal.Dock) [4]f32 {
    if (dock.activeRenderState()) |render_state| {
        return rgbToVec4(render_state.colors.background, 1.0);
    }
    return colors.rgba(0, 0, 0, 255);
}

fn renderHeader(dock: *const terminal.Dock) void {
    const header_height = theme.scaledUi(30.0);
    _ = zgui.beginChild("TerminalDockHeader", .{
        .w = 0.0,
        .h = header_height,
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

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(10.0), theme.scaledUi(6.0) } });
    defer zgui.popStyleVar(.{ .count = 1 });

    zgui.setCursorPos(.{ theme.scaledUi(10.0), theme.scaledUi(4.0) });
    zgui.textColored(theme.COLOR_WHITE, "{s}", .{dock.title()});

    var status_buf: [192]u8 = undefined;
    const status = dock.statusText(&status_buf);
    const status_size = zgui.calcTextSize(status, .{});
    const avail = zgui.getWindowSize()[0];
    zgui.sameLine(.{});
    zgui.setCursorPosX(@max(theme.scaledUi(120.0), avail - status_size[0] - theme.scaledUi(14.0)));
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{s}", .{status});
}

fn renderTabStrip(state: *app_state.AppState, dock: *terminal.Dock) void {
    const strip_height = theme.scaledUi(36.0);
    _ = zgui.beginChild("TerminalDockTabs", .{
        .w = 0.0,
        .h = strip_height,
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

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(8.0), theme.scaledUi(4.0) } });
    defer zgui.popStyleVar(.{ .count = 1 });

    for (dock.tabs.items, 0..) |tab, index| {
        var title_buf: [64]u8 = undefined;
        const title = dock.tabTitle(index, &title_buf);
        const active = dock.active_tab_index == index;
        const button_width = theme.clampf(
            zgui.calcTextSize(title, .{})[0] + theme.scaledUi(28.0),
            theme.scaledUi(82.0),
            theme.scaledUi(180.0),
        );

        zgui.pushStyleColor4f(.{ .idx = .button, .c = if (active) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_ALT });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = if (active) theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.08) else theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = if (active) theme.darken(theme.COLOR_SECONDARY_GREEN, 0.08) else theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
        if (zgui.button(zgui.formatZ("{s}##terminal-tab-{d}", .{ title, tab.id }), .{ .w = button_width, .h = theme.scaledUi(28.0) })) {
            dock.selectTab(index);
            state.markDirty();
        }
        zgui.popStyleColor(.{ .count = 3 });

        if (zgui.beginPopupContextItem()) {
            dock.selectTab(index);
            if (zgui.selectable("New Tab", .{ .selected = false, .h = theme.scaledUi(28.0) })) {
                dock.createTab(state.allocator) catch |err| {
                    app_state.log.warn("failed to create terminal tab: {s}", .{@errorName(err)});
                };
                state.markDirty();
                zgui.closeCurrentPopup();
            }
            if (zgui.selectable("Rename Tab", .{ .selected = false, .h = theme.scaledUi(28.0) })) {
                dock.beginRenameTab(tab.id);
                zgui.closeCurrentPopup();
            }
            if (zgui.selectable("Close Tab", .{ .selected = false, .h = theme.scaledUi(28.0) })) {
                dock.closeTab(state.allocator, index) catch |err| {
                    app_state.log.warn("failed to close terminal tab: {s}", .{@errorName(err)});
                };
                state.markDirty();
                zgui.closeCurrentPopup();
            }
            zgui.endPopup();
        }

        zgui.sameLine(.{ .spacing = theme.scaledUi(6.0) });
    }

    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("+##terminal-new-tab", .{ .w = theme.scaledUi(28.0), .h = theme.scaledUi(28.0) })) {
        dock.createTab(state.allocator) catch |err| {
            app_state.log.warn("failed to create terminal tab: {s}", .{@errorName(err)});
        };
        state.markDirty();
    }
    zgui.popStyleColor(.{ .count = 3 });
}

fn renderRenameTabPopup(state: *app_state.AppState, dock: *terminal.Dock, width: f32, height: f32) void {
    if (dock.rename_tab_id == null) return;
    if (!zgui.isPopupOpen(RENAME_TAB_POPUP_ID, .{})) {
        zgui.openPopup(RENAME_TAB_POPUP_ID, .{});
    }

    zgui.setNextWindowPos(.{
        .x = width * 0.5,
        .y = height * 0.5,
        .cond = .appearing,
        .pivot_x = 0.5,
        .pivot_y = 0.5,
    });
    zgui.setNextWindowSize(.{
        .w = theme.clampf(width * 0.26, theme.scaledUi(280.0), theme.scaledUi(380.0)),
        .h = 0.0,
        .cond = .appearing,
    });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = theme.scaledUi(12.0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(16.0), theme.scaledUi(16.0) } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ theme.scaledUi(10.0), theme.scaledUi(10.0) } });
    var open = true;
    if (!zgui.beginPopupModal(RENAME_TAB_POPUP_ID, .{
        .popen = &open,
        .flags = .{ .no_saved_settings = true },
    })) {
        if (!open) dock.cancelRenameTab();
        zgui.popStyleVar(.{ .count = 3 });
        return;
    }
    defer {
        zgui.endPopup();
        zgui.popStyleVar(.{ .count = 3 });
    }

    if (zgui.isWindowAppearing()) {
        zgui.setKeyboardFocusHere(0);
    }

    zgui.textColored(theme.COLOR_WHITE, "Rename tab", .{});
    _ = zgui.inputTextWithHint("##terminal-rename-tab", .{
        .hint = "Tab label",
        .buf = dock.renameBuffer(),
        .flags = .{ .enter_returns_true = true },
    });

    const modal_width = zgui.getContentRegionAvail()[0];
    const button_width = @max((modal_width - theme.scaledUi(10.0)) * 0.5, theme.scaledUi(92.0));
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("Cancel", .{ .w = button_width, .h = theme.scaledUi(32.0) })) {
        dock.cancelRenameTab();
        zgui.closeCurrentPopup();
        zgui.popStyleColor(.{ .count = 3 });
        return;
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_SECONDARY_GREEN });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.10) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) });
    if (zgui.button("Save", .{ .w = button_width, .h = theme.scaledUi(32.0) })) {
        dock.finishRenameTab(state.allocator) catch |err| {
            app_state.log.warn("failed to rename terminal tab: {s}", .{@errorName(err)});
        };
        state.markDirty();
        zgui.closeCurrentPopup();
        zgui.popStyleColor(.{ .count = 3 });
        return;
    }
    zgui.popStyleColor(.{ .count = 3 });
}

fn renderPaneNode(context: *RenderContext, node: *terminal.PaneNode, min: [2]f32, size: [2]f32) void {
    switch (node.*) {
        .leaf => |leaf| renderPaneLeaf(context, leaf.id, min, size),
        .split => |*split| {
            const handle = theme.scaledUi(8.0);
            const primary_size = if (split.axis == .vertical) size[0] else size[1];
            const available = @max(primary_size - handle, 1.0);
            const min_primary = theme.scaledUi(96.0);
            const min_ratio = theme.clampf(min_primary / available, terminal.MIN_SPLIT_RATIO, 0.45);
            split.ratio = theme.clampf(split.ratio, min_ratio, 1.0 - min_ratio);

            const first_primary = available * split.ratio;
            const second_primary = available - first_primary;

            if (split.axis == .vertical) {
                renderPaneNode(context, split.first, min, .{ first_primary, size[1] });
                renderSplitHandle(context, split, .{
                    min[0] + first_primary,
                    min[1],
                }, .{ handle, size[1] });
                renderPaneNode(context, split.second, .{
                    min[0] + first_primary + handle,
                    min[1],
                }, .{ second_primary, size[1] });
            } else {
                renderPaneNode(context, split.first, min, .{ size[0], first_primary });
                renderSplitHandle(context, split, .{
                    min[0],
                    min[1] + first_primary,
                }, .{ size[0], handle });
                renderPaneNode(context, split.second, .{
                    min[0],
                    min[1] + first_primary + handle,
                }, .{ size[0], second_primary });
            }
        },
    }
}

fn renderPaneLeaf(context: *RenderContext, pane_id: u32, min: [2]f32, size: [2]f32) void {
    const draw_list = zgui.getWindowDrawList();
    const pane_size = .{ @max(size[0], 1.0), @max(size[1], 1.0) };

    context.dock.resizePaneToFit(context.state.allocator, pane_id, pane_size[0], pane_size[1]) catch |err| {
        app_state.log.warn("failed to resize terminal pane {d}: {s}", .{ pane_id, @errorName(err) });
    };

    zgui.setCursorScreenPos(min);
    const clicked = zgui.invisibleButton(zgui.formatZ("##terminal-pane-{d}", .{pane_id}), .{
        .w = pane_size[0],
        .h = pane_size[1],
    });
    const focused = zgui.isItemFocused();
    const active = zgui.isItemActive();
    if (clicked) {
        context.dock.focusPane(pane_id);
        context.state.markDirty();
    }
    context.hitbox_focused = context.hitbox_focused or focused;
    context.hitbox_active = context.hitbox_active or active;
    context.clicked = context.clicked or clicked;

    if (zgui.beginPopupContextItem()) {
        context.dock.focusPane(pane_id);
        if (zgui.selectable("New Tab", .{ .selected = false, .h = theme.scaledUi(28.0) })) {
            context.dock.createTab(context.state.allocator) catch |err| {
                app_state.log.warn("failed to create terminal tab: {s}", .{@errorName(err)});
            };
            context.state.markDirty();
            zgui.closeCurrentPopup();
        }
        if (zgui.selectable("Split Up", .{ .selected = false, .h = theme.scaledUi(28.0) })) {
            context.dock.splitActivePane(context.state.allocator, .up) catch |err| {
                app_state.log.warn("failed to split terminal pane up: {s}", .{@errorName(err)});
            };
            context.state.markDirty();
            zgui.closeCurrentPopup();
        }
        if (zgui.selectable("Split Down", .{ .selected = false, .h = theme.scaledUi(28.0) })) {
            context.dock.splitActivePane(context.state.allocator, .down) catch |err| {
                app_state.log.warn("failed to split terminal pane down: {s}", .{@errorName(err)});
            };
            context.state.markDirty();
            zgui.closeCurrentPopup();
        }
        if (zgui.selectable("Split Left", .{ .selected = false, .h = theme.scaledUi(28.0) })) {
            context.dock.splitActivePane(context.state.allocator, .left) catch |err| {
                app_state.log.warn("failed to split terminal pane left: {s}", .{@errorName(err)});
            };
            context.state.markDirty();
            zgui.closeCurrentPopup();
        }
        if (zgui.selectable("Split Right", .{ .selected = false, .h = theme.scaledUi(28.0) })) {
            context.dock.splitActivePane(context.state.allocator, .right) catch |err| {
                app_state.log.warn("failed to split terminal pane right: {s}", .{@errorName(err)});
            };
            context.state.markDirty();
            zgui.closeCurrentPopup();
        }
        if (zgui.selectable("Close Pane", .{ .selected = false, .h = theme.scaledUi(28.0) })) {
            context.dock.closeActivePaneOrTab(context.state.allocator) catch |err| {
                app_state.log.warn("failed to close terminal pane: {s}", .{@errorName(err)});
            };
            context.state.markDirty();
            zgui.closeCurrentPopup();
        }
        zgui.endPopup();
    }

    if (context.dock.renderStateForPane(pane_id)) |render_state| {
        renderViewportRect(render_state, min, pane_size);
    } else {
        draw_list.addRectFilled(.{
            .pmin = min,
            .pmax = .{ min[0] + pane_size[0], min[1] + pane_size[1] },
            .col = zgui.colorConvertFloat4ToU32(colors.rgba(10, 10, 10, 255)),
        });
        draw_list.addText(.{
            min[0] + theme.scaledUi(10.0),
            min[1] + theme.scaledUi(10.0),
        }, zgui.colorConvertFloat4ToU32(theme.COLOR_TEXT_MUTED), "Starting shell...", .{});
    }

    const is_active = if (context.dock.activePaneConst()) |pane| pane.id == pane_id else false;
    draw_list.addRect(.{
        .pmin = min,
        .pmax = .{ min[0] + pane_size[0], min[1] + pane_size[1] },
        .col = zgui.colorConvertFloat4ToU32(if (is_active) theme.COLOR_GREEN else theme.COLOR_PANEL_MUTED),
        .thickness = if (is_active) 1.8 else 1.0,
    });
}

fn renderSplitHandle(context: *RenderContext, split: *terminal.PaneSplit, min: [2]f32, size: [2]f32) void {
    const draw_list = zgui.getWindowDrawList();
    zgui.setCursorScreenPos(min);
    _ = zgui.invisibleButton(zgui.formatZ("##terminal-split-{d}", .{@intFromPtr(split)}), .{
        .w = @max(size[0], 1.0),
        .h = @max(size[1], 1.0),
    });

    const hovered = zgui.isItemHovered(.{});
    const active = zgui.isItemActive();
    if (hovered or active) {
        zgui.setMouseCursor(if (split.axis == .vertical) .resize_ew else .resize_ns);
    }
    if (active) {
        const delta = zgui.getMouseDragDelta(.left, .{});
        const primary_size = if (split.axis == .vertical) size[0] else size[1];
        const drag_delta = if (split.axis == .vertical) delta[0] else delta[1];
        const new_ratio = split.ratio + (drag_delta / @max(primary_size * 2.0, 1.0));
        const clamped = theme.clampf(new_ratio, terminal.MIN_SPLIT_RATIO, 1.0 - terminal.MIN_SPLIT_RATIO);
        if (@abs(clamped - split.ratio) > 0.0001) {
            split.ratio = clamped;
            context.state.markDirty();
        }
    }

    const center = .{
        min[0] + size[0] * 0.5,
        min[1] + size[1] * 0.5,
    };
    const line_color = zgui.colorConvertFloat4ToU32(if (active) theme.COLOR_GREEN else if (hovered) theme.lighten(theme.COLOR_PANEL_MUTED, 0.12) else theme.COLOR_PANEL_MUTED);
    if (split.axis == .vertical) {
        draw_list.addLine(.{
            .p1 = .{ center[0], min[1] + theme.scaledUi(14.0) },
            .p2 = .{ center[0], min[1] + size[1] - theme.scaledUi(14.0) },
            .col = line_color,
            .thickness = 1.0,
        });
    } else {
        draw_list.addLine(.{
            .p1 = .{ min[0] + theme.scaledUi(14.0), center[1] },
            .p2 = .{ min[0] + size[0] - theme.scaledUi(14.0), center[1] },
            .col = line_color,
            .thickness = 1.0,
        });
    }
}

fn renderViewportRect(render_state: *const ghostty_vt.RenderState, origin: [2]f32, size: [2]f32) void {
    if (render_state.rows == 0 or render_state.cols == 0) return;

    const draw_list = zgui.getWindowDrawList();
    const width = @max(size[0], 1.0);
    const height = @max(size[1], 1.0);
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
