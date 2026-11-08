//! Real-time voice fixture harness: providers, key configuration and sessions.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"voice","label":"Voice","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
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
        const q = try h.parse(f.a(), try f.host.query("voice", f.a()));
        try expect(p.get(q, "error") == .null);
        return p.get(q, "data");
    }
    fn receipt(f: *Fixture, id: []const u8) !h.Operation {
        for (f.host.state.receipts) |r| if (h.eq(r.operation.intent_id, id)) return r.operation;
        return error.MissingReceipt;
    }
};

const providers_json =
    \\{"default_provider":"xai","providers":[
    \\ {"id":"xai","label":"xAI Grok","protocol":"openai_realtime","configured":true,"key_source":"verde","model":"grok-voice","voice":"Ara","voices":["Ara","Rex"]},
    \\ {"id":"openai","label":"OpenAI","protocol":"openai_realtime","configured":false,"key_source":"none","model":"gpt-realtime","voice":"marin","voices":["marin"]},
    \\ {"label":"no id"}]}
;
const session_json =
    \\{"provider":"xai","protocol":"openai_realtime","model":"grok-voice","voice":"Ara","token":"ephemeral-secret","expires_at_ms":1790000000000,
    \\ "websocket_url":"wss://api.x.ai/v1/realtime","auth":"bearer","instructions":"You are Moss.",
    \\ "tools":[{"name":"ask_companion","description":"Hand off","parameters":{"type":"object","properties":{"request":{"type":"string"}},"required":["request"]}},{"name":"companion_status","description":"Status"}],
    \\ "companion":{"id":"c1","name":"Moss","home_workspace_id":"ws","thread_id":"t1"}}
;

test "configure sends the key only in the RPC body, never in receipts or views" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const id = try f.intent("voice_provider_configure", .{ .provider = "openai", .api_key = "sk-very-secret", .make_default = true });
    const sent = try f.params("voice.provider.configure");
    try eql("sk-very-secret", p.s(sent, "api_key"));
    try expect(p.yes(p.get(sent, "make_default")));
    try expect(p.get(sent, "model") == .null);
    // The same intent id with another key is the same receipt: the key is not part of its identity.
    _ = try f.event("voice_provider_configure", .{ .intent_id = id, .provider = "openai", .api_key = "sk-different", .make_default = true });
    try expect(f.pending("voice.provider.configure") == 1);
    _ = try f.reply("voice.provider.configure", providers_json);
    try eql("succeeded", (try f.receipt(id)).state);
    const view = try f.host.query("voice", f.a());
    try expect(std.mem.indexOf(u8, view, "sk-") == null);
    const hosts = try f.host.query("hosts", f.a());
    try expect(std.mem.indexOf(u8, hosts, "sk-") == null);
    try expect(f.host.state.rpc.calls.len == 0);
    // Absent key keeps the stored one.
    _ = try f.intent("voice_provider_configure", .{ .provider = "xai", .voice = "Rex" });
    try expect(p.get(try f.params("voice.provider.configure"), "api_key") == .null);
}

test "backgrounding drops the session token and an old host is unsupported" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    _ = try f.intent("voice_session_create", .{});
    _ = try f.reply("voice.session.create", session_json);
    _ = try f.event("background", .{});
    try expect(p.get(try f.view(), "session") == .null);

    var g = try Fixture.init(all_scopes);
    defer g.deinit();
    _ = try g.intent("voice_providers_refresh", .{});
    _ = try g.reject("voice.providers", "unknown_method");
    try expect(!p.yes(p.get(try g.view(), "supported")));
    const blocked = try g.intent("voice_session_create", .{});
    try eql("unsupported", (try g.receipt(blocked)).@"error".?.code);

    var r = try Fixture.init(&.{"chat:read"});
    defer r.deinit();
    const denied = try r.intent("voice_provider_configure", .{ .provider = "xai", .api_key = "k" });
    try eql("insufficient_scope", (try r.receipt(denied)).@"error".?.code);
    try expect(r.pending("voice.provider.configure") == 0);
}

const voice_thread = "{\"thread\":{\"provider\":\"muse\",\"harness\":\"local_cli\",\"model_ref\":\"muse:default\",\"repository_id\":\"repo\"}}";

fn acceptVoice(f: *Fixture, queued: bool) ![]const u8 {
    _ = try f.reply("chat.thread.get", voice_thread);
    const params = try f.params("chat.turn.start");
    try eql("voice", p.s(params, "task_owner"));
    try eql("repo", p.s(params, "repository_id"));
    const turn = p.s(params, "turn_id");
    _ = try f.reply("chat.turn.start", try h.encode(f.a(), .{ .turn_id = turn, .queued = queued }));
    return turn;
}

