//! Transport-neutral typed client for the headless protocol.
//!
//! Builds request envelopes and parses response envelopes. The caller injects
//! a send function so unit tests need no sockets or daemon process.

const std = @import("std");
const protocol = @import("protocol.zig");
const registry = @import("registry_protocol.zig");
const store_protocol = @import("store_protocol.zig");
const changes_protocol = @import("changes_protocol.zig");
const providers_protocol = @import("providers_protocol.zig");
const access_protocol = @import("access_protocol.zig");
const connect_protocol = @import("connect_protocol.zig");

/// Sends one request JSON document and returns an allocator-owned response JSON document.
pub const TransportFn = *const fn (ctx: *anyopaque, request_json: []const u8) anyerror![]u8;

/// Coarse and granular capabilities that a direct daemon client may require.
/// The registry capabilities are deliberately included here while their
/// advertisement remains false during the phase-2 dual-write rollout.
pub const RequiredCapability = enum {
    terminal_raw,
    terminal_grid,
    chat,
    processes,
    leases,
    store,
    snapshots,
    changes,
    workspace_pagination,
    thread_pagination,
    message_pagination,
    provider_status,
    repository_projection,
    repository_manifests,
    browser_execution,
    browser_presentation,
    browser_session_state,
    browser_create,
    browser_navigation,
    browser_history,
    browser_javascript_eval,
    browser_dom_inspection,
    browser_selector_actions,
    browser_form_input,
    browser_low_level_pointer,
    browser_screenshot,
    browser_lifecycle_restart,
    browser_lifecycle_reset,
    browser_frame_streaming,
    browser_downloads,
    browser_uploads,

    pub fn wireName(self: @This()) []const u8 {
        return switch (self) {
            .terminal_raw => "terminal_raw",
            .terminal_grid => "terminal_grid",
            .chat => "chat",
            .processes => "processes",
            .leases => "leases",
            .store => "store",
            .snapshots => "snapshots",
            .changes => "changes",
            .workspace_pagination => "workspace_pagination",
            .thread_pagination => "thread_pagination",
            .message_pagination => "message_pagination",
            .provider_status => "provider_status",
            .repository_projection => "repository_projection",
            .repository_manifests => "repository_manifests",
            .browser_execution => "browser_execution",
            .browser_presentation => "browser_presentation",
            .browser_session_state => "browser.session_state",
            .browser_create => "browser.create",
            .browser_navigation => "browser.navigation",
            .browser_history => "browser.history",
            .browser_javascript_eval => "browser.javascript_eval",
            .browser_dom_inspection => "browser.dom_inspection",
            .browser_selector_actions => "browser.selector_actions",
            .browser_form_input => "browser.form_input",
            .browser_low_level_pointer => "browser.low_level_pointer",
            .browser_screenshot => "browser.screenshot",
            .browser_lifecycle_restart => "browser.lifecycle_restart",
            .browser_lifecycle_reset => "browser.lifecycle_reset",
            .browser_frame_streaming => "browser.frame_streaming",
            .browser_downloads => "browser.downloads",
            .browser_uploads => "browser.uploads",
        };
    }
};

/// The typed client-side error used when a direct daemon lacks a feature.
pub const CapabilityError = error{CapabilityUnavailable};

/// Check a coarse or granular advertised capability before a direct call.
pub fn requireCapability(capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
    return requireCapabilityChecked(capabilities, feature);
}

fn requireCapabilityChecked(capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
    const available = switch (feature) {
        .terminal_raw => capabilities.terminal_raw,
        .terminal_grid => capabilities.terminal_grid,
        .chat => capabilities.chat,
        .processes => capabilities.processes,
        .leases => capabilities.leases,
        .store => capabilities.store,
        .snapshots => capabilities.snapshots,
        .changes => capabilities.changes,
        .workspace_pagination => capabilities.workspace_pagination,
        .thread_pagination => capabilities.thread_pagination,
        .message_pagination => capabilities.message_pagination,
        .provider_status => capabilities.provider_status,
        .repository_projection => capabilities.repository_projection,
        .repository_manifests => capabilities.repository_manifests,
        .browser_execution => capabilities.browser_execution,
        .browser_presentation => capabilities.browser_presentation,
        .browser_session_state => capabilities.isFeatureAvailable(.browser_session_state),
        .browser_create => capabilities.isFeatureAvailable(.browser_create),
        .browser_navigation => capabilities.isFeatureAvailable(.browser_navigation),
        .browser_history => capabilities.isFeatureAvailable(.browser_history),
        .browser_javascript_eval => capabilities.isFeatureAvailable(.browser_javascript_eval),
        .browser_dom_inspection => capabilities.isFeatureAvailable(.browser_dom_inspection),
        .browser_selector_actions => capabilities.isFeatureAvailable(.browser_selector_actions),
        .browser_form_input => capabilities.isFeatureAvailable(.browser_form_input),
        .browser_low_level_pointer => capabilities.isFeatureAvailable(.browser_low_level_pointer),
        .browser_screenshot => capabilities.isFeatureAvailable(.browser_screenshot),
        .browser_lifecycle_restart => capabilities.isFeatureAvailable(.browser_lifecycle_restart),
        .browser_lifecycle_reset => capabilities.isFeatureAvailable(.browser_lifecycle_reset),
        .browser_frame_streaming => capabilities.isFeatureAvailable(.browser_frame_streaming),
        .browser_downloads => capabilities.isFeatureAvailable(.browser_downloads),
        .browser_uploads => capabilities.isFeatureAvailable(.browser_uploads),
    };
    if (!available) return error.CapabilityUnavailable;
}

/// Check a protocol capability using the protocol's established feature enum.
/// This is convenient for callers that already use `protocol.CapabilityFeature`.
pub fn requireFeature(capabilities: protocol.Capabilities, feature: protocol.CapabilityFeature) CapabilityError!void {
    return requireFeatureChecked(capabilities, feature);
}

fn requireFeatureChecked(capabilities: protocol.Capabilities, feature: protocol.CapabilityFeature) CapabilityError!void {
    if (!capabilities.isFeatureAvailable(feature)) return error.CapabilityUnavailable;
}

/// Alias documenting that the check is for a direct daemon request.
pub fn requireDaemonDirectCapability(capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
    return requireCapabilityChecked(capabilities, feature);
}

/// Convert a failed direct-mode capability check to the protocol error payload.
pub fn capabilityUnavailable(feature: RequiredCapability) protocol.Error {
    return .{
        .code = protocol.ERR_CAPABILITY_UNAVAILABLE,
        .message = switch (feature) {
            .terminal_raw => "terminal_raw capability is unavailable",
            .terminal_grid => "terminal_grid capability is unavailable",
            .chat => "chat capability is unavailable",
            .processes => "processes capability is unavailable",
            .leases => "leases capability is unavailable",
            .store => "store capability is unavailable",
            .snapshots => "snapshots capability is unavailable",
            .changes => "changes capability is unavailable",
            .workspace_pagination => "workspace_pagination capability is unavailable",
            .thread_pagination => "thread_pagination capability is unavailable",
            .message_pagination => "message_pagination capability is unavailable",
            .provider_status => "provider_status capability is unavailable",
            .repository_projection => "repository_projection capability is unavailable",
            .repository_manifests => "repository_manifests capability is unavailable",
            .browser_execution => "browser_execution capability is unavailable",
            .browser_presentation => "browser_presentation capability is unavailable",
            .browser_session_state => "browser.session_state capability is unavailable",
            .browser_create => "browser.create capability is unavailable",
            .browser_navigation => "browser.navigation capability is unavailable",
            .browser_history => "browser.history capability is unavailable",
            .browser_javascript_eval => "browser.javascript_eval capability is unavailable",
            .browser_dom_inspection => "browser.dom_inspection capability is unavailable",
            .browser_selector_actions => "browser.selector_actions capability is unavailable",
            .browser_form_input => "browser.form_input capability is unavailable",
            .browser_low_level_pointer => "browser.low_level_pointer capability is unavailable",
            .browser_screenshot => "browser.screenshot capability is unavailable",
            .browser_lifecycle_restart => "browser.lifecycle_restart capability is unavailable",
            .browser_lifecycle_reset => "browser.lifecycle_reset capability is unavailable",
            .browser_frame_streaming => "browser.frame_streaming capability is unavailable",
            .browser_downloads => "browser.downloads capability is unavailable",
            .browser_uploads => "browser.uploads capability is unavailable",
        },
    };
}

/// What a client-held core.changes cursor should do after one poll reply.
pub const ChangeCursorAdvance = struct {
    /// Cursor to send on the next core.changes request.
    next_cursor: u64,
    /// True when incremental entries can no longer be trusted (journal expiry
    /// or a daemon-instance change); the caller must refresh from
    /// core.snapshot before resuming incremental application.
    snapshot_required: bool,
};

/// Advance a client-held change cursor from one `core.changes` reply.
/// `previous_envelope` is the envelope from the last accepted reply (null on
/// the first poll); a nonce change resets the projection exactly like
/// registry_revision consumers do.
pub fn advanceChangeCursor(
    previous_envelope: ?registry.RegistryRevisionEnvelope,
    result: changes_protocol.ChangesResult,
) ChangeCursorAdvance {
    const instance_changed = if (previous_envelope) |previous|
        previous.shouldResetProjection(result.envelope)
    else
        false;
    return .{
        .next_cursor = result.next_cursor,
        .snapshot_required = result.expired or instance_changed,
    };
}

pub const RuntimeHandshakeError = error{
    RuntimeIdentityMissing,
    RuntimeIdentityMismatch,
    IncompatibleRuntimeProtocol,
};

/// Validate the network-runtime identity after the ordinary protocol-range
/// negotiation. Callers persist `runtime_id`, never a mutable label/address.
pub fn verifyRuntimeHandshake(
    status: protocol.StatusResult,
    expected_runtime_id: ?[]const u8,
) RuntimeHandshakeError!void {
    if (status.runtime_id.len == 0 or status.instance_id.len == 0) return error.RuntimeIdentityMissing;
    if (status.protocol.major != protocol.RUNTIME_PROTOCOL_MAJOR) return error.IncompatibleRuntimeProtocol;
    if (expected_runtime_id) |expected| {
        if (expected.len == 0 or !std.mem.eql(u8, expected, status.runtime_id)) return error.RuntimeIdentityMismatch;
    }
}

