//! Pure daemon-side process, outcome, and lease registry.

const std = @import("std");

pub const TERMINAL_PROCESS_OUTCOME_MAX: usize = 32;
pub const TERMINAL_PROCESS_OUTCOME_TTL_MS: i64 = 15 * std.time.ms_per_min;
pub const TERMINAL_PROCESS_EXIT_GRACE_MS: i64 = 250;
pub const WORKSPACE_LEASE_TTL_MS: i64 = 120 * std.time.ms_per_s;

pub const CLIENT_COMPATIBILITY_RETENTION_MS: i64 = 5 * std.time.ms_per_min;
pub const ORPHAN_GRACE_MS: i64 = 5 * std.time.ms_per_min;
pub const DISCONNECTED_RETENTION_MS: i64 = 30 * std.time.ms_per_min;
pub const TURN_ABANDONMENT_GRACE_MS: i64 = 5 * std.time.ms_per_min;
pub const TURN_RETENTION_TTL_MS: i64 = 15 * std.time.ms_per_min;
pub const TURN_RETENTION_MAX: usize = 32;
pub const STALE_ATTACH_TIMEOUT_MS: i64 = 60 * std.time.ms_per_s;
pub const WORKSPACE_PATH_ALIAS_TTL_MS: i64 = 24 * std.time.ms_per_hour;
pub const WORKSPACE_PATH_ALIAS_MAX: usize = 16;
pub const WORKSPACE_PATH_ALIAS_GLOBAL_MAX: usize = 256;
pub const WORKSPACE_RECORD_MAX: usize = 256;
pub const NOTIFICATION_MAILBOX_MAX: usize = 64;
pub const NOTIFICATION_SESSION_MAX: usize = 32;
pub const NOTIFICATION_GLOBAL_MAX: usize = 256;
pub const NOTIFICATION_TTL_MS: i64 = 15 * std.time.ms_per_min;
pub const REGISTRY_JOB_QUEUE_MAX: usize = 64;

// These are mirrored from headless/registry_protocol.zig deliberately.  The
// daemon registry stays independent of the std-only wire package; W2 projects
// these records into the protocol DTOs at the transport boundary.
pub const NOTIFICATION_TYPE_COORDINATION_CONFLICT: []const u8 = "coordination.conflict";
pub const NOTIFICATION_TITLE_CONFLICTING_COMMAND: []const u8 = "Conflicting command started";

pub const ClientRecord = struct {
    client_id: []u8,
    last_heartbeat_ms: i64,
    persistent: bool = false,
    compatibility: bool = false,
    closed: bool = false,
    closed_at_ms: ?i64 = null,

    pub fn deinit(self: *ClientRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
    }
};

/// A notification is owned by its workspace mailbox. `command` borrows the
/// same allocation as `body`, which keeps the daemon and wire shapes aligned
/// without storing the conflict command twice.
pub const Notification = struct {
    seq: u64,
    type: []const u8 = NOTIFICATION_TYPE_COORDINATION_CONFLICT,
    workspace_id: []u8,
    owner_session_id: ?[]u8,
    title: []const u8 = NOTIFICATION_TITLE_CONFLICTING_COMMAND,
    body: []u8,
    command: []const u8,
    created_at_ms: i64,
    order_seq: u64,

    fn init(
        allocator: std.mem.Allocator,
        seq: u64,
        workspace_id: []const u8,
        owner_session_id: []const u8,
        command: []const u8,
        created_at_ms: i64,
        order_seq: u64,
    ) !Notification {
        const owned_workspace_id = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(owned_workspace_id);
        const owned_owner = try allocator.dupe(u8, owner_session_id);
        errdefer allocator.free(owned_owner);
        const body = try allocator.dupe(u8, command);
        return .{
            .seq = seq,
            .workspace_id = owned_workspace_id,
            .owner_session_id = owned_owner,
            .body = body,
            .command = body,
            .created_at_ms = created_at_ms,
            .order_seq = order_seq,
        };
    }

    pub fn deinit(self: *Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        if (self.owner_session_id) |owner| allocator.free(owner);
        allocator.free(self.body);
    }
};

pub const RegistryNotification = Notification;

/// Pull-only bounded mailbox for one workspace. Entries are filtered by the
/// affected owner/session at read time, while `seq` remains a workspace-local
/// cursor that never moves backwards when old entries are evicted.
pub const NotificationMailbox = struct {
    entries: std.ArrayList(Notification) = .empty,
    next_seq: u64 = 1,
    max_entries: usize = NOTIFICATION_MAILBOX_MAX,
    max_entries_per_session: usize = NOTIFICATION_SESSION_MAX,

    pub fn deinit(self: *NotificationMailbox, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }

    pub fn append(
        self: *NotificationMailbox,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        owner_session_id: []const u8,
        command: []const u8,
        created_at_ms: i64,
        order_seq: u64,
    ) !usize {
        if (owner_session_id.len == 0) return error.NotificationOwnerRequired;
        if (command.len == 0) return error.NotificationBodyRequired;

        var removed_count: usize = 0;
        while (self.sessionCount(owner_session_id) >= self.max_entries_per_session) {
            if (!self.removeOldestForSession(allocator, owner_session_id)) break;
            removed_count += 1;
        }
        while (self.entries.items.len >= self.max_entries) {
            self.removeOldest(allocator);
            removed_count += 1;
        }

        var entry = try Notification.init(
            allocator,
            self.next_seq,
            workspace_id,
            owner_session_id,
            command,
            created_at_ms,
            order_seq,
        );
        errdefer entry.deinit(allocator);
        try self.entries.append(allocator, entry);
        self.next_seq +%= 1;
        if (self.next_seq == 0) self.next_seq = 1;
        return removed_count;
    }

    /// Append borrowed entry pointers matching a session and cursor. The
    /// pointers are invalidated by the next mailbox mutation.
    pub fn collect(
        self: *const NotificationMailbox,
        allocator: std.mem.Allocator,
        owner_session_id: ?[]const u8,
        after_seq: u64,
        limit: usize,
        out: *std.ArrayList(*const Notification),
    ) !u64 {
        var collected: usize = 0;
        for (self.entries.items) |*entry| {
            if (entry.seq <= after_seq) continue;
            if (owner_session_id) |owner| {
                if (entry.owner_session_id == null or !std.mem.eql(u8, entry.owner_session_id.?, owner)) continue;
            }
            if (limit != 0 and collected >= limit) break;
            try out.append(allocator, entry);
            collected += 1;
        }
        return self.next_seq;
    }

    pub fn pruneExpired(self: *NotificationMailbox, allocator: std.mem.Allocator, now_ms: i64) usize {
        var removed_count: usize = 0;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const created_at_ms = self.entries.items[index].created_at_ms;
            if (now_ms < created_at_ms or now_ms - created_at_ms <= NOTIFICATION_TTL_MS) {
                index += 1;
                continue;
            }
            self.removeAt(allocator, index);
            removed_count += 1;
        }
        return removed_count;
    }

    fn sessionCount(self: *const NotificationMailbox, owner_session_id: []const u8) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.owner_session_id) |owner| {
                if (std.mem.eql(u8, owner, owner_session_id)) count += 1;
            }
        }
        return count;
    }

    fn removeOldestForSession(self: *NotificationMailbox, allocator: std.mem.Allocator, owner_session_id: []const u8) bool {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.owner_session_id) |owner| {
                if (std.mem.eql(u8, owner, owner_session_id)) {
                    self.removeAt(allocator, index);
                    return true;
                }
            }
        }
        return false;
    }

    fn removeOldest(self: *NotificationMailbox, allocator: std.mem.Allocator) void {
        if (self.entries.items.len == 0) return;
        self.removeAt(allocator, 0);
    }

    fn removeAt(self: *NotificationMailbox, allocator: std.mem.Allocator, index: usize) void {
        var removed = self.entries.orderedRemove(index);
        removed.deinit(allocator);
    }
};

pub const ManagedProcessRuntimeState = enum {
    configured,
    starting,
    running,
    stopped,
    failed,
};

pub const ManagedProcessRuntimeEvent = enum {
    start,
    started,
    stop,
    stopped,
    failed,
    restart,
};

