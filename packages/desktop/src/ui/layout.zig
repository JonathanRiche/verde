//! Root native UI composition and modal routing.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");
const colors = @import("colors.zig");
const sidebar = @import("sidebar.zig");
const workspace_panes = @import("workspace_panes.zig");
const workspace_strip = @import("workspace_strip.zig");
const runtime = @import("runtime.zig");
const keybinds = @import("../app/keybinds.zig");
const debug_window = @import("debug.zig");
const settings_modal = @import("settings_modal.zig");
const runtime_connections = @import("../state/runtime_connections_controller.zig");
const command_palette = @import("command_palette.zig");
const companion = @import("companion.zig");
const handoff_sheet = @import("handoff_sheet.zig");
const companion_controller = @import("../state/companion_controller.zig");
const profiler = @import("../runtime/profiler.zig");
const app_config = @import("../app/config.zig");

const RootLayout = struct {
    sidebar: palette.Rect,
    workspace: palette.Rect,
    target_workspace_width: f32,
};

/// Above composer overlays (150), pane menus (180), and model cascade (1400).
const PALETTE_MODAL_Z: i32 = 2000;
/// Persistent root overlay below true modal ownership and above pane content.
const COMPANION_Z: i32 = 1550;

var sidebar_anim_width: f32 = -1.0;
var sidebar_anim_x: f32 = 0.0;
var sidebar_anim_last_ms: i64 = 0;
var sidebar_animating: bool = false;

/// Updates settings-modal hover using hits from `refreshPaletteModalHits`.
pub fn updateSettingsModalHover(state: *runtime.AppState, x: f32, y: f32) void {
    settings_modal.updateHover(state, x, y);
}

/// Routes wheel input to the workspace-settings or settings modal body.
pub fn handleSettingsModalWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    if (handleWorkspaceSettingsWheel(state, width, height, x, y, wheel_y)) return true;
    return settings_modal.handleWheel(state, width, height, x, y, wheel_y);
}

/// Zooms the attachment preview while the pointer is over its canvas.
pub fn handleImageModalWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    if (state.modal_image_path == null) return false;
    if (!pointInRect(x, y, imageModalCanvasRect(width, height))) return false;
    if (wheel_y > 0.0) {
        state.adjustImageModalZoom(1);
    } else if (wheel_y < 0.0) {
        state.adjustImageModalZoom(-1);
    }
    return true;
}

/// Rebuilds palette modal hit targets from the current window size **before** SDL input is
/// processed. `renderRoot` runs after `processEvents`, so hits must not depend on that order.
pub fn refreshPaletteModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    companion.refreshHits(state, width, height);
    state.palette_modal_hits.clearRetainingCapacity();
    // Inline handoff sheet: hits come from the source pane's last-rendered
    // rect (layout is stable across frames; same staleness as pane hits).
    // The sheet dies with its source: a project switch or closed pane would
    // leave it invisible but still key-capturing, so cancel instead.
    if (state.handoff_controller.sheet_open) {
        if (state.handoff_controller.project_index != state.project_controller.selected_index) {
            state.cancelHandoff();
        } else if (workspace_panes.recordedPaneRect(state.handoff_controller.source_pane_id)) |pane_rect| {
            handoff_sheet.registerHitsForPane(state, pane_rect);
        }
    }
    registerProviderOnboardingHits(state, width, height);
    registerMcpOnboardingHits(state, width, height);
    registerImageModalHits(state, width, height);
    registerTranscriptSelectionModalHits(state, width, height);
    registerWorkspaceAddModalHits(state, width, height);
    registerWorkspaceRenameModalHits(state, width, height);
    registerThreadImportModalHits(state, width, height);
    settings_modal.registerHits(state, width, height, queueModalHit);
    registerWorkspaceSettingsModalHits(state, width, height);
    registerRuntimeWizardModalHits(state, width, height);
    command_palette.registerHits(state, width, height, queueModalHit);
    registerRuntimeCredentialModalHits(state, width, height);
    registerRuntimeTrustModalHits(state, width, height);
}

/// Updates command-palette row hover using hits from `refreshPaletteModalHits`.
pub fn updateCommandPaletteHover(state: *runtime.AppState, x: f32, y: f32) void {
    command_palette.updateHover(state, x, y);
}

/// Routes wheel input to the command palette result list when it is open.
pub fn handleCommandPaletteWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    return command_palette.handleWheel(state, width, height, x, y, wheel_y);
}

/// Routes pointer buttons to the visible Companion surface only.
pub fn handleCompanionMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool, clicks: u8) bool {
    return companion.handleMouseButton(state, x, y, button, down, clicks);
}

/// Routes pointer motion to the visible Companion surface only.
pub fn handleCompanionMouseMotion(state: *runtime.AppState, x: f32, y: f32, dragging: bool) bool {
    return companion.handleMouseMotion(state, x, y, dragging);
}

/// Routes wheel input to the sidecar without occluding outside content.
pub fn handleCompanionWheel(state: *runtime.AppState, x: f32, y: f32, wheel_y: f32) bool {
    return companion.handleWheel(state, x, y, wheel_y);
}

/// Owns a Companion Escape sequence through its matching key-up.
pub fn handleCompanionEscapeKey(state: *runtime.AppState, down: bool) bool {
    return companion.handleEscapeKey(state, down);
}

pub fn companionOwnsEscapeKey(state: *const runtime.AppState) bool {
    return companion.ownsEscapeKey(state);
}

pub fn companionOwnsPointerRelease(state: *const runtime.AppState, button: u8) bool {
    return companion.ownsPointerRelease(state, button);
}

pub fn resetCompanionInputCaptures(state: *runtime.AppState) void {
    companion.resetInputCaptures(state);
}

pub fn companionHitAt(state: *const runtime.AppState, x: f32, y: f32) ?companion_controller.HitAction {
    return companion.hitAt(state, x, y);
}

/// Updates import-modal thread list hover using hits from `refreshPaletteModalHits`.
pub fn updateThreadImportModalHover(state: *runtime.AppState, x: f32, y: f32) void {
    if (state.thread_import_provider == null) {
        if (state.thread_import_hover_index != null) {
            state.thread_import_hover_index = null;
            state.markDirty();
        }
        return;
    }

    var new_hover: ?usize = null;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (hit.action != .thread_import_select) continue;
        if (!rectContainsModalPoint(hit.rect, x, y)) continue;
        new_hover = hit.index;
        break;
    }
    if (new_hover) |hi| {
        if (hi >= state.thread_import_threads.items.len) new_hover = null;
    }

    if (state.thread_import_hover_index == new_hover) return;
    state.thread_import_hover_index = new_hover;
    state.markDirty();
}

fn rectContainsModalPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

/// Lays out the root window and routes to the main UI regions.
pub fn renderRoot(state: *runtime.AppState, width: f32, height: f32) void {
    state.resetUiDebugFrame();
    // Re-armed by the sidebar pass when it draws a pulsing pip; the main loop
    // reads the previous frame's value to pace its animation tick.
    state.sidebar_pulse_animating = false;
    const root_layout = computeRootLayout(state, width, height);
    queueRootBackground(state, width, height);
    // The workspace strip (collapsed/hidden sidebar only) takes its height off
    // the top of the workspace rect here, once, so every pane layout below and
    // the prefix overlays share the same content rect.
    const split = workspace_strip.splitWorkspaceRect(state, root_layout.workspace);
    if (split.strip) |strip| workspace_strip.render(state, strip);
    if (state.isSidebarHidden()) {
        workspace_panes.renderAtWithTranscriptLayoutWidth(state, split.content, root_layout.target_workspace_width);
        sidebar.renderPalette(state, root_layout.sidebar);
    } else {
        sidebar.renderPalette(state, root_layout.sidebar);
        workspace_panes.renderAtWithTranscriptLayoutWidth(state, split.content, root_layout.target_workspace_width);
    }
    // Queue this root overlay only after scrolling panes have clipped their
    // local command range; the batch is z-sorted, so pre-queued high-z menu
    // commands otherwise move into that range and inherit the workspace clip.
    sidebar.renderContextMenuOverlay(state);
    workspace_panes.renderPaneDragPreview(state);
    sidebar.renderFloatingDragPreview(state);
    const companion_z = state.palette_overlay_batch.setZIndex(COMPANION_Z);
    companion.render(state, width, height);
    state.palette_overlay_batch.restoreZIndex(companion_z);
    // The which-key panel must sit above pane-local layers (composer, pane
    // chrome) that queue at higher z than the workspace body.
    const which_key_z = state.palette_overlay_batch.setZIndex(PALETTE_MODAL_Z);
    renderPrefixStatusBar(state, split.content);
    renderPrefixWhichKey(state, split.content);
    renderNoticeToast(state, split.content);
    state.palette_overlay_batch.restoreZIndex(which_key_z);
    const modal_z = state.palette_overlay_batch.setZIndex(PALETTE_MODAL_Z);
    defer state.palette_overlay_batch.restoreZIndex(modal_z);
    renderImageModal(state, width, height);
    renderTranscriptSelectionModal(state, width, height);
    renderWorkspaceAddModal(state, width, height);
    renderWorkspaceRenameModal(state, width, height);
    renderThreadImportModal(state, width, height);
    renderProviderOnboardingModal(state, width, height);
    renderMcpOnboardingModal(state, width, height);
    settings_modal.render(state, width, height);
    renderWorkspaceSettingsModal(state, width, height);
    renderRuntimeWizardModal(state, width, height);
    command_palette.render(state, width, height);
    renderRuntimeCredentialModal(state, width, height);
    renderRuntimeTrustModal(state, width, height);
    debug_window.render(state, width, height);
}

// Notice toast (item 11): `setSidebarNotice` text ("Copied selection.",
// "Chat pane closed.", ...) as a small pill at the bottom centre of the
// workspace, below pane headers so it never covers header icons. Timing and
// frame pacing live in AppState (`noticeToast*`); this only draws.
const NOTICE_TOAST_FONT_UI: f32 = 13.0;
const NOTICE_TOAST_PAD_X_UI: f32 = 14.0;
const NOTICE_TOAST_PAD_Y_UI: f32 = 8.0;
const NOTICE_TOAST_MARGIN_UI: f32 = 18.0;
const NOTICE_TOAST_RISE_UI: f32 = 10.0;
const NOTICE_TOAST_MAX_W_UI: f32 = 560.0;
const NOTICE_TOAST_MAX_LINES: f32 = 4.0;

fn renderNoticeToast(state: *runtime.AppState, workspace: palette.Rect) void {
    const toast = state.noticeToast() orelse return;
    if (workspace.w <= 0.0 or workspace.h <= 0.0) return;
    const font_size = theme.scaledUi(NOTICE_TOAST_FONT_UI);
    const text_h = font_size * 1.25;
    const pad_x = theme.scaledUi(NOTICE_TOAST_PAD_X_UI);
    const pad_y = theme.scaledUi(NOTICE_TOAST_PAD_Y_UI);
    const max_w = @min(@max(workspace.w - theme.scaledUi(32.0), theme.scaledUi(80.0)), theme.scaledUi(NOTICE_TOAST_MAX_W_UI));
    const avail_w = max_w - pad_x * 2.0;
    // Measure with the `.ui` role and draw with the same role below; the
    // untyped overlay text path falls back to the prose face, which is wider
    // than the UI face and clipped the tail of longer notices.
    const measured_w = runtime.paletteUiTextPrefixWidth(toast.text, font_size, toast.text.len) + font_size * 0.35;
    // Long notices wrap onto extra lines (word wrap in the text engine) and
    // the pill grows with them rather than clipping. Line count is estimated
    // from the flat width with one line of headroom for ragged breaks.
    const wrap = measured_w > avail_w;
    const lines: f32 = if (wrap) @min(@ceil(measured_w / avail_w) + 1.0, NOTICE_TOAST_MAX_LINES) else 1.0;
    const text_w = if (wrap) avail_w else measured_w;
    const pill_w = text_w + pad_x * 2.0;
    const pill_h = text_h * lines + pad_y * 2.0;
    // Keep clear of the prefix status bar when a chord is armed.
    const bottom_reserve = if (state.prefix_armed or state.prefix_navigate) prefixBarHeight() else 0.0;
    const settled_y = workspace.y + workspace.h - bottom_reserve - theme.scaledUi(NOTICE_TOAST_MARGIN_UI) - pill_h;
    const rise_offset = (1.0 - toast.rise) * theme.scaledUi(NOTICE_TOAST_RISE_UI);
    const pill: palette.Rect = .{
        .x = workspace.x + (workspace.w - pill_w) * 0.5,
        .y = settled_y + rise_offset,
        .w = pill_w,
        .h = pill_h,
    };
    const alpha = std.math.clamp(toast.alpha, 0.0, 1.0);
    if (alpha <= 0.0) return;
    var bg = paletteColor(theme.COLOR_PANEL_ALT);
    bg.a *= alpha;
    var border = paletteColor(if (toast.persistent) theme.COLOR_YELLOW else theme.borderMuted());
    border.a *= alpha;
    var fg = paletteColor(theme.COLOR_WHITE);
    fg.a *= alpha;
    // Rounded shell as two anti-aliased fills (border colour under an inset
    // fill) instead of a stroked border, which aliases on a pill radius.
    // A multi-line card keeps a single-line pill's corner radius instead of
    // turning into a stadium.
    const radius = (text_h + pad_y * 2.0) * 0.5;
    const inset = theme.scaledUi(1.0);
    queuePaletteRoundedRect(state, pill, border, radius);
    queuePaletteRoundedRect(state, .{ .x = pill.x + inset, .y = pill.y + inset, .w = pill.w - inset * 2.0, .h = pill.h - inset * 2.0 }, bg, radius - inset);
    const text_rect: palette.Rect = .{ .x = pill.x + pad_x, .y = pill.y + pad_y, .w = text_w, .h = text_h * lines };
    queuePaletteRoleText(state, text_rect, toast.text, fg, font_size, .ui, pill, wrap);
}

// Which-key overlay: while a tmux-style prefix chord is armed, a bottom-anchored
// panel lists every second key and what it does (neovim which-key style), so
// the user never has to remember the table. Hidden the moment the chord resolves.
const WHICH_KEY_MAX_HEIGHT_RATIO: f32 = 0.55;

// Prefix status bar: herdr-style one-line strip along the bottom the moment a
// chord arms — a PREFIX pill plus `esc cancel`, `<chord> send prefix`, and
// `? keybinds` hints. Instant and unobtrusive; the full table stays behind `?`.
const PREFIX_BAR_HEIGHT_UI: f32 = 26.0;

fn prefixBarHeight() f32 {
    return theme.scaledUi(PREFIX_BAR_HEIGHT_UI);
}

fn renderPrefixStatusBar(state: *runtime.AppState, workspace: palette.Rect) void {
    if (!state.prefix_armed and !state.prefix_navigate) return;
    const config = state.command_controller.keyboard_config orelse return;
    const navigate = state.prefix_navigate and !state.prefix_armed;
    const bar_h = prefixBarHeight();
    const bar: palette.Rect = .{ .x = workspace.x, .y = workspace.y + workspace.h - bar_h, .w = workspace.w, .h = bar_h };
    queuePaletteRoundedRect(state, bar, paletteColor(theme.COLOR_PANEL_ALT), 0.0);
    queuePaletteBorder(state, .{ .x = bar.x, .y = bar.y, .w = bar.w, .h = theme.scaledUi(1.0) }, paletteColor(theme.borderMuted()), 0.0, theme.scaledUi(1.0));

    const font_size = theme.scaledUi(12.0);
    const text_h = font_size * 1.25;
    const text_y = bar.y + (bar_h - text_h) * 0.5;
    const gap = theme.scaledUi(8.0);
    const hint_gap = theme.scaledUi(18.0);
    var x = bar.x + theme.scaledUi(12.0);

    const chevron = "\u{00bb}";
    queuePaletteText(state, .{ .x = x, .y = text_y, .w = runtime.paletteUiTextPrefixWidth(chevron, font_size, chevron.len), .h = text_h }, chevron, paletteColor(theme.current_colors.text_subtle), font_size, bar);
    x += runtime.paletteUiTextPrefixWidth(chevron, font_size, chevron.len) + gap;

    const pill_label: []const u8 = if (navigate) "NAVIGATE" else "PREFIX";
    const pill_pad = theme.scaledUi(8.0);
    const pill_w = runtime.paletteUiTextPrefixWidth(pill_label, font_size, pill_label.len) + pill_pad * 2.0;
    const pill: palette.Rect = .{ .x = x, .y = bar.y + theme.scaledUi(4.0), .w = pill_w, .h = bar_h - theme.scaledUi(8.0) };
    queuePaletteRoundedRect(state, pill, paletteColor(theme.accent()), theme.scaledUi(3.0));
    queuePaletteText(state, .{ .x = pill.x + pill_pad, .y = text_y, .w = pill_w - pill_pad * 2.0, .h = text_h }, pill_label, paletteColor(theme.background()), font_size, bar);
    x += pill_w + hint_gap;

    var chord_buf: [32]u8 = undefined;
    const chord = keybinds.formatFirstKeybind(&chord_buf, config.prefix.keys);
    const help_key = prefixHelpKeyLabel(config, if (navigate) config.prefix.navigate.items else config.prefix.bindings.items);
    const help_label: []const u8 = if (state.prefix_help_visible) "hide keybinds" else "keybinds";
    if (navigate) {
        x = queuePrefixHint(state, x, text_y, text_h, font_size, gap, hint_gap, bar, "esc", "back");
        // Navigate hints come straight from the table so remaps show up;
        // positional selects and the help key are folded into fixed hints.
        var key_buf: [32]u8 = undefined;
        var label_buf: [96]u8 = undefined;
        for (config.prefix.navigate.items) |binding| {
            switch (binding.target) {
                .workspace_select, .pane_select, .active_select, .show_keybinds, .navigate => continue,
                else => {},
            }
            if (x > bar.x + bar.w) break;
            const key = keybinds.formatKeybind(&key_buf, binding.key);
            const label = keybinds.prefixTargetLabel(&label_buf, binding.target);
            x = queuePrefixHint(state, x, text_y, text_h, font_size, gap, hint_gap, bar, key, label);
        }
        x = queuePrefixHint(state, x, text_y, text_h, font_size, gap, hint_gap, bar, "1-0", "workspace");
        _ = queuePrefixHint(state, x, text_y, text_h, font_size, gap, hint_gap, bar, help_key, help_label);
    } else {
        x = queuePrefixHint(state, x, text_y, text_h, font_size, gap, hint_gap, bar, "esc", "cancel");
        x = queuePrefixHint(state, x, text_y, text_h, font_size, gap, hint_gap, bar, chord, "send prefix");
        x = queuePrefixHint(state, x, text_y, text_h, font_size, gap, hint_gap, bar, prefixNavigateKeyLabel(config), "workspace nav");
        _ = queuePrefixHint(state, x, text_y, text_h, font_size, gap, hint_gap, bar, help_key, help_label);
    }
}

/// Queues one `key label` pair and returns the next x. Empty keys are skipped.
fn queuePrefixHint(state: *runtime.AppState, x_in: f32, text_y: f32, text_h: f32, font_size: f32, gap: f32, hint_gap: f32, clip: palette.Rect, key: []const u8, label: []const u8) f32 {
    if (key.len == 0) return x_in;
    var x = x_in;
    const key_w = runtime.paletteUiTextPrefixWidth(key, font_size, key.len);
    queuePaletteText(state, .{ .x = x, .y = text_y, .w = key_w, .h = text_h }, key, paletteColor(theme.accent()), font_size, clip);
    x += key_w + gap * 0.6;
    const label_w = runtime.paletteUiTextPrefixWidth(label, font_size, label.len);
    queuePaletteText(state, .{ .x = x, .y = text_y, .w = label_w, .h = text_h }, label, paletteColor(theme.current_colors.text_muted), font_size, clip);
    return x + label_w + hint_gap;
}

fn prefixNavigateKeyLabel(config: *const keybinds.NativeKeyboardConfig) []const u8 {
    for (config.prefix.bindings.items) |binding| {
        if (binding.target != .navigate) continue;
        return keybinds.formatKeybind(&prefix_navigate_key_buf, binding.key);
    }
    return "";
}
var prefix_navigate_key_buf: [32]u8 = undefined;

/// Label for whichever chord is bound to the cheat sheet (default `?`), so a
/// remapped help key is advertised correctly. Empty when unbound.
fn prefixHelpKeyLabel(config: *const keybinds.NativeKeyboardConfig, table: []const keybinds.PrefixBinding) []const u8 {
    _ = config;
    for (table) |binding| {
        if (binding.target != .show_keybinds) continue;
        if (binding.key.shift and binding.key.key == .slash and !binding.key.ctrl and !binding.key.alt and !binding.key.meta and !binding.key.primary) return "?";
        return keybinds.formatKeybind(&prefix_help_key_buf, binding.key);
    }
    return "";
}
var prefix_help_key_buf: [32]u8 = undefined;

// Prefix cheat sheet: full which-key table above the status bar, only after `?`.
fn renderPrefixWhichKey(state: *runtime.AppState, workspace: palette.Rect) void {
    if (!state.prefix_help_visible or (!state.prefix_armed and !state.prefix_navigate)) return;
    const config = state.command_controller.keyboard_config orelse return;
    const navigate = state.prefix_navigate and !state.prefix_armed;
    const bindings = if (navigate) config.prefix.navigate.items else config.prefix.bindings.items;

    const font_size = theme.scaledUi(12.0);
    const header_size = theme.scaledUi(12.5);
    const line_h = font_size * 1.25 + theme.scaledUi(4.0);
    const pad = theme.scaledUi(14.0);
    const margin = theme.scaledUi(12.0);
    const key_gap = theme.scaledUi(10.0);
    const col_gap = theme.scaledUi(22.0);

    // Column geometry comes from measured text so long script labels and
    // multi-token chords never overlap their neighbours.
    var key_buf: [32]u8 = undefined;
    var label_buf: [96]u8 = undefined;
    var key_w: f32 = 0.0;
    var label_w: f32 = 0.0;
    for (bindings) |binding| {
        const key = keybinds.formatKeybind(&key_buf, binding.key);
        const label = keybinds.prefixTargetLabel(&label_buf, binding.target);
        key_w = @max(key_w, runtime.paletteUiTextPrefixWidth(key, font_size, key.len));
        label_w = @max(label_w, runtime.paletteUiTextPrefixWidth(label, font_size, label.len));
    }
    label_w = @min(label_w, theme.scaledUi(180.0));
    const col_w = key_w + key_gap + label_w;

    const panel_w = @max(workspace.w - margin * 2.0, theme.scaledUi(320.0));
    const inner_w = panel_w - pad * 2.0;
    const columns: usize = @max(1, @as(usize, @intFromFloat(@floor((inner_w + col_gap) / (col_w + col_gap)))));
    const max_rows: usize = @max(1, @as(usize, @intFromFloat(@floor(((workspace.h - prefixBarHeight()) * WHICH_KEY_MAX_HEIGHT_RATIO - pad * 2.0 - line_h * 1.5) / line_h))));
    const wanted_rows = (bindings.len + columns - 1) / columns;
    const rows = @min(wanted_rows, max_rows);
    const shown = @min(bindings.len, rows * columns);
    const hidden = bindings.len - shown;

    const panel_h = pad * 2.0 + line_h * 1.5 + line_h * @as(f32, @floatFromInt(rows));
    const rect: palette.Rect = .{ .x = workspace.x + margin, .y = workspace.y + workspace.h - prefixBarHeight() - margin - panel_h, .w = panel_w, .h = panel_h };
    const radius = theme.scaledUi(8.0);
    queuePaletteRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 245)), radius);
    queuePaletteBorder(state, rect, paletteColor(theme.accent()), radius, theme.scaledUi(1.0));

    var chord_buf: [32]u8 = undefined;
    const chord = keybinds.formatFirstKeybind(&chord_buf, config.prefix.keys);
    var header_buf: [96]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} keybinds{s}", .{
        if (navigate) "Workspace nav" else chord,
        if (hidden > 0) "  (table truncated)" else "",
    }) catch chord;
    queuePaletteText(state, .{ .x = rect.x + pad, .y = rect.y + pad, .w = inner_w, .h = header_size * 1.25 }, header, paletteColor(theme.current_colors.text_muted), header_size, rect);

    const grid_y = rect.y + pad + line_h * 1.5;
    for (bindings[0..shown], 0..) |binding, index| {
        const col = index / rows;
        const row = index % rows;
        const x = rect.x + pad + @as(f32, @floatFromInt(col)) * (col_w + col_gap);
        const y = grid_y + @as(f32, @floatFromInt(row)) * line_h;
        const key = keybinds.formatKeybind(&key_buf, binding.key);
        const label = keybinds.prefixTargetLabel(&label_buf, binding.target);
        const this_key_w = runtime.paletteUiTextPrefixWidth(key, font_size, key.len);
        // Right-align keys inside the key column so labels start on one edge.
        queuePaletteText(state, .{ .x = x + key_w - this_key_w, .y = y, .w = this_key_w, .h = font_size * 1.25 }, key, paletteColor(theme.accent()), font_size, rect);
        queuePaletteText(state, .{ .x = x + key_w + key_gap, .y = y, .w = label_w, .h = font_size * 1.25 }, label, paletteColor(theme.current_colors.text), font_size, rect);
    }
}

