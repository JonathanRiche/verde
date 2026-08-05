//! Workspace pane tree ownership, persistence, migration, and repair.

const std = @import("std");
const browser_pane = @import("browser_pane.zig");
const app_config = @import("../app/config.zig");

const BrowserTabRef = browser_pane.BrowserTabRef;
const BrowserPaneRef = browser_pane.BrowserPaneRef;

pub const WorkspacePaneId = u32;
pub const MIN_SCROLL_PANE_EXTENT_CSS: f32 = 240.0;
pub const MAX_SCROLL_PANE_EXTENT_CSS: f32 = 1600.0;

pub const WorkspacePaneKind = enum {
    chat,
    terminal,
    browser,
};

pub const WorkspacePaneRef = union(WorkspacePaneKind) {
    chat: ChatPaneRef,
    terminal: TerminalPaneRef,
    browser: BrowserPaneRef,
};

pub const ChatPaneRef = struct {
    thread_index: usize = 0,
    transcript_scroll_valid: bool = false,
    transcript_scroll_y: f32 = 0.0,
};

pub const TerminalPaneRef = struct {
    dock_id: u32 = 0,
    purpose: TerminalPanePurpose = .normal,
};

pub const TerminalPanePurpose = enum {
    normal,
    editor,
};

pub fn deinitWorkspacePaneRef(ref: *WorkspacePaneRef, allocator: std.mem.Allocator) void {
    switch (ref.*) {
        .browser => |*browser| browser.deinit(allocator),
        .chat, .terminal => {},
    }
}

pub const WorkspacePane = struct {
    id: WorkspacePaneId,
    ref: WorkspacePaneRef,
};

pub const WorkspacePanePlacement = struct {
    pane_id: WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    new_after: bool,
};

const WorkspaceLayoutRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const WorkspacePaneLayoutRect = struct {
    pane_id: WorkspacePaneId,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const WorkspaceSplitAxis = enum {
    horizontal,
    vertical,
};

pub const WorkspacePaneDirection = enum {
    left,
    right,
    up,
    down,
};

pub const WorkspaceNode = union(enum) {
    leaf: WorkspacePaneId,
    split: struct {
        axis: WorkspaceSplitAxis,
        ratio: f32,
        first: *WorkspaceNode,
        second: *WorkspaceNode,
    },
};

pub const FloatingPaneGeometry = struct {
    /// Normalized workspace coordinates keep the pane usable across DPI and
    /// window-size changes. Rendering applies the final minimum-size clamp.
    x: f32 = 0.18,
    y: f32 = 0.14,
    w: f32 = 0.64,
    h: f32 = 0.68,
};

pub const FloatingQuickPane = struct {
    pane_id: WorkspacePaneId,
    geometry: FloatingPaneGeometry = .{},
    visible: bool = true,
    maximized: bool = false,
    pinned: bool = false,
    /// Detached quick panes are session-backed leaves that intentionally do
    /// not participate in the tiled root until Return to Tile is requested.
    detached: bool = false,
    return_focus_pane_id: ?WorkspacePaneId = null,
};

pub const WorkspaceLayout = struct {
    next_pane_id: WorkspacePaneId = 1,
    root: ?*WorkspaceNode = null,
    panes: std.ArrayList(WorkspacePane) = .empty,
    focused_pane_id: ?WorkspacePaneId = null,
    maximized_pane_id: ?WorkspacePaneId = null,
    quick_pane: ?FloatingQuickPane = null,
    /// Logical workspace pixels. The target is persisted; the current value
    /// eases toward it while the scrolling layout is visible.
    scroll_offset_x: f32 = 0.0,
    scroll_target_x: f32 = 0.0,
    scroll_offset_y: f32 = 0.0,
    scroll_target_y: f32 = 0.0,
    scroll_revealed_pane_id: ?WorkspacePaneId = null,
    /// A transient direct-navigation request. Rendering consumes it after
    /// placing the selected pane at the strip's leading edge.
    scroll_leading_pane_id: ?WorkspacePaneId = null,
    scroll_animation_last_ms: i64 = 0,
    scroll_axis_vertical: bool = false,
    /// Null values inherit the global app configuration. Both fields are
    /// persisted with the workspace layout so a local pin/threshold survives
    /// restart without requiring a database schema change.
    scroll_mode_override: ?app_config.WorkspaceScrollMode = null,
    scroll_threshold_override: ?u8 = null,
    /// The absolute extent remains for backwards compatibility and for the
    /// resize affordance's custom-width state. New resizes also persist a
    /// viewport-relative stride ratio so the layout follows display-size changes.
    scroll_pane_extent_override: ?f32 = null,
    scroll_pane_extent_ratio_override: ?f32 = null,

    pub fn initDefaultChat(allocator: std.mem.Allocator) !WorkspaceLayout {
        var layout: WorkspaceLayout = .{};
        errdefer layout.deinit(allocator);
        const pane_id = layout.next_pane_id;
        layout.next_pane_id += 1;
        try layout.panes.append(allocator, .{
            .id = pane_id,
            .ref = .{ .chat = .{ .thread_index = 0 } },
        });
        layout.root = try createLeafNode(allocator, pane_id);
        layout.focused_pane_id = pane_id;
        return layout;
    }

    pub fn deinit(self: *WorkspaceLayout, allocator: std.mem.Allocator) void {
        if (self.root) |root| destroyNode(allocator, root);
        for (self.panes.items) |*pane| deinitWorkspacePaneRef(&pane.ref, allocator);
        self.panes.deinit(allocator);
        self.* = .{};
    }

    pub fn ensureDefaultChat(self: *WorkspaceLayout, allocator: std.mem.Allocator) !bool {
        if (self.root != null and self.panes.items.len > 0 and self.firstVisiblePaneId() != null) {
            return try self.repairVisibleRoot(allocator);
        }

        self.deinit(allocator);
        self.* = try WorkspaceLayout.initDefaultChat(allocator);
        return true;
    }

    pub fn repairVisibleRoot(self: *WorkspaceLayout, allocator: std.mem.Allocator) !bool {
        var changed = false;
        // Early floating-pane builds persisted the quick pane inside the tiled
        // root and rendered it again as an overlay. Migrate that representation
        // before normal root repair so reopening a workspace cannot recreate
        // the duplicate pane underneath.
        if (self.quick_pane) |quick| {
            if (!quick.detached and self.rootContainsPane(quick.pane_id) and self.visiblePaneCount() > 1) {
                if (self.root) |root_node| self.root = removePaneFromTree(allocator, root_node, quick.pane_id);
                self.quick_pane.?.detached = true;
                self.quick_pane.?.return_focus_pane_id = self.firstVisiblePaneId();
                changed = true;
            }
        }
        if (self.root) |root_node| {
            const repaired = pruneRootToVisiblePanes(allocator, self, root_node);
            self.root = repaired.node;
            changed = changed or repaired.changed;
        }
        if (self.root == null) {
            if (self.firstVisiblePaneId()) |pane_id| {
                self.root = try createLeafNode(allocator, pane_id);
                changed = true;
            }
        }
        for (self.panes.items) |pane| {
            if (self.rootContainsPane(pane.id)) continue;
            if (self.quick_pane) |quick| {
                if (quick.detached and quick.pane_id == pane.id) continue;
            }
            try self.ensurePaneInRootSplit(allocator, pane.id, .horizontal, 0.64);
            changed = true;
        }
        if (self.focused_pane_id) |pane_id| {
            if (self.paneById(pane_id) == null) {
                self.focused_pane_id = self.firstVisiblePaneId();
                changed = true;
            }
        } else {
            self.focused_pane_id = self.firstVisiblePaneId();
            changed = changed or self.focused_pane_id != null;
        }
        if (self.maximized_pane_id) |pane_id| {
            if (self.paneById(pane_id) == null) {
                self.maximized_pane_id = null;
                changed = true;
            }
        }
        if (self.quick_pane) |quick| {
            if (self.paneById(quick.pane_id) == null) {
                self.quick_pane = null;
                changed = true;
            }
        }
        return changed;
    }

    pub fn firstVisiblePaneId(self: *const WorkspaceLayout) ?WorkspacePaneId {
        const root_node = self.root orelse return null;
        return self.edgeVisiblePaneId(root_node, false);
    }

    pub fn paneById(self: *const WorkspaceLayout, pane_id: WorkspacePaneId) ?*const WorkspacePane {
        for (self.panes.items) |*pane| {
            if (pane.id == pane_id) return pane;
        }
        return null;
    }

    pub fn paneByIdMutable(self: *WorkspaceLayout, pane_id: WorkspacePaneId) ?*WorkspacePane {
        for (self.panes.items) |*pane| {
            if (pane.id == pane_id) return pane;
        }
        return null;
    }

    pub fn visibleChatPaneIdForThread(self: *const WorkspaceLayout, thread_index: usize) ?WorkspacePaneId {
        for (self.panes.items) |pane| {
            if (!self.rootContainsPane(pane.id)) continue;
            switch (pane.ref) {
                .chat => |ref| if (ref.thread_index == thread_index) return pane.id,
                else => {},
            }
        }
        return null;
    }

    pub fn retargetPreferredChatPane(self: *WorkspaceLayout, thread_index: usize) ?WorkspacePaneId {
        if (self.focused_pane_id) |focused_pane_id| {
            if (self.paneByIdMutable(focused_pane_id)) |pane| {
                switch (pane.ref) {
                    .chat => |*ref| {
                        ref.thread_index = thread_index;
                        return pane.id;
                    },
                    else => {},
                }
            }
        }
        for (self.panes.items) |*pane| {
            switch (pane.ref) {
                .chat => |*ref| {
                    ref.thread_index = thread_index;
                    return pane.id;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn visibleTerminalPaneIdForDock(self: *const WorkspaceLayout, dock_id: u32) ?WorkspacePaneId {
        for (self.panes.items) |pane| {
            if (!self.rootContainsPane(pane.id)) continue;
            switch (pane.ref) {
                .terminal => |ref| if (ref.dock_id == dock_id) return pane.id,
                else => {},
            }
        }
        return null;
    }

    pub fn rootContainsPane(self: *const WorkspaceLayout, pane_id: WorkspacePaneId) bool {
        const root_node = self.root orelse return false;
        return nodeContainsPane(root_node, pane_id);
    }

    pub fn replaceRootWithLeaf(self: *WorkspaceLayout, allocator: std.mem.Allocator, pane_id: WorkspacePaneId) !void {
        if (self.root) |root_node| destroyNode(allocator, root_node);
        self.root = try createLeafNode(allocator, pane_id);
        self.focused_pane_id = pane_id;
    }

    pub fn focusedPane(self: *const WorkspaceLayout) ?*const WorkspacePane {
        const pane_id = self.focused_pane_id orelse return null;
        return self.paneById(pane_id);
    }

    pub fn focusCreatedPane(self: *WorkspaceLayout, pane_id: WorkspacePaneId) void {
        const was_maximized = self.maximized_pane_id != null;
        self.focused_pane_id = pane_id;
        if (was_maximized) self.maximized_pane_id = pane_id;
    }

    pub fn visiblePaneCount(self: *const WorkspaceLayout) usize {
        const root_node = self.root orelse return 0;
        return countWorkspaceNodeLeaves(root_node);
    }

    pub fn effectiveScrollMode(self: *const WorkspaceLayout, global_mode: app_config.WorkspaceScrollMode) app_config.WorkspaceScrollMode {
        return self.scroll_mode_override orelse global_mode;
    }

    pub fn effectiveScrollThreshold(self: *const WorkspaceLayout, global_threshold: u8) u8 {
        return self.scroll_threshold_override orelse global_threshold;
    }

    pub fn hasScrollOverride(self: *const WorkspaceLayout) bool {
        return self.scroll_mode_override != null or self.scroll_threshold_override != null;
    }

    pub fn requestLeadingScrollReveal(self: *WorkspaceLayout, pane_id: WorkspacePaneId) void {
        self.scroll_leading_pane_id = if (self.rootContainsPane(pane_id)) pane_id else null;
        self.scroll_revealed_pane_id = null;
    }

    /// Returns the adjacent tiled pane in the same order as the expanded
    /// sidebar, excluding detached panes that are not part of the root.
    pub fn adjacentTiledPaneIdInSidebarOrder(self: *const WorkspaceLayout, pane_id: WorkspacePaneId, direction: WorkspacePaneDirection) ?WorkspacePaneId {
        if (!self.rootContainsPane(pane_id)) return null;
        const backwards = direction == .left or direction == .up;

        var previous: ?WorkspacePaneId = null;
        var matched = false;
        for (self.panes.items) |pane| {
            if (!self.rootContainsPane(pane.id)) continue;
            if (backwards and pane.id == pane_id) return previous;
            if (matched) return pane.id;
            if (pane.id == pane_id) matched = true;
            previous = pane.id;
        }
        return null;
    }

    pub fn gridNewPanePlacement(self: *const WorkspaceLayout) ?WorkspacePanePlacement {
        if (self.maximized_pane_id != null) return null;
        const visible = self.visiblePaneCount();
        if (visible == 0 or visible >= 4) return null;

        const root_node = self.root orelse return null;
        var rects: [48]WorkspacePaneLayoutRect = undefined;
        var count: usize = 0;
        self.collectVisiblePaneRects(root_node, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, &rects, &count);
        if (count == 0) return null;

        if (visible == 1) {
            return .{ .pane_id = rects[0].pane_id, .axis = .vertical, .new_after = true };
        }

        var best: usize = 0;
        var i: usize = 1;
        while (i < count) : (i += 1) {
            const a = rects[i];
            const b = rects[best];
            if (a.h > b.h + 0.001) {
                best = i;
            } else if (a.h > b.h - 0.001 and a.x < b.x - 0.001) {
                best = i;
            }
        }
        return .{ .pane_id = rects[best].pane_id, .axis = .horizontal, .new_after = true };
    }

    pub fn collectVisiblePaneRects(
        self: *const WorkspaceLayout,
        node: *const WorkspaceNode,
        rect: WorkspaceLayoutRect,
        rects: *[48]WorkspacePaneLayoutRect,
        count: *usize,
    ) void {
        switch (node.*) {
            .leaf => |pane_id| {
                if (self.paneById(pane_id) == null or count.* >= rects.len) return;
                rects[count.*] = .{
                    .pane_id = pane_id,
                    .x = rect.x,
                    .y = rect.y,
                    .w = rect.w,
                    .h = rect.h,
                };
                count.* += 1;
            },
            .split => |split| {
                const ratio = std.math.clamp(split.ratio, 0.05, 0.95);
                switch (split.axis) {
                    .vertical => {
                        const first_w = rect.w * ratio;
                        const second_x = rect.x + first_w;
                        self.collectVisiblePaneRects(split.first, .{ .x = rect.x, .y = rect.y, .w = first_w, .h = rect.h }, rects, count);
                        self.collectVisiblePaneRects(split.second, .{ .x = second_x, .y = rect.y, .w = rect.w - first_w, .h = rect.h }, rects, count);
                    },
                    .horizontal => {
                        const first_h = rect.h * ratio;
                        const second_y = rect.y + first_h;
                        self.collectVisiblePaneRects(split.first, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = first_h }, rects, count);
                        self.collectVisiblePaneRects(split.second, .{ .x = rect.x, .y = second_y, .w = rect.w, .h = rect.h - first_h }, rects, count);
                    },
                }
            },
        }
    }

    pub fn paneIndexById(self: *const WorkspaceLayout, pane_id: WorkspacePaneId) ?usize {
        for (self.panes.items, 0..) |pane, index| {
            if (pane.id == pane_id) return index;
        }
        return null;
    }

    /// Moves a pane in the persisted sidebar order. `before_index` is a slot
    /// in the original array and may equal `panes.len` to move to the end.
    pub fn movePaneBefore(self: *WorkspaceLayout, pane_id: WorkspacePaneId, before_index: usize) bool {
        const pane_count = self.panes.items.len;
        if (pane_count < 2) return false;
        const source_index = self.paneIndexById(pane_id) orelse return false;

        var destination_index = @min(before_index, pane_count);
        if (destination_index > source_index) destination_index -= 1;
        if (destination_index == source_index) return false;

        const pane = self.panes.orderedRemove(source_index);
        self.panes.insertAssumeCapacity(destination_index, pane);
        self.scroll_revealed_pane_id = null;
        return true;
    }

    pub fn swapPaneRefs(self: *WorkspaceLayout, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId) bool {
        const first_index = self.paneIndexById(first_pane_id) orelse return false;
        const second_index = self.paneIndexById(second_pane_id) orelse return false;
        const first_ref = self.panes.items[first_index].ref;
        self.panes.items[first_index].ref = self.panes.items[second_index].ref;
        self.panes.items[second_index].ref = first_ref;
        return true;
    }

    pub fn hasVisiblePaneKind(self: *const WorkspaceLayout, kind: WorkspacePaneKind) bool {
        for (self.panes.items) |pane| {
            if (!self.rootContainsPane(pane.id)) continue;
            switch (pane.ref) {
                .chat => if (kind == .chat) return true,
                .terminal => if (kind == .terminal) return true,
                .browser => if (kind == .browser) return true,
            }
        }
        return false;
    }

    pub fn hasVisibleQuickPaneKind(self: *const WorkspaceLayout, kind: WorkspacePaneKind) bool {
        const quick = self.quick_pane orelse return false;
        if (!quick.visible) return false;
        const pane = self.paneById(quick.pane_id) orelse return false;
        return switch (pane.ref) {
            .chat => kind == .chat,
            .terminal => kind == .terminal,
            .browser => kind == .browser,
        };
    }

    pub fn visibleBrowserPaneId(self: *const WorkspaceLayout) ?WorkspacePaneId {
        for (self.panes.items) |pane| {
            switch (pane.ref) {
                .browser => return pane.id,
                else => {},
            }
        }
        return null;
    }

    pub fn hasTerminalDockPane(self: *const WorkspaceLayout, dock_id: u32) bool {
        for (self.panes.items) |pane| {
            switch (pane.ref) {
                .terminal => |ref| if (ref.dock_id == dock_id) return true,
                else => {},
            }
        }
        return false;
    }

    pub fn hasEditorTerminalDockPane(self: *const WorkspaceLayout, dock_id: u32) bool {
        for (self.panes.items) |pane| {
            switch (pane.ref) {
                .terminal => |ref| if (ref.dock_id == dock_id and ref.purpose == .editor) return true,
                else => {},
            }
        }
        return false;
    }

    pub fn maxTerminalDockId(self: *const WorkspaceLayout) u32 {
        var max_id: u32 = 0;
        for (self.panes.items) |pane| {
            switch (pane.ref) {
                .terminal => |ref| max_id = @max(max_id, ref.dock_id),
                else => {},
            }
        }
        return max_id;
    }

    pub fn ensureTerminalPane(self: *WorkspaceLayout, allocator: std.mem.Allocator, dock_id: u32) !WorkspacePaneId {
        for (self.panes.items) |*pane| {
            switch (pane.ref) {
                .terminal => |ref| if (ref.dock_id == dock_id) {
                    self.focused_pane_id = pane.id;
                    try self.ensurePaneInRootSplit(allocator, pane.id, .horizontal, 0.64);
                    return pane.id;
                },
                else => {},
            }
        }

        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.insertPaneAfterFocus(allocator, .{
            .id = pane_id,
            .ref = .{ .terminal = .{ .dock_id = dock_id } },
        });
        self.focused_pane_id = pane_id;
        try self.ensurePaneInRootSplit(allocator, pane_id, .horizontal, 0.64);
        return pane_id;
    }

    pub fn ensureBrowserPane(self: *WorkspaceLayout, allocator: std.mem.Allocator) !WorkspacePaneId {
        for (self.panes.items) |*pane| {
            switch (pane.ref) {
                .browser => {
                    self.focused_pane_id = pane.id;
                    try self.ensurePaneInRootSplit(allocator, pane.id, .vertical, 0.58);
                    return pane.id;
                },
                else => {},
            }
        }

        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.insertPaneAfterFocus(allocator, .{
            .id = pane_id,
            .ref = .{ .browser = .{} },
        });
        const pane = self.paneByIdMutable(pane_id) orelse return error.BrowserPaneNotFound;
        _ = try pane.ref.browser.ensureTab(allocator);
        self.focused_pane_id = pane_id;
        try self.ensurePaneInRootSplit(allocator, pane_id, .vertical, 0.58);
        return pane_id;
    }

    pub fn createTerminalPane(self: *WorkspaceLayout, allocator: std.mem.Allocator, dock_id: u32) !WorkspacePaneId {
        return self.createTerminalPaneWithPurpose(allocator, dock_id, .normal);
    }

    pub fn createTerminalPaneWithPurpose(self: *WorkspaceLayout, allocator: std.mem.Allocator, dock_id: u32, purpose: TerminalPanePurpose) !WorkspacePaneId {
        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.insertPaneAfterFocus(allocator, .{
            .id = pane_id,
            .ref = .{ .terminal = .{ .dock_id = dock_id, .purpose = purpose } },
        });
        return pane_id;
    }

    pub fn createChatPane(self: *WorkspaceLayout, allocator: std.mem.Allocator, thread_index: usize) !WorkspacePaneId {
        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.insertPaneAfterFocus(allocator, .{
            .id = pane_id,
            .ref = .{ .chat = .{ .thread_index = thread_index } },
        });
        return pane_id;
    }

    fn insertPaneAfterFocus(self: *WorkspaceLayout, allocator: std.mem.Allocator, pane: WorkspacePane) !void {
        const insert_index = if (self.focused_pane_id) |focused_pane_id|
            if (self.paneIndexById(focused_pane_id)) |focused_index| focused_index + 1 else self.panes.items.len
        else
            self.panes.items.len;
        try self.panes.insert(allocator, insert_index, pane);
        self.scroll_revealed_pane_id = null;
    }

    pub fn splitPaneWithLeaf(
        self: *WorkspaceLayout,
        allocator: std.mem.Allocator,
        target_pane_id: WorkspacePaneId,
        new_pane_id: WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        new_after: bool,
    ) !void {
        if (self.root) |root_node| {
            if (try splitNodeWithLeaf(allocator, root_node, target_pane_id, new_pane_id, axis, new_after)) {
                self.focused_pane_id = new_pane_id;
                return;
            }
        }
        try self.ensurePaneInRootSplit(allocator, new_pane_id, axis, 0.5);
        self.focused_pane_id = new_pane_id;
    }

    pub fn closePaneKind(self: *WorkspaceLayout, allocator: std.mem.Allocator, kind: WorkspacePaneKind) bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.panes.items.len) {
            const pane = self.panes.items[index];
            if (std.meta.activeTag(pane.ref) != kind) {
                index += 1;
                continue;
            }
            if (self.root) |root_node| {
                self.root = removePaneFromTree(allocator, root_node, pane.id);
            }
            var removed_ref = self.panes.items[index].ref;
            deinitWorkspacePaneRef(&removed_ref, allocator);
            _ = self.panes.orderedRemove(index);
            changed = true;
        }
        if (!changed) return false;

        if (self.focused_pane_id) |pane_id| {
            const focused = self.paneById(pane_id);
            if (focused == null) self.focused_pane_id = self.firstVisiblePaneId();
        }
        if (self.maximized_pane_id) |pane_id| {
            const maximized = self.paneById(pane_id);
            if (maximized == null) self.maximized_pane_id = null;
        }
        if (self.root == null) {
            if (self.firstVisiblePaneId()) |pane_id| {
                self.replaceRootWithLeaf(allocator, pane_id) catch {
                    self.focused_pane_id = pane_id;
                };
            }
        }
        return true;
    }

    pub fn closePane(self: *WorkspaceLayout, allocator: std.mem.Allocator, pane_id: WorkspacePaneId) ?WorkspacePaneRef {
        const pane_index = self.paneIndexById(pane_id) orelse return null;
        const removed_ref = self.panes.items[pane_index].ref;
        const was_maximized = self.maximized_pane_id == pane_id;
        var next_sidebar_pane_id: ?WorkspacePaneId = null;
        var next_tiled_pane_id: ?WorkspacePaneId = null;
        if (was_maximized and self.panes.items.len > 1) {
            var offset: usize = 1;
            while (offset < self.panes.items.len) : (offset += 1) {
                const candidate_index = (pane_index + offset) % self.panes.items.len;
                const candidate_id = self.panes.items[candidate_index].id;
                if (next_sidebar_pane_id == null) next_sidebar_pane_id = candidate_id;
                if (next_tiled_pane_id == null and self.rootContainsPane(candidate_id)) {
                    next_tiled_pane_id = candidate_id;
                }
            }
        }
        if (self.root) |root_node| {
            self.root = removePaneFromTree(allocator, root_node, pane_id);
        }
        _ = self.panes.orderedRemove(pane_index);
        if (self.quick_pane) |quick| {
            if (quick.pane_id == pane_id) self.quick_pane = null;
        }
        if (was_maximized) {
            self.focused_pane_id = next_sidebar_pane_id orelse self.firstVisiblePaneId();
            self.maximized_pane_id = next_tiled_pane_id orelse self.firstVisiblePaneId();
            if (self.quick_pane) |*quick| {
                if (quick.pane_id == self.focused_pane_id) {
                    quick.visible = true;
                    quick.return_focus_pane_id = self.maximized_pane_id;
                } else if (quick.visible) {
                    quick.visible = false;
                    quick.return_focus_pane_id = self.focused_pane_id;
                }
            }
        } else {
            if (self.focused_pane_id == pane_id) self.focused_pane_id = self.firstVisiblePaneId();
            if (self.maximized_pane_id == pane_id) self.maximized_pane_id = null;
        }
        return removed_ref;
    }

    pub fn resizeSplit(self: *WorkspaceLayout, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, ratio: f32) bool {
        const root_node = self.root orelse return false;
        return resizeNodeSplit(root_node, first_pane_id, second_pane_id, axis, @max(0.18, @min(0.82, ratio)));
    }

    pub fn nudgeSplitRatio(self: *WorkspaceLayout, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, delta: f32) bool {
        const root_node = self.root orelse return false;
        return nudgeNodeSplitRatio(root_node, first_pane_id, second_pane_id, axis, delta);
    }

    pub fn neighborPaneId(self: *const WorkspaceLayout, pane_id: WorkspacePaneId, direction: WorkspacePaneDirection) ?WorkspacePaneId {
        const root_node = self.root orelse return null;
        if (!nodeContainsPane(root_node, pane_id)) return null;
        return self.neighborPaneIdInNode(root_node, pane_id, direction);
    }

    pub fn neighborPaneIdInNode(
        self: *const WorkspaceLayout,
        node: *const WorkspaceNode,
        pane_id: WorkspacePaneId,
        direction: WorkspacePaneDirection,
    ) ?WorkspacePaneId {
        switch (node.*) {
            .leaf => return null,
            .split => |split| {
                if (nodeContainsPane(split.first, pane_id)) {
                    if (self.neighborPaneIdInNode(split.first, pane_id, direction)) |neighbor| return neighbor;
                    if ((direction == .right and split.axis == .vertical) or
                        (direction == .down and split.axis == .horizontal))
                    {
                        return self.edgeVisiblePaneId(split.second, false);
                    }
                    return null;
                }
                if (nodeContainsPane(split.second, pane_id)) {
                    if (self.neighborPaneIdInNode(split.second, pane_id, direction)) |neighbor| return neighbor;
                    if ((direction == .left and split.axis == .vertical) or
                        (direction == .up and split.axis == .horizontal))
                    {
                        return self.edgeVisiblePaneId(split.first, true);
                    }
                    return null;
                }
                return null;
            },
        }
    }

    pub fn edgeVisiblePaneId(self: *const WorkspaceLayout, node: *const WorkspaceNode, prefer_second: bool) ?WorkspacePaneId {
        switch (node.*) {
            .leaf => |pane_id| {
                return if (self.paneById(pane_id) != null) pane_id else null;
            },
            .split => |split| {
                if (prefer_second) {
                    return self.edgeVisiblePaneId(split.second, true) orelse self.edgeVisiblePaneId(split.first, true);
                }
                return self.edgeVisiblePaneId(split.first, false) orelse self.edgeVisiblePaneId(split.second, false);
            },
        }
    }

    pub fn persistedWorkspaceJson(self: *const WorkspaceLayout, allocator: std.mem.Allocator) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };

        try stringify.beginObject();
        try stringify.objectField("v");
        try stringify.write(2);
        try stringify.objectField("next");
        try stringify.write(self.next_pane_id);
        try stringify.objectField("focused");
        if (self.focused_pane_id) |pane_id| {
            try stringify.write(pane_id);
        } else {
            try stringify.write(null);
        }
        try stringify.objectField("maximized");
        if (self.maximized_pane_id) |pane_id| {
            try stringify.write(pane_id);
        } else {
            try stringify.write(null);
        }
        try stringify.objectField("scroll_x");
        try stringify.write(self.scroll_target_x);
        try stringify.objectField("scroll_y");
        try stringify.write(self.scroll_target_y);
        if (self.scroll_mode_override) |mode| {
            try stringify.objectField("scroll_mode");
            try stringify.write(@tagName(mode));
        }
        if (self.scroll_threshold_override) |threshold| {
            try stringify.objectField("scroll_threshold");
            try stringify.write(threshold);
        }
        if (self.scroll_pane_extent_override) |pane_extent| {
            try stringify.objectField("scroll_pane_extent");
            try stringify.write(pane_extent);
            if (self.scroll_pane_extent_ratio_override) |pane_extent_ratio| {
                try stringify.objectField("scroll_pane_extent_ratio");
                try stringify.write(pane_extent_ratio);
            }
        }
        try stringify.objectField("quick");
        if (self.quick_pane) |quick| {
            try stringify.beginObject();
            try stringify.objectField("pane");
            try stringify.write(quick.pane_id);
            try stringify.objectField("x");
            try stringify.write(quick.geometry.x);
            try stringify.objectField("y");
            try stringify.write(quick.geometry.y);
            try stringify.objectField("w");
            try stringify.write(quick.geometry.w);
            try stringify.objectField("h");
            try stringify.write(quick.geometry.h);
            try stringify.objectField("visible");
            try stringify.write(quick.visible);
            try stringify.objectField("maximized");
            try stringify.write(quick.maximized);
            try stringify.objectField("pinned");
            try stringify.write(quick.pinned);
            try stringify.objectField("detached");
            try stringify.write(quick.detached);
            try stringify.objectField("return_focus");
            if (quick.return_focus_pane_id) |pane_id| try stringify.write(pane_id) else try stringify.write(null);
            try stringify.endObject();
        } else {
            try stringify.write(null);
        }

        try stringify.objectField("panes");
        try stringify.beginArray();
        for (self.panes.items) |pane| {
            try stringify.beginObject();
            try stringify.objectField("id");
            try stringify.write(pane.id);
            switch (pane.ref) {
                .chat => |ref| {
                    try stringify.objectField("kind");
                    try stringify.write("chat");
                    try stringify.objectField("thread");
                    try stringify.write(ref.thread_index);
                },
                .terminal => |ref| {
                    try stringify.objectField("kind");
                    try stringify.write("terminal");
                    try stringify.objectField("dock");
                    try stringify.write(ref.dock_id);
                    if (ref.purpose != .normal) {
                        try stringify.objectField("purpose");
                        try stringify.write(@tagName(ref.purpose));
                    }
                },
                .browser => |ref| {
                    try stringify.objectField("kind");
                    try stringify.write("browser");
                    try stringify.objectField("active_tab");
                    try stringify.write(ref.active_tab_index);
                    try stringify.objectField("tabs");
                    try stringify.beginArray();
                    for (ref.tabs.items) |tab| {
                        try stringify.beginObject();
                        if (tab.url) |url| {
                            try stringify.objectField("url");
                            try stringify.write(url);
                        }
                        if (tab.title) |title| {
                            try stringify.objectField("title");
                            try stringify.write(title);
                        }
                        if (tab.pinned) {
                            try stringify.objectField("pinned");
                            try stringify.write(true);
                        }
                        try stringify.objectField("history_index");
                        if (tab.history_index) |history_index| try stringify.write(history_index) else try stringify.write(null);
                        try stringify.objectField("history");
                        try stringify.beginArray();
                        for (tab.history.items) |entry| try stringify.write(entry);
                        try stringify.endArray();
                        try stringify.endObject();
                    }
                    try stringify.endArray();
                },
            }
            try stringify.endObject();
        }
        try stringify.endArray();

        try stringify.objectField("root");
        if (self.root) |root_node| {
            try writeWorkspaceNodeJson(&stringify, root_node);
        } else {
            try stringify.write(null);
        }
        try stringify.endObject();
        return try writer.toOwnedSlice();
    }

    pub fn applyPersistedWorkspaceJson(self: *WorkspaceLayout, allocator: std.mem.Allocator, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const root_value = parsed.value;
        if (root_value != .object) return;
        const version = jsonInt(root_value.object.get("v") orelse .null) orelse 1;
        if (version < 2) {
            try self.applyLegacyPersistedWorkspaceJson(allocator, json);
            return;
        }

        const panes_value = root_value.object.get("panes") orelse return;
        if (panes_value != .array) return;

        var next_layout: WorkspaceLayout = .{};
        errdefer next_layout.deinit(allocator);
        next_layout.next_pane_id = @intCast(jsonInt(root_value.object.get("next") orelse .null) orelse 1);
        next_layout.focused_pane_id = if (jsonInt(root_value.object.get("focused") orelse .null)) |id| @intCast(id) else null;
        next_layout.maximized_pane_id = if (jsonInt(root_value.object.get("maximized") orelse .null)) |id| @intCast(id) else null;
        next_layout.scroll_target_x = @max(0.0, jsonFloat(root_value.object.get("scroll_x") orelse .null) orelse 0.0);
        next_layout.scroll_offset_x = next_layout.scroll_target_x;
        next_layout.scroll_target_y = @max(0.0, jsonFloat(root_value.object.get("scroll_y") orelse .null) orelse 0.0);
        next_layout.scroll_offset_y = next_layout.scroll_target_y;
        if (jsonString(root_value.object.get("scroll_mode") orelse .null)) |mode_value| {
            next_layout.scroll_mode_override = app_config.WorkspaceScrollMode.parse(mode_value);
        }
        if (jsonInt(root_value.object.get("scroll_threshold") orelse .null)) |threshold| {
            if (threshold >= app_config.MIN_WORKSPACE_SCROLL_THRESHOLD and threshold <= app_config.MAX_WORKSPACE_SCROLL_THRESHOLD) {
                next_layout.scroll_threshold_override = @intCast(threshold);
            }
        }
        if (jsonFloat(root_value.object.get("scroll_pane_extent") orelse .null)) |pane_extent| {
            if (pane_extent >= MIN_SCROLL_PANE_EXTENT_CSS and pane_extent <= MAX_SCROLL_PANE_EXTENT_CSS) {
                next_layout.scroll_pane_extent_override = pane_extent;
                if (jsonFloat(root_value.object.get("scroll_pane_extent_ratio") orelse .null)) |pane_extent_ratio| {
                    if (pane_extent_ratio > 0.0) next_layout.scroll_pane_extent_ratio_override = pane_extent_ratio;
                }
            }
        }
        if (root_value.object.get("quick")) |quick_value| {
            if (quick_value == .object) {
                if (jsonInt(quick_value.object.get("pane") orelse .null)) |pane_id| {
                    next_layout.quick_pane = .{
                        .pane_id = @intCast(pane_id),
                        .geometry = .{
                            .x = jsonFloat(quick_value.object.get("x") orelse .null) orelse 0.18,
                            .y = jsonFloat(quick_value.object.get("y") orelse .null) orelse 0.14,
                            .w = jsonFloat(quick_value.object.get("w") orelse .null) orelse 0.64,
                            .h = jsonFloat(quick_value.object.get("h") orelse .null) orelse 0.68,
                        },
                        .visible = jsonBool(quick_value.object.get("visible") orelse .null) orelse false,
                        .maximized = jsonBool(quick_value.object.get("maximized") orelse .null) orelse false,
                        .pinned = jsonBool(quick_value.object.get("pinned") orelse .null) orelse false,
                        .detached = jsonBool(quick_value.object.get("detached") orelse .null) orelse false,
                        .return_focus_pane_id = if (jsonInt(quick_value.object.get("return_focus") orelse .null)) |id| @intCast(id) else null,
                    };
                }
            }
        }

        for (panes_value.array.items) |pane_value| {
            if (pane_value != .object) continue;
            const pane_id: WorkspacePaneId = @intCast(jsonInt(pane_value.object.get("id") orelse .null) orelse continue);
            const kind = jsonString(pane_value.object.get("kind") orelse .null) orelse continue;
            if (std.mem.eql(u8, kind, "chat")) {
                const thread_index: usize = @intCast(jsonInt(pane_value.object.get("thread") orelse .null) orelse 0);
                try next_layout.panes.append(allocator, .{
                    .id = pane_id,
                    .ref = .{ .chat = .{ .thread_index = thread_index } },
                });
            } else if (std.mem.eql(u8, kind, "terminal")) {
                const dock_id: u32 = @intCast(jsonInt(pane_value.object.get("dock") orelse .null) orelse 0);
                const purpose_label = jsonString(pane_value.object.get("purpose") orelse .null) orelse "normal";
                const purpose: TerminalPanePurpose = if (std.mem.eql(u8, purpose_label, "editor")) .editor else .normal;
                try next_layout.panes.append(allocator, .{
                    .id = pane_id,
                    .ref = .{ .terminal = .{ .dock_id = dock_id, .purpose = purpose } },
                });
            } else if (std.mem.eql(u8, kind, "browser")) {
                var browser_ref: BrowserPaneRef = .{};
                var browser_ref_owned = true;
                errdefer if (browser_ref_owned) browser_ref.deinit(allocator);
                if (pane_value.object.get("tabs")) |tabs_value| {
                    if (tabs_value == .array) for (tabs_value.array.items) |tab_value| {
                        if (tab_value != .object) continue;
                        var tab: BrowserTabRef = .{};
                        errdefer tab.deinit(allocator);
                        if (jsonString(tab_value.object.get("url") orelse .null)) |url| try tab.setUrl(allocator, url);
                        if (jsonString(tab_value.object.get("title") orelse .null)) |title| try tab.setTitle(allocator, title);
                        if (tab_value.object.get("pinned")) |pinned| tab.pinned = pinned == .bool and pinned.bool;
                        if (tab_value.object.get("history")) |history_value| if (history_value == .array) {
                            for (history_value.array.items) |entry_value| {
                                const entry = jsonString(entry_value) orelse continue;
                                try tab.appendHistoryEntry(allocator, entry);
                            }
                        };
                        if (jsonInt(tab_value.object.get("history_index") orelse .null)) |history_index| {
                            if (history_index >= 0 and @as(usize, @intCast(history_index)) < tab.history.items.len) tab.history_index = @intCast(history_index);
                        }
                        try browser_ref.tabs.append(allocator, tab);
                    };
                    if (jsonInt(pane_value.object.get("active_tab") orelse .null)) |active| {
                        if (active >= 0) browser_ref.active_tab_index = @intCast(active);
                    }
                } else {
                    // Version 2 workspaces stored one tab directly on the pane.
                    const tab = try browser_ref.ensureTab(allocator);
                    if (jsonString(pane_value.object.get("url") orelse .null)) |url| try tab.setUrl(allocator, url);
                    if (jsonString(pane_value.object.get("title") orelse .null)) |title| try tab.setTitle(allocator, title);
                    if (pane_value.object.get("history")) |history_value| if (history_value == .array) {
                        for (history_value.array.items) |entry_value| {
                            const entry = jsonString(entry_value) orelse continue;
                            try tab.appendHistoryEntry(allocator, entry);
                        }
                    };
                    if (jsonInt(pane_value.object.get("history_index") orelse .null)) |history_index| {
                        if (history_index >= 0 and @as(usize, @intCast(history_index)) < tab.history.items.len) tab.history_index = @intCast(history_index);
                    }
                }
                const active_tab = try browser_ref.ensureTab(allocator);
                if (active_tab.url == null and active_tab.history.items.len > 0) {
                    const restore_index = active_tab.history_index orelse active_tab.history.items.len - 1;
                    try active_tab.setUrl(allocator, active_tab.history.items[restore_index]);
                    active_tab.history_index = restore_index;
                }
                try next_layout.panes.append(allocator, .{
                    .id = pane_id,
                    .ref = .{ .browser = browser_ref },
                });
                browser_ref_owned = false;
            }
            if (pane_id >= next_layout.next_pane_id) next_layout.next_pane_id = pane_id + 1;
        }

        if (root_value.object.get("root")) |node_value| {
            next_layout.root = try parseWorkspaceNodeJson(allocator, node_value);
        }
        if (next_layout.panes.items.len == 0) return;
        _ = try next_layout.repairVisibleRoot(allocator);
        if (next_layout.root == null) return;

        self.deinit(allocator);
        self.* = next_layout;
    }

    pub fn applyLegacyPersistedWorkspaceJson(self: *WorkspaceLayout, allocator: std.mem.Allocator, json: []const u8) !void {
        _ = try self.ensureDefaultChat(allocator);
        if (std.mem.indexOf(u8, json, "\"terminal_visible\":true") != null) {
            _ = try self.ensureTerminalPane(allocator, 0);
        }
        if (std.mem.indexOf(u8, json, "\"focused\":\"chat\"") != null) {
            self.focusFirstVisiblePaneKind(.chat);
        } else if (std.mem.indexOf(u8, json, "\"focused\":\"terminal\"") != null) {
            self.focusFirstVisiblePaneKind(.terminal);
        }
    }

    pub fn focusFirstVisiblePaneKind(self: *WorkspaceLayout, kind: WorkspacePaneKind) void {
        for (self.panes.items) |pane| {
            switch (pane.ref) {
                .chat => if (kind == .chat) {
                    self.focused_pane_id = pane.id;
                    return;
                },
                .terminal => if (kind == .terminal) {
                    self.focused_pane_id = pane.id;
                    return;
                },
                .browser => if (kind == .browser) {
                    self.focused_pane_id = pane.id;
                    return;
                },
            }
        }
    }

    pub fn ensurePaneInRootSplit(self: *WorkspaceLayout, allocator: std.mem.Allocator, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, ratio: f32) !void {
        if (self.root) |root_node| {
            if (nodeContainsPane(root_node, pane_id)) return;
            const new_leaf = try createLeafNode(allocator, pane_id);
            errdefer destroyNode(allocator, new_leaf);
            const split = try allocator.create(WorkspaceNode);
            split.* = .{ .split = .{
                .axis = axis,
                .ratio = ratio,
                .first = root_node,
                .second = new_leaf,
            } };
            self.root = split;
            return;
        }

        self.root = try createLeafNode(allocator, pane_id);
    }

    pub fn createLeafNode(allocator: std.mem.Allocator, pane_id: WorkspacePaneId) !*WorkspaceNode {
        const node = try allocator.create(WorkspaceNode);
        node.* = .{ .leaf = pane_id };
        return node;
    }

    pub fn destroyNode(allocator: std.mem.Allocator, node: *WorkspaceNode) void {
        switch (node.*) {
            .leaf => {},
            .split => |split| {
                destroyNode(allocator, split.first);
                destroyNode(allocator, split.second);
            },
        }
        allocator.destroy(node);
    }

    pub fn nodeContainsPane(node: *const WorkspaceNode, pane_id: WorkspacePaneId) bool {
        return switch (node.*) {
            .leaf => |leaf_id| leaf_id == pane_id,
            .split => |split| nodeContainsPane(split.first, pane_id) or nodeContainsPane(split.second, pane_id),
        };
    }

    pub fn countWorkspaceNodeLeaves(node: *const WorkspaceNode) usize {
        return switch (node.*) {
            .leaf => 1,
            .split => |split| countWorkspaceNodeLeaves(split.first) + countWorkspaceNodeLeaves(split.second),
        };
    }

    const PruneRootResult = struct {
        node: ?*WorkspaceNode,
        changed: bool,
    };

    pub fn pruneRootToVisiblePanes(allocator: std.mem.Allocator, layout: *const WorkspaceLayout, node: *WorkspaceNode) PruneRootResult {
        switch (node.*) {
            .leaf => |pane_id| {
                if (layout.paneById(pane_id) != null) return .{ .node = node, .changed = false };
                allocator.destroy(node);
                return .{ .node = null, .changed = true };
            },
            .split => |split| {
                const axis = split.axis;
                const ratio = split.ratio;
                const first = pruneRootToVisiblePanes(allocator, layout, split.first);
                const second = pruneRootToVisiblePanes(allocator, layout, split.second);
                const child_changed = first.changed or second.changed;
                if (first.node) |first_node| {
                    if (second.node) |second_node| {
                        node.* = .{ .split = .{
                            .axis = axis,
                            .ratio = ratio,
                            .first = first_node,
                            .second = second_node,
                        } };
                        return .{ .node = node, .changed = child_changed };
                    }
                    allocator.destroy(node);
                    return .{ .node = first_node, .changed = true };
                }
                if (second.node) |second_node| {
                    allocator.destroy(node);
                    return .{ .node = second_node, .changed = true };
                }
                allocator.destroy(node);
                return .{ .node = null, .changed = true };
            },
        }
    }

    pub fn resizeNodeSplit(node: *WorkspaceNode, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, ratio: f32) bool {
        switch (node.*) {
            .leaf => return false,
            .split => |*split| {
                if (split.axis == axis and
                    nodeContainsPane(split.first, first_pane_id) and
                    nodeContainsPane(split.second, second_pane_id))
                {
                    split.ratio = ratio;
                    return true;
                }
                if (resizeNodeSplit(split.first, first_pane_id, second_pane_id, axis, ratio)) return true;
                return resizeNodeSplit(split.second, first_pane_id, second_pane_id, axis, ratio);
            },
        }
    }

    pub fn nudgeNodeSplitRatio(node: *WorkspaceNode, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, delta: f32) bool {
        switch (node.*) {
            .leaf => return false,
            .split => |*split| {
                if (split.axis == axis and
                    nodeContainsPane(split.first, first_pane_id) and
                    nodeContainsPane(split.second, second_pane_id))
                {
                    split.ratio = @max(0.18, @min(0.82, split.ratio + delta));
                    return true;
                }
                if (nudgeNodeSplitRatio(split.first, first_pane_id, second_pane_id, axis, delta)) return true;
                return nudgeNodeSplitRatio(split.second, first_pane_id, second_pane_id, axis, delta);
            },
        }
    }

    pub fn removePaneFromTree(allocator: std.mem.Allocator, node: *WorkspaceNode, pane_id: WorkspacePaneId) ?*WorkspaceNode {
        switch (node.*) {
            .leaf => |leaf_id| {
                if (leaf_id != pane_id) return node;
                allocator.destroy(node);
                return null;
            },
            .split => |split| {
                const first = removePaneFromTree(allocator, split.first, pane_id);
                const second = removePaneFromTree(allocator, split.second, pane_id);
                if (first) |first_node| {
                    if (second) |second_node| {
                        node.* = .{ .split = .{
                            .axis = split.axis,
                            .ratio = split.ratio,
                            .first = first_node,
                            .second = second_node,
                        } };
                        return node;
                    }
                    allocator.destroy(node);
                    return first_node;
                }
                if (second) |second_node| {
                    allocator.destroy(node);
                    return second_node;
                }
                allocator.destroy(node);
                return null;
            },
        }
    }

    pub fn splitNodeWithLeaf(
        allocator: std.mem.Allocator,
        node: *WorkspaceNode,
        target_pane_id: WorkspacePaneId,
        new_pane_id: WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        new_after: bool,
    ) !bool {
        switch (node.*) {
            .leaf => |leaf_id| {
                if (leaf_id != target_pane_id) return false;
                const old_leaf = try createLeafNode(allocator, leaf_id);
                errdefer destroyNode(allocator, old_leaf);
                const new_leaf = try createLeafNode(allocator, new_pane_id);
                errdefer destroyNode(allocator, new_leaf);
                node.* = .{ .split = .{
                    .axis = axis,
                    .ratio = 0.5,
                    .first = if (new_after) old_leaf else new_leaf,
                    .second = if (new_after) new_leaf else old_leaf,
                } };
                return true;
            },
            .split => |split| {
                if (try splitNodeWithLeaf(allocator, split.first, target_pane_id, new_pane_id, axis, new_after)) return true;
                return try splitNodeWithLeaf(allocator, split.second, target_pane_id, new_pane_id, axis, new_after);
            },
        }
    }

    pub fn writeWorkspaceNodeJson(stringify: *std.json.Stringify, node: *const WorkspaceNode) !void {
        try stringify.beginObject();
        switch (node.*) {
            .leaf => |pane_id| {
                try stringify.objectField("leaf");
                try stringify.write(pane_id);
            },
            .split => |split| {
                try stringify.objectField("split");
                try stringify.beginObject();
                try stringify.objectField("axis");
                try stringify.write(switch (split.axis) {
                    .horizontal => "horizontal",
                    .vertical => "vertical",
                });
                try stringify.objectField("ratio");
                try stringify.write(split.ratio);
                try stringify.objectField("first");
                try writeWorkspaceNodeJson(stringify, split.first);
                try stringify.objectField("second");
                try writeWorkspaceNodeJson(stringify, split.second);
                try stringify.endObject();
            },
        }
        try stringify.endObject();
    }

    pub fn parseWorkspaceNodeJson(allocator: std.mem.Allocator, value: std.json.Value) !?*WorkspaceNode {
        if (value != .object) return null;
        if (value.object.get("leaf")) |leaf_value| {
            const pane_id: WorkspacePaneId = @intCast(jsonInt(leaf_value) orelse return null);
            return try createLeafNode(allocator, pane_id);
        }
        const split_value = value.object.get("split") orelse return null;
        if (split_value != .object) return null;
        const first_value = split_value.object.get("first") orelse return null;
        const second_value = split_value.object.get("second") orelse return null;
        const first_node = (try parseWorkspaceNodeJson(allocator, first_value)) orelse return null;
        errdefer destroyNode(allocator, first_node);
        const second_node = (try parseWorkspaceNodeJson(allocator, second_value)) orelse return null;
        errdefer destroyNode(allocator, second_node);
        const axis_label = jsonString(split_value.object.get("axis") orelse .null) orelse "horizontal";
        const node = try allocator.create(WorkspaceNode);
        node.* = .{ .split = .{
            .axis = if (std.mem.eql(u8, axis_label, "vertical")) .vertical else .horizontal,
            .ratio = jsonFloat(split_value.object.get("ratio") orelse .null) orelse 0.5,
            .first = first_node,
            .second = second_node,
        } };
        return node;
    }

    pub fn jsonString(value: std.json.Value) ?[]const u8 {
        return switch (value) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn jsonBool(value: std.json.Value) ?bool {
        return switch (value) {
            .bool => |b| b,
            else => null,
        };
    }

    pub fn jsonInt(value: std.json.Value) ?i64 {
        return switch (value) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        };
    }

    pub fn jsonFloat(value: std.json.Value) ?f32 {
        return switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => null,
        };
    }
};

