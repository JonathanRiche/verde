//! Compact horizontal tab strip across the top of the pane region: one tab per
//! workspace tab (see `state/workspace_tabs.zig`) of the selected workspace,
//! plus a trailing "+" that opens a new chat tab. Workspace switching stays in
//! the sidebar rail.

const std = @import("std");
const palette = @import("palette");
const app_config = @import("../app/config.zig");
const keybinds = @import("../app/keybinds.zig");
const storage_mod = @import("../state/storage.zig");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");
const runtime = @import("runtime.zig");
const sidebar = @import("sidebar.zig");
const chat_panel = @import("chat_panel.zig");
const workspace_panes = @import("workspace_panes.zig");
const profiler = @import("../runtime/profiler.zig");

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
/// Narrowest tab: provider glyph plus a readable title (~12 characters).
/// Tabs never shrink below it; extra tabs overflow and the strip scrolls.
pub const MIN_TAB_WIDTH_UI: f32 = 132.0;
/// Widest tab; keeps long labels from swallowing the strip on wide windows.
pub const MAX_TAB_WIDTH_UI: f32 = 220.0;
/// Leading pane-kind glyph (provider logo, terminal, globe, file icon).
const ICON_SLOT_UI: f32 = 16.0;
const ICON_GAP_UI: f32 = 7.0;
/// Horizontal scroll per wheel notch over an overflowing strip.
const WHEEL_STEP_UI: f32 = 64.0;
/// Overflow chevron buttons reserved at both ends of the tab viewport while
/// tabs run off it, and the fade that softens the clipped tab edge.
const OVERFLOW_CHEVRON_W_UI: f32 = 22.0;
const OVERFLOW_CHEVRON_GLYPH_UI: f32 = 12.0;
const OVERFLOW_FADE_W_UI: f32 = 24.0;
const OVERFLOW_FADE_STEPS: usize = 6;
const NF_COD_CHEVRON_LEFT = "\u{EAB5}";
const NF_COD_CHEVRON_RIGHT = "\u{EAB6}";
/// Adjacent tabs are separated by a hairline gap instead of a border so they
/// read as one tab row (Herdr-style) rather than floating pills.
pub const TAB_GAP_UI: f32 = 3.0;
pub const TAB_PAD_X_UI: f32 = 12.0;
/// The trailing "+" tab is square-ish: tab height plus a little side padding
/// so the glyph has a comfortable hit target without reading as a label tab.
pub const PLUS_TAB_WIDTH_UI: f32 = 30.0;
const LABEL_FONT_UI: f32 = 13.0;
const TAB_RADIUS_UI: f32 = 3.0;
const PIP_SIZE_UI: f32 = 6.0;
const PIP_GAP_UI: f32 = 6.0;
/// Ctrl-reveal key tip: same square badge the sidebar pane rows draw so the
/// Ctrl+N ordinal reads identically in both places.
const KEY_TIP_SIZE_UI: f32 = 18.0;
const KEY_TIP_FONT_UI: f32 = 11.0;
const KEY_TIP_RADIUS_UI: f32 = 5.0;
const KEY_TIP_INSET_X_UI: f32 = 4.0;
/// Close X on closable tabs (file viewer tabs), right-aligned in the tab.
const CLOSE_SIZE_UI: f32 = 18.0;
const CLOSE_GLYPH_UI: f32 = 12.0;
const CLOSE_INSET_X_UI: f32 = 4.0;
const NF_COD_CLOSE = "\u{EA76}";
/// Same line box the other Palette UI text queues use (see sidebar/layout).
const LINE_HEIGHT_FACTOR: f32 = 1.25;
/// Bounded label buffer; tabs are short so longer titles are truncated.
const LABEL_BUFFER_LEN: usize = 96;

/// `sidebar_toggle` is the leading show-sidebar button drawn while the rail
/// is hidden (the old collapsed rail carried it; the hidden rail cannot).
/// `side_panel_toggle` is the trailing show/hide for the tab's right panel.
/// `close_tab` is the X on closable (file viewer) tabs; it precedes its
/// tab's hit so it wins the overlap.
/// `scroll_left`/`scroll_right` are the overflow chevrons at the ends of
/// an overflowing tab row.
pub const HitKind = enum { tab, add_tab, sidebar_toggle, side_panel_toggle, close_tab, scroll_left, scroll_right };

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
/// Horizontal scroll of the tab row when tabs overflow (pixels).
var scroll_x: f32 = 0.0;
var max_scroll_x: f32 = 0.0;
/// Visible tab viewport width; a chevron click scrolls most of one page.
var page_w: f32 = 0.0;
/// Re-reveal the focused tab only when focus or the viewport changes, so a
/// wheel scroll is not undone on the next frame.
var revealed_tab_id: ?runtime.workspace_tabs.WorkspaceTabId = null;
var revealed_viewport_w: f32 = 0.0;

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
    if (!isVisible(state)) {
        // No strip this frame: drop the stale rect so wheel/hover routing
        // (which has no state access) cannot claim the old region.
        strip_rect = .{};
        strip_hit_count = 0;
        return .{ .strip = null, .content = workspace };
    }
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
    // The side panel toggle keeps the last slot at the right edge.
    const toggle_slot = w + theme.scaledUi(TAB_GAP_UI);
    const x = @min(after_x, strip.x + strip.w - pad - toggle_slot - w);
    return tabRect(strip, @max(x, strip.x + pad), w);
}

