//! K-17: push decrypt (A-12 vectors, tamper, wrong key, version, dedupe),
//! attention transitions, push registration and sign-out wipe coverage.
const std = @import("std");
const h = @import("host.zig");
const push = @import("push.zig");
const attention = @import("attention.zig");
const chat = @import("chat.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const seal = @import("headless").push_seal;
const root = @import("root.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const b64url = std.base64.url_safe_no_pad;

// A-12 fixed vector (packages/headless/src/push_seal.zig): RFC 7748 keys.
const vector_secret = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
const vector_public = hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
const vector_plaintext = "{\"kind\":\"approval\",\"title\":\"Verde\",\"snippet\":\"Run the test suite?\"}";
const vector_envelope = "AYUg8AmJMKdUdIt93LQ-91oNvzoNJjga9OukqY6qm05qd-M-eyZ6GWfMt9YSx4uHlwgMPXIeysAPOHi25l4kjlcz6tr1W6wqWvY-MQG_75AKRw5qYyaAZ3xpLtSB4pcNUOA4dcXSA_j7kF6nIah4BhB5MPk";
const runtime_id = "0123456789abcdef0123456789abcdef";

fn hex(comptime text: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

/// The secure-store value the core writes for `vc/1/<host>/push`.
fn record(a: std.mem.Allocator, pair: seal.KeyPair, runtime: []const u8) ![]const u8 {
    var public_text: [43]u8 = undefined;
    var secret_text: [43]u8 = undefined;
    const bytes = try h.encode(a, push.Record{ .runtime_id = runtime, .public_key = b64url.Encoder.encode(&public_text, &pair.public_key), .secret_key = b64url.Encoder.encode(&secret_text, &pair.secret_key) });
    return rpc.encodeBase64(a, bytes);
}
fn request(a: std.mem.Allocator, envelope: []const u8, keys: []const push.OpenKey, recent: []const []const u8) ![]const u8 {
    return h.encode(a, .{ .api_version = 1, .envelope = envelope, .keys = keys, .recent = recent });
}
fn daemonPayload(a: std.mem.Allocator, kind: []const u8, runtime: []const u8, snippet: []const u8) ![]const u8 {
    // Same field set and JSON encoding as A-14 `push.encodePayload`.
    return h.encode(a, .{ .runtime_id = runtime, .workspace_id = "ws 1", .thread_id = "thread/1", .turn_id = "turn-1", .kind = kind, .title = "Fix the build", .snippet = snippet });
}

test "push open agrees with the A-12 daemon vector through the stored record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pair = try seal.KeyPair.generateDeterministic(vector_secret);
    try expect(std.mem.eql(u8, &pair.public_key, &vector_public));
    const stored = try record(a, pair, runtime_id);
    // Cross-implementation decrypt: the record's secret opens the daemon vector.
    const bytes = try @import("auth.zig").decode64(a, stored);
    const parsed = push.parseRecord(a, bytes).?;
    var secret: [32]u8 = undefined;
    try b64url.Decoder.decode(&secret, parsed.secret_key);
    try eql(vector_plaintext, try seal.open(a, secret, vector_envelope));
    // The vector's plaintext predates A-14 (no runtime_id): opened, then rejected.
    const model = try push.open(a, try request(a, vector_envelope, &.{.{ .host_id = "home", .record_base64 = stored }}, &.{}));
    try expect(!model.opened and !model.update_required);
    try eql("invalid_payload", model.@"error".?);
    try eql(push.GENERIC_BODY, model.body);
}

test "push open returns a typed model for a daemon-sealed payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const device = try seal.KeyPair.generateDeterministic(hex("1111111111111111111111111111111111111111111111111111111111111111"));
    const other = try seal.KeyPair.generateDeterministic(hex("2222222222222222222222222222222222222222222222222222222222222222"));
    const envelope = try seal.seal(a, std.testing.io, device.public_key, try daemonPayload(a, "approval_pending", runtime_id, "Run `rm -rf build`?\nIn repo"));
    const keys = [_]push.OpenKey{ .{ .host_id = "other", .record_base64 = try record(a, other, runtime_id) }, .{ .host_id = "home", .record_base64 = try record(a, device, runtime_id) } };
    const model = try push.open(a, try request(a, envelope, &keys, &.{}));
    try expect(model.opened and model.@"error" == null and !model.duplicate);
    try eql("home", model.host_id.?);
    try eql("approval_pending", model.kind);
    try eql("needs_approval", model.attention.?);
    try eql("attention", model.channel);
    try eql("Fix the build", model.title);
    try eql("Needs approval: Run `rm -rf build`?\nIn repo", model.body);
    try eql("verde://open?host_id=home&workspace_id=ws%201&thread_id=thread%2F1", model.deep_link);
    try expect(model.actions.len == 3);
    try eql("approve", model.actions[1]);
    try eql("home:turn-1:approval_pending", model.dedupe_key.?);

    const done = try push.open(a, try request(a, try seal.seal(a, std.testing.io, device.public_key, try h.encode(a, .{ .runtime_id = runtime_id, .workspace_id = "ws", .thread_id = "t", .turn_id = "turn-2", .kind = "completed", .title = "" })), keys[1..], &.{}));
    try eql("Verde", done.title);
    try eql("Reply ready", done.body);
    try eql("completed", done.channel);
    try eql("reply", done.actions[1]);

    const test_push = try push.open(a, try request(a, try seal.seal(a, std.testing.io, device.public_key, try h.encode(a, .{ .runtime_id = runtime_id, .kind = "test", .title = "Verde push test" })), keys[1..], &.{}));
    try expect(test_push.opened and test_push.dedupe_key == null and test_push.actions.len == 1);
    try eql("verde://open?host_id=home", test_push.deep_link);
}

test "push open rejects tamper, wrong key, newer version and foreign runtime generically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const device = try seal.KeyPair.generateDeterministic(hex("3333333333333333333333333333333333333333333333333333333333333333"));
    const wrong = try seal.KeyPair.generateDeterministic(hex("4444444444444444444444444444444444444444444444444444444444444444"));
    const keys = [_]push.OpenKey{.{ .host_id = "home", .record_base64 = try record(a, device, runtime_id) }};
    const envelope = try seal.seal(a, std.testing.io, device.public_key, try daemonPayload(a, "failed", runtime_id, "boom"));

    const tampered = try a.dupe(u8, envelope);
    tampered[60] = if (tampered[60] == 'A') 'B' else 'A';
    const cases = [_]struct { envelope: []const u8, keys: []const push.OpenKey, code: []const u8 }{
        .{ .envelope = tampered, .keys = &keys, .code = "authentication_failed" },
        .{ .envelope = envelope, .keys = &.{.{ .host_id = "home", .record_base64 = try record(a, wrong, runtime_id) }}, .code = "authentication_failed" },
        .{ .envelope = envelope, .keys = &.{}, .code = "no_key" },
        .{ .envelope = envelope, .keys = &.{.{ .host_id = "home", .record_base64 = "bm90IGEgcmVjb3Jk" }}, .code = "no_key" },
        .{ .envelope = "not base64!", .keys = &keys, .code = "invalid_envelope" },
        .{ .envelope = "A" ** (seal.MAX_ENVELOPE_LEN + 1), .keys = &keys, .code = "envelope_too_large" },
    };
    for (cases) |case| {
        const model = try push.open(a, try request(a, case.envelope, case.keys, &.{}));
        try expect(!model.opened and !model.update_required and model.host_id == null and model.dedupe_key == null);
        try eql(case.code, model.@"error".?);
        try eql(push.GENERIC_TITLE, model.title);
        try eql(push.GENERIC_BODY, model.body);
        try eql("verde://open", model.deep_link);
    }

    // A future envelope version asks for an app update.
    var raw: [512]u8 = undefined;
    const raw_len = try b64url.Decoder.calcSizeForSlice(envelope);
    try b64url.Decoder.decode(raw[0..raw_len], envelope);
    raw[0] = 2;
    var future: [700]u8 = undefined;
    const newer = try push.open(a, try request(a, b64url.Encoder.encode(&future, raw[0..raw_len]), &keys, &.{}));
    try expect(!newer.opened and newer.update_required);
    try eql("unsupported_version", newer.@"error".?);
    try eql(push.GENERIC_BODY, newer.body);

    // A payload for another runtime is not trusted even though it decrypts.
    const foreign = try push.open(a, try request(a, try seal.seal(a, std.testing.io, device.public_key, try daemonPayload(a, "completed", "ffffffffffffffffffffffffffffffff", "")), &keys, &.{}));
    try eql("invalid_payload", foreign.@"error".?);
    const garbage = try push.open(a, try request(a, try seal.seal(a, std.testing.io, device.public_key, "[1,2]"), &keys, &.{}));
    try eql("invalid_payload", garbage.@"error".?);

    // Request-shape errors are statuses, not models.
    try std.testing.expectError(error.UnsupportedVersion, push.open(a, "{\"api_version\":2,\"envelope\":\"\",\"keys\":[]}"));
    try std.testing.expectError(error.InvalidArgument, push.open(a, "{\"api_version\":1,\"envelope\":7,\"keys\":[]}"));
    try std.testing.expectError(error.InvalidArgument, push.open(a, "nope"));
}

