//! Settings modal for viewing and editing `verde.json` app config.

const std = @import("std");
const build_options = @import("build_options");
const palette = @import("palette");
const host = @import("host.zig");
const app_config = @import("../app/config.zig");
const provider_cli_version = @import("../providers/cli_version.zig");
const phone_pairing = @import("../state/phone_pairing.zig");
const remote_access = @import("../state/remote_access.zig");
const settings_text = @import("settings_text_selection.zig");
const settings_controller = @import("../state/settings_controller.zig");
const custom_agent_form_state = @import("../state/custom_agent_form.zig");
const updater = @import("../app/updater.zig");
const theme = @import("theme.zig");
const runtime = @import("runtime.zig");
const text_measure = @import("text_measure.zig");
const utils = @import("../utils.zig");
const runtime_connections = @import("../state/runtime_connections_controller.zig");
const keybinds = @import("../app/keybinds.zig");

pub const Control = enum(u8) {
    ui_font_dec,
    ui_font_inc,
    terminal_font_dec,
    terminal_font_inc,
    workspace_pane_gap_dec,
    workspace_pane_gap_inc,
    workspace_panes_per_view_dec,
    workspace_panes_per_view_inc,
    workspace_unzoom_on_navigation,
    workspace_scroll_use_global,
    workspace_scroll_override,
    workspace_scroll_mode_automatic,
    workspace_scroll_mode_always,
    workspace_scroll_mode_disabled,
    workspace_scroll_threshold_dec,
    workspace_scroll_threshold_inc,
    workspace_scroll_horizontal,
    workspace_scroll_vertical,
    theme_dropdown,
    reduced_motion,
    reduced_motion_pane_scroll,
    reduced_motion_pane_layout,
    reduced_motion_status_pulse,
    reduced_motion_chat,
    reduced_motion_chrome,
    reduced_motion_companion,
    workspace_tabs_automatic,
    workspace_tabs_always,
    workspace_tabs_disabled,
    companion_character_dropdown,
    tool_groups_collapsed,
    tool_groups_expanded,
    tool_groups_remember_last,
    diff_layout_stacked,
    diff_layout_split,
    automatic_chat_titles,
    chat_title_provider_dropdown,
    chat_title_model_dropdown,
    new_chat_provider_dropdown,
    new_chat_model_dropdown,
    new_chat_reasoning_dropdown,
    commit_provider_dropdown,
    commit_model_dropdown,
    commit_action_commit,
    commit_action_push,
    new_chat_new_pane,
    new_chat_replace_pane,
    workspace_split_default_chat,
    workspace_split_default_terminal,
    workspace_new_tab_chat,
    workspace_new_tab_terminal,
    open_folder,
    open_editor,
    open_cursor,
    open_vscode,
    open_zed,
    open_action_dropdown,
    file_links_neovim_pane,
    links_verde_browser,
    links_system_browser,
    chat_links_global,
    chat_links_verde_browser,
    chat_links_system_browser,
    terminal_links_global,
    terminal_links_verde_browser,
    terminal_links_system_browser,
    browser_scroll_speed,
    companion_toggle,
    mcp_tools,
    hooks_claude,
    hooks_codex,
    hooks_cursor,
    hooks_opencode,
    hooks_grok,
    hooks_amp,
    hooks_pi,
    updates_check,
    updates_download,
    updates_automatic,
    updates_notes_toggle,
    updates_release_page,
    notifications_toggle,
    providers_recheck,
    providers_update_all,
    navigation_back_record,
    navigation_back_reset,
    navigation_forward_record,
    navigation_forward_reset,
    // One per settings_controller.PROVIDER_OPTIONS row. Each group stays contiguous.
    provider_update_first,
    provider_update_1,
    provider_update_2,
    provider_update_3,
    provider_update_4,
    provider_update_5,
    provider_update_6,
    provider_update_last,
    provider_row_first,
    provider_row_1,
    provider_row_2,
    provider_row_3,
    provider_row_4,
    provider_row_5,
    provider_row_6,
    provider_row_last,
};

const PROVIDER_ROW_COUNT = settings_controller.PROVIDER_OPTIONS.len;

comptime {
    std.debug.assert(@intFromEnum(Control.provider_row_last) - @intFromEnum(Control.provider_row_first) + 1 == PROVIDER_ROW_COUNT);
    std.debug.assert(@intFromEnum(Control.provider_update_last) - @intFromEnum(Control.provider_update_first) + 1 == PROVIDER_ROW_COUNT);
}

fn providerRowControl(row: usize) Control {
    return @enumFromInt(@intFromEnum(Control.provider_row_first) + @as(u8, @intCast(row)));
}

fn providerUpdateControl(row: usize) Control {
    return @enumFromInt(@intFromEnum(Control.provider_update_first) + @as(u8, @intCast(row)));
}

fn providerUpdateRowForControl(control: Control) ?usize {
    const index = @intFromEnum(control);
    if (index < @intFromEnum(Control.provider_update_first) or index > @intFromEnum(Control.provider_update_last)) return null;
    return index - @intFromEnum(Control.provider_update_first);
}

fn providerRowForControl(control: Control) ?usize {
    const index = @intFromEnum(control);
    if (index < @intFromEnum(Control.provider_row_first) or index > @intFromEnum(Control.provider_row_last)) return null;
    return index - @intFromEnum(Control.provider_row_first);
}

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
const COMPANION_CHARACTER_OPTIONS = [_]app_config.CompanionCharacter{ .sprout, .moss, .vireo };
const COMPANION_CHARACTER_LABELS = [_][]const u8{ "Sprout", "Moss", "Vireo" };
const COMPANION_HINT = "Shows running agents and what needs you.";
const NF_COD_CHEVRON_DOWN = "\u{EAB4}";
/// Parks controls of inactive pages/rows above the panel.
const OFFSCREEN_Y: f32 = -10000.0;
const NF_COD_CHEVRON_UP = "\u{EAB7}";

const Metrics = struct {
    modal_pad: f32,
    header_h: f32,
    nav_w: f32,
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
            .header_h = theme.scaledUi(52.0),
            .nav_w = theme.scaledUi(124.0),
            .footer_h = 0.0,
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
    nav: [settings_controller.Category.all.len]palette.Rect,
    content: palette.Rect,
    cancel: palette.Rect,
    save: palette.Rect,
    appearance_card: palette.Rect,
    theme_dropdown: palette.Rect,
    companion_character_label_y: f32,
    companion_character_dropdown: palette.Rect,
    ui_font_dec: palette.Rect,
    ui_font_inc: palette.Rect,
    reduced_motion: palette.Rect,
    reduced_motion_parts: [REDUCED_MOTION_PARTS.len]palette.Rect,
    reduced_motion_hint_y: f32,
    workspace_tabs_label_y: f32,
    workspace_tabs_automatic: palette.Rect,
    workspace_tabs_always: palette.Rect,
    workspace_tabs_disabled: palette.Rect,
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
    new_chat_provider_dropdown: palette.Rect,
    new_chat_model_dropdown: palette.Rect,
    new_chat_reasoning_dropdown: palette.Rect,
    new_chat_defaults_hint_y: f32,
    commit_card: palette.Rect,
    commit_provider_dropdown: palette.Rect,
    commit_model_dropdown: palette.Rect,
    commit_action_commit: palette.Rect,
    commit_action_push: palette.Rect,
    terminal_card: palette.Rect,
    terminal_font_dec: palette.Rect,
    terminal_font_inc: palette.Rect,
    terminal_hint_y: f32,
    browser_card: palette.Rect,
    links_verde_browser: palette.Rect,
    links_system_browser: palette.Rect,
    chat_links_global: palette.Rect,
    chat_links_verde_browser: palette.Rect,
    chat_links_system_browser: palette.Rect,
    terminal_links_global: palette.Rect,
    terminal_links_verde_browser: palette.Rect,
    terminal_links_system_browser: palette.Rect,
    browser_scroll_speed: palette.Rect,
    browser_hint_y: f32,
    companion_card: palette.Rect,
    companion_toggle: palette.Rect,
    companion_hint_y: f32,
    workspace_card: palette.Rect,
    open_cells: [OPEN_CHOICES.len]palette.Rect,
    open_action_dropdown: palette.Rect,
    custom_open: ?palette.Rect = null,
    new_chat_new_pane: palette.Rect,
    new_chat_replace_pane: palette.Rect,
    workspace_split_default_chat: palette.Rect,
    workspace_split_default_terminal: palette.Rect,
    workspace_split_default_hint_y: f32,
    workspace_new_tab_chat: palette.Rect,
    workspace_new_tab_terminal: palette.Rect,
    workspace_new_tab_hint_y: f32,
    file_links_neovim_pane: palette.Rect,
    file_links_hint_y: f32,
    workspace_unzoom_on_navigation: palette.Rect,
    workspace_unzoom_on_navigation_hint_y: f32,
    navigation_card: palette.Rect,
    navigation_back_record: palette.Rect,
    navigation_back_reset: palette.Rect,
    navigation_forward_record: palette.Rect,
    navigation_forward_reset: palette.Rect,
    navigation_hint_y: f32,
    workspace_pane_gap_dec: palette.Rect,
    workspace_pane_gap_inc: palette.Rect,
    workspace_pane_gap_hint_y: f32,
    workspace_panes_per_view_dec: palette.Rect,
    workspace_panes_per_view_inc: palette.Rect,
    workspace_panes_per_view_hint_y: f32,
    workspace_scroll_use_global: palette.Rect,
    workspace_scroll_override: palette.Rect,
    workspace_scroll_scope_hint_y: f32,
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
    phone_card: palette.Rect,
    runtimes_card: palette.Rect,
    runtimes: RuntimeCardPlan,
    integrations_card: palette.Rect,
    mcp_tools: palette.Rect,
    mcp_hint_y: f32,
    mcp_note_y: f32,
    hooks_label_y: f32,
    hooks_claude: palette.Rect,
    hooks_codex: palette.Rect,
    hooks_cursor: palette.Rect,
    hooks_opencode: palette.Rect,
    hooks_grok: palette.Rect,
    hooks_amp: palette.Rect,
    hooks_pi: palette.Rect,
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
    providers_card: palette.Rect,
    provider_rows: [PROVIDER_ROW_COUNT]palette.Rect,
    provider_updates: [PROVIDER_ROW_COUNT]palette.Rect,
    providers_hint_y: f32,
    providers_update_hint_y: f32,
    providers_recheck: palette.Rect,
    /// Zero width when no provider has an update waiting.
    providers_update_all: palette.Rect,
    custom_agents_card: palette.Rect,
    custom_agents_subtitle_y: f32,
    custom_agent_rows: [MAX_CUSTOM_AGENT_ROWS]palette.Rect,
    custom_agent_edits: [MAX_CUSTOM_AGENT_ROWS]palette.Rect,
    custom_agent_removes: [MAX_CUSTOM_AGENT_ROWS]palette.Rect,
    custom_agent_count: usize,
    custom_agents_empty_y: f32,
    custom_agents_add: palette.Rect,
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

fn sidebarDockWidth(state: *const runtime.AppState, width: f32) f32 {
    if (state.isSidebarHidden()) return 0.0;
    if (state.isSidebarCollapsed()) return theme.clampf(width * 0.07, theme.scaledUi(60.0), theme.scaledUi(76.0));
    if (width < theme.scaledUi(900.0)) return theme.clampf(width * 0.34, theme.scaledUi(180.0), theme.scaledUi(240.0));
    return theme.clampf(width * 0.19, theme.scaledUi(260.0), @min(theme.scaledUi(360.0), width * 0.32));
}

fn panelWidth(state: *const runtime.AppState, width: f32, dock_x: f32) f32 {
    const preferred = if (state.settings_controller.active_category == .connections)
        theme.scaledUi(760.0)
    else
        theme.scaledUi(560.0);
    const max_w = @max(width - dock_x - theme.scaledUi(12.0), theme.scaledUi(300.0));
    return @min(preferred, max_w);
}

fn layoutPanel(state: *const runtime.AppState, width: f32, height: f32) palette.Rect {
    const dock_x = sidebarDockWidth(state, width);
    const modal_w = panelWidth(state, width, dock_x);
    return .{
        .x = dock_x,
        .y = 0.0,
        .w = modal_w,
        .h = height,
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

/// Scrolls a Connect account tile the wizard redirected to into view once.
/// Returns true when the layout must be recomputed.
fn consumePendingRuntimesScroll(state: *runtime.AppState, layout: SettingsLayout) bool {
    const accounts = &state.runtime_connections.accounts;
    const focus = accounts.focus_account orelse return false;
    if (state.settings_controller.active_category != .connections) return false;
    accounts.focus_account = null;
    const plan = &layout.runtimes;
    for (plan.rows[0..plan.row_count]) |row_plan| {
        if (row_plan.kind != .account or row_plan.entry.account != focus) continue;
        const margin = theme.scaledUi(12.0);
        const target = state.settings_controller.scroll_y + (row_plan.tile.y - (layout.body_clip.y + margin));
        state.settings_controller.scroll_y = theme.clampf(target, 0.0, layout.max_scroll_y);
        return true;
    }
    return false;
}

fn computeLayout(state: *runtime.AppState, width: f32, height: f32) SettingsLayout {
    const m = metrics();
    const labeled = m.label_h + m.inner_gap + m.row_h;
    const companion_enabled = state.settings_controller.draft.companion_enabled;
    const auto_titles = state.settings_controller.draft.automatic_chat_titles_enabled;
    const auto_scroll = state.settings_controller.draft.workspace_scroll_mode == .automatic;

    const appearance_h = m.card_pad * 2.0 + m.title_h + m.row_gap +
        labeled + m.row_gap +
        m.row_h + m.row_gap +
        m.row_h + m.row_gap +
        @as(f32, @floatFromInt(REDUCED_MOTION_PARTS.len)) * (m.row_h + m.row_gap) -
        m.row_gap;
    const companion_h = m.card_pad * 2.0 + m.title_h + m.row_gap +
        m.row_h + m.inner_gap + m.label_h +
        if (companion_enabled) m.row_gap + labeled else 0.0;
    const transcript_h = m.card_pad * 2.0 + m.title_h + m.row_gap +
        labeled + m.row_gap +
        labeled;
    const chat_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.row_h +
        (if (auto_titles) m.row_gap + labeled else 0.0) +
        m.row_gap + labeled +
        m.row_gap + m.row_h;
    const commit_h = m.card_pad * 2.0 + m.title_h + m.row_gap + labeled + m.row_gap + labeled;
    const terminal_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.row_h;
    const browser_h = m.card_pad * 2.0 + m.title_h + m.row_gap +
        labeled * 4.0 + m.row_gap * 3.0;
    const workspace_h = m.card_pad * 2.0 + m.title_h + m.row_gap +
        labeled + m.row_gap +
        labeled + m.row_gap +
        labeled + m.row_gap +
        labeled + m.row_gap +
        labeled + m.row_gap +
        m.row_h + m.row_gap +
        m.row_h + m.row_gap +
        m.row_h + m.row_gap +
        labeled +
        (if (auto_scroll) m.row_gap + m.row_h else 0.0) +
        m.row_gap + labeled;
    const modal = layoutPanel(state, width, height);
    const category = state.settings_controller.active_category;
    const header: palette.Rect = .{ .x = modal.x, .y = modal.y, .w = modal.w, .h = m.header_h };
    const nav_x = modal.x + theme.scaledUi(8.0);
    const nav_y = header.y + header.h + theme.scaledUi(8.0);
    const nav_row_h = theme.scaledUi(32.0);
    var nav: [settings_controller.Category.all.len]palette.Rect = undefined;
    for (settings_controller.Category.all, 0..) |_, index| {
        nav[index] = .{
            .x = nav_x,
            .y = nav_y + @as(f32, @floatFromInt(index)) * nav_row_h,
            .w = m.nav_w,
            .h = nav_row_h - theme.scaledUi(2.0),
        };
    }
    const content_inset = theme.scaledUi(12.0);
    const content: palette.Rect = .{
        .x = modal.x + m.nav_w + content_inset,
        .y = header.y + header.h,
        .w = @max(modal.w - m.nav_w - content_inset * 2.0, theme.scaledUi(200.0)),
        .h = @max(modal.h - header.h, 0.0),
    };
    const content_w = content.w;
    // Only the Connections page shows the phone card; measuring it elsewhere is wasted shaping.
    const phone_h = if (category == .connections) phoneCard(state, .{ .x = 0, .y = 0, .w = content_w, .h = 0 }, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, false, null) else 0.0;
    const runtimes_w = content_w;
    const runtimes_h = planRuntimeCard(state, 0.0, 0.0, runtimes_w, m).height;
    const integrations_h = m.card_pad * 2.0 + m.title_h + m.row_gap * 2.0 + m.label_h * 4.0 + m.row_h * 8.0 + m.inner_gap * 10.0;
    const notifications_h = m.card_pad * 2.0 + m.title_h + m.row_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.label_h;
    const updates_notes_w = @max(content_w - m.card_pad * 2.0, theme.scaledUi(80.0));
    const updates_notes_h = notesBlockHeight(state, updates_notes_w, m);
    const package_hint_h = if (state.settings_controller.package_update_command != null) wrappedNotesRows(PACKAGE_UPDATE_HINT, updates_notes_w) * notesLineHeight() + m.label_h + m.inner_gap else 0.0;
    const updates_h = package_hint_h + m.card_pad * 2.0 + m.title_h + m.inner_gap + m.label_h + m.inner_gap + m.row_h + m.inner_gap + m.row_h + m.inner_gap + updates_notes_h + m.inner_gap + m.label_h;

    const provider_rows_h = @as(f32, @floatFromInt(PROVIDER_ROW_COUNT)) * providerRowHeight();
    const providers_h = m.card_pad * 2.0 + m.title_h + m.row_gap + provider_rows_h + m.label_h * 2.0 + m.row_gap + m.row_h;
    const custom_agent_count = @min(state.app_config.custom_acp_agents.len, MAX_CUSTOM_AGENT_ROWS);
    const custom_agents_h = customAgentsCardHeight(custom_agent_count, content_w, m);
    const appearance_page_h = appearance_h;
    const chat_page_h = transcript_h + m.card_gap + chat_h + m.card_gap + commit_h;
    const navigation_h = navigationCardHeight(m);
    const workspace_page_h = workspace_h + m.card_gap + navigation_h;
    const app_page_h = updates_h + m.card_gap + notifications_h;
    const body_h = switch (category) {
        .appearance => appearance_page_h,
        .companion => companion_h,
        .workspace => workspace_page_h,
        .chat => chat_page_h,
        .providers => providers_h + m.card_gap + custom_agents_h,
        .terminal => terminal_h,
        .browser => browser_h,
        .connections => phone_h + m.card_gap + runtimes_h,
        .agents => integrations_h,
        .app => app_page_h,
    };

    const footer: palette.Rect = .{ .x = modal.x, .y = modal.y + modal.h, .w = modal.w, .h = 0.0 };
    const content_y = content.y + m.modal_pad;
    const body_view_h = @max(content.h - m.modal_pad * 2.0, 0.0);
    const max_scroll_y = @max(body_h - body_view_h, 0.0);
    const scroll_y = theme.clampf(state.settings_controller.scroll_y, 0.0, max_scroll_y);
    const body_clip: palette.Rect = content;

    const close_size = theme.scaledUi(30.0);
    const close: palette.Rect = .{
        .x = modal.x + modal.w - m.modal_pad - close_size,
        .y = modal.y + (m.header_h - close_size) * 0.5,
        .w = close_size,
        .h = close_size,
    };
    const save: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
    const cancel: palette.Rect = save;

    const content_x = content.x;
    const offscreen_y: f32 = OFFSCREEN_Y;
    const page_y = content_y - scroll_y;
    var y = if (category == .appearance) page_y else offscreen_y;

    const appearance_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = appearance_h };
    const theme_row_y = appearance_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const theme_x = appearance_card.x + m.card_pad;
    const theme_dropdown: palette.Rect = .{ .x = theme_x, .y = theme_row_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const ui_font_y = theme_row_y + m.row_h + m.row_gap;
    const ui_stepper = stepperRects(appearance_card, m.card_pad, ui_font_y, m);
    const reduced_motion_y = ui_font_y + m.row_h + m.row_gap;
    const reduced_motion: palette.Rect = .{ .x = theme_x, .y = reduced_motion_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const reduced_motion_hint_y = reduced_motion_y + m.row_h;
    // Per-area switches sit indented under the master toggle.
    const motion_part_indent = theme.scaledUi(18.0);
    var reduced_motion_parts: [REDUCED_MOTION_PARTS.len]palette.Rect = undefined;
    var motion_part_y = reduced_motion_y + m.row_h + m.row_gap;
    for (&reduced_motion_parts) |*rect| {
        rect.* = .{ .x = theme_x + motion_part_indent, .y = motion_part_y, .w = content_w - m.card_pad * 2.0 - motion_part_indent, .h = m.row_h };
        motion_part_y += m.row_h + m.row_gap;
    }

    // Companion page: on/off switch, one-line hint, then the character
    // picker only while the companion is enabled.
    y = if (category == .companion) page_y else offscreen_y;

    const companion_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = companion_h };
    const companion_x = companion_card.x + m.card_pad;
    const companion_toggle_y = companion_card.y + m.card_pad + m.title_h + m.row_gap;
    const companion_toggle: palette.Rect = .{ .x = companion_x, .y = companion_toggle_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const companion_hint_y = companion_toggle_y + m.row_h + m.inner_gap;
    const companion_character_label_y = if (companion_enabled and category == .companion) companion_hint_y + m.label_h + m.row_gap else offscreen_y;
    const companion_row_y = if (companion_enabled and category == .companion) companion_character_label_y + m.label_h + m.inner_gap else offscreen_y;
    const companion_character_dropdown: palette.Rect = .{
        .x = companion_x,
        .y = companion_row_y,
        .w = content_w - m.card_pad * 2.0,
        .h = m.row_h,
    };

    y = if (category == .chat) page_y else offscreen_y;

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

    y = if (category == .chat) transcript_card.y + transcript_card.h + m.card_gap else offscreen_y;

    const chat_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = chat_h };
    const automatic_chat_titles_y = chat_card.y + m.card_pad + m.title_h + m.row_gap;
    const automatic_chat_titles: palette.Rect = .{ .x = chat_card.x + m.card_pad, .y = automatic_chat_titles_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const title_generator_label_y = if (auto_titles) automatic_chat_titles_y + m.row_h + m.row_gap else offscreen_y;
    const title_generator_y = if (auto_titles) title_generator_label_y + m.label_h + m.inner_gap else offscreen_y;
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
    const chat_hint_y = if (auto_titles) title_generator_y + m.row_h else automatic_chat_titles_y + m.row_h;
    const new_chat_defaults_label_y = chat_hint_y + m.row_gap;
    const new_chat_defaults_y = new_chat_defaults_label_y + m.label_h + m.inner_gap;
    const new_chat_defaults_w = content_w - m.card_pad * 2.0;
    const default_provider_w = (new_chat_defaults_w - m.inner_gap * 2.0) * 0.31;
    const default_reasoning_w = (new_chat_defaults_w - m.inner_gap * 2.0) * 0.23;
    const new_chat_provider_dropdown: palette.Rect = .{
        .x = chat_card.x + m.card_pad,
        .y = new_chat_defaults_y,
        .w = default_provider_w,
        .h = m.row_h,
    };
    const new_chat_model_dropdown: palette.Rect = .{
        .x = new_chat_provider_dropdown.x + new_chat_provider_dropdown.w + m.inner_gap,
        .y = new_chat_defaults_y,
        .w = new_chat_defaults_w - default_provider_w - default_reasoning_w - m.inner_gap * 2.0,
        .h = m.row_h,
    };
    const new_chat_reasoning_dropdown: palette.Rect = .{
        .x = new_chat_model_dropdown.x + new_chat_model_dropdown.w + m.inner_gap,
        .y = new_chat_defaults_y,
        .w = default_reasoning_w,
        .h = m.row_h,
    };
    const new_chat_defaults_hint_y = new_chat_defaults_y + m.row_h;
    const file_links_y = new_chat_defaults_y + m.row_h + m.row_gap;
    const file_links_neovim_pane: palette.Rect = .{ .x = chat_card.x + m.card_pad, .y = file_links_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const file_links_hint_y = file_links_y + m.row_h;

    // "Commit messages" card follows the Chat card (title generation lives there).
    y = if (category == .chat) chat_card.y + chat_card.h + m.card_gap else offscreen_y;
    const commit_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = commit_h };
    const commit_inner_w = content_w - m.card_pad * 2.0;
    const commit_generator_y = commit_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const commit_provider_w = (commit_inner_w - m.inner_gap) * 0.42;
    const commit_provider_dropdown: palette.Rect = .{ .x = commit_card.x + m.card_pad, .y = commit_generator_y, .w = commit_provider_w, .h = m.row_h };
    const commit_model_dropdown: palette.Rect = .{
        .x = commit_provider_dropdown.x + commit_provider_w + m.inner_gap,
        .y = commit_generator_y,
        .w = commit_inner_w - commit_provider_w - m.inner_gap,
        .h = m.row_h,
    };
    const commit_action_y = commit_generator_y + m.row_h + m.row_gap + m.label_h + m.inner_gap;
    const commit_action_w = commit_inner_w * 0.5;
    const commit_action_commit: palette.Rect = .{ .x = commit_card.x + m.card_pad, .y = commit_action_y, .w = commit_action_w, .h = m.row_h };
    const commit_action_push: palette.Rect = .{ .x = commit_action_commit.x + commit_action_w, .y = commit_action_y, .w = commit_action_w, .h = m.row_h };

    y = if (category == .providers) page_y else offscreen_y;

    const providers_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = providers_h };
    var provider_rows: [PROVIDER_ROW_COUNT]palette.Rect = undefined;
    var provider_updates: [PROVIDER_ROW_COUNT]palette.Rect = undefined;
    var provider_row_y = providers_card.y + m.card_pad + m.title_h + m.row_gap;
    const provider_action_w = @max(
        @max(@max(buttonWidth("Install"), buttonWidth("Update")), @max(buttonWidth("Sign in"), buttonWidth(PROVIDER_GET_NODE_LABEL))),
        @max(buttonWidth("Latest"), buttonWidth("Checking…")),
    );
    const provider_switch_reserve = theme.scaledUi(PROVIDER_SWITCH_RESERVE_UI);
    for (&provider_rows, &provider_updates) |*row, *update| {
        row.* = .{ .x = providers_card.x + m.card_pad, .y = provider_row_y, .w = content_w - m.card_pad * 2.0, .h = providerRowHeight() };
        // The action button sits just left of the switch, vertically
        // centered, so the name line and the status line beneath it (dot,
        // status, version) share everything to its left.
        const update_h = theme.scaledUi(24.0);
        update.* = .{
            .x = row.x + row.w - provider_switch_reserve - provider_action_w,
            .y = row.y + (row.h - update_h) * 0.5,
            .w = provider_action_w,
            .h = update_h,
        };
        provider_row_y += providerRowHeight();
    }
    const providers_hint_y = provider_row_y + m.row_gap;
    const providers_update_hint_y = providers_hint_y + m.label_h;
    const providers_recheck: palette.Rect = .{
        .x = providers_card.x + m.card_pad,
        .y = providers_update_hint_y + m.label_h + m.row_gap,
        .w = buttonWidth(PROVIDERS_RECHECK_LABEL),
        .h = m.row_h,
    };
    var update_all_label_buf: [32]u8 = undefined;
    const update_all_label = providersUpdateAllLabel(state, &update_all_label_buf);
    const providers_update_all: palette.Rect = .{
        .x = providers_recheck.x + providers_recheck.w + m.inner_gap,
        .y = providers_recheck.y,
        .w = if (update_all_label) |label| buttonWidth(label) else 0.0,
        .h = m.row_h,
    };

    const custom_agents_card: palette.Rect = .{ .x = content_x, .y = providers_card.y + providers_h + m.card_gap, .w = content_w, .h = custom_agents_h };
    const custom_agents_subtitle_y = custom_agents_card.y + m.card_pad + m.title_h + m.inner_gap;
    var custom_agent_rows: [MAX_CUSTOM_AGENT_ROWS]palette.Rect = @splat(.{});
    var custom_agent_edits: [MAX_CUSTOM_AGENT_ROWS]palette.Rect = @splat(.{});
    var custom_agent_removes: [MAX_CUSTOM_AGENT_ROWS]palette.Rect = @splat(.{});
    var custom_agent_y = custom_agents_subtitle_y + customAgentsSubtitleHeight(content_w, m) + m.row_gap;
    const custom_agents_empty_y = custom_agent_y;
    const custom_agent_button_h = theme.scaledUi(26.0);
    const custom_agent_remove_w = buttonWidth("Remove");
    const custom_agent_edit_w = buttonWidth("Edit");
    for (0..custom_agent_count) |index| {
        const row: palette.Rect = .{ .x = custom_agents_card.x + m.card_pad, .y = custom_agent_y, .w = content_w - m.card_pad * 2.0, .h = customAgentRowHeight() };
        custom_agent_rows[index] = row;
        const button_y = row.y + (row.h - custom_agent_button_h) * 0.5;
        custom_agent_removes[index] = .{ .x = row.x + row.w - custom_agent_remove_w, .y = button_y, .w = custom_agent_remove_w, .h = custom_agent_button_h };
        custom_agent_edits[index] = .{ .x = custom_agent_removes[index].x - m.inner_gap - custom_agent_edit_w, .y = button_y, .w = custom_agent_edit_w, .h = custom_agent_button_h };
        custom_agent_y += customAgentRowHeight();
    }
    if (custom_agent_count == 0) custom_agent_y += m.label_h + m.inner_gap;
    const custom_agents_add: palette.Rect = .{
        .x = custom_agents_card.x + m.card_pad,
        .y = custom_agent_y + m.row_gap,
        .w = buttonWidth(CUSTOM_AGENTS_ADD_LABEL),
        .h = m.row_h,
    };

    y = if (category == .terminal) page_y else offscreen_y;

    const terminal_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = terminal_h };
    const terminal_font_y = terminal_card.y + m.card_pad + m.title_h + m.row_gap;
    const terminal_stepper = stepperRects(terminal_card, m.card_pad, terminal_font_y, m);
    const terminal_hint_y = terminal_font_y + m.row_h + m.inner_gap;

    y = if (category == .browser) page_y else offscreen_y;

    const browser_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = browser_h };
    const link_label_y = browser_card.y + m.card_pad + m.title_h + m.row_gap;
    const link_row_y = link_label_y + m.label_h + m.inner_gap;
    const link_content_w = content_w - m.card_pad * 2.0;
    const link_cell_w = link_content_w * 0.5;
    const links_verde_browser: palette.Rect = .{ .x = browser_card.x + m.card_pad, .y = link_row_y, .w = link_cell_w, .h = m.row_h };
    const links_system_browser: palette.Rect = .{ .x = links_verde_browser.x + link_cell_w, .y = link_row_y, .w = link_cell_w, .h = m.row_h };
    const chat_links_label_y = link_row_y + m.row_h + m.row_gap;
    const chat_links_y = chat_links_label_y + m.label_h + m.inner_gap;
    const override_cell_w = link_content_w / 3.0;
    const chat_links_global: palette.Rect = .{ .x = browser_card.x + m.card_pad, .y = chat_links_y, .w = override_cell_w, .h = m.row_h };
    const chat_links_verde_browser: palette.Rect = .{ .x = chat_links_global.x + override_cell_w, .y = chat_links_y, .w = override_cell_w, .h = m.row_h };
    const chat_links_system_browser: palette.Rect = .{ .x = chat_links_verde_browser.x + override_cell_w, .y = chat_links_y, .w = override_cell_w, .h = m.row_h };
    const terminal_links_label_y = chat_links_y + m.row_h + m.row_gap;
    const terminal_links_y = terminal_links_label_y + m.label_h + m.inner_gap;
    const terminal_links_global: palette.Rect = .{ .x = browser_card.x + m.card_pad, .y = terminal_links_y, .w = override_cell_w, .h = m.row_h };
    const terminal_links_verde_browser: palette.Rect = .{ .x = terminal_links_global.x + override_cell_w, .y = terminal_links_y, .w = override_cell_w, .h = m.row_h };
    const terminal_links_system_browser: palette.Rect = .{ .x = terminal_links_verde_browser.x + override_cell_w, .y = terminal_links_y, .w = override_cell_w, .h = m.row_h };
    const browser_scroll_label_y = terminal_links_y + m.row_h + m.row_gap;
    const browser_scroll_speed_y = browser_scroll_label_y + m.label_h + m.inner_gap;
    const browser_scroll_speed: palette.Rect = .{ .x = browser_card.x + m.card_pad, .y = browser_scroll_speed_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const browser_hint_y = browser_scroll_speed_y + m.row_h + m.inner_gap;

    y = if (category == .workspace) page_y else offscreen_y;

    const workspace_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = workspace_h };
    const open_x = workspace_card.x + m.card_pad;
    const workspace_tabs_label_y = workspace_card.y + m.card_pad + m.title_h + m.row_gap;
    const workspace_tabs_y = workspace_tabs_label_y + m.label_h + m.inner_gap;
    const workspace_tabs_w = (content_w - m.card_pad * 2.0 - m.inner_gap * 2.0) / 3.0;
    const workspace_tabs_automatic: palette.Rect = .{ .x = open_x, .y = workspace_tabs_y, .w = workspace_tabs_w, .h = m.row_h };
    const workspace_tabs_always: palette.Rect = .{ .x = workspace_tabs_automatic.x + workspace_tabs_w + m.inner_gap, .y = workspace_tabs_y, .w = workspace_tabs_w, .h = m.row_h };
    const workspace_tabs_disabled: palette.Rect = .{ .x = workspace_tabs_always.x + workspace_tabs_w + m.inner_gap, .y = workspace_tabs_y, .w = workspace_tabs_w, .h = m.row_h };
    const open_y = workspace_tabs_y + m.row_h + m.row_gap + m.label_h + m.inner_gap;
    const open_cells = [_]palette.Rect{.{ .x = 0.0, .y = offscreen_y, .w = 0.0, .h = 0.0 }} ** OPEN_CHOICES.len;
    const custom_open: ?palette.Rect = null;
    const new_chat_label_y = open_y + m.row_h + m.row_gap;
    const new_chat_y = new_chat_label_y + m.label_h + m.inner_gap;
    const new_chat_cell_w = (content_w - m.card_pad * 2.0) * 0.5;
    const new_chat_new_pane: palette.Rect = .{ .x = open_x, .y = new_chat_y, .w = new_chat_cell_w, .h = m.row_h };
    const new_chat_replace_pane: palette.Rect = .{ .x = new_chat_new_pane.x + new_chat_cell_w, .y = new_chat_y, .w = new_chat_cell_w, .h = m.row_h };
    const workspace_split_default_label_y = new_chat_y + m.row_h + m.row_gap;
    const workspace_split_default_y = workspace_split_default_label_y + m.label_h + m.inner_gap;
    const workspace_split_default_w = (content_w - m.card_pad * 2.0) * 0.5;
    const workspace_split_default_chat: palette.Rect = .{ .x = open_x, .y = workspace_split_default_y, .w = workspace_split_default_w, .h = m.row_h };
    const workspace_split_default_terminal: palette.Rect = .{ .x = workspace_split_default_chat.x + workspace_split_default_w, .y = workspace_split_default_y, .w = workspace_split_default_w, .h = m.row_h };
    const workspace_split_default_hint_y = workspace_split_default_y + m.row_h;
    const workspace_new_tab_label_y = workspace_split_default_hint_y + m.row_gap;
    const workspace_new_tab_y = workspace_new_tab_label_y + m.label_h + m.inner_gap;
    const workspace_new_tab_chat: palette.Rect = .{ .x = open_x, .y = workspace_new_tab_y, .w = workspace_split_default_w, .h = m.row_h };
    const workspace_new_tab_terminal: palette.Rect = .{ .x = workspace_new_tab_chat.x + workspace_split_default_w, .y = workspace_new_tab_y, .w = workspace_split_default_w, .h = m.row_h };
    const workspace_new_tab_hint_y = workspace_new_tab_y + m.row_h;
    const workspace_unzoom_on_navigation_y = workspace_new_tab_hint_y + m.row_gap;
    const workspace_unzoom_on_navigation: palette.Rect = .{ .x = open_x, .y = workspace_unzoom_on_navigation_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const workspace_unzoom_on_navigation_hint_y = workspace_unzoom_on_navigation_y + m.row_h;
    const workspace_pane_gap_y = workspace_unzoom_on_navigation_hint_y + m.row_gap;
    const workspace_pane_gap_stepper = stepperRects(workspace_card, m.card_pad, workspace_pane_gap_y, m);
    const workspace_pane_gap_hint_y = workspace_pane_gap_y + m.row_h;
    const workspace_panes_per_view_y = workspace_pane_gap_hint_y + m.row_gap;
    const workspace_panes_per_view_stepper = stepperRects(workspace_card, m.card_pad, workspace_panes_per_view_y, m);
    const workspace_panes_per_view_hint_y = workspace_panes_per_view_y + m.row_h;
    const workspace_scroll_mode_label_y = workspace_panes_per_view_hint_y + m.row_gap;
    const workspace_scroll_mode_y = workspace_scroll_mode_label_y + m.label_h + m.inner_gap;
    const workspace_scroll_mode_w = (content_w - m.card_pad * 2.0) / 3.0;
    const workspace_scroll_mode_automatic: palette.Rect = .{ .x = open_x, .y = workspace_scroll_mode_y, .w = workspace_scroll_mode_w, .h = m.row_h };
    const workspace_scroll_mode_always: palette.Rect = .{ .x = workspace_scroll_mode_automatic.x + workspace_scroll_mode_w, .y = workspace_scroll_mode_y, .w = workspace_scroll_mode_w, .h = m.row_h };
    const workspace_scroll_mode_disabled: palette.Rect = .{ .x = workspace_scroll_mode_always.x + workspace_scroll_mode_w, .y = workspace_scroll_mode_y, .w = workspace_scroll_mode_w, .h = m.row_h };
    const workspace_scroll_mode_hint_y = workspace_scroll_mode_y + m.row_h;
    const workspace_scroll_threshold_y = if (auto_scroll) workspace_scroll_mode_hint_y + m.row_gap else offscreen_y;
    const workspace_scroll_threshold_stepper = stepperRects(workspace_card, m.card_pad, workspace_scroll_threshold_y, m);
    const workspace_scroll_threshold_hint_y = workspace_scroll_threshold_y + m.row_h;
    const workspace_scroll_direction_label_y = (if (auto_scroll) workspace_scroll_threshold_hint_y else workspace_scroll_mode_hint_y) + m.row_gap;
    const workspace_scroll_direction_y = workspace_scroll_direction_label_y + m.label_h + m.inner_gap;
    const workspace_scroll_direction_w = (content_w - m.card_pad * 2.0) * 0.5;
    const workspace_scroll_horizontal: palette.Rect = .{ .x = open_x, .y = workspace_scroll_direction_y, .w = workspace_scroll_direction_w, .h = m.row_h };
    const workspace_scroll_vertical: palette.Rect = .{ .x = workspace_scroll_horizontal.x + workspace_scroll_direction_w, .y = workspace_scroll_direction_y, .w = workspace_scroll_direction_w, .h = m.row_h };
    const workspace_scroll_direction_hint_y = workspace_scroll_direction_y + m.row_h;
    const workspace_scroll_use_global: palette.Rect = .{ .x = 0.0, .y = offscreen_y, .w = 0.0, .h = 0.0 };
    const workspace_scroll_override: palette.Rect = workspace_scroll_use_global;
    const workspace_scroll_scope_hint_y = offscreen_y;
    const navigation = layoutNavigationCard(.{ .x = content_x, .y = workspace_card.y + workspace_h + m.card_gap, .w = content_w, .h = navigation_h }, m);

    y = if (category == .connections) page_y else offscreen_y;

    const phone_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = phone_h };
    y += phone_h + m.card_gap;
    const runtimes_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = runtimes_h };
    const runtimes = planRuntimeCard(state, content_x, y, content_w, m);
    y = if (category == .agents) page_y else offscreen_y;

    const integrations_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = integrations_h };
    const mcp_tools_y = integrations_card.y + m.card_pad + m.title_h + m.row_gap + m.label_h + m.inner_gap;
    const mcp_tools: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = mcp_tools_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const mcp_hint_y = mcp_tools_y + m.row_h + m.inner_gap;
    // The auto-approval note uses the card's spare label slot.
    const mcp_note_y = mcp_hint_y + m.label_h;
    const hooks_label_y = mcp_note_y + m.label_h + m.row_gap;
    const hooks_claude_y = hooks_label_y + m.label_h + m.inner_gap;
    const hooks_claude: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_claude_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_codex_y = hooks_claude_y + m.row_h + m.inner_gap;
    const hooks_codex: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_codex_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_cursor_y = hooks_codex_y + m.row_h + m.inner_gap;
    const hooks_cursor: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_cursor_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_opencode_y = hooks_cursor_y + m.row_h + m.inner_gap;
    const hooks_opencode: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_opencode_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_grok_y = hooks_opencode_y + m.row_h + m.inner_gap;
    const hooks_grok: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_grok_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_amp_y = hooks_grok_y + m.row_h + m.inner_gap;
    const hooks_amp: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_amp_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const hooks_pi_y = hooks_amp_y + m.row_h + m.inner_gap;
    const hooks_pi: palette.Rect = .{ .x = integrations_card.x + m.card_pad, .y = hooks_pi_y, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const integrations_hint_y = hooks_pi_y + m.row_h + m.inner_gap;

    y = if (category == .app) page_y else offscreen_y;

    const updates_card: palette.Rect = .{ .x = content_x, .y = y, .w = content_w, .h = updates_h };
    const updates_status_y = updates_card.y + m.card_pad + m.title_h + m.inner_gap;
    const updates_actions_y = updates_status_y + m.label_h + m.inner_gap;
    const update_action_w = (content_w - m.card_pad * 2.0 - m.inner_gap) * 0.5;
    const updates_check: palette.Rect = .{ .x = updates_card.x + m.card_pad, .y = updates_actions_y, .w = update_action_w, .h = m.row_h };
    const updates_download: palette.Rect = .{ .x = updates_check.x + update_action_w + m.inner_gap, .y = updates_actions_y, .w = update_action_w, .h = m.row_h };
    const updates_automatic: palette.Rect = .{ .x = updates_check.x, .y = updates_actions_y + m.row_h + m.inner_gap, .w = content_w - m.card_pad * 2.0, .h = m.row_h };
    const updates_notes_y = updates_automatic.y + m.row_h + m.inner_gap + package_hint_h;
    const updates_links_y = updates_notes_y + updates_notes_h + m.inner_gap;
    var updates_notes_toggle: ?palette.Rect = null;
    if (state.settings_controller.update.release != null) {
        updates_notes_toggle = .{
            .x = updates_card.x + m.card_pad,
            .y = updates_links_y,
            .w = settingsTextWidth(theme.scaledUi(NOTES_LINK_FONT_SIZE), notesToggleLabel(state)),
            .h = m.label_h,
        };
    }
    const release_page_x = if (updates_notes_toggle) |toggle| toggle.x + toggle.w + m.row_gap * 2.0 else updates_card.x + m.card_pad;
    const updates_release_page: palette.Rect = .{
        .x = release_page_x,
        .y = updates_links_y,
        .w = settingsTextWidth(theme.scaledUi(NOTES_LINK_FONT_SIZE), RELEASE_PAGE_LABEL),
        .h = m.label_h,
    };

    y = if (category == .app) updates_card.y + updates_card.h + m.card_gap else offscreen_y;

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
        .nav = nav,
        .content = content,
        .cancel = cancel,
        .save = save,
        .appearance_card = appearance_card,
        .theme_dropdown = theme_dropdown,
        .companion_character_label_y = companion_character_label_y,
        .companion_character_dropdown = companion_character_dropdown,
        .ui_font_dec = ui_stepper.dec,
        .ui_font_inc = ui_stepper.inc,
        .reduced_motion = reduced_motion,
        .reduced_motion_parts = reduced_motion_parts,
        .reduced_motion_hint_y = reduced_motion_hint_y,
        .workspace_tabs_label_y = workspace_tabs_label_y,
        .workspace_tabs_automatic = workspace_tabs_automatic,
        .workspace_tabs_always = workspace_tabs_always,
        .workspace_tabs_disabled = workspace_tabs_disabled,
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
        .new_chat_provider_dropdown = new_chat_provider_dropdown,
        .new_chat_model_dropdown = new_chat_model_dropdown,
        .new_chat_reasoning_dropdown = new_chat_reasoning_dropdown,
        .new_chat_defaults_hint_y = new_chat_defaults_hint_y,
        .commit_card = commit_card,
        .commit_provider_dropdown = commit_provider_dropdown,
        .commit_model_dropdown = commit_model_dropdown,
        .commit_action_commit = commit_action_commit,
        .commit_action_push = commit_action_push,
        .terminal_card = terminal_card,
        .terminal_font_dec = terminal_stepper.dec,
        .terminal_font_inc = terminal_stepper.inc,
        .terminal_hint_y = terminal_hint_y,
        .browser_card = browser_card,
        .links_verde_browser = links_verde_browser,
        .links_system_browser = links_system_browser,
        .chat_links_global = chat_links_global,
        .chat_links_verde_browser = chat_links_verde_browser,
        .chat_links_system_browser = chat_links_system_browser,
        .terminal_links_global = terminal_links_global,
        .terminal_links_verde_browser = terminal_links_verde_browser,
        .terminal_links_system_browser = terminal_links_system_browser,
        .browser_scroll_speed = browser_scroll_speed,
        .browser_hint_y = browser_hint_y,
        .companion_card = companion_card,
        .companion_toggle = companion_toggle,
        .companion_hint_y = companion_hint_y,
        .workspace_card = workspace_card,
        .open_cells = open_cells,
        .open_action_dropdown = .{
            .x = open_x,
            .y = open_y,
            .w = content_w - m.card_pad * 2.0,
            .h = m.row_h,
        },
        .custom_open = custom_open,
        .new_chat_new_pane = new_chat_new_pane,
        .workspace_split_default_chat = workspace_split_default_chat,
        .workspace_split_default_terminal = workspace_split_default_terminal,
        .workspace_split_default_hint_y = workspace_split_default_hint_y,
        .workspace_new_tab_chat = workspace_new_tab_chat,
        .workspace_new_tab_terminal = workspace_new_tab_terminal,
        .workspace_new_tab_hint_y = workspace_new_tab_hint_y,
        .new_chat_replace_pane = new_chat_replace_pane,
        .file_links_neovim_pane = file_links_neovim_pane,
        .file_links_hint_y = file_links_hint_y,
        .workspace_unzoom_on_navigation = workspace_unzoom_on_navigation,
        .workspace_unzoom_on_navigation_hint_y = workspace_unzoom_on_navigation_hint_y,
        .navigation_card = navigation.card,
        .navigation_back_record = navigation.back_record,
        .navigation_back_reset = navigation.back_reset,
        .navigation_forward_record = navigation.forward_record,
        .navigation_forward_reset = navigation.forward_reset,
        .navigation_hint_y = navigation.hint_y,
        .workspace_pane_gap_dec = workspace_pane_gap_stepper.dec,
        .workspace_pane_gap_inc = workspace_pane_gap_stepper.inc,
        .workspace_pane_gap_hint_y = workspace_pane_gap_hint_y,
        .workspace_panes_per_view_dec = workspace_panes_per_view_stepper.dec,
        .workspace_panes_per_view_inc = workspace_panes_per_view_stepper.inc,
        .workspace_panes_per_view_hint_y = workspace_panes_per_view_hint_y,
        .workspace_scroll_use_global = workspace_scroll_use_global,
        .workspace_scroll_override = workspace_scroll_override,
        .workspace_scroll_scope_hint_y = workspace_scroll_scope_hint_y,
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
        .phone_card = phone_card,
        .runtimes_card = runtimes_card,
        .runtimes = runtimes,
        .integrations_card = integrations_card,
        .mcp_tools = mcp_tools,
        .mcp_hint_y = mcp_hint_y,
        .mcp_note_y = mcp_note_y,
        .hooks_label_y = hooks_label_y,
        .hooks_claude = hooks_claude,
        .hooks_codex = hooks_codex,
        .hooks_cursor = hooks_cursor,
        .hooks_opencode = hooks_opencode,
        .hooks_grok = hooks_grok,
        .hooks_amp = hooks_amp,
        .hooks_pi = hooks_pi,
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
        .providers_card = providers_card,
        .provider_rows = provider_rows,
        .provider_updates = provider_updates,
        .providers_hint_y = providers_hint_y,
        .providers_update_hint_y = providers_update_hint_y,
        .providers_recheck = providers_recheck,
        .providers_update_all = providers_update_all,
        .custom_agents_card = custom_agents_card,
        .custom_agents_subtitle_y = custom_agents_subtitle_y,
        .custom_agent_rows = custom_agent_rows,
        .custom_agent_edits = custom_agent_edits,
        .custom_agent_removes = custom_agent_removes,
        .custom_agent_count = custom_agent_count,
        .custom_agents_empty_y = custom_agents_empty_y,
        .custom_agents_add = custom_agents_add,
    };
}