/// Label shown on a tab: the title of its preferred pane (the last-focused
/// child of a split tile), so a chat│terminal tile reads as the chat you
/// were working in rather than an arbitrary member.
pub fn tabLabel(state: *const runtime.AppState, project_index: usize, tab: runtime.WorkspaceTab, term_title_buf: *sidebar.TerminalTitleBuffer) []const u8 {
    const project = &state.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(tab.preferred_pane_id) orelse return "Pane";
    return sidebar.paneTitle(state, project_index, project, pane, term_title_buf);
}

/// Tab strip: a Herdr-style row of rectangular tabs along the top of the
/// pane region, one per tab of the selected workspace (a split tile is one
/// tab) plus a trailing "+" tab. Rendered only when the sidebar is collapsed
/// or hidden. Tabs keep a readable minimum width; when they overflow, the
/// row scrolls horizontally (mouse wheel) and keeps the focused tab in view.
pub fn render(state: *runtime.AppState, strip: palette.Rect) void {
    strip_hit_count = 0;
    strip_rect = strip;
    queueRect(state, strip, paletteColor(theme.COLOR_PANEL));
    // Neutral hairline under the strip, drawn last so nothing covers it.
    // (The accent belongs to the focused pane, not this chrome.)
    defer queueBottomRule(state, strip);
    if (state.project_controller.projects.items.len == 0) return;
    const project_index = state.project_controller.selected_index;
    const project = &state.project_controller.projects.items[project_index];
    const layout = &project.workspace_layout;
    const arena = state.palette_frame_text_arena.allocator();
    const tab_buffer = arena.alloc(runtime.WorkspaceTab, layout.panes.items.len) catch return;
    const tabs = runtime.workspace_tabs.collect(layout, tab_buffer);
    const focused_tab_id = runtime.workspace_tabs.focusedTabId(layout);
    const gap = theme.scaledUi(TAB_GAP_UI);
    // Hidden sidebar: a leading show-sidebar button takes the first slot so
    // the rail can be brought back without a keybind or edge hover.
    const leading_w = if (state.isSidebarHidden()) theme.scaledUi(PLUS_TAB_WIDTH_UI) + gap else 0.0;
    const cap = tabWidthCap(strip.w - leading_w, tabs.len);
    const font_size = theme.scaledUi(LABEL_FONT_UI);
    const pad_x = theme.scaledUi(TAB_PAD_X_UI);
    const plus_w = theme.scaledUi(PLUS_TAB_WIDTH_UI);
    const strip_pad = theme.scaledUi(STRIP_PAD_X_UI);
    const icon_slot = theme.scaledUi(ICON_SLOT_UI);
    const icon_reserve = icon_slot + theme.scaledUi(ICON_GAP_UI);
    // The side panel toggle owns the right edge; tabs may not run under it
    // or the "+" tab's reserved slot.
    const toggle_slot_w = plus_w + gap;
    const tabs_right = strip.x + strip.w - strip_pad - toggle_slot_w - plus_w - gap;
    // Holding Ctrl reveals the Ctrl+N ordinal of each tab, mirroring the
    // sidebar pane rows; the badge takes a slot at the tab's right edge.
    const key_tip_w = theme.scaledUi(KEY_TIP_SIZE_UI) + theme.scaledUi(KEY_TIP_INSET_X_UI);
    var x = strip.x + strip_pad;
    if (leading_w > 0.0) {
        const toggle_rect = tabRect(strip, x, theme.scaledUi(PLUS_TAB_WIDTH_UI));
        const toggle_hovered = hovered_hit == strip_hit_count;
        if (toggle_hovered) queueRoundedRectClipped(state, toggle_rect, paletteColor(sidebar.hoverFill()), theme.scaledUi(TAB_RADIUS_UI), strip);
        sidebar.queueSidebarToggleGlyph(state, toggle_rect, false, toggle_hovered, strip);
        // The hidden rail's ACTIVE section is out of view: badge the toggle
        // when another workspace has a working/waiting pane, and say so in
        // the toggle's tooltip so the dot is never unexplained.
        const background = backgroundActivityPip(state, project_index);
        if (background) |bg| queueCountBadge(state, toggle_rect, strip, bg.working + bg.waiting, bg.pip.color);
        addHit(toggle_rect, .sidebar_toggle, project_index, 0);
        const toggle_tip = sidebar.shortcutTooltip(state, "Show sidebar", "toggle_sidebar_hidden");
        const tip = if (background) |bg| blk: {
            var activity_buf: [64]u8 = undefined;
            const activity = backgroundActivityLabel(&activity_buf, bg.working, bg.waiting);
            break :blk std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s} · {s}", .{ toggle_tip, activity }) catch toggle_tip;
        } else toggle_tip;
        // The toggle sits at the window's left edge, so below means over the
        // pane title and terminal text. Protect the toggle and the pane title
        // band but NOT the strip row: the tooltip solver can then put this
        // short label beside the toggle, inside the strip, over neighbouring
        // tabs, without relying on its "containing chrome row" exception.
        const avoid = [_]palette.Rect{ toggle_rect, paneTitleBand(layout, strip) };
        sidebar.offerTooltipAvoiding(state, toggle_rect, tip, &avoid);
        x += leading_w;
    }

    // Tabs scroll inside this viewport; the toggle, "+" and side panel
    // toggle stay pinned outside it.
    var viewport: palette.Rect = .{ .x = x, .y = strip.y, .w = @max(tabs_right - x, 0.0), .h = strip.h };

    // Measure pass: every tab's width and offset, so the overflow extent
    // and the focused tab's offset are known before anything is drawn.
    const widths = arena.alloc(f32, tabs.len) catch return;
    const lefts = arena.alloc(f32, tabs.len) catch return;
    var content_w: f32 = 0.0;
    var focused_left: ?f32 = null;
    var focused_w: f32 = 0.0;
    for (tabs, 0..) |tab, tab_index| {
        var term_title_buf: sidebar.TerminalTitleBuffer = undefined;
        const title = tabLabel(state, project_index, tab, &term_title_buf);
        var key_tip_buf: [16]u8 = undefined;
        const tip_reserve = tabTrailingReserve(state, layout, tab, tab_index, &key_tip_buf, key_tip_w);
        const pip_reserve = if (tabActivityPip(state, project_index, layout, tab.id) != null) theme.scaledUi(PIP_SIZE_UI) + theme.scaledUi(PIP_GAP_UI) else 0.0;
        // Measure through the GPU text path so tab widths match drawn glyphs.
        const label_w = runtime.paletteUiTextPrefixWidth(title, font_size, title.len);
        widths[tab_index] = tabWidth(label_w + icon_reserve + tip_reserve + pip_reserve, cap);
        if (tab_index > 0) content_w += gap;
        lefts[tab_index] = content_w;
        if (focused_tab_id != null and focused_tab_id.? == tab.id) {
            focused_left = content_w;
            focused_w = widths[tab_index];
        }
        content_w += widths[tab_index];
    }
    // Overflowing tabs give up a chevron slot at each end of the viewport
    // (both, so the row does not jump when one end is reached).
    const chevron_w = theme.scaledUi(OVERFLOW_CHEVRON_W_UI);
    const overflowing = content_w > viewport.w + 0.5 and viewport.w > chevron_w * 4.0;
    var left_chevron: palette.Rect = .{};
    var right_chevron: palette.Rect = .{};
    if (overflowing) {
        left_chevron = tabRect(strip, viewport.x, chevron_w);
        right_chevron = tabRect(strip, viewport.x + viewport.w - chevron_w, chevron_w);
        viewport.x += chevron_w + gap;
        viewport.w = @max(viewport.w - (chevron_w + gap) * 2.0, 0.0);
    }
    page_w = viewport.w;
    max_scroll_x = @max(content_w - viewport.w, 0.0);
    if (focused_tab_id != revealed_tab_id or viewport.w != revealed_viewport_w) {
        if (focused_left) |left| scroll_x = revealSpan(scroll_x, left, focused_w, viewport.w);
        revealed_tab_id = focused_tab_id;
        revealed_viewport_w = viewport.w;
    }
    scroll_x = theme.clampf(scroll_x, 0.0, max_scroll_x);

    // Chevron hits register before the tabs so they win any overlap; a
    // chevron with nothing left to reveal is drawn dimmed with no hit.
    const hidden = hiddenTabCounts(lefts, widths, scroll_x, viewport.w);
    const left_slot: ?usize = if (overflowing and hidden.before > 0) strip_hit_count else null;
    if (left_slot != null) addHit(left_chevron, .scroll_left, project_index, 0);
    const right_slot: ?usize = if (overflowing and hidden.after > 0) strip_hit_count else null;
    if (right_slot != null) addHit(right_chevron, .scroll_right, project_index, 0);

    x = viewport.x - scroll_x;
    for (tabs, 0..) |tab, tab_index| {
        const rect = tabRect(strip, x, widths[tab_index]);
        x = rect.x + rect.w + gap;
        // Off-screen tabs cost nothing and register no hits.
        const visible = intersect(rect, viewport) orelse continue;
        // Backs a terminal tab's live title for the measure + draw below.
        var term_title_buf: sidebar.TerminalTitleBuffer = undefined;
        const title = tabLabel(state, project_index, tab, &term_title_buf);
        var key_tip_buf: [16]u8 = undefined;
        const key_tip = tabKeyTip(state, &key_tip_buf, tab_index);
        const tip_reserve = tabTrailingReserve(state, layout, tab, tab_index, &key_tip_buf, key_tip_w);
        const closable = tabClosable(layout, tab);
        const pip = tabActivityPip(state, project_index, layout, tab.id);
        const pip_reserve = if (pip != null) theme.scaledUi(PIP_SIZE_UI) + theme.scaledUi(PIP_GAP_UI) else 0.0;
        const clip = viewport;
        const selected = focused_tab_id != null and focused_tab_id.? == tab.id;
        // A closable tab registers its X first, so the tab's own slot follows.
        const show_close = closable and key_tip.len == 0;
        const close_slot = strip_hit_count;
        const tab_slot = if (show_close) strip_hit_count + 1 else strip_hit_count;
        const close_hovered = show_close and hovered_hit == close_slot;
        const hovered = hovered_hit == tab_slot or close_hovered;
        renderTab(state, rect, clip, selected, hovered);
        const cy = rect.y + rect.h * 0.5;
        var content_x = rect.x + pad_x * 0.75;
        if (pip) |p| {
            // Same status mark as the sidebar pane rows, leading the tab.
            const dot = theme.scaledUi(PIP_SIZE_UI);
            const alpha: f32 = if (p.animated) sidebar.pipPulse(state, project_index) else 1.0;
            sidebar.queueStatusMark(state, p.mark, content_x + dot * 0.5, cy, p.color, alpha, clip);
            content_x += pip_reserve;
        }
        if (layout.paneById(tab.preferred_pane_id)) |pane| {
            sidebar.queuePaneGlyph(state, project_index, project, pane, .{ .x = content_x, .y = cy - icon_slot * 0.5, .w = icon_slot, .h = icon_slot }, clip);
        }
        content_x += icon_reserve;
        var label_buf: [LABEL_BUFFER_LEN]u8 = undefined;
        const label_right = rect.x + rect.w - @max(tip_reserve, pad_x * 0.75);
        const label = truncatedLabel(&label_buf, title, @max(label_right - content_x, 0.0), font_size);
        const text_color = if (selected) theme.COLOR_WHITE else if (hovered) theme.raise(theme.COLOR_TEXT_MUTED, 0.12) else theme.COLOR_TEXT_MUTED;
        const line_h = font_size * LINE_HEIGHT_FACTOR;
        queueText(state, .{ .x = content_x, .y = rect.y + @max((rect.h - line_h) * 0.5, 0.0), .w = @max(label_right - content_x, 0.0), .h = line_h }, label, paletteColor(text_color), font_size, clip);
        if (key_tip.len > 0) renderTabKeyTip(state, rect, clip, key_tip);
        if (show_close) renderTabClose(state, rect, clip, project_index, tab.preferred_pane_id, selected or hovered, close_hovered);
        addHit(visible, .tab, project_index, tab.preferred_pane_id);
        // Truncated titles (and tabs half scrolled out) show the full title.
        if (label.ptr != title.ptr or label.len != title.len or visible.w < rect.w) offerStripTooltip(state, visible, title);
    }
    if (overflowing) {
        if (hidden.before > 0) queueOverflowFade(state, viewport, .left);
        if (hidden.after > 0) queueOverflowFade(state, viewport, .right);
        renderOverflowChevron(state, left_chevron, strip, .left, left_slot, hidden.before);
        renderOverflowChevron(state, right_chevron, strip, .right, right_slot, hidden.after);
    }
    // The "+" follows the last tab, or the right chevron while overflowing.
    const plus_x = if (overflowing) right_chevron.x + right_chevron.w + gap else @min(x, viewport.x + viewport.w + gap);
    const plus_rect = plusTabRect(strip, plus_x);
    const plus_hovered = hovered_hit == strip_hit_count;
    renderTab(state, plus_rect, strip, false, plus_hovered);
    const plus_w_text = runtime.paletteUiTextPrefixWidth("+", font_size, 1);
    const plus_color = if (plus_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    queueCenteredText(state, plus_rect, "+", plus_w_text, paletteColor(plus_color), font_size, strip);
    addHit(plus_rect, .add_tab, project_index, 0);
    offerStripTooltip(state, plus_rect, "New tab");
    renderSidePanelToggle(state, strip, tabRect(strip, strip.x + strip.w - strip_pad - plus_w, plus_w), project_index);
}