test "push open dedupes against recently shown keys and exports through the C ABI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const device = try seal.KeyPair.generateDeterministic(hex("5555555555555555555555555555555555555555555555555555555555555555"));
    const keys = [_]push.OpenKey{.{ .host_id = "home", .record_base64 = try record(a, device, runtime_id) }};
    const envelope = try seal.seal(a, std.testing.io, device.public_key, try daemonPayload(a, "input_needed", runtime_id, "Which branch?"));
    const first = try push.open(a, try request(a, envelope, &keys, &.{"home:turn-0:input_needed"}));
    try expect(!first.duplicate);
    try eql("blocked", first.attention.?);
    try eql("Needs input: Which branch?", first.body);
    const again = try request(a, envelope, &keys, &.{ "x", first.dedupe_key.? });
    try expect((try push.open(a, again)).duplicate);

    var out: root.Buf = .{};
    try expect(root.vcPushOpen(again.ptr, again.len, &out) == 0);
    defer root.vcBufFree(out);
    const decoded = try std.json.parseFromSlice(push.Notification, std.testing.allocator, out.ptr.?[0..out.len], .{});
    defer decoded.deinit();
    try expect(decoded.value.duplicate and decoded.value.opened);
    try eql("home:turn-1:input_needed", decoded.value.dedupe_key.?);
    var bad: root.Buf = .{};
    try expect(root.vcPushOpen(null, 1, &bad) == 1 and bad.ptr == null);
}

