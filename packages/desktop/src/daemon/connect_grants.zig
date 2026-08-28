//! Offline Verde Connect bootstrap-grant validation and atomic consumption.

const std = @import("std");
const zqlite = @import("zqlite");
const headless = @import("headless");

const crypto = @import("connect_crypto.zig");
const store = @import("connect_store.zig");

pub const ConsumeInput = struct {
    compact_jwt: []const u8,
    jwks: []const crypto.PublicJwk,
    expected_issuer: []const u8,
    expected_audience: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    device_id: []const u8,
    device_key_thumbprint: []const u8,
    client_nonce: []const u8,
    now_ms: i64,
    maximum_lifetime_seconds: i64 = 300,
};

pub const Result = struct {
    grant_id: []u8,
    device_id: []u8,
    scopes: [][]const u8,
    expires_at_ms: i64,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.grant_id);
        allocator.free(self.device_id);
        for (self.scopes) |scope| allocator.free(scope);
        allocator.free(self.scopes);
        self.* = undefined;
    }
};

/// Validate every signed/bound claim before atomically recording both grant
/// ID and client nonce. Only after the insert commits may a caller mint local
/// Pair/access material for the device.
pub fn consume(
    allocator: std.mem.Allocator,
    conn: zqlite.Conn,
    input: ConsumeInput,
) !Result {
    if (input.now_ms < 0) return error.InvalidBootstrapTime;
    var verified = try crypto.verifyBootstrapGrant(allocator, input.compact_jwt, input.jwks, .{
        .issuer = input.expected_issuer,
        .audience = input.expected_audience,
        .runtime_id = input.runtime_id,
        .instance_id = input.instance_id,
        .device_id = input.device_id,
        .device_key_thumbprint = input.device_key_thumbprint,
        .client_nonce = input.client_nonce,
        .now_seconds = @divFloor(input.now_ms, 1000),
        .maximum_lifetime_seconds = input.maximum_lifetime_seconds,
    });
    defer verified.deinit();
    const claims = verified.claims();
    const expires_at_ms = std.math.mul(i64, claims.exp, 1000) catch return error.InvalidBootstrapTime;
    try store.consumeBootstrap(
        conn,
        claims.jti,
        claims.client_nonce,
        claims.runtime_id,
        claims.instance_id,
        claims.link_id,
        input.expected_issuer,
        input.expected_audience,
        claims.device_id,
        input.now_ms,
        expires_at_ms,
    );
    const scopes = try allocator.alloc([]const u8, claims.scopes.len);
    errdefer allocator.free(scopes);
    var initialized: usize = 0;
    errdefer for (scopes[0..initialized]) |scope| allocator.free(scope);
    for (claims.scopes, scopes) |scope, *owned| {
        owned.* = try allocator.dupe(u8, scope);
        initialized += 1;
    }
    const grant_id = try allocator.dupe(u8, claims.jti);
    errdefer allocator.free(grant_id);
    return .{
        .grant_id = grant_id,
        .device_id = try allocator.dupe(u8, claims.device_id),
        .scopes = scopes,
        .expires_at_ms = expires_at_ms,
    };
}

fn openTestStore(tmp: *std.testing.TmpDir) !zqlite.Conn {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ buffer[0..length], "grants.sqlite" });
    defer std.testing.allocator.free(path);
    return zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
}

