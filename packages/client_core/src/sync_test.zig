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
    const input = try std.json.Stringify.valueAlloc(a, .{ .api_version = 1, .type = "http_response", .now_ms = 1, .wall_time_ms = 1700000050000, .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(a, "{d}", .{tx.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(a, envelope), .@"error" = @as(?u8, null) }, .{});
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
