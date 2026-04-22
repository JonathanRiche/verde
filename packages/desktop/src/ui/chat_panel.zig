//! Chat workspace rendering for the native shell.

const std = @import("std");

const zig_dif = @import("zig_dif");
const zgui = @import("zgui");
const colors = @import("colors.zig");
const browser_panel = @import("browser.zig");
const chat_markdown = @import("chat_markdown.zig");
const composer_pickers = @import("composer_pickers.zig");
const file_icons = @import("file_icons.zig");
const runtime = @import("runtime.zig");
const terminal_panel = @import("terminal_panel.zig");
const theme = @import("theme.zig");
const app_state = @import("../state.zig");

const HEADER_OPEN_MENU_ID: [:0]const u8 = "ChatHeaderOpenMenu";
const WorkspaceLayout = struct {
    body_height: f32,
    browser_gap: f32,
    browser_width: f32,
    terminal_gap: f32,
    terminal_handle_height: f32,
    terminal_height: f32,
};

const TranscriptMarkdownCopyFrame = struct {
    requested: bool,
    builder: std.ArrayList(u8) = .empty,
    copied_any: bool = false,

    fn deinit(self: *TranscriptMarkdownCopyFrame, allocator: std.mem.Allocator) void {
        self.builder.deinit(allocator);
        self.* = undefined;
    }

    fn append(self: *TranscriptMarkdownCopyFrame, allocator: std.mem.Allocator, text: []const u8) void {
        if (text.len == 0) return;
        if (self.copied_any) {
            self.builder.appendSlice(allocator, "\n\n") catch return;
        }
        self.builder.appendSlice(allocator, text) catch return;
        self.copied_any = true;
    }
};

const OrderedTranscriptMarkdownSelection = struct {
    start: app_state.TranscriptMarkdownSelectionPoint,
    end: app_state.TranscriptMarkdownSelectionPoint,
};

const TranscriptMarkdownSelectAllFrame = struct {
    requested: bool,
    first: ?app_state.TranscriptMarkdownSelectionPoint = null,
    last: ?app_state.TranscriptMarkdownSelectionPoint = null,

    fn noteMessage(
        self: *TranscriptMarkdownSelectAllFrame,
        message_index: usize,
        first: chat_markdown.SelectionPoint,
        last: chat_markdown.SelectionPoint,
    ) void {
        if (self.first == null) {
            self.first = .{
                .message_index = message_index,
                .point = first,
            };
        }
        self.last = .{
            .message_index = message_index,
            .point = last,
        };
    }
};

// Renders the transcript, composer, and any bottom-docked workspace panels.
fn inner_workspace(state: *app_state.AppState) void {
    //INNER UI FOR CHAT WORKSPACE
    const inner_pad_y = theme.scaledUi(18.0);

    // No horizontal padding here so the transcript scrollbar reaches the far right edge.
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });

    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(0, 0, 0, 0) });

    defer zgui.popStyleVar(.{ .count = 1 });
    defer zgui.popStyleColor(.{ .count = 1 });
    _ = zgui.beginChild("ChatWorkspaceInner", .{
        .w = 0.0,
        .h = 0.0,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
    });

    defer zgui.endChild();
    zgui.dummy(.{ .w = 0.0, .h = inner_pad_y });

    if (state.projects.items.len == 0) {
        state.terminal_focused = false;
        const empty_pad_x = chatColumnInnerPadding(zgui.getContentRegionAvail()[0], false);
        zgui.indent(.{ .indent_w = empty_pad_x });
        zgui.textColored(theme.COLOR_WHITE, "No projects yet", .{});
        zgui.textColored(theme.COLOR_TEXT_MUTED, "Use the + button in the left rail, browse to a folder, then add its path here.", .{});
        zgui.unindent(.{ .indent_w = empty_pad_x });
        return;
    }

    const content = zgui.getContentRegionAvail();
    const layout = computeWorkspaceLayout(state, content[0], content[1]);
    const split_active = layout.browser_width > 0.0;
    const chat_column_width = if (split_active)
        @max(content[0] - layout.browser_gap - layout.browser_width, theme.scaledUi(240.0))
    else
        content[0];
    const inner_pad_x = chatColumnInnerPadding(chat_column_width, split_active);
    if (split_active) {
        zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
        defer zgui.popStyleVar(.{ .count = 1 });
        _ = zgui.beginChild("ChatBrowserSplit", .{
            .w = 0.0,
            .h = layout.body_height,
            .child_flags = .{
                .border = false,
                .always_use_window_padding = true,
            },
        });
        defer zgui.endChild();

        renderChatColumn(state, chat_column_width, layout.body_height, inner_pad_x);
        zgui.sameLine(.{ .spacing = layout.browser_gap });
        browser_panel.renderDock(state, layout.browser_width, layout.body_height);
    } else {
        renderChatColumn(state, chat_column_width, layout.body_height, inner_pad_x);
    }

    if (layout.terminal_height > 0.0) {
        zgui.dummy(.{ .w = 0.0, .h = layout.terminal_gap });
        renderTerminalResizeHandle(state, content[0], content[1], layout.terminal_handle_height);
        terminal_panel.renderDock(state, content[0], layout.terminal_height);
    }
}

// Derives responsive horizontal padding for the chat column so transcript and composer stay usable in split-pane layouts.
fn chatColumnInnerPadding(column_width: f32, split_active: bool) f32 {
    if (split_active) {
        return theme.clampf(column_width * 0.075, theme.scaledUi(18.0), theme.scaledUi(56.0));
    }
    return theme.clampf(column_width * 0.14, theme.scaledUi(24.0), theme.scaledUi(160.0));
}

// Renders the transcript and composer column that stays alongside the browser pane.
fn renderChatColumn(state: *app_state.AppState, width: f32, height: f32, inner_pad_x: f32) void {
    _ = zgui.beginChild("ChatBrowserSplitColumn", .{
        .w = width,
        .h = height,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
    });
    defer zgui.endChild();

    const composer_gap = theme.scaledUi(8.0);
    const composer_height = theme.clampf(height * 0.27, theme.scaledUi(168.0), @min(height * 0.42, theme.scaledUi(320.0)));
    const transcript_height = @max(height - composer_height - composer_gap, theme.scaledUi(120.0));
    renderTranscript(state, width, transcript_height, inner_pad_x);
    zgui.dummy(.{ .w = 0.0, .h = composer_gap });
    // Indent composer so it stays centered while transcript scrollbar is at far right.
    zgui.indent(.{ .indent_w = inner_pad_x });
    const composer_width = @max(width - 2 * inner_pad_x, theme.scaledUi(120.0));
    renderComposer(state, composer_width, @max(height - transcript_height - composer_gap, theme.scaledUi(120.0)));
    zgui.unindent(.{ .indent_w = inner_pad_x });
}

// Balances the horizontal browser split against the bottom terminal dock.
fn computeWorkspaceLayout(state: *app_state.AppState, available_width: f32, available_height: f32) WorkspaceLayout {
    const browser_visible = state.isBrowserVisible();
    const browser_gap = if (browser_visible) theme.scaledUi(12.0) else 0.0;
    const terminal_visible = state.isTerminalVisible();
    const terminal_gap = if (terminal_visible) theme.scaledUi(12.0) else 0.0;
    const terminal_handle_height = if (terminal_visible) theme.scaledUi(12.0) else 0.0;
    const minimum_workspace = theme.scaledUi(120.0);
    const preferred_terminal_height = if (terminal_visible) state.terminalPanelHeight(available_height) else 0.0;
    var terminal_height = preferred_terminal_height;
    const available_terminal_height = @max(available_height - minimum_workspace - terminal_gap - terminal_handle_height, 0.0);
    if (terminal_height > available_terminal_height) {
        terminal_height = available_terminal_height;
    }
    const body_height = @max(available_height - terminal_gap - terminal_handle_height - terminal_height, theme.scaledUi(120.0));
    const browser_width = if (browser_visible)
        @min(
            state.browserPanelWidth(available_width - browser_gap),
            @max(available_width - browser_gap - theme.scaledUi(260.0), theme.scaledUi(240.0)),
        )
    else
        0.0;

    return .{
        .body_height = body_height,
        .browser_gap = if (browser_width > 0.0) browser_gap else 0.0,
        .browser_width = browser_width,
        .terminal_gap = if (terminal_height > 0.0) terminal_gap else 0.0,
        .terminal_handle_height = if (terminal_height > 0.0) terminal_handle_height else 0.0,
        .terminal_height = terminal_height,
    };
}

fn renderTerminalResizeHandle(state: *app_state.AppState, width: f32, available_height: f32, height: f32) void {
    if (height <= 0.0) return;

    const draw_list = zgui.getWindowDrawList();
    const handle_pos = zgui.getCursorScreenPos();
    _ = zgui.invisibleButton("##terminal-resize-handle", .{ .w = width, .h = height });

    const hovered = zgui.isItemHovered(.{});
    const active = zgui.isItemActive();
    if (hovered or active) {
        zgui.setMouseCursor(.resize_ns);
    }

    if (zgui.isItemActivated()) {
        state.beginTerminalResizeDrag(available_height);
        zgui.resetMouseDragDelta(.left);
    }

    if (active) {
        const drag_delta = zgui.getMouseDragDelta(.left, .{});
        state.updateTerminalResizeDrag(available_height, drag_delta[1]);
    } else if (zgui.isItemDeactivated() or !zgui.isMouseDown(.left)) {
        state.endTerminalResizeDrag();
    }

    const handle_min = handle_pos;
    const handle_max = .{ handle_pos[0] + width, handle_pos[1] + height };
    const line_color = if (active)
        zgui.colorConvertFloat4ToU32(theme.COLOR_GREEN)
    else if (hovered)
        zgui.colorConvertFloat4ToU32(theme.lighten(theme.COLOR_PANEL_MUTED, 0.10))
    else
        zgui.colorConvertFloat4ToU32(theme.COLOR_PANEL_MUTED);
    const grip_width = theme.clampf(width * 0.12, theme.scaledUi(40.0), theme.scaledUi(84.0));
    const grip_height = theme.scaledUi(3.0);
    const center_y = handle_min[1] + height * 0.5;
    const grip_min = .{ handle_min[0] + (width - grip_width) * 0.5, center_y - grip_height * 0.5 };
    const grip_max = .{ grip_min[0] + grip_width, grip_min[1] + grip_height };

    draw_list.addLine(.{
        .p1 = .{ handle_min[0], center_y },
        .p2 = .{ handle_max[0], center_y },
        .col = line_color,
        .thickness = 1.0,
    });
    draw_list.addRectFilled(.{
        .pmin = grip_min,
        .pmax = grip_max,
        .col = line_color,
        .rounding = grip_height * 0.5,
    });
}

/// Renders the chat workspace shell beside the sidebar.
pub fn renderWorkspace(state: *app_state.AppState, width: f32, height: f32) void {
    zgui.setCursorPos(.{ zgui.getCursorPosX(), 0.0 });
    //OUTER UI FOR CHAT WORKSPACE
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 0.0 });
    // zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(30.0), theme.scaledUi(18.0) } });

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.CHAT_BLACK });
    defer zgui.popStyleColor(.{ .count = 1 });
    defer zgui.popStyleVar(.{ .count = 2 });
    _ = zgui.beginChild("ChatWorkspace", .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = false },
    });
    defer zgui.endChild();

    renderHeader(state);
    zgui.separator();
    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(5.0) });
    //END OUTER UI FOR CHAT WORKSPACE
    inner_workspace(state);
}

