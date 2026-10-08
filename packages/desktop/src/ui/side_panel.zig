//! Right side panel of the workspace: one per tab, with a Browser view (the
//! tab's docked browser) and an Agents view (linked chats of the tab's chat).
//! State lives in `WorkspaceLayout.side_panels`; actions in
//! `state/side_panel_controller.zig`.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const browser_panel = @import("browser.zig");
const chat_panel = @import("chat_panel.zig");
const workspace_layout = @import("../state/workspace_layout.zig");

const HEADER_H_UI: f32 = 36.0;
const HEADER_PAD_X_UI: f32 = 10.0;
const VIEW_TAB_PAD_X_UI: f32 = 10.0;
const VIEW_TAB_GAP_UI: f32 = 2.0;
const VIEW_TAB_H_UI: f32 = 26.0;
const VIEW_TAB_RADIUS_UI: f32 = 6.0;
const LABEL_FONT_UI: f32 = 13.0;
const ICON_BUTTON_UI: f32 = 26.0;
const ICON_FONT_UI: f32 = 15.0;
const BADGE_UI: f32 = 6.0;
/// Pointer slop either side of the panel's left edge for resizing.
const RESIZE_GRIP_UI: f32 = 4.0;
/// Below these widths the panel stays hidden (its open state is kept).
const MIN_PANEL_W_UI: f32 = 280.0;
const MIN_CONTENT_W_UI: f32 = 360.0;
const EMPTY_BUTTON_W_UI: f32 = 150.0;
const EMPTY_BUTTON_H_UI: f32 = 34.0;

const NF_COD_CLOSE = "\u{EA76}";
const NF_COD_LINK_EXTERNAL = "\u{EB14}";

pub const HitKind = enum { view_browser, view_agents, pop_out, close, open_browser };

const Hit = struct { rect: palette.Rect, kind: HitKind };

var hits: [8]Hit = undefined;
var hit_count: usize = 0;
var panel_rect: ?palette.Rect = null;
var grip_rect: palette.Rect = .{};
var header_rect: palette.Rect = .{};
var workspace_rect: palette.Rect = .{};
var resizing: bool = false;

pub const Split = struct {
    content: palette.Rect,
    panel: ?palette.Rect,
};

/// Carves the focused tab's panel off the right of the workspace rect.
pub fn split(state: *runtime.AppState, rect: palette.Rect) Split {
    const none: Split = .{ .content = rect, .panel = null };
    const panel = state.currentSidePanel() orelse return none;
    if (!panel.open) return none;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    const min_panel = theme.scaledUi(MIN_PANEL_W_UI);
    const min_content = theme.scaledUi(MIN_CONTENT_W_UI);
    if (rect.w < min_panel + min_content) return none;
    const desired = rect.w * layout.side_panel_ratio;
    const width = theme.clampf(desired, min_panel, rect.w - min_content);
    // Snap the shared edge once so content and panel neither gap nor overlap.
    const edge = @round(rect.x + rect.w - width);
    return .{
        .content = .{ .x = rect.x, .y = rect.y, .w = edge - rect.x, .h = rect.h },
        .panel = .{ .x = edge, .y = rect.y, .w = rect.x + rect.w - edge, .h = rect.h },
    };
}

pub fn resetHitCache() void {
    hit_count = 0;
    panel_rect = null;
}

/// Renders the panel. Returns true when the browser view drew the live page
/// (the frame's browser presentation then belongs to the panel).
pub fn render(state: *runtime.AppState, workspace: palette.Rect, rect: palette.Rect) bool {
    // Region: side panel = left divider, header (view tabs + actions), body.
    workspace_rect = workspace;
    panel_rect = rect;
    const panel = state.currentSidePanel() orelse return false;
    const stroke = @max(@round(theme.scaledUi(1.0)), 1.0);
    queueRect(state, rect, paletteColor(theme.COLOR_PANEL));
    queueRect(state, .{ .x = rect.x, .y = rect.y, .w = stroke, .h = rect.h }, paletteColor(theme.borderMuted()));
    grip_rect = .{
        .x = rect.x - theme.scaledUi(RESIZE_GRIP_UI),
        .y = rect.y,
        .w = theme.scaledUi(RESIZE_GRIP_UI) * 2.0,
        .h = rect.h,
    };

    const header_h = @round(theme.scaledUi(HEADER_H_UI));
    header_rect = .{ .x = rect.x + stroke, .y = rect.y, .w = rect.w - stroke, .h = header_h };
    renderHeader(state, header_rect, panel.view);
    queueRect(state, .{ .x = header_rect.x, .y = rect.y + header_h, .w = header_rect.w, .h = stroke }, paletteColor(theme.borderMuted()));

    const body: palette.Rect = .{
        .x = rect.x + stroke,
        .y = rect.y + header_h + stroke,
        .w = rect.w - stroke,
        .h = @max(rect.h - header_h - stroke, 0.0),
    };
    switch (panel.view) {
        .agents => {
            chat_panel.renderLinkedChatsPanel(state, body, state.sidePanelChatPaneId());
            return false;
        },
        .browser => {
            const pane_id = state.sidePanelBrowserPaneId() orelse {
                renderBrowserEmpty(state, body);
                return false;
            };
            if (!state.claimBrowserPanePresentation(pane_id)) {
                browser_panel.renderPendingPresentation(state, body);
                return false;
            }
            browser_panel.renderDockAtWithReserve(state, body, 0.0);
            return true;
        },
    }
}

