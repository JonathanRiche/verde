//! Workspace pane composition.
//!
//! This starts as a compatibility wrapper around the existing chat workspace.
//! The pane model lives in state so later slices can add terminal leaves without
//! changing the root UI entry point again.

const std = @import("std");

const palette = @import("palette");

const runtime = @import("runtime.zig");
const chat_panel = @import("chat_panel.zig");
const colors = @import("colors.zig");
const profiler = @import("../profiler.zig");
const terminal_panel = @import("terminal_panel.zig");
const theme = @import("theme.zig");

const FOCUS_ANIM_DURATION_MS: i64 = 160;

fn nowMs() i64 {
    return @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
}

const MAX_WORKSPACE_PANE_HITS = 32;
const WorkspacePaneAction = enum {
    focus,
    maximize,
    minimize,
    restore,
    toggle_split_menu,
    split_chat_vertical,
    split_chat_horizontal,
    split_terminal_vertical,
    split_terminal_horizontal,
    close,
    resize_split,
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
var split_menu_open_for: ?runtime.WorkspacePaneId = null;
var split_menu_rect: palette.Rect = .{};
var split_menu_anchor: palette.Rect = .{};

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

var pane_rect_count: usize = 0;
var pane_rects: [MAX_WORKSPACE_PANE_RECTS]WorkspacePaneRect = undefined;

var focus_prev_id: ?runtime.WorkspacePaneId = null;
var focus_curr_id: ?runtime.WorkspacePaneId = null;
var focus_anim_start_ms: i64 = std.math.minInt(i64) >> 2;

pub fn isFocusAnimating() bool {
    return (nowMs() - focus_anim_start_ms) < FOCUS_ANIM_DURATION_MS;
}

pub const FocusDirection = enum { left, right, up, down };

pub fn focusPaneInDirection(state: *runtime.AppState, dir: FocusDirection) bool {
    if (pane_rect_count == 0) return false;
    if (state.projects.items.len == 0) return false;
    const current_id = state.projects.items[state.selected_project_index].workspace_layout.focused_pane_id orelse return false;

    var current_rect: ?palette.Rect = null;
    var i: usize = 0;
    while (i < pane_rect_count) : (i += 1) {
        if (pane_rects[i].pane_id == current_id) {
            current_rect = pane_rects[i].rect;
            break;
        }
    }
    const cur = current_rect orelse return false;
    const cx = cur.x + cur.w * 0.5;
    const cy = cur.y + cur.h * 0.5;

    var best_id: ?runtime.WorkspacePaneId = null;
    var best_score: f32 = std.math.inf(f32);

    i = 0;
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
    _ = state.focusCurrentProjectWorkspacePane(target);
    state.markDirty();
    return true;
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
    if (state.projects.items.len == 0) return false;
    const current_id = state.projects.items[state.selected_project_index].workspace_layout.focused_pane_id orelse return false;

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

fn tickFocusAnimation(state: *runtime.AppState) void {
    if (state.projects.items.len == 0) return;
    const focused = state.projects.items[state.selected_project_index].workspace_layout.focused_pane_id;
    const same = (focus_curr_id == null and focused == null) or
        (focus_curr_id != null and focused != null and focus_curr_id.? == focused.?);
    if (same) return;
    focus_prev_id = focus_curr_id;
    focus_curr_id = focused;
    focus_anim_start_ms = nowMs();
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
    state.ensureCurrentProjectWorkspace();
    state.debug_workspace_visible_pane_count = state.currentProjectWorkspaceVisiblePaneCount();
    tickFocusAnimation(state);
    hit_cache.count = 0;
    pane_rect_count = 0;
    chat_panel.resetTranscriptHitCache();
    terminal_panel.resetHitCache();

    const minimized_count = state.currentProjectWorkspaceMinimizedPaneCount();
    const restore_h = if (minimized_count > 0) theme.scaledUi(34.0) else 0.0;
    const workspace_rect = palette.Rect{
        .x = rect.x,
        .y = rect.y,
        .w = rect.w,
        .h = @max(rect.h - restore_h, 1.0),
    };

    if (state.currentProjectWorkspaceMaximizedPaneId()) |pane_id| {
        renderLeaf(state, pane_id, workspace_rect);
        renderRestoreStrip(state, .{ .x = rect.x, .y = rect.y + workspace_rect.h, .w = rect.w, .h = restore_h }, minimized_count);
        renderSplitMenuOverlay(state, workspace_rect);
        return;
    }
    if (state.currentProjectWorkspaceRoot()) |root| {
        renderNode(state, root, workspace_rect);
        renderRestoreStrip(state, .{ .x = rect.x, .y = rect.y + workspace_rect.h, .w = rect.w, .h = restore_h }, minimized_count);
        renderSplitMenuOverlay(state, workspace_rect);
        return;
    }

    chat_panel.renderWorkspaceAt(state, workspace_rect);
    renderRestoreStrip(state, .{ .x = rect.x, .y = rect.y + workspace_rect.h, .w = rect.w, .h = restore_h }, minimized_count);
    renderSplitMenuOverlay(state, workspace_rect);
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool) bool {
    if (button == 3 and down) {
        // Right-click on a pane header opens the split menu anchored at the cursor.
        var ri: usize = hit_cache.count;
        while (ri > 0) {
            ri -= 1;
            const hit = hit_cache.hits[ri];
            if (hit.action != .focus) continue;
            if (!rectContains(hit.rect, x, y)) continue;
            _ = state.focusCurrentProjectWorkspacePane(hit.pane_id);
            split_menu_open_for = hit.pane_id;
            split_menu_anchor = .{ .x = x, .y = y, .w = 0.0, .h = 0.0 };
            return true;
        }
        return false;
    }
    if (button != 1) return false;
    if (!down) {
        if (resize_drag != null) {
            resize_drag = null;
            return true;
        }
        return false;
    }
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
            .minimize => {
                _ = state.minimizeCurrentProjectWorkspacePane(hit.pane_id);
                split_menu_open_for = null;
            },
            .restore => _ = state.restoreCurrentProjectWorkspacePane(hit.pane_id),
            .toggle_split_menu => {
                _ = state.focusCurrentProjectWorkspacePane(hit.pane_id);
                if (split_menu_open_for) |id| {
                    split_menu_open_for = if (id == hit.pane_id) null else hit.pane_id;
                } else {
                    split_menu_open_for = hit.pane_id;
                }
            },
            .split_chat_vertical => {
                _ = state.splitCurrentProjectWorkspacePaneWithChatAxis(hit.pane_id, .vertical);
                split_menu_open_for = null;
            },
            .split_chat_horizontal => {
                _ = state.splitCurrentProjectWorkspacePaneWithChatAxis(hit.pane_id, .horizontal);
                split_menu_open_for = null;
            },
            .split_terminal_vertical => {
                _ = state.splitCurrentProjectWorkspacePaneWithTerminalAxis(hit.pane_id, .vertical);
                split_menu_open_for = null;
            },
            .split_terminal_horizontal => {
                _ = state.splitCurrentProjectWorkspacePaneWithTerminalAxis(hit.pane_id, .horizontal);
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
        }
        return true;
    }
    // No hit matched. If the split menu is open, dismiss on outside click;
    // absorb clicks that landed inside the menu panel but missed a cell so it stays open.
    if (split_menu_open_for != null) {
        if (rectContains(split_menu_rect, x, y)) return true;
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

pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32) bool {
    if (resize_drag) |hit| {
        updateResizeDrag(state, hit, x, y);
        return true;
    }
    // Focus-follows-mouse: hovering into a pane focuses it. Skip while a split
    // menu is open and the cursor is inside that menu so the open pane stays put.
    if (split_menu_open_for != null and rectContains(split_menu_rect, x, y)) return false;
    var i: usize = 0;
    while (i < pane_rect_count) : (i += 1) {
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

pub fn renderThreadDropPreview(state: *runtime.AppState, x: f32, y: f32) void {
    const target = threadDropTargetAt(x, y) orelse return;
    queueRounded(state, target.preview, paletteColor(colors.rgba(93, 223, 143, 54)), theme.scaledUi(6.0));
    queueBorder(state, target.preview, paletteColor(colors.rgba(93, 223, 143, 210)), theme.scaledUi(6.0), theme.scaledUi(2.0));
}

pub fn dropThreadAt(state: *runtime.AppState, thread_index: usize, x: f32, y: f32) bool {
    const target = threadDropTargetAt(x, y) orelse return false;
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
    queueRect(state, rect, paletteColor(colors.rgba(44, 51, 58, 255)));
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

const PANE_HEADER_RIGHT_RESERVE: f32 = 138.0;

fn renderLeaf(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, rect: palette.Rect) void {
    const kind = state.workspacePaneKindById(pane_id) orelse return;
    if (pane_rect_count < pane_rects.len) {
        pane_rects[pane_rect_count] = .{ .pane_id = pane_id, .rect = rect };
        pane_rect_count += 1;
    }
    const reserve = theme.scaledUi(PANE_HEADER_RIGHT_RESERVE);
    const header_h = switch (kind) {
        .chat => chat_panel.paneHeaderHeight(rect),
        .terminal => terminal_panel.paneHeaderHeight(),
    };
    switch (kind) {
        .chat => chat_panel.renderWorkspaceAtForPaneWithReserve(state, rect, pane_id, reserve),
        .terminal => {
            const dock_id = state.workspaceTerminalDockIdByPane(pane_id) orelse 0;
            terminal_panel.renderDockAtForDockWithReserve(state, rect, dock_id, reserve);
        },
    }
    if (kind == .chat and header_h > 0.0) {
        const header_rect = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = header_h };
        renderPaneOverlay(state, pane_id, header_rect, reserve);
    }
    const alpha = focusBorderAlpha(pane_id);
    if (alpha > 0.01) {
        var border_color = theme.COLOR_SECONDARY_GREEN;
        border_color[3] *= alpha;
        queueBorder(state, rect, paletteColor(border_color), 0.0, theme.scaledUi(2.0));
    }
}

fn renderPaneOverlay(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, header_rect: palette.Rect, reserve: f32) void {
    const focused = state.isCurrentProjectWorkspacePaneFocused(pane_id);
    // Focus hit covers the header area only, registered first so it sits at lowest
    // priority. Clicks on icons (registered later) take precedence; clicks on the
    // chat panel's own buttons (Open/Browser) are resolved by chat_panel before
    // this handler runs.
    appendHit(.{ .pane_id = pane_id, .action = .focus, .rect = header_rect });

    const menu_open_here = if (split_menu_open_for) |id| id == pane_id else false;
    const header_hovered = rectContains(header_rect, state.palette_mouse_x, state.palette_mouse_y);
    const mx = state.palette_mouse_x;
    const my = state.palette_mouse_y;

    // Window controls aligned to the right within the reserved strip.
    const btn_w = theme.scaledUi(22.0);
    const btn_h = theme.scaledUi(20.0);
    const btn_gap = theme.scaledUi(2.0);
    const right_margin = theme.scaledUi(10.0);
    const btn_y = header_rect.y + (header_rect.h - btn_h) * 0.5;

    const close_rect = palette.Rect{ .x = header_rect.x + header_rect.w - right_margin - btn_w, .y = btn_y, .w = btn_w, .h = btn_h };
    const min_rect = palette.Rect{ .x = close_rect.x - btn_gap - btn_w, .y = btn_y, .w = btn_w, .h = btn_h };
    const max_rect = palette.Rect{ .x = min_rect.x - btn_gap - btn_w, .y = btn_y, .w = btn_w, .h = btn_h };

    // Render only when focused — non-focused panes keep their panel header clean.
    if (focused) {
        const is_maximized = state.isCurrentProjectWorkspacePaneMaximized(pane_id);
        const max_kind: WindowControlKind = if (is_maximized) .restore else .maximize;
        renderWindowControlButton(state, max_rect, max_kind, rectContains(max_rect, mx, my));
        appendHit(.{ .pane_id = pane_id, .action = .maximize, .rect = max_rect });
        renderWindowControlButton(state, min_rect, .minimize, rectContains(min_rect, mx, my));
        appendHit(.{ .pane_id = pane_id, .action = .minimize, .rect = min_rect });
        renderWindowControlButton(state, close_rect, .close, rectContains(close_rect, mx, my));
        appendHit(.{ .pane_id = pane_id, .action = .close, .rect = close_rect });

        // Split trigger (+): always visible on focused pane, brightens on header hover.
        const split_w = theme.scaledUi(24.0);
        const split_h = theme.scaledUi(20.0);
        const split_x = max_rect.x - theme.scaledUi(10.0) - split_w;
        const split_y = header_rect.y + (header_rect.h - split_h) * 0.5;
        const split_rect = palette.Rect{ .x = split_x, .y = split_y, .w = split_w, .h = split_h };
        const split_active = menu_open_here;
        const split_emphasized = header_hovered or split_active;
        renderSplitTriggerButton(state, split_rect, split_active, split_emphasized, header_rect);
        appendHit(.{ .pane_id = pane_id, .action = .toggle_split_menu, .rect = split_rect });
        if (menu_open_here) split_menu_anchor = split_rect;
    }
    _ = reserve;
}

const WindowControlKind = enum { close, minimize, maximize, restore };

fn renderWindowControlButton(state: *runtime.AppState, rect: palette.Rect, kind: WindowControlKind, hovered: bool) void {
    if (hovered) {
        const bg = switch (kind) {
            .close => colors.rgba(232, 76, 72, 220),
            else => colors.rgba(48, 54, 62, 255),
        };
        queueRounded(state, rect, paletteColor(bg), theme.scaledUi(4.0));
    }
    const icon_color = if (hovered) theme.COLOR_WHITE else colors.rgba(170, 178, 188, 255);
    const cx = rect.x + rect.w * 0.5;
    const cy = rect.y + rect.h * 0.5;
    const stroke = theme.scaledUi(1.0);
    switch (kind) {
        .close => {
            queueText(state, .{
                .x = rect.x,
                .y = rect.y + theme.scaledUi(2.0),
                .w = rect.w,
                .h = rect.h,
            }, "\u{00D7}", paletteColor(icon_color), theme.scaledUi(15.0), rect);
        },
        .minimize => {
            const bar_w = theme.scaledUi(9.0);
            const bar_h = stroke;
            queueRect(state, .{
                .x = cx - bar_w * 0.5,
                .y = cy + theme.scaledUi(3.0) - bar_h * 0.5,
                .w = bar_w,
                .h = bar_h,
            }, paletteColor(icon_color));
        },
        .maximize => {
            const sq = theme.scaledUi(9.0);
            queueBorder(state, .{
                .x = cx - sq * 0.5,
                .y = cy - sq * 0.5,
                .w = sq,
                .h = sq,
            }, paletteColor(icon_color), theme.scaledUi(1.0), stroke);
        },
        .restore => {
            const sq = theme.scaledUi(8.0);
            const off = theme.scaledUi(2.0);
            queueBorder(state, .{
                .x = cx - sq * 0.5 + off,
                .y = cy - sq * 0.5 - off,
                .w = sq,
                .h = sq,
            }, paletteColor(icon_color), theme.scaledUi(1.0), stroke);
            queueBorder(state, .{
                .x = cx - sq * 0.5 - off,
                .y = cy - sq * 0.5 + off,
                .w = sq,
                .h = sq,
            }, paletteColor(icon_color), theme.scaledUi(1.0), stroke);
        },
    }
}

fn renderSplitTriggerButton(state: *runtime.AppState, rect: palette.Rect, active: bool, emphasized: bool, clip: palette.Rect) void {
    if (active) {
        queueRounded(state, rect, paletteColor(colors.rgba(40, 50, 58, 255)), theme.scaledUi(5.0));
        queueBorder(state, rect, paletteColor(theme.COLOR_SECONDARY_GREEN), theme.scaledUi(5.0), theme.scaledUi(1.0));
    } else if (emphasized) {
        queueRounded(state, rect, paletteColor(colors.rgba(28, 32, 38, 255)), theme.scaledUi(5.0));
        queueBorder(state, rect, paletteColor(colors.rgba(62, 70, 78, 255)), theme.scaledUi(5.0), theme.scaledUi(1.0));
    }
    const text_color = if (active or emphasized)
        theme.COLOR_WHITE
    else
        colors.rgba(120, 128, 138, 255);
    queueText(state, .{
        .x = rect.x + theme.scaledUi(4.0),
        .y = rect.y + theme.scaledUi(1.0),
        .w = @max(rect.w - theme.scaledUi(8.0), 1.0),
        .h = rect.h,
    }, "+", paletteColor(text_color), theme.scaledUi(15.0), clip);
}

fn renderSplitMenuOverlay(state: *runtime.AppState, workspace_rect: palette.Rect) void {
    const pane_id = split_menu_open_for orelse return;

    const menu_w = theme.scaledUi(248.0);
    const header_h = theme.scaledUi(24.0);
    const cell_h = theme.scaledUi(48.0);
    const cell_gap = theme.scaledUi(8.0);
    const menu_pad_x = theme.scaledUi(12.0);
    const menu_pad_top = theme.scaledUi(8.0);
    const menu_pad_bottom = theme.scaledUi(12.0);
    const menu_h = menu_pad_top + header_h + menu_pad_bottom + cell_h * 2.0 + cell_gap;

    var menu_x = split_menu_anchor.x;
    const max_x = workspace_rect.x + workspace_rect.w - menu_w - theme.scaledUi(8.0);
    if (menu_x > max_x) menu_x = max_x;
    if (menu_x < workspace_rect.x + theme.scaledUi(8.0)) menu_x = workspace_rect.x + theme.scaledUi(8.0);
    var menu_y = split_menu_anchor.y + split_menu_anchor.h + theme.scaledUi(6.0);
    const max_y = workspace_rect.y + workspace_rect.h - menu_h - theme.scaledUi(8.0);
    if (menu_y > max_y) menu_y = max_y;

    const menu_rect = palette.Rect{ .x = menu_x, .y = menu_y, .w = menu_w, .h = menu_h };
    split_menu_rect = menu_rect;

    queueRounded(state, menu_rect, paletteColor(colors.rgba(26, 28, 34, 255)), theme.scaledUi(10.0));
    queueBorder(state, menu_rect, paletteColor(colors.rgba(66, 68, 78, 255)), theme.scaledUi(10.0), theme.scaledUi(1.0));

    queueText(state, .{
        .x = menu_rect.x + menu_pad_x,
        .y = menu_rect.y + menu_pad_top,
        .w = menu_rect.w - menu_pad_x * 2.0,
        .h = header_h,
    }, "Split pane", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(11.0), menu_rect);

    const grid_x = menu_rect.x + menu_pad_x;
    const grid_y = menu_rect.y + menu_pad_top + header_h;
    const cell_w = (menu_rect.w - menu_pad_x * 2.0 - cell_gap) * 0.5;

    const Opt = struct {
        action: WorkspacePaneAction,
        row: u8,
        col: u8,
        label: []const u8,
    };
    const opts = [_]Opt{
        .{ .action = .split_chat_vertical, .row = 0, .col = 0, .label = "Chat right" },
        .{ .action = .split_chat_horizontal, .row = 0, .col = 1, .label = "Chat below" },
        .{ .action = .split_terminal_vertical, .row = 1, .col = 0, .label = "Term right" },
        .{ .action = .split_terminal_horizontal, .row = 1, .col = 1, .label = "Term below" },
    };

    for (opts) |o| {
        const col_f: f32 = @floatFromInt(o.col);
        const row_f: f32 = @floatFromInt(o.row);
        const cx = grid_x + col_f * (cell_w + cell_gap);
        const cy = grid_y + row_f * (cell_h + cell_gap);
        const cell_rect = palette.Rect{ .x = cx, .y = cy, .w = cell_w, .h = cell_h };
        const hovered = rectContains(cell_rect, state.palette_mouse_x, state.palette_mouse_y);
        const cell_bg = if (hovered) colors.rgba(42, 50, 58, 255) else colors.rgba(31, 36, 42, 255);
        const cell_border = if (hovered) theme.COLOR_SECONDARY_GREEN else colors.rgba(66, 74, 84, 255);
        queueRounded(state, cell_rect, paletteColor(cell_bg), theme.scaledUi(6.0));
        queueBorder(state, cell_rect, paletteColor(cell_border), theme.scaledUi(6.0), theme.scaledUi(1.0));

        const diag_w = theme.scaledUi(30.0);
        const diag_h = theme.scaledUi(24.0);
        const diag = palette.Rect{
            .x = cell_rect.x + theme.scaledUi(10.0),
            .y = cell_rect.y + (cell_rect.h - diag_h) * 0.5,
            .w = diag_w,
            .h = diag_h,
        };
        const diag_stroke = if (hovered) colors.rgba(180, 200, 220, 255) else colors.rgba(110, 130, 150, 255);
        const fill_color = if (o.row == 0) colors.rgba(76, 168, 110, 220) else colors.rgba(196, 144, 96, 220);
        queueBorder(state, diag, paletteColor(diag_stroke), theme.scaledUi(2.0), theme.scaledUi(1.0));
        if (o.col == 0) {
            const line = palette.Rect{ .x = diag.x + diag.w * 0.5, .y = diag.y, .w = theme.scaledUi(1.0), .h = diag.h };
            queueRect(state, line, paletteColor(diag_stroke));
            const fill = palette.Rect{
                .x = diag.x + diag.w * 0.5 + theme.scaledUi(2.0),
                .y = diag.y + theme.scaledUi(2.0),
                .w = diag.w * 0.5 - theme.scaledUi(3.0),
                .h = diag.h - theme.scaledUi(4.0),
            };
            queueRect(state, fill, paletteColor(fill_color));
        } else {
            const line = palette.Rect{ .x = diag.x, .y = diag.y + diag.h * 0.5, .w = diag.w, .h = theme.scaledUi(1.0) };
            queueRect(state, line, paletteColor(diag_stroke));
            const fill = palette.Rect{
                .x = diag.x + theme.scaledUi(2.0),
                .y = diag.y + diag.h * 0.5 + theme.scaledUi(2.0),
                .w = diag.w - theme.scaledUi(4.0),
                .h = diag.h * 0.5 - theme.scaledUi(3.0),
            };
            queueRect(state, fill, paletteColor(fill_color));
        }

        const text_x = diag.x + diag.w + theme.scaledUi(10.0);
        const text_color = if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
        queueText(state, .{
            .x = text_x,
            .y = cell_rect.y + (cell_rect.h - theme.scaledUi(14.0)) * 0.5,
            .w = cell_rect.x + cell_rect.w - text_x - theme.scaledUi(8.0),
            .h = theme.scaledUi(14.0),
        }, o.label, paletteColor(text_color), theme.scaledUi(12.0), menu_rect);

        appendHit(.{ .pane_id = pane_id, .action = o.action, .rect = cell_rect });
    }
}

fn renderRestoreStrip(state: *runtime.AppState, rect: palette.Rect, minimized_count: usize) void {
    if (minimized_count == 0 or rect.h <= 0.0) return;
    queueRect(state, rect, paletteColor(colors.rgba(14, 16, 19, 255)));
    queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), 0.0, theme.scaledUi(1.0));

    var x = rect.x + theme.scaledUi(10.0);
    const chip_h = @max(rect.h - theme.scaledUi(12.0), theme.scaledUi(20.0));
    const y = rect.y + (rect.h - chip_h) * 0.5;
    const mx = state.palette_mouse_x;
    const my = state.palette_mouse_y;
    var i: usize = 0;
    while (i < minimized_count) : (i += 1) {
        const pane = state.currentProjectWorkspaceMinimizedPaneAt(i) orelse continue;
        const label = switch (pane.kind) {
            .chat => "Chat",
            .terminal => "Terminal",
        };
        const chip_w = switch (pane.kind) {
            .chat => theme.scaledUi(82.0),
            .terminal => theme.scaledUi(108.0),
        };
        const chip_rect = palette.Rect{ .x = x, .y = y, .w = chip_w, .h = chip_h };
        renderRestoreChip(state, chip_rect, label, rectContains(chip_rect, mx, my), rect);
        appendHit(.{ .pane_id = pane.id, .action = .restore, .rect = chip_rect });
        x += chip_w + theme.scaledUi(6.0);
        if (x > rect.x + rect.w - theme.scaledUi(24.0)) break;
    }
}

fn renderRestoreChip(state: *runtime.AppState, rect: palette.Rect, label: []const u8, hovered: bool, clip: palette.Rect) void {
    const bg = if (hovered) colors.rgba(40, 48, 56, 255) else colors.rgba(26, 30, 36, 255);
    const border = if (hovered) colors.rgba(96, 108, 122, 255) else colors.rgba(58, 66, 76, 255);
    queueRounded(state, rect, paletteColor(bg), theme.scaledUi(5.0));
    queueBorder(state, rect, paletteColor(border), theme.scaledUi(5.0), theme.scaledUi(1.0));

    const text_color = if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    // Up-arrow glyph drawn from two rects so it doesn't depend on font glyph coverage.
    const arrow_w = theme.scaledUi(8.0);
    const arrow_h = theme.scaledUi(5.0);
    const arrow_x = rect.x + theme.scaledUi(10.0);
    const arrow_cy = rect.y + rect.h * 0.5;
    // Diagonals approximated with two thin rects forming an inverted V.
    const stroke = theme.scaledUi(1.5);
    queueRect(state, .{
        .x = arrow_x,
        .y = arrow_cy + arrow_h * 0.5 - stroke,
        .w = arrow_w * 0.55,
        .h = stroke,
    }, paletteColor(text_color));
    queueRect(state, .{
        .x = arrow_x + arrow_w * 0.45,
        .y = arrow_cy + arrow_h * 0.5 - stroke,
        .w = arrow_w * 0.55,
        .h = stroke,
    }, paletteColor(text_color));
    queueRect(state, .{
        .x = arrow_x + arrow_w * 0.5 - stroke * 0.5,
        .y = arrow_cy - arrow_h * 0.5,
        .w = stroke,
        .h = arrow_h,
    }, paletteColor(text_color));

    queueText(state, .{
        .x = arrow_x + arrow_w + theme.scaledUi(8.0),
        .y = rect.y + (rect.h - theme.scaledUi(14.0)) * 0.5,
        .w = @max(rect.w - (arrow_w + theme.scaledUi(28.0)), 1.0),
        .h = theme.scaledUi(14.0),
    }, label, paletteColor(text_color), theme.scaledUi(12.0), clip);
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

fn paletteColor(color: [4]f32) palette.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}
