//! Workspace rail rendering for the native shell.

const std = @import("std");
const palette = @import("palette");
const sdl = @import("zsdl3");
const theme = @import("theme.zig");
const colors = @import("colors.zig");
const runtime = @import("runtime.zig");
const utils = @import("../utils.zig");
const profiler = @import("../profiler.zig");
const native_state = @import("../state.zig");
const Provider = native_state.Provider;

const log = std.log.scoped(.native_ui_sidebar);

/// Shared ~1.1s sine pulse (0.10..1.0) for working/waiting pips and badges.
/// Marks the frame as hosting an active pip animation so the main loop keeps
/// a ~30fps tick going; without it the loop sleeps between sends' 1Hz label
/// updates and the pulse visibly steps.
fn attentionPulse(state: *runtime.AppState) f32 {
    state.sidebar_pulse_animating = true;
    // Phase math in f64: ms-since-boot exceeds f32's 24-bit mantissa after
    // ~4.6h of uptime, which would quantize the sine into visible steps.
    const now_ms: f64 = @floatFromInt(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    return @floatCast(0.55 + 0.45 * @sin(now_ms / 180.0));
}

/// Saved-thread row: provider bitmap slot (CSS px). Match `COMPOSER_PROVIDER_LOGO_SLOT_CSS` in `chat_panel.zig`.
const SIDEBAR_THREAD_PROVIDER_GLYPH_CSS: f32 = 22.0;
/// Thread row height must fit `SIDEBAR_THREAD_PROVIDER_GLYPH_CSS` with a little vertical air.
const SIDEBAR_THREAD_ROW_HEIGHT_CSS: f32 = 38.0;
/// Vertical advance per thread row (row + gap).
const SIDEBAR_THREAD_ROW_STEP_CSS: f32 = 42.0;
const SIDEBAR_THREAD_ICON_LEADING_PAD_CSS: f32 = 10.0;
/// Horizontal gap between the icon slot and the title.
const SIDEBAR_THREAD_ICON_TITLE_GAP_CSS: f32 = 10.0;
/// Relative-time label starts this far from the row's right edge.
const SIDEBAR_THREAD_TIME_COLUMN_CSS: f32 = 60.0;
/// Padding between truncated title and the time column.
const SIDEBAR_THREAD_TITLE_TIME_GAP_CSS: f32 = 2.0;
const HIDDEN_SIDEBAR_EDGE_REVEAL_CSS: f32 = 8.0;
/// Reserved band at the bottom of the rail for sticky chrome (settings, etc.).
/// The scrolling workspace list stops short of this so its last row never
/// slides under — or past — the pinned footer.
const SIDEBAR_FOOTER_RESERVE_CSS: f32 = 56.0;
const THREAD_DRAG_THRESHOLD_CSS: f32 = 5.0;
const THREAD_DRAG_FLOATING_Z: i32 = 160;

const SidebarHitKind = enum {
    collapse,
    expand,
    add_workspace,
    new_thread,
    workspace_row,
    workspace_avatar,
    open_pane,
    /// Per-workspace "History · N" row; opens the command palette scoped to
    /// that workspace's saved threads.
    history,
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
var sidebar_scroll_y: f32 = 0.0;
var sidebar_max_scroll_y: f32 = 0.0;

const SidebarContextMenuAction = enum {
    workspace_new_chat,
    workspace_open_codex_tui,
    workspace_open_terminal,
    workspace_rename,
    workspace_import_codex,
    workspace_import_opencode,
    workspace_import_claude,
    workspace_archive,
    thread_open_tui,
    thread_open_chat,
    thread_sync,
    thread_archive,
};

var sidebar_menu_panel_rect: palette.Rect = .{};
var sidebar_menu_row_rects: [16]palette.Rect = undefined;
var sidebar_menu_row_actions: [16]SidebarContextMenuAction = undefined;
var sidebar_menu_row_enabled: [16]bool = undefined;
var sidebar_menu_row_labels: [16][]const u8 = undefined;
var sidebar_menu_row_count: usize = 0;

var settings_hovered: bool = false;

const WorkspaceDragState = struct {
    pending: bool = false,
    active: bool = false,
    project_index: usize = 0,
    start_x: f32 = 0.0,
    start_y: f32 = 0.0,
    x: f32 = 0.0,
    y: f32 = 0.0,
};

var workspace_drag: WorkspaceDragState = .{};
/// Drop slot computed during an active workspace drag: insert the dragged
/// project immediately before `workspace_drop_before` (array coordinates).
var workspace_drop_before: usize = 0;
var workspace_drop_line_y: f32 = 0.0;
var workspace_drop_valid: bool = false;

/// Renders the sidebar with Palette-owned drawing and retained hit regions.
pub fn renderPalette(state: *runtime.AppState, rect: palette.Rect) void {
    palette_sidebar_rect = rect;
    palette_hit_count = 0;

    queuePaletteRect(state, rect, paletteColor(theme.COLOR_PANEL));
    queuePaletteRect(state, .{
        .x = rect.x + rect.w - theme.scaledUi(1.0),
        .y = rect.y,
        .w = theme.scaledUi(1.0),
        .h = rect.h,
    }, paletteColor(theme.borderMuted()));

    if (state.isSidebarCollapsed()) {
        renderPaletteCollapsedSidebar(state, rect);
    } else {
        renderPaletteExpandedSidebar(state, rect);
    }
    if (state.sidebar_context_menu_open and !state.isSidebarCollapsed()) {
        renderSidebarContextMenu(state, rect);
    }
}

pub fn pointerOverSidebar(x: f32, y: f32) bool {
    return rectContainsPoint(palette_sidebar_rect, x, y);
}

pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32) void {
    if (state.isSidebarHidden()) {
        const reveal = x <= theme.scaledUi(HIDDEN_SIDEBAR_EDGE_REVEAL_CSS) or rectContainsPoint(palette_sidebar_rect, x, y);
        state.setSidebarHoverRevealed(reveal);
    }

    updateWorkspaceDrag(state, x, y);

    var new_project_hover: ?usize = null;
    var new_new_thread_hover: ?usize = null;
    var new_settings_hover = false;
    if (!state.isSidebarCollapsed() and rectContainsPoint(palette_sidebar_rect, x, y)) {
        // Walk hits in reverse so later (visually-topmost) rows win when
        // overlapping during scroll edge cases.
        var index = palette_hit_count;
        while (index > 0) {
            index -= 1;
            const hit = palette_hits[index];
            if (!rectContainsPoint(hit.rect, x, y)) continue;
            switch (hit.kind) {
                .workspace_row => {
                    if (new_project_hover == null) new_project_hover = hit.project_index;
                },
                .new_thread => {
                    if (new_new_thread_hover == null) new_new_thread_hover = hit.project_index;
                },
                .settings => new_settings_hover = true,
                else => {},
            }
        }
    }

    const project_changed = state.sidebar_project_hover != new_project_hover;
    const new_thread_changed = state.sidebar_new_thread_hover != new_new_thread_hover;
    const settings_changed = settings_hovered != new_settings_hover;
    settings_hovered = new_settings_hover;
    if (!project_changed and !new_thread_changed and !settings_changed) return;

    state.sidebar_project_hover = new_project_hover;
    state.sidebar_new_thread_hover = new_new_thread_hover;
    state.markDirty();
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) {
        if (workspace_drag.pending or workspace_drag.active) return finishWorkspaceDrag(state, x, y);
        return rectContainsPoint(palette_sidebar_rect, x, y);
    }
    if (!rectContainsPoint(palette_sidebar_rect, x, y)) return false;

    if (state.sidebar_context_menu_open and handleSidebarContextMenuPrimary(state, x, y)) {
        return true;
    }

    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_hits[index];
        if (!rectContainsPoint(hit.rect, x, y)) continue;

        switch (hit.kind) {
            .collapse => state.setSidebarCollapsed(true),
            .expand => state.setSidebarCollapsed(false),
            .add_workspace => {
                state.show_project_creator = true;
                state.setSidebarCollapsed(false);
                state.clearImportPath();
                state.project_import_cursor = 0;
                state.palette_modal_text_focus = .project_import;
                state.setSidebarNotice("");
                state.markDirty();
            },
            .new_thread => {
                if (state.projects.items.len > 0) state.createThreadForProject(@min(hit.project_index, state.projects.items.len - 1));
            },
            .workspace_row => {
                if (hit.project_index < state.projects.items.len) {
                    // Begin a pending drag; a release without movement is
                    // treated as a click (select + collapse toggle) in
                    // finishWorkspaceDrag, while movement past the threshold
                    // promotes to a reorder drag.
                    workspace_drop_valid = false;
                    workspace_drag = .{
                        .pending = true,
                        .project_index = hit.project_index,
                        .start_x = x,
                        .start_y = y,
                        .x = x,
                        .y = y,
                    };
                    _ = sdl.captureMouse(true);
                }
            },
            .open_pane => {
                state.focusWorkspaceOpenPane(hit.project_index, @intCast(hit.thread_index));
            },
            .workspace_avatar => {
                if (hit.project_index < state.projects.items.len) {
                    state.selected_project_index = hit.project_index;
                    state.markDirty();
                }
            },
            .history => {
                if (hit.project_index < state.projects.items.len) {
                    state.openCommandPalette(hit.project_index);
                }
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
    sidebar_scroll_y = theme.clampf(sidebar_scroll_y - wheel_y * theme.scaledUi(64.0), 0.0, sidebar_max_scroll_y);
    return true;
}

/// SDL mouse button id for right-click (`SDL_BUTTON_RIGHT`).
pub const palette_mouse_button_secondary: u8 = 3;

pub fn handlePaletteSecondaryMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) return false;
    if (state.isSidebarCollapsed()) return false;
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
            .workspace_row => {
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
            else => {},
        }
    }
    return false;
}

