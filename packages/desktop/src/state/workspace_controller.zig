//! Workspace command classification and lease controller operations.

const std = @import("std");
const project_state = @import("project.zig");
const process_registry = @import("../daemon/process_registry.zig");
const provider_types = @import("headless").provider_types;
const chat_threads = @import("../chat/threads.zig");
const runtime_log = @import("../runtime/log.zig");
const terminal = @import("../terminal/terminal.zig");
const chat_types = @import("chat_types.zig");
const utils = @import("../utils.zig");
const provider_models = @import("provider_models.zig");
const workspace_layout = @import("workspace_layout.zig");
const platform_runtime = @import("platform_runtime");
const log = std.log.scoped(.native_shell);

const ChatThread = chat_types.ChatThread;
const ChatImageAttachment = chat_types.ChatImageAttachment;
const PendingTimelineEvent = chat_types.PendingTimelineEvent;
const Provider = provider_models.Provider;
const ReasoningEffort = provider_models.ReasoningEffort;
const FastMode = provider_models.FastMode;
const ModelOption = provider_models.ModelOption;
const DEFAULT_CODEX_REASONING_EFFORT = provider_models.DEFAULT_CODEX_REASONING_EFFORT;
const DEFAULT_CODEX_MODEL = provider_models.DEFAULT_CODEX_MODEL;
const DEFAULT_OPENCODE_MODEL = provider_models.DEFAULT_OPENCODE_MODEL;
const DEFAULT_CLAUDE_MODEL = provider_models.DEFAULT_CLAUDE_MODEL;
const DEFAULT_CURSOR_MODEL = provider_models.DEFAULT_CURSOR_MODEL;
const CODEX_MODEL_OPTIONS = provider_models.CODEX_MODEL_OPTIONS;
const PI_MODEL_OPTIONS = provider_models.PI_MODEL_OPTIONS;
const DEFAULT_PI_MODEL = provider_models.DEFAULT_PI_MODEL;
const FX_MODEL_OPTIONS = provider_models.FX_MODEL_OPTIONS;
const DEFAULT_FX_MODEL = provider_models.DEFAULT_FX_MODEL;
const GROK_MODEL_OPTIONS = provider_models.GROK_MODEL_OPTIONS;
const DEFAULT_GROK_MODEL = provider_models.DEFAULT_GROK_MODEL;
const DEFAULT_MUSE_MODEL = provider_models.DEFAULT_MUSE_MODEL;
const CLAUDE_STANDARD_EFFORT_VALUES = provider_models.CLAUDE_STANDARD_EFFORT_VALUES;
const parseReasoningEffort = provider_models.parseReasoningEffort;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;
const WorkspacePaneKind = workspace_layout.WorkspacePaneKind;
const WorkspacePaneRef = workspace_layout.WorkspacePaneRef;
const WorkspaceNode = workspace_layout.WorkspaceNode;
const FloatingPaneGeometry = workspace_layout.FloatingPaneGeometry;
const FloatingQuickPane = workspace_layout.FloatingQuickPane;
const WorkspaceLayout = workspace_layout.WorkspaceLayout;
const deinitWorkspacePaneRef = workspace_layout.deinitWorkspacePaneRef;
const WorkspacePaneDirection = workspace_layout.WorkspacePaneDirection;
const WorkspacePanePlacement = workspace_layout.WorkspacePanePlacement;
const WorkspaceSplitAxis = workspace_layout.WorkspaceSplitAxis;

pub const OpenChatResult = struct {
    pane_id: WorkspacePaneId,
    thread_index: usize,
    focused: bool,
    presentation_existing: bool = false,
};

pub const OpenChatRequest = struct {
    provider: Provider,
    model_ref: ?[]const u8 = null,
    reasoning_effort: ?ReasoningEffort = null,
    reasoning_variant: ?[]const u8 = null,
    fast_mode: ?FastMode = null,
    target_pane_id: ?WorkspacePaneId = null,
    axis: WorkspaceSplitAxis = .horizontal,
    focus: bool = true,
};

pub const PresentChatRequest = struct {
    local_thread_id: []const u8,
    target_pane_id: ?WorkspacePaneId = null,
    axis: WorkspaceSplitAxis = .horizontal,
    focus: bool = true,
};

const EffectiveChatSettings = struct {
    reasoning_effort: ?ReasoningEffort,
    reasoning_variant: ?[]const u8,
    fast_mode: FastMode,
};

const WorkspaceViewportSnapshot = struct {
    offset_x: f32,
    target_x: f32,
    offset_y: f32,
    target_y: f32,
    revealed_pane_id: ?WorkspacePaneId,
    leading_pane_id: ?WorkspacePaneId,
    animation_last_ms: i64,
    axis_vertical: bool,
};

pub const ViewFocusSnapshot = struct {
    selected_project_index: usize,
    terminal_focused: bool,
    composer_focused: bool,
    palette_composer_focused: bool,
    browser_address_focused: bool,
};

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

fn composerModelOptions(self: anytype, provider: Provider) []const ModelOption {
    return chat_threads.modelOptions(
        ModelOption,
        provider,
        self.opencodeModelOptionsSnapshot(),
        CODEX_MODEL_OPTIONS[0..],
        self.claudeModelOptionsSnapshot(),
        self.cursorModelOptionsSnapshot(),
        self.piModelOptionsSnapshot(),
        self.fxModelOptionsSnapshot(),
        self.grokModelOptionsSnapshot(),
        self.museModelOptionsSnapshot(),
    );
}

fn composerDefaultModelRef(self: anytype, provider: Provider) [:0]const u8 {
    return switch (provider) {
        .codex => DEFAULT_CODEX_MODEL,
        .opencode => self.cachedDefaultModelRefForProvider(.opencode),
        .claude => DEFAULT_CLAUDE_MODEL,
        .cursor => DEFAULT_CURSOR_MODEL,
        .pi => DEFAULT_PI_MODEL,
        .fx => DEFAULT_FX_MODEL,
        .grok => DEFAULT_GROK_MODEL,
        .muse => DEFAULT_MUSE_MODEL,
    };
}

const Project = project_state.Project;
const WorkspaceLease = project_state.WorkspaceLease;
const TerminalProcessFinish = project_state.TerminalProcessFinish;

pub const CommandClass = process_registry.CommandClass;
pub const classifyWorkspaceCommand = process_registry.classifyWorkspaceCommand;
pub const inferredWorkspaceResource = process_registry.inferredWorkspaceResource;
pub const workspaceResourcesOverlap = process_registry.workspaceResourcesOverlap;
pub const appendOwnedString = process_registry.appendOwnedString;

pub fn pruneExpiredLeases(project: *Project, allocator: std.mem.Allocator, now_ms: i64) void {
    _ = process_registry.pruneExpiredLeaseList(&project.workspace_leases, allocator, now_ms);
}

pub fn acquireLease(
    project: *Project,
    allocator: std.mem.Allocator,
    owner: []const u8,
    command: []const u8,
    resources: []const []const u8,
    ttl_ms: i64,
    force: bool,
    now_ms: i64,
) !*WorkspaceLease {
    if (owner.len == 0) return error.LeaseOwnerRequired;
    if (resources.len == 0) return error.LeaseResourcesRequired;
    const lease_index = try process_registry.acquireLeaseInList(
        &project.workspace_leases,
        allocator,
        owner,
        command,
        resources,
        ttl_ms,
        force,
        now_ms,
        .legacy_decimal,
        "",
        &project.next_workspace_lease_id,
    );
    return &project.workspace_leases.items[lease_index];
}

pub fn releaseLease(project: *Project, allocator: std.mem.Allocator, owner: []const u8, lease_id: ?[]const u8, now_ms: i64) usize {
    if (owner.len == 0) return 0;
    _ = process_registry.pruneExpiredLeaseList(&project.workspace_leases, allocator, now_ms);
    return process_registry.releaseLeaseList(&project.workspace_leases, allocator, owner, lease_id);
}

pub fn releaseLeasesForExactOwner(project: *Project, allocator: std.mem.Allocator, owner: []const u8, now_ms: i64) usize {
    if (owner.len == 0) return 0;
    _ = process_registry.pruneExpiredLeaseList(&project.workspace_leases, allocator, now_ms);
    return process_registry.releaseLeasesForExactOwnerList(&project.workspace_leases, allocator, owner);
}

pub fn ensureCurrentProjectWorkspace(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    const changed = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.ensureDefaultChat(self.allocator) catch |err| {
        log.err("failed to initialize workspace panes: {s}", .{@errorName(err)});
        return;
    };
    if (changed) self.markWorkspaceDirty(self.project_controller.selected_index);
}

pub fn focusedWorkspacePaneKind(self: anytype) ?WorkspacePaneKind {
    if (self.project_controller.projects.items.len == 0) return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane = layout.focusedPane() orelse return null;
    return switch (pane.ref) {
        .chat => .chat,
        .terminal => .terminal,
        .browser => .browser,
    };
}

pub fn focusedWorkspaceChatPaneId(self: anytype) ?WorkspacePaneId {
    if (self.project_controller.projects.items.len == 0) return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane_id = layout.focused_pane_id orelse return null;
    return if (self.workspaceChatThreadIndexByPane(pane_id) != null) pane_id else null;
}

pub fn currentProjectHasVisibleWorkspaceTerminalPane(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.hasVisiblePaneKind(.terminal);
}

pub fn currentProjectVisibleBrowserPaneId(self: anytype) ?WorkspacePaneId {
    if (self.project_controller.projects.items.len == 0) return null;
    return self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.visibleBrowserPaneId();
}

pub fn threadIsOpenInTui(self: anytype, project_index: usize, thread_index: usize) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    if (thread_index >= project.threads.items.len) return false;
    const dock_id = project.threads.items[thread_index].tui_dock_id orelse return false;
    return project.workspace_layout.visibleTerminalPaneIdForDock(dock_id) != null;
}

pub fn currentProjectWorkspaceRoot(self: anytype) ?*const WorkspaceNode {
    if (self.project_controller.projects.items.len == 0) return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    if (layout.maximized_pane_id) |pane_id| {
        if (layout.paneById(pane_id) != null) return layout.root;
    }
    return layout.root;
}

pub fn currentProjectWorkspaceMaximizedPaneId(self: anytype) ?WorkspacePaneId {
    if (self.project_controller.projects.items.len == 0) return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane_id = layout.maximized_pane_id orelse return null;
    _ = layout.paneById(pane_id) orelse return null;
    return pane_id;
}

/// Whether `layout` renders as the scrolling strip under the user's scroll
/// settings; the strip gives every tab its own slot, so zoom stays inside it.
pub fn workspaceScrollingStripActive(self: anytype, layout: *const WorkspaceLayout) bool {
    return layout.scrollingStripEnabled(self.app_config.workspace_scroll_mode, self.app_config.workspace_scroll_threshold);
}

/// Whether the strip scrolls between tabs (wheel, eased reveal). Below the
/// "Start after" threshold it still gives every tab its own view but jumps
/// to the focused tab in place.
pub fn workspaceScrollingStripScrolls(self: anytype, layout: *const WorkspaceLayout) bool {
    return layout.scrollingStripScrolls(self.app_config.workspace_scroll_mode, self.app_config.workspace_scroll_threshold);
}

/// Zoomed pane of the selected workspace when it fills the whole pane region
/// (tiled layout, or a zoomed pane outside the strip's root tree). Null while
/// the strip is showing, where a zoomed pane only fills its tab's slot.
pub fn currentProjectWorkspaceFullZoomPaneId(self: anytype) ?WorkspacePaneId {
    const pane_id = self.currentProjectWorkspaceMaximizedPaneId() orelse return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    if (self.workspaceScrollingStripActive(layout) and layout.rootContainsPane(pane_id)) return null;
    return pane_id;
}

pub fn currentProjectQuickPane(self: anytype) ?FloatingQuickPane {
    if (self.project_controller.projects.items.len == 0) return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const quick = layout.quick_pane orelse return null;
    _ = layout.paneById(quick.pane_id) orelse return null;
    return quick;
}

