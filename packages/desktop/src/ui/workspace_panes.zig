//! Workspace pane composition.
//!
//! This starts as a compatibility wrapper around the existing chat workspace.
//! The pane model lives in state so later slices can add terminal leaves without
//! changing the root UI entry point again.

const std = @import("std");

const palette = @import("palette");
const sdl = @import("zsdl3");

const app_config = @import("../app/config.zig");
const keybinds = @import("../app/keybinds.zig");
const storage_mod = @import("../state/storage.zig");
const workspace_layout = @import("../state/workspace_layout.zig");
const runtime = @import("runtime.zig");
const browser_panel = @import("browser.zig");
const chat_panel = @import("chat_panel.zig");
const colors = @import("colors.zig");
const profiler = @import("../runtime/profiler.zig");
const terminal_panel = @import("terminal_panel.zig");
const theme = @import("theme.zig");

const THREAD_DROP_PREVIEW_Z: i32 = 140;
const PANE_ZOOM_CONTROL_Z: i32 = 150;
const PANE_CONTEXT_MENU_Z: i32 = 180;
const INACTIVE_PANE_FADE_ALPHA: u8 = 72;
const PANE_DRAG_THRESHOLD_CSS: f32 = 8.0;
const PANE_CHROME_CONTROL_SIZE_CSS: f32 = 30.0;
const PANE_CHROME_CONTROL_GAP_CSS: f32 = 6.0;
const PANE_CHROME_RIGHT_MARGIN_CSS: f32 = 10.0;
const CHAT_PANE_HEADER_RIGHT_RESERVE_CSS: f32 = PANE_CHROME_CONTROL_SIZE_CSS * 2.0 +
    PANE_CHROME_CONTROL_GAP_CSS + PANE_CHROME_RIGHT_MARGIN_CSS;
const BROWSER_TOOLBAR_RIGHT_RESERVE_CSS: f32 = PANE_CHROME_CONTROL_SIZE_CSS + PANE_CHROME_CONTROL_GAP_CSS;
const ZOOM_ICON_SIZE_CSS: f32 = 17.0;
const TERMINAL_ZOOM_HOVER_WIDTH_CSS: f32 = 112.0;
const TERMINAL_ZOOM_HOVER_HEIGHT_CSS: f32 = 48.0;
const INACTIVE_BORDER_WIDTH_CSS: f32 = 1.0;
const FOCUS_BORDER_WIDTH_CSS: f32 = 2.0;
const ZOOM_BORDER_WIDTH_CSS: f32 = 3.0;
const STATUS_BORDER_WIDTH_CSS: f32 = 3.0;
const STATUS_ZOOM_BORDER_WIDTH_CSS: f32 = 4.0;
const ZOOM_ICON_FOREGROUND_MIX: f32 = 0.30;
const ZOOM_BORDER_FOREGROUND_MIX: f32 = 0.60;
const DONE_PULSE_PERIOD_MS: i64 = 2800;
const WORKING_PULSE_PERIOD_MS: i64 = 2200;
const QUICK_PANE_MIN_W_CSS: f32 = 320.0;
const QUICK_PANE_MIN_H_CSS: f32 = 220.0;
const QUICK_PANE_MARGIN_CSS: f32 = 12.0;
const QUICK_PANE_DRAG_H_CSS: f32 = 28.0;
const QUICK_PANE_RESIZE_GRIP_CSS: f32 = 18.0;
const SCROLLING_WHEEL_STEP_CSS: f32 = 72.0;
const SCROLLING_SNAP_IDLE_MS: i64 = 120;
const SCROLLING_ANIMATION_DURATION_MS: i64 = 150;
const SCROLLING_ANIMATION_MAX_STEP_MS: i64 = 50;
const SCROLLING_ANIMATION_EPSILON: f32 = 0.5;
const SCROLLING_EDGE_BUTTON_THICKNESS_CSS: f32 = 32.0;
const SCROLLING_EDGE_BUTTON_LENGTH_CSS: f32 = 64.0;
const SCROLLING_EDGE_BUTTON_INSET_CSS: f32 = 6.0;
const SCROLLING_EDGE_HOVER_PAD_CSS: f32 = 14.0;
const SCROLLING_EDGE_CONTROL_Z: i32 = 170;

// Font Awesome glyphs bundled in SymbolsNerdFontMono and rendered with Palette's icon role.
const NF_FA_EXPAND = "\u{F065}";
const NF_FA_COMPRESS = "\u{F066}";
const NF_COD_CHEVRON_DOWN = "\u{EAB4}";
const NF_COD_CHEVRON_LEFT = "\u{EAB5}";
const NF_COD_CHEVRON_RIGHT = "\u{EAB6}";
const NF_COD_CHEVRON_UP = "\u{EAB7}";
const NF_COD_EDIT = "\u{EA73}";
const NF_COD_HISTORY = "\u{EA82}";
const NF_COD_TERMINAL = "\u{EA85}";

fn nowMs() i64 {
    return @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
}

const MAX_WORKSPACE_PANE_HITS = 48;
const WorkspacePaneAction = enum {
    focus,
    maximize,
    toggle_split_menu,
    copy_selection,
    paste_into_prompt,
    new_chat_thread,
    open_chat_history,
    open_terminal,
    refresh_chat_thread,
    split_chat_left,
    split_chat_right,
    split_chat_up,
    split_chat_down,
    split_terminal_left,
    split_terminal_right,
    split_terminal_up,
    split_terminal_down,
    close,
    resize_split,
    resize_scrolling_column,
    scrolling_previous,
    scrolling_next,
    move_quick_pane,
    resize_quick_pane,
};

const ScrollingEdgeDirection = enum { previous, next };

const WorkspacePaneHit = struct {
    pane_id: runtime.WorkspacePaneId = 0,
    sibling_pane_id: runtime.WorkspacePaneId = 0,
    action: WorkspacePaneAction = .focus,
    axis: runtime.WorkspaceSplitAxis = .horizontal,
    rect: palette.Rect = .{},
    split_rect: palette.Rect = .{},
    pane_index: usize = 0,
    scroll_offset: f32 = 0.0,
    /// Content-space origin of the pane at drag start. Trailing-edge drags
    /// keep this edge fixed; leading-edge drags keep the opposite edge fixed.
    drag_origin: f32 = 0.0,
    drag_extent: f32 = 0.0,
    leading_edge: bool = false,
};

const WorkspacePaneHitCache = struct {
    count: usize = 0,
    hits: [MAX_WORKSPACE_PANE_HITS]WorkspacePaneHit = [_]WorkspacePaneHit{.{}} ** MAX_WORKSPACE_PANE_HITS,
};

var hit_cache: WorkspacePaneHitCache = .{};
var resize_drag: ?WorkspacePaneHit = null;
const EMPTY_WORKSPACE_ACTION_COUNT: usize = 3;
var empty_workspace_selected_action: usize = 0;
const QuickPaneDragKind = enum { move, resize };
const QuickPaneDrag = struct {
    kind: QuickPaneDragKind,
    start_x: f32,
    start_y: f32,
    start: runtime.FloatingPaneGeometry,
    workspace: palette.Rect,
};
var quick_pane_drag: ?QuickPaneDrag = null;
var split_menu_open_for: ?runtime.WorkspacePaneId = null;
var split_menu_rect: palette.Rect = .{};
var split_submenu_rect: palette.Rect = .{};
var split_menu_anchor: palette.Rect = .{};
var split_menu_show_paste: bool = false;
const SplitMenuKind = enum { split_button, chat_context };
var split_menu_kind: SplitMenuKind = .split_button;

const MAX_WORKSPACE_PANE_RECTS = 16;
const WorkspacePaneRect = struct {
    pane_id: runtime.WorkspacePaneId,
    rect: palette.Rect,
};

const ThreadDropTarget = struct {
    pane_id: runtime.WorkspacePaneId,
    axis: runtime.WorkspaceSplitAxis,
    new_after: bool,
    preview: palette.Rect,
};

const PaneDragState = struct {
    pending: bool = false,
    active: bool = false,
    split_placement: bool = false,
    pane_id: runtime.WorkspacePaneId = 0,
    start_x: f32 = 0.0,
    start_y: f32 = 0.0,
    x: f32 = 0.0,
    y: f32 = 0.0,
};

var last_thread_drop_target: ?ThreadDropTarget = null;
var pane_drag: PaneDragState = .{};
var last_pane_drop_target: ?ThreadDropTarget = null;

var pane_rect_count: usize = 0;
var pane_rects: [MAX_WORKSPACE_PANE_RECTS]WorkspacePaneRect = undefined;
var last_workspace_rect: palette.Rect = .{};
var browser_pane_rendered: bool = false;
var scrolling_layout_rendered: bool = false;
var scrolling_max_offset: f32 = 0.0;
var scrolling_animating: bool = false;
var scrolling_previous_proximity: ?palette.Rect = null;
var scrolling_next_proximity: ?palette.Rect = null;
var scrolling_edge_pressed: ?ScrollingEdgeDirection = null;

var focus_prev_id: ?runtime.WorkspacePaneId = null;
var focus_curr_id: ?runtime.WorkspacePaneId = null;
var focus_anim_start_ms: i64 = std.math.minInt(i64) >> 2;
var focus_anim_duration_ms: i64 = theme.MOTION_BASE_MS;

pub fn isFocusAnimating() bool {
    return (nowMs() - focus_anim_start_ms) < focus_anim_duration_ms;
}

pub fn isScrollAnimating() bool {
    return scrolling_animating;
}

const PaneAgentVisualStatus = enum {
    idle,
    working,
    waiting,
    done,
    @"error",
};

var pane_status_animating = false;

pub fn isPaneStatusAnimating() bool {
    return pane_status_animating;
}

/// Handles navigation only while the selected workspace has no open panes.
pub fn handleEmptyWorkspaceKeyDown(state: *runtime.AppState, event: *const sdl.KeyboardEvent) bool {
    if (!emptyWorkspaceAcceptsKeyboard(state)) {
        empty_workspace_selected_action = 0;
        return false;
    }
    const modifiers = keymodBits(event.mod);
    if ((modifiers & (sdl.Keymod.ctrl | sdl.Keymod.gui | sdl.Keymod.alt | sdl.Keymod.shift)) != 0) return false;
    switch (event.key) {
        .up, .left => {
            empty_workspace_selected_action = emptyWorkspaceSelectionAfterMove(empty_workspace_selected_action, -1);
            state.markDirty();
            return true;
        },
        .down, .right => {
            empty_workspace_selected_action = emptyWorkspaceSelectionAfterMove(empty_workspace_selected_action, 1);
            state.markDirty();
            return true;
        },
        .@"return", .kp_enter => {
            const action: WorkspacePaneAction = switch (empty_workspace_selected_action) {
                0 => .new_chat_thread,
                1 => .open_chat_history,
                else => .open_terminal,
            };
            activateEmptyWorkspaceAction(state, action);
            empty_workspace_selected_action = 0;
            return true;
        },
        else => return false,
    }
}

fn emptyWorkspaceAcceptsKeyboard(state: *const runtime.AppState) bool {
    if (state.project_controller.projects.items.len == 0) return false;
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return false;
    if (state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout.visiblePaneCount() != 0) return false;
    if (state.currentProjectQuickPane()) |quick| if (quick.visible) return false;
    return true;
}

fn emptyWorkspaceSelectionAfterMove(current: usize, delta: i8) usize {
    if (delta < 0) return if (current == 0) EMPTY_WORKSPACE_ACTION_COUNT - 1 else current - 1;
    return (current + 1) % EMPTY_WORKSPACE_ACTION_COUNT;
}

fn activateEmptyWorkspaceAction(state: *runtime.AppState, action: WorkspacePaneAction) void {
    if (state.project_controller.projects.items.len == 0) return;
    switch (action) {
        .new_chat_thread => state.createThreadForProject(state.project_controller.selected_index),
        .open_chat_history => state.openCommandPalette(state.project_controller.selected_index),
        .open_terminal => _ = state.openTerminalPaneForProjectIndex(state.project_controller.selected_index),
        else => {},
    }
}

pub fn hasActivePaneDrag() bool {
    return pane_drag.pending or pane_drag.active;
}

pub fn handlePaletteWheel(state: *runtime.AppState, x: f32, y: f32, wheel_x: f32, wheel_y: f32, ctrl_held: bool) bool {
    if (!scrolling_layout_rendered) return false;
    if (!rectContains(last_workspace_rect, x, y)) return false;
    if (state.project_controller.projects.items.len == 0) return false;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    if (!scrollingLayoutActive(state, layout)) return false;

    const delta = scrollingWheelDelta(state.app_config.workspace_scroll_direction, wheel_x, wheel_y, ctrl_held) orelse return false;
    const target: *f32 = switch (state.app_config.workspace_scroll_direction) {
        .horizontal => &layout.scroll_target_x,
        .vertical => &layout.scroll_target_y,
    };
    const next_target = freeScrollTarget(
        target.*,
        delta,
        theme.scaledUi(SCROLLING_WHEEL_STEP_CSS),
        scrolling_max_offset,
    );
    if (@abs(next_target - target.*) > 0.001) {
        target.* = next_target;
        const timestamp = nowMs();
        layout.scroll_animation_last_ms = timestamp;
        layout.scroll_snap_deadline_ms = timestamp + SCROLLING_SNAP_IDLE_MS;
        state.markDirty();
    }
    layout.scroll_revealed_pane_id = layout.focused_pane_id;
    return true;
}

fn scrollingWheelDelta(direction: app_config.WorkspaceScrollDirection, wheel_x: f32, wheel_y: f32, ctrl_held: bool) ?f32 {
    return switch (direction) {
        .horizontal => if (@abs(wheel_x) >= 0.01 and @abs(wheel_x) >= @abs(wheel_y)) wheel_x else null,
        .vertical => if (ctrl_held and @abs(wheel_y) >= 0.01 and @abs(wheel_y) >= @abs(wheel_x)) -wheel_y else null,
    };
}

fn freeScrollTarget(current: f32, delta: f32, step: f32, max_offset: f32) f32 {
    return std.math.clamp(current + delta * step, 0.0, max_offset);
}

// Placement for a hotkey-opened pane while auto-building the 2x2 grid.
pub const GridPlacement = struct {
    pane_id: runtime.WorkspacePaneId,
    axis: runtime.WorkspaceSplitAxis,
    new_after: bool,
};

// Chooses where a new hotkey-opened pane should land so the first four panes
// form a 2x2 grid (TL -> TR -> BL -> BR) and a closed quadrant gets refilled.
// Returns null when the grid is full (>= 4 panes), when maximized, or when no
// geometry is available — callers then fall back to splitting the focused pane.
//
// The axis is driven by the build step, not aspect ratio: the first new pane
// splits side-by-side (a `.vertical` divider, i.e. left|right). The 2nd and 3rd
// then split the remaining full-height column into rows (`.horizontal`,
// top/bottom), which yields a square 2x2 on any display and naturally refills a
// collapsed column. (Aspect ratio fails on wide displays, where a half-width
// pane is still landscape and keeps spawning columns.)
pub fn gridNewPanePlacement(state: *runtime.AppState) ?GridPlacement {
    const placement = state.currentProjectGridNewPanePlacement() orelse return null;
    return .{ .pane_id = placement.pane_id, .axis = placement.axis, .new_after = placement.new_after };
}

pub const FocusDirection = enum { left, right, up, down };

fn scrollingPaneDirection(scroll_direction: app_config.WorkspaceScrollDirection, focus_direction: FocusDirection) ?runtime.WorkspacePaneDirection {
    return switch (scroll_direction) {
        .horizontal => switch (focus_direction) {
            .left => .left,
            .right => .right,
            .up, .down => null,
        },
        .vertical => switch (focus_direction) {
            .up => .up,
            .down => .down,
            .left, .right => null,
        },
    };
}

fn workspacePaneDirection(focus_direction: FocusDirection) runtime.WorkspacePaneDirection {
    return switch (focus_direction) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
    };
}

pub fn focusPaneInDirection(state: *runtime.AppState, dir: FocusDirection) bool {
    if (pane_rect_count == 0) return false;
    if (state.project_controller.projects.items.len == 0) return false;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    const current_id = layout.focused_pane_id orelse return false;
    const maximized = state.currentProjectWorkspaceMaximizedPaneId() != null;
    const scrolling_navigation = scrollingLayoutEnabled(
        layout.effectiveScrollMode(state.app_config.workspace_scroll_mode),
        layout.effectiveScrollThreshold(state.app_config.workspace_scroll_threshold),
        layout.visiblePaneCount(),
        false,
    );
    if (maximized) {
        if (scrolling_navigation) {
            const direction = workspacePaneDirection(dir);
            if (layout.neighborPaneId(current_id, direction)) |inner_target| {
                if (layout.panesShareScrollGroup(current_id, inner_target)) {
                    return focusPaneNavigationTarget(state, inner_target, true);
                }
            }
            const strip_direction = scrollingPaneDirection(state.app_config.workspace_scroll_direction, dir) orelse return false;
            const target = layout.adjacentScrollGroupPaneId(current_id, strip_direction) orelse return false;
            return focusPaneNavigationTarget(state, target, true);
        }
        if (state.currentProjectWorkspaceRoot()) |root| {
            var expanded_rects: [MAX_WORKSPACE_PANE_RECTS]WorkspacePaneRect = undefined;
            var expanded_count: usize = 0;
            collectNodePaneRects(root, pane_rects[0].rect, &expanded_rects, &expanded_count);
            if (focusPaneInDirectionFromRects(state, current_id, dir, expanded_rects[0..expanded_count], true)) return true;
        }
        return if (state.app_config.unzoom_on_pane_navigation)
            state.clearCurrentProjectWorkspacePaneMaximized()
        else
            false;
    }

    if (scrolling_navigation) {
        const direction = workspacePaneDirection(dir);
        if (layout.neighborPaneId(current_id, direction)) |inner_target| {
            if (layout.panesShareScrollGroup(current_id, inner_target)) {
                return focusPaneNavigationTarget(state, inner_target, false);
            }
        }
        const strip_direction = scrollingPaneDirection(state.app_config.workspace_scroll_direction, dir) orelse return false;
        const target = layout.adjacentScrollGroupPaneId(current_id, strip_direction) orelse return false;
        return focusPaneNavigationTarget(state, target, false);
    }

    return focusPaneInDirectionFromRects(state, current_id, dir, pane_rects[0..pane_rect_count], false);
}

pub fn openFocusedChatPaneContextMenu(state: *runtime.AppState) bool {
    if (state.project_controller.projects.items.len == 0) return false;
    const pane_id = state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout.focused_pane_id orelse return false;
    if (state.workspacePaneKindById(pane_id) != .chat) return false;
    var rect: ?palette.Rect = null;
    var i: usize = 0;
    while (i < pane_rect_count) : (i += 1) {
        if (pane_rects[i].pane_id == pane_id) {
            rect = pane_rects[i].rect;
            break;
        }
    }
    const pane_rect = rect orelse return false;
    split_menu_show_paste = false;
    split_menu_kind = .chat_context;
    split_menu_open_for = pane_id;
    split_menu_anchor = .{
        .x = pane_rect.x + @min(pane_rect.w * 0.5, theme.scaledUi(360.0)),
        .y = pane_rect.y + @min(pane_rect.h * 0.5, theme.scaledUi(320.0)),
        .w = 0.0,
        .h = 0.0,
    };
    state.markDirty();
    return true;
}

fn focusPaneInDirectionFromRects(
    state: *runtime.AppState,
    current_id: runtime.WorkspacePaneId,
    dir: FocusDirection,
    rects: []const WorkspacePaneRect,
    navigating_maximized: bool,
) bool {
    var current_rect: ?palette.Rect = null;
    var i: usize = 0;
    while (i < rects.len) : (i += 1) {
        if (rects[i].pane_id == current_id) {
            current_rect = rects[i].rect;
            break;
        }
    }
    const cur = current_rect orelse return false;
    const cx = cur.x + cur.w * 0.5;
    const cy = cur.y + cur.h * 0.5;

    var best_id: ?runtime.WorkspacePaneId = null;
    var best_score: f32 = std.math.inf(f32);

    i = 0;
    while (i < rects.len) : (i += 1) {
        const entry = rects[i];
        if (entry.pane_id == current_id) continue;
        const ex = entry.rect.x + entry.rect.w * 0.5;
        const ey = entry.rect.y + entry.rect.h * 0.5;
        const dx = ex - cx;
        const dy = ey - cy;
        const passes = switch (dir) {
            .left => dx < -1.0 and rangesOverlap(cur.y, cur.y + cur.h, entry.rect.y, entry.rect.y + entry.rect.h),
            .right => dx > 1.0 and rangesOverlap(cur.y, cur.y + cur.h, entry.rect.y, entry.rect.y + entry.rect.h),
            .up => dy < -1.0 and rangesOverlap(cur.x, cur.x + cur.w, entry.rect.x, entry.rect.x + entry.rect.w),
            .down => dy > 1.0 and rangesOverlap(cur.x, cur.x + cur.w, entry.rect.x, entry.rect.x + entry.rect.w),
        };
        if (!passes) continue;
        const primary = switch (dir) {
            .left, .right => @abs(dx),
            .up, .down => @abs(dy),
        };
        // Tie-break by perpendicular distance so a side-by-side candidate beats
        // a diagonal one that happens to share a single-pixel overlap.
        const perpendicular = switch (dir) {
            .left, .right => @abs(dy),
            .up, .down => @abs(dx),
        };
        const score = primary + perpendicular * 0.1;
        if (score < best_score) {
            best_score = score;
            best_id = entry.pane_id;
        }
    }

    const target = best_id orelse return false;
    return focusPaneNavigationTarget(state, target, navigating_maximized);
}

fn focusPaneNavigationTarget(state: *runtime.AppState, target: runtime.WorkspacePaneId, navigating_maximized: bool) bool {
    if (navigating_maximized) {
        if (state.app_config.unzoom_on_pane_navigation) {
            _ = state.clearCurrentProjectWorkspacePaneMaximized();
        } else {
            const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
            layout.maximized_pane_id = target;
        }
    }
    _ = state.focusCurrentProjectWorkspacePane(target);
    state.markDirty();
    return true;
}

