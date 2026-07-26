//! Project aggregate ownership, terminal docks, managed processes, and leases.

const std = @import("std");
const builtin = @import("builtin");
const app_config = @import("../config.zig");
const chat_threads = @import("../chat/threads.zig");
const stack_config = @import("../stack.zig");
const terminal = @import("../terminal/terminal.zig");
const chat_types = @import("chat_types.zig");
const herdr_types = @import("herdr_types.zig");
const provider_models = @import("provider_models.zig");
const workspace_layout = @import("workspace_layout.zig");

const ChatRole = provider_models.ChatRole;
const Provider = provider_models.Provider;
const Harness = provider_models.Harness;
const ChatThread = chat_types.ChatThread;
const HerdrWorkspaceLink = herdr_types.HerdrWorkspaceLink;
const WorkspaceLayout = workspace_layout.WorkspaceLayout;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;

pub const TerminalDockEntry = struct {
    id: u32,
    dock: terminal.Dock,

    pub fn deinit(self: *TerminalDockEntry, allocator: std.mem.Allocator) void {
        self.dock.deinit(allocator);
    }
};

pub const ManagedProcessStatus = enum {
    stopped,
    starting,
    running,
    stopping,
    crashed,
    restarting,
};

pub const ManagedProcess = struct {
    name: []u8,
    kind: stack_config.ProcessKind,
    command: []u8,
    argv: std.ArrayList([]u8) = .empty,
    cwd: []u8,
    restart: stack_config.RestartPolicy,
    provider: ?stack_config.AgentProvider = null,
    revive: stack_config.RevivePolicy = .attach_or_create,
    notify: bool = false,
    mcp: bool = false,
    hooks: bool = false,
    watch: std.ArrayList([]u8) = .empty,
    resources: std.ArrayList([]u8) = .empty,
    status: ManagedProcessStatus = .stopped,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
    last_start_ms: i64 = 0,
    last_exit_ms: i64 = 0,
    next_restart_ms: i64 = 0,
    restart_count: u32 = 0,
    watch_trigger_count: u32 = 0,
    last_watch_scan_ms: i64 = 0,
    last_watch_change_ms: i64 = 0,
    pending_watch_restart_ms: i64 = 0,
    watch_signature: u64 = 0,
    watch_ready: bool = false,
    watch_error_count: u32 = 0,
    dock_id: ?u32 = null,
    pane_id: ?WorkspacePaneId = null,
    explicit_stop: bool = false,

    pub fn initFromDefinition(allocator: std.mem.Allocator, definition: stack_config.ProcessDefinition) !ManagedProcess {
        const launch = definition.launchForOs(builtin.os.tag) orelse return error.ManagedProcessUnavailableOnPlatform;
        var process: ManagedProcess = .{
            .name = try allocator.dupe(u8, definition.name),
            .kind = definition.kind,
            .command = try allocator.dupe(u8, if (launch == .command) launch.command else ""),
            .argv = .empty,
            .cwd = try allocator.dupe(u8, definition.cwd),
            .restart = definition.restart,
            .provider = definition.provider,
            .revive = definition.revive,
            .notify = definition.notify,
            .mcp = definition.mcp,
            .hooks = definition.hooks,
            .watch = .empty,
            .resources = .empty,
        };
        errdefer process.deinit(allocator);
        if (launch == .argv) {
            for (launch.argv) |arg| try appendOwnedString(allocator, &process.argv, arg);
        }
        for (definition.watch.items) |pattern| {
            try appendOwnedString(allocator, &process.watch, pattern);
        }
        for (definition.resources.items) |resource| {
            try appendOwnedString(allocator, &process.resources, resource);
        }
        return process;
    }

    pub fn updateFromDefinition(self: *ManagedProcess, allocator: std.mem.Allocator, definition: stack_config.ProcessDefinition) !void {
        const launch = definition.launchForOs(builtin.os.tag) orelse return error.ManagedProcessUnavailableOnPlatform;
        self.kind = definition.kind;
        self.restart = definition.restart;
        self.provider = definition.provider;
        self.revive = definition.revive;
        self.notify = definition.notify;
        self.mcp = definition.mcp;
        self.hooks = definition.hooks;
        var reset_watch_state = false;
        const next_command = if (launch == .command) launch.command else "";
        const next_argv = if (launch == .argv) launch.argv else &.{};
        if (!std.mem.eql(u8, self.command, next_command) or !argvEqual(self.argv.items, next_argv)) {
            const replacement_command = try allocator.dupe(u8, next_command);
            errdefer allocator.free(replacement_command);
            var replacement_argv: std.ArrayList([]u8) = .empty;
            errdefer deinitOwnedArgv(allocator, &replacement_argv);
            for (next_argv) |arg| try appendOwnedString(allocator, &replacement_argv, arg);

            allocator.free(self.command);
            deinitOwnedArgv(allocator, &self.argv);
            self.command = replacement_command;
            self.argv = replacement_argv;
        }
        if (!std.mem.eql(u8, self.cwd, definition.cwd)) {
            allocator.free(self.cwd);
            self.cwd = try allocator.dupe(u8, definition.cwd);
            reset_watch_state = true;
        }
        if (!watchPatternsEqual(self.watch.items, definition.watch.items)) reset_watch_state = true;
        for (self.watch.items) |pattern| allocator.free(pattern);
        self.watch.clearRetainingCapacity();
        for (definition.watch.items) |pattern| {
            try appendOwnedString(allocator, &self.watch, pattern);
        }
        for (self.resources.items) |resource| allocator.free(resource);
        self.resources.clearRetainingCapacity();
        for (definition.resources.items) |resource| {
            try appendOwnedString(allocator, &self.resources, resource);
        }
        if (reset_watch_state) self.resetWatchState();
    }

    pub fn deinit(self: *ManagedProcess, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        deinitOwnedArgv(allocator, &self.argv);
        allocator.free(self.cwd);
        for (self.watch.items) |pattern| allocator.free(pattern);
        self.watch.deinit(allocator);
        for (self.resources.items) |resource| allocator.free(resource);
        self.resources.deinit(allocator);
    }

    pub fn resetWatchState(self: *ManagedProcess) void {
        self.watch_signature = 0;
        self.watch_ready = false;
        self.last_watch_scan_ms = 0;
        self.last_watch_change_ms = 0;
        self.pending_watch_restart_ms = 0;
        self.watch_error_count = 0;
    }

    pub fn watchPatternsEqual(left: []const []u8, right: []const []u8) bool {
        if (left.len != right.len) return false;
        for (left, right) |l, r| {
            if (!std.mem.eql(u8, l, r)) return false;
        }
        return true;
    }

    pub fn argvEqual(left: []const []u8, right: []const []u8) bool {
        if (left.len != right.len) return false;
        for (left, right) |l, r| {
            if (!std.mem.eql(u8, l, r)) return false;
        }
        return true;
    }

    pub fn deinitOwnedArgv(allocator: std.mem.Allocator, argv: *std.ArrayList([]u8)) void {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
};

/// An expiring, workspace-scoped claim on resources shared by agents and
/// commands. Leases are intentionally not persisted: expiration handles
/// crashed owners, while a Verde restart must never leave a stale blocker.
pub const WorkspaceLease = struct {
    id: []u8,
    owner: []u8,
    command: []u8,
    resources: std.ArrayList([]u8) = .empty,
    created_at_ms: i64,
    expires_at_ms: i64,

    pub fn deinit(self: *WorkspaceLease, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.owner);
        allocator.free(self.command);
        for (self.resources.items) |resource| allocator.free(resource);
        self.resources.deinit(allocator);
    }
};