/// Pure managed-process lifecycle. It records intent and observations only;
/// spawning, waiting, and I/O remain owned by the session daemon.
pub const ManagedProcessRuntime = struct {
    state: ManagedProcessRuntimeState = .configured,
    restart_count: u32 = 0,
    explicit_stop: bool = false,
    generation: u64 = 0,
    last_start_ms: ?i64 = null,
    last_exit_ms: ?i64 = null,

    pub fn transition(self: *ManagedProcessRuntime, event: ManagedProcessRuntimeEvent, now_ms: i64) !void {
        switch (event) {
            .start => switch (self.state) {
                .configured, .stopped, .failed => self.beginStart(now_ms),
                .starting, .running => return error.InvalidManagedProcessTransition,
            },
            .restart => switch (self.state) {
                .stopped, .failed, .running => {
                    self.restart_count +%= 1;
                    self.beginStart(now_ms);
                },
                .configured, .starting => return error.InvalidManagedProcessTransition,
            },
            .started => {
                if (self.state != .starting) return error.InvalidManagedProcessTransition;
                self.state = .running;
            },
            .stop => switch (self.state) {
                .starting, .running => {
                    self.explicit_stop = true;
                    self.state = .stopped;
                    self.last_exit_ms = now_ms;
                },
                .configured, .stopped, .failed => return error.InvalidManagedProcessTransition,
            },
            .stopped => switch (self.state) {
                .starting, .running => {
                    self.state = .stopped;
                    self.last_exit_ms = now_ms;
                },
                .configured, .stopped, .failed => return error.InvalidManagedProcessTransition,
            },
            .failed => switch (self.state) {
                .starting, .running => {
                    self.state = .failed;
                    self.last_exit_ms = now_ms;
                },
                .configured, .stopped, .failed => return error.InvalidManagedProcessTransition,
            },
        }
    }

    fn beginStart(self: *ManagedProcessRuntime, now_ms: i64) void {
        self.state = .starting;
        self.explicit_stop = false;
        self.last_start_ms = now_ms;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
};

pub const WorkspacePathAlias = struct {
    path: []u8,
    last_seen_ms: i64,

    fn deinit(self: *WorkspacePathAlias, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const RetainedTurnState = enum {
    running,
    approval_waiting,
    completed,
};

pub const RetainedTurn = struct {
    id: []u8,
    workspace_id: []u8,
    state: RetainedTurnState,
    abandoned_at_ms: i64,

    pub fn init(allocator: std.mem.Allocator, workspace_id: []const u8, id: []const u8, state: RetainedTurnState, abandoned_at_ms: i64) !RetainedTurn {
        const owned_workspace_id = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(owned_workspace_id);
        const owned_id = try allocator.dupe(u8, id);
        return .{
            .id = owned_id,
            .workspace_id = owned_workspace_id,
            .state = state,
            .abandoned_at_ms = abandoned_at_ms,
        };
    }

    pub fn deinit(self: *RetainedTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_id);
    }
};

pub const RegistryReapCounts = struct {
    aliases: usize = 0,
    notifications: usize = 0,
    turns: usize = 0,
    outcomes: usize = 0,
    leases: usize = 0,
    workspaces: usize = 0,
};

pub fn orphanGraceExpired(orphaned_at_ms: i64, now_ms: i64) bool {
    return retentionExpired(orphaned_at_ms, now_ms, ORPHAN_GRACE_MS);
}

pub fn disconnectedRetentionExpired(last_heartbeat_ms: i64, now_ms: i64, persistent: bool) bool {
    return !persistent and retentionExpired(last_heartbeat_ms, now_ms, DISCONNECTED_RETENTION_MS);
}

pub fn turnAbandonmentExpired(abandoned_at_ms: i64, now_ms: i64, state: RetainedTurnState) bool {
    const ttl = switch (state) {
        .running, .approval_waiting => TURN_ABANDONMENT_GRACE_MS,
        .completed => TURN_RETENTION_TTL_MS,
    };
    return retentionExpired(abandoned_at_ms, now_ms, ttl);
}

pub fn staleAttachExpired(last_attach_ms: i64, now_ms: i64) bool {
    return retentionExpired(last_attach_ms, now_ms, STALE_ATTACH_TIMEOUT_MS);
}

pub const RegistryJobKind = enum {
    load_config,
    start_managed_process,
    stop_managed_process,
    restart_managed_process,
    fanout_notification,
};

pub const RegistryJob = struct {
    kind: RegistryJobKind,
    workspace_id: []u8 = &.{},
    process_id: []u8 = &.{},
    client_id: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, kind: RegistryJobKind, workspace_id: []const u8, process_id: []const u8, client_id: []const u8) !RegistryJob {
        const owned_workspace_id = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(owned_workspace_id);
        const owned_process_id = try allocator.dupe(u8, process_id);
        errdefer allocator.free(owned_process_id);
        const owned_client_id = try allocator.dupe(u8, client_id);
        return .{
            .kind = kind,
            .workspace_id = owned_workspace_id,
            .process_id = owned_process_id,
            .client_id = owned_client_id,
        };
    }

    pub fn deinit(self: *RegistryJob, allocator: std.mem.Allocator) void {
        if (self.workspace_id.len != 0) allocator.free(self.workspace_id);
        if (self.process_id.len != 0) allocator.free(self.process_id);
        if (self.client_id.len != 0) allocator.free(self.client_id);
    }
};

/// Bounded FIFO used to hand slow registry work to an unlocked worker.
pub const RegistryJobQueue = struct {
    jobs: std.ArrayList(RegistryJob) = .empty,
    capacity: usize = REGISTRY_JOB_QUEUE_MAX,

    pub fn init(capacity: usize) !RegistryJobQueue {
        if (capacity == 0) return error.JobQueueCapacityRequired;
        return .{ .capacity = capacity };
    }

    pub fn deinit(self: *RegistryJobQueue, allocator: std.mem.Allocator) void {
        for (self.jobs.items) |*job| job.deinit(allocator);
        self.jobs.deinit(allocator);
    }

    pub fn push(self: *RegistryJobQueue, allocator: std.mem.Allocator, job: RegistryJob) !void {
        if (self.jobs.items.len >= self.capacity) return error.JobQueueFull;
        var owned_job = job;
        errdefer owned_job.deinit(allocator);
        try self.jobs.append(allocator, owned_job);
    }

    pub fn take(self: *RegistryJobQueue) ?RegistryJob {
        if (self.jobs.items.len == 0) return null;
        return self.jobs.orderedRemove(0);
    }

    pub fn peek(self: *const RegistryJobQueue) ?*const RegistryJob {
        if (self.jobs.items.len == 0) return null;
        return &self.jobs.items[0];
    }

    pub fn len(self: *const RegistryJobQueue) usize {
        return self.jobs.items.len;
    }

    pub fn isFull(self: *const RegistryJobQueue) bool {
        return self.jobs.items.len >= self.capacity;
    }
};

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

/// Resource comparison is exact set overlap; resource names are not prefixes.
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

pub const ManagedProcessStatus = enum {
    stopped,
    starting,
    running,
    stopping,
    crashed,
    restarting,
};

/// Daemon-owned configured process metadata. Runtime launch policy remains
/// outside this pure module; this record only stores coordination state.
pub const ManagedProcess = struct {
    workspace_id: []u8,
    id: []u8,
    name: []u8,
    command: []u8,
    cwd: []u8,
    resources: std.ArrayList([]u8) = .empty,
    status: ManagedProcessStatus = .stopped,
    pid: ?u32 = null,
    process_group: ?u32 = null,
    generation: u64 = 0,
    last_start_ms: i64 = 0,
    last_exit_ms: i64 = 0,
    explicit_stop: bool = false,
    restart_count: u32 = 0,
    runtime_state: ManagedProcessRuntimeState = .configured,
    runtime: ManagedProcessRuntime = .{},
    session_id: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        id: []const u8,
        name: []const u8,
        command: []const u8,
        cwd: []const u8,
    ) !ManagedProcess {
        const owned_workspace_id = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(owned_workspace_id);
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        const owned_cwd = try allocator.dupe(u8, cwd);
        return .{
            .workspace_id = owned_workspace_id,
            .id = owned_id,
            .name = owned_name,
            .command = owned_command,
            .cwd = owned_cwd,
        };
    }

    pub fn deinit(self: *ManagedProcess, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.command);
        allocator.free(self.cwd);
        deinitOwnedStringList(allocator, &self.resources);
        if (self.session_id) |session_id| allocator.free(session_id);
    }

    /// Apply an observed lifecycle event and mirror the pure runtime state in
    /// the legacy managed-process fields used by the desktop projection.
    pub fn transition(self: *ManagedProcess, event: ManagedProcessRuntimeEvent, now_ms: i64) !void {
        try self.runtime.transition(event, now_ms);
        self.runtime_state = self.runtime.state;
        self.generation = self.runtime.generation;
        self.restart_count = self.runtime.restart_count;
        self.explicit_stop = self.runtime.explicit_stop;
        if (self.runtime.last_start_ms) |last_start_ms| self.last_start_ms = last_start_ms;
        if (self.runtime.last_exit_ms) |last_exit_ms| self.last_exit_ms = last_exit_ms;
        self.status = switch (self.runtime.state) {
            .configured, .stopped => .stopped,
            .starting => .starting,
            .running => .running,
            .failed => .crashed,
        };
    }
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
    pane_id: ?u32 = null,
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
    workspace_id: []u8,
    process_id: []u8,
    generation: u64,
    process_identity: u32,
    session_id: []u8,
    command: []u8,
    cwd: []u8,
    pid: ?u32,
    process_group: ?u32,
    started_at_ms: i64,
    dock_id: u32,
    pane_id: ?u32,
    owner_kind: []u8,
    owner_title: []u8,
    provider: ?[]u8,
    missing_since_ms: ?i64 = null,

    fn init(
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        process_id: []u8,
        generation: u64,
        observation: TerminalProcessObservation,
    ) !TrackedTerminalProcess {
        errdefer allocator.free(process_id);
        const owned_workspace_id = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(owned_workspace_id);
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
            .workspace_id = owned_workspace_id,
            .process_id = process_id,
            .generation = generation,
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

    pub fn deinit(self: *TrackedTerminalProcess, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.process_id);
        allocator.free(self.session_id);
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.free(self.owner_kind);
        allocator.free(self.owner_title);
        if (self.provider) |value| allocator.free(value);
    }
};

pub const TerminalProcessOutcomeStatus = enum {
    completed,
    failed,
    cancelled,
    crashed,
    unknown,
};

pub const TerminalProcessOutcome = struct {
    workspace_id: []u8,
    process_id: []u8,
    generation: u64,
    session_id: []u8,
    command: []u8,
    cwd: []u8,
    pid: ?u32,
    process_group: ?u32,
    started_at_ms: i64,
    finished_at_ms: i64,
    dock_id: u32,
    pane_id: ?u32,
    owner_kind: []u8,
    owner_title: []u8,
    provider: ?[]u8,
    status: TerminalProcessOutcomeStatus,
    exit_code: ?u32,
    signal: ?u32,
    cancellation_reason: ?[]u8,

    pub fn deinit(self: *TerminalProcessOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
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

pub const ExternalProcessStatus = enum {
    running,
    completed,
    failed,
    cancelled,
    crashed,
    unknown,
};

/// Provider turns and background tasks are represented without importing UI
/// or AppState; the daemon can later populate and update this record.
pub const ExternalProcess = struct {
    workspace_id: []u8,
    process_id: []u8,
    command: []u8,
    cwd: []u8,
    owner_kind: []u8,
    owner_title: []u8,
    client_id: []u8,
    pid: ?u32 = null,
    process_group: ?u32 = null,
    generation: u64 = 0,
    started_at_ms: i64 = 0,
    finished_at_ms: ?i64 = null,
    status: ExternalProcessStatus = .running,

    pub fn init(
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        process_id: []const u8,
        command: []const u8,
        cwd: []const u8,
        owner_kind: []const u8,
        owner_title: []const u8,
        client_id: []const u8,
    ) !ExternalProcess {
        const owned_workspace_id = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(owned_workspace_id);
        const owned_process_id = try allocator.dupe(u8, process_id);
        errdefer allocator.free(owned_process_id);
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        const owned_cwd = try allocator.dupe(u8, cwd);
        errdefer allocator.free(owned_cwd);
        const owned_owner_kind = try allocator.dupe(u8, owner_kind);
        errdefer allocator.free(owned_owner_kind);
        const owned_owner_title = try allocator.dupe(u8, owner_title);
        errdefer allocator.free(owned_owner_title);
        const owned_client_id = try allocator.dupe(u8, client_id);
        return .{
            .workspace_id = owned_workspace_id,
            .process_id = owned_process_id,
            .command = owned_command,
            .cwd = owned_cwd,
            .owner_kind = owned_owner_kind,
            .owner_title = owned_owner_title,
            .client_id = owned_client_id,
        };
    }

    pub fn deinit(self: *ExternalProcess, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.process_id);
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.free(self.owner_kind);
        allocator.free(self.owner_title);
        allocator.free(self.client_id);
    }
};

pub const LeaseRecord = struct {
    workspace_id: []u8,
    id: []u8,
    owner: []u8,
    client_id: []u8,
    command: []u8,
    resources: std.ArrayList([]u8) = .empty,
    created_at_ms: i64,
    expires_at_ms: i64,
    last_renewal_ms: i64,

    fn init(
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        id: []u8,
        owner: []const u8,
        client_id: []const u8,
        command: []const u8,
        resources: []const []const u8,
        now_ms: i64,
    ) !LeaseRecord {
        errdefer allocator.free(id);
        const owned_workspace_id = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(owned_workspace_id);
        const owned_owner = try allocator.dupe(u8, owner);
        errdefer allocator.free(owned_owner);
        const owned_client_id = try allocator.dupe(u8, client_id);
        errdefer allocator.free(owned_client_id);
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        var owned_resources: std.ArrayList([]u8) = .empty;
        errdefer deinitOwnedStringList(allocator, &owned_resources);
        for (resources) |resource| try appendOwnedString(allocator, &owned_resources, resource);
        return .{
            .workspace_id = owned_workspace_id,
            .id = id,
            .owner = owned_owner,
            .client_id = owned_client_id,
            .command = owned_command,
            .resources = owned_resources,
            .created_at_ms = now_ms,
            .expires_at_ms = checkedLeaseExpiry(now_ms),
            .last_renewal_ms = now_ms,
        };
    }

    pub fn deinit(self: *LeaseRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.id);
        allocator.free(self.owner);
        allocator.free(self.client_id);
        allocator.free(self.command);
        deinitOwnedStringList(allocator, &self.resources);
    }
};