fn entry(turn: []const u8, status: attention.Status, kind: ?attention.Kind) attention.Entry {
    return .{ .workspace_id = "ws", .thread_id = "t", .turn_id = turn, .status = status, .attention = kind, .since_ms = 5 };
}
test "attention transitions follow notify.ts advanceAttention" {
    try expect(attention.notificationStatus("waiting_approval", false) == .waiting);
    try expect(attention.notificationStatus("running", true) == .waiting);
    try expect(attention.notificationStatus("failed", false) == .@"error");
    try expect(attention.notificationStatus("aborted", false) == .idle);
    try expect(attention.notificationStatus("accepted", false) == .working);
    try expect(attention.notificationStatus("completed", false) == .done);
    try expect(attention.notificationStatus("", false) == .done);

    // Seeding is silent.
    try expect(!attention.advance(null, entry("a", .done, null), false).raised);
    // working → done/waiting/error raises; focused suppresses and clears.
    var r = attention.advance(entry("a", .working, null), entry("a", .done, null), false);
    try expect(r.raised and r.entry.attention == .unread);
    r = attention.advance(entry("a", .working, null), entry("a", .waiting, null), false);
    try expect(r.raised and r.entry.attention == .needs_approval);
    r = attention.advance(entry("a", .waiting, .needs_approval), entry("a", .@"error", null), false);
    try expect(r.raised and r.entry.attention == .failed);
    r = attention.advance(entry("a", .waiting, .needs_approval), entry("a", .done, null), false);
    try expect(r.raised and r.entry.attention == .unread);
    r = attention.advance(entry("a", .working, null), entry("a", .done, null), true);
    try expect(!r.raised and r.entry.attention == null);
    r = attention.advance(entry("a", .done, .unread), entry("a", .done, null), true);
    try expect(r.entry.attention == null);
    // Unchanged status keeps attention; working/idle clears it.
    r = attention.advance(entry("a", .done, .unread), entry("a", .done, null), false);
    try expect(!r.raised and r.entry.attention == .unread and r.entry.since_ms == 5);
    try expect(attention.advance(entry("a", .done, .unread), entry("b", .working, null), false).entry.attention == null);
    try expect(attention.advance(entry("a", .done, .unread), entry("a", .idle, null), false).entry.attention == null);
    // Blocked (push-only) survives its own running turn, not a new one.
    try expect(attention.advance(entry("a", .working, .blocked), entry("a", .working, null), false).entry.attention == .blocked);
    try expect(attention.advance(entry("a", .working, .blocked), entry("b", .working, null), false).entry.attention == null);
    // A new turn already settled between polls still counts as observed work.
    r = attention.advance(entry("a", .done, null), entry("b", .done, null), false);
    try expect(r.raised and r.entry.attention == .unread);
    try expect(!attention.advance(entry("a", .done, null), entry("a", .done, null), false).raised);
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: h.Host,
    now: i64 = 1,
    serial: u64 = 1,
    /// Acknowledge attention record writes as the platform would.
    auto: bool = false,
    fn init(scopes: []const []const u8) !Fixture {
        var host = try h.Host.init(std.testing.allocator,
            \\{"api_version":1,"host_id":"home","label":"Home","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
        );
        errdefer host.deinit();
        var tx = try h.Transaction.init(&host);
        defer tx.deinit();
        tx.state.lifecycle = .foreground;
        tx.state.network_available = true;
        tx.state.auth.credential = .{ .runtime_id = runtime_id, .device_id = "device", .device_credential = "credential", .scopes = scopes };
        try rpc.attachBearer(&tx, "fixture-token", runtime_id, "fixture-pin");
        tx.state.rpc.instance_id = "00112233445566778899aabbccddeeff";
        tx.state.rpc.phase = .ready;
        std.testing.allocator.free(try tx.commit(&host, std.testing.allocator));
        return .{ .arena = .init(std.testing.allocator), .host = host };
    }
    fn deinit(f: *Fixture) void {
        f.host.deinit();
        f.arena.deinit();
    }
    fn a(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }
    fn event(f: *Fixture, tag: []const u8, payload: anytype) anyerror!V {
        var v = try h.parse(f.a(), try h.encode(f.a(), payload));
        if (v != .object) v = .{ .object = .empty };
        try v.object.put(f.a(), "type", .{ .string = tag });
        try v.object.put(f.a(), "api_version", .{ .integer = 1 });
        f.now += 1;
        try v.object.put(f.a(), "now_ms", .{ .integer = f.now });
        try v.object.put(f.a(), "wall_time_ms", .{ .integer = 1790000000000 + f.now });
        const batch = try h.parseLimit(f.a(), try f.host.handle(try h.encode(f.a(), v), f.a()), h.MAX_HTTP_INPUT);
        if (f.auto) if (find(batch, "secure_store_put", "/attention")) |put| {
            _ = try f.answer(put, null);
        };
        return batch;
    }
    fn intent(f: *Fixture, tag: []const u8, payload: anytype) !V {
        var v = try h.parse(f.a(), try h.encode(f.a(), payload));
        if (v != .object) v = .{ .object = .empty };
        try v.object.put(f.a(), "intent_id", .{ .string = try std.fmt.allocPrint(f.a(), "intent-{d}", .{f.serial}) });
        f.serial += 1;
        return f.event(tag, v);
    }
    /// Replace the sync snapshot: one workspace, two threads, given turns.
    fn snapshot(f: *Fixture, turn_json: []const u8) !void {
        var tx = try h.Transaction.init(&f.host);
        defer tx.deinit();
        const json = try std.fmt.allocPrint(tx.allocator(),
            \\{{"snapshot":{{"workspaces":[{{"workspace_id":"ws","label":"Repo","path":"/repo","threads":[{{"local_thread_id":"t1","title":"Fix build"}},{{"local_thread_id":"t2","title":"Docs"}}]}}]}},"sessions":[],"turns":{s},"incomplete_scopes":[]}}
        , .{turn_json});
        tx.state.sync.snapshot = try h.parse(tx.allocator(), json);
        f.a().free(try tx.commit(&f.host, f.a()));
    }
    fn tick(f: *Fixture) !V {
        return f.event("foreground", .{});
    }
    fn answer(f: *Fixture, effect: V, value: ?[]const u8) anyerror!V {
        if (h.eq(p.s(effect, "type"), "secure_store_get")) {
            return f.event("secure_store_value", .{ .effect_id = p.s(effect, "effect_id"), .generation = p.s(effect, "generation"), .key = p.s(effect, "key"), .value_base64 = if (value) |bytes| try rpc.encodeBase64(f.a(), bytes) else null, .@"error" = @as(?u8, null) });
        }
        return f.event("secure_store_done", .{ .effect_id = p.s(effect, "effect_id"), .generation = p.s(effect, "generation"), .key = p.s(effect, "key"), .@"error" = @as(?u8, null) });
    }
    fn query(f: *Fixture, selector: []const u8) !V {
        return p.get(try h.parse(f.a(), try f.host.query(selector, f.a())), "data");
    }
};
fn find(batch: V, tag: []const u8, key_suffix: []const u8) ?V {
    for (p.rows(p.get(batch, "effects"))) |effect| {
        if (h.eq(p.s(effect, "type"), tag) and std.mem.endsWith(u8, p.s(effect, "key"), key_suffix)) return effect;
    }
    return null;
}
fn count(batch: V, tag: []const u8) usize {
    var n: usize = 0;
    for (p.rows(p.get(batch, "effects"))) |effect| {
        if (h.eq(p.s(effect, "type"), tag)) n += 1;
    }
    return n;
}
fn running(turn: []const u8, thread: []const u8, status: []const u8) ![]const u8 {
    return std.fmt.allocPrint(std.testing.allocator, "{{\"turn_id\":\"{s}\",\"workspace_id\":\"ws\",\"local_thread_id\":\"{s}\",\"status\":\"{s}\",\"started_at_ms\":10}}", .{ turn, thread, status });
}
fn turns(f: *Fixture, items: []const []const u8) !void {
    var list: std.ArrayList(u8) = .empty;
    try list.append(f.a(), '[');
    for (items, 0..) |item, i| {
        if (i > 0) try list.append(f.a(), ',');
        try list.appendSlice(f.a(), item);
        std.testing.allocator.free(item);
    }
    try list.append(f.a(), ']');
    try f.snapshot(list.items);
}

test "host attention seeds silently, notifies on completion, clears on view and persists" {
    var f = try Fixture.init(&.{"chat:read"});
    defer f.deinit();
    f.auto = true;
    try turns(&f, &.{try running("old", "t1", "completed")});
    const load = find(try f.tick(), "secure_store_get", "/home/attention").?;
    const seeded = try f.answer(load, null);
    try expect(count(seeded, "notify") == 0);
    try expect(p.get(try f.query("attention"), "count").integer == 0);

    try turns(&f, &.{try running("turn-1", "t1", "running")});
    try expect(count(try f.tick(), "notify") == 0);
    try turns(&f, &.{try running("turn-1", "t1", "completed")});
    const batch = try f.tick();
    try expect(count(batch, "notify") == 1);
    const notice = find(batch, "notify", "").?;
    try eql("home:turn-1:completed", p.s(notice, "notification_id"));
    try eql("Reply ready in Repo", p.s(notice, "body"));
    try eql("Fix build", p.s(notice, "title"));
    try eql("t1", p.s(p.get(notice, "target"), "thread_id"));
    var scoped = false;
    for (p.rows(p.get(find(batch, "state_changed", "").?, "scopes"))) |scope| scoped = scoped or h.eq(scope.string, "attention");
    try expect(scoped);
    const saved = find(batch, "secure_store_put", "/home/attention").?;
    // Re-observing the same state neither re-notifies nor rewrites.
    try expect(count(try f.tick(), "notify") == 0);

    const view = try f.query("attention");
    try expect(p.get(view, "count").integer == 1);
    const item = p.rows(p.get(view, "items"))[0];
    try eql("unread", p.s(item, "kind"));
    try eql("Fix build", p.s(item, "title"));
    try eql("verde://open?host_id=home&workspace_id=ws&thread_id=t1", p.s(item, "deep_link"));
    const decoded = try std.json.parseFromValue(@import("wire.zig").Query(attention.View), std.testing.allocator, try h.parse(f.a(), try f.host.query("attention", f.a())), .{});
    defer decoded.deinit();
    const home = p.rows(p.get(try f.query("home"), "items"));
    try expect(home.len == 1);
    try eql("unread", p.s(home[0], "attention_kind"));
    try expect(p.yes(p.get(home[0], "attention")));
    const panes = p.rows(p.get(p.rows(p.get(try f.query("workspaces"), "items"))[0], "panes"));
    for (panes) |pane| if (h.eq(p.s(pane, "thread_id"), "t1")) try eql("unread", p.s(pane, "attention_kind"));

    // Persisted entries restore unread in a new process.
    const stored = try @import("auth.zig").decode64(f.a(), p.s(saved, "value_base64"));
    var g = try Fixture.init(&.{"chat:read"});
    defer g.deinit();
    try turns(&g, &.{try running("turn-1", "t1", "completed")});
    _ = try g.answer(find(try g.tick(), "secure_store_get", "/attention").?, stored);
    try expect(p.get(try g.query("attention"), "count").integer == 1);

    // Viewing the thread clears it.
    _ = try f.intent("thread_open", .{ .workspace_id = "ws", .thread_id = "t1" });
    try expect(p.get(try f.query("attention"), "count").integer == 0);
    try expect(p.rows(p.get(try f.query("home"), "items")).len == 0);
}

test "host attention suppresses the focused thread and follows approval, failure and push" {
    var f = try Fixture.init(&.{"chat:read"});
    defer f.deinit();
    f.auto = true;
    try turns(&f, &.{ try running("a", "t1", "running"), try running("b", "t2", "running") });
    _ = try f.answer(find(try f.tick(), "secure_store_get", "/attention").?, null);
    _ = try f.intent("focus", .{ .workspace_id = "ws", .thread_id = "t1", .terminal_id = null });
    try turns(&f, &.{ try running("a", "t1", "completed"), try running("b", "t2", "waiting_approval") });
    var batch = try f.tick();
    try expect(count(batch, "notify") == 1);
    try eql("home:b:approval_pending", p.s(find(batch, "notify", "").?, "notification_id"));
    try eql("Needs approval", p.s(find(batch, "notify", "").?, "body"));
    var view = try f.query("attention");
    try expect(p.get(view, "count").integer == 1);
    try eql("needs_approval", p.s(p.rows(p.get(view, "items"))[0], "kind"));

    // In the background the focused thread is not being viewed.
    _ = try f.event("background", .{});
    try turns(&f, &.{ try running("a2", "t1", "failed"), try running("b", "t2", "failed") });
    batch = try f.event("background", .{});
    try expect(count(batch, "notify") == 2);
    view = try f.query("attention");
    try expect(p.get(view, "count").integer == 2);
    for (p.rows(p.get(view, "items"))) |item| try eql("failed", p.s(item, "kind"));
    // Returning to the foreground on the focused thread clears only that one.
    _ = try f.event("foreground", .{});
    view = try f.query("attention");
    try expect(p.get(view, "count").integer == 1);
    try eql("t2", p.s(p.rows(p.get(view, "items"))[0], "thread_id"));
    _ = try f.intent("focus", .{ .workspace_id = null, .thread_id = null, .terminal_id = null });

    // Blocked is push-only; it survives its running turn and the in-app
    // notification is not repeated for a pushed event.
    try turns(&f, &.{ try running("a2", "t1", "failed"), try running("c", "t2", "running") });
    _ = try f.tick();
    _ = try f.event("push_received", .{ .workspace_id = "ws", .thread_id = "t2", .turn_id = "c", .kind = "input_needed" });
    try expect(count(try f.tick(), "notify") == 0);
    view = try f.query("attention");
    var blocked = false;
    for (p.rows(p.get(view, "items"))) |item| blocked = blocked or (h.eq(p.s(item, "thread_id"), "t2") and h.eq(p.s(item, "kind"), "blocked"));
    try expect(blocked);
    _ = try f.event("push_received", .{ .workspace_id = "ws", .thread_id = "t2", .turn_id = "c", .kind = "completed" });
    try turns(&f, &.{ try running("a2", "t1", "failed"), try running("c", "t2", "completed") });
    try expect(count(try f.tick(), "notify") == 0);
    try std.testing.expectError(error.InvalidArgument, f.event("push_received", .{ .workspace_id = "", .thread_id = "t2", .turn_id = "c", .kind = "completed" }));
}

test "push_register stores one key per host and registers the public key" {
    var f = try Fixture.init(&.{ "chat:read", "device:write" });
    defer f.deinit();
    const seed = [_]u8{9} ** 32;
    const seed64 = try @import("auth.zig").encode64(f.a(), &seed);
    var batch = try f.intent("push_register", .{ .platform = "android", .send_token = "relay-send-token", .key_seed_base64 = seed64 });
    const get = find(batch, "secure_store_get", "/home/push").?;
    batch = try f.answer(get, null);
    const put = find(batch, "secure_store_put", "/home/push").?;
    const stored = try @import("auth.zig").decode64(f.a(), p.s(put, "value_base64"));
    try expect(std.mem.indexOf(u8, stored, "relay-send-token") == null);
    const parsed = push.parseRecord(f.a(), stored).?;
    const expected = try seal.KeyPair.generateDeterministic(seed);
    var public_text: [43]u8 = undefined;
    try eql(b64url.Encoder.encode(&public_text, &expected.public_key), parsed.public_key);
    try eql(runtime_id, parsed.runtime_id);
    try expect(count(batch, "http_request") == 0);
    batch = try f.answer(put, null);
    const call = f.host.state.rpc.calls[f.host.state.rpc.calls.len - 1];
    try eql("device.push.register", call.method);
    const body = try h.parse(f.a(), try @import("auth.zig").decode64(f.a(), call.body_base64));
    try eql("android", p.s(p.get(body, "params"), "platform"));
    try eql("relay-send-token", p.s(p.get(body, "params"), "send_token"));
    try eql(parsed.public_key, p.s(p.get(body, "params"), "public_key"));
    try expect(f.host.state.push.send_token.len == 0 and f.host.state.push.seed_base64.len == 0);
    const reply = try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .result = .{ .accepted = true } });
    _ = try f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(f.a(), reply), .@"error" = @as(?u8, null) });
    try expect(operation(&f, "intent-1", "succeeded"));

    // The stored record opens what the daemon seals to the registered key.
    const envelope = try seal.seal(f.a(), std.testing.io, expected.public_key, try daemonPayload(f.a(), "completed", runtime_id, "All green"));
    const model = try push.open(f.a(), try request(f.a(), envelope, &.{.{ .host_id = "home", .record_base64 = p.s(put, "value_base64") }}, &.{}));
    try expect(model.opened);
    try eql("All green", model.body);

    // A token refresh reuses the stored key without rewriting it.
    batch = try f.intent("push_register", .{ .platform = "android", .send_token = "rotated", .key_seed_base64 = try @import("auth.zig").encode64(f.a(), &([_]u8{7} ** 32)) });
    batch = try f.answer(find(batch, "secure_store_get", "/home/push").?, try @import("auth.zig").decode64(f.a(), p.s(put, "value_base64")));
    try expect(find(batch, "secure_store_put", "/push") == null);
    const again = try h.parse(f.a(), try @import("auth.zig").decode64(f.a(), f.host.state.rpc.calls[f.host.state.rpc.calls.len - 1].body_base64));
    try eql(parsed.public_key, p.s(p.get(again, "params"), "public_key"));

    // Invalid shapes never reach a receipt; missing scope fails the operation.
    try std.testing.expectError(error.InvalidArgument, f.intent("push_register", .{ .platform = "web", .send_token = "t", .key_seed_base64 = seed64 }));
    try std.testing.expectError(error.InvalidArgument, f.intent("push_register", .{ .platform = "ios", .send_token = "has space", .key_seed_base64 = seed64 }));
    try std.testing.expectError(error.InvalidArgument, f.intent("push_register", .{ .platform = "ios", .send_token = "t", .key_seed_base64 = "AAAA" }));
    var g = try Fixture.init(&.{"chat:read"});
    defer g.deinit();
    _ = try g.intent("push_register", .{ .platform = "ios", .send_token = "t", .key_seed_base64 = seed64 });
    try expect(operation(&g, "intent-1", "failed"));
}
fn operation(f: *Fixture, id: []const u8, state: []const u8) bool {
    for (f.host.state.receipts) |r| if (h.eq(r.operation.intent_id, id)) return h.eq(r.operation.state, state);
    return false;
}

