const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("zsdl3");
const ghostty_vt = @import("../vendor/ghostty_vt.zig");
const keybinds = @import("../keybinds.zig");

const log = std.log.scoped(.native_terminal);

pub const DEFAULT_DOCK_HEIGHT: f32 = 136.0;
pub const MIN_DOCK_HEIGHT: f32 = 96.0;
pub const MAX_DOCK_HEIGHT: f32 = 900.0;

const SESSION_SUPPORTED = builtin.os.tag == .linux or builtin.os.tag == .macos;
const INITIAL_COLS: u16 = 96;
const INITIAL_ROWS: u16 = 12;
const MIN_COLS: u16 = 24;
const MIN_ROWS: u16 = 4;
const MAX_COLS: u16 = 320;
const MAX_ROWS: u16 = 120;
pub const CELL_PIXEL_WIDTH: u32 = 9;
pub const CELL_PIXEL_HEIGHT: u32 = 18;
const DEFAULT_FONT_SCALE: f32 = 1.0;
const MIN_FONT_SCALE: f32 = 0.75;
const MAX_FONT_SCALE: f32 = 2.0;
const FONT_SCALE_STEP: f32 = 0.125;
const WHEEL_SCROLL_LINES: f32 = 3.0;
// Darwin exposes the winsize setter under the BSD ioctl value, not std.c.T.IOCSWINSZ.
const TERMINAL_WINSIZE_IOCTL: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x80087467)),
    else => @intCast(std.c.T.IOCSWINSZ),
};
const TerminalStream = @TypeOf((@as(*ghostty_vt.Terminal, undefined)).vtStream());
const TerminalHandler = @TypeOf((@as(*ghostty_vt.Terminal, undefined)).vtHandler());
const DeviceAttributes = @typeInfo(
    std.meta.Child(std.meta.Child(@TypeOf(TerminalHandler.Effects.readonly.device_attributes))),
).@"fn".return_type.?;
const ColorScheme = std.meta.Child(
    @typeInfo(
        std.meta.Child(std.meta.Child(@TypeOf(TerminalHandler.Effects.readonly.color_scheme))),
    ).@"fn".return_type.?,
);
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Session = if (SESSION_SUPPORTED) UnixSession else UnsupportedSession;
pub const MIN_SPLIT_RATIO: f32 = 0.12;

pub const SplitAxis = enum(u8) {
    horizontal,
    vertical,
};

pub const SplitDirection = enum(u8) {
    up,
    down,
    left,
    right,
};

pub const TerminalLaunchKind = enum(u8) {
    shell,
    claude,
    opencode,
    codex,
    cursor,
    custom,
};

pub const TerminalLaunchProfile = struct {
    kind: TerminalLaunchKind = .shell,
    label: []const u8 = "",
    command: []const []const u8 = &.{},
};

const SessionCreateOptions = struct {
    cwd: []const u8,
    cols: u16,
    rows: u16,
    profile: TerminalLaunchProfile = .{},
};

pub const PersistedWorkspace = struct {
    active_tab_index: usize = 0,
    tabs: []const PersistedTab = &.{},
};

pub const PersistedTab = struct {
    title: ?[]const u8 = null,
    active_pane_id: u32 = 0,
    root_node_id: u32 = 0,
    nodes: []const PersistedNode = &.{},
};

pub const PersistedNodeKind = enum(u8) {
    leaf,
    split,
};

pub const PersistedNode = struct {
    node_id: u32,
    kind: PersistedNodeKind,
    pane_id: u32 = 0,
    axis: ?SplitAxis = null,
    ratio: ?f32 = null,
    first_node_id: ?u32 = null,
    second_node_id: ?u32 = null,
};

pub const PaneLeaf = struct {
    id: u32,
    session: ?*Session = null,
};

pub const PaneSplit = struct {
    axis: SplitAxis,
    ratio: f32 = 0.5,
    first: *PaneNode,
    second: *PaneNode,
};

pub const PaneNode = union(enum) {
    leaf: PaneLeaf,
    split: PaneSplit,
};

const PaneRect = struct {
    pane_id: u32,
    min: [2]f32,
    max: [2]f32,
};

const PaneFocusCandidate = struct {
    pane_id: u32,
    overlap: f32,
    primary_distance: f32,
    secondary_distance: f32,
};

pub const Tab = struct {
    id: u32,
    title: ?[]u8 = null,
    root: *PaneNode,
    active_pane_id: u32,

    fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        deinitPaneNode(self.root, allocator);
    }
};