pub const AffectedAgent = struct {
    owner: []const u8,
    client_id: []const u8,
    lease_id: []const u8,
    command: []const u8,
};

pub const LeaseConflictInfo = struct {
    owner: []const u8,
    client_id: []const u8,
    lease_id: []const u8,
    command: []const u8,
    resources: []const []u8,
};

pub const LeaseAcquireResult = struct {
    lease: *LeaseRecord,
    /// Borrowed views valid until the registry is next mutated.
    affected_agents: std.ArrayList(AffectedAgent) = .empty,

    pub fn deinit(self: *LeaseAcquireResult, allocator: std.mem.Allocator) void {
        self.affected_agents.deinit(allocator);
    }
};

pub const WorkspaceRecord = struct {
    id: []u8,
    canonical_path: ?[]u8 = null,
    path_aliases: std.ArrayList(WorkspacePathAlias) = .empty,
    last_seen_ms: i64 = 0,
    managed_processes: std.ArrayList(ManagedProcess) = .empty,
    tracked_terminal_processes: std.ArrayList(TrackedTerminalProcess) = .empty,
    external_processes: std.ArrayList(ExternalProcess) = .empty,
    terminal_process_outcomes: std.ArrayList(TerminalProcessOutcome) = .empty,
    leases: std.ArrayList(LeaseRecord) = .empty,
    notifications: NotificationMailbox = .{},
    retained_turns: std.ArrayList(RetainedTurn) = .empty,
    next_terminal_generation: u64 = 1,

    fn init(allocator: std.mem.Allocator, id: []const u8) !WorkspaceRecord {
        return .{ .id = try allocator.dupe(u8, id) };
    }

    fn deinit(self: *WorkspaceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.canonical_path) |path| allocator.free(path);
        for (self.path_aliases.items) |*alias| alias.deinit(allocator);
        self.path_aliases.deinit(allocator);
        for (self.managed_processes.items) |*process| process.deinit(allocator);
        self.managed_processes.deinit(allocator);
        for (self.tracked_terminal_processes.items) |*process| process.deinit(allocator);
        self.tracked_terminal_processes.deinit(allocator);
        for (self.external_processes.items) |*process| process.deinit(allocator);
        self.external_processes.deinit(allocator);
        for (self.terminal_process_outcomes.items) |*outcome| outcome.deinit(allocator);
        self.terminal_process_outcomes.deinit(allocator);
        for (self.leases.items) |*lease| lease.deinit(allocator);
        self.leases.deinit(allocator);
        self.notifications.deinit(allocator);
        for (self.retained_turns.items) |*turn| turn.deinit(allocator);
        self.retained_turns.deinit(allocator);
    }
};

