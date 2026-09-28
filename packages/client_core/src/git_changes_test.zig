//! Git review fixture harness; no real repositories or network.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const chat = @import("chat.zig");
const manage = @import("manage.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"manage","label":"Manage","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;
const snapshot =
    \\{"store_revision":5,"snapshot":{"workspaces":[
    \\ {"workspace_id":"ws-1","label":"One","path":"/home/u/src/one","provider":"claude","archived":false,"terminal_layout_json":"{\"keep\":true}","threads":[{"local_thread_id":"thread","title":"Fixture","provider":"codex"}]},
    \\ {"workspace_id":"ws-closed","label":"Old","path":"/srv/old","archived":true,"threads":[]}
    \\]}}
;
const all_scopes: []const []const u8 = &.{ "chat:read", "chat:write", "runtime:read", "repository:read", "repository:write" };

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: h.Host,
    serial: u64 = 1,
    now: i64 = 1,

    fn init(scopes: []const []const u8, capabilities: []const []const u8) !Fixture {
        var host = try h.Host.init(std.testing.allocator, config);
        errdefer host.deinit();
        var tx = try h.Transaction.init(&host);
        defer tx.deinit();
        tx.state.lifecycle = .foreground;
        tx.state.network_available = true;
        tx.state.auth.profile_loaded = false;
        tx.state.auth.credential = .{ .runtime_id = "0123456789abcdef0123456789abcdef", .device_id = "fixture", .device_credential = "fixture", .scopes = scopes };
        try rpc.attachBearer(&tx, "fixture-token", "0123456789abcdef0123456789abcdef", "fixture-pin");
        tx.state.rpc.instance_id = "00112233445566778899aabbccddeeff";
        tx.state.rpc.phase = .ready;
        tx.state.rpc.runtime_capabilities = capabilities;
        tx.state.sync.snapshot = try h.parse(tx.allocator(), snapshot);
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
        return h.parseLimit(f.a(), try f.host.handle(try h.encode(f.a(), v), f.a()), h.MAX_HTTP_INPUT);
    }
    /// Returns the intent ID it used.
    fn intent(f: *Fixture, tag: []const u8, payload: anytype) ![]const u8 {
        var v = try f.value(payload);
        if (v != .object) v = .{ .object = .empty };
        const id = try std.fmt.allocPrint(f.a(), "intent-{d}", .{f.serial});
        f.serial += 1;
        try v.object.put(f.a(), "intent_id", .{ .string = id });
        _ = try f.event(tag, v);
        return id;
    }
    fn pending(f: *Fixture, method: []const u8) usize {
        var n: usize = 0;
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, method)) {
            n += 1;
        };
        return n;
    }
    /// Management calls first: a success also queues sync's own snapshot.
    fn find(f: *Fixture, method: []const u8) !rpc.Call {
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, method) and call.intent_id != null and h.eq(call.intent_id.?, "@git")) return call;
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, method)) return call;
        return error.MissingRequest;
    }
    fn params(f: *Fixture, method: []const u8) !V {
        const call = try f.find(method);
        const bytes = try @import("auth.zig").decode64(f.a(), call.body_base64);
        return p.get(try h.parse(f.a(), bytes), "params");
    }
    fn respond(f: *Fixture, call: rpc.Call, body: []const u8) !void {
        _ = try f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(f.a(), body), .@"error" = @as(?u8, null) });
    }
    fn reply(f: *Fixture, method: []const u8, result: anytype) !void {
        const call = try f.find(method);
        try f.respond(call, try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .result = result }));
    }
    fn replyJson(f: *Fixture, method: []const u8, result: []const u8) !void {
        const call = try f.find(method);
        try f.respond(call, try std.fmt.allocPrint(f.a(), "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ call.id, result }));
    }
    fn reject(f: *Fixture, method: []const u8, code: []const u8, data: anytype) !void {
        const call = try f.find(method);
        try f.respond(call, try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .@"error" = .{ .code = code, .message = "rejected", .data = data } }));
    }
    fn view(f: *Fixture) !V {
        const q = try h.parse(f.a(), try f.host.query("git_review", f.a()));
        try expect(p.get(q, "error") == .null);
        return p.get(q, "data");
    }
    fn job(f: *Fixture, id: []const u8) !V {
        for (p.rows(p.get(try f.view(), "operations"))) |row| if (h.eq(p.s(row, "intent_id"), id)) return row;
        return error.MissingJob;
    }
    fn receipt(f: *Fixture, id: []const u8) !h.Operation {
        for (f.host.state.receipts) |r| if (h.eq(r.operation.intent_id, id)) return r.operation;
        return error.MissingReceipt;
    }
    fn expectFailed(f: *Fixture, id: []const u8, code: []const u8) !void {
        const j = try f.job(id);
        try eql("failed", p.s(j, "state"));
        try eql(code, p.s(p.get(j, "error"), "code"));
        const r = try f.receipt(id);
        try eql("failed", r.state);
        try eql(code, r.@"error".?.code);
    }
};

