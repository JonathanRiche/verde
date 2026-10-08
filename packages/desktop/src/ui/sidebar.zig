//! Workspace rail rendering for the native shell.

const std = @import("std");
const palette = @import("palette");
const sdl = @import("zsdl3");
const theme = @import("theme.zig");
const colors = @import("colors.zig");
const context_menu = @import("context_menu.zig");
const globe_icon = @import("globe_icon.zig");
const runtime = @import("runtime.zig");
const workspace_identity = @import("workspace_identity.zig");
const text_measure = @import("text_measure.zig");
const file_icons = @import("file_icons.zig");
const command_palette = @import("command_palette.zig");
const keybinds = @import("../app/keybinds.zig");
const utils = @import("../utils.zig");
const profiler = @import("../runtime/profiler.zig");
const platform_runtime = @import("platform_runtime");
const native_state = @import("../state.zig");
const Provider = native_state.Provider;
const SurfaceProvider = native_state.SurfaceProvider;

const log = std.log.scoped(.native_ui_sidebar);

/// Shared ~1.6s breathing pulse (0.35..1.0) for working/waiting pips and badges.
/// Only pips belonging to the selected workspace mark the frame as hosting an
/// active pip animation (the main loop's ~30fps tick); background-workspace
/// pips draw the same clock-driven pulse but deliberately step at the ~1Hz
/// pollSend repaint instead of forcing continuous frames app-wide.
fn attentionPulse(state: *runtime.AppState, project_index: usize) f32 {
    if (state.app_config.reduced_motion.status_pulse) return 1.0;
    if (project_index == state.project_controller.selected_index) state.sidebar_pulse_animating = true;
    return 0.35 + 0.65 * theme.activityPulse(profiler.nowNs());
}

/// Saved-thread row: provider bitmap slot (CSS px). Match `COMPOSER_PROVIDER_LOGO_SLOT_CSS` in `chat_panel.zig`.
const SIDEBAR_THREAD_PROVIDER_GLYPH_CSS: f32 = 22.0;
/// Thread row height must fit `SIDEBAR_THREAD_PROVIDER_GLYPH_CSS` with a little vertical air.
const SIDEBAR_THREAD_ROW_HEIGHT_CSS: f32 = 38.0;
/// Vertical advance per thread row (row + gap).
const SIDEBAR_THREAD_ROW_STEP_CSS: f32 = 42.0;
// Mini-rows inside a split-tile group are tighter than standalone rows so a
// tab group does not dominate the OPEN list.
const SIDEBAR_TILE_ROW_HEIGHT_CSS: f32 = 30.0;
const SIDEBAR_THREAD_ICON_LEADING_PAD_CSS: f32 = 10.0;
/// Horizontal gap between the icon slot and the title.
const SIDEBAR_THREAD_ICON_TITLE_GAP_CSS: f32 = 10.0;
/// Width reserved for the live status column ("Working · 59:59"); titles only
/// give up this width while a status label is actually present.
const SIDEBAR_STATUS_COLUMN_CSS: f32 = 96.0;
/// Horizontal padding of the expanded rail's content column. Kept tight so
/// pane titles keep as many characters as possible at typical rail widths.
const SIDEBAR_PAD_X_CSS: f32 = 16.0;
/// Compact workspace-row badge width for Herdr-backed workspaces.
const SIDEBAR_HERDR_BADGE_W_CSS: f32 = 50.0;
const HIDDEN_SIDEBAR_EDGE_REVEAL_CSS: f32 = 8.0;
/// Reserved band at the bottom of the rail for sticky chrome (settings, etc.).
/// The scrolling workspace list stops short of this so its last row never
/// slides under — or past — the pinned footer.
const SIDEBAR_FOOTER_RESERVE_CSS: f32 = 56.0;
/// Visible-row cap for the pinned ACTIVE cluster. Extra rows scroll inside
/// the cluster so a busy machine cannot bury the workspace tree.
const SIDEBAR_ACTIVE_MAX_ROWS: usize = 10;
/// Caption band above ACTIVE rows, including the gap under the label.
const SIDEBAR_ACTIVE_LABEL_H_CSS: f32 = 20.0;
/// Hairline divider plus trailing gap that separates ACTIVE from the tree.
const SIDEBAR_ACTIVE_TRAILING_H_CSS: f32 = 12.0;
/// Keep at least this much of the workspace tree visible under a tall ACTIVE
/// cluster so short windows still show the selected workspace.
const SIDEBAR_WORKSPACE_MIN_H_CSS: f32 = 96.0;
const THREAD_DRAG_THRESHOLD_CSS: f32 = 5.0;
const THREAD_DRAG_FLOATING_Z: i32 = 160;
/// Sidebar context menus are root overlays: keep them above pane menus and
/// composer popovers (up to 1402), but below Companion (1550) and true modals.
const SIDEBAR_CONTEXT_MENU_Z: i32 = 1450;

const SidebarHitKind = enum {
    /// Header toggle: hides the rail, or pins a hover-revealed rail open.
    collapse,
    new_thread,
    new_terminal,
    /// Workspace switcher trigger; opens the switcher popover.
    workspace_switcher,
    /// "+" beside the switcher trigger; opens the new-workspace creator.
    add_workspace,
    open_pane,
    /// Live pane row in the OPEN section; supports click focus and drag
    /// reordering in addition to the open-pane actions.
    open_pane_reorder,
    /// Search trigger pill; opens the command palette unscoped.
    command_palette,
    settings,
};

const SidebarHit = struct {
    rect: palette.Rect,
    kind: SidebarHitKind,
    project_index: usize = 0,
    thread_index: usize = 0,
};

var palette_hits: [512]SidebarHit = undefined;
var palette_hit_count: usize = 0;
var palette_sidebar_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
/// Last-rendered workspace switcher trigger; the switcher popover anchors to
/// it. Zero-sized while the rail is hidden.
var workspace_switcher_anchor: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

pub fn workspaceSwitcherAnchor() palette.Rect {
    return workspace_switcher_anchor;
}
var sidebar_scroll_y: f32 = 0.0;
var sidebar_max_scroll_y: f32 = 0.0;
var sidebar_revealed_project_index: ?usize = null;
var sidebar_revealed_pane_id: ?native_state.WorkspacePaneId = null;
var sidebar_revealed_view_h: f32 = 0.0;
var attention_scroll_y: f32 = 0.0;
var attention_max_scroll_y: f32 = 0.0;
var attention_clip: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

// Item 6: eased ACTIVE cluster geometry. Rows slide to their new sort
// position and the cluster viewport height eases, so a pane entering or
// leaving the cluster glides the tree instead of yanking it a row height.
// Only frames after a change cost anything: `attention_motion_animating`
// is re-derived every sidebar pass and cleared once everything settles.
const ActiveRowSlot = struct {
    project_index: usize,
    pane_id: runtime.WorkspacePaneId,
    /// Shown y offset (px) relative to the top of the row list content.
    y: f32,
    seen: bool,
};
const ATTENTION_MOTION_SETTLE_PX: f32 = 0.5;
var active_row_slots: [palette_hits.len]ActiveRowSlot = undefined;
var active_row_slot_count: usize = 0;
var attention_anim_viewport_h: f32 = -1.0;
var attention_anim_last_ms: i64 = 0;
var attention_motion_animating: bool = false;

/// True while ACTIVE rows or the cluster height are still easing; polled by
/// the frame pacer through `layout.isSidebarAnimating`.
pub fn isAttentionMotionAnimating() bool {
    return attention_motion_animating;
}

/// Per-frame easing step in 0..1 from the time since the previous sidebar
/// pass; 1.0 snaps (first frame, or reduced motion collapses to ~80ms).
fn attentionMotionStep(state: *const runtime.AppState) f32 {
    const now_ms: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    const first = attention_anim_last_ms == 0;
    const dt_ms = @max(now_ms - attention_anim_last_ms, 0);
    attention_anim_last_ms = now_ms;
    if (first) return 1.0;
    const duration_ms = theme.motionDurationMs(state.app_config.reduced_motion.chrome, theme.MOTION_BASE_MS);
    if (duration_ms <= 0) return 1.0;
    return theme.easeOutCubic(theme.clampf(@as(f32, @floatFromInt(dt_ms)) / @as(f32, @floatFromInt(duration_ms)), 0.0, 1.0));
}

fn approachEased(current: f32, target: f32, t: f32) f32 {
    const next = current + (target - current) * t;
    return if (@abs(next - target) <= ATTENTION_MOTION_SETTLE_PX) target else next;
}

/// Eases the cluster viewport toward `target_h`; a collapse to zero still
/// eases so the tree slides up rather than jumping when the last row leaves.
fn easedAttentionViewportH(target_h: f32, t: f32) f32 {
    if (attention_anim_viewport_h < 0.0) attention_anim_viewport_h = target_h;
    attention_anim_viewport_h = approachEased(attention_anim_viewport_h, target_h, t);
    if (attention_anim_viewport_h != target_h) attention_motion_animating = true;
    return attention_anim_viewport_h;
}

/// Shown y for one ACTIVE row. Known rows ease from where they were last
/// drawn; rows new to the cluster appear at their target.
fn activeRowShownY(project_index: usize, pane_id: runtime.WorkspacePaneId, target_y: f32, t: f32) f32 {
    for (active_row_slots[0..active_row_slot_count]) |*slot| {
        if (slot.project_index != project_index or slot.pane_id != pane_id) continue;
        slot.seen = true;
        slot.y = approachEased(slot.y, target_y, t);
        if (slot.y != target_y) attention_motion_animating = true;
        return slot.y;
    }
    if (active_row_slot_count < active_row_slots.len) {
        active_row_slots[active_row_slot_count] = .{ .project_index = project_index, .pane_id = pane_id, .y = target_y, .seen = true };
        active_row_slot_count += 1;
    }
    return target_y;
}

/// Drops slots for rows that left the cluster and clears `seen` for the next
/// pass. Slots must be dropped so a pane re-entering later starts fresh.
fn pruneActiveRowSlots() void {
    var keep: usize = 0;
    for (active_row_slots[0..active_row_slot_count]) |slot| {
        if (!slot.seen) continue;
        active_row_slots[keep] = .{ .project_index = slot.project_index, .pane_id = slot.pane_id, .y = slot.y, .seen = false };
        keep += 1;
    }
    active_row_slot_count = keep;
}

const SidebarContextMenuAction = enum {
    workspace_new_chat,
    workspace_open_codex_tui,
    workspace_open_terminal,
    workspace_herdr_handoff,
    workspace_herdr_focus_terminal,
    workspace_herdr_unlink,
    workspace_rename,
    workspace_open_settings,
    workspace_import_codex,
    workspace_import_opencode,
    workspace_import_claude,
    workspace_archive,
    thread_open_tui,
    thread_open_chat,
    thread_rename,
    thread_regenerate_title,
    thread_sync,
    thread_handoff,
    thread_close_pane,
};

/// The workspace pane showing this thread: its chat pane, or the agent TUI
/// terminal pane when the thread is open in TUI mode.
fn threadPaneId(state: *const runtime.AppState, project_index: usize, thread_index: usize) ?runtime.WorkspacePaneId {
    if (project_index >= state.project_controller.projects.items.len) return null;
    const project = &state.project_controller.projects.items[project_index];
    for (project.workspace_layout.panes.items) |pane| {
        switch (pane.ref) {
            .chat => |ref| if (ref.thread_index == thread_index) return pane.id,
            else => {},
        }
    }
    if (thread_index >= project.threads.items.len) return null;
    const dock_id = project.threads.items[thread_index].tui_dock_id orelse return null;
    return project.workspace_layout.visibleTerminalPaneIdForDock(dock_id);
}

var sidebar_menu_panel_rect: palette.Rect = .{};
var sidebar_menu_row_rects: [16]palette.Rect = undefined;
var sidebar_menu_row_actions: [16]SidebarContextMenuAction = undefined;
var sidebar_menu_row_enabled: [16]bool = undefined;
var sidebar_menu_row_labels: [16][]const u8 = undefined;
var sidebar_menu_row_count: usize = 0;

var settings_hovered: bool = false;
var add_workspace_hovered: bool = false;
var terminal_action_hovered: ?usize = null;
var search_trigger_hovered: bool = false;
var switcher_trigger_hovered: bool = false;
/// Per-frame: OPEN rows are interleaved newest-activity first (All
/// Workspaces), so in-workspace drag reorder is off.
var open_rows_recency_sorted: bool = false;
/// Per-frame: OPEN rows carry a workspace identity chip (All Workspaces).
var open_rows_show_chip: bool = false;

const PaneRowDragState = struct {
    pending: bool = false,
    active: bool = false,
    project_index: usize = 0,
    pane_id: native_state.WorkspacePaneId = 0,
    start_x: f32 = 0.0,
    start_y: f32 = 0.0,
    x: f32 = 0.0,
    y: f32 = 0.0,
};

var pane_row_drag: PaneRowDragState = .{};
/// Drop slot in the owning layout's persisted pane array.
var pane_drop_before: usize = 0;
var pane_drop_line_rect: palette.Rect = .{};
var pane_drop_valid: bool = false;
/// Another workspace under the cursor while dragging a chat row; dropping
/// there moves the chat into that workspace instead of reordering.
var pane_drop_target_project: ?usize = null;
var pane_drop_target_rect: palette.Rect = .{};

/// Renders the sidebar with Palette-owned drawing and retained hit regions.
pub fn renderPalette(state: *runtime.AppState, rect: palette.Rect) void {
    palette_sidebar_rect = rect;
    palette_hit_count = 0;
    attention_clip = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    attention_max_scroll_y = 0.0;
    // Re-armed below by any ACTIVE row or viewport still easing; cleared here
    // (not in the expanded pass) so a collapsed rail can never leave it stuck on.
    attention_motion_animating = false;

    queuePaletteRect(state, rect, paletteColor(theme.COLOR_PANEL));
    queuePaletteRect(state, .{
        .x = rect.x + rect.w - theme.scaledUi(1.0),
        .y = rect.y,
        .w = theme.scaledUi(1.0),
        .h = rect.h,
    }, paletteColor(theme.borderMuted()));

    renderPaletteExpandedSidebar(state, rect);
}

/// Renders the context menu after workspace-local clipping has completed.
pub fn renderContextMenuOverlay(state: *runtime.AppState) void {
    if (state.sidebar_context_menu_open) renderSidebarContextMenu(state, palette_sidebar_rect);
}

pub fn pointerOverSidebar(x: f32, y: f32) bool {
    return rectContainsPoint(palette_sidebar_rect, x, y) or rectContainsPoint(sidebar_menu_panel_rect, x, y);
}

/// True when the mouse rests on a clickable sidebar control (rail buttons,
/// workspace/thread rows, enabled context-menu rows) so the main loop can
/// show a pointer (hand) cursor. Every retained hit rect is actionable in
/// `handlePaletteMouseButton`, so any hit under the point qualifies.
pub fn wantsPointerAt(state: *const runtime.AppState, x: f32, y: f32) bool {
    if (state.sidebar_context_menu_open) {
        var row: usize = 0;
        while (row < sidebar_menu_row_count) : (row += 1) {
            // Disabled rows swallow clicks but perform nothing, so they keep
            // the default cursor.
            if (sidebar_menu_row_enabled[row] and rectContainsPoint(sidebar_menu_row_rects[row], x, y)) return true;
        }
    }
    if (!rectContainsPoint(palette_sidebar_rect, x, y)) return false;
    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        if (rectContainsPoint(palette_hits[index].rect, x, y)) return true;
    }
    return false;
}

/// Captured pane-row drags keep a move/grab cursor until mouse release, even
/// after the pointer leaves the sidebar. SDL's system cursor set exposes
/// `move` as the platform-native grab equivalent.
pub fn systemCursorAt(x: f32, y: f32) ?sdl.SystemCursor {
    _ = x;
    _ = y;
    if (pane_row_drag.pending or pane_row_drag.active) return .move;
    return null;
}

pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32) void {
    if (state.isSidebarHidden()) {
        const reveal = x <= theme.scaledUi(HIDDEN_SIDEBAR_EDGE_REVEAL_CSS) or rectContainsPoint(palette_sidebar_rect, x, y);
        state.setSidebarHoverRevealed(reveal);
    }

    updatePaneRowDrag(state, x, y);

    var new_new_thread_hover: ?usize = null;
    var new_terminal_hover: ?usize = null;
    var new_search_hover = false;
    var new_switcher_hover = false;
    var new_settings_hover = false;
    var new_add_workspace_hover = false;
    if (rectContainsPoint(palette_sidebar_rect, x, y)) {
        // Walk hits in reverse so later (visually-topmost) rows win when
        // overlapping during scroll edge cases.
        var index = palette_hit_count;
        while (index > 0) {
            index -= 1;
            const hit = palette_hits[index];
            if (!rectContainsPoint(hit.rect, x, y)) continue;
            switch (hit.kind) {
                .new_thread => {
                    if (new_new_thread_hover == null) new_new_thread_hover = hit.project_index;
                },
                .new_terminal => {
                    if (new_terminal_hover == null) new_terminal_hover = hit.project_index;
                },
                .workspace_switcher => new_switcher_hover = true,
                .add_workspace => new_add_workspace_hover = true,
                .command_palette => new_search_hover = true,
                .settings => new_settings_hover = true,
                else => {},
            }
        }
    }

    const new_thread_changed = state.sidebar_new_thread_hover != new_new_thread_hover;
    const terminal_changed = terminal_action_hovered != new_terminal_hover;
    const search_changed = search_trigger_hovered != new_search_hover;
    const switcher_changed = switcher_trigger_hovered != new_switcher_hover;
    const settings_changed = settings_hovered != new_settings_hover;
    const add_workspace_changed = add_workspace_hovered != new_add_workspace_hover;
    add_workspace_hovered = new_add_workspace_hover;
    terminal_action_hovered = new_terminal_hover;
    search_trigger_hovered = new_search_hover;
    switcher_trigger_hovered = new_switcher_hover;
    settings_hovered = new_settings_hover;
    if (!new_thread_changed and !terminal_changed and !search_changed and !switcher_changed and !settings_changed and !add_workspace_changed) return;

    state.sidebar_new_thread_hover = new_new_thread_hover;
    state.markDirty();
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) {
        if (pane_row_drag.pending or pane_row_drag.active) return finishPaneRowDrag(state, x, y);
        return rectContainsPoint(palette_sidebar_rect, x, y) or (state.sidebar_context_menu_open and rectContainsPoint(sidebar_menu_panel_rect, x, y));
    }

    if (state.sidebar_context_menu_open and handleSidebarContextMenuPrimary(state, x, y)) {
        return true;
    }

    if (!rectContainsPoint(palette_sidebar_rect, x, y)) return false;

    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_hits[index];
        if (!rectContainsPoint(hit.rect, x, y)) continue;

        switch (hit.kind) {
            // A hover-revealed rail is hidden: the toggle pins it open.
            .collapse => state.toggleSidebarHidden(),
            .workspace_switcher => state.openWorkspaceSwitcher(),
            .add_workspace => state.openWorkspaceCreator(true),
            .new_thread => {
                if (state.project_controller.projects.items.len > 0) state.createThreadForProject(@min(hit.project_index, state.project_controller.projects.items.len - 1));
            },
            .new_terminal => {
                if (hit.project_index < state.project_controller.projects.items.len) _ = state.openTerminalPaneForProjectIndex(hit.project_index);
            },
            .open_pane => {
                state.focusWorkspaceOpenPaneFromSidebar(hit.project_index, @intCast(hit.thread_index));
            },
            .open_pane_reorder => {
                startPaneRowDrag(state, hit.project_index, @intCast(hit.thread_index), x, y);
            },
            .command_palette => {
                state.openCommandPalette(null);
            },
            .settings => {
                state.openSettingsModal();
            },
        }
        return true;
    }
    return true;
}

