//! Recorded temporary-daemon fixtures plus adversarial legacy push schedules.
const std = @import("std");
const host = @import("host.zig");
const sync = @import("sync.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const wire = @import("wire.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const config =
    \\{"api_version":1,"host_id":"sync","label":"Sync","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;
const snapshot = @embedFile("fixtures/sync/snapshot.json");
const first = @embedFile("fixtures/sync/threads-0.json");
const last = @embedFile("fixtures/sync/threads-1.json");
const changes = @embedFile("fixtures/sync/changes.json");
fn init() !host.Host {
    return host.Host.init(std.testing.allocator, config);
}
fn ready(tx: *host.Transaction) !void {
    tx.state.lifecycle = .foreground;
    tx.state.network_available = true;
    try rpc.attachBearer(tx, "fixture-token", "0123456789abcdef0123456789abcdef", "fixture-pin");
    tx.state.rpc.instance_id = "00112233445566778899aabbccddeeff";
    tx.state.rpc.phase = .ready;
    tx.state.rpc.full_resync = true;
    try sync.pump(tx);
}
fn respond(tx: *host.Transaction, body: []const u8) !void {
    try expect(tx.state.rpc.calls.len > 0);
    const call = tx.state.rpc.calls[0];
    const a = tx.allocator();
    const envelope = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ call.id, body });
    const input = try std.json.Stringify.valueAlloc(a, .{ .api_version = 1, .type = "http_response", .now_ms = tx.state.now_ms orelse 1, .wall_time_ms = 1700000050000, .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(a, "{d}", .{tx.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(a, envelope), .@"error" = @as(?u8, null) }, .{});
    try tx.apply(try host.parse(a, input));
    try sync.pump(tx);
}
fn push(tx: *host.Transaction, method: []const u8, body: []const u8) !void {
    try sync.push(tx, try std.fmt.allocPrint(tx.allocator(), "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{{\"id\":1,\"result\":{s}}}}}", .{ method, body }));
}
fn fixture(tx: *host.Transaction) !void {
    try ready(tx);
    try respond(tx, snapshot);
    try respond(tx, first);
    try respond(tx, last);
}

test "sync recorded daemon snapshot and catalog pages project native models without desktop RPCs" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try ready(&tx);
    try expect(tx.state.sync.cursor == null);
    try respond(&tx, snapshot);
    try expect(tx.state.sync.cursor == null);
    try respond(&tx, first);
    try expect(tx.state.sync.cursor == null);
    try respond(&tx, last);
    try expect(tx.state.sync.cursor == 9);
    try expect(!tx.state.sync.loading and !tx.state.stale);
    for (tx.effects.items) |effect| {
        if (!host.eq(p.s(effect, "type"), "http_request")) continue;
        const body = p.s(effect, "body_base64");
        const bytes = try tx.allocator().alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(body));
        try std.base64.standard.Decoder.decode(bytes, body);
        const request = try host.parse(tx.allocator(), bytes);
        const method = p.s(request, "method");
        try expect(host.eq(method, "core.snapshot") or host.eq(method, "chat.thread.list"));
        try expect(p.get(request, "target") == .object);
    }
    const output = try tx.commit(&h, std.testing.allocator);
    defer std.testing.allocator.free(output);
    const query = try h.query("workspaces", std.testing.allocator);
    defer std.testing.allocator.free(query);
    const decoded = try std.json.parseFromSlice(wire.Query(wire.WorkspacesView), std.testing.allocator, query, .{});
    defer decoded.deinit();
    const ws = decoded.value.data.?.items[0];
    try expect(ws.panes.len == 4);
    try expect(ws.threads.len == 3);
    try eql("layout-thread", ws.panes[0].thread_id.?);
    try eql("unavailable", ws.panes[1].status);
    try expect(ws.panes[1].terminal_id == null);
    try eql("browser", ws.panes[2].kind);
    try eql("web-thread-fixture", ws.panes[3].thread_id.?);
    try expect(ws.threads[0].last_activity_at_ms.? == 1700000000000);
}

