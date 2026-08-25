//! Herdr profile picker state and owned profile summaries.

const std = @import("std");
const herdr = @import("../workspace/herdr.zig");
const terminal = @import("../terminal/terminal.zig");
const herdr_types = @import("herdr_types.zig");
const project_state = @import("project.zig");
const provider_models = @import("provider_models.zig");
const terminal_controller = @import("terminal_controller.zig");
const workspace_layout = @import("workspace_layout.zig");

const Provider = provider_models.Provider;
const Project = project_state.Project;
const ProviderExecutionTarget = herdr_types.ProviderExecutionTarget;
const HerdrPaneLink = herdr_types.HerdrPaneLink;
const HerdrPanePresentation = herdr_types.HerdrPanePresentation;
const HerdrPaneProvider = herdr_types.HerdrPaneProvider;
const HerdrWorkspaceLink = herdr_types.HerdrWorkspaceLink;
const WorkspaceNode = workspace_layout.WorkspaceNode;
const WorkspacePane = workspace_layout.WorkspacePane;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;
const deinitWorkspacePaneRef = workspace_layout.deinitWorkspacePaneRef;
const log = std.log.scoped(.native_shell);

pub const ProfileSummary = struct {
    name: [:0]const u8,
    ssh_target: [:0]const u8,
    session: [:0]const u8,
    remote_cwd: ?[:0]const u8 = null,
    local_dir: ?[:0]const u8 = null,

    pub fn deinit(self: ProfileSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.ssh_target);
        allocator.free(self.session);
        if (self.remote_cwd) |value| allocator.free(value);
        if (self.local_dir) |value| allocator.free(value);
    }
};

pub const State = struct {
    notice_storage: [256:0]u8 = [_:0]u8{0} ** 256,
    picker_project_index: ?usize = null,
    selected_index: ?usize = null,
    hover_index: ?usize = null,
    summaries: std.ArrayList(ProfileSummary) = .empty,
};

fn herdrPaneProviderForThreadProvider(provider: Provider) HerdrPaneProvider {
    return switch (provider) {
        .codex => .codex,
        .claude => .claude,
        .opencode => .opencode,
        .cursor => .cursor,
        // Pi, FX, and Grok have no HERDR pane mapping yet; unknown panes get no TUI command.
        .pi, .fx, .grok => .unknown,
    };
}

fn herdrAgentCommandForProvider(allocator: std.mem.Allocator, provider: HerdrPaneProvider, thread_id: ?[]const u8) !?[]u8 {
    if (thread_id) |id| {
        return switch (provider) {
            .codex => try std.fmt.allocPrint(allocator, "codex resume {s}", .{id}),
            .claude => try std.fmt.allocPrint(allocator, "claude --resume {s}", .{id}),
            .opencode => if (std.mem.startsWith(u8, id, "ses"))
                try std.fmt.allocPrint(allocator, "{s} --session {s}", .{ terminal_controller.OPENCODE_TUI_COMMAND, id })
            else
                try allocator.dupe(u8, terminal_controller.OPENCODE_TUI_COMMAND),
            .cursor => try std.fmt.allocPrint(allocator, "agent --resume {s}", .{id}),
            .terminal, .browser, .unknown => null,
        };
    }

    const command: ?[]const u8 = switch (provider) {
        .codex => "codex",
        .claude => "claude",
        .opencode => terminal_controller.OPENCODE_TUI_COMMAND,
        .cursor => "agent",
        .terminal, .browser, .unknown => null,
    };
    return if (command) |value| try allocator.dupe(u8, value) else null;
}

fn parseHerdrJsonStringAlloc(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const value = herdr.findJsonString(parsed.value, key) orelse return error.InvalidHerdrResponse;
    return try allocator.dupe(u8, value);
}

pub const HerdrOpenResult = struct {
    workspace_index: usize,
    workspace_id: []const u8,
    workspace_path: []const u8,
    created: bool,
    restored: bool,
    remote: []const u8,
    session: []const u8,
    herdr_workspace: []const u8,
    herdr_pane: ?[]const u8,
    terminal_dock_id: ?u32,
    terminal_pane_id: ?WorkspacePaneId,
};

pub const HerdrHandoffWorkspaceResult = struct {
    workspace_index: usize,
    workspace_id: []const u8,
    label: []const u8,
    path: []const u8,
    remote: []const u8,
    session: []const u8,
    herdr_workspace: []const u8,
    herdr_tab: ?[]const u8,
    created: bool,
    pane_count: usize,
};

pub const HerdrHandoffResult = struct {
    dry_run: bool,
    workspace_count: usize,
    workspaces: []HerdrHandoffWorkspaceResult,

    pub fn deinit(self: HerdrHandoffResult, allocator: std.mem.Allocator) void {
        if (self.workspaces.len > 0) allocator.free(self.workspaces);
    }
};

