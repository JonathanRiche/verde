//! D-10 thread and workspace management. Sans-IO like chat: every step is an
//! owned `/api/rpc` call, and each outcome lands on its intent receipt and on
//! the `manage` view. The view also carries `workspace_busy` counts and the
//! identity of a created thread or workspace.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const chat = @import("chat.zig");
const m = @import("chat_models.zig");
const c = @import("chat_catalogs.zig");
const sync = @import("sync.zig");
const store = @import("headless").store_protocol;
const V = std.json.Value;
const E = h.ApiError;
const A = std.mem.Allocator;
const eq = h.eq;
const add = c.append;

pub const Busy = rpc.Busy;
/// One management intent. `kind` is the intent tag; `thread_id` is set up front
/// for `thread_create` so the platform can navigate once `state` succeeds.
pub const Job = struct {
    intent_id: []const u8,
    kind: []const u8,
    state: []const u8 = "pending",
    workspace_id: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    busy: ?Busy = null,
    @"error": ?h.LocalError = null,
};
pub const DirectoryEntry = struct { name: []const u8, path: []const u8 };
/// Latest `directory_list` page. `suggestions` are parents of known workspaces,
/// which the daemon always accepts as browse roots.
pub const Directory = struct {
    path: []const u8 = "",
    parent: ?[]const u8 = null,
    entries: []const DirectoryEntry = &.{},
    suggestions: []const []const u8 = &.{},
    supported: bool = false,
    loading: bool = false,
    @"error": ?h.LocalError = null,
};
pub const NewChat = struct {
    workspace_id: ?[]const u8 = null,
    selection: m.Selection,
    providers: []const m.Choice = &.{},
    catalogs: m.Catalogs,
    loading: bool = false,
    can_create: bool = false,
    @"error": ?h.LocalError = null,
};
pub const View = struct {
    operations: []const Job,
    directory: Directory,
    new_chat: NewChat,
    can_manage_workspaces: bool,
    can_create_threads: bool,
};

const Step = enum { register, snapshot, workspace_upsert, thread_upsert, thread_get, thread_mutate, close, done };
const Task = struct {
    job: Job,
    step: Step = .register,
    rpc_id: ?u64 = null,
    attempts: u8 = 0,
    path: []const u8 = "",
    label: ?[]const u8 = null,
    archived: ?bool = null,
    thread: ?store.Thread = null,
    revision: ?u64 = null,
};
pub const State = struct {
    tasks: []Task = &.{},
    directory: Directory = .{},
    directory_id: ?u64 = null,
    directory_intent: []const u8 = "",
    chat_workspace: ?[]const u8 = null,
    selection: m.Selection = .{},
    models: V = .null,
    models_id: ?u64 = null,
    models_error: ?h.LocalError = null,
};

const MAX_TASKS = 16;
const MAX_LABEL = 256;
const tags = [_][]const u8{ "thread_rename", "thread_close", "thread_sync", "thread_create", "new_chat_select", "workspace_create", "workspace_rename", "workspace_archive", "workspace_close", "directory_list" };
const providers = [_][2][]const u8{ .{ "codex", "Codex" }, .{ "claude", "Claude" }, .{ "opencode", "OpenCode" }, .{ "cursor", "Cursor" }, .{ "pi", "Pi" }, .{ "fx", "FX" }, .{ "grok", "Grok" }, .{ "muse", "Muse" } };

pub fn owns(tag: []const u8) bool {
    for (tags) |t| if (eq(t, tag)) return true;
    return false;
}

