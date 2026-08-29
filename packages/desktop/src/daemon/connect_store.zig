//! Durable identity-bound Verde Connect intent, status, and grant replay store.

const std = @import("std");
const zqlite = @import("zqlite");
const headless = @import("headless");

const connect = headless.connect_protocol;

pub const State = struct {
    runtime_id: []u8,
    instance_id: []u8,
    desired_state: connect.DesiredState,
    lifecycle_state: connect.LifecycleState,
    control_plane_url: ?[]u8,
    issuer: ?[]u8,
    signer_jwks_json: ?[]u8,
    maximum_grant_lifetime_seconds: u16,
    link_id: ?[]u8,
    enrollment_id: ?[]u8,
    endpoint_https_url: ?[]u8,
    endpoint_wss_url: ?[]u8,
    connector_provider: ?[]u8,
    retry_attempt: u16,
    next_retry_at_ms: ?i64,
    last_error_code: ?[]u8,
    authenticated: bool,
    connector_running: bool,
    request_id: ?[]u8,
    updated_at_ms: i64,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_id);
        allocator.free(self.instance_id);
        freeOptional(allocator, self.control_plane_url);
        freeOptional(allocator, self.issuer);
        freeOptional(allocator, self.signer_jwks_json);
        freeOptional(allocator, self.link_id);
        freeOptional(allocator, self.enrollment_id);
        freeOptional(allocator, self.endpoint_https_url);
        freeOptional(allocator, self.endpoint_wss_url);
        freeOptional(allocator, self.connector_provider);
        freeOptional(allocator, self.last_error_code);
        freeOptional(allocator, self.request_id);
        self.* = undefined;
    }

    pub fn status(self: *const State) connect.StatusResult {
        return .{
            .connect_protocol_version = connect.CONNECT_PROTOCOL_VERSION,
            .runtime_id = self.runtime_id,
            .instance_id = self.instance_id,
            .desired_state = self.desired_state,
            .state = self.lifecycle_state,
            .control_plane_url = self.control_plane_url,
            .issuer = self.issuer,
            .link_id = self.link_id,
            .enrollment_id = self.enrollment_id,
            .endpoint_https_url = self.endpoint_https_url,
            .endpoint_wss_url = self.endpoint_wss_url,
            .connector_provider = self.connector_provider,
            .retry_attempt = self.retry_attempt,
            .next_retry_at_ms = self.next_retry_at_ms,
            .last_error_code = self.last_error_code,
            .authenticated = self.authenticated,
            .connector_running = self.connector_running,
        };
    }
};

pub const Linked = struct {
    link_id: []const u8,
    enrollment_id: []const u8,
    endpoint_https_url: []const u8,
    endpoint_wss_url: []const u8,
    connector_provider: []const u8,
};

pub fn initialize(conn: zqlite.Conn, runtime_id: []const u8, instance_id: []const u8) !void {
    try conn.execNoArgs(
        \\create table if not exists runtime_connect_state (
        \\    singleton integer primary key check (singleton = 1),
        \\    runtime_id text not null,
        \\    instance_id text not null,
        \\    desired_state text not null,
        \\    lifecycle_state text not null,
        \\    control_plane_url text,
        \\    issuer text,
        \\    signer_jwks_json text,
        \\    maximum_grant_lifetime_seconds integer not null,
        \\    link_id text,
        \\    enrollment_id text,
        \\    endpoint_https_url text,
        \\    endpoint_wss_url text,
        \\    connector_provider text,
        \\    retry_attempt integer not null,
        \\    next_retry_at_ms integer,
        \\    last_error_code text,
        \\    authenticated integer not null,
        \\    connector_running integer not null,
        \\    request_id text,
        \\    updated_at_ms integer not null
        \\)
    );
    try conn.execNoArgs(
        \\create table if not exists runtime_connect_bootstrap_consumptions (
        \\    grant_id text primary key,
        \\    client_nonce text not null unique,
        \\    runtime_id text not null,
        \\    instance_id text not null,
        \\    device_id text not null,
        \\    consumed_at_ms integer not null,
        \\    expires_at_ms integer not null
        \\)
    );
    if (try conn.row("select runtime_id, instance_id from runtime_connect_state where singleton = 1", .{})) |row_value| {
        var row = row_value;
        defer row.deinit();
        if (!std.mem.eql(u8, row.text(0), runtime_id) or !std.mem.eql(u8, row.text(1), instance_id)) {
            return error.ConnectIdentityMismatch;
        }
        return;
    }
    try conn.exec(
        \\insert into runtime_connect_state
        \\    (singleton, runtime_id, instance_id, desired_state, lifecycle_state,
        \\     retry_attempt, authenticated, connector_running,
        \\     maximum_grant_lifetime_seconds, updated_at_ms)
        \\values (1, ?1, ?2, 'unlinked', 'logged_out', 0, 0, 0, 300, 0)
    , .{ runtime_id, instance_id });
}

