//! Desktop ownership for multiple authenticated remote runtime connections.
//!
//! The manager is single-owner state intended for the desktop event thread.
//! SSH and gateway work run on dedicated workers; `poll` only observes bounded
//! state and collects workers after they report completion. This module never
//! starts, stops, or replaces a Verde daemon.

const std = @import("std");
const headless = @import("headless");
const connection = @import("connection.zig");
const gateway_transport = @import("gateway_transport.zig");
const profile = @import("profile.zig");
const profile_store = @import("profile_store.zig");
const secret_store = @import("secret_store.zig");
const tunnel_supervisor = @import("ssh_tunnel_supervisor.zig");

pub const MAX_PORT_SELECTION_ATTEMPTS: usize = 8;
pub const HEARTBEAT_INTERVAL_MS: u64 = 15_000;
pub const MAX_RPC_METHOD_BYTES: usize = 128;
pub const REPOSITORY_MANIFEST_CAPABILITY: []const u8 = "repositories.manifest.v1";
pub const REPOSITORY_CHAT_ROUTE_CAPABILITY: []const u8 = "chat.repository_route.v1";

pub const TransportKind = enum {
    local_socket,
    ssh_tunnel,
};

/// Secret-free, stable failure categories for the desktop runtime picker.
pub const Failure = enum {
    missing_credential,
    unsupported_transport,
    no_loopback_port,
    tunnel_spawn,
    tunnel_readiness,
    tunnel_wait,
    tunnel_exited,
    authentication,
    network,
    identity,
    protocol,
    resource,
};

pub const RuntimeSnapshot = struct {
    runtime_id: []const u8,
    instance_id: []const u8,
    server_version: []const u8,
    protocol_major: u32,
    protocol_minor: u32,
    negotiated_headless_protocol_version: u32,
};

/// Borrowed, secret-free projection. Its strings remain valid until the next
/// mutation of this manager. `snapshotsAlloc` bounds the row count to profiles.
pub const Snapshot = struct {
    profile_id: []const u8,
    label: []const u8,
    transport: TransportKind,
    phase: connection.Phase,
    failure: ?Failure,
    retry_at_ms: ?u64,
    local_port: ?u16,
    tunnel_lifecycle: tunnel_supervisor.Lifecycle,
    tunnel_pid: ?u32,
    runtime: ?RuntimeSnapshot,
    identity_pin_required: bool,
    rpc_in_flight: bool,
    last_heartbeat_ms: ?u64,
    /// Whether a process-memory bearer is currently hydrated. Never the value.
    credential_held: bool = false,
    /// True only when the live verified pair exactly matches the identity pair
    /// adopted from the profile document. Callers must not infer this merely
    /// from a connected phase when selecting an execution target.
    verified_runtime_matches_pin: bool = false,
    repository_manifest_capable: bool = false,
    repository_chat_route_capable: bool = false,
    /// Deliberately false until every general RPC carries the persisted
    /// runtime+instance target and the daemon checks it in the same dispatch;
    /// a separate heartbeat alone cannot authorize later mutation.
    execution_ready: bool,
};

pub const RpcTicket = struct {
    id: u64,
};

pub const RpcResponse = struct {
    allocator: std.mem.Allocator,
    json: []u8,

    pub fn deinit(self: *RpcResponse) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

/// A method-level JSON-RPC error remains a response; only failures that make
/// the authenticated runtime channel unusable are surfaced as `failed`.
pub const RpcCallResult = union(enum) {
    response: RpcResponse,
    failed: Failure,
    canceled,

    pub fn deinit(self: *RpcCallResult) void {
        switch (self.*) {
            .response => |*response| response.deinit(),
            .failed, .canceled => {},
        }
        self.* = undefined;
    }
};

/// Owned first-contact identity proposal. Controllers persist under the
/// profile-store lock, reread the authoritative pair, then acknowledge this
/// exact generation. No borrowed manager state crosses that transaction.
pub const RuntimePinProposal = struct {
    allocator: std.mem.Allocator,
    profile_id: []u8,
    generation: u64,
    runtime_id: []u8,
    instance_id: []u8,

    pub fn deinit(self: *RuntimePinProposal) void {
        self.allocator.free(self.profile_id);
        self.allocator.free(self.runtime_id);
        self.allocator.free(self.instance_id);
        self.* = undefined;
    }
};

pub const PersistedIdentity = struct {
    runtime_id: []const u8,
    instance_id: []const u8,
};

pub const PinAdoption = enum {
    committed_current,
    reconnect_required,
    installed_disabled,
};

/// Selects a candidate numeric loopback port. The supervisor must bind and
/// continuously own it before a bearer lease can be minted.
pub const PortSelector = struct {
    context: ?*anyopaque = null,
    select: *const fn (?*anyopaque, std.Io) anyerror!u16,

    pub fn system() PortSelector {
        return .{ .select = selectSystemLoopbackPort };
    }
};

/// One authenticated JSON-RPC exchange. The production implementation is the
/// fixed numeric-loopback gateway transport; injected tests never open a port.
pub const RpcBackend = struct {
    context: ?*anyopaque = null,
    call: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        u16,
        []const u8,
        []const u8,
    ) connection.TransportError![]u8,
    /// For a non-null context, retain must keep the pointed storage alive until
    /// the matching release. Calls must be bounded; system calls time out.
    retain_context: ?*const fn (?*anyopaque) void = null,
    release_context: ?*const fn (?*anyopaque) void = null,

    pub fn system() RpcBackend {
        return .{ .call = callSystemGateway };
    }

    fn validateLifetime(self: RpcBackend) !void {
        if (self.context == null) return;
        if (self.retain_context == null or self.release_context == null) {
            return error.UnsafeRpcBackendLifetime;
        }
    }

    fn retainContext(self: RpcBackend) void {
        if (self.retain_context) |retain| retain(self.context);
    }

    fn releaseContext(self: RpcBackend) void {
        if (self.release_context) |release| release(self.context);
    }
};

pub const Dependencies = struct {
    port_selector: PortSelector = PortSelector.system(),
    tunnel_backend: tunnel_supervisor.Backend = tunnel_supervisor.Backend.system(),
    rpc_backend: RpcBackend = RpcBackend.system(),
};

pub const ProfileReplacement = enum { label_only, endpoint_changed };