fn expectPaneOrder(layout: *const WorkspaceLayout, expected: []const WorkspacePaneId) !void {
    try std.testing.expectEqual(expected.len, layout.panes.items.len);
    for (expected, layout.panes.items) |expected_id, pane| {
        try std.testing.expectEqual(expected_id, pane.id);
    }
}

test "workspace layout prunes stale root leaves" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const stale_leaf = try WorkspaceLayout.createLeafNode(allocator, 999);
    const existing_root = layout.root.?;
    const split = allocator.create(WorkspaceNode) catch |err| {
        WorkspaceLayout.destroyNode(allocator, stale_leaf);
        return err;
    };
    split.* = .{ .split = .{
        .axis = .vertical,
        .ratio = 0.5,
        .first = stale_leaf,
        .second = existing_root,
    } };
    layout.root = split;

    _ = try layout.ensureDefaultChat(allocator);

    const root = layout.root orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), switch (root.*) {
        .leaf => |pane_id| pane_id,
        .split => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(@as(?WorkspacePaneId, 1), layout.focused_pane_id);
}

test "workspace layout migrates minimized panes back into the split tree" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const persisted =
        \\{"v":2,"next":3,"focused":1,"maximized":null,"panes":[
        \\{"id":1,"minimized":false,"kind":"chat","thread":0},
        \\{"id":2,"minimized":true,"kind":"terminal","dock":1}
        \\],"root":{"leaf":1}}
    ;
    try layout.applyPersistedWorkspaceJson(allocator, persisted);

    try std.testing.expectEqual(@as(usize, 2), layout.visiblePaneCount());
    try std.testing.expect(layout.rootContainsPane(1));
    try std.testing.expect(layout.rootContainsPane(2));

    const rewritten = try layout.persistedWorkspaceJson(allocator);
    defer allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "minimized") == null);
}

