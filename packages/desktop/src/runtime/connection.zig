//! Per-profile connection state and remote-runtime handshake ownership.
//!
//! This module never launches, replaces, or restarts a daemon. It only models
//! the desktop side of connecting to an already-managed runtime. Handshake
//! work may run away from the owner thread; its owned outcome is applied with
//! the generation captured for that attempt so stale work cannot win.

const std = @import("std");
const headless = @import("headless");

pub const RECONNECT_BASE_DELAY_MS: u64 = 500;
pub const RECONNECT_MAX_DELAY_MS: u64 = 30_000;
pub const RECONNECT_MAX_JITTER_MS: u32 = 500;
pub const MAX_SERVER_VERSION_BYTES: usize = 128;
pub const MAX_RUNTIME_CAPABILITIES: usize = 64;
pub const MAX_RUNTIME_CAPABILITY_BYTES: usize = 128;
pub const MAX_ADVERTISED_ATTACHMENT_BYTES: usize = 50 * 1024 * 1024;
pub const MAX_ADVERTISED_PARK_MS: u32 = 60_000;

pub const Phase = enum {
    disabled,
    connecting,
    handshaking,
    awaiting_trust,
    ready,
    failed,
    reconnecting,
};

/// Stable failure classes for retry policy and machine-readable diagnostics.
pub const FailureKind = enum {
    authentication,
    network,
    server_unavailable,
    identity,
    protocol,
    wrong_service,
    resource,

    pub fn retryable(self: FailureKind) bool {
        return self == .network or self == .server_unavailable;
    }
};

pub const Retry = struct {
    failure: FailureKind,
    attempt: u8,
    delay_ms: u64,
    retry_at_ms: u64,
};

pub const State = union(Phase) {
    disabled,
    connecting,
    handshaking,
    awaiting_trust,
    ready,
    failed: FailureKind,
    reconnecting: Retry,
};

pub const ApplyResult = enum {
    applied,
    stale,
};

pub const IdentityPinAdoption = enum {
    committed_current,
    reconnect_required,
    installed_disabled,
};

/// Errors an adapter may return before a valid headless response exists.
/// Adapters collapse platform-specific socket/HTTP errors into this boundary;
/// response parsing and protocol negotiation remain owned by this module.
pub const TransportError = error{
    OutOfMemory,
    AuthenticationRequired,
    NetworkUnavailable,
    RequestTimedOut,
    ConnectionClosed,
    ServerUnavailable,
    WrongService,
    ProtocolRejected,
};

/// Returns response JSON allocated by `allocator`. The typed headless client
/// frees it after parsing.
pub const TransportFn = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    request_json: []const u8,
) TransportError![]u8;

/// Handshake metadata with ownership independent of the response parse arena.
pub const OwnedRuntimeMetadata = struct {
    allocator: std.mem.Allocator,
    runtime_id: []u8,
    instance_id: []u8,
    server_version: []u8,
    runtime_protocol: headless.RuntimeProtocolVersion,
    runtime_capabilities: [][]u8,
    limits: headless.RuntimeLimits,
    headless_protocol_version: u32,
    headless_min_supported: u32,
    headless_max_supported: u32,
    negotiated_headless_protocol_version: u32,
    session_protocol_version: u32,
    capabilities: headless.Capabilities,

    fn cloneStatus(
        allocator: std.mem.Allocator,
        status: headless.StatusResult,
        negotiated_version: u32,
    ) !OwnedRuntimeMetadata {
        const runtime_id = try allocator.dupe(u8, status.runtime_id);
        errdefer allocator.free(runtime_id);
        const instance_id = try allocator.dupe(u8, status.instance_id);
        errdefer allocator.free(instance_id);
        const server_version = try allocator.dupe(u8, status.server_version);
        errdefer allocator.free(server_version);

        const runtime_capabilities = try allocator.alloc([]u8, status.runtime_capabilities.len);
        var initialized_capabilities: usize = 0;
        errdefer {
            for (runtime_capabilities[0..initialized_capabilities]) |capability| allocator.free(capability);
            allocator.free(runtime_capabilities);
        }
        for (status.runtime_capabilities, 0..) |capability, index| {
            runtime_capabilities[index] = try allocator.dupe(u8, capability);
            initialized_capabilities += 1;
        }

        return .{
            .allocator = allocator,
            .runtime_id = runtime_id,
            .instance_id = instance_id,
            .server_version = server_version,
            .runtime_protocol = status.protocol,
            .runtime_capabilities = runtime_capabilities,
            .limits = status.limits,
            .headless_protocol_version = status.headless_protocol_version,
            .headless_min_supported = status.min_supported,
            .headless_max_supported = status.max_supported,
            .negotiated_headless_protocol_version = negotiated_version,
            .session_protocol_version = status.protocol_version,
            .capabilities = status.capabilities,
        };
    }

    fn borrowedStatus(self: *const OwnedRuntimeMetadata) headless.StatusResult {
        return .{
            .runtime_id = self.runtime_id,
            .instance_id = self.instance_id,
            .server_version = self.server_version,
            .protocol = self.runtime_protocol,
            .runtime_capabilities = self.runtime_capabilities,
            .limits = self.limits,
            .headless_protocol_version = self.headless_protocol_version,
            .min_supported = self.headless_min_supported,
            .max_supported = self.headless_max_supported,
            .protocol_version = self.session_protocol_version,
            .pid = 0,
            .session_count = 0,
            .chat_turn_count = 0,
            .capabilities = self.capabilities,
        };
    }

    pub fn deinit(self: *OwnedRuntimeMetadata) void {
        self.allocator.free(self.runtime_id);
        self.allocator.free(self.instance_id);
        self.allocator.free(self.server_version);
        for (self.runtime_capabilities) |capability| self.allocator.free(capability);
        self.allocator.free(self.runtime_capabilities);
        self.* = undefined;
    }
};

/// Result produced by a transport worker. `completeHandshake` consumes it on
/// every path, including stale and invalid-transition paths.
pub const HandshakeOutcome = union(enum) {
    verified: OwnedRuntimeMetadata,
    failed: FailureKind,

    pub fn deinit(self: *HandshakeOutcome) void {
        switch (self.*) {
            .verified => |*metadata| metadata.deinit(),
            .failed => {},
        }
        self.* = undefined;
    }
};