pub fn floatFocusedWorkspacePane(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane_id = layout.focused_pane_id orelse return false;
    if (layout.paneById(pane_id) == null) return false;
    if (layout.quick_pane) |quick| {
        if (quick.pane_id == pane_id and quick.detached) {
            layout.quick_pane.?.visible = true;
            _ = self.focusCurrentProjectWorkspacePane(pane_id);
            self.markWorkspaceDirty(self.project_controller.selected_index);
            return true;
        }
        if (quick.pane_id != pane_id) {
            if (!self.returnCurrentProjectQuickPaneToTile()) return false;
            layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
        }
    }
    if (!layout.rootContainsPane(pane_id)) {
        layout.quick_pane = .{ .pane_id = pane_id, .visible = true, .detached = true, .return_focus_pane_id = layout.firstVisiblePaneId() };
    } else {
        if (layout.visiblePaneCount() <= 1) {
            self.setSidebarNotice("Add another tiled pane before floating this one.");
            return false;
        }
        if (layout.root) |root_node| layout.root = WorkspaceLayout.removePaneFromTree(self.allocator, root_node, pane_id);
        layout.quick_pane = .{
            .pane_id = pane_id,
            .detached = true,
            .return_focus_pane_id = layout.firstVisiblePaneId(),
        };
    }
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn toggleCurrentProjectQuickPane(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    if (layout.quick_pane == null) return self.createFloatingQuickTerminal();
    if (!layout.quick_pane.?.detached and layout.rootContainsPane(layout.quick_pane.?.pane_id)) {
        if (layout.visiblePaneCount() <= 1) return false;
        const quick_pane_id = layout.quick_pane.?.pane_id;
        if (layout.root) |root_node| layout.root = WorkspaceLayout.removePaneFromTree(self.allocator, root_node, quick_pane_id);
        layout.quick_pane.?.detached = true;
        layout.quick_pane.?.return_focus_pane_id = layout.firstVisiblePaneId();
    }
    layout.quick_pane.?.visible = !layout.quick_pane.?.visible;
    if (layout.quick_pane.?.visible) {
        _ = self.focusCurrentProjectWorkspacePane(layout.quick_pane.?.pane_id);
    } else {
        self.restoreFocusBehindQuickPane(layout.quick_pane.?);
    }
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn createFloatingQuickTerminal(self: anytype) bool {
    return createFloatingQuickTerminalWithProfile(self, .{});
}

pub fn createFloatingQuickTerminalWithProfile(self: anytype, profile: terminal.TerminalLaunchProfile) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const project_index = self.project_controller.selected_index;
    self.ensureCurrentProjectWorkspace();
    const return_focus_pane_id = self.project_controller.projects.items[project_index].workspace_layout.focused_pane_id;

    const dock_id = self.createProjectTerminalDock(project_index) catch |err| {
        log.err("failed to allocate quick terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create quick terminal.");
        return false;
    };
    const cwd = self.project_controller.projects.items[project_index].path;
    self.restartTerminalDockForWorkspaceProfile(project_index, dock_id, cwd, profile) catch |err| {
        log.err("failed to start quick terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to start quick terminal.");
        return false;
    };
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const pane_id = layout.createTerminalPane(self.allocator, dock_id) catch |err| {
        log.err("failed to create floating quick terminal pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create quick terminal.");
        return false;
    };
    layout.quick_pane = .{
        .pane_id = pane_id,
        .detached = true,
        .return_focus_pane_id = return_focus_pane_id,
    };
    layout.focused_pane_id = pane_id;
    dock.visible = false;
    self.requestTerminalDockFocus(dock_id);
    self.setSidebarNotice("Quick terminal ready.");
    self.markWorkspaceDirty(project_index);
    return true;
}

pub fn restoreFocusBehindQuickPane(self: anytype, quick: FloatingQuickPane) void {
    if (quick.return_focus_pane_id) |pane_id| {
        const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
        if (layout.rootContainsPane(pane_id)) {
            _ = self.focusCurrentProjectWorkspacePane(pane_id);
            return;
        }
    }
    self.unfocusBrowserPane();
    self.terminal_controller.focused = false;
}

pub fn minimizeCurrentProjectQuickPane(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const quick = if (layout.quick_pane) |*value| value else return false;
    quick.visible = false;
    self.restoreFocusBehindQuickPane(quick.*);
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn toggleCurrentProjectQuickPaneMaximized(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const quick = if (layout.quick_pane) |*value| value else return false;
    quick.visible = true;
    quick.maximized = !quick.maximized;
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn toggleCurrentProjectQuickPanePinned(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const quick = if (layout.quick_pane) |*value| value else return false;
    quick.pinned = !quick.pinned;
    quick.visible = true;
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn returnCurrentProjectQuickPaneToTile(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const quick = layout.quick_pane orelse return false;
    if (quick.detached) {
        const target_pane_id = if (quick.return_focus_pane_id) |pane_id|
            if (layout.rootContainsPane(pane_id)) pane_id else layout.firstVisiblePaneId()
        else
            layout.firstVisiblePaneId();
        if (target_pane_id) |target| {
            layout.splitPaneWithLeaf(self.allocator, target, quick.pane_id, .horizontal, true) catch |err| {
                log.err("failed to return quick pane to tiled layout: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to tile quick pane.");
                return false;
            };
        } else {
            layout.root = WorkspaceLayout.createLeafNode(self.allocator, quick.pane_id) catch return false;
        }
    }
    layout.quick_pane = null;
    _ = self.focusCurrentProjectWorkspacePane(quick.pane_id);
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn setCurrentProjectQuickPaneGeometry(self: anytype, geometry: FloatingPaneGeometry) void {
    if (self.project_controller.projects.items.len == 0) return;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const quick = if (layout.quick_pane) |*value| value else return;
    quick.geometry = .{
        .x = std.math.clamp(geometry.x, 0.0, 0.95),
        .y = std.math.clamp(geometry.y, 0.0, 0.95),
        .w = std.math.clamp(geometry.w, 0.05, 1.0),
        .h = std.math.clamp(geometry.h, 0.05, 1.0),
    };
    quick.maximized = false;
    self.markWorkspaceDirty(self.project_controller.selected_index);
}

pub fn workspacePaneKindById(self: anytype, pane_id: WorkspacePaneId) ?WorkspacePaneKind {
    if (self.project_controller.projects.items.len == 0) return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane = layout.paneById(pane_id) orelse return null;
    return switch (pane.ref) {
        .chat => .chat,
        .terminal => .terminal,
        .browser => .browser,
    };
}

pub fn workspaceTerminalDockIdByPane(self: anytype, pane_id: WorkspacePaneId) ?u32 {
    if (self.project_controller.projects.items.len == 0) return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane = layout.paneById(pane_id) orelse return null;
    return switch (pane.ref) {
        .terminal => |ref| ref.dock_id,
        else => null,
    };
}

pub fn workspaceChatThreadIndexByPane(self: anytype, pane_id: WorkspacePaneId) ?usize {
    if (self.project_controller.projects.items.len == 0) return null;
    const project = &self.project_controller.projects.items[self.project_controller.selected_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return null;
    return switch (pane.ref) {
        .chat => |ref| if (ref.thread_index < project.threads.items.len) ref.thread_index else null,
        else => null,
    };
}

pub fn captureViewFocusSnapshot(self: anytype) ViewFocusSnapshot {
    return .{
        .selected_project_index = self.project_controller.selected_index,
        .terminal_focused = self.terminal_controller.focused,
        .composer_focused = self.composer_controller.focused,
        .palette_composer_focused = self.composer_controller.composer.focused,
        .browser_address_focused = self.browser_controller.address_focused,
    };
}

pub fn restoreViewFocusSnapshot(self: anytype, snapshot: ViewFocusSnapshot) void {
    if (snapshot.selected_project_index < self.project_controller.projects.items.len) {
        self.project_controller.selected_index = snapshot.selected_project_index;
    } else if (self.project_controller.projects.items.len > 0) {
        self.project_controller.selected_index = self.project_controller.projects.items.len - 1;
    } else {
        self.project_controller.selected_index = 0;
    }
    self.terminal_controller.focused = snapshot.terminal_focused;
    self.composer_controller.focused = snapshot.composer_focused;
    self.composer_controller.composer.focused = snapshot.palette_composer_focused;
    self.browser_controller.address_focused = snapshot.browser_address_focused;
    self.syncRenameBuffer();
    self.syncPaletteComposerFromDraft();
}

pub fn setWorkspaceChatPaneDraftForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, value: []const u8, append: bool) !bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const thread_index = switch (pane.ref) {
        .chat => |ref| ref.thread_index,
        else => return false,
    };
    if (thread_index >= project.threads.items.len) return false;
    var thread = &project.threads.items[thread_index];
    if (append) {
        const current = thread.currentDraft();
        var next: std.ArrayList(u8) = .empty;
        defer next.deinit(self.allocator);
        try next.ensureTotalCapacity(self.allocator, current.len + value.len);
        try next.appendSlice(self.allocator, current);
        try next.appendSlice(self.allocator, value);
        thread.setDraft(next.items);
    } else {
        thread.setDraft(value);
    }
    project.selected_thread_index = thread_index;
    if (self.project_controller.selected_index == project_index) {
        self.terminal_controller.focused = false;
        self.syncPaletteComposerFromDraft();
    }
    self.noteThreadDraftMutation(thread);
    return true;
}

pub fn setWorkspaceChatPaneDraft(self: anytype, pane_id: WorkspacePaneId, value: []const u8, append: bool) !bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.setWorkspaceChatPaneDraftForProject(self.project_controller.selected_index, pane_id, value, append);
}

pub fn sendWorkspaceChatPanePromptForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, prompt: ?[]const u8) !bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const thread_index = switch (pane.ref) {
        .chat => |ref| ref.thread_index,
        else => return false,
    };
    if (thread_index >= project.threads.items.len) return false;
    const thread = &project.threads.items[thread_index];
    if (prompt) |text| return try self.sendThreadPrompt(project.id, thread.local_thread_id, text, &.{});
    return try self.sendThreadDraft(project_index, thread_index);
}

pub fn sendWorkspaceChatPanePrompt(self: anytype, pane_id: WorkspacePaneId, prompt: ?[]const u8) !bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.sendWorkspaceChatPanePromptForProject(self.project_controller.selected_index, pane_id, prompt);
}

pub fn followupWorkspaceChatPanePromptForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, prompt: []const u8) !bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const thread_index = switch (pane.ref) {
        .chat => |ref| ref.thread_index,
        else => return false,
    };
    return self.storeThreadFollowupPrompt(project_index, thread_index, prompt);
}

pub fn followupWorkspaceChatPanePrompt(self: anytype, pane_id: WorkspacePaneId, prompt: []const u8) !bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.followupWorkspaceChatPanePromptForProject(self.project_controller.selected_index, pane_id, prompt);
}

pub fn stopWorkspaceChatPaneForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const thread_index = switch (pane.ref) {
        .chat => |ref| ref.thread_index,
        else => return false,
    };
    if (thread_index >= project.threads.items.len) return false;
    return self.abortThreadByLocalId(project.id, project.threads.items[thread_index].local_thread_id);
}

pub fn stopWorkspaceChatPane(self: anytype, pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.stopWorkspaceChatPaneForProject(self.project_controller.selected_index, pane_id);
}

pub fn approveWorkspaceChatPaneForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, decision: provider_types.ApprovalDecision) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const thread_index = switch (pane.ref) {
        .chat => |ref| ref.thread_index,
        else => return false,
    };
    if (thread_index >= project.threads.items.len) return false;
    return self.resolveThreadApprovalByLocalId(project.id, project.threads.items[thread_index].local_thread_id, decision);
}

pub fn approveWorkspaceChatPane(self: anytype, pane_id: WorkspacePaneId, decision: provider_types.ApprovalDecision) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.approveWorkspaceChatPaneForProject(self.project_controller.selected_index, pane_id, decision);
}

pub fn writeWorkspaceTerminalPaneForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, bytes: []const u8) !bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const dock_id = switch (pane.ref) {
        .terminal => |ref| ref.dock_id,
        else => return false,
    };
    const workspace_pane_visible = project.workspace_layout.hasTerminalDockPane(dock_id);
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
    if (!dock.hasRunningSession()) try self.restartTerminalDockForWorkspace(project_index, dock_id);
    const wrote = try dock.writeInputToActivePane(bytes);
    if (wrote and project_index == self.project_controller.selected_index and
        (dock.visible or workspace_pane_visible))
    {
        self.noteTerminalInputActivity();
    }
    return wrote;
}

pub fn writeWorkspaceTerminalPane(self: anytype, pane_id: WorkspacePaneId, bytes: []const u8) !bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.writeWorkspaceTerminalPaneForProject(self.project_controller.selected_index, pane_id, bytes);
}

/// Sends one atomic key chord directly to a workspace terminal pane without
/// changing desktop or workspace focus.
pub fn writeWorkspaceTerminalKeyForProject(
    self: anytype,
    project_index: usize,
    pane_id: WorkspacePaneId,
    chord: terminal.TerminalKeyChord,
) !bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const dock_id = switch (pane.ref) {
        .terminal => |ref| ref.dock_id,
        else => return false,
    };
    const workspace_pane_visible = project.workspace_layout.hasTerminalDockPane(dock_id);
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
    const wrote = try dock.writeKeyToActivePane(chord);
    if (wrote and project_index == self.project_controller.selected_index and
        (dock.visible or workspace_pane_visible))
    {
        self.noteTerminalInputActivity();
    }
    return wrote;
}

/// Pastes text into a terminal pane's running session (bracketed paste),
/// so agent TUIs receive it as filled-in input rather than executed lines.
/// Unlike the write path this never restarts a dead session: pasting a
/// prompt into a fresh shell would be wrong.
pub fn pasteWorkspaceTerminalPaneForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, text: []const u8) !bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const dock_id = switch (pane.ref) {
        .terminal => |ref| ref.dock_id,
        else => return false,
    };
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
    if (!dock.hasRunningSession()) return false;
    return try dock.pasteTextToActivePane(self.allocator, text);
}

pub fn terminalPaneOutputTailForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, max_bytes: usize) !?[]u8 {
    if (project_index >= self.project_controller.projects.items.len) return null;
    var project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return null;
    const dock_id = switch (pane.ref) {
        .terminal => |ref| ref.dock_id,
        else => return null,
    };
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return null;
    try self.pollTerminalDockBeforeRead(project_index, dock_id, dock);
    return try dock.activeOutputTailAlloc(self.allocator, max_bytes);
}

pub fn terminalPaneOutputTail(self: anytype, pane_id: WorkspacePaneId, max_bytes: usize) !?[]u8 {
    if (self.project_controller.projects.items.len == 0) return null;
    return self.terminalPaneOutputTailForProject(self.project_controller.selected_index, pane_id, max_bytes);
}

pub fn terminalPaneScreenTextForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId) !?[]u8 {
    if (project_index >= self.project_controller.projects.items.len) return null;
    var project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return null;
    const dock_id = switch (pane.ref) {
        .terminal => |ref| ref.dock_id,
        else => return null,
    };
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return null;
    try self.pollTerminalDockBeforeRead(project_index, dock_id, dock);
    return try dock.activeScreenTextAlloc(self.allocator);
}

pub fn terminalPaneRenderStateForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId) ?*const terminal.RenderState {
    if (project_index >= self.project_controller.projects.items.len) return null;
    const project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return null;
    const dock_id = switch (pane.ref) {
        .terminal => |ref| ref.dock_id,
        else => return null,
    };
    const dock = self.projectTerminalDock(project_index, dock_id) orelse return null;
    return dock.activeRenderState();
}

pub fn terminalPaneGridSizeForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId) ?struct { cols: u16, rows: u16 } {
    if (project_index >= self.project_controller.projects.items.len) return null;
    const project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return null;
    const dock_id = switch (pane.ref) {
        .terminal => |ref| ref.dock_id,
        else => return null,
    };
    const dock = self.projectTerminalDock(project_index, dock_id) orelse return null;
    const grid = dock.activeGridSize() orelse return null;
    return .{ .cols = grid.cols, .rows = grid.rows };
}

pub fn pollTerminalDockBeforeRead(self: anytype, project_index: usize, dock_id: u32, dock: *terminal.Dock) !void {
    const changed = try dock.poll(self.allocator);
    self.syncTerminalDockProcessLifecycle(project_index, dock_id, dock, null);
    try self.drainTerminalDockNotifications(project_index, dock_id, dock);
    if (changed and project_index == self.project_controller.selected_index) {
        const project = &self.project_controller.projects.items[project_index];
        if (dock.visible or project.workspace_layout.hasTerminalDockPane(dock_id)) {
            self.terminal_controller.last_activity_ms = @intCast(@divTrunc(platform_runtime.monotonicTimestampNs(), std.time.ns_per_ms));
        }
    }
}

pub fn pollWorkspaceTerminalProcessLifecycles(self: anytype, project_index: usize) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    self.pollPendingTerminalSessionTeardowns(project_index);
    var project = &self.project_controller.projects.items[project_index];
    self.pollTerminalDockBeforeRead(project_index, 0, &project.terminal_dock) catch |err| {
        log.warn("failed to poll base terminal lifecycle: {s}", .{@errorName(err)});
    };
    for (project.terminal_docks.items) |*entry| {
        self.pollTerminalDockBeforeRead(project_index, entry.id, &entry.dock) catch |err| {
            log.warn("failed to poll terminal lifecycle dock={d}: {s}", .{ entry.id, @errorName(err) });
        };
    }
}

pub fn terminalPaneScreenText(self: anytype, pane_id: WorkspacePaneId) !?[]u8 {
    if (self.project_controller.projects.items.len == 0) return null;
    return self.terminalPaneScreenTextForProject(self.project_controller.selected_index, pane_id);
}

pub fn syncTerminalDockProcessLifecycle(
    self: anytype,
    project_index: usize,
    dock_id: u32,
    dock: *terminal.Dock,
    pane_id_override: ?WorkspacePaneId,
) void {
    syncTerminalDockProcessLifecycleInner(self, project_index, dock_id, dock, pane_id_override, true);
}

pub fn syncTerminalDockProcessLifecycleAfterTeardownPoll(
    self: anytype,
    project_index: usize,
    dock_id: u32,
    dock: *terminal.Dock,
    pane_id_override: ?WorkspacePaneId,
) void {
    syncTerminalDockProcessLifecycleInner(self, project_index, dock_id, dock, pane_id_override, false);
}

