//! Durable orchestration links, task state, and parent notification outbox.
const std = @import("std");
const zqlite = @import("zqlite");

/// Which parent asked for each delegated task. A side ledger created at store
/// open (like the access and push tables) rather than a chat_tasks column, so
/// no schema version bump strands older binaries on the same database.
/// Tasks without a row (human or recovered turns) notify every linked parent.
pub const ORIGINS_SQL: [:0]const u8 =
    \\create table if not exists chat_task_origins (
    \\ task_id text primary key references chat_tasks(task_id) on delete cascade,
    \\ parent_thread_id text not null
    \\);
;

pub fn initialize(conn: zqlite.Conn) !void {
    try conn.execNoArgs(ORIGINS_SQL);
}

/// Record the parent whose message started `task`; only that parent hears
/// its outcome, so work a shared child does for others stays out of it.
pub fn setOrigin(conn: zqlite.Conn, task: []const u8, parent: []const u8) !void {
    try conn.exec("insert or ignore into chat_task_origins(task_id,parent_thread_id) values(?,?)", .{ task, parent });
}

/// A resumed turn continues the delegated work it was blocked on, so it
/// reports to whichever parent asked for the thread's previous task.
pub fn inheritOrigin(conn: zqlite.Conn, task: []const u8, workspace: []const u8, child: []const u8) !void {
    try conn.exec(
        \\insert or ignore into chat_task_origins(task_id,parent_thread_id)
        \\select ?,o.parent_thread_id from chat_tasks k join chat_task_origins o on o.task_id=k.task_id
        \\where k.workspace_id=? and k.local_thread_id=? and k.task_id<>?
        \\and k.created_at_ms=(select max(created_at_ms) from chat_tasks where workspace_id=? and local_thread_id=? and task_id<>?)
        \\limit 1
    , .{ task, workspace, child, task, workspace, child, task });
}

/// SQL predicate (aliases `t` task, `l` link): the link's parent may hear
/// about the task.
pub const ORIGIN_MATCHES_SQL =
    "(not exists(select 1 from chat_task_origins o where o.task_id=t.task_id) " ++
    "or exists(select 1 from chat_task_origins o where o.task_id=t.task_id and o.parent_thread_id=l.parent_thread_id))";

