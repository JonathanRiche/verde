//! Wire DTOs for the daemon process and workspace-lease registry.
//!
//! The registry is volatile daemon state.  In particular, registry_revision
//! is meaningful only together with instance_nonce; a changed nonce resets a
//! client's projection instead of comparing revisions across instances.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const ERR_INVALID_PARAMS = protocol.ERR_INVALID_PARAMS;
pub const ERR_CONFLICT = protocol.ERR_CONFLICT;
pub const ERR_CAPABILITY_UNAVAILABLE = protocol.ERR_CAPABILITY_UNAVAILABLE;
pub const ERR_RESOURCE_NOT_FOUND = protocol.ERR_RESOURCE_NOT_FOUND;
pub const ERR_INVALID_STATE = protocol.ERR_INVALID_STATE;
pub const ERR_INTERNAL = protocol.ERR_INTERNAL;

pub const METHOD_WORKSPACE_RESOLVE: []const u8 = "workspace.resolve";
pub const METHOD_PROCESS_LIST: []const u8 = "process.list";
pub const METHOD_PROCESS_INSPECT: []const u8 = "process.inspect";
pub const METHOD_PROCESS_START: []const u8 = "process.start";
pub const METHOD_PROCESS_STOP: []const u8 = "process.stop";
pub const METHOD_PROCESS_RESTART: []const u8 = "process.restart";
pub const METHOD_PROCESS_LOGS: []const u8 = "process.logs";
pub const METHOD_PROCESS_WAIT: []const u8 = "process.wait";
pub const METHOD_LEASE_CHECK: []const u8 = "lease.check";
pub const METHOD_LEASE_ACQUIRE: []const u8 = "lease.acquire";
pub const METHOD_LEASE_RENEW: []const u8 = "lease.renew";
pub const METHOD_LEASE_RELEASE: []const u8 = "lease.release";
pub const METHOD_DAEMON_NOTIFICATIONS: []const u8 = "daemon.notifications";
pub const METHOD_DAEMON_CLIENT_REGISTER: []const u8 = "daemon.client.register";
pub const METHOD_DAEMON_CLIENT_HEARTBEAT: []const u8 = "daemon.client.heartbeat";
pub const METHOD_DAEMON_CLIENT_CLOSE: []const u8 = "daemon.client.close";
pub const METHOD_DAEMON_STOP: []const u8 = "daemon.stop";

// Compatibility aliases accepted during the desktop rollout.
pub const METHOD_WORKSPACE_PROCESSES_ALIAS: []const u8 = "workspace.processes";
pub const METHOD_WORKSPACE_CHECK_COMMAND_ALIAS: []const u8 = "workspace.checkCommand";
pub const METHOD_WORKSPACE_ACQUIRE_LEASE_ALIAS: []const u8 = "workspace.acquireLease";
pub const METHOD_WORKSPACE_RELEASE_LEASE_ALIAS: []const u8 = "workspace.releaseLease";

// Short aliases make the method table convenient for callers that do not use
// the METHOD_ prefix, while keeping one literal spelling for each method.
pub const WORKSPACE_RESOLVE_METHOD = METHOD_WORKSPACE_RESOLVE;
pub const PROCESS_LIST_METHOD = METHOD_PROCESS_LIST;
pub const PROCESS_INSPECT_METHOD = METHOD_PROCESS_INSPECT;
pub const PROCESS_START_METHOD = METHOD_PROCESS_START;
pub const PROCESS_STOP_METHOD = METHOD_PROCESS_STOP;
pub const PROCESS_RESTART_METHOD = METHOD_PROCESS_RESTART;
pub const PROCESS_LOGS_METHOD = METHOD_PROCESS_LOGS;
pub const PROCESS_WAIT_METHOD = METHOD_PROCESS_WAIT;
pub const LEASE_CHECK_METHOD = METHOD_LEASE_CHECK;
pub const LEASE_ACQUIRE_METHOD = METHOD_LEASE_ACQUIRE;
pub const LEASE_RENEW_METHOD = METHOD_LEASE_RENEW;
pub const LEASE_RELEASE_METHOD = METHOD_LEASE_RELEASE;
pub const DAEMON_NOTIFICATIONS_METHOD = METHOD_DAEMON_NOTIFICATIONS;
pub const DAEMON_CLIENT_REGISTER_METHOD = METHOD_DAEMON_CLIENT_REGISTER;
pub const DAEMON_CLIENT_HEARTBEAT_METHOD = METHOD_DAEMON_CLIENT_HEARTBEAT;
pub const DAEMON_CLIENT_CLOSE_METHOD = METHOD_DAEMON_CLIENT_CLOSE;
pub const DAEMON_STOP_METHOD = METHOD_DAEMON_STOP;

pub const CommandClassification = enum {
    other,
    build,
    @"test",
    formatter,
    package_install,
    migration,
    dev_server,
};
pub const CommandClass = CommandClassification;

pub const ProcessSource = enum {
    managed,
    terminal,
    external,
    gui_agent,
    background_task,
};

pub const ProcessKind = enum {
    managed,
    tracked_terminal,
    external,
    outcome,
};