const TransportBridge = struct {
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    send_fn: TransportFn,

    fn send(ctx: *anyopaque, request_json: []const u8) anyerror![]u8 {
        const self: *TransportBridge = @ptrCast(@alignCast(ctx));
        return try self.send_fn(self.ctx, self.allocator, request_json);
    }
};

/// Call and parse `core.status`, negotiate the headless protocol range, verify
/// the stable runtime identity, and return a self-contained result. The
/// expected ID should be the attempt's snapshot of its profile pin.
pub fn performHandshakeAlloc(
    allocator: std.mem.Allocator,
    expected_runtime_id: ?[]const u8,
    transport_ctx: *anyopaque,
    transport: TransportFn,
) !HandshakeOutcome {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var bridge: TransportBridge = .{
        .allocator = scratch,
        .ctx = transport_ctx,
        .send_fn = transport,
    };
    var client = headless.Client.init(scratch, &bridge, TransportBridge.send);
    const handshake = client.handshakeRuntime(expected_runtime_id) catch |err| {
        // Headless JSON encoding writes through an allocating writer, whose
        // allocator exhaustion is surfaced as WriteFailed at this boundary.
        if (err == error.OutOfMemory or err == error.WriteFailed) return error.OutOfMemory;
        return .{ .failed = classifyHandshakeError(err) };
    };
    validateIdentityPart(handshake.status.runtime_id) catch return .{ .failed = .identity };
    validateIdentityPart(handshake.status.instance_id) catch return .{ .failed = .identity };
    validateRuntimeStatus(handshake.status) catch return .{ .failed = .protocol };
    return .{
        .verified = try OwnedRuntimeMetadata.cloneStatus(
            allocator,
            handshake.status,
            handshake.negotiated_version,
        ),
    };
}

/// Bounds all allocation-amplifying runtime status fields before a caller
/// retains or projects them. Heartbeats reuse this after their targeted call.
pub fn validateRuntimeStatus(status: headless.StatusResult) !void {
    if (status.server_version.len == 0 or
        status.server_version.len > MAX_SERVER_VERSION_BYTES or
        !std.unicode.utf8ValidateSlice(status.server_version))
    {
        return error.InvalidServerVersion;
    }
    for (status.server_version) |byte| {
        if (std.ascii.isControl(byte)) return error.InvalidServerVersion;
    }
    if (status.runtime_capabilities.len > MAX_RUNTIME_CAPABILITIES) {
        return error.TooManyRuntimeCapabilities;
    }
    for (status.runtime_capabilities) |capability| {
        if (capability.len == 0 or capability.len > MAX_RUNTIME_CAPABILITY_BYTES) {
            return error.InvalidRuntimeCapability;
        }
        for (capability) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
                return error.InvalidRuntimeCapability;
            }
        }
    }

    const limits = status.limits;
    if (limits.max_request_bytes == 0 or
        limits.max_request_bytes > headless.protocol.RUNTIME_MAX_MESSAGE_BYTES or
        limits.max_response_bytes == 0 or
        limits.max_response_bytes > headless.protocol.RUNTIME_MAX_MESSAGE_BYTES or
        limits.max_attachment_bytes == 0 or
        limits.max_attachment_bytes > MAX_ADVERTISED_ATTACHMENT_BYTES or
        limits.max_parked_wait_ms == 0 or
        limits.max_parked_wait_ms > MAX_ADVERTISED_PARK_MS or
        limits.default_page_items == 0 or
        limits.max_page_items == 0 or
        limits.default_page_items > limits.max_page_items or
        limits.max_page_items > headless.store_protocol.MAX_PAGE_ITEMS)
    {
        return error.InvalidRuntimeLimits;
    }
}

fn classifyHandshakeError(err: anyerror) FailureKind {
    return switch (err) {
        error.AuthenticationRequired => .authentication,
        error.NetworkUnavailable,
        error.RequestTimedOut,
        error.ConnectionClosed,
        => .network,
        error.ServerUnavailable => .server_unavailable,
        error.WrongService => .wrong_service,
        error.RuntimeIdentityMissing,
        error.RuntimeIdentityMismatch,
        => .identity,
        error.OutOfMemory => .resource,
        else => .protocol,
    };
}

/// Exponential reconnect delay with caller-supplied jitter. The jitter is
/// bounded and the final delay saturates at `RECONNECT_MAX_DELAY_MS`.
pub fn reconnectDelayMs(attempt: u8, jitter_ms: u32) !u64 {
    if (attempt == 0) return error.InvalidReconnectAttempt;
    if (jitter_ms > RECONNECT_MAX_JITTER_MS) return error.ReconnectJitterOutOfRange;

    var delay = RECONNECT_BASE_DELAY_MS;
    var remaining_doublings: u8 = attempt - 1;
    while (remaining_doublings > 0 and delay < RECONNECT_MAX_DELAY_MS) : (remaining_doublings -= 1) {
        delay = @min(delay * 2, RECONNECT_MAX_DELAY_MS);
    }
    return @min(delay + jitter_ms, RECONNECT_MAX_DELAY_MS);
}

/// Stable runtime identities are exactly 128-bit lowercase hexadecimal values.
pub fn validateRuntimeId(runtime_id: []const u8) !void {
    return validateIdentityPart(runtime_id);
}

fn validateIdentityPart(value: []const u8) !void {
    if (value.len != 32) return error.InvalidRuntimeIdentity;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidRuntimeIdentity;
        }
    }
}