pub fn isSidebarAnimating() bool {
    return sidebar_animating;
}

fn computeRootLayout(state: *runtime.AppState, width: f32, height: f32) RootLayout {
    const gap: f32 = 0.0;
    const target_sidebar_width = if (state.isSidebarCollapsed())
        theme.clampf(width * 0.07, theme.scaledUi(60.0), theme.scaledUi(76.0))
    else if (width < theme.scaledUi(900.0))
        theme.clampf(width * 0.34, theme.scaledUi(180.0), theme.scaledUi(240.0))
    else
        // The compacted rail (tight padding, no History rows, hover-only
        // actions, ~96px status column) reads comfortably well below the old
        // 465px cap; keep width for the workspace panes instead.
        theme.clampf(width * 0.19, theme.scaledUi(260.0), @min(theme.scaledUi(360.0), width * 0.32));

    const hidden = state.isSidebarHidden();
    const target_sidebar_x = if (hidden and !state.isSidebarHoverRevealed()) -target_sidebar_width else 0.0;
    const now_ms: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    if (sidebar_anim_width < 0.0) {
        sidebar_anim_width = target_sidebar_width;
        sidebar_anim_x = target_sidebar_x;
        sidebar_anim_last_ms = now_ms;
    }
    const dt_ms = @max(now_ms - sidebar_anim_last_ms, 0);
    sidebar_anim_last_ms = now_ms;
    const duration_ms = theme.motionDurationMs(state.app_config.reduced_motion, theme.MOTION_BASE_MS);
    const step = if (duration_ms <= 0)
        1.0
    else
        theme.clampf(@as(f32, @floatFromInt(dt_ms)) / @as(f32, @floatFromInt(duration_ms)), 0.0, 1.0);
    const eased = theme.easeOutCubic(step);
    sidebar_anim_width = approach(sidebar_anim_width, target_sidebar_width, eased);
    sidebar_anim_x = approach(sidebar_anim_x, target_sidebar_x, eased);
    sidebar_animating = @abs(sidebar_anim_width - target_sidebar_width) > 0.5 or @abs(sidebar_anim_x - target_sidebar_x) > 0.5;
    if (!sidebar_animating) {
        sidebar_anim_width = target_sidebar_width;
        sidebar_anim_x = target_sidebar_x;
    }

    const layout_sidebar_width = if (hidden) 0.0 else sidebar_anim_width;
    const target_layout_sidebar_width = if (hidden) 0.0 else target_sidebar_width;
    const workspace_width = @max(width - layout_sidebar_width - gap, theme.scaledUi(320.0));
    return .{
        .sidebar = .{ .x = sidebar_anim_x, .y = 0.0, .w = sidebar_anim_width, .h = height },
        .workspace = .{ .x = layout_sidebar_width + gap, .y = 0.0, .w = workspace_width, .h = height },
        .target_workspace_width = @max(width - target_layout_sidebar_width - gap, theme.scaledUi(320.0)),
    };
}

fn approach(current: f32, target: f32, t: f32) f32 {
    return current + (target - current) * t;
}

fn queueRootBackground(state: *runtime.AppState, width: f32, height: f32) void {
    state.palette_overlay_batch.rect(state.allocator, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, paletteColor(theme.background())) catch |err| {
        runtime.log.warn("failed to queue root palette background: {s}", .{@errorName(err)});
    };
}

fn queuePaletteRoundedRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch |err| {
        runtime.log.warn("failed to queue layout palette rounded rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch |err| {
        runtime.log.warn("failed to queue layout palette border: {s}", .{@errorName(err)});
    };
}

fn queuePaletteText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stablePaletteText(state, value) catch |err| {
        runtime.log.warn("failed to retain layout palette text: {s}", .{@errorName(err)});
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
        runtime.log.warn("failed to queue layout palette text: {s}", .{@errorName(err)});
    };
}

/// Overlay text drawn with an explicit font role so callers that measured
/// with that role (see `runtime.paletteUiTextPrefixWidth`) get matching
/// glyph advances; `queuePaletteText` leaves the role unset and the renderer
/// then falls back to its default (prose) face.
fn queuePaletteRoleText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, font_role: palette.FontRole, clip: ?palette.Rect, wrap: bool) void {
    const stable_value = stablePaletteText(state, value) catch |err| {
        runtime.log.warn("failed to retain layout palette text: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.fixedRoleText(
        state.allocator,
        rect,
        stable_value,
        color,
        font_size,
        font_role,
        null,
        clip,
        .{},
        font_size * 0.55,
        font_size * 1.25,
        wrap,
    ) catch |err| {
        runtime.log.warn("failed to queue layout palette text: {s}", .{@errorName(err)});
    };
}

fn stablePaletteText(state: *runtime.AppState, value: []const u8) ![]const u8 {
    return try state.palette_frame_text_arena.allocator().dupe(u8, value);
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn queueModalHit(state: *runtime.AppState, rect: palette.Rect, action: runtime.PaletteModalAction, index: usize) void {
    state.palette_modal_hits.append(state.allocator, .{ .rect = rect, .action = action, .index = index }) catch |err| {
        runtime.log.warn("failed to retain layout modal hit: {s}", .{@errorName(err)});
    };
}

fn drawActionButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, color: [4]f32) void {
    const hovered = pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, rect);
    const fill = if (hovered) theme.lighten(color, 0.055) else color;
    const border = if (hovered) theme.lighten(color, 0.14) else theme.lighten(color, 0.06);
    queuePaletteRoundedRect(state, rect, paletteColor(fill), theme.scaledUi(7.0));
    queuePaletteBorder(state, rect, paletteColor(border), theme.scaledUi(7.0), theme.scaledUi(if (hovered) 1.5 else 1.0));
    const font_size = theme.scaledUi(14.0);
    const estimated_text_width = @as(f32, @floatFromInt(label.len)) * font_size * 0.52;
    queuePaletteText(state, .{
        .x = rect.x + @max((rect.w - estimated_text_width) * 0.5, theme.scaledUi(4.0)),
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = @max(@min(estimated_text_width + theme.scaledUi(2.0), rect.w - theme.scaledUi(8.0)), theme.scaledUi(8.0)),
        .h = font_size * 1.25,
    }, label, paletteColor(theme.foregroundOn(fill)), font_size, rect);
}

// ---------------------------------------------------------------------------
// Workspace Settings modal: bound to one workspace by id; first section is
// "Default runtime for new chats" plus a route to global connection
// management. Selection changes elsewhere never retarget the modal.
// ---------------------------------------------------------------------------

const WORKSPACE_SETTINGS_ROW_H_UI: f32 = 46.0;

const WorkspaceSettingsLayout = struct {
    modal: palette.Rect,
    title_y: f32,
    section_y: f32,
    /// Clip rect of the scrollable option list.
    list: palette.Rect,
    row_h: f32,
    explain_y: f32,
    scroll_section_y: f32,
    scroll_scope_app: palette.Rect,
    scroll_scope_custom: palette.Rect,
    scroll_mode_automatic: palette.Rect,
    scroll_mode_always: palette.Rect,
    scroll_mode_disabled: palette.Rect,
    scroll_threshold_dec: palette.Rect,
    scroll_threshold_inc: palette.Rect,
    show_scroll_mode: bool,
    show_scroll_threshold: bool,
    notice_y: f32,
    manage_button: palette.Rect,
    close_button: palette.Rect,
    max_scroll_y: f32,
};

// Fixed vertical bands around a height-clamped option list so the modal fits
// short laptop heights; only the list scrolls.
fn workspaceSettingsLayout(state: *const runtime.AppState, width: f32, height: f32) WorkspaceSettingsLayout {
    const pad = theme.scaledUi(20.0);
    const gap = theme.scaledUi(10.0);
    const title_h = theme.scaledUi(24.0);
    const section_h = theme.scaledUi(20.0);
    const explain_h = theme.scaledUi(17.0) * 3.0;
    const notice_h = theme.scaledUi(18.0);
    const button_h = theme.scaledUi(34.0);
    const control_h = theme.scaledUi(36.0);
    const row_h = theme.scaledUi(WORKSPACE_SETTINGS_ROW_H_UI);
    const override_enabled = state.settings_controller.draft.workspace_scroll_override_enabled;
    const show_scroll_mode = override_enabled;
    const show_scroll_threshold = override_enabled and state.settings_controller.draft.workspace_scroll_mode == .automatic;
    var scroll_block_h = section_h + gap + control_h;
    if (show_scroll_mode) scroll_block_h += gap + section_h + gap + control_h;
    if (show_scroll_threshold) scroll_block_h += gap + control_h;
    const modal_w = @min(theme.scaledUi(560.0), @max(width - theme.scaledUi(64.0), theme.scaledUi(320.0)));
    const rows_h = row_h * @as(f32, @floatFromInt(state.workspaceSettingsOptionCount()));
    const fixed_h = pad + title_h + gap + section_h + gap + gap + explain_h + gap + scroll_block_h + gap + notice_h + gap + button_h + pad;
    const max_modal_h = @max(height - theme.scaledUi(96.0), theme.scaledUi(300.0));
    const list_h = theme.clampf(rows_h, row_h, @max(max_modal_h - fixed_h, row_h));
    const modal_h = fixed_h + list_h;
    const modal: palette.Rect = .{
        .x = (width - modal_w) * 0.5,
        .y = @max((height - modal_h) * 0.5, theme.scaledUi(24.0)),
        .w = modal_w,
        .h = modal_h,
    };
    const title_y = modal.y + pad;
    const section_y = title_y + title_h + gap;
    const list: palette.Rect = .{
        .x = modal.x + pad,
        .y = section_y + section_h + gap,
        .w = modal.w - pad * 2.0,
        .h = list_h,
    };
    const explain_y = list.y + list.h + gap;
    const scroll_section_y = explain_y + explain_h + gap;
    const scope_y = scroll_section_y + section_h + gap;
    const scope_w = list.w * 0.5;
    const scroll_scope_app: palette.Rect = .{ .x = list.x, .y = scope_y, .w = scope_w, .h = control_h };
    const scroll_scope_custom: palette.Rect = .{ .x = scroll_scope_app.x + scope_w, .y = scope_y, .w = scope_w, .h = control_h };
    const mode_label_y = scope_y + control_h + gap;
    const mode_y = mode_label_y + section_h + gap;
    const mode_w = list.w / 3.0;
    const empty: palette.Rect = .{ .x = 0.0, .y = -10000.0, .w = 0.0, .h = 0.0 };
    const scroll_mode_automatic: palette.Rect = if (show_scroll_mode) .{ .x = list.x, .y = mode_y, .w = mode_w, .h = control_h } else empty;
    const scroll_mode_always: palette.Rect = if (show_scroll_mode) .{ .x = scroll_mode_automatic.x + mode_w, .y = mode_y, .w = mode_w, .h = control_h } else empty;
    const scroll_mode_disabled: palette.Rect = if (show_scroll_mode) .{ .x = scroll_mode_always.x + mode_w, .y = mode_y, .w = mode_w, .h = control_h } else empty;
    const threshold_y = if (show_scroll_mode) mode_y + control_h + gap else scope_y + control_h + gap;
    const step_w = theme.scaledUi(32.0);
    const scroll_threshold_inc: palette.Rect = if (show_scroll_threshold)
        .{ .x = list.x + list.w - step_w, .y = threshold_y, .w = step_w, .h = control_h }
    else
        empty;
    const scroll_threshold_dec: palette.Rect = if (show_scroll_threshold)
        .{ .x = scroll_threshold_inc.x - theme.scaledUi(44.0) - step_w, .y = threshold_y, .w = step_w, .h = control_h }
    else
        empty;
    const scroll_bottom = if (show_scroll_threshold)
        threshold_y + control_h
    else if (show_scroll_mode)
        mode_y + control_h
    else
        scope_y + control_h;
    const notice_y = scroll_bottom + gap;
    const button_y = notice_y + notice_h + gap;
    const close_w = theme.scaledUi(96.0);
    const manage_w = theme.scaledUi(176.0);
    const close_button: palette.Rect = .{ .x = modal.x + modal.w - pad - close_w, .y = button_y, .w = close_w, .h = button_h };
    const manage_button: palette.Rect = .{ .x = close_button.x - theme.scaledUi(8.0) - manage_w, .y = button_y, .w = manage_w, .h = button_h };
    return .{
        .modal = modal,
        .title_y = title_y,
        .section_y = section_y,
        .list = list,
        .row_h = row_h,
        .explain_y = explain_y,
        .scroll_section_y = scroll_section_y,
        .scroll_scope_app = scroll_scope_app,
        .scroll_scope_custom = scroll_scope_custom,
        .scroll_mode_automatic = scroll_mode_automatic,
        .scroll_mode_always = scroll_mode_always,
        .scroll_mode_disabled = scroll_mode_disabled,
        .scroll_threshold_dec = scroll_threshold_dec,
        .scroll_threshold_inc = scroll_threshold_inc,
        .show_scroll_mode = show_scroll_mode,
        .show_scroll_threshold = show_scroll_threshold,
        .notice_y = notice_y,
        .manage_button = manage_button,
        .close_button = close_button,
        .max_scroll_y = @max(rows_h - list_h, 0.0),
    };
}

fn workspaceSettingsOptionRowRect(layout: WorkspaceSettingsLayout, index: usize, scroll_y: f32) palette.Rect {
    return .{
        .x = layout.list.x,
        .y = layout.list.y + @as(f32, @floatFromInt(index)) * layout.row_h - scroll_y,
        .w = layout.list.w,
        .h = layout.row_h - theme.scaledUi(4.0),
    };
}

fn rectIntersection(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
}

fn registerWorkspaceSettingsModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.workspaceSettingsOpen()) return;
    if (state.workspaceSettingsProject() == null) return;
    const layout = workspaceSettingsLayout(state, width, height);
    registerModalChromeHits(state, width, height, layout.modal, true);
    const scroll_y = theme.clampf(state.workspace_settings_scroll_y, 0.0, layout.max_scroll_y);
    const count = state.workspaceSettingsOptionCount();
    var index: usize = 0;
    while (index < count) : (index += 1) {
        // Hits are clipped to the visible list band so scrolled-out rows
        // cannot be clicked through the explainer text or buttons.
        const clipped = rectIntersection(workspaceSettingsOptionRowRect(layout, index, scroll_y), layout.list);
        if (clipped.h <= 0.0) continue;
        queueModalHit(state, clipped, .workspace_settings_option, index);
    }
    queueModalHit(state, layout.manage_button, .workspace_settings_manage, 0);
    queueModalHit(state, layout.close_button, .workspace_settings_close, 0);
    queueModalHit(state, layout.scroll_scope_app, .workspace_settings_scroll_scope, 0);
    queueModalHit(state, layout.scroll_scope_custom, .workspace_settings_scroll_scope, 1);
    if (layout.show_scroll_mode) {
        queueModalHit(state, layout.scroll_mode_automatic, .workspace_settings_scroll_mode, 0);
        queueModalHit(state, layout.scroll_mode_always, .workspace_settings_scroll_mode, 1);
        queueModalHit(state, layout.scroll_mode_disabled, .workspace_settings_scroll_mode, 2);
    }
    if (layout.show_scroll_threshold) {
        queueModalHit(state, layout.scroll_threshold_dec, .workspace_settings_scroll_threshold_dec, 0);
        queueModalHit(state, layout.scroll_threshold_inc, .workspace_settings_scroll_threshold_inc, 0);
    }
}

/// Scrolls the workspace-settings option list while the pointer is over it.
fn handleWorkspaceSettingsWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    if (!state.workspaceSettingsOpen()) return false;
    const layout = workspaceSettingsLayout(state, width, height);
    if (!pointInRect(x, y, layout.modal)) return true; // swallow: modal owns the wheel
    if (!pointInRect(x, y, layout.list)) return true;
    state.workspace_settings_scroll_y = theme.clampf(
        state.workspace_settings_scroll_y - wheel_y * theme.scaledUi(48.0),
        0.0,
        layout.max_scroll_y,
    );
    state.markDirty();
    return true;
}

// Workspace Settings modal body: workspace-identifying title, single-choice
// default-runtime list with the current default marked, scope explainer, and
// Manage connections / Close actions.
fn renderWorkspaceSettingsModal(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.workspaceSettingsOpen()) return;
    const project = state.workspaceSettingsProject() orelse {
        // The bound workspace was closed/archived while the modal was open.
        state.closeWorkspaceSettings();
        return;
    };
    const layout = workspaceSettingsLayout(state, width, height);
    drawModalChromeVisual(state, width, height, layout.modal);
    const pad = theme.scaledUi(20.0);
    const content_w = layout.modal.w - pad * 2.0;

    var title_buffer: [192]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buffer, "Workspace settings — {s}", .{project.label}) catch "Workspace settings";
    queuePaletteText(state, .{ .x = layout.modal.x + pad, .y = layout.title_y, .w = content_w, .h = theme.scaledUi(24.0) }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), layout.modal);
    queuePaletteText(state, .{ .x = layout.modal.x + pad, .y = layout.section_y, .w = content_w, .h = theme.scaledUi(20.0) }, "Default runtime for new chats", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.5), layout.modal);

    state.workspace_settings_scroll_y = theme.clampf(state.workspace_settings_scroll_y, 0.0, layout.max_scroll_y);
    const mouse_x = state.transcript_controller.palette_mouse_x;
    const mouse_y = state.transcript_controller.palette_mouse_y;
    const count = state.workspaceSettingsOptionCount();
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const option = state.workspaceSettingsOptionAt(index) orelse continue;
        const row = workspaceSettingsOptionRowRect(layout, index, state.workspace_settings_scroll_y);
        if (row.y + row.h < layout.list.y or row.y > layout.list.y + layout.list.h) continue;
        const hovered = pointInRect(mouse_x, mouse_y, row) and pointInRect(mouse_x, mouse_y, layout.list);
        if (option.is_current) {
            queuePaletteRoundedRect(state, rectIntersection(row, layout.list), paletteColor(theme.withAlpha(theme.COLOR_GREEN, 30)), theme.scaledUi(8.0));
        } else if (hovered) {
            queuePaletteRoundedRect(state, rectIntersection(row, layout.list), paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 220)), theme.scaledUi(8.0));
        }
        // Radio affordance: outer ring always, inner dot only on the current
        // default so single-choice semantics read at a glance.
        const radio_size = theme.scaledUi(14.0);
        const radio: palette.Rect = .{
            .x = row.x + theme.scaledUi(12.0),
            .y = row.y + (row.h - radio_size) * 0.5,
            .w = radio_size,
            .h = radio_size,
        };
        // The ring/dot cannot be partially clipped like the rects above (the
        // border primitive has no clip rect), so draw them only when the
        // radio sits fully inside the list band; a half row shows text and
        // background alone rather than a ring bleeding into the explainer.
        const radio_fully_visible = radio.y >= layout.list.y and
            radio.y + radio.h <= layout.list.y + layout.list.h;
        if (radio_fully_visible) {
            queuePaletteBorder(state, radio, paletteColor(if (option.is_current) theme.COLOR_GREEN else theme.COLOR_TEXT_SUBTLE), radio_size * 0.5, theme.scaledUi(1.5));
            if (option.is_current) {
                const dot_inset = theme.scaledUi(4.0);
                queuePaletteRoundedRect(state, .{
                    .x = radio.x + dot_inset,
                    .y = radio.y + dot_inset,
                    .w = radio.w - dot_inset * 2.0,
                    .h = radio.h - dot_inset * 2.0,
                }, paletteColor(theme.COLOR_GREEN), (radio.w - dot_inset * 2.0) * 0.5);
            }
        }
        const badge = if (option.status) |status| runtime.runtimePickerStatusBadge(status) else "Always available";
        const badge_color = if (option.status) |status| runtime.runtimeStatusTone(status).color() else theme.COLOR_TEXT_MUTED;
        const badge_w = theme.scaledUi(170.0);
        const label_x = radio.x + radio_size + theme.scaledUi(10.0);
        queuePaletteText(state, .{
            .x = label_x,
            .y = row.y + (row.h - theme.scaledUi(20.0)) * 0.5,
            .w = @max(row.x + row.w - badge_w - theme.scaledUi(20.0) - label_x, theme.scaledUi(48.0)),
            .h = theme.scaledUi(20.0),
        }, option.label, paletteColor(if (option.is_current or hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(14.5), layout.list);
        queuePaletteText(state, .{
            .x = row.x + row.w - badge_w - theme.scaledUi(12.0),
            .y = row.y + (row.h - theme.scaledUi(17.0)) * 0.5,
            .w = badge_w,
            .h = theme.scaledUi(17.0),
        }, badge, paletteColor(badge_color), theme.scaledUi(12.0), layout.list);
    }

    const explain_lines: [3][]const u8 = .{
        "Applies to new chats in this workspace only.",
        "Chats that already started keep the runtime they were using.",
        "Each chat can still pick its own runtime from the composer.",
    };
    for (explain_lines, 0..) |line, line_index| {
        queuePaletteText(state, .{
            .x = layout.modal.x + pad,
            .y = layout.explain_y + @as(f32, @floatFromInt(line_index)) * theme.scaledUi(17.0),
            .w = content_w,
            .h = theme.scaledUi(17.0),
        }, line, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), layout.modal);
    }
    queuePaletteText(state, .{
        .x = layout.modal.x + pad,
        .y = layout.scroll_section_y,
        .w = content_w,
        .h = theme.scaledUi(20.0),
    }, "Scrolling", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.5), layout.modal);
    drawWorkspaceSettingsSegment(
        state,
        layout.scroll_scope_app,
        "App default",
        !state.settings_controller.draft.workspace_scroll_override_enabled,
        pointInRect(mouse_x, mouse_y, layout.scroll_scope_app),
    );
    drawWorkspaceSettingsSegment(
        state,
        layout.scroll_scope_custom,
        "Custom",
        state.settings_controller.draft.workspace_scroll_override_enabled,
        pointInRect(mouse_x, mouse_y, layout.scroll_scope_custom),
    );
    if (layout.show_scroll_mode) {
        queuePaletteText(state, .{
            .x = layout.modal.x + pad,
            .y = layout.scroll_mode_automatic.y - theme.scaledUi(28.0),
            .w = content_w,
            .h = theme.scaledUi(20.0),
        }, "Mode", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.5), layout.modal);
        const mode = state.settings_controller.draft.workspace_scroll_mode;
        drawWorkspaceSettingsSegment(state, layout.scroll_mode_automatic, "Auto", mode == .automatic, pointInRect(mouse_x, mouse_y, layout.scroll_mode_automatic));
        drawWorkspaceSettingsSegment(state, layout.scroll_mode_always, "Always", mode == .always, pointInRect(mouse_x, mouse_y, layout.scroll_mode_always));
        drawWorkspaceSettingsSegment(state, layout.scroll_mode_disabled, "Off", mode == .disabled, pointInRect(mouse_x, mouse_y, layout.scroll_mode_disabled));
    }
    if (layout.show_scroll_threshold) {
        var threshold_buf: [24]u8 = undefined;
        const threshold_label = std.fmt.bufPrint(&threshold_buf, "Start after {d} panes", .{state.settings_controller.draft.workspace_scroll_threshold}) catch "Start after";
        queuePaletteText(state, .{
            .x = layout.modal.x + pad,
            .y = layout.scroll_threshold_dec.y + (layout.scroll_threshold_dec.h - theme.scaledUi(18.0)) * 0.5,
            .w = @max(layout.scroll_threshold_dec.x - layout.modal.x - pad - theme.scaledUi(8.0), theme.scaledUi(80.0)),
            .h = theme.scaledUi(18.0),
        }, threshold_label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), layout.modal);
        drawWorkspaceSettingsSegment(state, layout.scroll_threshold_dec, "−", false, pointInRect(mouse_x, mouse_y, layout.scroll_threshold_dec));
        drawWorkspaceSettingsSegment(state, layout.scroll_threshold_inc, "+", false, pointInRect(mouse_x, mouse_y, layout.scroll_threshold_inc));
    }
    const notice = state.workspaceSettingsNotice();
    if (notice.len > 0) {
        queuePaletteText(state, .{ .x = layout.modal.x + pad, .y = layout.notice_y, .w = content_w, .h = theme.scaledUi(18.0) }, notice, paletteColor(theme.COLOR_GREEN), theme.scaledUi(12.5), layout.modal);
    }
    drawActionButton(state, layout.manage_button, "Manage connections", theme.COLOR_PANEL_ALT);
    drawActionButton(state, layout.close_button, "Close", theme.accent());
}

