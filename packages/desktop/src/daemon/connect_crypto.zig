//! Verde Connect v1 runtime key, JOSE, and bootstrap validation primitives.

const std = @import("std");
const headless = @import("headless");

const connect = headless.connect_protocol;
const access = headless.access_protocol;
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const RuntimeKeys = struct {
    signing: Ed25519.KeyPair,
    encryption: X25519.KeyPair,

    pub fn generate(io: std.Io) RuntimeKeys {
        return .{
            .signing = Ed25519.KeyPair.generate(io),
            .encryption = X25519.KeyPair.generate(io),
        };
    }

    pub fn clear(self: *RuntimeKeys) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&self.signing.secret_key));
        std.crypto.secureZero(u8, self.encryption.secret_key[0..]);
        self.* = undefined;
    }
};

pub const PublicJwk = struct {
    kty: []const u8,
    crv: []const u8,
    x: []const u8,
    kid: []const u8,
    use: ?[]const u8 = null,
    alg: ?[]const u8 = null,
};

pub const BootstrapExpectation = struct {
    issuer: []const u8,
    audience: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    device_id: []const u8,
    device_key_thumbprint: []const u8,
    client_nonce: []const u8,
    now_seconds: i64,
    maximum_lifetime_seconds: i64 = 300,
};

pub const BootstrapClaims = struct {
    iss: []const u8,
    sub: []const u8,
    aud: []const u8,
    jti: []const u8,
    iat: i64,
    nbf: i64,
    exp: i64,
    contract_version: []const u8,
    principal: Principal,
    link_id: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    device_id: []const u8,
    device_key_thumbprint: []const u8,
    client_nonce: []const u8,
    request_id: []const u8,
    scopes: []const []const u8,

    pub const Principal = struct { issuer: []const u8, subject: []const u8 };
};

pub const VerifiedBootstrap = struct {
    parsed: std.json.Parsed(BootstrapClaims),

    pub fn deinit(self: *VerifiedBootstrap) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn claims(self: *const VerifiedBootstrap) BootstrapClaims {
        return self.parsed.value;
    }
};

pub fn base64UrlEncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes);
    return encoded;
}

pub fn base64UrlDecodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded);
    return decoded;
}

pub fn publicKeyIdAlloc(allocator: std.mem.Allocator, prefix: []const u8, public_key: []const u8) ![]u8 {
    const thumbprint = try thumbprintAlloc(allocator, if (std.mem.eql(u8, prefix, "runtime-signing")) "Ed25519" else "X25519", public_key);
    defer allocator.free(thumbprint);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, thumbprint });
}

pub fn thumbprintAlloc(allocator: std.mem.Allocator, curve: []const u8, public_key: []const u8) ![]u8 {
    const x = try base64UrlEncodeAlloc(allocator, public_key);
    defer allocator.free(x);
    const canonical = try std.fmt.allocPrint(
        allocator,
        "{{\"crv\":\"{s}\",\"kty\":\"OKP\",\"x\":\"{s}\"}}",
        .{ curve, x },
    );
    defer allocator.free(canonical);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(canonical, &digest, .{});
    return base64UrlEncodeAlloc(allocator, &digest);
}

pub fn publicJwkAlloc(
    allocator: std.mem.Allocator,
    curve: []const u8,
    public_key: []const u8,
    kid: []const u8,
) ![]u8 {
    const x = try base64UrlEncodeAlloc(allocator, public_key);
    defer allocator.free(x);
    const signing = std.mem.eql(u8, curve, "Ed25519");
    return std.fmt.allocPrint(
        allocator,
        "{{\"kty\":\"OKP\",\"crv\":\"{s}\",\"x\":\"{s}\",\"kid\":\"{s}\",\"use\":\"{s}\",\"alg\":\"{s}\"}}",
        .{ curve, x, kid, if (signing) "sig" else "enc", if (signing) "EdDSA" else "ECDH-ES" },
    );
}

/// RFC 8785-compatible canonical digest for the bounded Connect request
/// shapes. Object keys are UTF-8 byte-sorted; arrays retain their wire order.
pub fn stableDigestAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writeCanonical(allocator, &writer.writer, value);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(writer.written(), &digest, .{});
    return base64UrlEncodeAlloc(allocator, &digest);
}