pub const Dock = struct {
    visible: bool = false,
    preferred_height: f32 = DEFAULT_DOCK_HEIGHT,
    font_scale: f32 = DEFAULT_FONT_SCALE,
    cwd: ?[]u8 = null,
    tabs: std.ArrayList(Tab) = .empty,
    active_tab_index: usize = 0,
    next_tab_id: u32 = 1,
    next_pane_id: u32 = 1,
    rename_tab_id: ?u32 = null,
    rename_storage: [96:0]u8 = std.mem.zeroes([96:0]u8),
    workspace_changed: bool = false,
    focus_requested: bool = false,
    launch_profile: TerminalLaunchProfile = .{},

    pub fn init(_: std.mem.Allocator) !Dock {
        return .{};
    }

    pub fn deinit(self: *Dock, allocator: std.mem.Allocator) void {
        if (self.cwd) |cwd| {
            allocator.free(cwd);
            self.cwd = null;
        }
        for (self.tabs.items) |*tab| {
            tab.deinit(allocator);
        }
        self.tabs.deinit(allocator);
    }

    pub fn toggle(self: *Dock) bool {
        self.visible = !self.visible;
        if (self.visible) self.focus_requested = true;
        return self.visible;
    }

    pub fn statusText(self: *const Dock, buf: *[192]u8) []const u8 {
        if (!SESSION_SUPPORTED) {
            return "Native shell embedding is only enabled on Linux and macOS.";
        }
        if (self.activePaneConst()) |pane| {
            if (pane.session) |session| {
                return session.statusText(buf);
            }
        }
        return if (self.visible) "Starting shell..." else "Hidden until toggled.";
    }

    pub fn effectiveHeight(self: *const Dock, available_height: f32) f32 {
        return clampHeightForAvailable(self.preferred_height, available_height);
    }

    pub fn setPreferredHeight(self: *Dock, available_height: f32, requested_height: f32) bool {
        const next_height = clampHeightForAvailable(requested_height, available_height);
        if (@abs(self.preferred_height - next_height) < 0.5) return false;
        self.preferred_height = next_height;
        return true;
    }

    pub fn ensureSession(self: *Dock, allocator: std.mem.Allocator, project_path: []const u8) !void {
        const cwd_changed = if (self.cwd) |cwd|
            !std.mem.eql(u8, cwd, project_path)
        else
            true;

        if (cwd_changed) {
            if (self.cwd) |cwd| allocator.free(cwd);
            self.cwd = try allocator.dupe(u8, project_path);
        }

        try self.ensureWorkspace(allocator);
    }

    pub fn poll(self: *Dock, allocator: std.mem.Allocator) !void {
        for (self.tabs.items) |*tab| {
            try pollPaneNode(tab.root, allocator);
        }
    }

    pub fn resizePaneToFit(self: *Dock, allocator: std.mem.Allocator, pane_id: u32, width: f32, height: f32) !void {
        const pane = self.findPaneById(pane_id) orelse return;
        if (pane.session) |session| {
            const cols = columnsForWidth(width, self.font_scale);
            const rows = rowsForHeight(height, self.font_scale);
            if (cols == 0 or rows == 0) {
                log.warn("skipping terminal resize for invalid pane size width={d:.2} height={d:.2}", .{ width, height });
                return;
            }
            try session.resize(
                allocator,
                cols,
                rows,
                scaledCellPixelWidth(self.font_scale),
                scaledCellPixelHeight(self.font_scale),
            );
        }
    }

    pub fn activeRenderState(self: *const Dock) ?*const ghostty_vt.RenderState {
        if (self.activePaneConst()) |pane| {
            if (pane.session) |session| return session.renderState();
        }
        return null;
    }

    pub fn renderStateForPane(self: *const Dock, pane_id: u32) ?*const ghostty_vt.RenderState {
        const pane = self.findPaneByIdConst(pane_id) orelse return null;
        if (pane.session) |session| return session.renderState();
        return null;
    }

    pub fn hasRunningSession(self: *const Dock) bool {
        for (self.tabs.items) |*tab| {
            if (paneNodeHasRunningSession(tab.root)) return true;
        }
        return false;
    }

    pub fn takeFocusRequest(self: *Dock) bool {
        const requested = self.focus_requested;
        self.focus_requested = false;
        return requested;
    }

    pub fn consumeWorkspaceChange(self: *Dock) bool {
        const changed = self.workspace_changed;
        self.workspace_changed = false;
        return changed;
    }

    pub fn handleTextInput(self: *Dock, input_text: []const u8) bool {
        if (input_text.len == 0 or isAsciiTerminalText(input_text)) return false;
        if (self.activePane()) |pane| {
            if (pane.session) |session| {
                return session.writeInput(input_text) catch |err| {
                    log.warn("terminal text input failed: {s}", .{@errorName(err)});
                    return false;
                };
            }
        }
        return false;
    }

    pub fn handleKeyDown(
        self: *Dock,
        allocator: std.mem.Allocator,
        keyboard: *const keybinds.NativeKeyboardConfig,
        event: *const sdl.KeyboardEvent,
    ) bool {
        if (terminalZoomDelta(event)) |delta| {
            self.font_scale = clampf(self.font_scale + delta, MIN_FONT_SCALE, MAX_FONT_SCALE);
            return true;
        }

        if (self.handleWorkspaceShortcut(allocator, keyboard, event) catch |err| {
            log.warn("terminal workspace shortcut failed: {s}", .{@errorName(err)});
            return false;
        }) {
            return true;
        }

        if (self.activePane()) |pane| {
            if (pane.session) |session| {
                return session.handleKeyDown(event) catch |err| {
                    log.warn("terminal key input failed: {s}", .{@errorName(err)});
                    return false;
                };
            }
        }
        return false;
    }

    pub fn handleWheel(self: *Dock, allocator: std.mem.Allocator, pane_id: u32, wheel_y: f32) bool {
        const pane = self.findPaneById(pane_id) orelse return false;
        if (pane.session) |session| {
            return session.handleWheel(allocator, wheel_y) catch |err| {
                log.warn("terminal wheel scroll failed: {s}", .{@errorName(err)});
                return false;
            };
        }
        return false;
    }

    pub fn activeTab(self: *Dock) ?*Tab {
        if (self.tabs.items.len == 0 or self.active_tab_index >= self.tabs.items.len) return null;
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn activeTabConst(self: *const Dock) ?*const Tab {
        if (self.tabs.items.len == 0 or self.active_tab_index >= self.tabs.items.len) return null;
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn activePane(self: *Dock) ?*PaneLeaf {
        const tab = self.activeTab() orelse return null;
        return findPaneLeaf(tab.root, tab.active_pane_id) orelse findFirstPaneLeaf(tab.root);
    }

    pub fn activePaneConst(self: *const Dock) ?*const PaneLeaf {
        const tab = self.activeTabConst() orelse return null;
        return findPaneLeafConst(tab.root, tab.active_pane_id) orelse findFirstPaneLeafConst(tab.root);
    }

    pub fn focusPane(self: *Dock, pane_id: u32) void {
        const tab = self.activeTab() orelse return;
        if (findPaneLeaf(tab.root, pane_id) == null) return;
        tab.active_pane_id = pane_id;
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn focusAdjacentPane(self: *Dock, allocator: std.mem.Allocator, direction: SplitDirection) !bool {
        const tab = self.activeTab() orelse return false;
        const next_pane_id = try findAdjacentPaneId(allocator, tab.root, tab.active_pane_id, direction) orelse return false;
        if (next_pane_id == tab.active_pane_id) return false;
        tab.active_pane_id = next_pane_id;
        self.workspace_changed = true;
        self.focus_requested = true;
        return true;
    }

    pub fn selectTab(self: *Dock, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.active_tab_index = index;
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn createTab(self: *Dock, allocator: std.mem.Allocator) !void {
        try self.tabs.append(allocator, try self.buildSinglePaneTab(allocator));
        self.active_tab_index = self.tabs.items.len - 1;
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn createTabWithProfile(self: *Dock, allocator: std.mem.Allocator, profile: TerminalLaunchProfile) !void {
        const previous_profile = self.launch_profile;
        self.launch_profile = profile;
        defer self.launch_profile = previous_profile;
        try self.createTab(allocator);
    }

    pub fn closeTab(self: *Dock, allocator: std.mem.Allocator, index: usize) !void {
        if (index >= self.tabs.items.len) return;
        var removed = self.tabs.orderedRemove(index);
        removed.deinit(allocator);
        if (self.tabs.items.len == 0) {
            try self.tabs.append(allocator, try self.buildSinglePaneTab(allocator));
            self.active_tab_index = 0;
        } else if (self.active_tab_index >= self.tabs.items.len) {
            self.active_tab_index = self.tabs.items.len - 1;
        } else if (index <= self.active_tab_index and self.active_tab_index > 0) {
            self.active_tab_index -= 1;
        }
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn closeActiveTab(self: *Dock, allocator: std.mem.Allocator) !void {
        if (self.active_tab_index >= self.tabs.items.len) return;
        try self.closeTab(allocator, self.active_tab_index);
    }

    pub fn splitActivePane(self: *Dock, allocator: std.mem.Allocator, direction: SplitDirection) !void {
        const tab = self.activeTab() orelse return;
        tab.active_pane_id = try self.replacePaneWithSplit(allocator, tab.root, tab.active_pane_id, direction);
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn closeActivePaneOrTab(self: *Dock, allocator: std.mem.Allocator) !void {
        const tab = self.activeTab() orelse return;
        if (isSinglePaneTree(tab.root)) {
            if (self.tabs.items.len > 1) try self.closeActiveTab(allocator);
            return;
        }
        try self.closeActivePane(allocator);
    }

    pub fn closeActivePane(self: *Dock, allocator: std.mem.Allocator) !void {
        const tab = self.activeTab() orelse return;
        if (isSinglePaneTree(tab.root)) return;
        try removePaneFromTree(allocator, &tab.root, tab.active_pane_id);
        if (findPaneLeaf(tab.root, tab.active_pane_id) == null) {
            if (findFirstPaneLeaf(tab.root)) |leaf| tab.active_pane_id = leaf.id;
        }
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn tabTitle(self: *const Dock, index: usize, buffer: *[96]u8) []const u8 {
        if (index >= self.tabs.items.len) return "";
        const tab = &self.tabs.items[index];
        if (tab.title) |tab_title| return tab_title;
        if (findPaneLeafConst(tab.root, tab.active_pane_id) orelse findFirstPaneLeafConst(tab.root)) |pane| {
            if (pane.session) |session| return session.tabTitle(buffer);
        }
        if (self.cwd) |cwd| return pathLabel(cwd);
        return "Shell";
    }

    pub fn beginRenameTab(self: *Dock, tab_id: u32) void {
        self.rename_tab_id = tab_id;
        @memset(&self.rename_storage, 0);
        if (self.findTabIndexById(tab_id)) |index| {
            var title_buf: [96]u8 = undefined;
            const tab_label = self.tabTitle(index, &title_buf);
            const len = @min(tab_label.len, self.rename_storage.len - 1);
            @memcpy(self.rename_storage[0..len], tab_label[0..len]);
        }
    }

    pub fn cancelRenameTab(self: *Dock) void {
        self.rename_tab_id = null;
        self.rename_storage[0] = 0;
    }

    pub fn renameBuffer(self: *Dock) [:0]u8 {
        return self.rename_storage[0 .. self.rename_storage.len - 1 :0];
    }

    pub fn finishRenameTab(self: *Dock, allocator: std.mem.Allocator) !void {
        const tab_id = self.rename_tab_id orelse return;
        const index = self.findTabIndexById(tab_id) orelse {
            self.cancelRenameTab();
            return;
        };
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(self.rename_storage[0..], 0), &std.ascii.whitespace);
        var tab = &self.tabs.items[index];
        if (tab.title) |tab_title| {
            allocator.free(tab_title);
            tab.title = null;
        }
        if (trimmed.len > 0) {
            tab.title = try allocator.dupe(u8, trimmed);
        }
        self.workspace_changed = true;
        self.cancelRenameTab();
    }

    pub fn persistedLayoutJson(self: *const Dock, allocator: std.mem.Allocator) !?[]u8 {
        if (self.tabs.items.len == 0) return null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var persisted_tabs: std.ArrayList(PersistedTab) = .empty;
        defer persisted_tabs.deinit(arena_allocator);

        for (self.tabs.items) |tab| {
            var nodes: std.ArrayList(PersistedNode) = .empty;
            defer nodes.deinit(arena_allocator);
            var next_node_id: u32 = 1;
            const root_node_id = try serializePaneNode(arena_allocator, tab.root, &nodes, &next_node_id);
            try persisted_tabs.append(arena_allocator, .{
                .title = if (tab.title) |tab_title| try arena_allocator.dupe(u8, tab_title) else null,
                .active_pane_id = tab.active_pane_id,
                .root_node_id = root_node_id,
                .nodes = try nodes.toOwnedSlice(arena_allocator),
            });
        }

        return try std.json.Stringify.valueAlloc(allocator, PersistedWorkspace{
            .active_tab_index = self.active_tab_index,
            .tabs = try persisted_tabs.toOwnedSlice(arena_allocator),
        }, .{});
    }

    pub fn applyPersistedLayoutJson(self: *Dock, allocator: std.mem.Allocator, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(PersistedWorkspace, allocator, json, .{});
        defer parsed.deinit();

        self.clearTabs(allocator);

        var max_pane_id: u32 = 0;
        for (parsed.value.tabs) |persisted_tab| {
            const root = try buildPaneNodeFromPersisted(allocator, persisted_tab.nodes, persisted_tab.root_node_id, &max_pane_id);
            var tab = Tab{
                .id = self.allocateTabId(),
                .title = if (persisted_tab.title) |tab_title| try allocator.dupe(u8, tab_title) else null,
                .root = root,
                .active_pane_id = persisted_tab.active_pane_id,
            };
            if (findPaneLeaf(root, tab.active_pane_id) == null) {
                if (findFirstPaneLeaf(root)) |leaf| tab.active_pane_id = leaf.id;
            }
            try self.tabs.append(allocator, tab);
        }

        if (self.tabs.items.len == 0) {
            try self.tabs.append(allocator, try self.buildSinglePaneTabWithoutSession(allocator));
        }

        self.active_tab_index = @min(parsed.value.active_tab_index, self.tabs.items.len - 1);
        self.next_pane_id = @max(self.next_pane_id, max_pane_id + 1);
    }

    fn ensureWorkspace(self: *Dock, allocator: std.mem.Allocator) !void {
        if (self.tabs.items.len == 0) {
            try self.tabs.append(allocator, try self.buildSinglePaneTabWithoutSession(allocator));
        }
        for (self.tabs.items) |*tab| {
            try self.ensureSessionsInNode(allocator, tab.root);
            if (findPaneLeaf(tab.root, tab.active_pane_id) == null) {
                if (findFirstPaneLeaf(tab.root)) |leaf| tab.active_pane_id = leaf.id;
            }
        }
        if (self.active_tab_index >= self.tabs.items.len) {
            self.active_tab_index = self.tabs.items.len - 1;
        }
    }

    fn clearTabs(self: *Dock, allocator: std.mem.Allocator) void {
        for (self.tabs.items) |*tab| tab.deinit(allocator);
        self.tabs.clearRetainingCapacity();
        self.active_tab_index = 0;
        self.rename_tab_id = null;
    }

    fn buildSinglePaneTab(self: *Dock, allocator: std.mem.Allocator) !Tab {
        const tab = try self.buildSinglePaneTabWithoutSession(allocator);
        try self.ensureSessionsInNode(allocator, tab.root);
        return tab;
    }

    fn buildSinglePaneTabWithoutSession(self: *Dock, allocator: std.mem.Allocator) !Tab {
        const root = try self.createLeafNode(allocator, false);
        return .{
            .id = self.allocateTabId(),
            .title = null,
            .root = root,
            .active_pane_id = root.leaf.id,
        };
    }

    fn createLeafNode(self: *Dock, allocator: std.mem.Allocator, ensure_session: bool) !*PaneNode {
        const node = try allocator.create(PaneNode);
        node.* = .{ .leaf = .{ .id = self.allocatePaneId(), .session = null } };
        if (ensure_session) {
            try self.ensureLeafSession(allocator, &node.leaf);
        }
        return node;
    }

    fn ensureLeafSession(self: *Dock, allocator: std.mem.Allocator, leaf: *PaneLeaf) !void {
        if (leaf.session != null) return;
        const cwd = self.cwd orelse return;
        leaf.session = try Session.create(allocator, .{
            .cwd = cwd,
            .cols = INITIAL_COLS,
            .rows = INITIAL_ROWS,
            .profile = self.launch_profile,
        });
    }

    fn ensureSessionsInNode(self: *Dock, allocator: std.mem.Allocator, node: *PaneNode) !void {
        switch (node.*) {
            .leaf => |*leaf| try self.ensureLeafSession(allocator, leaf),
            .split => |*split| {
                try self.ensureSessionsInNode(allocator, split.first);
                try self.ensureSessionsInNode(allocator, split.second);
            },
        }
    }

    fn allocateTabId(self: *Dock) u32 {
        const id = self.next_tab_id;
        self.next_tab_id += 1;
        return id;
    }

    fn allocatePaneId(self: *Dock) u32 {
        const id = self.next_pane_id;
        self.next_pane_id += 1;
        return id;
    }

    fn findTabIndexById(self: *const Dock, tab_id: u32) ?usize {
        for (self.tabs.items, 0..) |tab, index| {
            if (tab.id == tab_id) return index;
        }
        return null;
    }

    fn findPaneById(self: *Dock, pane_id: u32) ?*PaneLeaf {
        for (self.tabs.items) |*tab| {
            if (findPaneLeaf(tab.root, pane_id)) |leaf| return leaf;
        }
        return null;
    }

    fn findPaneByIdConst(self: *const Dock, pane_id: u32) ?*const PaneLeaf {
        for (self.tabs.items) |*tab| {
            if (findPaneLeafConst(tab.root, pane_id)) |leaf| return leaf;
        }
        return null;
    }

    fn replacePaneWithSplit(self: *Dock, allocator: std.mem.Allocator, node: *PaneNode, target_pane_id: u32, direction: SplitDirection) !u32 {
        return switch (node.*) {
            .leaf => |leaf| blk: {
                if (leaf.id != target_pane_id) break :blk error.PaneNotFound;

                const existing_leaf_node = try allocator.create(PaneNode);
                existing_leaf_node.* = .{ .leaf = leaf };
                const new_leaf_node = try self.createLeafNode(allocator, true);
                const new_pane_id = new_leaf_node.leaf.id;
                node.* = .{
                    .split = .{
                        .axis = axisForDirection(direction),
                        .ratio = 0.5,
                        .first = if (direction == .left or direction == .up) new_leaf_node else existing_leaf_node,
                        .second = if (direction == .left or direction == .up) existing_leaf_node else new_leaf_node,
                    },
                };
                break :blk new_pane_id;
            },
            .split => |*split| {
                if (paneNodeContains(split.first, target_pane_id)) {
                    return try self.replacePaneWithSplit(allocator, split.first, target_pane_id, direction);
                }
                if (paneNodeContains(split.second, target_pane_id)) {
                    return try self.replacePaneWithSplit(allocator, split.second, target_pane_id, direction);
                }
                return error.PaneNotFound;
            },
        };
    }

    fn handleWorkspaceShortcut(
        self: *Dock,
        allocator: std.mem.Allocator,
        keyboard: *const keybinds.NativeKeyboardConfig,
        event: *const sdl.KeyboardEvent,
    ) !bool {
        const action = keyboard.terminalActionForEvent(event) orelse return false;
        switch (action) {
            .new_tab => try self.createTab(allocator),
            .close_active => try self.closeActivePaneOrTab(allocator),
            .rename_tab => if (self.activeTab()) |tab| self.beginRenameTab(tab.id),
            .tab_previous => if (self.active_tab_index > 0) self.selectTab(self.active_tab_index - 1),
            .tab_next => if (self.active_tab_index + 1 < self.tabs.items.len) self.selectTab(self.active_tab_index + 1),
            .split_up => try self.splitActivePane(allocator, .up),
            .split_down => try self.splitActivePane(allocator, .down),
            .split_left => try self.splitActivePane(allocator, .left),
            .split_right => try self.splitActivePane(allocator, .right),
            .focus_up => _ = try self.focusAdjacentPane(allocator, .up),
            .focus_down => _ = try self.focusAdjacentPane(allocator, .down),
            .focus_left => _ = try self.focusAdjacentPane(allocator, .left),
            .focus_right => _ = try self.focusAdjacentPane(allocator, .right),
        }
        return true;
    }
};

fn deinitPaneNode(node: *PaneNode, allocator: std.mem.Allocator) void {
    switch (node.*) {
        .leaf => |*leaf| {
            if (leaf.session) |session| {
                session.deinit(allocator);
                allocator.destroy(session);
                leaf.session = null;
            }
            allocator.destroy(node);
        },
        .split => |*split| {
            deinitPaneNode(split.first, allocator);
            deinitPaneNode(split.second, allocator);
            allocator.destroy(node);
        },
    }
}

fn pollPaneNode(node: *PaneNode, allocator: std.mem.Allocator) !void {
    switch (node.*) {
        .leaf => |*leaf| {
            if (leaf.session) |session| try session.poll(allocator);
        },
        .split => |*split| {
            try pollPaneNode(split.first, allocator);
            try pollPaneNode(split.second, allocator);
        },
    }
}

fn paneNodeHasRunningSession(node: *const PaneNode) bool {
    return switch (node.*) {
        .leaf => |leaf| if (leaf.session) |session| session.isRunning() else false,
        .split => |split| paneNodeHasRunningSession(split.first) or paneNodeHasRunningSession(split.second),
    };
}

fn findPaneLeaf(node: *PaneNode, pane_id: u32) ?*PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| if (leaf.id == pane_id) leaf else null,
        .split => |*split| findPaneLeaf(split.first, pane_id) orelse findPaneLeaf(split.second, pane_id),
    };
}

fn findPaneLeafConst(node: *const PaneNode, pane_id: u32) ?*const PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| if (leaf.id == pane_id) leaf else null,
        .split => |*split| findPaneLeafConst(split.first, pane_id) orelse findPaneLeafConst(split.second, pane_id),
    };
}

fn findFirstPaneLeaf(node: *PaneNode) ?*PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| leaf,
        .split => |*split| findFirstPaneLeaf(split.first) orelse findFirstPaneLeaf(split.second),
    };
}

fn findFirstPaneLeafConst(node: *const PaneNode) ?*const PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| leaf,
        .split => |*split| findFirstPaneLeafConst(split.first) orelse findFirstPaneLeafConst(split.second),
    };
}

