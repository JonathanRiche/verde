//! Browser runtime ownership and deferred-launch controller state.

const std = @import("std");
const sdl = @import("zsdl3");
const browser_inspector = @import("../browser/inspector.zig");
const browser_runtime = @import("../browser/mod.zig");
const browser_screenshot = @import("../browser/screenshot.zig");
const runtime_log = @import("../runtime/log.zig");
const theme = @import("../ui/theme.zig");
const utils = @import("../utils.zig");
const browser_pane = @import("browser_pane.zig");
const chat_types = @import("chat_types.zig");
const workspace_layout = @import("workspace_layout.zig");
const platform_runtime = @import("platform_runtime");

const log = std.log.scoped(.native_shell);
const BrowserPaneRef = browser_pane.BrowserPaneRef;
const ChatThread = chat_types.ChatThread;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;
const WorkspacePaneKind = workspace_layout.WorkspacePaneKind;
const deinitWorkspacePaneRef = workspace_layout.deinitWorkspacePaneRef;

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

pub const BrowserContextMenuItem = struct {
    index: u32,
    label: []u8,
    enabled: bool,
    separator: bool,
    submenu: bool,
    parent_index: ?u32,
};

pub const BrowserContextMenuPayload = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    link_url: ?[]const u8 = null,
    items: []const BrowserContextMenuPayloadItem = &.{},
};

const BrowserContextMenuPayloadItem = struct {
    index: u32 = 0,
    label: []const u8 = "",
    enabled: bool = false,
    separator: bool = false,
    submenu: bool = false,
    items: []const BrowserContextMenuPayloadItem = &.{},
};

/// Kinds of expand/collapse cards that share the same per-frame hit list.
const InspectorPromptSubmittedEvent = struct {
    payload: struct {
        prompt: []const u8,
        selection: InspectorSelectionPayload,
        viewport: ?InspectorViewportPayload = null,
        /// Workspace pane id (stringified) the user picked in the bubble's
        /// "Send to" selector; null when the host never pushed targets.
        target: ?[]const u8 = null,
    },
};

/// Viewport metrics the inspector bundle reports at submit time; used to map
/// CSS selection coordinates onto browser frame pixels for screenshot crops.
const InspectorViewportPayload = struct {
    width: f32 = 0.0,
    height: f32 = 0.0,
    devicePixelRatio: f32 = 1.0,
    scrollX: f32 = 0.0,
    scrollY: f32 = 0.0,
};

const BrowserClipboardEvent = struct {
    source: []const u8,
    text: []const u8 = "",
    cut: bool = false,
};

const InspectorSelectionPayload = struct {
    mode: []const u8,
    element: ?InspectorElementPayload = null,
    elements: ?[]InspectorElementPayload = null,
    rect: ?InspectorRectPayload = null,
};

const InspectorElementPayload = struct {
    selector: ?[]const u8 = null,
    tagName: ?[]const u8 = null,
    textSnippet: ?[]const u8 = null,
    ariaLabel: ?[]const u8 = null,
    href: ?[]const u8 = null,
    rect: ?InspectorRectPayload = null,
};

const InspectorRectPayload = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 0.0,
    height: f32 = 0.0,
};

pub const BrowserOpenResult = struct {
    pane_id: WorkspacePaneId,
    workspace_index: usize,
    /// Retained for live-protocol compatibility; workspace-local panes are no longer moved.
    moved_from_workspace: ?usize,
};

pub const BrowserScreenshotResult = struct {
    path: []u8,
    png_bytes: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *BrowserScreenshotResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.png_bytes);
        self.* = undefined;
    }
};

pub const BrowserTabIndicator = enum {
    none,
    loading,
    failed,
};

const PaletteSurfaceTransition = enum {
    none,
    hide,
    restore,
};

pub const BrowserWorkspaceLocation = struct {
    index: usize,
    pane_id: WorkspacePaneId,
};

const RetainedBrowserRuntime = struct {
    project_index: usize,
    pane_id: ?WorkspacePaneId,
    runtime: browser_runtime.State,
};

pub fn browserToggleCloses(controls_visible: bool, runtime_workspace_index: ?usize, selected_project_index: usize) bool {
    if (!controls_visible) return false;
    const workspace_index = runtime_workspace_index orelse return true;
    return workspace_index == selected_project_index;
}

pub fn browserNavigationUrlIsPersistable(url: []const u8) bool {
    return std.mem.trim(u8, url, &std.ascii.whitespace).len > 0;
}

pub fn browserUrlsHaveSameOrigin(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    const left_uri = std.Uri.parse(left) catch return false;
    const right_uri = std.Uri.parse(right) catch return false;
    if (!std.ascii.eqlIgnoreCase(left_uri.scheme, right_uri.scheme)) return false;

    var left_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    var right_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const left_host = left_uri.getHost(&left_host_buffer) catch return false;
    const right_host = right_uri.getHost(&right_host_buffer) catch return false;
    if (!std.ascii.eqlIgnoreCase(left_host.bytes, right_host.bytes)) return false;

    return browserUriEffectivePort(left_uri) == browserUriEffectivePort(right_uri);
}

fn browserUriEffectivePort(uri: std.Uri) ?u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    return null;
}

pub const State = struct {
    runtime: browser_runtime.State,
    retained_runtimes: std.ArrayList(RetainedBrowserRuntime) = .empty,
    runtime_project_index: ?usize = null,
    /// The exact workspace pane whose page is loaded in the project's single
    /// shared runtime. Metadata and native page identity must move together.
    runtime_pane_id: ?WorkspacePaneId = null,
    launch_open_delay_frames: u8 = 0,
    start_eval_pending: bool = false,
    dev_server_project_index: ?usize = null,
    dev_server_process_index: ?usize = null,
    dev_server_next_check_ms: i64 = 0,
    dev_server_deadline_ms: i64 = 0,
    pane_min: [2]f32 = .{ 0.0, 0.0 },
    pane_max: [2]f32 = .{ 0.0, 0.0 },
    pane_input_size: [2]f32 = .{ 0.0, 0.0 },
    pane_hovered: bool = false,
    cursor_shape: browser_runtime.CursorShape = .default,
    app_window_screen_origin: [2]i32 = .{ 0, 0 },
    app_window_display_scale: f32 = 1.0,
    surface_suspended_for_palette_overlay: bool = false,
    surface_suspended_for_layout: bool = false,
    surface_suspended_for_empty_state: bool = false,
    clipboard_copy_pending: bool = false,
    pane_focused: bool = false,
    address_focused: bool = false,
    address_cursor: usize = 0,
    address_selection_anchor: ?usize = null,
    address_drag_active: bool = false,
    inspector_menu_open: bool = false,
    context_menu_open: bool = false,
    context_menu_anchor_x: f32 = 0.0,
    context_menu_anchor_y: f32 = 0.0,
    context_menu_items: std.ArrayList(BrowserContextMenuItem) = .empty,
    context_menu_link_url: ?[]u8 = null,
    context_menu_selected_index: ?u32 = null,
    context_menu_active_parent: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator) !State {
        return .{ .runtime = try browser_runtime.State.init(allocator) };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.context_menu_items.items) |item| allocator.free(item.label);
        self.context_menu_items.deinit(allocator);
        if (self.context_menu_link_url) |url| allocator.free(url);
        for (self.retained_runtimes.items) |*entry| entry.runtime.deinit();
        self.retained_runtimes.deinit(allocator);
        self.runtime.deinit();
        self.* = undefined;
    }

    pub fn projectMoved(self: *State, from: usize, insert_at: usize) void {
        if (self.runtime_project_index) |runtime_index| {
            self.runtime_project_index = adjustedProjectIndexAfterMove(runtime_index, from, insert_at);
        }
        for (self.retained_runtimes.items) |*entry| {
            entry.project_index = adjustedProjectIndexAfterMove(entry.project_index, from, insert_at);
        }
    }

    pub fn projectRemoved(self: *State, index: usize) bool {
        const removed_active = if (self.runtime_project_index) |runtime_index| runtime_index == index else false;
        if (self.runtime_project_index) |runtime_index| {
            if (removed_active) {
                self.runtime.controller.shutdown();
                self.runtime.setControlsVisible(false);
                self.runtime.status = .hidden;
                self.runtime_project_index = null;
                self.runtime_pane_id = null;
            } else if (runtime_index > index) {
                self.runtime_project_index = runtime_index - 1;
            }
        }

        var retained_index: usize = 0;
        while (retained_index < self.retained_runtimes.items.len) {
            const entry = &self.retained_runtimes.items[retained_index];
            if (entry.project_index == index) {
                entry.runtime.deinit();
                _ = self.retained_runtimes.orderedRemove(retained_index);
                continue;
            }
            if (entry.project_index > index) entry.project_index -= 1;
            retained_index += 1;
        }
        return removed_active;
    }

    /// Makes one workspace's retained WebView current without recreating its page.
    pub fn switchRuntimeToProject(self: *State, allocator: std.mem.Allocator, project_index: usize) !bool {
        if (self.runtime_project_index != null and self.runtime_project_index.? == project_index) return true;

        const retained_index = self.retainedRuntimeIndex(project_index);
        if (self.runtime_project_index != null and retained_index == null) {
            try self.retained_runtimes.ensureUnusedCapacity(allocator, 1);
        }

        var next_pane_id: ?WorkspacePaneId = null;
        var next_runtime = if (retained_index) |index| retained: {
            const retained = self.retained_runtimes.orderedRemove(index);
            next_pane_id = retained.pane_id;
            break :retained retained.runtime;
        } else try browser_runtime.State.init(allocator);
        errdefer next_runtime.deinit();
        next_runtime.controller.test_navigation_capture = self.runtime.controller.test_navigation_capture;

        if (retained_index == null) {
            try next_runtime.controller.setHostWindow(self.runtime.controller.host_window);
            try next_runtime.controller.setPaneBounds(self.runtime.controller.pane_bounds);
        }

        if (self.runtime_project_index) |previous_project_index| {
            const had_backend = self.runtime.controller.hasBackend();
            const hidden = hide: {
                self.runtime.controller.hide() catch |err| {
                    log.warn("failed to hide retained browser runtime: {s}", .{@errorName(err)});
                    break :hide false;
                };
                break :hide true;
            };
            if (had_backend and hidden) self.runtime.suppressNextClosedEvent();
            self.runtime.setControlsVisible(false);
            self.runtime.status = .hidden;
            self.retained_runtimes.appendAssumeCapacity(.{
                .project_index = previous_project_index,
                .pane_id = self.runtime_pane_id,
                .runtime = self.runtime,
            });
        } else {
            self.runtime.deinit();
        }

        self.runtime = next_runtime;
        self.runtime_project_index = project_index;
        self.runtime_pane_id = next_pane_id;
        return retained_index != null;
    }

    /// Destroys a hidden runtime whose browser pane was closed.
    pub fn discardRetainedRuntime(self: *State, project_index: usize) bool {
        const index = self.retainedRuntimeIndex(project_index) orelse return false;
        self.retained_runtimes.items[index].runtime.deinit();
        _ = self.retained_runtimes.orderedRemove(index);
        return true;
    }

    /// Updates exact ownership when a pane is removed from a workspace whose
    /// runtime is retained off-screen. A surviving sibling keeps the runtime
    /// alive but clears its binding so the next activation must navigate to
    /// that sibling instead of presenting the deleted pane's page as its own.
    pub fn reconcileRetainedRuntimePaneRemoval(
        self: *State,
        project_index: usize,
        removed_pane_id: WorkspacePaneId,
        replacement_pane_id: ?WorkspacePaneId,
    ) bool {
        const index = self.retainedRuntimeIndex(project_index) orelse return false;
        if (self.retained_runtimes.items[index].pane_id != removed_pane_id) return false;
        if (replacement_pane_id != null) {
            self.retained_runtimes.items[index].pane_id = null;
        } else {
            self.retained_runtimes.items[index].runtime.deinit();
            _ = self.retained_runtimes.orderedRemove(index);
        }
        return true;
    }

    pub fn shutdownRetainedRuntimes(self: *State, allocator: std.mem.Allocator) void {
        for (self.retained_runtimes.items) |*entry| entry.runtime.deinit();
        self.retained_runtimes.clearAndFree(allocator);
    }

    fn retainedRuntimeIndex(self: *const State, project_index: usize) ?usize {
        for (self.retained_runtimes.items, 0..) |entry, index| {
            if (entry.project_index == project_index) return index;
        }
        return null;
    }

    pub fn beginDevServerProbe(self: *State, project_index: usize, process_index: usize, now_ms: i64) void {
        self.dev_server_project_index = project_index;
        self.dev_server_process_index = process_index;
        self.dev_server_next_check_ms = now_ms;
        self.dev_server_deadline_ms = now_ms + 20_000;
    }

    pub fn clearDevServerProbe(self: *State) void {
        self.dev_server_project_index = null;
        self.dev_server_process_index = null;
        self.dev_server_next_check_ms = 0;
        self.dev_server_deadline_ms = 0;
    }
};

fn adjustedProjectIndexAfterMove(index: usize, from: usize, insert_at: usize) usize {
    if (index == from) return insert_at;
    var adjusted = index;
    if (adjusted > from) adjusted -= 1;
    if (adjusted >= insert_at) adjusted += 1;
    return adjusted;
}

test "browser runtime ownership follows workspace moves and removals" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);
    state.runtime_project_index = 2;

    state.projectMoved(0, 2);
    try std.testing.expectEqual(@as(?usize, 1), state.runtime_project_index);

    state.projectMoved(1, 0);
    try std.testing.expectEqual(@as(?usize, 0), state.runtime_project_index);

    try std.testing.expect(!state.projectRemoved(2));
    try std.testing.expectEqual(@as(?usize, 0), state.runtime_project_index);
    try std.testing.expect(state.projectRemoved(0));
    try std.testing.expectEqual(@as(?usize, null), state.runtime_project_index);
}

test "workspace switches retain each live browser runtime" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    state.runtime_project_index = 0;
    try state.runtime.setCurrentUrl("https://first.example/stateful");

    try std.testing.expect(!try state.switchRuntimeToProject(std.testing.allocator, 1));
    try state.runtime.setCurrentUrl("https://second.example/stateful");
    try std.testing.expectEqual(@as(usize, 1), state.retained_runtimes.items.len);

    try std.testing.expect(try state.switchRuntimeToProject(std.testing.allocator, 0));
    try std.testing.expectEqualStrings("https://first.example/stateful", state.runtime.current_url.?);
    try std.testing.expectEqual(@as(usize, 1), state.retained_runtimes.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.retained_runtimes.items[0].project_index);

    try std.testing.expect(!state.projectRemoved(1));
    try std.testing.expectEqual(@as(usize, 0), state.retained_runtimes.items.len);
}

pub fn attachBrowserHostWindow(self: anytype, handle: ?*anyopaque) void {
    self.browser_controller.runtime.controller.setHostWindow(handle) catch |err| {
        log.warn("failed to attach browser host window: {s}", .{@errorName(err)});
    };
    for (self.browser_controller.retained_runtimes.items) |*entry| {
        entry.runtime.controller.setHostWindow(handle) catch |err| {
            log.warn("failed to attach retained browser host window: {s}", .{@errorName(err)});
        };
    }
}

/// Opens the browser during startup when an explicit debug environment flag requests it.
pub fn openBrowserOnLaunchIfRequested(self: anytype) void {
    if (!self.browser_textures_enabled) return;

    const value = std.mem.sliceTo(std.c.getenv("VERDE_OPEN_BROWSER_ON_START") orelse return, 0);
    if (!std.mem.eql(u8, value, "1")) return;
    self.browser_controller.start_eval_pending = false;
    if (std.c.getenv("VERDE_BROWSER_START_URL")) |raw_start_url| {
        const start_url = std.mem.sliceTo(raw_start_url, 0);
        if (start_url.len > 0) {
            const normalized = self.normalizeBrowserUrl(start_url) catch |err| {
                log.warn("failed to normalize browser startup URL: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to normalize browser startup URL.");
                return;
            };
            defer self.allocator.free(normalized);
            self.browser_controller.runtime.setCurrentUrl(normalized) catch |err| {
                log.warn("failed to store browser startup URL: {s}", .{@errorName(err)});
                return;
            };
            self.browser_controller.runtime.setAddress(normalized);
        }
    }
    if (std.c.getenv("VERDE_BROWSER_START_EVAL")) |raw_start_eval| {
        self.browser_controller.start_eval_pending = std.mem.sliceTo(raw_start_eval, 0).len > 0;
    }
    // Wait a couple of app-loop turns so this exercises the same path as a
    // user click after the window is live instead of front-loading browser
    // creation before the first frame.
    self.browser_controller.launch_open_delay_frames = 2;
}

/// Reopens the browser runtime when the selected project restored a visible browser workspace pane.
pub fn restorePersistedBrowserPaneOnLaunch(self: anytype) void {
    if (!self.browser_textures_enabled) return;
    if (self.browser_controller.launch_open_delay_frames > 0 or self.browser_controller.runtime.controls_visible) return;
    if (self.project_controller.projects.items.len == 0) return;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    if (!layout.hasVisiblePaneKind(.browser)) return;
    if (layout.visibleBrowserPaneId()) |pane_id| {
        self.applyBrowserPaneSnapshotToRuntime(self.project_controller.selected_index, pane_id);
    }
    self.browser_controller.launch_open_delay_frames = 2;
}

/// Applies keyboard focus on launch based on the restored focused pane, so a
/// reopened terminal (or browser/chat) pane is immediately typeable instead
/// of requiring a manual mouse click to start receiving input.
pub fn applyInitialWorkspaceFocusOnLaunch(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane_id = if (layout.focused_pane_id) |focused_pane_id|
        if (layout.paneById(focused_pane_id) != null) focused_pane_id else layout.firstVisiblePaneId() orelse return
    else
        layout.firstVisiblePaneId() orelse return;
    _ = self.restoreWorkspacePaneFocus(self.project_controller.selected_index, pane_id);
}

