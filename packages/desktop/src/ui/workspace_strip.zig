//! Compact horizontal tab strip across the top of the pane region: one tab per
//! workspace tab (see `state/workspace_tabs.zig`) of the selected workspace,
//! plus a trailing "+" that opens a new chat tab. Workspace switching stays in
//! the sidebar rail.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const app_config = @import("../app/config.zig");
const keybinds = @import("../app/keybinds.zig");
const storage_mod = @import("../state/storage.zig");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");
const runtime = @import("runtime.zig");
const sidebar = @import("sidebar.zig");

/// Strip height in unscaled UI units: one compact tab row, matching the
/// sidebar header row so the pane region loses the least height possible.
pub const STRIP_HEIGHT_UI: f32 = 32.0;
/// Vertical inset between the strip edge and the tab body; tabs are full
/// rectangles inside it so every tab shares one height and the bottom gap
/// to pane content stays constant.
pub const TAB_INSET_Y_UI: f32 = 4.0;
/// Leading/trailing breathing room so the first tab does not butt against
/// the sidebar rail edge and the "+" tab never touches the window edge.
pub const STRIP_PAD_X_UI: f32 = 8.0;
/// Narrowest tab that still shows a readable "..." label on tight windows.
pub const MIN_TAB_WIDTH_UI: f32 = 44.0;
/// Widest tab; keeps long labels from swallowing the strip on wide windows.
pub const MAX_TAB_WIDTH_UI: f32 = 200.0;
/// Adjacent tabs are separated by a hairline gap instead of a border so they
/// read as one tab row (Herdr-style) rather than floating pills.
pub const TAB_GAP_UI: f32 = 3.0;
pub const TAB_PAD_X_UI: f32 = 12.0;
/// The trailing "+" tab is square-ish: tab height plus a little side padding
/// so the glyph has a comfortable hit target without reading as a label tab.
pub const PLUS_TAB_WIDTH_UI: f32 = 30.0;
const LABEL_FONT_UI: f32 = 13.0;
const TAB_RADIUS_UI: f32 = 3.0;
/// Ctrl-reveal key tip: same square badge the sidebar pane rows draw so the
/// Ctrl+N ordinal reads identically in both places.
const KEY_TIP_SIZE_UI: f32 = 18.0;
const KEY_TIP_FONT_UI: f32 = 11.0;
const KEY_TIP_RADIUS_UI: f32 = 5.0;
const KEY_TIP_INSET_X_UI: f32 = 4.0;
/// Same line box the other Palette UI text queues use (see sidebar/layout).
const LINE_HEIGHT_FACTOR: f32 = 1.25;
/// Bounded label buffer; tabs are short so longer titles are truncated.
const LABEL_BUFFER_LEN: usize = 96;

pub const HitKind = enum { tab, add_tab };

const StripHit = struct {
    rect: palette.Rect,
    kind: HitKind,
    project_index: usize,
    /// Pane focused when the tab is activated; unused for `add_tab`.
    pane_id: runtime.WorkspacePaneId,
};

/// Mirrors the sidebar's fixed hit array so pointer routing needs no allocation.
var strip_hits: [128]StripHit = undefined;
var strip_hit_count: usize = 0;
var strip_rect: palette.Rect = .{};
var hovered_hit: ?usize = null;

pub const Split = struct {
    strip: ?palette.Rect,
    content: palette.Rect,
};

/// By default the strip exists only when the sidebar cannot show the pane
/// list itself (collapsed rails reduce panes to dots, hidden rails show
/// nothing); `ui.workspace_tabs` can force it on beside the expanded sidebar
/// or turn it off entirely.
pub fn isVisible(state: *const runtime.AppState) bool {
    if (state.project_controller.projects.items.len == 0) return false;
    return switch (state.app_config.workspace_tabs) {
        .disabled => false,
        .always => true,
        .automatic => state.isSidebarCollapsed() or state.isSidebarHidden(),
    };
}

pub fn height() f32 {
    return theme.scaledUi(STRIP_HEIGHT_UI);
}

