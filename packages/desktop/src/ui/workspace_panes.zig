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
const profiler = @import("../profiler.zig");
const terminal_panel = @import("terminal_panel.zig");
const theme = @import("theme.zig");

const FOCUS_ANIM_DURATION_MS: i64 = 160;
const THREAD_DROP_PREVIEW_Z: i32 = 140;
const PANE_CONTEXT_MENU_Z: i32 = 180;

fn nowMs() i64 {
    return @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
}

const MAX_WORKSPACE_PANE_HITS = 48;
const WorkspacePaneAction = enum {
    focus,
    maximize,
    minimize,
    restore,
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

var last_thread_drop_target: ?ThreadDropTarget = null;

var pane_rect_count: usize = 0;
var pane_rects: [MAX_WORKSPACE_PANE_RECTS]WorkspacePaneRect = undefined;
var browser_pane_rendered: bool = false;

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

    return focusPaneInDirectionFromRects(state, current_id, dir, pane_rects[0..pane_rect_count], false);
}

pub fn openFocusedChatPaneContextMenu(state: *runtime.AppState) bool {
    if (state.projects.items.len == 0) return false;
    const pane_id = state.projects.items[state.selected_project_index].workspace_layout.focused_pane_id orelse return false;
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
    browser_pane_rendered = false;
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
        if (!browser_pane_rendered) state.noteBrowserPaneNotRendered();
        return;
    }
    if (state.currentProjectWorkspaceRoot()) |root| {
        renderNode(state, root, workspace_rect);
        renderRestoreStrip(state, .{ .x = rect.x, .y = rect.y + workspace_rect.h, .w = rect.w, .h = restore_h }, minimized_count);
        renderSplitMenuOverlay(state, workspace_rect);
        if (!browser_pane_rendered) state.noteBrowserPaneNotRendered();
        return;
    }

    chat_panel.renderWorkspaceAt(state, workspace_rect);
    renderRestoreStrip(state, .{ .x = rect.x, .y = rect.y + workspace_rect.h, .w = rect.w, .h = restore_h }, minimized_count);
    renderSplitMenuOverlay(state, workspace_rect);
    if (!browser_pane_rendered) state.noteBrowserPaneNotRendered();
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool) bool {
    if (button == 3 and down) {
        // Right-click on a pane opens the chat thread context menu anchored at the cursor.
        var ri: usize = hit_cache.count;
        while (ri > 0) {
            ri -= 1;
            const hit = hit_cache.hits[ri];
            if (hit.action != .focus) continue;
            if (!rectContains(hit.rect, x, y)) continue;
            _ = state.focusCurrentProjectWorkspacePane(hit.pane_id);
            split_menu_show_paste = false;
            split_menu_kind = .chat_context;
            if (state.palette_composer.textRect().contains(.{ .x = x, .y = y })) {
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
            if (state.workspacePaneKindById(pane_rect.pane_id) != .chat) return false;
            _ = state.focusCurrentProjectWorkspacePane(pane_rect.pane_id);
            split_menu_show_paste = false;
            split_menu_kind = .chat_context;
            if (state.palette_composer.textRect().contains(.{ .x = x, .y = y })) {
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
                split_menu_show_paste = false;
                split_menu_kind = .split_button;
                split_menu_anchor = hit.rect;
                if (split_menu_open_for) |id| {
                    split_menu_open_for = if (id == hit.pane_id) null else hit.pane_id;
                } else {
                    split_menu_open_for = hit.pane_id;
                }
            },
            .copy_selection => {
                copyTranscriptSelectionToClipboard(state);
                split_menu_open_for = null;
            },
            .paste_into_prompt => {
                _ = state.pasteClipboardTextIntoPaletteComposer();
                split_menu_open_for = null;
            },
            .new_chat_thread => {
                if (state.projects.items.len > 0) state.createThreadForProject(state.selected_project_index);
                split_menu_open_for = null;
            },
            .refresh_chat_thread => {
                if (state.projects.items.len > 0) {
                    const thread_index = state.currentProject().selected_thread_index;
                    state.syncThreadFromProvider(state.selected_project_index, thread_index);
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

pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32) bool {
    if (resize_drag) |hit| {
        updateResizeDrag(state, hit, x, y);
        return true;
    }
    // Focus-follows-mouse: hovering into a pane focuses it. Skip while a split
    // menu is open and the cursor is inside that menu so the open pane stays put.
    if (split_menu_open_for != null and (rectContains(split_menu_rect, x, y) or rectContains(split_submenu_rect, x, y))) return false;
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
    const maybe_target = threadDropTargetAt(x, y);
    last_thread_drop_target = maybe_target;
    const target = maybe_target orelse return;
    const previous_z = state.palette_overlay_batch.setZIndex(THREAD_DROP_PREVIEW_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);
    queueRounded(state, target.preview, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 54)), theme.scaledUi(6.0));
    queueBorder(state, target.preview, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 210)), theme.scaledUi(6.0), theme.scaledUi(2.0));
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

const PANE_HEADER_RIGHT_RESERVE: f32 = 46.0;

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
            browser_panel.renderDockAt(state, rect);
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

    // Render only when focused — non-focused panes keep their panel header clean.
    if (focused) {
        // Split trigger (+): always visible on focused pane, brightens on header hover.
        const split_w = theme.scaledUi(24.0);
        const split_h = theme.scaledUi(20.0);
        const right_margin = theme.scaledUi(10.0);
        const split_x = header_rect.x + header_rect.w - right_margin - split_w;
        const split_y = header_rect.y + (header_rect.h - split_h) * 0.5;
        const split_rect = palette.Rect{ .x = split_x, .y = split_y, .w = split_w, .h = split_h };
        const split_active = menu_open_here;
        const split_emphasized = header_hovered or split_active;
        renderSplitTriggerButton(state, split_rect, split_active, split_emphasized, header_rect);
        appendHit(.{ .pane_id = pane_id, .action = .toggle_split_menu, .rect = split_rect });
        if (menu_open_here and split_menu_kind == .split_button) split_menu_anchor = split_rect;
    }
    _ = reserve;
}

fn renderSplitTriggerButton(state: *runtime.AppState, rect: palette.Rect, active: bool, emphasized: bool, clip: palette.Rect) void {
    _ = clip;
    if (active) {
        queueRounded(state, rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(5.0));
        queueBorder(state, rect, paletteColor(theme.COLOR_SECONDARY_GREEN), theme.scaledUi(5.0), theme.scaledUi(1.0));
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
    const copy_count: usize = if (split_menu_kind == .chat_context and state.transcriptMarkdownSelectionActive()) 1 else 0;
    const paste_count: usize = if (split_menu_kind == .chat_context and split_menu_show_paste) 1 else 0;
    const command_count: usize = switch (split_menu_kind) {
        .chat_context => copy_count + paste_count + 3,
        .split_button => 1,
    };
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
    if (split_menu_kind == .chat_context) {
        if (copy_count > 0) y = renderContextMenuRow(state, pane_id, .copy_selection, "Copy", menu_rect, menu_pad_x, y, row_rect_w, row_h) + row_gap;
        if (paste_count > 0) y = renderContextMenuRow(state, pane_id, .paste_into_prompt, "Paste", menu_rect, menu_pad_x, y, row_rect_w, row_h) + row_gap;
        y = renderContextMenuRow(state, pane_id, .new_chat_thread, "New Chat Thread", menu_rect, menu_pad_x, y, row_rect_w, row_h) + row_gap;
        y = renderContextMenuRow(state, pane_id, .refresh_chat_thread, "Refresh Chat Thread", menu_rect, menu_pad_x, y, row_rect_w, row_h) + row_gap;
    }
    const split_trigger_rect = renderContextMenuStaticRow(state, "Split Pane", menu_rect, menu_pad_x, y, row_rect_w, row_h, true);

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
    const submenu_visible = rectContains(split_trigger_rect, state.palette_mouse_x, state.palette_mouse_y) or rectContains(submenu_rect, state.palette_mouse_x, state.palette_mouse_y);
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
    const hovered = rectContains(rect, state.palette_mouse_x, state.palette_mouse_y);
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
    const hovered = rectContains(rect, state.palette_mouse_x, state.palette_mouse_y);
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

fn renderRestoreStrip(state: *runtime.AppState, rect: palette.Rect, minimized_count: usize) void {
    if (minimized_count == 0 or rect.h <= 0.0) return;
    queueRect(state, rect, paletteColor(theme.background()));
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
            .browser => "Browser",
        };
        const chip_w = switch (pane.kind) {
            .chat => theme.scaledUi(82.0),
            .terminal => theme.scaledUi(108.0),
            .browser => theme.scaledUi(104.0),
        };
        const chip_rect = palette.Rect{ .x = x, .y = y, .w = chip_w, .h = chip_h };
        renderRestoreChip(state, chip_rect, label, rectContains(chip_rect, mx, my), rect);
        appendHit(.{ .pane_id = pane.id, .action = .restore, .rect = chip_rect });
        x += chip_w + theme.scaledUi(6.0);
        if (x > rect.x + rect.w - theme.scaledUi(24.0)) break;
    }
}

fn renderRestoreChip(state: *runtime.AppState, rect: palette.Rect, label: []const u8, hovered: bool, clip: palette.Rect) void {
    const bg = if (hovered) theme.lighten(theme.COLOR_PANEL_ALT, 0.08) else theme.COLOR_PANEL_ALT;
    const border = if (hovered) theme.COLOR_PANEL_MUTED else theme.borderMuted();
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