fn paneNodeContains(node: *PaneNode, pane_id: u32) bool {
    return findPaneLeaf(node, pane_id) != null;
}

fn isSinglePaneTree(node: *const PaneNode) bool {
    return switch (node.*) {
        .leaf => true,
        .split => false,
    };
}

fn removePaneFromTree(allocator: std.mem.Allocator, root: **PaneNode, pane_id: u32) !void {
    const node = root.*;
    switch (node.*) {
        .leaf => return,
        .split => |*split| {
            if (paneNodeContains(split.first, pane_id)) {
                if (split.first.* == .leaf and split.first.leaf.id == pane_id) {
                    deinitPaneNode(split.first, allocator);
                    const sibling = split.second;
                    allocator.destroy(node);
                    root.* = sibling;
                    return;
                }
                return removePaneFromTree(allocator, &split.first, pane_id);
            }
            if (paneNodeContains(split.second, pane_id)) {
                if (split.second.* == .leaf and split.second.leaf.id == pane_id) {
                    deinitPaneNode(split.second, allocator);
                    const sibling = split.first;
                    allocator.destroy(node);
                    root.* = sibling;
                    return;
                }
                return removePaneFromTree(allocator, &split.second, pane_id);
            }
        },
    }
}

fn findAdjacentPaneId(
    allocator: std.mem.Allocator,
    root: *const PaneNode,
    current_pane_id: u32,
    direction: SplitDirection,
) !?u32 {
    var pane_rects: std.ArrayList(PaneRect) = .empty;
    defer pane_rects.deinit(allocator);
    try collectPaneRects(allocator, root, .{ 0.0, 0.0 }, .{ 1.0, 1.0 }, &pane_rects);

    var current_rect: ?PaneRect = null;
    for (pane_rects.items) |pane_rect| {
        if (pane_rect.pane_id == current_pane_id) {
            current_rect = pane_rect;
            break;
        }
    }
    const current = current_rect orelse return null;

    var best: ?PaneFocusCandidate = null;
    for (pane_rects.items) |pane_rect| {
        if (pane_rect.pane_id == current_pane_id) continue;
        const candidate = paneFocusCandidate(current, pane_rect, direction) orelse continue;
        if (best == null or paneFocusCandidateBetter(candidate, best.?)) {
            best = candidate;
        }
    }
    return if (best) |candidate| candidate.pane_id else null;
}