pub const ProcessRegistry = struct {
    /// A new daemon instance chooses a fresh nonce. Lease IDs therefore stay
    /// opaque and cannot collide with IDs from a prior instance.
    instance_nonce: []u8,
    next_lease_counter: u64 = 1,
    /// Volatile, per-daemon-instance snapshot revision. It resets when the
    /// instance nonce changes and is never durable state.
    registry_revision: u64 = 0,
    workspaces: std.ArrayList(WorkspaceRecord) = .empty,
    clients: std.StringHashMapUnmanaged(ClientRecord) = .empty,
    next_client_counter: u64 = 1,
    notification_count: usize = 0,
    notification_global_cap: usize = NOTIFICATION_GLOBAL_MAX,
    next_notification_order: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, instance_nonce: []const u8) !ProcessRegistry {
        if (instance_nonce.len == 0) return error.InstanceNonceRequired;
        return .{ .instance_nonce = try allocator.dupe(u8, instance_nonce) };
    }

    pub fn deinit(self: *ProcessRegistry, allocator: std.mem.Allocator) void {
        allocator.free(self.instance_nonce);
        for (self.workspaces.items) |*workspace_record| workspace_record.deinit(allocator);
        self.workspaces.deinit(allocator);
        var client_iterator = self.clients.iterator();
        while (client_iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.clients.deinit(allocator);
    }

    /// Returns a borrowed workspace record. The pointer is invalidated by any
    /// registry mutation that reallocates, removes, or replaces workspace data;
    /// phase-2 callers must copy views while holding the registry lock/queue.
    pub fn workspace(self: *ProcessRegistry, workspace_id: []const u8) ?*WorkspaceRecord {
        for (self.workspaces.items) |*workspace_record| {
            if (std.mem.eql(u8, workspace_record.id, workspace_id)) return workspace_record;
        }
        return null;
    }

    /// Return a borrowed client record. The pointer is invalidated by a later
    /// client registration or removal.
    pub fn client(self: *ProcessRegistry, client_id: []const u8) ?*ClientRecord {
        return self.clients.getPtr(client_id);
    }

    /// Issue a daemon-scoped opaque client ID. The nonce is part of the ID so
    /// a client from a previous daemon instance cannot be mistaken for live
    /// state in this registry.
    pub fn registerClient(self: *ProcessRegistry, allocator: std.mem.Allocator, persistent: bool, now_ms: i64) !*ClientRecord {
        const client_id = try std.fmt.allocPrint(allocator, "client:{s}:{d}", .{ self.instance_nonce, self.next_client_counter });
        errdefer allocator.free(client_id);
        self.next_client_counter +%= 1;
        if (self.next_client_counter == 0) self.next_client_counter = 1;

        const key = try allocator.dupe(u8, client_id);
        errdefer allocator.free(key);
        try self.clients.put(allocator, key, .{
            .client_id = client_id,
            .last_heartbeat_ms = now_ms,
            .persistent = persistent,
        });
        self.bumpRevision();
        return self.clients.getPtr(client_id).?;
    }

    pub fn heartbeatClient(self: *ProcessRegistry, client_id: []const u8, now_ms: i64) bool {
        const record = self.client(client_id) orelse return false;
        if (record.closed) return false;
        record.last_heartbeat_ms = now_ms;
        self.bumpRevision();
        return true;
    }

    pub fn closeClient(self: *ProcessRegistry, client_id: []const u8, now_ms: i64) bool {
        const record = self.client(client_id) orelse return false;
        if (record.closed) return false;
        record.closed = true;
        record.closed_at_ms = now_ms;
        self.bumpRevision();
        return true;
    }

    /// Derive a stable compatibility ID for legacy owner/session callers.
    /// The owner itself is never used as a client ID on the wire.
    pub fn deriveCompatibilityClientId(allocator: std.mem.Allocator, owner: []const u8) ![]u8 {
        if (owner.len == 0) return error.ClientOwnerRequired;
        return std.fmt.allocPrint(allocator, "compat:{x}", .{std.hash.Wyhash.hash(0, owner)});
    }

    /// Register or refresh the short-lived compatibility client associated
    /// with an owner string. The returned record is borrowed from the map.
    pub fn ensureCompatibilityClient(self: *ProcessRegistry, allocator: std.mem.Allocator, owner: []const u8, now_ms: i64) !*ClientRecord {
        const derived_id = try deriveCompatibilityClientId(allocator, owner);
        defer allocator.free(derived_id);
        if (self.client(derived_id)) |record| {
            record.last_heartbeat_ms = now_ms;
            record.closed = false;
            record.closed_at_ms = null;
            return record;
        }

        const client_id = try allocator.dupe(u8, derived_id);
        errdefer allocator.free(client_id);
        const key = try allocator.dupe(u8, derived_id);
        errdefer allocator.free(key);
        try self.clients.put(allocator, key, .{
            .client_id = client_id,
            .last_heartbeat_ms = now_ms,
            .compatibility = true,
        });
        self.bumpRevision();
        return self.client(derived_id).?;
    }

    /// Look up a path alias without creating a second workspace identity.
    pub fn workspaceByPath(self: *ProcessRegistry, allocator: std.mem.Allocator, path: []const u8, now_ms: i64) ?*WorkspaceRecord {
        if (path.len == 0) return null;
        _ = self.pruneWorkspacePathAliases(allocator, now_ms);
        for (self.workspaces.items) |*workspace_record| {
            if (workspace_record.canonical_path) |canonical_path| {
                if (std.mem.eql(u8, canonical_path, path)) {
                    workspace_record.last_seen_ms = now_ms;
                    return workspace_record;
                }
            }
            for (workspace_record.path_aliases.items) |*alias| {
                if (std.mem.eql(u8, alias.path, path)) {
                    alias.last_seen_ms = now_ms;
                    workspace_record.last_seen_ms = now_ms;
                    return workspace_record;
                }
            }
        }
        return null;
    }

    /// Record a canonical path or lookup alias. A path already owned by a
    /// different workspace is rejected instead of being silently reassigned.
    pub fn registerWorkspacePath(self: *ProcessRegistry, allocator: std.mem.Allocator, workspace_id: []const u8, path: []const u8, now_ms: i64) !*WorkspaceRecord {
        if (path.len == 0) return error.WorkspacePathRequired;
        _ = self.pruneWorkspacePathAliases(allocator, now_ms);
        for (self.workspaces.items) |candidate| {
            if (std.mem.eql(u8, candidate.id, workspace_id)) continue;
            if (candidate.canonical_path) |canonical_path| {
                if (std.mem.eql(u8, canonical_path, path)) return error.WorkspacePathMapsToDifferentId;
            }
            for (candidate.path_aliases.items) |alias| {
                if (std.mem.eql(u8, alias.path, path)) return error.WorkspacePathMapsToDifferentId;
            }
        }
        const workspace_record = try self.ensureWorkspace(allocator, workspace_id);

        for (self.workspaces.items) |*candidate| {
            if (std.mem.eql(u8, candidate.id, workspace_record.id)) continue;
            if (candidate.canonical_path) |canonical_path| {
                if (std.mem.eql(u8, canonical_path, path)) return error.WorkspacePathMapsToDifferentId;
            }
            for (candidate.path_aliases.items) |alias| {
                if (std.mem.eql(u8, alias.path, path)) return error.WorkspacePathMapsToDifferentId;
            }
        }

        if (workspace_record.canonical_path) |canonical_path| {
            if (std.mem.eql(u8, canonical_path, path)) {
                workspace_record.last_seen_ms = now_ms;
                self.bumpRevision();
                return workspace_record;
            }
        } else {
            workspace_record.canonical_path = try allocator.dupe(u8, path);
            workspace_record.last_seen_ms = now_ms;
            self.bumpRevision();
            return workspace_record;
        }

        for (workspace_record.path_aliases.items) |*alias| {
            if (std.mem.eql(u8, alias.path, path)) {
                alias.last_seen_ms = now_ms;
                workspace_record.last_seen_ms = now_ms;
                self.bumpRevision();
                return workspace_record;
            }
        }

        while (workspace_record.path_aliases.items.len >= WORKSPACE_PATH_ALIAS_MAX) {
            var removed = workspace_record.path_aliases.orderedRemove(0);
            removed.deinit(allocator);
        }
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        try workspace_record.path_aliases.append(allocator, .{
            .path = owned_path,
            .last_seen_ms = now_ms,
        });
        workspace_record.last_seen_ms = now_ms;
        _ = self.pruneWorkspacePathAliasesToCap(allocator);
        self.bumpRevision();
        return workspace_record;
    }

    /// Returns a borrowed workspace record. The pointer is invalidated by a
    /// later registry mutation, so phase-2 callers must copy data while holding
    /// the registry lock/queue.
    pub fn ensureWorkspace(self: *ProcessRegistry, allocator: std.mem.Allocator, workspace_id: []const u8) !*WorkspaceRecord {
        if (workspace_id.len == 0) return error.WorkspaceIdRequired;
        if (self.workspace(workspace_id)) |workspace_record| return workspace_record;
        _ = self.evictIdleWorkspaces(allocator, 0);
        if (self.workspaces.items.len >= WORKSPACE_RECORD_MAX) return error.WorkspaceCapacityExceeded;
        var workspace_record = try WorkspaceRecord.init(allocator, workspace_id);
        errdefer workspace_record.deinit(allocator);
        try self.workspaces.append(allocator, workspace_record);
        self.bumpRevision();
        return &self.workspaces.items[self.workspaces.items.len - 1];
    }

    /// Append one pull-only notification without revoking or changing any
    /// lease. Callers that are already publishing a larger mutation can use
    /// `appendNotificationInternal` and bump the revision once for the batch.
    pub fn queueNotification(
        self: *ProcessRegistry,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        owner_session_id: []const u8,
        command: []const u8,
        now_ms: i64,
    ) !void {
        try self.appendNotificationInternal(allocator, workspace_id, owner_session_id, command, now_ms);
        self.bumpRevision();
    }

    /// Collect borrowed notification pointers for a workspace/session cursor.
    /// The returned cursor is the next sequence number, including evicted
    /// entries, so a client can persist it without observing gaps as errors.
    pub fn collectNotifications(
        self: *ProcessRegistry,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        owner_session_id: ?[]const u8,
        after_seq: u64,
        limit: usize,
        out: *std.ArrayList(*const Notification),
    ) !u64 {
        const workspace_record = self.workspace(workspace_id) orelse return 0;
        return workspace_record.notifications.collect(allocator, owner_session_id, after_seq, limit, out);
    }

    pub fn pruneNotifications(self: *ProcessRegistry, allocator: std.mem.Allocator, now_ms: i64) usize {
        var removed_count: usize = 0;
        for (self.workspaces.items) |*workspace_record| {
            removed_count += workspace_record.notifications.pruneExpired(allocator, now_ms);
        }
        if (removed_count != 0) {
            self.notification_count -|= removed_count;
            self.bumpRevision();
        }
        return removed_count;
    }

    pub fn retainTurn(self: *ProcessRegistry, allocator: std.mem.Allocator, workspace_id: []const u8, turn_id: []const u8, state: RetainedTurnState, abandoned_at_ms: i64) !void {
        const workspace_record = try self.ensureWorkspace(allocator, workspace_id);
        var retained_turn = try RetainedTurn.init(allocator, workspace_id, turn_id, state, abandoned_at_ms);
        errdefer retained_turn.deinit(allocator);
        try workspace_record.retained_turns.append(allocator, retained_turn);
        while (workspace_record.retained_turns.items.len > TURN_RETENTION_MAX) {
            var removed = workspace_record.retained_turns.orderedRemove(0);
            removed.deinit(allocator);
        }
        self.bumpRevision();
    }

    pub fn reapRetainedTurns(self: *ProcessRegistry, allocator: std.mem.Allocator, now_ms: i64) usize {
        var removed_count: usize = 0;
        for (self.workspaces.items) |*workspace_record| {
            var index: usize = 0;
            while (index < workspace_record.retained_turns.items.len) {
                const turn = workspace_record.retained_turns.items[index];
                if (!retainedTurnExpired(turn, now_ms)) {
                    index += 1;
                    continue;
                }
                var removed = workspace_record.retained_turns.orderedRemove(index);
                removed.deinit(allocator);
                removed_count += 1;
            }
        }
        if (removed_count != 0) self.bumpRevision();
        return removed_count;
    }

    /// Run all clock-driven bounded cleanup rules owned by this module.
    pub fn reap(self: *ProcessRegistry, allocator: std.mem.Allocator, now_ms: i64) RegistryReapCounts {
        var counts: RegistryReapCounts = .{};
        counts.aliases = self.pruneWorkspacePathAliases(allocator, now_ms);
        counts.notifications = self.pruneNotifications(allocator, now_ms);
        counts.turns = self.reapRetainedTurns(allocator, now_ms);
        for (self.workspaces.items) |workspace_record| {
            counts.outcomes += self.pruneTerminalProcessOutcomes(allocator, workspace_record.id, now_ms);
            counts.leases += self.pruneExpiredLeases(allocator, workspace_record.id, now_ms);
        }
        counts.workspaces = self.evictIdleWorkspaces(allocator, now_ms);
        return counts;
    }

    pub fn evictIdleWorkspaces(self: *ProcessRegistry, allocator: std.mem.Allocator, now_ms: i64) usize {
        _ = self.pruneWorkspacePathAliases(allocator, now_ms);
        var removed_count: usize = 0;
        var index: usize = 0;
        while (index < self.workspaces.items.len) {
            const workspace_record = &self.workspaces.items[index];
            if (workspaceRecordHasLiveReferences(workspace_record) or !retentionExpired(workspace_record.last_seen_ms, now_ms, WORKSPACE_PATH_ALIAS_TTL_MS)) {
                index += 1;
                continue;
            }
            self.removeWorkspaceAt(allocator, index);
            removed_count += 1;
        }

        while (self.workspaces.items.len > WORKSPACE_RECORD_MAX) {
            const index_to_remove = self.oldestEvictableWorkspaceIndex();
            if (index_to_remove == null) break;
            self.removeWorkspaceAt(allocator, index_to_remove.?);
            removed_count += 1;
        }
        if (removed_count != 0) self.bumpRevision();
        return removed_count;
    }

    fn appendNotificationInternal(
        self: *ProcessRegistry,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        owner_session_id: []const u8,
        command: []const u8,
        now_ms: i64,
    ) !void {
        const workspace_record = try self.ensureWorkspace(allocator, workspace_id);
        const removed_count = try workspace_record.notifications.append(
            allocator,
            workspace_id,
            owner_session_id,
            command,
            now_ms,
            self.next_notification_order,
        );
        self.notification_count -|= removed_count;
        self.notification_count += 1;
        self.next_notification_order +%= 1;
        if (self.next_notification_order == 0) self.next_notification_order = 1;
        self.pruneNotificationsToGlobalCap(allocator);
    }

    fn pruneNotificationsToGlobalCap(self: *ProcessRegistry, allocator: std.mem.Allocator) void {
        while (self.notification_count > self.notification_global_cap) {
            var oldest_workspace_index: ?usize = null;
            var oldest_entry_index: ?usize = null;
            var oldest_order_seq: u64 = std.math.maxInt(u64);
            for (self.workspaces.items, 0..) |workspace_record, workspace_index| {
                for (workspace_record.notifications.entries.items, 0..) |entry, entry_index| {
                    if (entry.order_seq < oldest_order_seq) {
                        oldest_order_seq = entry.order_seq;
                        oldest_workspace_index = workspace_index;
                        oldest_entry_index = entry_index;
                    }
                }
            }
            if (oldest_workspace_index == null or oldest_entry_index == null) break;
            self.workspaces.items[oldest_workspace_index.?].notifications.removeAt(allocator, oldest_entry_index.?);
            self.notification_count -= 1;
        }
    }

    fn pruneWorkspacePathAliases(self: *ProcessRegistry, allocator: std.mem.Allocator, now_ms: i64) usize {
        var removed_count: usize = 0;
        for (self.workspaces.items) |*workspace_record| {
            var index: usize = 0;
            while (index < workspace_record.path_aliases.items.len) {
                const alias = workspace_record.path_aliases.items[index];
                if (!retentionExpired(alias.last_seen_ms, now_ms, WORKSPACE_PATH_ALIAS_TTL_MS)) {
                    index += 1;
                    continue;
                }
                var removed = workspace_record.path_aliases.orderedRemove(index);
                removed.deinit(allocator);
                removed_count += 1;
            }
        }
        removed_count += self.pruneWorkspacePathAliasesToCap(allocator);
        return removed_count;
    }

    fn pruneWorkspacePathAliasesToCap(self: *ProcessRegistry, allocator: std.mem.Allocator) usize {
        var total = self.pathAliasCount();
        var removed_count: usize = 0;
        while (total > WORKSPACE_PATH_ALIAS_GLOBAL_MAX) {
            var oldest_workspace_index: ?usize = null;
            var oldest_alias_index: ?usize = null;
            var oldest_seen_ms: i64 = std.math.maxInt(i64);
            for (self.workspaces.items, 0..) |workspace_record, workspace_index| {
                for (workspace_record.path_aliases.items, 0..) |alias, alias_index| {
                    if (alias.last_seen_ms < oldest_seen_ms) {
                        oldest_seen_ms = alias.last_seen_ms;
                        oldest_workspace_index = workspace_index;
                        oldest_alias_index = alias_index;
                    }
                }
            }
            if (oldest_workspace_index == null or oldest_alias_index == null) break;
            var removed = self.workspaces.items[oldest_workspace_index.?].path_aliases.orderedRemove(oldest_alias_index.?);
            removed.deinit(allocator);
            total -= 1;
            removed_count += 1;
        }
        return removed_count;
    }

    fn pathAliasCount(self: *const ProcessRegistry) usize {
        var count: usize = 0;
        for (self.workspaces.items) |workspace_record| count += workspace_record.path_aliases.items.len;
        return count;
    }

    fn oldestEvictableWorkspaceIndex(self: *const ProcessRegistry) ?usize {
        var oldest_index: ?usize = null;
        var oldest_seen_ms: i64 = std.math.maxInt(i64);
        for (self.workspaces.items, 0..) |workspace_record, index| {
            if (workspaceRecordHasLiveReferences(&workspace_record)) continue;
            if (workspace_record.last_seen_ms < oldest_seen_ms) {
                oldest_seen_ms = workspace_record.last_seen_ms;
                oldest_index = index;
            }
        }
        return oldest_index;
    }

    fn removeWorkspaceAt(self: *ProcessRegistry, allocator: std.mem.Allocator, index: usize) void {
        var removed = self.workspaces.orderedRemove(index);
        removed.deinit(allocator);
    }

    /// Replaces the daemon namespace after a restart. Existing records remain
    /// available for graceful handoff, while future IDs use the new nonce.
    pub fn replaceInstanceNonce(self: *ProcessRegistry, allocator: std.mem.Allocator, instance_nonce: []const u8) !void {
        if (instance_nonce.len == 0) return error.InstanceNonceRequired;
        const replacement = try allocator.dupe(u8, instance_nonce);
        allocator.free(self.instance_nonce);
        self.instance_nonce = replacement;
        self.next_lease_counter = 1;
        self.next_client_counter = 1;
        self.registry_revision = 0;
    }

    pub fn pruneExpiredLeases(self: *ProcessRegistry, allocator: std.mem.Allocator, workspace_id: []const u8, now_ms: i64) usize {
        const workspace_record = self.workspace(workspace_id) orelse return 0;
        const removed = pruneExpiredLeaseList(&workspace_record.leases, allocator, now_ms);
        if (removed != 0) self.bumpRevision();
        return removed;
    }

    /// Acquires or renews a lease. `LeaseAcquireResult.lease` and its affected
    /// agent views borrow registry storage and are invalidated by a later
    /// mutation; phase-2 callers must copy them while holding the registry
    /// lock/queue.
    pub fn acquireLease(
        self: *ProcessRegistry,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        owner: []const u8,
        client_id: []const u8,
        command: []const u8,
        resources: []const []const u8,
        force: bool,
        now_ms: i64,
    ) !LeaseAcquireResult {
        if (owner.len == 0) return error.LeaseOwnerRequired;
        if (resources.len == 0) return error.LeaseResourcesRequired;
        const workspace_record = try self.ensureWorkspace(allocator, workspace_id);
        _ = self.pruneExpiredLeases(allocator, workspace_id, now_ms);

        var result: LeaseAcquireResult = .{ .lease = undefined };
        errdefer result.deinit(allocator);
        var renewal_handler = RegistryLeaseRenewalHandler{};
        var conflict_observer = RegistryLeaseConflictObserver{ .affected_agents = &result.affected_agents };
        const lease_index = try acquireLeaseInListWithPolicy(
            &workspace_record.leases,
            allocator,
            workspace_id,
            client_id,
            owner,
            command,
            resources,
            WORKSPACE_LEASE_TTL_MS,
            force,
            now_ms,
            .@"opaque",
            workspace_id,
            self.instance_nonce,
            &self.next_lease_counter,
            initRegistryLease,
            &renewal_handler,
            &conflict_observer,
        );
        if (force) {
            for (result.affected_agents.items, 0..) |affected, index| {
                if (notificationOwnerAlreadyQueued(result.affected_agents.items[0..index], affected.owner)) continue;
                try self.appendNotificationInternal(allocator, workspace_id, affected.owner, command, now_ms);
            }
        }
        self.bumpRevision();
        result.lease = &workspace_record.leases.items[lease_index];
        return result;
    }

    /// Returns borrowed conflict metadata after pruning expired leases. The
    /// fields and resource slices are invalidated by a later registry mutation;
    /// phase-2 callers must copy them while holding the registry lock/queue.
    pub fn checkLeaseConflicts(
        self: *ProcessRegistry,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        owner: []const u8,
        resources: []const []const u8,
        now_ms: i64,
        conflicts: *std.ArrayList(LeaseConflictInfo),
    ) !void {
        if (resources.len == 0) return error.LeaseResourcesRequired;
        var normalized = try normalizeResources(allocator, resources);
        defer deinitOwnedStringList(allocator, &normalized);
        _ = self.pruneExpiredLeases(allocator, workspace_id, now_ms);
        const workspace_record = self.workspace(workspace_id) orelse return;
        for (workspace_record.leases.items) |existing| {
            if (std.mem.eql(u8, existing.owner, owner)) continue;
            if (!workspaceResourcesOverlap(existing.resources.items, normalized.items)) continue;
            try conflicts.append(allocator, .{
                .owner = existing.owner,
                .client_id = existing.client_id,
                .lease_id = existing.id,
                .command = existing.command,
                .resources = existing.resources.items,
            });
        }
    }

    pub fn releaseLease(
        self: *ProcessRegistry,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        owner: []const u8,
        lease_id: ?[]const u8,
        now_ms: i64,
    ) usize {
        if (owner.len == 0) return 0;
        const workspace_record = self.workspace(workspace_id) orelse return 0;
        _ = self.pruneExpiredLeases(allocator, workspace_id, now_ms);
        const released = releaseLeaseList(&workspace_record.leases, allocator, owner, lease_id);
        if (released != 0) self.bumpRevision();
        return released;
    }

    pub fn activeLeaseCount(self: *ProcessRegistry, allocator: std.mem.Allocator, workspace_id: []const u8, now_ms: i64) usize {
        _ = self.pruneExpiredLeases(allocator, workspace_id, now_ms);
        return if (self.workspace(workspace_id)) |workspace_record| workspace_record.leases.items.len else 0;
    }

    /// Returns a borrowed tracked process pointer, invalidated by later
    /// registry mutations. Phase-2 callers must copy it while holding the
    /// registry lock/queue.
    pub fn observeTerminalProcess(
        self: *ProcessRegistry,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        observation: TerminalProcessObservation,
        replaced_finish: TerminalProcessFinish,
    ) !*TrackedTerminalProcess {
        const workspace_record = try self.ensureWorkspace(allocator, workspace_id);
        var replaced_index: ?usize = null;
        for (workspace_record.tracked_terminal_processes.items, 0..) |*tracked, index| {
            if (!std.mem.eql(u8, tracked.session_id, observation.session_id)) continue;
            if (tracked.process_identity == observation.process_identity) {
                tracked.missing_since_ms = null;
                return tracked;
            }
            replaced_index = index;
            break;
        }

        const generation = workspace_record.next_terminal_generation;
        const process_id = try std.fmt.allocPrint(allocator, "term:{s}:{d}", .{ observation.session_id, generation });
        var tracked = try TrackedTerminalProcess.init(allocator, workspace_id, process_id, generation, observation);
        errdefer tracked.deinit(allocator);
        if (replaced_index) |index| {
            try finishTrackedTerminalProcess(allocator, workspace_record, index, replaced_finish, observation.observed_at_ms);
        }
        try workspace_record.tracked_terminal_processes.append(allocator, tracked);
        advanceGeneration(&workspace_record.next_terminal_generation);
        self.bumpRevision();
        return &workspace_record.tracked_terminal_processes.items[workspace_record.tracked_terminal_processes.items.len - 1];
    }

    /// Returns a borrowed tracked process pointer, invalidated by later
    /// registry mutations. Phase-2 callers must copy it while holding the
    /// registry lock/queue.
    pub fn terminalProcessActiveForSession(self: *ProcessRegistry, workspace_id: []const u8, session_id: []const u8) ?*TrackedTerminalProcess {
        const workspace_record = self.workspace(workspace_id) orelse return null;
        for (workspace_record.tracked_terminal_processes.items) |*tracked| {
            if (std.mem.eql(u8, tracked.session_id, session_id)) return tracked;
        }
        return null;
    }

    /// Keeps a foreground process observable briefly after it disappears so a
    /// shell exit from the same command can supply the authoritative status.
    pub fn terminalProcessMissingReady(self: *ProcessRegistry, workspace_id: []const u8, session_id: []const u8, observed_at_ms: i64) bool {
        const tracked = self.terminalProcessActiveForSession(workspace_id, session_id) orelse return false;
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

    pub fn finishTerminalProcess(
        self: *ProcessRegistry,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        session_id: []const u8,
        finish: TerminalProcessFinish,
        finished_at_ms: i64,
    ) !bool {
        const workspace_record = self.workspace(workspace_id) orelse return false;
        for (workspace_record.tracked_terminal_processes.items, 0..) |tracked, index| {
            if (!std.mem.eql(u8, tracked.session_id, session_id)) continue;
            try finishTrackedTerminalProcess(allocator, workspace_record, index, finish, finished_at_ms);
            self.bumpRevision();
            return true;
        }
        return false;
    }

    pub fn pruneTerminalProcessOutcomes(self: *ProcessRegistry, allocator: std.mem.Allocator, workspace_id: []const u8, now_ms: i64) usize {
        const workspace_record = self.workspace(workspace_id) orelse return 0;
        const removed = pruneOutcomeList(&workspace_record.terminal_process_outcomes, allocator, now_ms);
        if (removed != 0) self.bumpRevision();
        return removed;
    }

    /// Takes ownership of `process` and returns a borrowed registry pointer.
    /// The pointer is invalidated by later registry mutations; phase-2 callers
    /// must copy it while holding the registry lock/queue.
    pub fn registerExternalProcess(
        self: *ProcessRegistry,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        process: ExternalProcess,
    ) !*ExternalProcess {
        var owned_process = process;
        errdefer owned_process.deinit(allocator);
        const workspace_record = try self.ensureWorkspace(allocator, workspace_id);
        try workspace_record.external_processes.append(allocator, owned_process);
        self.bumpRevision();
        return &workspace_record.external_processes.items[workspace_record.external_processes.items.len - 1];
    }

    pub fn finishExternalProcess(self: *ProcessRegistry, workspace_id: []const u8, process_id: []const u8, status: ExternalProcessStatus, finished_at_ms: i64) bool {
        const workspace_record = self.workspace(workspace_id) orelse return false;
        for (workspace_record.external_processes.items) |*process| {
            if (!std.mem.eql(u8, process.process_id, process_id)) continue;
            process.status = status;
            process.finished_at_ms = finished_at_ms;
            self.bumpRevision();
            return true;
        }
        return false;
    }

    /// Bump only when the caller still owns this daemon instance namespace.
    /// A stale request cannot advance a replacement daemon's projection.
    pub fn bumpRegistryRevision(self: *ProcessRegistry, instance_nonce: []const u8) !u64 {
        if (!std.mem.eql(u8, self.instance_nonce, instance_nonce)) return error.InstanceNonceMismatch;
        self.bumpRevision();
        return self.registry_revision;
    }

    pub fn revisionForInstance(self: *const ProcessRegistry, instance_nonce: []const u8) ?u64 {
        if (!std.mem.eql(u8, self.instance_nonce, instance_nonce)) return null;
        return self.registry_revision;
    }

    fn bumpRevision(self: *ProcessRegistry) void {
        self.registry_revision +%= 1;
        if (self.registry_revision == 0) self.registry_revision = 1;
    }
};

pub const ManagedProcessRecord = ManagedProcess;
pub const TrackedTerminalProcessRecord = TrackedTerminalProcess;
pub const ExternalProcessRecord = ExternalProcess;
pub const Outcome = TerminalProcessOutcome;
pub const Lease = LeaseRecord;

fn retentionExpired(start_ms: i64, now_ms: i64, ttl_ms: i64) bool {
    if (now_ms < start_ms) return false;
    return now_ms - start_ms > ttl_ms;
}

fn retainedTurnExpired(turn: RetainedTurn, now_ms: i64) bool {
    return turnAbandonmentExpired(turn.abandoned_at_ms, now_ms, turn.state);
}

fn workspaceRecordHasLiveReferences(workspace_record: *const WorkspaceRecord) bool {
    return workspace_record.managed_processes.items.len != 0 or
        workspace_record.tracked_terminal_processes.items.len != 0 or
        workspace_record.external_processes.items.len != 0 or
        workspace_record.terminal_process_outcomes.items.len != 0 or
        workspace_record.leases.items.len != 0 or
        workspace_record.notifications.entries.items.len != 0 or
        workspace_record.retained_turns.items.len != 0;
}

fn checkedLeaseExpiry(now_ms: i64) i64 {
    return now_ms + WORKSPACE_LEASE_TTL_MS;
}

fn advanceGeneration(generation: *u64) void {
    generation.* +%= 1;
    if (generation.* == 0) generation.* = 1;
}

fn processOutcomeStatus(finish: TerminalProcessFinish) TerminalProcessOutcomeStatus {
    if (finish.cancellation_reason != null) return .cancelled;
    if (finish.exit_code) |exit_code| return if (exit_code == 0) .completed else .failed;
    if (finish.signal != null) return .crashed;
    return .unknown;
}

pub fn processIdentity(process_group: ?u32, pid: ?u32) u32 {
    return process_group orelse pid orelse 0;
}

fn finishTrackedTerminalProcess(
    allocator: std.mem.Allocator,
    workspace_record: *WorkspaceRecord,
    tracked_index: usize,
    finish: TerminalProcessFinish,
    finished_at_ms: i64,
) !void {
    const cancellation_reason = if (finish.cancellation_reason) |value| try allocator.dupe(u8, value) else null;
    errdefer if (cancellation_reason) |value| allocator.free(value);
    try workspace_record.terminal_process_outcomes.ensureUnusedCapacity(allocator, 1);
    _ = pruneOutcomeList(&workspace_record.terminal_process_outcomes, allocator, finished_at_ms);
    while (workspace_record.terminal_process_outcomes.items.len >= TERMINAL_PROCESS_OUTCOME_MAX) {
        var removed = workspace_record.terminal_process_outcomes.orderedRemove(0);
        removed.deinit(allocator);
    }

    const tracked = workspace_record.tracked_terminal_processes.orderedRemove(tracked_index);
    workspace_record.terminal_process_outcomes.appendAssumeCapacity(.{
        .workspace_id = tracked.workspace_id,
        .process_id = tracked.process_id,
        .generation = tracked.generation,
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
        .status = processOutcomeStatus(finish),
        .exit_code = finish.exit_code,
        .signal = finish.signal,
        .cancellation_reason = cancellation_reason,
    });
}

fn normalizeResources(allocator: std.mem.Allocator, resources: []const []const u8) !std.ArrayList([]u8) {
    var normalized: std.ArrayList([]u8) = .empty;
    errdefer deinitOwnedStringList(allocator, &normalized);
    for (resources) |resource| {
        if (resource.len == 0) continue;
        var duplicate = false;
        for (normalized.items) |existing| {
            if (std.mem.eql(u8, existing, resource)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try appendOwnedString(allocator, &normalized, resource);
    }
    return normalized;
}

fn affectedAgentAlreadyListed(affected_agents: []const AffectedAgent, owner: []const u8, client_id: []const u8) bool {
    for (affected_agents) |affected| {
        if (std.mem.eql(u8, affected.owner, owner) and std.mem.eql(u8, affected.client_id, client_id)) return true;
    }
    return false;
}

fn notificationOwnerAlreadyQueued(affected_agents: []const AffectedAgent, owner: []const u8) bool {
    for (affected_agents) |affected| {
        if (std.mem.eql(u8, affected.owner, owner)) return true;
    }
    return false;
}

fn deinitOwnedStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}

/// Compatibility helper for the desktop Project adapter. The registry owns
/// the comparison, pruning, mutation, and release rules; only the legacy
/// numeric ID spelling remains here so existing desktop snapshots stay byte-
/// identical until the daemon registry is wired in.
pub fn pruneExpiredLeaseList(lease_list: anytype, allocator: std.mem.Allocator, now_ms: i64) usize {
    var index: usize = 0;
    var removed_count: usize = 0;
    while (index < lease_list.items.len) {
        if (lease_list.items[index].expires_at_ms > now_ms) {
            index += 1;
            continue;
        }
        var expired = lease_list.orderedRemove(index);
        expired.deinit(allocator);
        removed_count += 1;
    }
    return removed_count;
}

pub const LeaseIdMode = enum {
    legacy_decimal,
    @"opaque",
};

const NoopLeaseRenewalHandler = struct {
    fn renew(_: *@This(), _: anytype, _: i64) void {}
};

const NoopLeaseConflictObserver = struct {
    fn observe(_: *@This(), _: std.mem.Allocator, _: anytype) !void {}
};

const RegistryLeaseRenewalHandler = struct {
    fn renew(_: *@This(), lease: anytype, now_ms: i64) void {
        lease.last_renewal_ms = now_ms;
    }
};

const RegistryLeaseConflictObserver = struct {
    affected_agents: *std.ArrayList(AffectedAgent),

    fn observe(self: *@This(), allocator: std.mem.Allocator, lease: anytype) !void {
        if (affectedAgentAlreadyListed(self.affected_agents.items, lease.owner, lease.client_id)) return;
        try self.affected_agents.append(allocator, .{
            .owner = lease.owner,
            .client_id = lease.client_id,
            .lease_id = lease.id,
            .command = lease.command,
        });
    }
};

fn initCompatibilityLease(
    comptime LeaseType: type,
    allocator: std.mem.Allocator,
    id: []u8,
    _: []const u8,
    _: []const u8,
    owner: []const u8,
    command: []const u8,
    resources: []const []const u8,
    ttl_ms: i64,
    now_ms: i64,
) !LeaseType {
    errdefer allocator.free(id);
    const owned_owner = try allocator.dupe(u8, owner);
    errdefer allocator.free(owned_owner);
    const owned_command = try allocator.dupe(u8, command);
    errdefer allocator.free(owned_command);
    var owned_resources: std.ArrayList([]u8) = .empty;
    errdefer deinitOwnedStringList(allocator, &owned_resources);
    for (resources) |resource| try appendOwnedString(allocator, &owned_resources, resource);
    return LeaseType{
        .id = id,
        .owner = owned_owner,
        .command = owned_command,
        .resources = owned_resources,
        .created_at_ms = now_ms,
        .expires_at_ms = now_ms + ttl_ms,
    };
}

fn initRegistryLease(
    comptime LeaseType: type,
    allocator: std.mem.Allocator,
    id: []u8,
    workspace_id: []const u8,
    client_id: []const u8,
    owner: []const u8,
    command: []const u8,
    resources: []const []const u8,
    _: i64,
    now_ms: i64,
) !LeaseType {
    return LeaseType.init(allocator, workspace_id, id, owner, client_id, command, resources, now_ms);
}

/// Acquires or renews a lease in a legacy Project list. The complete lease
/// rule implementation is shared with the opaque ProcessRegistry path below;
/// this wrapper only supplies the legacy record/ID policy.
pub fn acquireLeaseInList(
    lease_list: anytype,
    allocator: std.mem.Allocator,
    owner: []const u8,
    command: []const u8,
    resources: []const []const u8,
    ttl_ms: i64,
    force: bool,
    now_ms: i64,
    id_mode: LeaseIdMode,
    id_namespace: []const u8,
    next_id: *u64,
) !usize {
    var renewal_handler = NoopLeaseRenewalHandler{};
    var conflict_observer = NoopLeaseConflictObserver{};
    return acquireLeaseInListWithPolicy(
        lease_list,
        allocator,
        "",
        "",
        owner,
        command,
        resources,
        ttl_ms,
        force,
        now_ms,
        id_mode,
        id_namespace,
        "",
        next_id,
        initCompatibilityLease,
        &renewal_handler,
        &conflict_observer,
    );
}

fn acquireLeaseInListWithPolicy(
    lease_list: anytype,
    allocator: std.mem.Allocator,
    init_workspace_id: []const u8,
    init_client_id: []const u8,
    owner: []const u8,
    command: []const u8,
    resources: []const []const u8,
    ttl_ms: i64,
    force: bool,
    now_ms: i64,
    id_mode: LeaseIdMode,
    id_namespace: []const u8,
    instance_nonce: []const u8,
    next_id: *u64,
    comptime lease_initializer: anytype,
    renewal_handler: anytype,
    conflict_observer: anytype,
) !usize {
    if (owner.len == 0) return error.LeaseOwnerRequired;
    if (resources.len == 0) return error.LeaseResourcesRequired;
    var normalized = try normalizeResources(allocator, resources);
    defer deinitOwnedStringList(allocator, &normalized);
    if (normalized.items.len == 0) return error.LeaseResourcesRequired;
    _ = pruneExpiredLeaseList(lease_list, allocator, now_ms);

    for (lease_list.items, 0..) |*existing, index| {
        if (!std.mem.eql(u8, existing.owner, owner)) continue;
        if (!workspaceLeaseResourcesEqual(existing.resources.items, normalized.items)) continue;
        existing.expires_at_ms = now_ms + ttl_ms;
        renewal_handler.renew(existing, now_ms);
        if (!std.mem.eql(u8, existing.command, command)) {
            const replacement = try allocator.dupe(u8, command);
            allocator.free(existing.command);
            existing.command = replacement;
        }
        return index;
    }

    for (lease_list.items) |existing| {
        if (std.mem.eql(u8, existing.owner, owner)) continue;
        if (!workspaceResourcesOverlap(existing.resources.items, normalized.items)) continue;
        if (!force) return error.LeaseConflict;
        try conflict_observer.observe(allocator, existing);
    }

    const id = switch (id_mode) {
        .legacy_decimal => try std.fmt.allocPrint(allocator, "lease:{d}", .{next_id.*}),
        .@"opaque" => try std.fmt.allocPrint(allocator, "lease:{s}:{s}:{d}", .{ id_namespace, instance_nonce, next_id.* }),
    };
    if (id_mode == .legacy_decimal) next_id.* += 1;
    var lease = try lease_initializer(
        @TypeOf(lease_list.items[0]),
        allocator,
        id,
        init_workspace_id,
        init_client_id,
        owner,
        command,
        normalized.items,
        ttl_ms,
        now_ms,
    );
    errdefer lease.deinit(allocator);
    lease.expires_at_ms = now_ms + ttl_ms;
    try lease_list.append(allocator, lease);
    if (id_mode == .@"opaque") {
        next_id.* +%= 1;
        if (next_id.* == 0) next_id.* = 1;
    }
    return lease_list.items.len - 1;
}

pub fn releaseLeaseList(lease_list: anytype, allocator: std.mem.Allocator, owner: []const u8, lease_id: ?[]const u8) usize {
    var released: usize = 0;
    var index: usize = 0;
    while (index < lease_list.items.len) {
        const existing = &lease_list.items[index];
        if (!std.mem.eql(u8, existing.owner, owner) or
            (lease_id != null and !std.mem.eql(u8, existing.id, lease_id.?)))
        {
            index += 1;
            continue;
        }
        var removed = lease_list.orderedRemove(index);
        removed.deinit(allocator);
        released += 1;
        if (lease_id != null) break;
    }
    return released;
}

pub fn releaseLeasesForExactOwnerList(lease_list: anytype, allocator: std.mem.Allocator, owner: []const u8) usize {
    return releaseLeaseList(lease_list, allocator, owner, null);
}

fn pruneOutcomeList(outcomes: *std.ArrayList(TerminalProcessOutcome), allocator: std.mem.Allocator, now_ms: i64) usize {
    var index: usize = 0;
    var removed_count: usize = 0;
    while (index < outcomes.items.len) {
        const outcome = &outcomes.items[index];
        if (now_ms < outcome.finished_at_ms or now_ms - outcome.finished_at_ms <= TERMINAL_PROCESS_OUTCOME_TTL_MS) {
            index += 1;
            continue;
        }
        var removed = outcomes.orderedRemove(index);
        removed.deinit(allocator);
        removed_count += 1;
    }
    return removed_count;
}

test "workspace commands classify conservatively and infer resources" {
    try std.testing.expectEqual(CommandClass.build, classifyWorkspaceCommand("mise run build"));
    try std.testing.expectEqual(CommandClass.@"test", classifyWorkspaceCommand("bun test packages/desktop"));
    try std.testing.expectEqual(CommandClass.formatter, classifyWorkspaceCommand("zig fmt src/main.zig"));
    try std.testing.expectEqual(CommandClass.package_install, classifyWorkspaceCommand("pnpm install"));
    try std.testing.expectEqual(CommandClass.migration, classifyWorkspaceCommand("rails db:migrate"));
    try std.testing.expectEqual(CommandClass.dev_server, classifyWorkspaceCommand("npm run dev"));
    try std.testing.expectEqual(CommandClass.other, classifyWorkspaceCommand("rg TODO src"));
    try std.testing.expectEqual(CommandClass.other, classifyWorkspaceCommand("cat build/log.txt"));
    try std.testing.expectEqualStrings("build", inferredWorkspaceResource("cargo test").?);
    try std.testing.expect(inferredWorkspaceResource("rg TODO src") == null);
}

test "workspace resource overlap is exact" {
    const left = [_][]const u8{ "build", "port:3000" };
    const same = [_][]const u8{"build"};
    const different = [_][]const u8{"database"};
    try std.testing.expect(workspaceResourcesOverlap(left[0..], same[0..]));
    try std.testing.expect(!workspaceResourcesOverlap(left[0..], different[0..]));
}

test "registry lease acquire renew conflict force release and expiry rules" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "daemon-a");
    defer registry.deinit(allocator);

    try std.testing.expectError(error.LeaseOwnerRequired, registry.acquireLease(allocator, "workspace-a", "", "client-a", "build", &[_][]const u8{"build"}, false, 0));
    try std.testing.expectError(error.LeaseResourcesRequired, registry.acquireLease(allocator, "workspace-a", "agent-a", "client-a", "build", &[_][]const u8{}, false, 0));

    const build = [_][]const u8{ "build", "build" };
    var first_result = try registry.acquireLease(allocator, "workspace-a", "agent-a", "client-a", "mise run build", &build, false, 1_000);
    defer first_result.deinit(allocator);
    const first_id = try allocator.dupe(u8, first_result.lease.id);
    defer allocator.free(first_id);
    try std.testing.expectEqualStrings("workspace-a", first_result.lease.workspace_id);
    try std.testing.expectEqual(@as(usize, 1), first_result.lease.resources.items.len);
    try std.testing.expectEqual(WORKSPACE_LEASE_TTL_MS, first_result.lease.expires_at_ms - 1_000);

    var conflict_list: std.ArrayList(LeaseConflictInfo) = .empty;
    defer conflict_list.deinit(allocator);
    try registry.checkLeaseConflicts(allocator, "workspace-a", "agent-b", &[_][]const u8{"build"}, 1_001, &conflict_list);
    try std.testing.expectEqual(@as(usize, 1), conflict_list.items.len);
    try std.testing.expectError(error.LeaseConflict, registry.acquireLease(allocator, "workspace-a", "agent-b", "client-b", "cargo test", &[_][]const u8{"build"}, false, 1_001));

    var forced = try registry.acquireLease(allocator, "workspace-a", "agent-b", "client-b", "cargo test", &[_][]const u8{"build"}, true, 1_001);
    defer forced.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), forced.affected_agents.items.len);
    try std.testing.expectEqualStrings("agent-a", forced.affected_agents.items[0].owner);
    try std.testing.expect(!std.mem.eql(u8, first_id, forced.lease.id));
    try std.testing.expectEqual(@as(usize, 2), registry.activeLeaseCount(allocator, "workspace-a", 1_001));

    var renewed = try registry.acquireLease(allocator, "workspace-a", "agent-a", "client-a", "cargo build", &[_][]const u8{"build"}, false, 2_000);
    defer renewed.deinit(allocator);
    try std.testing.expectEqualStrings(first_id, renewed.lease.id);
    try std.testing.expectEqualStrings("cargo build", renewed.lease.command);
    try std.testing.expectEqual(@as(usize, 0), registry.releaseLease(allocator, "workspace-a", "agent-b", renewed.lease.id, 2_001));
    try std.testing.expectEqual(@as(usize, 1), registry.releaseLease(allocator, "workspace-a", "agent-a", renewed.lease.id, 2_001));
    try std.testing.expectEqual(@as(usize, 1), registry.releaseLease(allocator, "workspace-a", "agent-b", null, 2_001));

    var expiring = try registry.acquireLease(allocator, "workspace-a", "agent-a", "client-a", "build", &[_][]const u8{"build"}, false, 3_000);
    defer expiring.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), registry.activeLeaseCount(allocator, "workspace-a", 3_000 + WORKSPACE_LEASE_TTL_MS - 1));
    try std.testing.expectEqual(@as(usize, 0), registry.activeLeaseCount(allocator, "workspace-a", 3_000 + WORKSPACE_LEASE_TTL_MS));
}