fn syncTerminalDockProcessLifecycleInner(
    self: anytype,
    project_index: usize,
    dock_id: u32,
    dock: *terminal.Dock,
    pane_id_override: ?WorkspacePaneId,
    poll_pending_teardowns: bool,
) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const now_ms = unixTimestampMs();
    var project = &self.project_controller.projects.items[project_index];
    project.pruneTerminalProcessOutcomes(self.allocator, now_ms);

    if (!adoptTerminalSessionTeardowns(project, self.allocator, dock)) {
        log.warn("failed to retain pending terminal teardown ownership", .{});
    }
    if (poll_pending_teardowns) self.pollPendingTerminalSessionTeardowns(project_index);

    const lifecycle_snapshots = dock.sessionLifecycleSnapshotsAlloc(self.allocator) catch return;
    defer self.allocator.free(lifecycle_snapshots);
    const session_id = dock.activeSessionId();
    const runtime_process = dock.activeRuntimeProcessSnapshot();
    const session = dock.activeSessionSnapshot();
    if (session_id) |active_session_id| {
        if (runtime_process) |snapshot| {
            if (snapshot.running and project.managedProcessByDockId(dock_id) == null) {
                var label_buffer: [96]u8 = undefined;
                const command = dock.activeForegroundProcessName(&label_buffer) orelse dock.activeProcessLabel(&label_buffer);
                const identity = snapshot.process_group orelse snapshot.pid orelse 0;
                const surface = self.surfaceBySessionIdConst(active_session_id);
                const provider = if (surface) |owner_surface|
                    if (owner_surface.provider) |value| @tagName(value) else null
                else
                    null;
                const transition_finish: TerminalProcessFinish = if (session) |session_snapshot|
                    if (session_snapshot.confirmed_exit)
                        .{ .exit_code = session_snapshot.exit_code, .signal = session_snapshot.signal }
                    else
                        .{}
                else
                    .{};
                project.observeTerminalProcess(self.allocator, .{
                    .process_identity = identity,
                    .session_id = active_session_id,
                    .command = command,
                    .cwd = dock.cwd orelse project.path,
                    .pid = snapshot.pid,
                    .process_group = snapshot.process_group,
                    .started_at_ms = snapshot.started_at_ms,
                    .observed_at_ms = now_ms,
                    .dock_id = dock_id,
                    .pane_id = pane_id_override orelse workspacePaneIdForTerminalDock(project, dock_id),
                    .owner_kind = if (surface != null and surface.?.provider != null) "agent" else "terminal",
                    .owner_title = if (surface) |owner_surface| owner_surface.title else command,
                    .provider = provider,
                }, transition_finish) catch |err| {
                    log.warn("failed to track terminal process outcome: {s}", .{@errorName(err)});
                };
            }
        }

        const session_running = if (session) |snapshot| snapshot.running else false;
        const confirmed_exit = if (session) |snapshot| snapshot.confirmed_exit else false;
        if (confirmed_exit) {
            _ = project.finishTerminalProcess(self.allocator, active_session_id, .{
                .exit_code = if (session) |snapshot| snapshot.exit_code else null,
                .signal = if (session) |snapshot| snapshot.signal else null,
            }, now_ms) catch |err| {
                log.warn("failed to retain terminal process outcome: {s}", .{@errorName(err)});
            };
            if (!session_running) {
                _ = releaseLeasesForExactOwner(project, self.allocator, active_session_id, now_ms);
            }
        } else if (runtime_process == null or !runtime_process.?.running) {
            if (project.terminalProcessMissingReady(active_session_id, now_ms)) {
                _ = project.finishTerminalProcess(self.allocator, active_session_id, .{
                    .exit_code = null,
                    .signal = null,
                }, now_ms) catch |err| {
                    log.warn("failed to retain terminal process outcome: {s}", .{@errorName(err)});
                };
            }
        }
    }

    for (lifecycle_snapshots) |lifecycle| {
        if (session_id != null and std.mem.eql(u8, session_id.?, lifecycle.session_id)) continue;
        if (lifecycle.snapshot.running or !lifecycle.snapshot.confirmed_exit) continue;
        _ = project.finishTerminalProcess(self.allocator, lifecycle.session_id, .{
            .exit_code = lifecycle.snapshot.exit_code,
            .signal = lifecycle.snapshot.signal,
        }, now_ms) catch |err| {
            log.warn("failed to retain terminal process outcome: {s}", .{@errorName(err)});
        };
        _ = releaseLeasesForExactOwner(project, self.allocator, lifecycle.session_id, now_ms);
    }
}

pub fn pollPendingTerminalSessionTeardowns(self: anytype, project_index: usize) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    pollProjectTerminalSessionTeardowns(self, &self.project_controller.projects.items[project_index]);
}

pub fn pollArchivedTerminalSessionTeardowns(self: anytype) void {
    for (self.project_controller.archived_projects.items) |*project| {
        pollProjectTerminalSessionTeardowns(self, project);
    }
}

fn pollProjectTerminalSessionTeardowns(self: anytype, project: *Project) void {
    const now_ms = unixTimestampMs();
    var index: usize = 0;
    while (index < project.pending_terminal_teardowns.items.len) {
        var teardown = &project.pending_terminal_teardowns.items[index];
        const completion = teardown.poll(self.allocator) catch |err| {
            log.warn("failed to poll pending terminal teardown: {s}", .{@errorName(err)});
            index += 1;
            continue;
        } orelse {
            index += 1;
            continue;
        };
        if (teardown.sessionId()) |session_id| {
            _ = project.finishTerminalProcess(self.allocator, session_id, .{
                .exit_code = completion.exit_code,
                .signal = completion.signal,
                .cancellation_reason = completion.cancellation_reason,
            }, now_ms) catch |err| {
                log.warn("failed to retain terminal teardown outcome: {s}", .{@errorName(err)});
                index += 1;
                continue;
            };
            _ = releaseLeasesForExactOwner(project, self.allocator, session_id, now_ms);
        }
        var removed = project.pending_terminal_teardowns.orderedRemove(index);
        removed.deinit(self.allocator);
    }
}

pub fn finishTerminalSessionsForTeardown(
    self: anytype,
    project_index: usize,
    dock: *terminal.Dock,
    reason: terminal.SessionTeardownReason,
) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    dock.queueAllSessionTeardowns(self.allocator, reason) catch |err| {
        log.warn("failed to queue terminal teardown ownership: {s}", .{@errorName(err)});
        return false;
    };
    const project = &self.project_controller.projects.items[project_index];
    if (!adoptTerminalSessionTeardowns(project, self.allocator, dock)) {
        log.warn("failed to retain queued terminal teardown ownership", .{});
        return false;
    }
    return true;
}

pub fn prepareProjectTerminalSessionsForTeardown(
    self: anytype,
    project_index: usize,
    reason: terminal.SessionTeardownReason,
) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    {
        const dock = &self.project_controller.projects.items[project_index].terminal_dock;
        self.syncTerminalDockProcessLifecycle(project_index, 0, dock, null);
        if (!self.finishTerminalSessionsForTeardown(project_index, dock, reason)) return false;
    }

    var dock_index: usize = 0;
    while (dock_index < self.project_controller.projects.items[project_index].terminal_docks.items.len) : (dock_index += 1) {
        const entry = &self.project_controller.projects.items[project_index].terminal_docks.items[dock_index];
        self.syncTerminalDockProcessLifecycle(project_index, entry.id, &entry.dock, null);
        if (!self.finishTerminalSessionsForTeardown(project_index, &entry.dock, reason)) return false;
    }

    for (self.project_controller.projects.items[project_index].managed_processes.items) |*process| {
        process.status = .stopped;
        process.explicit_stop = true;
        process.next_restart_ms = 0;
        process.pending_watch_restart_ms = 0;
    }
    return true;
}

fn adoptTerminalSessionTeardowns(project: *Project, allocator: std.mem.Allocator, dock: *terminal.Dock) bool {
    project.pending_terminal_teardowns.ensureUnusedCapacity(allocator, dock.pendingSessionTeardownCount()) catch return false;
    while (dock.takeSessionTeardown()) |teardown| {
        project.pending_terminal_teardowns.appendAssumeCapacity(teardown);
    }
    return true;
}

fn workspacePaneIdForTerminalDock(project: *const Project, dock_id: u32) ?WorkspacePaneId {
    for (project.workspace_layout.panes.items) |pane| {
        switch (pane.ref) {
            .terminal => |ref| if (ref.dock_id == dock_id) return pane.id,
            else => {},
        }
    }
    return null;
}

/// Removes expired workspace leases before reads and mutations.
pub fn pruneExpiredWorkspaceLeases(self: anytype, project_index: usize) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    pruneExpiredLeases(&self.project_controller.projects.items[project_index], self.allocator, unixTimestampMs());
}

pub fn acquireWorkspaceLease(
    self: anytype,
    project_index: usize,
    owner: []const u8,
    command: []const u8,
    resources: []const []const u8,
    ttl_ms: i64,
    force: bool,
) !*WorkspaceLease {
    if (project_index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
    return acquireLease(&self.project_controller.projects.items[project_index], self.allocator, owner, command, resources, ttl_ms, force, unixTimestampMs());
}

pub fn releaseWorkspaceLease(self: anytype, project_index: usize, owner: []const u8, lease_id: ?[]const u8) usize {
    if (project_index >= self.project_controller.projects.items.len) return 0;
    return releaseLease(&self.project_controller.projects.items[project_index], self.allocator, owner, lease_id, unixTimestampMs());
}

pub fn releaseWorkspaceLeasesForTerminalOwner(self: anytype, project_index: usize, owner: []const u8) usize {
    if (project_index >= self.project_controller.projects.items.len) return 0;
    return releaseLeasesForExactOwner(&self.project_controller.projects.items[project_index], self.allocator, owner, unixTimestampMs());
}

pub fn activeWorkspaceLeaseCount(self: anytype, project_index: usize) usize {
    self.pruneExpiredWorkspaceLeases(project_index);
    if (project_index >= self.project_controller.projects.items.len) return 0;
    return self.project_controller.projects.items[project_index].workspace_leases.items.len;
}

pub fn selectWorkspaceChatPaneThread(self: anytype, pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var project = &self.project_controller.projects.items[self.project_controller.selected_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const thread_index = switch (pane.ref) {
        .chat => |ref| ref.thread_index,
        else => return false,
    };
    if (thread_index >= project.threads.items.len) return false;
    project.selected_thread_index = thread_index;
    project.workspace_layout.focused_pane_id = pane_id;
    _ = self.clearChatCompletion(self.project_controller.selected_index, thread_index);
    self.terminal_controller.focused = false;
    self.unfocusBrowserPane();
    self.browser_controller.address_focused = false;
    self.syncPaletteComposerFromDraft();
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn isCurrentProjectWorkspacePaneFocused(self: anytype, pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.focused_pane_id == pane_id;
}

pub fn isCurrentProjectWorkspacePaneMaximized(self: anytype, pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.maximized_pane_id == pane_id;
}

pub fn focusWorkspacePane(self: anytype, project_index: usize, pane_id: WorkspacePaneId) bool {
    return focusWorkspacePaneWithCompletionPolicy(self, project_index, pane_id, true);
}

pub fn restoreWorkspacePaneFocus(self: anytype, project_index: usize, pane_id: WorkspacePaneId) bool {
    return focusWorkspacePaneWithCompletionPolicy(self, project_index, pane_id, false);
}

fn focusWorkspacePaneWithCompletionPolicy(
    self: anytype,
    project_index: usize,
    pane_id: WorkspacePaneId,
    acknowledge_completion: bool,
) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    if (layout.paneById(pane_id) == null) return false;
    const pane_focus_changed = layout.focused_pane_id != pane_id;
    const scroll_group_focus_changed = layout.rememberScrollGroupFocusedPane(pane_id);
    const pane = layout.paneById(pane_id).?;
    // Ordinary focus movement uses the strip's minimal-reveal behavior. A
    // direct navigation path may request leading-edge placement after this
    // method completes.
    layout.scroll_leading_pane_id = null;
    // Composer popovers belong to the live composer pane; leaving them
    // open on a pane that no longer renders them would silently keep
    // eating clicks through the popover routing.
    self.closePaletteModelPicker();
    self.closePaletteDirectoryPicker();
    self.closePaletteRuntimePicker();
    self.closeRunConfigPopover();
    var persisted_focus_changed = pane_focus_changed or scroll_group_focus_changed;
    layout.focused_pane_id = pane_id;
    switch (pane.ref) {
        .chat => |ref| {
            var project = &self.project_controller.projects.items[project_index];
            const thread_focus_changed = project.selected_thread_index != ref.thread_index;
            if (ref.thread_index < project.threads.items.len) {
                persisted_focus_changed = persisted_focus_changed or project.selected_thread_index != ref.thread_index;
                project.selected_thread_index = ref.thread_index;
                if (acknowledge_completion) _ = self.clearChatCompletion(project_index, ref.thread_index);
            }
            project.last_content_pane_id = pane_id;
            if (self.project_controller.selected_index == project_index) {
                if (thread_focus_changed) self.noteTranscriptSelectionChanged();
                self.syncPaletteComposerFromDraft();
                if (acknowledge_completion) {
                    self.requestComposerFocus();
                } else {
                    self.restoreComposerFocus();
                }
                if (pane_focus_changed or thread_focus_changed) {
                    self.prepareTranscriptPaneFocus(project_index, pane_id);
                }
            }
        },
        .terminal => |ref| {
            self.project_controller.projects.items[project_index].last_content_pane_id = pane_id;
            if (self.project_controller.selected_index == project_index) {
                if (acknowledge_completion) {
                    self.requestTerminalDockFocus(ref.dock_id);
                } else {
                    self.restoreTerminalDockFocus(ref.dock_id);
                }
            }
        },
        .browser => {
            if (self.project_controller.selected_index == project_index) {
                if (acknowledge_completion) {
                    self.focusBrowserPaneInWorkspace(project_index, pane_id);
                } else {
                    self.restoreBrowserPaneFocus(project_index, pane_id);
                }
            }
        },
    }
    if (acknowledge_completion and persisted_focus_changed) self.markWorkspaceDirty(project_index);
    return true;
}

pub fn focusCurrentProjectWorkspacePane(self: anytype, pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.focusWorkspacePane(self.project_controller.selected_index, pane_id);
}

pub fn focusPromptForFocusedChatWorkspacePane(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var project = &self.project_controller.projects.items[self.project_controller.selected_index];
    const pane_id = project.workspace_layout.focused_pane_id orelse return false;
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const thread_index = switch (pane.ref) {
        .chat => |ref| ref.thread_index,
        else => return false,
    };
    if (thread_index >= project.threads.items.len) return false;
    project.selected_thread_index = thread_index;
    _ = self.clearChatCompletion(self.project_controller.selected_index, thread_index);
    self.syncPaletteComposerFromDraft();
    self.composer_controller.composer.focused = true;
    self.composer_controller.focused = true;
    self.terminal_controller.focused = false;
    self.unfocusBrowserPane();
    self.browser_controller.address_focused = false;
    self.ensurePaletteComposerCursorVisible();
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn swapCurrentProjectWorkspacePanes(self: anytype, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    if (!layout.swapPaneRefs(first_pane_id, second_pane_id)) return false;
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn moveWorkspacePaneInSidebarOrder(
    self: anytype,
    project_index: usize,
    pane_id: WorkspacePaneId,
    before_index: usize,
) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    if (!layout.movePaneBefore(pane_id, before_index)) return false;
    self.markWorkspaceDirty(project_index);
    return true;
}

pub fn moveWorkspacePaneInDirection(
    self: anytype,
    project_index: usize,
    pane_id: WorkspacePaneId,
    direction: WorkspacePaneDirection,
) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const neighbor_id = layout.neighborPaneId(pane_id, direction) orelse return false;
    if (!layout.swapPaneRefs(pane_id, neighbor_id)) return false;
    layout.focused_pane_id = neighbor_id;
    if (self.project_controller.selected_index == project_index) {
        _ = self.focusCurrentProjectWorkspacePane(neighbor_id);
    } else {
        self.markWorkspaceDirty(project_index);
    }
    return true;
}

pub fn moveCurrentProjectWorkspacePaneToPlacement(
    self: anytype,
    source_pane_id: WorkspacePaneId,
    target_pane_id: WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    new_after: bool,
) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    if (source_pane_id == target_pane_id) return false;

    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    _ = layout.paneById(source_pane_id) orelse return false;
    _ = layout.paneById(target_pane_id) orelse return false;

    // Collapse the source's old split before reusing its pane id at the
    // drop target.
    if (layout.root) |root_node| {
        layout.root = WorkspaceLayout.removePaneFromTree(self.allocator, root_node, source_pane_id);
    }

    layout.splitPaneWithLeaf(self.allocator, target_pane_id, source_pane_id, axis, new_after) catch |err| {
        log.err("failed to move workspace pane: {s}", .{@errorName(err)});
        layout.ensurePaneInRootSplit(self.allocator, source_pane_id, axis, 0.5) catch {};
        self.setSidebarNotice("Failed to move workspace pane.");
        self.markWorkspaceDirty(self.project_controller.selected_index);
        return false;
    };
    layout.maximized_pane_id = null;
    _ = self.focusCurrentProjectWorkspacePane(source_pane_id);
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn toggleCurrentProjectWorkspacePaneMaximized(self: anytype, pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.toggleWorkspacePaneMaximized(self.project_controller.selected_index, pane_id);
}

pub fn toggleWorkspacePaneMaximized(self: anytype, project_index: usize, pane_id: WorkspacePaneId) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const pane = layout.paneById(pane_id) orelse return false;
    runtime_log.trace("pane maximize toggle begin project={d} pane={d} kind={s} currently_maximized={any}", .{
        project_index,
        pane_id,
        @tagName(pane.ref),
        layout.maximized_pane_id,
    });
    layout.maximized_pane_id = if (layout.maximized_pane_id == pane_id) null else pane_id;
    layout.focused_pane_id = pane_id;
    _ = self.focusWorkspacePane(project_index, pane_id);
    self.markWorkspaceDirty(project_index);
    runtime_log.trace("pane maximize toggle done project={d} pane={d} maximized={any}", .{
        project_index,
        pane_id,
        layout.maximized_pane_id,
    });
    return true;
}

pub fn maximizeWorkspacePane(self: anytype, project_index: usize, pane_id: WorkspacePaneId) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const layout = &self.project_controller.projects.items[project_index].workspace_layout;
    if (layout.maximized_pane_id == pane_id) return true;
    return self.toggleWorkspacePaneMaximized(project_index, pane_id);
}