fn collectPaneRects(
    allocator: std.mem.Allocator,
    node: *const PaneNode,
    min: [2]f32,
    max: [2]f32,
    pane_rects: *std.ArrayList(PaneRect),
) !void {
    switch (node.*) {
        .leaf => |leaf| try pane_rects.append(allocator, .{
            .pane_id = leaf.id,
            .min = min,
            .max = max,
        }),
        .split => |split| {
            if (split.axis == .vertical) {
                const split_x = min[0] + (max[0] - min[0]) * split.ratio;
                try collectPaneRects(allocator, split.first, min, .{ split_x, max[1] }, pane_rects);
                try collectPaneRects(allocator, split.second, .{ split_x, min[1] }, max, pane_rects);
            } else {
                const split_y = min[1] + (max[1] - min[1]) * split.ratio;
                try collectPaneRects(allocator, split.first, min, .{ max[0], split_y }, pane_rects);
                try collectPaneRects(allocator, split.second, .{ min[0], split_y }, max, pane_rects);
            }
        },
    }
}

fn paneFocusCandidate(current: PaneRect, candidate: PaneRect, direction: SplitDirection) ?PaneFocusCandidate {
    const epsilon = 0.0001;
    const current_center = .{
        (current.min[0] + current.max[0]) * 0.5,
        (current.min[1] + current.max[1]) * 0.5,
    };
    const candidate_center = .{
        (candidate.min[0] + candidate.max[0]) * 0.5,
        (candidate.min[1] + candidate.max[1]) * 0.5,
    };

    return switch (direction) {
        .left => blk: {
            if (candidate.max[0] > current.min[0] + epsilon) break :blk null;
            break :blk .{
                .pane_id = candidate.pane_id,
                .overlap = rectAxisOverlap(current.min[1], current.max[1], candidate.min[1], candidate.max[1]),
                .primary_distance = current.min[0] - candidate.max[0],
                .secondary_distance = @abs(current_center[1] - candidate_center[1]),
            };
        },
        .right => blk: {
            if (candidate.min[0] < current.max[0] - epsilon) break :blk null;
            break :blk .{
                .pane_id = candidate.pane_id,
                .overlap = rectAxisOverlap(current.min[1], current.max[1], candidate.min[1], candidate.max[1]),
                .primary_distance = candidate.min[0] - current.max[0],
                .secondary_distance = @abs(current_center[1] - candidate_center[1]),
            };
        },
        .up => blk: {
            if (candidate.max[1] > current.min[1] + epsilon) break :blk null;
            break :blk .{
                .pane_id = candidate.pane_id,
                .overlap = rectAxisOverlap(current.min[0], current.max[0], candidate.min[0], candidate.max[0]),
                .primary_distance = current.min[1] - candidate.max[1],
                .secondary_distance = @abs(current_center[0] - candidate_center[0]),
            };
        },
        .down => blk: {
            if (candidate.min[1] < current.max[1] - epsilon) break :blk null;
            break :blk .{
                .pane_id = candidate.pane_id,
                .overlap = rectAxisOverlap(current.min[0], current.max[0], candidate.min[0], candidate.max[0]),
                .primary_distance = candidate.min[1] - current.max[1],
                .secondary_distance = @abs(current_center[0] - candidate_center[0]),
            };
        },
    };
}

fn paneFocusCandidateBetter(candidate: PaneFocusCandidate, current_best: PaneFocusCandidate) bool {
    const epsilon = 0.0001;
    if (candidate.overlap > current_best.overlap + epsilon) return true;
    if (candidate.overlap + epsilon < current_best.overlap) return false;
    if (candidate.primary_distance + epsilon < current_best.primary_distance) return true;
    if (candidate.primary_distance > current_best.primary_distance + epsilon) return false;
    return candidate.secondary_distance + epsilon < current_best.secondary_distance;
}

fn rectAxisOverlap(a_min: f32, a_max: f32, b_min: f32, b_max: f32) f32 {
    return @max(0.0, @min(a_max, b_max) - @max(a_min, b_min));
}

fn axisForDirection(direction: SplitDirection) SplitAxis {
    return switch (direction) {
        .left, .right => .vertical,
        .up, .down => .horizontal,
    };
}

fn sanitizeSplitRatio(ratio: f32) f32 {
    return clampf(ratio, MIN_SPLIT_RATIO, 1.0 - MIN_SPLIT_RATIO);
}

fn serializePaneNode(
    allocator: std.mem.Allocator,
    node: *const PaneNode,
    nodes: *std.ArrayList(PersistedNode),
    next_node_id: *u32,
) !u32 {
    const node_id = next_node_id.*;
    next_node_id.* += 1;

    switch (node.*) {
        .leaf => |leaf| {
            try nodes.append(allocator, .{
                .node_id = node_id,
                .kind = .leaf,
                .pane_id = leaf.id,
            });
        },
        .split => |split| {
            const first_node_id = try serializePaneNode(allocator, split.first, nodes, next_node_id);
            const second_node_id = try serializePaneNode(allocator, split.second, nodes, next_node_id);
            try nodes.append(allocator, .{
                .node_id = node_id,
                .kind = .split,
                .axis = split.axis,
                .ratio = split.ratio,
                .first_node_id = first_node_id,
                .second_node_id = second_node_id,
            });
        },
    }

    return node_id;
}

fn buildPaneNodeFromPersisted(
    allocator: std.mem.Allocator,
    nodes: []const PersistedNode,
    root_node_id: u32,
    max_pane_id: *u32,
) !*PaneNode {
    for (nodes) |persisted| {
        if (persisted.node_id != root_node_id) continue;

        const node = try allocator.create(PaneNode);
        switch (persisted.kind) {
            .leaf => {
                max_pane_id.* = @max(max_pane_id.*, persisted.pane_id);
                node.* = .{ .leaf = .{ .id = @max(persisted.pane_id, 1), .session = null } };
            },
            .split => {
                const first_id = persisted.first_node_id orelse return error.InvalidPersistedTerminalLayout;
                const second_id = persisted.second_node_id orelse return error.InvalidPersistedTerminalLayout;
                node.* = .{
                    .split = .{
                        .axis = persisted.axis orelse .vertical,
                        .ratio = sanitizeSplitRatio(persisted.ratio orelse 0.5),
                        .first = try buildPaneNodeFromPersisted(allocator, nodes, first_id, max_pane_id),
                        .second = try buildPaneNodeFromPersisted(allocator, nodes, second_id, max_pane_id),
                    },
                };
            },
        }
        return node;
    }

    return error.InvalidPersistedTerminalLayout;
}

pub fn clampPreferredHeight(height: f32) f32 {
    return clampf(height, MIN_DOCK_HEIGHT, MAX_DOCK_HEIGHT);
}

pub fn clampHeightForAvailable(height: f32, available_height: f32) f32 {
    const max_allowed = @min(MAX_DOCK_HEIGHT, available_height * 0.82);
    const max_height = @max(MIN_DOCK_HEIGHT, max_allowed);
    return clampf(height, MIN_DOCK_HEIGHT, max_height);
}

const UnsupportedSession = struct {
    pub fn create(_: std.mem.Allocator, _: SessionCreateOptions) !*UnsupportedSession {
        return error.UnsupportedOperatingSystem;
    }

    pub fn deinit(_: *UnsupportedSession, _: std.mem.Allocator) void {}

    pub fn poll(_: *UnsupportedSession, _: std.mem.Allocator) !void {}

    pub fn resize(_: *UnsupportedSession, _: std.mem.Allocator, _: u16, _: u16, _: u32, _: u32) !void {}

    pub fn displayText(_: *const UnsupportedSession) []const u8 {
        return "";
    }

    pub fn statusText(_: *const UnsupportedSession, _: *[192]u8) []const u8 {
        return "Native shell embedding is only enabled on Linux and macOS.";
    }

    pub fn tabTitle(_: *const UnsupportedSession, _: *[96]u8) []const u8 {
        return "Shell";
    }

    pub fn isRunning(_: *const UnsupportedSession) bool {
        return false;
    }

    pub fn writeInput(_: *UnsupportedSession, _: []const u8) !bool {
        return false;
    }

    pub fn handleKeyDown(_: *UnsupportedSession, _: *const sdl.KeyboardEvent) !bool {
        return false;
    }
};

