//! Deterministic local-contract fixtures; no daemon, clocks, sockets or files.
const std = @import("std");
const core = @import("host.zig");
const abi = @import("root.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const config =
    \\{"api_version":1,"host_id":"phone-1","label":"Dev","https_url":null,"wss_url":null,"client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;
const start =
    \\{"api_version":1,"type":"start","now_ms":10,"wall_time_ms":100,"foreground":true,"network_available":true}
;
const background =
    \\{"api_version":1,"type":"background","now_ms":20,"wall_time_ms":80}
;
const shutdown =
    \\{"api_version":1,"type":"shutdown","now_ms":30,"wall_time_ms":130}
;
const intent =
    \\{"api_version":1,"type":"retry_connection","now_ms":10,"wall_time_ms":100,"intent_id":"intent-1"}
;
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: core.Host,
    fn init() !Fixture {
        return .{ .arena = .init(std.testing.allocator), .host = try .init(std.testing.allocator, config) };
    }
    fn deinit(self: *Fixture) void {
        self.host.deinit();
        self.arena.deinit();
    }
    fn event(self: *Fixture, bytes: []const u8) !V {
        const output = try self.host.handle(bytes, self.arena.allocator());
        return core.parse(self.arena.allocator(), output);
    }
    fn query(self: *Fixture, selector: []const u8) !V {
        return core.parse(self.arena.allocator(), try self.host.query(selector, self.arena.allocator()));
    }
    fn complete(self: *Fixture, effect: V, key: []const u8, now: i64) !V {
        const bytes = try std.json.Stringify.valueAlloc(self.arena.allocator(), .{ .api_version = 1, .type = "secure_store_value", .now_ms = now, .wall_time_ms = 100, .effect_id = get(effect, "effect_id").string, .generation = get(effect, "generation").string, .key = key, .value_base64 = @as(?[]const u8, null), .@"error" = @as(?u8, null) }, .{});
        return self.event(bytes);
    }
};
fn get(v: V, key: []const u8) V {
    return v.object.get(key).?;
}
fn effects(v: V) []V {
    return get(v, "effects").array.items;
}

test "start ordered effects, independent hosts, out-of-order storage, duplicate and stale callbacks" {
    var f = try Fixture.init();
    defer f.deinit();
    var other = try Fixture.init();
    defer other.deinit();
    const batch = effects(try f.event(start));
    try expect(batch.len == 3);
    try eql("secure_store_get", get(batch[0], "type").string);
    try eql("vc/1/phone-1/profile", get(batch[0], "key").string);
    try eql("vc/1/phone-1/credential", get(batch[1], "key").string);
    try eql("state_changed", get(batch[2], "type").string);
    try expect(other.host.state.lifecycle == .created);
    _ = try f.event(background);
    try expect(f.host.state.generation == 1);
    // Transport invalidation must preserve original storage generations.
    _ = try f.complete(batch[1], "vc/1/phone-1/credential", 20);
    try eql("unpaired", f.host.state.auth_state);
    try expect(effects(try f.complete(batch[1], "vc/1/phone-1/credential", 20)).len == 0);
    try expect(effects(try f.complete(batch[0], "wrong-key", 20)).len == 0);
    try expect(f.host.state.pending.len == 1);
    _ = try f.complete(batch[0], "vc/1/phone-1/profile", 20);
    try expect(f.host.state.pending.len == 0);
    const q = try f.query("hosts");
    const host = get(get(q, "data"), "items").array.items[0];
    try expect(get(host, "capabilities") == .array);
    const before = f.host.state.revision;
    _ = try f.query("home");
    _ = try f.query("workspaces");
    _ = try f.query("hosts");
    try expect(before == f.host.state.revision);
    _ = try f.event(shutdown);
    try expect(effects(try f.event(shutdown)).len == 0);
    try std.testing.expectError(error.InvalidLifecycle, f.event(background));
}

test "timers replace IDs, rearm early, reject old generation and duplicate completion; shutdown cancels" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.event(start);
    var tx = try core.Transaction.init(&f.host);
    defer tx.deinit();
    try tx.setTimer("reconnect", 100);
    const first = tx.state.pending[2].id;
    try tx.setTimer("reconnect", 200);
    try expect(tx.effects.items.len == 3);
    try eql("cancel_timer", get(tx.effects.items[1], "type").string);
    const second = tx.state.pending[2].id;
    try expect(!core.eq(first, second));
    _ = try tx.commit(&f.host, f.arena.allocator());
    const early = try std.fmt.allocPrint(f.arena.allocator(), "{{\"api_version\":1,\"type\":\"timer_fired\",\"now_ms\":15,\"wall_time_ms\":0,\"timer_id\":\"{s}\",\"generation\":\"0\"}}", .{second});
    const rearm = effects(try f.event(early));
    try expect(rearm.len == 1);
    try expect(get(rearm[0], "delay_ms").integer == 195);
    try expect(!core.eq(second, get(rearm[0], "timer_id").string));
    try expect(effects(try f.event(early)).len == 0);
    const stop = effects(try f.event(shutdown));
    try eql("cancel_timer", get(stop[0], "type").string);
    try expect(f.host.state.pending.len == 0);
}