pub fn renderFloatingDragPreview(state: *runtime.AppState) void {
    renderWorkspaceDragOverlay(state);
}

pub fn hasActiveThreadDrag() bool {
    return workspace_drag.pending or workspace_drag.active;
}

pub fn finishThreadDragIfMouseReleased(state: *runtime.AppState, x: f32, y: f32, buttons: sdl.MouseButtonFlags) bool {
    if (workspace_drag.pending or workspace_drag.active) {
        if (buttons.left != 0) return false;
        return finishWorkspaceDrag(state, x, y);
    }
    return false;
}

fn updateWorkspaceDrag(state: *runtime.AppState, x: f32, y: f32) void {
    if (!workspace_drag.pending and !workspace_drag.active) return;
    workspace_drag.x = x;
    workspace_drag.y = y;
    if (workspace_drag.pending) {
        const dx = x - workspace_drag.start_x;
        const dy = y - workspace_drag.start_y;
        const threshold = theme.scaledUi(THREAD_DRAG_THRESHOLD_CSS);
        if (dx * dx + dy * dy >= threshold * threshold) {
            workspace_drag.pending = false;
            workspace_drag.active = true;
        }
    }
    if (workspace_drag.active) computeWorkspaceDropTarget(y);
    state.markDirty();
}

/// Scans the retained workspace-row hit rects (in project order) to find where
/// a drop at vertical position `y` should insert.
fn computeWorkspaceDropTarget(y: f32) void {
    workspace_drop_valid = false;
    var index: usize = 0;
    while (index < palette_hit_count) : (index += 1) {
        const hit = palette_hits[index];
        if (hit.kind != .workspace_row) continue;
        const r = hit.rect;
        if (y < r.y) {
            workspace_drop_before = hit.project_index;
            workspace_drop_line_y = r.y;
            workspace_drop_valid = true;
            return;
        }
        if (y <= r.y + r.h) {
            if (y < r.y + r.h * 0.5) {
                workspace_drop_before = hit.project_index;
                workspace_drop_line_y = r.y;
            } else {
                workspace_drop_before = hit.project_index + 1;
                workspace_drop_line_y = r.y + r.h;
            }
            workspace_drop_valid = true;
            return;
        }
        // Cursor is below this row; remember it as the running candidate so a
        // drop past the last row lands at the end.
        workspace_drop_before = hit.project_index + 1;
        workspace_drop_line_y = r.y + r.h;
        workspace_drop_valid = true;
    }
}

fn finishWorkspaceDrag(state: *runtime.AppState, x: f32, y: f32) bool {
    _ = x;
    _ = y;
    const drag = workspace_drag;
    workspace_drag = .{};
    _ = sdl.captureMouse(false);

    if (!drag.active) {
        // No meaningful movement — treat as a plain click on the row.
        if (drag.project_index < state.projects.items.len) {
            state.noteInteraction();
            state.selected_project_index = drag.project_index;
            state.projects.items[drag.project_index].collapsed = !state.projects.items[drag.project_index].collapsed;
            state.syncRenameBuffer();
            state.requestTranscriptScrollToBottom();
            state.markDirty();
        }
        workspace_drop_valid = false;
        return true;
    }

    if (workspace_drop_valid) state.moveProject(drag.project_index, workspace_drop_before);
    workspace_drop_valid = false;
    state.markDirty();
    return true;
}

fn renderWorkspaceDragOverlay(state: *runtime.AppState) void {
    if (!workspace_drag.active) return;
    if (workspace_drag.project_index >= state.projects.items.len) return;

    const previous_z = state.palette_overlay_batch.setZIndex(THREAD_DRAG_FLOATING_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    if (workspace_drop_valid) {
        const line_h = theme.scaledUi(2.0);
        const inset = theme.scaledUi(25.0);
        queuePaletteRoundedRect(state, .{
            .x = palette_sidebar_rect.x + inset,
            .y = workspace_drop_line_y - line_h * 0.5,
            .w = palette_sidebar_rect.w - inset * 2.0,
            .h = line_h,
        }, paletteColor(theme.COLOR_GREEN), line_h * 0.5);
    }

    const project = &state.projects.items[workspace_drag.project_index];
    const w = theme.scaledUi(200.0);
    const h = theme.scaledUi(30.0);
    const rect: palette.Rect = .{
        .x = workspace_drag.x + theme.scaledUi(12.0),
        .y = workspace_drag.y + theme.scaledUi(8.0),
        .w = w,
        .h = h,
    };
    queuePaletteRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 232)), theme.scaledUi(8.0));
    queuePaletteBorder(state, rect, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 180)), theme.scaledUi(8.0), theme.scaledUi(1.0));
    const font = theme.scaledUi(13.5);
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(12.0),
        .y = rect.y + (rect.h - font * 1.25) * 0.5,
        .w = rect.w - theme.scaledUi(20.0),
        .h = font * 1.25,
    }, project.label, paletteColor(theme.COLOR_WHITE), font, rect);
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
                    if (pi < state.projects.items.len) state.createThreadForProject(pi);
                },
                .workspace_open_codex_tui => _ = state.openAgentTui(pi, .codex) catch false,
                .workspace_open_terminal => _ = state.openTerminalPaneForProjectIndex(pi),
                .workspace_rename => state.beginProjectRename(pi),
                .workspace_import_codex => state.beginThreadImport(pi, .codex),
                .workspace_import_opencode => state.beginThreadImport(pi, .opencode),
                .workspace_import_claude => state.beginThreadImport(pi, .claude),
                .workspace_archive => state.archiveProjectAtIndex(pi),
                .thread_open_tui => state.openThreadInTui(pi, ti),
                .thread_open_chat => state.openThreadInChat(pi, ti),
                .thread_sync => state.syncThreadFromProvider(pi, ti),
                .thread_archive => state.archiveThreadAtIndex(pi, ti),
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
    };
}