pub const HerdrUnlinkPreviousLink = struct {
    remote: []const u8,
    session: []const u8,
    herdr_workspace: []const u8,
    remote_cwd: ?[]const u8 = null,
    herdr_pane: ?[]const u8 = null,
    terminal_dock_id: ?u32 = null,
    terminal_pane_id: ?WorkspacePaneId = null,
    pane_links_len: usize = 0,
    updated_at_ms: i64 = 0,

    fn init(allocator: std.mem.Allocator, link: HerdrWorkspaceLink) !HerdrUnlinkPreviousLink {
        const remote = try allocator.dupe(u8, link.remote_alias);
        errdefer allocator.free(remote);
        const session = try allocator.dupe(u8, link.session_name);
        errdefer allocator.free(session);
        const workspace = try allocator.dupe(u8, link.workspace_id);
        errdefer allocator.free(workspace);
        const remote_cwd = if (link.remote_cwd) |value| try allocator.dupe(u8, value) else null;
        errdefer if (remote_cwd) |value| allocator.free(value);
        const herdr_pane = if (link.last_pane_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (herdr_pane) |value| allocator.free(value);
        return .{
            .remote = remote,
            .session = session,
            .herdr_workspace = workspace,
            .remote_cwd = remote_cwd,
            .herdr_pane = herdr_pane,
            .terminal_dock_id = link.attach_dock_id,
            .terminal_pane_id = link.attach_pane_id,
            .pane_links_len = link.pane_links.items.len,
            .updated_at_ms = link.updated_at_ms,
        };
    }

    fn deinit(self: HerdrUnlinkPreviousLink, allocator: std.mem.Allocator) void {
        allocator.free(self.remote);
        allocator.free(self.session);
        allocator.free(self.herdr_workspace);
        if (self.remote_cwd) |value| allocator.free(value);
        if (self.herdr_pane) |value| allocator.free(value);
    }
};

pub const HerdrUnlinkWorkspaceResult = struct {
    workspace_index: usize,
    workspace_id: []const u8,
    label: []const u8,
    path: []const u8,
    unlinked: bool,
    previous: ?HerdrUnlinkPreviousLink = null,

    fn deinit(self: HerdrUnlinkWorkspaceResult, allocator: std.mem.Allocator) void {
        if (self.previous) |previous| previous.deinit(allocator);
    }
};

pub const HerdrUnlinkResult = struct {
    workspace_count: usize,
    workspaces: []HerdrUnlinkWorkspaceResult,

    pub fn deinit(self: HerdrUnlinkResult, allocator: std.mem.Allocator) void {
        for (self.workspaces) |workspace| workspace.deinit(allocator);
        if (self.workspaces.len > 0) allocator.free(self.workspaces);
    }
};

pub fn consumePendingHerdrOpenRequest(self: anytype) !bool {
    var threaded: std.Io.Threaded = .init(self.allocator, .{});
    defer threaded.deinit();
    var loaded = try herdr.readPendingOpen(self.allocator, threaded.io(), self.storage.pref_path) orelse return false;
    defer loaded.deinit();
    herdr.deletePendingOpen(self.allocator, threaded.io(), self.storage.pref_path);
    _ = try openOrCreateHerdrWorkspace(self, loaded.value);
    return true;
}

pub fn openOrCreateHerdrWorkspace(self: anytype, request: herdr.OpenRequest) !HerdrOpenResult {
    try herdr.validateOpenRequest(request);
    const remote_alias = herdr.remoteAlias(request);
    var created = false;
    var restored = false;

    const project_index = if (findHerdrProjectIndex(self, request)) |index| index else blk: {
        const local_dir = try resolveHerdrLocalProjectDir(self, request);
        defer self.allocator.free(local_dir);
        if (self.findProjectIndexByPath(local_dir)) |index| {
            break :blk index;
        }
        const result = try self.createProjectFromPath(local_dir);
        created = !result.restored;
        restored = result.restored;
        break :blk result.index;
    };

    self.project_controller.selected_index = project_index;
    self.ensureCurrentProjectWorkspace();
    const local_dir_for_link = self.project_controller.projects.items[project_index].path;
    try replaceProjectHerdrLink(self, project_index, request, local_dir_for_link, null, null);
    self.syncRenameBuffer();
    self.setSidebarNotice(if (remote_alias.len > 0) "Remote Herdr workspace opened." else "Herdr workspace opened.");
    self.markDirty();

    const project = &self.project_controller.projects.items[project_index];
    const link = project.herdr_link;
    return .{
        .workspace_index = project_index,
        .workspace_id = project.id,
        .workspace_path = project.path,
        .created = created,
        .restored = restored,
        .remote = remote_alias,
        .session = request.session,
        .herdr_workspace = request.herdr_workspace,
        .herdr_pane = request.pane,
        .terminal_dock_id = if (link) |value| value.attach_dock_id else null,
        .terminal_pane_id = if (link) |value| value.attach_pane_id else null,
    };
}

pub fn handoffHerdrWorkspaces(self: anytype, result_allocator: std.mem.Allocator, request: herdr.HandoffRequest) !HerdrHandoffResult {
    try herdr.validateHandoffRequest(request);
    if (self.project_controller.projects.items.len == 0) return .{ .dry_run = request.dry_run, .workspace_count = 0, .workspaces = &.{} };

    var results: std.ArrayList(HerdrHandoffWorkspaceResult) = .empty;
    errdefer results.deinit(result_allocator);

    if (request.all or request.workspace == null) {
        for (self.project_controller.projects.items, 0..) |_, project_index| {
            try results.append(result_allocator, try handoffProjectToHerdr(self, project_index, request));
        }
    } else {
        const project_index = herdrHandoffProjectIndex(self, request.workspace.?) orelse return error.NoProjectSelected;
        try results.append(result_allocator, try handoffProjectToHerdr(self, project_index, request));
    }

    if (!request.dry_run) {
        self.setSidebarNotice("Handed Verde workspace layout to Herdr.");
        self.markDirty();
    }

    const owned = try results.toOwnedSlice(result_allocator);
    return .{
        .dry_run = request.dry_run,
        .workspace_count = owned.len,
        .workspaces = owned,
    };
}

pub fn unlinkHerdrWorkspaces(self: anytype, result_allocator: std.mem.Allocator, request: herdr.UnlinkRequest) !HerdrUnlinkResult {
    try herdr.validateUnlinkRequest(request);
    if (self.project_controller.projects.items.len == 0) return .{ .workspace_count = 0, .workspaces = &.{} };

    var results: std.ArrayList(HerdrUnlinkWorkspaceResult) = .empty;
    errdefer {
        for (results.items) |workspace| workspace.deinit(result_allocator);
        results.deinit(result_allocator);
    }

    if (request.all) {
        for (self.project_controller.projects.items, 0..) |project, project_index| {
            if (project.herdr_link == null) continue;
            try appendHerdrUnlinkResult(self, result_allocator, &results, project_index);
        }
    } else {
        const selector = request.workspace orelse "current";
        const project_index = herdrHandoffProjectIndex(self, selector) orelse return error.NoProjectSelected;
        try appendHerdrUnlinkResult(self, result_allocator, &results, project_index);
    }

    var unlinked_count: usize = 0;
    for (results.items) |result| {
        if (result.unlinked) unlinked_count += 1;
    }
    if (unlinked_count > 0) {
        self.setSidebarNotice(if (unlinked_count == 1) "Herdr link removed; workspace now runs locally." else "Herdr links removed; workspaces now run locally.");
        self.markDirty();
    }

    const owned = try results.toOwnedSlice(result_allocator);
    return .{
        .workspace_count = owned.len,
        .workspaces = owned,
    };
}

pub fn handoffProjectToLocalHerdrFromUi(self: anytype, project_index: usize) void {
    if (project_index >= self.project_controller.projects.items.len) {
        self.setSidebarNotice("Workspace not found.");
        return;
    }
    const request: herdr.HandoffRequest = .{
        .session = if (self.project_controller.projects.items[project_index].herdr_link) |link| link.session_name else "default",
        .workspace = self.project_controller.projects.items[project_index].id,
        .all = false,
    };
    var result = handoffHerdrWorkspaces(self, self.allocator, request) catch |err| {
        self.setSidebarNotice(herdrUiFailureMessage(err));
        return;
    };
    defer result.deinit(self.allocator);
    self.setSidebarNotice("Workspace handed off to Herdr.");
}

pub fn unlinkProjectHerdrFromUi(self: anytype, project_index: usize) void {
    if (project_index >= self.project_controller.projects.items.len) {
        self.setSidebarNotice("Workspace not found.");
        return;
    }
    const request: herdr.UnlinkRequest = .{
        .workspace = self.project_controller.projects.items[project_index].id,
        .all = false,
    };
    var result = unlinkHerdrWorkspaces(self, self.allocator, request) catch |err| {
        self.setSidebarNotice(herdrUiFailureMessage(err));
        return;
    };
    defer result.deinit(self.allocator);
    if (result.workspace_count == 0 or (result.workspaces.len > 0 and !result.workspaces[0].unlinked)) {
        self.setSidebarNotice("Workspace is already running locally.");
    }
}

pub fn focusProjectHerdrAttachTerminal(self: anytype, project_index: usize) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    const link = project.herdr_link orelse {
        self.setSidebarNotice("Workspace is not linked to Herdr.");
        return false;
    };
    const dock_id = link.attach_dock_id orelse {
        return openLinkedHerdrWorkspaceTerminalFromUi(self, project_index);
    };
    const pane_id = link.attach_pane_id orelse project.workspace_layout.visibleTerminalPaneIdForDock(dock_id) orelse {
        return openLinkedHerdrWorkspaceTerminalFromUi(self, project_index);
    };
    if (project.workspace_layout.paneById(pane_id) == null) {
        return openLinkedHerdrWorkspaceTerminalFromUi(self, project_index);
    }
    self.project_controller.selected_index = project_index;
    self.ensureCurrentProjectWorkspace();
    project = &self.project_controller.projects.items[project_index];
    project.workspace_layout.focused_pane_id = pane_id;
    project.workspace_layout.maximized_pane_id = null;
    self.requestTerminalDockFocus(dock_id);
    self.syncRenameBuffer();
    self.markDirty();
    return true;
}

