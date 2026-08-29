//! Owner-only Verde Connect lifecycle and bootstrap DTOs.
//!
//! Secret-bearing values redact during generic serialization. The private
//! daemon transport must use a deliberate encoder and clear its wire buffer.

const std = @import("std");
const access_protocol = @import("access_protocol.zig");

pub const CONNECT_PROTOCOL_VERSION: u32 = 1;
pub const CONTRACT_VERSION: []const u8 = "1";
pub const REDACTED_SECRET: []const u8 = "[REDACTED]";
pub const MAX_CONTROL_PLANE_URL_BYTES: usize = 2048;
pub const MAX_CREDENTIAL_FILE_BYTES: usize = 4096;
pub const MAX_COMPACT_TOKEN_BYTES: usize = 16 * 1024;
pub const MAX_BOOTSTRAP_BODY_BYTES: usize = 24 * 1024;
pub const HTTP_BOOTSTRAP_PATH: []const u8 = "/auth/connect/bootstrap";

pub const METHOD_LOGIN: []const u8 = "daemon.connect.login";
pub const METHOD_LINK: []const u8 = "daemon.connect.link";
pub const METHOD_STATUS: []const u8 = "daemon.connect.status";
pub const METHOD_UNLINK: []const u8 = "daemon.connect.unlink";
pub const METHOD_LOGOUT: []const u8 = "daemon.connect.logout";
pub const METHOD_BOOTSTRAP_CONSUME: []const u8 = "daemon.connect.bootstrap.consume";

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

pub const DesiredState = enum { unlinked, linked };
pub const LifecycleState = enum {
    logged_out,
    logged_in,
    linking,
    linked,
    retry_wait,
    unlinking,
    error_blocked,
};

pub const LoginRequest = struct {
    connect_protocol_version: u32,
    control_plane_url: []const u8,
    /// Owner-only no-follow file read by the daemon. The credential itself is
    /// never transported in request JSON or process arguments.
    credential_file: []const u8,
};

pub const LinkRequest = struct {
    connect_protocol_version: u32,
    provider: []const u8 = "external",
    external_descriptor: ?RuntimeDescriptor = null,
};

pub const RuntimeDescriptor = struct {
    contract_version: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    https_url: []const u8,
    wss_url: []const u8,
    tls_identity: struct { kind: []const u8, sha256: []const u8 },
    protocol: struct { major: u16, minor: u16 },
    capabilities: []const []const u8,
};

pub const StatusRequest = struct { connect_protocol_version: u32 };
pub const UnlinkRequest = struct { connect_protocol_version: u32 };
pub const LogoutRequest = struct { connect_protocol_version: u32 };

pub const StatusResult = struct {
    connect_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    desired_state: DesiredState,
    state: LifecycleState,
    control_plane_url: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    link_id: ?[]const u8 = null,
    enrollment_id: ?[]const u8 = null,
    endpoint_https_url: ?[]const u8 = null,
    endpoint_wss_url: ?[]const u8 = null,
    connector_provider: ?[]const u8 = null,
    retry_attempt: u16 = 0,
    next_retry_at_ms: ?i64 = null,
    last_error_code: ?[]const u8 = null,
    authenticated: bool,
    connector_running: bool,
};

pub const BootstrapConsumeRequest = struct {
    connect_protocol_version: u32,
    grant_jwt: Secret,
    expected_issuer: []const u8,
    expected_audience: []const u8,
    client_nonce: []const u8,
    device_id: []const u8,
    device_key_thumbprint: []const u8,
    device_label: []const u8,
};

pub const BootstrapConsumeResult = struct {
    connect_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    device_id: []const u8,
    device_credential: Secret,
    scopes: []const []const u8,
};

/// Public HTTPS request. The Connect identity is deliberately named
/// separately from the runtime-local device ID returned on success.
pub const HttpBootstrapRequest = struct {
    connect_protocol_version: u32,
    grant_jwt: Secret,
    expected_issuer: []const u8,
    expected_audience: []const u8,
    client_nonce: []const u8,
    connect_device_id: []const u8,
    device_key_thumbprint: []const u8,
    device_label: []const u8,
};

pub const HttpBootstrapResult = BootstrapConsumeResult;

