//! Palette-only terminal dock shell.

const std = @import("std");
const ghostty_vt = @import("../vendor/ghostty_vt.zig");
const palette = @import("palette");
const sdl = @import("zsdl3");

const app_state = @import("../state.zig");
const colors = @import("colors.zig");
const theme = @import("theme.zig");
const terminal = @import("../terminal/terminal.zig");
const runtime_log = @import("../runtime_log.zig");

const log = std.log.scoped(.terminal_panel);

const MAX_PANE_HITS = 64;
const MAX_TAB_HITS = 32;
const TERMINAL_CONTEXT_MENU_WIDTH: f32 = 180.0;
const TERMINAL_CONTEXT_MENU_ROW_HEIGHT: f32 = 30.0;
const TERMINAL_CONTEXT_MENU_PAD: f32 = 6.0;
const TERMINAL_SCROLLBAR_MIN_THUMB_CSS: f32 = 28.0;
const TERMINAL_SCROLLBAR_TRACK_WIDTH_CSS: f32 = 3.0;
const TERMINAL_SCROLLBAR_EDGE_PAD_CSS: f32 = 2.0;
const TERMINAL_SCROLLBAR_VERTICAL_PAD_CSS: f32 = 4.0;
const MAX_TERMINAL_LINK_BYTES: usize = 2048;
const MAX_TERMINAL_IMAGE_TEXTURES: usize = 128;

const TerminalContextMenuKind = enum {
    pane,
    tab,
};

const TerminalContextMenuAction = enum {
    copy_selection,
    new_tab,
    new_claude_tab,
    new_opencode_tab,
    new_codex_tab,
    new_cursor_tab,
    new_custom_tab,
    rename_tab,
    close_tab,
    split_up,
    split_down,
    split_left,
    split_right,
    zoom_pane,
    close_pane,
};

const TerminalGlyphKind = enum {
    text,
    icon,
    powerline,
};

const CachedDrawCommand = union(enum) {
    rect: struct {
        rect: palette.Rect,
        color: palette.Color,
        clip: ?palette.Rect = null,
    },
    border: struct {
        rect: palette.Rect,
        color: palette.Color,
        radius: f32,
        width: f32,
    },
    triangle: struct {
        p0: palette.draw.Vec2,
        p1: palette.draw.Vec2,
        p2: palette.draw.Vec2,
        color: palette.Color,
        clip: ?palette.Rect = null,
    },
    terminal_text: struct {
        rect: palette.Rect,
        value: []const u8,
        color: palette.Color,
        font_size: f32,
        clip: ?palette.Rect = null,
        glyph_kind: TerminalGlyphKind,
    },
};

const TerminalPaneDrawCache = struct {
    active: bool = false,
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    rect: palette.Rect = .{},
    rows: u16 = 0,
    cols: u16 = 0,
    font_scale: f32 = 0.0,
    screen: @TypeOf(ghostty_vt.RenderState.empty.screen) = .primary,
    // Cache the cursor position so a pure cursor move forces a rebuild even
    // if the dirty flag doesn't propagate (e.g. a same-cell SGR that doesn't
    // touch the rendered grid). Otherwise the previous frame's cursor
    // highlight can linger over the old cell.
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_visible: bool = false,
    arena: ?std.heap.ArenaAllocator = null,
    commands: std.ArrayList(CachedDrawCommand) = .empty,

    fn matches(self: *const TerminalPaneDrawCache, dock_id: u32, pane_id: u32) bool {
        return self.active and self.dock_id == dock_id and self.pane_id == pane_id;
    }

    fn validFor(self: *const TerminalPaneDrawCache, render_state: *const ghostty_vt.RenderState, rect: palette.Rect, font_scale: f32) bool {
        const cursor_x: u16 = if (render_state.cursor.viewport) |c| @intCast(c.x) else 0;
        const cursor_y: u16 = if (render_state.cursor.viewport) |c| @intCast(c.y) else 0;
        return self.active and
            rectEql(self.rect, rect) and
            self.rows == render_state.rows and
            self.cols == render_state.cols and
            self.font_scale == font_scale and
            self.screen == render_state.screen and
            self.cursor_x == cursor_x and
            self.cursor_y == cursor_y and
            self.cursor_visible == render_state.cursor.visible and
            render_state.dirty == .false;
    }

    fn beginRebuild(self: *TerminalPaneDrawCache, allocator: std.mem.Allocator, dock_id: u32, pane_id: u32, render_state: *const ghostty_vt.RenderState, rect: palette.Rect, font_scale: f32) void {
        self.active = true;
        self.dock_id = dock_id;
        self.pane_id = pane_id;
        self.rect = rect;
        self.rows = render_state.rows;
        self.cols = render_state.cols;
        self.font_scale = font_scale;
        self.screen = render_state.screen;
        self.cursor_x = if (render_state.cursor.viewport) |c| @intCast(c.x) else 0;
        self.cursor_y = if (render_state.cursor.viewport) |c| @intCast(c.y) else 0;
        self.cursor_visible = render_state.cursor.visible;
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(allocator);
        _ = self.arena.?.reset(.retain_capacity);
        self.commands.clearRetainingCapacity();
    }

    fn append(self: *TerminalPaneDrawCache, allocator: std.mem.Allocator, command: CachedDrawCommand) void {
        self.commands.append(allocator, command) catch {
            self.active = false;
        };
    }

    fn stableText(self: *TerminalPaneDrawCache, value: []const u8) []const u8 {
        if (self.arena) |*arena| {
            return arena.allocator().dupe(u8, value) catch "";
        }
        return "";
    }
};

const MAX_TERMINAL_PANE_DRAW_CACHES = 96;

const TerminalDrawCache = struct {
    entries: [MAX_TERMINAL_PANE_DRAW_CACHES]TerminalPaneDrawCache = [_]TerminalPaneDrawCache{.{}} ** MAX_TERMINAL_PANE_DRAW_CACHES,
    next_recycle: usize = 0,

    fn entryFor(self: *TerminalDrawCache, dock_id: u32, pane_id: u32) *TerminalPaneDrawCache {
        for (&self.entries) |*entry| {
            if (entry.matches(dock_id, pane_id)) return entry;
        }
        for (&self.entries) |*entry| {
            if (!entry.active) return entry;
        }
        const entry = &self.entries[self.next_recycle];
        self.next_recycle = (self.next_recycle + 1) % self.entries.len;
        return entry;
    }
};

const TerminalImageTexture = struct {
    active: bool = false,
    terminal_id: usize = 0,
    image_id: u32 = 0,
    texture_id: u32 = 0,
};

const TerminalImageTextureCache = struct {
    entries: [MAX_TERMINAL_IMAGE_TEXTURES]TerminalImageTexture = [_]TerminalImageTexture{.{}} ** MAX_TERMINAL_IMAGE_TEXTURES,
    next_recycle: usize = 0,

    fn find(self: *TerminalImageTextureCache, terminal_id: usize, image_id: u32) ?u32 {
        for (&self.entries) |*entry| {
            if (entry.active and entry.terminal_id == terminal_id and entry.image_id == image_id) {
                return entry.texture_id;
            }
        }
        return null;
    }

    fn invalidateTerminal(self: *TerminalImageTextureCache, state: *app_state.AppState, terminal_id: usize) void {
        for (&self.entries) |*entry| {
            if (!entry.active or entry.terminal_id != terminal_id) continue;
            state.releaseTexture(entry.texture_id);
            entry.* = .{};
        }
    }

    fn store(self: *TerminalImageTextureCache, state: *app_state.AppState, entry: TerminalImageTexture) void {
        for (&self.entries) |*candidate| {
            if (!candidate.active) {
                candidate.* = entry;
                return;
            }
        }
        const candidate = &self.entries[self.next_recycle];
        self.next_recycle = (self.next_recycle + 1) % self.entries.len;
        state.releaseTexture(candidate.texture_id);
        candidate.* = entry;
    }
};

const PaneHit = struct {
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    rect: palette.Rect = .{},
};

const TerminalCellCoord = struct {
    x: usize = 0,
    y: usize = 0,
};

const TerminalSelection = struct {
    active: bool = false,
    dragging: bool = false,
    moved: bool = false,
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    start_x: f32 = 0.0,
    start_y: f32 = 0.0,
    anchor: TerminalCellCoord = .{},
    focus: TerminalCellCoord = .{},
};

const PendingLinkClick = struct {
    active: bool = false,
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    start_x: f32 = 0.0,
    start_y: f32 = 0.0,
    coord: TerminalCellCoord = .{},
    href_len: usize = 0,
    href: [MAX_TERMINAL_LINK_BYTES]u8 = undefined,

    fn value(self: *const PendingLinkClick) []const u8 {
        return self.href[0..self.href_len];
    }
};

const TerminalUrlCellRanges = struct {
    count: usize = 0,
    ranges: [32]struct { start: usize, end: usize } = undefined,

    fn add(self: *TerminalUrlCellRanges, start: usize, end: usize) void {
        if (self.count >= self.ranges.len or end < start) return;
        self.ranges[self.count] = .{ .start = start, .end = end };
        self.count += 1;
    }

    fn covers(self: *const TerminalUrlCellRanges, column: usize) bool {
        for (self.ranges[0..self.count]) |range| {
            if (column >= range.start and column <= range.end) return true;
        }
        return false;
    }
};

const TabHit = struct {
    dock_id: u32 = 0,
    index: usize = 0,
    rect: palette.Rect = .{},
};

const PaneHitTarget = struct {
    dock_id: u32,
    pane_id: u32,
    rect: palette.Rect = .{},
};

const TabHitTarget = struct {
    dock_id: u32,
    index: usize,
};

const ContextMenuHit = struct {
    action: TerminalContextMenuAction = .new_tab,
    rect: palette.Rect = .{},
    enabled: bool = false,
};

const TerminalHitCache = struct {
    pane_count: usize = 0,
    panes: [MAX_PANE_HITS]PaneHit = [_]PaneHit{.{}} ** MAX_PANE_HITS,
    tab_count: usize = 0,
    tabs: [MAX_TAB_HITS]TabHit = [_]TabHit{.{}} ** MAX_TAB_HITS,
    menu_open: bool = false,
    menu_kind: TerminalContextMenuKind = .pane,
    menu_pane_id: u32 = 0,
    menu_tab_index: usize = 0,
    menu_anchor: palette.Rect = .{},
    menu_panel: palette.Rect = .{},
    menu_count: usize = 0,
    menu_hits: [14]ContextMenuHit = [_]ContextMenuHit{.{}} ** 14,
    menu_dock_id: u32 = 0,
    dock_id: u32 = 0,
};

var hit_cache: TerminalHitCache = .{};
var selection_state: TerminalSelection = .{};
var pending_link_click: PendingLinkClick = .{};
var draw_cache: TerminalDrawCache = .{};
var image_texture_cache: TerminalImageTextureCache = .{};
var active_capture: ?*TerminalPaneDrawCache = null;
var terminal_layout_log_enabled: ?bool = null;

pub fn renderDock(state: *app_state.AppState, width: f32, height: f32) void {
    renderDockAt(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height });
}

pub fn renderDockAt(state: *app_state.AppState, rect: palette.Rect) void {
    resetHitCache();
    renderDockAtForDock(state, rect, 0);
}

pub fn paneHeaderHeight() f32 {
    return 0.0;
}

pub fn renderDockAtForDock(state: *app_state.AppState, rect: palette.Rect, dock_id: u32) void {
    renderDockAtForDockWithReserve(state, rect, dock_id, 0.0);
}

