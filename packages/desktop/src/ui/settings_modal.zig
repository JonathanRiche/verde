//! Settings modal for viewing and editing `verde.json` app config.

const std = @import("std");
const build_options = @import("build_options");
const palette = @import("palette");
const sdl = @import("zsdl3");
const app_config = @import("../app/config.zig");
const updater = @import("../app/updater.zig");
const theme = @import("theme.zig");
const runtime = @import("runtime.zig");
const text_measure = @import("text_measure.zig");

pub const Control = enum(u8) {
    ui_font_dec,
    ui_font_inc,
    terminal_font_dec,
    terminal_font_inc,
    workspace_pane_gap_dec,
    workspace_pane_gap_inc,
    workspace_panes_per_view_dec,
    workspace_panes_per_view_inc,
    workspace_scroll_mode_automatic,
    workspace_scroll_mode_always,
    workspace_scroll_mode_disabled,
    workspace_scroll_threshold_dec,
    workspace_scroll_threshold_inc,
    workspace_scroll_horizontal,
    workspace_scroll_vertical,
    theme_dropdown,
    tool_groups_collapsed,
    tool_groups_expanded,
    tool_groups_remember_last,
    diff_layout_stacked,
    diff_layout_split,
    automatic_chat_titles,
    chat_title_provider_dropdown,
    chat_title_model_dropdown,
    new_chat_new_pane,
    new_chat_replace_pane,
    open_folder,
    open_editor,
    open_cursor,
    open_vscode,
    open_zed,
    file_links_neovim_pane,
    links_verde_browser,
    links_system_browser,
    browser_fast_scrolling,
    mcp_tools,
    hooks_claude,
    hooks_codex,
    hooks_cursor,
    hooks_grok,
    hooks_amp,
    updates_check,
    updates_download,
    updates_automatic,
    updates_notes_toggle,
    updates_release_page,
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

const THEME_MENU_MAX_ROWS: usize = 6;
const TITLE_MENU_MAX_ROWS: usize = 6;
const NF_COD_CHEVRON_DOWN = "\u{EAB4}";
const NF_COD_CHEVRON_UP = "\u{EAB7}";

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
            .modal_pad = theme.scaledUi(24.0),
            .header_h = theme.scaledUi(64.0),
            .footer_h = theme.scaledUi(60.0),
            .card_pad = theme.scaledUi(18.0),
            .card_gap = theme.scaledUi(14.0),
            .title_h = theme.scaledUi(22.0),
            .label_h = theme.scaledUi(16.0),
            .row_h = theme.scaledUi(36.0),
            .row_gap = theme.scaledUi(12.0),
            .inner_gap = theme.scaledUi(8.0),
            .step_w = theme.scaledUi(32.0),
            .value_w = theme.scaledUi(44.0),
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
    body_clip: palette.Rect,
    max_scroll_y: f32,
    close: palette.Rect,
    cancel: palette.Rect,
    save: palette.Rect,
    appearance_card: palette.Rect,
    theme_dropdown: palette.Rect,
    ui_font_dec: palette.Rect,
    ui_font_inc: palette.Rect,
    transcript_card: palette.Rect,
    tool_groups_collapsed: palette.Rect,
    tool_groups_expanded: palette.Rect,
    tool_groups_remember_last: palette.Rect,
    diff_layout_stacked: palette.Rect,
    diff_layout_split: palette.Rect,
    chat_card: palette.Rect,
    automatic_chat_titles: palette.Rect,
    chat_title_provider_dropdown: palette.Rect,
    chat_title_model_dropdown: palette.Rect,
    chat_hint_y: f32,
    terminal_card: palette.Rect,
    terminal_font_dec: palette.Rect,
    terminal_font_inc: palette.Rect,
    terminal_hint_y: f32,
    links_verde_browser: palette.Rect,
    links_system_browser: palette.Rect,
    browser_card: palette.Rect,
    browser_fast_scrolling: palette.Rect,
    browser_hint_y: f32,
    workspace_card: palette.Rect,
    open_cells: [OPEN_CHOICES.len]palette.Rect,
    custom_open: ?palette.Rect = null,
    new_chat_new_pane: palette.Rect,
    new_chat_replace_pane: palette.Rect,
    file_links_neovim_pane: palette.Rect,
    file_links_hint_y: f32,
    workspace_pane_gap_dec: palette.Rect,
    workspace_pane_gap_inc: palette.Rect,
    workspace_pane_gap_hint_y: f32,
    workspace_panes_per_view_dec: palette.Rect,
    workspace_panes_per_view_inc: palette.Rect,
    workspace_panes_per_view_hint_y: f32,
    workspace_scroll_mode_automatic: palette.Rect,
    workspace_scroll_mode_always: palette.Rect,
    workspace_scroll_mode_disabled: palette.Rect,
    workspace_scroll_mode_hint_y: f32,
    workspace_scroll_threshold_dec: palette.Rect,
    workspace_scroll_threshold_inc: palette.Rect,
    workspace_scroll_threshold_hint_y: f32,
    workspace_scroll_horizontal: palette.Rect,
    workspace_scroll_vertical: palette.Rect,
    workspace_scroll_direction_hint_y: f32,
    integrations_card: palette.Rect,
    mcp_tools: palette.Rect,
    mcp_hint_y: f32,
    hooks_label_y: f32,
    hooks_claude: palette.Rect,
    hooks_codex: palette.Rect,
    hooks_cursor: palette.Rect,
    hooks_grok: palette.Rect,
    hooks_amp: palette.Rect,
    integrations_hint_y: f32,
    updates_card: palette.Rect,
    updates_check: palette.Rect,
    updates_download: palette.Rect,
    updates_automatic: palette.Rect,
    updates_status_y: f32,
    updates_notes_y: f32,
    updates_notes_toggle: ?palette.Rect = null,
    updates_release_page: palette.Rect,
    notifications_card: palette.Rect,
    notifications_toggle: palette.Rect,
    notifications_hint_y: f32,
};

const log = std.log.scoped(.native_ui_settings);

// Frame-wide fade multiplier applied by paletteColor; set from the modal's
// animation progress at the top of render.
var current_fade_alpha: f32 = 1.0;

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
    return theme.mix(theme.COLOR_TEXT_SUBTLE, theme.COLOR_WHITE, 0.18);
}

// Settings controls need predictable contrast against the modal. Omarchy's
// terminal color0/color8 may be light, so panel_alt/panel_muted are unsuitable
// as opaque fills even though they remain useful as palette accents elsewhere.
fn raisedSurface(amount: f32) [4]f32 {
    return theme.mix(theme.background(), theme.COLOR_WHITE, amount);
}

fn cardSurface() [4]f32 {
    return raisedSurface(0.10);
}

fn controlSurface() [4]f32 {
    return raisedSurface(0.16);
}

fn controlHoverSurface() [4]f32 {
    return raisedSurface(0.22);
}

fn metrics() Metrics {
    return Metrics.init();
}

fn modalWidth(width: f32) f32 {
    // Scale with the window instead of pinning to a narrow strip; the margin
    // floor keeps small windows usable.
    const margin = theme.scaledUi(48.0);
    return @min(theme.clampf(width * 0.46, theme.scaledUi(600.0), theme.scaledUi(880.0)), @max(width - margin, theme.scaledUi(320.0)));
}