test "registry terminal replacement bumps generation and preserves outcomes" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "daemon-a");
    defer registry.deinit(allocator);

    const first = try registry.observeTerminalProcess(allocator, "workspace-a", .{
        .process_identity = 10,
        .session_id = "session-a",
        .command = "mise run build",
        .cwd = "/tmp",
        .started_at_ms = 1,
        .observed_at_ms = 2,
        .dock_id = 1,
        .owner_kind = "terminal",
        .owner_title = "build",
    }, .{});
    try std.testing.expectEqual(@as(u64, 1), first.generation);
    const same = try registry.observeTerminalProcess(allocator, "workspace-a", .{
        .process_identity = 10,
        .session_id = "session-a",
        .command = "mise run build",
        .cwd = "/tmp",
        .started_at_ms = 1,
        .observed_at_ms = 3,
        .dock_id = 1,
        .owner_kind = "terminal",
        .owner_title = "build",
    }, .{});
    try std.testing.expectEqual(first.generation, same.generation);

    const replacement = try registry.observeTerminalProcess(allocator, "workspace-a", .{
        .process_identity = 11,
        .session_id = "session-a",
        .command = "mise run build",
        .cwd = "/tmp",
        .started_at_ms = 4,
        .observed_at_ms = 5,
        .dock_id = 1,
        .owner_kind = "terminal",
        .owner_title = "build",
    }, .{ .exit_code = 17 });
    try std.testing.expectEqual(@as(u64, 2), replacement.generation);
    try std.testing.expectEqual(@as(usize, 1), registry.workspace("workspace-a").?.terminal_process_outcomes.items.len);
    try std.testing.expectEqual(TerminalProcessOutcomeStatus.failed, registry.workspace("workspace-a").?.terminal_process_outcomes.items[0].status);
}

