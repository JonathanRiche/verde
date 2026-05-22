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

const Row = struct {
    label: []const u8,
    control: ?Control = null,
    selected: bool = false,
    disabled: bool = false,
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

fn buildRows(state: *runtime.AppState, rows: *[15]Row, count: *usize) void {
    count.* = 0;
    const draft = state.settings_draft;

    rows[count.*] = .{ .label = "APPEARANCE", .disabled = true };
    count.* += 1;
    rows[count.*] = .{
        .label = "Theme: Omarchy (auto)",
        .control = .theme_omarchy,
        .selected = draft.theme_source == .omarchy,
    };
    count.* += 1;
    rows[count.*] = .{
        .label = "Theme: Verde default",
        .control = .theme_default,
        .selected = draft.theme_source == .default,
    };
    count.* += 1;
    rows[count.*] = .{ .label = "UI font size", .control = .ui_font_dec };
    count.* += 1;

    rows[count.*] = .{ .label = "TERMINAL", .disabled = true };
    count.* += 1;
    rows[count.*] = .{ .label = "Terminal font size", .control = .terminal_font_dec };
    count.* += 1;

    rows[count.*] = .{ .label = "WORKSPACE", .disabled = true };
    count.* += 1;
    rows[count.*] = .{
        .label = "Open with: Folder",
        .control = .open_folder,
        .selected = draft.open_action == .folder,
    };
    count.* += 1;
    rows[count.*] = .{
        .label = "Open with: Configured editor",
        .control = .open_editor,
        .selected = draft.open_action == .editor,
    };
    count.* += 1;
    rows[count.*] = .{
        .label = "Open with: Cursor",
        .control = .open_cursor,
        .selected = draft.open_action == .cursor,
    };
    count.* += 1;
    rows[count.*] = .{
        .label = "Open with: VS Code",
        .control = .open_vscode,
        .selected = draft.open_action == .vscode,
    };
    count.* += 1;
    rows[count.*] = .{
        .label = "Open with: Zed",
        .control = .open_zed,
        .selected = draft.open_action == .zed,
    };
    count.* += 1;

    if (draft.open_action == .custom) {
        var custom_buf: [96]u8 = undefined;
        const custom_label = if (state.app_config.default_open_action == .custom)
            std.fmt.bufPrint(&custom_buf, "Open with: {s} (custom)", .{state.app_config.default_open_action.custom.label}) catch "Open with: Custom action"
        else
            "Open with: Custom action";
        rows[count.*] = .{ .label = custom_label, .selected = true, .disabled = true };
        count.* += 1;
    }
}

fn advanceRowY(y: *f32, row: Row) void {
    if (row.disabled and row.control == null) {
        y.* += theme.scaledUi(26.0);
        return;
    }
    y.* += theme.scaledUi(34.0) + if (row.control == .ui_font_dec or row.control == .terminal_font_dec)
        theme.scaledUi(14.0)
    else
        theme.scaledUi(4.0);
}

fn forEachInteractiveRow(
    modal: palette.Rect,
    rows: []const Row,
    ctx: *anyopaque,
    callback: *const fn (*anyopaque, Row, palette.Rect, usize) void,
) void {
    var row_y = modal.y + theme.scaledUi(92.0);
    var index: usize = 0;
    while (index < rows.len) : (index += 1) {
        const row = rows[index];
        if (row.disabled and row.control == null) {
            advanceRowY(&row_y, row);
            continue;
        }
        if (row.control == null) {
            advanceRowY(&row_y, row);
            continue;
        }
        const rect: palette.Rect = .{
            .x = modal.x + theme.scaledUi(18.0),
            .y = row_y,
            .w = modal.w - theme.scaledUi(36.0),
            .h = theme.scaledUi(34.0),
        };
        callback(ctx, row, rect, index);
        advanceRowY(&row_y, row);
    }
}

const HitCtx = struct {
    state: *runtime.AppState,
    queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
};

fn queueRowHit(ctx: *anyopaque, row: Row, rect: palette.Rect, index: usize) void {
    const hit_ctx: *HitCtx = @ptrCast(@alignCast(ctx));
    _ = index;
    const control = row.control orelse return;
    if (control == .ui_font_dec or control == .terminal_font_dec) {
        const step_w = theme.scaledUi(34.0);
        const value_w = theme.scaledUi(72.0);
        hit_ctx.queue_hit(hit_ctx.state, .{ .x = rect.x + rect.w - value_w - step_w * 2.0 - theme.scaledUi(8.0), .y = rect.y, .w = step_w, .h = rect.h }, .settings_control, @intFromEnum(control));
        hit_ctx.queue_hit(hit_ctx.state, .{ .x = rect.x + rect.w - step_w, .y = rect.y, .w = step_w, .h = rect.h }, .settings_control, @intFromEnum(switch (control) {
            .ui_font_dec => .ui_font_inc,
            .terminal_font_dec => .terminal_font_inc,
            else => control,
        }));
        return;
    }
    hit_ctx.queue_hit(hit_ctx.state, rect, .settings_control, @intFromEnum(control));
}

/// Registers palette hit targets for the settings modal.
pub fn registerHits(state: *runtime.AppState, width: f32, height: f32, queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void) void {
    if (!state.show_settings_modal) return;

    const modal = layoutModal(width, height);
    queue_hit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .modal_dismiss, 0);
    queue_hit(state, modal, .modal_block, 0);

    const pad = theme.scaledUi(18.0);
    const button_h = theme.scaledUi(34.0);
    const button_y = modal.y + modal.h - pad - button_h;
    const gap = theme.scaledUi(10.0);
    const button_w = (modal.w - pad * 2.0 - gap) * 0.5;
    queue_hit(state, .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h }, .settings_cancel, 0);
    queue_hit(state, .{ .x = modal.x + pad + button_w + gap, .y = button_y, .w = button_w, .h = button_h }, .settings_save, 0);

    var rows: [15]Row = undefined;
    var row_count: usize = 0;
    buildRows(state, &rows, &row_count);
    var hit_ctx = HitCtx{ .state = state, .queue_hit = queue_hit };
    forEachInteractiveRow(modal, rows[0..row_count], &hit_ctx, queueRowHit);
}