/// Renders the current thread title block.
fn renderHeader(state: anytype) void {
    const header_height = theme.scaledUi(60.0);
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(0, 0, 0, 0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(28.0), theme.scaledUi(18.0) } });

    defer zgui.popStyleVar(.{ .count = 1 });
    defer zgui.popStyleColor(.{ .count = 1 });

    _ = zgui.beginChild("ChatHeader", .{
        .w = 0.0,
        .h = header_height,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_saved_settings = true,
        },
    });
    defer zgui.endChild();

    const header_start = zgui.getCursorPos();
    const header_start_x = zgui.getCursorPosX();
    const header_content_width = zgui.getContentRegionAvail()[0];
    const has_project = state.projects.items.len > 0;
    const title_text = if (has_project)
        if (state.currentThread().committed) state.currentThread().title else "New chat"
    else
        "No project selected";

    const button_height = theme.scaledUi(30.0);
    const button_gap = theme.scaledUi(8.0);
    const title_actions_gap = theme.scaledUi(16.0);
    const open_label = if (has_project) state.defaultOpenButtonLabel() else "";
    const open_icon_texture = if (has_project) state.defaultOpenIconTexture() else null;
    const open_draw_folder_icon = if (has_project) state.defaultOpenShowsFolderIcon() else false;
    const open_has_icon = open_draw_folder_icon or open_icon_texture != null;
    const open_button_width = if (has_project)
        theme.clampf(
            zgui.calcTextSize(open_label, .{})[0] + theme.scaledUi(if (open_has_icon) 54.0 else 28.0),
            theme.scaledUi(82.0),
            theme.scaledUi(184.0),
        )
    else
        0.0;
    const menu_button_width = if (has_project) theme.scaledUi(30.0) else 0.0;
    const browser_button_width = if (has_project) theme.scaledUi(106.0) else 0.0;
    const actions_width = if (has_project)
        open_button_width + menu_button_width + browser_button_width + button_gap * 2.0
    else
        0.0;
    const action_x = header_start_x + if (has_project)
        @max(theme.scaledUi(180.0), header_content_width - actions_width)
    else
        header_content_width;
    const title_max_width = if (has_project)
        @max(action_x - header_start_x - title_actions_gap, theme.scaledUi(96.0))
    else
        header_content_width;
    var title_buf: [256]u8 = undefined;
    const display_title = truncateTextToWidth(&title_buf, title_text, title_max_width);

    if (theme.heading_font) |font| {
        zgui.pushFont(font, 18);
        defer zgui.popFont();
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{display_title});
    } else {
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{display_title});
    }

    if (!has_project) return;

    const base_y = header_start[1];
    const can_open_folder = state.canOpenCurrentProjectDirectory();
    const can_open_configured = state.canOpenCurrentProjectEditor(.configured);
    const can_open_cursor = state.canOpenCurrentProjectEditor(.cursor);
    const can_open_vscode = state.canOpenCurrentProjectEditor(.vscode);
    const can_open_zed = state.canOpenCurrentProjectEditor(.zed);
    const configured_editor_logo = state.editorLogoTextureForTarget(.configured);
    const cursor_logo = state.editorLogoTextureForTarget(.cursor);
    const vscode_logo = state.editorLogoTextureForTarget(.vscode);
    const zed_logo = state.editorLogoTextureForTarget(.zed);

    zgui.setCursorPos(.{ action_x, base_y });
    const can_run_default_open = state.canRunDefaultOpenAction();
    zgui.beginDisabled(.{ .disabled = !can_run_default_open });
    const split_base_color = theme.COLOR_PANEL_ALT;
    const split_hover_color = theme.lighten(theme.COLOR_PANEL_ALT, 0.08);
    const split_active_color = theme.lighten(theme.COLOR_PANEL_ALT, 0.14);
    if (renderHeaderSplitTextButton(open_label, open_button_width, button_height, split_base_color, split_hover_color, split_active_color, open_icon_texture, open_draw_folder_icon)) {
        state.runDefaultOpenAction();
    }
    if (zgui.isItemHovered(.{ .delay_normal = true, .allow_when_disabled = true })) {
        _ = zgui.beginTooltip();
        zgui.textUnformatted(state.defaultOpenTooltip());
        zgui.endTooltip();
    }
    zgui.endDisabled();

    zgui.sameLine(.{ .spacing = 0.0 });
    const menu_button_pos = zgui.getCursorScreenPos();
    if (renderHeaderChevronButton(menu_button_width, button_height, theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.04), theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.12), theme.darken(theme.COLOR_SECONDARY_GREEN, 0.04))) {
        zgui.openPopup(HEADER_OPEN_MENU_ID, .{});
    }

    zgui.setNextWindowPos(.{
        .x = menu_button_pos[0],
        .y = menu_button_pos[1] + button_height + theme.scaledUi(6.0),
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
    zgui.setNextWindowSize(.{ .w = theme.scaledUi(250.0), .h = 0.0, .cond = .appearing });
    if (zgui.beginPopup(HEADER_OPEN_MENU_ID, .{})) {
        defer zgui.endPopup();
        var configured_editor_label_buf = std.mem.zeroes([96:0]u8);
        const configured_editor_label = if (state.configuredEditorDisplayName()) |name|
            std.fmt.bufPrintZ(&configured_editor_label_buf, "Open in {s}", .{name}) catch "Open in configured editor"
        else
            "Open in configured editor";

        if (renderHeaderOpenMenuRow(0, "Open folder", null, true, can_open_folder)) {
            state.openCurrentProjectDirectory();
            zgui.closeCurrentPopup();
        }
        if (can_open_configured and renderHeaderOpenMenuRow(1, configured_editor_label, configured_editor_logo, false, true)) {
            state.openCurrentProjectEditor(.configured);
            zgui.closeCurrentPopup();
        }
        if (can_open_cursor and renderHeaderOpenMenuRow(2, "Open in Cursor", cursor_logo, false, true)) {
            state.openCurrentProjectEditor(.cursor);
            zgui.closeCurrentPopup();
        }
        if (can_open_vscode and renderHeaderOpenMenuRow(3, "Open in VS Code", vscode_logo, false, true)) {
            state.openCurrentProjectEditor(.vscode);
            zgui.closeCurrentPopup();
        }
        if (can_open_zed and renderHeaderOpenMenuRow(4, "Open in Zed", zed_logo, false, true)) {
            state.openCurrentProjectEditor(.zed);
            zgui.closeCurrentPopup();
        }
    }

    zgui.sameLine(.{ .spacing = button_gap });
    if (renderHeaderBrowserButton(browser_button_width, button_height)) {
        state.toggleBrowser();
    }
    if (zgui.isItemHovered(.{ .delay_normal = true })) {
        _ = zgui.beginTooltip();
        zgui.textUnformatted("Open the browser controls and native webview runtime");
        zgui.endTooltip();
    }
}

fn truncateTextToWidth(buffer: []u8, value: []const u8, max_width: f32) []const u8 {
    if (buffer.len == 0 or max_width <= 0.0) return "";
    if (zgui.calcTextSize(value, .{})[0] <= max_width) return value;

    const ellipsis = "...";
    const ellipsis_width = zgui.calcTextSize(ellipsis, .{})[0];
    if (ellipsis_width > max_width) return "";
    if (buffer.len <= ellipsis.len) return ellipsis;

    const max_prefix_len = @min(value.len, buffer.len - ellipsis.len);
    var low: usize = 0;
    var high: usize = max_prefix_len;

    while (low < high) {
        const mid = low + @divFloor(high - low + 1, 2);
        @memcpy(buffer[0..mid], value[0..mid]);
        @memcpy(buffer[mid .. mid + ellipsis.len], ellipsis);
        const candidate = buffer[0 .. mid + ellipsis.len];
        if (zgui.calcTextSize(candidate, .{})[0] <= max_width) {
            low = mid;
        } else {
            high = mid - 1;
        }
    }

    @memcpy(buffer[0..low], value[0..low]);
    @memcpy(buffer[low .. low + ellipsis.len], ellipsis);
    return buffer[0 .. low + ellipsis.len];
}

fn renderHeaderActionButton(
    label: [:0]const u8,
    width: f32,
    height: f32,
    base_color: [4]f32,
    hover_color: [4]f32,
    active_color: [4]f32,
) bool {
    zgui.pushStyleColor4f(.{ .idx = .button, .c = base_color });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = hover_color });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = active_color });
    defer zgui.popStyleColor(.{ .count = 3 });
    return zgui.button(label, .{ .w = width, .h = height });
}

/// Browser button with a globe icon to the left of the label.
fn renderHeaderBrowserButton(width: f32, height: f32) bool {
    const start = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton("##header-browser-button", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();

    const bg = if (hovered) theme.lighten(theme.COLOR_PANEL_ALT, 0.08) else theme.COLOR_PANEL_ALT;
    draw_list.addRectFilled(.{
        .pmin = start,
        .pmax = .{ start[0] + width, start[1] + height },
        .col = zgui.colorConvertFloat4ToU32(bg),
        .rounding = theme.scaledUi(6.0),
    });

    const label = "Browser";
    const text_size = zgui.calcTextSize(label, .{});
    const icon_size = theme.scaledUi(12.0);
    const icon_gap = theme.scaledUi(5.0);
    const total_content = icon_size + icon_gap + text_size[0];
    const content_x = start[0] + (width - total_content) * 0.5;
    const cy = start[1] + height * 0.5;

    drawGlobeIcon(draw_list, content_x, cy, icon_size, theme.COLOR_TEXT_MUTED);

    const text_x = content_x + icon_size + icon_gap;
    const text_y = start[1] + (height - text_size[1]) * 0.5;
    draw_list.addTextUnformatted(.{ text_x, text_y }, zgui.colorConvertFloat4ToU32(theme.COLOR_WHITE), label);

    return clicked;
}

/// Draws a globe/world icon: a circle with horizontal and vertical arc lines.
fn drawGlobeIcon(draw_list: zgui.DrawList, x: f32, cy: f32, size: f32, color: [4]f32) void {
    const col = zgui.colorConvertFloat4ToU32(color);
    const r = size * 0.5;
    const cx = x + r;
    const t = theme.scaledUi(1.3);

    // Outer circle
    draw_list.addCircle(.{ .p = .{ cx, cy }, .r = r, .col = col, .thickness = t });

    // Vertical meridian (ellipse approximated as a narrower arc)
    // Left half of vertical ellipse
    const ew = r * 0.4; // ellipse half-width
    draw_list.addBezierCubic(.{
        .p1 = .{ cx, cy - r },
        .p2 = .{ cx - ew * 1.8, cy - r * 0.5 },
        .p3 = .{ cx - ew * 1.8, cy + r * 0.5 },
        .p4 = .{ cx, cy + r },
        .col = col,
        .thickness = t,
    });
    // Right half of vertical ellipse
    draw_list.addBezierCubic(.{
        .p1 = .{ cx, cy - r },
        .p2 = .{ cx + ew * 1.8, cy - r * 0.5 },
        .p3 = .{ cx + ew * 1.8, cy + r * 0.5 },
        .p4 = .{ cx, cy + r },
        .col = col,
        .thickness = t,
    });

    // Horizontal line across the middle
    draw_list.addLine(.{ .p1 = .{ cx - r, cy }, .p2 = .{ cx + r, cy }, .col = col, .thickness = t });
}

fn renderHeaderSplitTextButton(
    label: []const u8,
    width: f32,
    height: f32,
    base_color: [4]f32,
    hover_color: [4]f32,
    active_color: [4]f32,
    texture: ?app_state.CachedImageTexture,
    draw_folder: bool,
) bool {
    const start = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton("##header-open-button", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const active = zgui.isItemActive();
    const draw_list = zgui.getWindowDrawList();
    const bg_color = if (active)
        active_color
    else if (hovered)
        hover_color
    else
        base_color;
    const rounding = theme.scaledUi(10.0);

    draw_list.addRectFilled(.{
        .pmin = start,
        .pmax = .{ start[0] + width, start[1] + height },
        .col = zgui.colorConvertFloat4ToU32(bg_color),
        .rounding = rounding,
        .flags = .{ .round_corners_top_left = true, .round_corners_bottom_left = true },
    });

    const text_color = if (hovered or active) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    const icon_slot = theme.scaledUi(16.0);
    const icon_x = start[0] + theme.scaledUi(14.0);
    const icon_center_y = start[1] + height * 0.5;
    const text_x = if (draw_folder or texture != null)
        icon_x + icon_slot + theme.scaledUi(10.0)
    else
        start[0] + theme.scaledUi(14.0);
    const text_size = zgui.calcTextSize(label, .{});
    if (draw_folder) {
        drawFolderIcon(draw_list, icon_x, icon_center_y, text_color);
    } else if (texture) |cached| {
        const scaled = runtime.scaledImageSize(cached.width, cached.height, icon_slot, icon_slot);
        const icon_min = .{
            icon_x + (icon_slot - scaled[0]) * 0.5,
            start[1] + (height - scaled[1]) * 0.5,
        };
        draw_list.addImage(runtime.textureRefFromGlId(cached.texture_id), .{
            .pmin = icon_min,
            .pmax = .{ icon_min[0] + scaled[0], icon_min[1] + scaled[1] },
        });
    }

    const text_pos = .{ text_x, start[1] + (height - text_size[1]) * 0.5 };
    draw_list.addTextUnformatted(
        text_pos,
        zgui.colorConvertFloat4ToU32(text_color),
        label,
    );
    return clicked;
}

fn renderHeaderChevronButton(
    width: f32,
    height: f32,
    base_color: [4]f32,
    hover_color: [4]f32,
    active_color: [4]f32,
) bool {
    const start = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton("##header-chevron-button", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const active = zgui.isItemActive();
    const draw_list = zgui.getWindowDrawList();
    const bg_color = if (active)
        active_color
    else if (hovered)
        hover_color
    else
        base_color;
    const rounding = theme.scaledUi(10.0);

    draw_list.addRectFilled(.{
        .pmin = start,
        .pmax = .{ start[0] + width, start[1] + height },
        .col = zgui.colorConvertFloat4ToU32(bg_color),
        .rounding = rounding,
        .flags = .{ .round_corners_top_right = true, .round_corners_bottom_right = true },
    });
    draw_list.addLine(.{
        .p1 = .{ start[0], start[1] + theme.scaledUi(5.0) },
        .p2 = .{ start[0], start[1] + height - theme.scaledUi(5.0) },
        .col = zgui.colorConvertFloat4ToU32(colors.rgba(22, 24, 28, 110)),
        .thickness = 1.0,
    });

    drawChevron(
        draw_list,
        start[0] + width * 0.5 + theme.scaledUi(2.0),
        start[1] + height * 0.5,
        if (hovered or active) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE,
    );
    return clicked;
}

fn renderHeaderOpenMenuRow(
    id: i32,
    label: []const u8,
    texture: ?app_state.CachedImageTexture,
    draw_folder: bool,
    enabled: bool,
) bool {
    zgui.pushIntId(id);
    defer zgui.popId();

    const row_height = theme.scaledUi(34.0);
    const row_width = zgui.getWindowWidth() - theme.scaledUi(4.0);
    const clicked = zgui.invisibleButton("##header-open-menu-row", .{ .w = row_width, .h = row_height });
    const hovered = zgui.isItemHovered(.{});
    const item_min = zgui.getItemRectMin();
    const item_max = zgui.getItemRectMax();
    const draw_list = zgui.getWindowDrawList();
    const row_bg = if (!enabled)
        null
    else if (hovered)
        colors.rgba(42, 44, 52, 255)
    else
        null;

    if (row_bg) |bg| {
        draw_list.addRectFilled(.{
            .pmin = .{ item_min[0], item_min[1] },
            .pmax = .{ item_max[0], item_max[1] },
            .col = zgui.colorConvertFloat4ToU32(bg),
            .rounding = theme.scaledUi(8.0),
        });
    }

    const icon_slot = theme.scaledUi(18.0);
    const icon_x = item_min[0] + theme.scaledUi(12.0);
    const icon_center_y = item_min[1] + row_height * 0.5;
    const text_x = icon_x + icon_slot + theme.scaledUi(10.0);
    const text_size = zgui.calcTextSize(label, .{});
    const text_color = if (!enabled)
        theme.COLOR_TEXT_SUBTLE
    else if (hovered)
        theme.COLOR_WHITE
    else
        theme.COLOR_TEXT_MUTED;

    if (draw_folder) {
        drawFolderIcon(draw_list, icon_x, icon_center_y, text_color);
    } else if (texture) |cached| {
        const scaled = runtime.scaledImageSize(cached.width, cached.height, icon_slot, icon_slot);
        const icon_min = .{
            icon_x + (icon_slot - scaled[0]) * 0.5,
            item_min[1] + (row_height - scaled[1]) * 0.5,
        };
        draw_list.addImage(runtime.textureRefFromGlId(cached.texture_id), .{
            .pmin = icon_min,
            .pmax = .{ icon_min[0] + scaled[0], icon_min[1] + scaled[1] },
        });
    }

    draw_list.addTextUnformatted(
        .{ text_x, item_min[1] + (row_height - text_size[1]) * 0.5 },
        zgui.colorConvertFloat4ToU32(text_color),
        label,
    );
    return enabled and clicked;
}

fn drawFolderIcon(draw_list: zgui.DrawList, x: f32, center_y: f32, color: [4]f32) void {
    const col = zgui.colorConvertFloat4ToU32(color);
    const fw = theme.scaledUi(13.0);
    const fh = theme.scaledUi(9.0);
    draw_list.addRectFilled(.{
        .pmin = .{ x, center_y - fh * 0.5 - theme.scaledUi(2.0) },
        .pmax = .{ x + fw * 0.4, center_y - fh * 0.5 + theme.scaledUi(1.0) },
        .col = col,
        .rounding = theme.scaledUi(1.0),
    });
    draw_list.addRectFilled(.{
        .pmin = .{ x, center_y - fh * 0.5 },
        .pmax = .{ x + fw, center_y + fh * 0.5 },
        .col = col,
        .rounding = theme.scaledUi(1.5),
    });
}

fn drawChevron(draw_list: zgui.DrawList, x: f32, center_y: f32, color: [4]f32) void {
    const half = theme.scaledUi(4.0);
    const col = zgui.colorConvertFloat4ToU32(color);
    draw_list.addLine(.{
        .p1 = .{ x - half, center_y - half },
        .p2 = .{ x, center_y },
        .col = col,
        .thickness = theme.scaledUi(1.8),
    });
    draw_list.addLine(.{
        .p1 = .{ x - half, center_y + half },
        .p2 = .{ x, center_y },
        .col = col,
        .thickness = theme.scaledUi(1.8),
    });
}

/// Renders transcript history plus any in-flight stream state.
fn renderTranscript(state: *app_state.AppState, width: f32, height: f32, pad_x: f32) void {
    const selected_project_index = state.selected_project_index;
    const selected_thread_index = state.currentProject().selected_thread_index;
    const transcript_changed = state.transcript_project_index == null or
        state.transcript_thread_index == null or
        state.transcript_project_index.? != selected_project_index or
        state.transcript_thread_index.? != selected_thread_index;
    if (transcript_changed) {
        state.transcript_project_index = selected_project_index;
        state.transcript_thread_index = selected_thread_index;
        state.requestTranscriptScrollToBottom();
    }

    // Outer scrollable region spans full width so the scrollbar sits at the far right edge.
    _ = zgui.beginChild("Transcript", .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = false },
    });
    defer zgui.endChild();

    const has_pending_stream = runtime.isSendPending(state);
    updateTranscriptAutoFollow(state, has_pending_stream);
    const should_follow_stream = state.transcript_auto_follow_pending and has_pending_stream;

    // Inner content wrapper with horizontal padding; auto-resizes vertically so the
    // outer Transcript child handles scrolling while content stays centered.
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ pad_x, 0 } });
    _ = zgui.beginChild("TranscriptContent", .{
        .w = 0.0,
        .h = 0.0,
        .child_flags = .{
            .auto_resize_y = true,
            .always_use_window_padding = true,
        },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
        },
    });

    const ctrl_pressed = zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl);
    const transcript_focus_active = state.isTranscriptFocused() or zgui.isWindowFocused(.{ .child_windows = true });
    var markdown_copy_frame: TranscriptMarkdownCopyFrame = .{
        .requested = ctrl_pressed and zgui.isKeyPressed(.c, false) and state.transcriptMarkdownSelectionActive(),
    };
    defer markdown_copy_frame.deinit(std.heap.page_allocator);
    var markdown_select_all_frame: TranscriptMarkdownSelectAllFrame = .{
        .requested = ctrl_pressed and zgui.isKeyPressed(.a, false) and transcript_focus_active,
    };

    if (state.currentThread().messages.items.len == 0 and !has_pending_stream) {
        zgui.textColored(theme.COLOR_WHITE, "No messages yet", .{});
        zgui.textColored(theme.COLOR_TEXT_MUTED, "Choose a provider, type a prompt below, and start the first chat for this directory.", .{});
    } else {
        for (state.currentThread().messages.items, 0..) |message, index| {
            renderTranscriptMessage(state, @intCast(index + 1), index, message.role, message.author, message.body, message.image, &markdown_copy_frame, &markdown_select_all_frame);
            zgui.dummy(.{ .w = 0.0, .h = 10.0 });
        }

        if (has_pending_stream) {
            renderPendingDiffCard(state);
            renderPendingTimelineEvents(state);
            renderPendingTranscriptBubble(state);
            renderPendingApproval(state);
            renderPendingFollowup(state);
            zgui.dummy(.{ .w = 0.0, .h = 6.0 });
        }
    }

    if (markdown_select_all_frame.requested) {
        if (markdown_select_all_frame.first) |first| {
            if (markdown_select_all_frame.last) |last| {
                state.selectAllTranscriptMarkdownSelection(first.message_index, first.point, last.message_index, last.point);
            }
        }
    }

    if (markdown_copy_frame.requested and markdown_copy_frame.copied_any) {
        const copied = std.heap.page_allocator.dupeZ(u8, markdown_copy_frame.builder.items) catch null;
        if (copied) |text| {
            defer std.heap.page_allocator.free(text);
            zgui.setClipboardText(text);
        }
    }

    zgui.endChild();
    zgui.popStyleVar(.{ .count = 1 });
    state.transcript_focused = zgui.isWindowFocused(.{ .child_windows = true });
    if (!zgui.isMouseDown(.left)) {
        state.endTranscriptMarkdownSelection();
    }
    zgui.dummy(.{ .w = 0.0, .h = 0.0 });

    if (applyPendingTranscriptScroll(state, height)) {
        return;
    }

    // Hold bottom-scroll requests for a couple of frames so startup and thread
    // switches still land correctly after nested child layout settles.
    if (state.scroll_transcript_to_bottom_frames > 0) {
        jumpTranscriptToTail();
        state.scroll_transcript_to_bottom_frames -= 1;
    } else if (should_follow_stream) {
        smoothScrollTranscriptToTail();
    }
}

