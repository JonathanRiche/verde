//! Chat boundary harness: recorded private-daemon traffic plus adversarial schedules.
const std = @import("std");
const h = @import("host.zig");
const chat = @import("chat.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const m = @import("chat_models.zig");
const wire = @import("wire.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"chat","label":"Chat","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;
const ws = "chat-fixture-ws";
const thread = "chat-fixture-thread";
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
        tx.state.auth.profile_loaded = false;
        tx.state.auth.credential = .{ .runtime_id = "0123456789abcdef0123456789abcdef", .device_id = "fixture", .device_credential = "fixture", .scopes = &.{ "chat:read", "chat:write", "runtime:read", "repository:read", "terminal:write" } };
        try rpc.attachBearer(&tx, "fixture-token", "0123456789abcdef0123456789abcdef", "fixture-pin");
        tx.state.rpc.instance_id = "00112233445566778899aabbccddeeff";
        tx.state.rpc.phase = .ready;
        const record = try h.parse(tx.allocator(), @embedFile("fixtures/chat/thread.json"));
        var meta = p.get(record, "thread");
        try meta.object.put(tx.allocator(), "workspace_id", .{ .string = ws });
        tx.state.sync.catalog = try tx.allocator().dupe(V, &.{meta});
        tx.state.sync.has_catalog = true;
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
        return h.parseLimit(f.a(), (f.host.handle(try h.encode(f.a(), v), f.a()) catch |e| {
            std.debug.print("fixture event {s}: {s}\n", .{ tag, @errorName(e) });
            return e;
        }), h.MAX_HTTP_INPUT);
    }
    fn intent(f: *Fixture, tag: []const u8, payload: anytype) !V {
        var v = try f.value(payload);
        if (v != .object) v = .{ .object = .empty };
        try v.object.put(f.a(), "workspace_id", .{ .string = ws });
        try v.object.put(f.a(), "thread_id", .{ .string = thread });
        try v.object.put(f.a(), "intent_id", .{ .string = try std.fmt.allocPrint(f.a(), "intent-{d}", .{f.serial}) });
        f.serial += 1;
        return f.event(tag, v);
    }
    fn find(f: *Fixture, method: []const u8) !rpc.Call {
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, method)) return call;
        return error.MissingRequest;
    }
    fn params(f: *Fixture, method: []const u8) !V {
        const call = try f.find(method);
        const bytes = try @import("auth.zig").decode64Limit(f.a(), call.body_base64, h.MAX_HTTP_INPUT);
        const request = try h.parse(f.a(), bytes);
        try expect(p.get(request, "target") == .object);
        return p.get(request, "params");
    }
    fn response(f: *Fixture, method: []const u8, result: V, failure: ?struct { code: []const u8, message: []const u8 }) !V {
        const call = try f.find(method);
        const body = if (failure) |e| try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .@"error" = e }) else try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .result = result });
        return f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(f.a(), body), .@"error" = @as(?u8, null) });
    }
    fn reply(f: *Fixture, method: []const u8, result: anytype) !void {
        _ = try f.response(method, try f.value(result), null);
    }
    fn recorded(f: *Fixture, method: []const u8, bytes: []const u8) !void {
        _ = try f.response(method, try h.parse(f.a(), bytes), null);
    }
    fn storage(f: *Fixture, saved: ?[]const u8, fail: bool) !V {
        const t = f.host.state.chat.threads[0];
        for (f.host.state.pending) |pending| if (t.storage_id != null and h.eq(pending.id, t.storage_id.?)) {
            var v = try f.value(.{ .effect_id = pending.id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{pending.generation}), .key = pending.key, .@"error" = if (fail) try f.value(.{ .code = "io" }) else V.null });
            if (pending.kind == .store_get) try v.object.put(f.a(), "value_base64", if (saved) |s| .{ .string = try rpc.encodeBase64(f.a(), s) } else .null);
            return f.event(if (pending.kind == .store_get) "secure_store_value" else "secure_store_done", v);
        };
        return error.MissingStorage;
    }
    fn open(f: *Fixture) !void {
        _ = try f.intent("thread_open", .{});
        _ = try f.storage(null, false);
        try f.recorded("chat.message.list", @embedFile("fixtures/chat/page-0.json"));
        if (@import("chat_catalogs.zig").supportsModelDiscovery(f.host.state.chat.threads[0].metadata.provider)) try f.reply("provider.models.list", .{ .models = .{} });
    }
    fn draft(f: *Fixture, text: []const u8) !void {
        _ = try f.intent("draft_set", .{ .text = text, .attachments = .{} });
        _ = try f.storage(null, false);
    }
    fn tail(f: *Fixture, result: anytype) !void {
        try f.reply("chat.turn.tail", result);
    }
    fn tick(f: *Fixture, delay: i64) !void {
        f.now += delay;
        for (f.host.state.pending) |pending| if (pending.kind == .timer and h.eq(pending.purpose, "chat_retry")) {
            _ = try f.event("timer_fired", .{ .timer_id = pending.id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{pending.generation}) });
            return;
        };
        return error.MissingTimer;
    }
    fn seedTurn(f: *Fixture) !void {
        var tx = try h.Transaction.init(&f.host);
        defer tx.deinit();
        tx.state.chat.threads[0].turn = .{ .turn_id = "fixture-turn", .status = "running" };
        try chat.pump(&tx);
        _ = try tx.commit(&f.host, f.a());
    }
    fn query(f: *Fixture, prefix: []const u8) !V {
        return h.parse(f.a(), try f.host.query(try chat.selectorFor(f.a(), prefix, ws, thread), f.a()));
    }
};

