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

test "chat model discovery failure leaves the loaded chat readable" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.intent("thread_open", .{});
    _ = try f.storage(null, false);
    try f.recorded("chat.message.list", @embedFile("fixtures/chat/page-0.json"));
    // Reopen as a provider with model discovery (the fixture thread is codex).
    f.host.state.chat.threads[0].metadata.provider = "claude";
    f.host.state.chat.threads[0].saved.selection.provider = "claude";
    _ = try f.intent("thread_open", .{});
    _ = try f.response("provider.models.list", .null, .{ .code = "provider_unavailable", .message = "ProviderBridgeNotFound" });
    const t = &f.host.state.chat.threads[0];
    try expect(t.@"error" == null);
    try expect(t.rows.len > 0);
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
    try f.tail(.{ .status = "running", .events = .{.{ .seq = 1, .kind = "approval_requested", .payload_json = "{\"call_id\":\"call\"}" }}, .pending_approval = .{ .call_id = "call", .title = "Approve", .body = "Run fixture" } });
    // The lifecycle marker advances the cursor but never becomes a transcript row.
    try expect(f.host.state.chat.threads[0].after_seq == 1);
    for (f.host.state.chat.threads[0].overlay) |row| try expect(std.mem.indexOf(u8, row.body, "approval_requested") == null and !h.eq(row.author, "approval_requested"));
    _ = try f.intent("approval_decide", .{ .turn_id = "fixture-turn", .call_id = "stale", .decision = "approve" });
    try std.testing.expectError(error.MissingRequest, f.find("chat.turn.approve"));
    _ = try f.intent("approval_decide", .{ .turn_id = "fixture-turn", .call_id = "call", .decision = "approve" });
    try eql("pending", f.host.state.chat.threads[0].approval.?.resolution);
    try f.reply("chat.turn.approve", .{ .approved = true });
    const resolved = try f.response("chat.turn.tail", try f.value(.{ .status = "running", .events = .{}, .pending_approval = @as(?u8, null) }), null);
    try expect(f.host.state.chat.threads[0].approval == null);
    // Home's "needs you" overlay reads this chat's approval, so Home is re-announced.
    var announced = false;
    for (p.rows(p.get(resolved, "effects"))) |effect| if (h.eq(p.s(effect, "type"), "state_changed")) {
        for (p.rows(p.get(effect, "scopes"))) |scope| announced = announced or (scope == .string and h.eq(scope.string, "home"));
    };
    try expect(announced);
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