test "legacy invalidations coalesce and do not advance cursor past applied data" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try fixture(&tx);
    try push(&tx, "core.changes", changes);
    const id = tx.state.sync.snapshot_id.?;
    try push(&tx, "core.changes", changes);
    try push(&tx, "core.snapshot", snapshot);
    try expect(tx.state.sync.snapshot_id.? == id);
    try respond(&tx, snapshot);
    try respond(&tx, first);
    try respond(&tx, last);
    try expect(tx.state.sync.loading and tx.state.stale);
    try expect(tx.state.rpc.calls.len == 1);
    try respond(&tx, snapshot);
    try respond(&tx, first);
    try respond(&tx, last);
    try expect(!tx.state.sync.loading);
    try push(&tx, "core.changes", "{\"entries\":[],\"heartbeat\":true,\"next_cursor\":999}");
    try expect(tx.state.sync.cursor.? == 9);
    try expect(tx.state.rpc.calls.len == 0);
}

// ---- K-16 delta mode. Fixtures come from a temporary daemon + gateway
// (fixtures/delta/record.py); legacy (K-09) twins replay the same daemon state.
const delta = sync.delta;
const d_hello = @embedFile("fixtures/delta/hello.json");
const d_bootstrap = @embedFile("fixtures/delta/bootstrap.json");
const d_initial = @embedFile("fixtures/delta/initial.json");
const d_initial_threads = @embedFile("fixtures/delta/initial-threads.json");
const d_ack = @embedFile("fixtures/delta/ack.json");
const d_change = @embedFile("fixtures/delta/change.json");
const d_scoped = @embedFile("fixtures/delta/scoped.json");
const d_threads = @embedFile("fixtures/delta/threads.json");
const d_after = @embedFile("fixtures/delta/after-change.json");
const d_resume_ack = @embedFile("fixtures/delta/resume-ack.json");
const d_resume_change = @embedFile("fixtures/delta/resume-change.json");
const d_resume_scoped = @embedFile("fixtures/delta/resume-scoped.json");
const d_final = @embedFile("fixtures/delta/final.json");
const d_final_threads = @embedFile("fixtures/delta/final-threads.json");
const WALL = 1700000050000;