/// Toggles the desktop browser control surface and the underlying browser runtime.
pub fn toggleBrowser(self: anytype) void {
    if (!self.browser_textures_enabled) {
        self.setSidebarNotice("Browser is disabled for the SDL_GPU non-image renderer experiment.");
        return;
    }

    const browser_workspace_index = self.browserWorkspaceIndex();
    if (browserToggleCloses(
        self.browser_controller.runtime.controls_visible,
        browser_workspace_index,
        self.project_controller.selected_index,
    )) {
        self.closeBrowser();
        return;
    }

    self.ensureCurrentProjectWorkspace();
    if (self.project_controller.projects.items.len == 0) return;
    const result = self.openBrowserInWorkspace(self.project_controller.selected_index, null) catch |err| {
        log.err("failed to activate workspace browser pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to open browser pane.");
        return;
    };
    _ = self.focusCurrentProjectWorkspacePane(result.pane_id);
    self.browser_controller.address_focused = true;
    self.browser_controller.address_cursor = self.browser_controller.runtime.addressInput().len;
    self.unfocusBrowserPane();
    self.terminal_controller.focused = false;
    self.composer_controller.focused = false;
    self.blurNativeBrowserForAddressField();
    self.setSidebarNotice("Browser opened in this workspace.");
}

/// Ensures a workspace-local browser pane exists and activates its retained runtime.
pub fn openBrowserInWorkspace(self: anytype, project_index: usize, url: ?[]const u8) !BrowserOpenResult {
    return openBrowserInWorkspaceWithDirtyPolicy(self, project_index, url, null, true);
}

fn openBrowserInWorkspaceWithDirtyPolicy(
    self: anytype,
    project_index: usize,
    url: ?[]const u8,
    restore_pane_id: ?WorkspacePaneId,
    mark_dirty: bool,
) !BrowserOpenResult {
    if (!self.browser_textures_enabled) {
        self.setSidebarNotice("Browser is disabled for the SDL_GPU non-image renderer experiment.");
        return error.BrowserDisabled;
    }
    if (project_index >= self.project_controller.projects.items.len) return error.WorkspaceNotFound;

    const previous_runtime_workspace = self.browser_controller.runtime_project_index;
    const switching_workspace = previous_runtime_workspace == null or previous_runtime_workspace.? != project_index;
    const restored_live_runtime = try self.browser_controller.switchRuntimeToProject(self.allocator, project_index);
    const selected_index = self.project_controller.selected_index;
    const selected_focus = if (selected_index < self.project_controller.projects.items.len)
        self.project_controller.projects.items[selected_index].workspace_layout.focused_pane_id
    else
        null;
    const selected_focus_was_browser = if (selected_focus) |pane_id| focused: {
        const kind = self.workspacePaneKind(selected_index, pane_id) orelse break :focused false;
        break :focused kind == .browser;
    } else false;

    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const browser_pane_id = if (restore_pane_id) |pane_id| exact: {
        const pane = layout.paneById(pane_id) orelse return error.BrowserPaneNotFound;
        switch (pane.ref) {
            .browser => break :exact pane_id,
            else => return error.BrowserPaneNotFound,
        }
    } else try layout.ensureBrowserPane(self.allocator);
    if (restore_pane_id == null) layout.maximized_pane_id = null;
    const binding_changed = self.browser_controller.runtime_pane_id != browser_pane_id;
    if (!restored_live_runtime or binding_changed) self.applyBrowserPaneSnapshotToRuntime(project_index, browser_pane_id);
    const restore_url = self.browserPaneSnapshotUrl(project_index, browser_pane_id);

    if (project_index == selected_index) {
        self.restoreWorkspaceFocusIfVisible(project_index, selected_focus, browser_pane_id);
    } else {
        self.restoreWorkspaceFocusIfVisible(selected_index, selected_focus, null);
        if (selected_focus_was_browser) self.unfocusBrowserPane();
    }

    self.browser_controller.runtime.setControlsVisible(true);
    self.browser_controller.address_focused = false;
    self.browser_controller.inspector_menu_open = false;
    self.browser_controller.address_cursor = self.browser_controller.runtime.addressInput().len;

    if (url) |target_url| {
        try self.navigateBrowserToUrl(target_url);
    } else if (!restored_live_runtime or binding_changed or !self.browser_controller.runtime.controller.runtimeInitialized()) {
        const restored_url = restore_url orelse "about:blank";
        if (mark_dirty) {
            try self.navigateBrowserToUrl(restored_url);
        } else {
            try navigateBrowserRuntimeForRestore(self, restored_url);
        }
    } else if (switching_workspace or project_index == selected_index or !self.browser_controller.surface_suspended_for_layout) {
        try self.showBrowserRuntimeForLiveOpen();
    }
    self.browser_controller.runtime_pane_id = browser_pane_id;

    if (project_index == selected_index) {
        self.restoreBrowserSurfaceForRenderedLayout();
        self.syncBrowserPaneBoundsToBackend();
    } else {
        self.noteBrowserPaneNotRendered();
    }

    if (mark_dirty) {
        self.setSidebarNotice("Browser opened.");
        self.markDirty();
    }
    return .{
        .pane_id = browser_pane_id,
        .workspace_index = project_index,
        .moved_from_workspace = null,
    };
}

fn navigateBrowserRuntimeForRestore(self: anytype, value: []const u8) !void {
    const normalized = try self.normalizeBrowserUrl(value);
    defer self.allocator.free(normalized);
    self.restartBrowserRuntimeForCrossOriginNavigation(normalized);
    self.browser_controller.runtime.status = .opening;
    self.setActiveBrowserTabLoadState(true, false);
    self.browser_controller.runtime.controller.navigate(normalized) catch |err| {
        log.err("failed to restore browser runtime navigation: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.setActiveBrowserTabLoadState(false, true);
        self.browser_controller.runtime.setLastError("Failed to restore browser runtime.") catch {};
        return error.BrowserNavigationFailed;
    };
    self.browser_controller.runtime.setAddress(normalized);
    self.browser_controller.address_cursor = self.browser_controller.runtime.addressInput().len;
}

/// Binds the shared browser runtime to an existing browser pane in a workspace.
pub fn activateBrowserInWorkspace(self: anytype, project_index: usize) !BrowserOpenResult {
    if (project_index >= self.project_controller.projects.items.len) return error.WorkspaceNotFound;
    const layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const pane_id = preferredBrowserPaneId(layout) orelse return error.BrowserNotVisible;
    if (self.browser_controller.runtime.controls_visible) {
        if (self.browser_controller.runtime_project_index) |runtime_project_index| {
            if (runtime_project_index == project_index and self.browser_controller.runtime_pane_id == pane_id) {
                return .{
                    .pane_id = pane_id,
                    .workspace_index = project_index,
                    .moved_from_workspace = null,
                };
            }
            if (runtime_project_index == project_index) {
                return openBrowserInWorkspaceWithDirtyPolicy(self, project_index, null, pane_id, false);
            }
        }
    }
    return openBrowserInWorkspaceWithDirtyPolicy(self, project_index, null, pane_id, true);
}

fn preferredBrowserPaneId(layout: anytype) ?WorkspacePaneId {
    if (layout.focused_pane_id) |pane_id| {
        if (layout.paneById(pane_id)) |pane| {
            switch (pane.ref) {
                .browser => return pane_id,
                else => {},
            }
        }
    }
    return layout.visibleBrowserPaneId();
}

/// Removes one workspace's browser pane without disturbing browser snapshots in other workspaces.
pub fn closeBrowserInWorkspace(self: anytype, project_index: usize) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const pane_id = self.project_controller.projects.items[project_index].workspace_layout.visibleBrowserPaneId() orelse return false;
    if (self.browser_controller.runtime_project_index) |runtime_project_index| {
        if (runtime_project_index == project_index) {
            self.closeBrowser();
            return true;
        }
    }
    var removed_ref = self.project_controller.projects.items[project_index].workspace_layout.closePane(self.allocator, pane_id) orelse return false;
    deinitWorkspacePaneRef(&removed_ref, self.allocator);
    self.reconcileBrowserRuntimeAfterPaneRemoval(project_index, pane_id);
    self.setSidebarNotice("Browser closed in workspace.");
    self.markDirty();
    return true;
}

/// Navigates the browser runtime through the same normalization path used by the address field.
pub fn navigateBrowserToUrl(self: anytype, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.EmptyBrowserUrl;

    const normalized = try self.normalizeBrowserUrl(trimmed);
    defer self.allocator.free(normalized);

    self.restartBrowserRuntimeForCrossOriginNavigation(normalized);
    self.browser_controller.runtime.status = .opening;
    self.setActiveBrowserTabLoadState(true, false);
    self.browser_controller.runtime.controller.navigate(normalized) catch |err| {
        log.err("failed to navigate browser runtime: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.setActiveBrowserTabLoadState(false, true);
        self.browser_controller.runtime.setLastError("Failed to navigate browser runtime.") catch {};
        self.setSidebarNotice("Browser navigation failed.");
        return error.BrowserNavigationFailed;
    };
    self.browser_controller.runtime.setAddress(normalized);
    self.browser_controller.address_cursor = self.browser_controller.runtime.addressInput().len;
    self.recordVisibleBrowserPaneNavigation(normalized);
    self.setSidebarNotice("Browser navigation requested.");
}

/// Recreates only the embedded browser backend, optionally restoring its URL.
pub fn recoverBrowser(self: anytype, restore_url: bool) !void {
    const current_url = if (restore_url)
        if (self.browser_controller.runtime.current_url) |url| try self.allocator.dupe(u8, url) else null
    else
        null;
    defer if (current_url) |url| self.allocator.free(url);

    self.unfocusBrowserPane();
    self.clearBrowserContextMenuLocal();
    self.browser_controller.runtime.clearSuppressedEvalResults();
    try self.browser_controller.runtime.setLastEvalResult(null);
    try self.browser_controller.runtime.setLastError(null);
    self.browser_controller.runtime.controller.shutdown();
    self.browser_controller.runtime.status = .opening;

    if (current_url) |url| {
        try self.browser_controller.runtime.controller.navigate(url);
    } else {
        try self.browser_controller.runtime.controller.navigate("about:blank");
        try self.browser_controller.runtime.setCurrentUrl("about:blank");
        self.browser_controller.runtime.setAddress("about:blank");
        self.recordVisibleBrowserPaneNavigation("about:blank");
    }
    self.browser_controller.runtime.setControlsVisible(true);
    self.setSidebarNotice(if (restore_url) "Browser restarted." else "Browser reset.");
    self.markDirty();
}

/// Injects a pane-local automation pointer event when the backend supports it.
pub fn injectBrowserPointer(self: anytype, event: browser_runtime.MouseEvent) !void {
    if (!self.browser_controller.runtime.controller.supportsLowLevelPointer()) return error.UnsupportedBrowserCapability;
    var pane_event = event;
    const device_scale = self.browserPaneDeviceScale();
    pane_event.x = browserAutomationPointerCoordinate(event.x, device_scale);
    pane_event.y = browserAutomationPointerCoordinate(event.y, device_scale);
    if (!try self.browser_controller.runtime.controller.handleMouse(pane_event)) return error.UnsupportedBrowserCapability;
}

/// Returns the workspace whose pane currently owns the shared browser runtime.
pub fn browserWorkspaceLocation(self: anytype) ?BrowserWorkspaceLocation {
    const index = self.browser_controller.runtime_project_index orelse return null;
    if (index >= self.project_controller.projects.items.len) return null;
    const pane_id = self.browser_controller.runtime_pane_id orelse return null;
    const pane = self.project_controller.projects.items[index].workspace_layout.paneById(pane_id) orelse return null;
    switch (pane.ref) {
        .browser => {},
        else => return null,
    }
    return .{ .index = index, .pane_id = pane_id };
}

/// Returns the workspace whose pane currently owns the shared browser runtime.
pub fn browserWorkspaceIndex(self: anytype) ?usize {
    const location = self.browserWorkspaceLocation() orelse return null;
    return location.index;
}

/// Returns the pane currently bound to the shared browser runtime, if any.
pub fn browserWorkspacePaneId(self: anytype) ?WorkspacePaneId {
    const location = self.browserWorkspaceLocation() orelse return null;
    return location.pane_id;
}

/// Returns a workspace's persisted browser pane independently of runtime ownership.
pub fn browserPaneIdInWorkspace(self: anytype, project_index: usize) ?WorkspacePaneId {
    if (project_index >= self.project_controller.projects.items.len) return null;
    return self.project_controller.projects.items[project_index].workspace_layout.visibleBrowserPaneId();
}

pub fn browserPaneRefMutable(self: anytype, project_index: usize, pane_id: WorkspacePaneId) ?*BrowserPaneRef {
    if (project_index >= self.project_controller.projects.items.len) return null;
    const pane = self.project_controller.projects.items[project_index].workspace_layout.paneByIdMutable(pane_id) orelse return null;
    return switch (pane.ref) {
        .browser => |*ref| ref,
        else => null,
    };
}

pub fn visibleBrowserPaneRefMutable(self: anytype) ?*BrowserPaneRef {
    const location = self.browserWorkspaceLocation() orelse return null;
    return self.browserPaneRefMutable(location.index, location.pane_id);
}

pub fn browserPaneSnapshotUrl(self: anytype, project_index: usize, pane_id: WorkspacePaneId) ?[]const u8 {
    const ref = self.browserPaneRefMutable(project_index, pane_id) orelse return null;
    const tab = ref.activeTab() orelse return null;
    return tab.url;
}

// Workspace browser panes retain their live runtime while inactive.
pub fn restorePersistedBrowserPaneAfterProjectSelection(self: anytype, project_index: usize) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const layout = &self.project_controller.projects.items[project_index].workspace_layout;
    if (layout.visibleBrowserPaneId() == null) {
        // Keep the one live page hidden so its DOM state survives while
        // the selected workspace has no browser pane.
        self.noteBrowserPaneNotRendered();
        return;
    }
    const maximized_pane_id = layout.maximized_pane_id;
    if (!self.browser_textures_enabled) return;

    // Rebinding an existing browser runtime is workspace restoration, not an
    // explicit browser-open action, so it must not change the pane zoom state.
    defer layout.maximized_pane_id = maximized_pane_id;
    const restore_pane_id = if (layout.focused_pane_id) |focused_pane_id| focused: {
        const pane = layout.paneById(focused_pane_id) orelse break :focused layout.visibleBrowserPaneId().?;
        break :focused switch (pane.ref) {
            .browser => focused_pane_id,
            else => layout.visibleBrowserPaneId().?,
        };
    } else layout.visibleBrowserPaneId().?;
    _ = openBrowserInWorkspaceWithDirtyPolicy(self, project_index, null, restore_pane_id, false) catch |err| {
        log.warn("failed to restore browser pane after workspace selection: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to restore browser pane after selecting its workspace.") catch {};
        self.setSidebarNotice("Failed to reopen browser.");
        return;
    };
}

pub fn applyBrowserPaneSnapshotToRuntime(self: anytype, project_index: usize, pane_id: WorkspacePaneId) void {
    const ref = self.browserPaneRefMutable(project_index, pane_id) orelse return;
    const tab = ref.activeTab() orelse return;
    self.browser_controller.runtime.setCurrentUrl(tab.url) catch |err| {
        log.warn("failed to restore browser pane URL: {s}", .{@errorName(err)});
    };
    self.browser_controller.runtime.setCurrentTitle(tab.title) catch |err| {
        log.warn("failed to restore browser pane title: {s}", .{@errorName(err)});
    };
    self.browser_controller.runtime.setAddress(tab.url orelse "");
    self.browser_controller.address_cursor = self.browser_controller.runtime.addressInput().len;
}

pub fn recordVisibleBrowserPaneNavigation(self: anytype, url: []const u8) void {
    if (!browserNavigationUrlIsPersistable(url)) return;
    const ref = self.visibleBrowserPaneRefMutable() orelse return;
    const tab = ref.activeTab() orelse return;
    if (isBlankBrowserUrl(url)) {
        if (tab.url) |existing_url| {
            if (!isBlankBrowserUrl(existing_url)) return;
        }
    }
    tab.recordNavigation(self.allocator, url) catch |err| {
        log.warn("failed to persist browser pane URL history: {s}", .{@errorName(err)});
        return;
    };
    self.markDirty();
}

pub fn recordVisibleBrowserPaneTitle(self: anytype, title: []const u8) void {
    const ref = self.visibleBrowserPaneRefMutable() orelse return;
    const tab = ref.activeTab() orelse return;
    tab.setTitle(self.allocator, title) catch |err| {
        log.warn("failed to persist browser pane title: {s}", .{@errorName(err)});
        return;
    };
    self.markDirty();
}

pub fn setActiveBrowserTabLoadState(self: anytype, loading: bool, failed: bool) void {
    const ref = self.visibleBrowserPaneRefMutable() orelse return;
    const tab = ref.activeTab() orelse return;
    tab.loading = loading;
    tab.load_failed = failed;
}

pub fn navigatePersistedBrowserHistory(self: anytype, delta: i32) bool {
    const ref = self.visibleBrowserPaneRefMutable() orelse return false;
    const tab = ref.activeTab() orelse return false;
    const target = tab.historyTarget(delta) orelse return false;
    tab.history_index = target.index;
    tab.setUrl(self.allocator, target.url) catch |err| {
        log.warn("failed to update persisted browser history index: {s}", .{@errorName(err)});
        return false;
    };
    self.restartBrowserRuntimeForCrossOriginNavigation(target.url);
    self.browser_controller.runtime.status = .opening;
    self.browser_controller.runtime.controller.navigate(target.url) catch |err| {
        log.warn("failed to navigate persisted browser history: {s}", .{@errorName(err)});
        self.browser_controller.runtime.setLastError("Failed to navigate browser history.") catch {};
        return false;
    };
    self.browser_controller.runtime.setCurrentUrl(target.url) catch {};
    self.browser_controller.runtime.setAddress(target.url);
    self.browser_controller.address_cursor = self.browser_controller.runtime.addressInput().len;
    self.markDirty();
    return true;
}