const UnixSession = struct {
    master_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,
    terminal: ghostty_vt.Terminal,
    stream: TerminalStream,
    render_state: ghostty_vt.RenderState = .empty,
    cols: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
    running: bool = true,
    exit_status: ?u32 = null,
    launch_kind: TerminalLaunchKind = .shell,
    launch_label: []u8,

    const SpawnResult = struct {
        master_fd: std.posix.fd_t,
        child_pid: std.posix.pid_t,
    };

    extern fn forkpty(
        amaster: *c_int,
        name: ?[*:0]u8,
        termp: ?*const anyopaque,
        winp: ?*const std.posix.winsize,
    ) c_int;

    pub fn create(allocator: std.mem.Allocator, options: SessionCreateOptions) !*UnixSession {
        const self = try allocator.create(UnixSession);
        errdefer allocator.destroy(self);

        var terminal = try ghostty_vt.Terminal.init(allocator, .{
            .cols = options.cols,
            .rows = options.rows,
        });
        errdefer terminal.deinit(allocator);
        configureTerminalTheme(allocator, &terminal);
        try terminal.setPwd(options.cwd);

        const launch_label = try launchLabel(allocator, options.profile);
        errdefer allocator.free(launch_label);

        const child = try spawnCommand(allocator, options.cwd, options.cols, options.rows, options.profile);
        errdefer {
            std.posix.kill(child.child_pid, std.posix.SIG.TERM) catch {};
            _ = std.c.close(child.master_fd);
        }

        self.* = .{
            .master_fd = child.master_fd,
            .child_pid = child.child_pid,
            .terminal = terminal,
            .stream = undefined,
            .render_state = .empty,
            .cols = options.cols,
            .rows = options.rows,
            .cell_width = CELL_PIXEL_WIDTH,
            .cell_height = CELL_PIXEL_HEIGHT,
            .launch_kind = options.profile.kind,
            .launch_label = launch_label,
        };
        self.stream = self.terminal.vtStream();
        self.stream.handler.effects.write_pty = &UnixSession.streamWritePty;
        self.stream.handler.effects.device_attributes = &UnixSession.streamDeviceAttributes;
        self.stream.handler.effects.size = &UnixSession.streamSize;
        self.stream.handler.effects.xtversion = &UnixSession.streamXtVersion;
        self.stream.handler.effects.color_scheme = &UnixSession.streamColorScheme;
        errdefer self.stream.deinit();

        try self.refreshRenderState(allocator);
        return self;
    }

    pub fn deinit(self: *UnixSession, allocator: std.mem.Allocator) void {
        if (self.running) {
            std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch {};
        }
        _ = std.c.close(self.master_fd);
        _ = self.captureExitStatus();
        self.stream.deinit();
        self.render_state.deinit(allocator);
        self.terminal.deinit(allocator);
        allocator.free(self.launch_label);
    }

    pub fn poll(self: *UnixSession, allocator: std.mem.Allocator) !void {
        const changed = try self.drainOutput(allocator);
        const exited = self.captureExitStatus();
        if (changed or exited) {
            try self.refreshRenderState(allocator);
        }
    }

    pub fn resize(self: *UnixSession, allocator: std.mem.Allocator, cols: u16, rows: u16, cell_width: u32, cell_height: u32) !void {
        const next_cols = sanitizeCellCount(cols, MIN_COLS);
        const next_rows = sanitizeCellCount(rows, MIN_ROWS);
        const next_cell_width = @max(cell_width, 1);
        const next_cell_height = @max(cell_height, 1);
        const size_changed = self.cols != next_cols or self.rows != next_rows;
        const metrics_changed = self.cell_width != next_cell_width or self.cell_height != next_cell_height;
        if (!size_changed and !metrics_changed) return;
        self.cols = next_cols;
        self.rows = next_rows;
        self.cell_width = next_cell_width;
        self.cell_height = next_cell_height;
        if (size_changed) {
            try self.terminal.resize(allocator, next_cols, next_rows);
        }
        self.applyWinsize();
        try self.refreshRenderState(allocator);
    }

    pub fn renderState(self: *const UnixSession) *const ghostty_vt.RenderState {
        return &self.render_state;
    }

    pub fn statusText(self: *const UnixSession, buf: *[192]u8) []const u8 {
        if (self.running) {
            return std.fmt.bufPrint(buf, "{d}x{d} {s} attached", .{ self.cols, self.rows, self.launch_label }) catch "Terminal attached";
        }
        if (self.exit_status) |status| {
            if (std.c.W.IFEXITED(status)) {
                return std.fmt.bufPrint(buf, "{s} exited with code {d}", .{ self.launch_label, std.c.W.EXITSTATUS(status) }) catch "Terminal exited";
            }
            if (std.c.W.IFSIGNALED(status)) {
                return std.fmt.bufPrint(buf, "{s} terminated by signal {d}", .{ self.launch_label, std.c.W.TERMSIG(status) }) catch "Terminal exited";
            }
        }
        return std.fmt.bufPrint(buf, "{s} exited.", .{self.launch_label}) catch "Terminal exited.";
    }

    pub fn tabTitle(self: *const UnixSession, buffer: *[96]u8) []const u8 {
        if (self.launch_kind != .shell) return self.launch_label;
        if (builtin.os.tag == .linux) {
            var proc_path_buf: [64]u8 = undefined;
            const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/{d}/cwd", .{self.child_pid}) catch "";
            if (proc_path.len > 0) {
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                var threaded = std.Io.Threaded.init_single_threaded;
                if (std.Io.Dir.cwd().readLink(threaded.io(), proc_path, &cwd_buf)) |cwd_len| {
                    const label = pathLabel(cwd_buf[0..cwd_len]);
                    if (label.len > 0) {
                        const clipped = label[0..@min(label.len, buffer.len)];
                        return std.fmt.bufPrint(buffer, "{s}", .{clipped}) catch "Shell";
                    }
                } else |_| {}
            }
        }
        if (self.terminal.getPwd()) |pwd| {
            const label = pathLabel(pwd);
            if (label.len > 0) return label;
        }
        if (self.terminal.getTitle()) |title| {
            const trimmed = std.mem.trim(u8, title, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                if (trimmed.len <= buffer.len) return trimmed;
                return std.fmt.bufPrint(buffer, "{s}", .{trimmed[0..buffer.len]}) catch "Shell";
            }
        }
        return "Shell";
    }

    pub fn isRunning(self: *const UnixSession) bool {
        return self.running;
    }

    pub fn writeInput(self: *UnixSession, bytes: []const u8) !bool {
        if (!self.running or bytes.len == 0) return false;
        try writeAll(self.master_fd, bytes);
        return true;
    }

    pub fn handleKeyDown(self: *UnixSession, event: *const sdl.KeyboardEvent) !bool {
        if (!self.running or !event.down) return false;

        var utf8_buf: [8]u8 = undefined;
        const synthesized_utf8 = synthesizeTerminalUtf8(event, &utf8_buf);
        if (synthesized_utf8.len == 0 and shouldDeferToTextInput(event)) return false;

        const key = mapScancodeToGhostty(event.scancode) orelse return false;
        const key_event: ghostty_vt.input.KeyEvent = .{
            .action = if (event.repeat) .repeat else .press,
            .key = key,
            .mods = modsFromKeyboardEvent(event),
            .consumed_mods = consumedModsFromKeyboardEvent(event, synthesized_utf8),
            .utf8 = synthesized_utf8,
            .unshifted_codepoint = scancodeCodepoint(event.scancode) orelse 0,
        };

        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const options = ghostty_vt.input.KeyEncodeOptions.fromTerminal(&self.terminal);
        try ghostty_vt.input.encodeKey(&writer, key_event, options);
        const encoded = writer.buffered();
        if (encoded.len == 0) return true;
        try writeAll(self.master_fd, encoded);
        return true;
    }

    pub fn handleWheel(self: *UnixSession, allocator: std.mem.Allocator, wheel_y: f32) !bool {
        if (wheel_y == 0.0) return false;
        const line_count_float = @max(@round(@abs(wheel_y) * WHEEL_SCROLL_LINES), 1.0);
        const line_count: isize = @intFromFloat(line_count_float);
        self.terminal.scrollViewport(.{ .delta = if (wheel_y > 0.0) -line_count else line_count });
        try self.refreshRenderState(allocator);
        return true;
    }

    fn refreshRenderState(self: *UnixSession, allocator: std.mem.Allocator) !void {
        try self.render_state.update(allocator, &self.terminal);
    }

    fn drainOutput(self: *UnixSession, allocator: std.mem.Allocator) !bool {
        if (!self.running) return false;

        var changed = false;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const read_len = std.posix.read(self.master_fd, &buffer) catch |err| switch (err) {
                error.WouldBlock => break,
                error.InputOutput => {
                    self.running = false;
                    break;
                },
                else => return err,
            };
            if (read_len == 0) {
                self.running = false;
                break;
            }

            self.stream.nextSlice(buffer[0..read_len]);
            try self.repairTerminalState(allocator);
            changed = true;
        }

        return changed;
    }

    fn repairTerminalState(self: *UnixSession, allocator: std.mem.Allocator) !void {
        var repaired = false;
        const fallback_cols = sanitizeCellCount(self.cols, MIN_COLS);
        const fallback_rows = sanitizeCellCount(self.rows, MIN_ROWS);

        if (self.terminal.cols == 0 or self.terminal.rows == 0) {
            try self.terminal.resize(allocator, fallback_cols, fallback_rows);
            repaired = true;
        }

        const term_cols = sanitizeCellCount(self.terminal.cols, MIN_COLS);
        const term_rows = sanitizeCellCount(self.terminal.rows, MIN_ROWS);
        const max_col = term_cols - 1;
        const max_row = term_rows - 1;
        const region = self.terminal.scrolling_region;

        if (region.left > max_col or
            region.right > max_col or
            region.left >= region.right or
            region.top > max_row or
            region.bottom > max_row or
            region.top > region.bottom)
        {
            self.terminal.scrolling_region = .{
                .top = 0,
                .bottom = max_row,
                .left = 0,
                .right = max_col,
            };
            self.terminal.setCursorPos(1, 1);
            repaired = true;
        }

        if (repaired) {
            self.cols = term_cols;
            self.rows = term_rows;
            log.warn(
                "repaired terminal state cols={d} rows={d} region=({d},{d})-({d},{d})",
                .{
                    self.terminal.cols,
                    self.terminal.rows,
                    self.terminal.scrolling_region.left,
                    self.terminal.scrolling_region.top,
                    self.terminal.scrolling_region.right,
                    self.terminal.scrolling_region.bottom,
                },
            );
        }
    }

    fn streamWritePty(handler: *TerminalHandler, data: [:0]const u8) void {
        const session: *UnixSession = @fieldParentPtr("terminal", handler.terminal);
        writeAll(session.master_fd, std.mem.sliceTo(data, 0)) catch |err| {
            log.warn("failed to write terminal response to PTY: {s}", .{@errorName(err)});
        };
    }

    fn streamDeviceAttributes(_: *TerminalHandler) DeviceAttributes {
        return .{};
    }

    fn streamSize(handler: *TerminalHandler) ?ghostty_vt.size_report.Size {
        const session: *UnixSession = @fieldParentPtr("terminal", handler.terminal);
        return .{
            .rows = session.rows,
            .columns = session.cols,
            .cell_width = session.cell_width,
            .cell_height = session.cell_height,
        };
    }

    fn streamXtVersion(_: *TerminalHandler) []const u8 {
        return "verde";
    }

    fn streamColorScheme(_: *TerminalHandler) ?ColorScheme {
        return .dark;
    }

    const TerminalTheme = struct {
        background: ghostty_vt.color.RGB = terminalRgb(0x2c, 0x25, 0x25),
        foreground: ghostty_vt.color.RGB = terminalRgb(0xe6, 0xd9, 0xdb),
        cursor: ghostty_vt.color.RGB = terminalRgb(0xc3, 0xb7, 0xb8),
        palette: [256]ghostty_vt.color.RGB = defaultTerminalPalette(),
    };

    fn configureTerminalTheme(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal) void {
        var terminal_theme = TerminalTheme{};
        loadGhosttyTheme(allocator, &terminal_theme) catch |err| {
            log.debug("using built-in terminal theme fallback: {s}", .{@errorName(err)});
        };

        terminal.colors.background = ghostty_vt.color.DynamicRGB.init(terminal_theme.background);
        terminal.colors.foreground = ghostty_vt.color.DynamicRGB.init(terminal_theme.foreground);
        terminal.colors.cursor = ghostty_vt.color.DynamicRGB.init(terminal_theme.cursor);
        terminal.colors.palette.changeDefault(terminal_theme.palette);
    }

    fn defaultTerminalPalette() [256]ghostty_vt.color.RGB {
        var palette = ghostty_vt.color.default;
        const ansi = [_]ghostty_vt.color.RGB{
            terminalRgb(0x72, 0x69, 0x6a),
            terminalRgb(0xfd, 0x68, 0x83),
            terminalRgb(0xad, 0xda, 0x78),
            terminalRgb(0xf9, 0xcc, 0x6c),
            terminalRgb(0xf3, 0x8d, 0x70),
            terminalRgb(0xa8, 0xa9, 0xeb),
            terminalRgb(0x85, 0xda, 0xcc),
            terminalRgb(0xe6, 0xd9, 0xdb),
            terminalRgb(0x94, 0x8a, 0x8b),
            terminalRgb(0xff, 0x82, 0x97),
            terminalRgb(0xc8, 0xe2, 0x92),
            terminalRgb(0xfc, 0xd6, 0x75),
            terminalRgb(0xf8, 0xa7, 0x88),
            terminalRgb(0xbe, 0xbf, 0xfd),
            terminalRgb(0x9b, 0xf1, 0xe1),
            terminalRgb(0xf1, 0xe5, 0xe7),
        };
        @memcpy(palette[0..ansi.len], &ansi);
        return palette;
    }

    fn loadGhosttyTheme(allocator: std.mem.Allocator, terminal_theme: *TerminalTheme) !void {
        const home = std.c.getenv("HOME") orelse return error.HomeUnset;
        const home_slice = std.mem.span(home);
        const config_path = try std.fs.path.join(allocator, &.{ home_slice, ".config", "ghostty", "config" });
        defer allocator.free(config_path);

        try parseGhosttyThemeFile(allocator, config_path, terminal_theme, true);
    }

    fn parseGhosttyThemeFile(allocator: std.mem.Allocator, path: []const u8, terminal_theme: *TerminalTheme, follow_includes: bool) !void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const content = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(64 * 1024));
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const no_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index| raw_line[0..index] else raw_line;
            const line = std.mem.trim(u8, no_comment, " \t\r");
            if (line.len == 0) continue;
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..equals], " \t\r");
            const value = std.mem.trim(u8, line[equals + 1 ..], " \t\r");

            if (std.mem.eql(u8, key, "background")) {
                if (parseHexRgb(value)) |rgb| terminal_theme.background = rgb;
            } else if (std.mem.eql(u8, key, "foreground")) {
                if (parseHexRgb(value)) |rgb| terminal_theme.foreground = rgb;
            } else if (std.mem.eql(u8, key, "cursor-color")) {
                if (parseHexRgb(value)) |rgb| terminal_theme.cursor = rgb;
            } else if (std.mem.eql(u8, key, "palette")) {
                parseGhosttyPalette(value, terminal_theme);
            } else if (follow_includes and std.mem.eql(u8, key, "config-file")) {
                const include_path = try resolveGhosttyPath(allocator, path, value);
                defer allocator.free(include_path);
                parseGhosttyThemeFile(allocator, include_path, terminal_theme, false) catch |err| {
                    log.debug("failed to load ghostty theme include {s}: {s}", .{ include_path, @errorName(err) });
                };
            }
        }
    }

    fn parseGhosttyPalette(value: []const u8, terminal_theme: *TerminalTheme) void {
        const equals = std.mem.indexOfScalar(u8, value, '=') orelse return;
        const index_text = std.mem.trim(u8, value[0..equals], " \t\r");
        const color_text = std.mem.trim(u8, value[equals + 1 ..], " \t\r");
        const index = std.fmt.parseInt(usize, index_text, 10) catch return;
        if (index >= terminal_theme.palette.len) return;
        terminal_theme.palette[index] = parseHexRgb(color_text) orelse return;
    }

    fn resolveGhosttyPath(allocator: std.mem.Allocator, base_path: []const u8, raw_value: []const u8) ![]u8 {
        var value = std.mem.trim(u8, rawValueWithoutOptionalPrefix(raw_value), " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') value = value[1 .. value.len - 1];

        if (std.mem.startsWith(u8, value, "~/")) {
            const home = std.c.getenv("HOME") orelse return error.HomeUnset;
            return std.fs.path.join(allocator, &.{ std.mem.span(home), value[2..] });
        }
        if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);

        const base_dir = std.fs.path.dirname(base_path) orelse ".";
        return std.fs.path.join(allocator, &.{ base_dir, value });
    }

    fn rawValueWithoutOptionalPrefix(value: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, value, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '?') return std.mem.trim(u8, trimmed[1..], " \t\r");
        return trimmed;
    }

    fn parseHexRgb(raw_value: []const u8) ?ghostty_vt.color.RGB {
        var value = std.mem.trim(u8, raw_value, " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (value.len != 7 or value[0] != '#') return null;
        return terminalRgb(
            std.fmt.parseInt(u8, value[1..3], 16) catch return null,
            std.fmt.parseInt(u8, value[3..5], 16) catch return null,
            std.fmt.parseInt(u8, value[5..7], 16) catch return null,
        );
    }

    fn terminalRgb(r: u8, g: u8, b: u8) ghostty_vt.color.RGB {
        return .{ .r = r, .g = g, .b = b };
    }

    fn captureExitStatus(self: *UnixSession) bool {
        if (self.exit_status != null) return false;

        var status: c_int = 0;
        const wait_result = std.c.waitpid(self.child_pid, &status, std.c.W.NOHANG);
        if (wait_result == 0) return false;

        self.running = false;
        self.exit_status = @intCast(status);
        return true;
    }

    fn applyWinsize(self: *UnixSession) void {
        if (!self.running) return;

        var winsize = std.posix.winsize{
            .row = self.rows,
            .col = self.cols,
            .xpixel = @intCast(@min(@as(u32, std.math.maxInt(u16)), self.cell_width * self.cols)),
            .ypixel = @intCast(@min(@as(u32, std.math.maxInt(u16)), self.cell_height * self.rows)),
        };
        _ = std.c.ioctl(
            self.master_fd,
            TERMINAL_WINSIZE_IOCTL,
            &winsize,
        );
    }

    fn spawnCommand(allocator: std.mem.Allocator, cwd: []const u8, cols: u16, rows: u16, profile: TerminalLaunchProfile) !SpawnResult {
        const cwd_z = try allocator.dupeZ(u8, cwd);
        defer allocator.free(cwd_z);
        const command = try commandForProfile(allocator, profile);
        defer freeCommand(allocator, command);

        var master_fd: c_int = -1;
        const winsize = std.posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        const fork_result = forkpty(&master_fd, null, null, &winsize);
        if (fork_result < 0) return error.ForkPtyFailed;

        if (fork_result == 0) {
            childExec(cwd_z, command);
        }

        try setNonBlocking(@intCast(master_fd));
        return .{
            .master_fd = @intCast(master_fd),
            .child_pid = @intCast(fork_result),
        };
    }

    fn childExec(cwd: [:0]const u8, command: []const [:0]u8) noreturn {
        if (std.c.chdir(cwd.ptr) != 0) {
            std.c._exit(127);
        }

        _ = setenv("TERM", "xterm-ghostty", 1);
        _ = setenv("COLORTERM", "truecolor", 1);
        _ = setenv("TERM_PROGRAM", "ghostty", 1);
        _ = setenv("TERM_PROGRAM_VERSION", "1.1.0", 1);
        _ = setenv("CLICOLOR", "1", 1);
        _ = setenv("CLICOLOR_FORCE", "1", 0);
        _ = setenv("FORCE_COLOR", "3", 0);
        _ = unsetenv("NO_COLOR");
        if (std.c.getenv("LANG") == null) {
            _ = setenv("LANG", "C.UTF-8", 1);
        }

        var argv: [32:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 32;
        const count = @min(command.len, argv.len - 1);
        for (command[0..count], 0..) |arg, index| {
            argv[index] = arg.ptr;
        }
        if (count > 0) {
            _ = std.c.execve(command[0].ptr, &argv, std.c.environ);
        }
        std.c._exit(127);
    }
};

fn setNonBlocking(fd: std.posix.fd_t) !void {
    const current = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (current < 0) return error.FcntlFailed;
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (std.c.fcntl(fd, std.c.F.SETFL, current | @as(c_int, @intCast(nonblock))) < 0) return error.FcntlFailed;
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written_raw = std.c.write(fd, remaining.ptr, remaining.len);
        if (written_raw < 0) return error.WriteFailed;
        const written: usize = @intCast(written_raw);
        if (written == 0) return error.WriteFailed;
        remaining = remaining[written..];
    }
}