fn layoutModal(width: f32, height: f32, modal_h: f32) palette.Rect {
    const modal_w = modalWidth(width);
    const max_h = height * 0.9;
    const h = @min(theme.clampf(modal_h, theme.scaledUi(560.0), max_h), max_h);
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

    // Three columns: the wider modal makes two-across cells look oversized.
    const open_cols: usize = 3;
    const open_rows = (OPEN_CHOICES.len + open_cols - 1) / open_cols;
    const open_grid_h = @as(f32, @floatFromInt(open_rows)) * m.row_h + @as(f32, @floatFromInt(open_rows - 1)) * m.inner_gap;
    const custom_extra: f32 = if (state.settings_controller.draft.open_action == .custom) m.row_h + m.inner_gap else 0.0;

    const appearance_h = m.labeledBlockH(2);
    const transcript_h = m.card_pad * 2.0 + m.title_h + m.row_gap +
        m.label_h + m.inner_gap + m.row_h + m.row_gap +
        m.label_h + m.inner_gap + m.row_h;
    const chat_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.label_h + m.inner_gap + m.row_h + m.row_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.label_h;
    const terminal_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.row_h + m.inner_gap + m.label_h + m.row_gap + m.label_h + m.inner_gap + m.row_h;
    const browser_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.label_h;
    const workspace_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.label_h + m.inner_gap + open_grid_h + custom_extra +
        m.row_gap + m.label_h + m.inner_gap + m.row_h +
        m.row_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.label_h +
        m.row_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.label_h +
        m.row_gap + m.row_h + m.inner_gap + m.label_h +
        m.row_gap + m.row_h + m.inner_gap + m.label_h +
        m.row_gap + m.row_h + m.inner_gap + m.label_h +
        m.row_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.label_h;
    // MCP controls and status, followed by the provider status-hook controls.
    const integrations_h = m.card_pad * 2.0 + m.title_h + m.row_gap * 2.0 + m.label_h * 4.0 + m.row_h * 6.0 + m.inner_gap * 8.0;
    // Same shape as the integrations card: title, field label, one toggle row, hint.
    const notifications_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.label_h;
    // The modal width depends only on the window, so the notes block can be
    // measured before card heights are summed.
    const updates_notes_w = modalWidth(width) - m.modal_pad * 2.0 - m.card_pad * 2.0;
    const updates_notes_h = notesBlockHeight(state, updates_notes_w, m);
    // Version/status, action row, automatic-check preference, release notes
    // (preview or expanded), and the show-more / release-page links row.
    const updates_h = m.card_pad * 2.0 + m.title_h + m.inner_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.row_h + m.inner_gap + updates_notes_h + m.inner_gap + m.label_h;

    const body_h = appearance_h + m.card_gap + transcript_h + m.card_gap + chat_h + m.card_gap + terminal_h + m.card_gap + browser_h + m.card_gap + workspace_h + m.card_gap + integrations_h + m.card_gap + updates_h + m.card_gap + notifications_h;
    const modal_h = m.header_h + m.modal_pad + body_h + m.modal_pad + m.footer_h;
    const modal = layoutModal(width, height, modal_h);

    const header: palette.Rect = .{ .x = modal.x, .y = modal.y, .w = modal.w, .h = m.header_h };
    const footer: palette.Rect = .{ .x = modal.x, .y = modal.y + modal.h - m.footer_h, .w = modal.w, .h = m.footer_h };
    const content_y = header.y + header.h + m.modal_pad;
    const body_view_h = @max(footer.y - m.modal_pad - content_y, 0.0);
    const max_scroll_y = @max(body_h - body_view_h, 0.0);
    const scroll_y = theme.clampf(state.settings_controller.scroll_y, 0.0, max_scroll_y);
    const body_clip: palette.Rect = .{
        .x = modal.x,
        .y = header.y + header.h,
        .w = modal.w,
        .h = @max(footer.y - (header.y + header.h), 0.0),
    };

    const close_size = theme.scaledUi(30.0);
    const close: palette.Rect = .{
        .x = modal.x + modal.w - m.modal_pad - close_size,
        .y = modal.y + (m.header_h - close_size) * 0.5,
        .w = close_size,
        .h = close_size,
    };

    const button_h = theme.scaledUi(34.0);
    const button_w = theme.scaledUi(96.0);
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
    var y = content_y - scroll_y;

    const appearance_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = appearance_h };
    const theme_row_y = appearance_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const theme_x = appearance_card.x + m.card_pad;
    const theme_dropdown: palette.Rect = .{ .x = theme_x, .y = theme_row_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const ui_font_y = theme_row_y + m.row_h + m.row_gap;
    const ui_stepper = stepperRects(appearance_card, m.card_pad, ui_font_y, m);

    y += appearance_h + m.card_gap;

    const transcript_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = transcript_h };
    const tool_group_y = transcript_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const tool_group_w = (content_w - m.card_pad * 2.0 - m.inner_gap * 2.0) / 3.0;
    const tool_groups_collapsed: palette.Rect = .{ .x = transcript_card.x + m.card_pad, .y = tool_group_y, .w = tool_group_w, .h = m.row_h };
    const tool_groups_expanded: palette.Rect = .{ .x = tool_groups_collapsed.x + tool_group_w + m.inner_gap, .y = tool_group_y, .w = tool_group_w, .h = m.row_h };
    const tool_groups_remember_last: palette.Rect = .{ .x = tool_groups_expanded.x + tool_group_w + m.inner_gap, .y = tool_group_y, .w = tool_group_w, .h = m.row_h };
    const diff_layout_y = tool_group_y + m.row_h + m.row_gap + m.label_h + m.inner_gap;
    const diff_layout_w = (content_w - m.card_pad * 2.0) * 0.5;
    const diff_layout_stacked: palette.Rect = .{ .x = transcript_card.x + m.card_pad, .y = diff_layout_y, .w = diff_layout_w, .h = m.row_h };
    const diff_layout_split: palette.Rect = .{ .x = diff_layout_stacked.x + diff_layout_w, .y = diff_layout_y, .w = diff_layout_w, .h = m.row_h };

    y += transcript_h + m.card_gap;

    const chat_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = chat_h };
    const automatic_chat_titles_y = chat_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const automatic_chat_titles: palette.Rect = .{ .x = chat_card.x + m.card_pad, .y = automatic_chat_titles_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const title_generator_label_y = automatic_chat_titles_y + m.row_h + m.row_gap;
    const title_generator_y = title_generator_label_y + m.label_h + m.inner_gap;
    const title_generator_w = content_w - m.card_pad * 2.0;
    const title_provider_w = (title_generator_w - m.inner_gap) * 0.42;
    const chat_title_provider_dropdown: palette.Rect = .{
        .x = chat_card.x + m.card_pad,
        .y = title_generator_y,
        .w = title_provider_w,
        .h = m.row_h,
    };
    const chat_title_model_dropdown: palette.Rect = .{
        .x = chat_title_provider_dropdown.x + chat_title_provider_dropdown.w + m.inner_gap,
        .y = title_generator_y,
        .w = title_generator_w - title_provider_w - m.inner_gap,
        .h = m.row_h,
    };
    const chat_hint_y = title_generator_y + m.row_h + m.inner_gap;

    y += chat_h + m.card_gap;

    const terminal_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = terminal_h };
    const terminal_font_y = terminal_card.y + m.card_pad + m.title_h + m.row_gap;
    const terminal_stepper = stepperRects(terminal_card, m.card_pad, terminal_font_y, m);
    const terminal_hint_y = terminal_font_y + m.row_h + m.inner_gap;
    const link_label_y = terminal_hint_y + m.label_h + m.row_gap;
    const link_row_y = link_label_y + m.label_h + m.inner_gap;
    // Flush halves so the pair renders as one segmented control.
    const link_cell_w = (content_w - m.card_pad * 2.0) * 0.5;
    const links_verde_browser: palette.Rect = .{ .x = terminal_card.x + m.card_pad, .y = link_row_y, .w = link_cell_w, .h = m.row_h };
    const links_system_browser: palette.Rect = .{ .x = links_verde_browser.x + link_cell_w, .y = link_row_y, .w = link_cell_w, .h = m.row_h };

    y += terminal_h + m.card_gap;

    const browser_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = browser_h };
    const browser_fast_scrolling_y = browser_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const browser_fast_scrolling: palette.Rect = .{ .x = browser_card.x + m.card_pad, .y = browser_fast_scrolling_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const browser_hint_y = browser_fast_scrolling_y + m.row_h + m.inner_gap;

    y += browser_h + m.card_gap;

    const workspace_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = workspace_h };
    const open_y = workspace_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const open_cell_w = (content_w - m.card_pad * 2.0 - m.inner_gap * @as(f32, @floatFromInt(open_cols - 1))) / @as(f32, @floatFromInt(open_cols));
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
    if (state.settings_controller.draft.open_action == .custom) {
        custom_open = .{
            .x = open_x,
            .y = open_y + open_grid_h + m.inner_gap,
            .w = content_w - m.card_pad * 2.0,
            .h = m.row_h,
        };
    }
    const new_chat_label_y = open_y + open_grid_h + custom_extra + m.row_gap;
    const new_chat_y = new_chat_label_y + m.label_h + m.inner_gap;
    const new_chat_cell_w = (content_w - m.card_pad * 2.0) * 0.5;
    const new_chat_new_pane: palette.Rect = .{ .x = open_x, .y = new_chat_y, .w = new_chat_cell_w, .h = m.row_h };
    const new_chat_replace_pane: palette.Rect = .{ .x = new_chat_new_pane.x + new_chat_cell_w, .y = new_chat_y, .w = new_chat_cell_w, .h = m.row_h };
    const file_links_label_y = new_chat_y + m.row_h + m.row_gap;
    const file_links_y = file_links_label_y + m.label_h + m.inner_gap;
    const file_links_neovim_pane: palette.Rect = .{ .x = open_x, .y = file_links_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const file_links_hint_y = file_links_y + m.row_h + m.inner_gap;
    const workspace_scroll_mode_label_y = file_links_hint_y + m.label_h + m.row_gap;
    const workspace_scroll_mode_y = workspace_scroll_mode_label_y + m.label_h + m.inner_gap;
    const workspace_scroll_mode_w = (content_w - m.card_pad * 2.0) / 3.0;
    const workspace_scroll_mode_automatic: palette.Rect = .{ .x = open_x, .y = workspace_scroll_mode_y, .w = workspace_scroll_mode_w, .h = m.row_h };
    const workspace_scroll_mode_always: palette.Rect = .{ .x = workspace_scroll_mode_automatic.x + workspace_scroll_mode_w, .y = workspace_scroll_mode_y, .w = workspace_scroll_mode_w, .h = m.row_h };
    const workspace_scroll_mode_disabled: palette.Rect = .{ .x = workspace_scroll_mode_always.x + workspace_scroll_mode_w, .y = workspace_scroll_mode_y, .w = workspace_scroll_mode_w, .h = m.row_h };
    const workspace_scroll_mode_hint_y = workspace_scroll_mode_y + m.row_h + m.inner_gap;
    const workspace_scroll_threshold_y = workspace_scroll_mode_hint_y + m.label_h + m.row_gap;
    const workspace_scroll_threshold_stepper = stepperRects(workspace_card, m.card_pad, workspace_scroll_threshold_y, m);
    const workspace_scroll_threshold_hint_y = workspace_scroll_threshold_y + m.row_h + m.inner_gap;
    const workspace_pane_gap_y = workspace_scroll_threshold_hint_y + m.label_h + m.row_gap;
    const workspace_pane_gap_stepper = stepperRects(workspace_card, m.card_pad, workspace_pane_gap_y, m);
    const workspace_pane_gap_hint_y = workspace_pane_gap_y + m.row_h + m.inner_gap;
    const workspace_panes_per_view_y = workspace_pane_gap_hint_y + m.label_h + m.row_gap;
    const workspace_panes_per_view_stepper = stepperRects(workspace_card, m.card_pad, workspace_panes_per_view_y, m);
    const workspace_panes_per_view_hint_y = workspace_panes_per_view_y + m.row_h + m.inner_gap;
    const workspace_scroll_direction_label_y = workspace_panes_per_view_hint_y + m.label_h + m.row_gap;
    const workspace_scroll_direction_y = workspace_scroll_direction_label_y + m.label_h + m.inner_gap;
    const workspace_scroll_direction_w = (content_w - m.card_pad * 2.0) * 0.5;
    const workspace_scroll_horizontal: palette.Rect = .{ .x = open_x, .y = workspace_scroll_direction_y, .w = workspace_scroll_direction_w, .h = m.row_h };
    const workspace_scroll_vertical: palette.Rect = .{ .x = workspace_scroll_horizontal.x + workspace_scroll_direction_w, .y = workspace_scroll_direction_y, .w = workspace_scroll_direction_w, .h = m.row_h };
    const workspace_scroll_direction_hint_y = workspace_scroll_direction_y + m.row_h + m.inner_gap;

    y += workspace_h + m.card_gap;

    const integrations_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = integrations_h };
    const mcp_tools_y = integrations_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const mcp_tools: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = mcp_tools_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const mcp_hint_y = mcp_tools_y + m.row_h + m.inner_gap;
    const hooks_label_y = mcp_hint_y + m.label_h + m.row_gap;
    const hooks_claude_y = hooks_label_y + m.label_h + m.inner_gap;
    const hooks_claude: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_claude_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_codex_y = hooks_claude_y + m.row_h + m.inner_gap;
    const hooks_codex: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_codex_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_cursor_y = hooks_codex_y + m.row_h + m.inner_gap;
    const hooks_cursor: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_cursor_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_grok_y = hooks_cursor_y + m.row_h + m.inner_gap;
    const hooks_grok: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_grok_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_amp_y = hooks_grok_y + m.row_h + m.inner_gap;
    const hooks_amp: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_amp_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const integrations_hint_y = hooks_amp_y + m.row_h + m.inner_gap;

    y += integrations_h + m.card_gap;

    const updates_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = updates_h };
    const updates_status_y = updates_card.y + m.card_pad + m.title_h + m.inner_gap;
    const updates_actions_y = updates_status_y + m.label_h + m.inner_gap;
    const update_action_w = (content_w - m.card_pad * 2.0 - m.inner_gap) * 0.5;
    const updates_check: palette.Rect = .{ .x = updates_card.x + m.card_pad, .y = updates_actions_y, .w = update_action_w, .h = m.row_h };
    const updates_download: palette.Rect = .{ .x = updates_check.x + update_action_w + m.inner_gap, .y = updates_actions_y, .w = update_action_w, .h = m.row_h };
    const updates_automatic: palette.Rect = .{ .x = updates_check.x, .y = updates_actions_y + m.row_h + m.inner_gap, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const updates_notes_y = updates_automatic.y + m.row_h + m.inner_gap;
    const updates_links_y = updates_notes_y + updates_notes_h + m.inner_gap;
    var updates_notes_toggle: ?palette.Rect = null;
    if (state.settings_controller.update.release != null) {
        updates_notes_toggle = .{
            .x = updates_card.x + m.card_pad,
            .y = updates_links_y,
            .w = text_measure.textWidth(.ui, theme.scaledUi(NOTES_LINK_FONT_SIZE), notesToggleLabel(state)),
            .h = m.label_h,
        };
    }
    const release_page_x = if (updates_notes_toggle) |toggle| toggle.x + toggle.w + m.row_gap * 2.0 else updates_card.x + m.card_pad;
    const updates_release_page: palette.Rect = .{
        .x = release_page_x,
        .y = updates_links_y,
        .w = text_measure.textWidth(.ui, theme.scaledUi(NOTES_LINK_FONT_SIZE), RELEASE_PAGE_LABEL),
        .h = m.label_h,
    };

    y += updates_h + m.card_gap;

    const notifications_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = notifications_h };
    const notifications_toggle_y = notifications_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const notifications_toggle: palette.Rect = .{ .x = notifications_card.x + m.card_pad, .y = notifications_toggle_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const notifications_hint_y = notifications_toggle_y + m.row_h + m.inner_gap;

    return .{
        .modal = modal,
        .header = header,
        .footer = footer,
        .body_clip = body_clip,
        .max_scroll_y = max_scroll_y,
        .close = close,
        .cancel = cancel,
        .save = save,
        .appearance_card = appearance_card,
        .theme_dropdown = theme_dropdown,
        .ui_font_dec = ui_stepper.dec,
        .ui_font_inc = ui_stepper.inc,
        .transcript_card = transcript_card,
        .tool_groups_collapsed = tool_groups_collapsed,
        .tool_groups_expanded = tool_groups_expanded,
        .tool_groups_remember_last = tool_groups_remember_last,
        .diff_layout_stacked = diff_layout_stacked,
        .diff_layout_split = diff_layout_split,
        .chat_card = chat_card,
        .automatic_chat_titles = automatic_chat_titles,
        .chat_title_provider_dropdown = chat_title_provider_dropdown,
        .chat_title_model_dropdown = chat_title_model_dropdown,
        .chat_hint_y = chat_hint_y,
        .terminal_card = terminal_card,
        .terminal_font_dec = terminal_stepper.dec,
        .terminal_font_inc = terminal_stepper.inc,
        .terminal_hint_y = terminal_hint_y,
        .links_verde_browser = links_verde_browser,
        .links_system_browser = links_system_browser,
        .browser_card = browser_card,
        .browser_fast_scrolling = browser_fast_scrolling,
        .browser_hint_y = browser_hint_y,
        .workspace_card = workspace_card,
        .open_cells = open_cells,
        .custom_open = custom_open,
        .new_chat_new_pane = new_chat_new_pane,
        .new_chat_replace_pane = new_chat_replace_pane,
        .file_links_neovim_pane = file_links_neovim_pane,
        .file_links_hint_y = file_links_hint_y,
        .workspace_pane_gap_dec = workspace_pane_gap_stepper.dec,
        .workspace_pane_gap_inc = workspace_pane_gap_stepper.inc,
        .workspace_pane_gap_hint_y = workspace_pane_gap_hint_y,
        .workspace_panes_per_view_dec = workspace_panes_per_view_stepper.dec,
        .workspace_panes_per_view_inc = workspace_panes_per_view_stepper.inc,
        .workspace_panes_per_view_hint_y = workspace_panes_per_view_hint_y,
        .workspace_scroll_mode_automatic = workspace_scroll_mode_automatic,
        .workspace_scroll_mode_always = workspace_scroll_mode_always,
        .workspace_scroll_mode_disabled = workspace_scroll_mode_disabled,
        .workspace_scroll_mode_hint_y = workspace_scroll_mode_hint_y,
        .workspace_scroll_threshold_dec = workspace_scroll_threshold_stepper.dec,
        .workspace_scroll_threshold_inc = workspace_scroll_threshold_stepper.inc,
        .workspace_scroll_threshold_hint_y = workspace_scroll_threshold_hint_y,
        .workspace_scroll_horizontal = workspace_scroll_horizontal,
        .workspace_scroll_vertical = workspace_scroll_vertical,
        .workspace_scroll_direction_hint_y = workspace_scroll_direction_hint_y,
        .integrations_card = integrations_card,
        .mcp_tools = mcp_tools,
        .mcp_hint_y = mcp_hint_y,
        .hooks_label_y = hooks_label_y,
        .hooks_claude = hooks_claude,
        .hooks_codex = hooks_codex,
        .hooks_cursor = hooks_cursor,
        .hooks_grok = hooks_grok,
        .hooks_amp = hooks_amp,
        .integrations_hint_y = integrations_hint_y,
        .updates_card = updates_card,
        .updates_check = updates_check,
        .updates_download = updates_download,
        .updates_automatic = updates_automatic,
        .updates_status_y = updates_status_y,
        .updates_notes_y = updates_notes_y,
        .updates_notes_toggle = updates_notes_toggle,
        .updates_release_page = updates_release_page,
        .notifications_card = notifications_card,
        .notifications_toggle = notifications_toggle,
        .notifications_hint_y = notifications_hint_y,
    };
}

fn isControlHovered(state: *const runtime.AppState, control: Control) bool {
    return state.settings_controller.hover_control != null and state.settings_controller.hover_control.? == @intFromEnum(control);
}

