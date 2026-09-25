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

test "catalog revision expiration restarts and repeated cursors fail visibly" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try ready(&tx);
    try respond(&tx, snapshot);
    try respond(&tx, first);
    try expect(tx.state.rpc.calls.len > 0);
    const call = tx.state.rpc.calls[0];
    tx.state.rpc.results = try tx.allocator().dupe(rpc.Result, &.{.{ .id = call.id, .intent_id = null, .@"error" = .{ .domain = "rpc", .code = "remote_error", .message = "Rejected", .rpc_code = "revision_expired" } }});
    tx.state.rpc.calls = &.{};
    try sync.pump(&tx);
    try expect(tx.state.sync.staged.len == 0);
    try respond(&tx, first);
    try respond(&tx, first);
    try expect(tx.state.sync.@"error" != null);
    try expect(tx.state.sync.cursor == null);
}

test "partial snapshots preserve omitted sections and changed nonce resets cursors" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try fixture(&tx);
    try sync.applySnapshotScopes(&tx, try host.parse(tx.allocator(), @embedFile("fixtures/sync/snapshot-config.json")), &.{"config"});
    try sync.applySnapshot(&tx, try host.parse(tx.allocator(), "{\"snapshot\":{},\"store_revision\":1,\"turns\":[],\"incomplete_scopes\":[\"turns\"]}"));
    try expect(p.rows(p.get(p.get(tx.state.sync.snapshot, "snapshot"), "workspaces")).len == 1);
    try expect(p.get(tx.state.sync.snapshot, "config") == .object);
    try push(&tx, "core.changes", "{\"entries\":[],\"expired\":true,\"envelope\":{\"instance_nonce\":\"new\"},\"next_cursor\":1000}");
    try expect(tx.state.sync.cursor == null);
    try expect(tx.state.sync.snapshot_id != null);
}

test "projection sort_index identity, omitted settings, explicit nulls and attention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ws = try host.parse(a, "{\"workspace_id\":\"w\",\"path\":\"/project\",\"workspace_layout_json\":\"{\\\"panes\\\":[{\\\"kind\\\":\\\"chat\\\",\\\"thread\\\":42},{\\\"kind\\\":\\\"chat\\\",\\\"thread\\\":42}]}\"}");
    const t = try host.parse(a, "{\"workspace_id\":\"w\",\"local_thread_id\":\"x\",\"title\":\"X\",\"sort_index\":42}");
    const turns = try host.parse(a, "[{\"workspace_id\":\"w\",\"local_thread_id\":\"x\",\"status\":\"waiting_approval\",\"started_at_ms\":123}]");
    const panes = try p.panesForWorkspace(a, ws, &.{t}, .null, turns);
    try expect(panes.len == 1);
    try expect(panes[0].attention and panes[0].can_stop);
    try expect(panes[0].started_at_ms.? == 123);
    const source = try host.parse(a, "{\"reasoning_effort\":\"high\",\"fast_mode\":\"on\"}");
    const merged = try p.mergeThreadCatalogSettings(a, t, source, .null);
    try eql("high", p.s(merged, "reasoning_effort"));
    const explicit = try p.mergeThreadCatalogSettings(a, try host.parse(a, "{\"reasoning_effort\":null}"), source, .null);
    try expect(p.get(explicit, "reasoning_effort") == .null);
    try expect(try p.parseWorkspaceLayout(a, .{ .string = "invalid" }) == .null);
}

test "sync consumes only owned RPC outcomes and stale sockets have no effects" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try fixture(&tx);
    tx.state.rpc.results = try tx.allocator().dupe(rpc.Result, &.{.{ .id = 999, .intent_id = null, .value = .null }});
    try sync.pump(&tx);
    try expect(tx.state.rpc.results.len == 1);
    const before = tx.effects.items.len;
    try tx.apply(try host.parse(tx.allocator(), "{\"api_version\":1,\"type\":\"ws_message\",\"now_ms\":2,\"wall_time_ms\":2,\"socket_id\":\"stale\",\"generation\":\"0\",\"text\":\"{}\"}"));
    try expect(tx.effects.items.len == before);
}

test "queries remain pure and failed output allocation preserves populated state" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try fixture(&tx);
    const batch = try tx.commit(&h, std.testing.allocator);
    defer std.testing.allocator.free(batch);
    const before = try std.json.Stringify.valueAlloc(std.testing.allocator, h.state, .{});
    defer std.testing.allocator.free(before);
    const one = try h.query("workspaces", std.testing.allocator);
    defer std.testing.allocator.free(one);
    const two = try h.query("workspaces", std.testing.allocator);
    defer std.testing.allocator.free(two);
    try eql(one, two);
    const after = try std.json.Stringify.valueAlloc(std.testing.allocator, h.state, .{});
    defer std.testing.allocator.free(after);
    try eql(before, after);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, h.handle("{\"api_version\":1,\"type\":\"background\",\"now_ms\":3,\"wall_time_ms\":3}", failing.allocator()));
    const unchanged = try std.json.Stringify.valueAlloc(std.testing.allocator, h.state, .{});
    defer std.testing.allocator.free(unchanged);
    try eql(before, unchanged);
}