pub fn renderDockAtForDockWithReserve(state: *app_state.AppState, rect: palette.Rect, dock_id: u32, _: f32) void {
    if (state.projects.items.len == 0) return;
    hit_cache.dock_id = dock_id;
    var dock = state.currentProjectTerminalDockMutable(dock_id) orelse return;
    // No dock-level pre-resize: renderPane below resizes each pane against
    // its real (inset) grid rect. Pre-resizing here with the full dock rect
    // computes a different column count than the per-pane call, so on every
    // frame the active pane oscillated between two col counts and ghostty
    // reflowed back and forth — visible as terminal-pane jitter while typing.
    const dock_bg = if (dock.activeRenderState()) |render_state| rgbPaletteColor(render_state.colors.background, 1.0) else paletteColor(theme.background());
    queueRounded(state, rect, dock_bg, 0.0);
    queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), 0.0, 1.0);
    if (state.terminalDockSurfaceAttention(state.selected_project_index, dock_id)) {
        queueBorder(state, rect, paletteColor(theme.COLOR_YELLOW), 0.0, theme.scaledUi(2.0));
    }

    if (dock.activeTab()) |tab| {
        renderPaneNode(state, dock, tab.root, rect);
    } else {
        renderStatus(state, rect, "Starting shell...");
    }
    if (hit_cache.menu_open and hit_cache.menu_dock_id == dock_id) {
        renderContextMenu(state, dock, rect);
    }
    if (dock.takeFocusRequest()) {
        state.requestTerminalDockFocus(dock_id);
    }
}

pub fn handlePaletteKeyDown(state: *app_state.AppState, event: *const sdl.KeyboardEvent) bool {
    if (!terminalCopyShortcut(event) or !selection_state.active) return false;
    return copySelectionToClipboard(state);
}

pub fn handlePaletteMouseMotion(state: *app_state.AppState, x: f32, y: f32, buttons: sdl.MouseButtonFlags) bool {
    if (pending_link_click.active and selectionDragDistanceExceededFrom(pending_link_click.start_x, pending_link_click.start_y, x, y)) {
        pending_link_click = .{};
    }
    if (routeTerminalMouseMotion(state, x, y, buttons)) return true;
    if (!selection_state.dragging) return false;
    updateSelectionFocus(state, x, y) orelse return true;
    selection_state.moved = true;
    if (!selection_state.active and selectionDragDistanceExceeded(x, y)) {
        selection_state.active = true;
    }
    state.markDirty();
    return true;
}

pub fn mouseShapeAtPoint(state: *const app_state.AppState, x: f32, y: f32) ?ghostty_vt.MouseShape {
    const target = paneAtPoint(x, y) orelse return null;
    const dock = state.currentProjectTerminalDock(target.dock_id) orelse return null;
    return dock.mouseShapeForPane(target.pane_id);
}

fn routeTerminalMouseMotion(state: *app_state.AppState, x: f32, y: f32, buttons: sdl.MouseButtonFlags) bool {
    const target = paneAtPoint(x, y) orelse return false;
    var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
    return dock.handleMouseMotion(
        target.pane_id,
        terminalPressedMouseButton(buttons),
        x - target.rect.x,
        y - target.rect.y,
        target.rect.w,
        target.rect.h,
    );
}

fn terminalPressedMouseButton(buttons: sdl.MouseButtonFlags) ?u8 {
    if (buttons.left != 0) return 1;
    if (buttons.middle != 0) return 2;
    if (buttons.right != 0) return 3;
    if (buttons.x1 != 0) return 4;
    if (buttons.x2 != 0) return 5;
    return null;
}

pub fn handlePaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, button: u8, down: bool) bool {
    if (state.projects.items.len == 0) return false;
    if (button == 1 and !down and pending_link_click.active) return finishPendingLinkClick(state, x, y);
    if (button == 1 and hit_cache.menu_open) {
        if (!down) return true;
        const dock = state.currentProjectTerminalDockMutable(hit_cache.menu_dock_id) orelse return false;
        var i: usize = 0;
        while (i < hit_cache.menu_count) : (i += 1) {
            const hit = hit_cache.menu_hits[i];
            if (!hit.enabled or !rectContains(hit.rect, x, y)) continue;
            performContextMenuAction(state, dock, hit.action);
            hit_cache.menu_open = false;
            state.markDirty();
            return true;
        }
        if (!rectContains(hit_cache.menu_panel, x, y)) {
            hit_cache.menu_open = false;
            state.markDirty();
            return true;
        }
        return true;
    }
    if (button == 3 and rightClickSelectedPane(state, x, y, down)) return true;
    if (routeTerminalMouseButton(state, x, y, button, down)) return true;
    if (button == 1 and selection_state.dragging) {
        if (!down) {
            _ = updateSelectionFocus(state, x, y);
            selection_state.dragging = false;
            if (!selection_state.moved) selection_state.active = false;
            state.markDirty();
            return true;
        }
    }
    if (!down) return false;

    if (button == 1) {
        if (tabAtPoint(x, y)) |target| {
            hit_cache.dock_id = target.dock_id;
            var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
            dock.selectTab(target.index);
            focusTerminal(state);
            if (dock.consumeWorkspaceChange()) state.markDirty();
            hit_cache.menu_open = false;
            return true;
        }
        if (beginPendingLinkClick(state, x, y)) return true;
        // Try to begin a selection candidate first — it requires both a pane
        // hit AND a valid cell at the click, so clicks in the inset/padding
        // zone fall through to the focus-only branch below.
        if (beginSelectionCandidate(state, x, y)) return true;
        if (paneAtPoint(x, y)) |target| {
            hit_cache.dock_id = target.dock_id;
            var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
            dock.focusPane(target.pane_id);
            focusTerminal(state);
            clearSelection();
            if (dock.consumeWorkspaceChange()) state.markDirty();
            hit_cache.menu_open = false;
            return true;
        }
        return false;
    }

    if (button == 3) {
        if (tabAtPoint(x, y)) |target| {
            hit_cache.dock_id = target.dock_id;
            var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
            dock.selectTab(target.index);
            focusTerminal(state);
            openContextMenu(.tab, target.index, 0, x, y);
            if (dock.consumeWorkspaceChange()) state.markDirty();
            return true;
        }
        if (paneAtPoint(x, y)) |target| {
            hit_cache.dock_id = target.dock_id;
            var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
            dock.focusPane(target.pane_id);
            if (workspacePaneIdForDock(state, target.dock_id)) |workspace_pane_id| {
                _ = state.focusCurrentProjectWorkspacePane(workspace_pane_id);
            }
            focusTerminal(state);
            if (!selectionAffectsPane(target.dock_id, target.pane_id)) clearSelection();
            openContextMenu(.pane, 0, target.pane_id, x, y);
            if (dock.consumeWorkspaceChange()) state.markDirty();
            return true;
        }
    }
    return false;
}

fn routeTerminalMouseButton(state: *app_state.AppState, x: f32, y: f32, button: u8, down: bool) bool {
    const target = paneAtPoint(x, y) orelse return false;
    hit_cache.dock_id = target.dock_id;
    var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
    dock.focusPane(target.pane_id);
    if (workspacePaneIdForDock(state, target.dock_id)) |workspace_pane_id| {
        _ = state.focusCurrentProjectWorkspacePane(workspace_pane_id);
    }
    focusTerminal(state);
    if (!dock.handleMouseButton(target.pane_id, button, down, x - target.rect.x, y - target.rect.y, target.rect.w, target.rect.h)) {
        return false;
    }
    clearSelection();
    hit_cache.menu_open = false;
    if (dock.consumeWorkspaceChange()) state.markDirty();
    state.markDirty();
    return true;
}

fn rightClickSelectedPane(state: *app_state.AppState, x: f32, y: f32, down: bool) bool {
    const target = paneAtPoint(x, y) orelse return false;
    if (!selectionAffectsPane(target.dock_id, target.pane_id)) return false;
    if (!down) return true;
    hit_cache.dock_id = target.dock_id;
    var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
    dock.focusPane(target.pane_id);
    if (workspacePaneIdForDock(state, target.dock_id)) |workspace_pane_id| {
        _ = state.focusCurrentProjectWorkspacePane(workspace_pane_id);
    }
    focusTerminal(state);
    openContextMenu(.pane, 0, target.pane_id, x, y);
    if (dock.consumeWorkspaceChange()) state.markDirty();
    state.markDirty();
    return true;
}

pub fn handlePaletteWheel(state: *app_state.AppState, x: f32, y: f32, wheel_y: f32) bool {
    if (wheel_y == 0.0 or state.projects.items.len == 0) return false;
    if (paneAtPoint(x, y)) |target| {
        hit_cache.dock_id = target.dock_id;
        var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
        dock.focusPane(target.pane_id);
        focusTerminal(state);
        hit_cache.menu_open = false;
        if (dock.handleWheel(state.allocator, target.pane_id, wheel_y, x - target.rect.x, y - target.rect.y, target.rect.w, target.rect.h)) {
            state.markDirty();
        }
        if (dock.consumeWorkspaceChange()) state.markDirty();
        return true;
    }
    return false;
}

fn renderTabs(state: *app_state.AppState, dock: anytype, header: palette.Rect) void {
    const tab_h = theme.scaledUi(24.0);
    var x = header.x + theme.scaledUi(92.0);
    for (dock.tabs.items, 0..) |_, index| {
        var title_buf: [96]u8 = undefined;
        const label = dock.tabTitle(index, &title_buf);
        const tab_w = theme.clampf(@as(f32, @floatFromInt(label.len)) * theme.scaledUi(7.0) + theme.scaledUi(24.0), theme.scaledUi(72.0), theme.scaledUi(180.0));
        const tab_rect = palette.Rect{ .x = x, .y = header.y + theme.scaledUi(5.0), .w = tab_w, .h = tab_h };
        appendTabHit(index, tab_rect);
        if (index == dock.active_tab_index) queueRounded(state, tab_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(6.0));
        queueText(state, .{ .x = tab_rect.x + theme.scaledUi(10.0), .y = tab_rect.y + theme.scaledUi(4.0), .w = tab_rect.w - theme.scaledUi(20.0), .h = tab_rect.h }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), tab_rect);
        x += tab_w + theme.scaledUi(6.0);
        if (x > header.x + header.w - theme.scaledUi(80.0)) break;
    }
}

fn renderPaneNode(state: *app_state.AppState, dock: anytype, node: anytype, rect: palette.Rect) void {
    switch (node.*) {
        .leaf => |leaf| renderPane(state, dock, leaf.id, rect),
        .split => |split| {
            if (split.axis == .vertical) {
                const split_x = rect.x + rect.w * split.ratio;
                renderPaneNode(state, dock, split.first, .{ .x = rect.x, .y = rect.y, .w = split_x - rect.x, .h = rect.h });
                renderPaneNode(state, dock, split.second, .{ .x = split_x, .y = rect.y, .w = rect.x + rect.w - split_x, .h = rect.h });
                queueRect(state, .{ .x = split_x - theme.scaledUi(0.5), .y = rect.y, .w = theme.scaledUi(1.0), .h = rect.h }, paletteColor(theme.COLOR_PANEL_MUTED));
            } else {
                const split_y = rect.y + rect.h * split.ratio;
                renderPaneNode(state, dock, split.first, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = split_y - rect.y });
                renderPaneNode(state, dock, split.second, .{ .x = rect.x, .y = split_y, .w = rect.w, .h = rect.y + rect.h - split_y });
                queueRect(state, .{ .x = rect.x, .y = split_y - theme.scaledUi(0.5), .w = rect.w, .h = theme.scaledUi(1.0) }, paletteColor(theme.COLOR_PANEL_MUTED));
            }
        },
    }
}