fn openActionSelected(state: *const runtime.AppState, control: Control) bool {
    return switch (control) {
        .open_folder => state.settings_controller.draft.open_action == .folder,
        .open_editor => state.settings_controller.draft.open_action == .editor,
        .open_cursor => state.settings_controller.draft.open_action == .cursor,
        .open_vscode => state.settings_controller.draft.open_action == .vscode,
        .open_zed => state.settings_controller.draft.open_action == .zed,
        else => false,
    };
}

fn queueControlHit(
    state: *runtime.AppState,
    rect: palette.Rect,
    clip: palette.Rect,
    control: Control,
    queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    const visible = intersectRect(rect, clip) orelse return;
    queue_hit(state, visible, .settings_control, @intFromEnum(control));
}

fn themeMenuVisibleCount(state: *const runtime.AppState) usize {
    return @min(state.settingsThemeChoiceCount(), THEME_MENU_MAX_ROWS);
}

fn themeMenuMaxScroll(state: *const runtime.AppState) usize {
    return state.settingsThemeChoiceCount() - themeMenuVisibleCount(state);
}

fn themeMenuRect(state: *const runtime.AppState, layout: SettingsLayout) palette.Rect {
    const row_count = themeMenuVisibleCount(state);
    return .{
        .x = layout.theme_dropdown.x,
        .y = layout.theme_dropdown.y + layout.theme_dropdown.h + theme.scaledUi(4.0),
        .w = layout.theme_dropdown.w,
        .h = @as(f32, @floatFromInt(row_count)) * metrics().row_h,
    };
}

fn themeOptionRect(state: *const runtime.AppState, layout: SettingsLayout, visible_index: usize) palette.Rect {
    const menu = themeMenuRect(state, layout);
    return .{
        .x = menu.x,
        .y = menu.y + @as(f32, @floatFromInt(visible_index)) * metrics().row_h,
        .w = menu.w,
        .h = metrics().row_h,
    };
}

fn registerThemeOptionHits(
    state: *runtime.AppState,
    layout: SettingsLayout,
    queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    if (!state.settings_controller.theme_dropdown_open) return;
    state.settings_controller.theme_menu_scroll = @min(state.settings_controller.theme_menu_scroll, themeMenuMaxScroll(state));
    for (0..themeMenuVisibleCount(state)) |visible_index| {
        const rect = intersectRect(themeOptionRect(state, layout, visible_index), layout.body_clip) orelse continue;
        queue_hit(state, rect, .settings_theme_option, state.settings_controller.theme_menu_scroll + visible_index);
    }
}

fn dropdownMenuRect(dropdown: palette.Rect, row_count: usize) palette.Rect {
    return .{
        .x = dropdown.x,
        .y = dropdown.y + dropdown.h + theme.scaledUi(4.0),
        .w = dropdown.w,
        .h = @as(f32, @floatFromInt(row_count)) * metrics().row_h,
    };
}

fn dropdownOptionRect(menu: palette.Rect, visible_index: usize) palette.Rect {
    return .{
        .x = menu.x,
        .y = menu.y + @as(f32, @floatFromInt(visible_index)) * metrics().row_h,
        .w = menu.w,
        .h = metrics().row_h,
    };
}

fn titleProviderMenuRect(state: *const runtime.AppState, layout: SettingsLayout) palette.Rect {
    return dropdownMenuRect(layout.chat_title_provider_dropdown, @min(state.settingsChatTitleProviderCount(), TITLE_MENU_MAX_ROWS));
}

fn titleModelMenuVisibleCount(state: *const runtime.AppState) usize {
    return @min(state.settingsChatTitleModelCount(), TITLE_MENU_MAX_ROWS);
}

fn titleModelMenuMaxScroll(state: *const runtime.AppState) usize {
    return state.settingsChatTitleModelCount() - titleModelMenuVisibleCount(state);
}

fn titleModelMenuRect(state: *const runtime.AppState, layout: SettingsLayout) palette.Rect {
    return dropdownMenuRect(layout.chat_title_model_dropdown, titleModelMenuVisibleCount(state));
}

fn registerTitleOptionHits(
    state: *runtime.AppState,
    layout: SettingsLayout,
    queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    if (state.settings_controller.title_provider_dropdown_open) {
        const menu = titleProviderMenuRect(state, layout);
        for (0..state.settingsChatTitleProviderCount()) |option_index| {
            const rect = intersectRect(dropdownOptionRect(menu, option_index), layout.body_clip) orelse continue;
            queue_hit(state, rect, .settings_title_provider_option, option_index);
        }
    }
    if (state.settings_controller.title_model_dropdown_open) {
        state.settings_controller.title_model_menu_scroll = @min(state.settings_controller.title_model_menu_scroll, titleModelMenuMaxScroll(state));
        const menu = titleModelMenuRect(state, layout);
        for (0..titleModelMenuVisibleCount(state)) |visible_index| {
            const rect = intersectRect(dropdownOptionRect(menu, visible_index), layout.body_clip) orelse continue;
            queue_hit(state, rect, .settings_title_model_option, state.settings_controller.title_model_menu_scroll + visible_index);
        }
    }
}

/// Registers palette hit targets for the settings modal.
pub fn registerHits(state: *runtime.AppState, width: f32, height: f32, queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void) void {
    if (!state.settings_controller.modal_visible) return;
    if (state.settings_controller.modal_closing) {
        // Swallow input during the fade-out; the controls are already gone.
        queue_hit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .modal_block, 0);
        return;
    }

    const layout = computeLayout(state, width, height);
    state.settings_controller.scroll_y = theme.clampf(state.settings_controller.scroll_y, 0.0, layout.max_scroll_y);
    queue_hit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .modal_dismiss, 0);
    queue_hit(state, layout.modal, .modal_block, 0);
    queue_hit(state, layout.close, .settings_close, 0);
    queue_hit(state, layout.cancel, .settings_cancel, 0);
    queue_hit(state, layout.save, .settings_save, 0);
    queueControlHit(state, layout.theme_dropdown, layout.body_clip, .theme_dropdown, queue_hit);
    queueControlHit(state, layout.ui_font_dec, layout.body_clip, .ui_font_dec, queue_hit);
    queueControlHit(state, layout.ui_font_inc, layout.body_clip, .ui_font_inc, queue_hit);
    queueControlHit(state, layout.tool_groups_collapsed, layout.body_clip, .tool_groups_collapsed, queue_hit);
    queueControlHit(state, layout.tool_groups_expanded, layout.body_clip, .tool_groups_expanded, queue_hit);
    queueControlHit(state, layout.tool_groups_remember_last, layout.body_clip, .tool_groups_remember_last, queue_hit);
    queueControlHit(state, layout.diff_layout_stacked, layout.body_clip, .diff_layout_stacked, queue_hit);
    queueControlHit(state, layout.diff_layout_split, layout.body_clip, .diff_layout_split, queue_hit);
    queueControlHit(state, layout.automatic_chat_titles, layout.body_clip, .automatic_chat_titles, queue_hit);
    queueControlHit(state, layout.chat_title_provider_dropdown, layout.body_clip, .chat_title_provider_dropdown, queue_hit);
    queueControlHit(state, layout.chat_title_model_dropdown, layout.body_clip, .chat_title_model_dropdown, queue_hit);
    queueControlHit(state, layout.terminal_font_dec, layout.body_clip, .terminal_font_dec, queue_hit);
    queueControlHit(state, layout.terminal_font_inc, layout.body_clip, .terminal_font_inc, queue_hit);
    queueControlHit(state, layout.links_verde_browser, layout.body_clip, .links_verde_browser, queue_hit);
    queueControlHit(state, layout.links_system_browser, layout.body_clip, .links_system_browser, queue_hit);
    queueControlHit(state, layout.browser_fast_scrolling, layout.body_clip, .browser_fast_scrolling, queue_hit);
    for (OPEN_CHOICES, 0..) |choice, index| {
        queueControlHit(state, layout.open_cells[index], layout.body_clip, choice.control, queue_hit);
    }
    queueControlHit(state, layout.new_chat_new_pane, layout.body_clip, .new_chat_new_pane, queue_hit);
    queueControlHit(state, layout.new_chat_replace_pane, layout.body_clip, .new_chat_replace_pane, queue_hit);
    queueControlHit(state, layout.file_links_neovim_pane, layout.body_clip, .file_links_neovim_pane, queue_hit);
    queueControlHit(state, layout.workspace_scroll_mode_automatic, layout.body_clip, .workspace_scroll_mode_automatic, queue_hit);
    queueControlHit(state, layout.workspace_scroll_mode_always, layout.body_clip, .workspace_scroll_mode_always, queue_hit);
    queueControlHit(state, layout.workspace_scroll_mode_disabled, layout.body_clip, .workspace_scroll_mode_disabled, queue_hit);
    queueControlHit(state, layout.workspace_scroll_threshold_dec, layout.body_clip, .workspace_scroll_threshold_dec, queue_hit);
    queueControlHit(state, layout.workspace_scroll_threshold_inc, layout.body_clip, .workspace_scroll_threshold_inc, queue_hit);
    queueControlHit(state, layout.workspace_pane_gap_dec, layout.body_clip, .workspace_pane_gap_dec, queue_hit);
    queueControlHit(state, layout.workspace_pane_gap_inc, layout.body_clip, .workspace_pane_gap_inc, queue_hit);
    queueControlHit(state, layout.workspace_panes_per_view_dec, layout.body_clip, .workspace_panes_per_view_dec, queue_hit);
    queueControlHit(state, layout.workspace_panes_per_view_inc, layout.body_clip, .workspace_panes_per_view_inc, queue_hit);
    queueControlHit(state, layout.workspace_scroll_horizontal, layout.body_clip, .workspace_scroll_horizontal, queue_hit);
    queueControlHit(state, layout.workspace_scroll_vertical, layout.body_clip, .workspace_scroll_vertical, queue_hit);
    queueControlHit(state, layout.mcp_tools, layout.body_clip, .mcp_tools, queue_hit);
    queueControlHit(state, layout.hooks_claude, layout.body_clip, .hooks_claude, queue_hit);
    queueControlHit(state, layout.hooks_codex, layout.body_clip, .hooks_codex, queue_hit);
    queueControlHit(state, layout.hooks_cursor, layout.body_clip, .hooks_cursor, queue_hit);
    queueControlHit(state, layout.hooks_grok, layout.body_clip, .hooks_grok, queue_hit);
    queueControlHit(state, layout.hooks_amp, layout.body_clip, .hooks_amp, queue_hit);
    if (state.settings_controller.update.status != .checking) {
        queueControlHit(state, layout.updates_check, layout.body_clip, .updates_check, queue_hit);
    }
    if (state.updateInstallerButtonEnabled()) {
        queueControlHit(state, layout.updates_download, layout.body_clip, .updates_download, queue_hit);
    }
    queueControlHit(state, layout.updates_automatic, layout.body_clip, .updates_automatic, queue_hit);
    if (layout.updates_notes_toggle) |toggle| {
        queueControlHit(state, toggle, layout.body_clip, .updates_notes_toggle, queue_hit);
    }
    queueControlHit(state, layout.updates_release_page, layout.body_clip, .updates_release_page, queue_hit);
    queueControlHit(state, layout.notifications_toggle, layout.body_clip, .notifications_toggle, queue_hit);
    registerThemeOptionHits(state, layout, queue_hit);
    registerTitleOptionHits(state, layout, queue_hit);
}