test "chat recorded paging and tail match durable transcript and retain access-cap notice" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    try expect(f.host.state.chat.threads[0].rows.len == 40);
    const cursor = try f.a().dupe(u8, f.host.state.chat.threads[0].cursor.?);
    _ = try f.intent("thread_load_older", .{});
    try eql(cursor, p.s(try f.params("chat.message.list"), "cursor"));
    try f.recorded("chat.message.list", @embedFile("fixtures/chat/page-1.json"));
    try expect(f.host.state.chat.threads[0].rows.len == 45);
    try f.seedTurn();
    const tails = try h.parse(f.a(), @embedFile("fixtures/chat/tails.json"));
    for (tails.array.items, 0..) |tail_, i| {
        if (i > 0) try f.tick(160);
        _ = try f.response("chat.turn.tail", tail_, null);
    }
    const t = &f.host.state.chat.threads[0];
    try expect(t.after_seq == 2 and t.overlay.len == 2);
    try eql("stub-ok", t.overlay[1].body);
    const streamed_id = try f.a().dupe(u8, t.overlay[1].id);
    try f.recorded("chat.message.list", @embedFile("fixtures/chat/committed.json"));
    try expect(f.host.state.chat.threads[0].overlay.len == 0);
    var found = false;
    var notice = false;
    for (f.host.state.chat.threads[0].rows) |r| {
        if (h.eq(r.id, streamed_id)) {
            try eql("stub-ok", r.body);
            found = true;
        }
        if (h.eq(r.id, "access-cap:fixture")) notice = true;
    }
    try expect(found and notice);
    const json = try h.encode(f.a(), try f.query("thread"));
    _ = try std.json.parseFromSliceLeaky(wire.Query(m.ThreadView), f.a(), json, .{});
    const composer = try f.query("composer");
    _ = try std.json.parseFromValueLeaky(wire.Query(m.ComposerView), f.a(), composer, .{});
    for (f.host.state.rpc.calls) |call| try expect(!h.eq(call.method, "workspaces") and !h.eq(call.method, "panes") and !h.eq(call.method, "chat.status"));
}

test "chat send freezes draft, stages ordered chunks, and preserves newer typing" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    _ = try f.intent("draft_set", .{ .text = "send this", .attachments = .{.{ .local_id = "image", .name = "a.png", .mime = "image/png", .byte_size = "6", .bytes_base64 = "YWJjZGVm" }} });
    _ = try f.storage(null, false);
    const revision = p.s(p.get(p.get(try f.query("composer"), "data"), "draft"), "revision");
    _ = try f.intent("send", .{ .draft_revision = revision });
    try expect(f.host.state.chat.threads[0].overlay.len == 1);
    try f.reply("daemon.client.register", .{ .client_id = "fixture-client" });
    const upsert = try f.params("chat.thread.upsert");
    try expect(p.rows(p.get(p.get(upsert, "thread"), "messages")).len == 0);
    try f.reply("chat.thread.upsert", .{ .store_revision = 100 });
    try f.reply("chat.attachment.create", .{ .attachment_id = "abc", .max_chunk_bytes = 4 });
    try eql("YWJjZA==", p.s(try f.params("chat.attachment.append"), "data"));
    try f.reply("chat.attachment.append", .{ .received_bytes = 4 });
    try expect(p.uint(p.get(try f.params("chat.attachment.append"), "offset")).? == 4);
    try f.reply("chat.attachment.append", .{ .received_bytes = 6 });
    try f.reply("chat.attachment.commit", .{ .attachment_id = "abc" });
    const start = try f.params("chat.turn.start");
    try eql("send this", p.s(start, "prompt"));
    try eql("abc", p.rows(p.get(start, "attachments"))[0].string);
    try expect(p.get(start, "attachment_ids") == .null);
    try expect(p.get(start, "image_paths") == .null);
    try f.draft("new typing");
    try f.reply("chat.turn.start", .{ .turn_id = p.s(start, "turn_id") });
    try eql("new typing", f.host.state.chat.threads[0].saved.text);
    _ = try f.find("chat.turn.tail");
}

