//! D-10 management harness: thread/workspace intents against scripted daemon replies.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const chat = @import("chat.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"manage","label":"Manage","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;
const snapshot =
    \\{"store_revision":5,"snapshot":{"workspaces":[
    \\ {"workspace_id":"ws-1","label":"One","path":"/home/u/src/one","provider":"claude","archived":false,"terminal_layout_json":"{\"keep\":true}","threads":[]},
    \\ {"workspace_id":"ws-closed","label":"Old","path":"/srv/old","archived":true,"threads":[]}
    \\]}}
;
const all_scopes: []const []const u8 = &.{ "chat:read", "chat:write", "runtime:read", "repository:read", "repository:write" };

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: h.Host,
    serial: u64 = 1,
    now: i64 = 1,

    fn init(scopes: []const []const u8, capabilities: []const []const u8) !Fixture {
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
        tx.state.rpc.runtime_capabilities = capabilities;
        tx.state.sync.snapshot = try h.parse(tx.allocator(), snapshot);
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
    fn value(f: *Fixture, item: anytype) !V {
        return h.parseLimit(f.a(), try h.encode(f.a(), item), h.MAX_HTTP_INPUT);
    }
    fn event(f: *Fixture, tag: []const u8, payload: anytype) !V {
        var v = try f.value(payload);
        if (v != .object) v = .{ .object = .empty };
        try v.object.put(f.a(), "type", .{ .string = tag });
        try v.object.put(f.a(), "api_version", .{ .integer = 1 });
        try v.object.put(f.a(), "now_ms", .{ .integer = f.now });
        try v.object.put(f.a(), "wall_time_ms", .{ .integer = 1790363191000 + f.now });
        return h.parseLimit(f.a(), try f.host.handle(try h.encode(f.a(), v), f.a()), h.MAX_HTTP_INPUT);
    }
    /// Returns the intent ID it used.
    fn intent(f: *Fixture, tag: []const u8, payload: anytype) ![]const u8 {
        var v = try f.value(payload);
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
    /// Management calls first: a success also queues sync's own snapshot.
    fn find(f: *Fixture, method: []const u8) !rpc.Call {
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, method) and call.intent_id != null and h.eq(call.intent_id.?, "@manage")) return call;
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, method)) return call;
        return error.MissingRequest;
    }
    fn params(f: *Fixture, method: []const u8) !V {
        const call = try f.find(method);
        const bytes = try @import("auth.zig").decode64(f.a(), call.body_base64);
        return p.get(try h.parse(f.a(), bytes), "params");
    }
    fn respond(f: *Fixture, call: rpc.Call, body: []const u8) !void {
        _ = try f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(f.a(), body), .@"error" = @as(?u8, null) });
    }
    fn reply(f: *Fixture, method: []const u8, result: anytype) !void {
        const call = try f.find(method);
        try f.respond(call, try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .result = result }));
    }
    fn replyJson(f: *Fixture, method: []const u8, result: []const u8) !void {
        const call = try f.find(method);
        try f.respond(call, try std.fmt.allocPrint(f.a(), "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ call.id, result }));
    }
    fn reject(f: *Fixture, method: []const u8, code: []const u8, data: anytype) !void {
        const call = try f.find(method);
        try f.respond(call, try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .@"error" = .{ .code = code, .message = "rejected", .data = data } }));
    }
    fn view(f: *Fixture) !V {
        const q = try h.parse(f.a(), try f.host.query("manage", f.a()));
        try expect(p.get(q, "error") == .null);
        return p.get(q, "data");
    }
    fn job(f: *Fixture, id: []const u8) !V {
        for (p.rows(p.get(try f.view(), "operations"))) |row| if (h.eq(p.s(row, "intent_id"), id)) return row;
        return error.MissingJob;
    }
    fn receipt(f: *Fixture, id: []const u8) !h.Operation {
        for (f.host.state.receipts) |r| if (h.eq(r.operation.intent_id, id)) return r.operation;
        return error.MissingReceipt;
    }
    fn expectFailed(f: *Fixture, id: []const u8, code: []const u8) !void {
        const j = try f.job(id);
        try eql("failed", p.s(j, "state"));
        try eql(code, p.s(p.get(j, "error"), "code"));
        const r = try f.receipt(id);
        try eql("failed", r.state);
        try eql(code, r.@"error".?.code);
    }
};