test "transport and storage invalidation are separate and cancellation order is deterministic" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.event(start);
    var tx = try core.Transaction.init(&f.host);
    defer tx.deinit();
    const http = try tx.emit("http_request", .{ .method = "GET" });
    try tx.track(.http, http, "");
    const socket = try tx.emit("ws_open", .{});
    try tx.track(.socket, socket, "");
    const put = try tx.emit("secure_store_put", .{ .key = "vc/1/phone-1/profile", .value_base64 = "e30=" });
    try tx.track(.store_put, put, "vc/1/phone-1/profile");
    try tx.setTimer("poll", 100);
    _ = try tx.commit(&f.host, f.arena.allocator());
    const batch = effects(try f.event(background));
    try expect(batch.len == 4);
    try eql("http_cancel", get(batch[0], "type").string);
    try eql("ws_close", get(batch[1], "type").string);
    try eql("cancel_timer", get(batch[2], "type").string);
    try expect(f.host.state.pending.len == 3);
    const late = try std.fmt.allocPrint(f.arena.allocator(), "{{\"api_version\":1,\"type\":\"http_response\",\"now_ms\":20,\"wall_time_ms\":0,\"effect_id\":\"{s}\",\"generation\":\"0\",\"status\":200,\"headers\":[],\"body_base64\":\"e30=\",\"error\":null}}", .{http});
    try expect(effects(try f.event(late)).len == 0);
    const done = try std.fmt.allocPrint(f.arena.allocator(), "{{\"api_version\":1,\"type\":\"secure_store_done\",\"now_ms\":20,\"wall_time_ms\":0,\"effect_id\":\"{s}\",\"generation\":\"0\",\"key\":\"vc/1/phone-1/profile\",\"error\":null}}", .{put});
    _ = try f.event(done);
    try expect(f.host.state.pending.len == 2);
}

test "receipts canonicalize ordering and time and reject changed payload" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.event(intent);
    const reordered = "{\"intent_id\":\"intent-1\",\"wall_time_ms\":200,\"now_ms\":11,\"type\":\"retry_connection\",\"api_version\":1}";
    try expect(effects(try f.event(reordered)).len == 0);
    try expect(f.host.state.receipts.len == 1);
    try expect(effects(try f.event("{\"intent_id\":\"intent-1\",\"wall_time_ms\":200,\"now_ms\":11,\"type\":\"retry_connection\",\"api_version\":1,\"future_field\":{\"data\":123}}")).len == 0);
    const operation = get(get(try f.query("hosts"), "data"), "operations").array.items[0];
    try eql("unsupported", get(get(operation, "error"), "code").string);
    try std.testing.expectError(error.InvalidArgument, f.event("{\"api_version\":1,\"type\":\"history_load_more\",\"now_ms\":11,\"wall_time_ms\":100,\"intent_id\":\"intent-1\"}"));
}

fn retryIntent(f: *Fixture, id: []const u8) !V {
    return f.event(try std.fmt.allocPrint(f.arena.allocator(), "{{\"api_version\":1,\"type\":\"retry_connection\",\"now_ms\":11,\"wall_time_ms\":100,\"intent_id\":\"{s}\"}}", .{id}));
}
fn receiptIndex(f: *Fixture, id: []const u8) ?usize {
    for (f.host.state.receipts, 0..) |r, i| if (core.eq(r.operation.intent_id, id)) return i;
    return null;
}
/// Replaces the retained table with `count` distinct receipts in `state`.
fn fillReceipts(f: *Fixture, count: usize, state: []const u8) !void {
    const a = f.host.arena.allocator();
    const template = f.host.state.receipts[0];
    const receipts = try a.alloc(@TypeOf(template), count);
    for (receipts, 0..) |*r, i| {
        r.* = template;
        r.operation = .{ .intent_id = try std.fmt.allocPrint(a, "held-{d}", .{i}), .state = state, .@"error" = null };
    }
    f.host.state.receipts = receipts;
}

