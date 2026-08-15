//! Project aggregate ownership, terminal docks, managed processes, and leases.

const std = @import("std");
const builtin = @import("builtin");
const app_config = @import("../app/config.zig");
const chat_threads = @import("../chat/threads.zig");
const stack_config = @import("../workspace/stack.zig");
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

pub const TERMINAL_PROCESS_OUTCOME_MAX: usize = 32;
pub const TERMINAL_PROCESS_OUTCOME_TTL_MS: i64 = 15 * std.time.ms_per_min;
pub const TERMINAL_PROCESS_EXIT_GRACE_MS: i64 = 250;

pub const TerminalProcessOutcomeStatus = enum {
    completed,
    failed,
    cancelled,
    crashed,
    unknown,
};

pub const TerminalProcessObservation = struct {
    process_identity: u32,
    session_id: []const u8,
    command: []const u8,
    cwd: []const u8,
    pid: ?u32 = null,
    process_group: ?u32 = null,
    started_at_ms: i64,
    observed_at_ms: i64,
    dock_id: u32,
    pane_id: ?WorkspacePaneId = null,
    owner_kind: []const u8,
    owner_title: []const u8,
    provider: ?[]const u8 = null,
};

pub const TerminalProcessFinish = struct {
    exit_code: ?u32 = null,
    signal: ?u32 = null,
    cancellation_reason: ?[]const u8 = null,
};

pub const TrackedTerminalProcess = struct {
    process_id: []u8,
    process_identity: u32,
    session_id: []u8,
    command: []u8,
    cwd: []u8,
    pid: ?u32,
    process_group: ?u32,
    started_at_ms: i64,
    dock_id: u32,
    pane_id: ?WorkspacePaneId,
    owner_kind: []u8,
    owner_title: []u8,
    provider: ?[]u8,
    missing_since_ms: ?i64 = null,

    fn init(
        allocator: std.mem.Allocator,
        process_id: []u8,
        observation: TerminalProcessObservation,
    ) !TrackedTerminalProcess {
        errdefer allocator.free(process_id);
        const session_id = try allocator.dupe(u8, observation.session_id);
        errdefer allocator.free(session_id);
        const command = try allocator.dupe(u8, observation.command);
        errdefer allocator.free(command);
        const cwd = try allocator.dupe(u8, observation.cwd);
        errdefer allocator.free(cwd);
        const owner_kind = try allocator.dupe(u8, observation.owner_kind);
        errdefer allocator.free(owner_kind);
        const owner_title = try allocator.dupe(u8, observation.owner_title);
        errdefer allocator.free(owner_title);
        const provider = if (observation.provider) |value| try allocator.dupe(u8, value) else null;
        errdefer if (provider) |value| allocator.free(value);
        return .{
            .process_id = process_id,
            .process_identity = observation.process_identity,
            .session_id = session_id,
            .command = command,
            .cwd = cwd,
            .pid = observation.pid,
            .process_group = observation.process_group,
            .started_at_ms = observation.started_at_ms,
            .dock_id = observation.dock_id,
            .pane_id = observation.pane_id,
            .owner_kind = owner_kind,
            .owner_title = owner_title,
            .provider = provider,
        };
    }

    fn deinit(self: *TrackedTerminalProcess, allocator: std.mem.Allocator) void {
        allocator.free(self.process_id);
        allocator.free(self.session_id);
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.free(self.owner_kind);
        allocator.free(self.owner_title);
        if (self.provider) |value| allocator.free(value);
    }
};