const Entry = struct {
    owned_profile: profile.Profile,
    connection_state: connection.Connection,
    supervisor: tunnel_supervisor.Supervisor = tunnel_supervisor.Supervisor.init(),
    tunnel_owned: bool = false,
    tunnel_generation: ?u64 = null,
    local_port: ?u16 = null,
    handshake: ?*HandshakeTask = null,
    rpc_task: ?*RpcTask = null,
    rpc_result: ?CompletedRpc = null,
    healthy_generation: ?u64 = null,
    last_heartbeat_ms: ?u64 = null,
    next_heartbeat_at_ms: ?u64 = null,
    failure_override: ?Failure = null,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        // Both handoffs are non-blocking. Their worker-owned state and retained
        // callback contexts remain valid independently of this entry.
        self.supervisor.deinit();
        if (self.handshake) |task| {
            task.handoffToProcessReaper();
        }
        if (self.rpc_task) |task| task.handoffToProcessReaper();
        if (self.rpc_result) |*completed| completed.result.deinit();
        self.connection_state.deinit();
        self.owned_profile.deinit(allocator);
        self.* = undefined;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dependencies: Dependencies,
    secrets: secret_store.Store,
    entries: std.ArrayList(Entry) = .empty,
    next_rpc_id: u64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        profiles: []const profile.Profile,
        dependencies: Dependencies,
    ) !Manager {
        if (profiles.len > profile.MAX_PROFILES) return error.TooManyProfiles;
        try dependencies.rpc_backend.validateLifetime();
        var self: Manager = .{
            .allocator = allocator,
            .io = io,
            .dependencies = dependencies,
            .secrets = secret_store.Store.init(allocator),
        };
        errdefer self.deinit();
        for (profiles) |configured_profile| try self.addProfile(configured_profile);
        return self;
    }

    pub fn deinit(self: *Manager) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.secrets.deinit();
        self.* = undefined;
    }

    /// Adds an independently owned profile. Callback contexts must remain valid
    /// while the manager can synchronously invoke them; worker use is protected
    /// by the dependency's required retain/release contract.
    pub fn addProfile(self: *Manager, configured_profile: profile.Profile) !void {
        if (self.entries.items.len >= profile.MAX_PROFILES) return error.TooManyProfiles;
        if (self.findEntry(configured_profile.id) != null) return error.DuplicateProfileId;

        var owned_profile = try cloneProfile(self.allocator, configured_profile);
        errdefer owned_profile.deinit(self.allocator);
        var connection_state = try connection.Connection.init(
            self.allocator,
            owned_profile.id,
            owned_profile.expected_runtime_id,
            owned_profile.expected_instance_id,
        );
        errdefer connection_state.deinit();
        try self.entries.append(self.allocator, .{
            .owned_profile = owned_profile,
            .connection_state = connection_state,
        });
    }

    /// Hydrates or replaces a process-memory-only bearer token by profile ID.
    pub fn hydrateToken(self: *Manager, profile_id: []const u8, token: []const u8) !void {
        const entry = self.findEntry(profile_id) orelse return error.UnknownRuntimeProfile;
        try secret_store.validateToken(token);
        if (self.secrets.get(profile_id)) |previous| {
            if (!std.mem.eql(u8, previous, token)) {
                // Replacing a credential revokes the generation that could
                // otherwise stay ready or publish using the old token copy.
                try entry.connection_state.disable();
                clearHealth(entry);
                entry.failure_override = null;
                if (entry.tunnel_owned) entry.supervisor.stop();
                self.collectTerminalTunnel(entry);
            }
        }
        try self.secrets.put(profile_id, token);
        if (entry.failure_override == .missing_credential) entry.failure_override = null;
    }

    /// Invalidates the active generation, requests exact tunnel termination,
    /// then wipes the hydrated token. A late handshake can no longer publish.
    pub fn clearToken(self: *Manager, profile_id: []const u8) !bool {
        const entry = self.findEntry(profile_id) orelse return error.UnknownRuntimeProfile;
        try entry.connection_state.disable();
        clearHealth(entry);
        entry.failure_override = null;
        if (entry.tunnel_owned) entry.supervisor.stop();
        self.collectTerminalTunnel(entry);
        return self.secrets.remove(profile_id);
    }

    /// Removes a configured profile. The live generation is invalidated first
    /// so a late handshake cannot publish, the tunnel is asked to stop, the
    /// hydrated token is wiped, and any still-running worker is handed to the
    /// process reaper. Returns whether a token was forgotten.
    pub fn removeProfile(self: *Manager, profile_id: []const u8) !bool {
        const index = self.findEntryIndex(profile_id) orelse return error.UnknownRuntimeProfile;
        const entry = &self.entries.items[index];
        try entry.connection_state.disable();
        clearHealth(entry);
        entry.failure_override = null;
        if (entry.tunnel_owned) entry.supervisor.stop();
        self.collectTerminalTunnel(entry);
        const forgot_token = self.secrets.remove(profile_id);
        var removed = self.entries.orderedRemove(index);
        removed.deinit(self.allocator);
        return forgot_token;
    }

    /// Replaces non-secret profile fields from an authoritative store reload.
    /// A label-only change keeps the live generation and trust. Any endpoint
    /// change is treated as a new peer: the generation is invalidated, health
    /// is dropped, and the connection tracks the (already cleared) identity of
    /// the replacement profile instead of silently retaining trust.
    pub fn replaceProfile(self: *Manager, configured_profile: profile.Profile) !ProfileReplacement {
        const index = self.findEntryIndex(configured_profile.id) orelse return error.UnknownRuntimeProfile;
        const entry = &self.entries.items[index];
        if (profileEndpointsEqual(entry.owned_profile, configured_profile)) {
            const label = try self.allocator.dupe(u8, configured_profile.label);
            self.allocator.free(entry.owned_profile.label);
            entry.owned_profile.label = label;
            return .label_only;
        }
        _ = try self.removeProfile(configured_profile.id);
        var replacement = configured_profile;
        replacement.expected_runtime_id = null;
        replacement.expected_instance_id = null;
        try self.addProfile(replacement);
        // Keep the original ordering so picker/settings rows do not jump.
        const appended = self.entries.items.len - 1;
        if (appended != index) {
            const moved = self.entries.orderedRemove(appended);
            try self.entries.insert(self.allocator, index, moved);
        }
        return .endpoint_changed;
    }

    /// Borrowed profile IDs in display order; valid until the next mutation.
    pub fn profileIdsAlloc(self: *const Manager, allocator: std.mem.Allocator) ![][]const u8 {
        const ids = try allocator.alloc([]const u8, self.entries.items.len);
        for (self.entries.items, 0..) |entry, index| ids[index] = entry.owned_profile.id;
        return ids;
    }

    pub fn profileConst(self: *const Manager, profile_id: []const u8) ?*const profile.Profile {
        const entry = self.findEntryConst(profile_id) orelse return null;
        return &entry.owned_profile;
    }

    /// Starts an SSH attempt without waiting for authentication or network IO.
    pub fn enable(self: *Manager, profile_id: []const u8, now_ms: u64) !void {
        const index = self.findEntryIndex(profile_id) orelse return error.UnknownRuntimeProfile;
        const entry = &self.entries.items[index];
        if (entry.owned_profile.transport != .ssh_tunnel) {
            entry.failure_override = .unsupported_transport;
            return error.UnsupportedRuntimeTransport;
        }
        if (self.secrets.get(profile_id) == null) {
            entry.failure_override = .missing_credential;
            return error.MissingRuntimeCredential;
        }

        self.collectTerminalTunnel(entry);
        const generation = try entry.connection_state.enable();
        clearHealth(entry);
        entry.failure_override = null;
        if (!entry.tunnel_owned and entry.handshake == null) {
            try self.startAttempt(index, generation, now_ms);
        } else if (entry.tunnel_owned) {
            entry.supervisor.stop();
        }
    }

    /// Invalidates all current work and requests exact SSH-tree termination.
    /// The call never joins; `poll` collects only a terminal supervisor.
    pub fn disable(self: *Manager, profile_id: []const u8) !void {
        const entry = self.findEntry(profile_id) orelse return error.UnknownRuntimeProfile;
        try entry.connection_state.disable();
        clearHealth(entry);
        entry.failure_override = null;
        if (entry.tunnel_owned) entry.supervisor.stop();
        self.collectTerminalTunnel(entry);
    }

    /// Queues a fresh user-requested attempt after a terminal failure. Old SSH
    /// and handshake workers are allowed to finish but cannot win generation.
    pub fn retry(self: *Manager, profile_id: []const u8, now_ms: u64) !void {
        const index = self.findEntryIndex(profile_id) orelse return error.UnknownRuntimeProfile;
        const entry = &self.entries.items[index];
        if (self.secrets.get(profile_id) == null) {
            entry.failure_override = .missing_credential;
            return error.MissingRuntimeCredential;
        }
        self.collectTerminalTunnel(entry);
        const generation = try entry.connection_state.retryFailed();
        clearHealth(entry);
        entry.failure_override = null;
        if (!entry.tunnel_owned and entry.handshake == null) {
            try self.startAttempt(index, generation, now_ms);
        } else if (entry.tunnel_owned) {
            entry.supervisor.stop();
        }
    }

    /// Advances every profile with bounded owner-thread work. Gateway calls
    /// remain on handshake workers and supervisor collection joins only after
    /// a terminal lifecycle has already been published.
    pub fn poll(self: *Manager, now_ms: u64) !void {
        for (0..self.entries.items.len) |index| try self.pollEntry(index, now_ms);
    }

    pub fn snapshot(self: *const Manager, profile_id: []const u8) ?Snapshot {
        const entry = self.findEntryConst(profile_id) orelse return null;
        var row = snapshotEntry(entry);
        row.credential_held = self.secrets.get(profile_id) != null;
        return row;
    }

    /// Allocates only the bounded row array; all strings inside remain borrowed.
    pub fn snapshotsAlloc(self: *const Manager, allocator: std.mem.Allocator) ![]Snapshot {
        const snapshots = try allocator.alloc(Snapshot, self.entries.items.len);
        for (self.entries.items, 0..) |*entry, index| {
            snapshots[index] = snapshotEntry(entry);
            snapshots[index].credential_held = self.secrets.get(entry.owned_profile.id) != null;
        }
        return snapshots;
    }

    /// Copies the verified identity plus its profile generation for a durable
    /// lock/reload/conflict-check/save/reread transaction.
    pub fn runtimePinProposalAlloc(
        self: *const Manager,
        allocator: std.mem.Allocator,
        profile_id: []const u8,
    ) !?RuntimePinProposal {
        const entry = self.findEntryConst(profile_id) orelse return null;
        const metadata = entry.connection_state.pendingTrustMetadata() orelse return null;
        const owned_profile_id = try allocator.dupe(u8, entry.owned_profile.id);
        errdefer allocator.free(owned_profile_id);
        const runtime_id = try allocator.dupe(u8, metadata.runtime_id);
        errdefer allocator.free(runtime_id);
        const instance_id = try allocator.dupe(u8, metadata.instance_id);
        return .{
            .allocator = allocator,
            .profile_id = owned_profile_id,
            .generation = entry.connection_state.generation,
            .runtime_id = runtime_id,
            .instance_id = instance_id,
        };
    }

    /// Adopts the identity pair reread from durable storage. A matching live
    /// proposal becomes ready; a stale proposal or save conflict installs the
    /// disk pair but invalidates and reconnects all current work.
    pub fn acknowledgePersistedRuntimePin(
        self: *Manager,
        proposal: *const RuntimePinProposal,
        persisted: PersistedIdentity,
    ) !PinAdoption {
        const entry = self.findEntry(proposal.profile_id) orelse return error.UnknownRuntimeProfile;
        try connection.validateRuntimeId(proposal.runtime_id);
        try connection.validateRuntimeId(proposal.instance_id);
        try connection.validateRuntimeId(persisted.runtime_id);
        try connection.validateRuntimeId(persisted.instance_id);

        const profile_runtime_id = try self.allocator.dupe(u8, persisted.runtime_id);
        errdefer self.allocator.free(profile_runtime_id);
        const profile_instance_id = try self.allocator.dupe(u8, persisted.instance_id);
        errdefer self.allocator.free(profile_instance_id);
        const tunnel = entry.supervisor.getSnapshot();
        const allow_commit_current = entry.tunnel_owned and
            entry.tunnel_generation == proposal.generation and
            tunnel.lifecycle == .running;
        const adoption = try entry.connection_state.adoptPersistedIdentity(
            proposal.generation,
            proposal.runtime_id,
            proposal.instance_id,
            persisted.runtime_id,
            persisted.instance_id,
            allow_commit_current,
        );
        if (entry.owned_profile.expected_runtime_id) |runtime_id| self.allocator.free(runtime_id);
        if (entry.owned_profile.expected_instance_id) |instance_id| self.allocator.free(instance_id);
        entry.owned_profile.expected_runtime_id = profile_runtime_id;
        entry.owned_profile.expected_instance_id = profile_instance_id;
        clearHealth(entry);
        entry.failure_override = null;

        return switch (adoption) {
            .committed_current => .committed_current,
            .reconnect_required => blk: {
                if (entry.tunnel_owned) entry.supervisor.stop();
                self.collectTerminalTunnel(entry);
                break :blk .reconnect_required;
            },
            .installed_disabled => .installed_disabled,
        };
    }

    pub fn expectedRuntimeId(self: *const Manager, profile_id: []const u8) ?[]const u8 {
        const entry = self.findEntryConst(profile_id) orelse return null;
        return entry.owned_profile.expected_runtime_id;
    }

    pub fn expectedInstanceId(self: *const Manager, profile_id: []const u8) ?[]const u8 {
        const entry = self.findEntryConst(profile_id) orelse return null;
        return entry.owned_profile.expected_instance_id;
    }

    /// Starts one bounded general RPC off the owner thread. The target pair is
    /// copied from the durably adopted profile and cannot be supplied or
    /// overridden by the caller.
    pub fn beginRpc(
        self: *Manager,
        profile_id: []const u8,
        method: []const u8,
        params: anytype,
    ) !RpcTicket {
        try validateRpcMethod(method);
        const entry = self.findEntry(profile_id) orelse return error.UnknownRuntimeProfile;
        if (!entryExecutionReady(entry)) return error.RuntimeNotExecutionReady;
        if (entry.rpc_task != null) return error.RuntimeRpcBusy;
        if (entry.rpc_result != null) return error.RuntimeRpcResultPending;

        const runtime_id = entry.owned_profile.expected_runtime_id orelse
            return error.RuntimeNotExecutionReady;
        const instance_id = entry.owned_profile.expected_instance_id orelse
            return error.RuntimeNotExecutionReady;
        const request_id = try self.allocateRpcId();
        var encoder = try headless.Client.initTargetedEncoder(self.allocator, .{
            .runtime_id = runtime_id,
            .instance_id = instance_id,
        });
        const request_json = try encoder.encodeRequestWithId(request_id, method, params);
        defer self.allocator.free(request_json);
        if (request_json.len > headless.protocol.RUNTIME_MAX_MESSAGE_BYTES) {
            return error.RuntimeRpcRequestTooLarge;
        }

        const ticket: RpcTicket = .{ .id = request_id };
        try self.startRpcTask(entry, .{ .user = ticket }, request_id, request_json);
        return ticket;
    }

    /// Returns null while the matching worker is active, then transfers its
    /// one bounded result. Unknown or already-consumed tickets are rejected.
    pub fn takeRpcResult(self: *Manager, ticket: RpcTicket) !?RpcCallResult {
        for (self.entries.items) |*entry| {
            if (entry.rpc_task) |task| switch (task.kind) {
                .heartbeat => {},
                .user => |active| if (active.id == ticket.id) return null,
            };
            if (entry.rpc_result) |*completed| {
                if (completed.ticket.id != ticket.id) continue;
                const result = completed.result;
                entry.rpc_result = null;
                return result;
            }
        }
        return error.UnknownRuntimeRpcTicket;
    }

    fn pollEntry(self: *Manager, index: usize, now_ms: u64) !void {
        var entry = &self.entries.items[index];
        // A terminal relay owns the attempt outcome. Observe it before a
        // simultaneously completed HTTP worker so spawn/readiness failures
        // cannot be downgraded into a generic network reconnect.
        try self.observeTunnel(entry, now_ms);
        try self.collectHandshake(entry, now_ms);
        try self.collectRpc(entry, now_ms);

        switch (entry.connection_state.phase()) {
            .disabled, .failed => {
                clearHealth(entry);
                if (entry.tunnel_owned) entry.supervisor.stop();
                self.collectTerminalTunnel(entry);
            },
            .reconnecting => {
                clearHealth(entry);
                if (entry.tunnel_owned) entry.supervisor.stop();
                self.collectTerminalTunnel(entry);
                if (!entry.tunnel_owned and entry.handshake == null) {
                    if (try entry.connection_state.reconnectIfDue(now_ms)) |generation| {
                        self.startAttempt(index, generation, now_ms) catch {};
                    }
                }
            },
            .connecting => {
                clearHealth(entry);
                if (!entry.tunnel_owned and entry.handshake == null) {
                    self.startAttempt(index, entry.connection_state.generation, now_ms) catch {};
                } else if (entry.tunnel_owned and entry.handshake == null) {
                    const tunnel = entry.supervisor.getSnapshot();
                    if (tunnel.lifecycle == .running and
                        entry.tunnel_generation == entry.connection_state.generation)
                    {
                        try self.startHandshake(entry, now_ms);
                    }
                }
            },
            .handshaking, .awaiting_trust => clearHealth(entry),
            .ready => {
                entry.failure_override = null;
                if (!runtimeAdvertisesTargeting(entry)) {
                    try self.invalidateExecution(entry, .protocol, now_ms);
                } else if (entry.rpc_task == null and heartbeatDue(entry, now_ms)) {
                    self.startHeartbeat(entry) catch |err| {
                        const failure: connection.FailureKind = switch (err) {
                            error.MissingRuntimeCredential => .authentication,
                            error.RelayNotReady, error.BearerLeaseAlreadyHeld => .network,
                            else => .resource,
                        };
                        try self.invalidateExecution(entry, failure, now_ms);
                    };
                }
            },
        }
    }

    fn startAttempt(
        self: *Manager,
        index: usize,
        generation: u64,
        now_ms: u64,
    ) !void {
        var entry = &self.entries.items[index];
        if (self.secrets.get(entry.owned_profile.id) == null) {
            _ = try entry.connection_state.failAttempt(
                generation,
                .authentication,
                now_ms,
                reconnectJitter(entry, generation),
            );
            entry.failure_override = .missing_credential;
            return error.MissingRuntimeCredential;
        }

        const local_port = self.selectUniquePort(index) catch |err| {
            _ = try entry.connection_state.failAttempt(
                generation,
                .resource,
                now_ms,
                reconnectJitter(entry, generation),
            );
            entry.failure_override = .no_loopback_port;
            return err;
        };
        const ssh = switch (entry.owned_profile.transport) {
            .ssh_tunnel => |ssh| ssh,
            .local_socket => return error.UnsupportedRuntimeTransport,
        };
        entry.supervisor.startWithBackend(
            self.allocator,
            self.io,
            ssh,
            local_port,
            self.dependencies.tunnel_backend,
        ) catch |err| {
            _ = try entry.connection_state.failAttempt(
                generation,
                .resource,
                now_ms,
                reconnectJitter(entry, generation),
            );
            entry.failure_override = .tunnel_spawn;
            return err;
        };
        entry.tunnel_owned = true;
        entry.tunnel_generation = generation;
        entry.local_port = local_port;
        entry.failure_override = null;
    }

    fn startHandshake(self: *Manager, entry: *Entry, now_ms: u64) !void {
        const generation = entry.tunnel_generation orelse return error.MissingTunnelGeneration;
        const token = self.secrets.get(entry.owned_profile.id) orelse {
            _ = try entry.connection_state.failAttempt(
                generation,
                .authentication,
                now_ms,
                reconnectJitter(entry, generation),
            );
            entry.failure_override = .missing_credential;
            entry.supervisor.stop();
            return;
        };
        var bearer_lease = entry.supervisor.acquireBearerLease() catch {
            _ = try entry.connection_state.failAttempt(
                generation,
                .network,
                now_ms,
                reconnectJitter(entry, generation),
            );
            entry.failure_override = .tunnel_readiness;
            entry.supervisor.stop();
            return;
        };
        defer bearer_lease.release();
        if (try entry.connection_state.beginHandshake(generation) == .stale) return;

        entry.handshake = HandshakeTask.start(
            self.allocator,
            generation,
            entry.local_port orelse return error.MissingTunnelPort,
            token,
            entry.connection_state.expectedRuntimeId(),
            self.dependencies.rpc_backend,
            &bearer_lease,
        ) catch |err| {
            _ = try entry.connection_state.failAttempt(
                generation,
                .resource,
                now_ms,
                reconnectJitter(entry, generation),
            );
            entry.failure_override = .resource;
            entry.supervisor.stop();
            return err;
        };
    }

    fn collectHandshake(_: *Manager, entry: *Entry, now_ms: u64) !void {
        const task = entry.handshake orelse return;
        if (task.state.load(.acquire) != .finished) return;

        const generation = task.generation;
        const result = task.takeResult();
        const task_allocator = task.allocator;
        task.releaseFields();
        task_allocator.destroy(task);
        entry.handshake = null;
        if (!entry.tunnel_owned) entry.local_port = null;

        switch (result) {
            .outcome => |outcome| {
                const applied = try entry.connection_state.completeHandshake(
                    generation,
                    outcome,
                    now_ms,
                    reconnectJitter(entry, generation),
                );
                if (applied == .applied) {
                    entry.failure_override = if (entry.connection_state.lastFailure()) |failure|
                        mapConnectionFailure(failure)
                    else
                        null;
                }
            },
            .resource => {
                const applied = try entry.connection_state.failAttempt(
                    generation,
                    .resource,
                    now_ms,
                    reconnectJitter(entry, generation),
                );
                if (applied == .applied) entry.failure_override = .resource;
            },
        }
    }

    fn collectRpc(self: *Manager, entry: *Entry, now_ms: u64) !void {
        const task = entry.rpc_task orelse return;
        if (task.state.load(.acquire) != .finished) return;

        const generation = task.generation;
        const request_id = task.request_id;
        const kind = task.kind;
        const task_allocator = task.allocator;
        var worker_result: ?RpcWorkerResult = task.takeResult();
        task.releaseFields();
        task_allocator.destroy(task);
        entry.rpc_task = null;
        if (!entry.tunnel_owned and entry.handshake == null) entry.local_port = null;
        defer if (worker_result) |*result| result.deinit(task_allocator);

        if (!rpcGenerationIsCurrent(entry, generation)) {
            if (kind == .user) {
                entry.rpc_result = .{
                    .ticket = kind.user,
                    .result = .canceled,
                };
            }
            return;
        }

        switch (worker_result.?) {
            .failed => |failure| {
                try self.invalidateExecution(entry, failure, now_ms);
                if (kind == .user) {
                    entry.rpc_result = .{
                        .ticket = kind.user,
                        .result = .{ .failed = mapConnectionFailure(failure) },
                    };
                }
            },
            .response => |response| {
                if (inspectRpcResponse(
                    self.allocator,
                    kind,
                    request_id,
                    response,
                    entry.owned_profile.expected_runtime_id.?,
                    entry.owned_profile.expected_instance_id.?,
                )) |failure| {
                    try self.invalidateExecution(entry, failure, now_ms);
                    if (kind == .user) {
                        entry.rpc_result = .{
                            .ticket = kind.user,
                            .result = .{ .failed = mapConnectionFailure(failure) },
                        };
                    }
                } else {
                    entry.healthy_generation = generation;
                    entry.last_heartbeat_ms = now_ms;
                    entry.next_heartbeat_at_ms = now_ms +| HEARTBEAT_INTERVAL_MS;
                    if (kind == .user) {
                        entry.rpc_result = .{
                            .ticket = kind.user,
                            .result = .{ .response = .{
                                .allocator = task_allocator,
                                .json = response,
                            } },
                        };
                        worker_result = null;
                    }
                }
            },
        }
    }

    fn startHeartbeat(self: *Manager, entry: *Entry) !void {
        const runtime_id = entry.owned_profile.expected_runtime_id orelse
            return error.RuntimeIdentityNotPinned;
        const instance_id = entry.owned_profile.expected_instance_id orelse
            return error.RuntimeIdentityNotPinned;
        const request_id = try self.allocateRpcId();
        var encoder = try headless.Client.initTargetedEncoder(self.allocator, .{
            .runtime_id = runtime_id,
            .instance_id = instance_id,
        });
        const request_json = try encoder.encodeRequestWithId(
            request_id,
            "core.status",
            struct {}{},
        );
        defer self.allocator.free(request_json);
        if (request_json.len > headless.protocol.RUNTIME_MAX_MESSAGE_BYTES) {
            return error.RuntimeRpcRequestTooLarge;
        }
        try self.startRpcTask(entry, .heartbeat, request_id, request_json);
    }

    fn startRpcTask(
        self: *Manager,
        entry: *Entry,
        kind: RpcTaskKind,
        request_id: u64,
        request_json: []const u8,
    ) !void {
        if (entry.rpc_task != null) return error.RuntimeRpcBusy;
        if (entry.connection_state.phase() != .ready) return error.RuntimeNotExecutionReady;
        const generation = entry.connection_state.generation;
        if (!entry.tunnel_owned or entry.tunnel_generation != generation) {
            return error.RelayNotReady;
        }
        if (entry.supervisor.getSnapshot().lifecycle != .running) return error.RelayNotReady;
        const token = self.secrets.get(entry.owned_profile.id) orelse
            return error.MissingRuntimeCredential;
        var bearer_lease = try entry.supervisor.acquireBearerLease();
        defer bearer_lease.release();
        entry.rpc_task = try RpcTask.start(
            generation,
            request_id,
            kind,
            entry.local_port orelse return error.MissingTunnelPort,
            token,
            request_json,
            self.dependencies.rpc_backend,
            &bearer_lease,
        );
    }

    fn invalidateExecution(
        _: *Manager,
        entry: *Entry,
        failure: connection.FailureKind,
        now_ms: u64,
    ) !void {
        clearHealth(entry);
        if (entry.connection_state.phase() == .ready) {
            try entry.connection_state.postHandshakeFailure(
                failure,
                now_ms,
                reconnectJitter(entry, entry.connection_state.generation),
            );
        }
        entry.failure_override = mapConnectionFailure(failure);
        if (entry.tunnel_owned) entry.supervisor.stop();
    }

    fn allocateRpcId(self: *Manager) !u64 {
        if (self.next_rpc_id == std.math.maxInt(u64)) return error.RuntimeRpcIdExhausted;
        const id = self.next_rpc_id;
        self.next_rpc_id += 1;
        return id;
    }

    fn observeTunnel(self: *Manager, entry: *Entry, now_ms: u64) !void {
        if (!entry.tunnel_owned) return;
        const tunnel = entry.supervisor.getSnapshot();
        switch (tunnel.lifecycle) {
            .stopped, .exited, .failed => {},
            .starting, .running, .stopping => return,
        }

        clearHealth(entry);
        const observed_failure = mapTunnelFailure(tunnel);
        switch (entry.connection_state.phase()) {
            .connecting, .handshaking => if (entry.tunnel_generation) |generation| {
                const applied = try entry.connection_state.abortAttempt(
                    generation,
                    tunnelConnectionFailure(tunnel),
                    now_ms,
                    reconnectJitter(entry, generation),
                );
                if (applied == .applied) entry.failure_override = observed_failure;
            },
            .ready, .awaiting_trust => {
                try entry.connection_state.connectionLost(
                    now_ms,
                    reconnectJitter(entry, entry.connection_state.generation),
                );
                entry.failure_override = observed_failure;
            },
            .disabled, .failed, .reconnecting => {},
        }
        self.collectTerminalTunnel(entry);
    }

    fn collectTerminalTunnel(_: *Manager, entry: *Entry) void {
        if (!entry.tunnel_owned) return;
        if (!entry.supervisor.collectIfTerminal()) return;
        entry.tunnel_owned = false;
        entry.tunnel_generation = null;
        // A stale worker still holds both a copied bearer and this numeric port.
        // Reserve it against every other profile until that worker is collected;
        // the supervisor's bearer lease independently keeps the listener bound.
        if (entry.handshake == null and entry.rpc_task == null) entry.local_port = null;
    }

    fn selectUniquePort(self: *Manager, current_index: usize) !u16 {
        for (0..MAX_PORT_SELECTION_ATTEMPTS) |_| {
            const candidate = self.dependencies.port_selector.select(
                self.dependencies.port_selector.context,
                self.io,
            ) catch continue;
            if (candidate == 0 or self.portInUse(candidate, current_index)) continue;
            return candidate;
        }
        return error.NoLoopbackPortAvailable;
    }

    fn portInUse(self: *const Manager, port: u16, current_index: usize) bool {
        for (self.entries.items, 0..) |entry, index| {
            if (index != current_index and entry.local_port == port) return true;
        }
        return false;
    }

    fn findEntry(self: *Manager, profile_id: []const u8) ?*Entry {
        const index = self.findEntryIndex(profile_id) orelse return null;
        return &self.entries.items[index];
    }

    fn findEntryConst(self: *const Manager, profile_id: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.owned_profile.id, profile_id)) return entry;
        }
        return null;
    }

    fn findEntryIndex(self: *const Manager, profile_id: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.owned_profile.id, profile_id)) return index;
        }
        return null;
    }
};