test "long sessions roll settled receipts off without teardown and keep in-flight ones" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try retryIntent(&f, "held-0");
    @constCast(f.host.state.receipts)[0].operation.state = "pending";
    var name: [32]u8 = undefined;
    const total = 10_050;
    for (0..total) |i| {
        const batch = effects(try retryIntent(&f, try std.fmt.bufPrint(&name, "intent-{d}", .{i})));
        try expect(batch.len == 1);
        try eql("state_changed", get(batch[0], "type").string);
        // Each admission adds (and past the window evicts) a receipt: operations, not hosts.
        try expect(hasScope(batch[0], "operations"));
        try expect(!hasScope(batch[0], "hosts"));
        try expect(f.host.state.receipts.len <= core.RECENT_RECEIPTS + 1);
    }
    // The in-flight receipt survives ten thousand newer intents and still deduplicates.
    try expect(receiptIndex(&f, "held-0") != null);
    try eql("pending", f.host.state.receipts[receiptIndex(&f, "held-0").?].operation.state);
    try expect(effects(try retryIntent(&f, "held-0")).len == 0);
    // The settled window keeps exactly the newest intents, oldest first.
    try expect(f.host.state.receipts.len == core.RECENT_RECEIPTS + 1);
    try expect(receiptIndex(&f, try std.fmt.bufPrint(&name, "intent-{d}", .{total - core.RECENT_RECEIPTS})) != null);
    try expect(receiptIndex(&f, try std.fmt.bufPrint(&name, "intent-{d}", .{total - core.RECENT_RECEIPTS - 1})) == null);
    try expect(get(get(try f.query("hosts"), "data"), "operations").array.items.len == core.RECENT_RECEIPTS + 1);
    try expect(get(get(try f.query("operations"), "data"), "items").array.items.len == core.RECENT_RECEIPTS + 1);
}
fn hasScope(effect: V, selector: []const u8) bool {
    for (get(effect, "scopes").array.items) |scope| if (core.eq(scope.string, selector)) return true;
    return false;
}

test "recent settled receipts deduplicate and reject changed payloads" {
    var f = try Fixture.init();
    defer f.deinit();
    var name: [32]u8 = undefined;
    for (0..core.RECENT_RECEIPTS * 3) |i| _ = try retryIntent(&f, try std.fmt.bufPrint(&name, "intent-{d}", .{i}));
    const oldest = core.RECENT_RECEIPTS * 2;
    for ([_]usize{ oldest, oldest + 17, core.RECENT_RECEIPTS * 3 - 1 }) |i| {
        const id = try std.fmt.bufPrint(&name, "intent-{d}", .{i});
        const snapshot = try f.host.query("hosts", f.arena.allocator());
        try expect(effects(try retryIntent(&f, id)).len == 0);
        try eql(snapshot, try f.host.query("hosts", f.arena.allocator()));
        const changed = try std.fmt.allocPrint(f.arena.allocator(), "{{\"api_version\":1,\"type\":\"history_load_more\",\"now_ms\":11,\"wall_time_ms\":100,\"intent_id\":\"{s}\"}}", .{id});
        try std.testing.expectError(error.InvalidArgument, f.event(changed));
    }
}

test "in-flight receipts at the cap reject new intents with retryable backpressure" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try retryIntent(&f, "seed");
    try fillReceipts(&f, core.MAX_INFLIGHT_RECEIPTS, "uncertain");
    for (0..2) |_| {
        const batch = effects(try retryIntent(&f, "blocked"));
        try expect(batch.len == 1);
        try eql("state_changed", get(batch[0], "type").string);
        try expect(f.host.state.receipts.len == core.MAX_INFLIGHT_RECEIPTS + 1);
        const op = f.host.state.receipts[receiptIndex(&f, "blocked").?].operation;
        try eql("failed", op.state);
        try eql("resource", op.@"error".?.domain);
        try eql("backpressure", op.@"error".?.code);
        try expect(op.@"error".?.retryable);
        try eql("blocked", op.@"error".?.intent_id.?);
    }
    // A backpressure receipt still binds its ID to the original payload.
    try std.testing.expectError(error.InvalidArgument, f.event("{\"api_version\":1,\"type\":\"history_load_more\",\"now_ms\":11,\"wall_time_ms\":100,\"intent_id\":\"blocked\"}"));
    // Rejections are settled, so they never grow the table beyond the hard bound.
    var name: [32]u8 = undefined;
    for (0..core.RECENT_RECEIPTS + 8) |i| _ = try retryIntent(&f, try std.fmt.bufPrint(&name, "burst-{d}", .{i}));
    try expect(f.host.state.receipts.len == core.MAX_RECEIPTS);
    for (0..core.MAX_INFLIGHT_RECEIPTS) |i| try expect(receiptIndex(&f, try std.fmt.bufPrint(&name, "held-{d}", .{i})) != null);
    // Once one action resolves, retrying the same rejected ID is admitted and runs its engine.
    const last = try std.fmt.bufPrint(&name, "burst-{d}", .{core.RECENT_RECEIPTS + 7});
    try eql("backpressure", f.host.state.receipts[receiptIndex(&f, last).?].operation.@"error".?.code);
    @constCast(f.host.state.receipts)[receiptIndex(&f, "held-0").?].operation.state = "succeeded";
    _ = try retryIntent(&f, last);
    try eql("unsupported", f.host.state.receipts[receiptIndex(&f, last).?].operation.@"error".?.code);
    try expect(f.host.state.receipts.len <= core.MAX_RECEIPTS);
    // An admitted intent that stays pending counts against the cap again.
    @constCast(f.host.state.receipts)[receiptIndex(&f, last).?].operation.state = "pending";
    _ = try retryIntent(&f, "later");
    try eql("backpressure", f.host.state.receipts[receiptIndex(&f, "later").?].operation.@"error".?.code);
}

