//! Scheduled tasks fixture harness; loopback-free, no daemon.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const schedules = @import("schedules.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"clock","label":"Clock","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;
const all_scopes: []const []const u8 = &.{ "chat:read", "chat:write" };

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: h.Host,
    serial: u64 = 1,
    now: i64 = 1,

    fn init(scopes: []const []const u8) !Fixture {
        var host = try h.Host.init(std.testing.allocator, config);
        errdefer host.deinit();
        var tx = try h.Transaction.init(&host);
        defer tx.deinit();
        tx.state.lifecycle = .foreground;
        tx.state.network_available = true;
        tx.state.auth.profile_loaded = false;
        tx.state.auth.credential = .{ .runtime_id = "0123456789abcdef0123456789abcdef", .device_id = "fixture", .device_credential = "fixture", .scopes = scopes };
        try rpc.attachBearer(&tx, "fixture-token", "0123456789abcdef0123456789abcdef", "fixture-pin");
        tx.state.rpc.instance_id = "00112233445566778899aabbccddeeff";
        tx.state.rpc.phase = .ready;
        const output = try tx.commit(&host, std.testing.allocator);
        std.testing.allocator.free(output);
        return .{ .arena = .init(std.testing.allocator), .host = host };
    }
    fn deinit(f: *Fixture) void {
        f.host.deinit();
        f.arena.deinit();
    }
    fn a(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }
    fn event(f: *Fixture, tag: []const u8, payload: anytype) !V {
        var v = try h.parseLimit(f.a(), try h.encode(f.a(), payload), h.MAX_HTTP_INPUT);
        if (v != .object) v = .{ .object = .empty };
        try v.object.put(f.a(), "type", .{ .string = tag });
        try v.object.put(f.a(), "api_version", .{ .integer = 1 });
        try v.object.put(f.a(), "now_ms", .{ .integer = f.now });
        try v.object.put(f.a(), "wall_time_ms", .{ .integer = 1790363191000 + f.now });
        return h.parseLimit(f.a(), try f.host.handle(try h.encode(f.a(), v), f.a()), h.MAX_HTTP_INPUT);
    }
    fn intent(f: *Fixture, tag: []const u8, payload: anytype) ![]const u8 {
        var v = try h.parseLimit(f.a(), try h.encode(f.a(), payload), h.MAX_HTTP_INPUT);
        if (v != .object) v = .{ .object = .empty };
        const id = try std.fmt.allocPrint(f.a(), "intent-{d}", .{f.serial});
        f.serial += 1;
        try v.object.put(f.a(), "intent_id", .{ .string = id });
        _ = try f.event(tag, v);
        return id;
    }
    fn pending(f: *Fixture, method: []const u8) usize {
        var n: usize = 0;
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, method)) {
            n += 1;
        };
        return n;
    }
    fn find(f: *Fixture, method: []const u8) !rpc.Call {
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, method)) return call;
        return error.MissingRequest;
    }
    fn params(f: *Fixture, method: []const u8) !V {
        const call = try f.find(method);
        const bytes = try @import("auth.zig").decode64(f.a(), call.body_base64);
        return p.get(try h.parse(f.a(), bytes), "params");
    }
    fn respond(f: *Fixture, call: rpc.Call, body: []const u8) !V {
        return f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(f.a(), body), .@"error" = @as(?u8, null) });
    }
    fn reply(f: *Fixture, method: []const u8, result: []const u8) !V {
        const call = try f.find(method);
        return f.respond(call, try std.fmt.allocPrint(f.a(), "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ call.id, result }));
    }
    fn reject(f: *Fixture, method: []const u8, code: []const u8) !V {
        const call = try f.find(method);
        return f.respond(call, try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .@"error" = .{ .code = code, .message = "rejected" } }));
    }
    fn view(f: *Fixture) !V {
        const q = try h.parse(f.a(), try f.host.query("schedules", f.a()));
        try expect(p.get(q, "error") == .null);
        return p.get(q, "data");
    }
    fn receipt(f: *Fixture, id: []const u8) !h.Operation {
        for (f.host.state.receipts) |r| if (h.eq(r.operation.intent_id, id)) return r.operation;
        return error.MissingReceipt;
    }
    fn failed(f: *Fixture, id: []const u8) ![]const u8 {
        const op = try f.receipt(id);
        try eql("failed", op.state);
        return op.@"error".?.code;
    }
    /// Answers the list read a mutation queues.
    fn relist(f: *Fixture, result: []const u8) !void {
        try expect(f.pending("schedule.list") == 1);
        _ = try f.reply("schedule.list", result);
    }
};