const HandshakeResult = union(enum) {
    outcome: connection.HandshakeOutcome,
    resource,

    fn deinit(self: *HandshakeResult) void {
        switch (self.*) {
            .outcome => |*outcome| outcome.deinit(),
            .resource => {},
        }
        self.* = undefined;
    }
};

const HandshakeTask = struct {
    allocator: std.mem.Allocator,
    generation: u64,
    local_port: u16,
    token: []u8,
    expected_runtime_id: ?[]u8,
    rpc_backend: RpcBackend,
    bearer_lease: tunnel_supervisor.BearerLease,
    worker: ?std.Thread = null,
    state: std.atomic.Value(TaskState) = .init(.running),
    result: ?HandshakeResult = null,

    fn start(
        allocator: std.mem.Allocator,
        generation: u64,
        local_port: u16,
        token: []const u8,
        expected_runtime_id: ?[]const u8,
        rpc_backend: RpcBackend,
        bearer_lease: *tunnel_supervisor.BearerLease,
    ) !*HandshakeTask {
        _ = allocator;
        try rpc_backend.validateLifetime();
        // The task may outlive Manager.deinit while a bounded gateway call
        // completes, so all task memory is process-owned.
        const task_allocator = std.heap.page_allocator;
        const task = try task_allocator.create(HandshakeTask);
        errdefer task_allocator.destroy(task);
        const token_copy = try task_allocator.dupe(u8, token);
        errdefer eraseAndFree(task_allocator, token_copy);
        const expected_copy = if (expected_runtime_id) |runtime_id|
            try task_allocator.dupe(u8, runtime_id)
        else
            null;
        errdefer if (expected_copy) |runtime_id| task_allocator.free(runtime_id);
        rpc_backend.retainContext();
        errdefer rpc_backend.releaseContext();
        task.* = .{
            .allocator = task_allocator,
            .generation = generation,
            .local_port = local_port,
            .token = token_copy,
            .expected_runtime_id = expected_copy,
            .rpc_backend = rpc_backend,
            .bearer_lease = bearer_lease.take(),
        };
        errdefer task.bearer_lease.release();
        task.worker = try std.Thread.spawn(.{}, handshakeWorker, .{task});
        return task;
    }

    fn releaseFields(self: *HandshakeTask) void {
        if (self.result) |*result| result.deinit();
        eraseAndFree(self.allocator, self.token);
        if (self.expected_runtime_id) |runtime_id| self.allocator.free(runtime_id);
        self.rpc_backend.releaseContext();
    }

    fn takeResult(self: *HandshakeTask) HandshakeResult {
        std.debug.assert(self.state.load(.acquire) == .finished);
        if (self.worker) |worker| worker.join();
        self.worker = null;
        const result = self.result orelse unreachable;
        self.result = null;
        return result;
    }

    fn handoffToProcessReaper(self: *HandshakeTask) void {
        const worker = self.worker orelse unreachable;
        const previous = self.state.cmpxchgStrong(
            .running,
            .abandoned,
            .acq_rel,
            .acquire,
        );
        if (previous == null) {
            // The worker owns process-allocated state plus a retained backend
            // context after observing `.abandoned`.
            worker.detach();
            return;
        }
        std.debug.assert(previous.? == .finished);
        worker.join();
        const allocator = self.allocator;
        self.releaseFields();
        allocator.destroy(self);
    }
};

