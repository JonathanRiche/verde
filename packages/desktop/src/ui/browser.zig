//! Browser dock rendering for the native shell.

const std = @import("std");
const zgui = @import("zgui");

const app_state = @import("../state.zig");
const colors = @import("colors.zig");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

const BROWSER_INSPECTOR_MODE_MENU_ID: [:0]const u8 = "BrowserInspectorModeMenu";

/// Renders the browser dock that manages the in-app browser pane and bridge controls.
pub fn renderDock(state: *app_state.AppState, width: f32, height: f32) void {
    if (!state.isBrowserVisible()) return;

    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 0.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(18, 20, 25, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    //NOTE: Begin of BrowserDock
    _ = zgui.beginChild("BrowserDock", .{
        .w = width,
        .h = height,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
    });
    defer {
        zgui.endChild();
    }

    renderToolbar(state);
    if (!state.isBrowserVisible()) {
        //NOTE: END OF BrowserDock
        return;
    }
    renderPaneCanvas(state);
    //NOTE: END OF BrowserDock
}

/// Draws an icon glyph centered within the last-placed item rect.
fn drawCenteredIcon(icon: [:0]const u8, color: [4]f32) void {
    const min = zgui.getItemRectMin();
    const max = zgui.getItemRectMax();
    const font = zgui.getFont();
    const icon_size = zgui.getFontSize() * 0.5;
    const size = zgui.calcTextSize(icon, .{});
    const scaled_w = size[0] * 0.5;
    const scaled_h = size[1] * 0.5;
    zgui.getWindowDrawList().addTextExtendedUnformatted(
        .{
            min[0] + (max[0] - min[0] - scaled_w) * 0.5,
            min[1] + (max[1] - min[1] - scaled_h) * 0.5,
        },
        zgui.colorConvertFloat4ToU32(color),
        icon,
        .{ .font = font, .font_size = icon_size },
    );
}

/// Renders the compact browser toolbar with URL entry and primary actions.
fn renderToolbar(state: *app_state.AppState) void {
    const navigate_icon = "\u{f061}";
    const inspect_icon = "\u{f245}";
    const close_icon = "\u{f00d}";
    const toolbar_height = theme.scaledUi(52.0);
    const button_size = theme.scaledUi(36.0);
    const inspect_menu_button_width = theme.scaledUi(22.0);
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(10.0), theme.scaledUi(8.0) } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(18, 20, 25, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 1 });
    }
    //NOTE: Begin of BrowserToolbar
    _ = zgui.beginChild("BrowserToolbar", .{
        .w = 0.0,
        .h = toolbar_height,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
        },
    });
    defer {
        zgui.endChild();
    }

    const browser_state = state.browserState();
    const avail = zgui.getContentRegionAvail()[0];
    const gap = theme.scaledUi(8.0);
    const field_width = @max(avail - button_size * 3.0 - inspect_menu_button_width - gap * 3.0, theme.scaledUi(180.0));

    const frame_pad_y = (button_size - zgui.getFontSize()) * 0.5;
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ theme.scaledUi(8.0), frame_pad_y } });
    zgui.pushItemWidth(field_width);
    if (zgui.isWindowAppearing()) {
        zgui.setKeyboardFocusHere(0);
    }
    const submitted = zgui.inputTextWithHint("##browser-address", .{
        .hint = "https://example.com",
        .buf = browser_state.addressBuffer(),
        .flags = .{ .enter_returns_true = true },
    });
    const address_focused = zgui.isItemFocused();
    const address_active = zgui.isItemActive();
    if (address_focused or address_active) {
        state.terminal_focused = false;
        state.composer_focused = false;
        state.unfocusBrowserPane();
    }
    zgui.popItemWidth();
    zgui.popStyleVar(.{ .count = 1 });
    if (submitted) {
        state.navigateBrowserFromAddress();
    }

    zgui.sameLine(.{ .spacing = gap });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_SECONDARY_GREEN });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.10) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) });
    if (zgui.button("##browser-navigate", .{ .w = button_size, .h = button_size })) {
        state.navigateBrowserFromAddress();
    }
    drawCenteredIcon(navigate_icon, theme.COLOR_WHITE);
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{ .spacing = gap });
    const can_use_inspector = state.canUseBrowserInspector();
    const inspector_active = state.isBrowserInspectorEnabled();
    const inspector_mode = state.browserInspectorMode();
    const inspector_button_color = if (inspector_active) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_ALT;
    const inspector_hover_color = if (inspector_active) theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.08) else theme.lighten(theme.COLOR_PANEL_ALT, 0.08);
    const inspector_active_color = if (inspector_active) theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) else theme.lighten(theme.COLOR_PANEL_ALT, 0.14);
    var inspector_menu_button_pos = [_]f32{ 0.0, 0.0 };

    zgui.beginDisabled(.{ .disabled = !can_use_inspector });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = inspector_button_color });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = inspector_hover_color });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = inspector_active_color });
    if (zgui.button("##browser-inspect", .{ .w = button_size, .h = button_size })) {
        state.toggleBrowserInspector();
    }
    drawCenteredIcon(inspect_icon, if (can_use_inspector) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE);
    if (zgui.isItemHovered(.{ .delay_normal = true, .allow_when_disabled = true })) {
        _ = zgui.beginTooltip();
        if (can_use_inspector) {
            zgui.text("Toggle the bundled DOM inspector inside the CEF pane\nCurrent mode: {s}", .{inspector_mode.label()});
        } else {
            zgui.textUnformatted("The page inspector currently requires a real CEF runtime");
        }
        zgui.endTooltip();
    }

    zgui.sameLine(.{ .spacing = 0.0 });
    inspector_menu_button_pos = zgui.getCursorScreenPos();
    if (zgui.button("##browser-inspect-mode", .{ .w = inspect_menu_button_width, .h = button_size })) {
        zgui.openPopup(BROWSER_INSPECTOR_MODE_MENU_ID, .{});
    }
    drawDownChevron(
        if (can_use_inspector) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE,
        inspector_menu_button_pos,
        inspect_menu_button_width,
        button_size,
    );
    if (zgui.isItemHovered(.{ .delay_normal = true, .allow_when_disabled = true })) {
        _ = zgui.beginTooltip();
        if (can_use_inspector) {
            zgui.text("Choose the browser inspector mode\nCurrent mode: {s}", .{inspector_mode.label()});
        } else {
            zgui.textUnformatted("The page inspector currently requires a real CEF runtime");
        }
        zgui.endTooltip();
    }
    zgui.popStyleColor(.{ .count = 3 });
    zgui.endDisabled();

    zgui.setNextWindowPos(.{
        .x = inspector_menu_button_pos[0] + inspect_menu_button_width - theme.scaledUi(180.0),
        .y = inspector_menu_button_pos[1] + button_size + theme.scaledUi(6.0),
        .cond = .appearing,
    });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = theme.scaledUi(12.0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(8.0), theme.scaledUi(8.0) } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .popup_bg, .c = colors.rgba(26, 28, 34, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.rgba(66, 68, 78, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 3 });
    }
    zgui.setNextWindowSize(.{ .w = theme.scaledUi(180.0), .h = 0.0, .cond = .appearing });
    if (zgui.beginPopup(BROWSER_INSPECTOR_MODE_MENU_ID, .{})) {
        defer zgui.endPopup();

        if (renderInspectorModeMenuRow("Point", inspector_mode == .point)) {
            state.setBrowserInspectorMode(.point);
            zgui.closeCurrentPopup();
        }
        if (renderInspectorModeMenuRow("Draw Box", inspector_mode == .draw_box)) {
            state.setBrowserInspectorMode(.draw_box);
            zgui.closeCurrentPopup();
        }
        if (renderInspectorModeMenuRow("Draw Freeform", inspector_mode == .draw_freeform)) {
            state.setBrowserInspectorMode(.draw_freeform);
            zgui.closeCurrentPopup();
        }
    }

    zgui.sameLine(.{ .spacing = gap });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("##browser-close", .{ .w = button_size, .h = button_size })) {
        state.closeBrowser();
    }
    drawCenteredIcon(close_icon, theme.COLOR_WHITE);
    zgui.popStyleColor(.{ .count = 3 });
    //NOTE: END OF BrowserToolbar
}

