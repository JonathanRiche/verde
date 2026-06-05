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
    hooks_claude,
    hooks_codex,
    notifications_toggle,
};

const OpenChoice = struct {
    label: []const u8,
    control: Control,
};

const OPEN_CHOICES = [_]OpenChoice{
    .{ .label = "Folder", .control = .open_folder },
    .{ .label = "Editor", .control = .open_editor },
    .{ .label = "Cursor", .control = .open_cursor },
    .{ .label = "VS Code", .control = .open_vscode },
    .{ .label = "Zed", .control = .open_zed },
};

const Metrics = struct {
    modal_pad: f32,
    header_h: f32,
    footer_h: f32,
    card_pad: f32,
    card_gap: f32,
    title_h: f32,
    label_h: f32,
    row_h: f32,
    row_gap: f32,
    inner_gap: f32,
    step_w: f32,
    value_w: f32,

    fn init() Metrics {
        return .{
            .modal_pad = theme.scaledUi(20.0),
            .header_h = theme.scaledUi(58.0),
            .footer_h = theme.scaledUi(54.0),
            .card_pad = theme.scaledUi(16.0),
            .card_gap = theme.scaledUi(10.0),
            .title_h = theme.scaledUi(20.0),
            .label_h = theme.scaledUi(14.0),
            .row_h = theme.scaledUi(30.0),
            .row_gap = theme.scaledUi(10.0),
            .inner_gap = theme.scaledUi(6.0),
            .step_w = theme.scaledUi(26.0),
            .value_w = theme.scaledUi(34.0),
        };
    }

    fn stepperW(self: Metrics) f32 {
        return self.step_w * 2.0 + self.value_w;
    }

    fn labeledBlockH(self: Metrics, row_count: usize) f32 {
        return self.card_pad * 2.0 + self.title_h + self.row_gap + self.label_h + self.inner_gap +
            @as(f32, @floatFromInt(row_count)) * self.row_h +
            @as(f32, @floatFromInt(if (row_count > 0) row_count - 1 else 0)) * self.row_gap;
    }
};

const SettingsLayout = struct {
    modal: palette.Rect,
    header: palette.Rect,
    footer: palette.Rect,
    close: palette.Rect,
    cancel: palette.Rect,
    save: palette.Rect,
    appearance_card: palette.Rect,
    theme_omarchy: palette.Rect,
    theme_default: palette.Rect,
    ui_font_dec: palette.Rect,
    ui_font_inc: palette.Rect,
    terminal_card: palette.Rect,
    terminal_font_dec: palette.Rect,
    terminal_font_inc: palette.Rect,
    terminal_hint_y: f32,
    workspace_card: palette.Rect,
    open_cells: [OPEN_CHOICES.len]palette.Rect,
    custom_open: ?palette.Rect = null,
    integrations_card: palette.Rect,
    hooks_claude: palette.Rect,
    hooks_codex: palette.Rect,
    integrations_hint_y: f32,
    notifications_card: palette.Rect,
    notifications_toggle: palette.Rect,
    notifications_hint_y: f32,
};

const log = std.log.scoped(.native_ui_settings);

fn radiusSm() f32 {
    return theme.scaledUi(6.0);
}

fn radiusMd() f32 {
    return theme.scaledUi(8.0);
}

fn radiusLg() f32 {
    return theme.scaledUi(12.0);
}

fn textLabel() [4]f32 {
    return theme.COLOR_TEXT_MUTED;
}

fn textHint() [4]f32 {
    return theme.lighten(theme.COLOR_TEXT_SUBTLE, 0.18);
}

fn metrics() Metrics {
    return Metrics.init();
}

fn layoutModal(width: f32, height: f32, modal_h: f32) palette.Rect {
    const modal_w = theme.clampf(width * 0.36, theme.scaledUi(420.0), theme.scaledUi(480.0));
    const h = theme.clampf(modal_h, theme.scaledUi(480.0), height * 0.82);
    return .{
        .x = (width - modal_w) * 0.5,
        .y = (height - h) * 0.5,
        .w = modal_w,
        .h = h,
    };
}