pub fn link(conn: zqlite.Conn, allocator: std.mem.Allocator, workspace: []const u8, parent: []const u8, child: []const u8) !void {
    if (parent.len == 0 or child.len == 0 or std.mem.eql(u8, parent, child)) return error.InvalidParams;
    // Both ends must be durable threads in the same workspace.
    var count = (try conn.row("select count(*) from threads t join workspaces w on w.id=t.workspace_id where w.workspace_id=? and t.local_thread_id in (?,?)", .{ workspace, parent, child })) orelse return error.InvalidParams;
    defer count.deinit();
    if (count.int(0) != 2) return error.InvalidParams;
    // Refuse cycles, including indirect cycles, before accepting delegation.
    var cycle = (try conn.row(
        \\with recursive descendants(id) as (
        \\ select local_thread_id from chat_links where workspace_id=? and parent_thread_id=?
        \\ union select l.local_thread_id from chat_links l join descendants d on l.parent_thread_id=d.id where l.workspace_id=?
        \\) select count(*) from descendants where id=?
    , .{ workspace, child, workspace, parent })).?;
    defer cycle.deinit();
    if (cycle.int(0) != 0) return error.InvalidParams;
    const identity = try std.json.Stringify.valueAlloc(allocator, .{ workspace, parent, child }, .{});
    defer allocator.free(identity);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(identity, &digest, .{});
    const id = try std.fmt.allocPrint(allocator, "link:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer allocator.free(id);
    try conn.exec("insert into chat_links(link_id,workspace_id,parent_thread_id,local_thread_id) values(?,?,?,?) on conflict(workspace_id,parent_thread_id,local_thread_id) do update set hidden=0,delivery_enabled=1", .{ id, workspace, parent, child });
}

pub fn createTask(conn: zqlite.Conn, task: []const u8, workspace: []const u8, child: []const u8, owner: []const u8, now: i64) !void {
    try conn.exec("insert into chat_tasks(task_id,workspace_id,local_thread_id,owner,created_at_ms,updated_at_ms) values(?,?,?,?,?,?) on conflict(task_id) do nothing", .{ task, workspace, child, owner, now, now });
    var existing = (try conn.row("select workspace_id,local_thread_id,owner from chat_tasks where task_id=?", .{task})).?;
    defer existing.deinit();
    if (!std.mem.eql(u8, existing.text(0), workspace) or !std.mem.eql(u8, existing.text(1), child) or !std.mem.eql(u8, existing.text(2), owner)) return error.InvalidParams;
}

/// Messages sent to a busy child queue as separate turns that the provider
/// folds into one run, so they all finish together with the same reply.
/// The parent hears that outcome once, not once per queued message.
const same_run_window_ms: i64 = 30_000;

pub fn updateTask(conn: zqlite.Conn, task: []const u8, status: []const u8, summary: []const u8, approval: ?[]const u8, result: ?[]const u8, now: i64) !void {
    try conn.exec("savepoint chat_task_update", .{});
    errdefer conn.execNoArgs("rollback to chat_task_update; release chat_task_update") catch {};
    try conn.exec("update chat_tasks set status=?,summary=?,approval_json=?,result_json=?,updated_at_ms=?,revision=revision+1 where task_id=? and (status<>? or summary<>? or result_json is not ? or approval_json is not ?)", .{ status, summary, approval, result, now, task, status, summary, result, approval });
    if (!std.mem.eql(u8, status, "running")) {
        try conn.exec(
            \\insert or ignore into chat_deliveries(task_id,link_id,revision,status,summary)
            \\select t.task_id,l.link_id,t.revision,t.status,t.summary from chat_tasks t
            \\join chat_links l on l.workspace_id=t.workspace_id and l.local_thread_id=t.local_thread_id
            \\where t.task_id=? and l.delivery_enabled=1 and
        ++ ORIGIN_MATCHES_SQL ++
            \\
            \\and not (t.status='blocked' and exists(select 1 from chat_deliveries d where d.task_id=t.task_id and d.link_id=l.link_id and d.status=t.status and d.summary=t.summary))
            \\and not exists(select 1 from chat_deliveries d join chat_tasks o on o.task_id=d.task_id
            \\ where d.link_id=l.link_id and d.task_id<>t.task_id and d.status=t.status and d.summary=t.summary
            \\ and o.updated_at_ms>=t.updated_at_ms-?)
        , .{ task, same_run_window_ms });
    }
    try conn.execNoArgs("release chat_task_update");
}

/// Linked children of `parent` whose latest task is still working (the
/// writeTask notion: running, awaiting approval, or blocked mid-turn), plus
/// child results not yet delivered. Zero means the orchestration run settled.
/// `batch_turn` excludes the deliveries being handed over in that turn.
pub fn activeChildCount(conn: zqlite.Conn, workspace: []const u8, parent: []const u8, batch_turn: ?[]const u8) !usize {
    var row = (try conn.row(
        \\select (select count(*) from chat_links l
        \\ join chat_tasks k on k.task_id=(select task_id from chat_tasks where workspace_id=l.workspace_id and local_thread_id=l.local_thread_id order by created_at_ms desc,rowid desc limit 1)
        \\ where l.workspace_id=?1 and l.parent_thread_id=?2 and l.hidden=0 and l.delivery_enabled=1
        \\ and (k.status in ('running','waiting_approval') or (k.status='blocked' and k.result_json is null)))
        \\+ (select count(*) from chat_deliveries d join chat_links l on l.link_id=d.link_id
        \\ where l.workspace_id=?1 and l.parent_thread_id=?2 and l.delivery_enabled=1 and d.delivered=0
        \\ and (?3 is null or d.parent_turn_id is null or d.parent_turn_id<>?3))
    , .{ workspace, parent, batch_turn })) orelse return 0;
    defer row.deinit();
    return @intCast(@max(0, row.int(0)));
}

pub fn writeLinks(conn: zqlite.Conn, s: *std.json.Stringify, workspace: []const u8, parent: []const u8, include_hidden: bool) !void {
    var rows = try conn.rows(
        \\select l.link_id,l.local_thread_id,coalesce(t.title,l.local_thread_id),coalesce(t.provider,0),
        \\ coalesce(k.status,'idle'),coalesce(k.summary,''),k.task_id,coalesce(k.updated_at_ms,0),l.hidden
        \\from chat_links l join workspaces w on w.workspace_id=l.workspace_id
        \\left join threads t on t.workspace_id=w.id and t.local_thread_id=l.local_thread_id
        \\left join chat_tasks k on k.task_id=(select task_id from chat_tasks where workspace_id=l.workspace_id and local_thread_id=l.local_thread_id order by created_at_ms desc,rowid desc limit 1)
        \\where l.workspace_id=? and l.parent_thread_id=? and (? or l.hidden=0)
        \\order by coalesce(k.updated_at_ms,0) desc,l.link_id
    , .{ workspace, parent, include_hidden });
    defer rows.deinit();
    try s.beginObject();
    try s.objectField("links");
    try s.beginArray();
    const providers = [_][]const u8{ "opencode", "codex", "cursor", "claude", "pi", "fx", "grok", "muse" };
    while (rows.next()) |row| {
        const provider: usize = @intCast(@max(0, row.int(3)));
        try s.write(.{ .link_id = row.text(0), .workspace_id = workspace, .parent_thread_id = parent, .local_thread_id = row.text(1), .title = row.text(2), .provider = if (provider < providers.len) providers[provider] else "unknown", .status = row.text(4), .summary = row.text(5), .turn_id = row.nullableText(6), .updated_at_ms = row.int(7), .hidden = row.int(8) != 0 });
    }
    if (rows.err) |err| return err;
    try s.endArray();
    // Parent relationships remain navigable even when a parent hides its child row.
    try s.objectField("parents");
    try s.beginArray();
    var parents = try conn.rows(
        \\select l.link_id,l.parent_thread_id,coalesce(t.title,l.parent_thread_id),coalesce(t.provider,0)
        \\from chat_links l join workspaces w on w.workspace_id=l.workspace_id
        \\left join threads t on t.workspace_id=w.id and t.local_thread_id=l.parent_thread_id
        \\where l.workspace_id=? and l.local_thread_id=? order by l.parent_thread_id
    , .{ workspace, parent });
    defer parents.deinit();
    while (parents.next()) |row| {
        const provider: usize = @intCast(@max(0, row.int(3)));
        try s.write(.{ .link_id = row.text(0), .local_thread_id = row.text(1), .title = row.text(2), .provider = if (provider < providers.len) providers[provider] else "unknown" });
    }
    if (parents.err) |err| return err;
    try s.endArray();
    try s.endObject();
}

pub fn clear(conn: zqlite.Conn, workspace: []const u8, parent: []const u8, link_id: ?[]const u8, completed_only: bool) !void {
    try conn.exec(
        \\update chat_links set hidden=1,delivery_enabled=0 where workspace_id=? and parent_thread_id=? and (? is null or link_id=?)
        \\and (not ? or (select status from chat_tasks where workspace_id=chat_links.workspace_id and local_thread_id=chat_links.local_thread_id order by created_at_ms desc,rowid desc limit 1) in ('completed','failed','aborted','interrupted'))
    , .{ workspace, parent, link_id, link_id, completed_only });
    // Removing a child from the panel unlinks it: queued results are dropped
    // and it stops notifying the parent until the parent delegates to it again.
    try conn.exec("update chat_deliveries set delivered=1 where delivered=0 and link_id in (select link_id from chat_links where workspace_id=? and parent_thread_id=? and hidden=1)", .{ workspace, parent });
}

/// Write the MCP task representation from durable state, including its result.
pub fn writeTask(conn: zqlite.Conn, allocator: std.mem.Allocator, s: *std.json.Stringify, task: []const u8) !u64 {
    var row = (try conn.row("select status,summary,revision,approval_json,result_json,strftime('%Y-%m-%dT%H:%M:%fZ',created_at_ms/1000.0,'unixepoch'),strftime('%Y-%m-%dT%H:%M:%fZ',updated_at_ms/1000.0,'unixepoch') from chat_tasks where task_id=?", .{task})) orelse return error.ResourceNotFound;
    defer row.deinit();
    const status = row.text(0);
    const working = std.mem.eql(u8, status, "running") or (std.mem.eql(u8, status, "blocked") and row.nullableText(4) == null);
    const approval = std.mem.eql(u8, status, "waiting_approval");
    const cancelled = std.mem.eql(u8, status, "aborted");
    try s.beginObject();
    try s.objectField("taskId");
    try s.write(task);
    try s.objectField("status");
    try s.write(if (working) "working" else if (approval) "input_required" else if (cancelled) "cancelled" else "completed");
    try s.objectField("statusMessage");
    try s.write(row.text(1));
    try s.objectField("createdAt");
    try s.write(row.text(5));
    try s.objectField("lastUpdatedAt");
    try s.write(row.text(6));
    try s.objectField("ttlMs");
    try s.write(null);
    if (approval) {
        try s.objectField("inputRequests");
        if (row.nullableText(3)) |raw| {
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
            defer parsed.deinit();
            try s.write(parsed.value);
        } else try s.write(.{});
    } else if (!working and !cancelled) {
        try s.objectField("result");
        if (row.nullableText(4)) |raw| {
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
            defer parsed.deinit();
            try s.write(parsed.value);
        } else try s.write(.{ .content = .{.{ .type = "text", .text = row.text(1) }}, .isError = !std.mem.eql(u8, status, "completed") });
    }
    try s.endObject();
    return @intCast(row.int(2));
}

/// Reconcile the small crash window between transcript commit and task
/// publication, recovering the final assistant result from the durable turn.
pub fn recoverTasks(conn: zqlite.Conn, allocator: std.mem.Allocator, now: i64) !void {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Pending = struct { id: []const u8, status: []const u8, summary: []const u8 };
    var pending: std.ArrayList(Pending) = .empty;
    {
        var rows = try conn.rows(
            \\select k.task_id,
            \\ case when k.status='blocked' and t.status='completed' then 'blocked' else coalesce(t.status,'interrupted') end,
            \\ case when k.status='blocked' then k.summary else coalesce(
            \\ (select m.body from messages m join threads h on h.id=m.thread_id join workspaces w on w.id=h.workspace_id
            \\ where w.workspace_id=k.workspace_id and h.local_thread_id=k.local_thread_id and m.role=1
            \\ and substr(m.message_id,1,length('turn:'||k.task_id||':msg:'))='turn:'||k.task_id||':msg:' order by m.sort_index desc limit 1),
            \\ t.error_message,'Daemon restarted before the task completed') end
            \\from chat_tasks k left join chat_turns t on t.turn_id=k.task_id
            \\where k.status in ('running','waiting_approval') or (k.status='blocked' and k.result_json is null)
        , .{});
        defer rows.deinit();
        while (rows.next()) |row| try pending.append(arena, .{ .id = try arena.dupe(u8, row.text(0)), .status = try arena.dupe(u8, row.text(1)), .summary = try arena.dupe(u8, row.text(2)) });
        if (rows.err) |err| return err;
    }
    for (pending.items) |item| {
        const result = try std.json.Stringify.valueAlloc(arena, .{ .content = .{.{ .type = "text", .text = item.summary }}, .isError = !std.mem.eql(u8, item.status, "completed") }, .{});
        try updateTask(conn, item.id, item.status, item.summary, null, result, now);
        // Work cut short by the restart itself is not news for the parent;
        // waking it would start a turn nobody asked for.
        if (std.mem.eql(u8, item.status, "interrupted")) try conn.exec("update chat_deliveries set delivered=1 where task_id=? and delivered=0", .{item.id});
    }
}

test "removing a linked chat stops parent delivery" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs(@import("../db/chat_links_schema.zig").SCHEMA_SQL);
    try initialize(conn);
    try conn.execNoArgs("insert into chat_links(link_id,workspace_id,parent_thread_id,local_thread_id) values('l','w','p','c')");
    try createTask(conn, "t1", "w", "c", "verde", 1);
    try updateTask(conn, "t1", "completed", "queued", null, null, 2);
    try clear(conn, "w", "p", "l", false);
    var pending = (try conn.row("select count(*) from chat_deliveries where delivered=0", .{})).?;
    try std.testing.expectEqual(@as(i64, 0), pending.int(0));
    pending.deinit();
    try createTask(conn, "t2", "w", "c", "verde", 3);
    try updateTask(conn, "t2", "completed", "after removal", null, null, 4);
    var rows = (try conn.row("select count(*) from chat_deliveries where task_id='t2'", .{})).?;
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 0), rows.int(0));
}