/// Header band of the panes directly under the strip: full strip width,
/// as tall as the focused pane's header (last frame's recorded rect), so a
/// tooltip that avoids it clears every pane title in the row.
fn paneTitleBand(layout: *const runtime.WorkspaceLayout, strip: palette.Rect) palette.Rect {
    const top = strip.y + strip.h;
    const header_h = blk: {
        const pane_id = layout.focused_pane_id orelse break :blk theme.scaledUi(PANE_TITLE_BAND_FALLBACK_UI);
        const pane = workspace_panes.recordedPaneRect(pane_id) orelse break :blk theme.scaledUi(PANE_TITLE_BAND_FALLBACK_UI);
        break :blk chat_panel.paneHeaderHeight(pane) + @max(pane.y - top, 0.0);
    };
    return .{ .x = strip.x, .y = top, .w = strip.w, .h = header_h };
}

/// Pane header height used before any pane rect has been recorded.
const PANE_TITLE_BAND_FALLBACK_UI: f32 = 42.0;

/// Strip control tooltip (tab, "+", overflow chevron, right-panel toggle):
/// kept off the strip row it describes, like the header tooltips.
fn offerStripTooltip(state: *runtime.AppState, target: palette.Rect, label: []const u8) void {
    sidebar.offerTooltipAvoiding(state, target, label, &.{strip_rect});
}