pub const Project = struct {
    id: [:0]const u8,
    label: [:0]const u8,
    path: [:0]const u8,
    herdr_link: ?HerdrWorkspaceLink = null,
    archived: bool = false,
    unread_count: u8 = 0,
    collapsed: bool = false,
    thread_list_expanded: bool = false,
    terminal_dock: terminal.Dock,
    terminal_docks: std.ArrayList(TerminalDockEntry) = .empty,
    managed_processes: std.ArrayList(ManagedProcess) = .empty,
    workspace_leases: std.ArrayList(WorkspaceLease) = .empty,
    next_workspace_lease_id: u64 = 1,
    last_stack_config_refresh_ms: i64 = 0,
    stack_config_error: ?[]u8 = null,
    next_terminal_dock_id: u32 = 1,
    workspace_layout: WorkspaceLayout,
    threads: std.ArrayList(ChatThread),
    archived_threads: std.ArrayList(ChatThread),
    selected_thread_index: usize = 0,
    /// Last chat or terminal workspace pane the user focused; used to default
    /// the inspector design-mode "Send to" target (not persisted).
    last_content_pane_id: ?WorkspacePaneId = null,
    sidebar_thread_indices: std.ArrayList(usize) = .empty,
    sidebar_committed_thread_count: usize = 0,
    sidebar_thread_cache_dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, label: []const u8, path: []const u8, unread_count: u8) !Project {
        var terminal_dock = try terminal.Dock.init(allocator);
        terminal_dock.setDefaultFontSize(app_config.DEFAULT_TERMINAL_FONT_SIZE);
        errdefer terminal_dock.deinit(allocator);
        var project: Project = .{
            .id = try allocator.dupeZ(u8, id),
            .label = try allocator.dupeZ(u8, label),
            .path = try allocator.dupeZ(u8, path),
            .herdr_link = null,
            .archived = false,
            .unread_count = unread_count,
            .collapsed = false,
            .thread_list_expanded = false,
            .terminal_dock = terminal_dock,
            .terminal_docks = .empty,
            .managed_processes = .empty,
            .workspace_leases = .empty,
            .next_workspace_lease_id = 1,
            .last_stack_config_refresh_ms = 0,
            .stack_config_error = null,
            .next_terminal_dock_id = 1,
            .workspace_layout = try WorkspaceLayout.initDefaultChat(allocator),
            .threads = .empty,
            .archived_threads = .empty,
            .selected_thread_index = 0,
            .sidebar_thread_indices = .empty,
            .sidebar_committed_thread_count = 0,
            .sidebar_thread_cache_dirty = true,
        };
        _ = try project.addThread(allocator);
        return project;
    }

    pub fn currentThreadIndex(self: *const Project) usize {
        std.debug.assert(self.threads.items.len > 0);
        return @min(self.selected_thread_index, self.threads.items.len - 1);
    }

    pub fn currentThread(self: *const Project) *const ChatThread {
        return &self.threads.items[self.currentThreadIndex()];
    }

    pub fn currentThreadMutable(self: *Project) *ChatThread {
        std.debug.assert(self.threads.items.len > 0);
        if (self.selected_thread_index >= self.threads.items.len) {
            self.selected_thread_index = self.threads.items.len - 1;
        }
        return &self.threads.items[self.selected_thread_index];
    }

    pub fn invalidateSidebarThreadCache(self: *Project) void {
        self.sidebar_thread_cache_dirty = true;
    }

    pub fn committedThreadCountCached(self: *Project, allocator: std.mem.Allocator) usize {
        self.ensureSidebarThreadCache(allocator);
        return self.sidebar_committed_thread_count;
    }

    pub fn sortedCommittedThreadIndices(self: *Project, allocator: std.mem.Allocator) []const usize {
        self.ensureSidebarThreadCache(allocator);
        return self.sidebar_thread_indices.items;
    }

    pub fn currentDraft(self: *const Project) []const u8 {
        return self.currentThread().currentDraft();
    }

    pub fn draftBuffer(self: *Project) [:0]u8 {
        return self.currentThreadMutable().draftBuffer();
    }

    pub fn setDraft(self: *Project, value: []const u8) void {
        self.currentThreadMutable().setDraft(value);
    }

    pub fn clearDraft(self: *Project) void {
        self.currentThreadMutable().clearDraft();
    }

    pub fn addThread(self: *Project, allocator: std.mem.Allocator) !usize {
        var thread = try ChatThread.init(allocator, "New thread");
        errdefer thread.deinit(allocator);
        try self.threads.append(allocator, thread);
        self.selected_thread_index = self.threads.items.len - 1;
        return self.selected_thread_index;
    }

    pub fn normalize(self: *Project, allocator: std.mem.Allocator, default_terminal_font_size: f32) !void {
        if (!self.archived and self.threads.items.len == 0) {
            _ = try self.addThread(allocator);
        }
        if (self.threads.items.len == 0) {
            self.selected_thread_index = 0;
        } else if (self.selected_thread_index >= self.threads.items.len) {
            self.selected_thread_index = self.threads.items.len - 1;
        }
        for (self.threads.items) |*thread| {
            chat_threads.sanitizeEnum(Provider, &thread.provider, .opencode);
            chat_threads.sanitizeEnum(Harness, &thread.harness, .local_cli);
            for (thread.messages.items) |*message| {
                chat_threads.sanitizeEnum(ChatRole, &message.role, .user);
            }
        }
        for (self.archived_threads.items) |*thread| {
            chat_threads.sanitizeEnum(Provider, &thread.provider, .opencode);
            chat_threads.sanitizeEnum(Harness, &thread.harness, .local_cli);
            for (thread.messages.items) |*message| {
                chat_threads.sanitizeEnum(ChatRole, &message.role, .user);
            }
        }
        if (self.threads.items.len > 0) {
            const fallback_thread_index = @min(self.selected_thread_index, self.threads.items.len - 1);
            for (self.workspace_layout.panes.items) |*pane| {
                switch (pane.ref) {
                    .chat => |*ref| {
                        if (ref.thread_index >= self.threads.items.len) ref.thread_index = fallback_thread_index;
                    },
                    else => {},
                }
            }
        }
        try self.ensureTerminalDocksForWorkspace(allocator, default_terminal_font_size);
    }

    pub fn ensureTerminalDocksForWorkspace(self: *Project, allocator: std.mem.Allocator, default_terminal_font_size: f32) !void {
        const max_dock_id = self.workspace_layout.maxTerminalDockId();
        var dock_id: u32 = 1;
        while (dock_id <= max_dock_id) : (dock_id += 1) {
            if (self.terminalDockEntryById(dock_id) != null) continue;
            var dock = try terminal.Dock.init(allocator);
            dock.setDefaultFontSize(default_terminal_font_size);
            errdefer dock.deinit(allocator);
            try self.terminal_docks.append(allocator, .{ .id = dock_id, .dock = dock });
        }
        if (self.next_terminal_dock_id <= max_dock_id) self.next_terminal_dock_id = max_dock_id + 1;
    }

    pub fn applyDefaultTerminalFontSize(self: *Project, font_size: f32) void {
        self.terminal_dock.setDefaultFontSize(font_size);
        for (self.terminal_docks.items) |*entry| {
            entry.dock.setDefaultFontSize(font_size);
        }
    }

    pub fn terminalDockEntryById(self: *Project, dock_id: u32) ?*TerminalDockEntry {
        for (self.terminal_docks.items) |*entry| {
            if (entry.id == dock_id) return entry;
        }
        return null;
    }

    pub fn managedProcessByName(self: *Project, name: []const u8) ?*ManagedProcess {
        for (self.managed_processes.items) |*process| {
            if (std.mem.eql(u8, process.name, name)) return process;
        }
        return null;
    }

    pub fn clearManagedProcesses(self: *Project, allocator: std.mem.Allocator) void {
        for (self.managed_processes.items) |*process| {
            self.terminateManagedProcessSession(process);
            process.deinit(allocator);
        }
        self.managed_processes.clearRetainingCapacity();
    }

    pub fn terminateManagedProcessSession(self: *Project, process: *ManagedProcess) void {
        const dock_id = process.dock_id orelse return;
        const entry = self.terminalDockEntryById(dock_id) orelse return;
        _ = entry.dock.terminateActiveSession();
        process.status = .stopped;
        process.explicit_stop = true;
        process.next_restart_ms = 0;
        process.pending_watch_restart_ms = 0;
    }

    pub fn managedProcessByDockId(self: *Project, dock_id: u32) ?*ManagedProcess {
        for (self.managed_processes.items) |*process| {
            if (process.dock_id != null and process.dock_id.? == dock_id) return process;
        }
        return null;
    }

    pub fn removeTerminalDockById(self: *Project, allocator: std.mem.Allocator, dock_id: u32) bool {
        for (self.terminal_docks.items, 0..) |*entry, index| {
            if (entry.id != dock_id) continue;
            if (self.managedProcessByDockId(dock_id)) |process| {
                process.dock_id = null;
                process.pane_id = null;
                process.status = .stopped;
                process.explicit_stop = true;
                process.next_restart_ms = 0;
                process.pending_watch_restart_ms = 0;
            }
            entry.deinit(allocator);
            _ = self.terminal_docks.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn committedThreadCount(self: *const Project) usize {
        var count: usize = 0;
        for (self.threads.items) |thread| {
            if (thread.committed) count += 1;
        }
        return count;
    }

    pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.path);
        if (self.herdr_link) |*link| link.deinit(allocator);
        self.terminal_dock.deinit(allocator);
        for (self.terminal_docks.items) |*entry| entry.deinit(allocator);
        self.terminal_docks.deinit(allocator);
        for (self.managed_processes.items) |*process| process.deinit(allocator);
        self.managed_processes.deinit(allocator);
        for (self.workspace_leases.items) |*lease| lease.deinit(allocator);
        self.workspace_leases.deinit(allocator);
        if (self.stack_config_error) |message| allocator.free(message);
        self.workspace_layout.deinit(allocator);
        for (self.threads.items) |*thread| {
            thread.deinit(allocator);
        }
        self.threads.deinit(allocator);
        for (self.archived_threads.items) |*thread| {
            thread.deinit(allocator);
        }
        self.archived_threads.deinit(allocator);
        self.sidebar_thread_indices.deinit(allocator);
    }

    pub fn terminateWorkspaceSessions(self: *Project) void {
        self.terminal_dock.terminateAllSessions();
        for (self.terminal_docks.items) |*entry| entry.dock.terminateAllSessions();
        for (self.managed_processes.items) |*process| {
            process.status = .stopped;
            process.explicit_stop = true;
            process.next_restart_ms = 0;
            process.pending_watch_restart_ms = 0;
        }
    }

    pub fn ensureSidebarThreadCache(self: *Project, allocator: std.mem.Allocator) void {
        if (!self.sidebar_thread_cache_dirty) return;

        self.sidebar_thread_indices.clearRetainingCapacity();
        self.sidebar_committed_thread_count = 0;

        for (self.threads.items, 0..) |thread, index| {
            if (!thread.committed) continue;
            self.sidebar_committed_thread_count += 1;
            self.sidebar_thread_indices.append(allocator, index) catch {
                self.sidebar_thread_cache_dirty = true;
                return;
            };
        }

        var i: usize = 1;
        while (i < self.sidebar_thread_indices.items.len) : (i += 1) {
            const current = self.sidebar_thread_indices.items[i];
            var j = i;
            while (j > 0) : (j -= 1) {
                const left_index = self.sidebar_thread_indices.items[j - 1];
                const left = self.threads.items[left_index];
                const right = self.threads.items[current];
                const should_move = if (left.last_activity_at != right.last_activity_at)
                    left.last_activity_at < right.last_activity_at
                else
                    left_index < current;
                if (!should_move) break;
                self.sidebar_thread_indices.items[j] = self.sidebar_thread_indices.items[j - 1];
            }
            self.sidebar_thread_indices.items[j] = current;
        }

        self.sidebar_thread_cache_dirty = false;
    }

    pub fn setStackConfigError(self: *Project, allocator: std.mem.Allocator, message: []const u8) void {
        if (self.stack_config_error) |existing| allocator.free(existing);
        self.stack_config_error = allocator.dupe(u8, message) catch null;
    }

    pub fn clearStackConfigError(self: *Project, allocator: std.mem.Allocator) void {
        if (self.stack_config_error) |existing| allocator.free(existing);
        self.stack_config_error = null;
    }
};

fn appendOwnedString(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}