const ConfiguredRequestTarget = struct {
    runtime_id: [32]u8,
    instance_id: [32]u8,

    fn init(target: protocol.RequestTarget) !ConfiguredRequestTarget {
        try protocol.validateRequestTarget(target);
        var configured: ConfiguredRequestTarget = undefined;
        @memcpy(configured.runtime_id[0..], target.runtime_id);
        @memcpy(configured.instance_id[0..], target.instance_id);
        return configured;
    }

    fn borrow(self: *const ConfiguredRequestTarget) protocol.RequestTarget {
        return .{
            .runtime_id = &self.runtime_id,
            .instance_id = &self.instance_id,
        };
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport_ctx: ?*anyopaque,
    transport: ?TransportFn,
    request_target: ?ConfiguredRequestTarget = null,
    next_id: u64 = 1,
    negotiated_version: ?u32 = null,

    /// Successful `core.status` handshake result. Requests remain wire-compatible;
    /// the selected protocol version exists only in client state this milestone.
    pub const HandshakeResult = struct {
        status: protocol.StatusResult,
        negotiated_version: u32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        transport_ctx: *anyopaque,
        transport: TransportFn,
    ) Client {
        return .{
            .allocator = allocator,
            .transport_ctx = transport_ctx,
            .transport = transport,
        };
    }

    /// Create a transport client permanently pinned to one runtime generation.
    /// The identity pair is copied into the client so caller buffer changes
    /// cannot retarget later requests.
    pub fn initTargeted(
        allocator: std.mem.Allocator,
        transport_ctx: *anyopaque,
        transport: TransportFn,
        target: protocol.RequestTarget,
    ) !Client {
        var client = init(allocator, transport_ctx, transport);
        client.request_target = try ConfiguredRequestTarget.init(target);
        return client;
    }

    /// Creates an encoder/parser-only client for adapters that own transport.
    pub fn initEncoder(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .transport_ctx = null,
            .transport = null,
        };
    }

    /// Create an encoder-only client permanently pinned to one runtime
    /// generation. No per-call API can replace or omit this target.
    pub fn initTargetedEncoder(allocator: std.mem.Allocator, target: protocol.RequestTarget) !Client {
        var client = initEncoder(allocator);
        client.request_target = try ConfiguredRequestTarget.init(target);
        return client;
    }

    /// Encode a typed request, hand it to the transport, and parse the envelope.
    /// Caller owns the returned ParsedResponse and must call deinit.
    pub fn call(self: *Client, method: []const u8, params: anytype) !protocol.ParsedResponse {
        const id = self.next_id;
        self.next_id += 1;
        return try self.callWithId(id, method, params);
    }

    /// Encode and send a request with the caller's existing request id.
    pub fn callWithId(self: *Client, id: u64, method: []const u8, params: anytype) !protocol.ParsedResponse {
        const request_json = try self.encodeRequestWithId(id, method, params);
        defer {
            std.crypto.secureZero(u8, request_json);
            self.allocator.free(request_json);
        }

        const response_json = try self.send(request_json);
        defer {
            std.crypto.secureZero(u8, response_json);
            self.allocator.free(response_json);
        }

        return try self.parseResponseWithId(id, response_json);
    }

    /// Result of a call when the transport adapter must return the original response bytes.
    pub const CallResult = struct {
        response_json: ?[]u8,
        parsed: protocol.ParsedResponse,

        pub fn takeResponse(self: *CallResult) []u8 {
            const response_json = self.response_json orelse unreachable;
            self.response_json = null;
            return response_json;
        }

        pub fn deinit(self: *CallResult, allocator: std.mem.Allocator) void {
            self.parsed.deinit();
            if (self.response_json) |response_json| {
                std.crypto.secureZero(u8, response_json);
                allocator.free(response_json);
            }
            self.* = undefined;
        }
    };

    /// Encode, send, and parse while retaining ownership of the original response JSON.
    pub fn callAllocWithId(self: *Client, id: u64, method: []const u8, params: anytype) !CallResult {
        const request_json = try self.encodeRequestWithId(id, method, params);
        defer {
            std.crypto.secureZero(u8, request_json);
            self.allocator.free(request_json);
        }

        const response_json = try self.send(request_json);
        errdefer {
            std.crypto.secureZero(u8, response_json);
            self.allocator.free(response_json);
        }
        var parsed = try self.parseResponseWithId(id, response_json);
        errdefer parsed.deinit();
        return .{
            .response_json = response_json,
            .parsed = parsed,
        };
    }

    /// Build a request envelope without sending (useful for custom transports).
    pub fn encodeRequest(self: *Client, method: []const u8, params: anytype) !struct { id: u64, json: []u8 } {
        const id = self.next_id;
        self.next_id += 1;
        const json = try self.encodeRequestWithId(id, method, params);
        return .{ .id = id, .json = json };
    }

    /// Build a request envelope with an explicit id without advancing the generated id.
    pub fn encodeRequestWithId(self: *Client, id: u64, method: []const u8, params: anytype) ![]u8 {
        if (self.request_target) |*target| {
            return try protocol.encodeTargetedRequest(self.allocator, id, method, params, target.borrow());
        }
        return try protocol.encodeRequest(self.allocator, id, method, params);
    }

    /// Parse a response envelope produced by any transport.
    pub fn parseResponse(self: *Client, response_json: []const u8) !protocol.ParsedResponse {
        return try protocol.parseResponse(self.allocator, response_json);
    }

    /// Parse and correlate a response with the request that produced it.
    /// Numeric mismatches return `error.ResponseIdMismatch`; null-id errors are
    /// uncorrelated daemon failures and remain valid error responses.
    pub fn parseResponseWithId(self: *Client, request_id: u64, response_json: []const u8) !protocol.ParsedResponse {
        var parsed = try protocol.parseResponse(self.allocator, response_json);
        errdefer parsed.deinit();
        if (parsed.response.id) |response_id| {
            if (response_id != request_id) return error.ResponseIdMismatch;
        }
        return parsed;
    }

    /// Perform the client-side protocol handshake using the daemon's advertised
    /// `core.status` range. Call this before normal calls when using `Client` as
    /// a long-lived connection; no negotiation fields are added to requests.
    pub fn handshake(self: *Client) !HandshakeResult {
        const empty_params: struct {} = .{};
        var parsed = try self.call("core.status", empty_params);
        defer parsed.deinit();
        const status = try self.decodeStatus(&parsed);
        return .{
            .status = status,
            .negotiated_version = self.negotiated_version.?,
        };
    }

    /// Perform the handshake required for a configured remote runtime and
    /// reject a replaced/misdirected server before any state is projected.
    pub fn handshakeRuntime(self: *Client, expected_runtime_id: ?[]const u8) !HandshakeResult {
        const result = try self.handshake();
        try verifyRuntimeHandshake(result.status, expected_runtime_id);
        return result;
    }

    /// Return the version selected by the most recent successful status or
    /// capabilities decode. Before a successful handshake this returns
    /// `error.HandshakeRequired`.
    pub fn negotiatedProtocolVersion(self: *const Client) !u32 {
        return self.negotiated_version orelse error.HandshakeRequired;
    }

    /// Decode a successful `core.status` response into its typed result.
    pub fn decodeStatus(self: *Client, parsed: *const protocol.ParsedResponse) !protocol.StatusResult {
        const status = try self.decodeResult(protocol.StatusResult, parsed);
        _ = try self.recordNegotiatedRange(status.min_supported, status.max_supported);
        return status;
    }

    /// Decode a successful `core.capabilities` response into its typed result.
    pub fn decodeCapabilities(self: *Client, parsed: *const protocol.ParsedResponse) !protocol.CapabilitiesResult {
        const capabilities = try self.decodeResult(protocol.CapabilitiesResult, parsed);
        _ = try self.recordNegotiatedRange(capabilities.min_supported, capabilities.max_supported);
        return capabilities;
    }

    /// Decode a successful `process.list` response.
    pub fn decodeProcessList(self: *Client, parsed: *const protocol.ParsedResponse) !registry.ProcessListResult {
        return try self.decodeResult(registry.ProcessListResult, parsed);
    }

    /// Decode a successful `lease.check` response.
    pub fn decodeLeaseCheck(self: *Client, parsed: *const protocol.ParsedResponse) !registry.LeaseCheckResult {
        return try self.decodeResult(registry.LeaseCheckResult, parsed);
    }

    /// Decode a successful `lease.acquire` response.
    pub fn decodeLeaseAcquire(self: *Client, parsed: *const protocol.ParsedResponse) !registry.LeaseAcquireResult {
        return try self.decodeResult(registry.LeaseAcquireResult, parsed);
    }

    /// Decode a successful `lease.renew` response.
    pub fn decodeLeaseRenew(self: *Client, parsed: *const protocol.ParsedResponse) !registry.LeaseRenewResult {
        return try self.decodeResult(registry.LeaseRenewResult, parsed);
    }

    /// Decode a successful `lease.release` response.
    pub fn decodeLeaseRelease(self: *Client, parsed: *const protocol.ParsedResponse) !registry.LeaseReleaseResult {
        return try self.decodeResult(registry.LeaseReleaseResult, parsed);
    }

    /// Decode a successful `daemon.notifications` response.
    pub fn decodeNotifications(self: *Client, parsed: *const protocol.ParsedResponse) !registry.NotificationsResult {
        return try self.decodeResult(registry.NotificationsResult, parsed);
    }

    /// Decode a successful `daemon.client.register` response.
    pub fn decodeClientRegister(self: *Client, parsed: *const protocol.ParsedResponse) !registry.ClientRegisterResult {
        return try self.decodeResult(registry.ClientRegisterResult, parsed);
    }

    /// Decode a successful `daemon.client.heartbeat` response.
    pub fn decodeClientHeartbeat(self: *Client, parsed: *const protocol.ParsedResponse) !registry.ClientHeartbeatResult {
        return try self.decodeResult(registry.ClientHeartbeatResult, parsed);
    }

    /// Decode a successful `daemon.client.close` response.
    pub fn decodeClientClose(self: *Client, parsed: *const protocol.ParsedResponse) !registry.ClientCloseResult {
        return try self.decodeResult(registry.ClientCloseResult, parsed);
    }

    /// Decode a successful `daemon.stop` response.
    pub fn decodeDaemonStop(self: *Client, parsed: *const protocol.ParsedResponse) !registry.DaemonStopResult {
        return try self.decodeResult(registry.DaemonStopResult, parsed);
    }

    /// Decode a successful `workspace.resolve` response.
    pub fn decodeWorkspaceResolve(self: *Client, parsed: *const protocol.ParsedResponse) !registry.WorkspaceResolveResult {
        return try self.decodeResult(registry.WorkspaceResolveResult, parsed);
    }

    /// Decode a successful store write response.
    pub fn decodeWriteResult(self: *Client, parsed: *const protocol.ParsedResponse) !store_protocol.WriteResult {
        return try self.decodeResult(store_protocol.WriteResult, parsed);
    }

    /// Decode a successful daemon store status response.
    pub fn decodeStoreStatus(self: *Client, parsed: *const protocol.ParsedResponse) !store_protocol.StoreStatusResult {
        return try self.decodeResult(store_protocol.StoreStatusResult, parsed);
    }

    /// Decode one durable thread read with allocations independent of the
    /// response envelope's parse arena.
    pub fn decodeThreadGet(self: *Client, parsed: *const protocol.ParsedResponse) !store_protocol.ThreadGetResult {
        return try self.decodeResult(store_protocol.ThreadGetResult, parsed);
    }

    /// Decode a bounded workspace list with repository projections.
    pub fn decodeWorkspaceList(self: *Client, parsed: *const protocol.ParsedResponse) !store_protocol.WorkspaceListResult {
        return try self.decodeResult(store_protocol.WorkspaceListResult, parsed);
    }

    /// Decode one bounded, allocator-owned repository manifest projection.
    pub fn decodeWorkspaceRepositoryManifest(
        self: *Client,
        parsed: *const protocol.ParsedResponse,
    ) !store_protocol.WorkspaceRepositoryManifestResult {
        return try self.decodeResult(store_protocol.WorkspaceRepositoryManifestResult, parsed);
    }

    /// Decode a bounded durable thread metadata list.
    pub fn decodeThreadList(self: *Client, parsed: *const protocol.ParsedResponse) !store_protocol.ThreadListResult {
        return try self.decodeResult(store_protocol.ThreadListResult, parsed);
    }

    /// Decode a bounded bidirectional transcript page.
    pub fn decodeMessageList(self: *Client, parsed: *const protocol.ParsedResponse) !store_protocol.MessageListResult {
        return try self.decodeResult(store_protocol.MessageListResult, parsed);
    }

    /// Decode runtime-scoped installation/authentication status for providers.
    pub fn decodeProviderStatus(self: *Client, parsed: *const protocol.ParsedResponse) !providers_protocol.StatusResult {
        return try self.decodeResult(providers_protocol.StatusResult, parsed);
    }

    /// Decode one durable turn-ledger record.
    pub fn decodeTurnRecord(self: *Client, parsed: *const protocol.ParsedResponse) !store_protocol.TurnRecord {
        return try self.decodeResult(store_protocol.TurnRecord, parsed);
    }

    /// Decode a successful `core.changes` journal poll.
    pub fn decodeChanges(self: *Client, parsed: *const protocol.ParsedResponse) !changes_protocol.ChangesResult {
        return try self.decodeResult(changes_protocol.ChangesResult, parsed);
    }

    /// Decode a successful scoped composite `core.snapshot` response.
    pub fn decodeCompositeSnapshot(self: *Client, parsed: *const protocol.ParsedResponse) !store_protocol.CoreSnapshotResult {
        return try self.decodeResult(store_protocol.CoreSnapshotResult, parsed);
    }

    /// Decode the owner-only grant creation result with strict access-protocol
    /// fields. Unlike the legacy tolerant decoders, unknown fields fail closed.
    pub fn decodePairingGrantCreate(
        self: *Client,
        parsed: *const protocol.ParsedResponse,
    ) !access_protocol.PairingGrantCreateResult {
        const result = try self.decodeStrictResult(access_protocol.PairingGrantCreateResult, parsed);
        try validateAccessResultHeader(result.access_protocol_version, result.runtime_id, result.instance_id);
        try access_protocol.validateGrantId(result.grant_id);
        try access_protocol.validateSecret(result.pairing_token.reveal());
        try access_protocol.validateScopeNames(result.scopes);
        if (result.expires_at_ms < 0) return error.InvalidAccessResponse;
        return result;
    }

    /// Decode non-secret pairing grant metadata with strict v1 fields.
    pub fn decodePairingGrantList(
        self: *Client,
        parsed: *const protocol.ParsedResponse,
    ) !access_protocol.PairingGrantListResult {
        const result = try self.decodeStrictResult(access_protocol.PairingGrantListResult, parsed);
        try validateAccessResultHeader(result.access_protocol_version, result.runtime_id, result.instance_id);
        for (result.grants) |grant| {
            try access_protocol.validateGrantId(grant.grant_id);
            if (grant.label) |label| try access_protocol.validateDeviceLabel(label);
            try access_protocol.validateScopeNames(grant.scopes);
            if (grant.created_at_ms < 0 or grant.expires_at_ms < grant.created_at_ms or
                (grant.consumed_at_ms != null and grant.consumed_at_ms.? < 0) or
                (grant.revoked_at_ms != null and grant.revoked_at_ms.? < 0))
            {
                return error.InvalidAccessResponse;
            }
        }
        return result;
    }

    pub fn decodePairingGrantRevoke(
        self: *Client,
        parsed: *const protocol.ParsedResponse,
    ) !access_protocol.PairingGrantRevokeResult {
        const result = try self.decodeStrictResult(access_protocol.PairingGrantRevokeResult, parsed);
        try validateAccessProtocolVersion(result.access_protocol_version);
        try access_protocol.validateGrantId(result.grant_id);
        return result;
    }

    /// Decode non-secret device metadata with strict v1 fields.
    pub fn decodeDeviceList(
        self: *Client,
        parsed: *const protocol.ParsedResponse,
    ) !access_protocol.DeviceListResult {
        const result = try self.decodeStrictResult(access_protocol.DeviceListResult, parsed);
        try validateAccessResultHeader(result.access_protocol_version, result.runtime_id, result.instance_id);
        for (result.devices) |device| {
            try access_protocol.validateDeviceId(device.device_id);
            if (device.grant_id) |grant_id| try access_protocol.validateGrantId(grant_id);
            try access_protocol.validateDeviceLabel(device.label);
            try access_protocol.validateScopeNames(device.scopes);
            if (device.created_at_ms < 0 or
                (device.last_used_at_ms != null and device.last_used_at_ms.? < 0) or
                (device.revoked_at_ms != null and device.revoked_at_ms.? < 0))
            {
                return error.InvalidAccessResponse;
            }
        }
        return result;
    }

    pub fn decodeDeviceRevoke(
        self: *Client,
        parsed: *const protocol.ParsedResponse,
    ) !access_protocol.DeviceRevokeResult {
        const result = try self.decodeStrictResult(access_protocol.DeviceRevokeResult, parsed);
        try validateAccessProtocolVersion(result.access_protocol_version);
        try access_protocol.validateDeviceId(result.device_id);
        return result;
    }

    /// Decode the owner-only Connect projection without accepting future
    /// fields or a response for another runtime generation.
    pub fn decodeConnectStatus(
        self: *Client,
        parsed: *const protocol.ParsedResponse,
    ) !connect_protocol.StatusResult {
        const result = try self.decodeStrictResult(connect_protocol.StatusResult, parsed);
        try validateConnectProtocolVersion(result.connect_protocol_version);
        protocol.validateRequestTarget(.{
            .runtime_id = result.runtime_id,
            .instance_id = result.instance_id,
        }) catch return error.InvalidConnectResponse;
        if (self.request_target) |target| {
            const expected = target.borrow();
            if (!std.mem.eql(u8, result.runtime_id, expected.runtime_id) or
                !std.mem.eql(u8, result.instance_id, expected.instance_id))
            {
                return error.RuntimeIdentityMismatch;
            }
        }
        if (result.retry_attempt > 1024 or
            (result.next_retry_at_ms != null and result.next_retry_at_ms.? < 0))
        {
            return error.InvalidConnectResponse;
        }
        return result;
    }

    pub fn decodeConnectBootstrapConsume(
        self: *Client,
        parsed: *const protocol.ParsedResponse,
    ) !connect_protocol.BootstrapConsumeResult {
        const result = try self.decodeStrictResult(connect_protocol.BootstrapConsumeResult, parsed);
        try validateConnectProtocolVersion(result.connect_protocol_version);
        try access_protocol.validateScopeNames(result.scopes);
        protocol.validateRequestTarget(.{
            .runtime_id = result.runtime_id,
            .instance_id = result.instance_id,
        }) catch return error.InvalidConnectResponse;
        access_protocol.validateDeviceId(result.device_id) catch return error.InvalidConnectResponse;
        access_protocol.validateSecret(result.device_credential.reveal()) catch return error.InvalidConnectResponse;
        return result;
    }

    /// Send a bootstrap grant over the owner-only daemon transport. The
    /// request DTO deliberately redacts under generic serialization, so this
    /// is the sole typed client path that places the grant in a wire buffer.
    /// `callWithId` clears that buffer immediately after the transport call.
    pub fn callConnectBootstrapConsume(
        self: *Client,
        request: connect_protocol.BootstrapConsumeRequest,
    ) !protocol.ParsedResponse {
        try validateConnectProtocolVersion(request.connect_protocol_version);
        const grant_jwt = request.grant_jwt.reveal();
        if (grant_jwt.len == 0 or grant_jwt.len > connect_protocol.MAX_COMPACT_TOKEN_BYTES) {
            return error.InvalidConnectGrant;
        }
        const id = self.next_id;
        self.next_id += 1;
        return try self.callWithId(id, connect_protocol.METHOD_BOOTSTRAP_CONSUME, .{
            .connect_protocol_version = request.connect_protocol_version,
            .grant_jwt = grant_jwt,
            .expected_issuer = request.expected_issuer,
            .expected_audience = request.expected_audience,
            .client_nonce = request.client_nonce,
            .device_id = request.device_id,
            .device_key_thumbprint = request.device_key_thumbprint,
            .device_label = request.device_label,
        });
    }

    /// Issue an explicitly daemon-direct composite snapshot read. The gate is
    /// deliberately inside the typed call so an old daemon cannot silently
    /// re-enable a caller's legacy fallback after this API was chosen.
    pub fn callCompositeSnapshot(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.CoreSnapshotRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .snapshots);
        return try self.call(store_protocol.METHOD_CORE_SNAPSHOT, request);
    }

    /// Issue an explicitly daemon-direct journal read. Capability rejection
    /// and a daemon's method_not_found response are terminal outcomes for this
    /// call; the typed client performs exactly zero implicit fallback polls.
    pub fn callChanges(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: changes_protocol.ChangesRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .changes);
        return try self.call(changes_protocol.METHOD_CORE_CHANGES, request);
    }

    pub fn callWorkspaceList(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.WorkspaceListRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .workspace_pagination);
        try requireCapabilityChecked(capabilities, .repository_projection);
        return try self.call(store_protocol.METHOD_WORKSPACE_LIST, request);
    }

    pub fn callWorkspaceRepositoryManifest(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.WorkspaceRepositoryManifestRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .repository_manifests);
        return try self.call(store_protocol.METHOD_WORKSPACE_REPOSITORY_MANIFEST_GET, request);
    }

    pub fn callWorkspaceRepositoryUpsert(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.WorkspaceRepositoryUpsertRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .repository_manifests);
        return try self.call(store_protocol.METHOD_WORKSPACE_REPOSITORY_UPSERT, request);
    }

    pub fn callWorkspaceRepositoryRemove(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.WorkspaceRepositoryRemoveRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .repository_manifests);
        return try self.call(store_protocol.METHOD_WORKSPACE_REPOSITORY_REMOVE, request);
    }

    pub fn callWorkspaceRepositoryDefaultSet(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.WorkspaceDefaultRepositorySetRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .repository_manifests);
        return try self.call(store_protocol.METHOD_WORKSPACE_REPOSITORY_DEFAULT_SET, request);
    }

    pub fn callWorkspaceRepositoryBindingUpsert(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.WorkspaceRepositoryBindingUpsertRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .repository_manifests);
        return try self.call(store_protocol.METHOD_WORKSPACE_REPOSITORY_BINDING_UPSERT, request);
    }

    pub fn callWorkspaceRepositoryBindingRemove(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.WorkspaceRepositoryBindingRemoveRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .repository_manifests);
        return try self.call(store_protocol.METHOD_WORKSPACE_REPOSITORY_BINDING_REMOVE, request);
    }

    pub fn callThreadList(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.ThreadListRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .thread_pagination);
        return try self.call(store_protocol.METHOD_CHAT_THREAD_LIST, request);
    }

    pub fn callMessageList(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: store_protocol.MessageListRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .message_pagination);
        return try self.call(store_protocol.METHOD_CHAT_MESSAGE_LIST, request);
    }

    pub fn callProviderStatus(
        self: *Client,
        capabilities: protocol.Capabilities,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(
            providers_protocol.METHOD_PROVIDERS_STATUS,
            providers_protocol.StatusRequest{},
        );
    }

    /// Require a capability on this client before a direct daemon request.
    pub fn requireCapability(_: *Client, capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
        return requireCapabilityChecked(capabilities, feature);
    }

    /// Require a protocol feature on this client before a direct request.
    pub fn requireFeature(_: *Client, capabilities: protocol.Capabilities, feature: protocol.CapabilityFeature) CapabilityError!void {
        return requireFeatureChecked(capabilities, feature);
    }

    /// Require a capability for a daemon-direct operation.
    pub fn requireDaemonDirectCapability(_: *Client, capabilities: protocol.Capabilities, feature: RequiredCapability) CapabilityError!void {
        return requireCapabilityChecked(capabilities, feature);
    }

    fn recordNegotiatedRange(self: *Client, daemon_min: u32, daemon_max: u32) !u32 {
        self.negotiated_version = null;
        const negotiated_version = try protocol.negotiateProtocolVersion(
            .{
                .min = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
                .max = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
            },
            .{ .min = daemon_min, .max = daemon_max },
        );
        self.negotiated_version = negotiated_version;
        return negotiated_version;
    }

    fn resultValue(_: *Client, parsed: *const protocol.ParsedResponse) !std.json.Value {
        if (parsed.response.err) |remote_error| {
            if (std.mem.eql(u8, remote_error.code, protocol.ERR_RUNTIME_IDENTITY_MISSING)) {
                return error.RuntimeIdentityMissing;
            }
            if (std.mem.eql(u8, remote_error.code, protocol.ERR_RUNTIME_IDENTITY_MISMATCH)) {
                return error.RuntimeIdentityMismatch;
            }
            return error.RemoteError;
        }
        return parsed.response.result orelse error.InvalidResponse;
    }

    /// Re-encode the parsed result before typed parsing so `.alloc_always`
    /// produces values independent of the response envelope's arena.
    fn decodeResult(self: *Client, comptime T: type, parsed: *const protocol.ParsedResponse) !T {
        const result = try self.resultValue(parsed);
        const result_json = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
        defer self.allocator.free(result_json);
        return try std.json.parseFromSliceLeaky(T, self.allocator, result_json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    /// Access credentials and grants use strict, versioned objects. Parsing
    /// directly from the response DOM avoids another plaintext secret copy.
    fn decodeStrictResult(self: *Client, comptime T: type, parsed: *const protocol.ParsedResponse) !T {
        const result = try self.resultValue(parsed);
        return try std.json.parseFromValueLeaky(T, self.allocator, result, .{});
    }

    fn send(self: *Client, request_json: []const u8) ![]u8 {
        const transport = self.transport orelse return error.TransportUnavailable;
        const context = self.transport_ctx orelse return error.TransportUnavailable;
        return try transport(context, request_json);
    }
};

fn validateAccessProtocolVersion(version: u32) !void {
    if (version != access_protocol.ACCESS_PROTOCOL_VERSION) {
        return error.IncompatibleAccessProtocol;
    }
}

fn validateConnectProtocolVersion(version: u32) !void {
    if (version != connect_protocol.CONNECT_PROTOCOL_VERSION) {
        return error.IncompatibleConnectProtocol;
    }
}

fn validConnectPrefixedId(value: []const u8, prefix: []const u8) bool {
    if (value.len != prefix.len + 32 or !std.mem.startsWith(u8, value, prefix)) return false;
    for (value[prefix.len..]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn validateAccessResultHeader(
    version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
) !void {
    try validateAccessProtocolVersion(version);
    protocol.validateRequestTarget(.{
        .runtime_id = runtime_id,
        .instance_id = instance_id,
    }) catch return error.InvalidAccessResponse;
}

const MockTransport = struct {
    allocator: std.mem.Allocator,
    last_request: ?[]u8 = null,
    call_count: usize = 0,
    canned_response: []const u8,

    fn deinit(self: *MockTransport) void {
        if (self.last_request) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
    }

    fn send(ctx: *anyopaque, request_json: []const u8) anyerror![]u8 {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.call_count += 1;
        if (self.last_request) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        self.last_request = try self.allocator.dupe(u8, request_json);
        return try self.allocator.dupe(u8, self.canned_response);
    }
};

fn expectMockRequestMethod(mock: *const MockTransport, expected: []const u8) !void {
    var parsed = try protocol.parseRequest(std.testing.allocator, mock.last_request.?);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(expected, parsed.request.method);
}

test "client parses ok envelope via injected transport" {
    const allocator = std.testing.allocator;
    const ok_body = try protocol.encodeOkResponse(allocator, 1, .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(ok_body);

    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = ok_body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    var parsed = try client.call("core.capabilities", .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.response.isOk());
    try std.testing.expectEqual(@as(?u64, 1), parsed.response.id);
    try std.testing.expect(parsed.response.result.?.object.get("capabilities") != null);
    const capabilities = try client.decodeCapabilities(&parsed);
    try std.testing.expectEqual(@as(u32, 1), capabilities.headless_protocol_version);
    try std.testing.expect(capabilities.capabilities.terminal_raw);
    try std.testing.expect(mock.last_request != null);
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"method\":\"core.capabilities\",\"params\":[]}",
        mock.last_request.?,
    );

    const status_body = try protocol.encodeOkResponse(allocator, 2, .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 18,
        .pid = 4242,
        .session_count = 2,
        .chat_turn_count = 1,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(status_body);
    var parsed_status = try client.parseResponse(status_body);
    defer parsed_status.deinit();
    const status = try client.decodeStatus(&parsed_status);
    try std.testing.expectEqual(@as(u32, 18), status.protocol_version);
    try std.testing.expectEqual(@as(usize, 2), status.session_count);
}

test "Connect bootstrap uses only the explicit secret wire path" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const secret = "header.payload.signature";
    const request: connect_protocol.BootstrapConsumeRequest = .{
        .connect_protocol_version = connect_protocol.CONNECT_PROTOCOL_VERSION,
        .grant_jwt = .{ .bytes = secret },
        .expected_issuer = "https://connect.example.test",
        .expected_audience = "https://runtime.example.test",
        .client_nonce = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        .device_id = "dev_33333333333333333333333333333333",
        .device_key_thumbprint = "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k",
        .device_label = "Connect laptop",
    };
    const response = try allocator.dupe(
        u8,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"ok\":true,\"result\":{\"connect_protocol_version\":1," ++
            "\"runtime_id\":\"0123456789abcdef0123456789abcdef\"," ++
            "\"instance_id\":\"abcdef0123456789abcdef0123456789\"," ++
            "\"device_id\":\"00112233445566778899aabbccddeeff\"," ++
            "\"device_credential\":\"" ++ ("a" ** access_protocol.SECRET_HEX_BYTES) ++ "\"," ++
            "\"scopes\":[\"runtime:read\",\"chat:write\"]}}",
    );
    defer allocator.free(response);
    var mock: MockTransport = .{ .allocator = arena, .canned_response = response };
    defer mock.deinit();
    var client = Client.init(arena, &mock, MockTransport.send);

    const generic = try client.encodeRequest(connect_protocol.METHOD_BOOTSTRAP_CONSUME, request);
    defer {
        std.crypto.secureZero(u8, generic.json);
        arena.free(generic.json);
    }
    try std.testing.expect(std.mem.indexOf(u8, generic.json, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, generic.json, connect_protocol.REDACTED_SECRET) != null);

    client.next_id = 1;
    var parsed = try client.callConnectBootstrapConsume(request);
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, mock.last_request.?, secret) != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.last_request.?, connect_protocol.REDACTED_SECRET) == null);
    const result = try client.decodeConnectBootstrapConsume(&parsed);
    try std.testing.expectEqualStrings("00112233445566778899aabbccddeeff", result.device_id);
}