pub fn load(allocator: std.mem.Allocator, conn: zqlite.Conn) !State {
    var row = (try conn.row(
        \\select runtime_id, instance_id, desired_state, lifecycle_state,
        \\       control_plane_url, issuer, signer_jwks_json,
        \\       maximum_grant_lifetime_seconds, link_id, enrollment_id,
        \\       endpoint_https_url, endpoint_wss_url, connector_provider,
        \\       retry_attempt, next_retry_at_ms, last_error_code,
        \\       authenticated, connector_running, request_id, updated_at_ms
        \\from runtime_connect_state where singleton = 1
    , .{})) orelse return error.ConnectStateMissing;
    defer row.deinit();
    const maximum_lifetime = row.int(7);
    const retry = row.int(13);
    if (maximum_lifetime < 15 or maximum_lifetime > 300) return error.ConnectStateCorrupt;
    if (retry < 0 or retry > std.math.maxInt(u16)) return error.ConnectStateCorrupt;
    return .{
        .runtime_id = try allocator.dupe(u8, row.text(0)),
        .instance_id = try allocator.dupe(u8, row.text(1)),
        .desired_state = parseDesired(row.text(2)) catch return error.ConnectStateCorrupt,
        .lifecycle_state = parseLifecycle(row.text(3)) catch return error.ConnectStateCorrupt,
        .control_plane_url = try dupeNullable(allocator, &row, 4),
        .issuer = try dupeNullable(allocator, &row, 5),
        .signer_jwks_json = try dupeNullable(allocator, &row, 6),
        .maximum_grant_lifetime_seconds = @intCast(maximum_lifetime),
        .link_id = try dupeNullable(allocator, &row, 8),
        .enrollment_id = try dupeNullable(allocator, &row, 9),
        .endpoint_https_url = try dupeNullable(allocator, &row, 10),
        .endpoint_wss_url = try dupeNullable(allocator, &row, 11),
        .connector_provider = try dupeNullable(allocator, &row, 12),
        .retry_attempt = @intCast(retry),
        .next_retry_at_ms = row.nullableInt(14),
        .last_error_code = try dupeNullable(allocator, &row, 15),
        .authenticated = row.int(16) == 1,
        .connector_running = row.int(17) == 1,
        .request_id = try dupeNullable(allocator, &row, 18),
        .updated_at_ms = row.int(19),
    };
}

pub fn recordLogin(
    conn: zqlite.Conn,
    control_plane_url: []const u8,
    issuer: []const u8,
    signer_jwks_json: []const u8,
    maximum_grant_lifetime_seconds: u16,
    now_ms: i64,
) !void {
    var state = try load(std.heap.page_allocator, conn);
    defer state.deinit(std.heap.page_allocator);
    if (state.desired_state == .linked and state.control_plane_url != null and
        !std.mem.eql(u8, state.control_plane_url.?, control_plane_url)) return error.ConnectAlreadyLinked;
    try conn.exec(
        \\update runtime_connect_state
        \\set control_plane_url = ?1, issuer = ?2, signer_jwks_json = ?3,
        \\    maximum_grant_lifetime_seconds = ?4, authenticated = 1,
        \\    lifecycle_state = case when desired_state = 'linked' then lifecycle_state else 'logged_in' end,
        \\    last_error_code = null, updated_at_ms = ?5
        \\where singleton = 1
    , .{ control_plane_url, issuer, signer_jwks_json, maximum_grant_lifetime_seconds, now_ms });
}