fn collectNodePaneRects(
    node: *const runtime.WorkspaceNode,
    rect: palette.Rect,
    out: *[MAX_WORKSPACE_PANE_RECTS]WorkspacePaneRect,
    count: *usize,
) void {
    if (count.* >= out.len) return;
    switch (node.*) {
        .leaf => |pane_id| {
            out[count.*] = .{ .pane_id = pane_id, .rect = rect };
            count.* += 1;
        },
        .split => |split| {
            const gap = theme.scaledUi(1.0);
            if (split.axis == .vertical) {
                const first_w = @max(theme.scaledUi(180.0), rect.w * split.ratio - gap * 0.5);
                const second_w = @max(theme.scaledUi(180.0), rect.w - first_w - gap);
                const clamped_first_w = @max(theme.scaledUi(120.0), rect.w - second_w - gap);
                const first_rect = palette.Rect{ .x = rect.x, .y = rect.y, .w = clamped_first_w, .h = rect.h };
                const second_rect = palette.Rect{ .x = rect.x + clamped_first_w + gap, .y = rect.y, .w = @max(rect.w - clamped_first_w - gap, theme.scaledUi(120.0)), .h = rect.h };
                collectNodePaneRects(split.first, first_rect, out, count);
                collectNodePaneRects(split.second, second_rect, out, count);
            } else {
                const first_h = @max(theme.scaledUi(160.0), rect.h * split.ratio - gap * 0.5);
                const second_h = @max(theme.scaledUi(120.0), rect.h - first_h - gap);
                const clamped_first_h = @max(theme.scaledUi(120.0), rect.h - second_h - gap);
                const first_rect = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = clamped_first_h };
                const second_rect = palette.Rect{ .x = rect.x, .y = rect.y + clamped_first_h + gap, .w = rect.w, .h = @max(rect.h - clamped_first_h - gap, theme.scaledUi(120.0)) };
                collectNodePaneRects(split.first, first_rect, out, count);
                collectNodePaneRects(split.second, second_rect, out, count);
            }
        },
    }
}

fn rangesOverlap(a0: f32, a1: f32, b0: f32, b1: f32) bool {
    return a0 < b1 and b0 < a1;
}

const GROW_RATIO_STEP: f32 = 0.05;
/// Keyboard nudge for one scrolling pane. Large enough to feel like a drag
/// step, small enough that a few taps stay inside a typical laptop viewport.
const GROW_SCROLL_PANE_STEP_CSS: f32 = 96.0;

fn oppositeDirection(dir: FocusDirection) FocusDirection {
    return switch (dir) {
        .left => .right,
        .right => .left,
        .up => .down,
        .down => .up,
    };
}

fn findNeighborId(current_id: runtime.WorkspacePaneId, cur: palette.Rect, dir: FocusDirection) ?runtime.WorkspacePaneId {
    const cx = cur.x + cur.w * 0.5;
    const cy = cur.y + cur.h * 0.5;
    var best_id: ?runtime.WorkspacePaneId = null;
    var best_score: f32 = std.math.inf(f32);
    var i: usize = 0;
    while (i < pane_rect_count) : (i += 1) {
        const entry = pane_rects[i];
        if (entry.pane_id == current_id) continue;
        const ex = entry.rect.x + entry.rect.w * 0.5;
        const ey = entry.rect.y + entry.rect.h * 0.5;
        const dx = ex - cx;
        const dy = ey - cy;
        const passes = switch (dir) {
            .left => dx < -1.0 and rangesOverlap(cur.y, cur.y + cur.h, entry.rect.y, entry.rect.y + entry.rect.h),
            .right => dx > 1.0 and rangesOverlap(cur.y, cur.y + cur.h, entry.rect.y, entry.rect.y + entry.rect.h),
            .up => dy < -1.0 and rangesOverlap(cur.x, cur.x + cur.w, entry.rect.x, entry.rect.x + entry.rect.w),
            .down => dy > 1.0 and rangesOverlap(cur.x, cur.x + cur.w, entry.rect.x, entry.rect.x + entry.rect.w),
        };
        if (!passes) continue;
        const primary = switch (dir) {
            .left, .right => @abs(dx),
            .up, .down => @abs(dy),
        };
        const perpendicular = switch (dir) {
            .left, .right => @abs(dy),
            .up, .down => @abs(dx),
        };
        const score = primary + perpendicular * 0.1;
        if (score < best_score) {
            best_score = score;
            best_id = entry.pane_id;
        }
    }
    return best_id;
}

pub fn growPaneInDirection(state: *runtime.AppState, dir: FocusDirection) bool {
    if (state.project_controller.projects.items.len == 0) return false;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    if (scrollingLayoutActive(state, layout)) {
        const current_id = layout.focused_pane_id orelse return false;
        const neighbor = layout.neighborPaneId(current_id, workspacePaneDirection(dir));
        if (neighbor == null or !layout.panesShareScrollGroup(current_id, neighbor.?)) {
            return growScrollingPaneInDirection(state, layout, dir);
        }
    }
    if (pane_rect_count == 0) return false;
    const current_id = layout.focused_pane_id orelse return false;

    var current_rect: ?palette.Rect = null;
    var i: usize = 0;
    while (i < pane_rect_count) : (i += 1) {
        if (pane_rects[i].pane_id == current_id) {
            current_rect = pane_rects[i].rect;
            break;
        }
    }
    const cur = current_rect orelse return false;

    // Prefer the neighbor on the same side as the key direction so the user's
    // grow-toward-edge intent maps onto the boundary they expect. When there
    // is no neighbor on that side, fall back to the opposite neighbor so the
    // key still moves the nearest boundary (e.g. Alt+Shift+Left in the left
    // pane shrinks it by pulling its right edge in).
    var neighbor_side = dir;
    var neighbor_id = findNeighborId(current_id, cur, neighbor_side);
    if (neighbor_id == null) {
        neighbor_side = oppositeDirection(dir);
        neighbor_id = findNeighborId(current_id, cur, neighbor_side);
    }
    const target = neighbor_id orelse return false;

    const axis: runtime.WorkspaceSplitAxis = switch (dir) {
        .left, .right => .vertical,
        .up, .down => .horizontal,
    };
    // If the neighbor sits on the negative side of the axis (left/up), it is
    // the split's `first` child; otherwise it is `second`.
    const neighbor_is_first = (neighbor_side == .left) or (neighbor_side == .up);
    const first_id = if (neighbor_is_first) target else current_id;
    const second_id = if (neighbor_is_first) current_id else target;
    // Boundary direction: right/down = positive (ratio grows); left/up = negative.
    const positive = (dir == .right) or (dir == .down);
    const delta: f32 = if (positive) GROW_RATIO_STEP else -GROW_RATIO_STEP;
    return state.nudgeCurrentProjectWorkspaceSplit(first_id, second_id, axis, delta);
}

fn growScrollingPaneInDirection(
    state: *runtime.AppState,
    layout: *runtime.WorkspaceLayout,
    dir: FocusDirection,
) bool {
    const delta_css = scrollingGrowDeltaCss(state.app_config.workspace_scroll_direction, dir) orelse return false;
    const focused_pane_id = layout.focused_pane_id orelse return false;
    if (!layout.rootContainsPane(focused_pane_id)) return false;
    const group_id = layout.scrollGroupIdForPane(focused_pane_id) orelse return false;
    if (layout.scrollGroupPaneCount(group_id) > 1) return false;
    var extent_pane_id = focused_pane_id;
    var pane = layout.paneById(focused_pane_id) orelse return false;
    var chose_default = false;
    for (layout.panes.items) |*candidate| {
        if (layout.scrollGroupIdForPane(candidate.id) != group_id) continue;
        if (!chose_default) {
            extent_pane_id = candidate.id;
            pane = candidate;
            chose_default = true;
        }
        if (candidate.scroll_extent_css != null or candidate.scroll_extent_ratio != null) {
            extent_pane_id = candidate.id;
            pane = candidate;
            break;
        }
    }

    const vertical = state.app_config.workspace_scroll_direction == .vertical;
    const gap = theme.scaledUi(state.app_config.workspace_pane_gap);
    var group_ids: [MAX_WORKSPACE_PANE_RECTS]runtime.WorkspacePaneId = undefined;
    var representative_pane_ids: [MAX_WORKSPACE_PANE_RECTS]runtime.WorkspacePaneId = undefined;
    const group_count = collectScrollingGroups(layout, &group_ids, &representative_pane_ids);
    const raw_viewport_extent = if (vertical) last_workspace_rect.h else last_workspace_rect.w;
    const viewport_extent = scrollingViewportExtent(raw_viewport_extent, gap, group_count, state.app_config.workspace_panes_per_view);
    const ui_scale = theme.uiScaleFactor();
    const default_extent = responsiveScrollingPaneExtent(
        @max(viewport_extent, 1.0),
        gap,
        state.app_config.workspace_panes_per_view,
        layout.scroll_pane_extent_override,
        layout.scroll_pane_extent_ratio_override,
        ui_scale,
    );
    const current_css = scrollingGroupResolvedExtent(
        layout,
        group_id,
        pane,
        default_extent,
        @max(viewport_extent, 1.0),
        gap,
        ui_scale,
    ) / @max(ui_scale, 0.001);
    const next_css = scrollingPaneExtentAfterGrow(current_css, delta_css);
    if (@abs(next_css - current_css) <= 0.001) return false;

    const extent_ratio = if (viewport_extent > 1.0)
        scrollingPaneExtentRatio(next_css * ui_scale, viewport_extent, gap)
    else
        0.0;
    if (!layout.setPaneScrollExtent(extent_pane_id, next_css, extent_ratio)) return false;
    // Re-reveal on the next frame so a wider pane is not left clipped.
    layout.scroll_revealed_pane_id = null;
    state.markDirty();
    return true;
}

fn scrollingGrowDeltaCss(scroll_direction: app_config.WorkspaceScrollDirection, dir: FocusDirection) ?f32 {
    return switch (scroll_direction) {
        .horizontal => switch (dir) {
            .right => GROW_SCROLL_PANE_STEP_CSS,
            .left => -GROW_SCROLL_PANE_STEP_CSS,
            .up, .down => null,
        },
        .vertical => switch (dir) {
            .down => GROW_SCROLL_PANE_STEP_CSS,
            .up => -GROW_SCROLL_PANE_STEP_CSS,
            .left, .right => null,
        },
    };
}

fn scrollingPaneExtentAfterGrow(current_css: f32, delta_css: f32) f32 {
    return theme.clampf(
        current_css + delta_css,
        workspace_layout.MIN_SCROLL_PANE_EXTENT_CSS,
        workspace_layout.MAX_SCROLL_PANE_EXTENT_CSS,
    );
}

pub fn movePaneInDirection(state: *runtime.AppState, dir: FocusDirection) bool {
    if (pane_rect_count == 0) return false;
    if (state.project_controller.projects.items.len == 0) return false;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    const current_id = layout.focused_pane_id orelse return false;

    if (scrollingLayoutActive(state, layout)) {
        const direction = scrollingPaneDirection(state.app_config.workspace_scroll_direction, dir) orelse return false;
        const target = layout.adjacentTiledPaneIdInSidebarOrder(current_id, direction) orelse return false;
        if (!state.swapCurrentProjectWorkspacePanes(current_id, target)) return false;
        return state.focusCurrentProjectWorkspacePane(target);
    }

    var current_rect: ?palette.Rect = null;
    var i: usize = 0;
    while (i < pane_rect_count) : (i += 1) {
        if (pane_rects[i].pane_id == current_id) {
            current_rect = pane_rects[i].rect;
            break;
        }
    }
    const cur = current_rect orelse return false;
    const target = findNeighborId(current_id, cur, dir) orelse return false;
    if (!state.swapCurrentProjectWorkspacePanes(current_id, target)) return false;
    _ = state.focusCurrentProjectWorkspacePane(target);
    state.markDirty();
    return true;
}

fn tickFocusAnimation(state: *runtime.AppState) void {
    if (state.project_controller.projects.items.len == 0) return;
    const focused = state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout.focused_pane_id;
    const same = (focus_curr_id == null and focused == null) or
        (focus_curr_id != null and focused != null and focus_curr_id.? == focused.?);
    if (same) return;
    focus_prev_id = focus_curr_id;
    focus_curr_id = focused;
    focus_anim_start_ms = nowMs();
}

fn paneAgentVisualStatus(state: *const runtime.AppState, pane_id: runtime.WorkspacePaneId) PaneAgentVisualStatus {
    if (state.project_controller.projects.items.len == 0 or state.project_controller.selected_index >= state.project_controller.projects.items.len) return .idle;
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return .idle;
    return switch (pane.ref) {
        .chat => |ref| blk: {
            if (ref.thread_index >= project.threads.items.len) break :blk .idle;
            const thread = &project.threads.items[ref.thread_index];
            break :blk switch (thread.activityStatusForUi()) {
                .idle => .idle,
                .working => .working,
                .waiting => .waiting,
                .done => .done,
                .@"error" => .@"error",
            };
        },
        .terminal => |ref| blk: {
            const surface = state.projectTerminalSurface(state.project_controller.selected_index, ref.dock_id) orelse break :blk .idle;
            break :blk switch (surface.displayStatus()) {
                .done => .done,
                .working => .working,
                .waiting => .waiting,
                .@"error" => .@"error",
                .idle => .idle,
            };
        },
        .browser => .idle,
    };
}

fn paneStatusPulse(status: PaneAgentVisualStatus, timestamp_ms: i64) f32 {
    const period_ms = switch (status) {
        .done => DONE_PULSE_PERIOD_MS,
        .working, .waiting, .@"error" => WORKING_PULSE_PERIOD_MS,
        .idle => return 0.0,
    };
    const elapsed: f32 = @floatFromInt(@mod(timestamp_ms, period_ms));
    const phase = elapsed / @as(f32, @floatFromInt(period_ms));
    return 0.5 + 0.5 * @sin(phase * std.math.tau);
}

fn paneStatusPulseForMotion(status: PaneAgentVisualStatus, timestamp_ms: i64, reduced_motion: bool) f32 {
    return if (reduced_motion) 1.0 else paneStatusPulse(status, timestamp_ms);
}

fn focusBorderAlpha(pane_id: runtime.WorkspacePaneId) f32 {
    const elapsed = nowMs() - focus_anim_start_ms;
    const t = if (elapsed >= focus_anim_duration_ms)
        @as(f32, 1.0)
    else if (elapsed <= 0)
        @as(f32, 0.0)
    else
        @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(focus_anim_duration_ms));
    const ease = theme.easeOutCubic(t);
    if (focus_curr_id) |id| if (id == pane_id) return ease;
    if (focus_prev_id) |id| if (id == pane_id) return 1.0 - ease;
    return 0.0;
}

fn paneUsesRestingBorder(is_root_pane: bool, visible_pane_count: usize, maximized: bool) bool {
    return is_root_pane and visible_pane_count > 1 and !maximized;
}

test "resting pane borders appear only throughout tiled layouts" {
    try std.testing.expect(paneUsesRestingBorder(true, 2, false));
    try std.testing.expect(!paneUsesRestingBorder(true, 1, false));
    try std.testing.expect(!paneUsesRestingBorder(true, 2, true));
    try std.testing.expect(!paneUsesRestingBorder(false, 2, false));
}

/// Renders workspace panes with transcript geometry matching the visible pane.
pub fn renderAt(state: *runtime.AppState, rect: palette.Rect) void {
    renderAtWithTranscriptLayoutWidth(state, rect, rect.w);
}

/// Renders workspace panes while transcripts use their destination sidebar width.
pub fn renderAtWithTranscriptLayoutWidth(state: *runtime.AppState, rect: palette.Rect, target_workspace_width: f32) void {
    last_workspace_rect = rect;
    focus_anim_duration_ms = theme.motionDurationMs(state.app_config.reduced_motion, theme.MOTION_BASE_MS);
    state.terminal_controller.debug_workspace_visible_pane_count = state.currentProjectWorkspaceVisiblePaneCount();
    tickFocusAnimation(state);
    pane_status_animating = false;
    scrolling_layout_rendered = false;
    scrolling_max_offset = 0.0;
    scrolling_animating = false;
    state.transcript_controller.motion_suppressed = false;
    scrolling_previous_proximity = null;
    scrolling_next_proximity = null;
    hit_cache.count = 0;
    pane_rect_count = 0;
    browser_pane_rendered = false;
    chat_panel.resetWorkspaceHeaderHitCache();
    chat_panel.resetTranscriptHitCache();
    terminal_panel.resetHitCache();

    if (state.project_controller.projects.items.len == 0 or state.currentProjectWorkspaceRoot() != null) {
        empty_workspace_selected_action = 0;
    }

    if (state.currentProjectWorkspaceMaximizedPaneId()) |pane_id| {
        renderLeafWithTranscriptLayoutWidth(state, pane_id, rect, target_workspace_width);
    } else if (state.currentProjectWorkspaceRoot()) |root| {
        const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
        if (scrollingLayoutActive(state, layout)) {
            renderScrollingStrip(state, layout, rect, target_workspace_width);
        } else {
            const gap = theme.scaledUi(state.app_config.workspace_pane_gap);
            const pane_count = layout.visiblePaneCount();
            renderNode(
                state,
                root,
                tiledContentRect(rect, gap, pane_count),
                tiledContentExtent(target_workspace_width, gap, pane_count),
            );
        }
    } else if (state.project_controller.projects.items.len > 0) {
        renderEmptyWorkspace(state, rect);
    } else {
        empty_workspace_selected_action = 0;
        chat_panel.renderWorkspaceAtWithTranscriptLayoutWidth(state, rect, target_workspace_width);
    }

    renderQuickPane(state, rect, target_workspace_width);
    renderSplitMenuOverlay(state, rect);
    if (!browser_pane_rendered) state.noteBrowserPaneNotRendered();
}

// Empty workspace invitation shown after the final pane closes.
fn renderEmptyWorkspace(state: *runtime.AppState, rect: palette.Rect) void {
    queueRect(state, rect, paletteColor(theme.background()));

    const content_w = @max(1.0, @min(rect.w - theme.scaledUi(32.0), theme.scaledUi(380.0)));
    const title_size = theme.scaledUi(28.0);
    const body_size = theme.scaledUi(14.0);
    const button_w = @min(content_w, theme.scaledUi(280.0));
    const button_h = theme.scaledUi(38.0);
    const content_h = theme.scaledUi(232.0);
    const x = rect.x + (rect.w - content_w) * 0.5;
    var y = rect.y + @max(0.0, (rect.h - content_h) * 0.5);

    const title = "No open panes";
    const title_w = runtime.paletteUiTextPrefixWidth(title, title_size, title.len);
    queueText(state, .{ .x = x + @max(0.0, (content_w - title_w) * 0.5), .y = y, .w = @min(content_w, title_w), .h = title_size * 1.3 }, title, paletteColor(theme.COLOR_WHITE), title_size, rect);
    y += theme.scaledUi(42.0);
    const body = "Start a chat or open a terminal from this workspace.";
    const body_w = runtime.paletteUiTextPrefixWidth(body, body_size, body.len);
    queueText(state, .{ .x = x + @max(0.0, (content_w - body_w) * 0.5), .y = y, .w = @min(content_w, body_w), .h = body_size * 1.4 }, body, paletteColor(theme.COLOR_TEXT_MUTED), body_size, rect);
    y += theme.scaledUi(34.0);

    var new_chat_hint_buf: [32]u8 = undefined;
    var history_hint_buf: [32]u8 = undefined;
    var terminal_hint_buf: [32]u8 = undefined;
    const config = state.command_controller.keyboard_config;
    const new_chat_hint = if (config) |loaded| firstKeybindHint(&new_chat_hint_buf, loaded.new_thread) else "Ctrl+T";
    const history_hint = if (config) |loaded| firstKeybindHint(&history_hint_buf, loaded.command_palette) else "Ctrl+Shift+P";
    const terminal_hint = if (config) |loaded| firstKeybindHint(&terminal_hint_buf, loaded.workspace_split_terminal_horizontal) else "Ctrl+Shift+T";
    const button_x = rect.x + (rect.w - button_w) * 0.5;
    renderEmptyWorkspaceAction(state, .{ .x = button_x, .y = y, .w = button_w, .h = button_h }, NF_COD_EDIT, "New chat", new_chat_hint, .new_chat_thread, true, empty_workspace_selected_action == 0);
    y += button_h + theme.scaledUi(8.0);
    renderEmptyWorkspaceAction(state, .{ .x = button_x, .y = y, .w = button_w, .h = button_h }, NF_COD_HISTORY, "Open previous chat", history_hint, .open_chat_history, false, empty_workspace_selected_action == 1);
    y += button_h + theme.scaledUi(8.0);
    renderEmptyWorkspaceAction(state, .{ .x = button_x, .y = y, .w = button_w, .h = button_h }, NF_COD_TERMINAL, "Open terminal pane", terminal_hint, .open_terminal, false, empty_workspace_selected_action == 2);
}

fn firstKeybindHint(buf: []u8, bindings: []const keybinds.Keybind) []const u8 {
    if (bindings.len == 0) return "";
    return keybinds.formatKeybind(buf, bindings[0]);
}