fn writeCanonical(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            const keys = try allocator.alloc([]const u8, object.count());
            defer allocator.free(keys);
            var iterator = object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) keys[index] = entry.key_ptr.*;
            std.mem.sort([]const u8, keys, {}, struct {
                fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.order(u8, left, right) == .lt;
                }
            }.lessThan);
            try writer.writeByte('{');
            for (keys, 0..) |key, key_index| {
                if (key_index != 0) try writer.writeByte(',');
                var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
                try json.write(key);
                try writer.writeByte(':');
                try writeCanonical(allocator, writer, object.get(key).?);
            }
            try writer.writeByte('}');
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeCanonical(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        else => {
            var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
            try json.write(value);
        },
    }
}

pub fn signCompactAlloc(
    allocator: std.mem.Allocator,
    key_pair: *const Ed25519.KeyPair,
    kid: []const u8,
    typ: []const u8,
    payload_json: []const u8,
) ![]u8 {
    const header_json = try std.fmt.allocPrint(
        allocator,
        "{{\"alg\":\"EdDSA\",\"kid\":\"{s}\",\"typ\":\"{s}\"}}",
        .{ kid, typ },
    );
    defer allocator.free(header_json);
    const header = try base64UrlEncodeAlloc(allocator, header_json);
    defer allocator.free(header);
    const payload = try base64UrlEncodeAlloc(allocator, payload_json);
    defer allocator.free(payload);
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header, payload });
    defer allocator.free(signing_input);
    const signature = try key_pair.sign(signing_input, null);
    const signature_encoded = try base64UrlEncodeAlloc(allocator, &signature.toBytes());
    defer allocator.free(signature_encoded);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, signature_encoded });
}

