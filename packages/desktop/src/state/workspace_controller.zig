//! Workspace command classification and lease controller operations.

const std = @import("std");
const project_state = @import("project.zig");
const ai_harness = @import("../providers/harness.zig");
const chat_threads = @import("../chat/threads.zig");
const runtime_log = @import("../runtime/log.zig");
const terminal = @import("../terminal/terminal.zig");
const chat_types = @import("chat_types.zig");
const provider_models = @import("provider_models.zig");
const workspace_layout = @import("workspace_layout.zig");
const platform_runtime = @import("platform_runtime");
const log = std.log.scoped(.native_shell);

const ChatThread = chat_types.ChatThread;
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
const CODEX_REASONING_OPTIONS = provider_models.CODEX_REASONING_OPTIONS;
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

const EffectiveChatSettings = struct {
    reasoning_effort: ?ReasoningEffort,
    reasoning_variant: ?[]const u8,
    fast_mode: FastMode,
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
    );
}

fn composerDefaultModelRef(self: anytype, provider: Provider) [:0]const u8 {
    return switch (provider) {
        .codex => DEFAULT_CODEX_MODEL,
        .opencode => self.cachedDefaultModelRefForProvider(.opencode),
        .claude => DEFAULT_CLAUDE_MODEL,
        .cursor => DEFAULT_CURSOR_MODEL,
    };
}

const Project = project_state.Project;
const WorkspaceLease = project_state.WorkspaceLease;
const TerminalProcessFinish = project_state.TerminalProcessFinish;

pub const CommandClass = enum {
    other,
    build,
    @"test",
    formatter,
    package_install,
    migration,
    dev_server,
};

/// Conservatively classifies commands whose shared output is well-known.
/// Unknown commands remain concurrent unless callers declare resources.
pub fn classifyWorkspaceCommand(command: []const u8) CommandClass {
    if (commandHasAnyToken(command, &.{ "migrate", "migration", "migrations" })) return .migration;
    if (isPackageInstallCommand(command)) return .package_install;
    if (commandHasAnyToken(command, &.{ "fmt", "format", "formatter", "prettier", "gofmt", "rustfmt" })) return .formatter;
    if (commandHasAnyToken(command, &.{ "test", "tests", "pytest", "vitest", "jest" })) return .@"test";
    if (commandHasAnyToken(command, &.{ "build", "compile" }) or commandStartsWithToken(command, "make")) return .build;
    if (commandHasAnyToken(command, &.{ "dev", "serve", "server" })) return .dev_server;
    return .other;
}

pub fn inferredWorkspaceResource(command: []const u8) ?[]const u8 {
    return switch (classifyWorkspaceCommand(command)) {
        .build, .@"test" => "build",
        .formatter => "source",
        .package_install => "deps",
        .migration => "db",
        .other, .dev_server => null,
    };
}

fn commandHasAnyToken(command: []const u8, wanted: []const []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, command, " \t\r\n'\"=,:;()[]{}");
    while (tokens.next()) |token| {
        for (wanted) |candidate| {
            if (std.ascii.eqlIgnoreCase(token, candidate)) return true;
        }
    }
    return false;
}

fn commandStartsWithAnyToken(command: []const u8, wanted: []const []const u8) bool {
    for (wanted) |candidate| {
        if (commandStartsWithToken(command, candidate)) return true;
    }
    return false;
}

fn commandStartsWithToken(command: []const u8, wanted: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, command, " \t\r\n'\"");
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "exec") or
            std.ascii.eqlIgnoreCase(token, "sh") or
            std.ascii.eqlIgnoreCase(token, "bash") or
            std.ascii.eqlIgnoreCase(token, "zsh") or
            std.mem.eql(u8, token, "-c") or
            std.mem.eql(u8, token, "-lc")) continue;
        return std.ascii.eqlIgnoreCase(std.fs.path.basename(token), wanted);
    }
    return false;
}

fn isPackageInstallCommand(command: []const u8) bool {
    const managers = [_][]const u8{ "npm", "pnpm", "yarn", "bun", "pip", "pip3", "uv", "cargo", "gem", "bundle", "composer" };
    const has_manager = commandHasAnyToken(command, &managers) or commandStartsWithAnyToken(command, &managers);
    return has_manager and commandHasAnyToken(command, &.{ "install", "add", "remove", "update", "upgrade" });
}