test "registry outcome retention is bounded and time-pruned" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "daemon-a");
    defer registry.deinit(allocator);

    for (0..TERMINAL_PROCESS_OUTCOME_MAX + 1) |index| {
        var session_id_buf: [32]u8 = undefined;
        const session_id = try std.fmt.bufPrint(&session_id_buf, "session-{d}", .{index});
        _ = try registry.observeTerminalProcess(allocator, "workspace-a", .{
            .process_identity = @intCast(index + 1),
            .session_id = session_id,
            .command = "build",
            .cwd = "/tmp",
            .started_at_ms = 1,
            .observed_at_ms = @intCast(index + 1),
            .dock_id = 1,
            .owner_kind = "terminal",
            .owner_title = "build",
        }, .{});
        try std.testing.expect(try registry.finishTerminalProcess(allocator, "workspace-a", session_id, .{ .exit_code = 0 }, @intCast(index + 1)));
    }
    try std.testing.expectEqual(TERMINAL_PROCESS_OUTCOME_MAX, registry.workspace("workspace-a").?.terminal_process_outcomes.items.len);
    try std.testing.expectEqualStrings("session-1", registry.workspace("workspace-a").?.terminal_process_outcomes.items[0].session_id);
    const first_finished = registry.workspace("workspace-a").?.terminal_process_outcomes.items[0].finished_at_ms;
    try std.testing.expectEqual(@as(usize, 0), registry.pruneTerminalProcessOutcomes(allocator, "workspace-a", first_finished + TERMINAL_PROCESS_OUTCOME_TTL_MS));
    try std.testing.expectEqual(@as(usize, 1), registry.pruneTerminalProcessOutcomes(allocator, "workspace-a", first_finished + TERMINAL_PROCESS_OUTCOME_TTL_MS + 1));
}

