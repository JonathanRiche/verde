//! Network half of the runtime-side Verde Connect link lifecycle.
//!
//! Callers persist desired state before entering this module and persist the
//! returned result afterwards. No SQLite lock is held across bounded HTTP or
//! connector side effects.

const std = @import("std");
const headless = @import("headless");

const connect = headless.connect_protocol;
const client_mod = @import("connect_client.zig");
const crypto = @import("connect_crypto.zig");
const reconciler_mod = @import("connect_reconciler.zig");

/// Persist only an identity-verified service receipt. Clearing is called only
/// after a verified authenticated rollback response; failed cleanup retains it.
pub const LinkRecovery = struct {
    context: *anyopaque,
    save_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    clear_fn: *const fn (*anyopaque, []const u8) anyerror!void,
};

pub const LinkInput = struct {
    control_plane_url: []const u8,
    bearer_token: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    request_id: []const u8,
    provider: []const u8,
    external_descriptor: ?connect.RuntimeDescriptor,
    /// Sample when signing, after the bounded discovery/challenge exchanges.
    now_seconds_fn: *const fn () i64,
    recovery: ?LinkRecovery = null,
};

pub const LinkResult = struct {
    link_id: []u8,
    enrollment_id: []u8,
    endpoint_https_url: []u8,
    endpoint_wss_url: []u8,
    connector_provider: []u8,
    connector_running: bool,

    pub fn deinit(self: *LinkResult, allocator: std.mem.Allocator) void {
        allocator.free(self.link_id);
        allocator.free(self.enrollment_id);
        allocator.free(self.endpoint_https_url);
        allocator.free(self.endpoint_wss_url);
        allocator.free(self.connector_provider);
        self.* = undefined;
    }
};

pub const LoginResult = struct {
    issuer: []u8,
    signer_jwks_json: []u8,
    maximum_grant_lifetime_seconds: u16,
    headless_login_supported: bool,

    pub fn deinit(self: *LoginResult, allocator: std.mem.Allocator) void {
        allocator.free(self.issuer);
        allocator.free(self.signer_jwks_json);
        self.* = undefined;
    }
};

pub fn validateLogin(
    allocator: std.mem.Allocator,
    transport: client_mod.Transport,
    control_plane_url: []const u8,
    bearer_token: []const u8,
    request_id: []const u8,
) !LoginResult {
    const client = try client_mod.Client.init(allocator, transport, control_plane_url);
    var discovery = try client.discover();
    defer discovery.deinit();
    var signer = try client.signerMetadata(discovery.value());
    defer signer.deinit();
    var jwks = try client.signerJwks(discovery.value());
    defer jwks.deinit();
    const request_body = try std.json.Stringify.valueAlloc(allocator, .{
        .contract_version = connect.CONTRACT_VERSION,
        .request_id = request_id,
        .runtime_ids = &[_][]const u8{},
    }, .{});
    defer allocator.free(request_body);
    var response = try client.authenticatedJson(
        .POST,
        "/v1/runtime-inventory/query",
        bearer_token,
        request_body,
        &.{.ok},
    );
    defer response.deinit(allocator);
    const Inventory = struct {
        contract_version: []const u8,
        request_id: []const u8,
        runtimes: []const std.json.Value,
    };
    var inventory = std.json.parseFromSlice(Inventory, allocator, response.body, .{}) catch
        return error.InvalidControlPlaneResponse;
    defer inventory.deinit();
    if (!std.mem.eql(u8, inventory.value.contract_version, connect.CONTRACT_VERSION) or
        !std.mem.eql(u8, inventory.value.request_id, request_id)) return error.InvalidControlPlaneResponse;
    const issuer = try allocator.dupe(u8, discovery.value().issuer);
    errdefer allocator.free(issuer);
    const signer_jwks_json = try std.json.Stringify.valueAlloc(allocator, jwks.value, .{});
    errdefer allocator.free(signer_jwks_json);
    return .{
        .issuer = issuer,
        .signer_jwks_json = signer_jwks_json,
        .maximum_grant_lifetime_seconds = signer.value.maximum_grant_lifetime_seconds orelse 300,
        .headless_login_supported = discovery.value().oidc.headless_authorization.supported,
    };
}