// One empty-workspace action row with its configured shortcut.
fn renderEmptyWorkspaceAction(
    state: *runtime.AppState,
    rect: palette.Rect,
    icon: []const u8,
    label: []const u8,
    shortcut: []const u8,
    action: WorkspacePaneAction,
    primary: bool,
    selected: bool,
) void {
    const hovered = state.transcript_controller.palette_mouse_in_workspace and
        rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    const base_color = if (primary) theme.accent() else theme.COLOR_PANEL_ALT;
    const button_color = if (hovered or selected) theme.lighten(base_color, 0.08) else base_color;
    queueRounded(state, rect, paletteColor(button_color), theme.scaledUi(7.0));
    const border_color = if (selected and primary)
        theme.COLOR_WHITE
    else if (selected)
        theme.accent()
    else
        theme.borderMuted();
    if (!primary or selected) queueBorder(state, rect, paletteColor(border_color), theme.scaledUi(7.0), theme.scaledUi(if (selected) 2.0 else 1.0));

    const font_size = theme.scaledUi(14.0);
    const icon_size = theme.scaledUi(15.0);
    const left = rect.x + theme.scaledUi(13.0);
    queueIcon(state, .{ .x = left, .y = rect.y + (rect.h - icon_size) * 0.5, .w = icon_size, .h = icon_size }, icon, paletteColor(theme.COLOR_WHITE), icon_size, rect);
    const label_w = runtime.paletteUiTextPrefixWidth(label, font_size, label.len);
    queueText(state, .{ .x = left + theme.scaledUi(24.0), .y = rect.y + (rect.h - font_size * 1.25) * 0.5, .w = @min(label_w, rect.w * 0.58), .h = font_size * 1.25 }, label, paletteColor(theme.COLOR_WHITE), font_size, rect);
    if (shortcut.len > 0) {
        const hint_size = theme.scaledUi(11.0);
        const hint_w = runtime.paletteUiTextPrefixWidth(shortcut, hint_size, shortcut.len);
        queueText(state, .{ .x = rect.x + rect.w - theme.scaledUi(13.0) - hint_w, .y = rect.y + (rect.h - hint_size * 1.25) * 0.5, .w = hint_w, .h = hint_size * 1.25 }, shortcut, paletteColor(if (primary) theme.withAlpha(theme.COLOR_WHITE, 190) else theme.COLOR_TEXT_SUBTLE), hint_size, rect);
    }
    appendHit(.{ .action = action, .rect = rect });
}

// Floating quick-pane overlay above the unchanged tiled workspace.
fn renderQuickPane(state: *runtime.AppState, workspace_rect: palette.Rect, target_workspace_width: f32) void {
    const quick = state.currentProjectQuickPane() orelse return;
    if (!quick.visible) return;
    if (!quick.pinned) {
        queueRect(state, workspace_rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL, 92)));
    }
    const rect = quickPaneRect(quick, workspace_rect);
    var target_workspace_rect = workspace_rect;
    target_workspace_rect.w = target_workspace_width;
    const target_rect = quickPaneRect(quick, target_workspace_rect);
    queueRect(state, .{
        .x = rect.x - theme.scaledUi(2.0),
        .y = rect.y - theme.scaledUi(2.0),
        .w = rect.w + theme.scaledUi(4.0),
        .h = rect.h + theme.scaledUi(4.0),
    }, paletteColor(theme.withAlpha(theme.COLOR_PANEL, 210)));
    renderLeafWithTranscriptLayoutWidth(state, quick.pane_id, rect, target_rect.w);

    const drag_h = theme.scaledUi(QUICK_PANE_DRAG_H_CSS);
    appendHit(.{
        .pane_id = quick.pane_id,
        .action = .move_quick_pane,
        .rect = .{ .x = rect.x, .y = rect.y, .w = @max(0.0, rect.w - theme.scaledUi(112.0)), .h = drag_h },
    });
    if (!quick.maximized) {
        const grip = theme.scaledUi(QUICK_PANE_RESIZE_GRIP_CSS);
        appendHit(.{
            .pane_id = quick.pane_id,
            .action = .resize_quick_pane,
            .rect = .{ .x = rect.x + rect.w - grip, .y = rect.y + rect.h - grip, .w = grip, .h = grip },
        });
        queueBorder(state, rect, paletteColor(theme.accent()), theme.scaledUi(6.0), theme.scaledUi(2.0));
    }
}

fn quickPaneRect(quick: runtime.FloatingQuickPane, workspace: palette.Rect) palette.Rect {
    const margin = theme.scaledUi(QUICK_PANE_MARGIN_CSS);
    if (quick.maximized) {
        return .{
            .x = workspace.x + margin,
            .y = workspace.y + margin,
            .w = @max(1.0, workspace.w - margin * 2.0),
            .h = @max(1.0, workspace.h - margin * 2.0),
        };
    }
    const min_w = @min(theme.scaledUi(QUICK_PANE_MIN_W_CSS), @max(1.0, workspace.w - margin * 2.0));
    const min_h = @min(theme.scaledUi(QUICK_PANE_MIN_H_CSS), @max(1.0, workspace.h - margin * 2.0));
    const w = std.math.clamp(workspace.w * quick.geometry.w, min_w, @max(min_w, workspace.w - margin * 2.0));
    const h = std.math.clamp(workspace.h * quick.geometry.h, min_h, @max(min_h, workspace.h - margin * 2.0));
    const x = std.math.clamp(workspace.x + workspace.w * quick.geometry.x, workspace.x + margin, workspace.x + workspace.w - w - margin);
    const y = std.math.clamp(workspace.y + workspace.h * quick.geometry.y, workspace.y + margin, workspace.y + workspace.h - h - margin);
    return .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool, ctrl_down: bool, shift_down: bool) bool {
    if (button == 3 and down) {
        // Right-click on a pane opens the pane context menu anchored at the cursor.
        var ri: usize = hit_cache.count;
        while (ri > 0) {
            ri -= 1;
            const hit = hit_cache.hits[ri];
            if (hit.action != .focus) continue;
            if (!rectContains(hit.rect, x, y)) continue;
            _ = state.focusCurrentProjectWorkspacePane(hit.pane_id);
            split_menu_show_paste = false;
            split_menu_kind = .chat_context;
            if (state.composer_controller.composer.textRect().contains(.{ .x = x, .y = y })) {
                if (state.readClipboardTextForPaste()) |text| {
                    split_menu_show_paste = text.len > 0;
                    state.allocator.free(text);
                }
            }
            split_menu_open_for = hit.pane_id;
            split_menu_anchor = .{ .x = x, .y = y, .w = 0.0, .h = 0.0 };
            return true;
        }
        ri = pane_rect_count;
        while (ri > 0) {
            ri -= 1;
            const pane_rect = pane_rects[ri];
            if (!rectContains(pane_rect.rect, x, y)) continue;
            _ = state.focusCurrentProjectWorkspacePane(pane_rect.pane_id);
            split_menu_show_paste = false;
            split_menu_kind = .chat_context;
            if (state.composer_controller.composer.textRect().contains(.{ .x = x, .y = y })) {
                if (state.readClipboardTextForPaste()) |text| {
                    split_menu_show_paste = text.len > 0;
                    state.allocator.free(text);
                }
            }
            split_menu_open_for = pane_rect.pane_id;
            split_menu_anchor = .{ .x = x, .y = y, .w = 0.0, .h = 0.0 };
            return true;
        }
        return false;
    }
    if (button != 1) return false;
    if (!down) {
        if (quick_pane_drag != null) {
            quick_pane_drag = null;
            return true;
        }
        if (pane_drag.pending or pane_drag.active) return finishPaneDrag(state, x, y);
        if (resize_drag != null) {
            resize_drag = null;
            return true;
        }
        return false;
    }
    if (ctrl_down and beginPaneDrag(state, x, y, shift_down)) return true;
    var i: usize = hit_cache.count;
    while (i > 0) {
        i -= 1;
        const hit = hit_cache.hits[i];
        if (!rectContains(hit.rect, x, y)) continue;
        switch (hit.action) {
            .focus => {
                _ = state.focusCurrentProjectWorkspacePane(hit.pane_id);
                if (split_menu_open_for) |id| {
                    if (id != hit.pane_id) split_menu_open_for = null;
                }
            },
            .maximize => {
                _ = state.toggleCurrentProjectWorkspacePaneMaximized(hit.pane_id);
                split_menu_open_for = null;
            },
            .toggle_split_menu => toggleSplitMenu(state, hit),
            .copy_selection => {
                copyTranscriptSelectionToClipboard(state);
                split_menu_open_for = null;
            },
            .paste_into_prompt => {
                _ = state.pasteClipboardTextIntoPaletteComposer();
                split_menu_open_for = null;
            },
            .new_chat_thread => {
                activateEmptyWorkspaceAction(state, hit.action);
                split_menu_open_for = null;
            },
            .open_chat_history => {
                activateEmptyWorkspaceAction(state, hit.action);
                split_menu_open_for = null;
            },
            .open_terminal => {
                activateEmptyWorkspaceAction(state, hit.action);
                split_menu_open_for = null;
            },
            .refresh_chat_thread => {
                if (state.project_controller.projects.items.len > 0) {
                    const thread_index = state.currentProject().selected_thread_index;
                    state.syncThreadFromProvider(state.project_controller.selected_index, thread_index);
                }
                split_menu_open_for = null;
            },
            .split_chat_left => {
                _ = state.splitCurrentProjectWorkspacePaneWithChatPlacement(hit.pane_id, .vertical, false);
                split_menu_open_for = null;
            },
            .split_chat_right => {
                _ = state.splitCurrentProjectWorkspacePaneWithChatPlacement(hit.pane_id, .vertical, true);
                split_menu_open_for = null;
            },
            .split_chat_up => {
                _ = state.splitCurrentProjectWorkspacePaneWithChatPlacement(hit.pane_id, .horizontal, false);
                split_menu_open_for = null;
            },
            .split_chat_down => {
                _ = state.splitCurrentProjectWorkspacePaneWithChatPlacement(hit.pane_id, .horizontal, true);
                split_menu_open_for = null;
            },
            .split_terminal_left => {
                _ = state.splitCurrentProjectWorkspacePaneWithTerminalPlacement(hit.pane_id, .vertical, false);
                split_menu_open_for = null;
            },
            .split_terminal_right => {
                _ = state.splitCurrentProjectWorkspacePaneWithTerminalPlacement(hit.pane_id, .vertical, true);
                split_menu_open_for = null;
            },
            .split_terminal_up => {
                _ = state.splitCurrentProjectWorkspacePaneWithTerminalPlacement(hit.pane_id, .horizontal, false);
                split_menu_open_for = null;
            },
            .split_terminal_down => {
                _ = state.splitCurrentProjectWorkspacePaneWithTerminalPlacement(hit.pane_id, .horizontal, true);
                split_menu_open_for = null;
            },
            .close => {
                _ = state.closeCurrentProjectWorkspacePane(hit.pane_id);
                split_menu_open_for = null;
            },
            .resize_split, .resize_scrolling_column => {
                resize_drag = hit;
                updateResizeDrag(state, hit, x, y);
            },
            .scrolling_previous => focusScrollingEdgePane(state, .previous),
            .scrolling_next => focusScrollingEdgePane(state, .next),
            .move_quick_pane, .resize_quick_pane => {
                const quick = state.currentProjectQuickPane() orelse return false;
                quick_pane_drag = .{
                    .kind = if (hit.action == .move_quick_pane) .move else .resize,
                    .start_x = x,
                    .start_y = y,
                    .start = quick.geometry,
                    .workspace = last_workspace_rect,
                };
                _ = state.focusCurrentProjectWorkspacePane(hit.pane_id);
            },
        }
        return true;
    }
    // No hit matched. If the split menu is open, dismiss on outside click;
    // absorb clicks that landed inside the menu panel but missed a cell so it stays open.
    if (split_menu_open_for != null) {
        if (rectContains(split_menu_rect, x, y) or rectContains(split_submenu_rect, x, y)) return true;
        split_menu_open_for = null;
        return true;
    }
    i = pane_rect_count;
    while (i > 0) {
        i -= 1;
        const pane_rect = pane_rects[i];
        if (!rectContains(pane_rect.rect, x, y)) continue;
        _ = state.focusCurrentProjectWorkspacePane(pane_rect.pane_id);
        return false;
    }
    return false;
}

/// Handles pane chrome before browser and terminal content can consume its click.
pub fn handlePaneChromeMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool) bool {
    if (button != 1) return false;
    if (!down and scrolling_edge_pressed != null) {
        scrolling_edge_pressed = null;
        return true;
    }
    if (down) scrolling_edge_pressed = null;
    if (!down and quick_pane_drag != null) {
        quick_pane_drag = null;
        return true;
    }
    var i: usize = hit_cache.count;
    while (i > 0) {
        i -= 1;
        const hit = hit_cache.hits[i];
        if (!rectContains(hit.rect, x, y)) continue;
        switch (hit.action) {
            .maximize => {
                if (down) _ = state.toggleCurrentProjectWorkspacePaneMaximized(hit.pane_id);
            },
            .toggle_split_menu => {
                if (down) toggleSplitMenu(state, hit);
            },
            .scrolling_previous, .scrolling_next => {
                if (down) {
                    const direction: ScrollingEdgeDirection = if (hit.action == .scrolling_previous) .previous else .next;
                    scrolling_edge_pressed = direction;
                    focusScrollingEdgePane(state, direction);
                }
            },
            .move_quick_pane, .resize_quick_pane => {
                if (down) {
                    const quick = state.currentProjectQuickPane() orelse return false;
                    quick_pane_drag = .{
                        .kind = if (hit.action == .move_quick_pane) .move else .resize,
                        .start_x = x,
                        .start_y = y,
                        .start = quick.geometry,
                        .workspace = last_workspace_rect,
                    };
                    _ = state.focusCurrentProjectWorkspacePane(hit.pane_id);
                }
            },
            else => continue,
        }
        return true;
    }
    return false;
}

fn toggleSplitMenu(state: *runtime.AppState, hit: WorkspacePaneHit) void {
    _ = state.focusCurrentProjectWorkspacePane(hit.pane_id);
    split_menu_show_paste = false;
    split_menu_kind = .split_button;
    split_menu_anchor = hit.rect;
    if (split_menu_open_for) |id| {
        split_menu_open_for = if (id == hit.pane_id) null else hit.pane_id;
    } else {
        split_menu_open_for = hit.pane_id;
    }
}

/// Returns the system cursor for interactive workspace pane chrome.
pub fn systemCursorAt(x: f32, y: f32) ?sdl.SystemCursor {
    if (resize_drag) |hit| return resizeSystemCursor(hit.axis);
    var i: usize = hit_cache.count;
    while (i > 0) {
        i -= 1;
        const hit = hit_cache.hits[i];
        if (!rectContains(hit.rect, x, y)) continue;
        return switch (hit.action) {
            .focus => null,
            .resize_split, .resize_scrolling_column => resizeSystemCursor(hit.axis),
            else => .pointer,
        };
    }
    return null;
}

fn resizeSystemCursor(axis: runtime.WorkspaceSplitAxis) sdl.SystemCursor {
    return if (axis == .vertical) .ew_resize else .ns_resize;
}

pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32, ctrl_down: bool) bool {
    if (quick_pane_drag) |drag| {
        const dx = (x - drag.start_x) / @max(drag.workspace.w, 1.0);
        const dy = (y - drag.start_y) / @max(drag.workspace.h, 1.0);
        var geometry = drag.start;
        switch (drag.kind) {
            .move => {
                geometry.x += dx;
                geometry.y += dy;
            },
            .resize => {
                geometry.w += dx;
                geometry.h += dy;
            },
        }
        state.setCurrentProjectQuickPaneGeometry(geometry);
        return true;
    }
    if (pane_drag.pending or pane_drag.active) {
        if (!ctrl_down) {
            cancelPaneDrag();
            state.markDirty();
            return true;
        }
        updatePaneDrag(state, x, y);
        return true;
    }
    if (resize_drag) |hit| {
        updateResizeDrag(state, hit, x, y);
        return true;
    }
    // The edge affordance owns hover intent so a partially visible pane below
    // it cannot focus first and make the subsequent click skip two panes.
    if (scrollingEdgeProximityContains(x, y)) return false;
    // Focus-follows-mouse: hovering into a pane focuses it. Skip while a split
    // menu is open and the cursor is inside that menu so the open pane stays put.
    if (split_menu_open_for != null and (rectContains(split_menu_rect, x, y) or rectContains(split_submenu_rect, x, y))) return false;
    var i: usize = pane_rect_count;
    while (i > 0) {
        i -= 1;
        const entry = pane_rects[i];
        if (!rectContains(entry.rect, x, y)) continue;
        if (state.isCurrentProjectWorkspacePaneFocused(entry.pane_id)) return false;
        _ = state.focusCurrentProjectWorkspacePane(entry.pane_id);
        state.markDirty();
        if (split_menu_open_for) |id| {
            if (id != entry.pane_id) split_menu_open_for = null;
        }
        return false;
    }
    return false;
}

/// Renders the theme-accent drop overlay while Ctrl-dragging a workspace pane.
pub fn renderPaneDragPreview(state: *runtime.AppState) void {
    if (!pane_drag.active) return;
    const maybe_target = paneDragTargetAt(pane_drag.pane_id, pane_drag.x, pane_drag.y, pane_drag.split_placement);
    last_pane_drop_target = maybe_target;
    const target = maybe_target orelse return;
    const previous_z = state.palette_overlay_batch.setZIndex(THREAD_DROP_PREVIEW_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);
    renderPlacementPreview(state, target.preview);
}

pub fn renderThreadDropPreview(state: *runtime.AppState, x: f32, y: f32) void {
    const maybe_target = threadDropTargetAt(x, y);
    last_thread_drop_target = maybe_target;
    const target = maybe_target orelse return;
    const previous_z = state.palette_overlay_batch.setZIndex(THREAD_DROP_PREVIEW_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);
    renderPlacementPreview(state, target.preview);
}

pub fn clearThreadDropTarget() void {
    last_thread_drop_target = null;
}

pub fn dropThreadAt(state: *runtime.AppState, thread_index: usize, x: f32, y: f32) bool {
    const target = threadDropTargetAt(x, y) orelse last_thread_drop_target orelse return false;
    last_thread_drop_target = null;
    return state.splitCurrentProjectWorkspacePaneWithThread(target.pane_id, thread_index, target.axis, target.new_after);
}

fn threadDropTargetAt(x: f32, y: f32) ?ThreadDropTarget {
    var i: usize = pane_rect_count;
    while (i > 0) {
        i -= 1;
        const entry = pane_rects[i];
        if (!rectContains(entry.rect, x, y)) continue;
        return threadDropTargetForPane(entry.pane_id, entry.rect, x, y);
    }
    return null;
}

fn paneDragTargetAt(source_pane_id: runtime.WorkspacePaneId, x: f32, y: f32, split_placement: bool) ?ThreadDropTarget {
    var i: usize = pane_rect_count;
    while (i > 0) {
        i -= 1;
        const entry = pane_rects[i];
        if (entry.pane_id == source_pane_id) continue;
        if (!rectContains(entry.rect, x, y)) continue;
        if (split_placement) return threadDropTargetForPane(entry.pane_id, entry.rect, x, y);
        return .{ .pane_id = entry.pane_id, .axis = .vertical, .new_after = true, .preview = entry.rect };
    }
    return null;
}

fn beginPaneDrag(state: *runtime.AppState, x: f32, y: f32, split_placement: bool) bool {
    if (state.currentProjectWorkspaceVisiblePaneCount() <= 1) return false;
    var i: usize = pane_rect_count;
    while (i > 0) {
        i -= 1;
        const entry = pane_rects[i];
        if (!rectContains(entry.rect, x, y)) continue;
        pane_drag = .{
            .pending = true,
            .split_placement = split_placement,
            .pane_id = entry.pane_id,
            .start_x = x,
            .start_y = y,
            .x = x,
            .y = y,
        };
        last_pane_drop_target = null;
        split_menu_open_for = null;
        resize_drag = null;
        _ = state.focusCurrentProjectWorkspacePane(entry.pane_id);
        _ = sdl.captureMouse(true);
        state.markDirty();
        return true;
    }
    return false;
}

fn updatePaneDrag(state: *runtime.AppState, x: f32, y: f32) void {
    pane_drag.x = x;
    pane_drag.y = y;
    if (pane_drag.pending) {
        const dx = x - pane_drag.start_x;
        const dy = y - pane_drag.start_y;
        const threshold = theme.scaledUi(PANE_DRAG_THRESHOLD_CSS);
        if (dx * dx + dy * dy >= threshold * threshold) {
            pane_drag.pending = false;
            pane_drag.active = true;
        }
    }
    if (pane_drag.active) last_pane_drop_target = paneDragTargetAt(pane_drag.pane_id, x, y, pane_drag.split_placement);
    state.markDirty();
}

fn finishPaneDrag(state: *runtime.AppState, x: f32, y: f32) bool {
    const drag = pane_drag;
    pane_drag = .{};
    _ = sdl.captureMouse(false);
    defer last_pane_drop_target = null;
    if (!drag.active) return true;
    const target = paneDragTargetAt(drag.pane_id, x, y, drag.split_placement) orelse last_pane_drop_target orelse return true;
    if (drag.split_placement) {
        _ = state.moveCurrentProjectWorkspacePaneToPlacement(drag.pane_id, target.pane_id, target.axis, target.new_after);
    } else if (state.swapCurrentProjectWorkspacePanes(drag.pane_id, target.pane_id)) {
        _ = state.focusCurrentProjectWorkspacePane(target.pane_id);
        state.markDirty();
    }
    return true;
}

fn cancelPaneDrag() void {
    pane_drag = .{};
    last_pane_drop_target = null;
    _ = sdl.captureMouse(false);
}

fn renderPlacementPreview(state: *runtime.AppState, rect: palette.Rect) void {
    const accent = theme.current_colors.accent;
    queueRounded(state, rect, paletteColor(theme.withAlpha(accent, 54)), theme.scaledUi(6.0));
    queueBorder(state, rect, paletteColor(theme.withAlpha(accent, 210)), theme.scaledUi(6.0), theme.scaledUi(2.0));
}

fn threadDropTargetForPane(pane_id: runtime.WorkspacePaneId, rect: palette.Rect, x: f32, y: f32) ThreadDropTarget {
    const left_d = @max(x - rect.x, 0.0);
    const right_d = @max(rect.x + rect.w - x, 0.0);
    const top_d = @max(y - rect.y, 0.0);
    const bottom_d = @max(rect.y + rect.h - y, 0.0);
    const min_x = @min(left_d, right_d);
    const min_y = @min(top_d, bottom_d);
    if (min_x <= min_y) {
        const after = right_d < left_d;
        const w = @max(rect.w * 0.5, theme.scaledUi(80.0));
        const preview = if (after)
            palette.Rect{ .x = rect.x + rect.w - w, .y = rect.y, .w = w, .h = rect.h }
        else
            palette.Rect{ .x = rect.x, .y = rect.y, .w = w, .h = rect.h };
        return .{ .pane_id = pane_id, .axis = .vertical, .new_after = after, .preview = preview };
    }
    const after = bottom_d < top_d;
    const h = @max(rect.h * 0.5, theme.scaledUi(80.0));
    const preview = if (after)
        palette.Rect{ .x = rect.x, .y = rect.y + rect.h - h, .w = rect.w, .h = h }
    else
        palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = h };
    return .{ .pane_id = pane_id, .axis = .horizontal, .new_after = after, .preview = preview };
}