test "workspace layout persists floating quick pane geometry and state" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);
    layout.quick_pane = .{
        .pane_id = 1,
        .geometry = .{ .x = 0.12, .y = 0.23, .w = 0.54, .h = 0.65 },
        .visible = false,
        .maximized = true,
        .pinned = true,
    };

    const persisted = try layout.persistedWorkspaceJson(allocator);
    defer allocator.free(persisted);
    var restored = try WorkspaceLayout.initDefaultChat(allocator);
    defer restored.deinit(allocator);
    try restored.applyPersistedWorkspaceJson(allocator, persisted);

    const quick = restored.quick_pane orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), quick.pane_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.12), quick.geometry.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), quick.geometry.h, 0.0001);
    try std.testing.expect(!quick.visible);
    try std.testing.expect(quick.maximized);
    try std.testing.expect(quick.pinned);
    try std.testing.expect(restored.rootContainsPane(quick.pane_id));
}

test "detached quick pane stays out of tiled root across repair and persistence" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);
    const quick_pane_id = try layout.createTerminalPane(allocator, 7);
    layout.quick_pane = .{
        .pane_id = quick_pane_id,
        .detached = true,
        .return_focus_pane_id = 1,
    };
    layout.focused_pane_id = quick_pane_id;
    layout.maximized_pane_id = 1;

    _ = try layout.ensureDefaultChat(allocator);
    try std.testing.expectEqual(@as(usize, 1), layout.visiblePaneCount());
    try std.testing.expect(!layout.rootContainsPane(quick_pane_id));
    try std.testing.expect(!layout.hasVisiblePaneKind(.terminal));
    try std.testing.expect(layout.hasVisibleQuickPaneKind(.terminal));
    layout.quick_pane.?.visible = false;
    try std.testing.expect(!layout.hasVisibleQuickPaneKind(.terminal));
    layout.quick_pane.?.visible = true;

    const persisted = try layout.persistedWorkspaceJson(allocator);
    defer allocator.free(persisted);
    var restored = try WorkspaceLayout.initDefaultChat(allocator);
    defer restored.deinit(allocator);
    try restored.applyPersistedWorkspaceJson(allocator, persisted);

    const quick = restored.quick_pane orelse return error.TestExpectedEqual;
    try std.testing.expect(quick.detached);
    try std.testing.expectEqual(@as(?WorkspacePaneId, 1), quick.return_focus_pane_id);
    try std.testing.expect(!restored.rootContainsPane(quick.pane_id));
    try std.testing.expectEqual(@as(usize, 1), restored.visiblePaneCount());
    try std.testing.expectEqual(@as(?WorkspacePaneId, 1), restored.maximized_pane_id);
}