fn appendHerdrUnlinkResult(
    self: anytype,
    result_allocator: std.mem.Allocator,
    results: *std.ArrayList(HerdrUnlinkWorkspaceResult),
    project_index: usize,
) !void {
    var result = try snapshotHerdrUnlinkResult(self, result_allocator, project_index);
    var result_owned = true;
    errdefer if (result_owned) result.deinit(result_allocator);
    try results.append(result_allocator, result);
    result_owned = false;
    if (result.unlinked) clearProjectHerdrLink(self, project_index);
}

fn snapshotHerdrUnlinkResult(self: anytype, result_allocator: std.mem.Allocator, project_index: usize) !HerdrUnlinkWorkspaceResult {
    if (project_index >= self.project_controller.projects.items.len) return error.NoProjectSelected;
    const project = &self.project_controller.projects.items[project_index];
    const previous = if (project.herdr_link) |link| try HerdrUnlinkPreviousLink.init(result_allocator, link) else null;
    errdefer if (previous) |value| value.deinit(result_allocator);
    return .{
        .workspace_index = project_index,
        .workspace_id = project.id,
        .label = project.label,
        .path = project.path,
        .unlinked = previous != null,
        .previous = previous,
    };
}

fn clearProjectHerdrLink(self: anytype, project_index: usize) void {
    var project = &self.project_controller.projects.items[project_index];
    if (project.herdr_link) |*link| {
        link.deinit(self.allocator);
        project.herdr_link = null;
    }
}