fn stepperRects(card: palette.Rect, card_pad: f32, row_y: f32, m: Metrics) struct { dec: palette.Rect, inc: palette.Rect } {
    const inc: palette.Rect = .{
        .x = card.x + card.w - card_pad - m.step_w,
        .y = row_y,
        .w = m.step_w,
        .h = m.row_h,
    };
    const dec: palette.Rect = .{
        .x = inc.x - m.value_w - m.step_w,
        .y = row_y,
        .w = m.step_w,
        .h = m.row_h,
    };
    return .{ .dec = dec, .inc = inc };
}

fn computeLayout(state: *runtime.AppState, width: f32, height: f32) SettingsLayout {
    const m = metrics();

    const open_cols: usize = 2;
    const open_rows = (OPEN_CHOICES.len + open_cols - 1) / open_cols;
    const open_grid_h = @as(f32, @floatFromInt(open_rows)) * m.row_h + @as(f32, @floatFromInt(open_rows - 1)) * m.inner_gap;
    const custom_extra: f32 = if (state.settings_draft.open_action == .custom) m.row_h + m.inner_gap else 0.0;

    const appearance_h = m.labeledBlockH(2);
    const terminal_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.row_h + m.inner_gap + m.label_h;
    const workspace_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.label_h + m.inner_gap + open_grid_h + custom_extra;
    // Title, field label, two toggle rows (Claude + Codex), hint.
    const integrations_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.row_h + m.inner_gap + m.label_h;
    // Same shape as the integrations card: title, field label, one toggle row, hint.
    const notifications_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.label_h;

    const body_h = appearance_h + m.card_gap + terminal_h + m.card_gap + workspace_h + m.card_gap + integrations_h + m.card_gap + notifications_h;
    const modal_h = m.header_h + m.modal_pad + body_h + m.modal_pad + m.footer_h;
    const modal = layoutModal(width, height, modal_h);

    const header: palette.Rect = .{ .x = modal.x, .y = modal.y, .w = modal.w, .h = m.header_h };
    const footer: palette.Rect = .{ .x = modal.x, .y = modal.y + modal.h - m.footer_h, .w = modal.w, .h = m.footer_h };

    const close_size = theme.scaledUi(26.0);
    const close: palette.Rect = .{
        .x = modal.x + modal.w - m.modal_pad - close_size,
        .y = modal.y + (m.header_h - close_size) * 0.5,
        .w = close_size,
        .h = close_size,
    };

    const button_h = theme.scaledUi(30.0);
    const button_w = theme.scaledUi(84.0);
    const button_gap = theme.scaledUi(8.0);
    const save: palette.Rect = .{
        .x = footer.x + footer.w - m.modal_pad - button_w,
        .y = footer.y + (m.footer_h - button_h) * 0.5,
        .w = button_w,
        .h = button_h,
    };
    const cancel: palette.Rect = .{
        .x = save.x - button_gap - button_w,
        .y = save.y,
        .w = button_w,
        .h = button_h,
    };

    const content_x = modal.x + m.modal_pad;
    const content_w = modal.w - m.modal_pad * 2.0;
    var y = header.y + header.h + m.modal_pad;

    const appearance_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = appearance_h };
    const theme_row_y = appearance_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const segment_gap = m.inner_gap;
    const segment_w = (content_w - m.card_pad * 2.0 - segment_gap) * 0.5;
    const theme_x = appearance_card.x + m.card_pad;
    const theme_omarchy: palette.Rect = .{ .x = theme_x, .y = theme_row_y, .w = segment_w, .h = m.row_h };
    const theme_default: palette.Rect = .{ .x = theme_x + segment_w + segment_gap, .y = theme_row_y, .w = segment_w, .h = m.row_h };
    const ui_font_y = theme_row_y + m.row_h + m.row_gap;
    const ui_stepper = stepperRects(appearance_card, m.card_pad, ui_font_y, m);

    y += appearance_h + m.card_gap;

    const terminal_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = terminal_h };
    const terminal_font_y = terminal_card.y + m.card_pad + m.title_h + m.row_gap;
    const terminal_stepper = stepperRects(terminal_card, m.card_pad, terminal_font_y, m);
    const terminal_hint_y = terminal_font_y + m.row_h + m.inner_gap;

    y += terminal_h + m.card_gap;

    const workspace_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = workspace_h };
    const open_y = workspace_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const open_cell_w = (content_w - m.card_pad * 2.0 - m.inner_gap) * 0.5;
    const open_x = workspace_card.x + m.card_pad;
    var open_cells: [OPEN_CHOICES.len]palette.Rect = undefined;
    for (OPEN_CHOICES, 0..) |_, index| {
        const col = index % open_cols;
        const row = index / open_cols;
        open_cells[index] = .{
            .x = open_x + @as(f32, @floatFromInt(col)) * (open_cell_w + m.inner_gap),
            .y = open_y + @as(f32, @floatFromInt(row)) * (m.row_h + m.inner_gap),
            .w = open_cell_w,
            .h = m.row_h,
        };
    }

    var custom_open: ?palette.Rect = null;
    if (state.settings_draft.open_action == .custom) {
        custom_open = .{
            .x = open_x,
            .y = open_y + open_grid_h + m.inner_gap,
            .w = content_w - m.card_pad * 2.0,
            .h = m.row_h,
        };
    }

    y += workspace_h + m.card_gap;

    const integrations_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = integrations_h };
    const hooks_claude_y = integrations_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const hooks_claude: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_claude_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_codex_y = hooks_claude_y + m.row_h + m.inner_gap;
    const hooks_codex: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_codex_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const integrations_hint_y = hooks_codex_y + m.row_h + m.inner_gap;

    y += integrations_h + m.card_gap;

    const notifications_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = notifications_h };
    const notifications_toggle_y = notifications_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const notifications_toggle: palette.Rect = .{ .x = notifications_card.x + m.card_pad, .y = notifications_toggle_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const notifications_hint_y = notifications_toggle_y + m.row_h + m.inner_gap;

    return .{
        .modal = modal,
        .header = header,
        .footer = footer,
        .close = close,
        .cancel = cancel,
        .save = save,
        .appearance_card = appearance_card,
        .theme_omarchy = theme_omarchy,
        .theme_default = theme_default,
        .ui_font_dec = ui_stepper.dec,
        .ui_font_inc = ui_stepper.inc,
        .terminal_card = terminal_card,
        .terminal_font_dec = terminal_stepper.dec,
        .terminal_font_inc = terminal_stepper.inc,
        .terminal_hint_y = terminal_hint_y,
        .workspace_card = workspace_card,
        .open_cells = open_cells,
        .custom_open = custom_open,
        .integrations_card = integrations_card,
        .hooks_claude = hooks_claude,
        .hooks_codex = hooks_codex,
        .integrations_hint_y = integrations_hint_y,
        .notifications_card = notifications_card,
        .notifications_toggle = notifications_toggle,
        .notifications_hint_y = notifications_hint_y,
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

    const layout = computeLayout(state, width, height);
    queue_hit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .modal_dismiss, 0);
    queue_hit(state, layout.modal, .modal_block, 0);
    queue_hit(state, layout.close, .settings_close, 0);
    queue_hit(state, layout.cancel, .settings_cancel, 0);
    queue_hit(state, layout.save, .settings_save, 0);
    queue_hit(state, layout.theme_omarchy, .settings_control, @intFromEnum(Control.theme_omarchy));
    queue_hit(state, layout.theme_default, .settings_control, @intFromEnum(Control.theme_default));
    queue_hit(state, layout.ui_font_dec, .settings_control, @intFromEnum(Control.ui_font_dec));
    queue_hit(state, layout.ui_font_inc, .settings_control, @intFromEnum(Control.ui_font_inc));
    queue_hit(state, layout.terminal_font_dec, .settings_control, @intFromEnum(Control.terminal_font_dec));
    queue_hit(state, layout.terminal_font_inc, .settings_control, @intFromEnum(Control.terminal_font_inc));
    for (OPEN_CHOICES, 0..) |choice, index| {
        queue_hit(state, layout.open_cells[index], .settings_control, @intFromEnum(choice.control));
    }
    queue_hit(state, layout.hooks_claude, .settings_control, @intFromEnum(Control.hooks_claude));
    queue_hit(state, layout.hooks_codex, .settings_control, @intFromEnum(Control.hooks_codex));
    queue_hit(state, layout.notifications_toggle, .settings_control, @intFromEnum(Control.notifications_toggle));
}