pub const Connection = struct {
    allocator: std.mem.Allocator,
    profile_id: []u8,
    expected_runtime_id: ?[]u8,
    expected_instance_id: ?[]u8,
    state: State = .disabled,
    generation: u64 = 0,
    consecutive_transient_failures: u8 = 0,
    verified_metadata: ?OwnedRuntimeMetadata = null,

    pub fn init(
        allocator: std.mem.Allocator,
        profile_id: []const u8,
        expected_runtime_id: ?[]const u8,
        expected_instance_id: ?[]const u8,
    ) !Connection {
        if (profile_id.len == 0) return error.EmptyProfileId;
        if (expected_runtime_id) |runtime_id| try validateRuntimeId(runtime_id);
        if (expected_instance_id) |instance_id| {
            if (expected_runtime_id == null) return error.InvalidExpectedIdentityPair;
            try validateIdentityPart(instance_id);
        }

        const owned_profile_id = try allocator.dupe(u8, profile_id);
        errdefer allocator.free(owned_profile_id);
        const owned_runtime_id = if (expected_runtime_id) |runtime_id|
            try allocator.dupe(u8, runtime_id)
        else
            null;
        errdefer if (owned_runtime_id) |runtime_id| allocator.free(runtime_id);
        const owned_instance_id = if (expected_instance_id) |instance_id|
            try allocator.dupe(u8, instance_id)
        else
            null;
        return .{
            .allocator = allocator,
            .profile_id = owned_profile_id,
            .expected_runtime_id = owned_runtime_id,
            .expected_instance_id = owned_instance_id,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.clearVerifiedMetadata();
        self.allocator.free(self.profile_id);
        if (self.expected_runtime_id) |runtime_id| self.allocator.free(runtime_id);
        if (self.expected_instance_id) |instance_id| self.allocator.free(instance_id);
        self.* = undefined;
    }

    pub fn phase(self: *const Connection) Phase {
        return switch (self.state) {
            .disabled => .disabled,
            .connecting => .connecting,
            .handshaking => .handshaking,
            .awaiting_trust => .awaiting_trust,
            .ready => .ready,
            .failed => .failed,
            .reconnecting => .reconnecting,
        };
    }

    pub fn profileId(self: *const Connection) []const u8 {
        return self.profile_id;
    }

    pub fn expectedRuntimeId(self: *const Connection) ?[]const u8 {
        return self.expected_runtime_id;
    }

    pub fn expectedInstanceId(self: *const Connection) ?[]const u8 {
        return self.expected_instance_id;
    }

    /// Metadata is usable only while ready; reconnects never project a stale
    /// daemon snapshot as if it belonged to the current connection.
    pub fn metadata(self: *const Connection) ?*const OwnedRuntimeMetadata {
        if (self.phase() != .ready) return null;
        return if (self.verified_metadata) |*verified| verified else unreachable;
    }

    /// Verified metadata that is intentionally not executable/routable until
    /// the caller durably persists and commits its first-contact identity.
    pub fn pendingTrustMetadata(self: *const Connection) ?*const OwnedRuntimeMetadata {
        if (self.phase() != .awaiting_trust) return null;
        return if (self.verified_metadata) |*verified| verified else unreachable;
    }

    /// Installs the identity pair reread from durable storage. Only the exact
    /// still-pending proposal may become ready in place; every stale/conflict
    /// case invalidates current work and reconnects against the disk pin.
    pub fn adoptPersistedIdentity(
        self: *Connection,
        proposal_generation: u64,
        proposal_runtime_id: []const u8,
        proposal_instance_id: []const u8,
        persisted_runtime_id: []const u8,
        persisted_instance_id: []const u8,
        allow_commit_current: bool,
    ) !IdentityPinAdoption {
        try validateRuntimeId(proposal_runtime_id);
        try validateIdentityPart(proposal_instance_id);
        try validateRuntimeId(persisted_runtime_id);
        try validateIdentityPart(persisted_instance_id);

        const verified = self.pendingTrustMetadata();
        const commits_current = allow_commit_current and
            proposal_generation == self.generation and
            verified != null and
            std.mem.eql(u8, verified.?.runtime_id, proposal_runtime_id) and
            std.mem.eql(u8, verified.?.instance_id, proposal_instance_id) and
            std.mem.eql(u8, proposal_runtime_id, persisted_runtime_id) and
            std.mem.eql(u8, proposal_instance_id, persisted_instance_id);
        const reconnect = self.phase() != .disabled and !commits_current;
        const next_generation = if (reconnect) try self.nextGeneration() else self.generation;

        const next_runtime_id = try self.allocator.dupe(u8, persisted_runtime_id);
        errdefer self.allocator.free(next_runtime_id);
        const next_instance_id = try self.allocator.dupe(u8, persisted_instance_id);
        if (self.expected_runtime_id) |runtime_id| self.allocator.free(runtime_id);
        if (self.expected_instance_id) |instance_id| self.allocator.free(instance_id);
        self.expected_runtime_id = next_runtime_id;
        self.expected_instance_id = next_instance_id;

        if (commits_current) {
            self.state = .ready;
            return .committed_current;
        }
        self.clearVerifiedMetadata();
        self.consecutive_transient_failures = 0;
        if (!reconnect) return .installed_disabled;
        self.generation = next_generation;
        self.state = .connecting;
        return .reconnect_required;
    }

    pub fn lastFailure(self: *const Connection) ?FailureKind {
        return switch (self.state) {
            .failed => |failure| failure,
            .reconnecting => |retry| retry.failure,
            else => null,
        };
    }

    /// Enable a disabled profile and begin a new transport attempt.
    pub fn enable(self: *Connection) !u64 {
        if (self.phase() != .disabled) return error.InvalidConnectionTransition;
        const next_generation = try self.nextGeneration();
        self.clearVerifiedMetadata();
        self.consecutive_transient_failures = 0;
        self.generation = next_generation;
        self.state = .connecting;
        return next_generation;
    }

    /// Disable this profile. Advancing the generation invalidates all work
    /// already running for the previous attempt.
    pub fn disable(self: *Connection) !void {
        const next_generation = try self.nextGeneration();
        self.clearVerifiedMetadata();
        self.consecutive_transient_failures = 0;
        self.generation = next_generation;
        self.state = .disabled;
    }

    /// Advance a connecting transport into protocol handshaking.
    pub fn beginHandshake(self: *Connection, generation: u64) !ApplyResult {
        if (generation != self.generation) return .stale;
        if (self.phase() != .connecting) return error.InvalidConnectionTransition;
        self.state = .handshaking;
        return .applied;
    }

    /// Apply one worker-owned handshake result. The outcome is always consumed.
    pub fn completeHandshake(
        self: *Connection,
        generation: u64,
        outcome_value: HandshakeOutcome,
        now_ms: u64,
        jitter_ms: u32,
    ) !ApplyResult {
        var outcome = outcome_value;
        var outcome_owned = true;
        defer if (outcome_owned) outcome.deinit();

        if (generation != self.generation) return .stale;
        if (self.phase() != .handshaking) return error.InvalidConnectionTransition;
        switch (outcome) {
            .failed => |failure| return try self.applyFailure(failure, now_ms, jitter_ms),
            .verified => |verified| {
                validateRuntimeId(verified.runtime_id) catch {
                    return try self.applyFailure(.identity, now_ms, jitter_ms);
                };
                validateIdentityPart(verified.instance_id) catch {
                    return try self.applyFailure(.identity, now_ms, jitter_ms);
                };
                headless.verifyRuntimeHandshake(
                    verified.borrowedStatus(),
                    self.expected_runtime_id,
                ) catch |err| {
                    return try self.applyFailure(classifyHandshakeError(err), now_ms, jitter_ms);
                };
                if (self.expected_instance_id) |expected_instance_id| {
                    if (!std.mem.eql(u8, expected_instance_id, verified.instance_id)) {
                        return try self.applyFailure(.identity, now_ms, jitter_ms);
                    }
                }
                self.clearVerifiedMetadata();
                self.verified_metadata = verified;
                outcome_owned = false;
                self.consecutive_transient_failures = 0;
                self.state = if (self.expected_runtime_id == null or self.expected_instance_id == null)
                    .awaiting_trust
                else
                    .ready;
                return .applied;
            },
        }
    }

    /// Finish a transport attempt before handshaking, or report a handshake
    /// failure produced outside `performHandshakeAlloc`.
    pub fn failAttempt(
        self: *Connection,
        generation: u64,
        failure: FailureKind,
        now_ms: u64,
        jitter_ms: u32,
    ) !ApplyResult {
        if (generation != self.generation) return .stale;
        switch (self.phase()) {
            .connecting, .handshaking => {},
            else => return error.InvalidConnectionTransition,
        }
        return try self.applyFailure(failure, now_ms, jitter_ms);
    }

    /// Abort transport work that may still finish asynchronously. Advancing
    /// the generation before exposing the failure makes every late outcome
    /// from this attempt stale by construction.
    pub fn abortAttempt(
        self: *Connection,
        generation: u64,
        failure: FailureKind,
        now_ms: u64,
        jitter_ms: u32,
    ) !ApplyResult {
        if (generation != self.generation) return .stale;
        switch (self.phase()) {
            .connecting, .handshaking => {},
            else => return error.InvalidConnectionTransition,
        }
        const next_generation = try self.nextGeneration();
        const result = try self.applyFailure(failure, now_ms, jitter_ms);
        self.generation = next_generation;
        return result;
    }

    /// Start an immediate user-requested retry from either a terminal failure
    /// or a scheduled reconnect. No daemon process action or RPC replay is implied.
    pub fn retryFailed(self: *Connection) !u64 {
        switch (self.phase()) {
            .failed, .reconnecting => {},
            else => return error.InvalidConnectionTransition,
        }
        const next_generation = try self.nextGeneration();
        self.clearVerifiedMetadata();
        self.consecutive_transient_failures = 0;
        self.generation = next_generation;
        self.state = .connecting;
        return next_generation;
    }

    /// Start the next transport attempt once its deterministic deadline is due.
    pub fn reconnectIfDue(self: *Connection, now_ms: u64) !?u64 {
        const retry = switch (self.state) {
            .reconnecting => |retry| retry,
            else => return error.InvalidConnectionTransition,
        };
        if (now_ms < retry.retry_at_ms) return null;

        const next_generation = try self.nextGeneration();
        self.clearVerifiedMetadata();
        self.generation = next_generation;
        self.state = .connecting;
        return next_generation;
    }

    /// Record loss of a previously verified transport and schedule only a
    /// client reconnect. The remote daemon remains externally managed.
    pub fn connectionLost(self: *Connection, now_ms: u64, jitter_ms: u32) !void {
        switch (self.phase()) {
            .ready, .awaiting_trust => {},
            else => return error.InvalidConnectionTransition,
        }
        const retry = try self.nextRetry(.network, now_ms, jitter_ms);
        const next_generation = try self.nextGeneration();
        self.clearVerifiedMetadata();
        self.generation = next_generation;
        self.consecutive_transient_failures = retry.attempt;
        self.state = .{ .reconnecting = retry };
    }

    /// Invalidates a verified generation after a targeted heartbeat or RPC
    /// proves that its transport, identity, or protocol is no longer usable.
    pub fn postHandshakeFailure(
        self: *Connection,
        failure: FailureKind,
        now_ms: u64,
        jitter_ms: u32,
    ) !void {
        if (self.phase() != .ready) return error.InvalidConnectionTransition;
        const next_generation = try self.nextGeneration();
        _ = try self.applyFailure(failure, now_ms, jitter_ms);
        self.generation = next_generation;
    }

    fn applyFailure(
        self: *Connection,
        failure: FailureKind,
        now_ms: u64,
        jitter_ms: u32,
    ) !ApplyResult {
        self.clearVerifiedMetadata();
        if (failure.retryable()) {
            const retry = try self.nextRetry(failure, now_ms, jitter_ms);
            self.consecutive_transient_failures = retry.attempt;
            self.state = .{ .reconnecting = retry };
        } else {
            self.consecutive_transient_failures = 0;
            self.state = .{ .failed = failure };
        }
        return .applied;
    }

    fn nextRetry(self: *const Connection, failure: FailureKind, now_ms: u64, jitter_ms: u32) !Retry {
        std.debug.assert(failure.retryable());
        const attempt = if (self.consecutive_transient_failures == std.math.maxInt(u8))
            self.consecutive_transient_failures
        else
            self.consecutive_transient_failures + 1;
        const delay_ms = try reconnectDelayMs(attempt, jitter_ms);
        return .{
            .failure = failure,
            .attempt = attempt,
            .delay_ms = delay_ms,
            .retry_at_ms = now_ms +| delay_ms,
        };
    }

    fn nextGeneration(self: *const Connection) !u64 {
        if (self.generation == std.math.maxInt(u64)) return error.ConnectionGenerationExhausted;
        return self.generation + 1;
    }

    fn clearVerifiedMetadata(self: *Connection) void {
        if (self.verified_metadata) |*verified| verified.deinit();
        self.verified_metadata = null;
    }
};

const StatusTransport = struct {
    status: headless.StatusResult,
    calls: usize = 0,
    saw_core_status: bool = false,

    fn send(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        request_json: []const u8,
    ) TransportError![]u8 {
        const self: *StatusTransport = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.saw_core_status = std.mem.indexOf(u8, request_json, "\"method\":\"core.status\"") != null;
        return headless.encodeOkResponse(allocator, 1, self.status) catch return error.OutOfMemory;
    }
};

const ErrorTransport = struct {
    failure: FailureKind,

    fn send(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
    ) TransportError![]u8 {
        const self: *ErrorTransport = @ptrCast(@alignCast(ctx));
        return switch (self.failure) {
            .authentication => error.AuthenticationRequired,
            .network => error.NetworkUnavailable,
            .server_unavailable => error.ServerUnavailable,
            .wrong_service => error.WrongService,
            .identity, .protocol, .resource => unreachable,
        };
    }
};

const MalformedTransport = struct {
    fn send(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
    ) TransportError![]u8 {
        return allocator.dupe(u8, "not json") catch return error.OutOfMemory;
    }
};

const TEST_RUNTIME_ID = "0123456789abcdef0123456789abcdef";
const TEST_OTHER_RUNTIME_ID = "fedcba9876543210fedcba9876543210";
const TEST_INSTANCE_ID = "00112233445566778899aabbccddeeff";
const TEST_OTHER_INSTANCE_ID = "ffeeddccbbaa99887766554433221100";

fn validStatus() headless.StatusResult {
    return .{
        .runtime_id = TEST_RUNTIME_ID,
        .instance_id = TEST_INSTANCE_ID,
        .server_version = "1.2.3",
        .protocol = .{ .major = headless.protocol.RUNTIME_PROTOCOL_MAJOR, .minor = 4 },
        .runtime_capabilities = &.{ "core.snapshot.v1", "providers.status.v1" },
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

fn expectRetry(connection: *const Connection, attempt: u8, retry_at_ms: u64) !void {
    switch (connection.state) {
        .reconnecting => |retry| {
            try std.testing.expectEqual(FailureKind.network, retry.failure);
            try std.testing.expectEqual(attempt, retry.attempt);
            try std.testing.expectEqual(retry_at_ms, retry.retry_at_ms);
        },
        else => return error.TestExpectedReconnectState,
    }
}

fn expectStatusProtocolFailure(status: headless.StatusResult) !void {
    var transport: StatusTransport = .{ .status = status };
    var outcome = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &transport,
        StatusTransport.send,
    );
    defer outcome.deinit();
    try std.testing.expectEqual(FailureKind.protocol, outcome.failed);
}

test "connection covers every state and keeps retries explicit" {
    var connection = try Connection.init(
        std.testing.allocator,
        "profile-alpha",
        TEST_RUNTIME_ID,
        TEST_INSTANCE_ID,
    );
    defer connection.deinit();
    try std.testing.expectEqual(Phase.disabled, connection.phase());
    try std.testing.expectEqualStrings("profile-alpha", connection.profileId());

    const first_generation = try connection.enable();
    try std.testing.expectEqual(Phase.connecting, connection.phase());
    try std.testing.expectError(error.InvalidConnectionTransition, connection.enable());
    try std.testing.expectEqual(ApplyResult.applied, try connection.beginHandshake(first_generation));
    try std.testing.expectEqual(Phase.handshaking, connection.phase());

    var auth_transport: ErrorTransport = .{ .failure = .authentication };
    const auth = try performHandshakeAlloc(
        std.testing.allocator,
        connection.expectedRuntimeId(),
        &auth_transport,
        ErrorTransport.send,
    );
    try std.testing.expectEqual(
        ApplyResult.applied,
        try connection.completeHandshake(first_generation, auth, 1_000, 0),
    );
    try std.testing.expectEqual(Phase.failed, connection.phase());
    try std.testing.expectEqual(FailureKind.authentication, connection.lastFailure().?);

    const second_generation = try connection.retryFailed();
    try std.testing.expect(second_generation > first_generation);
    try std.testing.expectEqual(Phase.connecting, connection.phase());
    try std.testing.expectEqual(
        ApplyResult.applied,
        try connection.failAttempt(second_generation, .network, 2_000, 100),
    );
    try std.testing.expectEqual(Phase.reconnecting, connection.phase());
    try expectRetry(&connection, 1, 2_600);
    try std.testing.expect((try connection.reconnectIfDue(2_599)) == null);

    const third_generation = (try connection.reconnectIfDue(2_600)).?;
    try std.testing.expect(third_generation > second_generation);
    try std.testing.expectEqual(ApplyResult.applied, try connection.beginHandshake(third_generation));
    var status_transport: StatusTransport = .{ .status = validStatus() };
    const success = try performHandshakeAlloc(
        std.testing.allocator,
        connection.expectedRuntimeId(),
        &status_transport,
        StatusTransport.send,
    );
    try std.testing.expectEqual(
        ApplyResult.applied,
        try connection.completeHandshake(third_generation, success, 3_000, 0),
    );
    try std.testing.expectEqual(Phase.ready, connection.phase());
    try std.testing.expect(connection.lastFailure() == null);
    try std.testing.expect(status_transport.saw_core_status);

    const metadata = connection.metadata().?;
    try std.testing.expectEqualStrings(TEST_RUNTIME_ID, metadata.runtime_id);
    try std.testing.expectEqualStrings(TEST_INSTANCE_ID, metadata.instance_id);
    try std.testing.expectEqualStrings("1.2.3", metadata.server_version);
    try std.testing.expectEqual(@as(u32, 4), metadata.runtime_protocol.minor);
    try std.testing.expectEqual(@as(usize, 2), metadata.runtime_capabilities.len);
    try std.testing.expectEqual(@as(usize, 131_072), metadata.limits.max_response_bytes);
    try std.testing.expectEqual(headless.HEADLESS_PROTOCOL_VERSION, metadata.negotiated_headless_protocol_version);
    try std.testing.expect(metadata.capabilities.provider_status);

    try connection.connectionLost(4_000, 0);
    try std.testing.expectEqual(Phase.reconnecting, connection.phase());
    try std.testing.expect(connection.metadata() == null);
    try expectRetry(&connection, 1, 4_500);
    try connection.disable();
    try std.testing.expectEqual(Phase.disabled, connection.phase());
}

test "handshake classifies transport identity and protocol failures" {
    var auth_transport: ErrorTransport = .{ .failure = .authentication };
    var auth = try performHandshakeAlloc(
        std.testing.allocator,
        TEST_RUNTIME_ID,
        &auth_transport,
        ErrorTransport.send,
    );
    defer auth.deinit();
    try std.testing.expectEqual(FailureKind.authentication, auth.failed);

    var network_transport: ErrorTransport = .{ .failure = .network };
    var network = try performHandshakeAlloc(
        std.testing.allocator,
        TEST_RUNTIME_ID,
        &network_transport,
        ErrorTransport.send,
    );
    defer network.deinit();
    try std.testing.expectEqual(FailureKind.network, network.failed);

    var unavailable_transport: ErrorTransport = .{ .failure = .server_unavailable };
    var unavailable = try performHandshakeAlloc(
        std.testing.allocator,
        TEST_RUNTIME_ID,
        &unavailable_transport,
        ErrorTransport.send,
    );
    defer unavailable.deinit();
    try std.testing.expectEqual(FailureKind.server_unavailable, unavailable.failed);

    var wrong_service_transport: ErrorTransport = .{ .failure = .wrong_service };
    var wrong_service = try performHandshakeAlloc(
        std.testing.allocator,
        TEST_RUNTIME_ID,
        &wrong_service_transport,
        ErrorTransport.send,
    );
    defer wrong_service.deinit();
    try std.testing.expectEqual(FailureKind.wrong_service, wrong_service.failed);

    var mismatch_transport: StatusTransport = .{ .status = validStatus() };
    var mismatch = try performHandshakeAlloc(
        std.testing.allocator,
        TEST_OTHER_RUNTIME_ID,
        &mismatch_transport,
        StatusTransport.send,
    );
    defer mismatch.deinit();
    try std.testing.expectEqual(FailureKind.identity, mismatch.failed);

    var missing_runtime_status = validStatus();
    missing_runtime_status.runtime_id = "";
    var missing_runtime_transport: StatusTransport = .{ .status = missing_runtime_status };
    var missing_runtime = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &missing_runtime_transport,
        StatusTransport.send,
    );
    defer missing_runtime.deinit();
    try std.testing.expectEqual(FailureKind.identity, missing_runtime.failed);

    var missing_instance_status = validStatus();
    missing_instance_status.instance_id = "";
    var missing_instance_transport: StatusTransport = .{ .status = missing_instance_status };
    var missing_instance = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &missing_instance_transport,
        StatusTransport.send,
    );
    defer missing_instance.deinit();
    try std.testing.expectEqual(FailureKind.identity, missing_instance.failed);

    var runtime_protocol_status = validStatus();
    runtime_protocol_status.protocol.major += 1;
    var runtime_protocol_transport: StatusTransport = .{ .status = runtime_protocol_status };
    var runtime_protocol = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &runtime_protocol_transport,
        StatusTransport.send,
    );
    defer runtime_protocol.deinit();
    try std.testing.expectEqual(FailureKind.protocol, runtime_protocol.failed);

    var headless_protocol_status = validStatus();
    headless_protocol_status.min_supported = headless.MAX_SUPPORTED_PROTOCOL_VERSION + 1;
    headless_protocol_status.max_supported = headless.MAX_SUPPORTED_PROTOCOL_VERSION + 1;
    var headless_protocol_transport: StatusTransport = .{ .status = headless_protocol_status };
    var headless_protocol = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &headless_protocol_transport,
        StatusTransport.send,
    );
    defer headless_protocol.deinit();
    try std.testing.expectEqual(FailureKind.protocol, headless_protocol.failed);

    var malformed_transport: MalformedTransport = .{};
    var malformed = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &malformed_transport,
        MalformedTransport.send,
    );
    defer malformed.deinit();
    try std.testing.expectEqual(FailureKind.protocol, malformed.failed);
}

