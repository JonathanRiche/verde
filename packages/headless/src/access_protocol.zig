//! Direct-runtime pairing, device, access-token, and WebSocket-ticket DTOs.
//!
//! These types are transport-neutral. The HTTP gateway and detached clients
//! share their validated shapes, while durable verifier storage remains owned
//! by the runtime. Secret-bearing values redact during generic serialization;
//! a transport must use an explicit, immediately cleared wire buffer.

const std = @import("std");

pub const ACCESS_PROTOCOL_VERSION: u32 = 1;

pub const HTTP_PAIR_EXCHANGE_PATH: []const u8 = "/auth/pair/exchange";
pub const HTTP_ACCESS_TOKEN_PATH: []const u8 = "/auth/access-token";
pub const HTTP_WEBSOCKET_TICKET_PATH: []const u8 = "/auth/websocket-ticket";
pub const HTTP_RUNTIME_METADATA_PATH: []const u8 = "/.well-known/verde-runtime";
pub const HTTP_AUTHORIZATION_HEADER: []const u8 = "Authorization";
pub const HTTP_WEBSOCKET_PROTOCOL_HEADER: []const u8 = "Sec-WebSocket-Protocol";
pub const DEVICE_AUTHORIZATION_SCHEME: []const u8 = "VerdeDevice";
pub const WEBSOCKET_PROTOCOL_NAME: []const u8 = "verde.v1";
pub const WEBSOCKET_TICKET_PROTOCOL_PREFIX: []const u8 = "verde.ticket.";

pub const DEFAULT_PAIRING_TTL_SECONDS: u32 = 10 * 60;
pub const MAX_PAIRING_TTL_SECONDS: u32 = 60 * 60;
pub const DEFAULT_ACCESS_TOKEN_TTL_SECONDS: u32 = 15 * 60;
pub const DEFAULT_WEBSOCKET_TICKET_TTL_SECONDS: u32 = 30;
pub const PAIR_RUNTIME_CAPABILITY: []const u8 = "access.pair.v1";
pub const ACCESS_TOKEN_TYPE: []const u8 = "Bearer";
pub const MAX_DEVICE_LABEL_BYTES: usize = 128;
pub const MAX_SCOPE_COUNT: usize = 16;
pub const GRANT_ID_BYTES: usize = 16;
pub const GRANT_ID_HEX_BYTES: usize = GRANT_ID_BYTES * 2;
pub const DEVICE_ID_BYTES: usize = 16;
pub const DEVICE_ID_HEX_BYTES: usize = DEVICE_ID_BYTES * 2;
pub const SECRET_BYTES: usize = 32;
pub const SECRET_HEX_BYTES: usize = SECRET_BYTES * 2;
pub const REDACTED_SECRET: []const u8 = "[REDACTED]";
pub const MAX_PAIR_EXCHANGE_BODY_BYTES: usize = 4 * 1024;

// Owner-only daemon RPCs. They are intentionally not remotely callable even
// when the runtime advertises the complete Pair transport capability.
pub const METHOD_DAEMON_PAIRING_GRANT_CREATE: []const u8 = "daemon.access.pairing.create";
pub const METHOD_DAEMON_PAIRING_GRANT_LIST: []const u8 = "daemon.access.pairing.list";
pub const METHOD_DAEMON_PAIRING_GRANT_REVOKE: []const u8 = "daemon.access.pairing.revoke";
pub const METHOD_DAEMON_DEVICE_LIST: []const u8 = "daemon.access.device.list";
pub const METHOD_DAEMON_DEVICE_REVOKE: []const u8 = "daemon.access.device.revoke";
// Gateway-only bridge RPCs. These remain blocked from generic HTTP and
// WebSocket forwarding; the loopback gateway invokes them over the private
// daemon socket after applying its network authentication policy.
pub const METHOD_DAEMON_PAIRING_EXCHANGE: []const u8 = "daemon.access.pairing.exchange";
pub const METHOD_DAEMON_DEVICE_AUTHENTICATE: []const u8 = "daemon.access.device.authenticate";
pub const METHOD_DAEMON_DEVICE_AUTHORIZE: []const u8 = "daemon.access.device.authorize";