fn openLinkedHerdrWorkspaceTerminalFromUi(self: anytype, project_index: usize) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    const link = project.herdr_link orelse {
        self.setSidebarNotice("Workspace is not linked to Herdr.");
        return false;
    };
    const request: herdr.OpenRequest = .{
        .session = link.session_name,
        .herdr_workspace = link.workspace_id,
        .remote = if (link.remote_alias.len > 0) link.remote_alias else null,
        .cwd = if (link.remote_alias.len == 0) project.path else null,
        .remote_cwd = link.remote_cwd,
        .local_dir = project.path,
        .pane = link.last_pane_id,
    };
    const attach = ensureHerdrAttachTerminal(self, project_index, request) catch |err| {
        self.setSidebarNotice(herdrUiFailureMessage(err));
        return false;
    };
    replaceProjectHerdrLink(self, project_index, request, project.path, attach.dock_id, attach.pane_id) catch |err| {
        self.setSidebarNotice(herdrUiFailureMessage(err));
        return false;
    };
    self.syncRenameBuffer();
    self.setSidebarNotice("Herdr terminal opened.");
    self.markDirty();
    return true;
}

pub fn herdrUiFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.HerdrCommandFailed => "Herdr command failed. Check Herdr is installed/running.",
        error.InvalidHerdrResponse => "Herdr returned an unexpected response.",
        error.NoProjectSelected => "Workspace not found.",
        error.MissingHerdrSession => "Herdr session name is required.",
        else => "Herdr action failed.",
    };
}

fn handoffProjectToHerdr(self: anytype, project_index: usize, request: herdr.HandoffRequest) !HerdrHandoffWorkspaceResult {
    if (project_index >= self.project_controller.projects.items.len) return error.NoProjectSelected;
    var project = &self.project_controller.projects.items[project_index];
    const existing_link = project.herdr_link;
    const remote_alias = request.remote orelse if (existing_link) |link| link.remote_alias else "";
    const session_name = if (existing_link) |link| link.session_name else request.session;
    var default_remote_cwd: ?[]u8 = null;
    defer if (default_remote_cwd) |cwd| self.allocator.free(cwd);
    const remote_cwd = if (remote_alias.len > 0) blk: {
        if (request.remote_cwd) |cwd| break :blk cwd;
        if (existing_link) |link| {
            if (link.remote_cwd) |cwd| {
                // Earlier builds used the local project path as the
                // implicit remote cwd. Treat that as unset so existing
                // links migrate to Verde's remote workspace area.
                if (!std.mem.eql(u8, cwd, project.path)) break :blk cwd;
            }
        }
        default_remote_cwd = try herdr.defaultRemoteCwd(self.allocator, project.label, project.id);
        break :blk default_remote_cwd.?;
    } else null;
    const herdr_cwd = remote_cwd orelse project.path;

    if (request.dry_run) {
        const workspace_id = if (existing_link) |link| link.workspace_id else "(new)";
        return .{
            .workspace_index = project_index,
            .workspace_id = project.id,
            .label = project.label,
            .path = project.path,
            .remote = remote_alias,
            .session = session_name,
            .herdr_workspace = workspace_id,
            .herdr_tab = null,
            .created = existing_link == null,
            .pane_count = project.workspace_layout.visiblePaneCount(),
        };
    }

    const target: herdr.CliTarget = .{
        .session = session_name,
        .remote = if (remote_alias.len > 0) remote_alias else null,
    };
    if (remote_alias.len > 0) try ensureHerdrRemoteCwd(self, target, herdr_cwd);
    var workspace = if (existing_link) |link|
        try createHerdrMirrorTab(self, target, link.workspace_id, project.label, herdr_cwd)
    else
        try createHerdrWorkspace(self, target, project.label, herdr_cwd);
    defer workspace.deinit(self.allocator);

    var next_links: std.ArrayList(HerdrPaneLink) = .empty;
    var next_links_owned = true;
    errdefer if (next_links_owned) {
        for (next_links.items) |*pane_link| pane_link.deinit(self.allocator);
        next_links.deinit(self.allocator);
    };

    if (project.workspace_layout.root) |root_node| {
        try mirrorHerdrNode(self, project_index, target, root_node, workspace.root_pane_id, workspace.tab_id, herdr_cwd, &next_links);
    }

    const open_request: herdr.OpenRequest = .{
        .session = session_name,
        .herdr_workspace = workspace.workspace_id,
        .remote = if (remote_alias.len > 0) remote_alias else null,
        .cwd = if (remote_alias.len == 0) project.path else null,
        .remote_cwd = remote_cwd,
        .local_dir = project.path,
        .pane = workspace.root_pane_id,
    };
    try replaceProjectHerdrLink(self, project_index, open_request, project.path, null, null);
    project = &self.project_controller.projects.items[project_index];
    if (project.herdr_link) |*link| {
        link.replacePaneLinks(self.allocator, &next_links);
        next_links_owned = false;
    }
    const final_link = project.herdr_link.?;

    return .{
        .workspace_index = project_index,
        .workspace_id = project.id,
        .label = project.label,
        .path = project.path,
        .remote = final_link.remote_alias,
        .session = final_link.session_name,
        .herdr_workspace = final_link.workspace_id,
        .herdr_tab = null,
        .created = workspace.created,
        .pane_count = final_link.pane_links.items.len,
    };
}

