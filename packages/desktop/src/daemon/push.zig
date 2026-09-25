//! Durable, device-bound sealed push outbox. Call storage APIs under the store mutex;
//! network delivery must run without either the store or daemon mutex held.
const std = @import("std");
const builtin = @import("builtin");
const zqlite = @import("zqlite");
const headless = @import("headless");
const access_store = @import("access_store.zig");
const seal = headless.push_seal;

/// C-02 fills this in when the production relay deploys. Empty keeps rows queued.
pub const DEFAULT_RELAY_URL: []const u8 = "";
pub const MAX_PLAINTEXT_BYTES = 2560;
pub const MAX_ATTEMPTS = 8;
const MAX_RELAY_BODY_BYTES = 4096;
// Include JSON quotes/escaping: the worst-case envelope plus the 64-byte
// collapse id and these field separators must still fit one 4 KiB body.
const MAX_TOKEN_JSON_BYTES = MAX_RELAY_BODY_BYTES - seal.envelopeLen(MAX_PLAINTEXT_BYTES) - 64 - "{\"send_token\":,\"ciphertext\":\"\",\"collapse_id\":\"\"}".len;
const RETENTION_MS = 7 * std.time.ms_per_day;

pub fn validateRelayUrl(value: []const u8) !void {
    if (value.len == 0) return;
    if (value.len > 2048) return error.InvalidPushRelayUrl;
    for (value) |c| if (c < 0x21 or c > 0x7e or c == '\\') return error.InvalidPushRelayUrl;
    const uri = std.Uri.parse(value) catch return error.InvalidPushRelayUrl;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or
        (!uri.path.isEmpty() and !std.mem.eql(u8, uri.path.percent_encoded, "/"))) return error.InvalidPushRelayUrl;
}

/// Validate even when push is disabled: malformed config must never silently send elsewhere.
pub fn relayUrlFromConfig(root: std.json.Value) ![]const u8 {
    if (root != .object) return error.InvalidPushRelayUrl;
    const push = root.object.get("push") orelse return DEFAULT_RELAY_URL;
    if (push != .object) return error.InvalidPushRelayUrl;
    const url = push.object.get("relay_url") orelse return DEFAULT_RELAY_URL;
    if (url == .null) return DEFAULT_RELAY_URL;
    if (url != .string) return error.InvalidPushRelayUrl;
    try validateRelayUrl(url.string);
    return url.string;
}

pub fn initialize(conn: zqlite.Conn) !void {
    try conn.execNoArgs(
        \\create table if not exists device_push_registrations (
        \\ device_id text primary key, platform text not null, send_token text not null, public_key blob not null check(length(public_key)=32));
        \\create table if not exists device_push_outbox (
        \\ id integer primary key autoincrement, device_id text not null references device_push_registrations(device_id) on delete cascade,
        \\ kind text not null, dedupe_key text not null, sealed_payload text not null,
        \\ attempts integer not null default 0, next_attempt_at integer not null,
        \\ done integer not null default 0, created_at integer not null,
        \\ unique(device_id, kind, dedupe_key));
        \\create index if not exists device_push_due on device_push_outbox(done, next_attempt_at);
        \\create trigger if not exists device_push_revoke after update of revoked_at_ms on runtime_devices
        \\ when new.revoked_at_ms is not null begin delete from device_push_registrations where device_id = new.device_id; end;
        \\create trigger if not exists device_push_connect_revoke after update of revoked_at_ms on runtime_connect_devices
        \\ when new.revoked_at_ms is not null begin delete from device_push_registrations where device_id = new.device_id; end;
        \\create trigger if not exists device_push_delete after delete on runtime_devices
        \\ begin delete from device_push_registrations where device_id = old.device_id; end;
        \\create trigger if not exists device_push_connect_delete after delete on runtime_connect_devices
        \\ begin delete from device_push_registrations where device_id = old.device_id; end;
    );
}