pub fn restartBrowserRuntimeForCrossOriginNavigation(self: anytype, target_url: []const u8) void {
    if (!self.browser_controller.runtime.controller.runtimeInitialized()) return;
    const current_url = self.browser_controller.runtime.current_url orelse return;
    if (browserUrlsHaveSameOrigin(current_url, target_url)) return;
    // WebKit's WPE port retains site processes while swapping them through
    // the one legacy FDO exportable. A fresh helper is the only public,
    // deterministic process-pool boundary available to this backend.
    self.browser_controller.runtime.controller.shutdown();
}

pub fn showBrowserRuntimeForLiveOpen(self: anytype) !void {
    self.browser_controller.runtime.status = .opening;
    self.browser_controller.runtime.controller.show() catch |err| {
        log.err("failed to show browser runtime: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to show browser runtime.") catch {};
        self.setSidebarNotice("Failed to show browser.");
        return error.BrowserOpenFailed;
    };
}

pub fn restoreWorkspaceFocusIfVisible(self: anytype, project_index: usize, pane_id: ?WorkspacePaneId, except_pane_id: ?WorkspacePaneId) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const wanted = pane_id orelse return;
    if (except_pane_id != null and except_pane_id.? == wanted) return;
    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    _ = layout.paneById(wanted) orelse return;
    layout.focused_pane_id = wanted;
}

pub fn workspacePaneKind(self: anytype, project_index: usize, pane_id: WorkspacePaneId) ?WorkspacePaneKind {
    if (project_index >= self.project_controller.projects.items.len) return null;
    const pane = self.project_controller.projects.items[project_index].workspace_layout.paneById(pane_id) orelse return null;
    return std.meta.activeTag(pane.ref);
}

pub fn blurNativeBrowserForAddressField(self: anytype) void {
    if (!self.browser_controller.address_focused) return;
    self.browser_controller.runtime.controller.blur() catch |err| {
        log.warn("failed to clear native browser focus for address field: {s}", .{@errorName(err)});
    };
}

pub fn deactivateBrowserRuntime(self: anytype, shutdown: bool) void {
    self.browser_controller.runtime.setControlsVisible(false);
    self.browser_controller.runtime.setInspectorEnabled(false);
    self.browser_controller.runtime.clearSuppressedEvalResults();
    self.browser_controller.surface_suspended_for_palette_overlay = false;
    self.browser_controller.surface_suspended_for_layout = false;
    self.browser_controller.surface_suspended_for_empty_state = false;
    self.unfocusBrowserPane();
    self.browser_controller.pane_hovered = false;
    self.browser_controller.cursor_shape = .default;
    self.browser_controller.address_focused = false;
    self.browser_controller.inspector_menu_open = false;
    if (shutdown) {
        self.browser_controller.runtime.controller.shutdown();
    } else {
        self.browser_controller.runtime.controller.hide() catch |err| {
            log.warn("failed to hide inactive browser runtime: {s}", .{@errorName(err)});
        };
        self.suppressNextBrowserClosedEvent();
    }
    self.browser_controller.runtime.status = .hidden;
    self.browser_controller.runtime.setLastError(null) catch {};
    self.browser_controller.runtime_project_index = null;
    self.browser_controller.runtime_pane_id = null;
}

/// Reports whether any open workspace still owns a browser pane.
pub fn hasWorkspaceBrowserPane(self: anytype) bool {
    for (self.project_controller.projects.items) |*project| {
        if (project.workspace_layout.hasVisiblePaneKind(.browser)) return true;
    }
    return false;
}

/// Destroys only the removed pane's runtime while preserving other workspace sessions.
pub fn reconcileBrowserRuntimeAfterPaneRemoval(self: anytype, project_index: usize, removed_pane_id: WorkspacePaneId) void {
    const replacement_pane_id = if (project_index < self.project_controller.projects.items.len)
        preferredBrowserPaneId(&self.project_controller.projects.items[project_index].workspace_layout)
    else
        null;
    const removed_active_owner = if (self.browser_controller.runtime_project_index) |runtime_project_index|
        runtime_project_index == project_index and self.browser_controller.runtime_pane_id == removed_pane_id
    else
        false;
    if (removed_active_owner) {
        if (replacement_pane_id) |replacement| {
            _ = openBrowserInWorkspaceWithDirtyPolicy(self, project_index, null, replacement, false) catch |err| {
                log.warn("failed to transfer browser runtime after bound pane removal: {s}", .{@errorName(err)});
                self.deactivateBrowserRuntime(true);
            };
        } else {
            self.deactivateBrowserRuntime(true);
        }
    } else {
        _ = self.browser_controller.reconcileRetainedRuntimePaneRemoval(project_index, removed_pane_id, replacement_pane_id);
    }
    if (!self.hasWorkspaceBrowserPane()) {
        self.deactivateBrowserRuntime(true);
        self.browser_controller.shutdownRetainedRuntimes(self.allocator);
    }
}

/// Closes the active workspace's browser pane and releases an otherwise unused runtime.
pub fn closeBrowser(self: anytype) void {
    const project_index = self.browser_controller.runtime_project_index orelse self.project_controller.selected_index;
    if (project_index < self.project_controller.projects.items.len) {
        _ = self.project_controller.projects.items[project_index].workspace_layout.closePaneKind(self.allocator, .browser);
    }
    if (self.browser_controller.runtime_project_index == project_index) {
        self.deactivateBrowserRuntime(true);
    } else {
        _ = self.browser_controller.discardRetainedRuntime(project_index);
    }
    if (!self.hasWorkspaceBrowserPane()) self.browser_controller.shutdownRetainedRuntimes(self.allocator);
    self.ensureCurrentProjectWorkspace();
    self.setSidebarNotice("Browser closed.");
    self.markDirty();
}

/// Temporarily hides the native browser surface while the host SDL window is hidden/minimized.
pub fn suspendBrowserForHostWindowHidden(self: anytype) void {
    if (!self.isBrowserRuntimeActive()) return;
    self.unfocusBrowserPane();
    self.browser_controller.address_focused = false;
    self.browser_controller.runtime.controller.hide() catch |err| {
        log.warn("failed to hide browser runtime for host window lifecycle: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to hide browser runtime while the app window changed visibility.") catch {};
        return;
    };
    self.suppressNextBrowserClosedEvent();
}

/// Restores a visible browser dock after the host SDL window is shown/restored.
pub fn resumeBrowserAfterHostWindowShown(self: anytype) void {
    if (!self.isBrowserRuntimeActive()) return;
    const runtime_project_index = self.browser_controller.runtime_project_index orelse return;
    if (runtime_project_index != self.project_controller.selected_index) return;
    if (self.browser_controller.surface_suspended_for_empty_state) return;
    self.browser_controller.runtime.status = .opening;
    self.browser_controller.runtime.controller.show() catch |err| {
        log.warn("failed to restore browser runtime after host window lifecycle: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to restore browser runtime after the app window became visible.") catch {};
        return;
    };
    self.syncBrowserPaneBoundsToBackend();
}

/// Reports whether the selected workspace owns the active browser runtime.
pub fn isBrowserVisible(self: anytype) bool {
    return self.isBrowserRuntimeActiveInWorkspace(self.project_controller.selected_index);
}

/// Reports whether any workspace currently owns the shared browser runtime.
pub fn isBrowserRuntimeActive(self: anytype) bool {
    return self.browser_controller.runtime.controls_visible and self.browserWorkspaceLocation() != null;
}

/// Reports whether a specific workspace currently owns the shared browser runtime.
pub fn isBrowserRuntimeActiveInWorkspace(self: anytype, project_index: usize) bool {
    if (!self.browser_controller.runtime.controls_visible) return false;
    const runtime_project_index = self.browser_controller.runtime_project_index orelse return false;
    return runtime_project_index == project_index and self.browserPaneIdInWorkspace(project_index) != null;
}

/// Reports whether the current browser runtime can host the bundled page inspector.
pub fn canUseBrowserInspector(self: anytype) bool {
    return self.browser_controller.runtime.controller.supportsInspector();
}

pub fn browserBridgePolicyAllowsCurrentPage(self: anytype) bool {
    const page_url = if (self.browser_controller.runtime.current_url) |url| url else self.browser_controller.runtime.addressInput();
    return (browser_runtime.BridgePolicy{
        .allow_untrusted = browserBridgePolicyAllowsUntrustedPages(),
    }).allowsHostMessaging(page_url);
}

pub fn browserInspectorPolicyAllowsCurrentPage(self: anytype) bool {
    const page_url = if (self.browser_controller.runtime.current_url) |url| url else self.browser_controller.runtime.addressInput();
    return (browser_runtime.BridgePolicy{
        .allow_untrusted = browserBridgePolicyAllowsUntrustedPages(),
    }).allowsInspector(page_url);
}