/// Carves the strip off the top of the workspace rect exactly once; callers
/// lay out panes in `content` so tiled and scrolling layouts never overlap it.
pub fn splitWorkspaceRect(state: *const runtime.AppState, workspace: palette.Rect) Split {
    if (!isVisible(state)) return .{ .strip = null, .content = workspace };
    const strip_h = @min(height(), workspace.h);
    return .{
        .strip = .{ .x = workspace.x, .y = workspace.y, .w = workspace.w, .h = strip_h },
        .content = .{ .x = workspace.x, .y = workspace.y + strip_h, .w = workspace.w, .h = workspace.h - strip_h },
    };
}

/// Width every tab may use once the "+" tab has its fixed share.
pub fn tabWidthCap(strip_w: f32, tab_count: usize) f32 {
    if (tab_count == 0) return 0.0;
    const gap = theme.scaledUi(TAB_GAP_UI);
    const count: f32 = @floatFromInt(tab_count);
    const available = @max(strip_w - theme.scaledUi(STRIP_PAD_X_UI) * 2.0 - theme.scaledUi(PLUS_TAB_WIDTH_UI) - gap * count, 0.0);
    return theme.clampf(available / count, theme.scaledUi(MIN_TAB_WIDTH_UI), theme.scaledUi(MAX_TAB_WIDTH_UI));
}

/// Tabs are content-sized (label plus balanced padding) so short names stay
/// compact; on narrow windows the shared cap shrinks every tab together and
/// labels truncate rather than trailing tabs vanishing.
pub fn tabWidth(label_w: f32, cap: f32) f32 {
    const natural = label_w + theme.scaledUi(TAB_PAD_X_UI) * 2.0;
    return theme.clampf(natural, theme.scaledUi(MIN_TAB_WIDTH_UI), cap);
}

pub fn tabRect(strip: palette.Rect, x: f32, w: f32) palette.Rect {
    const inset = theme.scaledUi(TAB_INSET_Y_UI);
    return .{ .x = x, .y = strip.y + inset, .w = w, .h = @max(strip.h - inset * 2.0, 0.0) };
}

/// The "+" tab follows the last tab but never leaves the strip: on overflow
/// it pins to the right edge so opening a new tab stays reachable.
pub fn plusTabRect(strip: palette.Rect, after_x: f32) palette.Rect {
    const w = theme.scaledUi(PLUS_TAB_WIDTH_UI);
    const pad = theme.scaledUi(STRIP_PAD_X_UI);
    const x = @min(after_x, strip.x + strip.w - pad - w);
    return tabRect(strip, @max(x, strip.x + pad), w);
}

/// Label shown on a tab: the title of its preferred pane (the last-focused
/// child of a split tile), so a chat│terminal tile reads as the chat you
/// were working in rather than an arbitrary member.
pub fn tabLabel(state: *const runtime.AppState, project_index: usize, tab: runtime.WorkspaceTab) []const u8 {
    const project = &state.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(tab.preferred_pane_id) orelse return "Pane";
    return sidebar.paneTitle(state, project_index, project, pane);
}