/// Secret-bearing protocol value whose default JSON representation is always
/// redacted. A transport must deliberately call `reveal` and write the one
/// secret-bearing response/request field; generic structured logging cannot
/// serialize the credential by accident.
pub const Secret = struct {
    bytes: []const u8,

    pub fn reveal(self: Secret) []const u8 {
        return self.bytes;
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Secret {
        const token = try source.nextAlloc(allocator, options.allocate orelse .alloc_always);
        return switch (token) {
            .string => |value| .{ .bytes = value },
            .allocated_string => |value| .{ .bytes = value },
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !Secret {
        if (source != .string) return error.UnexpectedToken;
        return .{ .bytes = source.string };
    }

    pub fn jsonStringify(_: Secret, writer: anytype) !void {
        try writer.write(REDACTED_SECRET);
    }

    pub fn format(_: Secret, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(REDACTED_SECRET);
    }
};

/// Stable authorization scopes enforced independently for every daemon RPC.
pub const Scope = enum {
    runtime_read,
    chat_read,
    chat_write,
    terminal_read,
    terminal_write,
    repository_read,
    repository_write,
    device_read,

    pub fn wireName(self: Scope) []const u8 {
        return switch (self) {
            .runtime_read => "runtime:read",
            .chat_read => "chat:read",
            .chat_write => "chat:write",
            .terminal_read => "terminal:read",
            .terminal_write => "terminal:write",
            .repository_read => "repository:read",
            .repository_write => "repository:write",
            .device_read => "device:read",
        };
    }
};

pub const DEFAULT_SCOPE_NAMES = [_][]const u8{
    Scope.runtime_read.wireName(),
    Scope.chat_read.wireName(),
    Scope.chat_write.wireName(),
    Scope.terminal_read.wireName(),
    Scope.terminal_write.wireName(),
    Scope.repository_read.wireName(),
    Scope.repository_write.wireName(),
    Scope.device_read.wireName(),
};

/// Parse one stable scope spelling without accepting case or separator aliases.
pub fn parseScope(value: []const u8) !Scope {
    inline for (std.meta.tags(Scope)) |scope| {
        if (std.mem.eql(u8, value, scope.wireName())) return scope;
    }
    return error.UnknownAccessScope;
}

/// Reject an empty, oversized, unknown, or duplicate scope request.
pub fn validateScopeNames(values: []const []const u8) !void {
    if (values.len == 0) return error.AccessScopesRequired;
    if (values.len > MAX_SCOPE_COUNT) return error.TooManyAccessScopes;
    for (values, 0..) |value, index| {
        _ = try parseScope(value);
        for (values[0..index]) |earlier| {
            if (std.mem.eql(u8, value, earlier)) return error.DuplicateAccessScope;
        }
    }
}

/// Convert a validated scope list into its durable, protocol-versioned mask.
pub fn scopeMask(values: []const []const u8) !u16 {
    try validateScopeNames(values);
    var mask: u16 = 0;
    for (values) |value| {
        const scope = try parseScope(value);
        mask |= @as(u16, 1) << @intFromEnum(scope);
    }
    return mask;
}

/// Expand a durable scope mask into frozen wire names. The returned outer
/// slice is allocator-owned; its strings are static protocol constants.
pub fn scopeNamesAlloc(allocator: std.mem.Allocator, mask: u16) ![][]const u8 {
    try validateScopeMask(mask);
    const names = try allocator.alloc([]const u8, @popCount(mask));
    var index: usize = 0;
    inline for (std.meta.tags(Scope)) |scope| {
        const bit = @as(u16, 1) << @intFromEnum(scope);
        if (mask & bit != 0) {
            names[index] = scope.wireName();
            index += 1;
        }
    }
    return names;
}

/// Reject empty or future-version scope bits in durable version-1 records.
pub fn validateScopeMask(mask: u16) !void {
    const known_mask: u16 = (@as(u16, 1) << @intCast(std.meta.tags(Scope).len)) - 1;
    if (mask == 0) return error.AccessScopesRequired;
    if (mask & ~known_mask != 0) return error.UnknownAccessScope;
}

/// Return whether every requested scope is contained in the authorized set.
pub fn scopeMaskContains(authorized: u16, requested: u16) bool {
    return requested != 0 and authorized & requested == requested;
}

pub fn scopeBit(scope: Scope) u16 {
    return @as(u16, 1) << @intFromEnum(scope);
}

const SNAPSHOT_READ_MASK: u16 = scopeBit(.runtime_read) |
    scopeBit(.chat_read) |
    scopeBit(.terminal_read) |
    scopeBit(.repository_read);

pub fn webSocketBootstrapScopeMask() u16 {
    return SNAPSHOT_READ_MASK;
}

/// Return the exact scope mask required to forward one runtime RPC through a
/// paired session. Unknown and owner-only methods return null and therefore
/// fail closed. This is the single policy used by HTTP and WebSocket paths.
pub fn requiredScopeMaskForRpc(method: []const u8) ?u16 {
    if (std.mem.eql(u8, method, "core.snapshot") or
        std.mem.eql(u8, method, "core.changes")) return SNAPSHOT_READ_MASK;

    if (std.mem.eql(u8, method, "core.status") or
        std.mem.eql(u8, method, "core.capabilities") or
        std.mem.eql(u8, method, "status") or
        std.mem.eql(u8, method, "provider.models.list") or
        std.mem.eql(u8, method, "providers.status") or
        std.mem.eql(u8, method, "daemon.storeStatus")) return scopeBit(.runtime_read);

    if (std.mem.eql(u8, method, "chat.thread.get") or
        std.mem.eql(u8, method, "chat.thread.list") or
        std.mem.eql(u8, method, "chat.message.list") or
        std.mem.eql(u8, method, "chat.turn.list") or
        std.mem.eql(u8, method, "chat.turn.tail")) return scopeBit(.chat_read);

    if (std.mem.eql(u8, method, "chat.turn.start") or
        std.mem.eql(u8, method, "chat.turn.approve") or
        std.mem.eql(u8, method, "chat.turn.steer") or
        std.mem.eql(u8, method, "chat.followup") or
        std.mem.eql(u8, method, "chat.turn.cancel") or
        std.mem.eql(u8, method, "chat.turn.consume") or
        std.mem.eql(u8, method, "chat.turn.record") or
        std.mem.eql(u8, method, "chat.thread.upsert") or
        std.mem.eql(u8, method, "chat.draft.set") or
        std.mem.eql(u8, method, "chat.message.append") or
        std.mem.eql(u8, method, "surface.upsert") or
        std.mem.eql(u8, method, "surface.clear") or
        std.mem.eql(u8, method, "notification.chatCompletion.upsert") or
        std.mem.eql(u8, method, "notification.chatCompletion.clear")) return scopeBit(.chat_write);

    if (std.mem.eql(u8, method, "session.list") or
        std.mem.eql(u8, method, "session.inspect") or
        std.mem.eql(u8, method, "session.tail") or
        std.mem.eql(u8, method, "session.tail.batch") or
        std.mem.eql(u8, method, "session.screen")) return scopeBit(.terminal_read);

    if (std.mem.eql(u8, method, "session.create") or
        std.mem.eql(u8, method, "session.attach") or
        std.mem.eql(u8, method, "session.detach") or
        std.mem.eql(u8, method, "session.write") or
        std.mem.eql(u8, method, "session.resize") or
        std.mem.eql(u8, method, "session.kill") or
        std.mem.eql(u8, method, "session.cleanup")) return scopeBit(.terminal_write);

    if (std.mem.eql(u8, method, "workspace.resolve") or
        std.mem.eql(u8, method, "workspace.list") or
        std.mem.eql(u8, method, "workspace.repository.manifest.get")) return scopeBit(.repository_read);

    if (std.mem.eql(u8, method, "workspace.upsert") or
        std.mem.eql(u8, method, "workspace.repository.upsert") or
        std.mem.eql(u8, method, "workspace.repository.remove") or
        std.mem.eql(u8, method, "workspace.repository.default.set") or
        std.mem.eql(u8, method, "workspace.repository.binding.upsert") or
        std.mem.eql(u8, method, "workspace.repository.binding.remove")) return scopeBit(.repository_write);

    return null;
}

/// Validate a user-visible device label before it enters durable runtime data.
pub fn validateDeviceLabel(value: []const u8) !void {
    if (value.len == 0) return error.DeviceLabelRequired;
    if (value.len > MAX_DEVICE_LABEL_BYTES) return error.DeviceLabelTooLong;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidDeviceLabel;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidDeviceLabel;
    }
}

/// Validate a canonical opaque identifier without accepting aliases.
pub fn validateGrantId(value: []const u8) !void {
    if (!isCanonicalLowerHex(value, GRANT_ID_HEX_BYTES)) return error.InvalidGrantId;
}

/// Validate a canonical opaque identifier without accepting aliases.
pub fn validateDeviceId(value: []const u8) !void {
    if (!isCanonicalLowerHex(value, DEVICE_ID_HEX_BYTES)) return error.InvalidDeviceId;
}

/// Validate the encoded entropy returned once for a grant or device.
pub fn validateSecret(value: []const u8) !void {
    if (!isCanonicalLowerHex(value, SECRET_HEX_BYTES)) return error.InvalidAccessSecret;
}

/// Pairing grants are deliberately short lived even when requested locally.
pub fn validatePairingTtl(ttl_seconds: u32) !void {
    if (ttl_seconds == 0 or ttl_seconds > MAX_PAIRING_TTL_SECONDS) {
        return error.InvalidPairingTtl;
    }
}

fn isCanonicalLowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

/// Local administrator request. `ttl_seconds` is bounded again by the owner.
pub const PairingGrantCreateRequest = struct {
    access_protocol_version: u32,
    label: ?[]const u8 = null,
    ttl_seconds: u32 = DEFAULT_PAIRING_TTL_SECONDS,
    scopes: []const []const u8,
};

pub const PairingGrantListRequest = struct {
    access_protocol_version: u32,
};

/// Secret-bearing local result for a future explicit administrator surface.
/// Generic serialization redacts the token; wire output must be deliberate.
pub const PairingGrantCreateResult = struct {
    access_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    grant_id: []const u8,
    pairing_token: Secret,
    expires_at_ms: i64,
    scopes: []const []const u8,
};

/// Durable non-secret administrator view of a one-time pairing grant.
pub const PairingGrantRecord = struct {
    grant_id: []const u8,
    label: ?[]const u8 = null,
    scopes: []const []const u8,
    created_at_ms: i64,
    expires_at_ms: i64,
    consumed_at_ms: ?i64 = null,
    revoked_at_ms: ?i64 = null,
};

pub const PairingGrantListResult = struct {
    access_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    grants: []const PairingGrantRecord,
};

pub const PairingGrantRevokeRequest = struct {
    access_protocol_version: u32,
    grant_id: []const u8,
};

pub const PairingGrantRevokeResult = struct {
    access_protocol_version: u32,
    revoked: bool,
    grant_id: []const u8,
};

/// Remote one-time exchange. Authentication inputs are deliberately strict;
/// future fields require a negotiated protocol version instead of silent
/// acceptance by version-1 decoders.
pub const PairingGrantExchangeRequest = struct {
    access_protocol_version: u32,
    grant_id: []const u8,
    pairing_token: Secret,
    device_label: []const u8,
};

/// Strict authentication-input parser. Unknown/duplicate fields, missing
/// versions, noncanonical secrets, and oversized bodies fail closed.
pub fn parsePairingGrantExchangeRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
) !std.json.Parsed(PairingGrantExchangeRequest) {
    if (body.len > MAX_PAIR_EXCHANGE_BODY_BYTES) return error.PairExchangeBodyTooLarge;
    var parsed = try std.json.parseFromSlice(PairingGrantExchangeRequest, allocator, body, .{});
    errdefer parsed.deinit();
    if (parsed.value.access_protocol_version != ACCESS_PROTOCOL_VERSION) {
        return error.IncompatibleAccessProtocol;
    }
    try validateGrantId(parsed.value.grant_id);
    try validateSecret(parsed.value.pairing_token.reveal());
    try validateDeviceLabel(parsed.value.device_label);
    return parsed;
}

/// Long-lived device material is returned once and stored by clients only in
/// their OS credential store. The runtime retains a verifier, not this value.
pub const PairingGrantExchangeResult = struct {
    access_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    device_id: []const u8,
    device_credential: Secret,
    scopes: []const []const u8,
};

/// Non-secret identity and endpoint advertisement exposed by an explicitly
/// configured HTTPS reverse-proxy profile.
pub const RuntimeEndpointMetadata = struct {
    access_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    https_url: []const u8,
    wss_url: []const u8,
    capabilities: []const []const u8,
};

pub const DeviceRecord = struct {
    device_id: []const u8,
    grant_id: ?[]const u8 = null,
    source: DeviceSource = .pair,
    source_id: ?[]const u8 = null,
    label: []const u8,
    scopes: []const []const u8,
    created_at_ms: i64,
    last_used_at_ms: ?i64 = null,
    revoked_at_ms: ?i64 = null,
};

pub const DeviceSource = enum { pair, connect };

pub const DeviceListResult = struct {
    access_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    devices: []const DeviceRecord,
};

pub const DeviceListRequest = struct {
    access_protocol_version: u32,
};

pub const DeviceRevokeRequest = struct {
    access_protocol_version: u32,
    device_id: []const u8,
};

pub const DeviceRevokeResult = struct {
    access_protocol_version: u32,
    revoked: bool,
    device_id: []const u8,
};

/// The device ID and credential are carried only by the Authorization header;
/// request bodies and ordinary structured request logs never contain them.
pub const AccessTokenRequest = struct {
    access_protocol_version: u32,
    requested_scopes: []const []const u8,
};

pub fn parseAccessTokenRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
) !std.json.Parsed(AccessTokenRequest) {
    if (body.len > MAX_PAIR_EXCHANGE_BODY_BYTES) return error.AccessRequestBodyTooLarge;
    var parsed = try std.json.parseFromSlice(AccessTokenRequest, allocator, body, .{});
    errdefer parsed.deinit();
    if (parsed.value.access_protocol_version != ACCESS_PROTOCOL_VERSION) {
        return error.IncompatibleAccessProtocol;
    }
    try validateScopeNames(parsed.value.requested_scopes);
    return parsed;
}