fn applyPendingTranscriptScroll(state: *app_state.AppState, viewport_height: f32) bool {
    if (state.pending_transcript_line_scroll_steps == 0 and state.pending_transcript_page_scroll_steps == 0) {
        return false;
    }

    const line_step = theme.scaledUi(56.0);
    const page_step = @max(viewport_height - theme.scaledUi(48.0), theme.scaledUi(120.0));
    const delta_y =
        @as(f32, @floatFromInt(state.pending_transcript_line_scroll_steps)) * line_step +
        @as(f32, @floatFromInt(state.pending_transcript_page_scroll_steps)) * page_step;

    state.pending_transcript_line_scroll_steps = 0;
    state.pending_transcript_page_scroll_steps = 0;

    const scroll_max_y = zgui.getScrollMaxY();
    const next_scroll_y = std.math.clamp(zgui.getScrollY() + delta_y, 0.0, scroll_max_y);
    zgui.setScrollY(next_scroll_y);
    return true;
}

/// Renders the pending approval prompt from the provider.
fn renderPendingApproval(state: anytype) void {
    var snapshot = state.pendingApprovalSnapshot() catch null;
    defer freePendingApproval(state.allocator, &snapshot);

    if (snapshot) |approval| {
        renderTranscriptBubble(state, "pending-approval-body", .system, approval.title, approval.body, null, false);
        const button_width = theme.clampf(zgui.getContentRegionAvail()[0] * 0.28, theme.scaledUi(108.0), theme.scaledUi(180.0));
        zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(6.0) });
        if (zgui.button("Approve", .{ .w = button_width, .h = theme.scaledUi(34.0) })) {
            state.resolvePendingApproval(.approve);
        }
        zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.rgba(52, 54, 60, 255) });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.rgba(64, 66, 74, 255) });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.rgba(44, 46, 52, 255) });
        if (zgui.button("Deny", .{ .w = button_width, .h = theme.scaledUi(34.0) })) {
            state.resolvePendingApproval(.deny);
        }
        zgui.popStyleColor(.{ .count = 3 });
        zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(8.0) });
    }
}

fn renderPendingFollowup(state: *app_state.AppState) void {
    const snapshot = state.pendingFollowupSnapshot() catch null;
    defer if (snapshot) |pending| state.allocator.free(pending.prompt);

    const pending = snapshot orelse return;
    if (pending.kind == .steer and pending.state == .sent_inline) return;
    renderTranscriptBubble(
        state,
        "pending-followup-body",
        .system,
        switch (pending.kind) {
            .queue => "Queued next message",
            .steer => switch (pending.state) {
                .pending => "Steer pending",
                .sent_inline => "Steering current turn",
                .fallback_next_turn => "Steer unavailable, queued next turn",
            },
        },
        pending.prompt,
        null,
        false,
    );
    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(8.0) });
}

/// Renders streamed timeline events while a send is pending.
fn renderPendingTimelineEvents(state: *app_state.AppState) void {
    const send_state = state.currentThread().send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    if (send_state.status != .pending) return;

    for (send_state.pending_events.items, 0..) |event, index| {
        renderTranscriptMessage(state, @intCast(50_000 + index), null, event.role, event.author, event.body, null, null, null);
        zgui.dummy(.{ .w = 0.0, .h = 6.0 });
    }
}

/// Renders the live diff summary card for streamed file changes.
fn renderPendingDiffCard(state: *app_state.AppState) void {
    if (state.currentThread().provider == .opencode) return;

    const send_state = state.currentThread().send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    if (send_state.status != .pending) return;
    if (send_state.pending_diff_files.items.len == 0) return;

    renderPendingDiffCardLocked(&send_state.pending_diff_files);
    zgui.dummy(.{ .w = 0.0, .h = 6.0 });
}

/// Draws the pending diff card contents while the send lock is held.
fn renderPendingDiffCardLocked(files: anytype) void {
    const totals = summarizePendingDiffFiles(files.items);
    const card_height = pendingDiffCardHeight(files.items);

    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 12.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 14.0, 10.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(32, 33, 38, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    _ = zgui.beginChild("pending-diff-card", .{
        .w = 0.0,
        .h = card_height,
        .child_flags = .{ .border = true },
        .window_flags = .{ .no_saved_settings = true },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    renderChangedFilesHeader(files.items.len, totals.additions, totals.deletions);
    zgui.sameLine(.{ .spacing = 12.0 });
    if (renderChangedFilesAction("Expand all")) {
        for (files.items) |*file| file.expanded = true;
    }
    zgui.sameLine(.{ .spacing = 8.0 });
    if (renderChangedFilesAction("Collapse all")) {
        for (files.items) |*file| file.expanded = false;
    }
    zgui.dummy(.{ .w = 0.0, .h = 4.0 });

    for (files.items, 0..) |*file, index| {
        renderPendingDiffFile(file, index);
    }
}

/// Renders the streamed assistant bubble placeholder or partial text.
fn renderPendingTranscriptBubble(state: *app_state.AppState) void {
    const send_state = state.currentThread().send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();

    if (send_state.status != .pending) return;

    const stream_text = send_state.partial_text.items;
    var status_buf: [32]u8 = undefined;
    const working_label = formatPendingWorkingLabel(&status_buf, send_state.started_at_ms);
    renderTranscriptBubble(
        state,
        "pending-assistant",
        .assistant,
        working_label,
        if (stream_text.len > 0) stream_text else "Waiting for streamed output...",
        null,
        stream_text.len == 0,
    );
}

/// Dispatches a transcript item to the right visual treatment.
fn renderTranscriptMessage(
    state: *app_state.AppState,
    id: u32,
    message_index: ?usize,
    role: app_state.ChatRole,
    author: []const u8,
    body: []const u8,
    image: ?app_state.ChatImageAttachment,
    markdown_copy_frame: ?*TranscriptMarkdownCopyFrame,
    markdown_select_all_frame: ?*TranscriptMarkdownSelectAllFrame,
) void {
    if (role == .system and std.mem.eql(u8, author, "Changed files")) {
        if (state.currentThread().provider == .opencode) return;
        renderChangedFilesCardId(id, body);
        return;
    }
    if (role == .system and (std.mem.eql(u8, author, "Ran command") or std.mem.eql(u8, author, "Command failed"))) {
        renderCommandEventRowId(id, author, body);
        return;
    }

    const bubble_height = transcriptBubbleHeight(state, message_index, role, author, body, image);
    const bubble_theme = transcriptBubbleTheme(role);
    const bubble_width = transcriptBubbleWidth(role);
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = theme.TRANSCRIPT_BUBBLE_ROUNDING });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.TRANSCRIPT_BUBBLE_PADDING_X, theme.TRANSCRIPT_BUBBLE_PADDING_Y } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = bubble_theme.background });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = bubble_theme.border });
    if (shouldRightAlignBubble(role)) {
        zgui.setCursorPosX(zgui.getCursorPosX() + zgui.getContentRegionAvail()[0] - bubble_width);
    }
    _ = zgui.beginChildId(id, .{
        .w = bubbleWidthForChild(role, bubble_width),
        .h = bubble_height,
        .child_flags = .{ .border = true },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_saved_settings = true,
        },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    if (shouldShowBubbleAuthor(author)) {
        zgui.textColored(bubble_theme.author, "{s}", .{author});
        zgui.dummy(.{ .w = 0.0, .h = 2.0 });
    }
    if (image) |attachment| {
        renderImageAttachmentCard(state, attachment, false);
        if (body.len > 0) {
            zgui.dummy(.{ .w = 0.0, .h = 8.0 });
        }
    }
    const bubble_hovered = zgui.isWindowHovered(.{});
    renderTranscriptBody(state, message_index, role, body, false, bubble_hovered, markdown_copy_frame, markdown_select_all_frame);
}

/// Draws a generic transcript bubble with optional muted body text.
fn renderTranscriptBubble(state: anytype, id: [:0]const u8, role: anytype, author: []const u8, body: []const u8, image: anytype, muted_body: bool) void {
    const bubble_height = transcriptBubbleHeightGeneric(
        null,
        null,
        role,
        author,
        body,
        image,
        muted_body,
        shouldRenderCodexFileReferenceBody(state, role, body, muted_body),
    );
    const bubble_theme = transcriptBubbleTheme(role);
    const bubble_width = transcriptBubbleWidth(role);
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = theme.TRANSCRIPT_BUBBLE_ROUNDING });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.TRANSCRIPT_BUBBLE_PADDING_X, theme.TRANSCRIPT_BUBBLE_PADDING_Y } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = bubble_theme.background });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = bubble_theme.border });
    if (shouldRightAlignBubble(role)) {
        zgui.setCursorPosX(zgui.getCursorPosX() + zgui.getContentRegionAvail()[0] - bubble_width);
    }
    _ = zgui.beginChild(id, .{
        .w = bubbleWidthForChild(role, bubble_width),
        .h = bubble_height,
        .child_flags = .{ .border = true },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_saved_settings = true,
        },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    if (shouldShowBubbleAuthor(author)) {
        zgui.textColored(bubble_theme.author, "{s}", .{author});
        zgui.dummy(.{ .w = 0.0, .h = 2.0 });
    }
    if (image) |attachment| {
        renderImageAttachmentCard(state, attachment, false);
        if (body.len > 0) {
            zgui.dummy(.{ .w = 0.0, .h = 8.0 });
        }
    }
    renderTranscriptBody(state, null, role, body, muted_body, false, null, null);
}

fn renderTranscriptBody(state: *app_state.AppState, message_index: ?usize, role: anytype, body: []const u8, muted_body: bool, bubble_hovered: bool, markdown_copy_frame: ?*TranscriptMarkdownCopyFrame, markdown_select_all_frame: ?*TranscriptMarkdownSelectAllFrame) void {
    _ = bubble_hovered;
    if (shouldRenderCodexFileReferenceBody(state, role, body, muted_body)) {
        renderCodexFileReferenceBody(state, body);
        return;
    }

    if (message_index) |index| {
        if (!muted_body and renderSelectableMarkdownTranscriptBody(state, index, body, markdown_copy_frame, markdown_select_all_frame)) {
            return;
        }
        if (shouldRenderSelectablePlainTranscriptBody(body, muted_body)) {
            if (renderSelectablePlainTranscriptBody(state, index, body, muted_body)) {
                return;
            }
        }
    }

    if (!muted_body and renderMarkdownTranscriptBody(state, message_index, body)) {
        return;
    }

    zgui.pushTextWrapPos(0.0);
    defer zgui.popTextWrapPos();
    if (muted_body) {
        zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{body});
    } else {
        zgui.textWrapped("{s}", .{body});
    }
}

fn shouldRenderSelectablePlainTranscriptBody(body: []const u8, muted_body: bool) bool {
    _ = body;
    _ = muted_body;
    // Disabled until transcript selection uses our own layout model instead of
    // the vendor word-wrap path, which is unstable on the current ImGui build.
    return false;
}