/// Renders the settings modal over the workspace.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.settings_controller.modal_visible) return;
    state.tickSettingsModalAnimation();
    // The fade-out may have just finished and hidden the modal.
    if (!state.settings_controller.modal_visible) return;
    const fade_t = theme.clampf(state.settings_controller.modal_anim_progress, 0.0, 1.0);
    current_fade_alpha = fade_t * fade_t * (3.0 - 2.0 * fade_t);
    defer current_fade_alpha = 1.0;

    const m = metrics();
    const layout = computeLayout(state, width, height);
    state.settings_controller.scroll_y = theme.clampf(state.settings_controller.scroll_y, 0.0, layout.max_scroll_y);
    const dirty = state.isSettingsDraftDirty();
    drawModalChrome(state, width, height, layout.modal);

    drawHeaderBar(state, layout, dirty);
    drawCard(state, layout.appearance_card, layout.body_clip);
    drawCard(state, layout.transcript_card, layout.body_clip);
    drawCard(state, layout.chat_card, layout.body_clip);
    drawCard(state, layout.terminal_card, layout.body_clip);
    drawCard(state, layout.browser_card, layout.body_clip);
    drawCard(state, layout.workspace_card, layout.body_clip);
    drawCard(state, layout.integrations_card, layout.body_clip);
    drawCard(state, layout.updates_card, layout.body_clip);
    drawCard(state, layout.notifications_card, layout.body_clip);

    // Appearance
    drawCardTitle(state, layout.appearance_card, "Appearance", layout.body_clip);
    drawFieldLabel(state, layout.appearance_card, m, "Theme", layout.body_clip);
    drawThemeDropdown(state, layout);
    drawStepperRow(state, layout.appearance_card, m, layout.ui_font_dec.y, "UI font size", state.settings_controller.draft.font_size, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE, .ui_font_dec, .ui_font_inc, layout.ui_font_dec, layout.ui_font_inc, layout.body_clip);

    // Transcript
    drawCardTitle(state, layout.transcript_card, "Transcript", layout.body_clip);
    drawFieldLabel(state, layout.transcript_card, m, "Tool call groups", layout.body_clip);
    drawToggleCell(state, layout.tool_groups_collapsed, "Collapsed", state.settings_controller.draft.tool_call_group_preference == .collapsed, isControlHovered(state, .tool_groups_collapsed), layout.body_clip);
    drawToggleCell(state, layout.tool_groups_expanded, "Expanded", state.settings_controller.draft.tool_call_group_preference == .expanded, isControlHovered(state, .tool_groups_expanded), layout.body_clip);
    drawToggleCell(state, layout.tool_groups_remember_last, "Remember last", state.settings_controller.draft.tool_call_group_preference == .remember_last, isControlHovered(state, .tool_groups_remember_last), layout.body_clip);
    queueText(state, .{
        .x = layout.diff_layout_stacked.x,
        .y = layout.diff_layout_stacked.y - m.inner_gap - m.label_h,
        .w = layout.diff_layout_stacked.w + layout.diff_layout_split.w,
        .h = m.label_h,
    }, "Diff layout", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    drawSegmentedPair(state, layout.diff_layout_stacked, layout.diff_layout_split, "Stacked", "Split", state.settings_controller.draft.diff_layout_preference == .stacked, isControlHovered(state, .diff_layout_stacked), isControlHovered(state, .diff_layout_split), layout.body_clip);

    // Chat titles
    drawCardTitle(state, layout.chat_card, "Chat", layout.body_clip);
    drawFieldLabel(state, layout.chat_card, m, "Titles", layout.body_clip);
    drawSwitchRow(state, layout.automatic_chat_titles, "Generate automatically", state.settings_controller.draft.automatic_chat_titles_enabled, isControlHovered(state, .automatic_chat_titles), layout.body_clip);
    const title_generator_label_y = layout.chat_title_provider_dropdown.y - m.inner_gap - m.label_h;
    queueText(state, .{
        .x = layout.chat_title_provider_dropdown.x,
        .y = title_generator_label_y,
        .w = layout.chat_title_provider_dropdown.w,
        .h = m.label_h,
    }, "Provider", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    queueText(state, .{
        .x = layout.chat_title_model_dropdown.x,
        .y = title_generator_label_y,
        .w = layout.chat_title_model_dropdown.w,
        .h = m.label_h,
    }, "Model", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    drawChatTitleDropdown(state, layout.chat_title_provider_dropdown, state.settingsChatTitleProviderLabel(state.settingsChatTitleProviderSelectedIndex()), .chat_title_provider_dropdown, state.settings_controller.title_provider_dropdown_open, layout.body_clip);
    drawChatTitleDropdown(state, layout.chat_title_model_dropdown, state.settingsChatTitleModelSelectedLabel(), .chat_title_model_dropdown, state.settings_controller.title_model_dropdown_open, layout.body_clip);
    queueText(state, .{
        .x = layout.chat_card.x + m.card_pad,
        .y = layout.chat_hint_y,
        .w = layout.chat_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Default: GPT-5.6 Luna from Codex / ChatGPT", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);

    // Terminal
    drawCardTitle(state, layout.terminal_card, "Terminal", layout.body_clip);
    drawStepperRow(state, layout.terminal_card, m, layout.terminal_font_dec.y, "Font size", state.settings_controller.draft.terminal_font_size, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE, .terminal_font_dec, .terminal_font_inc, layout.terminal_font_dec, layout.terminal_font_inc, layout.body_clip);
    var profile_buf: [56]u8 = undefined;
    const profile_line = std.fmt.bufPrint(&profile_buf, "{d} launch profile(s) · edit in verde.json", .{state.app_config.terminal_launch_profiles.len}) catch "Edit terminal.profiles in verde.json";
    queueText(state, .{
        .x = layout.terminal_card.x + m.card_pad,
        .y = layout.terminal_hint_y,
        .w = layout.terminal_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, profile_line, paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);
    queueText(state, .{
        .x = layout.terminal_card.x + m.card_pad,
        .y = layout.links_verde_browser.y - m.inner_gap - m.label_h,
        .w = layout.terminal_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Terminal link clicks", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    drawSegmentedPair(state, layout.links_verde_browser, layout.links_system_browser, "Verde browser", "Default browser", state.settings_controller.draft.link_open_target == .verde_browser, isControlHovered(state, .links_verde_browser), isControlHovered(state, .links_system_browser), layout.body_clip);

    // Browser
    drawCardTitle(state, layout.browser_card, "Browser", layout.body_clip);
    drawFieldLabel(state, layout.browser_card, m, "Scrolling", layout.body_clip);
    drawSwitchRow(state, layout.browser_fast_scrolling, "Faster page scrolling (1.5x)", state.settings_controller.draft.browser_fast_scrolling_enabled, isControlHovered(state, .browser_fast_scrolling), layout.body_clip);
    queueText(state, .{
        .x = layout.browser_card.x + m.card_pad,
        .y = layout.browser_hint_y,
        .w = layout.browser_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Turn off to use Verde's standard embedded-browser speed", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);

    // Workspace
    drawCardTitle(state, layout.workspace_card, "Workspace", layout.body_clip);
    drawFieldLabel(state, layout.workspace_card, m, "Default open action", layout.body_clip);
    for (OPEN_CHOICES, 0..) |choice, index| {
        drawToggleCell(state, layout.open_cells[index], choice.label, openActionSelected(state, choice.control), isControlHovered(state, choice.control), layout.body_clip);
    }
    if (state.settings_controller.draft.open_action == .custom) {
        if (layout.custom_open) |custom_row| {
            var custom_buf: [80]u8 = undefined;
            const custom_label = if (state.app_config.default_open_action == .custom)
                std.fmt.bufPrint(&custom_buf, "{s} (custom)", .{state.app_config.default_open_action.custom.label}) catch "Custom"
            else
                "Custom action";
            drawToggleCell(state, custom_row, custom_label, true, false, layout.body_clip);
        }
    }
    queueText(state, .{
        .x = layout.new_chat_new_pane.x,
        .y = layout.new_chat_new_pane.y - m.inner_gap - m.label_h,
        .w = layout.new_chat_new_pane.w + layout.new_chat_replace_pane.w,
        .h = m.label_h,
    }, "New chat action", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    drawSegmentedPair(
        state,
        layout.new_chat_new_pane,
        layout.new_chat_replace_pane,
        "Create new pane",
        "Replace chat pane",
        state.settings_controller.draft.new_chat_pane_behavior == .new_pane,
        isControlHovered(state, .new_chat_new_pane),
        isControlHovered(state, .new_chat_replace_pane),
        layout.body_clip,
    );
    queueText(state, .{
        .x = layout.file_links_neovim_pane.x,
        .y = layout.file_links_neovim_pane.y - m.inner_gap - m.label_h,
        .w = layout.file_links_neovim_pane.w,
        .h = m.label_h,
    }, "Transcript file links", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    drawSwitchRow(state, layout.file_links_neovim_pane, "Open in workspace Neovim pane", state.settings_controller.draft.file_links_in_neovim_pane, isControlHovered(state, .file_links_neovim_pane), layout.body_clip);
    queueText(state, .{
        .x = layout.file_links_neovim_pane.x,
        .y = layout.file_links_hint_y,
        .w = layout.file_links_neovim_pane.w,
        .h = m.label_h,
    }, "Used only when Neovim is the configured editor; otherwise uses the default file action", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);
    queueText(state, .{
        .x = layout.workspace_scroll_mode_automatic.x,
        .y = layout.workspace_scroll_mode_automatic.y - m.inner_gap - m.label_h,
        .w = layout.workspace_scroll_mode_automatic.w + layout.workspace_scroll_mode_always.w + layout.workspace_scroll_mode_disabled.w,
        .h = m.label_h,
    }, "Scrolling layout", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    drawSegmentedTriple(
        state,
        layout.workspace_scroll_mode_automatic,
        layout.workspace_scroll_mode_always,
        layout.workspace_scroll_mode_disabled,
        .{ "Automatic", "Always", "Disabled" },
        @intFromEnum(state.settings_controller.draft.workspace_scroll_mode),
        .{
            isControlHovered(state, .workspace_scroll_mode_automatic),
            isControlHovered(state, .workspace_scroll_mode_always),
            isControlHovered(state, .workspace_scroll_mode_disabled),
        },
        layout.body_clip,
    );
    queueText(state, .{
        .x = layout.workspace_card.x + m.card_pad,
        .y = layout.workspace_scroll_mode_hint_y,
        .w = layout.workspace_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Automatic uses the threshold; Always pins scrolling; Disabled keeps tiled layout", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);
    drawStepperRow(state, layout.workspace_card, m, layout.workspace_scroll_threshold_dec.y, "Activation threshold", @floatFromInt(state.settings_controller.draft.workspace_scroll_threshold), @floatFromInt(app_config.MIN_WORKSPACE_SCROLL_THRESHOLD), @floatFromInt(app_config.MAX_WORKSPACE_SCROLL_THRESHOLD), .workspace_scroll_threshold_dec, .workspace_scroll_threshold_inc, layout.workspace_scroll_threshold_dec, layout.workspace_scroll_threshold_inc, layout.body_clip);
    queueText(state, .{
        .x = layout.workspace_card.x + m.card_pad,
        .y = layout.workspace_scroll_threshold_hint_y,
        .w = layout.workspace_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "In Automatic mode, scrolling starts when the workspace reaches this pane count", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);
    drawStepperRow(state, layout.workspace_card, m, layout.workspace_pane_gap_dec.y, "Pane spacing (px)", state.settings_controller.draft.workspace_pane_gap, app_config.MIN_WORKSPACE_PANE_GAP, app_config.MAX_WORKSPACE_PANE_GAP, .workspace_pane_gap_dec, .workspace_pane_gap_inc, layout.workspace_pane_gap_dec, layout.workspace_pane_gap_inc, layout.body_clip);
    queueText(state, .{
        .x = layout.workspace_card.x + m.card_pad,
        .y = layout.workspace_pane_gap_hint_y,
        .w = layout.workspace_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Space between scrolling panes; zoom stays edge-to-edge", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);
    drawStepperRow(state, layout.workspace_card, m, layout.workspace_panes_per_view_dec.y, "Panes per view", @floatFromInt(state.settings_controller.draft.workspace_panes_per_view), @floatFromInt(app_config.MIN_WORKSPACE_PANES_PER_VIEW), @floatFromInt(app_config.MAX_WORKSPACE_PANES_PER_VIEW), .workspace_panes_per_view_dec, .workspace_panes_per_view_inc, layout.workspace_panes_per_view_dec, layout.workspace_panes_per_view_inc, layout.body_clip);
    queueText(state, .{
        .x = layout.workspace_card.x + m.card_pad,
        .y = layout.workspace_panes_per_view_hint_y,
        .w = layout.workspace_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Sets how many scrolling panes fit along the selected direction", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);
    queueText(state, .{
        .x = layout.workspace_scroll_horizontal.x,
        .y = layout.workspace_scroll_horizontal.y - m.inner_gap - m.label_h,
        .w = layout.workspace_scroll_horizontal.w + layout.workspace_scroll_vertical.w,
        .h = m.label_h,
    }, "Scroll direction", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    drawSegmentedPair(state, layout.workspace_scroll_horizontal, layout.workspace_scroll_vertical, "Horizontal", "Vertical", state.settings_controller.draft.workspace_scroll_direction == .horizontal, isControlHovered(state, .workspace_scroll_horizontal), isControlHovered(state, .workspace_scroll_vertical), layout.body_clip);
    queueText(state, .{
        .x = layout.workspace_card.x + m.card_pad,
        .y = layout.workspace_scroll_direction_hint_y,
        .w = layout.workspace_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Vertical keeps normal pane scrolling; hold Ctrl and use the wheel to pan panes", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);

    // Agent integrations
    drawCardTitle(state, layout.integrations_card, "Agent integrations", layout.body_clip);
    drawFieldLabel(state, layout.integrations_card, m, "Verde agent tools (global)", layout.body_clip);
    const mcp_installed = state.settings_controller.mcp_summary.installedCount() > 0;
    drawSwitchRow(state, layout.mcp_tools, "Enable Verde MCP", mcp_installed, isControlHovered(state, .mcp_tools), layout.body_clip);
    var mcp_status_buf: [120]u8 = undefined;
    const mcp_status = if (state.settings_controller.mcp_summary.detectedCount() == 0)
        "No supported providers detected · Codex, Claude, Cursor, OpenCode, or Amp"
    else if (state.settings_controller.mcp_summary.failedCount() > 0)
        std.fmt.bufPrint(&mcp_status_buf, "Installed for {d} provider(s) · {d} provider config update(s) failed", .{ state.settings_controller.mcp_summary.installedCount(), state.settings_controller.mcp_summary.failedCount() }) catch "Some provider configs could not be updated"
    else if (state.settings_controller.mcp_summary.conflictCount() > 0)
        std.fmt.bufPrint(&mcp_status_buf, "Installed for {d} provider(s) · {d} existing verde entry conflict(s) preserved", .{ state.settings_controller.mcp_summary.installedCount(), state.settings_controller.mcp_summary.conflictCount() }) catch "Some existing verde entries were preserved"
    else
        std.fmt.bufPrint(&mcp_status_buf, "Installed for {d} of {d} detected provider(s) · workspace-aware in Verde panes", .{ state.settings_controller.mcp_summary.installedCount(), state.settings_controller.mcp_summary.detectedCount() }) catch "Workspace-aware in Verde panes";
    queueText(state, .{
        .x = layout.integrations_card.x + m.card_pad,
        .y = layout.mcp_hint_y,
        .w = layout.integrations_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, mcp_status, paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);
    queueText(state, .{
        .x = layout.integrations_card.x + m.card_pad,
        .y = layout.hooks_label_y,
        .w = layout.integrations_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Status pip hooks (global)", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    drawSwitchRow(state, layout.hooks_claude, "Claude", state.settings_controller.hook_claude_installed, isControlHovered(state, .hooks_claude), layout.body_clip);
    drawSwitchRow(state, layout.hooks_codex, "Codex", state.settings_controller.hook_codex_installed, isControlHovered(state, .hooks_codex), layout.body_clip);
    drawSwitchRow(state, layout.hooks_cursor, "Cursor", state.settings_controller.hook_cursor_installed, isControlHovered(state, .hooks_cursor), layout.body_clip);
    drawSwitchRow(state, layout.hooks_grok, "Grok", state.settings_controller.hook_grok_installed, isControlHovered(state, .hooks_grok), layout.body_clip);
    drawSwitchRow(state, layout.hooks_amp, "Amp", state.settings_controller.hook_amp_installed, isControlHovered(state, .hooks_amp), layout.body_clip);
    queueText(state, .{
        .x = layout.integrations_card.x + m.card_pad,
        .y = layout.integrations_hint_y,
        .w = layout.integrations_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Writes hooks/plugins globally · no-op outside Verde panes", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);

    // Updates
    drawCardTitle(state, layout.updates_card, "Updates", layout.body_clip);
    var version_buf: [96]u8 = undefined;
    const update_status = switch (state.settings_controller.update.status) {
        .idle => std.fmt.bufPrint(&version_buf, "Installed {s}", .{build_options.version}) catch "Installed version unavailable",
        .checking => std.fmt.bufPrint(&version_buf, "Installed {s} · Checking…", .{build_options.version}) catch "Checking for updates…",
        .up_to_date => std.fmt.bufPrint(&version_buf, "Installed {s} · Up to date", .{build_options.version}) catch "Verde is up to date",
        .update_available => if (state.settings_controller.update.release) |release|
            std.fmt.bufPrint(&version_buf, "Installed {s} · {s} available", .{ build_options.version, release.version }) catch "Update available"
        else
            "Update available",
        .failed => std.fmt.bufPrint(&version_buf, "Installed {s} · Check failed", .{build_options.version}) catch "Update check failed",
    };
    queueText(state, .{
        .x = layout.updates_card.x + m.card_pad,
        .y = layout.updates_status_y,
        .w = layout.updates_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, update_status, paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    const check_style: ButtonStyle = if (state.settings_controller.update.status == .checking) .disabled else .secondary;
    drawActionButton(state, layout.updates_check, if (state.settings_controller.update.status == .checking) "Checking…" else "Check now", check_style, isControlHovered(state, .updates_check), layout.body_clip);
    const update_button_enabled = state.updateInstallerButtonEnabled();
    const update_button_style: ButtonStyle = if (!update_button_enabled)
        .disabled
    else if (state.settings_controller.update_installer_started)
        .secondary
    else
        .primary;
    drawActionButton(state, layout.updates_download, state.updateInstallerButtonLabel(), update_button_style, isControlHovered(state, .updates_download), layout.body_clip);
    drawSwitchRow(state, layout.updates_automatic, "Check automatically", state.settings_controller.draft.check_for_updates_automatically, isControlHovered(state, .updates_automatic), layout.body_clip);
    const notes_x = layout.updates_card.x + m.card_pad;
    const notes_w = layout.updates_card.w - m.card_pad * 2.0;
    if (state.settings_controller.update_notes_expanded and state.settings_controller.update.release != null) {
        // Full (capped) release notes, one wrapped block per markdown line;
        // heights mirror notesBlockHeight so the card fits the text.
        var iter = NotesLineIterator.init(state.settings_controller.update.release.?.notes);
        var line_y = layout.updates_notes_y;
        while (iter.next()) |line| {
            const line_h = wrappedNotesRows(line.text, notes_w) * notesLineHeight();
            const line_rect: palette.Rect = .{ .x = notes_x, .y = line_y, .w = notes_w, .h = line_h };
            if (intersectRect(line_rect, layout.body_clip)) |line_clip| {
                const line_color = if (line.heading) textLabel() else textHint();
                queueWrappedText(state, line_rect, line.text, paletteColor(line_color), theme.scaledUi(NOTES_FONT_SIZE), line_clip);
            }
            line_y += line_h;
        }
    } else {
        const notes = if (state.settings_controller.update.release) |release| releaseNotesPreview(release.notes) else "Release notes appear here when a release is found.";
        const notes_rect: palette.Rect = .{
            .x = notes_x,
            .y = layout.updates_notes_y,
            .w = notes_w,
            .h = m.label_h * 2.0,
        };
        // Clip to the reserved two-line area so long previews cannot bleed into the next card.
        if (intersectRect(notes_rect, layout.body_clip)) |notes_clip| {
            queueWrappedText(state, notes_rect, notes, paletteColor(textHint()), theme.scaledUi(NOTES_FONT_SIZE), notes_clip);
        }
    }
    if (layout.updates_notes_toggle) |toggle_rect| {
        const toggle_color = if (isControlHovered(state, .updates_notes_toggle)) theme.COLOR_WHITE else textLabel();
        queueText(state, toggle_rect, notesToggleLabel(state), paletteColor(toggle_color), theme.scaledUi(NOTES_LINK_FONT_SIZE), layout.body_clip);
    }
    const release_page_color = if (isControlHovered(state, .updates_release_page)) theme.COLOR_WHITE else textLabel();
    queueText(state, layout.updates_release_page, RELEASE_PAGE_LABEL, paletteColor(release_page_color), theme.scaledUi(NOTES_LINK_FONT_SIZE), layout.body_clip);

    // Notifications
    drawCardTitle(state, layout.notifications_card, "Notifications", layout.body_clip);
    drawFieldLabel(state, layout.notifications_card, m, "Desktop alerts", layout.body_clip);
    drawSwitchRow(state, layout.notifications_toggle, "On agent completion", state.settings_controller.draft.notifications_enabled, isControlHovered(state, .notifications_toggle), layout.body_clip);
    queueText(state, .{
        .x = layout.notifications_card.x + m.card_pad,
        .y = layout.notifications_hint_y,
        .w = layout.notifications_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "System notification when an agent finishes · Windows, macOS & Linux", paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);

    drawBodyScrollbar(state, layout);
    drawThemeDropdownMenu(state, layout);
    drawChatTitleDropdownMenu(state, layout, true);
    drawChatTitleDropdownMenu(state, layout, false);
    drawFooterBar(state, layout, dirty);
}

/// Scrolls settings modal content within the fixed header/footer chrome.
pub fn handleWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    if (!state.settings_controller.modal_visible) return false;
    if (state.settings_controller.modal_closing) return true;

    const layout = computeLayout(state, width, height);
    if (!rectContains(layout.modal, x, y)) return true;
    if (state.settings_controller.theme_dropdown_open and rectContains(themeMenuRect(state, layout), x, y)) {
        const max_scroll = themeMenuMaxScroll(state);
        const next = if (wheel_y < 0.0)
            @min(state.settings_controller.theme_menu_scroll + 1, max_scroll)
        else if (wheel_y > 0.0)
            state.settings_controller.theme_menu_scroll -| 1
        else
            state.settings_controller.theme_menu_scroll;
        if (next != state.settings_controller.theme_menu_scroll) {
            state.settings_controller.theme_menu_scroll = next;
            state.markDirty();
        }
        return true;
    }
    if (state.settings_controller.title_provider_dropdown_open and rectContains(titleProviderMenuRect(state, layout), x, y)) return true;
    if (state.settings_controller.title_model_dropdown_open and rectContains(titleModelMenuRect(state, layout), x, y)) {
        const max_scroll = titleModelMenuMaxScroll(state);
        const next = if (wheel_y < 0.0)
            @min(state.settings_controller.title_model_menu_scroll + 1, max_scroll)
        else if (wheel_y > 0.0)
            state.settings_controller.title_model_menu_scroll -| 1
        else
            state.settings_controller.title_model_menu_scroll;
        if (next != state.settings_controller.title_model_menu_scroll) {
            state.settings_controller.title_model_menu_scroll = next;
            state.markDirty();
        }
        return true;
    }
    if (layout.max_scroll_y <= 0.0) return true;
    if (!rectContains(layout.body_clip, x, y)) return true;

    const delta = -wheel_y * theme.scaledUi(72.0);
    const next = theme.clampf(state.settings_controller.scroll_y + delta, 0.0, layout.max_scroll_y);
    if (next != state.settings_controller.scroll_y) {
        state.settings_controller.scroll_y = next;
        state.markDirty();
    }
    return true;
}

/// Updates settings-modal hover using hits from `refreshPaletteModalHits`.
pub fn updateHover(state: *runtime.AppState, x: f32, y: f32) void {
    if (!state.settings_controller.modal_visible) {
        if (state.settings_controller.hover_control != null or state.settings_controller.close_hovered or state.settings_controller.theme_hover_index != null or state.settings_controller.title_menu_hover_index != null) {
            state.settings_controller.hover_control = null;
            state.settings_controller.close_hovered = false;
            state.settings_controller.theme_hover_index = null;
            state.settings_controller.title_menu_hover_index = null;
            state.markDirty();
        }
        return;
    }

    var new_hover: ?u8 = null;
    var theme_hover: ?usize = null;
    var title_hover: ?usize = null;
    var close_hovered = false;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (hit.action == .settings_close) {
            if (rectContains(hit.rect, x, y)) close_hovered = true;
            continue;
        }
        if (hit.action == .settings_theme_option and rectContains(hit.rect, x, y)) {
            theme_hover = hit.index;
            break;
        }
        if ((hit.action == .settings_title_provider_option or hit.action == .settings_title_model_option) and rectContains(hit.rect, x, y)) {
            title_hover = hit.index;
            break;
        }
        if (hit.action != .settings_control) continue;
        if (!rectContains(hit.rect, x, y)) continue;
        new_hover = @intCast(hit.index);
        break;
    }

    if (state.settings_controller.hover_control == new_hover and state.settings_controller.close_hovered == close_hovered and state.settings_controller.theme_hover_index == theme_hover and state.settings_controller.title_menu_hover_index == title_hover) return;
    state.settings_controller.hover_control = new_hover;
    state.settings_controller.close_hovered = close_hovered;
    state.settings_controller.theme_hover_index = theme_hover;
    state.settings_controller.title_menu_hover_index = title_hover;
    state.markDirty();
}

/// Applies a settings control interaction to the in-modal draft.
pub fn applyControl(state: *runtime.AppState, control_index: usize) void {
    const control: Control = @enumFromInt(control_index);
    if (control != .theme_dropdown) {
        state.settings_controller.theme_dropdown_open = false;
        state.settings_controller.theme_hover_index = null;
    }
    if (control != .chat_title_provider_dropdown) state.settings_controller.title_provider_dropdown_open = false;
    if (control != .chat_title_model_dropdown) state.settings_controller.title_model_dropdown_open = false;
    if (control != .chat_title_provider_dropdown and control != .chat_title_model_dropdown) state.settings_controller.title_menu_hover_index = null;
    switch (control) {
        .ui_font_dec => state.settings_controller.draft.font_size = theme.clampf(state.settings_controller.draft.font_size - 1.0, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE),
        .ui_font_inc => state.settings_controller.draft.font_size = theme.clampf(state.settings_controller.draft.font_size + 1.0, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE),
        .terminal_font_dec => state.settings_controller.draft.terminal_font_size = theme.clampf(state.settings_controller.draft.terminal_font_size - 1.0, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE),
        .terminal_font_inc => state.settings_controller.draft.terminal_font_size = theme.clampf(state.settings_controller.draft.terminal_font_size + 1.0, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE),
        .workspace_pane_gap_dec => state.settings_controller.draft.workspace_pane_gap = theme.clampf(state.settings_controller.draft.workspace_pane_gap - 1.0, app_config.MIN_WORKSPACE_PANE_GAP, app_config.MAX_WORKSPACE_PANE_GAP),
        .workspace_pane_gap_inc => state.settings_controller.draft.workspace_pane_gap = theme.clampf(state.settings_controller.draft.workspace_pane_gap + 1.0, app_config.MIN_WORKSPACE_PANE_GAP, app_config.MAX_WORKSPACE_PANE_GAP),
        .workspace_panes_per_view_dec => {
            if (state.settings_controller.draft.workspace_panes_per_view > app_config.MIN_WORKSPACE_PANES_PER_VIEW) state.settings_controller.draft.workspace_panes_per_view -= 1;
        },
        .workspace_panes_per_view_inc => {
            if (state.settings_controller.draft.workspace_panes_per_view < app_config.MAX_WORKSPACE_PANES_PER_VIEW) state.settings_controller.draft.workspace_panes_per_view += 1;
        },
        .workspace_scroll_mode_automatic => state.settings_controller.draft.workspace_scroll_mode = .automatic,
        .workspace_scroll_mode_always => state.settings_controller.draft.workspace_scroll_mode = .always,
        .workspace_scroll_mode_disabled => state.settings_controller.draft.workspace_scroll_mode = .disabled,
        .workspace_scroll_threshold_dec => {
            if (state.settings_controller.draft.workspace_scroll_threshold > app_config.MIN_WORKSPACE_SCROLL_THRESHOLD) state.settings_controller.draft.workspace_scroll_threshold -= 1;
        },
        .workspace_scroll_threshold_inc => {
            if (state.settings_controller.draft.workspace_scroll_threshold < app_config.MAX_WORKSPACE_SCROLL_THRESHOLD) state.settings_controller.draft.workspace_scroll_threshold += 1;
        },
        .workspace_scroll_horizontal => state.settings_controller.draft.workspace_scroll_direction = .horizontal,
        .workspace_scroll_vertical => state.settings_controller.draft.workspace_scroll_direction = .vertical,
        .theme_dropdown => {
            state.settings_controller.theme_dropdown_open = !state.settings_controller.theme_dropdown_open;
            if (state.settings_controller.theme_dropdown_open) {
                state.settings_controller.theme_hover_index = state.settings_controller.draft.theme_choice;
                ensureThemeChoiceVisible(state, state.settings_controller.draft.theme_choice);
            } else {
                state.settings_controller.theme_hover_index = null;
            }
        },
        .tool_groups_collapsed => state.settings_controller.draft.tool_call_group_preference = .collapsed,
        .tool_groups_expanded => state.settings_controller.draft.tool_call_group_preference = .expanded,
        .tool_groups_remember_last => state.settings_controller.draft.tool_call_group_preference = .remember_last,
        .diff_layout_stacked => state.settings_controller.draft.diff_layout_preference = .stacked,
        .diff_layout_split => state.settings_controller.draft.diff_layout_preference = .split,
        .automatic_chat_titles => state.settings_controller.draft.automatic_chat_titles_enabled = !state.settings_controller.draft.automatic_chat_titles_enabled,
        .chat_title_provider_dropdown => {
            state.settings_controller.title_provider_dropdown_open = !state.settings_controller.title_provider_dropdown_open;
            if (state.settings_controller.title_provider_dropdown_open) {
                state.settings_controller.title_menu_hover_index = state.settingsChatTitleProviderSelectedIndex();
            } else {
                state.settings_controller.title_menu_hover_index = null;
            }
        },
        .chat_title_model_dropdown => {
            state.settings_controller.title_model_dropdown_open = !state.settings_controller.title_model_dropdown_open;
            if (state.settings_controller.title_model_dropdown_open) {
                const selected = state.settingsChatTitleModelSelectedIndex() orelse 0;
                state.settings_controller.title_menu_hover_index = selected;
                ensureTitleModelChoiceVisible(state, selected);
            } else {
                state.settings_controller.title_menu_hover_index = null;
            }
        },
        .new_chat_new_pane => state.settings_controller.draft.new_chat_pane_behavior = .new_pane,
        .new_chat_replace_pane => state.settings_controller.draft.new_chat_pane_behavior = .replace_pane,
        .open_folder => state.settings_controller.draft.open_action = .folder,
        .open_editor => state.settings_controller.draft.open_action = .editor,
        .open_cursor => state.settings_controller.draft.open_action = .cursor,
        .open_vscode => state.settings_controller.draft.open_action = .vscode,
        .open_zed => state.settings_controller.draft.open_action = .zed,
        .file_links_neovim_pane => state.settings_controller.draft.file_links_in_neovim_pane = !state.settings_controller.draft.file_links_in_neovim_pane,
        .links_verde_browser => state.settings_controller.draft.link_open_target = .verde_browser,
        .links_system_browser => state.settings_controller.draft.link_open_target = .system_browser,
        .browser_fast_scrolling => state.settings_controller.draft.browser_fast_scrolling_enabled = !state.settings_controller.draft.browser_fast_scrolling_enabled,
        // Acts immediately (filesystem side effect), independent of Save/Cancel.
        .mcp_tools => {
            state.toggleGlobalMcpIntegration();
            return;
        },
        .hooks_claude => {
            state.toggleClaudeGlobalHooks();
            return;
        },
        .hooks_codex => {
            state.toggleCodexGlobalHooks();
            return;
        },
        .hooks_cursor => {
            state.toggleCursorGlobalHooks();
            return;
        },
        .hooks_grok => {
            state.toggleGrokGlobalHooks();
            return;
        },
        .hooks_amp => {
            state.toggleAmpGlobalHooks();
            return;
        },
        .updates_check => {
            state.startUpdateCheck();
            return;
        },
        .updates_download => {
            if (state.settings_controller.update.status == .update_available) state.installAvailableUpdate();
            return;
        },
        .updates_automatic => state.settings_controller.draft.check_for_updates_automatically = !state.settings_controller.draft.check_for_updates_automatically,
        // View-only disclosure, not part of the Save/Cancel draft.
        .updates_notes_toggle => state.settings_controller.update_notes_expanded = !state.settings_controller.update_notes_expanded,
        .updates_release_page => {
            const url = if (state.settings_controller.update.release) |release| release.page_url else updater.State.releasesUrl();
            state.openConfiguredWebLink(url);
            return;
        },
        // Draft toggle: persisted to verde.json on Save, like the other fields.
        .notifications_toggle => state.settings_controller.draft.notifications_enabled = !state.settings_controller.draft.notifications_enabled,
    }
    state.markDirty();
}

/// Selects a built-in or installed theme from the open settings dropdown.
pub fn applyThemeOption(state: *runtime.AppState, choice_index: usize) void {
    state.selectSettingsThemeChoice(choice_index);
}

pub fn applyChatTitleProviderOption(state: *runtime.AppState, option_index: usize) void {
    state.selectSettingsChatTitleProvider(option_index);
}

pub fn applyChatTitleModelOption(state: *runtime.AppState, option_index: usize) void {
    state.selectSettingsChatTitleModel(option_index);
}

/// Handles navigation while a settings dropdown owns keyboard focus.
pub fn handleKeyDown(state: *runtime.AppState, key: sdl.Keycode) bool {
    if (!state.settings_controller.modal_visible) return false;
    if (state.settings_controller.theme_dropdown_open) return handleThemeKeyDown(state, key);
    if (state.settings_controller.title_provider_dropdown_open) return handleTitleProviderKeyDown(state, key);
    if (state.settings_controller.title_model_dropdown_open) return handleTitleModelKeyDown(state, key);
    return false;
}

fn handleThemeKeyDown(state: *runtime.AppState, key: sdl.Keycode) bool {
    const count = state.settingsThemeChoiceCount();
    if (count == 0) return false;
    const current = state.settings_controller.theme_hover_index orelse state.settings_controller.draft.theme_choice;
    const next = switch (key) {
        .up => current -| 1,
        .down => @min(current + 1, count - 1),
        .home => 0,
        .end => count - 1,
        .escape => {
            state.settings_controller.theme_dropdown_open = false;
            state.settings_controller.theme_hover_index = null;
            state.markDirty();
            return true;
        },
        .@"return", .kp_enter => {
            state.selectSettingsThemeChoice(current);
            return true;
        },
        else => return false,
    };
    state.settings_controller.theme_hover_index = next;
    ensureThemeChoiceVisible(state, next);
    state.markDirty();
    return true;
}

fn handleTitleProviderKeyDown(state: *runtime.AppState, key: sdl.Keycode) bool {
    const count = state.settingsChatTitleProviderCount();
    if (count == 0) return false;
    const current = state.settings_controller.title_menu_hover_index orelse state.settingsChatTitleProviderSelectedIndex();
    const next = switch (key) {
        .up => current -| 1,
        .down => @min(current + 1, count - 1),
        .home => 0,
        .end => count - 1,
        .escape => {
            state.settings_controller.title_provider_dropdown_open = false;
            state.settings_controller.title_menu_hover_index = null;
            state.markDirty();
            return true;
        },
        .@"return", .kp_enter => {
            state.selectSettingsChatTitleProvider(current);
            return true;
        },
        else => return false,
    };
    state.settings_controller.title_menu_hover_index = next;
    state.markDirty();
    return true;
}

fn handleTitleModelKeyDown(state: *runtime.AppState, key: sdl.Keycode) bool {
    const count = state.settingsChatTitleModelCount();
    if (count == 0) return false;
    const current = @min(state.settings_controller.title_menu_hover_index orelse state.settingsChatTitleModelSelectedIndex() orelse 0, count - 1);
    const next = switch (key) {
        .up => current -| 1,
        .down => @min(current + 1, count - 1),
        .home => 0,
        .end => count - 1,
        .escape => {
            state.settings_controller.title_model_dropdown_open = false;
            state.settings_controller.title_menu_hover_index = null;
            state.markDirty();
            return true;
        },
        .@"return", .kp_enter => {
            state.selectSettingsChatTitleModel(current);
            return true;
        },
        else => return false,
    };
    state.settings_controller.title_menu_hover_index = next;
    ensureTitleModelChoiceVisible(state, next);
    state.markDirty();
    return true;
}

fn ensureThemeChoiceVisible(state: *runtime.AppState, choice_index: usize) void {
    if (choice_index < state.settings_controller.theme_menu_scroll) {
        state.settings_controller.theme_menu_scroll = choice_index;
    } else {
        const visible_count = themeMenuVisibleCount(state);
        if (choice_index >= state.settings_controller.theme_menu_scroll + visible_count) {
            state.settings_controller.theme_menu_scroll = choice_index - visible_count + 1;
        }
    }
    state.settings_controller.theme_menu_scroll = @min(state.settings_controller.theme_menu_scroll, themeMenuMaxScroll(state));
}

fn ensureTitleModelChoiceVisible(state: *runtime.AppState, option_index: usize) void {
    if (option_index < state.settings_controller.title_model_menu_scroll) {
        state.settings_controller.title_model_menu_scroll = option_index;
    } else {
        const visible_count = titleModelMenuVisibleCount(state);
        if (option_index >= state.settings_controller.title_model_menu_scroll + visible_count) {
            state.settings_controller.title_model_menu_scroll = option_index - visible_count + 1;
        }
    }
    state.settings_controller.title_model_menu_scroll = @min(state.settings_controller.title_model_menu_scroll, titleModelMenuMaxScroll(state));
}

const NOTES_FONT_SIZE = 12.0;
const NOTES_LINK_FONT_SIZE = 12.5;
const RELEASE_PAGE_LABEL = "Open release page";
// Keeps a pathological release body from producing an unbounded card; the
// release-page link below the notes covers the tail.
const MAX_EXPANDED_NOTES_LINES: usize = 60;

const NotesLine = struct {
    text: []const u8,
    heading: bool,
};

/// Yields trimmed, non-empty release-note lines with markdown heading
/// markers stripped, capped at MAX_EXPANDED_NOTES_LINES.
const NotesLineIterator = struct {
    remaining: []const u8,
    emitted: usize = 0,

    fn init(notes: []const u8) NotesLineIterator {
        return .{ .remaining = std.mem.trim(u8, notes, &std.ascii.whitespace) };
    }

    fn next(self: *NotesLineIterator) ?NotesLine {
        while (self.remaining.len > 0 and self.emitted < MAX_EXPANDED_NOTES_LINES) {
            const line_end = std.mem.indexOfAny(u8, self.remaining, "\r\n") orelse self.remaining.len;
            var line = std.mem.trim(u8, self.remaining[0..line_end], &std.ascii.whitespace);
            self.remaining = std.mem.trimStart(u8, self.remaining[line_end..], &std.ascii.whitespace);
            const heading = line.len > 0 and line[0] == '#';
            line = std.mem.trimStart(u8, std.mem.trimStart(u8, line, "#"), " ");
            if (line.len == 0) continue;
            self.emitted += 1;
            return .{ .text = line, .heading = heading };
        }
        return null;
    }
};

fn notesLineHeight() f32 {
    return theme.scaledUi(NOTES_FONT_SIZE * 1.25);
}

/// Estimated wrapped-row count for one note line. The width bias reserves
/// slack for ragged word-wrap edges so estimates err toward an extra row
/// instead of clipping the last one.
fn wrappedNotesRows(line: []const u8, usable_w: f32) f32 {
    const width = text_measure.textWidth(.ui, theme.scaledUi(NOTES_FONT_SIZE), line);
    const rows = @ceil(width / @max(usable_w * 0.94, 1.0));
    return theme.clampf(rows, 1.0, 6.0);
}

/// Height of the release-notes block inside the Updates card: a two-line
/// preview when collapsed, the full (capped) note lines when expanded.
fn notesBlockHeight(state: *const runtime.AppState, usable_w: f32, m: Metrics) f32 {
    const collapsed_h = m.label_h * 2.0;
    if (!state.settings_controller.update_notes_expanded) return collapsed_h;
    const release = state.settings_controller.update.release orelse return collapsed_h;
    var iter = NotesLineIterator.init(release.notes);
    var total: f32 = 0.0;
    while (iter.next()) |line| total += wrappedNotesRows(line.text, usable_w) * notesLineHeight();
    return @max(total, collapsed_h);
}

fn notesToggleLabel(state: *const runtime.AppState) []const u8 {
    return if (state.settings_controller.update_notes_expanded) "Show less" else "Show full notes";
}

fn releaseNotesPreview(notes: []const u8) []const u8 {
    var remaining = std.mem.trim(u8, notes, &std.ascii.whitespace);
    while (remaining.len > 0) {
        const line_end = std.mem.indexOfAny(u8, remaining, "\r\n") orelse remaining.len;
        var line = std.mem.trim(u8, remaining[0..line_end], &std.ascii.whitespace);
        if (line.len > 0 and line[0] != '#') {
            if (std.mem.startsWith(u8, line, "* ") or std.mem.startsWith(u8, line, "- ")) line = line[2..];
            return line[0..@min(line.len, 220)];
        }
        remaining = std.mem.trimStart(u8, remaining[line_end..], &std.ascii.whitespace);
    }
    return "No release notes were provided.";
}

fn drawModalChrome(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect) void {
    queueRoundedRect(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, paletteColor(theme.scrim(0.68 * current_fade_alpha)), 0.0);
    queueRoundedRect(state, modal, paletteColor(theme.COLOR_PANEL), radiusLg());
    queueBorder(state, modal, paletteColor(theme.withAlpha(theme.borderMuted(), 110)), radiusLg(), theme.scaledUi(1.0));
}

fn drawHeaderBar(state: *runtime.AppState, layout: SettingsLayout, dirty: bool) void {
    const m = metrics();
    drawEdgeStrip(state, layout.header, theme.lighten(theme.COLOR_PANEL, 0.02), true);
    drawHairline(state, layout.header.x, layout.header.y + layout.header.h - 1.0, layout.header.w);

    queueText(state, .{
        .x = layout.modal.x + m.modal_pad,
        .y = layout.header.y + theme.scaledUi(15.0),
        .w = theme.scaledUi(160.0),
        .h = theme.scaledUi(22.0),
    }, "Settings", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), layout.modal);

    queueText(state, .{
        .x = layout.modal.x + m.modal_pad,
        .y = layout.header.y + theme.scaledUi(38.0),
        .w = layout.close.x - layout.modal.x - m.modal_pad - theme.scaledUi(8.0),
        .h = theme.scaledUi(16.0),
    }, "Stored in verde.json", paletteColor(textLabel()), theme.scaledUi(12.5), layout.modal);

    if (dirty) {
        const pill_w = theme.scaledUi(80.0);
        const pill_h = theme.scaledUi(20.0);
        const pill: palette.Rect = .{
            .x = layout.close.x - pill_w - theme.scaledUi(10.0),
            .y = layout.header.y + (m.header_h - pill_h) * 0.5,
            .w = pill_w,
            .h = pill_h,
        };
        queueRoundedRect(state, pill, paletteColor(theme.withAlpha(theme.COLOR_YELLOW, 36)), radiusSm());
        queueCenteredText(state, pill, "Unsaved", paletteColor(theme.COLOR_YELLOW), theme.scaledUi(11.0), layout.modal);
    }

    drawIconButton(state, layout.close, "×", state.settings_controller.close_hovered);
}

fn drawFooterBar(state: *runtime.AppState, layout: SettingsLayout, dirty: bool) void {
    const m = metrics();
    drawEdgeStrip(state, layout.footer, theme.darken(theme.COLOR_PANEL, 0.03), false);
    drawHairline(state, layout.footer.x, layout.footer.y, layout.footer.w);

    if (app_config.resolveConfigPath(state.allocator)) |config_path| {
        defer state.allocator.free(config_path);
        queueText(state, .{
            .x = layout.footer.x + m.modal_pad,
            .y = layout.footer.y + (m.footer_h - theme.scaledUi(16.0)) * 0.5,
            .w = layout.cancel.x - layout.footer.x - m.modal_pad - theme.scaledUi(10.0),
            .h = theme.scaledUi(16.0),
        }, config_path, paletteColor(textHint()), theme.scaledUi(11.5), layout.modal);
    } else |_| {}

    drawFooterButton(state, layout.cancel, "Cancel", .secondary);
    drawFooterButton(state, layout.save, "Save", if (dirty) .primary else .secondary);
}

const FooterStyle = enum { primary, secondary };

fn drawCard(state: *runtime.AppState, rect: palette.Rect, clip: palette.Rect) void {
    queueRoundedRectClipped(state, rect, paletteColor(cardSurface()), radiusMd(), clip);
}

fn drawCardTitle(state: *runtime.AppState, card: palette.Rect, title: []const u8, clip: palette.Rect) void {
    const m = metrics();
    queueText(state, .{
        .x = card.x + m.card_pad,
        .y = card.y + m.card_pad,
        .w = card.w - m.card_pad * 2.0,
        .h = m.title_h,
    }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(15.0), clip);
}

fn drawFieldLabel(state: *runtime.AppState, card: palette.Rect, m: Metrics, label: []const u8, clip: palette.Rect) void {
    queueText(state, .{
        .x = card.x + m.card_pad,
        .y = card.y + m.card_pad + m.title_h + m.row_gap,
        .w = card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, label, paletteColor(textLabel()), theme.scaledUi(12.5), clip);
}

// Appearance theme selector control.
fn drawThemeDropdown(state: *runtime.AppState, layout: SettingsLayout) void {
    const rect = layout.theme_dropdown;
    const hovered = isControlHovered(state, .theme_dropdown);
    const background = if (state.settings_controller.theme_dropdown_open)
        theme.withAlpha(theme.accent(), 34)
    else if (hovered)
        controlHoverSurface()
    else
        controlSurface();
    queueRoundedRectClipped(state, rect, paletteColor(background), radiusSm(), layout.body_clip);
    queueBorderClipped(state, rect, paletteColor(if (state.settings_controller.theme_dropdown_open) theme.withAlpha(theme.accent(), 150) else theme.withAlpha(theme.COLOR_WHITE, 24)), radiusSm(), theme.scaledUi(1.0), layout.body_clip);

    const selected = @min(state.settings_controller.draft.theme_choice, state.settingsThemeChoiceCount() - 1);
    queueText(state, .{
        .x = rect.x + theme.scaledUi(10.0),
        .y = rect.y + (rect.h - theme.scaledUi(15.0)) * 0.5,
        .w = rect.w - theme.scaledUi(38.0),
        .h = theme.scaledUi(15.0),
    }, state.settingsThemeChoiceLabel(selected), paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), layout.body_clip);
    const chevron_size = theme.scaledUi(14.0);
    queueIconText(state, .{
        .x = rect.x + rect.w - theme.scaledUi(18.0),
        .y = rect.y + (rect.h - chevron_size) * 0.5,
        .w = chevron_size,
        .h = chevron_size,
    }, if (state.settings_controller.theme_dropdown_open) NF_COD_CHEVRON_UP else NF_COD_CHEVRON_DOWN, paletteColor(textLabel()), chevron_size, layout.body_clip);
}

// Appearance theme selector popup rows.
fn drawThemeDropdownMenu(state: *runtime.AppState, layout: SettingsLayout) void {
    if (!state.settings_controller.theme_dropdown_open) return;
    const menu = themeMenuRect(state, layout);
    queueRoundedRectClipped(state, menu, paletteColor(raisedSurface(0.14)), radiusSm(), layout.body_clip);
    queueBorderClipped(state, menu, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 34)), radiusSm(), theme.scaledUi(1.0), layout.body_clip);

    for (0..themeMenuVisibleCount(state)) |visible_index| {
        const choice_index = state.settings_controller.theme_menu_scroll + visible_index;
        const row = themeOptionRect(state, layout, visible_index);
        const selected = choice_index == state.settings_controller.draft.theme_choice;
        const hovered = state.settings_controller.theme_hover_index == choice_index;
        if (selected or hovered) {
            const color = if (selected) theme.withAlpha(theme.accent(), 38) else controlHoverSurface();
            queueRoundedRectClipped(state, row, paletteColor(color), theme.scaledUi(4.0), layout.body_clip);
        }

        const dot_size = theme.scaledUi(6.0);
        const dot_color = if (selected) theme.accent() else theme.withAlpha(theme.COLOR_TEXT_MUTED, 110);
        queueRoundedRectClipped(state, .{
            .x = row.x + theme.scaledUi(10.0),
            .y = row.y + (row.h - dot_size) * 0.5,
            .w = dot_size,
            .h = dot_size,
        }, paletteColor(dot_color), dot_size * 0.5, layout.body_clip);
        queueText(state, .{
            .x = row.x + theme.scaledUi(25.0),
            .y = row.y + (row.h - theme.scaledUi(15.0)) * 0.5,
            .w = row.w - theme.scaledUi(42.0),
            .h = theme.scaledUi(15.0),
        }, state.settingsThemeChoiceLabel(choice_index), paletteColor(if (selected or hovered) theme.COLOR_WHITE else textLabel()), theme.scaledUi(13.0), layout.body_clip);
    }

    const count = state.settingsThemeChoiceCount();
    const visible_count = themeMenuVisibleCount(state);
    if (count > visible_count) {
        const track: palette.Rect = .{
            .x = menu.x + menu.w - theme.scaledUi(5.0),
            .y = menu.y + theme.scaledUi(4.0),
            .w = theme.scaledUi(2.0),
            .h = menu.h - theme.scaledUi(8.0),
        };
        const thumb_h = track.h * @as(f32, @floatFromInt(visible_count)) / @as(f32, @floatFromInt(count));
        const travel = track.h - thumb_h;
        const max_scroll = themeMenuMaxScroll(state);
        const progress = @as(f32, @floatFromInt(state.settings_controller.theme_menu_scroll)) / @as(f32, @floatFromInt(max_scroll));
        queueRoundedRectClipped(state, track, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 20)), theme.scaledUi(1.0), layout.body_clip);
        queueRoundedRectClipped(state, .{ .x = track.x, .y = track.y + travel * progress, .w = track.w, .h = thumb_h }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 100)), theme.scaledUi(1.0), layout.body_clip);
    }
}

// Chat title provider/model selector control.
fn drawChatTitleDropdown(
    state: *runtime.AppState,
    rect: palette.Rect,
    label: []const u8,
    control: Control,
    open: bool,
    clip: palette.Rect,
) void {
    const background = if (open)
        theme.withAlpha(theme.accent(), 34)
    else if (isControlHovered(state, control))
        controlHoverSurface()
    else
        controlSurface();
    queueRoundedRectClipped(state, rect, paletteColor(background), radiusSm(), clip);
    queueBorderClipped(state, rect, paletteColor(if (open) theme.withAlpha(theme.accent(), 150) else theme.withAlpha(theme.COLOR_WHITE, 24)), radiusSm(), theme.scaledUi(1.0), clip);
    queueText(state, .{
        .x = rect.x + theme.scaledUi(10.0),
        .y = rect.y + (rect.h - theme.scaledUi(15.0)) * 0.5,
        .w = rect.w - theme.scaledUi(38.0),
        .h = theme.scaledUi(15.0),
    }, label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), clip);
    const chevron_size = theme.scaledUi(14.0);
    queueIconText(state, .{
        .x = rect.x + rect.w - theme.scaledUi(18.0),
        .y = rect.y + (rect.h - chevron_size) * 0.5,
        .w = chevron_size,
        .h = chevron_size,
    }, if (open) NF_COD_CHEVRON_UP else NF_COD_CHEVRON_DOWN, paletteColor(textLabel()), chevron_size, clip);
}

// Chat title provider/model popup rows.
fn drawChatTitleDropdownMenu(state: *runtime.AppState, layout: SettingsLayout, provider_menu: bool) void {
    const open = if (provider_menu) state.settings_controller.title_provider_dropdown_open else state.settings_controller.title_model_dropdown_open;
    if (!open) return;
    const count = if (provider_menu) state.settingsChatTitleProviderCount() else state.settingsChatTitleModelCount();
    const visible_count = if (provider_menu) count else titleModelMenuVisibleCount(state);
    const scroll = if (provider_menu) 0 else state.settings_controller.title_model_menu_scroll;
    const menu = if (provider_menu) titleProviderMenuRect(state, layout) else titleModelMenuRect(state, layout);
    queueRoundedRectClipped(state, menu, paletteColor(raisedSurface(0.14)), radiusSm(), layout.body_clip);
    queueBorderClipped(state, menu, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 34)), radiusSm(), theme.scaledUi(1.0), layout.body_clip);

    const selected_index = if (provider_menu) state.settingsChatTitleProviderSelectedIndex() else state.settingsChatTitleModelSelectedIndex() orelse std.math.maxInt(usize);
    for (0..visible_count) |visible_index| {
        const option_index = scroll + visible_index;
        const row = dropdownOptionRect(menu, visible_index);
        const selected = option_index == selected_index;
        const hovered = state.settings_controller.title_menu_hover_index == option_index;
        if (selected or hovered) {
            const color = if (selected) theme.withAlpha(theme.accent(), 38) else controlHoverSurface();
            queueRoundedRectClipped(state, row, paletteColor(color), theme.scaledUi(4.0), layout.body_clip);
        }

        const dot_size = theme.scaledUi(6.0);
        const dot_color = if (selected) theme.accent() else theme.withAlpha(theme.COLOR_TEXT_MUTED, 110);
        queueRoundedRectClipped(state, .{
            .x = row.x + theme.scaledUi(10.0),
            .y = row.y + (row.h - dot_size) * 0.5,
            .w = dot_size,
            .h = dot_size,
        }, paletteColor(dot_color), dot_size * 0.5, layout.body_clip);
        const label = if (provider_menu) state.settingsChatTitleProviderLabel(option_index) else state.settingsChatTitleModelLabel(option_index);
        queueText(state, .{
            .x = row.x + theme.scaledUi(25.0),
            .y = row.y + (row.h - theme.scaledUi(15.0)) * 0.5,
            .w = row.w - theme.scaledUi(42.0),
            .h = theme.scaledUi(15.0),
        }, label, paletteColor(if (selected or hovered) theme.COLOR_WHITE else textLabel()), theme.scaledUi(13.0), layout.body_clip);
    }

    if (!provider_menu and count > visible_count) {
        const track: palette.Rect = .{
            .x = menu.x + menu.w - theme.scaledUi(5.0),
            .y = menu.y + theme.scaledUi(4.0),
            .w = theme.scaledUi(2.0),
            .h = menu.h - theme.scaledUi(8.0),
        };
        const thumb_h = track.h * @as(f32, @floatFromInt(visible_count)) / @as(f32, @floatFromInt(count));
        const travel = track.h - thumb_h;
        const progress = @as(f32, @floatFromInt(scroll)) / @as(f32, @floatFromInt(titleModelMenuMaxScroll(state)));
        queueRoundedRectClipped(state, track, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 20)), theme.scaledUi(1.0), layout.body_clip);
        queueRoundedRectClipped(state, .{ .x = track.x, .y = track.y + travel * progress, .w = track.w, .h = thumb_h }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 100)), theme.scaledUi(1.0), layout.body_clip);
    }
}

fn drawToggleCell(state: *runtime.AppState, rect: palette.Rect, label: []const u8, selected: bool, hovered: bool, clip: palette.Rect) void {
    const bg = if (selected)
        theme.withAlpha(theme.accent(), 44)
    else if (hovered)
        controlHoverSurface()
    else
        controlSurface();
    queueRoundedRectClipped(state, rect, paletteColor(bg), radiusSm(), clip);
    // Unselected cells need a visible edge or they read as disabled.
    const border = if (selected) theme.withAlpha(theme.accent(), 140) else theme.withAlpha(theme.COLOR_WHITE, 26);
    queueBorderClipped(state, rect, paletteColor(border), radiusSm(), theme.scaledUi(1.0), clip);

    const dot_size = theme.scaledUi(7.0);
    const dot_x = rect.x + theme.scaledUi(10.0);
    const dot_y = rect.y + (rect.h - dot_size) * 0.5;
    const dot_color = if (selected) theme.accent() else theme.withAlpha(theme.COLOR_TEXT_MUTED, 180);
    queueRoundedRectClipped(state, .{ .x = dot_x, .y = dot_y, .w = dot_size, .h = dot_size }, paletteColor(dot_color), theme.scaledUi(3.5), clip);

    const text_color = if (selected or hovered) theme.COLOR_WHITE else textLabel();
    queueText(state, .{
        .x = rect.x + theme.scaledUi(24.0),
        .y = rect.y + (rect.h - theme.scaledUi(16.0)) * 0.5,
        .w = rect.w - theme.scaledUi(28.0),
        .h = theme.scaledUi(16.0),
    }, label, paletteColor(text_color), theme.scaledUi(13.0), clip);
}

// Boolean setting row: label on the left, switch track on the right.
fn drawSwitchRow(state: *runtime.AppState, rect: palette.Rect, label: []const u8, on: bool, hovered: bool, clip: palette.Rect) void {
    if (hovered) {
        queueRoundedRectClipped(state, rect, paletteColor(controlHoverSurface()), radiusSm(), clip);
    }
    queueText(state, .{
        .x = rect.x + theme.scaledUi(10.0),
        .y = rect.y + (rect.h - theme.scaledUi(16.0)) * 0.5,
        .w = rect.w - theme.scaledUi(70.0),
        .h = theme.scaledUi(16.0),
    }, label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), clip);

    const track_w = theme.scaledUi(40.0);
    const track_h = theme.scaledUi(22.0);
    const track: palette.Rect = .{
        .x = rect.x + rect.w - theme.scaledUi(10.0) - track_w,
        .y = rect.y + (rect.h - track_h) * 0.5,
        .w = track_w,
        .h = track_h,
    };
    const track_color = if (on) theme.withAlpha(theme.accent(), 200) else controlSurface();
    queueRoundedRectClipped(state, track, paletteColor(track_color), track_h * 0.5, clip);
    if (!on) {
        queueBorderClipped(state, track, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 34)), track_h * 0.5, theme.scaledUi(1.0), clip);
    }

    const knob_pad = theme.scaledUi(3.0);
    const knob = track_h - knob_pad * 2.0;
    const knob_x = if (on) track.x + track.w - knob_pad - knob else track.x + knob_pad;
    const knob_color = if (on) theme.foregroundOn(theme.accent()) else theme.withAlpha(theme.COLOR_WHITE, 190);
    queueRoundedRectClipped(state, .{ .x = knob_x, .y = track.y + knob_pad, .w = knob, .h = knob }, paletteColor(knob_color), knob * 0.5, clip);
}

// Two-option exclusive choice rendered as one segmented control.
fn drawSegmentedPair(
    state: *runtime.AppState,
    left: palette.Rect,
    right: palette.Rect,
    left_label: []const u8,
    right_label: []const u8,
    left_selected: bool,
    left_hovered: bool,
    right_hovered: bool,
    clip: palette.Rect,
) void {
    const container: palette.Rect = .{ .x = left.x, .y = left.y, .w = left.w + right.w, .h = left.h };
    queueRoundedRectClipped(state, container, paletteColor(controlSurface()), radiusSm(), clip);
    queueBorderClipped(state, container, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 26)), radiusSm(), theme.scaledUi(1.0), clip);

    if (left_hovered and !left_selected) {
        queueRoundedRectClipped(state, left, paletteColor(controlHoverSurface()), radiusSm(), clip);
    }
    if (right_hovered and left_selected) {
        queueRoundedRectClipped(state, right, paletteColor(controlHoverSurface()), radiusSm(), clip);
    }
    const selected_rect = if (left_selected) left else right;
    queueRoundedRectClipped(state, selected_rect, paletteColor(theme.withAlpha(theme.accent(), 44)), radiusSm(), clip);
    queueBorderClipped(state, selected_rect, paletteColor(theme.withAlpha(theme.accent(), 150)), radiusSm(), theme.scaledUi(1.0), clip);

    const left_color = if (left_selected or left_hovered) theme.COLOR_WHITE else textLabel();
    const right_color = if (!left_selected or right_hovered) theme.COLOR_WHITE else textLabel();
    queueCenteredText(state, left, left_label, paletteColor(left_color), theme.scaledUi(13.0), clip);
    queueCenteredText(state, right, right_label, paletteColor(right_color), theme.scaledUi(13.0), clip);
}

// Three-option exclusive choice rendered as one segmented control.
fn drawSegmentedTriple(
    state: *runtime.AppState,
    first: palette.Rect,
    second: palette.Rect,
    third: palette.Rect,
    labels: [3][]const u8,
    selected_index: usize,
    hovered: [3]bool,
    clip: palette.Rect,
) void {
    const segments = [3]palette.Rect{ first, second, third };
    const container: palette.Rect = .{ .x = first.x, .y = first.y, .w = first.w + second.w + third.w, .h = first.h };
    queueRoundedRectClipped(state, container, paletteColor(controlSurface()), radiusSm(), clip);
    queueBorderClipped(state, container, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 26)), radiusSm(), theme.scaledUi(1.0), clip);

    for (segments, 0..) |segment, index| {
        if (hovered[index] and index != selected_index) {
            queueRoundedRectClipped(state, segment, paletteColor(controlHoverSurface()), radiusSm(), clip);
        }
    }
    const selected = segments[@min(selected_index, segments.len - 1)];
    queueRoundedRectClipped(state, selected, paletteColor(theme.withAlpha(theme.accent(), 44)), radiusSm(), clip);
    queueBorderClipped(state, selected, paletteColor(theme.withAlpha(theme.accent(), 150)), radiusSm(), theme.scaledUi(1.0), clip);

    for (segments, labels, 0..) |segment, label, index| {
        const color = if (index == selected_index or hovered[index]) theme.COLOR_WHITE else textLabel();
        queueCenteredText(state, segment, label, paletteColor(color), theme.scaledUi(13.0), clip);
    }
}

const ButtonStyle = enum { primary, secondary, disabled };

// Push button for immediate actions (update check/install), with a real
// disabled look so inert states don't read as clickable pills.
fn drawActionButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, style: ButtonStyle, hovered: bool, clip: palette.Rect) void {
    var button_fill: ?[4]f32 = null;
    switch (style) {
        .primary => {
            const accent = theme.accent();
            const bg = if (hovered) theme.mix(accent, theme.foregroundOn(accent), 0.10) else accent;
            button_fill = bg;
            queueRoundedRectClipped(state, rect, paletteColor(bg), radiusSm(), clip);
        },
        .secondary => {
            const bg = if (hovered) controlHoverSurface() else controlSurface();
            queueRoundedRectClipped(state, rect, paletteColor(bg), radiusSm(), clip);
            queueBorderClipped(state, rect, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 30)), radiusSm(), theme.scaledUi(1.0), clip);
        },
        .disabled => {
            queueBorderClipped(state, rect, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 16)), radiusSm(), theme.scaledUi(1.0), clip);
        },
    }
    const text_color = if (style == .disabled)
        textHint()
    else if (button_fill) |fill|
        theme.foregroundOn(fill)
    else
        theme.COLOR_WHITE;
    queueCenteredText(state, rect, label, paletteColor(text_color), theme.scaledUi(13.0), clip);
}

// Thin overlay scrollbar so overflow in the modal body is discoverable.
fn drawBodyScrollbar(state: *runtime.AppState, layout: SettingsLayout) void {
    if (layout.max_scroll_y <= 0.0) return;
    const track: palette.Rect = .{
        .x = layout.modal.x + layout.modal.w - theme.scaledUi(7.0),
        .y = layout.body_clip.y + theme.scaledUi(6.0),
        .w = theme.scaledUi(3.0),
        .h = layout.body_clip.h - theme.scaledUi(12.0),
    };
    if (track.h <= 0.0) return;
    const view_ratio = layout.body_clip.h / (layout.body_clip.h + layout.max_scroll_y);
    const thumb_h = @max(track.h * view_ratio, theme.scaledUi(24.0));
    const travel = @max(track.h - thumb_h, 0.0);
    const progress = state.settings_controller.scroll_y / layout.max_scroll_y;
    queueRoundedRect(state, track, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 16)), track.w * 0.5);
    queueRoundedRect(state, .{ .x = track.x, .y = track.y + travel * progress, .w = track.w, .h = thumb_h }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 90)), track.w * 0.5);
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
    }, label, paletteColor(textLabel()), theme.scaledUi(13.5), clip);

    const pill_x = dec_rect.x;
    const pill: palette.Rect = .{ .x = pill_x, .y = row_y, .w = m.stepperW(), .h = m.row_h };
    queueRoundedRectClipped(state, pill, paletteColor(controlSurface()), radiusSm(), clip);

    var value_buf: [8]u8 = undefined;
    const value_text = std.fmt.bufPrint(&value_buf, "{d:.0}", .{value}) catch "?";
    const value_rect: palette.Rect = .{ .x = dec_rect.x + m.step_w, .y = row_y, .w = m.value_w, .h = m.row_h };
    queueRoundedRectClipped(state, .{ .x = dec_rect.x + m.step_w - 0.5, .y = row_y + theme.scaledUi(6.0), .w = 1.0, .h = m.row_h - theme.scaledUi(12.0) }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 24)), 0.0, clip);
    queueRoundedRectClipped(state, .{ .x = inc_rect.x - 0.5, .y = row_y + theme.scaledUi(6.0), .w = 1.0, .h = m.row_h - theme.scaledUi(12.0) }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 24)), 0.0, clip);
    queueCenteredText(state, value_rect, value_text, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), clip);

    const at_min = value <= min_value;
    const at_max = value >= max_value;
    drawStepButton(state, dec_rect, "−", !at_min, isControlHovered(state, dec_control), clip);
    drawStepButton(state, inc_rect, "+", !at_max, isControlHovered(state, inc_control), clip);
}