const Selected = struct { provider: ?[]const u8 = null, model: ?[]const u8 = null, effort: ?[]const u8 = null, access: ?[]const u8 = null, speed: ?[]const u8 = null };
pub fn validate(a: A, tag: []const u8, event: V) E!void {
    if (eq(tag, "thread_rename") or eq(tag, "thread_close") or eq(tag, "thread_sync")) {
        _ = try h.decode(struct { workspace_id: []const u8, thread_id: []const u8 }, a, event);
        if (eq(tag, "thread_rename")) _ = try h.decode(struct { title: []const u8 }, a, event);
    } else if (eq(tag, "thread_create")) {
        _ = try h.decode(struct { workspace_id: []const u8, provider: []const u8 }, a, event);
        _ = try h.decode(Selected, a, event);
    } else if (eq(tag, "new_chat_select")) {
        _ = try h.decode(struct { workspace_id: []const u8 }, a, event);
        _ = try h.decode(Selected, a, event);
    } else if (eq(tag, "workspace_create")) {
        _ = try h.decode(struct { path: []const u8, label: ?[]const u8 = null }, a, event);
    } else if (eq(tag, "workspace_rename")) {
        _ = try h.decode(struct { workspace_id: []const u8, label: []const u8 }, a, event);
    } else if (eq(tag, "workspace_archive")) {
        _ = try h.decode(struct { workspace_id: []const u8, archived: bool }, a, event);
    } else if (eq(tag, "workspace_close")) {
        _ = try h.decode(struct { workspace_id: []const u8 }, a, event);
    } else if (eq(tag, "directory_list")) {
        _ = try h.decode(struct { path: ?[]const u8 = null }, a, event);
    }
}

pub fn receiptFields(context: []const u8) ?[]const u8 {
    if (eq(context, "thread_rename")) return "workspace_id thread_id title";
    if (eq(context, "thread_close") or eq(context, "thread_sync")) return "workspace_id thread_id";
    if (eq(context, "thread_create")) return "workspace_id provider model effort access speed";
    if (eq(context, "new_chat_select")) return "workspace_id provider model effort access speed";
    if (eq(context, "workspace_create")) return "path label";
    if (eq(context, "workspace_rename")) return "workspace_id label";
    if (eq(context, "workspace_archive")) return "workspace_id archived";
    if (eq(context, "workspace_close")) return "workspace_id";
    if (eq(context, "directory_list")) return "path";
    return null;
}

fn failure(code: []const u8, message: []const u8) h.LocalError {
    return .{ .domain = "lifecycle", .code = code, .message = message };
}
fn receipt(tx: *h.Transaction, id: []const u8, state: []const u8, err: ?h.LocalError) void {
    for (@constCast(tx.state.receipts)) |*r| if (eq(r.operation.intent_id, id)) {
        r.operation.state = state;
        r.operation.@"error" = err;
    };
    tx.changed = true;
}
fn online(tx: *h.Transaction) bool {
    return tx.state.lifecycle == .foreground and tx.state.network_available and tx.state.rpc.phase == .ready and tx.state.rpc.bearer != null and tx.state.rpc.spki_sha256 != null;
}
fn scoped(state: *const h.State, name: []const u8) bool {
    const credential = state.auth.credential orelse return false;
    for (credential.scopes) |s| if (eq(s, name)) return true;
    return false;
}
fn capable(state: *const h.State, name: []const u8) bool {
    for (state.rpc.runtime_capabilities) |cap| if (eq(cap, name)) return true;
    return false;
}
fn workspace(state: *const h.State, id: []const u8) V {
    for (p.rows(p.get(p.get(state.sync.snapshot, "snapshot"), "workspaces"))) |w| if (eq(p.s(w, "workspace_id"), id)) return w;
    return .null;
}
fn known(provider: []const u8) bool {
    for (providers) |item| if (eq(item[0], provider)) return true;
    return false;
}
/// Same identity as the web fallback (`linuxWorkspaceId`): wyhash seed 0, lowercase hex.
pub fn workspaceId(a: A, path: []const u8) E![]const u8 {
    return std.fmt.allocPrint(a, "{x}", .{std.hash.Wyhash.hash(0, path)});
}
/// Absolute, no parent traversal or control bytes; trailing slashes dropped.
fn cleanPath(raw: []const u8) ?[]const u8 {
    var path = std.mem.trim(u8, raw, " \t\r\n");
    while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (path.len == 0 or path.len > 4096 or path[0] != '/') return null;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return null;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (eq(part, "..") or eq(part, ".")) return null;
    return path;
}
fn cleanLabel(raw: []const u8) ?[]const u8 {
    const label = std.mem.trim(u8, raw, " \t\r\n");
    if (label.len == 0 or label.len > MAX_LABEL) return null;
    for (label) |byte| if (byte < 0x20 or byte == 0x7f) return null;
    return label;
}
fn digestHex(tx: *h.Transaction, parts: anytype, len: usize) E![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try h.encode(tx.allocator(), parts), &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return tx.allocator().dupe(u8, hex[0..len]);
}
/// Stable per logical mutation and attempt; intent IDs never reach the daemon.
fn requestKey(tx: *h.Transaction, t: *const Task) E![]const u8 {
    return std.fmt.allocPrint(tx.allocator(), "mobile:{s}:{d}", .{ try digestHex(tx, .{ tx.state.config.host_id, t.job.intent_id }, 24), t.attempts });
}