pub const AccessTokenResult = struct {
    access_protocol_version: u32,
    access_token: Secret,
    token_type: []const u8,
    expires_at_ms: i64,
    scopes: []const []const u8,
};

pub const WebSocketTicketRequest = struct {
    access_protocol_version: u32,
};

pub fn parseWebSocketTicketRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
) !std.json.Parsed(WebSocketTicketRequest) {
    if (body.len > MAX_PAIR_EXCHANGE_BODY_BYTES) return error.AccessRequestBodyTooLarge;
    var parsed = try std.json.parseFromSlice(WebSocketTicketRequest, allocator, body, .{});
    errdefer parsed.deinit();
    if (parsed.value.access_protocol_version != ACCESS_PROTOCOL_VERSION) {
        return error.IncompatibleAccessProtocol;
    }
    return parsed;
}

pub const WebSocketTicketResult = struct {
    access_protocol_version: u32,
    ticket: Secret,
    expires_at_ms: i64,
};

/// Secret-bearing requests accepted only over the private daemon transport.
pub const DeviceAuthenticateRequest = struct {
    access_protocol_version: u32,
    device_id: []const u8,
    device_credential: Secret,
    requested_scopes: []const []const u8,
};

pub const DeviceAuthorizeRequest = struct {
    access_protocol_version: u32,
    device_id: []const u8,
    required_scopes: []const []const u8,
};