test "tool rows parse title, one-line summary and body sections without changing the body" {
    const tb = @import("tool_body.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edit = try tb.parse(a, "edit", "Edit", "Tool:\nEdit `src/x.ts`\n\nInput:\n{\"file_path\":\"src/x.ts\",\"old_string\":\"a\",\"new_string\":\"b\"}\n\nOutput:\n--- a/src/x.ts\n+++ b/src/x.ts\n@@ -1 +1 @@\n-a\n+b");
    try eql("Edit", edit.title.?);
    try eql("src/x.ts", edit.summary.?);
    try eql("{\"file_path\":\"src/x.ts\",\"old_string\":\"a\",\"new_string\":\"b\"}", edit.input.?);
    try eql("--- a/src/x.ts\n+++ b/src/x.ts\n@@ -1 +1 @@\n-a\n+b", edit.output.?);
    try expect(edit.@"error" == null);
    const bare = try tb.parse(a, "execute", "Ran command", "Input:\nbun test\n\nOutput:\n3 pass\n\n0 fail");
    try eql("Ran command", bare.title.?);
    try eql("bun test", bare.summary.?);
    try eql("3 pass\n\n0 fail", bare.output.?);
    // A command that is its own title reads as the author plus the command.
    const titled = try tb.parse(a, "execute", "Command failed", "Tool:\n`git status --short`\n\nInput:\n{\"command\":[\"bash\",\"-lc\",\"git status --short\"]}\n\nError:\nexit 128\n\nTranscript:\n{\"type\":\"text\"}");
    try eql("Command failed", titled.title.?);
    try eql("git status --short", titled.summary.?);
    try eql("exit 128", titled.@"error".?);
    try expect(titled.output == null);
    const mcp = try tb.parse(a, "mcp", "MCP tool", "Tool:\nverde.report_chat_blocked\n\nInput:\n{\n  \"turn_id\": \"t-1\",\n  \"reason\": \"Need a decision\"\n}");
    try eql("MCP tool", mcp.title.?);
    try eql("verde.report_chat_blocked", mcp.summary.?);
    const search = try tb.parse(a, "search", "Search", "Tool:\nFind files\n\nInput:\n{\"pattern\":\"**/*.zig\\nignored\"}");
    try eql("Find files", search.title.?);
    try eql("**/*.zig", search.summary.?);
    const fetch = try tb.parse(a, "fetch", "Fetch", "Input:\n{\"url\":\"https://example.com/a\",\"prompt\":\"x\"}");
    try eql("Fetch", fetch.title.?);
    try eql("https://example.com/a", fetch.summary.?);
    const read = try tb.parse(a, "read", "Read", "Tool:\nRead File\n\nInput:\n{\"limit\":20}\n\nLocations:\nsrc/main.zig:1");
    try eql("Read File", read.title.?);
    try eql("src/main.zig:1", read.summary.?);
    // JSON noise never becomes the summary; unknown objects fall back to telling keys or nothing.
    const other = try tb.parse(a, "other", "Tool", "Input:\n{\"description\":\"Explore the repo\",\"n\":1}");
    try eql("Explore the repo", other.summary.?);
    const opaque_ = try tb.parse(a, "other", "Tool", "Input:\n{\"n\":1}");
    try expect(opaque_.summary == null);
    const broken = try tb.parse(a, "other", "Tool", "Input:\n{\"n\":");
    try expect(broken.summary == null);
    // Unstructured legacy bodies keep only the author as title.
    const legacy = try tb.parse(a, "execute", "Ran command", "git status --short");
    try eql("Ran command", legacy.title.?);
    try expect(legacy.summary == null and legacy.input == null and legacy.output == null);
    const long = try tb.parse(a, "execute", "Ran command", "Input:\n" ++ "é" ** 200);
    try expect(long.summary.?.len <= tb.MAX_SUMMARY and std.unicode.utf8ValidateSlice(long.summary.?));
}

test "streamed and stored tool rows expose parsed tool fields in the thread view" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    try f.seedTurn();
    try f.tail(.{ .status = "running", .events = .{.{ .seq = 1, .kind = "tool_call", .payload_json = "{\"call_id\":\"edit-1\",\"title\":\"Edit `src/x.ts`\",\"kind\":\"edit\",\"status\":\"completed\",\"input\":\"{\\\"file_path\\\":\\\"src/x.ts\\\"}\",\"output\":\"+b\"}" }} });
    const view = try std.json.parseFromValueLeaky(wire.Query(m.ThreadView), f.a(), try f.query("thread"), .{ .ignore_unknown_fields = true });
    var found = false;
    for (view.data.?.rows) |row| if (row.tool) |tool| if (h.eq(tool.id, "edit-1")) {
        try expect(std.mem.indexOf(u8, row.body, "Input:\n") != null);
        try eql("Edit", tool.title.?);
        try eql("src/x.ts", tool.summary.?);
        try eql("{\"file_path\":\"src/x.ts\"}", tool.input.?);
        try eql("+b", tool.output.?);
        found = true;
    };
    try expect(found);
}

test "slash choices list each command once and keep a runnable copy" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const slash = try h.parse(a,
        \\{"commands":[{"id":"code-review","name":"/code-review","availability":"needs_thread"},{"id":"code-review","name":"/code-review"},{"id":"plugin:code-review","name":"code-review"},{"id":"code-review","name":"/code-review"},{"id":"init","name":"/init"},{"id":"other","name":""},{"id":"another","name":""}]}
    );
    const out = try @import("chat_catalogs.zig").catalogs(a, .{ .provider = "claude" }, .null, slash);
    try expect(out.slash.len == 4);
    try eql("code-review", out.slash[0].id);
    try expect(out.slash[0].enabled and out.slash[0].reason == null);
    try eql("init", out.slash[1].id);
    try eql("other", out.slash[2].id);
    try eql("another", out.slash[3].id);
}

test "transcript images are named by their file name and keep the host path as reference" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.intent("thread_open", .{});
    _ = try f.storage(null, false);
    try f.recorded("chat.message.list",
        \\{"messages":[{"sort_index":1,"message_id":"img-1","role":"user","author":"You","body":"see","images":[{"path":"/home/u/.local/share/verde/attachments/shot 1.png","mime":"image/png","byte_size":3},{"path":"C:\\Users\\u\\pic.jpg","mime":"image/jpeg","byte_size":4}],"image":null,"tool_call_id":null,"tool_call_kind":null,"tool_call_status":null,"created_at_ms":null,"updated_at_ms":null}],"next_cursor":null,"store_revision":2}
    );
    var row: ?m.Row = null;
    for (f.host.state.chat.threads[0].rows) |r| if (h.eq(r.id, "img-1")) {
        row = r;
    };
    const images = row.?.attachments;
    try expect(images.len == 2);
    try eql("shot 1.png", images[0].name);
    try eql("/home/u/.local/share/verde/attachments/shot 1.png", images[0].reference.?);
    try eql("pic.jpg", images[1].name);
}