test "browser tabs and a detached quick pane each keep their scrolling column contract" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const browser_pane_id = try layout.ensureBrowserPane(allocator);
    const browser_pane_ref = layout.paneByIdMutable(browser_pane_id) orelse return error.TestExpectedEqual;
    const browser = switch (browser_pane_ref.ref) {
        .browser => |*ref| ref,
        else => return error.TestExpectedEqual,
    };
    try browser.tabs.append(allocator, .{});
    try browser.tabs.append(allocator, .{});

    const quick_pane_id = try layout.createTerminalPane(allocator, 7);
    layout.quick_pane = .{
        .pane_id = quick_pane_id,
        .detached = true,
        .return_focus_pane_id = browser_pane_id,
    };

    try std.testing.expectEqual(@as(usize, 3), browser.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), layout.visiblePaneCount());
    try std.testing.expect(!layout.rootContainsPane(quick_pane_id));

    const persisted = try layout.persistedWorkspaceJson(allocator);
    defer allocator.free(persisted);
    var restored = try WorkspaceLayout.initDefaultChat(allocator);
    defer restored.deinit(allocator);
    try restored.applyPersistedWorkspaceJson(allocator, persisted);

    const restored_browser_pane_ref = restored.paneByIdMutable(browser_pane_id) orelse return error.TestExpectedEqual;
    const restored_browser = switch (restored_browser_pane_ref.ref) {
        .browser => |*ref| ref,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 3), restored_browser.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), restored.visiblePaneCount());
    try std.testing.expect(restored.quick_pane.?.detached);
    try std.testing.expect(!restored.rootContainsPane(restored.quick_pane.?.pane_id));
}