/// The merged status used by the flattened process projection.
pub const ProcessStatus = enum {
    stopped,
    starting,
    running,
    stopping,
    crashed,
    restarting,
    completed,
    failed,
    cancelled,
    unknown,
};

/// Runtime states for configured managed processes.
pub const ManagedProcessStatus = enum {
    stopped,
    starting,
    running,
    stopping,
    crashed,
    restarting,
};

/// Runtime and terminal states for daemon-owned external work.
pub const ExternalProcessStatus = enum {
    running,
    completed,
    failed,
    cancelled,
    crashed,
    unknown,
};

/// Terminal classification for retained process outcomes.
pub const TerminalProcessOutcomeStatus = enum {
    completed,
    failed,
    crashed,
    cancelled,
    unknown,
};

pub const NotificationType = enum {
    coordination_conflict,

    pub fn wireName(self: @This()) []const u8 {
        return switch (self) {
            .coordination_conflict => "coordination.conflict",
        };
    }
};

pub const NOTIFICATION_TYPE_COORDINATION_CONFLICT: []const u8 = "coordination.conflict";
pub const NOTIFICATION_TITLE_CONFLICTING_COMMAND: []const u8 = "Conflicting command started";
pub const NOTIFICATION_OPTION_WAIT: []const u8 = "wait";
pub const NOTIFICATION_OPTION_CANCEL_EXISTING: []const u8 = "cancel_existing";
pub const NOTIFICATION_OPTION_RUN_ANYWAY: []const u8 = "run_anyway";
pub const NOTIFICATION_OPTION_OPEN_OWNER: []const u8 = "open_owner";

/// The volatile revision namespace used by every registry snapshot.
pub const RegistryRevisionEnvelope = struct {
    instance_nonce: []const u8 = "",
    registry_revision: u64 = 0,

    /// Revisions can only be compared within one daemon instance.
    pub fn sameInstance(self: @This(), other: @This()) bool {
        return std.mem.eql(u8, self.instance_nonce, other.instance_nonce);
    }

    /// A nonce change invalidates the cached projection, regardless of the
    /// numeric revisions reported by either daemon instance.
    pub fn shouldResetProjection(self: @This(), next: @This()) bool {
        return !self.sameInstance(next);
    }
};
pub const RegistryEnvelope = RegistryRevisionEnvelope;

pub const WorkspaceRef = struct {
    workspace_id: ?[]const u8 = null,
    workspace_path: ?[]const u8 = null,
};

pub const WorkspaceInfo = struct {
    id: []const u8 = "",
    path: []const u8 = "",
    label: ?[]const u8 = null,
    instance_nonce: []const u8 = "",
    registry_revision: u64 = 0,
};

pub const ManagedProcessRecord = struct {
    workspace_id: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    command: []const u8 = "",
    argv: []const []const u8 = &.{},
    cwd: []const u8 = "",
    resources: []const []const u8 = &.{},
    watch: []const []const u8 = &.{},
    status: ManagedProcessStatus = .stopped,
    pid: ?u32 = null,
    process_group: ?u32 = null,
    generation: u64 = 0,
    created_at_ms: i64 = 0,
    last_start_ms: ?i64 = null,
    last_exit_ms: ?i64 = null,
    restart_count: u32 = 0,
    explicit_stop: bool = false,
};
pub const ManagedProcess = ManagedProcessRecord;

pub const TrackedTerminalProcessRecord = struct {
    workspace_id: []const u8 = "",
    process_id: []const u8 = "",
    generation: u64 = 0,
    process_identity: u32 = 0,
    session_id: []const u8 = "",
    command: []const u8 = "",
    cwd: []const u8 = "",
    pid: ?u32 = null,
    process_group: ?u32 = null,
    started_at_ms: ?i64 = null,
    dock_id: ?u32 = null,
    pane_id: ?u32 = null,
    owner_kind: []const u8 = "",
    owner_title: []const u8 = "",
    provider: ?[]const u8 = null,
    missing_since_ms: ?i64 = null,
};
pub const TrackedTerminalProcess = TrackedTerminalProcessRecord;

pub const ExternalProcessRecord = struct {
    workspace_id: []const u8 = "",
    process_id: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    command: []const u8 = "",
    cwd: []const u8 = "",
    owner: ?[]const u8 = null,
    owner_session_id: ?[]const u8 = null,
    owner_kind: []const u8 = "",
    owner_title: []const u8 = "",
    client_id: []const u8 = "",
    provider_process_id: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    archived_thread: bool = false,
    resources: []const []const u8 = &.{},
    classification: CommandClassification = .other,
    pid: ?u32 = null,
    process_group: ?u32 = null,
    generation: u64 = 0,
    created_at_ms: i64 = 0,
    started_at_ms: ?i64 = null,
    updated_at_ms: ?i64 = null,
    finished_at_ms: ?i64 = null,
    status: ExternalProcessStatus = .running,
    attention: bool = false,
};
pub const ExternalProcess = ExternalProcessRecord;