test "chat approvals reconcile from tail and reject stale or duplicate decisions" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    try f.seedTurn();
    try f.tail(.{ .status = "running", .events = .{}, .pending_approval = .{ .call_id = "call", .title = "Approve", .body = "Run fixture" } });
    _ = try f.intent("approval_decide", .{ .turn_id = "fixture-turn", .call_id = "stale", .decision = "approve" });
    try std.testing.expectError(error.MissingRequest, f.find("chat.turn.approve"));
    _ = try f.intent("approval_decide", .{ .turn_id = "fixture-turn", .call_id = "call", .decision = "approve" });
    try eql("pending", f.host.state.chat.threads[0].approval.?.resolution);
    try f.reply("chat.turn.approve", .{ .approved = true });
    try f.tail(.{ .status = "running", .events = .{}, .pending_approval = @as(?u8, null) });
    try expect(f.host.state.chat.threads[0].approval == null);
}

test "chat follow-up requires durable receipt and uncertain steer is never automatically queued" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    try f.seedTurn();
    try f.draft("next");
    _ = try f.intent("followup_submit", .{ .draft_revision = "1", .kind = "steer" });
    try std.testing.expectError(error.MissingRequest, f.find("chat.turn.steer"));
    // unsent receipt, cleared draft, then sending receipt
    _ = try f.storage(null, false);
    while (f.host.state.chat.threads[0].storage_id != null) _ = try f.storage(null, false);
    const call = try f.find("chat.turn.steer");
    _ = try f.event("http_response", .{ .effect_id = call.effect_id, .generation = "0", .status = @as(?u16, null), .headers = .{}, .body_base64 = @as(?[]const u8, null), .@"error" = .{ .kind = "timeout", .code = "timeout" } });
    const followup = try std.json.parseFromSliceLeaky(m.Followup, f.a(), try h.encode(f.a(), f.host.state.chat.threads[0].saved.followup.?), .{});
    try eql("uncertain", followup.delivery);
    _ = try f.intent("followup_pull_back", .{ .followup_id = followup.id });
    try expect(f.host.state.chat.threads[0].saved.followup != null);
    while (f.host.state.chat.threads[0].storage_id != null) _ = try f.storage(null, false);
    _ = try f.intent("followup_retry", .{ .followup_id = followup.id });
    try std.testing.expectError(error.MissingRequest, f.find("chat.turn.steer"));
    _ = try f.find("chat.turn.tail");
}

test "chat shell confirmation binds route and query selectors preserve slash and percent IDs" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    _ = try f.intent("shell_prepare", .{ .command = "echo fixture" });
    try std.testing.expectError(error.MissingRequest, f.find("chat.shell.run"));
    const confirmation = try std.json.parseFromSliceLeaky(m.ShellConfirmation, f.a(), try h.encode(f.a(), f.host.state.chat.threads[0].confirmation.?), .{});
    _ = try f.intent("shell_confirm", .{ .confirmation_id = confirmation.id, .accept = true });
    try expect(p.yes(p.get(try f.params("chat.shell.run"), "confirmed")));
    _ = try f.intent("shell_confirm", .{ .confirmation_id = confirmation.id, .accept = true });
    var count: usize = 0;
    for (f.host.state.rpc.calls) |call| if (h.eq(call.method, "chat.shell.run")) {
        count += 1;
    };
    try expect(count == 1);
    const selector = try chat.selectorFor(f.a(), "thread", "w/s%", "[id]/%");
    try expect(std.mem.indexOf(u8, selector, "%25") != null);
}