const TaskState = enum(u8) {
    running,
    finished,
    abandoned,
};

const RpcTaskKind = union(enum) {
    heartbeat,
    user: RpcTicket,
};

const RpcWorkerResult = union(enum) {
    response: []u8,
    failed: connection.FailureKind,

    fn deinit(self: *RpcWorkerResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .response => |response| allocator.free(response),
            .failed => {},
        }
        self.* = undefined;
    }
};

const CompletedRpc = struct {
    ticket: RpcTicket,
    result: RpcCallResult,
};

const RpcTask = struct {
    allocator: std.mem.Allocator,
    generation: u64,
    request_id: u64,
    kind: RpcTaskKind,
    local_port: u16,
    token: []u8,
    request_json: []u8,
    rpc_backend: RpcBackend,
    bearer_lease: tunnel_supervisor.BearerLease,
    worker: ?std.Thread = null,
    state: std.atomic.Value(TaskState) = .init(.running),
    result: ?RpcWorkerResult = null,

    fn start(
        generation: u64,
        request_id: u64,
        kind: RpcTaskKind,
        local_port: u16,
        token: []const u8,
        request_json: []const u8,
        rpc_backend: RpcBackend,
        bearer_lease: *tunnel_supervisor.BearerLease,
    ) !*RpcTask {
        try rpc_backend.validateLifetime();
        const task_allocator = std.heap.page_allocator;
        const task = try task_allocator.create(RpcTask);
        errdefer task_allocator.destroy(task);
        const token_copy = try task_allocator.dupe(u8, token);
        errdefer eraseAndFree(task_allocator, token_copy);
        const request_copy = try task_allocator.dupe(u8, request_json);
        errdefer eraseAndFree(task_allocator, request_copy);
        rpc_backend.retainContext();
        errdefer rpc_backend.releaseContext();
        task.* = .{
            .allocator = task_allocator,
            .generation = generation,
            .request_id = request_id,
            .kind = kind,
            .local_port = local_port,
            .token = token_copy,
            .request_json = request_copy,
            .rpc_backend = rpc_backend,
            .bearer_lease = bearer_lease.take(),
        };
        errdefer task.bearer_lease.release();
        task.worker = try std.Thread.spawn(.{}, rpcWorker, .{task});
        return task;
    }

    fn releaseFields(self: *RpcTask) void {
        if (self.result) |*result| result.deinit(self.allocator);
        eraseAndFree(self.allocator, self.token);
        eraseAndFree(self.allocator, self.request_json);
        self.rpc_backend.releaseContext();
    }

    fn takeResult(self: *RpcTask) RpcWorkerResult {
        std.debug.assert(self.state.load(.acquire) == .finished);
        if (self.worker) |worker| worker.join();
        self.worker = null;
        const result = self.result orelse unreachable;
        self.result = null;
        return result;
    }

    fn handoffToProcessReaper(self: *RpcTask) void {
        const worker = self.worker orelse unreachable;
        const previous = self.state.cmpxchgStrong(
            .running,
            .abandoned,
            .acq_rel,
            .acquire,
        );
        if (previous == null) {
            worker.detach();
            return;
        }
        std.debug.assert(previous.? == .finished);
        worker.join();
        const allocator = self.allocator;
        self.releaseFields();
        allocator.destroy(self);
    }
};

fn rpcWorker(task: *RpcTask) void {
    task.result = if (task.rpc_backend.call(
        task.rpc_backend.context,
        task.allocator,
        task.local_port,
        task.token,
        task.request_json,
    )) |response| blk: {
        if (response.len > headless.protocol.RUNTIME_MAX_MESSAGE_BYTES) {
            task.allocator.free(response);
            break :blk .{ .failed = .protocol };
        }
        break :blk .{ .response = response };
    } else |err| .{ .failed = mapTransportFailure(err) };
    task.bearer_lease.release();
    const previous = task.state.swap(.finished, .acq_rel);
    switch (previous) {
        .running => {},
        .abandoned => {
            const allocator = task.allocator;
            task.releaseFields();
            allocator.destroy(task);
        },
        .finished => unreachable,
    }
}

const RpcBridge = struct {
    backend: RpcBackend,
    local_port: u16,
    token: []const u8,

    fn send(
        raw_context: *anyopaque,
        allocator: std.mem.Allocator,
        request_json: []const u8,
    ) connection.TransportError![]u8 {
        const self: *RpcBridge = @ptrCast(@alignCast(raw_context));
        return self.backend.call(
            self.backend.context,
            allocator,
            self.local_port,
            self.token,
            request_json,
        );
    }
};