fn drawDownChevron(color: [4]f32, start: [2]f32, width: f32, height: f32) void {
    const center_x = start[0] + width * 0.5;
    const center_y = start[1] + height * 0.5;
    const half = theme.scaledUi(3.5);
    const col = zgui.colorConvertFloat4ToU32(color);
    const draw_list = zgui.getWindowDrawList();
    draw_list.addLine(.{
        .p1 = .{ center_x - half, center_y - half * 0.5 },
        .p2 = .{ center_x, center_y + half * 0.5 },
        .col = col,
        .thickness = theme.scaledUi(1.8),
    });
    draw_list.addLine(.{
        .p1 = .{ center_x + half, center_y - half * 0.5 },
        .p2 = .{ center_x, center_y + half * 0.5 },
        .col = col,
        .thickness = theme.scaledUi(1.8),
    });
}

fn renderInspectorModeMenuRow(label: []const u8, selected: bool) bool {
    var row_buf = std.mem.zeroes([64:0]u8);
    const row_label = std.fmt.bufPrintZ(
        &row_buf,
        "{s}{s}",
        .{ if (selected) "• " else "  ", label },
    ) catch unreachable;
    return zgui.selectable(row_label, .{
        .selected = selected,
        .h = theme.scaledUi(32.0),
    });
}

