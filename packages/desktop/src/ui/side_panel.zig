//! Right side panel of the workspace: one per tab, with a Browser view (the
//! tab's docked browser), an Agents view (linked chats of the tab's chat), a
//! Changes view (uncommitted git changes) and a Files view (workspace file
//! explorer). Files opened from Changes or Files dock here as file tabs
//! after the view tabs, each with an x; the header's pop-out moves the shown
//! one into a workspace tab. State lives in `WorkspaceLayout.side_panels`;
//! actions in `state/side_panel_controller.zig`.
//!
//! This file owns the chrome (divider, resize grip, view and file tabs,
//! actions) and routes body input to the selected view. Changes and Files
//! implement the hook contract documented in `side_panel_changes.zig`; a
//! docked file routes to `file_viewer.zig`. Clicking their body gives the
//! panel keyboard focus until another surface takes it.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const browser_panel = @import("browser.zig");
const chat_panel = @import("chat_panel.zig");
const changes_view = @import("side_panel_changes.zig");
const files_view = @import("side_panel_files.zig");
const file_viewer = @import("file_viewer.zig");
const file_icons = @import("file_icons.zig");
const keybinds = @import("../app/keybinds.zig");
const workspace_layout = @import("../state/workspace_layout.zig");

const SidePanelView = workspace_layout.SidePanelView;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;

extern fn SDL_GetModState() sdl.Keymod;

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
/// Docked file tabs: natural width is capped, and they shrink to the
/// minimum before older ones scroll out of the header.
const FILE_TAB_MAX_W_UI: f32 = 180.0;
const FILE_TAB_MIN_W_UI: f32 = 84.0;
const FILE_TAB_PAD_X_UI: f32 = 8.0;
const FILE_TAB_ICON_UI: f32 = 13.0;
const FILE_TAB_CLOSE_UI: f32 = 18.0;
const FILE_TAB_CLOSE_FONT_UI: f32 = 12.0;

const NF_COD_CLOSE = "\u{EA76}";
const NF_COD_LINK_EXTERNAL = "\u{EB14}";
const NF_COD_GLOBE = "\u{EB01}";
const NF_COD_HUBOT = "\u{EB08}";
const NF_COD_SOURCE_CONTROL = "\u{EA68}";
const NF_COD_FILES = "\u{EAF0}";

/// View tabs in header order.
const VIEW_TABS = [_]struct { view: SidePanelView, label: []const u8, glyph: []const u8 }{
    .{ .view = .browser, .label = "Browser", .glyph = NF_COD_GLOBE },
    .{ .view = .agents, .label = "Agents", .glyph = NF_COD_HUBOT },
    .{ .view = .changes, .label = "Changes", .glyph = NF_COD_SOURCE_CONTROL },
    .{ .view = .files, .label = "Files", .glyph = NF_COD_FILES },
};

pub const HitKind = enum { view_tab, file_tab, file_close, pop_out, close, open_browser };

const Hit = struct { rect: palette.Rect, kind: HitKind, view: SidePanelView = .browser, pane_id: WorkspacePaneId = 0 };