fn helloStatus(tx: *host.Transaction) !std.json.Value {
    return p.get(p.get(p.get(try host.parse(tx.allocator(), d_hello), "params"), "status_envelope"), "result");
}
/// Handshake-complete state using the recorded runtime identity. `advertise`
/// selects a delta-capable gateway or a legacy host with the same daemon.
fn deltaReady(tx: *host.Transaction, advertise: bool) !void {
    const status = try helloStatus(tx);
    tx.state.lifecycle = .foreground;
    tx.state.network_available = true;
    try rpc.attachBearer(tx, "fixture-token", p.s(status, "runtime_id"), "fixture-pin");
    tx.state.rpc.instance_id = p.s(status, "instance_id");
    tx.state.rpc.runtime_capabilities = if (advertise) &.{ "core.snapshot.v1", "core.changes.v1", delta.CAPABILITY } else &.{ "core.snapshot.v1", "core.changes.v1" };
    tx.state.rpc.phase = .ready;
    tx.state.rpc.full_resync = true;
    try sync.pump(tx);
}
fn now(tx: *host.Transaction) i64 {
    return tx.state.now_ms orelse 1;
}
fn gen(tx: *host.Transaction) ![]const u8 {
    return std.fmt.allocPrint(tx.allocator(), "{d}", .{tx.state.generation});
}
fn pendingIndex(tx: *host.Transaction, kind: host.PendingKind, suffix: []const u8) ?usize {
    for (tx.state.pending, 0..) |pending, i| {
        if (pending.kind == kind and (std.mem.endsWith(u8, pending.key, suffix) or std.mem.endsWith(u8, pending.purpose, suffix))) return i;
    }
    return null;
}
/// Completes the checkpoint read with `value` (null: nothing stored).
fn storeValue(tx: *host.Transaction, value: ?[]const u8) !void {
    const pending = tx.state.pending[pendingIndex(tx, .store_get, "/sync").?];
    const event = try std.json.Stringify.valueAlloc(tx.allocator(), .{ .api_version = 1, .type = "secure_store_value", .now_ms = now(tx), .wall_time_ms = WALL, .effect_id = pending.id, .generation = try gen(tx), .key = pending.key, .value_base64 = value, .@"error" = @as(?u8, null) }, .{});
    try tx.apply(try host.parse(tx.allocator(), event));
    try sync.pump(tx);
}
fn storeDone(tx: *host.Transaction, failed: bool) !void {
    const i = pendingIndex(tx, .store_put, "/sync") orelse pendingIndex(tx, .store_delete, "/sync").?;
    const pending = tx.state.pending[i];
    const a = tx.allocator();
    const event = if (failed)
        try std.json.Stringify.valueAlloc(a, .{ .api_version = 1, .type = "secure_store_done", .now_ms = now(tx), .wall_time_ms = WALL, .effect_id = pending.id, .generation = try gen(tx), .key = pending.key, .@"error" = .{ .code = "io" } }, .{})
    else
        try std.json.Stringify.valueAlloc(a, .{ .api_version = 1, .type = "secure_store_done", .now_ms = now(tx), .wall_time_ms = WALL, .effect_id = pending.id, .generation = try gen(tx), .key = pending.key, .@"error" = @as(?u8, null) }, .{});
    try tx.apply(try host.parse(a, event));
    try sync.pump(tx);
}
fn openSocket(tx: *host.Transaction) ![]const u8 {
    const socket = try tx.emit("ws_connect", .{});
    try tx.track(.socket, socket, "auth_socket");
    return socket;
}
fn wsMessage(tx: *host.Transaction, socket: []const u8, text: []const u8) !void {
    const event = try std.json.Stringify.valueAlloc(tx.allocator(), .{ .api_version = 1, .type = "ws_message", .now_ms = now(tx), .wall_time_ms = WALL, .socket_id = socket, .generation = try gen(tx), .text = text }, .{});
    try tx.apply(try host.parse(tx.allocator(), event));
    try sync.pump(tx);
}
/// Returns the last `ws_send` effect's decoded request, if any since `from`.
fn lastSend(tx: *host.Transaction, from: usize) !?std.json.Value {
    var found: ?std.json.Value = null;
    for (tx.effects.items[from..]) |effect| {
        if (host.eq(p.s(effect, "type"), "ws_send")) found = try host.parse(tx.allocator(), p.s(effect, "text"));
    }
    return found;
}
/// Answers the pending opt-in with a recorded acknowledgement, re-keyed to
/// the core's JSON-RPC id (the recorder picked its own).
fn ackWith(tx: *host.Transaction, socket: []const u8, fixture_text: []const u8) !void {
    var note = try host.parse(tx.allocator(), fixture_text);
    try note.object.put(tx.allocator(), "id", .{ .integer = @intCast(tx.state.sync.delta.control_id.?) });
    try wsMessage(tx, socket, try std.json.Stringify.valueAlloc(tx.allocator(), note, .{}));
}
/// Synthetic delta notice in the gateway's forwarded-response shape.
fn frame(tx: *host.Transaction, entries: []const u8, next: u64, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(tx.allocator(), "{{\"jsonrpc\":\"2.0\",\"method\":\"core.changes\",\"params\":{{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{{\"entries\":{s},\"next_cursor\":{d},\"journal_floor_seq\":0,\"envelope\":{{\"instance_nonce\":\"{s}\",\"registry_revision\":1}},\"store_revision\":2{s}}}}}}}", .{ entries, next, tx.state.sync.nonce, extra });
}
fn snapshotScopes(tx: *host.Transaction, call: rpc.Call) ![]const std.json.Value {
    try eql("core.snapshot", call.method);
    const body = try host.parse(tx.allocator(), try @import("auth.zig").decode64(tx.allocator(), call.body_base64));
    return p.rows(p.get(p.get(body, "params"), "scopes"));
}
fn expectScopes(tx: *host.Transaction, expected: []const []const u8) !void {
    try expect(tx.state.rpc.calls.len == 1);
    const got = try snapshotScopes(tx, tx.state.rpc.calls[0]);
    try expect(got.len == expected.len);
    for (expected, got) |want, item| try eql(want, item.string);
}
/// No full (all-scope) snapshot read was issued in effects[from..].
fn expectNoFullSnapshot(tx: *host.Transaction, from: usize) !void {
    for (tx.effects.items[from..]) |effect| {
        if (!host.eq(p.s(effect, "type"), "http_request")) continue;
        const request = try host.parse(tx.allocator(), try @import("auth.zig").decode64(tx.allocator(), p.s(effect, "body_base64")));
        if (host.eq(p.s(request, "method"), "core.snapshot")) try expect(p.rows(p.get(p.get(request, "params"), "scopes")).len < sync.scopes.len);
    }
}
fn projections(tx: *host.Transaction) ![2][]const u8 {
    const a = tx.allocator();
    return .{
        try std.json.Stringify.valueAlloc(a, try sync.query(a, &tx.state, "home"), .{}),
        try std.json.Stringify.valueAlloc(a, try sync.query(a, &tx.state, "workspaces"), .{}),
    };
}
fn expectSameProjections(a: *host.Transaction, b: *host.Transaction) !void {
    const left = try projections(a);
    const right = try projections(b);
    try eql(left[0], right[0]);
    try eql(left[1], right[1]);
}
/// Legacy K-09 host fed the same daemon state: seed, then one full refresh.
fn legacyTwin(tx: *host.Transaction, full: []const u8, threads: []const u8) !void {
    try deltaReady(tx, false);
    try respond(tx, d_initial);
    try respond(tx, d_initial_threads);
    try wsMessage(tx, try openSocket(tx), d_change);
    try expectScopes(tx, &sync.scopes);
    try respond(tx, full);
    try respond(tx, threads);
    try expect(!tx.state.sync.loading and !tx.state.stale);
}
/// Fresh delta client: empty checkpoint, legacy seed, then opt-in at the
/// seeded cursor on a live socket. Returns the socket.
fn deltaSeeded(tx: *host.Transaction) ![]const u8 {
    try deltaReady(tx, true);
    // Checkpoint lookup owns the bootstrap until it answers.
    try expect(tx.state.rpc.calls.len == 0);
    try expect(pendingIndex(tx, .store_get, "/sync") != null);
    try storeValue(tx, null);
    try expectScopes(tx, &sync.scopes);
    try respond(tx, d_initial);
    try respond(tx, d_initial_threads);
    try expect(tx.state.sync.cursor.? == 7);
    try expect(pendingIndex(tx, .store_put, "/sync") != null);
    const socket = try openSocket(tx);
    const before = tx.effects.items.len;
    try wsMessage(tx, socket, d_hello);
    const send = (try lastSend(tx, before)).?;
    try eql("core.changes.mode", p.s(send, "method"));
    try eql("delta", p.s(p.get(send, "params"), "mode"));
    try expect(p.uint(p.get(p.get(send, "params"), "cursor")).? == 7);
    try eql(tx.state.rpc.runtime_id.?, p.s(p.get(send, "target"), "runtime_id"));
    try eql(tx.state.rpc.instance_id.?, p.s(p.get(send, "target"), "instance_id"));
    try expect(pendingIndex(tx, .timer, delta.ACK_TIMER) != null);
    // The mandatory post-hello gateway bootstrap is covered by the replay.
    try wsMessage(tx, socket, d_bootstrap);
    try expect(tx.state.rpc.calls.len == 0);
    try ackWith(tx, socket, d_ack);
    try expect(tx.state.sync.delta.enabled and !tx.state.stale);
    try expect(pendingIndex(tx, .timer, delta.ACK_TIMER) == null);
    return socket;
}
/// Applies the recorded chat.thread change via a scoped refresh.
fn deltaChanged(tx: *host.Transaction, socket: []const u8) !void {
    try wsMessage(tx, socket, d_change);
    try expectScopes(tx, &.{ "workspaces", "config" });
    try respond(tx, d_scoped);
    // The cursor moves only once the catalog it acknowledges has committed.
    try expect(tx.state.sync.cursor.? == 7);
    try respond(tx, d_threads);
    try expect(tx.state.sync.cursor.? == 8);
    try expect(!tx.state.sync.loading and !tx.state.stale);
}