pub const TerminalProcessOutcome = struct {
    process_id: []u8,
    session_id: []u8,
    command: []u8,
    cwd: []u8,
    pid: ?u32,
    process_group: ?u32,
    started_at_ms: i64,
    finished_at_ms: i64,
    dock_id: u32,
    pane_id: ?WorkspacePaneId,
    owner_kind: []u8,
    owner_title: []u8,
    provider: ?[]u8,
    status: TerminalProcessOutcomeStatus,
    exit_code: ?u32,
    signal: ?u32,
    cancellation_reason: ?[]u8,

    fn deinit(self: *TerminalProcessOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.process_id);
        allocator.free(self.session_id);
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.free(self.owner_kind);
        allocator.free(self.owner_title);
        if (self.provider) |value| allocator.free(value);
        if (self.cancellation_reason) |value| allocator.free(value);
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
    tracked_terminal_processes: std.ArrayList(TrackedTerminalProcess) = .empty,
    terminal_process_outcomes: std.ArrayList(TerminalProcessOutcome) = .empty,
    pending_terminal_teardowns: std.ArrayList(terminal.SessionTeardown) = .empty,
    next_terminal_process_id: u64 = 1,
    next_workspace_lease_id: u64 = 1,
    last_stack_config_refresh_ms: i64 = 0,
    stack_config_error: ?[]u8 = null,
    next_terminal_dock_id: u32 = 1,
    workspace_layout: WorkspaceLayout,
    threads: std.ArrayList(ChatThread),
    archived_threads: std.ArrayList(ChatThread),
    companion_thread_local_id: ?[:0]const u8 = null,
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
            .tracked_terminal_processes = .empty,
            .terminal_process_outcomes = .empty,
            .pending_terminal_teardowns = .empty,
            .next_terminal_process_id = 1,
            .next_workspace_lease_id = 1,
            .last_stack_config_refresh_ms = 0,
            .stack_config_error = null,
            .next_terminal_dock_id = 1,
            .workspace_layout = try WorkspaceLayout.initDefaultChat(allocator),
            .threads = .empty,
            .archived_threads = .empty,
            .companion_thread_local_id = null,
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

    /// Resolves or creates the one pane-less Companion thread without changing
    /// the selected thread or workspace layout.
    pub fn ensureCompanionThread(self: *Project, allocator: std.mem.Allocator) !*ChatThread {
        if (self.companion_thread_local_id) |local_id| {
            for (self.threads.items) |*thread| {
                if (std.mem.eql(u8, thread.local_thread_id, local_id)) return thread;
            }
            allocator.free(local_id);
            self.companion_thread_local_id = null;
        }

        var thread = try ChatThread.init(allocator, "Companion");
        errdefer thread.deinit(allocator);
        const local_id = try allocator.dupeZ(u8, thread.local_thread_id);
        errdefer allocator.free(local_id);
        try self.threads.append(allocator, thread);
        const appended = &self.threads.items[self.threads.items.len - 1];
        self.companion_thread_local_id = local_id;
        return appended;
    }

    pub fn isCompanionThread(self: *const Project, thread: *const ChatThread) bool {
        const local_id = self.companion_thread_local_id orelse return false;
        return std.mem.eql(u8, local_id, thread.local_thread_id);
    }

    /// Removes the eager-created Companion rows produced by the phase-two
    /// prototype, but only when no durable or live owner can observe them.
    pub fn cleanupPristineLegacyCompanion(self: *Project, allocator: std.mem.Allocator) bool {
        const local_id = self.companion_thread_local_id orelse return false;
        const thread_index = for (self.threads.items, 0..) |thread, index| {
            if (std.mem.eql(u8, thread.local_thread_id, local_id)) break index;
        } else return false;
        const thread = &self.threads.items[thread_index];
        if (thread.committed or thread.messages.items.len != 0 or thread.provider_thread_id != null or
            thread.currentDraft().len != 0 or thread.draftImageCount() != 0 or thread.background_tasks.items.len != 0 or
            thread.completion_pending or self.selected_thread_index == thread_index)
        {
            return false;
        }
        for (self.workspace_layout.panes.items) |pane| switch (pane.ref) {
            .chat => |ref| if (ref.thread_index == thread_index) return false,
            else => {},
        };
        const send_state = thread.send_state;
        send_state.mutex.lock();
        const pristine_send = send_state.status == .idle and send_state.provisional_provider_thread_id == null and
            send_state.active_turn_id == null and send_state.daemon_turn_id == null and !send_state.daemon_owned and
            send_state.daemon_last_seq == 0 and send_state.result == null and send_state.error_message == null and
            send_state.control_error_message == null and send_state.provider == null and send_state.partial_text.items.len == 0 and
            !send_state.thinking and send_state.pending_events.items.len == 0 and send_state.pending_diff_files.items.len == 0 and
            !send_state.pending_diff_has_turn_snapshot and send_state.pending_approval == null and send_state.approval_decision == null and
            send_state.pending_followup == null and !send_state.pending_followup_signal_sent and !send_state.stop_requested and
            !send_state.stop_signal_sent and send_state.worker == null and !send_state.local_command and send_state.local_command_text == null and
            send_state.local_command_cwd == null and send_state.local_command_shell == null and send_state.active_local_child == null;
        send_state.mutex.unlock();
        if (!pristine_send) return false;

        allocator.free(self.companion_thread_local_id.?);
        self.companion_thread_local_id = null;
        var removed = self.threads.orderedRemove(thread_index);
        removed.deinit(allocator);
        for (self.workspace_layout.panes.items) |*pane| switch (pane.ref) {
            .chat => |*ref| if (ref.thread_index > thread_index) {
                ref.thread_index -= 1;
            },
            else => {},
        };
        if (thread_index < self.selected_thread_index) {
            self.selected_thread_index -= 1;
        } else if (self.threads.items.len == 0) {
            self.selected_thread_index = 0;
        } else if (self.selected_thread_index >= self.threads.items.len) {
            self.selected_thread_index = self.threads.items.len - 1;
        }
        self.invalidateSidebarThreadCache();
        return true;
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

    pub fn observeTerminalProcess(
        self: *Project,
        allocator: std.mem.Allocator,
        observation: TerminalProcessObservation,
        replaced_finish: TerminalProcessFinish,
    ) !void {
        var replaced_index: ?usize = null;
        for (self.tracked_terminal_processes.items, 0..) |*tracked, index| {
            if (!std.mem.eql(u8, tracked.session_id, observation.session_id)) continue;
            if (tracked.process_identity == observation.process_identity) {
                tracked.missing_since_ms = null;
                return;
            }
            replaced_index = index;
            break;
        }
        const process_id = try std.fmt.allocPrint(
            allocator,
            "term:{s}:{d}",
            .{ observation.session_id, self.next_terminal_process_id },
        );
        var tracked = try TrackedTerminalProcess.init(allocator, process_id, observation);
        errdefer tracked.deinit(allocator);
        if (replaced_index) |index| {
            try self.finishTrackedTerminalProcess(allocator, index, replaced_finish, observation.observed_at_ms);
            self.tracked_terminal_processes.appendAssumeCapacity(tracked);
        } else {
            try self.tracked_terminal_processes.append(allocator, tracked);
        }
        self.next_terminal_process_id +%= 1;
        if (self.next_terminal_process_id == 0) self.next_terminal_process_id = 1;
    }

    pub fn terminalProcessActiveForSession(self: *const Project, session_id: []const u8) ?*const TrackedTerminalProcess {
        for (self.tracked_terminal_processes.items) |*tracked| {
            if (std.mem.eql(u8, tracked.session_id, session_id)) return tracked;
        }
        return null;
    }

    /// Keeps a foreground process observable briefly after it disappears so a
    /// shell exit from the same command can supply the authoritative status.
    pub fn terminalProcessMissingReady(self: *Project, session_id: []const u8, observed_at_ms: i64) bool {
        for (self.tracked_terminal_processes.items) |*tracked| {
            if (!std.mem.eql(u8, tracked.session_id, session_id)) continue;
            const missing_since_ms = tracked.missing_since_ms orelse {
                tracked.missing_since_ms = observed_at_ms;
                return false;
            };
            if (observed_at_ms < missing_since_ms) {
                tracked.missing_since_ms = observed_at_ms;
                return false;
            }
            return observed_at_ms - missing_since_ms >= TERMINAL_PROCESS_EXIT_GRACE_MS;
        }
        return false;
    }

    pub fn finishTerminalProcess(
        self: *Project,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        finish: TerminalProcessFinish,
        finished_at_ms: i64,
    ) !bool {
        for (self.tracked_terminal_processes.items, 0..) |tracked, index| {
            if (!std.mem.eql(u8, tracked.session_id, session_id)) continue;
            try self.finishTrackedTerminalProcess(allocator, index, finish, finished_at_ms);
            return true;
        }
        return false;
    }

    pub fn pruneTerminalProcessOutcomes(self: *Project, allocator: std.mem.Allocator, now_ms: i64) void {
        var index: usize = 0;
        while (index < self.terminal_process_outcomes.items.len) {
            const outcome = &self.terminal_process_outcomes.items[index];
            if (now_ms < outcome.finished_at_ms or now_ms - outcome.finished_at_ms <= TERMINAL_PROCESS_OUTCOME_TTL_MS) {
                index += 1;
                continue;
            }
            var removed = self.terminal_process_outcomes.orderedRemove(index);
            removed.deinit(allocator);
        }
    }

    fn finishTrackedTerminalProcess(
        self: *Project,
        allocator: std.mem.Allocator,
        tracked_index: usize,
        finish: TerminalProcessFinish,
        finished_at_ms: i64,
    ) !void {
        const cancellation_reason = if (finish.cancellation_reason) |value| try allocator.dupe(u8, value) else null;
        errdefer if (cancellation_reason) |value| allocator.free(value);
        try self.terminal_process_outcomes.ensureUnusedCapacity(allocator, 1);

        self.pruneTerminalProcessOutcomes(allocator, finished_at_ms);
        while (self.terminal_process_outcomes.items.len >= TERMINAL_PROCESS_OUTCOME_MAX) {
            var removed = self.terminal_process_outcomes.orderedRemove(0);
            removed.deinit(allocator);
        }

        const tracked = self.tracked_terminal_processes.orderedRemove(tracked_index);
        self.terminal_process_outcomes.appendAssumeCapacity(.{
            .process_id = tracked.process_id,
            .session_id = tracked.session_id,
            .command = tracked.command,
            .cwd = tracked.cwd,
            .pid = tracked.pid,
            .process_group = tracked.process_group,
            .started_at_ms = tracked.started_at_ms,
            .finished_at_ms = finished_at_ms,
            .dock_id = tracked.dock_id,
            .pane_id = tracked.pane_id,
            .owner_kind = tracked.owner_kind,
            .owner_title = tracked.owner_title,
            .provider = tracked.provider,
            .status = terminalProcessOutcomeStatus(finish),
            .exit_code = finish.exit_code,
            .signal = finish.signal,
            .cancellation_reason = cancellation_reason,
        });
    }

    pub fn committedThreadCount(self: *const Project) usize {
        var count: usize = 0;
        for (self.threads.items) |thread| {
            if (thread.committed and !self.isCompanionThread(&thread)) count += 1;
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
        for (self.tracked_terminal_processes.items) |*process| process.deinit(allocator);
        self.tracked_terminal_processes.deinit(allocator);
        for (self.terminal_process_outcomes.items) |*outcome| outcome.deinit(allocator);
        self.terminal_process_outcomes.deinit(allocator);
        for (self.pending_terminal_teardowns.items) |*teardown| teardown.deinit(allocator);
        self.pending_terminal_teardowns.deinit(allocator);
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
        if (self.companion_thread_local_id) |local_id| allocator.free(local_id);
        self.sidebar_thread_indices.deinit(allocator);
    }

    pub fn ensureSidebarThreadCache(self: *Project, allocator: std.mem.Allocator) void {
        if (!self.sidebar_thread_cache_dirty) return;

        self.sidebar_thread_indices.clearRetainingCapacity();
        self.sidebar_committed_thread_count = 0;

        for (self.threads.items, 0..) |thread, index| {
            if (!thread.committed or self.isCompanionThread(&thread)) continue;
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

fn terminalProcessOutcomeStatus(finish: TerminalProcessFinish) TerminalProcessOutcomeStatus {
    if (finish.cancellation_reason != null) return .cancelled;
    if (finish.exit_code) |exit_code| return if (exit_code == 0) .completed else .failed;
    if (finish.signal != null) return .crashed;
    return .unknown;
}

fn appendOwnedString(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

test "terminal process outcomes classify exits once" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "terminal-results", "Terminal results", "/tmp/terminal-results", 0);
    defer project.deinit(allocator);

    const cases = [_]struct {
        session_id: []const u8,
        finish: TerminalProcessFinish,
        expected_status: TerminalProcessOutcomeStatus,
    }{
        .{ .session_id = "session-clean", .finish = .{ .exit_code = 0 }, .expected_status = .completed },
        .{ .session_id = "session-failed", .finish = .{ .exit_code = 17 }, .expected_status = .failed },
        .{ .session_id = "session-signal", .finish = .{ .signal = 9 }, .expected_status = .crashed },
        .{ .session_id = "session-unknown", .finish = .{}, .expected_status = .unknown },
        .{
            .session_id = "session-cancelled",
            .finish = .{ .signal = 15, .cancellation_reason = "pane closed" },
            .expected_status = .cancelled,
        },
    };

    for (cases, 0..) |case, index| {
        try project.observeTerminalProcess(allocator, .{
            .process_identity = @intCast(index + 10),
            .session_id = case.session_id,
            .command = "codex",
            .cwd = "/tmp/terminal-results",
            .pid = @intCast(index + 10),
            .process_group = @intCast(index + 10),
            .started_at_ms = @intCast(100 + index),
            .observed_at_ms = @intCast(150 + index),
            .dock_id = @intCast(index + 1),
            .pane_id = @intCast(index + 20),
            .owner_kind = "agent",
            .owner_title = "Codex",
            .provider = "codex",
        }, .{});
        try std.testing.expect(try project.finishTerminalProcess(allocator, case.session_id, case.finish, @intCast(200 + index)));
        try std.testing.expect(!(try project.finishTerminalProcess(allocator, case.session_id, case.finish, @intCast(300 + index))));
        try std.testing.expectEqual(case.expected_status, project.terminal_process_outcomes.items[index].status);
    }

    try std.testing.expectEqual(@as(usize, cases.len), project.terminal_process_outcomes.items.len);
    try std.testing.expectEqual(@as(?u32, 17), project.terminal_process_outcomes.items[1].exit_code);
    try std.testing.expectEqual(@as(?u32, 9), project.terminal_process_outcomes.items[2].signal);
    try std.testing.expectEqualStrings("pane closed", project.terminal_process_outcomes.items[4].cancellation_reason.?);
}

test "terminal finalization and replacement preserve the active tracker on allocation failure" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "terminal-atomic", "Terminal atomic", "/tmp/terminal-atomic", 0);
    defer project.deinit(allocator);

    try project.observeTerminalProcess(allocator, .{
        .process_identity = 41,
        .session_id = "session-atomic",
        .command = "first",
        .cwd = "/tmp/terminal-atomic",
        .pid = 41,
        .process_group = 41,
        .started_at_ms = 100,
        .observed_at_ms = 110,
        .dock_id = 1,
        .owner_kind = "terminal",
        .owner_title = "first",
    }, .{});
    const active_id = try allocator.dupe(u8, project.terminalProcessActiveForSession("session-atomic").?.process_id);
    defer allocator.free(active_id);

    var finish_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        project.finishTerminalProcess(finish_failing.allocator(), "session-atomic", .{ .exit_code = 0 }, 200),
    );
    try std.testing.expectEqualStrings(active_id, project.terminalProcessActiveForSession("session-atomic").?.process_id);
    try std.testing.expectEqual(@as(usize, 0), project.terminal_process_outcomes.items.len);

    var replacement_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 6 });
    try std.testing.expectError(error.OutOfMemory, project.observeTerminalProcess(replacement_failing.allocator(), .{
        .process_identity = 42,
        .session_id = "session-atomic",
        .command = "second",
        .cwd = "/tmp/terminal-atomic",
        .pid = 42,
        .process_group = 42,
        .started_at_ms = 100,
        .observed_at_ms = 300,
        .dock_id = 1,
        .owner_kind = "terminal",
        .owner_title = "second",
    }, .{}));
    try std.testing.expectEqualStrings(active_id, project.terminalProcessActiveForSession("session-atomic").?.process_id);
    try std.testing.expectEqual(@as(usize, 0), project.terminal_process_outcomes.items.len);
}