fn begin(tx: *h.Transaction, job: Job) E!usize {
    const s = &tx.state.manage;
    var kept: []Task = &.{};
    const drop = s.tasks.len + 1 > MAX_TASKS;
    var dropped = false;
    for (s.tasks) |t| {
        if (drop and !dropped and t.step == .done) {
            dropped = true;
            continue;
        }
        try addTask(tx.allocator(), &kept, t);
    }
    if (kept.len >= MAX_TASKS) return error.ResourceLimit;
    try addTask(tx.allocator(), &kept, .{ .job = job });
    s.tasks = kept;
    receipt(tx, job.intent_id, "pending", null);
    return kept.len - 1;
}
fn addTask(a: A, dest: *[]Task, item: Task) E!void {
    const next = try a.alloc(Task, dest.len + 1);
    @memcpy(next[0..dest.len], dest.*);
    next[dest.len] = item;
    dest.* = next;
}
fn finish(tx: *h.Transaction, i: usize, err: ?h.LocalError) void {
    const t = &tx.state.manage.tasks[i];
    t.step = .done;
    t.rpc_id = null;
    t.job.@"error" = err;
    t.job.state = if (err) |e| (if (eq(e.delivery orelse "", "uncertain")) "uncertain" else "failed") else "succeeded";
    receipt(tx, t.job.intent_id, t.job.state, err);
}
fn fail(tx: *h.Transaction, job: Job, code: []const u8, message: []const u8) E!void {
    const i = try begin(tx, job);
    finish(tx, i, failure(code, message));
}

/// Workspace/thread management intents. Host receipts already deduplicate retries.
pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!bool {
    if (!owns(tag)) return false;
    const id = p.s(event, "intent_id");
    if (eq(tag, "directory_list")) {
        try directory(tx, id, p.get(event, "path"));
        return true;
    }
    if (eq(tag, "new_chat_select")) {
        try select(tx, id, event);
        return true;
    }
    const ws_id = p.s(event, "workspace_id");
    var job: Job = .{ .intent_id = id, .kind = tag, .workspace_id = if (ws_id.len > 0) ws_id else null };
    const write_scope = if (std.mem.startsWith(u8, tag, "thread_")) "chat:write" else "repository:write";
    if (!online(tx)) {
        try fail(tx, job, "unavailable", "Connect to the host first.");
        return true;
    }
    if (!scoped(&tx.state, write_scope)) {
        try fail(tx, job, "insufficient_scope", "This device may not change workspaces.");
        return true;
    }
    if (eq(tag, "thread_rename") or eq(tag, "thread_close") or eq(tag, "thread_sync")) {
        job.thread_id = p.s(event, "thread_id");
        if (ws_id.len == 0 or job.thread_id.?.len == 0) {
            try fail(tx, job, "not_found", "Chat not found.");
            return true;
        }
        const label = if (eq(tag, "thread_rename")) cleanLabel(p.s(event, "title")) else null;
        if (eq(tag, "thread_rename") and label == null) {
            try fail(tx, job, "invalid_title", "Use a chat title between 1 and 256 bytes, without line breaks.");
            return true;
        }
        const i = try begin(tx, job);
        tx.state.manage.tasks[i].label = label;
        try advance(tx, i);
        return true;
    }
    if (eq(tag, "thread_create")) {
        try createThread(tx, job, event);
        return true;
    }
    if (eq(tag, "workspace_create")) {
        const path = cleanPath(p.s(event, "path")) orelse {
            try fail(tx, job, "invalid_path", "Choose an absolute folder path.");
            return true;
        };
        const label_value = p.get(event, "label");
        const label = if (label_value == .string and std.mem.trim(u8, label_value.string, " \t\r\n").len > 0) cleanLabel(label_value.string) orelse {
            try fail(tx, job, "invalid_label", "Use a shorter workspace name.");
            return true;
        } else null;
        job.workspace_id = try workspaceId(tx.allocator(), path);
        const existing = workspace(&tx.state, job.workspace_id.?);
        const i = try begin(tx, job);
        const t = &tx.state.manage.tasks[i];
        t.path = path;
        t.label = label;
        if (existing != .null) {
            if (!p.yes(p.get(existing, "archived")) and label == null) {
                finish(tx, i, null);
                return true;
            }
            // Adding a closed workspace's folder again reopens it, keeping its metadata.
            t.archived = false;
        }
        try advance(tx, i);
        return true;
    }
    if (ws_id.len == 0) {
        try fail(tx, job, "workspace_unavailable", "Workspace not found.");
        return true;
    }
    if (eq(tag, "workspace_close")) {
        const i = try begin(tx, job);
        tx.state.manage.tasks[i].step = .close;
        try advance(tx, i);
        return true;
    }
    var label: ?[]const u8 = null;
    var archived: ?bool = null;
    if (eq(tag, "workspace_rename")) {
        label = cleanLabel(p.s(event, "label")) orelse {
            try fail(tx, job, "invalid_label", "Enter a workspace name.");
            return true;
        };
    } else archived = p.yes(p.get(event, "archived"));
    const i = try begin(tx, job);
    tx.state.manage.tasks[i].label = label;
    tx.state.manage.tasks[i].archived = archived;
    try advance(tx, i);
    return true;
}