fn drawWorkspaceSettingsSegment(state: *runtime.AppState, rect: palette.Rect, label: []const u8, selected: bool, hovered: bool) void {
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    const fill = if (selected) theme.withAlpha(theme.accent(), 44) else if (hovered) theme.withAlpha(theme.COLOR_PANEL_ALT, 220) else theme.COLOR_PANEL_ALT;
    const border = if (selected) theme.withAlpha(theme.accent(), 140) else theme.withAlpha(theme.COLOR_WHITE, 26);
    queuePaletteRoundedRect(state, rect, paletteColor(fill), theme.scaledUi(7.0));
    queuePaletteBorder(state, rect, paletteColor(border), theme.scaledUi(7.0), theme.scaledUi(1.0));
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(8.0),
        .y = rect.y + (rect.h - theme.scaledUi(16.0)) * 0.5,
        .w = @max(rect.w - theme.scaledUi(16.0), theme.scaledUi(8.0)),
        .h = theme.scaledUi(16.0),
    }, label, paletteColor(if (selected or hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), rect);
}

fn drawModalChromeVisual(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect) void {
    const scrim: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = width, .h = height };
    queuePaletteRoundedRect(state, scrim, paletteColor(theme.scrim(0.68)), 0.0);
    queuePaletteRoundedRect(state, modal, paletteColor(theme.COLOR_PANEL), theme.scaledUi(12.0));
    queuePaletteBorder(state, modal, paletteColor(theme.withAlpha(theme.borderMuted(), 110)), theme.scaledUi(12.0), theme.scaledUi(1.0));
}

fn registerModalChromeHits(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect, dismissible: bool) void {
    const scrim: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = width, .h = height };
    queueModalHit(state, scrim, if (dismissible) .modal_dismiss else .modal_block, 0);
    queueModalHit(state, modal, .modal_block, 0);
}

fn drawTextField(state: *runtime.AppState, rect: palette.Rect, value: []const u8, hint: []const u8, focused: bool, cursor: usize) void {
    const border = if (focused) theme.accent() else theme.COLOR_PANEL_MUTED;
    queuePaletteRoundedRect(state, rect, paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.03)), theme.scaledUi(7.0));
    queuePaletteBorder(state, rect, paletteColor(border), theme.scaledUi(7.0), theme.scaledUi(1.0));
    const text = if (value.len > 0) value else hint;
    const color = if (value.len > 0) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE;
    const font_size = theme.scaledUi(14.0);
    const text_x = rect.x + theme.scaledUi(10.0);
    const text_y = rect.y + theme.scaledUi(8.0);
    const text_w = rect.w - theme.scaledUi(20.0);

    if (focused) {
        // Cache the input geometry so the mouse/keyboard handlers can
        // hit-test and convert click-x to text offset without re-running
        // the modal layout.
        state.modal_text_input_rect = rect;
        state.modal_text_input_font_size = font_size;
        if (modalSelectionRange(state, value)) |sel| {
            const x0 = text_x + runtime.paletteUiTextPrefixWidth(value, font_size, sel.start);
            const x1 = text_x + runtime.paletteUiTextPrefixWidth(value, font_size, sel.end);
            const clamped_x0 = @max(x0, text_x);
            const clamped_x1 = @min(x1, text_x + text_w);
            if (clamped_x1 > clamped_x0) {
                state.palette_overlay_batch.rect(
                    state.allocator,
                    .{ .x = clamped_x0, .y = text_y, .w = clamped_x1 - clamped_x0, .h = theme.scaledUi(20.0) },
                    paletteColor(theme.withAlpha(theme.selection(), 200)),
                ) catch {};
            }
        }
    }

    const stable_value = stablePaletteText(state, text) catch return;
    state.palette_overlay_batch.roleText(
        state.allocator,
        .{ .x = text_x, .y = text_y, .w = text_w, .h = theme.scaledUi(20.0) },
        stable_value,
        paletteColor(color),
        font_size,
        .ui,
        null,
        rect,
    ) catch {};
    if (focused) {
        const clamped_cursor = @min(cursor, value.len);
        const prefix_w = runtime.paletteUiTextPrefixWidth(value, font_size, clamped_cursor);
        const cursor_x = text_x + prefix_w;
        state.palette_overlay_batch.rect(state.allocator, .{ .x = cursor_x, .y = text_y, .w = theme.scaledUi(1.0), .h = rect.h - theme.scaledUi(16.0) }, paletteColor(theme.COLOR_WHITE)) catch {};
    }
}

// Renders the bearer field using only a same-length non-secret mask.
fn drawRuntimeCredentialField(state: *runtime.AppState, rect: palette.Rect) void {
    // The bearer itself never enters a Palette batch, frame arena,
    // diagnostic, or other UI-owned allocation.
    var masked: [4096]u8 = undefined;
    const value = maskedRuntimeCredential(&masked, state.runtimeCredentialToken().len);
    drawTextField(
        state,
        rect,
        value,
        "Bearer token",
        state.palette_modal_text_focus == .runtime_credential,
        state.runtime_credential_token_cursor,
    );
}

const ModalSelectionRange = struct { start: usize, end: usize };

fn modalSelectionRange(state: *runtime.AppState, value: []const u8) ?ModalSelectionRange {
    const anchor = state.modal_text_selection_anchor orelse return null;
    const cursor = focusedCursorReadOnly(state);
    const a = @min(anchor, value.len);
    const c = @min(cursor, value.len);
    if (a == c) return null;
    return .{ .start = @min(a, c), .end = @max(a, c) };
}

fn focusedCursorReadOnly(state: *runtime.AppState) usize {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.project_rename_cursor,
        .thread_import => state.thread_import_cursor,
        .project_import_name => state.project_import_name_cursor,
        .project_import => state.project_import_cursor,
        .runtime_credential => state.runtime_credential_token_cursor,
        .runtime_wizard_label => state.runtime_connections.label_cursor,
        .runtime_wizard_host => state.runtime_connections.host_cursor,
        .runtime_wizard_user => state.runtime_connections.user_cursor,
        .runtime_wizard_ssh_port => state.runtime_connections.ssh_port_cursor,
        .runtime_wizard_gateway_port => state.runtime_connections.gateway_port_cursor,
        .runtime_wizard_grant_id => state.runtime_connections.grant_id_cursor,
        .runtime_wizard_pairing_code => state.runtime_connections.pairing_code_cursor,
        .runtime_wizard_device_label => state.runtime_connections.device_label_cursor,
        .runtime_wizard_control_plane_url => state.runtime_connections.control_plane_url_cursor,
        .command_palette => state.command_controller.cursor,
        .none => 0,
    };
}

/// Fields whose bytes are secrets: rendered masked, zeroed on delete, and
/// never handed to the frame arena.
fn isSecretModalFocus(state: *const runtime.AppState, focus: runtime.PaletteModalTextFocus) bool {
    return focus == .runtime_credential or focus == .runtime_wizard_pairing_code or
        (focus == .runtime_wizard_control_plane_url and
            state.runtime_connections.wizard_method == .pair and
            state.runtime_connections.wizard_mode == .add);
}

fn clearModalSelection(state: *runtime.AppState) void {
    state.modal_text_selection_anchor = null;
}

fn blurModalTextInput(state: *runtime.AppState) void {
    state.palette_modal_text_focus = .none;
    state.modal_text_selection_anchor = null;
    state.modal_text_drag_active = false;
}

/// Clears modal caret-selection gestures when the native window loses focus.
pub fn blurPaletteModalTextInput(state: *runtime.AppState) void {
    blurModalTextInput(state);
}

fn modalOffsetForClickX(value: []const u8, font_size: f32, rel: f32) usize {
    if (value.len == 0 or rel <= 0.0) return 0;
    const total = runtime.paletteUiTextPrefixWidth(value, font_size, value.len);
    if (rel >= total) return value.len;
    var i: usize = 0;
    while (i < value.len) {
        const step = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        const next = @min(i + step, value.len);
        const w_before = runtime.paletteUiTextPrefixWidth(value, font_size, i);
        const w_after = runtime.paletteUiTextPrefixWidth(value, font_size, next);
        if (w_after > rel) {
            return if (rel - w_before <= w_after - rel) i else next;
        }
        i = next;
    }
    return value.len;
}

fn maskedRuntimeCredential(buffer: *[4096]u8, len: usize) []const u8 {
    const masked_len = @min(len, buffer.len);
    @memset(buffer[0..masked_len], '*');
    return buffer[0..masked_len];
}

fn focusedMetricOffsetForClickX(
    state: *runtime.AppState,
    value: []const u8,
    font_size: f32,
    rel: f32,
) usize {
    if (!isSecretModalFocus(state, state.palette_modal_text_focus)) {
        return modalOffsetForClickX(value, font_size, rel);
    }
    var masked: [4096]u8 = undefined;
    return modalOffsetForClickX(maskedRuntimeCredential(&masked, value.len), font_size, rel);
}

fn isModalWordChar(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_' or b == '-' or b == '.';
}

fn modalWordBoundsAt(value: []const u8, offset: usize) ModalSelectionRange {
    if (value.len == 0) return .{ .start = 0, .end = 0 };
    var start = @min(offset, value.len);
    var end = start;
    while (start > 0 and isModalWordChar(value[start - 1])) start -= 1;
    while (end < value.len and isModalWordChar(value[end])) end += 1;
    if (start == end and end < value.len) end += 1;
    return .{ .start = start, .end = end };
}

fn focusedValue(state: *runtime.AppState) []const u8 {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.renameInput(),
        .thread_import => state.threadImportThreadId(),
        .project_import_name => state.importProjectNameDraft(),
        .project_import => state.importDirectoryDraft(),
        .runtime_credential => state.runtimeCredentialToken(),
        .runtime_wizard_label => state.runtime_connections.fieldValue(.label),
        .runtime_wizard_host => state.runtime_connections.fieldValue(.host),
        .runtime_wizard_user => state.runtime_connections.fieldValue(.user),
        .runtime_wizard_ssh_port => state.runtime_connections.fieldValue(.ssh_port),
        .runtime_wizard_gateway_port => state.runtime_connections.fieldValue(.gateway_port),
        .runtime_wizard_grant_id => state.runtime_connections.fieldValue(.grant_id),
        .runtime_wizard_pairing_code => state.runtime_connections.fieldValue(.pairing_code),
        .runtime_wizard_device_label => state.runtime_connections.fieldValue(.device_label),
        .runtime_wizard_control_plane_url => state.runtime_connections.fieldValue(.control_plane_url),
        .command_palette => state.commandPaletteQuery(),
        .none => &[_]u8{},
    };
}

/// Removes the active selection from the focused modal buffer, returning true
/// if any bytes were deleted. Cursor is left at the selection's start and the
/// anchor is cleared.
fn deleteModalSelection(state: *runtime.AppState) bool {
    const value = focusedValue(state);
    const sel = modalSelectionRange(state, value) orelse return false;
    const buf = focusedBuffer(state) orelse return false;
    const cursor = focusedCursor(state) orelse return false;
    const current_len = std.mem.sliceTo(buf, 0).len;
    const removed = sel.end - sel.start;
    std.mem.copyForwards(u8, buf[sel.start .. current_len - removed], buf[sel.end..current_len]);
    if (isSecretModalFocus(state, state.palette_modal_text_focus)) {
        std.crypto.secureZero(u8, buf[current_len - removed .. current_len]);
    } else {
        buf[current_len - removed] = 0;
    }
    cursor.* = sel.start;
    clearModalSelection(state);
    return true;
}

fn copyModalSelection(state: *runtime.AppState) void {
    const value = focusedValue(state);
    const sel = modalSelectionRange(state, value) orelse return;
    const slice = value[sel.start..sel.end];
    if (slice.len == 0) return;
    const z = state.allocator.dupeZ(u8, slice) catch return;
    defer {
        if (isSecretModalFocus(state, state.palette_modal_text_focus)) {
            std.crypto.secureZero(u8, z);
        }
        state.allocator.free(z);
    }
    sdl.setClipboardText(z) catch |err| {
        runtime.log.warn("failed to copy modal selection: {s}", .{@errorName(err)});
    };
}

fn pasteIntoModal(state: *runtime.AppState) bool {
    if (state.palette_modal_text_focus == .runtime_credential) {
        return pasteIntoRuntimeCredential(state);
    }
    const text = state.readClipboardTextForPaste() orelse return false;
    const secret = isSecretModalFocus(state, state.palette_modal_text_focus);
    defer {
        if (secret) std.crypto.secureZero(u8, text);
        state.allocator.free(text);
    }
    if (text.len == 0) return false;
    // Wizard fields apply their own per-field filters (hex, digits, URL).
    if (runtime_connections.focusedWizardField(state.palette_modal_text_focus) != null) {
        return handlePaletteTextInput(state, text);
    }
    _ = deleteModalSelection(state);
    // Modal inputs are single-line; strip control chars from pasted text.
    var sanitized: [4096]u8 = undefined;
    var n: usize = 0;
    for (text) |b| {
        if (b == '\n' or b == '\r' or b == '\t') continue;
        if (n >= sanitized.len) break;
        sanitized[n] = b;
        n += 1;
    }
    if (n == 0) return false;
    const buf = focusedBuffer(state) orelse return false;
    const cursor = focusedCursor(state) orelse return false;
    _ = insertIntoZBuffer(buf, cursor, sanitized[0..n]);
    return true;
}

fn readRuntimeCredentialClipboard(state: *runtime.AppState) ?[]u8 {
    const clipboard_text = sdl.getClipboardText() catch |err| {
        runtime.log.warn("failed to read runtime credential clipboard text: {s}", .{@errorName(err)});
        return null;
    };
    const text = std.mem.span(clipboard_text);
    defer {
        std.crypto.secureZero(u8, @constCast(text));
        sdl.free(@ptrCast(clipboard_text));
    }
    const max_raw_bytes = state.runtimeCredentialTokenBuffer().len - 1;
    return state.allocator.dupe(u8, text[0..@min(text.len, max_raw_bytes)]) catch null;
}

fn insertRuntimeCredentialText(state: *runtime.AppState, text: []const u8) bool {
    var sanitized: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &sanitized);
    var len: usize = 0;
    for (text) |byte| {
        // Runtime bearer tokens are printable ASCII without spaces. Filtering
        // here keeps byte-wise caret and selection boundaries well-defined.
        if (byte < 0x21 or byte > 0x7e) continue;
        if (len >= sanitized.len) break;
        sanitized[len] = byte;
        len += 1;
    }
    if (len == 0) return true;
    _ = deleteModalSelection(state);
    return insertIntoZBuffer(
        state.runtimeCredentialTokenBuffer(),
        &state.runtime_credential_token_cursor,
        sanitized[0..len],
    );
}

fn pasteIntoRuntimeCredential(state: *runtime.AppState) bool {
    const text = readRuntimeCredentialClipboard(state) orelse return false;
    defer {
        std.crypto.secureZero(u8, text);
        state.allocator.free(text);
    }
    return insertRuntimeCredentialText(state, text);
}

fn moveModalCursorWithShift(state: *runtime.AppState, target: usize, shift: bool) bool {
    const cursor = focusedCursor(state) orelse return false;
    if (shift) {
        if (state.modal_text_selection_anchor == null) {
            state.modal_text_selection_anchor = cursor.*;
        }
    } else {
        clearModalSelection(state);
    }
    cursor.* = target;
    return true;
}

fn pointInRect(x: f32, y: f32, rect: palette.Rect) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    if (!down) {
        if (state.modal_text_drag_active) state.modal_text_drag_active = false;
        settings_modal.endBrowserScrollSpeedDrag(state);
    }
    if (state.palette_modal_hits.items.len == 0) return false;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (!pointInRect(x, y, hit.rect)) continue;
        if (hit.action == .project_import_browse) {
            runtime.log.info("workspace import browse hit down={} x={d:.1} y={d:.1}", .{ down, x, y });
            if (!down) state.requestBrowseForProjectDirectory();
            return true;
        }
        if (!down) return true;
        switch (hit.action) {
            .mcp_onboarding_not_now => state.completeMcpOnboarding(false),
            .mcp_onboarding_enable => state.completeMcpOnboarding(true),
            .provider_onboarding_close => state.dismissProviderOnboarding(),
            .provider_onboarding_recheck => state.recheckProviderReadiness(),
            .provider_onboarding_open_guide => state.openProviderSetupGuide(),
            .image_close => state.closeImageModal(),
            .image_zoom_out => state.adjustImageModalZoom(-1),
            .image_zoom_in => state.adjustImageModalZoom(1),
            .image_pan_canvas => state.beginImageModalPan(x, y),
            .project_rename_cancel => state.cancelProjectRename(),
            .project_rename_submit => state.finishProjectRename(),
            .transcript_close => state.closeTranscriptSelectionModal(),
            .thread_import_refresh => state.refreshThreadImportList(),
            .thread_import_cancel => state.cancelThreadImport(),
            .thread_import_submit => state.importSelectedThread(),
            .thread_import_select => state.selectThreadImport(hit.index),
            .handoff_cancel => state.cancelHandoff(),
            .handoff_prepare => state.prepareHandoffTarget(),
            .handoff_menu_toggle => handoff_sheet.toggleMenu(state, hit.index),
            .handoff_menu_option => handoff_sheet.applyMenuOption(state, hit.index),
            .handoff_menu_close => state.setHandoffMenu(null),
            .handoff_preview_toggle => state.toggleHandoffPreview(),
            .project_import_browse => unreachable,
            .project_import_submit => {
                state.importProjectFromInput() catch |err| {
                    runtime.log.warn("workspace import failed: {s}", .{@errorName(err)});
                    state.setSidebarNotice("Could not add that directory path.");
                };
            },
            .project_import_create_dir => {
                state.createProjectDirectoryFromInput() catch |err| {
                    runtime.log.warn("workspace directory creation failed: {s}", .{@errorName(err)});
                    state.setSidebarNotice("Could not create that directory path.");
                };
            },
            .project_import_cancel => state.cancelProjectImport(),
            .runtime_credential_cancel => state.cancelRuntimeCredentialModal(),
            .runtime_credential_submit => state.submitRuntimeCredential(),
            .runtime_credential_input => focusModalInput(state, .runtime_credential, hit.rect, x, clicks),
            .runtime_trust_cancel => state.cancelRuntimeTrust(),
            .runtime_trust_confirm => state.confirmRuntimeTrust(),
            .runtime_wizard_cancel => state.cancelRuntimeConnectionWizard(),
            .runtime_wizard_back => state.runtimeConnectionWizardBack(),
            .runtime_wizard_submit => state.submitRuntimeConnectionWizard(),
            .runtime_wizard_connect => state.runtimeConnectionWizardConnect(),
            .runtime_wizard_done => state.cancelRuntimeConnectionWizard(),
            .runtime_wizard_method => state.chooseRuntimeWizardMethod(@enumFromInt(@min(hit.index, @typeInfo(runtime_connections.WizardMethod).@"enum".fields.len - 1))),
            .runtime_wizard_select => state.selectRuntimeWizardConnectRuntime(hit.index),
            .runtime_wizard_input => focusModalInput(state, runtimeWizardFocusForIndex(hit.index), hit.rect, x, clicks),
            .settings_runtime_action => state.applyRuntimeRowAction(hit.index),
            .settings_cancel, .settings_close, .settings_save => state.closeSettingsPanel(),
            .settings_category => settings_modal.applySettingsCategory(state, hit.index),
            .settings_open_option => settings_modal.applyOpenActionOption(state, hit.index),
            .workspace_settings_close => state.closeWorkspaceSettings(),
            .workspace_settings_option => state.applyWorkspaceSettingsOption(hit.index),
            .workspace_settings_manage => state.openManageConnectionsFromWorkspaceSettings(),
            .workspace_settings_scroll_scope => state.applyWorkspaceSettingsScrollScope(hit.index != 0),
            .workspace_settings_scroll_mode => {
                const mode: app_config.WorkspaceScrollMode = switch (hit.index) {
                    0 => .automatic,
                    1 => .always,
                    else => .disabled,
                };
                state.applyWorkspaceSettingsScrollMode(mode);
            },
            .workspace_settings_scroll_threshold_dec => {
                const current = state.settings_controller.draft.workspace_scroll_threshold;
                if (current > app_config.MIN_WORKSPACE_SCROLL_THRESHOLD) {
                    state.applyWorkspaceSettingsScrollThreshold(current - 1);
                }
            },
            .workspace_settings_scroll_threshold_inc => {
                const current = state.settings_controller.draft.workspace_scroll_threshold;
                if (current < app_config.MAX_WORKSPACE_SCROLL_THRESHOLD) {
                    state.applyWorkspaceSettingsScrollThreshold(current + 1);
                }
            },
            .settings_control => settings_modal.applyControlAt(state, hit.index, hit.rect, x),
            .settings_theme_option => settings_modal.applyThemeOption(state, hit.index),
            .settings_title_provider_option => settings_modal.applyChatTitleProviderOption(state, hit.index),
            .settings_title_model_option => settings_modal.applyChatTitleModelOption(state, hit.index),
            .settings_new_chat_provider_option => settings_modal.applyNewChatProviderOption(state, hit.index),
            .settings_new_chat_model_option => settings_modal.applyNewChatModelOption(state, hit.index),
            .settings_new_chat_reasoning_option => settings_modal.applyNewChatReasoningOption(state, hit.index),
            .modal_dismiss => dismissTopModal(state),
            .modal_block => {
                blurModalTextInput(state);
                if (state.settings_controller.theme_dropdown_open) {
                    state.settings_controller.theme_dropdown_open = false;
                    state.settings_controller.theme_hover_index = null;
                    state.markDirty();
                }
                if (state.settings_controller.companion_character_dropdown_open) {
                    state.settings_controller.companion_character_dropdown_open = false;
                    state.settings_controller.companion_character_hover_index = null;
                    state.markDirty();
                }
                if (state.settings_controller.title_provider_dropdown_open or state.settings_controller.title_model_dropdown_open) {
                    state.settings_controller.title_provider_dropdown_open = false;
                    state.settings_controller.title_model_dropdown_open = false;
                    state.settings_controller.title_menu_hover_index = null;
                    state.markDirty();
                }
                if (state.settings_controller.new_chat_provider_dropdown_open or state.settings_controller.new_chat_model_dropdown_open or state.settings_controller.new_chat_reasoning_dropdown_open) {
                    state.settings_controller.new_chat_provider_dropdown_open = false;
                    state.settings_controller.new_chat_model_dropdown_open = false;
                    state.settings_controller.new_chat_reasoning_dropdown_open = false;
                    state.settings_controller.new_chat_menu_hover_index = null;
                    state.markDirty();
                }
                if (state.settings_controller.open_action_dropdown_open) {
                    state.settings_controller.open_action_dropdown_open = false;
                    state.settings_controller.open_action_hover_index = null;
                    state.markDirty();
                }
            },
            .project_rename_input => focusModalInput(state, .project_rename, hit.rect, x, clicks),
            .thread_import_input => focusModalInput(state, .thread_import, hit.rect, x, clicks),
            .project_import_name_input => focusModalInput(state, .project_import_name, hit.rect, x, clicks),
            .project_import_input => focusModalInput(state, .project_import, hit.rect, x, clicks),
            .command_palette_input => focusModalInput(state, .command_palette, hit.rect, x, clicks),
            .command_palette_row => command_palette.activateRow(state, hit.index, false),
            .command_palette_action_row => command_palette.runActionRow(state, hit.index),
        }
        return true;
    }
    return true;
}