fn shouldDeferToTextInput(event: *const sdl.KeyboardEvent) bool {
    if (modifierPressed(event.mod, sdl.Keymod.ctrl)) return false;
    if (modifierPressed(event.mod, sdl.Keymod.alt)) return false;
    if (modifierPressed(event.mod, sdl.Keymod.gui)) return false;

    return switch (event.scancode) {
        .a,
        .b,
        .c,
        .d,
        .e,
        .f,
        .g,
        .h,
        .i,
        .j,
        .k,
        .l,
        .m,
        .n,
        .o,
        .p,
        .q,
        .r,
        .s,
        .t,
        .u,
        .v,
        .w,
        .x,
        .y,
        .z,
        .@"0",
        .@"1",
        .@"2",
        .@"3",
        .@"4",
        .@"5",
        .@"6",
        .@"7",
        .@"8",
        .@"9",
        .space,
        .minus,
        .equals,
        .leftbracket,
        .rightbracket,
        .backslash,
        .semicolon,
        .apostrophe,
        .grave,
        .comma,
        .period,
        .slash,
        => true,
        else => false,
    };
}

fn isAsciiTerminalText(input_text: []const u8) bool {
    if (input_text.len == 0) return false;
    for (input_text) |byte| {
        if (byte < 0x20 or byte > 0x7E) return false;
    }
    return true;
}

