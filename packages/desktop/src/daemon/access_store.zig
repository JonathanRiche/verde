//! Durable, daemon-owned pairing grants and scoped device verifiers.
//!
//! The tables live in the runtime's identity-bound `state.sqlite`. Raw grant
//! tokens and device credentials are returned once, zeroed by their owners,
//! and never enter SQLite or this module's logs.

const std = @import("std");
const zqlite = @import("zqlite");
const headless = @import("headless");

const access = headless.access_protocol;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

const GRANT_VERIFIER_DOMAIN: []const u8 = "verde-pairing-grant-v1";
const DEVICE_VERIFIER_DOMAIN: []const u8 = "verde-device-credential-v1";
const BUSY_TIMEOUT_MS: u32 = 2_000;
pub const DEFAULT_RETENTION_MS: i64 = 30 * std.time.ms_per_day;
pub const MAX_ACTIVE_PAIRING_GRANTS: i64 = 32;
pub const MAX_RETAINED_PAIRING_GRANTS: i64 = 4096;
pub const MAX_ACTIVE_DEVICES: i64 = 256;
pub const MAX_RETAINED_DEVICES: i64 = 1024;

pub const PruneResult = struct {
    grants_removed: usize,
    devices_removed: usize,
};

/// Create the identity-bound access tables without advertising a network
/// capability. Public exchange is enabled only when the gateway enforcement
/// slice is installed as a whole.
pub fn initialize(conn: zqlite.Conn) !void {
    try conn.execNoArgs(
        \\create table if not exists runtime_pairing_grants (
        \\    grant_id text primary key check(length(grant_id) = 32),
        \\    verifier blob not null check(length(verifier) = 32),
        \\    label text,
        \\    scopes integer not null check(scopes > 0 and scopes <= 255),
        \\    created_at_ms integer not null,
        \\    expires_at_ms integer not null,
        \\    consumed_at_ms integer,
        \\    revoked_at_ms integer
        \\);
        \\create table if not exists runtime_devices (
        \\    device_id text primary key check(length(device_id) = 32),
        \\    grant_id text not null unique references runtime_pairing_grants(grant_id),
        \\    credential_verifier blob not null check(length(credential_verifier) = 32),
        \\    label text not null,
        \\    scopes integer not null check(scopes > 0 and scopes <= 255),
        \\    created_at_ms integer not null,
        \\    last_used_at_ms integer,
        \\    revoked_at_ms integer
        \\);
        \\create index if not exists runtime_pairing_grants_created
        \\    on runtime_pairing_grants(created_at_ms desc);
        \\create index if not exists runtime_devices_created
        \\    on runtime_devices(created_at_ms desc);
    );
}

/// Raw grant material issued exactly once to a local administrator.
pub const IssuedPairingGrant = struct {
    grant_id: [access.GRANT_ID_HEX_BYTES]u8,
    pairing_token: [access.SECRET_HEX_BYTES]u8,
    expires_at_ms: i64,
    scope_mask: u16,

    pub fn clear(self: *IssuedPairingGrant) void {
        std.crypto.secureZero(u8, self.pairing_token[0..]);
        self.* = undefined;
    }

    pub fn toProtocol(
        self: *const IssuedPairingGrant,
        runtime_id: []const u8,
        instance_id: []const u8,
        scope_names: []const []const u8,
    ) access.PairingGrantCreateResult {
        return .{
            .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
            .runtime_id = runtime_id,
            .instance_id = instance_id,
            .grant_id = self.grant_id[0..],
            .pairing_token = .{ .bytes = self.pairing_token[0..] },
            .expires_at_ms = self.expires_at_ms,
            .scopes = scope_names,
        };
    }
};

/// Device credential returned exactly once after an atomic grant exchange.
pub const IssuedDevice = struct {
    device_id: [access.DEVICE_ID_HEX_BYTES]u8,
    device_credential: [access.SECRET_HEX_BYTES]u8,
    scope_mask: u16,

    pub fn clear(self: *IssuedDevice) void {
        std.crypto.secureZero(u8, self.device_credential[0..]);
        self.* = undefined;
    }

    pub fn toProtocol(
        self: *const IssuedDevice,
        runtime_id: []const u8,
        instance_id: []const u8,
        scope_names: []const []const u8,
    ) access.PairingGrantExchangeResult {
        return .{
            .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
            .runtime_id = runtime_id,
            .instance_id = instance_id,
            .device_id = self.device_id[0..],
            .device_credential = .{ .bytes = self.device_credential[0..] },
            .scopes = scope_names,
        };
    }
};

