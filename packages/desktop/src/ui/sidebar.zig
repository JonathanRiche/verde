//! Project rail rendering for the native shell.

const std = @import("std");
const palette = @import("palette");
const theme = @import("theme.zig");
const colors = @import("colors.zig");
const runtime = @import("runtime.zig");
const utils = @import("../utils.zig");
const native_state = @import("../state.zig");
const workspace_panes = @import("workspace_panes.zig");
const Provider = native_state.Provider;

const log = std.log.scoped(.native_ui_sidebar);

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
const THREAD_DRAG_THRESHOLD_CSS: f32 = 5.0;
const THREAD_DRAG_FLOATING_Z: i32 = 160;

const SidebarHitKind = enum {
    collapse,
    expand,
    add_project,
    new_thread,
    project_row,
    thread_row,
    toggle_threads,
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
    project_new_chat,
    project_rename,
    project_import_codex,
    project_import_opencode,
    project_import_claude,
    project_archive,
    thread_sync,
    thread_archive,
};

var sidebar_menu_panel_rect: palette.Rect = .{};
var sidebar_menu_row_rects: [8]palette.Rect = undefined;
var sidebar_menu_row_actions: [8]SidebarContextMenuAction = undefined;
var sidebar_menu_row_enabled: [8]bool = undefined;
var sidebar_menu_row_labels: [8][]const u8 = undefined;
var sidebar_menu_row_count: usize = 0;

const ThreadDragState = struct {
    pending: bool = false,
    active: bool = false,
    project_index: usize = 0,
    thread_index: usize = 0,
    start_x: f32 = 0.0,
    start_y: f32 = 0.0,
    x: f32 = 0.0,
    y: f32 = 0.0,
};

var thread_drag: ThreadDragState = .{};

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
    }, paletteColor(colors.DARK_BLUE));

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

    updateThreadDrag(state, x, y);

    var new_thread_hover: ?native_state.SidebarThreadHover = null;
    var new_project_hover: ?usize = null;
    var new_new_thread_hover: ?usize = null;
    if (!state.isSidebarCollapsed() and rectContainsPoint(palette_sidebar_rect, x, y)) {
        // Walk hits in reverse so later (visually-topmost) rows win when
        // overlapping during scroll edge cases.
        var index = palette_hit_count;
        while (index > 0) {
            index -= 1;
            const hit = palette_hits[index];
            if (!rectContainsPoint(hit.rect, x, y)) continue;
            switch (hit.kind) {
                .thread_row => {
                    if (new_thread_hover == null) {
                        new_thread_hover = .{ .project_index = hit.project_index, .thread_index = hit.thread_index };
                    }
                },
                .project_row => {
                    if (new_project_hover == null) new_project_hover = hit.project_index;
                },
                .new_thread => {
                    if (new_new_thread_hover == null) new_new_thread_hover = hit.project_index;
                },
                else => {},
            }
        }
    }

    const thread_changed = !threadHoverEq(state.sidebar_thread_hover, new_thread_hover);
    const project_changed = state.sidebar_project_hover != new_project_hover;
    const new_thread_changed = state.sidebar_new_thread_hover != new_new_thread_hover;
    if (!thread_changed and !project_changed and !new_thread_changed) return;

    state.sidebar_thread_hover = new_thread_hover;
    state.sidebar_project_hover = new_project_hover;
    state.sidebar_new_thread_hover = new_new_thread_hover;
    state.markDirty();
}