/// Click into a modal text field: place the cursor at the click x, set the
/// selection anchor, and prime a drag. Double-click selects the word under
/// the pointer; triple-click selects all.
fn focusModalInput(state: *runtime.AppState, focus: runtime.PaletteModalTextFocus, rect: palette.Rect, x: f32, clicks: u8) void {
    if (state.palette_modal_text_focus != focus) {
        state.palette_modal_text_focus = focus;
        clearModalSelection(state);
    }
    const value = focusedValue(state);
    const font_size = theme.scaledUi(14.0);
    const text_x = rect.x + theme.scaledUi(10.0);
    const rel = @max(x - text_x, 0.0);
    const offset = focusedMetricOffsetForClickX(state, value, font_size, rel);
    const cursor = focusedCursor(state) orelse return;
    if (clicks >= 3) {
        state.modal_text_selection_anchor = 0;
        cursor.* = value.len;
        state.modal_text_drag_active = false;
    } else if (clicks == 2) {
        const bounds = modalWordBoundsAt(value, offset);
        state.modal_text_selection_anchor = bounds.start;
        cursor.* = bounds.end;
        state.modal_text_drag_active = false;
    } else {
        cursor.* = offset;
        state.modal_text_selection_anchor = offset;
        state.modal_text_drag_active = true;
    }
}

/// Routes modal pointer motion and reports whether the workspace is occluded.
pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32) bool {
    if (settings_modal.updateBrowserScrollSpeedDrag(state, x)) return true;
    if (state.updateImageModalPan(x, y)) return true;
    if (state.modal_text_drag_active and state.palette_modal_text_focus != .none) {
        const value = focusedValue(state);
        const rect = state.modal_text_input_rect;
        if (rect.w > 0.0) {
            const text_x = rect.x + theme.scaledUi(10.0);
            const rel = @max(x - text_x, 0.0);
            const offset = focusedMetricOffsetForClickX(state, value, state.modal_text_input_font_size, rel);
            if (focusedCursor(state)) |cursor| cursor.* = offset;
        }
    }
    return state.palette_modal_hits.items.len > 0;
}

/// True while any Palette modal owns pointer input for the window.
pub fn hasPaletteModal(state: *const runtime.AppState) bool {
    return state.palette_modal_hits.items.len > 0;
}

pub fn handlePaletteTextInput(state: *runtime.AppState, text: []const u8) bool {
    if (state.palette_modal_text_focus == .none) {
        // The trust modal intentionally has no editable field, and clicking
        // credential-modal chrome blurs its field. Both still own text input:
        // an SDL text_input paired with an already-consumed key-down must not
        // fall through into the obscured composer, browser, or terminal.
        // Workspace Settings has no editable field but likewise owns text
        // input while open.
        return state.runtimeCredentialModalOpen() or
            state.runtimeTrustProposal() != null or
            state.workspaceSettingsOpen();
    }
    if (state.palette_modal_text_focus == .runtime_credential) {
        return insertRuntimeCredentialText(state, text);
    }
    _ = deleteModalSelection(state);
    return switch (state.palette_modal_text_focus) {
        .project_rename => insertIntoZBuffer(state.renameBuffer(), &state.project_rename_cursor, text),
        .thread_import => insertIntoZBuffer(state.threadImportThreadIdBuffer(), &state.thread_import_cursor, text),
        .project_import_name => insertIntoZBuffer(state.importProjectNameBuffer(), &state.project_import_name_cursor, text),
        .project_import => insertIntoZBuffer(state.importPathBuffer(), &state.project_import_cursor, text),
        .runtime_credential => unreachable,
        .runtime_wizard_label, .runtime_wizard_host, .runtime_wizard_user, .runtime_wizard_device_label, .runtime_wizard_control_plane_url => blk: {
            // Single-line fields: strip control characters so a pasted
            // "host\n" cannot smuggle a line break into a profile.
            var sanitized: [runtime_connections.URL_CAPACITY]u8 = undefined;
            var len: usize = 0;
            for (text) |byte| {
                if (byte < 0x20 or byte == 0x7f) continue;
                if (len >= sanitized.len) break;
                sanitized[len] = byte;
                len += 1;
            }
            const field: runtime_connections.WizardField = switch (state.palette_modal_text_focus) {
                .runtime_wizard_label => .label,
                .runtime_wizard_host => .host,
                .runtime_wizard_device_label => .device_label,
                .runtime_wizard_control_plane_url => .control_plane_url,
                else => .user,
            };
            break :blk insertIntoZBuffer(state.runtime_connections.fieldBuffer(field), state.runtime_connections.fieldCursor(field), sanitized[0..len]);
        },
        .runtime_wizard_grant_id, .runtime_wizard_pairing_code => blk: {
            // Both values are canonical lowercase hex; fold case and drop
            // everything else so a copied "Grant: AB12…" pastes cleanly. The
            // scratch copy is zeroed because it may hold the pairing code.
            var hex: [runtime_connections.PAIRING_CODE_CAPACITY]u8 = undefined;
            defer std.crypto.secureZero(u8, &hex);
            var len: usize = 0;
            for (text) |byte| {
                const lower = std.ascii.toLower(byte);
                if (!std.ascii.isHex(lower)) continue;
                if (len >= hex.len) break;
                hex[len] = lower;
                len += 1;
            }
            const field: runtime_connections.WizardField = if (state.palette_modal_text_focus == .runtime_wizard_grant_id) .grant_id else .pairing_code;
            break :blk insertIntoZBuffer(state.runtime_connections.fieldBuffer(field), state.runtime_connections.fieldCursor(field), hex[0..len]);
        },
        .runtime_wizard_ssh_port, .runtime_wizard_gateway_port => blk: {
            var digits: [runtime_connections.PORT_CAPACITY]u8 = undefined;
            const filtered = runtime_connections.filterPortText(text, &digits);
            const field: runtime_connections.WizardField = if (state.palette_modal_text_focus == .runtime_wizard_ssh_port) .ssh_port else .gateway_port;
            break :blk insertIntoZBuffer(state.runtime_connections.fieldBuffer(field), state.runtime_connections.fieldCursor(field), filtered);
        },
        .command_palette => blk: {
            const inserted = insertIntoZBuffer(state.commandPaletteQueryBuffer(), &state.command_controller.cursor, text);
            state.markDirty();
            break :blk inserted;
        },
        .none => false,
    };
}

pub fn handlePaletteKeyDown(state: *runtime.AppState, event: *const sdl.KeyboardEvent) bool {
    const has_modal_open = state.runtimeCredentialModalOpen() or
        state.runtimeTrustProposal() != null or
        state.modal_image_path != null or
        state.settings_controller.mcp_onboarding_visible or
        state.settings_controller.provider_onboarding_visible or
        state.rename_project_index != null or
        state.transcriptSelectionBuffer() != null or
        state.thread_import_provider != null or
        state.handoff_controller.sheet_open or
        state.project_controller.show_creator or
        state.settings_controller.modal_visible or
        state.workspaceSettingsOpen() or
        state.runtime_connections.wizard_open or
        state.command_controller.open;
    if (!has_modal_open) return false;
    if (runtimeWizardOwnsKeys(state)) {
        switch (event.key) {
            .tab => {
                state.cycleRuntimeWizardField((keymodBits(event.mod) & sdl.Keymod.shift) != 0);
                state.markDirty();
                return true;
            },
            .@"return", .kp_enter => {
                switch (state.runtime_connections.wizard_step) {
                    .form, .pair_grant, .connect_setup => state.submitRuntimeConnectionWizard(),
                    // Enter obeys the same gate as the drawn middle button:
                    // with no recovery action it activates the visible Done
                    // control and never a hidden connect/pair path.
                    .testing => if (wizardTestingActionable(state))
                        state.runtimeConnectionWizardConnect()
                    else
                        state.cancelRuntimeConnectionWizard(),
                    // Identity confirmation and method choice need a click:
                    // a stray Enter must not adopt a runtime identity.
                    .method, .pair_confirm => {},
                }
                return true;
            },
            else => {},
        }
    }
    // Palette-owned navigation/activation keys; editing keys fall through to
    // the shared modal text path below.
    if (state.command_controller.open and command_palette.handleKeyDown(state, event)) return true;
    if (state.handoff_controller.sheet_open and handoff_sheet.handleKeyDown(state, event)) return true;
    if (state.settings_controller.modal_visible and settings_modal.handleKeyDown(state, event.key)) return true;
    // Workspace Settings keyboard ownership: it has no editable field, so
    // with no higher-priority modal above it Escape closes through the shared
    // dismiss path and every other key is consumed — Enter, Backspace, and
    // shortcuts must not fall through to the obscured composer, browser, or
    // terminal, and rows stay mouse-activated only.
    if (state.workspaceSettingsOpen() and
        !state.runtimeCredentialModalOpen() and
        state.runtimeTrustProposal() == null and
        !state.runtime_connections.wizard_open and
        !state.command_controller.open)
    {
        if (event.key == .escape) dismissTopModal(state);
        return true;
    }
    const primary = (keymodBits(event.mod) & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
    const shift = (keymodBits(event.mod) & sdl.Keymod.shift) != 0;
    switch (event.key) {
        .escape => {
            dismissTopModal(state);
            return true;
        },
        .@"return", .kp_enter => {
            if (state.runtimeCredentialModalOpen()) {
                state.submitRuntimeCredential();
                return true;
            }
            if (state.runtimeTrustProposal() != null) {
                // Trust appears asynchronously after a handshake. Do not let
                // an Enter intended for the obscured composer approve a new
                // identity; confirmation requires the explicit modal button.
                return true;
            }
            if (state.settings_controller.provider_onboarding_visible) {
                state.recheckProviderReadiness();
                return true;
            }
            if (state.settings_controller.mcp_onboarding_visible) {
                state.completeMcpOnboarding(true);
                return true;
            }
            if (state.palette_modal_text_focus == .project_rename) {
                state.finishProjectRename();
                return true;
            }
            if (state.palette_modal_text_focus == .thread_import) {
                state.importSelectedThread();
                return true;
            }
            if (state.palette_modal_text_focus == .project_import or state.palette_modal_text_focus == .project_import_name) {
                state.importProjectFromInput() catch |err| {
                    runtime.log.warn("workspace import failed: {s}", .{@errorName(err)});
                    state.setSidebarNotice("Could not add that directory path.");
                };
                return true;
            }
            if (state.handoff_controller.sheet_open) {
                // Enter always prepares with the current (default) choices,
                // even from inside an open select menu.
                state.setHandoffMenu(null);
                state.prepareHandoffTarget();
                return true;
            }
            return false;
        },
        .left => {
            if (state.palette_modal_text_focus == .none) return true;
            const cursor = focusedCursor(state) orelse return true;
            return moveModalCursorWithShift(state, cursor.* -| 1, shift);
        },
        .right => {
            if (state.palette_modal_text_focus == .none) return true;
            const cursor = focusedCursor(state) orelse return true;
            return moveModalCursorWithShift(state, @min(cursor.* + 1, focusedTextLen(state)), shift);
        },
        .home => {
            if (state.palette_modal_text_focus == .none) return true;
            return moveModalCursorWithShift(state, 0, shift);
        },
        .end => {
            if (state.palette_modal_text_focus == .none) return true;
            return moveModalCursorWithShift(state, focusedTextLen(state), shift);
        },
        .backspace => {
            if (state.palette_modal_text_focus != .none and deleteModalSelection(state)) return true;
            return deleteModalText(state, true);
        },
        .delete => {
            if (state.palette_modal_text_focus != .none and deleteModalSelection(state)) return true;
            return deleteModalText(state, false);
        },
        .a => {
            if (primary and state.palette_modal_text_focus != .none) {
                const cursor = focusedCursor(state) orelse return true;
                state.modal_text_selection_anchor = 0;
                cursor.* = focusedTextLen(state);
                return true;
            }
            return true;
        },
        .c => {
            if (primary and state.palette_modal_text_focus != .none) {
                copyModalSelection(state);
                return true;
            }
            if (state.transcriptSelectionBuffer()) |text| {
                if (primary) {
                    const clipboard_text = state.allocator.dupeZ(u8, text) catch return true;
                    defer state.allocator.free(clipboard_text);
                    sdl.setClipboardText(clipboard_text) catch |err| {
                        runtime.log.warn("failed to set transcript selection clipboard text: {s}", .{@errorName(err)});
                    };
                    return true;
                }
            }
            return false;
        },
        .x => {
            if (primary and state.palette_modal_text_focus != .none) {
                copyModalSelection(state);
                _ = deleteModalSelection(state);
                return true;
            }
            return true;
        },
        .v => {
            if (primary and state.palette_modal_text_focus != .none) {
                _ = pasteIntoModal(state);
                return true;
            }
            return true;
        },
        else => return true,
    }
}

fn dismissTopModal(state: *runtime.AppState) void {
    if (state.runtimeCredentialModalOpen()) {
        state.cancelRuntimeCredentialModal();
        return;
    }
    if (state.runtimeTrustProposal() != null) {
        state.cancelRuntimeTrust();
        return;
    }
    if (state.runtime_connections.wizard_open) {
        state.cancelRuntimeConnectionWizard();
        return;
    }
    if (state.command_controller.open) {
        state.closeCommandPalette();
        return;
    }
    if (state.settings_controller.provider_onboarding_visible) {
        state.dismissProviderOnboarding();
    } else if (state.settings_controller.mcp_onboarding_visible) {
        state.completeMcpOnboarding(false);
    } else if (state.modal_image_path != null) {
        state.closeImageModal();
    } else if (state.transcriptSelectionBuffer() != null) {
        state.closeTranscriptSelectionModal();
    } else if (state.project_controller.show_creator) {
        state.cancelProjectImport();
    } else if (state.rename_project_index != null) {
        state.cancelProjectRename();
    } else if (state.thread_import_provider != null) {
        state.cancelThreadImport();
    } else if (state.handoff_controller.sheet_open) {
        if (state.handoff_controller.menu != null) {
            state.setHandoffMenu(null);
        } else {
            state.cancelHandoff();
        }
    } else if (state.workspaceSettingsOpen()) {
        state.closeWorkspaceSettings();
    } else if (state.settings_controller.modal_visible) {
        state.cancelSettingsModal();
    }
    blurModalTextInput(state);
}

fn keymodBits(modifier_state: sdl.Keymod) u16 {
    return @as(*const u16, @ptrCast(&modifier_state)).*;
}

fn insertIntoZBuffer(buf: [:0]u8, cursor: *usize, text: []const u8) bool {
    const current = std.mem.sliceTo(buf, 0);
    if (text.len == 0 or current.len + text.len >= buf.len) return true;
    const at = @min(cursor.*, current.len);
    std.mem.copyBackwards(u8, buf[at + text.len .. current.len + text.len], buf[at..current.len]);
    @memcpy(buf[at .. at + text.len], text);
    buf[current.len + text.len] = 0;
    cursor.* = at + text.len;
    return true;
}

fn moveModalCursor(state: *runtime.AppState, delta: isize) bool {
    const cursor = focusedCursor(state) orelse return false;
    const len = focusedTextLen(state);
    if (delta < 0) {
        cursor.* -|= 1;
    } else {
        cursor.* = @min(cursor.* + 1, len);
    }
    return true;
}

fn moveModalCursorToEdge(state: *runtime.AppState, start: bool) bool {
    const cursor = focusedCursor(state) orelse return false;
    cursor.* = if (start) 0 else focusedTextLen(state);
    return true;
}

fn deleteModalText(state: *runtime.AppState, backwards: bool) bool {
    const cursor = focusedCursor(state) orelse return false;
    const buf = focusedBuffer(state) orelse return false;
    const len = std.mem.sliceTo(buf, 0).len;
    if (backwards) {
        if (cursor.* == 0 or len == 0) return true;
        const at = cursor.* - 1;
        std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
        if (isSecretModalFocus(state, state.palette_modal_text_focus)) {
            std.crypto.secureZero(u8, buf[len - 1 .. len]);
        } else {
            buf[len - 1] = 0;
        }
        cursor.* = at;
    } else {
        if (cursor.* >= len) return true;
        std.mem.copyForwards(u8, buf[cursor.* .. len - 1], buf[cursor.* + 1 .. len]);
        if (isSecretModalFocus(state, state.palette_modal_text_focus)) {
            std.crypto.secureZero(u8, buf[len - 1 .. len]);
        } else {
            buf[len - 1] = 0;
        }
    }
    return true;
}

fn focusedCursor(state: *runtime.AppState) ?*usize {
    return switch (state.palette_modal_text_focus) {
        .project_rename => &state.project_rename_cursor,
        .thread_import => &state.thread_import_cursor,
        .project_import_name => &state.project_import_name_cursor,
        .project_import => &state.project_import_cursor,
        .runtime_credential => &state.runtime_credential_token_cursor,
        .runtime_wizard_label => &state.runtime_connections.label_cursor,
        .runtime_wizard_host => &state.runtime_connections.host_cursor,
        .runtime_wizard_user => &state.runtime_connections.user_cursor,
        .runtime_wizard_ssh_port => &state.runtime_connections.ssh_port_cursor,
        .runtime_wizard_gateway_port => &state.runtime_connections.gateway_port_cursor,
        .runtime_wizard_grant_id => &state.runtime_connections.grant_id_cursor,
        .runtime_wizard_pairing_code => &state.runtime_connections.pairing_code_cursor,
        .runtime_wizard_device_label => &state.runtime_connections.device_label_cursor,
        .runtime_wizard_control_plane_url => &state.runtime_connections.control_plane_url_cursor,
        .command_palette => &state.command_controller.cursor,
        .none => null,
    };
}

fn focusedBuffer(state: *runtime.AppState) ?[:0]u8 {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.renameBuffer(),
        .thread_import => state.threadImportThreadIdBuffer(),
        .project_import_name => state.importProjectNameBuffer(),
        .project_import => state.importPathBuffer(),
        .runtime_credential => state.runtimeCredentialTokenBuffer(),
        .runtime_wizard_label => state.runtime_connections.fieldBuffer(.label),
        .runtime_wizard_host => state.runtime_connections.fieldBuffer(.host),
        .runtime_wizard_user => state.runtime_connections.fieldBuffer(.user),
        .runtime_wizard_ssh_port => state.runtime_connections.fieldBuffer(.ssh_port),
        .runtime_wizard_gateway_port => state.runtime_connections.fieldBuffer(.gateway_port),
        .runtime_wizard_grant_id => state.runtime_connections.fieldBuffer(.grant_id),
        .runtime_wizard_pairing_code => state.runtime_connections.fieldBuffer(.pairing_code),
        .runtime_wizard_device_label => state.runtime_connections.fieldBuffer(.device_label),
        .runtime_wizard_control_plane_url => state.runtime_connections.fieldBuffer(.control_plane_url),
        .command_palette => state.commandPaletteQueryBuffer(),
        .none => null,
    };
}

fn focusedTextLen(state: *runtime.AppState) usize {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.renameInput().len,
        .thread_import => state.threadImportThreadId().len,
        .project_import_name => state.importProjectNameDraft().len,
        .project_import => state.importDirectoryDraft().len,
        .runtime_credential => state.runtimeCredentialToken().len,
        .runtime_wizard_label => state.runtime_connections.fieldValue(.label).len,
        .runtime_wizard_host => state.runtime_connections.fieldValue(.host).len,
        .runtime_wizard_user => state.runtime_connections.fieldValue(.user).len,
        .runtime_wizard_ssh_port => state.runtime_connections.fieldValue(.ssh_port).len,
        .runtime_wizard_gateway_port => state.runtime_connections.fieldValue(.gateway_port).len,
        .runtime_wizard_grant_id => state.runtime_connections.fieldValue(.grant_id).len,
        .runtime_wizard_pairing_code => state.runtime_connections.fieldValue(.pairing_code).len,
        .runtime_wizard_device_label => state.runtime_connections.fieldValue(.device_label).len,
        .runtime_wizard_control_plane_url => state.runtime_connections.fieldValue(.control_plane_url).len,
        .command_palette => state.commandPaletteQuery().len,
        .none => 0,
    };
}

