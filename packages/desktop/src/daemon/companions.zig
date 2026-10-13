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
pub const MAX_ROSTER_JSON_BYTES: usize = 160 * 1024;

/// One-row ledger created at store open (like chat_task_origins), so no
/// schema version bump strands older binaries on the same database.
pub const SCHEMA_SQL: [:0]const u8 =
    \\create table if not exists companion_roster (
    \\ id integer primary key check (id = 1),
    \\ revision integer not null,
    \\ roster_json text not null
    \\);
;

/// Pending brain handoffs: after a companion switches provider, its next
/// turn on the new provider receives the brief plus recent history once the
/// new provider has no session yet.
pub const HANDOFF_SQL: [:0]const u8 =
    \\create table if not exists companion_handoffs (
    \\ workspace_id text not null,
    \\ local_thread_id text not null,
    \\ from_brain text not null,
    \\ to_brain text not null,
    \\ brief text not null default '',
    \\ created_at_ms integer not null,
    \\ primary key (workspace_id, local_thread_id)
    \\);
;

pub fn initialize(conn: zqlite.Conn) !void {
    try conn.execNoArgs(SCHEMA_SQL);
    try conn.execNoArgs(HANDOFF_SQL);
}

pub fn recordHandoff(conn: zqlite.Conn, workspace_id: []const u8, thread_id: []const u8, from_brain: []const u8, to_brain: []const u8, brief: []const u8, now_ms: i64) !void {
    try conn.exec(
        "insert into companion_handoffs(workspace_id,local_thread_id,from_brain,to_brain,brief,created_at_ms) values(?,?,?,?,?,?) " ++
            "on conflict(workspace_id,local_thread_id) do update set from_brain=excluded.from_brain,to_brain=excluded.to_brain,brief=excluded.brief,created_at_ms=excluded.created_at_ms",
        .{ workspace_id, thread_id, from_brain, to_brain, brief, now_ms },
    );
}

/// Character budget for replayed history (the newest turns win).
const HANDOFF_HISTORY_BUDGET: usize = 24 * 1024;
const HANDOFF_MESSAGE_CAP: usize = 4 * 1024;

/// Handoff context for a thread whose provider has not started a session
/// yet, or null. Consumes the pending row once the new provider has a
/// session (the context is already in its memory).
pub fn handoffContextAlloc(conn: zqlite.Conn, allocator: std.mem.Allocator, workspace_id: []const u8, thread_id: []const u8) !?[]u8 {
    var pending = (try conn.row("select from_brain,to_brain,brief from companion_handoffs where workspace_id=? and local_thread_id=?", .{ workspace_id, thread_id })) orelse return null;
    defer pending.deinit();
    const session = blk: {
        var row = (try conn.row("select t.id, t.provider_thread_id from threads t join workspaces w on w.id=t.workspace_id where w.workspace_id=? and t.local_thread_id=?", .{ workspace_id, thread_id })) orelse return null;
        defer row.deinit();
        const has_session = if (row.nullableText(1)) |value| value.len > 0 else false;
        break :blk .{ .id = row.int(0), .has_session = has_session };
    };
    if (session.has_session) {
        try conn.exec("delete from companion_handoffs where workspace_id=? and local_thread_id=?", .{ workspace_id, thread_id });
        return null;
    }

    // Newest conversational rows first until the budget is spent.
    const Line = struct { role: i64, author: []u8, body: []u8 };
    var lines: std.ArrayList(Line) = .empty;
    defer {
        for (lines.items) |line| {
            allocator.free(line.author);
            allocator.free(line.body);
        }
        lines.deinit(allocator);
    }
    var used: usize = 0;
    var omitted: usize = 0;
    {
        var rows = try conn.rows("select role,author,body from messages where thread_id=? and tool_call_id is null and role in (0,1) order by sort_index desc", .{session.id});
        defer rows.deinit();
        while (rows.next()) |row| {
            const body = std.mem.trim(u8, row.text(2), " \t\r\n");
            if (body.len == 0) continue;
            if (used >= HANDOFF_HISTORY_BUDGET) {
                omitted += 1;
                continue;
            }
            const clipped = clip(body, HANDOFF_MESSAGE_CAP);
            used += clipped.len;
            try lines.append(allocator, .{ .role = row.int(0), .author = try allocator.dupe(u8, row.text(1)), .body = try allocator.dupe(u8, clipped) });
        }
        if (rows.err) |err| return err;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("<brain_handoff>\nYou just took over as this companion's brain from {s} (you are {s}). The earlier conversation happened with the previous brain; continue it seamlessly without re-introducing yourself.\n", .{ pending.text(0), pending.text(1) });
    const brief = std.mem.trim(u8, pending.text(2), " \t\r\n");
    if (brief.len > 0) try w.print("\nHandoff brief written by the previous brain:\n{s}\n", .{clip(brief, 8 * 1024)});
    if (omitted > 0) try w.print("\n({d} older messages omitted; use read_chat_thread on this thread if you need them.)\n", .{omitted});
    if (lines.items.len > 0) {
        try w.writeAll("\nRecent conversation (oldest first):\n");
        var index = lines.items.len;
        while (index > 0) {
            index -= 1;
            const line = lines.items[index];
            try w.print("[{s}] {s}\n", .{ if (line.role == 0) "user" else "assistant", line.body });
        }
    }
    try w.writeAll("</brain_handoff>");
    return try out.toOwnedSlice();
}

fn clip(text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    var end = cap;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// Prompt asking the outgoing brain for a successor brief. Visible in the
/// transcript on purpose: the user sees what was handed over.
pub fn briefPromptAlloc(allocator: std.mem.Allocator, name: []const u8, to_brain: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\↪ Brain handoff: {s} is switching to {s}. Write a handoff brief for your successor, under 300 words and without running tools: current goals, work in progress (crew chats with their workspace and thread ids), decisions made, open questions, and what you've learned about how the user likes to work.
    , .{ name, to_brain });
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
    const handoff = try handoffContextAlloc(conn, allocator, workspace_id, local_thread_id);
    defer if (handoff) |text| allocator.free(text);
    const label = blk: {
        var row = (try conn.row("select label from workspaces where workspace_id=?", .{workspace_id})) orelse break :blk try allocator.dupe(u8, workspace_id);
        defer row.deinit();
        break :blk try allocator.dupe(u8, row.text(0));
    };
    defer allocator.free(label);
    const note = try persona.noteAlloc(allocator, companion.name.slice(), companion.character, workspace_id, label, companion.orders.slice());
    const text = handoff orelse return note;
    defer allocator.free(note);
    return try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ note, text });
}