/// Tab strip: a Herdr-style row of rectangular tabs along the top of the
/// pane region, one per tab of the selected workspace (a split tile is one
/// tab) plus a trailing "+" tab. Rendered only when the sidebar is collapsed
/// or hidden.
pub fn render(state: *runtime.AppState, strip: palette.Rect) void {
    strip_hit_count = 0;
    strip_rect = strip;
    queueRect(state, strip, paletteColor(theme.COLOR_PANEL));
    if (state.project_controller.projects.items.len == 0) return;
    const project_index = state.project_controller.selected_index;
    const layout = &state.project_controller.projects.items[project_index].workspace_layout;
    var tab_buffer: [runtime.workspace_tabs.MAX_WORKSPACE_TABS]runtime.WorkspaceTab = undefined;
    const tabs = runtime.workspace_tabs.collect(layout, &tab_buffer);
    const focused_tab_id = runtime.workspace_tabs.focusedTabId(layout);
    const cap = tabWidthCap(strip.w, tabs.len);
    const gap = theme.scaledUi(TAB_GAP_UI);
    const font_size = theme.scaledUi(LABEL_FONT_UI);
    const pad_x = theme.scaledUi(TAB_PAD_X_UI);
    const plus_w = theme.scaledUi(PLUS_TAB_WIDTH_UI);
    const strip_pad = theme.scaledUi(STRIP_PAD_X_UI);
    // Tabs may not run under the "+" tab's reserved right-edge slot.
    const tabs_right = strip.x + strip.w - strip_pad - plus_w - gap;
    // Holding Ctrl reveals the Ctrl+N ordinal of each tab, mirroring the
    // sidebar pane rows; the badge takes a slot at the tab's right edge.
    const key_tip_w = theme.scaledUi(KEY_TIP_SIZE_UI) + theme.scaledUi(KEY_TIP_INSET_X_UI);
    var x = strip.x + strip_pad;
    for (tabs, 0..) |tab, tab_index| {
        const title = tabLabel(state, project_index, tab);
        var key_tip_buf: [16]u8 = undefined;
        const key_tip = tabKeyTip(state, &key_tip_buf, tab_index);
        const tip_reserve = if (key_tip.len > 0) key_tip_w else 0.0;
        // Measure through the GPU text path so tab widths match drawn glyphs.
        const label_w = runtime.paletteUiTextPrefixWidth(title, font_size, title.len);
        const rect = tabRect(strip, x, tabWidth(label_w + tip_reserve, cap));
        if (rect.x + theme.scaledUi(MIN_TAB_WIDTH_UI) > tabs_right) break;
        const clip: palette.Rect = .{ .x = strip.x, .y = strip.y, .w = @max(tabs_right - strip.x, 0.0), .h = strip.h };
        const selected = focused_tab_id != null and focused_tab_id.? == tab.id;
        const hovered = hovered_hit == strip_hit_count;
        renderTab(state, rect, clip, selected, hovered);
        var label_buf: [LABEL_BUFFER_LEN]u8 = undefined;
        const label_area: palette.Rect = .{ .x = rect.x, .y = rect.y, .w = @max(rect.w - tip_reserve, 0.0), .h = rect.h };
        const label = truncatedLabel(&label_buf, title, @max(label_area.w - pad_x * 2.0, 0.0), font_size);
        const shown_w = runtime.paletteUiTextPrefixWidth(label, font_size, label.len);
        const text_color = if (selected) theme.COLOR_WHITE else if (hovered) theme.lighten(theme.COLOR_TEXT_MUTED, 0.12) else theme.COLOR_TEXT_MUTED;
        queueCenteredText(state, label_area, label, shown_w, paletteColor(text_color), font_size, clip);
        if (key_tip.len > 0) renderTabKeyTip(state, rect, clip, key_tip);
        addHit(rect, .tab, project_index, tab.preferred_pane_id);
        x = rect.x + rect.w + gap;
    }
    const plus_rect = plusTabRect(strip, x);
    const plus_hovered = hovered_hit == strip_hit_count;
    renderTab(state, plus_rect, strip, false, plus_hovered);
    const plus_w_text = runtime.paletteUiTextPrefixWidth("+", font_size, 1);
    const plus_color = if (plus_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    queueCenteredText(state, plus_rect, "+", plus_w_text, paletteColor(plus_color), font_size, strip);
    addHit(plus_rect, .add_tab, project_index, 0);
}

/// One tab body: rectangular background with a hairline edge so adjacent
/// tabs separate cleanly; the active tab carries the accent tint.
fn renderTab(state: *runtime.AppState, rect: palette.Rect, clip: palette.Rect, selected: bool, hovered: bool) void {
    const radius = theme.scaledUi(TAB_RADIUS_UI);
    const fill: [4]f32 = if (selected)
        theme.withAlpha(theme.accent(), 64)
    else if (hovered)
        theme.lighten(theme.COLOR_PANEL_ALT, 0.06)
    else
        theme.COLOR_PANEL_ALT;
    queueRoundedRectClipped(state, rect, paletteColor(fill), radius, clip);
    const edge: [4]f32 = if (selected) theme.withAlpha(theme.accent(), 180) else theme.borderMuted();
    queueBorderClipped(state, rect, paletteColor(edge), radius, 1.0, clip);
}

/// Key label for the tab's Ctrl+N binding while plain Ctrl is held (the
/// Ctrl+Shift reveal belongs to the attention cluster, not tabs). Empty when
/// hints are hidden or the ordinal has no plain-Ctrl binding.
fn tabKeyTip(state: *const runtime.AppState, buf: []u8, tab_index: usize) []const u8 {
    if (!state.ctrl_shortcut_hints_visible or state.shift_shortcut_hints_visible) return "";
    const config = state.command_controller.keyboard_config orelse return "";
    return keybinds.formatCtrlKeyTipAt(buf, config.workspace_pane_select, tab_index);
}

/// Square key-tip badge at the tab's right edge, styled like the sidebar's
/// pane-row badge.
fn renderTabKeyTip(state: *runtime.AppState, tab: palette.Rect, clip: palette.Rect, label: []const u8) void {
    const size = theme.scaledUi(KEY_TIP_SIZE_UI);
    const rect: palette.Rect = .{
        .x = tab.x + tab.w - size - theme.scaledUi(KEY_TIP_INSET_X_UI),
        .y = tab.y + @max((tab.h - size) * 0.5, 0.0),
        .w = size,
        .h = @min(size, tab.h),
    };
    const radius = theme.scaledUi(KEY_TIP_RADIUS_UI);
    queueRoundedRectClipped(state, rect, paletteColor(theme.COLOR_PANEL_ALT), radius, clip);
    queueBorderClipped(state, rect, paletteColor(theme.borderMuted()), radius, 1.0, clip);
    const font_size = theme.scaledUi(KEY_TIP_FONT_UI);
    const text_w = runtime.paletteUiTextPrefixWidth(label, font_size, label.len);
    queueCenteredText(state, rect, label, text_w, paletteColor(theme.accent()), font_size, clip);
}

/// Truncates `label` with a trailing ellipsis so it fits `max_w` using
/// Palette text metrics, cutting only at UTF-8 codepoint boundaries.
pub fn truncatedLabel(buffer: *[LABEL_BUFFER_LEN]u8, label: []const u8, max_w: f32, font_size: f32) []const u8 {
    const ellipsis = "...";
    const bounded = label[0..@min(label.len, buffer.len - ellipsis.len)];
    if (text_measure.textWidth(.ui, font_size, bounded) <= max_w and bounded.len == label.len) return label;
    const ellipsis_w = text_measure.textWidth(.ui, font_size, ellipsis);
    var end: usize = 0;
    var fit_end: usize = 0;
    while (end < bounded.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(bounded[end]) catch 1;
        const next = @min(end + cp_len, bounded.len);
        if (text_measure.textPrefixWidth(.ui, bounded, font_size, next) + ellipsis_w > max_w) break;
        fit_end = next;
        end = next;
    }
    @memcpy(buffer[0..fit_end], bounded[0..fit_end]);
    @memcpy(buffer[fit_end .. fit_end + ellipsis.len], ellipsis);
    return buffer[0 .. fit_end + ellipsis.len];
}

/// Routes a strip click: a tab focuses its preferred pane through the same
/// path as a sidebar pane row (which also reveals it in the scrolling
/// strip); the "+" tab opens a new chat exactly like the sidebar "+".
pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    if (!isVisible(state) or !rectContains(strip_rect, x, y)) return false;
    if (!down) return true;
    if (hitAt(x, y)) |hit| activateHit(state, hit);
    return true;
}