fn renderSelectablePlainTranscriptBody(state: *app_state.AppState, message_index: usize, body: []const u8, muted_body: bool) bool {
    const selector = state.transcriptBodyTextSelector(message_index, body) orelse return false;
    const line_count = state.transcriptBodyTextLineCount(message_index, body);
    if (line_count == 0) return false;

    const style = zgui.getStyle();
    zgui.pushIntId(@intCast(message_index + 1));
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ style.item_spacing[0], 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(0, 0, 0, 0) });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 2 });
        zgui.popId();
    }

    _ = zgui.beginChild("##selectable-transcript-body", .{
        .w = 0.0,
        .h = 0.0,
        .child_flags = .{
            .auto_resize_y = true,
        },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_saved_settings = true,
            .no_move = true,
        },
    });
    defer zgui.endChild();

    zgui.pushTextWrapPos(0.0);
    defer zgui.popTextWrapPos();

    for (0..line_count) |line_index| {
        const line = state.transcriptBodyTextLineAt(message_index, body, line_index);
        if (line.len == 0) {
            zgui.dummy(.{ .w = 0.0, .h = zgui.getTextLineHeight() });
            continue;
        }
        if (muted_body) {
            zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{line});
        } else {
            zgui.textWrapped("{s}", .{line});
        }
    }

    selector.update();
    return true;
}

fn transcriptMarkdownSelectionPointLessThan(lhs: app_state.TranscriptMarkdownSelectionPoint, rhs: app_state.TranscriptMarkdownSelectionPoint) bool {
    if (lhs.message_index != rhs.message_index) return lhs.message_index < rhs.message_index;
    return lhs.point.line_index < rhs.point.line_index or
        (lhs.point.line_index == rhs.point.line_index and lhs.point.column < rhs.point.column);
}

fn orderedTranscriptMarkdownSelection(selection: app_state.TranscriptMarkdownSelection) OrderedTranscriptMarkdownSelection {
    if (transcriptMarkdownSelectionPointLessThan(selection.focus, selection.anchor)) {
        return .{
            .start = selection.focus,
            .end = selection.anchor,
        };
    }
    return .{
        .start = selection.anchor,
        .end = selection.focus,
    };
}

fn localTranscriptMarkdownSelectionForMessage(
    selection: ?app_state.TranscriptMarkdownSelection,
    message_index: usize,
) ?chat_markdown.SelectionRange {
    const active = selection orelse return null;
    const ordered = orderedTranscriptMarkdownSelection(active);
    if (message_index < ordered.start.message_index or message_index > ordered.end.message_index) return null;

    const whole_message_start: chat_markdown.SelectionPoint = .{ .line_index = 0, .column = 0 };
    const whole_message_end: chat_markdown.SelectionPoint = .{ .line_index = std.math.maxInt(usize), .column = std.math.maxInt(usize) };

    return .{
        .anchor = if (message_index == ordered.start.message_index) ordered.start.point else whole_message_start,
        .focus = if (message_index == ordered.end.message_index) ordered.end.point else whole_message_end,
    };
}

fn transcriptMarkdownRenderOptions() chat_markdown.RenderOptions {
    return .{
        .heading_font = theme.heading_font,
        .heading_font_size = if (theme.heading_font != null) theme.heading_font_size else null,
        .bold_font = theme.bold_font,
        .italic_font = theme.italic_font,
        .bold_italic_font = theme.bold_italic_font,
        .code_font = theme.terminal_font,
        .code_font_size = if (theme.terminal_font != null) theme.terminal_font_size else null,
    };
}

fn transcriptMarkdownBodyView(state: *app_state.AppState, message_index: ?usize, body: []const u8, fallback_view: *?chat_markdown.BodyView) ?chat_markdown.BodyView {
    if (message_index) |index| {
        if (state.transcriptMarkdownBodyView(index, body)) |cached| {
            return cached.*;
        }
    }

    fallback_view.* = chat_markdown.buildBodyView(std.heap.page_allocator, body) catch return null;
    return fallback_view.*;
}

fn renderSelectableMarkdownTranscriptBody(
    state: *app_state.AppState,
    message_index: usize,
    body: []const u8,
    markdown_copy_frame: ?*TranscriptMarkdownCopyFrame,
    markdown_select_all_frame: ?*TranscriptMarkdownSelectAllFrame,
) bool {
    var fallback_view: ?chat_markdown.BodyView = null;
    defer if (fallback_view) |*view| view.deinit(std.heap.page_allocator);
    const view = transcriptMarkdownBodyView(state, message_index, body, &fallback_view) orelse return false;

    const style = zgui.getStyle();
    const options = transcriptMarkdownRenderOptions();
    const selection = localTranscriptMarkdownSelectionForMessage(state.transcriptMarkdownSelection(), message_index);
    const selection_active = selection != null;
    const copy_selection = if (markdown_copy_frame) |frame| selection_active and frame.requested else false;

    zgui.pushIntId(@intCast(message_index + 1));
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ style.item_spacing[0], 0.0 } });
    defer {
        zgui.popStyleVar(.{ .count = 2 });
        zgui.popId();
    }

    const body_width = @max(zgui.getContentRegionAvail()[0], 1.0);
    const body_start = zgui.getCursorScreenPos();
    var result = chat_markdown.renderSelectableBody(
        std.heap.page_allocator,
        view,
        options,
        selection,
        copy_selection,
    );
    defer result.deinit(std.heap.page_allocator);

    const body_end = zgui.getCursorScreenPos();
    const body_height = @max(body_end[1] - body_start[1], zgui.getTextLineHeight());
    zgui.setCursorScreenPos(body_start);
    _ = zgui.invisibleButton("##selectable-markdown-hitbox", .{ .w = body_width, .h = body_height });
    const body_hovered = zgui.isItemHovered(.{});
    const body_active = zgui.isItemActive();
    const body_activated = zgui.isItemActivated();
    const click_count: usize = if (body_activated) @intCast(@max(zgui.getMouseClickedCount(.left), 0)) else 0;
    zgui.setCursorScreenPos(body_end);

    if (body_hovered or body_active) {
        zgui.setMouseCursor(.text_input);
    }
    if (body_activated) {
        if (result.hovered_point) |point| {
            if (chat_markdown.selectionRangeForClickCount(std.heap.page_allocator, view, body_width, options, point, click_count)) |expanded| {
                state.selectAllTranscriptMarkdownSelection(message_index, expanded.anchor, message_index, expanded.focus);
            } else {
                state.beginTranscriptMarkdownSelection(message_index, point);
            }
        } else if (body_hovered) {
            state.clearTranscriptMarkdownSelection();
        }
    } else if (state.transcriptMarkdownSelectionDragging() and zgui.isMouseDown(.left)) {
        if (body_hovered or body_active) {
            if (result.hovered_point) |point| {
                state.updateTranscriptMarkdownSelection(message_index, point);
            }
        }
    }

    if (markdown_select_all_frame) |frame| {
        if (frame.requested) {
            if (result.first_point) |first| {
                if (result.last_point) |last| {
                    frame.noteMessage(message_index, first, last);
                }
            }
        }
    }
    if (copy_selection) {
        if (markdown_copy_frame) |frame| {
            if (result.copied_text) |copied| {
                frame.append(std.heap.page_allocator, copied);
            }
        }
    }

    return true;
}

fn renderMarkdownTranscriptBody(state: *app_state.AppState, message_index: ?usize, body: []const u8) bool {
    var fallback_view: ?chat_markdown.BodyView = null;
    defer if (fallback_view) |*view| view.deinit(std.heap.page_allocator);
    const view = transcriptMarkdownBodyView(state, message_index, body, &fallback_view) orelse return false;

    chat_markdown.renderBody(view, transcriptMarkdownRenderOptions());
    return true;
}

fn shouldRenderCodexFileReferenceBody(state: *app_state.AppState, role: anytype, body: []const u8, muted_body: bool) bool {
    return !muted_body and
        role == .assistant and
        state.currentThread().provider == .codex and
        std.mem.indexOf(u8, body, "](/") != null and
        !bodyLikelyUsesMarkdownBlocks(body);
}

fn bodyLikelyUsesMarkdownBlocks(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "```") != null) return true;
    if (std.mem.indexOf(u8, body, "\n~~~") != null) return true;
    if (std.mem.indexOf(u8, body, "\n- ") != null) return true;
    if (std.mem.indexOf(u8, body, "\n* ") != null) return true;
    if (std.mem.indexOf(u8, body, "\n> ") != null) return true;
    if (std.mem.indexOf(u8, body, "\n#") != null) return true;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (std.ascii.isDigit(trimmed[0])) {
            var index: usize = 1;
            while (index < trimmed.len and std.ascii.isDigit(trimmed[index])) : (index += 1) {}
            if (index < trimmed.len - 1 and trimmed[index] == '.' and trimmed[index + 1] == ' ') return true;
        }
    }
    return false;
}

const CodexFileReference = struct {
    start: usize,
    end: usize,
    label: []const u8,
    path: []const u8,
};

const CodexInlineLayout = struct {
    base_screen: [2]f32,
    cursor_x: f32,
    cursor_y: f32,
    max_x: f32,
    line_height: f32,
    available_width: f32,
    file_ref_count: usize = 0,
};

fn renderCodexFileReferenceBody(state: *app_state.AppState, body: []const u8) void {
    const base_screen = zgui.getCursorScreenPos();
    const available_width = zgui.getContentRegionAvail()[0];
    const line_height = @max(zgui.getTextLineHeightWithSpacing(), theme.scaledUi(28.0));
    var layout: CodexInlineLayout = .{
        .base_screen = base_screen,
        .cursor_x = base_screen[0],
        .cursor_y = base_screen[1],
        .max_x = base_screen[0] + available_width,
        .line_height = line_height,
        .available_width = available_width,
    };

    var lines = std.mem.splitScalar(u8, body, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) advanceCodexInlineLine(&layout) else first_line = false;
        if (line.len == 0) continue;
        renderCodexFileReferenceLine(state, line, &layout);
    }

    const used_height = @max(layout.cursor_y - layout.base_screen[1] + layout.line_height, zgui.getTextLineHeight());
    zgui.setCursorScreenPos(base_screen);
    zgui.dummy(.{ .w = available_width, .h = used_height });
}

const CodexInlineMeasure = struct {
    cursor_x: f32 = 0.0,
    cursor_y: f32 = 0.0,
    max_x: f32,
    line_height: f32,
};

fn codexFileReferenceBodyHeight(body: []const u8, available_width: f32) f32 {
    const line_height = @max(zgui.getTextLineHeightWithSpacing(), theme.scaledUi(28.0));
    var layout: CodexInlineMeasure = .{
        .max_x = available_width,
        .line_height = line_height,
    };

    var lines = std.mem.splitScalar(u8, body, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) {
            advanceCodexInlineMeasureLine(&layout);
        } else {
            first_line = false;
        }
        if (line.len == 0) continue;
        measureCodexFileReferenceLine(line, &layout);
    }

    return @max(layout.cursor_y + layout.line_height, zgui.getTextLineHeight());
}

fn advanceCodexInlineMeasureLine(layout: *CodexInlineMeasure) void {
    layout.cursor_x = 0.0;
    layout.cursor_y += layout.line_height;
}

fn measureCodexFileReferenceLine(line: []const u8, layout: *CodexInlineMeasure) void {
    var cursor: usize = 0;
    while (cursor < line.len) {
        if (findNextCodexFileReference(line, cursor)) |file_ref| {
            measureCodexTextRun(line[cursor..file_ref.start], layout);
            measureCodexFileReferenceToken(file_ref, layout);
            cursor = file_ref.end;
            continue;
        }

        measureCodexTextRun(line[cursor..], layout);
        break;
    }
}

fn measureCodexTextRun(text: []const u8, layout: *CodexInlineMeasure) void {
    var cursor: usize = 0;
    while (cursor < text.len) {
        const is_space = std.ascii.isWhitespace(text[cursor]);
        var end = cursor + 1;
        while (end < text.len and std.ascii.isWhitespace(text[end]) == is_space) : (end += 1) {}
        measureCodexTextToken(text[cursor..end], is_space, layout);
        cursor = end;
    }
}

fn measureCodexTextToken(token: []const u8, is_space: bool, layout: *CodexInlineMeasure) void {
    if (is_space) {
        if (layout.cursor_x <= 0.0) return;
        const width = zgui.calcTextSize(token, .{})[0];
        if (layout.cursor_x + width > layout.max_x) {
            advanceCodexInlineMeasureLine(layout);
            return;
        }
        layout.cursor_x += width;
        return;
    }

    const width = zgui.calcTextSize(token, .{})[0];
    if (layout.cursor_x > 0.0 and layout.cursor_x + width > layout.max_x) {
        advanceCodexInlineMeasureLine(layout);
    }
    layout.cursor_x += width;
}

fn measureCodexFileReferenceToken(file_ref: CodexFileReference, layout: *CodexInlineMeasure) void {
    const text_size = zgui.calcTextSize(file_ref.label, .{});
    const padding_x = theme.scaledUi(8.0);
    const chip_width = text_size[0] + padding_x * 2.0;

    if (layout.cursor_x > 0.0 and layout.cursor_x + chip_width > layout.max_x) {
        advanceCodexInlineMeasureLine(layout);
    }
    layout.cursor_x += chip_width;
}

fn renderCodexFileReferenceLine(state: *app_state.AppState, line: []const u8, layout: *CodexInlineLayout) void {
    var cursor: usize = 0;
    while (cursor < line.len) {
        if (findNextCodexFileReference(line, cursor)) |file_ref| {
            renderCodexTextRun(line[cursor..file_ref.start], layout);
            renderCodexFileReferenceToken(state, file_ref, layout);
            cursor = file_ref.end;
            continue;
        }

        renderCodexTextRun(line[cursor..], layout);
        break;
    }
}

fn renderCodexTextRun(text: []const u8, layout: *CodexInlineLayout) void {
    var cursor: usize = 0;
    while (cursor < text.len) {
        const is_space = std.ascii.isWhitespace(text[cursor]);
        var end = cursor + 1;
        while (end < text.len and std.ascii.isWhitespace(text[end]) == is_space) : (end += 1) {}
        renderCodexTextToken(text[cursor..end], is_space, layout);
        cursor = end;
    }
}

fn renderCodexTextToken(token: []const u8, is_space: bool, layout: *CodexInlineLayout) void {
    const start_x = layout.base_screen[0];
    if (is_space) {
        if (layout.cursor_x <= start_x) return;
        const width = zgui.calcTextSize(token, .{})[0];
        if (layout.cursor_x + width > layout.max_x) {
            advanceCodexInlineLine(layout);
            return;
        }
        layout.cursor_x += width;
        return;
    }

    const width = zgui.calcTextSize(token, .{})[0];
    if (layout.cursor_x > start_x and layout.cursor_x + width > layout.max_x) {
        advanceCodexInlineLine(layout);
    }

    zgui.getWindowDrawList().addTextUnformatted(
        .{ layout.cursor_x, layout.cursor_y + (layout.line_height - zgui.getTextLineHeight()) * 0.5 },
        zgui.colorConvertFloat4ToU32(theme.COLOR_TEXT_MUTED),
        token,
    );
    layout.cursor_x += width;
}

