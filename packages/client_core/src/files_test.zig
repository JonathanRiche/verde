//! D-12 file fetch harness: `file_open` → `file_fetch` → bodiless `http_response`.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const files = @import("files.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"files","label":"Files","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: h.Host,
    serial: u64 = 1,
    now: i64 = 1,

    fn init() !Fixture {
        var host = try h.Host.init(std.testing.allocator, config);
        errdefer host.deinit();
        var tx = try h.Transaction.init(&host);
        defer tx.deinit();
        tx.state.lifecycle = .foreground;
        tx.state.network_available = true;
        tx.state.auth_state = "paired";
        tx.state.auth.credential = .{ .runtime_id = "0123456789abcdef0123456789abcdef", .device_id = "fixture", .device_credential = "fixture", .scopes = &.{"repository:read"} };
        try rpc.attachBearer(&tx, "fixture-token", "0123456789abcdef0123456789abcdef", "fixture-pin");
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
        var v = try h.parse(f.a(), try h.encode(f.a(), payload));
        if (v != .object) v = .{ .object = .empty };
        try v.object.put(f.a(), "type", .{ .string = tag });
        try v.object.put(f.a(), "api_version", .{ .integer = 1 });
        f.now += 1;
        try v.object.put(f.a(), "now_ms", .{ .integer = f.now });
        try v.object.put(f.a(), "wall_time_ms", .{ .integer = 1790363191000 + f.now });
        return h.parse(f.a(), try f.host.handle(try h.encode(f.a(), v), f.a()));
    }
    /// Returns the intent ID and the committed batch.
    fn open(f: *Fixture, path: []const u8, kind: []const u8, max_bytes: u32) !struct { id: []const u8, batch: V } {
        const id = try std.fmt.allocPrint(f.a(), "file-{d}", .{f.serial});
        f.serial += 1;
        return .{ .id = id, .batch = try f.event("file_open", .{ .intent_id = id, .path = path, .kind = kind, .max_bytes = max_bytes }) };
    }
    fn respond(f: *Fixture, effect: V, status: ?u16, transport: ?[]const u8) !V {
        return f.event("http_response", .{
            .effect_id = effect.object.get("effect_id").?.string,
            .generation = effect.object.get("generation").?.string,
            .status = status,
            .headers = &[_]struct { name: []const u8, value: []const u8 }{},
            .body_base64 = @as(?[]const u8, null),
            .@"error" = if (transport) |kind| @as(?struct { kind: []const u8, code: []const u8 }, .{ .kind = kind, .code = "unknown" }) else null,
        });
    }
    fn op(f: *Fixture, id: []const u8) h.Operation {
        for (f.host.state.receipts) |r| if (h.eq(r.operation.intent_id, id)) return r.operation;
        unreachable;
    }
};

fn effects(batch: V, tag: []const u8) usize {
    var n: usize = 0;
    for (batch.object.get("effects").?.array.items) |e| n += @intFromBool(h.eq(e.object.get("type").?.string, tag));
    return n;
}
fn find(batch: V, tag: []const u8) ?V {
    for (batch.object.get("effects").?.array.items) |e| if (h.eq(e.object.get("type").?.string, tag)) return e;
    return null;
}

test "file_open emits an authenticated, pinned, bounded fetch and succeeds without a body" {
    var f = try Fixture.init();
    defer f.deinit();
    const opened = try f.open("/home/u/src/a b/Ünï+#?.ts", "file", 64 * 1024 * 1024);
    const fetch = find(opened.batch, "file_fetch").?;
    try expect(effects(opened.batch, "http_request") == 0);
    try eql(opened.id, fetch.object.get("intent_id").?.string);
    try eql("https://host.example/api/file?path=/home/u/src/a%20b/%C3%9Cn%C3%AF%2B%23%3F.ts", fetch.object.get("url").?.string);
    const header = fetch.object.get("headers").?.array.items[0];
    try eql("Authorization", header.object.get("name").?.string);
    try eql("Bearer fixture-token", header.object.get("value").?.string);
    try eql("fixture-pin", fetch.object.get("tls").?.object.get("spki_sha256").?.string);
    try eql("https://host.example", fetch.object.get("tls").?.object.get("origin").?.string);
    // The platform's limit is capped at the gateway's 32 MiB.
    try expect(fetch.object.get("max_response_bytes").?.integer == files.MAX_FILE_BYTES);
    try eql("pending", f.op(opened.id).state);
    _ = try f.respond(fetch, 200, null);
    try eql("succeeded", f.op(opened.id).state);
    try expect(f.op(opened.id).@"error" == null);
    try expect(f.host.state.files.fetches.len == 0);
    try expect(f.host.state.pending.len == 0);

    const preview = try f.open("/home/u/deck.pptx", "preview", 1024);
    const effect = find(preview.batch, "file_fetch").?;
    try eql("https://host.example/api/preview?path=/home/u/deck.pptx", effect.object.get("url").?.string);
    try expect(effect.object.get("timeout_ms").?.integer > 30_000);
    try expect(effect.object.get("max_response_bytes").?.integer == 1024);
}