pub fn verifyBootstrapGrant(
    allocator: std.mem.Allocator,
    compact_jwt: []const u8,
    jwks: []const PublicJwk,
    expected: BootstrapExpectation,
) !VerifiedBootstrap {
    if (compact_jwt.len == 0 or compact_jwt.len > connect.MAX_COMPACT_TOKEN_BYTES) return error.InvalidBootstrapGrant;
    const parts = splitCompact(compact_jwt, 3) catch return error.InvalidBootstrapGrant;
    const header_bytes = base64UrlDecodeAlloc(allocator, parts[0]) catch return error.InvalidBootstrapGrant;
    defer allocator.free(header_bytes);
    const Header = struct { alg: []const u8, kid: []const u8, typ: []const u8 };
    var header = std.json.parseFromSlice(Header, allocator, header_bytes, .{ .allocate = .alloc_always }) catch
        return error.InvalidBootstrapGrant;
    defer header.deinit();
    if (!std.mem.eql(u8, header.value.alg, "EdDSA") or
        !std.mem.eql(u8, header.value.typ, "verde-connect-bootstrap+jwt")) return error.InvalidBootstrapGrant;
    const jwk = findSigningJwk(jwks, header.value.kid) orelse return error.UnknownBootstrapKey;
    const public_bytes = try decodeFixed(32, jwk.x);
    const signature_bytes = try decodeFixed(64, parts[2]);
    const public_key = Ed25519.PublicKey.fromBytes(public_bytes) catch return error.InvalidBootstrapGrant;
    Ed25519.Signature.fromBytes(signature_bytes).verify(
        compact_jwt[0 .. parts[0].len + 1 + parts[1].len],
        public_key,
    ) catch return error.InvalidBootstrapGrant;

    const payload_bytes = base64UrlDecodeAlloc(allocator, parts[1]) catch return error.InvalidBootstrapGrant;
    defer allocator.free(payload_bytes);
    var parsed = std.json.parseFromSlice(BootstrapClaims, allocator, payload_bytes, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidBootstrapGrant;
    errdefer parsed.deinit();
    try validateBootstrapClaims(parsed.value, expected);
    return .{ .parsed = parsed };
}

fn validateBootstrapClaims(claims: BootstrapClaims, expected: BootstrapExpectation) !void {
    if (expected.now_seconds < 0 or expected.maximum_lifetime_seconds < 15 or
        expected.maximum_lifetime_seconds > 300 or
        !validHex32(expected.runtime_id) or !validHex32(expected.instance_id) or
        !validPrefixedHex(expected.device_id, "dev_") or
        !validBase64Url43(expected.device_key_thumbprint) or
        !validBase64Url43(expected.client_nonce)) return error.InvalidBootstrapExpectation;
    if (!std.mem.eql(u8, claims.contract_version, connect.CONTRACT_VERSION) or
        !std.mem.eql(u8, claims.iss, expected.issuer) or
        !std.mem.eql(u8, claims.aud, expected.audience) or
        !std.mem.eql(u8, claims.runtime_id, expected.runtime_id) or
        !std.mem.eql(u8, claims.instance_id, expected.instance_id) or
        !std.mem.eql(u8, claims.device_id, expected.device_id) or
        !std.mem.eql(u8, claims.device_key_thumbprint, expected.device_key_thumbprint) or
        !std.mem.eql(u8, claims.client_nonce, expected.client_nonce)) return error.BootstrapIdentityMismatch;
    if (!validPrefixedHex(claims.jti, "grt_") or !validPrefixedHex(claims.link_id, "lnk_") or
        !validPrefixedHex(claims.request_id, "req_") or
        !validPrefixedHex(claims.device_id, "dev_") or
        !validHex32(claims.runtime_id) or !validHex32(claims.instance_id) or
        !validBase64Url43(claims.device_key_thumbprint) or !validBase64Url43(claims.client_nonce) or
        claims.principal.issuer.len == 0 or claims.principal.issuer.len > 2048 or
        claims.principal.subject.len == 0 or claims.principal.subject.len > 255)
    {
        return error.InvalidBootstrapGrant;
    }
    for (claims.principal.issuer) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidBootstrapGrant;
    for (claims.principal.subject) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidBootstrapGrant;
    if (claims.iat < 0 or claims.nbf < 0 or claims.exp < 0 or
        claims.iat != claims.nbf or claims.iat > expected.now_seconds or
        claims.exp <= expected.now_seconds or claims.exp <= claims.iat or
        claims.exp - claims.iat > expected.maximum_lifetime_seconds) return error.BootstrapGrantExpired;
    // Avoid allocation in validation: compare the subject's two slices around
    // its mandatory NUL separator.
    const separator = std.mem.indexOfScalar(u8, claims.sub, 0) orelse return error.InvalidBootstrapGrant;
    if (std.mem.indexOfScalarPos(u8, claims.sub, separator + 1, 0) != null or
        !std.mem.eql(u8, claims.sub[0..separator], claims.principal.issuer) or
        !std.mem.eql(u8, claims.sub[separator + 1 ..], claims.principal.subject)) return error.InvalidBootstrapGrant;
    try access.validateScopeNames(claims.scopes);
}

pub fn decryptConnectorJweAlloc(
    allocator: std.mem.Allocator,
    compact_jwe: []const u8,
    recipient_secret: [32]u8,
    expected_kid: []const u8,
    expected_enrollment_id: []const u8,
    expected_expires_at: []const u8,
) ![]u8 {
    if (compact_jwe.len == 0 or compact_jwe.len > 8192) return error.InvalidConnectorJwe;
    const parts = splitCompact(compact_jwe, 5) catch return error.InvalidConnectorJwe;
    if (parts[1].len != 0) return error.InvalidConnectorJwe;
    const header_bytes = base64UrlDecodeAlloc(allocator, parts[0]) catch return error.InvalidConnectorJwe;
    defer allocator.free(header_bytes);
    const Header = struct {
        alg: []const u8,
        enc: []const u8,
        typ: []const u8,
        kid: []const u8,
        enrollment_id: []const u8,
        expires_at: []const u8,
        epk: struct { x: []const u8, crv: []const u8, kty: []const u8 },
    };
    var header = std.json.parseFromSlice(Header, allocator, header_bytes, .{ .allocate = .alloc_always }) catch
        return error.InvalidConnectorJwe;
    defer header.deinit();
    if (!std.mem.eql(u8, header.value.alg, "ECDH-ES") or
        !std.mem.eql(u8, header.value.enc, "A256GCM") or
        !std.mem.eql(u8, header.value.typ, "verde-connect-credential+jwe") or
        !std.mem.eql(u8, header.value.kid, expected_kid) or
        !std.mem.eql(u8, header.value.enrollment_id, expected_enrollment_id) or
        !std.mem.eql(u8, header.value.expires_at, expected_expires_at) or
        !std.mem.eql(u8, header.value.epk.kty, "OKP") or
        !std.mem.eql(u8, header.value.epk.crv, "X25519")) return error.InvalidConnectorJwe;

    const ephemeral_public = try decodeFixed(32, header.value.epk.x);
    var shared = X25519.scalarmult(recipient_secret, ephemeral_public) catch return error.InvalidConnectorJwe;
    defer std.crypto.secureZero(u8, &shared);
    var key = deriveEcdhEsKey(shared);
    defer std.crypto.secureZero(u8, &key);
    const nonce = try decodeFixed(Aes256Gcm.nonce_length, parts[2]);
    const tag = try decodeFixed(Aes256Gcm.tag_length, parts[4]);
    const ciphertext = base64UrlDecodeAlloc(allocator, parts[3]) catch return error.InvalidConnectorJwe;
    defer allocator.free(ciphertext);
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer {
        std.crypto.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }
    Aes256Gcm.decrypt(plaintext, ciphertext, tag, parts[0], nonce, key) catch return error.InvalidConnectorJwe;
    return plaintext;
}

fn deriveEcdhEsKey(shared: [32]u8) [32]u8 {
    const algorithm = "A256GCM";
    var input: [4 + 32 + 4 + algorithm.len + 4 + 4 + 4]u8 = @splat(0);
    std.mem.writeInt(u32, input[0..4], 1, .big);
    @memcpy(input[4..36], &shared);
    std.mem.writeInt(u32, input[36..40], algorithm.len, .big);
    @memcpy(input[40 .. 40 + algorithm.len], algorithm);
    const supp_pub_offset = 40 + algorithm.len + 8;
    std.mem.writeInt(u32, input[supp_pub_offset .. supp_pub_offset + 4], 256, .big);
    var key: [32]u8 = undefined;
    Sha256.hash(&input, &key, .{});
    return key;
}

fn findSigningJwk(jwks: []const PublicJwk, kid: []const u8) ?PublicJwk {
    for (jwks) |jwk| {
        if (std.mem.eql(u8, jwk.kid, kid) and std.mem.eql(u8, jwk.kty, "OKP") and
            std.mem.eql(u8, jwk.crv, "Ed25519") and
            (jwk.use == null or std.mem.eql(u8, jwk.use.?, "sig")) and
            (jwk.alg == null or std.mem.eql(u8, jwk.alg.?, "EdDSA"))) return jwk;
    }
    return null;
}

fn splitCompact(value: []const u8, comptime count: usize) ![count][]const u8 {
    var parts: [count][]const u8 = undefined;
    var iterator = std.mem.splitScalar(u8, value, '.');
    for (&parts) |*part| part.* = iterator.next() orelse return error.InvalidCompactJose;
    if (iterator.next() != null) return error.InvalidCompactJose;
    return parts;
}

fn decodeFixed(comptime size: usize, encoded: []const u8) ![size]u8 {
    var output: [size]u8 = undefined;
    const decoded_size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded);
    if (decoded_size != size) return error.InvalidBase64Length;
    try std.base64.url_safe_no_pad.Decoder.decode(&output, encoded);
    return output;
}