pub const TerminalProcessOutcome = struct {
    workspace_id: []const u8 = "",
    process_id: []const u8 = "",
    id: []const u8 = "",
    generation: u64 = 0,
    session_id: []const u8 = "",
    command: []const u8 = "",
    cwd: []const u8 = "",
    classification: CommandClassification = .other,
    pid: ?u32 = null,
    process_group: ?u32 = null,
    started_at_ms: ?i64 = null,
    finished_at_ms: ?i64 = null,
    dock_id: ?u32 = null,
    pane_id: ?u32 = null,
    owner_kind: []const u8 = "",
    owner_title: []const u8 = "",
    provider: ?[]const u8 = null,
    status: TerminalProcessOutcomeStatus = .unknown,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
    cancellation_reason: ?[]const u8 = null,
};
pub const ProcessOutcome = TerminalProcessOutcome;
pub const OutcomeRecord = TerminalProcessOutcome;

/// The flattened process projection used by `process.list` and `process.inspect`.
pub const ProcessSnapshot = struct {
    id: []const u8 = "",
    workspace_id: []const u8 = "",
    workspace_path: []const u8 = "",
    source: ProcessSource = .managed,
    kind: ProcessKind = .managed,
    name: []const u8 = "",
    owner: ?[]const u8 = null,
    owner_session_id: ?[]const u8 = null,
    command: []const u8 = "",
    cwd: []const u8 = "",
    status: ProcessStatus = .unknown,
    classification: CommandClassification = .other,
    resources: []const []const u8 = &.{},
    pid: ?u32 = null,
    process_group: ?u32 = null,
    dock_id: ?u32 = null,
    pane_id: ?u32 = null,
    created_at_ms: i64 = 0,
    started_at_ms: ?i64 = null,
    finished_at_ms: ?i64 = null,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
    cancellation_reason: ?[]const u8 = null,
    runtime_status: ?ManagedProcessStatus = null,
    restart_count: u32 = 0,
    attention: bool = false,
};

pub const LeaseRecord = struct {
    workspace_id: []const u8 = "",
    id: []const u8 = "",
    owner: []const u8 = "",
    client_id: []const u8 = "",
    command: []const u8 = "",
    resources: []const []const u8 = &.{},
    created_at_ms: i64 = 0,
    expires_at_ms: i64 = 0,
    last_renewal_ms: i64 = 0,
};
pub const Lease = LeaseRecord;

/// A lease or process that prevents a requested resource claim.
pub const LeaseConflict = struct {
    kind: []const u8 = "",
    source: []const u8 = "",
    resource: []const u8 = "",
    id: []const u8 = "",
    owner: []const u8 = "",
    owner_kind: []const u8 = "",
    command: []const u8 = "",
    status: []const u8 = "",
    cancel_method: []const u8 = "",
    session_id: ?[]const u8 = null,
    pane_id: ?u32 = null,
    thread_id: ?[]const u8 = null,
    started_at_ms: i64 = 0,
    expires_at_ms: ?i64 = null,
};
pub const LeaseConflictInfo = LeaseConflict;

pub const Notification = struct {
    seq: u64 = 0,
    type: []const u8 = NOTIFICATION_TYPE_COORDINATION_CONFLICT,
    workspace_id: []const u8 = "",
    owner_session_id: ?[]const u8 = null,
    title: []const u8 = NOTIFICATION_TITLE_CONFLICTING_COMMAND,
    body: []const u8 = "",
    command: []const u8 = "",
    created_at_ms: i64 = 0,
};
pub const LeaseForceNotification = Notification;

pub const ProcessListRequest = struct {
    workspace: WorkspaceRef = .{},
    include_outcomes: bool = false,
    include_notifications: bool = false,
    after_registry_revision: ?u64 = null,
};

pub const ProcessListResult = struct {
    workspace: WorkspaceInfo = .{},
    instance_nonce: []const u8 = "",
    registry_revision: u64 = 0,
    polled_at_ms: i64 = 0,
    processes: []const ProcessSnapshot = &.{},
    outcomes: []const TerminalProcessOutcome = &.{},
    leases: []const LeaseRecord = &.{},
    notifications: []const Notification = &.{},
    next_notification_seq: u64 = 0,
};

pub const WorkspaceResolveRequest = struct {
    workspace: WorkspaceRef = .{},
};

pub const WorkspaceResolveResult = struct {
    workspace: WorkspaceInfo = .{},
};

pub const ProcessInspectRequest = struct {
    workspace: WorkspaceRef = .{},
    process_id: []const u8 = "",
};

pub const ProcessInspectResult = struct {
    workspace: WorkspaceInfo = .{},
    registry_revision: u64 = 0,
    process: ?ProcessSnapshot = null,
    outcome: ?TerminalProcessOutcome = null,
};

pub const ProcessStartRequest = struct {
    workspace: WorkspaceRef = .{},
    client_id: ?[]const u8 = null,
    name: []const u8 = "",
    process_id: ?[]const u8 = null,
};

pub const ProcessStartResult = struct {
    workspace: WorkspaceInfo = .{},
    registry_revision: u64 = 0,
    started: bool = false,
    process: ?ProcessSnapshot = null,
};

pub const ProcessStopRequest = struct {
    workspace: WorkspaceRef = .{},
    client_id: ?[]const u8 = null,
    process_id: []const u8 = "",
    force: bool = false,
};