fn renderPane(state: *app_state.AppState, dock: anytype, pane_id: u32, rect: palette.Rect) void {
    // `rect` is the full pane bounds; `grid_rect` is inset horizontally so
    // cell output gets breathing room without pulling the focus border or
    // mouse hit envelope inward (the focus border should hug the dock edge
    // for outermost panes, not float at the inset).
    const inset = terminalPaneHorizontalInset();
    const grid_rect = palette.Rect{
        .x = rect.x + inset,
        .y = rect.y,
        .w = @max(rect.w - inset * 2.0, 1.0),
        .h = rect.h,
    };
    appendPaneHit(pane_id, grid_rect);
    // A failed resize must be visible in diagnostics: the session's cell
    // counts are updated before the fallible daemon/model steps, so a single
    // failure makes later frames see "no size change" and never retry,
    // leaving the PTY/model at the wrong size.
    dock.resizePaneToFit(state.allocator, pane_id, grid_rect.w, grid_rect.h) catch |err| {
        runtime_log.diagnostic("terminal resizePaneToFit failed pane={d} err={s}", .{ pane_id, @errorName(err) });
    };
    const focused = if (dock.activePaneConst()) |active| active.id == pane_id and state.terminal_focused else false;
    const render_state = dock.renderStateForPane(pane_id) orelse {
        var status_buf: [192]u8 = undefined;
        queueRect(state, rect, paletteColor(theme.background()));
        renderStatus(state, rect, dock.statusText(&status_buf));
        return;
    };
    renderViewport(state, pane_id, render_state, dock.terminalForPane(pane_id), grid_rect, dock.font_scale);
    if (dock.scrollbarForPane(pane_id)) |scrollbar| {
        renderTerminalScrollbar(state, rect, grid_rect, scrollbar);
    }
    dock.markPaneRendered(pane_id);
    if (focused) queueBorder(state, rect, paletteColor(theme.COLOR_SECONDARY_GREEN), 0.0, theme.scaledUi(1.0));
}

fn renderViewport(state: *app_state.AppState, pane_id: u32, render_state: *const ghostty_vt.RenderState, terminal_model: ?*ghostty_vt.Terminal, rect: palette.Rect, font_scale: f32) void {
    if (render_state.rows == 0 or render_state.cols == 0) return;
    if (terminal_model) |model| {
        if (model.screens.active.kitty_images.dirty) {
            image_texture_cache.invalidateTerminal(state, @intFromPtr(model));
        }
    }
    const dock_id = hit_cache.dock_id;
    const cache = draw_cache.entryFor(dock_id, pane_id);
    const selection_dynamic = selectionAffectsPane(dock_id, pane_id);
    // Diagnostic: VERDE_TERMINAL_DISABLE_DRAW_CACHE=1 forces every frame to
    // rebuild. Used to isolate cache-invalidation bugs (e.g. zoom-then-scroll
    // showing narrow-cell ghost rows from a pre-resize cached frame) from
    // upstream Ghostty reflow issues. If the artifact vanishes with this set,
    // the cache key is missing something it should depend on.
    if (!selection_dynamic and !drawCacheBypassEnabled() and cache.validFor(render_state, rect, font_scale)) {
        replayCachedViewport(state, cache);
        if (terminal_model) |model| {
            renderTerminalImages(state, model, rect, rect, terminalRenderCellSize(terminal.CELL_PIXEL_WIDTH, font_scale), terminalRenderCellSize(terminal.CELL_PIXEL_HEIGHT, font_scale));
            model.screens.active.kitty_images.dirty = false;
        }
        return;
    }

    cache.beginRebuild(state.allocator, dock_id, pane_id, render_state, rect, font_scale);
    active_capture = cache;
    defer active_capture = null;

    const cols_f = @as(f32, @floatFromInt(render_state.cols));
    const rows_f = @as(f32, @floatFromInt(render_state.rows));
    const cell_w = terminalRenderCellSize(terminal.CELL_PIXEL_WIDTH, font_scale);
    const cell_h = terminalRenderCellSize(terminal.CELL_PIXEL_HEIGHT, font_scale);
    const grid_rect = palette.Rect{
        .x = rect.x,
        .y = rect.y,
        .w = @min(cell_w * cols_f, rect.w),
        .h = @min(cell_h * rows_f, rect.h),
    };
    logTerminalViewport("rebuild", dock_id, pane_id, rect, render_state, font_scale);
    const font_size = terminalFontSizeForCell(cell_w, cell_h);
    const text_y_offset = @max((cell_h - font_size) * 0.34, 0.0);

    queueRect(state, rect, rgbPaletteColor(render_state.colors.background, 1.0));
    const row_data = render_state.row_data.slice();
    const row_cells = row_data.items(.cells);
    const row_selections = row_data.items(.selection);
    const visible_rows = @min(row_cells.len, @as(usize, @intFromFloat(@ceil(rect.h / cell_h))));
    const visible_cols = @min(@as(usize, render_state.cols), @as(usize, @intFromFloat(@ceil(rect.w / cell_w))));
    const row_start = visibleRowStart(render_state, visible_rows);

    for (0..visible_rows) |visual_y| {
        const model_y = row_start + visual_y;
        const cells = row_cells[model_y];
        const selection = row_selections[model_y];
        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);
        const row_styles = cells_slice.items(.style);
        const row_graphemes = cells_slice.items(.grapheme);
        const row_y = grid_rect.y + @as(f32, @floatFromInt(visual_y)) * cell_h;
        if (row_y >= rect.y + rect.h) break;
        const url_ranges = terminalUrlCellRanges(state.allocator, cells) catch TerminalUrlCellRanges{};

        const row_visible_cols = @min(raw_cells.len, visible_cols);
        for (raw_cells[0..row_visible_cols], 0..) |raw_cell, x| {
            const span = @as(f32, @floatFromInt(cellWidthCells(raw_cell)));
            const cell_rect = terminalCellRect(grid_rect, cell_w, cell_h, x, visual_y, span);
            if (cell_rect.x >= rect.x + rect.w) break;
            const cell_style = styleForCell(raw_cell, row_styles, x);
            var bg = cell_style.bg(&raw_cell, &render_state.colors.palette) orelse render_state.colors.background;
            var fg = cell_style.fg(.{ .default = render_state.colors.foreground, .palette = &render_state.colors.palette, .bold = .bright });

            // Apply the SGR inverse (reverse-video) attribute. ghostty's
            // Style.bg/fg deliberately return the raw colors; swapping for
            // `flags.inverse` is the renderer's job. Both values are already
            // resolved to concrete defaults above, so a plain swap is correct.
            // This also restores app-drawn cursors (e.g. Claude Code / Ink),
            // which paint the caret cell as inverse video rather than relying
            // on the hardware (DECTCEM) cursor handled below.
            if (cell_style.flags.inverse) {
                const swap = bg;
                bg = fg;
                fg = swap;
            }

            if (selection) |range| {
                if (x >= range[0] and x <= range[1]) bg = blendRgb(bg, render_state.colors.foreground, 0.22);
            }
            if (selectionCoversCell(hit_cache.dock_id, pane_id, x, model_y)) {
                bg = blendRgb(bg, render_state.colors.foreground, 0.32);
            }
            if (render_state.cursor.viewport) |cursor| {
                if (cursor.x == x and cursor.y == model_y and render_state.cursor.visible) {
                    if (render_state.cursor.visual_style == .block) {
                        const cursor_fill = render_state.colors.cursor orelse render_state.colors.foreground;
                        bg = blendRgb(bg, cursor_fill, 0.62);
                        fg = render_state.colors.background;
                    } else {
                        drawCursor(state, render_state, cell_rect, rect);
                    }
                }
            }

            if (!rgbEql(bg, render_state.colors.background) or rawCellNeedsFill(raw_cell)) {
                queueClippedRect(state, cell_rect, rgbPaletteColor(bg, 1.0), rect);
            }
            if (!raw_cell.hasText() or raw_cell.wide == .spacer_tail) continue;
            if (raw_cell.codepoint() == ghostty_vt.kitty.graphics.unicode.placeholder) continue;
            var text_buf: [128]u8 = undefined;
            const text = cellText(raw_cell, graphemesForCell(raw_cell, row_graphemes, x), &text_buf) orelse continue;
            const glyph_kind = terminalGlyphKind(raw_cell.codepoint());
            if (glyph_kind == .powerline) {
                queuePowerlineGlyph(state, cell_rect, raw_cell.codepoint(), rgbPaletteColor(fg, foregroundAlpha(cell_style)), rect);
                continue;
            }
            if (queueTerminalCellGeometry(state, cell_rect, raw_cell.codepoint(), rgbPaletteColor(fg, foregroundAlpha(cell_style)), rect)) {
                continue;
            }
            // Codepoints that fall through to the proportional fallback faces
            // (Noto Sans Symbols / Symbols 2 / Emoji) have their baseline
            // metrics expressed for proportional layout — the visible glyph
            // sits noticeably lower in the em-box than mono glyphs at the
            // same y. Lift them so they line up with adjacent mono text.
            const glyph_y_offset = text_y_offset - cell_h * glyphBaselineLiftFraction(raw_cell.codepoint());
            const text_rect = terminalTextRect(cell_rect, glyph_y_offset, glyph_kind);
            const draw_font_size = terminalTextFontSize(font_size, glyph_kind);
            queueTerminalText(state, .{
                .x = text_rect.x,
                .y = text_rect.y,
                .w = text_rect.w,
                .h = text_rect.h,
            }, text, rgbPaletteColor(fg, foregroundAlpha(cell_style)), draw_font_size, intersectRect(if (glyph_kind != .text or glyphNeedsRelaxedClip(raw_cell.codepoint())) rect else cell_rect, rect), glyph_kind);
            if (url_ranges.covers(x)) {
                drawTerminalLinkUnderline(state, cell_rect, rgbPaletteColor(fg, foregroundAlpha(cell_style)), rect);
            }
        }
    }
    if (terminal_model) |model| {
        renderTerminalImages(state, model, grid_rect, rect, cell_w, cell_h);
        model.screens.active.kitty_images.dirty = false;
    }
}

fn renderStatus(state: *app_state.AppState, rect: palette.Rect, label: []const u8) void {
    queueText(state, .{
        .x = rect.x + theme.scaledUi(16.0),
        .y = rect.y + theme.scaledUi(18.0),
        .w = rect.w - theme.scaledUi(32.0),
        .h = theme.scaledUi(24.0),
    }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), rect);
}

fn replayCachedViewport(state: *app_state.AppState, cache: *const TerminalPaneDrawCache) void {
    for (cache.commands.items) |command| {
        switch (command) {
            .rect => |cmd| queueClippedRect(state, cmd.rect, cmd.color, cmd.clip),
            .border => |cmd| queueBorder(state, cmd.rect, cmd.color, cmd.radius, cmd.width),
            .triangle => |cmd| queueTriangle(state, cmd.p0, cmd.p1, cmd.p2, cmd.color, cmd.clip),
            .terminal_text => |cmd| queueTerminalText(state, cmd.rect, cmd.value, cmd.color, cmd.font_size, cmd.clip, cmd.glyph_kind),
        }
    }
}

/// Renders Kitty image placements stored by Ghostty VT into the terminal grid.
fn renderTerminalImages(state: *app_state.AppState, model: *const ghostty_vt.Terminal, grid_rect: palette.Rect, clip: palette.Rect, cell_w: f32, cell_h: f32) void {
    const storage = &model.screens.active.kitty_images;
    if (storage.images.count() == 0 or storage.placements.count() == 0) return;
    const model_cell_w = model.width_px / @max(model.cols, 1);
    const model_cell_h = model.height_px / @max(model.rows, 1);
    if (model_cell_w == 0 or model_cell_h == 0) return;
    const scale_x = cell_w / @as(f32, @floatFromInt(model_cell_w));
    const scale_y = cell_h / @as(f32, @floatFromInt(model_cell_h));

    renderPinnedTerminalImages(state, model, storage, grid_rect, clip, scale_x, scale_y);

    const top = model.screens.active.pages.getTopLeft(.viewport);
    const bottom = model.screens.active.pages.getBottomRight(.viewport) orelse return;
    var iterator = ghostty_vt.kitty.graphics.unicode.placementIterator(top, bottom);
    while (iterator.next()) |virtual_placement| {
        var image = storage.imageById(virtual_placement.image_id) orelse continue;
        const placement = virtual_placement.renderPlacement(storage, &image, model_cell_w, model_cell_h) catch continue;
        if (placement.dest_width == 0 or placement.dest_height == 0) continue;
        const viewport = model.screens.active.pages.pointFromPin(.viewport, placement.top_left) orelse continue;
        const texture_id = ensureTerminalImageTexture(state, model, &image) orelse continue;
        const dest: palette.Rect = .{
            .x = grid_rect.x + @as(f32, @floatFromInt(viewport.viewport.x)) * cell_w + @as(f32, @floatFromInt(placement.offset_x)) * scale_x,
            .y = grid_rect.y + @as(f32, @floatFromInt(viewport.viewport.y)) * cell_h + @as(f32, @floatFromInt(placement.offset_y)) * scale_y,
            .w = @as(f32, @floatFromInt(placement.dest_width)) * scale_x,
            .h = @as(f32, @floatFromInt(placement.dest_height)) * scale_y,
        };
        queueTerminalImage(state, dest, texture_id, terminalImageUv(&image, placement.source_x, placement.source_y, placement.source_width, placement.source_height), clip);
    }
}