const OverflowSide = enum { left, right };

/// Tabs at least partly scrolled out of the viewport before/after it.
fn hiddenTabCounts(lefts: []const f32, widths: []const f32, scroll: f32, view_w: f32) struct { before: usize, after: usize } {
    var before: usize = 0;
    var after: usize = 0;
    for (lefts, widths) |left, w| {
        if (left < scroll - 0.5) before += 1;
        if (left + w > scroll + view_w + 0.5) after += 1;
    }
    return .{ .before = before, .after = after };
}

/// Softens the clipped edge of the tab row: stepped strip-colour bands
/// (Palette has no gradient primitive), opaque at the viewport edge and
/// fading toward the tabs.
fn queueOverflowFade(state: *runtime.AppState, viewport: palette.Rect, side: OverflowSide) void {
    const fade_w = @min(theme.scaledUi(OVERFLOW_FADE_W_UI), viewport.w * 0.25);
    if (fade_w < 1.0) return;
    const steps: f32 = @floatFromInt(OVERFLOW_FADE_STEPS);
    var i: usize = 0;
    while (i < OVERFLOW_FADE_STEPS) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        // Band 0 touches the edge; alpha falls linearly to ~0 at the tabs.
        const inner = @round(fade_w * fi / steps);
        const outer = @round(fade_w * (fi + 1.0) / steps);
        if (outer <= inner) continue;
        const alpha = 1.0 - fi / steps;
        const x = switch (side) {
            .left => @round(viewport.x) + inner,
            .right => @round(viewport.x + viewport.w) - outer,
        };
        queueRect(state, .{ .x = x, .y = viewport.y, .w = outer - inner, .h = viewport.h }, paletteColor(theme.withAlpha(theme.COLOR_PANEL, @intFromFloat(alpha * 255.0))));
    }
}