test "client parses error envelope via injected transport" {
    const allocator = std.testing.allocator;
    const err_body = try protocol.encodeErrorResponse(
        allocator,
        1,
        protocol.ERR_UNKNOWN_METHOD,
        "unknown method",
    );
    defer allocator.free(err_body);

    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = err_body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    var parsed = try client.call("core.nope", .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.response.isOk());
    try std.testing.expectEqualStrings(protocol.ERR_UNKNOWN_METHOD, parsed.response.err.?.code);
}

test "targeted client copies one target into generic and typed requests" {
    const allocator = std.testing.allocator;
    const ok_body = try protocol.encodeOkResponse(allocator, 2, .{});
    defer allocator.free(ok_body);
    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = ok_body,
    };
    defer mock.deinit();

    var runtime_id: [32]u8 = "0123456789abcdef0123456789abcdef".*;
    var instance_id: [32]u8 = "00112233445566778899aabbccddeeff".*;
    var client = try Client.initTargeted(allocator, &mock, MockTransport.send, .{
        .runtime_id = &runtime_id,
        .instance_id = &instance_id,
    });
    runtime_id[0] = 'f';
    instance_id[0] = 'f';

    const generic = try client.encodeRequest("core.capabilities", .{});
    defer allocator.free(generic.json);
    var parsed_generic = try protocol.parseRequest(allocator, generic.json);
    defer parsed_generic.deinit();
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef",
        parsed_generic.request.target.?.runtime_id,
    );
    try std.testing.expectEqualStrings(
        "00112233445566778899aabbccddeeff",
        parsed_generic.request.target.?.instance_id,
    );

    var typed = try client.callCompositeSnapshot(protocol.Capabilities.phase1(), .{});
    defer typed.deinit();
    var parsed_typed = try protocol.parseRequest(allocator, mock.last_request.?);
    defer parsed_typed.deinit();
    try std.testing.expectEqualStrings("core.snapshot", parsed_typed.request.method);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef",
        parsed_typed.request.target.?.runtime_id,
    );
}

