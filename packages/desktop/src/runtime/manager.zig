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
const pair_client = @import("pair_client.zig");
const profile = @import("profile.zig");
const profile_store = @import("profile_store.zig");
const secret_store = @import("secret_store.zig");
const tunnel_supervisor = @import("ssh_tunnel_supervisor.zig");

const access_protocol = headless.access_protocol;

pub const MAX_PORT_SELECTION_ATTEMPTS: usize = 8;
pub const HEARTBEAT_INTERVAL_MS: u64 = 15_000;
pub const MAX_RPC_METHOD_BYTES: usize = 128;
pub const REPOSITORY_MANIFEST_CAPABILITY: []const u8 = "repositories.manifest.v1";
pub const REPOSITORY_CHAT_ROUTE_CAPABILITY: []const u8 = "chat.repository_route.v1";
pub const CHAT_ATTACHMENT_CAPABILITY: []const u8 = headless.attachment_protocol.CHAT_ATTACHMENT_CAPABILITY;
/// Paired-device access tokens are re-minted this long before they expire so
/// a heartbeat never races an expiry.
pub const ACCESS_TOKEN_REFRESH_MARGIN_MS: u64 = 60_000;
pub const ACCESS_TOKEN_MIN_REFRESH_DELAY_MS: u64 = 5_000;
/// Suffix for the process-memory slot holding a paired device credential.
pub const DEVICE_SECRET_SUFFIX: []const u8 = ".device";

pub const TransportKind = enum {
    local_socket,
    ssh_tunnel,
    direct_https,
    connect,
};

/// Prepared request target. Direct and Connect calls intentionally share the
/// same authenticated operations; only endpoint resolution differs.
pub const TransportTarget = union(enum) {
    loopback: u16,
    direct_https: []const u8,
};

const OwnedTransportTarget = union(enum) {
    loopback: u16,
    direct_https: []u8,

    fn clone(allocator: std.mem.Allocator, target: TransportTarget) !OwnedTransportTarget {
        return switch (target) {
            .loopback => |port| .{ .loopback = port },
            .direct_https => |url| .{ .direct_https = try allocator.dupe(u8, url) },
        };
    }

    fn borrow(self: OwnedTransportTarget) TransportTarget {
        return switch (self) {
            .loopback => |port| .{ .loopback = port },
            .direct_https => |url| .{ .direct_https = url },
        };
    }

    fn deinit(self: *OwnedTransportTarget, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loopback => {},
            .direct_https => |url| allocator.free(url),
        }
        self.* = undefined;
    }
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
    /// The runtime refused the one-time pairing grant (expired, revoked, or
    /// already used). The user must mint a new grant on the runtime.
    pairing_rejected,
    /// The runtime's Pair endpoints are rate limiting this device.
    rate_limited,
};

/// Stable, secret-free reason codes shared by snapshots and RPC results.
/// These codes are independent of display copy and must not be inferred from
/// an English error message.
pub const FailureReason = enum {
    transport_offline,
    wrong_service,
    invalid_protocol_response,
    server_unavailable,
    authentication_required,
    device_credential_revoked,
    identity_changed,
    workspace_binding_missing,
    provider_unavailable,
    provider_not_authenticated,
    credential_store_unavailable,
    credential_invalid,
    unknown,
};

pub const CredentialHydration = enum {
    not_applicable,
    loaded,
    missing,
    backend_unavailable,
    invalid,
};

/// Where a paired profile is in the one-time grant exchange.
pub const PairingState = enum {
    none,
    /// The grant is being exchanged over the tunnel.
    exchanging,
    /// The runtime accepted the grant; the identity awaits user confirmation.
    awaiting_confirmation,
};

/// Secret input for one exchange. The manager copies and zeroes it.
pub const PairingInput = struct {
    grant_id: []const u8,
    pairing_token: []const u8,
    device_label: []const u8,
};

/// Non-secret outcome of a grant exchange, shown for confirmation before the
/// device is persisted. Borrowed until the next manager mutation.
pub const PairingResult = struct {
    device_id: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
};

/// One Pair auth POST over the supervised loopback port. Injected in tests.
pub const AccessBackend = struct {
    context: ?*anyopaque = null,
    call: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        TransportTarget,
        []const u8,
        ?[]const u8,
        []const u8,
    ) pair_client.Error![]u8,
    retain_context: ?*const fn (?*anyopaque) void = null,
    release_context: ?*const fn (?*anyopaque) void = null,

    pub fn system() AccessBackend {
        return .{ .call = callSystemAccess };
    }

    fn validateLifetime(self: AccessBackend) !void {
        if (self.context == null) return;
        if (self.retain_context == null or self.release_context == null) {
            return error.UnsafeRpcBackendLifetime;
        }
    }

    fn retainContext(self: AccessBackend) void {
        if (self.retain_context) |retain| retain(self.context);
    }

    fn releaseContext(self: AccessBackend) void {
        if (self.release_context) |release| release(self.context);
    }
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
    failure_reason: ?FailureReason = null,
    automatic_retry_scheduled: bool = false,
    retry_attempt: u8 = 0,
    retry_delay_ms: ?u64 = null,
    manual_retry_available: bool = false,
    last_successful_connection_ms: ?u64 = null,
    credential_hydration: CredentialHydration = .not_applicable,
    desired_enabled: bool = false,
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
    /// Whether the runtime accepts staged chat attachments (chat.attachments.v1).
    /// Old daemons leave this false so attachment sends reject visibly.
    chat_attachment_capable: bool = false,
    /// Runtime-advertised, connection-validated upload limits. Zero until a
    /// verified handshake supplies them.
    max_attachment_bytes: usize = 0,
    max_request_bytes: usize = 0,
    /// Deliberately false until every general RPC carries the persisted
    /// runtime+instance target and the daemon checks it in the same dispatch;
    /// a separate heartbeat alone cannot authorize later mutation.
    execution_ready: bool,
    access: profile.AccessKind = .admin_token,
    pairing_state: PairingState = .none,
    /// Whether a paired device credential is hydrated in memory. Never the value.
    device_credential_held: bool = false,
    /// Runtime-reported wall-clock expiry of the current paired access token.
    access_token_expires_at_ms: ?i64 = null,
    device_id: ?[]const u8 = null,
};

pub const RpcTicket = struct {
    id: u64,
};

pub const RpcResponse = struct {
    allocator: std.mem.Allocator,
    json: []u8,
    /// Method-level failure classification, if the valid JSON-RPC response
    /// carries one. It never causes prompt replay or connection fallback.
    failure_reason: ?FailureReason = null,

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
        TransportTarget,
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
    access_backend: AccessBackend = AccessBackend.system(),
    /// False keeps paired device credentials in process memory only (tests
    /// and callers that must never touch the OS keyring).
    durable_credentials: bool = true,
};

pub const ProfileReplacement = enum { label_only, endpoint_changed };

/// Owned copy of a grant awaiting exchange. Zeroed on release.
const PendingGrant = struct {
    grant_id: []u8,
    pairing_token: []u8,
    device_label: []u8,

    fn deinit(self: *PendingGrant, allocator: std.mem.Allocator) void {
        allocator.free(self.grant_id);
        eraseAndFree(allocator, self.pairing_token);
        allocator.free(self.device_label);
        self.* = undefined;
    }
};