test "public bootstrap vector validates once and fails closed on identity or replay" {
    const runtime_id = "0123456789abcdef0123456789abcdef";
    const instance_id = "abcdef0123456789abcdef0123456789";
    const device_id = "dev_33333333333333333333333333333333";
    const nonce = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const thumbprint = "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k";
    const jwt = "eyJhbGciOiJFZERTQSIsImtpZCI6InRlc3QtcnVudGltZS1zaWduaW5nLXYxIiwidHlwIjoidmVyZGUtY29ubmVjdC1ib290c3RyYXArand0In0.eyJjb250cmFjdF92ZXJzaW9uIjoiMSIsInByaW5jaXBhbCI6eyJpc3N1ZXIiOiJodHRwczovL2lkLmV4YW1wbGUudGVzdCIsInN1YmplY3QiOiJ0ZXN0LXN1YmplY3QifSwibGlua19pZCI6Imxua180NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NCIsInJ1bnRpbWVfaWQiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZiIsImluc3RhbmNlX2lkIjoiYWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODkiLCJkZXZpY2VfaWQiOiJkZXZfMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMiLCJkZXZpY2Vfa2V5X3RodW1icHJpbnQiOiJrUHJLX3FteFZXYVlWQTl3d0JGNkl1bzN2Vnp6N1R4SENUd1hCeWdyUzRrIiwiY2xpZW50X25vbmNlIjoiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsInJlcXVlc3RfaWQiOiJyZXFfMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIiLCJzY29wZXMiOlsicnVudGltZTpyZWFkIiwiY2hhdDp3cml0ZSJdLCJpc3MiOiJodHRwczovL2Nvbm5lY3QuZXhhbXBsZS50ZXN0Iiwic3ViIjoiaHR0cHM6Ly9pZC5leGFtcGxlLnRlc3RcdTAwMDB0ZXN0LXN1YmplY3QiLCJhdWQiOiJodHRwczovL3J1bnRpbWUuZXhhbXBsZS50ZXN0IiwianRpIjoiZ3J0XzY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2IiwiaWF0IjoxODkzNDU2MDAwLCJuYmYiOjE4OTM0NTYwMDAsImV4cCI6MTg5MzQ1NjA5MH0.N1mVArVXRAQ0DM8Mn-_uMB3WLRKuEwGvtS66xkrbmMaialYRCntcDmpjPsRoj-SuD_LfcHhJlLb5YNManLeOAA";
    const jwks = [_]crypto.PublicJwk{.{
        .kty = "OKP",
        .crv = "Ed25519",
        .x = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
        .kid = "test-runtime-signing-v1",
        .use = "sig",
        .alg = "EdDSA",
    }};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const conn = try openTestStore(&tmp);
    defer conn.close();
    try store.initialize(conn, runtime_id, instance_id);
    try store.recordLogin(conn, "https://connect.example.test", "https://connect.example.test", "{\"keys\":[]}", 300, 1);
    try store.beginLink(conn, "req_11111111111111111111111111111111", "external", 2);
    try store.recordLinked(conn, .{
        .link_id = "lnk_44444444444444444444444444444444",
        .enrollment_id = "enr_55555555555555555555555555555555",
        .endpoint_https_url = "https://runtime.example.test",
        .endpoint_wss_url = "wss://runtime.example.test/v1/ws",
        .connector_provider = "external",
    }, false, 3);
    const base: ConsumeInput = .{
        .compact_jwt = jwt,
        .jwks = &jwks,
        .expected_issuer = "https://connect.example.test",
        .expected_audience = "https://runtime.example.test",
        .runtime_id = runtime_id,
        .instance_id = instance_id,
        .device_id = device_id,
        .device_key_thumbprint = thumbprint,
        .client_nonce = nonce,
        .now_ms = 1_893_456_000_000,
    };
    var result = try consume(std.testing.allocator, conn, base);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("grt_66666666666666666666666666666666", result.grant_id);
    try std.testing.expectEqual(@as(usize, 2), result.scopes.len);
    try std.testing.expectError(error.ConnectBootstrapReplay, consume(std.testing.allocator, conn, base));
    var wrong = base;
    wrong.instance_id = "00000000000000000000000000000000";
    try std.testing.expectError(error.BootstrapIdentityMismatch, consume(std.testing.allocator, conn, wrong));
}

test "signer rotation accepts retained keys but rejects unknown kid" {
    const jwt = "eyJhbGciOiJFZERTQSIsImtpZCI6InRlc3QtcnVudGltZS1zaWduaW5nLXYxIiwidHlwIjoidmVyZGUtY29ubmVjdC1ib290c3RyYXArand0In0.eyJjb250cmFjdF92ZXJzaW9uIjoiMSIsInByaW5jaXBhbCI6eyJpc3N1ZXIiOiJodHRwczovL2lkLmV4YW1wbGUudGVzdCIsInN1YmplY3QiOiJ0ZXN0LXN1YmplY3QifSwibGlua19pZCI6Imxua180NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NCIsInJ1bnRpbWVfaWQiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZiIsImluc3RhbmNlX2lkIjoiYWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODkiLCJkZXZpY2VfaWQiOiJkZXZfMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMiLCJkZXZpY2Vfa2V5X3RodW1icHJpbnQiOiJrUHJLX3FteFZXYVlWQTl3d0JGNkl1bzN2Vnp6N1R4SENUd1hCeWdyUzRrIiwiY2xpZW50X25vbmNlIjoiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsInJlcXVlc3RfaWQiOiJyZXFfMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIiLCJzY29wZXMiOlsicnVudGltZTpyZWFkIiwiY2hhdDp3cml0ZSJdLCJpc3MiOiJodHRwczovL2Nvbm5lY3QuZXhhbXBsZS50ZXN0Iiwic3ViIjoiaHR0cHM6Ly9pZC5leGFtcGxlLnRlc3RcdTAwMDB0ZXN0LXN1YmplY3QiLCJhdWQiOiJodHRwczovL3J1bnRpbWUuZXhhbXBsZS50ZXN0IiwianRpIjoiZ3J0XzY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2IiwiaWF0IjoxODkzNDU2MDAwLCJuYmYiOjE4OTM0NTYwMDAsImV4cCI6MTg5MzQ1NjA5MH0.N1mVArVXRAQ0DM8Mn-_uMB3WLRKuEwGvtS66xkrbmMaialYRCntcDmpjPsRoj-SuD_LfcHhJlLb5YNManLeOAA";
    const unknown = [_]crypto.PublicJwk{.{ .kty = "OKP", .crv = "Ed25519", .x = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo", .kid = "different-signing-key" }};
    try std.testing.expectError(error.UnknownBootstrapKey, crypto.verifyBootstrapGrant(std.testing.allocator, jwt, &unknown, .{
        .issuer = "https://connect.example.test",
        .audience = "https://runtime.example.test",
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .instance_id = "abcdef0123456789abcdef0123456789",
        .device_id = "dev_33333333333333333333333333333333",
        .device_key_thumbprint = "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k",
        .client_nonce = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        .now_seconds = 1_893_456_000,
    }));
}