test "handshake rejects allocation amplification and unsafe advertised limits" {
    var oversized_version = validStatus();
    oversized_version.server_version = &([_]u8{'v'} ** (MAX_SERVER_VERSION_BYTES + 1));
    try expectStatusProtocolFailure(oversized_version);

    var too_many_capabilities = validStatus();
    too_many_capabilities.runtime_capabilities = &([_][]const u8{"cap.v1"} ** (MAX_RUNTIME_CAPABILITIES + 1));
    try expectStatusProtocolFailure(too_many_capabilities);

    var oversized_capability = validStatus();
    oversized_capability.runtime_capabilities = &.{
        &([_]u8{'x'} ** (MAX_RUNTIME_CAPABILITY_BYTES + 1)),
    };
    try expectStatusProtocolFailure(oversized_capability);

    var zero_limit = validStatus();
    zero_limit.limits.max_request_bytes = 0;
    try expectStatusProtocolFailure(zero_limit);

    var oversized_limit = validStatus();
    oversized_limit.limits.max_response_bytes = headless.protocol.RUNTIME_MAX_MESSAGE_BYTES + 1;
    try expectStatusProtocolFailure(oversized_limit);

    var invalid_page_limits = validStatus();
    invalid_page_limits.limits.default_page_items = 2;
    invalid_page_limits.limits.max_page_items = 1;
    try expectStatusProtocolFailure(invalid_page_limits);
}