const OwnedPairingResult = struct {
    device_id: []u8,
    runtime_id: []u8,
    instance_id: []u8,

    fn deinit(self: *OwnedPairingResult, allocator: std.mem.Allocator) void {
        allocator.free(self.device_id);
        allocator.free(self.runtime_id);
        allocator.free(self.instance_id);
        self.* = undefined;
    }
};

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
    access_task: ?*AccessTask = null,
    pending_grant: ?PendingGrant = null,
    pairing_result: ?OwnedPairingResult = null,
    access_token_expires_at_ms: ?i64 = null,
    access_token_refresh_at_ms: ?u64 = null,
    healthy_generation: ?u64 = null,
    last_heartbeat_ms: ?u64 = null,
    next_heartbeat_at_ms: ?u64 = null,
    last_successful_connection_ms: ?u64 = null,
    credential_hydration: CredentialHydration = .not_applicable,
    failure_override: ?Failure = null,
    /// True after a ready-phase 401 already spent its one silent access-token
    /// re-mint without an intervening healthy round trip. A daemon restart
    /// invalidates the daemon's process-memory bearer table while the paired
    /// device credential stays valid, so the first 401 buys a re-mint, not a
    /// failure; a second consecutive 401 escalates to a visible auth failure.
    stale_bearer_remint_attempted: bool = false,
    /// Set only when the runtime's device-auth endpoint explicitly rejected
    /// the stored device credential (the gateway answers 401 solely on the
    /// daemon's authoritative `authentication_rejected`). This is the sole
    /// path into the permanent `device_credential_revoked` presentation;
    /// transport, timeout, and generic bearer failures never set it.
    device_auth_rejected: bool = false,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        // Both handoffs are non-blocking. Their worker-owned state and retained
        // callback contexts remain valid independently of this entry.
        self.supervisor.deinit();
        if (self.handshake) |task| {
            task.handoffToProcessReaper();
        }
        if (self.rpc_task) |task| task.handoffToProcessReaper();
        if (self.access_task) |task| task.handoffToProcessReaper();
        if (self.rpc_result) |*completed| completed.result.deinit();
        if (self.pending_grant) |*grant| grant.deinit(allocator);
        if (self.pairing_result) |*result| result.deinit(allocator);
        self.connection_state.deinit();
        self.owned_profile.deinit(allocator);
        self.* = undefined;
    }

    fn usesDeviceCredential(self: *const Entry) bool {
        return switch (self.owned_profile.access) {
            .paired_device => true,
            .connect => |link| link.hasRuntimeDevice(),
            .admin_token => false,
        };
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
        try dependencies.access_backend.validateLifetime();
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
            .credential_hydration = if (configured_profile.access.kind() == .admin_token)
                .not_applicable
            else
                .missing,
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
        var device_key_buffer: DeviceSecretKeyBuffer = undefined;
        _ = self.secrets.remove(deviceSecretKey(&device_key_buffer, profile_id));
        var removed = self.entries.orderedRemove(index);
        removed.deinit(self.allocator);
        return forgot_token;
    }

    /// Hydrates the paired device credential (never the short-lived access
    /// token) from the credential store. Replacing it invalidates the live
    /// generation exactly like replacing an administrator token.
    pub fn hydrateDeviceCredential(self: *Manager, profile_id: []const u8, credential: []const u8) !void {
        const entry = self.findEntry(profile_id) orelse return error.UnknownRuntimeProfile;
        if (!entry.usesDeviceCredential()) return error.ProfileAccessMismatch;
        try access_protocol.validateSecret(credential);
        var key_buffer: DeviceSecretKeyBuffer = undefined;
        const key = deviceSecretKey(&key_buffer, profile_id);
        if (self.secrets.get(key)) |previous| {
            if (!std.mem.eql(u8, previous, credential)) {
                try entry.connection_state.disable();
                clearHealth(entry);
                entry.failure_override = null;
                if (entry.tunnel_owned) entry.supervisor.stop();
                self.collectTerminalTunnel(entry);
                _ = self.secrets.remove(profile_id);
            }
        }
        try self.secrets.put(key, credential);
        entry.credential_hydration = .loaded;
        // A newly hydrated credential has no proven auth history.
        entry.device_auth_rejected = false;
        entry.stale_bearer_remint_attempted = false;
        if (entry.failure_override == .missing_credential) entry.failure_override = null;
    }

    /// Records a credential-store load outcome without accepting secret data.
    pub fn noteCredentialHydration(
        self: *Manager,
        profile_id: []const u8,
        hydration: CredentialHydration,
    ) !void {
        const entry = self.findEntry(profile_id) orelse return error.UnknownRuntimeProfile;
        if (!entry.usesDeviceCredential() or hydration == .not_applicable) {
            return error.ProfileAccessMismatch;
        }
        if (hydration == .loaded) return error.CredentialHydrationRequiresSecret;
        entry.credential_hydration = hydration;
        entry.failure_override = .missing_credential;
    }

    /// Forgets the device credential and any minted access token, invalidating
    /// the live generation first. Returns whether a credential was held.
    pub fn clearDeviceCredential(self: *Manager, profile_id: []const u8) !bool {
        const entry = self.findEntry(profile_id) orelse return error.UnknownRuntimeProfile;
        try entry.connection_state.disable();
        clearHealth(entry);
        entry.failure_override = null;
        entry.access_token_expires_at_ms = null;
        entry.access_token_refresh_at_ms = null;
        entry.device_auth_rejected = false;
        entry.stale_bearer_remint_attempted = false;
        if (entry.tunnel_owned) entry.supervisor.stop();
        self.collectTerminalTunnel(entry);
        _ = self.secrets.remove(profile_id);
        var key_buffer: DeviceSecretKeyBuffer = undefined;
        entry.credential_hydration = .missing;
        return self.secrets.remove(deviceSecretKey(&key_buffer, profile_id));
    }

    /// Stores a one-time grant for the next attempt and starts it. The grant is
    /// exchanged exactly once; the resulting identity waits for confirmation.
    pub fn beginPairing(self: *Manager, profile_id: []const u8, input: PairingInput, now_ms: u64) !void {
        const index = self.findEntryIndex(profile_id) orelse return error.UnknownRuntimeProfile;
        const entry = &self.entries.items[index];
        if (entry.owned_profile.access != .paired_device) return error.ProfileAccessMismatch;
        if (entry.owned_profile.transport != .ssh_tunnel and entry.owned_profile.transport != .direct_https) {
            entry.failure_override = .unsupported_transport;
            return error.UnsupportedRuntimeTransport;
        }
        try access_protocol.validateGrantId(input.grant_id);
        try access_protocol.validateSecret(input.pairing_token);
        try access_protocol.validateDeviceLabel(input.device_label);

        const grant_id = try self.allocator.dupe(u8, input.grant_id);
        errdefer self.allocator.free(grant_id);
        const pairing_token = try self.allocator.dupe(u8, input.pairing_token);
        errdefer eraseAndFree(self.allocator, pairing_token);
        const device_label = try self.allocator.dupe(u8, input.device_label);
        errdefer self.allocator.free(device_label);

        // A re-pair replaces the old device entirely: old credential, token,
        // trust, and any unconfirmed previous exchange.
        try entry.connection_state.disable();
        clearHealth(entry);
        if (entry.tunnel_owned) entry.supervisor.stop();
        self.collectTerminalTunnel(entry);
        self.dropPairingState(entry);
        entry.pending_grant = .{
            .grant_id = grant_id,
            .pairing_token = pairing_token,
            .device_label = device_label,
        };
        const generation = try entry.connection_state.enable();
        entry.failure_override = null;
        if (!entry.tunnel_owned and entry.handshake == null and entry.access_task == null) {
            try self.startAttempt(index, generation, now_ms);
        }
    }

    /// Cancels an unconfirmed pairing: disables the connection, stops the
    /// tunnel, and wipes the grant plus any device credential it produced.
    /// The runtime may still list an orphaned device; the UI says so.
    pub fn abandonPairing(self: *Manager, profile_id: []const u8) !void {
        const entry = self.findEntry(profile_id) orelse return error.UnknownRuntimeProfile;
        try entry.connection_state.disable();
        clearHealth(entry);
        entry.failure_override = null;
        if (entry.tunnel_owned) entry.supervisor.stop();
        self.collectTerminalTunnel(entry);
        self.dropPairingState(entry);
    }

    /// Borrowed exchange result awaiting confirmation, if any.
    pub fn pairingResult(self: *const Manager, profile_id: []const u8) ?PairingResult {
        const entry = self.findEntryConst(profile_id) orelse return null;
        const result = entry.pairing_result orelse return null;
        return .{
            .device_id = result.device_id,
            .runtime_id = result.runtime_id,
            .instance_id = result.instance_id,
        };
    }

    /// Installs the persisted paired profile (device reference plus identity
    /// pin) after the user confirmed the exchanged identity, keeping the
    /// hydrated device credential, then starts a normal authenticated attempt.
    pub fn completePairing(self: *Manager, configured_profile: profile.Profile, now_ms: u64) !void {
        const index = self.findEntryIndex(configured_profile.id) orelse return error.UnknownRuntimeProfile;
        if (configured_profile.access != .paired_device or !configured_profile.access.paired_device.isPaired()) {
            return error.ProfileAccessMismatch;
        }
        {
            const entry = &self.entries.items[index];
            const result = entry.pairing_result orelse return error.PairingNotConfirmed;
            const expected_runtime = configured_profile.expected_runtime_id orelse return error.PairingNotConfirmed;
            const expected_instance = configured_profile.expected_instance_id orelse return error.PairingNotConfirmed;
            if (!std.mem.eql(u8, result.runtime_id, expected_runtime) or
                !std.mem.eql(u8, result.instance_id, expected_instance) or
                !std.mem.eql(u8, result.device_id, configured_profile.access.paired_device.device_id.?))
            {
                return error.PairingIdentityMismatch;
            }
        }
        try self.replaceEntryProfile(index, configured_profile, true);
        try self.enable(configured_profile.id, now_ms);
    }

    fn dropPairingState(self: *Manager, entry: *Entry) void {
        if (entry.pending_grant) |*grant| grant.deinit(self.allocator);
        entry.pending_grant = null;
        if (entry.pairing_result) |*result| result.deinit(self.allocator);
        entry.pairing_result = null;
        entry.access_token_expires_at_ms = null;
        entry.access_token_refresh_at_ms = null;
        _ = self.secrets.remove(entry.owned_profile.id);
        var key_buffer: DeviceSecretKeyBuffer = undefined;
        _ = self.secrets.remove(deviceSecretKey(&key_buffer, entry.owned_profile.id));
    }

    // Swaps the entry's profile and connection state. Pair confirmation keeps
    // its freshly exchanged credential; explicit peer replacement clears all
    // credentials before the new descriptor becomes live.
    fn replaceEntryProfile(
        self: *Manager,
        index: usize,
        configured_profile: profile.Profile,
        preserve_credentials: bool,
    ) !void {
        var owned_profile = try cloneProfile(self.allocator, configured_profile);
        errdefer owned_profile.deinit(self.allocator);
        var connection_state = try connection.Connection.init(
            self.allocator,
            owned_profile.id,
            owned_profile.expected_runtime_id,
            owned_profile.expected_instance_id,
        );
        errdefer connection_state.deinit();
        const entry = &self.entries.items[index];
        try entry.connection_state.disable();
        clearHealth(entry);
        if (entry.tunnel_owned) entry.supervisor.stop();
        self.collectTerminalTunnel(entry);
        if (entry.pending_grant) |*grant| grant.deinit(self.allocator);
        if (entry.pairing_result) |*result| result.deinit(self.allocator);
        var previous = self.entries.items[index];
        previous.pending_grant = null;
        previous.pairing_result = null;
        if (!preserve_credentials) {
            _ = self.secrets.remove(configured_profile.id);
            var clear_key_buffer: DeviceSecretKeyBuffer = undefined;
            _ = self.secrets.remove(deviceSecretKey(&clear_key_buffer, configured_profile.id));
        }
        var device_key_buffer: DeviceSecretKeyBuffer = undefined;
        const device_credential_loaded = configured_profile.access.kind() != .admin_token and
            self.secrets.get(deviceSecretKey(&device_key_buffer, configured_profile.id)) != null;
        self.entries.items[index] = .{
            .owned_profile = owned_profile,
            .connection_state = connection_state,
            .credential_hydration = if (configured_profile.access.kind() == .admin_token)
                .not_applicable
            else if (device_credential_loaded)
                .loaded
            else
                .missing,
        };
        previous.deinit(self.allocator);
    }

    /// Installs a newly selected Connect descriptor even when its transport
    /// URLs equal the previous selection. Link and runtime identity changes are
    /// new peers: live work and both credential forms must never cross them.
    pub fn replaceConnectPeer(self: *Manager, configured_profile: profile.Profile) !void {
        if (configured_profile.transport != .connect or configured_profile.access != .connect) {
            return error.ProfileAccessMismatch;
        }
        const index = self.findEntryIndex(configured_profile.id) orelse return error.UnknownRuntimeProfile;
        try self.replaceEntryProfile(index, configured_profile, false);
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
            errdefer self.allocator.free(label);
            // Device references and Connect link ids are non-secret access
            // metadata that may change without the peer changing.
            var access = try cloneAccess(self.allocator, configured_profile.access);
            self.allocator.free(entry.owned_profile.label);
            entry.owned_profile.label = label;
            entry.owned_profile.access.deinit(self.allocator);
            entry.owned_profile.access = access;
            entry.owned_profile.desired_enabled = configured_profile.desired_enabled;
            access = .admin_token;
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

    /// Starts a remote attempt without waiting for authentication or network IO.
    pub fn enable(self: *Manager, profile_id: []const u8, now_ms: u64) !void {
        const index = self.findEntryIndex(profile_id) orelse return error.UnknownRuntimeProfile;
        const entry = &self.entries.items[index];
        if (entry.owned_profile.transport != .ssh_tunnel and
            entry.owned_profile.transport != .direct_https and entry.owned_profile.transport != .connect)
        {
            entry.failure_override = .unsupported_transport;
            return error.UnsupportedRuntimeTransport;
        }
        if (!self.entryHasStartCredential(entry)) {
            entry.failure_override = .missing_credential;
            return error.MissingRuntimeCredential;
        }

        self.collectTerminalTunnel(entry);
        const generation = try entry.connection_state.enable();
        clearHealth(entry);
        entry.failure_override = null;
        entry.device_auth_rejected = false;
        entry.stale_bearer_remint_attempted = false;
        if (!entry.tunnel_owned and entry.handshake == null and entry.access_task == null) {
            try self.startAttempt(index, generation, now_ms);
        } else if (entry.tunnel_owned) {
            entry.supervisor.stop();
        }
    }

    // Admin-token profiles need the bearer. Pair and bootstrapped Connect
    // profiles use the same runtime-local device credential and token flow.
    fn entryHasStartCredential(self: *const Manager, entry: *const Entry) bool {
        return switch (entry.owned_profile.access) {
            .admin_token => self.secrets.get(entry.owned_profile.id) != null,
            .paired_device => blk: {
                if (entry.pending_grant != null) break :blk true;
                var key_buffer: DeviceSecretKeyBuffer = undefined;
                break :blk self.secrets.get(deviceSecretKey(&key_buffer, entry.owned_profile.id)) != null;
            },
            .connect => |link| blk: {
                if (!link.hasRuntimeDevice()) break :blk false;
                var key_buffer: DeviceSecretKeyBuffer = undefined;
                break :blk self.secrets.get(deviceSecretKey(&key_buffer, entry.owned_profile.id)) != null;
            },
        };
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
        if (!self.entryHasStartCredential(entry)) {
            entry.failure_override = .missing_credential;
            return error.MissingRuntimeCredential;
        }
        self.collectTerminalTunnel(entry);
        const generation = try entry.connection_state.retryFailed();
        clearHealth(entry);
        entry.failure_override = null;
        // A user-driven retry re-probes with the held credential; a genuine
        // revocation re-proves itself through the device-auth endpoint.
        entry.device_auth_rejected = false;
        entry.stale_bearer_remint_attempted = false;
        if (!entry.tunnel_owned and entry.handshake == null and entry.access_task == null) {
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
        self.fillSecretPresence(entry, &row);
        return row;
    }

    /// Allocates only the bounded row array; all strings inside remain borrowed.
    pub fn snapshotsAlloc(self: *const Manager, allocator: std.mem.Allocator) ![]Snapshot {
        const snapshots = try allocator.alloc(Snapshot, self.entries.items.len);
        for (self.entries.items, 0..) |*entry, index| {
            snapshots[index] = snapshotEntry(entry);
            self.fillSecretPresence(entry, &snapshots[index]);
        }
        return snapshots;
    }

    fn fillSecretPresence(self: *const Manager, entry: *const Entry, row: *Snapshot) void {
        row.credential_held = self.secrets.get(entry.owned_profile.id) != null;
        var key_buffer: DeviceSecretKeyBuffer = undefined;
        row.device_credential_held = self.secrets.get(deviceSecretKey(&key_buffer, entry.owned_profile.id)) != null;
        row.manual_retry_available = (row.phase == .failed or row.phase == .reconnecting) and
            self.entryHasStartCredential(entry);
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
        const allow_commit_current = entry.tunnel_generation == proposal.generation and
            ((!entry.tunnel_owned and isDirectEntry(entry)) or tunnel.lifecycle == .running);
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
        try self.startRpcTask(
            entry,
            .{ .user = ticket },
            request_id,
            request_json,
            rpcFailureContext(method),
        );
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
        try self.collectAccess(entry, now_ms);
        try self.collectRpc(entry, now_ms);

        const workers_idle = entry.handshake == null and entry.access_task == null;
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
                if (!entry.tunnel_owned and workers_idle) {
                    if (try entry.connection_state.reconnectIfDue(now_ms)) |generation| {
                        self.startAttempt(index, generation, now_ms) catch {};
                    }
                }
            },
            .connecting => {
                clearHealth(entry);
                if (isDirectEntry(entry) and entry.tunnel_generation == entry.connection_state.generation and workers_idle) {
                    try self.advanceConnecting(entry, now_ms);
                } else if (!entry.tunnel_owned and workers_idle) {
                    self.startAttempt(index, entry.connection_state.generation, now_ms) catch {};
                } else if (entry.tunnel_owned and workers_idle) {
                    const tunnel = entry.supervisor.getSnapshot();
                    if (tunnel.lifecycle == .running and
                        entry.tunnel_generation == entry.connection_state.generation)
                    {
                        try self.advanceConnecting(entry, now_ms);
                    }
                }
            },
            .handshaking, .awaiting_trust => clearHealth(entry),
            .ready => {
                entry.failure_override = null;
                if (!runtimeAdvertisesTargeting(entry)) {
                    try self.invalidateExecution(entry, .protocol, now_ms);
                } else if (entry.usesDeviceCredential() and entry.rpc_task == null and entry.access_task == null and
                    accessTokenRefreshDue(entry, now_ms))
                {
                    // Re-mint before expiry; the fresh token replaces the old
                    // one in place so the ready generation is preserved.
                    self.startAccessTask(entry, .mint_access_token, now_ms) catch |err| {
                        const failure: connection.FailureKind = switch (err) {
                            error.MissingRuntimeCredential => .authentication,
                            error.RelayNotReady, error.BearerLeaseAlreadyHeld => .network,
                            else => .resource,
                        };
                        try self.invalidateExecution(entry, failure, now_ms);
                    };
                } else if (entry.rpc_task == null and entry.access_task == null and heartbeatDue(entry, now_ms)) {
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
        if (!self.entryHasStartCredential(entry)) {
            _ = try entry.connection_state.failAttempt(
                generation,
                .authentication,
                now_ms,
                reconnectJitter(entry, generation),
            );
            entry.failure_override = .missing_credential;
            return error.MissingRuntimeCredential;
        }
        if (entry.usesDeviceCredential()) {
            // Access tokens are short lived and bound to the runtime session;
            // every attempt mints a fresh one from the device credential.
            _ = self.secrets.remove(entry.owned_profile.id);
            entry.access_token_expires_at_ms = null;
            entry.access_token_refresh_at_ms = null;
        }

        if (entry.owned_profile.transport == .direct_https or entry.owned_profile.transport == .connect) {
            const endpoint = directEndpoint(entry) orelse {
                _ = try entry.connection_state.failAttempt(generation, .protocol, now_ms, reconnectJitter(entry, generation));
                entry.failure_override = .unsupported_transport;
                return error.UnsupportedRuntimeTransport;
            };
            _ = endpoint;
            entry.tunnel_generation = generation;
            entry.failure_override = null;
            return;
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
            .local_socket, .direct_https, .connect => return error.UnsupportedRuntimeTransport,
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
            if (entry.tunnel_owned) entry.supervisor.stop();
            return;
        };
        var bearer_lease: ?tunnel_supervisor.BearerLease = if (entry.tunnel_owned)
            entry.supervisor.acquireBearerLease() catch {
                _ = try entry.connection_state.failAttempt(generation, .network, now_ms, reconnectJitter(entry, generation));
                entry.failure_override = .tunnel_readiness;
                entry.supervisor.stop();
                return;
            }
        else
            null;
        defer if (bearer_lease) |*lease| lease.release();
        if (try entry.connection_state.beginHandshake(generation) == .stale) return;

        entry.handshake = HandshakeTask.start(
            self.allocator,
            generation,
            try transportTarget(entry),
            token,
            entry.connection_state.expectedRuntimeId(),
            self.dependencies.rpc_backend,
            if (bearer_lease) |*lease| lease else null,
        ) catch |err| {
            _ = try entry.connection_state.failAttempt(
                generation,
                .resource,
                now_ms,
                reconnectJitter(entry, generation),
            );
            entry.failure_override = .resource;
            if (entry.tunnel_owned) entry.supervisor.stop();
            return err;
        };
    }

    // With the tunnel up and no worker running, pick the next single relayed
    // call: grant exchange, access-token mint, or the identity handshake.
    fn advanceConnecting(self: *Manager, entry: *Entry, now_ms: u64) !void {
        if (!entry.usesDeviceCredential()) return self.startHandshake(entry, now_ms);
        if (entry.pending_grant != null) return self.startAccessTask(entry, .pair_exchange, now_ms);
        // An exchanged identity waits for the user; keep the tunnel warm.
        if (entry.pairing_result != null) return;
        if (self.secrets.get(entry.owned_profile.id) == null) {
            return self.startAccessTask(entry, .mint_access_token, now_ms);
        }
        return self.startHandshake(entry, now_ms);
    }

    fn startAccessTask(self: *Manager, entry: *Entry, kind: AccessTaskKind, now_ms: u64) !void {
        const generation = entry.tunnel_generation orelse return error.MissingTunnelGeneration;
        if (entry.access_task != null) return error.RuntimeRpcBusy;
        if (entry.tunnel_owned and entry.supervisor.getSnapshot().lifecycle != .running) return error.RelayNotReady;
        const target = try transportTarget(entry);

        var body: []u8 = undefined;
        var authorization: ?[]u8 = null;
        var path: []const u8 = undefined;
        switch (kind) {
            .pair_exchange => {
                const grant = entry.pending_grant orelse return error.PairingGrantMissing;
                path = access_protocol.HTTP_PAIR_EXCHANGE_PATH;
                body = try encodeExchangeBodyAlloc(self.allocator, grant);
            },
            .mint_access_token => {
                var key_buffer: DeviceSecretKeyBuffer = undefined;
                const credential = self.secrets.get(deviceSecretKey(&key_buffer, entry.owned_profile.id)) orelse {
                    _ = try entry.connection_state.failAttempt(
                        generation,
                        .authentication,
                        now_ms,
                        reconnectJitter(entry, generation),
                    );
                    entry.failure_override = .missing_credential;
                    entry.supervisor.stop();
                    return error.MissingRuntimeCredential;
                };
                const device_id = switch (entry.owned_profile.access) {
                    .paired_device => |device| device.device_id orelse return error.MissingRuntimeCredential,
                    .connect => |link| link.device_id orelse return error.MissingRuntimeCredential,
                    else => return error.ProfileAccessMismatch,
                };
                path = access_protocol.HTTP_ACCESS_TOKEN_PATH;
                authorization = try pair_client.deviceAuthorizationAlloc(self.allocator, device_id, credential);
                body = try encodeAccessTokenBodyAlloc(self.allocator);
            },
        }
        defer eraseAndFree(self.allocator, body);
        defer if (authorization) |value| eraseAndFree(self.allocator, value);

        var bearer_lease: ?tunnel_supervisor.BearerLease = if (entry.tunnel_owned) entry.supervisor.acquireBearerLease() catch {
            if (entry.connection_state.phase() == .ready) return error.BearerLeaseAlreadyHeld;
            _ = try entry.connection_state.failAttempt(
                generation,
                .network,
                now_ms,
                reconnectJitter(entry, generation),
            );
            entry.failure_override = .tunnel_readiness;
            entry.supervisor.stop();
            return;
        } else null;
        defer if (bearer_lease) |*lease| lease.release();
        entry.access_task = AccessTask.start(
            generation,
            kind,
            target,
            path,
            authorization,
            body,
            self.dependencies.access_backend,
            if (bearer_lease) |*lease| lease else null,
        ) catch |err| {
            if (entry.connection_state.phase() != .ready) {
                _ = try entry.connection_state.failAttempt(
                    generation,
                    .resource,
                    now_ms,
                    reconnectJitter(entry, generation),
                );
                entry.failure_override = .resource;
                entry.supervisor.stop();
            }
            return err;
        };
    }

    fn collectAccess(self: *Manager, entry: *Entry, now_ms: u64) !void {
        const task = entry.access_task orelse return;
        if (task.state.load(.acquire) != .finished) return;

        const generation = task.generation;
        const kind = task.kind;
        const task_allocator = task.allocator;
        var worker_result = task.takeResult();
        task.releaseFields();
        task_allocator.destroy(task);
        entry.access_task = null;
        defer worker_result.deinit(task_allocator);
        if (!entry.tunnel_owned and entry.handshake == null) entry.local_port = null;

        const current = entry.tunnel_generation == generation and
            (!entry.tunnel_owned or entry.supervisor.getSnapshot().lifecycle == .running) and
            entry.connection_state.generation == generation and
            switch (entry.connection_state.phase()) {
                .connecting, .ready => true,
                else => false,
            };
        if (!current) return;

        switch (worker_result) {
            .failed => |failure| try self.failAccess(entry, generation, kind, failure, now_ms),
            .response => |response| switch (kind) {
                .pair_exchange => self.applyExchange(entry, generation, response, now_ms) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.PairingIdentityMismatch => try self.failAccess(entry, generation, kind, .identity, now_ms),
                    else => try self.failAccess(entry, generation, kind, .protocol, now_ms),
                },
                .mint_access_token => self.applyAccessToken(entry, response, now_ms) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => try self.failAccess(entry, generation, kind, .protocol, now_ms),
                },
            },
        }
    }

    fn failAccess(
        self: *Manager,
        entry: *Entry,
        generation: u64,
        kind: AccessTaskKind,
        failure: AccessFailure,
        now_ms: u64,
    ) !void {
        // Only the device-auth endpoint's explicit 401 is authoritative for
        // the credential itself: the gateway answers 503 while the daemon is
        // unreachable and 429 while rate limiting, so those never claim the
        // device was revoked.
        if (kind == .mint_access_token and failure == .authentication) {
            entry.device_auth_rejected = true;
        }
        const connection_failure: connection.FailureKind = switch (failure) {
            .authentication, .rate_limited => .authentication,
            .network => .network,
            .identity => .identity,
            .protocol => .protocol,
            .resource => .resource,
        };
        const override: Failure = switch (failure) {
            .authentication => if (kind == .pair_exchange) .pairing_rejected else .authentication,
            .rate_limited => .rate_limited,
            .network => .network,
            .identity => .identity,
            .protocol => .protocol,
            .resource => .resource,
        };
        // A rejected grant is one-shot: retrying it cannot succeed, so drop
        // it and stop rather than scheduling reconnects against the runtime.
        if (kind == .pair_exchange) {
            if (entry.pending_grant) |*grant| grant.deinit(self.allocator);
            entry.pending_grant = null;
            _ = try entry.connection_state.failAttempt(
                generation,
                connection_failure,
                now_ms,
                reconnectJitter(entry, generation),
            );
            try entry.connection_state.disable();
            entry.failure_override = override;
            if (entry.tunnel_owned) entry.supervisor.stop();
            return;
        }
        if (entry.connection_state.phase() == .ready) {
            try self.invalidateExecution(entry, connection_failure, now_ms);
        } else {
            _ = try entry.connection_state.failAttempt(
                generation,
                connection_failure,
                now_ms,
                reconnectJitter(entry, generation),
            );
            if (entry.tunnel_owned) entry.supervisor.stop();
        }
        entry.failure_override = override;
    }

    // Validates the exchange response, stores the device credential in memory,
    // and parks the identity for confirmation. A re-pair against a pinned
    // profile must produce the same runtime.
    fn applyExchange(self: *Manager, entry: *Entry, generation: u64, response: []const u8, now_ms: u64) !void {
        _ = generation;
        _ = now_ms;
        var parsed = try std.json.parseFromSlice(ExchangeResponse, self.allocator, response, .{
            .ignore_unknown_fields = true,
        });
        defer {
            std.crypto.secureZero(u8, @constCast(parsed.value.device_credential));
            parsed.deinit();
        }
        const value = parsed.value;
        if (value.access_protocol_version != access_protocol.ACCESS_PROTOCOL_VERSION) return error.IncompatibleAccessProtocol;
        try connection.validateRuntimeId(value.runtime_id);
        try connection.validateRuntimeId(value.instance_id);
        try access_protocol.validateDeviceId(value.device_id);
        try access_protocol.validateSecret(value.device_credential);
        if (entry.owned_profile.expected_runtime_id) |pinned| {
            if (!std.mem.eql(u8, pinned, value.runtime_id)) return error.PairingIdentityMismatch;
        }

        const device_id = try self.allocator.dupe(u8, value.device_id);
        errdefer self.allocator.free(device_id);
        const runtime_id = try self.allocator.dupe(u8, value.runtime_id);
        errdefer self.allocator.free(runtime_id);
        const instance_id = try self.allocator.dupe(u8, value.instance_id);
        errdefer self.allocator.free(instance_id);
        var key_buffer: DeviceSecretKeyBuffer = undefined;
        try self.secrets.put(deviceSecretKey(&key_buffer, entry.owned_profile.id), value.device_credential);

        if (entry.pending_grant) |*grant| grant.deinit(self.allocator);
        entry.pending_grant = null;
        // Re-pairing replaces the credential, so prior auth outcomes are void.
        entry.device_auth_rejected = false;
        entry.stale_bearer_remint_attempted = false;
        if (entry.pairing_result) |*previous| previous.deinit(self.allocator);
        entry.pairing_result = .{
            .device_id = device_id,
            .runtime_id = runtime_id,
            .instance_id = instance_id,
        };
    }

    fn applyAccessToken(self: *Manager, entry: *Entry, response: []const u8, now_ms: u64) !void {
        var parsed = try std.json.parseFromSlice(AccessTokenResponse, self.allocator, response, .{
            .ignore_unknown_fields = true,
        });
        defer {
            std.crypto.secureZero(u8, @constCast(parsed.value.access_token));
            parsed.deinit();
        }
        const value = parsed.value;
        if (value.access_protocol_version != access_protocol.ACCESS_PROTOCOL_VERSION) return error.IncompatibleAccessProtocol;
        if (!std.mem.eql(u8, value.token_type, access_protocol.ACCESS_TOKEN_TYPE)) return error.UnexpectedTokenType;
        try access_protocol.validateSecret(value.access_token);
        try self.secrets.put(entry.owned_profile.id, value.access_token);
        entry.access_token_expires_at_ms = value.expires_at_ms;
        entry.access_token_refresh_at_ms = accessTokenRefreshAt(self.io, value.expires_at_ms, now_ms);
        // The runtime just accepted the device credential, so any previous
        // rejection marker is stale. The remint-attempted bound stays until a
        // healthy RPC proves the fresh bearer actually works.
        entry.device_auth_rejected = false;
        if (entry.failure_override == .missing_credential) entry.failure_override = null;
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
                    if (entry.connection_state.phase() == .ready or
                        entry.connection_state.phase() == .awaiting_trust)
                    {
                        entry.last_successful_connection_ms = now_ms;
                    }
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
        const failure_context = task.failure_context;
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
                if (!self.recoverStaleBearer(entry, failure)) {
                    try self.invalidateExecution(entry, failure, now_ms);
                }
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
                    // A successful authenticated round trip is authoritative:
                    // the credential works, so any stale auth/revoked markers
                    // must not survive it.
                    entry.stale_bearer_remint_attempted = false;
                    entry.device_auth_rejected = false;
                    if (kind == .user) {
                        const failure_reason = classifyRpcResponseFailure(
                            self.allocator,
                            failure_context,
                            request_id,
                            response,
                        );
                        entry.rpc_result = .{
                            .ticket = kind.user,
                            .result = .{ .response = .{
                                .allocator = task_allocator,
                                .json = response,
                                .failure_reason = failure_reason,
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
        try self.startRpcTask(entry, .heartbeat, request_id, request_json, .general);
    }

    fn startRpcTask(
        self: *Manager,
        entry: *Entry,
        kind: RpcTaskKind,
        request_id: u64,
        request_json: []const u8,
        failure_context: RpcFailureContext,
    ) !void {
        if (entry.rpc_task != null) return error.RuntimeRpcBusy;
        if (entry.connection_state.phase() != .ready) return error.RuntimeNotExecutionReady;
        const generation = entry.connection_state.generation;
        if (entry.tunnel_generation != generation) return error.RelayNotReady;
        if (entry.tunnel_owned and entry.supervisor.getSnapshot().lifecycle != .running) return error.RelayNotReady;
        const token = self.secrets.get(entry.owned_profile.id) orelse
            return error.MissingRuntimeCredential;
        var bearer_lease: ?tunnel_supervisor.BearerLease = if (entry.tunnel_owned)
            try entry.supervisor.acquireBearerLease()
        else
            null;
        defer if (bearer_lease) |*lease| lease.release();
        entry.rpc_task = try RpcTask.start(
            generation,
            request_id,
            kind,
            failure_context,
            try transportTarget(entry),
            token,
            request_json,
            self.dependencies.rpc_backend,
            if (bearer_lease) |*lease| lease else null,
        );
    }

    /// A 401 on an authenticated RPC right after a daemon restart usually
    /// means the daemon lost its process-memory access-token table, not that
    /// the paired device was revoked. Spend the still-valid device credential
    /// on one silent re-mint (bounded by `stale_bearer_remint_attempted`)
    /// before letting authentication surface as a failure. Returns whether
    /// recovery was scheduled; the ready generation is preserved so a stale
    /// pre-restart worker cannot outrank the recovering session.
    fn recoverStaleBearer(_: *Manager, entry: *Entry, failure: connection.FailureKind) bool {
        if (failure != .authentication) return false;
        if (!entry.usesDeviceCredential()) return false;
        if (entry.connection_state.phase() != .ready) return false;
        if (entry.stale_bearer_remint_attempted) return false;
        entry.stale_bearer_remint_attempted = true;
        clearHealth(entry);
        // Due immediately: the ready branch prefers a re-mint over the next
        // heartbeat, and a successful mint restores the real refresh deadline.
        entry.access_token_refresh_at_ms = 0;
        return true;
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
    target: OwnedTransportTarget,
    token: []u8,
    expected_runtime_id: ?[]u8,
    rpc_backend: RpcBackend,
    bearer_lease: ?tunnel_supervisor.BearerLease,
    worker: ?std.Thread = null,
    state: std.atomic.Value(TaskState) = .init(.running),
    result: ?HandshakeResult = null,

    fn start(
        allocator: std.mem.Allocator,
        generation: u64,
        target: TransportTarget,
        token: []const u8,
        expected_runtime_id: ?[]const u8,
        rpc_backend: RpcBackend,
        bearer_lease: ?*tunnel_supervisor.BearerLease,
    ) !*HandshakeTask {
        _ = allocator;
        try rpc_backend.validateLifetime();
        // The task may outlive Manager.deinit while a bounded gateway call
        // completes, so all task memory is process-owned.
        const task_allocator = std.heap.page_allocator;
        const task = try task_allocator.create(HandshakeTask);
        errdefer task_allocator.destroy(task);
        var target_copy = try OwnedTransportTarget.clone(task_allocator, target);
        errdefer target_copy.deinit(task_allocator);
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
            .target = target_copy,
            .token = token_copy,
            .expected_runtime_id = expected_copy,
            .rpc_backend = rpc_backend,
            .bearer_lease = if (bearer_lease) |lease| lease.take() else null,
        };
        errdefer if (task.bearer_lease) |*lease| lease.release();
        task.worker = try std.Thread.spawn(.{}, handshakeWorker, .{task});
        return task;
    }

    fn releaseFields(self: *HandshakeTask) void {
        if (self.result) |*result| result.deinit();
        self.target.deinit(self.allocator);
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

const AccessTaskKind = enum {
    pair_exchange,
    mint_access_token,
};

const AccessFailure = enum {
    authentication,
    rate_limited,
    network,
    identity,
    protocol,
    resource,
};

const AccessWorkerResult = union(enum) {
    response: []u8,
    failed: AccessFailure,

    fn deinit(self: *AccessWorkerResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .response => |response| eraseAndFree(allocator, response),
            .failed => {},
        }
        self.* = undefined;
    }
};

const ExchangeResponse = struct {
    access_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    device_id: []const u8,
    device_credential: []const u8,
};

const AccessTokenResponse = struct {
    access_protocol_version: u32,
    access_token: []const u8,
    token_type: []const u8,
    expires_at_ms: i64,
};

pub const DeviceSecretKeyBuffer = [secret_store.MAX_PROFILE_ID_BYTES + DEVICE_SECRET_SUFFIX.len]u8;

/// Process-memory slot for the paired device credential of one profile.
pub fn deviceSecretKey(buffer: *DeviceSecretKeyBuffer, profile_id: []const u8) []const u8 {
    const len = @min(profile_id.len, secret_store.MAX_PROFILE_ID_BYTES);
    @memcpy(buffer[0..len], profile_id[0..len]);
    @memcpy(buffer[len .. len + DEVICE_SECRET_SUFFIX.len], DEVICE_SECRET_SUFFIX);
    return buffer[0 .. len + DEVICE_SECRET_SUFFIX.len];
}

fn encodeExchangeBodyAlloc(allocator: std.mem.Allocator, grant: PendingGrant) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("access_protocol_version");
    try stringify.write(access_protocol.ACCESS_PROTOCOL_VERSION);
    try stringify.objectField("grant_id");
    try stringify.write(grant.grant_id);
    try stringify.objectField("pairing_token");
    try stringify.write(grant.pairing_token);
    try stringify.objectField("device_label");
    try stringify.write(grant.device_label);
    try stringify.endObject();
    return out.toOwnedSlice();
}

fn encodeAccessTokenBodyAlloc(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("access_protocol_version");
    try stringify.write(access_protocol.ACCESS_PROTOCOL_VERSION);
    try stringify.objectField("requested_scopes");
    try stringify.write(&access_protocol.DEFAULT_SCOPE_NAMES);
    try stringify.endObject();
    return out.toOwnedSlice();
}

// The runtime reports wall-clock expiry; the manager runs on the caller's
// monotonic `now_ms`. Convert once at mint time using the remaining TTL.
fn accessTokenRefreshAt(io: std.Io, expires_at_ms: i64, now_ms: u64) u64 {
    const wall_now_ms = std.Io.Clock.real.now(io).toMilliseconds();
    const ttl_ms: u64 = if (expires_at_ms > wall_now_ms) @intCast(expires_at_ms - wall_now_ms) else 0;
    const lead = ttl_ms -| ACCESS_TOKEN_REFRESH_MARGIN_MS;
    return now_ms +| @max(lead, ACCESS_TOKEN_MIN_REFRESH_DELAY_MS);
}

fn accessTokenRefreshDue(entry: *const Entry, now_ms: u64) bool {
    const refresh_at = entry.access_token_refresh_at_ms orelse return false;
    return now_ms >= refresh_at;
}

const AccessTask = struct {
    allocator: std.mem.Allocator,
    generation: u64,
    kind: AccessTaskKind,
    target: OwnedTransportTarget,
    path: []const u8,
    authorization: ?[]u8,
    body: []u8,
    access_backend: AccessBackend,
    bearer_lease: ?tunnel_supervisor.BearerLease,
    worker: ?std.Thread = null,
    state: std.atomic.Value(TaskState) = .init(.running),
    result: ?AccessWorkerResult = null,

    fn start(
        generation: u64,
        kind: AccessTaskKind,
        target: TransportTarget,
        path: []const u8,
        authorization: ?[]const u8,
        body: []const u8,
        access_backend: AccessBackend,
        bearer_lease: ?*tunnel_supervisor.BearerLease,
    ) !*AccessTask {
        try access_backend.validateLifetime();
        const task_allocator = std.heap.page_allocator;
        const task = try task_allocator.create(AccessTask);
        errdefer task_allocator.destroy(task);
        var target_copy = try OwnedTransportTarget.clone(task_allocator, target);
        errdefer target_copy.deinit(task_allocator);
        const authorization_copy = if (authorization) |value| try task_allocator.dupe(u8, value) else null;
        errdefer if (authorization_copy) |value| eraseAndFree(task_allocator, value);
        const body_copy = try task_allocator.dupe(u8, body);
        errdefer eraseAndFree(task_allocator, body_copy);
        access_backend.retainContext();
        errdefer access_backend.releaseContext();
        task.* = .{
            .allocator = task_allocator,
            .generation = generation,
            .kind = kind,
            .target = target_copy,
            .path = path,
            .authorization = authorization_copy,
            .body = body_copy,
            .access_backend = access_backend,
            .bearer_lease = if (bearer_lease) |lease| lease.take() else null,
        };
        errdefer if (task.bearer_lease) |*lease| lease.release();
        task.worker = try std.Thread.spawn(.{}, accessWorker, .{task});
        return task;
    }

    fn releaseFields(self: *AccessTask) void {
        if (self.result) |*result| result.deinit(self.allocator);
        self.target.deinit(self.allocator);
        if (self.authorization) |value| eraseAndFree(self.allocator, value);
        eraseAndFree(self.allocator, self.body);
        self.access_backend.releaseContext();
    }

    fn takeResult(self: *AccessTask) AccessWorkerResult {
        std.debug.assert(self.state.load(.acquire) == .finished);
        if (self.worker) |worker| worker.join();
        self.worker = null;
        const result = self.result orelse unreachable;
        self.result = null;
        return result;
    }

    fn handoffToProcessReaper(self: *AccessTask) void {
        const worker = self.worker orelse unreachable;
        const previous = self.state.cmpxchgStrong(.running, .abandoned, .acq_rel, .acquire);
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

fn accessWorker(task: *AccessTask) void {
    task.result = if (task.access_backend.call(
        task.access_backend.context,
        task.allocator,
        task.target.borrow(),
        task.path,
        task.authorization,
        task.body,
    )) |response| blk: {
        if (response.len > access_protocol.MAX_PAIR_EXCHANGE_BODY_BYTES) {
            eraseAndFree(task.allocator, response);
            break :blk .{ .failed = .protocol };
        }
        break :blk .{ .response = response };
    } else |err| .{ .failed = mapAccessFailure(err) };
    if (task.bearer_lease) |*lease| lease.release();
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

fn mapAccessFailure(err: pair_client.Error) AccessFailure {
    return switch (err) {
        error.OutOfMemory => .resource,
        error.AuthenticationRequired => .authentication,
        error.RateLimited => .rate_limited,
        error.NetworkUnavailable,
        error.RequestTimedOut,
        error.ConnectionClosed,
        error.ServerUnavailable,
        => .network,
        error.WrongService, error.ProtocolRejected => .protocol,
    };
}

fn callSystemAccess(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    target: TransportTarget,
    path: []const u8,
    authorization: ?[]const u8,
    body: []const u8,
) pair_client.Error![]u8 {
    return switch (target) {
        .loopback => |port| pair_client.postAlloc(allocator, .{
            .local_port = port,
            .path = path,
            .authorization = authorization,
            .body = body,
        }),
        .direct_https => |url| pair_client.postDirectAlloc(allocator, .{
            .https_url = url,
            .path = path,
            .authorization = authorization,
            .body = body,
        }),
    };
}

const RpcTaskKind = union(enum) {
    heartbeat,
    user: RpcTicket,
};

const RpcFailureContext = enum {
    general,
    repository_manifest_get,
    providers_status,
    chat_turn_start,
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
    failure_context: RpcFailureContext,
    target: OwnedTransportTarget,
    token: []u8,
    request_json: []u8,
    rpc_backend: RpcBackend,
    bearer_lease: ?tunnel_supervisor.BearerLease,
    worker: ?std.Thread = null,
    state: std.atomic.Value(TaskState) = .init(.running),
    result: ?RpcWorkerResult = null,

    fn start(
        generation: u64,
        request_id: u64,
        kind: RpcTaskKind,
        failure_context: RpcFailureContext,
        target: TransportTarget,
        token: []const u8,
        request_json: []const u8,
        rpc_backend: RpcBackend,
        bearer_lease: ?*tunnel_supervisor.BearerLease,
    ) !*RpcTask {
        try rpc_backend.validateLifetime();
        const task_allocator = std.heap.page_allocator;
        const task = try task_allocator.create(RpcTask);
        errdefer task_allocator.destroy(task);
        var target_copy = try OwnedTransportTarget.clone(task_allocator, target);
        errdefer target_copy.deinit(task_allocator);
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
            .failure_context = failure_context,
            .target = target_copy,
            .token = token_copy,
            .request_json = request_copy,
            .rpc_backend = rpc_backend,
            .bearer_lease = if (bearer_lease) |lease| lease.take() else null,
        };
        errdefer if (task.bearer_lease) |*lease| lease.release();
        task.worker = try std.Thread.spawn(.{}, rpcWorker, .{task});
        return task;
    }

    fn releaseFields(self: *RpcTask) void {
        if (self.result) |*result| result.deinit(self.allocator);
        self.target.deinit(self.allocator);
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
        task.target.borrow(),
        task.token,
        task.request_json,
    )) |response| blk: {
        if (response.len > headless.protocol.RUNTIME_MAX_MESSAGE_BYTES) {
            task.allocator.free(response);
            break :blk .{ .failed = .protocol };
        }
        break :blk .{ .response = response };
    } else |err| .{ .failed = mapTransportFailure(err) };
    if (task.bearer_lease) |*lease| lease.release();
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
    target: TransportTarget,
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
            self.target,
            self.token,
            request_json,
        );
    }
};

fn handshakeWorker(task: *HandshakeTask) void {
    var bridge: RpcBridge = .{
        .backend = task.rpc_backend,
        .target = task.target.borrow(),
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
    if (task.bearer_lease) |*lease| lease.release();
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
    target: TransportTarget,
    bearer_token: []const u8,
    rpc_json: []const u8,
) connection.TransportError![]u8 {
    const response = switch (target) {
        .loopback => |port| gateway_transport.callAlloc(allocator, .{
            .local_port = port,
            .bearer_token = bearer_token,
            .rpc_json = rpc_json,
        }),
        .direct_https => |url| gateway_transport.callDirectAlloc(allocator, .{
            .https_url = url,
            .bearer_token = bearer_token,
            .rpc_json = rpc_json,
        }),
    };
    return response catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AuthenticationRequired => error.AuthenticationRequired,
        error.RequestTimedOut => error.RequestTimedOut,
        error.DaemonUnavailable => error.ServerUnavailable,
        error.WrongService, error.RedirectRejected => error.WrongService,
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

fn rpcFailureContext(method: []const u8) RpcFailureContext {
    if (std.mem.eql(u8, method, headless.store_protocol.METHOD_WORKSPACE_REPOSITORY_MANIFEST_GET)) {
        return .repository_manifest_get;
    }
    if (std.mem.eql(u8, method, headless.providers_protocol.METHOD_PROVIDERS_STATUS)) {
        return .providers_status;
    }
    if (std.mem.eql(u8, method, "chat.turn.start")) return .chat_turn_start;
    return .general;
}

/// Classifies one valid method-level JSON-RPC error by stable method and code.
/// Display text is intentionally excluded from this contract.
pub fn classifyRpcFailure(method: []const u8, code: []const u8) FailureReason {
    return classifyRpcError(rpcFailureContext(method), code);
}

fn classifyRpcError(context: RpcFailureContext, code: []const u8) FailureReason {
    if (context == .repository_manifest_get and
        std.mem.eql(u8, code, headless.protocol.ERR_RESOURCE_NOT_FOUND))
    {
        return .workspace_binding_missing;
    }
    if (context == .providers_status and
        std.mem.eql(u8, code, headless.protocol.ERR_CAPABILITY_UNAVAILABLE))
    {
        return .provider_unavailable;
    }
    if (context == .chat_turn_start and
        std.mem.eql(u8, code, headless.protocol.ERR_PROVIDER_UNAVAILABLE))
    {
        return .provider_unavailable;
    }
    return .unknown;
}

/// Classifies structured provider state independently from unrelated chat RPC
/// errors and without parsing display text.
pub fn classifyProviderStatus(status: headless.providers_protocol.ProviderStatus) ?FailureReason {
    if (!status.installed or
        std.mem.eql(u8, status.state, "missing") or
        std.mem.eql(u8, status.state, "unavailable"))
    {
        return .provider_unavailable;
    }
    if (std.mem.eql(u8, status.authentication, "unauthenticated") or
        std.mem.eql(u8, status.authentication, "required"))
    {
        return .provider_not_authenticated;
    }
    return null;
}

fn classifyRpcResponseFailure(
    allocator: std.mem.Allocator,
    context: RpcFailureContext,
    request_id: u64,
    response_json: []const u8,
) ?FailureReason {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var client = headless.Client.initEncoder(arena.allocator());
    var parsed = client.parseResponseWithId(request_id, response_json) catch return null;
    defer parsed.deinit();
    const remote_error = parsed.response.err orelse return null;
    return classifyRpcError(context, remote_error.code);
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
        error.ServerUnavailable => .server_unavailable,
        error.WrongService => .wrong_service,
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
    if (current.access.kind() != next.access.kind()) return false;
    return switch (current.transport) {
        .local_socket => next.transport == .local_socket,
        .ssh_tunnel => |a| switch (next.transport) {
            .local_socket, .direct_https, .connect => false,
            .ssh_tunnel => |b| std.mem.eql(u8, a.host, b.host) and
                a.port == b.port and
                a.remote_gateway_port == b.remote_gateway_port and
                ((a.user == null and b.user == null) or
                    (a.user != null and b.user != null and std.mem.eql(u8, a.user.?, b.user.?))),
        },
        .direct_https => |a| switch (next.transport) {
            .direct_https => |b| optionalStringsEqual(a.https_url, b.https_url) and
                optionalStringsEqual(a.wss_url, b.wss_url) and
                optionalStringsEqual(a.spki_sha256, b.spki_sha256),
            .local_socket, .ssh_tunnel, .connect => false,
        },
        .connect => |a| switch (next.transport) {
            .local_socket, .ssh_tunnel, .direct_https => false,
            .connect => |b| optionalStringsEqual(a.https_url, b.https_url) and
                optionalStringsEqual(a.wss_url, b.wss_url) and
                optionalStringsEqual(a.spki_sha256, b.spki_sha256),
        },
    };
}

fn optionalStringsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn clearHealth(entry: *Entry) void {
    entry.healthy_generation = null;
    entry.last_heartbeat_ms = null;
    entry.next_heartbeat_at_ms = null;
}

fn rpcGenerationIsCurrent(entry: *const Entry, generation: u64) bool {
    if (entry.connection_state.phase() != .ready or
        entry.connection_state.generation != generation or
        entry.tunnel_generation != generation)
    {
        return false;
    }
    return !entry.tunnel_owned or entry.supervisor.getSnapshot().lifecycle == .running;
}

fn isDirectEntry(entry: *const Entry) bool {
    return entry.owned_profile.transport == .direct_https or entry.owned_profile.transport == .connect;
}

fn directEndpoint(entry: *const Entry) ?[]const u8 {
    return switch (entry.owned_profile.transport) {
        .direct_https => |endpoint| endpoint.https_url,
        .connect => |endpoint| endpoint.https_url,
        .local_socket, .ssh_tunnel => null,
    };
}

fn transportTarget(entry: *const Entry) !TransportTarget {
    if (entry.tunnel_owned) return .{ .loopback = entry.local_port orelse return error.MissingTunnelPort };
    return .{ .direct_https = directEndpoint(entry) orelse return error.MissingDirectEndpoint };
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
    const retry = switch (entry.connection_state.state) {
        .reconnecting => |retry_state| retry_state,
        else => null,
    };
    const connection_failure = entry.connection_state.lastFailure();
    const displayed_failure = entry.failure_override orelse if (connection_failure) |failure|
        mapConnectionFailure(failure)
    else
        null;
    return .{
        .profile_id = entry.owned_profile.id,
        .label = entry.owned_profile.label,
        .transport = switch (entry.owned_profile.transport) {
            .local_socket => .local_socket,
            .ssh_tunnel => .ssh_tunnel,
            .direct_https => .direct_https,
            .connect => .connect,
        },
        .access = entry.owned_profile.access.kind(),
        .pairing_state = if (entry.pairing_result != null)
            .awaiting_confirmation
        else if (entry.pending_grant != null or
            (entry.access_task != null and entry.access_task.?.kind == .pair_exchange))
            .exchanging
        else
            .none,
        .access_token_expires_at_ms = entry.access_token_expires_at_ms,
        .device_id = switch (entry.owned_profile.access) {
            .paired_device => |device| device.device_id,
            .connect => |link| link.device_id,
            else => null,
        },
        .phase = entry.connection_state.phase(),
        .failure = displayed_failure,
        .failure_reason = if (entry.credential_hydration == .backend_unavailable)
            .credential_store_unavailable
        else if (entry.credential_hydration == .invalid)
            .credential_invalid
        else if (entry.failure_override == .missing_credential)
            .authentication_required
        else if (connection_failure) |failure|
            // Revoked is claimed only on the device-auth endpoint's explicit
            // rejection. A generic bearer 401 (daemon restart, stale session)
            // stays a plain authentication failure with retry affordances.
            if (failure == .authentication and entry.device_auth_rejected)
                .device_credential_revoked
            else
                mapConnectionFailureReason(failure)
        else if (displayed_failure) |failure|
            mapManagerFailureReason(failure)
        else
            null,
        .automatic_retry_scheduled = retry != null,
        .retry_attempt = if (retry) |value| value.attempt else 0,
        .retry_delay_ms = if (retry) |value| value.delay_ms else null,
        .retry_at_ms = if (retry) |value| value.retry_at_ms else null,
        .last_successful_connection_ms = entry.last_successful_connection_ms,
        .credential_hydration = entry.credential_hydration,
        .desired_enabled = entry.owned_profile.desired_enabled,
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
        .chat_attachment_capable = runtimeAdvertisesCapability(entry, CHAT_ATTACHMENT_CAPABILITY),
        .max_attachment_bytes = if (entry.connection_state.metadata()) |runtime| runtime.limits.max_attachment_bytes else 0,
        .max_request_bytes = if (entry.connection_state.metadata()) |runtime| runtime.limits.max_request_bytes else 0,
        .execution_ready = entryExecutionReady(entry),
    };
}

fn mapConnectionFailure(failure: connection.FailureKind) Failure {
    return switch (failure) {
        .authentication => .authentication,
        .network => .network,
        .server_unavailable => .network,
        .identity => .identity,
        .protocol => .protocol,
        .wrong_service => .protocol,
        .resource => .resource,
    };
}

fn mapConnectionFailureReason(failure: connection.FailureKind) FailureReason {
    return switch (failure) {
        .authentication => .authentication_required,
        .network => .transport_offline,
        .server_unavailable => .server_unavailable,
        .identity => .identity_changed,
        .protocol => .invalid_protocol_response,
        .wrong_service => .wrong_service,
        .resource => .unknown,
    };
}

fn mapManagerFailureReason(failure: Failure) FailureReason {
    return switch (failure) {
        .missing_credential, .authentication, .pairing_rejected => .authentication_required,
        .network, .tunnel_readiness, .tunnel_wait, .tunnel_exited => .transport_offline,
        .identity => .identity_changed,
        .protocol => .invalid_protocol_response,
        .unsupported_transport,
        .no_loopback_port,
        .tunnel_spawn,
        .resource,
        .rate_limited,
        => .unknown,
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
        .direct_https => |endpoint| blk: {
            var cloned: profile.DirectTransport = .{};
            errdefer cloned.deinit(allocator);
            if (endpoint.https_url) |value| cloned.https_url = try allocator.dupe(u8, value);
            if (endpoint.wss_url) |value| cloned.wss_url = try allocator.dupe(u8, value);
            if (endpoint.spki_sha256) |value| cloned.spki_sha256 = try allocator.dupe(u8, value);
            break :blk .{ .direct_https = cloned };
        },
        .connect => |endpoint| blk: {
            var cloned: profile.ConnectTransport = .{};
            errdefer cloned.deinit(allocator);
            if (endpoint.https_url) |value| cloned.https_url = try allocator.dupe(u8, value);
            if (endpoint.wss_url) |value| cloned.wss_url = try allocator.dupe(u8, value);
            if (endpoint.spki_sha256) |value| cloned.spki_sha256 = try allocator.dupe(u8, value);
            break :blk .{ .connect = cloned };
        },
    };
    errdefer {
        var owned_transport = transport;
        owned_transport.deinit(allocator);
    }
    const access = try cloneAccess(allocator, source.access);
    return .{
        .id = id,
        .label = label,
        .expected_runtime_id = expected_runtime_id,
        .expected_instance_id = expected_instance_id,
        .transport = transport,
        .access = access,
        .desired_enabled = source.desired_enabled,
    };
}

fn cloneAccess(allocator: std.mem.Allocator, source: profile.Access) !profile.Access {
    return switch (source) {
        .admin_token => .admin_token,
        .paired_device => |device| blk: {
            var cloned: profile.PairedDevice = .{};
            errdefer cloned.deinit(allocator);
            if (device.device_id) |value| cloned.device_id = try allocator.dupe(u8, value);
            if (device.credential_ref) |value| cloned.credential_ref = try allocator.dupe(u8, value);
            break :blk .{ .paired_device = cloned };
        },
        .connect => |link| blk: {
            const url = try allocator.dupe(u8, link.control_plane_url);
            errdefer allocator.free(url);
            const link_id = if (link.link_id) |value| try allocator.dupe(u8, value) else null;
            errdefer if (link_id) |value| allocator.free(value);
            const device_id = if (link.device_id) |value| try allocator.dupe(u8, value) else null;
            errdefer if (device_id) |value| allocator.free(value);
            const credential_ref = if (link.credential_ref) |value| try allocator.dupe(u8, value) else null;
            break :blk .{ .connect = .{
                .control_plane_url = url,
                .link_id = link_id,
                .device_id = device_id,
                .credential_ref = credential_ref,
            } };
        },
    };
}

fn eraseAndFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

const TEST_TOKEN_A = "0123456789abcdef0123456789abcdef";
const TEST_TOKEN_B = "fedcba9876543210fedcba9876543210";
const TEST_DEVICE_CREDENTIAL =
    "0123456789abcdef0123456789abcdef" ++
    "fedcba9876543210fedcba9876543210";
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
        target: TransportTarget,
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

        const runtime_id = switch (target) {
            .loopback => |port| if (port == 43_127) self.runtime_a else self.runtime_b,
            .direct_https => self.runtime_a,
        };
        if (parsed.request.target) |request_target| {
            if (!std.mem.eql(u8, request_target.runtime_id, runtime_id) or
                !std.mem.eql(u8, request_target.instance_id, TEST_INSTANCE))
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
    /// Targeted calls answer 401 (stale bearer after a daemon restart); the
    /// untargeted handshake keeps working so a re-minted token can recover.
    auth_failure,
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
        _: TransportTarget,
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
        if (is_targeted and mode == .auth_failure) return error.AuthenticationRequired;
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
                .normal, .network_failure, .auth_failure => headless.encodeOkResponse(
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

const TEST_DEVICE_ID = "0123456789abcdef0123456789abcdef";
const TEST_MINTED_TOKEN = "0123456789abcdef" ** 4;

const TestAccessMode = enum(u8) {
    normal,
    /// The daemon explicitly rejected the device credential (gateway 401).
    reject,
    /// The gateway cannot reach the daemon (503): outage, not revocation.
    unavailable,
};

/// Hermetic Pair-auth gateway seam serving access-token mints, so restart-
/// shaped bearer invalidation and authoritative device rejection can both be
/// exercised without a network.
const TestAccessGateway = struct {
    mode: std.atomic.Value(u8) = .init(@intFromEnum(TestAccessMode.normal)),
    mints: std.atomic.Value(usize) = .init(0),
    device_authorized: std.atomic.Value(bool) = .init(true),
    retained: std.atomic.Value(usize) = .init(0),

    fn setMode(self: *TestAccessGateway, mode: TestAccessMode) void {
        self.mode.store(@intFromEnum(mode), .release);
    }

    fn retain(raw_context: ?*anyopaque) void {
        const self: *TestAccessGateway = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchAdd(1, .acq_rel);
    }

    fn release(raw_context: ?*anyopaque) void {
        const self: *TestAccessGateway = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchSub(1, .acq_rel);
    }

    fn call(
        raw_context: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: TransportTarget,
        path: []const u8,
        authorization: ?[]const u8,
        _: []const u8,
    ) pair_client.Error![]u8 {
        const self: *TestAccessGateway = @ptrCast(@alignCast(raw_context.?));
        if (!std.mem.eql(u8, path, access_protocol.HTTP_ACCESS_TOKEN_PATH)) {
            return error.ProtocolRejected;
        }
        // Every mint must present the stored device credential; recovery from
        // a stale bearer must never invent or drop it.
        const expected_header = "VerdeDevice " ++ TEST_DEVICE_ID ++ "." ++ TEST_DEVICE_CREDENTIAL;
        if (authorization == null or !std.mem.eql(u8, authorization.?, expected_header)) {
            self.device_authorized.store(false, .release);
        }
        switch (@as(TestAccessMode, @enumFromInt(self.mode.load(.acquire)))) {
            .reject => return error.AuthenticationRequired,
            .unavailable => return error.ServerUnavailable,
            .normal => {},
        }
        _ = self.mints.fetchAdd(1, .acq_rel);
        return std.fmt.allocPrint(
            allocator,
            "{{\"access_protocol_version\":{d},\"access_token\":\"{s}\",\"token_type\":\"{s}\",\"expires_at_ms\":{d}}}",
            .{
                access_protocol.ACCESS_PROTOCOL_VERSION,
                TEST_MINTED_TOKEN,
                access_protocol.ACCESS_TOKEN_TYPE,
                std.math.maxInt(i64),
            },
        ) catch error.OutOfMemory;
    }

    fn backend(self: *TestAccessGateway) AccessBackend {
        return .{
            .context = self,
            .call = call,
            .retain_context = retain,
            .release_context = release,
        };
    }
};

fn createPairedDirectTestProfile(label: []const u8) !profile.Profile {
    var configured = try profile.Profile.createPairedDirect(
        std.testing.allocator,
        std.testing.io,
        label,
        "https://runtime.example",
        null,
    );
    errdefer configured.deinit(std.testing.allocator);
    try configured.setPairedDevice(
        std.testing.allocator,
        TEST_DEVICE_ID,
        "verde-runtime/test/device",
    );
    try configured.setExpectedIdentity(std.testing.allocator, TEST_RUNTIME_A, TEST_INSTANCE);
    return configured;
}

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
    try std.testing.expect(pending.last_successful_connection_ms != null);
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
            try std.testing.expectEqual(FailureReason.unknown, response.failure_reason.?);
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

test "typed RPC failure reasons use method and code rather than messages" {
    try std.testing.expectEqual(
        connection.FailureKind.server_unavailable,
        mapTransportFailure(error.ServerUnavailable),
    );
    try std.testing.expectEqual(
        connection.FailureKind.wrong_service,
        mapTransportFailure(error.WrongService),
    );
    try std.testing.expectEqual(
        FailureReason.workspace_binding_missing,
        classifyRpcFailure("workspace.repository.manifest.get", headless.protocol.ERR_RESOURCE_NOT_FOUND),
    );
    try std.testing.expectEqual(
        FailureReason.unknown,
        classifyRpcFailure("chat.turn.start", headless.protocol.ERR_RESOURCE_NOT_FOUND),
    );
    try std.testing.expectEqual(
        FailureReason.provider_unavailable,
        classifyRpcFailure("chat.turn.start", headless.protocol.ERR_PROVIDER_UNAVAILABLE),
    );
    try std.testing.expectEqual(
        FailureReason.unknown,
        classifyRpcFailure("chat.turn.start", headless.protocol.ERR_CAPABILITY_UNAVAILABLE),
    );
    try std.testing.expectEqual(
        FailureReason.unknown,
        classifyRpcFailure("chat.turn.start", headless.protocol.ERR_INVALID_STATE),
    );
    try std.testing.expectEqual(
        FailureReason.unknown,
        classifyRpcFailure("chat.turn.tail", headless.protocol.ERR_RESOURCE_NOT_FOUND),
    );
    try std.testing.expectEqual(
        FailureReason.unknown,
        classifyRpcFailure("chat.message.append", headless.protocol.ERR_INVALID_PARAMS),
    );
    try std.testing.expectEqual(
        FailureReason.unknown,
        classifyRpcFailure("workspace.repository.binding.upsert", headless.protocol.ERR_RESOURCE_NOT_FOUND),
    );
    try std.testing.expectEqual(
        FailureReason.provider_unavailable,
        classifyRpcFailure("providers.status", headless.protocol.ERR_CAPABILITY_UNAVAILABLE),
    );
    try std.testing.expectEqual(
        FailureReason.unknown,
        classifyRpcFailure("core.snapshot", headless.protocol.ERR_INTERNAL),
    );

    const unavailable: headless.providers_protocol.ProviderStatus = .{
        .provider = "codex",
        .label = "Codex",
        .surfaces = .{ .native_chat = true },
        .installed = false,
        .state = "missing",
        .authentication = "unknown",
    };
    try std.testing.expectEqual(FailureReason.provider_unavailable, classifyProviderStatus(unavailable).?);
    const signed_out: headless.providers_protocol.ProviderStatus = .{
        .provider = "codex",
        .label = "Codex",
        .surfaces = .{ .native_chat = true },
        .installed = true,
        .state = "ready",
        .authentication = "unauthenticated",
    };
    try std.testing.expectEqual(FailureReason.provider_not_authenticated, classifyProviderStatus(signed_out).?);
    const ready: headless.providers_protocol.ProviderStatus = .{
        .provider = "codex",
        .label = "Codex",
        .surfaces = .{ .native_chat = true },
        .installed = true,
        .state = "ready",
        .authentication = "authenticated",
    };
    try std.testing.expect(classifyProviderStatus(ready) == null);
}

test "transient and wrong-service failures preserve paired device credentials" {
    var configured = try profile.Profile.createPairedDirect(
        std.testing.allocator,
        std.testing.io,
        "Paired Direct",
        "https://runtime.example",
        null,
    );
    defer configured.deinit(std.testing.allocator);
    try configured.setPairedDevice(
        std.testing.allocator,
        "0123456789abcdef0123456789abcdef",
        "verde-runtime/test/device",
    );
    try configured.setExpectedIdentity(std.testing.allocator, TEST_RUNTIME_A, TEST_INSTANCE);

    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .durable_credentials = false,
    });
    defer manager.deinit();
    try manager.noteCredentialHydration(configured.id, .backend_unavailable);
    const backend_failure = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(CredentialHydration.backend_unavailable, backend_failure.credential_hydration);
    try std.testing.expectEqual(FailureReason.credential_store_unavailable, backend_failure.failure_reason.?);
    try manager.noteCredentialHydration(configured.id, .invalid);
    const invalid = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(CredentialHydration.invalid, invalid.credential_hydration);
    try std.testing.expectEqual(FailureReason.credential_invalid, invalid.failure_reason.?);
    try manager.hydrateDeviceCredential(configured.id, TEST_DEVICE_CREDENTIAL);
    const entry = manager.findEntry(configured.id).?;
    const first_generation = try entry.connection_state.enable();
    _ = try entry.connection_state.failAttempt(first_generation, .network, 1_000, 0);

    const offline = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.reconnecting, offline.phase);
    try std.testing.expectEqual(FailureReason.transport_offline, offline.failure_reason.?);
    try std.testing.expect(offline.device_credential_held);
    try std.testing.expect(offline.automatic_retry_scheduled);
    try std.testing.expect(offline.manual_retry_available);

    const retry_generation = try entry.connection_state.retryFailed();
    _ = try entry.connection_state.failAttempt(retry_generation, .wrong_service, 1_100, 0);
    const wrong_service = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.failed, wrong_service.phase);
    try std.testing.expectEqual(FailureReason.wrong_service, wrong_service.failure_reason.?);
    try std.testing.expect(wrong_service.device_credential_held);
    try std.testing.expect(wrong_service.failure.? != .missing_credential);

    // A generic transport 401 (stale bearer after a daemon restart, proxy
    // misfire) is not proof of revocation: it must present as a plain
    // authentication failure with the credential intact.
    const auth_generation = try entry.connection_state.retryFailed();
    _ = try entry.connection_state.failAttempt(auth_generation, .authentication, 1_200, 0);
    const generic_auth = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(FailureReason.authentication_required, generic_auth.failure_reason.?);
    try std.testing.expect(generic_auth.device_credential_held);
    try std.testing.expect(generic_auth.manual_retry_available);

    // Only the device-auth endpoint's explicit rejection claims revocation.
    entry.device_auth_rejected = true;
    const revoked = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(FailureReason.device_credential_revoked, revoked.failure_reason.?);
    try std.testing.expect(!revoked.automatic_retry_scheduled);
    try std.testing.expect(revoked.device_credential_held);

    // A manual retry re-probes the same credential; the revoked marker must
    // not survive the fresh attempt unless the runtime rejects it again.
    try manager.retry(configured.id, 1_300);
    try std.testing.expect(!entry.device_auth_rejected);
    try std.testing.expect(manager.snapshot(configured.id).?.failure_reason == null);
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

    const connected = manager.snapshot(configured.id).?;
    const first_heartbeat_ms = connected.last_heartbeat_ms.?;
    const last_successful_connection_ms = connected.last_successful_connection_ms.?;
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
    try std.testing.expectEqual(FailureReason.transport_offline, disconnected.failure_reason.?);
    try std.testing.expect(disconnected.retry_at_ms != null);
    try std.testing.expect(disconnected.automatic_retry_scheduled);
    try std.testing.expect(disconnected.retry_attempt > 0);
    try std.testing.expect(disconnected.retry_delay_ms != null);
    try std.testing.expectEqual(last_successful_connection_ms, disconnected.last_successful_connection_ms.?);
    try std.testing.expect(!disconnected.execution_ready);
    try std.testing.expectEqual(@as(usize, 2), rpc.targeted_heartbeats.load(.acquire));

    rpc.setMode(.normal);
    try waitForExecutionReady(&manager, configured.id, disconnected.retry_at_ms.?);
    try std.testing.expectEqual(connection.Phase.ready, manager.snapshot(configured.id).?.phase);
    try std.testing.expectEqual(@as(usize, 3), rpc.targeted_heartbeats.load(.acquire));
    try std.testing.expect(rpc.valid_targets.load(.acquire));
}

test "daemon restart stale bearer re-mints silently and recovers with the same device credential" {
    var configured = try createPairedDirectTestProfile("Restart VM");
    defer configured.deinit(std.testing.allocator);
    var rpc: TargetRpc = .{ .expected_token = TEST_MINTED_TOKEN };
    var access: TestAccessGateway = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .rpc_backend = rpc.backend(),
        .access_backend = access.backend(),
    });
    defer manager.deinit();
    try manager.hydrateDeviceCredential(configured.id, TEST_DEVICE_CREDENTIAL);
    try manager.enable(configured.id, 0);
    try waitForExecutionReady(&manager, configured.id, 5_000);
    const mints_before = access.mints.load(.acquire);
    const due_ms = manager.snapshot(configured.id).?.last_heartbeat_ms.? + HEARTBEAT_INTERVAL_MS;

    // The daemon restarts: its process-memory bearer table is gone while the
    // paired device record stays valid, so targeted calls answer 401.
    rpc.setMode(.auth_failure);
    for (0..2_000) |iteration| {
        try manager.poll(due_ms + iteration);
        if (!manager.snapshot(configured.id).?.execution_ready) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestExpectedStaleBearer;

    // The 401 reads as a stale bearer: the same ready session, no failure
    // classification, and never a revoked credential or a pairing flow.
    const stale = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(connection.Phase.ready, stale.phase);
    try std.testing.expect(stale.failure_reason == null);
    try std.testing.expectEqual(PairingState.none, stale.pairing_state);

    // The daemon is reachable again: one silent re-mint with the identical
    // device credential restores health without any user action.
    rpc.setMode(.normal);
    try waitForExecutionReady(&manager, configured.id, due_ms + 2_000);
    const recovered = manager.snapshot(configured.id).?;
    try std.testing.expect(recovered.failure_reason == null);
    try std.testing.expect(recovered.device_credential_held);
    // Refreshed runtime limits flow into the same snapshot chat send routes on.
    try std.testing.expectEqual(@as(usize, 1_048_576), recovered.max_attachment_bytes);
    try std.testing.expect(access.mints.load(.acquire) > mints_before);
    try std.testing.expect(access.device_authorized.load(.acquire));
    try std.testing.expect(rpc.valid_targets.load(.acquire));
}

test "persistent 401 after a fresh mint escalates to a generic auth failure, never revoked" {
    var configured = try createPairedDirectTestProfile("Escalation VM");
    defer configured.deinit(std.testing.allocator);
    var rpc: TargetRpc = .{ .expected_token = TEST_MINTED_TOKEN };
    var access: TestAccessGateway = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .rpc_backend = rpc.backend(),
        .access_backend = access.backend(),
    });
    defer manager.deinit();
    try manager.hydrateDeviceCredential(configured.id, TEST_DEVICE_CREDENTIAL);
    try manager.enable(configured.id, 0);
    try waitForExecutionReady(&manager, configured.id, 5_000);
    const mints_before = access.mints.load(.acquire);
    const due_ms = manager.snapshot(configured.id).?.last_heartbeat_ms.? + HEARTBEAT_INTERVAL_MS;

    // Mints keep succeeding but the runtime keeps answering 401: after the
    // one silent recovery attempt this must surface as a visible generic
    // authentication failure with a manual retry, never as revocation.
    rpc.setMode(.auth_failure);
    for (0..2_000) |iteration| {
        try manager.poll(due_ms + iteration);
        if (manager.snapshot(configured.id).?.phase == .failed) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestExpectedEscalation;

    const failed = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(FailureReason.authentication_required, failed.failure_reason.?);
    try std.testing.expect(!failed.automatic_retry_scheduled);
    try std.testing.expect(failed.manual_retry_available);
    try std.testing.expect(failed.device_credential_held);
    try std.testing.expectEqual(mints_before + 1, access.mints.load(.acquire));

    // Manual Reconnect against a healthy runtime recovers with the same
    // credential and clears the stale failure.
    rpc.setMode(.normal);
    try manager.retry(configured.id, due_ms + 3_000);
    try waitForExecutionReady(&manager, configured.id, due_ms + 3_000);
    try std.testing.expect(manager.snapshot(configured.id).?.failure_reason == null);
}

test "explicit device-auth rejection is the only path into device revoked" {
    var configured = try createPairedDirectTestProfile("Revoked VM Auth");
    defer configured.deinit(std.testing.allocator);
    var rpc: TargetRpc = .{ .expected_token = TEST_MINTED_TOKEN };
    var access: TestAccessGateway = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .rpc_backend = rpc.backend(),
        .access_backend = access.backend(),
    });
    defer manager.deinit();
    try manager.hydrateDeviceCredential(configured.id, TEST_DEVICE_CREDENTIAL);
    try manager.enable(configured.id, 0);
    try waitForExecutionReady(&manager, configured.id, 5_000);
    const due_ms = manager.snapshot(configured.id).?.last_heartbeat_ms.? + HEARTBEAT_INTERVAL_MS;

    // The recovery mint is explicitly rejected by the device-auth endpoint:
    // that, and only that, presents as a revoked device offering Re-pair.
    access.setMode(.reject);
    rpc.setMode(.auth_failure);
    for (0..2_000) |iteration| {
        try manager.poll(due_ms + iteration);
        if (manager.snapshot(configured.id).?.phase == .failed) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestExpectedRejection;

    const revoked = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(FailureReason.device_credential_revoked, revoked.failure_reason.?);
    try std.testing.expect(!revoked.automatic_retry_scheduled);
    try std.testing.expect(revoked.device_credential_held);

    // If the runtime un-revokes the device, a manual retry re-proves the
    // stored credential instead of forcing a re-pair.
    access.setMode(.normal);
    rpc.setMode(.normal);
    try manager.retry(configured.id, due_ms + 3_000);
    try waitForExecutionReady(&manager, configured.id, due_ms + 3_000);
    try std.testing.expect(manager.snapshot(configured.id).?.failure_reason == null);
}