pub fn handlePaletteWheel(x: f32, y: f32, wheel_y: f32) bool {
    if (wheel_y == 0.0 or !rectContainsPoint(palette_sidebar_rect, x, y)) return false;
    const step = wheel_y * theme.scaledUi(64.0);
    // Overflowing ACTIVE rows own the wheel while the pointer is inside the
    // pinned cluster so that motion cannot steal the workspace tree's scroll.
    if (attention_max_scroll_y > 1.0 and rectContainsPoint(attention_clip, x, y)) {
        attention_scroll_y = theme.clampf(attention_scroll_y - step, 0.0, attention_max_scroll_y);
        return true;
    }
    sidebar_scroll_y = theme.clampf(sidebar_scroll_y - step, 0.0, sidebar_max_scroll_y);
    return true;
}

/// SDL mouse button id for right-click (`SDL_BUTTON_RIGHT`).
pub const palette_mouse_button_secondary: u8 = 3;

pub fn handlePaletteSecondaryMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) return false;
    if (!rectContainsPoint(palette_sidebar_rect, x, y)) return false;

    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_hits[index];
        if (!rectContainsPoint(hit.rect, x, y)) continue;

        switch (hit.kind) {
            .new_thread => {
                state.workspace_header_open_menu_open = false;
                state.sidebar_context_menu_anchor_x = x;
                state.sidebar_context_menu_anchor_y = y;
                state.sidebar_context_menu_project_index = hit.project_index;
                state.sidebar_context_menu_thread_index = 0;
                state.sidebar_context_menu_kind = .project_new_thread;
                state.sidebar_context_menu_open = true;
                state.blurPaletteComposer();
                state.noteInteraction();
                state.markDirty();
                return true;
            },
            .workspace_switcher => {
                if (hit.project_index >= state.project_controller.projects.items.len) return true;
                state.workspace_header_open_menu_open = false;
                state.sidebar_context_menu_anchor_x = x;
                state.sidebar_context_menu_anchor_y = y;
                state.sidebar_context_menu_project_index = hit.project_index;
                state.sidebar_context_menu_thread_index = 0;
                state.sidebar_context_menu_kind = .project;
                state.sidebar_context_menu_open = true;
                state.blurPaletteComposer();
                state.noteInteraction();
                state.markDirty();
                return true;
            },
            .open_pane, .open_pane_reorder => {
                if (openPaneChatThreadIndex(state, hit.project_index, @intCast(hit.thread_index))) |thread_index| {
                    state.workspace_header_open_menu_open = false;
                    state.sidebar_context_menu_anchor_x = x;
                    state.sidebar_context_menu_anchor_y = y;
                    state.sidebar_context_menu_project_index = hit.project_index;
                    state.sidebar_context_menu_thread_index = thread_index;
                    state.sidebar_context_menu_kind = .thread;
                    state.sidebar_context_menu_open = true;
                    state.blurPaletteComposer();
                    state.noteInteraction();
                    state.markDirty();
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

pub fn renderFloatingDragPreview(state: *runtime.AppState) void {
    renderPaneRowDragOverlay(state);
}

pub fn hasActiveThreadDrag() bool {
    return pane_row_drag.pending or pane_row_drag.active;
}

pub fn finishThreadDragIfMouseReleased(state: *runtime.AppState, x: f32, y: f32, buttons: sdl.MouseButtonFlags) bool {
    if (pane_row_drag.pending or pane_row_drag.active) {
        if (buttons.left != 0) return false;
        return finishPaneRowDrag(state, x, y);
    }
    return false;
}

fn updatePaneRowDrag(state: *runtime.AppState, x: f32, y: f32) void {
    if (!pane_row_drag.pending and !pane_row_drag.active) return;
    pane_row_drag.x = x;
    pane_row_drag.y = y;
    if (pane_row_drag.pending) {
        const dx = x - pane_row_drag.start_x;
        const dy = y - pane_row_drag.start_y;
        const threshold = theme.scaledUi(THREAD_DRAG_THRESHOLD_CSS);
        if (dx * dx + dy * dy >= threshold * threshold) {
            pane_row_drag.pending = false;
            pane_row_drag.active = true;
        }
    }
    if (pane_row_drag.active) {
        if (!computePaneMoveTarget(state, x, y)) computePaneDropTarget(state, y);
    }
    state.markDirty();
}

/// A dragged chat row over another workspace's OPEN rows (All Workspaces
/// scope) targets that workspace. Returns true when a move target is set;
/// reorder is then off. The highlight spans the target's visible rows.
fn computePaneMoveTarget(state: *const runtime.AppState, x: f32, y: f32) bool {
    pane_drop_target_project = null;
    const source = pane_row_drag.project_index;
    if (openPaneChatThreadIndex(state, source, pane_row_drag.pane_id) == null) return false;
    var index = palette_hit_count;
    const target_hit = while (index > 0) {
        index -= 1;
        const hit = palette_hits[index];
        if (hit.project_index == source or !rectContainsPoint(hit.rect, x, y)) continue;
        if (hit.kind == .open_pane_reorder) break hit;
    } else return false;
    const target = target_hit.project_index;
    if (target >= state.project_controller.projects.items.len) return false;
    if (state.project_controller.projects.items[target].herdr_link != null) return false;
    if (open_rows_recency_sorted) {
        // Recency-interleaved rows: a union would span other workspaces'
        // rows, so highlight only the hovered target row.
        pane_drop_target_rect = target_hit.rect;
        pane_drop_target_project = target;
        pane_drop_valid = false;
        return true;
    }
    var bounds: ?palette.Rect = null;
    index = 0;
    while (index < palette_hit_count) : (index += 1) {
        const hit = palette_hits[index];
        if (hit.project_index != target or hit.kind != .open_pane_reorder) continue;
        bounds = if (bounds) |b| unionRects(b, hit.rect) else hit.rect;
    }
    pane_drop_target_rect = bounds orelse return false;
    pane_drop_target_project = target;
    pane_drop_valid = false;
    return true;
}

fn unionRects(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Finds the insertion slot among the visible rows of the dragged pane's
/// owning workspace. Attention-cluster duplicates are deliberately excluded.
fn computePaneDropTarget(state: *const runtime.AppState, y: f32) void {
    pane_drop_valid = false;
    // Recency order is not layout order; in-place reorder has no meaning there.
    if (open_rows_recency_sorted) return;
    if (pane_row_drag.project_index >= state.project_controller.projects.items.len) return;
    const layout = &state.project_controller.projects.items[pane_row_drag.project_index].workspace_layout;
    var index: usize = 0;
    while (index < palette_hit_count) : (index += 1) {
        const hit = palette_hits[index];
        if (hit.kind != .open_pane_reorder or hit.project_index != pane_row_drag.project_index) continue;
        const r = hit.rect;
        const row_index = layout.paneIndexById(@intCast(hit.thread_index)) orelse continue;
        pane_drop_line_rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = theme.scaledUi(2.0) };
        if (y < r.y + r.h * 0.5) {
            pane_drop_before = row_index;
            pane_drop_valid = true;
            return;
        }
        pane_drop_before = row_index + 1;
        pane_drop_line_rect.y = r.y + r.h;
        pane_drop_valid = true;
    }
}

fn startPaneRowDrag(state: *runtime.AppState, project_index: usize, pane_id: native_state.WorkspacePaneId, x: f32, y: f32) void {
    if (project_index >= state.project_controller.projects.items.len) return;
    const layout = &state.project_controller.projects.items[project_index].workspace_layout;
    _ = layout.paneById(pane_id) orelse return;
    pane_drop_valid = false;
    pane_drop_target_project = null;
    pane_row_drag = .{
        .pending = true,
        .project_index = project_index,
        .pane_id = pane_id,
        .start_x = x,
        .start_y = y,
        .x = x,
        .y = y,
    };
    _ = sdl.captureMouse(true);
    state.markDirty();
}

fn finishPaneRowDrag(state: *runtime.AppState, x: f32, y: f32) bool {
    _ = x;
    _ = y;
    const drag = pane_row_drag;
    pane_row_drag = .{};
    _ = sdl.captureMouse(false);
    const move_target = pane_drop_target_project;
    pane_drop_target_project = null;

    if (!drag.active) {
        state.focusWorkspaceOpenPaneFromSidebar(drag.project_index, drag.pane_id);
    } else if (move_target) |target| {
        _ = state.moveChatPaneToProject(drag.project_index, drag.pane_id, target);
    } else if (pane_drop_valid) {
        _ = state.moveWorkspacePaneInSidebarOrder(drag.project_index, drag.pane_id, pane_drop_before);
    }
    pane_drop_valid = false;
    state.markDirty();
    return true;
}

// Renders the pane-row insertion marker and floating drag preview.
fn renderPaneRowDragOverlay(state: *runtime.AppState) void {
    if (!pane_row_drag.active) return;
    if (pane_row_drag.project_index >= state.project_controller.projects.items.len) return;
    const project = &state.project_controller.projects.items[pane_row_drag.project_index];
    const pane = project.workspace_layout.paneById(pane_row_drag.pane_id) orelse return;

    const previous_z = state.palette_overlay_batch.setZIndex(THREAD_DRAG_FLOATING_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    if (pane_drop_target_project != null) {
        const radius = theme.scaledUi(6.0);
        queuePaletteRoundedRect(state, pane_drop_target_rect, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 40)), radius);
        queuePaletteBorder(state, pane_drop_target_rect, paletteColor(theme.COLOR_GREEN), radius, theme.scaledUi(1.5));
    } else if (pane_drop_valid) {
        queuePaletteRoundedRect(state, .{
            .x = pane_drop_line_rect.x,
            .y = pane_drop_line_rect.y - pane_drop_line_rect.h * 0.5,
            .w = pane_drop_line_rect.w,
            .h = pane_drop_line_rect.h,
        }, paletteColor(theme.COLOR_GREEN), pane_drop_line_rect.h * 0.5);
    }

    const w = theme.scaledUi(200.0);
    const h = theme.scaledUi(30.0);
    const rect: palette.Rect = .{
        .x = pane_row_drag.x + theme.scaledUi(12.0),
        .y = pane_row_drag.y + theme.scaledUi(8.0),
        .w = w,
        .h = h,
    };
    queuePaletteRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 232)), theme.scaledUi(8.0));
    queuePaletteBorder(state, rect, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 180)), theme.scaledUi(8.0), theme.scaledUi(1.0));
    const font = theme.scaledUi(13.5);
    var term_title_buf: TerminalTitleBuffer = undefined;
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(12.0),
        .y = rect.y + (rect.h - font * 1.25) * 0.5,
        .w = rect.w - theme.scaledUi(20.0),
        .h = font * 1.25,
    }, paneTitle(state, pane_row_drag.project_index, project, pane, &term_title_buf), paletteColor(theme.COLOR_WHITE), font, rect);
}

/// Scratch for `Dock.activeProcessLabel`, sized to its buffer contract.
pub const TerminalTitleBuffer = [96]u8;

/// Short human label for a pane, shared by the sidebar rows, the pane drag
/// ghost, and the workspace tab strip: thread title, terminal title, or
/// browser tab title, with a kind-named fallback. `term_title_buf` backs the
/// terminal's live-process label when no surface title is set.
pub fn paneTitle(
    state: *const runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    pane: *const native_state.WorkspacePane,
    term_title_buf: *TerminalTitleBuffer,
) []const u8 {
    return switch (pane.ref) {
        .chat => |ref| if (ref.thread_index < project.threads.items.len) project.threads.items[ref.thread_index].title else "Chat",
        .terminal => |ref| terminalPaneTitle(state, project_index, ref.dock_id, term_title_buf),
        .browser => browserPaneTitle(pane),
        .file => |ref| std.fs.path.basename(ref.path),
    };
}

/// Terminal pane label: prefer an agent/notify-provided surface title, then
/// the terminal's live label (pinned TUI title, OSC title, or cwd), then a
/// generic fallback. Every surface that names a terminal pane must go through
/// this so the tab strip and sidebar never disagree.
fn terminalPaneTitle(
    state: *const runtime.AppState,
    project_index: usize,
    dock_id: u32,
    term_title_buf: *TerminalTitleBuffer,
) []const u8 {
    const title = blk: {
        if (state.projectTerminalSurface(project_index, dock_id)) |s| if (s.title.len > 0) break :blk s.title;
        if (state.projectTerminalDock(project_index, dock_id)) |dock| {
            const live = dock.activeProcessLabel(term_title_buf);
            if (live.len > 0) break :blk live;
        }
        break :blk "Terminal";
    };
    // Agents (e.g. Claude Code) prefix their title with a symbol marker like
    // "✳" the UI font can't render; drop it so it doesn't show as a tofu box.
    return stripLeadingTitleSymbols(title);
}

fn handleSidebarContextMenuPrimary(state: *runtime.AppState, x: f32, y: f32) bool {
    if (!state.sidebar_context_menu_open) return false;

    if (rectContainsPoint(sidebar_menu_panel_rect, x, y)) {
        const pi = state.sidebar_context_menu_project_index;
        const ti = state.sidebar_context_menu_thread_index;
        var idx = sidebar_menu_row_count;
        while (idx > 0) {
            idx -= 1;
            if (!rectContainsPoint(sidebar_menu_row_rects[idx], x, y)) continue;
            const enabled = sidebar_menu_row_enabled[idx];
            const action = sidebar_menu_row_actions[idx];
            state.closeSidebarContextMenu();
            state.workspace_header_open_menu_open = false;
            if (!enabled) return true;
            state.blurPaletteComposer();
            state.noteInteraction();
            switch (action) {
                .workspace_new_chat => {
                    if (pi < state.project_controller.projects.items.len) state.createThreadForProject(pi);
                },
                .workspace_open_codex_tui => _ = state.openAgentTui(pi, .codex) catch false,
                .workspace_open_terminal => _ = state.openTerminalPaneForProjectIndex(pi),
                .workspace_herdr_handoff => state.handoffProjectToLocalHerdrFromUi(pi),
                .workspace_herdr_focus_terminal => _ = state.focusProjectHerdrAttachTerminal(pi),
                .workspace_herdr_unlink => state.unlinkProjectHerdrFromUi(pi),
                .workspace_rename => state.beginProjectRename(pi),
                .workspace_open_settings => state.openWorkspaceSettingsForProject(pi),
                .workspace_import_codex => state.beginThreadImport(pi, .codex),
                .workspace_import_opencode => state.beginThreadImport(pi, .opencode),
                .workspace_import_claude => state.beginThreadImport(pi, .claude),
                .workspace_archive => state.closeProjectAtIndex(pi),
                .thread_open_tui => state.openThreadInTui(pi, ti),
                .thread_open_chat => state.openThreadInChat(pi, ti),
                .thread_rename => state.beginThreadRename(pi, ti),
                .thread_regenerate_title => state.regenerateThreadTitleAtIndex(pi, ti),
                .thread_sync => state.syncThreadFromProvider(pi, ti),
                .thread_handoff => {
                    if (pi < state.project_controller.projects.items.len) {
                        for (state.project_controller.projects.items[pi].workspace_layout.panes.items) |pane| {
                            switch (pane.ref) {
                                .chat => |ref| if (ref.thread_index == ti) {
                                    state.beginThreadHandoff(pi, ti, pane.id);
                                    break;
                                },
                                else => {},
                            }
                        }
                    }
                },
                .thread_close_pane => if (threadPaneId(state, pi, ti)) |pane_id| {
                    _ = state.closeWorkspacePane(pi, pane_id);
                },
            }
            return true;
        }
        state.closeSidebarContextMenu();
        state.workspace_header_open_menu_open = false;
        return true;
    }

    state.closeSidebarContextMenu();
    state.workspace_header_open_menu_open = false;
    return true;
}

fn appendSidebarContextMenuRow(action: SidebarContextMenuAction, enabled: bool, label: []const u8) void {
    if (sidebar_menu_row_count >= sidebar_menu_row_rects.len) return;
    sidebar_menu_row_actions[sidebar_menu_row_count] = action;
    sidebar_menu_row_enabled[sidebar_menu_row_count] = enabled;
    sidebar_menu_row_labels[sidebar_menu_row_count] = label;
    sidebar_menu_row_count += 1;
}

fn openTuiLabel(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Open in TUI: Codex",
        .opencode => "Open in TUI: OpenCode",
        .claude => "Open in TUI: Claude",
        .cursor => "Open in TUI: Cursor",
        .pi => "Open in TUI: Pi",
        .fx => "Open in TUI: FX",
        .grok => "Open in TUI: Grok",
        .muse => "Open in TUI: Muse",
    };
}