/// Renders the settings modal over the workspace.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.show_settings_modal) return;

    const m = metrics();
    const layout = computeLayout(state, width, height);
    const dirty = state.isSettingsDraftDirty();
    drawModalChrome(state, width, height, layout.modal);

    drawHeaderBar(state, layout, dirty);
    drawCard(state, layout.appearance_card);
    drawCard(state, layout.terminal_card);
    drawCard(state, layout.workspace_card);
    drawCard(state, layout.integrations_card);
    drawCard(state, layout.notifications_card);

    // Appearance
    drawCardTitle(state, layout.appearance_card, "Appearance", layout.modal);
    drawFieldLabel(state, layout.appearance_card, m, "Theme");
    drawToggleCell(state, layout.theme_omarchy, "Omarchy", state.settings_draft.theme_source == .omarchy, isControlHovered(state, .theme_omarchy), layout.modal);
    drawToggleCell(state, layout.theme_default, "Verde", state.settings_draft.theme_source == .default, isControlHovered(state, .theme_default), layout.modal);
    drawStepperRow(state, layout.appearance_card, m, layout.ui_font_dec.y, "UI font size", state.settings_draft.font_size, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE, .ui_font_dec, .ui_font_inc, layout.ui_font_dec, layout.ui_font_inc, layout.modal);

    // Terminal
    drawCardTitle(state, layout.terminal_card, "Terminal", layout.modal);
    drawStepperRow(state, layout.terminal_card, m, layout.terminal_font_dec.y, "Font size", state.settings_draft.terminal_font_size, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE, .terminal_font_dec, .terminal_font_inc, layout.terminal_font_dec, layout.terminal_font_inc, layout.modal);
    var profile_buf: [56]u8 = undefined;
    const profile_line = std.fmt.bufPrint(&profile_buf, "{d} launch profile(s) · edit in verde.json", .{state.app_config.terminal_launch_profiles.len}) catch "Edit terminal.profiles in verde.json";
    queueText(state, .{
        .x = layout.terminal_card.x + m.card_pad,
        .y = layout.terminal_hint_y,
        .w = layout.terminal_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, profile_line, paletteColor(textHint()), theme.scaledUi(11.5), layout.modal);

    // Workspace
    drawCardTitle(state, layout.workspace_card, "Workspace", layout.modal);
    drawFieldLabel(state, layout.workspace_card, m, "Default open action");
    for (OPEN_CHOICES, 0..) |choice, index| {
        drawToggleCell(state, layout.open_cells[index], choice.label, openActionSelected(state, choice.control), isControlHovered(state, choice.control), layout.modal);
    }
    if (state.settings_draft.open_action == .custom) {
        if (layout.custom_open) |custom_row| {
            var custom_buf: [80]u8 = undefined;
            const custom_label = if (state.app_config.default_open_action == .custom)
                std.fmt.bufPrint(&custom_buf, "{s} (custom)", .{state.app_config.default_open_action.custom.label}) catch "Custom"
            else
                "Custom action";
            drawToggleCell(state, custom_row, custom_label, true, false, layout.modal);
        }
    }

    // Agent integrations
    drawCardTitle(state, layout.integrations_card, "Agent integrations", layout.modal);
    drawFieldLabel(state, layout.integrations_card, m, "Status pip hooks (global)");
    const claude_on = state.settings_hook_claude_installed;
    drawToggleCell(state, layout.hooks_claude, if (claude_on) "Claude  ·  Enabled" else "Claude  ·  Disabled", claude_on, isControlHovered(state, .hooks_claude), layout.modal);
    const codex_on = state.settings_hook_codex_installed;
    drawToggleCell(state, layout.hooks_codex, if (codex_on) "Codex  ·  Enabled" else "Codex  ·  Disabled", codex_on, isControlHovered(state, .hooks_codex), layout.modal);
    queueText(state, .{
        .x = layout.integrations_card.x + m.card_pad,
        .y = layout.integrations_hint_y,
        .w = layout.integrations_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Writes hooks to ~/.claude & ~/.codex · merges, no-op outside Verde panes", paletteColor(textHint()), theme.scaledUi(11.5), layout.modal);

    // Notifications
    drawCardTitle(state, layout.notifications_card, "Notifications", layout.modal);
    drawFieldLabel(state, layout.notifications_card, m, "Desktop alerts");
    const notifications_on = state.settings_draft.notifications_enabled;
    drawToggleCell(state, layout.notifications_toggle, if (notifications_on) "On agent completion  ·  Enabled" else "On agent completion  ·  Disabled", notifications_on, isControlHovered(state, .notifications_toggle), layout.modal);
    queueText(state, .{
        .x = layout.notifications_card.x + m.card_pad,
        .y = layout.notifications_hint_y,
        .w = layout.notifications_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "System notification when an agent finishes · macOS & Linux", paletteColor(textHint()), theme.scaledUi(11.5), layout.modal);

    drawFooterBar(state, layout, dirty);
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
        // Acts immediately (filesystem side effect), independent of Save/Cancel.
        .hooks_claude => {
            state.toggleClaudeGlobalHooks();
            return;
        },
        .hooks_codex => {
            state.toggleCodexGlobalHooks();
            return;
        },
        // Draft toggle: persisted to verde.json on Save, like the other fields.
        .notifications_toggle => state.settings_draft.notifications_enabled = !state.settings_draft.notifications_enabled,
    }
    state.markDirty();
}

fn drawModalChrome(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect) void {
    queueRoundedRect(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.68 }, 0.0);
    queueRoundedRect(state, modal, paletteColor(theme.COLOR_PANEL), radiusLg());
    queueBorder(state, modal, paletteColor(theme.withAlpha(theme.borderMuted(), 110)), radiusLg(), theme.scaledUi(1.0));
}

fn drawHeaderBar(state: *runtime.AppState, layout: SettingsLayout, dirty: bool) void {
    const m = metrics();
    queueRoundedRect(state, layout.header, paletteColor(theme.lighten(theme.COLOR_PANEL, 0.02)), 0.0);
    drawHairline(state, layout.header.x, layout.header.y + layout.header.h - 1.0, layout.header.w);

    queueText(state, .{
        .x = layout.modal.x + m.modal_pad,
        .y = layout.header.y + theme.scaledUi(14.0),
        .w = theme.scaledUi(140.0),
        .h = theme.scaledUi(20.0),
    }, "Settings", paletteColor(theme.COLOR_WHITE), theme.scaledUi(16.0), layout.modal);

    queueText(state, .{
        .x = layout.modal.x + m.modal_pad,
        .y = layout.header.y + theme.scaledUi(34.0),
        .w = layout.close.x - layout.modal.x - m.modal_pad - theme.scaledUi(8.0),
        .h = theme.scaledUi(16.0),
    }, "Stored in verde.json", paletteColor(textLabel()), theme.scaledUi(12.0), layout.modal);

    if (dirty) {
        const pill_w = theme.scaledUi(72.0);
        const pill_h = theme.scaledUi(18.0);
        const pill: palette.Rect = .{
            .x = layout.close.x - pill_w - theme.scaledUi(10.0),
            .y = layout.header.y + theme.scaledUi(16.0),
            .w = pill_w,
            .h = pill_h,
        };
        queueRoundedRect(state, pill, paletteColor(theme.withAlpha(theme.COLOR_YELLOW, 36)), radiusSm());
        queueCenteredText(state, pill, "Unsaved", paletteColor(theme.COLOR_YELLOW), theme.scaledUi(10.5), layout.modal);
    }

    drawIconButton(state, layout.close, "×", state.settings_close_hovered);
}

fn drawFooterBar(state: *runtime.AppState, layout: SettingsLayout, dirty: bool) void {
    const m = metrics();
    queueRoundedRect(state, layout.footer, paletteColor(theme.darken(theme.COLOR_PANEL, 0.03)), 0.0);
    drawHairline(state, layout.footer.x, layout.footer.y, layout.footer.w);

    if (app_config.resolveConfigPath(state.allocator)) |config_path| {
        defer state.allocator.free(config_path);
        queueText(state, .{
            .x = layout.footer.x + m.modal_pad,
            .y = layout.footer.y + theme.scaledUi(19.0),
            .w = layout.cancel.x - layout.footer.x - m.modal_pad - theme.scaledUi(10.0),
            .h = theme.scaledUi(16.0),
        }, config_path, paletteColor(textHint()), theme.scaledUi(11.0), layout.modal);
    } else |_| {}

    drawFooterButton(state, layout.cancel, "Cancel", .secondary);
    drawFooterButton(state, layout.save, "Save", if (dirty) .primary else .secondary);
}

const FooterStyle = enum { primary, secondary };

fn drawCard(state: *runtime.AppState, rect: palette.Rect) void {
    queueRoundedRect(state, rect, paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.03)), radiusMd());
}