const daily_json =
    \\{"id":"sch-1","name":"Morning CI check","prompt":"Check CI.","target":{"kind":"thread","workspace_id":"ws","thread_id":"t1"},
    \\ "repeat":{"kind":"daily","time":"09:00","weekdays":[1,2,3,4,5]},"enabled":true,"parent_workspace_id":"ws","parent_thread_id":"t1",
    \\ "created_by":"companion","next_run_ms":1792470000000,"last_run_ms":1792383600000,"last_status":"ok","last_error":null,
    \\ "last_thread_id":"t1","run_count":12,"created_at_ms":1792300000000,"updated_at_ms":1792383600000}
;
const interval_json =
    \\{"id":"sch-2","name":"Every two hours","prompt":"Ping.","target":{"kind":"new_chat","workspace_id":"ws2","provider":"claude","model":"opus"},
    \\ "repeat":{"kind":"interval","every_minutes":120},"enabled":false,"created_by":"cli","next_run_ms":null,"last_status":null,"run_count":0}
;
const list_json = "{\"now_ms\":1792400000000,\"schedules\":[" ++ daily_json ++ "," ++ interval_json ++ ",{\"name\":\"no id\"}]}";
const empty_list = "{\"now_ms\":1792400000000,\"schedules\":[]}";

const thread_target = schedules.Target{ .kind = "thread", .workspace_id = "ws", .thread_id = "t1" };
const daily = schedules.Repeat{ .kind = "daily", .time = "09:00", .weekdays = &.{ 1, 2, 3, 4, 5 } };

test "refresh decodes the daemon list into flattened rows and coalesces reads" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const id = try f.intent("schedule_refresh", .{});
    try eql("pending", (try f.receipt(id)).state);
    try expect(p.yes(p.get(try f.view(), "loading")));
    try expect(p.get(try f.params("schedule.list"), "workspace_id") == .null);
    // A second refresh joins the read in flight.
    const again = try f.intent("schedule_refresh", .{});
    try eql("succeeded", (try f.receipt(again)).state);
    try expect(f.pending("schedule.list") == 1);
    _ = try f.reply("schedule.list", list_json);
    try eql("succeeded", (try f.receipt(id)).state);
    const view = try f.view();
    try expect(p.yes(p.get(view, "loaded")));
    try expect(!p.yes(p.get(view, "loading")));
    try expect(p.yes(p.get(view, "can_edit")));
    try expect(p.num(p.get(view, "now_ms")).? == 1792400000000);
    const rows = p.rows(p.get(view, "schedules"));
    try expect(rows.len == 2);
    const first = rows[0];
    try eql("sch-1", p.s(first, "id"));
    try eql("Morning CI check", p.s(first, "name"));
    try eql("thread", p.s(first, "target_kind"));
    try eql("ws", p.s(first, "target_workspace_id"));
    try eql("t1", p.s(first, "target_thread_id"));
    try eql("daily", p.s(first, "repeat_kind"));
    try eql("09:00", p.s(first, "repeat_time"));
    try expect(p.rows(p.get(first, "repeat_weekdays")).len == 5);
    try expect(p.get(first, "repeat_every_minutes") == .null);
    try expect(p.yes(p.get(first, "enabled")));
    try eql("ok", p.s(first, "last_status"));
    try expect(p.get(first, "last_error") == .null);
    try expect(p.num(p.get(first, "next_run_ms")).? == 1792470000000);
    try expect(p.num(p.get(first, "run_count")).? == 12);
    try eql("companion", p.s(first, "created_by"));
    const second = rows[1];
    try eql("new_chat", p.s(second, "target_kind"));
    try eql("claude", p.s(second, "target_provider"));
    try eql("opus", p.s(second, "target_model"));
    try eql("interval", p.s(second, "repeat_kind"));
    try expect(p.num(p.get(second, "repeat_every_minutes")).? == 120);
    try expect(!p.yes(p.get(second, "enabled")));
    try expect(p.get(second, "next_run_ms") == .null);
    try expect(p.get(second, "last_status") == .null);
    try eql("", p.s(second, "target_thread_id"));

    // A workspace filter is forwarded and remembered.
    _ = try f.intent("schedule_refresh", .{ .workspace_id = "ws" });
    try eql("ws", p.s(try f.params("schedule.list"), "workspace_id"));
    try eql("ws", p.s(try f.view(), "workspace_id"));
}