fn renderSidebarContextMenu(state: *runtime.AppState, sidebar_rect: palette.Rect) void {
    if (!state.sidebar_context_menu_open) return;

    const pad = theme.scaledUi(6.0);
    const menu_w = theme.scaledUi(248.0);
    const menu_pad = theme.scaledUi(8.0);
    const menu_row_h = theme.scaledUi(34.0);
    const font_size = theme.scaledUi(14.0);

    sidebar_menu_row_count = 0;
    switch (state.sidebar_context_menu_kind) {
        .none => return,
        .project => {
            const pi = state.sidebar_context_menu_project_index;
            appendSidebarContextMenuRow(.workspace_new_chat, true, "Start a new chat");
            appendSidebarContextMenuRow(.workspace_open_codex_tui, pi < state.projects.items.len, "Open Codex TUI");
            appendSidebarContextMenuRow(.workspace_open_terminal, pi < state.projects.items.len, "Open terminal");
            appendSidebarContextMenuRow(.workspace_rename, true, "Rename workspace");
            appendSidebarContextMenuRow(.workspace_import_codex, true, "Import Codex thread");
            appendSidebarContextMenuRow(.workspace_import_opencode, true, "Import OpenCode thread");
            appendSidebarContextMenuRow(.workspace_import_claude, true, "Import Claude thread");
            var busy = false;
            if (pi < state.projects.items.len) {
                for (state.projects.items[pi].threads.items) |*th| {
                    if (th.isSendPendingForUi()) {
                        busy = true;
                        break;
                    }
                }
            }
            appendSidebarContextMenuRow(.workspace_archive, !busy, "Archive workspace");
        },
        .project_new_thread => {
            const pi = state.sidebar_context_menu_project_index;
            appendSidebarContextMenuRow(.workspace_new_chat, pi < state.projects.items.len, "Start a new chat");
            appendSidebarContextMenuRow(.workspace_open_codex_tui, pi < state.projects.items.len, "Open Codex TUI");
        },
        .thread => {
            const pi = state.sidebar_context_menu_project_index;
            const ti = state.sidebar_context_menu_thread_index;
            var can_sync = false;
            var can_archive = true;
            var provider: Provider = .opencode;
            var in_tui = false;
            if (pi < state.projects.items.len) {
                const proj = state.projects.items[pi];
                if (ti < proj.threads.items.len) {
                    const th = proj.threads.items[ti];
                    can_sync = th.provider_thread_id != null and !th.isSendPendingForUi();
                    can_archive = !th.isSendPendingForUi();
                    provider = th.provider;
                    in_tui = state.threadIsOpenInTui(pi, ti);
                }
            }
            appendSidebarContextMenuRow(.thread_sync, can_sync, "Sync thread");
            if (in_tui) {
                appendSidebarContextMenuRow(.thread_open_chat, true, "Open as chat");
            } else {
                appendSidebarContextMenuRow(.thread_open_tui, can_sync, openTuiLabel(provider));
            }
            appendSidebarContextMenuRow(.thread_archive, can_archive, "Archive thread");
        },
    }

    if (sidebar_menu_row_count == 0) return;

    const menu_h = menu_pad * 2.0 + @as(f32, @floatFromInt(sidebar_menu_row_count)) * menu_row_h;
    var menu_x = state.sidebar_context_menu_anchor_x;
    var menu_y = state.sidebar_context_menu_anchor_y;
    menu_x = theme.clampf(menu_x, sidebar_rect.x + pad, sidebar_rect.x + sidebar_rect.w - menu_w - pad);
    menu_y = theme.clampf(menu_y, sidebar_rect.y + pad, sidebar_rect.y + sidebar_rect.h - menu_h - pad);

    sidebar_menu_panel_rect = .{ .x = menu_x, .y = menu_y, .w = menu_w, .h = menu_h };
    const clip = sidebar_menu_panel_rect;

    queuePaletteRoundedRect(state, sidebar_menu_panel_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(12.0));
    queuePaletteBorder(state, sidebar_menu_panel_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(12.0), theme.scaledUi(1.0));

    const mx = state.palette_mouse_x;
    const my = state.palette_mouse_y;
    const mouse_ok = state.palette_mouse_in_workspace;

    var ry = menu_y + menu_pad;
    var ri: usize = 0;
    while (ri < sidebar_menu_row_count) : (ri += 1) {
        const rr: palette.Rect = .{
            .x = menu_x + theme.scaledUi(4.0),
            .y = ry,
            .w = menu_w - theme.scaledUi(8.0),
            .h = menu_row_h,
        };
        sidebar_menu_row_rects[ri] = rr;

        const row_hover = mouse_ok and sidebar_menu_row_enabled[ri] and rectContainsPoint(rr, mx, my);
        if (row_hover) {
            queuePaletteRoundedRect(state, rr, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(8.0));
        }

        const row_col = paletteColor(if (!sidebar_menu_row_enabled[ri])
            theme.COLOR_TEXT_SUBTLE
        else if (row_hover)
            theme.COLOR_WHITE
        else
            theme.COLOR_TEXT_MUTED);

        const label = sidebar_menu_row_labels[ri];
        queuePaletteText(state, .{
            .x = rr.x + theme.scaledUi(12.0),
            .y = rr.y + (menu_row_h - font_size * 1.25) * 0.5,
            .w = rr.w - theme.scaledUi(16.0),
            .h = font_size * 1.25,
        }, label, row_col, font_size, clip);

        ry += menu_row_h;
    }
}