test "targeted client rejects an invalid configured identity" {
    try std.testing.expectError(
        error.RuntimeIdentityMissing,
        Client.initTargetedEncoder(std.testing.allocator, .{
            .runtime_id = "not-canonical",
            .instance_id = "00112233445566778899aabbccddeeff",
        }),
    );
}

test "access result decoders are strict and keep generic secret rendering redacted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client = Client.initEncoder(arena);
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"access_protocol_version":1,"runtime_id":"0123456789abcdef0123456789abcdef","instance_id":"00112233445566778899aabbccddeeff","grant_id":"fedcba9876543210fedcba9876543210","pairing_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expires_at_ms":1000,"scopes":["runtime:read"]}}
    ;
    var parsed = try protocol.parseResponse(arena, response);
    defer parsed.deinit();
    var result = try client.decodePairingGrantCreate(&parsed);
    defer std.crypto.secureZero(u8, @constCast(result.pairing_token.reveal()));
    try std.testing.expectEqualStrings("a" ** access_protocol.SECRET_HEX_BYTES, result.pairing_token.reveal());
    const generic = try std.json.Stringify.valueAlloc(arena, result, .{});
    try std.testing.expect(std.mem.indexOf(u8, generic, "a" ** access_protocol.SECRET_HEX_BYTES) == null);
    try std.testing.expect(std.mem.indexOf(u8, generic, access_protocol.REDACTED_SECRET) != null);

    const unknown_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"access_protocol_version":1,"runtime_id":"0123456789abcdef0123456789abcdef","instance_id":"00112233445566778899aabbccddeeff","grant_id":"fedcba9876543210fedcba9876543210","pairing_token":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","expires_at_ms":1000,"scopes":["runtime:read"],"future":true}}
    ;
    var unknown = try protocol.parseResponse(arena, unknown_response);
    defer unknown.deinit();
    const unknown_token = unknown.response.result.?.object.get("pairing_token").?.string;
    defer std.crypto.secureZero(u8, @constCast(unknown_token));
    try std.testing.expectError(error.UnknownField, client.decodePairingGrantCreate(&unknown));

    const missing_version_response =
        \\{"jsonrpc":"2.0","id":3,"result":{"runtime_id":"0123456789abcdef0123456789abcdef","instance_id":"00112233445566778899aabbccddeeff","grant_id":"fedcba9876543210fedcba9876543210","pairing_token":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","expires_at_ms":1000,"scopes":["runtime:read"]}}
    ;
    var missing_version = try protocol.parseResponse(arena, missing_version_response);
    defer missing_version.deinit();
    const missing_token = missing_version.response.result.?.object.get("pairing_token").?.string;
    defer std.crypto.secureZero(u8, @constCast(missing_token));
    try std.testing.expectError(error.MissingField, client.decodePairingGrantCreate(&missing_version));
}

test "device list accepts Connect devices without Pair grants and validates present grants" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client = Client.initEncoder(arena);
    const connect_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"access_protocol_version":1,"runtime_id":"0123456789abcdef0123456789abcdef","instance_id":"00112233445566778899aabbccddeeff","devices":[{"device_id":"fedcba9876543210fedcba9876543210","grant_id":null,"source":"connect","source_id":"grt_66666666666666666666666666666666","label":"Connect laptop","scopes":["runtime:read"],"created_at_ms":1000}]}}
    ;
    var connect = try protocol.parseResponse(arena, connect_response);
    defer connect.deinit();
    const devices = try client.decodeDeviceList(&connect);
    try std.testing.expect(devices.devices[0].grant_id == null);

    const invalid_pair_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"access_protocol_version":1,"runtime_id":"0123456789abcdef0123456789abcdef","instance_id":"00112233445566778899aabbccddeeff","devices":[{"device_id":"fedcba9876543210fedcba9876543210","grant_id":"not-a-grant","source":"pair","source_id":null,"label":"Paired laptop","scopes":["runtime:read"],"created_at_ms":1000}]}}
    ;
    var invalid_pair = try protocol.parseResponse(arena, invalid_pair_response);
    defer invalid_pair.deinit();
    try std.testing.expectError(error.InvalidGrantId, client.decodeDeviceList(&invalid_pair));
}

