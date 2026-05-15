//! Workspace pane composition.
//!
//! This starts as a compatibility wrapper around the existing chat workspace.
//! The pane model lives in state so later slices can add terminal leaves without
//! changing the root UI entry point again.

const palette = @import("palette");

const runtime = @import("runtime.zig");
const chat_panel = @import("chat_panel.zig");
const colors = @import("colors.zig");
const terminal_panel = @import("terminal_panel.zig");
const theme = @import("theme.zig");

const MAX_WORKSPACE_PANE_HITS = 32;
const WorkspacePaneAction = enum {
    focus,
    maximize,
    minimize,
    restore,
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

pub fn renderAt(state: *runtime.AppState, rect: palette.Rect) void {
    state.ensureCurrentProjectWorkspace();
    state.debug_workspace_visible_pane_count = state.currentProjectWorkspaceVisiblePaneCount();
    hit_cache.count = 0;
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
        return;
    }
    if (state.currentProjectWorkspaceRoot()) |root| {
        renderNode(state, root, workspace_rect);
        renderRestoreStrip(state, .{ .x = rect.x, .y = rect.y + workspace_rect.h, .w = rect.w, .h = restore_h }, minimized_count);
        return;
    }

    chat_panel.renderWorkspaceAt(state, workspace_rect);
    renderRestoreStrip(state, .{ .x = rect.x, .y = rect.y + workspace_rect.h, .w = rect.w, .h = restore_h }, minimized_count);
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool) bool {
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
            .focus => _ = state.focusCurrentProjectWorkspacePane(hit.pane_id),
            .maximize => _ = state.toggleCurrentProjectWorkspacePaneMaximized(hit.pane_id),
            .minimize => _ = state.minimizeCurrentProjectWorkspacePane(hit.pane_id),
            .restore => _ = state.restoreCurrentProjectWorkspacePane(hit.pane_id),
            .split_chat_vertical => _ = state.splitCurrentProjectWorkspacePaneWithChatAxis(hit.pane_id, .vertical),
            .split_chat_horizontal => _ = state.splitCurrentProjectWorkspacePaneWithChatAxis(hit.pane_id, .horizontal),
            .split_terminal_vertical => _ = state.splitCurrentProjectWorkspacePaneWithTerminalAxis(hit.pane_id, .vertical),
            .split_terminal_horizontal => _ = state.splitCurrentProjectWorkspacePaneWithTerminalAxis(hit.pane_id, .horizontal),
            .close => _ = state.closeCurrentProjectWorkspacePane(hit.pane_id),
            .resize_split => {
                resize_drag = hit;
                updateResizeDrag(state, hit, x, y);
            },
        }
        return true;
    }
    return false;
}

pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, y: f32) bool {
    const hit = resize_drag orelse return false;
    updateResizeDrag(state, hit, x, y);
    return true;
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

fn renderLeaf(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, rect: palette.Rect) void {
    const kind = state.workspacePaneKindById(pane_id) orelse return;
    const chrome_h = theme.scaledUi(28.0);
    const header = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = chrome_h };
    const body = palette.Rect{ .x = rect.x, .y = rect.y + chrome_h, .w = rect.w, .h = @max(rect.h - chrome_h, 1.0) };
    renderPaneChrome(state, pane_id, kind, header);
    switch (kind) {
        .chat => chat_panel.renderWorkspaceAtForPane(state, body, pane_id),
        .terminal => {
            const dock_id = state.workspaceTerminalDockIdByPane(pane_id) orelse 0;
            terminal_panel.renderDockAtForDock(state, body, dock_id);
        },
    }
    if (state.isCurrentProjectWorkspacePaneFocused(pane_id)) {
        queueBorder(state, rect, paletteColor(theme.COLOR_SECONDARY_GREEN), 0.0, theme.scaledUi(1.0));
    }
}