pub const OwnedPairingGrant = struct {
    grant_id: []u8,
    label: ?[]u8,
    scope_mask: u16,
    created_at_ms: i64,
    expires_at_ms: i64,
    consumed_at_ms: ?i64,
    revoked_at_ms: ?i64,

    pub fn deinit(self: *OwnedPairingGrant, allocator: std.mem.Allocator) void {
        allocator.free(self.grant_id);
        if (self.label) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const OwnedPairingGrantList = struct {
    items: []OwnedPairingGrant,

    pub fn deinit(self: *OwnedPairingGrantList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const OwnedDevice = struct {
    device_id: []u8,
    grant_id: []u8,
    label: []u8,
    scope_mask: u16,
    created_at_ms: i64,
    last_used_at_ms: ?i64,
    revoked_at_ms: ?i64,

    pub fn deinit(self: *OwnedDevice, allocator: std.mem.Allocator) void {
        allocator.free(self.device_id);
        allocator.free(self.grant_id);
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const OwnedDeviceList = struct {
    items: []OwnedDevice,

    pub fn deinit(self: *OwnedDeviceList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Create a short-lived grant and persist only its domain-separated digest.
pub fn createPairingGrant(
    io: std.Io,
    conn: zqlite.Conn,
    request: access.PairingGrantCreateRequest,
    now_ms: i64,
) !IssuedPairingGrant {
    try validateNow(now_ms);
    if (request.access_protocol_version != access.ACCESS_PROTOCOL_VERSION) {
        return error.IncompatibleAccessProtocol;
    }
    try access.validatePairingTtl(request.ttl_seconds);
    if (request.label) |label| try access.validateDeviceLabel(label);
    const scope_mask = try access.scopeMask(request.scopes);

    var issued: IssuedPairingGrant = .{
        .grant_id = try secureHex(access.GRANT_ID_BYTES, io),
        .pairing_token = try secureHex(access.SECRET_BYTES, io),
        .expires_at_ms = saturatingAdd(now_ms, @as(i64, request.ttl_seconds) * 1000),
        .scope_mask = scope_mask,
    };
    errdefer issued.clear();
    var verifier = secretVerifier(
        GRANT_VERIFIER_DOMAIN,
        issued.grant_id[0..],
        issued.pairing_token[0..],
    );
    defer std.crypto.secureZero(u8, verifier[0..]);

    try conn.execNoArgs("begin immediate");
    var transaction_open = true;
    defer if (transaction_open) conn.rollback();
    _ = try pruneLockedToLimits(
        conn,
        now_ms,
        DEFAULT_RETENTION_MS,
        MAX_RETAINED_PAIRING_GRANTS - 1,
        MAX_RETAINED_DEVICES,
    );
    if (try countRows(conn, "runtime_pairing_grants") >= MAX_RETAINED_PAIRING_GRANTS) {
        return error.PairingGrantRetentionLimitReached;
    }
    var active_row = (try conn.row(
        \\select count(*) from runtime_pairing_grants
        \\where consumed_at_ms is null and revoked_at_ms is null and expires_at_ms > ?1
    , .{now_ms})).?;
    const active_count = active_row.int(0);
    active_row.deinit();
    if (active_count >= MAX_ACTIVE_PAIRING_GRANTS) return error.TooManyActivePairingGrants;

    try conn.exec(
        \\insert into runtime_pairing_grants
        \\    (grant_id, verifier, label, scopes, created_at_ms, expires_at_ms)
        \\values (?1, ?2, ?3, ?4, ?5, ?6)
    , .{
        issued.grant_id[0..],
        zqlite.blob(verifier[0..]),
        request.label,
        @as(i64, scope_mask),
        now_ms,
        issued.expires_at_ms,
    });
    try conn.commit();
    transaction_open = false;
    return issued;
}

/// Consume a valid grant exactly once and atomically persist a new device
/// verifier. Every invalid/expired/replayed grant returns the same error.
pub fn exchangePairingGrant(
    io: std.Io,
    conn: zqlite.Conn,
    request: access.PairingGrantExchangeRequest,
    now_ms: i64,
) !IssuedDevice {
    try validateNow(now_ms);
    if (request.access_protocol_version != access.ACCESS_PROTOCOL_VERSION) {
        return error.IncompatibleAccessProtocol;
    }
    access.validateGrantId(request.grant_id) catch return error.PairingGrantRejected;
    access.validateSecret(request.pairing_token.reveal()) catch return error.PairingGrantRejected;
    try access.validateDeviceLabel(request.device_label);

    try conn.execNoArgs("begin immediate");
    var transaction_open = true;
    defer if (transaction_open) conn.rollback();
    var row = (try conn.row(
        \\select verifier, scopes, expires_at_ms, consumed_at_ms, revoked_at_ms
        \\from runtime_pairing_grants where grant_id = ?1
    , .{request.grant_id})) orelse return error.PairingGrantRejected;

    const stored_verifier = row.blob(0);
    const scope_mask = checkedScopeMask(row.int(1)) catch {
        row.deinit();
        return error.AccessStoreCorrupt;
    };
    const expires_at_ms = row.int(2);
    const consumed_at_ms = row.nullableInt(3);
    const revoked_at_ms = row.nullableInt(4);
    var candidate = secretVerifier(
        GRANT_VERIFIER_DOMAIN,
        request.grant_id,
        request.pairing_token.reveal(),
    );
    defer std.crypto.secureZero(u8, candidate[0..]);
    if (stored_verifier.len != candidate.len or
        !std.crypto.timing_safe.eql(Digest, stored_verifier[0..@sizeOf(Digest)].*, candidate) or
        consumed_at_ms != null or revoked_at_ms != null or now_ms >= expires_at_ms)
    {
        row.deinit();
        return error.PairingGrantRejected;
    }
    row.deinit();

    // Capacity state is visible only after the one-time credential has been
    // proven. Invalid or replayed tokens retain one uniform rejection path and
    // cannot trigger retention maintenance.
    _ = try pruneLockedToLimits(
        conn,
        now_ms,
        DEFAULT_RETENTION_MS,
        MAX_RETAINED_PAIRING_GRANTS,
        MAX_RETAINED_DEVICES - 1,
    );
    if (try countRows(conn, "runtime_devices") >= MAX_RETAINED_DEVICES) {
        return error.DeviceRetentionLimitReached;
    }
    var active_devices_row = (try conn.row(
        "select count(*) from runtime_devices where revoked_at_ms is null",
        .{},
    )).?;
    const active_devices = active_devices_row.int(0);
    active_devices_row.deinit();
    if (active_devices >= MAX_ACTIVE_DEVICES) return error.TooManyActiveDevices;

    var issued: IssuedDevice = .{
        .device_id = try secureHex(access.DEVICE_ID_BYTES, io),
        .device_credential = try secureHex(access.SECRET_BYTES, io),
        .scope_mask = 0,
    };
    errdefer issued.clear();

    var device_verifier = secretVerifier(
        DEVICE_VERIFIER_DOMAIN,
        issued.device_id[0..],
        issued.device_credential[0..],
    );
    defer std.crypto.secureZero(u8, device_verifier[0..]);
    try conn.exec(
        \\insert into runtime_devices
        \\    (device_id, grant_id, credential_verifier, label, scopes, created_at_ms)
        \\values (?1, ?2, ?3, ?4, ?5, ?6)
    , .{
        issued.device_id[0..],
        request.grant_id,
        zqlite.blob(device_verifier[0..]),
        request.device_label,
        @as(i64, scope_mask),
        now_ms,
    });
    try conn.exec(
        \\update runtime_pairing_grants set consumed_at_ms = ?2
        \\where grant_id = ?1 and consumed_at_ms is null and revoked_at_ms is null
    , .{ request.grant_id, now_ms });
    if (conn.changes() != 1) return error.PairingGrantRejected;
    try conn.commit();
    transaction_open = false;
    issued.scope_mask = scope_mask;
    return issued;
}

/// Verify a device credential in constant time, enforce scope subset, record
/// successful use, and return only the requested/granted mask. Keeping the
/// device's broader authorization private prevents a token adapter from
/// accidentally widening a least-privilege request.
pub fn authenticateDevice(
    conn: zqlite.Conn,
    device_id: []const u8,
    device_credential: []const u8,
    requested_scopes: []const []const u8,
    now_ms: i64,
) !u16 {
    try validateNow(now_ms);
    access.validateDeviceId(device_id) catch return error.DeviceAuthenticationRejected;
    access.validateSecret(device_credential) catch return error.DeviceAuthenticationRejected;
    const requested_mask = access.scopeMask(requested_scopes) catch
        return error.DeviceAuthenticationRejected;

    try conn.execNoArgs("begin immediate");
    var transaction_open = true;
    defer if (transaction_open) conn.rollback();
    var row = (try conn.row(
        \\select credential_verifier, scopes, revoked_at_ms
        \\from runtime_devices where device_id = ?1
    , .{device_id})) orelse return error.DeviceAuthenticationRejected;
    defer row.deinit();

    const stored_verifier = row.blob(0);
    const authorized_mask = try checkedScopeMask(row.int(1));
    const revoked_at_ms = row.nullableInt(2);
    var candidate = secretVerifier(DEVICE_VERIFIER_DOMAIN, device_id, device_credential);
    defer std.crypto.secureZero(u8, candidate[0..]);
    if (stored_verifier.len != candidate.len or
        !std.crypto.timing_safe.eql(Digest, stored_verifier[0..@sizeOf(Digest)].*, candidate) or
        revoked_at_ms != null or
        !access.scopeMaskContains(authorized_mask, requested_mask))
    {
        return error.DeviceAuthenticationRejected;
    }

    try conn.exec(
        "update runtime_devices set last_used_at_ms = ?2 where device_id = ?1 and revoked_at_ms is null",
        .{ device_id, now_ms },
    );
    if (conn.changes() != 1) return error.DeviceAuthenticationRejected;
    try conn.commit();
    transaction_open = false;
    return requested_mask;
}

/// Re-check an already authenticated device for every network operation.
/// This makes local revocation effective for short-lived access tokens and
/// WebSocket sessions without retaining the device credential in the gateway.
pub fn authorizeDevice(
    conn: zqlite.Conn,
    device_id: []const u8,
    required_scopes: []const []const u8,
) !u16 {
    access.validateDeviceId(device_id) catch return error.DeviceAuthorizationRejected;
    const required_mask = access.scopeMask(required_scopes) catch
        return error.DeviceAuthorizationRejected;
    var row = (try conn.row(
        "select scopes, revoked_at_ms from runtime_devices where device_id = ?1",
        .{device_id},
    )) orelse return error.DeviceAuthorizationRejected;
    defer row.deinit();
    const authorized_mask = try checkedScopeMask(row.int(0));
    if (row.nullableInt(1) != null or
        !access.scopeMaskContains(authorized_mask, required_mask))
    {
        return error.DeviceAuthorizationRejected;
    }
    return required_mask;
}

/// Revoke an unconsumed grant. Returns false when absent or already final.
pub fn revokePairingGrant(conn: zqlite.Conn, grant_id: []const u8, now_ms: i64) !bool {
    try access.validateGrantId(grant_id);
    try validateNow(now_ms);
    try conn.exec(
        \\update runtime_pairing_grants set revoked_at_ms = ?2
        \\where grant_id = ?1 and consumed_at_ms is null and revoked_at_ms is null
    , .{ grant_id, now_ms });
    return conn.changes() == 1;
}

/// Revoke a device idempotently. No credential material is accepted here.
pub fn revokeDevice(conn: zqlite.Conn, device_id: []const u8, now_ms: i64) !bool {
    try access.validateDeviceId(device_id);
    try validateNow(now_ms);
    try conn.exec(
        "update runtime_devices set revoked_at_ms = ?2 where device_id = ?1 and revoked_at_ms is null",
        .{ device_id, now_ms },
    );
    return conn.changes() == 1;
}

/// List only non-secret grant metadata for local administration.
pub fn listPairingGrants(
    allocator: std.mem.Allocator,
    conn: zqlite.Conn,
    now_ms: i64,
) !OwnedPairingGrantList {
    _ = try prune(conn, now_ms, DEFAULT_RETENTION_MS);
    var items: std.ArrayList(OwnedPairingGrant) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    var rows = try conn.rows(
        \\select grant_id, label, scopes, created_at_ms, expires_at_ms,
        \\       consumed_at_ms, revoked_at_ms
        \\from runtime_pairing_grants order by created_at_ms desc, grant_id
    , .{});
    defer rows.deinit();
    while (rows.next()) |row| {
        const grant_id = row.text(0);
        try access.validateGrantId(grant_id);
        const label = row.nullableText(1);
        if (label) |value| try access.validateDeviceLabel(value);
        const owned_id = try allocator.dupe(u8, grant_id);
        errdefer allocator.free(owned_id);
        const owned_label = if (label) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_label) |value| allocator.free(value);
        try items.append(allocator, .{
            .grant_id = owned_id,
            .label = owned_label,
            .scope_mask = try checkedScopeMask(row.int(2)),
            .created_at_ms = row.int(3),
            .expires_at_ms = row.int(4),
            .consumed_at_ms = row.nullableInt(5),
            .revoked_at_ms = row.nullableInt(6),
        });
    }
    if (rows.err) |err| return err;
    return .{ .items = try items.toOwnedSlice(allocator) };
}

/// List only non-secret device metadata for local administration.
pub fn listDevices(
    allocator: std.mem.Allocator,
    conn: zqlite.Conn,
    now_ms: i64,
) !OwnedDeviceList {
    _ = try prune(conn, now_ms, DEFAULT_RETENTION_MS);
    var items: std.ArrayList(OwnedDevice) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    var rows = try conn.rows(
        \\select device_id, grant_id, label, scopes, created_at_ms,
        \\       last_used_at_ms, revoked_at_ms
        \\from runtime_devices order by created_at_ms desc, device_id
    , .{});
    defer rows.deinit();
    while (rows.next()) |row| {
        const device_id = row.text(0);
        const grant_id = row.text(1);
        const label = row.text(2);
        try access.validateDeviceId(device_id);
        try access.validateGrantId(grant_id);
        try access.validateDeviceLabel(label);
        const owned_device_id = try allocator.dupe(u8, device_id);
        errdefer allocator.free(owned_device_id);
        const owned_grant_id = try allocator.dupe(u8, grant_id);
        errdefer allocator.free(owned_grant_id);
        const owned_label = try allocator.dupe(u8, label);
        errdefer allocator.free(owned_label);
        try items.append(allocator, .{
            .device_id = owned_device_id,
            .grant_id = owned_grant_id,
            .label = owned_label,
            .scope_mask = try checkedScopeMask(row.int(3)),
            .created_at_ms = row.int(4),
            .last_used_at_ms = row.nullableInt(5),
            .revoked_at_ms = row.nullableInt(6),
        });
    }
    if (rows.err) |err| return err;
    return .{ .items = try items.toOwnedSlice(allocator) };
}

/// Bound terminal audit history by age and count. Active grants/devices and
/// grants still referenced by retained devices are never pruned.
pub fn prune(conn: zqlite.Conn, now_ms: i64, retention_ms: i64) !PruneResult {
    try validateNow(now_ms);
    if (retention_ms < 0) return error.InvalidAccessRetention;
    try conn.execNoArgs("begin immediate");
    var transaction_open = true;
    defer if (transaction_open) conn.rollback();
    const result = try pruneLockedToLimits(
        conn,
        now_ms,
        retention_ms,
        MAX_RETAINED_PAIRING_GRANTS,
        MAX_RETAINED_DEVICES,
    );
    try conn.commit();
    transaction_open = false;
    return result;
}

fn pruneLockedToLimits(
    conn: zqlite.Conn,
    now_ms: i64,
    retention_ms: i64,
    grant_limit: i64,
    device_limit: i64,
) !PruneResult {
    if (grant_limit < 0 or device_limit < 0) return error.InvalidAccessRetention;
    const cutoff_ms = @max(@as(i64, 0), now_ms -| retention_ms);
    try conn.exec(
        \\delete from runtime_devices
        \\where revoked_at_ms is not null and revoked_at_ms <= ?1
    , .{cutoff_ms});
    var devices_removed = conn.changes();
    const device_excess = @max(@as(i64, 0), try countRows(conn, "runtime_devices") - device_limit);
    if (device_excess > 0) {
        try conn.exec(
            \\delete from runtime_devices where device_id in (
            \\    select device_id from runtime_devices
            \\    where revoked_at_ms is not null
            \\    order by revoked_at_ms, created_at_ms, device_id
            \\    limit ?1
            \\)
        , .{device_excess});
        devices_removed += conn.changes();
    }
    try conn.exec(
        \\delete from runtime_pairing_grants
        \\where not exists (
        \\    select 1 from runtime_devices where runtime_devices.grant_id = runtime_pairing_grants.grant_id
        \\) and (
        \\    (consumed_at_ms is not null and consumed_at_ms <= ?1) or
        \\    (revoked_at_ms is not null and revoked_at_ms <= ?1) or
        \\    (consumed_at_ms is null and revoked_at_ms is null and expires_at_ms <= ?1)
        \\)
    , .{cutoff_ms});
    var grants_removed = conn.changes();
    const grant_excess = @max(@as(i64, 0), try countRows(conn, "runtime_pairing_grants") - grant_limit);
    if (grant_excess > 0) {
        try conn.exec(
            \\delete from runtime_pairing_grants where grant_id in (
            \\    select grant_id from runtime_pairing_grants
            \\    where not exists (
            \\        select 1 from runtime_devices
            \\        where runtime_devices.grant_id = runtime_pairing_grants.grant_id
            \\    ) and (
            \\        consumed_at_ms is not null or revoked_at_ms is not null or expires_at_ms <= ?1
            \\    )
            \\    order by coalesce(revoked_at_ms, consumed_at_ms, expires_at_ms),
            \\             created_at_ms, grant_id
            \\    limit ?2
            \\)
        , .{ now_ms, grant_excess });
        grants_removed += conn.changes();
    }
    return .{
        .grants_removed = grants_removed,
        .devices_removed = devices_removed,
    };
}

fn countRows(conn: zqlite.Conn, comptime table_name: []const u8) !i64 {
    var row = (try conn.row("select count(*) from " ++ table_name, .{})).?;
    defer row.deinit();
    const count = row.int(0);
    if (count < 0) return error.AccessStoreCorrupt;
    return count;
}

fn checkedScopeMask(value: i64) !u16 {
    if (value <= 0 or value > std.math.maxInt(u16)) return error.AccessStoreCorrupt;
    const mask: u16 = @intCast(value);
    access.validateScopeMask(mask) catch return error.AccessStoreCorrupt;
    return mask;
}

fn validateNow(now_ms: i64) !void {
    if (now_ms < 0) return error.InvalidAccessTimestamp;
}

fn saturatingAdd(base: i64, delta: i64) i64 {
    return std.math.add(i64, base, delta) catch std.math.maxInt(i64);
}

fn secureHex(comptime byte_len: usize, io: std.Io) ![byte_len * 2]u8 {
    var entropy: [byte_len]u8 = undefined;
    defer std.crypto.secureZero(u8, entropy[0..]);
    try std.Io.randomSecure(io, entropy[0..]);
    return std.fmt.bytesToHex(entropy, .lower);
}

fn secretVerifier(domain: []const u8, id: []const u8, secret: []const u8) Digest {
    var hash = Sha256.init(.{});
    hash.update(domain);
    hash.update("\x00");
    hash.update(id);
    hash.update("\x00");
    hash.update(secret);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

test "pairing grant exchange is one-time, scoped, revocable, and verifier-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.joinZ(
        std.testing.allocator,
        &.{ path_buffer[0..path_len], "access.sqlite" },
    );
    defer std.testing.allocator.free(path);
    const conn = try zqlite.open(
        path,
        zqlite.OpenFlags.Create | zqlite.OpenFlags.NoFollow | zqlite.OpenFlags.EXResCode,
    );
    defer conn.close();
    try conn.busyTimeout(BUSY_TIMEOUT_MS);
    try conn.execNoArgs("pragma foreign_keys = on");
    try initialize(conn);

    var grant = try createPairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .label = "Test laptop",
        .ttl_seconds = 60,
        .scopes = &.{ "runtime:read", "chat:read", "chat:write" },
    }, 1_000);
    defer grant.clear();
    try std.testing.expectEqual(@as(usize, access.SECRET_HEX_BYTES), grant.pairing_token.len);

    var verifier_row = (try conn.row(
        "select verifier from runtime_pairing_grants where grant_id = ?1",
        .{grant.grant_id[0..]},
    )).?;
    defer verifier_row.deinit();
    try std.testing.expectEqual(@as(usize, @sizeOf(Digest)), verifier_row.blob(0).len);
    try std.testing.expect(!std.mem.eql(u8, verifier_row.blob(0), grant.pairing_token[0..@sizeOf(Digest)]));

    const exchange_request: access.PairingGrantExchangeRequest = .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .grant_id = grant.grant_id[0..],
        .pairing_token = .{ .bytes = grant.pairing_token[0..] },
        .device_label = "Test laptop",
    };
    var device = try exchangePairingGrant(std.testing.io, conn, exchange_request, 2_000);
    defer device.clear();
    try std.testing.expectError(
        error.PairingGrantRejected,
        exchangePairingGrant(std.testing.io, conn, exchange_request, 2_001),
    );

    const requested_mask = try access.scopeMask(&.{ "runtime:read", "chat:write" });
    const granted_mask = try authenticateDevice(
        conn,
        device.device_id[0..],
        device.device_credential[0..],
        &.{ "runtime:read", "chat:write" },
        3_000,
    );
    try std.testing.expect(device.scope_mask != requested_mask);
    try std.testing.expectEqual(requested_mask, granted_mask);
    try std.testing.expectEqual(
        try access.scopeMask(&.{"runtime:read"}),
        try authorizeDevice(conn, device.device_id[0..], &.{"runtime:read"}),
    );
    try std.testing.expectError(
        error.DeviceAuthorizationRejected,
        authorizeDevice(conn, device.device_id[0..], &.{"terminal:write"}),
    );
    try std.testing.expectError(
        error.DeviceAuthenticationRejected,
        authenticateDevice(
            conn,
            device.device_id[0..],
            "0" ** access.SECRET_HEX_BYTES,
            &.{"runtime:read"},
            3_001,
        ),
    );
    try std.testing.expectError(
        error.DeviceAuthenticationRejected,
        authenticateDevice(
            conn,
            device.device_id[0..],
            device.device_credential[0..],
            &.{"terminal:write"},
            3_002,
        ),
    );

    var grants = try listPairingGrants(std.testing.allocator, conn, 3_100);
    defer grants.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), grants.items.len);
    try std.testing.expect(grants.items[0].consumed_at_ms != null);
    var devices = try listDevices(std.testing.allocator, conn, 3_100);
    defer devices.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), devices.items.len);
    try std.testing.expectEqualStrings("Test laptop", devices.items[0].label);

    try std.testing.expect(try revokeDevice(conn, device.device_id[0..], 4_000));
    try std.testing.expect(!(try revokeDevice(conn, device.device_id[0..], 4_001)));
    try std.testing.expectError(
        error.DeviceAuthorizationRejected,
        authorizeDevice(conn, device.device_id[0..], &.{"runtime:read"}),
    );
    try std.testing.expectError(
        error.DeviceAuthenticationRejected,
        authenticateDevice(
            conn,
            device.device_id[0..],
            device.device_credential[0..],
            &.{"runtime:read"},
            4_002,
        ),
    );
}