test "identity response errors retain their failure classification" {
    var client = Client.initEncoder(std.testing.allocator);
    const cases = [_]struct { code: []const u8, expected: anyerror }{
        .{ .code = protocol.ERR_RUNTIME_IDENTITY_MISSING, .expected = error.RuntimeIdentityMissing },
        .{ .code = protocol.ERR_RUNTIME_IDENTITY_MISMATCH, .expected = error.RuntimeIdentityMismatch },
    };
    for (cases) |case| {
        const encoded = try protocol.encodeErrorResponse(std.testing.allocator, 1, case.code, "identity rejected");
        defer std.testing.allocator.free(encoded);
        var parsed = try protocol.parseResponse(std.testing.allocator, encoded);
        defer parsed.deinit();
        try std.testing.expectError(case.expected, client.decodeStatus(&parsed));
    }
}

test "client rejects mismatched response ids in both call paths" {
    const allocator = std.testing.allocator;
    const wrong_id_body = try protocol.encodeOkResponse(allocator, 99, .{ .ok = true });
    defer allocator.free(wrong_id_body);

    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = wrong_id_body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    try std.testing.expectError(error.ResponseIdMismatch, client.callWithId(1, "core.status", .{}));
    try std.testing.expectError(error.ResponseIdMismatch, client.callAllocWithId(1, "core.status", .{}));
}

test "client accepts null id error as an uncorrelated failure" {
    const allocator = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":\"internal_error\",\"message\":\"OutOfMemory\"}}";
    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    var parsed = try client.callWithId(7, "core.status", .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.response.isOk());
    try std.testing.expect(parsed.response.id == null);
    try std.testing.expectEqualStrings("internal_error", parsed.response.err.?.code);
}

test "client handshake returns and records negotiated version" {
    const allocator = std.testing.allocator;
    const status_body = try protocol.encodeOkResponse(allocator, 1, .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 18,
        .pid = 4242,
        .session_count = 0,
        .chat_turn_count = 0,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(status_body);

    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = status_body,
    };
    defer mock.deinit();

    var client = Client.init(allocator, &mock, MockTransport.send);
    try std.testing.expectError(error.HandshakeRequired, client.negotiatedProtocolVersion());
    const result = try client.handshake();
    try std.testing.expectEqual(protocol.HEADLESS_PROTOCOL_VERSION, result.negotiated_version);
    try std.testing.expectEqual(result.negotiated_version, try client.negotiatedProtocolVersion());
    try std.testing.expectEqual(@as(u32, 4242), result.status.pid);
}

test "remote handshake verifies stable runtime identity and protocol major" {
    const status: protocol.StatusResult = .{
        .runtime_id = "runtime-a",
        .instance_id = "instance-a",
        .server_version = "1.0.0",
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 26,
        .pid = 1,
        .session_count = 0,
        .chat_turn_count = 0,
        .capabilities = protocol.Capabilities.phase1(),
    };
    try verifyRuntimeHandshake(status, null);
    try verifyRuntimeHandshake(status, "runtime-a");
    try std.testing.expectError(error.RuntimeIdentityMismatch, verifyRuntimeHandshake(status, "runtime-b"));

    var missing = status;
    missing.runtime_id = "";
    try std.testing.expectError(error.RuntimeIdentityMissing, verifyRuntimeHandshake(missing, null));
    var incompatible = status;
    incompatible.protocol.major += 1;
    try std.testing.expectError(error.IncompatibleRuntimeProtocol, verifyRuntimeHandshake(incompatible, null));
}