fn consumedModsFromKeyboardEvent(event: *const sdl.KeyboardEvent, utf8: []const u8) ghostty_vt.input.KeyMods {
    if (utf8.len == 0) return .{};
    return .{
        .shift = modifierPressed(event.mod, sdl.Keymod.shift),
    };
}

fn synthesizeTerminalUtf8(event: *const sdl.KeyboardEvent, buf: *[8]u8) []const u8 {
    if (modifierPressed(event.mod, sdl.Keymod.ctrl)) return "";
    if (modifierPressed(event.mod, sdl.Keymod.alt)) return "";
    if (modifierPressed(event.mod, sdl.Keymod.gui)) return "";

    const shift = modifierPressed(event.mod, sdl.Keymod.shift);
    const caps = modifierPressed(event.mod, sdl.Keymod.caps);
    const scancode_value = @intFromEnum(event.scancode);
    const a_value = @intFromEnum(sdl.Scancode.a);
    const z_value = @intFromEnum(sdl.Scancode.z);
    if (scancode_value >= a_value and scancode_value <= z_value) {
        const base = @as(u8, @intCast(scancode_value - a_value)) + 'a';
        const upper = shift != caps;
        buf[0] = if (upper) std.ascii.toUpper(base) else base;
        return buf[0..1];
    }

    const ch: u8 = switch (event.scancode) {
        .@"0" => if (shift) ')' else '0',
        .@"1" => if (shift) '!' else '1',
        .@"2" => if (shift) '@' else '2',
        .@"3" => if (shift) '#' else '3',
        .@"4" => if (shift) '$' else '4',
        .@"5" => if (shift) '%' else '5',
        .@"6" => if (shift) '^' else '6',
        .@"7" => if (shift) '&' else '7',
        .@"8" => if (shift) '*' else '8',
        .@"9" => if (shift) '(' else '9',
        .space => ' ',
        .minus => if (shift) '_' else '-',
        .equals => if (shift) '+' else '=',
        .leftbracket => if (shift) '{' else '[',
        .rightbracket => if (shift) '}' else ']',
        .backslash => if (shift) '|' else '\\',
        .semicolon => if (shift) ':' else ';',
        .apostrophe => if (shift) '"' else '\'',
        .grave => if (shift) '~' else '`',
        .comma => if (shift) '<' else ',',
        .period => if (shift) '>' else '.',
        .slash => if (shift) '?' else '/',
        else => return "",
    };
    buf[0] = ch;
    return buf[0..1];
}

fn modsFromKeyboardEvent(event: *const sdl.KeyboardEvent) ghostty_vt.input.KeyMods {
    return .{
        .shift = modifierPressed(event.mod, sdl.Keymod.shift),
        .ctrl = modifierPressed(event.mod, sdl.Keymod.ctrl),
        .alt = modifierPressed(event.mod, sdl.Keymod.alt),
        .super = modifierPressed(event.mod, sdl.Keymod.gui),
        .caps_lock = modifierPressed(event.mod, sdl.Keymod.caps),
        .num_lock = modifierPressed(event.mod, sdl.Keymod.num),
    };
}

fn modifierPressed(state: sdl.Keymod, mask: u16) bool {
    const state_bits = @as(*const u16, @ptrCast(&state)).*;
    return (state_bits & mask) != 0;
}

fn mapScancodeToGhostty(scancode: sdl.Scancode) ?ghostty_vt.input.Key {
    return switch (scancode) {
        .a => .key_a,
        .b => .key_b,
        .c => .key_c,
        .d => .key_d,
        .e => .key_e,
        .f => .key_f,
        .g => .key_g,
        .h => .key_h,
        .i => .key_i,
        .j => .key_j,
        .k => .key_k,
        .l => .key_l,
        .m => .key_m,
        .n => .key_n,
        .o => .key_o,
        .p => .key_p,
        .q => .key_q,
        .r => .key_r,
        .s => .key_s,
        .t => .key_t,
        .u => .key_u,
        .v => .key_v,
        .w => .key_w,
        .x => .key_x,
        .y => .key_y,
        .z => .key_z,
        .@"0" => .digit_0,
        .@"1" => .digit_1,
        .@"2" => .digit_2,
        .@"3" => .digit_3,
        .@"4" => .digit_4,
        .@"5" => .digit_5,
        .@"6" => .digit_6,
        .@"7" => .digit_7,
        .@"8" => .digit_8,
        .@"9" => .digit_9,
        .@"return" => .enter,
        .escape => .escape,
        .backspace => .backspace,
        .tab => .tab,
        .space => .space,
        .minus => .minus,
        .equals => .equal,
        .leftbracket => .bracket_left,
        .rightbracket => .bracket_right,
        .backslash => .backslash,
        .semicolon => .semicolon,
        .apostrophe => .quote,
        .grave => .backquote,
        .comma => .comma,
        .period => .period,
        .slash => .slash,
        .capslock => .caps_lock,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        .printscreen => .print_screen,
        .scrolllock => .scroll_lock,
        .pause => .pause,
        .insert => .insert,
        .home => .home,
        .pageup => .page_up,
        .delete => .delete,
        .end => .end,
        .pagedown => .page_down,
        .right => .arrow_right,
        .left => .arrow_left,
        .down => .arrow_down,
        .up => .arrow_up,
        .numlockclear => .num_lock,
        .kp_divide => .numpad_divide,
        .kp_multiply => .numpad_multiply,
        .kp_minus => .numpad_subtract,
        .kp_plus => .numpad_add,
        .kp_enter => .numpad_enter,
        .kp_0 => .numpad_0,
        .kp_1 => .numpad_1,
        .kp_2 => .numpad_2,
        .kp_3 => .numpad_3,
        .kp_4 => .numpad_4,
        .kp_5 => .numpad_5,
        .kp_6 => .numpad_6,
        .kp_7 => .numpad_7,
        .kp_8 => .numpad_8,
        .kp_9 => .numpad_9,
        .kp_period => .numpad_decimal,
        .kp_equals => .numpad_equal,
        .lctrl => .control_left,
        .lshift => .shift_left,
        .lalt => .alt_left,
        .lgui => .meta_left,
        .rctrl => .control_right,
        .rshift => .shift_right,
        .ralt => .alt_right,
        .rgui => .meta_right,
        else => null,
    };
}