test "expired or revoked grants fail closed without creating devices" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.joinZ(
        std.testing.allocator,
        &.{ path_buffer[0..path_len], "access.sqlite" },
    );
    defer std.testing.allocator.free(path);
    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs("pragma foreign_keys = on");
    try initialize(conn);

    var expired = try createPairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .ttl_seconds = 1,
        .scopes = &.{"runtime:read"},
    }, 10_000);
    defer expired.clear();
    const expired_request: access.PairingGrantExchangeRequest = .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .grant_id = expired.grant_id[0..],
        .pairing_token = .{ .bytes = expired.pairing_token[0..] },
        .device_label = "Expired device",
    };
    try std.testing.expectError(
        error.PairingGrantRejected,
        exchangePairingGrant(std.testing.io, conn, expired_request, 11_000),
    );

    var revoked = try createPairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .ttl_seconds = 60,
        .scopes = &.{"runtime:read"},
    }, 20_000);
    defer revoked.clear();
    try std.testing.expect(try revokePairingGrant(conn, revoked.grant_id[0..], 20_001));
    try std.testing.expect(!(try revokePairingGrant(conn, revoked.grant_id[0..], 20_002)));
    const revoked_request: access.PairingGrantExchangeRequest = .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .grant_id = revoked.grant_id[0..],
        .pairing_token = .{ .bytes = revoked.pairing_token[0..] },
        .device_label = "Revoked device",
    };
    try std.testing.expectError(
        error.PairingGrantRejected,
        exchangePairingGrant(std.testing.io, conn, revoked_request, 20_003),
    );
    var count_row = (try conn.row("select count(*) from runtime_devices", .{})).?;
    defer count_row.deinit();
    try std.testing.expectEqual(@as(i64, 0), count_row.int(0));
}