fn isControlHovered(state: *const runtime.AppState, control: Control) bool {
    return state.settings_controller.hover_control != null and state.settings_controller.hover_control.? == @intFromEnum(control);
}

fn openActionSelectedIndex(state: *const runtime.AppState) usize {
    const action = state.settings_controller.draft.open_action;
    inline for (OPEN_CHOICES, 0..) |choice, index| {
        const selected = switch (choice.control) {
            .open_folder => action == .folder,
            .open_editor => action == .editor,
            .open_cursor => action == .cursor,
            .open_vscode => action == .vscode,
            .open_zed => action == .zed,
            else => false,
        };
        if (selected) return index;
    }
    return 0;
}

fn handleOpenActionKeyDown(state: *runtime.AppState, key: palette.event.Keycode) bool {
    const count = OPEN_CHOICES.len;
    const current = state.settings_controller.open_action_hover_index orelse openActionSelectedIndex(state);
    const next = switch (key) {
        .up => current -| 1,
        .down => @min(current + 1, count - 1),
        .home => 0,
        .end => count - 1,
        .escape => {
            state.settings_controller.open_action_dropdown_open = false;
            state.settings_controller.open_action_hover_index = null;
            state.markDirty();
            return true;
        },
        .@"return", .kp_enter => {
            applyOpenActionOption(state, current);
            return true;
        },
        else => return false,
    };
    state.settings_controller.open_action_hover_index = next;
    state.markDirty();
    return true;
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
    recordFocusStop(.settings_control, @intFromEnum(control), rect, clip);
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

fn companionCharacterCount() usize {
    return COMPANION_CHARACTER_OPTIONS.len;
}

fn companionCharacterLabel(choice_index: usize) []const u8 {
    if (choice_index >= COMPANION_CHARACTER_LABELS.len) return "Unknown companion";
    return COMPANION_CHARACTER_LABELS[choice_index];
}

fn companionCharacterIndex(character: app_config.CompanionCharacter) usize {
    inline for (COMPANION_CHARACTER_OPTIONS, 0..) |option, index| {
        if (option == character) return index;
    }
    return 0;
}

fn companionCharacterMenuRect(layout: SettingsLayout) palette.Rect {
    return dropdownMenuRect(layout.companion_character_dropdown, companionCharacterCount());
}

fn companionCharacterOptionRect(layout: SettingsLayout, choice_index: usize) palette.Rect {
    return dropdownOptionRect(companionCharacterMenuRect(layout), choice_index);
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

fn registerCompanionCharacterOptionHits(
    state: *runtime.AppState,
    layout: SettingsLayout,
    queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    if (!state.settings_controller.companion_character_dropdown_open) return;
    // Fixed Sprout/Moss/Vireo list — reuse the theme option action channel with
    // the choice index; applyThemeOption is only invoked when the theme menu
    // is open, so companion selection routes through applyCompanionCharacterOption.
    for (0..companionCharacterCount()) |choice_index| {
        const rect = intersectRect(companionCharacterOptionRect(layout, choice_index), layout.body_clip) orelse continue;
        queue_hit(state, rect, .settings_theme_option, choice_index);
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

// ------------------------------------------------------------------
// Commit messages menus
// ------------------------------------------------------------------

fn commitMenuCount(state: *runtime.AppState, menu: settings_controller.CommitMenu) usize {
    return switch (menu) {
        .provider => settings_controller.settingsCommitProviderCount(),
        .model => settings_controller.settingsCommitModelCount(state),
    };
}

fn commitMenuVisibleCount(state: *runtime.AppState, menu: settings_controller.CommitMenu) usize {
    return @min(commitMenuCount(state, menu), TITLE_MENU_MAX_ROWS);
}

fn commitMenuMaxScroll(state: *runtime.AppState, menu: settings_controller.CommitMenu) usize {
    return commitMenuCount(state, menu) - commitMenuVisibleCount(state, menu);
}

fn commitMenuScroll(state: *runtime.AppState, menu: settings_controller.CommitMenu) usize {
    return if (menu == .model) @min(state.settings_controller.commit_model_menu_scroll, commitMenuMaxScroll(state, .model)) else 0;
}

fn commitMenuRect(state: *runtime.AppState, layout: SettingsLayout, menu: settings_controller.CommitMenu) palette.Rect {
    const dropdown = if (menu == .provider) layout.commit_provider_dropdown else layout.commit_model_dropdown;
    return dropdownMenuRect(dropdown, commitMenuVisibleCount(state, menu));
}

fn commitMenuSelectedIndex(state: *runtime.AppState, menu: settings_controller.CommitMenu) ?usize {
    return switch (menu) {
        .provider => settings_controller.settingsCommitProviderSelectedIndex(state),
        .model => settings_controller.settingsCommitModelSelectedIndex(state),
    };
}

fn commitMenuLabel(state: *runtime.AppState, menu: settings_controller.CommitMenu, option_index: usize, buf: []u8) []const u8 {
    return switch (menu) {
        .provider => settings_controller.settingsCommitProviderLabel(option_index),
        .model => settings_controller.settingsCommitModelLabel(state, option_index, buf),
    };
}

fn registerCommitOptionHits(
    state: *runtime.AppState,
    layout: SettingsLayout,
    queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    const menu = state.settings_controller.commit_menu orelse return;
    const scroll = commitMenuScroll(state, menu);
    state.settings_controller.commit_model_menu_scroll = if (menu == .model) scroll else state.settings_controller.commit_model_menu_scroll;
    const rect = commitMenuRect(state, layout, menu);
    for (0..commitMenuVisibleCount(state, menu)) |visible_index| {
        const row = intersectRect(dropdownOptionRect(rect, visible_index), layout.body_clip) orelse continue;
        queue_hit(state, row, .settings_commit_option, scroll + visible_index);
    }
}

fn toggleCommitMenu(state: *runtime.AppState, menu: settings_controller.CommitMenu) void {
    if (state.settings_controller.commit_menu == menu) {
        state.settings_controller.commit_menu = null;
        state.settings_controller.commit_menu_hover_index = null;
        return;
    }
    state.settings_controller.commit_menu = menu;
    const selected = commitMenuSelectedIndex(state, menu) orelse 0;
    state.settings_controller.commit_menu_hover_index = selected;
    if (menu == .model) ensureCommitModelChoiceVisible(state, selected);
}

fn ensureCommitModelChoiceVisible(state: *runtime.AppState, option_index: usize) void {
    const visible_count = commitMenuVisibleCount(state, .model);
    if (option_index < state.settings_controller.commit_model_menu_scroll) {
        state.settings_controller.commit_model_menu_scroll = option_index;
    } else if (option_index >= state.settings_controller.commit_model_menu_scroll + visible_count) {
        state.settings_controller.commit_model_menu_scroll = option_index + 1 - visible_count;
    }
    state.settings_controller.commit_model_menu_scroll = @min(state.settings_controller.commit_model_menu_scroll, commitMenuMaxScroll(state, .model));
}

pub fn applyCommitMenuOption(state: *runtime.AppState, option_index: usize) void {
    const menu = state.settings_controller.commit_menu orelse return;
    switch (menu) {
        .provider => settings_controller.selectSettingsCommitProvider(state, option_index),
        .model => settings_controller.selectSettingsCommitModel(state, option_index),
    }
    state.markDirty();
}

fn handleCommitMenuKeyDown(state: *runtime.AppState, menu: settings_controller.CommitMenu, key: palette.event.Keycode) bool {
    const count = commitMenuCount(state, menu);
    if (count == 0) return false;
    const current = @min(state.settings_controller.commit_menu_hover_index orelse commitMenuSelectedIndex(state, menu) orelse 0, count - 1);
    const next = switch (key) {
        .up => current -| 1,
        .down => @min(current + 1, count - 1),
        .home => 0,
        .end => count - 1,
        .escape => {
            state.settings_controller.commit_menu = null;
            state.settings_controller.commit_menu_hover_index = null;
            state.markDirty();
            return true;
        },
        .@"return", .kp_enter => {
            applyCommitMenuOption(state, current);
            return true;
        },
        else => return false,
    };
    state.settings_controller.commit_menu_hover_index = next;
    if (menu == .model) ensureCommitModelChoiceVisible(state, next);
    state.markDirty();
    return true;
}

fn drawCommitCard(state: *runtime.AppState, layout: SettingsLayout, m: Metrics) void {
    drawCard(state, layout.commit_card, layout.body_clip);
    drawCardTitle(state, layout.commit_card, "Commit messages", layout.body_clip);
    const label_y = layout.commit_provider_dropdown.y - m.inner_gap - m.label_h;
    queueText(state, .{ .x = layout.commit_provider_dropdown.x, .y = label_y, .w = layout.commit_provider_dropdown.w, .h = m.label_h }, "Provider", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    queueText(state, .{ .x = layout.commit_model_dropdown.x, .y = label_y, .w = layout.commit_model_dropdown.w, .h = m.label_h }, "Model", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    const open = state.settings_controller.commit_menu;
    drawChatTitleDropdown(state, layout.commit_provider_dropdown, settings_controller.settingsCommitProviderLabel(settings_controller.settingsCommitProviderSelectedIndex(state)), .commit_provider_dropdown, open == .provider, layout.body_clip);
    var model_buf: [128]u8 = undefined;
    drawChatTitleDropdown(state, layout.commit_model_dropdown, settings_controller.settingsCommitModelSelectedLabel(state, &model_buf), .commit_model_dropdown, open == .model, layout.body_clip);
    queueText(state, .{
        .x = layout.commit_action_commit.x,
        .y = layout.commit_action_commit.y - m.inner_gap - m.label_h,
        .w = layout.commit_action_commit.w + layout.commit_action_push.w,
        .h = m.label_h,
    }, "Default action", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
    drawSegmentedPair(state, layout.commit_action_commit, layout.commit_action_push, "Commit", "Commit & push", state.app_config.commit_default_action == .commit, isControlHovered(state, .commit_action_commit), isControlHovered(state, .commit_action_push), layout.body_clip);
}

fn drawCommitDropdownMenu(state: *runtime.AppState, layout: SettingsLayout) void {
    const menu_kind = state.settings_controller.commit_menu orelse return;
    const count = commitMenuCount(state, menu_kind);
    const visible_count = commitMenuVisibleCount(state, menu_kind);
    const scroll = commitMenuScroll(state, menu_kind);
    const menu = commitMenuRect(state, layout, menu_kind);
    queueRoundedRectClipped(state, menu, paletteColor(raisedSurface(0.14)), radiusSm(), layout.body_clip);
    queueBorderClipped(state, menu, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 34)), radiusSm(), theme.scaledUi(1.0), layout.body_clip);
    const selected_index = commitMenuSelectedIndex(state, menu_kind) orelse std.math.maxInt(usize);
    for (0..visible_count) |visible_index| {
        const option_index = scroll + visible_index;
        const row = dropdownOptionRect(menu, visible_index);
        const selected = option_index == selected_index;
        const hovered = state.settings_controller.commit_menu_hover_index == option_index;
        if (selected or hovered) {
            const color = if (selected) theme.withAlpha(theme.accent(), 38) else controlHoverSurface();
            queueRoundedRectClipped(state, row, paletteColor(color), theme.scaledUi(4.0), layout.body_clip);
        }
        const dot_size = theme.scaledUi(6.0);
        const dot_color = if (selected) theme.accent() else theme.withAlpha(theme.COLOR_TEXT_MUTED, 110);
        queueRoundedRectClipped(state, .{ .x = row.x + theme.scaledUi(10.0), .y = row.y + (row.h - dot_size) * 0.5, .w = dot_size, .h = dot_size }, paletteColor(dot_color), dot_size * 0.5, layout.body_clip);
        var label_buf: [128]u8 = undefined;
        queueText(state, .{
            .x = row.x + theme.scaledUi(25.0),
            .y = row.y + (row.h - theme.scaledUi(15.0)) * 0.5,
            .w = row.w - theme.scaledUi(42.0),
            .h = theme.scaledUi(15.0),
        }, commitMenuLabel(state, menu_kind, option_index, &label_buf), paletteColor(if (selected or hovered) theme.COLOR_WHITE else textLabel()), theme.scaledUi(13.0), layout.body_clip);
    }
    if (count > visible_count) {
        const track: palette.Rect = .{ .x = menu.x + menu.w - theme.scaledUi(5.0), .y = menu.y + theme.scaledUi(4.0), .w = theme.scaledUi(2.0), .h = menu.h - theme.scaledUi(8.0) };
        const thumb_h = track.h * @as(f32, @floatFromInt(visible_count)) / @as(f32, @floatFromInt(count));
        const progress = @as(f32, @floatFromInt(scroll)) / @as(f32, @floatFromInt(commitMenuMaxScroll(state, menu_kind)));
        queueRoundedRectClipped(state, track, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 20)), theme.scaledUi(1.0), layout.body_clip);
        queueRoundedRectClipped(state, .{ .x = track.x, .y = track.y + (track.h - thumb_h) * progress, .w = track.w, .h = thumb_h }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 100)), theme.scaledUi(1.0), layout.body_clip);
    }
}

const NewChatMenuKind = enum { provider, model, reasoning };

fn newChatMenuCount(state: *const runtime.AppState, kind: NewChatMenuKind) usize {
    return switch (kind) {
        .provider => state.settingsNewChatProviderCount(),
        .model => state.settingsNewChatModelCount(),
        .reasoning => state.settingsNewChatReasoningCount(),
    };
}

fn newChatModelMenuVisibleCount(state: *const runtime.AppState) usize {
    return @min(state.settingsNewChatModelCount(), TITLE_MENU_MAX_ROWS);
}

fn newChatModelMenuMaxScroll(state: *const runtime.AppState) usize {
    return state.settingsNewChatModelCount() - newChatModelMenuVisibleCount(state);
}

fn newChatMenuRect(state: *const runtime.AppState, layout: SettingsLayout, kind: NewChatMenuKind) palette.Rect {
    const dropdown = switch (kind) {
        .provider => layout.new_chat_provider_dropdown,
        .model => layout.new_chat_model_dropdown,
        .reasoning => layout.new_chat_reasoning_dropdown,
    };
    const count = if (kind == .model) newChatModelMenuVisibleCount(state) else @min(newChatMenuCount(state, kind), TITLE_MENU_MAX_ROWS);
    return dropdownMenuRect(dropdown, count);
}

fn registerNewChatOptionHits(
    state: *runtime.AppState,
    layout: SettingsLayout,
    queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    const kinds = [_]NewChatMenuKind{ .provider, .model, .reasoning };
    for (kinds) |kind| {
        const open = switch (kind) {
            .provider => state.settings_controller.new_chat_provider_dropdown_open,
            .model => state.settings_controller.new_chat_model_dropdown_open,
            .reasoning => state.settings_controller.new_chat_reasoning_dropdown_open,
        };
        if (!open) continue;
        if (kind == .model) state.settings_controller.new_chat_model_menu_scroll = @min(state.settings_controller.new_chat_model_menu_scroll, newChatModelMenuMaxScroll(state));
        const scroll = if (kind == .model) state.settings_controller.new_chat_model_menu_scroll else 0;
        const visible_count = if (kind == .model) newChatModelMenuVisibleCount(state) else @min(newChatMenuCount(state, kind), TITLE_MENU_MAX_ROWS);
        const action: runtime.PaletteModalAction = switch (kind) {
            .provider => .settings_new_chat_provider_option,
            .model => .settings_new_chat_model_option,
            .reasoning => .settings_new_chat_reasoning_option,
        };
        const menu = newChatMenuRect(state, layout, kind);
        for (0..visible_count) |visible_index| {
            const rect = intersectRect(dropdownOptionRect(menu, visible_index), layout.body_clip) orelse continue;
            queue_hit(state, rect, action, scroll + visible_index);
        }
    }
}

fn openActionMenuRect(layout: SettingsLayout) palette.Rect {
    return dropdownMenuRect(layout.open_action_dropdown, OPEN_CHOICES.len);
}

fn registerOpenActionOptionHits(
    state: *runtime.AppState,
    layout: SettingsLayout,
    queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    if (!state.settings_controller.open_action_dropdown_open) return;
    const menu = openActionMenuRect(layout);
    for (0..OPEN_CHOICES.len) |option_index| {
        const rect = intersectRect(dropdownOptionRect(menu, option_index), layout.body_clip) orelse continue;
        queue_hit(state, rect, .settings_open_option, option_index);
    }
}

/// Registers palette hit targets for the settings modal.
pub fn registerHits(state: *runtime.AppState, width: f32, height: f32, queue_hit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void) void {
    focus_stop_count = 0;
    if (!state.settings_controller.modal_visible) {
        keyboard_focus = null;
        focus_ring_visible = false;
        return;
    }
    if (state.settings_controller.modal_closing) {
        // Swallow input during the fade-out; the controls are already gone.
        queue_hit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .modal_block, 0);
        return;
    }

    var layout = computeLayout(state, width, height);
    if (consumePendingRuntimesScroll(state, layout)) layout = computeLayout(state, width, height);
    state.settings_controller.scroll_y = theme.clampf(state.settings_controller.scroll_y, 0.0, layout.max_scroll_y);
    // Full-window dismiss so a click on the sidebar or workspace closes the
    // docked column. Panel chrome stays modal_block so empty space there does
    // not dismiss (and still closes open dropdowns).
    queue_hit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .modal_dismiss, 0);
    queue_hit(state, layout.modal, .modal_block, 0);
    queue_hit(state, layout.close, .settings_close, 0);
    for (settings_controller.Category.all, 0..) |_, index| {
        queue_hit(state, layout.nav[index], .settings_category, index);
        recordFocusStop(.settings_category, index, layout.nav[index], null);
    }
    focus_body_clip = layout.body_clip;
    const category = state.settings_controller.active_category;
    if (category == .appearance) {
        queueControlHit(state, layout.theme_dropdown, layout.body_clip, .theme_dropdown, queue_hit);
        queueControlHit(state, layout.ui_font_dec, layout.body_clip, .ui_font_dec, queue_hit);
        queueControlHit(state, layout.ui_font_inc, layout.body_clip, .ui_font_inc, queue_hit);
        queueControlHit(state, layout.reduced_motion, layout.body_clip, .reduced_motion, queue_hit);
        for (REDUCED_MOTION_PARTS, layout.reduced_motion_parts) |part, rect| {
            queueControlHit(state, rect, layout.body_clip, part.control, queue_hit);
        }
    }
    if (category == .companion) {
        queueControlHit(state, layout.companion_toggle, layout.body_clip, .companion_toggle, queue_hit);
        if (state.settings_controller.draft.companion_enabled) {
            queueControlHit(state, layout.companion_character_dropdown, layout.body_clip, .companion_character_dropdown, queue_hit);
        }
    }
    if (category == .workspace) {
        queueControlHit(state, layout.workspace_tabs_automatic, layout.body_clip, .workspace_tabs_automatic, queue_hit);
        queueControlHit(state, layout.workspace_tabs_always, layout.body_clip, .workspace_tabs_always, queue_hit);
        queueControlHit(state, layout.workspace_tabs_disabled, layout.body_clip, .workspace_tabs_disabled, queue_hit);
        queueControlHit(state, layout.open_action_dropdown, layout.body_clip, .open_action_dropdown, queue_hit);
        queueControlHit(state, layout.new_chat_new_pane, layout.body_clip, .new_chat_new_pane, queue_hit);
        queueControlHit(state, layout.new_chat_replace_pane, layout.body_clip, .new_chat_replace_pane, queue_hit);
        queueControlHit(state, layout.workspace_split_default_chat, layout.body_clip, .workspace_split_default_chat, queue_hit);
        queueControlHit(state, layout.workspace_split_default_terminal, layout.body_clip, .workspace_split_default_terminal, queue_hit);
        queueControlHit(state, layout.workspace_new_tab_chat, layout.body_clip, .workspace_new_tab_chat, queue_hit);
        queueControlHit(state, layout.workspace_new_tab_terminal, layout.body_clip, .workspace_new_tab_terminal, queue_hit);
        queueControlHit(state, layout.workspace_unzoom_on_navigation, layout.body_clip, .workspace_unzoom_on_navigation, queue_hit);
        queueControlHit(state, layout.workspace_scroll_mode_automatic, layout.body_clip, .workspace_scroll_mode_automatic, queue_hit);
        queueControlHit(state, layout.workspace_scroll_mode_always, layout.body_clip, .workspace_scroll_mode_always, queue_hit);
        queueControlHit(state, layout.workspace_scroll_mode_disabled, layout.body_clip, .workspace_scroll_mode_disabled, queue_hit);
        if (state.settings_controller.draft.workspace_scroll_mode == .automatic) {
            queueControlHit(state, layout.workspace_scroll_threshold_dec, layout.body_clip, .workspace_scroll_threshold_dec, queue_hit);
            queueControlHit(state, layout.workspace_scroll_threshold_inc, layout.body_clip, .workspace_scroll_threshold_inc, queue_hit);
        }
        queueControlHit(state, layout.workspace_pane_gap_dec, layout.body_clip, .workspace_pane_gap_dec, queue_hit);
        queueControlHit(state, layout.workspace_pane_gap_inc, layout.body_clip, .workspace_pane_gap_inc, queue_hit);
        queueControlHit(state, layout.workspace_panes_per_view_dec, layout.body_clip, .workspace_panes_per_view_dec, queue_hit);
        queueControlHit(state, layout.workspace_panes_per_view_inc, layout.body_clip, .workspace_panes_per_view_inc, queue_hit);
        queueControlHit(state, layout.workspace_scroll_horizontal, layout.body_clip, .workspace_scroll_horizontal, queue_hit);
        queueControlHit(state, layout.workspace_scroll_vertical, layout.body_clip, .workspace_scroll_vertical, queue_hit);
        queueControlHit(state, layout.navigation_back_record, layout.body_clip, .navigation_back_record, queue_hit);
        queueControlHit(state, layout.navigation_back_reset, layout.body_clip, .navigation_back_reset, queue_hit);
        queueControlHit(state, layout.navigation_forward_record, layout.body_clip, .navigation_forward_record, queue_hit);
        queueControlHit(state, layout.navigation_forward_reset, layout.body_clip, .navigation_forward_reset, queue_hit);
    }
    if (category == .chat) {
        queueControlHit(state, layout.tool_groups_collapsed, layout.body_clip, .tool_groups_collapsed, queue_hit);
        queueControlHit(state, layout.tool_groups_expanded, layout.body_clip, .tool_groups_expanded, queue_hit);
        queueControlHit(state, layout.tool_groups_remember_last, layout.body_clip, .tool_groups_remember_last, queue_hit);
        queueControlHit(state, layout.diff_layout_stacked, layout.body_clip, .diff_layout_stacked, queue_hit);
        queueControlHit(state, layout.diff_layout_split, layout.body_clip, .diff_layout_split, queue_hit);
        queueControlHit(state, layout.automatic_chat_titles, layout.body_clip, .automatic_chat_titles, queue_hit);
        if (state.settings_controller.draft.automatic_chat_titles_enabled) {
            queueControlHit(state, layout.chat_title_provider_dropdown, layout.body_clip, .chat_title_provider_dropdown, queue_hit);
            queueControlHit(state, layout.chat_title_model_dropdown, layout.body_clip, .chat_title_model_dropdown, queue_hit);
        }
        queueControlHit(state, layout.new_chat_provider_dropdown, layout.body_clip, .new_chat_provider_dropdown, queue_hit);
        queueControlHit(state, layout.new_chat_model_dropdown, layout.body_clip, .new_chat_model_dropdown, queue_hit);
        queueControlHit(state, layout.new_chat_reasoning_dropdown, layout.body_clip, .new_chat_reasoning_dropdown, queue_hit);
        queueControlHit(state, layout.file_links_neovim_pane, layout.body_clip, .file_links_neovim_pane, queue_hit);
        queueControlHit(state, layout.commit_provider_dropdown, layout.body_clip, .commit_provider_dropdown, queue_hit);
        queueControlHit(state, layout.commit_model_dropdown, layout.body_clip, .commit_model_dropdown, queue_hit);
        queueControlHit(state, layout.commit_action_commit, layout.body_clip, .commit_action_commit, queue_hit);
        queueControlHit(state, layout.commit_action_push, layout.body_clip, .commit_action_push, queue_hit);
    }
    if (category == .terminal) {
        queueControlHit(state, layout.terminal_font_dec, layout.body_clip, .terminal_font_dec, queue_hit);
        queueControlHit(state, layout.terminal_font_inc, layout.body_clip, .terminal_font_inc, queue_hit);
    }
    if (category == .browser) {
        queueControlHit(state, layout.links_verde_browser, layout.body_clip, .links_verde_browser, queue_hit);
        queueControlHit(state, layout.links_system_browser, layout.body_clip, .links_system_browser, queue_hit);
        queueControlHit(state, layout.chat_links_global, layout.body_clip, .chat_links_global, queue_hit);
        queueControlHit(state, layout.chat_links_verde_browser, layout.body_clip, .chat_links_verde_browser, queue_hit);
        queueControlHit(state, layout.chat_links_system_browser, layout.body_clip, .chat_links_system_browser, queue_hit);
        queueControlHit(state, layout.terminal_links_global, layout.body_clip, .terminal_links_global, queue_hit);
        queueControlHit(state, layout.terminal_links_verde_browser, layout.body_clip, .terminal_links_verde_browser, queue_hit);
        queueControlHit(state, layout.terminal_links_system_browser, layout.body_clip, .terminal_links_system_browser, queue_hit);
        queueControlHit(state, browserScrollSliderHitRect(layout.browser_scroll_speed), layout.body_clip, .browser_scroll_speed, queue_hit);
    }
    if (category == .providers) {
        for (layout.provider_rows, 0..) |row, index| {
            queueControlHit(state, row, layout.body_clip, providerRowControl(index), queue_hit);
        }
        // Registered after the row so Install/Update wins the overlap.
        // Latest and an unfinished check are labels, not buttons.
        const provider_snapshot = state.providerReadinessSnapshot();
        for (layout.provider_updates, 0..) |update, index| {
            const provider = settings_controller.settingsProviderForRow(index);
            switch (providerAction(&provider_snapshot, provider)) {
                .install, .update, .sign_in, .get_node => queueControlHit(state, update, layout.body_clip, providerUpdateControl(index), queue_hit),
                .latest, .pending, .none => {},
            }
        }
        queueControlHit(state, layout.providers_recheck, layout.body_clip, .providers_recheck, queue_hit);
        if (layout.providers_update_all.w > 0.0) queueControlHit(state, layout.providers_update_all, layout.body_clip, .providers_update_all, queue_hit);
        for (0..layout.custom_agent_count) |index| {
            recordFocusStop(.settings_custom_agent_edit, index, layout.custom_agent_edits[index], layout.body_clip);
            recordFocusStop(.settings_custom_agent_remove, index, layout.custom_agent_removes[index], layout.body_clip);
            if (intersectRect(layout.custom_agent_edits[index], layout.body_clip)) |rect| queue_hit(state, rect, .settings_custom_agent_edit, index);
            if (intersectRect(layout.custom_agent_removes[index], layout.body_clip)) |rect| queue_hit(state, rect, .settings_custom_agent_remove, index);
        }
        recordFocusStop(.settings_custom_agent_add, 0, layout.custom_agents_add, layout.body_clip);
        if (intersectRect(layout.custom_agents_add, layout.body_clip)) |rect| queue_hit(state, rect, .settings_custom_agent_add, 0);
    }
    if (category == .agents) {
        queueControlHit(state, layout.mcp_tools, layout.body_clip, .mcp_tools, queue_hit);
        queueControlHit(state, layout.hooks_claude, layout.body_clip, .hooks_claude, queue_hit);
        queueControlHit(state, layout.hooks_codex, layout.body_clip, .hooks_codex, queue_hit);
        queueControlHit(state, layout.hooks_cursor, layout.body_clip, .hooks_cursor, queue_hit);
        queueControlHit(state, layout.hooks_opencode, layout.body_clip, .hooks_opencode, queue_hit);
        queueControlHit(state, layout.hooks_grok, layout.body_clip, .hooks_grok, queue_hit);
        queueControlHit(state, layout.hooks_amp, layout.body_clip, .hooks_amp, queue_hit);
        queueControlHit(state, layout.hooks_pi, layout.body_clip, .hooks_pi, queue_hit);
    }
    if (category == .app) {
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
    }
    if (category == .connections) {
        _ = phoneCard(state, layout.phone_card, layout.body_clip, false, queue_hit);
        registerRuntimeCardHits(state, layout, queue_hit);
    }
    // Close ends the Tab cycle: nav, then the page, then the header button.
    recordFocusStop(.settings_close, 0, layout.close, null);
    registerThemeOptionHits(state, layout, queue_hit);
    registerCompanionCharacterOptionHits(state, layout, queue_hit);
    registerTitleOptionHits(state, layout, queue_hit);
    registerNewChatOptionHits(state, layout, queue_hit);
    registerCommitOptionHits(state, layout, queue_hit);
    registerOpenActionOptionHits(state, layout, queue_hit);
}