pub fn clearCurrentProjectWorkspacePaneMaximized(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.clearWorkspacePaneMaximized(self.project_controller.selected_index);
}

pub fn clearWorkspacePaneMaximized(self: anytype, project_index: usize) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    if (layout.maximized_pane_id == null) return false;
    layout.maximized_pane_id = null;
    self.markWorkspaceDirty(project_index);
    return true;
}

pub fn closeCurrentProjectWorkspacePane(self: anytype, pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.closeWorkspacePane(self.project_controller.selected_index, pane_id);
}

fn shouldTearDownClosedTerminalDock(has_remaining_pane: bool, preserve_agent_history: bool) bool {
    return !has_remaining_pane and !preserve_agent_history;
}

pub fn closeWorkspacePane(self: anytype, project_index: usize, pane_id: WorkspacePaneId) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    var layout = &project.workspace_layout;
    var removed_ref = layout.closePane(self.allocator, pane_id) orelse return false;
    defer deinitWorkspacePaneRef(&removed_ref, self.allocator);
    switch (removed_ref) {
        .chat => |ref| {
            // Item 5b: the thread follows its last pane out of the open set.
            const closed = self.closeThreadAfterPaneClose(project_index, ref.thread_index);
            self.setSidebarNotice(if (closed) "Chat closed. Find it again in the command palette." else "Chat pane closed.");
        },
        .terminal => |ref| {
            const preserve_agent_history = self.workspaceAgentTuiHistoryAt(project_index, ref.dock_id) != 0;
            // Saved agent TUIs stay attached to their daemon session while
            // hidden. Reopening History must reattach the same conversation,
            // not a blank shell after a pane-close teardown.
            if (shouldTearDownClosedTerminalDock(layout.hasTerminalDockPane(ref.dock_id), preserve_agent_history)) {
                if (ref.dock_id == 0) {
                    self.syncTerminalDockProcessLifecycle(project_index, ref.dock_id, &project.terminal_dock, pane_id);
                    _ = self.finishTerminalSessionsForTeardown(project_index, &project.terminal_dock, .pane_closed);
                    project.terminal_dock.visible = false;
                } else if (project.terminalDockEntryById(ref.dock_id)) |entry| {
                    self.syncTerminalDockProcessLifecycle(project_index, ref.dock_id, &entry.dock, pane_id);
                    const teardown_owned = self.finishTerminalSessionsForTeardown(project_index, &entry.dock, .pane_closed);
                    if (!preserve_agent_history and teardown_owned) _ = project.removeTerminalDockById(self.allocator, ref.dock_id);
                }
            }
            if (preserve_agent_history) {
                if (project.managedProcessByDockId(ref.dock_id)) |process| process.pane_id = null;
                if (self.projectTerminalDock(project_index, ref.dock_id)) |dock| {
                    if (dock.activeSessionId()) |session_id| {
                        if (self.surfaceBySessionId(session_id)) |surface| surface.pane_id = null;
                    }
                }
            }
            if (self.project_controller.selected_index == project_index and !layout.hasVisiblePaneKind(.terminal)) self.terminal_controller.focused = false;
            self.setSidebarNotice(if (preserve_agent_history) "Agent TUI closed. Reopen it from History." else "Terminal pane closed.");
        },
        .browser => {
            self.reconcileBrowserRuntimeAfterPaneRemoval(project_index, pane_id);
            self.setSidebarNotice("Browser pane closed.");
        },
    }
    self.clearHerdrClosedPaneMetadata(project_index, pane_id, removed_ref);
    if (layout.root == null) {
        if (layout.firstVisiblePaneId()) |next_id| {
            layout.replaceRootWithLeaf(self.allocator, next_id) catch {
                layout.focused_pane_id = next_id;
            };
        }
    }
    if (self.project_controller.selected_index == project_index) {
        if (layout.focused_pane_id) |focused_pane_id| {
            _ = self.focusWorkspacePane(project_index, focused_pane_id);
        } else {
            self.terminal_controller.focused = false;
            self.composer_controller.focused = false;
            self.composer_controller.composer.focused = false;
            self.unfocusBrowserPane();
            self.browser_controller.address_focused = false;
        }
    }
    self.markWorkspaceDirty(project_index);
    return true;
}

pub fn clearHerdrClosedPaneMetadata(self: anytype, project_index: usize, pane_id: WorkspacePaneId, removed_ref: WorkspacePaneRef) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    var project = &self.project_controller.projects.items[project_index];
    if (project.herdr_link) |*link| {
        var changed = link.removePaneLinkForVerdePane(self.allocator, pane_id);
        if (link.attach_pane_id) |attach_pane_id| {
            if (attach_pane_id == pane_id) {
                link.attach_pane_id = null;
                link.attach_dock_id = null;
                changed = true;
            }
        }
        switch (removed_ref) {
            .terminal => |ref| {
                if (link.attach_dock_id) |attach_dock_id| {
                    if (attach_dock_id == ref.dock_id and !project.workspace_layout.hasTerminalDockPane(ref.dock_id)) {
                        link.attach_dock_id = null;
                        link.attach_pane_id = null;
                        changed = true;
                    }
                }
            },
            else => {},
        }
        if (changed) link.updated_at_ms = unixTimestampMs();
    }
}

/// Close the focused pane. A second press on an empty workspace archives that
/// workspace, matching tmux/herdr prefix-x.
pub fn closeFocusedWorkspacePane(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const project_index = self.project_controller.selected_index;
    const layout = &self.project_controller.projects.items[project_index].workspace_layout;
    if (layout.focused_pane_id) |pane_id| {
        if (self.closeCurrentProjectWorkspacePane(pane_id)) return true;
    }
    if (layout.visiblePaneCount() != 0) return false;
    return self.closeProjectAtIndexResult(project_index);
}

pub fn splitCurrentProjectWorkspacePaneWithChat(self: anytype, pane_id: WorkspacePaneId) bool {
    return self.splitCurrentProjectWorkspacePaneWithChatAxis(pane_id, .vertical);
}

pub fn splitFocusedWorkspacePaneWithChatAxis(self: anytype, axis: WorkspaceSplitAxis) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const pane_id = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.focused_pane_id orelse return false;
    return self.splitCurrentProjectWorkspacePaneWithChatAxis(pane_id, axis);
}

pub fn splitCurrentProjectWorkspacePaneWithChatAxis(self: anytype, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
    return self.splitCurrentProjectWorkspacePaneWithChatPlacement(pane_id, axis, true);
}

pub fn splitCurrentProjectWorkspacePaneWithChatPlacement(self: anytype, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.splitWorkspacePaneWithChatPlacement(self.project_controller.selected_index, pane_id, axis, new_after);
}

/// Split a chat pane and keep it inside the target scrolling tile.
pub fn splitCurrentProjectWorkspacePaneTiledWithChatPlacement(
    self: anytype,
    pane_id: WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    new_after: bool,
) bool {
    if (!self.splitCurrentProjectWorkspacePaneWithChatPlacement(pane_id, axis, new_after)) return false;
    return joinCurrentProjectCreatedPaneToScrollGroup(self, pane_id);
}

pub fn splitFocusedWorkspacePaneTiledWithChatPlacement(self: anytype, axis: WorkspaceSplitAxis, new_after: bool) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const pane_id = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.focused_pane_id orelse return false;
    return self.splitCurrentProjectWorkspacePaneTiledWithChatPlacement(pane_id, axis, new_after);
}

pub fn splitWorkspacePaneWithChatAxis(self: anytype, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
    return self.splitWorkspacePaneWithChatPlacement(project_index, pane_id, axis, true);
}

pub fn openWorkspaceChat(
    self: anytype,
    project_index: usize,
    request: OpenChatRequest,
) !OpenChatResult {
    if (project_index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
    if (request.model_ref) |requested_model| {
        if (!self.providerSupportsModel(request.provider, requested_model)) return error.InvalidModel;
    }
    const selected_model = request.model_ref orelse composerDefaultModelRef(self, request.provider);
    const settings = try self.resolveChatCreationSettings(request, selected_model);
    const result = try createWorkspaceChatPane(
        &self.project_controller.projects.items[project_index],
        self.allocator,
        request.provider,
        selected_model,
        settings,
        request.target_pane_id,
        request.axis,
        request.focus,
    );
    if (request.focus) {
        self.project_controller.selected_index = project_index;
        self.requestComposerFocus();
        self.syncPaletteComposerFromDraft();
        self.syncRenameBuffer();
    }
    self.setSidebarNotice("New chat pane ready.");
    self.markDirty();
    return result;
}

/// Present a daemon-projected thread without creating or replacing its identity.
pub fn presentWorkspaceChat(self: anytype, project_index: usize, request: PresentChatRequest) !OpenChatResult {
    if (project_index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
    var project = &self.project_controller.projects.items[project_index];
    const thread_index = for (project.threads.items, 0..) |thread, index| {
        if (std.mem.eql(u8, thread.local_thread_id, request.local_thread_id)) break index;
    } else return error.ProjectionPending;

    for (project.workspace_layout.panes.items) |pane| switch (pane.ref) {
        .chat => |chat_ref| if (chat_ref.thread_index == thread_index) {
            if (request.focus) {
                project.workspace_layout.focusCreatedPane(pane.id);
                project.selected_thread_index = thread_index;
                project.last_content_pane_id = pane.id;
                self.project_controller.selected_index = project_index;
                self.requestComposerFocus();
                self.syncPaletteComposerFromDraft();
                self.syncRenameBuffer();
                self.markDirty();
            }
            return .{ .pane_id = pane.id, .thread_index = thread_index, .focused = request.focus, .presentation_existing = true };
        },
        else => {},
    };

    const result = try createWorkspaceChatPaneForThread(
        project,
        self.allocator,
        thread_index,
        request.target_pane_id,
        request.axis,
        request.focus,
    );
    if (request.focus) {
        self.project_controller.selected_index = project_index;
        self.requestComposerFocus();
        self.syncPaletteComposerFromDraft();
        self.syncRenameBuffer();
    }
    self.setSidebarNotice("Chat pane ready.");
    self.markDirty();
    return result;
}

pub const OpenSubagentRequest = struct {
    parent_local_thread_id: []const u8,
    tool_call_id: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
    message_index: ?usize = null,
    target_pane_id: ?WorkspacePaneId = null,
    axis: WorkspaceSplitAxis = .vertical,
    focus: bool = true,
};

const SubagentSource = struct {
    identity: []u8,
    title: []u8,
    prompt: []u8,
    result: []u8,
    /// Child activity as JSON lines (see `ToolCallUpdate.transcript`).
    transcript: []u8,
    /// Live partial text of the block the child is still writing; absent for
    /// durable rows, which only carry completed blocks.
    partial: []u8,
    status: ?provider_types.ToolCallStatus,

    fn deinit(self: SubagentSource, allocator: std.mem.Allocator) void {
        allocator.free(self.identity);
        allocator.free(self.title);
        allocator.free(self.prompt);
        allocator.free(self.result);
        allocator.free(self.transcript);
        allocator.free(self.partial);
    }

    /// Identifies the parent state these rows came from.
    fn signature(self: SubagentSource) u64 {
        var hasher = std.hash.Wyhash.init(0x5B4A6E7);
        hasher.update(self.prompt);
        hasher.update("\x00");
        hasher.update(self.transcript);
        hasher.update("\x00");
        hasher.update(self.partial);
        hasher.update("\x00");
        hasher.update(self.result);
        hasher.update("\x00");
        hasher.update(@tagName(self.status orelse .unknown));
        return hasher.final();
    }
};

const SUBAGENT_VIEW_INTRO = "Read-only view of a child agent. This is not an independent Verde chat.";

pub fn openSubagentFromParentMessage(
    self: anytype,
    project_index: usize,
    parent_thread_index: usize,
    message_index: usize,
) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const project = &self.project_controller.projects.items[project_index];
    if (parent_thread_index >= project.threads.items.len) return;
    _ = openSubagent(self, project_index, .{
        .parent_local_thread_id = project.threads.items[parent_thread_index].local_thread_id,
        .message_index = message_index,
        .axis = .vertical,
        .focus = true,
    }) catch |err| {
        log.warn("failed to open subagent chat pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Could not open that subagent.");
        self.markDirty();
        return;
    };
}

pub fn openSubagent(self: anytype, project_index: usize, request: OpenSubagentRequest) !OpenChatResult {
    if (project_index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
    var project = &self.project_controller.projects.items[project_index];
    const parent_index = for (project.threads.items, 0..) |thread, index| {
        if (std.mem.eql(u8, thread.local_thread_id, request.parent_local_thread_id)) break index;
    } else return error.ParentThreadNotFound;

    const source = try captureSubagentSource(self.allocator, &project.threads.items[parent_index], request);
    defer source.deinit(self.allocator);

    const child_index = try project.ensureSubagentThread(
        self.allocator,
        &project.threads.items[parent_index],
        source.identity,
        source.title,
    );
    project = &self.project_controller.projects.items[project_index];
    try applySubagentSource(self.allocator, &project.threads.items[child_index], source);

    return try presentSubagentThread(self, project_index, child_index, request.target_pane_id, request.axis, request.focus);
}

/// Refreshes every open child pane of `parent_thread_index` from the parent's
/// current subagent rows, so a running child's streamed activity and its
/// eventual result appear without reopening the pane.
pub fn syncSubagentViews(self: anytype, project_index: usize, parent_thread_index: usize) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const project = &self.project_controller.projects.items[project_index];
    if (parent_thread_index >= project.threads.items.len) return;
    const parent_local_id = project.threads.items[parent_thread_index].local_thread_id;
    for (project.threads.items, 0..) |thread, child_index| {
        const parent_id = chat_types.subagentParentLocalId(thread.local_thread_id) orelse continue;
        if (!std.mem.eql(u8, parent_id, parent_local_id)) continue;
        syncSubagentView(self, project, parent_thread_index, child_index) catch |err| {
            log.warn("failed to refresh subagent pane: {s}", .{@errorName(err)});
        };
        // A child pane can host a nested agent card of its own, so its
        // grandchild panes rebuild from the rows we just refreshed. Minted
        // parent ids grow with each level, so this recursion cannot cycle.
        syncSubagentViews(self, project_index, child_index);
    }
}

fn syncSubagentView(self: anytype, project: *project_state.Project, parent_index: usize, child_index: usize) !void {
    const parent = &project.threads.items[parent_index];
    const child = &project.threads.items[child_index];
    const source = (try findSubagentSourceForChild(self.allocator, parent, child.local_thread_id)) orelse return;
    defer source.deinit(self.allocator);
    if (child.subagent_view_signature == source.signature()) return;
    try applySubagentSource(self.allocator, child, source);
    self.markDirty();
}

fn applySubagentSource(allocator: std.mem.Allocator, child: *ChatThread, source: SubagentSource) !void {
    var rows = try buildSubagentViewRows(allocator, source);
    defer utils.freePendingTimelineEvents(allocator, &rows);
    try child.replaceSubagentViewRows(allocator, source.title, rows.items, source.signature());
}

/// Locates the parent row that minted `child_local_id`. Returns null when the
/// send worker holds the pending stream this frame; the next poll retries.
fn findSubagentSourceForChild(allocator: std.mem.Allocator, parent: *ChatThread, child_local_id: []const u8) !?SubagentSource {
    for (parent.messages.items, 0..) |message, index| {
        if (!chat_types.looksLikeSubagentCard(message.author, message.tool_call_kind, message.body)) continue;
        var identity_buf: [32]u8 = undefined;
        const identity = subagentIdentity(&identity_buf, message.tool_call_id, message.body, index);
        if (!try subagentIdentityMatches(allocator, parent.local_thread_id, identity, child_local_id)) continue;
        return try buildSubagentSource(allocator, identity, message.body, message.tool_call_status, null);
    }
    if (!parent.send_state.mutex.tryLock()) return null;
    defer parent.send_state.mutex.unlock();
    for (parent.send_state.pending_events.items, 0..) |event, pending_index| {
        if (!chat_types.looksLikeSubagentCard(event.author, event.tool_call_kind, event.body)) continue;
        var identity_buf: [32]u8 = undefined;
        const identity = subagentIdentity(&identity_buf, event.tool_call_id, event.body, parent.messages.items.len + pending_index);
        if (!try subagentIdentityMatches(allocator, parent.local_thread_id, identity, child_local_id)) continue;
        return try buildSubagentSource(allocator, identity, event.body, event.tool_call_status, event.tool_call_transcript_partial);
    }
    return null;
}

fn subagentIdentityMatches(allocator: std.mem.Allocator, parent_local_id: []const u8, identity: []const u8, child_local_id: []const u8) !bool {
    const minted = try chat_types.mintSubagentLocalThreadId(allocator, parent_local_id, identity);
    defer allocator.free(minted);
    return std.mem.eql(u8, minted, child_local_id);
}

/// The task prompt is lifted verbatim from the call's input JSON, so it still
/// carries `\n`/`\"` escapes; decode them for the "You" bubble. Text that is
/// not a valid JSON string body is kept as is.
fn unescapeJsonStringAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return allocator.dupe(u8, raw);
    const quoted = try std.mem.concat(allocator, u8, &.{ "\"", raw, "\"" });
    defer allocator.free(quoted);
    const parsed = std.json.parseFromSlice([]const u8, allocator, quoted, .{}) catch return allocator.dupe(u8, raw);
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.value);
}