/// Renders non-virtual Kitty placements anchored directly to terminal pins.
fn renderPinnedTerminalImages(state: *app_state.AppState, model: *const ghostty_vt.Terminal, storage: *const ghostty_vt.kitty.graphics.ImageStorage, grid_rect: palette.Rect, clip: palette.Rect, scale_x: f32, scale_y: f32) void {
    var iterator = storage.placements.iterator();
    while (iterator.next()) |entry| {
        const placement = entry.value_ptr;
        const pin = switch (placement.location) {
            .pin => |value| value,
            .virtual => continue,
        };
        var image = storage.imageById(entry.key_ptr.image_id) orelse continue;
        const viewport = model.screens.active.pages.pointFromPin(.viewport, pin.*) orelse continue;
        const size = placement.pixelSize(image, model);
        if (size.width == 0 or size.height == 0) continue;
        const texture_id = ensureTerminalImageTexture(state, model, &image) orelse continue;
        const source_x = @min(placement.source_x, image.width);
        const source_y = @min(placement.source_y, image.height);
        const source_width = @min(if (placement.source_width > 0) placement.source_width else image.width, image.width - source_x);
        const source_height = @min(if (placement.source_height > 0) placement.source_height else image.height, image.height - source_y);
        const dest: palette.Rect = .{
            .x = grid_rect.x + @as(f32, @floatFromInt(viewport.viewport.x)) * (scale_x * @as(f32, @floatFromInt(model.width_px / @max(model.cols, 1)))) + @as(f32, @floatFromInt(placement.x_offset)) * scale_x,
            .y = grid_rect.y + @as(f32, @floatFromInt(viewport.viewport.y)) * (scale_y * @as(f32, @floatFromInt(model.height_px / @max(model.rows, 1)))) + @as(f32, @floatFromInt(placement.y_offset)) * scale_y,
            .w = @as(f32, @floatFromInt(size.width)) * scale_x,
            .h = @as(f32, @floatFromInt(size.height)) * scale_y,
        };
        queueTerminalImage(state, dest, texture_id, terminalImageUv(&image, source_x, source_y, source_width, source_height), clip);
    }
}

fn terminalImageUv(image: *const ghostty_vt.kitty.graphics.Image, x: u32, y: u32, width: u32, height: u32) palette.Rect {
    const image_w: f32 = @floatFromInt(@max(image.width, 1));
    const image_h: f32 = @floatFromInt(@max(image.height, 1));
    return .{
        .x = @as(f32, @floatFromInt(x)) / image_w,
        .y = @as(f32, @floatFromInt(y)) / image_h,
        .w = @as(f32, @floatFromInt(width)) / image_w,
        .h = @as(f32, @floatFromInt(height)) / image_h,
    };
}

fn ensureTerminalImageTexture(state: *app_state.AppState, model: *const ghostty_vt.Terminal, image: *const ghostty_vt.kitty.graphics.Image) ?u32 {
    const terminal_id = @intFromPtr(model);
    if (image_texture_cache.find(terminal_id, image.id)) |texture_id| return texture_id;
    const rgba = terminalImageRgba(state.allocator, image) orelse return null;
    defer if (rgba.owned) state.allocator.free(rgba.pixels);
    const texture = state.uploadRgbaTexture(image.width, image.height, rgba.pixels) orelse {
        runtime_log.diagnostic("terminal image texture upload failed image={d} format={s} size={d}x{d} bytes={d}", .{ image.id, @tagName(image.format), image.width, image.height, rgba.pixels.len });
        return null;
    };
    image_texture_cache.store(state, .{
        .active = true,
        .terminal_id = terminal_id,
        .image_id = image.id,
        .texture_id = texture.texture_id,
    });
    return texture.texture_id;
}

const TerminalRgbaPixels = struct {
    pixels: []const u8,
    owned: bool,
};

fn terminalImageRgba(allocator: std.mem.Allocator, image: *const ghostty_vt.kitty.graphics.Image) ?TerminalRgbaPixels {
    const pixel_count = std.math.mul(usize, image.width, image.height) catch return null;
    const rgba_len = std.math.mul(usize, pixel_count, 4) catch return null;
    if (image.format == .rgba) {
        if (image.data.len != rgba_len) return null;
        return .{ .pixels = image.data, .owned = false };
    }
    const source_bpp: usize = switch (image.format) {
        .rgb => 3,
        .gray_alpha => 2,
        .gray => 1,
        .rgba => unreachable,
        .png => return null,
    };
    const source_len = std.math.mul(usize, pixel_count, source_bpp) catch return null;
    if (image.data.len != source_len) return null;
    const pixels = allocator.alloc(u8, rgba_len) catch return null;
    for (0..pixel_count) |index| {
        const src = index * source_bpp;
        const dst = index * 4;
        switch (image.format) {
            .rgb => {
                pixels[dst] = image.data[src];
                pixels[dst + 1] = image.data[src + 1];
                pixels[dst + 2] = image.data[src + 2];
                pixels[dst + 3] = 255;
            },
            .gray_alpha => {
                @memset(pixels[dst .. dst + 3], image.data[src]);
                pixels[dst + 3] = image.data[src + 1];
            },
            .gray => {
                @memset(pixels[dst .. dst + 3], image.data[src]);
                pixels[dst + 3] = 255;
            },
            .rgba, .png => unreachable,
        }
    }
    return .{ .pixels = pixels, .owned = true };
}

fn selectionAffectsPane(dock_id: u32, pane_id: u32) bool {
    return selection_state.active and selection_state.dock_id == dock_id and selection_state.pane_id == pane_id;
}

fn visibleRowStart(render_state: *const ghostty_vt.RenderState, visible_rows: usize) usize {
    if (render_state.screen != .alternate) return 0;
    if (visible_rows >= render_state.rows) return 0;
    return @as(usize, render_state.rows) - visible_rows;
}

/// Renders the terminal scrollback position indicator along the pane edge.
fn renderTerminalScrollbar(state: *app_state.AppState, pane_rect: palette.Rect, grid_rect: palette.Rect, scrollbar: terminal.TerminalScrollbar) void {
    if (scrollbar.len == 0 or scrollbar.total <= scrollbar.len) return;
    const pad_y = theme.scaledUi(TERMINAL_SCROLLBAR_VERTICAL_PAD_CSS);
    if (grid_rect.h <= pad_y * 2.0 + theme.scaledUi(TERMINAL_SCROLLBAR_MIN_THUMB_CSS)) return;

    const track_w = theme.scaledUi(TERMINAL_SCROLLBAR_TRACK_WIDTH_CSS);
    const edge_pad = theme.scaledUi(TERMINAL_SCROLLBAR_EDGE_PAD_CSS);
    const track: palette.Rect = .{
        .x = pane_rect.x + pane_rect.w - edge_pad - track_w,
        .y = grid_rect.y + pad_y,
        .w = track_w,
        .h = grid_rect.h - pad_y * 2.0,
    };

    const total_f: f32 = @floatFromInt(scrollbar.total);
    const len_f: f32 = @floatFromInt(scrollbar.len);
    const scrollable_rows = scrollbar.total - scrollbar.len;
    const offset_f: f32 = @floatFromInt(@min(scrollbar.offset, scrollable_rows));
    const scrollable_f: f32 = @floatFromInt(scrollable_rows);
    const thumb_h = @min(track.h, @max(theme.scaledUi(TERMINAL_SCROLLBAR_MIN_THUMB_CSS), track.h * (len_f / total_f)));
    const thumb_y = track.y + (track.h - thumb_h) * (offset_f / scrollable_f);

    queueRounded(state, track, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 140)), theme.scaledUi(2.0));
    queueRounded(state, .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, paletteColor(theme.withAlpha(theme.COLOR_TEXT_MUTED, 220)), theme.scaledUi(2.0));
}

fn renderContextMenu(state: *app_state.AppState, dock: anytype, dock_rect: palette.Rect) void {
    if (!hit_cache.menu_open) return;
    const mx = state.palette_mouse_x;
    const my = state.palette_mouse_y;
    const mouse_ok = state.palette_mouse_in_workspace;

    var actions: [14]TerminalContextMenuAction = undefined;
    var labels: [14][]const u8 = undefined;
    var enabled: [14]bool = undefined;
    var count: usize = 0;
    //NOTE: DIsabled for now b/c we dont to tradional tabs
    // actions[count] = .new_tab;
    // labels[count] = "New Tab";
    // enabled[count] = true;
    // count += 1;
    //NOTE: Didabling rihgt click agents since users is already in terminal
    // actions[count] = .new_claude_tab;
    // labels[count] = "New Claude Tab";
    // enabled[count] = true;
    // count += 1;
    // actions[count] = .new_opencode_tab;
    // labels[count] = "New OpenCode Tab";
    // enabled[count] = true;
    // count += 1;
    // actions[count] = .new_codex_tab;
    // labels[count] = "New Codex Tab";
    // enabled[count] = true;
    // count += 1;
    // actions[count] = .new_cursor_tab;
    // labels[count] = "New Cursor Tab";
    // enabled[count] = true;
    // count += 1;
    if (state.hasCustomTerminalLaunchProfile()) {
        actions[count] = .new_custom_tab;
        labels[count] = state.customTerminalLaunchProfileLabel();
        enabled[count] = true;
        count += 1;
    }
    if (hit_cache.menu_kind == .tab) {
        actions[count] = .rename_tab;
        labels[count] = "Rename Tab";
        enabled[count] = true;
        count += 1;
        actions[count] = .close_tab;
        labels[count] = "Close Tab";
        enabled[count] = dock.tabs.items.len > 1;
        count += 1;
    } else {
        const workspace_pane_id = workspacePaneIdForDock(state, hit_cache.menu_dock_id);
        const has_workspace_pane = workspace_pane_id != null;
        if (selectionAffectsPane(hit_cache.menu_dock_id, hit_cache.menu_pane_id)) {
            actions[count] = .copy_selection;
            labels[count] = "Copy";
            enabled[count] = true;
            count += 1;
        }
        actions[count] = .zoom_pane;
        labels[count] = if (workspace_pane_id) |pane_id|
            if (state.isCurrentProjectWorkspacePaneMaximized(pane_id)) "Unzoom Pane" else "Zoom Pane"
        else
            "Zoom Pane";
        enabled[count] = has_workspace_pane;
        count += 1;
        actions[count] = .split_up;
        labels[count] = "New Pane Above";
        enabled[count] = has_workspace_pane;
        count += 1;
        actions[count] = .split_down;
        labels[count] = "New Pane Below";
        enabled[count] = has_workspace_pane;
        count += 1;
        actions[count] = .split_left;
        labels[count] = "New Pane Left";
        enabled[count] = has_workspace_pane;
        count += 1;
        actions[count] = .split_right;
        labels[count] = "New Pane Right";
        enabled[count] = has_workspace_pane;
        count += 1;
        actions[count] = .close_pane;
        labels[count] = "Close Pane";
        enabled[count] = has_workspace_pane;
        count += 1;
    }

    const menu_w = theme.scaledUi(TERMINAL_CONTEXT_MENU_WIDTH);
    const pad = theme.scaledUi(TERMINAL_CONTEXT_MENU_PAD);
    const row_h = theme.scaledUi(TERMINAL_CONTEXT_MENU_ROW_HEIGHT);
    const menu_h = pad * 2.0 + row_h * @as(f32, @floatFromInt(count));
    var menu_x = hit_cache.menu_anchor.x;
    var menu_y = hit_cache.menu_anchor.y;
    if (menu_x + menu_w > dock_rect.x + dock_rect.w) menu_x = dock_rect.x + dock_rect.w - menu_w - theme.scaledUi(4.0);
    if (menu_y + menu_h > dock_rect.y + dock_rect.h) menu_y = dock_rect.y + dock_rect.h - menu_h - theme.scaledUi(4.0);

    menu_x = @max(dock_rect.x + theme.scaledUi(4.0), menu_x);
    menu_y = @max(dock_rect.y + theme.scaledUi(4.0), menu_y);
    hit_cache.menu_panel = .{ .x = menu_x, .y = menu_y, .w = menu_w, .h = menu_h };

    queueRounded(state, hit_cache.menu_panel, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(8.0));
    queueBorder(state, hit_cache.menu_panel, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), theme.scaledUi(1.0));

    hit_cache.menu_count = count;
    var i: usize = 0;
    var y = menu_y + pad;
    while (i < count) : (i += 1) {
        const row = palette.Rect{ .x = menu_x + pad, .y = y, .w = menu_w - pad * 2.0, .h = row_h };
        hit_cache.menu_hits[i] = .{ .action = actions[i], .rect = row, .enabled = enabled[i] };
        const hovered = mouse_ok and enabled[i] and rectContains(row, mx, my);
        if (hovered) queueRounded(state, row, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(6.0));
        queueText(state, .{
            .x = row.x + theme.scaledUi(10.0),
            .y = row.y + theme.scaledUi(6.0),
            .w = row.w - theme.scaledUi(20.0),
            .h = row.h,
        }, labels[i], paletteColor(if (enabled[i]) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), hit_cache.menu_panel);
        y += row_h;
    }
}