pub fn activateHit(state: *runtime.AppState, hit: StripHit) void {
    if (hit.project_index >= state.project_controller.projects.items.len) return;
    switch (hit.kind) {
        .tab => state.focusWorkspaceOpenPaneFromSidebar(hit.project_index, hit.pane_id),
        .add_tab => state.addWorkspaceTab(hit.project_index, null),
    }
}

/// Tracks tab hover so the strip repaints only when the hovered tab changes.
pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32) void {
    const next = if (isVisible(state)) hitSlotAt(x, y) else null;
    if (next == hovered_hit) return;
    hovered_hit = next;
    state.markDirty();
}

pub fn systemCursorAt(x: f32, y: f32) ?sdl.SystemCursor {
    if (hitSlotAt(x, y) != null) return .pointer;
    return null;
}

fn hitSlotAt(x: f32, y: f32) ?usize {
    for (strip_hits[0..strip_hit_count], 0..) |hit, slot| {
        if (rectContains(hit.rect, x, y)) return slot;
    }
    return null;
}

fn hitAt(x: f32, y: f32) ?StripHit {
    const slot = hitSlotAt(x, y) orelse return null;
    return strip_hits[slot];
}

fn addHit(rect: palette.Rect, kind: HitKind, project_index: usize, pane_id: runtime.WorkspacePaneId) void {
    if (strip_hit_count >= strip_hits.len) return;
    strip_hits[strip_hit_count] = .{ .rect = rect, .kind = kind, .project_index = project_index, .pane_id = pane_id };
    strip_hit_count += 1;
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn queueRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch |err| {
        runtime.log.warn("failed to queue workspace strip rect: {s}", .{@errorName(err)});
    };
}

