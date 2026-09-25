//! Sans-I/O request codec and typed response decoding for headless clients.
//! No transport, sockets, filesystem, threads, or std.Io instance is required.
//! Encoded buffers and ParsedResponse values belong to the caller. Typed
//! results use the codec allocator; use an arena for their lifetime. Strict
//! access/Connect decodes retain their existing response-DOM borrowing rules.

const std = @import("std");
const protocol = @import("protocol.zig");
const registry = @import("registry_protocol.zig");
const store_protocol = @import("store_protocol.zig");
const changes_protocol = @import("changes_protocol.zig");
const providers_protocol = @import("providers_protocol.zig");
const access_protocol = @import("access_protocol.zig");
const connect_protocol = @import("connect_protocol.zig");

pub const ConfiguredRequestTarget = struct {
    runtime_id: [32]u8,
    instance_id: [32]u8,

    pub fn init(target: protocol.RequestTarget) !ConfiguredRequestTarget {
        try protocol.validateRequestTarget(target);
        var configured: ConfiguredRequestTarget = undefined;
        @memcpy(configured.runtime_id[0..], target.runtime_id);
        @memcpy(configured.instance_id[0..], target.instance_id);
        return configured;
    }

    pub fn borrow(self: *const ConfiguredRequestTarget) protocol.RequestTarget {
        return .{
            .runtime_id = &self.runtime_id,
            .instance_id = &self.instance_id,
        };
    }
};