test "pinned instance recreation fails closed even when runtime id is unchanged" {
    var runtime_connection = try Connection.init(
        std.testing.allocator,
        "profile-alpha",
        TEST_RUNTIME_ID,
        TEST_INSTANCE_ID,
    );
    defer runtime_connection.deinit();
    const generation = try runtime_connection.enable();
    _ = try runtime_connection.beginHandshake(generation);

    var recreated_status = validStatus();
    recreated_status.instance_id = TEST_OTHER_INSTANCE_ID;
    var transport: StatusTransport = .{ .status = recreated_status };
    const outcome = try performHandshakeAlloc(
        std.testing.allocator,
        TEST_RUNTIME_ID,
        &transport,
        StatusTransport.send,
    );
    _ = try runtime_connection.completeHandshake(generation, outcome, 0, 0);
    try std.testing.expectEqual(Phase.failed, runtime_connection.phase());
    try std.testing.expectEqual(FailureKind.identity, runtime_connection.lastFailure().?);
    try std.testing.expect(runtime_connection.metadata() == null);
}

test "completion rechecks the profile identity pin" {
    var connection = try Connection.init(
        std.testing.allocator,
        "profile-alpha",
        TEST_OTHER_RUNTIME_ID,
        TEST_INSTANCE_ID,
    );
    defer connection.deinit();
    const generation = try connection.enable();
    _ = try connection.beginHandshake(generation);

    var transport: StatusTransport = .{ .status = validStatus() };
    const outcome = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &transport,
        StatusTransport.send,
    );
    try std.testing.expectEqual(
        ApplyResult.applied,
        try connection.completeHandshake(generation, outcome, 0, 0),
    );
    try std.testing.expectEqual(Phase.failed, connection.phase());
    try std.testing.expectEqual(FailureKind.identity, connection.lastFailure().?);
    try std.testing.expect(connection.metadata() == null);
}

