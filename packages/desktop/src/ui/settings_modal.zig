//! Settings modal for viewing and editing `verde.json` app config.

const std = @import("std");
const palette = @import("palette");
const app_config = @import("../config.zig");
const theme = @import("theme.zig");
const runtime = @import("runtime.zig");

pub const Control = enum(u8) {
    ui_font_dec,
    ui_font_inc,
    terminal_font_dec,
    terminal_font_inc,
    theme_omarchy,
    theme_default,
    open_folder,
    open_editor,
    open_cursor,
    open_vscode,
    open_zed,
};

const OpenChoice = struct {
    label: []const u8,
    control: Control,
};

const OPEN_CHOICES = [_]OpenChoice{
    .{ .label = "Folder", .control = .open_folder },
    .{ .label = "Configured editor", .control = .open_editor },
    .{ .label = "Cursor", .control = .open_cursor },
    .{ .label = "VS Code", .control = .open_vscode },
    .{ .label = "Zed", .control = .open_zed },
};

const ContentLayout = struct {
    theme_omarchy: palette.Rect,
    theme_default: palette.Rect,
    ui_font: palette.Rect,
    terminal_font: palette.Rect,
    open_rows: [OPEN_CHOICES.len]palette.Rect,
    custom_open_row: ?palette.Rect = null,
    footer_note_y: f32,
};

const log = std.log.scoped(.native_ui_settings);

fn layoutModal(width: f32, height: f32) palette.Rect {
    const modal_w = theme.clampf(width * 0.42, theme.scaledUi(420.0), theme.scaledUi(560.0));
    const modal_h = theme.clampf(height * 0.78, theme.scaledUi(520.0), theme.scaledUi(680.0));
    return .{
        .x = (width - modal_w) * 0.5,
        .y = (height - modal_h) * 0.5,
        .w = modal_w,
        .h = modal_h,
    };
}

fn computeContentLayout(state: *runtime.AppState, modal: palette.Rect) ContentLayout {
    const pad = theme.scaledUi(18.0);
    const content_w = modal.w - pad * 2.0;
    const content_x = modal.x + pad;
    var y = modal.y + theme.scaledUi(96.0);

    const segment_gap = theme.scaledUi(8.0);
    const row_h = theme.scaledUi(34.0);
    const segment_w = (content_w - segment_gap) * 0.5;
    const theme_omarchy: palette.Rect = .{ .x = content_x, .y = y, .w = segment_w, .h = row_h };
    const theme_default: palette.Rect = .{ .x = content_x + segment_w + segment_gap, .y = y, .w = segment_w, .h = row_h };
    y += row_h + theme.scaledUi(14.0);

    const ui_font: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = row_h };
    y += row_h + theme.scaledUi(18.0) + theme.scaledUi(14.0);
    y += theme.scaledUi(22.0) + theme.scaledUi(10.0);

    const terminal_font: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = row_h };
    y += row_h + theme.scaledUi(28.0);
    y += theme.scaledUi(22.0) + theme.scaledUi(10.0) + theme.scaledUi(18.0);

    var open_rows: [OPEN_CHOICES.len]palette.Rect = undefined;
    const choice_h = theme.scaledUi(30.0);
    var custom_open_row: ?palette.Rect = null;
    for (OPEN_CHOICES, 0..) |_, index| {
        open_rows[index] = .{ .x = content_x, .y = y, .w = content_w, .h = choice_h };
        y += choice_h + theme.scaledUi(2.0);
    }

    if (state.settings_draft.open_action == .custom) {
        custom_open_row = .{ .x = content_x, .y = y, .w = content_w, .h = choice_h };
        y += choice_h + theme.scaledUi(2.0);
    }

    return .{
        .theme_omarchy = theme_omarchy,
        .theme_default = theme_default,
        .ui_font = ui_font,
        .terminal_font = terminal_font,
        .open_rows = open_rows,
        .custom_open_row = custom_open_row,
        .footer_note_y = y + theme.scaledUi(6.0),
    };
}

fn isControlHovered(state: *const runtime.AppState, control: Control) bool {
    return state.settings_hover_control != null and state.settings_hover_control.? == @intFromEnum(control);
}

