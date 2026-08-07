//! Pure daemon-side process, outcome, and lease registry.

const std = @import("std");

pub const TERMINAL_PROCESS_OUTCOME_MAX: usize = 32;
pub const TERMINAL_PROCESS_OUTCOME_TTL_MS: i64 = 15 * std.time.ms_per_min;
pub const TERMINAL_PROCESS_EXIT_GRACE_MS: i64 = 250;
pub const WORKSPACE_LEASE_TTL_MS: i64 = 120 * std.time.ms_per_s;

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
    managed_processes: std.ArrayList(ManagedProcess) = .empty,
    tracked_terminal_processes: std.ArrayList(TrackedTerminalProcess) = .empty,
    external_processes: std.ArrayList(ExternalProcess) = .empty,
    terminal_process_outcomes: std.ArrayList(TerminalProcessOutcome) = .empty,
    leases: std.ArrayList(LeaseRecord) = .empty,
    next_terminal_generation: u64 = 1,

    fn init(allocator: std.mem.Allocator, id: []const u8) !WorkspaceRecord {
        return .{ .id = try allocator.dupe(u8, id) };
    }

    fn deinit(self: *WorkspaceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
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

    pub fn init(allocator: std.mem.Allocator, instance_nonce: []const u8) !ProcessRegistry {
        if (instance_nonce.len == 0) return error.InstanceNonceRequired;
        return .{ .instance_nonce = try allocator.dupe(u8, instance_nonce) };
    }

    pub fn deinit(self: *ProcessRegistry, allocator: std.mem.Allocator) void {
        allocator.free(self.instance_nonce);
        for (self.workspaces.items) |*workspace_record| workspace_record.deinit(allocator);
        self.workspaces.deinit(allocator);
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

    /// Returns a borrowed workspace record. The pointer is invalidated by a
    /// later registry mutation, so phase-2 callers must copy data while holding
    /// the registry lock/queue.
    pub fn ensureWorkspace(self: *ProcessRegistry, allocator: std.mem.Allocator, workspace_id: []const u8) !*WorkspaceRecord {
        if (workspace_id.len == 0) return error.WorkspaceIdRequired;
        if (self.workspace(workspace_id)) |workspace_record| return workspace_record;
        var workspace_record = try WorkspaceRecord.init(allocator, workspace_id);
        errdefer workspace_record.deinit(allocator);
        try self.workspaces.append(allocator, workspace_record);
        self.bumpRevision();
        return &self.workspaces.items[self.workspaces.items.len - 1];
    }

    /// Replaces the daemon namespace after a restart. Existing records remain
    /// available for graceful handoff, while future IDs use the new nonce.
    pub fn replaceInstanceNonce(self: *ProcessRegistry, allocator: std.mem.Allocator, instance_nonce: []const u8) !void {
        if (instance_nonce.len == 0) return error.InstanceNonceRequired;
        const replacement = try allocator.dupe(u8, instance_nonce);
        allocator.free(self.instance_nonce);
        self.instance_nonce = replacement;
        self.next_lease_counter = 1;
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

    fn bumpRevision(self: *ProcessRegistry) void {
        self.registry_revision +%= 1;
    }
};

pub const ManagedProcessRecord = ManagedProcess;
pub const TrackedTerminalProcessRecord = TrackedTerminalProcess;
pub const ExternalProcessRecord = ExternalProcess;
pub const Outcome = TerminalProcessOutcome;
pub const Lease = LeaseRecord;

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