test "delta contract: no full snapshot after hello and projections equal legacy" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    const socket = try deltaSeeded(&tx);
    const after_hello = tx.effects.items.len;
    try deltaChanged(&tx, socket);
    try expectNoFullSnapshot(&tx, after_hello);
    var legacy = try host.Transaction.init(&h);
    defer legacy.deinit();
    try legacyTwin(&legacy, d_after, d_threads);
    try expectSameProjections(&tx, &legacy);
    try expect(std.mem.indexOf(u8, (try projections(&tx))[1], "After delta") != null);
}

test "delta reconnect resumes at the incorporated cursor without a snapshot" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    const first_socket = try deltaSeeded(&tx);
    try deltaChanged(&tx, first_socket);
    try tx.invalidateTransport();
    try sync.pump(&tx);
    try expect(!tx.state.sync.delta.enabled and tx.state.sync.delta.socket == null);
    const before = tx.effects.items.len;
    tx.state.rpc.phase = .ready;
    tx.state.rpc.full_resync = true;
    try sync.pump(&tx);
    try expect(tx.state.rpc.calls.len == 0 and tx.state.stale);
    const socket = try openSocket(&tx);
    try wsMessage(&tx, socket, d_hello);
    const send = (try lastSend(&tx, before)).?;
    try expect(p.uint(p.get(p.get(send, "params"), "cursor")).? == 8);
    try wsMessage(&tx, socket, d_bootstrap);
    try ackWith(&tx, socket, d_resume_ack);
    // The edit made while offline arrives as the replay after the cursor.
    try wsMessage(&tx, socket, d_resume_change);
    try expectScopes(&tx, &.{ "workspaces", "config" });
    try respond(&tx, d_resume_scoped);
    try respond(&tx, d_final_threads);
    try expect(tx.state.sync.cursor.? == 9 and !tx.state.stale);
    try expectNoFullSnapshot(&tx, before);
    var legacy = try host.Transaction.init(&h);
    defer legacy.deinit();
    try legacyTwin(&legacy, d_final, d_final_threads);
    try expectSameProjections(&tx, &legacy);
    try expect(std.mem.indexOf(u8, (try projections(&tx))[1], "Offline edit") != null);
}

