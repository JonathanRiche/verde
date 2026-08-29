//! Offline Verde Connect bootstrap-grant validation and atomic consumption.

const std = @import("std");
const zqlite = @import("zqlite");
const headless = @import("headless");

const crypto = @import("connect_crypto.zig");
const store = @import("connect_store.zig");
const access_store = @import("access_store.zig");

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

/// Validate every signed/bound claim, consume its replay keys, and issue a
/// runtime-local device verifier in one transaction.
pub fn consume(
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: zqlite.Conn,
    input: ConsumeInput,
    device_label: []const u8,
) !access_store.IssuedDevice {
    if (input.now_ms < 0) return error.InvalidBootstrapTime;
    try headless.access_protocol.validateDeviceLabel(device_label);
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
    const scope_mask = try headless.access_protocol.scopeMask(claims.scopes);
    try conn.execNoArgs("begin immediate");
    var transaction_open = true;
    defer if (transaction_open) conn.rollback();
    try store.consumeBootstrapLocked(
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
    var issued = try access_store.issueConnectDeviceLocked(io, conn, .{
        .connect_grant_id = claims.jti,
        .connect_device_id = claims.device_id,
        .device_key_thumbprint = claims.device_key_thumbprint,
        .issuer = input.expected_issuer,
        .device_label = device_label,
        .scope_mask = scope_mask,
        .now_ms = input.now_ms,
    });
    errdefer issued.clear();
    try conn.commit();
    transaction_open = false;
    return issued;
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
    try access_store.initialize(conn);
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
    var mismatch = base;
    mismatch.expected_issuer = "https://other.example.test";
    try std.testing.expectError(
        error.BootstrapIdentityMismatch,
        consume(std.testing.allocator, std.testing.io, conn, mismatch, "Wrong issuer"),
    );
    mismatch = base;
    mismatch.expected_audience = "https://other-runtime.example.test";
    try std.testing.expectError(
        error.BootstrapIdentityMismatch,
        consume(std.testing.allocator, std.testing.io, conn, mismatch, "Wrong audience"),
    );
    mismatch = base;
    mismatch.device_key_thumbprint = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try std.testing.expectError(
        error.BootstrapIdentityMismatch,
        consume(std.testing.allocator, std.testing.io, conn, mismatch, "Wrong key"),
    );
    var expired = base;
    expired.now_ms = 1_893_456_090_000;
    try std.testing.expectError(
        error.BootstrapGrantExpired,
        consume(std.testing.allocator, std.testing.io, conn, expired, "Expired"),
    );
    try conn.execNoArgs(
        \\create trigger reject_connect_device_for_test
        \\before insert on runtime_connect_devices
        \\begin select raise(abort, 'injected device insert failure'); end
    );
    try std.testing.expectError(
        error.ConstraintTrigger,
        consume(std.testing.allocator, std.testing.io, conn, base, "Connect laptop"),
    );
    try conn.execNoArgs("drop trigger reject_connect_device_for_test");
    // The failed post-validation insert rolled back grant consumption, so the
    // exact signed grant remains usable once durable issuance can succeed.
    var result = try consume(std.testing.allocator, std.testing.io, conn, base, "Connect laptop");
    defer result.clear();
    try std.testing.expectEqual(
        try headless.access_protocol.scopeMask(&.{ "runtime:read", "chat:write" }),
        result.scope_mask,
    );
    try std.testing.expectEqual(
        headless.access_protocol.scopeBit(.runtime_read),
        try access_store.authenticateDevice(
            conn,
            result.device_id[0..],
            result.device_credential[0..],
            &.{"runtime:read"},
            base.now_ms + 1,
        ),
    );
    try std.testing.expectError(
        error.ConnectBootstrapReplay,
        consume(std.testing.allocator, std.testing.io, conn, base, "Replay"),
    );
    var wrong = base;
    wrong.instance_id = "00000000000000000000000000000000";
    try std.testing.expectError(
        error.BootstrapIdentityMismatch,
        consume(std.testing.allocator, std.testing.io, conn, wrong, "Wrong identity"),
    );
    var devices = try access_store.listDevices(std.testing.allocator, conn, base.now_ms + 2);
    defer devices.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), devices.items.len);
    try std.testing.expectEqual(headless.access_protocol.DeviceSource.connect, devices.items[0].source);
    try std.testing.expectEqualStrings("grt_66666666666666666666666666666666", devices.items[0].source_id.?);
    try std.testing.expect(try access_store.revokeDevice(conn, result.device_id[0..], base.now_ms + 3));
    try std.testing.expectError(
        error.DeviceAuthenticationRejected,
        access_store.authenticateDevice(
            conn,
            result.device_id[0..],
            result.device_credential[0..],
            &.{"runtime:read"},
            base.now_ms + 4,
        ),
    );
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