fn drawCardTitle(state: *runtime.AppState, card: palette.Rect, title: []const u8, clip: palette.Rect) void {
    const m = metrics();
    queueText(state, .{
        .x = card.x + m.card_pad,
        .y = card.y + m.card_pad,
        .w = card.w - m.card_pad * 2.0,
        .h = m.title_h,
    }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), clip);
}

fn drawFieldLabel(state: *runtime.AppState, card: palette.Rect, m: Metrics, label: []const u8) void {
    queueText(state, .{
        .x = card.x + m.card_pad,
        .y = card.y + m.card_pad + m.title_h + m.row_gap,
        .w = card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, label, paletteColor(textLabel()), theme.scaledUi(12.0), card);
}

fn drawToggleCell(state: *runtime.AppState, rect: palette.Rect, label: []const u8, selected: bool, hovered: bool, clip: palette.Rect) void {
    const bg = if (selected)
        theme.withAlpha(theme.COLOR_GREEN, 44)
    else if (hovered)
        theme.lighten(theme.COLOR_PANEL_MUTED, 0.06)
    else
        theme.lighten(theme.COLOR_PANEL_MUTED, 0.02);
    queueRoundedRect(state, rect, paletteColor(bg), radiusSm());

    const dot_size = theme.scaledUi(7.0);
    const dot_x = rect.x + theme.scaledUi(9.0);
    const dot_y = rect.y + (rect.h - dot_size) * 0.5;
    const dot_color = if (selected) theme.COLOR_GREEN else theme.withAlpha(theme.COLOR_TEXT_MUTED, 180);
    queueRoundedRect(state, .{ .x = dot_x, .y = dot_y, .w = dot_size, .h = dot_size }, paletteColor(dot_color), theme.scaledUi(3.5));

    const text_color = if (selected or hovered) theme.COLOR_WHITE else textLabel();
    queueText(state, .{
        .x = rect.x + theme.scaledUi(22.0),
        .y = rect.y + (rect.h - theme.scaledUi(15.0)) * 0.5,
        .w = rect.w - theme.scaledUi(26.0),
        .h = theme.scaledUi(15.0),
    }, label, paletteColor(text_color), theme.scaledUi(12.5), clip);
}

fn drawStepperRow(
    state: *runtime.AppState,
    card: palette.Rect,
    m: Metrics,
    row_y: f32,
    label: []const u8,
    value: f32,
    min_value: f32,
    max_value: f32,
    dec_control: Control,
    inc_control: Control,
    dec_rect: palette.Rect,
    inc_rect: palette.Rect,
    clip: palette.Rect,
) void {
    queueText(state, .{
        .x = card.x + m.card_pad,
        .y = row_y + (m.row_h - theme.scaledUi(15.0)) * 0.5,
        .w = card.w * 0.5,
        .h = theme.scaledUi(15.0),
    }, label, paletteColor(textLabel()), theme.scaledUi(13.0), clip);

    const pill_x = dec_rect.x;
    const pill: palette.Rect = .{ .x = pill_x, .y = row_y, .w = m.stepperW(), .h = m.row_h };
    queueRoundedRect(state, pill, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 120)), radiusSm());

    var value_buf: [8]u8 = undefined;
    const value_text = std.fmt.bufPrint(&value_buf, "{d:.0}", .{value}) catch "?";
    const value_rect: palette.Rect = .{ .x = dec_rect.x + m.step_w, .y = row_y, .w = m.value_w, .h = m.row_h };
    queueRoundedRect(state, .{ .x = dec_rect.x + m.step_w - 0.5, .y = row_y + theme.scaledUi(6.0), .w = 1.0, .h = m.row_h - theme.scaledUi(12.0) }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 24)), 0.0);
    queueRoundedRect(state, .{ .x = inc_rect.x - 0.5, .y = row_y + theme.scaledUi(6.0), .w = 1.0, .h = m.row_h - theme.scaledUi(12.0) }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 24)), 0.0);
    queueCenteredText(state, value_rect, value_text, paletteColor(theme.COLOR_WHITE), theme.scaledUi(12.5), clip);

    const at_min = value <= min_value;
    const at_max = value >= max_value;
    drawStepButton(state, dec_rect, "−", !at_min, isControlHovered(state, dec_control));
    drawStepButton(state, inc_rect, "+", !at_max, isControlHovered(state, inc_control));
}