pub fn register(conn: zqlite.Conn, allocator: std.mem.Allocator, io: std.Io, device_id: []const u8, platform: []const u8, token: []const u8, public_key: []const u8) !void {
    _ = try access_store.authorizeDevice(conn, device_id, &.{"device:write"});
    if ((!std.mem.eql(u8, platform, "android") and !std.mem.eql(u8, platform, "ios")) or token.len == 0 or token.len > MAX_TOKEN_JSON_BYTES - 2) return error.InvalidParams;
    for (token) |c| if (c < 0x21 or c > 0x7e) return error.InvalidParams;
    const encoded_token = try std.json.Stringify.valueAlloc(allocator, token, .{});
    defer {
        std.crypto.secureZero(u8, encoded_token);
        allocator.free(encoded_token);
    }
    if (encoded_token.len > MAX_TOKEN_JSON_BYTES) return error.InvalidParams;
    var key: [32]u8 = undefined;
    if (public_key.len != 43) return error.InvalidPublicKey;
    std.base64.url_safe_no_pad.Decoder.decode(&key, public_key) catch return error.InvalidPublicKey;
    var canonical: [43]u8 = undefined;
    if (!std.mem.eql(u8, std.base64.url_safe_no_pad.Encoder.encode(&canonical, &key), public_key)) return error.InvalidPublicKey;
    const probe = seal.seal(allocator, io, key, "") catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidPublicKey,
    };
    allocator.free(probe);
    if (try conn.row("select platform,send_token,public_key from device_push_registrations where device_id=?1", .{device_id})) |record| {
        var row = record;
        defer row.deinit();
        if (std.mem.eql(u8, row.text(0), platform) and std.mem.eql(u8, row.text(1), token) and std.mem.eql(u8, row.blob(2), &key)) return;
    }
    try conn.execNoArgs("begin immediate");
    errdefer conn.rollback();
    // Token/key rotation discards ciphertext sealed for the previous installation.
    try unregister(conn, device_id);
    try conn.exec("insert into device_push_registrations values (?1, ?2, ?3, ?4)", .{ device_id, platform, token, zqlite.blob(&key) });
    try conn.commit();
}

pub fn unregister(conn: zqlite.Conn, device_id: []const u8) !void {
    try conn.exec("delete from device_push_registrations where device_id = ?1", .{device_id});
}

pub const Payload = struct {
    runtime_id: []const u8,
    workspace_id: []const u8 = "",
    thread_id: []const u8 = "",
    turn_id: []const u8 = "",
    kind: []const u8,
    title: []const u8,
    snippet: []const u8 = "",
};

/// Trim whole UTF-8 codepoints, accounting for JSON escaping before sealing.
pub fn encodePayload(allocator: std.mem.Allocator, payload: Payload) ![]u8 {
    var bounded = payload;
    while (true) {
        const bytes = try std.json.Stringify.valueAlloc(allocator, bounded, .{});
        if (bytes.len <= MAX_PLAINTEXT_BYTES) return bytes;
        const excess = bytes.len - MAX_PLAINTEXT_BYTES;
        allocator.free(bytes);
        if (bounded.snippet.len > 0) bounded.snippet = trimBytes(bounded.snippet, excess) else if (bounded.title.len > 0) bounded.title = trimBytes(bounded.title, excess) else return error.PushPayloadTooLarge;
    }
}

fn trimBytes(value: []const u8, amount: usize) []const u8 {
    var end = value.len - @min(value.len, amount);
    while (end > 0 and value[end] & 0xc0 == 0x80) : (end -= 1) {}
    return value[0..end];
}