fn renderPaletteExpandedSidebar(state: *runtime.AppState, rect: palette.Rect) void {
    const pad_x = theme.scaledUi(25.0);
    const rail_w = @max(rect.w - pad_x * 2.0, theme.scaledUi(140.0));
    const x = rect.x + pad_x;

    // The logo, sidebar-collapse toggle, "WORKSPACES" label, and add-workspace
    // button stay pinned at the top of the rail; only the workspace list
    // scrolls beneath them. The header is rendered AFTER the list (with a
    // background strip first) so any list rows scrolled into the header band
    // are visually overwritten — no z-index plumbing required.
    const header_top = rect.y + theme.scaledUi(31.0);
    const projects_label_y = header_top + theme.scaledUi(92.0);
    const list_top = projects_label_y + theme.scaledUi(38.0);
    // Reserve a band at the bottom of the rail for sticky chrome. Clipping the
    // list short here also caps `sidebar_max_scroll_y` (computed below from
    // `list_clip.y + list_clip.h`), so the list scrolls to rest above the
    // footer instead of running off the bottom edge.
    const footer_reserve = theme.scaledUi(SIDEBAR_FOOTER_RESERVE_CSS);
    const list_bottom = @max(rect.y + rect.h - footer_reserve, list_top);
    const list_clip: palette.Rect = .{ .x = rect.x, .y = list_top, .w = rect.w, .h = @max(list_bottom - list_top, 0.0) };
    const clip = list_clip;
    var y = list_top - sidebar_scroll_y;

    var project_index: usize = 0;
    while (project_index < state.projects.items.len) : (project_index += 1) {
        const project = &state.projects.items[project_index];
        const selected = state.selected_project_index == project_index;
        const collapsed = project.collapsed;
        const row_h = theme.scaledUi(28.0);
        const action_w = theme.scaledUi(32.0);
        const row_rect: palette.Rect = .{ .x = x, .y = y, .w = rail_w - action_w - theme.scaledUi(6.0), .h = row_h };
        const project_visible = rowVisible(row_rect, list_clip);
        const project_hovered = state.sidebar_project_hover == project_index;
        if (project_visible) {
            if (selected) {
                // Darker than the sidebar panel itself (matches the chat
                // transcript's CHAT_BLACK) plus a muted border so the active
                // workspace reads as a recessed card.
                state.palette_overlay_batch.panel(
                    state.allocator,
                    snapRect(row_rect),
                    paletteColor(theme.background()),
                    paletteColor(theme.COLOR_PANEL_MUTED),
                    theme.scaledUi(6.0),
                    theme.scaledUi(1.0),
                ) catch {};
            } else if (project_hovered) {
                queuePaletteRoundedRect(state, row_rect, paletteColor(theme.withAlpha(theme.COLOR_SECONDARY_GREEN, 180)), theme.scaledUi(6.0));
            }
        }
        if (project_visible) addPaletteHit(row_rect, .workspace_row, project_index, 0);

        const cy = y + row_h * 0.5;
        // Inset the chevron from the bordered row's left edge so the chevron
        // visually centers within the card rather than hugging the border.
        var tx = x + theme.scaledUi(14.0);
        const chevron_color: [4]f32 = if (selected or project_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE;
        if (project_visible) queuePaletteChevron(state, tx, cy, chevron_color, collapsed);
        // Chevron renders into a ~14px wide cell — leave room before the
        // folder icon so the arrow doesn't crowd the project title.
        tx += theme.scaledUi(18.0);
        if (project_visible) queuePaletteFolderIcon(state, tx, cy, theme.scaledUi(14.0), theme.scaledUi(10.0), if (selected) theme.COLOR_SECONDARY_GREEN else if (project_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE, selected);
        tx += theme.scaledUi(20.0);
        if (project_visible) queuePaletteText(state, .{ .x = tx, .y = y + theme.scaledUi(4.0), .w = row_rect.x + row_rect.w - tx, .h = row_h }, project.label, paletteColor(if (selected or project_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(15.0), row_rect);
        const new_rect: palette.Rect = .{ .x = rect.x + rect.w - pad_x - action_w, .y = y, .w = action_w, .h = row_h };
        const new_hovered = state.sidebar_new_thread_hover == project_index;
        if (project_visible) {
            if (new_hovered) {
                queuePaletteRoundedRect(state, new_rect, paletteColor(theme.withAlpha(theme.COLOR_SECONDARY_GREEN, 200)), theme.scaledUi(6.0));
            }
            queuePaletteEditGlyph(state, .{ new_rect.x, new_rect.y }, new_rect.w, new_rect.h, if (new_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED);
            addPaletteHit(new_rect, .new_thread, project_index, 0);
        }
        y += row_h + theme.scaledUi(4.0);

        if (!collapsed) {
            y = renderOpenPanesSection(state, project_index, project, x, rail_w, list_clip, clip, y);
            y = renderHistoryRow(state, project_index, project, x, rail_w, list_clip, clip, y);
        } else {
            y = renderAttentionPanesSection(state, project_index, project, x, rail_w, list_clip, clip, y);
        }
        y += theme.scaledUi(8.0);
    }

    // Scrollbar must clip to the list area so the thumb never extends behind
    // the pinned header strip drawn below.
    sidebar_max_scroll_y = @max(0.0, y + sidebar_scroll_y - (list_clip.y + list_clip.h) + theme.scaledUi(8.0));
    sidebar_scroll_y = theme.clampf(sidebar_scroll_y, 0.0, sidebar_max_scroll_y);
    if (sidebar_max_scroll_y > 1.0 and list_clip.h > theme.scaledUi(32.0)) {
        const track: palette.Rect = .{ .x = rect.x + rect.w - theme.scaledUi(4.0), .y = list_clip.y + theme.scaledUi(4.0), .w = theme.scaledUi(3.0), .h = list_clip.h - theme.scaledUi(8.0) };
        const thumb_h = @max(theme.scaledUi(34.0), track.h * (track.h / (track.h + sidebar_max_scroll_y)));
        const thumb_y = track.y + (track.h - thumb_h) * (sidebar_scroll_y / sidebar_max_scroll_y);
        queuePaletteRoundedRect(state, track, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 120)), theme.scaledUi(2.0));
        queuePaletteRoundedRect(state, .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, paletteColor(theme.withAlpha(theme.COLOR_TEXT_MUTED, 200)), theme.scaledUi(2.0));
    }

    // Pinned footer band — painted after the list so any row scrolled into the
    // reserved band is covered by the panel-colored strip. A divider marks the
    // top edge so the boundary is visible; sticky chrome (settings, etc.) lands
    // here later.
    if (list_bottom < rect.y + rect.h) {
        const footer_rect: palette.Rect = .{
            .x = rect.x,
            .y = list_bottom,
            .w = rect.w - theme.scaledUi(1.0),
            .h = rect.y + rect.h - list_bottom,
        };
        // Blend with the sidebar (COLOR_PANEL) so the band reads as part of the
        // rail, with just a hairline divider separating it from the list.
        queuePaletteRect(state, footer_rect, paletteColor(theme.COLOR_PANEL));
        queuePaletteRect(state, .{
            .x = rect.x,
            .y = list_bottom,
            .w = rect.w - theme.scaledUi(1.0),
            .h = theme.scaledUi(1.0),
        }, paletteColor(theme.borderMuted()));

        // Compact gear icon button aligned to the rail, with a square
        // hover-highlight matching the rest of the sidebar's row language.
        const btn = theme.scaledUi(34.0);
        const btn_rect: palette.Rect = .{
            .x = rect.x + rect.w - pad_x - btn,
            .y = footer_rect.y + (footer_rect.h - btn) * 0.5,
            .w = btn,
            .h = btn,
        };
        const settings_hover = state.palette_mouse_in_workspace and rectContainsPoint(btn_rect, state.palette_mouse_x, state.palette_mouse_y);
        if (settings_hover) {
            queuePaletteRoundedRect(state, btn_rect, paletteColor(theme.withAlpha(theme.COLOR_SECONDARY_GREEN, 180)), theme.scaledUi(8.0));
        }
        const fg = if (settings_hover) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
        const icon_font = theme.scaledUi(17.0);
        queuePaletteIcon(state, .{
            .x = btn_rect.x + (btn_rect.w - icon_font) * 0.5,
            .y = btn_rect.y + (btn_rect.h - icon_font) * 0.5,
            .w = icon_font,
            .h = icon_font,
        }, NF_COD_GEAR, icon_font, paletteColor(fg), footer_rect);
        addPaletteHit(btn_rect, .settings, 0, 0);
    }

    // Pinned header — painted last so any scrolled rows in the header band
    // are covered by the panel-colored strip before the chrome paints on top.
    queuePaletteRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w - theme.scaledUi(1.0), .h = list_top - rect.y }, paletteColor(theme.COLOR_PANEL));
    queuePaletteLogoMark(state, .{ .x = x, .y = header_top, .w = theme.scaledUi(42.0), .h = theme.scaledUi(42.0) });
    queuePaletteText(state, .{ .x = x + theme.scaledUi(54.0), .y = header_top + theme.scaledUi(4.0), .w = theme.scaledUi(130.0), .h = theme.scaledUi(38.0) }, "verde", paletteColor(theme.COLOR_WHITE), theme.heading_font_size, rect);

    const toggle_rect: palette.Rect = .{ .x = rect.x + rect.w - pad_x - theme.scaledUi(28.0), .y = header_top + theme.scaledUi(6.0), .w = theme.scaledUi(28.0), .h = theme.scaledUi(28.0) };
    queuePaletteButton(state, toggle_rect, "<", false);
    addPaletteHit(toggle_rect, .collapse, 0, 0);

    queuePaletteText(state, .{ .x = x, .y = projects_label_y, .w = theme.scaledUi(150.0), .h = theme.scaledUi(24.0) }, "WORKSPACES", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(16.0), rect);
    const add_rect: palette.Rect = .{ .x = rect.x + rect.w - pad_x - theme.scaledUi(28.0), .y = projects_label_y - theme.scaledUi(2.0), .w = theme.scaledUi(28.0), .h = theme.scaledUi(28.0) };
    queuePaletteButton(state, add_rect, "+", true);
    addPaletteHit(add_rect, .add_workspace, 0, 0);
}

fn renderPaletteCollapsedSidebar(state: *runtime.AppState, rect: palette.Rect) void {
    const button = theme.scaledUi(36.0);
    const x = rect.x + (rect.w - button) * 0.5;
    var y = rect.y + theme.scaledUi(30.0);
    queuePaletteLogoMark(state, .{ .x = x + theme.scaledUi(2.0), .y = y, .w = theme.scaledUi(32.0), .h = theme.scaledUi(32.0) });
    y += theme.scaledUi(58.0);
    const expand_rect: palette.Rect = .{ .x = x, .y = y, .w = button, .h = theme.scaledUi(30.0) };
    queuePaletteButton(state, expand_rect, ">", false);
    addPaletteHit(expand_rect, .expand, 0, 0);
    y += theme.scaledUi(38.0);
    const new_rect: palette.Rect = .{ .x = x, .y = y, .w = button, .h = theme.scaledUi(30.0) };
    queuePaletteEditGlyph(state, .{ new_rect.x, new_rect.y }, new_rect.w, new_rect.h, theme.COLOR_TEXT_MUTED);
    addPaletteHit(new_rect, .new_thread, state.selected_project_index, 0);
    y += theme.scaledUi(34.0);

    // Hairline divider, then a vertical "activity dock" of workspace avatars so
    // the narrow rail shows every workspace, which one is active, and whether
    // any of its panes need attention — instead of being a dead button strip.
    queuePaletteRect(state, .{ .x = x + theme.scaledUi(6.0), .y = y, .w = button - theme.scaledUi(12.0), .h = theme.scaledUi(1.0) }, paletteColor(theme.borderMuted()));
    y += theme.scaledUi(12.0);

    const avatar = theme.scaledUi(36.0);
    const dock_bottom = rect.y + rect.h - theme.scaledUi(48.0);
    var project_index: usize = 0;
    while (project_index < state.projects.items.len) : (project_index += 1) {
        if (y + avatar > dock_bottom) break; // keep the rail tidy; expand to see the rest
        const project = &state.projects.items[project_index];
        const selected = state.selected_project_index == project_index;
        const avatar_rect: palette.Rect = .{ .x = x, .y = y, .w = avatar, .h = avatar };
        const hovered = state.palette_mouse_in_workspace and rectContainsPoint(avatar_rect, state.palette_mouse_x, state.palette_mouse_y);

        // The active workspace reads as a bold filled chip in the theme accent —
        // mirroring (and amplifying) the green filled folder of the expanded
        // view's selected row — with a left accent bar for an unmistakable cue.
        const bg = if (selected)
            paletteColor(theme.COLOR_SECONDARY_GREEN)
        else if (hovered)
            paletteColor(theme.withAlpha(theme.COLOR_SECONDARY_GREEN, 110))
        else
            paletteColor(theme.COLOR_PANEL_ALT);
        queuePaletteRoundedRect(state, avatar_rect, bg, theme.scaledUi(9.0));
        if (selected) {
            const bar_h = avatar * 0.55;
            queuePaletteRoundedRect(state, .{
                .x = rect.x + theme.scaledUi(2.0),
                .y = avatar_rect.y + (avatar - bar_h) * 0.5,
                .w = theme.scaledUi(3.0),
                .h = bar_h,
            }, paletteColor(theme.COLOR_SECONDARY_GREEN), theme.scaledUi(1.5));
        }

        // Workspace initial as the avatar mark. queuePaletteText is left-aligned,
        // so center it manually (single glyph ~= font * 0.6 wide). On the filled
        // active chip the initial reverses out to the dark panel color.
        var letter_buf: [1]u8 = undefined;
        const letter = workspaceInitial(&letter_buf, project.label);
        const letter_font = theme.scaledUi(15.0);
        const letter_w = letter_font * 0.6;
        const letter_color = if (selected)
            theme.background()
        else if (hovered)
            theme.COLOR_WHITE
        else
            theme.COLOR_TEXT_MUTED;
        queuePaletteText(state, .{
            .x = @round(avatar_rect.x + (avatar - letter_w) * 0.5),
            .y = @round(avatar_rect.y + (avatar - letter_font * 1.25) * 0.5),
            .w = letter_w + theme.scaledUi(3.0),
            .h = letter_font * 1.25,
        }, letter, paletteColor(letter_color), letter_font, null);

        // Attention badge tucked into the top-right corner, kept fully inside the
        // narrow rail so it doesn't clip against the panel edge.
        if (workspaceStatusColor(state, project_index)) |badge| {
            const pulse = attentionPulse(state);
            const badge_d = theme.scaledUi(8.0);
            queuePaletteRoundedRect(state, .{
                .x = avatar_rect.x + avatar - badge_d - theme.scaledUi(2.0),
                .y = avatar_rect.y + theme.scaledUi(2.0),
                .w = badge_d,
                .h = badge_d,
            }, paletteColor(theme.withAlpha(badge, @intFromFloat(pulse * 255.0))), badge_d * 0.5);
        }

        addPaletteHit(avatar_rect, .workspace_avatar, project_index, 0);
        y += avatar + theme.scaledUi(5.0);

        // Composition dots: one per open (non-minimized) pane, colored by kind.
        renderCollapsedCompositionDots(state, project, avatar_rect.x + avatar * 0.5, y);
        y += theme.scaledUi(11.0);
    }

    const add_rect: palette.Rect = .{ .x = x, .y = rect.y + rect.h - theme.scaledUi(42.0), .w = button, .h = theme.scaledUi(30.0) };
    queuePaletteButton(state, add_rect, "+", true);
    addPaletteHit(add_rect, .add_workspace, 0, 0);
}

/// Writes the uppercase first letter of a workspace label into `buf` for use as
/// a collapsed-rail avatar mark, returning the rendered slice.
fn workspaceInitial(buf: *[1]u8, label: []const u8) []const u8 {
    if (label.len == 0) return "?";
    buf[0] = switch (label[0]) {
        'a'...'z' => label[0] - 32,
        else => label[0],
    };
    return buf[0..1];
}

/// Aggregate attention color for a workspace's panes (error > waiting > working),
/// or null when nothing needs attention. Used by the collapsed activity dock.
fn workspaceStatusColor(state: *runtime.AppState, project_index: usize) ?[4]f32 {
    if (project_index >= state.projects.items.len) return null;
    const project = &state.projects.items[project_index];
    var has_waiting = false;
    var has_working = false;
    for (project.workspace_layout.panes.items) |pane| {
        switch (pane.ref) {
            .terminal => |ref| {
                if (state.isFocusedTerminalSurface(project_index, ref.dock_id)) continue;
                if (state.projectTerminalSurface(project_index, ref.dock_id)) |surface| {
                    switch (surface.status) {
                        .@"error" => return theme.COLOR_DIFF_REMOVE,
                        .waiting => has_waiting = true,
                        .working => has_working = true,
                        else => {},
                    }
                }
            },
            .chat => |ref| {
                if (ref.thread_index < project.threads.items.len and project.threads.items[ref.thread_index].isSendPendingForUi()) has_working = true;
            },
            .browser => {},
        }
    }
    if (has_waiting) return theme.COLOR_YELLOW;
    if (has_working) return theme.COLOR_SECONDARY_GREEN;
    return null;
}

/// Draws a centered row of small dots — one per open pane, colored by kind —
/// beneath a collapsed workspace avatar.
fn renderCollapsedCompositionDots(state: *runtime.AppState, project: *const native_state.Project, center_x: f32, y: f32) void {
    const max_dots = 4;
    var count: usize = 0;
    for (project.workspace_layout.panes.items) |pane| {
        if (pane.minimized) continue;
        count += 1;
    }
    if (count == 0) return;
    const shown = @min(count, max_dots);
    const dot = theme.scaledUi(4.0);
    const gap = theme.scaledUi(3.0);
    const total_w = @as(f32, @floatFromInt(shown)) * dot + @as(f32, @floatFromInt(shown - 1)) * gap;
    var dx = center_x - total_w * 0.5;
    var drawn: usize = 0;
    for (project.workspace_layout.panes.items) |pane| {
        if (pane.minimized) continue;
        if (drawn >= max_dots) break;
        const color = switch (pane.ref) {
            .chat => theme.COLOR_SECONDARY_GREEN,
            .terminal => theme.COLOR_TEXT_MUTED,
            .browser => theme.COLOR_GREEN,
        };
        queuePaletteRoundedRect(state, .{ .x = dx, .y = y, .w = dot, .h = dot }, paletteColor(color), dot * 0.5);
        dx += dot + gap;
        drawn += 1;
    }
}

fn queuePaletteRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch |err| {
        log.warn("failed to queue sidebar palette rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, green: bool) void {
    queuePaletteRoundedRect(state, rect, paletteColor(if (green) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_ALT), theme.scaledUi(8.0));
    const font_size = theme.scaledUi(16.0);
    const text_width = @as(f32, @floatFromInt(label.len)) * font_size * 0.55;
    queuePaletteText(state, .{
        .x = rect.x + (rect.w - text_width) * 0.5,
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = @max(text_width, theme.scaledUi(4.0)),
        .h = font_size * 1.25,
    }, label, paletteColor(theme.COLOR_WHITE), font_size, rect);
}

/// Renders the live "OPEN" list of a workspace's layout panes (chat / terminal
/// / browser) above the saved-chats history, so every pane kind is visible and
/// directly focusable from the sidebar. Returns the advanced y cursor.
fn renderOpenPanesSection(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    x: f32,
    rail_w: f32,
    list_clip: palette.Rect,
    clip: palette.Rect,
    y_in: f32,
) f32 {
    var y = y_in;
    const layout = &project.workspace_layout;
    if (layout.panes.items.len == 0) return y;

    const label_rect: palette.Rect = .{ .x = x + theme.scaledUi(24.0), .y = y, .w = rail_w - theme.scaledUi(24.0), .h = theme.scaledUi(20.0) };
    if (rowVisible(label_rect, list_clip)) queuePaletteText(state, label_rect, "OPEN", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), clip);
    y += theme.scaledUi(22.0);

    for (layout.panes.items) |*pane| {
        const row_rect: palette.Rect = .{
            .x = x + theme.scaledUi(24.0),
            .y = y,
            .w = rail_w - theme.scaledUi(42.0),
            .h = theme.scaledUi(SIDEBAR_THREAD_ROW_HEIGHT_CSS),
        };
        if (rowVisible(row_rect, list_clip)) renderOpenPaneRow(state, project_index, project, pane, row_rect, clip);
        y += theme.scaledUi(SIDEBAR_THREAD_ROW_STEP_CSS);
    }
    y += theme.scaledUi(6.0);
    return y;
}

fn renderOpenPaneRow(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    pane: *const native_state.WorkspacePane,
    rect: palette.Rect,
    clip: palette.Rect,
) void {
    const layout = &project.workspace_layout;
    const focused = state.selected_project_index == project_index and layout.focused_pane_id == pane.id;
    const hovered = state.palette_mouse_in_workspace and rectContainsPoint(rect, state.palette_mouse_x, state.palette_mouse_y);
    if (focused) {
        queuePaletteRoundedRect(state, snapRect(rect), paletteColor(theme.borderMuted()), theme.scaledUi(7.0));
    } else if (hovered) {
        queuePaletteRoundedRect(state, snapRect(rect), paletteColor(theme.withAlpha(theme.COLOR_SECONDARY_GREEN, 210)), theme.scaledUi(7.0));
    }
    addPaletteHit(rect, .open_pane, project_index, pane.id);

    const dim = pane.minimized;
    const cy = rect.y + rect.h * 0.5;
    const icon_x = rect.x + theme.scaledUi(SIDEBAR_THREAD_ICON_LEADING_PAD_CSS);
    const muted = if (dim) theme.COLOR_TEXT_SUBTLE else theme.COLOR_TEXT_MUTED;

    // Backing storage for the terminal pane's live tab title and the foreground
    // process name used for provider detection; must outlive the render below,
    // so they live at function scope.
    var term_title_buf: [96]u8 = undefined;
    var comm_buf: [96]u8 = undefined;
    var title: []const u8 = "";
    var running = false;
    var status: ?native_state.SurfaceStatus = null;
    switch (pane.ref) {
        .chat => |ref| {
            if (ref.thread_index < project.threads.items.len) {
                const thread = &project.threads.items[ref.thread_index];
                queuePaletteProviderGlyph(state, thread.provider, icon_x, cy, clip);
                title = thread.title;
                running = thread.isSendPendingForUi();
            } else {
                queuePaletteChatBubbleIcon(state, icon_x, cy, muted);
                title = "Chat";
            }
        },
        .terminal => |ref| {
            const surface = state.projectTerminalSurface(project_index, ref.dock_id);
            if (surface) |s| {
                status = s.status;
                if (s.status == .working) running = true;
            }
            // Detect a running agent (Claude/Codex/etc.) from the surface
            // provider or the foreground process name, and draw a split
            // provider+terminal glyph for it; otherwise a plain terminal glyph.
            var agent_provider: ?Provider = if (surface) |s| s.provider else null;
            if (agent_provider == null) {
                if (state.projectTerminalDock(project_index, ref.dock_id)) |dock| {
                    // Live foreground process when running, else the provider
                    // pinned by the notify hook (persisted across restarts,
                    // available before the agent process is revived).
                    if (dock.activeForegroundProcessName(&comm_buf)) |comm| agent_provider = providerFromComm(comm);
                    if (agent_provider == null) {
                        if (dock.activeTabPinnedProvider()) |name| agent_provider = std.meta.stringToEnum(Provider, name);
                    }
                }
            }
            if (agent_provider) |prov| {
                // Neutral/white prompt mark so it contrasts with the provider logo
                // instead of blending into it (the accent shares the logo's hue).
                const mark_color = if (dim) theme.COLOR_TEXT_SUBTLE else theme.COLOR_WHITE;
                queuePaletteAgentTerminalGlyph(state, prov, icon_x, cy, mark_color, clip);
            } else {
                queuePaletteTerminalMark(state, icon_x, cy, theme.scaledUi(14.0), muted, clip);
            }
            // Prefer an agent/notify-provided surface title, then the terminal's
            // live OSC title (or cwd via tabTitle), then a generic fallback.
            title = blk: {
                if (surface) |s| if (s.title.len > 0) break :blk s.title;
                if (state.projectTerminalDock(project_index, ref.dock_id)) |dock| {
                    const live = dock.activeProcessLabel(&term_title_buf);
                    if (live.len > 0) break :blk live;
                }
                break :blk "Terminal";
            };
            // Agents (e.g. Claude Code) prefix their title with a symbol marker
            // like "✳" the sidebar font can't render; drop it so it doesn't show
            // as a tofu box before the title.
            title = stripLeadingTitleSymbols(title);
        },
        .browser => {
            queuePaletteGlobeIcon(state, icon_x + theme.scaledUi(7.0), cy, theme.scaledUi(13.0), paletteColor(muted));
            title = browserPaneTitle(pane);
        },
    }

    const title_left_css = SIDEBAR_THREAD_ICON_LEADING_PAD_CSS + SIDEBAR_THREAD_PROVIDER_GLYPH_CSS + SIDEBAR_THREAD_ICON_TITLE_GAP_CSS;
    var title_buf = std.mem.zeroes([64:0]u8);
    const title_chars: usize = @intFromFloat(@max((rect.w - theme.scaledUi(title_left_css + SIDEBAR_THREAD_TIME_COLUMN_CSS)) / theme.scaledUi(7.0), 8.0));
    const shown = truncatedThreadTitle(&title_buf, title, title_chars);

    const emphasis = focused or hovered;
    const title_color = if (dim)
        theme.COLOR_TEXT_SUBTLE
    else if (running)
        theme.COLOR_SECONDARY_GREEN
    else if (emphasis)
        theme.COLOR_WHITE
    else
        theme.COLOR_TEXT_MUTED;

    const title_font = theme.scaledUi(13.5);
    const title_line = title_font * 1.30;
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(title_left_css),
        .y = @round(rect.y + (rect.h - title_line) * 0.5),
        .w = rect.w - theme.scaledUi(title_left_css + 12.0),
        .h = title_line,
    }, shown, paletteColor(title_color), title_font, clip);

    // No status pip on the pane you're focused in — you're already there.
    if (!focused) {
        if (paneStatusColor(status, running)) |pip_color| {
            const animated = running or (if (status) |s| s == .waiting else false);
            const pulse: f32 = if (animated) attentionPulse(state) else 1.0;
            const dot = theme.scaledUi(7.0);
            queuePaletteRoundedRect(state, .{
                .x = rect.x + rect.w - theme.scaledUi(10.0),
                .y = cy - dot * 0.5,
                .w = dot,
                .h = dot,
            }, paletteColor(theme.withAlpha(pip_color, @intFromFloat(pulse * 255.0))), dot * 0.5);
        }
    }
}