const HerdrWorkspaceBootstrap = struct {
    workspace_id: []u8,
    tab_id: ?[]u8 = null,
    root_pane_id: []u8,
    created: bool,

    fn deinit(self: *HerdrWorkspaceBootstrap, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        if (self.tab_id) |tab_id| allocator.free(tab_id);
        allocator.free(self.root_pane_id);
    }
};

fn createHerdrWorkspace(self: anytype, target: herdr.CliTarget, label: []const u8, cwd: []const u8) !HerdrWorkspaceBootstrap {
    const cli_args = [_][]const u8{ "workspace", "create", "--cwd", cwd, "--label", label, "--no-focus" };
    const result = try runHerdrCli(self, target, &cli_args);
    defer freeHerdrRunResult(self, result);
    try ensureHerdrCliSuccess(self, result, "workspace create");
    return .{
        .workspace_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "workspace_id"),
        .tab_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "tab_id"),
        .root_pane_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "pane_id"),
        .created = true,
    };
}

fn createHerdrMirrorTab(self: anytype, target: herdr.CliTarget, workspace_id: []const u8, label: []const u8, cwd: []const u8) !HerdrWorkspaceBootstrap {
    const tab_label = try std.fmt.allocPrint(self.allocator, "Verde: {s}", .{label});
    defer self.allocator.free(tab_label);
    const cli_args = [_][]const u8{ "tab", "create", "--workspace", workspace_id, "--cwd", cwd, "--label", tab_label, "--no-focus" };
    const result = try runHerdrCli(self, target, &cli_args);
    defer freeHerdrRunResult(self, result);
    try ensureHerdrCliSuccess(self, result, "tab create");
    return .{
        .workspace_id = try self.allocator.dupe(u8, workspace_id),
        .tab_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "tab_id"),
        .root_pane_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "pane_id"),
        .created = false,
    };
}

fn mirrorHerdrNode(
    self: anytype,
    project_index: usize,
    target: herdr.CliTarget,
    node: *const WorkspaceNode,
    herdr_pane_id: []const u8,
    herdr_tab_id: ?[]const u8,
    cwd: []const u8,
    links: *std.ArrayList(HerdrPaneLink),
) !void {
    switch (node.*) {
        .leaf => |verde_pane_id| try configureHerdrPaneForVerdePane(self, project_index, target, verde_pane_id, herdr_tab_id, herdr_pane_id, cwd, links),
        .split => |split| {
            const ratio_text = try std.fmt.allocPrint(self.allocator, "{d}", .{std.math.clamp(split.ratio, 0.05, 0.95)});
            defer self.allocator.free(ratio_text);
            const direction = switch (split.axis) {
                .vertical => "right",
                .horizontal => "down",
            };
            const cli_args = [_][]const u8{ "pane", "split", herdr_pane_id, "--direction", direction, "--ratio", ratio_text, "--cwd", cwd, "--no-focus" };
            const result = try runHerdrCli(self, target, &cli_args);
            defer freeHerdrRunResult(self, result);
            try ensureHerdrCliSuccess(self, result, "pane split");
            const second_pane_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "pane_id");
            defer self.allocator.free(second_pane_id);
            try mirrorHerdrNode(self, project_index, target, split.first, herdr_pane_id, herdr_tab_id, cwd, links);
            try mirrorHerdrNode(self, project_index, target, split.second, second_pane_id, herdr_tab_id, cwd, links);
        },
    }
}

fn configureHerdrPaneForVerdePane(
    self: anytype,
    project_index: usize,
    target: herdr.CliTarget,
    verde_pane_id: WorkspacePaneId,
    herdr_tab_id: ?[]const u8,
    herdr_pane_id: []const u8,
    default_cwd: []const u8,
    links: *std.ArrayList(HerdrPaneLink),
) !void {
    const project = &self.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(verde_pane_id) orelse return;

    const descriptor = try herdrPaneDescriptor(self, project_index, pane, default_cwd);
    defer descriptor.deinit(self.allocator);
    var link = try HerdrPaneLink.init(
        self.allocator,
        verde_pane_id,
        herdr_tab_id,
        herdr_pane_id,
        descriptor.provider,
        descriptor.presentation,
        descriptor.provider_thread_id,
        null,
        descriptor.cwd,
        descriptor.title,
    );
    errdefer link.deinit(self.allocator);
    try links.append(self.allocator, link);

    try renameHerdrPane(self, target, herdr_pane_id, descriptor.title);
    if (descriptor.command) |command| try runHerdrPaneCommand(self, target, herdr_pane_id, command);
}

const HerdrPaneDescriptor = struct {
    provider: HerdrPaneProvider,
    presentation: HerdrPanePresentation,
    provider_thread_id: ?[]const u8 = null,
    cwd: []const u8,
    title: []u8,
    command: ?[]u8 = null,

    fn deinit(self: HerdrPaneDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.command) |command| allocator.free(command);
    }
};