// ---------------------------------------------------------------------------
// Runtime connection wizard (SSH) — layered above the settings modal
// ---------------------------------------------------------------------------

const WizardField = runtime_connections.WizardField;

fn runtimeWizardFocusForIndex(index: usize) runtime.PaletteModalTextFocus {
    const field: WizardField = @enumFromInt(@min(index, @typeInfo(WizardField).@"enum".fields.len - 1));
    return switch (field) {
        .label => .runtime_wizard_label,
        .host => .runtime_wizard_host,
        .user => .runtime_wizard_user,
        .ssh_port => .runtime_wizard_ssh_port,
        .gateway_port => .runtime_wizard_gateway_port,
        .grant_id => .runtime_wizard_grant_id,
        .pairing_code => .runtime_wizard_pairing_code,
        .device_label => .runtime_wizard_device_label,
        .control_plane_url => .runtime_wizard_control_plane_url,
    };
}

/// Credential and trust modals stack above the wizard and keep their keys.
fn runtimeWizardOwnsKeys(state: *const runtime.AppState) bool {
    return state.runtime_connections.wizard_open and
        !state.runtimeCredentialModalOpen() and
        state.runtimeTrustProposal() == null and
        !state.command_controller.open;
}

/// Method cards on the chooser step.
const WIZARD_METHOD_COUNT: usize = @typeInfo(runtime_connections.WizardMethod).@"enum".fields.len;
/// Inventory rows shown on the Connect step before the list is clipped;
/// a count of hidden rows is rendered instead of a scroll surface.
const WIZARD_INVENTORY_VISIBLE_ROWS: usize = 5;

const WizardLayout = struct {
    modal: palette.Rect,
    pad: f32,
    content_w: f32,
    /// Indexed by `WizardField` ordinal; only the current step's fields are
    /// positioned meaningfully.
    fields: [@typeInfo(WizardField).@"enum".fields.len]palette.Rect,
    methods: [WIZARD_METHOD_COUNT]palette.Rect,
    inventory: [WIZARD_INVENTORY_VISIBLE_ROWS]palette.Rect,
    inventory_y: f32,
    /// Identity boxes on the pairing confirmation step.
    identity: [2]palette.Rect,
    notice_y: f32,
    buttons: [3]palette.Rect,
    status_y: f32,
};

fn runtimeWizardLayout(state: *const runtime.AppState, width: f32, height: f32) WizardLayout {
    const pad = theme.scaledUi(20.0);
    const modal_w = @min(theme.clampf(width * 0.44, theme.scaledUi(460.0), theme.scaledUi(640.0)), @max(width - pad * 2.0, theme.scaledUi(320.0)));
    const label_h = theme.scaledUi(18.0);
    const input_h = theme.scaledUi(36.0);
    const gap = theme.scaledUi(8.0);
    const row_gap = theme.scaledUi(12.0);
    const button_h = theme.scaledUi(36.0);
    const heading_h = theme.scaledUi(24.0);
    const sub_h = theme.scaledUi(20.0);
    // 56px cards give the title plus a one-line description room to breathe.
    const method_card_h = theme.scaledUi(56.0);
    const inventory_row_h = theme.scaledUi(44.0);
    const identity_box_h = theme.scaledUi(38.0);
    const rc = &state.runtime_connections;
    const step = rc.wizard_step;
    const field_row_h = label_h + input_h + row_gap;
    const status_block_h = theme.scaledUi(60.0);
    const inventory_rows = @min(rc.connect_runtimes.items.len, WIZARD_INVENTORY_VISIBLE_ROWS);
    const body_h: f32 = switch (step) {
        .method => @as(f32, @floatFromInt(WIZARD_METHOD_COUNT)) * (method_card_h + row_gap),
        .form => if (rc.wizard_method == .pair) 2.0 * field_row_h else 4.0 * field_row_h,
        .pair_grant => 3.0 * field_row_h,
        .pair_confirm => 2.0 * (label_h + identity_box_h + row_gap),
        .connect_setup => 2.0 * field_row_h + status_block_h + @as(f32, @floatFromInt(inventory_rows)) * (inventory_row_h + gap) + (if (rc.connect_runtimes_truncated > 0) sub_h else 0.0),
        .testing => status_block_h,
    };
    const modal_h = @min(pad + heading_h + gap + sub_h + row_gap + body_h + sub_h + row_gap + button_h + pad, height - pad * 2.0);
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    const content_w = modal.w - pad * 2.0;
    var layout: WizardLayout = undefined;
    layout.modal = modal;
    layout.pad = pad;
    layout.content_w = content_w;
    var y = modal.y + pad + heading_h + gap + sub_h + row_gap;
    layout.status_y = y;
    const x = modal.x + pad;
    for (&layout.fields) |*rect| rect.* = .{ .x = x, .y = y, .w = content_w, .h = input_h };
    for (&layout.methods, 0..) |*rect, index| {
        rect.* = .{ .x = x, .y = y + @as(f32, @floatFromInt(index)) * (method_card_h + row_gap), .w = content_w, .h = method_card_h };
    }
    switch (step) {
        .form => {
            if (rc.wizard_method == .pair) {
                for ([_]WizardField{ .label, .control_plane_url }) |field| {
                    layout.fields[@intFromEnum(field)] = .{ .x = x, .y = y + label_h, .w = content_w, .h = input_h };
                    y += field_row_h;
                }
            } else {
                for ([_]WizardField{ .label, .host, .user }) |field| {
                    layout.fields[@intFromEnum(field)] = .{ .x = x, .y = y + label_h, .w = content_w, .h = input_h };
                    y += field_row_h;
                }
                const half_w = (content_w - theme.scaledUi(10.0)) * 0.5;
                layout.fields[@intFromEnum(WizardField.ssh_port)] = .{ .x = x, .y = y + label_h, .w = half_w, .h = input_h };
                layout.fields[@intFromEnum(WizardField.gateway_port)] = .{ .x = x + half_w + theme.scaledUi(10.0), .y = y + label_h, .w = half_w, .h = input_h };
                y += field_row_h;
            }
        },
        .pair_grant => {
            const fields = [_]WizardField{ .grant_id, .pairing_code, .device_label };
            for (fields) |field| {
                layout.fields[@intFromEnum(field)] = .{ .x = x, .y = y + label_h, .w = content_w, .h = input_h };
                y += field_row_h;
            }
        },
        .pair_confirm => {
            for (&layout.identity) |*rect| {
                rect.* = .{ .x = x, .y = y + label_h, .w = content_w, .h = identity_box_h };
                y += label_h + identity_box_h + row_gap;
            }
        },
        .connect_setup => {
            const fields = [_]WizardField{ .label, .control_plane_url };
            for (fields) |field| {
                layout.fields[@intFromEnum(field)] = .{ .x = x, .y = y + label_h, .w = content_w, .h = input_h };
                y += field_row_h;
            }
            layout.status_y = y;
            y += status_block_h;
            layout.inventory_y = y;
            for (&layout.inventory) |*rect| {
                rect.* = .{ .x = x, .y = y, .w = content_w, .h = inventory_row_h };
                y += inventory_row_h + gap;
            }
            if (rc.connect_runtimes_truncated > 0) y += sub_h;
        },
        .method => y += body_h,
        .testing => y += status_block_h,
    }
    layout.notice_y = y;
    const button_y = modal.y + modal.h - pad - button_h;
    const button_gap = theme.scaledUi(10.0);
    const button_w = (content_w - button_gap * 2.0) / 3.0;
    for (0..3) |index| {
        layout.buttons[index] = .{ .x = x + @as(f32, @floatFromInt(index)) * (button_w + button_gap), .y = button_y, .w = button_w, .h = button_h };
    }
    return layout;
}

fn registerRuntimeWizardModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    const rc = &state.runtime_connections;
    if (!rc.wizard_open) return;
    const layout = runtimeWizardLayout(state, width, height);
    // Not dismissible from the scrim: a stray click must not lose the draft.
    registerModalChromeHits(state, width, height, layout.modal, false);
    for (rc.visibleFields()) |field| {
        queueModalHit(state, layout.fields[@intFromEnum(field)], .runtime_wizard_input, @intFromEnum(field));
    }
    switch (rc.wizard_step) {
        .method => {
            for (layout.methods, 0..) |rect, index| queueModalHit(state, rect, .runtime_wizard_method, index);
            queueModalHit(state, layout.buttons[0], .runtime_wizard_cancel, 0);
        },
        .form => {
            queueModalHit(state, layout.buttons[0], .runtime_wizard_cancel, 0);
            if (rc.wizard_mode == .add and rc.wizard_profile_id == null) queueModalHit(state, layout.buttons[1], .runtime_wizard_back, 0);
            queueModalHit(state, layout.buttons[2], .runtime_wizard_submit, 0);
        },
        .pair_grant => {
            queueModalHit(state, layout.buttons[0], .runtime_wizard_cancel, 0);
            queueModalHit(state, layout.buttons[1], .runtime_wizard_back, 0);
            if (!rc.pairing_exchange_started) queueModalHit(state, layout.buttons[2], .runtime_wizard_submit, 0);
        },
        .pair_confirm => {
            queueModalHit(state, layout.buttons[0], .runtime_wizard_cancel, 0);
            queueModalHit(state, layout.buttons[1], .runtime_wizard_connect, 0);
            queueModalHit(state, layout.buttons[2], .runtime_wizard_submit, 0);
        },
        .connect_setup => {
            const visible = @min(rc.connect_runtimes.items.len, WIZARD_INVENTORY_VISIBLE_ROWS);
            for (layout.inventory[0..visible], 0..) |rect, index| queueModalHit(state, rect, .runtime_wizard_select, index);
            queueModalHit(state, layout.buttons[0], .runtime_wizard_cancel, 0);
            if (rc.wizard_mode == .add and rc.wizard_profile_id == null) {
                queueModalHit(state, layout.buttons[1], .runtime_wizard_back, 0);
            } else if (connectSignedIn(rc.connect_phase)) {
                queueModalHit(state, layout.buttons[1], .runtime_wizard_connect, 0);
            }
            if (connectPrimaryEnabled(rc)) queueModalHit(state, layout.buttons[2], .runtime_wizard_submit, 0);
        },
        .testing => {
            queueModalHit(state, layout.buttons[0], .runtime_wizard_back, 0);
            // Same gate as the render path: no hit for a button that is not drawn.
            if (wizardTestingActionable(state)) queueModalHit(state, layout.buttons[1], .runtime_wizard_connect, 0);
            queueModalHit(state, layout.buttons[2], .runtime_wizard_done, 0);
        },
    }
}

/// Label of the testing-step middle button, or empty when the shared
/// recovery mapping has no action for the status. Trust review keeps its
/// wizard wording; everything else uses the mapping's own label so the
/// button never promises an action `recoverRuntimeProfile` will not run.
/// Single actionability gate for the testing step's middle control, shared by
/// render, pointer hit registration, and keyboard Enter.
fn wizardTestingActionable(state: *const runtime.AppState) bool {
    const profile_id = state.runtime_connections.wizard_profile_id orelse return false;
    return wizardTestingActionLabel(state.runtimeProfileStatus(profile_id)).len > 0;
}

fn wizardTestingActionLabel(status: runtime.RuntimePickerStatus) []const u8 {
    const recovery = runtime.runtimeStatusRecovery(status);
    return switch (recovery) {
        .none => "",
        .review_trust => "Verify…",
        else => runtime.runtimeRecoveryLabel(recovery, status),
    };
}

test "wizard testing step hides the middle button when recovery has no action" {
    try std.testing.expectEqualStrings("", wizardTestingActionLabel(.ready));
    try std.testing.expectEqualStrings("", wizardTestingActionLabel(.connecting));
    // A scheduled reconnect exposes the manual accelerator.
    try std.testing.expectEqualStrings("Retry now", wizardTestingActionLabel(.reconnecting));
    try std.testing.expectEqualStrings("", wizardTestingActionLabel(.unavailable));
    try std.testing.expectEqualStrings("Verify…", wizardTestingActionLabel(.trust_required));
    try std.testing.expectEqualStrings("Edit endpoint", wizardTestingActionLabel(.identity_mismatch));
    try std.testing.expectEqualStrings("Reconnect", wizardTestingActionLabel(.provider_not_authenticated));
    try std.testing.expectEqualStrings("Connect", wizardTestingActionLabel(.paired_offline));
}

fn connectSignedIn(phase: runtime_connections.ConnectPhase) bool {
    return phase == .signed_in or phase == .loading_inventory or phase == .inventory_loaded;
}

fn connectPrimaryEnabled(rc: *const runtime_connections.State) bool {
    return switch (rc.connect_phase) {
        .idle, .failed, .discovered => true,
        .inventory_loaded => rc.connect_selected != null,
        .signed_in => true,
        .discovering, .signing_in, .loading_inventory, .bootstrapping, .bootstrap_ready => false,
    };
}

fn connectPrimaryLabel(rc: *const runtime_connections.State) []const u8 {
    return switch (rc.connect_phase) {
        .idle => if (rc.wizard_profile_id == null) "Save & check" else "Check",
        .failed => "Retry",
        .discovering => "Checking…",
        .discovered => "Sign in",
        .signing_in => "Waiting for browser…",
        .signed_in, .loading_inventory => "Loading…",
        .inventory_loaded => "Use selected runtime",
        .bootstrapping => "Creating device…",
        .bootstrap_ready => "Finishing…",
    };
}

fn drawWizardField(state: *runtime.AppState, layout: WizardLayout, field: WizardField, label: []const u8, hint: []const u8) void {
    const rect = layout.fields[@intFromEnum(field)];
    queuePaletteText(state, .{ .x = rect.x, .y = rect.y - theme.scaledUi(18.0), .w = rect.w, .h = theme.scaledUi(16.0) }, label, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), layout.modal);
    const focus = runtimeWizardFocusForIndex(@intFromEnum(field));
    const value = state.runtime_connections.fieldValue(field);
    if (isSecretModalFocus(state, focus)) {
        // Same-length mask: pairing codes and an unimported one-paste Pair
        // link never enter a Palette batch or frame arena.
        var masked: [4096]u8 = undefined;
        drawTextField(state, rect, maskedRuntimeCredential(&masked, value.len), hint, state.palette_modal_text_focus == focus, state.runtime_connections.fieldCursor(field).*);
        return;
    }
    drawTextField(state, rect, value, hint, state.palette_modal_text_focus == focus, state.runtime_connections.fieldCursor(field).*);
}

/// Labelled read-only identity box (runtime id / instance id / SPKI).
fn drawWizardIdentityBox(state: *runtime.AppState, modal: palette.Rect, rect: palette.Rect, label: []const u8, value: []const u8) void {
    queuePaletteText(state, .{ .x = rect.x, .y = rect.y - theme.scaledUi(18.0), .w = rect.w, .h = theme.scaledUi(16.0) }, label, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), modal);
    queuePaletteRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(6.0));
    queuePaletteText(state, .{ .x = rect.x + theme.scaledUi(10.0), .y = rect.y + theme.scaledUi(9.0), .w = rect.w - theme.scaledUi(20.0), .h = theme.scaledUi(20.0) }, value, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), modal);
}

// Renders the add/edit runtime connection wizard: SSH form, then a connect
// step that shows the live verification state of the saved profile.
fn renderRuntimeWizardModal(state: *runtime.AppState, width: f32, height: f32) void {
    const rc = &state.runtime_connections;
    if (!rc.wizard_open) return;
    const layout = runtimeWizardLayout(state, width, height);
    const modal = layout.modal;
    drawModalChromeVisual(state, width, height, modal);
    const pad = layout.pad;
    const heading = switch (rc.wizard_step) {
        .method => "Add connection",
        .pair_grant => "Pair this device",
        .pair_confirm => "Confirm the runtime identity",
        else => switch (rc.wizard_mode) {
            .add => "Add runtime connection",
            .edit => "Edit runtime connection",
        },
    };
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + pad, .w = layout.content_w, .h = theme.scaledUi(24.0) }, heading, paletteColor(theme.COLOR_WHITE), theme.scaledUi(18.0), modal);
    const subtitle = switch (rc.wizard_step) {
        .method => "Choose how this desktop reaches the runtime. Only Connect needs an account.",
        .form => if (rc.wizard_method == .pair)
            "Paste the complete Pair link once. HTTPS and runtime identity are verified before trust is saved."
        else
            "Reach a self-hosted Verde daemon over SSH. Host keys are verified by OpenSSH; no secrets are stored here.",
        .pair_grant => "Advanced manual fallback: review or enter the grant ID and masked one-time code, then exchange.",
        .pair_confirm => "The runtime answered the exchange. Verify both IDs against `verde-daemon identity` before trusting it.",
        .connect_setup => "Enter your self-hosted Verde Connect URL. Sign-in uses the system browser with PKCE; tokens stay in memory.",
        .testing => switch (rc.wizard_method) {
            .ssh => "Connect to verify the daemon identity. You will be asked for the gateway token and to confirm the runtime on first contact.",
            .pair => "Connect uses the paired device credential; no token prompt is needed.",
            .connect => "Connect uses the runtime-local device credential; OIDC is needed only to select or re-bootstrap.",
        },
    };
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + pad + theme.scaledUi(32.0), .w = layout.content_w, .h = theme.scaledUi(20.0) }, subtitle, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.5), modal);

    switch (rc.wizard_step) {
        .method => {
            for (layout.methods, 0..) |rect, index| {
                const method: runtime_connections.WizardMethod = @enumFromInt(index);
                const hovered = pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, rect);
                queuePaletteRoundedRect(state, rect, paletteColor(if (hovered) theme.lighten(theme.COLOR_PANEL_ALT, 0.055) else theme.COLOR_PANEL_ALT), theme.scaledUi(7.0));
                queuePaletteBorder(state, rect, paletteColor(if (hovered) theme.accent() else theme.COLOR_PANEL_MUTED), theme.scaledUi(7.0), theme.scaledUi(1.0));
                queuePaletteText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = rect.y + theme.scaledUi(8.0), .w = rect.w - theme.scaledUi(24.0), .h = theme.scaledUi(20.0) }, method.title(), paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), rect);
                queuePaletteText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = rect.y + theme.scaledUi(30.0), .w = rect.w - theme.scaledUi(24.0), .h = theme.scaledUi(18.0) }, method.description(), paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), rect);
            }
            drawActionButton(state, layout.buttons[0], "Cancel", theme.COLOR_PANEL_ALT);
        },
        .form => {
            drawWizardField(state, layout, .label, "NAME", "Build VM");
            if (rc.wizard_method == .pair) {
                drawWizardField(state, layout, .control_plane_url, if (rc.wizard_mode == .add) "PAIR LINK (MASKED)" else "DIRECT HTTPS / TAILSCALE SERVE URL", if (rc.wizard_mode == .add) "verde://pair?host=…&grant_id=…#code=…" else "https://runtime.example");
            } else {
                drawWizardField(state, layout, .host, "SSH HOST OR CONFIG ALIAS", "runtime.example or my-vm");
                drawWizardField(state, layout, .user, "SSH USER (OPTIONAL)", "leave empty to use ~/.ssh/config");
                drawWizardField(state, layout, .ssh_port, "SSH PORT", "22");
                drawWizardField(state, layout, .gateway_port, "GATEWAY PORT ON HOST", "7420");
            }
            drawActionButton(state, layout.buttons[0], "Cancel", theme.COLOR_PANEL_ALT);
            if (rc.wizard_mode == .add and rc.wizard_profile_id == null) drawActionButton(state, layout.buttons[1], "Back", theme.COLOR_PANEL_ALT);
            drawActionButton(state, layout.buttons[2], if (rc.wizard_mode == .add) "Save & continue" else "Save", theme.accent());
        },
        .pair_grant => {
            drawWizardField(state, layout, .grant_id, "GRANT ID", "32 hex characters");
            drawWizardField(state, layout, .pairing_code, "ONE-TIME PAIRING CODE", "64 hex characters, masked");
            drawWizardField(state, layout, .device_label, "DEVICE LABEL", "e.g. work laptop");
            drawActionButton(state, layout.buttons[0], "Cancel", theme.COLOR_PANEL_ALT);
            drawActionButton(state, layout.buttons[1], "Back", theme.COLOR_PANEL_ALT);
            drawActionButton(state, layout.buttons[2], if (rc.pairing_exchange_started) "Exchanging…" else "Exchange grant", theme.accent());
        },
        .pair_confirm => {
            var runtime_id: []const u8 = "";
            var instance_id: []const u8 = "";
            if (state.runtime_service) |service| if (rc.wizard_profile_id) |profile_id| if (service.pairingResult(profile_id)) |result| {
                runtime_id = result.runtime_id;
                instance_id = result.instance_id;
            };
            drawWizardIdentityBox(state, modal, layout.identity[0], "RUNTIME ID", runtime_id);
            drawWizardIdentityBox(state, modal, layout.identity[1], "INSTANCE ID", instance_id);
            drawActionButton(state, layout.buttons[0], "Cancel", theme.COLOR_PANEL_ALT);
            drawActionButton(state, layout.buttons[1], "Not this runtime", theme.COLOR_PANEL_ALT);
            drawActionButton(state, layout.buttons[2], "Trust and pair", theme.accent());
        },
        .connect_setup => {
            drawWizardField(state, layout, .label, "NAME", "Team control plane");
            drawWizardField(state, layout, .control_plane_url, "CONTROL PLANE URL", "https://connect.example");
            const status: []const u8 = if (rc.connect_failure) |failure| failure.message() else switch (rc.connect_phase) {
                .idle => "Not checked yet.",
                .discovering => "Fetching /.well-known/verde-connect-configuration…",
                .discovered => "Discovery verified. Signed out.",
                .signing_in => if (rc.connect_login_open) "Browser opened. Finish sign-in there; this window waits for the loopback redirect." else "Starting sign-in…",
                .signed_in, .loading_inventory => "Signed in. Loading linked runtimes…",
                .inventory_loaded => "Signed in.",
                .bootstrapping => "Creating the runtime-local device credential…",
                .bootstrap_ready => "Runtime bootstrap complete.",
                .failed => "Failed.",
            };
            const status_color = if (rc.connect_failure != null) theme.danger() else if (connectSignedIn(rc.connect_phase)) theme.success() else theme.COLOR_TEXT_MUTED;
            queuePaletteText(state, .{ .x = modal.x + pad, .y = layout.status_y, .w = layout.content_w, .h = theme.scaledUi(20.0) }, status, paletteColor(status_color), theme.scaledUi(13.0), modal);
            var issuer_buf: [runtime_connections.URL_CAPACITY + 32]u8 = undefined;
            const issuer_line: []const u8 = if (rc.connect_issuer) |issuer|
                std.fmt.bufPrint(&issuer_buf, "Issuer {s}{s}", .{ issuer, if (rc.connect_device_flow_advertised) " · device flow advertised" else "" }) catch issuer
            else
                "";
            queuePaletteText(state, .{ .x = modal.x + pad, .y = layout.status_y + theme.scaledUi(24.0), .w = layout.content_w, .h = theme.scaledUi(18.0) }, issuer_line, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), modal);
            const visible = @min(rc.connect_runtimes.items.len, WIZARD_INVENTORY_VISIBLE_ROWS);
            for (rc.connect_runtimes.items[0..visible], 0..) |row, index| {
                const rect = layout.inventory[index];
                const selected = rc.connect_selected == index;
                queuePaletteRoundedRect(state, rect, paletteColor(if (selected) theme.lighten(theme.COLOR_PANEL_ALT, 0.08) else theme.COLOR_PANEL_ALT), theme.scaledUi(7.0));
                queuePaletteBorder(state, rect, paletteColor(if (selected) theme.accent() else theme.COLOR_PANEL_MUTED), theme.scaledUi(7.0), theme.scaledUi(if (selected) 1.5 else 1.0));
                queuePaletteText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = rect.y + theme.scaledUi(6.0), .w = rect.w - theme.scaledUi(24.0), .h = theme.scaledUi(18.0) }, row.https_url, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), rect);
                var id_buf: [256]u8 = undefined;
                const id_line = std.fmt.bufPrint(&id_buf, "runtime {s} · instance {s} · spki {s}", .{ row.runtime_id, row.instance_id, row.spki_sha256 }) catch row.runtime_id;
                queuePaletteText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = rect.y + theme.scaledUi(24.0), .w = rect.w - theme.scaledUi(24.0), .h = theme.scaledUi(16.0) }, id_line, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), rect);
            }
            const hidden = rc.connect_runtimes.items.len - visible + rc.connect_runtimes_truncated;
            if (hidden > 0) {
                var more_buf: [64]u8 = undefined;
                const more = std.fmt.bufPrint(&more_buf, "{d} more linked runtime(s) not shown", .{hidden}) catch "";
                queuePaletteText(state, .{ .x = modal.x + pad, .y = layout.inventory_y + @as(f32, @floatFromInt(visible)) * (theme.scaledUi(44.0) + theme.scaledUi(8.0)), .w = layout.content_w, .h = theme.scaledUi(18.0) }, more, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), modal);
            }
            drawActionButton(state, layout.buttons[0], "Cancel", theme.COLOR_PANEL_ALT);
            if (rc.wizard_mode == .add and rc.wizard_profile_id == null) {
                drawActionButton(state, layout.buttons[1], "Back", theme.COLOR_PANEL_ALT);
            } else if (connectSignedIn(rc.connect_phase)) {
                drawActionButton(state, layout.buttons[1], "Sign out", theme.COLOR_PANEL_ALT);
            }
            drawActionButton(state, layout.buttons[2], connectPrimaryLabel(rc), if (connectPrimaryEnabled(rc)) theme.accent() else theme.COLOR_PANEL_MUTED);
        },
        .testing => {
            var badge: []const u8 = "Saved";
            var description: []const u8 = "";
            var badge_color = theme.COLOR_TEXT_MUTED;
            // The middle button mirrors `recoverRuntimeProfile`: label and
            // action come from one mapping, and no button is drawn when the
            // mapping has nothing to do (connected/connecting) so a no-op
            // accent control never appears.
            var connect_label: []const u8 = "";
            if (rc.wizard_profile_id) |profile_id| {
                const status = state.runtimeProfileStatus(profile_id);
                badge = runtime.runtimePickerStatusBadge(status);
                description = runtime.runtimePickerStatusDescription(status);
                badge_color = runtime.runtimeStatusTone(status).color();
                connect_label = wizardTestingActionLabel(status);
            }
            queuePaletteText(state, .{ .x = modal.x + pad, .y = layout.status_y, .w = layout.content_w, .h = theme.scaledUi(22.0) }, badge, paletteColor(badge_color), theme.scaledUi(15.0), modal);
            queuePaletteText(state, .{ .x = modal.x + pad, .y = layout.status_y + theme.scaledUi(26.0), .w = layout.content_w, .h = theme.scaledUi(20.0) }, description, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.5), modal);
            drawActionButton(state, layout.buttons[0], "Edit", theme.COLOR_PANEL_ALT);
            if (connect_label.len > 0) drawActionButton(state, layout.buttons[1], connect_label, theme.accent());
            drawActionButton(state, layout.buttons[2], "Done", theme.COLOR_PANEL_ALT);
        },
    }
    const notice = rc.wizardNotice();
    if (notice.len > 0) {
        queuePaletteText(state, .{ .x = modal.x + pad, .y = layout.notice_y, .w = layout.content_w, .h = theme.scaledUi(20.0) }, notice, paletteColor(theme.COLOR_YELLOW), theme.scaledUi(12.5), modal);
    }
}