test "full resync drops superseded sync results but preserves other feature results" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try ready(&tx);
    const old = tx.state.sync.snapshot_id.?;
    tx.state.rpc.results = try tx.allocator().dupe(rpc.Result, &.{ .{ .id = old, .intent_id = "@sync", .value = try host.parse(tx.allocator(), snapshot) }, .{ .id = 999, .intent_id = "chat", .value = .null } });
    tx.state.rpc.full_resync = true;
    try sync.pump(&tx);
    try expect(tx.state.sync.snapshot == .null);
    try expect(tx.state.sync.snapshot_id.? != old);
    try expect(tx.state.rpc.results.len == 1);
    try expect(tx.state.rpc.results[0].id == 999);
    try expect(p.uint(try host.parse(tx.allocator(), "18446744073709551615")).? == std.math.maxInt(u64));
}

test "valid legacy socket notification enters projection only at the matching generation" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try fixture(&tx);
    const socket = try tx.emit("ws_connect", .{});
    try tx.track(.socket, socket, "fixture");
    const note = try std.fmt.allocPrint(tx.allocator(), "{{\"method\":\"core.changes\",\"params\":{{\"result\":{s}}}}}", .{changes});
    const event = try std.json.Stringify.valueAlloc(tx.allocator(), .{ .api_version = 1, .type = "ws_message", .now_ms = 2, .wall_time_ms = 2, .socket_id = socket, .generation = "0", .text = note }, .{});
    try tx.apply(try host.parse(tx.allocator(), event));
    try expect(tx.state.sync.snapshot_id != null);
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

test "legacy host without the capability keeps K-09 sync" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    try deltaReady(&tx, false);
    try expectScopes(&tx, &sync.scopes);
    try respond(&tx, d_initial);
    try respond(&tx, d_initial_threads);
    const socket = try openSocket(&tx);
    try wsMessage(&tx, socket, d_hello);
    try wsMessage(&tx, socket, d_change);
    try expectScopes(&tx, &sync.scopes);
    try respond(&tx, d_after);
    try respond(&tx, d_threads);
    try expect(tx.state.sync.cursor.? == 8);
    for (tx.effects.items) |effect| {
        try expect(!host.eq(p.s(effect, "type"), "ws_send"));
        try expect(!std.mem.endsWith(u8, p.s(effect, "key"), "/sync"));
    }
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

test "delta cancelled scoped read keeps its cursor and a new instance reseeds" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    const socket = try deltaSeeded(&tx);
    try wsMessage(&tx, socket, d_change);
    try expect(tx.state.sync.loading);
    try tx.invalidateTransport();
    try sync.pump(&tx);
    try expect(!tx.state.sync.loading and tx.state.sync.@"error" == null);
    try expect(tx.state.sync.cursor.? == 7 and tx.state.sync.delta.active_cursor == null);
    tx.state.rpc.phase = .ready;
    tx.state.rpc.full_resync = true;
    try sync.pump(&tx);
    try expect(tx.state.rpc.calls.len == 0);
    const before = tx.effects.items.len;
    try wsMessage(&tx, try openSocket(&tx), d_hello);
    try expect(p.uint(p.get(p.get((try lastSend(&tx, before)).?, "params"), "cursor")).? == 7);
    // A restarted daemon instance invalidates the cursor: full legacy seed.
    try tx.invalidateTransport();
    tx.state.rpc.instance_id = "ffeeddccbbaa99887766554433221100";
    tx.state.rpc.phase = .ready;
    tx.state.rpc.full_resync = true;
    try sync.pump(&tx);
    try expectScopes(&tx, &sync.scopes);
    try expect(tx.state.sync.cursor == null and tx.state.sync.delta.instance_id.len > 0);
    try eql("ffeeddccbbaa99887766554433221100", tx.state.sync.delta.instance_id);
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

test "delta error and invalid notices fall back and superseded scoped reads are dropped" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    const socket = try deltaSeeded(&tx);
    try wsMessage(&tx, socket, d_change);
    const scoped = tx.state.sync.snapshot_id.?;
    // An entry beyond next_cursor is not a valid journal page.
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":20,\"topic\":\"session\",\"resource_id\":\"x\"}]", 9, ""));
    try expect(tx.state.sync.delta.fallbacks == 1);
    try expect(tx.state.sync.snapshot_id.? != scoped);
    try expect(tx.state.rpc.calls.len == 2);
    // The superseded scoped answer arrives first and is discarded.
    try respond(&tx, d_scoped);
    try expect(tx.state.sync.loading and tx.state.sync.cursor == null);
    try expectScopes(&tx, &sync.scopes);
    try respond(&tx, d_after);
    try respond(&tx, d_threads);
    try ackWith(&tx, socket, d_resume_ack);
    try expect(tx.state.sync.delta.enabled);
    try wsMessage(&tx, socket, "{\"jsonrpc\":\"2.0\",\"method\":\"core.changes\",\"params\":{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32603,\"message\":\"poll failed\"}}}");
    try expect(tx.state.sync.delta.fallbacks == 2 and !tx.state.sync.delta.enabled);
    try expectScopes(&tx, &sync.scopes);
    try respond(&tx, d_after);
    try respond(&tx, d_threads);
    try ackWith(&tx, socket, d_resume_ack);
    // A failed scoped read also recovers through legacy.
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":9,\"topic\":\"chat.turn\",\"resource_id\":\"t\"}]", 9, ""));
    try expectScopes(&tx, &.{ "turns", "config" });
    const call = tx.state.rpc.calls[0];
    tx.state.rpc.results = try tx.allocator().dupe(rpc.Result, &.{.{ .id = call.id, .intent_id = "@sync", .@"error" = .{ .domain = "rpc", .code = "remote_error", .message = "Rejected" } }});
    tx.state.rpc.calls = &.{};
    try sync.pump(&tx);
    try expect(tx.state.sync.delta.disabled and tx.state.sync.@"error" == null);
    try expectScopes(&tx, &sync.scopes);
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