pub fn browserBridgePolicyAllowsUntrustedPages() bool {
    const raw = std.c.getenv("VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE") orelse return false;
    const value = std.mem.trim(u8, std.mem.sliceTo(raw, 0), &std.ascii.whitespace);
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

/// Reports whether the bundled browser inspector is currently armed.
pub fn isBrowserInspectorEnabled(self: anytype) bool {
    return self.browser_controller.runtime.inspectorEnabled();
}

/// Reports which interaction mode the bundled browser inspector will use.
pub fn browserInspectorMode(self: anytype) browser_runtime.InspectorMode {
    return self.browser_controller.runtime.inspectorMode();
}

/// Reports whether the browser inspector mode menu is open in Palette UI.
pub fn isBrowserInspectorMenuOpen(self: anytype) bool {
    return self.browser_controller.inspector_menu_open;
}

/// Reports whether a Palette overlay has temporarily hidden the native browser surface.
pub fn isBrowserSurfaceSuspendedForPaletteOverlay(self: anytype) bool {
    return self.browser_controller.surface_suspended_for_palette_overlay;
}

pub fn isBrowserSurfaceSuspendedForLayout(self: anytype) bool {
    return self.browser_controller.surface_suspended_for_layout;
}

pub fn isBrowserSurfaceSuspendedForEmptyState(self: anytype) bool {
    return self.browser_controller.surface_suspended_for_empty_state;
}

/// Reports whether the workspace header Open menu is currently open.
pub fn isWorkspaceHeaderOpenMenuOpen(self: anytype) bool {
    return self.workspace_header_open_menu_open;
}

/// Reports whether the Add Project modal is currently open.
pub fn isProjectImportModalOpen(self: anytype) bool {
    return self.project_controller.show_creator;
}

/// Reports whether the Thread Import modal is currently open.
pub fn isThreadImportModalOpen(self: anytype) bool {
    return self.thread_import_provider != null;
}

/// Reports whether the image preview modal is currently open.
pub fn isImageModalOpen(self: anytype) bool {
    return self.modal_image_path != null;
}

/// Reports whether the transcript selection modal is currently open.
pub fn isTranscriptSelectionModalOpen(self: anytype) bool {
    return self.transcript_controller.selection_text != null;
}

/// Reports which Palette modal text field owns focus.
pub fn paletteModalTextFocusName(self: anytype) []const u8 {
    return @tagName(self.palette_modal_text_focus);
}

/// Reports whether a sidebar context menu is open over the workspace.
pub fn isSidebarContextMenuOpen(self: anytype) bool {
    return self.sidebar_context_menu_open;
}

/// Reports whether a composer-owned menu/popover is open over the workspace.
pub fn isComposerMenuOpen(self: anytype) bool {
    return self.composer_controller.locked_model_picker_open or
        self.composer_controller.composer.active_menu != null or
        self.composer_controller.model_picker.isOpen() or
        self.composer_controller.run_config_open;
}

/// Opens or closes the browser inspector mode menu for live parity smokes.
pub fn setBrowserInspectorMenuOpen(self: anytype, open: bool) bool {
    if (open and (!self.isBrowserVisible() or !self.canUseBrowserInspector())) return false;
    self.browser_controller.inspector_menu_open = open;
    if (open) {
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    }
    self.syncBrowserPaneBoundsToBackend();
    return true;
}

/// Opens or closes the workspace header Open menu for live overlay parity smokes.
pub fn setWorkspaceHeaderOpenMenuOpen(self: anytype, open: bool) void {
    self.workspace_header_open_menu_open = open;
    if (!open) self.workspace_header_open_menu_pane_id = null;
    if (open) {
        self.browser_controller.inspector_menu_open = false;
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    }
    self.syncBrowserPaneBoundsToBackend();
}

/// Opens or closes a sidebar context menu for live overlay parity smokes.
pub fn setSidebarContextMenuOpen(self: anytype, open: bool) void {
    self.sidebar_context_menu_open = open;
    self.sidebar_context_menu_kind = if (open) .project else .none;
    if (open) {
        self.browser_controller.inspector_menu_open = false;
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    }
    self.syncBrowserPaneBoundsToBackend();
}

/// Opens or closes a composer-owned menu for live overlay parity smokes.
pub fn setComposerMenuOpen(self: anytype, open: bool) void {
    if (open) {
        self.openRunConfigPopover();
        // Empty workspaces cannot host the run-config popover (no current
        // thread), but live parity smokes still expect the overlay flag to
        // report open; fall back to the composer's inert menu marker.
        if (!self.composer_controller.run_config_open) {
            self.composer_controller.composer.active_menu = .reasoning;
            self.composer_controller.composer.hovered_menu_index = 0;
        }
        self.composer_controller.locked_model_picker_open = false;
        self.closePaletteModelPicker();
        self.browser_controller.inspector_menu_open = false;
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    } else {
        self.composer_controller.composer.active_menu = null;
        self.composer_controller.composer.hovered_menu_index = null;
        self.composer_controller.locked_model_picker_open = false;
        self.closePaletteModelPicker();
        self.closeRunConfigPopover();
    }
    self.syncBrowserPaneBoundsToBackend();
}

/// Opens or closes the Add Project modal for live overlay parity smokes.
pub fn setProjectImportModalOpen(self: anytype, open: bool) void {
    if (open) {
        self.project_controller.show_creator = true;
        self.palette_modal_text_focus = .project_import;
        self.project_import_cursor = self.importDirectoryDraft().len;
        self.browser_controller.inspector_menu_open = false;
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    } else {
        self.cancelProjectImport();
    }
    self.syncBrowserPaneBoundsToBackend();
}

/// Opens or closes the Thread Import modal for live overlay parity smokes.
pub fn setThreadImportModalOpen(self: anytype, open: bool) void {
    if (open) {
        self.thread_import_provider = .codex;
        self.thread_import_project_index = self.project_controller.selected_index;
        self.thread_import_selected_index = null;
        self.import_thread_id_storage[0] = 0;
        self.palette_modal_text_focus = .thread_import;
        self.thread_import_cursor = 0;
        self.browser_controller.inspector_menu_open = false;
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    } else {
        self.cancelThreadImport();
    }
    self.syncBrowserPaneBoundsToBackend();
}

/// Opens or closes the image preview modal for live overlay parity smokes.
pub fn setImageModalOpen(self: anytype, open: bool) void {
    if (open) {
        self.openImageModal("live-smoke-image.png");
        self.browser_controller.inspector_menu_open = false;
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    } else {
        self.closeImageModal();
    }
    self.syncBrowserPaneBoundsToBackend();
}

/// Opens or closes the transcript selection modal for live overlay parity smokes.
pub fn setTranscriptSelectionModalOpen(self: anytype, open: bool) void {
    if (open) {
        self.closeTranscriptSelectionModal();
        self.transcript_controller.selection_text = self.allocator.dupeZ(u8, "Live transcript selection smoke") catch null;
        self.transcript_controller.selection_modal_requested = true;
        self.browser_controller.inspector_menu_open = false;
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.browser_controller.address_focused = false;
        self.unfocusBrowserPane();
    } else {
        self.closeTranscriptSelectionModal();
    }
    self.syncBrowserPaneBoundsToBackend();
}

/// Computes the height reserved for the browser dock inside the chat workspace.
pub fn browserPanelHeight(self: anytype, available_height: f32) f32 {
    if (!self.isBrowserVisible()) return 0.0;
    return theme.clampf(available_height * 0.24, theme.scaledUi(182.0), @min(theme.scaledUi(320.0), available_height * 0.42));
}

/// Computes the width reserved for the browser pane when the chat workspace is split horizontally.
pub fn browserPanelWidth(self: anytype, available_width: f32) f32 {
    if (!self.isBrowserVisible()) return 0.0;
    return theme.clampf(available_width * 0.5, theme.scaledUi(320.0), available_width * 0.62);
}

/// Records the latest browser pane bounds plus the helper input size so SDL events can be remapped correctly.
pub fn noteBrowserPaneRegion(self: anytype, min: [2]f32, max: [2]f32, input_size: [2]f32, hovered: bool) void {
    self.browser_controller.pane_min = min;
    self.browser_controller.pane_max = max;
    self.browser_controller.pane_input_size = input_size;
    self.browser_controller.pane_hovered = hovered;
    self.restoreBrowserSurfaceForRenderedLayout();
    self.syncBrowserPaneBoundsToBackend();
}

/// Keeps native child surfaces behind Palette while the useful browser empty state is rendered.
pub fn noteBrowserEmptyStateRendered(self: anytype, is_empty: bool) void {
    const uses_native_surface = switch (self.browser_controller.runtime.controller.presentationKind()) {
        .native_child_view, .native_wayland_surface, .helper_window => true,
        .snapshot_texture, .offscreen_texture, .stub => false,
    };
    const should_suspend = is_empty and uses_native_surface;
    if (should_suspend == self.browser_controller.surface_suspended_for_empty_state) return;

    if (should_suspend) {
        self.browser_controller.runtime.controller.hide() catch |err| {
            log.warn("failed to hide native browser for empty state: {s}", .{@errorName(err)});
            return;
        };
        self.suppressNextBrowserClosedEvent();
        self.browser_controller.surface_suspended_for_empty_state = true;
        self.unfocusBrowserPane();
        return;
    }

    self.browser_controller.surface_suspended_for_empty_state = false;
    if (!self.isBrowserVisible() or self.browser_controller.surface_suspended_for_layout or
        self.browser_controller.surface_suspended_for_palette_overlay or self.browserBlockedByPaletteOverlay()) return;
    self.browser_controller.runtime.status = .opening;
    self.browser_controller.runtime.controller.show() catch |err| {
        log.warn("failed to restore native browser after empty state: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to restore browser runtime after the empty state.") catch {};
        return;
    };
    self.syncBrowserPaneBoundsToBackend();
}

pub fn noteBrowserPaneNotRendered(self: anytype) void {
    if (!self.isBrowserRuntimeActive()) return;
    self.browser_controller.pane_hovered = false;
    self.browser_controller.pane_min = .{ 0.0, 0.0 };
    self.browser_controller.pane_max = .{ 0.0, 0.0 };
    self.browser_controller.pane_input_size = .{ 0.0, 0.0 };
    if (self.browser_controller.surface_suspended_for_layout) return;
    self.browser_controller.runtime.controller.hide() catch |err| {
        log.warn("failed to hide browser runtime while pane is not rendered: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to hide browser runtime while pane is not visible in the layout.") catch {};
        return;
    };
    self.suppressNextBrowserClosedEvent();
    self.browser_controller.surface_suspended_for_layout = true;
    self.unfocusBrowserPane();
}

/// Records the app window origin used to place native child/overlay browser surfaces.
pub fn noteAppWindowFrame(self: anytype, screen_x: i32, screen_y: i32, display_scale: f32) void {
    self.browser_controller.app_window_screen_origin = .{ screen_x, screen_y };
    self.browser_controller.app_window_display_scale = @max(display_scale, 0.001);
    self.syncBrowserPaneBoundsToBackend();
}

/// Returns the device scale used by WPE when it renders logical browser pixels into a high-density frame.
pub fn browserPaneDeviceScale(self: anytype) f32 {
    const presentation = self.browser_controller.runtime.controller.presentationKind();
    const runtime = self.browser_controller.runtime.controller.runtimeKind();
    if (runtime == .native_webview and presentation == .offscreen_texture) {
        return theme.clampf(self.browser_controller.app_window_display_scale, 1.0, 5.0);
    }
    return 1.0;
}

/// Returns the browser input coordinate space for the current visible pane rectangle.
pub fn browserPaneInputSize(self: anytype, pane_width: f32, pane_height: f32) [2]f32 {
    const scale = self.browserPaneDeviceScale();
    return .{
        @max(@round(pane_width / scale), 1.0),
        @max(@round(pane_height / scale), 1.0),
    };
}

pub fn syncBrowserPaneBoundsToBackend(self: anytype) void {
    if (!self.isBrowserVisible()) return;
    if (self.browser_controller.surface_suspended_for_layout) return;
    if (self.browser_controller.surface_suspended_for_empty_state) return;
    if (self.browser_controller.pane_max[0] <= self.browser_controller.pane_min[0] or self.browser_controller.pane_max[1] <= self.browser_controller.pane_min[1]) return;
    if (self.syncBrowserSurfaceOcclusion()) return;
    const pane_width = self.browser_controller.pane_max[0] - self.browser_controller.pane_min[0];
    const pane_height = self.browser_controller.pane_max[1] - self.browser_controller.pane_min[1];
    const presentation = self.browser_controller.runtime.controller.presentationKind();
    const runtime = self.browser_controller.runtime.controller.runtimeKind();
    const uses_native_surface = switch (presentation) {
        .native_child_view, .native_wayland_surface, .helper_window => true,
        .snapshot_texture, .offscreen_texture, .stub => false,
    };
    const uses_scaled_wpe_texture = runtime == .native_webview and presentation == .offscreen_texture;
    const scale = if (uses_native_surface) @max(self.browser_controller.app_window_display_scale, 0.001) else 1.0;
    const size_scale = if (uses_scaled_wpe_texture) self.browserPaneDeviceScale() else scale;
    const pane_x: i32 = @intFromFloat(@round(self.browser_controller.pane_min[0] / scale));
    const pane_y: i32 = @intFromFloat(@round(self.browser_controller.pane_min[1] / scale));
    const x = if (presentation == .native_wayland_surface)
        pane_x
    else
        self.browser_controller.app_window_screen_origin[0] + pane_x;
    const y = if (presentation == .native_wayland_surface)
        pane_y
    else
        self.browser_controller.app_window_screen_origin[1] + pane_y;
    const width: u32 = @intFromFloat(@max(@round(pane_width / size_scale), 1.0));
    const height: u32 = @intFromFloat(@max(@round(pane_height / size_scale), 1.0));
    self.browser_controller.runtime.controller.setPaneBounds(.{
        .screen_x = x,
        .screen_y = y,
        .width = width,
        .height = height,
        .scale = if (uses_scaled_wpe_texture) self.browserPaneDeviceScale() else 1.0,
    }) catch |err| {
        log.warn("failed to sync browser pane bounds: {s}", .{@errorName(err)});
    };
}

pub fn restoreBrowserSurfaceForRenderedLayout(self: anytype) void {
    if (!self.browser_controller.surface_suspended_for_layout) return;
    self.browser_controller.surface_suspended_for_layout = false;
    if (self.browserBlockedByPaletteOverlay()) return;
    if (self.browser_controller.surface_suspended_for_empty_state) return;
    self.browser_controller.runtime.status = .opening;
    self.browser_controller.runtime.controller.show() catch |err| {
        log.warn("failed to restore browser runtime after pane returned to layout: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to restore browser runtime after pane returned to the layout.") catch {};
        return;
    };
    if (!self.browser_controller.pane_focused) {
        self.browser_controller.runtime.controller.blur() catch |err| {
            log.warn("failed to clear restored native browser focus: {s}", .{@errorName(err)});
        };
    }
}

pub fn syncBrowserSurfaceOcclusion(self: anytype) bool {
    const blocked = self.browserBlockedByPaletteOverlay();
    switch (paletteSurfaceTransition(blocked, self.browser_controller.surface_suspended_for_palette_overlay)) {
        .hide => {
            self.browser_controller.runtime.controller.hide() catch |err| {
                log.warn("failed to hide browser runtime for palette overlay: {s}", .{@errorName(err)});
                self.browser_controller.runtime.status = .failed;
                self.browser_controller.runtime.setLastError("Failed to hide browser runtime for Palette overlay.") catch {};
                return true;
            };
            self.suppressNextBrowserClosedEvent();
            self.browser_controller.surface_suspended_for_palette_overlay = true;
            self.unfocusBrowserPane();
        },
        .restore => {
            self.browser_controller.surface_suspended_for_palette_overlay = false;
            if (self.browser_controller.surface_suspended_for_empty_state) return false;
            self.browser_controller.runtime.status = .opening;
            self.browser_controller.runtime.controller.show() catch |err| {
                log.warn("failed to restore browser runtime after palette overlay: {s}", .{@errorName(err)});
                self.browser_controller.runtime.status = .failed;
                self.browser_controller.runtime.setLastError("Failed to restore browser runtime after Palette overlay.") catch {};
                return false;
            };
            if (!self.browser_controller.pane_focused) {
                self.browser_controller.runtime.controller.blur() catch |err| {
                    log.warn("failed to clear restored native browser focus: {s}", .{@errorName(err)});
                };
            }
        },
        .none => {},
    }
    return blocked;
}

fn paletteSurfaceTransition(blocked: bool, suspended: bool) PaletteSurfaceTransition {
    if (blocked) return if (suspended) .none else .hide;
    return if (suspended) .restore else .none;
}

pub fn browserBlockedByPaletteOverlay(self: anytype) bool {
    const quick_blocks_browser = if (self.currentProjectQuickPane()) |quick| blk: {
        const kind = self.workspacePaneKindById(quick.pane_id);
        break :blk quick.visible and (kind == null or kind.? != .browser);
    } else false;
    return quick_blocks_browser or
        companionSidecarBlocksBrowser(
            self.isCompanionEnabled(),
            self.companion_controller.visibility == .sidecar_open,
        ) or
        self.project_controller.show_creator or
        self.settings_controller.modal_visible or
        self.handoff_controller.modal_open or
        self.rename_project_index != null or
        self.thread_import_provider != null or
        self.modal_image_path != null or
        self.transcript_controller.selection_text != null or
        self.palette_modal_text_focus != .none or
        self.browser_controller.inspector_menu_open or
        self.workspace_header_open_menu_open or
        self.sidebar_context_menu_open or
        self.composer_controller.locked_model_picker_open or
        self.composer_controller.composer.active_menu != null or
        self.composer_controller.model_picker.isOpen() or
        self.composer_controller.run_config_open;
}

fn companionSidecarBlocksBrowser(companion_enabled: bool, sidecar_open: bool) bool {
    return companion_enabled and sidecar_open;
}

test "Companion sidecar drives the existing browser surface hide restore lifecycle" {
    const retained_sidecar_open = true;
    const disabled_blocked = companionSidecarBlocksBrowser(false, retained_sidecar_open);
    try std.testing.expect(!disabled_blocked);
    try std.testing.expectEqual(
        PaletteSurfaceTransition.restore,
        paletteSurfaceTransition(disabled_blocked, true),
    );

    const enabled_blocked = companionSidecarBlocksBrowser(true, retained_sidecar_open);
    try std.testing.expect(enabled_blocked);
    try std.testing.expectEqual(PaletteSurfaceTransition.none, paletteSurfaceTransition(false, false));
    // Opening a sidecar hides one native child surface exactly once.
    try std.testing.expectEqual(PaletteSurfaceTransition.hide, paletteSurfaceTransition(enabled_blocked, false));
    try std.testing.expectEqual(PaletteSurfaceTransition.none, paletteSurfaceTransition(enabled_blocked, true));
    // Collapse restores it; an offscreen texture has no suspended child and
    // therefore requires no surface lifecycle operation.
    try std.testing.expectEqual(PaletteSurfaceTransition.restore, paletteSurfaceTransition(false, true));
    try std.testing.expectEqual(PaletteSurfaceTransition.none, paletteSurfaceTransition(false, false));
    // A true modal keeps the same surface hidden after Companion is disabled.
    const unrelated_palette_overlay_blocked = disabled_blocked or true;
    try std.testing.expectEqual(
        PaletteSurfaceTransition.none,
        paletteSurfaceTransition(unrelated_palette_overlay_blocked, true),
    );
    try std.testing.expect(retained_sidecar_open);
}

pub fn suppressNextBrowserClosedEvent(self: anytype) void {
    self.browser_controller.runtime.suppressNextClosedEvent();
}

pub fn consumeSuppressedBrowserClosedEvent(self: anytype) bool {
    return self.browser_controller.runtime.consumeSuppressedClosedEvent();
}

/// Clears browser-pane keyboard focus when another UI surface takes ownership.
pub fn unfocusBrowserPane(self: anytype) void {
    const was_focused = self.browser_controller.pane_focused;
    const native_focused = self.isNativeBrowserSurfaceFocused();
    self.browser_controller.pane_focused = false;
    if (was_focused or native_focused) {
        self.browser_controller.runtime.controller.blur() catch |err| {
            log.warn("failed to clear native browser focus: {s}", .{@errorName(err)});
        };
    }
}

const BrowserPaneFocusPolicy = enum {
    user,
    restore,
};

fn focusBrowserPaneWithPolicy(
    self: anytype,
    project_index: usize,
    pane_id: WorkspacePaneId,
    policy: BrowserPaneFocusPolicy,
) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const pane = layout.paneById(pane_id) orelse return;
    switch (pane.ref) {
        .browser => {},
        else => return,
    }
    if (self.browser_textures_enabled) {
        const binding_is_exact = self.browser_controller.runtime.controls_visible and
            self.browser_controller.runtime_project_index == project_index and
            self.browser_controller.runtime_pane_id == pane_id;
        if (!binding_is_exact) {
            _ = openBrowserInWorkspaceWithDirtyPolicy(self, project_index, null, pane_id, false) catch |err| {
                log.warn("failed to bind exact focused workspace browser: {s}", .{@errorName(err)});
            };
        }
    }
    self.browser_controller.pane_focused = true;
    self.terminal_controller.focused = false;
    self.composer_controller.focused = false;
    self.composer_controller.composer.focused = false;
    self.browser_controller.address_focused = false;
    layout.focused_pane_id = pane_id;
    self.browser_controller.runtime.controller.focus() catch |err| {
        log.warn("failed to focus native browser surface: {s}", .{@errorName(err)});
    };
    if (policy == .user) self.markDirty();
}

/// Gives keyboard ownership to the exact pane already selected by the caller.
pub fn focusBrowserPaneInWorkspace(self: anytype, project_index: usize, pane_id: WorkspacePaneId) void {
    focusBrowserPaneWithPolicy(self, project_index, pane_id, .user);
}

pub fn focusBrowserPane(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    const project_index = self.project_controller.selected_index;
    const layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const pane_id = preferredBrowserPaneId(layout) orelse return;
    focusBrowserPaneWithPolicy(self, project_index, pane_id, .user);
}

/// Restore keyboard ownership to one persisted browser pane exactly. This is
/// deliberately dirty- and acknowledgement-neutral for launch/workspace restore.
pub fn restoreBrowserPaneFocus(self: anytype, project_index: usize, pane_id: WorkspacePaneId) void {
    focusBrowserPaneWithPolicy(self, project_index, pane_id, .restore);
}

/// Reports whether the browser pane currently owns keyboard input.
pub fn isBrowserPaneFocused(self: anytype) bool {
    return self.isBrowserVisible() and self.browser_controller.pane_focused;
}

/// Reports whether the native child browser view owns OS keyboard input.
pub fn isNativeBrowserSurfaceFocused(self: anytype) bool {
    return self.isBrowserVisible() and self.browser_controller.runtime.controller.hasNativeFocus();
}

/// Reports whether the browser pane is backed by a platform view that receives
/// keyboard input directly from the OS rather than through SDL forwarding.
pub fn browserPaneUsesNativeKeyboardSurface(self: anytype) bool {
    if (!self.isBrowserVisible()) return false;
    return switch (self.browser_controller.runtime.controller.presentationKind()) {
        .native_child_view, .native_wayland_surface, .helper_window => true,
        .snapshot_texture, .offscreen_texture, .stub => false,
    };
}

/// Reports whether the last rendered browser pane contains the given framebuffer-space point.
pub fn browserPaneContains(self: anytype, x: f32, y: f32) bool {
    if (!self.isBrowserVisible()) return false;
    if (self.browser_controller.pane_max[0] <= self.browser_controller.pane_min[0] or self.browser_controller.pane_max[1] <= self.browser_controller.pane_min[1]) {
        return false;
    }
    return x >= self.browser_controller.pane_min[0] and
        y >= self.browser_controller.pane_min[1] and
        x <= self.browser_controller.pane_max[0] and
        y <= self.browser_controller.pane_max[1];
}

/// Returns the browser-requested cursor only for texture-backed content under the pointer.
pub fn browserCursorShapeAtPoint(self: anytype, x: f32, y: f32) ?browser_runtime.CursorShape {
    if (!self.browserPaneContains(x, y)) return null;
    return switch (self.browser_controller.runtime.controller.presentationKind()) {
        .snapshot_texture, .offscreen_texture => self.browser_controller.cursor_shape,
        .native_child_view, .native_wayland_surface, .helper_window, .stub => null,
    };
}

/// Reports when WKWebView or WebView2 should control the shared OS cursor.
pub fn nativeBrowserOwnsCursor(self: anytype) bool {
    if (!self.isBrowserVisible() or
        self.browser_controller.surface_suspended_for_layout or
        self.browser_controller.surface_suspended_for_empty_state or
        self.browser_controller.surface_suspended_for_palette_overlay or
        self.browserBlockedByPaletteOverlay()) return false;
    if (self.browser_controller.runtime.controller.presentationKind() != .native_child_view) return false;
    return self.browser_controller.runtime.controller.nativeSurfaceOwnsCursor();
}

/// Forwards browser-pane pointer input after converting it into pane-local coordinates.
pub fn handleBrowserMouse(self: anytype, event: browser_runtime.MouseEvent) bool {
    if (!self.isBrowserVisible()) return false;

    const contains_pointer = self.browserPaneContains(event.x, event.y);
    const is_pointer_event = event.button != null or event.wheel_x != 0.0 or event.wheel_y != 0.0;
    if (event.button != null and event.pressed and !contains_pointer) {
        self.unfocusBrowserPane();
        return false;
    }
    if (!contains_pointer and !self.browser_controller.pane_focused) return false;
    if (is_pointer_event and !contains_pointer) return false;
    if (event.button) |button| {
        if (event.pressed and (button == .back or button == .forward)) {
            self.navigateBrowserHistory(if (button == .back) -1 else 1);
            return true;
        }
        if (event.pressed and contains_pointer) {
            self.focusBrowserPane();
        }
    }

    var pane_event = event;
    const displayed_width = self.browser_controller.pane_max[0] - self.browser_controller.pane_min[0];
    const displayed_height = self.browser_controller.pane_max[1] - self.browser_controller.pane_min[1];
    const input_width = @max(self.browser_controller.pane_input_size[0], 1.0);
    const input_height = @max(self.browser_controller.pane_input_size[1], 1.0);
    const presentation = self.browser_controller.runtime.controller.presentationKind();
    const runtime = self.browser_controller.runtime.controller.runtimeKind();
    const uses_scaled_wpe_texture = runtime == .native_webview and presentation == .offscreen_texture and self.browserPaneDeviceScale() > 1.0;
    pane_event.x = browserPointerCoordinate(event.x - self.browser_controller.pane_min[0], displayed_width, input_width, uses_scaled_wpe_texture);
    pane_event.y = browserPointerCoordinate(event.y - self.browser_controller.pane_min[1], displayed_height, input_height, uses_scaled_wpe_texture);
    pane_event.wheel_multiplier = browserWheelMultiplier(self.app_config.browser_fast_scrolling_enabled);

    const handled = self.browser_controller.runtime.controller.handleMouse(pane_event) catch |err| {
        log.warn("failed to forward browser mouse input: {s}", .{@errorName(err)});
        return false;
    };
    if (handled and contains_pointer and event.button != null and event.pressed) {
        self.focusBrowserPane();
    }
    if (handled) return true;

    return contains_pointer and is_pointer_event and switch (self.browser_controller.runtime.controller.presentationKind()) {
        .native_child_view, .native_wayland_surface => true,
        .helper_window, .snapshot_texture, .offscreen_texture, .stub => false,
    };
}