pub const DeviceAuthorizationResult = struct {
    access_protocol_version: u32,
    device_id: []const u8,
    scopes: []const []const u8,
};

test "access scopes use frozen names and reject aliases or duplicates" {
    try std.testing.expectEqual(Scope.terminal_write, try parseScope("terminal:write"));
    try std.testing.expectError(error.UnknownAccessScope, parseScope("TERMINAL:WRITE"));
    try std.testing.expectError(error.UnknownAccessScope, parseScope("terminal_write"));
    try validateScopeNames(&DEFAULT_SCOPE_NAMES);
    try std.testing.expectError(error.AccessScopesRequired, validateScopeNames(&.{}));
    try std.testing.expectError(
        error.DuplicateAccessScope,
        validateScopeNames(&.{ "runtime:read", "runtime:read" }),
    );
    const mask = try scopeMask(&.{ "runtime:read", "terminal:write" });
    try std.testing.expect(scopeMaskContains(mask, try scopeMask(&.{"runtime:read"})));
    try std.testing.expect(!scopeMaskContains(mask, try scopeMask(&.{"chat:write"})));
    const names = try scopeNamesAlloc(std.testing.allocator, mask);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("runtime:read", names[0]);
    try std.testing.expectEqualStrings("terminal:write", names[1]);
}