fn renderPaneChrome(state: *runtime.AppState, pane_id: runtime.WorkspacePaneId, kind: runtime.WorkspacePaneKind, rect: palette.Rect) void {
    const focused = state.isCurrentProjectWorkspacePaneFocused(pane_id);
    const bg = if (focused) colors.rgba(20, 28, 30, 255) else colors.rgba(18, 20, 24, 255);
    queueRect(state, rect, paletteColor(bg));
    queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), 0.0, theme.scaledUi(1.0));
    appendHit(.{ .pane_id = pane_id, .action = .focus, .rect = rect });

    const label = switch (kind) {
        .chat => "Chat",
        .terminal => "Terminal",
    };
    const label_w = switch (kind) {
        .chat => theme.scaledUi(40.0),
        .terminal => theme.scaledUi(70.0),
    };
    queueText(state, .{
        .x = rect.x + theme.scaledUi(10.0),
        .y = rect.y + theme.scaledUi(6.0),
        .w = label_w,
        .h = theme.scaledUi(16.0),
    }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), rect);

    if (!focused) return;

    const button_h = theme.scaledUi(20.0);
    const gap = theme.scaledUi(5.0);
    const y = rect.y + @max((rect.h - button_h) * 0.5, 0.0);
    var left_x = rect.x + theme.scaledUi(10.0) + label_w + theme.scaledUi(10.0);
    const right_controls_w = theme.scaledUi(136.0);
    const split_limit_x = rect.x + rect.w - right_controls_w - theme.scaledUi(10.0);
    if (rect.w >= theme.scaledUi(520.0)) {
        left_x = renderChromeButton(state, pane_id, .split_chat_vertical, left_x, y, theme.scaledUi(58.0), button_h, "Chat |", rect) + gap;
        left_x = renderChromeButton(state, pane_id, .split_chat_horizontal, left_x, y, theme.scaledUi(58.0), button_h, "Chat -", rect) + gap;
        left_x += theme.scaledUi(4.0);
        if (left_x + theme.scaledUi(128.0) < split_limit_x) {
            left_x = renderChromeButton(state, pane_id, .split_terminal_vertical, left_x, y, theme.scaledUi(60.0), button_h, "Term |", rect) + gap;
            _ = renderChromeButton(state, pane_id, .split_terminal_horizontal, left_x, y, theme.scaledUi(60.0), button_h, "Term -", rect);
        }
    } else if (rect.w >= theme.scaledUi(340.0)) {
        left_x = renderChromeButton(state, pane_id, .split_chat_vertical, left_x, y, theme.scaledUi(34.0), button_h, "C|", rect) + gap;
        left_x = renderChromeButton(state, pane_id, .split_chat_horizontal, left_x, y, theme.scaledUi(34.0), button_h, "C-", rect) + gap;
        left_x = renderChromeButton(state, pane_id, .split_terminal_vertical, left_x, y, theme.scaledUi(34.0), button_h, "T|", rect) + gap;
        _ = renderChromeButton(state, pane_id, .split_terminal_horizontal, left_x, y, theme.scaledUi(34.0), button_h, "T-", rect);
    }

    var right_x = rect.x + rect.w - theme.scaledUi(8.0) - theme.scaledUi(28.0);
    right_x = renderChromeButton(state, pane_id, .close, right_x, y, theme.scaledUi(28.0), button_h, "x", rect) - gap - theme.scaledUi(36.0);
    right_x = renderChromeButton(state, pane_id, .minimize, right_x, y, theme.scaledUi(36.0), button_h, "Min", rect) - gap - theme.scaledUi(36.0);
    _ = renderChromeButton(state, pane_id, .maximize, right_x, y, theme.scaledUi(36.0), button_h, if (state.isCurrentProjectWorkspacePaneMaximized(pane_id)) "Fit" else "Max", rect);
}

fn renderChromeButton(
    state: *runtime.AppState,
    pane_id: runtime.WorkspacePaneId,
    action: WorkspacePaneAction,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    label: []const u8,
    clip: palette.Rect,
) f32 {
    const rect = palette.Rect{ .x = x, .y = y, .w = w, .h = h };
    renderIconButton(state, rect, label, clip);
    appendHit(.{ .pane_id = pane_id, .action = action, .rect = rect });
    return x + w;
}

fn renderRestoreStrip(state: *runtime.AppState, rect: palette.Rect, minimized_count: usize) void {
    if (minimized_count == 0 or rect.h <= 0.0) return;
    queueRect(state, rect, paletteColor(colors.rgba(14, 16, 19, 255)));
    queueBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), 0.0, theme.scaledUi(1.0));

    var x = rect.x + theme.scaledUi(8.0);
    const y = rect.y + theme.scaledUi(6.0);
    const button_h = @max(rect.h - theme.scaledUi(12.0), theme.scaledUi(18.0));
    var i: usize = 0;
    while (i < minimized_count) : (i += 1) {
        const pane = state.currentProjectWorkspaceMinimizedPaneAt(i) orelse continue;
        const label = switch (pane.kind) {
            .chat => "Restore Chat",
            .terminal => "Restore Terminal",
        };
        const button_w = switch (pane.kind) {
            .chat => theme.scaledUi(104.0),
            .terminal => theme.scaledUi(128.0),
        };
        const button_rect = palette.Rect{ .x = x, .y = y, .w = button_w, .h = button_h };
        renderRestoreButton(state, button_rect, label, rect);
        appendHit(.{ .pane_id = pane.id, .action = .restore, .rect = button_rect });
        x += button_w + theme.scaledUi(8.0);
        if (x > rect.x + rect.w - theme.scaledUi(24.0)) break;
    }
}

fn renderRestoreButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, clip: palette.Rect) void {
    queueRounded(state, rect, paletteColor(colors.rgba(31, 36, 42, 255)), theme.scaledUi(5.0));
    queueBorder(state, rect, paletteColor(colors.rgba(66, 74, 84, 255)), theme.scaledUi(5.0), theme.scaledUi(1.0));
    queueText(state, .{ .x = rect.x + theme.scaledUi(9.0), .y = rect.y + theme.scaledUi(4.0), .w = @max(rect.w - theme.scaledUi(18.0), 1.0), .h = rect.h }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), clip);
}

fn renderIconButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, clip: palette.Rect) void {
    queueRounded(state, rect, paletteColor(colors.rgba(28, 32, 38, 255)), theme.scaledUi(5.0));
    queueBorder(state, rect, paletteColor(colors.rgba(62, 70, 78, 255)), theme.scaledUi(5.0), theme.scaledUi(1.0));
    queueText(state, .{ .x = rect.x + theme.scaledUi(4.0), .y = rect.y + theme.scaledUi(3.0), .w = @max(rect.w - theme.scaledUi(8.0), 1.0), .h = rect.h }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(11.0), clip);
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