fn performContextMenuAction(state: *app_state.AppState, dock: anytype, action: TerminalContextMenuAction) void {
    const focus_menu_dock_after = switch (action) {
        .split_up, .split_down, .split_left, .split_right, .zoom_pane, .close_pane => false,
        else => true,
    };
    const uses_workspace_pane_action = switch (action) {
        .split_up, .split_down, .split_left, .split_right, .zoom_pane, .close_pane => true,
        else => false,
    };
    switch (action) {
        .copy_selection => _ = copySelectionToClipboard(state),
        .new_tab => _ = state.createCurrentProjectTerminalTab(hit_cache.menu_dock_id, .{}),
        .new_claude_tab => _ = state.createCurrentProjectTerminalTab(hit_cache.menu_dock_id, .{ .kind = .claude, .label = "Claude" }),
        .new_opencode_tab => _ = state.createCurrentProjectTerminalTab(hit_cache.menu_dock_id, .{ .kind = .opencode, .label = "OpenCode" }),
        .new_codex_tab => _ = state.createCurrentProjectTerminalTab(hit_cache.menu_dock_id, .{ .kind = .codex, .label = "Codex" }),
        .new_cursor_tab => _ = state.createCurrentProjectTerminalTab(hit_cache.menu_dock_id, .{ .kind = .cursor, .label = "Cursor" }),
        .new_custom_tab => if (state.firstCustomTerminalLaunchProfile()) |profile| {
            _ = state.createCurrentProjectTerminalTab(hit_cache.menu_dock_id, profile);
        },
        .rename_tab => if (dock.activeTab()) |tab| dock.beginRenameTab(tab.id),
        .close_tab => dock.closeTab(state.allocator, hit_cache.menu_tab_index) catch |err| app_state.log.warn("failed to close terminal tab: {s}", .{@errorName(err)}),
        .split_up => if (workspacePaneIdForDock(state, hit_cache.menu_dock_id)) |pane_id| {
            _ = state.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, .horizontal, false);
        },
        .split_down => if (workspacePaneIdForDock(state, hit_cache.menu_dock_id)) |pane_id| {
            _ = state.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, .horizontal, true);
        },
        .split_left => if (workspacePaneIdForDock(state, hit_cache.menu_dock_id)) |pane_id| {
            _ = state.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, .vertical, false);
        },
        .split_right => if (workspacePaneIdForDock(state, hit_cache.menu_dock_id)) |pane_id| {
            _ = state.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, .vertical, true);
        },
        .zoom_pane => if (workspacePaneIdForDock(state, hit_cache.menu_dock_id)) |pane_id| {
            _ = state.toggleCurrentProjectWorkspacePaneMaximized(pane_id);
        },
        .close_pane => if (workspacePaneIdForDock(state, hit_cache.menu_dock_id)) |pane_id| {
            _ = state.closeCurrentProjectWorkspacePane(pane_id);
        },
    }
    if (focus_menu_dock_after) focusTerminal(state);
    if (!uses_workspace_pane_action and dock.consumeWorkspaceChange()) state.markDirty();
}

fn workspacePaneIdForDock(state: *const app_state.AppState, dock_id: u32) ?app_state.WorkspacePaneId {
    if (state.projects.items.len == 0) return null;
    const layout = &state.projects.items[state.selected_project_index].workspace_layout;
    for (layout.panes.items) |pane| {
        if (pane.minimized) continue;
        switch (pane.ref) {
            .terminal => |ref| if (ref.dock_id == dock_id) return pane.id,
            else => {},
        }
    }
    return null;
}

fn focusTerminal(state: *app_state.AppState) void {
    state.requestTerminalDockFocus(if (hit_cache.menu_open) hit_cache.menu_dock_id else hit_cache.dock_id);
}

fn beginPendingLinkClick(state: *app_state.AppState, x: f32, y: f32) bool {
    const target = paneAtPoint(x, y) orelse return false;
    hit_cache.dock_id = target.dock_id;
    const dock = state.currentProjectTerminalDock(target.dock_id) orelse return false;
    // Full-screen TUIs that requested mouse input own plain clicks; do not
    // steal those events for link opening.
    if (dock.paneWantsMouseInput(target.pane_id)) return false;
    const coord = cellAtPoint(state, target, x, y) orelse return false;
    const href = linkAtCell(state.allocator, dock, target.pane_id, coord) catch |err| {
        log.warn("failed to hit-test terminal link: {s}", .{@errorName(err)});
        return false;
    } orelse return false;
    defer state.allocator.free(href);
    if (href.len == 0 or href.len > pending_link_click.href.len) return false;

    var mutable_dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
    mutable_dock.focusPane(target.pane_id);
    if (workspacePaneIdForDock(state, target.dock_id)) |workspace_pane_id| {
        _ = state.focusCurrentProjectWorkspacePane(workspace_pane_id);
    }
    focusTerminal(state);
    clearSelection();
    pending_link_click = .{
        .active = true,
        .dock_id = target.dock_id,
        .pane_id = target.pane_id,
        .start_x = x,
        .start_y = y,
        .coord = coord,
        .href_len = href.len,
    };
    @memcpy(pending_link_click.href[0..href.len], href);
    hit_cache.menu_open = false;
    if (mutable_dock.consumeWorkspaceChange()) state.markDirty();
    state.markDirty();
    return true;
}

fn finishPendingLinkClick(state: *app_state.AppState, x: f32, y: f32) bool {
    const click = pending_link_click;
    pending_link_click = .{};
    if (selectionDragDistanceExceededFrom(click.start_x, click.start_y, x, y)) return true;
    const target = paneAtPoint(x, y) orelse return true;
    if (target.dock_id != click.dock_id or target.pane_id != click.pane_id) return true;
    const coord = cellAtPoint(state, target, x, y) orelse return true;
    if (coord.x != click.coord.x or coord.y != click.coord.y) return true;

    state.openConfiguredWebLink(click.value());
    state.markDirty();
    return true;
}

fn linkAtCell(allocator: std.mem.Allocator, dock: *const terminal.Dock, pane_id: u32, coord: TerminalCellCoord) !?[]u8 {
    const render_state = dock.renderStateForPane(pane_id) orelse return null;
    const row_data = render_state.row_data.slice();
    const row_cells = row_data.items(.cells);
    if (coord.y >= row_cells.len) return null;

    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(allocator);
    var byte_cols: std.ArrayList(usize) = .empty;
    defer byte_cols.deinit(allocator);
    try appendTerminalRowText(allocator, row_cells[coord.y], &row_text, &byte_cols);
    return urlAtRowColumn(allocator, row_text.items, byte_cols.items, coord.x);
}

fn appendTerminalRowText(
    allocator: std.mem.Allocator,
    row: anytype,
    output: *std.ArrayList(u8),
    byte_cols: *std.ArrayList(usize),
) !void {
    const cells_slice = row.slice();
    const raw_cells = cells_slice.items(.raw);
    const row_graphemes = cells_slice.items(.grapheme);
    for (raw_cells, 0..) |raw_cell, x| {
        if (raw_cell.wide == .spacer_tail) continue;
        var text_buf: [128]u8 = undefined;
        const text = if (raw_cell.hasText())
            cellText(raw_cell, graphemesForCell(raw_cell, row_graphemes, x), &text_buf) orelse " "
        else
            " ";
        try output.appendSlice(allocator, text);
        for (0..text.len) |_| try byte_cols.append(allocator, x);
    }
}

fn terminalUrlCellRanges(allocator: std.mem.Allocator, row: anytype) !TerminalUrlCellRanges {
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(allocator);
    var byte_cols: std.ArrayList(usize) = .empty;
    defer byte_cols.deinit(allocator);
    try appendTerminalRowText(allocator, row, &row_text, &byte_cols);

    var result: TerminalUrlCellRanges = .{};
    var index: usize = 0;
    while (index < row_text.items.len) {
        const start = nextUrlStart(row_text.items, index) orelse break;
        var end = start;
        while (end < row_text.items.len and isUrlBodyByte(row_text.items[end])) : (end += 1) {}
        end = trimUrlEnd(row_text.items, start, end);
        if (urlByteRangeColumns(byte_cols.items, start, end)) |cols| {
            result.add(cols.start, cols.end);
        }
        index = @max(end, start + 1);
    }
    return result;
}

fn urlAtRowColumn(allocator: std.mem.Allocator, row_text: []const u8, byte_cols: []const usize, column: usize) !?[]u8 {
    if (row_text.len == 0 or row_text.len != byte_cols.len) return null;
    var index: usize = 0;
    while (index < row_text.len) {
        const start = nextUrlStart(row_text, index) orelse return null;
        var end = start;
        while (end < row_text.len and isUrlBodyByte(row_text[end])) : (end += 1) {}
        end = trimUrlEnd(row_text, start, end);
        if (end > start and columnWithinByteRange(byte_cols, start, end, column)) {
            return try allocator.dupe(u8, row_text[start..end]);
        }
        index = @max(end, start + 1);
    }
    return null;
}

fn nextUrlStart(text: []const u8, start: usize) ?usize {
    const schemes = [_][]const u8{ "https://", "http://", "file://" };
    var best: ?usize = null;
    for (schemes) |scheme| {
        if (std.mem.indexOfPos(u8, text, start, scheme)) |found| {
            if (best == null or found < best.?) best = found;
        }
    }
    return best;
}

fn isUrlBodyByte(byte: u8) bool {
    return switch (byte) {
        0...32, '"', '\'', '<', '>', '`' => false,
        else => true,
    };
}

fn trimUrlEnd(text: []const u8, start: usize, end: usize) usize {
    var result = end;
    while (result > start) {
        switch (text[result - 1]) {
            '.', ',', ';', ':', '!', '?', ')', ']', '}' => result -= 1,
            else => break,
        }
    }
    return result;
}

fn columnWithinByteRange(byte_cols: []const usize, start: usize, end: usize, column: usize) bool {
    if (start >= end or end > byte_cols.len) return false;
    for (byte_cols[start..end]) |byte_col| {
        if (byte_col == column) return true;
    }
    return false;
}