/// Returns false for a duplicate; retain the newest 4096 completed keys for up to seven days.
/// Caller may use an arena; no plaintext ever enters SQLite.
pub fn enqueue(conn: zqlite.Conn, allocator: std.mem.Allocator, io: std.Io, device_id: []const u8, dedupe_key: []const u8, payload: Payload, now_ms: i64) !bool {
    if (dedupe_key.len == 0 or dedupe_key.len > 256 or payload.kind.len == 0 or payload.kind.len > 64) return error.InvalidParams;
    try conn.exec("delete from device_push_outbox where done=1 and created_at < ?1", .{now_ms - RETENTION_MS});
    if (try conn.row("select id from device_push_outbox where device_id=?1 and kind=?2 and dedupe_key=?3", .{ device_id, payload.kind, dedupe_key })) |r| {
        var row = r;
        row.deinit();
        return false;
    }
    var count = (try conn.row("select count(*) from device_push_outbox where done=0", .{})).?;
    const full = count.int(0) >= 4096;
    count.deinit();
    if (full) return error.PushOutboxFull;
    var row = (try conn.row("select public_key from device_push_registrations where device_id=?1", .{device_id})) orelse return error.PushNotRegistered;
    const key: [32]u8 = row.blob(0)[0..32].*;
    row.deinit();
    const plaintext = try encodePayload(allocator, payload);
    defer {
        std.crypto.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }
    const ciphertext = try seal.seal(allocator, io, key, plaintext);
    defer allocator.free(ciphertext);
    try conn.exec("insert into device_push_outbox(device_id,kind,dedupe_key,sealed_payload,next_attempt_at,created_at) values(?1,?2,?3,?4,?5,?5)", .{ device_id, payload.kind, dedupe_key, ciphertext, now_ms });
    return true;
}

pub const Delivery = struct {
    id: i64,
    send_token: []const u8,
    ciphertext: []const u8,
    collapse_id: [64]u8,
};

/// Strings belong to the supplied arena. Called by the sole sender, under the store mutex.
pub fn next(conn: zqlite.Conn, arena: std.mem.Allocator, now_ms: i64) !?Delivery {
    var row = (try conn.row("select o.id,r.send_token,o.sealed_payload,o.kind,o.dedupe_key from device_push_outbox o join device_push_registrations r using(device_id) where o.done=0 and o.next_attempt_at<=?1 order by o.id limit 1", .{now_ms})) orelse return null;
    defer row.deinit();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(row.text(3));
    hash.update(&.{0});
    hash.update(row.text(4));
    const digest = hash.finalResult();
    return .{ .id = row.int(0), .send_token = try arena.dupe(u8, row.text(1)), .ciphertext = try arena.dupe(u8, row.text(2)), .collapse_id = std.fmt.bytesToHex(&digest, .lower) };
}

/// Null status is a transport failure. A stale response cannot delete a new registration.
pub fn complete(conn: zqlite.Conn, id: i64, status: ?u16, now_ms: i64) !void {
    if (status == 410) {
        try conn.exec("delete from device_push_registrations where device_id=(select device_id from device_push_outbox where id=?1)", .{id});
    } else if (status != null and status.? >= 200 and status.? < 300) {
        try conn.exec("update device_push_outbox set done=1, sealed_payload='' where id=?1", .{id});
        try conn.execNoArgs("delete from device_push_outbox where done=1 and id not in (select id from device_push_outbox where done=1 order by id desc limit 4096)");
    } else {
        var row = (try conn.row("select attempts from device_push_outbox where id=?1", .{id})) orelse return;
        const attempts = row.int(0) + 1;
        row.deinit();
        if (attempts >= MAX_ATTEMPTS) {
            try conn.exec("delete from device_push_outbox where id=?1", .{id});
        } else {
            const delay: i64 = @as(i64, 1000) << @as(u6, @intCast(attempts - 1));
            try conn.exec("update device_push_outbox set attempts=?2,next_attempt_at=?3 where id=?1", .{ id, attempts, now_ms + delay });
        }
    }
}