pub fn workspaceResourcesOverlap(left: anytype, right: anytype) bool {
    for (left) |left_resource| {
        for (right) |right_resource| {
            if (std.mem.eql(u8, left_resource, right_resource)) return true;
        }
    }
    return false;
}

fn workspaceLeaseResourcesEqual(left: anytype, right: anytype) bool {
    if (left.len != right.len) return false;
    for (left) |resource| {
        var found = false;
        for (right) |candidate| {
            if (std.mem.eql(u8, resource, candidate)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub fn appendOwnedString(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

pub fn pruneExpiredLeases(project: *Project, allocator: std.mem.Allocator, now_ms: i64) void {
    var index: usize = 0;
    while (index < project.workspace_leases.items.len) {
        if (project.workspace_leases.items[index].expires_at_ms > now_ms) {
            index += 1;
            continue;
        }
        var expired = project.workspace_leases.orderedRemove(index);
        expired.deinit(allocator);
    }
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
    pruneExpiredLeases(project, allocator, now_ms);

    for (project.workspace_leases.items) |*existing| {
        if (!std.mem.eql(u8, existing.owner, owner)) continue;
        if (!workspaceLeaseResourcesEqual(existing.resources.items, resources)) continue;
        existing.expires_at_ms = now_ms + ttl_ms;
        if (!std.mem.eql(u8, existing.command, command)) {
            const replacement = try allocator.dupe(u8, command);
            allocator.free(existing.command);
            existing.command = replacement;
        }
        return existing;
    }

    if (!force) {
        for (project.workspace_leases.items) |existing| {
            if (std.mem.eql(u8, existing.owner, owner)) continue;
            if (workspaceResourcesOverlap(existing.resources.items, resources)) return error.LeaseConflict;
        }
    }

    var lease: WorkspaceLease = lease: {
        const id = try std.fmt.allocPrint(allocator, "lease:{d}", .{project.next_workspace_lease_id});
        errdefer allocator.free(id);
        const owned_owner = try allocator.dupe(u8, owner);
        errdefer allocator.free(owned_owner);
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        break :lease .{
            .id = id,
            .owner = owned_owner,
            .command = owned_command,
            .created_at_ms = now_ms,
            .expires_at_ms = now_ms + ttl_ms,
        };
    };
    project.next_workspace_lease_id += 1;
    errdefer lease.deinit(allocator);
    for (resources) |resource| try appendOwnedString(allocator, &lease.resources, resource);
    try project.workspace_leases.append(allocator, lease);
    return &project.workspace_leases.items[project.workspace_leases.items.len - 1];
}

pub fn releaseLease(project: *Project, allocator: std.mem.Allocator, owner: []const u8, lease_id: ?[]const u8, now_ms: i64) usize {
    if (owner.len == 0) return 0;
    pruneExpiredLeases(project, allocator, now_ms);
    var released: usize = 0;
    var index: usize = 0;
    while (index < project.workspace_leases.items.len) {
        const existing = &project.workspace_leases.items[index];
        if (!std.mem.eql(u8, existing.owner, owner) or
            (lease_id != null and !std.mem.eql(u8, existing.id, lease_id.?)))
        {
            index += 1;
            continue;
        }
        var removed = project.workspace_leases.orderedRemove(index);
        removed.deinit(allocator);
        released += 1;
        if (lease_id != null) break;
    }
    return released;
}

pub fn releaseLeasesForExactOwner(project: *Project, allocator: std.mem.Allocator, owner: []const u8, now_ms: i64) usize {
    return releaseLease(project, allocator, owner, null, now_ms);
}

pub fn ensureCurrentProjectWorkspace(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    const changed = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.ensureDefaultChat(self.allocator) catch |err| {
        log.err("failed to initialize workspace panes: {s}", .{@errorName(err)});
        return;
    };
    if (changed) self.markDirty();
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
            self.markDirty();
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
    self.markDirty();
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
    self.markDirty();
    return true;
}

pub fn createFloatingQuickTerminal(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const project_index = self.project_controller.selected_index;
    self.ensureCurrentProjectWorkspace();
    const return_focus_pane_id = self.project_controller.projects.items[project_index].workspace_layout.focused_pane_id;

    const dock_id = self.createProjectTerminalDock(project_index) catch |err| {
        log.err("failed to allocate quick terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create quick terminal.");
        return false;
    };
    self.restartTerminalDockForWorkspace(project_index, dock_id) catch |err| {
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
    self.markDirty();
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
    self.markDirty();
    return true;
}

pub fn toggleCurrentProjectQuickPaneMaximized(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const quick = if (layout.quick_pane) |*value| value else return false;
    quick.visible = true;
    quick.maximized = !quick.maximized;
    self.markDirty();
    return true;
}

pub fn toggleCurrentProjectQuickPanePinned(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const quick = if (layout.quick_pane) |*value| value else return false;
    quick.pinned = !quick.pinned;
    quick.visible = true;
    self.markDirty();
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
    self.markDirty();
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
    self.markDirty();
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
    self.markDirty();
    return true;
}

pub fn setWorkspaceChatPaneDraft(self: anytype, pane_id: WorkspacePaneId, value: []const u8, append: bool) !bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.setWorkspaceChatPaneDraftForProject(self.project_controller.selected_index, pane_id, value, append);
}

pub fn sendWorkspaceChatPanePromptForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, prompt: ?[]const u8) !bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const snapshot = self.captureViewFocusSnapshot();
    const restore_view = project_index != snapshot.selected_project_index;
    if (restore_view) self.project_controller.selected_index = project_index;
    defer if (restore_view) self.restoreViewFocusSnapshot(snapshot);

    if (prompt) |text| {
        if (!try self.setWorkspaceChatPaneDraft(pane_id, text, false)) return false;
    } else if (!self.selectWorkspaceChatPaneThread(pane_id)) return false;

    try self.sendDraft();
    return true;
}

pub fn sendWorkspaceChatPanePrompt(self: anytype, pane_id: WorkspacePaneId, prompt: ?[]const u8) !bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.sendWorkspaceChatPanePromptForProject(self.project_controller.selected_index, pane_id, prompt);
}

pub fn followupWorkspaceChatPanePromptForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, prompt: []const u8) !bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const snapshot = self.captureViewFocusSnapshot();
    const restore_view = project_index != snapshot.selected_project_index;
    if (restore_view) self.project_controller.selected_index = project_index;
    defer if (restore_view) self.restoreViewFocusSnapshot(snapshot);

    if (!try self.setWorkspaceChatPaneDraft(pane_id, prompt, false)) return false;
    self.queueOrSteerDraftDuringSend();
    return true;
}

