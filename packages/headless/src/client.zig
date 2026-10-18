//! Transport-neutral typed client for the headless protocol.
//!
//! The caller injects a send function. Pure encoding and decoding live in
//! `client_codec.zig`, also exposed as `codec` for transport-owning clients.

const std = @import("std");
pub const codec = @import("client_codec.zig");
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

const ConfiguredRequestTarget = codec.ConfiguredRequestTarget;

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

    pub const encodeRequest = codec.methodsFor(Client).encodeRequest;
    pub const encodeRequestWithId = codec.methodsFor(Client).encodeRequestWithId;
    pub const parseResponse = codec.methodsFor(Client).parseResponse;
    pub const parseResponseWithId = codec.methodsFor(Client).parseResponseWithId;

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

    pub const negotiatedProtocolVersion = codec.methodsFor(Client).negotiatedProtocolVersion;
    pub const decodeStatus = codec.methodsFor(Client).decodeStatus;
    pub const decodeCapabilities = codec.methodsFor(Client).decodeCapabilities;
    pub const decodeProcessList = codec.methodsFor(Client).decodeProcessList;
    pub const decodeLeaseCheck = codec.methodsFor(Client).decodeLeaseCheck;
    pub const decodeLeaseAcquire = codec.methodsFor(Client).decodeLeaseAcquire;
    pub const decodeLeaseRenew = codec.methodsFor(Client).decodeLeaseRenew;
    pub const decodeLeaseRelease = codec.methodsFor(Client).decodeLeaseRelease;
    pub const decodeNotifications = codec.methodsFor(Client).decodeNotifications;
    pub const decodeClientRegister = codec.methodsFor(Client).decodeClientRegister;
    pub const decodeClientHeartbeat = codec.methodsFor(Client).decodeClientHeartbeat;
    pub const decodeClientClose = codec.methodsFor(Client).decodeClientClose;
    pub const decodeDaemonStop = codec.methodsFor(Client).decodeDaemonStop;
    pub const decodeWorkspaceResolve = codec.methodsFor(Client).decodeWorkspaceResolve;
    pub const decodeWriteResult = codec.methodsFor(Client).decodeWriteResult;
    pub const decodeStoreStatus = codec.methodsFor(Client).decodeStoreStatus;
    pub const decodeThreadGet = codec.methodsFor(Client).decodeThreadGet;
    pub const decodeWorkspaceList = codec.methodsFor(Client).decodeWorkspaceList;
    pub const decodeWorkspaceRepositoryManifest = codec.methodsFor(Client).decodeWorkspaceRepositoryManifest;
    pub const decodeThreadList = codec.methodsFor(Client).decodeThreadList;
    pub const decodeMessageList = codec.methodsFor(Client).decodeMessageList;
    pub const decodeSurfaceCompletionObserve = codec.methodsFor(Client).decodeSurfaceCompletionObserve;
    pub const decodeSurfaceCommitProofClassify = codec.methodsFor(Client).decodeSurfaceCommitProofClassify;
    pub const decodeProviderModelsList = codec.methodsFor(Client).decodeProviderModelsList;
    pub const decodeProviderStatus = codec.methodsFor(Client).decodeProviderStatus;
    pub const decodeProviderAuthStatus = codec.methodsFor(Client).decodeProviderAuthStatus;
    pub const decodeProviderThreadsList = codec.methodsFor(Client).decodeProviderThreadsList;
    pub const decodeProviderThreadRead = codec.methodsFor(Client).decodeProviderThreadRead;
    pub const decodeProviderThreadInterrupt = codec.methodsFor(Client).decodeProviderThreadInterrupt;
    pub const decodeProviderThreadSteer = codec.methodsFor(Client).decodeProviderThreadSteer;
    pub const decodeProviderSlashList = codec.methodsFor(Client).decodeProviderSlashList;
    pub const decodeProviderSlashRun = codec.methodsFor(Client).decodeProviderSlashRun;
    pub const decodeProviderCodexBackgroundStatus = codec.methodsFor(Client).decodeProviderCodexBackgroundStatus;
    pub const decodeProviderCodexBackgroundTerminate = codec.methodsFor(Client).decodeProviderCodexBackgroundTerminate;
    pub const decodeProviderIntegrationsInspect = codec.methodsFor(Client).decodeProviderIntegrationsInspect;
    pub const decodeProviderHooksSet = codec.methodsFor(Client).decodeProviderHooksSet;
    pub const decodeProviderMcpSet = codec.methodsFor(Client).decodeProviderMcpSet;
    pub const decodeProviderTitleGenerate = codec.methodsFor(Client).decodeProviderTitleGenerate;
    pub const decodeTurnRecord = codec.methodsFor(Client).decodeTurnRecord;
    pub const decodeChanges = codec.methodsFor(Client).decodeChanges;
    pub const decodeCompositeSnapshot = codec.methodsFor(Client).decodeCompositeSnapshot;
    pub const decodePairingGrantCreate = codec.methodsFor(Client).decodePairingGrantCreate;
    pub const decodePairingGrantList = codec.methodsFor(Client).decodePairingGrantList;
    pub const decodePairingGrantRevoke = codec.methodsFor(Client).decodePairingGrantRevoke;
    pub const decodeDeviceList = codec.methodsFor(Client).decodeDeviceList;
    pub const decodeDeviceRevoke = codec.methodsFor(Client).decodeDeviceRevoke;
    pub const decodeConnectStatus = codec.methodsFor(Client).decodeConnectStatus;
    pub const decodeConnectBootstrapConsume = codec.methodsFor(Client).decodeConnectBootstrapConsume;

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

    pub fn callProviderModelsList(
        self: *Client,
        capabilities: protocol.Capabilities,
        request: providers_protocol.ModelsListRequest,
    ) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_MODELS_LIST, request);
    }

    pub fn callProviderAuthStatus(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.AuthStatusRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_AUTH_STATUS, request);
    }

    pub fn callProviderThreadsList(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.ThreadsListRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_THREADS_LIST, request);
    }

    pub fn callProviderThreadRead(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.ThreadReadRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_THREAD_READ, request);
    }

    pub fn callProviderThreadInterrupt(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.ThreadInterruptRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_THREAD_INTERRUPT, request);
    }

    pub fn callProviderThreadSteer(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.ThreadSteerRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_THREAD_STEER, request);
    }

    pub fn callProviderSlashList(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.SlashListRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_SLASH_LIST, request);
    }

    pub fn callProviderSlashRun(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.SlashRunRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_SLASH_RUN, request);
    }

    pub fn callProviderCodexBackgroundStatus(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.CodexBackgroundRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_CODEX_BACKGROUND_STATUS, request);
    }

    pub fn callProviderCodexBackgroundTerminate(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.CodexBackgroundRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_CODEX_BACKGROUND_TERMINATE, request);
    }

    pub fn callProviderIntegrationsInspect(self: *Client, capabilities: protocol.Capabilities) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(
            providers_protocol.METHOD_PROVIDER_INTEGRATIONS_INSPECT,
            providers_protocol.IntegrationsInspectRequest{},
        );
    }

    pub fn callProviderHooksSet(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.HooksSetRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_HOOKS_SET, request);
    }

    pub fn callProviderMcpSet(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.McpSetRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_MCP_SET, request);
    }

    pub fn callProviderTitleGenerate(self: *Client, capabilities: protocol.Capabilities, request: providers_protocol.TitleGenerateRequest) !protocol.ParsedResponse {
        try requireCapabilityChecked(capabilities, .provider_status);
        return try self.call(providers_protocol.METHOD_PROVIDER_TITLE_GENERATE, request);
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

    fn send(self: *Client, request_json: []const u8) ![]u8 {
        const transport = self.transport orelse return error.TransportUnavailable;
        const context = self.transport_ctx orelse return error.TransportUnavailable;
        return try transport(context, request_json);
    }
};

const validateConnectProtocolVersion = codec.validateConnectProtocolVersion;

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