/// Renders the settings modal over the workspace.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.show_settings_modal) return;

    const modal = layoutModal(width, height);
    drawModalChrome(state, width, height, modal);

    const pad = theme.scaledUi(18.0);
    queueText(state, .{ .x = modal.x + pad, .y = modal.y + pad, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "Settings", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    queueText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(44.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(36.0) }, "Changes are saved to verde.json and picked up automatically when the file changes.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);

    if (app_config.resolveConfigPath(state.allocator)) |config_path| {
        defer state.allocator.free(config_path);
        queueText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(72.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(16.0) }, config_path, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.5), modal);
    } else |_| {}

    var rows: [15]Row = undefined;
    var row_count: usize = 0;
    buildRows(state, &rows, &row_count);

    var row_y = modal.y + theme.scaledUi(92.0);
    var index: usize = 0;
    while (index < row_count) : (index += 1) {
        const row = rows[index];
        const rect: palette.Rect = .{
            .x = modal.x + pad,
            .y = row_y,
            .w = modal.w - pad * 2.0,
            .h = theme.scaledUi(34.0),
        };
        if (row.disabled and row.control == null) {
            queueText(state, rect, row.label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), modal);
            advanceRowY(&row_y, row);
            continue;
        }
        const control = row.control orelse {
            advanceRowY(&row_y, row);
            continue;
        };
        const hovered = state.settings_hover_index != null and state.settings_hover_index.? == index;
        if (control == .ui_font_dec or control == .terminal_font_dec) {
            var value_buf: [16]u8 = undefined;
            const value = std.fmt.bufPrint(&value_buf, "{d:.0}", .{
                if (control == .ui_font_dec) state.settings_draft.font_size else state.settings_draft.terminal_font_size,
            }) catch "?";
            drawStepperRow(state, rect, if (control == .ui_font_dec) "UI font size" else "Terminal font size", value, hovered, modal);
            advanceRowY(&row_y, row);
            continue;
        }
        drawChoiceRow(state, rect, row.label, row.selected, hovered, modal);
        advanceRowY(&row_y, row);
    }

    var profile_buf: [48]u8 = undefined;
    const profile_line = std.fmt.bufPrint(&profile_buf, "Terminal launch profiles: {d}", .{state.app_config.terminal_launch_profiles.len}) catch "Terminal launch profiles";
    queueText(state, .{ .x = modal.x + pad, .y = modal.y + modal.h - pad - theme.scaledUi(86.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, profile_line, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.5), modal);

    const button_h = theme.scaledUi(34.0);
    const button_y = modal.y + modal.h - pad - button_h;
    const gap = theme.scaledUi(10.0);
    const button_w = (modal.w - pad * 2.0 - gap) * 0.5;
    drawButton(state, .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h }, "Cancel", theme.COLOR_PANEL_ALT);
    drawButton(state, .{ .x = modal.x + pad + button_w + gap, .y = button_y, .w = button_w, .h = button_h }, "Save", theme.COLOR_SECONDARY_GREEN);
}