test "voice request waits for acceptance, preserves drafts, and relays only its own turn" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    {
        var tx = try h.Transaction.init(&f.host);
        defer tx.deinit();
        tx.state.chat.threads = try tx.allocator().alloc(@import("chat.zig").Thread, 1);
        tx.state.chat.threads[0] = .{ .workspace_id = "ws", .id = "moss", .cwd = "/fixture", .metadata = .{ .local_thread_id = "moss", .title = "Moss" }, .loaded = true, .saved = .{ .text = "unsent typed draft" } };
        const output = try tx.commit(&f.host, f.a());
        _ = output;
    }
    const chat_before = try h.encode(f.a(), f.host.state.chat.threads[0].saved);
    const first = try f.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "first request" });
    try eql("pending", (try f.receipt(first)).state);
    const first_turn = try acceptVoice(&f, false);
    try eql("succeeded", (try f.receipt(first)).state);
    const first_tail = try f.find("chat.turn.tail");
    const second = try f.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "corrected request" });
    const second_turn = try acceptVoice(&f, true);
    try expect(!h.eq(first_turn, second_turn));
    var second_tail: ?rpc.Call = null;
    for (f.host.state.rpc.calls) |call| if (h.eq(call.method, "chat.turn.tail") and call.id != first_tail.id) {
        second_tail = call;
    };
    _ = try f.respond(second_tail.?, try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = second_tail.?.id, .result = .{ .status = "completed", .result_reply_text = "corrected answer" } }));
    try eql("succeeded", (try f.receipt(second)).state);
    _ = try f.respond(first_tail, try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = first_tail.id, .result = .{ .status = "completed", .result_reply_text = "older answer" } }));
    const rows = p.rows(p.get(try f.view(), "requests"));
    try expect(rows.len == 2);
    try eql(first, p.s(rows[0], "intent_id"));
    try eql("older answer", p.s(rows[0], "reply"));
    try eql(second, p.s(rows[1], "intent_id"));
    try eql("corrected answer", p.s(rows[1], "reply"));
    try eql(chat_before, try h.encode(f.a(), f.host.state.chat.threads[0].saved));
}

test "voice cancellation before acceptance cannot race a later start" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const submit = try f.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "stop this" });
    const turn = f.host.state.voice.requests[0].turn_id;
    const cancel = try f.intent("voice_request_cancel", .{ .turn_id = turn });
    try eql("succeeded", (try f.receipt(cancel)).state);
    try eql("failed", (try f.receipt(submit)).state);
    _ = try f.reply("chat.thread.get", voice_thread);
    try expect(f.pending("chat.turn.start") == 0);

    _ = try f.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "stop during start" });
    _ = try f.reply("chat.thread.get", voice_thread);
    const next_turn = p.s(try f.params("chat.turn.start"), "turn_id");
    const stop = try f.intent("voice_request_cancel", .{ .turn_id = next_turn });
    try expect(f.pending("chat.turn.cancel") == 0);
    _ = try f.reply("chat.turn.start", try h.encode(f.a(), .{ .turn_id = next_turn, .queued = true }));
    try expect(f.pending("chat.turn.cancel") == 1);
    try eql(next_turn, p.s(try f.params("chat.turn.cancel"), "turn_id"));
    try eql("pending", (try f.receipt(stop)).state);
    _ = try f.reply("chat.turn.cancel", "{\"accepted\":true}");
    try eql("succeeded", (try f.receipt(stop)).state);
}

test "voice tails paginate and retry queued turns without retracting acceptance" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const id = try f.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "request" });
    _ = try acceptVoice(&f, true);
    _ = try f.reject("chat.turn.tail", "not_found");
    try eql("succeeded", (try f.receipt(id)).state);
    f.now += 1001;
    _ = try f.event("foreground", .{});
    _ = try f.reply("chat.turn.tail", "{\"status\":\"completed\",\"events\":[{\"seq\":5}],\"has_more_events\":true}");
    try expect(p.uint(p.get(try f.params("chat.turn.tail"), "after_seq")) == 5);
    _ = try f.reply("chat.turn.tail", "{\"status\":\"completed\",\"result_reply_text\":\"full answer\"}");
    try eql("full answer", p.s(p.rows(p.get(try f.view(), "requests"))[0], "reply"));
}

test "voice request failures and read-only devices never claim accepted" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const id = try f.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "request" });
    _ = try f.reply("chat.thread.get", voice_thread);
    _ = try f.reject("chat.turn.start", "invalid_state");
    try eql("failed", (try f.receipt(id)).state);
    try expect(f.pending("chat.turn.tail") == 0);
    var r = try Fixture.init(&.{"chat:read"});
    defer r.deinit();
    const denied = try r.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "request" });
    try eql("insufficient_scope", (try r.receipt(denied)).@"error".?.code);
    try expect(r.pending("chat.thread.get") == 0);
}

test "voice stop remains available at request capacity and malformed cancel is uncertain" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    for (0..16) |_| _ = try f.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "request" });
    const busy = try f.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "request" });
    try eql("busy", (try f.receipt(busy)).@"error".?.code);
    const stopped = try f.intent("voice_request_cancel", .{ .turn_id = f.host.state.voice.requests[0].turn_id });
    try eql("succeeded", (try f.receipt(stopped)).state);
    const other = try f.intent("voice_request_cancel", .{ .turn_id = "externally-started" });
    _ = try f.reply("chat.turn.cancel", "{\"accepted\":false}");
    try eql("uncertain", (try f.receipt(other)).state);
}

test "voice never replays an uncertain start" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const id = try f.intent("voice_request_submit", .{ .workspace_id = "ws", .thread_id = "moss", .prompt = "request" });
    _ = try f.reply("chat.thread.get", voice_thread);
    const call = try f.find("chat.turn.start");
    _ = try f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = 503, .headers = .{}, .body_base64 = "", .@"error" = @as(?u8, null) });
    try eql("uncertain", (try f.receipt(id)).state);
    f.now += 1000;
    _ = try f.event("foreground", .{});
    try expect(f.pending("chat.turn.start") == 0);
}