fn renderSidebarContextMenu(state: *runtime.AppState, sidebar_rect: palette.Rect) void {
    if (!state.sidebar_context_menu_open) return;

    const pad = theme.scaledUi(6.0);
    const menu_w = theme.scaledUi(248.0);
    const menu_pad = theme.scaledUi(context_menu.PAD_UI);
    const menu_row_h = theme.scaledUi(context_menu.ROW_HEIGHT_UI);

    sidebar_menu_row_count = 0;
    switch (state.sidebar_context_menu_kind) {
        .none => return,
        .project => {
            const pi = state.sidebar_context_menu_project_index;
            const herdr_link = if (pi < state.project_controller.projects.items.len) state.project_controller.projects.items[pi].herdr_link else null;
            appendSidebarContextMenuRow(.workspace_new_chat, true, "Start a new chat");
            appendSidebarContextMenuRow(.workspace_open_codex_tui, pi < state.project_controller.projects.items.len, "Open Codex TUI");
            appendSidebarContextMenuRow(.workspace_open_terminal, pi < state.project_controller.projects.items.len, "Open terminal");
            if (herdr_link) |link| {
                appendSidebarContextMenuRow(.workspace_herdr_focus_terminal, pi < state.project_controller.projects.items.len, if (link.attach_dock_id != null) "Focus Herdr terminal" else "Open Herdr terminal");
                appendSidebarContextMenuRow(.workspace_herdr_handoff, pi < state.project_controller.projects.items.len, "Refresh Herdr handoff");
                appendSidebarContextMenuRow(.workspace_herdr_unlink, pi < state.project_controller.projects.items.len, "Run locally (unlink Herdr)");
            } else {
                appendSidebarContextMenuRow(.workspace_herdr_handoff, pi < state.project_controller.projects.items.len, "Handoff to Herdr");
            }
            appendSidebarContextMenuRow(.workspace_rename, true, "Rename workspace");
            appendSidebarContextMenuRow(.workspace_open_settings, pi < state.project_controller.projects.items.len, "Workspace settings");
            appendSidebarContextMenuRow(.workspace_import_codex, true, "Import Codex thread");
            appendSidebarContextMenuRow(.workspace_import_opencode, true, "Import OpenCode thread");
            appendSidebarContextMenuRow(.workspace_import_claude, true, "Import Claude thread");
            var busy = false;
            if (pi < state.project_controller.projects.items.len) {
                for (state.project_controller.projects.items[pi].threads.items) |*th| {
                    if (th.isSendPendingForUi()) {
                        busy = true;
                        break;
                    }
                }
            }
            appendSidebarContextMenuRow(.workspace_archive, !busy, "Close workspace");
        },
        .project_new_thread => {
            const pi = state.sidebar_context_menu_project_index;
            appendSidebarContextMenuRow(.workspace_new_chat, pi < state.project_controller.projects.items.len, "Start a new chat");
            appendSidebarContextMenuRow(.workspace_open_codex_tui, pi < state.project_controller.projects.items.len, "Open Codex TUI");
        },
        .thread => {
            const pi = state.sidebar_context_menu_project_index;
            const ti = state.sidebar_context_menu_thread_index;
            var can_sync = false;
            var can_regenerate_title = false;
            var can_handoff = true;
            var provider: Provider = .opencode;
            var in_tui = false;
            if (pi < state.project_controller.projects.items.len) {
                const proj = state.project_controller.projects.items[pi];
                if (ti < proj.threads.items.len) {
                    const th = proj.threads.items[ti];
                    can_sync = th.provider_thread_id != null and !th.isSendPendingForUi();
                    can_regenerate_title = state.canRegenerateThreadTitle(pi, ti);
                    can_handoff = !th.isSendPendingForUi();
                    provider = th.provider;
                    in_tui = state.threadIsOpenInTui(pi, ti);
                }
            }
            appendSidebarContextMenuRow(.thread_rename, true, "Rename chat");
            appendSidebarContextMenuRow(.thread_regenerate_title, can_regenerate_title, "Regenerate title");
            appendSidebarContextMenuRow(.thread_sync, can_sync, "Sync thread");
            appendSidebarContextMenuRow(.thread_handoff, can_handoff, "Handoff to another agent");
            if (in_tui) {
                appendSidebarContextMenuRow(.thread_open_chat, true, "Open as chat");
            } else {
                appendSidebarContextMenuRow(.thread_open_tui, can_sync, openTuiLabel(provider));
            }
            appendSidebarContextMenuRow(.thread_close_pane, threadPaneId(state, pi, ti) != null, "Close pane");
        },
    }

    if (sidebar_menu_row_count == 0) return;

    const previous_z = state.palette_overlay_batch.setZIndex(SIDEBAR_CONTEXT_MENU_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    const menu_h = menu_pad * 2.0 + @as(f32, @floatFromInt(sidebar_menu_row_count)) * menu_row_h;
    var menu_x = state.sidebar_context_menu_anchor_x;
    var menu_y = state.sidebar_context_menu_anchor_y;
    menu_x = theme.clampf(menu_x, sidebar_rect.x + pad, sidebar_rect.x + sidebar_rect.w - menu_w - pad);
    menu_y = theme.clampf(menu_y, sidebar_rect.y + pad, sidebar_rect.y + sidebar_rect.h - menu_h - pad);

    sidebar_menu_panel_rect = context_menu.queuePanel(state, .{ .x = menu_x, .y = menu_y, .w = menu_w, .h = menu_h });
    const clip = sidebar_menu_panel_rect;

    const mx = state.transcript_controller.palette_mouse_x;
    const my = state.transcript_controller.palette_mouse_y;
    const mouse_ok = state.transcript_controller.palette_mouse_in_workspace;

    var ry = sidebar_menu_panel_rect.y + menu_pad;
    var ri: usize = 0;
    while (ri < sidebar_menu_row_count) : (ri += 1) {
        const rr: palette.Rect = .{
            .x = sidebar_menu_panel_rect.x + menu_pad,
            .y = ry,
            .w = sidebar_menu_panel_rect.w - menu_pad * 2.0,
            .h = menu_row_h,
        };
        sidebar_menu_row_rects[ri] = rr;

        const row_hover = mouse_ok and sidebar_menu_row_enabled[ri] and rectContainsPoint(rr, mx, my);
        if (row_hover) context_menu.queueRowHighlight(state, rr);
        context_menu.queueLabel(state, rr, sidebar_menu_row_labels[ri], context_menu.labelColor(sidebar_menu_row_enabled[ri], row_hover), 0.0, 0.0, clip);

        ry += menu_row_h;
    }
}

/// Expanded workspace rail: one compact pinned header row, a pinned
/// "ACTIVE" attention cluster, then an independently scrolling workspace
/// tree. Only the selected workspace expands its pane list; the others stay
/// one header row tall and surface live work through the cluster. The cluster
/// stays visible while the tree scrolls, and overflows internally after
/// ~10 rows so a busy machine cannot bury the tree.
fn renderPaletteExpandedSidebar(state: *runtime.AppState, rect: palette.Rect) void {
    const pad_x = theme.scaledUi(SIDEBAR_PAD_X_CSS);
    const rail_w = @max(rect.w - pad_x * 2.0, theme.scaledUi(140.0));
    const x = rect.x + pad_x;
    const projects = state.project_controller.projects.items;
    const selected_index = state.project_controller.selected_index;
    const has_selected = selected_index < projects.len;
    // Feed switcher recency: the selected workspace is the one in use.
    if (has_selected) workspace_identity.noteUsed(projects[selected_index].id, unixTimestampMs());
    const all_scope = state.sidebar_all_workspaces or !has_selected;
    open_rows_show_chip = all_scope;
    open_rows_recency_sorted = all_scope;

    // Pinned chrome, top to bottom: header (logo + toggle), workspace
    // switcher trigger, search pill with new chat / new terminal buttons.
    // Chrome paints AFTER the list (over a panel strip) so rows scrolled into
    // the band are covered — no z-index plumbing required.
    const header_top = rect.y + theme.scaledUi(14.0);
    const header_h = theme.scaledUi(32.0);
    const switcher_h = theme.scaledUi(34.0);
    const switcher_top = header_top + header_h + theme.scaledUi(8.0);
    const search_h = theme.scaledUi(30.0);
    const search_top = switcher_top + switcher_h + theme.scaledUi(6.0);
    const list_top = search_top + search_h + theme.scaledUi(12.0);
    // Reserve a band at the bottom of the rail for the sticky footer; the list
    // clip stops here so `sidebar_max_scroll_y` rests above it.
    const footer_reserve = theme.scaledUi(SIDEBAR_FOOTER_RESERVE_CSS);
    const list_bottom = @max(rect.y + rect.h - footer_reserve, list_top);
    const available_list_h = @max(list_bottom - list_top, 0.0);

    var cluster_rows: [palette_hits.len]AttentionClusterRow = undefined;
    const cluster_row_count = collectAttentionClusterRows(state, &cluster_rows);
    if (cluster_row_count > 0) sortAttentionClusterRows(cluster_rows[0..cluster_row_count]);
    const cluster_layout = attentionClusterLayoutForRail(cluster_row_count, available_list_h);
    const motion_t = attentionMotionStep(state);
    attention_clip = .{
        .x = rect.x,
        .y = list_top,
        .w = rect.w,
        .h = easedAttentionViewportH(cluster_layout.viewport_h, motion_t),
    };

    // OPEN section: the scoped workspace's panes, or every open workspace's
    // panes under All Workspaces. No workspace folder rows.
    const open_top = list_top + cluster_layout.viewport_h;
    const open_clip: palette.Rect = .{
        .x = rect.x,
        .y = open_top,
        .w = rect.w,
        .h = @max(list_bottom - open_top, 0.0),
    };
    const caption_h = theme.scaledUi(SIDEBAR_ACTIVE_LABEL_H_CSS);
    // The OPEN caption stays pinned at the top of the band; only the rows
    // beneath it scroll, clipped so they slide under the caption.
    const rows_clip: palette.Rect = .{
        .x = open_clip.x,
        .y = open_clip.y + caption_h,
        .w = open_clip.w,
        .h = @max(open_clip.h - caption_h, 0.0),
    };
    const focused_pane_id = if (has_selected) projects[selected_index].workspace_layout.focused_pane_id else null;
    const focus_changed = sidebar_revealed_project_index != selected_index or
        sidebar_revealed_pane_id != focused_pane_id or sidebar_revealed_view_h != open_clip.h;
    // One ordered list drives measuring, focus reveal, and rendering, so the
    // three passes cannot disagree about row positions.
    const open_units = collectOpenUnits(state, all_scope);
    var content_y = open_top + caption_h;
    var focused_row: ?palette.Rect = null;
    for (open_units) |unit| {
        const unit_h = openUnitHeight(&projects[unit.project_index].workspace_layout, unit.pane_index);
        if (unit.project_index == selected_index and focused_pane_id != null and
            openUnitContainsPane(&projects[unit.project_index].workspace_layout, unit.pane_index, focused_pane_id.?))
        {
            focused_row = .{ .x = 0.0, .y = content_y, .w = 0.0, .h = unit_h.row };
        }
        content_y += unit_h.step;
    }
    if (open_units.len > 0) content_y += theme.scaledUi(4.0);
    sidebar_max_scroll_y = @max(0.0, content_y - (open_clip.y + open_clip.h) + theme.scaledUi(8.0));
    sidebar_scroll_y = theme.clampf(sidebar_scroll_y, 0.0, sidebar_max_scroll_y);
    if (focus_changed) {
        if (focused_row) |row| {
            sidebar_scroll_y = revealSidebarRow(sidebar_scroll_y, row.y, row.h, rows_clip, sidebar_max_scroll_y);
        }
        sidebar_revealed_project_index = selected_index;
        sidebar_revealed_pane_id = focused_pane_id;
        sidebar_revealed_view_h = open_clip.h;
    }

    var y = open_top + caption_h - sidebar_scroll_y;
    const rows_top = y;
    const selected_tabs: []const native_state.WorkspaceTab = if (has_selected) blk: {
        const layout = &projects[selected_index].workspace_layout;
        const buf = state.palette_frame_text_arena.allocator().alloc(native_state.WorkspaceTab, layout.panes.items.len) catch break :blk &.{};
        break :blk native_state.workspace_tabs.collect(layout, buf);
    } else &.{};
    const row_ordinals = allWorkspacesOrderActive(state);
    for (open_units, 0..) |unit, ordinal| {
        y = renderOpenPaneUnit(state, unit, selected_tabs, if (row_ordinals) ordinal else null, x, rail_w, rows_clip, rows_clip, y);
    }
    if (open_units.len > 0) y += theme.scaledUi(4.0);
    if (y == rows_top) {
        queuePaletteText(state, .{ .x = x + theme.scaledUi(4.0), .y = y + theme.scaledUi(4.0), .w = rail_w, .h = theme.scaledUi(18.0) }, "No open panes", paletteColor(theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 190)), theme.scaledUi(12.5), rows_clip);
    }

    // Scrollbar clips to the OPEN band so the thumb never extends behind the
    // pinned ACTIVE cluster or chrome drawn below.
    sidebar_max_scroll_y = @max(0.0, y + sidebar_scroll_y - (open_clip.y + open_clip.h) + theme.scaledUi(8.0));
    sidebar_scroll_y = theme.clampf(sidebar_scroll_y, 0.0, sidebar_max_scroll_y);
    renderSidebarOverflowScrollbar(state, rows_clip, sidebar_scroll_y, sidebar_max_scroll_y);

    // Pinned OPEN caption, painted after the rows over a panel strip so a
    // row scrolled up under it is covered (same approach as the chrome).
    if (caption_h > 0.0 and open_clip.h > 0.0) {
        queuePaletteRect(state, .{ .x = rect.x, .y = open_top, .w = rect.w - theme.scaledUi(1.0), .h = @min(caption_h, open_clip.h) }, paletteColor(theme.COLOR_PANEL));
        queuePaletteText(state, .{ .x = x, .y = open_top, .w = rail_w, .h = theme.scaledUi(18.0) }, "OPEN", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), open_clip);
    }

    // Pinned footer band with the global settings gear.
    if (list_bottom < rect.y + rect.h) {
        const footer_rect: palette.Rect = .{
            .x = rect.x,
            .y = list_bottom,
            .w = rect.w - theme.scaledUi(1.0),
            .h = rect.y + rect.h - list_bottom,
        };
        queuePaletteRect(state, footer_rect, paletteColor(theme.COLOR_PANEL));
        queuePaletteRect(state, .{
            .x = rect.x,
            .y = list_bottom,
            .w = rect.w - theme.scaledUi(1.0),
            .h = theme.scaledUi(1.0),
        }, paletteColor(theme.borderMuted()));

        const btn = theme.scaledUi(34.0);
        const btn_rect: palette.Rect = .{
            .x = rect.x + rect.w - pad_x - btn,
            .y = footer_rect.y + (footer_rect.h - btn) * 0.5,
            .w = btn,
            .h = btn,
        };
        renderPaletteSettingsButton(state, btn_rect, footer_rect);
    }

    // Pin ACTIVE after the OPEN list so any row scrolled into the cluster
    // band is covered.
    if (attention_clip.h > 0.0) {
        queuePaletteRect(state, .{
            .x = attention_clip.x,
            .y = attention_clip.y,
            .w = attention_clip.w - theme.scaledUi(1.0),
            .h = attention_clip.h,
        }, paletteColor(theme.COLOR_PANEL));
        renderAttentionClusterSection(state, x, rail_w, cluster_rows[0..cluster_row_count], attention_clip, motion_t);
    }
    pruneActiveRowSlots();

    // Pinned chrome, painted last.
    queuePaletteRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w - theme.scaledUi(1.0), .h = list_top - rect.y }, paletteColor(theme.COLOR_PANEL));
    const logo = theme.scaledUi(28.0);
    queuePaletteLogoMark(state, .{ .x = x, .y = header_top + (header_h - logo) * 0.5, .w = logo, .h = logo });
    const btn_w = theme.scaledUi(28.0);
    const toggle_rect: palette.Rect = .{ .x = rect.x + rect.w - pad_x - btn_w, .y = header_top + (header_h - btn_w) * 0.5, .w = btn_w, .h = btn_w };
    renderPaletteSidebarToggle(state, toggle_rect, !state.isSidebarHidden());

    // Switcher trigger with a trailing "+" (new workspace). The button shares
    // the action column below so it sits directly above the terminal button.
    const action_w = theme.scaledUi(30.0);
    const action_gap = theme.scaledUi(2.0);
    const add_gap = theme.scaledUi(6.0);
    renderWorkspaceSwitcherTrigger(state, .{ .x = x, .y = switcher_top, .w = rail_w - action_w - add_gap, .h = switcher_h }, if (all_scope) null else selected_index);
    const add_rect: palette.Rect = .{ .x = x + rail_w - action_w, .y = switcher_top + (switcher_h - action_w) * 0.5, .w = action_w, .h = action_w };
    renderPaletteSidebarActionIcon(state, add_rect, NF_COD_ADD, add_workspace_hovered, rect);
    addPaletteHit(add_rect, .add_workspace, 0, 0);

    // Search pill + new chat / new terminal. Under All Workspaces they target
    // the selected (= most recently used) workspace.
    const actions_w = if (has_selected) action_w * 2.0 + action_gap + theme.scaledUi(6.0) else 0.0;
    renderPaletteSearchTrigger(state, .{ .x = x, .y = search_top, .w = rail_w - actions_w, .h = search_h });
    if (has_selected) {
        const new_rect: palette.Rect = .{ .x = x + rail_w - action_w * 2.0 - action_gap, .y = search_top, .w = action_w, .h = search_h };
        const terminal_rect: palette.Rect = .{ .x = x + rail_w - action_w, .y = search_top, .w = action_w, .h = search_h };
        renderPaletteSidebarActionIcon(state, new_rect, NF_COD_EDIT, state.sidebar_new_thread_hover == selected_index, rect);
        addPaletteHit(new_rect, .new_thread, selected_index, 0);
        renderPaletteSidebarActionIcon(state, terminal_rect, NF_COD_TERMINAL, terminal_action_hovered == selected_index, rect);
        addPaletteHit(terminal_rect, .new_terminal, selected_index, 0);
    }
}