test "turns folded into one child run notify the parent once" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs(@import("../db/chat_links_schema.zig").SCHEMA_SQL);
    try initialize(conn);
    try conn.execNoArgs("insert into chat_links(link_id,workspace_id,parent_thread_id,local_thread_id) values('l','w','p','c')");
    try createTask(conn, "t1", "w", "c", "verde", 1);
    try createTask(conn, "t2", "w", "c", "verde", 2);
    try createTask(conn, "t3", "w", "c", "verde", 3);
    try updateTask(conn, "t1", "completed", "same reply", null, null, 100_000);
    try updateTask(conn, "t2", "completed", "same reply", null, null, 100_300);
    try updateTask(conn, "t3", "completed", "different reply", null, null, 100_400);
    var folded = (try conn.row("select count(*) from chat_deliveries", .{})).?;
    try std.testing.expectEqual(@as(i64, 2), folded.int(0));
    folded.deinit();
    // A later run that happens to repeat the reply is still news.
    try createTask(conn, "t4", "w", "c", "verde", 4);
    try updateTask(conn, "t4", "completed", "same reply", null, null, 500_000);
    var later = (try conn.row("select count(*) from chat_deliveries where task_id='t4'", .{})).?;
    defer later.deinit();
    try std.testing.expectEqual(@as(i64, 1), later.int(0));
}