/// State for callers that execute transport effects themselves.
pub const Codec = struct {
    allocator: std.mem.Allocator,
    request_target: ?ConfiguredRequestTarget = null,
    next_id: u64 = 1,
    negotiated_version: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator) Codec {
        return .{ .allocator = allocator };
    }

    /// Copy and validate the identity so later caller mutations cannot retarget requests.
    pub fn initTargeted(allocator: std.mem.Allocator, target: protocol.RequestTarget) !Codec {
        return .{ .allocator = allocator, .request_target = try ConfiguredRequestTarget.init(target) };
    }

    pub const encodeRequest = methodsFor(Codec).encodeRequest;
    pub const encodeRequestWithId = methodsFor(Codec).encodeRequestWithId;
    pub const parseResponse = methodsFor(Codec).parseResponse;
    pub const parseResponseWithId = methodsFor(Codec).parseResponseWithId;
    pub const negotiatedProtocolVersion = methodsFor(Codec).negotiatedProtocolVersion;
    pub const decodeStatus = methodsFor(Codec).decodeStatus;
    pub const decodeCapabilities = methodsFor(Codec).decodeCapabilities;
    pub const decodeProcessList = methodsFor(Codec).decodeProcessList;
    pub const decodeLeaseCheck = methodsFor(Codec).decodeLeaseCheck;
    pub const decodeLeaseAcquire = methodsFor(Codec).decodeLeaseAcquire;
    pub const decodeLeaseRenew = methodsFor(Codec).decodeLeaseRenew;
    pub const decodeLeaseRelease = methodsFor(Codec).decodeLeaseRelease;
    pub const decodeNotifications = methodsFor(Codec).decodeNotifications;
    pub const decodeClientRegister = methodsFor(Codec).decodeClientRegister;
    pub const decodeClientHeartbeat = methodsFor(Codec).decodeClientHeartbeat;
    pub const decodeClientClose = methodsFor(Codec).decodeClientClose;
    pub const decodeDaemonStop = methodsFor(Codec).decodeDaemonStop;
    pub const decodeWorkspaceResolve = methodsFor(Codec).decodeWorkspaceResolve;
    pub const decodeWriteResult = methodsFor(Codec).decodeWriteResult;
    pub const decodeStoreStatus = methodsFor(Codec).decodeStoreStatus;
    pub const decodeThreadGet = methodsFor(Codec).decodeThreadGet;
    pub const decodeWorkspaceList = methodsFor(Codec).decodeWorkspaceList;
    pub const decodeWorkspaceRepositoryManifest = methodsFor(Codec).decodeWorkspaceRepositoryManifest;
    pub const decodeThreadList = methodsFor(Codec).decodeThreadList;
    pub const decodeMessageList = methodsFor(Codec).decodeMessageList;
    pub const decodeSurfaceCompletionObserve = methodsFor(Codec).decodeSurfaceCompletionObserve;
    pub const decodeSurfaceCommitProofClassify = methodsFor(Codec).decodeSurfaceCommitProofClassify;
    pub const decodeProviderModelsList = methodsFor(Codec).decodeProviderModelsList;
    pub const decodeProviderStatus = methodsFor(Codec).decodeProviderStatus;
    pub const decodeProviderAuthStatus = methodsFor(Codec).decodeProviderAuthStatus;
    pub const decodeProviderThreadsList = methodsFor(Codec).decodeProviderThreadsList;
    pub const decodeProviderThreadRead = methodsFor(Codec).decodeProviderThreadRead;
    pub const decodeProviderThreadInterrupt = methodsFor(Codec).decodeProviderThreadInterrupt;
    pub const decodeProviderThreadSteer = methodsFor(Codec).decodeProviderThreadSteer;
    pub const decodeProviderSlashList = methodsFor(Codec).decodeProviderSlashList;
    pub const decodeProviderSlashRun = methodsFor(Codec).decodeProviderSlashRun;
    pub const decodeProviderCodexBackgroundStatus = methodsFor(Codec).decodeProviderCodexBackgroundStatus;
    pub const decodeProviderCodexBackgroundTerminate = methodsFor(Codec).decodeProviderCodexBackgroundTerminate;
    pub const decodeProviderIntegrationsInspect = methodsFor(Codec).decodeProviderIntegrationsInspect;
    pub const decodeProviderHooksSet = methodsFor(Codec).decodeProviderHooksSet;
    pub const decodeProviderMcpSet = methodsFor(Codec).decodeProviderMcpSet;
    pub const decodeProviderTitleGenerate = methodsFor(Codec).decodeProviderTitleGenerate;
    pub const decodeTurnRecord = methodsFor(Codec).decodeTurnRecord;
    pub const decodeChanges = methodsFor(Codec).decodeChanges;
    pub const decodeCompositeSnapshot = methodsFor(Codec).decodeCompositeSnapshot;
    pub const decodePairingGrantCreate = methodsFor(Codec).decodePairingGrantCreate;
    pub const decodePairingGrantList = methodsFor(Codec).decodePairingGrantList;
    pub const decodePairingGrantRevoke = methodsFor(Codec).decodePairingGrantRevoke;
    pub const decodeDeviceList = methodsFor(Codec).decodeDeviceList;
    pub const decodeDeviceRevoke = methodsFor(Codec).decodeDeviceRevoke;
    pub const decodeConnectStatus = methodsFor(Codec).decodeConnectStatus;
    pub const decodeConnectBootstrapConsume = methodsFor(Codec).decodeConnectBootstrapConsume;
};