fn handshakeWorker(task: *HandshakeTask) void {
    var bridge: RpcBridge = .{
        .backend = task.rpc_backend,
        .local_port = task.local_port,
        .token = task.token,
    };
    task.result = if (connection.performHandshakeAlloc(
        task.allocator,
        task.expected_runtime_id,
        &bridge,
        RpcBridge.send,
    )) |outcome|
        .{ .outcome = outcome }
    else |_|
        .resource;
    // Release the continuously bound port only after the bearer-bearing RPC
    // can no longer initiate or retry a loopback connection.
    task.bearer_lease.release();
    const previous = task.state.swap(.finished, .acq_rel);
    switch (previous) {
        .running => {},
        .abandoned => {
            const allocator = task.allocator;
            task.releaseFields();
            allocator.destroy(task);
        },
        .finished => unreachable,
    }
}

fn selectSystemLoopbackPort(_: ?*anyopaque, io: std.Io) anyerror!u16 {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    if (port == 0) return error.NoLoopbackPortAvailable;
    return port;
}

fn callSystemGateway(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    local_port: u16,
    bearer_token: []const u8,
    rpc_json: []const u8,
) connection.TransportError![]u8 {
    return gateway_transport.callAlloc(allocator, .{
        .local_port = local_port,
        .bearer_token = bearer_token,
        .rpc_json = rpc_json,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AuthenticationRequired => error.AuthenticationRequired,
        error.RequestTimedOut => error.RequestTimedOut,
        error.RedirectRejected,
        error.GatewayRejected,
        error.RequestTooLarge,
        error.ResponseTooLarge,
        error.EmptyRequest,
        error.InvalidPort,
        error.InvalidTimeout,
        error.WeakToken,
        error.TokenTooLong,
        error.InvalidTokenEncoding,
        => error.ProtocolRejected,
        else => error.NetworkUnavailable,
    };
}

fn inspectRpcResponse(
    allocator: std.mem.Allocator,
    kind: RpcTaskKind,
    request_id: u64,
    response_json: []const u8,
    expected_runtime_id: []const u8,
    expected_instance_id: []const u8,
) ?connection.FailureKind {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var client = headless.Client.initEncoder(arena.allocator());
    var parsed = client.parseResponseWithId(request_id, response_json) catch |err| {
        return classifyRpcInspectionError(err);
    };
    defer parsed.deinit();
    if (parsed.response.id == null) return .protocol;

    if (parsed.response.err) |remote_error| {
        if (std.mem.eql(u8, remote_error.code, headless.protocol.ERR_RUNTIME_IDENTITY_MISSING) or
            std.mem.eql(u8, remote_error.code, headless.protocol.ERR_RUNTIME_IDENTITY_MISMATCH))
        {
            return .identity;
        }
        return if (kind == .heartbeat) .protocol else null;
    }
    if (kind == .user) return null;

    const status = client.decodeStatus(&parsed) catch |err| {
        return classifyRpcInspectionError(err);
    };
    connection.validateRuntimeStatus(status) catch return .protocol;
    headless.verifyRuntimeHandshake(status, expected_runtime_id) catch return .identity;
    if (!std.mem.eql(u8, status.instance_id, expected_instance_id)) return .identity;
    if (!statusAdvertisesTargeting(status)) return .protocol;
    return null;
}

fn classifyRpcInspectionError(err: anyerror) connection.FailureKind {
    return switch (err) {
        error.OutOfMemory => .resource,
        error.RuntimeIdentityMissing, error.RuntimeIdentityMismatch => .identity,
        else => .protocol,
    };
}

fn mapTransportFailure(err: connection.TransportError) connection.FailureKind {
    return switch (err) {
        error.OutOfMemory => .resource,
        error.AuthenticationRequired => .authentication,
        error.NetworkUnavailable,
        error.RequestTimedOut,
        error.ConnectionClosed,
        => .network,
        error.ProtocolRejected => .protocol,
    };
}

fn statusAdvertisesTargeting(status: headless.StatusResult) bool {
    for (status.runtime_capabilities) |capability| {
        if (std.mem.eql(u8, capability, "rpc.target.v1")) return true;
    }
    return false;
}

fn runtimeAdvertisesTargeting(entry: *const Entry) bool {
    const metadata = entry.connection_state.metadata() orelse return false;
    for (metadata.runtime_capabilities) |capability| {
        if (std.mem.eql(u8, capability, "rpc.target.v1")) return true;
    }
    return false;
}

fn runtimeAdvertisesCapability(entry: *const Entry, expected: []const u8) bool {
    const metadata = entry.connection_state.metadata() orelse return false;
    for (metadata.runtime_capabilities) |capability| {
        if (std.mem.eql(u8, capability, expected)) return true;
    }
    return false;
}

fn verifiedRuntimeMatchesPin(entry: *const Entry) bool {
    const metadata = entry.connection_state.metadata() orelse return false;
    const runtime_id = entry.owned_profile.expected_runtime_id orelse return false;
    const instance_id = entry.owned_profile.expected_instance_id orelse return false;
    return std.mem.eql(u8, metadata.runtime_id, runtime_id) and
        std.mem.eql(u8, metadata.instance_id, instance_id);
}

fn heartbeatDue(entry: *const Entry, now_ms: u64) bool {
    if (entry.healthy_generation != entry.connection_state.generation) return true;
    return now_ms >= (entry.next_heartbeat_at_ms orelse 0);
}

fn profileEndpointsEqual(current: profile.Profile, next: profile.Profile) bool {
    return switch (current.transport) {
        .local_socket => next.transport == .local_socket,
        .ssh_tunnel => |a| switch (next.transport) {
            .local_socket => false,
            .ssh_tunnel => |b| std.mem.eql(u8, a.host, b.host) and
                a.port == b.port and
                a.remote_gateway_port == b.remote_gateway_port and
                ((a.user == null and b.user == null) or
                    (a.user != null and b.user != null and std.mem.eql(u8, a.user.?, b.user.?))),
        },
    };
}

fn clearHealth(entry: *Entry) void {
    entry.healthy_generation = null;
    entry.last_heartbeat_ms = null;
    entry.next_heartbeat_at_ms = null;
}

fn rpcGenerationIsCurrent(entry: *const Entry, generation: u64) bool {
    if (entry.connection_state.phase() != .ready or
        entry.connection_state.generation != generation or
        !entry.tunnel_owned or
        entry.tunnel_generation != generation)
    {
        return false;
    }
    return entry.supervisor.getSnapshot().lifecycle == .running;
}

fn entryExecutionReady(entry: *const Entry) bool {
    return entry.healthy_generation == entry.connection_state.generation and
        rpcGenerationIsCurrent(entry, entry.connection_state.generation) and
        entry.owned_profile.expected_runtime_id != null and
        entry.owned_profile.expected_instance_id != null and
        runtimeAdvertisesTargeting(entry);
}

fn validateRpcMethod(method: []const u8) !void {
    if (method.len == 0 or method.len > MAX_RPC_METHOD_BYTES) return error.InvalidRuntimeRpcMethod;
    for (method) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidRuntimeRpcMethod;
        }
    }
}

fn snapshotEntry(entry: *const Entry) Snapshot {
    const tunnel = if (entry.tunnel_owned)
        entry.supervisor.getSnapshot()
    else
        tunnel_supervisor.Snapshot{ .lifecycle = .stopped };
    const pending_metadata = entry.connection_state.pendingTrustMetadata();
    const metadata = entry.connection_state.metadata() orelse pending_metadata;
    return .{
        .profile_id = entry.owned_profile.id,
        .label = entry.owned_profile.label,
        .transport = switch (entry.owned_profile.transport) {
            .local_socket => .local_socket,
            .ssh_tunnel => .ssh_tunnel,
        },
        .phase = entry.connection_state.phase(),
        .failure = entry.failure_override orelse if (entry.connection_state.lastFailure()) |failure|
            mapConnectionFailure(failure)
        else
            null,
        .retry_at_ms = switch (entry.connection_state.state) {
            .reconnecting => |retry_state| retry_state.retry_at_ms,
            else => null,
        },
        .local_port = entry.local_port,
        .tunnel_lifecycle = tunnel.lifecycle,
        .tunnel_pid = tunnel.pid,
        .runtime = if (metadata) |runtime| .{
            .runtime_id = runtime.runtime_id,
            .instance_id = runtime.instance_id,
            .server_version = runtime.server_version,
            .protocol_major = runtime.runtime_protocol.major,
            .protocol_minor = runtime.runtime_protocol.minor,
            .negotiated_headless_protocol_version = runtime.negotiated_headless_protocol_version,
        } else null,
        .identity_pin_required = pending_metadata != null,
        .rpc_in_flight = entry.rpc_task != null,
        .last_heartbeat_ms = entry.last_heartbeat_ms,
        .verified_runtime_matches_pin = verifiedRuntimeMatchesPin(entry),
        .repository_manifest_capable = runtimeAdvertisesCapability(entry, REPOSITORY_MANIFEST_CAPABILITY),
        .repository_chat_route_capable = runtimeAdvertisesCapability(entry, REPOSITORY_CHAT_ROUTE_CAPABILITY),
        .execution_ready = entryExecutionReady(entry),
    };
}

fn mapConnectionFailure(failure: connection.FailureKind) Failure {
    return switch (failure) {
        .authentication => .authentication,
        .network => .network,
        .identity => .identity,
        .protocol => .protocol,
        .resource => .resource,
    };
}

fn mapTunnelFailure(snapshot: tunnel_supervisor.Snapshot) Failure {
    return switch (snapshot.lifecycle) {
        .failed => switch (snapshot.failure orelse .wait) {
            .spawn => .tunnel_spawn,
            .readiness => .tunnel_readiness,
            .wait => .tunnel_wait,
        },
        .stopped, .exited => .tunnel_exited,
        .starting, .running, .stopping => unreachable,
    };
}

fn tunnelConnectionFailure(snapshot: tunnel_supervisor.Snapshot) connection.FailureKind {
    return switch (snapshot.lifecycle) {
        .failed => switch (snapshot.failure orelse .wait) {
            .spawn, .readiness => .resource,
            .wait => .network,
        },
        .stopped, .exited => .network,
        .starting, .running, .stopping => unreachable,
    };
}

fn reconnectJitter(entry: *const Entry, generation: u64) u32 {
    const hash = std.hash.Wyhash.hash(generation, entry.owned_profile.id);
    return @intCast(hash % (connection.RECONNECT_MAX_JITTER_MS + 1));
}