/// Child pane rows: intro, task prompt, the child's streamed activity
/// (assistant text plus tool cards), then its result or a status note.
fn buildSubagentViewRows(allocator: std.mem.Allocator, source: SubagentSource) !std.ArrayListUnmanaged(PendingTimelineEvent) {
    var rows: std.ArrayListUnmanaged(PendingTimelineEvent) = .empty;
    errdefer utils.freePendingTimelineEvents(allocator, &rows);
    try appendSubagentTextRow(allocator, &rows, .system, "System", SUBAGENT_VIEW_INTRO);
    try appendSubagentTextRow(allocator, &rows, .user, "You", source.prompt);
    var lines = std.mem.splitScalar(u8, source.transcript, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0) continue;
        appendSubagentTranscriptEntry(allocator, &rows, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A malformed line loses one entry, not the whole pane.
            else => continue,
        };
    }
    // The block the child is still writing has no transcript entry yet; show
    // it as the trailing bubble it will become once the entry lands.
    if (std.mem.trim(u8, source.partial, " \n\r\t").len > 0) {
        try appendSubagentChildText(allocator, &rows, source.partial);
    }
    const result = std.mem.trim(u8, source.result, " \n\r\t");
    if (result.len > 0) {
        // Claude's hand-back repeats the child's last reply (indented, with a
        // usage trailer); the streamed bubble already shows it.
        if (!subagentResultRepeatsLastText(rows.items, result)) {
            try appendSubagentTextRow(allocator, &rows, .assistant, "Child agent", result);
        }
    } else {
        try appendSubagentTextRow(allocator, &rows, .system, "Child agent", subagentStatusFallback(source.status));
    }
    return rows;
}

fn subagentResultRepeatsLastText(rows: []const PendingTimelineEvent, result: []const u8) bool {
    if (rows.len == 0) return false;
    const last = rows[rows.len - 1];
    if (last.role != .assistant or last.tool_call_id != null) return false;
    var lines = std.mem.splitScalar(u8, last.body, '\n');
    const first_line = std.mem.trim(u8, lines.first(), " \r\t");
    if (first_line.len < 16) return std.mem.eql(u8, std.mem.trim(u8, last.body, " \n\r\t"), result);
    return std.mem.indexOf(u8, result, first_line) != null;
}

fn appendSubagentTextRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(PendingTimelineEvent),
    role: provider_models.ChatRole,
    author: []const u8,
    body: []const u8,
) !void {
    const owned_author = try allocator.dupe(u8, author);
    errdefer allocator.free(owned_author);
    const owned_body = try allocator.dupe(u8, body);
    errdefer allocator.free(owned_body);
    try rows.append(allocator, .{ .role = role, .author = owned_author, .body = owned_body });
}

fn appendSubagentTranscriptEntry(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(PendingTimelineEvent),
    line: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTranscriptEntry;
    const object = parsed.value.object;
    const entry_type = jsonObjectStringField(object, "type") orelse return error.InvalidTranscriptEntry;
    // A nested agent's work belongs inside the card that launched it, not in
    // this pane's timeline: file it as that card's own transcript so the card
    // drills down exactly like the one this pane was opened from.
    if (jsonObjectStringField(object, "parent")) |nested_call_id| {
        if (nested_call_id.len > 0) {
            const nested_line = try nestedTranscriptLineAlloc(allocator, object);
            defer allocator.free(nested_line);
            try utils.upsertPendingToolCallEvent(allocator, rows, .{
                .call_id = nested_call_id,
                .title = "",
                // Only an agent's own Task call is ever tagged as a parent, so
                // a level deeper than this pane knows still lands on a card
                // that reads (and drills down) as the agent it came from.
                .kind = .subagent,
                .transcript = nested_line,
            });
            return;
        }
    }
    if (std.mem.eql(u8, entry_type, "text")) {
        const text = jsonObjectStringField(object, "text") orelse return;
        try appendSubagentChildText(allocator, rows, text);
        return;
    }
    if (std.mem.eql(u8, entry_type, "thinking")) {
        const text = jsonObjectStringField(object, "text") orelse return;
        if (std.mem.trim(u8, text, " \n\r\t").len == 0) return;
        // No provider surfaces parent reasoning as a row today, so the child's
        // gets the quiet tool-card treatment the panel gives "Thinking".
        try appendSubagentTextRow(allocator, rows, .system, "Thinking", text);
        return;
    }
    const call_id = jsonObjectStringField(object, "id") orelse return error.InvalidTranscriptEntry;
    if (std.mem.eql(u8, entry_type, "tool_use")) {
        const kind_text = jsonObjectStringField(object, "kind");
        try utils.upsertPendingToolCallEvent(allocator, rows, .{
            .call_id = call_id,
            .title = jsonObjectStringField(object, "title") orelse "",
            .kind = if (kind_text) |value| std.meta.stringToEnum(provider_types.ToolCallKind, value) else null,
            .status = .in_progress,
            .input = jsonObjectStringField(object, "input"),
        });
        return;
    }
    if (std.mem.eql(u8, entry_type, "tool_result")) {
        const failed = if (object.get("is_error")) |value| value == .bool and value.bool else false;
        const output = jsonObjectStringField(object, "output");
        try utils.upsertPendingToolCallEvent(allocator, rows, .{
            .call_id = call_id,
            .title = "",
            .status = if (failed) .failed else .completed,
            .output = if (failed) null else output,
            .error_text = if (failed) output else null,
        });
    }
}

/// Appends child assistant text, merging into the trailing bubble so
/// consecutive chunks (and the partial that precedes them) read as one reply.
fn appendSubagentChildText(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(PendingTimelineEvent),
    text: []const u8,
) !void {
    if (std.mem.trim(u8, text, " \n\r\t").len == 0) return;
    if (rows.items.len > 0) {
        const last = &rows.items[rows.items.len - 1];
        if (last.role == .assistant and last.tool_call_id == null) {
            const joined = try std.mem.concat(allocator, u8, &.{ last.body, "\n\n", text });
            allocator.free(last.body);
            last.body = joined;
            return;
        }
    }
    try appendSubagentTextRow(allocator, rows, .assistant, "Child agent", text);
}

/// Re-serializes a nested entry without its `parent` tag, so the nested card's
/// `Transcript:` section reads exactly like a direct child's.
fn nestedTranscriptLineAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    var it = object.iterator();
    while (it.next()) |field| {
        if (std.mem.eql(u8, field.key_ptr.*, "parent")) continue;
        try stringify.objectField(field.key_ptr.*);
        try stringify.write(field.value_ptr.*);
    }
    try stringify.endObject();
    try writer.writer.writeByte('\n');
    return try writer.toOwnedSlice();
}

fn jsonObjectStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn presentSubagentThread(
    self: anytype,
    project_index: usize,
    thread_index: usize,
    target_pane_id: ?WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    focus: bool,
) !OpenChatResult {
    var project = &self.project_controller.projects.items[project_index];
    for (project.workspace_layout.panes.items) |pane| switch (pane.ref) {
        .chat => |chat_ref| if (chat_ref.thread_index == thread_index) {
            if (focus) {
                project.workspace_layout.focusCreatedPane(pane.id);
                project.selected_thread_index = thread_index;
                project.last_content_pane_id = pane.id;
                self.project_controller.selected_index = project_index;
                self.blurPaletteComposer();
                self.syncRenameBuffer();
                self.requestTranscriptScrollToBottom();
                self.markDirty();
            }
            return .{ .pane_id = pane.id, .thread_index = thread_index, .focused = focus, .presentation_existing = true };
        },
        else => {},
    };

    const result = try createWorkspaceChatPaneForThread(
        project,
        self.allocator,
        thread_index,
        target_pane_id,
        axis,
        focus,
    );
    if (focus) {
        self.project_controller.selected_index = project_index;
        self.blurPaletteComposer();
        self.syncRenameBuffer();
        self.requestTranscriptScrollToBottom();
    }
    self.setSidebarNotice("Subagent pane ready.");
    self.markDirty();
    return result;
}

fn captureSubagentSource(
    allocator: std.mem.Allocator,
    parent: *const ChatThread,
    request: OpenSubagentRequest,
) !SubagentSource {
    if (request.tool_call_id) |call_id| {
        for (parent.messages.items, 0..) |message, index| {
            if (message.tool_call_id) |existing| {
                if (std.mem.eql(u8, existing, call_id)) {
                    return try subagentSourceFromMessage(allocator, message, index);
                }
            }
        }
        {
            parent.send_state.mutex.lock();
            defer parent.send_state.mutex.unlock();
            for (parent.send_state.pending_events.items, 0..) |event, pending_index| {
                if (event.tool_call_id) |existing| {
                    if (std.mem.eql(u8, existing, call_id)) {
                        return try subagentSourceFromPending(allocator, event, parent.messages.items.len + pending_index);
                    }
                }
            }
        }
    }
    if (request.message_id) |message_id| {
        for (parent.messages.items, 0..) |message, index| {
            if (message.message_id) |existing| {
                if (std.mem.eql(u8, existing, message_id)) {
                    return try subagentSourceFromMessage(allocator, message, index);
                }
            }
        }
        {
            parent.send_state.mutex.lock();
            defer parent.send_state.mutex.unlock();
            for (parent.send_state.pending_events.items, 0..) |event, pending_index| {
                if (event.message_id) |existing| {
                    if (std.mem.eql(u8, existing, message_id)) {
                        return try subagentSourceFromPending(allocator, event, parent.messages.items.len + pending_index);
                    }
                }
            }
        }
    }
    const message_index = request.message_index orelse return error.SourceNotFound;
    if (message_index < parent.messages.items.len) {
        return try subagentSourceFromMessage(allocator, parent.messages.items[message_index], message_index);
    }
    {
        parent.send_state.mutex.lock();
        defer parent.send_state.mutex.unlock();
        const pending_index = message_index - parent.messages.items.len;
        if (pending_index >= parent.send_state.pending_events.items.len) return error.SourceNotFound;
        return try subagentSourceFromPending(allocator, parent.send_state.pending_events.items[pending_index], message_index);
    }
}

fn subagentSourceFromMessage(allocator: std.mem.Allocator, message: chat_types.ChatMessage, message_index: usize) !SubagentSource {
    if (!chat_types.looksLikeSubagentCard(message.author, message.tool_call_kind, message.body)) return error.NotASubagent;
    var identity_buf: [32]u8 = undefined;
    const identity = subagentIdentity(&identity_buf, message.tool_call_id, message.body, message_index);
    return try buildSubagentSource(allocator, identity, message.body, message.tool_call_status, null);
}

fn subagentSourceFromPending(allocator: std.mem.Allocator, event: chat_types.PendingTimelineEvent, message_index: usize) !SubagentSource {
    if (!chat_types.looksLikeSubagentCard(event.author, event.tool_call_kind, event.body)) return error.NotASubagent;
    var identity_buf: [32]u8 = undefined;
    const identity = subagentIdentity(&identity_buf, event.tool_call_id, event.body, message_index);
    return try buildSubagentSource(allocator, identity, event.body, event.tool_call_status, event.tool_call_transcript_partial);
}

/// Stable child identity: the provider call id, else an OpenCode child
/// session id, else the row position.
fn subagentIdentity(buf: *[32]u8, tool_call_id: ?[]const u8, body: []const u8, message_index: usize) []const u8 {
    if (tool_call_id) |call_id| return call_id;
    if (chat_types.parseSubagentConversation(body).session_id) |session_id| return session_id;
    return std.fmt.bufPrint(buf, "m{d}", .{message_index}) catch "m";
}

fn buildSubagentSource(
    allocator: std.mem.Allocator,
    identity: []const u8,
    body: []const u8,
    status: ?provider_types.ToolCallStatus,
    partial: ?[]const u8,
) !SubagentSource {
    const parsed = chat_types.parseSubagentConversation(body);
    const owned_identity = try allocator.dupe(u8, identity);
    errdefer allocator.free(owned_identity);
    const owned_title = try allocator.dupe(u8, parsed.title);
    errdefer allocator.free(owned_title);
    const owned_prompt = try unescapeJsonStringAlloc(allocator, parsed.prompt);
    errdefer allocator.free(owned_prompt);
    const owned_result = try allocator.dupe(u8, parsed.result);
    errdefer allocator.free(owned_result);
    const owned_transcript = try allocator.dupe(u8, parsed.transcript orelse "");
    errdefer allocator.free(owned_transcript);
    const owned_partial = try allocator.dupe(u8, partial orelse "");
    errdefer allocator.free(owned_partial);
    return .{
        .identity = owned_identity,
        .title = owned_title,
        .prompt = owned_prompt,
        .result = owned_result,
        .transcript = owned_transcript,
        .partial = owned_partial,
        .status = status,
    };
}

fn subagentStatusFallback(status: ?provider_types.ToolCallStatus) []const u8 {
    return switch (status orelse .unknown) {
        .pending, .in_progress => "This subagent is still running.",
        .cancelled => "This subagent was cancelled.",
        .failed => "This subagent failed.",
        .completed, .unknown => "This subagent finished without a stored transcript.",
    };
}