pub fn beginLink(conn: zqlite.Conn, request_id: []const u8, provider: []const u8, now_ms: i64) !void {
    try conn.execNoArgs("begin immediate");
    errdefer conn.rollback();
    var row = (try conn.row(
        "select authenticated, desired_state from runtime_connect_state where singleton = 1",
        .{},
    )).?;
    const authenticated = row.int(0) == 1;
    row.deinit();
    if (!authenticated) return error.ConnectLoginRequired;
    try conn.exec(
        \\update runtime_connect_state
        \\set desired_state = 'linked', lifecycle_state = 'linking', request_id = ?1,
        \\    connector_provider = ?2, connector_running = 0, retry_attempt = 0,
        \\    next_retry_at_ms = null, last_error_code = null, updated_at_ms = ?3
        \\where singleton = 1
    , .{ request_id, provider, now_ms });
    try conn.commit();
}

pub fn recordLinked(conn: zqlite.Conn, linked: Linked, connector_running: bool, now_ms: i64) !void {
    try conn.exec(
        \\update runtime_connect_state
        \\set desired_state = 'linked', lifecycle_state = 'linked', link_id = ?1,
        \\    enrollment_id = ?2, endpoint_https_url = ?3, endpoint_wss_url = ?4,
        \\    connector_provider = ?5, connector_running = ?6, retry_attempt = 0,
        \\    next_retry_at_ms = null, last_error_code = null, updated_at_ms = ?7
        \\where singleton = 1
    , .{ linked.link_id, linked.enrollment_id, linked.endpoint_https_url, linked.endpoint_wss_url, linked.connector_provider, @intFromBool(connector_running), now_ms });
}

pub fn recordRetry(conn: zqlite.Conn, error_code: []const u8, attempt: u16, next_retry_at_ms: i64, now_ms: i64) !void {
    try conn.exec(
        \\update runtime_connect_state
        \\set lifecycle_state = 'retry_wait', connector_running = 0, retry_attempt = ?1,
        \\    next_retry_at_ms = ?2, last_error_code = ?3, updated_at_ms = ?4
        \\where singleton = 1 and desired_state = 'linked'
    , .{ attempt, next_retry_at_ms, error_code, now_ms });
}

pub fn beginUnlink(conn: zqlite.Conn, now_ms: i64) !void {
    try conn.exec(
        \\update runtime_connect_state
        \\set desired_state = 'unlinked', lifecycle_state = 'unlinking',
        \\    connector_running = 0, retry_attempt = 0, next_retry_at_ms = null,
        \\    last_error_code = null, updated_at_ms = ?1
        \\where singleton = 1
    , .{now_ms});
}

pub fn recordUnlinked(conn: zqlite.Conn, now_ms: i64) !void {
    try conn.exec(
        \\update runtime_connect_state
        \\set desired_state = 'unlinked', lifecycle_state = case when authenticated = 1 then 'logged_in' else 'logged_out' end,
        \\    link_id = null, enrollment_id = null, endpoint_https_url = null,
        \\    endpoint_wss_url = null, connector_provider = null,
        \\    connector_running = 0, retry_attempt = 0,
        \\    next_retry_at_ms = null, last_error_code = null, request_id = null,
        \\    updated_at_ms = ?1 where singleton = 1
    , .{now_ms});
}