fn storeEffect(batch: V) ?V {
    for (p.rows(p.get(batch, "effects"))) |effect| {
        if (std.mem.startsWith(u8, p.s(effect, "type"), "secure_store_")) return effect;
    }
    return null;
}

test "sign out wipes chat drafts, push key, attention and the chat index" {
    var f = try Fixture.init(&.{"chat:read"});
    defer f.deinit();
    // One chat record indexed in a previous process, one live loaded thread.
    const indexed = "ab" ** 32;
    var tx = try h.Transaction.init(&f.host);
    var threads = try tx.allocator().alloc(chat.Thread, 1);
    threads[0] = .{ .workspace_id = "ws", .id = "t1", .metadata = .{ .local_thread_id = "t1", .title = "Fix build" }, .cwd = "/repo", .loaded = true };
    tx.state.chat.threads = threads;
    const live_key = try f.a().dupe(u8, try chat.recordKey(&tx, &threads[0]));
    f.a().free(try tx.commit(&f.host, f.a()));
    tx.deinit();
    // The index loads lazily and learns the live thread.
    var batch = try f.tick();
    const index_get = find(batch, "secure_store_get", "/home/chat_index").?;
    batch = try f.answer(index_get, try h.encode(f.a(), .{ .version = 1, .digests = &[_][]const u8{indexed} }));
    const index_put = find(batch, "secure_store_put", "/home/chat_index").?;
    const index_bytes = try @import("auth.zig").decode64(f.a(), p.s(index_put, "value_base64"));
    try expect(std.mem.indexOf(u8, index_bytes, indexed) != null and std.mem.indexOf(u8, index_bytes, live_key[live_key.len - 64 ..]) != null);
    _ = try f.answer(index_put, null);

    batch = try f.intent("forget_host", .{ .host_id = "home" });
    var deleted: std.ArrayList([]const u8) = .empty;
    var effect = storeEffect(batch).?;
    while (true) {
        try expect(h.eq(p.s(effect, "type"), "secure_store_delete"));
        try deleted.append(f.a(), p.s(effect, "key"));
        batch = try f.answer(effect, null);
        effect = storeEffect(batch) orelse break;
    }
    try eql("signed_out", f.host.state.auth_state);
    const want = [_][]const u8{ "vc/1/home/credential", "vc/1/home/profile", "vc/1/home/sync", "vc/1/home/attention", "vc/1/home/push", live_key, "vc/1/home/chat/" ++ indexed, "vc/1/home/chat_index" };
    try expect(deleted.items.len == want.len);
    for (want, deleted.items) |w, d| try eql(w, d);
    try expect(f.host.state.chat.threads.len == 0 and f.host.state.attention.entries.len == 0 and f.host.state.chat_index.digests.len == 0);
}