test "an old host is unsupported and an unreadable list fails without dropping rows" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const id = try f.intent("schedule_refresh", .{});
    _ = try f.reject("schedule.list", "method_not_found");
    try eql("method_not_found", try f.failed(id));
    try expect(!p.yes(p.get(try f.view(), "supported")));
    const blocked = try f.intent("schedule_run", .{ .id = "sch-1" });
    try eql("unsupported", try f.failed(blocked));
    try expect(f.pending("schedule.run") == 0);

    var g = try Fixture.init(all_scopes);
    defer g.deinit();
    _ = try g.intent("schedule_refresh", .{});
    _ = try g.reply("schedule.list", list_json);
    const bad = try g.intent("schedule_refresh", .{});
    _ = try g.reply("schedule.list", "{\"now_ms\":1}");
    try eql("invalid_schedules", try g.failed(bad));
    const view = try g.view();
    try eql("invalid_schedules", p.s(p.get(view, "error"), "code"));
    try expect(p.rows(p.get(view, "schedules")).len == 2);
}

test "create sends the RPC shape, shows the schedule at once and re-reads the list" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const id = try f.intent("schedule_create", .{
        .name = "  ",
        .prompt = "Check CI.",
        .target = thread_target,
        .repeat = daily,
        .parent_workspace_id = "ws",
        .parent_thread_id = "t1",
    });
    try eql("pending", (try f.receipt(id)).state);
    try expect(p.yes(p.get(try f.view(), "saving")));
    const sent = try f.params("schedule.create");
    // A blank name is omitted so the daemon derives one; the phone labels itself.
    try expect(p.get(sent, "name") == .null);
    try eql("Check CI.", p.s(sent, "prompt"));
    try eql("mobile", p.s(sent, "created_by"));
    try eql("t1", p.s(sent, "parent_thread_id"));
    try expect(p.get(sent, "enabled") == .null);
    const target = p.get(sent, "target");
    try eql("thread", p.s(target, "kind"));
    try eql("ws", p.s(target, "workspace_id"));
    try eql("t1", p.s(target, "thread_id"));
    try expect(p.get(target, "provider") == .null);
    const repeat = p.get(sent, "repeat");
    try eql("daily", p.s(repeat, "kind"));
    try eql("09:00", p.s(repeat, "time"));
    try expect(p.rows(p.get(repeat, "weekdays")).len == 5);
    try expect(p.get(repeat, "at_ms") == .null);
    try expect(f.pending("schedule.list") == 0);

    _ = try f.reply("schedule.create", "{\"schedule\":" ++ daily_json ++ "}");
    try eql("succeeded", (try f.receipt(id)).state);
    var view = try f.view();
    try expect(!p.yes(p.get(view, "saving")));
    try expect(p.rows(p.get(view, "schedules")).len == 1);
    try eql("sch-1", p.s(p.rows(p.get(view, "schedules"))[0], "id"));
    try f.relist(list_json);
    view = try f.view();
    try expect(p.rows(p.get(view, "schedules")).len == 2);

    // A new chat target sends provider/model and only the repeat kind's own fields.
    const other = try f.intent("schedule_create", .{
        .name = "Hourly",
        .prompt = "Ping.",
        .target = schedules.Target{ .kind = "new_chat", .workspace_id = "ws2", .provider = "claude", .model = "opus", .thread_id = "ignored" },
        .repeat = schedules.Repeat{ .kind = "interval", .every_minutes = 60, .time = "10:00" },
        .enabled = false,
        .created_by = "companion",
    });
    const sent2 = try f.params("schedule.create");
    try eql("Hourly", p.s(sent2, "name"));
    try eql("companion", p.s(sent2, "created_by"));
    try expect(p.get(sent2, "enabled") == .bool and !p.yes(p.get(sent2, "enabled")));
    try eql("claude", p.s(p.get(sent2, "target"), "provider"));
    try eql("opus", p.s(p.get(sent2, "target"), "model"));
    try expect(p.get(p.get(sent2, "target"), "thread_id") == .null);
    try expect(p.num(p.get(p.get(sent2, "repeat"), "every_minutes")).? == 60);
    try expect(p.get(p.get(sent2, "repeat"), "time") == .null);
    _ = try f.reject("schedule.create", "invalid_params");
    try eql("invalid_params", try f.failed(other));
    // A failed write still re-reads, since the daemon may have changed anyway.
    try expect(f.pending("schedule.list") == 1);
}