fn drawStepButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, enabled: bool, hovered: bool, clip: palette.Rect) void {
    if (hovered and enabled) {
        queueRoundedRectClipped(state, rect, paletteColor(controlHoverSurface()), theme.scaledUi(5.0), clip);
    }
    const text_color = if (enabled) theme.COLOR_WHITE else textHint();
    queueCenteredText(state, rect, label, paletteColor(text_color), theme.scaledUi(15.0), clip);
}

fn drawFooterButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, style: FooterStyle) void {
    const bg: [4]f32 = switch (style) {
        .primary => theme.accent(),
        .secondary => controlSurface(),
    };
    const text_color: [4]f32 = switch (style) {
        .primary => theme.foregroundOn(bg),
        .secondary => theme.COLOR_WHITE,
    };
    queueRoundedRect(state, rect, paletteColor(bg), radiusMd());
    queueCenteredText(state, rect, label, paletteColor(text_color), theme.scaledUi(13.5), rect);
}

fn drawIconButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, hovered: bool) void {
    if (hovered) {
        queueRoundedRect(state, rect, paletteColor(controlHoverSurface()), radiusSm());
    }
    queueCenteredText(state, rect, label, paletteColor(if (hovered) theme.COLOR_WHITE else textLabel()), theme.scaledUi(17.0), rect);
}