/// Renders the in-app browser pane canvas or the current scaffold placeholder.
fn renderPaneCanvas(state: *app_state.AppState) void {
    const browser_state = state.browserState();
    const avail = zgui.getContentRegionAvail();
    const canvas_height = @max(avail[1], theme.scaledUi(180.0));
    const width_px: u32 = @intFromFloat(@max(avail[0], 1.0));
    const height_px: u32 = @intFromFloat(@max(canvas_height, 1.0));
    const input_size = .{ @as(f32, @floatFromInt(width_px)), @as(f32, @floatFromInt(height_px)) };
    browser_state.controller.resizePane(width_px, height_px) catch {};

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(9, 11, 16, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 1 });
    }
    //NOTE: Begin of BrowserPaneCanvas
    _ = zgui.beginChild("BrowserPaneCanvas", .{
        .w = 0.0,
        .h = canvas_height,
        .child_flags = .{
            .border = false,
        },
    });
    defer {
        zgui.endChild();
    }

    const pane_pos = zgui.getWindowPos();
    const pane_size = zgui.getWindowSize();
    const pane_hovered = zgui.isWindowHovered(.{});

    if (browser_state.controller.paneTexture()) |pane_texture| {
        if (pane_texture.isReady()) {
            // Preserve the browser snapshot aspect ratio so compositor-sized frames are not stretched into the pane.
            const image_size = runtime.scaledImageSize(
                @intCast(pane_texture.width),
                @intCast(pane_texture.height),
                zgui.getContentRegionAvail()[0],
                zgui.getContentRegionAvail()[1],
            );
            const x_offset = (pane_size[0] - image_size[0]) * 0.5;
            const y_offset = (pane_size[1] - image_size[1]) * 0.5;
            if (y_offset > 0.0) {
                zgui.dummy(.{ .w = 0.0, .h = y_offset });
            }
            if (x_offset > 0.0) {
                zgui.setCursorPosX(zgui.getCursorPosX() + x_offset);
            }
            const image_pos = zgui.getCursorScreenPos();
            state.noteBrowserPaneRegion(
                image_pos,
                .{ image_pos[0] + image_size[0], image_pos[1] + image_size[1] },
                input_size,
                pane_hovered,
            );
            zgui.image(runtime.textureRefFromGlId(pane_texture.texture_id), .{
                .w = image_size[0],
                .h = image_size[1],
            });
            //NOTE: END OF BrowserPaneCanvas
            return;
        }
    }

    // Fall back to the full pane bounds while the browser frame has not arrived yet.
    state.noteBrowserPaneRegion(
        pane_pos,
        .{ pane_pos[0] + pane_size[0], pane_pos[1] + pane_size[1] },
        input_size,
        pane_hovered,
    );

    renderPanePlaceholder();
    //NOTE: END OF BrowserPaneCanvas
}

/// Keeps the pane visually blank until the first browser frame arrives.
fn renderPanePlaceholder() void {}