test "two database connections serialize one-time grant exchange" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.joinZ(
        std.testing.allocator,
        &.{ path_buffer[0..path_len], "access.sqlite" },
    );
    defer std.testing.allocator.free(path);
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    const first_conn = try zqlite.open(path, flags);
    defer first_conn.close();
    try first_conn.busyTimeout(BUSY_TIMEOUT_MS);
    try first_conn.execNoArgs("pragma foreign_keys = on");
    try initialize(first_conn);
    const second_conn = try zqlite.open(path, flags);
    defer second_conn.close();
    try second_conn.busyTimeout(BUSY_TIMEOUT_MS);
    try second_conn.execNoArgs("pragma foreign_keys = on");

    var grant = try createPairingGrant(std.testing.io, first_conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .ttl_seconds = 60,
        .scopes = &.{ "runtime:read", "chat:write" },
    }, 30_000);
    defer grant.clear();
    const request: access.PairingGrantExchangeRequest = .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .grant_id = grant.grant_id[0..],
        .pairing_token = .{ .bytes = grant.pairing_token[0..] },
        .device_label = "Racing device",
    };

    const RaceContext = struct {
        conn: zqlite.Conn,
        request: access.PairingGrantExchangeRequest,
        ready: *std.atomic.Value(u8),
        start: *std.atomic.Value(bool),
        issued: bool = false,
        rejected: bool = false,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            var threaded = std.Io.Threaded.init_single_threaded;
            _ = self.ready.fetchAdd(1, .release);
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            var device = exchangePairingGrant(
                threaded.io(),
                self.conn,
                self.request,
                30_001,
            ) catch |err| {
                if (err == error.PairingGrantRejected) {
                    self.rejected = true;
                } else {
                    self.failure = err;
                }
                return;
            };
            device.clear();
            self.issued = true;
        }
    };
    var ready: std.atomic.Value(u8) = .init(0);
    var start: std.atomic.Value(bool) = .init(false);
    var first: RaceContext = .{
        .conn = first_conn,
        .request = request,
        .ready = &ready,
        .start = &start,
    };
    var second: RaceContext = .{
        .conn = second_conn,
        .request = request,
        .ready = &ready,
        .start = &start,
    };
    const first_thread = try std.Thread.spawn(.{}, RaceContext.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, RaceContext.run, .{&second});
    while (ready.load(.acquire) != 2) std.atomic.spinLoopHint();
    start.store(true, .release);
    first_thread.join();
    second_thread.join();

    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    try std.testing.expect((first.issued and second.rejected) or
        (second.issued and first.rejected));
    var count_row = (try first_conn.row(
        \\select (select count(*) from runtime_devices),
        \\       (select count(*) from runtime_pairing_grants where consumed_at_ms is not null)
    , .{})).?;
    defer count_row.deinit();
    try std.testing.expectEqual(@as(i64, 1), count_row.int(0));
    try std.testing.expectEqual(@as(i64, 1), count_row.int(1));
}