test "file_open classifies gateway and transport failures" {
    var f = try Fixture.init();
    defer f.deinit();
    const cases = [_]struct { status: ?u16, transport: ?[]const u8, code: []const u8, retryable: bool }{
        .{ .status = 403, .transport = null, .code = "forbidden", .retryable = false },
        .{ .status = 404, .transport = null, .code = "not_found", .retryable = false },
        .{ .status = 413, .transport = null, .code = "too_large", .retryable = false },
        .{ .status = 415, .transport = null, .code = "unsupported", .retryable = false },
        .{ .status = 501, .transport = null, .code = "preview_unavailable", .retryable = false },
        .{ .status = 503, .transport = null, .code = "server_unavailable", .retryable = true },
        .{ .status = null, .transport = "resource", .code = "too_large", .retryable = false },
        .{ .status = null, .transport = "timeout", .code = "timeout", .retryable = true },
        .{ .status = null, .transport = "network", .code = "offline", .retryable = true },
        .{ .status = null, .transport = "tls", .code = "identity", .retryable = false },
    };
    for (cases) |case| {
        const opened = try f.open("/home/u/report.pdf", "file", 1024);
        _ = try f.respond(find(opened.batch, "file_fetch").?, case.status, case.transport);
        const op = f.op(opened.id);
        try eql("failed", op.state);
        try eql(case.code, op.@"error".?.code);
        try eql("file", op.@"error".?.domain);
        try eql(opened.id, op.@"error".?.intent_id.?);
        try expect(op.@"error".?.retryable == case.retryable);
        // User-facing text never repeats the path.
        try expect(std.mem.indexOf(u8, op.@"error".?.message, "report") == null);
    }
}

test "file_open rejects invalid paths, offline hosts and excess concurrency without a request" {
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ "relative/a.md", "/home/u/../etc/passwd", "/", "/a\x01b.md" }) |path| {
        const opened = try f.open(path, "file", 1024);
        try expect(find(opened.batch, "file_fetch") == null);
        try eql("invalid_path", f.op(opened.id).@"error".?.code);
    }
    var ids: [files.MAX_FETCHES][]const u8 = undefined;
    for (&ids) |*id| id.* = (try f.open("/home/u/a.md", "file", 1024)).id;
    const busy = try f.open("/home/u/a.md", "file", 1024);
    try expect(find(busy.batch, "file_fetch") == null);
    try eql("busy", f.op(busy.id).@"error".?.code);

    // Losing the network invalidates transport: pending fetches are cancelled and fail retryably.
    const lost = try f.event("network_changed", .{ .available = false, .network_id = "" });
    try expect(effects(lost, "http_cancel") == files.MAX_FETCHES);
    for (ids) |id| {
        try eql("cancelled", f.op(id).@"error".?.code);
        try expect(f.op(id).@"error".?.retryable);
    }
    try expect(f.host.state.files.fetches.len == 0);
    const offline = try f.open("/home/u/a.md", "file", 1024);
    try expect(find(offline.batch, "file_fetch") == null);
    try eql("offline", f.op(offline.id).@"error".?.code);
}

test "a 401 refreshes the bearer once and resends; a stale completion is ignored" {
    var f = try Fixture.init();
    defer f.deinit();
    const opened = try f.open("/home/u/notes.md", "file", 1024);
    const first = find(opened.batch, "file_fetch").?;
    _ = try f.respond(first, 401, null);
    try eql("pending", f.op(opened.id).state);
    try expect(f.host.state.rpc.bearer == null);
    try expect(f.host.state.files.fetches.len == 1);
    // A duplicate of the consumed completion no longer matches anything.
    _ = try f.respond(first, 200, null);
    try eql("pending", f.op(opened.id).state);

    // K-07 attaches the refreshed token; the next pump resends with it.
    var tx = try h.Transaction.init(&f.host);
    defer tx.deinit();
    try rpc.attachBearer(&tx, "fresh-token", "0123456789abcdef0123456789abcdef", "fixture-pin");
    try files.pump(&tx);
    const output = try tx.commit(&f.host, f.a());
    const batch = try h.parse(f.a(), output);
    const second = find(batch, "file_fetch").?;
    try eql("Bearer fresh-token", second.object.get("headers").?.array.items[0].object.get("value").?.string);
    try expect(!h.eq(first.object.get("effect_id").?.string, second.object.get("effect_id").?.string));
    _ = try f.respond(second, 401, null);
    try eql("unauthorized", f.op(opened.id).@"error".?.code);
    try expect(f.host.state.files.fetches.len == 0);
}