/// Workspace switcher trigger: scope chip, scope label, Herdr badge, chevron.
/// `scope == null` is All Workspaces. Click opens the switcher popover;
/// right-click opens the selected workspace's context menu.
fn renderWorkspaceSwitcherTrigger(state: *runtime.AppState, rect: palette.Rect, scope: ?usize) void {
    workspace_switcher_anchor = rect;
    const open = state.command_controller.open and state.command_controller.mode == .workspaces;
    const hovered = switcher_trigger_hovered or open;
    const radius = theme.scaledUi(7.0);
    // No resting chrome: the trigger sits flush on the rail and only shows
    // the accent wash on hover / while the switcher is open.
    if (hovered) queuePaletteRoundedRect(state, snapRect(rect), paletteColor(theme.wash(theme.COLOR_GREEN, 48)), radius);
    addPaletteHit(rect, .workspace_switcher, state.project_controller.selected_index, 0);

    const projects = state.project_controller.projects.items;
    const chip = theme.scaledUi(22.0);
    const cy = rect.y + rect.h * 0.5;
    const chip_rect: palette.Rect = .{ .x = rect.x + theme.scaledUi(6.0), .y = cy - chip * 0.5, .w = chip, .h = chip };
    const project: ?*const native_state.Project = if (scope) |pi| (if (pi < projects.len) &projects[pi] else null) else null;
    queueWorkspaceChip(state, chip_rect, project, false, rect);

    const chevron_x = rect.x + rect.w - theme.scaledUi(18.0);
    var label_right = chevron_x - theme.scaledUi(6.0);
    if (project) |p| {
        if (herdrRuntimeBadgeLabel(p)) |badge| {
            const badge_w = theme.scaledUi(SIDEBAR_HERDR_BADGE_W_CSS);
            label_right -= badge_w;
            renderHerdrRuntimeBadge(state, .{ .x = label_right, .y = rect.y + theme.scaledUi(8.0), .w = badge_w, .h = rect.h - theme.scaledUi(16.0) }, badge, hovered, rect);
            label_right -= theme.scaledUi(6.0);
        }
    }
    var shortcut_buf: [16]u8 = undefined;
    const shortcut = if (state.alt_shortcut_hints_visible)
        if (state.command_controller.keyboard_config) |config|
            keybinds.formatAltKeyTipAt(&shortcut_buf, config.workspace_show_all, 0)
        else
            ""
    else
        "";
    const label = if (project) |p| p.label else "All Workspaces";
    const label_x = chip_rect.x + chip + theme.scaledUi(10.0);
    const font = theme.scaledUi(14.0);
    queuePaletteText(state, .{
        .x = label_x,
        .y = @round(cy - font * 0.65),
        .w = @max(label_right - label_x, theme.scaledUi(24.0)),
        .h = font * 1.3,
    }, label, paletteColor(if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), font, rect);
    if (shortcut.len > 0) {
        renderSidebarShortcutKeyTip(state, rect, rect, shortcut);
    } else {
        queuePaletteChevron(state, chevron_x, cy, if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE, false);
    }
}

/// One OPEN-list entry: a standalone pane or a whole split tile, addressed
/// by the first pane of its scroll group in persisted pane order.
const OpenUnit = struct {
    project_index: usize,
    pane_index: usize,
    /// Latest activity across the unit's panes (unix ms); orders All Workspaces.
    recency_ms: i64,
};

/// OPEN units in display order. A single-workspace scope keeps layout order;
/// All Workspaces interleaves every workspace's units newest-activity first
/// (stable, so ties keep workspace + layout order).
fn collectOpenUnits(state: *runtime.AppState, all_scope: bool) []OpenUnit {
    const projects = state.project_controller.projects.items;
    const selected_index = state.project_controller.selected_index;
    var total: usize = 0;
    for (projects, 0..) |*project, index| {
        if (!all_scope and index != selected_index) continue;
        total += project.workspace_layout.panes.items.len;
    }
    const units = state.palette_frame_text_arena.allocator().alloc(OpenUnit, total) catch return &.{};
    var count: usize = 0;
    for (projects, 0..) |*project, project_index| {
        if (!all_scope and project_index != selected_index) continue;
        const layout = &project.workspace_layout;
        for (layout.panes.items, 0..) |pane, pane_index| {
            if (!isOpenUnitHead(layout, pane_index)) continue;
            const group_id = layout.scrollGroupIdForPane(pane.id).?;
            var recency: i64 = 0;
            for (layout.panes.items) |*member| {
                if (layout.scrollGroupIdForPane(member.id) != group_id) continue;
                recency = @max(recency, paneRecencyMs(state, project_index, project, member));
            }
            units[count] = .{ .project_index = project_index, .pane_index = pane_index, .recency_ms = recency };
            count += 1;
        }
    }
    const result = units[0..count];
    if (all_scope) std.sort.insertion(OpenUnit, result, {}, openUnitNewerFirst);
    return result;
}

fn openUnitNewerFirst(_: void, a: OpenUnit, b: OpenUnit) bool {
    return a.recency_ms > b.recency_ms;
}

/// True while the visible sidebar lists every workspace. Keyboard ordinals
/// (Ctrl+N) and tab-to-tab navigation then follow the sidebar's displayed
/// cross-workspace order instead of the selected workspace's layout order,
/// so what you press matches what you see.
pub fn allWorkspacesOrderActive(state: *const runtime.AppState) bool {
    return state.sidebar_all_workspaces and !state.isSidebarHidden() and state.project_controller.projects.items.len > 0;
}

fn focusOpenUnit(state: *runtime.AppState, unit: OpenUnit) bool {
    const layout = &state.project_controller.projects.items[unit.project_index].workspace_layout;
    const group_id = layout.scrollGroupIdForPane(layout.panes.items[unit.pane_index].id) orelse return false;
    return state.selectWorkspaceTab(unit.project_index, group_id);
}

/// Index of the unit holding the focused pane of the selected workspace.
fn focusedOpenUnitIndex(state: *runtime.AppState, units: []const OpenUnit) ?usize {
    const projects = state.project_controller.projects.items;
    const selected = state.project_controller.selected_index;
    if (selected >= projects.len) return null;
    const layout = &projects[selected].workspace_layout;
    const focused = layout.focused_pane_id orelse return null;
    for (units, 0..) |unit, index| {
        if (unit.project_index == selected and openUnitContainsPane(layout, unit.pane_index, focused)) return index;
    }
    return null;
}

/// Ctrl+1…Ctrl+0 / `pane_select`: the N-th row of the sidebar under All
/// Workspaces, else the N-th tab of the selected workspace.
pub fn selectOpenRowAtOrdinal(state: *runtime.AppState, ordinal: usize) bool {
    if (!allWorkspacesOrderActive(state)) return state.selectWorkspaceTabAtIndex(ordinal);
    const units = collectOpenUnits(state, true);
    if (ordinal >= units.len) return false;
    return focusOpenUnit(state, units[ordinal]);
}

/// Steps focus to the previous/next sidebar row under All Workspaces,
/// crossing into other workspaces. Returns false outside that scope (or at
/// an end without `wrap`) so callers can fall back to their own order.
/// `wrap` cycles past either end (Ctrl+Tab) instead of stopping (hjkl).
pub fn focusAdjacentOpenRow(state: *runtime.AppState, forward: bool, wrap: bool) bool {
    if (!allWorkspacesOrderActive(state)) return false;
    const units = collectOpenUnits(state, true);
    if (units.len == 0) return false;
    const current = focusedOpenUnitIndex(state, units) orelse return focusOpenUnit(state, units[0]);
    const target = if (forward)
        (if (current + 1 < units.len) current + 1 else if (wrap) 0 else return false)
    else
        (if (current > 0) current - 1 else if (wrap) units.len - 1 else return false);
    if (target == current) return false;
    return focusOpenUnit(state, units[target]);
}

/// Last activity of one pane in unix ms: a chat's last turn activity, or a
/// terminal's last status change. Browsers carry no activity signal.
fn paneRecencyMs(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    pane: *const native_state.WorkspacePane,
) i64 {
    return switch (pane.ref) {
        .chat => |ref| if (ref.thread_index < project.threads.items.len)
            project.threads.items[ref.thread_index].last_activity_at *| std.time.ms_per_s
        else
            0,
        .terminal => |ref| if (state.projectTerminalSurface(project_index, ref.dock_id)) |surface|
            surface.status_changed_at_ms
        else
            0,
        .browser, .file => 0,
    };
}

/// True for a rooted pane that is the first of its scroll group (tile).
fn isOpenUnitHead(layout: *const native_state.WorkspaceLayout, pane_index: usize) bool {
    const pane = layout.panes.items[pane_index];
    // Side-panel browsers belong to their tab, not the OPEN list; listing
    // them would also let Ctrl+N/Ctrl+Tab focus a hidden page.
    if (layout.isDockedPane(pane.id)) return false;
    const group_id = layout.scrollGroupIdForPane(pane.id) orelse return false;
    if (layout.scrollGroupPaneCount(group_id) <= 1) return true;
    if (layout.root == null) return false;
    for (layout.panes.items[0..pane_index]) |earlier| {
        if (layout.scrollGroupIdForPane(earlier.id) == group_id) return false;
    }
    return true;
}

fn openUnitContainsPane(layout: *const native_state.WorkspaceLayout, pane_index: usize, pane_id: native_state.WorkspacePaneId) bool {
    const group_id = layout.scrollGroupIdForPane(layout.panes.items[pane_index].id) orelse return false;
    return layout.scrollGroupIdForPane(pane_id) == group_id;
}

const OpenUnitHeight = struct { row: f32, step: f32 };

/// Drawn height and vertical advance of one OPEN unit.
fn openUnitHeight(layout: *const native_state.WorkspaceLayout, pane_index: usize) OpenUnitHeight {
    const row_h = theme.scaledUi(SIDEBAR_THREAD_ROW_HEIGHT_CSS);
    const group_id = layout.scrollGroupIdForPane(layout.panes.items[pane_index].id) orelse return .{ .row = row_h, .step = theme.scaledUi(SIDEBAR_THREAD_ROW_STEP_CSS) };
    if (layout.scrollGroupPaneCount(group_id) <= 1) return .{ .row = row_h, .step = theme.scaledUi(SIDEBAR_THREAD_ROW_STEP_CSS) };
    const tile_gap = theme.scaledUi(4.0);
    const tile_row_h = theme.scaledUi(SIDEBAR_TILE_ROW_HEIGHT_CSS);
    const rows = if (layout.root) |root| sidebarScrollGroupRows(layout, root, group_id) else 1;
    const group_h = tile_row_h * @as(f32, @floatFromInt(@max(rows, 1))) +
        tile_gap * @as(f32, @floatFromInt(if (rows > 0) rows - 1 else 0));
    return .{ .row = group_h, .step = group_h + tile_gap };
}

fn revealSidebarRow(scroll_y: f32, row_y: f32, row_h: f32, clip: palette.Rect, max_scroll_y: f32) f32 {
    const visible_y = row_y - scroll_y;
    if (visible_y < clip.y) return theme.clampf(scroll_y + visible_y - clip.y, 0.0, max_scroll_y);
    if (visible_y + row_h > clip.y + clip.h) return theme.clampf(scroll_y + visible_y + row_h - clip.y - clip.h, 0.0, max_scroll_y);
    return scroll_y;
}

test "sidebar reveals a newly focused row past the viewport edge" {
    const clip: palette.Rect = .{ .x = 0.0, .y = 100.0, .w = 240.0, .h = 200.0 };
    try std.testing.expectEqual(@as(f32, 48.0), revealSidebarRow(0.0, 304.0, 44.0, clip, 80.0));
    try std.testing.expectEqual(@as(f32, 12.0), revealSidebarRow(80.0, 112.0, 44.0, clip, 80.0));
    try std.testing.expectEqual(@as(f32, 0.0), revealSidebarRow(0.0, 150.0, 44.0, clip, 80.0));
}

/// Pinned command-palette trigger, kept deliberately quiet: a search glyph,
/// muted "Search" label, and the configured shortcut as plain subtle text.
/// No box/border/badge chrome — it uses the same accent hover wash as list
/// rows so it reads as part of the rail under any theme.
fn renderPaletteSearchTrigger(state: *runtime.AppState, rect: palette.Rect) void {
    const hovered = search_trigger_hovered;
    if (hovered) {
        queuePaletteRoundedRect(state, snapRect(rect), paletteColor(theme.wash(theme.COLOR_GREEN, 48)), theme.scaledUi(6.0));
    }
    addPaletteHit(rect, .command_palette, 0, 0);

    const cy = rect.y + rect.h * 0.5;
    const fg = if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE;
    const icon_font = theme.scaledUi(12.5);
    queuePaletteIcon(state, .{
        .x = rect.x + theme.scaledUi(8.0),
        .y = cy - icon_font * 0.55,
        .w = icon_font,
        .h = icon_font,
    }, NF_COD_SEARCH, icon_font, paletteColor(fg), null);

    const label_font = theme.scaledUi(12.5);
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(28.0),
        .y = @round(cy - label_font * 0.65),
        .w = theme.scaledUi(80.0),
        .h = label_font * 1.3,
    }, "Search", paletteColor(fg), label_font, rect);

    const hint = command_palette.commandPaletteShortcutHint(state);
    if (hint.len == 0) return;
    const hint_font = theme.scaledUi(10.0);
    // Same per-char width estimate the rail uses elsewhere for right-aligned
    // labels; shortcut strings are short ASCII so the error stays invisible.
    const hint_w = @as(f32, @floatFromInt(hint.len)) * hint_font * 0.54;
    queuePaletteText(state, .{
        .x = rect.x + rect.w - hint_w - theme.scaledUi(8.0),
        .y = @round(cy - hint_font * 0.65),
        .w = hint_w + theme.scaledUi(6.0),
        .h = hint_font * 1.3,
    }, hint, paletteColor(theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 210)), hint_font, rect);
}

const AttentionClusterRow = struct {
    project_index: usize,
    pane: *const native_state.WorkspacePane,
    completed_at_ms: ?i64,
};

const AttentionClusterLayout = struct {
    content_h: f32,
    viewport_h: f32,
};

/// Sizes the pinned ACTIVE cluster: grow with row count until the ~10-row
/// cap (or until the remaining rail would starve the workspace tree).
fn attentionClusterLayout(
    row_count: usize,
    available_list_h: f32,
    row_step: f32,
    label_h: f32,
    trailing_h: f32,
    max_rows: usize,
    workspace_min_h: f32,
) AttentionClusterLayout {
    if (row_count == 0 or available_list_h <= 0.0) return .{ .content_h = 0.0, .viewport_h = 0.0 };
    const content_h = label_h + @as(f32, @floatFromInt(row_count)) * row_step + trailing_h;
    const max_rows_h = label_h + @as(f32, @floatFromInt(max_rows)) * row_step + trailing_h;
    const max_from_space = if (available_list_h > workspace_min_h)
        available_list_h - workspace_min_h
    else
        available_list_h * 0.5;
    return .{
        .content_h = content_h,
        .viewport_h = @min(content_h, @min(max_rows_h, max_from_space)),
    };
}

fn attentionClusterLayoutForRail(row_count: usize, available_list_h: f32) AttentionClusterLayout {
    return attentionClusterLayout(
        row_count,
        available_list_h,
        theme.scaledUi(SIDEBAR_THREAD_ROW_STEP_CSS),
        theme.scaledUi(SIDEBAR_ACTIVE_LABEL_H_CSS),
        theme.scaledUi(SIDEBAR_ACTIVE_TRAILING_H_CSS),
        SIDEBAR_ACTIVE_MAX_ROWS,
        theme.scaledUi(SIDEBAR_WORKSPACE_MIN_H_CSS),
    );
}

/// Pinned "ACTIVE" cluster: every working/waiting/done/error pane across all
/// workspaces, including the selected workspace. Pending completions sort
/// first in completion order. The caption and divider stay put; only the
/// row list scrolls when the cluster overflows its cap.
fn renderAttentionClusterSection(
    state: *runtime.AppState,
    x: f32,
    rail_w: f32,
    rows: []const AttentionClusterRow,
    clip: palette.Rect,
    motion_t: f32,
) void {
    if (rows.len == 0 or clip.h <= 0.0) return;

    const label_h = theme.scaledUi(SIDEBAR_ACTIVE_LABEL_H_CSS);
    const trailing_h = theme.scaledUi(SIDEBAR_ACTIVE_TRAILING_H_CSS);
    const row_h = theme.scaledUi(SIDEBAR_THREAD_ROW_HEIGHT_CSS);
    const row_step = theme.scaledUi(SIDEBAR_THREAD_ROW_STEP_CSS);
    const rows_clip: palette.Rect = .{
        .x = clip.x,
        .y = clip.y + label_h,
        .w = clip.w,
        .h = @max(clip.h - label_h - trailing_h, 0.0),
    };
    const content_h = @as(f32, @floatFromInt(rows.len)) * row_step;
    attention_max_scroll_y = @max(0.0, content_h - rows_clip.h);
    attention_scroll_y = theme.clampf(attention_scroll_y, 0.0, attention_max_scroll_y);

    const rows_top = rows_clip.y - attention_scroll_y;
    for (rows, 0..) |row, active_index| {
        const project = &state.project_controller.projects.items[row.project_index];
        const target_y = @as(f32, @floatFromInt(active_index)) * row_step;
        const shown_y = activeRowShownY(row.project_index, row.pane.id, target_y, motion_t);
        const row_rect: palette.Rect = .{ .x = x, .y = rows_top + shown_y, .w = rail_w, .h = row_h };
        if (rowVisible(row_rect, rows_clip)) {
            // Active rows span every workspace, so they always carry the
            // workspace chip; OPEN rows follow the scope.
            const scoped_chip = open_rows_show_chip;
            open_rows_show_chip = true;
            renderOpenPaneRow(state, row.project_index, project, row.pane, row_rect, rows_clip, true, true, active_index, false);
            open_rows_show_chip = scoped_chip;
        }
    }

    // Caption and divider paint after the rows so a scrolled row cannot cover
    // the section chrome — same overwrite trick as the rail header.
    queuePaletteRect(state, .{
        .x = clip.x,
        .y = clip.y,
        .w = clip.w - theme.scaledUi(1.0),
        .h = label_h,
    }, paletteColor(theme.COLOR_PANEL));
    queuePaletteText(state, .{
        .x = x,
        .y = clip.y,
        .w = rail_w,
        .h = theme.scaledUi(18.0),
    }, "ACTIVE", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), clip);

    const divider_band: palette.Rect = .{
        .x = clip.x,
        .y = clip.y + clip.h - trailing_h,
        .w = clip.w - theme.scaledUi(1.0),
        .h = trailing_h,
    };
    queuePaletteRect(state, divider_band, paletteColor(theme.COLOR_PANEL));
    queuePaletteRect(state, .{
        .x = x,
        .y = divider_band.y + theme.scaledUi(2.0),
        .w = rail_w,
        .h = theme.scaledUi(1.0),
    }, paletteColor(theme.borderMuted()));

    renderSidebarOverflowScrollbar(state, rows_clip, attention_scroll_y, attention_max_scroll_y);
}