test "malformed JSON, framing, typed failures and lifecycle errors leave state unchanged" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.event(start);
    const bad = [_][]const u8{
        "{",                                                                                                                                                                                                                                       "[]",                                                                             "{\"api_version\":1,\"type\":\"unknown\",\"now_ms\":10,\"wall_time_ms\":0}",
        "{\"api_version\":1,\"type\":\"foreground\",\"now_ms\":9,\"wall_time_ms\":0}",                                                                                                                                                             "{\"api_version\":1,\"type\":\"foreground\",\"now_ms\":10.5,\"wall_time_ms\":0}", "{\"api_version\":1,\"type\":\"secure_store_done\",\"now_ms\":10,\"wall_time_ms\":0,\"effect_id\":\"missing\",\"generation\":\"0\",\"key\":\"key\",\"error\":{\"code\":\"secret exception text\"}}",
        "{\"api_version\":1,\"type\":\"http_response\",\"now_ms\":10,\"wall_time_ms\":0,\"effect_id\":\"missing\",\"generation\":\"0\",\"status\":200,\"headers\":[],\"body_base64\":null,\"error\":{\"kind\":\"network\",\"code\":\"offline\"}}",
    };
    const snapshot = try f.host.query("hosts", f.arena.allocator());
    for (bad) |event| {
        try std.testing.expectError(error.InvalidArgument, f.event(event));
        try eql(snapshot, try f.host.query("hosts", f.arena.allocator()));
    }
    try std.testing.expectError(error.InvalidLifecycle, f.event(start));
    try std.testing.expectError(error.UnsupportedVersion, f.event("{\"api_version\":2}"));
    const unknown = try f.query("thread:missing");
    try expect(get(unknown, "data") == .null);
    try eql("not_found", get(get(unknown, "error"), "code").string);
}

test "C ABI input ownership, independent output lifetime, nulls and clear-on-failure" {
    var input: [config.len]u8 = undefined;
    @memcpy(&input, config);
    var host: ?*core.Host = null;
    try expect(abi.vcHostNew(&input, input.len, &host) == 0);
    @memset(&input, 'x');
    var out: abi.Buf = .{};
    try expect(abi.vcHostQuery(host, "hosts", 5, &out) == 0);
    abi.vcHostFree(host);
    try expect(std.mem.indexOf(u8, out.ptr.?[0..out.len], "phone-1") != null);
    abi.vcBufFree(out);
    out = .{ .ptr = @ptrFromInt(1), .len = 1 };
    try expect(abi.vcHostHandle(null, null, 0, &out) == 1);
    try expect(out.ptr == null and out.len == 0);
    host = @ptrFromInt(@alignOf(core.Host));
    try expect(abi.vcHostNew(null, 1, &host) == 1 and host == null);
    abi.vcBufFree(.{});
    abi.vcHostFree(null);
}