const g = @import("git_changes.zig");
const review = g.m.ReviewResult{ .review_id = "review-1", .workspace_id = "ws-1", .local_thread_id = "thread", .turn_running = true, .default_action = "commit", .repos = &.{.{ .root = "/repo", .name = "repo", .branch = "main", .head = "abc", .files = &.{.{ .path = "a.zig", .status = "modified", .ownership = "mine", .additions = 2, .deletions = 1, .binary = false, .hunk_selectable = true, .preview_truncated = false, .hunks = &.{.{ .index = 0, .header = "@@ -1 +1 @@", .text = "@@ -1 +1 @@\n-a\n+b" }} }} }} };
const selection = [_]g.m.RepoSelection{.{ .root = "/repo", .files = &.{.{ .path = "a.zig" }} }};
fn loaded(f: *Fixture) !void {
    _ = try f.intent("git_review_open", .{ .workspace_id = "ws-1", .thread_id = "thread" });
    try f.reply("git.changes.review", review);
}
test "git review scopes default selection validation and longer generation deadline" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    try loaded(&f);
    const view = try f.view();
    try eql("loaded", p.s(view, "state"));
    try expect(p.yes(p.get(view, "can_commit")));
    try expect(!p.yes(p.get(view, "can_configure")));
    _ = try f.intent("git_message_generate", .{ .review_id = "review-1", .selections = selection });
    try expect((try f.find("git.changes.commit_message")).timeout_ms == 120_000);
    try f.reply("git.changes.commit_message", .{ .message = "Fixture subject", .provider = "codex", .model = "fixture" });
    try eql("ready", p.s(try f.view(), "message_state"));
    _ = try f.intent("git_commit", .{ .review_id = "review-1", .message = "Fixture subject", .selections = selection, .push = true });
    const call = try f.find("git.changes.commit");
    try expect(call.mutation);
    try expect(call.timeout_ms == 120_000);
    try f.reply("git.changes.commit", .{ .workspace_id = "ws-1", .local_thread_id = "thread", .files = 1, .repos = .{.{ .root = "/repo", .commit = "abc", .short_commit = "abc", .subject = "Fixture subject", .files = 1, .push = "rejected" }} });
    try expect(f.pending("git.changes.commit") == 0);
    try expect(f.pending("git.changes.review") == 1);
    _ = try f.intent("git_pull_push", .{ .workspace_id = "ws-1", .root = "/repo" });
    try expect((try f.find("git.changes.pull_push")).mutation);
}
test "git writes and config are gated without emitting a mutation" {
    var f = try Fixture.init(&.{"repository:read"}, &.{});
    defer f.deinit();
    try loaded(&f);
    try expect(!p.yes(p.get(try f.view(), "can_commit")));
    const id = try f.intent("git_commit", .{ .review_id = "review-1", .message = "Fixture", .selections = selection, .push = false });
    try eql("scope_denied", (try f.receipt(id)).@"error".?.code);
    try expect(f.pending("git.changes.commit") == 0);
    const config_id = try f.intent("git_config_set", .{ .commit_default_action = "commit_and_push" });
    try eql("scope_denied", (try f.receipt(config_id)).@"error".?.code);
    try expect(f.pending("config.commit.set") == 0);
}
test "git stale reviews refresh without replaying commit" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    try loaded(&f);
    const id = try f.intent("git_commit", .{ .review_id = "review-1", .message = "Fixture", .selections = selection, .push = false });
    try f.reject("git.changes.commit", "changed_since_review", null);
    try eql("failed", (try f.receipt(id)).state);
    try expect(f.pending("git.changes.review") == 1);
    try expect(f.pending("git.changes.commit") == 0);
    try eql("stale", p.s(try f.view(), "state"));
}
test "git interrupted commit reuses the exact request and receipt" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    try loaded(&f);
    const id = try f.intent("git_commit", .{ .review_id = "review-1", .message = "Fixture", .selections = selection, .push = false });
    const call = try f.find("git.changes.commit");
    _ = try f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = @as(?u16, null), .headers = .{}, .body_base64 = @as(?[]const u8, null), .@"error" = .{ .kind = "network", .code = "reset" } });
    try eql("uncertain", (try f.receipt(id)).state);
    try expect(f.pending("git.changes.commit") == 0);
    try expect(f.pending("git.changes.review") == 0);
    try retryTick(&f);
    const replay = try f.params("git.changes.commit");
    try eql("review-1", p.s(replay, "review_id"));
    try eql("Fixture", p.s(replay, "message"));
    try eql("a.zig", p.s(p.rows(p.get(p.rows(p.get(replay, "selections"))[0], "files"))[0], "path"));
    try f.reply("git.changes.commit", .{ .workspace_id = "ws-1", .local_thread_id = "thread", .files = 1, .repos = .{} });
    try eql("succeeded", (try f.receipt(id)).state);
}
test "git hunk selections cannot escape frozen review" {
    try expect(g.validSelections(review, &selection));
    try expect(!g.validSelections(review, &.{.{ .root = "/other", .files = &.{.{ .path = "a.zig" }} }}));
    try expect(!g.validSelections(review, &.{.{ .root = "/repo", .files = &.{.{ .path = "a.zig", .hunks = &.{1} }} }}));
    var limited = review;
    var repo = review.repos[0];
    var file = repo.files[0];
    file.preview_truncated = true;
    repo.files = &.{file};
    limited.repos = &.{repo};
    try expect(!g.validSelections(limited, &.{.{ .root = "/repo", .files = &.{.{ .path = "a.zig", .hunks = &.{0} }} }}));
}