fn drawStepButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, enabled: bool, hovered: bool) void {
    if (hovered and enabled) {
        queueRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 140)), theme.scaledUi(5.0));
    }
    const text_color = if (enabled) theme.COLOR_WHITE else textHint();
    queueCenteredText(state, rect, label, paletteColor(text_color), theme.scaledUi(14.0), rect);
}

fn drawFooterButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, style: FooterStyle) void {
    const bg: [4]f32 = switch (style) {
        .primary => theme.COLOR_GREEN,
        .secondary => theme.COLOR_PANEL_MUTED,
    };
    const text_color: [4]f32 = switch (style) {
        .primary => theme.COLOR_WHITE,
        .secondary => theme.COLOR_WHITE,
    };
    queueRoundedRect(state, rect, paletteColor(bg), radiusMd());
    queueCenteredText(state, rect, label, paletteColor(text_color), theme.scaledUi(13.0), rect);
}

fn drawIconButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, hovered: bool) void {
    if (hovered) {
        queueRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 140)), radiusSm());
    }
    queueCenteredText(state, rect, label, paletteColor(if (hovered) theme.COLOR_WHITE else textLabel()), theme.scaledUi(17.0), rect);
}

fn drawHairline(state: *runtime.AppState, x: f32, y: f32, w: f32) void {
    if (w <= 0.0) return;
    queueRoundedRect(state, .{ .x = x, .y = y, .w = w, .h = 1.0 }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 18)), 0.0);
}

fn queueCenteredText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const estimated_w = @as(f32, @floatFromInt(value.len)) * font_size * 0.52;
    queueText(state, .{
        .x = rect.x + @max((rect.w - estimated_w) * 0.5, theme.scaledUi(2.0)),
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = @min(estimated_w + theme.scaledUi(4.0), rect.w),
        .h = font_size * 1.25,
    }, value, color, font_size, clip);
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