fn collectAttentionClusterRows(state: *runtime.AppState, rows: []AttentionClusterRow) usize {
    var row_count: usize = 0;
    for (state.project_controller.projects.items, 0..) |*project, project_index| {
        // ACTIVE is global: it lists working/waiting panes from every open
        // workspace regardless of the switcher scope (scope filters OPEN only).
        for (project.workspace_layout.panes.items) |*pane| {
            if (!paneNeedsAttention(state, project_index, project, pane)) continue;
            var duplicate = false;
            for (rows[0..row_count]) |row| {
                if (row.project_index != project_index) continue;
                duplicate = switch (pane.ref) {
                    .chat => |ref| switch (row.pane.ref) {
                        .chat => |existing| existing.thread_index == ref.thread_index,
                        else => false,
                    },
                    .terminal => |ref| switch (row.pane.ref) {
                        .terminal => |existing| existing.dock_id == ref.dock_id,
                        else => false,
                    },
                    .browser => false,
                    .file => |ref| switch (row.pane.ref) {
                        .file => |existing| std.mem.eql(u8, existing.path, ref.path),
                        else => false,
                    },
                };
                if (duplicate) break;
            }
            if (duplicate or row_count >= rows.len) continue;
            rows[row_count] = .{
                .project_index = project_index,
                .pane = pane,
                .completed_at_ms = paneCompletionTime(state, project_index, pane),
            };
            row_count += 1;
        }
    }
    return row_count;
}

/// Focuses the ACTIVE row at the same sorted position used by the sidebar.
pub fn focusAttentionClusterRowAtIndex(state: *runtime.AppState, row_index: usize) bool {
    var rows: [palette_hits.len]AttentionClusterRow = undefined;
    const row_count = collectAttentionClusterRows(state, &rows);
    if (row_index >= row_count) return false;
    sortAttentionClusterRows(rows[0..row_count]);
    const current_pane_id = if (state.project_controller.selected_index < state.project_controller.projects.items.len)
        state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout.focused_pane_id
    else
        null;
    var current_row: ?usize = null;
    if (current_pane_id) |pane_id| {
        for (rows[0..row_count], 0..) |candidate, index| {
            if (candidate.project_index == state.project_controller.selected_index and candidate.pane.id == pane_id) {
                current_row = index;
                break;
            }
        }
    }
    const row = rows[row_index];
    state.focusWorkspaceOpenPaneFromSidebar(row.project_index, row.pane.id);
    if (row.project_index < state.project_controller.projects.items.len) {
        const direction: i8 = if (current_row) |from| (if (row_index >= from) 1 else -1) else 1;
        state.project_controller.projects.items[row.project_index].workspace_layout.noteScrollSkipDirection(direction);
    }
    return true;
}

/// Cycles through only the rows currently shown in the global ACTIVE section.
pub fn focusAdjacentAttentionClusterRow(state: *runtime.AppState, delta: i32) bool {
    if (delta == 0) return false;
    var rows: [palette_hits.len]AttentionClusterRow = undefined;
    const row_count = collectAttentionClusterRows(state, &rows);
    if (row_count == 0) return false;
    sortAttentionClusterRows(rows[0..row_count]);

    const current_pane_id = if (state.project_controller.selected_index < state.project_controller.projects.items.len)
        state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout.focused_pane_id
    else
        null;
    const target_index = adjacentAttentionClusterRowIndex(
        rows[0..row_count],
        state.project_controller.selected_index,
        current_pane_id,
        delta,
    );
    const row = rows[target_index];
    state.focusWorkspaceOpenPaneFromSidebar(row.project_index, row.pane.id);
    if (row.project_index < state.project_controller.projects.items.len) {
        state.project_controller.projects.items[row.project_index].workspace_layout.noteScrollSkipDirection(if (delta > 0) 1 else -1);
    }
    return true;
}

fn adjacentAttentionClusterRowIndex(
    rows: []const AttentionClusterRow,
    current_project_index: usize,
    current_pane_id: ?native_state.WorkspacePaneId,
    delta: i32,
) usize {
    std.debug.assert(rows.len > 0);
    std.debug.assert(delta != 0);
    var current_index: ?usize = null;
    if (current_pane_id) |pane_id| {
        for (rows, 0..) |row, index| {
            if (row.project_index == current_project_index and row.pane.id == pane_id) {
                current_index = index;
                break;
            }
        }
    }

    if (current_index) |index| {
        if (delta < 0) return if (index == 0) rows.len - 1 else index - 1;
        return if (index + 1 == rows.len) 0 else index + 1;
    }
    return if (delta < 0) rows.len - 1 else 0;
}

fn sortAttentionClusterRows(rows: []AttentionClusterRow) void {
    var sort_index: usize = 1;
    while (sort_index < rows.len) : (sort_index += 1) {
        const current = rows[sort_index];
        var insert_index = sort_index;
        while (insert_index > 0 and attentionClusterRowLessThan(current, rows[insert_index - 1])) : (insert_index -= 1) {
            rows[insert_index] = rows[insert_index - 1];
        }
        rows[insert_index] = current;
    }
}

fn paneCompletionTime(
    state: *const runtime.AppState,
    project_index: usize,
    pane: *const native_state.WorkspacePane,
) ?i64 {
    return switch (pane.ref) {
        .chat => |ref| blk: {
            if (project_index >= state.project_controller.projects.items.len) break :blk null;
            const project = &state.project_controller.projects.items[project_index];
            if (ref.thread_index >= project.threads.items.len) break :blk null;
            const thread = &project.threads.items[ref.thread_index];
            break :blk if (thread.completion_pending) thread.completed_at_ms else null;
        },
        .terminal => |ref| blk: {
            const surface = state.projectTerminalSurface(project_index, ref.dock_id) orelse break :blk null;
            break :blk if (surface.completion_pending) surface.completed_at_ms else null;
        },
        else => null,
    };
}

fn attentionClusterRowLessThan(left: AttentionClusterRow, right: AttentionClusterRow) bool {
    if (left.completed_at_ms != null and right.completed_at_ms == null) return true;
    if (left.completed_at_ms == null or right.completed_at_ms == null) return false;
    if (left.completed_at_ms.? != right.completed_at_ms.?) return left.completed_at_ms.? < right.completed_at_ms.?;
    if (left.project_index != right.project_index) return left.project_index < right.project_index;
    return left.pane.id < right.pane.id;
}

fn herdrRuntimeBadgeLabel(project: *const native_state.Project) ?[]const u8 {
    _ = project.herdr_link orelse return null;
    return "HERDR";
}

// Renders the compact Herdr runtime badge inside a workspace row.
fn renderHerdrRuntimeBadge(state: *runtime.AppState, rect: palette.Rect, label: []const u8, emphasized: bool, clip: palette.Rect) void {
    // Accent washes so the badge follows the active theme; the emphasized
    // state reverses the label out against the stronger fill.
    const bg = if (emphasized)
        theme.withAlpha(theme.COLOR_GREEN, 200)
    else
        theme.wash(theme.COLOR_GREEN, 56);
    queuePaletteRoundedRect(state, rect, paletteColor(bg), theme.scaledUi(6.0));
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(6.0),
        .y = rect.y + theme.scaledUi(1.0),
        .w = rect.w - theme.scaledUi(12.0),
        .h = rect.h,
    }, label, paletteColor(if (emphasized) theme.background() else theme.COLOR_TEXT_MUTED), theme.scaledUi(9.0), clip);
}

/// Renders the sidebar collapse/expand toggle used by both rails: a modern
/// panel-left codicon (filled while expanded, hollow while collapsed) with the
/// same hover treatment as the settings button, replacing the old "<"/">" text.
fn renderPaletteSidebarToggle(state: *runtime.AppState, rect: palette.Rect, expanded: bool) void {
    const hovered = state.transcript_controller.palette_mouse_in_workspace and rectContainsPoint(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    if (hovered) {
        queuePaletteRoundedRect(state, rect, paletteColor(theme.wash(theme.COLOR_GREEN, 56)), theme.scaledUi(8.0));
    }
    queueSidebarToggleGlyph(state, rect, expanded, hovered, null);
    addPaletteHit(rect, .collapse, 0, 0);
}

/// Panel-left codicon centered in `rect` (filled while the rail is shown,
/// hollow while hidden). Shared with the workspace tab strip's leading
/// show-sidebar button.
pub fn queueSidebarToggleGlyph(state: *runtime.AppState, rect: palette.Rect, expanded: bool, hovered: bool, clip: ?palette.Rect) void {
    const fg = if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    const icon_font = @min(theme.scaledUi(17.0), rect.h);
    const glyph = if (expanded) NF_COD_LAYOUT_SIDEBAR_LEFT else NF_COD_LAYOUT_SIDEBAR_LEFT_OFF;
    queuePaletteIcon(state, .{
        .x = rect.x + (rect.w - icon_font) * 0.5,
        .y = rect.y + (rect.h - icon_font) * 0.5,
        .w = icon_font,
        .h = icon_font,
    }, glyph, icon_font, paletteColor(fg), clip);
}

/// Mirror of `queueSidebarToggleGlyph` for the right side panel toggle.
pub fn queueSidePanelToggleGlyph(state: *runtime.AppState, rect: palette.Rect, open: bool, hovered: bool, clip: ?palette.Rect) void {
    const fg = if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    const icon_font = @min(theme.scaledUi(17.0), rect.h);
    const glyph = if (open) NF_COD_LAYOUT_SIDEBAR_RIGHT else NF_COD_LAYOUT_SIDEBAR_RIGHT_OFF;
    queuePaletteIcon(state, .{
        .x = rect.x + (rect.w - icon_font) * 0.5,
        .y = rect.y + (rect.h - icon_font) * 0.5,
        .w = icon_font,
        .h = icon_font,
    }, glyph, icon_font, paletteColor(fg), clip);
}

/// Renders add/edit actions with the same themed geometry as the sidebar toggle.
fn renderPaletteSidebarActionIcon(state: *runtime.AppState, rect: palette.Rect, glyph: []const u8, hover_override: ?bool, clip: ?palette.Rect) void {
    const hovered = hover_override orelse (state.transcript_controller.palette_mouse_in_workspace and rectContainsPoint(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y));
    if (hovered) {
        queuePaletteRoundedRect(state, rect, paletteColor(theme.wash(theme.COLOR_GREEN, 56)), theme.scaledUi(8.0));
    }
    const fg = if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    const icon_font = theme.scaledUi(17.0);
    queuePaletteIcon(state, .{
        .x = rect.x + (rect.w - icon_font) * 0.5,
        .y = rect.y + (rect.h - icon_font) * 0.5,
        .w = icon_font,
        .h = icon_font,
    }, glyph, icon_font, paletteColor(fg), clip);
}

/// Renders the sidebar settings gear button used by both expanded and collapsed rails.
fn renderPaletteSettingsButton(state: *runtime.AppState, rect: palette.Rect, clip: ?palette.Rect) void {
    const settings_hover = state.transcript_controller.palette_mouse_in_workspace and rectContainsPoint(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    if (settings_hover) {
        queuePaletteRoundedRect(state, rect, paletteColor(theme.wash(theme.COLOR_GREEN, 56)), theme.scaledUi(8.0));
    }
    const fg = if (settings_hover) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    const icon_font = theme.scaledUi(17.0);
    queuePaletteIcon(state, .{
        .x = rect.x + (rect.w - icon_font) * 0.5,
        .y = rect.y + (rect.h - icon_font) * 0.5,
        .w = icon_font,
        .h = icon_font,
    }, NF_COD_GEAR, icon_font, paletteColor(fg), clip);
    addPaletteHit(rect, .settings, 0, 0);
}

fn chatSurfaceStatusForUi(thread: *const native_state.ChatThread) native_state.SurfaceStatus {
    return switch (thread.activityStatusForUi()) {
        .idle => .idle,
        .working => .working,
        .waiting => .waiting,
        .done => .done,
        .@"error" => .@"error",
    };
}

const CollapsedPaneIndicator = struct {
    color: [4]f32,
    opacity: f32 = 1.0,
};

fn queuePaletteRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch |err| {
        log.warn("failed to queue sidebar palette rect: {s}", .{@errorName(err)});
    };
}

/// Renders one OPEN unit (standalone pane row or split-tile miniature) at
/// `y_in`; returns the advanced y cursor. Rows sit flush: there are no
/// workspace folder rows to nest under.
fn renderOpenPaneUnit(
    state: *runtime.AppState,
    unit: OpenUnit,
    selected_tabs: []const native_state.WorkspaceTab,
    /// Sidebar row ordinal under All Workspaces; overrides the per-workspace
    /// tab ordinal so Ctrl+N badges count down the visible list.
    row_ordinal: ?usize,
    x: f32,
    rail_w: f32,
    list_clip: palette.Rect,
    clip: palette.Rect,
    y_in: f32,
) f32 {
    const project_index = unit.project_index;
    const project = &state.project_controller.projects.items[project_index];
    const layout = &project.workspace_layout;
    const pane = &layout.panes.items[unit.pane_index];
    const group_id = layout.scrollGroupIdForPane(pane.id) orelse return y_in;
    // Ctrl+N tips address the selected workspace's tabs only; a split tile
    // shares one ordinal and its mini-rows show none.
    const shortcuts = row_ordinal != null or project_index == state.project_controller.selected_index;
    const tab_index = row_ordinal orelse if (shortcuts) native_state.workspace_tabs.indexOfTab(selected_tabs, group_id) else null;
    const height = openUnitHeight(layout, unit.pane_index);
    if (layout.scrollGroupPaneCount(group_id) > 1) {
        const root = layout.root orelse return y_in;
        // The tile carries its tab's Ctrl badge once, in a column beside
        // the mini-rows, so the sidebar numbering has no hole at a split.
        var tile_shortcut_buf: [16]u8 = undefined;
        const tile_shortcut = if (shortcuts) tileShortcutLabel(state, &tile_shortcut_buf, tab_index) else "";
        const badge_column = if (tile_shortcut.len > 0) theme.scaledUi(30.0) else 0.0;
        // Under All Workspaces the group gets the same identity chip as a
        // standalone row, in a leading column centred on the whole group.
        const chip = theme.scaledUi(18.0);
        const chip_column = if (open_rows_show_chip) theme.scaledUi(4.0) + chip + theme.scaledUi(6.0) else 0.0;
        const group_rect: palette.Rect = .{ .x = x + chip_column, .y = y_in, .w = rail_w - badge_column - chip_column, .h = height.row };
        if (rowVisible(.{ .x = x, .y = y_in, .w = rail_w, .h = height.row }, list_clip)) {
            if (open_rows_show_chip) {
                const chip_rect: palette.Rect = .{ .x = x + theme.scaledUi(4.0), .y = y_in + (height.row - chip) * 0.5, .w = chip, .h = chip };
                queueWorkspaceChip(state, chip_rect, project, false, clip);
            }
            renderOpenPaneGroupNode(state, project_index, project, root, group_id, group_rect, clip);
            if (tile_shortcut.len > 0) {
                renderSidebarShortcutKeyTip(state, .{ .x = x, .y = y_in, .w = rail_w, .h = height.row }, clip, tile_shortcut);
            }
        }
        return y_in + height.step;
    }
    const row_rect: palette.Rect = .{ .x = x, .y = y_in, .w = rail_w, .h = height.row };
    if (rowVisible(row_rect, list_clip)) renderOpenPaneRow(state, project_index, project, pane, row_rect, clip, false, false, tab_index, false);
    return y_in + height.step;
}

fn sidebarScrollGroupRows(
    layout: *const native_state.WorkspaceLayout,
    node: *const native_state.WorkspaceNode,
    group_id: native_state.WorkspacePaneId,
) usize {
    return switch (node.*) {
        .leaf => |pane_id| if (layout.scrollGroupIdForPane(pane_id) == group_id) 1 else 0,
        .split => |split| blk: {
            const first = sidebarScrollGroupRows(layout, split.first, group_id);
            const second = sidebarScrollGroupRows(layout, split.second, group_id);
            if (first == 0) break :blk second;
            if (second == 0) break :blk first;
            break :blk if (split.axis == .horizontal) first + second else @max(first, second);
        },
    };
}

// Clickable miniature split tree beneath one workspace row.
fn renderOpenPaneGroupNode(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    node: *const native_state.WorkspaceNode,
    group_id: native_state.WorkspacePaneId,
    rect: palette.Rect,
    clip: palette.Rect,
) void {
    const layout = &project.workspace_layout;
    switch (node.*) {
        .leaf => |pane_id| {
            if (layout.scrollGroupIdForPane(pane_id) != group_id) return;
            const pane = layout.paneById(pane_id) orelse return;
            queuePaletteRoundedRect(state, snapRect(rect), paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 150)), theme.scaledUi(6.0));
            renderOpenPaneRow(state, project_index, project, pane, rect, clip, false, false, null, true);
            queuePaletteBorder(state, snapRect(rect), paletteColor(theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 105)), theme.scaledUi(6.0), theme.scaledUi(1.0));
        },
        .split => |split| {
            const first_rows = sidebarScrollGroupRows(layout, split.first, group_id);
            const second_rows = sidebarScrollGroupRows(layout, split.second, group_id);
            if (first_rows == 0 and second_rows == 0) return;
            if (second_rows == 0) return renderOpenPaneGroupNode(state, project_index, project, split.first, group_id, rect, clip);
            if (first_rows == 0) return renderOpenPaneGroupNode(state, project_index, project, split.second, group_id, rect, clip);
            renderOpenPaneGroupSplit(state, project_index, project, split, group_id, rect, clip);
        },
    }
}