test "registry owns and finishes external processes" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "daemon-a");
    defer registry.deinit(allocator);

    const rejected = try ExternalProcess.init(allocator, "workspace-a", "external-rejected", "build", "/tmp", "task", "Build", "client-a");
    try std.testing.expectError(error.WorkspaceIdRequired, registry.registerExternalProcess(allocator, "", rejected));

    const process = try ExternalProcess.init(allocator, "workspace-a", "external-1", "build", "/tmp", "task", "Build", "client-a");
    const registered = try registry.registerExternalProcess(allocator, "workspace-a", process);
    try std.testing.expectEqual(ExternalProcessStatus.running, registered.status);
    try std.testing.expectEqualStrings("client-a", registered.client_id);
    try std.testing.expect(registry.finishExternalProcess("workspace-a", "external-1", .completed, 42));
    try std.testing.expectEqual(ExternalProcessStatus.completed, registered.status);
    try std.testing.expectEqual(@as(?i64, 42), registered.finished_at_ms);
}

test "registry lease ids are opaque unique and nonce-scoped" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "nonce-a");
    defer registry.deinit(allocator);

    var first = try registry.acquireLease(allocator, "workspace-a", "agent-a", "client-a", "build", &[_][]const u8{"build"}, false, 1);
    defer first.deinit(allocator);
    const first_id = try allocator.dupe(u8, first.lease.id);
    defer allocator.free(first_id);
    try std.testing.expect(!std.mem.eql(u8, first.lease.id, "lease:1"));

    _ = registry.releaseLease(allocator, "workspace-a", "agent-a", first.lease.id, 2);
    const revision_before_replacement = registry.registry_revision;
    try std.testing.expect(revision_before_replacement > 0);
    try registry.replaceInstanceNonce(allocator, "nonce-b");
    try std.testing.expectEqual(@as(u64, 0), registry.registry_revision);
    var second = try registry.acquireLease(allocator, "workspace-a", "agent-a", "client-a", "deps", &[_][]const u8{"deps"}, false, 3);
    defer second.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, first_id, second.lease.id));
    try std.testing.expect(std.mem.indexOf(u8, second.lease.id, "nonce-b") != null);
    try std.testing.expectEqual(@as(u64, 1), registry.registry_revision);
}