test "pruning retains active records and bounds terminal audit history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.joinZ(
        std.testing.allocator,
        &.{ path_buffer[0..path_len], "access.sqlite" },
    );
    defer std.testing.allocator.free(path);
    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs("pragma foreign_keys = on");
    try initialize(conn);

    var consumed = try createPairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .ttl_seconds = 60,
        .scopes = &.{"runtime:read"},
    }, 1_000);
    defer consumed.clear();
    var device = try exchangePairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .grant_id = consumed.grant_id[0..],
        .pairing_token = .{ .bytes = consumed.pairing_token[0..] },
        .device_label = "Retained device",
    }, 1_100);
    defer device.clear();
    try std.testing.expect(try revokeDevice(conn, device.device_id[0..], 2_000));

    var revoked = try createPairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .ttl_seconds = 60,
        .scopes = &.{"runtime:read"},
    }, 1_000);
    defer revoked.clear();
    try std.testing.expect(try revokePairingGrant(conn, revoked.grant_id[0..], 2_000));

    var expired = try createPairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .ttl_seconds = 1,
        .scopes = &.{"runtime:read"},
    }, 1_000);
    defer expired.clear();

    const before_cutoff = try prune(conn, 2_999, 1_000);
    try std.testing.expectEqual(@as(usize, 0), before_cutoff.devices_removed);
    try std.testing.expectEqual(@as(usize, 0), before_cutoff.grants_removed);
    try std.testing.expectEqual(@as(i64, 1), try countRows(conn, "runtime_devices"));
    try std.testing.expectEqual(@as(i64, 3), try countRows(conn, "runtime_pairing_grants"));

    const at_cutoff = try prune(conn, 3_000, 1_000);
    try std.testing.expectEqual(@as(usize, 1), at_cutoff.devices_removed);
    try std.testing.expectEqual(@as(usize, 3), at_cutoff.grants_removed);
    try std.testing.expectEqual(@as(i64, 0), try countRows(conn, "runtime_devices"));
    try std.testing.expectEqual(@as(i64, 0), try countRows(conn, "runtime_pairing_grants"));

    var active = try createPairingGrant(std.testing.io, conn, .{
        .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
        .ttl_seconds = 60,
        .scopes = &.{"runtime:read"},
    }, 100_000);
    defer active.clear();
    const active_prune = try prune(conn, 100_000, 0);
    try std.testing.expectEqual(@as(usize, 0), active_prune.devices_removed);
    try std.testing.expectEqual(@as(usize, 0), active_prune.grants_removed);
    try std.testing.expectEqual(@as(i64, 1), try countRows(conn, "runtime_pairing_grants"));
}