fn herdrPaneDescriptor(self: anytype, project_index: usize, pane: *const WorkspacePane, default_cwd: []const u8) !HerdrPaneDescriptor {
    const project = &self.project_controller.projects.items[project_index];
    return switch (pane.ref) {
        .chat => |chat_ref| blk: {
            const maybe_thread = if (chat_ref.thread_index < project.threads.items.len) &project.threads.items[chat_ref.thread_index] else null;
            const provider = if (maybe_thread) |thread| herdrPaneProviderForThreadProvider(thread.provider) else .unknown;
            const thread_title = if (maybe_thread) |thread| thread.title else "Chat";
            const title = try std.fmt.allocPrint(self.allocator, "{s} GUI", .{thread_title});
            errdefer self.allocator.free(title);
            const provider_thread_id = if (maybe_thread) |thread| thread.provider_thread_id else null;
            const command = try herdrAgentCommandForProvider(self.allocator, provider, provider_thread_id);
            break :blk .{
                .provider = provider,
                .presentation = .gui_chat,
                .provider_thread_id = provider_thread_id,
                .cwd = default_cwd,
                .title = title,
                .command = command,
            };
        },
        .terminal => |terminal_ref| blk: {
            const dock = self.projectTerminalDock(project_index, terminal_ref.dock_id);
            const cwd = if (dock) |value| value.cwd orelse default_cwd else default_cwd;
            const title = try std.fmt.allocPrint(self.allocator, "Terminal {d}", .{terminal_ref.dock_id});
            break :blk .{ .provider = .terminal, .presentation = .terminal, .cwd = cwd, .title = title };
        },
        .browser => |browser_ref| blk: {
            const tab = browser_ref.activeTabConst();
            const label = if (tab) |active| active.title orelse active.url orelse "Browser" else "Browser";
            const title = try std.fmt.allocPrint(self.allocator, "Browser: {s}", .{label});
            break :blk .{ .provider = .browser, .presentation = .browser_link, .cwd = default_cwd, .title = title };
        },
    };
}

fn herdrHandoffProjectIndex(self: anytype, selector: []const u8) ?usize {
    if (std.mem.eql(u8, selector, "current")) return self.project_controller.selected_index;
    if (std.fmt.parseInt(usize, selector, 10)) |index| {
        if (index < self.project_controller.projects.items.len) return index;
    } else |_| {}
    for (self.project_controller.projects.items, 0..) |project, index| {
        if (std.mem.eql(u8, project.id, selector) or
            self.projectPathMatches(project.path, selector) or
            std.mem.eql(u8, project.label, selector)) return index;
    }
    return null;
}

fn runHerdrCli(self: anytype, target: herdr.CliTarget, cli_args: []const []const u8) !std.process.RunResult {
    var threaded: std.Io.Threaded = .init(self.allocator, .{});
    defer threaded.deinit();
    return try herdr.runCli(self.allocator, threaded.io(), target, cli_args, 512 * 1024);
}

fn ensureHerdrRemoteCwd(self: anytype, target: herdr.CliTarget, cwd: []const u8) !void {
    const remote = target.remote orelse return;
    const command = try herdr.remoteMkdirCommandLineAlloc(self.allocator, cwd);
    defer self.allocator.free(command);
    var threaded: std.Io.Threaded = .init(self.allocator, .{});
    defer threaded.deinit();
    const result = try herdr.runRemoteShell(self.allocator, threaded.io(), remote, .{ .bytes = command }, 64 * 1024);
    defer freeHerdrRunResult(self, result);
    try ensureHerdrCliSuccess(self, result, "remote mkdir");
}

fn remoteCwdForWorkspaceCwd(self: anytype, project: *const Project, cwd: []const u8) ![]u8 {
    const link = project.herdr_link orelse return error.WorkspaceNotRemote;
    const base = link.remote_cwd orelse return error.MissingRemoteCwd;
    const trimmed = std.mem.trim(u8, cwd, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, project.path)) {
        return try self.allocator.dupe(u8, base);
    }
    if (std.mem.startsWith(u8, trimmed, project.path) and trimmed.len > project.path.len and trimmed[project.path.len] == std.fs.path.sep) {
        return try std.fs.path.join(self.allocator, &.{ base, trimmed[project.path.len + 1 ..] });
    }
    if (std.fs.path.isAbsolute(trimmed)) return try self.allocator.dupe(u8, trimmed);
    return try std.fs.path.join(self.allocator, &.{ base, trimmed });
}

fn commandArgsForTerminalProfile(profile: terminal.TerminalLaunchProfile) ?[]const []const u8 {
    if (profile.command.len > 0) return profile.command;
    return switch (profile.kind) {
        .shell => null,
        .claude => &.{"claude"},
        .opencode => &.{"opencode"},
        .codex => &.{"codex"},
        .cursor => &.{"cursor"},
        .custom => &.{},
    };
}

fn remoteTerminalLabel(link: HerdrWorkspaceLink, profile: terminal.TerminalLaunchProfile, buffer: []u8) []const u8 {
    const label = std.mem.trim(u8, profile.label, &std.ascii.whitespace);
    if (label.len > 0) return label;
    return std.fmt.bufPrint(buffer, "Remote {s}", .{link.remote_alias}) catch "Remote terminal";
}

fn remoteCommandForTerminalProfile(
    self: anytype,
    project: *const Project,
    profile: terminal.TerminalLaunchProfile,
    cwd: []const u8,
) ![]u8 {
    const link = project.herdr_link orelse return error.WorkspaceNotRemote;
    if (link.remote_alias.len == 0) return error.WorkspaceNotRemote;
    const remote_cwd = try remoteCwdForWorkspaceCwd(self, project, cwd);
    defer self.allocator.free(remote_cwd);
    if (commandArgsForTerminalProfile(profile)) |args| {
        return try herdr.remoteExecCommandLineAlloc(self.allocator, remote_cwd, args);
    }
    return try herdr.remoteLoginShellCommandLineAlloc(self.allocator, remote_cwd);
}