fn queueRoundedRectClipped(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, color, radius, clip) catch |err| {
        runtime.log.warn("failed to queue workspace strip tab: {s}", .{@errorName(err)});
    };
}

fn queueBorderClipped(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.rectBorderClipped(state.allocator, rect, color, radius, width, clip) catch |err| {
        runtime.log.warn("failed to queue workspace strip border: {s}", .{@errorName(err)});
    };
}

/// Centers a single line inside a tab: horizontally from the measured
/// width, vertically by offsetting the text line box within the tab height.
fn queueCenteredText(state: *runtime.AppState, tab: palette.Rect, value: []const u8, text_w: f32, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    const line_h = font_size * LINE_HEIGHT_FACTOR;
    const text_x = tab.x + @max((tab.w - text_w) * 0.5, 0.0);
    const text_y = tab.y + @max((tab.h - line_h) * 0.5, 0.0);
    queueText(state, .{ .x = text_x, .y = text_y, .w = @max(tab.x + tab.w - text_x, 0.0), .h = line_h }, value, color, font_size, clip);
}

fn queueText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    const stable_value = state.palette_frame_text_arena.allocator().dupe(u8, value) catch |err| {
        runtime.log.warn("failed to retain workspace strip text: {s}", .{@errorName(err)});
        return;
    };
    // Explicit .ui role so tabs use the same face as the sidebar/rail text
    // instead of the batch default.
    state.palette_overlay_batch.roleText(
        state.allocator,
        rect,
        stable_value,
        color,
        font_size,
        .ui,
        null,
        clip,
    ) catch |err| {
        runtime.log.warn("failed to queue workspace strip text: {s}", .{@errorName(err)});
    };
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn testState(projects: *std.ArrayList(runtime.Project)) runtime.AppState {
    var state: runtime.AppState = undefined;
    state.sidebar_collapsed = false;
    state.sidebar_hidden = false;
    state.app_config.workspace_tabs = .automatic;
    state.project_controller.projects = projects.*;
    state.project_controller.selected_index = 0;
    state.project_controller.show_creator = false;
    state.lifecycle = .{};
    state.project_directory_browse_requested = false;
    state.project_directory_picker_create_parent = false;
    state.project_directory_picker_start_home = false;
    state.import_path_storage[0] = 0;
    state.palette_modal_text_focus = .none;
    return state;
}

