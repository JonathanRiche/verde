//! Per-tab right side panel (Browser / Agents) and the docked browser panes
//! that live in it. Layout storage is `WorkspaceLayout.side_panels`; this
//! file holds the user-facing actions.

const std = @import("std");
const workspace_layout = @import("workspace_layout.zig");
const workspace_tabs = @import("workspace_tabs.zig");

const WorkspaceLayout = workspace_layout.WorkspaceLayout;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;
const SidePanelView = workspace_layout.SidePanelView;
const TabSidePanel = workspace_layout.TabSidePanel;

const log = std.log.scoped(.side_panel);

fn selectedLayout(self: anytype) ?*WorkspaceLayout {
    if (self.project_controller.projects.items.len == 0) return null;
    const index = self.project_controller.selected_index;
    if (index >= self.project_controller.projects.items.len) return null;
    return &self.project_controller.projects.items[index].workspace_layout;
}

/// Focused tab of the selected workspace, which the side panel follows.
pub fn sidePanelTabId(self: anytype) ?WorkspacePaneId {
    const layout = selectedLayout(self) orelse return null;
    return layout.focusedTabId();
}

/// Panel state for the focused tab; closed default when it has none.
pub fn currentSidePanel(self: anytype) ?TabSidePanel {
    const layout = selectedLayout(self) orelse return null;
    const tab_id = layout.focusedTabId() orelse return null;
    return layout.sidePanel(tab_id);
}

pub fn isSidePanelOpen(self: anytype) bool {
    const panel = currentSidePanel(self) orelse return false;
    return panel.open;
}

/// Shows or hides the focused tab's panel. Hiding keeps the browser's page
/// alive off-screen until idle eviction reclaims it.
pub fn toggleSidePanel(self: anytype) void {
    const layout = selectedLayout(self) orelse return;
    const tab_id = layout.focusedTabId() orelse return;
    const panel = layout.sidePanelMutable(self.allocator, tab_id) catch |err| {
        log.warn("failed to store side panel state: {s}", .{@errorName(err)});
        return;
    };
    panel.open = !panel.open;
    if (!panel.open) {
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    }
    self.markDirty();
}

pub fn setSidePanelOpen(self: anytype, open: bool) void {
    if (isSidePanelOpen(self) == open) return;
    toggleSidePanel(self);
}

pub fn setSidePanelView(self: anytype, view: SidePanelView) void {
    const layout = selectedLayout(self) orelse return;
    const tab_id = layout.focusedTabId() orelse return;
    const panel = layout.sidePanelMutable(self.allocator, tab_id) catch return;
    if (panel.open and panel.view == view) return;
    panel.open = true;
    panel.view = view;
    if (view != .browser) {
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    }
    self.markDirty();
}

pub fn setSidePanelRatio(self: anytype, ratio: f32) void {
    const layout = selectedLayout(self) orelse return;
    if (layout.setSidePanelRatio(ratio)) self.markDirty();
}

/// Docked browser of the focused tab, if it has one.
pub fn sidePanelBrowserPaneId(self: anytype) ?WorkspacePaneId {
    const layout = selectedLayout(self) orelse return null;
    const tab_id = layout.focusedTabId() orelse return null;
    return layout.dockedBrowserPaneId(tab_id);
}

/// Chat pane whose linked agents the Agents view lists: the focused pane
/// when it is a chat, else the first chat in the focused tab.
pub fn sidePanelChatPaneId(self: anytype) ?WorkspacePaneId {
    const layout = selectedLayout(self) orelse return null;
    const tab_id = layout.focusedTabId() orelse return null;
    if (layout.focused_pane_id) |focused| {
        if (layout.paneById(focused)) |pane| {
            if (pane.ref == .chat) return focused;
        }
    }
    for (layout.panes.items) |pane| {
        if (pane.ref != .chat) continue;
        if (workspace_tabs.tabIdForPane(layout, pane.id) == tab_id) return pane.id;
    }
    return null;
}

/// "Move to own tab": the docked browser becomes a tiled tab of its own.
pub fn moveBrowserToOwnTab(self: anytype, pane_id: WorkspacePaneId) void {
    const layout = selectedLayout(self) orelse return;
    const moved = layout.undockBrowserPane(self.allocator, pane_id) catch |err| {
        log.warn("failed to move browser to its own tab: {s}", .{@errorName(err)});
        self.setSidebarNotice("Could not move the browser to its own tab.");
        return;
    };
    if (!moved) return;
    _ = self.focusCurrentProjectWorkspacePane(pane_id);
    self.setSidebarNotice("Browser moved to its own tab.");
    self.markDirty();
}

