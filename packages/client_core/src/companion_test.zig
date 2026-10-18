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

const Line = companion.TranscriptMessage;

test "transcript save registers once, appends each line with a stable request key and clips long bodies" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const long = try f.a().alloc(u8, companion.MAX_TRANSCRIPT_BODY + 100);
    @memset(long, 'x');
    const lines = [_]Line{
        .{ .key = "0", .role = "system", .author = "Live", .body = "Live voice · xAI Grok", .created_at_ms = 10 },
        .{ .key = "1", .role = "user", .author = "You (voice)", .body = "  ", .created_at_ms = 11 },
        .{ .key = "2", .role = "assistant", .author = "Moss (voice)", .body = long, .created_at_ms = 12 },
    };
    const id = try f.intent("companion_transcript_save", .{ .workspace_id = "ws", .thread_id = "t1", .session_id = "s1", .messages = lines });
    try eql("pending", (try f.receipt(id)).state);
    _ = try f.reply("daemon.client.register", "{\"client_id\":\"phone\"}");
    var sent = try f.params("chat.message.append");
    try eql("live:s1:0", p.s(p.get(sent, "mutation"), "request_key"));
    try eql("phone", p.s(p.get(sent, "mutation"), "client_id"));
    try eql("t1", p.s(sent, "thread_id"));
    try eql("live:s1:0", p.s(p.get(sent, "message"), "message_id"));
    try eql("system", p.s(p.get(sent, "message"), "role"));
    try expect(p.num(p.get(p.get(sent, "message"), "updated_at_ms")).? == 10);
    _ = try f.reply("chat.message.append", "{\"store_revision\":5,\"applied\":true}");
    // The blank line is skipped; the long one is clipped with an ellipsis.
    sent = try f.params("chat.message.append");
    try eql("live:s1:2", p.s(p.get(sent, "message"), "message_id"));
    const body = p.s(p.get(sent, "message"), "body");
    try expect(body.len <= companion.MAX_TRANSCRIPT_BODY);
    try expect(std.mem.endsWith(u8, body, "\u{2026}"));
    try expect(f.pending("chat.message.append") == 1);
    _ = try f.reply("chat.message.append", "{\"store_revision\":6,\"applied\":true}");
    try eql("succeeded", (try f.receipt(id)).state);
    try expect(f.host.state.companion.saves.len == 0);
    // A retry of the same lines reuses the same request keys (the daemon deduplicates), without re-registering.
    _ = try f.intent("companion_transcript_save", .{ .workspace_id = "ws", .thread_id = "t1", .session_id = "s1", .messages = lines[0..1] });
    try expect(f.pending("daemon.client.register") == 0);
    try eql("live:s1:0", p.s(p.get(try f.params("chat.message.append"), "mutation"), "request_key"));
}