test "chat tail retries after transport failure and only applied sequence advances cursor" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    try f.seedTurn();
    try f.tail(.{ .status = "running", .events = .{.{ .seq = 1, .kind = "assistant_delta", .payload_json = "{\"text\":\"one\"}" }} });
    try f.tick(160);
    const call = try f.find("chat.turn.tail");
    _ = try f.event("http_response", .{ .effect_id = call.effect_id, .generation = "0", .status = @as(?u16, null), .headers = .{}, .body_base64 = @as(?[]const u8, null), .@"error" = .{ .kind = "timeout", .code = "timeout" } });
    try f.tick(1000);
    try expect(p.uint(p.get(try f.params("chat.turn.tail"), "after_seq")).? == 1);
    try f.tail(.{ .status = "running", .events = .{ .{ .seq = 1, .kind = "assistant_delta", .payload_json = "{\"text\":\"one\"}" }, .{ .seq = 2, .kind = "assistant_delta", .payload_json = "{\"text\":\"two\"}" } } });
    try expect(f.host.state.chat.threads[0].after_seq == 2);
    try eql("onetwo", f.host.state.chat.threads[0].overlay[0].body);
    const before = f.host.state.revision;
    _ = try f.query("thread");
    try expect(f.host.state.revision == before);
}

test "chat scopes deny sends locally and draft writes remain ordered" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    _ = try f.intent("draft_set", .{ .text = "first", .attachments = .{} });
    const first = try f.a().dupe(u8, f.host.state.chat.threads[0].storage_id.?);
    _ = try f.intent("draft_set", .{ .text = "second", .attachments = .{} });
    try eql(first, f.host.state.chat.threads[0].storage_id.?);
    _ = try f.storage(null, false);
    try expect(f.host.state.chat.threads[0].storage_id != null);
    _ = try f.storage(null, false);
    var tx = try h.Transaction.init(&f.host);
    defer tx.deinit();
    tx.state.auth.credential.?.scopes = &.{"chat:read"};
    _ = try tx.commit(&f.host, f.a());
    _ = try f.intent("send", .{ .draft_revision = "2" });
    try std.testing.expectError(error.MissingRequest, f.find("daemon.client.register"));
    try eql("second", f.host.state.chat.threads[0].saved.text);
    const composer = p.get(try f.query("composer"), "data");
    try expect(!p.yes(p.get(composer, "can_send")));
}

test "phone-sized image survives draft persistence restore and chunk upload" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    const image = try f.a().alloc(u8, 160 * 1024);
    @memset(image, 42);
    // Auth payloads retain their separate 64 KiB limit.
    try std.testing.expectError(error.ResourceLimit, @import("auth.zig").decode64(f.a(), try rpc.encodeBase64(f.a(), image)));
    _ = try f.intent("draft_set", .{ .text = "fixture image", .attachments = .{.{ .local_id = "large-image", .name = "fixture.jpg", .mime = "image/jpeg", .byte_size = "163840", .bytes_base64 = try rpc.encodeBase64(f.a(), image) }} });
    _ = try f.storage(null, false);
    const saved = try h.encode(f.a(), f.host.state.chat.threads[0].saved);
    var restored = try Fixture.init();
    defer restored.deinit();
    _ = try restored.intent("thread_open", .{});
    _ = try restored.storage(saved, false);
    const t = restored.host.state.chat.threads[0];
    try eql(f.host.state.chat.threads[0].saved.inputs[0].bytes_base64, t.saved.inputs[0].bytes_base64);
    _ = try restored.intent("send", .{ .draft_revision = try std.fmt.allocPrint(restored.a(), "{d}", .{t.saved.revision}) });
    try restored.reply("daemon.client.register", .{ .client_id = "fixture-client" });
    try restored.reply("chat.thread.upsert", .{ .store_revision = 100 });
    try restored.reply("chat.attachment.create", .{ .attachment_id = "large", .max_chunk_bytes = 48 * 1024 });
    var received: usize = 0;
    while (received < image.len) {
        const params = try restored.params("chat.attachment.append");
        try expect(p.uint(p.get(params, "offset")).? == received);
        const chunk = try @import("auth.zig").decode64(restored.a(), p.s(params, "data"));
        try expect(std.mem.eql(u8, image[received .. received + chunk.len], chunk));
        received += chunk.len;
        try restored.reply("chat.attachment.append", .{ .received_bytes = received });
    }
    try restored.reply("chat.attachment.commit", .{ .attachment_id = "large" });
    const start = try restored.params("chat.turn.start");
    try expect(p.rows(p.get(start, "attachments")).len == 1);
    try eql("large", p.rows(p.get(start, "attachments"))[0].string);
}

