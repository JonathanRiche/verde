//! Daemon-owned machine Companion roster. Every client (desktop, web, mobile)
//! reads and writes the same roster through `companion.roster.get` /
//! `companion.roster.put`, and the daemon itself appends the companion's
//! persona to turns on a companion thread, so a message sent from a phone gets
//! the same orchestrator as one typed on the desktop.

const std = @import("std");
const zqlite = @import("zqlite");
const roster_mod = @import("../state/companion_roster.zig");
const persona = @import("../state/companion_persona.zig");

pub const METHOD_GET = "companion.roster.get";
pub const METHOD_PUT = "companion.roster.put";
pub const MAX_ROSTER_JSON_BYTES: usize = 48 * 1024;

/// One-row ledger created at store open (like chat_task_origins), so no
/// schema version bump strands older binaries on the same database.
pub const SCHEMA_SQL: [:0]const u8 =
    \\create table if not exists companion_roster (
    \\ id integer primary key check (id = 1),
    \\ revision integer not null,
    \\ roster_json text not null
    \\);
;

pub fn initialize(conn: zqlite.Conn) !void {
    try conn.execNoArgs(SCHEMA_SQL);
}

pub const Snapshot = struct {
    revision: i64,
    /// Canonical roster JSON (see companion_roster.encodeAlloc).
    json: []u8,
};

const EMPTY_ROSTER_JSON = "{\"version\":1,\"active_id\":\"\",\"companions\":[]}";

/// Current roster; revision 0 with an empty roster when none was ever saved.
pub fn get(conn: zqlite.Conn, allocator: std.mem.Allocator) !Snapshot {
    var row = (try conn.row("select revision,roster_json from companion_roster where id=1", .{})) orelse
        return .{ .revision = 0, .json = try allocator.dupe(u8, EMPTY_ROSTER_JSON) };
    defer row.deinit();
    return .{ .revision = row.int(0), .json = try allocator.dupe(u8, row.text(1)) };
}

/// Validates and stores a roster, returning the new revision. When
/// `expected_revision` is set and stale, returns error.Conflict so two clients
/// editing at once never silently overwrite each other.
pub fn put(conn: zqlite.Conn, allocator: std.mem.Allocator, roster_json: []const u8, expected_revision: ?i64) !i64 {
    if (roster_json.len == 0 or roster_json.len > MAX_ROSTER_JSON_BYTES) return error.InvalidParams;
    var roster = roster_mod.init();
    roster.parse(allocator, roster_json) catch return error.InvalidParams;
    const canonical = try roster.encodeAlloc(allocator);
    defer allocator.free(canonical);
    const current = blk: {
        var row = (try conn.row("select revision from companion_roster where id=1", .{})) orelse break :blk @as(i64, 0);
        defer row.deinit();
        break :blk row.int(0);
    };
    if (expected_revision) |expected| {
        if (expected != current) return error.Conflict;
    }
    const next = current + 1;
    try conn.exec(
        "insert into companion_roster(id,revision,roster_json) values(1,?,?) on conflict(id) do update set revision=excluded.revision,roster_json=excluded.roster_json",
        .{ next, canonical },
    );
    return next;
}

/// Persona note for a turn on a companion thread, or null for ordinary chats.
pub fn noteForThread(conn: zqlite.Conn, allocator: std.mem.Allocator, workspace_id: []const u8, local_thread_id: []const u8) !?[]u8 {
    const snapshot = try get(conn, allocator);
    defer allocator.free(snapshot.json);
    if (snapshot.revision == 0) return null;
    var roster = roster_mod.init();
    roster.parse(allocator, snapshot.json) catch return null;
    const index = roster.indexForThread(workspace_id, local_thread_id) orelse return null;
    const companion = &roster.entries[index];
    const label = blk: {
        var row = (try conn.row("select label from workspaces where workspace_id=?", .{workspace_id})) orelse break :blk try allocator.dupe(u8, workspace_id);
        defer row.deinit();
        break :blk try allocator.dupe(u8, row.text(0));
    };
    defer allocator.free(label);
    return try persona.noteAlloc(allocator, companion.name.slice(), companion.character, workspace_id, label, companion.orders.slice());
}

fn testConn() !zqlite.Conn {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    try initialize(conn);
    try conn.execNoArgs("create table workspaces (id integer primary key, workspace_id text unique, label text)");
    return conn;
}

test "roster starts empty, versions every put, and rejects stale writers" {
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    const empty = try get(conn, allocator);
    defer allocator.free(empty.json);
    try std.testing.expectEqual(@as(i64, 0), empty.revision);

    const first = try put(conn, allocator, "{\"companions\":[{\"id\":\"a\",\"name\":\"Juniper\",\"character\":\"moss\"}]}", 0);
    try std.testing.expectEqual(@as(i64, 1), first);
    try std.testing.expectError(error.Conflict, put(conn, allocator, "{\"companions\":[]}", 0));
    try std.testing.expectEqual(@as(i64, 2), try put(conn, allocator, "{\"companions\":[]}", null));
    try std.testing.expectError(error.InvalidParams, put(conn, allocator, "not json", null));

    const snapshot = try get(conn, allocator);
    defer allocator.free(snapshot.json);
    try std.testing.expectEqual(@as(i64, 2), snapshot.revision);
}

test "persona is attached only to the companion's own thread" {
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    try conn.execNoArgs("insert into workspaces(workspace_id,label) values('home','verde')");
    _ = try put(conn, allocator,
        \\{"companions":[{"id":"a","name":"Wren","character":"vireo","home_workspace_id":"home","thread_id":"chat-1","orders":"Never push to main."}]}
    , null);
    const note = (try noteForThread(conn, allocator, "home", "chat-1")).?;
    defer allocator.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "You are Wren") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "(verde, workspace_id home)") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "Never push to main.") != null);
    try std.testing.expect((try noteForThread(conn, allocator, "home", "chat-2")) == null);
    try std.testing.expect((try noteForThread(conn, allocator, "other", "chat-1")) == null);
}