// Geometry for one branch point in the sidebar tile miniature.
fn renderOpenPaneGroupSplit(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    split: anytype,
    group_id: native_state.WorkspacePaneId,
    rect: palette.Rect,
    clip: palette.Rect,
) void {
    const gap = theme.scaledUi(4.0);
    const ratio = std.math.clamp(split.ratio, 0.22, 0.78);
    if (split.axis == .vertical) {
        const available = @max(rect.w - gap, 0.0);
        const first_w = available * ratio;
        const first_rect: palette.Rect = .{ .x = rect.x, .y = rect.y, .w = first_w, .h = rect.h };
        const second_rect: palette.Rect = .{ .x = rect.x + first_w + gap, .y = rect.y, .w = available - first_w, .h = rect.h };
        renderOpenPaneGroupNode(state, project_index, project, split.first, group_id, first_rect, clip);
        renderOpenPaneGroupNode(state, project_index, project, split.second, group_id, second_rect, clip);
        return;
    }
    const available = @max(rect.h - gap, 0.0);
    const first_h = available * ratio;
    const first_rect: palette.Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = first_h };
    const second_rect: palette.Rect = .{ .x = rect.x, .y = rect.y + first_h + gap, .w = rect.w, .h = available - first_h };
    renderOpenPaneGroupNode(state, project_index, project, split.first, group_id, first_rect, clip);
    renderOpenPaneGroupNode(state, project_index, project, split.second, group_id, second_rect, clip);
}

/// Renders one live pane row: provider glyph, truncated title, and a trailing
/// status column ("Working · m:ss" / "Waiting" / "Done" / "Failed"). With
/// `show_workspace_tag` (attention-cluster rows) the row focuses only (no
/// reorder drag); the identity chip follows `open_rows_show_chip`.
fn renderOpenPaneRow(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    pane: *const native_state.WorkspacePane,
    rect: palette.Rect,
    clip: palette.Rect,
    show_workspace_tag: bool,
    active_shortcut: bool,
    shortcut_index: ?usize,
    compact_tile: bool,
) void {
    const layout = &project.workspace_layout;
    const quick = if (layout.quick_pane) |value|
        if (value.pane_id == pane.id) value else null
    else
        null;
    const focused = state.project_controller.selected_index == project_index and layout.focused_pane_id == pane.id;
    const hovered = state.transcript_controller.palette_mouse_in_workspace and rectContainsPoint(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    // Accent-tinted fills (not the gray border token) so focus/hover track
    // the active theme; alphas follow the command palette's selection washes.
    if (focused) {
        queuePaletteRoundedRectClipped(state, rect, paletteColor(theme.wash(theme.COLOR_GREEN, 72)), theme.scaledUi(7.0), clip);
        // Light palettes soften the wash, so a solid accent bar marks the row.
        if (theme.isLightPalette()) {
            const bar_w = theme.scaledUi(3.0);
            const bar_inset = theme.scaledUi(6.0);
            queuePaletteRoundedRectClipped(state, snapRect(.{
                .x = rect.x,
                .y = rect.y + bar_inset,
                .w = bar_w,
                .h = @max(rect.h - bar_inset * 2.0, bar_w),
            }), paletteColor(theme.accent()), bar_w * 0.5, clip);
        }
    } else if (hovered) {
        queuePaletteRoundedRectClipped(state, rect, paletteColor(theme.wash(theme.COLOR_GREEN, 48)), theme.scaledUi(7.0), clip);
    }
    addClippedPaletteHit(rect, clip, if (show_workspace_tag) .open_pane else .open_pane_reorder, project_index, pane.id);

    const cy = rect.y + rect.h * 0.5;
    const leading_pad = if (compact_tile) 6.0 else SIDEBAR_THREAD_ICON_LEADING_PAD_CSS;
    const icon_title_gap = if (compact_tile) 5.0 else SIDEBAR_THREAD_ICON_TITLE_GAP_CSS;
    var icon_x = rect.x + theme.scaledUi(leading_pad);
    var title_left = theme.scaledUi(leading_pad + SIDEBAR_THREAD_PROVIDER_GLYPH_CSS + icon_title_gap);
    const muted = theme.COLOR_TEXT_MUTED;

    // Workspace identity chip under All Workspaces, so rows from different
    // workspaces stay attributable; single-workspace scope omits it.
    if (open_rows_show_chip and !compact_tile) {
        const chip = theme.scaledUi(18.0);
        const chip_rect: palette.Rect = .{ .x = rect.x + theme.scaledUi(4.0), .y = cy - chip * 0.5, .w = chip, .h = chip };
        queueWorkspaceChip(state, chip_rect, project, false, clip);
        const shift = chip + theme.scaledUi(8.0);
        icon_x += shift;
        title_left += shift;
    }

    // Backing storage for the terminal pane's live tab title and the foreground
    // process name used for provider detection; must outlive the render below,
    // so they live at function scope.
    var term_title_buf: [96]u8 = undefined;
    var comm_buf: [96]u8 = undefined;
    var title: []const u8 = "";
    var running = false;
    var status: ?native_state.SurfaceStatus = null;
    // Unix ms when the pane's live work began, when known; drives the elapsed
    // portion of the status label.
    var status_started_at_ms: ?i64 = null;
    switch (pane.ref) {
        .chat => |ref| {
            if (ref.thread_index < project.threads.items.len) {
                const thread = &project.threads.items[ref.thread_index];
                queuePaletteProviderGlyph(state, thread.provider, icon_x, cy, clip);
                queueGitChangesDot(state, project, thread, icon_x, cy, clip);
                title = thread.title;
                status = chatSurfaceStatusForUi(thread);
                running = status.? == .working;
                if (running) status_started_at_ms = thread.sendStartedAtMsForUi();
            } else {
                if (intersectRects(.{ .x = icon_x, .y = cy - theme.scaledUi(8.0), .w = theme.scaledUi(12.0), .h = theme.scaledUi(16.0) }, clip) != null)
                    queuePaletteChatBubbleIcon(state, icon_x, cy, muted);
                title = "Chat";
            }
        },
        .terminal => |ref| {
            const surface = state.projectTerminalSurface(project_index, ref.dock_id);
            if (surface) |s| {
                status = state.terminalSurfaceDisplayStatus(s);
                if (!s.completion_pending and s.status == .working) {
                    running = true;
                    if (s.status_changed_at_ms > 0) status_started_at_ms = s.status_changed_at_ms;
                }
            }
            // Prefer the live process over retained surface metadata so an
            // already-stale hook claim cannot mask the agent actually running.
            var foreground_process: ?[]const u8 = null;
            var pinned_provider: ?[]const u8 = null;
            if (state.projectTerminalDock(project_index, ref.dock_id)) |dock| {
                foreground_process = dock.activeForegroundProcessName(&comm_buf);
                pinned_provider = dock.activeTabPinnedProvider();
            }
            const agent_provider = terminalAgentProviderForMetadata(
                if (surface) |s| s.provider else null,
                foreground_process,
                pinned_provider,
            );
            if (agent_provider) |prov| {
                // Neutral/white prompt mark so it contrasts with the provider logo
                // instead of blending into it (the accent shares the logo's hue).
                const mark_color = theme.COLOR_WHITE;
                queuePaletteAgentTerminalGlyph(state, prov, icon_x, cy, mark_color, clip);
            } else {
                queuePaletteTerminalMark(state, icon_x, cy, theme.scaledUi(14.0), muted, clip);
            }
            title = terminalPaneTitle(state, project_index, ref.dock_id, &term_title_buf);
        },
        .browser => {
            // Center in the shared provider glyph slot so the smaller globe
            // lines up with chat/provider icons rather than hugging the left.
            const globe_size = theme.scaledUi(13.0);
            const slot = theme.scaledUi(SIDEBAR_THREAD_PROVIDER_GLYPH_CSS);
            // Unclipped primitive: skip it when the row straddles the list
            // edge so the globe cannot bleed into the section below.
            if (intersectRects(.{ .x = icon_x, .y = cy - globe_size * 0.5, .w = slot, .h = globe_size }, clip)) |visible| {
                // Tolerate float rounding: eased rows sit at fractional y, so a
                // fully visible globe can intersect to a hair under its size.
                if (visible.h + 0.5 >= globe_size) globe_icon.queue(state, icon_x + slot * 0.5, cy, globe_size, paletteColor(muted));
            }
            title = browserPaneTitle(pane);
        },
        .file => |ref| {
            // File-type glyph centred in the shared provider glyph slot.
            const name = std.fs.path.basename(ref.path);
            const icon = file_icons.forFile(name);
            const glyph_size = theme.scaledUi(13.0);
            const slot = theme.scaledUi(SIDEBAR_THREAD_PROVIDER_GLYPH_CSS);
            const glyph_w = text_measure.textWidth(.icon, glyph_size, icon.glyph);
            queuePaletteIcon(
                state,
                .{ .x = icon_x + (slot - glyph_w) * 0.5, .y = cy - glyph_size * 0.65, .w = glyph_w, .h = glyph_size * 1.3 },
                icon.glyph,
                glyph_size,
                paletteColor(theme.legibleOn(icon.color, theme.background())),
                clip,
            );
            title = name;
        },
    }

    // Small top-right badge on the existing pane glyph: accent while shown and
    // muted while hidden. Keeping it above the terminal underscore avoids
    // changing the row's established icon-to-title spacing.
    if (quick) |quick_state| {
        const badge_size = theme.scaledUi(8.0);
        const badge_rect: palette.Rect = .{
            .x = icon_x + theme.scaledUi(15.0),
            .y = cy - theme.scaledUi(9.0),
            .w = badge_size,
            .h = badge_size,
        };
        const badge_color = if (quick_state.visible) theme.COLOR_GREEN else theme.COLOR_TEXT_SUBTLE;
        queuePaletteIcon(state, badge_rect, NF_FA_WINDOW_RESTORE, badge_size, paletteColor(badge_color), clip);
    }

    // Status label computed before truncation so the title only surrenders
    // width while a label is actually present.
    var status_buf: [24]u8 = undefined;
    const status_label = if (compact_tile) "" else paneStatusLabelText(&status_buf, status, running, status_started_at_ms);
    var shortcut_buf: [16]u8 = undefined;
    const shortcut_label = if (state.ctrl_shortcut_hints_visible and shortcut_index != null and active_shortcut and state.shift_shortcut_hints_visible)
        if (state.command_controller.keyboard_config) |config|
            keybinds.formatCtrlShiftKeyTipAt(&shortcut_buf, config.workspace_active_select, shortcut_index.?)
        else
            ""
    else if (state.ctrl_shortcut_hints_visible and shortcut_index != null and !active_shortcut and !state.shift_shortcut_hints_visible)
        if (state.command_controller.keyboard_config) |config|
            keybinds.formatCtrlKeyTipAt(&shortcut_buf, config.workspace_pane_select, shortcut_index.?)
        else
            ""
    else
        "";
    const status_reserve = if (shortcut_label.len > 0)
        theme.scaledUi(30.0)
    else if (status_label.len > 0)
        theme.scaledUi(SIDEBAR_STATUS_COLUMN_CSS)
    else
        theme.scaledUi(14.0);

    var title_buf = std.mem.zeroes([64:0]u8);
    const title_chars: usize = @intFromFloat(@max((rect.w - title_left - status_reserve) / theme.scaledUi(7.0), 8.0));
    const shown = truncatedThreadTitle(&title_buf, title, title_chars);

    const emphasis = focused or hovered;
    const title_color = if (running)
        theme.COLOR_GREEN
    else if (emphasis)
        theme.COLOR_WHITE
    else
        theme.COLOR_TEXT_MUTED;

    const title_font = theme.scaledUi(13.5);
    const title_line = title_font * 1.30;
    queuePaletteText(state, .{
        .x = rect.x + title_left,
        .y = @round(rect.y + (rect.h - title_line) * 0.5),
        .w = rect.w - title_left - theme.scaledUi(12.0),
        .h = title_line,
    }, shown, paletteColor(title_color), title_font, clip);

    // Trailing status column: pulsing pip plus the status text in the same
    // color. The at-a-glance words/elapsed-time are what the expanded rail
    // offers over the collapsed rail's bare dots.
    if (shortcut_label.len > 0) {
        renderSidebarShortcutKeyTip(state, rect, clip, shortcut_label);
    } else if (paneStatusColor(status, running)) |pip_color| {
        const animated = running or (if (status) |s| s == .working or s == .waiting else false);
        const pulse: f32 = if (animated) attentionPulse(state, project_index) else 1.0;
        const dot = theme.scaledUi(6.0);
        const status_font = theme.scaledUi(11.0);
        // Approximate right-alignment with the same per-char width heuristic
        // the title truncation uses; labels are short and near-uniform.
        const est_w = @as(f32, @floatFromInt(status_label.len)) * status_font * 0.54;
        const label_x = rect.x + rect.w - theme.scaledUi(10.0) - est_w;
        queuePaletteRoundedRectClipped(state, .{
            .x = label_x - dot - theme.scaledUi(6.0),
            .y = cy - dot * 0.5,
            .w = dot,
            .h = dot,
        }, paletteColor(theme.withAlpha(pip_color, @intFromFloat(pulse * 255.0))), dot * 0.5, clip);
        if (status_label.len > 0) {
            queuePaletteText(state, .{
                .x = label_x,
                .y = @round(cy - status_font * 0.65),
                .w = est_w + theme.scaledUi(8.0),
                .h = status_font * 1.3,
            }, status_label, paletteColor(pip_color), status_font, clip);
        }
    }
}

// Plain-Ctrl key tip for a split tile's tab ordinal; empty while hints are
// hidden, during the Ctrl+Shift reveal, or when the tile is not a tab.
fn tileShortcutLabel(state: *const runtime.AppState, buf: []u8, tab_index: ?usize) []const u8 {
    if (!state.ctrl_shortcut_hints_visible or state.shift_shortcut_hints_visible) return "";
    const index = tab_index orelse return "";
    const config = state.command_controller.keyboard_config orelse return "";
    return keybinds.formatCtrlKeyTipAt(buf, config.workspace_pane_select, index);
}

// Minimal Ctrl-number badge in the row's existing trailing status slot.
fn renderSidebarShortcutKeyTip(state: *runtime.AppState, row_rect: palette.Rect, clip: palette.Rect, label: []const u8) void {
    const size = theme.scaledUi(18.0);
    const rect: palette.Rect = .{
        .x = row_rect.x + row_rect.w - size - theme.scaledUi(8.0),
        .y = row_rect.y + (row_rect.h - size) * 0.5,
        .w = size,
        .h = size,
    };
    // One SDF command owns fill and stroke, avoiding the doubled AA fringe
    // produced by overlapping rounded-fill and border commands.
    queuePalettePanel(
        state,
        rect,
        paletteColor(theme.COLOR_PANEL_ALT),
        paletteColor(theme.borderMuted()),
        theme.scaledUi(5.0),
        theme.scaledUi(1.0),
    );
    const font_size = theme.scaledUi(11.0);
    const text_w = runtime.paletteUiTextPrefixWidth(label, font_size, label.len);
    queuePaletteUiText(state, .{
        .x = rect.x + @max((rect.w - text_w) * 0.5, 0.0),
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = @min(text_w, rect.w),
        .h = font_size * 1.25,
    }, label, paletteColor(theme.accent()), font_size, clip);
}

/// Formats a pane row's live status label; empty when the pane is quiet.
/// Working panes show elapsed time ("Working · 1:20", or "h:mm:ss" once the
/// word no longer fits alongside an hours-long timer).
fn paneStatusLabelText(buf: []u8, status: ?native_state.SurfaceStatus, running: bool, started_at_ms: ?i64) []const u8 {
    const working = running or (if (status) |s| s == .working else false);
    if (working) {
        if (started_at_ms) |start| {
            if (start > 0) {
                const total_seconds: u64 = @intCast(@max(@divTrunc(unixTimestampMs() - start, std.time.ms_per_s), 0));
                const hours = total_seconds / 3600;
                const minutes = (total_seconds / 60) % 60;
                const seconds = total_seconds % 60;
                if (hours > 0) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "Working";
                return std.fmt.bufPrint(buf, "Working · {d}:{d:0>2}", .{ minutes, seconds }) catch "Working";
            }
        }
        return "Working";
    }
    if (status) |s| {
        return switch (s) {
            .waiting => "Waiting",
            .done => "Done",
            .@"error" => "Failed",
            else => "",
        };
    }
    return "";
}

fn openPaneChatThreadIndex(state: *const runtime.AppState, project_index: usize, pane_id: native_state.WorkspacePaneId) ?usize {
    if (project_index >= state.project_controller.projects.items.len) return null;
    const project = &state.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return null;
    return switch (pane.ref) {
        .chat => |ref| if (ref.thread_index < project.threads.items.len) ref.thread_index else null,
        else => null,
    };
}

/// True when a pane should punch through to the attention cluster: chat sends
/// in flight, or terminal surfaces working/waiting/done/errored. A done pane
/// stays visible until focusing it acknowledges the completion and resets it
/// to idle.
fn paneNeedsAttention(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    pane: *const native_state.WorkspacePane,
) bool {
    switch (pane.ref) {
        .chat => |ref| {
            if (ref.thread_index >= project.threads.items.len) return false;
            const thread = &project.threads.items[ref.thread_index];
            return chatSurfaceStatusForUi(thread) != .idle;
        },
        .terminal => |ref| {
            const surface = state.projectTerminalSurface(project_index, ref.dock_id) orelse return false;
            // Done remains visible here until the terminal focus path
            // acknowledges it by resetting the surface to idle.
            return switch (state.terminalSurfaceDisplayStatus(surface)) {
                .working, .waiting, .done, .@"error" => true,
                .idle => false,
            };
        },
        .browser, .file => return false,
    }
}

/// Status pip for one pane, shared by the sidebar rows' semantics and the
/// workspace tab strip. `rank` orders competing pips within a tab:
/// waiting > error > working > done.
pub const PanePip = struct {
    color: [4]f32,
    animated: bool,
    rank: u8,
};

pub fn panePip(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    pane: *const native_state.WorkspacePane,
) ?PanePip {
    var status: ?native_state.SurfaceStatus = null;
    var running = false;
    switch (pane.ref) {
        .chat => |ref| {
            if (ref.thread_index >= project.threads.items.len) return null;
            status = chatSurfaceStatusForUi(&project.threads.items[ref.thread_index]);
            running = status.? == .working;
        },
        .terminal => |ref| {
            const surface = state.projectTerminalSurface(project_index, ref.dock_id) orelse return null;
            status = state.terminalSurfaceDisplayStatus(surface);
            running = !surface.completion_pending and surface.status == .working;
        },
        .browser, .file => return null,
    }
    const color = paneStatusColor(status, running) orelse return null;
    const s = status orelse .idle;
    const rank: u8 = switch (s) {
        .waiting => 4,
        .@"error" => 3,
        .working => 2,
        .done => 1,
        .idle => if (running) 2 else 0,
    };
    return .{ .color = color, .animated = running or s == .working or s == .waiting, .rank = rank };
}

/// Pulse alpha (0.35..1.0) for an animated pip; see `attentionPulse`.
pub fn pipPulse(state: *runtime.AppState, project_index: usize) f32 {
    return attentionPulse(state, project_index);
}

/// Maps a terminal surface status (and chat running state) to a sidebar status
/// pip color, or null when the pane needs no attention indicator.
fn paneStatusColor(status: ?native_state.SurfaceStatus, running: bool) ?[4]f32 {
    if (status) |s| {
        return switch (s) {
            .working => theme.COLOR_GREEN,
            .waiting => theme.COLOR_YELLOW,
            .@"error" => theme.COLOR_DIFF_REMOVE,
            .done => theme.success(),
            .idle => if (running) theme.COLOR_GREEN else null,
        };
    }
    if (running) return theme.COLOR_GREEN;
    return null;
}

/// Best-effort human label for the workspace browser pane.
fn browserPaneTitle(pane: *const native_state.WorkspacePane) []const u8 {
    const ref = switch (pane.ref) {
        .browser => |browser| browser,
        else => return "Browser",
    };
    const tab = ref.activeTabConst() orelse return "Browser";
    if (tab.title) |title| {
        if (title.len > 0 and !std.mem.eql(u8, title, "about:blank")) return title;
    }
    const url = tab.url orelse return "Browser";
    if (url.len == 0 or std.mem.eql(u8, url, "about:blank")) return "New tab";
    return url;
}

fn rowVisible(row: palette.Rect, viewport: palette.Rect) bool {
    return row.y + row.h >= viewport.y and row.y <= viewport.y + viewport.h;
}

fn intersectRects(a: palette.Rect, b: palette.Rect) ?palette.Rect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
}