fn renderCodexFileReferenceToken(state: *app_state.AppState, file_ref: CodexFileReference, layout: *CodexInlineLayout) void {
    const text_size = zgui.calcTextSize(file_ref.label, .{});
    const padding_x = theme.scaledUi(8.0);
    const chip_width = text_size[0] + padding_x * 2.0;
    const chip_height = theme.scaledUi(24.0);
    const start_x = layout.base_screen[0];

    if (layout.cursor_x > start_x and layout.cursor_x + chip_width > layout.max_x) {
        advanceCodexInlineLine(layout);
    }

    const chip_pos = .{
        layout.cursor_x,
        layout.cursor_y + (layout.line_height - chip_height) * 0.5,
    };
    var id_buf: [48:0]u8 = undefined;
    const button_id = std.fmt.bufPrintZ(&id_buf, "##codex-file-ref-{d}", .{layout.file_ref_count}) catch return;
    layout.file_ref_count += 1;

    zgui.setCursorScreenPos(chip_pos);
    const clicked = zgui.invisibleButton(button_id, .{ .w = chip_width, .h = chip_height });
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();
    const bg = if (hovered)
        theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.08)
    else
        theme.COLOR_SECONDARY_GREEN;
    draw_list.addRectFilled(.{
        .pmin = chip_pos,
        .pmax = .{ chip_pos[0] + chip_width, chip_pos[1] + chip_height },
        .col = zgui.colorConvertFloat4ToU32(bg),
        .rounding = theme.scaledUi(7.0),
    });
    draw_list.addTextUnformatted(
        .{
            chip_pos[0] + padding_x,
            chip_pos[1] + (chip_height - text_size[1]) * 0.5,
        },
        zgui.colorConvertFloat4ToU32(theme.COLOR_DIFF_ADD),
        file_ref.label,
    );

    if (hovered) {
        _ = zgui.beginTooltip();
        zgui.textUnformatted(file_ref.path);
        zgui.endTooltip();
    }
    if (clicked) {
        state.openTranscriptFileReference(file_ref.path);
    }

    layout.cursor_x += chip_width;
}

fn advanceCodexInlineLine(layout: *CodexInlineLayout) void {
    layout.cursor_x = layout.base_screen[0];
    layout.cursor_y += layout.line_height;
}

fn findNextCodexFileReference(text: []const u8, start_index: usize) ?CodexFileReference {
    var index = start_index;
    while (index < text.len) : (index += 1) {
        if (text[index] != '[') continue;
        const close_bracket_rel = std.mem.indexOfScalarPos(u8, text, index + 1, ']') orelse continue;
        if (close_bracket_rel + 1 >= text.len or text[close_bracket_rel + 1] != '(') continue;
        const close_paren = std.mem.indexOfScalarPos(u8, text, close_bracket_rel + 2, ')') orelse continue;
        const target = text[close_bracket_rel + 2 .. close_paren];
        if (target.len == 0 or target[0] != '/') continue;
        const path = codexFileReferencePath(target);
        if (path.len == 0) continue;

        return .{
            .start = index,
            .end = close_paren + 1,
            .label = text[index + 1 .. close_bracket_rel],
            .path = path,
        };
    }
    return null;
}

fn codexFileReferencePath(target: []const u8) []const u8 {
    const hash_index = std.mem.indexOfScalar(u8, target, '#') orelse return target;
    return target[0..hash_index];
}

/// Draws a compact system row for command execution events.
fn renderCommandEventRowId(id: u32, author: []const u8, body: []const u8) void {
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 10.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 14.0, 9.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(28, 29, 34, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    _ = zgui.beginChildId(id, .{
        .w = 0.0,
        .h = 0.0,
        .child_flags = .{
            .border = true,
            .auto_resize_y = true,
        },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_saved_settings = true,
        },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    zgui.textColored(theme.COLOR_TEXT_MUTED, ">_", .{});
    zgui.sameLine(.{ .spacing = 12.0 });
    zgui.textColored(if (std.mem.eql(u8, author, "Command failed")) theme.COLOR_DIFF_REMOVE else theme.COLOR_TEXT_MUTED, "{s}", .{author});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "-", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.pushTextWrapPos(0.0);
    zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{body});
    zgui.popTextWrapPos();
}

/// Renders a persisted changed-files message as a rich card.
fn renderChangedFilesCardId(id: u32, body: []const u8) void {
    var entries = parseChangedFileEntries(body);
    const totals = summarizeChangedFiles(entries);
    const has_patch_details = changedFilesEntriesHavePatch(entries.items);
    var open_all = false;
    var close_all = false;

    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 12.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 14.0, 10.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(32, 33, 38, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    _ = zgui.beginChildId(id, .{
        .w = 0.0,
        .h = 0.0,
        .child_flags = .{
            .border = true,
            .auto_resize_y = true,
        },
        .window_flags = .{ .no_saved_settings = true },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
        entries.deinit(std.heap.page_allocator);
    }

    renderChangedFilesHeader(entries.items.len, totals.additions, totals.deletions);
    if (has_patch_details) {
        zgui.sameLine(.{ .spacing = 12.0 });
        if (renderChangedFilesAction("Collapse all")) {
            close_all = true;
        }
        zgui.sameLine(.{ .spacing = 8.0 });
        if (renderChangedFilesAction("View diff")) {
            open_all = true;
        }
    } else {
        zgui.sameLine(.{ .spacing = 12.0 });
        zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Summary only", .{});
    }
    zgui.dummy(.{ .w = 0.0, .h = 4.0 });

    if (has_patch_details) {
        for (entries.items, 0..) |entry, index| {
            renderChangedFilesDetailedEntry(entry, id, index, open_all, close_all);
        }
        return;
    }

    var last_parent: ?[]const u8 = null;
    for (entries.items) |entry| {
        const parent = std.fs.path.dirname(entry.path) orelse ".";
        if (last_parent == null or !std.mem.eql(u8, last_parent.?, parent)) {
            renderChangedFilesFolder(parent);
            last_parent = parent;
        }
        renderChangedFilesEntry(entry);
    }
}

/// Draws the header for changed-file summaries.
fn renderChangedFilesHeader(file_count: usize, additions: i64, deletions: i64) void {
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "CHANGED FILES ({d})", .{file_count});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "•", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_DIFF_ADD, "+{d}", .{additions});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "/", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_DIFF_REMOVE, "-{d}", .{deletions});
}

/// Draws a small action button used inside diff cards.
fn renderChangedFilesAction(label: [:0]const u8) bool {
    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = 8.0 });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 10.0, 4.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.rgba(52, 54, 60, 255) });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.rgba(62, 64, 72, 255) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.rgba(68, 70, 78, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 3 });
        zgui.popStyleVar(.{ .count = 2 });
    }
    return zgui.button(label, .{ .h = 26.0 });
}

/// Draws a folder label row inside a changed-files card.
fn renderChangedFilesFolder(path: []const u8) void {
    zgui.textColored(theme.COLOR_TEXT_MUTED, "v  {s}", .{path});
    zgui.dummy(.{ .w = 0.0, .h = 2.0 });
}

/// Draws a single changed file row without patch details.
fn renderChangedFilesEntry(entry: anytype) void {
    const file_name = std.fs.path.basename(entry.path);
    zgui.textColored(theme.COLOR_TEXT_MUTED, "    {s}", .{file_name});
    zgui.sameLine(.{ .spacing = 16.0 });
    zgui.textColored(theme.COLOR_DIFF_ADD, "+{d}", .{entry.additions});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "/", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_DIFF_REMOVE, "-{d}", .{entry.deletions});
    zgui.dummy(.{ .w = 0.0, .h = 2.0 });
}

/// Draws one expandable changed-file row with its patch.
fn renderChangedFilesDetailedEntry(entry: anytype, message_id: u32, index: usize, open_all: bool, close_all: bool) void {
    var header_storage: [512]u8 = undefined;
    const header_label = std.fmt.bufPrintZ(&header_storage, "{s}  +{d} / -{d}##changed-files-{d}-{d}", .{
        entry.path,
        entry.additions,
        entry.deletions,
        message_id,
        index,
    }) catch return;

    if (open_all) {
        zgui.setNextItemOpen(.{ .is_open = true, .cond = .always });
    } else if (close_all) {
        zgui.setNextItemOpen(.{ .is_open = false, .cond = .always });
    }

    if (zgui.collapsingHeader(header_label, .{})) {
        if (entry.patch) |patch| {
            renderPendingDiffPatch(patch, @as(usize, message_id) * 1000 + index);
        } else {
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, "No patch body available.", .{});
        }
        zgui.dummy(.{ .w = 0.0, .h = 6.0 });
    }
}

/// Draws one pending diff file row in the live stream card.
fn renderPendingDiffFile(file: anytype, index: usize) void {
    const toggle_label = if (file.expanded) "v" else ">";
    const file_name = std.fs.path.basename(file.path);
    var toggle_storage: [48]u8 = undefined;
    const toggle_button_label = std.fmt.bufPrintZ(&toggle_storage, "{s}##pending-diff-toggle-{d}", .{ toggle_label, index }) catch return;

    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = 8.0 });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 8.0, 6.0 } });
    defer zgui.popStyleVar(.{ .count = 2 });

    if (zgui.button(toggle_button_label, .{ .w = 28.0, .h = 28.0 })) {
        file.expanded = !file.expanded;
    }
    zgui.sameLine(.{ .spacing = 10.0 });
    zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{file_name});
    zgui.sameLine(.{ .spacing = 10.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{s}", .{file.path});
    zgui.sameLine(.{ .spacing = 12.0 });
    zgui.textColored(theme.COLOR_DIFF_ADD, "+{d}", .{file.additions});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "/", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_DIFF_REMOVE, "-{d}", .{file.deletions});

    if (file.expanded) {
        if (file.patch) |patch| {
            renderPendingDiffPatch(patch, index);
        } else {
            zgui.dummy(.{ .w = 0.0, .h = 6.0 });
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, "No patch body available yet.", .{});
        }
    }

    zgui.dummy(.{ .w = 0.0, .h = 8.0 });
}