test "workspace strip is gated on a collapsed or hidden sidebar" {
    const allocator = std.testing.allocator;
    var projects: std.ArrayList(runtime.Project) = .empty;
    defer {
        for (projects.items) |*project| project.deinit(allocator);
        projects.deinit(allocator);
    }
    try projects.append(allocator, try runtime.Project.init(allocator, "ws-a", "alpha", "/tmp/alpha", 0));
    var state = testState(&projects);
    const workspace: palette.Rect = .{ .x = 300.0, .y = 0.0, .w = 900.0, .h = 700.0 };

    try std.testing.expect(!isVisible(&state));
    const visible_split = splitWorkspaceRect(&state, workspace);
    try std.testing.expect(visible_split.strip == null);
    try std.testing.expectEqual(workspace.h, visible_split.content.h);

    state.sidebar_collapsed = true;
    try std.testing.expect(isVisible(&state));
    state.sidebar_collapsed = false;
    state.sidebar_hidden = true;
    try std.testing.expect(isVisible(&state));

    // Height is subtracted exactly once and the strip starts at the pane region.
    const split = splitWorkspaceRect(&state, workspace);
    const strip = split.strip orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(workspace.x, strip.x);
    try std.testing.expectEqual(workspace.y, strip.y);
    try std.testing.expectEqual(workspace.w, strip.w);
    try std.testing.expectEqual(height(), strip.h);
    try std.testing.expectEqual(workspace.y + height(), split.content.y);
    try std.testing.expectEqual(workspace.h - height(), split.content.h);

    // Short-height windows never produce a negative content rect.
    const short = splitWorkspaceRect(&state, .{ .x = 0.0, .y = 0.0, .w = 400.0, .h = 10.0 });
    try std.testing.expectEqual(@as(f32, 0.0), short.content.h);
    try std.testing.expectEqual(@as(f32, 10.0), short.strip.?.h);

    // `always` shows the strip beside the expanded sidebar; `disabled`
    // suppresses it even when the sidebar is hidden.
    state.sidebar_hidden = false;
    state.app_config.workspace_tabs = .always;
    try std.testing.expect(isVisible(&state));
    try std.testing.expect(splitWorkspaceRect(&state, workspace).strip != null);
    state.sidebar_hidden = true;
    state.app_config.workspace_tabs = .disabled;
    try std.testing.expect(!isVisible(&state));
    try std.testing.expectEqual(workspace.h, splitWorkspaceRect(&state, workspace).content.h);
    state.app_config.workspace_tabs = .automatic;

    // No open workspaces: nothing to switch, so no reserved height.
    state.project_controller.projects = .empty;
    try std.testing.expect(!isVisible(&state));
}

test "workspace strip tabs are content-sized, uniformly tall, and never overlap" {
    const strip: palette.Rect = .{ .x = 100.0, .y = 0.0, .w = 1000.0, .h = STRIP_HEIGHT_UI };
    const cap = tabWidthCap(strip.w, 3);
    try std.testing.expectEqual(MAX_TAB_WIDTH_UI, cap);

    // A short label yields a compact tab: label plus balanced padding.
    const short_w = tabWidth(40.0, cap);
    try std.testing.expectEqual(40.0 + TAB_PAD_X_UI * 2.0, short_w);
    // A long label stops at the cap instead of growing without bound.
    try std.testing.expectEqual(cap, tabWidth(900.0, cap));

    // Every tab shares one height inset from the strip edges.
    const first = tabRect(strip, strip.x, short_w);
    const second = tabRect(strip, first.x + first.w + TAB_GAP_UI, cap);
    try std.testing.expectEqual(STRIP_HEIGHT_UI - TAB_INSET_Y_UI * 2.0, first.h);
    try std.testing.expectEqual(first.h, second.h);
    try std.testing.expectEqual(first.y, second.y);
    try std.testing.expectEqual(first.x + first.w + TAB_GAP_UI, second.x);

    // Laptop-width strip with many workspaces: the cap shrinks so all tabs
    // plus the "+" tab fit inside the strip.
    const narrow_w: f32 = 600.0;
    const many: usize = 8;
    const narrow_cap = tabWidthCap(narrow_w, many);
    try std.testing.expect(narrow_cap < MAX_TAB_WIDTH_UI);
    const count: f32 = @floatFromInt(many);
    try std.testing.expect(narrow_cap * count + TAB_GAP_UI * count + PLUS_TAB_WIDTH_UI + STRIP_PAD_X_UI * 2.0 <= narrow_w + 0.5);

    // Extremely narrow strips bottom out at the readable minimum.
    try std.testing.expectEqual(MIN_TAB_WIDTH_UI, tabWidthCap(120.0, 10));
    try std.testing.expectEqual(@as(f32, 0.0), tabWidthCap(600.0, 0));
}