test "delta expired, foreign nonce, regressed and malformed notices fall back then re-opt-in" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    const socket = try deltaSeeded(&tx);
    const bad = [_][]const u8{
        try frame(&tx, "[]", 8, ",\"expired\":true"),
        "{\"jsonrpc\":\"2.0\",\"method\":\"core.changes\",\"params\":{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"entries\":[],\"next_cursor\":9,\"envelope\":{\"instance_nonce\":\"another-instance\"},\"store_revision\":2}}}",
        try frame(&tx, "[]", 3, ""),
    };
    for (bad, 1..) |text, n| {
        const before = tx.effects.items.len;
        try wsMessage(&tx, socket, text);
        try expect(!tx.state.sync.delta.enabled and tx.state.stale);
        try expect(tx.state.sync.delta.fallbacks == n);
        // Recovery is a full legacy refresh; the feed is ignored meanwhile.
        try expectScopes(&tx, &sync.scopes);
        if (n < delta.MAX_FALLBACKS) {
            try wsMessage(&tx, socket, d_bootstrap);
            try wsMessage(&tx, socket, d_change);
            try expect(tx.state.rpc.calls.len == 1 and !tx.state.sync.dirty);
        }
        try respond(&tx, d_after);
        try respond(&tx, d_threads);
        try expect(tx.state.sync.cursor.? == 8);
        if (n < delta.MAX_FALLBACKS) {
            const send = (try lastSend(&tx, before)).?;
            try expect(p.uint(p.get(p.get(send, "params"), "cursor")).? == 8);
            try ackWith(&tx, socket, "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"mode\":\"delta\",\"cursor\":8}}");
            try expect(tx.state.sync.delta.enabled);
        }
    }
    // Repeated recovery on one socket: stay on K-09 until the next socket.
    try expect(tx.state.sync.delta.disabled and tx.state.sync.delta.control_id == null);
    try wsMessage(&tx, socket, d_change);
    try expectScopes(&tx, &sync.scopes);
    // A new socket opts in again.
    try respond(&tx, d_after);
    try respond(&tx, d_threads);
    const before = tx.effects.items.len;
    try wsMessage(&tx, try openSocket(&tx), d_hello);
    try expect((try lastSend(&tx, before)) != null);
}