pub fn applySettingsCategory(state: *runtime.AppState, index: usize) void {
    if (index >= settings_controller.Category.all.len) return;
    state.selectSettingsCategory(settings_controller.Category.all[index]);
}

fn openActionDraftLabel(state: *const runtime.AppState) []const u8 {
    if (state.settings_controller.draft.open_action == .custom) return "Custom";
    return OPEN_CHOICES[openActionSelectedIndex(state)].label;
}

/// Renders the docked settings column over the workspace.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.settings_controller.modal_visible) return;
    state.tickSettingsModalAnimation();
    if (!state.settings_controller.modal_visible) return;
    settings_text.beginFrame(width, height);
    const fade_t = theme.clampf(state.settings_controller.modal_anim_progress, 0.0, 1.0);
    current_fade_alpha = fade_t * fade_t * (3.0 - 2.0 * fade_t);
    defer current_fade_alpha = 1.0;

    const m = metrics();
    var layout = computeLayout(state, width, height);
    if (consumePendingRuntimesScroll(state, layout)) layout = computeLayout(state, width, height);
    state.settings_controller.scroll_y = theme.clampf(state.settings_controller.scroll_y, 0.0, layout.max_scroll_y);
    drawModalChrome(state, width, height, layout.modal);
    drawHeaderBar(state, layout);
    drawCategoryNav(state, layout);
    queueRoundedRect(state, .{
        .x = layout.content.x - theme.scaledUi(1.0),
        .y = layout.content.y,
        .w = theme.scaledUi(1.0),
        .h = layout.content.h,
    }, paletteColor(theme.withAlpha(theme.borderMuted(), 90)), 0.0);

    const category = state.settings_controller.active_category;
    if (category == .appearance) {
        drawCard(state, layout.appearance_card, layout.body_clip);
        drawCardTitle(state, layout.appearance_card, "Appearance", layout.body_clip);
        drawFieldLabel(state, layout.appearance_card, m, "Theme", layout.body_clip);
        drawThemeDropdown(state, layout);
        drawStepperRow(state, layout.appearance_card, m, layout.ui_font_dec.y, "UI font", state.settings_controller.draft.font_size, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE, .ui_font_dec, .ui_font_inc, layout.ui_font_dec, layout.ui_font_inc, layout.body_clip);
        const motion = state.settings_controller.draft.reduced_motion;
        drawSwitchRow(state, layout.reduced_motion, "Reduce motion", motion.all(), isControlHovered(state, .reduced_motion), layout.body_clip);
        for (REDUCED_MOTION_PARTS, layout.reduced_motion_parts) |part, rect| {
            drawSwitchRow(state, rect, part.label, reducedMotionPart(motion, part.part), isControlHovered(state, part.control), layout.body_clip);
        }
    } else if (category == .companion) {
        drawCard(state, layout.companion_card, layout.body_clip);
        drawCardTitle(state, layout.companion_card, "Companion", layout.body_clip);
        drawSwitchRow(state, layout.companion_toggle, "Show companion", state.settings_controller.draft.companion_enabled, isControlHovered(state, .companion_toggle), layout.body_clip);
        queueText(state, .{
            .x = layout.companion_card.x + m.card_pad,
            .y = layout.companion_hint_y,
            .w = layout.companion_card.w - m.card_pad * 2.0,
            .h = m.label_h,
        }, COMPANION_HINT, paletteColor(textHint()), theme.scaledUi(12.5), layout.body_clip);
        if (state.settings_controller.draft.companion_enabled) {
            queueText(state, .{
                .x = layout.companion_card.x + m.card_pad,
                .y = layout.companion_character_label_y,
                .w = layout.companion_card.w - m.card_pad * 2.0,
                .h = m.label_h,
            }, "Character", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
            drawCompanionCharacterDropdown(state, layout);
        }
    } else if (category == .workspace) {
        drawCard(state, layout.workspace_card, layout.body_clip);
        drawCardTitle(state, layout.workspace_card, "Workspace", layout.body_clip);
        queueText(state, .{
            .x = layout.workspace_card.x + m.card_pad,
            .y = layout.workspace_tabs_label_y,
            .w = layout.workspace_card.w - m.card_pad * 2.0,
            .h = m.label_h,
        }, "Tabs", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawToggleCell(state, layout.workspace_tabs_automatic, "Auto", state.settings_controller.draft.workspace_tabs == .automatic, isControlHovered(state, .workspace_tabs_automatic), layout.body_clip);
        drawToggleCell(state, layout.workspace_tabs_always, "Always", state.settings_controller.draft.workspace_tabs == .always, isControlHovered(state, .workspace_tabs_always), layout.body_clip);
        drawToggleCell(state, layout.workspace_tabs_disabled, "Off", state.settings_controller.draft.workspace_tabs == .disabled, isControlHovered(state, .workspace_tabs_disabled), layout.body_clip);
        queueText(state, .{
            .x = layout.open_action_dropdown.x,
            .y = layout.open_action_dropdown.y - m.inner_gap - m.label_h,
            .w = layout.open_action_dropdown.w,
            .h = m.label_h,
        }, "Open with", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawChatTitleDropdown(state, layout.open_action_dropdown, openActionDraftLabel(state), .open_action_dropdown, state.settings_controller.open_action_dropdown_open, layout.body_clip);
        queueText(state, .{
            .x = layout.new_chat_new_pane.x,
            .y = layout.new_chat_new_pane.y - m.inner_gap - m.label_h,
            .w = layout.new_chat_new_pane.w + layout.new_chat_replace_pane.w,
            .h = m.label_h,
        }, "New chat", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSegmentedPair(state, layout.new_chat_new_pane, layout.new_chat_replace_pane, "New pane", "Replace", state.settings_controller.draft.new_chat_pane_behavior == .new_pane, isControlHovered(state, .new_chat_new_pane), isControlHovered(state, .new_chat_replace_pane), layout.body_clip);
        queueText(state, .{
            .x = layout.workspace_split_default_chat.x,
            .y = layout.workspace_split_default_chat.y - m.inner_gap - m.label_h,
            .w = layout.workspace_split_default_chat.w + layout.workspace_split_default_terminal.w,
            .h = m.label_h,
        }, "Split", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSegmentedPair(state, layout.workspace_split_default_chat, layout.workspace_split_default_terminal, "Chat", "Terminal", state.settings_controller.draft.workspace_split_default_pane == .chat, isControlHovered(state, .workspace_split_default_chat), isControlHovered(state, .workspace_split_default_terminal), layout.body_clip);
        queueText(state, .{
            .x = layout.workspace_new_tab_chat.x,
            .y = layout.workspace_new_tab_chat.y - m.inner_gap - m.label_h,
            .w = layout.workspace_new_tab_chat.w + layout.workspace_new_tab_terminal.w,
            .h = m.label_h,
        }, "New tab", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSegmentedPair(state, layout.workspace_new_tab_chat, layout.workspace_new_tab_terminal, "Chat", "Terminal", state.settings_controller.draft.workspace_new_tab_pane == .chat, isControlHovered(state, .workspace_new_tab_chat), isControlHovered(state, .workspace_new_tab_terminal), layout.body_clip);
        drawSwitchRow(state, layout.workspace_unzoom_on_navigation, "Unzoom on navigate", state.settings_controller.draft.unzoom_on_pane_navigation, isControlHovered(state, .workspace_unzoom_on_navigation), layout.body_clip);
        drawStepperRow(state, layout.workspace_card, m, layout.workspace_pane_gap_dec.y, "Pane gap", state.settings_controller.draft.workspace_pane_gap, app_config.MIN_WORKSPACE_PANE_GAP, app_config.MAX_WORKSPACE_PANE_GAP, .workspace_pane_gap_dec, .workspace_pane_gap_inc, layout.workspace_pane_gap_dec, layout.workspace_pane_gap_inc, layout.body_clip);
        drawStepperRow(state, layout.workspace_card, m, layout.workspace_panes_per_view_dec.y, "Panes per view", @floatFromInt(state.settings_controller.draft.workspace_panes_per_view), @floatFromInt(app_config.MIN_WORKSPACE_PANES_PER_VIEW), @floatFromInt(app_config.MAX_WORKSPACE_PANES_PER_VIEW), .workspace_panes_per_view_dec, .workspace_panes_per_view_inc, layout.workspace_panes_per_view_dec, layout.workspace_panes_per_view_inc, layout.body_clip);
        queueText(state, .{
            .x = layout.workspace_scroll_mode_automatic.x,
            .y = layout.workspace_scroll_mode_automatic.y - m.inner_gap - m.label_h,
            .w = layout.workspace_scroll_mode_automatic.w + layout.workspace_scroll_mode_always.w + layout.workspace_scroll_mode_disabled.w,
            .h = m.label_h,
        }, "Scrolling", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSegmentedTriple(
            state,
            layout.workspace_scroll_mode_automatic,
            layout.workspace_scroll_mode_always,
            layout.workspace_scroll_mode_disabled,
            .{ "Auto", "Always", "Off" },
            @intFromEnum(state.settings_controller.draft.workspace_scroll_mode),
            .{
                isControlHovered(state, .workspace_scroll_mode_automatic),
                isControlHovered(state, .workspace_scroll_mode_always),
                isControlHovered(state, .workspace_scroll_mode_disabled),
            },
            layout.body_clip,
        );
        if (state.settings_controller.draft.workspace_scroll_mode == .automatic) {
            drawStepperRow(state, layout.workspace_card, m, layout.workspace_scroll_threshold_dec.y, "Start after", @floatFromInt(state.settings_controller.draft.workspace_scroll_threshold), @floatFromInt(app_config.MIN_WORKSPACE_SCROLL_THRESHOLD), @floatFromInt(app_config.MAX_WORKSPACE_SCROLL_THRESHOLD), .workspace_scroll_threshold_dec, .workspace_scroll_threshold_inc, layout.workspace_scroll_threshold_dec, layout.workspace_scroll_threshold_inc, layout.body_clip);
        }
        queueText(state, .{
            .x = layout.workspace_scroll_horizontal.x,
            .y = layout.workspace_scroll_horizontal.y - m.inner_gap - m.label_h,
            .w = layout.workspace_scroll_horizontal.w + layout.workspace_scroll_vertical.w,
            .h = m.label_h,
        }, "Direction", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSegmentedPair(state, layout.workspace_scroll_horizontal, layout.workspace_scroll_vertical, "Horizontal", "Vertical", state.settings_controller.draft.workspace_scroll_direction == .horizontal, isControlHovered(state, .workspace_scroll_horizontal), isControlHovered(state, .workspace_scroll_vertical), layout.body_clip);
        drawNavigationCard(state, layout, m);
    } else if (category == .chat) {
        drawCard(state, layout.transcript_card, layout.body_clip);
        drawCardTitle(state, layout.transcript_card, "Transcript", layout.body_clip);
        drawFieldLabel(state, layout.transcript_card, m, "Tool groups", layout.body_clip);
        drawToggleCell(state, layout.tool_groups_collapsed, "Collapse", state.settings_controller.draft.tool_call_group_preference == .collapsed, isControlHovered(state, .tool_groups_collapsed), layout.body_clip);
        drawToggleCell(state, layout.tool_groups_expanded, "Expand", state.settings_controller.draft.tool_call_group_preference == .expanded, isControlHovered(state, .tool_groups_expanded), layout.body_clip);
        drawToggleCell(state, layout.tool_groups_remember_last, "Remember", state.settings_controller.draft.tool_call_group_preference == .remember_last, isControlHovered(state, .tool_groups_remember_last), layout.body_clip);
        queueText(state, .{
            .x = layout.diff_layout_stacked.x,
            .y = layout.diff_layout_stacked.y - m.inner_gap - m.label_h,
            .w = layout.diff_layout_stacked.w + layout.diff_layout_split.w,
            .h = m.label_h,
        }, "Diff", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSegmentedPair(state, layout.diff_layout_stacked, layout.diff_layout_split, "Stacked", "Split", state.settings_controller.draft.diff_layout_preference == .stacked, isControlHovered(state, .diff_layout_stacked), isControlHovered(state, .diff_layout_split), layout.body_clip);

        drawCard(state, layout.chat_card, layout.body_clip);
        drawCardTitle(state, layout.chat_card, "Chat", layout.body_clip);
        drawSwitchRow(state, layout.automatic_chat_titles, "Auto-name chats", state.settings_controller.draft.automatic_chat_titles_enabled, isControlHovered(state, .automatic_chat_titles), layout.body_clip);
        if (state.settings_controller.draft.automatic_chat_titles_enabled) {
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
        }
        const new_chat_defaults_label_y = layout.new_chat_provider_dropdown.y - m.inner_gap - m.label_h;
        queueText(state, .{ .x = layout.new_chat_provider_dropdown.x, .y = new_chat_defaults_label_y, .w = layout.new_chat_provider_dropdown.w, .h = m.label_h }, "New chat", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        queueText(state, .{ .x = layout.new_chat_model_dropdown.x, .y = new_chat_defaults_label_y, .w = layout.new_chat_model_dropdown.w, .h = m.label_h }, "Model", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        queueText(state, .{ .x = layout.new_chat_reasoning_dropdown.x, .y = new_chat_defaults_label_y, .w = layout.new_chat_reasoning_dropdown.w, .h = m.label_h }, "Reasoning", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawChatTitleDropdown(state, layout.new_chat_provider_dropdown, state.settingsNewChatProviderLabel(state.settingsNewChatProviderSelectedIndex()), .new_chat_provider_dropdown, state.settings_controller.new_chat_provider_dropdown_open, layout.body_clip);
        drawChatTitleDropdown(state, layout.new_chat_model_dropdown, state.settingsNewChatModelSelectedLabel(), .new_chat_model_dropdown, state.settings_controller.new_chat_model_dropdown_open, layout.body_clip);
        drawChatTitleDropdown(state, layout.new_chat_reasoning_dropdown, state.settingsNewChatReasoningSelectedLabel(), .new_chat_reasoning_dropdown, state.settings_controller.new_chat_reasoning_dropdown_open, layout.body_clip);
        drawSwitchRow(state, layout.file_links_neovim_pane, "File links in Neovim", state.settings_controller.draft.file_links_in_neovim_pane, isControlHovered(state, .file_links_neovim_pane), layout.body_clip);
        drawCommitCard(state, layout, m);
    } else if (category == .terminal) {
        drawCard(state, layout.terminal_card, layout.body_clip);
        drawCardTitle(state, layout.terminal_card, "Terminal", layout.body_clip);
        drawStepperRow(state, layout.terminal_card, m, layout.terminal_font_dec.y, "Font size", state.settings_controller.draft.terminal_font_size, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE, .terminal_font_dec, .terminal_font_inc, layout.terminal_font_dec, layout.terminal_font_inc, layout.body_clip);
    } else if (category == .browser) {
        drawCard(state, layout.browser_card, layout.body_clip);
        drawCardTitle(state, layout.browser_card, "Browser", layout.body_clip);
        queueText(state, .{ .x = layout.links_verde_browser.x, .y = layout.links_verde_browser.y - m.inner_gap - m.label_h, .w = layout.links_verde_browser.w + layout.links_system_browser.w, .h = m.label_h }, "Web links", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSegmentedPair(state, layout.links_verde_browser, layout.links_system_browser, "Verde", "System", state.settings_controller.draft.link_open_target == .verde_browser, isControlHovered(state, .links_verde_browser), isControlHovered(state, .links_system_browser), layout.body_clip);
        queueText(state, .{ .x = layout.chat_links_global.x, .y = layout.chat_links_global.y - m.inner_gap - m.label_h, .w = layout.chat_links_global.w * 3.0, .h = m.label_h }, "Chat links", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSegmentedTriple(state, layout.chat_links_global, layout.chat_links_verde_browser, layout.chat_links_system_browser, .{ "Global", "Verde", "System" }, @intFromEnum(state.settings_controller.draft.chat_link_open_override), .{ isControlHovered(state, .chat_links_global), isControlHovered(state, .chat_links_verde_browser), isControlHovered(state, .chat_links_system_browser) }, layout.body_clip);
        queueText(state, .{ .x = layout.terminal_links_global.x, .y = layout.terminal_links_global.y - m.inner_gap - m.label_h, .w = layout.terminal_links_global.w * 3.0, .h = m.label_h }, "Terminal links", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSegmentedTriple(state, layout.terminal_links_global, layout.terminal_links_verde_browser, layout.terminal_links_system_browser, .{ "Global", "Verde", "System" }, @intFromEnum(state.settings_controller.draft.terminal_link_open_override), .{ isControlHovered(state, .terminal_links_global), isControlHovered(state, .terminal_links_verde_browser), isControlHovered(state, .terminal_links_system_browser) }, layout.body_clip);
        drawBrowserScrollSpeedSlider(state, layout.browser_scroll_speed, state.settings_controller.draft.browser_scroll_speed, isControlHovered(state, .browser_scroll_speed), layout.body_clip);
    } else if (category == .providers) {
        drawProvidersCard(state, layout, m);
        drawCustomAgentsCard(state, layout, m);
    } else if (category == .connections) {
        _ = phoneCard(state, layout.phone_card, layout.body_clip, true, null);
        drawRuntimeCard(state, layout);
    } else if (category == .agents) {
        drawCard(state, layout.integrations_card, layout.body_clip);
        drawCardTitle(state, layout.integrations_card, "Agents", layout.body_clip);
        drawFieldLabel(state, layout.integrations_card, m, "Verde MCP", layout.body_clip);
        const mcp_installed = state.settings_controller.mcp_summary.installedCount() > 0;
        drawSwitchRow(state, layout.mcp_tools, "Enable Verde MCP", mcp_installed, isControlHovered(state, .mcp_tools), layout.body_clip);
        const mcp_summary = state.settings_controller.mcp_summary;
        var mcp_names_buf: [96]u8 = undefined;
        var mcp_status_buf: [200]u8 = undefined;
        const mcp_status = if (mcp_summary.detectedCount() == 0)
            "No supported providers detected"
        else if (!mcp_installed and mcp_summary.failedCount() == 0)
            // Off: say what turning it on would cover, not "Installed for 0".
            std.fmt.bufPrint(&mcp_status_buf, "Off · {d} detected provider{s} can use Verde's tools", .{ mcp_summary.detectedCount(), if (mcp_summary.detectedCount() == 1) "" else "s" }) catch "Off"
        else if (mcp_summary.failedCount() > 0)
            std.fmt.bufPrint(&mcp_status_buf, "Installed for {d} · could not update {s}", .{ mcp_summary.installedCount(), mcpProviderNames(&mcp_names_buf, mcp_summary, .failed) }) catch "Some provider configs could not be updated"
        else if (mcp_summary.conflictCount() > 0)
            std.fmt.bufPrint(&mcp_status_buf, "Installed for {d} · kept the existing verde entry for {s}", .{ mcp_summary.installedCount(), mcpProviderNames(&mcp_names_buf, mcp_summary, .conflict) }) catch "Some existing verde entries were preserved"
        else
            std.fmt.bufPrint(&mcp_status_buf, "Installed for {d} of {d} detected", .{ mcp_summary.installedCount(), mcp_summary.detectedCount() }) catch "Workspace-aware in Verde panes";
        const mcp_text_w = layout.integrations_card.w - m.card_pad * 2.0;
        var mcp_status_fit_buf: [200]u8 = undefined;
        queueText(state, .{
            .x = layout.integrations_card.x + m.card_pad,
            .y = layout.mcp_hint_y,
            .w = mcp_text_w,
            .h = m.label_h,
        }, ellipsizedText(&mcp_status_fit_buf, mcp_status, theme.scaledUi(12.0), mcp_text_w), paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);
        // Only true while Verde's entry is actually in Codex's config.
        if (mcp_summary.codex == .installed) {
            var mcp_note_buf: [160]u8 = undefined;
            queueText(state, .{
                .x = layout.integrations_card.x + m.card_pad,
                .y = layout.mcp_note_y,
                .w = mcp_text_w,
                .h = m.label_h,
            }, ellipsizedText(&mcp_note_buf, MCP_AUTO_APPROVE_NOTE, theme.scaledUi(12.0), mcp_text_w), paletteColor(textHint()), theme.scaledUi(12.0), layout.body_clip);
        }
        queueText(state, .{
            .x = layout.integrations_card.x + m.card_pad,
            .y = layout.hooks_label_y,
            .w = layout.integrations_card.w - m.card_pad * 2.0,
            .h = m.label_h,
        }, "Status hooks", paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        drawSwitchRow(state, layout.hooks_claude, "Claude", state.settings_controller.hook_claude_installed, isControlHovered(state, .hooks_claude), layout.body_clip);
        drawSwitchRow(state, layout.hooks_codex, "Codex", state.settings_controller.hook_codex_installed, isControlHovered(state, .hooks_codex), layout.body_clip);
        drawSwitchRow(state, layout.hooks_cursor, "Cursor", state.settings_controller.hook_cursor_installed, isControlHovered(state, .hooks_cursor), layout.body_clip);
        drawSwitchRow(state, layout.hooks_opencode, "OpenCode", state.settings_controller.hook_opencode_installed, isControlHovered(state, .hooks_opencode), layout.body_clip);
        drawSwitchRow(state, layout.hooks_grok, "Grok", state.settings_controller.hook_grok_installed, isControlHovered(state, .hooks_grok), layout.body_clip);
        drawSwitchRow(state, layout.hooks_amp, "Amp", state.settings_controller.hook_amp_installed, isControlHovered(state, .hooks_amp), layout.body_clip);
        drawSwitchRow(state, layout.hooks_pi, "Pi", state.settings_controller.hook_pi_installed, isControlHovered(state, .hooks_pi), layout.body_clip);
    } else if (category == .app) {
        drawCard(state, layout.updates_card, layout.body_clip);
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
        if (state.settings_controller.package_update_command) |command| {
            const hint_y = layout.updates_automatic.y + m.row_h + m.inner_gap;
            const hint_w = layout.updates_card.w - m.card_pad * 2.0;
            const hint_h = wrappedNotesRows(PACKAGE_UPDATE_HINT, hint_w) * notesLineHeight();
            queueWrappedText(state, .{
                .x = layout.updates_card.x + m.card_pad,
                .y = hint_y,
                .w = hint_w,
                .h = hint_h,
            }, PACKAGE_UPDATE_HINT, paletteColor(textHint()), theme.scaledUi(NOTES_FONT_SIZE), layout.body_clip);
            queueText(state, .{
                .x = layout.updates_card.x + m.card_pad,
                .y = hint_y + hint_h,
                .w = hint_w,
                .h = m.label_h,
            }, command, paletteColor(textLabel()), theme.scaledUi(12.5), layout.body_clip);
        }
        const notes_x = layout.updates_card.x + m.card_pad;
        const notes_w = layout.updates_card.w - m.card_pad * 2.0;
        if (state.settings_controller.update_notes_expanded and state.settings_controller.update.release != null) {
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

        drawCard(state, layout.notifications_card, layout.body_clip);
        drawCardTitle(state, layout.notifications_card, "Notifications", layout.body_clip);
        drawSwitchRow(state, layout.notifications_toggle, "Agent status", state.settings_controller.draft.notifications_enabled, isControlHovered(state, .notifications_toggle), layout.body_clip);
    }

    drawBodyScrollbar(state, layout);
    drawFocusRing(state);
    drawThemeDropdownMenu(state, layout);
    drawCompanionCharacterDropdownMenu(state, layout);
    drawChatTitleDropdownMenu(state, layout, true);
    drawChatTitleDropdownMenu(state, layout, false);
    drawNewChatDropdownMenu(state, layout, .provider);
    drawNewChatDropdownMenu(state, layout, .model);
    drawNewChatDropdownMenu(state, layout, .reasoning);
    drawCommitDropdownMenu(state, layout);
    drawOpenActionDropdownMenu(state, layout);
    settings_text.drawMenu(state);
}

/// Scrolls settings modal content within the fixed header/footer chrome.
pub fn handleWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    if (!state.settings_controller.modal_visible) return false;
    if (state.settings_controller.modal_closing) return true;

    const layout = computeLayout(state, width, height);
    if (!rectContains(layout.modal, x, y)) return false;
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
    // Fixed three-row companion menu: consume wheel so the body does not scroll under it.
    if (state.settings_controller.companion_character_dropdown_open and rectContains(companionCharacterMenuRect(layout), x, y)) return true;
    if (state.settings_controller.open_action_dropdown_open and rectContains(openActionMenuRect(layout), x, y)) return true;
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
    if (state.settings_controller.commit_menu != null and rectContains(commitMenuRect(state, layout, state.settings_controller.commit_menu.?), x, y)) {
        if (state.settings_controller.commit_menu.? == .model) {
            const max_scroll = commitMenuMaxScroll(state, .model);
            const current = state.settings_controller.commit_model_menu_scroll;
            const next = if (wheel_y < 0.0) @min(current + 1, max_scroll) else if (wheel_y > 0.0) current -| 1 else current;
            if (next != current) {
                state.settings_controller.commit_model_menu_scroll = next;
                state.markDirty();
            }
        }
        return true;
    }
    if (state.settings_controller.new_chat_model_dropdown_open and rectContains(newChatMenuRect(state, layout, .model), x, y)) {
        const max_scroll = newChatModelMenuMaxScroll(state);
        const next = if (wheel_y < 0.0)
            @min(state.settings_controller.new_chat_model_menu_scroll + 1, max_scroll)
        else if (wheel_y > 0.0)
            state.settings_controller.new_chat_model_menu_scroll -| 1
        else
            state.settings_controller.new_chat_model_menu_scroll;
        if (next != state.settings_controller.new_chat_model_menu_scroll) {
            state.settings_controller.new_chat_model_menu_scroll = next;
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
        if (state.settings_controller.hover_control != null or state.settings_controller.hover_runtime_action != null or state.settings_controller.close_hovered or state.settings_controller.hover_category != null or state.settings_controller.open_action_hover_index != null or state.settings_controller.theme_hover_index != null or state.settings_controller.companion_character_hover_index != null or state.settings_controller.title_menu_hover_index != null or state.settings_controller.new_chat_menu_hover_index != null) {
            state.settings_controller.hover_control = null;
            state.settings_controller.hover_runtime_action = null;
            state.settings_controller.close_hovered = false;
            state.settings_controller.hover_category = null;
            state.settings_controller.open_action_hover_index = null;
            state.settings_controller.theme_hover_index = null;
            state.settings_controller.companion_character_hover_index = null;
            state.settings_controller.title_menu_hover_index = null;
            state.settings_controller.new_chat_menu_hover_index = null;
            state.markDirty();
        }
        return;
    }

    var new_hover: ?u8 = null;
    var runtime_hover: ?usize = null;
    var theme_hover: ?usize = null;
    var companion_hover: ?usize = null;
    var title_hover: ?usize = null;
    var new_chat_hover: ?usize = null;
    var commit_hover: ?usize = null;
    var category_hover: ?u8 = null;
    var open_action_hover: ?usize = null;
    var close_hovered = false;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (hit.action == .settings_close) {
            if (rectContains(hit.rect, x, y)) close_hovered = true;
            continue;
        }
        if (hit.action == .settings_category and rectContains(hit.rect, x, y)) {
            category_hover = @intCast(hit.index);
            break;
        }
        if (hit.action == .settings_open_option and rectContains(hit.rect, x, y)) {
            open_action_hover = hit.index;
            break;
        }
        if (hit.action == .settings_theme_option and rectContains(hit.rect, x, y)) {
            if (state.settings_controller.companion_character_dropdown_open) {
                companion_hover = hit.index;
            } else {
                theme_hover = hit.index;
            }
            break;
        }
        if ((hit.action == .settings_title_provider_option or hit.action == .settings_title_model_option) and rectContains(hit.rect, x, y)) {
            title_hover = hit.index;
            break;
        }
        if ((hit.action == .settings_new_chat_provider_option or hit.action == .settings_new_chat_model_option or hit.action == .settings_new_chat_reasoning_option) and rectContains(hit.rect, x, y)) {
            new_chat_hover = hit.index;
            break;
        }
        if (hit.action == .settings_commit_option and rectContains(hit.rect, x, y)) {
            commit_hover = hit.index;
            break;
        }
        if (hit.action == .settings_phone_action and rectContains(hit.rect, x, y)) {
            runtime_hover = hit.index | PHONE_HOVER_BIT;
            break;
        }
        if (hit.action == .settings_runtime_action and rectContains(hit.rect, x, y)) {
            runtime_hover = hit.index;
            break;
        }
        if (hit.action != .settings_control) continue;
        if (!rectContains(hit.rect, x, y)) continue;
        new_hover = @intCast(hit.index);
        break;
    }

    if (state.settings_controller.hover_control == new_hover and state.settings_controller.hover_runtime_action == runtime_hover and state.settings_controller.close_hovered == close_hovered and state.settings_controller.hover_category == category_hover and state.settings_controller.open_action_hover_index == open_action_hover and state.settings_controller.theme_hover_index == theme_hover and state.settings_controller.companion_character_hover_index == companion_hover and state.settings_controller.title_menu_hover_index == title_hover and state.settings_controller.new_chat_menu_hover_index == new_chat_hover and (state.settings_controller.commit_menu == null or state.settings_controller.commit_menu_hover_index == commit_hover)) return;
    state.settings_controller.hover_control = new_hover;
    state.settings_controller.hover_runtime_action = runtime_hover;
    state.settings_controller.close_hovered = close_hovered;
    state.settings_controller.hover_category = category_hover;
    state.settings_controller.open_action_hover_index = open_action_hover;
    state.settings_controller.theme_hover_index = theme_hover;
    state.settings_controller.companion_character_hover_index = companion_hover;
    state.settings_controller.title_menu_hover_index = title_hover;
    state.settings_controller.new_chat_menu_hover_index = new_chat_hover;
    if (state.settings_controller.commit_menu != null) state.settings_controller.commit_menu_hover_index = commit_hover;
    state.markDirty();
}

/// Applies a settings control interaction to the in-modal draft.
pub fn applyControlAt(state: *runtime.AppState, control_index: usize, rect: palette.Rect, x: f32) void {
    applyControl(state, control_index);
    const control: Control = @enumFromInt(control_index);
    if (control != .browser_scroll_speed) return;
    state.settings_controller.browser_scroll_speed_drag_active = true;
    state.settings_controller.browser_scroll_speed_drag_x = rect.x;
    state.settings_controller.browser_scroll_speed_drag_w = rect.w;
    _ = updateBrowserScrollSpeedDrag(state, x);
}

/// Updates the browser scroll-speed draft while its settings slider owns the pointer.
pub fn updateBrowserScrollSpeedDrag(state: *runtime.AppState, x: f32) bool {
    if (!state.settings_controller.browser_scroll_speed_drag_active) return false;
    const track: palette.Rect = .{
        .x = state.settings_controller.browser_scroll_speed_drag_x,
        .y = 0.0,
        .w = state.settings_controller.browser_scroll_speed_drag_w,
        .h = 1.0,
    };
    const next = browserScrollSpeedFromPoint(track, x);
    if (next != state.settings_controller.draft.browser_scroll_speed) {
        state.settings_controller.draft.browser_scroll_speed = next;
        state.markDirty();
    }
    return true;
}

/// Releases any pointer capture held by the browser scroll-speed slider.
pub fn endBrowserScrollSpeedDrag(state: *runtime.AppState) void {
    if (!state.settings_controller.browser_scroll_speed_drag_active) return;
    state.settings_controller.browser_scroll_speed_drag_active = false;
    state.commitSettingsPreference();
}

/// Applies a settings control that does not require pointer geometry.
pub fn applyControl(state: *runtime.AppState, control_index: usize) void {
    const control: Control = @enumFromInt(control_index);
    if (control != .theme_dropdown) {
        state.settings_controller.theme_dropdown_open = false;
        state.settings_controller.theme_hover_index = null;
    }
    if (control != .companion_character_dropdown) {
        state.settings_controller.companion_character_dropdown_open = false;
        state.settings_controller.companion_character_hover_index = null;
    }
    if (control != .chat_title_provider_dropdown) state.settings_controller.title_provider_dropdown_open = false;
    if (control != .chat_title_model_dropdown) state.settings_controller.title_model_dropdown_open = false;
    if (control != .chat_title_provider_dropdown and control != .chat_title_model_dropdown) state.settings_controller.title_menu_hover_index = null;
    if (control != .new_chat_provider_dropdown) state.settings_controller.new_chat_provider_dropdown_open = false;
    if (control != .new_chat_model_dropdown) state.settings_controller.new_chat_model_dropdown_open = false;
    if (control != .new_chat_reasoning_dropdown) state.settings_controller.new_chat_reasoning_dropdown_open = false;
    if (control != .open_action_dropdown) {
        state.settings_controller.open_action_dropdown_open = false;
        state.settings_controller.open_action_hover_index = null;
    }
    if (control != .commit_provider_dropdown and control != .commit_model_dropdown) {
        state.settings_controller.commit_menu = null;
        state.settings_controller.commit_menu_hover_index = null;
    }
    if (applyNavigationControl(state, control)) return;
    switch (control) {
        .commit_provider_dropdown => toggleCommitMenu(state, .provider),
        .commit_model_dropdown => toggleCommitMenu(state, .model),
        .commit_action_commit => settings_controller.selectSettingsCommitAction(state, .commit),
        .commit_action_push => settings_controller.selectSettingsCommitAction(state, .commit_and_push),
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
        .workspace_split_default_chat => state.settings_controller.draft.workspace_split_default_pane = .chat,
        .workspace_split_default_terminal => state.settings_controller.draft.workspace_split_default_pane = .terminal,
        .workspace_new_tab_chat => state.settings_controller.draft.workspace_new_tab_pane = .chat,
        .workspace_new_tab_terminal => state.settings_controller.draft.workspace_new_tab_pane = .terminal,
        .workspace_scroll_use_global => {
            state.settings_controller.draft.workspace_scroll_override_enabled = false;
            state.settings_controller.draft.workspace_scroll_mode = state.app_config.workspace_scroll_mode;
            state.settings_controller.draft.workspace_scroll_threshold = state.app_config.workspace_scroll_threshold;
        },
        .workspace_scroll_override => state.settings_controller.draft.workspace_scroll_override_enabled = true,
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
        .reduced_motion => {
            const motion = &state.settings_controller.draft.reduced_motion;
            motion.setAll(!motion.all());
        },
        .reduced_motion_pane_scroll,
        .reduced_motion_pane_layout,
        .reduced_motion_status_pulse,
        .reduced_motion_chat,
        .reduced_motion_chrome,
        .reduced_motion_companion,
        => {
            const motion = &state.settings_controller.draft.reduced_motion;
            for (REDUCED_MOTION_PARTS) |part| {
                if (part.control == control) toggleReducedMotionPart(motion, part.part);
            }
        },
        .workspace_tabs_automatic => state.settings_controller.draft.workspace_tabs = .automatic,
        .workspace_tabs_always => state.settings_controller.draft.workspace_tabs = .always,
        .workspace_tabs_disabled => state.settings_controller.draft.workspace_tabs = .disabled,
        .theme_dropdown => {
            state.settings_controller.theme_dropdown_open = !state.settings_controller.theme_dropdown_open;
            if (state.settings_controller.theme_dropdown_open) {
                state.settings_controller.companion_character_dropdown_open = false;
                state.settings_controller.companion_character_hover_index = null;
                state.settings_controller.theme_hover_index = state.settings_controller.draft.theme_choice;
                ensureThemeChoiceVisible(state, state.settings_controller.draft.theme_choice);
            } else {
                state.settings_controller.theme_hover_index = null;
            }
        },
        .companion_character_dropdown => {
            state.settings_controller.companion_character_dropdown_open = !state.settings_controller.companion_character_dropdown_open;
            if (state.settings_controller.companion_character_dropdown_open) {
                state.settings_controller.theme_dropdown_open = false;
                state.settings_controller.theme_hover_index = null;
                state.settings_controller.companion_character_hover_index = companionCharacterIndex(state.settings_controller.draft.companion_character);
            } else {
                state.settings_controller.companion_character_hover_index = null;
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
        .new_chat_provider_dropdown => {
            state.settings_controller.new_chat_provider_dropdown_open = !state.settings_controller.new_chat_provider_dropdown_open;
            state.settings_controller.new_chat_menu_hover_index = if (state.settings_controller.new_chat_provider_dropdown_open) state.settingsNewChatProviderSelectedIndex() else null;
        },
        .new_chat_model_dropdown => {
            state.settings_controller.new_chat_model_dropdown_open = !state.settings_controller.new_chat_model_dropdown_open;
            if (state.settings_controller.new_chat_model_dropdown_open) {
                const selected = state.settingsNewChatModelSelectedIndex() orelse 0;
                state.settings_controller.new_chat_menu_hover_index = selected;
                ensureNewChatModelChoiceVisible(state, selected);
            } else state.settings_controller.new_chat_menu_hover_index = null;
        },
        .new_chat_reasoning_dropdown => {
            state.settings_controller.new_chat_reasoning_dropdown_open = !state.settings_controller.new_chat_reasoning_dropdown_open;
            state.settings_controller.new_chat_menu_hover_index = if (state.settings_controller.new_chat_reasoning_dropdown_open) state.settingsNewChatReasoningSelectedIndex() else null;
        },
        .new_chat_new_pane => state.settings_controller.draft.new_chat_pane_behavior = .new_pane,
        .new_chat_replace_pane => state.settings_controller.draft.new_chat_pane_behavior = .replace_pane,
        .open_folder => state.settings_controller.draft.open_action = .folder,
        .open_editor => state.settings_controller.draft.open_action = .editor,
        .open_cursor => state.settings_controller.draft.open_action = .cursor,
        .open_vscode => state.settings_controller.draft.open_action = .vscode,
        .open_zed => state.settings_controller.draft.open_action = .zed,
        .open_action_dropdown => {
            state.settings_controller.open_action_dropdown_open = !state.settings_controller.open_action_dropdown_open;
            state.settings_controller.open_action_hover_index = if (state.settings_controller.open_action_dropdown_open)
                openActionSelectedIndex(state)
            else
                null;
            state.markDirty();
            return;
        },
        .file_links_neovim_pane => state.settings_controller.draft.file_links_in_neovim_pane = !state.settings_controller.draft.file_links_in_neovim_pane,
        .workspace_unzoom_on_navigation => state.settings_controller.draft.unzoom_on_pane_navigation = !state.settings_controller.draft.unzoom_on_pane_navigation,
        .links_verde_browser => state.settings_controller.draft.link_open_target = .verde_browser,
        .links_system_browser => state.settings_controller.draft.link_open_target = .system_browser,
        .chat_links_global => state.settings_controller.draft.chat_link_open_override = .global,
        .chat_links_verde_browser => state.settings_controller.draft.chat_link_open_override = .verde_browser,
        .chat_links_system_browser => state.settings_controller.draft.chat_link_open_override = .system_browser,
        .terminal_links_global => state.settings_controller.draft.terminal_link_open_override = .global,
        .terminal_links_verde_browser => state.settings_controller.draft.terminal_link_open_override = .verde_browser,
        .terminal_links_system_browser => state.settings_controller.draft.terminal_link_open_override = .system_browser,
        .browser_scroll_speed => {
            state.markDirty();
            return;
        },
        .companion_toggle => {
            state.settings_controller.draft.companion_enabled = !state.settings_controller.draft.companion_enabled;
            if (!state.settings_controller.draft.companion_enabled) {
                state.settings_controller.companion_character_dropdown_open = false;
                state.settings_controller.companion_character_hover_index = null;
            }
        },
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
        .hooks_opencode => {
            state.toggleOpencodeGlobalHooks();
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
        .hooks_pi => {
            state.togglePiGlobalHooks();
            return;
        },
        .updates_check => {
            state.startUpdateCheck();
            return;
        },
        .updates_download => {
            if (state.updateInstallerButtonEnabled()) state.installAvailableUpdate();
            return;
        },
        .updates_automatic => state.settings_controller.draft.check_for_updates_automatically = !state.settings_controller.draft.check_for_updates_automatically,
        // View-only disclosure, not part of the Save/Cancel draft.
        .updates_notes_toggle => {
            state.settings_controller.update_notes_expanded = !state.settings_controller.update_notes_expanded;
            state.markDirty();
            return;
        },
        .updates_release_page => {
            const url = if (state.settings_controller.update.release) |release| release.page_url else updater.State.releasesUrl();
            state.openConfiguredWebLink(url);
            return;
        },
        // Draft toggle: persisted to verde.json on Save, like the other fields.
        .notifications_toggle => state.settings_controller.draft.notifications_enabled = !state.settings_controller.draft.notifications_enabled,
        // Handled by `applyNavigationControl`; they write keybinds, not the draft.
        .navigation_back_record, .navigation_back_reset, .navigation_forward_record, .navigation_forward_reset => return,
        .providers_recheck => {
            state.startProviderReadinessCheck();
            state.markDirty();
            return;
        },
        .providers_update_all => {
            state.updateAllSettingsProviders();
            return;
        },
        .provider_update_first, .provider_update_1, .provider_update_2, .provider_update_3, .provider_update_4, .provider_update_5, .provider_update_6, .provider_update_last => {
            const row = providerUpdateRowForControl(control).?;
            const provider = settings_controller.settingsProviderForRow(row);
            const provider_snapshot = state.providerReadinessSnapshot();
            switch (providerAction(&provider_snapshot, provider)) {
                .install, .update => state.installSettingsProvider(row),
                .sign_in => state.loginSettingsProvider(row),
                .get_node => state.openNodeDownloadPage(),
                .latest, .pending, .none => {},
            }
            return;
        },
        .provider_row_first, .provider_row_1, .provider_row_2, .provider_row_3, .provider_row_4, .provider_row_5, .provider_row_6, .provider_row_last => {
            // Commits on its own; it may also move the new-chat default.
            state.toggleSettingsProviderEnabled(providerRowForControl(control).?);
            return;
        },
    }
    state.commitSettingsPreference();
}

/// Selects a built-in or installed theme, or a Default companion choice when that menu owns the hit channel.
pub fn applyThemeOption(state: *runtime.AppState, choice_index: usize) void {
    if (state.settings_controller.companion_character_dropdown_open) {
        applyCompanionCharacterOption(state, choice_index);
        return;
    }
    state.selectSettingsThemeChoice(choice_index);
}

/// Selects the companion character and applies it immediately.
pub fn applyCompanionCharacterOption(state: *runtime.AppState, choice_index: usize) void {
    if (choice_index >= companionCharacterCount()) return;
    const character = COMPANION_CHARACTER_OPTIONS[choice_index];
    if (character == state.settings_controller.draft.companion_character) {
        state.settings_controller.companion_character_dropdown_open = false;
        state.settings_controller.companion_character_hover_index = null;
        state.markDirty();
        return;
    }
    state.settings_controller.draft.companion_character = character;
    state.settings_controller.companion_character_dropdown_open = false;
    state.settings_controller.companion_character_hover_index = null;
    state.commitSettingsPreference();
}

pub fn applyOpenActionOption(state: *runtime.AppState, option_index: usize) void {
    if (option_index >= OPEN_CHOICES.len) return;
    state.settings_controller.draft.open_action = switch (OPEN_CHOICES[option_index].control) {
        .open_folder => .folder,
        .open_editor => .editor,
        .open_cursor => .cursor,
        .open_vscode => .vscode,
        .open_zed => .zed,
        else => return,
    };
    state.settings_controller.open_action_dropdown_open = false;
    state.settings_controller.open_action_hover_index = null;
    state.commitSettingsPreference();
}

pub fn applyChatTitleProviderOption(state: *runtime.AppState, option_index: usize) void {
    state.selectSettingsChatTitleProvider(option_index);
}

pub fn applyChatTitleModelOption(state: *runtime.AppState, option_index: usize) void {
    state.selectSettingsChatTitleModel(option_index);
}

pub fn applyNewChatProviderOption(state: *runtime.AppState, option_index: usize) void {
    state.selectSettingsNewChatProvider(option_index);
}

pub fn applyNewChatModelOption(state: *runtime.AppState, option_index: usize) void {
    state.selectSettingsNewChatModel(option_index);
}

pub fn applyNewChatReasoningOption(state: *runtime.AppState, option_index: usize) void {
    state.selectSettingsNewChatReasoning(option_index);
}

/// Handles settings keyboard navigation: open dropdown menus first, then
/// Tab focus, arrow navigation, and Enter/Space activation.
pub fn handleKeyDown(state: *runtime.AppState, event: *const palette.event.KeyEvent) bool {
    if (!state.settings_controller.modal_visible) return false;
    if (state.settings_controller.modal_closing or overlayOwnsKeyboard(state)) return false;
    // The shortcut recorder owns every key, modifiers included.
    if (shortcutCaptureActive(state)) return handleShortcutCaptureKey(state, event);
    if (settings_text.handleKey(state, event)) return true;
    if (event.mod.primary() or event.mod.alt) return false;
    const key = event.key;
    if (key == .tab) {
        closeDropdowns(state);
        moveFocus(state, !event.mod.shift);
        return true;
    }
    if (handleDropdownKeyDown(state, key)) return true;
    if (dropdownOpen(state)) {
        // Space confirms like Enter inside an open menu.
        if (key == .space) return handleDropdownKeyDown(state, .@"return");
        return false;
    }
    return handleFocusKeyDown(state, key);
}

fn handleDropdownKeyDown(state: *runtime.AppState, key: palette.event.Keycode) bool {
    if (state.settings_controller.theme_dropdown_open) return handleThemeKeyDown(state, key);
    if (state.settings_controller.companion_character_dropdown_open) return handleCompanionCharacterKeyDown(state, key);
    if (state.settings_controller.title_provider_dropdown_open) return handleTitleProviderKeyDown(state, key);
    if (state.settings_controller.title_model_dropdown_open) return handleTitleModelKeyDown(state, key);
    if (state.settings_controller.new_chat_provider_dropdown_open) return handleNewChatMenuKeyDown(state, key, .provider);
    if (state.settings_controller.new_chat_model_dropdown_open) return handleNewChatMenuKeyDown(state, key, .model);
    if (state.settings_controller.new_chat_reasoning_dropdown_open) return handleNewChatMenuKeyDown(state, key, .reasoning);
    if (state.settings_controller.open_action_dropdown_open) return handleOpenActionKeyDown(state, key);
    if (state.settings_controller.commit_menu) |menu| return handleCommitMenuKeyDown(state, menu, key);
    return false;
}

// Keyboard focus. Tab stops are rebuilt by every `registerHits` pass in
// Tab order (category nav, page controls, Close) with unclipped rects, so
// focus can reach and scroll to controls outside the body viewport.

const FocusStop = struct {
    action: runtime.PaletteModalAction,
    index: usize,
    rect: palette.Rect,
    /// Body viewport for page controls; null for panel chrome (nav, Close).
    clip: ?palette.Rect,
};

const FocusRef = struct { action: runtime.PaletteModalAction, index: usize };

const MAX_FOCUS_STOPS: usize = 192;

var focus_stops: [MAX_FOCUS_STOPS]FocusStop = undefined;
var focus_stop_count: usize = 0;
var focus_body_clip: palette.Rect = .{};
/// Tracked by identity, not list position, so focus survives a page that
/// grows or shrinks between frames.
var keyboard_focus: ?FocusRef = null;
/// The ring shows only after keyboard input; a click moves focus silently.
var focus_ring_visible: bool = false;

fn recordFocusStop(action: runtime.PaletteModalAction, index: usize, rect: palette.Rect, clip: ?palette.Rect) void {
    if (focus_stop_count >= MAX_FOCUS_STOPS) return;
    if (rect.w <= 0.0 or rect.h <= 0.0 or rect.y <= OFFSCREEN_Y * 0.5) return;
    focus_stops[focus_stop_count] = .{ .action = action, .index = index, .rect = rect, .clip = clip };
    focus_stop_count += 1;
}

fn focusedStopIndex() ?usize {
    const focus = keyboard_focus orelse return null;
    for (focus_stops[0..focus_stop_count], 0..) |stop, index| {
        if (stop.action == focus.action and stop.index == focus.index) return index;
    }
    return null;
}

fn activeCategoryIndex(state: *const runtime.AppState) usize {
    for (settings_controller.Category.all, 0..) |category, index| {
        if (category == state.settings_controller.active_category) return index;
    }
    return 0;
}

fn stopIndexFor(action: runtime.PaletteModalAction, index: usize) ?usize {
    for (focus_stops[0..focus_stop_count], 0..) |stop, i| {
        if (stop.action == action and stop.index == index) return i;
    }
    return null;
}

fn firstBodyStop(forward: bool) ?usize {
    var i: usize = 0;
    while (i < focus_stop_count) : (i += 1) {
        const index = if (forward) i else focus_stop_count - 1 - i;
        if (focus_stops[index].clip != null) return index;
    }
    return null;
}

fn setFocus(state: *runtime.AppState, stop_index: usize) void {
    const stop = focus_stops[stop_index];
    keyboard_focus = .{ .action = stop.action, .index = stop.index };
    focus_ring_visible = true;
    if (stop.clip) |clip| {
        // Scroll just enough to reveal the stop plus a small margin.
        const margin = theme.scaledUi(12.0);
        const top = stop.rect.y;
        const bottom = stop.rect.y + stop.rect.h;
        if (top < clip.y) {
            state.settings_controller.scroll_y = @max(0.0, state.settings_controller.scroll_y - (clip.y - top + margin));
        } else if (bottom > clip.y + clip.h) {
            state.settings_controller.scroll_y += bottom - (clip.y + clip.h) + margin;
        }
    }
    state.markDirty();
}

/// Tab / Shift+Tab. The category nav is one stop (the active category);
/// arrows move between categories, like a tab list.
fn moveFocus(state: *runtime.AppState, forward: bool) void {
    const n = focus_stop_count;
    if (n == 0) return;
    const active_nav = activeCategoryIndex(state);
    var i: usize = focusedStopIndex() orelse if (forward) n - 1 else 0;
    var steps: usize = 0;
    while (steps < n) : (steps += 1) {
        i = if (forward) (i + 1) % n else (i + n - 1) % n;
        const stop = focus_stops[i];
        if (stop.action == .settings_category and stop.index != active_nav) continue;
        setFocus(state, i);
        return;
    }
}

fn selectCategoryByKeyboard(state: *runtime.AppState, index: usize) void {
    applySettingsCategory(state, index);
    keyboard_focus = .{ .action = .settings_category, .index = index };
    focus_ring_visible = true;
    state.markDirty();
}

fn stepBrowserScrollSpeed(state: *runtime.AppState, increase: bool) void {
    const draft = &state.settings_controller.draft;
    const step = app_config.BROWSER_SCROLL_SPEED_STEP;
    const raw = draft.browser_scroll_speed + if (increase) step else -step;
    const steps = @round((theme.clampf(raw, app_config.MIN_BROWSER_SCROLL_SPEED, app_config.MAX_BROWSER_SCROLL_SPEED) - app_config.MIN_BROWSER_SCROLL_SPEED) / step);
    draft.browser_scroll_speed = app_config.MIN_BROWSER_SCROLL_SPEED + steps * step;
    state.commitSettingsPreference();
    state.markDirty();
}

/// Runs the same action a click on the stop would.
fn activateStop(state: *runtime.AppState, stop: FocusStop) void {
    switch (stop.action) {
        .settings_close => state.closeSettingsPanel(),
        .settings_category => selectCategoryByKeyboard(state, stop.index),
        .settings_control => applyControl(state, stop.index),
        .settings_runtime_action => applyRuntimeAction(state, stop.index),
        .settings_phone_action => applyPhoneAction(state, stop.index),
        .settings_custom_agent_add => custom_agent_form_state.openAdd(state),
        .settings_custom_agent_edit => custom_agent_form_state.openEdit(state, stop.index),
        .settings_custom_agent_remove => custom_agent_form_state.remove(state, stop.index),
        else => {},
    }
}

fn handleFocusKeyDown(state: *runtime.AppState, key: palette.event.Keycode) bool {
    const current = focusedStopIndex();
    const category_count = settings_controller.Category.all.len;
    switch (key) {
        .@"return", .kp_enter, .space => {
            const index = current orelse return false;
            focus_ring_visible = true;
            activateStop(state, focus_stops[index]);
            state.markDirty();
            return true;
        },
        .up, .down => {
            const forward = key == .down;
            const index = current orelse {
                if (firstBodyStop(forward)) |body| setFocus(state, body);
                return true;
            };
            const stop = focus_stops[index];
            if (stop.action == .settings_category) {
                const next = if (forward) @min(stop.index + 1, category_count - 1) else stop.index -| 1;
                if (next != stop.index) selectCategoryByKeyboard(state, next);
                return true;
            }
            if (stop.clip == null) return true;
            // Walk to the neighboring page control; stop at the page edges.
            var i = index;
            while (if (forward) i + 1 < focus_stop_count else i > 0) {
                i = if (forward) i + 1 else i - 1;
                if (focus_stops[i].clip != null) {
                    setFocus(state, i);
                    break;
                }
            }
            return true;
        },
        .left, .right => {
            const index = current orelse return false;
            const stop = focus_stops[index];
            if (stop.action == .settings_control and stop.index == @intFromEnum(Control.browser_scroll_speed)) {
                stepBrowserScrollSpeed(state, key == .right);
                return true;
            }
            if (stop.action == .settings_category and key == .right) {
                if (firstBodyStop(true)) |body| setFocus(state, body);
                return true;
            }
            if (stop.clip != null and key == .left) {
                if (stopIndexFor(.settings_category, activeCategoryIndex(state))) |nav| setFocus(state, nav);
                return true;
            }
            return false;
        },
        .home, .end => {
            const index = current orelse return false;
            if (focus_stops[index].action != .settings_category) return false;
            selectCategoryByKeyboard(state, if (key == .home) 0 else category_count - 1);
            return true;
        },
        .pageup, .pagedown => {
            const page = @max(focus_body_clip.h * 0.9, 1.0);
            const delta = if (key == .pagedown) page else -page;
            state.settings_controller.scroll_y = @max(0.0, state.settings_controller.scroll_y + delta);
            state.markDirty();
            return true;
        },
        else => return false,
    }
}

/// Moves keyboard focus to a clicked control without showing the ring, so a
/// following Tab continues from where the pointer left off.
pub fn noteClickedHit(action: runtime.PaletteModalAction, index: usize) void {
    focus_ring_visible = false;
    if (stopIndexFor(action, index) != null) keyboard_focus = .{ .action = action, .index = index };
}

/// Keys belong to a sheet or prompt stacked above settings, not to settings.
fn overlayOwnsKeyboard(state: *const runtime.AppState) bool {
    return state.custom_agent_form.open or
        state.folder_browser.open or
        state.runtimeCredentialModalOpen() or
        state.runtimeTrustProposal() != null or
        state.runtime_connections.wizard_open or
        state.command_controller.open or
        state.workspaceSettingsOpen() or
        state.settings_controller.provider_onboarding_visible or
        state.settings_controller.mcp_onboarding_visible or
        state.settings_controller.folder_access_onboarding_visible;
}

fn dropdownOpen(state: *const runtime.AppState) bool {
    const sc = &state.settings_controller;
    return sc.theme_dropdown_open or
        sc.companion_character_dropdown_open or
        sc.title_provider_dropdown_open or
        sc.title_model_dropdown_open or
        sc.new_chat_provider_dropdown_open or
        sc.new_chat_model_dropdown_open or
        sc.new_chat_reasoning_dropdown_open or
        sc.open_action_dropdown_open or
        sc.commit_menu != null;
}

/// Closes every settings dropdown menu without applying a choice.
pub fn closeDropdowns(state: *runtime.AppState) void {
    if (!dropdownOpen(state)) return;
    const sc = &state.settings_controller;
    sc.theme_dropdown_open = false;
    sc.theme_hover_index = null;
    sc.companion_character_dropdown_open = false;
    sc.companion_character_hover_index = null;
    sc.title_provider_dropdown_open = false;
    sc.title_model_dropdown_open = false;
    sc.title_menu_hover_index = null;
    sc.commit_menu = null;
    sc.commit_menu_hover_index = null;
    sc.new_chat_provider_dropdown_open = false;
    sc.new_chat_model_dropdown_open = false;
    sc.new_chat_reasoning_dropdown_open = false;
    sc.new_chat_menu_hover_index = null;
    sc.open_action_dropdown_open = false;
    sc.open_action_hover_index = null;
    state.markDirty();
}

// Focus ring: accent outline offset outside the focused control.
fn drawFocusRing(state: *runtime.AppState) void {
    if (!focus_ring_visible) return;
    const index = focusedStopIndex() orelse return;
    const stop = focus_stops[index];
    const ring_w = @max(1.0, @round(theme.scaledUi(2.0)));
    const gap = ring_w;
    const left = @round(stop.rect.x - gap);
    const top = @round(stop.rect.y - gap);
    const ring: palette.Rect = .{
        .x = left,
        .y = top,
        .w = @round(stop.rect.x + stop.rect.w + gap) - left,
        .h = @round(stop.rect.y + stop.rect.h + gap) - top,
    };
    const color = paletteColor(theme.accent());
    if (stop.clip) |clip| {
        queueBorderClipped(state, ring, color, radiusSm() + gap, ring_w, clip);
    } else {
        queueBorder(state, ring, color, radiusSm() + gap, ring_w);
    }
}

fn handleThemeKeyDown(state: *runtime.AppState, key: palette.event.Keycode) bool {
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

fn handleCompanionCharacterKeyDown(state: *runtime.AppState, key: palette.event.Keycode) bool {
    const count = companionCharacterCount();
    if (count == 0) return false;
    const current = state.settings_controller.companion_character_hover_index orelse companionCharacterIndex(state.settings_controller.draft.companion_character);
    const next = switch (key) {
        .up => current -| 1,
        .down => @min(current + 1, count - 1),
        .home => 0,
        .end => count - 1,
        .escape => {
            state.settings_controller.companion_character_dropdown_open = false;
            state.settings_controller.companion_character_hover_index = null;
            state.markDirty();
            return true;
        },
        .@"return", .kp_enter => {
            applyCompanionCharacterOption(state, current);
            return true;
        },
        else => return false,
    };
    state.settings_controller.companion_character_hover_index = next;
    state.markDirty();
    return true;
}

fn handleTitleProviderKeyDown(state: *runtime.AppState, key: palette.event.Keycode) bool {
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

fn handleTitleModelKeyDown(state: *runtime.AppState, key: palette.event.Keycode) bool {
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

fn handleNewChatMenuKeyDown(state: *runtime.AppState, key: palette.event.Keycode, kind: NewChatMenuKind) bool {
    const count = newChatMenuCount(state, kind);
    if (count == 0) return false;
    const selected = switch (kind) {
        .provider => state.settingsNewChatProviderSelectedIndex(),
        .model => state.settingsNewChatModelSelectedIndex() orelse 0,
        .reasoning => state.settingsNewChatReasoningSelectedIndex(),
    };
    const current = @min(state.settings_controller.new_chat_menu_hover_index orelse selected, count - 1);
    const next = switch (key) {
        .up => current -| 1,
        .down => @min(current + 1, count - 1),
        .home => 0,
        .end => count - 1,
        .escape => {
            state.settings_controller.new_chat_provider_dropdown_open = false;
            state.settings_controller.new_chat_model_dropdown_open = false;
            state.settings_controller.new_chat_reasoning_dropdown_open = false;
            state.settings_controller.new_chat_menu_hover_index = null;
            state.markDirty();
            return true;
        },
        .@"return", .kp_enter => {
            switch (kind) {
                .provider => state.selectSettingsNewChatProvider(current),
                .model => state.selectSettingsNewChatModel(current),
                .reasoning => state.selectSettingsNewChatReasoning(current),
            }
            return true;
        },
        else => return false,
    };
    state.settings_controller.new_chat_menu_hover_index = next;
    if (kind == .model) ensureNewChatModelChoiceVisible(state, next);
    state.markDirty();
    return true;
}

fn ensureNewChatModelChoiceVisible(state: *runtime.AppState, option_index: usize) void {
    if (option_index < state.settings_controller.new_chat_model_menu_scroll) {
        state.settings_controller.new_chat_model_menu_scroll = option_index;
    } else {
        const visible_count = newChatModelMenuVisibleCount(state);
        if (option_index >= state.settings_controller.new_chat_model_menu_scroll + visible_count) {
            state.settings_controller.new_chat_model_menu_scroll = option_index - visible_count + 1;
        }
    }
    state.settings_controller.new_chat_model_menu_scroll = @min(state.settings_controller.new_chat_model_menu_scroll, newChatModelMenuMaxScroll(state));
}

const NOTES_FONT_SIZE = 12.0;
const NOTES_LINK_FONT_SIZE = 12.5;
const RELEASE_PAGE_LABEL = "Open release page";
const PACKAGE_UPDATE_HINT = "Update with your package manager. AUR packages need yay or paru.";
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
    const width = settingsTextWidth(theme.scaledUi(NOTES_FONT_SIZE), line);
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
    _ = width;
    _ = height;
    queueRoundedRect(state, modal, paletteColor(theme.COLOR_PANEL), 0.0);
    queueBorder(state, modal, paletteColor(theme.withAlpha(theme.borderMuted(), 110)), 0.0, theme.scaledUi(1.0));
}

fn drawHeaderBar(state: *runtime.AppState, layout: SettingsLayout) void {
    const m = metrics();
    drawEdgeStrip(state, layout.header, theme.raise(theme.COLOR_PANEL, 0.02), true);
    drawHairline(state, layout.header.x, layout.header.y + layout.header.h - 1.0, layout.header.w);

    queueText(state, .{
        .x = layout.modal.x + m.modal_pad,
        .y = layout.header.y + (m.header_h - theme.scaledUi(22.0)) * 0.5,
        .w = theme.scaledUi(160.0),
        .h = theme.scaledUi(22.0),
    }, "Settings", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), layout.modal);

    drawIconButton(state, layout.close, "×", state.settings_controller.close_hovered);
}

const PROVIDERS_RECHECK_LABEL = "Check again";
/// Matches the onboarding dialog's wording for an installed CLI that lacks Node.js.
const PROVIDER_NEEDS_NODE_BADGE = runtime.provider_setup.NEEDS_NODE_STATUS;
const PROVIDER_GET_NODE_LABEL = "Get Node.js";
const PROVIDERS_UPDATE_HINT = "Update uses the tool that installed that copy, such as mise.";
/// Enable switch plus its margins at a provider row's right edge.
const PROVIDER_SWITCH_RESERVE_UI: f32 = 10.0 + 40.0 + 20.0;

fn providerRowHeight() f32 {
    return theme.scaledUi(46.0);
}

const ProviderAction = enum { install, sign_in, update, latest, pending, get_node, none };

fn providerAction(snapshot: *const runtime.ProviderReadinessSnapshot, provider: runtime.Provider) ProviderAction {
    const readiness = snapshot.forProvider(provider);
    const release = snapshot.releaseForProvider(provider);
    // The CLI is installed but Verde also needs Node.js; reinstalling the CLI
    // would not help, so the action points at Node.js itself.
    if (readiness == .missing and snapshot.requirementForProvider(provider) == .node) return .get_node;
    if (readiness == .missing) return .install;
    // Installed but not authenticated (or auth could not be confirmed): sign-in
    // is the step that unblocks chats, so it takes the slot over Update.
    if (readiness == .signed_out or readiness == .unavailable) return .sign_in;
    return switch (release) {
        .available => .update,
        .current => .latest,
        .unknown => if (readiness == .checking) .pending else .none,
    };
}

fn providerReadinessColor(readiness: runtime.ProviderReadiness) [4]f32 {
    return switch (readiness) {
        .ready => theme.success(),
        .signed_out => theme.warning(),
        .missing, .unavailable => theme.danger(),
        .checking => theme.COLOR_TEXT_SUBTLE,
    };
}

/// Same wording as the "Connect an AI provider" dialog rows (layout.zig
/// `renderProviderReadinessRow`) so both surfaces describe a provider alike.
fn providerReadinessBadge(readiness: runtime.ProviderReadiness) []const u8 {
    return switch (readiness) {
        .checking => "Checking…",
        .missing => "CLI not found",
        .signed_out => "Sign-in needed",
        .ready => "Ready",
        .unavailable => "Could not verify",
    };
}

/// Provider names as the onboarding dialog shows them
/// (layout.zig `providerOnboardingName`).
fn providerDisplayName(provider: runtime.Provider) []const u8 {
    return switch (provider) {
        .codex => "Codex",
        .opencode => "OpenCode",
        .claude => "Claude Code",
        .cursor => "Cursor",
        .pi => "Pi",
        .fx => "FX",
        .grok => "Grok",
        .muse => "Muse",
        .custom_acp => "Custom ACP agents",
    };
}

/// Codex's Verde MCP entry is written with `default_tools_approval_mode =
/// "approve"` (providers/mcp.zig), so say so where the user turns it on.
const MCP_AUTO_APPROVE_NOTE = "In Codex, Verde's tools are set to auto-approve (no prompt per call).";

/// Comma-separated names of the MCP providers in `status`, e.g. the ones whose
/// existing `verde` entry was kept instead of overwritten.
fn mcpProviderNames(buf: []u8, summary: anytype, status: @TypeOf(summary.codex)) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    var count: usize = 0;
    inline for (std.meta.fields(@TypeOf(summary))) |field| {
        if (@field(summary, field.name) == status) {
            if (count > 0) writer.writeAll(", ") catch {};
            writer.writeAll(mcpProviderName(field.name)) catch {};
            count += 1;
        }
    }
    return buf[0..writer.end];
}

fn mcpProviderName(comptime field_name: []const u8) []const u8 {
    const names = .{
        .{ "codex", "Codex" },
        .{ "claude", "Claude Code" },
        .{ "cursor", "Cursor" },
        .{ "opencode", "OpenCode" },
        .{ "amp", "Amp" },
        .{ "pi", "Pi" },
        .{ "fx", "FX" },
        .{ "grok", "Grok" },
    };
    inline for (names) |pair| {
        if (comptime std.mem.eql(u8, pair[0], field_name)) return pair[1];
    }
    return field_name;
}

fn drawProvidersCard(state: *runtime.AppState, layout: SettingsLayout, m: Metrics) void {
    // Providers page: logo, name over a status line (dot, auth status, CLI
    // version), then the installer/sign-in button and the enable switch.
    const clip = layout.body_clip;
    drawCard(state, layout.providers_card, clip);
    drawCardTitle(state, layout.providers_card, "Model providers", clip);
    const snapshot = state.providerReadinessSnapshot();
    const status_font = theme.scaledUi(11.5);
    const name_font = theme.scaledUi(13.0);
    const dot = theme.scaledUi(7.0);
    const inset = theme.scaledUi(10.0);
    const logo = theme.scaledUi(18.0);
    const logo_gap = theme.scaledUi(10.0);
    for (layout.provider_rows, layout.provider_updates, 0..) |row, update, index| {
        const enabled = state.settingsProviderEnabled(index);
        const provider = settings_controller.settingsProviderForRow(index);
        const readiness = snapshot.forProvider(provider);
        const version = snapshot.versionForProvider(provider);
        const action = providerAction(&snapshot, provider);
        const needs_node = readiness == .missing and snapshot.requirementForProvider(provider) == .node;
        drawSwitchRow(state, row, "", enabled, isControlHovered(state, providerRowControl(index)), clip);

        const logo_rect: palette.Rect = .{ .x = row.x + inset, .y = row.y + (row.h - logo) * 0.5, .w = logo, .h = logo };
        const label = providerDisplayName(provider);
        const texture = state.providerLogoTexture(provider);
        if (texture != null and texture.?.valid and texture.?.texture_id != 0) {
            const cached = texture.?;
            const r = utils.snapImageRectToPixels(utils.imageRectContain(cached.width, cached.height, logo_rect.x, logo_rect.y, logo_rect.w, logo_rect.h));
            const alpha: f32 = (if (enabled) @as(f32, 1.0) else 0.45) * current_fade_alpha;
            const tint = theme.providerLogoTint(@tagName(provider));
            state.palette_overlay_batch.image(state.allocator, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, palette.TextureId.init(cached.texture_id), .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 }, .{ .r = tint[0], .g = tint[1], .b = tint[2], .a = tint[3] * alpha }, clip) catch |err| {
                log.warn("failed to queue provider logo: {s}", .{@errorName(err)});
            };
        } else {
            queueCenteredText(state, logo_rect, label[0..1], paletteColor(textLabel()), theme.scaledUi(11.0), clip);
        }

        // Both lines stop short of the action button and ellipsize instead
        // of running underneath it.
        const name_x = logo_rect.x + logo + logo_gap;
        const text_w = @max(update.x - theme.scaledUi(10.0) - name_x, 0.0);
        const name_y = row.y + theme.scaledUi(5.0);
        var name_buf: [64]u8 = undefined;
        queueText(state, .{
            .x = name_x,
            .y = name_y,
            .w = text_w,
            .h = theme.scaledUi(16.0),
        }, ellipsizedText(&name_buf, label, name_font, text_w), paletteColor(if (enabled) theme.COLOR_WHITE else textLabel()), name_font, clip);

        // Status line: the same dot colors and words as the provider dialog
        // (Needs Node.js reads amber, as there), then the CLI version.
        const line_y = name_y + theme.scaledUi(18.0);
        const line_h = theme.scaledUi(14.0);
        const color = if (!enabled) theme.COLOR_TEXT_SUBTLE else if (needs_node) theme.warning() else providerReadinessColor(readiness);
        queueRoundedRectClipped(state, .{ .x = name_x, .y = line_y + (line_h - dot) * 0.5, .w = dot, .h = dot }, paletteColor(color), dot * 0.5, clip);
        const status_x = name_x + dot + theme.scaledUi(6.0);
        const status_room = @max(update.x - theme.scaledUi(10.0) - status_x, 0.0);
        const status = if (needs_node) PROVIDER_NEEDS_NODE_BADGE else providerReadinessBadge(readiness);
        var status_buf: [64]u8 = undefined;
        const status_text = ellipsizedText(&status_buf, status, status_font, status_room);
        queueText(state, .{ .x = status_x, .y = line_y, .w = status_room, .h = line_h }, status_text, paletteColor(if (enabled) textLabel() else textHint()), status_font, clip);
        if (version.len > 0) {
            var version_text_buf: [96]u8 = undefined;
            const version_text = std.fmt.bufPrint(&version_text_buf, " · {s}", .{provider_cli_version.shortVersion(version)}) catch "";
            const version_x = status_x + settingsTextWidth(status_font, status_text);
            const version_room = @max(status_x + status_room - version_x, 0.0);
            var version_buf: [96]u8 = undefined;
            queueText(state, .{ .x = version_x, .y = line_y, .w = version_room, .h = line_h }, ellipsizedText(&version_buf, version_text, status_font, version_room), paletteColor(textHint()), status_font, clip);
        }
        switch (action) {
            .install => drawActionButton(state, update, "Install", .secondary, isControlHovered(state, providerUpdateControl(index)), clip),
            .update => drawActionButton(state, update, "Update", .secondary, isControlHovered(state, providerUpdateControl(index)), clip),
            .sign_in => drawActionButton(state, update, "Sign in", .primary, isControlHovered(state, providerUpdateControl(index)), clip),
            .get_node => drawActionButton(state, update, PROVIDER_GET_NODE_LABEL, .primary, isControlHovered(state, providerUpdateControl(index)), clip),
            .pending => drawActionButton(state, update, "Checking…", .disabled, false, clip),
            .latest => queueCenteredText(state, update, "Latest", paletteColor(textHint()), theme.scaledUi(12.0), clip),
            .none => {},
        }
    }
    queueText(state, .{
        .x = layout.providers_card.x + m.card_pad,
        .y = layout.providers_hint_y,
        .w = layout.providers_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, "Disabled providers are hidden from the model picker and new chats.", paletteColor(textHint()), theme.scaledUi(12.0), clip);
    queueText(state, .{
        .x = layout.providers_card.x + m.card_pad,
        .y = layout.providers_update_hint_y,
        .w = layout.providers_card.w - m.card_pad * 2.0,
        .h = m.label_h,
    }, PROVIDERS_UPDATE_HINT, paletteColor(textHint()), theme.scaledUi(12.0), clip);
    drawActionButton(state, layout.providers_recheck, PROVIDERS_RECHECK_LABEL, .secondary, isControlHovered(state, .providers_recheck), clip);
    var update_all_label_buf: [32]u8 = undefined;
    if (layout.providers_update_all.w > 0.0) if (providersUpdateAllLabel(state, &update_all_label_buf)) |label| {
        drawActionButton(state, layout.providers_update_all, label, .primary, isControlHovered(state, .providers_update_all), clip);
    };
}

/// "Update all (N)" when two or more providers have an update waiting; one
/// outdated provider already has its own Update button on its row.
fn providersUpdateAllLabel(state: *runtime.AppState, buf: []u8) ?[]const u8 {
    const count = state.providerUpdatesAvailableCount();
    if (count < 2) return null;
    return std.fmt.bufPrint(buf, "Update all ({d})", .{count}) catch "Update all";
}

// ---------------------------------------------------------------------------
// Custom ACP agents card
// ---------------------------------------------------------------------------

const MAX_CUSTOM_AGENT_ROWS = app_config.custom_acp_agents.MAX_AGENTS;
const CUSTOM_AGENTS_ADD_LABEL = "Add custom agent";
/// One line; ellipsized on narrow cards rather than running past the edge.
const CUSTOM_AGENTS_EMPTY = "No custom agents yet. Add one with its ACP server command.";
const CUSTOM_AGENTS_SUBTITLE = "Any agent that speaks the Agent Client Protocol over stdio. Each one appears in the model picker under Custom ACP.";

fn customAgentRowHeight() f32 {
    return theme.scaledUi(44.0);
}

fn customAgentsCardHeight(count: usize, card_w: f32, m: Metrics) f32 {
    const rows_h = if (count == 0) m.label_h + m.inner_gap else @as(f32, @floatFromInt(count)) * customAgentRowHeight();
    return m.card_pad * 2.0 + m.title_h + m.inner_gap + customAgentsSubtitleHeight(card_w, m) + m.row_gap + rows_h + m.row_gap + m.row_h;
}

/// The subtitle wraps inside the card instead of running past its edge.
fn customAgentsSubtitleHeight(card_w: f32, m: Metrics) f32 {
    const usable_w = @max(card_w - m.card_pad * 2.0, theme.scaledUi(80.0));
    return @max(wrappedNotesRows(CUSTOM_AGENTS_SUBTITLE, usable_w) * notesLineHeight(), m.label_h);
}

fn drawCustomAgentsCard(state: *runtime.AppState, layout: SettingsLayout, m: Metrics) void {
    const clip = layout.body_clip;
    const card = layout.custom_agents_card;
    drawCard(state, card, clip);
    drawCardTitle(state, card, "Custom ACP agents", clip);
    queueWrappedText(state, .{
        .x = card.x + m.card_pad,
        .y = layout.custom_agents_subtitle_y,
        .w = @max(card.w - m.card_pad * 2.0, theme.scaledUi(80.0)),
        .h = customAgentsSubtitleHeight(card.w, m),
    }, CUSTOM_AGENTS_SUBTITLE, paletteColor(textHint()), theme.scaledUi(NOTES_FONT_SIZE), clip);

    const agents = state.app_config.custom_acp_agents;
    if (layout.custom_agent_count == 0) {
        var empty_buf: [96]u8 = undefined;
        queueText(state, .{
            .x = card.x + m.card_pad,
            .y = layout.custom_agents_empty_y,
            .w = card.w - m.card_pad * 2.0,
            .h = m.label_h,
        }, ellipsizedText(&empty_buf, CUSTOM_AGENTS_EMPTY, theme.scaledUi(12.5), card.w - m.card_pad * 2.0), paletteColor(textLabel()), theme.scaledUi(12.5), clip);
    }
    const mouse_x = state.transcript_controller.palette_mouse_x;
    const mouse_y = state.transcript_controller.palette_mouse_y;
    for (0..layout.custom_agent_count) |index| {
        const agent = agents[index];
        const row = layout.custom_agent_rows[index];
        const text_w = @max(layout.custom_agent_edits[index].x - m.inner_gap - row.x, 0.0);
        var name_buf: [128]u8 = undefined;
        queueText(state, .{ .x = row.x, .y = row.y + theme.scaledUi(5.0), .w = text_w, .h = theme.scaledUi(16.0) }, ellipsizedText(&name_buf, agent.name, theme.scaledUi(13.0), text_w), paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), clip);
        var command_buf: [256]u8 = undefined;
        var command_fit_buf: [256]u8 = undefined;
        queueText(state, .{ .x = row.x, .y = row.y + theme.scaledUi(23.0), .w = text_w, .h = theme.scaledUi(14.0) }, ellipsizedText(&command_fit_buf, commandSummary(&command_buf, agent), theme.scaledUi(11.0), text_w), paletteColor(textHint()), theme.scaledUi(11.0), clip);
        const edit = layout.custom_agent_edits[index];
        const remove = layout.custom_agent_removes[index];
        drawActionButton(state, edit, "Edit", .secondary, pointInRect(mouse_x, mouse_y, edit), clip);
        drawActionButton(state, remove, "Remove", .secondary, pointInRect(mouse_x, mouse_y, remove), clip);
    }
    drawActionButton(state, layout.custom_agents_add, CUSTOM_AGENTS_ADD_LABEL, .primary, pointInRect(mouse_x, mouse_y, layout.custom_agents_add), clip);
}

/// `command arg1 arg2 …` truncated to the buffer; env values are never shown.
fn commandSummary(buf: []u8, agent: app_config.custom_acp_agents.Agent) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll(agent.command) catch return buf[0..writer.end];
    for (agent.args) |arg| {
        writer.writeByte(' ') catch break;
        writer.writeAll(arg) catch break;
    }
    if (agent.env.len > 0) {
        writer.print("  ·  {d} env var{s}", .{ agent.env.len, if (agent.env.len == 1) "" else "s" }) catch {};
    }
    return buf[0..writer.end];
}

fn pointInRect(x: f32, y: f32, rect: palette.Rect) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn drawCategoryNav(state: *runtime.AppState, layout: SettingsLayout) void {
    const active = @intFromEnum(state.settings_controller.active_category);
    for (settings_controller.Category.all, 0..) |category, index| {
        const rect = layout.nav[index];
        const selected = index == active;
        const hovered = state.settings_controller.hover_category == @as(u8, @intCast(index));
        if (selected) {
            queueRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.accent(), 40)), radiusSm());
        } else if (hovered) {
            queueRoundedRect(state, rect, paletteColor(controlHoverSurface()), radiusSm());
        }
        queueText(state, .{
            .x = rect.x + theme.scaledUi(10.0),
            .y = rect.y + (rect.h - theme.scaledUi(16.0)) * 0.5,
            .w = rect.w - theme.scaledUi(14.0),
            .h = theme.scaledUi(16.0),
        }, category.label(), paletteColor(if (selected or hovered) theme.COLOR_WHITE else textLabel()), theme.scaledUi(13.0), layout.modal);
    }
}

// ---------------------------------------------------------------------------
// Runtimes & connections card
// ---------------------------------------------------------------------------

/// Local, every configured profile, account tiles and their machines not
/// linked yet. Rows past the bound are not drawn.
const MAX_RUNTIME_ROWS: usize = 96;
/// Upper bound of `planRuntimeRowButtons` for one profile row: primary
/// recovery, Disconnect, Show server setup, Forget token/device, Edit,
/// Confirm remove + Keep, Copy diagnostics, workspace default. `pushButton`
/// asserts rather than silently dropping a planned action.
const MAX_ROW_BUTTONS: usize = 9;
/// Bounded detail block: repository rows + provider rows + status lines.
const MAX_DETAIL_LINES: usize = 40;
const DETAIL_LINE_BYTES: usize = 240;
const RowAction = runtime_connections.RowAction;

const RUNTIME_SUBTITLE = "Where chats run. New chats in this workspace start on its default runtime.";
const RUNTIME_HINT = "Started chats stay on the runtime they began on. Administrator tokens are kept in memory only.";
const ADD_CONNECTION_LABEL = "Add connection\u{2026}";

const RuntimeRowPlan = struct {
    kind: RuntimeRowKind,
    /// Row encoded into this tile's `settings_runtime_action` indices.
    row: usize,
    entry: RuntimeDisplayRow,
    /// Bordered tile for top-level rows and accounts; the band a machine
    /// occupies inside its account tile.
    tile: palette.Rect,
    /// Title and status block (plus header buttons); toggles expansion for
    /// Local and runtime rows.
    header: palette.Rect,
    /// Right edge of the title/status text, left of any header buttons.
    text_right: f32,
    /// Expand chevron; zero width for rows that do not expand.
    chevron: palette.Rect,
    buttons: [MAX_ROW_BUTTONS]palette.Rect,
    button_actions: [MAX_ROW_BUTTONS]RowAction,
    button_labels: [MAX_ROW_BUTTONS][]const u8,
    button_styles: [MAX_ROW_BUTTONS]ButtonStyle,
    button_count: usize,
    /// Buttons `[0, header_button_count)` sit in the header; the rest form
    /// the expanded row's action bar.
    header_button_count: usize,
    /// Third header line explaining a failing row.
    has_note: bool,
    /// Top of the expanded body, below the divider.
    detail_y: f32,
    expanded: bool,
    bottom: f32,
};

const RuntimeCardPlan = struct {
    rows: [MAX_RUNTIME_ROWS]RuntimeRowPlan,
    row_count: usize,
    /// Card header (title, helper, Add connection, notice) starts here.
    header_y: f32,
    hint_y: f32,
    height: f32,
};

const DetailLine = struct {
    text: []const u8,
    /// `heading` labels a group; `note` is plain guidance under an item.
    tone: enum { normal, muted, warning, good, heading, note },
    /// Install / Sign in button drawn at the right of this status line.
    setup: ?ProviderSetupLine = null,
    /// Technical value (ids, endpoints, setup commands) shown only in the
    /// row's Details disclosure.
    detail: bool = false,
};

/// Remote provider line action: runs the provider setup flow on the runtime.
const ProviderSetupLine = struct {
    /// Index into `runtime_connections.providers`, or `GITHUB_SETUP_ROW`.
    provider_row: usize,
    label: []const u8,
};

/// Marks a `settings_runtime_action` index as a remote provider setup button
/// (`(row << 8) | provider_row`) rather than an encoded `RowAction`.
const PROVIDER_SETUP_ACTION_BIT: usize = 1 << (@bitSizeOf(usize) - 2);
/// `ProviderSetupLine.provider_row` for the GitHub tool line; above any
/// provider row (`MAX_READINESS_ROWS`) and within the action's 8 bits.
const GITHUB_SETUP_ROW: usize = 0xff;

comptime {
    std.debug.assert(runtime_connections.MAX_READINESS_ROWS < GITHUB_SETUP_ROW);
}

const DetailBuffer = struct {
    lines: [MAX_DETAIL_LINES]DetailLine = undefined,
    scratch: [MAX_DETAIL_LINES][DETAIL_LINE_BYTES]u8 = undefined,
    count: usize = 0,

    fn push(self: *DetailBuffer, tone: @FieldType(DetailLine, "tone"), comptime fmt: []const u8, args: anytype) void {
        if (self.count >= MAX_DETAIL_LINES) return;
        const text = std.fmt.bufPrint(&self.scratch[self.count], fmt, args) catch blk: {
            // Truncate rather than drop: the row must still show that a
            // value exists even when it does not fit the line budget.
            break :blk self.scratch[self.count][0..];
        };
        self.lines[self.count] = .{ .text = text, .tone = tone };
        self.count += 1;
    }

    /// A technical line for the Details disclosure.
    fn pushDetail(self: *DetailBuffer, comptime fmt: []const u8, args: anytype) void {
        self.push(.muted, fmt, args);
        if (self.count > 0) self.lines[self.count - 1].detail = true;
    }

    /// Puts an Install / Sign in button on the status line just pushed. The
    /// command it runs is kept for Details instead of crowding the row.
    fn pushSetup(self: *DetailBuffer, setup: ProviderSetupLine, comptime fmt: []const u8, args: anytype) void {
        if (self.count == 0) return;
        self.lines[self.count - 1].setup = setup;
        self.pushDetail(fmt, args);
    }
};

/// One readable status line for a runtime-reported provider. Signed in
/// (reported, probed, or this session) is green whatever else the runtime
/// reports; a runtime that cannot verify accounts (`authentication:
/// "unknown"`) is not a warning; only an explicit sign-out or an unexpected
/// state is.
fn pushRemoteProviderStatus(state: *const runtime.AppState, profile_id: []const u8, row: runtime_connections.ProviderRow, readiness: runtime.ProviderReadiness, out: *DetailBuffer) void {
    const provider = if (row.provider) |value| std.meta.stringToEnum(runtime.Provider, value) else null;
    const setup = &state.settings_controller.provider_setup;
    // Where the daemon cannot report sign-in, the runtime-side status probe
    // decides; the session memory is the fallback.
    const probed = if (provider) |value| runtime.provider_setup.probedAuth(setup, profile_id, value) else .unknown;
    if (remoteProviderSignedIn(state, profile_id, row, readiness)) {
        const how = if (readiness == .ready) "Ready" else if (probed == .signed_in) "Signed in" else "Signed in this session";
        return out.push(.good, "{s} \u{00B7} {s}", .{ row.label, how });
    }
    const known_state = std.mem.eql(u8, row.state, "unknown") or std.mem.eql(u8, row.state, "missing") or
        std.mem.eql(u8, row.state, "ready") or std.mem.eql(u8, row.state, "signed_out");
    if (!known_state) return out.push(.warning, "{s} \u{00B7} {s}", .{ row.label, row.state });
    if (readiness == .unavailable and probed == .signed_out) return out.push(.warning, "{s} \u{00B7} Not signed in", .{row.label});
    switch (readiness) {
        .ready => out.push(.good, "{s} \u{00B7} Ready", .{row.label}),
        .missing => out.push(.normal, "{s} \u{00B7} Not installed", .{row.label}),
        .signed_out => out.push(.warning, "{s} \u{00B7} Not signed in", .{row.label}),
        .unavailable, .checking => out.push(.normal, "{s} \u{00B7} Installed \u{00B7} sign-in can't be checked here", .{row.label}),
    }
}

/// The dialog provider a remote providers.status row maps to, and whether
/// it needs installing; null when Verde has no setup flow for it or it is
/// already ready.
fn remoteProviderSetup(state: *const runtime.AppState, profile_id: []const u8, row: runtime_connections.ProviderRow) ?struct { provider: runtime.Provider, missing: bool } {
    const id = row.provider orelse return null;
    const provider = std.meta.stringToEnum(runtime.Provider, id) orelse return null;
    if (provider == .custom_acp) return null;
    const readiness = runtime.provider_setup.remoteReadiness(null, row.state, row.authentication);
    if (remoteProviderSignedIn(state, profile_id, row, readiness)) return null;
    return .{ .provider = provider, .missing = readiness == .missing };
}

/// Ready as reported, or (where the runtime cannot report sign-in) signed in
/// per the runtime-side probe or a sign-in completed this app session; a
/// probe that says signed out wins over the session memory.
fn remoteProviderSignedIn(state: *const runtime.AppState, profile_id: []const u8, row: runtime_connections.ProviderRow, readiness: runtime.ProviderReadiness) bool {
    if (readiness == .ready) return true;
    if (readiness != .unavailable) return false;
    const id = row.provider orelse return false;
    const provider = std.meta.stringToEnum(runtime.Provider, id) orelse return false;
    const setup = &state.settings_controller.provider_setup;
    return switch (runtime.provider_setup.probedAuth(setup, profile_id, provider)) {
        .signed_in => true,
        .signed_out => false,
        .unknown => runtime.provider_setup.signedInThisSession(setup, profile_id, provider),
    };
}

/// Routes a `settings_runtime_action` click or keyboard activation: remote
/// provider setup buttons open the setup flow on that runtime; everything
/// else is a runtime row action.
pub fn applyRuntimeAction(state: *runtime.AppState, index: usize) void {
    if (index & PROVIDER_SETUP_ACTION_BIT == 0) return state.applyRuntimeRowAction(index);
    const raw = index & ~PROVIDER_SETUP_ACTION_BIT;
    const profile_id = runtimeRowProfileId(state, raw >> 8) orelse return;
    const providers = state.runtime_connections.providers.items;
    const provider_row = raw & 0xff;
    if (provider_row == GITHUB_SETUP_ROW) {
        const status = runtime.provider_setup.githubStatus(&state.settings_controller.provider_setup, profile_id) orelse return;
        switch (status) {
            .missing => runtime.provider_setup.openGithubForRuntime(state, profile_id, true),
            .signed_out => runtime.provider_setup.openGithubForRuntime(state, profile_id, false),
            .signed_in, .unknown => {},
        }
        return;
    }
    if (provider_row >= providers.len) return;
    const setup = remoteProviderSetup(state, profile_id, providers[provider_row]) orelse return;
    runtime.provider_setup.openForRuntime(state, profile_id, setup.provider, setup.missing);
}

fn runtimeRowProfileId(state: *const runtime.AppState, row: usize) ?[]const u8 {
    if (row == 0) return null;
    const index = row - 1;
    if (index >= state.runtime_picker_profiles.items.len) return null;
    return state.runtime_picker_profiles.items[index].profile_id;
}

fn runtimeRowIsWorkspaceDefault(state: *const runtime.AppState, profile_id: ?[]const u8) bool {
    const workspace_id = state.currentWorkspaceIdForRuntimeDefault() orelse return profile_id == null;
    const default_id = state.workspaceRuntimeDefaultProfile(workspace_id);
    if (profile_id) |value| return std.mem.eql(u8, default_id, value);
    return std.mem.eql(u8, default_id, "local");
}

fn buttonWidth(label: []const u8) f32 {
    // Measured label plus a fixed horizontal pad so short verbs keep a
    // comfortable click target and long ones never clip.
    return settingsTextWidth(theme.scaledUi(13.0), label) + theme.scaledUi(28.0);
}

/// Width of text queued through `queueText`. That path leaves the font role
/// unset, so the renderer draws it with its default face (prose bold), which
/// is wider than the `.ui` face; measuring `.ui` let long labels such as
/// "Add custom agent" spill past their buttons.
fn settingsTextWidth(font_size: f32, value: []const u8) f32 {
    return text_measure.textWidth(.prose_bold, font_size, value);
}

/// `value` shortened with a trailing ellipsis to fit `max_w` as drawn by
/// `queueText`; cuts only at UTF-8 boundaries. Returns `value` when it fits.
fn ellipsizedText(buf: []u8, value: []const u8, font_size: f32, max_w: f32) []const u8 {
    if (connTextWidth(font_size, value) <= max_w) return value;
    const ellipsis = "\u{2026}";
    if (buf.len <= ellipsis.len) return "";
    const budget = max_w - connTextWidth(font_size, ellipsis);
    // Binary search the longest fitting prefix; widths grow with length.
    var lo: usize = 0;
    var hi: usize = @min(value.len, buf.len - ellipsis.len);
    while (lo < hi) {
        var mid = lo + (hi - lo + 1) / 2;
        while (mid > lo and mid < value.len and (value[mid] & 0xC0) == 0x80) mid -= 1;
        if (mid == lo) break;
        if (connTextWidth(font_size, value[0..mid]) <= budget) lo = mid else hi = mid - 1;
    }
    const kept = std.mem.trimEnd(u8, value[0..lo], " ");
    @memcpy(buf[0..kept.len], kept);
    @memcpy(buf[kept.len .. kept.len + ellipsis.len], ellipsis);
    return buf[0 .. kept.len + ellipsis.len];
}

fn pushButton(plan: *RuntimeRowPlan, action: RowAction, label: []const u8, style: ButtonStyle) void {
    std.debug.assert(plan.button_count < MAX_ROW_BUTTONS);
    plan.button_actions[plan.button_count] = action;
    plan.button_labels[plan.button_count] = label;
    plan.button_styles[plan.button_count] = style;
    plan.button_count += 1;
}

fn planRuntimeRowButtons(state: *const runtime.AppState, plan: *RuntimeRowPlan, profile_id: ?[]const u8) void {
    plan.button_count = 0;
    const is_default = runtimeRowIsWorkspaceDefault(state, profile_id);
    const id = profile_id orelse {
        pushButton(plan, .set_workspace_default, if (is_default) "Workspace default" else "Use as default", if (is_default) .disabled else .secondary);
        return;
    };
    const snapshot = state.runtimeProfileSnapshot(id);
    const status = state.runtimeProfileStatus(id);
    // Primary action follows the shared recovery mapping so the picker,
    // wizard, and composer banner agree. Re-pair is never offered unless the
    // status is a credential/revocation state.
    const recovery = runtime.runtimeStatusRecovery(status);
    const primary_label = runtime.runtimeRecoveryLabel(recovery, status);
    switch (recovery) {
        .retry => pushButton(plan, if (status == .offline or status == .paired_offline) .connect else .retry, primary_label, .primary),
        .reconnect => pushButton(plan, .reconnect, primary_label, .primary),
        .credential => pushButton(plan, .connect, primary_label, .primary),
        .repair => pushButton(plan, .pair_device, primary_label, .primary),
        .review_trust => pushButton(plan, .review_trust, primary_label, .primary),
        .edit_endpoint => pushButton(plan, .edit, primary_label, .primary),
        .choose_runtime => pushButton(plan, .choose_runtime, primary_label, .primary),
        .server_setup => pushButton(plan, .show_server_setup, primary_label, .primary),
        .none => switch (status) {
            .connecting, .handshaking, .trust_required, .ready, .reconnecting => pushButton(plan, .disable, "Disconnect", .secondary),
            else => {},
        },
    }
    // Readiness failures happen on an authenticated open session. Keep an
    // explicit Disconnect alongside the corrective action and fresh-session
    // retry so users are never trapped in a connected-but-blocked state.
    if (snapshot) |live| {
        if (live.phase == .ready and recovery != .none) pushButton(plan, .disable, "Disconnect", .secondary);
        // Reconnecting rows now surface "Retry now" as the primary; keep the
        // explicit way out of the retry loop.
        if (live.phase == .reconnecting) pushButton(plan, .disable, "Disconnect", .secondary);
    }
    if (recovery != .server_setup and runtime.runtimeStatusOffersServerSetup(status)) {
        pushButton(plan, .show_server_setup, "Show server setup", .secondary);
    }
    if (snapshot) |live| switch (live.access) {
        .admin_token => if (live.credential_held) pushButton(plan, .forget_token, "Forget token", .danger),
        .paired_device => if (live.device_id != null or live.credential_held) {
            pushButton(plan, .forget_device, "Forget device", .danger);
        },
        .connect => {},
    };
    // An account's machines are managed on the account tile; Edit would
    // re-point one machine at another control plane.
    if (state.runtime_connections.accounts.accountForProfile(id) == null) pushButton(plan, .edit, "Edit", .secondary);
    if (state.runtime_connections.isRemoveConfirming(id)) {
        pushButton(plan, .remove_confirm, "Confirm remove", .danger_confirm);
        pushButton(plan, .remove_cancel, "Keep", .secondary);
    } else {
        pushButton(plan, .remove, "Remove", .danger);
    }
    pushButton(plan, .copy_diagnostics, "Copy diagnostics", .secondary);
    pushButton(plan, .set_workspace_default, if (is_default) "Workspace default" else "Use as default", if (is_default) .disabled else .secondary);
}

/// Builds the expanded row's lines. Local reads the workspace folder and the
/// desktop's own provider probe; remote rows read only daemon-reported data.
/// Lines flagged `detail` (ids, endpoints, setup commands) go to the row's
/// Details disclosure; access problems stay in the row.
fn collectRuntimeDetailLines(state: *const runtime.AppState, profile_id: ?[]const u8, out: *DetailBuffer) void {
    out.count = 0;
    const rc = &state.runtime_connections;
    if (profile_id == null) {
        out.push(.heading, "Workspace", .{});
        if (state.project_controller.selected_index < state.project_controller.projects.items.len) {
            const project = state.project_controller.projects.items[state.project_controller.selected_index];
            out.push(.good, "{s}", .{project.path});
        } else {
            out.push(.muted, "No workspace selected", .{});
        }
        out.push(.heading, "Providers", .{});
        const snapshot = state.provider_controller.readiness.snapshot;
        inline for (.{ .codex, .claude, .cursor, .opencode, .pi, .fx, .grok }) |provider| {
            const readiness = snapshot.forProvider(provider);
            // Green only when usable; a missing CLI is neutral, only a
            // needed sign-in is a problem.
            const tone: @FieldType(DetailLine, "tone") = switch (readiness) {
                .ready => .good,
                .signed_out => .warning,
                .checking => .muted,
                .missing, .unavailable => .normal,
            };
            out.push(tone, "{s} \u{00B7} {s}", .{ providerDisplayName(provider), providerReadinessBadge(readiness) });
        }
        return;
    }
    const id = profile_id.?;
    const access_start = out.count;
    pushRuntimeEndpointDetail(state, id, out);
    pushRuntimeAccessDetailLines(state, id, out);
    for (out.lines[access_start..out.count]) |*line| {
        if (line.tone != .warning) line.detail = true;
    }
    const tracking = rc.readiness_profile_id != null and std.mem.eql(u8, rc.readiness_profile_id.?, id);
    const manifest_state = if (tracking) rc.manifest_state else .idle;
    const providers_state = if (tracking) rc.providers_state else .idle;
    out.push(.heading, "Repositories", .{});
    switch (manifest_state) {
        .idle, .loading => out.push(.muted, "Checking\u{2026}", .{}),
        .not_ready => out.push(.muted, "Shown once this runtime is connected and verified", .{}),
        .unsupported => out.push(.warning, "This daemon does not advertise repository manifests", .{}),
        .failed => out.push(.warning, "Could not be read from the daemon", .{}),
        .loaded => {
            if (rc.repositories.items.len == 0) {
                out.push(.warning, "None registered for this workspace on the daemon", .{});
            }
            for (rc.repositories.items) |repo| {
                const default_tag = if (repo.is_default) " (default)" else "";
                if (repo.root_path) |root| {
                    if (std.mem.eql(u8, repo.availability, "available")) {
                        out.push(.good, "{s}{s} \u{00B7} {s}", .{ repo.label, default_tag, root });
                    } else {
                        out.push(.warning, "{s}{s} \u{00B7} {s} \u{00B7} {s}", .{ repo.label, default_tag, repo.availability, root });
                    }
                } else {
                    out.push(.warning, "{s}{s} \u{00B7} Not bound on this runtime", .{ repo.label, default_tag });
                    out.push(.note, "Bind or clone it on the host; the desktop can't clone remotely yet.", .{});
                }
            }
            if (rc.repositories_truncated > 0) out.push(.note, "+{d} more repositories", .{rc.repositories_truncated});
        },
    }
    out.push(.heading, "Providers", .{});
    switch (providers_state) {
        .idle, .loading => out.push(.muted, "Checking\u{2026}", .{}),
        .not_ready => out.push(.muted, "Shown once this runtime is verified", .{}),
        .unsupported => out.push(.warning, "Not reported by this daemon", .{}),
        .failed => out.push(.warning, "The provider list could not be read", .{}),
        .loaded => {
            for (rc.providers.items, 0..) |row, provider_row| {
                const readiness = runtime.provider_setup.remoteReadiness(null, row.state, row.authentication);
                // Signed-in rows (reported, probed, or signed in this
                // session) need no remediation line or Sign in button.
                const ready = remoteProviderSignedIn(state, id, row, readiness);
                pushRemoteProviderStatus(state, id, row, readiness, out);
                if (!ready) {
                    if (remoteProviderSetup(state, id, row)) |setup| {
                        // Runs in a terminal on this runtime, from the provider dialog.
                        out.pushSetup(.{ .provider_row = provider_row, .label = if (setup.missing) "Install" else "Sign in" }, "{s} setup \u{00B7} {s}", .{ row.label, row.remediation_command orelse row.remediation_label orelse "provider dialog" });
                    } else if (row.remediation_command) |command| {
                        out.pushDetail("{s} \u{00B7} {s}: {s}", .{ row.label, row.remediation_label orelse "Setup", command });
                    } else if (row.remediation_label) |label| {
                        out.push(.note, "{s}", .{label});
                    }
                }
            }
            if (rc.providers_truncated > 0) out.push(.note, "+{d} more providers", .{rc.providers_truncated});
        },
    }
    pushRuntimeToolLines(state, id, out);
}

/// Where a standalone runtime is reached; Connect machines list theirs with
/// the access lines.
fn pushRuntimeEndpointDetail(state: *const runtime.AppState, profile_id: []const u8, out: *DetailBuffer) void {
    const service = state.runtime_service orelse return;
    const configured = service.runtime_manager.profileConst(profile_id) orelse return;
    switch (configured.transport) {
        .ssh_tunnel => |ssh| out.pushDetail("SSH \u{00B7} {s}{s}{s}:{d} \u{2192} gateway port {d}", .{
            ssh.user orelse "",
            if (ssh.user != null) "@" else "",
            ssh.host,
            ssh.port,
            ssh.remote_gateway_port,
        }),
        .direct_https => |endpoint| out.pushDetail("Endpoint \u{00B7} {s}", .{endpoint.https_url orelse "(missing endpoint)"}),
        .local_socket, .connect => {},
    }
}

/// Tools on a remote runtime: the GitHub CLI's sign-in, from a status probe
/// Verde runs there itself (the daemon need not know about GitHub). Shown
/// once the runtime can run commands.
fn pushRuntimeToolLines(state: *const runtime.AppState, profile_id: []const u8, out: *DetailBuffer) void {
    const service = state.runtime_service orelse return;
    const live = service.snapshot(profile_id) orelse return;
    if (!live.execution_ready) return;
    out.push(.heading, "Tools", .{});
    const status = runtime.provider_setup.githubStatus(&state.settings_controller.provider_setup, profile_id) orelse {
        return out.push(.muted, "GitHub \u{00B7} Checking\u{2026}", .{});
    };
    switch (status) {
        .signed_in => out.push(.good, "GitHub \u{00B7} Signed in", .{}),
        .signed_out => {
            out.push(.normal, "GitHub \u{00B7} Not signed in", .{});
            out.pushSetup(.{ .provider_row = GITHUB_SETUP_ROW, .label = "Sign in" }, "GitHub sign-in \u{00B7} {s}", .{runtime.provider_setup.remote_github.SIGN_IN_SUMMARY});
        },
        .missing => {
            out.push(.normal, "GitHub \u{00B7} Not installed", .{});
            // gh alone is no use signed out, so one click does both.
            out.pushSetup(.{ .provider_row = GITHUB_SETUP_ROW, .label = "Install & sign in" }, "GitHub setup \u{00B7} {s}", .{runtime.provider_setup.remote_github.INSTALL_AND_SIGN_IN_SUMMARY});
        },
        .unknown => out.push(.muted, "GitHub \u{00B7} Status unavailable; checking again shortly", .{}),
    }
}

/// Method-specific, secret-free access details for Pair and Connect. Never
/// prints a credential, token, or expiry secret.
fn pushRuntimeAccessDetailLines(state: *const runtime.AppState, profile_id: []const u8, out: *DetailBuffer) void {
    const service = state.runtime_service orelse return;
    const snapshot = service.snapshot(profile_id) orelse return;
    const configured = service.runtime_manager.profileConst(profile_id) orelse return;
    switch (configured.access) {
        .admin_token => out.push(.muted, "Access · administrator token, entered each session and kept in memory only", .{}),
        .paired_device => |device| {
            if (device.device_id) |device_id| {
                out.push(.good, "Access · paired device {s}", .{device_id});
            } else {
                out.push(.warning, "Access · not paired yet — redeem a one-time grant from the runtime host", .{});
            }
            const backend = service.credentialBackend();
            if (backend.durable()) {
                out.push(.muted, "Device credential · stored by reference in the OS credential store ({s})", .{@tagName(backend)});
            } else {
                out.push(.warning, "Device credential · memory only on this platform; pair again after relaunch", .{});
            }
            switch (snapshot.pairing_state) {
                .none => {},
                .exchanging => out.push(.muted, "Pairing · exchanging the one-time grant with the runtime", .{}),
                .awaiting_confirmation => out.push(.warning, "Pairing · runtime identity awaits your confirmation in the wizard", .{}),
            }
            if (snapshot.access_token_expires_at_ms) |expires| {
                const now = state.runtimeNowMs();
                const remaining_s: u64 = if (expires > 0 and @as(u64, @intCast(expires)) > now) (@as(u64, @intCast(expires)) - now) / 1000 else 0;
                out.push(.muted, "Access token · renews via /auth/access-token, {d}s left", .{remaining_s});
            }
        },
        .connect => |link| {
            out.push(.muted, "Control plane · {s}", .{link.control_plane_url});
            if (link.link_id) |link_id| out.push(.muted, "Link · {s}", .{link_id});
            switch (configured.transport) {
                .connect => |endpoint| {
                    if (endpoint.https_url) |https| out.push(.muted, "Endpoint · {s}", .{https});
                    if (endpoint.wss_url) |wss| out.push(.muted, "WebSocket · {s}", .{wss});
                    if (endpoint.spki_sha256) |spki| out.push(.muted, "TLS SPKI sha256 · {s}", .{spki});
                },
                else => {},
            }
            if (configured.expected_runtime_id) |runtime_id| out.push(.muted, "Runtime · {s} / {s}", .{ runtime_id, configured.expected_instance_id orelse "?" });
            if (link.device_id) |device_id| out.push(.muted, "Runtime-local device · {s}", .{device_id});
            if (link.credential_ref != null and !snapshot.device_credential_held) {
                out.push(.warning, "Runtime-local credential is not loaded; sign in to Connect and bootstrap again", .{});
            }
        },
    }
}

/// What one tile in the Runtimes & connections card represents.
const RuntimeRowKind = enum { local, profile, account, available };

/// Tile order for the card: Local, standalone runtimes, then each Connect
/// account followed by its linked machines and its machines not linked yet.
const RuntimeDisplayRow = struct {
    kind: RuntimeRowKind,
    /// Row encoded into `settings_runtime_action`: profile rows keep
    /// `picker index + 1`, account rows the account index, available rows
    /// `account * LINK_ROW_STRIDE + machine`.
    row: usize,
    profile_id: ?[]const u8 = null,
    account: usize = 0,
    machine: usize = 0,
    nested: bool = false,
};

fn collectRuntimeDisplayRows(state: *const runtime.AppState, out: []RuntimeDisplayRow) usize {
    const accounts = &state.runtime_connections.accounts;
    const profiles = state.runtime_picker_profiles.items;
    var count: usize = 0;
    out[count] = .{ .kind = .local, .row = 0 };
    count += 1;
    for (profiles, 0..) |configured, index| {
        if (count == out.len) return count;
        if (accounts.accountForProfile(configured.profile_id) != null) continue;
        out[count] = .{ .kind = .profile, .row = index + 1, .profile_id = configured.profile_id };
        count += 1;
    }
    for (accounts.accounts.items, 0..) |account, account_index| {
        if (account.profile_count == 0) continue;
        if (count == out.len) return count;
        out[count] = .{ .kind = .account, .row = account_index, .account = account_index };
        count += 1;
        for (profiles, 0..) |configured, index| {
            if (count == out.len) return count;
            if (accounts.accountForProfile(configured.profile_id) != account_index) continue;
            out[count] = .{ .kind = .profile, .row = index + 1, .profile_id = configured.profile_id, .account = account_index, .nested = true };
            count += 1;
        }
        for (accounts.available.items) |entry| {
            if (entry.account != account_index) continue;
            if (count == out.len) return count;
            out[count] = .{
                .kind = .available,
                .row = account_index * runtime_connections.connect_accounts.LINK_ROW_STRIDE + entry.machine,
                .account = account_index,
                .machine = entry.machine,
                .nested = true,
            };
            count += 1;
        }
    }
    return count;
}

fn planAccountButtons(state: *const runtime.AppState, plan: *RuntimeRowPlan, account_index: usize) void {
    plan.button_count = 0;
    const account = state.runtime_connections.accounts.accountAt(account_index) orelse return;
    if (account.lent) return;
    if (account.session_unavailable or account.phase == .failed) {
        pushButton(plan, .account_sign_in, "Retry", .primary);
        return;
    }
    if (account.canSignIn()) {
        pushButton(plan, .account_sign_in, "Sign in", .primary);
        return;
    }
    if (account.signedIn()) {
        pushButton(plan, .account_refresh, "Refresh", if (account.busy()) .disabled else .secondary);
        pushButton(plan, .account_sign_out, "Sign out", if (account.link != null) .disabled else .secondary);
    }
}

fn planAvailableButtons(state: *const runtime.AppState, plan: *RuntimeRowPlan, account_index: usize, machine_index: usize) void {
    plan.button_count = 0;
    const account = state.runtime_connections.accounts.accountAt(account_index) orelse return;
    const machine = account.machineAt(machine_index) orelse return;
    if (account.linkingRuntime(machine.runtime_id)) {
        pushButton(plan, .link_machine, "Connecting\u{2026}", .disabled);
    } else {
        pushButton(plan, .link_machine, "Connect", if (account.busy() or account.lent) .disabled else .primary);
    }
}

/// A linked machine the signed-in account no longer lists is stopped (or
/// unassigned) rather than merely unreachable.
fn machineStopped(state: *const runtime.AppState, entry: RuntimeDisplayRow, status: runtime.RuntimePickerStatus) bool {
    if (entry.kind != .profile or !entry.nested or status == .ready) return false;
    const account = state.runtime_connections.accounts.accountAt(entry.account) orelse return false;
    if (!account.signedIn() or account.phase != .inventory_loaded) return false;
    const service = state.runtime_service orelse return false;
    const configured = service.runtime_manager.profileConst(entry.profile_id.?) orelse return false;
    const https_url: ?[]const u8 = switch (configured.transport) {
        .connect => |endpoint| endpoint.https_url,
        else => null,
    };
    return runtime_connections.connect_accounts.matchMachine(account.machines.items, configured.expected_runtime_id, https_url) == null;
}

fn planRuntimeCard(state: *runtime.AppState, x: f32, y: f32, w: f32, m: Metrics) RuntimeCardPlan {
    var plan: RuntimeCardPlan = undefined;
    plan.row_count = 0;
    plan.header_y = y + m.card_pad;
    const inner_x = x + m.card_pad;
    const inner_w = @max(w - m.card_pad * 2.0, 1.0);
    var pass: ConnPass = .{ .state = state, .x = inner_x, .y = plan.header_y, .w = inner_w, .clip = ZERO_RECT, .draw = false, .queue_hit = null };
    runtimeCardHeader(&pass);
    var cursor_y = pass.y;
    var display: [MAX_RUNTIME_ROWS]RuntimeDisplayRow = undefined;
    const total_rows = collectRuntimeDisplayRows(state, &display);
    // Plan index of the account tile whose machines are being laid out.
    var open_account: ?usize = null;
    for (display[0..total_rows]) |entry| {
        if (open_account) |account_plan| if (!entry.nested) {
            cursor_y = closeAccountTile(&plan.rows[account_plan], cursor_y, m);
            open_account = null;
        };
        const row_plan = planRuntimeRow(state, entry, inner_x, cursor_y, inner_w);
        plan.rows[plan.row_count] = row_plan;
        // Machines stack flush inside their account tile, split by dividers.
        cursor_y = if (entry.kind == .account or entry.nested) row_plan.bottom else row_plan.bottom + m.inner_gap;
        if (entry.kind == .account) open_account = plan.row_count;
        plan.row_count += 1;
    }
    if (open_account) |account_plan| cursor_y = closeAccountTile(&plan.rows[account_plan], cursor_y, m);
    plan.hint_y = cursor_y + m.row_gap - m.inner_gap;
    pass.y = plan.hint_y;
    pass.text(RUNTIME_HINT, textHint(), theme.scaledUi(12.0), null);
    plan.height = pass.y + m.card_pad - y;
    return plan;
}

/// Extends an account tile around its machine rows; returns the next y.
fn closeAccountTile(account: *RuntimeRowPlan, cursor_y: f32, m: Metrics) f32 {
    const bottom = @max(cursor_y, account.bottom);
    account.tile.h = bottom - account.tile.y;
    return bottom + m.inner_gap;
}

/// Card title, helper and Add connection, then the card's last notice.
fn runtimeCardHeader(pass: *ConnPass) void {
    const m = metrics();
    pass.header("Runtimes & connections", RUNTIME_SUBTITLE, &.{.{
        .label = ADD_CONNECTION_LABEL,
        .action = .settings_runtime_action,
        .index = runtime_connections.encodeRowAction(0, .add_connection),
    }});
    const notice = pass.state.runtime_connections.cardNotice();
    if (notice.len > 0) {
        pass.y += m.inner_gap;
        pass.text(notice, textLabel(), theme.scaledUi(12.0), RUNTIME_NOTICE_BLOCK);
    }
    pass.y += m.row_gap;
}

/// How many of a row's leading buttons sit in its header: every account and
/// available-machine button, else the row's main action (a recovery,
/// Disconnect, or Use as default). Management verbs wait in the expanded row.
fn headerButtonCount(plan: *const RuntimeRowPlan) usize {
    switch (plan.kind) {
        .account, .available => return plan.button_count,
        .local, .profile => {},
    }
    if (plan.button_count == 0) return 0;
    const style = plan.button_styles[0];
    if (style == .primary) return 1;
    return switch (plan.button_actions[0]) {
        .disable => 1,
        .set_workspace_default => if (style == .disabled) 0 else 1,
        else => 0,
    };
}

fn planRuntimeRow(state: *runtime.AppState, entry: RuntimeDisplayRow, tile_x: f32, y: f32, tile_w: f32) RuntimeRowPlan {
    const m = metrics();
    const cm = ConnMetrics.init();
    var plan: RuntimeRowPlan = undefined;
    plan.kind = entry.kind;
    plan.row = entry.row;
    plan.entry = entry;
    plan.expanded = switch (entry.kind) {
        .local, .profile => state.runtime_connections.isExpanded(entry.profile_id),
        .account, .available => false,
    };
    switch (entry.kind) {
        .local, .profile => planRuntimeRowButtons(state, &plan, entry.profile_id),
        .account => planAccountButtons(state, &plan, entry.account),
        .available => planAvailableButtons(state, &plan, entry.account, entry.machine),
    }
    plan.header_button_count = headerButtonCount(&plan);
    var text_buf: [320]u8 = undefined;
    plan.has_note = runtimeRowText(state, entry, &text_buf).note.len > 0;

    const content_x = tile_x + cm.pad_x;
    const content_w = @max(tile_w - cm.pad_x * 2.0, 1.0);
    const text_h = cm.title_h + cm.line_gap + cm.status_h + if (plan.has_note) cm.line_gap + cm.status_h else 0.0;
    const top = y + cm.pad_y;
    var right = content_x + content_w;
    plan.chevron = .{ .x = right, .y = top, .w = 0.0, .h = 0.0 };
    if (entry.kind == .local or entry.kind == .profile) {
        plan.chevron = .{ .x = right - cm.chevron, .y = top + (text_h - cm.chevron) * 0.5, .w = cm.chevron, .h = cm.chevron };
        right = plan.chevron.x - m.inner_gap;
    }
    // Header buttons sit right of the text while it keeps a readable width,
    // else on their own line under it.
    var buttons_w: f32 = 0.0;
    for (0..plan.header_button_count) |index| buttons_w += buttonWidth(plan.button_labels[index]) + if (index > 0) m.inner_gap else 0.0;
    const beside = plan.header_button_count == 0 or right - content_x - buttons_w - m.row_gap >= cm.min_text_w;
    var header_bottom = top + text_h;
    plan.text_right = right;
    if (beside and plan.header_button_count > 0) {
        var bx = right - buttons_w;
        const by = top + (text_h - cm.button_h) * 0.5;
        for (0..plan.header_button_count) |index| {
            const bw = buttonWidth(plan.button_labels[index]);
            plan.buttons[index] = .{ .x = bx, .y = by, .w = bw, .h = cm.button_h };
            bx += bw + m.inner_gap;
        }
        plan.text_right = right - buttons_w - m.row_gap;
        header_bottom = @max(header_bottom, by + cm.button_h);
    } else if (plan.header_button_count > 0) {
        var bx = content_x;
        var by = header_bottom + m.inner_gap;
        for (0..plan.header_button_count) |index| {
            const bw = @min(buttonWidth(plan.button_labels[index]), content_w);
            if (index > 0 and bx + bw > content_x + content_w) {
                bx = content_x;
                by += cm.button_h + m.inner_gap;
            }
            plan.buttons[index] = .{ .x = bx, .y = by, .w = bw, .h = cm.button_h };
            bx += bw + m.inner_gap;
        }
        header_bottom = by + cm.button_h;
    }
    plan.header = .{ .x = tile_x, .y = y, .w = tile_w, .h = header_bottom + cm.pad_y - y };
    plan.detail_y = plan.header.y + plan.header.h + cm.pad_y;
    var bottom = plan.header.y + plan.header.h;
    if (plan.expanded) {
        var pass = rowBodyPass(state, &plan, ZERO_RECT, false, null);
        runtimeRowBody(&pass, &plan);
        bottom = pass.y + cm.pad_y;
    }
    plan.bottom = bottom;
    plan.tile = .{ .x = tile_x, .y = y, .w = tile_w, .h = bottom - y };
    return plan;
}

fn rowBodyPass(state: *runtime.AppState, plan: *const RuntimeRowPlan, clip: palette.Rect, draw: bool, queue_hit: ?QueueHitFn) ConnPass {
    const cm = ConnMetrics.init();
    return .{
        .state = state,
        .x = plan.tile.x + cm.pad_x,
        .y = plan.detail_y,
        .w = @max(plan.tile.w - cm.pad_x * 2.0, 1.0),
        .clip = clip,
        .draw = draw,
        .queue_hit = queue_hit,
    };
}

/// Selectable text block for line `line_index` of runtime row `row`.
fn runtimeTextBlock(row: usize, line_index: usize) u32 {
    return RUNTIME_TEXT_BLOCK_BASE + @as(u32, @intCast(row % MAX_RUNTIME_ROWS)) * 64 + @as(u32, @intCast(line_index % 64));
}

/// Expanded row: readiness (repositories, providers, tools) with their
/// Install / Sign in buttons, the row's management actions (destructive
/// last), then a Details disclosure with ids, endpoints and setup commands
/// as selectable text. One pass measures, registers hits and draws.
fn runtimeRowBody(pass: *ConnPass, plan: *const RuntimeRowPlan) void {
    const m = metrics();
    const cm = ConnMetrics.init();
    const row = plan.row;
    var buffer: DetailBuffer = .{};
    collectRuntimeDetailLines(pass.state, plan.entry.profile_id, &buffer);
    var first = true;
    var detail_count: usize = 0;
    for (buffer.lines[0..buffer.count], 0..) |line, line_index| {
        if (line.detail) {
            detail_count += 1;
            continue;
        }
        switch (line.tone) {
            .heading => {
                if (!first) pass.y += theme.scaledUi(8.0);
                pass.text(line.text, textHint(), theme.scaledUi(11.5), null);
                pass.y += theme.scaledUi(2.0);
            },
            .note => {
                const indent = cm.dot + cm.dot_gap;
                pass.textAt(pass.x + indent, pass.w - indent, line.text, textHint(), cm.status_font, runtimeTextBlock(row, line_index));
                pass.y += theme.scaledUi(4.0);
            },
            else => runtimeBodyItem(pass, line, row, runtimeTextBlock(row, line_index)),
        }
        first = false;
    }

    var specs: [MAX_ROW_BUTTONS]ConnButton = undefined;
    var count: usize = 0;
    for ([_]bool{ false, true }) |destructive| {
        for (plan.header_button_count..plan.button_count) |index| {
            const style = plan.button_styles[index];
            // A disabled "Workspace default" is the header's Default chip.
            if (style == .disabled) continue;
            const action = plan.button_actions[index];
            const is_destructive = style == .danger or style == .danger_confirm or action == .remove_cancel;
            if (is_destructive != destructive) continue;
            specs[count] = .{
                .label = plan.button_labels[index],
                .style = style,
                .action = .settings_runtime_action,
                .index = runtime_connections.encodeRowAction(row, action),
            };
            count += 1;
        }
    }
    if (count > 0) {
        if (!first) pass.y += m.row_gap;
        pass.buttonRow(specs[0..count]);
        first = false;
    }

    if (detail_count == 0) return;
    const open = detailsOpen(detailsKey(.runtime, plan.entry.profile_id orelse "local"));
    if (!first) pass.y += m.inner_gap;
    pass.buttonRow(&.{.{ .label = "Details", .action = .settings_phone_action, .index = RUNTIME_DETAILS_ACTION + row, .disclosure = open }});
    if (!open) return;
    pass.y += theme.scaledUi(4.0);
    const indent = theme.scaledUi(DISCLOSURE_PAD_UI);
    for (buffer.lines[0..buffer.count], 0..) |line, line_index| {
        if (!line.detail) continue;
        pass.textAt(pass.x + indent, pass.w - indent, line.text, textLabel(), cm.status_font, runtimeTextBlock(row, line_index));
        pass.y += theme.scaledUi(3.0);
    }
}

/// One readiness line: tone dot, "Name · status" (the status muted), and its
/// Install / Sign in button at the right edge. Wraps instead of clipping.
fn runtimeBodyItem(pass: *ConnPass, line: DetailLine, row: usize, block: u32) void {
    const m = metrics();
    const cm = ConnMetrics.init();
    const font = cm.status_font;
    const line_h = connLineHeight(font);
    const top = pass.y;
    var room = pass.w;
    var button: ?ConnButton = null;
    if (line.setup) |setup| {
        const spec: ConnButton = .{
            .label = setup.label,
            .action = .settings_runtime_action,
            .index = PROVIDER_SETUP_ACTION_BIT | (row << 8) | setup.provider_row,
        };
        button = spec;
        room -= spec.width() + m.row_gap;
    }
    const item_pad = @max((cm.item_h - line_h) * 0.5, 0.0);
    pass.y += item_pad;
    if (pass.draw) {
        queueRoundedRectClipped(pass.state, .{
            .x = pass.x,
            .y = pass.y + (line_h - cm.dot) * 0.5,
            .w = cm.dot,
            .h = cm.dot,
        }, paletteColor(connToneColor(detailTone(line.tone))), cm.dot * 0.5, pass.clip);
    }
    const text_x = pass.x + cm.dot + cm.dot_gap;
    const text_w = @max(pass.x + room - text_x, 1.0);
    const split = std.mem.indexOf(u8, line.text, " \u{00B7} ");
    if (split != null and connTextWidth(font, line.text) <= text_w) {
        if (pass.draw) {
            const name = line.text[0..split.?];
            const name_w = connTextWidth(font, name);
            const rect: palette.Rect = .{ .x = text_x, .y = pass.y, .w = text_w, .h = line_h };
            settings_text.recordLine(pass.state, block, 0, rect, line.text, font, pass.clip);
            queueText(pass.state, .{ .x = text_x, .y = pass.y, .w = name_w + theme.scaledUi(2.0), .h = line_h }, name, paletteColor(theme.COLOR_WHITE), font, pass.clip);
            queueText(pass.state, .{ .x = text_x + name_w, .y = pass.y, .w = @max(text_w - name_w, 0.0), .h = line_h }, line.text[split.?..], paletteColor(textHint()), font, pass.clip);
        }
        pass.y += line_h;
    } else {
        pass.textAt(text_x, text_w, line.text, if (line.tone == .muted) textHint() else textLabel(), font, block);
    }
    pass.y = @max(pass.y + item_pad, top + cm.item_h);
    if (button) |spec| {
        const bw = spec.width();
        pass.control(.{ .x = pass.x + pass.w - bw, .y = top + (cm.item_h - cm.item_button_h) * 0.5, .w = bw, .h = cm.item_button_h }, spec);
    }
}

fn registerRuntimeCardHits(state: *runtime.AppState, layout: SettingsLayout, queue_hit: QueueHitFn) void {
    const m = metrics();
    const plan = &layout.runtimes;
    const card = layout.runtimes_card;
    // Tab order follows the page: Add connection, then each row's header,
    // its main action, and its expanded controls.
    var header: ConnPass = .{ .state = state, .x = card.x + m.card_pad, .y = plan.header_y, .w = @max(card.w - m.card_pad * 2.0, 1.0), .clip = layout.body_clip, .draw = false, .queue_hit = queue_hit };
    runtimeCardHeader(&header);
    for (plan.rows[0..plan.row_count]) |*row_plan| {
        const row = row_plan.row;
        if (row_plan.kind == .local or row_plan.kind == .profile) {
            const expand = runtime_connections.encodeRowAction(row, .expand);
            recordFocusStop(.settings_runtime_action, expand, row_plan.header, layout.body_clip);
            if (intersectRect(row_plan.header, layout.body_clip)) |visible| queue_hit(state, visible, .settings_runtime_action, expand);
        }
        for (0..row_plan.header_button_count) |index| {
            if (row_plan.button_styles[index] == .disabled) continue;
            const action = runtime_connections.encodeRowAction(row, row_plan.button_actions[index]);
            recordFocusStop(.settings_runtime_action, action, row_plan.buttons[index], layout.body_clip);
            if (intersectRect(row_plan.buttons[index], layout.body_clip)) |visible| queue_hit(state, visible, .settings_runtime_action, action);
        }
        if (!row_plan.expanded) continue;
        var body = rowBodyPass(state, row_plan, layout.body_clip, false, queue_hit);
        runtimeRowBody(&body, row_plan);
    }
}

fn isRuntimeActionHovered(state: *const runtime.AppState, index: usize) bool {
    const hovered = state.settings_controller.hover_runtime_action orelse return false;
    return hovered == index;
}

/// Title, one-line status, and (for failing rows) why, for one row header.
const RuntimeRowText = struct {
    title: []const u8,
    status: []const u8,
    tone: ConnTone,
    /// Why a failing row fails; a third header line, empty otherwise.
    note: []const u8 = "",
};

fn runtimeRowText(state: *const runtime.AppState, entry: RuntimeDisplayRow, buf: []u8) RuntimeRowText {
    const accounts = &state.runtime_connections.accounts;
    switch (entry.kind) {
        .local => return .{ .title = "Local", .status = "This computer", .tone = .good },
        .account => {
            const account = accounts.accountAt(entry.account) orelse return .{ .title = "Account", .status = "", .tone = .neutral };
            const title = account.title();
            if (account.session_unavailable or account.phase == .failed) {
                return .{ .title = title, .status = "Unavailable \u{00B7} retry, or sign in again", .tone = .warning };
            }
            if (account.signedIn()) {
                const count = account.machines.items.len;
                const plural: []const u8 = if (count == 1) "" else "s";
                const status = if (account.identity) |identity|
                    std.fmt.bufPrint(buf, "Signed in as {s} \u{00B7} {d} machine{s}", .{ identity, count, plural })
                else
                    std.fmt.bufPrint(buf, "Signed in \u{00B7} {d} machine{s}", .{ count, plural });
                return .{ .title = title, .status = status catch "Signed in", .tone = .good };
            }
            return switch (account.phase) {
                .idle, .discovering, .loading_inventory => .{ .title = title, .status = "Checking\u{2026}", .tone = .neutral },
                .signing_in => .{ .title = title, .status = "Signing in\u{2026}", .tone = .neutral },
                else => .{ .title = title, .status = "Sign in to use this account's machines", .tone = .warning },
            };
        },
        .available => {
            const account = accounts.accountAt(entry.account) orelse return .{ .title = "Machine", .status = "", .tone = .neutral };
            const machine = account.machineAt(entry.machine) orelse return .{ .title = "Machine", .status = "", .tone = .neutral };
            const linking = account.linkingRuntime(machine.runtime_id);
            return .{
                .title = machine.name(),
                .status = if (linking) "Connecting\u{2026}" else "Available \u{00B7} not connected on this computer",
                .tone = .neutral,
            };
        },
        .profile => {},
    }
    const id = entry.profile_id.?;
    const status = state.runtimeProfileStatus(id);
    const stopped = machineStopped(state, entry, status);
    const tone: ConnTone = if (stopped) .neutral else runtimeTone(status);
    const badge = if (stopped) "Stopped" else runtime.runtimePickerStatusBadge(status);
    const note: []const u8 = if (stopped)
        "Not running in this account right now"
    else if (tone == .warning or tone == .danger)
        runtime.runtimePickerStatusDescription(status)
    else
        "";
    const snapshot = state.runtimeProfileSnapshot(id) orelse return .{ .title = "Unavailable runtime", .status = badge, .tone = tone, .note = note };
    if (entry.nested) return .{ .title = accounts.machineLabel(id) orelse snapshot.label, .status = badge, .tone = tone, .note = note };
    const service = state.runtime_service orelse return .{ .title = snapshot.label, .status = badge, .tone = tone, .note = note };
    const configured = service.runtime_manager.profileConst(id) orelse return .{ .title = snapshot.label, .status = badge, .tone = tone, .note = note };
    const via: []const u8 = switch (configured.transport) {
        .ssh_tunnel => "SSH",
        .local_socket => "Local socket",
        .direct_https => "Direct / Tailnet",
        .connect => "Verde Cloud",
    };
    return .{
        .title = snapshot.label,
        .status = std.fmt.bufPrint(buf, "{s} \u{00B7} {s}", .{ badge, via }) catch badge,
        .tone = tone,
        .note = note,
    };
}

// Runtimes & connections: Local, standalone runtimes, and one tile per
// Verde Cloud account holding its machines as divided sub-rows. Each row is
// a title over a dot-led status line with its main action at the right;
// expanding shows readiness, management actions and Details.
fn drawRuntimeCard(state: *runtime.AppState, layout: SettingsLayout) void {
    const m = metrics();
    const card = layout.runtimes_card;
    const clip = layout.body_clip;
    const plan = &layout.runtimes;
    drawCard(state, card, clip);
    var pass: ConnPass = .{ .state = state, .x = card.x + m.card_pad, .y = plan.header_y, .w = @max(card.w - m.card_pad * 2.0, 1.0), .clip = clip, .draw = true, .queue_hit = null };
    runtimeCardHeader(&pass);
    for (plan.rows[0..plan.row_count]) |*row_plan| drawRuntimeRow(state, row_plan, clip);
    pass.y = plan.hint_y;
    pass.text(RUNTIME_HINT, textHint(), theme.scaledUi(12.0), null);
}

fn drawRuntimeRow(state: *runtime.AppState, row_plan: *const RuntimeRowPlan, clip: palette.Rect) void {
    const m = metrics();
    const cm = ConnMetrics.init();
    const entry = row_plan.entry;
    const row = row_plan.row;
    const tile = row_plan.tile;
    const header = row_plan.header;
    const expandable = entry.kind == .local or entry.kind == .profile;
    const header_hovered = expandable and isRuntimeActionHovered(state, runtime_connections.encodeRowAction(row, .expand));
    const content_x = tile.x + cm.pad_x;
    const content_w = @max(tile.w - cm.pad_x * 2.0, 0.0);
    const wash = paletteColor(theme.withAlpha(theme.COLOR_WHITE, 9));
    if (entry.nested) {
        // A machine inside its account tile: a divider, no tile of its own.
        drawDivider(state, content_x, tile.y, content_w, clip);
        // Inset by the account tile's stroke so the wash keeps its border.
        const stroke = @max(@round(theme.scaledUi(1.0)), 1.0);
        if (header_hovered) queueRoundedRectClipped(state, .{ .x = header.x + stroke, .y = header.y + stroke, .w = @max(header.w - stroke * 2.0, 0.0), .h = @max(header.h - stroke * 2.0, 0.0) }, wash, radiusSm(), clip);
    } else {
        const fill = raisedSurface(if (entry.kind == .account) 0.12 else 0.135);
        const border = theme.withAlpha(theme.COLOR_WHITE, if (row_plan.expanded) 30 else 20);
        queuePanelClipped(state, tile, fill, border, radiusSm(), clip);
        if (header_hovered) queueRoundedRectClipped(state, header, wash, radiusSm(), clip);
    }

    var text_buf: [320]u8 = undefined;
    const text = runtimeRowText(state, entry, &text_buf);
    const top = header.y + cm.pad_y;
    const text_w = @max(row_plan.text_right - content_x, 0.0);
    // Title, with a neutral "Default" chip right after it.
    const is_default = expandable and runtimeRowIsWorkspaceDefault(state, entry.profile_id);
    const chip_label = "Default";
    const chip_w = chipWidth(chip_label);
    const show_chip = is_default and text_w >= chip_w + m.inner_gap + theme.scaledUi(40.0);
    const title_room = if (show_chip) text_w - chip_w - m.inner_gap else text_w;
    var title_buf: [256]u8 = undefined;
    const title = ellipsizedText(&title_buf, text.title, cm.title_font, title_room);
    queueText(state, .{ .x = content_x, .y = top, .w = title_room, .h = cm.title_h }, title, paletteColor(theme.COLOR_WHITE), cm.title_font, clip);
    if (show_chip) drawChip(state, content_x + connTextWidth(cm.title_font, title) + m.inner_gap, top + cm.title_h * 0.5, chip_label, clip);
    const status_y = top + cm.title_h + cm.line_gap;
    drawStatusLine(state, content_x, status_y, text_w, cm.status_h, text.tone, text.status, clip);
    if (row_plan.has_note and text.note.len > 0) {
        const indent = cm.dot + cm.dot_gap;
        queueFittedText(state, .{
            .x = content_x + indent,
            .y = status_y + cm.status_h + cm.line_gap,
            .w = @max(text_w - indent, 0.0),
            .h = cm.status_h,
        }, text.note, paletteColor(textHint()), cm.status_font, clip);
    }
    if (expandable) {
        queueIconText(state, row_plan.chevron, if (row_plan.expanded) NF_COD_CHEVRON_UP else NF_COD_CHEVRON_DOWN, paletteColor(if (header_hovered) theme.COLOR_WHITE else textLabel()), cm.chevron, clip);
    }
    for (0..row_plan.header_button_count) |index| {
        const action_index = runtime_connections.encodeRowAction(row, row_plan.button_actions[index]);
        drawActionButton(state, row_plan.buttons[index], row_plan.button_labels[index], row_plan.button_styles[index], isRuntimeActionHovered(state, action_index), clip);
    }
    if (!row_plan.expanded) return;
    drawDivider(state, content_x, header.y + header.h, content_w, clip);
    var body = rowBodyPass(state, row_plan, clip, true, null);
    runtimeRowBody(&body, row_plan);
}

// ---------------------------------------------------------------------------
// Connections page: shared row primitives
// ---------------------------------------------------------------------------

const QueueHitFn = *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void;
const ZERO_RECT: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };

/// Status tones on the Connections page: green only when something works
/// (connected, signed in, ready), neutral for idle states (available, not
/// installed, checking), amber only for a problem the user can fix, red for
/// failures and revocations.
const ConnTone = enum { good, neutral, warning, danger };

fn connToneColor(tone: ConnTone) [4]f32 {
    return switch (tone) {
        .good => theme.success(),
        .neutral => textHint(),
        .warning => theme.warning(),
        .danger => theme.danger(),
    };
}

fn runtimeTone(status: runtime.RuntimePickerStatus) ConnTone {
    return switch (runtime.runtimeStatusTone(status)) {
        .success => .good,
        .muted => .neutral,
        .warning => .warning,
        .danger => .danger,
    };
}

fn detailTone(tone: @FieldType(DetailLine, "tone")) ConnTone {
    return switch (tone) {
        .good => .good,
        .warning => .warning,
        .normal, .muted, .heading, .note => .neutral,
    };
}

/// Geometry tokens shared by Connections rows (runtimes, machines, paired
/// devices): a title line over a dot-led status line, compact buttons.
const ConnMetrics = struct {
    pad_x: f32,
    pad_y: f32,
    title_font: f32,
    title_h: f32,
    status_font: f32,
    status_h: f32,
    line_gap: f32,
    button_h: f32,
    item_button_h: f32,
    dot: f32,
    dot_gap: f32,
    chevron: f32,
    /// One readiness line, tall enough for its Install / Sign in button.
    item_h: f32,
    /// Narrowest title/status text before a row's buttons wrap under it.
    min_text_w: f32,

    fn init() ConnMetrics {
        return .{
            .pad_x = theme.scaledUi(14.0),
            .pad_y = theme.scaledUi(11.0),
            .title_font = theme.scaledUi(13.5),
            .title_h = theme.scaledUi(18.0),
            .status_font = theme.scaledUi(12.0),
            .status_h = theme.scaledUi(16.0),
            .line_gap = theme.scaledUi(3.0),
            .button_h = theme.scaledUi(28.0),
            .item_button_h = theme.scaledUi(24.0),
            .dot = theme.scaledUi(7.0),
            .dot_gap = theme.scaledUi(7.0),
            .chevron = theme.scaledUi(14.0),
            .item_h = theme.scaledUi(28.0),
            .min_text_w = theme.scaledUi(150.0),
        };
    }
};

fn connLineHeight(font: f32) f32 {
    return @round(font * 1.3);
}

/// Direct-mapped memo of Connections text widths. Rows are measured for
/// layout, hit testing and drawing every frame and their "·" lines take the
/// GPU shaping path, so uncached measurement made the page lag on hover.
const ConnWidthSlot = struct { key: u64 = 0, width: f32 = 0.0 };
var conn_width_cache: [512]ConnWidthSlot = [_]ConnWidthSlot{.{}} ** 512;

/// `settingsTextWidth`, memoized per font size, font generation and text.
fn connTextWidth(font_size: f32, value: []const u8) f32 {
    var hasher = std.hash.Wyhash.init(@as(u32, @bitCast(font_size)));
    const generation = text_measure.fontGeneration();
    hasher.update(std.mem.asBytes(&generation));
    hasher.update(value);
    const key = hasher.final() | 1;
    const slot = &conn_width_cache[@intCast(key % conn_width_cache.len)];
    if (slot.key == key) return slot.width;
    const width = settingsTextWidth(font_size, value);
    slot.* = .{ .key = key, .width = width };
    return width;
}

/// Break at measured UTF-8 boundaries, including inside an unbroken URL.
/// The same slices determine height, hit testing and rendered lines.
const WrappedLines = struct {
    value: []const u8,
    width: f32,
    font: f32,
    offset: usize = 0,

    // Measure once per word and binary-search only inside an overlong word.
    fn next(self: *WrappedLines) ?[]const u8 {
        const value = self.value;
        while (self.offset < value.len and value[self.offset] == ' ') self.offset += 1;
        if (self.offset == value.len) return null;
        const start = self.offset;
        var end = start;
        if (self.fits(start, value.len)) {
            end = value.len;
        } else while (end < value.len) {
            var word_end = end;
            while (word_end < value.len and value[word_end] == ' ') word_end += 1;
            word_end = std.mem.indexOfScalarPos(u8, value, word_end, ' ') orelse value.len;
            if (!self.fits(start, word_end)) break;
            end = word_end;
        }
        if (end == start) {
            const word_end = std.mem.indexOfScalarPos(u8, value, start, ' ') orelse value.len;
            var lo = @min(start + (std.unicode.utf8ByteSequenceLength(value[start]) catch 1), word_end);
            var hi = word_end;
            while (lo < hi) {
                var mid = lo + (hi - lo + 1) / 2;
                while (mid > lo and mid < value.len and value[mid] & 0xC0 == 0x80) mid -= 1;
                if (mid == lo) break;
                if (self.fits(start, mid)) lo = mid else hi = mid - 1;
            }
            end = lo;
        }
        self.offset = end;
        return value[start..end];
    }

    fn fits(self: *const WrappedLines, start: usize, end: usize) bool {
        return connTextWidth(self.font, self.value[start..end]) <= self.width;
    }
};

/// A compact button (or a "Details" disclosure) placed by `ConnPass`.
const ConnButton = struct {
    label: []const u8,
    style: ButtonStyle = .secondary,
    action: runtime.PaletteModalAction,
    index: usize,
    /// False draws the button but registers no hit or Tab stop.
    enabled: bool = true,
    /// Draws a disclosure in this open state instead of a push button.
    disclosure: ?bool = null,

    fn width(self: ConnButton) f32 {
        return if (self.disclosure != null) disclosureWidth(self.label) else buttonWidth(self.label);
    }
};

/// One walk over a Connections section that measures it (`draw` false,
/// no `queue_hit`), registers its hits and Tab stops in visual order, or
/// draws it, so the three can never disagree. `y` advances as it goes.
const ConnPass = struct {
    state: *runtime.AppState,
    x: f32,
    y: f32,
    w: f32,
    clip: palette.Rect,
    draw: bool,
    queue_hit: ?QueueHitFn,

    /// Wrapped text; recorded as selectable content when `block` is given.
    fn text(self: *ConnPass, value: []const u8, color: [4]f32, font: f32, block: ?u32) void {
        self.textAt(self.x, self.w, value, color, font, block);
    }

    fn textAt(self: *ConnPass, x: f32, w: f32, value: []const u8, color: [4]f32, font: f32, block: ?u32) void {
        const line_h = connLineHeight(font);
        var lines: WrappedLines = .{ .value = value, .width = @max(w, 1.0), .font = font };
        var index: usize = 0;
        while (lines.next()) |line| : (index += 1) {
            const rect: palette.Rect = .{ .x = x, .y = self.y, .w = @max(w, 1.0), .h = line_h };
            if (self.draw) {
                if (block) |id| settings_text.recordLine(self.state, id, index, rect, line, font, self.clip);
                queueText(self.state, rect, line, paletteColor(color), font, self.clip);
            }
            self.y += line_h;
        }
    }

    /// Tone dot, then wrapped text indented past it.
    fn status(self: *ConnPass, tone: ConnTone, value: []const u8, color: [4]f32, font: f32, block: ?u32) void {
        const cm = ConnMetrics.init();
        const line_h = connLineHeight(font);
        if (self.draw) {
            queueRoundedRectClipped(self.state, .{ .x = self.x, .y = self.y + (line_h - cm.dot) * 0.5, .w = cm.dot, .h = cm.dot }, paletteColor(connToneColor(tone)), cm.dot * 0.5, self.clip);
        }
        const indent = cm.dot + cm.dot_gap;
        self.textAt(self.x + indent, self.w - indent, value, color, font, block);
    }

    fn control(self: *ConnPass, rect: palette.Rect, spec: ConnButton) void {
        const hover_key = if (spec.action == .settings_phone_action) spec.index | PHONE_HOVER_BIT else spec.index;
        const live = spec.enabled and spec.style != .disabled;
        const hovered = live and self.state.settings_controller.hover_runtime_action == hover_key;
        if (self.draw) {
            if (spec.disclosure) |open| {
                drawDisclosure(self.state, rect, spec.label, open, hovered, self.clip);
            } else {
                drawActionButton(self.state, rect, spec.label, spec.style, hovered, self.clip);
            }
        }
        if (!live) return;
        const queue = self.queue_hit orelse return;
        recordFocusStop(spec.action, spec.index, rect, self.clip);
        if (intersectRect(rect, self.clip)) |visible| queue(self.state, visible, spec.action, spec.index);
    }

    /// Compact buttons left to right from `x`, wrapping at `w`.
    fn buttonRowAt(self: *ConnPass, x: f32, w: f32, specs: []const ConnButton) void {
        if (specs.len == 0) return;
        const m = metrics();
        const cm = ConnMetrics.init();
        var cursor_x = x;
        var row_y = self.y;
        for (specs, 0..) |spec, index| {
            const bw = @min(spec.width(), w);
            if (index > 0 and cursor_x + bw > x + w) {
                cursor_x = x;
                row_y += cm.button_h + m.inner_gap;
            }
            self.control(.{ .x = cursor_x, .y = row_y, .w = bw, .h = cm.button_h }, spec);
            cursor_x += bw + m.inner_gap;
        }
        self.y = row_y + cm.button_h;
    }

    fn buttonRow(self: *ConnPass, specs: []const ConnButton) void {
        self.buttonRowAt(self.x, self.w, specs);
    }

    /// Card or section title with right-aligned compact buttons, then the
    /// helper text. The buttons drop under the helper when the title would
    /// be cramped.
    fn header(self: *ConnPass, title: []const u8, helper: []const u8, specs: []const ConnButton) void {
        const m = metrics();
        const cm = ConnMetrics.init();
        const title_font = theme.scaledUi(15.0);
        var buttons_w: f32 = 0.0;
        for (specs, 0..) |spec, index| buttons_w += spec.width() + if (index > 0) m.inner_gap else 0.0;
        const beside = specs.len > 0 and connTextWidth(title_font, title) + m.row_gap + buttons_w <= self.w;
        const title_w = if (beside) self.w - buttons_w - m.row_gap else self.w;
        if (self.draw) queueFittedText(self.state, .{ .x = self.x, .y = self.y, .w = title_w, .h = m.title_h }, title, paletteColor(theme.COLOR_WHITE), title_font, self.clip);
        const top = self.y;
        self.y += m.title_h;
        if (beside) {
            var bx = self.x + self.w - buttons_w;
            const by = top + (m.title_h - cm.button_h) * 0.5;
            for (specs) |spec| {
                const bw = spec.width();
                self.control(.{ .x = bx, .y = by, .w = bw, .h = cm.button_h }, spec);
                bx += bw + m.inner_gap;
            }
            self.y = @max(self.y, by + cm.button_h);
        }
        if (helper.len > 0) {
            self.y += theme.scaledUi(4.0);
            self.text(helper, textHint(), theme.scaledUi(12.0), null);
        }
        if (specs.len > 0 and !beside) {
            self.y += m.inner_gap;
            self.buttonRow(specs);
        }
    }
};

/// One line of row text shortened with an ellipsis to `rect.w`.
fn queueFittedText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font: f32, clip: palette.Rect) void {
    var buf: [512]u8 = undefined;
    queueText(state, rect, ellipsizedText(&buf, value, font, rect.w), color, font, clip);
}

/// Tone dot centered on one status line, then the fitted status text.
fn drawStatusLine(state: *runtime.AppState, x: f32, y: f32, w: f32, h: f32, tone: ConnTone, value: []const u8, clip: palette.Rect) void {
    const cm = ConnMetrics.init();
    queueRoundedRectClipped(state, .{ .x = x, .y = y + (h - cm.dot) * 0.5, .w = cm.dot, .h = cm.dot }, paletteColor(connToneColor(tone)), cm.dot * 0.5, clip);
    const text_x = x + cm.dot + cm.dot_gap;
    queueFittedText(state, .{ .x = text_x, .y = y, .w = @max(x + w - text_x, 0.0), .h = h }, value, paletteColor(textLabel()), cm.status_font, clip);
}

/// Horizontal padding inside a "Details" disclosure, in UI units.
const DISCLOSURE_PAD_UI: f32 = 8.0;

fn disclosureWidth(label: []const u8) f32 {
    return connTextWidth(theme.scaledUi(12.5), label) + theme.scaledUi(DISCLOSURE_PAD_UI * 2.0 + 5.0 + 12.0);
}

/// Borderless "Details ⌄" toggle; washes on hover like other quiet controls.
fn drawDisclosure(state: *runtime.AppState, rect: palette.Rect, label: []const u8, open: bool, hovered: bool, clip: palette.Rect) void {
    if (hovered) queueRoundedRectClipped(state, rect, paletteColor(controlHoverSurface()), radiusSm(), clip);
    const font = theme.scaledUi(12.5);
    const color = paletteColor(if (hovered or open) theme.COLOR_WHITE else textLabel());
    const text_w = connTextWidth(font, label);
    const text_h = font * 1.25;
    const text_x = rect.x + theme.scaledUi(DISCLOSURE_PAD_UI);
    queueText(state, .{ .x = text_x, .y = rect.y + (rect.h - text_h) * 0.5, .w = text_w + theme.scaledUi(2.0), .h = text_h }, label, color, font, clip);
    const icon = theme.scaledUi(12.0);
    queueIconText(state, .{
        .x = text_x + text_w + theme.scaledUi(5.0),
        .y = rect.y + (rect.h - icon) * 0.5,
        .w = icon,
        .h = icon,
    }, if (open) NF_COD_CHEVRON_UP else NF_COD_CHEVRON_DOWN, color, icon, clip);
}

fn chipWidth(label: []const u8) f32 {
    return connTextWidth(theme.scaledUi(11.0), label) + theme.scaledUi(14.0);
}

/// Small neutral label chip (e.g. "Default") vertically centered on `center_y`.
fn drawChip(state: *runtime.AppState, x: f32, center_y: f32, label: []const u8, clip: palette.Rect) void {
    const h = theme.scaledUi(18.0);
    const rect: palette.Rect = .{ .x = x, .y = center_y - h * 0.5, .w = chipWidth(label), .h = h };
    queueRoundedRectClipped(state, rect, paletteColor(controlSurface()), h * 0.5, clip);
    queueCenteredText(state, rect, label, paletteColor(textLabel()), theme.scaledUi(11.0), clip);
}

/// Hairline divider on whole device pixels.
fn drawDivider(state: *runtime.AppState, x: f32, y: f32, w: f32, clip: palette.Rect) void {
    if (w <= 0.0) return;
    const stroke = @max(@round(theme.scaledUi(1.0)), 1.0);
    const left = @round(x);
    queueRoundedRectClipped(state, .{ .x = left, .y = @round(y), .w = @round(x + w) - left, .h = stroke }, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 16)), 0.0, clip);
}

/// A bordered surface as one snapped panel command (crisp-chrome rules).
fn queuePanelClipped(state: *runtime.AppState, rect: palette.Rect, fill: [4]f32, border: [4]f32, radius: f32, clip: palette.Rect) void {
    if (intersectRect(rect, clip) == null) return;
    const stroke = @max(@round(theme.scaledUi(1.0)), 1.0);
    const left = @round(rect.x);
    const top = @round(rect.y);
    const snapped: palette.Rect = .{ .x = left, .y = top, .w = @round(rect.x + rect.w) - left, .h = @round(rect.y + rect.h) - top };
    state.palette_overlay_batch.panelClipped(state.allocator, snapped, paletteColor(fill), paletteColor(border), radius, stroke, clip) catch |err| {
        log.warn("failed to queue settings panel: {s}", .{@errorName(err)});
    };
}

/// "Details" disclosures open on the Connections page, keyed by a hash of
/// the runtime profile or paired device id so they follow the item.
var open_details: [16]u64 = @splat(0);

const DetailsKind = enum(u8) { runtime, device };

fn detailsKey(kind: DetailsKind, id: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(@intFromEnum(kind));
    hasher.update(id);
    return hasher.final() | 1;
}

fn detailsOpen(key: u64) bool {
    return std.mem.indexOfScalar(u64, &open_details, key) != null;
}

fn toggleDetails(key: u64) void {
    if (std.mem.indexOfScalar(u64, &open_details, key)) |index| {
        open_details[index] = 0;
        return;
    }
    const slot = std.mem.indexOfScalar(u64, &open_details, 0) orelse blk: {
        // Full: forget the oldest.
        std.mem.copyForwards(u64, open_details[0 .. open_details.len - 1], open_details[1..]);
        break :blk open_details.len - 1;
    };
    open_details[slot] = key;
}

/// "just now", "5 min ago", "10 h ago", "3 d ago", "2 mo ago", "1 y ago".
fn humanizeAgo(buf: []u8, seconds: i64) []const u8 {
    const s = @max(seconds, 0);
    const minute: i64 = 60;
    const hour: i64 = 60 * minute;
    const day: i64 = 24 * hour;
    if (s < minute) return "just now";
    const result = if (s < hour)
        std.fmt.bufPrint(buf, "{d} min ago", .{@divFloor(s, minute)})
    else if (s < day)
        std.fmt.bufPrint(buf, "{d} h ago", .{@divFloor(s, hour)})
    else if (s < 30 * day)
        std.fmt.bufPrint(buf, "{d} d ago", .{@divFloor(s, day)})
    else if (s < 365 * day)
        std.fmt.bufPrint(buf, "{d} mo ago", .{@divFloor(s, 30 * day)})
    else
        std.fmt.bufPrint(buf, "{d} y ago", .{@divFloor(s, 365 * day)});
    return result catch "a while ago";
}

fn secondsSince(now_ms: i64, then_ms: i64) i64 {
    return @divFloor(@max(now_ms - then_ms, 0), 1000);
}

const PairingPreset = @TypeOf(phone_pairing.PAIRING_PRESETS[0]);

/// A device's permissions in a few words; the full scope list is in Details.
fn deviceAccessSummary(buf: []u8, preset: ?PairingPreset, scope_count: usize) []const u8 {
    if (preset) |value| return switch (value) {
        .full => "Full access",
        .chat => "Chat access",
        .monitor => "Monitor (read-only)",
    };
    if (scope_count == 0) return "No permissions";
    return std.fmt.bufPrint(buf, "Custom access \u{00B7} {d} permission{s}", .{ scope_count, if (scope_count == 1) "" else "s" }) catch "Custom access";
}

/// Seen this recently reads as "Active now" with a green dot.
const DEVICE_ACTIVE_WINDOW_MS: i64 = 10 * 60 * 1000;

fn deviceTone(last_used_at_ms: ?i64, revoked_at_ms: ?i64, now_ms: i64) ConnTone {
    if (revoked_at_ms != null) return .danger;
    const last = last_used_at_ms orelse return .neutral;
    return if (now_ms - last <= DEVICE_ACTIVE_WINDOW_MS) .good else .neutral;
}

/// "Full access · Last seen 10 h ago", "Revoked 3 d ago · Chat access", …
fn deviceStatusText(buf: []u8, access: []const u8, last_used_at_ms: ?i64, revoked_at_ms: ?i64, now_ms: i64) []const u8 {
    var ago_buf: [32]u8 = undefined;
    if (revoked_at_ms) |revoked| {
        return std.fmt.bufPrint(buf, "Revoked {s} \u{00B7} {s}", .{ humanizeAgo(&ago_buf, secondsSince(now_ms, revoked)), access }) catch "Revoked";
    }
    const last = last_used_at_ms orelse return std.fmt.bufPrint(buf, "{s} \u{00B7} Not used yet", .{access}) catch access;
    if (now_ms - last <= DEVICE_ACTIVE_WINDOW_MS) return std.fmt.bufPrint(buf, "{s} \u{00B7} Active now", .{access}) catch access;
    return std.fmt.bufPrint(buf, "{s} \u{00B7} Last seen {s}", .{ access, humanizeAgo(&ago_buf, secondsSince(now_ms, last)) }) catch access;
}

test "connections ages read as short human phrases" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("just now", humanizeAgo(&buf, -5));
    try std.testing.expectEqualStrings("just now", humanizeAgo(&buf, 59));
    try std.testing.expectEqualStrings("2 min ago", humanizeAgo(&buf, 150));
    try std.testing.expectEqualStrings("10 h ago", humanizeAgo(&buf, 36461));
    try std.testing.expectEqualStrings("3 d ago", humanizeAgo(&buf, 3 * 86400 + 5));
    try std.testing.expectEqualStrings("1 mo ago", humanizeAgo(&buf, 45 * 86400));
    try std.testing.expectEqualStrings("1 y ago", humanizeAgo(&buf, 400 * 86400));
}

test "paired device rows summarize access and last use" {
    var buf: [96]u8 = undefined;
    var status_buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings("Full access", deviceAccessSummary(&buf, .full, 20));
    try std.testing.expectEqualStrings("Monitor (read-only)", deviceAccessSummary(&buf, .monitor, 7));
    try std.testing.expectEqualStrings("Custom access \u{00B7} 3 permissions", deviceAccessSummary(&buf, null, 3));
    try std.testing.expectEqualStrings("No permissions", deviceAccessSummary(&buf, null, 0));
    const now: i64 = 1_000_000_000;
    try std.testing.expectEqualStrings("Full access \u{00B7} Last seen 10 h ago", deviceStatusText(&status_buf, "Full access", now - 36461 * 1000, null, now));
    try std.testing.expectEqualStrings("Full access \u{00B7} Active now", deviceStatusText(&status_buf, "Full access", now - 30 * 1000, null, now));
    try std.testing.expectEqualStrings("Chat access \u{00B7} Not used yet", deviceStatusText(&status_buf, "Chat access", null, null, now));
    try std.testing.expectEqualStrings("Revoked 2 d ago \u{00B7} Chat access", deviceStatusText(&status_buf, "Chat access", now, now - 2 * 86400 * 1000, now));
    try std.testing.expectEqual(ConnTone.danger, deviceTone(now, now - 1000, now));
    try std.testing.expectEqual(ConnTone.good, deviceTone(now - 1000, null, now));
    try std.testing.expectEqual(ConnTone.neutral, deviceTone(now - 36461 * 1000, null, now));
    try std.testing.expectEqual(ConnTone.neutral, deviceTone(null, null, now));
}

test "connections text fits its width with an ellipsis" {
    var buf: [256]u8 = undefined;
    const font: f32 = 12.0;
    const value = "Permissions \u{00B7} runtime:read, chat:read, chat:write, terminal:read, repository:read";
    const max_w = settingsTextWidth(font, "Permissions \u{00B7} runtime:read");
    const fitted = ellipsizedText(&buf, value, font, max_w);
    try std.testing.expect(std.mem.endsWith(u8, fitted, "\u{2026}"));
    try std.testing.expect(settingsTextWidth(font, fitted) <= max_w);
    try std.testing.expectEqualStrings("Ready", ellipsizedText(&buf, "Ready", font, 1000.0));
}

test "details disclosures toggle by identity and forget the oldest when full" {
    const saved = open_details;
    defer open_details = saved;
    open_details = @splat(0);
    const key = detailsKey(.device, "device-a");
    try std.testing.expect(key != detailsKey(.runtime, "device-a"));
    toggleDetails(key);
    try std.testing.expect(detailsOpen(key));
    toggleDetails(key);
    try std.testing.expect(!detailsOpen(key));
    for (0..open_details.len + 1) |index| {
        var id_buf: [16]u8 = undefined;
        toggleDetails(detailsKey(.runtime, std.fmt.bufPrint(&id_buf, "p{d}", .{index}) catch unreachable));
    }
    try std.testing.expect(!detailsOpen(detailsKey(.runtime, "p0")));
    try std.testing.expect(detailsOpen(detailsKey(.runtime, "p16")));
}

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

// Appearance Default companion selector control.
fn drawCompanionCharacterDropdown(state: *runtime.AppState, layout: SettingsLayout) void {
    const rect = layout.companion_character_dropdown;
    const hovered = isControlHovered(state, .companion_character_dropdown);
    const background = if (state.settings_controller.companion_character_dropdown_open)
        theme.withAlpha(theme.accent(), 34)
    else if (hovered)
        controlHoverSurface()
    else
        controlSurface();
    queueRoundedRectClipped(state, rect, paletteColor(background), radiusSm(), layout.body_clip);
    queueBorderClipped(state, rect, paletteColor(if (state.settings_controller.companion_character_dropdown_open) theme.withAlpha(theme.accent(), 150) else theme.withAlpha(theme.COLOR_WHITE, 24)), radiusSm(), theme.scaledUi(1.0), layout.body_clip);

    const selected = companionCharacterIndex(state.settings_controller.draft.companion_character);
    queueText(state, .{
        .x = rect.x + theme.scaledUi(10.0),
        .y = rect.y + (rect.h - theme.scaledUi(15.0)) * 0.5,
        .w = rect.w - theme.scaledUi(38.0),
        .h = theme.scaledUi(15.0),
    }, companionCharacterLabel(selected), paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), layout.body_clip);
    const chevron_size = theme.scaledUi(14.0);
    queueIconText(state, .{
        .x = rect.x + rect.w - theme.scaledUi(18.0),
        .y = rect.y + (rect.h - chevron_size) * 0.5,
        .w = chevron_size,
        .h = chevron_size,
    }, if (state.settings_controller.companion_character_dropdown_open) NF_COD_CHEVRON_UP else NF_COD_CHEVRON_DOWN, paletteColor(textLabel()), chevron_size, layout.body_clip);
}

// Appearance Default companion selector popup rows.
fn drawCompanionCharacterDropdownMenu(state: *runtime.AppState, layout: SettingsLayout) void {
    if (!state.settings_controller.companion_character_dropdown_open) return;
    const menu = companionCharacterMenuRect(layout);
    queueRoundedRectClipped(state, menu, paletteColor(raisedSurface(0.14)), radiusSm(), layout.body_clip);
    queueBorderClipped(state, menu, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 34)), radiusSm(), theme.scaledUi(1.0), layout.body_clip);

    const selected = companionCharacterIndex(state.settings_controller.draft.companion_character);
    for (0..companionCharacterCount()) |choice_index| {
        const row = companionCharacterOptionRect(layout, choice_index);
        const is_selected = choice_index == selected;
        const hovered = state.settings_controller.companion_character_hover_index == choice_index;
        if (is_selected or hovered) {
            const fill = if (is_selected) theme.withAlpha(theme.accent(), 38) else controlHoverSurface();
            queueRoundedRectClipped(state, row, paletteColor(fill), theme.scaledUi(4.0), layout.body_clip);
        }

        const dot_size = theme.scaledUi(6.0);
        const dot_color = if (is_selected) theme.accent() else theme.withAlpha(theme.COLOR_TEXT_MUTED, 110);
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
        }, companionCharacterLabel(choice_index), paletteColor(if (is_selected or hovered) theme.COLOR_WHITE else textLabel()), theme.scaledUi(13.0), layout.body_clip);
    }
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

// Renders one new-chat default dropdown menu over the Chat settings card.
fn drawNewChatDropdownMenu(state: *runtime.AppState, layout: SettingsLayout, kind: NewChatMenuKind) void {
    const open = switch (kind) {
        .provider => state.settings_controller.new_chat_provider_dropdown_open,
        .model => state.settings_controller.new_chat_model_dropdown_open,
        .reasoning => state.settings_controller.new_chat_reasoning_dropdown_open,
    };
    if (!open) return;
    const count = newChatMenuCount(state, kind);
    const visible_count = if (kind == .model) newChatModelMenuVisibleCount(state) else @min(count, TITLE_MENU_MAX_ROWS);
    const scroll = if (kind == .model) state.settings_controller.new_chat_model_menu_scroll else 0;
    const menu = newChatMenuRect(state, layout, kind);
    queueRoundedRectClipped(state, menu, paletteColor(raisedSurface(0.14)), radiusSm(), layout.body_clip);
    queueBorderClipped(state, menu, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 34)), radiusSm(), theme.scaledUi(1.0), layout.body_clip);

    const selected_index = switch (kind) {
        .provider => state.settingsNewChatProviderSelectedIndex(),
        .model => state.settingsNewChatModelSelectedIndex() orelse std.math.maxInt(usize),
        .reasoning => state.settingsNewChatReasoningSelectedIndex(),
    };
    for (0..visible_count) |visible_index| {
        const option_index = scroll + visible_index;
        const row = dropdownOptionRect(menu, visible_index);
        const selected = option_index == selected_index;
        const hovered = state.settings_controller.new_chat_menu_hover_index == option_index;
        if (selected or hovered) queueRoundedRectClipped(state, row, paletteColor(if (selected) theme.withAlpha(theme.accent(), 38) else controlHoverSurface()), theme.scaledUi(4.0), layout.body_clip);
        const label = switch (kind) {
            .provider => state.settingsNewChatProviderLabel(option_index),
            .model => state.settingsNewChatModelLabel(option_index),
            .reasoning => state.settingsNewChatReasoningLabel(option_index),
        };
        queueText(state, .{
            .x = row.x + theme.scaledUi(10.0),
            .y = row.y + (row.h - theme.scaledUi(15.0)) * 0.5,
            .w = row.w - theme.scaledUi(20.0),
            .h = theme.scaledUi(15.0),
        }, label, paletteColor(if (selected or hovered) theme.COLOR_WHITE else textLabel()), theme.scaledUi(13.0), layout.body_clip);
    }
}

fn drawOpenActionDropdownMenu(state: *runtime.AppState, layout: SettingsLayout) void {
    if (!state.settings_controller.open_action_dropdown_open) return;
    const menu = openActionMenuRect(layout);
    queueRoundedRectClipped(state, menu, paletteColor(raisedSurface(0.14)), radiusSm(), layout.body_clip);
    queueBorderClipped(state, menu, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 34)), radiusSm(), theme.scaledUi(1.0), layout.body_clip);
    const selected_index = openActionSelectedIndex(state);
    for (OPEN_CHOICES, 0..) |choice, option_index| {
        const row = dropdownOptionRect(menu, option_index);
        const selected = option_index == selected_index;
        const hovered = state.settings_controller.open_action_hover_index == option_index;
        if (selected or hovered) {
            queueRoundedRectClipped(state, row, paletteColor(if (selected) theme.withAlpha(theme.accent(), 38) else controlHoverSurface()), theme.scaledUi(4.0), layout.body_clip);
        }
        queueText(state, .{
            .x = row.x + theme.scaledUi(10.0),
            .y = row.y + (row.h - theme.scaledUi(15.0)) * 0.5,
            .w = row.w - theme.scaledUi(20.0),
            .h = theme.scaledUi(15.0),
        }, choice.label, paletteColor(if (selected or hovered) theme.COLOR_WHITE else textLabel()), theme.scaledUi(13.0), layout.body_clip);
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
const ReducedMotionRow = struct {
    part: app_config.ReducedMotion.Part,
    control: Control,
    label: []const u8,
};

/// Sub-switches under "Reduce motion", in display order.
const REDUCED_MOTION_PARTS = [_]ReducedMotionRow{
    .{ .part = .pane_scroll, .control = .reduced_motion_pane_scroll, .label = "Pane scrolling" },
    .{ .part = .pane_layout, .control = .reduced_motion_pane_layout, .label = "Pane resize & focus" },
    .{ .part = .status_pulse, .control = .reduced_motion_status_pulse, .label = "Status pulses" },
    .{ .part = .chat, .control = .reduced_motion_chat, .label = "Chat animations" },
    .{ .part = .chrome, .control = .reduced_motion_chrome, .label = "Sidebar & dialogs" },
    .{ .part = .companion, .control = .reduced_motion_companion, .label = "Companion" },
};

fn reducedMotionPart(motion: app_config.ReducedMotion, part: app_config.ReducedMotion.Part) bool {
    return switch (part) {
        inline else => |tag| @field(motion, @tagName(tag)),
    };
}

fn toggleReducedMotionPart(motion: *app_config.ReducedMotion, part: app_config.ReducedMotion.Part) void {
    switch (part) {
        inline else => |tag| @field(motion, @tagName(tag)) = !@field(motion, @tagName(tag)),
    }
}

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
    drawSwitchTrack(state, .{
        .x = rect.x + rect.w - theme.scaledUi(10.0) - track_w,
        .y = rect.y + (rect.h - track_h) * 0.5,
        .w = track_w,
        .h = track_h,
    }, on, false, clip);
}

/// The switch alone (track and knob); `hovered` brightens an off track.
fn drawSwitchTrack(state: *runtime.AppState, track: palette.Rect, on: bool, hovered: bool, clip: palette.Rect) void {
    const track_h = track.h;
    const track_color = if (on) theme.withAlpha(theme.accent(), 200) else if (hovered) controlHoverSurface() else controlSurface();
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

fn browserScrollSliderHitRect(row: palette.Rect) palette.Rect {
    const label_w = @min(theme.scaledUi(142.0), row.w * 0.38);
    const value_w = @min(theme.scaledUi(58.0), row.w * 0.22);
    return .{
        .x = row.x + label_w,
        .y = row.y,
        .w = @max(row.w - label_w - value_w, 1.0),
        .h = row.h,
    };
}

fn browserScrollSpeedFromPoint(track: palette.Rect, x: f32) f32 {
    const progress = theme.clampf((x - track.x) / @max(track.w, 1.0), 0.0, 1.0);
    const span = app_config.MAX_BROWSER_SCROLL_SPEED - app_config.MIN_BROWSER_SCROLL_SPEED;
    const raw = app_config.MIN_BROWSER_SCROLL_SPEED + progress * span;
    const steps = @round((raw - app_config.MIN_BROWSER_SCROLL_SPEED) / app_config.BROWSER_SCROLL_SPEED_STEP);
    return app_config.MIN_BROWSER_SCROLL_SPEED + steps * app_config.BROWSER_SCROLL_SPEED_STEP;
}

// Browser settings row: wheel-speed slider with its current multiplier.
fn drawBrowserScrollSpeedSlider(state: *runtime.AppState, row: palette.Rect, value: f32, hovered: bool, clip: palette.Rect) void {
    const hit = browserScrollSliderHitRect(row);
    queueText(state, .{
        .x = row.x + theme.scaledUi(10.0),
        .y = row.y + (row.h - theme.scaledUi(16.0)) * 0.5,
        .w = @max(hit.x - row.x - theme.scaledUi(16.0), 1.0),
        .h = theme.scaledUi(16.0),
    }, "Wheel speed", paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), clip);

    const track_h = theme.scaledUi(6.0);
    const track: palette.Rect = .{ .x = hit.x, .y = row.y + (row.h - track_h) * 0.5, .w = hit.w, .h = track_h };
    const progress = (theme.clampf(value, app_config.MIN_BROWSER_SCROLL_SPEED, app_config.MAX_BROWSER_SCROLL_SPEED) - app_config.MIN_BROWSER_SCROLL_SPEED) /
        (app_config.MAX_BROWSER_SCROLL_SPEED - app_config.MIN_BROWSER_SCROLL_SPEED);
    queueRoundedRectClipped(state, track, paletteColor(if (hovered) controlHoverSurface() else controlSurface()), track_h * 0.5, clip);
    queueRoundedRectClipped(state, .{ .x = track.x, .y = track.y, .w = track.w * progress, .h = track.h }, paletteColor(theme.withAlpha(theme.accent(), 210)), track_h * 0.5, clip);

    const knob_size = theme.scaledUi(16.0);
    const knob_x = track.x + track.w * progress - knob_size * 0.5;
    queueRoundedRectClipped(state, .{ .x = knob_x, .y = row.y + (row.h - knob_size) * 0.5, .w = knob_size, .h = knob_size }, paletteColor(theme.COLOR_WHITE), knob_size * 0.5, clip);

    var value_buf: [16]u8 = undefined;
    const value_text = std.fmt.bufPrint(&value_buf, "{d:.2}×", .{value}) catch "?×";
    queueCenteredText(state, .{ .x = hit.x + hit.w + theme.scaledUi(8.0), .y = row.y, .w = theme.scaledUi(50.0), .h = row.h }, value_text, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), clip);
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

/// `danger` is a de-emphasized destructive action (Remove, Revoke, Forget);
/// `danger_confirm` is its armed second step.
const ButtonStyle = enum { primary, secondary, disabled, danger, danger_confirm };

// Push button for immediate actions (update check/install), with a real
// disabled look so inert states don't read as clickable pills.
// Navigation shortcuts card (Workspace page). Back/Forward step through the
// workspace/chat history. Bindings live in `keybinds.navigation` and are
// written straight to verde.json, outside the settings draft.

const NAVIGATION_LABEL_W: f32 = 84.0;
const MAX_NAVIGATION_BINDINGS: usize = 8;

/// Direction whose shortcut button is waiting for a key or mouse button.
var shortcut_capture: ?keybinds.NavigationDirection = null;
var navigation_notice_buf: [128]u8 = undefined;
var navigation_notice_len: usize = 0;
var navigation_notice_warning: bool = false;

const NavigationCardLayout = struct {
    card: palette.Rect,
    back_record: palette.Rect,
    back_reset: palette.Rect,
    forward_record: palette.Rect,
    forward_reset: palette.Rect,
    hint_y: f32,
};

fn navigationCardHeight(m: Metrics) f32 {
    return m.card_pad * 2.0 + m.title_h + m.row_gap +
        m.row_h + m.inner_gap + m.row_h + m.inner_gap +
        m.label_h * 2.0;
}

fn layoutNavigationCard(card: palette.Rect, m: Metrics) NavigationCardLayout {
    const label_w = theme.scaledUi(NAVIGATION_LABEL_W);
    const reset_w = buttonWidth("Reset");
    const x = card.x + m.card_pad + label_w;
    const record_w = @max(card.w - m.card_pad * 2.0 - label_w - m.inner_gap - reset_w, theme.scaledUi(80.0));
    const back_y = card.y + m.card_pad + m.title_h + m.row_gap;
    const forward_y = back_y + m.row_h + m.inner_gap;
    return .{
        .card = card,
        .back_record = .{ .x = x, .y = back_y, .w = record_w, .h = m.row_h },
        .back_reset = .{ .x = x + record_w + m.inner_gap, .y = back_y, .w = reset_w, .h = m.row_h },
        .forward_record = .{ .x = x, .y = forward_y, .w = record_w, .h = m.row_h },
        .forward_reset = .{ .x = x + record_w + m.inner_gap, .y = forward_y, .w = reset_w, .h = m.row_h },
        .hint_y = forward_y + m.row_h + m.inner_gap,
    };
}

fn navigationBindings(state: *const runtime.AppState, direction: keybinds.NavigationDirection) []const keybinds.Keybind {
    const config = state.command_controller.keyboard_config orelse return &.{};
    return config.navigationBindings(direction);
}

fn navigationBindingsAreDefault(state: *const runtime.AppState, direction: keybinds.NavigationDirection) bool {
    const defaults = keybinds.defaultNavigationBindings(direction);
    const current = navigationBindings(state, direction);
    if (current.len != defaults.len) return false;
    for (current, defaults) |a, b| {
        if (a.mouse_button != b.mouse_button or a.key != b.key or a.alt != b.alt or a.ctrl != b.ctrl or
            a.meta != b.meta or a.primary != b.primary or a.shift != b.shift) return false;
    }
    return true;
}

fn formatNavigationBindings(buf: []u8, bindings: []const keybinds.Keybind) []const u8 {
    if (bindings.len == 0) return "None";
    var count: usize = 0;
    for (bindings, 0..) |binding, index| {
        if (index > 0) count += copyText(buf[count..], ", ");
        var one: [48]u8 = undefined;
        count += copyText(buf[count..], keybinds.formatKeybind(&one, binding));
    }
    return buf[0..count];
}

fn copyText(dest: []u8, src: []const u8) usize {
    const count = @min(dest.len, src.len);
    @memcpy(dest[0..count], src[0..count]);
    return count;
}

fn setNavigationNotice(comptime fmt: []const u8, args: anytype, warning: bool) void {
    const text = std.fmt.bufPrint(&navigation_notice_buf, fmt, args) catch navigation_notice_buf[0..0];
    navigation_notice_len = text.len;
    navigation_notice_warning = warning;
}

/// True while a shortcut button waits for input. Leaving the Workspace page
/// or closing Settings cancels the recording.
pub fn shortcutCaptureActive(state: *const runtime.AppState) bool {
    if (shortcut_capture == null) return false;
    if (!state.settings_controller.modal_visible or state.settings_controller.modal_closing or
        state.settings_controller.active_category != .workspace)
    {
        shortcut_capture = null;
        return false;
    }
    return true;
}

fn applyNavigationControl(state: *runtime.AppState, control: Control) bool {
    const direction: keybinds.NavigationDirection = switch (control) {
        .navigation_back_record, .navigation_back_reset => .back,
        .navigation_forward_record, .navigation_forward_reset => .forward,
        else => {
            shortcut_capture = null;
            return false;
        },
    };
    const reset = control == .navigation_back_reset or control == .navigation_forward_reset;
    if (reset) {
        shortcut_capture = null;
        if (saveNavigationBindings(state, direction, null)) setNavigationNotice("{s} reset to the mouse side button.", .{directionLabel(direction)}, false);
    } else if (isCapturing(direction)) {
        shortcut_capture = null;
        navigation_notice_len = 0;
    } else {
        shortcut_capture = direction;
        setNavigationNotice("Press a key chord or mouse button for {s}. Esc cancels, Backspace clears.", .{directionLabel(direction)}, false);
    }
    state.markDirty();
    return true;
}

fn isCapturing(direction: keybinds.NavigationDirection) bool {
    const active = shortcut_capture orelse return false;
    return active == direction;
}

fn directionLabel(direction: keybinds.NavigationDirection) []const u8 {
    return switch (direction) {
        .back => "Back",
        .forward => "Forward",
    };
}

fn handleShortcutCaptureKey(state: *runtime.AppState, event: *const palette.event.KeyEvent) bool {
    const direction = shortcut_capture orelse return false;
    state.markDirty();
    const plain = !event.mod.ctrl and !event.mod.alt and !event.mod.shift and !event.mod.super;
    if (plain and event.key == .escape) {
        shortcut_capture = null;
        navigation_notice_len = 0;
        return true;
    }
    if (plain and (event.key == .backspace or event.key == .delete)) {
        shortcut_capture = null;
        if (saveNavigationBindings(state, direction, &.{})) setNavigationNotice("{s} has no shortcut now. Reset restores the mouse button.", .{directionLabel(direction)}, false);
        return true;
    }
    // Bare modifiers and unspellable keys keep the recorder waiting.
    const binding = keybinds.keybindFromKeyEvent(event) orelse return true;
    if (state.command_controller.keyboard_config) |config| {
        var label_buf: [64]u8 = undefined;
        if (config.conflictLabelForEvent(&label_buf, event)) |owner| {
            var chord_buf: [48]u8 = undefined;
            setNavigationNotice("{s} is already used by {s}. Try another.", .{ keybinds.formatKeybind(&chord_buf, binding), owner }, true);
            return true;
        }
    }
    addNavigationBinding(state, direction, binding);
    return true;
}

/// Records a pointer button (main routes extra buttons here first).
pub fn captureShortcutMouseButton(state: *runtime.AppState, button: u8) void {
    const direction = shortcut_capture orelse return;
    state.markDirty();
    const binding = keybinds.keybindFromMouseButton(button) orelse return;
    const other: keybinds.NavigationDirection = if (direction == .back) .forward else .back;
    for (navigationBindings(state, other)) |existing| {
        if (existing.mouse_button == button) {
            var chord_buf: [48]u8 = undefined;
            setNavigationNotice("{s} is already used by {s}. Try another.", .{ keybinds.formatKeybind(&chord_buf, binding), directionLabel(other) }, true);
            return;
        }
    }
    addNavigationBinding(state, direction, binding);
}

fn addNavigationBinding(state: *runtime.AppState, direction: keybinds.NavigationDirection, binding: keybinds.Keybind) void {
    shortcut_capture = null;
    var next: [MAX_NAVIGATION_BINDINGS]keybinds.Keybind = undefined;
    var count: usize = 0;
    var already_bound = false;
    for (navigationBindings(state, direction)) |existing| {
        if (count == next.len) break;
        if (existing.mouse_button == binding.mouse_button and existing.key == binding.key and existing.alt == binding.alt and
            existing.ctrl == binding.ctrl and existing.meta == binding.meta and existing.shift == binding.shift and !existing.primary)
        {
            already_bound = true;
        }
        next[count] = existing;
        count += 1;
    }
    var chord_buf: [48]u8 = undefined;
    const chord = keybinds.formatKeybind(&chord_buf, binding);
    if (already_bound) {
        setNavigationNotice("{s} already goes {s}.", .{ chord, if (direction == .back) "back" else "forward" }, false);
        return;
    }
    if (count == next.len) count -= 1;
    next[count] = binding;
    count += 1;
    if (saveNavigationBindings(state, direction, next[0..count])) {
        setNavigationNotice("Added {s} to {s}.", .{ chord, directionLabel(direction) }, false);
    }
}

fn saveNavigationBindings(state: *runtime.AppState, direction: keybinds.NavigationDirection, bindings: ?[]const keybinds.Keybind) bool {
    keybinds.saveNavigationBindings(state.allocator, direction, bindings) catch |err| {
        std.log.scoped(.settings_modal).warn("saving navigation keybinds failed: {s}", .{@errorName(err)});
        setNavigationNotice("Could not save the shortcut to verde.json.", .{}, true);
        return false;
    };
    state.keybinds_reload_requested = true;
    return true;
}

fn drawNavigationCard(state: *runtime.AppState, layout: SettingsLayout, m: Metrics) void {
    const card = layout.navigation_card;
    drawCard(state, card, layout.body_clip);
    drawCardTitle(state, card, "Back & forward", layout.body_clip);
    drawNavigationRow(state, layout, m, .back, layout.navigation_back_record, layout.navigation_back_reset, .navigation_back_record, .navigation_back_reset);
    drawNavigationRow(state, layout, m, .forward, layout.navigation_forward_record, layout.navigation_forward_reset, .navigation_forward_record, .navigation_forward_reset);

    const text_w = card.w - m.card_pad * 2.0;
    const font_size = theme.scaledUi(12.5);
    var hint_buf: [160]u8 = undefined;
    const hint = ellipsizedText(&hint_buf, "Steps through workspaces and chats you visited. Click a shortcut to add a key or mouse button.", font_size, text_w);
    queueText(state, .{ .x = card.x + m.card_pad, .y = layout.navigation_hint_y, .w = text_w, .h = m.label_h }, hint, paletteColor(textHint()), font_size, layout.body_clip);
    if (navigation_notice_len > 0) {
        var notice_buf: [160]u8 = undefined;
        const notice = ellipsizedText(&notice_buf, navigation_notice_buf[0..navigation_notice_len], font_size, text_w);
        const color = if (navigation_notice_warning) theme.warning() else textLabel();
        queueText(state, .{ .x = card.x + m.card_pad, .y = layout.navigation_hint_y + m.label_h, .w = text_w, .h = m.label_h }, notice, paletteColor(color), font_size, layout.body_clip);
    }
}

fn drawNavigationRow(
    state: *runtime.AppState,
    layout: SettingsLayout,
    m: Metrics,
    direction: keybinds.NavigationDirection,
    record: palette.Rect,
    reset: palette.Rect,
    record_control: Control,
    reset_control: Control,
) void {
    queueText(state, .{
        .x = layout.navigation_card.x + m.card_pad,
        .y = record.y + (m.row_h - theme.scaledUi(15.0)) * 0.5,
        .w = theme.scaledUi(NAVIGATION_LABEL_W),
        .h = theme.scaledUi(15.0),
    }, directionLabel(direction), paletteColor(textLabel()), theme.scaledUi(13.5), layout.body_clip);

    const capturing = isCapturing(direction);
    var list_buf: [256]u8 = undefined;
    var fit_buf: [256]u8 = undefined;
    const label = if (capturing)
        "Press keys or a mouse button…"
    else
        ellipsizedText(&fit_buf, formatNavigationBindings(&list_buf, navigationBindings(state, direction)), theme.scaledUi(13.0), record.w - theme.scaledUi(20.0));
    drawActionButton(state, record, label, if (capturing) .primary else .secondary, isControlHovered(state, record_control), layout.body_clip);
    const is_default = navigationBindingsAreDefault(state, direction);
    drawActionButton(state, reset, "Reset", if (is_default) .disabled else .secondary, !is_default and isControlHovered(state, reset_control), layout.body_clip);
}

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
        .danger => {
            // Quiet until hovered so destructive verbs never outweigh the
            // row's main action.
            const fill = if (hovered) theme.mix(controlSurface(), theme.danger(), 0.18) else theme.withAlpha(controlSurface(), 0);
            queuePanelClipped(state, rect, fill, theme.withAlpha(theme.danger(), if (hovered) 140 else 70), radiusSm(), clip);
        },
        .danger_confirm => {
            const bg = if (hovered) theme.mix(theme.danger(), theme.foregroundOn(theme.danger()), 0.10) else theme.danger();
            button_fill = bg;
            queueRoundedRectClipped(state, rect, paletteColor(bg), radiusSm(), clip);
        },
    }
    const text_color = if (style == .disabled)
        textHint()
    else if (style == .danger)
        theme.mix(theme.danger(), theme.COLOR_WHITE, 0.25)
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
    // Measure the real advance so button labels sit centered instead of
    // drifting left when a per-character estimate overshoots.
    const estimated_w = settingsTextWidth(font_size, value);
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

