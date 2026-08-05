//! Workspace pane composition.
//!
//! This starts as a compatibility wrapper around the existing chat workspace.
//! The pane model lives in state so later slices can add terminal leaves without
//! changing the root UI entry point again.

const std = @import("std");

const palette = @import("palette");
const sdl = @import("zsdl3");

const runtime = @import("runtime.zig");
const browser_panel = @import("browser.zig");
const chat_panel = @import("chat_panel.zig");
const colors = @import("colors.zig");
const profiler = @import("../runtime/profiler.zig");
const terminal_panel = @import("terminal_panel.zig");
const theme = @import("theme.zig");

const FOCUS_ANIM_DURATION_MS: i64 = 160;
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
const SCROLLING_LAYOUT_PANE_THRESHOLD: usize = 2;
const SCROLLING_WHEEL_STEP_CSS: f32 = 72.0;
const SCROLLING_ANIMATION_DURATION_MS: i64 = 150;
const SCROLLING_ANIMATION_MAX_STEP_MS: i64 = 50;
const SCROLLING_ANIMATION_EPSILON: f32 = 0.5;

// Font Awesome glyphs bundled in SymbolsNerdFontMono and rendered with Palette's icon role.
const NF_FA_EXPAND = "\u{F065}";
const NF_FA_COMPRESS = "\u{F066}";

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
    move_quick_pane,
    resize_quick_pane,
};

const WorkspacePaneHit = struct {
    pane_id: runtime.WorkspacePaneId = 0,
    sibling_pane_id: runtime.WorkspacePaneId = 0,
    action: WorkspacePaneAction = .focus,
    axis: runtime.WorkspaceSplitAxis = .horizontal,
    rect: palette.Rect = .{},
    split_rect: palette.Rect = .{},
};

const WorkspacePaneHitCache = struct {
    count: usize = 0,
    hits: [MAX_WORKSPACE_PANE_HITS]WorkspacePaneHit = [_]WorkspacePaneHit{.{}} ** MAX_WORKSPACE_PANE_HITS,
};

var hit_cache: WorkspacePaneHitCache = .{};
var resize_drag: ?WorkspacePaneHit = null;
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
var scrolling_max_offset_x: f32 = 0.0;
var scrolling_animating: bool = false;

var focus_prev_id: ?runtime.WorkspacePaneId = null;
var focus_curr_id: ?runtime.WorkspacePaneId = null;
var focus_anim_start_ms: i64 = std.math.minInt(i64) >> 2;