test "sign out reads an unloaded chat index and retries a failed chat delete" {
    var f = try Fixture.init(&.{"chat:read"});
    defer f.deinit();
    const indexed = "cd" ** 32;
    var effect = storeEffect(try f.intent("forget_host", .{ .host_id = "home" })).?;
    // credential, profile, sync, attention, push
    for (0..5) |_| {
        try eql("secure_store_delete", p.s(effect, "type"));
        effect = storeEffect(try f.answer(effect, null)).?;
    }
    // After push, the index is read because this process never loaded it.
    try eql("vc/1/home/chat_index", p.s(effect, "key"));
    try eql("secure_store_get", p.s(effect, "type"));
    const batch = try f.answer(effect, try h.encode(f.a(), .{ .version = 1, .digests = &[_][]const u8{ indexed, "not-a-digest" } }));
    const chat_delete = storeEffect(batch).?;
    try eql("secure_store_delete", p.s(chat_delete, "type"));
    try eql("vc/1/home/chat/" ++ indexed, p.s(chat_delete, "key"));
    _ = try f.event("secure_store_done", .{ .effect_id = p.s(chat_delete, "effect_id"), .generation = p.s(chat_delete, "generation"), .key = p.s(chat_delete, "key"), .@"error" = .{ .code = "locked" } });
    try eql("sign_out_delete_failed", f.host.state.host_error.?.code);
    const retried = storeEffect(try f.intent("retry_connection", .{})).?;
    try eql(p.s(chat_delete, "key"), p.s(retried, "key"));
    const last = storeEffect(try f.answer(retried, null)).?;
    try eql("vc/1/home/chat_index", p.s(last, "key"));
    try eql("secure_store_delete", p.s(last, "type"));
    try expect(storeEffect(try f.answer(last, null)) == null);
    try eql("signed_out", f.host.state.auth_state);
}