pub const ProcessStopResult = struct {
    workspace: WorkspaceInfo = .{},
    registry_revision: u64 = 0,
    stopped: bool = false,
    process: ?ProcessSnapshot = null,
};

pub const ProcessRestartRequest = struct {
    workspace: WorkspaceRef = .{},
    client_id: ?[]const u8 = null,
    name: []const u8 = "",
    process_id: ?[]const u8 = null,
};

pub const ProcessRestartResult = struct {
    workspace: WorkspaceInfo = .{},
    registry_revision: u64 = 0,
    restarted: bool = false,
    process: ?ProcessSnapshot = null,
};

pub const ProcessLogsRequest = struct {
    workspace: WorkspaceRef = .{},
    process_id: []const u8 = "",
    after_cursor: ?u64 = null,
    max_bytes: u32 = 0,
};

pub const ProcessLogsResult = struct {
    workspace: WorkspaceInfo = .{},
    registry_revision: u64 = 0,
    process_id: []const u8 = "",
    cursor: u64 = 0,
    complete: bool = false,
    text: []const u8 = "",
};

pub const ProcessWaitRequest = struct {
    workspace: WorkspaceRef = .{},
    process_id: []const u8 = "",
    after_registry_revision: ?u64 = null,
    timeout_ms: u32 = 0,
};

pub const ProcessWaitResult = struct {
    workspace: WorkspaceInfo = .{},
    registry_revision: u64 = 0,
    process_id: []const u8 = "",
    terminal_state: ?TerminalProcessOutcomeStatus = null,
    outcome: ?TerminalProcessOutcome = null,
    changed: bool = false,
    timed_out: bool = false,
};

pub const LeaseCheckRequest = struct {
    workspace: WorkspaceRef = .{},
    command: []const u8 = "",
    owner: []const u8 = "",
    client_id: ?[]const u8 = null,
    resources: []const []const u8 = &.{},
    explicit_resources: []const []const u8 = &.{},
};

pub const LeaseCheckResult = struct {
    workspace: WorkspaceInfo = .{},
    registry_revision: u64 = 0,
    command: []const u8 = "",
    classification: CommandClassification = .other,
    resources: []const []const u8 = &.{},
    explicit_resources: []const []const u8 = &.{},
    inferred_resources: []const []const u8 = &.{},
    conflicts: []const LeaseConflict = &.{},
    allowed: bool = true,
    conflict_count: u32 = 0,
    warning: ?[]const u8 = null,
    options: []const []const u8 = &.{
        NOTIFICATION_OPTION_WAIT,
        NOTIFICATION_OPTION_CANCEL_EXISTING,
        NOTIFICATION_OPTION_RUN_ANYWAY,
        NOTIFICATION_OPTION_OPEN_OWNER,
    },
};

pub const LeaseAcquireRequest = struct {
    workspace: WorkspaceRef = .{},
    owner: []const u8 = "",
    client_id: ?[]const u8 = null,
    command: []const u8 = "",
    resources: []const []const u8 = &.{},
    force: bool = false,
    ttl_ms: i64 = 120_000,
};

pub const LeaseAcquireResult = struct {
    workspace: WorkspaceInfo = .{},
    instance_nonce: []const u8 = "",
    registry_revision: u64 = 0,
    acquired: bool = false,
    forced: bool = false,
    renewed: bool = false,
    lease_id: ?[]const u8 = null,
    owner: []const u8 = "",
    client_id: ?[]const u8 = null,
    command: []const u8 = "",
    resources: []const []const u8 = &.{},
    created_at_ms: ?i64 = null,
    expires_at_ms: ?i64 = null,
    last_renewal_ms: ?i64 = null,
    lease: ?LeaseRecord = null,
    conflicts: []const LeaseConflict = &.{},
};

pub const LeaseRenewRequest = struct {
    workspace: WorkspaceRef = .{},
    owner: []const u8 = "",
    client_id: ?[]const u8 = null,
    lease_id: []const u8 = "",
    ttl_ms: i64 = 120_000,
};

pub const LeaseRenewResult = struct {
    workspace: WorkspaceInfo = .{},
    instance_nonce: []const u8 = "",
    registry_revision: u64 = 0,
    renewed: bool = false,
    lease_id: []const u8 = "",
    owner: []const u8 = "",
    client_id: ?[]const u8 = null,
    created_at_ms: ?i64 = null,
    expires_at_ms: ?i64 = null,
    last_renewal_ms: ?i64 = null,
    lease: ?LeaseRecord = null,
};

pub const LeaseReleaseRequest = struct {
    workspace: WorkspaceRef = .{},
    owner: []const u8 = "",
    client_id: ?[]const u8 = null,
    lease_id: ?[]const u8 = null,
};

pub const LeaseReleaseResult = struct {
    workspace: WorkspaceInfo = .{},
    registry_revision: u64 = 0,
    released: bool = false,
    released_count: u32 = 0,
    lease_id: ?[]const u8 = null,
};

pub const NotificationsRequest = struct {
    workspace: WorkspaceRef = .{},
    owner_session_id: ?[]const u8 = null,
    after_seq: u64 = 0,
    limit: u32 = 0,
};
pub const DaemonNotificationsRequest = NotificationsRequest;