test "workspace repair migrates duplicated legacy quick pane out of tiled root" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);
    const persisted =
        \\{"v":2,"next":3,"focused":2,"maximized":null,
        \\"quick":{"pane":2,"visible":true,"maximized":false,"pinned":false},
        \\"panes":[{"id":1,"kind":"chat","thread":0},{"id":2,"kind":"terminal","dock":7}],
        \\"root":{"split":{"axis":"horizontal","ratio":0.5,"first":{"leaf":1},"second":{"leaf":2}}}}
    ;
    try layout.applyPersistedWorkspaceJson(allocator, persisted);

    const quick = layout.quick_pane orelse return error.TestExpectedEqual;
    try std.testing.expect(quick.detached);
    try std.testing.expect(!layout.rootContainsPane(quick.pane_id));
    try std.testing.expect(layout.rootContainsPane(1));
    try std.testing.expectEqual(@as(usize, 1), layout.visiblePaneCount());
}

test "workspace layout grid placement follows pane hotkey order" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    var placement = layout.gridNewPanePlacement() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), placement.pane_id);
    try std.testing.expectEqual(WorkspaceSplitAxis.vertical, placement.axis);
    try std.testing.expect(placement.new_after);

    const pane2 = try layout.createTerminalPane(allocator, 10);
    try layout.splitPaneWithLeaf(allocator, placement.pane_id, pane2, placement.axis, placement.new_after);

    placement = layout.gridNewPanePlacement() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), placement.pane_id);
    try std.testing.expectEqual(WorkspaceSplitAxis.horizontal, placement.axis);
    try std.testing.expect(placement.new_after);

    const pane3 = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, placement.pane_id, pane3, placement.axis, placement.new_after);

    placement = layout.gridNewPanePlacement() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(pane2, placement.pane_id);
    try std.testing.expectEqual(WorkspaceSplitAxis.horizontal, placement.axis);
    try std.testing.expect(placement.new_after);
}