test "update, run and delete settle receipts, patch rows and refresh" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    _ = try f.intent("schedule_refresh", .{});
    _ = try f.reply("schedule.list", list_json);

    const toggle = try f.intent("schedule_update", .{ .id = "sch-1", .enabled = false });
    const sent = try f.params("schedule.update");
    try eql("sch-1", p.s(sent, "id"));
    try expect(p.get(sent, "enabled") == .bool and !p.yes(p.get(sent, "enabled")));
    try expect(p.get(sent, "name") == .null);
    try expect(p.get(sent, "repeat") == .null);
    var view = try f.view();
    try eql("sch-1", p.str(p.rows(p.get(view, "busy_ids"))[0]));
    const disabled = try std.mem.replaceOwned(u8, f.a(), daily_json, "\"enabled\":true", "\"enabled\":false");
    _ = try f.reply("schedule.update", try std.fmt.allocPrint(f.a(), "{{\"schedule\":{s}}}", .{disabled}));
    try eql("succeeded", (try f.receipt(toggle)).state);
    view = try f.view();
    try expect(p.rows(p.get(view, "busy_ids")).len == 0);
    // The confirmed row replaces the old one in place (both disabled now, so next run decides).
    const rows = p.rows(p.get(view, "schedules"));
    try expect(rows.len == 2);
    try eql("sch-1", p.s(rows[0], "id"));
    try expect(!p.yes(p.get(rows[0], "enabled")));
    try f.relist(list_json);

    const run = try f.intent("schedule_run", .{ .id = "sch-1" });
    try eql("sch-1", p.s(try f.params("schedule.run"), "id"));
    _ = try f.reply("schedule.run", "{\"schedule\":" ++ daily_json ++ ",\"thread_id\":\"t1\",\"turn_id\":\"turn-9\"}");
    try eql("succeeded", (try f.receipt(run)).state);
    const last = p.get(try f.view(), "last_run");
    try eql(run, p.s(last, "intent_id"));
    try eql("sch-1", p.s(last, "schedule_id"));
    try eql("ws", p.s(last, "workspace_id"));
    try eql("t1", p.s(last, "thread_id"));
    try eql("turn-9", p.s(last, "turn_id"));
    try f.relist(list_json);

    const delete = try f.intent("schedule_delete", .{ .id = "sch-2" });
    try eql("sch-2", p.s(try f.params("schedule.delete"), "id"));
    _ = try f.reply("schedule.delete", "{\"deleted\":true}");
    try eql("succeeded", (try f.receipt(delete)).state);
    try expect(p.rows(p.get(try f.view(), "schedules")).len == 1);
    try f.relist("{\"now_ms\":1,\"schedules\":[" ++ daily_json ++ "]}");

    // Unknown ids: delete is already done, run/update fail and drop the stale row.
    const gone = try f.intent("schedule_delete", .{ .id = "sch-9" });
    _ = try f.reject("schedule.delete", "not_found");
    try eql("succeeded", (try f.receipt(gone)).state);
    try f.relist("{\"now_ms\":1,\"schedules\":[" ++ daily_json ++ "]}");
    const missing = try f.intent("schedule_run", .{ .id = "sch-1" });
    _ = try f.reject("schedule.run", "not_found");
    try eql("not_found", try f.failed(missing));
    try expect(p.rows(p.get(try f.view(), "schedules")).len == 0);
}