test "thread_create registers once, upserts a local draft thread and opens before sync lists it" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    const id = try f.intent("thread_create", .{ .workspace_id = "ws-1", .provider = "codex", .model = "gpt-5.5", .effort = "high", .access = null, .speed = null });
    try eql("pending", p.s(try f.job(id), "state"));
    try f.reply("daemon.client.register", .{ .client_id = "client-1" });
    const upsert = try f.params("chat.thread.upsert");
    try eql("ws-1", p.s(upsert, "workspace_id"));
    const thread = p.get(upsert, "thread");
    const thread_id = p.s(thread, "local_thread_id");
    try expect(std.mem.startsWith(u8, thread_id, "web-thread-"));
    try eql("New Chat", p.s(thread, "title"));
    try expect(p.get(thread, "committed") == .bool and !p.get(thread, "committed").bool);
    try eql("local", p.s(thread, "profile_id"));
    try eql("primary", p.s(thread, "repository_id"));
    try eql("codex", p.s(thread, "provider"));
    try eql("gpt-5.5", p.s(thread, "model_ref"));
    try eql("high", p.s(thread, "reasoning_effort"));
    try eql("full_access", p.s(thread, "access_mode"));
    try eql("client-1", p.s(p.get(upsert, "mutation"), "client_id"));
    try expect(std.mem.startsWith(u8, p.s(p.get(upsert, "mutation"), "request_key"), "mobile:"));
    // The daemon never sees the platform intent ID.
    try expect(std.mem.indexOf(u8, p.s(p.get(upsert, "mutation"), "request_key"), id) == null);
    try eql(thread_id, p.s(try f.job(id), "thread_id"));

    try f.reply("chat.thread.upsert", .{ .store_revision = 6, .applied = true });
    try eql("succeeded", p.s(try f.job(id), "state"));
    try eql("succeeded", (try f.receipt(id)).state);
    try expect(f.pending("core.snapshot") == 1);
    // Adopted into chat: the transcript selector resolves and thread_open pages.
    const selector = try chat.selectorFor(f.a(), "thread", "ws-1", thread_id);
    const thread_view = try h.parse(f.a(), try f.host.query(selector, f.a()));
    try eql("New Chat", p.s(p.get(p.get(thread_view, "data"), "thread"), "title"));
    const open = try f.intent("thread_open", .{ .workspace_id = "ws-1", .thread_id = thread_id });
    try expect(f.pending("chat.message.list") == 1);
    try eql("pending", (try f.receipt(open)).state);

    // The registered client is reused.
    const second = try f.intent("thread_create", .{ .workspace_id = "ws-1", .provider = "claude", .model = null, .effort = null, .access = "supervised", .speed = null });
    try expect(f.pending("daemon.client.register") == 0);
    const params = try f.params("chat.thread.upsert");
    try eql("supervised", p.s(p.get(params, "thread"), "access_mode"));
    try expect(!h.eq(p.s(p.get(params, "thread"), "local_thread_id"), thread_id));
    try eql("pending", p.s(try f.job(second), "state"));
}

test "thread_create rejects closed workspaces, bad selections and missing scope locally" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    try f.expectFailed(try f.intent("thread_create", .{ .workspace_id = "ws-closed", .provider = "codex" }), "workspace_archived");
    try f.expectFailed(try f.intent("thread_create", .{ .workspace_id = "missing", .provider = "codex" }), "workspace_unavailable");
    try f.expectFailed(try f.intent("thread_create", .{ .workspace_id = "ws-1", .provider = "nope" }), "invalid_selection");
    try f.expectFailed(try f.intent("thread_create", .{ .workspace_id = "ws-1", .provider = "codex", .model = "not-a-model" }), "invalid_selection");
    try expect(f.host.state.rpc.calls.len == 0);

    var g = try Fixture.init(&.{"chat:read"}, &.{});
    defer g.deinit();
    try g.expectFailed(try g.intent("thread_create", .{ .workspace_id = "ws-1", .provider = "codex" }), "insufficient_scope");
    try g.expectFailed(try g.intent("workspace_close", .{ .workspace_id = "ws-1" }), "insufficient_scope");
    try expect(!p.yes(p.get(try g.view(), "can_manage_workspaces")));
}

