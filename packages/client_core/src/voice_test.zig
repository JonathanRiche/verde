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

fn announced(output: V, scope: []const u8) bool {
    for (p.rows(p.get(output, "effects"))) |effect| if (h.eq(p.s(effect, "type"), "state_changed")) {
        for (p.rows(p.get(effect, "scopes"))) |s| if (h.eq(p.str(s), scope)) return true;
    };
    return false;
}

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

test "providers refresh coalesces and lists providers without keys" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const first = try f.intent("voice_providers_refresh", .{});
    const second = try f.intent("voice_providers_refresh", .{});
    try eql("succeeded", (try f.receipt(second)).state);
    try expect(f.pending("voice.providers") == 1);
    const out = try f.reply("voice.providers", providers_json);
    try expect(announced(out, "voice"));
    try eql("succeeded", (try f.receipt(first)).state);
    const view = try f.view();
    try expect(p.yes(p.get(view, "loaded")));
    try eql("xai", p.s(view, "default_provider"));
    const list = p.rows(p.get(view, "providers"));
    try expect(list.len == 2);
    try eql("verde", p.s(list[0], "key_source"));
    try expect(p.rows(p.get(list[0], "voices")).len == 2);
    try expect(!p.yes(p.get(list[1], "configured")));
}

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

test "session create exposes a ready session with raw tool schemas and is replaced by the next request" {
    var f = try Fixture.init(all_scopes);
    defer f.deinit();
    const id = try f.intent("voice_session_create", .{ .companion_id = "c1" });
    var session = p.get(try f.view(), "session");
    try eql("pending", p.s(session, "status"));
    try eql(id, p.s(session, "intent_id"));
    try eql("c1", p.s(try f.params("voice.session.create"), "companion_id"));
    try expect(p.get(try f.params("voice.session.create"), "provider") == .null);
    _ = try f.reply("voice.session.create", session_json);
    session = p.get(try f.view(), "session");
    try eql("ready", p.s(session, "status"));
    try eql("ephemeral-secret", p.s(session, "token"));
    try eql("bearer", p.s(session, "auth"));
    try eql("Moss", p.s(p.get(session, "companion"), "name"));
    const tools = p.rows(p.get(session, "tools"));
    try expect(tools.len == 2);
    const schema = try h.parse(f.a(), p.s(tools[0], "parameters"));
    try eql("request", p.rows(p.get(schema, "required"))[0].string);
    try eql("{\"type\":\"object\",\"properties\":{}}", p.s(tools[1], "parameters"));
    try eql("succeeded", (try f.receipt(id)).state);
    // A new request drops the old token before anything else happens.
    _ = try f.intent("voice_session_create", .{ .provider = "gemini" });
    session = p.get(try f.view(), "session");
    try eql("pending", p.s(session, "status"));
    try eql("", p.s(session, "token"));
    _ = try f.reject("voice.session.create", "voice_not_configured");
    session = p.get(try f.view(), "session");
    try eql("failed", p.s(session, "status"));
    try eql("voice_not_configured", p.s(session, "error_code"));
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
