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
/// Read-only list of the workspace's `verde.toml` stack definitions, so
/// detached clients can start a whole stack by name.
pub const METHOD_PROCESS_DEFINITIONS: []const u8 = "process.definitions";
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