pub const NotificationsResult = struct {
    workspace: WorkspaceInfo = .{},
    registry_revision: u64 = 0,
    notifications: []const Notification = &.{},
    next_notification_seq: u64 = 0,
};
pub const DaemonNotificationsResult = NotificationsResult;

pub const ClientRegisterRequest = struct {
    persistent: bool = false,
};
pub const DaemonClientRegisterRequest = ClientRegisterRequest;

pub const ClientRegisterResult = struct {
    client_id: []const u8 = "",
    persistent: bool = false,
    retention_ms: u64 = 0,
};
pub const DaemonClientRegisterResult = ClientRegisterResult;

pub const ClientHeartbeatRequest = struct {
    client_id: []const u8 = "",
};
pub const DaemonClientHeartbeatRequest = ClientHeartbeatRequest;

pub const ClientHeartbeatResult = struct {
    client_id: []const u8 = "",
    accepted: bool = false,
    last_heartbeat_ms: i64 = 0,
};
pub const DaemonClientHeartbeatResult = ClientHeartbeatResult;

pub const ClientCloseRequest = struct {
    client_id: []const u8 = "",
};
pub const DaemonClientCloseRequest = ClientCloseRequest;

pub const ClientCloseResult = struct {
    client_id: []const u8 = "",
    closed: bool = false,
    released_leases: u32 = 0,
};
pub const DaemonClientCloseResult = ClientCloseResult;

pub const DaemonStopRequest = struct {
    client_id: []const u8 = "",
    force: bool = false,
};

pub const DaemonStopResult = struct {
    accepted: bool = false,
    stopping: bool = false,
    registry_revision: u64 = 0,
};

/// Encode one typed registry value as a standalone JSON object/value.
pub fn encode(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.write(value);
    return try writer.toOwnedSlice();
}

pub const encodeJson = encode;
pub const encodeAlloc = encode;