/// Overflow chevron: a tab-shaped button that pages the row toward hidden
/// tabs; tooltip says how many are out of view. Dimmed (no hit) when that
/// side has nothing hidden.
fn renderOverflowChevron(state: *runtime.AppState, rect: palette.Rect, strip: palette.Rect, side: OverflowSide, slot: ?usize, hidden_count: usize) void {
    const enabled = slot != null;
    const hovered = enabled and hovered_hit == slot.?;
    renderTab(state, rect, strip, false, hovered);
    const glyph = switch (side) {
        .left => NF_COD_CHEVRON_LEFT,
        .right => NF_COD_CHEVRON_RIGHT,
    };
    const size = theme.scaledUi(OVERFLOW_CHEVRON_GLYPH_UI);
    const glyph_w = text_measure.textWidth(.icon, size, glyph);
    const color = if (!enabled) theme.COLOR_TEXT_SUBTLE else if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    state.palette_overlay_batch.roleText(state.allocator, .{
        .x = @round(rect.x + (rect.w - glyph_w) * 0.5),
        .y = rect.y + (rect.h - size * 1.3) * 0.5,
        .w = glyph_w,
        .h = size * 1.3,
    }, glyph, paletteColor(color), size, .icon, null, strip) catch {};
    if (!enabled) return;
    var label_buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{d} more tab{s}", .{ hidden_count, if (hidden_count == 1) "" else "s" }) catch "More tabs";
    offerStripTooltip(state, rect, label);
}

/// One whole-pixel neutral rule along the strip's bottom edge.
fn queueBottomRule(state: *runtime.AppState, strip: palette.Rect) void {
    const t = @max(@round(theme.scaledUi(1.0)), 1.0);
    const left = @round(strip.x);
    const bottom = @round(strip.y + strip.h);
    queueRect(state, .{ .x = left, .y = bottom - t, .w = @round(strip.x + strip.w) - left, .h = t }, paletteColor(theme.borderMuted()));
}

/// Width a tab reserves at its trailing edge: the Ctrl+N key tip while Ctrl
/// is held, else the close X of closable tabs.
fn tabTrailingReserve(
    state: *const runtime.AppState,
    layout: *const runtime.WorkspaceLayout,
    tab: runtime.WorkspaceTab,
    tab_index: usize,
    key_tip_buf: []u8,
    key_tip_w: f32,
) f32 {
    if (tabKeyTip(state, key_tip_buf, tab_index).len > 0) return key_tip_w;
    if (tabClosable(layout, tab)) return theme.scaledUi(CLOSE_SIZE_UI) + theme.scaledUi(CLOSE_INSET_X_UI);
    return 0.0;
}

/// Scroll offset that brings the span [`left`, `left + w`) fully into a
/// viewport of width `view_w`, moving as little as possible.
fn revealSpan(current: f32, left: f32, w: f32, view_w: f32) f32 {
    if (left < current) return left;
    if (left + w > current + view_w) return left + w - view_w;
    return current;
}

/// Scroll offset after paging the tab row one step: most of a viewport, so
/// the tab cut at the edge stays visible as context.
fn pagedScroll(current: f32, max_scroll: f32, view_w: f32, forward: bool) f32 {
    const step = @max(view_w * 0.75, 1.0);
    return theme.clampf(if (forward) current + step else current - step, 0.0, max_scroll);
}

test "overflow chevrons page the tab row and count hidden tabs" {
    try std.testing.expectEqual(@as(f32, 75.0), pagedScroll(0.0, 500.0, 100.0, true));
    try std.testing.expectEqual(@as(f32, 0.0), pagedScroll(50.0, 500.0, 100.0, false));
    try std.testing.expectEqual(@as(f32, 500.0), pagedScroll(480.0, 500.0, 100.0, true));
    const lefts = [_]f32{ 0.0, 103.0, 206.0, 309.0 };
    const widths = [_]f32{ 100.0, 100.0, 100.0, 100.0 };
    const at_start = hiddenTabCounts(&lefts, &widths, 0.0, 250.0);
    try std.testing.expectEqual(@as(usize, 0), at_start.before);
    try std.testing.expectEqual(@as(usize, 2), at_start.after);
    const mid = hiddenTabCounts(&lefts, &widths, 120.0, 250.0);
    try std.testing.expectEqual(@as(usize, 2), mid.before);
    try std.testing.expectEqual(@as(usize, 1), mid.after);
}

/// Wheel over an overflowing strip scrolls the tabs horizontally (wheel up
/// = toward the first tab). Routed through `sidebar.handlePaletteWheel`.
pub fn handleWheel(x: f32, y: f32, wheel_y: f32) bool {
    if (wheel_y == 0.0 or strip_rect.w <= 0.0 or !rectContains(strip_rect, x, y)) return false;
    if (max_scroll_x <= 0.0) return true;
    scroll_x = theme.clampf(scroll_x - wheel_y * theme.scaledUi(WHEEL_STEP_UI), 0.0, max_scroll_x);
    return true;
}