test "git malformed outcomes recover only the original idempotent operation" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    const open_id = try f.intent("git_review_open", .{ .workspace_id = "ws-1", .thread_id = "thread" });
    try f.replyJson("git.changes.review", "{}");
    try eql("failed", (try f.receipt(open_id)).state);
    try loaded(&f);
    const generate = try f.intent("git_message_generate", .{ .review_id = "review-1" });
    try f.replyJson("git.changes.commit_message", "{}");
    try eql("failed", (try f.receipt(generate)).state);
    const commit = try f.intent("git_commit", .{ .review_id = "review-1", .message = "Fixture", .selections = selection });
    try f.replyJson("git.changes.commit", "{}");
    try eql("uncertain", (try f.receipt(commit)).state);
    try expect(f.pending("git.changes.commit") == 0);
    try expect(f.pending("git.changes.review") == 0);
    try retryTick(&f);
    try expect(f.pending("git.changes.commit") == 1);
}

test "git mutation rejects 401 without auth replay" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    try loaded(&f);
    const id = try f.intent("git_commit", .{ .review_id = "review-1", .message = "Fixture", .selections = selection });
    const call = try f.find("git.changes.commit");
    try expect(!call.retry_auth);
    _ = try f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = 401, .headers = .{}, .body_base64 = "", .@"error" = @as(?u8, null) });
    try eql("failed", (try f.receipt(id)).state);
    try expect(f.pending("git.changes.commit") == 0);
}

test "git summary signals coalesce and cached changes remain during refresh" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    _ = try f.intent("git_summary_refresh", .{ .workspace_id = "ws-1" });
    try expect(f.pending("git.changes.summary") == 1);
    _ = try f.intent("git_summary_refresh", .{ .workspace_id = "ws-1" });
    try expect(f.pending("git.changes.summary") == 1);
    const response = .{ .workspace_id = "ws-1", .revision = 1, .threads = .{.{ .local_thread_id = "thread", .files = 2, .additions = 4, .deletions = 1, .attention = 1 }} };
    try f.reply("git.changes.summary", response);
    try expect(f.pending("git.changes.summary") == 1);
    const q = try h.parse(f.a(), try f.host.query("git_summary:ws-1", f.a()));
    try expect(p.yes(p.get(p.get(q, "data"), "loading")));
    try expect(p.rows(p.get(p.get(q, "data"), "threads")).len == 1);
    try f.reply("git.changes.summary", response);
    try expect(f.pending("git.changes.summary") == 0);
    // Neither a tick nor an unrelated input can create a polling request.
    _ = try f.event("foreground", .{});
    try expect(f.pending("git.changes.summary") == 1);
    try f.reply("git.changes.summary", response);
    _ = try f.intent("retry_connection", .{});
    try expect(f.pending("git.changes.summary") == 0);
}