fn urlByteRangeColumns(byte_cols: []const usize, start: usize, end: usize) ?struct { start: usize, end: usize } {
    if (start >= end or end > byte_cols.len) return null;
    var min_col: usize = std.math.maxInt(usize);
    var max_col: usize = 0;
    for (byte_cols[start..end]) |byte_col| {
        min_col = @min(min_col, byte_col);
        max_col = @max(max_col, byte_col);
    }
    if (min_col == std.math.maxInt(usize)) return null;
    return .{ .start = min_col, .end = max_col };
}

fn beginSelectionCandidate(state: *app_state.AppState, x: f32, y: f32) bool {
    const target = paneAtPoint(x, y) orelse return false;
    const coord = cellAtPoint(state, target, x, y) orelse return false;
    hit_cache.dock_id = target.dock_id;
    var dock = state.currentProjectTerminalDockMutable(target.dock_id) orelse return false;
    dock.focusPane(target.pane_id);
    focusTerminal(state);
    selection_state = .{
        .active = false,
        .dragging = true,
        .moved = false,
        .dock_id = target.dock_id,
        .pane_id = target.pane_id,
        .start_x = x,
        .start_y = y,
        .anchor = coord,
        .focus = coord,
    };
    hit_cache.menu_open = false;
    if (dock.consumeWorkspaceChange()) state.markDirty();
    state.markDirty();
    return true;
}

fn selectionDragDistanceExceeded(x: f32, y: f32) bool {
    return selectionDragDistanceExceededFrom(selection_state.start_x, selection_state.start_y, x, y);
}

fn selectionDragDistanceExceededFrom(start_x: f32, start_y: f32, x: f32, y: f32) bool {
    const dx = x - start_x;
    const dy = y - start_y;
    return dx * dx + dy * dy >= 16.0;
}

fn updateSelectionFocus(state: *app_state.AppState, x: f32, y: f32) ?void {
    const target = PaneHitTarget{ .dock_id = selection_state.dock_id, .pane_id = selection_state.pane_id };
    selection_state.focus = cellAtPoint(state, target, x, y) orelse return null;
}

fn clearSelection() void {
    selection_state = .{};
}

fn cellAtPoint(state: *app_state.AppState, target: PaneHitTarget, x: f32, y: f32) ?TerminalCellCoord {
    const rect = paneRect(target.dock_id, target.pane_id) orelse return null;
    const dock = state.currentProjectTerminalDock(target.dock_id) orelse return null;
    const render_state = dock.renderStateForPane(target.pane_id) orelse return null;
    if (render_state.cols == 0 or render_state.rows == 0) return null;
    const cell_w = terminalRenderCellSize(terminal.CELL_PIXEL_WIDTH, dock.font_scale);
    const cell_h = terminalRenderCellSize(terminal.CELL_PIXEL_HEIGHT, dock.font_scale);
    const visible_rows = @min(@as(usize, render_state.rows), @as(usize, @intFromFloat(@ceil(rect.h / cell_h))));
    const row_start = visibleRowStart(render_state, visible_rows);
    const clamped_x = theme.clampf(x, rect.x, rect.x + rect.w - 1.0);
    const clamped_y = theme.clampf(y, rect.y, rect.y + rect.h - 1.0);
    const cell_x = theme.clampf(@floor((clamped_x - rect.x) / cell_w), 0.0, @as(f32, @floatFromInt(render_state.cols - 1)));
    const visual_y = theme.clampf(@floor((clamped_y - rect.y) / cell_h), 0.0, @as(f32, @floatFromInt(@max(visible_rows, 1) - 1)));
    return .{ .x = @intFromFloat(cell_x), .y = row_start + @as(usize, @intFromFloat(visual_y)) };
}

fn paneRect(dock_id: u32, pane_id: u32) ?palette.Rect {
    var i: usize = 0;
    while (i < hit_cache.pane_count) : (i += 1) {
        const hit = hit_cache.panes[i];
        if (hit.dock_id == dock_id and hit.pane_id == pane_id) return hit.rect;
    }
    return null;
}

fn selectionCoversCell(dock_id: u32, pane_id: u32, x: usize, y: usize) bool {
    if (!selection_state.active or selection_state.dock_id != dock_id or selection_state.pane_id != pane_id) return false;
    const start = selectionStart();
    const end = selectionEnd();
    if (y < start.y or y > end.y) return false;
    if (start.y == end.y) return x >= start.x and x <= end.x;
    if (y == start.y) return x >= start.x;
    if (y == end.y) return x <= end.x;
    return true;
}

fn selectionStart() TerminalCellCoord {
    return if (coordLessThan(selection_state.focus, selection_state.anchor)) selection_state.focus else selection_state.anchor;
}

fn selectionEnd() TerminalCellCoord {
    return if (coordLessThan(selection_state.focus, selection_state.anchor)) selection_state.anchor else selection_state.focus;
}

fn coordLessThan(a: TerminalCellCoord, b: TerminalCellCoord) bool {
    return a.y < b.y or (a.y == b.y and a.x < b.x);
}

fn copySelectionToClipboard(state: *app_state.AppState) bool {
    const dock = state.currentProjectTerminalDock(selection_state.dock_id) orelse return true;
    const render_state = dock.renderStateForPane(selection_state.pane_id) orelse return true;
    const text = selectedRenderStateText(state.allocator, render_state) catch |err| {
        app_state.log.warn("failed to build terminal selection clipboard text: {s}", .{@errorName(err)});
        return true;
    };
    defer state.allocator.free(text);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return true;

    const clipboard_text = state.allocator.dupeZ(u8, text) catch return true;
    defer state.allocator.free(clipboard_text);
    sdl.setClipboardText(clipboard_text) catch |err| {
        app_state.log.warn("failed to set terminal selection clipboard text: {s}", .{@errorName(err)});
    };
    return true;
}

fn selectedRenderStateText(allocator: std.mem.Allocator, render_state: *const ghostty_vt.RenderState) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const start = selectionStart();
    const end = selectionEnd();
    const row_data = render_state.row_data.slice();
    const row_cells = row_data.items(.cells);
    var y = start.y;
    while (y <= end.y and y < row_cells.len) : (y += 1) {
        const cells_slice = row_cells[y].slice();
        const raw_cells = cells_slice.items(.raw);
        if (raw_cells.len == 0) continue;
        const row_graphemes = cells_slice.items(.grapheme);
        const row_start = if (y == start.y) start.x else 0;
        const row_end = if (y == end.y) @min(end.x, raw_cells.len - 1) else raw_cells.len - 1;

        var row: std.ArrayList(u8) = .empty;
        defer row.deinit(allocator);

        var x = row_start;
        while (x <= row_end and x < raw_cells.len) : (x += 1) {
            const raw_cell = raw_cells[x];
            if (raw_cell.wide == .spacer_tail) continue;
            if (!raw_cell.hasText()) {
                try row.append(allocator, ' ');
                continue;
            }

            var text_buf: [128]u8 = undefined;
            const text = cellText(raw_cell, graphemesForCell(raw_cell, row_graphemes, x), &text_buf) orelse " ";
            try row.appendSlice(allocator, text);
            if (raw_cell.wide == .wide and x < row_end) try row.append(allocator, ' ');
        }

        try output.appendSlice(allocator, std.mem.trimEnd(u8, row.items, " \t"));
        if (y < end.y) try output.append(allocator, '\n');
    }

    return output.toOwnedSlice(allocator);
}

fn openContextMenu(kind: TerminalContextMenuKind, tab_index: usize, pane_id: u32, x: f32, y: f32) void {
    hit_cache.menu_open = true;
    hit_cache.menu_kind = kind;
    hit_cache.menu_dock_id = hit_cache.dock_id;
    hit_cache.menu_tab_index = tab_index;
    hit_cache.menu_pane_id = pane_id;
    hit_cache.menu_anchor = .{ .x = x, .y = y, .w = 1.0, .h = 1.0 };
}

pub fn resetHitCache() void {
    hit_cache.pane_count = 0;
    hit_cache.tab_count = 0;
    hit_cache.menu_count = 0;
}

fn appendPaneHit(pane_id: u32, rect: palette.Rect) void {
    if (hit_cache.pane_count >= MAX_PANE_HITS) return;
    hit_cache.panes[hit_cache.pane_count] = .{ .dock_id = hit_cache.dock_id, .pane_id = pane_id, .rect = rect };
    hit_cache.pane_count += 1;
}

fn appendTabHit(index: usize, rect: palette.Rect) void {
    if (hit_cache.tab_count >= MAX_TAB_HITS) return;
    hit_cache.tabs[hit_cache.tab_count] = .{ .dock_id = hit_cache.dock_id, .index = index, .rect = rect };
    hit_cache.tab_count += 1;
}

fn paneAtPoint(x: f32, y: f32) ?PaneHitTarget {
    var i: usize = 0;
    while (i < hit_cache.pane_count) : (i += 1) {
        const hit = hit_cache.panes[i];
        if (rectContains(hit.rect, x, y)) return .{ .dock_id = hit.dock_id, .pane_id = hit.pane_id, .rect = hit.rect };
    }
    return null;
}

fn tabAtPoint(x: f32, y: f32) ?TabHitTarget {
    var i: usize = 0;
    while (i < hit_cache.tab_count) : (i += 1) {
        const hit = hit_cache.tabs[i];
        if (rectContains(hit.rect, x, y)) return .{ .dock_id = hit.dock_id, .index = hit.index };
    }
    return null;
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h;
}

fn terminalCopyShortcut(event: *const sdl.KeyboardEvent) bool {
    if (!event.down or event.repeat) return false;
    if (event.scancode != .c and event.key != .c) return false;
    if (modifierPressed(event.mod, sdl.Keymod.alt)) return false;
    const ctrl = modifierPressed(event.mod, sdl.Keymod.ctrl);
    const gui = modifierPressed(event.mod, sdl.Keymod.gui);
    // Ctrl+C, Ctrl+Shift+C, Super+C, Super+Shift+C. Shift is optional so the
    // copy-if-selection behavior reaches handlePaletteKeyDown before the bare
    // Ctrl+C falls through to the terminal as SIGINT.
    return ctrl != gui; // exactly one of ctrl/gui; reject ctrl+gui chord
}

fn modifierPressed(state: sdl.Keymod, mask: u16) bool {
    const state_bits = @as(*const u16, @ptrCast(&state)).*;
    return (state_bits & mask) != 0;
}

fn drawCursor(state: *app_state.AppState, render_state: *const ghostty_vt.RenderState, rect: palette.Rect, clip: palette.Rect) void {
    const color = rgbPaletteColor(render_state.colors.cursor orelse render_state.colors.foreground, 0.95);
    switch (render_state.cursor.visual_style) {
        .block => queueClippedRect(state, rect, color, clip),
        .block_hollow => queueBorder(state, intersectRect(rect, clip) orelse return, color, 0.0, theme.scaledUi(1.5)),
        .bar => queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = @max(rect.w * 0.12, theme.scaledUi(2.0)), .h = rect.h }, color, clip),
        .underline => queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h - @max(rect.h * 0.1, theme.scaledUi(2.0)), .w = rect.w, .h = @max(rect.h * 0.1, theme.scaledUi(2.0)) }, color, clip),
    }
}

fn drawTerminalLinkUnderline(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, clip: palette.Rect) void {
    const line_h = @max(theme.scaledUi(1.0), 1.0);
    queueClippedRect(state, .{
        .x = rect.x,
        .y = rect.y + rect.h - line_h - @max(theme.scaledUi(1.0), 1.0),
        .w = rect.w,
        .h = line_h,
    }, color, clip);
}

fn rawCellNeedsFill(cell: ghostty_vt.Cell) bool {
    return switch (cell.content_tag) {
        .bg_color_palette, .bg_color_rgb => true,
        else => false,
    };
}

fn cellWidthCells(cell: ghostty_vt.Cell) u2 {
    return switch (cell.wide) {
        .wide => 2,
        else => 1,
    };
}