test "client status decode rejects invalid and incompatible daemon ranges" {
    const allocator = std.testing.allocator;
    var client = Client.initEncoder(allocator);

    const invalid_body = try protocol.encodeOkResponse(allocator, 1, .{
        .headless_protocol_version = 3,
        .min_supported = 3,
        .max_supported = 2,
        .protocol_version = 18,
        .pid = 1,
        .session_count = 0,
        .chat_turn_count = 0,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(invalid_body);
    var invalid = try client.parseResponseWithId(1, invalid_body);
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidProtocolRange, client.decodeStatus(&invalid));

    const incompatible_body = try protocol.encodeOkResponse(allocator, 2, .{
        .headless_protocol_version = 3,
        .min_supported = 2,
        .max_supported = 3,
        .protocol_version = 18,
        .pid = 1,
        .session_count = 0,
        .chat_turn_count = 0,
        .capabilities = protocol.Capabilities.phase1(),
    });
    defer allocator.free(incompatible_body);
    var incompatible = try client.parseResponseWithId(2, incompatible_body);
    defer incompatible.deinit();
    try std.testing.expectError(error.IncompatibleProtocolVersion, client.decodeStatus(&incompatible));
}

test "client encodeRequest assigns monotonic ids" {
    const allocator = std.testing.allocator;
    var client = Client.initEncoder(allocator);

    const first = try client.encodeRequest("session.list", .{});
    defer allocator.free(first.json);
    const second = try client.encodeRequest("chat.turn.tail", .{
        .turn_id = "turn-1",
        .after_seq = 7,
    });
    defer allocator.free(second.json);

    try std.testing.expectEqual(@as(u64, 1), first.id);
    try std.testing.expectEqual(@as(u64, 2), second.id);
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"method\":\"session.list\",\"params\":[]}",
        first.json,
    );
    try std.testing.expectEqualStrings(
        "{\"id\":2,\"method\":\"chat.turn.tail\",\"params\":{\"turn_id\":\"turn-1\",\"after_seq\":7}}",
        second.json,
    );

    const core_status = try client.encodeRequestWithId(3, "core.status", .{});
    defer allocator.free(core_status);
    try std.testing.expectEqualStrings(
        "{\"id\":3,\"method\":\"core.status\",\"params\":[]}",
        core_status,
    );
}

test "registry decoders are tolerant and own result strings" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    var client = Client.initEncoder(result_arena.allocator());
    const response_allocator = std.testing.allocator;

    var process_list = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"registry_revision\":7,\"processes\":[{\"id\":\"p1\",\"status\":\"running\"}],\"future\":true}}",
    );
    defer process_list.deinit();
    const process_list_result = try client.decodeProcessList(&process_list);
    try std.testing.expectEqual(@as(u64, 7), process_list_result.registry_revision);
    try std.testing.expectEqualStrings("p1", process_list_result.processes[0].id);
    try std.testing.expectEqual(registry.ProcessStatus.running, process_list_result.processes[0].status);

    var lease_check = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"allowed\":false,\"conflicts\":[{\"id\":\"l1\"}],\"future\":true}}",
    );
    defer lease_check.deinit();
    const lease_check_result = try client.decodeLeaseCheck(&lease_check);
    try std.testing.expect(!lease_check_result.allowed);
    try std.testing.expectEqualStrings("l1", lease_check_result.conflicts[0].id);

    var lease_acquire = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"acquired\":true,\"lease_id\":\"l1\"}}",
    );
    defer lease_acquire.deinit();
    const lease_acquire_result = try client.decodeLeaseAcquire(&lease_acquire);
    try std.testing.expect(lease_acquire_result.acquired);
    try std.testing.expectEqualStrings("l1", lease_acquire_result.lease_id.?);

    var lease_renew = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"renewed\":true,\"lease_id\":\"l1\"}}",
    );
    defer lease_renew.deinit();
    const lease_renew_result = try client.decodeLeaseRenew(&lease_renew);
    try std.testing.expect(lease_renew_result.renewed);
    try std.testing.expectEqualStrings("l1", lease_renew_result.lease_id);

    var lease_release = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"released\":true,\"released_count\":1}}",
    );
    defer lease_release.deinit();
    const lease_release_result = try client.decodeLeaseRelease(&lease_release);
    try std.testing.expect(lease_release_result.released);
    try std.testing.expectEqual(@as(u32, 1), lease_release_result.released_count);

    var notifications = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{\"notifications\":[{\"seq\":4,\"body\":\"conflict\"}],\"next_notification_seq\":5}}",
    );
    defer notifications.deinit();
    const notifications_result = try client.decodeNotifications(&notifications);
    try std.testing.expectEqual(@as(u64, 5), notifications_result.next_notification_seq);
    try std.testing.expectEqualStrings("conflict", notifications_result.notifications[0].body);

    var client_register = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"client_id\":\"c1\",\"persistent\":true}}",
    );
    defer client_register.deinit();
    const client_register_result = try client.decodeClientRegister(&client_register);
    try std.testing.expectEqualStrings("c1", client_register_result.client_id);
    try std.testing.expect(client_register_result.persistent);

    var client_heartbeat = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"client_id\":\"c1\",\"accepted\":true}}",
    );
    defer client_heartbeat.deinit();
    const client_heartbeat_result = try client.decodeClientHeartbeat(&client_heartbeat);
    try std.testing.expectEqualStrings("c1", client_heartbeat_result.client_id);
    try std.testing.expect(client_heartbeat_result.accepted);

    var client_close = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"client_id\":\"c1\",\"closed\":true,\"released_leases\":2}}",
    );
    defer client_close.deinit();
    const client_close_result = try client.decodeClientClose(&client_close);
    try std.testing.expectEqualStrings("c1", client_close_result.client_id);
    try std.testing.expect(client_close_result.closed);
    try std.testing.expectEqual(@as(u32, 2), client_close_result.released_leases);

    var daemon_stop = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"result\":{\"accepted\":true,\"stopping\":true}}",
    );
    defer daemon_stop.deinit();
    const daemon_stop_result = try client.decodeDaemonStop(&daemon_stop);
    try std.testing.expect(daemon_stop_result.accepted);
    try std.testing.expect(daemon_stop_result.stopping);

    var workspace_resolve = try protocol.parseResponse(
        response_allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":{\"workspace\":{\"id\":\"w1\",\"path\":\"/tmp/w\"}}}",
    );
    defer workspace_resolve.deinit();
    const workspace_resolve_result = try client.decodeWorkspaceResolve(&workspace_resolve);
    try std.testing.expectEqualStrings("w1", workspace_resolve_result.workspace.id);
    try std.testing.expectEqualStrings("/tmp/w", workspace_resolve_result.workspace.path);
}