test "a mutation finishing during a read queues one more read" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    _ = try f.intent("schedule_refresh", .{});
    _ = try f.intent("schedule_delete", .{ .id = "sch-2" });
    _ = try f.reply("schedule.delete", "{\"deleted\":true}");
    try expect(f.pending("schedule.list") == 1);
    _ = try f.reply("schedule.list", list_json);
    // The first read may predate the delete: read once more.
    try expect(f.pending("schedule.list") == 1);
    try f.relist("{\"now_ms\":1,\"schedules\":[" ++ daily_json ++ "]}");
    try expect(f.pending("schedule.list") == 0);
    try expect(p.rows(p.get(try f.view(), "schedules")).len == 1);
}

test "validation fails locally with no RPC" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const long_prompt = try f.a().alloc(u8, schedules.MAX_PROMPT_BYTES + 1);
    @memset(long_prompt, 'x');
    const long_name = try f.a().alloc(u8, schedules.MAX_NAME_BYTES + 1);
    @memset(long_name, 'n');
    const Case = struct { code: []const u8, name: ?[]const u8 = null, prompt: []const u8 = "Do it.", target: schedules.Target = thread_target, repeat: schedules.Repeat = daily };
    const cases = [_]Case{
        .{ .code = "invalid_prompt", .prompt = " \n " },
        .{ .code = "invalid_prompt", .prompt = long_prompt },
        .{ .code = "invalid_name", .name = long_name },
        .{ .code = "invalid_target", .target = .{ .kind = "thread", .workspace_id = "ws" } },
        .{ .code = "invalid_target", .target = .{ .kind = "thread", .workspace_id = "", .thread_id = "t1" } },
        .{ .code = "invalid_target", .target = .{ .kind = "elsewhere", .workspace_id = "ws" } },
        .{ .code = "invalid_provider", .target = .{ .kind = "new_chat", .workspace_id = "ws" } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "once" } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "once", .at_ms = -5 } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "interval", .every_minutes = 4 } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "interval", .every_minutes = 10081 } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "interval" } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "daily", .time = "24:00" } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "daily", .time = "9:00" } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "daily" } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "daily", .time = "09:00", .weekdays = &.{7} } },
        .{ .code = "invalid_repeat", .repeat = .{ .kind = "weekly", .time = "09:00" } },
    };
    for (cases) |c| {
        const id = try f.intent("schedule_create", .{ .name = c.name, .prompt = c.prompt, .target = c.target, .repeat = c.repeat });
        eql(c.code, try f.failed(id)) catch |err| {
            std.debug.print("\ncase {s} prompt={d}B target={s} repeat={s}\n", .{ c.code, c.prompt.len, c.target.kind, c.repeat.kind });
            return err;
        };
    }
    // Updates check only what they change; the boundaries themselves are accepted.
    try eql("invalid_name", try f.failed(try f.intent("schedule_update", .{ .id = "sch-1", .name = "" })));
    try eql("invalid_repeat", try f.failed(try f.intent("schedule_update", .{ .id = "sch-1", .repeat = schedules.Repeat{ .kind = "daily", .time = "12:60" } })));
    try eql("invalid_schedule", try f.failed(try f.intent("schedule_update", .{ .id = "", .enabled = true })));
    try eql("invalid_schedule", try f.failed(try f.intent("schedule_delete", .{ .id = "" })));
    try eql("invalid_schedule", try f.failed(try f.intent("schedule_run", .{ .id = "" })));
    try eql("invalid_workspace", try f.failed(try f.intent("schedule_refresh", .{ .workspace_id = "" })));
    try expect(f.host.state.rpc.calls.len == 0);
    try expect(schedules.validTime("00:00") and schedules.validTime("23:59"));

    const edge = try f.intent("schedule_create", .{ .prompt = "Do it.", .target = thread_target, .repeat = schedules.Repeat{ .kind = "interval", .every_minutes = schedules.MIN_EVERY_MINUTES } });
    try eql("pending", (try f.receipt(edge)).state);
    const week = try f.intent("schedule_update", .{ .id = "sch-1", .repeat = schedules.Repeat{ .kind = "interval", .every_minutes = schedules.MAX_EVERY_MINUTES } });
    try eql("pending", (try f.receipt(week)).state);
    const every_day = try f.intent("schedule_update", .{ .id = "sch-1", .repeat = schedules.Repeat{ .kind = "daily", .time = "23:59" } });
    try eql("pending", (try f.receipt(every_day)).state);
    // `weekdays` absent means every day: an empty list is sent.
    try expect(f.pending("schedule.update") == 2);
}