fn scrollingLayoutActive(state: *const runtime.AppState, layout: *const runtime.WorkspaceLayout) bool {
    return scrollingLayoutEnabled(
        layout.effectiveScrollMode(state.app_config.workspace_scroll_mode),
        layout.effectiveScrollThreshold(state.app_config.workspace_scroll_threshold),
        layout.visiblePaneCount(),
        layout.maximized_pane_id != null,
    );
}

fn scrollingLayoutEnabled(mode: app_config.WorkspaceScrollMode, threshold: u8, visible_pane_count: usize, maximized: bool) bool {
    if (maximized or visible_pane_count == 0) return false;
    return switch (mode) {
        .automatic => visible_pane_count >= @as(usize, threshold),
        .always => true,
        .disabled => false,
    };
}

// Configurable-axis workspace strip with focus-aware reveal and clipping.
fn renderScrollingStrip(
    state: *runtime.AppState,
    layout: *runtime.WorkspaceLayout,
    workspace: palette.Rect,
    target_workspace_width: f32,
) void {
    const direction = state.app_config.workspace_scroll_direction;
    const vertical = direction == .vertical;
    if (layout.scroll_axis_vertical != vertical) {
        layout.scroll_axis_vertical = vertical;
        layout.scroll_revealed_pane_id = null;
        layout.scroll_animation_last_ms = 0;
        layout.scroll_snap_deadline_ms = 0;
    }

    const gap = theme.scaledUi(state.app_config.workspace_pane_gap);
    var group_ids: [MAX_WORKSPACE_PANE_RECTS]runtime.WorkspacePaneId = undefined;
    var representative_pane_ids: [MAX_WORKSPACE_PANE_RECTS]runtime.WorkspacePaneId = undefined;
    const pane_count = collectScrollingGroups(layout, &group_ids, &representative_pane_ids);
    const viewport = scrollingViewportRect(workspace, gap, pane_count, state.app_config.workspace_panes_per_view);
    const target_viewport_width = scrollingViewportExtent(target_workspace_width, gap, pane_count, state.app_config.workspace_panes_per_view);
    const viewport_has_margins = scrollingViewportUsesMargins(pane_count, state.app_config.workspace_panes_per_view);
    const viewport_extent = if (vertical) viewport.h else viewport.w;
    const default_extent = responsiveScrollingPaneExtent(
        viewport_extent,
        gap,
        state.app_config.workspace_panes_per_view,
        layout.scroll_pane_extent_override,
        layout.scroll_pane_extent_ratio_override,
        theme.uiScaleFactor(),
    );
    var extents: [MAX_WORKSPACE_PANE_RECTS]f32 = undefined;
    resolveScrollingGroupExtents(
        layout,
        group_ids[0..pane_count],
        representative_pane_ids[0..pane_count],
        default_extent,
        viewport_extent,
        gap,
        theme.uiScaleFactor(),
        extents[0..pane_count],
    );
    const target_viewport_extent = if (vertical) viewport.h else target_viewport_width;
    const target_default_extent = responsiveScrollingPaneExtent(
        target_viewport_extent,
        gap,
        state.app_config.workspace_panes_per_view,
        layout.scroll_pane_extent_override,
        layout.scroll_pane_extent_ratio_override,
        theme.uiScaleFactor(),
    );
    var target_extents: [MAX_WORKSPACE_PANE_RECTS]f32 = undefined;
    resolveScrollingGroupExtents(
        layout,
        group_ids[0..pane_count],
        representative_pane_ids[0..pane_count],
        target_default_extent,
        target_viewport_extent,
        gap,
        theme.uiScaleFactor(),
        target_extents[0..pane_count],
    );
    const max_offset = scrollingStripMaxOffset(viewport_extent, extents[0..pane_count], gap);
    const offset: *f32 = if (vertical) &layout.scroll_offset_y else &layout.scroll_offset_x;
    const target: *f32 = if (vertical) &layout.scroll_target_y else &layout.scroll_target_x;
    clampScrollingOffsets(offset, target, max_offset);

    // A live edge drag owns scroll; don't let focus-reveal fight the pointer.
    if (resize_drag != null) {
        layout.scroll_snap_deadline_ms = 0;
    } else {
        if (layout.focused_pane_id) |focused_id| {
            if (layout.rootContainsPane(focused_id) and layout.scroll_revealed_pane_id != focused_id) {
                layout.scroll_snap_deadline_ms = 0;
                if (scrollGroupIndexForPane(layout, focused_id)) |focused_index| {
                    const revealed_target = revealedScrollTargetForPane(
                        target.*,
                        viewport_extent,
                        extents[0..pane_count],
                        gap,
                        focused_index,
                        max_offset,
                    );
                    const actually_offscreen = @abs(revealed_target - target.*) > 0.001;
                    const next_target = if (layout.scroll_leading_pane_id == focused_id and actually_offscreen)
                        leadingScrollTargetForPane(extents[0..pane_count], gap, focused_index, max_offset)
                    else
                        revealed_target;
                    setScrollingTarget(state, target, &layout.scroll_animation_last_ms, next_target);
                }
                layout.scroll_leading_pane_id = null;
                layout.scroll_revealed_pane_id = focused_id;
            }
        }
        if (scrollSnapTargetAfterIdle(
            layout.scroll_snap_deadline_ms,
            nowMs(),
            target.*,
            extents[0..pane_count],
            gap,
            max_offset,
        )) |snap_target| {
            layout.scroll_snap_deadline_ms = 0;
            setScrollingTarget(state, target, &layout.scroll_animation_last_ms, snap_target);
        }
    }

    tickScrollingAnimation(offset, target.*, &layout.scroll_animation_last_ms);
    // Keep frame pacing active until the idle deadline can settle even a
    // sub-pixel wheel gesture that finished easing early.
    if (layout.scroll_snap_deadline_ms != 0) scrolling_animating = true;
    // The strip owns pane-region motion until it reaches its target. A chat
    // pane rendered below consumes this flag by presenting resident transcript
    // content directly, avoiding a compounded slide-plus-fade.
    state.transcript_controller.motion_suppressed = scrolling_animating;
    scrolling_layout_rendered = true;
    scrolling_max_offset = max_offset;

    const command_start = state.palette_overlay_batch.commands.items.len;
    const text_run_start = state.palette_overlay_batch.text_runs.items.len;
    var origin: f32 = 0.0;
    const root = layout.root orelse return;
    for (group_ids[0..pane_count], 0..) |group_id, pane_index| {
        const pane_extent = extents[pane_index];
        const target_pane_width = if (vertical)
            target_viewport_width
        else
            target_extents[pane_index];
        renderScrollingGroup(
            state,
            layout,
            root,
            group_id,
            representative_pane_ids[pane_index],
            viewport,
            direction,
            origin,
            pane_extent,
            target_pane_width,
            gap,
            offset.*,
            pane_index,
            viewport_has_margins,
        );
        origin += pane_extent + gap;
    }
    clipWorkspaceBatch(state, command_start, text_run_start, viewport);
    clipWorkspaceHitCaches(viewport);
    renderScrollingEdgeNavigation(state, layout, viewport, direction, pane_count);
}

const ScrollingEdgeAvailability = struct {
    previous: bool,
    next: bool,
};

const ScrollingEdgeRects = struct {
    button: palette.Rect,
    proximity: palette.Rect,
};

fn scrollingEdgeAvailability(focused_index: ?usize, pane_count: usize) ScrollingEdgeAvailability {
    const index = focused_index orelse return .{ .previous = false, .next = false };
    if (index >= pane_count) return .{ .previous = false, .next = false };
    return .{
        .previous = index > 0,
        .next = index + 1 < pane_count,
    };
}

fn scrollingEdgeRects(
    workspace: palette.Rect,
    direction: app_config.WorkspaceScrollDirection,
    edge: ScrollingEdgeDirection,
    thickness: f32,
    length: f32,
    inset: f32,
    hover_pad: f32,
) ScrollingEdgeRects {
    const previous = edge == .previous;
    const axis_extent = if (direction == .horizontal) workspace.w else workspace.h;
    const safe_inset = @min(inset, @max((axis_extent - thickness) * 0.5, 0.0));
    const button: palette.Rect = switch (direction) {
        .horizontal => .{
            .x = if (previous) workspace.x + safe_inset else workspace.x + workspace.w - thickness - safe_inset,
            .y = workspace.y + (workspace.h - length) * 0.5,
            .w = thickness,
            .h = length,
        },
        .vertical => .{
            .x = workspace.x + (workspace.w - length) * 0.5,
            .y = if (previous) workspace.y + safe_inset else workspace.y + workspace.h - thickness - safe_inset,
            .w = length,
            .h = thickness,
        },
    };
    const expanded: palette.Rect = .{
        .x = button.x - hover_pad,
        .y = button.y - hover_pad,
        .w = button.w + hover_pad * 2.0,
        .h = button.h + hover_pad * 2.0,
    };
    return .{
        .button = button,
        .proximity = intersectRects(expanded, workspace) orelse button,
    };
}

// Hover-only previous/next controls along the scrolling workspace edge.
fn renderScrollingEdgeNavigation(
    state: *runtime.AppState,
    layout: *const runtime.WorkspaceLayout,
    workspace: palette.Rect,
    direction: app_config.WorkspaceScrollDirection,
    pane_count: usize,
) void {
    if (pane_drag.pending or pane_drag.active or resize_drag != null or quick_pane_drag != null or split_menu_open_for != null) return;
    if (state.currentProjectQuickPane()) |quick| if (quick.visible) return;

    const focused_index = if (layout.focused_pane_id) |pane_id| scrollGroupIndexForPane(layout, pane_id) else null;
    const available = scrollingEdgeAvailability(focused_index, pane_count);
    if (!available.previous and !available.next) return;

    const thickness = @min(theme.scaledUi(SCROLLING_EDGE_BUTTON_THICKNESS_CSS), if (direction == .horizontal) workspace.w else workspace.h);
    const length = @min(theme.scaledUi(SCROLLING_EDGE_BUTTON_LENGTH_CSS), if (direction == .horizontal) workspace.h else workspace.w);
    const inset = theme.scaledUi(SCROLLING_EDGE_BUTTON_INSET_CSS);
    const hover_pad = theme.scaledUi(SCROLLING_EDGE_HOVER_PAD_CSS);
    if (available.previous) renderScrollingEdgeControl(state, workspace, direction, .previous, thickness, length, inset, hover_pad);
    if (available.next) renderScrollingEdgeControl(state, workspace, direction, .next, thickness, length, inset, hover_pad);
}

// One previous/next chevron inside the hovered workspace edge.
fn renderScrollingEdgeControl(
    state: *runtime.AppState,
    workspace: palette.Rect,
    direction: app_config.WorkspaceScrollDirection,
    edge: ScrollingEdgeDirection,
    thickness: f32,
    length: f32,
    inset: f32,
    hover_pad: f32,
) void {
    const rects = scrollingEdgeRects(workspace, direction, edge, thickness, length, inset, hover_pad);
    switch (edge) {
        .previous => scrolling_previous_proximity = rects.proximity,
        .next => scrolling_next_proximity = rects.proximity,
    }
    if (!state.transcript_controller.palette_mouse_in_workspace or
        !rectContains(rects.proximity, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) return;

    const previous_z = state.palette_overlay_batch.setZIndex(SCROLLING_EDGE_CONTROL_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);
    queueRounded(state, rects.button, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 232)), theme.scaledUi(9.0));
    queueBorder(state, rects.button, paletteColor(theme.withAlpha(theme.accent(), 190)), theme.scaledUi(9.0), theme.scaledUi(1.5));

    const icon_size = theme.scaledUi(18.0);
    const icon_rect: palette.Rect = .{
        .x = rects.button.x + (rects.button.w - icon_size) * 0.5,
        .y = rects.button.y + (rects.button.h - icon_size) * 0.5,
        .w = icon_size,
        .h = icon_size,
    };
    const glyph = switch (direction) {
        .horizontal => if (edge == .previous) NF_COD_CHEVRON_LEFT else NF_COD_CHEVRON_RIGHT,
        .vertical => if (edge == .previous) NF_COD_CHEVRON_UP else NF_COD_CHEVRON_DOWN,
    };
    queueIcon(state, icon_rect, glyph, paletteColor(theme.COLOR_WHITE), icon_size, workspace);
    appendHit(.{
        .action = if (edge == .previous) .scrolling_previous else .scrolling_next,
        .rect = rects.button,
    });
}

fn scrollingEdgeProximityContains(x: f32, y: f32) bool {
    if (scrolling_previous_proximity) |rect| if (rectContains(rect, x, y)) return true;
    if (scrolling_next_proximity) |rect| if (rectContains(rect, x, y)) return true;
    return false;
}

fn focusScrollingEdgePane(state: *runtime.AppState, edge: ScrollingEdgeDirection) void {
    if (state.project_controller.projects.items.len == 0) return;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    const focused_pane_id = layout.focused_pane_id orelse return;
    const direction: runtime.WorkspacePaneDirection = switch (state.app_config.workspace_scroll_direction) {
        .horizontal => if (edge == .previous) .left else .right,
        .vertical => if (edge == .previous) .up else .down,
    };
    const target = layout.adjacentScrollGroupPaneId(focused_pane_id, direction) orelse return;
    _ = focusPaneNavigationTarget(state, target, false);
}

// One scrolling workspace item, including any nested tiled panes.
fn renderScrollingGroup(
    state: *runtime.AppState,
    layout: *const runtime.WorkspaceLayout,
    root: *const runtime.WorkspaceNode,
    group_id: runtime.WorkspacePaneId,
    representative_pane_id: runtime.WorkspacePaneId,
    workspace: palette.Rect,
    direction: app_config.WorkspaceScrollDirection,
    origin: f32,
    pane_extent: f32,
    target_pane_width: f32,
    gap: f32,
    offset: f32,
    pane_index: usize,
    viewport_has_margins: bool,
) void {
    const screen_origin = origin - offset;
    const rect: palette.Rect = switch (direction) {
        .horizontal => .{ .x = workspace.x + screen_origin, .y = workspace.y, .w = pane_extent, .h = workspace.h },
        .vertical => .{ .x = workspace.x, .y = workspace.y + screen_origin, .w = workspace.w, .h = pane_extent },
    };
    if (intersectRects(rect, workspace) == null) return;
    const pane_count = layout.scrollGroupPaneCount(group_id);
    const content_pane_count = if (viewport_has_margins) @as(usize, 1) else pane_count;
    renderScrollGroupNode(
        state,
        layout,
        root,
        group_id,
        tiledContentRect(rect, gap, content_pane_count),
        tiledContentExtent(target_pane_width, gap, content_pane_count),
    );
    const gutter: palette.Rect = switch (direction) {
        .horizontal => .{ .x = rect.x + rect.w, .y = workspace.y, .w = gap, .h = workspace.h },
        .vertical => .{ .x = workspace.x, .y = rect.y + rect.h, .w = workspace.w, .h = gap },
    };
    if (intersectRects(gutter, workspace) != null) queueRect(state, gutter, paletteColor(theme.background()));
    if (pane_count > 1) return;
    const grip_extent = theme.scaledUi(10.0);
    const axis: runtime.WorkspaceSplitAxis = if (direction == .horizontal) .vertical else .horizontal;
    // Leading grip stays inside this pane so it resizes the pane the pointer
    // is on, not the neighbor that owns the shared gutter.
    const leading_grip: palette.Rect = switch (direction) {
        .horizontal => .{ .x = rect.x, .y = workspace.y, .w = grip_extent, .h = workspace.h },
        .vertical => .{ .x = workspace.x, .y = rect.y, .w = workspace.w, .h = grip_extent },
    };
    const trailing_grip: palette.Rect = switch (direction) {
        .horizontal => .{ .x = rect.x + rect.w - grip_extent * 0.5, .y = workspace.y, .w = grip_extent, .h = workspace.h },
        .vertical => .{ .x = workspace.x, .y = rect.y + rect.h - grip_extent * 0.5, .w = workspace.w, .h = grip_extent },
    };
    appendScrollingResizeHit(representative_pane_id, axis, leading_grip, workspace, pane_index, offset, origin, pane_extent, true);
    appendScrollingResizeHit(representative_pane_id, axis, trailing_grip, workspace, pane_index, offset, origin, pane_extent, false);
}

fn nodeContainsScrollGroup(
    layout: *const runtime.WorkspaceLayout,
    node: *const runtime.WorkspaceNode,
    group_id: runtime.WorkspacePaneId,
) bool {
    return switch (node.*) {
        .leaf => |pane_id| layout.scrollGroupIdForPane(pane_id) == group_id,
        .split => |split| nodeContainsScrollGroup(layout, split.first, group_id) or
            nodeContainsScrollGroup(layout, split.second, group_id),
    };
}

// Nested tiled region inside one scrolling workspace item.
fn renderScrollGroupNode(
    state: *runtime.AppState,
    layout: *const runtime.WorkspaceLayout,
    node: *const runtime.WorkspaceNode,
    group_id: runtime.WorkspacePaneId,
    rect: palette.Rect,
    target_width: f32,
) void {
    switch (node.*) {
        .leaf => |pane_id| {
            if (layout.scrollGroupIdForPane(pane_id) == group_id) {
                renderLeafWithTranscriptLayoutWidth(state, pane_id, rect, target_width);
            }
        },
        .split => |split| {
            const first_visible = nodeContainsScrollGroup(layout, split.first, group_id);
            const second_visible = nodeContainsScrollGroup(layout, split.second, group_id);
            if (!first_visible and !second_visible) return;
            if (!second_visible) return renderScrollGroupNode(state, layout, split.first, group_id, rect, target_width);
            if (!first_visible) return renderScrollGroupNode(state, layout, split.second, group_id, rect, target_width);
            renderScrollGroupSplit(state, layout, split, group_id, rect, target_width);
        },
    }
}

// Split geometry within one scrolling tile group.
fn renderScrollGroupSplit(
    state: *runtime.AppState,
    layout: *const runtime.WorkspaceLayout,
    split: anytype,
    group_id: runtime.WorkspacePaneId,
    rect: palette.Rect,
    target_width: f32,
) void {
    const gap = theme.scaledUi(state.app_config.workspace_pane_gap);
    if (split.axis == .vertical) {
        const widths = verticalSplitWidths(rect.w, split.ratio, gap);
        const target_widths = verticalSplitWidths(target_width, split.ratio, gap);
        const first_rect: palette.Rect = .{ .x = rect.x, .y = rect.y, .w = widths.first, .h = rect.h };
        const gutter_rect: palette.Rect = .{ .x = rect.x + widths.first, .y = rect.y, .w = gap, .h = rect.h };
        const second_rect: palette.Rect = .{ .x = gutter_rect.x + gap, .y = rect.y, .w = widths.second, .h = rect.h };
        renderScrollGroupNode(state, layout, split.first, group_id, first_rect, target_widths.first);
        renderScrollGroupGutter(state, layout, split.first, split.second, group_id, .vertical, gutter_rect, rect);
        renderScrollGroupNode(state, layout, split.second, group_id, second_rect, target_widths.second);
        return;
    }

    const first_h = @max(theme.scaledUi(160.0), rect.h * split.ratio - gap * 0.5);
    const second_h = @max(theme.scaledUi(120.0), rect.h - first_h - gap);
    const clamped_first_h = @max(theme.scaledUi(120.0), rect.h - second_h - gap);
    const first_rect: palette.Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = clamped_first_h };
    const gutter_rect: palette.Rect = .{ .x = rect.x, .y = rect.y + clamped_first_h, .w = rect.w, .h = gap };
    const second_rect: palette.Rect = .{ .x = rect.x, .y = gutter_rect.y + gap, .w = rect.w, .h = @max(rect.h - clamped_first_h - gap, theme.scaledUi(120.0)) };
    renderScrollGroupNode(state, layout, split.first, group_id, first_rect, target_width);
    renderScrollGroupGutter(state, layout, split.first, split.second, group_id, .horizontal, gutter_rect, rect);
    renderScrollGroupNode(state, layout, split.second, group_id, second_rect, target_width);
}

fn firstPaneIdInScrollGroup(
    layout: *const runtime.WorkspaceLayout,
    node: *const runtime.WorkspaceNode,
    group_id: runtime.WorkspacePaneId,
) ?runtime.WorkspacePaneId {
    return switch (node.*) {
        .leaf => |pane_id| if (layout.scrollGroupIdForPane(pane_id) == group_id) pane_id else null,
        .split => |split| firstPaneIdInScrollGroup(layout, split.first, group_id) orelse
            firstPaneIdInScrollGroup(layout, split.second, group_id),
    };
}

// Resize gutter between two branches of a scrolling tile group.
fn renderScrollGroupGutter(
    state: *runtime.AppState,
    layout: *const runtime.WorkspaceLayout,
    first: *const runtime.WorkspaceNode,
    second: *const runtime.WorkspaceNode,
    group_id: runtime.WorkspacePaneId,
    axis: runtime.WorkspaceSplitAxis,
    rect: palette.Rect,
    split_rect: palette.Rect,
) void {
    queueRect(state, rect, paletteColor(theme.background()));
    const hit_rect: palette.Rect = if (axis == .vertical)
        .{ .x = rect.x - theme.scaledUi(4.0), .y = rect.y, .w = rect.w + theme.scaledUi(8.0), .h = rect.h }
    else
        .{ .x = rect.x, .y = rect.y - theme.scaledUi(4.0), .w = rect.w, .h = rect.h + theme.scaledUi(8.0) };
    appendHit(.{
        .pane_id = firstPaneIdInScrollGroup(layout, first, group_id) orelse return,
        .sibling_pane_id = firstPaneIdInScrollGroup(layout, second, group_id) orelse return,
        .action = .resize_split,
        .axis = axis,
        .rect = hit_rect,
        .split_rect = split_rect,
    });
}