const PHONE_PRESET_ACTION: usize = 5;
comptime {
    std.debug.assert(PHONE_PRESET_ACTION + phone_pairing.PAIRING_PRESETS.len <= 16);
}

const PHONE_HOVER_BIT: usize = 1 << (@bitSizeOf(usize) - 1);
/// "Details" disclosure of paired device `i`: `DEVICE_DETAILS_ACTION + i`,
/// above every revoke action (16 + 2 per device).
const DEVICE_DETAILS_ACTION: usize = 1 << 19;
/// Remote access controls share the phone card's action space above every
/// device index.
const REMOTE_SWITCH_ACTION: usize = 1 << 20;
const REMOTE_BLOCKER_ACTION: usize = REMOTE_SWITCH_ACTION + 1;
/// "Details" disclosure of runtime row `r`: `RUNTIME_DETAILS_ACTION + r`. It
/// rides the phone action space because it only changes this page's view.
const RUNTIME_DETAILS_ACTION: usize = 1 << 21;
/// Selectable text blocks in the Connections page (settings_text_selection).
const REMOTE_STATUS_BLOCK: u32 = 1;
const REMOTE_BLOCKER_BLOCK: u32 = 2;
const REMOTE_DETAIL_BLOCK: u32 = 3;
const PHONE_NOTICE_BLOCK: u32 = 4;
const PHONE_HOST_BLOCK: u32 = 5;
const PHONE_LINK_BLOCK: u32 = 6;
const REMOTE_NOTICE_BLOCK: u32 = 7;
const RUNTIME_NOTICE_BLOCK: u32 = 8;
/// `+ row * 64 + line`; see `runtimeTextBlock`.
const RUNTIME_TEXT_BLOCK_BASE: u32 = 0x1000;
/// `+ device * 8 + field`; see `pairedDeviceDetails`.
const DEVICE_DETAILS_BLOCK_BASE: u32 = 0x4000;