test "composer catalogs name the model behind a provider's default choice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cat = @import("chat_catalogs.zig");
    // Built-in Claude list before discovery answers.
    var out = try cat.catalogs(a, .{ .provider = "claude" }, .null, .null);
    try eql("default", out.models[0].id);
    try eql("Opus 5.5", out.default_model_label.?);
    try expect(out.default_effort_label == null);
    // The host's list names the default; a selected concrete model keeps the label for the menu.
    const listed = try h.parse(a,
        \\{"models":[{"model_id":"default","model_name":"Default (Opus 6)"},{"model_id":"sonnet","model_name":"Sonnet 5.5"}]}
    );
    out = try cat.catalogs(a, .{ .provider = "claude", .model = "sonnet" }, listed, .null);
    try eql("Opus 6", out.default_model_label.?);
    // A default that defers to the CLI's own config, or an unnamed one, stays unknown.
    out = try cat.catalogs(a, .{ .provider = "pi" }, try h.parse(a, "{\"models\":[{\"model_id\":\"default\",\"model_name\":\"Default (pi config)\"}]}"), .null);
    try expect(out.default_model_label == null);
    out = try cat.catalogs(a, .{ .provider = "claude" }, try h.parse(a, "{\"models\":[{\"model_id\":\"default\",\"model_name\":\"Default (recommended)\"}]}"), .null);
    try expect(out.default_model_label == null);
    out = try cat.catalogs(a, .{ .provider = "grok" }, .null, .null);
    try expect(out.default_model_label == null);
    // No default choice at all (Codex lists concrete models; a listed catalog without one).
    out = try cat.catalogs(a, .{ .provider = "codex" }, .null, .null);
    try expect(out.default_model_label == null);
    out = try cat.catalogs(a, .{ .provider = "claude" }, try h.parse(a, "{\"models\":[{\"model_id\":\"sonnet\",\"model_name\":\"Sonnet 5.5\"}]}"), .null);
    try expect(out.default_model_label == null);
}

/// The `workspaces` selector's summary of the fixture thread.
fn listedThread(f: *Fixture, catalog_activity_s: ?i64, turns: anytype) !V {
    var tx = try h.Transaction.init(&f.host);
    defer tx.deinit();
    var meta = try h.parse(tx.allocator(), try h.encode(f.a(), tx.state.sync.catalog[0]));
    try meta.object.put(tx.allocator(), "last_activity_at", if (catalog_activity_s) |n| .{ .integer = n } else .null);
    tx.state.sync.catalog = try tx.allocator().dupe(V, &.{meta});
    tx.state.sync.snapshot = try h.parse(tx.allocator(), try h.encode(f.a(), .{ .snapshot = .{ .workspaces = .{.{ .workspace_id = ws, .label = "Fixture" }} }, .turns = turns }));
    f.a().free(try tx.commit(&f.host, f.a()));
    const out = try h.parse(f.a(), try f.host.query("workspaces", f.a()));
    for (p.rows(p.get(p.get(out, "data"), "items"))) |w| for (p.rows(p.get(w, "threads"))) |t| if (h.eq(p.s(t, "thread_id"), thread)) return t;
    return error.MissingThread;
}

test "thread activity follows turns this device observes until the host catches up" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    const none = .{};
    // No host activity and no observed turn yet.
    try expect(p.get(try listedThread(&f, null, none), "last_activity_at_ms") == .null);
    // Host value only (seconds).
    try expect(p.num(p.get(try listedThread(&f, 1790000000, none), "last_activity_at_ms")).? == 1790000000000);
    // A sync turn's start/finish counts even when the host never bumped the thread.
    try expect(p.num(p.get(try listedThread(&f, 1790000000, .{.{ .workspace_id = ws, .local_thread_id = thread, .turn_id = "older", .status = "completed", .started_at_ms = 1790000100000, .finished_at_ms = 1790000200000 }}), "last_activity_at_ms")).? == 1790000200000);
    // Tail progress seen on this device bumps it to the observed wall time.
    try f.seedTurn();
    f.now = 5000;
    try f.tail(.{ .status = "completed", .events = .{.{ .seq = 1, .kind = "assistant_delta", .payload_json = "{\"text\":\"done\"}" }} });
    const seen: i64 = 1790363191000 + 5000;
    try expect(f.host.state.chat.threads[0].activity_ms.? == seen);
    const listed = try listedThread(&f, 1790000000, none);
    try expect(p.num(p.get(listed, "last_activity_at_ms")).? == seen);
    try eql("Today", p.s(listed, "history_bucket"));
    const view = try f.query("thread");
    try expect(p.num(p.get(p.get(p.get(view, "data"), "thread"), "last_activity_at_ms")).? == seen);
    // Once the host's value is newer, it wins.
    try expect(p.num(p.get(try listedThread(&f, 1790363200, none), "last_activity_at_ms")).? == 1790363200000);
}