pub fn restartTerminalDockForWorkspaceProfile(
    self: anytype,
    project_index: usize,
    dock_id: u32,
    cwd: []const u8,
    profile: terminal.TerminalLaunchProfile,
) !void {
    if (project_index >= self.project_controller.projects.items.len) return error.NoProjectSelected;
    const project = &self.project_controller.projects.items[project_index];
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return error.NoProjectSelected;
    if (project.herdr_link) |link| {
        if (link.remote_alias.len > 0) {
            const remote_command = try remoteCommandForTerminalProfile(self, project, profile, cwd);
            defer self.allocator.free(remote_command);
            var label_buf: [160]u8 = undefined;
            const label = remoteTerminalLabel(link, profile, &label_buf);
            const command_args = [_][]const u8{ "ssh", "-tt", link.remote_alias, remote_command };
            try dock.restartWithProfilePersistent(self.allocator, project.path, .{
                .kind = .custom,
                .label = label,
                .command = &command_args,
            }, self.storage.pref_path, dock_id);
            return;
        }
    }
    try dock.restartWithProfilePersistent(self.allocator, cwd, profile, self.storage.pref_path, dock_id);
}

pub fn restartTerminalDockForWorkspace(self: anytype, project_index: usize, dock_id: u32) !void {
    if (project_index >= self.project_controller.projects.items.len) return error.NoProjectSelected;
    const project = &self.project_controller.projects.items[project_index];
    try restartTerminalDockForWorkspaceProfile(self, project_index, dock_id, project.path, .{});
}

pub fn createTerminalTabForWorkspaceProfile(
    self: anytype,
    project_index: usize,
    dock_id: u32,
    profile: terminal.TerminalLaunchProfile,
) !void {
    if (project_index >= self.project_controller.projects.items.len) return error.NoProjectSelected;
    const project = &self.project_controller.projects.items[project_index];
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return error.NoProjectSelected;
    if (project.herdr_link) |link| {
        if (link.remote_alias.len > 0) {
            const cwd = dock.cwd orelse project.path;
            const remote_command = try remoteCommandForTerminalProfile(self, project, profile, cwd);
            defer self.allocator.free(remote_command);
            var label_buf: [160]u8 = undefined;
            const label = remoteTerminalLabel(link, profile, &label_buf);
            const command_args = [_][]const u8{ "ssh", "-tt", link.remote_alias, remote_command };
            try dock.createTabWithProfile(self.allocator, .{
                .kind = .custom,
                .label = label,
                .command = &command_args,
            });
            return;
        }
    }
    if (profile.kind == .shell and profile.label.len == 0 and profile.command.len == 0) {
        try dock.createTab(self.allocator);
    } else {
        try dock.createTabWithProfile(self.allocator, profile);
    }
}

fn freeHerdrRunResult(self: anytype, result: std.process.RunResult) void {
    self.allocator.free(result.stdout);
    self.allocator.free(result.stderr);
}

fn ensureHerdrCliSuccess(self: anytype, result: std.process.RunResult, action: []const u8) !void {
    _ = self;
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    log.warn("Herdr CLI {s} failed stderr_len={d}", .{ action, result.stderr.len });
    return error.HerdrCommandFailed;
}

fn renameHerdrPane(self: anytype, target: herdr.CliTarget, pane_id: []const u8, title: []const u8) !void {
    const cli_args = [_][]const u8{ "pane", "rename", pane_id, title };
    const result = try runHerdrCli(self, target, &cli_args);
    defer freeHerdrRunResult(self, result);
    try ensureHerdrCliSuccess(self, result, "pane rename");
}

fn runHerdrPaneCommand(self: anytype, target: herdr.CliTarget, pane_id: []const u8, command: []const u8) !void {
    const cli_args = [_][]const u8{ "pane", "run", pane_id, command };
    const result = try runHerdrCli(self, target, &cli_args);
    defer freeHerdrRunResult(self, result);
    try ensureHerdrCliSuccess(self, result, "pane run");
}

const HerdrAttachPane = struct {
    dock_id: u32,
    pane_id: WorkspacePaneId,
};

fn ensureHerdrAttachTerminal(self: anytype, project_index: usize, request: herdr.OpenRequest) !HerdrAttachPane {
    if (project_index >= self.project_controller.projects.items.len) return error.NoProjectSelected;
    var project = &self.project_controller.projects.items[project_index];
    if (project.herdr_link) |link| {
        if (link.attach_dock_id) |dock_id| {
            if (self.projectTerminalDockMutable(project_index, dock_id)) |dock| {
                const pane_id = link.attach_pane_id orelse project.workspace_layout.visibleTerminalPaneIdForDock(dock_id);
                if (pane_id) |id| {
                    if (project.workspace_layout.paneById(id) != null) {
                        if (!dock.hasRunningSession()) try restartHerdrAttachDock(self, project_index, dock_id, request);
                        project = &self.project_controller.projects.items[project_index];
                        project.workspace_layout.focused_pane_id = id;
                        project.workspace_layout.maximized_pane_id = null;
                        self.requestTerminalDockFocus(dock_id);
                        return .{ .dock_id = dock_id, .pane_id = id };
                    }
                }
            }
        }
    }

    const dock_id = try self.createProjectTerminalDock(project_index);
    try restartHerdrAttachDock(self, project_index, dock_id, request);
    if (replaceOnlyDraftChatPaneWithTerminal(self, project_index, dock_id)) |pane_id| {
        self.requestTerminalDockFocus(dock_id);
        return .{ .dock_id = dock_id, .pane_id = pane_id };
    }

    project = &self.project_controller.projects.items[project_index];
    const pane_id = try project.workspace_layout.ensureTerminalPane(self.allocator, dock_id);
    project.workspace_layout.focusCreatedPane(pane_id);
    self.requestTerminalDockFocus(dock_id);
    return .{ .dock_id = dock_id, .pane_id = pane_id };
}