fn runtimeCredentialModalRect(width: f32, height: f32) palette.Rect {
    const modal_w = theme.clampf(width * 0.40, theme.scaledUi(420.0), theme.scaledUi(560.0));
    const modal_h = theme.scaledUi(284.0);
    return .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
}

fn runtimeTrustModalRect(width: f32, height: f32) palette.Rect {
    const modal_w = theme.clampf(width * 0.48, theme.scaledUi(520.0), theme.scaledUi(680.0));
    const modal_h = theme.scaledUi(366.0);
    return .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
}

fn registerRuntimeCredentialModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.runtimeCredentialModalOpen()) return;
    const modal = runtimeCredentialModalRect(width, height);
    registerModalChromeHits(state, width, height, modal, false);
    const pad = theme.scaledUi(20.0);
    const input_rect: palette.Rect = .{
        .x = modal.x + pad,
        .y = modal.y + theme.scaledUi(132.0),
        .w = modal.w - pad * 2.0,
        .h = theme.scaledUi(36.0),
    };
    const gap = theme.scaledUi(10.0);
    const button_h = theme.scaledUi(36.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const button_y = modal.y + modal.h - pad - button_h;
    queueModalHit(state, input_rect, .runtime_credential_input, 0);
    queueModalHit(state, .{ .x = input_rect.x, .y = button_y, .w = button_w, .h = button_h }, .runtime_credential_cancel, 0);
    queueModalHit(state, .{ .x = input_rect.x + button_w + gap, .y = button_y, .w = button_w, .h = button_h }, .runtime_credential_submit, 0);
}

fn registerRuntimeTrustModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (state.runtimeTrustProposal() == null) return;
    const modal = runtimeTrustModalRect(width, height);
    registerModalChromeHits(state, width, height, modal, false);
    const pad = theme.scaledUi(20.0);
    const gap = theme.scaledUi(10.0);
    const button_h = theme.scaledUi(36.0);
    const content_w = modal.w - pad * 2.0;
    const button_w = (content_w - gap) * 0.5;
    const button_y = modal.y + modal.h - pad - button_h;
    queueModalHit(state, .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h }, .runtime_trust_cancel, 0);
    queueModalHit(state, .{ .x = modal.x + pad + button_w + gap, .y = button_y, .w = button_w, .h = button_h }, .runtime_trust_confirm, 0);
}

// Renders the masked, process-memory-only runtime bearer entry modal.
fn renderRuntimeCredentialModal(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.runtimeCredentialModalOpen()) return;
    const modal = runtimeCredentialModalRect(width, height);
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(20.0);
    const content_w = modal.w - pad * 2.0;
    var heading_buf: [192]u8 = undefined;
    const heading = std.fmt.bufPrint(
        &heading_buf,
        "Connect to {s}",
        .{state.runtimeCredentialProfileLabel()},
    ) catch "Connect to remote runtime";
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + pad, .w = content_w, .h = theme.scaledUi(24.0) }, heading, paletteColor(theme.COLOR_WHITE), theme.scaledUi(18.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(54.0), .w = content_w, .h = theme.scaledUi(20.0) }, "Enter the gateway bearer token for this daemon.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(76.0), .w = content_w, .h = theme.scaledUi(20.0) }, "Memory-only: never saved, logged, or put in SSH argv/environment.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.5), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(104.0), .w = content_w, .h = theme.scaledUi(18.0) }, "BEARER TOKEN", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), modal);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(132.0), .w = content_w, .h = theme.scaledUi(36.0) };
    drawRuntimeCredentialField(state, input_rect);
    const notice = state.runtimeCredentialNotice();
    if (notice.len > 0) {
        queuePaletteText(state, .{ .x = modal.x + pad, .y = input_rect.y + theme.scaledUi(44.0), .w = content_w, .h = theme.scaledUi(20.0) }, notice, paletteColor(theme.COLOR_YELLOW), theme.scaledUi(12.5), modal);
    }
    const gap = theme.scaledUi(10.0);
    const button_h = theme.scaledUi(36.0);
    const button_w = (content_w - gap) * 0.5;
    const button_y = modal.y + modal.h - pad - button_h;
    drawActionButton(state, .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h }, "Cancel", theme.COLOR_PANEL_ALT);
    drawActionButton(state, .{ .x = modal.x + pad + button_w + gap, .y = button_y, .w = button_w, .h = button_h }, "Connect", theme.accent());
}

// Renders the explicit first-contact daemon identity confirmation modal.
fn renderRuntimeTrustModal(state: *runtime.AppState, width: f32, height: f32) void {
    const proposal = state.runtimeTrustProposal() orelse return;
    const modal = runtimeTrustModalRect(width, height);
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(20.0);
    const content_w = modal.w - pad * 2.0;
    var heading_buf: [192]u8 = undefined;
    const heading = std.fmt.bufPrint(
        &heading_buf,
        "Trust {s}?",
        .{state.runtimeTrustProfileLabel()},
    ) catch "Trust remote runtime?";
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + pad, .w = content_w, .h = theme.scaledUi(24.0) }, heading, paletteColor(theme.COLOR_WHITE), theme.scaledUi(18.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(54.0), .w = content_w, .h = theme.scaledUi(20.0) }, "First contact is blocked until you verify both complete IDs.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(76.0), .w = content_w, .h = theme.scaledUi(20.0) }, "Compare them with the daemon output on the remote machine.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.5), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(112.0), .w = content_w, .h = theme.scaledUi(18.0) }, "RUNTIME ID", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), modal);
    queuePaletteRoundedRect(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(134.0), .w = content_w, .h = theme.scaledUi(38.0) }, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(6.0));
    queuePaletteText(state, .{ .x = modal.x + pad + theme.scaledUi(10.0), .y = modal.y + theme.scaledUi(143.0), .w = content_w - theme.scaledUi(20.0), .h = theme.scaledUi(20.0) }, proposal.runtime_id, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(188.0), .w = content_w, .h = theme.scaledUi(18.0) }, "INSTANCE ID", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), modal);
    queuePaletteRoundedRect(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(210.0), .w = content_w, .h = theme.scaledUi(38.0) }, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(6.0));
    queuePaletteText(state, .{ .x = modal.x + pad + theme.scaledUi(10.0), .y = modal.y + theme.scaledUi(219.0), .w = content_w - theme.scaledUi(20.0), .h = theme.scaledUi(20.0) }, proposal.instance_id, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), modal);
    const notice = state.runtimeTrustNotice();
    if (notice.len > 0) {
        queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(258.0), .w = content_w, .h = theme.scaledUi(20.0) }, notice, paletteColor(theme.COLOR_YELLOW), theme.scaledUi(12.5), modal);
    }
    const gap = theme.scaledUi(10.0);
    const button_h = theme.scaledUi(36.0);
    const button_w = (content_w - gap) * 0.5;
    const button_y = modal.y + modal.h - pad - button_h;
    drawActionButton(state, .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h }, "Cancel and disconnect", theme.COLOR_PANEL_ALT);
    drawActionButton(state, .{ .x = modal.x + pad + button_w + gap, .y = button_y, .w = button_w, .h = button_h }, "Trust this daemon", theme.accent());
}

fn registerImageModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (state.modal_image_path == null) return;
    const modal_padding_x: f32 = 22.0;
    const modal_padding_y: f32 = 20.0;
    const modal_width = @min(width * 0.78, 980.0);
    const modal_height = @min(height * 0.82, 760.0);
    const modal: palette.Rect = .{ .x = (width - modal_width) * 0.5, .y = (height - modal_height) * 0.5, .w = modal_width, .h = modal_height };
    registerModalChromeHits(state, width, height, modal, true);
    const content: palette.Rect = .{ .x = modal.x + modal_padding_x, .y = modal.y + modal_padding_y, .w = modal.w - modal_padding_x * 2.0, .h = modal.h - modal_padding_y * 2.0 };
    const close_size: f32 = 28.0;
    const close_rect: palette.Rect = .{ .x = content.x + content.w - close_size, .y = content.y, .w = close_size, .h = close_size };
    queueModalHit(state, close_rect, .image_close, 0);
    const zoom_gap = theme.scaledUi(6.0);
    const zoom_label_w = theme.scaledUi(54.0);
    const zoom_out_rect: palette.Rect = .{
        .x = close_rect.x - 12.0 - close_size * 2.0 - zoom_label_w - zoom_gap * 2.0,
        .y = content.y,
        .w = close_size,
        .h = close_size,
    };
    const zoom_in_rect: palette.Rect = .{
        .x = zoom_out_rect.x + close_size + zoom_gap + zoom_label_w + zoom_gap,
        .y = content.y,
        .w = close_size,
        .h = close_size,
    };
    queueModalHit(state, zoom_out_rect, .image_zoom_out, 0);
    queueModalHit(state, zoom_in_rect, .image_zoom_in, 0);
    if (state.modal_image_zoom > 1.0) {
        queueModalHit(state, imageModalCanvasRect(width, height), .image_pan_canvas, 0);
    }
}

fn imageModalCanvasRect(width: f32, height: f32) palette.Rect {
    const modal_padding_x: f32 = 22.0;
    const modal_padding_y: f32 = 20.0;
    const modal_width = @min(width * 0.78, 980.0);
    const modal_height = @min(height * 0.82, 760.0);
    const modal: palette.Rect = .{ .x = (width - modal_width) * 0.5, .y = (height - modal_height) * 0.5, .w = modal_width, .h = modal_height };
    const content: palette.Rect = .{ .x = modal.x + modal_padding_x, .y = modal.y + modal_padding_y, .w = modal.w - modal_padding_x * 2.0, .h = modal.h - modal_padding_y * 2.0 };
    return .{ .x = content.x, .y = content.y + theme.scaledUi(62.0), .w = content.w, .h = content.h - theme.scaledUi(62.0) };
}

fn registerTranscriptSelectionModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (state.transcriptSelectionBuffer() == null) return;
    const modal: palette.Rect = .{ .x = (width - @min(width * 0.76, theme.scaledUi(980.0))) * 0.5, .y = (height - @min(height * 0.8, theme.scaledUi(760.0))) * 0.5, .w = @min(width * 0.76, theme.scaledUi(980.0)), .h = @min(height * 0.8, theme.scaledUi(760.0)) };
    registerModalChromeHits(state, width, height, modal, true);
    const pad = theme.scaledUi(18.0);
    const close_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + modal.h - pad - theme.scaledUi(34.0), .w = theme.scaledUi(112.0), .h = theme.scaledUi(34.0) };
    queueModalHit(state, close_rect, .transcript_close, 0);
}

fn providerOnboardingRect(width: f32, height: f32) palette.Rect {
    const modal_w = theme.clampf(width * 0.54, theme.scaledUi(540.0), theme.scaledUi(720.0));
    const modal_h = theme.clampf(height * 0.78, theme.scaledUi(500.0), theme.scaledUi(620.0));
    return .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
}

fn registerProviderOnboardingHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.settings_controller.provider_onboarding_visible) return;
    const modal = providerOnboardingRect(width, height);
    registerModalChromeHits(state, width, height, modal, false);
    const pad = theme.scaledUi(22.0);
    const button_h = theme.scaledUi(36.0);
    const gap = theme.scaledUi(10.0);
    const close_w = theme.scaledUi(104.0);
    const guide_w = theme.scaledUi(156.0);
    const check_w = theme.scaledUi(126.0);
    const button_y = modal.y + modal.h - pad - button_h;
    queueModalHit(state, .{ .x = modal.x + pad, .y = button_y, .w = close_w, .h = button_h }, .provider_onboarding_close, 0);
    queueModalHit(state, .{ .x = modal.x + modal.w - pad - check_w, .y = button_y, .w = check_w, .h = button_h }, .provider_onboarding_recheck, 0);
    queueModalHit(state, .{ .x = modal.x + modal.w - pad - check_w - gap - guide_w, .y = button_y, .w = guide_w, .h = button_h }, .provider_onboarding_open_guide, 0);
}

fn mcpOnboardingRect(width: f32, height: f32) palette.Rect {
    const modal_w = theme.clampf(width * 0.5, theme.scaledUi(520.0), theme.scaledUi(680.0));
    const modal_h = theme.clampf(height * 0.56, theme.scaledUi(400.0), theme.scaledUi(440.0));
    return .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
}

fn registerMcpOnboardingHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.settings_controller.mcp_onboarding_visible or state.settings_controller.provider_onboarding_visible) return;
    const modal = mcpOnboardingRect(width, height);
    registerModalChromeHits(state, width, height, modal, false);
    const pad = theme.scaledUi(22.0);
    const button_h = theme.scaledUi(36.0);
    const skip_w = theme.scaledUi(104.0);
    const enable_w = theme.scaledUi(176.0);
    const button_y = modal.y + modal.h - pad - button_h;
    queueModalHit(state, .{ .x = modal.x + pad, .y = button_y, .w = skip_w, .h = button_h }, .mcp_onboarding_not_now, 0);
    queueModalHit(state, .{ .x = modal.x + modal.w - pad - enable_w, .y = button_y, .w = enable_w, .h = button_h }, .mcp_onboarding_enable, 0);
}

fn registerWorkspaceAddModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.project_controller.show_creator) return;
    const modal_w = theme.clampf(width * 0.34, theme.scaledUi(360.0), theme.scaledUi(500.0));
    const notice_h: f32 = if (state.projectImportNotice().len > 0) theme.scaledUi(24.0) else 0.0;
    const modal_h = theme.scaledUi(320.0) + notice_h;
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    registerModalChromeHits(state, width, height, modal, false);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    y += theme.scaledUi(30.0);
    y += theme.scaledUi(72.0);
    const name_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    queueModalHit(state, name_rect, .project_import_name_input, 0);
    y += theme.scaledUi(44.0);
    const button_gap = theme.scaledUi(10.0);
    const browse_w = (modal.w - pad * 2.0 - button_gap) * 0.5;
    const browse_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = browse_w, .h = theme.scaledUi(36.0) };
    const create_rect: palette.Rect = .{ .x = browse_rect.x + browse_rect.w + button_gap, .y = y, .w = browse_w, .h = browse_rect.h };
    queueModalHit(state, browse_rect, .project_import_browse, 0);
    queueModalHit(state, create_rect, .project_import_create_dir, 0);
    y += theme.scaledUi(44.0);
    const add_w = theme.scaledUi(92.0);
    const row_gap = theme.scaledUi(10.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0 - add_w - row_gap, .h = theme.scaledUi(34.0) };
    const add_rect: palette.Rect = .{ .x = input_rect.x + input_rect.w + row_gap, .y = y, .w = add_w, .h = theme.scaledUi(34.0) };
    queueModalHit(state, input_rect, .project_import_input, 0);
    queueModalHit(state, add_rect, .project_import_submit, 0);
    y += theme.scaledUi(46.0);
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = theme.scaledUi(120.0), .h = theme.scaledUi(34.0) };
    queueModalHit(state, cancel_rect, .project_import_cancel, 0);
}

fn registerWorkspaceRenameModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    const rename_index = state.rename_project_index orelse return;
    if (rename_index >= state.project_controller.projects.items.len) return;
    const modal_w = theme.clampf(width * 0.28, theme.scaledUi(320.0), theme.scaledUi(420.0));
    const modal_h = theme.scaledUi(188.0);
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    registerModalChromeHits(state, width, height, modal, true);
    const pad = theme.scaledUi(18.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(76.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    const gap = theme.scaledUi(10.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = input_rect.x, .y = modal.y + modal.h - pad - theme.scaledUi(34.0), .w = button_w, .h = theme.scaledUi(34.0) };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + cancel_rect.w + gap, .y = cancel_rect.y, .w = button_w, .h = cancel_rect.h };
    queueModalHit(state, input_rect, .project_rename_input, 0);
    queueModalHit(state, cancel_rect, .project_rename_cancel, 0);
    queueModalHit(state, submit_rect, .project_rename_submit, 0);
}

fn registerThreadImportModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (state.thread_import_provider == null) return;
    const project_index = state.thread_import_project_index orelse return;
    if (project_index >= state.project_controller.projects.items.len) return;
    const modal_w = theme.clampf(width * 0.42, theme.scaledUi(460.0), theme.scaledUi(640.0));
    const modal_h = theme.clampf(height * 0.66, theme.scaledUi(420.0), theme.scaledUi(620.0));
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    registerModalChromeHits(state, width, height, modal, true);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    y += theme.scaledUi(26.0);
    y += theme.scaledUi(20.0);
    y += theme.scaledUi(24.0);
    y += theme.scaledUi(48.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    queueModalHit(state, input_rect, .thread_import_input, 0);
    y += theme.scaledUi(44.0);
    const refresh_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = @max(theme.scaledUi(112.0), input_rect.w * 0.28), .h = theme.scaledUi(32.0) };
    queueModalHit(state, refresh_rect, .thread_import_refresh, 0);
    y += theme.scaledUi(42.0);
    const notice_h = if (state.threadImportNotice().len > 0) theme.scaledUi(24.0) else 0.0;
    const button_h = theme.scaledUi(34.0);
    const list_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = input_rect.w, .h = modal.y + modal.h - pad - button_h - notice_h - theme.scaledUi(16.0) - y };
    if (state.thread_import_threads.items.len != 0) {
        const row_h = theme.scaledUi(42.0);
        for (state.thread_import_threads.items, 0..) |_, index| {
            const row: palette.Rect = .{ .x = list_rect.x + theme.scaledUi(6.0), .y = list_rect.y + theme.scaledUi(6.0) + @as(f32, @floatFromInt(index)) * row_h, .w = list_rect.w - theme.scaledUi(12.0), .h = row_h - theme.scaledUi(2.0) };
            if (row.y + row.h > list_rect.y + list_rect.h) break;
            queueModalHit(state, row, .thread_import_select, index);
        }
    }
    const button_y = modal.y + modal.h - pad - button_h;
    const gap = theme.scaledUi(10.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + button_w + gap, .y = button_y, .w = button_w, .h = button_h };
    queueModalHit(state, cancel_rect, .thread_import_cancel, 0);
    queueModalHit(state, submit_rect, .thread_import_submit, 0);
}