fn openActionSelected(state: *const runtime.AppState, control: Control) bool {
    return switch (control) {
        .open_folder => state.settings_draft.open_action == .folder,
        .open_editor => state.settings_draft.open_action == .editor,
        .open_cursor => state.settings_draft.open_action == .cursor,
        .open_vscode => state.settings_draft.open_action == .vscode,
        .open_zed => state.settings_draft.open_action == .zed,
        else => false,
    };
}

/// Registers palette hit targets for the settings modal.
pub fn registerHits(state: *runtime.AppState, width: f32, height: f32, queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void) void {
    if (!state.show_settings_modal) return;

    const modal = layoutModal(width, height);
    queue_hit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .modal_dismiss, 0);
    queue_hit(state, modal, .modal_block, 0);

    const pad = theme.scaledUi(18.0);
    const close_size = theme.scaledUi(28.0);
    queue_hit(state, .{ .x = modal.x + modal.w - pad - close_size, .y = modal.y + pad, .w = close_size, .h = close_size }, .settings_close, 0);

    const button_h = theme.scaledUi(34.0);
    const button_y = modal.y + modal.h - pad - button_h;
    const gap = theme.scaledUi(10.0);
    const button_w = (modal.w - pad * 2.0 - gap) * 0.5;
    queue_hit(state, .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h }, .settings_cancel, 0);
    queue_hit(state, .{ .x = modal.x + pad + button_w + gap, .y = button_y, .w = button_w, .h = button_h }, .settings_save, 0);

    const layout = computeContentLayout(state, modal);
    queue_hit(state, layout.theme_omarchy, .settings_control, @intFromEnum(Control.theme_omarchy));
    queue_hit(state, layout.theme_default, .settings_control, @intFromEnum(Control.theme_default));
    queueStepperHits(state, layout.ui_font, .ui_font_dec, .ui_font_inc, queue_hit);
    queueStepperHits(state, layout.terminal_font, .terminal_font_dec, .terminal_font_inc, queue_hit);

    for (OPEN_CHOICES, 0..) |choice, index| {
        queue_hit(state, layout.open_rows[index], .settings_control, @intFromEnum(choice.control));
    }
}

fn queueStepperHits(
    state: *runtime.AppState,
    rect: palette.Rect,
    dec: Control,
    inc: Control,
    queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    const step_w = theme.scaledUi(34.0);
    const value_w = theme.scaledUi(72.0);
    queue_hit(state, .{ .x = rect.x + rect.w - value_w - step_w * 2.0 - theme.scaledUi(8.0), .y = rect.y, .w = step_w, .h = rect.h }, .settings_control, @intFromEnum(dec));
    queue_hit(state, .{ .x = rect.x + rect.w - step_w, .y = rect.y, .w = step_w, .h = rect.h }, .settings_control, @intFromEnum(inc));
}