fn browserPointerCoordinate(local: f32, displayed_extent: f32, input_extent: f32, uses_scaled_wpe_texture: bool) f32 {
    // WPE consumes physical pointer coordinates and applies its configured
    // device scale internally. Other backends expect their declared input size.
    if (uses_scaled_wpe_texture) return local;
    return local * (@max(input_extent, 1.0) / @max(displayed_extent, 1.0));
}

fn browserAutomationPointerCoordinate(logical: f32, device_scale: f32) f32 {
    // Live/MCP coordinates use browser logical pixels, while scaled WPE consumes
    // physical pointer coordinates before applying its configured device scale.
    return logical * device_scale;
}

fn browserWheelMultiplier(fast_scrolling_enabled: bool) f32 {
    return if (fast_scrolling_enabled) 1.5 else 1.0;
}

/// Forwards browser-pane keyboard and text input when the pane owns focus.
pub fn handleBrowserKey(self: anytype, event: browser_runtime.KeyEvent) bool {
    if (!self.isBrowserPaneFocused()) return false;
    return self.browser_controller.runtime.controller.handleKey(event) catch |err| {
        log.warn("failed to forward browser keyboard input: {s}", .{@errorName(err)});
        return false;
    };
}

pub fn clearBrowserContextMenuLocal(self: anytype) void {
    for (self.browser_controller.context_menu_items.items) |item| {
        self.allocator.free(item.label);
    }
    self.browser_controller.context_menu_items.clearRetainingCapacity();
    if (self.browser_controller.context_menu_link_url) |url| self.allocator.free(url);
    self.browser_controller.context_menu_link_url = null;
    self.browser_controller.context_menu_open = false;
    self.browser_controller.context_menu_anchor_x = 0.0;
    self.browser_controller.context_menu_anchor_y = 0.0;
    self.browser_controller.context_menu_selected_index = null;
    self.browser_controller.context_menu_active_parent = null;
}

pub fn dismissBrowserContextMenu(self: anytype) void {
    const was_open = self.browser_controller.context_menu_open;
    self.clearBrowserContextMenuLocal();
    if (was_open) {
        self.browser_controller.runtime.controller.dismissContextMenu() catch |err| {
            log.warn("failed to dismiss browser context menu: {s}", .{@errorName(err)});
        };
    }
}

pub fn activateBrowserContextMenuItem(self: anytype, index: u32) void {
    if (!self.browser_controller.context_menu_open) return;
    var enabled = false;
    for (self.browser_controller.context_menu_items.items) |item| {
        if (item.index == index) {
            enabled = item.enabled and !item.separator and !item.submenu;
            break;
        }
    }
    if (!enabled) return;
    self.clearBrowserContextMenuLocal();
    self.browser_controller.runtime.controller.activateContextMenuItem(index) catch |err| {
        log.warn("failed to activate browser context menu item: {s}", .{@errorName(err)});
    };
}

pub fn appendBrowserContextMenuPayloadItems(
    self: anytype,
    items: []const BrowserContextMenuPayloadItem,
    parent_index: ?u32,
) void {
    for (items) |item| {
        const label = self.allocator.dupe(u8, item.label) catch |err| {
            log.warn("failed to retain browser context menu label: {s}", .{@errorName(err)});
            continue;
        };
        self.browser_controller.context_menu_items.append(self.allocator, .{
            .index = item.index,
            .label = label,
            .enabled = item.enabled,
            .separator = item.separator,
            .submenu = item.submenu,
            .parent_index = parent_index,
        }) catch |err| {
            self.allocator.free(label);
            log.warn("failed to append browser context menu item: {s}", .{@errorName(err)});
            continue;
        };
        if (item.items.len > 0) {
            self.appendBrowserContextMenuPayloadItems(item.items, item.index);
        }
    }
}

pub fn openBrowserContextMenuFromPayload(self: anytype, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(BrowserContextMenuPayload, self.allocator, payload, .{ .allocate = .alloc_always }) catch |err| {
        log.warn("failed to parse browser context menu payload: {s}", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();

    self.clearBrowserContextMenuLocal();
    const displayed_width = self.browser_controller.pane_max[0] - self.browser_controller.pane_min[0];
    const displayed_height = self.browser_controller.pane_max[1] - self.browser_controller.pane_min[1];
    const input_width = @max(self.browser_controller.pane_input_size[0], 1.0);
    const input_height = @max(self.browser_controller.pane_input_size[1], 1.0);
    self.browser_controller.context_menu_anchor_x = self.browser_controller.pane_min[0] + parsed.value.x * (@max(displayed_width, 1.0) / input_width);
    self.browser_controller.context_menu_anchor_y = self.browser_controller.pane_min[1] + parsed.value.y * (@max(displayed_height, 1.0) / input_height);
    if (parsed.value.link_url) |url| {
        self.browser_controller.context_menu_link_url = self.allocator.dupe(u8, url) catch |err| failed: {
            log.warn("failed to retain browser context-menu link URL: {s}", .{@errorName(err)});
            break :failed null;
        };
    }

    self.appendBrowserContextMenuPayloadItems(parsed.value.items, null);
    self.browser_controller.context_menu_open = self.browser_controller.context_menu_items.items.len > 0 or self.browser_controller.context_menu_link_url != null;
    self.browser_controller.address_focused = false;
    self.browser_controller.inspector_menu_open = false;
}

pub fn browserContextMenuHasLink(self: anytype) bool {
    return self.browser_controller.context_menu_open and self.browser_controller.context_menu_link_url != null;
}

pub fn openBrowserContextLink(self: anytype, new_tab: bool) void {
    const url = self.browser_controller.context_menu_link_url orelse return;
    const owned = self.allocator.dupe(u8, url) catch return;
    defer self.allocator.free(owned);
    self.dismissBrowserContextMenu();
    if (new_tab) self.createBrowserTab();
    self.navigateBrowserToUrl(owned) catch |err| {
        log.warn("failed to open browser context-menu link: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to open link.");
    };
}

/// Re-shows the native browser window without changing dock visibility.
pub fn reopenBrowserWindow(self: anytype) void {
    if (!self.browser_controller.runtime.controller.supportsPopout()) {
        self.setSidebarNotice("Browser pop out is not implemented yet.");
        return;
    }
    self.browser_controller.runtime.status = .opening;
    self.browser_controller.runtime.controller.show() catch |err| {
        log.err("failed to re-show browser runtime: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to reopen browser window.") catch {};
        self.setSidebarNotice("Failed to reopen browser window.");
        return;
    };
    self.setSidebarNotice("Browser window reopened.");
}

/// Navigates the browser runtime using the current browser address input buffer.
pub fn navigateBrowserFromAddress(self: anytype) void {
    self.navigateBrowserToUrl(self.browser_controller.runtime.addressInput()) catch |err| switch (err) {
        error.EmptyBrowserUrl => {
            self.setSidebarNotice("Enter a browser URL first.");
            return;
        },
        error.BrowserNavigationFailed => return,
        else => {
            self.setSidebarNotice("Failed to normalize browser URL.");
            return;
        },
    };
}

/// Captures the current CPU-side browser frame and stores the PNG beside
/// other browser captures so live-control and MCP callers can reuse it.
pub fn captureBrowserScreenshot(self: anytype) !BrowserScreenshotResult {
    if (!self.isBrowserRuntimeActive()) return error.BrowserNotVisible;
    const frame = (try self.browser_controller.runtime.controller.copyFramePixels(self.allocator)) orelse
        return error.BrowserScreenshotUnavailable;
    defer frame.deinit(self.allocator);

    const crop: browser_screenshot.CropRect = .{
        .x = 0,
        .y = 0,
        .width = frame.width,
        .height = frame.height,
    };
    const png_bytes = try browser_screenshot.encodeFrameCropPng(self.allocator, frame, crop);
    errdefer self.allocator.free(png_bytes);
    const path = try self.writeImageBytesToStorage("browser-captures", "browser", "png", png_bytes);
    errdefer self.allocator.free(path);
    return .{
        .path = path,
        .png_bytes = png_bytes,
        .width = frame.width,
        .height = frame.height,
    };
}

/// Reuses the workspace process manager for the browser empty-state CTA.
/// Existing process configuration wins; otherwise the workspace opens in
/// the configured editor so the user can add a `verde.yml` process.
pub fn setupBrowserDevServer(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) {
        self.setSidebarNotice("Import a workspace before setting up a dev server.");
        return;
    }
    const project_index = self.project_controller.selected_index;
    self.refreshProjectStackConfig(project_index) catch |err| {
        log.warn("failed to load dev-server process config: {s}", .{@errorName(err)});
        self.setSidebarNotice("Fix the workspace verde.yml before starting its dev server.");
        return;
    };

    var process_index: ?usize = null;
    for (self.project_controller.projects.items[project_index].managed_processes.items, 0..) |process, index| {
        if (process.kind == .process) {
            process_index = index;
            break;
        }
    }
    if (process_index) |index| {
        const name = self.project_controller.projects.items[project_index].managed_processes.items[index].name;
        const started = self.startManagedProcess(project_index, name) catch |err| {
            log.warn("failed to start dev-server process {s}: {s}", .{ name, @errorName(err) });
            self.setSidebarNotice("Failed to start the configured dev server.");
            return;
        };
        const now = unixTimestampMs();
        self.browser_controller.beginDevServerProbe(project_index, index, now);
        self.setSidebarNotice(if (started) "Started the dev server; waiting for its local URL." else "Waiting for the dev server's local URL.");
        return;
    }

    self.openCurrentProjectEditor(.configured);
    self.setSidebarNotice("Add a dev-server process to verde.yml, then use this action again.");
}

/// Navigates typed addresses or reloads when the URL bar already matches the current page.
pub fn navigateOrReloadBrowserFromAddress(self: anytype) void {
    const trimmed = std.mem.trim(u8, self.browser_controller.runtime.addressInput(), &std.ascii.whitespace);
    if (trimmed.len == 0) {
        self.reloadBrowser();
        return;
    }
    const normalized = self.normalizeBrowserUrl(trimmed) catch {
        self.setSidebarNotice("Failed to normalize browser URL.");
        return;
    };
    defer self.allocator.free(normalized);

    if (self.browser_controller.runtime.current_url) |current_url| {
        if (std.mem.eql(u8, current_url, normalized)) {
            self.reloadBrowser();
            return;
        }
    }

    self.restartBrowserRuntimeForCrossOriginNavigation(normalized);
    self.browser_controller.runtime.status = .opening;
    self.browser_controller.runtime.controller.navigate(normalized) catch |err| {
        log.err("failed to navigate browser runtime: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to navigate browser runtime.") catch {};
        self.setSidebarNotice("Browser navigation failed.");
        return;
    };
    self.browser_controller.runtime.setAddress(normalized);
    self.setSidebarNotice("Browser navigation requested.");
}

/// Evaluates the current browser JavaScript input inside the browser runtime.
pub fn evalBrowserScript(self: anytype) void {
    const trimmed = std.mem.trim(u8, self.browser_controller.runtime.scriptInput(), &std.ascii.whitespace);
    if (trimmed.len == 0) {
        self.setSidebarNotice("Enter JavaScript first.");
        return;
    }

    self.browser_controller.runtime.controller.eval(trimmed) catch |err| {
        log.err("failed to evaluate browser script: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to evaluate browser script.") catch {};
        self.setSidebarNotice("Browser script evaluation failed.");
        return;
    };
    self.setSidebarNotice("Browser script evaluation requested.");
}

/// Posts the current JSON bridge input into the browser runtime.
pub fn postBrowserJsonFromInput(self: anytype) void {
    const trimmed = std.mem.trim(u8, self.browser_controller.runtime.jsonInput(), &std.ascii.whitespace);
    if (trimmed.len == 0) {
        self.setSidebarNotice("Enter JSON first.");
        return;
    }

    self.browser_controller.runtime.controller.postJson(trimmed) catch |err| {
        log.err("failed to post browser JSON: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to post browser JSON.") catch {};
        self.setSidebarNotice("Browser JSON bridge failed.");
        return;
    };
    self.setSidebarNotice("Browser JSON bridge requested.");
}

/// Toggles the bundled page inspector overlay inside the browser runtime.
pub fn toggleBrowserInspector(self: anytype) void {
    if (self.browser_controller.runtime.inspectorEnabled()) {
        self.disableBrowserInspector(true);
        return;
    }
    self.enableBrowserInspector(true);
}

/// Updates the browser inspector mode and reapplies the live inspector when needed.
pub fn setBrowserInspectorMode(self: anytype, mode: browser_runtime.InspectorMode) void {
    if (self.browser_controller.runtime.inspectorMode() == mode) return;

    self.browser_controller.runtime.setInspectorMode(mode);
    if (!self.browser_controller.runtime.inspectorEnabled()) {
        self.setSidebarNotice(inspectorModeStoredNotice(mode));
        return;
    }

    self.applyBrowserInspector(true, inspectorModeSwitchedNotice(mode));
}

/// Applies queued browser runtime events back onto app-visible browser state.
pub fn pollBrowser(self: anytype) bool {
    if (!self.browser_textures_enabled) return false;

    var needs_render = self.pollPendingBrowserDevServer();
    if (self.browser_controller.launch_open_delay_frames == 0 and !self.browser_controller.runtime.controller.hasBackend()) return needs_render;

    if (self.browser_controller.launch_open_delay_frames > 0) {
        self.browser_controller.launch_open_delay_frames -= 1;
        if (self.browser_controller.launch_open_delay_frames == 0) {
            if (self.project_controller.projects.items.len > 0 and
                self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.visibleBrowserPaneId() != null)
            {
                // Launch restoration may already have bound the persisted
                // pane while applying its keyboard focus. Re-enter the exact
                // restore path: the ordinary toggle would interpret that
                // successful binding as a request to close the pane.
                self.restorePersistedBrowserPaneAfterProjectSelection(self.project_controller.selected_index);
            } else {
                self.toggleBrowser();
            }
            needs_render = true;
        }
    }
    needs_render = self.browser_controller.runtime.controller.uploadFrame() or needs_render;
    while (self.browser_controller.runtime.controller.pollEvent()) |event| {
        defer event.deinit(self.allocator);
        needs_render = true;
        switch (event) {
            .opened => {
                self.browser_controller.runtime.status = .ready;
                self.browser_controller.runtime.setLastError(null) catch {};
            },
            .closed => {
                self.browser_controller.pane_focused = false;
                self.clearBrowserContextMenuLocal();
                if (self.consumeSuppressedBrowserClosedEvent()) {
                    continue;
                }
                self.browser_controller.runtime.status = .hidden;
                self.setSidebarNotice("Browser window closed.");
            },
            .navigated => |url| {
                // WPE emits an empty URI while a fresh WebView is being
                // initialized. It is not a navigation and must not erase
                // the workspace tab snapshot used by live/MCP commands.
                if (!browserNavigationUrlIsPersistable(url)) continue;
                self.clearBrowserContextMenuLocal();
                self.browser_controller.runtime.status = .ready;
                self.setActiveBrowserTabLoadState(true, false);
                self.browser_controller.runtime.setCurrentUrl(url) catch {};
                self.browser_controller.runtime.setAddress(url);
                self.recordVisibleBrowserPaneNavigation(url);
                self.browser_controller.runtime.setLastError(null) catch {};
            },
            .title_changed => |title| {
                self.browser_controller.runtime.setCurrentTitle(title) catch {};
                self.recordVisibleBrowserPaneTitle(title);
            },
            .document_loaded => {
                self.setActiveBrowserTabLoadState(false, false);
                self.reapplyBrowserInspectorAfterLoad();
                self.runBrowserStartupEvalIfRequested();
            },
            .cursor_changed => |shape| {
                self.browser_controller.cursor_shape = shape;
            },
            .js_message => |message| {
                const inspector_message = isInspectorBridgeMessage(message);
                const inspector_message_allowed = inspector_message and
                    self.browser_controller.runtime.inspectorEnabled() and
                    self.browserInspectorPolicyAllowsCurrentPage();
                if (!inspector_message_allowed and !self.browserBridgePolicyAllowsCurrentPage()) {
                    const page_url = if (self.browser_controller.runtime.current_url) |url| url else self.browser_controller.runtime.addressInput();
                    log.warn("blocked browser bridge message from disallowed page url_len={d}", .{page_url.len});
                    self.browser_controller.runtime.setLastError("Browser bridge message rejected by origin policy.") catch {};
                    self.setSidebarNotice("Browser bridge message blocked for this page.");
                    continue;
                }
                if (isBrowserClipboardMessage(message)) {
                    self.handleBrowserClipboardMessage(message);
                    continue;
                }
                if (inspector_message) {
                    if (isInspectorDisabledMessage(message)) {
                        self.browser_controller.runtime.setInspectorEnabled(false);
                        self.browser_controller.inspector_menu_open = false;
                        continue;
                    }
                    if (isInspectorHoverMessage(message) or
                        isInspectorLifecycleMessage(message) or
                        isInspectorPromptChangedMessage(message))
                    {
                        continue;
                    }
                    self.browser_controller.runtime.setLastJsMessage(message) catch {};
                    if (isInspectorSelectionMessage(message)) {
                        self.setSidebarNotice("Browser inspector captured a selection.");
                        // The bubble just opened; refresh its "Send to"
                        // targets so they track the current pane layout.
                        self.pushInspectorPromptTargets();
                    } else if (isInspectorPromptSubmittedMessage(message)) {
                        self.handleInspectorPromptSubmitted(message);
                    }
                    continue;
                }
                self.browser_controller.runtime.setLastJsMessage(message) catch {};
                self.setSidebarNotice("Browser bridge message received.");
            },
            .eval_result => |result| {
                self.browser_controller.runtime.setLastEvalResult(result) catch {};
                if (self.browser_controller.clipboard_copy_pending) {
                    self.browser_controller.clipboard_copy_pending = false;
                    self.copyBrowserEvalResultToClipboard(result);
                    continue;
                }
                if (self.browser_controller.runtime.consumeSuppressedEvalResult()) {
                    continue;
                }
                self.setSidebarNotice("Browser script evaluation completed.");
            },
            .context_menu => |payload| {
                self.openBrowserContextMenuFromPayload(payload);
            },
            .context_menu_dismissed => {
                self.clearBrowserContextMenuLocal();
            },
            .failed => |message| {
                self.browser_controller.runtime.status = .failed;
                self.setActiveBrowserTabLoadState(false, true);
                self.browser_controller.runtime.setLastError(message) catch {};
                self.setSidebarNotice("Browser runtime reported a failure.");
            },
        }
    }
    if (self.isNativeBrowserSurfaceFocused() and self.browser_controller.address_focused) {
        self.browser_controller.address_focused = false;
        needs_render = true;
    }
    return needs_render;
}

/// Records browser presentation after the main renderer successfully submits a frame.
pub fn noteBrowserFramePresented(self: anytype) void {
    if (!self.browser_textures_enabled or !self.isBrowserVisible()) return;
    self.browser_controller.runtime.controller.noteFramePresented();
}

pub fn pollPendingBrowserDevServer(self: anytype) bool {
    const project_index = self.browser_controller.dev_server_project_index orelse return false;
    const process_index = self.browser_controller.dev_server_process_index orelse return false;
    const now = unixTimestampMs();
    if (now < self.browser_controller.dev_server_next_check_ms) return false;
    self.browser_controller.dev_server_next_check_ms = now + 250;
    if (now >= self.browser_controller.dev_server_deadline_ms) {
        self.clearPendingBrowserDevServer();
        self.setSidebarNotice("Dev server started, but no local URL was detected. Enter it above.");
        return true;
    }
    if (project_index >= self.project_controller.projects.items.len or process_index >= self.project_controller.projects.items[project_index].managed_processes.items.len) {
        self.clearPendingBrowserDevServer();
        return false;
    }
    const process = &self.project_controller.projects.items[project_index].managed_processes.items[process_index];
    const dock_id = process.dock_id orelse return false;
    const dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
    const output = (dock.activeOutputTailAlloc(self.allocator, 32 * 1024) catch return false) orelse return false;
    defer self.allocator.free(output);
    const url = localDevServerUrl(output) orelse return false;
    self.navigateBrowserToUrl(url) catch |err| {
        log.warn("failed to open detected dev-server url: {s}", .{@errorName(err)});
        return false;
    };
    self.clearPendingBrowserDevServer();
    self.setSidebarNotice("Opened the detected dev server URL.");
    return true;
}

pub fn clearPendingBrowserDevServer(self: anytype) void {
    self.browser_controller.clearDevServerProbe();
}

pub fn localDevServerUrl(output: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (search_from < output.len) {
        const http = std.mem.indexOfPos(u8, output, search_from, "http://");
        const https = std.mem.indexOfPos(u8, output, search_from, "https://");
        const start = if (http) |http_start|
            if (https) |https_start| @min(http_start, https_start) else http_start
        else
            https orelse return null;
        const scheme_len: usize = if (std.mem.startsWith(u8, output[start..], "https://")) 8 else 7;
        var end = start + scheme_len;
        while (end < output.len and !std.ascii.isWhitespace(output[end]) and
            std.mem.indexOfScalar(u8, "\"'<>`()", output[end]) == null) : (end += 1)
        {}
        while (end > start and (output[end - 1] == '.' or output[end - 1] == ',' or output[end - 1] == ';')) end -= 1;
        const candidate = output[start..end];
        const authority = candidate[scheme_len..];
        const authority_end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
        const host_port = authority[0..authority_end];
        if (isLoopbackAuthority(host_port)) {
            return candidate;
        }
        search_from = @max(end, start + scheme_len);
    }
    return null;
}

pub fn isLoopbackAuthority(authority: []const u8) bool {
    if (std.mem.startsWith(u8, authority, "[::1]")) {
        const remainder = authority["[::1]".len..];
        return remainder.len == 0 or remainder[0] == ':';
    }
    const host_end = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    const host = authority[0..host_end];
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "0.0.0.0");
}