comptime {
    std.debug.assert(RUNTIME_TEXT_BLOCK_BASE + MAX_RUNTIME_ROWS * 64 <= DEVICE_DETAILS_BLOCK_BASE);
    std.debug.assert(MAX_DETAIL_LINES <= 64);
}

const REMOTE_ACCESS_HELPER = "Reach this computer's chats from your phone or your other computers over Tailscale. It keeps running after Verde quits.";

test "connections text wraps at words and splits only overlong words" {
    const font = theme.scaledUi(NOTES_FONT_SIZE);
    const value = "Paired via · pairing link https://verdeai.dev/pair?host=https%3A%2F%2Fhost.ts.net";
    const width = connTextWidth(font, "Paired via · pairing");
    var lines: WrappedLines = .{ .value = value, .width = width, .font = font };
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(std.testing.allocator);
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        try std.testing.expect(line.len > 0 and line[0] != ' ' and line[line.len - 1] != ' ');
        try std.testing.expect(connTextWidth(font, line) <= width);
        if (count == 0) try std.testing.expectEqualStrings("Paired via · pairing", line);
        try rebuilt.appendSlice(std.testing.allocator, line);
    }
    try std.testing.expect(count > 3);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    for (value) |byte| if (byte != ' ') try expected.append(std.testing.allocator, byte);
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(std.testing.allocator);
    for (rebuilt.items) |byte| if (byte != ' ') try actual.append(std.testing.allocator, byte);
    try std.testing.expectEqualStrings(expected.items, actual.items);
}