test "terminal process disappearance waits for a possible shell exit and reappearance cancels the grace" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "terminal-grace", "Terminal grace", "/tmp/terminal-grace", 0);
    defer project.deinit(allocator);

    const observation: TerminalProcessObservation = .{
        .process_identity = 41,
        .session_id = "session-grace",
        .command = "sleep",
        .cwd = "/tmp/terminal-grace",
        .pid = 41,
        .process_group = 41,
        .started_at_ms = 100,
        .observed_at_ms = 110,
        .dock_id = 1,
        .owner_kind = "terminal",
        .owner_title = "sleep",
    };
    try project.observeTerminalProcess(allocator, observation, .{});
    try std.testing.expect(!project.terminalProcessMissingReady("session-grace", 200));
    try std.testing.expect(!project.terminalProcessMissingReady(
        "session-grace",
        200 + TERMINAL_PROCESS_EXIT_GRACE_MS - 1,
    ));
    try std.testing.expect(project.terminalProcessMissingReady(
        "session-grace",
        200 + TERMINAL_PROCESS_EXIT_GRACE_MS,
    ));

    try project.observeTerminalProcess(allocator, observation, .{});
    try std.testing.expect(project.terminalProcessActiveForSession("session-grace").?.missing_since_ms == null);
    try std.testing.expect(!project.terminalProcessMissingReady("session-grace", 1_000));
}