test "delegated work notifies only the parent that asked for it" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs(@import("../db/chat_links_schema.zig").SCHEMA_SQL);
    try initialize(conn);
    try conn.execNoArgs("insert into chat_links(link_id,workspace_id,parent_thread_id,local_thread_id) values('l1','w','p1','c'),('l2','w','p2','c')");
    try createTask(conn, "asked", "w", "c", "mcp", 1);
    try setOrigin(conn, "asked", "p1");
    try updateTask(conn, "asked", "completed", "done for p1", null, null, 2);
    var asked = (try conn.row("select group_concat(link_id) from chat_deliveries where task_id='asked'", .{})).?;
    try std.testing.expectEqualStrings("l1", asked.text(0));
    asked.deinit();
    // A human turn in the shared child has no origin and reaches every parent.
    try createTask(conn, "human", "w", "c", "verde", 3);
    try updateTask(conn, "human", "completed", "human asked", null, null, 4);
    var human = (try conn.row("select count(*) from chat_deliveries where task_id='human'", .{})).?;
    try std.testing.expectEqual(@as(i64, 2), human.int(0));
    human.deinit();
    // A resume continues the previous delegated task, so it inherits its parent.
    try createTask(conn, "blocked", "w", "c", "mcp", 5);
    try setOrigin(conn, "blocked", "p2");
    try createTask(conn, "resume:x", "w", "c", "verde", 6);
    try inheritOrigin(conn, "resume:x", "w", "c");
    try updateTask(conn, "resume:x", "completed", "resumed", null, null, 7);
    var resumed = (try conn.row("select group_concat(link_id) from chat_deliveries where task_id='resume:x'", .{})).?;
    defer resumed.deinit();
    try std.testing.expectEqualStrings("l2", resumed.text(0));
}