test "delta opt-in rejection or timeout keeps the socket on legacy sync" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try deltaReady(&tx, true);
    try storeValue(&tx, null);
    try respond(&tx, d_initial);
    try respond(&tx, d_initial_threads);
    const socket = try openSocket(&tx);
    try wsMessage(&tx, socket, d_hello);
    try expect(tx.state.sync.delta.control_id != null);
    // Older gateways reject unknown requests with an id-0 error frame.
    try wsMessage(&tx, socket, "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}");
    try expect(tx.state.sync.delta.disabled);
    try expectScopes(&tx, &sync.scopes);
    try respond(&tx, d_after);
    try respond(&tx, d_threads);
    try wsMessage(&tx, socket, d_change);
    try expectScopes(&tx, &sync.scopes);
    try respond(&tx, d_after);
    try respond(&tx, d_threads);
    // Timeout on the next socket.
    const next = try openSocket(&tx);
    try wsMessage(&tx, next, d_hello);
    try expect(tx.state.sync.delta.control_id != null and !tx.state.sync.delta.disabled);
    const timer = tx.state.pending[pendingIndex(&tx, .timer, delta.ACK_TIMER).?];
    const event = try std.json.Stringify.valueAlloc(tx.allocator(), .{ .api_version = 1, .type = "timer_fired", .now_ms = timer.deadline, .wall_time_ms = WALL, .timer_id = timer.id, .generation = try gen(&tx) }, .{});
    try tx.apply(try host.parse(tx.allocator(), event));
    try sync.pump(&tx);
    try expect(tx.state.sync.delta.disabled and tx.state.sync.delta.control_id == null);
    try expectScopes(&tx, &sync.scopes);
    // A late acknowledgement is not a response to anything pending.
    try wsMessage(&tx, next, d_ack);
    try expect(!tx.state.sync.delta.enabled);
}

test "delta checkpoint restores a cold start without snapshots and rejects foreign instances" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    const socket = try deltaSeeded(&tx);
    try storeDone(&tx, false);
    try deltaChanged(&tx, socket);
    var stored: []const u8 = "";
    for (tx.effects.items) |effect| {
        if (host.eq(p.s(effect, "type"), "secure_store_put") and std.mem.endsWith(u8, p.s(effect, "key"), "/sync")) stored = p.s(effect, "value_base64");
    }
    const record = try host.parse(tx.allocator(), try @import("auth.zig").decode64(tx.allocator(), stored));
    try eql("8", p.s(record, "cursor"));
    try expect(p.get(record, "version").integer == 1);

    var cold = try host.Transaction.init(&h);
    defer cold.deinit();
    cold.state.sync = .{};
    try deltaReady(&cold, true);
    try storeValue(&cold, stored);
    try expect(cold.state.rpc.calls.len == 0 and cold.state.stale);
    try expect(cold.state.sync.cursor.? == 8);
    const before = cold.effects.items.len;
    const cold_socket = try openSocket(&cold);
    try wsMessage(&cold, cold_socket, d_hello);
    try expect(p.uint(p.get(p.get((try lastSend(&cold, before)).?, "params"), "cursor")).? == 8);
    try ackWith(&cold, cold_socket, d_resume_ack);
    try expectSameProjections(&cold, &tx);
    try expectNoFullSnapshot(&cold, 0);
    // An unchanged cursor is not rewritten.
    try expect(pendingIndex(&cold, .store_put, "/sync") == null);

    var foreign = try host.Transaction.init(&h);
    defer foreign.deinit();
    foreign.state.sync = .{};
    try deltaReady(&foreign, true);
    foreign.state.rpc.instance_id = "ffeeddccbbaa99887766554433221100";
    try storeValue(&foreign, stored);
    try expectScopes(&foreign, &sync.scopes);
    try expect(foreign.state.sync.cursor == null);
    // Corrupt records likewise only cost a seed.
    var corrupt = try host.Transaction.init(&h);
    defer corrupt.deinit();
    corrupt.state.sync = .{};
    try deltaReady(&corrupt, true);
    try storeValue(&corrupt, try rpc.encodeBase64(corrupt.allocator(), "{\"version\":1}"));
    try expectScopes(&corrupt, &sync.scopes);
}

test "workspace projection normalizes legacy milliseconds before recent sorting and age buckets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try host.parse(a,
        \\{"snapshot":{"workspaces":[{"workspace_id":"w","threads":[
        \\{"local_thread_id":"old","title":"Legacy","last_activity_at":1700000000999},
        \\{"local_thread_id":"new","title":"Current","last_activity_at":1790000000},
        \\{"local_thread_id":"unknown","title":"Unknown"}]}]}}
    );
    const catalog = p.rows(p.get(p.rows(p.get(p.get(data, "snapshot"), "workspaces"))[0], "threads"));
    // Both the initial snapshot and the completed catalog use the same units.
    for ([_]bool{ false, true }) |has_catalog| {
        var listed: std.ArrayList(std.json.Value) = .empty;
        for (catalog) |row| {
            var copy = try host.parse(a, try std.json.Stringify.valueAlloc(a, row, .{}));
            try copy.object.put(a, "workspace_id", .{ .string = "w" });
            try listed.append(a, copy);
        }
        const models = try p.project(a, data, listed.items, has_catalog, 1790000060000);
        try eql("new", models.history[0].thread_id);
        try eql("old", models.history[1].thread_id);
        try eql("unknown", models.history[2].thread_id);
        try std.testing.expectEqual(@as(?i64, 1700000000000), models.workspaces[0].threads[0].last_activity_at_ms);
        try std.testing.expectEqual(@as(?i64, 1790000000000), models.history[0].last_activity_at_ms);
        try std.testing.expectEqual(@as(?i64, null), models.history[2].last_activity_at_ms);
        try eql("Today", models.history[0].history_bucket);
        try eql("Older", models.history[1].history_bucket);
        try eql("new", models.workspaces[0].panes[0].thread_id.?);
        try eql("old", models.workspaces[0].panes[1].thread_id.?);
    }
}