test "terminal process outcome retention starts at final observation and evicts oldest results" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "terminal-retention", "Terminal retention", "/tmp/terminal-retention", 0);
    defer project.deinit(allocator);

    for (0..TERMINAL_PROCESS_OUTCOME_MAX + 1) |index| {
        const session_id = try std.fmt.allocPrint(allocator, "session-{d}", .{index});
        defer allocator.free(session_id);
        const observed_at_ms: i64 = TERMINAL_PROCESS_OUTCOME_TTL_MS * 2 + @as(i64, @intCast(index));
        try project.observeTerminalProcess(allocator, .{
            .process_identity = @intCast(index + 1),
            .session_id = session_id,
            .command = "mise run build",
            .cwd = "/tmp/terminal-retention",
            .pid = @intCast(index + 1),
            .started_at_ms = 1,
            .observed_at_ms = observed_at_ms,
            .dock_id = @intCast(index + 1),
            .owner_kind = "terminal",
            .owner_title = "mise run build",
        }, .{});
        try std.testing.expect(try project.finishTerminalProcess(allocator, session_id, .{ .exit_code = 0 }, observed_at_ms));
    }

    try std.testing.expectEqual(@as(usize, TERMINAL_PROCESS_OUTCOME_MAX), project.terminal_process_outcomes.items.len);
    try std.testing.expectEqualStrings("session-1", project.terminal_process_outcomes.items[0].session_id);

    const oldest_finished_at = project.terminal_process_outcomes.items[0].finished_at_ms;
    project.pruneTerminalProcessOutcomes(allocator, oldest_finished_at + TERMINAL_PROCESS_OUTCOME_TTL_MS);
    try std.testing.expectEqual(@as(usize, TERMINAL_PROCESS_OUTCOME_MAX), project.terminal_process_outcomes.items.len);
    project.pruneTerminalProcessOutcomes(allocator, oldest_finished_at + TERMINAL_PROCESS_OUTCOME_TTL_MS + 1);
    try std.testing.expectEqual(@as(usize, TERMINAL_PROCESS_OUTCOME_MAX - 1), project.terminal_process_outcomes.items.len);
    const newest_finished_at = project.terminal_process_outcomes.items[project.terminal_process_outcomes.items.len - 1].finished_at_ms;
    project.pruneTerminalProcessOutcomes(allocator, newest_finished_at + TERMINAL_PROCESS_OUTCOME_TTL_MS + 1);
    try std.testing.expectEqual(@as(usize, 0), project.terminal_process_outcomes.items.len);
}