fn renderHeader(state: *runtime.AppState, rect: palette.Rect, view: workspace_layout.SidePanelView) void {
    const pad = theme.scaledUi(HEADER_PAD_X_UI);
    const font = theme.scaledUi(LABEL_FONT_UI);
    const tab_h = theme.scaledUi(VIEW_TAB_H_UI);
    const tab_y = rect.y + (rect.h - tab_h) * 0.5;
    var x = rect.x + pad;
    const views = [_]struct { kind: HitKind, label: []const u8, view: workspace_layout.SidePanelView }{
        .{ .kind = .view_browser, .label = "Browser", .view = .browser },
        .{ .kind = .view_agents, .label = "Agents", .view = .agents },
    };
    const agents_active = if (state.sidePanelChatPaneId()) |pane_id| chat_panel.linkedChatsActiveForPane(state, pane_id) else false;
    for (views) |entry| {
        const label_w = runtime.paletteUiTextPrefixWidth(entry.label, font, entry.label.len);
        const badge_w = if (entry.view == .agents and agents_active) theme.scaledUi(BADGE_UI) + theme.scaledUi(6.0) else 0.0;
        const tab = snap(.{ .x = x, .y = tab_y, .w = label_w + badge_w + theme.scaledUi(VIEW_TAB_PAD_X_UI) * 2.0, .h = tab_h });
        const selected = entry.view == view;
        const hovered = mouseIn(state, tab);
        if (selected or hovered) {
            const fill = if (selected) theme.wash(theme.accent(), 48) else theme.raise(theme.COLOR_PANEL, 0.06);
            queueRounded(state, tab, paletteColor(fill), theme.scaledUi(VIEW_TAB_RADIUS_UI), rect);
        }
        const color = if (selected) theme.COLOR_WHITE else if (hovered) theme.raise(theme.COLOR_TEXT_MUTED, 0.12) else theme.COLOR_TEXT_MUTED;
        const line_h = font * 1.25;
        queueText(state, .{
            .x = tab.x + theme.scaledUi(VIEW_TAB_PAD_X_UI),
            .y = tab.y + (tab.h - line_h) * 0.5,
            .w = label_w + theme.scaledUi(2.0),
            .h = line_h,
        }, entry.label, paletteColor(color), font, rect);
        if (badge_w > 0.0) {
            const dot = theme.scaledUi(BADGE_UI);
            queueRounded(state, .{
                .x = tab.x + theme.scaledUi(VIEW_TAB_PAD_X_UI) + label_w + theme.scaledUi(6.0),
                .y = tab.y + (tab.h - dot) * 0.5,
                .w = dot,
                .h = dot,
            }, paletteColor(theme.COLOR_GREEN), dot * 0.5, rect);
        }
        addHit(tab, entry.kind);
        x = tab.x + tab.w + theme.scaledUi(VIEW_TAB_GAP_UI);
    }

    // Actions hug the right edge: close, then "move to own tab".
    const button = theme.scaledUi(ICON_BUTTON_UI);
    var right = rect.x + rect.w - pad;
    const close_rect = snap(.{ .x = right - button, .y = rect.y + (rect.h - button) * 0.5, .w = button, .h = button });
    renderIconButton(state, close_rect, NF_COD_CLOSE, rect);
    addHit(close_rect, .close);
    right = close_rect.x - theme.scaledUi(4.0);
    if (view == .browser and state.sidePanelBrowserPaneId() != null) {
        const pop_rect = snap(.{ .x = right - button, .y = close_rect.y, .w = button, .h = button });
        renderIconButton(state, pop_rect, NF_COD_LINK_EXTERNAL, rect);
        addHit(pop_rect, .pop_out);
    }
}

fn renderIconButton(state: *runtime.AppState, rect: palette.Rect, glyph: []const u8, clip: palette.Rect) void {
    const hovered = mouseIn(state, rect);
    if (hovered) queueRounded(state, rect, paletteColor(theme.raise(theme.COLOR_PANEL, 0.08)), theme.scaledUi(VIEW_TAB_RADIUS_UI), clip);
    const font = theme.scaledUi(ICON_FONT_UI);
    queueIcon(state, .{
        .x = rect.x + (rect.w - font) * 0.5,
        .y = rect.y + (rect.h - font) * 0.5,
        .w = font,
        .h = font,
    }, glyph, paletteColor(if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), font, clip);
}