// Adds an https scheme for bare hostnames so the browser control surface accepts normal typed URLs.
pub fn normalizeBrowserUrl(self: anytype, value: []const u8) ![]u8 {
    if (hasUriScheme(value)) {
        return try self.allocator.dupe(u8, value);
    }
    return try std.fmt.allocPrint(self.allocator, "https://{s}", .{value});
}

pub fn hasUriScheme(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "://") != null or
        std.mem.startsWith(u8, value, "about:") or
        std.mem.startsWith(u8, value, "data:") or
        std.mem.startsWith(u8, value, "file:") or
        std.mem.startsWith(u8, value, "blob:") or
        std.mem.startsWith(u8, value, "javascript:") or
        std.mem.startsWith(u8, value, "mailto:");
}

pub fn isBlankBrowserUrl(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    return std.mem.eql(u8, trimmed, "about:blank");
}

pub fn runBrowserStartupEvalIfRequested(self: anytype) void {
    if (!self.browser_controller.start_eval_pending) return;
    self.browser_controller.start_eval_pending = false;
    const raw_script = std.c.getenv("VERDE_BROWSER_START_EVAL") orelse return;
    const script = std.mem.sliceTo(raw_script, 0);
    if (script.len == 0) return;
    self.browser_controller.runtime.controller.eval(script) catch |err| {
        log.warn("failed to run browser startup eval: {s}", .{@errorName(err)});
        self.browser_controller.runtime.setLastError("Failed to run browser startup eval.") catch {};
        self.setSidebarNotice("Browser startup eval failed.");
    };
}

pub fn inspectorModeStoredNotice(mode: browser_runtime.InspectorMode) []const u8 {
    return switch (mode) {
        .point => "Browser inspector mode set to Point.",
        .draw_box => "Browser inspector mode set to Draw Box.",
        .draw_freeform => "Browser inspector mode set to Draw Freeform.",
    };
}

pub fn inspectorModeSwitchedNotice(mode: browser_runtime.InspectorMode) []const u8 {
    return switch (mode) {
        .point => "Browser inspector switched to Point mode.",
        .draw_box => "Browser inspector switched to Draw Box mode.",
        .draw_freeform => "Browser inspector switched to Draw Freeform mode.",
    };
}

pub fn isBrowserClipboardMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"source\":\"verde-browser-clipboard\"") != null;
}

pub fn handleBrowserClipboardMessage(self: anytype, message: []const u8) void {
    var parsed = std.json.parseFromSlice(BrowserClipboardEvent, self.allocator, message, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("failed to parse browser clipboard message: {s}", .{@errorName(err)});
        self.setSidebarNotice("Browser clipboard message could not be parsed.");
        return;
    };
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.source, "verde-browser-clipboard")) {
        return;
    }
    self.copyBrowserEvalResultToClipboard(parsed.value.text);
}

// Design-mode prompts submit straight to the active chat; the crop padding
// keeps a little page context around the selected element in the capture.
const INSPECTOR_CROP_PADDING_CSS: f32 = 12.0;

const InspectorPromptResult = enum {
    sent,
    drafted,
    failed,

    fn jsValue(self: InspectorPromptResult) []const u8 {
        return switch (self) {
            .sent => "sent",
            .drafted => "drafted",
            .failed => "failed",
        };
    }
};

const InspectorCapture = struct {
    path: []u8,
    byte_len: usize,
};

pub fn handleInspectorPromptSubmitted(self: anytype, message: []const u8) void {
    if (self.project_controller.projects.items.len == 0) {
        self.setSidebarNotice("No active chat is available for the browser inspector prompt.");
        self.notifyInspectorPromptResult(.failed, "No active chat is available.");
        return;
    }

    var parsed = std.json.parseFromSlice(InspectorPromptSubmittedEvent, self.allocator, message, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("failed to parse inspector prompt submission: {s}", .{@errorName(err)});
        self.setSidebarNotice("Browser inspector prompt could not be parsed.");
        self.notifyInspectorPromptResult(.failed, "Verde could not parse this prompt.");
        return;
    };
    defer parsed.deinit();

    const prompt = std.mem.trim(u8, parsed.value.payload.prompt, &std.ascii.whitespace);
    if (prompt.len == 0) {
        self.setSidebarNotice("Browser inspector prompt was empty.");
        self.notifyInspectorPromptResult(.failed, "The prompt was empty.");
        return;
    }

    const context_block = self.buildInspectorContextBlock(parsed.value.payload.selection) catch |err| {
        log.warn("failed to build inspector context block: {s}", .{@errorName(err)});
        self.setSidebarNotice("Browser inspector prompt could not be prepared.");
        self.notifyInspectorPromptResult(.failed, "Verde could not prepare this prompt.");
        return;
    };
    defer self.allocator.free(context_block);

    // Best-effort screenshot crop; text-only context still sends when the
    // backend has no CPU frame (or the selection is offscreen).
    const capture = self.captureInspectorSelectionImage(
        parsed.value.payload.selection,
        parsed.value.payload.viewport,
    );
    defer if (capture) |c| self.allocator.free(c.path);

    // Route to the destination the user picked in the bubble's "Send to"
    // selector: a TUI pane gets the prompt pasted into its input, a chat
    // pane retargets the thread for the send below.
    if (parsed.value.payload.target) |target| {
        if (std.mem.startsWith(u8, target, "tui:")) {
            runtime_log.diagnostic("inspector prompt path=tui pane_token_len={d} prompt_len={d}", .{ target.len - "tui:".len, prompt.len });
            self.fillInspectorPromptIntoTui(target["tui:".len..], context_block, prompt, capture);
            return;
        }
        self.applyInspectorPromptTarget(target);
    }

    const thread = self.currentThreadMutable();
    const draft_text = std.mem.trim(u8, self.currentDraft(), &std.ascii.whitespace);
    const send_busy = thread.isSendPending();
    const composer_dirty = draft_text.len != 0 or thread.draftImageCount() != 0;
    runtime_log.diagnostic("inspector prompt submitted prompt_len={d} target={} busy={} dirty={} capture={}", .{
        prompt.len,
        parsed.value.payload.target != null,
        send_busy,
        composer_dirty,
        capture != null,
    });

    // Mid-send with a clean composer: queue as a follow-up so the prompt
    // dispatches right after the current reply, matching what queuing a
    // message from the composer would do.
    if (send_busy and !composer_dirty and !threadHasPendingFollowup(thread)) {
        self.queueInspectorPromptAsFollowup(thread, context_block, prompt, capture);
        return;
    }
    // A dirty composer (or an already-queued follow-up) means auto-sending
    // would clobber or bundle the user's in-progress input; park the
    // prompt in the draft instead.
    if (send_busy or composer_dirty) {
        self.fallbackInspectorPromptToDraft(thread, context_block, prompt, capture, send_busy);
        return;
    }

    const send_body = std.fmt.allocPrint(
        self.allocator,
        "{s}\n\n{s}",
        .{ prompt, context_block },
    ) catch |err| {
        log.warn("failed to compose inspector send body: {s}", .{@errorName(err)});
        self.setSidebarNotice("Browser inspector prompt could not be prepared.");
        self.notifyInspectorPromptResult(.failed, "Verde could not prepare this prompt.");
        return;
    };
    defer self.allocator.free(send_body);

    self.setDraft(send_body);
    if (capture) |c| {
        thread.addDraftImage(self.allocator, c.path, "image/png", c.byte_len) catch |err| {
            log.warn("failed to attach inspector capture: {s}", .{@errorName(err)});
        };
    }
    self.sendDraft() catch |err| {
        log.warn("failed to send inspector prompt: {s}", .{@errorName(err)});
        self.setSidebarNotice("Browser inspector prompt could not be sent.");
        self.notifyInspectorPromptResult(.failed, "Verde could not start the send.");
        return;
    };

    if (self.currentThread().isSendPending()) {
        runtime_log.diagnostic("inspector prompt path=auto_send started", .{});
        self.setSidebarNotice("Browser inspector prompt sent to the current chat.");
        self.notifyInspectorPromptResult(.sent, null);
    } else {
        // sendDraft bailed without starting (e.g. no provider target); the
        // composed body is still sitting in the composer draft.
        runtime_log.diagnostic("inspector prompt path=auto_send did_not_start", .{});
        self.syncPaletteComposerFromDraft();
        self.requestComposerFocus();
        self.setSidebarNotice("Browser inspector prompt was added to the composer draft.");
        self.notifyInspectorPromptResult(.drafted, null);
    }
}

// Reports whether a follow-up is already queued on the thread's in-flight
// send; queuing another would silently clobber it.
pub fn threadHasPendingFollowup(thread: *ChatThread) bool {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    return send_state.pending_followup != null;
}

// Queues the design-mode prompt as a follow-up on the in-flight send
// (steer for Codex, queue otherwise). Follow-ups are text-only, so the
// screenshot rides along as a readable file path instead of an
// attachment. Falls back to the draft-park path if queuing fails.
pub fn queueInspectorPromptAsFollowup(
    self: anytype,
    thread: *ChatThread,
    context_block: []const u8,
    prompt: []const u8,
    capture: ?InspectorCapture,
) void {
    const followup_text = if (capture) |c|
        std.fmt.allocPrint(self.allocator, "{s}\n\n{s}Screenshot: {s}", .{ prompt, context_block, c.path })
    else
        std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ prompt, context_block });
    const resolved_text = followup_text catch |err| {
        log.warn("failed to compose inspector follow-up: {s}", .{@errorName(err)});
        self.fallbackInspectorPromptToDraft(thread, context_block, prompt, capture, true);
        return;
    };
    defer self.allocator.free(resolved_text);

    self.setDraft(resolved_text);
    self.queueOrSteerDraftDuringSend();
    // queueOrSteerDraftDuringSend consumes and clears the draft on
    // success; a non-empty draft means it could not queue.
    if (self.currentDraft().len == 0) {
        runtime_log.diagnostic("inspector prompt path=followup queued", .{});
        self.notifyInspectorPromptResult(.sent, null);
        return;
    }
    runtime_log.diagnostic("inspector prompt path=followup queue_failed", .{});
    self.syncPaletteComposerFromDraft();
    self.requestComposerFocus();
    self.notifyInspectorPromptResult(.drafted, null);
}

// Pastes the design-mode prompt into a TUI pane's input (Codex/Claude/
// opencode/... running in a thread-bound terminal dock). Bracketed paste
// fills the input without submitting so the user reviews and hits Enter.
// The screenshot rides along as a file path the CLI can read itself.
pub fn fillInspectorPromptIntoTui(
    self: anytype,
    pane_token: []const u8,
    context_block: []const u8,
    prompt: []const u8,
    capture: ?InspectorCapture,
) void {
    const failed = blk: {
        const pane_id = std.fmt.parseInt(WorkspacePaneId, pane_token, 10) catch break :blk true;
        const text = if (capture) |c|
            std.fmt.allocPrint(self.allocator, "{s}\n\n{s}Screenshot: {s}", .{ prompt, context_block, c.path })
        else
            std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ prompt, context_block });
        const resolved_text = text catch break :blk true;
        defer self.allocator.free(resolved_text);

        const pasted = self.pasteWorkspaceTerminalPaneForProject(
            self.project_controller.selected_index,
            pane_id,
            resolved_text,
        ) catch |err| {
            log.warn("failed to paste inspector prompt into TUI pane: {s}", .{@errorName(err)});
            break :blk true;
        };
        if (!pasted) break :blk true;

        // Hand focus to the TUI so the user can review and submit there.
        _ = self.focusWorkspacePane(self.project_controller.selected_index, pane_id);
        break :blk false;
    };

    if (failed) {
        // The TUI pane vanished or its session died between selection and
        // submit; keep the prompt by parking it in the composer draft.
        self.fallbackInspectorPromptToDraft(self.currentThreadMutable(), context_block, prompt, capture, false);
        return;
    }
    self.setSidebarNotice("Browser inspector prompt filled into the TUI input.");
    self.notifyInspectorPromptResult(.sent, null);
}

// Appends the design-mode prompt to the composer draft when auto-send is
// unsafe (send already running, or the user has an in-progress draft).
pub fn fallbackInspectorPromptToDraft(
    self: anytype,
    thread: *ChatThread,
    context_block: []const u8,
    prompt: []const u8,
    capture: ?InspectorCapture,
    send_busy: bool,
) void {
    const draft_block = std.fmt.allocPrint(
        self.allocator,
        "{s}Requested change:\n{s}",
        .{ context_block, prompt },
    ) catch |err| {
        log.warn("failed to build inspector draft block: {s}", .{@errorName(err)});
        self.setSidebarNotice("Browser inspector prompt could not be prepared.");
        self.notifyInspectorPromptResult(.failed, "Verde could not prepare this prompt.");
        return;
    };
    defer self.allocator.free(draft_block);

    const current_draft = self.currentDraft();
    const next_draft = if (current_draft.len == 0)
        self.allocator.dupe(u8, draft_block)
    else
        std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ current_draft, draft_block });
    const resolved_next_draft = next_draft catch |err| {
        log.warn("failed to append inspector prompt to draft: {s}", .{@errorName(err)});
        self.setSidebarNotice("Browser inspector prompt could not be added to the draft.");
        self.notifyInspectorPromptResult(.failed, "Verde could not add this prompt to the draft.");
        return;
    };
    defer self.allocator.free(resolved_next_draft);

    self.setDraft(resolved_next_draft);
    if (capture) |c| {
        thread.addDraftImage(self.allocator, c.path, "image/png", c.byte_len) catch |err| {
            log.warn("failed to attach inspector capture to draft: {s}", .{@errorName(err)});
        };
    }
    // setDraft alone leaves the composer widget stale; sync so the parked
    // prompt is actually visible to the user.
    self.syncPaletteComposerFromDraft();
    self.requestComposerFocus();
    runtime_log.diagnostic("inspector prompt path=draft busy={}", .{send_busy});
    self.setSidebarNotice(if (send_busy)
        "Browser inspector prompt added to the draft; a send is already running."
    else
        "Browser inspector prompt added to the current chat draft.");
    self.notifyInspectorPromptResult(.drafted, null);
}