test "terminal process identity transitions preserve failures and never reuse record ids" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "terminal-identity", "Terminal identity", "/tmp/terminal-identity", 0);
    defer project.deinit(allocator);

    try project.observeTerminalProcess(allocator, .{
        .process_identity = 42,
        .session_id = "session-identity",
        .command = "first",
        .cwd = "/tmp/terminal-identity",
        .pid = 42,
        .process_group = 42,
        .started_at_ms = 1,
        .observed_at_ms = 1_000,
        .dock_id = 3,
        .owner_kind = "terminal",
        .owner_title = "first",
    }, .{});
    const first_id = try allocator.dupe(u8, project.terminalProcessActiveForSession("session-identity").?.process_id);
    defer allocator.free(first_id);

    try project.observeTerminalProcess(allocator, .{
        .process_identity = 43,
        .session_id = "session-identity",
        .command = "second",
        .cwd = "/tmp/terminal-identity",
        .pid = 43,
        .process_group = 43,
        .started_at_ms = 1,
        .observed_at_ms = 2_000,
        .dock_id = 3,
        .owner_kind = "terminal",
        .owner_title = "second",
    }, .{ .exit_code = 17 });
    try std.testing.expectEqual(TerminalProcessOutcomeStatus.failed, project.terminal_process_outcomes.items[0].status);
    try std.testing.expectEqual(@as(?u32, 17), project.terminal_process_outcomes.items[0].exit_code);

    try project.observeTerminalProcess(allocator, .{
        .process_identity = 42,
        .session_id = "session-identity",
        .command = "third",
        .cwd = "/tmp/terminal-identity",
        .pid = 42,
        .process_group = 42,
        .started_at_ms = 1,
        .observed_at_ms = 3_000,
        .dock_id = 3,
        .owner_kind = "terminal",
        .owner_title = "third",
    }, .{});
    try std.testing.expectEqual(TerminalProcessOutcomeStatus.unknown, project.terminal_process_outcomes.items[1].status);
    const third_id = project.terminalProcessActiveForSession("session-identity").?.process_id;
    try std.testing.expect(!std.mem.eql(u8, first_id, third_id));

    try std.testing.expect(try project.finishTerminalProcess(allocator, "session-identity", .{ .signal = 9 }, 4_000));
    try std.testing.expectEqual(TerminalProcessOutcomeStatus.crashed, project.terminal_process_outcomes.items[2].status);
    try std.testing.expectEqual(@as(?u32, 9), project.terminal_process_outcomes.items[2].signal);
    try std.testing.expectEqualStrings(third_id, project.terminal_process_outcomes.items[2].process_id);

    for (project.terminal_process_outcomes.items, 0..) |outcome, index| {
        for (project.terminal_process_outcomes.items[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, outcome.process_id, other.process_id));
        }
    }
}