fn createThread(tx: *h.Transaction, base: Job, event: V) E!void {
    var job = base;
    const ws = workspace(&tx.state, p.s(event, "workspace_id"));
    if (ws == .null) return fail(tx, job, "workspace_unavailable", "Workspace not found.");
    if (p.yes(p.get(ws, "archived"))) return fail(tx, job, "workspace_archived", "Reopen this workspace first.");
    var selection = try h.decode(m.Selection, tx.allocator(), event);
    if (selection.effort != null and selection.effort.?.len == 0) selection.effort = null;
    if (!try valid(tx, p.s(event, "workspace_id"), selection)) return fail(tx, job, "invalid_selection", "Choose a supported provider and model.");
    const a = tx.allocator();
    const suffix = try digestHex(tx, .{ tx.state.config.session_nonce, job.intent_id }, 8);
    // `web-thread-` marks a chat started by a remote client; desktop and web
    // tile and list those once they are committed by a first send.
    const thread_id = try std.fmt.allocPrint(a, "web-thread-{d}-{s}", .{ @max(tx.state.wall_time_ms, 0), suffix });
    job.thread_id = thread_id;
    const provider = selection.provider.?;
    const variant = eq(provider, "cursor") or eq(provider, "opencode");
    const i = try begin(tx, job);
    tx.state.manage.tasks[i].thread = .{
        .local_thread_id = thread_id,
        .title = "New Chat",
        .committed = false,
        .last_activity_at = @divFloor(@max(tx.state.wall_time_ms, 0), 1000),
        .model_ref = selection.model,
        .reasoning_effort = if (variant) null else selection.effort,
        .reasoning_variant = if (variant) selection.effort else null,
        .fast_mode = selection.speed,
        .access_mode = selection.access orelse "full_access",
        .provider = provider,
        .harness = "local_cli",
        // The daemon rejects a partial route: profile and repository travel together.
        .profile_id = "local",
        .repository_id = "primary",
    };
    try advance(tx, i);
}

fn models(state: *const h.State, provider: []const u8, ws: []const u8) V {
    const s = &state.manage;
    if (s.chat_workspace == null or !eq(s.chat_workspace.?, ws) or !eq(s.selection.provider orelse "", provider)) return .null;
    return s.models;
}
fn valid(tx: *h.Transaction, ws: []const u8, selection: m.Selection) E!bool {
    const provider = selection.provider orelse return false;
    if (!known(provider)) return false;
    const catalogs = try c.catalogs(tx.allocator(), selection, models(&tx.state, provider, ws), .null);
    return catalogs.models.len > 0 and c.contains(catalogs.models, selection.model) and c.contains(catalogs.efforts, selection.effort) and c.contains(catalogs.access, selection.access) and c.contains(catalogs.speeds, selection.speed);
}