test "workspace_create hashes the path like the web, trims it and derives the label" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    const id = try f.intent("workspace_create", .{ .path = " /home/u/src/two/ ", .label = null });
    try f.reply("daemon.client.register", .{ .client_id = "client-1" });
    const params = try f.params("workspace.upsert");
    const ws = p.get(params, "workspace");
    const expected = try std.fmt.allocPrint(f.a(), "{x}", .{std.hash.Wyhash.hash(0, "/home/u/src/two")});
    try eql(expected, p.s(ws, "workspace_id"));
    try eql("/home/u/src/two", p.s(ws, "path"));
    try eql("two", p.s(ws, "label"));
    try expect(p.get(p.get(params, "mutation"), "expected_store_revision") == .null);
    try eql(expected, p.s(try f.job(id), "workspace_id"));
    try f.reply("workspace.upsert", .{ .store_revision = 6, .applied = true });
    try eql("succeeded", p.s(try f.job(id), "state"));
    try expect(f.pending("core.snapshot") == 1);

    try f.expectFailed(try f.intent("workspace_create", .{ .path = "relative/dir" }), "invalid_path");
    try f.expectFailed(try f.intent("workspace_create", .{ .path = "/home/u/../etc" }), "invalid_path");
    try f.expectFailed(try f.intent("workspace_create", .{ .path = "/home/u/x", .label = "bad\nlabel" }), "invalid_label");
}

test "rename and reopen rewrite full metadata at the read revision and retry conflicts" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    const id = try f.intent("workspace_rename", .{ .workspace_id = "ws-1", .label = "  Renamed  " });
    try f.reply("daemon.client.register", .{ .client_id = "client-1" });
    try eql("ws-1", p.s(try f.params("core.snapshot"), "workspace_id"));
    try f.replyJson("core.snapshot", snapshot);
    var params = try f.params("workspace.upsert");
    try expect(p.uint(p.get(p.get(params, "mutation"), "expected_store_revision")).? == 5);
    const first_key = p.s(p.get(params, "mutation"), "request_key");
    var ws = p.get(params, "workspace");
    try eql("Renamed", p.s(ws, "label"));
    try eql("{\"keep\":true}", p.s(ws, "terminal_layout_json"));
    try eql("/home/u/src/one", p.s(ws, "path"));
    try expect(p.get(ws, "threads") == .null);

    try f.reject("workspace.upsert", "conflict", null);
    try expect(f.pending("core.snapshot") == 1);
    try f.replyJson("core.snapshot", "{\"store_revision\":7,\"workspaces\":[{\"workspace_id\":\"ws-1\",\"label\":\"Theirs\",\"path\":\"/home/u/src/one\"}]}");
    params = try f.params("workspace.upsert");
    try expect(p.uint(p.get(p.get(params, "mutation"), "expected_store_revision")).? == 7);
    try expect(!h.eq(first_key, p.s(p.get(params, "mutation"), "request_key")));
    ws = p.get(params, "workspace");
    try eql("Renamed", p.s(ws, "label"));
    try f.reply("workspace.upsert", .{ .store_revision = 8, .applied = true });
    try eql("succeeded", p.s(try f.job(id), "state"));

    // Persistent conflicts stop after three attempts with a typed error.
    const reopen = try f.intent("workspace_archive", .{ .workspace_id = "ws-closed", .archived = false });
    for (0..3) |_| {
        try f.replyJson("core.snapshot", snapshot);
        try expect(p.get(p.get(try f.params("workspace.upsert"), "workspace"), "archived").bool == false);
        try f.reject("workspace.upsert", "conflict", null);
    }
    try f.expectFailed(reopen, "conflict");
    try expect(f.pending("workspace.upsert") == 0);

    try f.expectFailed(try f.intent("workspace_rename", .{ .workspace_id = "ws-1", .label = "   " }), "invalid_label");
    const gone = try f.intent("workspace_archive", .{ .workspace_id = "missing", .archived = true });
    try f.replyJson("core.snapshot", snapshot);
    try f.expectFailed(gone, "workspace_unavailable");
}