/// Decode a typed registry value while ignoring fields introduced by newer peers.
pub fn decode(comptime T: type, allocator: std.mem.Allocator, json_bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Decode a typed registry value into an arena-owned value.
pub fn decodeLeaky(comptime T: type, allocator: std.mem.Allocator, json_bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub const decodeJson = decode;

test "registry DTOs round trip every public shape" {
    const allocator = std.testing.allocator;
    const resources = [_][]const u8{ "build", "source" };
    const workspace: WorkspaceRef = .{ .workspace_id = "workspace-1", .workspace_path = "/tmp/project" };
    const info: WorkspaceInfo = .{
        .id = "workspace-1",
        .path = "/tmp/project",
        .label = "Project",
        .instance_nonce = "daemon-a",
        .registry_revision = 7,
    };
    const process: ProcessSnapshot = .{
        .id = "term:session-1:2",
        .workspace_id = "workspace-1",
        .workspace_path = "/tmp/project",
        .source = .terminal,
        .kind = .tracked_terminal,
        .name = "cargo test",
        .owner = "agent-1",
        .owner_session_id = "session-1",
        .command = "cargo test",
        .cwd = "/tmp/project",
        .status = .running,
        .classification = .@"test",
        .resources = &resources,
        .pid = 41,
        .process_group = 42,
        .dock_id = 3,
        .pane_id = 4,
        .created_at_ms = 10,
        .started_at_ms = 11,
        .restart_count = 2,
        .attention = true,
    };
    const managed: ManagedProcessRecord = .{
        .workspace_id = "workspace-1",
        .id = "proc:workspace-1:web",
        .name = "web",
        .command = "npm run dev",
        .argv = &.{ "npm", "run", "dev" },
        .cwd = "/tmp/project",
        .resources = &resources,
        .watch = &.{ "src/**" },
        .status = .running,
        .generation = 3,
        .last_start_ms = 20,
        .restart_count = 1,
    };
    const tracked: TrackedTerminalProcessRecord = .{
        .workspace_id = "workspace-1",
        .process_id = "term:session-1:2",
        .generation = 2,
        .process_identity = 42,
        .session_id = "session-1",
        .command = "cargo test",
        .cwd = "/tmp/project",
        .pid = 41,
        .process_group = 42,
        .started_at_ms = 11,
        .dock_id = 3,
        .pane_id = 4,
        .owner_kind = "agent",
        .owner_title = "Agent",
        .provider = "codex",
    };
    const external: ExternalProcessRecord = .{
        .workspace_id = "workspace-1",
        .process_id = "task:task-1",
        .id = "task:task-1",
        .name = "background task",
        .command = "cargo test",
        .cwd = "/tmp/project",
        .owner = "thread-1",
        .owner_session_id = "session-1",
        .owner_kind = "gui_agent",
        .owner_title = "Agent",
        .client_id = "client-1",
        .resources = &resources,
        .classification = .@"test",
        .status = .running,
    };
    const outcome: TerminalProcessOutcome = .{
        .workspace_id = "workspace-1",
        .process_id = "term:session-1:1",
        .id = "term:session-1:1",
        .generation = 1,
        .session_id = "session-1",
        .command = "cargo test",
        .cwd = "/tmp/project",
        .classification = .@"test",
        .started_at_ms = 1,
        .finished_at_ms = 9,
        .status = .completed,
        .exit_code = 0,
    };
    const lease: LeaseRecord = .{
        .workspace_id = "workspace-1",
        .id = "lease:workspace-1:daemon-a:1",
        .owner = "agent-1",
        .client_id = "client-1",
        .command = "cargo test",
        .resources = &resources,
        .created_at_ms = 1,
        .expires_at_ms = 121_000,
        .last_renewal_ms = 1,
    };
    const conflict: LeaseConflict = .{
        .kind = "lease",
        .source = "lease",
        .resource = "build",
        .id = lease.id,
        .owner = "agent-1",
        .owner_kind = "agent",
        .command = lease.command,
        .status = "leased",
        .expires_at_ms = lease.expires_at_ms,
        .cancel_method = "workspace.releaseLease (owner only)",
    };
    const notification: Notification = .{
        .seq = 8,
        .workspace_id = "workspace-1",
        .owner_session_id = "session-1",
        .body = "cargo test",
        .command = "cargo test",
        .created_at_ms = 12,
    };

    const values = .{
        workspace,
        info,
        RegistryRevisionEnvelope{ .instance_nonce = "daemon-a", .registry_revision = 7 },
        managed,
        tracked,
        external,
        outcome,
        process,
        lease,
        conflict,
        notification,
        ProcessListRequest{ .workspace = workspace, .include_outcomes = true, .include_notifications = true, .after_registry_revision = 6 },
        ProcessListResult{ .workspace = info, .instance_nonce = "daemon-a", .registry_revision = 7, .polled_at_ms = 13, .processes = &.{process}, .outcomes = &.{outcome}, .leases = &.{lease}, .notifications = &.{notification}, .next_notification_seq = 9 },
        WorkspaceResolveRequest{ .workspace = workspace },
        WorkspaceResolveResult{ .workspace = info },
        ProcessInspectRequest{ .workspace = workspace, .process_id = process.id },
        ProcessInspectResult{ .workspace = info, .registry_revision = 7, .process = process },
        ProcessStartRequest{ .workspace = workspace, .client_id = "client-1", .name = "web" },
        ProcessStartResult{ .workspace = info, .registry_revision = 7, .started = true, .process = process },
        ProcessStopRequest{ .workspace = workspace, .client_id = "client-1", .process_id = process.id },
        ProcessStopResult{ .workspace = info, .registry_revision = 7, .stopped = true, .process = process },
        ProcessRestartRequest{ .workspace = workspace, .client_id = "client-1", .name = "web" },
        ProcessRestartResult{ .workspace = info, .registry_revision = 7, .restarted = true, .process = process },
        ProcessLogsRequest{ .workspace = workspace, .process_id = process.id, .after_cursor = 3, .max_bytes = 100 },
        ProcessLogsResult{ .workspace = info, .registry_revision = 7, .process_id = process.id, .cursor = 4, .complete = true, .text = "done" },
        ProcessWaitRequest{ .workspace = workspace, .process_id = process.id, .after_registry_revision = 6, .timeout_ms = 500 },
        ProcessWaitResult{ .workspace = info, .registry_revision = 7, .process_id = process.id, .terminal_state = .completed, .outcome = outcome, .changed = true },
        LeaseCheckRequest{ .workspace = workspace, .command = "cargo test", .owner = "agent-2", .client_id = "client-2", .resources = &resources, .explicit_resources = &resources },
        LeaseCheckResult{ .workspace = info, .registry_revision = 7, .command = "cargo test", .classification = .@"test", .resources = &resources, .explicit_resources = &resources, .inferred_resources = &.{ "build" }, .conflicts = &.{conflict}, .allowed = false, .conflict_count = 1 },
        LeaseAcquireRequest{ .workspace = workspace, .owner = "agent-2", .client_id = "client-2", .command = "cargo test", .resources = &resources, .force = true, .ttl_ms = 120_000 },
        LeaseAcquireResult{ .workspace = info, .instance_nonce = "daemon-a", .registry_revision = 7, .acquired = true, .forced = true, .lease_id = lease.id, .owner = "agent-2", .client_id = "client-2", .command = "cargo test", .resources = &resources, .created_at_ms = 2, .expires_at_ms = 120_002, .last_renewal_ms = 2, .lease = lease, .conflicts = &.{conflict} },
        LeaseRenewRequest{ .workspace = workspace, .owner = "agent-1", .client_id = "client-1", .lease_id = lease.id, .ttl_ms = 120_000 },
        LeaseRenewResult{ .workspace = info, .instance_nonce = "daemon-a", .registry_revision = 8, .renewed = true, .lease_id = lease.id, .owner = "agent-1", .client_id = "client-1", .created_at_ms = 1, .expires_at_ms = 121_000, .last_renewal_ms = 2, .lease = lease },
        LeaseReleaseRequest{ .workspace = workspace, .owner = "agent-1", .client_id = "client-1", .lease_id = lease.id },
        LeaseReleaseResult{ .workspace = info, .registry_revision = 9, .released = true, .released_count = 1, .lease_id = lease.id },
        NotificationsRequest{ .workspace = workspace, .owner_session_id = "session-1", .after_seq = 7, .limit = 10 },
        NotificationsResult{ .workspace = info, .registry_revision = 7, .notifications = &.{notification}, .next_notification_seq = 9 },
        ClientRegisterRequest{ .persistent = true },
        ClientRegisterResult{ .client_id = "client-1", .persistent = true, .retention_ms = 60_000 },
        ClientHeartbeatRequest{ .client_id = "client-1" },
        ClientHeartbeatResult{ .client_id = "client-1", .accepted = true, .last_heartbeat_ms = 20 },
        ClientCloseRequest{ .client_id = "client-1" },
        ClientCloseResult{ .client_id = "client-1", .closed = true, .released_leases = 1 },
        DaemonStopRequest{ .client_id = "client-1", .force = true },
        DaemonStopResult{ .accepted = true, .stopping = true, .registry_revision = 10 },
    };

    inline for (values) |value| {
        const json = try encode(allocator, value);
        defer allocator.free(json);
        var parsed = try decode(@TypeOf(value), allocator, json);
        parsed.deinit();
    }

    const list = ProcessListResult{ .workspace = info, .registry_revision = 7, .processes = &.{process}, .outcomes = &.{outcome}, .leases = &.{lease}, .notifications = &.{notification} };
    const list_json = try encode(allocator, list);
    defer allocator.free(list_json);
    var parsed_list = try decode(ProcessListResult, allocator, list_json);
    defer parsed_list.deinit();
    try std.testing.expectEqual(@as(u64, 7), parsed_list.value.registry_revision);
    try std.testing.expectEqualStrings("term:session-1:2", parsed_list.value.processes[0].id);
    try std.testing.expectEqualStrings("lease:workspace-1:daemon-a:1", parsed_list.value.leases[0].id);
    try std.testing.expectEqualStrings(NOTIFICATION_TYPE_COORDINATION_CONFLICT, parsed_list.value.notifications[0].type);
}

test "registry decoders ignore unknown fields and default absent optionals" {
    const raw =
        \\{"workspace_id":"workspace-1","workspace_path":"/tmp/project","future_field":{"enabled":true}}
    ;
    var workspace = try decode(WorkspaceRef, std.testing.allocator, raw);
    defer workspace.deinit();
    try std.testing.expectEqualStrings("workspace-1", workspace.value.workspace_id.?);
    try std.testing.expect(workspace.value.workspace_path != null);

    const minimal = "{\"id\":\"proc-1\",\"future\":42}";
    var process = try decode(ProcessSnapshot, std.testing.allocator, minimal);
    defer process.deinit();
    try std.testing.expectEqualStrings("proc-1", process.value.id);
    try std.testing.expect(process.value.owner == null);
    try std.testing.expect(process.value.pid == null);
    try std.testing.expect(!process.value.attention);
    try std.testing.expectEqual(ProcessStatus.unknown, process.value.status);
}

test "registry decodes a hand-written process list JSON literal" {
    const raw =
        \\{
        \\  "workspace":{"id":"w1","path":"/work","registry_revision":12,"instance_nonce":"n1"},
        \\  "instance_nonce":"n1",
        \\  "registry_revision":12,
        \\  "polled_at_ms":99,
        \\  "processes":[{"id":"proc:w1:web","workspace_id":"w1","source":"managed","kind":"managed","name":"web","command":"npm run dev","cwd":"/work","status":"running","classification":"dev_server","resources":[]}],
        \\  "outcomes":[],
        \\  "leases":[{"id":"lease:w1:n1:1","workspace_id":"w1","owner":"agent","client_id":"c1","command":"cargo test","resources":["build"],"created_at_ms":1,"expires_at_ms":1000,"last_renewal_ms":1}],
        \\  "notifications":[],
        \\  "next_notification_seq":1,
        \\  "new_peer_field":"ignored"
        \\}
    ;
    var parsed = try decode(ProcessListResult, std.testing.allocator, raw);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("n1", parsed.value.instance_nonce);
    try std.testing.expectEqual(@as(u64, 12), parsed.value.registry_revision);
    try std.testing.expectEqual(ProcessSource.managed, parsed.value.processes[0].source);
    try std.testing.expectEqual(ProcessStatus.running, parsed.value.processes[0].status);
    try std.testing.expectEqual(CommandClassification.dev_server, parsed.value.processes[0].classification);
    try std.testing.expectEqualStrings("agent", parsed.value.leases[0].owner);
}

test "registry decodes live and future lease conflict statuses" {
    const live =
        \\{"kind":"lease","source":"lease","resource":"build","id":"lease:w1:n1:1","owner":"agent","owner_kind":"agent","command":"cargo test","status":"leased","cancel_method":"workspace.releaseLease (owner only)","session_id":null,"pane_id":null,"thread_id":null,"started_at_ms":1,"expires_at_ms":1000}
    ;
    var parsed_live = try decode(LeaseConflict, std.testing.allocator, live);
    defer parsed_live.deinit();
    try std.testing.expectEqualStrings("lease:w1:n1:1", parsed_live.value.id);
    try std.testing.expectEqualStrings("leased", parsed_live.value.status);
    try std.testing.expectEqual(@as(?i64, 1000), parsed_live.value.expires_at_ms);

    const future =
        \\{"kind":"process","source":"configured","resource":"build","id":"proc:w1:web","owner":"proc:w1:web","owner_kind":"managed_process","command":"npm run dev","status":"paused_by_future_peer","cancel_method":"process.stop"}
    ;
    var parsed_future = try decode(LeaseConflict, std.testing.allocator, future);
    defer parsed_future.deinit();
    try std.testing.expectEqualStrings("paused_by_future_peer", parsed_future.value.status);
}

test "registry method, alias, error, enum, and notification names are pinned" {
    try std.testing.expectEqualStrings("workspace.resolve", METHOD_WORKSPACE_RESOLVE);
    try std.testing.expectEqualStrings("process.list", METHOD_PROCESS_LIST);
    try std.testing.expectEqualStrings("process.inspect", METHOD_PROCESS_INSPECT);
    try std.testing.expectEqualStrings("process.start", METHOD_PROCESS_START);
    try std.testing.expectEqualStrings("process.stop", METHOD_PROCESS_STOP);
    try std.testing.expectEqualStrings("process.restart", METHOD_PROCESS_RESTART);
    try std.testing.expectEqualStrings("process.logs", METHOD_PROCESS_LOGS);
    try std.testing.expectEqualStrings("process.wait", METHOD_PROCESS_WAIT);
    try std.testing.expectEqualStrings("lease.check", METHOD_LEASE_CHECK);
    try std.testing.expectEqualStrings("lease.acquire", METHOD_LEASE_ACQUIRE);
    try std.testing.expectEqualStrings("lease.renew", METHOD_LEASE_RENEW);
    try std.testing.expectEqualStrings("lease.release", METHOD_LEASE_RELEASE);
    try std.testing.expectEqualStrings("daemon.notifications", METHOD_DAEMON_NOTIFICATIONS);
    try std.testing.expectEqualStrings("daemon.client.register", METHOD_DAEMON_CLIENT_REGISTER);
    try std.testing.expectEqualStrings("daemon.client.heartbeat", METHOD_DAEMON_CLIENT_HEARTBEAT);
    try std.testing.expectEqualStrings("daemon.client.close", METHOD_DAEMON_CLIENT_CLOSE);
    try std.testing.expectEqualStrings("daemon.stop", METHOD_DAEMON_STOP);
    try std.testing.expectEqualStrings("workspace.processes", METHOD_WORKSPACE_PROCESSES_ALIAS);
    try std.testing.expectEqualStrings("workspace.checkCommand", METHOD_WORKSPACE_CHECK_COMMAND_ALIAS);
    try std.testing.expectEqualStrings("workspace.acquireLease", METHOD_WORKSPACE_ACQUIRE_LEASE_ALIAS);
    try std.testing.expectEqualStrings("workspace.releaseLease", METHOD_WORKSPACE_RELEASE_LEASE_ALIAS);

    try std.testing.expectEqualStrings("conflict", ERR_CONFLICT);
    try std.testing.expectEqualStrings("invalid_params", ERR_INVALID_PARAMS);
    try std.testing.expectEqualStrings("resource_not_found", ERR_RESOURCE_NOT_FOUND);
    try std.testing.expectEqualStrings("invalid_state", ERR_INVALID_STATE);
    try std.testing.expectEqualStrings("capability_unavailable", ERR_CAPABILITY_UNAVAILABLE);
    try std.testing.expectEqualStrings("internal", ERR_INTERNAL);
    try std.testing.expectEqualStrings("coordination.conflict", NotificationType.coordination_conflict.wireName());
    try std.testing.expectEqualStrings("coordination.conflict", NOTIFICATION_TYPE_COORDINATION_CONFLICT);
    try std.testing.expectEqualStrings("Conflicting command started", NOTIFICATION_TITLE_CONFLICTING_COMMAND);
    try std.testing.expectEqualStrings("build", @tagName(CommandClassification.build));
    try std.testing.expectEqualStrings("test", @tagName(CommandClassification.@"test"));
    try std.testing.expectEqualStrings("running", @tagName(ProcessStatus.running));
    try std.testing.expectEqualStrings("completed", @tagName(TerminalProcessOutcomeStatus.completed));
}

test "decoded registry revisions reset only when the instance nonce changes" {
    const old_json = "{\"instance_nonce\":\"old\",\"registry_revision\":44}";
    const replacement_json = "{\"instance_nonce\":\"new\",\"registry_revision\":0}";
    const same_instance_json = "{\"instance_nonce\":\"old\",\"registry_revision\":2}";

    var old = try decode(RegistryRevisionEnvelope, std.testing.allocator, old_json);
    defer old.deinit();
    var replacement = try decode(RegistryRevisionEnvelope, std.testing.allocator, replacement_json);
    defer replacement.deinit();
    var same_instance = try decode(RegistryRevisionEnvelope, std.testing.allocator, same_instance_json);
    defer same_instance.deinit();

    try std.testing.expect(!old.value.sameInstance(replacement.value));
    try std.testing.expect(old.value.shouldResetProjection(replacement.value));
    try std.testing.expectEqual(@as(u64, 0), replacement.value.registry_revision);
    try std.testing.expect(old.value.sameInstance(same_instance.value));
    try std.testing.expect(!old.value.shouldResetProjection(same_instance.value));
}