fn intersect(a: palette.Rect, b: palette.Rect) ?palette.Rect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
}

fn renderSidePanelToggle(state: *runtime.AppState, strip: palette.Rect, rect: palette.Rect, project_index: usize) void {
    const hovered = hovered_hit == strip_hit_count;
    if (hovered) queueRoundedRectClipped(state, rect, paletteColor(sidebar.hoverFill()), theme.scaledUi(TAB_RADIUS_UI), strip);
    const open = state.isSidePanelOpen();
    sidebar.queueSidePanelToggleGlyph(state, rect, open, hovered, strip);
    var agents_active: usize = 0;
    if (!open) {
        if (state.sidePanelChatPaneId()) |pane_id| {
            // Agents still working while the panel is hidden: a count badge
            // tinted by the most urgent status; the tooltip names it.
            const activity = chat_panel.agentActivityForPane(state, pane_id);
            if (activity.waiting()) {
                renderAgentCountBadge(state, rect, strip, activity);
                agents_active = activity.active;
            }
        }
    }
    addHit(rect, .side_panel_toggle, project_index, 0);
    const toggle_tip = sidebar.shortcutTooltip(state, if (open) "Hide right panel" else "Show right panel", "toggle_side_panel");
    if (agents_active > 0) {
        const tip = std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s} · {d} agent{s} working", .{ toggle_tip, agents_active, if (agents_active == 1) "" else "s" }) catch toggle_tip;
        offerStripTooltip(state, rect, tip);
    } else {
        offerStripTooltip(state, rect, toggle_tip);
    }
}

fn renderAgentCountBadge(state: *runtime.AppState, toggle: palette.Rect, strip: palette.Rect, activity: chat_panel.AgentActivity) void {
    queueCountBadge(state, toggle, strip, activity.active, chat_panel.agentActivityColor(activity));
}

/// Count badge size (UI px): pill height and digit size.
const COUNT_BADGE_H_UI: f32 = 15.0;
const COUNT_BADGE_FONT_UI: f32 = 10.5;

/// Numbered status badge on a toggle's top-right corner (agents still
/// working behind a hidden panel, or live panes in other workspaces).
/// Opaque status fill with on-colour digits so the number always reads;
/// the toggle's tooltip names what is counted. Counts over 9 show "9+".
fn queueCountBadge(state: *runtime.AppState, toggle: palette.Rect, strip: palette.Rect, count: usize, color: [4]f32) void {
    if (count == 0) return;
    var count_buf: [8]u8 = undefined;
    const label = countBadgeLabel(&count_buf, count);
    const font_size = theme.scaledUi(COUNT_BADGE_FONT_UI);
    const text_w = runtime.paletteUiTextPrefixWidth(label, font_size, label.len);
    const h = @round(theme.scaledUi(COUNT_BADGE_H_UI));
    const w = @round(@max(h, text_w + theme.scaledUi(8.0)));
    const badge: palette.Rect = .{
        .x = @round(toggle.x + toggle.w - w + theme.scaledUi(4.0)),
        .y = @round(toggle.y - theme.scaledUi(1.0)),
        .w = w,
        .h = h,
    };
    const fill: [4]f32 = .{ color[0], color[1], color[2], 1.0 };
    queueRoundedRectClipped(state, badge, paletteColor(fill), h * 0.5, strip);
    queueCenteredText(state, badge, label, text_w, paletteColor(theme.foregroundOn(fill)), font_size, strip);
}

fn countBadgeLabel(buf: []u8, count: usize) []const u8 {
    if (count > 9) return "9+";
    return std.fmt.bufPrint(buf, "{d}", .{count}) catch "9+";
}

test "count badges show the number, capped at 9+" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("2", countBadgeLabel(&buf, 2));
    try std.testing.expectEqualStrings("9", countBadgeLabel(&buf, 9));
    try std.testing.expectEqualStrings("9+", countBadgeLabel(&buf, 12));
}

/// One tab body: rectangular background with a hairline edge so adjacent
/// tabs separate cleanly; the active tab carries the accent tint.
/// Strongest status pip among the panes of tab `tab_id`, or null when idle.
fn tabActivityPip(state: *runtime.AppState, project_index: usize, layout: *const runtime.WorkspaceLayout, tab_id: runtime.workspace_tabs.WorkspaceTabId) ?sidebar.PanePip {
    const project = &state.project_controller.projects.items[project_index];
    var best: ?sidebar.PanePip = null;
    for (layout.panes.items) |*pane| {
        if (runtime.workspace_tabs.tabIdForPane(layout, pane.id) != tab_id) continue;
        const pip = sidebar.panePip(state, project_index, project, pane) orelse continue;
        if (best == null or pip.rank > best.?.rank) best = pip;
    }
    return best;
}

/// Strongest live pip outside the current workspace, plus how many panes
/// there are working vs waiting (the toggle tooltip names them).
const BackgroundPip = struct { project_index: usize, pip: sidebar.PanePip, working: usize = 0, waiting: usize = 0 };