/// Draws a syntax-colored patch block.
fn renderPendingDiffPatch(patch: []const u8, index: usize) void {
    const patch_height = pendingDiffPatchHeight(patch);

    zgui.dummy(.{ .w = 0.0, .h = 6.0 });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 8.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 8.0, 8.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(24, 24, 24, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    _ = zgui.beginChildId(@intCast(80_000 + index), .{
        .w = 0.0,
        .h = patch_height,
        .child_flags = .{ .border = true },
        .window_flags = .{ .no_saved_settings = true, .horizontal_scrollbar = true },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    var view = zig_dif.buildSideBySidePatchViewWithOptions(std.heap.page_allocator, patch, .{
        .context_lines = 2,
    }) catch {
        renderPendingDiffPatchFallback(patch);
        return;
    };
    defer view.deinit();

    if (renderPatchView(view)) return;
    renderPendingDiffPatchFallback(patch);
}

fn renderPatchView(view: zig_dif.SideBySidePatchView) bool {
    if (view.rows.len == 0) return false;

    const terminal_font = theme.terminal_font orelse zgui.getFont();
    const terminal_font_size = if (theme.terminal_font != null) theme.terminal_font_size else zgui.getFontSize();
    zgui.pushFont(terminal_font, terminal_font_size);
    defer zgui.popFont();

    const layout = patchViewLayout(view);
    for (view.rows, 0..) |row, row_index| {
        switch (row.kind) {
            .code => renderPatchCodeRow(view, row, row_index, layout),
            else => renderPatchMetaRow(row, row_index, layout.total),
        }
    }

    return true;
}

// Renders one full-width metadata row inside the split diff card.
fn renderPatchMetaRow(row: zig_dif.SideBySideRow, row_index: usize, content_width: f32) void {
    const row_height = switch (row.kind) {
        .file_header => theme.scaledUi(28.0),
        .hunk_header => theme.scaledUi(24.0),
        .context_gap => theme.scaledUi(24.0),
        .note => theme.scaledUi(20.0),
        .prelude => theme.scaledUi(20.0),
        .code => unreachable,
    };
    const origin = zgui.getCursorScreenPos();
    const width = @max(@max(zgui.getContentRegionAvail()[0], content_width), 1.0);
    var id_buf: [64]u8 = undefined;
    const button_id = std.fmt.bufPrintZ(&id_buf, "##patch-meta-{d}", .{row_index}) catch return;
    _ = zgui.invisibleButton(button_id, .{ .w = width, .h = row_height });

    const draw_list = zgui.getWindowDrawList();
    const row_max = .{ origin[0] + width, origin[1] + row_height };
    draw_list.addRectFilled(.{
        .pmin = origin,
        .pmax = row_max,
        .col = zgui.colorConvertFloat4ToU32(patchMetaBackground(row.kind)),
        .rounding = if (row.kind == .file_header) theme.scaledUi(6.0) else 0.0,
    });

    draw_list.pushClipRect(.{
        .pmin = origin,
        .pmax = row_max,
        .intersect_with_current = true,
    });
    defer draw_list.popClipRect();

    var label_buf: [192]u8 = undefined;
    const label = patchMetaRowLabel(row, &label_buf);
    const label_color = patchMetaLabelColor(row.kind);

    if (row.kind == .hunk_header or row.kind == .context_gap) {
        const label_size = zgui.calcTextSize(label, .{});
        const pill_pad_x = theme.scaledUi(12.0);
        const pill_pad_y = theme.scaledUi(4.0);
        const pill_width = label_size[0] + pill_pad_x * 2.0;
        const pill_height = zgui.getTextLineHeight() + pill_pad_y * 2.0;
        const pill_min = .{
            origin[0] + @max((width - pill_width) * 0.5, theme.scaledUi(8.0)),
            origin[1] + @max((row_height - pill_height) * 0.5, 0.0),
        };
        const pill_max = .{ pill_min[0] + pill_width, pill_min[1] + pill_height };
        draw_list.addRectFilled(.{
            .pmin = pill_min,
            .pmax = pill_max,
            .col = zgui.colorConvertFloat4ToU32(patchMetaPillBackground(row.kind)),
            .rounding = theme.scaledUi(6.0),
        });
        draw_list.addRect(.{
            .pmin = pill_min,
            .pmax = pill_max,
            .col = zgui.colorConvertFloat4ToU32(patchMetaPillBorder(row.kind)),
            .rounding = theme.scaledUi(6.0),
            .thickness = 1.0,
        });
        draw_list.addTextUnformatted(
            .{ pill_min[0] + pill_pad_x, pill_min[1] + (pill_height - zgui.getTextLineHeight()) * 0.5 },
            zgui.colorConvertFloat4ToU32(label_color),
            label,
        );
        return;
    }

    drawPatchTokenRun(.{
        .kind = patchDisplayLineKindForRow(row.kind),
        .text = "",
        .tokens = row.tokens,
    }, draw_list, origin[0] + theme.scaledUi(10.0), origin[1] + (row_height - zgui.getTextLineHeight()) * 0.5, row_max[0] - theme.scaledUi(10.0));
}

// Renders one side-by-side code row with independent left and right cells.
fn renderPatchCodeRow(view: zig_dif.SideBySidePatchView, row: zig_dif.SideBySideRow, row_index: usize, layout: PatchColumnLayout) void {
    const row_height = theme.scaledUi(26.0);
    const origin = zgui.getCursorScreenPos();
    const width = @max(@max(zgui.getContentRegionAvail()[0], layout.total), 1.0);
    const gap = theme.scaledUi(8.0);
    const left_width = layout.left;
    const right_width = layout.right;
    var id_buf: [64]u8 = undefined;
    const button_id = std.fmt.bufPrintZ(&id_buf, "##patch-code-{d}", .{row_index}) catch return;
    _ = zgui.invisibleButton(button_id, .{ .w = width, .h = row_height });

    const draw_list = zgui.getWindowDrawList();
    const left_min = origin;
    const left_max = .{ origin[0] + left_width, origin[1] + row_height };
    const right_min = .{ left_max[0] + gap, origin[1] };
    const right_max = .{ right_min[0] + right_width, origin[1] + row_height };

    drawPatchCell(draw_list, row.left, left_min, left_max, maxLineNumberDigits(view.max_old_line));
    drawPatchCell(draw_list, row.right, right_min, right_max, maxLineNumberDigits(view.max_new_line));

    draw_list.addLine(.{
        .p1 = .{ left_max[0] + gap * 0.5, origin[1] },
        .p2 = .{ left_max[0] + gap * 0.5, origin[1] + row_height },
        .col = zgui.colorConvertFloat4ToU32(theme.COLOR_PANEL_MUTED),
        .thickness = 1.0,
    });
}

// Draws one side of the split diff row.
fn drawPatchCell(
    draw_list: anytype,
    cell: ?zig_dif.SideBySideCell,
    min: [2]f32,
    max: [2]f32,
    digits: usize,
) void {
    const pad_x = theme.scaledUi(8.0);
    const gutter_pad_x = theme.scaledUi(10.0);
    const text_pad_x = theme.scaledUi(8.0);
    const line_height = max[1] - min[1];
    const number_width = patchNumberColumnWidth(digits);
    const text_y = min[1] + (line_height - zgui.getTextLineHeight()) * 0.5;
    const bg = patchCellBackground(if (cell) |value| value.kind else null);
    draw_list.addRectFilled(.{
        .pmin = min,
        .pmax = max,
        .col = zgui.colorConvertFloat4ToU32(bg),
    });

    if (cell) |value| {
        const gutter_width = pad_x + number_width + gutter_pad_x;
        if (value.kind == .addition or value.kind == .deletion) {
            draw_list.addRectFilled(.{
                .pmin = .{ min[0], min[1] },
                .pmax = .{ min[0] + theme.scaledUi(3.0), max[1] },
                .col = zgui.colorConvertFloat4ToU32(if (value.kind == .addition) theme.COLOR_DIFF_ADD else theme.COLOR_DIFF_REMOVE),
            });
        }

        draw_list.pushClipRect(.{
            .pmin = min,
            .pmax = max,
            .intersect_with_current = true,
        });
        defer draw_list.popClipRect();

        draw_list.addRectFilled(.{
            .pmin = min,
            .pmax = .{ min[0] + gutter_width, max[1] },
            .col = zgui.colorConvertFloat4ToU32(colors.rgba(20, 21, 25, 255)),
        });
        draw_list.addLine(.{
            .p1 = .{ min[0] + gutter_width, min[1] },
            .p2 = .{ min[0] + gutter_width, max[1] },
            .col = zgui.colorConvertFloat4ToU32(colors.rgba(58, 60, 68, 255)),
            .thickness = 1.0,
        });

        var number_buf: [32]u8 = undefined;
        const number_text = if (value.line_number) |line_number|
            std.fmt.bufPrint(&number_buf, "{d: >[1]}", .{ line_number, digits }) catch ""
        else
            std.fmt.bufPrint(&number_buf, "{s: >[1]}", .{ "", digits }) catch "";
        draw_list.addTextUnformatted(
            .{ min[0] + pad_x, text_y },
            zgui.colorConvertFloat4ToU32(theme.COLOR_TEXT_SUBTLE),
            number_text,
        );

        drawPatchTokenRun(value, draw_list, min[0] + gutter_width + text_pad_x, text_y, max[0] - pad_x);
    }
}

// Draws one run of syntax tokens directly into the current draw list.
fn drawPatchTokenRun(
    cell: zig_dif.SideBySideCell,
    draw_list: anytype,
    start_x: f32,
    start_y: f32,
    max_x: f32,
) void {
    var cursor_x = start_x;
    var text_offset: usize = 0;
    for (cell.tokens) |token| {
        if (token.text.len == 0) continue;
        const emphasized = patchTokenIsEmphasized(cell, text_offset, token.text.len);
        const width = zgui.calcTextSize(token.text, .{})[0];
        if (cursor_x >= max_x) break;
        drawPatchInlineHighlights(draw_list, cell, token, text_offset, cursor_x, start_y);
        draw_list.addTextUnformatted(
            .{ cursor_x, start_y },
            zgui.colorConvertFloat4ToU32(patchTokenColor(cell.kind, token.kind, emphasized)),
            token.text,
        );
        cursor_x += width;
        text_offset += token.text.len;
    }
}

fn drawPatchInlineHighlights(
    draw_list: anytype,
    cell: zig_dif.SideBySideCell,
    token: zig_dif.Token,
    token_start: usize,
    token_x: f32,
    token_y: f32,
) void {
    if (cell.emphasis_ranges.len == 0) return;
    const token_end = token_start + token.text.len;
    const highlight_color = patchInlineHighlightColor(cell.kind);
    if (highlight_color[3] <= 0.0) return;

    for (cell.emphasis_ranges) |range| {
        const overlap_start = @max(range.start, token_start);
        const overlap_end = @min(range.end, token_end);
        if (overlap_end <= overlap_start) continue;

        const local_start = overlap_start - token_start;
        const local_end = overlap_end - token_start;
        const prefix_width = if (local_start > 0) zgui.calcTextSize(token.text[0..local_start], .{})[0] else 0.0;
        const highlight_width = zgui.calcTextSize(token.text[local_start..local_end], .{})[0];
        if (highlight_width <= 0.0) continue;

        draw_list.addRectFilled(.{
            .pmin = .{ token_x + prefix_width, token_y + theme.scaledUi(0.5) },
            .pmax = .{
                token_x + prefix_width + highlight_width,
                token_y + zgui.getTextLineHeight() - theme.scaledUi(0.5),
            },
            .col = zgui.colorConvertFloat4ToU32(highlight_color),
            .rounding = theme.scaledUi(4.0),
        });
    }
}

fn patchMetaBackground(kind: zig_dif.SideBySideRowKind) [4]f32 {
    return switch (kind) {
        .file_header => colors.rgba(32, 34, 40, 255),
        .hunk_header => colors.rgba(20, 21, 25, 255),
        .context_gap => colors.rgba(19, 20, 24, 255),
        .note => colors.rgba(22, 22, 26, 255),
        .prelude => colors.rgba(18, 18, 22, 255),
        .code => colors.rgba(24, 24, 28, 255),
    };
}

fn patchMetaPillBackground(kind: zig_dif.SideBySideRowKind) [4]f32 {
    return switch (kind) {
        .hunk_header => colors.rgba(31, 27, 18, 255),
        .context_gap => colors.rgba(22, 23, 28, 255),
        else => patchMetaBackground(kind),
    };
}

fn patchMetaPillBorder(kind: zig_dif.SideBySideRowKind) [4]f32 {
    return switch (kind) {
        .hunk_header => colors.rgba(113, 89, 30, 255),
        .context_gap => colors.rgba(62, 64, 72, 255),
        else => colors.rgba(58, 60, 68, 255),
    };
}

fn patchCellBackground(kind: ?zig_dif.DisplayLineKind) [4]f32 {
    return switch (kind orelse .context) {
        .addition => colors.rgba(30, 52, 43, 255),
        .deletion => colors.rgba(57, 34, 36, 255),
        .context => colors.rgba(24, 24, 28, 255),
        .context_gap, .file_header, .hunk_header, .note, .prelude => colors.rgba(24, 24, 28, 255),
    };
}

fn patchInlineHighlightColor(kind: zig_dif.DisplayLineKind) [4]f32 {
    return switch (kind) {
        .addition => colors.rgba(52, 224, 148, 56),
        .deletion => colors.rgba(255, 100, 100, 56),
        else => colors.rgba(255, 255, 255, 0),
    };
}

fn patchDisplayLineKindForRow(kind: zig_dif.SideBySideRowKind) zig_dif.DisplayLineKind {
    return switch (kind) {
        .prelude => .prelude,
        .file_header => .file_header,
        .hunk_header => .hunk_header,
        .context_gap => .context_gap,
        .note => .note,
        .code => .context,
    };
}

fn patchNumberColumnWidth(digits: usize) f32 {
    const width_per_digit = zgui.calcTextSize("0", .{})[0];
    return width_per_digit * @as(f32, @floatFromInt(@max(digits, 1)));
}

fn patchViewContentWidth(view: zig_dif.SideBySidePatchView) f32 {
    return patchViewLayout(view).total;
}

const PatchColumnLayout = struct {
    left: f32,
    right: f32,
    total: f32,
};

fn patchViewLayout(view: zig_dif.SideBySidePatchView) PatchColumnLayout {
    const gap = theme.scaledUi(8.0);
    const left_digits = maxLineNumberDigits(view.max_old_line);
    const right_digits = maxLineNumberDigits(view.max_new_line);
    var max_left: f32 = theme.scaledUi(300.0);
    var max_right: f32 = theme.scaledUi(300.0);
    var max_meta: f32 = theme.scaledUi(300.0);
    for (view.rows) |row| {
        switch (row.kind) {
            .code => {
                max_left = @max(max_left, patchCellContentWidth(row.left, left_digits));
                max_right = @max(max_right, patchCellContentWidth(row.right, right_digits));
            },
            else => {
                max_meta = @max(max_meta, patchMetaRowWidth(row));
            },
        }
    }
    const total = @max(max_left + gap + max_right, max_meta);
    return .{
        .left = max_left,
        .right = max_right,
        .total = total,
    };
}

fn patchCellContentWidth(cell: ?zig_dif.SideBySideCell, digits: usize) f32 {
    const text = if (cell) |value| value.text else "";
    return theme.scaledUi(8.0) + patchNumberColumnWidth(digits) + theme.scaledUi(10.0) + theme.scaledUi(8.0) + zgui.calcTextSize(text, .{})[0];
}

fn patchMetaTokensWidth(tokens: []const zig_dif.Token) f32 {
    var width: f32 = 0.0;
    for (tokens) |token| width += zgui.calcTextSize(token.text, .{})[0];
    return width;
}

fn patchMetaRowWidth(row: zig_dif.SideBySideRow) f32 {
    return switch (row.kind) {
        .hunk_header, .context_gap => blk: {
            var label_buf: [192]u8 = undefined;
            const label = patchMetaRowLabel(row, &label_buf);
            break :blk zgui.calcTextSize(label, .{})[0] + theme.scaledUi(32.0);
        },
        else => patchMetaTokensWidth(row.tokens) + theme.scaledUi(32.0),
    };
}

fn patchMetaRowLabel(row: zig_dif.SideBySideRow, buf: []u8) []const u8 {
    const raw = patchTokensText(row.tokens, buf);
    return switch (row.kind) {
        .hunk_header => patchCleanHunkLabel(raw, buf),
        .context_gap => patchCleanContextGapLabel(raw, buf),
        else => raw,
    };
}

fn patchTokensText(tokens: []const zig_dif.Token, buf: []u8) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    for (tokens) |token| {
        writer.writeAll(token.text) catch return "";
    }
    return buf[0..stream.pos];
}

fn patchCleanHunkLabel(text: []const u8, buf: []u8) []const u8 {
    const parsed = parsePatchHunkHeader(text) orelse return std.mem.trim(u8, text, " @");
    const old_end = parsed.old.start + parsed.old.count - 1;
    const new_end = parsed.new.start + parsed.new.count - 1;
    return std.fmt.bufPrint(buf, "{d}-{d} -> {d}-{d}", .{
        parsed.old.start,
        old_end,
        parsed.new.start,
        new_end,
    }) catch std.mem.trim(u8, text, " @");
}

fn patchCleanContextGapLabel(text: []const u8, buf: []u8) []const u8 {
    const count = parseFirstUnsigned(text) orelse return std.mem.trim(u8, text, " .");
    return std.fmt.bufPrint(buf, "{d} unchanged {s}", .{
        count,
        if (count == 1) "line" else "lines",
    }) catch std.mem.trim(u8, text, " .");
}

const PatchHunkRange = struct {
    start: usize,
    count: usize,
};

const PatchHunkHeader = struct {
    old: PatchHunkRange,
    new: PatchHunkRange,
};

fn parsePatchHunkHeader(text: []const u8) ?PatchHunkHeader {
    if (!std.mem.startsWith(u8, text, "@@")) return null;

    var parts = std.mem.tokenizeAny(u8, text, " \t");
    _ = parts.next() orelse return null;
    const old_text = parts.next() orelse return null;
    const new_text = parts.next() orelse return null;
    const old_range = parsePatchRange(old_text) orelse return null;
    const new_range = parsePatchRange(new_text) orelse return null;
    return .{ .old = old_range, .new = new_range };
}

fn parsePatchRange(text: []const u8) ?PatchHunkRange {
    if (text.len < 2) return null;
    const trimmed = std.mem.trim(u8, text, ",");
    const signless = trimmed[1..];
    var parts = std.mem.splitScalar(u8, signless, ',');
    const start_text = parts.next() orelse return null;
    const start = std.fmt.parseInt(usize, start_text, 10) catch return null;
    const count = if (parts.next()) |count_text|
        std.fmt.parseInt(usize, count_text, 10) catch return null
    else
        1;
    return .{
        .start = start,
        .count = @max(count, 1),
    };
}

fn parseFirstUnsigned(text: []const u8) ?usize {
    var index: usize = 0;
    while (index < text.len and !std.ascii.isDigit(text[index])) : (index += 1) {}
    if (index >= text.len) return null;
    const start = index;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
    return std.fmt.parseInt(usize, text[start..index], 10) catch null;
}

fn patchTokenColor(line_kind: zig_dif.DisplayLineKind, token_kind: zig_dif.TokenKind, emphasized: bool) [4]f32 {
    if (line_kind == .hunk_header) return colors.rgb(0xC7, 0xA3, 0x3A);
    if (line_kind == .context_gap) return theme.COLOR_TEXT_SUBTLE;
    if (line_kind == .note) return theme.COLOR_TEXT_SUBTLE;
    if (line_kind == .file_header or line_kind == .prelude) return theme.COLOR_TEXT_MUTED;

    const base = switch (line_kind) {
        .addition => theme.COLOR_DIFF_ADD,
        .deletion => theme.COLOR_DIFF_REMOVE,
        else => theme.COLOR_TEXT_MUTED,
    };

    if (emphasized) {
        return switch (token_kind) {
            .plain => theme.COLOR_WHITE,
            .comment => theme.COLOR_TEXT_SUBTLE,
            .string => theme.lighten(theme.COLOR_GREEN, 0.18),
            .number => colors.rgb(0xFF, 0xC9, 0x75),
            .keyword => theme.lighten(theme.COLOR_YELLOW, 0.15),
            .type_name => theme.lighten(colors.rgb(0x7D, 0xC4, 0xE4), 0.16),
            .function_name => theme.lighten(colors.rgb(0x56, 0xB6, 0xC2), 0.16),
            .property_name => theme.lighten(colors.rgb(0x61, 0xAF, 0xEF), 0.16),
            .variable_name => theme.COLOR_WHITE,
            .constant_name => theme.lighten(colors.rgb(0xE5, 0xC0, 0x7B), 0.16),
            .operator, .punctuation => theme.COLOR_WHITE,
        };
    }

    return switch (token_kind) {
        .plain => base,
        .comment => theme.COLOR_TEXT_SUBTLE,
        .string => theme.lighten(theme.COLOR_GREEN, 0.08),
        .number => colors.rgb(0xF0, 0xB0, 0x5C),
        .keyword => theme.COLOR_YELLOW,
        .type_name => colors.rgb(0x7D, 0xC4, 0xE4),
        .function_name => colors.rgb(0x56, 0xB6, 0xC2),
        .property_name => colors.rgb(0x61, 0xAF, 0xEF),
        .variable_name => theme.COLOR_TEXT_MUTED,
        .constant_name => colors.rgb(0xE5, 0xC0, 0x7B),
        .operator, .punctuation => base,
    };
}

fn patchTokenIsEmphasized(cell: zig_dif.SideBySideCell, token_start: usize, token_len: usize) bool {
    if (cell.emphasis_ranges.len == 0) return false;
    const token_end = token_start + token_len;
    for (cell.emphasis_ranges) |range| {
        if (range.start < token_end and range.end > token_start) return true;
    }
    return false;
}

fn patchMetaLabelColor(kind: zig_dif.SideBySideRowKind) [4]f32 {
    return switch (kind) {
        .hunk_header => colors.rgb(0xE0, 0xB8, 0x5A),
        .context_gap => theme.COLOR_TEXT_SUBTLE,
        .file_header => theme.COLOR_TEXT_MUTED,
        .note => theme.COLOR_TEXT_SUBTLE,
        .prelude => theme.COLOR_TEXT_MUTED,
        .code => theme.COLOR_TEXT_MUTED,
    };
}

fn maxLineNumberDigits(value: usize) usize {
    if (value == 0) return 1;
    return std.math.log10_int(value) + 1;
}

fn renderPatchTextLine(color: [4]f32, line: []const u8) void {
    if (line.len == 0) {
        zgui.textColored(color, " ", .{});
        return;
    }
    zgui.textColored(color, "{s}", .{line});
}

fn renderPendingDiffPatchFallback(patch: []const u8) void {
    var lines = std.mem.tokenizeScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, " ", .{});
            continue;
        }

        const color = switch (line[0]) {
            '+' => if (std.mem.startsWith(u8, line, "+++")) theme.COLOR_TEXT_SUBTLE else theme.COLOR_DIFF_ADD,
            '-' => if (std.mem.startsWith(u8, line, "---")) theme.COLOR_TEXT_SUBTLE else theme.COLOR_DIFF_REMOVE,
            '@' => theme.COLOR_YELLOW,
            else => theme.COLOR_TEXT_MUTED,
        };
        zgui.textColored(color, "{s}", .{line});
    }
}