/// Renders the settings modal over the workspace.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.show_settings_modal) return;

    const modal = layoutModal(width, height);
    const layout = computeContentLayout(state, modal);
    const dirty = state.isSettingsDraftDirty();
    drawModalChrome(state, width, height, modal);

    const pad = theme.scaledUi(18.0);
    const close_size = theme.scaledUi(28.0);
    const title_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + pad, .w = modal.w - pad * 2.0 - close_size - theme.scaledUi(8.0), .h = theme.scaledUi(24.0) };
    queueText(state, title_rect, "Settings", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    drawIconButton(state, .{ .x = modal.x + modal.w - pad - close_size, .y = modal.y + pad, .w = close_size, .h = close_size }, "x", state.settings_close_hovered);

    queueText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(44.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) }, "Edit app preferences. Saved to verde.json on Save and reloaded when the file changes externally.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.5), modal);

    if (dirty) {
        queueText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(78.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(16.0) }, "Unsaved changes", paletteColor(theme.COLOR_YELLOW), theme.scaledUi(12.0), modal);
    }

    var section_y = modal.y + theme.scaledUi(96.0) - theme.scaledUi(22.0);
    drawSectionHeader(state, modal, section_y, "Appearance");
    drawThemeSegment(state, layout.theme_omarchy, "Omarchy (auto)", state.settings_draft.theme_source == .omarchy, isControlHovered(state, .theme_omarchy), modal);
    drawThemeSegment(state, layout.theme_default, "Verde default", state.settings_draft.theme_source == .default, isControlHovered(state, .theme_default), modal);
    drawStepperRow(state, layout.ui_font, "UI font size", state.settings_draft.font_size, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE, .ui_font_dec, .ui_font_inc, modal);

    section_y = layout.ui_font.y + layout.ui_font.h + theme.scaledUi(18.0);
    drawSectionDivider(state, modal, section_y);
    section_y += theme.scaledUi(14.0);
    drawSectionHeader(state, modal, section_y, "Terminal");
    drawStepperRow(state, layout.terminal_font, "Terminal font size", state.settings_draft.terminal_font_size, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE, .terminal_font_dec, .terminal_font_inc, modal);

    var profile_buf: [64]u8 = undefined;
    const profile_line = std.fmt.bufPrint(&profile_buf, "Launch profiles: {d}  ·  edit terminal.profiles in verde.json", .{state.app_config.terminal_launch_profiles.len}) catch "Launch profiles configured in verde.json";
    queueText(state, .{ .x = modal.x + pad, .y = layout.terminal_font.y + layout.terminal_font.h + theme.scaledUi(10.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, profile_line, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.5), modal);

    section_y = layout.terminal_font.y + layout.terminal_font.h + theme.scaledUi(28.0);
    drawSectionDivider(state, modal, section_y);
    section_y += theme.scaledUi(14.0);
    drawSectionHeader(state, modal, section_y, "Workspace");
    queueText(state, .{ .x = modal.x + pad, .y = section_y + theme.scaledUi(22.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(16.0) }, "Default open action", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), modal);

    for (OPEN_CHOICES, 0..) |choice, index| {
        drawChoiceRow(state, layout.open_rows[index], choice.label, openActionSelected(state, choice.control), isControlHovered(state, choice.control), modal);
    }

    if (state.settings_draft.open_action == .custom) {
        var custom_buf: [96]u8 = undefined;
        const custom_label = if (state.app_config.default_open_action == .custom)
            std.fmt.bufPrint(&custom_buf, "{s} (custom)", .{state.app_config.default_open_action.custom.label}) catch "Custom action"
        else
            "Custom action";
        if (layout.custom_open_row) |custom_row| {
            drawChoiceRow(state, custom_row, custom_label, true, false, modal);
            queueText(state, .{ .x = modal.x + pad, .y = custom_row.y + custom_row.h + theme.scaledUi(2.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(16.0) }, "Custom actions are defined in verde.json.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), modal);
        }
    }

    if (app_config.resolveConfigPath(state.allocator)) |config_path| {
        defer state.allocator.free(config_path);
        queueText(state, .{ .x = modal.x + pad, .y = layout.footer_note_y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(16.0) }, config_path, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(10.5), modal);
    } else |_| {}

    const button_h = theme.scaledUi(34.0);
    const button_y = modal.y + modal.h - pad - button_h;
    const gap = theme.scaledUi(10.0);
    const button_w = (modal.w - pad * 2.0 - gap) * 0.5;
    drawButton(state, .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h }, "Cancel", theme.COLOR_PANEL_ALT);
    drawButton(state, .{ .x = modal.x + pad + button_w + gap, .y = button_y, .w = button_w, .h = button_h }, "Save", if (dirty) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_MUTED);
}

/// Updates settings-modal hover using hits from `refreshPaletteModalHits`.
pub fn updateHover(state: *runtime.AppState, x: f32, y: f32) void {
    if (!state.show_settings_modal) {
        if (state.settings_hover_control != null or state.settings_close_hovered) {
            state.settings_hover_control = null;
            state.settings_close_hovered = false;
            state.markDirty();
        }
        return;
    }

    var new_hover: ?u8 = null;
    var close_hovered = false;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (hit.action == .settings_close) {
            if (rectContains(hit.rect, x, y)) close_hovered = true;
            continue;
        }
        if (hit.action != .settings_control) continue;
        if (!rectContains(hit.rect, x, y)) continue;
        new_hover = @intCast(hit.index);
        break;
    }

    if (state.settings_hover_control == new_hover and state.settings_close_hovered == close_hovered) return;
    state.settings_hover_control = new_hover;
    state.settings_close_hovered = close_hovered;
    state.markDirty();
}