test "stale generations cannot overwrite newer connection state" {
    var connection = try Connection.init(
        std.testing.allocator,
        "profile-alpha",
        TEST_RUNTIME_ID,
        TEST_INSTANCE_ID,
    );
    defer connection.deinit();
    const stale_generation = try connection.enable();
    _ = try connection.beginHandshake(stale_generation);

    var transport: StatusTransport = .{ .status = validStatus() };
    const outcome = try performHandshakeAlloc(
        std.testing.allocator,
        connection.expectedRuntimeId(),
        &transport,
        StatusTransport.send,
    );
    try connection.disable();
    const current_generation = try connection.enable();
    try std.testing.expect(current_generation > stale_generation);
    try std.testing.expectEqual(
        ApplyResult.stale,
        try connection.completeHandshake(stale_generation, outcome, 0, 0),
    );
    try std.testing.expectEqual(Phase.connecting, connection.phase());
    try std.testing.expect(connection.metadata() == null);

    try std.testing.expectEqual(
        ApplyResult.stale,
        try connection.beginHandshake(stale_generation),
    );
    try std.testing.expectEqual(
        ApplyResult.stale,
        try connection.failAttempt(stale_generation, .authentication, 0, 0),
    );
    try std.testing.expectEqual(Phase.connecting, connection.phase());
}