fn cloneProfile(allocator: std.mem.Allocator, source: profile.Profile) !profile.Profile {
    const id = try allocator.dupe(u8, source.id);
    errdefer allocator.free(id);
    const label = try allocator.dupe(u8, source.label);
    errdefer allocator.free(label);
    const expected_runtime_id = if (source.expected_runtime_id) |runtime_id|
        try allocator.dupe(u8, runtime_id)
    else
        null;
    errdefer if (expected_runtime_id) |runtime_id| allocator.free(runtime_id);
    const expected_instance_id = if (source.expected_instance_id) |instance_id|
        try allocator.dupe(u8, instance_id)
    else
        null;
    errdefer if (expected_instance_id) |instance_id| allocator.free(instance_id);
    const transport: profile.Transport = switch (source.transport) {
        .local_socket => .local_socket,
        .ssh_tunnel => |ssh| blk: {
            const host = try allocator.dupe(u8, ssh.host);
            errdefer allocator.free(host);
            const user = if (ssh.user) |value| try allocator.dupe(u8, value) else null;
            errdefer if (user) |value| allocator.free(value);
            break :blk .{ .ssh_tunnel = .{
                .host = host,
                .user = user,
                .port = ssh.port,
                .remote_gateway_port = ssh.remote_gateway_port,
            } };
        },
    };
    return .{
        .id = id,
        .label = label,
        .expected_runtime_id = expected_runtime_id,
        .expected_instance_id = expected_instance_id,
        .transport = transport,
    };
}

fn eraseAndFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

const TEST_TOKEN_A = "0123456789abcdef0123456789abcdef";
const TEST_TOKEN_B = "fedcba9876543210fedcba9876543210";
const TEST_RUNTIME_A = "0123456789abcdef0123456789abcdef";
const TEST_RUNTIME_B = "fedcba9876543210fedcba9876543210";
const TEST_INSTANCE = "00112233445566778899aabbccddeeff";

const TestPorts = struct {
    values: []const u16,
    index: usize = 0,
    calls: usize = 0,

    fn select(raw_context: ?*anyopaque, _: std.Io) anyerror!u16 {
        const self: *TestPorts = @ptrCast(@alignCast(raw_context.?));
        self.calls += 1;
        if (self.values.len == 0) return error.NoTestPort;
        const result = self.values[@min(self.index, self.values.len - 1)];
        if (self.index < self.values.len - 1) self.index += 1;
        return result;
    }
};

const TestTunnel = struct {
    allow_ready: std.atomic.Value(bool) = .init(false),
    force_exit: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(usize) = .init(0),
    stopped: std.atomic.Value(usize) = .init(0),
    retained: std.atomic.Value(usize) = .init(0),

    fn retain(raw_context: ?*anyopaque) void {
        const self: *TestTunnel = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchAdd(1, .acq_rel);
    }

    fn release(raw_context: ?*anyopaque) void {
        const self: *TestTunnel = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchSub(1, .acq_rel);
    }

    fn run(
        raw_context: ?*anyopaque,
        io: std.Io,
        _: []const []const u8,
        _: u16,
        control: tunnel_supervisor.Control,
    ) tunnel_supervisor.Outcome {
        const self: *TestTunnel = @ptrCast(@alignCast(raw_context.?));
        const ordinal = self.started.fetchAdd(1, .acq_rel);
        control.markSpawned(@intCast(10_000 + ordinal));
        while (!self.allow_ready.load(.acquire)) {
            if (control.stopRequested()) {
                _ = self.stopped.fetchAdd(1, .acq_rel);
                return .stopped;
            }
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        }
        control.markForwardReady(@intCast(10_000 + ordinal));
        while (!control.stopRequested()) {
            if (self.force_exit.load(.acquire)) return .{ .exited = .{ .exited = 255 } };
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        }
        _ = self.stopped.fetchAdd(1, .acq_rel);
        return .stopped;
    }

    fn backend(self: *TestTunnel) tunnel_supervisor.Backend {
        return .{
            .context = self,
            .run = run,
            .retain_context = retain,
            .release_context = release,
        };
    }
};