/// Settings → Remote access: a title with its switch, one status line, and
/// exactly one action for the current blocker. Work runs in
/// `state/remote_access.zig`.
fn remoteAccessSection(card: *ConnPass) void {
    const state = card.state;
    const remote = &state.settings_controller.remote_access;
    const m = metrics();
    const cm = ConnMetrics.init();
    const font = cm.status_font;
    const indent = cm.dot + cm.dot_gap;
    const enabled = remote_access.supported and !remote.busy();
    const track_w = theme.scaledUi(40.0);
    const track_h = theme.scaledUi(22.0);
    const track: palette.Rect = .{ .x = card.x + card.w - track_w, .y = card.y + (m.title_h - track_h) * 0.5, .w = track_w, .h = track_h };
    if (card.draw) {
        queueFittedText(state, .{ .x = card.x, .y = card.y, .w = @max(track.x - m.row_gap - card.x, 0.0), .h = m.title_h }, "Remote access", paletteColor(theme.COLOR_WHITE), theme.scaledUi(15.0), card.clip);
        drawSwitchTrack(state, track, remote.switchOn(), enabled and state.settings_controller.hover_runtime_action == (REMOTE_SWITCH_ACTION | PHONE_HOVER_BIT), card.clip);
    }
    if (enabled) if (card.queue_hit) |queue| {
        recordFocusStop(.settings_phone_action, REMOTE_SWITCH_ACTION, track, card.clip);
        if (intersectRect(track, card.clip)) |visible| queue(state, visible, .settings_phone_action, REMOTE_SWITCH_ACTION);
    };
    card.y += m.title_h + theme.scaledUi(4.0);
    card.text(REMOTE_ACCESS_HELPER, textHint(), font, null);
    card.y += m.row_gap;

    var buf: [400]u8 = undefined;
    const reachable = remote.phase == .on and remote.origin() != null;
    const status: []const u8 = if (!remote_access.supported)
        remote_access.blockerSummary(.unsupported_os)
    else switch (remote.phase) {
        .loading => "Checking Remote access\u{2026}",
        .enabling => "Turning on Remote access\u{2026}",
        .disabling => "Turning off Remote access\u{2026}",
        .syncing => "Updating Remote access to match this version of Verde\u{2026}",
        .on => if (remote.origin()) |origin| std.fmt.bufPrint(&buf, "On \u{00B7} reachable at {s}", .{origin}) catch origin else "On",
        .off => "Off \u{00B7} other devices can't reach this computer",
    };
    const tone: ConnTone = if (!remote_access.supported) .warning else if (reachable) .good else .neutral;
    card.status(tone, status, textLabel(), font, REMOTE_STATUS_BLOCK);
    if (remote.notice().len > 0) {
        card.y += theme.scaledUi(2.0);
        card.textAt(card.x + indent, card.w - indent, remote.notice(), textLabel(), font, REMOTE_NOTICE_BLOCK);
    }
    if (remote.blocker == null and reachable) {
        // Pairing by approval finds machines on the ports Add connection probes.
        card.textAt(card.x + indent, card.w - indent, if (remote_access.discoverableNearby(remote.saved.https_port))
            "Your other computers can find this one under Add connection \u{2192} Nearby machines."
        else
            "Add connection \u{2192} Nearby machines can't find this port; pair other computers with a pairing link.", textHint(), font, null);
    }
    const blocker = remote.blocker orelse return;
    card.y += m.inner_gap;
    card.status(.warning, remote_access.blockerSummary(blocker), textLabel(), font, REMOTE_BLOCKER_BLOCK);
    if (remote.message.len > 0) card.textAt(card.x + indent, card.w - indent, remote.message.slice(), textHint(), font, REMOTE_DETAIL_BLOCK);
    var label_buf: [48]u8 = undefined;
    const label: ?[]const u8 = switch (remote_access.blockerAction(blocker)) {
        .none => null,
        .get_tailscale => "Get Tailscale",
        .open_tailscale => "Open Tailscale",
        .use_suggested_port => std.fmt.bufPrint(&label_buf, "Use port {d} instead", .{remote.suggested_port}) catch "Use another port",
        .retry => "Try again",
    };
    const value = label orelse return;
    card.y += m.inner_gap;
    card.buttonRowAt(card.x + indent, card.w - indent, &.{.{
        .label = value,
        .style = if (remote.busy()) .disabled else .primary,
        .action = .settings_phone_action,
        .index = REMOTE_BLOCKER_ACTION,
    }});
}