test "device labels are bounded UTF-8 without controls" {
    try validateDeviceLabel("Ryan's laptop");
    try validateDeviceLabel("Téléphone");
    try std.testing.expectError(error.DeviceLabelRequired, validateDeviceLabel(""));
    try std.testing.expectError(error.InvalidDeviceLabel, validateDeviceLabel("bad\nlabel"));
    try std.testing.expectError(error.InvalidDeviceLabel, validateDeviceLabel("bad\xff"));
    try std.testing.expectError(
        error.DeviceLabelTooLong,
        validateDeviceLabel("x" ** (MAX_DEVICE_LABEL_BYTES + 1)),
    );
}

test "opaque access identifiers and pairing TTLs are canonical" {
    try validateGrantId("0123456789abcdef0123456789abcdef");
    try validateDeviceId("fedcba9876543210fedcba9876543210");
    try validateSecret("a" ** SECRET_HEX_BYTES);
    try std.testing.expectError(
        error.InvalidGrantId,
        validateGrantId("0123456789ABCDEF0123456789ABCDEF"),
    );
    try std.testing.expectError(error.InvalidAccessSecret, validateSecret("short"));
    try validatePairingTtl(DEFAULT_PAIRING_TTL_SECONDS);
    try std.testing.expectError(error.InvalidPairingTtl, validatePairingTtl(0));
    try std.testing.expectError(
        error.InvalidPairingTtl,
        validatePairingTtl(MAX_PAIRING_TTL_SECONDS + 1),
    );
}