/// The New chat sheet's working selection; loads the provider's model catalog.
fn select(tx: *h.Transaction, id: []const u8, event: V) E!void {
    const s = &tx.state.manage;
    const ws_id = p.s(event, "workspace_id");
    const ws = workspace(&tx.state, ws_id);
    if (ws == .null) return receipt(tx, id, "failed", failure("workspace_unavailable", "Workspace not found."));
    var selection = try h.decode(m.Selection, tx.allocator(), event);
    if (selection.effort != null and selection.effort.?.len == 0) selection.effort = null;
    const same_workspace = s.chat_workspace != null and eq(s.chat_workspace.?, ws_id);
    if (selection.provider == null) selection.provider = if (same_workspace) s.selection.provider else null;
    if (selection.provider == null) selection.provider = if (known(p.s(ws, "provider"))) p.s(ws, "provider") else "codex";
    const provider = selection.provider.?;
    const reload = !same_workspace or !eq(s.selection.provider orelse "", provider);
    if (!known(provider)) return receipt(tx, id, "failed", failure("invalid_selection", "Choose a supported provider."));
    const dynamic: V = if (reload) .null else s.models;
    const catalogs = try c.catalogs(tx.allocator(), selection, dynamic, .null);
    if (!c.contains(catalogs.models, selection.model) or !c.contains(catalogs.efforts, selection.effort) or !c.contains(catalogs.access, selection.access) or !c.contains(catalogs.speeds, selection.speed)) {
        return receipt(tx, id, "failed", failure("invalid_selection", "That model setting is not available."));
    }
    s.chat_workspace = ws_id;
    s.selection = selection;
    receipt(tx, id, "succeeded", null);
    if (!reload) return;
    s.models = .null;
    s.models_id = null;
    s.models_error = null;
    if (!online(tx) or !scoped(&tx.state, "runtime:read")) return;
    s.models_id = try rpc.request(tx, "provider.models.list", .{ .provider = provider, .project_path = p.s(ws, "path") }, .{ .mutation = false, .intent_id = "@manage" });
}

fn directory(tx: *h.Transaction, id: []const u8, requested: V) E!void {
    const s = &tx.state.manage;
    if (s.directory_intent.len > 0) receipt(tx, s.directory_intent, "succeeded", null);
    s.directory_intent = "";
    s.directory_id = null;
    s.directory.loading = false;
    var err: ?h.LocalError = null;
    if (!online(tx)) err = failure("unavailable", "Connect to the host first.") else if (!scoped(&tx.state, "repository:read")) err = failure("insufficient_scope", "This device may not browse folders.") else if (!capable(&tx.state, "workspace.directory.v1")) err = failure("unsupported", "Update Verde on the computer to browse folders.");
    const raw = if (requested == .string and std.mem.trim(u8, requested.string, " \t\r\n").len > 0) requested.string else try defaultRoot(tx.allocator(), &tx.state);
    const path = cleanPath(raw) orelse blk: {
        if (err == null) err = failure("invalid_path", "Choose an absolute folder path.");
        break :blk raw;
    };
    s.directory.path = path;
    s.directory.parent = null;
    s.directory.entries = &.{};
    s.directory.@"error" = err;
    if (err) |e| return receipt(tx, id, "failed", e);
    s.directory.loading = true;
    s.directory_intent = id;
    s.directory_id = try rpc.request(tx, "workspace.directory.list", .{ .path = path }, .{ .mutation = false, .intent_id = "@manage" });
    receipt(tx, id, "pending", null);
}
fn suggestions(a: A, state: *const h.State) E![]const []const u8 {
    var out: []const []const u8 = &.{};
    for (p.rows(p.get(p.get(state.sync.snapshot, "snapshot"), "workspaces"))) |w| {
        const path = cleanPath(p.s(w, "path")) orelse continue;
        const parent = std.fs.path.dirnamePosix(path) orelse continue;
        var duplicate = false;
        for (out) |seen| if (eq(seen, parent)) {
            duplicate = true;
        };
        if (!duplicate and out.len < 16) try add([]const u8, a, &out, parent);
    }
    return out;
}
fn defaultRoot(a: A, state: *const h.State) E![]const u8 {
    const roots = try suggestions(a, state);
    return if (roots.len > 0) roots[0] else "/";
}