/// Crops the latest CPU-side browser frame to the submitted selection and
/// stores it as a PNG attachment. Returns null when any step is
/// unavailable — the prompt then sends with text-only context.
pub fn captureInspectorSelectionImage(
    self: anytype,
    selection: InspectorSelectionPayload,
    viewport: ?InspectorViewportPayload,
) ?InspectorCapture {
    const vp = viewport orelse {
        runtime_log.diagnostic("inspector capture skipped: no viewport payload", .{});
        return null;
    };
    if (vp.width <= 0.0 or vp.height <= 0.0) return null;
    const css_rect: InspectorRectPayload = selection.rect orelse blk: {
        const element = selection.element orelse return null;
        break :blk element.rect orelse {
            runtime_log.diagnostic("inspector capture skipped: selection has no rect", .{});
            return null;
        };
    };

    const frame = (self.browser_controller.runtime.controller.copyFramePixels(self.allocator) catch |err| {
        log.warn("failed to copy browser frame for inspector capture: {s}", .{@errorName(err)});
        return null;
    }) orelse {
        runtime_log.diagnostic("inspector capture skipped: no CPU frame available", .{});
        return null;
    };
    defer frame.deinit(self.allocator);

    const crop = browser_screenshot.cropRectFromCss(
        css_rect.x,
        css_rect.y,
        css_rect.width,
        css_rect.height,
        vp.width,
        vp.height,
        frame.width,
        frame.height,
        INSPECTOR_CROP_PADDING_CSS,
    ) orelse return null;

    const png = browser_screenshot.encodeFrameCropPng(self.allocator, frame, crop) catch |err| {
        log.warn("failed to encode inspector capture: {s}", .{@errorName(err)});
        return null;
    };
    defer self.allocator.free(png);

    const path = self.writeImageBytesToStorage("inspector-captures", "inspector", "png", png) catch |err| {
        log.warn("failed to store inspector capture: {s}", .{@errorName(err)});
        return null;
    };
    return .{ .path = path, .byte_len = png.len };
}

// Switches the project's selected thread to the chat pane the user picked
// in the bubble's "Send to" selector. Invalid/closed panes are ignored so
// the send falls back to the last-focused thread. Accepts "chat:<pane>"
// (current bundles) and bare "<pane>" (transitional).
pub fn applyInspectorPromptTarget(self: anytype, target: []const u8) void {
    const pane_token = if (std.mem.startsWith(u8, target, "chat:")) target["chat:".len..] else target;
    const pane_id = std.fmt.parseInt(WorkspacePaneId, pane_token, 10) catch return;
    const thread_index = self.workspaceChatThreadIndexByPane(pane_id) orelse return;
    const project = &self.project_controller.projects.items[self.project_controller.selected_index];
    if (project.selected_thread_index == thread_index) return;
    project.selected_thread_index = thread_index;
    self.syncPaletteComposerFromDraft();
}

/// Pushes the current project's chat destinations into the inspector
/// bubble as "Send to" targets: visible chat panes plus threads open in a
/// TUI pane (Codex/Claude/opencode/... running in a thread-bound terminal
/// dock). The bubble shows a selector only when more than one exists.
/// Called whenever a selection is captured so the list tracks pane layout
/// changes.
pub fn pushInspectorPromptTargets(self: anytype) void {
    if (!self.canUseBrowserInspector() or !self.browser_controller.runtime.inspectorEnabled()) return;
    if (self.project_controller.projects.items.len == 0) return;
    const project = &self.project_controller.projects.items[self.project_controller.selected_index];

    const TargetJson = struct {
        id: []const u8,
        label: []const u8,
    };
    var owned_strings = std.ArrayList([]u8).empty;
    defer {
        for (owned_strings.items) |item| self.allocator.free(item);
        owned_strings.deinit(self.allocator);
    }
    var targets = std.ArrayList(TargetJson).empty;
    defer targets.deinit(self.allocator);
    var target_pane_ids = std.ArrayList(WorkspacePaneId).empty;
    defer target_pane_ids.deinit(self.allocator);
    var chat_default: ?[]const u8 = null;

    const current_thread_index = project.currentThreadIndex();
    for (project.workspace_layout.panes.items) |pane| {
        const thread_index = switch (pane.ref) {
            .chat => |ref| ref.thread_index,
            else => continue,
        };
        if (thread_index >= project.threads.items.len) continue;
        const id = std.fmt.allocPrint(self.allocator, "chat:{d}", .{pane.id}) catch return;
        owned_strings.append(self.allocator, id) catch {
            self.allocator.free(id);
            return;
        };
        targets.append(self.allocator, .{
            .id = id,
            .label = project.threads.items[thread_index].title,
        }) catch return;
        target_pane_ids.append(self.allocator, pane.id) catch return;
        if (chat_default == null and thread_index == current_thread_index) chat_default = id;
    }

    // Threads running as TUIs in thread-bound terminal docks are chat
    // destinations too: the prompt gets pasted into the TUI's input.
    for (project.threads.items) |*thread| {
        const dock_id = thread.tui_dock_id orelse continue;
        const pane_id = project.workspace_layout.visibleTerminalPaneIdForDock(dock_id) orelse continue;
        const dock = self.projectTerminalDockMutable(self.project_controller.selected_index, dock_id) orelse continue;
        if (!dock.hasRunningSession()) continue;
        const id = std.fmt.allocPrint(self.allocator, "tui:{d}", .{pane_id}) catch return;
        owned_strings.append(self.allocator, id) catch {
            self.allocator.free(id);
            return;
        };
        const label = std.fmt.allocPrint(self.allocator, "{s} (TUI)", .{thread.title}) catch return;
        owned_strings.append(self.allocator, label) catch {
            self.allocator.free(label);
            return;
        };
        targets.append(self.allocator, .{ .id = id, .label = label }) catch return;
        target_pane_ids.append(self.allocator, pane_id) catch return;
    }

    // Default: the last-focused chat/terminal pane wins, then the pane of
    // the currently selected thread, then the first target.
    var selected_id: ?[]const u8 = null;
    if (project.last_content_pane_id) |last_pane_id| {
        for (target_pane_ids.items, 0..) |pane_id, index| {
            if (pane_id == last_pane_id) {
                selected_id = targets.items[index].id;
                break;
            }
        }
    }
    if (selected_id == null) selected_id = chat_default;
    if (selected_id == null and targets.items.len > 0) selected_id = targets.items[0].id;

    // Two argument literals for setPromptTargets(targets, selectedId);
    // separate Stringify instances since each serializes one root value.
    var json_buffer: std.Io.Writer.Allocating = .init(self.allocator);
    defer json_buffer.deinit();
    var targets_jw: std.json.Stringify = .{ .writer = &json_buffer.writer, .options = .{} };
    targets_jw.write(targets.items) catch return;
    json_buffer.writer.writeAll(", ") catch return;
    var selected_jw: std.json.Stringify = .{ .writer = &json_buffer.writer, .options = .{} };
    selected_jw.write(selected_id) catch return;

    const script = std.fmt.allocPrint(
        self.allocator,
        "(function() {{ const h = window.VerdeInspector && window.VerdeInspector.get ? window.VerdeInspector.get() : null; if (h && typeof h.setPromptTargets === \"function\") h.setPromptTargets({s}); }})();",
        .{json_buffer.written()},
    ) catch return;
    defer self.allocator.free(script);

    runtime_log.diagnostic("inspector targets push count={d}", .{targets.items.len});
    self.browser_controller.runtime.expectSuppressedEvalResult();
    self.browser_controller.runtime.controller.eval(script) catch |err| {
        _ = self.browser_controller.runtime.consumeSuppressedEvalResult();
        log.warn("failed to push inspector prompt targets: {s}", .{@errorName(err)});
    };
}

// Evaluates the host→page acknowledgement for a submitted design-mode
// prompt. `message` must be a fixed string literal (it is interpolated
// into a JS string without escaping).
pub fn notifyInspectorPromptResult(self: anytype, result: InspectorPromptResult, message: ?[]const u8) void {
    if (!self.canUseBrowserInspector() or !self.browser_controller.runtime.inspectorEnabled()) {
        runtime_log.diagnostic("inspector ack skipped result={s} usable={} enabled={}", .{
            result.jsValue(),
            self.canUseBrowserInspector(),
            self.browser_controller.runtime.inspectorEnabled(),
        });
        return;
    }
    runtime_log.diagnostic("inspector ack dispatch result={s}", .{result.jsValue()});
    const script = std.fmt.allocPrint(
        self.allocator,
        "(function() {{ const h = window.VerdeInspector && window.VerdeInspector.get ? window.VerdeInspector.get() : null; if (h && typeof h.notifyPromptResult === \"function\") h.notifyPromptResult(\"{s}\", \"{s}\"); }})();",
        .{ result.jsValue(), message orelse "" },
    ) catch return;
    defer self.allocator.free(script);

    self.browser_controller.runtime.expectSuppressedEvalResult();
    self.browser_controller.runtime.controller.eval(script) catch |err| {
        _ = self.browser_controller.runtime.consumeSuppressedEvalResult();
        log.warn("failed to deliver inspector prompt result: {s}", .{@errorName(err)});
    };
}

/// Formats the selection metadata (mode, page, region, elements) that
/// accompanies every design-mode prompt. Ends with a trailing newline.
pub fn buildInspectorContextBlock(
    self: anytype,
    selection: InspectorSelectionPayload,
) ![]u8 {
    const allocator = self.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    const header = try std.fmt.allocPrint(
        allocator,
        "Browser inspector selection\nMode: {s}\n",
        .{selection.mode},
    );
    defer allocator.free(header);
    try buffer.appendSlice(allocator, header);

    if (self.browser_controller.runtime.current_url) |url| {
        const page_line = try std.fmt.allocPrint(allocator, "Page: {s}\n", .{url});
        defer allocator.free(page_line);
        try buffer.appendSlice(allocator, page_line);
    }

    if (selection.rect) |rect| {
        const region = try std.fmt.allocPrint(
            allocator,
            "Region: {d:.0} x {d:.0} at ({d:.0}, {d:.0})\n",
            .{ rect.width, rect.height, rect.x, rect.y },
        );
        defer allocator.free(region);
        try buffer.appendSlice(allocator, region);
    }

    if (selection.element) |element| {
        try appendInspectorElementSummary(&buffer, allocator, element, null);
    } else if (selection.elements) |elements| {
        const count = @min(elements.len, 6);
        const selected_label = try std.fmt.allocPrint(
            allocator,
            "Selected elements ({d} shown):\n",
            .{count},
        );
        defer allocator.free(selected_label);
        try buffer.appendSlice(allocator, selected_label);
        for (elements[0..count], 0..) |element, index| {
            try appendInspectorElementSummary(&buffer, allocator, element, index + 1);
        }
        if (elements.len > count) {
            const more_label = try std.fmt.allocPrint(
                allocator,
                "... and {d} more element{s}\n",
                .{ elements.len - count, if (elements.len - count == 1) "" else "s" },
            );
            defer allocator.free(more_label);
            try buffer.appendSlice(allocator, more_label);
        }
    }

    return buffer.toOwnedSlice(allocator);
}

pub fn appendInspectorElementSummary(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    element: InspectorElementPayload,
    index: ?usize,
) !void {
    const prefix = if (index) |value|
        try std.fmt.allocPrint(allocator, "{d}. ", .{value})
    else
        try allocator.dupe(u8, "Element: ");
    defer allocator.free(prefix);

    try buffer.appendSlice(allocator, prefix);
    try buffer.appendSlice(allocator, element.selector orelse "(unknown selector)");
    if (element.tagName) |tag_name| {
        const label = try std.fmt.allocPrint(allocator, " [{s}]", .{tag_name});
        defer allocator.free(label);
        try buffer.appendSlice(allocator, label);
    }
    try buffer.append(allocator, '\n');

    if (element.textSnippet) |text_snippet| {
        const trimmed = std.mem.trim(u8, text_snippet, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            const label = try std.fmt.allocPrint(allocator, "   text: {s}\n", .{trimmed});
            defer allocator.free(label);
            try buffer.appendSlice(allocator, label);
        }
    }
    if (element.ariaLabel) |aria_label| {
        const trimmed = std.mem.trim(u8, aria_label, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            const label = try std.fmt.allocPrint(allocator, "   aria-label: {s}\n", .{trimmed});
            defer allocator.free(label);
            try buffer.appendSlice(allocator, label);
        }
    }
    if (element.href) |href| {
        const trimmed = std.mem.trim(u8, href, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            const label = try std.fmt.allocPrint(allocator, "   href: {s}\n", .{trimmed});
            defer allocator.free(label);
            try buffer.appendSlice(allocator, label);
        }
    }
}

// Enables the bundled inspector and dispatches one internal eval into the current browser document.
pub fn enableBrowserInspector(self: anytype, show_notice: bool) void {
    self.applyBrowserInspector(show_notice, "Browser inspector enabled.");
}

// Enables or reapplies the bundled inspector using the currently selected mode.
pub fn applyBrowserInspector(self: anytype, show_notice: bool, success_notice: []const u8) void {
    if (!self.isBrowserVisible()) {
        self.setSidebarNotice("Open the browser before enabling the inspector.");
        return;
    }
    if (!self.canUseBrowserInspector()) {
        self.setSidebarNotice("The browser inspector is not available for this browser backend.");
        return;
    }
    if (!self.browserInspectorPolicyAllowsCurrentPage()) {
        self.setSidebarNotice("Browser inspector is only available for app, localhost, and web pages.");
        return;
    }

    const theme_json = inspectorThemeJsonAlloc(self.allocator) catch |err| {
        log.err("failed to build browser inspector theme: {s}", .{@errorName(err)});
        if (show_notice) self.setSidebarNotice("Failed to build the browser inspector.");
        return;
    };
    defer self.allocator.free(theme_json);

    const script = browser_inspector.enableScriptAlloc(self.allocator, self.browser_controller.runtime.inspectorMode(), theme_json) catch |err| {
        log.err("failed to build browser inspector script: {s}", .{@errorName(err)});
        if (show_notice) self.setSidebarNotice("Failed to build the browser inspector.");
        return;
    };
    defer self.allocator.free(script);

    self.browser_controller.runtime.setInspectorEnabled(true);
    self.browser_controller.runtime.expectSuppressedEvalResult();
    self.browser_controller.runtime.controller.eval(script) catch |err| {
        _ = self.browser_controller.runtime.consumeSuppressedEvalResult();
        self.browser_controller.runtime.setInspectorEnabled(false);
        log.err("failed to enable browser inspector: {s}", .{@errorName(err)});
        if (show_notice) self.setSidebarNotice("Failed to enable the browser inspector.");
        return;
    };
    if (show_notice) self.setSidebarNotice(success_notice);
}

/// Serializes the active UI theme tokens into the inspector bundle's
/// InspectorThemeInput shape (hex colors) so the in-page overlay matches
/// the app theme instead of the built-in green defaults.
pub fn inspectorThemeJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    var accent_buf: [7]u8 = undefined;
    var panel_buf: [7]u8 = undefined;
    var input_buf: [7]u8 = undefined;
    var text_buf: [7]u8 = undefined;
    var muted_buf: [7]u8 = undefined;
    var error_buf: [7]u8 = undefined;
    const theme_payload = .{
        .accent = cssHexFromColor(&accent_buf, theme.current_colors.accent),
        .panelBackground = cssHexFromColor(&panel_buf, theme.current_colors.panel_alt),
        .inputBackground = cssHexFromColor(&input_buf, theme.current_colors.panel),
        .text = cssHexFromColor(&text_buf, theme.current_colors.text),
        .textMuted = cssHexFromColor(&muted_buf, theme.current_colors.text_muted),
        .@"error" = cssHexFromColor(&error_buf, theme.current_colors.diff_remove),
    };

    var json_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer json_buffer.deinit();
    var jw: std.json.Stringify = .{ .writer = &json_buffer.writer, .options = .{} };
    try jw.write(theme_payload);
    return json_buffer.toOwnedSlice();
}

// Formats a normalized [4]f32 UI color as "#rrggbb" into `buffer`.
pub fn cssHexFromColor(buffer: *[7]u8, color: [4]f32) []const u8 {
    const r: u8 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0));
    const g: u8 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0));
    const b: u8 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0));
    return std.fmt.bufPrint(buffer, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch unreachable;
}

// Disables the bundled inspector overlay while leaving the page alive.
pub fn disableBrowserInspector(self: anytype, show_notice: bool) void {
    self.browser_controller.runtime.setInspectorEnabled(false);
    if (!self.isBrowserVisible() or !self.canUseBrowserInspector()) {
        if (show_notice) self.setSidebarNotice("Browser inspector disabled.");
        return;
    }

    self.browser_controller.runtime.expectSuppressedEvalResult();
    self.browser_controller.runtime.controller.eval(browser_inspector.disable_script) catch |err| {
        _ = self.browser_controller.runtime.consumeSuppressedEvalResult();
        log.err("failed to disable browser inspector: {s}", .{@errorName(err)});
        if (show_notice) self.setSidebarNotice("Failed to disable the browser inspector.");
        return;
    };
    if (show_notice) self.setSidebarNotice("Browser inspector disabled.");
}

