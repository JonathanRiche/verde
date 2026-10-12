//! Companion roster/crew fixture harness; loopback-free, no daemon.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const companion = @import("companion.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"buddy","label":"Buddy","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
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
        const q = try h.parse(f.a(), try f.host.query("companion", f.a()));
        try expect(p.get(q, "error") == .null);
        return p.get(q, "data");
    }
    fn receipt(f: *Fixture, id: []const u8) !h.Operation {
        for (f.host.state.receipts) |r| if (h.eq(r.operation.intent_id, id)) return r.operation;
        return error.MissingReceipt;
    }
};

fn announced(output: V, scope: []const u8) bool {
    for (p.rows(p.get(output, "effects"))) |effect| if (h.eq(p.s(effect, "type"), "state_changed")) {
        for (p.rows(p.get(effect, "scopes"))) |s| if (h.eq(p.str(s), scope)) return true;
    };
    return false;
}

const roster_json =
    \\{"revision":3,"roster":{"version":1,"active_id":"c1","future":true,"companions":[
    \\ {"id":"c1","name":"Juniper","character":"moss","home_workspace_id":"ws","thread_id":"t1","provider":"claude","model":"opus","orders":"Run tests."},
    \\ {"id":"c2","name":"Wren","character":"dragon"},
    \\ {"name":"no id"}
    \\]}}
;

test "roster refresh reads leniently, coalesces and announces the companion selector" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    var view = try f.view();
    try expect(!p.yes(p.get(view, "loaded")));
    const first = try f.intent("companion_refresh", .{});
    try eql("pending", (try f.receipt(first)).state);
    const second = try f.intent("companion_refresh", .{});
    try eql("succeeded", (try f.receipt(second)).state);
    try expect(f.pending("companion.roster.get") == 1);
    const out = try f.reply("companion.roster.get", roster_json);
    try expect(announced(out, "companion"));
    try eql("succeeded", (try f.receipt(first)).state);
    view = try f.view();
    try expect(p.yes(p.get(view, "loaded")) and p.yes(p.get(view, "can_edit")));
    try eql("3", p.s(view, "revision"));
    const roster = p.get(view, "roster");
    try eql("c1", p.s(roster, "active_id"));
    const list = p.rows(p.get(roster, "companions"));
    try expect(list.len == 2);
    try eql("Juniper", p.s(list[0], "name"));
    try eql("moss", p.s(list[0], "character"));
    try eql("Run tests.", p.s(list[0], "orders"));
    // Unknown characters fall back to Sprout; missing fields read as empty.
    try eql("sprout", p.s(list[1], "character"));
    try eql("", p.s(list[1], "thread_id"));
}

test "save sends the roster at the expected revision and adopts the new revision" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    _ = try f.intent("companion_refresh", .{});
    _ = try f.reply("companion.roster.get", "{\"revision\":0,\"roster\":{\"version\":1,\"active_id\":\"\",\"companions\":[]}}");
    const roster = companion.Roster{ .active_id = "a", .companions = &.{.{ .id = "a", .name = "Sprout", .home_workspace_id = "ws" }} };
    const save = try f.intent("companion_save", .{ .roster = roster, .expected_revision = "0" });
    try eql("pending", (try f.receipt(save)).state);
    try expect(p.yes(p.get(try f.view(), "saving")));
    const sent = try f.params("companion.roster.put");
    try expect(p.num(p.get(sent, "expected_revision")).? == 0);
    try eql("Sprout", p.s(p.rows(p.get(p.get(sent, "roster"), "companions"))[0], "name"));
    // Only one write at a time.
    const busy = try f.intent("companion_save", .{ .roster = roster, .expected_revision = "0" });
    try eql("busy", (try f.receipt(busy)).@"error".?.code);
    _ = try f.reply("companion.roster.put", "{\"revision\":1}");
    try eql("succeeded", (try f.receipt(save)).state);
    const view = try f.view();
    try expect(!p.yes(p.get(view, "saving")));
    try eql("1", p.s(view, "revision"));
    try eql("a", p.s(p.get(view, "roster"), "active_id"));
}