fn threadHoverEq(a: ?native_state.SidebarThreadHover, b: ?native_state.SidebarThreadHover) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.project_index == b.?.project_index and a.?.thread_index == b.?.thread_index;
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) {
        if (thread_drag.pending or thread_drag.active) return finishThreadDrag(state, x, y);
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
            .add_project => {
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
            .project_row => {
                if (hit.project_index < state.projects.items.len) {
                    state.noteInteraction();
                    state.selected_project_index = hit.project_index;
                    state.projects.items[hit.project_index].collapsed = !state.projects.items[hit.project_index].collapsed;
                    state.syncRenameBuffer();
                    state.requestTranscriptScrollToBottom();
                    state.markDirty();
                }
            },
            .thread_row => {
                if (hit.project_index < state.projects.items.len and hit.thread_index < state.projects.items[hit.project_index].threads.items.len) {
                    thread_drag = .{
                        .pending = true,
                        .project_index = hit.project_index,
                        .thread_index = hit.thread_index,
                        .start_x = x,
                        .start_y = y,
                        .x = x,
                        .y = y,
                    };
                }
            },
            .toggle_threads => {
                if (hit.project_index < state.projects.items.len) {
                    state.projects.items[hit.project_index].thread_list_expanded = !state.projects.items[hit.project_index].thread_list_expanded;
                    state.markDirty();
                }
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
            .project_row => {
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
            .thread_row => {
                state.workspace_header_open_menu_open = false;
                state.sidebar_context_menu_anchor_x = x;
                state.sidebar_context_menu_anchor_y = y;
                state.sidebar_context_menu_project_index = hit.project_index;
                state.sidebar_context_menu_thread_index = hit.thread_index;
                state.sidebar_context_menu_kind = .thread;
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

pub fn renderWorkspaceDragPreview(state: *runtime.AppState) void {
    if (!thread_drag.active) return;
    workspace_panes.renderThreadDropPreview(state, thread_drag.x, thread_drag.y);
}

pub fn renderFloatingDragPreview(state: *runtime.AppState) void {
    renderThreadDragPreview(state);
}

pub fn hasActiveThreadDrag() bool {
    return thread_drag.pending or thread_drag.active;
}

fn updateThreadDrag(state: *runtime.AppState, x: f32, y: f32) void {
    if (!thread_drag.pending and !thread_drag.active) return;
    thread_drag.x = x;
    thread_drag.y = y;
    if (thread_drag.pending) {
        const dx = x - thread_drag.start_x;
        const dy = y - thread_drag.start_y;
        const threshold = theme.scaledUi(THREAD_DRAG_THRESHOLD_CSS);
        if (dx * dx + dy * dy >= threshold * threshold) {
            thread_drag.pending = false;
            thread_drag.active = true;
        }
    }
    state.markDirty();
}

fn finishThreadDrag(state: *runtime.AppState, x: f32, y: f32) bool {
    const drag = thread_drag;
    thread_drag = .{};
    if (!drag.active) {
        if (drag.project_index < state.projects.items.len and drag.thread_index < state.projects.items[drag.project_index].threads.items.len) {
            state.noteInteraction();
            state.selected_project_index = drag.project_index;
            state.projects.items[drag.project_index].selected_thread_index = drag.thread_index;
            state.requestComposerFocus();
            state.syncRenameBuffer();
            state.markDirty();
        }
        return true;
    }

    if (drag.project_index != state.selected_project_index) {
        state.setSidebarNotice("Switch to that project before dragging its thread into panes.");
        return true;
    }
    if (workspace_panes.dropThreadAt(state, drag.thread_index, x, y)) {
        state.setSidebarNotice("");
    } else {
        state.setSidebarNotice("Drop on a pane edge to open that thread.");
    }
    return true;
}

fn renderThreadDragPreview(state: *runtime.AppState) void {
    if (!thread_drag.active) return;
    if (thread_drag.project_index >= state.projects.items.len) return;
    const project = &state.projects.items[thread_drag.project_index];
    if (thread_drag.thread_index >= project.threads.items.len) return;
    const previous_z = state.palette_overlay_batch.setZIndex(THREAD_DRAG_FLOATING_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);
    const thread = &project.threads.items[thread_drag.thread_index];
    const w = theme.scaledUi(220.0);
    const h = theme.scaledUi(38.0);
    const rect: palette.Rect = .{
        .x = thread_drag.x + theme.scaledUi(12.0),
        .y = thread_drag.y + theme.scaledUi(10.0),
        .w = w,
        .h = h,
    };
    queuePaletteRoundedRect(state, rect, paletteColor(colors.rgba(27, 35, 34, 232)), theme.scaledUi(8.0));
    queuePaletteBorder(state, rect, paletteColor(colors.rgba(93, 223, 143, 180)), theme.scaledUi(8.0), theme.scaledUi(1.0));
    queuePaletteProviderGlyph(state, thread.provider, rect.x + theme.scaledUi(10.0), rect.y + rect.h * 0.5, rect);
    var title_buf = std.mem.zeroes([64:0]u8);
    const row_label = truncatedThreadTitle(&title_buf, thread.title, 24);
    const font = theme.scaledUi(13.5);
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(42.0),
        .y = rect.y + (rect.h - font * 1.25) * 0.5,
        .w = rect.w - theme.scaledUi(52.0),
        .h = font * 1.25,
    }, row_label, paletteColor(theme.COLOR_WHITE), font, rect);
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
                .project_new_chat => {
                    if (pi < state.projects.items.len) state.createThreadForProject(pi);
                },
                .project_rename => state.beginProjectRename(pi),
                .project_import_codex => state.beginThreadImport(pi, .codex),
                .project_import_opencode => state.beginThreadImport(pi, .opencode),
                .project_import_claude => state.beginThreadImport(pi, .claude),
                .project_archive => state.archiveProjectAtIndex(pi),
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
            appendSidebarContextMenuRow(.project_new_chat, true, "Start a new chat");
            appendSidebarContextMenuRow(.project_rename, true, "Rename project");
            appendSidebarContextMenuRow(.project_import_codex, true, "Import Codex thread");
            appendSidebarContextMenuRow(.project_import_opencode, true, "Import OpenCode thread");
            appendSidebarContextMenuRow(.project_import_claude, true, "Import Claude thread");
            var busy = false;
            if (pi < state.projects.items.len) {
                for (state.projects.items[pi].threads.items) |*th| {
                    if (th.isSendPendingForUi()) {
                        busy = true;
                        break;
                    }
                }
            }
            appendSidebarContextMenuRow(.project_archive, !busy, "Archive project");
        },
        .thread => {
            const pi = state.sidebar_context_menu_project_index;
            const ti = state.sidebar_context_menu_thread_index;
            var can_sync = false;
            var can_archive = true;
            if (pi < state.projects.items.len) {
                const proj = state.projects.items[pi];
                if (ti < proj.threads.items.len) {
                    const th = proj.threads.items[ti];
                    can_sync = th.provider_thread_id != null and !th.isSendPendingForUi();
                    can_archive = !th.isSendPendingForUi();
                }
            }
            appendSidebarContextMenuRow(.thread_sync, can_sync, "Sync thread");
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

    queuePaletteRoundedRect(state, sidebar_menu_panel_rect, paletteColor(colors.rgba(26, 28, 34, 255)), theme.scaledUi(12.0));
    queuePaletteBorder(state, sidebar_menu_panel_rect, paletteColor(colors.rgba(66, 68, 78, 255)), theme.scaledUi(12.0), theme.scaledUi(1.0));

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
            queuePaletteRoundedRect(state, rr, paletteColor(colors.rgba(42, 44, 52, 255)), theme.scaledUi(8.0));
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

    // The logo, sidebar-collapse toggle, "PROJECTS" label, and add-project
    // button stay pinned at the top of the rail; only the project list
    // scrolls beneath them. The header is rendered AFTER the list (with a
    // background strip first) so any list rows scrolled into the header band
    // are visually overwritten — no z-index plumbing required.
    const header_top = rect.y + theme.scaledUi(31.0);
    const projects_label_y = header_top + theme.scaledUi(92.0);
    const list_top = projects_label_y + theme.scaledUi(38.0);
    const list_clip: palette.Rect = .{ .x = rect.x, .y = list_top, .w = rect.w, .h = @max(rect.y + rect.h - list_top, 0.0) };
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
                // project reads as a recessed card.
                state.palette_overlay_batch.panel(
                    state.allocator,
                    snapRect(row_rect),
                    paletteColor(colors.CHAT_BLACK),
                    paletteColor(theme.COLOR_PANEL_MUTED),
                    theme.scaledUi(6.0),
                    theme.scaledUi(1.0),
                ) catch {};
            } else if (project_hovered) {
                queuePaletteRoundedRect(state, row_rect, paletteColor(colors.rgba(36, 49, 45, 180)), theme.scaledUi(6.0));
            }
        }
        if (project_visible) addPaletteHit(row_rect, .project_row, project_index, 0);

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
                queuePaletteRoundedRect(state, new_rect, paletteColor(colors.rgba(36, 49, 45, 200)), theme.scaledUi(6.0));
            }
            queuePaletteEditGlyph(state, .{ new_rect.x, new_rect.y }, new_rect.w, new_rect.h, if (new_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED);
            addPaletteHit(new_rect, .new_thread, project_index, 0);
        }
        y += row_h + theme.scaledUi(4.0);

        if (!collapsed) {
            var saved_buf: [32]u8 = undefined;
            const saved = std.fmt.bufPrint(&saved_buf, "{d} saved chats", .{project.committedThreadCountCached(state.allocator)}) catch "saved chats";
            const saved_rect: palette.Rect = .{ .x = x + theme.scaledUi(24.0), .y = y, .w = rail_w - theme.scaledUi(24.0), .h = theme.scaledUi(22.0) };
            if (rowVisible(saved_rect, list_clip)) queuePaletteText(state, saved_rect, saved, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(14.0), clip);
            y += theme.scaledUi(24.0);

            const sorted_indices = project.sortedCommittedThreadIndices(state.allocator);
            const show_all = project.thread_list_expanded or sorted_indices.len <= runtime.SIDEBAR_VISIBLE_THREAD_LIMIT;
            const visible_count = if (show_all) sorted_indices.len else @min(sorted_indices.len, runtime.SIDEBAR_VISIBLE_THREAD_LIMIT);
            for (sorted_indices[0..visible_count]) |thread_index| {
                if (thread_index >= project.threads.items.len) break;
                const thread = &project.threads.items[thread_index];
                const thread_rect: palette.Rect = .{
                    .x = x + theme.scaledUi(24.0),
                    .y = y,
                    .w = rail_w - theme.scaledUi(42.0),
                    .h = theme.scaledUi(SIDEBAR_THREAD_ROW_HEIGHT_CSS),
                };
                if (rowVisible(thread_rect, list_clip)) renderPaletteThreadRow(state, project_index, thread_index, thread, thread_rect, clip);
                y += theme.scaledUi(SIDEBAR_THREAD_ROW_STEP_CSS);
            }
            if (sorted_indices.len > runtime.SIDEBAR_VISIBLE_THREAD_LIMIT) {
                const show_rect: palette.Rect = .{ .x = x + theme.scaledUi(12.0), .y = y + theme.scaledUi(2.0), .w = rail_w - theme.scaledUi(24.0), .h = theme.scaledUi(32.0) };
                if (rowVisible(show_rect, list_clip)) {
                    queuePaletteRoundedRect(state, show_rect, paletteColor(theme.COLOR_SECONDARY_GREEN), theme.scaledUi(8.0));
                    const label = if (project.thread_list_expanded) "Show less" else "Show more";
                    const show_pad_x = theme.scaledUi(14.0);
                    const font_size = theme.scaledUi(14.0);
                    queuePaletteText(state, .{
                        .x = show_rect.x + show_pad_x,
                        .y = show_rect.y + (show_rect.h - font_size * 1.25) * 0.5,
                        .w = show_rect.w - show_pad_x * 2.0,
                        .h = font_size * 1.25,
                    }, label, paletteColor(theme.COLOR_WHITE), font_size, show_rect);
                    addPaletteHit(show_rect, .toggle_threads, project_index, 0);
                }
                y += theme.scaledUi(40.0);
            }
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
        queuePaletteRoundedRect(state, track, paletteColor(colors.rgba(35, 42, 46, 120)), theme.scaledUi(2.0));
        queuePaletteRoundedRect(state, .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, paletteColor(colors.rgba(145, 163, 170, 200)), theme.scaledUi(2.0));
    }

    // Pinned header — painted last so any scrolled rows in the header band
    // are covered by the panel-colored strip before the chrome paints on top.
    queuePaletteRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w - theme.scaledUi(1.0), .h = list_top - rect.y }, paletteColor(theme.COLOR_PANEL));
    queuePaletteLogoMark(state, .{ .x = x, .y = header_top, .w = theme.scaledUi(42.0), .h = theme.scaledUi(42.0) });
    queuePaletteText(state, .{ .x = x + theme.scaledUi(54.0), .y = header_top + theme.scaledUi(4.0), .w = theme.scaledUi(130.0), .h = theme.scaledUi(38.0) }, "verde", paletteColor(theme.COLOR_WHITE), theme.heading_font_size, rect);

    const toggle_rect: palette.Rect = .{ .x = rect.x + rect.w - pad_x - theme.scaledUi(28.0), .y = header_top + theme.scaledUi(6.0), .w = theme.scaledUi(28.0), .h = theme.scaledUi(28.0) };
    queuePaletteButton(state, toggle_rect, "<", false);
    addPaletteHit(toggle_rect, .collapse, 0, 0);

    queuePaletteText(state, .{ .x = x, .y = projects_label_y, .w = theme.scaledUi(130.0), .h = theme.scaledUi(24.0) }, "PROJECTS", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(16.0), rect);
    const add_rect: palette.Rect = .{ .x = rect.x + rect.w - pad_x - theme.scaledUi(28.0), .y = projects_label_y - theme.scaledUi(2.0), .w = theme.scaledUi(28.0), .h = theme.scaledUi(28.0) };
    queuePaletteButton(state, add_rect, "+", true);
    addPaletteHit(add_rect, .add_project, 0, 0);
}