/// No redirects, proxies, response bodies, or secret logging. One finite five-second request.
pub fn send(allocator: std.mem.Allocator, base_url: []const u8, delivery: Delivery) !u16 {
    if (base_url.len == 0) return error.RelayNotConfigured;
    // Plain HTTP exists only in test binaries, for ephemeral loopback fixtures.
    if (!(builtin.is_test and std.mem.startsWith(u8, base_url, "http://127.0.0.1:"))) try validateRelayUrl(base_url);
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/send", .{std.mem.trimEnd(u8, base_url, "/")});
    defer allocator.free(url);
    const body = try std.json.Stringify.valueAlloc(allocator, .{ .send_token = delivery.send_token, .ciphertext = delivery.ciphertext, .collapse_id = &delivery.collapse_id }, .{});
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    if (body.len > MAX_RELAY_BODY_BYTES) return error.PushPayloadTooLarge;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
    defer client.deinit();
    const options: std.http.Client.FetchOptions = .{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    };
    const Result = union(enum) { fetch: std.http.Client.FetchError!std.http.Client.FetchResult, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(threaded.io(), &buffer);
    select.async(.fetch, std.http.Client.fetch, .{ &client, options });
    select.async(.timeout, std.Io.sleep, .{ threaded.io(), std.Io.Duration.fromMilliseconds(5000), .awake });
    defer select.cancelDiscard();
    return switch (try select.await()) {
        .fetch => |result| @intFromEnum((try result).status),
        .timeout => error.PushRelayTimeout,
    };
}

test "push relay config accepts only HTTPS base URLs or an unset value" {
    for ([_][]const u8{ "", "https://relay.example", "https://relay.example/", "https://127.0.0.1:8443" }) |url| try validateRelayUrl(url);
    for ([_][]const u8{ "http://127.0.0.1:8080", "https://user@relay.example", "https://relay.example/v1/send", "https://relay.example//", "https://relay.example?x", "https://relay.example#x", "https:///", "https://relay.example/\\x" }) |url| try std.testing.expectError(error.InvalidPushRelayUrl, validateRelayUrl(url));
    var json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"push\":{\"relay_url\":null}}", .{});
    defer json.deinit();
    try std.testing.expectEqualStrings("", try relayUrlFromConfig(json.value));
}

test "push payload truncates snippet then title with escaped UTF-8 inside budget" {
    const a = std.testing.allocator;
    const bytes = try encodePayload(a, .{ .runtime_id = "runtime", .kind = "done", .title = "é" ** 2000, .snippet = "\"\n" ** 2000 });
    defer a.free(bytes);
    try std.testing.expect(bytes.len <= MAX_PLAINTEXT_BYTES);
    var parsed = try std.json.parseFromSlice(Payload, a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", parsed.value.snippet);
    try std.testing.expect(std.unicode.utf8ValidateSlice(parsed.value.title));
    const key = seal.generateKeyPair(std.testing.io);
    const sealed = try seal.seal(a, std.testing.io, key.public_key, bytes);
    defer a.free(sealed);
    const opened = try seal.open(a, key.secret_key, sealed);
    defer a.free(opened);
    try std.testing.expectEqualStrings(bytes, opened);
    // Payload as delivered by APNs, including its fixed placeholder and collapse key.
    const wire = try std.json.Stringify.valueAlloc(a, .{ .aps = .{ .alert = "A Verde chat needs attention", .@"mutable-content" = 1 }, .ciphertext = sealed, .collapse_id = "0" ** 64 }, .{});
    defer a.free(wire);
    try std.testing.expect(wire.len < 4096);
}

const TestRelay = struct {
    listener: *std.Io.net.Server,
    status: std.http.Status,
    expected: Delivery,

    fn serve(self: TestRelay, io: std.Io) !void {
        const stream = try self.listener.accept(io);
        defer stream.close(io);
        var read_buf: [8192]u8 = undefined;
        var write_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var writer = stream.writer(io, &write_buf);
        var server: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        try std.testing.expectEqualStrings("/v1/send", request.head.target);
        try std.testing.expectEqual(std.http.Method.POST, request.head.method);
        var body_buf: [8192]u8 = undefined;
        const body = try request.readerExpectNone(&body_buf).allocRemaining(std.testing.allocator, .limited(8192));
        defer std.testing.allocator.free(body);
        var parsed = try std.json.parseFromSlice(struct { send_token: []const u8, ciphertext: []const u8, collapse_id: []const u8 }, std.testing.allocator, body, .{});
        defer parsed.deinit();
        // Do not include sensitive actual values in assertion output.
        try std.testing.expect(std.mem.eql(u8, self.expected.send_token, parsed.value.send_token));
        try std.testing.expect(std.mem.eql(u8, self.expected.ciphertext, parsed.value.ciphertext));
        try std.testing.expectEqualStrings(&self.expected.collapse_id, parsed.value.collapse_id);
        try request.respond("", .{ .status = self.status, .keep_alive = false });
    }
};

fn testDelivery(delivery: Delivery, status: std.http.Status) !u16 {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{listener.socket.address.getPort()});
    defer a.free(url);
    const fixture: TestRelay = .{ .listener = &listener, .status = status, .expected = delivery };
    const Result = union(enum) { served: anyerror!void, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    try select.concurrent(.served, TestRelay.serve, .{ fixture, io });
    select.async(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromMilliseconds(7000), .awake });
    defer select.cancelDiscard();
    const result = try send(a, url, delivery);
    switch (try select.await()) {
        .served => |served| try served,
        .timeout => return error.TestRelayTimeout,
    }
    return result;
}