fn appendScrollingResizeHit(
    pane_id: runtime.WorkspacePaneId,
    axis: runtime.WorkspaceSplitAxis,
    grip: palette.Rect,
    workspace: palette.Rect,
    pane_index: usize,
    offset: f32,
    origin: f32,
    pane_extent: f32,
    leading_edge: bool,
) void {
    if (intersectRects(grip, workspace) == null) return;
    appendHit(.{
        .pane_id = pane_id,
        .action = .resize_scrolling_column,
        .axis = axis,
        .rect = grip,
        .split_rect = workspace,
        .pane_index = pane_index,
        .scroll_offset = offset,
        .drag_origin = origin,
        .drag_extent = pane_extent,
        .leading_edge = leading_edge,
    });
}

fn scrollGroupIndexForPane(layout: *const runtime.WorkspaceLayout, pane_id: runtime.WorkspacePaneId) ?usize {
    const wanted_group = layout.scrollGroupIdForPane(pane_id) orelse return null;
    var group_index: usize = 0;
    for (layout.panes.items, 0..) |pane, pane_index| {
        if (!layout.rootContainsPane(pane.id)) continue;
        const group_id = layout.scrollGroupIdForPane(pane.id) orelse continue;
        var seen = false;
        for (layout.panes.items[0..pane_index]) |earlier| {
            if (!layout.rootContainsPane(earlier.id)) continue;
            if (layout.scrollGroupIdForPane(earlier.id) == group_id) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (group_id == wanted_group) return group_index;
        group_index += 1;
    }
    return null;
}

fn scrollingPaneExtent(viewport_extent: f32, gap: f32, panes_per_view: u8) f32 {
    const count: f32 = @floatFromInt(@max(panes_per_view, 1));
    return @max((viewport_extent - gap * (count - 1.0)) / count, 1.0);
}

fn scrollingViewportUsesMargins(group_count: usize, panes_per_view: u8) bool {
    return group_count > 1 and panes_per_view > 1;
}

fn scrollingViewportExtent(extent: f32, gap: f32, group_count: usize, panes_per_view: u8) f32 {
    if (!scrollingViewportUsesMargins(group_count, panes_per_view)) return extent;
    return tiledContentExtent(extent, gap, 2);
}

fn scrollingViewportRect(rect: palette.Rect, gap: f32, group_count: usize, panes_per_view: u8) palette.Rect {
    if (!scrollingViewportUsesMargins(group_count, panes_per_view)) return rect;
    return tiledContentRect(rect, gap, 2);
}

fn responsiveScrollingPaneExtent(
    viewport_extent: f32,
    gap: f32,
    panes_per_view: u8,
    override_css: ?f32,
    override_ratio: ?f32,
    ui_scale: f32,
) f32 {
    const default_extent = scrollingPaneExtent(viewport_extent, gap, panes_per_view);
    const custom_css = override_css orelse return default_extent;
    const scale = @max(ui_scale, 0.001);
    const minimum = workspace_layout.MIN_SCROLL_PANE_EXTENT_CSS * scale;
    const maximum = workspace_layout.MAX_SCROLL_PANE_EXTENT_CSS * scale;
    if (override_ratio) |ratio| {
        return theme.clampf((viewport_extent + gap) * ratio - gap, minimum, maximum);
    }

    // Widths saved before viewport-relative persistence must not strand a
    // laptop at a lower density than its configured panes-per-view value.
    const legacy_extent = theme.clampf(custom_css * scale, minimum, maximum);
    return @min(legacy_extent, default_extent);
}

fn scrollingMaxOffset(viewport_extent: f32, pane_extent: f32, gap: f32, pane_count: usize) f32 {
    if (pane_count == 0) return 0.0;
    const count: f32 = @floatFromInt(pane_count);
    const total_extent = pane_extent * count + gap * (count - 1.0);
    const ordinary_max = @max(0.0, total_extent - viewport_extent);
    const final_pane_origin = (count - 1.0) * (pane_extent + gap);
    return @max(ordinary_max, final_pane_origin);
}

fn collectScrollingGroups(
    layout: *const runtime.WorkspaceLayout,
    group_ids: *[MAX_WORKSPACE_PANE_RECTS]runtime.WorkspacePaneId,
    representative_pane_ids: *[MAX_WORKSPACE_PANE_RECTS]runtime.WorkspacePaneId,
) usize {
    var count: usize = 0;
    for (layout.panes.items, 0..) |pane, pane_index| {
        if (!layout.rootContainsPane(pane.id)) continue;
        const group_id = layout.scrollGroupIdForPane(pane.id) orelse continue;
        var seen = false;
        for (layout.panes.items[0..pane_index]) |earlier| {
            if (!layout.rootContainsPane(earlier.id)) continue;
            if (layout.scrollGroupIdForPane(earlier.id) == group_id) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (count >= group_ids.len) break;
        group_ids[count] = group_id;
        representative_pane_ids[count] = pane.id;
        count += 1;
    }
    return count;
}

fn resolveScrollingGroupExtents(
    layout: *const runtime.WorkspaceLayout,
    group_ids: []const runtime.WorkspacePaneId,
    representative_pane_ids: []const runtime.WorkspacePaneId,
    default_extent: f32,
    viewport_extent: f32,
    gap: f32,
    ui_scale: f32,
    extents: []f32,
) void {
    for (group_ids, representative_pane_ids, extents) |group_id, representative_pane_id, *extent| {
        var resolved_pane = layout.paneById(representative_pane_id) orelse continue;
        for (layout.panes.items) |*pane| {
            if (layout.scrollGroupIdForPane(pane.id) != group_id) continue;
            if (pane.scroll_extent_css != null or pane.scroll_extent_ratio != null) {
                resolved_pane = pane;
                break;
            }
        }
        extent.* = scrollingGroupResolvedExtent(
            layout,
            group_id,
            resolved_pane,
            default_extent,
            viewport_extent,
            gap,
            ui_scale,
        );
    }
}

fn scrollingGroupResolvedExtent(
    layout: *const runtime.WorkspaceLayout,
    group_id: runtime.WorkspacePaneId,
    pane: *const workspace_layout.WorkspacePane,
    default_extent: f32,
    viewport_extent: f32,
    gap: f32,
    ui_scale: f32,
) f32 {
    // A live tile group owns the full scrolling viewport so its internal split
    // tree has the same usable area as an ordinary tiled workspace. As soon as
    // only one leaf remains, its normal scrolling extent applies again.
    if (layout.scrollGroupPaneCount(group_id) > 1) return @max(viewport_extent, 1.0);
    return scrollingPaneResolvedExtent(pane, default_extent, viewport_extent, gap, ui_scale);
}

fn scrollingPaneResolvedExtent(
    pane: *const workspace_layout.WorkspacePane,
    default_extent: f32,
    viewport_extent: f32,
    gap: f32,
    ui_scale: f32,
) f32 {
    const scale = @max(ui_scale, 0.001);
    const minimum = workspace_layout.MIN_SCROLL_PANE_EXTENT_CSS * scale;
    const maximum = workspace_layout.MAX_SCROLL_PANE_EXTENT_CSS * scale;
    if (pane.scroll_extent_ratio) |ratio| {
        return theme.clampf((viewport_extent + gap) * ratio - gap, minimum, maximum);
    }
    if (pane.scroll_extent_css) |css| {
        return theme.clampf(css * scale, minimum, maximum);
    }
    return default_extent;
}

fn scrollingStripMaxOffset(viewport_extent: f32, extents: []const f32, gap: f32) f32 {
    if (extents.len == 0) return 0.0;
    var total_extent: f32 = 0.0;
    for (extents, 0..) |pane_extent, index| {
        if (index > 0) total_extent += gap;
        total_extent += pane_extent;
    }
    const ordinary_max = @max(0.0, total_extent - viewport_extent);
    var final_pane_origin: f32 = 0.0;
    var index: usize = 0;
    while (index + 1 < extents.len) : (index += 1) {
        final_pane_origin += extents[index] + gap;
    }
    return @max(ordinary_max, final_pane_origin);
}

fn scrollingPaneOrigin(extents: []const f32, gap: f32, pane_index: usize) f32 {
    var origin: f32 = 0.0;
    var index: usize = 0;
    while (index < pane_index and index < extents.len) : (index += 1) {
        origin += extents[index] + gap;
    }
    return origin;
}

fn revealedScrollTargetForPane(
    current: f32,
    viewport_extent: f32,
    extents: []const f32,
    gap: f32,
    pane_index: usize,
    max_offset: f32,
) f32 {
    if (pane_index >= extents.len) return std.math.clamp(current, 0.0, max_offset);
    return revealedColumnScrollTarget(
        current,
        viewport_extent,
        scrollingPaneOrigin(extents, gap, pane_index),
        extents[pane_index],
        max_offset,
    );
}

fn revealedColumnScrollTarget(current: f32, viewport_extent: f32, column_left: f32, column_extent: f32, max_offset: f32) f32 {
    const column_right = column_left + column_extent;
    var target = current;
    if (column_left < current) {
        target = column_left;
    } else if (column_right > current + viewport_extent) {
        target = column_right - viewport_extent;
    }
    return std.math.clamp(target, 0.0, max_offset);
}

fn leadingScrollTargetForPane(extents: []const f32, gap: f32, pane_index: usize, max_offset: f32) f32 {
    return std.math.clamp(scrollingPaneOrigin(extents, gap, pane_index), 0.0, max_offset);
}

fn scrollSnapTargetAfterIdle(
    deadline_ms: i64,
    timestamp_ms: i64,
    current_target: f32,
    extents: []const f32,
    gap: f32,
    max_offset: f32,
) ?f32 {
    if (deadline_ms == 0 or timestamp_ms < deadline_ms) return null;
    return nearestPaneScrollTarget(current_target, extents, gap, max_offset);
}

fn nearestPaneScrollTarget(current_target: f32, extents: []const f32, gap: f32, max_offset: f32) f32 {
    if (extents.len == 0) return std.math.clamp(current_target, 0.0, max_offset);

    var origin: f32 = 0.0;
    var closest = std.math.clamp(origin, 0.0, max_offset);
    var closest_distance = @abs(current_target - closest);
    for (extents, 0..) |_, index| {
        if (index > 0) origin += extents[index - 1] + gap;
        const candidate = std.math.clamp(origin, 0.0, max_offset);
        const distance = @abs(current_target - candidate);
        if (distance < closest_distance) {
            closest = candidate;
            closest_distance = distance;
        }
    }
    return closest;
}

fn scrollingPaneExtentFromTrailingDrag(position: f32, scroll_offset: f32, origin: f32, ui_scale: f32) f32 {
    return (position + scroll_offset - origin) / @max(ui_scale, 0.001);
}

fn scrollingPaneExtentFromLeadingDrag(position: f32, scroll_offset: f32, origin: f32, start_extent: f32, ui_scale: f32) f32 {
    return (origin + start_extent - position - scroll_offset) / @max(ui_scale, 0.001);
}

fn scrollingScrollAfterLeadingResize(start_scroll: f32, start_extent: f32, new_extent: f32) f32 {
    return start_scroll + (new_extent - start_extent);
}

fn scrollingPaneExtentRatio(pane_extent: f32, viewport_extent: f32, gap: f32) f32 {
    return (pane_extent + gap) / @max(viewport_extent + gap, 1.0);
}

fn revealedScrollTarget(current: f32, viewport_w: f32, column_w: f32, gap: f32, pane_index: usize, max_offset: f32) f32 {
    const column_left = @as(f32, @floatFromInt(pane_index)) * (column_w + gap);
    return revealedColumnScrollTarget(current, viewport_w, column_left, column_w, max_offset);
}

fn leadingScrollTarget(column_w: f32, gap: f32, pane_index: usize, max_offset: f32) f32 {
    const column_left = @as(f32, @floatFromInt(pane_index)) * (column_w + gap);
    return std.math.clamp(column_left, 0.0, max_offset);
}

fn setScrollingTarget(state: *runtime.AppState, current_target: *f32, animation_last_ms: *i64, target: f32) void {
    if (@abs(target - current_target.*) <= 0.001) return;
    current_target.* = target;
    animation_last_ms.* = nowMs();
    state.markDirty();
}

fn clampScrollingOffsets(offset: *f32, target: *f32, max_offset: f32) void {
    target.* = std.math.clamp(target.*, 0.0, max_offset);
    offset.* = std.math.clamp(offset.*, 0.0, max_offset);
}

fn tickScrollingAnimation(offset: *f32, target: f32, animation_last_ms: *i64) void {
    const timestamp = nowMs();
    if (animation_last_ms.* == 0) animation_last_ms.* = timestamp;
    const elapsed_ms = std.math.clamp(timestamp - animation_last_ms.*, 0, SCROLLING_ANIMATION_MAX_STEP_MS);
    animation_last_ms.* = timestamp;
    offset.* = advanceScrollOffset(offset.*, target, elapsed_ms);
    if (@abs(target - offset.*) <= SCROLLING_ANIMATION_EPSILON) {
        offset.* = target;
    } else {
        scrolling_animating = true;
    }
}

fn advanceScrollOffset(current: f32, target: f32, elapsed_ms: i64) f32 {
    if (elapsed_ms <= 0 or @abs(target - current) <= SCROLLING_ANIMATION_EPSILON) return current;
    const progress = @min(1.0, @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(SCROLLING_ANIMATION_DURATION_MS)));
    return current + (target - current) * theme.easeOutCubic(progress);
}

fn clipWorkspaceBatch(state: *runtime.AppState, command_start: usize, text_run_start: usize, workspace: palette.Rect) void {
    for (state.palette_overlay_batch.commands.items[command_start..]) |*command| {
        command.clip = intersectOptionalClip(command.clip, workspace);
    }
    for (state.palette_overlay_batch.text_runs.items[text_run_start..]) |*run| {
        run.clip = intersectOptionalClip(run.clip, workspace);
    }
}

fn clipWorkspaceHitCaches(workspace: palette.Rect) void {
    chat_panel.clipTranscriptHitCache(workspace);

    var write_index: usize = 0;
    for (hit_cache.hits[0..hit_cache.count]) |hit| {
        var clipped = hit;
        clipped.rect = intersectRects(hit.rect, workspace) orelse continue;
        hit_cache.hits[write_index] = clipped;
        write_index += 1;
    }
    hit_cache.count = write_index;

    write_index = 0;
    for (pane_rects[0..pane_rect_count]) |entry| {
        const clipped_rect = intersectRects(entry.rect, workspace) orelse continue;
        pane_rects[write_index] = .{ .pane_id = entry.pane_id, .rect = clipped_rect };
        write_index += 1;
    }
    pane_rect_count = write_index;
}

fn intersectOptionalClip(existing: ?palette.Rect, bounds: palette.Rect) palette.Rect {
    return intersectRects(existing orelse bounds, bounds) orelse .{ .x = bounds.x, .y = bounds.y, .w = 0.0, .h = 0.0 };
}

fn intersectRects(a: palette.Rect, b: palette.Rect) ?palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

const VerticalSplitWidths = struct {
    first: f32,
    second: f32,
};

fn verticalSplitWidths(total_width: f32, ratio: f32, gap: f32) VerticalSplitWidths {
    const first_width = @max(theme.scaledUi(180.0), total_width * ratio - gap * 0.5);
    const second_width = @max(theme.scaledUi(180.0), total_width - first_width - gap);
    const clamped_first_width = @max(theme.scaledUi(120.0), total_width - second_width - gap);
    return .{
        .first = clamped_first_width,
        .second = @max(total_width - clamped_first_width - gap, theme.scaledUi(120.0)),
    };
}

fn tiledContentExtent(extent: f32, gap: f32, pane_count: usize) f32 {
    if (pane_count <= 1) return extent;
    const inset = @min(gap, @max((extent - 1.0) * 0.5, 0.0));
    return @max(1.0, extent - inset * 2.0);
}

fn tiledContentRect(rect: palette.Rect, gap: f32, pane_count: usize) palette.Rect {
    if (pane_count <= 1) return rect;
    const horizontal_inset = @min(gap, @max((rect.w - 1.0) * 0.5, 0.0));
    const vertical_inset = @min(gap, @max((rect.h - 1.0) * 0.5, 0.0));
    return .{
        .x = rect.x + horizontal_inset,
        .y = rect.y + vertical_inset,
        .w = @max(1.0, rect.w - horizontal_inset * 2.0),
        .h = @max(1.0, rect.h - vertical_inset * 2.0),
    };
}

test "tiled content adds four-sided margins only for pane groups" {
    const rect: palette.Rect = .{ .x = 10.0, .y = 20.0, .w = 1000.0, .h = 700.0 };

    try std.testing.expectEqual(rect, tiledContentRect(rect, 12.0, 1));
    try std.testing.expectEqual(@as(f32, 1000.0), tiledContentExtent(rect.w, 12.0, 1));

    const tiled = tiledContentRect(rect, 12.0, 2);
    try std.testing.expectEqual(@as(f32, 22.0), tiled.x);
    try std.testing.expectEqual(@as(f32, 32.0), tiled.y);
    try std.testing.expectEqual(@as(f32, 976.0), tiled.w);
    try std.testing.expectEqual(@as(f32, 676.0), tiled.h);
    try std.testing.expectEqual(@as(f32, 976.0), tiledContentExtent(rect.w, 12.0, 2));
}

test "target split widths finish without a corrective transcript reflow" {
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);

    const widths = verticalSplitWidths(900.0, 0.42, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 900.0), widths.first + widths.second + 1.0, 0.001);
    const final_widths = verticalSplitWidths(720.0, 0.42, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 720.0), final_widths.first + final_widths.second + 1.0, 0.001);
}

// Tiled workspace region; pane shells animate while transcript widths stay final.
fn renderNode(state: *runtime.AppState, node: *const runtime.WorkspaceNode, rect: palette.Rect, target_width: f32) void {
    switch (node.*) {
        .leaf => |pane_id| renderLeafWithTranscriptLayoutWidth(state, pane_id, rect, target_width),
        .split => |split| {
            const gap = theme.scaledUi(state.app_config.workspace_pane_gap);
            if (split.axis == .vertical) {
                const widths = verticalSplitWidths(rect.w, split.ratio, gap);
                const target_widths = verticalSplitWidths(target_width, split.ratio, gap);
                const first_rect = palette.Rect{ .x = rect.x, .y = rect.y, .w = widths.first, .h = rect.h };
                const gutter_rect = palette.Rect{ .x = rect.x + widths.first, .y = rect.y, .w = gap, .h = rect.h };
                const second_rect = palette.Rect{ .x = rect.x + widths.first + gap, .y = rect.y, .w = widths.second, .h = rect.h };
                renderNode(state, split.first, first_rect, target_widths.first);
                renderSplitGutter(state, split.first, split.second, .vertical, gutter_rect, rect);
                renderNode(state, split.second, second_rect, target_widths.second);
            } else {
                const first_h = @max(theme.scaledUi(160.0), rect.h * split.ratio - gap * 0.5);
                const second_h = @max(theme.scaledUi(120.0), rect.h - first_h - gap);
                const clamped_first_h = @max(theme.scaledUi(120.0), rect.h - second_h - gap);
                const first_rect = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = clamped_first_h };
                const gutter_rect = palette.Rect{ .x = rect.x, .y = rect.y + clamped_first_h, .w = rect.w, .h = gap };
                const second_rect = palette.Rect{ .x = rect.x, .y = rect.y + clamped_first_h + gap, .w = rect.w, .h = @max(rect.h - clamped_first_h - gap, theme.scaledUi(120.0)) };
                renderNode(state, split.first, first_rect, target_width);
                renderSplitGutter(state, split.first, split.second, .horizontal, gutter_rect, rect);
                renderNode(state, split.second, second_rect, target_width);
            }
        },
    }
}

fn renderSplitGutter(state: *runtime.AppState, first: *const runtime.WorkspaceNode, second: *const runtime.WorkspaceNode, axis: runtime.WorkspaceSplitAxis, rect: palette.Rect, split_rect: palette.Rect) void {
    queueRect(state, rect, paletteColor(theme.background()));
    const hit_rect = if (axis == .vertical)
        palette.Rect{ .x = rect.x - theme.scaledUi(4.0), .y = rect.y, .w = rect.w + theme.scaledUi(8.0), .h = rect.h }
    else
        palette.Rect{ .x = rect.x, .y = rect.y - theme.scaledUi(4.0), .w = rect.w, .h = rect.h + theme.scaledUi(8.0) };
    appendHit(.{
        .pane_id = firstPaneId(first) orelse return,
        .sibling_pane_id = firstPaneId(second) orelse return,
        .action = .resize_split,
        .axis = axis,
        .rect = hit_rect,
        .split_rect = split_rect,
    });
}

fn firstPaneId(node: *const runtime.WorkspaceNode) ?runtime.WorkspacePaneId {
    return switch (node.*) {
        .leaf => |pane_id| pane_id,
        .split => |split| firstPaneId(split.first) orelse firstPaneId(split.second),
    };
}

fn updateResizeDrag(state: *runtime.AppState, hit: WorkspacePaneHit, x: f32, y: f32) void {
    if (hit.action == .resize_scrolling_column) {
        if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return;
        const position = if (hit.axis == .vertical) x - hit.split_rect.x else y - hit.split_rect.y;
        const ui_scale = theme.uiScaleFactor();
        const pane_extent_css = if (hit.leading_edge)
            scrollingPaneExtentFromLeadingDrag(position, hit.scroll_offset, hit.drag_origin, hit.drag_extent, ui_scale)
        else
            scrollingPaneExtentFromTrailingDrag(position, hit.scroll_offset, hit.drag_origin, ui_scale);
        const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
        const viewport_extent = if (hit.axis == .vertical) hit.split_rect.w else hit.split_rect.h;
        const extent_ratio = scrollingPaneExtentRatio(
            theme.clampf(pane_extent_css, workspace_layout.MIN_SCROLL_PANE_EXTENT_CSS, workspace_layout.MAX_SCROLL_PANE_EXTENT_CSS) * ui_scale,
            viewport_extent,
            theme.scaledUi(state.app_config.workspace_pane_gap),
        );
        if (!layout.setPaneScrollExtent(hit.pane_id, pane_extent_css, extent_ratio)) return;
        if (hit.leading_edge) {
            const new_extent_px = (layout.paneById(hit.pane_id) orelse return).scroll_extent_css.? * ui_scale;
            const next_scroll = @max(0.0, scrollingScrollAfterLeadingResize(hit.scroll_offset, hit.drag_extent, new_extent_px));
            if (hit.axis == .vertical) {
                layout.scroll_offset_x = next_scroll;
                layout.scroll_target_x = next_scroll;
            } else {
                layout.scroll_offset_y = next_scroll;
                layout.scroll_target_y = next_scroll;
            }
        }
        state.markDirty();
        return;
    }
    const ratio = if (hit.axis == .vertical)
        (x - hit.split_rect.x) / @max(hit.split_rect.w, 1.0)
    else
        (y - hit.split_rect.y) / @max(hit.split_rect.h, 1.0);
    state.resizeCurrentProjectWorkspaceSplit(hit.pane_id, hit.sibling_pane_id, hit.axis, ratio);
}