/// Issue the request for a task's current step.
fn advance(tx: *h.Transaction, i: usize) E!void {
    const t = &tx.state.manage.tasks[i];
    if (t.step == .register and tx.state.chat.client_id != null) t.step = firstStep(t);
    switch (t.step) {
        .register => t.rpc_id = try rpc.request(tx, "daemon.client.register", .{ .persistent = false }, .{ .intent_id = "@manage" }),
        .snapshot => t.rpc_id = try rpc.request(tx, "core.snapshot", .{ .workspace_id = t.job.workspace_id.?, .scopes = [_][]const u8{"workspaces"} }, .{ .mutation = false, .legacy_snapshot = true, .intent_id = "@manage" }),
        .workspace_upsert => t.rpc_id = try rpc.request(tx, "workspace.upsert", .{ .mutation = .{ .request_key = try requestKey(tx, t), .client_id = tx.state.chat.client_id.? }, .workspace = .{ .workspace_id = t.job.workspace_id.?, .label = t.label orelse std.fs.path.basenamePosix(t.path), .path = t.path } }, .{ .intent_id = "@manage" }),
        .thread_get => t.rpc_id = try rpc.request(tx, "chat.thread.get", .{ .workspace_id = t.job.workspace_id.?, .local_thread_id = t.job.thread_id.? }, .{ .mutation = false, .intent_id = "@manage" }),
        .thread_mutate => {
            const mutation = .{ .client_id = tx.state.chat.client_id.?, .request_key = try requestKey(tx, t), .expected_store_revision = t.revision };
            if (eq(t.job.kind, "thread_rename")) {
                t.rpc_id = try rpc.request(tx, "chat.thread.upsert", .{ .workspace_id = t.job.workspace_id.?, .thread = t.thread.?, .mutation = mutation }, .{ .intent_id = "@manage" });
            } else if (eq(t.job.kind, "thread_close")) {
                t.rpc_id = try rpc.request(tx, "chat.thread.close", .{ .workspace_id = t.job.workspace_id.?, .local_thread_id = t.job.thread_id.?, .mutation = mutation }, .{ .intent_id = "@manage" });
            } else {
                const thread = t.thread.?;
                if (thread.provider_thread_id == null or (thread.profile_id != null and !eq(thread.profile_id.?, "local"))) return finish(tx, i, failure("unsupported", "Sync requires a saved provider thread on this host."));
                const projected = try p.project(tx.allocator(), tx.state.sync.snapshot, tx.state.sync.catalog, tx.state.sync.has_catalog, tx.state.wall_time_ms);
                for (projected.active) |item| if ((item.can_stop or eq(item.status, "waiting_approval")) and item.thread_id != null and eq(item.thread_id.?, t.job.thread_id.?) and eq(item.workspace_id, t.job.workspace_id.?)) {
                    return finish(tx, i, failure("thread_busy", "Wait for this chat to finish before syncing."));
                };
                t.rpc_id = try rpc.request(tx, "provider.thread.sync", .{ .workspace_id = t.job.workspace_id.?, .local_thread_id = t.job.thread_id.?, .provider_thread_id = thread.provider_thread_id.? }, .{ .intent_id = "@manage" });
            }
        },
        .thread_upsert => t.rpc_id = try rpc.request(tx, "chat.thread.upsert", .{ .workspace_id = t.job.workspace_id.?, .thread = t.thread.?, .mutation = .{ .client_id = tx.state.chat.client_id.?, .request_key = try requestKey(tx, t) } }, .{ .intent_id = "@manage" }),
        .close => t.rpc_id = try rpc.request(tx, "workspace.close", .{ .workspace_id = t.job.workspace_id.? }, .{ .intent_id = "@manage" }),
        .done => {},
    }
}
fn firstStep(t: *const Task) Step {
    if (eq(t.job.kind, "thread_create")) return .thread_upsert;
    if (std.mem.startsWith(u8, t.job.kind, "thread_")) return .thread_get;
    // Rename, archive and reopen rewrite the full metadata read at a revision.
    if (t.archived != null or eq(t.job.kind, "workspace_rename")) return .snapshot;
    return .workspace_upsert;
}