test "photos too large for the draft record stay in memory and upload" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    const image = try f.a().alloc(u8, 700 * 1024);
    @memset(image, 7);
    const out = try f.intent("draft_set", .{ .text = "big photo", .attachments = .{.{ .local_id = "big", .name = "big.jpg", .mime = "image/jpeg", .byte_size = "716800", .bytes_base64 = try rpc.encodeBase64(f.a(), image) }} });
    var record: ?[]const u8 = null;
    for (p.rows(p.get(out, "effects"))) |effect| if (h.eq(p.s(effect, "type"), "secure_store_put")) {
        record = try @import("auth.zig").decode64Limit(f.a(), p.s(effect, "value_base64"), h.MAX_INPUT);
    };
    try expect(record.?.len <= h.MAX_INPUT / 2);
    try expect(std.mem.indexOf(u8, record.?, "big photo") != null);
    try expect(std.mem.indexOf(u8, record.?, "\"big.jpg\"") == null);
    _ = try f.storage(null, false);
    const t = f.host.state.chat.threads[0];
    try expect(t.saved.inputs.len == 1);
    // A second photo is added by reference to the first, so each event carries one image.
    _ = try f.intent("draft_set", .{ .text = "big photo", .attachments = .{
        .{ .local_id = "big", .name = "big.jpg", .mime = "image/jpeg", .byte_size = "716800", .bytes_base64 = "" },
        .{ .local_id = "big-2", .name = "big.jpg", .mime = "image/jpeg", .byte_size = "716800", .bytes_base64 = try rpc.encodeBase64(f.a(), image) },
    } });
    _ = try f.storage(null, false);
    const both = f.host.state.chat.threads[0];
    try expect(both.saved.inputs.len == 2);
    try eql(both.saved.inputs[0].bytes_base64, both.saved.inputs[1].bytes_base64);
    _ = try f.intent("send", .{ .draft_revision = try std.fmt.allocPrint(f.a(), "{d}", .{both.saved.revision}) });
    try f.reply("daemon.client.register", .{ .client_id = "fixture-client" });
    try f.reply("chat.thread.upsert", .{ .store_revision = 100 });
    try f.reply("chat.attachment.create", .{ .attachment_id = "first", .max_chunk_bytes = 256 * 1024 });
    var received: usize = 0;
    while (received < image.len) {
        const params = try f.params("chat.attachment.append");
        received += (try @import("auth.zig").decode64Limit(f.a(), p.s(params, "data"), h.MAX_INPUT)).len;
        try f.reply("chat.attachment.append", .{ .received_bytes = received });
    }
    try f.reply("chat.attachment.commit", .{ .attachment_id = "first" });
    // The second photo starts uploading after the first commits.
    _ = try f.find("chat.attachment.create");
}

test "chat discovers externally started turn after a completed turn without replaying stale snapshot" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    try f.seedTurn();
    try f.tail(.{ .status = "completed", .events = .{.{ .seq = 1, .kind = "assistant_delta", .payload_json = "{\"text\":\"previous answer\"}" }} });
    try f.recorded("chat.message.list", @embedFile("fixtures/chat/page-0.json"));
    {
        var tx = try h.Transaction.init(&f.host);
        defer tx.deinit();
        tx.state.sync.snapshot = try h.parse(tx.allocator(), try h.encode(f.a(), .{ .turns = .{.{ .workspace_id = ws, .local_thread_id = thread, .turn_id = "fixture-turn", .status = "running" }} }));
        try chat.pump(&tx);
        _ = try tx.commit(&f.host, f.a());
    }
    try std.testing.expectError(error.MissingRequest, f.find("chat.turn.tail"));
    {
        var tx = try h.Transaction.init(&f.host);
        defer tx.deinit();
        tx.state.sync.snapshot = try h.parse(tx.allocator(), try h.encode(f.a(), .{ .turns = .{.{ .workspace_id = ws, .local_thread_id = thread, .turn_id = "external-next", .status = "running", .started_at_ms = 1790363200000 }} }));
        try chat.pump(&tx);
        _ = try tx.commit(&f.host, f.a());
    }
    try eql("external-next", p.s(try f.params("chat.turn.tail"), "turn_id"));
    try expect(p.uint(p.get(try f.params("chat.turn.tail"), "after_seq")).? == 0);
    try f.tail(.{ .status = "running", .events = .{.{ .seq = 1, .kind = "tool_call", .payload_json = "{\"call_id\":\"next-tool\",\"title\":\"Fixture tool\",\"kind\":\"execute\",\"status\":\"in_progress\",\"input\":\"fixture\"}" }} });
    const t = f.host.state.chat.threads[0];
    try eql("running", t.turn.?.status);
    try expect(t.overlay.len > 0);
}