test "missing scopes deny locally, offline fails, and signing out clears the list" {
    var r = try Fixture.init(&.{"chat:read"});
    defer r.deinit();
    _ = try r.intent("schedule_refresh", .{});
    _ = try r.reply("schedule.list", list_json);
    try expect(!p.yes(p.get(try r.view(), "can_edit")));
    inline for (.{
        .{ "schedule_create", .{ .prompt = "Do it.", .target = thread_target, .repeat = daily } },
        .{ "schedule_update", .{ .id = "sch-1", .enabled = false } },
        .{ "schedule_delete", .{ .id = "sch-1" } },
        .{ "schedule_run", .{ .id = "sch-1" } },
    }) |case| {
        const denied = try r.intent(case[0], case[1]);
        try eql("insufficient_scope", try r.failed(denied));
    }
    try expect(r.host.state.rpc.calls.len == 0);

    var w = try Fixture.init(&.{"chat:write"});
    defer w.deinit();
    const unread = try w.intent("schedule_refresh", .{});
    try eql("insufficient_scope", try w.failed(unread));
    try expect(w.pending("schedule.list") == 0);
    // Without chat:read a write still goes through but is not followed by a read.
    const run = try w.intent("schedule_run", .{ .id = "sch-1" });
    _ = try w.reply("schedule.run", "{\"schedule\":" ++ daily_json ++ ",\"thread_id\":\"t1\"}");
    try eql("succeeded", (try w.receipt(run)).state);
    try expect(w.pending("schedule.list") == 0);
    try expect(p.get(p.get(try w.view(), "last_run"), "turn_id") == .null);

    var o = try Fixture.init(all_scopes);
    defer o.deinit();
    _ = try o.intent("schedule_refresh", .{});
    _ = try o.reply("schedule.list", list_json);
    _ = try o.event("network_changed", .{ .available = false, .network_id = "" });
    const offline = try o.intent("schedule_run", .{ .id = "sch-1" });
    try eql("offline", try o.failed(offline));
    try expect(!p.yes(p.get(try o.view(), "can_edit")));
    var tx = try h.Transaction.init(&o.host);
    defer tx.deinit();
    tx.state.auth.credential = null;
    schedules.observe(&tx);
    try expect(tx.state.schedules.view.schedules.len == 0 and !tx.state.schedules.view.loaded);
}

test "the same intent id replays its receipt without a second RPC" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const payload = .{ .intent_id = "same", .prompt = "Do it.", .target = thread_target, .repeat = daily };
    _ = try f.event("schedule_create", payload);
    _ = try f.event("schedule_create", payload);
    try expect(f.pending("schedule.create") == 1);
    // A different body under the same id is a contract violation.
    try std.testing.expectError(error.InvalidArgument, f.event("schedule_create", .{ .intent_id = "same", .prompt = "Other.", .target = thread_target, .repeat = daily }));
}
