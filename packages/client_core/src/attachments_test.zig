//! Attachment image fetch harness: chunked reads, LRU, release and dedupe.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const attachments = @import("attachments.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"images","label":"Images","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: h.Host,
    serial: u64 = 1,

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
        try v.object.put(f.a(), "now_ms", .{ .integer = 1 });
        try v.object.put(f.a(), "wall_time_ms", .{ .integer = 1790363191000 });
        return h.parseLimit(f.a(), try f.host.handle(try h.encode(f.a(), v), f.a()), h.MAX_HTTP_INPUT);
    }
    fn intent(f: *Fixture, tag: []const u8, payload: anytype) ![]const u8 {
        var v = try h.parseLimit(f.a(), try h.encode(f.a(), payload), h.MAX_HTTP_INPUT);
        const id = try std.fmt.allocPrint(f.a(), "intent-{d}", .{f.serial});
        f.serial += 1;
        try v.object.put(f.a(), "intent_id", .{ .string = id });
        _ = try f.event(tag, v);
        return id;
    }
    fn calls(f: *Fixture) usize {
        var n: usize = 0;
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, "chat.attachment.read")) {
            n += 1;
        };
        return n;
    }
    fn first(f: *Fixture) !rpc.Call {
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, "chat.attachment.read")) return call;
        return error.MissingRequest;
    }
    fn params(f: *Fixture) !V {
        const bytes = try @import("auth.zig").decode64(f.a(), (try f.first()).body_base64);
        return p.get(try h.parse(f.a(), bytes), "params");
    }
    fn respond(f: *Fixture, body: []const u8) !void {
        const call = try f.first();
        _ = try f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(f.a(), body), .@"error" = @as(?u8, null) });
    }
    fn chunk(f: *Fixture, total: usize, offset: usize, bytes: []const u8) !void {
        const call = try f.first();
        try f.respond(try std.fmt.allocPrint(f.a(), "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"mime\":\"image/png\",\"total_bytes\":{d},\"offset\":{d},\"data\":\"{s}\"}}}}", .{ call.id, total, offset, try rpc.encodeBase64(f.a(), bytes) }));
    }
    fn reject(f: *Fixture, code: []const u8) !void {
        const call = try f.first();
        try f.respond(try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .@"error" = .{ .code = code, .message = "rejected" } }));
    }
    fn item(f: *Fixture, key: []const u8) !?V {
        const q = try h.parseLimit(f.a(), try f.host.query("attachments", f.a()), h.MAX_HTTP_INPUT * 2);
        for (p.rows(p.get(p.get(q, "data"), "items"))) |row| if (h.eq(p.s(row, "key"), key)) return row;
        return null;
    }
    fn receipt(f: *Fixture, id: []const u8) !h.Operation {
        for (f.host.state.receipts) |r| if (h.eq(r.operation.intent_id, id)) return r.operation;
        return error.MissingReceipt;
    }
};
const read_scopes: []const []const u8 = &.{"chat:read"};

test "fetch reads chunks until total_bytes, dedupes and exposes base64 once ready" {
    var f = try Fixture.init(read_scopes);
    defer f.deinit();
    const id = try f.intent("attachment_fetch", .{ .workspace_id = "ws", .thread_id = "t", .message_id = "m1", .index = 1 });
    const again = try f.intent("attachment_fetch", .{ .workspace_id = "ws", .thread_id = "t", .message_id = "m1", .index = 1 });
    try expect(f.calls() == 1);
    const sent = try f.params();
    try eql("t", p.s(sent, "local_thread_id"));
    try eql("m1", p.s(sent, "message_id"));
    try expect(p.num(p.get(sent, "index")).? == 1 and p.num(p.get(sent, "offset")).? == 0);
    try f.chunk(6, 0, "abc");
    var view = (try f.item("ws|t|m1|1")).?;
    try eql("loading", p.s(view, "status"));
    try expect(p.get(view, "data_base64") == .null);
    try expect(p.num(p.get(try f.params(), "offset")).? == 3);
    try f.chunk(6, 3, "def");
    view = (try f.item("ws|t|m1|1")).?;
    try eql("ready", p.s(view, "status"));
    try eql("image/png", p.s(view, "mime"));
    try eql("YWJjZGVm", p.s(view, "data_base64"));
    try eql("succeeded", (try f.receipt(id)).state);
    try eql("succeeded", (try f.receipt(again)).state);
    // Ready: a new fetch reuses it; release drops the bytes.
    _ = try f.intent("attachment_fetch", .{ .workspace_id = "ws", .thread_id = "t", .message_id = "m1", .index = 1 });
    try expect(f.calls() == 0);
    _ = try f.intent("attachment_release", .{ .key = "ws|t|m1|1" });
    try expect((try f.item("ws|t|m1|1")) == null);
    try expect(f.host.blobs.count() == 0);
}

test "missing images are unavailable, bad chunks fail, and only four ready blobs stay in memory" {
    var f = try Fixture.init(read_scopes);
    defer f.deinit();
    const gone = try f.intent("attachment_fetch", .{ .workspace_id = "ws", .thread_id = "t", .message_id = "old", .index = 0 });
    try f.reject("resource_not_found");
    try eql("unavailable", p.s((try f.item("ws|t|old|0")).?, "status"));
    try eql("failed", (try f.receipt(gone)).state);
    _ = try f.intent("attachment_fetch", .{ .workspace_id = "ws", .thread_id = "t", .message_id = "big", .index = 0 });
    try f.chunk(attachments.MAX_IMAGE_BYTES + 1, 0, "x");
    try eql("too_large", p.s((try f.item("ws|t|big|0")).?, "error_code"));
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |m| {
        _ = try f.intent("attachment_fetch", .{ .workspace_id = "ws", .thread_id = "t", .message_id = m, .index = 0 });
        try f.chunk(1, 0, "z");
    }
    try expect((try f.item("ws|t|a|0")) == null);
    try eql("ready", p.s((try f.item("ws|t|e|0")).?, "status"));
    try expect(f.host.blobs.count() == attachments.MAX_READY);

    var r = try Fixture.init(&.{"terminal:read"});
    defer r.deinit();
    const denied = try r.intent("attachment_fetch", .{ .workspace_id = "ws", .thread_id = "t", .message_id = "m", .index = 0 });
    try eql("insufficient_scope", (try r.receipt(denied)).@"error".?.code);
}