fn applyRemoteAccessAction(state: *runtime.AppState, action: usize) void {
    const remote = &state.settings_controller.remote_access;
    if (remote.busy()) return;
    const pref_path = state.storage.pref_path;
    if (action == REMOTE_SWITCH_ACTION) {
        if (remote.switchOn()) remote.disable(pref_path) else remote.enable(pref_path, remote.saved.https_port);
        return;
    }
    if (action != REMOTE_BLOCKER_ACTION) return;
    const blocker = remote.blocker orelse return;
    switch (remote_access.blockerAction(blocker)) {
        .none => {},
        .get_tailscale => utils.openUrlInDefaultBrowser(state.allocator, remote_access.TAILSCALE_DOWNLOAD_URL) catch {
            state.setSidebarNotice("Could not open the Tailscale download page.");
        },
        .open_tailscale => {
            // macOS ships a Tailscale app; on Linux the admin console is the
            // closest thing to "open", and the status text names the sign-in.
            const opened = if (@import("builtin").os.tag == .macos)
                utils.openPathWithSystemHandler(state.allocator, "/Applications/Tailscale.app")
            else
                utils.openUrlInDefaultBrowser(state.allocator, remote_access.TAILSCALE_LOGIN_URL);
            opened catch state.setSidebarNotice("Could not open Tailscale.");
        },
        .use_suggested_port, .retry => remote.retry(pref_path),
    }
}