pub fn resolveChatCreationSettings(self: anytype, request: OpenChatRequest, model_ref: []const u8) !EffectiveChatSettings {
    if (request.reasoning_effort != null and request.reasoning_variant != null) {
        return error.ConflictingReasoningSettings;
    }

    if (request.reasoning_effort) |effort| {
        const supported = switch (request.provider) {
            .codex => codexSupportsReasoningEffort(model_ref, effort),
            .claude => blk: {
                const option = self.modelOptionForProvider(.claude, model_ref) orelse break :blk false;
                if (!option.reasoning_supported) break :blk false;
                const values = option.claude_effort_values orelse CLAUDE_STANDARD_EFFORT_VALUES[0..];
                for (values) |value| {
                    if (parseReasoningEffort(value)) |available| {
                        if (available == effort) break :blk true;
                    }
                }
                break :blk false;
            },
            // Pi accepts every Verde effort tag as a thinking level.
            .pi => true,
            .opencode, .cursor, .fx => false,
            // grok reasoning efforts stop at xhigh.
            .grok => effort != .max,
            .muse => true,
        };
        if (!supported) return error.UnsupportedReasoningEffort;
    }

    if (request.reasoning_variant) |variant| {
        if (variant.len == 0) return error.UnsupportedReasoningVariant;
        const option = self.modelOptionForProvider(request.provider, model_ref) orelse
            return error.UnsupportedReasoningVariant;
        const values = switch (request.provider) {
            .opencode => option.reasoning_variant_keys,
            .cursor => option.cursor_reasoning_values,
            .codex, .claude, .pi, .fx, .grok, .muse => null,
        } orelse return error.UnsupportedReasoningVariant;
        var supported = false;
        for (values) |value| {
            if (std.mem.eql(u8, value, variant)) {
                supported = true;
                break;
            }
        }
        if (!supported) return error.UnsupportedReasoningVariant;
    }

    if (request.fast_mode != null) {
        const supported = switch (request.provider) {
            .codex => true,
            .cursor => if (self.modelOptionForProvider(.cursor, model_ref)) |option| option.cursor_fast_supported else false,
            .opencode, .claude, .pi, .fx, .grok, .muse => false,
        };
        if (!supported) return error.UnsupportedFastMode;
    }

    return .{
        .reasoning_effort = request.reasoning_effort orelse if (request.provider == .codex) DEFAULT_CODEX_REASONING_EFFORT else null,
        .reasoning_variant = request.reasoning_variant,
        .fast_mode = request.fast_mode orelse .off,
    };
}

pub fn modelOptionForProvider(self: anytype, provider: Provider, model_ref: []const u8) ?ModelOption {
    for (composerModelOptions(self, provider)) |option| {
        const value = option.value orelse continue;
        if (std.mem.eql(u8, value, model_ref)) return option;
    }
    return null;
}

pub fn codexSupportsReasoningEffort(model_ref: []const u8, effort: ReasoningEffort) bool {
    for (provider_models.codexReasoningOptions(model_ref)) |option| {
        if (option.value) |value| {
            if (value == effort) return true;
        }
    }
    return false;
}

pub fn providerSupportsModel(self: anytype, provider: Provider, model_ref: []const u8) bool {
    for (composerModelOptions(self, provider)) |option| {
        const available_model = option.value orelse continue;
        if (std.mem.eql(u8, available_model, model_ref)) return true;
    }
    return false;
}

pub fn splitWorkspacePaneWithChatPlacement(self: anytype, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
    return splitWorkspacePaneWithChatPlacementAndFocus(self, project_index, pane_id, axis, new_after, true);
}

pub fn splitWorkspacePaneWithChatPlacementAndFocus(self: anytype, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool, focus: bool) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    var layout = &project.workspace_layout;
    _ = layout.paneById(pane_id) orelse return false;
    const previous_pane_id = layout.focused_pane_id;
    const previous_revealed_pane_id = layout.scroll_revealed_pane_id;
    const previous_thread_index = project.selected_thread_index;
    defer if (!focus) {
        layout.focused_pane_id = previous_pane_id;
        layout.scroll_revealed_pane_id = previous_revealed_pane_id;
        project.selected_thread_index = previous_thread_index;
    };
    const thread_index = project.addThread(self.allocator) catch |err| {
        log.err("failed to create chat thread for workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create a new thread.");
        return false;
    };
    self.applyNewChatDefaults(project_index, thread_index) catch |err| {
        log.warn("failed to apply new-chat defaults: {s}", .{@errorName(err)});
    };
    const new_pane_id = layout.createChatPane(self.allocator, thread_index) catch |err| {
        log.err("failed to create chat workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create chat pane.");
        return false;
    };
    layout.splitPaneWithLeaf(self.allocator, pane_id, new_pane_id, axis, new_after) catch |err| {
        log.err("failed to split chat workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to split workspace.");
        return false;
    };
    if (focus) layout.focusCreatedPane(new_pane_id);
    project.selected_thread_index = thread_index;
    if (focus and self.project_controller.selected_index == project_index) {
        self.terminal_controller.focused = false;
        self.requestComposerFocus();
        self.syncRenameBuffer();
    }
    self.setSidebarNotice("New chat pane ready.");
    self.markDirty();
    return true;
}

pub fn createWorkspaceChatPane(
    project: *Project,
    allocator: std.mem.Allocator,
    provider: Provider,
    model_ref: []const u8,
    settings: EffectiveChatSettings,
    target_pane_id: ?WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    focus: bool,
) !OpenChatResult {
    var layout = &project.workspace_layout;
    const target_id = target_pane_id orelse layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse
        return error.TargetPaneNotFound;
    _ = layout.paneById(target_id) orelse return error.TargetPaneNotFound;

    const previous_focused_pane_id = layout.focused_pane_id;
    const previous_maximized_pane_id = layout.maximized_pane_id;
    const previous_thread_index = project.selected_thread_index;
    const previous_viewport: WorkspaceViewportSnapshot = .{
        .offset_x = layout.scroll_offset_x,
        .target_x = layout.scroll_target_x,
        .offset_y = layout.scroll_offset_y,
        .target_y = layout.scroll_target_y,
        .revealed_pane_id = layout.scroll_revealed_pane_id,
        .leading_pane_id = layout.scroll_leading_pane_id,
        .animation_last_ms = layout.scroll_animation_last_ms,
        .axis_vertical = layout.scroll_axis_vertical,
    };

    var thread = try ChatThread.init(allocator, "New thread");
    var thread_owned = true;
    errdefer if (thread_owned) thread.deinit(allocator);
    const owned_model_ref = try allocator.dupeZ(u8, model_ref);
    allocator.free(thread.model_ref.?);
    thread.model_ref = owned_model_ref;
    thread.provider = provider;
    thread.reasoning_effort = settings.reasoning_effort;
    thread.opencode_reasoning_variant = if (settings.reasoning_variant) |variant|
        try allocator.dupeZ(u8, variant)
    else
        null;
    thread.fast_mode = settings.fast_mode;

    try project.threads.append(allocator, thread);
    thread_owned = false;
    var thread_appended = true;
    errdefer if (thread_appended) {
        var removed_thread = project.threads.pop().?;
        removed_thread.deinit(allocator);
        project.selected_thread_index = previous_thread_index;
    };
    const thread_index = project.threads.items.len - 1;

    const previous_next_pane_id = layout.next_pane_id;
    errdefer layout.next_pane_id = previous_next_pane_id;
    const new_pane_id = try layout.createChatPane(allocator, thread_index);
    var pane_inserted = true;
    errdefer if (pane_inserted) {
        if (layout.closePane(allocator, new_pane_id)) |removed| {
            var removed_ref = removed;
            deinitWorkspacePaneRef(&removed_ref, allocator);
        }
    };

    try layout.splitPaneWithLeaf(allocator, target_id, new_pane_id, axis, true);
    pane_inserted = false;
    thread_appended = false;

    if (focus) {
        layout.focusCreatedPane(new_pane_id);
        project.selected_thread_index = thread_index;
        project.last_content_pane_id = new_pane_id;
    } else {
        layout.focused_pane_id = previous_focused_pane_id;
        layout.maximized_pane_id = previous_maximized_pane_id;
        layout.scroll_offset_x = previous_viewport.offset_x;
        layout.scroll_target_x = previous_viewport.target_x;
        layout.scroll_offset_y = previous_viewport.offset_y;
        layout.scroll_target_y = previous_viewport.target_y;
        layout.scroll_revealed_pane_id = previous_viewport.revealed_pane_id;
        layout.scroll_leading_pane_id = previous_viewport.leading_pane_id;
        layout.scroll_animation_last_ms = previous_viewport.animation_last_ms;
        layout.scroll_axis_vertical = previous_viewport.axis_vertical;
        project.selected_thread_index = previous_thread_index;
    }
    return .{
        .pane_id = new_pane_id,
        .thread_index = thread_index,
        .focused = focus,
    };
}

fn createWorkspaceChatPaneForThread(
    project: *Project,
    allocator: std.mem.Allocator,
    thread_index: usize,
    target_pane_id: ?WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    focus: bool,
) !OpenChatResult {
    var layout = &project.workspace_layout;
    const target_id = target_pane_id orelse layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse
        return error.TargetPaneNotFound;
    _ = layout.paneById(target_id) orelse return error.TargetPaneNotFound;
    const previous_focused_pane_id = layout.focused_pane_id;
    const previous_maximized_pane_id = layout.maximized_pane_id;
    const previous_thread_index = project.selected_thread_index;
    const previous_last_content_pane_id = project.last_content_pane_id;
    const previous_next_pane_id = layout.next_pane_id;
    const previous_viewport: WorkspaceViewportSnapshot = .{
        .offset_x = layout.scroll_offset_x,
        .target_x = layout.scroll_target_x,
        .offset_y = layout.scroll_offset_y,
        .target_y = layout.scroll_target_y,
        .revealed_pane_id = layout.scroll_revealed_pane_id,
        .leading_pane_id = layout.scroll_leading_pane_id,
        .animation_last_ms = layout.scroll_animation_last_ms,
        .axis_vertical = layout.scroll_axis_vertical,
    };
    const previous_quick_pane = layout.quick_pane;
    errdefer layout.next_pane_id = previous_next_pane_id;
    const new_pane_id = try layout.createChatPane(allocator, thread_index);
    var pane_inserted = true;
    errdefer if (pane_inserted) {
        if (layout.closePane(allocator, new_pane_id)) |removed| {
            var removed_ref = removed;
            deinitWorkspacePaneRef(&removed_ref, allocator);
        }
        layout.focused_pane_id = previous_focused_pane_id;
        layout.maximized_pane_id = previous_maximized_pane_id;
        project.selected_thread_index = previous_thread_index;
        project.last_content_pane_id = previous_last_content_pane_id;
        layout.scroll_offset_x = previous_viewport.offset_x;
        layout.scroll_target_x = previous_viewport.target_x;
        layout.scroll_offset_y = previous_viewport.offset_y;
        layout.scroll_target_y = previous_viewport.target_y;
        layout.scroll_revealed_pane_id = previous_viewport.revealed_pane_id;
        layout.scroll_leading_pane_id = previous_viewport.leading_pane_id;
        layout.scroll_animation_last_ms = previous_viewport.animation_last_ms;
        layout.scroll_axis_vertical = previous_viewport.axis_vertical;
        layout.quick_pane = previous_quick_pane;
    };
    try layout.splitPaneWithLeaf(allocator, target_id, new_pane_id, axis, true);
    pane_inserted = false;
    if (focus) {
        layout.focusCreatedPane(new_pane_id);
        project.selected_thread_index = thread_index;
        project.last_content_pane_id = new_pane_id;
    } else {
        layout.focused_pane_id = previous_focused_pane_id;
        layout.maximized_pane_id = previous_maximized_pane_id;
        project.selected_thread_index = previous_thread_index;
        project.last_content_pane_id = previous_last_content_pane_id;
        layout.scroll_offset_x = previous_viewport.offset_x;
        layout.scroll_target_x = previous_viewport.target_x;
        layout.scroll_offset_y = previous_viewport.offset_y;
        layout.scroll_target_y = previous_viewport.target_y;
        layout.scroll_revealed_pane_id = previous_viewport.revealed_pane_id;
        layout.scroll_leading_pane_id = previous_viewport.leading_pane_id;
        layout.scroll_animation_last_ms = previous_viewport.animation_last_ms;
        layout.scroll_axis_vertical = previous_viewport.axis_vertical;
        layout.quick_pane = previous_quick_pane;
    }
    return .{ .pane_id = new_pane_id, .thread_index = thread_index, .focused = focus };
}

pub fn splitCurrentProjectWorkspacePaneWithThread(
    self: anytype,
    pane_id: WorkspacePaneId,
    thread_index: usize,
    axis: WorkspaceSplitAxis,
    new_after: bool,
) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var project = &self.project_controller.projects.items[self.project_controller.selected_index];
    if (thread_index >= project.threads.items.len) return false;
    var layout = &project.workspace_layout;
    const target_pane_id = if (layout.paneById(pane_id) != null)
        pane_id
    else
        layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse pane_id;
    _ = layout.paneById(target_pane_id) orelse return false;
    const new_pane_id = layout.createChatPane(self.allocator, thread_index) catch |err| {
        log.err("failed to create dropped chat workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create chat pane.");
        return false;
    };
    layout.splitPaneWithLeaf(self.allocator, target_pane_id, new_pane_id, axis, new_after) catch |err| {
        log.err("failed to split dropped chat workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to split workspace.");
        return false;
    };
    layout.focusCreatedPane(new_pane_id);
    project.selected_thread_index = thread_index;
    self.terminal_controller.focused = false;
    self.requestComposerFocus();
    self.syncRenameBuffer();
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn splitCurrentProjectWorkspacePaneWithTerminal(self: anytype, pane_id: WorkspacePaneId) bool {
    return self.splitCurrentProjectWorkspacePaneWithTerminalAxis(pane_id, .horizontal);
}

pub fn splitFocusedWorkspacePaneWithTerminalAxis(self: anytype, axis: WorkspaceSplitAxis) bool {
    return self.splitFocusedWorkspacePaneWithTerminalPlacement(axis, true);
}

pub fn splitFocusedWorkspacePaneWithTerminalPlacement(self: anytype, axis: WorkspaceSplitAxis, new_after: bool) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const pane_id = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.focused_pane_id orelse return false;
    return self.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, axis, new_after);
}

pub fn openTerminalPaneForProjectIndex(self: anytype, project_index: usize) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    self.project_controller.selected_index = project_index;
    if (self.project_controller.projects.items[project_index].workspace_layout.visiblePaneCount() == 0) {
        return openTerminalPaneInEmptyWorkspace(self, project_index);
    }
    self.ensureCurrentProjectWorkspace();
    const pane_id = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.focused_pane_id orelse return false;
    return self.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, .horizontal, true);
}

fn openTerminalPaneInEmptyWorkspace(self: anytype, project_index: usize) bool {
    const dock_id = self.createProjectTerminalDock(project_index) catch |err| {
        log.err("failed to allocate terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create terminal dock.");
        return false;
    };
    self.restartTerminalDockForWorkspace(project_index, dock_id) catch |err| {
        log.err("failed to start terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to start terminal.");
        return false;
    };
    var project = &self.project_controller.projects.items[project_index];
    const pane_id = project.workspace_layout.createTerminalPane(self.allocator, dock_id) catch |err| {
        log.err("failed to create terminal workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create terminal pane.");
        return false;
    };
    project.workspace_layout.replaceRootWithLeaf(self.allocator, pane_id) catch |err| {
        log.err("failed to seed terminal workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to open terminal pane.");
        return false;
    };
    project.workspace_layout.focusCreatedPane(pane_id);
    if (self.projectTerminalDockMutable(project_index, dock_id)) |dock| dock.visible = false;
    self.requestTerminalDockFocus(dock_id);
    self.setSidebarNotice("Terminal pane created.");
    self.markWorkspaceDirty(project_index);
    return true;
}

pub fn openCurrentProjectTerminalPaneForCommand(self: anytype) ?WorkspacePaneId {
    if (self.project_controller.projects.items.len == 0) return null;
    self.ensureCurrentProjectWorkspace();

    var project = &self.project_controller.projects.items[self.project_controller.selected_index];
    var layout = &project.workspace_layout;
    const target_pane_id = layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse {
        self.setSidebarNotice("No workspace pane selected.");
        return null;
    };
    _ = layout.paneById(target_pane_id) orelse return null;

    const dock_id = self.createCurrentProjectTerminalDock() catch |err| {
        log.err("failed to allocate editor terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create terminal dock.");
        return null;
    };
    project = &self.project_controller.projects.items[self.project_controller.selected_index];
    self.restartTerminalDockForWorkspace(self.project_controller.selected_index, dock_id) catch |err| {
        log.err("failed to start editor terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to start terminal.");
        return null;
    };
    var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return null;

    layout = &project.workspace_layout;
    const new_pane_id = layout.createTerminalPaneWithPurpose(self.allocator, dock_id, .editor) catch |err| {
        log.err("failed to create editor terminal workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create terminal pane.");
        return null;
    };
    layout.splitPaneWithLeaf(self.allocator, target_pane_id, new_pane_id, .horizontal, true) catch |err| {
        log.err("failed to split editor terminal workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to split workspace.");
        return null;
    };
    layout.focusCreatedPane(new_pane_id);
    dock.visible = false;
    self.requestTerminalDockFocus(dock_id);
    return new_pane_id;
}