/// Quiet per-workspace "History · N" trailing row. The saved-thread list
/// itself lives in the command palette (this row opens it scoped to the
/// workspace); the rail only tracks live panes.
fn renderHistoryRow(
    state: *runtime.AppState,
    project_index: usize,
    project: *native_state.Project,
    x: f32,
    rail_w: f32,
    list_clip: palette.Rect,
    clip: palette.Rect,
    y_in: f32,
) f32 {
    var y = y_in;
    const row_rect: palette.Rect = .{
        .x = x + theme.scaledUi(24.0),
        .y = y,
        .w = rail_w - theme.scaledUi(42.0),
        .h = theme.scaledUi(28.0),
    };
    if (rowVisible(row_rect, list_clip)) {
        const hovered = state.palette_mouse_in_workspace and rectContainsPoint(row_rect, state.palette_mouse_x, state.palette_mouse_y);
        if (hovered) {
            queuePaletteRoundedRect(state, snapRect(row_rect), paletteColor(theme.withAlpha(theme.COLOR_SECONDARY_GREEN, 180)), theme.scaledUi(7.0));
        }
        addPaletteHit(row_rect, .history, project_index, 0);
        var label_buf: [40]u8 = undefined;
        const count = project.committedThreadCountCached(state.allocator);
        const label = std.fmt.bufPrint(&label_buf, "History · {d}", .{count}) catch "History";
        const font_size = theme.scaledUi(12.5);
        queuePaletteText(state, .{
            .x = row_rect.x + theme.scaledUi(10.0),
            .y = row_rect.y + (row_rect.h - font_size * 1.3) * 0.5,
            .w = row_rect.w - theme.scaledUi(20.0),
            .h = font_size * 1.3,
        }, label, paletteColor(if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE), font_size, clip);
    }
    y += theme.scaledUi(30.0);
    return y;
}

