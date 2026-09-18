//! Durable orchestration links, task state, and parent notification outbox.
const std = @import("std");
const zqlite = @import("zqlite");

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

pub fn updateTask(conn: zqlite.Conn, task: []const u8, status: []const u8, summary: []const u8, approval: ?[]const u8, result: ?[]const u8, now: i64) !void {
    try conn.exec("savepoint chat_task_update", .{});
    errdefer conn.execNoArgs("rollback to chat_task_update; release chat_task_update") catch {};
    try conn.exec("update chat_tasks set status=?,summary=?,approval_json=?,result_json=?,updated_at_ms=?,revision=revision+1 where task_id=? and (status<>? or summary<>? or result_json is not ? or approval_json is not ?)", .{ status, summary, approval, result, now, task, status, summary, result, approval });
    if (!std.mem.eql(u8, status, "running")) {
        try conn.exec(
            \\insert or ignore into chat_deliveries(task_id,link_id,revision,status,summary)
            \\select t.task_id,l.link_id,t.revision,t.status,t.summary from chat_tasks t
            \\join chat_links l on l.workspace_id=t.workspace_id and l.local_thread_id=t.local_thread_id
            \\where t.task_id=? and l.delivery_enabled=1
            \\and not (t.status='blocked' and exists(select 1 from chat_deliveries d where d.task_id=t.task_id and d.link_id=l.link_id and d.status=t.status and d.summary=t.summary))
        , .{task});
    }
    try conn.execNoArgs("release chat_task_update");
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
        \\update chat_links set hidden=1 where workspace_id=? and parent_thread_id=? and (? is null or link_id=?)
        \\and (not ? or (select status from chat_tasks where workspace_id=chat_links.workspace_id and local_thread_id=chat_links.local_thread_id order by created_at_ms desc,rowid desc limit 1) in ('completed','failed','aborted','interrupted'))
    , .{ workspace, parent, link_id, link_id, completed_only });
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
    }
}
