//! User-initiated git review/commit, bounded idempotent recovery, no refresh polling.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
pub const m = @import("git_models.zig");
const clone = @import("state_clone.zig");
const add = @import("chat_catalogs.zig").append;
const A = std.mem.Allocator;
const V = std.json.Value;
const E = h.ApiError;
const eq = h.eq;
pub const Summary = struct {
    workspace_id: []const u8,
    threads: []const m.ThreadSummary = &.{},
    loading: bool = false,
    supported: bool = true,
    @"error": ?h.LocalError = null,
};
pub const ReviewView = struct {
    state: []const u8 = "idle",
    loading: bool = false,
    supported: bool = true,
    can_commit: bool = false,
    can_configure: bool = false,
    can_retry: bool = false,
    review: ?m.ReviewResult = null,
    message_state: []const u8 = "idle",
    message: ?m.CommitMessageResult = null,
    mutation_state: []const u8 = "idle",
    result: ?m.CommitResult = null,
    pull_push_result: ?m.PullPushResult = null,
    config: ?m.ConfigCommitSnapshot = null,
    @"error": ?h.LocalError = null,
};
const Watch = struct { view: Summary, dirty: bool = true, rpc_id: ?u64 = null };
pub const StatusView = struct {
    loading: bool = false,
    supported: bool = true,
    can_commit: bool = false,
    status: ?m.StatusResult = null,
    @"error": ?h.LocalError = null,
};
const Kind = enum { summary, status, review, message, commit, push, pull_push };
const Retained = struct {
    commit: ?m.CommitRequest = null,
    push: ?m.PushRequest = null,
    intent_id: []const u8,
    workspace_id: []const u8,
    expires_ms: i64,
    attempts: u8 = 0,
    due_ms: ?i64 = null,
};
const Request = struct { id: u64, kind: Kind, intent_id: []const u8, workspace_id: []const u8, epoch: u64 };
pub const State = struct {
    watches: []Watch = &.{},
    requests: []const Request = &.{},
    view: ReviewView = .{},
    route: ?m.ReviewRequest = null,
    epoch: u64 = 0,
    rereview: bool = false,
    status: StatusView = .{},
    status_route: ?m.StatusRequest = null,
    status_dirty: bool = false,
    status_id: ?u64 = null,
    retained: ?Retained = null,
    review_started_ms: i64 = 0,
};
pub fn owns(tag: []const u8) bool {
    return std.mem.startsWith(u8, tag, "git_");
}
pub fn receiptFields(tag: []const u8) ?[]const u8 {
    if (eq(tag, "selections")) return "root files";
    if (eq(tag, "files")) return "path hunks";
    if (eq(tag, "git_status_refresh")) return "workspace_id thread_id";
    if (eq(tag, "git_push")) return "workspace_id root";
    if (eq(tag, "git_retry")) return "";
    if (eq(tag, "git_summary_refresh")) return "workspace_id";
    if (eq(tag, "git_review_open")) return "workspace_id thread_id";
    if (eq(tag, "git_message_generate")) return "review_id selections";
    if (eq(tag, "git_commit")) return "review_id message selections push new_branch branch_name";
    if (eq(tag, "git_pull_push")) return "workspace_id root";
    if (eq(tag, "git_config_set")) return "commit_message_provider commit_message_model commit_default_action";
    return null;
}
pub fn validate(a: A, tag: []const u8, v: V) E!void {
    if (eq(tag, "git_summary_refresh")) {
        _ = try h.string(v, "workspace_id");
    } else if (eq(tag, "git_review_open") or eq(tag, "git_status_refresh")) {
        _ = try h.string(v, "workspace_id");
        _ = try h.string(v, "thread_id");
    } else if (eq(tag, "git_commit")) {
        _ = try h.decode(m.CommitRequest, a, v);
    } else if (eq(tag, "git_message_generate")) {
        _ = try h.decode(m.CommitMessageRequest, a, v);
    } else if (eq(tag, "git_pull_push") or eq(tag, "git_push")) {
        _ = try h.decode(m.PullPushRequest, a, v);
    } else if (eq(tag, "git_config_set")) {
        _ = try h.decode(m.ConfigCommitSetRequest, a, v);
    } else if (!eq(tag, "git_retry")) return error.InvalidArgument;
}
fn scoped(s: *const h.State, name: []const u8) bool {
    const credential = s.auth.credential orelse return false;
    for (credential.scopes) |scope| if (eq(scope, name)) return true;
    return false;
}
fn online(s: *const h.State) bool {
    return s.lifecycle == .foreground and s.network_available and s.rpc.phase == .ready and s.rpc.bearer != null;
}
fn failure(code: []const u8, message: []const u8) h.LocalError {
    return .{ .domain = "git", .code = code, .message = message };
}
fn receipt(tx: *h.Transaction, id: []const u8, state: []const u8, err: ?h.LocalError) void {
    for (@constCast(tx.state.receipts)) |*r| if (eq(r.operation.intent_id, id)) {
        r.operation.state = state;
        r.operation.@"error" = err;
    };
    tx.changed = true;
}
fn reject(tx: *h.Transaction, id: []const u8, e: h.LocalError) void {
    tx.state.git.view.@"error" = e;
    receipt(tx, id, "failed", e);
}
fn watch(tx: *h.Transaction, ws: []const u8) E!usize {
    for (tx.state.git.watches, 0..) |w, i| if (eq(w.view.workspace_id, ws)) return i;
    if (tx.state.git.watches.len >= 64 or ws.len == 0 or ws.len > 256) return error.ResourceLimit;
    const old = tx.state.git.watches;
    const next = try tx.allocator().alloc(Watch, old.len + 1);
    @memcpy(next[0..old.len], old);
    next[old.len] = .{ .view = .{ .workspace_id = ws } };
    tx.state.git.watches = next;
    return old.len;
}
fn track(tx: *h.Transaction, id: u64, kind: Kind, intent_id: []const u8, ws: []const u8) E!void {
    try add(Request, tx.allocator(), &tx.state.git.requests, .{ .id = id, .kind = kind, .intent_id = intent_id, .workspace_id = ws, .epoch = tx.state.git.epoch });
    receipt(tx, intent_id, "pending", null);
}
fn open(tx: *h.Transaction, intent_id: []const u8) E!void {
    const route = tx.state.git.route orelse return;
    const id = try rpc.request(tx, "git.changes.review", route, .{ .mutation = false, .intent_id = "@git" });
    tx.state.git.view.loading = true;
    try track(tx, id, .review, intent_id, route.workspace_id);
}
pub fn intent(tx: *h.Transaction, tag: []const u8, v: V) E!void {
    if (!owns(tag)) return;
    const id = try h.string(v, "intent_id");
    if (eq(tag, "git_config_set")) return reject(tx, id, failure("scope_denied", "Change commit settings on your computer."));
    const mutation = eq(tag, "git_commit") or eq(tag, "git_pull_push") or eq(tag, "git_push") or eq(tag, "git_retry");
    if (!scoped(&tx.state, "repository:read") or (mutation and !scoped(&tx.state, "chat:write"))) return reject(tx, id, failure("scope_denied", "This device can review changes but needs Chat or Full access to commit."));
    if (!online(&tx.state)) return reject(tx, id, failure("offline", "Connect to the host to review or commit changes."));
    const s = &tx.state.git;
    if (eq(s.view.mutation_state, "pending")) return reject(tx, id, failure("busy", "Wait for the current git operation to finish."));
    if (eq(tag, "git_retry")) {
        if (s.retained == null) return reject(tx, id, failure("nothing_to_retry", "No interrupted operation to retry."));
        s.retained.?.attempts = 0;
        s.retained.?.due_ms = tx.state.now_ms orelse 0;
        receipt(tx, id, "succeeded", null);
        return;
    }
    if (eq(tag, "git_summary_refresh")) {
        const i = try watch(tx, try h.string(v, "workspace_id"));
        s.watches[i].dirty = true;
        receipt(tx, id, "succeeded", null);
        return;
    }
    if (eq(tag, "git_review_open")) {
        if (s.retained) |retained| {
            if ((tx.state.now_ms orelse 0) < retained.expires_ms) return reject(tx, id, failure("busy", "Resolve the interrupted operation first."));
            s.retained = null;
        }
        const ws = try h.string(v, "workspace_id");
        const thread = try h.string(v, "thread_id");
        const route = routeFor(tx, ws, thread) orelse {
            s.epoch += 1;
            s.route = null;
            s.rereview = false;
            s.view = .{ .state = "unsupported", .supported = false };
            return reject(tx, id, failure("unsupported", "Remote-runtime chats cannot be reviewed on this phone yet."));
        };
        s.epoch += 1;
        s.view = .{ .state = "loading" };
        s.route = route;
        s.review_started_ms = tx.state.now_ms orelse 0;
        _ = try watch(tx, ws);
        try open(tx, id);
        return;
    }
    if (eq(tag, "git_status_refresh")) {
        const route = routeFor(tx, try h.string(v, "workspace_id"), try h.string(v, "thread_id")) orelse {
            s.status = .{ .supported = false, .@"error" = failure("unsupported", "Remote-runtime chats cannot be reviewed on this phone yet.") };
            s.status_route = null;
            receipt(tx, id, "failed", s.status.@"error");
            return;
        };
        if (s.status_route == null or !eq(s.status_route.?.workspace_id, route.workspace_id) or !eq(s.status_route.?.local_thread_id, route.local_thread_id)) s.status = .{};
        s.status_route = .{ .workspace_id = route.workspace_id, .local_thread_id = route.local_thread_id, .repository_id = route.repository_id, .relative_cwd = route.relative_cwd, .cwd = route.cwd };
        s.status_dirty = true;
        receipt(tx, id, "succeeded", null);
        return;
    }
    if (eq(tag, "git_push")) {
        const ws = try h.string(v, "workspace_id");
        const root = try h.string(v, "root");
        var known = false;
        if (s.status.status) |status| if (eq(status.workspace_id, ws)) {
            for (status.repos) |repo| if (eq(repo.root, root) and repo.has_remote and repo.ahead > 0) {
                known = true;
            };
        };
        if (!known) return reject(tx, id, failure("invalid_selection", "Refresh branch status before pushing."));
        if (s.retained != null) return reject(tx, id, failure("busy", "Resolve the interrupted operation first."));
        const key = try std.fmt.allocPrint(tx.allocator(), "{s}:{s}", .{ tx.state.config.session_nonce, id });
        const r = m.PushRequest{ .workspace_id = ws, .root = root, .request_id = key };
        s.view.pull_push_result = null;
        s.retained = .{ .push = r, .intent_id = id, .workspace_id = ws, .expires_ms = (tx.state.now_ms orelse 0) + 600_000 };
        s.view.mutation_state = "pending";
        try track(tx, try rpc.request(tx, "git.changes.push", r, .{ .mutation = true, .retry_auth = false, .intent_id = "@git", .timeout_ms = 120_000 }), .push, id, ws);
        return;
    }
    if (eq(tag, "git_pull_push")) {
        const r = try h.decode(m.PullPushRequest, tx.allocator(), v);
        var rejected = false;
        if (s.view.result) |result| if (eq(result.workspace_id, r.workspace_id)) {
            for (result.repos) |repo| if (eq(repo.root, r.root) and eq(repo.push, "rejected")) {
                rejected = true;
            };
        };
        if (s.view.pull_push_result) |result| if (eq(result.root, r.root) and eq(result.push, "rejected")) {
            rejected = true;
        };
        if (!rejected) return reject(tx, id, failure("invalid_selection", "Pull & push is available after a rejected push."));
        s.view.mutation_state = "pending";
        try track(tx, try rpc.request(tx, "git.changes.pull_push", r, .{ .mutation = true, .retry_auth = false, .intent_id = "@git", .timeout_ms = 120_000 }), .pull_push, id, r.workspace_id);
        return;
    }
    const review = s.view.review orelse return reject(tx, id, failure("review_expired", "Open a fresh review first."));
    if (!eq(p.s(v, "review_id"), review.review_id) or !eq(s.view.state, "loaded") or s.view.loading) return reject(tx, id, failure("review_expired", "Open a fresh review first."));
    if (eq(tag, "git_message_generate")) {
        if (eq(s.view.message_state, "loading")) return reject(tx, id, failure("busy", "A commit message is already being generated."));
        const r = try h.decode(m.CommitMessageRequest, tx.allocator(), v);
        if (r.selections) |selections| if (!validSelections(review, selections)) return reject(tx, id, failure("invalid_selection", "Choose files from this review."));
        s.view.message_state = "loading";
        s.view.@"error" = null;
        try track(tx, try rpc.request(tx, "git.changes.commit_message", r, .{ .mutation = false, .intent_id = "@git", .timeout_ms = 120_000 }), .message, id, review.workspace_id);
    } else if (eq(tag, "git_commit")) {
        const r = try h.decode(m.CommitRequest, tx.allocator(), v);
        if (s.retained != null) return reject(tx, id, failure("busy", "Resolve the interrupted operation first."));
        if (std.mem.trim(u8, r.message, " \n\r\t").len == 0 or r.message.len > 65536 or !validSelections(review, r.selections)) return reject(tx, id, failure("invalid_selection", "Choose files and enter a commit message."));
        s.view.result = null;
        s.retained = .{ .commit = r, .intent_id = id, .workspace_id = review.workspace_id, .expires_ms = s.review_started_ms + 3_600_000 };
        s.view.mutation_state = "pending";
        s.view.@"error" = null;
        try track(tx, try rpc.request(tx, "git.changes.commit", r, .{ .mutation = true, .retry_auth = false, .intent_id = "@git", .timeout_ms = if (r.push) 120_000 else 30_000 }), .commit, id, review.workspace_id);
    }
}
fn optional(v: V, key: []const u8) ?[]const u8 {
    const text = p.s(v, key);
    return if (text.len == 0) null else text;
}
pub fn validSelections(review: m.ReviewResult, selections: []const m.RepoSelection) bool {
    if (selections.len == 0) return false;
    for (selections, 0..) |selected, ri| {
        for (selections[0..ri]) |prior| if (eq(prior.root, selected.root)) return false;
        var repo: ?m.ReviewRepo = null;
        for (review.repos) |r| if (eq(r.root, selected.root)) {
            repo = r;
        };
        const r = repo orelse return false;
        if (selected.files.len == 0) return false;
        for (selected.files, 0..) |file, fi| {
            for (selected.files[0..fi]) |prior| if (eq(prior.path, file.path)) return false;
            var found: ?m.ReviewFile = null;
            for (r.files) |f| if (eq(f.path, file.path)) {
                found = f;
            };
            const f = found orelse return false;
            if (file.hunks) |hunks| {
                if (hunks.len == 0 or !f.hunk_selectable or f.preview_truncated or f.binary) return false;
                for (hunks, 0..) |index, hi| {
                    for (hunks[0..hi]) |prior| if (prior == index) return false;
                    var exists = false;
                    for (f.hunks) |chunk| if (chunk.index == index) {
                        exists = true;
                    };
                    if (!exists) return false;
                }
            }
        }
    }
    return true;
}
fn named(e: h.LocalError) h.LocalError {
    const code = e.rpc_code orelse e.code;
    return failure(code, if (eq(code, "changed_since_review")) "Files changed since review. Refreshing…" else if (eq(code, "head_moved")) "The branch changed. Refreshing…" else if (eq(code, "review_expired")) "This review expired. Refreshing…" else if (eq(code, "missing_git_identity")) "Set your Git name and email on your computer first." else if (eq(code, "branch_create_failed")) "Could not create the branch. Nothing was committed." else if (eq(code, "in_progress")) "The operation is still running. Checking its result…" else if (eq(code, "turns_running")) "Wait for running chats before pulling and pushing." else "The host could not complete the git operation.");
}
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.git;
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        if (result.intent_id == null or !eq(result.intent_id.?, "@git")) {
            try add(rpc.Result, tx.allocator(), &tx.state.rpc.results, result);
            continue;
        }
        var request: ?Request = null;
        for (s.requests, 0..) |r, i| if (r.id == result.id) {
            request = r;
            const next = try tx.allocator().alloc(Request, s.requests.len - 1);
            @memcpy(next[0..i], s.requests[0..i]);
            @memcpy(next[i..], s.requests[i + 1 ..]);
            s.requests = next;
            break;
        };
        const r = request orelse continue;
        tx.changed = true;
        if (r.kind == .summary) {
            const i = try watch(tx, r.workspace_id);
            const w = &s.watches[i];
            w.rpc_id = null;
            w.view.loading = false;
            if (result.@"error") |e| {
                w.view.@"error" = named(e);
                if (eq(e.rpc_code orelse "", "method_not_found")) w.view.supported = false;
            } else {
                const data = h.decode(m.SummaryResult, tx.allocator(), result.value orelse .null) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    w.view.@"error" = failure("invalid_response", "Could not read changes.");
                    continue;
                };
                if (!eq(data.workspace_id, r.workspace_id)) {
                    w.view.@"error" = failure("invalid_response", "Could not read changes.");
                    continue;
                }
                w.view.threads = data.threads;
                w.view.@"error" = null;
            }
            continue;
        }
        if (r.kind == .status) {
            s.status_id = null;
            s.status.loading = false;
            if (result.@"error") |err| {
                s.status.@"error" = named(err);
            } else {
                const status = h.decode(m.StatusResult, tx.allocator(), result.value orelse .null) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    s.status.@"error" = failure("invalid_response", "Could not read branch status.");
                    continue;
                };
                if (s.status_route) |route| if (eq(status.workspace_id, route.workspace_id) and eq(status.local_thread_id, route.local_thread_id)) {
                    s.status.status = status;
                    s.status.@"error" = null;
                };
            }
            continue;
        }
        if (r.epoch != s.epoch) {
            receipt(tx, r.intent_id, "failed", failure("superseded", "A newer review replaced this request."));
            continue;
        }
        s.view.loading = false;
        if (result.@"error") |e| {
            const uncertain = (r.kind == .commit or r.kind == .push or r.kind == .pull_push) and eq(e.delivery orelse "", "uncertain");
            if ((uncertain or eq(e.rpc_code orelse e.code, "in_progress")) and (r.kind == .commit or r.kind == .push) and s.retained != null) {
                try recovery(tx);
                continue;
            }
            if (r.kind == .commit or r.kind == .push) s.retained = null;
            const err = if (uncertain) failure("uncertain", "Pull & push may have completed. Refresh status before trying again.") else named(e);
            s.view.@"error" = err;
            if (r.kind == .message) s.view.message_state = "failed";
            if (r.kind == .commit or r.kind == .push or r.kind == .pull_push) s.view.mutation_state = if (uncertain) "uncertain" else "failed";
            if (r.kind == .review) {
                s.view.state = if (eq(err.code, "method_not_found")) "unsupported" else "failed";
                if (eq(err.code, "method_not_found")) s.view.supported = false;
            }
            if (eq(err.code, "changed_since_review") or eq(err.code, "review_expired")) {
                s.view.state = if (eq(err.code, "review_expired")) "expired" else "stale";
                s.rereview = true;
                s.watches[try watch(tx, r.workspace_id)].dirty = true;
            }
            receipt(tx, r.intent_id, if (uncertain) "uncertain" else "failed", err);
            continue;
        }
        const value = result.value orelse .null;
        switch (r.kind) {
            .review => {
                const review = h.decode(m.ReviewResult, tx.allocator(), value) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try invalidResponse(tx, r);
                    continue;
                };
                if (s.route == null or !eq(review.workspace_id, s.route.?.workspace_id) or !eq(review.local_thread_id, s.route.?.local_thread_id)) {
                    try invalidResponse(tx, r);
                    continue;
                }
                s.view.review = review;
                s.view.state = "loaded";
                s.view.message = null;
                s.view.message_state = "idle";
            },
            .message => {
                s.view.message = h.decode(m.CommitMessageResult, tx.allocator(), value) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try invalidResponse(tx, r);
                    continue;
                };
                s.view.message_state = "ready";
            },
            .commit => {
                s.view.result = h.decode(m.CommitResult, tx.allocator(), value) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try invalidResponse(tx, r);
                    continue;
                };
                if (!eq(s.view.result.?.workspace_id, r.workspace_id) or s.route == null or !eq(s.view.result.?.local_thread_id, s.route.?.local_thread_id)) {
                    s.view.result = null;
                    try invalidResponse(tx, r);
                    continue;
                }
                s.retained = null;
                s.status_dirty = true;
                s.view.mutation_state = "succeeded";
                s.view.state = "stale";
                s.rereview = true;
                s.watches[try watch(tx, r.workspace_id)].dirty = true;
            },
            .push, .pull_push => {
                s.view.pull_push_result = h.decode(m.PullPushResult, tx.allocator(), value) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try invalidResponse(tx, r);
                    continue;
                };
                s.retained = null;
                s.status_dirty = true;
                s.view.mutation_state = "succeeded";
                s.rereview = true;
                s.watches[try watch(tx, r.workspace_id)].dirty = true;
            },
            .summary, .status => unreachable,
        }
        receipt(tx, r.intent_id, "succeeded", null);
    }
    if (!online(&tx.state) or !scoped(&tx.state, "repository:read")) return;
    for (s.watches) |*w| if (w.dirty and w.rpc_id == null and w.view.supported) {
        w.rpc_id = try rpc.request(tx, "git.changes.summary", .{ .workspace_id = w.view.workspace_id }, .{ .mutation = false, .intent_id = "@git" });
        w.dirty = false;
        w.view.loading = true;
        try track(tx, w.rpc_id.?, .summary, "", w.view.workspace_id);
    };
    if (s.status_dirty and s.status_id == null) {
        if (s.status_route) |route| {
            s.status_id = try rpc.request(tx, "git.changes.status", route, .{ .mutation = false, .intent_id = "@git" });
            s.status.loading = true;
            s.status_dirty = false;
            try track(tx, s.status_id.?, .status, "", route.workspace_id);
        }
    }
    try retryRetained(tx);
    if (s.rereview and !s.view.loading) {
        s.rereview = false;
        s.epoch += 1;
        s.review_started_ms = tx.state.now_ms orelse 0;
        try open(tx, "");
    }
}
/// Refresh signals only; no polling timer. Coalesces changes during in-flight reads.
pub fn observe(tx: *h.Transaction, event: V) E!void {
    if (tx.state.auth.credential == null) {
        if (tx.state.git.watches.len > 0 or tx.state.git.route != null or tx.state.git.status_route != null or tx.state.git.retained != null) {
            tx.state.git = .{};
            tx.changed = true;
        }
        return;
    }
    const tag = p.s(event, "type");
    const dirty = eq(tag, "foreground") or eq(tag, "focus");
    if (eq(tag, "focus") and p.s(event, "workspace_id").len > 0) _ = try watch(tx, p.s(event, "workspace_id"));
    if (dirty) {
        turnChanged(tx);
    }
}
pub fn turnChanged(tx: *h.Transaction) void {
    tx.state.git.status_dirty = true;
    for (tx.state.git.watches) |*w| w.dirty = true;
}
fn invalidResponse(tx: *h.Transaction, r: Request) E!void {
    if ((r.kind == .commit or r.kind == .push) and tx.state.git.retained != null) return recovery(tx);
    const mutation = r.kind == .commit or r.kind == .push or r.kind == .pull_push;
    const err = failure(if (mutation) "uncertain" else "invalid_response", if (mutation) "The operation may have committed. Refreshing; it will not be sent again." else "Could not read the host response.");
    tx.state.git.view.@"error" = err;
    if (r.kind == .review) tx.state.git.view.state = "failed";
    if (r.kind == .message) tx.state.git.view.message_state = "failed";
    if (mutation) {
        tx.state.git.view.mutation_state = "uncertain";
        tx.state.git.view.state = "stale";
        tx.state.git.rereview = true;
        turnChanged(tx);
    }
    receipt(tx, r.intent_id, if (mutation) "uncertain" else "failed", err);
}
pub fn query(a: A, s: *const h.State, selector: []const u8) E!?V {
    if (eq(selector, "git_status")) {
        var view = s.git.status;
        view.can_commit = scoped(s, "repository:read") and scoped(s, "chat:write") and view.supported;
        return try h.parse(a, try h.encode(a, view));
    }
    if (eq(selector, "git_review")) {
        var view = s.git.view;
        view.can_commit = scoped(s, "repository:read") and scoped(s, "chat:write") and view.supported;
        view.can_configure = false;
        view.can_retry = s.git.retained != null and !eq(view.mutation_state, "pending") and (s.now_ms orelse 0) < s.git.retained.?.expires_ms;
        view.config = commitConfig(s);
        return try h.parse(a, try h.encode(a, view));
    }
    if (std.mem.startsWith(u8, selector, "git_summary:")) {
        const ws = selector[12..];
        for (s.git.watches) |w| if (eq(w.view.workspace_id, ws)) return try h.parse(a, try h.encode(a, w.view));
        return try h.parse(a, try h.encode(a, Summary{ .workspace_id = ws }));
    }
    return null;
}
fn commitConfig(s: *const h.State) m.ConfigCommitSnapshot {
    const config = p.get(p.get(s.sync.snapshot, "config"), "chat");
    return .{ .commit_message_provider = optional(config, "commit_message_provider") orelse "auto", .commit_message_model = optional(config, "commit_message_model"), .commit_default_action = optional(config, "commit_default_action") orelse "commit" };
}
pub fn scopes(a: A, before: *const h.State, after: *const h.State) E![]const []const u8 {
    var out: []const []const u8 = &.{};
    if (!clone.equal(StatusView, before.git.status, after.git.status) or !clone.equal(@TypeOf(before.auth.credential), before.auth.credential, after.auth.credential)) try add([]const u8, a, &out, "git_status");
    if (!clone.equal(ReviewView, before.git.view, after.git.view) or !clone.equal(m.ConfigCommitSnapshot, commitConfig(before), commitConfig(after)) or !clone.equal(@TypeOf(before.auth.credential), before.auth.credential, after.auth.credential)) try add([]const u8, a, &out, "git_review");
    for (after.git.watches) |w| {
        var changed = true;
        for (before.git.watches) |old| if (eq(old.view.workspace_id, w.view.workspace_id)) {
            changed = !clone.equal(Summary, old.view, w.view);
            break;
        };
        if (changed) try add([]const u8, a, &out, try std.fmt.allocPrint(a, "git_summary:{s}", .{w.view.workspace_id}));
    }
    for (before.git.watches) |old| {
        var retained = false;
        for (after.git.watches) |w| if (eq(w.view.workspace_id, old.view.workspace_id)) {
            retained = true;
        };
        if (!retained) try add([]const u8, a, &out, try std.fmt.allocPrint(a, "git_summary:{s}", .{old.view.workspace_id}));
    }
    return out;
}