test "a conflicting save fails with conflict and re-reads the roster" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    _ = try f.intent("companion_refresh", .{});
    _ = try f.reply("companion.roster.get", "{\"revision\":2,\"roster\":{\"companions\":[]}}");
    const save = try f.intent("companion_save", .{ .roster = companion.Roster{ .companions = &.{.{ .id = "a", .name = "Moss", .character = "moss" }} }, .expected_revision = "2" });
    _ = try f.reject("companion.roster.put", "conflict");
    const op = try f.receipt(save);
    try eql("failed", op.state);
    try eql("conflict", op.@"error".?.code);
    try expect(f.pending("companion.roster.get") == 1);
    _ = try f.reply("companion.roster.get", "{\"revision\":3,\"roster\":{\"active_id\":\"b\",\"companions\":[{\"id\":\"b\",\"name\":\"Vireo\",\"character\":\"vireo\"}]}}");
    const view = try f.view();
    try eql("3", p.s(view, "revision"));
    try eql("Vireo", p.s(p.rows(p.get(p.get(view, "roster"), "companions"))[0], "name"));
}

test "invalid rosters, missing scopes and old hosts are refused locally" {
    var f = try Fixture.init(&.{"chat:read"});
    defer f.deinit();
    const scoped = try f.intent("companion_save", .{ .roster = companion.Roster{}, .expected_revision = "0" });
    try eql("insufficient_scope", (try f.receipt(scoped)).@"error".?.code);
    try expect(f.pending("companion.roster.put") == 0);
    _ = try f.intent("companion_refresh", .{});
    _ = try f.reject("companion.roster.get", "method_not_found");
    const view = try f.view();
    try expect(!p.yes(p.get(view, "supported")) and !p.yes(p.get(view, "can_edit")));

    var g = try Fixture.init(all_scopes);
    defer g.deinit();
    const long = try g.intent("companion_save", .{ .roster = companion.Roster{ .companions = &.{.{ .id = "a", .name = "A name that is far too long for any companion" }} }, .expected_revision = "0" });
    try eql("invalid_name", (try g.receipt(long)).@"error".?.code);
    const bad = try g.intent("companion_save", .{ .roster = companion.Roster{ .companions = &.{.{ .id = "a", .name = "Ok", .character = "dragon" }} }, .expected_revision = "0" });
    try eql("invalid_character", (try g.receipt(bad)).@"error".?.code);
    try expect(g.pending("companion.roster.put") == 0);
}

test "crew lists the companion thread's links and resets when the companion changes" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const id = try f.intent("companion_crew_refresh", .{ .workspace_id = "ws", .thread_id = "t1" });
    const sent = try f.params("chat.links.list");
    try eql("ws", p.s(sent, "workspace_id"));
    try eql("t1", p.s(sent, "parent_thread_id"));
    _ = try f.intent("companion_crew_refresh", .{ .workspace_id = "ws", .thread_id = "t1" });
    try expect(f.pending("chat.links.list") == 1);
    _ = try f.reply("chat.links.list",
        \\{"links":[{"link_id":"l1","workspace_id":"other","parent_workspace_id":"ws","local_thread_id":"child","title":"Fix CI","provider":"codex","status":"waiting_approval","summary":"Needs approval","updated_at_ms":5,"hidden":false,"extra":1},
        \\ {"link_id":"l2","workspace_id":"","local_thread_id":"x"}]}
    );
    try eql("succeeded", (try f.receipt(id)).state);
    var crew = p.get(try f.view(), "crew");
    try expect(p.yes(p.get(crew, "loaded")));
    const links = p.rows(p.get(crew, "links"));
    try expect(links.len == 1);
    try eql("waiting_approval", p.s(links[0], "status"));
    try eql("other", p.s(links[0], "workspace_id"));
    _ = try f.intent("companion_crew_refresh", .{ .workspace_id = "ws", .thread_id = "t2" });
    crew = p.get(try f.view(), "crew");
    try expect(p.rows(p.get(crew, "links")).len == 0 and p.yes(p.get(crew, "loading")));
    try eql("t2", p.s(crew, "thread_id"));
}