fn allocationScenario(a: A) !void {
    var host = core.Host.init(a, config) catch |err| return err;
    defer host.deinit();
    const before = try host.query("hosts", std.testing.allocator);
    defer std.testing.allocator.free(before);
    const batch = host.handle(start, a) catch |err| {
        const after = try host.query("hosts", std.testing.allocator);
        defer std.testing.allocator.free(after);
        try eql(before, after);
        try expect(host.state.pending.len == 0 and host.state.next_id == 1 and host.state.now_ms == null);
        return err;
    };
    defer a.free(batch);
    try expect(host.state.pending.len == 2);
}
test "every constructor, staging, effect and output allocation failure rolls back without leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "retry without a started host fails visibly and emits no I/O" {
    const cases = [_]struct { tag: []const u8, payload: []const u8 }{
        .{ .tag = "retry_connection", .payload = "" },
    };
    for (cases) |case| {
        var f = try Fixture.init();
        defer f.deinit();
        const ids = if (core.eq(case.tag, "focus")) "" else ",\"workspace_id\":\"w\",\"thread_id\":\"t\",\"terminal_id\":\"term\"";
        const event = try std.fmt.allocPrint(f.arena.allocator(), "{{\"api_version\":1,\"type\":\"{s}\",\"now_ms\":0,\"wall_time_ms\":0,\"intent_id\":\"i\"{s}{s}}}", .{ case.tag, ids, case.payload });
        const batch = effects(try f.event(event));
        try expect(batch.len == 1);
        try eql("state_changed", get(batch[0], "type").string);
        try eql("unsupported", f.host.state.receipts[0].operation.@"error".?.code);
    }
}

test "constructor uses shared mobile URL rules, limits nesting, and keeps 64 bit revisions lossless" {
    const invalid_configs = [_][]const u8{
        "{\"api_version\":2}",
        "{\"api_version\":1}",
    };
    for (invalid_configs) |input| {
        var host: ?*core.Host = null;
        try expect(abi.vcHostNew(input.ptr, input.len, &host) != 0 and host == null);
    }
    var f = try Fixture.init();
    defer f.deinit();
    const urls = [_][]const u8{ "http://host", "https://user@host", "https://host?token=secret", "https://host#fragment", "https://other" };
    for (urls) |url| {
        var cfg = f.host.state.config;
        cfg.https_url = url;
        cfg.wss_url = "wss://host/ws";
        const bytes = try std.json.Stringify.valueAlloc(f.arena.allocator(), cfg, .{});
        try std.testing.expectError(error.InvalidArgument, core.Host.init(std.testing.allocator, bytes));
    }
    f.host.state.revision = 9007199254740993;
    const snapshot = try f.query("hosts");
    try eql("9007199254740993", get(snapshot, "revision").string);
    const deep = "[" ** 65 ++ "0" ++ "]" ** 65;
    try std.testing.expectError(error.ResourceLimit, f.event(deep));
    _ = try f.event(start);
    const before = f.host.state.revision;
    _ = try f.event("{\"api_version\":1,\"type\":\"foreground\",\"now_ms\":10,\"wall_time_ms\":-100,\"future\":true}");
    try expect(f.host.state.revision == before);
}

test "matching generation completes once, due timer drains, storage failure is not unpaired" {
    var f = try Fixture.init();
    defer f.deinit();
    const batch = effects(try f.event(start));
    const fail = try std.fmt.allocPrint(f.arena.allocator(), "{{\"api_version\":1,\"type\":\"secure_store_value\",\"now_ms\":10,\"wall_time_ms\":0,\"effect_id\":\"{s}\",\"generation\":\"0\",\"key\":\"vc/1/phone-1/credential\",\"value_base64\":null,\"error\":{{\"code\":\"locked\"}}}}", .{get(batch[1], "effect_id").string});
    _ = try f.event(fail);
    try eql("loading", f.host.state.auth_state);
    try expect(f.host.state.host_error != null);
    var tx = try core.Transaction.init(&f.host);
    defer tx.deinit();
    try tx.setTimer("test", 5);
    const id = tx.state.pending[1].id;
    _ = try tx.commit(&f.host, f.arena.allocator());
    const wrong = try std.fmt.allocPrint(f.arena.allocator(), "{{\"api_version\":1,\"type\":\"timer_fired\",\"now_ms\":15,\"wall_time_ms\":0,\"timer_id\":\"{s}\",\"generation\":\"1\"}}", .{id});
    try expect(effects(try f.event(wrong)).len == 0);
    try expect(f.host.state.pending.len == 2);
    const due = try std.fmt.allocPrint(f.arena.allocator(), "{{\"api_version\":1,\"type\":\"timer_fired\",\"now_ms\":15,\"wall_time_ms\":0,\"timer_id\":\"{s}\",\"generation\":\"0\"}}", .{id});
    try expect(effects(try f.event(due)).len == 0);
    try expect(f.host.state.pending.len == 1);
    try expect(effects(try f.event(due)).len == 0);
}