// Reapplies the inspector after the next main-frame load when the user has it armed.
pub fn reapplyBrowserInspectorAfterLoad(self: anytype) void {
    if (!self.browser_controller.runtime.inspectorEnabled()) return;
    if (!self.canUseBrowserInspector()) return;
    self.applyBrowserInspector(false, "");
}

pub fn navigateBrowserHistory(self: anytype, delta: i32) void {
    if (self.navigatePersistedBrowserHistory(delta)) return;
    const result = if (delta < 0)
        self.browser_controller.runtime.controller.goBack()
    else
        self.browser_controller.runtime.controller.goForward();
    result catch |err| {
        log.warn("failed to navigate browser history: {s}", .{@errorName(err)});
        self.browser_controller.runtime.setLastError("Failed to navigate browser history.") catch {};
        return;
    };
    self.markDirty();
}

pub fn browserTabCount(self: anytype) usize {
    const ref = self.visibleBrowserPaneRefMutable() orelse return 0;
    return ref.tabs.items.len;
}

pub fn activeBrowserTabIndex(self: anytype) usize {
    const ref = self.visibleBrowserPaneRefMutable() orelse return 0;
    return @min(ref.active_tab_index, ref.tabs.items.len -| 1);
}

pub fn browserTabTitle(self: anytype, index: usize) []const u8 {
    const ref = self.visibleBrowserPaneRefMutable() orelse return "New tab";
    if (index >= ref.tabs.items.len) return "New tab";
    const tab = &ref.tabs.items[index];
    return tab.title orelse tab.url orelse "New tab";
}

pub fn browserTabPinned(self: anytype, index: usize) bool {
    const ref = self.visibleBrowserPaneRefMutable() orelse return false;
    if (index >= ref.tabs.items.len) return false;
    return ref.tabs.items[index].pinned;
}

pub fn browserTabIndicator(self: anytype, index: usize) BrowserTabIndicator {
    const ref = self.visibleBrowserPaneRefMutable() orelse return .none;
    if (index >= ref.tabs.items.len) return .none;
    const tab = &ref.tabs.items[index];
    if (tab.load_failed) return .failed;
    if (tab.loading) return .loading;
    return .none;
}

pub fn browserCanGoBack(self: anytype) bool {
    const ref = self.visibleBrowserPaneRefMutable() orelse return false;
    const tab = ref.activeTab() orelse return false;
    return (tab.history_index orelse 0) > 0;
}

pub fn browserCanGoForward(self: anytype) bool {
    const ref = self.visibleBrowserPaneRefMutable() orelse return false;
    const tab = ref.activeTab() orelse return false;
    const index = tab.history_index orelse return false;
    return index + 1 < tab.history.items.len;
}

pub fn createBrowserTab(self: anytype) void {
    const ref = self.visibleBrowserPaneRefMutable() orelse return;
    ref.tabs.append(self.allocator, .{}) catch |err| {
        log.warn("failed to create browser tab: {s}", .{@errorName(err)});
        return;
    };
    ref.active_tab_index = ref.tabs.items.len - 1;
    self.activateBrowserTabRuntime(null, null);
    self.browser_controller.address_focused = true;
    self.markDirty();
}

pub fn duplicateBrowserTab(self: anytype, index: usize) void {
    const ref = self.visibleBrowserPaneRefMutable() orelse return;
    if (index >= ref.tabs.items.len) return;
    const duplicate = ref.tabs.items[index].clone(self.allocator) catch |err| {
        log.warn("failed to duplicate browser tab: {s}", .{@errorName(err)});
        return;
    };
    ref.tabs.insert(self.allocator, index + 1, duplicate) catch |err| {
        var owned = duplicate;
        owned.deinit(self.allocator);
        log.warn("failed to insert duplicated browser tab: {s}", .{@errorName(err)});
        return;
    };
    ref.active_tab_index = index + 1;
    const active = &ref.tabs.items[ref.active_tab_index];
    self.activateBrowserTabRuntime(active.url, active.title);
    self.markDirty();
}

pub fn toggleBrowserTabPinned(self: anytype, index: usize) void {
    const ref = self.visibleBrowserPaneRefMutable() orelse return;
    if (index >= ref.tabs.items.len) return;
    const was_pinned = ref.tabs.items[index].pinned;
    var pinned_count: usize = 0;
    for (ref.tabs.items) |tab| {
        if (tab.pinned) pinned_count += 1;
    }
    ref.tabs.items[index].pinned = !was_pinned;
    const target = if (was_pinned) pinned_count -| 1 else pinned_count;
    ref.moveTab(self.allocator, index, @min(target, ref.tabs.items.len - 1)) catch |err| {
        ref.tabs.items[index].pinned = was_pinned;
        log.warn("failed to reposition pinned browser tab: {s}", .{@errorName(err)});
        return;
    };
    self.markDirty();
}

pub fn moveBrowserTab(self: anytype, from: usize, to: usize) void {
    const ref = self.visibleBrowserPaneRefMutable() orelse return;
    ref.moveTab(self.allocator, from, to) catch |err| {
        log.warn("failed to reorder browser tab: {s}", .{@errorName(err)});
        return;
    };
    self.markDirty();
}

pub fn switchBrowserTab(self: anytype, index: usize) void {
    const ref = self.visibleBrowserPaneRefMutable() orelse return;
    if (index >= ref.tabs.items.len or index == ref.active_tab_index) return;
    ref.active_tab_index = index;
    const tab = &ref.tabs.items[index];
    self.activateBrowserTabRuntime(tab.url, tab.title);
    self.markDirty();
}

pub fn closeBrowserTab(self: anytype, index: usize) void {
    const ref = self.visibleBrowserPaneRefMutable() orelse return;
    if (index >= ref.tabs.items.len) return;
    if (ref.tabs.items.len == 1) {
        ref.tabs.items[0].deinit(self.allocator);
        ref.tabs.items[0] = .{};
        ref.active_tab_index = 0;
    } else {
        var removed = ref.tabs.orderedRemove(index);
        removed.deinit(self.allocator);
        if (ref.active_tab_index >= ref.tabs.items.len) ref.active_tab_index = ref.tabs.items.len - 1 else if (index < ref.active_tab_index) ref.active_tab_index -= 1;
    }
    const active = ref.activeTab().?;
    self.activateBrowserTabRuntime(active.url, active.title);
    self.markDirty();
}

pub fn activateBrowserTabRuntime(self: anytype, url: ?[]const u8, title: ?[]const u8) void {
    self.restartBrowserRuntimeForCrossOriginNavigation(url orelse "about:blank");
    self.browser_controller.runtime.setCurrentUrl(url) catch {};
    self.browser_controller.runtime.setCurrentTitle(title) catch {};
    self.browser_controller.runtime.setAddress(url orelse "");
    self.browser_controller.address_cursor = self.browser_controller.runtime.addressInput().len;
    self.browser_controller.address_selection_anchor = null;
    self.browser_controller.runtime.status = .opening;
    if (self.visibleBrowserPaneRefMutable()) |ref| {
        if (ref.activeTab()) |tab| {
            tab.loading = true;
            tab.load_failed = false;
        }
    }
    self.browser_controller.runtime.controller.navigate(url orelse "about:blank") catch |err| {
        log.warn("failed to activate browser tab: {s}", .{@errorName(err)});
        self.browser_controller.runtime.status = .failed;
        self.browser_controller.runtime.setLastError("Failed to activate browser tab.") catch {};
        if (self.visibleBrowserPaneRefMutable()) |ref| {
            if (ref.activeTab()) |tab| {
                tab.loading = false;
                tab.load_failed = true;
            }
        }
    };
}

pub fn reloadBrowser(self: anytype) void {
    self.setActiveBrowserTabLoadState(true, false);
    self.browser_controller.runtime.controller.reload() catch |err| {
        log.warn("failed to reload browser: {s}", .{@errorName(err)});
        self.setActiveBrowserTabLoadState(false, true);
        self.browser_controller.runtime.setLastError("Failed to reload browser.") catch {};
        return;
    };
    self.setSidebarNotice("Browser reload requested.");
    self.markDirty();
}

pub fn openCurrentBrowserUrlExternally(self: anytype) void {
    const url = self.browser_controller.runtime.current_url orelse {
        self.setSidebarNotice("No browser URL to open.");
        return;
    };
    utils.openUrlInDefaultBrowser(self.allocator, url) catch |err| {
        log.warn("failed to open current browser URL externally: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to open URL in the default browser.");
        return;
    };
    self.setSidebarNotice("Opened URL in the default browser.");
}

pub fn selectAllBrowserFocusedElement(self: anytype) void {
    const script =
        \\(function(){
        \\  let el=window.__verdeInputTarget;
        \\  if(el&&!el.isConnected)el=null;
        \\  const resolve=(node)=>{
        \\    if(!node)return null;
        \\    if(node.isContentEditable||node instanceof HTMLInputElement||node instanceof HTMLTextAreaElement)return node;
        \\    return (node.closest&&node.closest('input,textarea,[contenteditable="true"]'))||null;
        \\  };
        \\  el=resolve(el)||resolve(document.activeElement);
        \\  if(!el)return false;
        \\  window.__verdeInputTarget=el;
        \\  if(el.focus)el.focus({preventScroll:true});
        \\  if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){
        \\    if(el.setSelectionRange)el.setSelectionRange(0,el.value.length);
        \\    return true;
        \\  }
        \\  if(el.isContentEditable){
        \\    const range=document.createRange();
        \\    range.selectNodeContents(el);
        \\    const selection=window.getSelection();
        \\    if(!selection)return false;
        \\    selection.removeAllRanges();
        \\    selection.addRange(range);
        \\    return true;
        \\  }
        \\  return false;
        \\})()
    ;
    self.browser_controller.runtime.expectSuppressedEvalResult();
    self.browser_controller.runtime.controller.eval(script) catch |err| {
        log.warn("failed to select browser focused element text: {s}", .{@errorName(err)});
        return;
    };
    self.markDirty();
}

pub fn pasteBrowserTextIntoFocusedElement(self: anytype, text: []const u8) void {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    stringify.write(text) catch |err| {
        log.warn("failed to encode browser paste text: {s}", .{@errorName(err)});
        return;
    };
    const encoded = out.written();
    const script = std.fmt.allocPrint(self.allocator,
        \\(function(){{
        \\  const text={s};
        \\  let el=window.__verdeInputTarget;
        \\  if(el&&!el.isConnected)el=null;
        \\  const resolve=(node)=>{{
        \\    if(!node)return null;
        \\    if(node.isContentEditable||node instanceof HTMLInputElement||node instanceof HTMLTextAreaElement)return node;
        \\    return (node.closest&&node.closest('input,textarea,[contenteditable="true"]'))||null;
        \\  }};
        \\  el=resolve(el)||resolve(document.activeElement);
        \\  if(!el)return false;
        \\  window.__verdeInputTarget=el;
        \\  if(el.focus)el.focus({{preventScroll:true}});
        \\  if(el.isContentEditable){{
        \\    document.execCommand('insertText',false,text);
        \\    return true;
        \\  }}
        \\  if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){{
        \\    const start=el.selectionStart??el.value.length;
        \\    const end=el.selectionEnd??el.value.length;
        \\    el.value=el.value.slice(0,start)+text+el.value.slice(end);
        \\    const next=start+text.length;
        \\    if(el.setSelectionRange)el.setSelectionRange(next,next);
        \\    el.dispatchEvent(new InputEvent('input',{{bubbles:true,data:text,inputType:'insertFromPaste'}}));
        \\    return true;
        \\  }}
        \\  return false;
        \\}})()
    , .{encoded}) catch |err| {
        log.warn("failed to build browser paste script: {s}", .{@errorName(err)});
        return;
    };
    defer self.allocator.free(script);
    self.browser_controller.runtime.expectSuppressedEvalResult();
    self.browser_controller.runtime.controller.eval(script) catch |err| {
        log.warn("failed to paste browser text: {s}", .{@errorName(err)});
        return;
    };
    self.markDirty();
}

pub fn copyBrowserFocusedSelection(self: anytype, cut: bool) void {
    const script = if (cut)
        \\(function(){
        \\  const post=(text)=>{
        \\    const payload=JSON.stringify({source:'verde-browser-clipboard',text:String(text||''),cut:true});
        \\    if(window.__VERDE_BROWSER_IPC__&&typeof window.__VERDE_BROWSER_IPC__.postMessage==='function'){window.__VERDE_BROWSER_IPC__.postMessage(payload);return;}
        \\    if(window.verde&&typeof window.verde.postMessage==='function'){window.verde.postMessage(payload);return;}
        \\    if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.verde){window.webkit.messageHandlers.verde.postMessage(payload);}
        \\  };
        \\  let el=window.__verdeInputTarget;
        \\  if(el&&!el.isConnected)el=null;
        \\  const resolve=(node)=>{
        \\    if(!node)return null;
        \\    if(node.isContentEditable||node instanceof HTMLInputElement||node instanceof HTMLTextAreaElement)return node;
        \\    return (node.closest&&node.closest('input,textarea,[contenteditable="true"]'))||null;
        \\  };
        \\  el=resolve(el)||resolve(document.activeElement);
        \\  let text='';
        \\  if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){
        \\    const start=el.selectionStart??0;
        \\    const end=el.selectionEnd??0;
        \\    text=el.value.slice(start,end);
        \\    if(text.length>0){
        \\      el.value=el.value.slice(0,start)+el.value.slice(end);
        \\      if(el.setSelectionRange)el.setSelectionRange(start,start);
        \\      el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteByCut'}));
        \\    }
        \\  }else{
        \\    text=String(window.getSelection?.()||'');
        \\    if(text.length>0&&el&&el.isContentEditable){document.execCommand('delete',false);}
        \\  }
        \\  window.__verdeClipboardSelection=text;
        \\  post(text);
        \\  return text.length>0;
        \\})()
    else
        \\(function(){
        \\  const post=(text)=>{
        \\    const payload=JSON.stringify({source:'verde-browser-clipboard',text:String(text||''),cut:false});
        \\    if(window.__VERDE_BROWSER_IPC__&&typeof window.__VERDE_BROWSER_IPC__.postMessage==='function'){window.__VERDE_BROWSER_IPC__.postMessage(payload);return;}
        \\    if(window.verde&&typeof window.verde.postMessage==='function'){window.verde.postMessage(payload);return;}
        \\    if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.verde){window.webkit.messageHandlers.verde.postMessage(payload);}
        \\  };
        \\  let el=window.__verdeInputTarget;
        \\  if(el&&!el.isConnected)el=null;
        \\  const resolve=(node)=>{
        \\    if(!node)return null;
        \\    if(node.isContentEditable||node instanceof HTMLInputElement||node instanceof HTMLTextAreaElement)return node;
        \\    return (node.closest&&node.closest('input,textarea,[contenteditable="true"]'))||null;
        \\  };
        \\  el=resolve(el)||resolve(document.activeElement);
        \\  let text='';
        \\  if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){
        \\    text=el.value.slice(el.selectionStart??0,el.selectionEnd??0);
        \\  }else{
        \\    text=String(window.getSelection?.()||'');
        \\  }
        \\  window.__verdeClipboardSelection=text;
        \\  post(text);
        \\  return text.length>0;
        \\})()
    ;
    self.browser_controller.runtime.expectSuppressedEvalResult();
    self.browser_controller.runtime.controller.eval(script) catch |err| {
        log.warn("failed to capture browser focused selection: {s}", .{@errorName(err)});
        return;
    };
    self.markDirty();
}

pub fn copyBrowserEvalResultToClipboard(self: anytype, result: []const u8) void {
    if (result.len == 0) return;
    const z = self.allocator.dupeZ(u8, result) catch |err| {
        log.warn("failed to copy browser selection: {s}", .{@errorName(err)});
        return;
    };
    defer self.allocator.free(z);
    sdl.setClipboardText(z) catch |err| {
        log.warn("failed to set browser selection clipboard text: {s}", .{@errorName(err)});
        return;
    };
    self.setSidebarNotice("Browser selection copied.");
}

pub fn isInspectorBridgeMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"source\":\"verde-inspector\"") != null;
}

pub fn isInspectorHoverMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"type\":\"element:hover\"") != null;
}

pub fn isInspectorLifecycleMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"type\":\"inspector:enabled\"") != null or
        std.mem.indexOf(u8, message, "\"type\":\"inspector:disabled\"") != null or
        std.mem.indexOf(u8, message, "\"type\":\"inspector:mode-changed\"") != null;
}

pub fn isInspectorDisabledMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"type\":\"inspector:disabled\"") != null;
}

pub fn isInspectorSelectionMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"type\":\"element:selected\"") != null or
        std.mem.indexOf(u8, message, "\"type\":\"region:selected\"") != null;
}

pub fn isInspectorPromptSubmittedMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"type\":\"prompt:submitted\"") != null;
}

pub fn isInspectorPromptChangedMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "\"type\":\"prompt:changed\"") != null;
}

test "browser fast scrolling uses a separate wheel multiplier" {
    try std.testing.expectEqual(@as(f32, 1.0), browserWheelMultiplier(false));
    try std.testing.expectEqual(@as(f32, 1.5), browserWheelMultiplier(true));
}

test "scaled WPE pointer coordinates stay in physical pane space" {
    try std.testing.expectEqual(@as(f32, 600.0), browserPointerCoordinate(600.0, 1000.0, 600.0, true));
    try std.testing.expectEqual(@as(f32, 360.0), browserPointerCoordinate(600.0, 1000.0, 600.0, false));
}

test "browser automation pointer coordinates scale logical input once" {
    try std.testing.expectEqual(@as(f32, 360.0), browserAutomationPointerCoordinate(360.0, 1.0));
    try std.testing.expectEqual(@as(f32, 600.0), browserAutomationPointerCoordinate(360.0, 5.0 / 3.0));
}