test "first contact remains non-ready until a durably persisted pin is committed" {
    var runtime_connection = try Connection.init(
        std.testing.allocator,
        "profile-alpha",
        null,
        null,
    );
    defer runtime_connection.deinit();
    const generation = try runtime_connection.enable();
    _ = try runtime_connection.beginHandshake(generation);

    var transport: StatusTransport = .{ .status = validStatus() };
    const outcome = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &transport,
        StatusTransport.send,
    );
    try std.testing.expectEqual(
        ApplyResult.applied,
        try runtime_connection.completeHandshake(generation, outcome, 0, 0),
    );
    try std.testing.expectEqual(Phase.awaiting_trust, runtime_connection.phase());
    try std.testing.expect(runtime_connection.metadata() == null);
    try std.testing.expectEqualStrings(
        TEST_RUNTIME_ID,
        runtime_connection.pendingTrustMetadata().?.runtime_id,
    );
    // Persistence is deliberately outside Connection; this explicit adoption
    // is called only with the identity pair reread from durable storage.
    try std.testing.expectEqual(
        IdentityPinAdoption.committed_current,
        try runtime_connection.adoptPersistedIdentity(
            generation,
            TEST_RUNTIME_ID,
            TEST_INSTANCE_ID,
            TEST_RUNTIME_ID,
            TEST_INSTANCE_ID,
            true,
        ),
    );
    try std.testing.expectEqual(Phase.ready, runtime_connection.phase());
    try std.testing.expectEqualStrings(TEST_RUNTIME_ID, runtime_connection.expectedRuntimeId().?);
    try std.testing.expectEqualStrings(TEST_INSTANCE_ID, runtime_connection.expectedInstanceId().?);
    try std.testing.expectEqualStrings(TEST_RUNTIME_ID, runtime_connection.metadata().?.runtime_id);
    try std.testing.expect(runtime_connection.pendingTrustMetadata() == null);
}

test "a conflicting durable pin invalidates pending trust and reconnects pinned" {
    var runtime_connection = try Connection.init(
        std.testing.allocator,
        "profile-alpha",
        null,
        null,
    );
    defer runtime_connection.deinit();
    const generation = try runtime_connection.enable();
    _ = try runtime_connection.beginHandshake(generation);
    var transport: StatusTransport = .{ .status = validStatus() };
    const outcome = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &transport,
        StatusTransport.send,
    );
    _ = try runtime_connection.completeHandshake(generation, outcome, 0, 0);

    try std.testing.expectEqual(
        IdentityPinAdoption.reconnect_required,
        try runtime_connection.adoptPersistedIdentity(
            generation,
            TEST_RUNTIME_ID,
            TEST_INSTANCE_ID,
            TEST_OTHER_RUNTIME_ID,
            TEST_OTHER_INSTANCE_ID,
            true,
        ),
    );
    try std.testing.expectEqual(Phase.connecting, runtime_connection.phase());
    try std.testing.expectEqualStrings(
        TEST_OTHER_RUNTIME_ID,
        runtime_connection.expectedRuntimeId().?,
    );
    try std.testing.expectEqualStrings(
        TEST_OTHER_INSTANCE_ID,
        runtime_connection.expectedInstanceId().?,
    );
    try std.testing.expect(runtime_connection.metadata() == null);
}