/// Uses the real store and access grant flow, including migrations and revocation triggers.
pub fn createTestDevice(conn: zqlite.Conn) !access_store.IssuedDevice {
    const access = headless.access_protocol;
    var grant = try access_store.createPairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .label = "Push fixture",
        .ttl_seconds = 60,
        .scopes = &.{"device:write"},
    }, 1000);
    defer grant.clear();
    return access_store.exchangePairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .grant_id = &grant.grant_id,
        .pairing_token = .{ .bytes = &grant.pairing_token },
        .device_label = "Phone",
    }, 2000);
}

test "push outbox delivers through loopback retries dedupes survives reopen and clears on revoke or 410" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.join(a, &.{ path_buffer[0..path_len], "push.sqlite" });
    defer a.free(path);
    const Store = @import("store.zig").Store;
    var store = try Store.init(a, path);
    var store_open = true;
    defer if (store_open) store.deinit();
    var device = try createTestDevice(store.conn);
    defer device.clear();
    const key = seal.generateKeyPair(std.testing.io);
    var key_buffer: [43]u8 = undefined;
    const public_key = std.base64.url_safe_no_pad.Encoder.encode(&key_buffer, &key.public_key);
    try std.testing.expectError(error.InvalidPublicKey, register(store.conn, a, std.testing.io, &device.device_id, "android", "fixture-token", "A" ** 43));
    try std.testing.expectError(error.InvalidPublicKey, register(store.conn, a, std.testing.io, &device.device_id, "android", "fixture-token", "bad"));
    try register(store.conn, a, std.testing.io, &device.device_id, "android", "fixture-token", public_key);
    const payload: Payload = .{ .runtime_id = "fixture", .kind = "done", .title = "Test only" };
    try std.testing.expect(try enqueue(store.conn, a, std.testing.io, &device.device_id, "turn-1", payload, 3000));
    try std.testing.expect(!(try enqueue(store.conn, a, std.testing.io, &device.device_id, "turn-1", payload, 3000)));
    try register(store.conn, a, std.testing.io, &device.device_id, "android", "fixture-token", public_key);
    store.deinit();
    store_open = false;
    store = try Store.init(a, path);
    store_open = true;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const first = (try next(store.conn, arena.allocator(), 3000)).?;
    try std.testing.expectError(error.RelayNotConfigured, send(a, "", first));
    var row = (try store.conn.row("select attempts from device_push_outbox where id=?1", .{first.id})).?;
    try std.testing.expectEqual(@as(i64, 0), row.int(0));
    row.deinit();
    const plaintext = try seal.open(a, key.secret_key, first.ciphertext);
    defer a.free(plaintext);
    try std.testing.expect(std.mem.indexOf(u8, plaintext, "Test only") != null);
    try complete(store.conn, first.id, try testDelivery(first, .service_unavailable), 3000);
    try std.testing.expect(try next(store.conn, arena.allocator(), 3999) == null);
    const retry = (try next(store.conn, arena.allocator(), 4000)).?;
    try std.testing.expectEqual(first.id, retry.id);
    try complete(store.conn, retry.id, try testDelivery(retry, .ok), 4000);
    try std.testing.expect(try next(store.conn, arena.allocator(), 4000) == null);
    try std.testing.expect(!(try enqueue(store.conn, a, std.testing.io, &device.device_id, "turn-1", payload, 4001)));
    _ = try enqueue(store.conn, a, std.testing.io, &device.device_id, "turn-2", payload, 5000);
    const gone = (try next(store.conn, arena.allocator(), 5000)).?;
    try complete(store.conn, gone.id, try testDelivery(gone, .gone), 5000);
    try std.testing.expectError(error.PushNotRegistered, enqueue(store.conn, a, std.testing.io, &device.device_id, "turn-3", payload, 5000));
    try register(store.conn, a, std.testing.io, &device.device_id, "ios", "new-fixture-token", public_key);
    _ = try enqueue(store.conn, a, std.testing.io, &device.device_id, "turn-4", payload, 6000);
    const stale = (try next(store.conn, arena.allocator(), 6000)).?;
    try register(store.conn, a, std.testing.io, &device.device_id, "ios", "rotated-fixture-token", public_key);
    _ = try enqueue(store.conn, a, std.testing.io, &device.device_id, "turn-5", payload, 6000);
    try complete(store.conn, stale.id, 410, 6000);
    const current = (try next(store.conn, arena.allocator(), 6000)).?;
    for (0..MAX_ATTEMPTS) |_| try complete(store.conn, current.id, null, 6000);
    try std.testing.expect(try next(store.conn, arena.allocator(), 1_000_000) == null);
    _ = try enqueue(store.conn, a, std.testing.io, &device.device_id, "turn-6", payload, 7000);
    try std.testing.expect(try access_store.revokeDevice(store.conn, &device.device_id, 8000));
    try std.testing.expect(try next(store.conn, arena.allocator(), 9000) == null);
    try std.testing.expectError(error.DeviceAuthorizationRejected, register(store.conn, a, std.testing.io, &device.device_id, "ios", "fixture-token", public_key));
    try std.testing.expectError(error.PushNotRegistered, enqueue(store.conn, a, std.testing.io, &device.device_id, "turn-7", payload, 9000));
    var connected = try access_store.issueConnectDeviceLocked(std.testing.io, store.conn, .{
        .connect_grant_id = "push-connect-grant",
        .connect_device_id = "push-connect-phone",
        .device_key_thumbprint = "fixture-thumbprint",
        .issuer = "https://fixture.test",
        .device_label = "Connect phone",
        .scope_mask = headless.access_protocol.scopeBit(.device_write),
        .now_ms = 9000,
    });
    defer connected.clear();
    try register(store.conn, a, std.testing.io, &connected.device_id, "ios", "fixture-connect-token", public_key);
    _ = try enqueue(store.conn, a, std.testing.io, &connected.device_id, "connect-turn", payload, 9000);
    try std.testing.expect(try access_store.revokeDevice(store.conn, &connected.device_id, 10000));
    try std.testing.expect(try next(store.conn, arena.allocator(), 10000) == null);
    try std.testing.expectError(error.PushNotRegistered, enqueue(store.conn, a, std.testing.io, &connected.device_id, "connect-turn-2", payload, 10000));
}
