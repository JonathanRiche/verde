//! Workspace tabs: the user-facing unit of a workspace.
//!
//! A tab is one scrolling item in the workspace strip — either a lone pane or
//! a split tile group whose panes share `WorkspacePane.scroll_group_id`. The
//! tab id is that group id, which is the id of the pane that founded the tile,
//! so it stays stable while panes are added to or closed inside the tile.
//! The tab strip UI, the scrolling layout, and the CLI/MCP `panes` payload all
//! derive tabs from here so they never disagree on what "a tab" is.

const std = @import("std");
const workspace_layout = @import("workspace_layout.zig");

const WorkspaceLayout = workspace_layout.WorkspaceLayout;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;

pub const WorkspaceTabId = WorkspacePaneId;

pub const WorkspaceTab = struct {
    id: WorkspaceTabId,
    /// First pane of the tab in persisted pane order. The scrolling layout
    /// resolves the tab's default extent from it.
    representative_pane_id: WorkspacePaneId,
    /// Pane that receives focus when the tab is activated: the last-focused
    /// child of a split tile, otherwise its first pane.
    preferred_pane_id: WorkspacePaneId,
    pane_count: usize,
};

/// Collects the visible tabs of `layout` in strip order (persisted pane
/// order, first occurrence of each tile). Panes outside the root tree,
/// such as a detached quick pane, are not tabs.
pub fn collect(layout: *const WorkspaceLayout, buffer: []WorkspaceTab) []WorkspaceTab {
    var iterator = Iterator{ .layout = layout };
    var count: usize = 0;
    while (count < buffer.len) {
        buffer[count] = iterator.next() orelse break;
        count += 1;
    }
    return buffer[0..count];
}

/// Visits every rooted tab without imposing a rendering or buffer limit.
pub const Iterator = struct {
    layout: *const WorkspaceLayout,
    pane_index: usize = 0,

    pub fn next(self: *Iterator) ?WorkspaceTab {
        while (self.pane_index < self.layout.panes.items.len) {
            const index = self.pane_index;
            self.pane_index += 1;
            const pane = self.layout.panes.items[index];
            const tab_id = tabIdForPane(self.layout, pane.id) orelse continue;
            var seen = false;
            for (self.layout.panes.items[0..index]) |earlier| {
                if (tabIdForPane(self.layout, earlier.id) == tab_id) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            return .{
                .id = tab_id,
                .representative_pane_id = pane.id,
                .preferred_pane_id = self.layout.preferredScrollGroupPaneId(tab_id) orelse pane.id,
                .pane_count = self.layout.scrollGroupPaneCount(tab_id),
            };
        }
        return null;
    }
};

/// Tab that owns `pane_id`, or null for panes outside the root tree.
pub fn tabIdForPane(layout: *const WorkspaceLayout, pane_id: WorkspacePaneId) ?WorkspaceTabId {
    if (!layout.rootContainsPane(pane_id)) return null;
    return layout.scrollGroupIdForPane(pane_id);
}

/// Tab holding the focused pane. Null while nothing tiled has focus.
pub fn focusedTabId(layout: *const WorkspaceLayout) ?WorkspaceTabId {
    const focused = layout.focused_pane_id orelse return null;
    return tabIdForPane(layout, focused);
}

pub fn indexOfTab(tabs: []const WorkspaceTab, tab_id: WorkspaceTabId) ?usize {
    for (tabs, 0..) |tab, index| {
        if (tab.id == tab_id) return index;
    }
    return null;
}

pub fn indexOfPane(layout: *const WorkspaceLayout, tabs: []const WorkspaceTab, pane_id: WorkspacePaneId) ?usize {
    const tab_id = tabIdForPane(layout, pane_id) orelse return null;
    return indexOfTab(tabs, tab_id);
}

test "a split tile is one tab and standalone panes are their own tabs" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    // Split the founding chat pane and weld the terminal into its tile.
    const tiled_pane_id = try layout.createTerminalPane(allocator, 10);
    try layout.splitPaneWithLeaf(allocator, 1, tiled_pane_id, .vertical, true);
    try std.testing.expect(layout.joinPaneToScrollGroup(1, tiled_pane_id));
    // A second split without joining becomes a separate strip item.
    const standalone_pane_id = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, tiled_pane_id, standalone_pane_id, .vertical, true);

    var buffer: [16]WorkspaceTab = undefined;
    const tabs = collect(&layout, &buffer);
    try std.testing.expectEqual(@as(usize, 2), tabs.len);
    try std.testing.expectEqual(@as(WorkspaceTabId, 1), tabs[0].id);
    try std.testing.expectEqual(@as(usize, 2), tabs[0].pane_count);
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), tabs[0].representative_pane_id);
    try std.testing.expectEqual(standalone_pane_id, tabs[1].id);
    try std.testing.expectEqual(@as(usize, 1), tabs[1].pane_count);

    // Both tiled panes resolve to the same tab; the focused pane picks it.
    try std.testing.expectEqual(@as(?WorkspaceTabId, 1), tabIdForPane(&layout, tiled_pane_id));
    try std.testing.expectEqual(@as(?usize, 0), indexOfPane(&layout, tabs, tiled_pane_id));
    layout.focused_pane_id = standalone_pane_id;
    try std.testing.expectEqual(@as(?WorkspaceTabId, standalone_pane_id), focusedTabId(&layout));

    // Re-entering a tile lands on its last-focused child.
    try std.testing.expect(layout.rememberScrollGroupFocusedPane(tiled_pane_id));
    try std.testing.expectEqual(tiled_pane_id, collect(&layout, &buffer)[0].preferred_pane_id);
}