test "runtime identity validation is canonical and fail closed" {
    try validateRuntimeId(TEST_RUNTIME_ID);
    try std.testing.expectError(error.InvalidRuntimeIdentity, validateRuntimeId("runtime-alpha"));
    try std.testing.expectError(
        error.InvalidRuntimeIdentity,
        validateRuntimeId("0123456789ABCDEF0123456789ABCDEF"),
    );
    try std.testing.expectError(
        error.InvalidRuntimeIdentity,
        Connection.init(std.testing.allocator, "profile-alpha", "runtime-alpha", null),
    );

    var runtime_connection = try Connection.init(
        std.testing.allocator,
        "profile-alpha",
        null,
        null,
    );
    defer runtime_connection.deinit();
    const generation = try runtime_connection.enable();
    _ = try runtime_connection.beginHandshake(generation);
    var invalid_status = validStatus();
    invalid_status.runtime_id = "0123456789ABCDEF0123456789ABCDEF";
    var transport: StatusTransport = .{ .status = invalid_status };
    const outcome = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &transport,
        StatusTransport.send,
    );
    try std.testing.expectEqual(
        ApplyResult.applied,
        try runtime_connection.completeHandshake(generation, outcome, 0, 0),
    );
    try std.testing.expectEqual(Phase.failed, runtime_connection.phase());
    try std.testing.expectEqual(FailureKind.identity, runtime_connection.lastFailure().?);
    try std.testing.expect(runtime_connection.metadata() == null);
    try std.testing.expect(runtime_connection.pendingTrustMetadata() == null);

    var instance_connection = try Connection.init(
        std.testing.allocator,
        "profile-beta",
        null,
        null,
    );
    defer instance_connection.deinit();
    const instance_generation = try instance_connection.enable();
    _ = try instance_connection.beginHandshake(instance_generation);
    var invalid_instance_status = validStatus();
    invalid_instance_status.instance_id = "00112233445566778899AABBCCDDEEFF";
    var instance_transport: StatusTransport = .{ .status = invalid_instance_status };
    const instance_outcome = try performHandshakeAlloc(
        std.testing.allocator,
        null,
        &instance_transport,
        StatusTransport.send,
    );
    _ = try instance_connection.completeHandshake(
        instance_generation,
        instance_outcome,
        0,
        0,
    );
    try std.testing.expectEqual(Phase.failed, instance_connection.phase());
    try std.testing.expectEqual(FailureKind.identity, instance_connection.lastFailure().?);
}

test "reconnect delay is deterministic jittered and capped" {
    try std.testing.expectError(error.InvalidReconnectAttempt, reconnectDelayMs(0, 0));
    try std.testing.expectError(
        error.ReconnectJitterOutOfRange,
        reconnectDelayMs(1, RECONNECT_MAX_JITTER_MS + 1),
    );
    try std.testing.expectEqual(@as(u64, 500), try reconnectDelayMs(1, 0));
    try std.testing.expectEqual(@as(u64, 1_000), try reconnectDelayMs(2, 0));
    try std.testing.expectEqual(@as(u64, 2_250), try reconnectDelayMs(3, 250));
    try std.testing.expectEqual(RECONNECT_MAX_DELAY_MS, try reconnectDelayMs(64, 0));
    try std.testing.expectEqual(RECONNECT_MAX_DELAY_MS, try reconnectDelayMs(255, RECONNECT_MAX_JITTER_MS));
}

test "only transient failures retry and manual retry bypasses the deadline" {
    var runtime_connection = try Connection.init(
        std.testing.allocator,
        "profile-retry",
        TEST_RUNTIME_ID,
        TEST_INSTANCE_ID,
    );
    defer runtime_connection.deinit();

    const first_generation = try runtime_connection.enable();
    _ = try runtime_connection.failAttempt(first_generation, .server_unavailable, 1_000, 25);
    switch (runtime_connection.state) {
        .reconnecting => |retry| {
            try std.testing.expectEqual(FailureKind.server_unavailable, retry.failure);
            try std.testing.expectEqual(@as(u8, 1), retry.attempt);
            try std.testing.expectEqual(@as(u64, 525), retry.delay_ms);
            try std.testing.expectEqual(@as(u64, 1_525), retry.retry_at_ms);
        },
        else => return error.TestExpectedReconnectState,
    }
    const manual_generation = try runtime_connection.retryFailed();
    try std.testing.expect(manual_generation > first_generation);
    try std.testing.expectEqual(Phase.connecting, runtime_connection.phase());

    _ = try runtime_connection.failAttempt(manual_generation, .wrong_service, 1_100, 0);
    try std.testing.expectEqual(Phase.failed, runtime_connection.phase());
    try std.testing.expectEqual(FailureKind.wrong_service, runtime_connection.lastFailure().?);
}

fn checkConnectionAllocationFailures(allocator: std.mem.Allocator) !void {
    var connection = try Connection.init(
        allocator,
        "profile-alpha",
        TEST_RUNTIME_ID,
        TEST_INSTANCE_ID,
    );
    defer connection.deinit();
    const generation = try connection.enable();
    _ = try connection.beginHandshake(generation);

    var transport: StatusTransport = .{ .status = validStatus() };
    const outcome = try performHandshakeAlloc(
        allocator,
        connection.expectedRuntimeId(),
        &transport,
        StatusTransport.send,
    );
    // The typed client's JSON writer may erase allocator exhaustion behind a
    // parse-shaped error. This transport is always valid, so a classified
    // failure in this harness can only be the injected allocation failure.
    if (outcome == .failed) {
        var failed_outcome = outcome;
        failed_outcome.deinit();
        return error.OutOfMemory;
    }
    _ = try connection.completeHandshake(generation, outcome, 0, 0);
    try std.testing.expectEqualStrings(TEST_RUNTIME_ID, connection.metadata().?.runtime_id);
}

test "connection and owned handshake clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkConnectionAllocationFailures,
        .{},
    );
}