test "workspace identity matches the cross-client FNV-1a vectors" {
    // Pinned in docs/workspace-switcher-sidebar.md consumers (desktop, web, iOS, Android).
    try std.testing.expectEqual(@as(u32, 0x48d4ea0e), p.identityHash("ws-alpha"));
    try std.testing.expectEqual(@as(u8, 14), p.iconIndex("ws-alpha"));
    try std.testing.expectEqual(@as(u8, 2), p.colorIndex("ws-alpha"));
    try std.testing.expectEqual(@as(u32, 0x9f38bee9), p.identityHash("baaa819e66d8f3be"));
    try std.testing.expectEqual(@as(u8, 9), p.iconIndex("baaa819e66d8f3be"));
    try std.testing.expectEqual(@as(u8, 6), p.colorIndex("baaa819e66d8f3be"));
    try std.testing.expectEqual(@as(u32, 0x811c9dc5), p.identityHash(""));
    try std.testing.expectEqual(@as(u8, 5), p.iconIndex(""));
    try std.testing.expectEqual(@as(u8, 5), p.colorIndex(""));
}

test "workspace projection carries the repository manifest and primary group key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try host.parse(a,
        \\{"snapshot":{"workspaces":[
        \\{"workspace_id":"w","path":"/src/verde","repositories":[
        \\{"repository_id":"docs","label":"Docs","vcs_identity":"git@github.com:Other/Docs.git","bindings":[]},
        \\{"repository_id":"primary","label":"verde","vcs_identity":"git@github.com:JonathanRiche/Verde.git","default_branch":"master",
        \\"bindings":[{"runtime_id":"rt","root_path":"/src/verde","availability":"missing"},{"runtime_id":"","root_path":"/x"},{"runtime_id":"rt2","root_path":"/y"}]},
        \\{"label":"no id"}]},
        \\{"workspace_id":"local","repositories":[{"repository_id":"primary","label":"local","vcs_identity":"/srv/repo.git"}]},
        \\{"workspace_id":"none","repositories":[{"repository_id":"primary","label":"none"}]},
        \\{"workspace_id":"old"}]}}
    );
    const models = try p.project(a, data, &.{}, false, 0);
    const w = models.workspaces[0];
    try std.testing.expectEqual(@as(usize, 2), w.repositories.len);
    try eql("docs", w.repositories[0].repository_id);
    const primary = w.repositories[1];
    try eql("primary", primary.repository_id);
    try eql("git@github.com:JonathanRiche/Verde.git", primary.vcs_identity.?);
    try eql("master", primary.default_branch.?);
    try std.testing.expectEqual(@as(usize, 2), primary.bindings.len);
    try eql("missing", primary.bindings[0].availability);
    try eql("available", primary.bindings[1].availability);
    try eql("v1:github.com/jonathanriche/verde", w.group_key.?);
    try std.testing.expectEqual(@as(?[]const u8, null), models.workspaces[1].group_key);
    try std.testing.expectEqual(@as(?[]const u8, null), models.workspaces[2].group_key);
    try std.testing.expectEqual(@as(?[]const u8, null), models.workspaces[2].repositories[0].vcs_identity);
    // Daemons without repositories in core.snapshot keep the old shape.
    try std.testing.expectEqual(@as(usize, 0), models.workspaces[3].repositories.len);
    try std.testing.expectEqual(@as(?[]const u8, null), models.workspaces[3].group_key);
    const json = try std.json.Stringify.valueAlloc(a, models.workspaces[3], .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"repositories\":[],\"group_key\":null") != null);
}