test "Companion ensure is pane-less stable and replaces stale identity" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "companion", "Companion", "/tmp/companion", 0);
    defer project.deinit(allocator);
    const selected_before = project.selected_thread_index;
    const pane_count_before = project.workspace_layout.panes.items.len;
    const focused_pane_before = project.workspace_layout.focused_pane_id;
    try std.testing.expect(project.companion_thread_local_id == null);

    const first = try project.ensureCompanionThread(allocator);
    const first_id = try allocator.dupe(u8, first.local_thread_id);
    defer allocator.free(first_id);
    const count_after_first = project.threads.items.len;
    const repeated = try project.ensureCompanionThread(allocator);
    try std.testing.expectEqualStrings(first_id, repeated.local_thread_id);
    try std.testing.expectEqual(count_after_first, project.threads.items.len);
    try std.testing.expectEqual(selected_before, project.selected_thread_index);
    try std.testing.expectEqual(pane_count_before, project.workspace_layout.panes.items.len);
    try std.testing.expectEqual(focused_pane_before, project.workspace_layout.focused_pane_id);
    try std.testing.expect(project.isCompanionThread(repeated));

    allocator.free(project.companion_thread_local_id.?);
    project.companion_thread_local_id = try allocator.dupeZ(u8, "missing-companion");
    const replacement = try project.ensureCompanionThread(allocator);
    try std.testing.expect(!std.mem.eql(u8, first_id, replacement.local_thread_id));
    try std.testing.expectEqual(count_after_first + 1, project.threads.items.len);
    try std.testing.expectEqual(selected_before, project.selected_thread_index);
    try std.testing.expectEqual(pane_count_before, project.workspace_layout.panes.items.len);
}