pub fn openThreadInTui(self: anytype, project_index: usize, thread_index: usize) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    var project = &self.project_controller.projects.items[project_index];
    if (thread_index >= project.threads.items.len) return;
    var thread = &project.threads.items[thread_index];
    const provider_thread_id = thread.provider_thread_id orelse {
        self.setSidebarNotice("Thread has no provider session id yet.");
        return;
    };
    const command = self.tuiResumeCommand(thread.provider, provider_thread_id) catch |err| {
        log.warn("failed to build TUI resume command: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to build TUI resume command.");
        return;
    };
    defer self.allocator.free(command);

    self.project_controller.selected_index = project_index;
    self.ensureCurrentProjectWorkspace();

    project = &self.project_controller.projects.items[project_index];
    thread = &project.threads.items[thread_index];
    var layout = &project.workspace_layout;

    const previous_dock_id = thread.tui_dock_id;
    const pane_id = if (previous_dock_id) |dock_id|
        layout.visibleTerminalPaneIdForDock(dock_id) orelse
            layout.visibleChatPaneIdForThread(thread_index) orelse
            layout.focused_pane_id orelse
            layout.firstVisiblePaneId() orelse
            return
    else
        layout.visibleChatPaneIdForThread(thread_index) orelse
            layout.focused_pane_id orelse
            layout.firstVisiblePaneId() orelse
            return;

    if (previous_dock_id) |dock_id| {
        if (self.currentProjectTerminalDockMutable(dock_id)) |old_dock| {
            self.syncTerminalDockProcessLifecycle(project_index, dock_id, old_dock, pane_id);
            if (!self.finishTerminalSessionsForTeardown(project_index, old_dock, .tui_reopened)) {
                self.setSidebarNotice("Failed to retain previous TUI lifecycle.");
                return;
            }
        }
    }

    const dock_id = self.createCurrentProjectTerminalDock() catch |err| {
        log.err("failed to allocate TUI terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create TUI terminal.");
        return;
    };

    project = &self.project_controller.projects.items[project_index];
    thread = &project.threads.items[thread_index];
    layout = &project.workspace_layout;
    thread.tui_dock_id = dock_id;
    const pane = layout.paneByIdMutable(pane_id) orelse return;
    const fx_command = [_][]const u8{ "fx", "--resume", provider_thread_id };
    const launch_profile: terminal.TerminalLaunchProfile = if (thread.provider == .fx)
        .{ .kind = .custom, .label = "fx", .command = &fx_command }
    else
        .{};
    self.restartTerminalDockForWorkspaceProfile(project_index, dock_id, project.path, launch_profile) catch |err| {
        log.err("failed to start TUI terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to start TUI terminal.");
        return;
    };
    var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return;
    _ = dock.setActiveTabPinnedProvider(self.allocator, @tagName(thread.provider));
    _ = self.workspaceAgentTuiHistoryAt(project_index, dock_id);

    pane.ref = .{ .terminal = .{ .dock_id = dock_id } };
    layout.focused_pane_id = pane_id;
    layout.maximized_pane_id = null;
    dock.visible = false;
    self.requestTerminalFocus();
    if (thread.provider != .fx) {
        _ = self.writeWorkspaceTerminalPane(pane_id, command) catch |err| {
            log.warn("failed to write TUI resume command: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to write TUI resume command.");
            return;
        };
    }
    self.setSidebarNotice("Thread opened in TUI.");
    self.markDirty();
}

pub fn openThreadInChat(self: anytype, project_index: usize, thread_index: usize) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    var project = &self.project_controller.projects.items[project_index];
    if (thread_index >= project.threads.items.len) return;
    const dock_id = project.threads.items[thread_index].tui_dock_id orelse return;

    self.project_controller.selected_index = project_index;
    self.ensureCurrentProjectWorkspace();
    project = &self.project_controller.projects.items[project_index];
    var layout = &project.workspace_layout;
    const pane_id = layout.visibleTerminalPaneIdForDock(dock_id) orelse layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse return;
    const pane = layout.paneByIdMutable(pane_id) orelse return;
    pane.ref = .{ .chat = .{ .thread_index = thread_index } };
    layout.focused_pane_id = pane_id;
    layout.maximized_pane_id = null;
    project.selected_thread_index = thread_index;
    self.terminal_controller.focused = false;
    self.requestComposerFocus();
    self.syncRenameBuffer();
    self.setSidebarNotice("Thread opened in chat.");
    self.markDirty();
}

pub fn tuiResumeCommand(self: anytype, provider: Provider, thread_id: []const u8) ![]u8 {
    return switch (provider) {
        .codex => std.fmt.allocPrint(self.allocator, "codex resume {s}\n", .{thread_id}),
        .opencode => blk: {
            if (!std.mem.startsWith(u8, thread_id, "ses")) {
                break :blk self.allocator.dupe(u8, "opencode --continue\n");
            }
            break :blk std.fmt.allocPrint(self.allocator, "opencode --session {s}\n", .{thread_id});
        },
        .claude => std.fmt.allocPrint(self.allocator, "claude --resume {s}\n", .{thread_id}),
        .cursor => std.fmt.allocPrint(self.allocator, "agent --resume {s}\n", .{thread_id}),
        .pi => std.fmt.allocPrint(self.allocator, "pi --session-id {s}\n", .{thread_id}),
        .fx => std.fmt.allocPrint(self.allocator, "fx --resume {s}\n", .{thread_id}),
        .grok => std.fmt.allocPrint(self.allocator, "grok --resume {s}\n", .{thread_id}),
        .muse => std.fmt.allocPrint(self.allocator, "muse resume {s}\n", .{thread_id}),
    };
}

fn threadForTuiDock(project: *const Project, dock_id: u32) ?*const ChatThread {
    for (project.threads.items) |*thread| {
        if (thread.tui_dock_id == dock_id) return thread;
    }
    for (project.archived_threads.items) |*thread| {
        if (thread.tui_dock_id == dock_id) return thread;
    }
    return null;
}

fn terminalPaneForDock(project: *const Project, dock_id: u32) ?WorkspacePaneId {
    if (project.workspace_layout.visibleTerminalPaneIdForDock(dock_id)) |pane_id| return pane_id;
    for (project.workspace_layout.panes.items) |pane| {
        switch (pane.ref) {
            .terminal => |ref| if (ref.dock_id == dock_id) return pane.id,
            else => {},
        }
    }
    return null;
}

/// Replays the provider resume command only when the terminal layer reports
/// that a persisted daemon session had to be recreated. Thread and dock IDs,
/// rather than mutable display titles, provide the durable association.
pub fn resumeRecreatedThreadTui(self: anytype, project_index: usize, dock_id: u32) !bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    const thread = threadForTuiDock(project, dock_id) orelse return false;
    const provider_thread_id = thread.provider_thread_id orelse return false;
    const pane_id = terminalPaneForDock(project, dock_id) orelse return false;
    if (thread.provider == .fx) {
        const fx_command = [_][]const u8{ "fx", "--resume", provider_thread_id };
        try self.restartTerminalDockForWorkspaceProfile(project_index, dock_id, project.path, .{
            .kind = .custom,
            .label = "fx",
            .command = &fx_command,
        });
        return true;
    }
    const command = try self.tuiResumeCommand(thread.provider, provider_thread_id);
    defer self.allocator.free(command);
    return try self.writeWorkspaceTerminalPaneForProject(project_index, pane_id, command);
}

pub fn splitCurrentProjectWorkspacePaneWithTerminalAxis(self: anytype, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
    return self.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, axis, true);
}

pub fn splitCurrentProjectWorkspacePaneWithTerminalPlacement(self: anytype, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.splitWorkspacePaneWithTerminalPlacement(self.project_controller.selected_index, pane_id, axis, new_after);
}

/// Split a terminal pane and keep it inside the target scrolling tile.
pub fn splitCurrentProjectWorkspacePaneTiledWithTerminalPlacement(
    self: anytype,
    pane_id: WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    new_after: bool,
) bool {
    if (!self.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, axis, new_after)) return false;
    return joinCurrentProjectCreatedPaneToScrollGroup(self, pane_id);
}

pub fn splitFocusedWorkspacePaneTiledWithTerminalPlacement(self: anytype, axis: WorkspaceSplitAxis, new_after: bool) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const pane_id = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.focused_pane_id orelse return false;
    return self.splitCurrentProjectWorkspacePaneTiledWithTerminalPlacement(pane_id, axis, new_after);
}

fn joinCurrentProjectCreatedPaneToScrollGroup(self: anytype, target_pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const new_pane_id = layout.focused_pane_id orelse return false;
    if (new_pane_id == target_pane_id) return true;
    if (!layout.joinPaneToScrollGroup(target_pane_id, new_pane_id)) return false;
    self.markWorkspaceDirty(self.project_controller.selected_index);
    return true;
}

pub fn splitWorkspacePaneWithTerminalAxis(self: anytype, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
    return self.splitWorkspacePaneWithTerminalPlacement(project_index, pane_id, axis, true);
}

pub fn splitWorkspacePaneWithTerminalPlacement(self: anytype, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
    return splitWorkspacePaneWithTerminalPlacementAndFocus(self, project_index, pane_id, axis, new_after, true);
}

pub fn splitWorkspacePaneWithTerminalPlacementAndFocus(self: anytype, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool, focus: bool) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    var layout = &project.workspace_layout;
    _ = layout.paneById(pane_id) orelse return false;
    const previous_pane_id = layout.focused_pane_id;
    const previous_revealed_pane_id = layout.scroll_revealed_pane_id;
    const previous_thread_index = project.selected_thread_index;
    defer if (!focus) {
        layout.focused_pane_id = previous_pane_id;
        layout.scroll_revealed_pane_id = previous_revealed_pane_id;
        project.selected_thread_index = previous_thread_index;
    };

    const dock_id = self.createProjectTerminalDock(project_index) catch |err| {
        log.err("failed to allocate terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create terminal dock.");
        return false;
    };
    self.restartTerminalDockForWorkspace(project_index, dock_id) catch |err| {
        log.err("failed to start terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to start terminal.");
        return false;
    };
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
    // Terminal startup queues a focus request consumed by the next UI frame.
    if (!focus) dock.focus_requested = false;

    const new_pane_id = layout.createTerminalPane(self.allocator, dock_id) catch |err| {
        log.err("failed to create terminal workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create terminal pane.");
        return false;
    };
    layout.splitPaneWithLeaf(self.allocator, pane_id, new_pane_id, axis, new_after) catch |err| {
        log.err("failed to split terminal workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to split workspace.");
        return false;
    };
    if (focus) layout.focusCreatedPane(new_pane_id);
    dock.visible = false;
    if (focus and self.project_controller.selected_index == project_index) self.requestTerminalDockFocus(dock_id);
    self.setSidebarNotice("Terminal pane created.");
    self.markWorkspaceDirty(project_index);
    return true;
}

pub fn toggleFocusedWorkspacePaneMaximized(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const pane_id = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.focused_pane_id orelse return false;
    return self.toggleCurrentProjectWorkspacePaneMaximized(pane_id);
}

pub fn resizeCurrentProjectWorkspaceSplit(
    self: anytype,
    first_pane_id: WorkspacePaneId,
    second_pane_id: WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    ratio: f32,
) void {
    if (self.project_controller.projects.items.len == 0) return;
    _ = self.resizeWorkspaceSplit(self.project_controller.selected_index, first_pane_id, second_pane_id, axis, ratio);
}

pub fn resizeWorkspaceSplit(
    self: anytype,
    project_index: usize,
    first_pane_id: WorkspacePaneId,
    second_pane_id: WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    ratio: f32,
) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    if (!layout.resizeSplit(first_pane_id, second_pane_id, axis, ratio)) return false;
    self.markWorkspaceDirty(project_index);
    return true;
}

pub fn nudgeCurrentProjectWorkspaceSplit(
    self: anytype,
    first_pane_id: WorkspacePaneId,
    second_pane_id: WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    delta: f32,
) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    if (layout.nudgeSplitRatio(first_pane_id, second_pane_id, axis, delta)) {
        self.markWorkspaceDirty(self.project_controller.selected_index);
        return true;
    }
    return false;
}

pub fn focusCurrentProjectWorkspaceTerminalPane(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    for (layout.panes.items) |pane| {
        switch (pane.ref) {
            .terminal => {
                layout.focused_pane_id = pane.id;
                return;
            },
            else => {},
        }
    }
}

pub fn focusCurrentProjectWorkspaceTerminalDock(self: anytype, dock_id: u32) void {
    if (self.project_controller.projects.items.len == 0) return;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    for (layout.panes.items) |pane| {
        switch (pane.ref) {
            .terminal => |ref| if (ref.dock_id == dock_id) {
                layout.focused_pane_id = pane.id;
                return;
            },
            else => {},
        }
    }
}

pub fn currentProjectWorkspaceVisiblePaneCount(self: anytype) usize {
    if (self.project_controller.projects.items.len == 0) return 0;
    return self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.visiblePaneCount();
}

pub fn currentProjectGridNewPanePlacement(self: anytype) ?WorkspacePanePlacement {
    if (self.project_controller.projects.items.len == 0) return null;
    return self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.gridNewPanePlacement();
}

test "prefix close on an empty workspace archives the workspace" {
    const allocator = std.testing.allocator;
    const FakeState = struct {
        allocator: std.mem.Allocator,
        project_controller: struct {
            projects: std.ArrayList(Project) = .empty,
            selected_index: usize = 0,
        } = .{},
        closed_workspace_index: ?usize = null,

        pub fn closeCurrentProjectWorkspacePane(self: *@This(), pane_id: WorkspacePaneId) bool {
            if (self.project_controller.projects.items.len == 0) return false;
            var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
            var removed_ref = layout.closePane(self.allocator, pane_id) orelse return false;
            deinitWorkspacePaneRef(&removed_ref, self.allocator);
            return true;
        }

        pub fn closeProjectAtIndexResult(self: *@This(), index: usize) bool {
            self.closed_workspace_index = index;
            return true;
        }
    };

    var state: FakeState = .{ .allocator = allocator };
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var empty_project = try Project.init(allocator, "empty", "Empty", "/tmp/empty", 0);
    var removed_empty_ref = empty_project.workspace_layout.closePane(allocator, 1) orelse return error.TestExpectedEqual;
    deinitWorkspacePaneRef(&removed_empty_ref, allocator);
    state.project_controller.projects.append(allocator, empty_project) catch |err| {
        empty_project.deinit(allocator);
        return err;
    };
    var occupied_project = try Project.init(allocator, "occupied", "Occupied", "/tmp/occupied", 0);
    state.project_controller.projects.append(allocator, occupied_project) catch |err| {
        occupied_project.deinit(allocator);
        return err;
    };

    try std.testing.expect(closeFocusedWorkspacePane(&state));
    try std.testing.expectEqual(@as(?usize, 0), state.closed_workspace_index);
    try std.testing.expectEqual(@as(usize, 0), state.project_controller.projects.items[0].workspace_layout.visiblePaneCount());

    state.closed_workspace_index = null;
    state.project_controller.selected_index = 1;
    try std.testing.expect(closeFocusedWorkspacePane(&state));
    try std.testing.expectEqual(@as(?usize, null), state.closed_workspace_index);
    try std.testing.expectEqual(@as(usize, 0), state.project_controller.projects.items[1].workspace_layout.visiblePaneCount());
    try std.testing.expect(closeFocusedWorkspacePane(&state));
    try std.testing.expectEqual(@as(?usize, 1), state.closed_workspace_index);
}