test "pair exchange and WebSocket ticket DTOs have stable object shapes" {
    const request: PairingGrantExchangeRequest = .{
        .access_protocol_version = ACCESS_PROTOCOL_VERSION,
        .grant_id = "grant-1",
        .pairing_token = .{ .bytes = "pair-secret" },
        .device_label = "Laptop",
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "pair-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, REDACTED_SECRET) != null);

    const wire =
        \\{"access_protocol_version":1,"grant_id":"0123456789abcdef0123456789abcdef","pairing_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","device_label":"Laptop"}
    ;
    var parsed = try parsePairingGrantExchangeRequest(std.testing.allocator, wire);
    defer parsed.deinit();
    try std.testing.expectEqual(ACCESS_PROTOCOL_VERSION, parsed.value.access_protocol_version);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", parsed.value.grant_id);
    try std.testing.expectEqualStrings("a" ** SECRET_HEX_BYTES, parsed.value.pairing_token.reveal());
    try std.testing.expectEqualStrings("Laptop", parsed.value.device_label);
    try std.testing.expectError(
        error.UnknownField,
        parsePairingGrantExchangeRequest(std.testing.allocator,
            \\{"access_protocol_version":1,"grant_id":"0123456789abcdef0123456789abcdef","pairing_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","device_label":"Laptop","future":true}
        ),
    );
    try std.testing.expectError(
        error.MissingField,
        parsePairingGrantExchangeRequest(std.testing.allocator,
            \\{"grant_id":"0123456789abcdef0123456789abcdef","pairing_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","device_label":"Laptop"}
        ),
    );
    try std.testing.expectError(
        error.DuplicateField,
        parsePairingGrantExchangeRequest(std.testing.allocator,
            \\{"access_protocol_version":1,"access_protocol_version":1,"grant_id":"0123456789abcdef0123456789abcdef","pairing_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","device_label":"Laptop"}
        ),
    );

    const ticket_request = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        WebSocketTicketRequest{ .access_protocol_version = ACCESS_PROTOCOL_VERSION },
        .{},
    );
    defer std.testing.allocator.free(ticket_request);
    try std.testing.expectEqualStrings("{\"access_protocol_version\":1}", ticket_request);
}