pub fn isFocusAnimating() bool {
    return (nowMs() - focus_anim_start_ms) < FOCUS_ANIM_DURATION_MS;
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

pub fn hasActivePaneDrag() bool {
    return pane_drag.pending or pane_drag.active;
}

pub fn handlePaletteWheel(state: *runtime.AppState, x: f32, y: f32, wheel_x: f32, wheel_y: f32) bool {
    if (!scrolling_layout_rendered or @abs(wheel_x) < 0.01 or @abs(wheel_x) < @abs(wheel_y)) return false;
    if (!rectContains(last_workspace_rect, x, y)) return false;
    if (state.project_controller.projects.items.len == 0) return false;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    if (!scrollingLayoutActive(layout)) return false;

    const next_target = std.math.clamp(
        layout.scroll_target_x + wheel_x * theme.scaledUi(SCROLLING_WHEEL_STEP_CSS),
        0.0,
        scrolling_max_offset_x,
    );
    if (@abs(next_target - layout.scroll_target_x) > 0.001) {
        layout.scroll_target_x = next_target;
        layout.scroll_animation_last_ms = nowMs();
        state.markDirty();
    }
    layout.scroll_revealed_pane_id = layout.focused_pane_id;
    return true;
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

pub fn focusPaneInDirection(state: *runtime.AppState, dir: FocusDirection) bool {
    if (pane_rect_count == 0) return false;
    if (state.project_controller.projects.items.len == 0) return false;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    const current_id = layout.focused_pane_id orelse return false;
    const maximized = state.currentProjectWorkspaceMaximizedPaneId() != null;
    if (maximized) {
        if (state.currentProjectWorkspaceRoot()) |root| {
            var expanded_rects: [MAX_WORKSPACE_PANE_RECTS]WorkspacePaneRect = undefined;
            var expanded_count: usize = 0;
            collectNodePaneRects(root, pane_rects[0].rect, &expanded_rects, &expanded_count);
            if (focusPaneInDirectionFromRects(state, current_id, dir, expanded_rects[0..expanded_count], true)) return true;
        }
        return state.clearCurrentProjectWorkspacePaneMaximized();
    }

    if (scrollingLayoutActive(layout)) {
        const direction: runtime.WorkspacePaneDirection = switch (dir) {
            .left => .left,
            .right => .right,
            .up, .down => return false,
        };
        const target = layout.adjacentTiledPaneIdInSidebarOrder(current_id, direction) orelse return false;
        return state.focusCurrentProjectWorkspacePane(target);
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
    clear_maximized: bool,
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
    if (clear_maximized) _ = state.clearCurrentProjectWorkspacePaneMaximized();
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
    if (pane_rect_count == 0) return false;
    if (state.project_controller.projects.items.len == 0) return false;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    if (scrollingLayoutActive(layout)) return false;
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

pub fn movePaneInDirection(state: *runtime.AppState, dir: FocusDirection) bool {
    if (pane_rect_count == 0) return false;
    if (state.project_controller.projects.items.len == 0) return false;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    const current_id = layout.focused_pane_id orelse return false;

    if (scrollingLayoutActive(layout)) {
        const direction: runtime.WorkspacePaneDirection = switch (dir) {
            .left => .left,
            .right => .right,
            .up, .down => return false,
        };
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

fn easeOutCubic(t: f32) f32 {
    const inv = 1.0 - t;
    return 1.0 - inv * inv * inv;
}

fn focusBorderAlpha(pane_id: runtime.WorkspacePaneId) f32 {
    const elapsed = nowMs() - focus_anim_start_ms;
    const t = if (elapsed >= FOCUS_ANIM_DURATION_MS)
        @as(f32, 1.0)
    else if (elapsed <= 0)
        @as(f32, 0.0)
    else
        @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(FOCUS_ANIM_DURATION_MS));
    const ease = easeOutCubic(t);
    if (focus_curr_id) |id| if (id == pane_id) return ease;
    if (focus_prev_id) |id| if (id == pane_id) return 1.0 - ease;
    return 0.0;
}

pub fn renderAt(state: *runtime.AppState, rect: palette.Rect) void {
    last_workspace_rect = rect;
    state.ensureCurrentProjectWorkspace();
    state.terminal_controller.debug_workspace_visible_pane_count = state.currentProjectWorkspaceVisiblePaneCount();
    tickFocusAnimation(state);
    pane_status_animating = false;
    scrolling_layout_rendered = false;
    scrolling_max_offset_x = 0.0;
    scrolling_animating = false;
    hit_cache.count = 0;
    pane_rect_count = 0;
    browser_pane_rendered = false;
    chat_panel.resetWorkspaceHeaderHitCache();
    chat_panel.resetTranscriptHitCache();
    terminal_panel.resetHitCache();

    if (state.currentProjectWorkspaceMaximizedPaneId()) |pane_id| {
        renderLeaf(state, pane_id, rect);
    } else if (state.currentProjectWorkspaceRoot()) |root| {
        const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
        if (scrollingLayoutActive(layout)) {
            renderScrollingColumns(state, layout, rect);
        } else {
            renderNode(state, root, rect);
        }
    } else {
        chat_panel.renderWorkspaceAt(state, rect);
    }

    renderQuickPane(state, rect);
    renderSplitMenuOverlay(state, rect);
    if (!browser_pane_rendered) state.noteBrowserPaneNotRendered();
}

// Floating quick-pane overlay above the unchanged tiled workspace.
fn renderQuickPane(state: *runtime.AppState, workspace_rect: palette.Rect) void {
    const quick = state.currentProjectQuickPane() orelse return;
    if (!quick.visible) return;
    if (!quick.pinned) {
        queueRect(state, workspace_rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL, 92)));
    }
    const rect = quickPaneRect(quick, workspace_rect);
    queueRect(state, .{
        .x = rect.x - theme.scaledUi(2.0),
        .y = rect.y - theme.scaledUi(2.0),
        .w = rect.w + theme.scaledUi(4.0),
        .h = rect.h + theme.scaledUi(4.0),
    }, paletteColor(theme.withAlpha(theme.COLOR_PANEL, 210)));
    renderLeaf(state, quick.pane_id, rect);

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
                if (state.project_controller.projects.items.len > 0) state.createThreadForProject(state.project_controller.selected_index);
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
            .resize_split => {
                resize_drag = hit;
                updateResizeDrag(state, hit, x, y);
            },
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

/// True when the mouse rests on interactive workspace pane chrome.
pub fn wantsPointerAt(x: f32, y: f32) bool {
    var i: usize = hit_cache.count;
    while (i > 0) {
        i -= 1;
        const hit = hit_cache.hits[i];
        if (!rectContains(hit.rect, x, y)) continue;
        return switch (hit.action) {
            .focus, .resize_split => false,
            else => true,
        };
    }
    return false;
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

fn scrollingLayoutActive(layout: *const runtime.WorkspaceLayout) bool {
    return layout.maximized_pane_id == null and layout.visiblePaneCount() >= SCROLLING_LAYOUT_PANE_THRESHOLD;
}

// Horizontally scrolling workspace strip with focus-aware reveal and clipping.
fn renderScrollingColumns(
    state: *runtime.AppState,
    layout: *runtime.WorkspaceLayout,
    workspace: palette.Rect,
) void {
    const gap = theme.scaledUi(state.app_config.workspace_pane_gap);
    const column_w = scrollingColumnWidth(workspace.w, gap, state.app_config.workspace_panes_per_view);
    const pane_count = layout.visiblePaneCount();
    const total_w = column_w * @as(f32, @floatFromInt(pane_count)) + gap * @as(f32, @floatFromInt(pane_count - 1));
    const max_offset = @max(0.0, total_w - workspace.w);
    clampScrollingOffsets(layout, max_offset);

    if (layout.focused_pane_id) |focused_id| {
        if (layout.rootContainsPane(focused_id) and layout.scroll_revealed_pane_id != focused_id) {
            if (paneIndexInSidebarOrder(layout, focused_id)) |focused_index| {
                const next_target = revealedScrollTarget(
                    layout.scroll_target_x,
                    workspace.w,
                    column_w,
                    gap,
                    focused_index,
                    max_offset,
                );
                setScrollingTarget(state, layout, next_target);
            }
            layout.scroll_revealed_pane_id = focused_id;
        }
    }

    tickScrollingAnimation(layout);
    scrolling_layout_rendered = true;
    scrolling_max_offset_x = max_offset;

    const command_start = state.palette_overlay_batch.commands.items.len;
    const text_run_start = state.palette_overlay_batch.text_runs.items.len;
    var pane_index: usize = 0;
    for (layout.panes.items) |pane| {
        if (!layout.rootContainsPane(pane.id)) continue;
        renderScrollingPane(state, pane.id, workspace, column_w, gap, layout.scroll_offset_x, pane_index);
        pane_index += 1;
    }
    clipWorkspaceBatch(state, command_start, text_run_start, workspace);
    clipWorkspaceHitCaches(workspace);
}

fn renderScrollingPane(
    state: *runtime.AppState,
    pane_id: runtime.WorkspacePaneId,
    workspace: palette.Rect,
    column_w: f32,
    gap: f32,
    offset_x: f32,
    pane_index: usize,
) void {
    const step = column_w + gap;
    const rect: palette.Rect = .{
        .x = workspace.x + @as(f32, @floatFromInt(pane_index)) * step - offset_x,
        .y = workspace.y,
        .w = column_w,
        .h = workspace.h,
    };
    if (rect.x + rect.w <= workspace.x or rect.x >= workspace.x + workspace.w) return;
    renderLeaf(state, pane_id, rect);
    const gutter_x = rect.x + rect.w;
    if (gutter_x < workspace.x + workspace.w and gutter_x + gap > workspace.x) {
        queueRect(state, .{
            .x = gutter_x,
            .y = workspace.y,
            .w = gap,
            .h = workspace.h,
        }, paletteColor(theme.background()));
    }
}

fn paneIndexInSidebarOrder(layout: *const runtime.WorkspaceLayout, pane_id: runtime.WorkspacePaneId) ?usize {
    var tiled_index: usize = 0;
    for (layout.panes.items) |pane| {
        if (!layout.rootContainsPane(pane.id)) continue;
        if (pane.id == pane_id) return tiled_index;
        tiled_index += 1;
    }
    return null;
}

fn scrollingColumnWidth(viewport_w: f32, gap: f32, panes_per_view: u8) f32 {
    const count: f32 = @floatFromInt(@max(panes_per_view, 1));
    return @max((viewport_w - gap * (count - 1.0)) / count, 1.0);
}

fn revealedScrollTarget(current: f32, viewport_w: f32, column_w: f32, gap: f32, pane_index: usize, max_offset: f32) f32 {
    const column_left = @as(f32, @floatFromInt(pane_index)) * (column_w + gap);
    const column_right = column_left + column_w;
    var target = current;
    if (column_left < current) {
        target = column_left;
    } else if (column_right > current + viewport_w) {
        target = column_right - viewport_w;
    }
    return std.math.clamp(target, 0.0, max_offset);
}

fn setScrollingTarget(state: *runtime.AppState, layout: *runtime.WorkspaceLayout, target: f32) void {
    if (@abs(target - layout.scroll_target_x) <= 0.001) return;
    layout.scroll_target_x = target;
    layout.scroll_animation_last_ms = nowMs();
    state.markDirty();
}

fn clampScrollingOffsets(layout: *runtime.WorkspaceLayout, max_offset: f32) void {
    layout.scroll_target_x = std.math.clamp(layout.scroll_target_x, 0.0, max_offset);
    layout.scroll_offset_x = std.math.clamp(layout.scroll_offset_x, 0.0, max_offset);
}

fn tickScrollingAnimation(layout: *runtime.WorkspaceLayout) void {
    const timestamp = nowMs();
    if (layout.scroll_animation_last_ms == 0) layout.scroll_animation_last_ms = timestamp;
    const elapsed_ms = std.math.clamp(timestamp - layout.scroll_animation_last_ms, 0, SCROLLING_ANIMATION_MAX_STEP_MS);
    layout.scroll_animation_last_ms = timestamp;
    layout.scroll_offset_x = advanceScrollOffset(layout.scroll_offset_x, layout.scroll_target_x, elapsed_ms);
    if (@abs(layout.scroll_target_x - layout.scroll_offset_x) <= SCROLLING_ANIMATION_EPSILON) {
        layout.scroll_offset_x = layout.scroll_target_x;
    } else {
        scrolling_animating = true;
    }
}

fn advanceScrollOffset(current: f32, target: f32, elapsed_ms: i64) f32 {
    if (elapsed_ms <= 0 or @abs(target - current) <= SCROLLING_ANIMATION_EPSILON) return current;
    const progress = @min(1.0, @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(SCROLLING_ANIMATION_DURATION_MS)));
    return current + (target - current) * easeOutCubic(progress);
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

fn renderNode(state: *runtime.AppState, node: *const runtime.WorkspaceNode, rect: palette.Rect) void {
    switch (node.*) {
        .leaf => |pane_id| renderLeaf(state, pane_id, rect),
        .split => |split| {
            const gap = theme.scaledUi(1.0);
            if (split.axis == .vertical) {
                const first_w = @max(theme.scaledUi(180.0), rect.w * split.ratio - gap * 0.5);
                const second_w = @max(theme.scaledUi(180.0), rect.w - first_w - gap);
                const clamped_first_w = @max(theme.scaledUi(120.0), rect.w - second_w - gap);
                const first_rect = palette.Rect{ .x = rect.x, .y = rect.y, .w = clamped_first_w, .h = rect.h };
                const gutter_rect = palette.Rect{ .x = rect.x + clamped_first_w, .y = rect.y, .w = gap, .h = rect.h };
                const second_rect = palette.Rect{ .x = rect.x + clamped_first_w + gap, .y = rect.y, .w = @max(rect.w - clamped_first_w - gap, theme.scaledUi(120.0)), .h = rect.h };
                renderNode(state, split.first, first_rect);
                renderSplitGutter(state, split.first, split.second, .vertical, gutter_rect, rect);
                renderNode(state, split.second, second_rect);
            } else {
                const first_h = @max(theme.scaledUi(160.0), rect.h * split.ratio - gap * 0.5);
                const second_h = @max(theme.scaledUi(120.0), rect.h - first_h - gap);
                const clamped_first_h = @max(theme.scaledUi(120.0), rect.h - second_h - gap);
                const first_rect = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = clamped_first_h };
                const gutter_rect = palette.Rect{ .x = rect.x, .y = rect.y + clamped_first_h, .w = rect.w, .h = gap };
                const second_rect = palette.Rect{ .x = rect.x, .y = rect.y + clamped_first_h + gap, .w = rect.w, .h = @max(rect.h - clamped_first_h - gap, theme.scaledUi(120.0)) };
                renderNode(state, split.first, first_rect);
                renderSplitGutter(state, split.first, split.second, .horizontal, gutter_rect, rect);
                renderNode(state, split.second, second_rect);
            }
        },
    }
}

fn renderSplitGutter(state: *runtime.AppState, first: *const runtime.WorkspaceNode, second: *const runtime.WorkspaceNode, axis: runtime.WorkspaceSplitAxis, rect: palette.Rect, split_rect: palette.Rect) void {
    queueRect(state, rect, paletteColor(theme.COLOR_PANEL_MUTED));
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
    const ratio = if (hit.axis == .vertical)
        (x - hit.split_rect.x) / @max(hit.split_rect.w, 1.0)
    else
        (y - hit.split_rect.y) / @max(hit.split_rect.h, 1.0);
    state.resizeCurrentProjectWorkspaceSplit(hit.pane_id, hit.sibling_pane_id, hit.axis, ratio);
}

fn renderLeaf(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, rect: palette.Rect) void {
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
        .chat => chat_panel.renderWorkspaceAtForPaneWithReserve(state, rect, pane_id, reserve),
        .terminal => {
            const dock_id = state.workspaceTerminalDockIdByPane(pane_id) orelse 0;
            terminal_panel.renderDockAtForDockWithReserve(state, rect, dock_id, reserve);
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
    // Pane status frame. Live agent states intentionally override the ordinary
    // focus/unfocused and zoom colors so they remain legible in tiled and
    // maximized layouts without tinting the pane's content.
    const agent_status = paneAgentVisualStatus(state, pane_id);
    if (agent_status != .idle) {
        pane_status_animating = true;
        const pulse = paneStatusPulse(agent_status, nowMs());
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
    if (kind == .terminal and !maximized) {
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

test "scrolling column width fits the configured panes per view" {
    const viewport_w: f32 = 1000.0;
    const gap: f32 = 12.0;
    inline for (.{ @as(u8, 1), @as(u8, 2), @as(u8, 3), @as(u8, 6) }) |count| {
        const column_w = scrollingColumnWidth(viewport_w, gap, count);
        const count_f: f32 = @floatFromInt(count);
        try std.testing.expectApproxEqAbs(viewport_w, column_w * count_f + gap * (count_f - 1.0), 0.001);
    }
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