const TestRpc = struct {
    runtime_a: []const u8 = TEST_RUNTIME_A,
    runtime_b: []const u8 = TEST_RUNTIME_B,
    expected_token: []const u8 = TEST_TOKEN_A,
    allow_return: std.atomic.Value(bool) = .init(true),
    calls: std.atomic.Value(usize) = .init(0),
    retained: std.atomic.Value(usize) = .init(0),
    valid_request: std.atomic.Value(bool) = .init(true),

    fn retain(raw_context: ?*anyopaque) void {
        const self: *TestRpc = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchAdd(1, .acq_rel);
    }

    fn release(raw_context: ?*anyopaque) void {
        const self: *TestRpc = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchSub(1, .acq_rel);
    }

    fn call(
        raw_context: ?*anyopaque,
        allocator: std.mem.Allocator,
        local_port: u16,
        bearer_token: []const u8,
        rpc_json: []const u8,
    ) connection.TransportError![]u8 {
        const self: *TestRpc = @ptrCast(@alignCast(raw_context.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        if (!std.mem.eql(u8, bearer_token, self.expected_token)) {
            self.valid_request.store(false, .release);
        }
        var parsed = headless.protocol.parseRequest(allocator, rpc_json) catch {
            self.valid_request.store(false, .release);
            return error.ProtocolRejected;
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.request.method, "core.status")) {
            self.valid_request.store(false, .release);
        }
        while (!self.allow_return.load(.acquire)) std.atomic.spinLoopHint();

        const runtime_id = if (local_port == 43_127) self.runtime_a else self.runtime_b;
        if (parsed.request.target) |target| {
            if (!std.mem.eql(u8, target.runtime_id, runtime_id) or
                !std.mem.eql(u8, target.instance_id, TEST_INSTANCE))
            {
                self.valid_request.store(false, .release);
            }
        }
        return headless.encodeOkResponse(allocator, parsed.request.id, testStatus(runtime_id)) catch
            return error.OutOfMemory;
    }

    fn backend(self: *TestRpc) RpcBackend {
        return .{
            .context = self,
            .call = call,
            .retain_context = retain,
            .release_context = release,
        };
    }
};

const TargetRpcMode = enum(u8) {
    normal,
    method_error,
    identity_mismatch,
    network_failure,
};

/// Hermetic daemon seam for proving that every post-handshake exchange carries
/// the manager-owned durable target pair. Modes affect targeted calls only, so
/// the initial untargeted identity handshake can establish the connection.
const TargetRpc = struct {
    expected_token: []const u8 = TEST_TOKEN_A,
    mode: std.atomic.Value(u8) = .init(@intFromEnum(TargetRpcMode.normal)),
    allow_general_return: std.atomic.Value(bool) = .init(true),
    advertise_targeting: bool = true,
    calls: std.atomic.Value(usize) = .init(0),
    targeted_heartbeats: std.atomic.Value(usize) = .init(0),
    targeted_general: std.atomic.Value(usize) = .init(0),
    retained: std.atomic.Value(usize) = .init(0),
    valid_targets: std.atomic.Value(bool) = .init(true),

    fn setMode(self: *TargetRpc, mode: TargetRpcMode) void {
        self.mode.store(@intFromEnum(mode), .release);
    }

    fn retain(raw_context: ?*anyopaque) void {
        const self: *TargetRpc = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchAdd(1, .acq_rel);
    }

    fn release(raw_context: ?*anyopaque) void {
        const self: *TargetRpc = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchSub(1, .acq_rel);
    }

    fn call(
        raw_context: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: u16,
        bearer_token: []const u8,
        rpc_json: []const u8,
    ) connection.TransportError![]u8 {
        const self: *TargetRpc = @ptrCast(@alignCast(raw_context.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        if (!std.mem.eql(u8, bearer_token, self.expected_token)) {
            self.valid_targets.store(false, .release);
        }

        var parsed = headless.protocol.parseRequest(allocator, rpc_json) catch {
            self.valid_targets.store(false, .release);
            return error.ProtocolRejected;
        };
        defer parsed.deinit();
        const is_status = std.mem.eql(u8, parsed.request.method, "core.status");
        const is_targeted = parsed.request.target != null;
        if (is_targeted) {
            const target = parsed.request.target.?;
            if (!std.mem.eql(u8, target.runtime_id, TEST_RUNTIME_A) or
                !std.mem.eql(u8, target.instance_id, TEST_INSTANCE))
            {
                self.valid_targets.store(false, .release);
            }
            if (is_status) {
                _ = self.targeted_heartbeats.fetchAdd(1, .acq_rel);
            } else {
                _ = self.targeted_general.fetchAdd(1, .acq_rel);
            }
        } else if (!is_status) {
            self.valid_targets.store(false, .release);
        }

        const mode: TargetRpcMode = @enumFromInt(self.mode.load(.acquire));
        if (is_targeted and mode == .network_failure) return error.NetworkUnavailable;
        if (!is_status) {
            while (!self.allow_general_return.load(.acquire)) std.atomic.spinLoopHint();
            return switch (mode) {
                .method_error => headless.encodeErrorResponse(
                    allocator,
                    parsed.request.id,
                    headless.protocol.ERR_INVALID_PARAMS,
                    "test method error",
                ) catch error.OutOfMemory,
                .identity_mismatch => headless.encodeErrorResponse(
                    allocator,
                    parsed.request.id,
                    headless.protocol.ERR_RUNTIME_IDENTITY_MISMATCH,
                    "runtime replaced",
                ) catch error.OutOfMemory,
                .normal, .network_failure => headless.encodeOkResponse(
                    allocator,
                    parsed.request.id,
                    .{ .ok = true },
                ) catch error.OutOfMemory,
            };
        }

        var status = testStatus(TEST_RUNTIME_A);
        if (!self.advertise_targeting) {
            status.runtime_capabilities = &.{"core.snapshot.v1"};
        }
        return headless.encodeOkResponse(allocator, parsed.request.id, status) catch
            return error.OutOfMemory;
    }

    fn backend(self: *TargetRpc) RpcBackend {
        return .{
            .context = self,
            .call = call,
            .retain_context = retain,
            .release_context = release,
        };
    }
};

fn testStatus(runtime_id: []const u8) headless.StatusResult {
    return .{
        .runtime_id = runtime_id,
        .instance_id = TEST_INSTANCE,
        .server_version = "1.2.3",
        .protocol = .{ .major = headless.protocol.RUNTIME_PROTOCOL_MAJOR, .minor = 4 },
        .runtime_capabilities = &.{ "rpc.target.v1", "core.snapshot.v1", "providers.status.v1" },
        .limits = .{
            .max_request_bytes = 65_536,
            .max_response_bytes = 131_072,
            .max_attachment_bytes = 1_048_576,
            .max_parked_wait_ms = 9_000,
            .default_page_items = 25,
            .max_page_items = 75,
        },
        .headless_protocol_version = headless.HEADLESS_PROTOCOL_VERSION,
        .min_supported = headless.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = headless.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 26,
        .pid = 42,
        .session_count = 2,
        .chat_turn_count = 3,
        .capabilities = headless.Capabilities.phase1(),
    };
}

fn createTestProfile(label: []const u8) !profile.Profile {
    return profile.Profile.createSshTunnel(
        std.testing.allocator,
        std.testing.io,
        label,
        null,
        .{ .host = "runtime.example", .user = "verde" },
    );
}

fn createPinnedTestProfile(label: []const u8) !profile.Profile {
    var configured = try createTestProfile(label);
    errdefer configured.deinit(std.testing.allocator);
    try configured.setExpectedIdentity(std.testing.allocator, TEST_RUNTIME_A, TEST_INSTANCE);
    return configured;
}

fn waitForManagerPhase(
    manager: *Manager,
    profile_id: []const u8,
    expected: connection.Phase,
) !void {
    for (0..2_000) |iteration| {
        try manager.poll(1_000 + iteration);
        if (manager.snapshot(profile_id).?.phase == expected) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedManagerPhase;
}

fn waitForManagerCleanup(manager: *Manager, profile_id: []const u8) !void {
    for (0..2_000) |iteration| {
        try manager.poll(10_000 + iteration);
        const current = manager.snapshot(profile_id).?;
        if (current.local_port == null and current.tunnel_lifecycle == .stopped) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedManagerCleanup;
}

fn waitForExecutionReady(manager: *Manager, profile_id: []const u8, start_ms: u64) !void {
    for (0..2_000) |iteration| {
        try manager.poll(start_ms + iteration);
        if (manager.snapshot(profile_id).?.execution_ready) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedExecutionReady;
}

fn waitForRpcResult(
    manager: *Manager,
    ticket: RpcTicket,
    start_ms: u64,
) !RpcCallResult {
    for (0..2_000) |iteration| {
        try manager.poll(start_ms + iteration);
        if (try manager.takeRpcResult(ticket)) |result| return result;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedRpcResult;
}

test "manager gates auth on readiness and first contact on durable trust" {
    var configured = try createTestProfile("Build VM");
    defer configured.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    var rpc: TestRpc = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    try manager.enable(configured.id, 0);

    // Spawn/liveness alone never releases a bearer token to loopback.
    for (0..50) |iteration| {
        try manager.poll(iteration);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(connection.Phase.connecting, manager.snapshot(configured.id).?.phase);
    try std.testing.expectEqual(@as(usize, 0), rpc.calls.load(.acquire));

    tunnel.allow_ready.store(true, .release);
    try waitForManagerPhase(&manager, configured.id, .awaiting_trust);
    const pending = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(@as(usize, 1), rpc.calls.load(.acquire));
    try std.testing.expect(rpc.valid_request.load(.acquire));
    try std.testing.expect(pending.runtime != null);
    try std.testing.expectEqualStrings(TEST_RUNTIME_A, pending.runtime.?.runtime_id);
    try std.testing.expect(pending.identity_pin_required);
    try std.testing.expect(!pending.execution_ready);
    var proposal = (try manager.runtimePinProposalAlloc(
        std.testing.allocator,
        configured.id,
    )).?;
    defer proposal.deinit();
    try std.testing.expectEqualStrings(configured.id, proposal.profile_id);
    try std.testing.expectEqualStrings(TEST_RUNTIME_A, proposal.runtime_id);
    try std.testing.expectEqualStrings(TEST_INSTANCE, proposal.instance_id);
    try std.testing.expect(manager.expectedRuntimeId(configured.id) == null);
    try std.testing.expect(manager.expectedInstanceId(configured.id) == null);

    // The authoritative profile is saved first; only then may the manager make
    // this verified connection ready in memory.
    try configured.setExpectedIdentity(std.testing.allocator, TEST_RUNTIME_A, TEST_INSTANCE);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const store_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ path_buffer[0..path_len], profile_store.FILE_NAME },
    );
    defer std.testing.allocator.free(store_path);
    try profile_store.saveAtPath(
        std.testing.allocator,
        std.testing.io,
        store_path,
        &.{configured},
    );
    try std.testing.expectEqual(
        PinAdoption.committed_current,
        try manager.acknowledgePersistedRuntimePin(&proposal, .{
            .runtime_id = TEST_RUNTIME_A,
            .instance_id = TEST_INSTANCE,
        }),
    );
    const trusted = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.ready, trusted.phase);
    try std.testing.expect(!trusted.identity_pin_required);
    try std.testing.expect(!trusted.execution_ready);
    try waitForExecutionReady(&manager, configured.id, 10_000);
    try std.testing.expectEqual(@as(usize, 2), rpc.calls.load(.acquire));
    try std.testing.expect(rpc.valid_request.load(.acquire));

    // Rotation invalidates the old-token generation and tunnel before the new
    // token can be used by a fresh attempt.
    try manager.hydrateToken(configured.id, TEST_TOKEN_B);
    try std.testing.expectEqual(connection.Phase.disabled, manager.snapshot(configured.id).?.phase);
    try waitForManagerCleanup(&manager, configured.id);
    rpc.expected_token = TEST_TOKEN_B;
    try manager.enable(configured.id, 20_000);
    try waitForManagerPhase(&manager, configured.id, .ready);
    try waitForExecutionReady(&manager, configured.id, 30_000);
    try std.testing.expectEqual(@as(usize, 4), rpc.calls.load(.acquire));
    try std.testing.expect(rpc.valid_request.load(.acquire));

    try std.testing.expect(try manager.clearToken(configured.id));
    try std.testing.expectEqual(connection.Phase.disabled, manager.snapshot(configured.id).?.phase);
    try waitForManagerCleanup(&manager, configured.id);
    try std.testing.expect(!(try manager.clearToken(configured.id)));
    try std.testing.expectEqual(@as(usize, 0), rpc.retained.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), tunnel.retained.load(.acquire));
}

test "targeted RPC preserves method errors and rejects replacement before mutation" {
    var configured = try createPinnedTestProfile("Pinned VM");
    defer configured.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TargetRpc = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    try manager.enable(configured.id, 0);
    try waitForExecutionReady(&manager, configured.id, 5_000);
    try std.testing.expectEqual(@as(usize, 1), rpc.targeted_heartbeats.load(.acquire));
    try std.testing.expect(rpc.valid_targets.load(.acquire));

    try std.testing.expectError(
        error.InvalidRuntimeRpcMethod,
        manager.beginRpc(configured.id, "core snapshot", .{}),
    );
    rpc.setMode(.method_error);
    const method_ticket = try manager.beginRpc(configured.id, "core.snapshot", .{
        // A same-named params field cannot override the top-level durable pair.
        .target = .{ .runtime_id = TEST_RUNTIME_B, .instance_id = TEST_RUNTIME_B },
    });
    var method_result = try waitForRpcResult(&manager, method_ticket, 10_000);
    defer method_result.deinit();
    switch (method_result) {
        .response => |response| {
            var client = headless.Client.initEncoder(std.testing.allocator);
            var parsed = try client.parseResponseWithId(method_ticket.id, response.json);
            defer parsed.deinit();
            try std.testing.expectEqualStrings(
                headless.protocol.ERR_INVALID_PARAMS,
                parsed.response.err.?.code,
            );
        },
        .failed, .canceled => return error.TestExpectedMethodErrorResponse,
    }
    try std.testing.expect(manager.snapshot(configured.id).?.execution_ready);
    try std.testing.expectEqual(@as(usize, 1), rpc.targeted_general.load(.acquire));
    try std.testing.expect(rpc.valid_targets.load(.acquire));

    // The daemon changes after the heartbeat. Its same-dispatch target check
    // rejects the next mutation before the method can execute.
    rpc.setMode(.identity_mismatch);
    const replaced_ticket = try manager.beginRpc(configured.id, "core.snapshot", .{});
    var replaced_result = try waitForRpcResult(&manager, replaced_ticket, 12_000);
    defer replaced_result.deinit();
    switch (replaced_result) {
        .failed => |failure| try std.testing.expectEqual(Failure.identity, failure),
        .response, .canceled => return error.TestExpectedIdentityFailure,
    }
    const replaced = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.failed, replaced.phase);
    try std.testing.expectEqual(Failure.identity, replaced.failure.?);
    try std.testing.expect(!replaced.execution_ready);
    try std.testing.expectEqual(@as(usize, 2), rpc.targeted_general.load(.acquire));
    try std.testing.expect(rpc.valid_targets.load(.acquire));
    try waitForManagerCleanup(&manager, configured.id);
}

test "targeted heartbeat network failure retries and restores health" {
    var configured = try createPinnedTestProfile("Heartbeat VM");
    defer configured.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TargetRpc = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    try manager.enable(configured.id, 0);
    try waitForExecutionReady(&manager, configured.id, 5_000);

    const first_heartbeat_ms = manager.snapshot(configured.id).?.last_heartbeat_ms.?;
    const due_ms = first_heartbeat_ms + HEARTBEAT_INTERVAL_MS;
    rpc.setMode(.network_failure);
    try manager.poll(due_ms);
    for (0..2_000) |iteration| {
        try manager.poll(due_ms + iteration);
        if (manager.snapshot(configured.id).?.phase == .reconnecting) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestExpectedHeartbeatReconnect;

    const disconnected = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(Failure.network, disconnected.failure.?);
    try std.testing.expect(disconnected.retry_at_ms != null);
    try std.testing.expect(!disconnected.execution_ready);
    try std.testing.expectEqual(@as(usize, 2), rpc.targeted_heartbeats.load(.acquire));

    rpc.setMode(.normal);
    try waitForExecutionReady(&manager, configured.id, disconnected.retry_at_ms.?);
    try std.testing.expectEqual(connection.Phase.ready, manager.snapshot(configured.id).?.phase);
    try std.testing.expectEqual(@as(usize, 3), rpc.targeted_heartbeats.load(.acquire));
    try std.testing.expect(rpc.valid_targets.load(.acquire));
}

test "runtime without targeted RPC capability never becomes execution ready" {
    var configured = try createPinnedTestProfile("Legacy VM");
    defer configured.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TargetRpc = .{ .advertise_targeting = false };
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    try manager.enable(configured.id, 0);
    try waitForManagerPhase(&manager, configured.id, .failed);

    const failed = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(Failure.protocol, failed.failure.?);
    try std.testing.expect(!failed.execution_ready);
    try std.testing.expectEqual(@as(usize, 0), rpc.targeted_heartbeats.load(.acquire));
    try std.testing.expectError(
        error.RuntimeNotExecutionReady,
        manager.beginRpc(configured.id, "core.snapshot", .{}),
    );
    try waitForManagerCleanup(&manager, configured.id);
}

test "clearing a token contains an in-flight targeted RPC" {
    var configured = try createPinnedTestProfile("Revoked RPC VM");
    defer configured.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TargetRpc = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    try manager.enable(configured.id, 0);
    try waitForExecutionReady(&manager, configured.id, 5_000);

    rpc.allow_general_return.store(false, .release);
    const ticket = try manager.beginRpc(configured.id, "core.snapshot", .{});
    for (0..2_000) |iteration| {
        try manager.poll(10_000 + iteration);
        if (rpc.targeted_general.load(.acquire) == 1) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestExpectedBlockedRpc;

    try std.testing.expect(try manager.clearToken(configured.id));
    const revoked = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.disabled, revoked.phase);
    try std.testing.expect(!revoked.execution_ready);
    // The internal reservation survives until the bearer-bearing worker ends.
    try std.testing.expectEqual(@as(?u16, 43_127), revoked.local_port);

    rpc.allow_general_return.store(true, .release);
    var result = try waitForRpcResult(&manager, ticket, 12_000);
    defer result.deinit();
    switch (result) {
        .canceled => {},
        .response, .failed => return error.TestExpectedCanceledRpc,
    }
    try waitForManagerCleanup(&manager, configured.id);
    try std.testing.expectEqual(@as(usize, 0), rpc.retained.load(.acquire));
    try std.testing.expect(rpc.valid_targets.load(.acquire));
}

test "manager owns multiple profiles and bounds duplicate port retries" {
    var first = try createTestProfile("First VM");
    defer first.deinit(std.testing.allocator);
    var second = try createTestProfile("Second VM");
    defer second.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{ 43_127, 43_127 } };
    var tunnel: TestTunnel = .{};
    var rpc: TestRpc = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{ first, second }, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(first.id, TEST_TOKEN_A);
    try manager.hydrateToken(second.id, TEST_TOKEN_A);
    try manager.enable(first.id, 0);
    try std.testing.expectError(error.NoLoopbackPortAvailable, manager.enable(second.id, 0));
    try std.testing.expectEqual(@as(usize, 1 + MAX_PORT_SELECTION_ATTEMPTS), ports.calls);
    const second_snapshot = manager.snapshot(second.id).?;
    try std.testing.expectEqual(connection.Phase.failed, second_snapshot.phase);
    try std.testing.expectEqual(Failure.no_loopback_port, second_snapshot.failure.?);
    try std.testing.expectEqual(@as(?u16, 43_127), manager.snapshot(first.id).?.local_port);
    try manager.disable(first.id);
    try waitForManagerCleanup(&manager, first.id);
}

test "manager advances multiple profile connections concurrently" {
    var first = try createTestProfile("First VM");
    defer first.deinit(std.testing.allocator);
    var second = try createTestProfile("Second VM");
    defer second.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{ 43_127, 43_128 } };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TestRpc = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{ first, second }, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(first.id, TEST_TOKEN_A);
    try manager.hydrateToken(second.id, TEST_TOKEN_A);
    try manager.enable(first.id, 0);
    try manager.enable(second.id, 0);
    try waitForManagerPhase(&manager, first.id, .awaiting_trust);
    try waitForManagerPhase(&manager, second.id, .awaiting_trust);

    const first_snapshot = manager.snapshot(first.id).?;
    const second_snapshot = manager.snapshot(second.id).?;
    try std.testing.expectEqual(@as(?u16, 43_127), first_snapshot.local_port);
    try std.testing.expectEqual(@as(?u16, 43_128), second_snapshot.local_port);
    try std.testing.expectEqualStrings(TEST_RUNTIME_A, first_snapshot.runtime.?.runtime_id);
    try std.testing.expectEqualStrings(TEST_RUNTIME_B, second_snapshot.runtime.?.runtime_id);
    try std.testing.expectEqual(@as(usize, 2), rpc.calls.load(.acquire));

    try manager.disable(first.id);
    try manager.disable(second.id);
    try waitForManagerCleanup(&manager, first.id);
    try waitForManagerCleanup(&manager, second.id);
}

test "invalid runtime identity never becomes pending or ready" {
    var configured = try createTestProfile("Invalid VM");
    defer configured.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TestRpc = .{ .runtime_a = "runtime-alpha" };
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    try manager.enable(configured.id, 0);
    try waitForManagerPhase(&manager, configured.id, .failed);
    const failed = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(Failure.identity, failed.failure.?);
    try std.testing.expect(failed.runtime == null);
    try std.testing.expect(!failed.identity_pin_required);
    try std.testing.expect(!failed.execution_ready);
    try std.testing.expect((try manager.runtimePinProposalAlloc(
        std.testing.allocator,
        configured.id,
    )) == null);
    try waitForManagerCleanup(&manager, configured.id);

    rpc.runtime_a = TEST_RUNTIME_A;
    try manager.retry(configured.id, 10_000);
    try waitForManagerPhase(&manager, configured.id, .awaiting_trust);
    try std.testing.expectEqual(@as(usize, 2), rpc.calls.load(.acquire));
    try manager.disable(configured.id);
    try waitForManagerCleanup(&manager, configured.id);
}

test "manager rejects detachable RPC contexts without ownership hooks" {
    var rpc: TestRpc = .{};
    try std.testing.expectError(
        error.UnsafeRpcBackendLifetime,
        Manager.init(std.testing.allocator, std.testing.io, &.{}, .{
            .rpc_backend = .{ .context = &rpc, .call = TestRpc.call },
        }),
    );
}

test "manager deinit hands a blocked handshake to owned process cleanup" {
    var configured = try createTestProfile("Blocked VM");
    defer configured.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TestRpc = .{};
    rpc.allow_return.store(false, .release);
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    try manager.enable(configured.id, 0);
    for (0..2_000) |iteration| {
        try manager.poll(iteration);
        if (rpc.calls.load(.acquire) == 1) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 1), rpc.calls.load(.acquire));
    try std.testing.expectEqual(connection.Phase.handshaking, manager.snapshot(configured.id).?.phase);

    // The callback is still blocked when deinit returns, proving no owner-thread
    // join. Its retained context and page-allocated task remain valid.
    manager.deinit();
    try std.testing.expectEqual(@as(usize, 1), rpc.retained.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), tunnel.retained.load(.acquire));
    rpc.allow_return.store(true, .release);
    for (0..2_000) |_| {
        if (rpc.retained.load(.acquire) == 0 and tunnel.retained.load(.acquire) == 0) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), rpc.retained.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), tunnel.retained.load(.acquire));
}