fn styleForCell(cell: ghostty_vt.Cell, styles: []const ghostty_vt.Style, index: usize) ghostty_vt.Style {
    return switch (cell.content_tag) {
        .bg_color_palette => .{ .bg_color = .{ .palette = @intCast(cell.content.color_palette) } },
        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
            .r = cell.content.color_rgb.r,
            .g = cell.content.color_rgb.g,
            .b = cell.content.color_rgb.b,
        } } },
        else => if (cell.hasStyling()) styles[index] else .{},
    };
}

fn graphemesForCell(cell: ghostty_vt.Cell, graphemes: []const []const u21, index: usize) []const u21 {
    return if (cell.hasGrapheme()) graphemes[index] else &.{};
}

fn cellText(raw_cell: ghostty_vt.Cell, graphemes: []const u21, buffer: []u8) ?[]const u8 {
    if (!raw_cell.hasText()) return null;
    var index: usize = 0;
    index += std.unicode.utf8Encode(raw_cell.codepoint(), buffer[index..]) catch return null;
    if (raw_cell.hasGrapheme()) {
        for (graphemes) |cp| {
            if (index >= buffer.len) break;
            index += std.unicode.utf8Encode(cp, buffer[index..]) catch break;
        }
    }
    return buffer[0..index];
}

fn glyphNeedsRelaxedClip(cp: u21) bool {
    return switch (cp) {
        // Symbol blocks served by the proportional fallback faces (Noto Sans
        // Symbols / Symbols 2 / Emoji). Their glyphs are designed at
        // proportional metrics — applying a mono-cell scissor crops the top
        // and bottom and produces visibly cut-off renders compared to
        // Ghostty. Granting them the relaxed clip lets each glyph use its
        // natural extent. Bleed into adjacent cells is bounded by the glyph's
        // own design width; in practice TUIs follow these symbols with a
        // space, so any overflow lands harmlessly.
        0x2100...0x214F, // Letterlike Symbols (ℹ etc.)
        0x2300...0x23FF, // Misc Technical (⌘⌥⌫⏵⎿ etc.)
        0x2600...0x26FF, // Misc Symbols (☀☁⚠⚡⚙⚓☃⛅⚑)
        0x2700...0x27BF, // Dingbats (✓✗✨➜➤➔ + numbered ❶➀)
        0x2B00...0x2BFF, // Misc Symbols and Arrows (⮕⭐⬆)
        0xe0a0...0xe0af,
        0xe5fa...0xe7ff,
        0xf000...0xf8ff,
        0xf0000...0xf20ff,
        => true,
        else => false,
    };
}

/// Codepoints whose glyph likely lives in a *proportional* fallback face
/// (Noto Sans Symbols 2, Noto Emoji). Their baseline sits lower in the em-box
/// than mono glyphs at the same font_size, so without a y-lift they appear to
/// drop below adjacent mono text. Excluded: Nerd Font private-use blocks
/// (mono-style, align natively) AND the numbered-dingbat sub-range
/// U+2776..U+2793 served by *Noto Sans Symbols* (the original, not "2"),
/// whose metrics are closer to mono — applying the lift made them sit too
/// high. Other dingbats in U+2700..U+27BF still need the lift since they
/// come from Symbols 2 or Emoji.
fn glyphBaselineLiftFraction(cp: u21) f32 {
    return switch (cp) {
        // Numbered dingbats render from Noto Sans Symbols (the original).
        // Empirically: 14% too high, 12% still slightly low.
        0x2776...0x2793 => 0.13,
        0x2100...0x214F,
        0x2300...0x23FF,
        0x2600...0x26FF,
        0x2700...0x2775,
        0x2794...0x27BF,
        0x2B00...0x2BFF,
        0x1F300...0x1FAFF, // 4-byte emoji blocks
        => 0.14,
        else => 0.0,
    };
}

fn foregroundAlpha(style: ghostty_vt.Style) f32 {
    return if (style.flags.faint) 0.55 else 1.0;
}

/// When `VERDE_TERMINAL_DISABLE_DRAW_CACHE=1` is set in the host environment,
/// `renderViewport` skips the per-pane draw-command cache and rebuilds every
/// frame. Pure diagnostic — used to bisect rendering bugs between cache
/// invalidation gaps (resize, reflow, font scale) and upstream terminal-model
/// problems.
fn drawCacheBypassEnabled() bool {
    return std.c.getenv("VERDE_TERMINAL_DISABLE_DRAW_CACHE") != null;
}

fn rgbEql(a: ghostty_vt.color.RGB, b: ghostty_vt.color.RGB) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

fn rectEql(a: palette.Rect, b: palette.Rect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

fn blendRgb(a: ghostty_vt.color.RGB, b: ghostty_vt.color.RGB, amount: f32) ghostty_vt.color.RGB {
    const t = theme.clampf(amount, 0.0, 1.0);
    return .{
        .r = blendChannel(a.r, b.r, t),
        .g = blendChannel(a.g, b.g, t),
        .b = blendChannel(a.b, b.b, t),
    };
}

fn blendChannel(a: u8, b: u8, t: f32) u8 {
    const lhs = @as(f32, @floatFromInt(a));
    const rhs = @as(f32, @floatFromInt(b));
    return @intFromFloat(lhs + (rhs - lhs) * t);
}

fn terminalCellRect(rect: palette.Rect, cell_w: f32, cell_h: f32, x: usize, y: usize, span: f32) palette.Rect {
    const x0 = @round(rect.x + @as(f32, @floatFromInt(x)) * cell_w);
    const x1 = @round(rect.x + (@as(f32, @floatFromInt(x)) + span) * cell_w);
    const y0 = @round(rect.y + @as(f32, @floatFromInt(y)) * cell_h);
    const y1 = @round(rect.y + (@as(f32, @floatFromInt(y)) + 1.0) * cell_h);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(x1 - x0, 1.0),
        .h = @max(y1 - y0, 1.0),
    };
}

fn terminalTextRect(rect: palette.Rect, y_offset: f32, glyph_kind: TerminalGlyphKind) palette.Rect {
    return switch (glyph_kind) {
        .text => .{ .x = rect.x, .y = rect.y + y_offset, .w = rect.w, .h = rect.h },
        .icon => .{
            .x = rect.x - rect.w * 0.04,
            .y = rect.y + y_offset - rect.h * 0.04,
            .w = rect.w * 1.10,
            .h = rect.h * 1.08,
        },
        .powerline => .{
            .x = rect.x - rect.w * 0.16,
            .y = rect.y + y_offset - rect.h * 0.18,
            .w = rect.w * 1.42,
            .h = rect.h * 1.28,
        },
    };
}

fn terminalRenderCellSize(base: u32, font_scale: f32) f32 {
    return @max(@round(@as(f32, @floatFromInt(base)) * font_scale), 1.0);
}

/// Breathing room on the left/right edges of the dock so terminal output
/// doesn't sit flush against the pane border. Applied once at the dock
/// level — splits divide the inset region without adding more padding
/// between sibling panes.
fn terminalPaneHorizontalInset() f32 {
    return theme.scaledUi(6.0);
}

fn intersectRect(a: palette.Rect, b: palette.Rect) ?palette.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    if (right <= x or bottom <= y) return null;
    return .{
        .x = x,
        .y = y,
        .w = right - x,
        .h = bottom - y,
    };
}

fn terminalLayoutLogEnabled() bool {
    if (terminal_layout_log_enabled) |enabled| return enabled;
    const enabled = if (std.c.getenv("VERDE_TERMINAL_LAYOUT_LOG")) |value_ptr| blk: {
        const value = std.mem.span(value_ptr);
        break :blk value.len > 0 and !std.mem.eql(u8, value, "0");
    } else false;
    terminal_layout_log_enabled = enabled;
    return enabled;
}

fn logTerminalViewport(
    comptime event: []const u8,
    dock_id: u32,
    pane_id: u32,
    rect: palette.Rect,
    render_state: *const ghostty_vt.RenderState,
    font_scale: f32,
) void {
    if (!terminalLayoutLogEnabled()) return;
    const cell_w = terminalRenderCellSize(terminal.CELL_PIXEL_WIDTH, font_scale);
    const cell_h = terminalRenderCellSize(terminal.CELL_PIXEL_HEIGHT, font_scale);
    const grid_w = @min(cell_w * @as(f32, @floatFromInt(render_state.cols)), rect.w);
    const grid_h = @min(cell_h * @as(f32, @floatFromInt(render_state.rows)), rect.h);
    log.info(
        "{s} dock={d} pane={d} rect=({d:.1},{d:.1} {d:.1}x{d:.1}) grid={d:.1}x{d:.1} cells={d}x{d} cell={d:.1}x{d:.1} font_scale={d:.3} dirty={s}",
        .{
            event,
            dock_id,
            pane_id,
            rect.x,
            rect.y,
            rect.w,
            rect.h,
            grid_w,
            grid_h,
            render_state.cols,
            render_state.rows,
            cell_w,
            cell_h,
            font_scale,
            @tagName(render_state.dirty),
        },
    );
}

fn terminalTextFontSize(font_size: f32, glyph_kind: TerminalGlyphKind) f32 {
    return switch (glyph_kind) {
        .text => font_size,
        .icon => font_size * 0.92,
        .powerline => font_size * 1.18,
    };
}

fn terminalFontSizeForCell(cell_w: f32, cell_h: f32) f32 {
    const by_height = cell_h * 0.95;
    const by_width = cell_w * 1.9;
    return theme.clampf(@min(by_height, by_width), 8.0, cell_h * 1.05);
}

fn stableText(state: *app_state.AppState, value: []const u8) []const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch "";
}

fn queueRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    if (active_capture) |cache| {
        cache.append(state.allocator, .{ .rect = .{ .rect = rect, .color = color } });
    }
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch {};
}

fn queueClippedRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, clip: ?palette.Rect) void {
    if (clip) |clip_rect| {
        if (active_capture) |cache| {
            cache.append(state.allocator, .{ .rect = .{ .rect = rect, .color = color, .clip = clip_rect } });
        }
        state.palette_overlay_batch.rectClipped(state.allocator, rect, color, clip_rect) catch {};
    } else {
        queueRect(state, rect, color);
    }
}

fn queueTriangle(state: *app_state.AppState, p0: palette.draw.Vec2, p1: palette.draw.Vec2, p2: palette.draw.Vec2, color: palette.Color, clip: ?palette.Rect) void {
    if (active_capture) |cache| {
        cache.append(state.allocator, .{ .triangle = .{ .p0 = p0, .p1 = p1, .p2 = p2, .color = color, .clip = clip } });
    }
    if (clip) |clip_rect| {
        state.palette_overlay_batch.triangleClipped(state.allocator, p0, p1, p2, color, clip_rect) catch {};
    } else {
        state.palette_overlay_batch.triangle(state.allocator, p0, p1, p2, color) catch {};
    }
}

fn queueRounded(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch {};
}

fn queueBorder(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    if (active_capture) |cache| {
        cache.append(state.allocator, .{ .border = .{ .rect = rect, .color = color, .radius = radius, .width = width } });
    }
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch {};
}

fn queueText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.text(state.allocator, rect, stableText(state, value), color, font_size, clip) catch {};
}

fn queueTerminalText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect, glyph_kind: TerminalGlyphKind) void {
    if (active_capture) |cache| {
        cache.append(state.allocator, .{
            .terminal_text = .{
                .rect = rect,
                .value = cache.stableText(value),
                .color = color,
                .font_size = font_size,
                .clip = clip,
                .glyph_kind = glyph_kind,
            },
        });
    }
    const font_role: ?palette.FontRole = switch (glyph_kind) {
        .text => .mono,
        .icon, .powerline => .icon,
    };
    if (glyph_kind == .text) {
        state.palette_overlay_batch.fixedRoleText(
            state.allocator,
            rect,
            stableText(state, value),
            color,
            font_size,
            font_role,
            null,
            clip,
            .{},
            rect.w,
            rect.h,
            false,
        ) catch {};
        return;
    }
    state.palette_overlay_batch.roleText(state.allocator, rect, stableText(state, value), color, font_size, font_role, null, clip) catch {};
}