pub fn recordLogout(conn: zqlite.Conn, now_ms: i64) !void {
    try conn.exec(
        \\update runtime_connect_state
        \\set desired_state = 'unlinked', lifecycle_state = 'logged_out',
        \\    control_plane_url = null, issuer = null,
        \\    signer_jwks_json = null, maximum_grant_lifetime_seconds = 300,
        \\    link_id = null, enrollment_id = null, endpoint_https_url = null,
        \\    endpoint_wss_url = null, connector_provider = null, request_id = null,
        \\    authenticated = 0, connector_running = 0, retry_attempt = 0,
        \\    next_retry_at_ms = null, last_error_code = null, updated_at_ms = ?1
        \\where singleton = 1
    , .{now_ms});
}

pub fn consumeBootstrap(
    conn: zqlite.Conn,
    grant_id: []const u8,
    client_nonce: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    link_id: []const u8,
    issuer: []const u8,
    audience: []const u8,
    device_id: []const u8,
    consumed_at_ms: i64,
    expires_at_ms: i64,
) !void {
    try conn.execNoArgs("begin immediate");
    var transaction_open = true;
    defer if (transaction_open) conn.rollback();
    try consumeBootstrapLocked(
        conn,
        grant_id,
        client_nonce,
        runtime_id,
        instance_id,
        link_id,
        issuer,
        audience,
        device_id,
        consumed_at_ms,
        expires_at_ms,
    );
    try conn.commit();
    transaction_open = false;
}

/// Validate linked state and record one grant/nonce inside the caller's open
/// transaction. Used when device verifier issuance must share the commit.
pub fn consumeBootstrapLocked(
    conn: zqlite.Conn,
    grant_id: []const u8,
    client_nonce: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    link_id: []const u8,
    issuer: []const u8,
    audience: []const u8,
    device_id: []const u8,
    consumed_at_ms: i64,
    expires_at_ms: i64,
) !void {
    var identity = (try conn.row(
        \\select runtime_id, instance_id, desired_state, lifecycle_state,
        \\       link_id, issuer, endpoint_https_url
        \\from runtime_connect_state where singleton = 1
    , .{})).?;
    const matches = std.mem.eql(u8, identity.text(0), runtime_id) and
        std.mem.eql(u8, identity.text(1), instance_id);
    const linked = std.mem.eql(u8, identity.text(2), "linked") and
        std.mem.eql(u8, identity.text(3), "linked") and
        identity.nullableText(4) != null and std.mem.eql(u8, identity.nullableText(4).?, link_id) and
        identity.nullableText(5) != null and std.mem.eql(u8, identity.nullableText(5).?, issuer) and
        identity.nullableText(6) != null and std.mem.eql(u8, identity.nullableText(6).?, audience);
    identity.deinit();
    if (!matches) return error.ConnectIdentityMismatch;
    if (!linked) return error.ConnectLinkRequired;
    conn.exec(
        \\insert into runtime_connect_bootstrap_consumptions
        \\    (grant_id, client_nonce, runtime_id, instance_id, device_id, consumed_at_ms, expires_at_ms)
        \\values (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    , .{ grant_id, client_nonce, runtime_id, instance_id, device_id, consumed_at_ms, expires_at_ms }) catch
        return error.ConnectBootstrapReplay;
    try conn.exec(
        "delete from runtime_connect_bootstrap_consumptions where expires_at_ms < ?1 and grant_id != ?2",
        .{ consumed_at_ms - 300_000, grant_id },
    );
}

fn parseDesired(value: []const u8) !connect.DesiredState {
    if (std.mem.eql(u8, value, "unlinked")) return .unlinked;
    if (std.mem.eql(u8, value, "linked")) return .linked;
    return error.InvalidState;
}

fn parseLifecycle(value: []const u8) !connect.LifecycleState {
    inline for (std.meta.tags(connect.LifecycleState)) |tag| {
        if (std.mem.eql(u8, value, @tagName(tag))) return tag;
    }
    return error.InvalidState;
}

fn dupeNullable(allocator: std.mem.Allocator, row: anytype, index: usize) !?[]u8 {
    const value = row.nullableText(index) orelse return null;
    return try allocator.dupe(u8, value);
}

fn freeOptional(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |bytes| allocator.free(bytes);
}

fn openTestStore(tmp: *std.testing.TmpDir) !zqlite.Conn {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ buffer[0..length], "connect.sqlite" });
    defer std.testing.allocator.free(path);
    return zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
}