/// Collapsed workspaces hide quiet panes but punch attention panes through
/// as compact rows, so the rail reads as a live status board: its height
/// tracks activity, never history or pane count. Idle collapsed workspaces
/// stay one header line tall.
fn renderAttentionPanesSection(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    x: f32,
    rail_w: f32,
    list_clip: palette.Rect,
    clip: palette.Rect,
    y_in: f32,
) f32 {
    var y = y_in;
    const layout = &project.workspace_layout;
    for (layout.panes.items) |*pane| {
        if (!paneNeedsAttention(state, project_index, project, pane)) continue;
        const row_rect: palette.Rect = .{
            .x = x + theme.scaledUi(24.0),
            .y = y,
            .w = rail_w - theme.scaledUi(42.0),
            .h = theme.scaledUi(SIDEBAR_THREAD_ROW_HEIGHT_CSS),
        };
        if (rowVisible(row_rect, list_clip)) renderOpenPaneRow(state, project_index, project, pane, row_rect, clip);
        y += theme.scaledUi(SIDEBAR_THREAD_ROW_STEP_CSS);
    }
    return y;
}

/// True when a pane should punch through a collapsed workspace row: chat
/// sends in flight, or terminal surfaces working/waiting/errored (or flagged
/// for attention/unread by hooks). `done`/idle panes stay hidden so finished
/// work stops occupying the rail once it has nothing new to report.
fn paneNeedsAttention(
    state: *runtime.AppState,
    project_index: usize,
    project: *const native_state.Project,
    pane: *const native_state.WorkspacePane,
) bool {
    switch (pane.ref) {
        .chat => |ref| {
            if (ref.thread_index >= project.threads.items.len) return false;
            return project.threads.items[ref.thread_index].isSendPendingForUi();
        },
        .terminal => |ref| {
            const surface = state.projectTerminalSurface(project_index, ref.dock_id) orelse return false;
            if (state.isFocusedTerminalSurface(project_index, ref.dock_id)) return false;
            if (surface.attention or surface.unread_count > 0) return true;
            return switch (surface.status) {
                .working, .waiting, .@"error" => true,
                .done, .idle => false,
            };
        },
        .browser => return false,
    }
}

