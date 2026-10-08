//! Workspace explorer fixture harness; no real repositories or network.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const V = std.json.Value;
const config =
    \\{"api_version":1,"host_id":"explore","label":"Explore","https_url":"https://host.example","wss_url":"wss://host.example/ws","client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;
const snapshot =
    \\{"store_revision":5,"snapshot":{"workspaces":[
    \\ {"workspace_id":"ws-1","label":"One","path":"/home/u/src/one","provider":"claude","archived":false,"threads":[{"local_thread_id":"thread","title":"Fixture","provider":"codex"}]}
    \\]}}
;
const read_scopes: []const []const u8 = &.{ "chat:read", "chat:write", "repository:read" };

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: h.Host,
    serial: u64 = 1,
    now: i64 = 1,

    fn init(scopes: []const []const u8) !Fixture {
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
    fn event(f: *Fixture, tag: []const u8, payload: anytype) !V {
        var v = try h.parseLimit(f.a(), try h.encode(f.a(), payload), h.MAX_HTTP_INPUT);
        if (v != .object) v = .{ .object = .empty };
        try v.object.put(f.a(), "type", .{ .string = tag });
        try v.object.put(f.a(), "api_version", .{ .integer = 1 });
        try v.object.put(f.a(), "now_ms", .{ .integer = f.now });
        try v.object.put(f.a(), "wall_time_ms", .{ .integer = 1790363191000 + f.now });
        return h.parseLimit(f.a(), try f.host.handle(try h.encode(f.a(), v), f.a()), h.MAX_HTTP_INPUT);
    }
    fn intent(f: *Fixture, tag: []const u8, payload: anytype) ![]const u8 {
        var v = try h.parseLimit(f.a(), try h.encode(f.a(), payload), h.MAX_HTTP_INPUT);
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
    /// The oldest outstanding call for `method`.
    fn find(f: *Fixture, method: []const u8) !rpc.Call {
        for (f.host.state.rpc.calls) |call| if (h.eq(call.method, method)) return call;
        return error.MissingRequest;
    }
    fn params(f: *Fixture, method: []const u8) !V {
        const call = try f.find(method);
        const bytes = try @import("auth.zig").decode64(f.a(), call.body_base64);
        return p.get(try h.parse(f.a(), bytes), "params");
    }
    fn respond(f: *Fixture, call: rpc.Call, body: []const u8) !V {
        return f.event("http_response", .{ .effect_id = call.effect_id, .generation = try std.fmt.allocPrint(f.a(), "{d}", .{f.host.state.generation}), .status = 200, .headers = .{}, .body_base64 = try rpc.encodeBase64(f.a(), body), .@"error" = @as(?u8, null) });
    }
    fn replyJson(f: *Fixture, method: []const u8, result: []const u8) !V {
        const call = try f.find(method);
        return f.respond(call, try std.fmt.allocPrint(f.a(), "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ call.id, result }));
    }
    fn reject(f: *Fixture, method: []const u8, code: []const u8) !V {
        const call = try f.find(method);
        return f.respond(call, try h.encode(f.a(), .{ .jsonrpc = "2.0", .id = call.id, .@"error" = .{ .code = code, .message = "rejected" } }));
    }
    fn query(f: *Fixture, selector: []const u8) !V {
        const q = try h.parse(f.a(), try f.host.query(selector, f.a()));
        try expect(p.get(q, "error") == .null);
        return p.get(q, "data");
    }
    fn receipt(f: *Fixture, id: []const u8) !h.Operation {
        for (f.host.state.receipts) |r| if (h.eq(r.operation.intent_id, id)) return r.operation;
        return error.MissingReceipt;
    }
};

fn announced(output: V, scope: []const u8) bool {
    for (p.rows(p.get(output, "effects"))) |effect| if (h.eq(p.s(effect, "type"), "state_changed")) {
        for (p.rows(p.get(effect, "scopes"))) |s| if (h.eq(p.str(s), scope)) return true;
    };
    return false;
}

test "file tree lists roots, then folders lazily by root id, hiding .git and coalescing repeats" {
    var f = try Fixture.init(read_scopes);
    defer f.deinit();
    const roots = try f.intent("workspace_files_list", .{ .workspace_id = "ws-1" });
    try eql("pending", (try f.receipt(roots)).state);
    const first = try f.params("workspace.files.list");
    try expect(first.object.get("root") == null and first.object.get("path") == null);
    _ = try f.intent("workspace_files_list", .{ .workspace_id = "ws-1" });
    try expect(f.pending("workspace.files.list") == 1);
    const out = try f.replyJson("workspace.files.list",
        \\{"roots":[{"id":"home","name":"one","path":"/home/u/src/one"},{"id":"verde-cloud","name":"verde-cloud","path":"/home/u/src/verde-cloud"},{"id":"../x","name":"bad"},{"id":"bare"}],"entries":[],"truncated":false}
    );
    try expect(announced(out, "workspace_files:ws-1"));
    try eql("succeeded", (try f.receipt(roots)).state);
    var view = try f.query("workspace_files:ws-1");
    try expect(p.yes(p.get(view, "loaded")));
    const listed = p.rows(p.get(view, "roots"));
    try expect(listed.len == 3);
    try eql("home", p.s(listed[0], "id"));
    try expect(p.yes(p.get(listed[0], "home")) and !p.yes(p.get(listed[1], "home")));
    try eql("bare", p.s(listed[2], "name"));
    try eql("", p.s(listed[2], "path"));

    const dir = try f.intent("workspace_files_list", .{ .workspace_id = "ws-1", .root = "home", .path = "" });
    const params = try f.params("workspace.files.list");
    try eql("home", p.s(params, "root"));
    try eql("", p.s(params, "path"));
    view = try f.query("workspace_files:ws-1");
    try expect(p.yes(p.get(p.rows(p.get(view, "dirs"))[0], "loading")));
    // The same folder in another root is a different directory.
    _ = try f.intent("workspace_files_list", .{ .workspace_id = "ws-1", .root = "home", .path = "" });
    try expect(f.pending("workspace.files.list") == 1);
    _ = try f.replyJson("workspace.files.list",
        \\{"root":"home","path":"","entries":[{"name":".git","path":".git","kind":"directory","size":0,"ignored":false,"symlink":false},{"name":"src","path":"src","kind":"directory","size":0,"ignored":false,"symlink":false},{"name":"zig-out","path":"zig-out","kind":"directory","size":0,"ignored":true,"symlink":false},{"name":"build.zig","path":"build.zig","kind":"file","size":120,"ignored":false,"symlink":false},{"name":"odd","path":"/etc/passwd","kind":"file"},{"name":"up","path":"../up","kind":"file"}],"truncated":true}
    );
    try eql("succeeded", (try f.receipt(dir)).state);
    view = try f.query("workspace_files:ws-1");
    const d = p.rows(p.get(view, "dirs"))[0];
    try eql("home", p.s(d, "root"));
    try expect(!p.yes(p.get(d, "loading")) and p.yes(p.get(d, "loaded")) and p.yes(p.get(d, "truncated")));
    const entries = p.rows(p.get(d, "entries"));
    try expect(entries.len == 3);
    try eql("src", p.s(entries[0], "path"));
    try expect(p.yes(p.get(entries[1], "ignored")));
    try expect(p.uint(p.get(entries[2], "size")).? == 120);

    const other = try f.intent("workspace_files_list", .{ .workspace_id = "ws-1", .root = "verde-cloud", .path = "src/" });
    try eql("verde-cloud", p.s(try f.params("workspace.files.list"), "root"));
    try eql("src", p.s(try f.params("workspace.files.list"), "path"));
    _ = try f.replyJson("workspace.files.list",
        \\{"root":"verde-cloud","path":"src","entries":[{"name":"a.ts","path":"src/a.ts","kind":"file","size":3}],"truncated":false}
    );
    try eql("succeeded", (try f.receipt(other)).state);
    view = try f.query("workspace_files:ws-1");
    try expect(p.rows(p.get(view, "dirs")).len == 2);
    try eql("src/a.ts", p.s(p.rows(p.get(p.rows(p.get(view, "dirs"))[1], "entries"))[0], "path"));

    for ([_][2][]const u8{ .{ "home", "../etc" }, .{ "home", "/home/u/src/one" }, .{ "../x", "" }, .{ "a/b", "" }, .{ "", "" }, .{ "home", "a\\b" } }) |c| {
        const bad = try f.intent("workspace_files_list", .{ .workspace_id = "ws-1", .root = c[0], .path = c[1] });
        try eql("invalid_path", (try f.receipt(bad)).@"error".?.code);
    }
    try expect(f.pending("workspace.files.list") == 0);

    const missing = try f.intent("workspace_files_list", .{ .workspace_id = "ws-1", .root = "home", .path = "gone" });
    _ = try f.reject("workspace.files.list", "not_found");
    try eql("not_found", (try f.receipt(missing)).@"error".?.code);
    view = try f.query("workspace_files:ws-1");
    try eql("not_found", p.s(p.get(p.rows(p.get(view, "dirs"))[2], "error"), "code"));
}

test "file preview reads by root id with transport caps, keeps the newest and closes" {
    var f = try Fixture.init(read_scopes);
    defer f.deinit();
    const first = try f.intent("workspace_file_read", .{ .workspace_id = "ws-1", .root = "home", .path = "src/a.zig" });
    const params = try f.params("workspace.files.read");
    try eql("home", p.s(params, "root"));
    try eql("src/a.zig", p.s(params, "path"));
    try expect(p.uint(p.get(params, "max_bytes")).? == 524288);
    try expect(p.uint(p.get(params, "max_image_bytes")).? == 614400);
    const second = try f.intent("workspace_file_read", .{ .workspace_id = "ws-1", .root = "verde-cloud", .path = "logo.png" });
    var view = try f.query("workspace_file");
    try eql("logo.png", p.s(view, "path"));
    try expect(p.yes(p.get(view, "loading")));
    _ = try f.replyJson("workspace.files.read",
        \\{"root":"home","path":"src/a.zig","name":"a.zig","size":3,"kind":"text","encoding":"utf8","content":"abc","truncated":false}
    );
    try eql("superseded", (try f.receipt(first)).@"error".?.code);
    const out = try f.replyJson("workspace.files.read",
        \\{"root":"verde-cloud","path":"logo.png","name":"logo.png","size":4,"kind":"image","mime":"image/png","encoding":"base64","content":"iVBORw==","truncated":false}
    );
    try expect(announced(out, "workspace_file"));
    try eql("succeeded", (try f.receipt(second)).state);
    view = try f.query("workspace_file");
    try expect(!p.yes(p.get(view, "loading")));
    try eql("image", p.s(p.get(view, "result"), "kind"));
    try eql("iVBORw==", p.s(p.get(view, "result"), "content"));

    // A reply for a different file is rejected.
    const third = try f.intent("workspace_file_read", .{ .workspace_id = "ws-1", .root = "home", .path = "b.md" });
    _ = try f.replyJson("workspace.files.read",
        \\{"root":"home","path":"c.md","kind":"markdown","encoding":"utf8","content":"#"}
    );
    try eql("invalid_response", (try f.receipt(third)).@"error".?.code);

    for ([_][2][]const u8{ .{ "home", "" }, .{ "home", "../x" }, .{ "/home/u", "a" }, .{ "home", "/etc/passwd" } }) |c| {
        const bad = try f.intent("workspace_file_read", .{ .workspace_id = "ws-1", .root = c[0], .path = c[1] });
        try eql("invalid_path", (try f.receipt(bad)).@"error".?.code);
    }
    try expect(f.pending("workspace.files.read") == 0);

    _ = try f.intent("workspace_file_read", .{ .workspace_id = "ws-1", .root = "home", .path = "late.txt" });
    const close = try f.intent("workspace_preview_close", .{ .workspace_id = "ws-1" });
    try eql("succeeded", (try f.receipt(close)).state);
    view = try f.query("workspace_file");
    try eql("", p.s(view, "path"));
    try expect(p.get(view, "result") == .null);
    // The response still in flight lands nowhere.
    _ = try f.replyJson("workspace.files.read",
        \\{"root":"home","path":"late.txt","kind":"text","encoding":"utf8","content":"late"}
    );
    view = try f.query("workspace_file");
    try expect(p.get(view, "result") == .null);

    var g = try Fixture.init(read_scopes);
    defer g.deinit();
    _ = try g.intent("workspace_file_read", .{ .workspace_id = "ws-1", .root = "home", .path = "a" });
    _ = try g.reject("workspace.files.read", "method_not_found");
    try expect(!p.yes(p.get(try g.query("workspace_file"), "supported")));
    const again = try g.intent("workspace_file_read", .{ .workspace_id = "ws-1", .root = "home", .path = "a" });
    try eql("unsupported", (try g.receipt(again)).@"error".?.code);
}

test "explorer needs repository read and degrades on older hosts" {
    var f = try Fixture.init(&.{"chat:read"});
    defer f.deinit();
    const denied = try f.intent("workspace_changes_open", .{ .workspace_id = "ws-1" });
    try eql("scope_denied", (try f.receipt(denied)).@"error".?.code);
    try expect(f.pending("git.changes.workspace") == 0);

    var g = try Fixture.init(read_scopes);
    defer g.deinit();
    _ = try g.intent("workspace_files_list", .{ .workspace_id = "ws-1" });
    _ = try g.reject("workspace.files.list", "method_not_found");
    const view = try g.query("workspace_files:ws-1");
    try expect(!p.yes(p.get(view, "supported")));
    const again = try g.intent("workspace_files_list", .{ .workspace_id = "ws-1" });
    try eql("unsupported", (try g.receipt(again)).@"error".?.code);
}

test "workspace changes refresh on turns and foreground only while watched" {
    var f = try Fixture.init(read_scopes);
    defer f.deinit();
    const open = try f.intent("workspace_changes_open", .{ .workspace_id = "ws-1" });
    try eql("ws-1", p.s(try f.params("git.changes.workspace"), "workspace_id"));
    // A second open while the read is in flight coalesces into one trailing refresh.
    _ = try f.intent("workspace_changes_open", .{ .workspace_id = "ws-1" });
    try expect(f.pending("git.changes.workspace") == 1);
    const out = try f.replyJson("git.changes.workspace",
        \\{"workspace_id":"ws-1","revision":4,"repos":[{"root":"/home/u/src/one","name":"one","branch":"main","is_default_branch":true,"ahead":1,"files":[{"path":"src/a.zig","status":"modified","ownership":"mine","owners":[{"local_thread_id":"thread","title":"Fixture"}],"additions":3,"deletions":1},{"path":"notes.md","status":"added","untracked":true,"ownership":"unassigned"}]}],"future_field":1}
    );
    try expect(announced(out, "workspace_changes:ws-1"));
    try eql("succeeded", (try f.receipt(open)).state);
    try expect(f.pending("git.changes.workspace") == 1);
    _ = try f.replyJson("git.changes.workspace",
        \\{"workspace_id":"ws-1","revision":4,"repos":[{"root":"/home/u/src/one","name":"one","files":[{"path":"src/a.zig","status":"modified","ownership":"mine","owners":[{"local_thread_id":"thread","title":"Fixture"}],"additions":3,"deletions":1}]}]}
    );
    try expect(f.pending("git.changes.workspace") == 0);
    var view = try f.query("workspace_changes:ws-1");
    try expect(p.yes(p.get(view, "loaded")) and !p.yes(p.get(view, "loading")));
    const files = p.rows(p.get(p.rows(p.get(view, "repos"))[0], "files"));
    try expect(files.len == 1);
    try eql("Fixture", p.s(p.rows(p.get(files[0], "owners"))[0], "title"));

    _ = try f.event("foreground", .{});
    try expect(f.pending("git.changes.workspace") == 1);
    _ = try f.reject("git.changes.workspace", "resource_not_found");
    view = try f.query("workspace_changes:ws-1");
    try eql("resource_not_found", p.s(p.get(view, "error"), "code"));
    // The cached list stays on screen with the error.
    try expect(p.rows(p.get(view, "repos")).len == 1);

    _ = try f.intent("workspace_changes_close", .{ .workspace_id = "ws-1" });
    _ = try f.event("foreground", .{});
    try expect(f.pending("git.changes.workspace") == 0);
}

test "file patch keeps only the newest request and validates paths" {
    var f = try Fixture.init(read_scopes);
    defer f.deinit();
    const first = try f.intent("workspace_file_patch", .{ .workspace_id = "ws-1", .root = "/home/u/src/one", .path = "src/a.zig" });
    const second = try f.intent("workspace_file_patch", .{ .workspace_id = "ws-1", .root = "/home/u/src/one", .path = "src/b.zig", .context_lines = 5_000_000 });
    try expect(f.pending("git.changes.file_patch") == 2);
    _ = try f.replyJson("git.changes.file_patch",
        \\{"root":"/home/u/src/one","path":"src/a.zig","status":"modified","additions":1,"deletions":1,"patch":"@@ -1 +1 @@\n-a\n+b\n"}
    );
    try eql("superseded", (try f.receipt(first)).@"error".?.code);
    var view = try f.query("workspace_patch");
    try eql("src/b.zig", p.s(view, "path"));
    try expect(p.yes(p.get(view, "loading")));
    try expect(p.uint(p.get(view, "context_lines")).? == 1_000_000);
    try expect(p.uint(p.get(try f.params("git.changes.file_patch"), "context_lines")).? == 1_000_000);
    _ = try f.replyJson("git.changes.file_patch",
        \\{"root":"/home/u/src/one","path":"src/b.zig","status":"added","additions":2,"context_lines":1000000,"patch":"@@ -0,0 +1,2 @@\n+x\n+y\n"}
    );
    try eql("succeeded", (try f.receipt(second)).state);
    view = try f.query("workspace_patch");
    try expect(!p.yes(p.get(view, "loading")));
    try eql("@@ -0,0 +1,2 @@\n+x\n+y\n", p.s(p.get(view, "result"), "patch"));

    const escape = try f.intent("workspace_file_patch", .{ .workspace_id = "ws-1", .root = "/home/u/src/one", .path = "../secret" });
    try eql("invalid_path", (try f.receipt(escape)).@"error".?.code);
    const absolute = try f.intent("workspace_file_patch", .{ .workspace_id = "ws-1", .root = "/home/u/src/one", .path = "/etc/passwd" });
    try eql("invalid_path", (try f.receipt(absolute)).@"error".?.code);
    try expect(f.pending("git.changes.file_patch") == 0);
}

test "signing out clears explorer state" {
    var f = try Fixture.init(read_scopes);
    defer f.deinit();
    _ = try f.intent("workspace_changes_open", .{ .workspace_id = "ws-1" });
    _ = try f.replyJson("git.changes.workspace",
        \\{"workspace_id":"ws-1","revision":1,"repos":[]}
    );
    try expect(f.host.state.explorer.changes.len == 1);
    var tx = try h.Transaction.init(&f.host);
    defer tx.deinit();
    tx.state.auth.credential = null;
    try @import("workspace_explorer.zig").observe(&tx, .null);
    try expect(tx.state.explorer.changes.len == 0 and tx.state.explorer.watched.len == 0);
}