fn renderLeafWithTranscriptLayoutWidth(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, rect: palette.Rect, target_width: f32) void {
    renderLeafWithin(state, pane_id, rect, null, target_width);
}

fn renderLeafWithin(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, rect: palette.Rect, viewport_clip: ?palette.Rect, target_width: f32) void {
    // Workspace pane contents. Scrolling panes pass the visible workspace so
    // expensive renderers can avoid emitting commands that will be clipped.
    const kind = state.workspacePaneKindById(pane_id) orelse return;
    if (pane_rect_count < pane_rects.len) {
        pane_rects[pane_rect_count] = .{ .pane_id = pane_id, .rect = rect };
        pane_rect_count += 1;
    }
    const maximized = state.isCurrentProjectWorkspacePaneMaximized(pane_id);
    const reserve = if (kind == .chat) theme.scaledUi(CHAT_PANE_HEADER_RIGHT_RESERVE_CSS) else 0.0;
    const header_h = switch (kind) {
        .chat => chat_panel.paneHeaderHeight(rect),
        .terminal => terminal_panel.paneHeaderHeight(),
        .browser => 0.0,
    };
    switch (kind) {
        .chat => chat_panel.renderWorkspaceAtForPaneWithReserveAndTranscriptLayoutWidth(state, rect, pane_id, reserve, target_width),
        .terminal => {
            const dock_id = state.workspaceTerminalDockIdByPane(pane_id) orelse 0;
            if (viewport_clip) |clip| {
                terminal_panel.renderDockAtForDockWithin(state, rect, dock_id, reserve, clip);
            } else {
                terminal_panel.renderDockAtForDockWithReserve(state, rect, dock_id, reserve);
            }
        },
        .browser => {
            browser_pane_rendered = true;
            browser_panel.renderDockAtWithReserve(state, rect, theme.scaledUi(BROWSER_TOOLBAR_RIGHT_RESERVE_CSS));
        },
    }
    renderInactivePaneFade(state, pane_id, rect);
    if (kind == .chat and header_h > 0.0) {
        const header_rect = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = header_h };
        renderPaneOverlay(state, pane_id, header_rect);
    }
    renderZoomControl(state, pane_id, kind, rect, header_h, maximized);
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    if (paneUsesRestingBorder(layout.rootContainsPane(pane_id), layout.visiblePaneCount(), maximized)) {
        queueBorder(state, rect, paletteColor(theme.borderMuted()), 0.0, theme.scaledUi(INACTIVE_BORDER_WIDTH_CSS));
    }
    // Pane status frame. Live agent states intentionally override the ordinary
    // focus/unfocused and zoom colors so they remain legible in tiled and
    // maximized layouts without tinting the pane's content.
    const agent_status = paneAgentVisualStatus(state, pane_id);
    if (agent_status != .idle) {
        const animated = !state.app_config.reduced_motion;
        pane_status_animating = pane_status_animating or animated;
        const pulse = paneStatusPulseForMotion(agent_status, nowMs(), state.app_config.reduced_motion);
        var border_color = switch (agent_status) {
            .done => theme.success(),
            .working => theme.accent(),
            .waiting => theme.COLOR_YELLOW,
            .@"error" => theme.COLOR_DIFF_REMOVE,
            .idle => unreachable,
        };
        const min_alpha: f32 = if (agent_status == .done or agent_status == .@"error") 0.72 else 0.52;
        border_color[3] *= min_alpha + (1.0 - min_alpha) * pulse;
        const border_width = theme.scaledUi(if (maximized) STATUS_ZOOM_BORDER_WIDTH_CSS else STATUS_BORDER_WIDTH_CSS);
        queueBorder(state, rect, paletteColor(border_color), 0.0, border_width);
        return;
    }

    // Quiet panes retain the existing animated focus border.
    const focus_alpha = focusBorderAlpha(pane_id);
    const alpha = @max(focus_alpha, if (maximized) @as(f32, 1.0) else @as(f32, 0.0));
    if (alpha > 0.01) {
        var border_color = if (maximized) zoomBorderAccent() else theme.accent();
        border_color[3] *= alpha;
        const border_width = theme.scaledUi(if (maximized) ZOOM_BORDER_WIDTH_CSS else FOCUS_BORDER_WIDTH_CSS);
        queueBorder(state, rect, paletteColor(border_color), 0.0, border_width);
    }
}

// Top-right zoom control for chat, terminal, and browser workspace panes.
fn renderZoomControl(
    state: *runtime.AppState,
    pane_id: runtime.WorkspacePaneId,
    kind: runtime.WorkspacePaneKind,
    pane_rect: palette.Rect,
    header_h: f32,
    maximized: bool,
) void {
    const control_size = theme.scaledUi(PANE_CHROME_CONTROL_SIZE_CSS);
    const margin = theme.scaledUi(PANE_CHROME_RIGHT_MARGIN_CSS);
    // Browser owns the far-right close action; keep zoom immediately to its left.
    const split_reserve = if (kind == .chat or kind == .terminal or kind == .browser)
        theme.scaledUi(PANE_CHROME_CONTROL_SIZE_CSS + PANE_CHROME_CONTROL_GAP_CSS)
    else
        0.0;
    const control_rect: palette.Rect = .{
        .x = pane_rect.x + pane_rect.w - margin - split_reserve - control_size,
        .y = switch (kind) {
            .chat => pane_rect.y + @max((header_h - control_size) * 0.5, theme.scaledUi(4.0)),
            .terminal => pane_rect.y + margin,
            .browser => pane_rect.y + (browser_panel.paneToolbarActionRowHeight() - control_size) * 0.5,
        },
        .w = control_size,
        .h = control_size,
    };
    const hovered = state.transcript_controller.palette_mouse_in_workspace and rectContains(control_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    if (kind == .terminal and !maximized and !state.alt_shortcut_hints_visible) {
        const hover_rect: palette.Rect = .{
            .x = pane_rect.x + pane_rect.w - theme.scaledUi(TERMINAL_ZOOM_HOVER_WIDTH_CSS),
            .y = pane_rect.y,
            .w = theme.scaledUi(TERMINAL_ZOOM_HOVER_WIDTH_CSS),
            .h = theme.scaledUi(TERMINAL_ZOOM_HOVER_HEIGHT_CSS),
        };
        if (!rectContains(hover_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) return;
    }

    const previous_z = state.palette_overlay_batch.setZIndex(PANE_ZOOM_CONTROL_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    const icon_color = if (maximized)
        zoomIconAccent()
    else if (hovered)
        zoomIconAccent()
    else
        theme.COLOR_TEXT_MUTED;
    const icon_size = theme.scaledUi(ZOOM_ICON_SIZE_CSS);
    const icon_rect: palette.Rect = .{
        .x = control_rect.x + (control_rect.w - icon_size) * 0.5,
        .y = control_rect.y + (control_rect.h - icon_size) * 0.5,
        .w = icon_size,
        .h = icon_size,
    };
    queueIcon(
        state,
        icon_rect,
        if (maximized) NF_FA_COMPRESS else NF_FA_EXPAND,
        paletteColor(icon_color),
        icon_size,
        pane_rect,
    );
    appendHit(.{ .pane_id = pane_id, .action = .maximize, .rect = control_rect });

    if (state.alt_shortcut_hints_visible and state.isCurrentProjectWorkspacePaneFocused(pane_id)) {
        if (state.command_controller.keyboard_config) |config| {
            var label_buf: [16]u8 = undefined;
            renderPaneShortcutKeyTip(state, control_rect, pane_rect, keybinds.formatAltKeyTip(&label_buf, config.workspace_toggle_maximize));
        }
    }

    if (kind == .terminal) {
        const split_rect: palette.Rect = .{
            .x = pane_rect.x + pane_rect.w - margin - control_size,
            .y = control_rect.y,
            .w = control_size,
            .h = control_size,
        };
        const menu_open_here = if (split_menu_open_for) |id| id == pane_id else false;
        const split_emphasized = rectContains(split_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y) or menu_open_here;
        renderSplitTriggerButton(state, split_rect, menu_open_here, split_emphasized, pane_rect);
        appendHit(.{ .pane_id = pane_id, .action = .toggle_split_menu, .rect = split_rect });
        if (menu_open_here and split_menu_kind == .split_button) split_menu_anchor = split_rect;
    }
}

// Compact Alt-reveal badge attached to the focused pane's zoom control.
fn renderPaneShortcutKeyTip(state: *runtime.AppState, target: palette.Rect, clip: palette.Rect, label: []const u8) void {
    if (label.len == 0) return;
    const size = theme.scaledUi(15.0);
    const rect: palette.Rect = .{
        .x = target.x - size + theme.scaledUi(2.5),
        .y = target.y + (target.h - size) * 0.5,
        .w = size,
        .h = size,
    };
    queueRounded(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(3.5));
    queueBorder(state, rect, paletteColor(theme.borderMuted()), theme.scaledUi(3.5), theme.scaledUi(0.75));
    const font_size = theme.scaledUi(9.5);
    const text_w = runtime.paletteUiTextPrefixWidth(label, font_size, label.len);
    queueText(state, .{
        .x = rect.x + @max((rect.w - text_w) * 0.5, 0.0),
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = @min(text_w, rect.w),
        .h = font_size * 1.25,
    }, label, paletteColor(theme.accent()), font_size, clip);
}

fn zoomIconAccent() [4]f32 {
    return theme.mix(theme.accent(), theme.current_colors.text, ZOOM_ICON_FOREGROUND_MIX);
}

fn zoomBorderAccent() [4]f32 {
    return theme.mix(theme.accent(), theme.current_colors.text, ZOOM_BORDER_FOREGROUND_MIX);
}

fn renderInactivePaneFade(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, rect: palette.Rect) void {
    if (state.currentProjectWorkspaceVisiblePaneCount() <= 1) return;
    if (state.isCurrentProjectWorkspacePaneFocused(pane_id)) return;
    queueRect(state, rect, paletteColor(theme.withAlpha(theme.background(), INACTIVE_PANE_FADE_ALPHA)));
}

fn renderPaneOverlay(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, header_rect: palette.Rect) void {
    const focused = state.isCurrentProjectWorkspacePaneFocused(pane_id);
    // Focus hit covers the header area only, registered first so it sits at lowest
    // priority. Clicks on icons (registered later) take precedence; clicks on the
    // chat panel's own buttons (Open/Browser) are resolved by chat_panel before
    // this handler runs.
    appendHit(.{ .pane_id = pane_id, .action = .focus, .rect = header_rect });

    const menu_open_here = if (split_menu_open_for) |id| id == pane_id else false;
    // Render only when focused — non-focused panes keep their panel header clean.
    if (focused) {
        // Split trigger (+): always visible on focused pane, brightens on direct hover.
        const split_w = theme.scaledUi(PANE_CHROME_CONTROL_SIZE_CSS);
        const split_h = theme.scaledUi(PANE_CHROME_CONTROL_SIZE_CSS);
        const right_margin = theme.scaledUi(PANE_CHROME_RIGHT_MARGIN_CSS);
        const split_x = header_rect.x + header_rect.w - right_margin - split_w;
        const split_y = header_rect.y + (header_rect.h - split_h) * 0.5;
        const split_rect = palette.Rect{ .x = split_x, .y = split_y, .w = split_w, .h = split_h };
        const split_active = menu_open_here;
        const split_emphasized = rectContains(split_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y) or split_active;
        renderSplitTriggerButton(state, split_rect, split_active, split_emphasized, header_rect);
        appendHit(.{ .pane_id = pane_id, .action = .toggle_split_menu, .rect = split_rect });
        if (menu_open_here and split_menu_kind == .split_button) split_menu_anchor = split_rect;
    }
}

fn renderSplitTriggerButton(state: *runtime.AppState, rect: palette.Rect, active: bool, emphasized: bool, clip: palette.Rect) void {
    _ = clip;
    if (active) {
        queueRounded(state, rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(5.0));
        queueBorder(state, rect, paletteColor(theme.accent()), theme.scaledUi(5.0), theme.scaledUi(1.0));
    } else if (emphasized) {
        queueRounded(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(5.0));
        queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(5.0), theme.scaledUi(1.0));
    }
    const icon_color = if (active or emphasized)
        theme.COLOR_WHITE
    else
        theme.COLOR_TEXT_SUBTLE;

    const cell = theme.scaledUi(4.0);
    const gap = theme.scaledUi(2.0);
    const grid_w = cell * 2.0 + gap;
    const grid_h = grid_w;
    const start_x = rect.x + (rect.w - grid_w) * 0.5;
    const start_y = rect.y + (rect.h - grid_h) * 0.5;
    var row: usize = 0;
    while (row < 2) : (row += 1) {
        var col: usize = 0;
        while (col < 2) : (col += 1) {
            queueRect(state, .{
                .x = start_x + @as(f32, @floatFromInt(col)) * (cell + gap),
                .y = start_y + @as(f32, @floatFromInt(row)) * (cell + gap),
                .w = cell,
                .h = cell,
            }, paletteColor(icon_color));
        }
    }
}

fn renderSplitMenuOverlay(state: *runtime.AppState, workspace_rect: palette.Rect) void {
    const pane_id = split_menu_open_for orelse return;
    const previous_z = state.palette_overlay_batch.setZIndex(PANE_CONTEXT_MENU_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    const menu_w = theme.scaledUi(230.0);
    const submenu_w = theme.scaledUi(210.0);
    const row_h = theme.scaledUi(28.0);
    const row_gap = theme.scaledUi(4.0);
    const menu_pad_x = theme.scaledUi(14.0);
    const menu_pad_top = theme.scaledUi(12.0);
    const menu_pad_bottom = theme.scaledUi(12.0);
    const pane_kind = state.workspacePaneKindById(pane_id);
    const is_chat_context = split_menu_kind == .chat_context and pane_kind == .chat;
    const copy_count: usize = if (is_chat_context and state.transcriptMarkdownSelectionActive()) 1 else 0;
    const paste_count: usize = if (is_chat_context and split_menu_show_paste) 1 else 0;
    const chat_command_count: usize = if (is_chat_context) copy_count + paste_count + 2 else 0;
    const command_count: usize = chat_command_count + 3;
    const split_count: usize = 8;
    const menu_h = menu_pad_top + menu_pad_bottom +
        @as(f32, @floatFromInt(command_count)) * row_h +
        @as(f32, @floatFromInt(command_count - 1)) * row_gap;
    const submenu_h = menu_pad_top + menu_pad_bottom +
        @as(f32, @floatFromInt(split_count)) * row_h +
        @as(f32, @floatFromInt(split_count - 1)) * row_gap;

    var menu_x = split_menu_anchor.x;
    const max_x = workspace_rect.x + workspace_rect.w - menu_w - theme.scaledUi(8.0);
    if (menu_x > max_x) menu_x = max_x;
    if (menu_x < workspace_rect.x + theme.scaledUi(8.0)) menu_x = workspace_rect.x + theme.scaledUi(8.0);
    var menu_y = split_menu_anchor.y + split_menu_anchor.h + theme.scaledUi(6.0);
    const max_y = workspace_rect.y + workspace_rect.h - menu_h - theme.scaledUi(8.0);
    if (menu_y > max_y) menu_y = max_y;

    const menu_rect = palette.Rect{ .x = menu_x, .y = menu_y, .w = menu_w, .h = menu_h };
    split_menu_rect = menu_rect;
    split_submenu_rect = .{};

    queueRounded(state, menu_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(10.0));
    queueBorder(state, menu_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(10.0), theme.scaledUi(1.0));

    const MenuRow = struct {
        action: WorkspacePaneAction,
        label: []const u8,
    };
    var y = menu_rect.y + menu_pad_top;
    const row_rect_w = menu_rect.w - menu_pad_x * 2.0;
    if (is_chat_context) {
        if (copy_count > 0) y = renderContextMenuRow(state, pane_id, .copy_selection, "Copy", menu_rect, menu_pad_x, y, row_rect_w, row_h) + row_gap;
        if (paste_count > 0) y = renderContextMenuRow(state, pane_id, .paste_into_prompt, "Paste", menu_rect, menu_pad_x, y, row_rect_w, row_h) + row_gap;
        y = renderContextMenuRow(state, pane_id, .new_chat_thread, "New Chat Thread", menu_rect, menu_pad_x, y, row_rect_w, row_h) + row_gap;
        y = renderContextMenuRow(state, pane_id, .refresh_chat_thread, "Refresh Chat Thread", menu_rect, menu_pad_x, y, row_rect_w, row_h) + row_gap;
    }
    const zoom_label = if (state.isCurrentProjectWorkspacePaneMaximized(pane_id)) "Unzoom Pane" else "Zoom Pane";
    y = renderContextMenuRow(state, pane_id, .maximize, zoom_label, menu_rect, menu_pad_x, y, row_rect_w, row_h) + row_gap;
    const split_trigger_rect = renderContextMenuStaticRow(state, "Split Pane", menu_rect, menu_pad_x, y, row_rect_w, row_h, true);
    y = split_trigger_rect.y + split_trigger_rect.h + row_gap;
    _ = renderContextMenuRow(state, pane_id, .close, "Close Pane", menu_rect, menu_pad_x, y, row_rect_w, row_h);

    const rows = [_]MenuRow{
        .{ .action = .split_chat_left, .label = "Chat Left" },
        .{ .action = .split_chat_right, .label = "Chat Right" },
        .{ .action = .split_chat_up, .label = "Chat Above" },
        .{ .action = .split_chat_down, .label = "Chat Below" },
        .{ .action = .split_terminal_left, .label = "Terminal Left" },
        .{ .action = .split_terminal_right, .label = "Terminal Right" },
        .{ .action = .split_terminal_up, .label = "Terminal Above" },
        .{ .action = .split_terminal_down, .label = "Terminal Below" },
    };

    var submenu_x = menu_rect.x + menu_rect.w + theme.scaledUi(6.0);
    if (submenu_x + submenu_w > workspace_rect.x + workspace_rect.w - theme.scaledUi(8.0)) {
        submenu_x = menu_rect.x - submenu_w - theme.scaledUi(6.0);
    }
    var submenu_y = split_trigger_rect.y;
    const submenu_max_y = workspace_rect.y + workspace_rect.h - submenu_h - theme.scaledUi(8.0);
    if (submenu_y > submenu_max_y) submenu_y = submenu_max_y;
    if (submenu_y < workspace_rect.y + theme.scaledUi(8.0)) submenu_y = workspace_rect.y + theme.scaledUi(8.0);
    const submenu_rect = palette.Rect{ .x = submenu_x, .y = submenu_y, .w = submenu_w, .h = submenu_h };
    const submenu_visible = rectContains(split_trigger_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y) or rectContains(submenu_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    if (submenu_visible) {
        split_submenu_rect = submenu_rect;
        queueRounded(state, submenu_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(10.0));
        queueBorder(state, submenu_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(10.0), theme.scaledUi(1.0));
        y = submenu_rect.y + menu_pad_top;
        const submenu_row_w = submenu_rect.w - menu_pad_x * 2.0;
        for (rows) |row| {
            y = renderContextMenuRow(state, pane_id, row.action, row.label, submenu_rect, menu_pad_x, y, submenu_row_w, row_h) + row_gap;
        }
    }
}

fn renderContextMenuStaticRow(
    state: *runtime.AppState,
    label: []const u8,
    menu_rect: palette.Rect,
    pad_x: f32,
    y: f32,
    w: f32,
    h: f32,
    arrow: bool,
) palette.Rect {
    const rect = palette.Rect{ .x = menu_rect.x + pad_x, .y = y, .w = w, .h = h };
    const hovered = rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    if (hovered) queueRounded(state, rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(5.0));
    queueText(state, .{
        .x = rect.x + theme.scaledUi(8.0),
        .y = rect.y + (rect.h - theme.scaledUi(14.0)) * 0.5,
        .w = @max(rect.w - theme.scaledUi(32.0), 1.0),
        .h = theme.scaledUi(14.0),
    }, label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(12.0), menu_rect);
    if (arrow) {
        queueText(state, .{
            .x = rect.x + rect.w - theme.scaledUi(20.0),
            .y = rect.y + (rect.h - theme.scaledUi(14.0)) * 0.5,
            .w = theme.scaledUi(12.0),
            .h = theme.scaledUi(14.0),
        }, ">", paletteColor(theme.COLOR_WHITE), theme.scaledUi(12.0), menu_rect);
    }
    return rect;
}

fn renderContextMenuRow(
    state: *runtime.AppState,
    pane_id: runtime.WorkspacePaneId,
    action: WorkspacePaneAction,
    label: []const u8,
    menu_rect: palette.Rect,
    pad_x: f32,
    y: f32,
    w: f32,
    h: f32,
) f32 {
    const rect = palette.Rect{ .x = menu_rect.x + pad_x, .y = y, .w = w, .h = h };
    const hovered = rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    if (hovered) {
        queueRounded(state, rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(5.0));
    }
    const text_color = if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    queueText(state, .{
        .x = rect.x + theme.scaledUi(8.0),
        .y = rect.y + (rect.h - theme.scaledUi(14.0)) * 0.5,
        .w = @max(rect.w - theme.scaledUi(16.0), 1.0),
        .h = theme.scaledUi(14.0),
    }, label, paletteColor(text_color), theme.scaledUi(12.0), menu_rect);
    appendHit(.{ .pane_id = pane_id, .action = action, .rect = rect });
    return rect.y + rect.h;
}

fn copyTranscriptSelectionToClipboard(state: *runtime.AppState) void {
    const text = (chat_panel.transcriptMarkdownSelectionPlainText(state) catch {
        state.setSidebarNotice("Failed to copy selection.");
        return;
    }) orelse {
        state.setSidebarNotice("No transcript text selected.");
        return;
    };
    defer state.allocator.free(text);
    if (text.len == 0) {
        state.setSidebarNotice("No transcript text selected.");
        return;
    }
    const z = state.allocator.dupeZ(u8, text) catch {
        state.setSidebarNotice("Failed to copy selection.");
        return;
    };
    defer state.allocator.free(z);
    sdl.setClipboardText(z) catch {
        state.setSidebarNotice("Failed to copy selection.");
        return;
    };
    state.setSidebarNotice("Copied selection.");
}

fn appendHit(hit: WorkspacePaneHit) void {
    if (hit_cache.count >= hit_cache.hits.len) return;
    hit_cache.hits[hit_cache.count] = hit;
    hit_cache.count += 1;
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h;
}

fn keymodBits(modifier_state: sdl.Keymod) u16 {
    return @as(*const u16, @ptrCast(&modifier_state)).*;
}

fn stableText(state: *runtime.AppState, value: []const u8) []const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch "";
}

fn queueRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch {};
}

fn queueRounded(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch {};
}

fn queueBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch {};
}

fn queueText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.text(state.allocator, rect, stableText(state, value), color, font_size, clip) catch {};
}