test "active child count tracks working children and undelivered results" {
    var conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try conn.execNoArgs(@import("../db/chat_links_schema.zig").SCHEMA_SQL);
    try initialize(conn);
    try conn.execNoArgs("insert into chat_links(link_id,workspace_id,parent_thread_id,local_thread_id) values('l1','w','p','c1'),('l2','w','p','c2')");
    try createTask(conn, "t1", "w", "c1", "mcp", 1);
    try createTask(conn, "t2", "w", "c2", "mcp", 1);
    try std.testing.expectEqual(@as(usize, 2), try activeChildCount(conn, "w", "p", null));
    try updateTask(conn, "t1", "completed", "one", null, null, 2);
    // c2 still running, t1's result not yet handed over.
    try std.testing.expectEqual(@as(usize, 2), try activeChildCount(conn, "w", "p", null));
    try conn.execNoArgs("update chat_deliveries set parent_turn_id='child-event:batch'");
    try std.testing.expectEqual(@as(usize, 1), try activeChildCount(conn, "w", "p", "child-event:batch"));
    try updateTask(conn, "t2", "completed", "two", "{}", "{}", 3);
    try conn.execNoArgs("update chat_deliveries set delivered=1");
    try std.testing.expectEqual(@as(usize, 0), try activeChildCount(conn, "w", "p", null));
}