test "registry clients issue opaque IDs track heartbeats and derive compatibility clients" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "nonce-a");
    defer registry.deinit(allocator);

    const persistent = try registry.registerClient(allocator, true, 100);
    try std.testing.expect(std.mem.startsWith(u8, persistent.client_id, "client:nonce-a:"));
    try std.testing.expect(persistent.persistent);
    try std.testing.expect(registry.heartbeatClient(persistent.client_id, 200));
    try std.testing.expectEqual(@as(i64, 200), persistent.last_heartbeat_ms);
    try std.testing.expect(registry.closeClient(persistent.client_id, 300));
    try std.testing.expect(!registry.heartbeatClient(persistent.client_id, 400));

    const derived = try ProcessRegistry.deriveCompatibilityClientId(allocator, "session-a");
    defer allocator.free(derived);
    const compatibility = try registry.ensureCompatibilityClient(allocator, "session-a", 500);
    try std.testing.expectEqualStrings(derived, compatibility.client_id);
    try std.testing.expect(compatibility.compatibility);
    const same_compatibility = try registry.ensureCompatibilityClient(allocator, "session-a", 600);
    try std.testing.expectEqualStrings(compatibility.client_id, same_compatibility.client_id);
    try std.testing.expectEqual(@as(i64, 600), same_compatibility.last_heartbeat_ms);
    try std.testing.expectEqual(@as(usize, 2), registry.clients.count());
}

test "forced lease acquisition appends one pull notification per affected owner" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "nonce-a");
    defer registry.deinit(allocator);

    var first = try registry.acquireLease(allocator, "workspace-a", "owner-a", "client-a", "build", &[_][]const u8{"build"}, false, 1_000);
    defer first.deinit(allocator);
    var forced = try registry.acquireLease(allocator, "workspace-a", "owner-b", "client-b", "cargo test", &[_][]const u8{"build"}, true, 1_001);
    defer forced.deinit(allocator);

    const mailbox = &registry.workspace("workspace-a").?.notifications;
    try std.testing.expectEqual(@as(usize, 1), mailbox.entries.items.len);
    try std.testing.expectEqual(@as(u64, 1), mailbox.entries.items[0].seq);
    try std.testing.expectEqualStrings("owner-a", mailbox.entries.items[0].owner_session_id.?);
    try std.testing.expectEqualStrings(NOTIFICATION_TITLE_CONFLICTING_COMMAND, mailbox.entries.items[0].title);
    try std.testing.expectEqualStrings("cargo test", mailbox.entries.items[0].body);
    try std.testing.expectEqualStrings(NOTIFICATION_TYPE_COORDINATION_CONFLICT, mailbox.entries.items[0].type);
    try std.testing.expectEqual(@as(usize, 2), registry.activeLeaseCount(allocator, "workspace-a", 1_001));

    var pulled: std.ArrayList(*const Notification) = .empty;
    defer pulled.deinit(allocator);
    const next_seq = try registry.collectNotifications(allocator, "workspace-a", "owner-a", 0, 10, &pulled);
    try std.testing.expectEqual(@as(usize, 1), pulled.items.len);
    try std.testing.expectEqual(@as(u64, 2), next_seq);
    try std.testing.expectEqualStrings("cargo test", pulled.items[0].command);
}

test "notification mailboxes enforce per-session and global bounds with monotonic cursors" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "nonce-a");
    defer registry.deinit(allocator);
    registry.notification_global_cap = 3;
    const workspace = try registry.ensureWorkspace(allocator, "workspace-a");
    workspace.notifications.max_entries = 8;
    workspace.notifications.max_entries_per_session = 2;

    try registry.queueNotification(allocator, "workspace-a", "owner-a", "one", 0);
    try registry.queueNotification(allocator, "workspace-a", "owner-a", "two", 1);
    try registry.queueNotification(allocator, "workspace-a", "owner-a", "three", 2);
    try registry.queueNotification(allocator, "workspace-a", "owner-b", "four", 3);
    try std.testing.expectEqual(@as(usize, 3), registry.notification_count);
    try std.testing.expectEqual(@as(usize, 3), workspace.notifications.entries.items.len);
    try std.testing.expectEqual(@as(u64, 5), workspace.notifications.next_seq);
    try std.testing.expectEqualStrings("two", workspace.notifications.entries.items[0].body);

    var pulled: std.ArrayList(*const Notification) = .empty;
    defer pulled.deinit(allocator);
    _ = try workspace.notifications.collect(allocator, "owner-a", 0, 0, &pulled);
    try std.testing.expectEqual(@as(usize, 2), pulled.items.len);
    try std.testing.expectEqualStrings("two", pulled.items[0].body);
}

test "registry revision bump is scoped to the active instance nonce" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "nonce-a");
    defer registry.deinit(allocator);

    try std.testing.expectError(error.InstanceNonceMismatch, registry.bumpRegistryRevision("nonce-b"));
    try std.testing.expectEqual(@as(u64, 0), registry.registry_revision);
    try std.testing.expectEqual(@as(u64, 1), try registry.bumpRegistryRevision("nonce-a"));
    try std.testing.expectEqual(@as(?u64, 1), registry.revisionForInstance("nonce-a"));
    try std.testing.expect(registry.revisionForInstance("nonce-b") == null);
    try registry.replaceInstanceNonce(allocator, "nonce-b");
    try std.testing.expectEqual(@as(u64, 0), registry.registry_revision);
    try std.testing.expectEqual(@as(?u64, 0), registry.revisionForInstance("nonce-b"));
}

test "managed process runtime transitions preserve restart and explicit-stop state" {
    var runtime: ManagedProcessRuntime = .{};
    try std.testing.expectError(error.InvalidManagedProcessTransition, runtime.transition(.started, 1));
    try runtime.transition(.start, 10);
    try std.testing.expectEqual(ManagedProcessRuntimeState.starting, runtime.state);
    try std.testing.expectEqual(@as(u64, 1), runtime.generation);
    try runtime.transition(.started, 11);
    try std.testing.expectEqual(ManagedProcessRuntimeState.running, runtime.state);
    try runtime.transition(.restart, 20);
    try std.testing.expectEqual(ManagedProcessRuntimeState.starting, runtime.state);
    try std.testing.expectEqual(@as(u32, 1), runtime.restart_count);
    try std.testing.expectEqual(@as(u64, 2), runtime.generation);
    try runtime.transition(.started, 21);
    try runtime.transition(.stop, 30);
    try std.testing.expectEqual(ManagedProcessRuntimeState.stopped, runtime.state);
    try std.testing.expect(runtime.explicit_stop);
    try runtime.transition(.restart, 40);
    try std.testing.expectEqual(ManagedProcessRuntimeState.starting, runtime.state);
    try std.testing.expect(!runtime.explicit_stop);
    try runtime.transition(.failed, 41);
    try std.testing.expectEqual(ManagedProcessRuntimeState.failed, runtime.state);
}

test "workspace path aliases reject collisions and expire by fake clock" {
    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "nonce-a");
    defer registry.deinit(allocator);

    _ = try registry.registerWorkspacePath(allocator, "workspace-a", "/work/current", 0);
    _ = try registry.registerWorkspacePath(allocator, "workspace-a", "/work/old", 0);
    try std.testing.expectEqualStrings("workspace-a", registry.workspaceByPath(allocator, "/work/old", WORKSPACE_PATH_ALIAS_TTL_MS).?.id);
    try std.testing.expectError(error.WorkspacePathMapsToDifferentId, registry.registerWorkspacePath(allocator, "workspace-b", "/work/old", 1));
    try std.testing.expect(registry.workspace("workspace-b") == null);
    try std.testing.expect(registry.workspaceByPath(allocator, "/work/old", 2 * WORKSPACE_PATH_ALIAS_TTL_MS + 1) == null);

    var alias_buffer: [32]u8 = undefined;
    for (0..WORKSPACE_PATH_ALIAS_MAX + 1) |index| {
        const alias = try std.fmt.bufPrint(&alias_buffer, "/work/alias-{d}", .{index});
        _ = try registry.registerWorkspacePath(allocator, "workspace-a", alias, 100 + @as(i64, @intCast(index)));
    }
    try std.testing.expect(registry.workspaceByPath(allocator, "/work/alias-0", 200) == null);
    try std.testing.expect(registry.workspaceByPath(allocator, "/work/alias-1", 200) != null);
}

test "retention helpers pin grace boundaries and turn cap" {
    try std.testing.expect(!orphanGraceExpired(0, ORPHAN_GRACE_MS));
    try std.testing.expect(orphanGraceExpired(0, ORPHAN_GRACE_MS + 1));
    try std.testing.expect(!disconnectedRetentionExpired(0, DISCONNECTED_RETENTION_MS + 1, true));
    try std.testing.expect(!disconnectedRetentionExpired(0, DISCONNECTED_RETENTION_MS, false));
    try std.testing.expect(disconnectedRetentionExpired(0, DISCONNECTED_RETENTION_MS + 1, false));
    try std.testing.expect(!turnAbandonmentExpired(0, TURN_ABANDONMENT_GRACE_MS, .running));
    try std.testing.expect(turnAbandonmentExpired(0, TURN_ABANDONMENT_GRACE_MS + 1, .running));
    try std.testing.expect(!turnAbandonmentExpired(0, TURN_RETENTION_TTL_MS, .completed));
    try std.testing.expect(turnAbandonmentExpired(0, TURN_RETENTION_TTL_MS + 1, .completed));
    try std.testing.expect(!staleAttachExpired(0, STALE_ATTACH_TIMEOUT_MS));
    try std.testing.expect(staleAttachExpired(0, STALE_ATTACH_TIMEOUT_MS + 1));

    const allocator = std.testing.allocator;
    var registry = try ProcessRegistry.init(allocator, "nonce-a");
    defer registry.deinit(allocator);
    var id_buffer: [32]u8 = undefined;
    for (0..TURN_RETENTION_MAX + 1) |index| {
        const turn_id = try std.fmt.bufPrint(&id_buffer, "turn-{d}", .{index});
        try registry.retainTurn(allocator, "workspace-a", turn_id, .completed, @intCast(index));
    }
    const turns = &registry.workspace("workspace-a").?.retained_turns;
    try std.testing.expectEqual(TURN_RETENTION_MAX, turns.items.len);
    try std.testing.expectEqualStrings("turn-1", turns.items[0].id);
    try std.testing.expectEqual(@as(usize, 0), registry.reapRetainedTurns(allocator, TURN_RETENTION_TTL_MS));
    try std.testing.expectEqual(@as(usize, TURN_RETENTION_MAX - 1), registry.reapRetainedTurns(allocator, TURN_RETENTION_TTL_MS + 32));
    try std.testing.expectEqual(@as(usize, 1), registry.reapRetainedTurns(allocator, TURN_RETENTION_TTL_MS + 33));
}

test "registry job queue is an owned bounded FIFO" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.JobQueueCapacityRequired, RegistryJobQueue.init(0));
    var queue = try RegistryJobQueue.init(2);
    defer queue.deinit(allocator);

    const first = try RegistryJob.init(allocator, .load_config, "workspace-a", "", "client-a");
    try queue.push(allocator, first);
    try queue.push(allocator, .{ .kind = .start_managed_process });
    try std.testing.expect(queue.isFull());
    try std.testing.expectError(error.JobQueueFull, queue.push(allocator, .{ .kind = .stop_managed_process }));
    try std.testing.expectEqual(RegistryJobKind.load_config, queue.peek().?.kind);
    var popped = queue.take().?;
    defer popped.deinit(allocator);
    try std.testing.expectEqualStrings("workspace-a", popped.workspace_id);
    try std.testing.expectEqual(RegistryJobKind.start_managed_process, queue.peek().?.kind);
    var second = queue.take().?;
    second.deinit(allocator);
    try std.testing.expect(queue.take() == null);
}