test "count pressure evicts only the oldest eligible terminal records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fs.path.joinZ(
        std.testing.allocator,
        &.{ path_buffer[0..path_len], "access.sqlite" },
    );
    defer std.testing.allocator.free(path);
    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs("pragma foreign_keys = on");
    try initialize(conn);

    const first_grant = "00000000000000000000000000000001";
    const second_grant = "00000000000000000000000000000002";
    const third_grant = "00000000000000000000000000000003";
    const active_grant = "00000000000000000000000000000004";
    try conn.exec(
        "insert into runtime_pairing_grants values (?1, zeroblob(32), null, 1, 10, 2000, 100, null)",
        .{first_grant},
    );
    try conn.exec(
        "insert into runtime_pairing_grants values (?1, zeroblob(32), null, 1, 20, 2000, null, 200)",
        .{second_grant},
    );
    try conn.exec(
        "insert into runtime_pairing_grants values (?1, zeroblob(32), null, 1, 30, 500, null, null)",
        .{third_grant},
    );
    try conn.exec(
        "insert into runtime_pairing_grants values (?1, zeroblob(32), null, 1, 40, 2000, null, null)",
        .{active_grant},
    );
    try conn.execNoArgs("begin immediate");
    const grant_trim = try pruneLockedToLimits(conn, 1_000, 10_000, 2, 0);
    try conn.commit();
    try std.testing.expectEqual(@as(usize, 2), grant_trim.grants_removed);
    try std.testing.expectEqual(@as(usize, 0), grant_trim.devices_removed);
    try std.testing.expectEqual(@as(i64, 2), try countRows(conn, "runtime_pairing_grants"));
    {
        var row = (try conn.row(
            "select 1 from runtime_pairing_grants where grant_id = ?1",
            .{third_grant},
        )).?;
        defer row.deinit();
    }
    {
        var row = (try conn.row(
            "select 1 from runtime_pairing_grants where grant_id = ?1",
            .{active_grant},
        )).?;
        defer row.deinit();
    }

    try conn.execNoArgs("delete from runtime_pairing_grants");
    const device_grants = [_][]const u8{
        "10000000000000000000000000000001",
        "10000000000000000000000000000002",
        "10000000000000000000000000000003",
    };
    const device_ids = [_][]const u8{
        "20000000000000000000000000000001",
        "20000000000000000000000000000002",
        "20000000000000000000000000000003",
    };
    for (device_grants, device_ids, 0..) |grant_id, device_id, index| {
        const timestamp: i64 = @intCast(100 + index);
        try conn.exec(
            "insert into runtime_pairing_grants values (?1, zeroblob(32), null, 1, ?2, 2000, ?2, null)",
            .{ grant_id, timestamp },
        );
        try conn.exec(
            "insert into runtime_devices values (?1, ?2, zeroblob(32), 'Device', 1, ?3, null, ?3)",
            .{ device_id, grant_id, timestamp },
        );
    }
    try conn.exec(
        "insert into runtime_pairing_grants values (?1, zeroblob(32), null, 1, 500, 2000, null, null)",
        .{active_grant},
    );
    try conn.execNoArgs("begin immediate");
    const device_trim = try pruneLockedToLimits(conn, 1_000, 10_000, 3, 2);
    try conn.commit();
    try std.testing.expectEqual(@as(usize, 1), device_trim.devices_removed);
    try std.testing.expectEqual(@as(usize, 1), device_trim.grants_removed);
    try std.testing.expectEqual(@as(i64, 2), try countRows(conn, "runtime_devices"));
    try std.testing.expectEqual(@as(i64, 3), try countRows(conn, "runtime_pairing_grants"));
    try std.testing.expect((try conn.row(
        "select 1 from runtime_devices where device_id = ?1",
        .{device_ids[0]},
    )) == null);
    try std.testing.expect((try conn.row(
        "select 1 from runtime_pairing_grants where grant_id = ?1",
        .{device_grants[0]},
    )) == null);
}