pub fn link(
    allocator: std.mem.Allocator,
    transport: client_mod.Transport,
    keys: *const crypto.RuntimeKeys,
    connector: ?reconciler_mod.Connector,
    input: LinkInput,
) !LinkResult {
    try validateRequestId(input.request_id);
    if (!std.mem.eql(u8, input.provider, "external") and !std.mem.eql(u8, input.provider, "noop_test")) {
        return error.UnsupportedEndpointProvider;
    }
    if (std.mem.eql(u8, input.provider, "external") != (input.external_descriptor != null)) {
        return error.ExternalDescriptorRequired;
    }
    const client = try client_mod.Client.init(allocator, transport, input.control_plane_url);
    var discovery = try client.discover();
    defer discovery.deinit();
    var signer = try client.signerMetadata(discovery.value());
    defer signer.deinit();

    const signing_public = keys.signing.public_key.toBytes();
    const signing_kid = try crypto.publicKeyIdAlloc(allocator, "runtime-signing", &signing_public);
    defer allocator.free(signing_kid);
    const encryption_kid = try crypto.publicKeyIdAlloc(allocator, "runtime-encryption", &keys.encryption.public_key);
    defer allocator.free(encryption_kid);
    const signing_x = try crypto.base64UrlEncodeAlloc(allocator, &signing_public);
    defer allocator.free(signing_x);
    const encryption_x = try crypto.base64UrlEncodeAlloc(allocator, &keys.encryption.public_key);
    defer allocator.free(encryption_x);
    const signing_jwk: crypto.PublicJwk = .{
        .kty = "OKP",
        .crv = "Ed25519",
        .x = signing_x,
        .kid = signing_kid,
        .use = "sig",
        .alg = "EdDSA",
    };
    const encryption_jwk: crypto.PublicJwk = .{
        .kty = "OKP",
        .crv = "X25519",
        .x = encryption_x,
        .kid = encryption_kid,
        .use = "enc",
        .alg = "ECDH-ES",
    };
    const challenge_body = try std.json.Stringify.valueAlloc(allocator, .{
        .contract_version = connect.CONTRACT_VERSION,
        .request_id = input.request_id,
        .runtime_id = input.runtime_id,
        .instance_id = input.instance_id,
        .runtime_signing_jwk = signing_jwk,
        .runtime_encryption_jwk = encryption_jwk,
    }, .{ .emit_null_optional_fields = false });
    defer allocator.free(challenge_body);
    var challenge_response = try client.authenticatedJson(
        .POST,
        "/v1/runtime-links/challenges",
        input.bearer_token,
        challenge_body,
        &.{ .ok, .created },
    );
    defer challenge_response.deinit(allocator);
    const Challenge = struct {
        contract_version: []const u8,
        challenge_id: []const u8,
        audience: []const u8,
        principal: crypto.BootstrapClaims.Principal,
        nonce: []const u8,
        expires_at: []const u8,
    };
    var challenge = std.json.parseFromSlice(Challenge, allocator, challenge_response.body, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidControlPlaneResponse;
    defer challenge.deinit();
    if (!std.mem.eql(u8, challenge.value.contract_version, connect.CONTRACT_VERSION) or
        !std.mem.eql(u8, challenge.value.audience, discovery.value().issuer) or
        !validPrefixedHex(challenge.value.challenge_id, "chl_") or
        !validBase64Url43(challenge.value.nonce) or
        !validPrincipal(challenge.value.principal)) return error.InvalidControlPlaneResponse;
    const challenge_expiry = try parseRfc3339Seconds(challenge.value.expires_at);
    const proof_now = input.now_seconds_fn();
    const proof_expiry = @min(challenge_expiry, proof_now + 60);
    if (proof_expiry <= proof_now) return error.LinkChallengeExpired;
    const signing_thumbprint = try crypto.thumbprintAlloc(allocator, "Ed25519", &signing_public);
    defer allocator.free(signing_thumbprint);
    const encryption_thumbprint = try crypto.thumbprintAlloc(allocator, "X25519", &keys.encryption.public_key);
    defer allocator.free(encryption_thumbprint);
    const runtime_issuer = try std.fmt.allocPrint(allocator, "urn:verde:runtime:{s}", .{input.runtime_id});
    defer allocator.free(runtime_issuer);
    const link_payload = try std.json.Stringify.valueAlloc(allocator, .{
        .contract_version = connect.CONTRACT_VERSION,
        .challenge_id = challenge.value.challenge_id,
        .principal = challenge.value.principal,
        .runtime_id = input.runtime_id,
        .instance_id = input.instance_id,
        .runtime_key_thumbprint = signing_thumbprint,
        .runtime_encryption_key_thumbprint = encryption_thumbprint,
        .nonce = challenge.value.nonce,
        .iss = runtime_issuer,
        .sub = input.runtime_id,
        .aud = challenge.value.audience,
        .jti = challenge.value.challenge_id,
        .iat = proof_now,
        .nbf = proof_now,
        .exp = proof_expiry,
    }, .{});
    defer allocator.free(link_payload);
    const link_proof = try crypto.signCompactAlloc(
        allocator,
        &keys.signing,
        signing_kid,
        "verde-runtime-link+jwt",
        link_payload,
    );
    defer allocator.free(link_proof);
    const link_body = try std.json.Stringify.valueAlloc(allocator, .{
        .contract_version = connect.CONTRACT_VERSION,
        .challenge_id = challenge.value.challenge_id,
        .proof_jwt = link_proof,
    }, .{});
    defer allocator.free(link_body);
    var link_response = try client.authenticatedJson(
        .POST,
        "/v1/runtime-links",
        input.bearer_token,
        link_body,
        &.{ .ok, .created },
    );
    defer link_response.deinit(allocator);
    const Link = struct {
        contract_version: []const u8,
        link_id: []const u8,
        runtime_id: []const u8,
        instance_id: []const u8,
        runtime_key_thumbprint: []const u8,
        runtime_encryption_key_thumbprint: []const u8,
        status: []const u8,
        created_at: []const u8,
        unlinked_at: ?[]const u8 = null,
    };
    var linked = std.json.parseFromSlice(Link, allocator, link_response.body, .{ .allocate = .alloc_always }) catch
        return error.InvalidControlPlaneResponse;
    defer linked.deinit();
    if (!std.mem.eql(u8, linked.value.contract_version, connect.CONTRACT_VERSION) or
        !std.mem.eql(u8, linked.value.runtime_id, input.runtime_id) or
        !std.mem.eql(u8, linked.value.instance_id, input.instance_id) or
        !std.mem.eql(u8, linked.value.runtime_key_thumbprint, signing_thumbprint) or
        !std.mem.eql(u8, linked.value.runtime_encryption_key_thumbprint, encryption_thumbprint) or
        !std.mem.eql(u8, linked.value.status, "linked") or
        !validPrefixedHex(linked.value.link_id, "lnk_") or linked.value.unlinked_at != null)
    {
        return error.LinkIdentityMismatch;
    }
    _ = parseRfc3339Seconds(linked.value.created_at) catch return error.InvalidControlPlaneResponse;

    // A 200 receipt can refer to a preexisting link: never compensate it.
    // Invalid/ambiguous creation responses never authorize guessed deletion.
    errdefer if (link_response.status == .created) {
        if (unlink(allocator, transport, input.control_plane_url, input.bearer_token, linked.value.link_id, input.runtime_id, input.instance_id, input.request_id)) |_| {
            if (input.recovery) |recovery| recovery.clear_fn(recovery.context, linked.value.link_id) catch {};
        } else |_| {}
    };
    if (input.recovery) |recovery| try recovery.save_fn(recovery.context, linked.value.link_id);

    const enrollment_now = input.now_seconds_fn();
    const expires_at = try formatRfc3339Alloc(allocator, enrollment_now + 90);
    defer allocator.free(expires_at);
    const unsigned_enrollment = .{
        .contract_version = connect.CONTRACT_VERSION,
        .request_id = input.request_id,
        .provider = input.provider,
        .expires_at = expires_at,
        .external_descriptor = input.external_descriptor,
    };
    const unsigned_json = try std.json.Stringify.valueAlloc(allocator, unsigned_enrollment, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(unsigned_json);
    var unsigned_value = try std.json.parseFromSlice(std.json.Value, allocator, unsigned_json, .{});
    defer unsigned_value.deinit();
    const request_digest = try crypto.stableDigestAlloc(allocator, unsigned_value.value);
    defer allocator.free(request_digest);
    const enrollment_payload = try std.json.Stringify.valueAlloc(allocator, .{
        .contract_version = connect.CONTRACT_VERSION,
        .link_id = linked.value.link_id,
        .request_id = input.request_id,
        .request_digest = request_digest,
        .runtime_id = input.runtime_id,
        .instance_id = input.instance_id,
        .runtime_key_thumbprint = signing_thumbprint,
        .iss = runtime_issuer,
        .sub = input.runtime_id,
        .aud = discovery.value().issuer,
        .jti = input.request_id,
        .iat = enrollment_now,
        .nbf = enrollment_now,
        .exp = enrollment_now + 90,
    }, .{});
    defer allocator.free(enrollment_payload);
    const enrollment_proof = try crypto.signCompactAlloc(
        allocator,
        &keys.signing,
        signing_kid,
        "verde-endpoint-enrollment+jwt",
        enrollment_payload,
    );
    defer allocator.free(enrollment_proof);
    const enrollment_body = try std.json.Stringify.valueAlloc(allocator, .{
        .contract_version = connect.CONTRACT_VERSION,
        .request_id = input.request_id,
        .provider = input.provider,
        .runtime_proof_jwt = enrollment_proof,
        .expires_at = expires_at,
        .external_descriptor = input.external_descriptor,
    }, .{ .emit_null_optional_fields = false });
    defer allocator.free(enrollment_body);
    const enrollment_path = try std.fmt.allocPrint(
        allocator,
        "/v1/runtime-links/{s}/endpoint-enrollments",
        .{linked.value.link_id},
    );
    defer allocator.free(enrollment_path);
    var enrollment_response = try client.authenticatedJson(
        .POST,
        enrollment_path,
        input.bearer_token,
        enrollment_body,
        &.{ .ok, .created },
    );
    defer enrollment_response.deinit(allocator);
    const Enrollment = struct {
        contract_version: []const u8,
        enrollment_id: []const u8,
        provider: []const u8,
        descriptor: connect.RuntimeDescriptor,
        connector_enrollment: ?struct {
            encrypted_credential: []const u8,
            expires_at: []const u8,
            key_thumbprint: []const u8,
            alg: []const u8,
            enc: []const u8,
        } = null,
        created_at: []const u8,
    };
    var enrollment = std.json.parseFromSlice(Enrollment, allocator, enrollment_response.body, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidControlPlaneResponse;
    defer enrollment.deinit();
    try validateEnrollment(enrollment.value, input, linked.value.link_id, encryption_thumbprint);
    _ = parseRfc3339Seconds(enrollment.value.created_at) catch return error.InvalidControlPlaneResponse;
    var connector_running = false;
    if (enrollment.value.connector_enrollment) |sealed| {
        const connector_expiry = parseRfc3339Seconds(sealed.expires_at) catch
            return error.InvalidControlPlaneResponse;
        if (connector_expiry <= input.now_seconds_fn()) return error.ConnectorEnrollmentExpired;
        const owned_connector = connector orelse return error.ConnectorAdapterUnavailable;
        const plaintext = try crypto.decryptConnectorJweAlloc(
            allocator,
            sealed.encrypted_credential,
            keys.encryption.secret_key,
            encryption_kid,
            enrollment.value.enrollment_id,
            sealed.expires_at,
        );
        defer {
            std.crypto.secureZero(u8, plaintext);
            allocator.free(plaintext);
        }
        try owned_connector.start(plaintext);
        connector_running = owned_connector.running();
        if (!connector_running) return error.ConnectorStartFailed;
    }
    const link_id = try allocator.dupe(u8, linked.value.link_id);
    errdefer allocator.free(link_id);
    const enrollment_id = try allocator.dupe(u8, enrollment.value.enrollment_id);
    errdefer allocator.free(enrollment_id);
    const endpoint_https_url = try allocator.dupe(u8, enrollment.value.descriptor.https_url);
    errdefer allocator.free(endpoint_https_url);
    const endpoint_wss_url = try allocator.dupe(u8, enrollment.value.descriptor.wss_url);
    errdefer allocator.free(endpoint_wss_url);
    const connector_provider = try allocator.dupe(u8, enrollment.value.provider);
    errdefer allocator.free(connector_provider);
    return .{
        .link_id = link_id,
        .enrollment_id = enrollment_id,
        .endpoint_https_url = endpoint_https_url,
        .endpoint_wss_url = endpoint_wss_url,
        .connector_provider = connector_provider,
        .connector_running = connector_running,
    };
}

pub fn unlink(
    allocator: std.mem.Allocator,
    transport: client_mod.Transport,
    control_plane_url: []const u8,
    bearer_token: []const u8,
    link_id: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    request_id: []const u8,
) !void {
    if (!validPrefixedHex(link_id, "lnk_")) return error.InvalidControlPlaneResponse;
    const client = try client_mod.Client.init(allocator, transport, control_plane_url);
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .contract_version = connect.CONTRACT_VERSION,
        .request_id = request_id,
    }, .{});
    defer allocator.free(body);
    const path = try std.fmt.allocPrint(allocator, "/v1/runtime-links/{s}", .{link_id});
    defer allocator.free(path);
    var response = try client.authenticatedJson(.DELETE, path, bearer_token, body, &.{.ok});
    defer response.deinit(allocator);
    const Unlinked = struct {
        contract_version: []const u8,
        link_id: []const u8,
        runtime_id: []const u8,
        instance_id: []const u8,
        runtime_key_thumbprint: []const u8,
        runtime_encryption_key_thumbprint: []const u8,
        status: []const u8,
        created_at: []const u8,
        unlinked_at: ?[]const u8 = null,
    };
    var unlinked = std.json.parseFromSlice(Unlinked, allocator, response.body, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidControlPlaneResponse;
    defer unlinked.deinit();
    if (!std.mem.eql(u8, unlinked.value.contract_version, connect.CONTRACT_VERSION) or
        !std.mem.eql(u8, unlinked.value.link_id, link_id) or
        !std.mem.eql(u8, unlinked.value.runtime_id, runtime_id) or
        !std.mem.eql(u8, unlinked.value.instance_id, instance_id) or
        !std.mem.eql(u8, unlinked.value.status, "unlinked") or unlinked.value.unlinked_at == null)
    {
        return error.LinkIdentityMismatch;
    }
    _ = parseRfc3339Seconds(unlinked.value.created_at) catch return error.InvalidControlPlaneResponse;
    _ = parseRfc3339Seconds(unlinked.value.unlinked_at.?) catch return error.InvalidControlPlaneResponse;
}

fn validateEnrollment(value: anytype, input: LinkInput, link_id: []const u8, encryption_thumbprint: []const u8) !void {
    _ = link_id;
    if (!std.mem.eql(u8, value.contract_version, connect.CONTRACT_VERSION) or
        !std.mem.eql(u8, value.provider, input.provider) or
        !validPrefixedHex(value.enrollment_id, "enr_")) return error.EnrollmentIdentityMismatch;
    connect.validateRuntimeDescriptor(value.descriptor, input.runtime_id, input.instance_id) catch
        return error.EnrollmentIdentityMismatch;
    if (input.external_descriptor) |expected| {
        if (!descriptorEqual(value.descriptor, expected) or value.connector_enrollment != null) {
            return error.EnrollmentIdentityMismatch;
        }
    } else if (value.connector_enrollment == null) {
        return error.EnrollmentIdentityMismatch;
    }
    if (value.connector_enrollment) |sealed| {
        if (!std.mem.eql(u8, sealed.key_thumbprint, encryption_thumbprint) or
            !std.mem.eql(u8, sealed.alg, "ECDH-ES") or
            !std.mem.eql(u8, sealed.enc, "A256GCM")) return error.EnrollmentIdentityMismatch;
    }
}

fn descriptorEqual(left: connect.RuntimeDescriptor, right: connect.RuntimeDescriptor) bool {
    if (!std.mem.eql(u8, left.contract_version, right.contract_version) or
        !std.mem.eql(u8, left.runtime_id, right.runtime_id) or
        !std.mem.eql(u8, left.instance_id, right.instance_id) or
        !std.mem.eql(u8, left.https_url, right.https_url) or
        !std.mem.eql(u8, left.wss_url, right.wss_url) or
        !std.mem.eql(u8, left.tls_identity.kind, right.tls_identity.kind) or
        !std.mem.eql(u8, left.tls_identity.sha256, right.tls_identity.sha256) or
        left.protocol.major != right.protocol.major or left.protocol.minor != right.protocol.minor or
        left.capabilities.len != right.capabilities.len) return false;
    for (left.capabilities, right.capabilities) |left_capability, right_capability| {
        if (!std.mem.eql(u8, left_capability, right_capability)) return false;
    }
    return true;
}

fn validPrefixedHex(value: []const u8, prefix: []const u8) bool {
    if (value.len != prefix.len + 32 or !std.mem.startsWith(u8, value, prefix)) return false;
    for (value[prefix.len..]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn validBase64Url43(value: []const u8) bool {
    if (value.len != 43) return false;
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn validPrincipal(principal: crypto.BootstrapClaims.Principal) bool {
    if (principal.issuer.len == 0 or principal.issuer.len > 2048 or
        principal.subject.len == 0 or principal.subject.len > 255) return false;
    for (principal.issuer) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    for (principal.subject) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    const uri = std.Uri.parse(principal.issuer) catch return false;
    return uri.scheme.len != 0;
}

pub fn randomRequestId(io: std.Io) ![36]u8 {
    var bytes: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    try io.randomSecure(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return "req_".* ++ hex;
}

fn validateRequestId(value: []const u8) !void {
    if (value.len != 36 or !std.mem.startsWith(u8, value, "req_")) return error.InvalidConnectRequestId;
    for (value[4..]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidConnectRequestId;
}

fn parseRfc3339Seconds(value: []const u8) !i64 {
    if (value.len < 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or
        value[13] != ':' or value[16] != ':' or value[value.len - 1] != 'Z') return error.InvalidTimestamp;
    if (value.len != 20) {
        if (value.len < 22 or value[19] != '.') return error.InvalidTimestamp;
        for (value[20 .. value.len - 1]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
    }
    const year = try std.fmt.parseInt(u16, value[0..4], 10);
    const month_number = try std.fmt.parseInt(u4, value[5..7], 10);
    const day = try std.fmt.parseInt(u5, value[8..10], 10);
    const hour = try std.fmt.parseInt(u5, value[11..13], 10);
    const minute = try std.fmt.parseInt(u6, value[14..16], 10);
    const second = try std.fmt.parseInt(u6, value[17..19], 10);
    if (year < 1970 or month_number < 1 or month_number > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) {
        return error.InvalidTimestamp;
    }
    const month: std.time.epoch.Month = @enumFromInt(month_number);
    if (day > std.time.epoch.getDaysInMonth(year, month)) return error.InvalidTimestamp;
    var days: u64 = 0;
    var cursor: u16 = 1970;
    while (cursor < year) : (cursor += 1) days += std.time.epoch.getDaysInYear(cursor);
    var month_cursor: u4 = 1;
    while (month_cursor < month_number) : (month_cursor += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(month_cursor));
    }
    const result = days * std.time.epoch.secs_per_day +
        (@as(u64, day) - 1) * std.time.epoch.secs_per_day +
        @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
    return std.math.cast(i64, result) orelse error.InvalidTimestamp;
}

fn formatRfc3339Alloc(allocator: std.mem.Allocator, seconds: i64) ![]u8 {
    if (seconds < 0) return error.InvalidTimestamp;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

test "timestamp helpers round-trip the public vector instant" {
    const seconds = try parseRfc3339Seconds("2030-01-01T00:00:00.000Z");
    try std.testing.expectEqual(@as(i64, 1_893_456_000), seconds);
    const formatted = try formatRfc3339Alloc(std.testing.allocator, seconds);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("2030-01-01T00:00:00.000Z", formatted);
}

test "request IDs are canonical and generated from secure entropy" {
    const id = try randomRequestId(std.testing.io);
    try validateRequestId(&id);
    try std.testing.expectError(error.InvalidConnectRequestId, validateRequestId("req_NOT_HEX"));
}

test "native link signs with fresh time after delayed challenge and rejects expired challenge" {
    const Fixture = struct {
        var seconds: i64 = 1_893_456_000;
        keys: *crypto.RuntimeKeys,
        expire: bool,
        verified: bool = false,

        fn now() i64 {
            return seconds;
        }

        fn send(raw: *anyopaque, allocator: std.mem.Allocator, request: client_mod.Request) !client_mod.Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.mem.endsWith(u8, request.url, "/.well-known/verde-connect-configuration")) {
                return .{ .status = .ok, .body = try allocator.dupe(u8,
                    \\{"contract_version":"1","issuer":"https://connect.example.test","api_base_url":"https://connect.example.test","oidc":{"issuer":"https://id.example.test","authorization_endpoint":"https://id.example.test/auth","token_endpoint":"https://id.example.test/token","public_client":{"client_id":"verde","scopes":["openid"],"redirect_uris":["http://127.0.0.1:48123/callback"],"response_type":"code","token_endpoint_auth_method":"none"},"code_challenge_methods_supported":["S256"],"headless_authorization":{"supported":false}},"jwks_uri":"https://connect.example.test/v1/.well-known/jwks.json","signer_metadata_url":"https://connect.example.test/v1/signer-metadata","capabilities":["runtime-link-proof-ed25519","inventory-v1","bootstrap-grant-eddsa","connector-credential-jwe-x25519","endpoint-external"]}
                ) };
            }
            if (std.mem.endsWith(u8, request.url, "/v1/signer-metadata")) {
                return .{ .status = .ok, .body = try allocator.dupe(u8,
                    \\{"contract_version":"1","issuer":"https://connect.example.test","jwks_uri":"https://connect.example.test/v1/.well-known/jwks.json","algorithms":["EdDSA"],"maximum_grant_lifetime_seconds":300}
                ) };
            }
            if (std.mem.endsWith(u8, request.url, "/v1/runtime-links/challenges")) {
                // The challenge arrives after lookup/network delay, without a
                // wall-clock sleep. Sampling before these requests is stale.
                seconds = if (self.expire) 1_893_456_090 else 1_893_456_003;
                return .{ .status = .created, .body = try allocator.dupe(u8,
                    \\{"contract_version":"1","challenge_id":"chl_11111111111111111111111111111111","audience":"https://connect.example.test","principal":{"issuer":"https://id.example.test","subject":"fixture"},"nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2030-01-01T00:01:00.000Z"}
                ) };
            }
            if (std.mem.endsWith(u8, request.url, "/v1/runtime-links")) {
                var body = try std.json.parseFromSlice(std.json.Value, allocator, request.body.?, .{});
                defer body.deinit();
                const jwt = body.value.object.get("proof_jwt").?.string;
                var parts = std.mem.splitScalar(u8, jwt, '.');
                _ = parts.next().?;
                const encoded_payload = parts.next().?;
                const encoded_signature = parts.next().?;
                try std.testing.expect(parts.next() == null);
                const payload = try crypto.base64UrlDecodeAlloc(allocator, encoded_payload);
                defer allocator.free(payload);
                var claims = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
                defer claims.deinit();
                try std.testing.expectEqual(@as(i64, 1_893_456_003), claims.value.object.get("iat").?.integer);
                try std.testing.expectEqual(seconds, claims.value.object.get("nbf").?.integer);
                try std.testing.expectEqual(@as(i64, 1_893_456_060), claims.value.object.get("exp").?.integer);
                const signature = try crypto.base64UrlDecodeAlloc(allocator, encoded_signature);
                defer allocator.free(signature);
                try std.testing.expectEqual(@as(usize, 64), signature.len);
                // Verify the actual native Ed25519 proof, not just JSON fields.
                try std.crypto.sign.Ed25519.Signature.fromBytes(signature[0..64].*).verify(
                    jwt[0 .. jwt.len - encoded_signature.len - 1],
                    self.keys.signing.public_key,
                );
                self.verified = true;
                return error.FixtureProofVerified;
            }
            return error.UnexpectedFixtureRequest;
        }
    };
    var keys = crypto.RuntimeKeys.generate(std.testing.io);
    defer keys.clear();
    for ([_]bool{ false, true }) |expired| {
        Fixture.seconds = 1_893_456_000;
        var fixture: Fixture = .{ .keys = &keys, .expire = expired };
        const result = link(std.testing.allocator, .{ .context = &fixture, .send_fn = Fixture.send }, &keys, null, .{
            .control_plane_url = "https://connect.example.test",
            .bearer_token = "synthetic-offline-fixture-token",
            .runtime_id = "11111111111111111111111111111111",
            .instance_id = "22222222222222222222222222222222",
            .request_id = "req_33333333333333333333333333333333",
            .provider = "noop_test",
            .external_descriptor = null,
            .now_seconds_fn = Fixture.now,
        });
        if (expired) {
            try std.testing.expectError(error.LinkChallengeExpired, result);
            try std.testing.expect(!fixture.verified);
        } else {
            try std.testing.expectError(error.FixtureProofVerified, result);
            try std.testing.expect(fixture.verified);
        }
    }
}

test "enrollment failures rollback only verified created links and retain failed cleanup recovery" {
    const Fixture = struct {
        const Mode = enum { enrollment_failure, rollback_failure, ambiguous_rollback, preexisting, ambiguous_creation, wrong_identity };
        keys: *crypto.RuntimeKeys,
        mode: Mode,
        saved: bool = false,
        cleared: bool = false,
        deleted: bool = false,
        fn now() i64 {
            return 1_893_456_003;
        }
        fn save(raw: *anyopaque, id: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("lnk_22222222222222222222222222222222", id);
            self.saved = true;
        }
        fn clear(raw: *anyopaque, id: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("lnk_22222222222222222222222222222222", id);
            try std.testing.expect(self.deleted);
            self.cleared = true;
        }
        fn receipt(self: *@This(), allocator: std.mem.Allocator, removed: bool) ![]u8 {
            const signing = self.keys.signing.public_key.toBytes();
            const encryption = self.keys.encryption.public_key;
            const signing_thumb = try crypto.thumbprintAlloc(allocator, "Ed25519", &signing);
            defer allocator.free(signing_thumb);
            const encryption_thumb = try crypto.thumbprintAlloc(allocator, "X25519", &encryption);
            defer allocator.free(encryption_thumb);
            return std.json.Stringify.valueAlloc(allocator, .{
                .contract_version = "1",
                .link_id = "lnk_22222222222222222222222222222222",
                .runtime_id = "11111111111111111111111111111111",
                .instance_id = if (self.mode == .wrong_identity) "99999999999999999999999999999999" else "22222222222222222222222222222222",
                .runtime_key_thumbprint = signing_thumb,
                .runtime_encryption_key_thumbprint = encryption_thumb,
                .status = if (removed) "unlinked" else "linked",
                .created_at = "2030-01-01T00:00:03.000Z",
                .unlinked_at = if (removed) @as(?[]const u8, "2030-01-01T00:00:04.000Z") else null,
            }, .{});
        }
        fn send(raw: *anyopaque, allocator: std.mem.Allocator, request: client_mod.Request) !client_mod.Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.mem.endsWith(u8, request.url, "/.well-known/verde-connect-configuration")) {
                return .{ .status = .ok, .body = try allocator.dupe(u8,
                    \\{"contract_version":"1","issuer":"https://connect.example.test","api_base_url":"https://connect.example.test","oidc":{"issuer":"https://id.example.test","authorization_endpoint":"https://id.example.test/auth","token_endpoint":"https://id.example.test/token","public_client":{"client_id":"verde","scopes":["openid"],"redirect_uris":["http://127.0.0.1:48123/callback"],"response_type":"code","token_endpoint_auth_method":"none"},"code_challenge_methods_supported":["S256"],"headless_authorization":{"supported":false}},"jwks_uri":"https://connect.example.test/v1/.well-known/jwks.json","signer_metadata_url":"https://connect.example.test/v1/signer-metadata","capabilities":["runtime-link-proof-ed25519","inventory-v1","bootstrap-grant-eddsa","connector-credential-jwe-x25519","endpoint-external"]}
                ) };
            }
            if (std.mem.endsWith(u8, request.url, "/v1/signer-metadata")) {
                return .{ .status = .ok, .body = try allocator.dupe(u8,
                    \\{"contract_version":"1","issuer":"https://connect.example.test","jwks_uri":"https://connect.example.test/v1/.well-known/jwks.json","algorithms":["EdDSA"],"maximum_grant_lifetime_seconds":300}
                ) };
            }

            if (std.mem.endsWith(u8, request.url, "/v1/runtime-links/challenges")) {
                return .{ .status = .created, .body = try allocator.dupe(u8,
                    \\{"contract_version":"1","challenge_id":"chl_11111111111111111111111111111111","audience":"https://connect.example.test","principal":{"issuer":"https://id.example.test","subject":"fixture"},"nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2030-01-01T00:01:00.000Z"}
                ) };
            }
            if (std.mem.endsWith(u8, request.url, "/v1/runtime-links")) {
                return .{ .status = if (self.mode == .preexisting) .ok else .created, .body = if (self.mode == .ambiguous_creation) try allocator.dupe(u8, "{broken") else try self.receipt(allocator, false) };
            }
            if (std.mem.endsWith(u8, request.url, "/endpoint-enrollments")) {
                try std.testing.expect(self.saved and !self.cleared);
                return error.EnrollmentRefused;
            }
            if (request.method == .DELETE) {
                try std.testing.expect(self.saved);
                try std.testing.expectEqualStrings("https://connect.example.test/v1/runtime-links/lnk_22222222222222222222222222222222", request.url);
                try std.testing.expectEqualStrings("synthetic-offline-fixture-token", request.bearer_token.?);
                self.deleted = true;
                if (self.mode == .rollback_failure) return error.RollbackTransportFailed;
                return .{ .status = .ok, .body = if (self.mode == .ambiguous_rollback) try allocator.dupe(u8, "{broken") else try self.receipt(allocator, true) };
            }
            return error.UnexpectedFixtureRequest;
        }
    };
    var keys = crypto.RuntimeKeys.generate(std.testing.io);
    defer keys.clear();
    inline for (std.meta.tags(Fixture.Mode)) |mode| {
        var fixture: Fixture = .{ .keys = &keys, .mode = mode };
        const result = link(std.testing.allocator, .{ .context = &fixture, .send_fn = Fixture.send }, &keys, null, .{
            .control_plane_url = "https://connect.example.test",
            .bearer_token = "synthetic-offline-fixture-token",
            .runtime_id = "11111111111111111111111111111111",
            .instance_id = "22222222222222222222222222222222",
            .request_id = "req_33333333333333333333333333333333",
            .provider = "noop_test",
            .external_descriptor = null,
            .now_seconds_fn = Fixture.now,
            .recovery = .{ .context = &fixture, .save_fn = Fixture.save, .clear_fn = Fixture.clear },
        });
        if (mode == .ambiguous_creation) {
            try std.testing.expectError(error.InvalidControlPlaneResponse, result);
            try std.testing.expect(!fixture.saved and !fixture.deleted);
        } else if (mode == .wrong_identity) {
            try std.testing.expectError(error.LinkIdentityMismatch, result);
            try std.testing.expect(!fixture.saved and !fixture.deleted);
        } else {
            try std.testing.expectError(error.EnrollmentRefused, result);
            try std.testing.expect(fixture.saved);
            try std.testing.expectEqual(mode != .preexisting, fixture.deleted);
            try std.testing.expectEqual(mode == .enrollment_failure, fixture.cleared);
        }
    }
}