fn restartHerdrAttachDock(self: anytype, project_index: usize, dock_id: u32, request: herdr.OpenRequest) !void {
    const project = &self.project_controller.projects.items[project_index];
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return error.NoProjectSelected;
    const remote_alias = herdr.remoteAlias(request);
    const label = if (remote_alias.len > 0)
        try std.fmt.allocPrint(self.allocator, "Herdr {s}@{s}", .{ request.session, remote_alias })
    else
        try std.fmt.allocPrint(self.allocator, "Herdr {s}", .{request.session});
    defer self.allocator.free(label);

    if (remote_alias.len > 0) {
        const remote_command = try herdr.remoteHerdrCommandLineAlloc(self.allocator, request.session, &.{});
        defer self.allocator.free(remote_command);
        // Herdr's ratatui frontend opens the remote TTY directly; without
        // forced allocation it can panic with ENXIO even though Verde's
        // local side is already a PTY.
        const command_args = [_][]const u8{ "ssh", "-tt", remote_alias, remote_command };
        try dock.restartWithProfilePersistent(self.allocator, project.path, .{
            .kind = .custom,
            .label = label,
            .command = &command_args,
        }, self.storage.pref_path, dock_id);
    } else {
        const command_args = [_][]const u8{ "herdr", "--session", request.session };
        try dock.restartWithProfilePersistent(self.allocator, project.path, .{
            .kind = .custom,
            .label = label,
            .command = &command_args,
        }, self.storage.pref_path, dock_id);
    }
    dock.visible = false;
}

fn replaceOnlyDraftChatPaneWithTerminal(self: anytype, project_index: usize, dock_id: u32) ?WorkspacePaneId {
    var project = &self.project_controller.projects.items[project_index];
    var layout = &project.workspace_layout;
    if (layout.panes.items.len != 1) return null;
    var pane = &layout.panes.items[0];
    switch (pane.ref) {
        .chat => |chat_ref| {
            if (chat_ref.thread_index >= project.threads.items.len) return null;
            const thread = &project.threads.items[chat_ref.thread_index];
            if (thread.committed or thread.messages.items.len > 0 or thread.currentDraft().len > 0) return null;
            deinitWorkspacePaneRef(&pane.ref, self.allocator);
            pane.ref = .{ .terminal = .{ .dock_id = dock_id } };
            layout.focusCreatedPane(pane.id);
            return pane.id;
        },
        else => return null,
    }
}

fn replaceProjectHerdrLink(
    self: anytype,
    project_index: usize,
    request: herdr.OpenRequest,
    local_dir: []const u8,
    attach_dock_id: ?u32,
    attach_pane_id: ?WorkspacePaneId,
) !void {
    var project = &self.project_controller.projects.items[project_index];
    const existing_dock_id = attach_dock_id orelse if (project.herdr_link) |link| link.attach_dock_id else null;
    const existing_pane_id = attach_pane_id orelse if (project.herdr_link) |link| link.attach_pane_id else null;
    var next = try HerdrWorkspaceLink.init(
        self.allocator,
        herdr.remoteAlias(request),
        request.session,
        request.herdr_workspace,
        local_dir,
        request.remote_cwd,
        request.pane,
        existing_dock_id,
        existing_pane_id,
    );
    errdefer next.deinit(self.allocator);
    if (project.herdr_link) |*old| {
        // `verde herdr open` is often a focus/pickup operation; preserve
        // pane presentation metadata so returning from Herdr still knows
        // which panes should come back as GUI chat versus terminal/TUI.
        if (herdrLinkMatchesRequest(old.*, request)) {
            next.pane_links = old.pane_links;
            old.pane_links = .empty;
        }
        old.deinit(self.allocator);
    }
    project.herdr_link = next;
}

fn findHerdrProjectIndex(self: anytype, request: herdr.OpenRequest) ?usize {
    for (self.project_controller.projects.items, 0..) |project, index| {
        const link = project.herdr_link orelse continue;
        if (herdrLinkMatchesRequest(link, request)) return index;
    }
    return null;
}

fn herdrLinkMatchesRequest(link: HerdrWorkspaceLink, request: herdr.OpenRequest) bool {
    return std.mem.eql(u8, link.remote_alias, herdr.remoteAlias(request)) and
        std.mem.eql(u8, link.session_name, request.session) and
        std.mem.eql(u8, link.workspace_id, request.herdr_workspace);
}

fn resolveHerdrLocalProjectDir(self: anytype, request: herdr.OpenRequest) ![]u8 {
    if (request.local_dir) |local_dir| return try self.ensureDirectoryPath(local_dir);
    if (herdr.remoteAlias(request).len > 0) {
        const default_dir = try herdr.defaultLocalDir(self.allocator, self.storage.pref_path, request);
        defer self.allocator.free(default_dir);
        return try self.ensureDirectoryPath(default_dir);
    }
    if (request.cwd) |cwd| return try self.resolveProjectPath(cwd);
    const default_dir = try herdr.defaultLocalDir(self.allocator, self.storage.pref_path, request);
    defer self.allocator.free(default_dir);
    return try self.ensureDirectoryPath(default_dir);
}