test "addressed chat send does not change the visible workspace selection" {
    const allocator = std.testing.allocator;
    const FakeState = struct {
        project_controller: struct {
            projects: std.ArrayList(Project) = .empty,
            selected_index: usize = 0,
        } = .{},
        send_calls: usize = 0,

        pub fn sendThreadPrompt(self: *@This(), _: []const u8, _: []const u8, _: []const u8, _: []const ChatImageAttachment) !bool {
            self.send_calls += 1;
            return true;
        }

        pub fn sendThreadDraft(_: *@This(), _: usize, _: usize) !bool {
            return true;
        }
    };

    var state: FakeState = .{};
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }
    var project = try Project.init(allocator, "background-send", "Background", "/tmp/background-send", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    const selected_thread_before = state.project_controller.projects.items[0].selected_thread_index;
    const focused_pane_before = state.project_controller.projects.items[0].workspace_layout.focused_pane_id;
    const target_pane_id = focused_pane_before orelse return error.MissingChatPane;

    try std.testing.expect(try sendWorkspaceChatPanePromptForProject(&state, 0, target_pane_id, "background prompt"));
    try std.testing.expectEqual(@as(usize, 1), state.send_calls);
    try std.testing.expectEqual(@as(usize, 0), state.project_controller.selected_index);
    try std.testing.expectEqual(selected_thread_before, state.project_controller.projects.items[0].selected_thread_index);
    try std.testing.expectEqual(focused_pane_before, state.project_controller.projects.items[0].workspace_layout.focused_pane_id);
}

test "background splits preserve selection and viewport without requesting input focus" {
    const allocator = std.testing.allocator;
    const FakeState = struct {
        allocator: std.mem.Allocator,
        project_controller: struct {
            projects: std.ArrayList(Project) = .empty,
            selected_index: usize = 0,
        } = .{},
        terminal_controller: struct { focused: bool = true } = .{},
        dock: struct { visible: bool = false, focus_requested: bool = false } = .{},
        focus_requests: usize = 0,
        terminal_starts: usize = 0,

        pub fn applyNewChatDefaults(_: *@This(), _: usize, _: usize) !void {}
        pub fn setSidebarNotice(_: *@This(), _: []const u8) void {}
        pub fn markDirty(_: *@This()) void {}
        pub fn markWorkspaceDirty(_: *@This(), _: usize) void {}
        pub fn syncRenameBuffer(_: *@This()) void {}
        pub fn requestComposerFocus(self: *@This()) void {
            self.focus_requests += 1;
        }
        pub fn requestTerminalDockFocus(self: *@This(), _: u32) void {
            self.focus_requests += 1;
        }
        pub fn createProjectTerminalDock(_: *@This(), _: usize) !u32 {
            return 7;
        }
        pub fn restartTerminalDockForWorkspace(self: *@This(), _: usize, _: u32) !void {
            self.terminal_starts += 1;
            self.dock.focus_requested = true;
        }
        pub fn projectTerminalDockMutable(self: *@This(), _: usize, _: u32) ?*@TypeOf(self.dock) {
            return &self.dock;
        }
    };
    var state: FakeState = .{ .allocator = allocator };
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }
    try state.project_controller.projects.ensureUnusedCapacity(allocator, 1);
    state.project_controller.projects.appendAssumeCapacity(try Project.init(allocator, "split", "Split", "/tmp/split", 0));
    const project = &state.project_controller.projects.items[0];
    const layout = &project.workspace_layout;
    const pane_id = layout.focused_pane_id.?;
    const thread_index = project.selected_thread_index;
    layout.maximized_pane_id = pane_id;
    layout.scroll_revealed_pane_id = pane_id;
    layout.scroll_offset_x = 120;
    layout.scroll_target_x = 180;
    for ([_]bool{ false, true }) |terminal_pane| {
        const created = if (terminal_pane)
            splitWorkspacePaneWithTerminalPlacementAndFocus(&state, 0, pane_id, .horizontal, true, false)
        else
            splitWorkspacePaneWithChatPlacementAndFocus(&state, 0, pane_id, .horizontal, true, false);
        try std.testing.expect(created);
        try std.testing.expectEqual(pane_id, layout.focused_pane_id.?);
        try std.testing.expectEqual(pane_id, layout.maximized_pane_id.?);
        try std.testing.expectEqual(pane_id, layout.scroll_revealed_pane_id.?);
        try std.testing.expectEqual(thread_index, project.selected_thread_index);
        try std.testing.expectEqual(@as(f32, 120), layout.scroll_offset_x);
        try std.testing.expectEqual(@as(f32, 180), layout.scroll_target_x);
        try std.testing.expectEqual(@as(usize, 0), state.focus_requests);
        try std.testing.expect(state.terminal_controller.focused);
    }
    try std.testing.expectEqual(@as(usize, 3), layout.visiblePaneCount());
    try std.testing.expectEqual(@as(usize, 2), project.threads.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.terminal_starts);
    try std.testing.expect(!state.dock.focus_requested);
    try std.testing.expect(splitWorkspacePaneWithChatPlacement(&state, 0, pane_id, .horizontal, true));
    try std.testing.expect(layout.focused_pane_id.? != pane_id);
    try std.testing.expectEqual(@as(usize, 1), state.focus_requests);
}

test "background chat creation preserves the scrolling viewport" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "background-open", "Background", "/tmp/background-open", 0);
    defer project.deinit(allocator);

    const layout = &project.workspace_layout;
    const focused_pane_id = layout.focused_pane_id orelse return error.MissingChatPane;
    layout.scroll_offset_x = 120.0;
    layout.scroll_target_x = 180.0;
    layout.scroll_offset_y = 24.0;
    layout.scroll_target_y = 48.0;
    layout.scroll_revealed_pane_id = focused_pane_id;
    layout.scroll_leading_pane_id = focused_pane_id;
    layout.scroll_animation_last_ms = 456;
    layout.scroll_axis_vertical = true;

    const result = try createWorkspaceChatPane(
        &project,
        allocator,
        .codex,
        DEFAULT_CODEX_MODEL,
        .{
            .reasoning_effort = DEFAULT_CODEX_REASONING_EFFORT,
            .reasoning_variant = null,
            .fast_mode = .off,
        },
        focused_pane_id,
        .horizontal,
        false,
    );

    try std.testing.expect(!result.focused);
    try std.testing.expectEqual(@as(?WorkspacePaneId, focused_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(f32, 120.0), layout.scroll_offset_x);
    try std.testing.expectEqual(@as(f32, 180.0), layout.scroll_target_x);
    try std.testing.expectEqual(@as(f32, 24.0), layout.scroll_offset_y);
    try std.testing.expectEqual(@as(f32, 48.0), layout.scroll_target_y);
    try std.testing.expectEqual(@as(?WorkspacePaneId, focused_pane_id), layout.scroll_revealed_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, focused_pane_id), layout.scroll_leading_pane_id);
    try std.testing.expectEqual(@as(i64, 456), layout.scroll_animation_last_ms);
    try std.testing.expect(layout.scroll_axis_vertical);
}

test "subagent view rows render streamed child activity as text and tool cards" {
    const allocator = std.testing.allocator;
    const source: SubagentSource = .{
        .identity = try allocator.dupe(u8, "agent-1"),
        .title = try allocator.dupe(u8, "Explore repo"),
        .prompt = try allocator.dupe(u8, "Look around"),
        .result = try allocator.dupe(u8, ""),
        .transcript = try allocator.dupe(u8,
            \\{"type":"text","text":"Looking around."}
            \\{"type":"tool_use","id":"c1","kind":"execute","title":"","input":"ls"}
            \\{"type":"tool_result","id":"c1","is_error":false,"output":"README.md"}
            \\{"type":"text","text":"Found one file."}
            \\{"type":"text","text":"Reading it next."}
            \\not json
            \\{"type":"tool_use","id":"c2","kind":"read","title":"Read README.md","input":"{\"file_path\":\"README.md\"}"}
        ),
        .partial = try allocator.dupe(u8, ""),
        .status = .in_progress,
    };
    defer source.deinit(allocator);

    var rows = try buildSubagentViewRows(allocator, source);
    defer utils.freePendingTimelineEvents(allocator, &rows);
    try std.testing.expectEqual(@as(usize, 7), rows.items.len);
    try std.testing.expectEqual(provider_models.ChatRole.user, rows.items[1].role);
    try std.testing.expectEqualStrings("Look around", rows.items[1].body);
    try std.testing.expectEqualStrings("Looking around.", rows.items[2].body);
    try std.testing.expectEqualStrings("Ran command", rows.items[3].author);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, rows.items[3].tool_call_status.?);
    try std.testing.expectEqualStrings("Input:\nls\n\nOutput:\nREADME.md", rows.items[3].body);
    try std.testing.expectEqualStrings("Found one file.\n\nReading it next.", rows.items[4].body);
    try std.testing.expectEqual(provider_types.ToolCallKind.read, rows.items[5].tool_call_kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.in_progress, rows.items[5].tool_call_status.?);
    try std.testing.expectEqualStrings("This subagent is still running.", rows.items[6].body);

    var thread = try ChatThread.init(allocator, "child");
    defer thread.deinit(allocator);
    try thread.replaceSubagentViewRows(allocator, source.title, rows.items, source.signature());
    try std.testing.expectEqual(@as(usize, 7), thread.messages.items.len);
    try std.testing.expectEqualStrings("c1", thread.messages.items[3].tool_call_id.?);
    try std.testing.expectEqualStrings("Explore repo", thread.title);
    try std.testing.expectEqual(source.signature(), thread.subagent_view_signature);
}

test "subagent view renders child thinking and the still-streaming block" {
    const allocator = std.testing.allocator;
    const source: SubagentSource = .{
        .identity = try allocator.dupe(u8, "agent-4"),
        .title = try allocator.dupe(u8, "Explore repo"),
        .prompt = try allocator.dupe(u8, "Look around"),
        .result = try allocator.dupe(u8, ""),
        .transcript = try allocator.dupe(u8,
            \\{"type":"thinking","text":"Weighing where to start."}
            \\{"type":"text","text":"Looking around."}
            \\{"type":"surprise","text":"ignored"}
        ),
        .partial = try allocator.dupe(u8, "Reading the README"),
        .status = .in_progress,
    };
    defer source.deinit(allocator);

    var rows = try buildSubagentViewRows(allocator, source);
    defer utils.freePendingTimelineEvents(allocator, &rows);
    // intro, prompt, thinking, child text merged with the partial, status note
    try std.testing.expectEqual(@as(usize, 5), rows.items.len);
    try std.testing.expectEqual(provider_models.ChatRole.system, rows.items[2].role);
    try std.testing.expectEqualStrings("Thinking", rows.items[2].author);
    try std.testing.expectEqualStrings("Weighing where to start.", rows.items[2].body);
    try std.testing.expectEqualStrings("Child agent", rows.items[3].author);
    try std.testing.expectEqualStrings("Looking around.\n\nReading the README", rows.items[3].body);
    try std.testing.expectEqualStrings("This subagent is still running.", rows.items[4].body);

    // The partial is part of the pane identity, so the next delta re-syncs it.
    const grown: SubagentSource = .{
        .identity = source.identity,
        .title = source.title,
        .prompt = source.prompt,
        .result = source.result,
        .transcript = source.transcript,
        .partial = try allocator.dupe(u8, "Reading the README now"),
        .status = source.status,
    };
    defer allocator.free(grown.partial);
    try std.testing.expect(source.signature() != grown.signature());
}

test "subagent view skips a result that repeats the child's final reply" {
    const allocator = std.testing.allocator;
    const source: SubagentSource = .{
        .identity = try allocator.dupe(u8, "agent-2"),
        .title = try allocator.dupe(u8, "Summarize"),
        .prompt = try allocator.dupe(u8, "Summarize the repo"),
        .result = try allocator.dupe(u8, "[Subagent hand-back] The report follows:\n  Verde is a Zig-based desktop application.\n  \n  It hosts agents.\nagentId: abc\n<usage>tool_uses: 2</usage>"),
        .transcript = try allocator.dupe(u8,
            \\{"type":"text","text":"Verde is a Zig-based desktop application.\n\nIt hosts agents."}
        ),
        .partial = try allocator.dupe(u8, ""),
        .status = .completed,
    };
    defer source.deinit(allocator);
    var rows = try buildSubagentViewRows(allocator, source);
    defer utils.freePendingTimelineEvents(allocator, &rows);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    try std.testing.expectEqualStrings("Verde is a Zig-based desktop application.\n\nIt hosts agents.", rows.items[2].body);
}

test "subagent prompts decode JSON string escapes for the You bubble" {
    const allocator = std.testing.allocator;
    const body = "Tool:\nExplore\n\nInput:\n{\"description\":\"Explore\",\"prompt\":\"Line one.\\n\\nSay \\\"hi\\\" then stop.\"}";
    const source = try buildSubagentSource(allocator, "agent-3", body, .in_progress, null);
    defer source.deinit(allocator);
    try std.testing.expectEqualStrings("Line one.\n\nSay \"hi\" then stop.", source.prompt);
    const plain = try unescapeJsonStringAlloc(allocator, "no escapes here");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("no escapes here", plain);
    const broken = try unescapeJsonStringAlloc(allocator, "trailing backslash \\");
    defer allocator.free(broken);
    try std.testing.expectEqualStrings("trailing backslash \\", broken);
}

test "nested agent entries fill the nested card instead of the child pane timeline" {
    const allocator = std.testing.allocator;
    const source: SubagentSource = .{
        .identity = try allocator.dupe(u8, "agent-5"),
        .title = try allocator.dupe(u8, "Explore repo"),
        .prompt = try allocator.dupe(u8, "Explore"),
        .result = try allocator.dupe(u8, ""),
        .transcript = try allocator.dupe(u8,
            \\{"type":"text","text":"Delegating."}
            \\{"type":"tool_use","id":"nested","kind":"subagent","title":"Read README","input":"{\"description\":\"Read README\",\"prompt\":\"Read README.md\"}"}
            \\{"type":"thinking","text":"Open the file.","parent":"nested"}
            \\{"type":"tool_use","id":"g1","kind":"read","title":"Read README.md","input":"{\"file_path\":\"README.md\"}","parent":"nested"}
            \\{"type":"tool_result","id":"g1","is_error":false,"output":"hi","parent":"nested"}
            \\{"type":"text","text":"README says hi.","parent":"nested"}
            \\{"type":"tool_result","id":"nested","is_error":false,"output":"nested report"}
        ),
        .partial = try allocator.dupe(u8, ""),
        .status = .in_progress,
    };
    defer source.deinit(allocator);

    var rows = try buildSubagentViewRows(allocator, source);
    defer utils.freePendingTimelineEvents(allocator, &rows);
    // intro, prompt, the child's own text, the nested card, status note
    try std.testing.expectEqual(@as(usize, 5), rows.items.len);
    try std.testing.expectEqualStrings("Delegating.", rows.items[2].body);
    const nested = rows.items[3];
    try std.testing.expectEqualStrings("nested", nested.tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallKind.subagent, nested.tool_call_kind.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, nested.tool_call_status.?);
    try std.testing.expect(chat_types.looksLikeSubagentCard(nested.author, nested.tool_call_kind, nested.body));
    // The nested card carries the grandchild's activity, stripped of the tag.
    try std.testing.expect(std.mem.indexOf(u8, nested.body, "\"parent\"") == null);
    try std.testing.expectEqualStrings("nested report", chat_types.parseSubagentConversation(nested.body).result);

    // Clicking that card opens a grandchild pane built from the same row.
    const nested_source = try buildSubagentSource(allocator, "nested", nested.body, nested.tool_call_status, null);
    defer nested_source.deinit(allocator);
    try std.testing.expectEqualStrings("Read README", nested_source.title);
    try std.testing.expectEqualStrings("Read README.md", nested_source.prompt);
    var nested_rows = try buildSubagentViewRows(allocator, nested_source);
    defer utils.freePendingTimelineEvents(allocator, &nested_rows);
    try std.testing.expectEqual(@as(usize, 6), nested_rows.items.len);
    try std.testing.expectEqualStrings("Open the file.", nested_rows.items[2].body);
    try std.testing.expectEqualStrings("g1", nested_rows.items[3].tool_call_id.?);
    try std.testing.expectEqual(provider_types.ToolCallStatus.completed, nested_rows.items[3].tool_call_status.?);
    try std.testing.expectEqualStrings("README says hi.", nested_rows.items[4].body);
    try std.testing.expectEqualStrings("nested report", nested_rows.items[5].body);
}