test "Connect state is identity-bound and unlink survives restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime_id = "0123456789abcdef0123456789abcdef";
    const instance_id = "abcdef0123456789abcdef0123456789";
    var conn = try openTestStore(&tmp);
    try initialize(conn, runtime_id, instance_id);
    try recordLogin(conn, "https://connect.example.test", "https://connect.example.test", "{\"keys\":[]}", 300, 1);
    try beginLink(conn, "req_11111111111111111111111111111111", "external", 2);
    try recordLinked(conn, .{
        .link_id = "lnk_22222222222222222222222222222222",
        .enrollment_id = "enr_33333333333333333333333333333333",
        .endpoint_https_url = "https://runtime.example.test",
        .endpoint_wss_url = "wss://runtime.example.test/v1/ws",
        .connector_provider = "external",
    }, false, 3);
    try recordUnlinked(conn, 4);
    conn.close();

    conn = try openTestStore(&tmp);
    defer conn.close();
    try initialize(conn, runtime_id, instance_id);
    var state = try load(std.testing.allocator, conn);
    defer state.deinit(std.testing.allocator);
    try std.testing.expectEqual(connect.DesiredState.unlinked, state.desired_state);
    try std.testing.expect(state.authenticated);
    try std.testing.expectEqual(connect.LifecycleState.logged_in, state.lifecycle_state);
    try std.testing.expectEqual(@as(?[]u8, null), state.connector_provider);
    try std.testing.expectError(
        error.ConnectIdentityMismatch,
        initialize(conn, runtime_id, "00000000000000000000000000000000"),
    );
}

test "bootstrap grant ID and nonce are consumed atomically once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime_id = "0123456789abcdef0123456789abcdef";
    const instance_id = "abcdef0123456789abcdef0123456789";
    const conn = try openTestStore(&tmp);
    defer conn.close();
    try initialize(conn, runtime_id, instance_id);
    try recordLogin(conn, "https://connect.example.test", "https://connect.example.test", "{\"keys\":[]}", 300, 1);
    try beginLink(conn, "req_99999999999999999999999999999999", "external", 2);
    try recordLinked(conn, .{
        .link_id = "lnk_99999999999999999999999999999999",
        .enrollment_id = "enr_99999999999999999999999999999999",
        .endpoint_https_url = "https://runtime.example.test",
        .endpoint_wss_url = "wss://runtime.example.test/v1/ws",
        .connector_provider = "external",
    }, false, 3);
    try consumeBootstrap(conn, "grt_11111111111111111111111111111111", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", runtime_id, instance_id, "lnk_99999999999999999999999999999999", "https://connect.example.test", "https://runtime.example.test", "dev_22222222222222222222222222222222", 1_000, 90_000);
    try std.testing.expectError(error.ConnectBootstrapReplay, consumeBootstrap(conn, "grt_11111111111111111111111111111111", "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", runtime_id, instance_id, "lnk_99999999999999999999999999999999", "https://connect.example.test", "https://runtime.example.test", "dev_22222222222222222222222222222222", 1_001, 90_000));
    try std.testing.expectError(error.ConnectBootstrapReplay, consumeBootstrap(conn, "grt_33333333333333333333333333333333", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", runtime_id, instance_id, "lnk_99999999999999999999999999999999", "https://connect.example.test", "https://runtime.example.test", "dev_22222222222222222222222222222222", 1_002, 90_000));
    try beginUnlink(conn, 4);
    try std.testing.expectError(error.ConnectLinkRequired, consumeBootstrap(conn, "grt_44444444444444444444444444444444", "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", runtime_id, instance_id, "lnk_99999999999999999999999999999999", "https://connect.example.test", "https://runtime.example.test", "dev_22222222222222222222222222222222", 1_003, 90_000));
}