test "tabs skip panes outside the root tree" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    // A pane record with no leaf in the tree (e.g. a detached quick pane).
    const orphan_pane_id = try layout.createTerminalPane(allocator, 12);
    var buffer: [16]WorkspaceTab = undefined;
    const tabs = collect(&layout, &buffer);
    try std.testing.expectEqual(@as(usize, 1), tabs.len);
    try std.testing.expectEqual(@as(?WorkspaceTabId, null), tabIdForPane(&layout, orphan_pane_id));
    try std.testing.expectEqual(@as(?usize, null), indexOfPane(&layout, tabs, orphan_pane_id));
    try std.testing.expectEqual(@as(?usize, null), indexOfTab(tabs, 999));
}

test "tabs remain reachable beyond the former sixteen group limit" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);
    var last: WorkspacePaneId = 1;
    for (0..40) |index| {
        const pane_id = try layout.createTerminalPane(allocator, @intCast(index + 1));
        try layout.splitPaneWithLeaf(allocator, last, pane_id, .vertical, true);
        last = pane_id;
    }
    // A late split joins its existing tab; a detached pane is never a tab.
    const child = try layout.createTerminalPane(allocator, 100);
    try layout.splitPaneWithLeaf(allocator, last, child, .horizontal, true);
    try std.testing.expect(layout.joinPaneToScrollGroup(last, child));
    try std.testing.expect(layout.rememberScrollGroupFocusedPane(child));
    const detached = try layout.createTerminalPane(allocator, 101);
    const buffer = try allocator.alloc(WorkspaceTab, layout.panes.items.len);
    defer allocator.free(buffer);
    const tabs = collect(&layout, buffer);
    try std.testing.expectEqual(@as(usize, 41), tabs.len);
    try std.testing.expectEqual(layout.visibleTabCount(), tabs.len);
    try std.testing.expectEqual(last, tabs[40].id);
    try std.testing.expectEqual(child, tabs[40].preferred_pane_id);
    try std.testing.expectEqual(@as(usize, 2), tabs[40].pane_count);
    try std.testing.expectEqual(@as(?usize, 40), indexOfPane(&layout, tabs, child));
    try std.testing.expectEqual(@as(?usize, null), indexOfPane(&layout, tabs, detached));
}
