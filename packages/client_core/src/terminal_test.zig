//! Synthetic VT goldens and deterministic pump schedules. Never log PTY contents.
const std = @import("std");
const h = @import("host.zig");
const vt = @import("terminal.zig");
const pump = @import("terminal_pump.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const abi = @import("root.zig");
const expect = std.testing.expect;
const A = std.testing.allocator;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"terminal","label":"Terminal","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;
fn snapshot(t: *vt.Terminal) !std.json.Parsed(vt.Snapshot) {
    const bytes = try t.snapshot(A);
    defer A.free(bytes);
    return std.json.parseFromSlice(vt.Snapshot, A, bytes, .{ .allocate = .alloc_always });
}
// Use boolean comparisons so a failed assertion never prints terminal content.
fn same(left: []const u8, right: []const u8) !void {
    try expect(std.mem.eql(u8, left, right));
}
test "VT recorded daemon replay produces styled grapheme grid and modes" {
    var arena = std.heap.ArenaAllocator.init(A);
    defer arena.deinit();
    const value = try h.parse(arena.allocator(), @embedFile("fixtures/terminal/tail.json"));
    const t = try vt.Terminal.create(A, "{\"api_version\":1,\"cols\":20,\"rows\":4,\"scrollback_rows\":100}");
    defer t.destroy();
    try t.write(p.s(value, "text"));
    var grid = try snapshot(t);
    defer grid.deinit();
    try expect(grid.value.cells.len == 80);
    try same(grid.value.title, "Fixture");
    try expect(grid.value.vt_modes.application_cursor and grid.value.vt_modes.bracketed_paste);
    try same(grid.value.cells[0].text, "R");
    try expect(grid.value.cells[0].bold);
    try expect(!std.mem.eql(u8, grid.value.cells[0].fg, grid.value.cells[10].fg));
    try same(grid.value.cells[26].text, "界");
    try expect(grid.value.cells[26].width == 2 and grid.value.cells[27].width == 0);
    try same(grid.value.cells[29].text, "é");
}
test "VT partial UTF8 and escapes, alternate screen, resize and scroll" {
    const t = try vt.Terminal.create(A, "{\"api_version\":1,\"cols\":8,\"rows\":2,\"scrollback_rows\":100}");
    defer t.destroy();
    try t.write("\xe7");
    try t.write("\x95\x8c\x1b[");
    try t.write("31mX");
    var grid = try snapshot(t);
    defer grid.deinit();
    try same(grid.value.cells[0].text, "界");
    try same(grid.value.cells[2].text, "X");
    try t.write("\x1b[?1049hALT\x1b[?1049l");
    var restored = try snapshot(t);
    defer restored.deinit();
    try same(restored.value.cells[0].text, "界");
    try t.write("\r\na\r\nb\r\nc\r\nd");
    try t.scroll(100);
    var older = try snapshot(t);
    defer older.deinit();
    try expect(older.value.scroll_offset > 0);
    try t.scroll(-100);
    try t.resize(12, 3);
    var resized = try snapshot(t);
    defer resized.deinit();
    try expect(resized.value.cells.len == 36 and resized.value.scroll_offset == 0);
    try std.testing.expectError(error.InvalidArgument, t.resize(0, 1));
    try std.testing.expectError(error.ResourceLimit, t.resize(512, 512));
}
test "VT replies survive snapshot allocation failure and drain only on successful ABI output" {
    const t = try vt.Terminal.create(A, "{\"api_version\":1,\"cols\":8,\"rows\":2,\"scrollback_rows\":0}");
    defer t.destroy();
    try t.write("\x1b[6n");
    var failing = std.testing.FailingAllocator.init(A, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, t.snapshot(failing.allocator()));
    var before = try snapshot(t);
    defer before.deinit();
    try expect(before.value.reply_bytes_base64.len > 0);
    var buf: abi.Buf = .{};
    try expect(abi.vcTermSnapshot(t, &buf) == 0);
    defer abi.vcBufFree(buf);
    var after = try snapshot(t);
    defer after.deinit();
    try expect(after.value.reply_bytes_base64.len == 0);
}
fn ready(tx: *h.Transaction) !void {
    tx.state.lifecycle = .foreground;
    tx.state.network_available = true;
    try rpc.attachBearer(tx, "fixture-token", "0123456789abcdef0123456789abcdef", "fixture-pin");
    tx.state.rpc.instance_id = "00112233445566778899aabbccddeeff";
    tx.state.rpc.phase = .ready;
}
fn event(tx: *h.Transaction, tag: []const u8, fields: anytype) !void {
    var value = try h.parse(tx.allocator(), try h.encode(tx.allocator(), fields));
    if (value != .object) value = .{ .object = .empty };
    const a = tx.allocator();
    try value.object.put(a, "api_version", .{ .integer = 1 });
    try value.object.put(a, "type", .{ .string = tag });
    try value.object.put(a, "now_ms", .{ .integer = tx.state.now_ms orelse 0 });
    try value.object.put(a, "wall_time_ms", .{ .integer = 0 });
    tx.apply(value) catch |err| {
        std.debug.print("terminal test event {s} failed: {s}\n", .{ tag, @errorName(err) });
        return err;
    };
    pump.pump(tx) catch |err| {
        std.debug.print("terminal test pump failed: {s}\n", .{@errorName(err)});
        return err;
    };
}
fn findCall(tx: *h.Transaction, method: []const u8) !rpc.Call {
    for (tx.state.rpc.calls) |call| if (h.eq(call.method, method)) return call;
    std.debug.print("missing expected method {s}; call count {d}\n", .{ method, tx.state.rpc.calls.len });
    return error.MissingCall;
}
fn response(tx: *h.Transaction, call: rpc.Call, value: V) !void {
    const body = try h.encode(tx.allocator(), .{ .jsonrpc = "2.0", .id = call.id, .result = value });
    try event(tx, "http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(tx.allocator(), "{d}", .{tx.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(tx.allocator(), body), .@"error" = @as(?u8, null) });
}
fn fixture(tx: *h.Transaction, method: []const u8, text: []const u8) !void {
    try response(tx, try findCall(tx, method), try h.parse(tx.allocator(), text));
}
fn attach(tx: *h.Transaction) !void {
    try event(tx, "terminal_attach", .{ .intent_id = "attach", .terminal_id = "k12-fixture" });
}
fn output(tx: *h.Transaction) !V {
    var index = tx.effects.items.len;
    while (index > 0) {
        index -= 1;
        const e = tx.effects.items[index];
        if (h.eq(p.s(e, "type"), "terminal_output")) return e;
    }
    for (tx.state.terminal.rows) |r| if (r.view.@"error") |err| std.debug.print("terminal result code {s}\n", .{err.code});
    return error.MissingOutput;
}
fn ack(tx: *h.Transaction, effect: V, failure: bool) !void {
    try event(tx, "terminal_applied", .{ .effect_id = p.s(effect, "effect_id"), .generation = p.s(effect, "generation"), .terminal_id = "k12-fixture", .grid_revision = "1", .@"error" = if (failure) h.PlatformFailure{ .code = .resource } else @as(?h.PlatformFailure, null) });
}
fn timer(tx: *h.Transaction) !h.Pending {
    for (tx.state.pending) |pending| if (pending.kind == .timer) return pending;
    return error.MissingTimer;
}
fn fire(tx: *h.Transaction, pending: h.Pending) !void {
    try event(tx, "timer_fired", .{ .timer_id = pending.id, .generation = try std.fmt.allocPrint(tx.allocator(), "{d}", .{pending.generation}) });
}
fn request(tx: *h.Transaction, call: rpc.Call) !V {
    const encoded = call.body_base64;
    const bytes = try tx.allocator().alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    try std.base64.standard.Decoder.decode(bytes, encoded);
    return h.parse(tx.allocator(), bytes);
}
test "pump session tail commits offsets only on ACK and waits 160ms active / 1s idle" {
    var host = try h.Host.init(A, config);
    defer host.deinit();
    var tx = try h.Transaction.init(&host);
    defer tx.deinit();
    try ready(&tx);
    try attach(&tx);
    const first_call = try findCall(&tx, "session.tail");
    try expect(p.get(p.get(try request(&tx, first_call), "params"), "offset") == .null);
    try fixture(&tx, "session.tail", @embedFile("fixtures/terminal/tail.json"));
    const first = try output(&tx);
    try expect(p.yes(p.get(first, "reset")));
    try expect(tx.state.terminal.rows[0].offset == null);
    try expect(tx.state.rpc.calls.len == 0);
    try ack(&tx, first, false);
    const offset = tx.state.terminal.rows[0].offset.?;
    const active = try timer(&tx);
    try expect(active.deadline == 160);
    try ack(&tx, first, false);
    try expect(tx.state.pending.len == 1);
    // Early timer must get a new ID and cannot issue another read yet.
    tx.state.now_ms = 80;
    try fire(&tx, active);
    const replacement = try timer(&tx);
    try expect(!h.eq(active.id, replacement.id));
    tx.state.now_ms = 160;
    try fire(&tx, replacement);
    const call = try findCall(&tx, "session.tail");
    try expect(p.uint(p.get(p.get(try request(&tx, call), "params"), "offset")).? == offset);
    try response(&tx, call, try h.parse(tx.allocator(), try h.encode(tx.allocator(), .{ .id = "k12-fixture", .text = "", .running = true, .next_offset = offset })));
    try ack(&tx, try output(&tx), false);
    try expect((try timer(&tx)).deadline == 1160);
    const bytes = try tx.commit(&host, A);
    defer A.free(bytes);
    const query = try host.query("terminal:k12-fixture", A);
    defer A.free(query);
    const decoded = try std.json.parseFromSlice(@import("wire.zig").Query(pump.View), A, query, .{});
    defer decoded.deinit();
    try expect(decoded.value.data.?.next_offset != null);
}
test "pump failed apply resets replay, ring gaps reset, background ignores stale callbacks" {
    var host = try h.Host.init(A, config);
    defer host.deinit();
    var tx = try h.Transaction.init(&host);
    defer tx.deinit();
    try ready(&tx);
    try attach(&tx);
    try fixture(&tx, "session.tail", @embedFile("fixtures/terminal/tail.json"));
    const old = try output(&tx);
    try ack(&tx, old, true);
    try expect(tx.state.terminal.rows[0].offset == null);
    tx.state.now_ms = 1000;
    try fire(&tx, try timer(&tx));
    try response(&tx, try findCall(&tx, "session.tail"), try h.parse(tx.allocator(), "{\"text\":\"x\",\"running\":true,\"next_offset\":9007199254740993}"));
    try ack(&tx, try output(&tx), false);
    try expect(tx.state.terminal.rows[0].offset.? == 9007199254740993);
    tx.state.now_ms = 1160;
    try fire(&tx, try timer(&tx));
    try response(&tx, try findCall(&tx, "session.tail"), try h.parse(tx.allocator(), "{\"text\":\"x\",\"running\":true,\"offset\":9007199254741000,\"next_offset\":9007199254741001}"));
    const gap = try output(&tx);
    try expect(p.yes(p.get(gap, "reset")));
    try event(&tx, "background", .{});
    try expect(tx.state.pending.len == 0 and tx.state.rpc.calls.len == 0);
    try ack(&tx, gap, false);
    try expect(tx.state.terminal.rows[0].offset == null);
    try ready(&tx);
    try pump.pump(&tx);
    try expect(tx.state.rpc.calls.len == 1);
    try event(&tx, "terminal_detach", .{ .intent_id = "detach", .terminal_id = "k12-fixture" });
    try expect(tx.state.rpc.calls.len == 0);
}
test "pump create resize kill and raw replies use only targeted session methods" {
    var host = try h.Host.init(A, config);
    defer host.deinit();
    var tx = try h.Transaction.init(&host);
    defer tx.deinit();
    try ready(&tx);
    try event(&tx, "terminal_create", .{ .intent_id = "create", .workspace_id = "ws", .cwd = "/tmp/k12-fixture", .cols = 20, .rows = 4 });
    const id = tx.state.terminal.rows[0].view.terminal_id;
    const create = try findCall(&tx, "session.create");
    try expect(p.get(try request(&tx, create), "target") == .object);
    var created = try h.parse(tx.allocator(), @embedFile("fixtures/terminal/create.json"));
    try created.object.getPtr("session").?.object.put(tx.allocator(), "id", .{ .string = id });
    try response(&tx, create, created);
    try event(&tx, "terminal_resize", .{ .intent_id = "resize", .terminal_id = id, .cols = 24, .rows = 6 });
    try fixture(&tx, "session.resize", @embedFile("fixtures/terminal/resize.json"));
    try expect(tx.state.terminal.rows[0].view.cols == 24);
    try event(&tx, "terminal_reply", .{ .terminal_id = id, .bytes_base64 = "G1swbg==" });
    try fixture(&tx, "session.write", @embedFile("fixtures/terminal/write.json"));
    try event(&tx, "terminal_kill", .{ .intent_id = "kill", .terminal_id = id });
    try fixture(&tx, "session.kill", @embedFile("fixtures/terminal/kill.json"));
    try expect(!tx.state.terminal.rows[0].view.attached and tx.state.rpc.calls.len == 0);
    for (tx.effects.items) |e| if (h.eq(p.s(e, "type"), "http_request")) {
        const encoded = p.s(e, "body_base64");
        const bytes = try tx.allocator().alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
        try std.base64.standard.Decoder.decode(bytes, encoded);
        const method = p.s(try h.parse(tx.allocator(), bytes), "method");
        try expect(std.mem.startsWith(u8, method, "session."));
        try expect(@import("headless").access_protocol.requiredScopeMaskForRpc(method) != null);
    };
}
test "keys encode Ctrl Alt application arrows and bracketed paste once" {
    var arena = std.heap.ArenaAllocator.init(A);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { key: []const u8, ctrl: bool, alt: bool, expected: []const u8 }{
        .{ .key = "c", .ctrl = true, .alt = false, .expected = "\x03" },
        .{ .key = "x", .ctrl = false, .alt = true, .expected = "\x1bx" },
        .{ .key = "ArrowUp", .ctrl = false, .alt = false, .expected = "\x1bOA" },
        .{ .key = "ArrowLeft", .ctrl = true, .alt = false, .expected = "\x1b[1;5D" },
    }) |case| {
        const value = try h.parse(a, try h.encode(a, .{ .vt_modes = .{ .application_cursor = true, .bracketed_paste = true }, .input = .{ .kind = "key", .key = case.key, .ctrl = case.ctrl, .alt = case.alt, .shift = false } }));
        try same(try pump.encodeInput(a, value), case.expected);
    }
    try same(pump.alignPtyStream("broken\n\x1b[2Jok"), "\x1b[2Jok");
}
test "paste chunks serialize on success, preserve UTF8 and never replay after ambiguous write" {
    var host = try h.Host.init(A, config);
    defer host.deinit();
    var tx = try h.Transaction.init(&host);
    defer tx.deinit();
    try ready(&tx);
    try attach(&tx);
    const paste = try tx.allocator().alloc(u8, 9000);
    for (0..3000) |i| @memcpy(paste[i * 3 ..][0..3], "界");
    const fields = .{ .intent_id = "paste", .terminal_id = "k12-fixture", .vt_modes = .{ .application_cursor = false, .bracketed_paste = true }, .input = .{ .kind = "paste", .text = paste, .ctrl = false, .alt = false, .shift = false } };
    try event(&tx, "terminal_input", fields);
    const write = try findCall(&tx, "session.write");
    const text = p.s(p.get(try request(&tx, write), "params"), "text");
    try expect(text.len <= 4096 and std.unicode.utf8ValidateSlice(text) and std.mem.startsWith(u8, text, "\x1b[200~"));
    try event(&tx, "terminal_input", fields);
    try expect((try findCall(&tx, "session.write")).id == write.id);
    try fixture(&tx, "session.write", @embedFile("fixtures/terminal/write.json"));
    const second = try findCall(&tx, "session.write");
    try expect(second.id != write.id);
    try event(&tx, "http_response", .{ .effect_id = second.effect_id, .generation = "0", .status = @as(?u8, null), .headers = .{}, .body_base64 = @as(?u8, null), .@"error" = h.TransportFailure{ .kind = .network, .code = .reset } });
    try expect(tx.state.terminal.rows[0].actions.len == 0);
    try same(tx.state.receipts[1].operation.state, "uncertain");
    try pump.pump(&tx);
    for (tx.state.rpc.calls) |call| try expect(!h.eq(call.method, "session.write"));
}

test "terminal selectors decode once and failed batch allocation cannot consume input" {
    var host = try h.Host.init(A, config);
    defer host.deinit();
    var tx = try h.Transaction.init(&host);
    defer tx.deinit();
    try ready(&tx);
    try event(&tx, "terminal_attach", .{ .intent_id = "attach-special", .terminal_id = "session:%2F/one" });
    const committed = try tx.commit(&host, A);
    defer A.free(committed);
    const batch = try std.json.parseFromSlice(V, A, committed, .{});
    defer batch.deinit();
    var found = false;
    for (p.rows(p.get(batch.value, "effects"))) |effect| {
        if (!h.eq(p.s(effect, "type"), "state_changed")) continue;
        for (p.rows(p.get(effect, "scopes"))) |scope| if (scope == .string and h.eq(scope.string, "terminal:session%3A%252F%2Fone")) {
            found = true;
        };
    }
    try expect(found);
    const query = try host.query("terminal:session%3A%252F%2Fone", A);
    defer A.free(query);
    const parsed = try std.json.parseFromSlice(@import("wire.zig").Query(pump.View), A, query, .{});
    defer parsed.deinit();
    try expect(parsed.value.data != null);
    const revision = host.state.revision;
    var failing = std.testing.FailingAllocator.init(A, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, host.handle(
        \\{"api_version":1,"type":"terminal_input","now_ms":0,"wall_time_ms":0,"intent_id":"rollback","terminal_id":"session:%2F/one","vt_modes":{"application_cursor":false,"bracketed_paste":false},"input":{"kind":"text","text":"x","ctrl":false,"alt":false,"shift":false}}
    , failing.allocator()));
    try expect(host.state.revision == revision and host.state.terminal.rows[0].actions.len == 0);
}

test "settled terminal receipts roll off with every other settled receipt while pending input stays" {
    var host = try h.Host.init(A, config);
    defer host.deinit();
    var tx = try h.Transaction.init(&host);
    defer tx.deinit();
    try ready(&tx);
    try attach(&tx);
    const modes = .{ .application_cursor = false, .bracketed_paste = false };
    // The unanswered write keeps this receipt pending, so it must survive eviction.
    try event(&tx, "terminal_input", .{ .intent_id = "key-pending", .terminal_id = "k12-fixture", .vt_modes = modes, .input = .{ .kind = "text", .text = "x", .ctrl = false, .alt = false, .shift = false } });
    for (0..h.RECENT_RECEIPTS + 10) |i| {
        const id = try std.fmt.allocPrint(tx.allocator(), "key-{d}", .{i});
        try event(&tx, "terminal_input", .{ .intent_id = id, .terminal_id = "k12-fixture", .vt_modes = modes, .input = .{ .kind = "text", .text = "", .ctrl = false, .alt = false, .shift = false } });
    }
    const state = struct {
        fn of(receipts: anytype, id: []const u8) ?[]const u8 {
            for (receipts) |r| if (h.eq(r.operation.intent_id, id)) return r.operation.state;
            return null;
        }
    };
    // One rolling window covers every settled kind: the attach receipt goes first.
    try expect(tx.state.receipts.len == 1 + h.RECENT_RECEIPTS);
    try expect(state.of(tx.state.receipts, "attach") == null);
    try same(state.of(tx.state.receipts, "key-pending").?, "pending");
    try expect(state.of(tx.state.receipts, "key-9") == null and state.of(tx.state.receipts, "key-10") != null);
    // A retained ID still deduplicates instead of writing again.
    try event(&tx, "terminal_input", .{ .intent_id = "key-pending", .terminal_id = "k12-fixture", .vt_modes = modes, .input = .{ .kind = "text", .text = "x", .ctrl = false, .alt = false, .shift = false } });
    try expect(tx.state.receipts.len == 1 + h.RECENT_RECEIPTS and tx.state.terminal.rows[0].actions.len == 1);
    // A table full of in-flight receipts pushes back instead of evicting or failing the call.
    const pending = tx.state.receipts[0];
    try same(pending.operation.state, "pending");
    const full = try tx.allocator().alloc(@TypeOf(pending), h.MAX_INFLIGHT_RECEIPTS);
    @memset(full, pending);
    tx.state.receipts = full;
    try tx.apply(try h.parse(tx.allocator(),
        \\{"api_version":1,"type":"terminal_input","now_ms":0,"wall_time_ms":0,"intent_id":"key-full","terminal_id":"k12-fixture","vt_modes":{"application_cursor":false,"bracketed_paste":false},"input":{"kind":"text","text":"y","ctrl":false,"alt":false,"shift":false}}
    ));
    try expect(tx.state.receipts.len == h.MAX_INFLIGHT_RECEIPTS + 1 and tx.state.terminal.rows[0].actions.len == 1);
    const rejected = tx.state.receipts[h.MAX_INFLIGHT_RECEIPTS].operation;
    try same(rejected.state, "failed");
    try same(rejected.@"error".?.code, "backpressure");
    try expect(rejected.@"error".?.retryable);
}