/// Maps a terminal surface status (and chat running state) to a sidebar status
/// pip color, or null when the pane needs no attention indicator.
fn paneStatusColor(status: ?native_state.SurfaceStatus, running: bool) ?[4]f32 {
    if (status) |s| {
        return switch (s) {
            .working => theme.COLOR_SECONDARY_GREEN,
            .waiting => theme.COLOR_YELLOW,
            .@"error" => theme.COLOR_DIFF_REMOVE,
            .done => theme.COLOR_TEXT_SUBTLE,
            .idle => if (running) theme.COLOR_SECONDARY_GREEN else null,
        };
    }
    if (running) return theme.COLOR_SECONDARY_GREEN;
    return null;
}

/// Best-effort human label for the workspace browser pane.
fn browserPaneTitle(pane: *const native_state.WorkspacePane) []const u8 {
    const ref = switch (pane.ref) {
        .browser => |browser| browser,
        else => return "Browser",
    };
    if (ref.title) |title| {
        if (title.len > 0) return title;
    }
    const url = ref.url orelse return "Browser";
    if (url.len == 0) return "Browser";
    return url;
}

/// Draws a minimal globe glyph (circle + equator + meridian) for browser panes.
fn queuePaletteGlobeIcon(state: *runtime.AppState, cx: f32, cy: f32, size: f32, color: palette.Color) void {
    const r = size * 0.5;
    const stroke = @max(theme.scaledUi(1.0), size * 0.09);
    queuePaletteBorder(state, .{ .x = cx - r, .y = cy - r, .w = size, .h = size }, color, r, stroke);
    queuePaletteRect(state, .{ .x = cx - r, .y = cy - stroke * 0.5, .w = size, .h = stroke }, color);
    queuePaletteRect(state, .{ .x = cx - stroke * 0.5, .y = cy - r, .w = stroke, .h = size }, color);
}