/// Renders the composer card, input, pickers, and send button.
fn renderComposer(state: *app_state.AppState, width: f32, height: f32) void {
    const composer_bg = colors.GREEN_600;
    const composer_rounding = theme.scaledUi(18.0);
    state.composer_focused = false;
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = composer_rounding });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(18.0), theme.scaledUi(12.0) } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = composer_bg });
    // zgui.pushStyleColor4f(.{ .idx = .border, .c = .{ 0, 0, 0, 0 } });

    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    const composer_screen_pos = zgui.getCursorScreenPos();
    _ = zgui.beginChild("Composer", .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = true },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });

        const border_color = colors.DARK_BLUE;
        const draw_list = zgui.getWindowDrawList();
        draw_list.addRect(.{
            .pmin = composer_screen_pos,
            .pmax = .{ composer_screen_pos[0] + width, composer_screen_pos[1] + height },
            .col = zgui.colorConvertFloat4ToU32(border_color),
            .rounding = composer_rounding,
            .thickness = 1.5,
        });
    }

    if (state.currentThread().draft_image) |image| {
        renderComposerAttachmentPreview(state, image);
        zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(10.0) });
    }

    const attachment_height: f32 = if (state.currentThread().draft_image != null) theme.scaledUi(82.0) else 0.0;
    const content_width = @max(zgui.getContentRegionAvail()[0], theme.scaledUi(120.0));
    const input_h: f32 = @max(height - theme.scaledUi(86.0) - attachment_height, theme.scaledUi(48.0));
    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = 0.0 });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ theme.scaledUi(4.0), theme.scaledUi(6.0) } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = composer_bg });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = composer_bg });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = composer_bg });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = .{ 0, 0, 0, 0 } });

    const cursor_before = zgui.getCursorScreenPos();
    const buf = state.draftBuffer();
    if (state.consumeComposerFocusRequest()) {
        zgui.setKeyboardFocusHere(0);
    }
    zgui.pushIntId(@intCast(state.composer_input_nonce));
    defer zgui.popId();
    const submitted = zgui.inputTextMultiline("##chat-draft", .{
        .buf = buf,
        .w = content_width,
        .h = input_h,
        .flags = .{
            .ctrl_enter_for_new_line = true,
            .enter_returns_true = true,
        },
    });
    state.composer_focused = zgui.isItemFocused();
    if (state.composer_focused) {
        state.terminal_focused = false;
    }
    const input_rect_min = zgui.getItemRectMin();
    const input_rect_max = zgui.getItemRectMax();
    zgui.popStyleColor(.{ .count = 4 });
    zgui.popStyleVar(.{ .count = 2 });
    state.updateFileSearch();

    if (buf[0] == 0) {
        const hint_pos = .{ cursor_before[0] + theme.scaledUi(4.0), cursor_before[1] + theme.scaledUi(6.0) };
        const draw_list = zgui.getWindowDrawList();
        draw_list.addText(hint_pos, zgui.colorConvertFloat4ToU32(colors.rgba(100, 102, 115, 255)), "Ask anything, or use / to show available commands", .{});
    }

    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(2.0) });
    composer_pickers.render(state);
    const pending = runtime.isSendPending(state);
    if (pending) {
        if (state.pendingFollowupHint()) |hint| {
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{s}", .{hint});
            zgui.sameLine(.{ .spacing = theme.scaledUi(6.0) });
            zgui.textColored(theme.COLOR_TEXT_MUTED, "to hold a follow-up while this thread is running", .{});
        }
    }

    const send_btn_size = theme.scaledUi(32.0);
    zgui.sameLine(.{ .spacing = 0.0 });
    const avail = zgui.getContentRegionAvail();
    if (avail[0] > send_btn_size + theme.scaledUi(4.0)) {
        zgui.sameLine(.{ .spacing = avail[0] - send_btn_size - theme.scaledUi(4.0) });
    }

    {
        const btn_pos = zgui.getCursorScreenPos();
        const clicked = zgui.invisibleButton("##send-btn", .{ .w = send_btn_size, .h = send_btn_size });
        const hovered = zgui.isItemHovered(.{});
        const draw_list = zgui.getWindowDrawList();
        const cx = btn_pos[0] + send_btn_size * 0.5;
        const cy = btn_pos[1] + send_btn_size * 0.5;
        const r = send_btn_size * 0.5;

        const circle_color = if (pending)
            colors.rgba(80, 72, 24, 255)
        else if (hovered)
            theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.12)
        else
            theme.COLOR_SECONDARY_GREEN;
        draw_list.addCircleFilled(.{
            .p = .{ cx, cy },
            .r = r,
            .col = zgui.colorConvertFloat4ToU32(circle_color),
        });

        if (pending) {
            const white = zgui.colorConvertFloat4ToU32(theme.COLOR_WHITE);
            const stop_half = theme.scaledUi(5.5);
            draw_list.addRectFilled(.{
                .pmin = .{ cx - stop_half, cy - stop_half },
                .pmax = .{ cx + stop_half, cy + stop_half },
                .col = white,
                .rounding = theme.scaledUi(2.0),
            });
        } else {
            const white = zgui.colorConvertFloat4ToU32(theme.COLOR_WHITE);
            const arrow_half_w = theme.scaledUi(5.5);
            const arrow_top = cy - theme.scaledUi(7.0);
            const arrow_mid = cy - theme.scaledUi(1.0);
            const arrow_bottom = cy + theme.scaledUi(7.0);

            draw_list.addTriangleFilled(.{
                .p1 = .{ cx, arrow_top },
                .p2 = .{ cx - arrow_half_w, arrow_mid },
                .p3 = .{ cx + arrow_half_w, arrow_mid },
                .col = white,
            });
            draw_list.addLine(.{
                .p1 = .{ cx, arrow_mid },
                .p2 = .{ cx, arrow_bottom },
                .col = white,
                .thickness = theme.scaledUi(2.4),
            });
        }

        if (clicked and pending) {
            state.abortCurrentThreadSend();
        } else if ((clicked or submitted) and !pending) {
            if (submitted and state.acceptPrimaryFileSearchResult()) {
                return;
            }
            state.sendDraft() catch |err| {
                runtime.log.err("failed to send draft: {s}", .{@errorName(err)});
            };
        } else if (submitted and pending) {
            state.setSidebarNotice("This thread is still running. Press Tab to queue or steer a follow-up.");
        }
    }

    if (state.hasActiveFileSearch()) {
        renderComposerFileSearchResults(state, composer_screen_pos, width, input_rect_min, input_rect_max);
    }
}

fn renderComposerFileSearchResults(
    state: *app_state.AppState,
    composer_screen_pos: [2]f32,
    composer_width: f32,
    input_rect_min: [2]f32,
    input_rect_max: [2]f32,
) void {
    const results = state.fileSearchResults();
    const row_height = theme.scaledUi(28.0);
    const visible_rows = @max(@as(usize, 1), @min(results.len, 6));
    const visible_rows_height = row_height * @as(f32, @floatFromInt(visible_rows));
    const top_padding = theme.scaledUi(16.0);
    const bottom_padding = theme.scaledUi(12.0);
    const popup_gap = theme.scaledUi(8.0);
    const top_safe_margin = theme.scaledUi(72.0);
    const available_above = @max(input_rect_min[1] - top_safe_margin - popup_gap, row_height + top_padding + bottom_padding);
    const list_height = theme.clampf(
        available_above - top_padding - bottom_padding,
        row_height,
        visible_rows_height,
    );
    const card_height = top_padding + bottom_padding + list_height;
    const horizontal_margin = theme.scaledUi(12.0);
    const card_width = theme.clampf(
        input_rect_max[0] - input_rect_min[0],
        theme.scaledUi(280.0),
        composer_width - horizontal_margin * 2.0,
    );
    const popup_x = theme.clampf(
        input_rect_min[0],
        composer_screen_pos[0] + horizontal_margin,
        composer_screen_pos[0] + composer_width - horizontal_margin - card_width,
    );
    const popup_y = @max(
        top_safe_margin,
        input_rect_min[1] - card_height - popup_gap,
    );

    zgui.setNextWindowPos(.{
        .x = popup_x,
        .y = popup_y,
    });
    zgui.setNextWindowSize(.{
        .w = card_width,
        .h = card_height,
    });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = theme.scaledUi(10.0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(10.0), theme.scaledUi(8.0) } });
    zgui.pushStyleColor4f(.{ .idx = .window_bg, .c = colors.rgba(34, 36, 42, 244) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    _ = zgui.begin("ComposerFileSearchOverlay", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_scrollbar = true,
            .no_collapse = true,
            .no_saved_settings = true,
            .no_move = true,
            .no_focus_on_appearing = true,
            .no_nav_focus = true,
        },
    });
    defer {
        zgui.end();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    if (results.len == 0) {
        const message = if (state.fileSearchIsScanning())
            "Indexing project files..."
        else
            "Type to search files...";
        zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{message});
        return;
    }

    const ensure_selected_visible = state.consumeFileSearchEnsureSelectionVisible();
    _ = zgui.beginChild("ComposerFileSearchResults", .{
        .w = 0.0,
        .h = list_height,
        .child_flags = .{ .border = false },
        .window_flags = .{ .no_saved_settings = true },
    });
    defer zgui.endChild();

    for (results, 0..) |result, index| {
        zgui.pushIntId(@intCast(index));

        const selected = index == state.fileSearchSelectedIndex();
        if (zgui.selectable("##file-search-row", .{
            .selected = selected,
            .h = row_height,
        })) {
            zgui.popId();
            _ = state.selectFileSearchResult(index);
            return;
        }

        const icon = file_icons.forFile(result.file_name);
        const row_min = zgui.getItemRectMin();
        const row_max = zgui.getItemRectMax();
        const draw_list = zgui.getWindowDrawList();
        const row_center_y = row_min[1] + (row_max[1] - row_min[1]) * 0.5;
        const icon_size = zgui.calcTextSize(icon.glyph, .{});
        const text_size = zgui.calcTextSize(result.relative_path, .{});
        const icon_pos = .{
            row_min[0] + theme.scaledUi(8.0),
            row_center_y - icon_size[1] * 0.5,
        };
        const name_pos = .{
            row_min[0] + theme.scaledUi(34.0),
            row_center_y - text_size[1] * 0.5,
        };
        draw_list.addTextUnformatted(icon_pos, zgui.colorConvertFloat4ToU32(icon.color), icon.glyph);
        draw_list.addTextUnformatted(name_pos, zgui.colorConvertFloat4ToU32(if (selected) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), result.relative_path);
        if (selected and ensure_selected_visible) {
            zgui.setScrollHereY(.{ .center_y_ratio = 0.5 });
        }
        zgui.popId();
    }
}

/// Draws the compact attachment preview above the composer.
fn renderComposerAttachmentPreview(state: *app_state.AppState, image: app_state.ChatImageAttachment) void {
    zgui.beginGroup();
    defer zgui.endGroup();

    renderImageAttachmentCard(state, image, true);
    zgui.sameLine(.{ .spacing = theme.scaledUi(8.0) });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.rgba(52, 54, 61, 255) });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.rgba(74, 76, 84, 255) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.rgba(92, 94, 102, 255) });
    if (zgui.button("x", .{ .w = theme.scaledUi(26.0), .h = theme.scaledUi(26.0) })) {
        state.clearCurrentDraftImage();
    }
    zgui.popStyleColor(.{ .count = 3 });
}