fn queueIcon(state: *runtime.AppState, rect: palette.Rect, glyph: []const u8, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roleText(
        state.allocator,
        rect,
        stableText(state, glyph),
        color,
        font_size,
        .icon,
        null,
        clip,
    ) catch {};
}

fn paletteColor(color: [4]f32) palette.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

test "empty workspace option navigation wraps without external state" {
    try std.testing.expectEqual(@as(usize, 1), emptyWorkspaceSelectionAfterMove(0, 1));
    try std.testing.expectEqual(@as(usize, 2), emptyWorkspaceSelectionAfterMove(1, 1));
    try std.testing.expectEqual(@as(usize, 0), emptyWorkspaceSelectionAfterMove(2, 1));
    try std.testing.expectEqual(@as(usize, 2), emptyWorkspaceSelectionAfterMove(0, -1));
    try std.testing.expectEqual(@as(usize, 0), emptyWorkspaceSelectionAfterMove(1, -1));
}

test "pane status pulses are bounded and use deliberately slow periods" {
    try std.testing.expect(DONE_PULSE_PERIOD_MS > WORKING_PULSE_PERIOD_MS);
    try std.testing.expect(WORKING_PULSE_PERIOD_MS >= 2000);

    inline for (.{ PaneAgentVisualStatus.done, PaneAgentVisualStatus.working }) |status| {
        const period = if (status == .done) DONE_PULSE_PERIOD_MS else WORKING_PULSE_PERIOD_MS;
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), paneStatusPulse(status, 0), 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), paneStatusPulse(status, @divTrunc(period, 4)), 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), paneStatusPulse(status, @divTrunc(period, 2)), 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), paneStatusPulse(status, @divTrunc(period * 3, 4)), 0.0001);
    }
    try std.testing.expectEqual(@as(f32, 1.0), paneStatusPulseForMotion(.working, 0, true));
    try std.testing.expectEqual(@as(f32, 1.0), paneStatusPulseForMotion(.done, DONE_PULSE_PERIOD_MS * 3 / 4, true));
}

test "directional navigation transfers zoom unless unzoom is configured" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try storage_mod.Storage.initWithPrefPath(allocator, path_buf[0..path_len]);
    defer storage.deinit();
    var state = try runtime.AppState.init(allocator, &storage, app_config.AppConfig{}, .{
        .gl_texture_uploads_enabled = false,
        .browser_textures_enabled = false,
    });
    defer {
        state.lifecycle.clearDirty();
        state.deinit();
    }

    for (state.project_controller.projects.items) |*project| project.deinit(allocator);
    state.project_controller.projects.clearRetainingCapacity();
    state.lifecycle.clearDirty();

    var project = try runtime.Project.init(allocator, "zoom-navigation", "Zoom Navigation", "/tmp/zoom-navigation", 0);
    const first_pane_id = project.workspace_layout.focused_pane_id.?;
    const second_thread = try project.addThread(allocator);
    const second_pane_id = try project.workspace_layout.createChatPane(allocator, second_thread);
    try project.workspace_layout.splitPaneWithLeaf(allocator, first_pane_id, second_pane_id, .vertical, true);
    project.workspace_layout.focused_pane_id = first_pane_id;
    project.workspace_layout.maximized_pane_id = first_pane_id;
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    state.project_controller.selected_index = 0;

    const rects = [_]WorkspacePaneRect{
        .{ .pane_id = first_pane_id, .rect = .{ .x = 0.0, .y = 0.0, .w = 100.0, .h = 100.0 } },
        .{ .pane_id = second_pane_id, .rect = .{ .x = 101.0, .y = 0.0, .w = 100.0, .h = 100.0 } },
    };
    try std.testing.expect(focusPaneInDirectionFromRects(&state, first_pane_id, .right, &rects, true));
    var layout = &state.project_controller.projects.items[0].workspace_layout;
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, second_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, second_pane_id), layout.maximized_pane_id);

    layout.focused_pane_id = first_pane_id;
    layout.maximized_pane_id = first_pane_id;
    state.app_config.unzoom_on_pane_navigation = true;
    try std.testing.expect(focusPaneInDirectionFromRects(&state, first_pane_id, .right, &rects, true));
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, second_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, null), layout.maximized_pane_id);
}

test "zoomed scrolling navigation follows sidebar order through terminal panes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try storage_mod.Storage.initWithPrefPath(allocator, path_buf[0..path_len]);
    defer storage.deinit();
    var state = try runtime.AppState.init(allocator, &storage, app_config.AppConfig{}, .{
        .gl_texture_uploads_enabled = false,
        .browser_textures_enabled = false,
    });
    defer {
        pane_rect_count = 0;
        state.lifecycle.clearDirty();
        state.deinit();
    }

    for (state.project_controller.projects.items) |*project| project.deinit(allocator);
    state.project_controller.projects.clearRetainingCapacity();
    state.lifecycle.clearDirty();

    var project = try runtime.Project.init(allocator, "scroll-navigation", "Scroll Navigation", "/tmp/scroll-navigation", 0);
    const first_pane_id = project.workspace_layout.focused_pane_id.?;
    const lower_thread = try project.addThread(allocator);
    const lower_chat_pane_id = try project.workspace_layout.createChatPane(allocator, lower_thread);
    try project.workspace_layout.splitPaneWithLeaf(allocator, first_pane_id, lower_chat_pane_id, .horizontal, true);
    try std.testing.expect(project.workspace_layout.joinPaneToScrollGroup(first_pane_id, lower_chat_pane_id));
    const terminal_pane_id = try project.workspace_layout.createTerminalPane(allocator, 7);
    try project.workspace_layout.splitPaneWithLeaf(allocator, first_pane_id, terminal_pane_id, .vertical, true);
    const trailing_thread = try project.addThread(allocator);
    const trailing_chat_pane_id = try project.workspace_layout.createChatPane(allocator, trailing_thread);
    try project.workspace_layout.splitPaneWithLeaf(allocator, first_pane_id, trailing_chat_pane_id, .vertical, true);
    project.workspace_layout.focused_pane_id = first_pane_id;
    project.workspace_layout.maximized_pane_id = first_pane_id;
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    state.project_controller.selected_index = 0;
    state.app_config.workspace_scroll_mode = .always;
    state.app_config.workspace_scroll_direction = .horizontal;

    // Zoomed navigation follows hidden split geometry inside a tiled group,
    // then follows scrolling-group order along the strip axis.
    pane_rect_count = 1;
    pane_rects[0] = .{ .pane_id = first_pane_id, .rect = .{ .x = 0.0, .y = 0.0, .w = 1000.0, .h = 700.0 } };
    const layout = &state.project_controller.projects.items[0].workspace_layout;
    try std.testing.expect(focusPaneInDirection(&state, .down));
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, lower_chat_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, lower_chat_pane_id), layout.maximized_pane_id);
    try std.testing.expect(focusPaneInDirection(&state, .up));
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, first_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, first_pane_id), layout.maximized_pane_id);
    try std.testing.expect(focusPaneInDirection(&state, .right));
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, terminal_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, terminal_pane_id), layout.maximized_pane_id);
}

test "scrolling focus reveal moves only enough to expose the column" {
    const viewport_w: f32 = 1000.0;
    const column_w: f32 = 640.0;
    const gap: f32 = 1.0;
    const max_offset: f32 = 281.0;

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), revealedScrollTarget(0.0, viewport_w, column_w, gap, 0, max_offset), 0.0001);
    try std.testing.expectApproxEqAbs(max_offset, revealedScrollTarget(0.0, viewport_w, column_w, gap, 1, max_offset), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), revealedScrollTarget(max_offset, viewport_w, column_w, gap, 0, max_offset), 0.0001);
}

test "sidebar horizontal render preserves visible activation and minimally reveals after pre-render resize" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try storage_mod.Storage.initWithPrefPath(allocator, path_buf[0..path_len]);
    defer storage.deinit();
    var state = try runtime.AppState.init(allocator, &storage, app_config.AppConfig{}, .{
        .gl_texture_uploads_enabled = false,
        .browser_textures_enabled = false,
    });
    defer {
        state.lifecycle.clearDirty();
        state.deinit();
    }

    for (state.project_controller.projects.items) |*project| project.deinit(allocator);
    state.project_controller.projects.clearRetainingCapacity();
    state.lifecycle.clearDirty();

    var project = try runtime.Project.init(allocator, "render-a", "Render A", "/tmp/render-a", 0);
    const second_thread = try project.addThread(allocator);
    const second_pane = try project.workspace_layout.createChatPane(allocator, second_thread);
    try project.workspace_layout.splitPaneWithLeaf(allocator, 1, second_pane, .horizontal, true);
    try std.testing.expect(project.workspace_layout.resizeSplit(1, second_pane, .horizontal, 0.37));
    const third_thread = try project.addThread(allocator);
    const third_pane = try project.workspace_layout.createChatPane(allocator, third_thread);
    try project.workspace_layout.splitPaneWithLeaf(allocator, second_pane, third_pane, .vertical, true);
    try std.testing.expect(project.workspace_layout.resizeSplit(second_pane, third_pane, .vertical, 0.61));
    project.workspace_layout.focused_pane_id = second_pane;
    project.workspace_layout.maximized_pane_id = second_pane;
    project.workspace_layout.scroll_offset_x = 73.25;
    project.workspace_layout.scroll_target_x = 73.25;
    project.workspace_layout.scroll_offset_y = 19.5;
    project.workspace_layout.scroll_target_y = 19.5;
    project.workspace_layout.scroll_mode_override = .always;
    project.workspace_layout.scroll_pane_extent_override = 620.0;
    project.workspace_layout.scroll_pane_extent_ratio_override = 0.30;
    const persisted = try project.workspace_layout.persistedWorkspaceJson(allocator);
    defer allocator.free(persisted);
    try project.workspace_layout.applyPersistedWorkspaceJson(allocator, persisted);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    var away = try runtime.Project.init(allocator, "render-b", "Render B", "/tmp/render-b", 0);
    state.project_controller.projects.append(allocator, away) catch |err| {
        away.deinit(allocator);
        return err;
    };
    state.project_controller.selected_index = 0;

    const narrow: palette.Rect = .{ .x = 31.0, .y = 47.0, .w = 1000.0, .h = 780.0 };
    const layout = &state.project_controller.projects.items[0].workspace_layout;

    // Establish a real strip acknowledgement, maximize its visible pane,
    // transfer maximize to offscreen C, then restore through production APIs.
    try std.testing.expect(state.toggleWorkspacePaneMaximized(0, second_pane));
    renderAt(&state, narrow);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, second_pane), layout.scroll_revealed_pane_id);
    const preserved_target_x = layout.scroll_target_x;
    const preserved_target_y = layout.scroll_target_y;
    try std.testing.expect(state.toggleWorkspacePaneMaximized(0, second_pane));
    state.focusWorkspaceOpenPaneFromSidebar(0, third_pane);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, third_pane), layout.maximized_pane_id);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, null), layout.scroll_revealed_pane_id);
    try std.testing.expectEqual(preserved_target_x, layout.scroll_target_x);
    try std.testing.expectEqual(preserved_target_y, layout.scroll_target_y);
    layout.scroll_pane_extent_ratio_override = 0.45;
    try std.testing.expect(state.clearWorkspacePaneMaximized(0));
    renderAt(&state, narrow);

    const gap = theme.scaledUi(state.app_config.workspace_pane_gap);
    const viewport_w = scrollingViewportExtent(narrow.w, gap, layout.visiblePaneCount(), state.app_config.workspace_panes_per_view);
    const pane_extent = responsiveScrollingPaneExtent(
        viewport_w,
        gap,
        state.app_config.workspace_panes_per_view,
        layout.scroll_pane_extent_override,
        layout.scroll_pane_extent_ratio_override,
        theme.uiScaleFactor(),
    );
    const max_offset = scrollingMaxOffset(viewport_w, pane_extent, gap, layout.visiblePaneCount());
    const expected_target = revealedScrollTarget(preserved_target_x, viewport_w, pane_extent, gap, 2, max_offset);
    const leading_target = leadingScrollTarget(pane_extent, gap, 2, max_offset);
    try std.testing.expectApproxEqAbs(expected_target, layout.scroll_target_x, 0.0001);
    try std.testing.expect(expected_target > preserved_target_x);
    try std.testing.expect(layout.scroll_target_x < leading_target);
    const third_end = 3.0 * pane_extent + 2.0 * gap;
    try std.testing.expect(third_end <= layout.scroll_target_x + viewport_w + 0.0001);
    try std.testing.expect(layout.scroll_target_x <= third_end - viewport_w + 0.0001);
    try std.testing.expect(layout.scroll_offset_x >= 0.0 and layout.scroll_offset_x <= max_offset);
    try std.testing.expectEqual(preserved_target_y, layout.scroll_target_y);

    // Same-pane sidebar reselection invalidates the old acknowledgement. A
    // changed same-axis extent is recomputed, while unchanged visible geometry
    // preserves both the exact animated offset and target.
    const shorter: palette.Rect = .{ .x = 31.0, .y = 47.0, .w = 700.0, .h = 780.0 };
    const before_resize_target = layout.scroll_target_x;
    layout.scroll_pane_extent_ratio_override = 0.60;
    state.focusWorkspaceOpenPaneFromSidebar(0, third_pane);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, null), layout.scroll_revealed_pane_id);
    renderAt(&state, shorter);
    const resized_viewport_w = scrollingViewportExtent(shorter.w, gap, layout.visiblePaneCount(), state.app_config.workspace_panes_per_view);
    const resized_extent = responsiveScrollingPaneExtent(resized_viewport_w, gap, state.app_config.workspace_panes_per_view, layout.scroll_pane_extent_override, layout.scroll_pane_extent_ratio_override, theme.uiScaleFactor());
    const resized_max = scrollingMaxOffset(resized_viewport_w, resized_extent, gap, layout.visiblePaneCount());
    const resized_expected = revealedScrollTarget(before_resize_target, resized_viewport_w, resized_extent, gap, 2, resized_max);
    try std.testing.expectApproxEqAbs(resized_expected, layout.scroll_target_x, 0.0001);
    layout.scroll_offset_x = layout.scroll_target_x;
    const visible_offset = layout.scroll_offset_x;
    const visible_target = layout.scroll_target_x;
    state.focusWorkspaceOpenPaneFromSidebar(0, third_pane);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, null), layout.scroll_revealed_pane_id);
    renderAt(&state, shorter);
    try std.testing.expectEqual(visible_offset, layout.scroll_offset_x);
    try std.testing.expectEqual(visible_target, layout.scroll_target_x);

    // Explicit non-sidebar navigation still places a genuinely offscreen pane
    // at its leading edge.
    state.focusWorkspaceOpenPaneFromSidebar(0, 1);
    renderAt(&state, shorter);
    state.focusWorkspaceOpenPane(0, third_pane);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, third_pane), layout.scroll_leading_pane_id);
    renderAt(&state, shorter);
    try std.testing.expectApproxEqAbs(leadingScrollTarget(resized_extent, gap, 2, resized_max), layout.scroll_target_x, 0.0001);
    switch (layout.root.?.*) {
        .split => |split| try std.testing.expectApproxEqAbs(@as(f32, 0.37), split.ratio, 0.0001),
        .leaf => return error.TestExpectedEqual,
    }
}

test "sidebar vertical render minimally reveals after pre-render resize" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var config: app_config.AppConfig = .{};
    config.workspace_scroll_direction = .vertical;
    var storage = try storage_mod.Storage.initWithPrefPath(allocator, path_buf[0..path_len]);
    defer storage.deinit();
    var state = try runtime.AppState.init(allocator, &storage, config, .{
        .gl_texture_uploads_enabled = false,
        .browser_textures_enabled = false,
    });
    defer {
        state.lifecycle.clearDirty();
        state.deinit();
    }

    for (state.project_controller.projects.items) |*project| project.deinit(allocator);
    state.project_controller.projects.clearRetainingCapacity();
    state.lifecycle.clearDirty();

    var project = try runtime.Project.init(allocator, "render-vertical", "Render vertical", "/tmp/render-vertical", 0);
    const second_thread = try project.addThread(allocator);
    const second_pane = try project.workspace_layout.createChatPane(allocator, second_thread);
    try project.workspace_layout.splitPaneWithLeaf(allocator, 1, second_pane, .horizontal, true);
    try std.testing.expect(project.workspace_layout.resizeSplit(1, second_pane, .horizontal, 0.38));
    const third_thread = try project.addThread(allocator);
    const third_pane = try project.workspace_layout.createChatPane(allocator, third_thread);
    try project.workspace_layout.splitPaneWithLeaf(allocator, second_pane, third_pane, .vertical, true);
    try std.testing.expect(project.workspace_layout.resizeSplit(second_pane, third_pane, .vertical, 0.62));
    project.workspace_layout.focused_pane_id = second_pane;
    project.workspace_layout.scroll_offset_x = 41.0;
    project.workspace_layout.scroll_target_x = 41.0;
    project.workspace_layout.scroll_offset_y = 19.5;
    project.workspace_layout.scroll_target_y = 19.5;
    project.workspace_layout.scroll_mode_override = .always;
    project.workspace_layout.scroll_pane_extent_override = 620.0;
    project.workspace_layout.scroll_pane_extent_ratio_override = 0.30;
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    var away = try runtime.Project.init(allocator, "render-vertical-away", "Away", "/tmp/render-vertical-away", 0);
    state.project_controller.projects.append(allocator, away) catch |err| {
        away.deinit(allocator);
        return err;
    };
    state.project_controller.selected_index = 0;

    const tall: palette.Rect = .{ .x = 31.0, .y = 47.0, .w = 780.0, .h = 1400.0 };
    const short: palette.Rect = .{ .x = 31.0, .y = 47.0, .w = 780.0, .h = 1000.0 };
    const layout = &state.project_controller.projects.items[0].workspace_layout;

    renderAt(&state, tall);
    state.focusWorkspaceOpenPaneFromSidebar(0, third_pane);
    renderAt(&state, tall);
    state.focusWorkspaceOpenPaneFromSidebar(0, second_pane);
    renderAt(&state, tall);
    layout.scroll_offset_y = layout.scroll_target_y;
    const visible_offset = layout.scroll_offset_y;
    const visible_target = layout.scroll_target_y;
    state.focusWorkspaceOpenPaneFromSidebar(0, second_pane);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, null), layout.scroll_revealed_pane_id);
    renderAt(&state, tall);
    try std.testing.expectEqual(visible_offset, layout.scroll_offset_y);
    try std.testing.expectEqual(visible_target, layout.scroll_target_y);
    try std.testing.expectEqual(@as(f32, 41.0), layout.scroll_target_x);

    state.project_controller.selected_index = 1;
    layout.scroll_pane_extent_ratio_override = 0.45;
    state.focusWorkspaceOpenPaneFromSidebar(0, third_pane);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, null), layout.scroll_revealed_pane_id);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, null), layout.scroll_leading_pane_id);
    renderAt(&state, short);

    const gap = theme.scaledUi(state.app_config.workspace_pane_gap);
    const viewport_h = scrollingViewportExtent(short.h, gap, layout.visiblePaneCount(), state.app_config.workspace_panes_per_view);
    const pane_extent = responsiveScrollingPaneExtent(
        viewport_h,
        gap,
        state.app_config.workspace_panes_per_view,
        layout.scroll_pane_extent_override,
        layout.scroll_pane_extent_ratio_override,
        theme.uiScaleFactor(),
    );
    const max_offset = scrollingMaxOffset(viewport_h, pane_extent, gap, layout.visiblePaneCount());
    const expected_target = revealedScrollTarget(19.5, viewport_h, pane_extent, gap, 2, max_offset);
    const leading_target = leadingScrollTarget(pane_extent, gap, 2, max_offset);
    try std.testing.expectApproxEqAbs(expected_target, layout.scroll_target_y, 0.0001);
    try std.testing.expect(layout.scroll_target_y > 19.5);
    try std.testing.expect(layout.scroll_target_y < leading_target);
    try std.testing.expect(layout.scroll_target_y <= max_offset);
    try std.testing.expectEqual(@as(f32, 41.0), layout.scroll_target_x);

    const shorter: palette.Rect = .{ .x = 31.0, .y = 47.0, .w = 780.0, .h = 700.0 };
    const before_resize_target = layout.scroll_target_y;
    layout.scroll_pane_extent_ratio_override = 0.60;
    state.focusWorkspaceOpenPaneFromSidebar(0, third_pane);
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, null), layout.scroll_revealed_pane_id);
    renderAt(&state, shorter);
    const resized_viewport_h = scrollingViewportExtent(shorter.h, gap, layout.visiblePaneCount(), state.app_config.workspace_panes_per_view);
    const resized_extent = responsiveScrollingPaneExtent(resized_viewport_h, gap, state.app_config.workspace_panes_per_view, layout.scroll_pane_extent_override, layout.scroll_pane_extent_ratio_override, theme.uiScaleFactor());
    const resized_max = scrollingMaxOffset(resized_viewport_h, resized_extent, gap, layout.visiblePaneCount());
    const resized_expected = revealedScrollTarget(before_resize_target, resized_viewport_h, resized_extent, gap, 2, resized_max);
    try std.testing.expectApproxEqAbs(resized_expected, layout.scroll_target_y, 0.0001);
    layout.scroll_offset_y = layout.scroll_target_y;
    const same_geometry_offset = layout.scroll_offset_y;
    const same_geometry_target = layout.scroll_target_y;
    state.focusWorkspaceOpenPaneFromSidebar(0, third_pane);
    renderAt(&state, shorter);
    try std.testing.expectEqual(same_geometry_offset, layout.scroll_offset_y);
    try std.testing.expectEqual(same_geometry_target, layout.scroll_target_y);
    switch (layout.root.?.*) {
        .split => |split| try std.testing.expectApproxEqAbs(@as(f32, 0.38), split.ratio, 0.0001),
        .leaf => return error.TestExpectedEqual,
    }
}