fn renderPaletteCollapsedSidebar(state: *runtime.AppState, rect: palette.Rect) void {
    const button = theme.scaledUi(36.0);
    const x = rect.x + (rect.w - button) * 0.5;
    var y = rect.y + theme.scaledUi(30.0);
    queuePaletteLogoMark(state, .{ .x = x + theme.scaledUi(2.0), .y = y, .w = theme.scaledUi(32.0), .h = theme.scaledUi(32.0) });
    y += theme.scaledUi(62.0);
    const expand_rect: palette.Rect = .{ .x = x, .y = y, .w = button, .h = theme.scaledUi(30.0) };
    queuePaletteButton(state, expand_rect, ">", false);
    addPaletteHit(expand_rect, .expand, 0, 0);
    y += theme.scaledUi(40.0);
    const new_rect: palette.Rect = .{ .x = x, .y = y, .w = button, .h = theme.scaledUi(30.0) };
    queuePaletteEditGlyph(state, .{ new_rect.x, new_rect.y }, new_rect.w, new_rect.h, theme.COLOR_TEXT_MUTED);
    addPaletteHit(new_rect, .new_thread, state.selected_project_index, 0);
    y += theme.scaledUi(40.0);
    const add_rect: palette.Rect = .{ .x = x, .y = y, .w = button, .h = theme.scaledUi(30.0) };
    queuePaletteButton(state, add_rect, "+", true);
    addPaletteHit(add_rect, .add_project, 0, 0);
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

fn renderPaletteThreadRow(state: *runtime.AppState, project_index: usize, thread_index: usize, thread: anytype, rect: palette.Rect, clip: palette.Rect) void {
    const project = &state.projects.items[project_index];
    const selected = state.selected_project_index == project_index and project.selected_thread_index == thread_index;
    const hovered = if (state.sidebar_thread_hover) |h| h.project_index == project_index and h.thread_index == thread_index else false;
    if (selected) {
        const bg = if (hovered)
            paletteColor(theme.lighten(colors.DARK_BLUE, 0.09))
        else
            paletteColor(colors.DARK_BLUE);
        queuePaletteRoundedRect(state, snapRect(rect), bg, theme.scaledUi(7.0));
    } else if (hovered) {
        queuePaletteRoundedRect(state, snapRect(rect), paletteColor(colors.rgba(36, 49, 45, 210)), theme.scaledUi(7.0));
    }
    addPaletteHit(rect, .thread_row, project_index, thread_index);

    const title_left_css = SIDEBAR_THREAD_ICON_LEADING_PAD_CSS + SIDEBAR_THREAD_PROVIDER_GLYPH_CSS + SIDEBAR_THREAD_ICON_TITLE_GAP_CSS;
    const title_area_right_css = title_left_css + SIDEBAR_THREAD_TIME_COLUMN_CSS + SIDEBAR_THREAD_TITLE_TIME_GAP_CSS;
    queuePaletteProviderGlyph(state, thread.provider, rect.x + theme.scaledUi(SIDEBAR_THREAD_ICON_LEADING_PAD_CSS), rect.y + rect.h * 0.5, clip);
    var time_buf: [24]u8 = undefined;
    const relative_time = formatRelativeTime(&time_buf, thread.last_activity_at);
    var title_buf = std.mem.zeroes([64:0]u8);
    const title_chars: usize = @intFromFloat(@max((rect.w - theme.scaledUi(title_left_css + SIDEBAR_THREAD_TIME_COLUMN_CSS)) / theme.scaledUi(7.0), 8.0));
    const row_label = truncatedThreadTitle(&title_buf, thread.title, title_chars);

    const title_emphasis = selected or hovered;
    const title_font = theme.scaledUi(13.5);
    const title_line = title_font * 1.30;
    const title_y = @round(rect.y + (rect.h - title_line) * 0.5);
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(title_left_css),
        .y = title_y,
        .w = rect.w - theme.scaledUi(title_area_right_css),
        .h = title_line,
    }, row_label, paletteColor(if (title_emphasis) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), title_font, clip);
    queuePaletteText(state, .{
        .x = rect.x + rect.w - theme.scaledUi(60.0),
        .y = title_y,
        .w = theme.scaledUi(58.0),
        .h = title_line,
    }, relative_time, paletteColor(colors.TIME_LABEL), title_font, clip);
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
fn formatRelativeTime(buffer: []u8, timestamp: i64) []const u8 {
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

fn queuePaletteProviderGlyph(state: *runtime.AppState, provider: Provider, x: f32, center_y: f32, clip: palette.Rect) void {
    const image_size = theme.scaledUi(SIDEBAR_THREAD_PROVIDER_GLYPH_CSS);
    const image_rect: palette.Rect = .{
        .x = x,
        .y = center_y - image_size * 0.5,
        .w = image_size,
        .h = image_size,
    };
    const texture = switch (provider) {
        .codex => state.codex_logo_texture,
        .opencode => state.opencode_logo_texture,
        .claude => state.claude_logo_texture,
        .cursor => state.cursor_logo_texture,
    };
    if (texture) |cached| {
        const r = utils.snapImageRectToPixels(utils.imageRectContain(cached.width, cached.height, image_rect.x, image_rect.y, image_rect.w, image_rect.h));
        const draw = snapRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
        if (queuePaletteImage(state, draw, cached, paletteColor(theme.COLOR_WHITE), clip)) return;
    }

    const label = switch (provider) {
        .codex => "C",
        .opencode => "O",
        .claude => "Cl",
        .cursor => "Cu",
    };
    const font_size = theme.scaledUi(11.0);
    queuePaletteText(state, .{
        .x = x,
        .y = center_y - font_size * 0.55,
        .w = theme.scaledUi(14.0),
        .h = font_size * 1.25,
    }, label, paletteColor(theme.COLOR_TEXT_SUBTLE), font_size, null);
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