fn testConn() !zqlite.Conn {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    try initialize(conn);
    try conn.execNoArgs("create table workspaces (id integer primary key, workspace_id text unique, label text)");
    try conn.execNoArgs("create table threads (id integer primary key, workspace_id integer, local_thread_id text, provider_thread_id text)");
    try conn.execNoArgs("create table messages (id integer primary key, thread_id integer, sort_index integer, role integer, author text, body text, tool_call_id text)");
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

test "a pending handoff replays the brief and recent history until the new provider has a session" {
    const allocator = std.testing.allocator;
    var conn = try testConn();
    defer conn.close();
    try conn.execNoArgs("insert into workspaces(id,workspace_id,label) values(1,'home','verde')");
    try conn.execNoArgs("insert into threads(id,workspace_id,local_thread_id,provider_thread_id) values(7,1,'chat-1',null)");
    try conn.execNoArgs("insert into messages(thread_id,sort_index,role,author,body,tool_call_id) values(7,0,0,'You','Fix the ACP tests',null),(7,1,2,'Tool','ran',null),(7,2,1,'Moss','Opened a Codex chat for it',null),(7,3,1,'Moss','tool output','call-1')");
    _ = try put(conn, allocator,
        \\{"companions":[{"id":"a","name":"Moss","character":"moss","home_workspace_id":"home","thread_id":"chat-1"}]}
    , null);
    try recordHandoff(conn, "home", "chat-1", "Claude · haiku", "Codex · gpt-5.5", "Goal: green ACP tests.", 5);

    const note = (try noteForThread(conn, allocator, "home", "chat-1")).?;
    defer allocator.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "You are Moss") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "took over as this companion's brain from Claude · haiku") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "Goal: green ACP tests.") != null);
    const user_at = std.mem.indexOf(u8, note, "[user] Fix the ACP tests").?;
    const assistant_at = std.mem.indexOf(u8, note, "[assistant] Opened a Codex chat for it").?;
    try std.testing.expect(user_at < assistant_at);
    try std.testing.expect(std.mem.indexOf(u8, note, "tool output") == null);
    try std.testing.expect(std.mem.indexOf(u8, note, "ran") == null or std.mem.indexOf(u8, note, "[assistant] ran") == null);

    // Once the new provider has a session, the handoff is consumed.
    try conn.execNoArgs("update threads set provider_thread_id='codex-session' where id=7");
    const later = (try noteForThread(conn, allocator, "home", "chat-1")).?;
    defer allocator.free(later);
    try std.testing.expect(std.mem.indexOf(u8, later, "brain_handoff") == null);
    var remaining = (try conn.row("select count(*) from companion_handoffs", .{})).?;
    defer remaining.deinit();
    try std.testing.expectEqual(@as(i64, 0), remaining.int(0));
}