/// Strongest working/waiting pip in any workspace other than `current`.
/// Settled states (done/error) stay off the toggle; they are not "happening".
fn backgroundActivityPip(state: *runtime.AppState, current: usize) ?BackgroundPip {
    var best: ?BackgroundPip = null;
    var working: usize = 0;
    var waiting: usize = 0;
    for (state.project_controller.projects.items, 0..) |*project, project_index| {
        if (project_index == current) continue;
        for (project.workspace_layout.panes.items) |*pane| {
            const pip = sidebar.panePip(state, project_index, project, pane) orelse continue;
            if (!pip.animated) continue;
            if (pip.mark == .working) working += 1 else waiting += 1;
            if (best == null or pip.rank > best.?.pip.rank) best = .{ .project_index = project_index, .pip = pip };
        }
    }
    if (best) |*b| {
        b.working = working;
        b.waiting = waiting;
    }
    return best;
}

/// "2 working in other workspaces", "1 waiting in another workspace", or
/// both counts joined.
fn backgroundActivityLabel(buf: []u8, working: usize, waiting: usize) []const u8 {
    const total = working + waiting;
    const where = if (total == 1) "in another workspace" else "in other workspaces";
    if (working > 0 and waiting > 0) return std.fmt.bufPrint(buf, "{d} working, {d} waiting {s}", .{ working, waiting, where }) catch "Activity in other workspaces";
    if (working > 0) return std.fmt.bufPrint(buf, "{d} working {s}", .{ working, where }) catch "Activity in other workspaces";
    return std.fmt.bufPrint(buf, "{d} waiting {s}", .{ waiting, where }) catch "Activity in other workspaces";
}

test "sidebar toggle dot explains background activity" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1 working in another workspace", backgroundActivityLabel(&buf, 1, 0));
    try std.testing.expectEqualStrings("3 waiting in other workspaces", backgroundActivityLabel(&buf, 0, 3));
    try std.testing.expectEqualStrings("2 working, 1 waiting in other workspaces", backgroundActivityLabel(&buf, 2, 1));
}

fn renderTab(state: *runtime.AppState, rect: palette.Rect, clip: palette.Rect, selected: bool, hovered: bool) void {
    const radius = theme.scaledUi(TAB_RADIUS_UI);
    const fill: [4]f32 = if (selected)
        theme.wash(theme.accent(), 64)
    else if (hovered)
        theme.raise(theme.COLOR_PANEL_ALT, 0.06)
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

/// File viewer tabs and one-shot task terminals (provider sign-in/install,
/// editor tasks: `purpose == .editor`) carry a close X; other kinds close
/// from their pane. A task terminal that is the only pane is never
/// auto-closed when its command exits, so it needs a visible way out.
fn tabClosable(layout: *const runtime.WorkspaceLayout, tab: runtime.WorkspaceTab) bool {
    const pane = layout.paneById(tab.preferred_pane_id) orelse return false;
    return switch (pane.ref) {
        .file => true,
        .terminal => |terminal_ref| terminal_ref.purpose == .editor,
        else => false,
    };
}

/// Close X at the tab's right edge (where the key tip goes while Ctrl is
/// held). Registers the `close_tab` hit; the glyph shows on the selected or
/// hovered tab only, so idle tabs stay quiet.
fn renderTabClose(state: *runtime.AppState, tab: palette.Rect, clip: palette.Rect, project_index: usize, pane_id: runtime.WorkspacePaneId, visible: bool, hovered: bool) void {
    const size = @min(theme.scaledUi(CLOSE_SIZE_UI), tab.h);
    const rect: palette.Rect = .{
        .x = tab.x + tab.w - size - theme.scaledUi(CLOSE_INSET_X_UI),
        .y = tab.y + @max((tab.h - size) * 0.5, 0.0),
        .w = size,
        .h = size,
    };
    // Always register (possibly empty) so the tab's hit slot stays `+1`.
    const hit_rect = intersect(rect, clip) orelse palette.Rect{ .x = rect.x, .y = rect.y, .w = 0.0, .h = 0.0 };
    addHit(hit_rect, .close_tab, project_index, pane_id);
    if (!visible) return;
    if (hovered) queueRoundedRectClipped(state, rect, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 30)), theme.scaledUi(KEY_TIP_RADIUS_UI), clip);
    const glyph_size = theme.scaledUi(CLOSE_GLYPH_UI);
    const glyph_w = text_measure.textWidth(.icon, glyph_size, NF_COD_CLOSE);
    const color = if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    state.palette_overlay_batch.roleText(state.allocator, .{
        .x = rect.x + (rect.w - glyph_w) * 0.5,
        .y = rect.y + (rect.h - glyph_size * 1.3) * 0.5,
        .w = glyph_w,
        .h = glyph_size * 1.3,
    }, NF_COD_CLOSE, paletteColor(color), glyph_size, .icon, null, clip) catch {};
}

/// Truncates `label` with a trailing ellipsis so it fits `max_w` using
/// Palette text metrics for the tab font, cutting only at UTF-8 codepoint
/// boundaries.
pub fn truncatedLabel(buffer: *[LABEL_BUFFER_LEN]u8, label: []const u8, max_w: f32, font_size: f32) []const u8 {
    return ellipsize(buffer, label, max_w, font_size, .ui);
}