pub fn parseHttpBootstrapRequest(
    allocator: std.mem.Allocator,
    body: []const u8,
) !std.json.Parsed(HttpBootstrapRequest) {
    if (body.len > MAX_BOOTSTRAP_BODY_BYTES) return error.ConnectBootstrapBodyTooLarge;
    var parsed = try std.json.parseFromSlice(HttpBootstrapRequest, allocator, body, .{});
    errdefer parsed.deinit();
    if (parsed.value.connect_protocol_version != CONNECT_PROTOCOL_VERSION) {
        return error.IncompatibleConnectProtocol;
    }
    if (parsed.value.grant_jwt.reveal().len == 0 or
        parsed.value.grant_jwt.reveal().len > MAX_COMPACT_TOKEN_BYTES)
    {
        return error.InvalidBootstrapGrant;
    }
    try validateControlPlaneUrl(parsed.value.expected_issuer);
    if (!validEndpointUrl(parsed.value.expected_audience, "https") or
        !validPrefixedHex32(parsed.value.connect_device_id, "dev_") or
        !validBase64Url43(parsed.value.client_nonce) or
        !validBase64Url43(parsed.value.device_key_thumbprint))
    {
        return error.InvalidBootstrapGrant;
    }
    try access_protocol.validateDeviceLabel(parsed.value.device_label);
    return parsed;
}

pub fn isMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, METHOD_LOGIN) or
        std.mem.eql(u8, method, METHOD_LINK) or
        std.mem.eql(u8, method, METHOD_STATUS) or
        std.mem.eql(u8, method, METHOD_UNLINK) or
        std.mem.eql(u8, method, METHOD_LOGOUT) or
        std.mem.eql(u8, method, METHOD_BOOTSTRAP_CONSUME);
}

pub fn isMutatingMethod(method: []const u8) bool {
    return isMethod(method) and !std.mem.eql(u8, method, METHOD_STATUS);
}

pub fn validateControlPlaneUrl(value: []const u8) !void {
    if (value.len == 0 or value.len > MAX_CONTROL_PLANE_URL_BYTES) return error.InvalidControlPlaneUrl;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidControlPlaneUrl;
    const uri = std.Uri.parse(value) catch return error.InvalidControlPlaneUrl;
    if (!std.mem.eql(u8, uri.scheme, "https")) return error.InsecureControlPlaneUrl;
    if (uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or std.mem.endsWith(u8, value, "/"))
    {
        return error.InvalidControlPlaneUrl;
    }
}

pub fn validateCredentialFile(value: []const u8) !void {
    if (value.len == 0 or value.len > MAX_CREDENTIAL_FILE_BYTES) return error.InvalidCredentialFile;
    if (!std.fs.path.isAbsolute(value)) return error.InvalidCredentialFile;
    for (value) |byte| if (byte == 0 or byte < 0x20 or byte == 0x7f) return error.InvalidCredentialFile;
}

pub fn validateRuntimeDescriptor(value: RuntimeDescriptor, runtime_id: []const u8, instance_id: []const u8) !void {
    if (!std.mem.eql(u8, value.contract_version, CONTRACT_VERSION) or
        !std.mem.eql(u8, value.runtime_id, runtime_id) or
        !std.mem.eql(u8, value.instance_id, instance_id) or
        !validEndpointUrl(value.https_url, "https") or
        !validEndpointUrl(value.wss_url, "wss") or
        !std.mem.eql(u8, value.tls_identity.kind, "spki_sha256") or
        !validBase64Url43(value.tls_identity.sha256) or value.protocol.major != 1 or
        value.capabilities.len > 128)
    {
        return error.InvalidRuntimeDescriptor;
    }
    for (value.capabilities, 0..) |capability, index| {
        if (capability.len < 2 or capability.len > 64 or capability[0] < 'a' or capability[0] > 'z') {
            return error.InvalidRuntimeDescriptor;
        }
        for (capability[1..]) |byte| switch (byte) {
            'a'...'z', '0'...'9', '_', '.', ':', '-' => {},
            else => return error.InvalidRuntimeDescriptor,
        };
        for (value.capabilities[0..index]) |prior| {
            if (std.mem.eql(u8, prior, capability)) return error.InvalidRuntimeDescriptor;
        }
    }
}