/// "Attach to tab": a browser tab joins the side panel of the nearest tab
/// before it (else after it) that has no browser of its own.
pub fn attachBrowserToTab(self: anytype, pane_id: WorkspacePaneId) void {
    const layout = selectedLayout(self) orelse return;
    if (ownTabHasDockedBrowser(layout, pane_id)) {
        self.setSidebarNotice("Close this tab's side panel browser before attaching it to another tab.");
        return;
    }
    const tab_id = attachTargetTabId(self.allocator, layout, pane_id) orelse {
        self.setSidebarNotice("No tab without a browser to attach to.");
        return;
    };
    const was_focused = layout.focused_pane_id == pane_id;
    const docked = layout.dockBrowserPane(self.allocator, pane_id, tab_id) catch |err| {
        log.warn("failed to attach browser to tab: {s}", .{@errorName(err)});
        return;
    };
    if (!docked) {
        self.setSidebarNotice("Could not attach the browser to that tab.");
        return;
    }
    if (was_focused) {
        // Follow the browser into the tab whose panel now shows it.
        for (layout.panes.items) |pane| {
            if (workspace_tabs.tabIdForPane(layout, pane.id) == tab_id) {
                _ = self.focusCurrentProjectWorkspacePane(pane.id);
                break;
            }
        }
    }
    self.unfocusBrowserPane();
    self.setSidebarNotice("Browser attached to tab.");
    self.markDirty();
}

pub fn canAttachBrowserToTab(self: anytype, pane_id: WorkspacePaneId) bool {
    const layout = selectedLayout(self) orelse return false;
    if (layout.isDockedPane(pane_id)) return false;
    if (ownTabHasDockedBrowser(layout, pane_id)) return false;
    return attachTargetTabId(self.allocator, layout, pane_id) != null;
}

/// A browser tab can carry its own side-panel browser. Attaching the tab
/// elsewhere would leave that browser without a tab, and it would be pruned.
fn ownTabHasDockedBrowser(layout: *const WorkspaceLayout, pane_id: WorkspacePaneId) bool {
    const own_tab = workspace_tabs.tabIdForPane(layout, pane_id) orelse return false;
    const docked = layout.dockedBrowserPaneId(own_tab) orelse return false;
    return docked != pane_id;
}

fn attachTargetTabId(allocator: std.mem.Allocator, layout: *const WorkspaceLayout, pane_id: WorkspacePaneId) ?WorkspacePaneId {
    const own_tab = workspace_tabs.tabIdForPane(layout, pane_id) orelse return null;
    const buffer = allocator.alloc(workspace_tabs.WorkspaceTab, layout.panes.items.len) catch return null;
    defer allocator.free(buffer);
    const tabs = workspace_tabs.collect(layout, buffer);
    const own_index = workspace_tabs.indexOfTab(tabs, own_tab) orelse return null;
    var index = own_index;
    while (index > 0) {
        index -= 1;
        if (layout.dockedBrowserPaneId(tabs[index].id) == null) return tabs[index].id;
    }
    index = own_index + 1;
    while (index < tabs.len) : (index += 1) {
        if (layout.dockedBrowserPaneId(tabs[index].id) == null) return tabs[index].id;
    }
    return null;
}

test "attach target prefers the tab before the browser" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);
    const second = try layout.createChatPane(allocator, 1);
    try layout.ensurePaneInRootSplit(allocator, second, .vertical, 0.5);
    const second_tab = layout.scrollGroupIdForPane(second).?;
    const browser = try layout.ensureDockedBrowserPane(allocator, second_tab);
    try std.testing.expect(try layout.undockBrowserPane(allocator, browser));
    try std.testing.expectEqual(@as(?WorkspacePaneId, second_tab), attachTargetTabId(allocator, &layout, browser));
    try std.testing.expect(try layout.dockBrowserPane(allocator, browser, second_tab));
    try std.testing.expectEqual(@as(?WorkspacePaneId, browser), layout.dockedBrowserPaneId(second_tab));
}