/// The rail's shared ellipsizer (tab labels, sidebar row titles): the
/// longest prefix of `label` that fits `max_w` in `role` with a trailing
/// "…", written into `buffer`. Never cuts inside a multi-byte codepoint
/// (a cut through "—" rendered as "�"), including when `label` is longer
/// than `buffer`. Returns `label` unchanged when it already fits.
pub fn ellipsize(buffer: []u8, label: []const u8, max_w: f32, font_size: f32, role: palette.FontRole) []const u8 {
    const ellipsis = "\u{2026}";
    if (buffer.len < ellipsis.len) return "";
    const bounded = utf8Prefix(label, buffer.len - ellipsis.len);
    if (bounded.len == label.len and text_measure.textWidth(role, font_size, label) <= max_w) return label;
    const ellipsis_w = text_measure.textWidth(role, font_size, ellipsis);
    var end: usize = 0;
    var fit_end: usize = 0;
    while (end < bounded.len) {
        const next = nextCodepointEnd(bounded, end);
        if (text_measure.textPrefixWidth(role, bounded, font_size, next) + ellipsis_w > max_w) break;
        fit_end = next;
        end = next;
    }
    // Never leave a dangling separator before the ellipsis ("Stream A …").
    const kept = std.mem.trimEnd(u8, bounded[0..fit_end], " \t");
    @memcpy(buffer[0..kept.len], kept);
    @memcpy(buffer[kept.len .. kept.len + ellipsis.len], ellipsis);
    return buffer[0 .. kept.len + ellipsis.len];
}

/// Longest prefix of `text` within `max_bytes` that ends on a UTF-8
/// codepoint boundary.
pub fn utf8Prefix(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// End of the codepoint starting at `start`; a malformed or truncated
/// sequence advances one byte so the walk always terminates.
fn nextCodepointEnd(text: []const u8, start: usize) usize {
    const cp_len = std.unicode.utf8ByteSequenceLength(text[start]) catch return start + 1;
    if (start + cp_len > text.len) return start + 1;
    return start + cp_len;
}

test "truncation never splits a multi-byte codepoint" {
    // "—" is three bytes (E2 80 94); every byte cut inside it backs off to
    // the space before it.
    const title = "UI fix R3 Stream A — polish";
    const dash = comptime std.mem.indexOf(u8, title, "—").?;
    try std.testing.expectEqualStrings("UI fix R3 Stream A ", utf8Prefix(title, dash + 1));
    try std.testing.expectEqualStrings("UI fix R3 Stream A ", utf8Prefix(title, dash + 2));
    try std.testing.expectEqualStrings("UI fix R3 Stream A —", utf8Prefix(title, dash + 3));
    try std.testing.expectEqualStrings(title, utf8Prefix(title, title.len));
    // A label longer than the buffer, with the buffer edge inside "—":
    // the result is valid UTF-8 and ends in the ellipsis.
    var small: [dash + 1 + 3]u8 = undefined;
    const fitted = ellipsize(&small, title, 10_000.0, 12.0, .ui);
    try std.testing.expect(std.unicode.utf8ValidateSlice(fitted));
    try std.testing.expectEqualStrings("UI fix R3 Stream A\u{2026}", fitted);
    // Width-limited cuts are valid UTF-8 at every width.
    var buf: [LABEL_BUFFER_LEN]u8 = undefined;
    var w: f32 = 0.0;
    while (w < 400.0) : (w += 3.0) {
        try std.testing.expect(std.unicode.utf8ValidateSlice(ellipsize(&buf, title, w, 12.0, .ui)));
    }
    try std.testing.expectEqualStrings(title, ellipsize(&buf, title, 10_000.0, 12.0, .ui));
    // A truncated lead byte advances one byte instead of overrunning.
    try std.testing.expectEqual(@as(usize, 1), nextCodepointEnd("\xE2\x80", 0));
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
        .sidebar_toggle => state.setSidebarHidden(false),
        .side_panel_toggle => state.toggleSidePanel(),
        .close_tab => _ = state.closeCurrentProjectWorkspacePane(hit.pane_id),
        .scroll_left, .scroll_right => {
            scroll_x = pagedScroll(scroll_x, max_scroll_x, page_w, hit.kind == .scroll_right);
            state.markDirty();
        },
    }
}

/// Tracks tab hover so the strip repaints only when the hovered tab changes.
pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32) void {
    const next = if (isVisible(state)) hitSlotAt(x, y) else null;
    if (next == hovered_hit) return;
    hovered_hit = next;
    state.markDirty();
}

pub fn systemCursorAt(x: f32, y: f32) ?palette.platform.CursorShape {
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
    var tab_buffer: [16]runtime.WorkspaceTab = undefined;
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

    // Like Herdr, "+" appends at the end of the strip even when the focused
    // tab is not the last one, instead of opening beside the focused pane.
    const second_tab_id = tabs[1].id;
    activateHit(&state, .{ .rect = .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 }, .kind = .add_tab, .project_index = 0, .pane_id = 0 });
    layout = &state.project_controller.projects.items[0].workspace_layout;
    tabs = runtime.workspace_tabs.collect(layout, &tab_buffer);
    try std.testing.expectEqual(@as(usize, 3), tabs.len);
    try std.testing.expectEqual(second_tab_id, tabs[1].id);
    try std.testing.expectEqual(@as(?runtime.WorkspaceTabId, tabs[2].id), runtime.workspace_tabs.focusedTabId(layout));
    // Tab labels resolve through the pane title (both tiled panes are chats).
    var term_title_buf: sidebar.TerminalTitleBuffer = undefined;
    try std.testing.expect(tabLabel(&state, 0, tabs[0], &term_title_buf).len > 0);
}

// The rail shares this module's test registration (desktop_test_root.zig
// imports the strip, not the sidebar), so its inline tests run too.
test {
    _ = sidebar;
}