test "git remote runtime review is unsupported and signout clears projections" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    var tx = try h.Transaction.init(&f.host);
    defer tx.deinit();
    tx.state.sync.catalog = &.{try h.parse(tx.allocator(), "{\"workspace_id\":\"ws-1\",\"local_thread_id\":\"thread\",\"profile_id\":\"remote\"}")};
    const output = try tx.commit(&f.host, f.a());
    _ = output;
    const id = try f.intent("git_review_open", .{ .workspace_id = "ws-1", .thread_id = "thread" });
    try eql("unsupported", (try f.receipt(id)).@"error".?.code);
    try expect(f.pending("git.changes.review") == 0);
    _ = try f.intent("git_summary_refresh", .{ .workspace_id = "ws-1" });
    var clear = try h.Transaction.init(&f.host);
    defer clear.deinit();
    clear.state.auth.credential = null;
    try g.observe(&clear, .null);
    const changed = try g.scopes(f.a(), &f.host.state, &clear.state);
    var found = false;
    for (changed) |scope| if (h.eq(scope, "git_summary:ws-1")) {
        found = true;
    };
    try expect(found);
    try expect(clear.state.git.watches.len == 0);
}

test "git selection receipt identity includes paths and hunks" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    try loaded(&f);
    const id = try f.intent("git_commit", .{ .review_id = "review-1", .message = "Fixture", .selections = selection });
    _ = try f.event("git_commit", .{ .intent_id = id, .review_id = "review-1", .message = "Fixture", .selections = selection });
    try expect(f.pending("git.changes.commit") == 1);
    try std.testing.expectError(error.InvalidArgument, f.event("git_commit", .{ .intent_id = id, .review_id = "review-1", .message = "Fixture", .selections = .{.{ .root = "/repo", .files = .{.{ .path = "a.zig", .hunks = .{0} }} }} }));
}

fn retryTick(f: *Fixture) !void {
    f.now += 2_001;
    for (f.host.state.pending) |pending| if (pending.kind == .timer and h.eq(pending.purpose, "git_retry")) {
        _ = try f.event("timer_fired", .{ .timer_id = pending.id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{pending.generation}) });
        return;
    };
    return error.MissingTimer;
}
test "Chat preset commits on a new branch without repository write" {
    var f = try Fixture.init(&.{ "chat:write", "repository:read" }, &.{});
    defer f.deinit();
    try loaded(&f);
    try expect(p.yes(p.get(try f.view(), "can_commit")));
    _ = try f.intent("git_commit", .{ .review_id = "review-1", .message = "Fixture", .selections = selection, .new_branch = true, .branch_name = "feature/fixture" });
    const request = try f.params("git.changes.commit");
    try expect(p.yes(p.get(request, "new_branch")));
    try eql("feature/fixture", p.s(request, "branch_name"));
}
test "git status and push use retained request identity with finite retry window" {
    var f = try Fixture.init(&.{ "chat:write", "repository:read" }, &.{});
    defer f.deinit();
    _ = try f.intent("git_status_refresh", .{ .workspace_id = "ws-1", .thread_id = "thread" });
    try f.reply("git.changes.status", .{ .workspace_id = "ws-1", .local_thread_id = "thread", .repos = .{.{ .root = "/repo", .name = "repo", .branch = "feature/test", .has_remote = true, .ahead = 2 }} });
    const id = try f.intent("git_push", .{ .workspace_id = "ws-1", .root = "/repo" });
    const key = try f.a().dupe(u8, p.s(try f.params("git.changes.push"), "request_id"));
    try expect(key.len > 0);
    try f.reject("git.changes.push", "in_progress", null);
    try retryTick(&f);
    try eql(key, p.s(try f.params("git.changes.push"), "request_id"));
    try f.reply("git.changes.push", .{ .root = "/repo", .push = "pushed" });
    try eql("succeeded", (try f.receipt(id)).state);
    try expect(f.pending("git.changes.status") == 1);
}
test "git idempotent recovery is bounded and does not refresh the frozen review" {
    var f = try Fixture.init(all_scopes, &.{});
    defer f.deinit();
    try loaded(&f);
    const id = try f.intent("git_commit", .{ .review_id = "review-1", .message = "Fixture", .selections = selection });
    for (0..3) |_| {
        try f.reject("git.changes.commit", "in_progress", null);
        try retryTick(&f);
        try expect(f.pending("git.changes.review") == 0);
    }
    try f.reject("git.changes.commit", "in_progress", null);
    try expect(f.pending("git.changes.commit") == 0);
    try expect(p.yes(p.get(try f.view(), "can_retry")));
    f.now = 3_600_002;
    _ = try f.intent("git_retry", .{});
    try expect(f.pending("git.changes.commit") == 0);
    try eql("uncertain", (try f.receipt(id)).state);
    try expect(!p.yes(p.get(try f.view(), "can_retry")));
}