fn queueTerminalImage(state: *app_state.AppState, rect: palette.Rect, texture_id: u32, uv: palette.Rect, clip: ?palette.Rect) void {
    state.palette_overlay_batch.image(
        state.allocator,
        rect,
        palette.TextureId.init(texture_id),
        uv,
        palette.Color.white,
        clip,
    ) catch {};
}

fn queuePowerlineGlyph(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) void {
    // Overdraw the *base* (wide) edge by a fraction of a pixel to hide the AA
    // seam against the adjacent same-colored segment. The apex stays exactly on
    // the cell boundary: extending it would poke the triangle's color into the
    // next segment, which reads as the segments "bleeding" into each other.
    const bleed = theme.scaledUi(0.2);
    const x0 = rect.x;
    const x1 = rect.x + rect.w;
    const top = rect.y;
    const bottom = rect.y + rect.h;
    const mid_y = rect.y + rect.h * 0.5;
    switch (cp) {
        0xe0b0, 0xe0b4, 0xe0b8, 0xe0bc, 0xe0c0, 0xe0c4 => queueTriangle(
            state,
            .{ .x = x0 - bleed, .y = top },
            .{ .x = x0 - bleed, .y = bottom },
            .{ .x = x1, .y = mid_y },
            color,
            clip,
        ),
        0xe0b2, 0xe0b6, 0xe0ba, 0xe0be, 0xe0c2, 0xe0c6 => queueTriangle(
            state,
            .{ .x = x1 + bleed, .y = top },
            .{ .x = x1 + bleed, .y = bottom },
            .{ .x = x0, .y = mid_y },
            color,
            clip,
        ),
        else => queueTerminalText(state, terminalTextRect(rect, 0.0, .icon), "?", color, rect.h, clip, .icon),
    }
}

fn queueTerminalCellGeometry(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    if (queueBlockElement(state, rect, cp, color, clip)) return true;
    if (queueBoxDrawing(state, rect, cp, color, clip)) return true;
    if (queueBraillePattern(state, rect, cp, color, clip)) return true;
    if (queueMiscSymbol(state, rect, cp, color, clip)) return true;
    return false;
}

fn queueBlockElement(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    const eighth = rect.h / 8.0;
    const eighth_w = rect.w / 8.0;
    switch (cp) {
        0x2580 => queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h * 0.5 }, color, clip),
        0x2581...0x2587 => {
            const rows = @as(f32, @floatFromInt(cp - 0x2580));
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h - eighth * rows, .w = rect.w, .h = eighth * rows }, color, clip);
        },
        0x2588 => queueClippedRect(state, rect, color, clip),
        0x2589...0x258f => {
            const cols = @as(f32, @floatFromInt(8 - (cp - 0x2588)));
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = eighth_w * cols, .h = rect.h }, color, clip);
        },
        0x2590 => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y, .w = rect.w * 0.5, .h = rect.h }, color, clip),
        0x2594 => queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @max(eighth, 1.0) }, color, clip),
        0x2595 => queueClippedRect(state, .{ .x = rect.x + rect.w - @max(eighth_w, 1.0), .y = rect.y, .w = @max(eighth_w, 1.0), .h = rect.h }, color, clip),
        0x2596 => queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip),
        0x2597 => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip),
        0x2598 => queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip),
        0x2599 => {
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w * 0.5, .h = rect.h }, color, clip);
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259a => {
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259b => {
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259c => {
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259d => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip),
        0x259e => {
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        0x259f => {
            queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = rect.y, .w = rect.w * 0.5, .h = rect.h }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = rect.y + rect.h * 0.5, .w = rect.w * 0.5, .h = rect.h * 0.5 }, color, clip);
        },
        else => return false,
    }
    return true;
}

fn queueBoxDrawing(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    if (cp < 0x2500 or cp > 0x257f) return false;
    const stroke = @max(@round(@min(rect.w, rect.h) * 0.105), 1.0);
    const cx = rect.x + rect.w * 0.5 - stroke * 0.5;
    const cy = rect.y + rect.h * 0.5 - stroke * 0.5;
    switch (cp) {
        0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x254c, 0x254d => queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w, .h = stroke }, color, clip),
        0x2502, 0x2503, 0x2506, 0x2507, 0x250a, 0x250b, 0x254e, 0x254f => queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h }, color, clip),
        0x250c...0x250f, 0x256d => {
            queueClippedRect(state, .{ .x = cx, .y = cy, .w = stroke, .h = rect.h * 0.5 + stroke * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = cx, .y = cy, .w = rect.w * 0.5 + stroke * 0.5, .h = stroke }, color, clip);
        },
        0x2510...0x2513, 0x256e => {
            queueClippedRect(state, .{ .x = cx, .y = cy, .w = stroke, .h = rect.h * 0.5 + stroke * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w * 0.5 + stroke * 0.5, .h = stroke }, color, clip);
        },
        0x2514...0x2517, 0x2570 => {
            queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h * 0.5 + stroke * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = cx, .y = cy, .w = rect.w * 0.5 + stroke * 0.5, .h = stroke }, color, clip);
        },
        0x2518...0x251b, 0x256f => {
            queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h * 0.5 + stroke * 0.5 }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w * 0.5 + stroke * 0.5, .h = stroke }, color, clip);
        },
        0x251c...0x254b => {
            queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h }, color, clip);
            queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w, .h = stroke }, color, clip);
        },
        0x2571 => queueDiagonalGlyph(state, rect, color, clip, true),
        0x2572 => queueDiagonalGlyph(state, rect, color, clip, false),
        0x2573 => {
            queueDiagonalGlyph(state, rect, color, clip, true);
            queueDiagonalGlyph(state, rect, color, clip, false);
        },
        0x2574 => queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w * 0.5, .h = stroke }, color, clip),
        0x2575 => queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h * 0.5 }, color, clip),
        0x2576 => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = cy, .w = rect.w * 0.5, .h = stroke }, color, clip),
        0x2577 => queueClippedRect(state, .{ .x = cx, .y = rect.y + rect.h * 0.5, .w = stroke, .h = rect.h * 0.5 }, color, clip),
        0x2578 => queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w * 0.5, .h = stroke * 1.4 }, color, clip),
        0x2579 => queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke * 1.4, .h = rect.h * 0.5 }, color, clip),
        0x257a => queueClippedRect(state, .{ .x = rect.x + rect.w * 0.5, .y = cy, .w = rect.w * 0.5, .h = stroke * 1.4 }, color, clip),
        0x257b => queueClippedRect(state, .{ .x = cx, .y = rect.y + rect.h * 0.5, .w = stroke * 1.4, .h = rect.h * 0.5 }, color, clip),
        0x257c...0x257f => {
            queueClippedRect(state, .{ .x = rect.x, .y = cy, .w = rect.w, .h = stroke }, color, clip);
            queueClippedRect(state, .{ .x = cx, .y = rect.y, .w = stroke, .h = rect.h }, color, clip);
        },
        else => return false,
    }
    return true;
}

fn queueDiagonalGlyph(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, clip: ?palette.Rect, rising: bool) void {
    const steps: usize = 8;
    const step_w = rect.w / @as(f32, @floatFromInt(steps));
    const step_h = rect.h / @as(f32, @floatFromInt(steps));
    for (0..steps) |i| {
        const fi = @as(f32, @floatFromInt(i));
        const y_index = if (rising) steps - 1 - i else i;
        queueClippedRect(state, .{
            .x = rect.x + fi * step_w,
            .y = rect.y + @as(f32, @floatFromInt(y_index)) * step_h,
            .w = @max(step_w, 1.0),
            .h = @max(step_h, 1.0),
        }, color, clip);
    }
}

fn queueBraillePattern(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    if (cp < 0x2800 or cp > 0x28ff) return false;
    const bits = cp - 0x2800;
    if (bits == 0) return true;
    const dot_w = @max(@floor(rect.w / 3.0), 1.0);
    const dot_h = @max(@floor(rect.h / 5.0), 1.0);
    const x0 = rect.x + rect.w * 0.18;
    const x1 = rect.x + rect.w * 0.62;
    const ys = [_]f32{
        rect.y + rect.h * 0.08,
        rect.y + rect.h * 0.32,
        rect.y + rect.h * 0.56,
        rect.y + rect.h * 0.80,
    };
    const dots = [_]struct { bit: u8, x: f32, y: f32 }{
        .{ .bit = 0, .x = x0, .y = ys[0] },
        .{ .bit = 1, .x = x0, .y = ys[1] },
        .{ .bit = 2, .x = x0, .y = ys[2] },
        .{ .bit = 6, .x = x0, .y = ys[3] },
        .{ .bit = 3, .x = x1, .y = ys[0] },
        .{ .bit = 4, .x = x1, .y = ys[1] },
        .{ .bit = 5, .x = x1, .y = ys[2] },
        .{ .bit = 7, .x = x1, .y = ys[3] },
    };
    for (dots) |dot| {
        if ((bits & (@as(u21, 1) << @intCast(dot.bit))) == 0) continue;
        queueClippedRect(state, .{ .x = dot.x, .y = dot.y, .w = dot_w, .h = dot_h }, color, clip);
    }
    return true;
}

fn queueMiscSymbol(state: *app_state.AppState, rect: palette.Rect, cp: u21, color: palette.Color, clip: ?palette.Rect) bool {
    const inset_x = rect.w * 0.12;
    const inset_y = rect.h * 0.20;
    const left = rect.x + inset_x;
    const right = rect.x + rect.w - inset_x;
    const top = rect.y + inset_y;
    const bottom = rect.y + rect.h - inset_y;
    const mid_y = rect.y + rect.h * 0.5;
    switch (cp) {
        0x23f5 => queueTriangle(
            state,
            .{ .x = left, .y = top },
            .{ .x = left, .y = bottom },
            .{ .x = right, .y = mid_y },
            color,
            clip,
        ),
        0x23f4 => queueTriangle(
            state,
            .{ .x = right, .y = top },
            .{ .x = right, .y = bottom },
            .{ .x = left, .y = mid_y },
            color,
            clip,
        ),
        // ⎿ — the corner connector TUIs like Claude Code draw under a tool/tree
        // node. Box-drawing (0x2500..0x257f) doesn't cover it, so without this it
        // falls back to the font and renders as tofu. Draw a bottom-left elbow:
        // a full-height vertical that joins the line above, plus a short foot.
        0x23bf => {
            const stroke = @max(@round(@min(rect.w, rect.h) * 0.105), 1.0);
            const lx = rect.x + rect.w * 0.5 - stroke * 0.5;
            queueClippedRect(state, .{ .x = lx, .y = rect.y, .w = stroke, .h = rect.h }, color, clip);
            queueClippedRect(state, .{ .x = lx, .y = rect.y + rect.h - stroke, .w = rect.w * 0.5 + stroke * 0.5, .h = stroke }, color, clip);
        },
        else => return false,
    }
    return true;
}

fn paletteColor(color: [4]f32) palette.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

fn rgbPaletteColor(rgb: ghostty_vt.color.RGB, alpha: f32) palette.Color {
    return .{
        .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
        .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
        .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
        .a = alpha,
    };
}

fn terminalGlyphKind(cp: u21) TerminalGlyphKind {
    // Only the powerline codepoints whose geometry `queuePowerlineGlyph`
    // actually draws (filled right- and left-pointing triangles, plus their
    // half-circle / hexagonal / flame stylistic variants — same triangle
    // approximation for all). Everything else in the broader powerline range
    // (E0B1 thin right, E0B3 thin left, E0B5/E0B7 lower / upper triangles,
    // etc.) falls through to .text so it renders via the user's Nerd Font
    // which has the correct glyph shapes — instead of hitting the `else =>
    // "?"` placeholder in queuePowerlineGlyph that rendered as tofu.
    return switch (cp) {
        0xe0b0,
        0xe0b2,
        0xe0b4,
        0xe0b6,
        0xe0b8,
        0xe0ba,
        0xe0bc,
        0xe0be,
        0xe0c0,
        0xe0c2,
        0xe0c4,
        0xe0c6,
        => .powerline,
        else => .text,
    };
}