// Header/footer chrome strip. The fill is inset by the modal border width and
// follows the modal corner radius on its outer edge, then the inner edge is
// squared off — a plain squared fill overpaints the rounded corners and the
// 1px modal border, which reads as broken corners.
fn drawEdgeStrip(state: *runtime.AppState, bar: palette.Rect, color: [4]f32, round_top: bool) void {
    const bw = theme.scaledUi(1.0);
    const strip: palette.Rect = .{
        .x = bar.x + bw,
        .y = if (round_top) bar.y + bw else bar.y,
        .w = bar.w - bw * 2.0,
        .h = bar.h - bw,
    };
    queueRoundedRect(state, strip, paletteColor(color), radiusLg());
    const patch_h = @min(radiusLg(), strip.h * 0.5);
    const patch: palette.Rect = if (round_top)
        .{ .x = strip.x, .y = strip.y + strip.h - patch_h, .w = strip.w, .h = patch_h }
    else
        .{ .x = strip.x, .y = strip.y, .w = strip.w, .h = patch_h };
    queueRoundedRect(state, patch, paletteColor(color), 0.0);
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

fn queueRoundedRectClipped(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, clip: palette.Rect) void {
    if (intersectRect(rect, clip) == null) return;
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, color, radius, clip) catch |err| {
        log.warn("failed to queue clipped settings rounded rect: {s}", .{@errorName(err)});
    };
}

fn queueBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch |err| {
        log.warn("failed to queue settings border: {s}", .{@errorName(err)});
    };
}

fn queueBorderClipped(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32, clip: palette.Rect) void {
    if (intersectRect(rect, clip) == null) return;
    state.palette_overlay_batch.rectBorderClipped(state.allocator, rect, color, radius, width, clip) catch |err| {
        log.warn("failed to queue clipped settings border: {s}", .{@errorName(err)});
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

// Same as `queueText` but wraps at the rect width for multi-line hint copy.
fn queueWrappedText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
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
        true,
    ) catch |err| {
        log.warn("failed to queue settings text: {s}", .{@errorName(err)});
    };
}

fn queueIconText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = state.palette_frame_text_arena.allocator().dupe(u8, value) catch |err| {
        log.warn("failed to retain settings icon: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.roleText(
        state.allocator,
        rect,
        stable_value,
        color,
        font_size,
        .icon,
        null,
        clip,
    ) catch |err| {
        log.warn("failed to queue settings icon: {s}", .{@errorName(err)});
    };
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn intersectRect(a: palette.Rect, b: palette.Rect) ?palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] * current_fade_alpha };
}