const runtime = "0123456789abcdef0123456789abcdef";
/// Lists the fixture workspace with `repositories` and points the open thread at `cwd`.
fn manifest(f: *Fixture, repositories: anytype, cwd: []const u8) !void {
    var tx = try h.Transaction.init(&f.host);
    defer tx.deinit();
    tx.state.rpc.runtime_id = runtime;
    tx.state.sync.snapshot = try h.parse(tx.allocator(), try h.encode(f.a(), .{ .snapshot = .{ .workspaces = .{.{ .workspace_id = ws, .label = "Fixture", .path = "/repo", .default_repository_id = "primary", .repositories = repositories }} } }));
    const threads = try tx.allocator().dupe(chat.Thread, tx.state.chat.threads);
    threads[0].cwd = cwd;
    tx.state.chat.threads = threads;
    f.a().free(try tx.commit(&f.host, f.a()));
}
fn routeOf(f: *Fixture, staged: bool) ?chat.ManifestRoute {
    return chat.manifestRoute(&f.host.state, &f.host.state.chat.threads[0], staged);
}

test "turns without repository metadata route through the workspace manifest so photos are staged" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    const repos = .{
        .{ .repository_id = "primary", .label = "Fixture", .bindings = .{ .{ .runtime_id = "ffffffffffffffffffffffffffffffff", .root_path = "/elsewhere" }, .{ .runtime_id = runtime, .root_path = "/repo/" } } },
        .{ .repository_id = "api", .label = "API", .bindings = .{.{ .runtime_id = runtime, .root_path = "/repo/services/api" }} },
    };
    // The deepest checkout holding the cwd wins; the root itself has no relative cwd.
    try manifest(&f, repos, "/repo/services/api/src");
    var r = routeOf(&f, false).?;
    try eql("api", r.repository_id);
    try eql("src", r.relative_cwd.?);
    try manifest(&f, repos, "/repo");
    r = routeOf(&f, false).?;
    try eql("primary", r.repository_id);
    try expect(r.relative_cwd == null);
    try manifest(&f, repos, "/repo/docs/");
    try eql("docs", routeOf(&f, false).?.relative_cwd.?);
    // Another runtime's checkout and folders outside every checkout keep the project path.
    try manifest(&f, repos, "/elsewhere/x");
    try expect(routeOf(&f, true) == null);
    // A legacy one-path workspace routes staged uploads through its `primary` path only.
    try manifest(&f, .{}, "/repo/app");
    try expect(routeOf(&f, false) == null);
    r = routeOf(&f, true).?;
    try eql("primary", r.repository_id);
    try eql("app", r.relative_cwd.?);

    // End to end: the photo turn carries the repository route, never `project_path`.
    try manifest(&f, repos, "/repo/services/api");
    _ = try f.intent("draft_set", .{ .text = "look", .attachments = .{.{ .local_id = "image", .name = "a.png", .mime = "image/png", .byte_size = "3", .bytes_base64 = "YWJj" }} });
    _ = try f.storage(null, false);
    const revision = p.s(p.get(p.get(try f.query("composer"), "data"), "draft"), "revision");
    _ = try f.intent("send", .{ .draft_revision = revision });
    try f.reply("daemon.client.register", .{ .client_id = "fixture-client" });
    try f.reply("chat.thread.upsert", .{ .store_revision = 100 });
    try f.reply("chat.attachment.create", .{ .attachment_id = "abc", .max_chunk_bytes = 16 });
    try f.reply("chat.attachment.append", .{ .received_bytes = 3 });
    try f.reply("chat.attachment.commit", .{ .attachment_id = "abc" });
    const start = try f.params("chat.turn.start");
    try eql("api", p.s(start, "repository_id"));
    try expect(p.get(start, "relative_cwd") == .null);
    try expect(p.get(start, "project_path") == .null);
    try eql("abc", p.rows(p.get(start, "attachments"))[0].string);
    // Acceptance commits that route on the host thread; the next upsert must carry it.
    try f.reply("chat.turn.start", .{ .turn_id = p.s(start, "turn_id") });
    const meta = f.host.state.chat.threads[0].metadata;
    try eql("api", meta.repository_id.?);
    try expect(meta.repository_cwd == null);
    try eql("local", meta.profile_id.?);
    try eql(runtime, meta.runtime_id.?);
}