/// Updates settings-modal hover using hits from `refreshPaletteModalHits`.
pub fn updateHover(state: *runtime.AppState, x: f32, y: f32) void {
    if (!state.show_settings_modal) {
        if (state.settings_hover_index != null) {
            state.settings_hover_index = null;
            state.markDirty();
        }
        return;
    }

    var new_hover: ?usize = null;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (hit.action != .settings_control) continue;
        if (!rectContains(hit.rect, x, y)) continue;
        new_hover = controlRowIndex(state, @enumFromInt(hit.index));
        break;
    }

    if (state.settings_hover_index == new_hover) return;
    state.settings_hover_index = new_hover;
    state.markDirty();
}

fn controlRowIndex(state: *runtime.AppState, control: Control) ?usize {
    var rows: [15]Row = undefined;
    var row_count: usize = 0;
    buildRows(state, &rows, &row_count);
    var index: usize = 0;
    while (index < row_count) : (index += 1) {
        const row = rows[index];
        if (row.control) |row_control| {
            if (row_control == control or
                (row_control == .ui_font_dec and control == .ui_font_inc) or
                (row_control == .terminal_font_dec and control == .terminal_font_inc))
            {
                return index;
            }
        }
    }
    return null;
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

fn drawChoiceRow(state: *runtime.AppState, rect: palette.Rect, label: []const u8, selected: bool, hovered: bool, clip: palette.Rect) void {
    if (selected) {
        queueRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(7.0));
    } else if (hovered) {
        queueRoundedRect(state, rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.10)), theme.scaledUi(7.0));
    } else {
        queueRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(7.0));
        queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(7.0), theme.scaledUi(1.0));
    }
    const color = if (selected or hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    queueText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = rect.y + theme.scaledUi(8.0), .w = rect.w - theme.scaledUi(24.0), .h = theme.scaledUi(20.0) }, label, paletteColor(color), theme.scaledUi(13.5), clip);
}

fn drawStepperRow(state: *runtime.AppState, rect: palette.Rect, label: []const u8, value: []const u8, hovered: bool, clip: palette.Rect) void {
    queueRoundedRect(state, rect, paletteColor(if (hovered) theme.lighten(theme.COLOR_PANEL_ALT, 0.08) else theme.COLOR_PANEL_ALT), theme.scaledUi(7.0));
    queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(7.0), theme.scaledUi(1.0));
    queueText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = rect.y + theme.scaledUi(8.0), .w = rect.w * 0.55, .h = theme.scaledUi(20.0) }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.5), clip);

    const step_w = theme.scaledUi(34.0);
    const value_w = theme.scaledUi(72.0);
    const minus_rect: palette.Rect = .{ .x = rect.x + rect.w - value_w - step_w * 2.0 - theme.scaledUi(8.0), .y = rect.y, .w = step_w, .h = rect.h };
    const value_rect: palette.Rect = .{ .x = minus_rect.x + step_w, .y = rect.y, .w = value_w, .h = rect.h };
    const plus_rect: palette.Rect = .{ .x = value_rect.x + value_w, .y = rect.y, .w = step_w, .h = rect.h };
    drawButton(state, minus_rect, "-", theme.COLOR_PANEL_MUTED);
    queueText(state, .{ .x = value_rect.x, .y = rect.y + theme.scaledUi(8.0), .w = value_rect.w, .h = theme.scaledUi(20.0) }, value, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.5), clip);
    drawButton(state, plus_rect, "+", theme.COLOR_SECONDARY_GREEN);
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
