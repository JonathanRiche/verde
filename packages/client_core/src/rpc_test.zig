//! RPC host fixtures: fake HTTP completions, no sockets or real credentials.
const std = @import("std");
const host = @import("host.zig");
const rpc = @import("rpc.zig");
const protocol = @import("headless").protocol;
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const runtime = "0123456789abcdef0123456789abcdef";
const instance = "00112233445566778899aabbccddeeff";
const other = "ffeeddccbbaa99887766554433221100";
const config =
    \\{"api_version":1,"host_id":"rpc","label":"RPC","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;
fn init() !host.Host {
    var h = try host.Host.init(std.testing.allocator, config);
    h.state.lifecycle = .foreground;
    h.state.network_available = true;
    return h;
}
fn setup(tx: *host.Transaction) !void {
    try rpc.attachBearer(tx, "fake-token", runtime, "fake-pin");
}
fn statusValue(id: []const u8) protocol.StatusResult {
    return .{ .runtime_id = runtime, .instance_id = id, .server_version = "1.0", .headless_protocol_version = 1, .min_supported = 1, .max_supported = 1, .protocol_version = 26, .pid = 1, .session_count = 0, .chat_turn_count = 0, .capabilities = protocol.Capabilities{} };
}
fn response(tx: *host.Transaction, call: rpc.Call, payload: anytype) !void {
    const a = tx.allocator();
    const wire = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = call.id, .result = payload }, .{});
    try rawResponse(tx, call, wire, 200);
}
fn rawResponse(tx: *host.Transaction, call: rpc.Call, wire: []const u8, status: u16) !void {
    const a = tx.allocator();
    const event = try host.parse(a, try std.json.Stringify.valueAlloc(a, .{ .api_version = 1, .type = "http_response", .now_ms = 1, .wall_time_ms = 1, .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(a, "{d}", .{tx.state.generation}), .status = status, .headers = .{}, .body_base64 = try rpc.encodeBase64(a, wire), .@"error" = @as(?u8, null) }, .{}));
    try tx.apply(event);
}
fn ready(tx: *host.Transaction) !void {
    try setup(tx);
    _ = try rpc.beginHandshake(tx);
    try response(tx, tx.state.rpc.calls[0], statusValue(instance));
    try response(tx, tx.state.rpc.calls[0], .{ .runtime_id = runtime, .instance_id = instance, .headless_protocol_version = 1, .min_supported = 1, .max_supported = 1, .capabilities = protocol.Capabilities{} });
    try expect(rpc.takeFullResync(tx));
}
fn envelope(tx: *host.Transaction, effect_index: usize) !std.json.Value {
    const encoded = tx.effects.items[effect_index].object.get("body_base64").?.string;
    const bytes = try tx.allocator().alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    try std.base64.standard.Decoder.decode(bytes, encoded);
    return host.parse(tx.allocator(), bytes);
}

test "RPC envelope targets every call except status; parked and interactive HTTP dispatch concurrently" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try ready(&tx);
    const initial = try envelope(&tx, 0);
    try expect(initial.object.get("target") == null);
    try expect(initial.object.get("jsonrpc") == null);
    const capability = try envelope(&tx, 1);
    try eql(runtime, capability.object.get("target").?.object.get("runtime_id").?.string);
    try eql(instance, capability.object.get("target").?.object.get("instance_id").?.string);
    tx.state.rpc.next_id = 9_007_199_254_740_993;
    const tail_id = try rpc.request(&tx, "chat.turn.tail", .{ .wait_ms = 20_000 }, .{ .mutation = false, .parked_wait_ms = 20_000 });
    const send_id = try rpc.request(&tx, "chat.turn.start", .{}, .{ .intent_id = "send-1" });
    try expect(send_id == tail_id + 1);
    for (tx.effects.items, 0..) |effect, index| {
        const wire = try envelope(&tx, index);
        if (index != 0) try eql(instance, wire.object.get("target").?.object.get("instance_id").?.string);
        try eql("http_request", effect.object.get("type").?.string);
        try eql("https://host.example/api/rpc", effect.object.get("url").?.string);
        const headers = effect.object.get("headers").?.array.items;
        try eql("Bearer fake-token", headers[0].object.get("value").?.string);
    }
    const tail = tx.state.rpc.calls[0];
    const send = tx.state.rpc.calls[1];
    try response(&tx, send, .{ .accepted = true });
    try expect(rpc.takeResult(&tx).?.id == send_id);
    try response(&tx, tail, .{});
    try expect(rpc.takeResult(&tx).?.id == tail_id);
    try response(&tx, tail, .{}); // duplicate completion ignored
    try expect(rpc.takeResult(&tx) == null);
}