test "registry decoders return RemoteError for error envelopes" {
    var client = Client.initEncoder(std.testing.allocator);
    var parsed = try protocol.parseResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"capability_unavailable\",\"message\":\"processes capability is unavailable\",\"data\":{\"feature\":\"processes\"}}}",
    );
    defer parsed.deinit();

    try std.testing.expectError(error.RemoteError, client.decodeProcessList(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeLeaseCheck(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeLeaseAcquire(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeLeaseRenew(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeLeaseRelease(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeNotifications(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeClientRegister(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeClientHeartbeat(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeClientClose(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeDaemonStop(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeWorkspaceResolve(&parsed));
}

test "decodeWriteResult decodes success payloads" {
    var client = Client.initEncoder(std.testing.allocator);
    var parsed = try protocol.parseResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"store_revision\":7,\"applied\":true,\"duplicate\":false}}",
    );
    defer parsed.deinit();

    const result = try client.decodeWriteResult(&parsed);
    try std.testing.expectEqual(@as(u64, 7), result.store_revision);
    try std.testing.expect(result.applied);
    try std.testing.expect(!result.duplicate);
}

test "decodeWriteResult rejects error envelopes" {
    var client = Client.initEncoder(std.testing.allocator);
    var parsed = try protocol.parseResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"store_busy\",\"message\":\"store is busy\"}}",
    );
    defer parsed.deinit();

    try std.testing.expectError(error.RemoteError, client.decodeWriteResult(&parsed));
}

test "decodeStoreStatus decodes all fields" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    var client = Client.initEncoder(result_arena.allocator());
    var drain_state: []const u8 = undefined;

    {
        var response_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer response_arena.deinit();
        var parsed = try protocol.parseResponse(
            response_arena.allocator(),
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"schema_version\":2,\"store_revision\":9,\"writer_ready\":true,\"queued_mutation_count\":3,\"drain_state\":\"open\"}}",
        );
        defer parsed.deinit();

        const result = try client.decodeStoreStatus(&parsed);
        try std.testing.expectEqual(@as(u32, 2), result.schema_version);
        try std.testing.expectEqual(@as(u64, 9), result.store_revision);
        try std.testing.expect(result.writer_ready);
        try std.testing.expectEqual(@as(usize, 3), result.queued_mutation_count);
        drain_state = result.drain_state;
    }

    try std.testing.expectEqualStrings("open", drain_state);
}

test "chat read decoders are tolerant and own result strings" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    var client = Client.initEncoder(result_arena.allocator());
    var thread_title: []const u8 = undefined;
    var list_cursor: []const u8 = undefined;
    var turn_status: []const u8 = undefined;

    {
        var response_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer response_arena.deinit();

        var thread_get = try protocol.parseResponse(
            response_arena.allocator(),
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"thread\":{\"local_thread_id\":\"t1\",\"title\":\"A thread\",\"messages\":[{\"message_id\":\"m1\",\"role\":\"user\",\"author\":\"me\",\"body\":\"hi\",\"future\":true}],\"future\":1},\"store_revision\":7,\"future_result\":{}}}",
        );
        defer thread_get.deinit();
        const thread_get_result = try client.decodeThreadGet(&thread_get);
        try std.testing.expectEqual(@as(u64, 7), thread_get_result.store_revision);
        try std.testing.expectEqualStrings("t1", thread_get_result.thread.local_thread_id);
        try std.testing.expectEqual(@as(usize, 1), thread_get_result.thread.messages.len);
        try std.testing.expectEqualStrings("hi", thread_get_result.thread.messages[0].body);
        thread_title = thread_get_result.thread.title;

        var thread_list = try protocol.parseResponse(
            response_arena.allocator(),
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"threads\":[{\"local_thread_id\":\"t1\",\"title\":\"A thread\",\"future\":true}],\"next_cursor\":\"cursor-2\",\"store_revision\":7,\"future\":[]}}",
        );
        defer thread_list.deinit();
        const thread_list_result = try client.decodeThreadList(&thread_list);
        try std.testing.expectEqual(@as(usize, 1), thread_list_result.threads.len);
        try std.testing.expectEqualStrings("t1", thread_list_result.threads[0].local_thread_id);
        // Defaults fill fields the daemon omitted.
        try std.testing.expectEqualStrings("opencode", thread_list_result.threads[0].provider);
        list_cursor = thread_list_result.next_cursor.?;

        var turn_record = try protocol.parseResponse(
            response_arena.allocator(),
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"turn_id\":\"turn-1\",\"workspace_id\":\"w1\",\"local_thread_id\":\"t1\",\"status\":\"completed\",\"started_at_ms\":50,\"provider\":\"codex\",\"future\":true}}",
        );
        defer turn_record.deinit();
        const turn_record_result = try client.decodeTurnRecord(&turn_record);
        try std.testing.expectEqualStrings("turn-1", turn_record_result.turn_id);
        try std.testing.expect(turn_record_result.finished_at_ms == null);
        turn_status = turn_record_result.status;
    }

    // The response arenas above are gone; decoded strings must still be valid.
    try std.testing.expectEqualStrings("A thread", thread_title);
    try std.testing.expectEqualStrings("cursor-2", list_cursor);
    try std.testing.expectEqualStrings("completed", turn_status);
}

test "chat read decoders return RemoteError for error envelopes" {
    var client = Client.initEncoder(std.testing.allocator);
    var parsed = try protocol.parseResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"resource_not_found\",\"message\":\"no such thread\"}}",
    );
    defer parsed.deinit();

    try std.testing.expectError(error.RemoteError, client.decodeThreadGet(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeThreadList(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeTurnRecord(&parsed));
}

test "remote projection and provider decoders tolerate additive fields" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    var client = Client.initEncoder(result_arena.allocator());

    var workspaces = try protocol.parseResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"W\",\"path\":\"/w\",\"repositories\":[{\"repository_id\":\"primary\",\"label\":\"Primary\",\"bindings\":[{\"runtime_id\":\"r1\",\"root_path\":\"/w\"}]}],\"future\":true}],\"store_revision\":2}}",
    );
    defer workspaces.deinit();
    const workspace_result = try client.decodeWorkspaceList(&workspaces);
    try std.testing.expectEqualStrings("r1", workspace_result.workspaces[0].repositories[0].bindings[0].runtime_id);

    var messages = try protocol.parseResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"messages\":[{\"sort_index\":4,\"message_id\":\"m4\",\"role\":\"assistant\",\"author\":\"Codex\",\"body\":\"done\",\"future\":1}],\"next_cursor\":\"b:4\",\"store_revision\":3}}",
    );
    defer messages.deinit();
    const message_result = try client.decodeMessageList(&messages);
    try std.testing.expectEqual(@as(usize, 4), message_result.messages[0].sort_index);
    try std.testing.expectEqualStrings("b:4", message_result.next_cursor.?);

    var providers = try protocol.parseResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"runtime_id\":\"r1\",\"instance_id\":\"i1\",\"probed_at_ms\":5,\"providers\":[{\"provider\":\"amp\",\"label\":\"Amp\",\"surfaces\":{\"terminal_tui\":true,\"mcp\":true,\"lifecycle\":true},\"installed\":true,\"state\":\"ready\",\"authentication\":\"unknown\",\"future\":true}]}}",
    );
    defer providers.deinit();
    const provider_result = try client.decodeProviderStatus(&providers);
    try std.testing.expect(!provider_result.providers[0].surfaces.native_chat);
    try std.testing.expect(provider_result.providers[0].surfaces.mcp);
}

test "repository manifest decoder owns the complete bounded projection" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    var client = Client.initEncoder(result_arena.allocator());
    var repository_label: []const u8 = undefined;
    var binding_root: []const u8 = undefined;

    {
        var parsed = try protocol.parseResponse(
            std.testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"workspace_id\":\"w1\",\"default_repository_id\":\"repo-api\",\"repositories\":[{\"repository_id\":\"repo-api\",\"label\":\"API\",\"bindings\":[{\"runtime_id\":\"0123456789abcdef0123456789abcdef\",\"root_path\":\"/srv/api\",\"availability\":\"available\",\"future\":true}],\"future\":1}],\"store_revision\":9,\"future\":{}}}",
        );
        defer parsed.deinit();
        const result = try client.decodeWorkspaceRepositoryManifest(&parsed);
        try std.testing.expectEqualStrings("w1", result.workspace_id);
        try std.testing.expectEqualStrings("repo-api", result.default_repository_id);
        try std.testing.expectEqual(@as(usize, 1), result.repositories.len);
        try std.testing.expectEqual(@as(u64, 9), result.store_revision);
        repository_label = result.repositories[0].label;
        binding_root = result.repositories[0].bindings[0].root_path;
    }

    try std.testing.expectEqualStrings("API", repository_label);
    try std.testing.expectEqualStrings("/srv/api", binding_root);
}

test "repository manifest typed calls share one fail-closed capability gate" {
    const allocator = std.testing.allocator;
    const ok_body = try protocol.encodeOkResponse(allocator, 1, .{
        .store_revision = @as(u64, 1),
        .applied = true,
        .duplicate = false,
    });
    defer allocator.free(ok_body);
    var mock: MockTransport = .{ .allocator = allocator, .canned_response = ok_body };
    defer mock.deinit();
    var client = Client.init(allocator, &mock, MockTransport.send);
    const unavailable: protocol.Capabilities = .{};
    const current = protocol.Capabilities.phase1();
    const mutation: store_protocol.MutationHeader = .{
        .request_key = "repo-test",
        .client_id = "client-test",
    };

    try std.testing.expectError(
        error.CapabilityUnavailable,
        client.callWorkspaceRepositoryManifest(unavailable, .{ .workspace_id = "w1" }),
    );
    try std.testing.expectError(
        error.CapabilityUnavailable,
        client.callWorkspaceRepositoryUpsert(unavailable, .{
            .mutation = mutation,
            .workspace_id = "w1",
            .repository = .{ .repository_id = "repo-api", .label = "API" },
        }),
    );
    try std.testing.expectError(
        error.CapabilityUnavailable,
        client.callWorkspaceRepositoryRemove(unavailable, .{
            .mutation = mutation,
            .workspace_id = "w1",
            .repository_id = "repo-api",
        }),
    );
    try std.testing.expectError(
        error.CapabilityUnavailable,
        client.callWorkspaceRepositoryDefaultSet(unavailable, .{
            .mutation = mutation,
            .workspace_id = "w1",
            .repository_id = "repo-api",
        }),
    );
    try std.testing.expectError(
        error.CapabilityUnavailable,
        client.callWorkspaceRepositoryBindingUpsert(unavailable, .{
            .mutation = mutation,
            .workspace_id = "w1",
            .repository_id = "repo-api",
            .binding = .{
                .runtime_id = "0123456789abcdef0123456789abcdef",
                .root_path = "/srv/api",
            },
        }),
    );
    try std.testing.expectError(
        error.CapabilityUnavailable,
        client.callWorkspaceRepositoryBindingRemove(unavailable, .{
            .mutation = mutation,
            .workspace_id = "w1",
            .repository_id = "repo-api",
            .runtime_id = "0123456789abcdef0123456789abcdef",
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);

    var manifest = try client.callWorkspaceRepositoryManifest(current, .{ .workspace_id = "w1" });
    defer manifest.deinit();
    try expectMockRequestMethod(&mock, store_protocol.METHOD_WORKSPACE_REPOSITORY_MANIFEST_GET);
    client.next_id = 1;
    var upsert = try client.callWorkspaceRepositoryUpsert(current, .{
        .mutation = mutation,
        .workspace_id = "w1",
        .repository = .{ .repository_id = "repo-api", .label = "API" },
    });
    defer upsert.deinit();
    try expectMockRequestMethod(&mock, store_protocol.METHOD_WORKSPACE_REPOSITORY_UPSERT);
    client.next_id = 1;
    var remove = try client.callWorkspaceRepositoryRemove(current, .{
        .mutation = mutation,
        .workspace_id = "w1",
        .repository_id = "repo-api",
    });
    defer remove.deinit();
    try expectMockRequestMethod(&mock, store_protocol.METHOD_WORKSPACE_REPOSITORY_REMOVE);
    client.next_id = 1;
    var set_default = try client.callWorkspaceRepositoryDefaultSet(current, .{
        .mutation = mutation,
        .workspace_id = "w1",
        .repository_id = "repo-api",
    });
    defer set_default.deinit();
    try expectMockRequestMethod(&mock, store_protocol.METHOD_WORKSPACE_REPOSITORY_DEFAULT_SET);
    client.next_id = 1;
    var binding_upsert = try client.callWorkspaceRepositoryBindingUpsert(current, .{
        .mutation = mutation,
        .workspace_id = "w1",
        .repository_id = "repo-api",
        .binding = .{
            .runtime_id = "0123456789abcdef0123456789abcdef",
            .root_path = "/srv/api",
        },
    });
    defer binding_upsert.deinit();
    try expectMockRequestMethod(&mock, store_protocol.METHOD_WORKSPACE_REPOSITORY_BINDING_UPSERT);
    client.next_id = 1;
    var binding_remove = try client.callWorkspaceRepositoryBindingRemove(current, .{
        .mutation = mutation,
        .workspace_id = "w1",
        .repository_id = "repo-api",
        .runtime_id = "0123456789abcdef0123456789abcdef",
    });
    defer binding_remove.deinit();
    try expectMockRequestMethod(&mock, store_protocol.METHOD_WORKSPACE_REPOSITORY_BINDING_REMOVE);
}

test "changes and composite snapshot decoders are tolerant and own result strings" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    var client = Client.initEncoder(result_arena.allocator());
    var entry_topic: []const u8 = undefined;
    var incomplete_scope: []const u8 = undefined;

    {
        var response_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer response_arena.deinit();

        var changes = try protocol.parseResponse(
            response_arena.allocator(),
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"envelope\":{\"instance_nonce\":\"daemon-a\",\"registry_revision\":12},\"store_revision\":9,\"entries\":[{\"change_seq\":6,\"topic\":\"chat.thread\",\"resource_id\":\"t1\",\"workspace_id\":\"w1\",\"store_revision\":9,\"future\":true}],\"next_cursor\":6,\"journal_floor_seq\":2,\"expired\":false,\"future\":{}}}",
        );
        defer changes.deinit();
        const changes_result = try client.decodeChanges(&changes);
        try std.testing.expectEqualStrings("daemon-a", changes_result.envelope.instance_nonce);
        try std.testing.expectEqual(@as(u64, 9), changes_result.store_revision);
        try std.testing.expectEqual(@as(u64, 6), changes_result.next_cursor);
        try std.testing.expectEqual(@as(u64, 2), changes_result.journal_floor_seq);
        try std.testing.expect(!changes_result.expired);
        try std.testing.expectEqual(@as(usize, 1), changes_result.entries.len);
        try std.testing.expectEqualStrings("t1", changes_result.entries[0].resource_id);
        try std.testing.expect(changes_result.entries[0].registry_revision == null);
        entry_topic = changes_result.entries[0].topic;

        var composite = try protocol.parseResponse(
            response_arena.allocator(),
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"snapshot\":{\"store_revision\":9},\"store_revision\":9,\"envelope\":{\"instance_nonce\":\"daemon-a\",\"registry_revision\":12},\"change_cursor\":6,\"processes\":[{\"id\":\"p1\",\"status\":\"running\",\"future\":true}],\"leases\":[{\"id\":\"l1\"}],\"sessions\":[{\"session_id\":\"s1\",\"running\":true}],\"turns\":[{\"turn_id\":\"turn-1\",\"workspace_id\":\"w1\",\"local_thread_id\":\"t1\",\"status\":\"completed\",\"started_at_ms\":50,\"provider\":\"codex\"}],\"incomplete_scopes\":[\"turns\"],\"future\":true}}",
        );
        defer composite.deinit();
        const composite_result = try client.decodeCompositeSnapshot(&composite);
        try std.testing.expectEqual(@as(u64, 9), composite_result.store_revision);
        try std.testing.expectEqual(@as(?u64, 6), composite_result.change_cursor);
        try std.testing.expectEqualStrings("daemon-a", composite_result.envelope.?.instance_nonce);
        try std.testing.expectEqualStrings("p1", composite_result.processes[0].id);
        try std.testing.expectEqualStrings("l1", composite_result.leases[0].id);
        try std.testing.expectEqualStrings("s1", composite_result.sessions[0].session_id);
        try std.testing.expect(composite_result.sessions[0].running);
        try std.testing.expectEqualStrings("turn-1", composite_result.turns[0].turn_id);
        incomplete_scope = composite_result.incomplete_scopes[0];

        // The M3 store-only result still decodes with composite fields absent.
        var store_only = try protocol.parseResponse(
            response_arena.allocator(),
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"snapshot\":{\"store_revision\":9},\"store_revision\":9}}",
        );
        defer store_only.deinit();
        const store_only_result = try client.decodeCompositeSnapshot(&store_only);
        try std.testing.expect(store_only_result.envelope == null);
        try std.testing.expect(store_only_result.change_cursor == null);
        try std.testing.expectEqual(@as(usize, 0), store_only_result.incomplete_scopes.len);
    }

    // The response arenas above are gone; decoded strings must still be valid.
    try std.testing.expectEqualStrings("chat.thread", entry_topic);
    try std.testing.expectEqualStrings("turns", incomplete_scope);
}

test "changes and composite snapshot decoders return RemoteError for error envelopes" {
    var client = Client.initEncoder(std.testing.allocator);
    var parsed = try protocol.parseResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"revision_expired\",\"message\":\"cursor below journal floor\",\"data\":{\"floor_seq\":42}}}",
    );
    defer parsed.deinit();

    try std.testing.expectError(error.RemoteError, client.decodeChanges(&parsed));
    try std.testing.expectError(error.RemoteError, client.decodeCompositeSnapshot(&parsed));
    try std.testing.expectEqualStrings(protocol.ERR_REVISION_EXPIRED, parsed.response.err.?.code);
}

test "advanceChangeCursor advances, surfaces expiry, and resets across instances" {
    const same_instance: registry.RegistryRevisionEnvelope = .{
        .instance_nonce = "daemon-a",
        .registry_revision = 12,
    };

    // Ordinary advance: adopt next_cursor, no snapshot required.
    const advanced = advanceChangeCursor(same_instance, .{
        .envelope = .{ .instance_nonce = "daemon-a", .registry_revision = 13 },
        .next_cursor = 7,
    });
    try std.testing.expectEqual(@as(u64, 7), advanced.next_cursor);
    try std.testing.expect(!advanced.snapshot_required);

    // Heartbeat (no entries, unchanged cursor) is still a plain advance.
    const heartbeat = advanceChangeCursor(same_instance, .{
        .envelope = same_instance,
        .next_cursor = 7,
    });
    try std.testing.expectEqual(@as(u64, 7), heartbeat.next_cursor);
    try std.testing.expect(!heartbeat.snapshot_required);

    // Journal expiry forces a snapshot before trusting increments again.
    const expired = advanceChangeCursor(same_instance, .{
        .envelope = same_instance,
        .next_cursor = 40,
        .journal_floor_seq = 40,
        .expired = true,
    });
    try std.testing.expectEqual(@as(u64, 40), expired.next_cursor);
    try std.testing.expect(expired.snapshot_required);

    // A daemon-instance change invalidates the cursor even without expiry.
    const replaced = advanceChangeCursor(same_instance, .{
        .envelope = .{ .instance_nonce = "daemon-b", .registry_revision = 1 },
        .next_cursor = 1,
    });
    try std.testing.expectEqual(@as(u64, 1), replaced.next_cursor);
    try std.testing.expect(replaced.snapshot_required);

    // First poll has no previous envelope; nothing to reset against.
    const first = advanceChangeCursor(null, .{
        .envelope = same_instance,
        .next_cursor = 3,
    });
    try std.testing.expectEqual(@as(u64, 3), first.next_cursor);
    try std.testing.expect(!first.snapshot_required);
}

test "store capability gate reports capability_unavailable" {
    const phase1 = protocol.Capabilities.phase1();
    var client = Client.initEncoder(std.testing.allocator);
    try std.testing.expectError(error.CapabilityUnavailable, requireCapability(phase1, .store));
    try std.testing.expectError(error.CapabilityUnavailable, client.requireCapability(phase1, .store));

    const unavailable = capabilityUnavailable(.store);
    try std.testing.expectEqualStrings("store", RequiredCapability.store.wireName());
    try std.testing.expectEqualStrings(protocol.ERR_CAPABILITY_UNAVAILABLE, unavailable.code);
    try std.testing.expectEqualStrings("store capability is unavailable", unavailable.message);
}

test "remote read and repository manifest capabilities are explicit" {
    const capabilities = protocol.Capabilities.phase1();
    try requireCapability(capabilities, .workspace_pagination);
    try requireCapability(capabilities, .thread_pagination);
    try requireCapability(capabilities, .message_pagination);
    try requireCapability(capabilities, .provider_status);
    try requireCapability(capabilities, .repository_projection);
    try requireCapability(capabilities, .repository_manifests);
    try std.testing.expectEqualStrings("provider_status", RequiredCapability.provider_status.wireName());
}

test "M4-P5 chat flip: current daemon passes, old-daemon shape rejects daemon-direct chat" {
    // Flip side A: a current daemon (phase1) advertises chat, so the shared
    // capability check helper admits daemon-direct chat calls.
    const current = protocol.Capabilities.phase1();
    try requireCapability(current, .chat);
    try requireDaemonDirectCapability(current, .chat);

    // Flip side B: an old daemon serialized `chat:false` explicitly; the
    // helper must reject with CapabilityUnavailable, and the caller surfaces
    // capabilityUnavailable(.chat) — never a silent re-route through Live.
    const old_shape =
        \\{"headless_protocol_version":1,"min_supported":1,"max_supported":1,"capabilities":{"terminal_raw":true,"terminal_grid":false,"chat":false,"processes":false,"leases":false,"browser_execution":false,"browser_presentation":false}}
    ;
    var parsed = try std.json.parseFromSlice(protocol.CapabilitiesResult, std.testing.allocator, old_shape, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectError(
        error.CapabilityUnavailable,
        requireDaemonDirectCapability(parsed.value.capabilities, .chat),
    );

    const unavailable = capabilityUnavailable(.chat);
    try std.testing.expectEqualStrings("chat", RequiredCapability.chat.wireName());
    try std.testing.expectEqualStrings(protocol.ERR_CAPABILITY_UNAVAILABLE, unavailable.code);
    try std.testing.expectEqualStrings("chat capability is unavailable", unavailable.message);
}

test "M5-P5 typed snapshot and changes calls gate old daemons without fallback" {
    const allocator = std.testing.allocator;
    // These fields did not exist on an old daemon, so tolerant decoding must
    // leave both false. The typed calls reject before transport: zero legacy
    // polls or alternate-route requests can be silently re-enabled.
    const old_shape =
        \\{"headless_protocol_version":1,"min_supported":1,"max_supported":1,"capabilities":{"terminal_raw":true}}
    ;
    var old = try std.json.parseFromSlice(protocol.CapabilitiesResult, allocator, old_shape, .{
        .ignore_unknown_fields = true,
    });
    defer old.deinit();

    var mock: MockTransport = .{
        .allocator = allocator,
        .canned_response = "unused",
    };
    defer mock.deinit();
    var client = Client.init(allocator, &mock, MockTransport.send);
    try std.testing.expectError(
        error.CapabilityUnavailable,
        client.callCompositeSnapshot(old.value.capabilities, .{}),
    );
    try std.testing.expectError(
        error.CapabilityUnavailable,
        client.callChanges(old.value.capabilities, .{}),
    );
    try std.testing.expectEqual(@as(usize, 0), mock.call_count);

    // Version-skew defense: even if a peer advertises `changes` but answers
    // method_not_found, the explicit direct call returns that one envelope
    // unchanged. There is no second transport call and no fallback arm.
    const missing_body = try protocol.encodeErrorResponse(
        allocator,
        1,
        "method_not_found",
        changes_protocol.METHOD_CORE_CHANGES,
    );
    defer allocator.free(missing_body);
    mock.canned_response = missing_body;
    var advertised = old.value.capabilities;
    advertised.changes = true;
    var missing = try client.callChanges(advertised, .{ .cursor = 7 });
    defer missing.deinit();
    try std.testing.expect(!missing.response.isOk());
    try std.testing.expectEqualStrings("method_not_found", missing.response.err.?.code);
    try std.testing.expectEqual(@as(usize, 1), mock.call_count);
}

test "capability checks support direct registry mode" {
    const phase1 = protocol.Capabilities.phase1();
    try requireCapability(phase1, .terminal_raw);
    try std.testing.expectError(error.CapabilityUnavailable, requireCapability(phase1, .processes));
    try std.testing.expectError(error.CapabilityUnavailable, requireDaemonDirectCapability(phase1, .leases));
    try std.testing.expectError(error.CapabilityUnavailable, requireFeature(phase1, .browser_navigation));

    const unavailable = capabilityUnavailable(.processes);
    try std.testing.expectEqualStrings(protocol.ERR_CAPABILITY_UNAVAILABLE, unavailable.code);
    try std.testing.expectEqualStrings("processes capability is unavailable", unavailable.message);

    const capable = protocol.Capabilities.withBrowser(.{ .navigation = true }, false);
    try requireCapability(capable, .browser_navigation);
    try requireFeature(capable, .browser_navigation);
}