/// Drain owned RPC outcomes; results tagged `@manage` but superseded are dropped.
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.manage;
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        if (result.intent_id == null or !eq(result.intent_id.?, "@manage")) {
            try add(rpc.Result, tx.allocator(), &tx.state.rpc.results, result);
            continue;
        }
        tx.changed = true;
        if (s.directory_id != null and s.directory_id.? == result.id) {
            try listed(tx, result);
            continue;
        }
        if (s.models_id != null and s.models_id.? == result.id) {
            s.models_id = null;
            if (result.@"error") |e| s.models_error = e else s.models = result.value orelse .null;
            continue;
        }
        for (s.tasks, 0..) |t, i| if (t.rpc_id != null and t.rpc_id.? == result.id) {
            try step(tx, i, result);
            break;
        };
    }
}

fn listed(tx: *h.Transaction, result: rpc.Result) E!void {
    const s = &tx.state.manage;
    const id = s.directory_intent;
    s.directory_id = null;
    s.directory_intent = "";
    s.directory.loading = false;
    if (result.@"error") |e| {
        s.directory.@"error" = typed(e);
        return receipt(tx, id, "failed", s.directory.@"error");
    }
    const v = result.value orelse .null;
    const path = p.get(v, "path");
    const parent = p.get(v, "parent");
    if (path != .string or p.get(v, "directories") != .array or (parent != .null and parent != .string)) {
        s.directory.@"error" = failure("invalid_directory", "The folder list could not be read.");
        return receipt(tx, id, "failed", s.directory.@"error");
    }
    var entries: []const DirectoryEntry = &.{};
    for (p.rows(p.get(v, "directories"))) |row| {
        const name = p.s(row, "name");
        const child = p.s(row, "path");
        if (name.len == 0 or child.len == 0 or entries.len >= 4096) continue;
        try add(DirectoryEntry, tx.allocator(), &entries, .{ .name = name, .path = child });
    }
    s.directory.path = path.string;
    s.directory.parent = if (parent == .string) parent.string else null;
    s.directory.entries = entries;
    s.directory.@"error" = null;
    receipt(tx, id, "succeeded", null);
}

/// Daemon codes the UI acts on become the local error code as well.
fn typed(e: h.LocalError) h.LocalError {
    var out = e;
    const code = e.rpc_code orelse return out;
    inline for (.{ "workspace_busy", "workspace_archived", "conflict", "not_found", "invalid_params", "path_outside_roots", "invalid_state" }) |known_code| {
        if (eq(code, known_code)) out.code = known_code;
    }
    if (eq(code, "workspace_busy")) out.message = "Stop this workspace's running requests and tasks first.";
    if (eq(code, "workspace_archived")) out.message = "This workspace is closed. Reopen it first.";
    return out;
}