fn renderMcpOnboardingModal(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.settings_controller.mcp_onboarding_visible or state.settings_controller.provider_onboarding_visible) return;
    const modal = mcpOnboardingRect(width, height);
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(22.0);
    const clip = modal;
    var y = modal.y + pad;

    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(28.0) }, "Make Verde work better with your agents", paletteColor(theme.COLOR_WHITE), theme.scaledUi(22.0), clip);
    y += theme.scaledUi(36.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(40.0) }, "Enable Verde's MCP tools for agents you start in terminal panes or use through Verde.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.5), clip);
    y += theme.scaledUi(54.0);

    const benefit_h = theme.scaledUi(52.0);
    const benefit_gap = theme.scaledUi(7.0);
    renderMcpBenefitRow(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = benefit_h }, "Test apps", "Inspect and interact with Verde's embedded browser.", clip);
    y += benefit_h + benefit_gap;
    renderMcpBenefitRow(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = benefit_h }, "Work with processes", "Start configured services and read their logs.", clip);
    y += benefit_h + benefit_gap;
    renderMcpBenefitRow(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = benefit_h }, "Understand the workspace", "Use the current Verde workspace and its panes automatically.", clip);
    const benefits_bottom = y + benefit_h;

    const button_h = theme.scaledUi(36.0);
    const button_y = modal.y + modal.h - pad - button_h;
    queuePaletteText(state, .{ .x = modal.x + pad, .y = benefits_bottom + theme.scaledUi(16.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(28.0) }, "Updates detected providers' user settings and preserves existing servers. Remove it any time in Settings.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), clip);
    drawActionButton(state, .{ .x = modal.x + pad, .y = button_y, .w = theme.scaledUi(104.0), .h = button_h }, "Not now", theme.COLOR_PANEL_ALT);
    drawActionButton(state, .{ .x = modal.x + modal.w - pad - theme.scaledUi(176.0), .y = button_y, .w = theme.scaledUi(176.0), .h = button_h }, "Enable Verde tools", theme.accent());
}

// Renders one capability included with Verde's MCP server.
fn renderMcpBenefitRow(state: *runtime.AppState, rect: palette.Rect, title: []const u8, detail: []const u8, clip: palette.Rect) void {
    queuePaletteRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 105)), theme.scaledUi(9.0));
    queuePaletteBorder(state, rect, paletteColor(theme.withAlpha(theme.borderMuted(), 90)), theme.scaledUi(9.0), theme.scaledUi(1.0));
    const text_x = rect.x + theme.scaledUi(14.0);
    queuePaletteText(state, .{ .x = text_x, .y = rect.y + theme.scaledUi(7.0), .w = rect.w - theme.scaledUi(28.0), .h = theme.scaledUi(18.0) }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.5), clip);
    queuePaletteText(state, .{ .x = text_x, .y = rect.y + theme.scaledUi(27.0), .w = rect.w - theme.scaledUi(28.0), .h = theme.scaledUi(17.0) }, detail, paletteColor(theme.lighten(theme.COLOR_TEXT_SUBTLE, 0.1)), theme.scaledUi(12.5), clip);
}

/// Shows the attachment preview modal for the selected image.
// Renders the first-run provider checklist when no authenticated GUI provider is available.
fn renderProviderOnboardingModal(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.settings_controller.provider_onboarding_visible) return;
    const modal = providerOnboardingRect(width, height);
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(22.0);
    const clip = modal;
    var y = modal.y + pad;

    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(28.0) }, "Connect an AI provider", paletteColor(theme.COLOR_WHITE), theme.scaledUi(22.0), clip);
    y += theme.scaledUi(34.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(42.0) }, "Verde uses coding-agent accounts already installed on this computer. Set up any one provider to start chatting; Verde does not require its own subscription.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.5), clip);
    y += theme.scaledUi(52.0);

    const snapshot = state.providerReadinessSnapshot();
    const providers = [_]runtime.Provider{ .codex, .opencode, .claude, .cursor, .pi, .fx, .grok };
    const button_h = theme.scaledUi(36.0);
    const button_y = modal.y + modal.h - pad - button_h;
    const rows_bottom = button_y - theme.scaledUi(18.0);
    const row_gap = theme.scaledUi(8.0);
    // Divide the available space across every provider row so new providers
    // cannot silently overflow past the modal buttons.
    const row_count: f32 = @floatFromInt(providers.len);
    const row_h = @max((rows_bottom - y - row_gap * (row_count - 1.0)) / row_count, theme.scaledUi(58.0));
    for (providers) |provider| {
        const row: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = row_h };
        renderProviderReadinessRow(state, row, provider, snapshot.forProvider(provider), clip);
        y += row_h + row_gap;
    }

    const gap = theme.scaledUi(10.0);
    const close_w = theme.scaledUi(104.0);
    const guide_w = theme.scaledUi(156.0);
    const check_w = theme.scaledUi(126.0);
    drawActionButton(state, .{ .x = modal.x + pad, .y = button_y, .w = close_w, .h = button_h }, "Not now", theme.COLOR_PANEL_ALT);
    drawActionButton(state, .{ .x = modal.x + modal.w - pad - check_w - gap - guide_w, .y = button_y, .w = guide_w, .h = button_h }, "Open setup guide", theme.COLOR_PANEL_MUTED);
    const checking = snapshot.codex == .checking and snapshot.opencode == .checking and snapshot.claude == .checking and snapshot.cursor == .checking and snapshot.pi == .checking and snapshot.fx == .checking and snapshot.grok == .checking;
    drawActionButton(state, .{ .x = modal.x + modal.w - pad - check_w, .y = button_y, .w = check_w, .h = button_h }, if (checking) "Checking..." else "Check again", theme.accent());
}

// Renders one provider's executable/auth status and its shortest recovery step.
fn renderProviderReadinessRow(state: *runtime.AppState, rect: palette.Rect, provider: runtime.Provider, readiness: runtime.ProviderReadiness, clip: palette.Rect) void {
    queuePaletteRoundedRect(state, rect, paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.025)), theme.scaledUi(9.0));
    queuePaletteBorder(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 190)), theme.scaledUi(9.0), theme.scaledUi(1.0));

    const dot_color = switch (readiness) {
        .ready => theme.success(),
        .signed_out => theme.COLOR_YELLOW,
        .missing => theme.COLOR_DIFF_REMOVE,
        .checking => theme.COLOR_TEXT_MUTED,
        .unavailable => theme.COLOR_YELLOW,
    };
    const dot = theme.scaledUi(8.0);
    queuePaletteRoundedRect(state, .{ .x = rect.x + theme.scaledUi(14.0), .y = rect.y + theme.scaledUi(16.0), .w = dot, .h = dot }, paletteColor(dot_color), dot * 0.5);

    const title = switch (provider) {
        .codex => "Codex",
        .opencode => "OpenCode",
        .claude => "Claude Code",
        .cursor => "Cursor",
        .pi => "Pi",
        .fx => "FX",
        .grok => "Grok",
        .muse => "Muse",
    };
    const status = switch (readiness) {
        .checking => "Checking...",
        .missing => "CLI not found",
        .signed_out => "Sign-in needed",
        .ready => "Ready",
        .unavailable => "Could not verify",
    };
    const step = providerReadinessStep(provider, readiness);
    const text_x = rect.x + theme.scaledUi(34.0);
    const status_w = theme.scaledUi(116.0);
    queuePaletteText(state, .{ .x = text_x, .y = rect.y + theme.scaledUi(8.0), .w = rect.w - status_w - theme.scaledUi(48.0), .h = theme.scaledUi(20.0) }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.5), clip);
    queuePaletteText(state, .{ .x = rect.x + rect.w - status_w - theme.scaledUi(12.0), .y = rect.y + theme.scaledUi(9.0), .w = status_w, .h = theme.scaledUi(18.0) }, status, paletteColor(dot_color), theme.scaledUi(12.0), clip);
    queuePaletteText(state, .{ .x = text_x, .y = rect.y + theme.scaledUi(31.0), .w = rect.w - theme.scaledUi(48.0), .h = @max(rect.h - theme.scaledUi(36.0), theme.scaledUi(18.0)) }, step, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), clip);
}

fn providerReadinessStep(provider: runtime.Provider, readiness: runtime.ProviderReadiness) []const u8 {
    if (readiness == .ready) return "Installed and authenticated. You can select this provider in the composer.";
    if (readiness == .checking) return "Checking the local CLI and account session...";
    return switch (provider) {
        .codex => if (readiness == .missing) "Install the Codex CLI, then run: codex login" else "Run codex login, then return here and check again.",
        .opencode => if (readiness == .missing) "Install OpenCode, then run: opencode" else "Open opencode, connect a model provider, then check again.",
        .claude => if (readiness == .missing) "Install Claude Code, then run: claude" else "Open claude, complete sign-in, then check again.",
        .cursor => if (readiness == .missing) "Install the Cursor CLI, then run: agent login" else "Run agent login, then return here and check again.",
        .pi => if (readiness == .missing) "Install the pi CLI, then run: pi" else "Open pi, connect a model provider, then check again.",
        .fx => if (readiness == .missing) "Install the fx CLI (curl -fsSL https://fx.sh/setup.sh | bash), then run: fx login" else "Run fx login, then return here and check again.",
        .grok => if (readiness == .missing) "Install Grok Build (docs.x.ai/build), then run: grok login" else "Run grok login, then return here and check again.",
        .muse => if (readiness == .missing) "Install Muse Code, then run: muse login" else "Run muse login, then return here and check again.",
    };
}

// Renders the full-size image preview modal over the workspace.
fn renderImageModal(state: *runtime.AppState, width: f32, height: f32) void {
    const modal_path = state.modal_image_path orelse return;
    const modal_padding_x: f32 = 22.0;
    const modal_padding_y: f32 = 20.0;
    const modal_width = @min(width * 0.78, 980.0);
    const modal_height = @min(height * 0.82, 760.0);
    const modal: palette.Rect = .{ .x = (width - modal_width) * 0.5, .y = (height - modal_height) * 0.5, .w = modal_width, .h = modal_height };
    drawModalChromeVisual(state, width, height, modal);

    const texture = state.ensureImageTexture(modal_path);
    const close_size: f32 = 28.0;
    const header_gap: f32 = 12.0;
    const content: palette.Rect = .{ .x = modal.x + modal_padding_x, .y = modal.y + modal_padding_y, .w = modal.w - modal_padding_x * 2.0, .h = modal.h - modal_padding_y * 2.0 };
    const close_rect: palette.Rect = .{ .x = content.x + content.w - close_size, .y = content.y, .w = close_size, .h = close_size };
    const zoom_gap = theme.scaledUi(6.0);
    const zoom_label_w = theme.scaledUi(54.0);
    const zoom_out_rect: palette.Rect = .{
        .x = close_rect.x - header_gap - close_size * 2.0 - zoom_label_w - zoom_gap * 2.0,
        .y = content.y,
        .w = close_size,
        .h = close_size,
    };
    const zoom_label_rect: palette.Rect = .{
        .x = zoom_out_rect.x + close_size + zoom_gap,
        .y = content.y,
        .w = zoom_label_w,
        .h = close_size,
    };
    const zoom_in_rect: palette.Rect = .{
        .x = zoom_label_rect.x + zoom_label_w + zoom_gap,
        .y = content.y,
        .w = close_size,
        .h = close_size,
    };
    const header_text_width = @max(zoom_out_rect.x - content.x - header_gap, 160.0);
    drawActionButton(state, close_rect, "x", theme.withAlpha(theme.COLOR_PANEL_MUTED, 220));
    drawActionButton(state, zoom_out_rect, "-", theme.withAlpha(theme.COLOR_PANEL_MUTED, 220));
    drawActionButton(state, zoom_in_rect, "+", theme.withAlpha(theme.COLOR_PANEL_MUTED, 220));
    var zoom_label_buf: [16]u8 = undefined;
    const zoom_percent: i32 = @intFromFloat(state.modal_image_zoom * 100.0);
    const zoom_label = std.fmt.bufPrint(&zoom_label_buf, "{d}%", .{zoom_percent}) catch "100%";
    const zoom_font_size = theme.scaledUi(13.0);
    const zoom_label_text_w = @as(f32, @floatFromInt(zoom_label.len)) * zoom_font_size * 0.52;
    queuePaletteText(state, .{
        .x = zoom_label_rect.x + @max((zoom_label_rect.w - zoom_label_text_w) * 0.5, 0.0),
        .y = zoom_label_rect.y + (zoom_label_rect.h - zoom_font_size * 1.25) * 0.5,
        .w = @min(zoom_label_text_w, zoom_label_rect.w),
        .h = zoom_font_size * 1.25,
    }, zoom_label, paletteColor(theme.COLOR_TEXT_MUTED), zoom_font_size, modal);
    queuePaletteText(state, .{ .x = content.x, .y = content.y, .w = header_text_width, .h = theme.scaledUi(22.0) }, std.fs.path.basename(modal_path), paletteColor(theme.COLOR_WHITE), theme.scaledUi(16.0), modal);
    queuePaletteText(state, .{ .x = content.x, .y = content.y + theme.scaledUi(24.0), .w = header_text_width, .h = theme.scaledUi(20.0) }, modal_path, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), modal);

    const canvas = imageModalCanvasRect(width, height);
    queuePaletteRoundedRect(state, canvas, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(10.0));
    queuePaletteBorder(state, canvas, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(10.0), theme.scaledUi(1.0));
    const image_max_w = @max(canvas.w - theme.scaledUi(32.0), 80.0);
    const image_max_h = @max(canvas.h - theme.scaledUi(32.0), 80.0);

    if (texture) |cached| {
        const dims = runtime.scaledImageSize(cached.width, cached.height, image_max_w, image_max_h);
        const zoomed_w = dims[0] * state.modal_image_zoom;
        const zoomed_h = dims[1] * state.modal_image_zoom;
        const max_pan_x = @max((zoomed_w - canvas.w) * 0.5, 0.0);
        const max_pan_y = @max((zoomed_h - canvas.h) * 0.5, 0.0);
        state.clampImageModalPan(max_pan_x, max_pan_y);
        state.palette_overlay_batch.image(
            state.allocator,
            .{
                .x = canvas.x + (canvas.w - zoomed_w) * 0.5 + state.modal_image_pan_x,
                .y = canvas.y + (canvas.h - zoomed_h) * 0.5 + state.modal_image_pan_y,
                .w = zoomed_w,
                .h = zoomed_h,
            },
            palette.TextureId.init(cached.texture_id),
            .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 },
            paletteColor(theme.COLOR_WHITE),
            canvas,
        ) catch {};
    } else {
        const unavailable_rect: palette.Rect = .{ .x = canvas.x + theme.scaledUi(16.0), .y = canvas.y + theme.scaledUi(16.0), .w = image_max_w, .h = @min(image_max_h, 240.0) };
        queuePaletteRoundedRect(state, unavailable_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(10.0));
        queuePaletteBorder(state, unavailable_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(10.0), theme.scaledUi(1.0));
        queuePaletteText(state, .{
            .x = unavailable_rect.x + theme.scaledUi(16.0),
            .y = unavailable_rect.y + (unavailable_rect.h - theme.scaledUi(18.0)) * 0.5,
            .w = unavailable_rect.w - theme.scaledUi(32.0),
            .h = theme.scaledUi(22.0),
        }, "Preview unavailable", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(16.0), unavailable_rect);
    }
}

/// Shows the modal used to rename the active workspace or chat.
fn renderWorkspaceRenameModal(state: *runtime.AppState, width: f32, height: f32) void {
    const rename_index = state.rename_project_index orelse return;
    if (rename_index >= state.project_controller.projects.items.len) {
        state.rename_project_index = null;
        return;
    }
    const modal_w = theme.clampf(width * 0.28, theme.scaledUi(320.0), theme.scaledUi(420.0));
    const modal_h = theme.scaledUi(188.0);
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    const renaming_thread = state.rename_thread_index != null;
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + pad, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, if (renaming_thread) "Rename chat" else "Rename workspace", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(44.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(20.0) }, state.project_controller.projects.items[rename_index].path, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(76.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    drawTextField(state, input_rect, state.renameInput(), if (renaming_thread) "Chat title" else "Workspace label", state.palette_modal_text_focus == .project_rename, state.project_rename_cursor);
    const gap = theme.scaledUi(10.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = input_rect.x, .y = modal.y + modal.h - pad - theme.scaledUi(34.0), .w = button_w, .h = theme.scaledUi(34.0) };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + cancel_rect.w + gap, .y = cancel_rect.y, .w = button_w, .h = cancel_rect.h };
    drawActionButton(state, cancel_rect, "Cancel", theme.COLOR_PANEL_ALT);
    drawActionButton(state, submit_rect, "Rename", theme.accent());
}

// Add-workspace modal for optional folder selection and creation.
fn renderWorkspaceAddModal(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.project_controller.show_creator) return;
    const modal_w = theme.clampf(width * 0.34, theme.scaledUi(360.0), theme.scaledUi(500.0));
    const notice = state.projectImportNotice();
    const notice_h: f32 = if (notice.len > 0) theme.scaledUi(24.0) else 0.0;
    const modal_h = theme.scaledUi(320.0) + notice_h;
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "New workspace", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    y += theme.scaledUi(30.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, "Blank folder creates a numbered workspace.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(18.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, "Verde manages its working directory.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(18.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, "Blank name uses the shown default.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(24.0);
    var default_name_buf: [64]u8 = undefined;
    const default_name = state.defaultProjectImportName(&default_name_buf);
    var name_placeholder_buf: [96]u8 = undefined;
    const name_placeholder = std.fmt.bufPrint(&name_placeholder_buf, "{s} (default name)", .{default_name}) catch default_name;
    const name_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    drawTextField(state, name_rect, state.importProjectNameDraft(), name_placeholder, state.palette_modal_text_focus == .project_import_name, state.project_import_name_cursor);
    y += theme.scaledUi(44.0);
    const button_gap = theme.scaledUi(10.0);
    const browse_w = (modal.w - pad * 2.0 - button_gap) * 0.5;
    const browse_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = browse_w, .h = theme.scaledUi(36.0) };
    const create_rect: palette.Rect = .{ .x = browse_rect.x + browse_rect.w + button_gap, .y = y, .w = browse_w, .h = browse_rect.h };
    drawActionButton(state, browse_rect, "Open existing folder", theme.COLOR_PANEL_ALT);
    drawActionButton(state, create_rect, "New folder...", theme.COLOR_GREEN);
    y += theme.scaledUi(44.0);
    const add_w = theme.scaledUi(92.0);
    const row_gap = theme.scaledUi(10.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0 - add_w - row_gap, .h = theme.scaledUi(34.0) };
    const add_rect: palette.Rect = .{ .x = input_rect.x + input_rect.w + row_gap, .y = y, .w = add_w, .h = theme.scaledUi(34.0) };
    drawTextField(state, input_rect, state.importDirectoryDraft(), "Folder path (optional)", state.palette_modal_text_focus == .project_import, state.project_import_cursor);
    drawActionButton(state, add_rect, "Create", theme.accent());
    y += theme.scaledUi(46.0);
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = theme.scaledUi(120.0), .h = theme.scaledUi(34.0) };
    drawActionButton(state, cancel_rect, "Cancel", theme.COLOR_PANEL_ALT);
    if (notice.len > 0) {
        y += theme.scaledUi(42.0);
        queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(20.0) }, notice, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), modal);
    }
}

fn renderTranscriptSelectionModal(state: *runtime.AppState, width: f32, height: f32) void {
    const transcript_text = state.transcriptSelectionBuffer() orelse return;
    _ = state.consumeTranscriptSelectionModalRequest();
    const modal: palette.Rect = .{ .x = (width - @min(width * 0.76, theme.scaledUi(980.0))) * 0.5, .y = (height - @min(height * 0.8, theme.scaledUi(760.0))) * 0.5, .w = @min(width * 0.76, theme.scaledUi(980.0)), .h = @min(height * 0.8, theme.scaledUi(760.0)) };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + pad, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "Thread text", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(44.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(20.0) }, "Ctrl+C copies the modal text.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    const close_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + modal.h - pad - theme.scaledUi(34.0), .w = theme.scaledUi(112.0), .h = theme.scaledUi(34.0) };
    const text_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(74.0), .w = modal.w - pad * 2.0, .h = close_rect.y - modal.y - theme.scaledUi(86.0) };
    queuePaletteRoundedRect(state, text_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(8.0));
    queuePaletteBorder(state, text_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), theme.scaledUi(1.0));
    queuePaletteText(state, .{ .x = text_rect.x + theme.scaledUi(12.0), .y = text_rect.y + theme.scaledUi(10.0), .w = text_rect.w - theme.scaledUi(24.0), .h = text_rect.h - theme.scaledUi(20.0) }, transcript_text, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), text_rect);
    drawActionButton(state, close_rect, "Close", theme.COLOR_PANEL_ALT);
}

fn renderThreadImportModal(state: *runtime.AppState, width: f32, height: f32) void {
    const provider = state.thread_import_provider orelse return;
    const project_index = state.thread_import_project_index orelse return;
    if (project_index >= state.project_controller.projects.items.len) {
        state.cancelThreadImport();
        return;
    }
    const modal_w = theme.clampf(width * 0.42, theme.scaledUi(460.0), theme.scaledUi(640.0));
    const modal_h = theme.clampf(height * 0.66, theme.scaledUi(420.0), theme.scaledUi(620.0));
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    const project = &state.project_controller.projects.items[project_index];
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, threadImportHeading(provider), paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    y += theme.scaledUi(26.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, project.label, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(20.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, project.path, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(24.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(40.0) }, threadImportDescription(provider), paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(48.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    drawTextField(state, input_rect, state.threadImportThreadId(), threadImportHint(provider), state.palette_modal_text_focus == .thread_import, state.thread_import_cursor);
    y += theme.scaledUi(44.0);
    const refresh_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = @max(theme.scaledUi(112.0), input_rect.w * 0.28), .h = theme.scaledUi(32.0) };
    drawActionButton(state, refresh_rect, "Refresh list", theme.COLOR_PANEL_MUTED);
    y += theme.scaledUi(42.0);
    const notice_h = if (state.threadImportNotice().len > 0) theme.scaledUi(24.0) else 0.0;
    const button_h = theme.scaledUi(34.0);
    const list_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = input_rect.w, .h = modal.y + modal.h - pad - button_h - notice_h - theme.scaledUi(16.0) - y };
    queuePaletteRoundedRect(state, list_rect, paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.03)), theme.scaledUi(8.0));
    queuePaletteBorder(state, list_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), theme.scaledUi(1.0));
    if (state.thread_import_threads.items.len == 0) {
        queuePaletteText(state, .{ .x = list_rect.x + theme.scaledUi(12.0), .y = list_rect.y + theme.scaledUi(12.0), .w = list_rect.w - theme.scaledUi(24.0), .h = theme.scaledUi(20.0) }, emptyThreadImportListNotice(provider), paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), list_rect);
    } else {
        const row_h = theme.scaledUi(42.0);
        for (state.thread_import_threads.items, 0..) |thread, index| {
            const row: palette.Rect = .{ .x = list_rect.x + theme.scaledUi(6.0), .y = list_rect.y + theme.scaledUi(6.0) + @as(f32, @floatFromInt(index)) * row_h, .w = list_rect.w - theme.scaledUi(12.0), .h = row_h - theme.scaledUi(2.0) };
            if (row.y + row.h > list_rect.y + list_rect.h) break;
            const selected = state.thread_import_selected_index != null and state.thread_import_selected_index.? == index;
            const row_hovered = state.thread_import_hover_index != null and state.thread_import_hover_index.? == index;
            if (selected) {
                const sel_bg = if (row_hovered)
                    paletteColor(theme.lighten(theme.COLOR_PANEL_MUTED, 0.10))
                else
                    paletteColor(theme.COLOR_PANEL_MUTED);
                queuePaletteRoundedRect(state, row, sel_bg, theme.scaledUi(6.0));
            } else if (row_hovered) {
                queuePaletteRoundedRect(state, row, paletteColor(theme.lighten(theme.COLOR_PANEL_MUTED, 0.06)), theme.scaledUi(6.0));
                queuePaletteBorder(state, row, paletteColor(theme.lighten(theme.borderMuted(), 0.02)), theme.scaledUi(6.0), theme.scaledUi(1.0));
            }
            const title_col = paletteColor(theme.COLOR_WHITE);
            const id_col = paletteColor(if (row_hovered) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE);
            const text_w = row.w - theme.scaledUi(16.0);
            const title_font = theme.scaledUi(13.0);
            const id_font = theme.scaledUi(12.0);
            const title = truncateThreadImportLabel(state, threadImportSingleLineLabel(thread.title), text_w, title_font);
            const id = truncateThreadImportLabel(state, threadImportSingleLineLabel(thread.id), text_w, id_font);
            queuePaletteText(state, .{ .x = row.x + theme.scaledUi(8.0), .y = row.y + theme.scaledUi(4.0), .w = text_w, .h = theme.scaledUi(18.0) }, title, title_col, title_font, row);
            queuePaletteText(state, .{ .x = row.x + theme.scaledUi(8.0), .y = row.y + theme.scaledUi(22.0), .w = text_w, .h = theme.scaledUi(16.0) }, id, id_col, id_font, row);
        }
    }

    const button_y = modal.y + modal.h - pad - button_h;
    if (state.threadImportNotice().len > 0) {
        queuePaletteText(state, .{ .x = modal.x + pad, .y = button_y - theme.scaledUi(26.0), .w = input_rect.w, .h = theme.scaledUi(20.0) }, state.threadImportNotice(), paletteColor(theme.COLOR_YELLOW), theme.scaledUi(13.0), modal);
    }
    const gap = theme.scaledUi(10.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + button_w + gap, .y = button_y, .w = button_w, .h = button_h };
    drawActionButton(state, cancel_rect, "Cancel", theme.COLOR_PANEL_MUTED);
    drawActionButton(state, submit_rect, "Import", theme.COLOR_GREEN);
}

