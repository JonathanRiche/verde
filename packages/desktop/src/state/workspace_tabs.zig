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

/// Upper bound on tabs collected per workspace; matches the pane-rect budget
/// the scrolling layout already caps at.
pub const MAX_WORKSPACE_TABS: usize = 16;

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
    var count: usize = 0;
    for (layout.panes.items) |pane| {
        if (!layout.rootContainsPane(pane.id)) continue;
        const tab_id = layout.scrollGroupIdForPane(pane.id) orelse continue;
        if (indexOfTab(buffer[0..count], tab_id) != null) continue;
        if (count >= buffer.len) break;
        buffer[count] = .{
            .id = tab_id,
            .representative_pane_id = pane.id,
            .preferred_pane_id = layout.preferredScrollGroupPaneId(tab_id) orelse pane.id,
            .pane_count = layout.scrollGroupPaneCount(tab_id),
        };
        count += 1;
    }
    return buffer[0..count];
}

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

    var buffer: [MAX_WORKSPACE_TABS]WorkspaceTab = undefined;
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
    var buffer: [MAX_WORKSPACE_TABS]WorkspaceTab = undefined;
    const tabs = collect(&layout, &buffer);
    try std.testing.expectEqual(@as(usize, 1), tabs.len);
    try std.testing.expectEqual(@as(?WorkspaceTabId, null), tabIdForPane(&layout, orphan_pane_id));
    try std.testing.expectEqual(@as(?usize, null), indexOfPane(&layout, tabs, orphan_pane_id));
    try std.testing.expectEqual(@as(?usize, null), indexOfTab(tabs, 999));
}