fn step(tx: *h.Transaction, i: usize, result: rpc.Result) E!void {
    const t = &tx.state.manage.tasks[i];
    t.rpc_id = null;
    if (result.@"error") |e| {
        const code = e.rpc_code orelse "";
        if (t.step == .workspace_upsert and eq(code, "conflict") and firstStep(t) == .snapshot and t.attempts < 2 and online(tx)) {
            // A concurrent edit moved the store revision: re-read and retry once more.
            t.attempts += 1;
            t.step = .snapshot;
            return advance(tx, i);
        }
        if (t.step == .thread_mutate and eq(t.job.kind, "thread_rename") and eq(code, "conflict") and t.attempts < 2 and online(tx)) {
            t.attempts += 1;
            t.step = .thread_get;
            return advance(tx, i);
        }
        t.job.busy = result.busy;
        return finish(tx, i, typed(e));
    }
    const v = result.value orelse .null;
    switch (t.step) {
        .register => {
            const client = p.s(v, "client_id");
            if (client.len == 0) return finish(tx, i, failure("invalid_client", "The host did not register this device."));
            tx.state.chat.client_id = client;
            t.step = firstStep(t);
            try advance(tx, i);
        },
        .snapshot => {
            var current: V = .null;
            const listed_rows = if (p.get(p.get(v, "snapshot"), "workspaces") == .array) p.get(p.get(v, "snapshot"), "workspaces") else p.get(v, "workspaces");
            for (p.rows(listed_rows)) |w| if (eq(p.s(w, "workspace_id"), t.job.workspace_id.?)) {
                current = w;
            };
            const revision = p.uint(p.get(v, "store_revision"));
            if (current != .object or revision == null) return finish(tx, i, failure("workspace_unavailable", "Workspace not found."));
            // Rewrite the complete shell metadata so layout and settings survive.
            var metadata: std.json.ObjectMap = .empty;
            var it = current.object.iterator();
            while (it.next()) |entry| {
                if (eq(entry.key_ptr.*, "threads") or eq(entry.key_ptr.*, "messages")) continue;
                try metadata.put(tx.allocator(), entry.key_ptr.*, entry.value_ptr.*);
            }
            if (t.label) |label| try metadata.put(tx.allocator(), "label", .{ .string = label });
            if (t.archived) |archived| try metadata.put(tx.allocator(), "archived", .{ .bool = archived });
            t.step = .workspace_upsert;
            t.rpc_id = try rpc.request(tx, "workspace.upsert", .{ .mutation = .{ .request_key = try requestKey(tx, t), .client_id = tx.state.chat.client_id.?, .expected_store_revision = revision.? }, .workspace = V{ .object = metadata } }, .{ .intent_id = "@manage" });
        },
        .thread_get => {
            const read = std.json.parseFromValueLeaky(store.ThreadGetResult, tx.allocator(), v, .{ .ignore_unknown_fields = true }) catch return finish(tx, i, failure("invalid_thread", "The host returned an unreadable chat."));
            if (!eq(read.thread.local_thread_id, t.job.thread_id.?)) return finish(tx, i, failure("invalid_thread", "The host returned a different chat."));
            t.thread = read.thread;
            t.revision = read.store_revision;
            if (t.label) |title| t.thread.?.title = title;
            t.step = .thread_mutate;
            try advance(tx, i);
        },
        .thread_mutate, .workspace_upsert, .close => {
            finish(tx, i, null);
            try sync.refresh(tx);
        },
        .thread_upsert => {
            try chat.adopt(tx, t.job.workspace_id.?, t.thread.?);
            finish(tx, i, null);
            try sync.refresh(tx);
        },
        .done => {},
    }
}

/// Pure `manage` selector.
pub fn query(a: A, state: *const h.State) E!V {
    const s = &state.manage;
    const jobs = try a.alloc(Job, s.tasks.len);
    for (s.tasks, jobs) |t, *job| job.* = t.job;
    const ready = state.lifecycle == .foreground and state.network_available and state.rpc.phase == .ready and state.rpc.bearer != null;
    var choices: []const m.Choice = &.{};
    for (providers) |item| try add(m.Choice, a, &choices, .{ .id = item[0], .label = item[1] });
    var new_chat: NewChat = .{ .selection = .{}, .catalogs = .{}, .providers = choices, .loading = s.models_id != null, .@"error" = s.models_error };
    if (s.chat_workspace) |ws_id| {
        const ws = workspace(state, ws_id);
        new_chat.workspace_id = ws_id;
        new_chat.selection = s.selection;
        new_chat.catalogs = try c.catalogs(a, s.selection, s.models, .null);
        new_chat.can_create = ready and scoped(state, "chat:write") and ws != .null and !p.yes(p.get(ws, "archived"));
    }
    var dir = s.directory;
    dir.suggestions = try suggestions(a, state);
    dir.supported = capable(state, "workspace.directory.v1");
    const view: View = .{
        .operations = jobs,
        .directory = dir,
        .new_chat = new_chat,
        .can_manage_workspaces = ready and scoped(state, "repository:write"),
        .can_create_threads = ready and scoped(state, "chat:write"),
    };
    return h.parseLimit(a, try h.encode(a, view), h.MAX_HTTP_INPUT);
}