fn threadImportHeading(provider: runtime.Provider) []const u8 {
    return switch (provider) {
        .codex => "Import Codex thread",
        .opencode => "Import OpenCode thread",
        .claude => "Import Claude thread",
        .cursor => "Import Cursor thread",
        .pi => "Import Pi thread",
        .fx => "Import FX thread",
        .grok => "Import Grok thread",
        .muse => "Import Muse thread",
    };
}

fn threadImportDescription(provider: runtime.Provider) []const u8 {
    return switch (provider) {
        .codex => "Import loads the existing Codex transcript into this workspace and binds future turns to the same thread.",
        .opencode => "Import loads the existing OpenCode transcript into this workspace and binds future turns to the same thread.",
        .claude => "Import loads the existing Claude transcript into this workspace and binds future turns to the same thread.",
        .cursor => "Import loads the existing Cursor transcript into this workspace and binds future turns to the same thread.",
        .pi => "Import loads the existing Pi transcript into this workspace and binds future turns to the same thread.",
        .fx => "Import loads the existing FX transcript into this workspace and binds future turns to the same thread.",
        .grok => "Import loads the existing Grok transcript into this workspace and binds future turns to the same thread.",
        .muse => "Import loads the existing Muse transcript into this workspace and binds future turns to the same session.",
    };
}

fn threadImportHint(provider: runtime.Provider) [:0]const u8 {
    return switch (provider) {
        .codex => "Paste a Codex thread ID",
        .opencode => "Paste an OpenCode thread ID",
        .claude => "Paste a Claude thread ID",
        .cursor => "Paste a Cursor thread ID",
        .pi => "Paste a Pi session ID",
        .fx => "Paste an FX session ID",
        .grok => "Paste a Grok session ID",
        .muse => "Paste a Muse session ID",
    };
}

fn emptyThreadImportListNotice(provider: runtime.Provider) []const u8 {
    return switch (provider) {
        .codex => "No cached Codex threads to show.",
        .opencode => "No cached OpenCode threads to show.",
        .claude => "No cached Claude threads to show.",
        .cursor => "No cached Cursor threads to show.",
        .pi => "No cached Pi threads to show.",
        .fx => "No cached FX threads to show.",
        .grok => "No cached Grok threads to show.",
        .muse => "No cached Muse sessions to show.",
    };
}

fn threadImportSingleLineLabel(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const line_end = std.mem.findAny(u8, trimmed, "\r\n") orelse trimmed.len;
    return std.mem.trimEnd(u8, trimmed[0..line_end], " \t");
}

// Import summaries come from external providers, so measure and bound their
// labels before handing them to Palette's fixed-height rows.
fn truncateThreadImportLabel(state: *runtime.AppState, value: []const u8, max_width: f32, font_size: f32) []const u8 {
    if (value.len == 0 or text_measure.textWidth(.ui, font_size, value) <= max_width) return value;
    const ellipsis = "…";
    const ellipsis_width = text_measure.textWidth(.ui, font_size, ellipsis);
    var low: usize = 0;
    var high: usize = value.len - 1;
    var best: usize = 0;
    while (low <= high) {
        const mid = low + (high - low) / 2;
        var prefix_end = mid;
        while (prefix_end > 0 and (value[prefix_end] & 0xC0) == 0x80) prefix_end -= 1;
        if (text_measure.textWidth(.ui, font_size, value[0..prefix_end]) + ellipsis_width <= max_width) {
            best = @max(best, prefix_end);
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }
    if (best == 0) return ellipsis;
    return std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s}{s}", .{ value[0..best], ellipsis }) catch value;
}

test "thread import labels use only the first non-empty line" {
    try std.testing.expectEqualStrings("First title", threadImportSingleLineLabel(" \nFirst title  \r\nSecond line"));
    try std.testing.expectEqualStrings("One line", threadImportSingleLineLabel("\tOne line\t"));
}

test "runtime credential input filters edits and wipes removed bytes" {
    var state: runtime.AppState = undefined;
    // Zero the sentinel too: `[0..]` on a sentinel-terminated array stops
    // before the terminator, and the buffer accessor checks it.
    state.runtime_credential_token_storage = std.mem.zeroes(@TypeOf(state.runtime_credential_token_storage));
    state.runtime_credential_token_cursor = 0;
    state.palette_modal_text_focus = .runtime_credential;
    state.modal_text_selection_anchor = null;
    state.modal_text_drag_active = false;
    state.runtime_credential_profile_id = null;
    state.runtime_pin_proposal = null;

    try std.testing.expect(handlePaletteTextInput(&state, "abc \nDEF\t$"));
    try std.testing.expectEqualStrings("abcDEF$", state.runtimeCredentialToken());

    // Insertion replaces the active selection first and applies the same
    // printable, no-space contract used by the secret store.
    state.modal_text_selection_anchor = 3;
    state.runtime_credential_token_cursor = 6;
    try std.testing.expect(handlePaletteTextInput(&state, "pq\n r"));
    try std.testing.expectEqualStrings("abcpqr$", state.runtimeCredentialToken());
    try std.testing.expectEqual(@as(?usize, null), state.modal_text_selection_anchor);

    state.runtime_credential_token_cursor = state.runtimeCredentialToken().len;
    const before_backspace = state.runtimeCredentialToken().len;
    try std.testing.expect(deleteModalText(&state, true));
    try std.testing.expectEqualStrings("abcpqr", state.runtimeCredentialToken());
    try std.testing.expectEqual(@as(u8, 0), state.runtime_credential_token_storage[before_backspace - 1]);
    state.runtime_credential_token_cursor = 3;
    const before_delete = state.runtimeCredentialToken().len;
    try std.testing.expect(deleteModalText(&state, false));
    try std.testing.expectEqualStrings("abcqr", state.runtimeCredentialToken());
    try std.testing.expectEqual(@as(u8, 0), state.runtime_credential_token_storage[before_delete - 1]);

    const previous_len = state.runtimeCredentialToken().len;
    state.modal_text_selection_anchor = 0;
    state.runtime_credential_token_cursor = previous_len;
    try std.testing.expect(deleteModalSelection(&state));
    try std.testing.expectEqualStrings("", state.runtimeCredentialToken());
    for (state.runtime_credential_token_storage[0..previous_len]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "runtime credential input honors selection navigation pointer and blur contract" {
    var state: runtime.AppState = undefined;
    // Zero the sentinel too: `[0..]` on a sentinel-terminated array stops
    // before the terminator, and the buffer accessor checks it.
    state.runtime_credential_token_storage = std.mem.zeroes(@TypeOf(state.runtime_credential_token_storage));
    @memcpy(state.runtime_credential_token_storage[0..7], "abc/def");
    state.runtime_credential_token_cursor = 3;
    state.palette_modal_text_focus = .runtime_credential;
    state.modal_text_selection_anchor = null;
    state.modal_text_drag_active = false;
    state.runtime_credential_profile_id = null;
    state.runtime_pin_proposal = null;

    try std.testing.expect(moveModalCursorWithShift(&state, 0, true));
    try std.testing.expectEqual(@as(?usize, 3), state.modal_text_selection_anchor);
    try std.testing.expectEqual(@as(usize, 0), state.runtime_credential_token_cursor);
    try std.testing.expect(moveModalCursorWithShift(&state, 7, false));
    try std.testing.expectEqual(@as(?usize, null), state.modal_text_selection_anchor);

    const word = modalWordBoundsAt(state.runtimeCredentialToken(), 5);
    try std.testing.expectEqual(@as(usize, 4), word.start);
    try std.testing.expectEqual(@as(usize, 7), word.end);

    const input_rect: palette.Rect = .{ .x = 20.0, .y = 20.0, .w = 300.0, .h = 36.0 };
    focusModalInput(&state, .runtime_credential, input_rect, input_rect.x, 3);
    try std.testing.expectEqual(@as(?usize, 0), state.modal_text_selection_anchor);
    try std.testing.expectEqual(@as(usize, 7), state.runtime_credential_token_cursor);
    try std.testing.expect(!state.modal_text_drag_active);

    focusModalInput(&state, .runtime_credential, input_rect, input_rect.x + input_rect.w, 1);
    try std.testing.expectEqual(@as(?usize, 7), state.modal_text_selection_anchor);
    try std.testing.expectEqual(@as(usize, 7), state.runtime_credential_token_cursor);
    try std.testing.expect(state.modal_text_drag_active);

    blurPaletteModalTextInput(&state);
    try std.testing.expectEqual(runtime.PaletteModalTextFocus.none, state.palette_modal_text_focus);
    try std.testing.expectEqual(@as(?usize, null), state.modal_text_selection_anchor);
    try std.testing.expect(!state.modal_text_drag_active);

    // Blurred runtime modals still consume SDL text_input so a paired event
    // cannot reach an obscured composer or terminal.
    state.runtime_credential_profile_id = @constCast("profile-remote");
    try std.testing.expect(handlePaletteTextInput(&state, "must-not-leak"));
    try std.testing.expectEqualStrings("abc/def", state.runtimeCredentialToken());
}

test "runtime credential renderer receives only a same-length mask" {
    var mask_storage: [4096]u8 = undefined;
    const masked = maskedRuntimeCredential(&mask_storage, "not-a-renderable-secret".len);
    try std.testing.expectEqual(@as(usize, "not-a-renderable-secret".len), masked.len);
    for (masked) |byte| try std.testing.expectEqual(@as(u8, '*'), byte);
    try std.testing.expect(!std.mem.eql(u8, masked, "not-a-renderable-secret"));
}

test "Pair wizard form positions only its two visible fields on separate rows" {
    var state: runtime.AppState = undefined;
    state.runtime_connections = .{};
    state.runtime_connections.wizard_step = .form;
    state.runtime_connections.wizard_method = .pair;

    const pair_layout = runtimeWizardLayout(&state, 1200.0, 900.0);
    const label = pair_layout.fields[@intFromEnum(WizardField.label)];
    const pair_link = pair_layout.fields[@intFromEnum(WizardField.control_plane_url)];
    try std.testing.expect(pair_link.y >= label.y + label.h);
    try std.testing.expectEqual(label.x, pair_link.x);
    try std.testing.expectEqual(label.w, pair_link.w);
    try std.testing.expectEqualSlices(
        WizardField,
        &.{ .label, .control_plane_url },
        state.runtime_connections.visibleFields(),
    );

    state.runtime_connections.wizard_method = .ssh;
    const ssh_layout = runtimeWizardLayout(&state, 1200.0, 900.0);
    try std.testing.expect(pair_layout.modal.h < ssh_layout.modal.h);
}

test "workspace settings modal dismisses on escape and routes its actions" {
    const source = @embedFile("layout.zig");
    const dismiss_start = std.mem.indexOf(u8, source, "fn dismissTopModal").?;
    const dismiss_end = std.mem.indexOfPos(u8, source, dismiss_start, "fn keymodBits").?;
    const dismiss_path = source[dismiss_start..dismiss_end];
    try std.testing.expect(std.mem.indexOf(u8, dismiss_path, "state.workspaceSettingsOpen()") != null);
    try std.testing.expect(std.mem.indexOf(u8, dismiss_path, "state.closeWorkspaceSettings()") != null);

    const pointer_start = std.mem.indexOf(u8, source, "pub fn handlePaletteMouseButton").?;
    const pointer_end = std.mem.indexOfPos(u8, source, pointer_start, "fn focusModalInput").?;
    const pointer_path = source[pointer_start..pointer_end];
    try std.testing.expect(std.mem.indexOf(u8, pointer_path, ".workspace_settings_option => state.applyWorkspaceSettingsOption(hit.index)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pointer_path, ".workspace_settings_manage => state.openManageConnectionsFromWorkspaceSettings()") != null);
    try std.testing.expect(std.mem.indexOf(u8, pointer_path, ".workspace_settings_close => state.closeWorkspaceSettings()") != null);
}

test "workspace settings modal owns keyboard and text input while open" {
    const allocator = std.testing.allocator;
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.lifecycle = .{};
    state.palette_modal_text_focus = .none;
    state.modal_text_selection_anchor = null;
    state.modal_text_drag_active = false;
    state.runtime_credential_profile_id = null;
    state.runtime_pin_proposal = null;
    state.modal_image_path = null;
    state.settings_controller.mcp_onboarding_visible = false;
    state.settings_controller.provider_onboarding_visible = false;
    state.settings_controller.modal_visible = false;
    state.rename_project_index = null;
    state.transcript_controller.selection_text = null;
    state.thread_import_provider = null;
    state.handoff_controller.sheet_open = false;
    state.project_controller.show_creator = false;
    state.runtime_connections = .{};
    state.command_controller.open = false;
    state.workspace_settings_project_id = null;
    state.workspace_settings_notice_storage = @splat(0);
    defer state.closeWorkspaceSettings();

    // With no focused field, an SDL text_input must be swallowed while the
    // modal is open so printable characters cannot reach the obscured
    // composer, browser, or terminal.
    try std.testing.expect(!handlePaletteTextInput(&state, "x"));
    state.workspace_settings_project_id = try allocator.dupe(u8, "workspace-a");
    try std.testing.expect(handlePaletteTextInput(&state, "x"));

    // Every key-down is consumed while the modal owns the keyboard; Escape
    // additionally closes it through the shared dismiss path.
    var event: sdl.KeyboardEvent = undefined;
    @memset(std.mem.asBytes(&event), 0);
    event.type = .key_down;
    event.down = true;
    const consumed_keys: [4]sdl.Keycode = .{ .@"return", .c, .backspace, .q };
    for (consumed_keys) |key| {
        event.key = key;
        try std.testing.expect(handlePaletteKeyDown(&state, &event));
        try std.testing.expect(state.workspaceSettingsOpen());
    }
    // Ctrl+C (copy chord) is likewise consumed, not forwarded.
    event.key = .c;
    @as(*u16, @ptrCast(&event.mod)).* = sdl.Keymod.ctrl;
    try std.testing.expect(handlePaletteKeyDown(&state, &event));
    try std.testing.expect(state.workspaceSettingsOpen());
    @as(*u16, @ptrCast(&event.mod)).* = sdl.Keymod.none;
    event.key = .escape;
    try std.testing.expect(handlePaletteKeyDown(&state, &event));
    try std.testing.expect(!state.workspaceSettingsOpen());
    // Once closed, the same keys fall back to normal (unconsumed) routing.
    event.key = .q;
    try std.testing.expect(!handlePaletteKeyDown(&state, &event));
    try std.testing.expect(!handlePaletteTextInput(&state, "x"));
}

test "workspace settings layout clamps the option list at short heights" {
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);
    const allocator = std.testing.allocator;

    var state: runtime.AppState = undefined;
    state.runtime_picker_profiles = .empty;
    state.settings_controller = .{};
    defer {
        for (state.runtime_picker_profiles.items) |*profile| {
            allocator.free(profile.profile_id);
        }
        state.runtime_picker_profiles.deinit(allocator);
    }
    var index: usize = 0;
    while (index < 12) : (index += 1) {
        try state.runtime_picker_profiles.append(allocator, .{
            .profile_id = try allocator.dupe(u8, "profile-0123456789abcdef0123456789abcdef"),
            .status = .offline,
        });
    }

    const tall = workspaceSettingsLayout(&state, 1200.0, 1000.0);
    const short = workspaceSettingsLayout(&state, 1200.0, 520.0);
    // The whole modal stays on screen at short heights; only the list shrinks
    // and becomes scrollable.
    try std.testing.expect(short.modal.y >= 0.0);
    try std.testing.expect(short.modal.y + short.modal.h <= 520.0 + theme.scaledUi(1.0));
    try std.testing.expect(short.list.h < tall.list.h);
    try std.testing.expect(short.max_scroll_y > 0.0);
    // Buttons stay inside the modal below the notice band.
    try std.testing.expect(short.close_button.y + short.close_button.h <= short.modal.y + short.modal.h);
    try std.testing.expect(short.manage_button.x + short.manage_button.w < short.close_button.x);
    // A row scrolled past the clip registers no hit area.
    const scrolled = workspaceSettingsOptionRowRect(short, 11, short.max_scroll_y);
    try std.testing.expect(scrolled.y + scrolled.h <= short.list.y + short.list.h + short.row_h);
    const hidden = rectIntersection(workspaceSettingsOptionRowRect(short, 0, short.max_scroll_y), short.list);
    try std.testing.expect(hidden.h <= 0.0 or short.max_scroll_y < short.row_h);

    // A half-scrolled top row centers its radio above the list band, so the
    // renderer must gate the unclippable ring/dot on full containment.
    const partial = workspaceSettingsOptionRowRect(short, 0, short.row_h * 0.5);
    const radio_size = theme.scaledUi(14.0);
    const partial_radio_y = partial.y + (partial.h - radio_size) * 0.5;
    try std.testing.expect(partial_radio_y < short.list.y);
    const source = @embedFile("layout.zig");
    const render_start = std.mem.indexOf(u8, source, "fn renderWorkspaceSettingsModal").?;
    const render_end = std.mem.indexOfPos(u8, source, render_start, "fn drawModalChromeVisual").?;
    const render_path = source[render_start..render_end];
    const guard = std.mem.indexOf(u8, render_path, "const radio_fully_visible = radio.y >= layout.list.y and").?;
    const ring = std.mem.indexOf(u8, render_path, "queuePaletteBorder(state, radio").?;
    try std.testing.expect(guard < ring);
}

test "runtime trust requires the explicit confirmation button" {
    const source = @embedFile("layout.zig");
    const keys_start = std.mem.indexOf(u8, source, "pub fn handlePaletteKeyDown").?;
    const keys_end = std.mem.indexOfPos(u8, source, keys_start, "fn dismissTopModal").?;
    const key_path = source[keys_start..keys_end];
    try std.testing.expect(std.mem.indexOf(u8, key_path, "state.runtimeTrustProposal() != null") != null);
    try std.testing.expect(std.mem.indexOf(u8, key_path, "confirmRuntimeTrust") == null);

    const pointer_start = std.mem.indexOf(u8, source, "pub fn handlePaletteMouseButton").?;
    const pointer_end = std.mem.indexOfPos(u8, source, pointer_start, "fn focusModalInput").?;
    const pointer_path = source[pointer_start..pointer_end];
    try std.testing.expect(std.mem.indexOf(u8, pointer_path, ".runtime_trust_confirm => state.confirmRuntimeTrust()") != null);
}

test "runtime wizard fields honor the modal text-input contract and port filtering" {
    var state: runtime.AppState = undefined;
    state.runtime_connections = .{};
    state.runtime_connections.wizard_open = true;
    state.palette_modal_text_focus = .runtime_wizard_host;
    state.modal_text_selection_anchor = null;
    state.modal_text_drag_active = false;
    state.runtime_credential_profile_id = null;
    state.runtime_pin_proposal = null;

    try std.testing.expect(handlePaletteTextInput(&state, "dev.\nexample"));
    try std.testing.expectEqualStrings("dev.example", state.runtime_connections.fieldValue(.host));

    // Insertion replaces the active selection first; Shift navigation and
    // pointer focus follow the same anchor/cursor contract as other modals.
    state.modal_text_selection_anchor = 3;
    state.runtime_connections.host_cursor = 4;
    try std.testing.expect(handlePaletteTextInput(&state, "-"));
    try std.testing.expectEqualStrings("dev-example", state.runtime_connections.fieldValue(.host));
    try std.testing.expectEqual(@as(?usize, null), state.modal_text_selection_anchor);
    try std.testing.expect(moveModalCursorWithShift(&state, 0, true));
    try std.testing.expectEqual(@as(?usize, 4), state.modal_text_selection_anchor);
    try std.testing.expectEqual(@as(usize, 0), state.runtime_connections.host_cursor);
    try std.testing.expect(deleteModalSelection(&state));
    try std.testing.expectEqualStrings("example", state.runtime_connections.fieldValue(.host));

    const input_rect: palette.Rect = .{ .x = 20.0, .y = 20.0, .w = 300.0, .h = 36.0 };
    focusModalInput(&state, .runtime_wizard_host, input_rect, input_rect.x, 3);
    try std.testing.expectEqual(@as(?usize, 0), state.modal_text_selection_anchor);
    try std.testing.expectEqual(@as(usize, 7), state.runtime_connections.host_cursor);
    blurPaletteModalTextInput(&state);
    try std.testing.expectEqual(runtime.PaletteModalTextFocus.none, state.palette_modal_text_focus);
    try std.testing.expectEqual(@as(?usize, null), state.modal_text_selection_anchor);
    try std.testing.expect(!state.modal_text_drag_active);

    // Port fields accept digits only, so a pasted "host:port" cannot smuggle
    // text into a numeric field.
    state.palette_modal_text_focus = .runtime_wizard_gateway_port;
    try std.testing.expect(handlePaletteTextInput(&state, "6a7-8 3"));
    try std.testing.expectEqualStrings("6783", state.runtime_connections.fieldValue(.gateway_port));
    state.runtime_connections.gateway_port_cursor = 4;
    try std.testing.expect(deleteModalText(&state, true));
    try std.testing.expectEqualStrings("678", state.runtime_connections.fieldValue(.gateway_port));
}