fn addPaletteHit(rect: palette.Rect, kind: SidebarHitKind, project_index: usize, thread_index: usize) void {
    if (palette_hit_count >= palette_hits.len) return;
    palette_hits[palette_hit_count] = .{
        .rect = rect,
        .kind = kind,
        .project_index = project_index,
        .thread_index = thread_index,
    };
    palette_hit_count += 1;
}

fn addClippedPaletteHit(rect: palette.Rect, clip: palette.Rect, kind: SidebarHitKind, project_index: usize, thread_index: usize) void {
    if (intersectRects(rect, clip)) |hit_rect| addPaletteHit(hit_rect, kind, project_index, thread_index);
}

fn renderSidebarOverflowScrollbar(
    state: *runtime.AppState,
    clip: palette.Rect,
    scroll_y: f32,
    max_scroll_y: f32,
) void {
    if (max_scroll_y <= 1.0 or clip.h <= theme.scaledUi(32.0)) return;
    const track: palette.Rect = .{
        .x = clip.x + clip.w - theme.scaledUi(4.0),
        .y = clip.y + theme.scaledUi(4.0),
        .w = theme.scaledUi(3.0),
        .h = clip.h - theme.scaledUi(8.0),
    };
    const thumb_h = @max(theme.scaledUi(34.0), track.h * (track.h / (track.h + max_scroll_y)));
    const thumb_y = track.y + (track.h - thumb_h) * (scroll_y / max_scroll_y);
    queuePaletteRoundedRect(state, track, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 120)), theme.scaledUi(2.0));
    queuePaletteRoundedRect(state, .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, paletteColor(theme.withAlpha(theme.COLOR_TEXT_MUTED, 200)), theme.scaledUi(2.0));
}

fn rectContainsPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn queuePaletteRoundedRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, snapRect(rect), color, radius) catch |err| {
        log.warn("failed to queue sidebar palette rounded rect: {s}", .{@errorName(err)});
    };
}

/// Clipped variant for shapes inside a scrolling list: a row straddling the
/// viewport edge must not bleed its fill, chip, or pip past the section.
fn queuePaletteRoundedRectClipped(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, snapRect(rect), color, radius, clip) catch |err| {
        log.warn("failed to queue sidebar palette rounded rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, snapRect(rect), color, radius, width) catch |err| {
        log.warn("failed to queue sidebar palette border: {s}", .{@errorName(err)});
    };
}

fn queuePalettePanel(state: *runtime.AppState, rect: palette.Rect, fill: palette.Color, border: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.panel(state.allocator, snapRect(rect), fill, border, radius, width) catch |err| {
        log.warn("failed to queue sidebar palette panel: {s}", .{@errorName(err)});
    };
}

// Nerd Font Symbols codicon glyphs used throughout the sidebar. Codepoints
// confirmed against SymbolsNerdFontMono-Regular.ttf's cmap.
const NF_COD_CHEVRON_RIGHT = "\u{EAB6}";
const NF_COD_CHEVRON_DOWN = "\u{EAB4}";
const NF_COD_ADD = "\u{EA60}";
const NF_COD_EDIT = "\u{EA73}";
const NF_COD_GEAR = "\u{EB51}";
const NF_COD_TERMINAL = "\u{EA85}";
const NF_COD_HISTORY = "\u{EA82}";
const NF_COD_SEARCH = "\u{EA6D}";
// Font Awesome's overlapping-window mark. It badges floating panes without
// replacing the pane-kind/provider glyph users already recognize.
const NF_FA_WINDOW_RESTORE = "\u{F2D2}";
// Panel-style sidebar toggle (VS Code's layout-sidebar-left): filled left pane
// while the rail is expanded, hollow "off" variant while collapsed.
const NF_COD_LAYOUT_SIDEBAR_LEFT = "\u{EBF3}";
const NF_COD_LAYOUT_SIDEBAR_LEFT_OFF = "\u{EC02}";
const NF_COD_LAYOUT_SIDEBAR_RIGHT = "\u{EBF4}";
const NF_COD_LAYOUT_SIDEBAR_RIGHT_OFF = "\u{EC00}";