test "RPC restart invalidates old work and requests full resync without host error or mutation replay" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try ready(&tx);
    _ = try rpc.request(&tx, "chat.turn.start", .{}, .{});
    const old_call = tx.state.rpc.calls[0];
    _ = try rpc.beginHandshake(&tx);
    try response(&tx, tx.state.rpc.calls[1], statusValue(other));
    try expect(tx.state.generation == 1);
    try expect(tx.state.stale);
    try expect(tx.state.host_error == null);
    const uncertain = rpc.takeResult(&tx).?;
    try eql("uncertain", uncertain.@"error".?.delivery.?);
    try expect(tx.state.rpc.calls.len == 1);
    try eql("core.capabilities", tx.state.rpc.calls[0].method);
    try response(&tx, tx.state.rpc.calls[0], .{ .runtime_id = runtime, .instance_id = other, .headless_protocol_version = 1, .min_supported = 1, .max_supported = 1, .capabilities = protocol.Capabilities{} });
    try expect(rpc.takeFullResync(&tx));
    try expect(!rpc.takeFullResync(&tx));
    try expect(tx.state.rpc.phase == .ready);
    try response(&tx, old_call, .{});
    try expect(rpc.takeResult(&tx) == null);
}

test "RPC typed errors, response correlation and FailureKind retry classes" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try ready(&tx);
    const Kind = @import("verde_remote").connection.FailureKind;
    inline for (std.meta.tags(Kind)) |kind| {
        const err = rpc.failure(kind, "test", false);
        try expect(err.retryable == (kind == .network or kind == .server_unavailable));
    }
    for ([_]u16{ 401, 403, 503, 404 }) |status| {
        _ = try rpc.request(&tx, "chat.turn.start", .{}, .{});
        try rawResponse(&tx, tx.state.rpc.calls[0], "", status);
        const err = rpc.takeResult(&tx).?.@"error".?;
        try expect(err.retryable == (status == 503));
        try eql(if (status == 503) "uncertain" else "rejected", err.delivery.?);
        if (status == 403) try eql("scope_denied", err.code);
    }
    _ = try rpc.request(&tx, "chat.turn.start", .{}, .{});
    try rawResponse(&tx, tx.state.rpc.calls[0], "{\"id\":0,\"result\":{}}", 200);
    try eql("protocol", rpc.takeResult(&tx).?.@"error".?.failure_kind.?);
    _ = try rpc.request(&tx, "chat.turn.start", .{}, .{});
    const call = tx.state.rpc.calls[0];
    const wire = try std.json.Stringify.valueAlloc(tx.allocator(), .{ .jsonrpc = "2.0", .id = call.id, .@"error" = .{ .code = "future_code", .message = "secret server text" } }, .{});
    try rawResponse(&tx, call, wire, 200);
    const err = rpc.takeResult(&tx).?.@"error".?;
    try eql("future_code", err.rpc_code.?);
    try expect(std.mem.indexOf(u8, err.message, "secret") == null);
}

test "RPC negotiated limits and explicit snapshot allowance" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try ready(&tx);
    try std.testing.expectError(error.ResourceLimit, rpc.request(&tx, "chat.turn.tail", .{ .wait_ms = 30_000 }, .{ .parked_wait_ms = 30_000 }));
    try std.testing.expectError(error.ResourceLimit, rpc.request(&tx, "chat.thread.list", .{ .limit = 201 }, .{ .mutation = false }));
    _ = try rpc.request(&tx, "core.snapshot", .{}, .{ .mutation = false, .legacy_snapshot = true });
    try expect(tx.state.rpc.calls[0].response_cap == protocol.MAX_MESSAGE_BYTES);
    tx.state.rpc.limits.max_request_bytes = 1;
    try std.testing.expectError(error.ResourceLimit, rpc.request(&tx, "core.status", .{}, .{ .mutation = false }));
}