test "workspace strip plus tab trails the last tab and stays inside the strip" {
    const strip: palette.Rect = .{ .x = 50.0, .y = 0.0, .w = 500.0, .h = STRIP_HEIGHT_UI };
    const trailing = plusTabRect(strip, 200.0);
    try std.testing.expectEqual(@as(f32, 200.0), trailing.x);
    try std.testing.expectEqual(PLUS_TAB_WIDTH_UI, trailing.w);
    try std.testing.expectEqual(STRIP_HEIGHT_UI - TAB_INSET_Y_UI * 2.0, trailing.h);

    // Overflow pins the "+" to the right edge instead of pushing it off-screen.
    const pinned = plusTabRect(strip, 5000.0);
    try std.testing.expectEqual(strip.x + strip.w - STRIP_PAD_X_UI - PLUS_TAB_WIDTH_UI, pinned.x);
    try std.testing.expect(pinned.x + pinned.w <= strip.x + strip.w - STRIP_PAD_X_UI);
    // Vertically centered: equal space above and below the text line box.
    const line_h = LABEL_FONT_UI * LINE_HEIGHT_FACTOR;
    try std.testing.expect(trailing.h >= line_h);
}

test "workspace strip labels truncate with an ellipsis using text metrics" {
    var buffer: [LABEL_BUFFER_LEN]u8 = undefined;
    const label = "a-very-long-workspace-name-that-cannot-fit";
    const font_size = LABEL_FONT_UI;
    const full_w = text_measure.textWidth(.ui, font_size, label);
    try std.testing.expectEqualStrings(label, truncatedLabel(&buffer, label, full_w, font_size));

    const truncated = truncatedLabel(&buffer, label, full_w * 0.5, font_size);
    try std.testing.expect(truncated.len < label.len);
    try std.testing.expect(std.mem.endsWith(u8, truncated, "..."));
    try std.testing.expect(text_measure.textWidth(.ui, font_size, truncated) <= full_w * 0.5 + 0.5);

    // Nothing fits: only the ellipsis remains rather than a partial glyph.
    try std.testing.expectEqualStrings("...", truncatedLabel(&buffer, label, 0.0, font_size));
}