fn validEndpointUrl(value: []const u8, expected_scheme: []const u8) bool {
    if (value.len == 0 or value.len > MAX_CONTROL_PLANE_URL_BYTES) return false;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    const uri = std.Uri.parse(value) catch return false;
    return std.mem.eql(u8, uri.scheme, expected_scheme) and
        uri.host != null and !uri.host.?.isEmpty() and
        uri.user == null and uri.password == null and uri.fragment == null;
}

fn validBase64Url43(value: []const u8) bool {
    if (value.len != 43) return false;
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn validPrefixedHex32(value: []const u8, prefix: []const u8) bool {
    if (value.len != prefix.len + 32 or !std.mem.startsWith(u8, value, prefix)) return false;
    for (value[prefix.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

test "connect methods keep login/link and unlink/logout distinct" {
    try std.testing.expect(isMutatingMethod(METHOD_LOGIN));
    try std.testing.expect(isMutatingMethod(METHOD_LINK));
    try std.testing.expect(isMutatingMethod(METHOD_UNLINK));
    try std.testing.expect(isMutatingMethod(METHOD_LOGOUT));
    try std.testing.expect(!isMutatingMethod(METHOD_STATUS));
}

test "control-plane URL and credential handoff are fail closed" {
    try validateControlPlaneUrl("https://connect.example.test");
    try std.testing.expectError(error.InsecureControlPlaneUrl, validateControlPlaneUrl("http://connect.example.test"));
    try std.testing.expectError(error.InvalidControlPlaneUrl, validateControlPlaneUrl("https://user@connect.example.test"));
    try std.testing.expectError(error.InvalidControlPlaneUrl, validateControlPlaneUrl("https:///missing-host"));
    try std.testing.expectError(error.InvalidControlPlaneUrl, validateControlPlaneUrl("https://connect.example.test/"));
    try validateCredentialFile("/run/user/1000/verde-connect-token");
    try std.testing.expectError(error.InvalidCredentialFile, validateCredentialFile("relative-token"));
}

test "connect secrets redact by default" {
    const secret: Secret = .{ .bytes = "do-not-print" };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, secret, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("\"[REDACTED]\"", encoded);
}

test "runtime descriptors enforce public v1 identity and endpoint constraints" {
    const descriptor: RuntimeDescriptor = .{
        .contract_version = "1",
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .instance_id = "abcdef0123456789abcdef0123456789",
        .https_url = "https://runtime.example.test",
        .wss_url = "wss://runtime.example.test/v1/ws",
        .tls_identity = .{ .kind = "spki_sha256", .sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
        .protocol = .{ .major = 1, .minor = 0 },
        .capabilities = &.{ "chat.read", "terminal.write" },
    };
    try validateRuntimeDescriptor(descriptor, descriptor.runtime_id, descriptor.instance_id);
    var invalid = descriptor;
    invalid.wss_url = "wss:///missing-host";
    try std.testing.expectError(
        error.InvalidRuntimeDescriptor,
        validateRuntimeDescriptor(invalid, descriptor.runtime_id, descriptor.instance_id),
    );
}

test "public Connect bootstrap DTO is strict redacting and identity-explicit" {
    const wire =
        "{\"connect_protocol_version\":1,\"grant_jwt\":\"header.payload.signature\"," ++
        "\"expected_issuer\":\"https://connect.example.test\"," ++
        "\"expected_audience\":\"https://runtime.example.test\"," ++
        "\"client_nonce\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"," ++
        "\"connect_device_id\":\"dev_33333333333333333333333333333333\"," ++
        "\"device_key_thumbprint\":\"kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k\"," ++
        "\"device_label\":\"Connect laptop\"}";
    var parsed = try parseHttpBootstrapRequest(std.testing.allocator, wire);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("dev_33333333333333333333333333333333", parsed.value.connect_device_id);
    const generic = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(generic);
    try std.testing.expect(std.mem.indexOf(u8, generic, "header.payload.signature") == null);
    try std.testing.expect(std.mem.indexOf(u8, generic, REDACTED_SECRET) != null);
    try std.testing.expectError(error.UnknownField, parseHttpBootstrapRequest(
        std.testing.allocator,
        wire[0 .. wire.len - 1] ++ ",\"future\":true}",
    ));
}