pub fn followupWorkspaceChatPanePrompt(self: anytype, pane_id: WorkspacePaneId, prompt: []const u8) !bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.followupWorkspaceChatPanePromptForProject(self.project_controller.selected_index, pane_id, prompt);
}

pub fn stopWorkspaceChatPaneForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const snapshot = self.captureViewFocusSnapshot();
    const restore_view = project_index != snapshot.selected_project_index;
    if (restore_view) self.project_controller.selected_index = project_index;
    defer if (restore_view) self.restoreViewFocusSnapshot(snapshot);

    if (!self.selectWorkspaceChatPaneThread(pane_id)) return false;
    self.abortCurrentThreadSend();
    return true;
}

pub fn stopWorkspaceChatPane(self: anytype, pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.stopWorkspaceChatPaneForProject(self.project_controller.selected_index, pane_id);
}

pub fn approveWorkspaceChatPaneForProject(self: anytype, project_index: usize, pane_id: WorkspacePaneId, decision: ai_harness.ApprovalDecision) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const snapshot = self.captureViewFocusSnapshot();
    const restore_view = project_index != snapshot.selected_project_index;
    if (restore_view) self.project_controller.selected_index = project_index;
    defer if (restore_view) self.restoreViewFocusSnapshot(snapshot);

    if (!self.selectWorkspaceChatPaneThread(pane_id)) return false;
    self.resolvePendingApproval(decision);
    return true;
}