test "background commands become one task row each and running tasks are listed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bg = @import("background_rows.zig");
    const rows = [_]m.Row{
        .{ .id = "u1", .role = "user", .body = "start the servers" },
        .{ .id = "b1", .role = "system", .author = "Background command", .body = "bun run dev\n--port 3000\n\nVerde task ID: task-1\nOutput log: /tmp/verde-task-1.log\nPID file: /tmp/verde-task-1.pid\nStop command: kill 1", .created_at_ms = 10 },
        .{ .id = "b2", .role = "system", .author = "Backgrounded command", .body = "Input:\nnpm run watch\n\nProvider: codex\nCodex item ID: item-2\nProcess ID: 42\nProvider thread ID: pt-1\nCWD: /repo", .created_at_ms = 11 },
        .{ .id = "b3", .role = "system", .author = "Background command", .body = "tail -f log\n\nCodex item ID: item-3\nProcess ID: 43\nProvider thread ID: pt-1", .created_at_ms = 12 },
        .{ .id = "b4", .role = "system", .author = "Background command", .body = "sleep 100\n\nProcess ID: 44\nProvider thread ID: pt-1", .created_at_ms = 13 },
        .{ .id = "s1", .role = "system", .author = bg.CODEX_SNAPSHOT_AUTHOR, .body = "Provider thread ID: pt-1\nCodex item ID: item-3", .created_at_ms = 20 },
        .{ .id = "e1", .role = "system", .author = "Background task completed", .body = "bun run dev\n--port 3000\n\nVerde task ID: task-1\nOutput log: /tmp/verde-task-1.log", .created_at_ms = 30 },
        .{ .id = "b1-again", .role = "system", .author = "Background command", .body = "bun run dev\n\nVerde task ID: task-1", .created_at_ms = 31 },
        .{ .id = "e4", .role = "system", .author = "Background task stopped", .body = "sleep 100\n\nProcess ID: 44\nProvider thread ID: pt-1", .created_at_ms = 40 },
        .{ .id = "r1", .role = "system", .author = "Ran command", .body = "ls" },
    };
    const out = try bg.project(a, &rows);
    // user, four tasks (merged, snapshot hidden), the plain command row.
    try expect(out.rows.len == 6);
    const dev = out.rows[1];
    try eql("background_task", dev.kind);
    try eql("b1", dev.id);
    try eql("bun run dev\n--port 3000", dev.body);
    try expect(std.mem.indexOf(u8, dev.body, "Verde task ID") == null);
    try eql("bun run dev", dev.background.?.label);
    try eql("completed", dev.background.?.status);
    try eql("task-1", dev.background.?.task_id.?);
    try expect(dev.background.?.started_at_ms.? == 10 and dev.background.?.finished_at_ms.? == 30);
    // Codex released item-2 (absent from the snapshot); item-3 is still listed.
    try eql("npm run watch", out.rows[2].background.?.label);
    try eql("completed", out.rows[2].background.?.status);
    try eql("item-2", out.rows[2].background.?.task_id.?);
    try eql("running", out.rows[3].background.?.status);
    try eql("stopped", out.rows[4].background.?.status);
    try eql("44", out.rows[4].background.?.task_id.?);
    try eql("Ran command", out.rows[5].author);
    try expect(out.running.len == 1);
    try eql("b3", out.running[0].row_id);
    try eql("tail -f log", out.running[0].label);
    try eql("item-3", out.running[0].task_id.?);
}

test "the thread view carries background task rows and the running list" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.open();
    try f.seedTurn();
    try f.tail(.{ .status = "running", .events = .{.{ .seq = 1, .kind = "message", .payload_json = "{\"title\":\"Background command\",\"body\":\"bun run dev\\n\\nVerde task ID: t-9\\nPID file: /tmp/x.pid\"}" }} });
    const view = try std.json.parseFromValueLeaky(wire.Query(m.ThreadView), f.a(), try f.query("thread"), .{ .ignore_unknown_fields = true });
    var found = false;
    for (view.data.?.rows) |row| if (row.background) |b| {
        try eql("bun run dev", row.body);
        try eql("running", b.status);
        try eql("t-9", b.task_id.?);
        found = true;
    };
    try expect(found);
    try expect(view.data.?.background_tasks.len == 1);
    try eql("bun run dev", view.data.?.background_tasks[0].label);
}