fn rowVisible(row: palette.Rect, viewport: palette.Rect) bool {
    return row.y + row.h >= viewport.y and row.y <= viewport.y + viewport.h;
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

fn rectContainsPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn queuePaletteRoundedRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, snapRect(rect), color, radius) catch |err| {
        log.warn("failed to queue sidebar palette rounded rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, snapRect(rect), color, radius, width) catch |err| {
        log.warn("failed to queue sidebar palette border: {s}", .{@errorName(err)});
    };
}

fn queuePaletteFolderIcon(state: *runtime.AppState, x: f32, center_y: f32, width: f32, height: f32, color: [4]f32, filled: bool) void {
    const tab_rect: palette.Rect = .{
        .x = x,
        .y = center_y - height * 0.5 - theme.scaledUi(2.0),
        .w = width * 0.4,
        .h = theme.scaledUi(3.0),
    };
    const body_rect: palette.Rect = .{
        .x = x,
        .y = center_y - height * 0.5,
        .w = width,
        .h = height,
    };
    const palette_color = paletteColor(color);
    queuePaletteRoundedRect(state, tab_rect, palette_color, theme.scaledUi(1.0));
    if (filled) {
        queuePaletteRoundedRect(state, body_rect, palette_color, theme.scaledUi(1.5));
    } else {
        queuePaletteBorder(state, body_rect, palette_color, theme.scaledUi(1.5), theme.scaledUi(1.4));
    }
}

// Nerd Font Symbols codicon glyphs used throughout the sidebar. Codepoints
// confirmed against SymbolsNerdFontMono-Regular.ttf's cmap.
const NF_COD_CHEVRON_RIGHT = "\u{EAB6}";
const NF_COD_CHEVRON_DOWN = "\u{EAB4}";
const NF_COD_EDIT = "\u{EA73}";
const NF_COD_GEAR = "\u{EB51}";
const NF_COD_TERMINAL = "\u{EA85}";

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

fn queuePaletteEditGlyph(state: *runtime.AppState, start: [2]f32, width: f32, height: f32, color: [4]f32) void {
    const font_size = @min(width, height) * 0.5;
    queuePaletteIcon(state, .{
        .x = start[0] + (width - font_size) * 0.5,
        .y = start[1] + (height - font_size) * 0.5,
        .w = font_size,
        .h = font_size,
    }, NF_COD_EDIT, font_size, paletteColor(color), null);
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
        if (queuePaletteImage(state, image_rect, cached, paletteColor(theme.COLOR_WHITE), null)) return;
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

fn snapRect(rect: palette.Rect) palette.Rect {
    return .{
        .x = @round(rect.x),
        .y = @round(rect.y),
        .w = @round(rect.w),
        .h = @round(rect.h),
    };
}

/// Strips a leading run of non-ASCII bytes (a symbol/emoji marker such as the
/// "✳" agents prepend to their terminal title) when it is separated from the
/// real title by a space. Falls back to the original string otherwise, so plain
/// or fully non-ASCII titles are left untouched.
fn stripLeadingTitleSymbols(title: []const u8) []const u8 {
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
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
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

pub fn queuePaletteProviderGlyph(state: *runtime.AppState, provider: Provider, x: f32, center_y: f32, clip: palette.Rect) void {
    const image_size = theme.scaledUi(SIDEBAR_THREAD_PROVIDER_GLYPH_CSS);
    queuePaletteProviderGlyphInRect(state, provider, .{
        .x = x,
        .y = center_y - image_size * 0.5,
        .w = image_size,
        .h = image_size,
    }, clip);
}

/// Draws a provider logo (or letter fallback) fitted within `box`.
fn queuePaletteProviderGlyphInRect(state: *runtime.AppState, provider: Provider, box: palette.Rect, clip: ?palette.Rect) void {
    const texture = switch (provider) {
        .codex => state.codex_logo_texture,
        .opencode => state.opencode_logo_texture,
        .claude => state.claude_logo_texture,
        .cursor => state.cursor_logo_texture,
    };
    if (texture) |cached| {
        const r = utils.snapImageRectToPixels(utils.imageRectContain(cached.width, cached.height, box.x, box.y, box.w, box.h));
        const draw = snapRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
        if (queuePaletteImage(state, draw, cached, paletteColor(theme.COLOR_WHITE), clip)) return;
    }

    const label = switch (provider) {
        .codex => "C",
        .opencode => "O",
        .claude => "Cl",
        .cursor => "Cu",
    };
    const font_size = @min(theme.scaledUi(11.0), box.h);
    queuePaletteText(state, .{
        .x = box.x,
        .y = box.y + (box.h - font_size * 1.25) * 0.5,
        .w = box.w,
        .h = font_size * 1.25,
    }, label, paletteColor(theme.COLOR_TEXT_SUBTLE), font_size, clip);
}

/// Maps a foreground process `comm` name to a known agent provider, so a
/// terminal pane running e.g. `claude` shows that provider's split icon.
fn providerFromComm(comm: []const u8) ?Provider {
    if (std.mem.eql(u8, comm, "claude")) return .claude;
    if (std.mem.eql(u8, comm, "codex")) return .codex;
    if (std.mem.eql(u8, comm, "opencode")) return .opencode;
    if (std.mem.startsWith(u8, comm, "cursor")) return .cursor;
    return null;
}

/// Composite glyph for an agent running in a terminal pane: the provider logo
/// sits in the upper-left, a font-safe `>_` prompt mark in the lower-right, and
/// a diagonal slash divides them.
fn queuePaletteAgentTerminalGlyph(state: *runtime.AppState, provider: Provider, x: f32, center_y: f32, term_color: [4]f32, clip: palette.Rect) void {
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