test "workspace sidebar order provides scrolling neighbors on either axis" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const second_pane_id = try layout.createTerminalPane(allocator, 10);
    try layout.splitPaneWithLeaf(allocator, 1, second_pane_id, .vertical, true);
    const middle_pane_id = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, 1, middle_pane_id, .horizontal, true);

    // Splitting pane 1 again makes root order 1,3,2 while sidebar/storage
    // order remains 1,2,3. Scrolling follows the latter.
    try std.testing.expectEqual(@as(?WorkspacePaneId, null), layout.adjacentTiledPaneIdInSidebarOrder(1, .left));
    try std.testing.expectEqual(@as(?WorkspacePaneId, second_pane_id), layout.adjacentTiledPaneIdInSidebarOrder(1, .right));
    try std.testing.expectEqual(@as(?WorkspacePaneId, 1), layout.adjacentTiledPaneIdInSidebarOrder(second_pane_id, .left));
    try std.testing.expectEqual(@as(?WorkspacePaneId, middle_pane_id), layout.adjacentTiledPaneIdInSidebarOrder(second_pane_id, .right));
    try std.testing.expectEqual(@as(?WorkspacePaneId, second_pane_id), layout.adjacentTiledPaneIdInSidebarOrder(middle_pane_id, .left));
    try std.testing.expectEqual(@as(?WorkspacePaneId, null), layout.adjacentTiledPaneIdInSidebarOrder(middle_pane_id, .right));
    try std.testing.expectEqual(@as(?WorkspacePaneId, 1), layout.adjacentTiledPaneIdInSidebarOrder(second_pane_id, .up));
    try std.testing.expectEqual(@as(?WorkspacePaneId, middle_pane_id), layout.adjacentTiledPaneIdInSidebarOrder(second_pane_id, .down));
}