test "delta checkpoint write failures are non-fatal and oversized records are deleted" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    const socket = try deltaSeeded(&tx);
    try storeDone(&tx, true);
    try expect(tx.state.sync.@"error" == null and tx.state.sync.delta.enabled);
    try deltaChanged(&tx, socket);
    // The failed record is retried at the next incorporated cursor.
    try expect(pendingIndex(&tx, .store_put, "/sync") != null);
    // Two cursors while a write is in flight coalesce into one follow-up.
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":9,\"topic\":\"notification\",\"resource_id\":\"n\"}]", 9, ""));
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":10,\"topic\":\"notification\",\"resource_id\":\"n\"}]", 10, ""));
    try expect(tx.state.sync.cursor.? == 10 and tx.state.sync.delta.save_again);
    const before = tx.effects.items.len;
    try storeDone(&tx, false);
    var puts: usize = 0;
    for (tx.effects.items[before..]) |effect| {
        if (host.eq(p.s(effect, "type"), "secure_store_put")) puts += 1;
    }
    try expect(puts == 1);
    try storeDone(&tx, false);
    // A record over the per-item bound is deleted once instead of kept stale.
    const big = try tx.allocator().alloc(u8, delta.CHECKPOINT_MAX);
    @memset(big, 'x');
    var row = try host.parse(tx.allocator(), "{\"workspace_id\":\"delta-ws\",\"local_thread_id\":\"big\"}");
    try row.object.put(tx.allocator(), "title", .{ .string = big });
    tx.state.sync.catalog = try tx.allocator().dupe(std.json.Value, &.{row});
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":11,\"topic\":\"notification\",\"resource_id\":\"n\"}]", 11, ""));
    try expect(pendingIndex(&tx, .store_delete, "/sync") != null);
    try storeDone(&tx, false);
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":12,\"topic\":\"notification\",\"resource_id\":\"n\"}]", 12, ""));
    try expect(pendingIndex(&tx, .store_delete, "/sync") == null and pendingIndex(&tx, .store_put, "/sync") == null);
}

test "delta notices coalesce, replays are idempotent and heartbeats are free" {
    var h = try init();
    defer h.deinit();
    var tx = try host.Transaction.init(&h);
    defer tx.deinit();
    const socket = try deltaSeeded(&tx);
    try wsMessage(&tx, socket, d_change);
    try wsMessage(&tx, socket, d_change);
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":8,\"topic\":\"chat.thread\",\"resource_id\":\"delta-thread\"},{\"change_seq\":9,\"topic\":\"chat.turn\",\"resource_id\":\"t\"},{\"change_seq\":10,\"topic\":\"process\",\"resource_id\":\"p\"}]", 10, ""));
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":11,\"topic\":\"session\",\"resource_id\":\"s\"}]", 11, ""));
    try expectScopes(&tx, &.{ "workspaces", "config" });
    try respond(&tx, d_scoped);
    try respond(&tx, d_threads);
    try expect(tx.state.sync.cursor.? == 8);
    // One coalesced read for everything queued behind the first.
    try expectScopes(&tx, &.{ "registry", "sessions", "turns", "config" });
    try respond(&tx, d_scoped);
    try expect(tx.state.sync.cursor.? == 11 and !tx.state.sync.loading);
    try wsMessage(&tx, socket, try frame(&tx, "[]", 11, ",\"heartbeat\":true"));
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":12,\"topic\":\"notification\",\"resource_id\":\"n\"}]", 12, ""));
    try expect(tx.state.sync.cursor.? == 12 and tx.state.rpc.calls.len == 0);
    // Unknown future topics refresh every scope but stay in delta mode.
    try wsMessage(&tx, socket, try frame(&tx, "[{\"change_seq\":13,\"topic\":\"future.topic\",\"resource_id\":\"f\"}]", 13, ""));
    try expect(tx.state.sync.delta.enabled);
    try expect(tx.state.sync.delta.active_cursor.? == 13 and tx.state.sync.delta.active_catalog);
}