fn renderBrowserEmpty(state: *runtime.AppState, rect: palette.Rect) void {
    queueRect(state, rect, paletteColor(theme.background()));
    const pad = theme.scaledUi(20.0);
    const width = @max(rect.w - pad * 2.0, 0.0);
    if (width <= 0.0) return;
    const title_font = theme.scaledUi(14.0);
    const body_font = theme.scaledUi(12.0);
    const y = rect.y + @max(rect.h * 0.3, pad);
    queueText(state, .{ .x = rect.x + pad, .y = y, .w = width, .h = title_font * 1.4 }, "No preview yet", paletteColor(theme.COLOR_WHITE), title_font, rect);
    queueText(state, .{ .x = rect.x + pad, .y = y + title_font * 1.4 + theme.scaledUi(6.0), .w = width, .h = body_font * 1.4 }, "Agents in this tab open pages here.", paletteColor(theme.COLOR_TEXT_MUTED), body_font, rect);
    const button = snap(.{
        .x = rect.x + pad,
        .y = y + title_font * 1.4 + body_font * 1.4 + theme.scaledUi(18.0),
        .w = @min(theme.scaledUi(EMPTY_BUTTON_W_UI), width),
        .h = theme.scaledUi(EMPTY_BUTTON_H_UI),
    });
    const fill = if (mouseIn(state, button)) theme.raise(theme.accent(), 0.08) else theme.accent();
    queueRounded(state, button, paletteColor(fill), theme.scaledUi(8.0), rect);
    const label = "Open browser";
    const label_w = runtime.paletteUiTextPrefixWidth(label, body_font * 1.08, label.len);
    const line_h = body_font * 1.08 * 1.25;
    queueText(state, .{
        .x = button.x + @max((button.w - label_w) * 0.5, 0.0),
        .y = button.y + (button.h - line_h) * 0.5,
        .w = label_w + theme.scaledUi(2.0),
        .h = line_h,
    }, label, paletteColor(theme.foregroundOn(fill)), body_font * 1.08, button);
    addHit(button, .open_browser);
}

/// Clicks on panel chrome and the resize grip. The browser page and agent
/// rows are routed by their own handlers.
pub fn handleMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    if (resizing and !down) {
        resizing = false;
        return true;
    }
    const rect = panel_rect orelse return false;
    if (!down) return hitAt(x, y) != null;
    if (rectContains(grip_rect, x, y)) {
        resizing = true;
        return true;
    }
    if (hitAt(x, y)) |hit| {
        activate(state, hit.kind);
        return true;
    }
    // Header gaps are inert rather than falling through to panes.
    return rectContains(header_rect, x, y) and rectContains(rect, x, y);
}

pub fn handleMouseMotion(state: *runtime.AppState, x: f32, _: f32) bool {
    if (!resizing) return false;
    const ratio = (workspace_rect.x + workspace_rect.w - x) / @max(workspace_rect.w, 1.0);
    state.setSidePanelRatio(ratio);
    return true;
}

pub fn isResizing() bool {
    return resizing;
}

pub fn systemCursorAt(x: f32, y: f32) ?sdl.SystemCursor {
    if (panel_rect == null) return null;
    if (resizing or rectContains(grip_rect, x, y)) return .ew_resize;
    if (hitAt(x, y) != null) return .pointer;
    return null;
}

/// Whether the point lies on the panel, so pane routing can skip it.
pub fn containsPoint(x: f32, y: f32) bool {
    const rect = panel_rect orelse return false;
    return rectContains(rect, x, y);
}

fn activate(state: *runtime.AppState, kind: HitKind) void {
    switch (kind) {
        .view_browser => state.setSidePanelView(.browser),
        .view_agents => state.setSidePanelView(.agents),
        .close => state.setSidePanelOpen(false),
        .pop_out => if (state.sidePanelBrowserPaneId()) |pane_id| state.moveBrowserToOwnTab(pane_id),
        .open_browser => state.openSidePanelBrowser(),
    }
}

fn hitAt(x: f32, y: f32) ?Hit {
    var index = hit_count;
    while (index > 0) {
        index -= 1;
        if (rectContains(hits[index].rect, x, y)) return hits[index];
    }
    return null;
}

fn addHit(rect: palette.Rect, kind: HitKind) void {
    if (hit_count >= hits.len) return;
    hits[hit_count] = .{ .rect = rect, .kind = kind };
    hit_count += 1;
}

fn mouseIn(state: *runtime.AppState, rect: palette.Rect) bool {
    return rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h;
}

fn snap(rect: palette.Rect) palette.Rect {
    const x0 = @round(rect.x);
    const y0 = @round(rect.y);
    return .{ .x = x0, .y = y0, .w = @round(rect.x + rect.w) - x0, .h = @round(rect.y + rect.h) - y0 };
}

fn stableText(state: *runtime.AppState, value: []const u8) []const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch "";
}

fn queueRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch {};
}

fn queueRounded(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, color, radius, clip) catch {};
}

fn queueText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roleText(state.allocator, rect, stableText(state, value), color, font_size, .ui, null, clip) catch {};
}

fn queueIcon(state: *runtime.AppState, rect: palette.Rect, glyph: []const u8, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roleText(state.allocator, rect, stableText(state, glyph), color, font_size, .icon, null, clip) catch {};
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}