var hits: [64]Hit = undefined;
var hit_count: usize = 0;
var panel_rect: ?palette.Rect = null;
var grip_rect: palette.Rect = .{};
var header_rect: palette.Rect = .{};
var workspace_rect: palette.Rect = .{};
var body_rect: palette.Rect = .{};
var body_view: ?SidePanelView = null;
/// Docked file drawn in the body when `body_view` is `.file`.
var body_file_pane: WorkspacePaneId = 0;
var resizing: bool = false;
/// The panel body owns the keyboard. Only honoured while no composer,
/// terminal or browser has focus, so any surface taking focus wins.
var body_focused: bool = false;
/// A press began in a Changes/Files body; its motion and release follow it.
var body_drag: bool = false;

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
    // Narrow windows split evenly rather than hiding an open panel, so the
    // toggle never looks dead; only truly tiny windows hide it.
    if (rect.w < min_panel * 2.0) return none;
    const desired = rect.w * layout.side_panel_ratio;
    const width = if (rect.w < min_panel + min_content)
        rect.w * 0.5
    else
        theme.clampf(desired, min_panel, rect.w - min_content);
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
    body_view = null;
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
    // The grip sits on the panel side of the divider so it never steals
    // the neighbouring pane's edge (its scrollbar lives there).
    grip_rect = .{
        .x = rect.x - stroke,
        .y = rect.y,
        .w = theme.scaledUi(RESIZE_GRIP_UI) * 2.0,
        .h = rect.h,
    };

    // A `.file` view whose docked file is gone shows the list it came from.
    const file_pane = state.sidePanelFilePaneId();
    const view: SidePanelView = if (panel.view == .file and file_pane == null) panel.return_view else panel.view;
    const header_h = @round(theme.scaledUi(HEADER_H_UI));
    header_rect = .{ .x = rect.x + stroke, .y = rect.y, .w = rect.w - stroke, .h = header_h };
    renderHeader(state, header_rect, view, file_pane);
    queueRect(state, .{ .x = header_rect.x, .y = rect.y + header_h, .w = header_rect.w, .h = stroke }, paletteColor(theme.borderMuted()));

    const body: palette.Rect = .{
        .x = rect.x + stroke,
        .y = rect.y + header_h + stroke,
        .w = rect.w - stroke,
        .h = @max(rect.h - header_h - stroke, 0.0),
    };
    body_rect = body;
    body_view = view;
    switch (view) {
        .agents => {
            chat_panel.renderLinkedChatsPanel(state, body, state.sidePanelChatPaneId());
            return false;
        },
        .changes => {
            changes_view.resetHitCache();
            changes_view.render(state, body, bodyHasKeyboard(state));
            return false;
        },
        .files => {
            files_view.resetHitCache();
            files_view.render(state, body, bodyHasKeyboard(state));
            return false;
        },
        .file => {
            body_file_pane = file_pane orelse return false;
            file_viewer.renderDockedPane(state, body_file_pane, body);
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

fn renderHeader(state: *runtime.AppState, rect: palette.Rect, view: SidePanelView, file_pane: ?WorkspacePaneId) void {
    const pad = theme.scaledUi(HEADER_PAD_X_UI);
    const font = theme.scaledUi(LABEL_FONT_UI);
    const icon_font = theme.scaledUi(ICON_FONT_UI);
    const tab_h = theme.scaledUi(VIEW_TAB_H_UI);
    const tab_y = rect.y + (rect.h - tab_h) * 0.5;
    const tab_pad = theme.scaledUi(VIEW_TAB_PAD_X_UI);
    const gap = theme.scaledUi(VIEW_TAB_GAP_UI);
    const dot = theme.scaledUi(BADGE_UI);
    const agents_active = if (state.sidePanelChatPaneId()) |pane_id| chat_panel.linkedChatsActiveForPane(state, pane_id) else false;

    var file_buffer: [64]WorkspacePaneId = undefined;
    const files = dockedFiles(state, &file_buffer);

    // Labels when they fit beside the actions (and a file tab or two), else
    // icon-only tabs.
    const actions_w = theme.scaledUi(ICON_BUTTON_UI) * 2.0 + theme.scaledUi(4.0) + pad;
    const files_min_w = @as(f32, @floatFromInt(@min(files.len, 2))) * theme.scaledUi(FILE_TAB_MIN_W_UI);
    var labels_w: f32 = 0.0;
    for (VIEW_TABS) |entry| {
        labels_w += runtime.paletteUiTextPrefixWidth(entry.label, font, entry.label.len) + tab_pad * 2.0 + gap;
        if (entry.view == .agents and agents_active) labels_w += dot + theme.scaledUi(6.0);
    }
    const compact = pad + labels_w + actions_w + files_min_w > rect.w;

    var x = rect.x + pad;
    for (VIEW_TABS) |entry| {
        const content_w = if (compact) icon_font else runtime.paletteUiTextPrefixWidth(entry.label, font, entry.label.len);
        const badge_w = if (entry.view == .agents and agents_active) dot + theme.scaledUi(if (compact) 3.0 else 6.0) else 0.0;
        const inner_pad = if (compact) theme.scaledUi(6.0) else tab_pad;
        const tab = snap(.{ .x = x, .y = tab_y, .w = content_w + badge_w + inner_pad * 2.0, .h = tab_h });
        const selected = entry.view == view;
        const hovered = mouseIn(state, tab);
        if (selected or hovered) {
            const fill = if (selected) theme.wash(theme.accent(), 48) else theme.raise(theme.COLOR_PANEL, 0.06);
            queueRounded(state, tab, paletteColor(fill), theme.scaledUi(VIEW_TAB_RADIUS_UI), rect);
        }
        const color = if (selected) theme.COLOR_WHITE else if (hovered) theme.raise(theme.COLOR_TEXT_MUTED, 0.12) else theme.COLOR_TEXT_MUTED;
        if (compact) {
            queueIcon(state, .{
                .x = tab.x + inner_pad,
                .y = tab.y + (tab.h - icon_font) * 0.5,
                .w = icon_font,
                .h = icon_font,
            }, entry.glyph, paletteColor(color), icon_font, rect);
        } else {
            const line_h = font * 1.25;
            queueText(state, .{
                .x = tab.x + inner_pad,
                .y = tab.y + (tab.h - line_h) * 0.5,
                .w = content_w + theme.scaledUi(2.0),
                .h = line_h,
            }, entry.label, paletteColor(color), font, rect);
        }
        if (badge_w > 0.0) {
            queueRounded(state, .{
                .x = tab.x + tab.w - inner_pad - dot,
                .y = tab.y + (tab.h - dot) * 0.5,
                .w = dot,
                .h = dot,
            }, paletteColor(theme.COLOR_GREEN), dot * 0.5, rect);
        }
        addHit(.{ .rect = tab, .kind = .view_tab, .view = entry.view });
        x = tab.x + tab.w + gap;
    }

    // Actions hug the right edge: close, then "move to own tab".
    const button = theme.scaledUi(ICON_BUTTON_UI);
    var right = rect.x + rect.w - pad;
    const close_rect = snap(.{ .x = right - button, .y = rect.y + (rect.h - button) * 0.5, .w = button, .h = button });
    renderIconButton(state, close_rect, NF_COD_CLOSE, rect);
    addHit(.{ .rect = close_rect, .kind = .close });
    right = close_rect.x - theme.scaledUi(4.0);
    if ((view == .browser and state.sidePanelBrowserPaneId() != null) or view == .file) {
        const pop_rect = snap(.{ .x = right - button, .y = close_rect.y, .w = button, .h = button });
        renderIconButton(state, pop_rect, NF_COD_LINK_EXTERNAL, rect);
        addHit(.{ .rect = pop_rect, .kind = .pop_out });
    }

    if (files.len > 0) {
        const divider_h = tab_h * 0.6;
        const stroke = @max(@round(theme.scaledUi(1.0)), 1.0);
        queueRect(state, snap(.{ .x = x + gap, .y = rect.y + (rect.h - divider_h) * 0.5, .w = stroke, .h = divider_h }), paletteColor(theme.borderMuted()));
        const strip: palette.Rect = .{ .x = x + gap * 2.0 + stroke, .y = rect.y, .w = @max(close_rect.x - button - theme.scaledUi(8.0) - (x + gap * 2.0 + stroke), 0.0), .h = rect.h };
        renderFileTabs(state, strip, tab_y, tab_h, files, if (view == .file) file_pane else null);
    }
}

/// Docked files of the focused tab, in panel (pane) order.
fn dockedFiles(state: *runtime.AppState, buffer: []WorkspacePaneId) []const WorkspacePaneId {
    const tab_id = state.sidePanelTabId() orelse return buffer[0..0];
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    var count: usize = 0;
    for (layout.panes.items) |pane| {
        if (count >= buffer.len) break;
        if (pane.docked_tab_id != tab_id or pane.ref != .file) continue;
        buffer[count] = pane.id;
        count += 1;
    }
    return buffer[0..count];
}

fn dockedFileName(state: *runtime.AppState, pane_id: WorkspacePaneId) []const u8 {
    const ref = state.filePaneRef(pane_id) orelse return "";
    return std.fs.path.basename(ref.path);
}

/// File tabs share `strip`: natural width up to a cap, shrinking evenly to a
/// minimum; past that only a window around the selected tab is drawn.
fn renderFileTabs(state: *runtime.AppState, strip: palette.Rect, tab_y: f32, tab_h: f32, files: []const WorkspacePaneId, selected: ?WorkspacePaneId) void {
    if (strip.w <= 0.0 or files.len == 0) return;
    const font = theme.scaledUi(LABEL_FONT_UI);
    const icon_font = theme.scaledUi(FILE_TAB_ICON_UI);
    const pad = theme.scaledUi(FILE_TAB_PAD_X_UI);
    const close_size = theme.scaledUi(FILE_TAB_CLOSE_UI);
    const gap = theme.scaledUi(VIEW_TAB_GAP_UI);
    const max_w = theme.scaledUi(FILE_TAB_MAX_W_UI);
    const min_w = @min(theme.scaledUi(FILE_TAB_MIN_W_UI), strip.w);
    const chrome_w = pad + icon_font + theme.scaledUi(6.0) + theme.scaledUi(6.0) + close_size + theme.scaledUi(4.0);

    var natural_total: f32 = 0.0;
    for (files) |pane_id| {
        const name = dockedFileName(state, pane_id);
        natural_total += @min(chrome_w + runtime.paletteUiTextPrefixWidth(name, font, name.len), max_w) + gap;
    }
    const count_f: f32 = @floatFromInt(files.len);
    const shrunk_w = @max((strip.w - gap * count_f) / count_f, min_w);
    const fits = natural_total <= strip.w;
    const visible: usize = if (fits) files.len else @max(@as(usize, @intFromFloat(@floor((strip.w + gap) / (shrunk_w + gap)))), 1);
    var start: usize = 0;
    if (visible < files.len) {
        const selected_index = blk: {
            for (files, 0..) |pane_id, index| if (selected == pane_id) break :blk index;
            break :blk files.len - 1;
        };
        start = @min(selected_index + 1 -| visible, files.len - visible);
    }

    var x = strip.x;
    for (files[start..@min(start + visible, files.len)]) |pane_id| {
        const name = dockedFileName(state, pane_id);
        const natural = @min(chrome_w + runtime.paletteUiTextPrefixWidth(name, font, name.len), max_w);
        const width = if (fits) natural else @min(shrunk_w, natural);
        const tab = snap(.{ .x = x, .y = tab_y, .w = width, .h = tab_h });
        if (tab.x >= strip.x + strip.w) break;
        const clip = intersect(tab, strip);
        const is_selected = selected == pane_id;
        const hovered = mouseIn(state, tab);
        if (is_selected or hovered) {
            const fill = if (is_selected) theme.wash(theme.accent(), 48) else theme.raise(theme.COLOR_PANEL, 0.06);
            queueRounded(state, tab, paletteColor(fill), theme.scaledUi(VIEW_TAB_RADIUS_UI), clip);
        }
        const color = if (is_selected) theme.COLOR_WHITE else if (hovered) theme.raise(theme.COLOR_TEXT_MUTED, 0.12) else theme.COLOR_TEXT_MUTED;

        const icon = file_icons.forFile(name);
        const icon_h = icon_font * 1.3;
        queueIcon(state, .{ .x = tab.x + pad, .y = tab.y + (tab.h - icon_h) * 0.5, .w = icon_font, .h = icon_h }, icon.glyph, paletteColor(theme.legibleOn(icon.color, theme.COLOR_PANEL)), icon_font, clip);

        const close_rect = snap(.{ .x = tab.x + tab.w - theme.scaledUi(4.0) - close_size, .y = tab.y + (tab.h - close_size) * 0.5, .w = close_size, .h = close_size });
        const label_x = tab.x + pad + icon_font + theme.scaledUi(6.0);
        const label_clip = intersect(clip, .{ .x = label_x, .y = tab.y, .w = @max(close_rect.x - theme.scaledUi(4.0) - label_x, 0.0), .h = tab.h });
        const line_h = font * 1.25;
        queueText(state, .{ .x = label_x, .y = tab.y + (tab.h - line_h) * 0.5, .w = runtime.paletteUiTextPrefixWidth(name, font, name.len) + theme.scaledUi(2.0), .h = line_h }, name, paletteColor(color), font, label_clip);

        const close_hovered = mouseIn(state, close_rect);
        if (close_hovered) queueRounded(state, close_rect, paletteColor(theme.raise(theme.COLOR_PANEL, 0.14)), theme.scaledUi(4.0), clip);
        const close_font = theme.scaledUi(FILE_TAB_CLOSE_FONT_UI);
        queueIcon(state, .{
            .x = close_rect.x + (close_rect.w - close_font) * 0.5,
            .y = close_rect.y + (close_rect.h - close_font * 1.3) * 0.5,
            .w = close_font,
            .h = close_font * 1.3,
        }, NF_COD_CLOSE, paletteColor(if (close_hovered) theme.COLOR_WHITE else color), close_font, clip);

        addHit(.{ .rect = clip, .kind = .file_tab, .pane_id = pane_id });
        addHit(.{ .rect = intersect(close_rect, clip), .kind = .file_close, .pane_id = pane_id });
        x = tab.x + tab.w + gap;
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
    const title = "No preview yet";
    const body = "Agents in this tab open pages here.";
    const title_h = title_font * 1.4;
    const body_h = body_font * 1.4;
    const button_h = theme.scaledUi(EMPTY_BUTTON_H_UI);
    const title_gap = theme.scaledUi(6.0);
    const button_gap = theme.scaledUi(18.0);
    // Centre the title, hint and button as one group in the body.
    const group_h = title_h + title_gap + body_h + button_gap + button_h;
    const y = rect.y + @max((rect.h - group_h) * 0.5, pad);
    const center_x = rect.x + rect.w * 0.5;
    const title_w = @min(runtime.paletteUiTextPrefixWidth(title, title_font, title.len) + theme.scaledUi(2.0), width);
    const body_w = @min(runtime.paletteUiTextPrefixWidth(body, body_font, body.len) + theme.scaledUi(2.0), width);
    queueText(state, .{ .x = @round(center_x - title_w * 0.5), .y = y, .w = title_w, .h = title_h }, title, paletteColor(theme.COLOR_WHITE), title_font, rect);
    queueText(state, .{ .x = @round(center_x - body_w * 0.5), .y = y + title_h + title_gap, .w = body_w, .h = body_h }, body, paletteColor(theme.COLOR_TEXT_MUTED), body_font, rect);
    const button_w = @min(theme.scaledUi(EMPTY_BUTTON_W_UI), width);
    const button = snap(.{
        .x = center_x - button_w * 0.5,
        .y = y + title_h + title_gap + body_h + button_gap,
        .w = button_w,
        .h = button_h,
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
    addHit(.{ .rect = button, .kind = .open_browser });
}

/// Clicks on the panel: chrome and resize grip first, then the selected
/// view's body. Browser page input routes through the browser's own handler
/// below; every other body click is swallowed so it never reaches panes.
pub fn handleMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    if (!down) {
        if (resizing) {
            resizing = false;
            return true;
        }
        if (body_drag) {
            body_drag = false;
            _ = dispatchBodyMouseButton(state, x, y, false, clicks);
            return true;
        }
        // A pane drag released over the panel still belongs to the panes.
        return false;
    }
    const rect = panel_rect orelse {
        body_focused = false;
        return false;
    };
    if (!rectContains(rect, x, y) and !rectContains(grip_rect, x, y)) {
        body_focused = false;
        return false;
    }
    if (rectContains(grip_rect, x, y)) {
        resizing = true;
        return true;
    }
    if (hitAt(x, y)) |hit| {
        activate(state, hit);
        return true;
    }
    if (rectContains(header_rect, x, y)) return true;
    const view = body_view orelse return true;
    switch (view) {
        .browser => {
            body_focused = false;
            return false;
        },
        .agents => {
            body_focused = false;
            _ = chat_panel.handleLinkedChatsMouseButton(state, x, y, true);
            return true;
        },
        .changes, .files, .file => {
            focusBody(state);
            body_drag = true;
            _ = dispatchBodyMouseButton(state, x, y, true, clicks);
            return true;
        },
    }
}

pub fn handleMouseMotion(state: *runtime.AppState, x: f32, y: f32) bool {
    if (resizing) {
        const ratio = (workspace_rect.x + workspace_rect.w - x) / @max(workspace_rect.w, 1.0);
        state.setSidePanelRatio(ratio);
        return true;
    }
    const view = body_view orelse return false;
    if (!body_drag and !rectContains(body_rect, x, y)) return false;
    return switch (view) {
        .changes => changes_view.handleMouseMotion(state, x, y),
        .files => files_view.handleMouseMotion(state, x, y),
        .file => file_viewer.handleMouseMotion(state, x, y),
        .browser, .agents => false,
    };
}

/// Wheel over a Changes/Files body scrolls that view and never the panes.
pub fn handleWheel(state: *runtime.AppState, x: f32, y: f32, wheel_y: f32) bool {
    const view = body_view orelse return false;
    if (panel_rect == null or !rectContains(body_rect, x, y)) return false;
    switch (view) {
        .changes => _ = changes_view.handleWheel(state, x, y, wheel_y),
        .files => _ = files_view.handleWheel(state, x, y, wheel_y),
        .file => _ = file_viewer.handleWheel(state, body_file_pane, x, y, 0.0, wheel_y),
        .browser, .agents => return false,
    }
    return true;
}

/// Keys while the panel body owns the keyboard. Escape hands focus back;
/// the close-pane shortcut closes the panel instead of the focused pane.
pub fn handleKeyDown(state: *runtime.AppState, event: *const sdl.KeyboardEvent, action: ?keybinds.NativeKeyboardAction) bool {
    if (!bodyHasKeyboard(state)) return false;
    const view = body_view orelse return false;
    const handled = switch (view) {
        .changes => changes_view.handleKey(state, event),
        .files => files_view.handleKey(state, event),
        .file => file_viewer.handlePaneKeyDown(state, body_file_pane, event),
        .browser, .agents => false,
    };
    if (handled) return true;
    if (event.key == .escape) {
        body_focused = false;
        state.markDirty();
        return true;
    }
    if (action) |resolved| {
        if (resolved == .workspace_close or resolved == .workspace_close_current) {
            // A docked file closes its own tab; other views close the panel.
            if (view == .file) {
                state.closeSidePanelFile(body_file_pane);
                return true;
            }
            body_focused = false;
            state.setSidePanelOpen(false);
            return true;
        }
    }
    return false;
}

pub fn handleTextInput(state: *runtime.AppState, text: []const u8) bool {
    if (!bodyHasKeyboard(state)) return false;
    const view = body_view orelse return false;
    return switch (view) {
        .changes => changes_view.handleTextInput(state, text),
        .files => files_view.handleTextInput(state, text),
        .browser, .agents, .file => false,
    };
}

/// Whether a text field in the focused panel body needs SDL text input.
pub fn wantsTextInput(state: *runtime.AppState) bool {
    if (!bodyHasKeyboard(state)) return false;
    const view = body_view orelse return false;
    return switch (view) {
        .changes => changes_view.wantsTextInput(state),
        .files => files_view.wantsTextInput(state),
        .browser, .agents, .file => false,
    };
}

pub fn isResizing() bool {
    return resizing;
}

pub fn systemCursorAt(state: *runtime.AppState, x: f32, y: f32) ?sdl.SystemCursor {
    const rect = panel_rect orelse return null;
    if (resizing or rectContains(grip_rect, x, y)) return .ew_resize;
    if (hitAt(x, y) != null) return .pointer;
    if (!rectContains(rect, x, y) or !rectContains(body_rect, x, y)) return null;
    const view = body_view orelse return null;
    return switch (view) {
        .changes => changes_view.systemCursorAt(state, x, y),
        .files => files_view.systemCursorAt(state, x, y),
        .file => file_viewer.systemCursorAt(x, y),
        .browser, .agents => null,
    };
}

/// True while the panel body, not a pane, receives keyboard input.
pub fn bodyHasKeyboard(state: *runtime.AppState) bool {
    if (!body_focused or panel_rect == null) return false;
    if (state.composer_controller.focused or state.terminal_controller.focused) return false;
    if (state.browser_controller.address_focused or state.isBrowserPaneFocused()) return false;
    return true;
}

fn focusBody(state: *runtime.AppState) void {
    state.blurPaletteComposer();
    state.terminal_controller.focused = false;
    state.browser_controller.address_focused = false;
    state.unfocusBrowserPane();
    body_focused = true;
    state.markDirty();
}

fn dispatchBodyMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    const view = body_view orelse return false;
    return switch (view) {
        .changes => changes_view.handleMouseButton(state, x, y, down, clicks),
        .files => files_view.handleMouseButton(state, x, y, down, clicks),
        .file => if (down)
            file_viewer.handleMouseDown(state, body_file_pane, x, y, isShiftDown())
        else
            file_viewer.handleMouseUp(state),
        .browser, .agents => false,
    };
}

/// Whether the point lies on the panel, so pane routing can skip it.
pub fn containsPoint(x: f32, y: f32) bool {
    const rect = panel_rect orelse return false;
    return rectContains(rect, x, y);
}

fn activate(state: *runtime.AppState, hit: Hit) void {
    switch (hit.kind) {
        .view_tab => state.setSidePanelView(hit.view),
        .file_tab => state.showSidePanelFile(hit.pane_id),
        .file_close => state.closeSidePanelFile(hit.pane_id),
        .close => state.setSidePanelOpen(false),
        .pop_out => if (body_view != null and body_view.? == .file)
            state.moveSidePanelFileToOwnTab(body_file_pane)
        else if (state.sidePanelBrowserPaneId()) |pane_id|
            state.moveBrowserToOwnTab(pane_id),
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

fn addHit(hit: Hit) void {
    if (hit_count >= hits.len) return;
    hits[hit_count] = hit;
    hit_count += 1;
}

fn mouseIn(state: *runtime.AppState, rect: palette.Rect) bool {
    return rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h;
}

fn isShiftDown() bool {
    const modifiers = SDL_GetModState();
    const bits = @as(*const u16, @ptrCast(&modifiers)).*;
    return (bits & sdl.Keymod.shift) != 0;
}

fn intersect(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
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