test "committed Companion is absent from sidebar cache" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "companion-sidebar", "Companion", "/tmp/companion-sidebar", 0);
    defer project.deinit(allocator);
    project.threads.items[0].committed = true;
    const companion = try project.ensureCompanionThread(allocator);
    companion.committed = true;
    project.invalidateSidebarThreadCache();

    try std.testing.expectEqual(@as(usize, 1), project.committedThreadCount());
    try std.testing.expectEqual(@as(usize, 1), project.committedThreadCountCached(allocator));
    const indices = project.sortedCommittedThreadIndices(allocator);
    try std.testing.expectEqual(@as(usize, 1), indices.len);
    try std.testing.expect(!project.isCompanionThread(&project.threads.items[indices[0]]));
}

test "legacy pristine Companion cleanup repairs non-last indexes" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "legacy", "Legacy", "/tmp/legacy", 0);
    defer project.deinit(allocator);
    const companion = try project.ensureCompanionThread(allocator);
    const companion_id = try allocator.dupe(u8, companion.local_thread_id);
    defer allocator.free(companion_id);
    _ = try project.addThread(allocator);
    const later_pane = try project.workspace_layout.createChatPane(allocator, 2);
    try project.workspace_layout.ensurePaneInRootSplit(allocator, later_pane, .vertical, 0.5);
    project.selected_thread_index = 2;

    try std.testing.expect(project.cleanupPristineLegacyCompanion(allocator));
    try std.testing.expect(project.companion_thread_local_id == null);
    try std.testing.expectEqual(@as(usize, 2), project.threads.items.len);
    try std.testing.expectEqual(@as(usize, 1), project.selected_thread_index);
    try std.testing.expectEqual(@as(usize, 1), project.workspace_layout.paneById(later_pane).?.ref.chat.thread_index);
    for (project.threads.items) |thread| try std.testing.expect(!std.mem.eql(u8, companion_id, thread.local_thread_id));
}

test "legacy Companion cleanup preserves every non-pristine owner" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "legacy-owned", "Legacy", "/tmp/legacy-owned", 0);
    defer project.deinit(allocator);
    const companion = try project.ensureCompanionThread(allocator);
    companion.setDraft("keep me");
    try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));
    companion.clearDraft();
    try companion.setDraftImage(allocator, "/tmp/image.png", "image/png", 1);
    try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));
    companion.clearDraftImage(allocator);
    companion.provider_thread_id = try allocator.dupeZ(u8, "provider-thread");
    try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));
    allocator.free(companion.provider_thread_id.?);
    companion.provider_thread_id = null;
    companion.send_state.status = .pending;
    try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));
    companion.send_state.status = .idle;
    _ = try project.workspace_layout.createChatPane(allocator, 1);
    try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));
    try std.testing.expectEqualStrings(companion.local_thread_id, project.companion_thread_local_id.?);
}