/// Shared codec methods preserve Client's existing public fields and API.
/// Self supplies allocator, request_target, next_id, and negotiated_version.
pub fn methodsFor(comptime Self: type) type {
    return struct {
        /// Build a request envelope without sending (useful for custom transports).
        pub fn encodeRequest(self: *Self, method: []const u8, params: anytype) !struct { id: u64, json: []u8 } {
            const id = self.next_id;
            self.next_id += 1;
            const json = try self.encodeRequestWithId(id, method, params);
            return .{ .id = id, .json = json };
        }

        /// Build a request envelope with an explicit id without advancing the generated id.
        pub fn encodeRequestWithId(self: *Self, id: u64, method: []const u8, params: anytype) ![]u8 {
            if (self.request_target) |*target| {
                return try protocol.encodeTargetedRequest(self.allocator, id, method, params, target.borrow());
            }
            return try protocol.encodeRequest(self.allocator, id, method, params);
        }

        /// Parse a response envelope produced by any transport.
        pub fn parseResponse(self: *Self, response_json: []const u8) !protocol.ParsedResponse {
            return try protocol.parseResponse(self.allocator, response_json);
        }

        /// Parse and correlate a response with the request that produced it.
        /// Numeric mismatches return `error.ResponseIdMismatch`; null-id errors are
        /// uncorrelated daemon failures and remain valid error responses.
        pub fn parseResponseWithId(self: *Self, request_id: u64, response_json: []const u8) !protocol.ParsedResponse {
            var parsed = try protocol.parseResponse(self.allocator, response_json);
            errdefer parsed.deinit();
            if (parsed.response.id) |response_id| {
                if (response_id != request_id) return error.ResponseIdMismatch;
            }
            return parsed;
        }

        /// Return the version selected by the most recent successful status or
        /// capabilities decode. Before a successful handshake this returns
        /// `error.HandshakeRequired`.
        pub fn negotiatedProtocolVersion(self: *const Self) !u32 {
            return self.negotiated_version orelse error.HandshakeRequired;
        }

        /// Decode a successful `core.status` response into its typed result.
        pub fn decodeStatus(self: *Self, parsed: *const protocol.ParsedResponse) !protocol.StatusResult {
            const status = try decodeResult(self, protocol.StatusResult, parsed);
            _ = try recordNegotiatedRange(self, status.min_supported, status.max_supported);
            return status;
        }

        /// Decode a successful `core.capabilities` response into its typed result.
        pub fn decodeCapabilities(self: *Self, parsed: *const protocol.ParsedResponse) !protocol.CapabilitiesResult {
            const capabilities = try decodeResult(self, protocol.CapabilitiesResult, parsed);
            _ = try recordNegotiatedRange(self, capabilities.min_supported, capabilities.max_supported);
            return capabilities;
        }

        /// Decode a successful `process.list` response.
        pub fn decodeProcessList(self: *Self, parsed: *const protocol.ParsedResponse) !registry.ProcessListResult {
            return try decodeResult(self, registry.ProcessListResult, parsed);
        }

        /// Decode a successful `lease.check` response.
        pub fn decodeLeaseCheck(self: *Self, parsed: *const protocol.ParsedResponse) !registry.LeaseCheckResult {
            return try decodeResult(self, registry.LeaseCheckResult, parsed);
        }

        /// Decode a successful `lease.acquire` response.
        pub fn decodeLeaseAcquire(self: *Self, parsed: *const protocol.ParsedResponse) !registry.LeaseAcquireResult {
            return try decodeResult(self, registry.LeaseAcquireResult, parsed);
        }

        /// Decode a successful `lease.renew` response.
        pub fn decodeLeaseRenew(self: *Self, parsed: *const protocol.ParsedResponse) !registry.LeaseRenewResult {
            return try decodeResult(self, registry.LeaseRenewResult, parsed);
        }

        /// Decode a successful `lease.release` response.
        pub fn decodeLeaseRelease(self: *Self, parsed: *const protocol.ParsedResponse) !registry.LeaseReleaseResult {
            return try decodeResult(self, registry.LeaseReleaseResult, parsed);
        }

        /// Decode a successful `daemon.notifications` response.
        pub fn decodeNotifications(self: *Self, parsed: *const protocol.ParsedResponse) !registry.NotificationsResult {
            return try decodeResult(self, registry.NotificationsResult, parsed);
        }

        /// Decode a successful `daemon.client.register` response.
        pub fn decodeClientRegister(self: *Self, parsed: *const protocol.ParsedResponse) !registry.ClientRegisterResult {
            return try decodeResult(self, registry.ClientRegisterResult, parsed);
        }

        /// Decode a successful `daemon.client.heartbeat` response.
        pub fn decodeClientHeartbeat(self: *Self, parsed: *const protocol.ParsedResponse) !registry.ClientHeartbeatResult {
            return try decodeResult(self, registry.ClientHeartbeatResult, parsed);
        }

        /// Decode a successful `daemon.client.close` response.
        pub fn decodeClientClose(self: *Self, parsed: *const protocol.ParsedResponse) !registry.ClientCloseResult {
            return try decodeResult(self, registry.ClientCloseResult, parsed);
        }

        /// Decode a successful `daemon.stop` response.
        pub fn decodeDaemonStop(self: *Self, parsed: *const protocol.ParsedResponse) !registry.DaemonStopResult {
            return try decodeResult(self, registry.DaemonStopResult, parsed);
        }

        /// Decode a successful `workspace.resolve` response.
        pub fn decodeWorkspaceResolve(self: *Self, parsed: *const protocol.ParsedResponse) !registry.WorkspaceResolveResult {
            return try decodeResult(self, registry.WorkspaceResolveResult, parsed);
        }

        /// Decode a successful store write response.
        pub fn decodeWriteResult(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.WriteResult {
            return try decodeResult(self, store_protocol.WriteResult, parsed);
        }

        /// Decode a successful daemon store status response.
        pub fn decodeStoreStatus(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.StoreStatusResult {
            return try decodeResult(self, store_protocol.StoreStatusResult, parsed);
        }

        /// Decode one durable thread read with allocations independent of the
        /// response envelope's parse arena.
        pub fn decodeThreadGet(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.ThreadGetResult {
            return try decodeResult(self, store_protocol.ThreadGetResult, parsed);
        }

        /// Decode a bounded workspace list with repository projections.
        pub fn decodeWorkspaceList(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.WorkspaceListResult {
            return try decodeResult(self, store_protocol.WorkspaceListResult, parsed);
        }

        /// Decode one bounded, allocator-owned repository manifest projection.
        pub fn decodeWorkspaceRepositoryManifest(
            self: *Self,
            parsed: *const protocol.ParsedResponse,
        ) !store_protocol.WorkspaceRepositoryManifestResult {
            return try decodeResult(self, store_protocol.WorkspaceRepositoryManifestResult, parsed);
        }

        /// Decode a bounded durable thread metadata list.
        pub fn decodeThreadList(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.ThreadListResult {
            return try decodeResult(self, store_protocol.ThreadListResult, parsed);
        }

        /// Decode a bounded bidirectional transcript page.
        pub fn decodeMessageList(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.MessageListResult {
            return try decodeResult(self, store_protocol.MessageListResult, parsed);
        }

        pub fn decodeSurfaceCompletionObserve(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.SurfaceCompletionObserveResult {
            return try decodeResult(self, store_protocol.SurfaceCompletionObserveResult, parsed);
        }

        pub fn decodeSurfaceCommitProofClassify(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.SurfaceCommitProofClassifyResult {
            return try decodeResult(self, store_protocol.SurfaceCommitProofClassifyResult, parsed);
        }

        /// Decode the dynamic model catalog returned by one provider runtime.
        pub fn decodeProviderModelsList(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.ModelsListResult {
            return try decodeResult(self, providers_protocol.ModelsListResult, parsed);
        }

        /// Decode runtime-scoped installation/authentication status for providers.
        pub fn decodeProviderStatus(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.StatusResult {
            return try decodeResult(self, providers_protocol.StatusResult, parsed);
        }

        pub fn decodeProviderAuthStatus(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.AuthStatusResult {
            return try decodeResult(self, providers_protocol.AuthStatusResult, parsed);
        }

        pub fn decodeProviderThreadsList(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.ThreadsListResult {
            return try decodeResult(self, providers_protocol.ThreadsListResult, parsed);
        }

        pub fn decodeProviderThreadRead(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.ThreadReadResult {
            return try decodeResult(self, providers_protocol.ThreadReadResult, parsed);
        }

        pub fn decodeProviderThreadInterrupt(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.ThreadControlResult {
            return try decodeResult(self, providers_protocol.ThreadControlResult, parsed);
        }

        pub fn decodeProviderThreadSteer(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.ThreadControlResult {
            return try decodeResult(self, providers_protocol.ThreadControlResult, parsed);
        }

        pub fn decodeProviderSlashList(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.SlashListResult {
            return try decodeResult(self, providers_protocol.SlashListResult, parsed);
        }

        pub fn decodeProviderSlashRun(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.SlashRunResult {
            return try decodeResult(self, providers_protocol.SlashRunResult, parsed);
        }

        pub fn decodeProviderCodexBackgroundStatus(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.CodexBackgroundStatusResult {
            return try decodeResult(self, providers_protocol.CodexBackgroundStatusResult, parsed);
        }

        pub fn decodeProviderCodexBackgroundTerminate(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.CodexBackgroundTerminateResult {
            return try decodeResult(self, providers_protocol.CodexBackgroundTerminateResult, parsed);
        }

        pub fn decodeProviderIntegrationsInspect(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.IntegrationsInspectResult {
            return try decodeResult(self, providers_protocol.IntegrationsInspectResult, parsed);
        }

        pub fn decodeProviderHooksSet(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.HooksSetResult {
            return try decodeResult(self, providers_protocol.HooksSetResult, parsed);
        }

        pub fn decodeProviderMcpSet(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.McpSetResult {
            return try decodeResult(self, providers_protocol.McpSetResult, parsed);
        }

        pub fn decodeProviderTitleGenerate(self: *Self, parsed: *const protocol.ParsedResponse) !providers_protocol.TitleGenerateResult {
            return try decodeResult(self, providers_protocol.TitleGenerateResult, parsed);
        }

        /// Decode one durable turn-ledger record.
        pub fn decodeTurnRecord(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.TurnRecord {
            return try decodeResult(self, store_protocol.TurnRecord, parsed);
        }

        /// Decode a successful `core.changes` journal poll.
        pub fn decodeChanges(self: *Self, parsed: *const protocol.ParsedResponse) !changes_protocol.ChangesResult {
            return try decodeResult(self, changes_protocol.ChangesResult, parsed);
        }

        /// Decode a successful scoped composite `core.snapshot` response.
        pub fn decodeCompositeSnapshot(self: *Self, parsed: *const protocol.ParsedResponse) !store_protocol.CoreSnapshotResult {
            return try decodeResult(self, store_protocol.CoreSnapshotResult, parsed);
        }

        /// Decode the owner-only grant creation result with strict access-protocol
        /// fields. Unlike the legacy tolerant decoders, unknown fields fail closed.
        pub fn decodePairingGrantCreate(
            self: *Self,
            parsed: *const protocol.ParsedResponse,
        ) !access_protocol.PairingGrantCreateResult {
            const result = try decodeStrictResult(self, access_protocol.PairingGrantCreateResult, parsed);
            try validateAccessResultHeader(result.access_protocol_version, result.runtime_id, result.instance_id);
            try access_protocol.validateGrantId(result.grant_id);
            try access_protocol.validateSecret(result.pairing_token.reveal());
            try access_protocol.validateScopeNames(result.scopes);
            if (result.expires_at_ms < 0) return error.InvalidAccessResponse;
            return result;
        }

        /// Decode non-secret pairing grant metadata with strict v1 fields.
        pub fn decodePairingGrantList(
            self: *Self,
            parsed: *const protocol.ParsedResponse,
        ) !access_protocol.PairingGrantListResult {
            const result = try decodeStrictResult(self, access_protocol.PairingGrantListResult, parsed);
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
            self: *Self,
            parsed: *const protocol.ParsedResponse,
        ) !access_protocol.PairingGrantRevokeResult {
            const result = try decodeStrictResult(self, access_protocol.PairingGrantRevokeResult, parsed);
            try validateAccessProtocolVersion(result.access_protocol_version);
            try access_protocol.validateGrantId(result.grant_id);
            return result;
        }

        /// Decode non-secret device metadata with strict v1 fields.
        pub fn decodeDeviceList(
            self: *Self,
            parsed: *const protocol.ParsedResponse,
        ) !access_protocol.DeviceListResult {
            const result = try decodeStrictResult(self, access_protocol.DeviceListResult, parsed);
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
            self: *Self,
            parsed: *const protocol.ParsedResponse,
        ) !access_protocol.DeviceRevokeResult {
            const result = try decodeStrictResult(self, access_protocol.DeviceRevokeResult, parsed);
            try validateAccessProtocolVersion(result.access_protocol_version);
            try access_protocol.validateDeviceId(result.device_id);
            return result;
        }

        /// Decode the owner-only Connect projection without accepting future
        /// fields or a response for another runtime generation.
        pub fn decodeConnectStatus(
            self: *Self,
            parsed: *const protocol.ParsedResponse,
        ) !connect_protocol.StatusResult {
            const result = try decodeStrictResult(self, connect_protocol.StatusResult, parsed);
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
            self: *Self,
            parsed: *const protocol.ParsedResponse,
        ) !connect_protocol.BootstrapConsumeResult {
            const result = try decodeStrictResult(self, connect_protocol.BootstrapConsumeResult, parsed);
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

        fn recordNegotiatedRange(self: *Self, daemon_min: u32, daemon_max: u32) !u32 {
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

        fn resultValue(_: *Self, parsed: *const protocol.ParsedResponse) !std.json.Value {
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
        fn decodeResult(self: *Self, comptime T: type, parsed: *const protocol.ParsedResponse) !T {
            const result = try resultValue(self, parsed);
            const result_json = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
            defer self.allocator.free(result_json);
            return try std.json.parseFromSliceLeaky(T, self.allocator, result_json, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
        }

        /// Access credentials and grants use strict, versioned objects. Parsing
        /// directly from the response DOM avoids another plaintext secret copy.
        fn decodeStrictResult(self: *Self, comptime T: type, parsed: *const protocol.ParsedResponse) !T {
            const result = try resultValue(self, parsed);
            return try std.json.parseFromValueLeaky(T, self.allocator, result, .{});
        }
    };
}

fn validateAccessProtocolVersion(version: u32) !void {
    if (version != access_protocol.ACCESS_PROTOCOL_VERSION) {
        return error.IncompatibleAccessProtocol;
    }
}

pub fn validateConnectProtocolVersion(version: u32) !void {
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

test "standalone codec preserves targeting, ids, and response correlation" {
    const allocator = std.testing.allocator;
    var runtime_id = "0123456789abcdef0123456789abcdef".*;
    var codec = try Codec.initTargeted(allocator, .{
        .runtime_id = &runtime_id,
        .instance_id = "fedcba9876543210fedcba9876543210",
    });
    runtime_id[0] = 'f';
    const request = try codec.encodeRequest("workspace.list", .{});
    defer allocator.free(request.json);
    try std.testing.expectEqual(@as(u64, 1), request.id);
    try std.testing.expectEqual(@as(u64, 2), codec.next_id);
    const expected = try protocol.encodeTargetedRequest(allocator, 1, "workspace.list", .{}, .{
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .instance_id = "fedcba9876543210fedcba9876543210",
    });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, request.json);
    try std.testing.expectError(error.ResponseIdMismatch, codec.parseResponseWithId(request.id,
        \\{"jsonrpc":"2.0","id":2,"result":{}}
    ));
    var failure = try codec.parseResponseWithId(request.id,
        \\{"jsonrpc":"2.0","id":null,"error":{"code":"runtime_identity_mismatch","message":"replaced"}}
    );
    defer failure.deinit();
    try std.testing.expectError(error.RuntimeIdentityMismatch, codec.decodeStatus(&failure));
}

test "standalone codec decodes owned results and negotiates without transport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var codec = Codec.init(arena.allocator());
    try std.testing.expectError(error.HandshakeRequired, codec.negotiatedProtocolVersion());
    const body = try protocol.encodeOkResponse(std.testing.allocator, 7, protocol.StatusResult{
        .server_version = "codec-test",
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 1,
        .pid = 0,
        .session_count = 0,
        .chat_turn_count = 0,
        .capabilities = .{},
    });
    defer std.testing.allocator.free(body);
    const status = status: {
        var parsed = try codec.parseResponseWithId(7, body);
        defer parsed.deinit();
        break :status try codec.decodeStatus(&parsed);
    };
    try std.testing.expectEqualStrings("codec-test", status.server_version);
    try std.testing.expectEqual(status.max_supported, try codec.negotiatedProtocolVersion());
}