test "scrolling pane extent fits the configured panes per view" {
    const gap: f32 = 12.0;
    inline for (.{ @as(f32, 360.0), @as(f32, 1000.0), @as(f32, 1440.0) }) |viewport_extent| {
        inline for (.{ @as(u8, 1), @as(u8, 2), @as(u8, 3), @as(u8, 6) }) |count| {
            const pane_extent = scrollingPaneExtent(viewport_extent, gap, count);
            const count_f: f32 = @floatFromInt(count);
            try std.testing.expectApproxEqAbs(viewport_extent, pane_extent * count_f + gap * (count_f - 1.0), 0.001);
        }
    }
}

test "scrolling viewport margins require multiple displayed groups" {
    const rect: palette.Rect = .{ .x = 10.0, .y = 20.0, .w = 1000.0, .h = 700.0 };

    try std.testing.expectEqual(rect, scrollingViewportRect(rect, 12.0, 1, 2));
    try std.testing.expectEqual(rect, scrollingViewportRect(rect, 12.0, 2, 1));
    try std.testing.expectEqual(@as(f32, 1000.0), scrollingViewportExtent(rect.w, 12.0, 1, 2));

    const inset = scrollingViewportRect(rect, 12.0, 2, 2);
    try std.testing.expectEqual(@as(f32, 22.0), inset.x);
    try std.testing.expectEqual(@as(f32, 32.0), inset.y);
    try std.testing.expectEqual(@as(f32, 976.0), inset.w);
    try std.testing.expectEqual(@as(f32, 676.0), inset.h);
    try std.testing.expectEqual(@as(f32, 976.0), scrollingViewportExtent(rect.w, 12.0, 2, 2));
}

test "custom scrolling pane extent follows viewport changes" {
    const gap: f32 = 12.0;
    try std.testing.expectApproxEqAbs(
        @as(f32, 994.0),
        responsiveScrollingPaneExtent(2000.0, gap, 2, 1200.0, null, 1.0),
        0.0001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 994.0),
        responsiveScrollingPaneExtent(2000.0, gap, 2, 994.0, 0.5, 1.0),
        0.0001,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, 494.0),
        responsiveScrollingPaneExtent(1000.0, gap, 2, 994.0, 0.5, 1.0),
        0.0001,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), scrollingPaneExtentRatio(994.0, 2000.0, gap), 0.0001);
}

test "pane resize cursor follows the divider axis" {
    try std.testing.expectEqual(sdl.SystemCursor.ew_resize, resizeSystemCursor(.vertical));
    try std.testing.expectEqual(sdl.SystemCursor.ns_resize, resizeSystemCursor(.horizontal));
}

test "scrolling range keeps the final pane available at the leading edge" {
    const pane_extent: f32 = 500.0;
    const gap: f32 = 12.0;
    const pane_count: usize = 4;
    try std.testing.expectApproxEqAbs(@as(f32, 1676.0), scrollingMaxOffset(360.0, pane_extent, gap, pane_count), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1536.0), scrollingMaxOffset(900.0, pane_extent, gap, pane_count), 0.0001);

    var offset: f32 = 1600.0;
    var target: f32 = 1676.0;
    clampScrollingOffsets(&offset, &target, scrollingMaxOffset(900.0, pane_extent, gap, pane_count));
    try std.testing.expectApproxEqAbs(@as(f32, 1536.0), offset, 0.0001);
    try std.testing.expectApproxEqAbs(offset, target, 0.0001);

    clampScrollingOffsets(&offset, &target, scrollingMaxOffset(900.0, pane_extent, gap, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 512.0), offset, 0.0001);
    try std.testing.expectApproxEqAbs(offset, target, 0.0001);
}

test "direct pane reveal anchors its leading edge" {
    const pane_extent: f32 = 500.0;
    const gap: f32 = 12.0;
    const max_offset = scrollingMaxOffset(1000.0, pane_extent, gap, 4);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), leadingScrollTarget(pane_extent, gap, 0, max_offset), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1024.0), leadingScrollTarget(pane_extent, gap, 2, max_offset), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1536.0), leadingScrollTarget(pane_extent, gap, 3, max_offset), 0.0001);
}

test "scrolling column drag resizes only the grabbed pane" {
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), scrollingPaneExtentFromTrailingDrag(500.0, 0.0, 0.0, 1.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), scrollingPaneExtentFromTrailingDrag(1012.0, 0.0, 512.0, 1.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), scrollingPaneExtentFromTrailingDrag(812.0, 200.0, 512.0, 1.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), scrollingPaneExtentFromTrailingDrag(1000.0, 0.0, 0.0, 2.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), scrollingPaneExtentFromTrailingDrag(625.0, 0.0, 0.0, 1.25), 0.0001);
    // A wider preceding pane must not be folded into a shared strip width.
    try std.testing.expectApproxEqAbs(@as(f32, 420.0), scrollingPaneExtentFromTrailingDrag(1132.0, 0.0, 712.0, 1.0), 0.0001);
}

test "scrolling column leading drag keeps the trailing edge fixed" {
    try std.testing.expectApproxEqAbs(@as(f32, 600.0), scrollingPaneExtentFromLeadingDrag(412.0, 0.0, 512.0, 500.0, 1.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 400.0), scrollingPaneExtentFromLeadingDrag(612.0, 0.0, 512.0, 500.0, 1.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), scrollingScrollAfterLeadingResize(0.0, 500.0, 600.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), scrollingScrollAfterLeadingResize(180.0, 500.0, 400.0), 0.0001);
}

test "variable scrolling extents keep a uniform strip equivalent" {
    const extents = [_]f32{ 500.0, 500.0, 500.0, 500.0 };
    try std.testing.expectApproxEqAbs(scrollingMaxOffset(360.0, 500.0, 12.0, 4), scrollingStripMaxOffset(360.0, &extents, 12.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1024.0), scrollingPaneOrigin(&extents, 12.0, 2), 0.0001);
    const mixed = [_]f32{ 700.0, 400.0, 500.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1112.0), scrollingPaneOrigin(&mixed, 12.0, 2), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1112.0), leadingScrollTargetForPane(&mixed, 12.0, 2, 2000.0), 0.0001);
}

test "scrolling strip collects a tiled group as one item" {
    const allocator = std.testing.allocator;
    var layout = try runtime.WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const tiled_pane_id = try layout.createTerminalPane(allocator, 10);
    try layout.splitPaneWithLeaf(allocator, 1, tiled_pane_id, .vertical, true);
    try std.testing.expect(layout.joinPaneToScrollGroup(1, tiled_pane_id));
    const standalone_pane_id = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, tiled_pane_id, standalone_pane_id, .vertical, true);
    try std.testing.expect(layout.setPaneScrollExtent(tiled_pane_id, 640.0, 0.5));

    var group_ids: [MAX_WORKSPACE_PANE_RECTS]runtime.WorkspacePaneId = undefined;
    var representative_ids: [MAX_WORKSPACE_PANE_RECTS]runtime.WorkspacePaneId = undefined;
    const count = collectScrollingGroups(&layout, &group_ids, &representative_ids);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(runtime.WorkspacePaneId, 1), group_ids[0]);
    try std.testing.expectEqual(standalone_pane_id, group_ids[1]);
    try std.testing.expectEqual(@as(runtime.WorkspacePaneId, 1), representative_ids[0]);

    var extents: [MAX_WORKSPACE_PANE_RECTS]f32 = undefined;
    resolveScrollingGroupExtents(&layout, group_ids[0..count], representative_ids[0..count], 500.0, 1292.0, 12.0, 1.0, extents[0..count]);
    try std.testing.expectApproxEqAbs(@as(f32, 1292.0), extents[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), extents[1], 0.0001);

    // A nested tile always fills the viewport, while standalone panes keep
    // their ordinary custom widths.
    try std.testing.expect(layout.setPaneScrollExtent(standalone_pane_id, 400.0, 0.4));
    resolveScrollingGroupExtents(&layout, group_ids[0..count], representative_ids[0..count], 900.0, 900.0, 12.0, 1.0, extents[0..count]);
    try std.testing.expectApproxEqAbs(@as(f32, 900.0), extents[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 352.8), extents[1], 0.0001);

    try std.testing.expectEqual(@as(?usize, 0), scrollGroupIndexForPane(&layout, tiled_pane_id));
    try std.testing.expectEqual(@as(?usize, 1), scrollGroupIndexForPane(&layout, standalone_pane_id));

    // Closing one child returns the survivor to its ordinary scrolling width.
    try std.testing.expect(layout.setPaneScrollExtent(1, 640.0, 0.5));
    _ = layout.closePane(allocator, tiled_pane_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), layout.scrollGroupPaneCount(1));
    try std.testing.expectEqual(@as(?runtime.WorkspacePaneId, 1), layout.paneById(1).?.scroll_group_id);
    const collapsed_count = collectScrollingGroups(&layout, &group_ids, &representative_ids);
    resolveScrollingGroupExtents(&layout, group_ids[0..collapsed_count], representative_ids[0..collapsed_count], 900.0, 900.0, 12.0, 1.0, extents[0..collapsed_count]);
    try std.testing.expectApproxEqAbs(@as(f32, 444.0), extents[0], 0.0001);
}

test "scrolling grow keys follow the strip axis" {
    try std.testing.expectEqual(@as(?f32, GROW_SCROLL_PANE_STEP_CSS), scrollingGrowDeltaCss(.horizontal, .right));
    try std.testing.expectEqual(@as(?f32, -GROW_SCROLL_PANE_STEP_CSS), scrollingGrowDeltaCss(.horizontal, .left));
    try std.testing.expect(scrollingGrowDeltaCss(.horizontal, .up) == null);
    try std.testing.expect(scrollingGrowDeltaCss(.horizontal, .down) == null);
    try std.testing.expectEqual(@as(?f32, GROW_SCROLL_PANE_STEP_CSS), scrollingGrowDeltaCss(.vertical, .down));
    try std.testing.expectEqual(@as(?f32, -GROW_SCROLL_PANE_STEP_CSS), scrollingGrowDeltaCss(.vertical, .up));
    try std.testing.expect(scrollingGrowDeltaCss(.vertical, .left) == null);
    try std.testing.expect(scrollingGrowDeltaCss(.vertical, .right) == null);
}

test "scrolling grow step clamps to pane extent limits" {
    try std.testing.expectApproxEqAbs(@as(f32, 596.0), scrollingPaneExtentAfterGrow(500.0, GROW_SCROLL_PANE_STEP_CSS), 0.0001);
    try std.testing.expectApproxEqAbs(workspace_layout.MIN_SCROLL_PANE_EXTENT_CSS, scrollingPaneExtentAfterGrow(240.0, -GROW_SCROLL_PANE_STEP_CSS), 0.0001);
    try std.testing.expectApproxEqAbs(workspace_layout.MAX_SCROLL_PANE_EXTENT_CSS, scrollingPaneExtentAfterGrow(1550.0, GROW_SCROLL_PANE_STEP_CSS), 0.0001);
}

test "scrolling grow resizes only the focused pane" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try storage_mod.Storage.initWithPrefPath(allocator, path_buf[0..path_len]);
    defer storage.deinit();
    var state = try runtime.AppState.init(allocator, &storage, app_config.AppConfig{}, .{
        .gl_texture_uploads_enabled = false,
        .browser_textures_enabled = false,
    });
    defer {
        state.lifecycle.clearDirty();
        state.deinit();
    }

    for (state.project_controller.projects.items) |*project| project.deinit(allocator);
    state.project_controller.projects.clearRetainingCapacity();
    state.lifecycle.clearDirty();

    var project = try runtime.Project.init(allocator, "grow-scroll", "Grow scroll", "/tmp/grow-scroll", 0);
    const first_pane_id = project.workspace_layout.focused_pane_id.?;
    const second_thread = try project.addThread(allocator);
    const second_pane_id = try project.workspace_layout.createChatPane(allocator, second_thread);
    try project.workspace_layout.splitPaneWithLeaf(allocator, first_pane_id, second_pane_id, .vertical, true);
    project.workspace_layout.focused_pane_id = first_pane_id;
    project.workspace_layout.scroll_mode_override = .always;
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    state.project_controller.selected_index = 0;
    state.app_config.workspace_scroll_mode = .always;
    state.app_config.workspace_scroll_direction = .horizontal;
    last_workspace_rect = .{ .x = 0.0, .y = 0.0, .w = 1200.0, .h = 800.0 };

    try std.testing.expect(growPaneInDirection(&state, .right));
    try std.testing.expect(!growPaneInDirection(&state, .up));
    const layout = &state.project_controller.projects.items[0].workspace_layout;
    const first = layout.paneById(first_pane_id) orelse return error.TestExpectedEqual;
    const second = layout.paneById(second_pane_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(first.scroll_extent_css != null);
    try std.testing.expectEqual(@as(?f32, null), second.scroll_extent_css);
    const grown = first.scroll_extent_css.?;
    try std.testing.expect(grown > workspace_layout.MIN_SCROLL_PANE_EXTENT_CSS);
    try std.testing.expect(growPaneInDirection(&state, .left));
    try std.testing.expectApproxEqAbs(grown - GROW_SCROLL_PANE_STEP_CSS, layout.paneById(first_pane_id).?.scroll_extent_css.?, 1.0);
    try std.testing.expectEqual(@as(?f32, null), layout.paneById(second_pane_id).?.scroll_extent_css);
}

test "scrolling layout policy supports automatic always and disabled modes" {
    try std.testing.expect(!scrollingLayoutEnabled(.automatic, 4, 3, false));
    try std.testing.expect(scrollingLayoutEnabled(.automatic, 4, 4, false));
    try std.testing.expect(scrollingLayoutEnabled(.always, 64, 1, false));
    try std.testing.expect(!scrollingLayoutEnabled(.disabled, 1, 8, false));
    try std.testing.expect(!scrollingLayoutEnabled(.always, 1, 0, false));
    try std.testing.expect(!scrollingLayoutEnabled(.always, 1, 4, true));
}

test "scrolling layout automatic mode covers configured threshold matrix" {
    const thresholds = [_]u8{ 1, 2, 4, 8 };
    for (thresholds) |threshold| {
        if (threshold > 1) {
            try std.testing.expect(!scrollingLayoutEnabled(.automatic, threshold, @as(usize, threshold - 1), false));
        }
        try std.testing.expect(scrollingLayoutEnabled(.automatic, threshold, @as(usize, threshold), false));
        try std.testing.expect(scrollingLayoutEnabled(.automatic, threshold, @as(usize, threshold) + 1, false));
    }
    try std.testing.expect(!scrollingLayoutEnabled(.disabled, 1, 64, false));
}

test "automatic scrolling activation follows tiled pane creation and closure" {
    const allocator = std.testing.allocator;
    var layout = try runtime.WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    try std.testing.expect(!scrollingLayoutEnabled(.automatic, 2, layout.visiblePaneCount(), false));

    const second_pane_id = try layout.createTerminalPane(allocator, 10);
    try layout.splitPaneWithLeaf(allocator, 1, second_pane_id, .vertical, true);
    try std.testing.expect(scrollingLayoutEnabled(.automatic, 2, layout.visiblePaneCount(), false));

    const third_pane_id = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, second_pane_id, third_pane_id, .horizontal, true);
    try std.testing.expect(scrollingLayoutEnabled(.automatic, 2, layout.visiblePaneCount(), false));

    var removed_ref = layout.closePane(allocator, third_pane_id) orelse return error.TestExpectedEqual;
    workspace_layout.deinitWorkspacePaneRef(&removed_ref, allocator);
    try std.testing.expect(scrollingLayoutEnabled(.automatic, 2, layout.visiblePaneCount(), false));

    removed_ref = layout.closePane(allocator, second_pane_id) orelse return error.TestExpectedEqual;
    workspace_layout.deinitWorkspacePaneRef(&removed_ref, allocator);
    try std.testing.expect(!scrollingLayoutEnabled(.automatic, 2, layout.visiblePaneCount(), false));
}

test "scrolling focus direction follows the configured axis" {
    try std.testing.expectEqual(runtime.WorkspacePaneDirection.left, scrollingPaneDirection(.horizontal, .left).?);
    try std.testing.expectEqual(runtime.WorkspacePaneDirection.right, scrollingPaneDirection(.horizontal, .right).?);
    try std.testing.expect(scrollingPaneDirection(.horizontal, .down) == null);
    try std.testing.expectEqual(runtime.WorkspacePaneDirection.up, scrollingPaneDirection(.vertical, .up).?);
    try std.testing.expectEqual(runtime.WorkspacePaneDirection.down, scrollingPaneDirection(.vertical, .down).?);
    try std.testing.expect(scrollingPaneDirection(.vertical, .right) == null);
}

test "scrolling edge navigation only exposes adjacent sidebar panes" {
    const missing = scrollingEdgeAvailability(null, 4);
    try std.testing.expect(!missing.previous);
    try std.testing.expect(!missing.next);

    const first = scrollingEdgeAvailability(0, 4);
    try std.testing.expect(!first.previous);
    try std.testing.expect(first.next);

    const middle = scrollingEdgeAvailability(2, 4);
    try std.testing.expect(middle.previous);
    try std.testing.expect(middle.next);

    const last = scrollingEdgeAvailability(3, 4);
    try std.testing.expect(last.previous);
    try std.testing.expect(!last.next);
}

test "scrolling edge navigation geometry follows the configured axis" {
    const workspace: palette.Rect = .{ .x = 10.0, .y = 20.0, .w = 400.0, .h = 200.0 };
    const left = scrollingEdgeRects(workspace, .horizontal, .previous, 32.0, 64.0, 6.0, 14.0);
    const right = scrollingEdgeRects(workspace, .horizontal, .next, 32.0, 64.0, 6.0, 14.0);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), left.button.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 88.0), left.button.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 372.0), right.button.x, 0.0001);
    try std.testing.expect(rectContains(left.proximity, left.button.x, left.button.y));
    try std.testing.expect(!rectContains(left.proximity, workspace.x + workspace.w * 0.5, workspace.y + workspace.h * 0.5));

    const top = scrollingEdgeRects(workspace, .vertical, .previous, 32.0, 64.0, 6.0, 14.0);
    const bottom = scrollingEdgeRects(workspace, .vertical, .next, 32.0, 64.0, 6.0, 14.0);
    try std.testing.expectApproxEqAbs(@as(f32, 178.0), top.button.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 26.0), top.button.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 182.0), bottom.button.y, 0.0001);
}

test "scrolling wheel routing preserves ordinary vertical pane scrolling" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), scrollingWheelDelta(.horizontal, 2.0, 0.5, false).?, 0.0001);
    try std.testing.expect(scrollingWheelDelta(.horizontal, 0.2, 1.0, false) == null);
    try std.testing.expect(scrollingWheelDelta(.vertical, 0.0, -2.0, false) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), scrollingWheelDelta(.vertical, 0.0, -2.0, true).?, 0.0001);
}

test "manual scrolling settles partial positions to the nearest pane" {
    const extents = [_]f32{ 500.0, 360.0, 640.0 };
    const target = freeScrollTarget(0.0, 4.5, SCROLLING_WHEEL_STEP_CSS, 884.0);
    try std.testing.expectApproxEqAbs(@as(f32, 324.0), target, 0.0001);
    try std.testing.expect(scrollSnapTargetAfterIdle(120, 119, target, &extents, 12.0, 884.0) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 512.0), scrollSnapTargetAfterIdle(120, 120, target, &extents, 12.0, 884.0).?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), nearestPaneScrollTarget(200.0, &extents, 12.0, 884.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 884.0), nearestPaneScrollTarget(800.0, &extents, 12.0, 884.0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1200.0), freeScrollTarget(1190.0, 1.0, SCROLLING_WHEEL_STEP_CSS, 1200.0), 0.0001);
}

test "scrolling animation advances without overshooting" {
    const partial = advanceScrollOffset(0.0, 300.0, 16);
    try std.testing.expect(partial > 0.0);
    try std.testing.expect(partial < 300.0);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), advanceScrollOffset(0.0, 300.0, SCROLLING_ANIMATION_DURATION_MS), 0.0001);
}

test "scrolling clip intersection stays inside the workspace" {
    const workspace: palette.Rect = .{ .x = 200.0, .y = 10.0, .w = 800.0, .h = 600.0 };
    const clipped = intersectRects(.{ .x = 120.0, .y = 0.0, .w = 500.0, .h = 640.0 }, workspace) orelse return error.TestExpectedEqual;
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), clipped.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 420.0), clipped.w, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 600.0), clipped.h, 0.0001);
    try std.testing.expect(intersectRects(.{ .x = 0.0, .y = 0.0, .w = 100.0, .h = 100.0 }, workspace) == null);
}