test "access token and ticket requests are strict and versioned" {
    var token = try parseAccessTokenRequest(
        std.testing.allocator,
        "{\"access_protocol_version\":1,\"requested_scopes\":[\"runtime:read\",\"chat:write\"]}",
    );
    defer token.deinit();
    try std.testing.expectEqual(@as(usize, 2), token.value.requested_scopes.len);
    try std.testing.expectError(
        error.DuplicateField,
        parseAccessTokenRequest(
            std.testing.allocator,
            "{\"access_protocol_version\":1,\"access_protocol_version\":1,\"requested_scopes\":[\"runtime:read\"]}",
        ),
    );
    try std.testing.expectError(
        error.UnknownField,
        parseWebSocketTicketRequest(
            std.testing.allocator,
            "{\"access_protocol_version\":1,\"future\":true}",
        ),
    );
    try std.testing.expectError(
        error.IncompatibleAccessProtocol,
        parseWebSocketTicketRequest(
            std.testing.allocator,
            "{\"access_protocol_version\":2}",
        ),
    );
}

test "runtime endpoint metadata has the frozen direct-runtime shape" {
    const metadata: RuntimeEndpointMetadata = .{
        .access_protocol_version = ACCESS_PROTOCOL_VERSION,
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .instance_id = "00112233445566778899aabbccddeeff",
        .https_url = "https://runtime.example.test",
        .wss_url = "wss://runtime.example.test/ws",
        .capabilities = &.{PAIR_RUNTIME_CAPABILITY},
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, metadata, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"access_protocol_version\":1,\"runtime_id\":\"0123456789abcdef0123456789abcdef\",\"instance_id\":\"00112233445566778899aabbccddeeff\",\"https_url\":\"https://runtime.example.test\",\"wss_url\":\"wss://runtime.example.test/ws\",\"capabilities\":[\"access.pair.v1\"]}",
        encoded,
    );
}

test "paired RPC scope policy is exact and fails closed" {
    try std.testing.expectEqual(
        scopeBit(.chat_write),
        requiredScopeMaskForRpc("chat.turn.start").?,
    );
    try std.testing.expectEqual(
        scopeBit(.terminal_read),
        requiredScopeMaskForRpc("session.tail").?,
    );
    try std.testing.expectEqual(
        webSocketBootstrapScopeMask(),
        requiredScopeMaskForRpc("core.snapshot").?,
    );
    try std.testing.expect(requiredScopeMaskForRpc("daemon.stop") == null);
    try std.testing.expect(requiredScopeMaskForRpc("process.start") == null);
    try std.testing.expect(requiredScopeMaskForRpc("future.method") == null);
    try std.testing.expect(requiredScopeMaskForRpc(METHOD_DAEMON_DEVICE_AUTHORIZE) == null);
}