test "workspace panes can be reordered by sidebar insertion slot" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const second_pane_id = try layout.createTerminalPane(allocator, 10);
    try layout.splitPaneWithLeaf(allocator, 1, second_pane_id, .vertical, true);
    const third_pane_id = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, second_pane_id, third_pane_id, .vertical, true);
    layout.focused_pane_id = second_pane_id;
    layout.scroll_revealed_pane_id = second_pane_id;

    try std.testing.expect(layout.movePaneBefore(third_pane_id, 0));
    try std.testing.expectEqual(third_pane_id, layout.panes.items[0].id);
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), layout.panes.items[1].id);
    try std.testing.expectEqual(second_pane_id, layout.panes.items[2].id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, second_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, null), layout.scroll_revealed_pane_id);

    try std.testing.expect(layout.movePaneBefore(third_pane_id, layout.panes.items.len));
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), layout.panes.items[0].id);
    try std.testing.expectEqual(second_pane_id, layout.panes.items[1].id);
    try std.testing.expectEqual(third_pane_id, layout.panes.items[2].id);
    try std.testing.expect(!layout.movePaneBefore(second_pane_id, 2));
}

test "new workspace panes are inserted immediately after focus" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const trailing_terminal_id = try layout.createTerminalPane(allocator, 10);
    layout.focused_pane_id = 1;
    const chat_id = try layout.createChatPane(allocator, 1);
    try expectPaneOrder(&layout, &.{ 1, chat_id, trailing_terminal_id });

    layout.focused_pane_id = 1;
    const browser_id = try layout.ensureBrowserPane(allocator);
    try expectPaneOrder(&layout, &.{ 1, browser_id, chat_id, trailing_terminal_id });

    layout.focused_pane_id = chat_id;
    const editor_terminal_id = try layout.createTerminalPaneWithPurpose(allocator, 11, .editor);
    try expectPaneOrder(&layout, &.{ 1, browser_id, chat_id, editor_terminal_id, trailing_terminal_id });

    layout.focused_pane_id = 9999;
    const fallback_terminal_id = try layout.createTerminalPane(allocator, 12);
    try std.testing.expectEqual(fallback_terminal_id, layout.panes.items[layout.panes.items.len - 1].id);
}

test "workspace layout persists the scrolling target" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);
    layout.scroll_offset_x = 48.0;
    layout.scroll_target_x = 173.5;
    layout.scroll_offset_y = 24.0;
    layout.scroll_target_y = 96.25;
    layout.requestLeadingScrollReveal(1);
    layout.scroll_animation_last_ms = 900;

    try std.testing.expectEqual(@as(?WorkspacePaneId, 1), layout.scroll_leading_pane_id);

    const persisted = try layout.persistedWorkspaceJson(allocator);
    defer allocator.free(persisted);
    var restored = try WorkspaceLayout.initDefaultChat(allocator);
    defer restored.deinit(allocator);
    try restored.applyPersistedWorkspaceJson(allocator, persisted);

    try std.testing.expectApproxEqAbs(@as(f32, 173.5), restored.scroll_target_x, 0.0001);
    try std.testing.expectApproxEqAbs(restored.scroll_target_x, restored.scroll_offset_x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 96.25), restored.scroll_target_y, 0.0001);
    try std.testing.expectApproxEqAbs(restored.scroll_target_y, restored.scroll_offset_y, 0.0001);
    try std.testing.expectEqual(@as(?WorkspacePaneId, null), restored.scroll_revealed_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, null), restored.scroll_leading_pane_id);
    try std.testing.expectEqual(@as(i64, 0), restored.scroll_animation_last_ms);
}

test "workspace layout persists scrolling policy overrides" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);
    layout.scroll_mode_override = .always;
    layout.scroll_threshold_override = 8;
    layout.scroll_pane_extent_override = 720.0;
    layout.scroll_pane_extent_ratio_override = 0.45;

    const persisted = try layout.persistedWorkspaceJson(allocator);
    defer allocator.free(persisted);
    var restored = try WorkspaceLayout.initDefaultChat(allocator);
    defer restored.deinit(allocator);
    try restored.applyPersistedWorkspaceJson(allocator, persisted);

    try std.testing.expect(restored.hasScrollOverride());
    try std.testing.expectEqual(app_config.WorkspaceScrollMode.always, restored.effectiveScrollMode(.automatic));
    try std.testing.expectEqual(@as(u8, 8), restored.effectiveScrollThreshold(2));
    try std.testing.expectApproxEqAbs(@as(f32, 720.0), restored.scroll_pane_extent_override.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), restored.scroll_pane_extent_ratio_override.?, 0.0001);
}

test "workspace layout ignores invalid scrolling policy overrides" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);
    const persisted =
        \\{"v":2,"next":2,"focused":1,"maximized":null,"scroll_mode":"sometimes","scroll_threshold":0,"scroll_pane_extent":20,"scroll_pane_extent_ratio":0,
        \\"panes":[{"id":1,"kind":"chat","thread":0}],"root":{"leaf":1}}
    ;
    try layout.applyPersistedWorkspaceJson(allocator, persisted);

    try std.testing.expect(!layout.hasScrollOverride());
    try std.testing.expectEqual(app_config.WorkspaceScrollMode.disabled, layout.effectiveScrollMode(.disabled));
    try std.testing.expectEqual(@as(u8, 4), layout.effectiveScrollThreshold(4));
    try std.testing.expectEqual(@as(?f32, null), layout.scroll_pane_extent_override);
    try std.testing.expectEqual(@as(?f32, null), layout.scroll_pane_extent_ratio_override);
}

test "closing a maximized pane transfers zoom in sidebar order" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const first_pane_id = layout.panes.items[0].id;
    const second_pane_id = try layout.createTerminalPane(allocator, 10);
    try layout.splitPaneWithLeaf(allocator, first_pane_id, second_pane_id, .vertical, true);
    const third_pane_id = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, second_pane_id, third_pane_id, .horizontal, true);

    layout.focused_pane_id = second_pane_id;
    layout.maximized_pane_id = second_pane_id;
    var removed_ref = layout.closePane(allocator, second_pane_id) orelse return error.TestExpectedEqual;
    deinitWorkspacePaneRef(&removed_ref, allocator);
    try std.testing.expectEqual(@as(?WorkspacePaneId, third_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, third_pane_id), layout.maximized_pane_id);

    removed_ref = layout.closePane(allocator, third_pane_id) orelse return error.TestExpectedEqual;
    deinitWorkspacePaneRef(&removed_ref, allocator);
    try std.testing.expectEqual(@as(?WorkspacePaneId, first_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, first_pane_id), layout.maximized_pane_id);
}

test "closing a maximized pane focuses the next quick pane without losing tiled zoom" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const first_pane_id = layout.panes.items[0].id;
    const quick_pane_id = try layout.createTerminalPane(allocator, 10);
    const tiled_pane_id = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, first_pane_id, tiled_pane_id, .vertical, true);
    layout.quick_pane = .{
        .pane_id = quick_pane_id,
        .visible = false,
        .detached = true,
        .return_focus_pane_id = first_pane_id,
    };
    layout.focused_pane_id = first_pane_id;
    layout.maximized_pane_id = first_pane_id;

    var removed_ref = layout.closePane(allocator, first_pane_id) orelse return error.TestExpectedEqual;
    deinitWorkspacePaneRef(&removed_ref, allocator);
    try std.testing.expectEqual(@as(?WorkspacePaneId, quick_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, tiled_pane_id), layout.maximized_pane_id);
    try std.testing.expect(layout.quick_pane.?.visible);
    try std.testing.expectEqual(@as(?WorkspacePaneId, tiled_pane_id), layout.quick_pane.?.return_focus_pane_id);
}

test "workspace chat replacement prefers the focused chat pane" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const second_pane_id = try layout.createChatPane(allocator, 1);
    try layout.splitPaneWithLeaf(allocator, 1, second_pane_id, .vertical, true);
    layout.focused_pane_id = second_pane_id;

    try std.testing.expectEqual(@as(?WorkspacePaneId, second_pane_id), layout.retargetPreferredChatPane(2));
    const first_pane = layout.paneById(1) orelse return error.TestExpectedEqual;
    const second_pane = layout.paneById(second_pane_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), first_pane.ref.chat.thread_index);
    try std.testing.expectEqual(@as(usize, 2), second_pane.ref.chat.thread_index);
}