pub fn approveWorkspaceChatPane(self: anytype, pane_id: WorkspacePaneId, decision: ai_harness.ApprovalDecision) bool {
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

pub fn pollTerminalDockBeforeRead(self: anytype, project_index: usize, dock_id: u32, dock: *terminal.Dock) !void {
    const changed = try dock.poll(self.allocator);
    self.syncTerminalDockProcessLifecycle(project_index, dock_id, dock, null);
    try self.drainTerminalDockNotifications(project_index, dock_id, dock);
    if (changed and project_index == self.project_controller.selected_index) {
        const project = &self.project_controller.projects.items[project_index];
        if (dock.visible or project.workspace_layout.hasTerminalDockPane(dock_id)) {
            self.terminal_controller.last_activity_ms = @intCast(@divTrunc(platform_runtime.monotonicTimestampNs(), std.time.ns_per_ms));
            self.markDirty();
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
    self.markDirty();
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
    if (project_index >= self.project_controller.projects.items.len) return false;
    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const pane = layout.paneById(pane_id) orelse return false;
    // Composer popovers belong to the live composer pane; leaving them
    // open on a pane that no longer renders them would silently keep
    // eating clicks through the popover routing.
    self.closePaletteModelPicker();
    self.closeRunConfigPopover();
    layout.focused_pane_id = pane_id;
    switch (pane.ref) {
        .chat => |ref| {
            var project = &self.project_controller.projects.items[project_index];
            if (ref.thread_index < project.threads.items.len) {
                project.selected_thread_index = ref.thread_index;
                _ = self.clearChatCompletion(project_index, ref.thread_index);
            }
            project.last_content_pane_id = pane_id;
            if (self.project_controller.selected_index == project_index) {
                self.syncPaletteComposerFromDraft();
                self.requestComposerFocus();
            }
        },
        .terminal => |ref| {
            self.project_controller.projects.items[project_index].last_content_pane_id = pane_id;
            if (self.project_controller.selected_index == project_index) self.requestTerminalDockFocus(ref.dock_id);
        },
        .browser => {
            if (self.project_controller.selected_index == project_index) self.focusBrowserPane();
        },
    }
    self.markDirty();
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
    self.markDirty();
    return true;
}

pub fn swapCurrentProjectWorkspacePanes(self: anytype, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    var layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    if (!layout.swapPaneRefs(first_pane_id, second_pane_id)) return false;
    self.markDirty();
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
        self.markDirty();
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
        self.markDirty();
        return false;
    };
    layout.maximized_pane_id = null;
    _ = self.focusCurrentProjectWorkspacePane(source_pane_id);
    self.markDirty();
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
    runtime_log.diagnostic("pane maximize toggle begin project={d} pane={d} kind={s} currently_maximized={any}", .{
        project_index,
        pane_id,
        @tagName(pane.ref),
        layout.maximized_pane_id,
    });
    layout.maximized_pane_id = if (layout.maximized_pane_id == pane_id) null else pane_id;
    layout.focused_pane_id = pane_id;
    _ = self.focusWorkspacePane(project_index, pane_id);
    self.markDirty();
    runtime_log.diagnostic("pane maximize toggle done project={d} pane={d} maximized={any}", .{
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
    self.markDirty();
    return true;
}

pub fn closeCurrentProjectWorkspacePane(self: anytype, pane_id: WorkspacePaneId) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.closeWorkspacePane(self.project_controller.selected_index, pane_id);
}

pub fn closeWorkspacePane(self: anytype, project_index: usize, pane_id: WorkspacePaneId) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    var layout = &project.workspace_layout;
    if (layout.rootContainsPane(pane_id) and layout.visiblePaneCount() <= 1) {
        self.setSidebarNotice("Cannot close the last workspace pane.");
        return false;
    }
    var removed_ref = layout.closePane(self.allocator, pane_id) orelse return false;
    defer deinitWorkspacePaneRef(&removed_ref, self.allocator);
    switch (removed_ref) {
        .chat => self.setSidebarNotice("Chat pane closed."),
        .terminal => |ref| {
            const preserve_agent_history = self.workspaceAgentTuiHistoryAt(project_index, ref.dock_id) != 0;
            if (!layout.hasTerminalDockPane(ref.dock_id)) {
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
            }
            if (self.project_controller.selected_index == project_index and !layout.hasVisiblePaneKind(.terminal)) self.terminal_controller.focused = false;
            self.setSidebarNotice(if (preserve_agent_history) "Agent TUI closed. Reopen it from History." else "Terminal pane closed.");
        },
        .browser => {
            const removed_runtime_owner = if (self.browser_controller.runtime_project_index) |runtime_project_index|
                runtime_project_index == project_index
            else
                false;
            self.reconcileBrowserRuntimeAfterPaneRemoval(project_index, removed_runtime_owner);
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
        }
    }
    self.markDirty();
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

pub fn closeFocusedWorkspacePane(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const pane_id = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.focused_pane_id orelse return false;
    return self.closeCurrentProjectWorkspacePane(pane_id);
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

pub fn resolveChatCreationSettings(self: anytype, request: OpenChatRequest, model_ref: []const u8) !EffectiveChatSettings {
    if (request.reasoning_effort != null and request.reasoning_variant != null) {
        return error.ConflictingReasoningSettings;
    }

    if (request.reasoning_effort) |effort| {
        const supported = switch (request.provider) {
            .codex => codexSupportsReasoningEffort(effort),
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
            .opencode, .cursor => false,
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
            .codex, .claude => null,
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
            .opencode, .claude => false,
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

pub fn codexSupportsReasoningEffort(effort: ReasoningEffort) bool {
    for (CODEX_REASONING_OPTIONS) |option| {
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
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    var layout = &project.workspace_layout;
    _ = layout.paneById(pane_id) orelse return false;
    const thread_index = project.addThread(self.allocator) catch |err| {
        log.err("failed to create chat thread for workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create a new thread.");
        return false;
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
    layout.focusCreatedPane(new_pane_id);
    project.selected_thread_index = thread_index;
    if (self.project_controller.selected_index == project_index) {
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
    var pane_appended = true;
    errdefer if (pane_appended) {
        var removed_ref = layout.panes.pop().?.ref;
        deinitWorkspacePaneRef(&removed_ref, allocator);
    };

    try layout.splitPaneWithLeaf(allocator, target_id, new_pane_id, axis, true);
    pane_appended = false;
    thread_appended = false;

    if (focus) {
        layout.focusCreatedPane(new_pane_id);
        project.selected_thread_index = thread_index;
        project.last_content_pane_id = new_pane_id;
    } else {
        layout.focused_pane_id = previous_focused_pane_id;
        layout.maximized_pane_id = previous_maximized_pane_id;
        project.selected_thread_index = previous_thread_index;
    }
    return .{
        .pane_id = new_pane_id,
        .thread_index = thread_index,
        .focused = focus,
    };
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
    self.markDirty();
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
    self.ensureCurrentProjectWorkspace();
    const pane_id = self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout.focused_pane_id orelse return false;
    return self.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, .horizontal, true);
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
    self.restartTerminalDockForWorkspace(project_index, dock_id) catch |err| {
        log.err("failed to start TUI terminal dock: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to start TUI terminal.");
        return;
    };
    var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return;
    _ = dock.setActiveTabPinnedProvider(self.allocator, @tagName(thread.provider));

    pane.ref = .{ .terminal = .{ .dock_id = dock_id } };
    layout.focused_pane_id = pane_id;
    layout.maximized_pane_id = null;
    dock.visible = false;
    self.requestTerminalFocus();
    _ = self.writeWorkspaceTerminalPane(pane_id, command) catch |err| {
        log.warn("failed to write TUI resume command: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to write TUI resume command.");
        return;
    };
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
    };
}

pub fn splitCurrentProjectWorkspacePaneWithTerminalAxis(self: anytype, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
    return self.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, axis, true);
}

pub fn splitCurrentProjectWorkspacePaneWithTerminalPlacement(self: anytype, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    return self.splitWorkspacePaneWithTerminalPlacement(self.project_controller.selected_index, pane_id, axis, new_after);
}

pub fn splitWorkspacePaneWithTerminalAxis(self: anytype, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
    return self.splitWorkspacePaneWithTerminalPlacement(project_index, pane_id, axis, true);
}

pub fn splitWorkspacePaneWithTerminalPlacement(self: anytype, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    var layout = &project.workspace_layout;
    _ = layout.paneById(pane_id) orelse return false;

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
    layout.focusCreatedPane(new_pane_id);
    dock.visible = false;
    if (self.project_controller.selected_index == project_index) self.requestTerminalDockFocus(dock_id);
    self.setSidebarNotice("Terminal pane created.");
    self.markDirty();
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
    self.markDirty();
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
        self.markDirty();
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