test "RPC runtime changes require trust; incompatible mobile client requires update" {
    inline for (.{ true, false }) |identity| {
        var h = try init();
        defer h.deinit();
        var tx = try host.Transaction.init(&h);
        defer tx.deinit();
        try setup(&tx);
        _ = try rpc.beginHandshake(&tx);
        var status = statusValue(instance);
        if (identity) status.runtime_id = other else status.mobile.min_client = 2;
        try response(&tx, tx.state.rpc.calls[0], status);
        try expect(tx.state.rpc.calls.len == 0);
        try expect(tx.state.host_error != null);
        try expect(tx.state.rpc.update_required == !identity);
        try expect(!rpc.takeFullResync(&tx));
    }
}

test "RPC target rejection rediscovers instance and leaves other mutations uncertain" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try ready(&tx);
    _ = try rpc.request(&tx, "chat.turn.start", .{}, .{});
    _ = try rpc.request(&tx, "chat.turn.cancel", .{}, .{});
    const call = tx.state.rpc.calls[0];
    const wire = try std.json.Stringify.valueAlloc(tx.allocator(), .{ .jsonrpc = "2.0", .id = call.id, .@"error" = .{ .code = "runtime_identity_mismatch", .message = "changed" } }, .{});
    try rawResponse(&tx, call, wire, 200);
    try eql("rejected", rpc.takeResult(&tx).?.@"error".?.delivery.?);
    try eql("uncertain", rpc.takeResult(&tx).?.@"error".?.delivery.?);
    try eql("core.status", tx.state.rpc.calls[0].method);
    try response(&tx, tx.state.rpc.calls[0], statusValue(other));
    try response(&tx, tx.state.rpc.calls[0], .{ .runtime_id = runtime, .instance_id = other, .headless_protocol_version = 1, .min_supported = 1, .max_supported = 1, .capabilities = protocol.Capabilities{} });
    try expect(tx.state.host_error == null);
    try expect(rpc.takeFullResync(&tx));
}

test "RPC transport failure is uncertain for mutation, stale generations are ignored, credentials stay out of queries" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try ready(&tx);
    _ = try rpc.request(&tx, "chat.turn.start", .{}, .{ .intent_id = "send" });
    const call = tx.state.rpc.calls[0];
    const a = tx.allocator();
    const event = try host.parse(a, try std.json.Stringify.valueAlloc(a, .{ .api_version = 1, .type = "http_response", .now_ms = 1, .wall_time_ms = 1, .effect_id = call.effect_id, .generation = "0", .status = @as(?u16, null), .headers = .{}, .body_base64 = @as(?[]const u8, null), .@"error" = .{ .kind = "timeout", .code = "timeout" } }, .{}));
    try tx.apply(event);
    const result = rpc.takeResult(&tx).?;
    try eql("uncertain", result.@"error".?.delivery.?);
    try eql("send", result.@"error".?.intent_id.?);
    try eql("network", result.@"error".?.failure_kind.?);
    const output = try tx.commit(&h, std.testing.allocator);
    defer std.testing.allocator.free(output);
    const query = try h.query("hosts", std.testing.allocator);
    defer std.testing.allocator.free(query);
    try expect(std.mem.indexOf(u8, query, "fake-token") == null);
    try expect(h.state.rpc.phase == .ready);
    var resumed = try host.Transaction.init(&h);
    defer resumed.deinit();
    _ = try rpc.request(&resumed, "chat.turn.tail", .{}, .{ .mutation = false });
    var stale = event;
    try stale.object.put(a, "effect_id", .{ .string = resumed.state.rpc.calls[0].effect_id });
    try stale.object.put(a, "generation", .{ .string = "99" });
    try resumed.apply(stale);
    try expect(resumed.state.rpc.calls.len == 1);
    try expect(rpc.takeResult(&resumed) == null);
}

fn allocationScenario(a: std.mem.Allocator) !void {
    var h = try host.Host.init(a, config);
    defer h.deinit();
    h.state.lifecycle = .foreground;
    h.state.network_available = true;
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try setup(&tx);
    _ = try rpc.beginHandshake(&tx);
    const output = tx.commit(&h, a) catch |err| {
        try expect(h.state.rpc.bearer == null);
        try expect(h.state.pending.len == 0);
        try expect(h.state.rpc.next_id == 1);
        return err;
    };
    defer a.free(output);
    try expect(h.state.rpc.calls.len == 1);
}
test "RPC allocation failures preserve host and effect atomicity" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