test "gateway outage during bearer recovery schedules backoff instead of revocation" {
    var configured = try createPairedDirectTestProfile("Outage VM");
    defer configured.deinit(std.testing.allocator);
    var rpc: TargetRpc = .{ .expected_token = TEST_MINTED_TOKEN };
    var access: TestAccessGateway = .{};
    var manager = try Manager.init(std.testing.allocator, std.testing.io, &.{configured}, .{
        .rpc_backend = rpc.backend(),
        .access_backend = access.backend(),
    });
    defer manager.deinit();
    try manager.hydrateDeviceCredential(configured.id, TEST_DEVICE_CREDENTIAL);
    try manager.enable(configured.id, 0);
    try waitForExecutionReady(&manager, configured.id, 5_000);
    const due_ms = manager.snapshot(configured.id).?.last_heartbeat_ms.? + HEARTBEAT_INTERVAL_MS;

    // Restart window: the bearer is stale and the gateway cannot reach the
    // daemon yet. This is an outage with bounded automatic retries.
    access.setMode(.unavailable);
    rpc.setMode(.auth_failure);
    for (0..2_000) |iteration| {
        try manager.poll(due_ms + iteration);
        if (manager.snapshot(configured.id).?.phase == .reconnecting) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    } else return error.TestExpectedOutageBackoff;

    const outage = manager.snapshot(configured.id).?;
    try std.testing.expectEqual(FailureReason.transport_offline, outage.failure_reason.?);
    try std.testing.expect(outage.automatic_retry_scheduled);
    try std.testing.expect(outage.retry_at_ms != null);
    try std.testing.expect(outage.device_credential_held);

    // Services come back: the scheduled retry reconnects with the held
    // credential, no user action and no re-pair.
    access.setMode(.normal);
    rpc.setMode(.normal);
    try waitForExecutionReady(&manager, configured.id, outage.retry_at_ms.?);
    try std.testing.expect(manager.snapshot(configured.id).?.failure_reason == null);
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