/// Applies a settings control interaction to the in-modal draft.
pub fn applyControl(state: *runtime.AppState, control_index: usize) void {
    const control: Control = @enumFromInt(control_index);
    switch (control) {
        .ui_font_dec => state.settings_draft.font_size = theme.clampf(state.settings_draft.font_size - 1.0, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE),
        .ui_font_inc => state.settings_draft.font_size = theme.clampf(state.settings_draft.font_size + 1.0, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE),
        .terminal_font_dec => state.settings_draft.terminal_font_size = theme.clampf(state.settings_draft.terminal_font_size - 1.0, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE),
        .terminal_font_inc => state.settings_draft.terminal_font_size = theme.clampf(state.settings_draft.terminal_font_size + 1.0, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE),
        .theme_omarchy => state.settings_draft.theme_source = .omarchy,
        .theme_default => state.settings_draft.theme_source = .default,
        .open_folder => state.settings_draft.open_action = .folder,
        .open_editor => state.settings_draft.open_action = .editor,
        .open_cursor => state.settings_draft.open_action = .cursor,
        .open_vscode => state.settings_draft.open_action = .vscode,
        .open_zed => state.settings_draft.open_action = .zed,
    }
    state.markDirty();
}

fn drawModalChrome(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect) void {
    queueRoundedRect(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.46 }, 0.0);
    queueRoundedRect(state, modal, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 248)), theme.scaledUi(16.0));
    queueBorder(state, modal, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(16.0), theme.scaledUi(1.0));
}

fn drawSectionHeader(state: *runtime.AppState, modal: palette.Rect, y: f32, label: []const u8) void {
    const pad = theme.scaledUi(18.0);
    queueText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), modal);
}

fn drawSectionDivider(state: *runtime.AppState, modal: palette.Rect, y: f32) void {
    const pad = theme.scaledUi(18.0);
    queueRoundedRect(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = 1.0 }, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 180)), 0.0);
}

fn drawIconButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, hovered: bool) void {
    const bg = if (hovered) theme.lighten(theme.COLOR_PANEL_MUTED, 0.08) else theme.withAlpha(theme.COLOR_PANEL_MUTED, 220);
    queueRoundedRect(state, rect, paletteColor(bg), theme.scaledUi(7.0));
    queueBorder(state, rect, paletteColor(theme.lighten(bg, 0.06)), theme.scaledUi(7.0), theme.scaledUi(1.0));
    const font_size = theme.scaledUi(14.0);
    queueText(state, .{
        .x = rect.x + (rect.w - font_size) * 0.5,
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = font_size,
        .h = font_size * 1.25,
    }, label, paletteColor(theme.COLOR_WHITE), font_size, rect);
}

fn drawButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, color: [4]f32) void {
    queueRoundedRect(state, rect, paletteColor(color), theme.scaledUi(7.0));
    queueBorder(state, rect, paletteColor(theme.lighten(color, 0.06)), theme.scaledUi(7.0), theme.scaledUi(1.0));
    const font_size = theme.scaledUi(14.0);
    queueText(state, .{
        .x = rect.x + theme.scaledUi(12.0),
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = rect.w - theme.scaledUi(24.0),
        .h = font_size * 1.25,
    }, label, paletteColor(theme.COLOR_WHITE), font_size, rect);
}

fn drawThemeSegment(state: *runtime.AppState, rect: palette.Rect, label: []const u8, selected: bool, hovered: bool, clip: palette.Rect) void {
    if (selected) {
        queueRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(7.0));
        queueBorder(state, rect, paletteColor(theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.04)), theme.scaledUi(7.0), theme.scaledUi(1.5));
    } else if (hovered) {
        queueRoundedRect(state, rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.10)), theme.scaledUi(7.0));
        queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(7.0), theme.scaledUi(1.0));
    } else {
        queueRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(7.0));
        queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(7.0), theme.scaledUi(1.0));
    }
    const color = if (selected or hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    queueText(state, .{ .x = rect.x, .y = rect.y + theme.scaledUi(8.0), .w = rect.w, .h = theme.scaledUi(20.0) }, label, paletteColor(color), theme.scaledUi(13.0), clip);
}