/// Settings → Paired devices: Refresh and Pair a phone in the header, the
/// pairing flow in an inset panel while open, then one compact row per
/// device.
fn pairedDevicesSection(card: *ConnPass) void {
    const state = card.state;
    const phone = &state.settings_controller.phone;
    const m = metrics();
    const cm = ConnMetrics.init();
    const idle = phone.pending == null;
    card.header("Paired devices", "", &.{
        .{ .label = "Refresh", .style = if (idle) .secondary else .disabled, .action = .settings_phone_action, .index = 4 },
        .{ .label = if (phone.opened) "Close pairing" else "Pair a phone", .style = if (phone.opened) .secondary else .primary, .action = .settings_phone_action, .index = 0 },
    });
    card.y += theme.scaledUi(4.0);
    card.text(phone.notice, textHint(), cm.status_font, PHONE_NOTICE_BLOCK);
    if (phone.opened) {
        card.y += m.row_gap;
        pairingPanel(card);
    }
    const devices = phone.devices();
    if (phone.devices_result != null and devices.len == 0) {
        card.y += m.inner_gap;
        card.text("No paired devices yet.", textHint(), cm.status_font, null);
    }
    if (devices.len > 0) card.y += m.inner_gap;
    for (devices, 0..) |device, index| pairedDeviceRow(card, device, index, idle);
}

/// The pairing flow in an inset panel: host, permission preset, then the
/// link and QR code once created. Measured first so the panel is drawn
/// beneath its contents.
fn pairingPanel(card: *ConnPass) void {
    const pad = theme.scaledUi(14.0);
    var measure = card.*;
    measure.draw = false;
    measure.queue_hit = null;
    measure.x += pad;
    measure.w = @max(card.w - pad * 2.0, 1.0);
    measure.y += pad;
    pairingPanelContents(&measure);
    const panel: palette.Rect = .{ .x = card.x, .y = card.y, .w = card.w, .h = measure.y + pad - card.y };
    if (card.draw) queuePanelClipped(card.state, panel, raisedSurface(0.135), theme.withAlpha(theme.COLOR_WHITE, 20), radiusSm(), card.clip);
    var inner = card.*;
    inner.x = measure.x;
    inner.w = measure.w;
    inner.y = card.y + pad;
    pairingPanelContents(&inner);
    card.y = panel.y + panel.h;
}

fn pairingPanelContents(card: *ConnPass) void {
    // Pairing is local-owner management; remote connection credentials never enter this card.
    const state = card.state;
    const phone = &state.settings_controller.phone;
    const m = metrics();
    const cm = ConnMetrics.init();
    const font = cm.status_font;
    const idle = phone.pending == null;
    switch (phone.hostSource()) {
        .remote_access => {
            var host_buf: [2100]u8 = undefined;
            card.status(.good, std.fmt.bufPrint(&host_buf, "Phones connect through Remote access at {s}", .{phone.activeHost().?}) catch phone.activeHost().?, textLabel(), font, PHONE_HOST_BLOCK);
        },
        .pasted, .none => {
            card.text("Turn on Remote access above so phones can reach this computer.", textLabel(), font, null);
            // Advanced fallback for a gateway Verde does not manage.
            card.text("Advanced: paste another HTTPS gateway URL, such as https://your-host.ts.net.", textHint(), font, null);
            card.y += m.inner_gap;
            card.buttonRow(&.{.{ .label = "Paste host URL", .style = if (idle) .secondary else .disabled, .action = .settings_phone_action, .index = 1 }});
            if (phone.host_len > 0) {
                card.y += m.inner_gap;
                card.status(.neutral, phone.host[0..phone.host_len], textLabel(), font, PHONE_HOST_BLOCK);
            }
        },
    }
    card.y += m.row_gap;
    card.text("Permissions", textLabel(), theme.scaledUi(12.5), null);
    card.y += theme.scaledUi(6.0);
    const can_choose = idle and phone.grant == null;
    var presets: [phone_pairing.PAIRING_PRESETS.len]ConnButton = undefined;
    for (phone_pairing.PAIRING_PRESETS, 0..) |preset, index| presets[index] = .{
        .label = phone_pairing.presetLabel(preset),
        .style = if (phone.preset == preset) .primary else if (can_choose) .secondary else .disabled,
        .action = .settings_phone_action,
        .index = PHONE_PRESET_ACTION + index,
        .enabled = can_choose,
    };
    card.buttonRow(&presets);
    card.y += theme.scaledUi(6.0);
    card.text(phone_pairing.presetDescription(phone.preset), textHint(), font, null);
    if (phone.grant != null) card.text("Close pairing to choose permissions for a new link.", textHint(), font, null);
    card.y += m.row_gap;
    const can_create = idle and phone.activeHost() != null and phone.grant == null;
    card.buttonRow(&.{.{ .label = "Create pairing link", .style = if (can_create) .primary else .disabled, .action = .settings_phone_action, .index = 2 }});
    const grant = phone.grant orelse return;
    card.y += m.row_gap;
    if (grant.qr) |*qr| {
        // Integer modules and a four-module white quiet zone keep the local symbol scannable.
        const modules: f32 = @floatFromInt(@as(u16, qr.size) + 8);
        const unit = @max(1.0, @floor(@min(card.w, theme.scaledUi(240.0)) / modules));
        const side = modules * unit;
        const box: palette.Rect = .{ .x = @floor(card.x), .y = @floor(card.y), .w = side, .h = side };
        if (card.draw) {
            queueRoundedRectClipped(state, box, .{ .r = 1, .g = 1, .b = 1, .a = current_fade_alpha }, 0, card.clip);
            for (0..qr.size) |y| for (0..qr.size) |x| {
                if (qr.isDark(@intCast(x), @intCast(y))) queueRoundedRectClipped(state, .{
                    .x = box.x + @as(f32, @floatFromInt(x + 4)) * unit,
                    .y = box.y + @as(f32, @floatFromInt(y + 4)) * unit,
                    .w = unit,
                    .h = unit,
                }, .{ .r = 0, .g = 0, .b = 0, .a = current_fade_alpha }, 0, card.clip);
            };
        }
        card.y += side + m.row_gap;
    }
    var buf: [80]u8 = undefined;
    const seconds = @divFloor(@max(grant.expires_at_ms - @import("platform_runtime").unixTimestampMs(), 0) + 999, 1000);
    card.status(if (seconds > 0) .good else .neutral, std.fmt.bufPrint(&buf, "Link expires in {d}:{d:0>2}", .{ @divFloor(seconds, 60), @mod(seconds, 60) }) catch "", textLabel(), font, null);
    if (grant.link) |link| {
        card.y += theme.scaledUi(4.0);
        card.text(link, textHint(), font, PHONE_LINK_BLOCK);
    }
    card.y += m.inner_gap;
    card.buttonRow(&.{.{ .label = "Copy link", .style = if (seconds > 0) .secondary else .disabled, .action = .settings_phone_action, .index = 3 }});
}

/// One paired device: name over "Full access · Last seen 10 h ago", with
/// Details and a quiet Revoke (armed to Confirm revoke / Keep) at the right.
fn pairedDeviceRow(card: *ConnPass, device: anytype, index: usize, idle: bool) void {
    const state = card.state;
    const phone = &state.settings_controller.phone;
    const m = metrics();
    const cm = ConnMetrics.init();
    const now_ms = @import("platform_runtime").unixTimestampMs();
    const revoked = device.revoked_at_ms != null;
    const open = detailsOpen(detailsKey(.device, device.device_id));
    var specs: [3]ConnButton = undefined;
    var count: usize = 0;
    specs[count] = .{ .label = "Details", .action = .settings_phone_action, .index = DEVICE_DETAILS_ACTION + index, .disclosure = open };
    count += 1;
    if (!revoked) {
        if (phone.confirm_revoke == index) {
            specs[count] = .{ .label = "Keep", .style = if (idle) .secondary else .disabled, .action = .settings_phone_action, .index = 17 + index * 2 };
            count += 1;
            specs[count] = .{ .label = "Confirm revoke", .style = if (idle) .danger_confirm else .disabled, .action = .settings_phone_action, .index = 16 + index * 2 };
            count += 1;
        } else {
            specs[count] = .{ .label = "Revoke", .style = if (idle) .danger else .disabled, .action = .settings_phone_action, .index = 16 + index * 2 };
            count += 1;
        }
    }
    if (card.draw) drawDivider(state, card.x, card.y, card.w, card.clip);
    const top = card.y + cm.pad_y;
    const text_h = cm.title_h + cm.line_gap + cm.status_h;
    var buttons_w: f32 = 0.0;
    for (specs[0..count], 0..) |spec, i| buttons_w += spec.width() + if (i > 0) m.inner_gap else 0.0;
    const beside = card.w - buttons_w - m.row_gap >= cm.min_text_w;
    const text_w = if (beside) card.w - buttons_w - m.row_gap else card.w;
    if (card.draw) {
        const name = if (device.label.len > 0) device.label else "Unnamed device";
        queueFittedText(state, .{ .x = card.x, .y = top, .w = text_w, .h = cm.title_h }, name, paletteColor(theme.COLOR_WHITE), cm.title_font, card.clip);
        var access_buf: [64]u8 = undefined;
        var status_buf: [160]u8 = undefined;
        const access = deviceAccessSummary(&access_buf, device.preset, device.scopes.len);
        const status = deviceStatusText(&status_buf, access, device.last_used_at_ms, device.revoked_at_ms, now_ms);
        drawStatusLine(state, card.x, top + cm.title_h + cm.line_gap, text_w, cm.status_h, deviceTone(device.last_used_at_ms, device.revoked_at_ms, now_ms), status, card.clip);
    }
    card.y = top + text_h;
    if (beside) {
        var bx = card.x + card.w - buttons_w;
        const by = top + (text_h - cm.button_h) * 0.5;
        for (specs[0..count]) |spec| {
            const bw = spec.width();
            card.control(.{ .x = bx, .y = by, .w = bw, .h = cm.button_h }, spec);
            bx += bw + m.inner_gap;
        }
        card.y = @max(card.y, by + cm.button_h);
    } else {
        card.y += m.inner_gap;
        card.buttonRow(specs[0..count]);
    }
    card.y += cm.pad_y;
    if (!open) return;
    pairedDeviceDetails(card, device, index, now_ms);
    card.y += cm.pad_y;
}

/// Technical facts about a paired device, one selectable block per field.
fn pairedDeviceDetails(card: *ConnPass, device: anytype, index: usize, now_ms: i64) void {
    const font = ConnMetrics.init().status_font;
    const indent = theme.scaledUi(DISCLOSURE_PAD_UI);
    const x = card.x + indent;
    const w = card.w - indent;
    const base = DEVICE_DETAILS_BLOCK_BASE + @as(u32, @intCast(index % 512)) * 8;
    const gap = theme.scaledUi(3.0);
    var buf: [1024]u8 = undefined;
    card.textAt(x, w, std.fmt.bufPrint(&buf, "Device ID \u{00B7} {s}", .{device.device_id}) catch device.device_id, textLabel(), font, base);
    card.y += gap;
    const source: []const u8 = switch (device.source) {
        .pair => "Pairing link",
        .connect => "Verde Cloud",
    };
    card.textAt(x, w, std.fmt.bufPrint(&buf, "Paired via \u{00B7} {s}", .{source}) catch source, textLabel(), font, base + 1);
    card.y += gap;
    var ago_buf: [32]u8 = undefined;
    card.textAt(x, w, std.fmt.bufPrint(&buf, "Paired \u{00B7} {s}", .{humanizeAgo(&ago_buf, secondsSince(now_ms, device.created_at_ms))}) catch "", textLabel(), font, base + 2);
    card.y += gap;
    card.textAt(x, w, std.fmt.bufPrint(&buf, "Access mode cap \u{00B7} {s}", .{phone_pairing.accessModeLabel(device.max_access_mode)}) catch "", textLabel(), font, base + 3);
    card.y += gap;
    var writer: std.Io.Writer = .fixed(&buf);
    writer.writeAll("Permissions \u{00B7} ") catch {};
    if (device.scopes.len == 0) writer.writeAll("none") catch {};
    for (device.scopes, 0..) |scope, i| {
        if (i > 0) writer.writeAll(", ") catch {};
        writer.writeAll(scope) catch {};
    }
    card.textAt(x, w, writer.buffered(), textLabel(), font, base + 4);
}

const PhoneCardExtent = struct { remote_h: f32, total_h: f32 };

/// Remote access and Paired devices as two cards stacked in `rect`; returns
/// their combined height. Drawing measures first to size the card surfaces.
fn phoneCard(state: *runtime.AppState, rect: palette.Rect, clip: palette.Rect, draw: bool, queue_hit: ?QueueHitFn) f32 {
    const m = metrics();
    if (draw) {
        const extent = phoneCardPass(state, rect, clip, false, null);
        drawCard(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = extent.remote_h }, clip);
        const devices_y = rect.y + extent.remote_h + m.card_gap;
        drawCard(state, .{ .x = rect.x, .y = devices_y, .w = rect.w, .h = rect.y + extent.total_h - devices_y }, clip);
    }
    return phoneCardPass(state, rect, clip, draw, queue_hit).total_h;
}

fn phoneCardPass(state: *runtime.AppState, rect: palette.Rect, clip: palette.Rect, draw: bool, queue_hit: ?QueueHitFn) PhoneCardExtent {
    const m = metrics();
    var card: ConnPass = .{ .state = state, .x = rect.x + m.card_pad, .y = rect.y + m.card_pad, .w = @max(rect.w - m.card_pad * 2.0, 1.0), .clip = clip, .draw = draw, .queue_hit = queue_hit };
    remoteAccessSection(&card);
    const remote_h = card.y + m.card_pad - rect.y;
    card.y = rect.y + remote_h + m.card_gap + m.card_pad;
    pairedDevicesSection(&card);
    return .{ .remote_h = remote_h, .total_h = card.y + m.card_pad - rect.y };
}

/// Settings content-text selection, routed ahead of the shared modal hits.
pub fn handleTextMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool, clicks: u8) bool {
    if (!state.settings_controller.modal_visible or state.settings_controller.modal_closing) return false;
    return settings_text.handleMouseButton(state, x, y, button, down, clicks);
}

pub fn handleTextMouseMotion(state: *runtime.AppState, x: f32, y: f32) bool {
    if (!state.settings_controller.modal_visible) return false;
    return settings_text.handleMouseMotion(state, x, y);
}

/// I-beam over selectable Settings text; null elsewhere.
pub fn textSystemCursorAt(state: *const runtime.AppState, x: f32, y: f32) ?palette.platform.CursorShape {
    if (!state.settings_controller.modal_visible) return null;
    return settings_text.systemCursorAt(x, y);
}

pub fn applyPhoneAction(state: *runtime.AppState, action: usize) void {
    const phone = &state.settings_controller.phone;
    if (action >= RUNTIME_DETAILS_ACTION) {
        toggleDetails(detailsKey(.runtime, runtimeRowProfileId(state, action - RUNTIME_DETAILS_ACTION) orelse "local"));
        state.markDirty();
        return;
    }
    if (action >= DEVICE_DETAILS_ACTION and action < REMOTE_SWITCH_ACTION) {
        const devices = phone.devices();
        const index = action - DEVICE_DETAILS_ACTION;
        if (index < devices.len) toggleDetails(detailsKey(.device, devices[index].device_id));
        state.markDirty();
        return;
    }
    if (action >= REMOTE_SWITCH_ACTION) {
        applyRemoteAccessAction(state, action);
        state.markDirty();
        return;
    }
    if (action >= PHONE_PRESET_ACTION and action < PHONE_PRESET_ACTION + phone_pairing.PAIRING_PRESETS.len) {
        phone.selectPreset(action - PHONE_PRESET_ACTION);
        state.markDirty();
        return;
    }
    switch (action) {
        0 => if (phone.opened) {
            phone.close();
        } else {
            phone.opened = true;
        },
        1 => {
            const text = (host.getClipboardText(state.allocator) catch null) orelse {
                phone.notice = "Could not read the clipboard.";
                state.markDirty();
                return;
            };
            defer {
                std.crypto.secureZero(u8, text);
                state.allocator.free(text);
            }
            phone.setHost(text) catch {
                phone.notice = "Paste an HTTPS host URL without credentials, a path, query, or fragment.";
                state.markDirty();
                return;
            };
            phone.notice = "Host set. Create a link when ready to scan.";
        },
        2 => phone.start(state.storage.pref_path, .create, null),
        3 => if (phone.grant) |grant| {
            if (grant.expires_at_ms > @import("platform_runtime").unixTimestampMs()) if (grant.link) |link| {
                phone.notice = if (state.setClipboardText(link)) "Pairing link copied." else "Could not copy the link.";
            };
        },
        4 => phone.start(state.storage.pref_path, .list, null),
        else => {
            if (action < 16 or phone.pending != null) return;
            const index = (action - 16) / 2;
            if (index >= phone.devices().len) return;
            if (action % 2 == 1) {
                phone.confirm_revoke = null;
            } else if (phone.confirm_revoke == index) {
                phone.start(state.storage.pref_path, .revoke, phone.devices()[index].device_id);
            } else phone.confirm_revoke = index;
        },
    }
    state.markDirty();
}