fn scancodeCodepoint(scancode: sdl.Scancode) ?u21 {
    return switch (scancode) {
        .a => 'a',
        .b => 'b',
        .c => 'c',
        .d => 'd',
        .e => 'e',
        .f => 'f',
        .g => 'g',
        .h => 'h',
        .i => 'i',
        .j => 'j',
        .k => 'k',
        .l => 'l',
        .m => 'm',
        .n => 'n',
        .o => 'o',
        .p => 'p',
        .q => 'q',
        .r => 'r',
        .s => 's',
        .t => 't',
        .u => 'u',
        .v => 'v',
        .w => 'w',
        .x => 'x',
        .y => 'y',
        .z => 'z',
        .@"0" => '0',
        .@"1" => '1',
        .@"2" => '2',
        .@"3" => '3',
        .@"4" => '4',
        .@"5" => '5',
        .@"6" => '6',
        .@"7" => '7',
        .@"8" => '8',
        .@"9" => '9',
        .space => ' ',
        .minus => '-',
        .equals => '=',
        .leftbracket => '[',
        .rightbracket => ']',
        .backslash => '\\',
        .semicolon => ';',
        .apostrophe => '\'',
        .grave => '`',
        .comma => ',',
        .period => '.',
        .slash => '/',
        else => null,
    };
}

fn terminalZoomDelta(event: *const sdl.KeyboardEvent) ?f32 {
    if (!event.down or event.repeat) return null;
    if (!modifierPressed(event.mod, sdl.Keymod.ctrl)) return null;
    if (modifierPressed(event.mod, sdl.Keymod.alt) or modifierPressed(event.mod, sdl.Keymod.gui)) return null;

    return switch (event.scancode) {
        .minus, .kp_minus => -FONT_SCALE_STEP,
        .equals, .kp_plus, .kp_equals => FONT_SCALE_STEP,
        else => null,
    };
}

fn scaledCellPixelWidth(font_scale: f32) u32 {
    return scaledCellPixels(CELL_PIXEL_WIDTH, font_scale);
}

fn scaledCellPixelHeight(font_scale: f32) u32 {
    return scaledCellPixels(CELL_PIXEL_HEIGHT, font_scale);
}

fn scaledCellPixels(base: u32, font_scale: f32) u32 {
    const clamped = clampf(font_scale, MIN_FONT_SCALE, MAX_FONT_SCALE);
    return @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(base)) * clamped))));
}

fn columnsForWidth(width: f32, font_scale: f32) u16 {
    const sanitized = sanitizeViewportDimension(width) orelse return INITIAL_COLS;
    return clampCellCount(
        @intFromFloat(sanitized / @as(f32, @floatFromInt(scaledCellPixelWidth(font_scale)))),
        MIN_COLS,
        MAX_COLS,
    );
}

fn rowsForHeight(height: f32, font_scale: f32) u16 {
    const sanitized = sanitizeViewportDimension(height) orelse return INITIAL_ROWS;
    return clampCellCount(
        @intFromFloat(sanitized / @as(f32, @floatFromInt(scaledCellPixelHeight(font_scale)))),
        MIN_ROWS,
        MAX_ROWS,
    );
}

fn clampCellCount(value: i32, min_value: u16, max_value: u16) u16 {
    return @intCast(@max(@as(i32, min_value), @min(value, @as(i32, max_value))));
}

fn sanitizeViewportDimension(value: f32) ?f32 {
    if (!std.math.isFinite(value)) return null;
    if (value <= 1.0) return null;
    return value;
}

fn sanitizeCellCount(value: u16, min_value: u16) u16 {
    return @max(value, min_value);
}

fn pathLabel(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, std.fs.path.sep_str);
    if (trimmed.len == 0) return std.fs.path.sep_str;
    const base = std.fs.path.basename(trimmed);
    return if (base.len > 0) base else trimmed;
}

fn launchLabel(allocator: std.mem.Allocator, profile: TerminalLaunchProfile) ![]u8 {
    const label = std.mem.trim(u8, profile.label, &std.ascii.whitespace);
    if (label.len > 0) return allocator.dupe(u8, label);
    const fallback = switch (profile.kind) {
        .shell => "Shell",
        .claude => "Claude",
        .opencode => "OpenCode",
        .codex => "Codex",
        .cursor => "Cursor",
        .custom => if (profile.command.len > 0) profile.command[0] else "Custom",
    };
    return allocator.dupe(u8, fallback);
}

fn commandForProfile(allocator: std.mem.Allocator, profile: TerminalLaunchProfile) ![][:0]u8 {
    return switch (profile.kind) {
        .shell => blk: {
            const shell = if (std.c.getenv("SHELL")) |shell_ptr| std.mem.span(shell_ptr) else "/bin/bash";
            break :blk dupeCommand(allocator, &.{ shell, "-i" });
        },
        .claude => dupeCommand(allocator, &.{"claude"}),
        .opencode => dupeCommand(allocator, &.{"opencode"}),
        .codex => dupeCommand(allocator, &.{"codex"}),
        .cursor => dupeCommand(allocator, &.{"cursor"}),
        .custom => {
            if (profile.command.len == 0) return error.EmptyTerminalLaunchCommand;
            return dupeCommand(allocator, profile.command);
        },
    };
}

fn dupeCommand(allocator: std.mem.Allocator, args: []const []const u8) ![][:0]u8 {
    const command = try allocator.alloc([:0]u8, args.len);
    var initialized: usize = 0;
    errdefer {
        for (command[0..initialized]) |arg| allocator.free(arg);
        allocator.free(command);
    }
    for (args, 0..) |arg, index| {
        command[index] = try allocator.dupeZ(u8, arg);
        initialized += 1;
    }
    return command;
}

fn freeCommand(allocator: std.mem.Allocator, command: [][:0]u8) void {
    for (command) |arg| allocator.free(arg);
    allocator.free(command);
}

fn clampf(value: f32, min_value: f32, max_value: f32) f32 {
    return @max(min_value, @min(value, max_value));
}

test "focus adjacent pane uses split direction" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);

    try dock.tabs.append(allocator, try dock.buildSinglePaneTabWithoutSession(allocator));
    const left_id = dock.activePaneConst().?.id;
    try dock.splitActivePane(allocator, .right);
    const right_id = dock.activePaneConst().?.id;

    try std.testing.expectEqual(right_id, dock.activePaneConst().?.id);
    try std.testing.expect(try dock.focusAdjacentPane(allocator, .left));
    try std.testing.expectEqual(left_id, dock.activePaneConst().?.id);
    try std.testing.expect(try dock.focusAdjacentPane(allocator, .right));
    try std.testing.expectEqual(right_id, dock.activePaneConst().?.id);
}

test "unix session PTY smoke" {
    if (!SESSION_SUPPORTED) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const session = try UnixSession.create(allocator, .{
        .cwd = cwd,
        .cols = 80,
        .rows = 24,
    });
    defer {
        session.deinit(allocator);
        allocator.destroy(session);
    }

    try session.writeInput("printf 'verde-terminal-smoke'\r");

    var found = false;
    for (0..40) |_| {
        try session.poll(allocator);
        const screen = try session.terminal.plainString(allocator);
        defer allocator.free(screen);
        if (std.mem.indexOf(u8, screen, "verde-terminal-smoke") != null) {
            found = true;
            break;
        }
        std.time.sleep(50 * std.time.ns_per_ms);
    }

    try testing.expect(found);

    _ = try session.writeInput("exit\r");
    for (0..40) |_| {
        try session.poll(allocator);
        if (!session.running) break;
        std.time.sleep(25 * std.time.ns_per_ms);
    }
}

test "terminal geometry sanitization never returns zero cells" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, INITIAL_COLS), columnsForWidth(0.0));
    try testing.expectEqual(@as(u16, INITIAL_COLS), columnsForWidth(-40.0));
    try testing.expectEqual(@as(u16, INITIAL_COLS), columnsForWidth(std.math.nan(f32)));
    try testing.expectEqual(@as(u16, INITIAL_ROWS), rowsForHeight(0.0));
    try testing.expectEqual(@as(u16, INITIAL_ROWS), rowsForHeight(-10.0));
    try testing.expectEqual(@as(u16, INITIAL_ROWS), rowsForHeight(std.math.nan(f32)));
}

test "repair terminal state resets invalid scrolling region" {
    if (!SESSION_SUPPORTED) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const session = try UnixSession.create(allocator, .{
        .cwd = cwd,
        .cols = 80,
        .rows = 24,
    });
    defer {
        session.deinit(allocator);
        allocator.destroy(session);
    }

    session.terminal.scrolling_region.left = 0;
    session.terminal.scrolling_region.right = 0;
    session.terminal.scrolling_region.top = 99;
    session.terminal.scrolling_region.bottom = 0;

    try session.repairTerminalState(allocator);

    try testing.expectEqual(@as(@TypeOf(session.terminal.scrolling_region.left), 0), session.terminal.scrolling_region.left);
    try testing.expectEqual(session.terminal.cols - 1, session.terminal.scrolling_region.right);
    try testing.expectEqual(@as(@TypeOf(session.terminal.scrolling_region.top), 0), session.terminal.scrolling_region.top);
    try testing.expectEqual(session.terminal.rows - 1, session.terminal.scrolling_region.bottom);
}