/// Draws an image attachment card in transcript or composer mode.
fn renderImageAttachmentCard(state: *app_state.AppState, image: app_state.ChatImageAttachment, compact: bool) void {
    const avail_width = @max(zgui.getContentRegionAvail()[0], theme.scaledUi(120.0));
    const card_width: f32 = if (compact)
        theme.clampf(avail_width, theme.scaledUi(196.0), theme.scaledUi(320.0))
    else
        theme.clampf(avail_width, theme.scaledUi(220.0), theme.scaledUi(420.0));
    const card_height: f32 = if (compact)
        theme.clampf(card_width * 0.34, theme.scaledUi(68.0), theme.scaledUi(96.0))
    else
        theme.clampf(card_width * 0.74, theme.scaledUi(168.0), theme.scaledUi(260.0));
    const card_padding: f32 = if (compact) theme.scaledUi(8.0) else theme.scaledUi(10.0);
    const preview_width: f32 = if (compact) theme.clampf(card_width * 0.26, theme.scaledUi(50.0), theme.scaledUi(72.0)) else card_width - (card_padding * 2.0);
    const preview_height: f32 = if (compact) card_height - (card_padding * 2.0) else theme.clampf(card_height * 0.62, theme.scaledUi(116.0), theme.scaledUi(180.0));
    const start = zgui.getCursorScreenPos();
    var byte_size_buf = std.mem.zeroes([32:0]u8);
    const byte_size_text = runtime.formatByteSize(&byte_size_buf, image.byte_size);

    zgui.dummy(.{ .w = card_width, .h = card_height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{
        .pmin = start,
        .pmax = .{ start[0] + card_width, start[1] + card_height },
        .col = zgui.colorConvertFloat4ToU32(colors.rgba(42, 43, 50, 255)),
        .rounding = theme.scaledUi(12.0),
    });
    draw_list.addRect(.{
        .pmin = start,
        .pmax = .{ start[0] + card_width, start[1] + card_height },
        .col = zgui.colorConvertFloat4ToU32(colors.DARK_BLUE),
        .rounding = theme.scaledUi(12.0),
        .thickness = 1.0,
    });
    draw_list.addRectFilled(.{
        .pmin = .{ start[0] + card_padding, start[1] + card_padding },
        .pmax = .{ start[0] + card_padding + preview_width, start[1] + card_padding + preview_height },
        .col = zgui.colorConvertFloat4ToU32(colors.rgba(24, 25, 31, 255)),
        .rounding = theme.scaledUi(10.0),
    });

    zgui.pushStrIdZ(image.path);
    defer zgui.popId();

    zgui.setCursorScreenPos(.{ start[0] + card_padding, start[1] + card_padding });
    const texture = state.ensureImageTexture(image.path);
    if (texture) |cached| {
        const dims = runtime.scaledImageSize(cached.width, cached.height, preview_width, preview_height);
        const x_offset = (preview_width - dims[0]) * 0.5;
        const y_offset = (preview_height - dims[1]) * 0.5;
        const image_pos = [2]f32{ start[0] + card_padding + x_offset, start[1] + card_padding + y_offset };
        zgui.setCursorScreenPos(image_pos);
        zgui.image(runtime.textureRefFromGlId(cached.texture_id), .{
            .w = dims[0],
            .h = dims[1],
        });
        zgui.setCursorScreenPos(image_pos);
        if (zgui.invisibleButton("##attachment-thumb", .{
            .w = dims[0],
            .h = dims[1],
        })) {
            state.openImageModal(image.path);
        }
        if (zgui.isItemHovered(.{})) {
            draw_list.addRect(.{
                .pmin = .{ image_pos[0], image_pos[1] },
                .pmax = .{ image_pos[0] + dims[0], image_pos[1] + dims[1] },
                .col = zgui.colorConvertFloat4ToU32(colors.DARK_BLUE),
                .rounding = theme.scaledUi(8.0),
                .thickness = 1.0,
            });
        }
    } else {
        if (zgui.button("Image", .{ .w = preview_width, .h = preview_height })) {
            state.openImageModal(image.path);
        }
    }

    if (compact) {
        zgui.setCursorScreenPos(.{ start[0] + card_padding + preview_width + theme.scaledUi(10.0), start[1] + theme.scaledUi(11.0) });
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{image.file_name});
        zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}  {s}", .{ image.mime, byte_size_text });
        zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Clipboard image", .{});
    } else {
        zgui.setCursorScreenPos(.{ start[0] + theme.scaledUi(12.0), start[1] + card_padding + preview_height + theme.scaledUi(10.0) });
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{image.file_name});
        zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}  {s}", .{ image.mime, byte_size_text });
    }
    zgui.setCursorScreenPos(.{ start[0], start[1] + card_height });
}

const TranscriptBubbleTheme = struct {
    background: [4]f32,
    border: [4]f32,
    author: [4]f32,
};

/// Returns the bubble colors for a transcript role.
fn transcriptBubbleTheme(role: anytype) TranscriptBubbleTheme {
    if (role == .user) return .{
        // .background = colors.rgba(18, 62, 42, 255),
        .background = colors.rgba(0x20, 0x27, 0x2A, 255),
        .border = colors.DARK_BLUE,
        .author = colors.rgba(130, 255, 180, 255),
    };
    if (role == .assistant) return .{
        // .background = colors.rgba(38, 39, 44, 255),

        .background = colors.rgba(0x0D, 0x12, 0x13, 255),
        // .border = colors.DARK_BLUE,
        .border = colors.rgba(0, 0, 0, 0),
        .author = colors.rgba(180, 185, 200, 255),
    };
    return .{
        .background = colors.rgba(52, 42, 18, 255),
        .border = colors.DARK_BLUE,
        .author = colors.rgba(255, 230, 150, 255),
    };
}

/// Updates the sticky auto-follow latch for the live transcript tail.
fn updateTranscriptAutoFollow(state: *app_state.AppState, has_pending_stream: bool) void {
    if (!has_pending_stream) {
        state.transcript_auto_follow_pending = false;
        return;
    }

    if (state.scroll_transcript_to_bottom_frames > 0 or transcriptIsNearBottom()) {
        state.transcript_auto_follow_pending = true;
    }
}

/// Checks whether the transcript viewport is already near the tail.
fn transcriptIsNearBottom() bool {
    const scroll_max_y = zgui.getScrollMaxY();
    if (scroll_max_y <= 0.0) return true;
    const scroll_y = zgui.getScrollY();
    return (scroll_max_y - scroll_y) <= theme.scaledUi(72.0);
}

fn jumpTranscriptToTail() void {
    zgui.setScrollY(zgui.getScrollMaxY());
}

fn smoothScrollTranscriptToTail() void {
    const target_y = zgui.getScrollMaxY();
    const current_y = zgui.getScrollY();
    const remaining = target_y - current_y;
    if (remaining <= 0.5) {
        zgui.setScrollY(target_y);
        return;
    }

    const step = std.math.clamp(
        remaining * 0.42,
        theme.scaledUi(10.0),
        theme.scaledUi(160.0),
    );
    const next_y = @min(current_y + step, target_y);
    zgui.setScrollY(next_y);
}

fn formatPendingWorkingLabel(buf: []u8, started_at_ms: i64) []const u8 {
    const now_ms = std.time.milliTimestamp();
    const safe_started_at_ms = @max(started_at_ms, 0);
    const elapsed_ms = @max(now_ms - safe_started_at_ms, 0);
    const total_seconds: u64 = @intCast(@divTrunc(elapsed_ms, std.time.ms_per_s));
    const hours = total_seconds / 3600;
    const minutes = (total_seconds / 60) % 60;
    const seconds = total_seconds % 60;

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "Working - {d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "Working - 0:00";
    }
    return std.fmt.bufPrint(buf, "Working - {d}:{d:0>2}", .{ minutes, seconds }) catch "Working - 0:00";
}

/// Adapts typed transcript height calculation to the generic helper.
fn transcriptBubbleHeight(state: *app_state.AppState, message_index: ?usize, role: app_state.ChatRole, author: []const u8, body: []const u8, image: ?app_state.ChatImageAttachment) f32 {
    return transcriptBubbleHeightGeneric(
        state,
        message_index,
        role,
        author,
        body,
        image,
        false,
        shouldRenderCodexFileReferenceBody(state, role, body, false),
    );
}

/// Measures the height needed for a transcript bubble.
fn transcriptBubbleHeightGeneric(
    state: ?*app_state.AppState,
    message_index: ?usize,
    role: anytype,
    author: []const u8,
    body: []const u8,
    image: anytype,
    muted_body: bool,
    use_codex_file_reference_layout: bool,
) f32 {
    const style = zgui.getStyle();
    const bubble_width = transcriptBubbleWidth(role);
    const inner_width = @max(bubble_width - (theme.TRANSCRIPT_BUBBLE_PADDING_X * 2.0), 64.0);
    const author_size = if (shouldShowBubbleAuthor(author)) zgui.calcTextSize(author, .{}) else .{ 0.0, 0.0 };
    const body_height = if (use_codex_file_reference_layout)
        codexFileReferenceBodyHeight(body, inner_width)
    else if (!muted_body)
        measureMarkdownTranscriptBodyHeight(state, message_index, body, inner_width)
    else
        zgui.calcTextSize(body, .{ .wrap_width = inner_width })[1];
    const image_height: f32 = if (image != null) theme.clampf(inner_width * 0.46, theme.scaledUi(132.0), theme.scaledUi(220.0)) else 0.0;
    const image_gap: f32 = if (image != null and body.len > 0) theme.scaledUi(8.0) else 0.0;
    const vertical_padding = theme.TRANSCRIPT_BUBBLE_PADDING_Y * 2.0;
    const text_gap = if (shouldShowBubbleAuthor(author)) 2.0 + style.item_spacing[1] else 0.0;
    const border_allowance = 4.0;
    return @max(author_size[1] + body_height + image_height + image_gap + vertical_padding + text_gap + border_allowance, theme.scaledUi(56.0));
}

fn measureMarkdownTranscriptBodyHeight(state: ?*app_state.AppState, message_index: ?usize, body: []const u8, inner_width: f32) f32 {
    var fallback_view: ?chat_markdown.BodyView = null;
    defer if (fallback_view) |*view| view.deinit(std.heap.page_allocator);

    const view = if (state) |app|
        transcriptMarkdownBodyView(app, message_index, body, &fallback_view) orelse return zgui.calcTextSize(body, .{ .wrap_width = inner_width })[1]
    else blk: {
        fallback_view = chat_markdown.buildBodyView(std.heap.page_allocator, body) catch {
            return zgui.calcTextSize(body, .{ .wrap_width = inner_width })[1];
        };
        break :blk fallback_view.?;
    };

    return chat_markdown.measureBodyHeight(view, inner_width, transcriptMarkdownRenderOptions());
}

fn transcriptBubbleWidth(role: anytype) f32 {
    const avail = zgui.getContentRegionAvail();
    if (role == .user) return avail[0] * 0.5;
    return avail[0];
}

fn bubbleWidthForChild(role: anytype, bubble_width: f32) f32 {
    if (role == .user) return bubble_width;
    return 0.0;
}

fn shouldRightAlignBubble(role: anytype) bool {
    return role == .user;
}

fn shouldShowBubbleAuthor(author: []const u8) bool {
    return !std.mem.eql(u8, author, "You") and !std.mem.eql(u8, author, "Codex");
}

/// Returns the compact height for a simple changed-files card.
/// Estimates the current live diff card height.
fn pendingDiffCardHeight(files: anytype) f32 {
    var height: f32 = 52.0;
    for (files) |file| {
        height += 30.0;
        if (file.expanded) {
            const patch_height = if (file.patch) |patch| pendingDiffPatchHeight(patch) else 44.0;
            height += patch_height + 8.0;
        }
    }
    return @min(height, 620.0);
}

/// Estimates the viewport height for a patch block.
fn pendingDiffPatchHeight(patch: []const u8) f32 {
    const line_count = countTextLines(patch);
    return @min(28.0 + (@as(f32, @floatFromInt(line_count)) * 18.0), 240.0);
}

/// Parses changed-file text from legacy or streamed bodies.
fn parseChangedFileEntries(body: []const u8) std.ArrayListUnmanaged(runtime.ChangedFileEntry) {
    if (std.mem.startsWith(u8, body, runtime.PERSISTED_DIFF_MARKER)) {
        return parsePersistedDiffEntries(body);
    }

    var entries: std.ArrayListUnmanaged(runtime.ChangedFileEntry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const plus_index = std.mem.lastIndexOf(u8, trimmed, " +") orelse continue;
        const path = std.mem.trimRight(u8, trimmed[0..plus_index], &std.ascii.whitespace);
        const counts = trimmed[plus_index + 2 ..];
        const slash_index = std.mem.indexOf(u8, counts, " / -") orelse continue;
        const add_slice = counts[0..slash_index];
        const del_slice = counts[slash_index + 5 ..];
        const additions = std.fmt.parseInt(i64, add_slice, 10) catch 0;
        const deletions = std.fmt.parseInt(i64, del_slice, 10) catch 0;

        entries.append(std.heap.page_allocator, .{
            .path = path,
            .additions = additions,
            .deletions = deletions,
            .patch = null,
        }) catch break;
    }
    return entries;
}

/// Parses the persisted diff wire format into file entries.
fn parsePersistedDiffEntries(body: []const u8) std.ArrayListUnmanaged(runtime.ChangedFileEntry) {
    var entries: std.ArrayListUnmanaged(runtime.ChangedFileEntry) = .empty;
    var cursor: usize = runtime.PERSISTED_DIFF_MARKER.len;

    while (cursor < body.len) {
        const line_end_rel = std.mem.indexOfScalarPos(u8, body, cursor, '\n') orelse break;
        const header = body[cursor..line_end_rel];
        cursor = line_end_rel + 1;
        if (!std.mem.startsWith(u8, header, "FILE\t")) break;

        var parts = std.mem.splitScalar(u8, header, '\t');
        _ = parts.next();
        const path = parts.next() orelse break;
        const additions_text = parts.next() orelse break;
        const deletions_text = parts.next() orelse break;
        const patch_len_text = parts.next() orelse break;

        const additions = std.fmt.parseInt(i64, additions_text, 10) catch 0;
        const deletions = std.fmt.parseInt(i64, deletions_text, 10) catch 0;
        const patch_len = std.fmt.parseInt(usize, patch_len_text, 10) catch 0;
        if (cursor + patch_len > body.len) break;

        const patch = if (patch_len > 0) body[cursor .. cursor + patch_len] else null;
        cursor += patch_len;
        if (cursor < body.len and body[cursor] == '\n') cursor += 1;

        entries.append(std.heap.page_allocator, .{
            .path = path,
            .additions = additions,
            .deletions = deletions,
            .patch = patch,
        }) catch break;
    }

    return entries;
}

/// Totals additions and deletions for parsed changed files.
fn summarizeChangedFiles(entries: anytype) struct { additions: i64, deletions: i64 } {
    var additions: i64 = 0;
    var deletions: i64 = 0;
    for (entries.items) |entry| {
        additions += entry.additions;
        deletions += entry.deletions;
    }
    return .{ .additions = additions, .deletions = deletions };
}

/// Reports whether any changed-file entry includes a patch body.
fn changedFilesEntriesHavePatch(entries: anytype) bool {
    for (entries) |entry| {
        if (entry.patch != null) return true;
    }
    return false;
}

/// Totals additions and deletions for pending diff files.
fn summarizePendingDiffFiles(files: anytype) struct { additions: i64, deletions: i64 } {
    var additions: i64 = 0;
    var deletions: i64 = 0;
    for (files) |file| {
        additions += file.additions;
        deletions += file.deletions;
    }
    return .{ .additions = additions, .deletions = deletions };
}

/// Counts newline-delimited lines for patch sizing.
fn countTextLines(text: []const u8) usize {
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |char| {
        if (char == '\n') count += 1;
    }
    return count;
}

/// Frees a copied approval snapshot after rendering.
fn freePendingApproval(allocator: std.mem.Allocator, approval: anytype) void {
    if (approval.*) |snapshot| {
        allocator.free(snapshot.call_id);
        allocator.free(snapshot.title);
        allocator.free(snapshot.body);
        approval.* = null;
    }
}