test "workspace strip hits resolve tabs and the add-tab button" {
    const allocator = std.testing.allocator;
    var projects: std.ArrayList(runtime.Project) = .empty;
    defer {
        for (projects.items) |*project| project.deinit(allocator);
        projects.deinit(allocator);
    }
    try projects.append(allocator, try runtime.Project.init(allocator, "ws-a", "alpha", "/tmp/alpha", 0));
    var state = testState(&projects);
    state.sidebar_hidden = true;

    strip_rect = .{ .x = 0.0, .y = 0.0, .w = 800.0, .h = STRIP_HEIGHT_UI };
    strip_hit_count = 0;
    defer strip_hit_count = 0;
    const cap = tabWidthCap(strip_rect.w, 2);
    const first = tabRect(strip_rect, strip_rect.x, tabWidth(40.0, cap));
    const second = tabRect(strip_rect, first.x + first.w + TAB_GAP_UI, tabWidth(40.0, cap));
    const plus = plusTabRect(strip_rect, second.x + second.w + TAB_GAP_UI);
    addHit(first, .tab, 0, 1);
    addHit(second, .tab, 0, 7);
    addHit(plus, .add_tab, 0, 0);

    const second_hit = hitAt(second.x + 1.0, second.y + 1.0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(HitKind.tab, second_hit.kind);
    try std.testing.expectEqual(@as(usize, 0), second_hit.project_index);
    try std.testing.expectEqual(@as(runtime.WorkspacePaneId, 7), second_hit.pane_id);
    const plus_hit = hitAt(plus.x + plus.w * 0.5, plus.y + plus.h * 0.5) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(HitKind.add_tab, plus_hit.kind);
    try std.testing.expectEqual(@as(?usize, null), hitSlotAt(plus.x + plus.w + 10.0, plus.y));
    try std.testing.expectEqual(@as(?sdl.SystemCursor, .pointer), systemCursorAt(plus.x + 1.0, plus.y + 1.0));

    // Clicks outside the strip fall through to pane handlers.
    try std.testing.expect(!handlePaletteMouseButton(&state, 10.0, STRIP_HEIGHT_UI + 50.0, true));
    // A hidden strip owns no pointer input even with stale hits.
    state.sidebar_hidden = false;
    try std.testing.expect(!handlePaletteMouseButton(&state, second.x + 1.0, second.y + 1.0, true));
}

fn fullTestState(allocator: std.mem.Allocator, storage: *storage_mod.Storage) !runtime.AppState {
    var state = try runtime.AppState.init(allocator, storage, app_config.AppConfig{}, .{
        .gl_texture_uploads_enabled = false,
        .browser_textures_enabled = false,
    });
    errdefer {
        state.lifecycle.clearDirty();
        state.deinit();
    }
    for (state.project_controller.projects.items) |*project| project.deinit(allocator);
    state.project_controller.projects.clearRetainingCapacity();
    state.lifecycle.clearDirty();
    var project = try runtime.Project.init(allocator, "tabs", "Tabs", "/tmp/tabs", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    state.project_controller.selected_index = 0;
    return state;
}

test "workspace strip tabs follow tiles: a split tile is one tab and activation focuses its pane" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try storage_mod.Storage.initWithPrefPath(allocator, path_buf[0..path_len]);
    defer storage.deinit();
    var state = try fullTestState(allocator, &storage);
    defer {
        state.lifecycle.clearDirty();
        state.deinit();
    }
    state.sidebar_collapsed = true;

    const first_pane_id = state.project_controller.projects.items[0].workspace_layout.focused_pane_id orelse return error.TestExpectedEqual;
    // Header-menu split welds the new pane into the first tab.
    try std.testing.expect(state.splitCurrentProjectWorkspacePaneTiledWithChatPlacement(first_pane_id, .vertical, true));
    var layout = &state.project_controller.projects.items[0].workspace_layout;
    const tiled_pane_id = layout.focused_pane_id orelse return error.TestExpectedEqual;
    var tab_buffer: [runtime.workspace_tabs.MAX_WORKSPACE_TABS]runtime.WorkspaceTab = undefined;
    var tabs = runtime.workspace_tabs.collect(layout, &tab_buffer);
    try std.testing.expectEqual(@as(usize, 1), tabs.len);
    try std.testing.expectEqual(@as(usize, 2), tabs[0].pane_count);
    try std.testing.expectEqual(@as(?runtime.WorkspaceTabId, tabs[0].id), runtime.workspace_tabs.focusedTabId(layout));

    // The "+" tab opens a new chat (the default `workspace_new_tab_pane`) as its own tab, in the same workspace.
    try std.testing.expectEqual(app_config.WorkspaceSplitDefaultPane.chat, state.app_config.workspace_new_tab_pane);
    activateHit(&state, .{ .rect = .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 }, .kind = .add_tab, .project_index = 0, .pane_id = 0 });
    layout = &state.project_controller.projects.items[0].workspace_layout;
    tabs = runtime.workspace_tabs.collect(layout, &tab_buffer);
    try std.testing.expectEqual(@as(usize, 2), tabs.len);
    try std.testing.expectEqual(@as(usize, 1), tabs[1].pane_count);
    try std.testing.expectEqual(@as(?runtime.WorkspaceTabId, tabs[1].id), runtime.workspace_tabs.focusedTabId(layout));
    try std.testing.expectEqual(@as(usize, 1), state.project_controller.projects.items.len);
    try std.testing.expect(state.sidebar_collapsed);

    // Activating the first tab returns focus to its preferred pane.
    activateHit(&state, .{ .rect = .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 }, .kind = .tab, .project_index = 0, .pane_id = tabs[0].preferred_pane_id });
    layout = &state.project_controller.projects.items[0].workspace_layout;
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, tabs[0].preferred_pane_id), layout.focused_pane_id);
    try std.testing.expect(layout.panesShareScrollGroup(first_pane_id, tiled_pane_id));
    try std.testing.expectEqual(@as(?runtime.WorkspaceTabId, tabs[0].id), runtime.workspace_tabs.focusedTabId(layout));
    // Tab labels resolve through the pane title (both tiled panes are chats).
    try std.testing.expect(tabLabel(&state, 0, tabs[0]).len > 0);
}