test "legacy Companion cleanup rejects all send-owned presentation and action state" {
    const allocator = std.testing.allocator;
    const Owner = enum {
        result,
        provider_error,
        control_error,
        provider,
        provisional_identity,
        active_turn,
        daemon_turn,
        daemon_sequence,
        partial,
        thinking,
        event,
        diff,
        diff_snapshot,
        approval,
        decision,
        followup,
        followup_signal,
        stop_request,
        stop_signal,
        local_command,
        local_text,
        local_cwd,
        local_shell,
    };

    for (std.enums.values(Owner)) |owner| {
        var project = try Project.init(allocator, "legacy-send-owner", "Legacy", "/tmp/legacy-send-owner", 0);
        errdefer project.deinit(allocator);
        const companion = try project.ensureCompanionThread(allocator);
        const send_state = companion.send_state;
        switch (owner) {
            .result => send_state.result = .{
                .provider_thread_id = try std.heap.page_allocator.dupe(u8, "provider"),
                .reply_text = try std.heap.page_allocator.dupe(u8, "reply"),
            },
            .provider_error => send_state.error_message = try std.heap.page_allocator.dupe(u8, "provider failed"),
            .control_error => send_state.control_error_message = try std.heap.page_allocator.dupe(u8, "action failed"),
            .provider => send_state.provider = .codex,
            .provisional_identity => send_state.provisional_provider_thread_id = try std.heap.page_allocator.dupe(u8, "provisional"),
            .active_turn => send_state.active_turn_id = try std.heap.page_allocator.dupe(u8, "active"),
            .daemon_turn => send_state.daemon_turn_id = try std.heap.page_allocator.dupe(u8, "daemon"),
            .daemon_sequence => send_state.daemon_last_seq = 1,
            .partial => try send_state.partial_text.appendSlice(std.heap.page_allocator, "partial"),
            .thinking => send_state.thinking = true,
            .event => try send_state.pending_events.append(std.heap.page_allocator, .{
                .role = .system,
                .author = try std.heap.page_allocator.dupe(u8, "Event"),
                .body = try std.heap.page_allocator.dupe(u8, "body"),
            }),
            .diff => try send_state.pending_diff_files.append(std.heap.page_allocator, .{
                .path = try std.heap.page_allocator.dupe(u8, "file.zig"),
                .additions = 1,
                .deletions = 0,
            }),
            .diff_snapshot => send_state.pending_diff_has_turn_snapshot = true,
            .approval => send_state.pending_approval = .{
                .call_id = try std.heap.page_allocator.dupe(u8, "call"),
                .title = try std.heap.page_allocator.dupe(u8, "Approve"),
                .body = try std.heap.page_allocator.dupe(u8, "body"),
            },
            .decision => send_state.approval_decision = .approve,
            .followup => send_state.pending_followup = .{
                .kind = .queue,
                .prompt = try allocator.dupe(u8, "next"),
            },
            .followup_signal => send_state.pending_followup_signal_sent = true,
            .stop_request => send_state.stop_requested = true,
            .stop_signal => send_state.stop_signal_sent = true,
            .local_command => send_state.local_command = true,
            .local_text => send_state.local_command_text = try std.heap.page_allocator.dupe(u8, "echo ok"),
            .local_cwd => send_state.local_command_cwd = try std.heap.page_allocator.dupe(u8, "/tmp"),
            .local_shell => send_state.local_command_shell = try std.heap.page_allocator.dupe(u8, "/bin/sh"),
        }
        try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));
        try std.testing.expect(project.companion_thread_local_id != null);
        project.deinit(allocator);
    }
}

test "legacy Companion cleanup rejects selection and stale identity and is idempotent" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "legacy-edge", "Legacy", "/tmp/legacy-edge", 0);
    defer project.deinit(allocator);
    _ = try project.ensureCompanionThread(allocator);
    project.selected_thread_index = 1;
    try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));

    project.selected_thread_index = 0;
    try std.testing.expect(project.cleanupPristineLegacyCompanion(allocator));
    try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));

    project.companion_thread_local_id = try allocator.dupeZ(u8, "stale-designation");
    try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));

    allocator.free(project.companion_thread_local_id.?);
    var archived = try ChatThread.init(allocator, "Archived Companion");
    archived.archived = true;
    const archived_id = try allocator.dupeZ(u8, archived.local_thread_id);
    project.archived_threads.append(allocator, archived) catch |err| {
        allocator.free(archived_id);
        archived.deinit(allocator);
        return err;
    };
    project.companion_thread_local_id = archived_id;
    try std.testing.expect(!project.cleanupPristineLegacyCompanion(allocator));
}