fn drawChoiceRow(state: *runtime.AppState, rect: palette.Rect, label: []const u8, selected: bool, hovered: bool, clip: palette.Rect) void {
    if (hovered and !selected) {
        queueRoundedRect(state, rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(6.0));
    }

    const marker = if (selected) "●" else "○";
    const marker_color = if (selected) theme.COLOR_SECONDARY_GREEN else theme.COLOR_TEXT_SUBTLE;
    queueText(state, .{ .x = rect.x + theme.scaledUi(4.0), .y = rect.y + theme.scaledUi(5.0), .w = theme.scaledUi(16.0), .h = theme.scaledUi(20.0) }, marker, paletteColor(marker_color), theme.scaledUi(13.0), clip);

    const color = if (selected or hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    queueText(state, .{ .x = rect.x + theme.scaledUi(24.0), .y = rect.y + theme.scaledUi(5.0), .w = rect.w - theme.scaledUi(28.0), .h = theme.scaledUi(20.0) }, label, paletteColor(color), theme.scaledUi(13.0), clip);
}

fn drawStepperRow(
    state: *runtime.AppState,
    rect: palette.Rect,
    label: []const u8,
    value: f32,
    min_value: f32,
    max_value: f32,
    dec: Control,
    inc: Control,
    clip: palette.Rect,
) void {
    const hovered = isControlHovered(state, dec) or isControlHovered(state, inc);
    queueRoundedRect(state, rect, paletteColor(if (hovered) theme.lighten(theme.COLOR_PANEL_ALT, 0.08) else theme.COLOR_PANEL_ALT), theme.scaledUi(7.0));
    queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(7.0), theme.scaledUi(1.0));
    queueText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = rect.y + theme.scaledUi(8.0), .w = rect.w * 0.55, .h = theme.scaledUi(20.0) }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.5), clip);

    var value_buf: [16]u8 = undefined;
    const value_text = std.fmt.bufPrint(&value_buf, "{d:.0}", .{value}) catch "?";

    const step_w = theme.scaledUi(34.0);
    const value_w = theme.scaledUi(72.0);
    const minus_rect: palette.Rect = .{ .x = rect.x + rect.w - value_w - step_w * 2.0 - theme.scaledUi(8.0), .y = rect.y, .w = step_w, .h = rect.h };
    const value_rect: palette.Rect = .{ .x = minus_rect.x + step_w, .y = rect.y, .w = value_w, .h = rect.h };
    const plus_rect: palette.Rect = .{ .x = value_rect.x + value_w, .y = rect.y, .w = step_w, .h = rect.h };

    const at_min = value <= min_value;
    const at_max = value >= max_value;
    drawButton(state, minus_rect, "-", if (at_min) theme.withAlpha(theme.COLOR_PANEL_MUTED, 140) else theme.COLOR_PANEL_MUTED);
    queueText(state, .{ .x = value_rect.x, .y = rect.y + theme.scaledUi(8.0), .w = value_rect.w, .h = theme.scaledUi(20.0) }, value_text, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.5), clip);
    drawButton(state, plus_rect, "+", if (at_max) theme.withAlpha(theme.COLOR_PANEL_MUTED, 140) else theme.COLOR_SECONDARY_GREEN);
}

fn queueRoundedRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch |err| {
        log.warn("failed to queue settings rounded rect: {s}", .{@errorName(err)});
    };
}

fn queueBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch |err| {
        log.warn("failed to queue settings border: {s}", .{@errorName(err)});
    };
}

fn queueText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = state.palette_frame_text_arena.allocator().dupe(u8, value) catch |err| {
        log.warn("failed to retain settings text: {s}", .{@errorName(err)});
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
        log.warn("failed to queue settings text: {s}", .{@errorName(err)});
    };
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}