fn validPrefixedHex(value: []const u8, prefix: []const u8) bool {
    if (value.len != prefix.len + 32 or !std.mem.startsWith(u8, value, prefix)) return false;
    for (value[prefix.len..]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn validHex32(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
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

test "RFC 7638 runtime key thumbprints match public vectors" {
    const ed_public = try decodeFixed(32, "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo");
    const ed_thumbprint = try thumbprintAlloc(std.testing.allocator, "Ed25519", &ed_public);
    defer std.testing.allocator.free(ed_thumbprint);
    try std.testing.expectEqualStrings("kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k", ed_thumbprint);

    const x_public = try decodeFixed(32, "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo");
    const x_thumbprint = try thumbprintAlloc(std.testing.allocator, "X25519", &x_public);
    defer std.testing.allocator.free(x_thumbprint);
    try std.testing.expectEqualStrings("u809Vppx5ixWMOohxWr2aM3m5bD0LQ67g_GPmubQus4", x_thumbprint);
}

test "RFC 8785 canonical request digest matches the public vector" {
    const input =
        \\{"z":[3,{"b":true,"a":"é"}],"a":{"negative_zero":0,"text":"line\nfeed"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{});
    defer parsed.deinit();
    const digest = try stableDigestAlloc(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings("uSbozcVnxd-4lvMt6bCgX6EvatYkGkp8Lsy_Ac9auPg", digest);
}

test "runtime link Ed25519 compact proof matches the public vector" {
    var seed = try decodeFixed(32, "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A");
    defer std.crypto.secureZero(u8, &seed);
    var key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key_pair.secret_key));
    const expected = "eyJhbGciOiJFZERTQSIsImtpZCI6InRlc3QtcnVudGltZS1zaWduaW5nLXYxIiwidHlwIjoidmVyZGUtcnVudGltZS1saW5rK2p3dCJ9.eyJjb250cmFjdF92ZXJzaW9uIjoiMSIsImNoYWxsZW5nZV9pZCI6ImNobF8xMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMSIsInByaW5jaXBhbCI6eyJpc3N1ZXIiOiJodHRwczovL2lkLmV4YW1wbGUudGVzdCIsInN1YmplY3QiOiJ0ZXN0LXN1YmplY3QifSwicnVudGltZV9pZCI6IjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIiwiaW5zdGFuY2VfaWQiOiJhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OSIsInJ1bnRpbWVfa2V5X3RodW1icHJpbnQiOiJrUHJLX3FteFZXYVlWQTl3d0JGNkl1bzN2Vnp6N1R4SENUd1hCeWdyUzRrIiwicnVudGltZV9lbmNyeXB0aW9uX2tleV90aHVtYnByaW50IjoidTgwOVZwcHg1aXhXTU9vaHhXcjJhTTNtNWJEMExRNjdnX0dQbXViUXVzNCIsIm5vbmNlIjoiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsImlzcyI6InVybjp2ZXJkZTpydW50aW1lOjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIiwic3ViIjoiMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYiLCJhdWQiOiJodHRwczovL2Nvbm5lY3QuZXhhbXBsZS50ZXN0IiwianRpIjoiY2hsXzExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExIiwiaWF0IjoxODkzNDU2MDAwLCJuYmYiOjE4OTM0NTYwMDAsImV4cCI6MTg5MzQ1NjA5MH0.chErSoybDEfsVBC8UH5VHXwJ5SKhrs63psY9bMbvv6os3SgtYQrzlCSku7UADizikgSnbzBLj4e7_gYVG4loDg";
    const parts = try splitCompact(expected, 3);
    const payload = try base64UrlDecodeAlloc(std.testing.allocator, parts[1]);
    defer std.testing.allocator.free(payload);
    const actual = try signCompactAlloc(
        std.testing.allocator,
        &key_pair,
        "test-runtime-signing-v1",
        "verde-runtime-link+jwt",
        payload,
    );
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "connector credential JWE vector decrypts and rejects identity mismatch" {
    const private_key = try decodeFixed(32, "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo");
    const compact = "eyJhbGciOiJFQ0RILUVTIiwiZW5jIjoiQTI1NkdDTSIsInR5cCI6InZlcmRlLWNvbm5lY3QtY3JlZGVudGlhbCtqd2UiLCJraWQiOiJ0ZXN0LXJ1bnRpbWUtZW5jcnlwdGlvbi12MSIsImVucm9sbG1lbnRfaWQiOiJlbnJfNTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTUiLCJleHBpcmVzX2F0IjoiMjAzMC0wMS0wMVQwMDowMTozMC4wMDBaIiwiZXBrIjp7IngiOiJlTDMwQ3VMajVDdGdMSndrMTBXeDRPR1V0SXAzUlpDU1FWcmlkazlacVhFIiwiY3J2IjoiWDI1NTE5Iiwia3R5IjoiT0tQIn19..mupRMeWeH_dnnleP.fvjGqyMDUpiFSbmFP6543oj2dydH3DMG2dj0T4Bgqjo.q4tcyPVgg64zPQw_WZAbWw";
    const plaintext = try decryptConnectorJweAlloc(
        std.testing.allocator,
        compact,
        private_key,
        "test-runtime-encryption-v1",
        "enr_55555555555555555555555555555555",
        "2030-01-01T00:01:30.000Z",
    );
    defer {
        std.crypto.secureZero(u8, plaintext);
        std.testing.allocator.free(plaintext);
    }
    var expected: [32]u8 = undefined;
    for (&expected, 0..) |*byte, index| byte.* = @intCast(index);
    try std.testing.expectEqualSlices(u8, &expected, plaintext);
    try std.testing.expectError(error.InvalidConnectorJwe, decryptConnectorJweAlloc(
        std.testing.allocator,
        compact,
        private_key,
        "wrong-runtime-key",
        "enr_55555555555555555555555555555555",
        "2030-01-01T00:01:30.000Z",
    ));
}