test "clearing a token makes an in-flight handshake permanently stale" {
    var configured = try createTestProfile("Revoked VM");
    defer configured.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TestRpc = .{};
    rpc.allow_return.store(false, .release);
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    try manager.enable(configured.id, 0);
    for (0..2_000) |iteration| {
        try manager.poll(iteration);
        if (rpc.calls.load(.acquire) == 1) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(connection.Phase.handshaking, manager.snapshot(configured.id).?.phase);

    try std.testing.expect(try manager.clearToken(configured.id));
    try std.testing.expectEqual(connection.Phase.disabled, manager.snapshot(configured.id).?.phase);
    rpc.allow_return.store(true, .release);
    for (0..2_000) |iteration| {
        try manager.poll(10_000 + iteration);
        if (rpc.retained.load(.acquire) == 0 and
            manager.snapshot(configured.id).?.local_port == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    const revoked = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.disabled, revoked.phase);
    try std.testing.expect(revoked.runtime == null);
    try std.testing.expect(!revoked.identity_pin_required);
    try std.testing.expectEqual(@as(usize, 0), rpc.retained.load(.acquire));
}

test "stale bearer worker keeps its port reserved across profiles" {
    var first = try createTestProfile("Revoked VM");
    defer first.deinit(std.testing.allocator);
    var second = try createTestProfile("Other VM");
    defer second.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{43_127} };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TestRpc = .{};
    rpc.allow_return.store(false, .release);
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{ first, second }, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(first.id, TEST_TOKEN_A);
    try manager.hydrateToken(second.id, TEST_TOKEN_A);
    try manager.enable(first.id, 0);
    for (0..2_000) |iteration| {
        try manager.poll(iteration);
        if (rpc.calls.load(.acquire) == 1) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(connection.Phase.handshaking, manager.snapshot(first.id).?.phase);

    _ = try manager.clearToken(first.id);
    try std.testing.expectError(error.NoLoopbackPortAvailable, manager.enable(second.id, 1_000));
    try std.testing.expectEqual(@as(?u16, 43_127), manager.snapshot(first.id).?.local_port);
    try std.testing.expectEqual(Failure.no_loopback_port, manager.snapshot(second.id).?.failure.?);

    rpc.allow_return.store(true, .release);
    try waitForManagerCleanup(&manager, first.id);
    try manager.disable(second.id);
}

test "SSH exit between proposal and save reconnects against the durable identity pair" {
    var configured = try createTestProfile("Ephemeral VM");
    defer configured.deinit(std.testing.allocator);
    var ports: TestPorts = .{ .values = &.{ 43_127, 43_128 } };
    var tunnel: TestTunnel = .{};
    tunnel.allow_ready.store(true, .release);
    var rpc: TestRpc = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .port_selector = .{ .context = &ports, .select = TestPorts.select },
        .tunnel_backend = tunnel.backend(),
        .rpc_backend = rpc.backend(),
    });
    defer manager.deinit();
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    try manager.enable(configured.id, 0);
    try waitForManagerPhase(&manager, configured.id, .awaiting_trust);
    var proposal = (try manager.runtimePinProposalAlloc(
        std.testing.allocator,
        configured.id,
    )).?;
    defer proposal.deinit();

    tunnel.force_exit.store(true, .release);
    for (0..2_000) |_| {
        if (manager.snapshot(configured.id).?.tunnel_lifecycle == .exited) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestTunnelDidNotExit;

    try configured.setExpectedIdentity(std.testing.allocator, TEST_RUNTIME_A, TEST_INSTANCE);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const store_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ path_buffer[0..path_len], profile_store.FILE_NAME },
    );
    defer std.testing.allocator.free(store_path);
    try profile_store.saveAtPath(
        std.testing.allocator,
        std.testing.io,
        store_path,
        &.{configured},
    );

    try std.testing.expectEqual(
        PinAdoption.reconnect_required,
        try manager.acknowledgePersistedRuntimePin(&proposal, .{
            .runtime_id = TEST_RUNTIME_A,
            .instance_id = TEST_INSTANCE,
        }),
    );
    try std.testing.expectEqual(connection.Phase.connecting, manager.snapshot(configured.id).?.phase);
    try std.testing.expectEqualStrings(TEST_RUNTIME_A, manager.expectedRuntimeId(configured.id).?);
    try std.testing.expectEqualStrings(TEST_INSTANCE, manager.expectedInstanceId(configured.id).?);
    try std.testing.expect(!manager.snapshot(configured.id).?.execution_ready);
    try manager.disable(configured.id);
}

fn checkManagerAllocationFailures(allocator: std.mem.Allocator) !void {
    var configured = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Allocation VM",
        TEST_RUNTIME_A,
        .{ .host = "runtime.example", .user = "verde" },
    );
    defer configured.deinit(allocator);
    var manager = try Manager.init(allocator, std.testing.io, &.{configured}, .{});
    defer manager.deinit();
    try manager.hydrateToken(configured.id, TEST_TOKEN_A);
    const snapshots = try manager.snapshotsAlloc(allocator);
    defer allocator.free(snapshots);
    try std.testing.expectEqual(@as(usize, 1), snapshots.len);
}

test "manager-owned profiles secrets and snapshots clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkManagerAllocationFailures,
        .{},
    );
}