fn routeFor(tx: *h.Transaction, ws: []const u8, thread: []const u8) ?m.ReviewRequest {
    var source: V = .null;
    for (p.rows(p.get(p.get(tx.state.sync.snapshot, "snapshot"), "workspaces"))) |w| if (eq(p.s(w, "workspace_id"), ws)) {
        for (p.rows(p.get(w, "threads"))) |t| if (eq(p.s(t, "local_thread_id"), thread)) {
            source = t;
        };
    };
    for (tx.state.sync.catalog) |t| if (eq(p.s(t, "workspace_id"), ws) and eq(p.s(t, "local_thread_id"), thread)) {
        source = t;
    };
    const profile = p.s(source, "profile_id");
    const runtime = p.s(source, "runtime_id");
    if (source == .null or (profile.len > 0 and !eq(profile, "local")) or (runtime.len > 0 and !eq(runtime, tx.state.rpc.runtime_id orelse ""))) return null;
    return .{ .hunk_budget_bytes = @min(tx.state.rpc.limits.max_response_bytes / 16, 128 * 1024), .workspace_id = ws, .local_thread_id = thread, .repository_id = optional(source, "repository_id"), .relative_cwd = optional(source, "repository_cwd"), .cwd = optional(source, "cwd") };
}
fn recovery(tx: *h.Transaction) E!void {
    const s = &tx.state.git;
    const r = if (s.retained) |*value| value else return;
    const now = tx.state.now_ms orelse 0;
    s.view.mutation_state = "uncertain";
    s.view.@"error" = failure("uncertain", "Checking the original operation; no new commit or push will be started.");
    receipt(tx, r.intent_id, "uncertain", s.view.@"error");
    if (r.attempts >= 3 or now >= r.expires_ms) return;
    r.due_ms = now + 2_000;
    try tx.setTimer("git_retry", 2_000);
}
pub fn complete(_: *h.Transaction, pending: h.Pending) bool {
    return pending.kind == .timer and eq(pending.purpose, "git_retry");
}
fn retryRetained(tx: *h.Transaction) E!void {
    const s = &tx.state.git;
    if (!online(&tx.state) or !scoped(&tx.state, "chat:write") or !scoped(&tx.state, "repository:read")) return;
    const r = if (s.retained) |*value| value else return;
    const due = r.due_ms orelse return;
    const now = tx.state.now_ms orelse 0;
    if (now < due) return;
    if (now >= r.expires_ms) {
        r.due_ms = null;
        s.view.@"error" = failure("retry_expired", "The safe retry window expired. Refresh changes and check the repository on your computer.");
        return;
    }
    r.due_ms = null;
    r.attempts += 1;
    s.view.mutation_state = "pending";
    if (r.commit) |request| {
        try track(tx, try rpc.request(tx, "git.changes.commit", request, .{ .mutation = true, .retry_auth = false, .intent_id = "@git", .timeout_ms = if (request.push) 120_000 else 30_000 }), .commit, r.intent_id, r.workspace_id);
    } else if (r.push) |request| {
        try track(tx, try rpc.request(tx, "git.changes.push", request, .{ .mutation = true, .retry_auth = false, .intent_id = "@git", .timeout_ms = 120_000 }), .push, r.intent_id, r.workspace_id);
    }
}