/// Renders a centered codicon glyph through the icon font. Replaces the
/// hand-drawn shapes / PNGs we used before.
fn queuePaletteIcon(state: *runtime.AppState, rect: palette.Rect, glyph: []const u8, font_size: f32, color: palette.Color, clip: ?palette.Rect) void {
    const stable_value = stablePaletteText(state, glyph) catch |err| {
        log.warn("failed to retain sidebar icon: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.roleText(
        state.allocator,
        snapRect(rect),
        stable_value,
        color,
        font_size,
        .icon,
        null,
        clip,
    ) catch |err| {
        log.warn("failed to queue sidebar icon: {s}", .{@errorName(err)});
    };
}

/// Workspace identity chip: the workspace's hashed icon in its theme-derived
/// slot color on a tinted rounded square (see
/// docs/workspace-switcher-sidebar.md). `project == null` draws the All
/// Workspaces chip in the accent color. User overrides win over the hash.
pub fn queueWorkspaceChip(state: *runtime.AppState, rect: palette.Rect, project: ?*const native_state.Project, dimmed: bool, clip: ?palette.Rect) void {
    if (project) |p| {
        const identity = workspace_identity.resolve(p.id, p.icon_index, p.color_index);
        queueIdentityChip(state, rect, workspace_identity.glyphAt(identity.icon_index), workspace_identity.slotColor(identity.color_index), dimmed, clip);
    } else {
        queueIdentityChip(state, rect, workspace_identity.ALL_WORKSPACES_GLYPH, theme.accent(), dimmed, clip);
    }
}

/// Draws one identity chip (glyph tinted `base_color` on a tinted square).
pub fn queueIdentityChip(state: *runtime.AppState, rect: palette.Rect, glyph: []const u8, base_color: [4]f32, dimmed: bool, clip: ?palette.Rect) void {
    workspace_identity.drawChip(&state.palette_overlay_batch, state.allocator, rect, glyph, base_color, dimmed, clip) catch |err| {
        log.warn("failed to queue workspace chip: {s}", .{@errorName(err)});
    };
}

fn queuePaletteChevron(state: *runtime.AppState, x: f32, center_y: f32, color: [4]f32, collapsed: bool) void {
    const font_size = theme.scaledUi(13.0);
    const glyph = if (collapsed) NF_COD_CHEVRON_RIGHT else NF_COD_CHEVRON_DOWN;
    queuePaletteIcon(state, .{
        .x = x - theme.scaledUi(4.0),
        .y = center_y - font_size * 0.5,
        .w = theme.scaledUi(14.0),
        .h = font_size,
    }, glyph, font_size, paletteColor(color), null);
}

fn queuePaletteLogoMark(state: *runtime.AppState, rect: palette.Rect) void {
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    if (state.logo_texture) |cached| {
        const dims = runtime.scaledImageSize(cached.width, cached.height, rect.w, rect.h);
        const image_rect: palette.Rect = .{
            .x = rect.x + (rect.w - dims[0]) * 0.5,
            .y = rect.y + (rect.h - dims[1]) * 0.5,
            .w = dims[0],
            .h = dims[1],
        };
        if (queuePaletteImage(state, image_rect, cached, paletteColor(theme.COLOR_GREEN), null)) return;
    }

    const mark_color = paletteColor(theme.COLOR_GREEN);
    const thickness = theme.scaledUi(3.0);
    queuePaletteBorder(state, rect, mark_color, theme.scaledUi(6.0), thickness);
    queuePaletteRect(state, .{
        .x = rect.x + rect.w * 0.5 - thickness * 0.5,
        .y = rect.y + rect.h * 0.25,
        .w = thickness,
        .h = rect.h * 0.5,
    }, mark_color);
    queuePaletteRect(state, .{
        .x = rect.x + rect.w * 0.25,
        .y = rect.y + rect.h * 0.5 - thickness * 0.5,
        .w = rect.w * 0.5,
        .h = thickness,
    }, mark_color);
}

fn queuePaletteText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stablePaletteText(state, value) catch |err| {
        log.warn("failed to retain sidebar palette text: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.fixedText(
        state.allocator,
        snapRect(rect),
        stable_value,
        color,
        font_size,
        clip,
        .{},
        font_size * 0.55,
        font_size * 1.25,
        false,
    ) catch |err| {
        log.warn("failed to queue sidebar palette text: {s}", .{@errorName(err)});
    };
}

fn queuePaletteUiText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stablePaletteText(state, value) catch |err| {
        log.warn("failed to retain sidebar UI text: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.roleText(
        state.allocator,
        snapRect(rect),
        stable_value,
        color,
        font_size,
        .ui,
        null,
        clip,
    ) catch |err| {
        log.warn("failed to queue sidebar UI text: {s}", .{@errorName(err)});
    };
}

fn stablePaletteText(state: *runtime.AppState, value: []const u8) ![]const u8 {
    return try state.palette_frame_text_arena.allocator().dupe(u8, value);
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn queuePaletteImage(state: *runtime.AppState, rect: palette.Rect, cached: native_state.CachedImageTexture, tint: palette.Color, clip: ?palette.Rect) bool {
    if (!cached.valid or cached.texture_id == 0 or rect.w <= 0.0 or rect.h <= 0.0) return false;
    state.palette_overlay_batch.image(
        state.allocator,
        snapRect(rect),
        palette.TextureId.init(cached.texture_id),
        .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 },
        tint,
        clip,
    ) catch |err| {
        log.warn("failed to queue sidebar palette image: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

/// Snaps each edge to the pixel grid (not origin + size) so adjacent rects
/// share edges without one-pixel gaps or overlaps.
fn snapRect(rect: palette.Rect) palette.Rect {
    const x = @round(rect.x);
    const y = @round(rect.y);
    return .{ .x = x, .y = y, .w = @round(rect.x + rect.w) - x, .h = @round(rect.y + rect.h) - y };
}

/// Strips a leading run of non-ASCII bytes (a symbol/emoji marker such as the
/// "✳" agents prepend to their terminal title) when it is separated from the
/// real title by a space. Falls back to the original string otherwise, so plain
/// or fully non-ASCII titles are left untouched.
pub fn stripLeadingTitleSymbols(title: []const u8) []const u8 {
    if (title.len == 0 or title[0] < 0x80) return title;
    var i: usize = 0;
    while (i < title.len and title[i] >= 0x80) {
        i += if (title[i] >= 0xF0) 4 else if (title[i] >= 0xE0) 3 else if (title[i] >= 0xC0) 2 else 1;
    }
    if (i < title.len and (title[i] == ' ' or title[i] == '\t')) {
        const rest = std.mem.trimStart(u8, title[i..], " \t");
        if (rest.len > 0 and rest[0] < 0x80) return rest;
    }
    return title;
}

/// Truncates a thread title for narrow sidebar rows.
fn truncatedThreadTitle(buffer: *[64:0]u8, value: []const u8, max_len: usize) [:0]const u8 {
    const bounded_max = @min(buffer.len - 1, max_len);
    if (value.len <= bounded_max) return std.fmt.bufPrintZ(buffer, "{s}", .{value}) catch value[0..bounded_max :0];
    if (bounded_max <= 3) return "...";
    const prefix_len = bounded_max - 3;
    @memcpy(buffer[0..prefix_len], value[0..prefix_len]);
    @memcpy(buffer[prefix_len..bounded_max], "...");
    buffer[bounded_max] = 0;
    return buffer[0..bounded_max :0];
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

fn unixTimestampSeconds() i64 {
    return @divTrunc(unixTimestampMs(), std.time.ms_per_s);
}

/// Formats a relative timestamp for sidebar metadata.
pub fn formatRelativeTime(buffer: []u8, timestamp: i64) []const u8 {
    if (timestamp <= 0) return "—";
    const now = unixTimestampSeconds();
    const elapsed = @max(0, now - timestamp);
    if (elapsed < 60) return "now";
    if (elapsed < 3600) {
        const minutes = @divFloor(elapsed, 60);
        return std.fmt.bufPrint(buffer, "{d}m", .{minutes}) catch "…";
    }
    if (elapsed < 86_400) {
        const hours = @divFloor(elapsed, 3600);
        return std.fmt.bufPrint(buffer, "{d}h", .{hours}) catch "…";
    }
    const days = @divFloor(elapsed, 86_400);
    return std.fmt.bufPrint(buffer, "{d}d", .{days}) catch "…";
}

/// Small dot at the provider glyph's lower-right corner when the chat owns
/// uncommitted git changes; amber when a file needs an ownership decision.
fn queueGitChangesDot(
    state: *runtime.AppState,
    project: *const native_state.Project,
    thread: *const native_state.ChatThread,
    icon_x: f32,
    center_y: f32,
    clip: palette.Rect,
) void {
    state.ensureGitChangesSummary(project.id);
    if (!thread.committed) return;
    const summary = state.gitChangesThreadSummary(thread.local_thread_id) orelse return;
    if (summary.files == 0) return;
    const slot = theme.scaledUi(SIDEBAR_THREAD_PROVIDER_GLYPH_CSS);
    const dot = theme.scaledUi(7.0);
    const cx = icon_x + slot - dot * 0.35;
    const dot_cy = center_y + slot * 0.5 - dot * 0.35;
    const color = if (summary.attention > 0) theme.COLOR_YELLOW else theme.COLOR_TEXT_MUTED;
    queuePaletteRoundedRectClipped(state, snapRect(.{ .x = cx - dot * 0.5, .y = dot_cy - dot * 0.5, .w = dot, .h = dot }), paletteColor(color), dot * 0.5, clip);
}

pub fn queuePaletteProviderGlyph(state: *runtime.AppState, provider: Provider, x: f32, center_y: f32, clip: palette.Rect) void {
    const image_size = theme.scaledUi(SIDEBAR_THREAD_PROVIDER_GLYPH_CSS);
    queuePaletteProviderGlyphInRect(state, terminalAgentProviderFromChatProvider(provider), .{
        .x = x,
        .y = center_y - image_size * 0.5,
        .w = image_size,
        .h = image_size,
    }, clip);
}

pub fn queuePaletteAgentTuiProviderGlyph(state: *runtime.AppState, provider: native_state.AgentTuiHistoryProvider, x: f32, center_y: f32, clip: palette.Rect) void {
    const terminal_provider: TerminalAgentProvider = switch (provider) {
        .codex => .codex,
        .opencode => .opencode,
        .claude => .claude,
        .cursor => .cursor,
        .pi => .pi,
        .fx => .fx,
        .grok => .grok,
        .amp => .amp,
        .muse => .muse,
    };
    queuePaletteAgentTerminalGlyph(state, terminal_provider, x, center_y, theme.COLOR_WHITE, clip);
}

const TerminalAgentProvider = enum {
    codex,
    opencode,
    claude,
    cursor,
    grok,
    amp,
    pi,
    fx,
    muse,
};

fn terminalAgentProviderFromChatProvider(provider: Provider) TerminalAgentProvider {
    return switch (provider) {
        .codex => .codex,
        .opencode => .opencode,
        .claude => .claude,
        .cursor => .cursor,
        .pi => .pi,
        .fx => .fx,
        .grok => .grok,
        .muse => .muse,
    };
}

fn terminalAgentProviderFromProvider(provider: ?SurfaceProvider) ?TerminalAgentProvider {
    return switch (provider orelse return null) {
        .codex => .codex,
        .opencode => .opencode,
        .claude => .claude,
        .cursor => .cursor,
        .grok => .grok,
        .amp => .amp,
        .pi => .pi,
        .fx => .fx,
        .muse => .muse,
    };
}

pub fn terminalAgentProviderForMetadata(
    surface_provider: ?SurfaceProvider,
    foreground_process: ?[]const u8,
    pinned_provider: ?[]const u8,
) ?TerminalAgentProvider {
    if (foreground_process) |comm| {
        if (providerFromComm(comm)) |provider| return provider;
    }
    if (terminalAgentProviderFromProvider(surface_provider)) |provider| return provider;
    if (pinned_provider) |name| return std.meta.stringToEnum(TerminalAgentProvider, name);
    return null;
}

/// Draws a provider logo (or letter fallback) fitted within `box`.
fn queuePaletteProviderGlyphInRect(state: *runtime.AppState, provider: TerminalAgentProvider, box: palette.Rect, clip: ?palette.Rect) void {
    const texture = switch (provider) {
        .codex => state.codex_logo_texture,
        .opencode => state.opencode_logo_texture,
        .claude => state.claude_logo_texture,
        .cursor => state.cursor_logo_texture,
        .grok => state.grok_logo_texture,
        .amp => state.amp_logo_texture,
        .pi => state.pi_logo_texture,
        .fx => state.fx_logo_texture,
        .muse => state.muse_logo_texture,
    };
    if (texture) |cached| {
        const r = utils.snapImageRectToPixels(utils.imageRectContain(cached.width, cached.height, box.x, box.y, box.w, box.h));
        const draw = snapRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
        if (queuePaletteImage(state, draw, cached, paletteColor(theme.providerLogoTint(@tagName(provider))), clip)) return;
    }

    const label = switch (provider) {
        .codex => "C",
        .opencode => "O",
        .claude => "Cl",
        .cursor => "Cu",
        .grok => "G",
        .amp => "A",
        .pi => "P",
        .fx => "F",
        .muse => "M",
    };
    const font_size = @min(theme.scaledUi(11.0), box.h);
    const color = if (provider == .amp) theme.COLOR_YELLOW else theme.COLOR_TEXT_SUBTLE;
    queuePaletteText(state, .{
        .x = box.x,
        .y = box.y + (box.h - font_size * 1.25) * 0.5,
        .w = box.w,
        .h = font_size * 1.25,
    }, label, paletteColor(color), font_size, clip);
}

/// Maps a foreground process `comm` name to a known agent provider, so a
/// terminal pane running e.g. `claude` shows that provider's split icon.
fn providerFromComm(comm: []const u8) ?TerminalAgentProvider {
    if (std.mem.eql(u8, comm, "claude")) return .claude;
    if (std.mem.eql(u8, comm, "codex")) return .codex;
    if (std.mem.eql(u8, comm, "opencode") or std.mem.eql(u8, comm, "opencode2")) return .opencode;
    if (std.mem.startsWith(u8, comm, "cursor")) return .cursor;
    if (std.mem.eql(u8, comm, "agent")) return .cursor;
    if (std.mem.eql(u8, comm, "grok")) return .grok;
    if (std.mem.eql(u8, comm, "amp")) return .amp;
    if (std.mem.eql(u8, comm, "fx")) return .fx;
    if (std.mem.eql(u8, comm, "muse") or std.mem.startsWith(u8, comm, "muse-bin-")) return .muse;
    return null;
}

/// Composite glyph for an agent running in a terminal pane: the provider logo
/// sits in the upper-left, a font-safe `>_` prompt mark in the lower-right, and
/// a diagonal slash divides them.
fn queuePaletteAgentTerminalGlyph(state: *runtime.AppState, provider: TerminalAgentProvider, x: f32, center_y: f32, term_color: [4]f32, clip: palette.Rect) void {
    // Provider logo, then a `>_` prompt — laid out horizontally and vertically
    // centered. Kept deliberately simple (no diagonal/divider primitives) so it
    // renders cleanly at sidebar size.
    const logo = theme.scaledUi(15.0);
    queuePaletteProviderGlyphInRect(state, provider, .{ .x = x, .y = center_y - logo * 0.5, .w = logo, .h = logo }, clip);
    queuePaletteTerminalMark(state, x + logo + theme.scaledUi(1.0), center_y, theme.scaledUi(11.0), term_color, clip);
}

/// Draws a font-safe `>_` shell-prompt mark for terminal panes.
fn queuePaletteTerminalMark(state: *runtime.AppState, x: f32, center_y: f32, size: f32, color: [4]f32, clip: ?palette.Rect) void {
    queuePaletteText(state, .{
        .x = x,
        .y = center_y - size * 0.62,
        .w = size * 1.9,
        .h = size * 1.25,
    }, ">_", paletteColor(color), size, clip);
}

/// Draws a thick line segment between two points using two triangles.
fn queuePaletteDiagLine(state: *runtime.AppState, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: [4]f32, clip: palette.Rect) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0.0) return;
    const nx = -dy / len * (thickness * 0.5);
    const ny = dx / len * (thickness * 0.5);
    const c = paletteColor(color);
    const a: palette.draw.Vec2 = .{ .x = x0 + nx, .y = y0 + ny };
    const b: palette.draw.Vec2 = .{ .x = x0 - nx, .y = y0 - ny };
    const cc: palette.draw.Vec2 = .{ .x = x1 - nx, .y = y1 - ny };
    const d: palette.draw.Vec2 = .{ .x = x1 + nx, .y = y1 + ny };
    state.palette_overlay_batch.triangleClipped(state.allocator, a, b, cc, c, clip) catch {};
    state.palette_overlay_batch.triangleClipped(state.allocator, a, cc, d, c, clip) catch {};
}

/// Queues a small speech bubble icon for thread rows.
fn queuePaletteChatBubbleIcon(state: anytype, x: f32, center_y: f32, color: [4]f32) void {
    const bw = theme.scaledUi(11.0); // bubble width
    const bh = theme.scaledUi(8.0); // bubble height
    const r = theme.scaledUi(2.0); // corner rounding
    const bubble_top = center_y - bh * 0.5 - theme.scaledUi(1.0);
    const palette_color = paletteColor(color);

    queuePaletteRoundedRect(state, .{
        .x = x,
        .y = bubble_top,
        .w = bw,
        .h = bh,
    }, palette_color, r);
    queuePaletteRect(state, .{
        .x = x + theme.scaledUi(2.5),
        .y = bubble_top + bh - theme.scaledUi(0.5),
        .w = theme.scaledUi(3.0),
        .h = theme.scaledUi(2.5),
    }, palette_color);
}

test "live Amp process wins over stale Cursor terminal metadata" {
    try std.testing.expectEqual(
        TerminalAgentProvider.amp,
        terminalAgentProviderForMetadata(.cursor, "amp", "cursor").?,
    );
}

test "ACTIVE row slots ease toward a new sort position and prune leavers" {
    active_row_slot_count = 0;
    attention_motion_animating = false;
    // New row appears at its target without motion.
    try std.testing.expectEqual(@as(f32, 0.0), activeRowShownY(0, 7, 0.0, 0.5));
    try std.testing.expect(!attention_motion_animating);
    pruneActiveRowSlots();
    // Same row re-sorted one step down eases halfway, then settles.
    try std.testing.expectEqual(@as(f32, 20.0), activeRowShownY(0, 7, 40.0, 0.5));
    try std.testing.expect(attention_motion_animating);
    pruneActiveRowSlots();
    attention_motion_animating = false;
    try std.testing.expectEqual(@as(f32, 40.0), activeRowShownY(0, 7, 40.0, 1.0));
    try std.testing.expect(!attention_motion_animating);
    // A row that was not seen this pass is dropped so it restarts fresh.
    pruneActiveRowSlots();
    try std.testing.expectEqual(@as(usize, 1), active_row_slot_count);
    pruneActiveRowSlots();
    try std.testing.expectEqual(@as(usize, 0), active_row_slot_count);
}

test "ACTIVE cluster viewport height eases including collapse to zero" {
    attention_anim_viewport_h = -1.0;
    attention_motion_animating = false;
    try std.testing.expectEqual(@as(f32, 100.0), easedAttentionViewportH(100.0, 0.5));
    try std.testing.expect(!attention_motion_animating);
    try std.testing.expectEqual(@as(f32, 50.0), easedAttentionViewportH(0.0, 0.5));
    try std.testing.expect(attention_motion_animating);
    attention_motion_animating = false;
    try std.testing.expectEqual(@as(f32, 0.0), easedAttentionViewportH(0.0, 1.0));
    try std.testing.expect(!attention_motion_animating);
    attention_anim_viewport_h = -1.0;
}

test "ACTIVE rows put durable completions first in finish order" {
    var panes = [_]native_state.WorkspacePane{
        .{ .id = 1, .ref = .{ .browser = .{} } },
        .{ .id = 2, .ref = .{ .browser = .{} } },
        .{ .id = 3, .ref = .{ .browser = .{} } },
    };
    var rows = [_]AttentionClusterRow{
        .{ .project_index = 0, .pane = &panes[0], .completed_at_ms = null },
        .{ .project_index = 1, .pane = &panes[1], .completed_at_ms = 200 },
        .{ .project_index = 0, .pane = &panes[2], .completed_at_ms = 100 },
    };

    sortAttentionClusterRows(&rows);
    try std.testing.expectEqual(@as(native_state.WorkspacePaneId, 3), rows[0].pane.id);
    try std.testing.expectEqual(@as(native_state.WorkspacePaneId, 2), rows[1].pane.id);
    try std.testing.expectEqual(@as(native_state.WorkspacePaneId, 1), rows[2].pane.id);
}

test "ACTIVE row cycling wraps and enters from either edge" {
    var panes = [_]native_state.WorkspacePane{
        .{ .id = 11, .ref = .{ .browser = .{} } },
        .{ .id = 22, .ref = .{ .browser = .{} } },
        .{ .id = 33, .ref = .{ .browser = .{} } },
    };
    const rows = [_]AttentionClusterRow{
        .{ .project_index = 0, .pane = &panes[0], .completed_at_ms = null },
        .{ .project_index = 1, .pane = &panes[1], .completed_at_ms = null },
        .{ .project_index = 1, .pane = &panes[2], .completed_at_ms = null },
    };

    try std.testing.expectEqual(@as(usize, 2), adjacentAttentionClusterRowIndex(&rows, 0, 11, -1));
    try std.testing.expectEqual(@as(usize, 1), adjacentAttentionClusterRowIndex(&rows, 0, 11, 1));
    try std.testing.expectEqual(@as(usize, 0), adjacentAttentionClusterRowIndex(&rows, 1, 33, 1));
    try std.testing.expectEqual(@as(usize, 2), adjacentAttentionClusterRowIndex(&rows, 0, null, -1));
    try std.testing.expectEqual(@as(usize, 0), adjacentAttentionClusterRowIndex(&rows, 0, null, 1));
}

test "sidebar tile miniature follows nested split rows" {
    const allocator = std.testing.allocator;
    var layout = try native_state.WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const right_pane_id = try layout.createTerminalPane(allocator, 10);
    try layout.splitPaneWithLeaf(allocator, 1, right_pane_id, .vertical, true);
    try std.testing.expect(layout.joinPaneToScrollGroup(1, right_pane_id));
    try std.testing.expectEqual(@as(usize, 1), sidebarScrollGroupRows(&layout, layout.root.?, 1));

    const bottom_right_pane_id = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, right_pane_id, bottom_right_pane_id, .horizontal, true);
    try std.testing.expect(layout.joinPaneToScrollGroup(right_pane_id, bottom_right_pane_id));
    try std.testing.expectEqual(@as(usize, 2), sidebarScrollGroupRows(&layout, layout.root.?, 1));
}

test "ACTIVE collection sees every restored chat pane and deduplicates one thread owner" {
    const allocator = std.testing.allocator;
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    // Scoped to a different workspace: ACTIVE is global and must still see
    // this workspace's attention panes.
    state.project_controller.selected_index = 1;
    state.sidebar_all_workspaces = false;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var project = try native_state.Project.init(allocator, "active-workspace", "Active", "/tmp/active", 0);
    const second_thread_index = try project.addThread(allocator);
    const second_pane_id = try project.workspace_layout.createChatPane(allocator, second_thread_index);
    try project.workspace_layout.splitPaneWithLeaf(allocator, 1, second_pane_id, .vertical, true);
    const duplicate_pane_id = try project.workspace_layout.createChatPane(allocator, second_thread_index);
    try project.workspace_layout.splitPaneWithLeaf(allocator, second_pane_id, duplicate_pane_id, .horizontal, true);
    project.threads.items[0].completion_pending = true;
    project.threads.items[0].completed_at_ms = 100;
    project.threads.items[second_thread_index].completion_pending = true;
    project.threads.items[second_thread_index].completed_at_ms = 200;
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    var rows: [8]AttentionClusterRow = undefined;
    const row_count = collectAttentionClusterRows(&state, &rows);
    try std.testing.expectEqual(@as(usize, 2), row_count);
    sortAttentionClusterRows(rows[0..row_count]);
    try std.testing.expectEqual(@as(usize, 0), rows[0].pane.ref.chat.thread_index);
    try std.testing.expectEqual(second_thread_index, rows[1].pane.ref.chat.thread_index);
}

test "OPEN interleaves All Workspaces newest-activity first and keeps layout order when scoped" {
    const allocator = std.testing.allocator;
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer state.palette_frame_text_arena.deinit();
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }
    const activity = [_]i64{ 10, 30, 20 };
    for (activity, 0..) |seconds, index| {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "ws-{d}", .{index});
        var project = try native_state.Project.init(allocator, id, id, "/tmp/ws", 0);
        project.threads.items[0].last_activity_at = seconds;
        state.project_controller.projects.append(allocator, project) catch |err| {
            project.deinit(allocator);
            return err;
        };
    }

    const all = collectOpenUnits(&state, true);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqual(@as(usize, 1), all[0].project_index);
    try std.testing.expectEqual(@as(usize, 2), all[1].project_index);
    try std.testing.expectEqual(@as(usize, 0), all[2].project_index);
    try std.testing.expectEqual(@as(i64, 30_000), all[0].recency_ms);

    const scoped = collectOpenUnits(&state, false);
    try std.testing.expectEqual(@as(usize, 1), scoped.len);
    try std.testing.expectEqual(@as(usize, 0), scoped[0].project_index);
}

test "All Workspaces keyboard order follows the displayed OPEN rows" {
    const allocator = std.testing.allocator;
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer state.palette_frame_text_arena.deinit();
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }
    const activity = [_]i64{ 10, 30, 20 };
    for (activity, 0..) |seconds, index| {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "ws-{d}", .{index});
        var project = try native_state.Project.init(allocator, id, id, "/tmp/ws", 0);
        project.threads.items[0].last_activity_at = seconds;
        project.workspace_layout.focused_pane_id = project.workspace_layout.panes.items[0].id;
        state.project_controller.projects.append(allocator, project) catch |err| {
            project.deinit(allocator);
            return err;
        };
    }

    // Displayed order is ws-1, ws-2, ws-0 (newest first). The selected
    // workspace's focused row sits at that displayed position, so Ctrl+N and
    // next/previous step from what the user sees, not layout order.
    const units = collectOpenUnits(&state, true);
    state.project_controller.selected_index = 2;
    try std.testing.expectEqual(@as(?usize, 1), focusedOpenUnitIndex(&state, units));
    state.project_controller.selected_index = 0;
    try std.testing.expectEqual(@as(?usize, 2), focusedOpenUnitIndex(&state, units));
    state.project_controller.selected_index = 1;
    try std.testing.expectEqual(@as(?usize, 0), focusedOpenUnitIndex(&state, units));
}

test "ACTIVE cluster caps viewport at ten rows and leaves room for the workspace tree" {
    const empty = attentionClusterLayout(0, 800, 42, 20, 12, 10, 96);
    try std.testing.expectEqual(@as(f32, 0), empty.content_h);
    try std.testing.expectEqual(@as(f32, 0), empty.viewport_h);

    const short = attentionClusterLayout(3, 800, 42, 20, 12, 10, 96);
    try std.testing.expectEqual(@as(f32, 158), short.content_h);
    try std.testing.expectEqual(@as(f32, 158), short.viewport_h);

    const overflowing = attentionClusterLayout(15, 800, 42, 20, 12, 10, 96);
    try std.testing.expectEqual(@as(f32, 662), overflowing.content_h);
    try std.testing.expectEqual(@as(f32, 452), overflowing.viewport_h);

    const short_rail = attentionClusterLayout(15, 200, 42, 20, 12, 10, 96);
    try std.testing.expectEqual(@as(f32, 104), short_rail.viewport_h);

    const tiny_rail = attentionClusterLayout(15, 80, 42, 20, 12, 10, 96);
    try std.testing.expectEqual(@as(f32, 40), tiny_rail.viewport_h);
}

test "ACTIVE wheel stays in the pinned cluster when it overflows" {
    const previous_sidebar_rect = palette_sidebar_rect;
    const previous_sidebar_scroll = sidebar_scroll_y;
    const previous_sidebar_max = sidebar_max_scroll_y;
    const previous_attention_clip = attention_clip;
    const previous_attention_scroll = attention_scroll_y;
    const previous_attention_max = attention_max_scroll_y;
    defer {
        palette_sidebar_rect = previous_sidebar_rect;
        sidebar_scroll_y = previous_sidebar_scroll;
        sidebar_max_scroll_y = previous_sidebar_max;
        attention_clip = previous_attention_clip;
        attention_scroll_y = previous_attention_scroll;
        attention_max_scroll_y = previous_attention_max;
    }

    palette_sidebar_rect = .{ .x = 0, .y = 0, .w = 240, .h = 800 };
    attention_clip = .{ .x = 0, .y = 100, .w = 240, .h = 200 };
    attention_scroll_y = 0.0;
    attention_max_scroll_y = 400.0;
    sidebar_scroll_y = 0.0;
    sidebar_max_scroll_y = 400.0;

    try std.testing.expect(handlePaletteWheel(40, 150, -1.0));
    try std.testing.expect(attention_scroll_y > 0.0);
    try std.testing.expectEqual(@as(f32, 0), sidebar_scroll_y);

    attention_scroll_y = 0.0;
    try std.testing.expect(handlePaletteWheel(40, 400, -1.0));
    try std.testing.expectEqual(@as(f32, 0), attention_scroll_y);
    try std.testing.expect(sidebar_scroll_y > 0.0);

    sidebar_scroll_y = 0.0;
    attention_max_scroll_y = 0.0;
    try std.testing.expect(handlePaletteWheel(40, 150, -1.0));
    try std.testing.expectEqual(@as(f32, 0), attention_scroll_y);
    try std.testing.expect(sidebar_scroll_y > 0.0);
}

test "workspace settings entry points bind to the invoked workspace" {
    const source = @embedFile("sidebar.zig");
    const switcher_source = @embedFile("command_palette.zig");
    // The switcher row gear and the labelled context-menu row both route
    // through the id-bound opener, never through the selected workspace.
    try std.testing.expect(std.mem.indexOf(u8, switcher_source, "state.openWorkspaceSettingsForProject(pi)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".workspace_open_settings => state.openWorkspaceSettingsForProject(pi)") != null);
}
