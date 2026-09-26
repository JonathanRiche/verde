//! Sans-IO chat engine. Owns transcript cursors, frozen sends and durable local follow-ups.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
pub const models = @import("chat_models.zig");
const m = models;
const c = @import("chat_catalogs.zig");
const store = @import("headless").store_protocol;
const apply = @import("verde_remote").transcript_apply;
const wire = @import("wire.zig");
const V = std.json.Value;
const E = h.ApiError;
const eq = h.eq;
const add = c.append;
const A = std.mem.Allocator;
const Kind = enum { page, legacy, tail, register, upsert, create, append, commit, start, cancel, approve, steer, shell, slash_list, slash_run, model_list, mentions, history };
const Request = struct { id: u64, thread: usize, kind: Kind, intent: []const u8 = "", cursor: ?[]const u8 = null, reconcile: bool = false, epoch: u64 = 0 };
const Send = struct { intent: []const u8, revision: u64, text: []const u8, inputs: []const wire.AttachmentInput, settings: store.Thread, turn_id: []const u8, message_id: []const u8, attachments: []const m.Attachment = &.{}, index: usize = 0, offset: usize = 0, chunk: usize = 0, sent_bytes: usize = 0, followup: bool = false };
const Saved = struct { version: u32 = 1, revision: u64 = 0, text: []const u8 = "", inputs: []const wire.AttachmentInput = &.{}, selection: m.Selection = .{}, followup: ?m.Followup = null, followup_inputs: []const wire.AttachmentInput = &.{}, followup_settings: ?store.Thread = null, route: []const u8 = "" };
pub const Thread = struct {
    workspace_id: []const u8,
    id: []const u8,
    metadata: store.Thread,
    cwd: []const u8,
    saved: Saved = .{},
    loaded: bool = false,
    edited: bool = false,
    dirty: bool = false,
    storage_id: ?[]const u8 = null,
    storage_revision: u64 = 0,
    storage_snapshot: ?Saved = null,
    storage_intents: []const []const u8 = &.{},
    rows: []const m.Row = &.{},
    overlay: []const m.Row = &.{},
    events: []const apply.ChatEvent = &.{},
    cursor: ?[]const u8 = null,
    seen_cursors: []const []const u8 = &.{},
    loading: bool = false,
    reconcile: bool = false,
    turn: ?m.Turn = null,
    approval: ?m.Approval = null,
    after_seq: u64 = 0,
    focused: bool = false,
    send: ?Send = null,
    send_intent: ?[]const u8 = null,
    followup_intent: []const u8 = "",
    followup_dispatch: bool = false,
    dynamic_models: V = .null,
    slash: V = .null,
    mentions: []const m.Mention = &.{},
    search_epoch: u64 = 0,
    catalog_epoch: u64 = 0,
    confirmation: ?m.ShellConfirmation = null,
    confirmation_route: []const u8 = "",
    retry_at: i64 = 0,
    @"error": ?h.LocalError = null,
};
pub const State = struct { threads: []Thread = &.{}, requests: []const Request = &.{}, client_id: ?[]const u8 = null, generation: u64 = 0, instance_id: ?[]const u8 = null, history: wire.HistoryView = .{ .query = "", .items = &.{}, .next_cursor = null, .loading = false, .@"error" = null }, history_epoch: u64 = 0, history_restarts: u8 = 0, history_workspace: []const u8 = "", history_cursors: []const []const u8 = &.{} };
fn value(a: A, item: anytype) E!V {
    return h.parseLimit(a, try h.encode(a, item), h.MAX_HTTP_INPUT);
}
fn decimal(a: A, n: u64) E![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}
fn err(code: []const u8) h.LocalError {
    return .{ .domain = "lifecycle", .code = code, .message = "Chat action could not be completed.", .retryable = true };
}
fn operation(tx: *h.Transaction, id: []const u8, state: []const u8, failure: ?h.LocalError) void {
    for (@constCast(tx.state.receipts)) |*receipt| if (eq(receipt.operation.intent_id, id)) {
        receipt.operation.state = state;
        receipt.operation.@"error" = failure;
    };
    tx.changed = true;
}
fn reject(tx: *h.Transaction, id: []const u8, code: []const u8) void {
    operation(tx, id, "failed", err(code));
}
fn online(tx: *h.Transaction) bool {
    return tx.state.lifecycle == .foreground and tx.state.network_available and tx.state.rpc.phase == .ready and tx.state.rpc.bearer != null and tx.state.rpc.spki_sha256 != null;
}
fn scope(tx: *h.Transaction, name: []const u8) bool {
    const credential = tx.state.auth.credential orelse return false;
    for (credential.scopes) |s| if (eq(s, name)) return true;
    return false;
}
fn terminal(status: []const u8) bool {
    return eq(status, "completed") or eq(status, "failed") or eq(status, "aborted") or eq(status, "interrupted");
}
fn activeStatus(status: []const u8) bool {
    return eq(status, "working") or eq(status, "waiting") or eq(status, "accepted") or eq(status, "running") or eq(status, "waiting_approval");
}
fn active(t: *const Thread) bool {
    return if (t.turn) |turn| activeStatus(turn.status) else false;
}
fn exists(tx: *h.Transaction, i: usize, kind: Kind) bool {
    for (tx.state.chat.requests) |r| if (r.thread == i and r.kind == kind) return true;
    return false;
}
fn call(tx: *h.Transaction, i: usize, kind: Kind, method: []const u8, params: anytype, mutation: bool, intent_id: []const u8) E!void {
    const wait: u32 = if (kind == .tail) @min(@as(u32, 25000), tx.state.rpc.limits.max_parked_wait_ms) else 0;
    const id = try rpc.request(tx, method, params, .{ .mutation = mutation, .intent_id = "@chat", .parked_wait_ms = wait });
    try add(Request, tx.allocator(), &tx.state.chat.requests, .{ .id = id, .thread = i, .kind = kind, .intent = intent_id, .epoch = if (kind == .history) tx.state.chat.history_epoch else if (kind == .mentions) tx.state.chat.threads[i].search_epoch else tx.state.chat.threads[i].catalog_epoch });
    if (intent_id.len > 0) operation(tx, intent_id, "pending", null);
}
fn route(a: A, t: *const Thread) E![]const u8 {
    return h.encode(a, .{ t.cwd, t.metadata.repository_id, t.metadata.repository_cwd, t.metadata.runtime_id, t.saved.selection.provider });
}
fn key(tx: *h.Transaction, t: *const Thread) E![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try h.encode(tx.allocator(), .{ t.workspace_id, t.id }), &digest, .{});
    return std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/chat/{s}", .{ tx.state.config.host_id, std.fmt.bytesToHex(digest, .lower) });
}
/// K-17: sign-out and the chat index derive record keys the same way.
pub fn recordKey(tx: *h.Transaction, t: *const Thread) E![]const u8 {
    return key(tx, t);
}
fn ensure(tx: *h.Transaction, ws: []const u8, id: []const u8) E!?usize {
    if (ws.len == 0 or id.len == 0) return null;
    for (tx.state.chat.threads, 0..) |t, i| if (eq(t.workspace_id, ws) and eq(t.id, id)) return i;
    var source: V = .null;
    var path: []const u8 = "";
    for (p.rows(p.get(p.get(tx.state.sync.snapshot, "snapshot"), "workspaces"))) |w| {
        if (!eq(p.s(w, "workspace_id"), ws)) continue;
        path = p.s(w, "path");
        for (p.rows(p.get(w, "threads"))) |t| if (eq(p.s(t, "local_thread_id"), id)) {
            source = t;
        };
    }
    for (tx.state.sync.catalog) |t| if (eq(p.s(t, "workspace_id"), ws) and eq(p.s(t, "local_thread_id"), id)) {
        source = t;
    };
    if (source == .null) return null;
    const meta = std.json.parseFromValueLeaky(store.Thread, tx.allocator(), source, .{ .ignore_unknown_fields = true }) catch |e| return h.mapError(e);
    if (meta.profile_id != null and !eq(meta.profile_id.?, "local")) return null;
    if (meta.runtime_id) |runtime| if (tx.state.rpc.runtime_id != null and !eq(runtime, tx.state.rpc.runtime_id.?)) return null;
    return try insert(tx, ws, id, meta, path);
}
/// D-10: a thread this client just created opens before sync lists it.
pub fn adopt(tx: *h.Transaction, ws: []const u8, meta: store.Thread) E!void {
    for (tx.state.chat.threads) |t| if (eq(t.workspace_id, ws) and eq(t.id, meta.local_thread_id)) return;
    // At the cap the created thread still opens once sync lists it.
    if (tx.state.chat.threads.len >= 128) return;
    var path: []const u8 = "";
    for (p.rows(p.get(p.get(tx.state.sync.snapshot, "snapshot"), "workspaces"))) |w| if (eq(p.s(w, "workspace_id"), ws)) {
        path = p.s(w, "path");
    };
    _ = try insert(tx, ws, meta.local_thread_id, meta, path);
}
fn insert(tx: *h.Transaction, ws: []const u8, id: []const u8, meta: store.Thread, path: []const u8) E!usize {
    if (tx.state.chat.threads.len >= 128) return error.ResourceLimit;
    const i = tx.state.chat.threads.len;
    const next = try tx.allocator().alloc(Thread, i + 1);
    @memcpy(next[0..i], tx.state.chat.threads);
    next[i] = .{ .workspace_id = ws, .id = id, .metadata = meta, .cwd = meta.cwd orelse path, .saved = .{ .selection = .{ .provider = meta.provider, .model = meta.model_ref, .effort = meta.reasoning_effort orelse meta.reasoning_variant, .access = meta.access_mode, .speed = meta.fast_mode } } };
    tx.state.chat.threads = next;
    const storage_key = try key(tx, &next[i]);
    const effect = try tx.emit("secure_store_get", .{ .key = storage_key });
    try tx.track(.store_get, effect, storage_key);
    next[i].storage_id = effect;
    return i;
}
fn persist(tx: *h.Transaction, i: usize) E!void {
    const t = &tx.state.chat.threads[i];
    t.dirty = true;
    if (!t.loaded or t.storage_id != null) return;
    const storage_key = try key(tx, t);
    const bytes = try h.encode(tx.allocator(), t.saved);
    if (bytes.len > h.MAX_INPUT / 2) return error.ResourceLimit;
    const effect = try tx.emit("secure_store_put", .{ .key = storage_key, .value_base64 = try rpc.encodeBase64(tx.allocator(), bytes) });
    try tx.track(.store_put, effect, storage_key);
    t.storage_id = effect;
    t.storage_snapshot = t.saved;
    t.storage_revision = t.saved.revision;
    t.dirty = false;
}
fn attachments(a: A, inputs: []const wire.AttachmentInput) E![]const m.Attachment {
    var out: []const m.Attachment = &.{};
    for (inputs) |input| try add(m.Attachment, a, &out, .{ .local_id = input.local_id, .name = input.name, .mime = input.mime, .byte_size = input.byte_size });
    return out;
}
fn page(tx: *h.Transaction, i: usize, older: bool, intent_id: []const u8) E!void {
    const t = &tx.state.chat.threads[i];
    if (t.loading) {
        if (intent_id.len > 0) reject(tx, intent_id, "page_pending");
        return;
    }
    if (older and t.cursor == null) {
        operation(tx, intent_id, "succeeded", null);
        return;
    }
    const limit = @min(@as(u32, 40), tx.state.rpc.limits.max_page_items);
    try call(tx, i, .page, "chat.message.list", .{ .workspace_id = t.workspace_id, .local_thread_id = t.id, .direction = "backward", .limit = limit, .cursor = if (older) t.cursor else null }, false, intent_id);
    const last = @constCast(&tx.state.chat.requests[tx.state.chat.requests.len - 1]);
    last.cursor = if (older) t.cursor else null;
    last.reconcile = t.reconcile and !older;
    t.loading = true;
}
fn tail(tx: *h.Transaction, i: usize) E!void {
    const t = &tx.state.chat.threads[i];
    if (t.turn == null or exists(tx, i, .tail)) return;
    try call(tx, i, .tail, "chat.turn.tail", .{ .turn_id = t.turn.?.turn_id, .after_seq = t.after_seq, .wait_ms = @min(@as(u32, 25000), tx.state.rpc.limits.max_parked_wait_ms), .max_bytes = tx.state.rpc.limits.max_response_bytes }, false, "");
}
fn metadata(t: *const Thread) store.Thread {
    var out = t.metadata;
    out.messages = &.{};
    out.message_offset = 0;
    out.draft = "";
    out.draft_images = &.{};
    out.draft_image = null;
    // Sending makes a draft chat visible to other clients, as the web does.
    out.committed = true;
    out.provider = t.saved.selection.provider orelse out.provider;
    out.model_ref = t.saved.selection.model;
    out.reasoning_effort = if (eq(out.provider, "cursor") or eq(out.provider, "opencode")) null else t.saved.selection.effort;
    out.reasoning_variant = if (eq(out.provider, "cursor") or eq(out.provider, "opencode")) t.saved.selection.effort else null;
    out.access_mode = t.saved.selection.access;
    out.fast_mode = t.saved.selection.speed;
    return out;
}
fn upsert(tx: *h.Transaction, i: usize) E!void {
    const t = &tx.state.chat.threads[i];
    const send = t.send orelse return;
    if (tx.state.chat.client_id == null) {
        try call(tx, i, .register, "daemon.client.register", .{ .persistent = false }, true, send.intent);
        return;
    }
    try call(tx, i, .upsert, "chat.thread.upsert", .{ .workspace_id = t.workspace_id, .thread = send.settings, .mutation = .{ .client_id = tx.state.chat.client_id.?, .request_key = send.turn_id } }, true, send.intent);
}
fn beginSend(tx: *h.Transaction, i: usize, intent_id: []const u8, followup: bool) E!void {
    const t = &tx.state.chat.threads[i];
    const a = tx.allocator();
    const turn_id = if (followup) t.saved.followup.?.next_turn_id else try std.fmt.allocPrint(a, "mobile:{s}:{d}", .{ tx.state.config.session_nonce, tx.state.next_id });
    const message_id = try std.fmt.allocPrint(a, "{s}:user", .{turn_id});
    t.send = .{ .intent = intent_id, .revision = t.saved.revision, .text = if (followup) t.saved.followup.?.text else if (std.mem.startsWith(u8, t.saved.text, "!!")) t.saved.text[1..] else t.saved.text, .inputs = if (followup) t.saved.followup_inputs else t.saved.inputs, .settings = if (followup) t.saved.followup_settings.? else metadata(t), .turn_id = turn_id, .message_id = message_id, .followup = followup };
    t.send_intent = intent_id;
    t.overlay = &.{};
    try add(m.Row, a, &t.overlay, .{ .id = message_id, .role = "user", .body = t.send.?.text, .delivery = "optimistic", .created_at_ms = tx.state.wall_time_ms, .attachments = try attachments(a, t.send.?.inputs) });
    try upsert(tx, i);
}
fn uploadNext(tx: *h.Transaction, i: usize) E!void {
    const t = &tx.state.chat.threads[i];
    const send = &t.send.?;
    if (send.index < send.inputs.len) {
        const input = send.inputs[send.index];
        const size = std.fmt.parseInt(u64, input.byte_size, 10) catch return error.InvalidArgument;
        try call(tx, i, .create, "chat.attachment.create", .{ .mime = input.mime, .byte_size = size }, true, send.intent);
    } else {
        var ids: []const []const u8 = &.{};
        for (send.attachments) |item| try add([]const u8, tx.allocator(), &ids, item.attachment_id.?);
        const meta = send.settings;
        var params = try value(tx.allocator(), .{ .turn_id = send.turn_id, .workspace_id = t.workspace_id, .local_thread_id = t.id, .message_id = send.message_id, .prompt = send.text, .thread_title = meta.title, .provider = meta.provider, .harness = meta.harness, .provider_thread_id = meta.provider_thread_id, .model_ref = meta.model_ref, .reasoning_effort = meta.reasoning_effort, .opencode_reasoning_variant = meta.reasoning_variant, .fast_mode = eq(meta.fast_mode orelse "off", "on"), .access_mode = meta.access_mode, .attachment_ids = ids });
        try addRoute(tx.allocator(), t, &params);
        try call(tx, i, .start, "chat.turn.start", params, true, send.intent);
    }
}
fn addRoute(a: A, t: *const Thread, params: *V) E!void {
    if (t.metadata.repository_id != null or t.metadata.repository_cwd != null) {
        try params.object.put(a, "repository_id", .{ .string = t.metadata.repository_id orelse "primary" });
        try params.object.put(a, "relative_cwd", if (t.metadata.repository_cwd) |v| .{ .string = v } else .null);
    } else try params.object.put(a, "project_path", .{ .string = t.cwd });
}
fn uploadChunk(tx: *h.Transaction, i: usize) E!void {
    const send = &tx.state.chat.threads[i].send.?;
    const input = send.inputs[send.index];
    const bytes = try @import("auth.zig").decode64(tx.allocator(), input.bytes_base64);
    const item = send.attachments[send.index];
    if (send.offset == bytes.len) {
        try call(tx, i, .commit, "chat.attachment.commit", .{ .attachment_id = item.attachment_id.? }, true, send.intent);
    } else {
        const end = @min(bytes.len, send.offset + send.chunk);
        send.sent_bytes = end - send.offset;
        try call(tx, i, .append, "chat.attachment.append", .{ .attachment_id = item.attachment_id.?, .offset = send.offset, .data = try rpc.encodeBase64(tx.allocator(), bytes[send.offset..end]) }, true, send.intent);
    }
}
/// Chat intents use the host's rolling receipt deduplication before entering here.
pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!bool {
    var owned = false;
    inline for (.{ "focus", "thread_open", "thread_load_older", "history_search", "history_load_more", "draft_set", "composer_select", "send", "turn_cancel", "followup_submit", "followup_retry", "followup_pull_back", "followup_cancel", "approval_decide", "shell_prepare", "shell_confirm", "slash_search", "slash_run", "mention_search" }) |name| {
        if (eq(tag, name)) owned = true;
    }
    if (!owned) return false;
    const id = p.s(event, "intent_id");
    if (eq(tag, "history_search") or eq(tag, "history_load_more")) {
        if (!online(tx) or !scope(tx, "chat:read")) {
            reject(tx, id, "unavailable");
            return true;
        }
        if (eq(tag, "history_search")) {
            tx.state.chat.history_epoch += 1;
            tx.state.chat.history_restarts = 0;
            tx.state.chat.history = .{ .query = p.s(event, "query"), .items = &.{}, .next_cursor = null, .loading = false, .@"error" = null };
            tx.state.chat.history_workspace = p.s(event, "workspace_id");
            tx.state.chat.history_cursors = &.{};
        } else if (tx.state.chat.history.loading or tx.state.chat.history.next_cursor == null) {
            reject(tx, id, "no_more_history");
            return true;
        }
        try historyPage(tx, id);
        return true;
    }
    if (eq(tag, "shell_confirm")) {
        for (tx.state.chat.threads, 0..) |*t, i| {
            const confirmation = t.confirmation orelse continue;
            if (!eq(confirmation.id, p.s(event, "confirmation_id"))) continue;
            t.confirmation = null;
            if (!p.yes(p.get(event, "accept"))) {
                operation(tx, id, "succeeded", null);
                return true;
            }
            if (!online(tx) or !scope(tx, "chat:write") or !scope(tx, "terminal:write") or !eq(t.confirmation_route, try route(tx.allocator(), t))) {
                reject(tx, id, "stale_confirmation");
                return true;
            }
            var params = try value(tx.allocator(), .{ .workspace_id = t.workspace_id, .local_thread_id = t.id, .command = confirmation.command, .confirmed = true });
            try addRoute(tx.allocator(), t, &params);
            try call(tx, i, .shell, "chat.shell.run", params, true, id);
            return true;
        }
        reject(tx, id, "stale_confirmation");
        return true;
    }
    if (eq(tag, "focus")) for (tx.state.chat.threads) |*t| {
        t.focused = false;
    };
    if (eq(tag, "focus") and p.get(event, "thread_id") == .null) {
        operation(tx, id, "succeeded", null);
        return false;
    }
    const i = (try ensure(tx, p.s(event, "workspace_id"), p.s(event, "thread_id"))) orelse {
        reject(tx, id, "thread_unavailable");
        return true;
    };
    const t = &tx.state.chat.threads[i];
    if (eq(tag, "draft_set")) {
        const inputs = try tx.allocator().dupe(wire.AttachmentInput, try h.decode([]const wire.AttachmentInput, tx.allocator(), p.get(event, "attachments")));
        for (inputs, 0..) |*input, n| {
            // Empty bytes keep this draft's attachment with the same ID and size, so the platform
            // never has to hold or resend bytes it cannot read back (restored or pulled-back drafts).
            if (input.bytes_base64.len == 0) for (t.saved.inputs) |old| {
                if (eq(old.local_id, input.local_id) and eq(old.byte_size, input.byte_size)) input.* = old;
            };
            const bytes = try @import("auth.zig").decode64(tx.allocator(), input.bytes_base64);
            const size = std.fmt.parseInt(u64, input.byte_size, 10) catch return error.InvalidArgument;
            if (size != bytes.len or size > tx.state.rpc.limits.max_attachment_bytes or size == 0 or input.local_id.len == 0 or !std.mem.startsWith(u8, input.mime, "image/")) return error.InvalidArgument;
            for (inputs[0..n]) |previous| if (eq(previous.local_id, input.local_id)) return error.InvalidArgument;
        }
        if (t.saved.revision == std.math.maxInt(u64)) return error.ResourceLimit;
        t.saved.revision += 1;
        t.saved.text = p.s(event, "text");
        t.saved.inputs = inputs;
        t.edited = true;
        try add([]const u8, tx.allocator(), &t.storage_intents, id);
        operation(tx, id, "pending", null);
        try persist(tx, i);
        return true;
    }
    if (eq(tag, "composer_select")) {
        var selection = try h.decode(m.Selection, tx.allocator(), event);
        if (selection.effort != null and selection.effort.?.len == 0) selection.effort = null;
        if (selection.provider == null) selection.provider = t.saved.selection.provider;
        const same_provider = eq(selection.provider orelse "", t.saved.selection.provider orelse "");
        const catalogs = try c.catalogs(tx.allocator(), selection, if (same_provider) t.dynamic_models else .null, .null);
        if (!c.contains(catalogs.models, selection.model) or catalogs.models.len == 0 or !c.contains(catalogs.efforts, selection.effort) or !c.contains(catalogs.access, selection.access) or !c.contains(catalogs.speeds, selection.speed)) {
            reject(tx, id, "invalid_selection");
            return true;
        }
        t.saved.selection = selection;
        t.saved.revision += 1;
        t.edited = true;
        t.catalog_epoch += 1;
        t.slash = .null;
        t.confirmation = null;
        if (!same_provider) t.dynamic_models = .null;
        try add([]const u8, tx.allocator(), &t.storage_intents, id);
        operation(tx, id, "pending", null);
        try persist(tx, i);
        return true;
    }
    if (!online(tx) or !scope(tx, "chat:read")) {
        reject(tx, id, "unavailable");
        return true;
    }
    if (eq(tag, "thread_open") or eq(tag, "focus")) {
        t.focused = true;
        t.retry_at = 0;
        if (!t.loaded and t.storage_id == null) {
            const storage_key = try key(tx, t);
            const effect = try tx.emit("secure_store_get", .{ .key = storage_key });
            try tx.track(.store_get, effect, storage_key);
            t.storage_id = effect;
        }
        try page(tx, i, false, id);
        if (scope(tx, "runtime:read") and !exists(tx, i, .model_list)) try call(tx, i, .model_list, "provider.models.list", .{ .provider = t.saved.selection.provider orelse t.metadata.provider, .project_path = t.cwd }, false, "");
        return true;
    }
    if (eq(tag, "thread_load_older")) {
        try page(tx, i, true, id);
        return true;
    }
    if (eq(tag, "slash_search")) {
        if (!scope(tx, "runtime:read")) {
            reject(tx, id, "insufficient_scope");
            return true;
        }
        try call(tx, i, .slash_list, "provider.slash.list", .{ .provider = t.saved.selection.provider orelse t.metadata.provider, .project_path = t.cwd }, false, id);
        return true;
    }
    if (eq(tag, "mention_search")) {
        if (!scope(tx, "repository:read")) {
            reject(tx, id, "insufficient_scope");
            return true;
        }
        t.search_epoch += 1;
        try call(tx, i, .mentions, "workspace.files.search", .{ .workspace_id = t.workspace_id, .repository_id = t.metadata.repository_id orelse "primary", .relative_cwd = t.metadata.repository_cwd, .query = p.s(event, "query"), .limit = @min(@as(u32, 20), tx.state.rpc.limits.max_page_items) }, false, id);
        return true;
    }
    if (!scope(tx, "chat:write")) {
        reject(tx, id, "insufficient_scope");
        return true;
    }
    if (eq(tag, "send") or eq(tag, "followup_submit")) {
        const revision = std.fmt.parseInt(u64, p.s(event, "draft_revision"), 10) catch return error.InvalidArgument;
        if (revision != t.saved.revision or !t.loaded or t.send != null or (t.saved.text.len == 0 and t.saved.inputs.len == 0)) {
            reject(tx, id, "draft_unavailable");
            return true;
        }
        if (eq(tag, "send")) {
            if (std.mem.startsWith(u8, t.saved.text, "!") and !std.mem.startsWith(u8, t.saved.text, "!!")) {
                if (!scope(tx, "terminal:write")) {
                    reject(tx, id, "insufficient_scope");
                    return true;
                }
                const command = std.mem.trim(u8, t.saved.text[1..], " \r\n\t");
                if (command.len == 0) {
                    reject(tx, id, "empty_command");
                    return true;
                }
                t.confirmation = .{ .id = try std.fmt.allocPrint(tx.allocator(), "confirm:{s}:{s}", .{ tx.state.config.session_nonce, id }), .command = command, .cwd = t.cwd };
                t.confirmation_route = try route(tx.allocator(), t);
                operation(tx, id, "succeeded", null);
                return true;
            }
            if (active(t)) {
                reject(tx, id, "turn_active");
                return true;
            }
            try beginSend(tx, i, id, false);
        } else {
            if (!active(t) or t.saved.followup != null) {
                reject(tx, id, "followup_unavailable");
                return true;
            }
            const fid = try std.fmt.allocPrint(tx.allocator(), "mobile-followup:{s}:{d}", .{ tx.state.config.session_nonce, tx.state.next_id });
            t.saved.followup = .{ .id = fid, .kind = if (t.saved.inputs.len > 0) "queue" else p.s(event, "kind"), .turn_id = t.turn.?.turn_id, .steer_id = fid, .next_turn_id = try std.fmt.allocPrint(tx.allocator(), "{s}:next", .{fid}), .text = t.saved.text, .attachments = try attachments(tx.allocator(), t.saved.inputs) };
            t.saved.followup_inputs = t.saved.inputs;
            t.saved.followup_settings = metadata(t);
            t.saved.route = try route(tx.allocator(), t);
            t.followup_intent = id;
            t.followup_dispatch = eq(t.saved.followup.?.kind, "steer");
            // Receipt owns the draft; actual clearing waits for its durable acknowledgement.
            try persist(tx, i);
            operation(tx, id, "pending", null);
        }
    } else if (eq(tag, "turn_cancel")) {
        if (!active(t) or !eq(t.turn.?.turn_id, p.s(event, "turn_id")) or t.turn.?.stop_pending) {
            reject(tx, id, "stale_turn");
            return true;
        }
        t.turn.?.stop_pending = true;
        try call(tx, i, .cancel, "chat.turn.cancel", .{ .turn_id = t.turn.?.turn_id }, true, id);
    } else if (eq(tag, "approval_decide")) {
        const approval = t.approval orelse {
            reject(tx, id, "stale_approval");
            return true;
        };
        if (!active(t) or !eq(approval.turn_id, p.s(event, "turn_id")) or !eq(approval.call_id, p.s(event, "call_id")) or eq(approval.resolution, "pending")) {
            reject(tx, id, "stale_approval");
            return true;
        }
        t.approval.?.resolution = "pending";
        try call(tx, i, .approve, "chat.turn.approve", .{ .turn_id = approval.turn_id, .call_id = approval.call_id, .decision = p.s(event, "decision") }, true, id);
    } else if (eq(tag, "shell_prepare")) {
        if (!scope(tx, "terminal:write")) {
            reject(tx, id, "insufficient_scope");
            return true;
        }
        const command = std.mem.trim(u8, p.s(event, "command"), " \r\n\t");
        if (command.len == 0) {
            reject(tx, id, "empty_command");
            return true;
        }
        t.confirmation = .{ .id = try std.fmt.allocPrint(tx.allocator(), "confirm:{s}:{s}", .{ tx.state.config.session_nonce, id }), .command = command, .cwd = t.cwd };
        t.confirmation_route = try route(tx.allocator(), t);
        operation(tx, id, "succeeded", null);
    } else if (eq(tag, "slash_run")) {
        const command = p.s(event, "command");
        const catalogs = try c.catalogs(tx.allocator(), t.saved.selection, t.dynamic_models, t.slash);
        if (!c.contains(catalogs.slash, command)) {
            reject(tx, id, "unknown_command");
            return true;
        }
        for (p.rows(p.get(t.slash, "commands"))) |row| if (eq(p.s(row, "id"), command) and p.yes(p.get(row, "requires_thread")) and t.metadata.provider_thread_id == null) {
            reject(tx, id, "provider_thread_required");
            return true;
        };
        try call(tx, i, .slash_run, "provider.slash.run", .{ .provider = t.saved.selection.provider orelse t.metadata.provider, .project_path = t.cwd, .thread_id = t.metadata.provider_thread_id, .command = command, .args = p.s(event, "args"), .raw_text = try std.fmt.allocPrint(tx.allocator(), "/{s} {s}", .{ command, p.s(event, "args") }) }, true, id);
    } else if (std.mem.startsWith(u8, tag, "followup_")) {
        const f = if (t.saved.followup) |*f| f else {
            reject(tx, id, "followup_unavailable");
            return true;
        };
        if (!eq(f.id, p.s(event, "followup_id"))) {
            reject(tx, id, "stale_followup");
            return true;
        }
        if (eq(tag, "followup_retry")) {
            if (eq(f.delivery, "sending") or eq(f.delivery, "accepted") or !eq(t.saved.route, try route(tx.allocator(), t))) {
                reject(tx, id, "followup_unavailable");
                return true;
            }
            t.followup_intent = id;
            if (eq(f.delivery, "uncertain")) {
                // Recovery reads evidence only, including after daemon restart.
                t.after_seq = 0;
                t.events = &.{};
                t.overlay = &.{};
                t.turn = .{ .turn_id = if (eq(f.kind, "steer") and eq(f.state, "pending")) f.turn_id else f.next_turn_id, .status = "running" };
                try tail(tx, i);
                operation(tx, id, "pending", null);
            } else {
                f.paused = false;
                t.followup_dispatch = true;
                try persist(tx, i);
                operation(tx, id, "pending", null);
            }
        } else {
            if (!eq(f.delivery, "unsent")) {
                reject(tx, id, "delivery_unconfirmed");
                return true;
            }
            if (eq(tag, "followup_pull_back")) {
                t.saved.text = if (t.saved.text.len == 0) f.text else try std.fmt.allocPrint(tx.allocator(), "{s}\n\n{s}", .{ t.saved.text, f.text });
                for (t.saved.followup_inputs) |input| try add(wire.AttachmentInput, tx.allocator(), &t.saved.inputs, input);
                t.saved.revision += 1;
            }
            t.saved.followup = null;
            t.saved.followup_inputs = &.{};
            t.saved.followup_settings = null;
            t.followup_dispatch = false;
            try add([]const u8, tx.allocator(), &t.storage_intents, id);
            operation(tx, id, "pending", null);
            try persist(tx, i);
        }
    } else return false;
    tx.changed = true;
    return true;
}
fn historyPage(tx: *h.Transaction, id: []const u8) E!void {
    const s = &tx.state.chat;
    // History does not use the thread index.
    const rpc_id = try rpc.request(tx, "chat.thread.list", .{ .workspace_id = s.history_workspace, .query = s.history.query, .recent_first = true, .limit = @min(@as(u32, 40), tx.state.rpc.limits.max_page_items), .cursor = s.history.next_cursor }, .{ .mutation = false, .intent_id = "@chat" });
    try add(Request, tx.allocator(), &s.requests, .{ .id = rpc_id, .thread = 0, .kind = .history, .intent = id, .epoch = s.history_epoch });
    s.history.loading = true;
    operation(tx, id, "pending", null);
}
/// Storage and retry timer completions are correlated by the host first.
pub fn complete(tx: *h.Transaction, pending: h.Pending, event: V) E!bool {
    if (pending.kind == .timer and eq(pending.purpose, "chat_retry")) return true;
    if (pending.kind != .store_get and pending.kind != .store_put) return false;
    for (tx.state.chat.threads, 0..) |*t, i| {
        if (t.storage_id == null or !eq(t.storage_id.?, pending.id)) continue;
        t.storage_id = null;
        tx.changed = true;
        if (p.get(event, "error") != .null) {
            t.@"error" = .{ .domain = "storage", .code = "chat_storage_failed", .message = "Draft or follow-up could not be saved.", .retryable = true };
            t.dirty = true;
            for (t.storage_intents) |id| operation(tx, id, "failed", t.@"error");
            operation(tx, t.followup_intent, "failed", t.@"error");
            t.followup_dispatch = false;
            if (t.saved.followup) |*f| f.paused = true;
            return true;
        }
        if (pending.kind == .store_get) {
            const encoded = p.get(event, "value_base64");
            if (encoded == .string) {
                const bytes = try @import("auth.zig").decode64(tx.allocator(), encoded.string);
                const saved = std.json.parseFromSliceLeaky(Saved, tx.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch |e| {
                    if (e == error.OutOfMemory) return error.OutOfMemory;
                    t.@"error" = err("invalid_saved_chat");
                    return true;
                };
                if (saved.version != 1 or (saved.followup != null and (!validFollowup(saved.followup.?) or saved.followup_settings == null))) {
                    t.@"error" = err("invalid_saved_chat");
                    return true;
                }
                if (!t.edited) t.saved = saved else {
                    t.saved.followup = saved.followup;
                    t.saved.followup_inputs = saved.followup_inputs;
                    t.saved.followup_settings = saved.followup_settings;
                    t.saved.route = saved.route;
                }
                if (t.saved.followup) |*f| {
                    f.paused = true;
                    if (eq(f.delivery, "sending")) f.delivery = "uncertain";
                    f.can_pull_back = eq(f.delivery, "unsent");
                    f.can_retry = !eq(f.delivery, "accepted");
                }
            }
            t.loaded = true;
            if (t.dirty) try persist(tx, i);
        } else {
            const written = t.storage_snapshot.?;
            t.storage_snapshot = null;
            if (!t.dirty) {
                for (t.storage_intents) |id| operation(tx, id, "succeeded", null);
                t.storage_intents = &.{};
            }
            if (written.followup) |f| {
                if (t.saved.followup != null and eq(t.saved.followup.?.id, f.id)) {
                    if (t.followup_intent.len > 0 and eq(f.delivery, "unsent")) {
                        if (t.saved.revision == written.revision and eq(t.saved.text, f.text)) {
                            t.saved.text = "";
                            t.saved.inputs = &.{};
                            t.saved.revision += 1;
                            t.dirty = true;
                        }
                        operation(tx, t.followup_intent, "succeeded", null);
                    }
                    // Only a durable sending receipt authorizes the mutation.
                    if (eq(f.delivery, "sending") and t.followup_dispatch and online(tx)) {
                        t.followup_dispatch = false;
                        if (eq(f.kind, "steer") and eq(f.state, "pending")) {
                            try call(tx, i, .steer, "chat.turn.steer", .{ .turn_id = f.turn_id, .steer_id = f.steer_id, .prompt = f.text, .image_paths = [_][]const u8{} }, true, t.followup_intent);
                        } else try beginSend(tx, i, t.followup_intent, true);
                    }
                }
            }
            if (t.dirty) try persist(tx, i);
        }
        return true;
    }
    return false;
}
fn summary(a: A, t: *const Thread, wall: i64) E!p.ThreadSummary {
    const timestamp = if (store.threadActivitySeconds(t.metadata.last_activity_at)) |n| std.math.mul(i64, n, 1000) catch null else null;
    const age = @as(i128, wall) - @as(i128, timestamp orelse 0);
    return .{ .workspace_id = try a.dupe(u8, t.workspace_id), .thread_id = t.id, .title = t.metadata.title, .provider = t.saved.selection.provider orelse t.metadata.provider, .model = t.saved.selection.model orelse t.metadata.model_ref, .cwd = t.cwd, .open = true, .archived = t.metadata.archived, .last_activity_at_ms = timestamp, .status = if (t.turn) |turn| turn.status else "idle", .history_bucket = if (age < 86400000) "Today" else if (age < 604800000) "This week" else "Older" };
}
fn messageRow(a: A, message: store.Message, fallback: []const u8, delivery: []const u8) E!m.Row {
    var images: []const m.Attachment = &.{};
    for (message.images) |image| try add(m.Attachment, a, &images, .{ .local_id = image.path, .name = image.path, .mime = image.mime, .byte_size = try decimal(a, image.byte_size), .reference = image.path, .status = "committed" });
    if (message.image) |image| if (images.len == 0) {
        try add(m.Attachment, a, &images, .{ .local_id = image.path, .name = image.path, .mime = image.mime, .byte_size = try decimal(a, image.byte_size), .reference = image.path, .status = "committed" });
    };
    return .{ .id = if (message.message_id.len > 0) message.message_id else fallback, .role = message.role, .author = message.author, .body = message.body, .delivery = delivery, .created_at_ms = message.created_at_ms, .attachments = images, .kind = if (message.tool_call_id != null) "tool" else "message", .tool = if (message.tool_call_id) |id| .{ .id = id, .kind = message.tool_call_kind orelse "unknown", .status = message.tool_call_status orelse "unknown" } else null };
}
fn receivePage(tx: *h.Transaction, request: Request, result: V) E!void {
    const t = &tx.state.chat.threads[request.thread];
    const source = if (request.kind == .legacy) p.get(result, "thread") else result;
    if (p.get(source, "messages") != .array) {
        t.@"error" = err("invalid_transcript");
        return;
    }
    var next: []const m.Row = &.{};
    for (p.rows(p.get(source, "messages")), 0..) |item, index| {
        const message = std.json.parseFromValueLeaky(store.Message, tx.allocator(), item, .{ .ignore_unknown_fields = true }) catch |e| return h.mapError(e);
        const id = try std.fmt.allocPrint(tx.allocator(), "legacy:{s}:{d}", .{ t.id, message.sort_index + index });
        const converted = try messageRow(tx.allocator(), message, id, "committed");
        var duplicate = false;
        for (next) |r| if (eq(r.id, converted.id)) {
            duplicate = true;
        };
        if (!duplicate) try add(m.Row, tx.allocator(), &next, converted);
    }
    // Fresh server rows replace matching IDs without reversing older history.
    var unmatched: []const m.Row = &.{};
    for (t.rows) |old| {
        var duplicate = false;
        for (next) |r| if (eq(r.id, old.id)) {
            duplicate = true;
        };
        if (!duplicate) try add(m.Row, tx.allocator(), &unmatched, old);
    }
    if (request.cursor != null) {
        for (unmatched) |old| try add(m.Row, tx.allocator(), &next, old);
    } else {
        for (next) |fresh| try add(m.Row, tx.allocator(), &unmatched, fresh);
        next = unmatched;
    }
    const cursor = p.get(result, "next_cursor");
    if (cursor != .null) {
        if (cursor != .string or cursor.string.len == 0) {
            t.@"error" = err("invalid_cursor");
            return;
        }
        if (request.cursor != null) for (t.seen_cursors) |seen| if (eq(seen, cursor.string)) {
            t.@"error" = err("repeated_cursor");
            return;
        };
        if (request.cursor == null) t.seen_cursors = &.{};
        try add([]const u8, tx.allocator(), &t.seen_cursors, cursor.string);
    }
    t.rows = next;
    t.cursor = if (cursor == .string) cursor.string else null;
    if (request.reconcile) {
        // Terminal publication is durable-first. Only clear after this read commits.
        t.overlay = &.{};
        t.events = &.{};
        t.reconcile = false;
    }
    if (t.retry_at != std.math.maxInt(i64)) t.@"error" = null;
}
fn approvalFromTurn(t: *Thread, value_: V) void {
    const approval = p.get(value_, "pending_approval");
    if (!active(t) or p.s(approval, "call_id").len == 0 or p.get(approval, "title") != .string or p.get(approval, "body") != .string) {
        t.approval = null;
        return;
    }
    const old = t.approval;
    t.approval = .{ .turn_id = t.turn.?.turn_id, .call_id = p.s(approval, "call_id"), .title = p.s(approval, "title"), .body = p.s(approval, "body") };
    if (old) |previous| if (eq(previous.turn_id, t.approval.?.turn_id) and eq(previous.call_id, t.approval.?.call_id)) {
        t.approval.?.resolution = previous.resolution;
        t.approval.?.@"error" = previous.@"error";
    };
}
fn receiveTail(tx: *h.Transaction, i: usize, result: V) E!void {
    const t = &tx.state.chat.threads[i];
    const status = p.s(result, "status");
    if ((!activeStatus(status) and !terminal(status)) or p.get(result, "events") != .array or t.turn == null) {
        t.@"error" = err("invalid_tail");
        t.retry_at = std.math.maxInt(i64);
        return;
    }
    if (p.uint(p.get(result, "events_compacted_before_seq"))) |before| if (before > t.after_seq) {
        t.events = &.{};
        t.overlay = &.{};
        t.after_seq = before;
        t.reconcile = true;
        if (!t.loading) try page(tx, i, false, "");
        return;
    };
    for (p.rows(p.get(result, "events"))) |event| {
        const seq = p.uint(p.get(event, "seq")) orelse {
            t.@"error" = err("invalid_tail_sequence");
            return;
        };
        if (seq <= t.after_seq) continue;
        if (seq != t.after_seq + 1) {
            t.@"error" = err("tail_sequence_gap");
            t.retry_at = std.math.maxInt(i64);
            return;
        }
        const kind = p.s(event, "kind");
        const payload = p.s(event, "payload_json");
        const decoded = h.parse(tx.allocator(), payload) catch |e| {
            if (e == error.OutOfMemory) return e;
            t.@"error" = err("invalid_tail_event");
            return;
        };
        if (eq(kind, "steer")) if (t.saved.followup) |*f| if (eq(f.steer_id, p.s(decoded, "steer_id"))) {
            f.state = "sent_inline";
            f.delivery = "accepted";
            f.can_pull_back = false;
            f.can_retry = false;
            operation(tx, t.followup_intent, "succeeded", null);
            try persist(tx, i);
        };
        // Keep unknown provider events readable rather than silently dropping them.
        const known = eq(kind, "assistant_delta") or eq(kind, "message") or eq(kind, "steer") or eq(kind, "tool_call") or eq(kind, "diff") or eq(kind, "completed") or eq(kind, "failed") or eq(kind, "aborted") or eq(kind, "thread_id") or eq(kind, "turn_id") or eq(kind, "approval") or eq(kind, "thread_title");
        try add(apply.ChatEvent, tx.allocator(), &t.events, .{ .kind = if (known) kind else "message", .payload_json = if (known) payload else try h.encode(tx.allocator(), .{ .title = kind, .body = if (p.s(decoded, "text").len > 0) p.s(decoded, "text") else payload }) });
        t.after_seq = seq;
    }
    t.turn.?.status = status;
    t.turn.?.after_seq = try decimal(tx.allocator(), t.after_seq);
    t.turn.?.started_at_ms = p.num(p.get(result, "started_at_ms"));
    if (p.get(result, "provider_thread_id") == .string) t.metadata.provider_thread_id = p.s(result, "provider_thread_id");
    approvalFromTurn(t, result);
    var overlay: []const m.Row = &.{};
    for (t.overlay) |r| if (eq(r.role, "user")) {
        try add(m.Row, tx.allocator(), &overlay, r);
    };
    if (overlay.len == 0 and p.get(result, "user_prompt") == .string) {
        try add(m.Row, tx.allocator(), &overlay, .{ .id = p.s(result, "user_message_id"), .role = "user", .body = p.s(result, "user_prompt"), .delivery = "streaming" });
    }
    const output = apply.apply(tx.allocator(), t.events, .{ .streaming = !terminal(status), .status = if (eq(status, "failed")) .failed else if (eq(status, "aborted") or eq(status, "interrupted")) .aborted else .completed, .provider = t.saved.selection.provider orelse t.metadata.provider, .reply_text = p.s(result, "result_reply_text"), .failure_message = if (p.get(result, "error_message") == .string) p.s(result, "error_message") else null }) catch |e| return h.mapError(e);
    for (output, 0..) |message, index| {
        const id = try std.fmt.allocPrint(tx.allocator(), "turn:{s}:msg:{d}", .{ t.turn.?.turn_id, index + 1 });
        try add(m.Row, tx.allocator(), &overlay, try messageRow(tx.allocator(), message, id, "streaming"));
    }
    t.overlay = overlay;
    t.@"error" = null;
    if (t.saved.followup) |*f| if (eq(f.next_turn_id, t.turn.?.turn_id)) {
        f.delivery = "accepted";
        f.can_pull_back = false;
        f.can_retry = false;
        operation(tx, t.followup_intent, "succeeded", null);
        try persist(tx, i);
    };
    if (terminal(status)) {
        t.turn.?.stop_pending = false;
        t.reconcile = true;
        if (!t.loading) try page(tx, i, false, "");
        if (t.saved.followup) |*f| if (eq(f.turn_id, t.turn.?.turn_id)) {
            if (eq(f.delivery, "accepted")) {
                t.saved.followup = null;
                t.saved.followup_inputs = &.{};
                try persist(tx, i);
            } else if (!eq(status, "completed")) {
                f.paused = true;
                try persist(tx, i);
            } else if (!f.paused and eq(f.delivery, "unsent") and (eq(f.kind, "queue") or eq(f.state, "fallback_next_turn"))) {
                t.followup_dispatch = true;
                try persist(tx, i);
            }
        };
    } else if (p.yes(p.get(result, "has_more_events"))) try tail(tx, i) else {
        t.retry_at = (tx.state.now_ms orelse 0) + 160;
        try tx.setTimer("chat_retry", 160);
    }
}
fn failed(tx: *h.Transaction, request: Request, failure: h.LocalError, fallback: bool) E!void {
    const t = &tx.state.chat.threads[request.thread];
    t.@"error" = failure;
    operation(tx, request.intent, if (eq(failure.delivery orelse "", "uncertain")) "uncertain" else "failed", failure);
    if (request.kind == .page or request.kind == .legacy) {
        t.loading = false;
        t.retry_at = if (failure.retryable) (tx.state.now_ms orelse 0) + 1000 else std.math.maxInt(i64);
        if (failure.retryable and online(tx)) try tx.setTimer("chat_retry", 1000);
        const code = failure.rpc_code orelse "";
        if (request.kind == .page and request.cursor == null and (eq(code, "unknown_method") or eq(code, "method_not_found"))) {
            t.loading = true;
            try call(tx, request.thread, .legacy, "chat.thread.get", .{ .workspace_id = t.workspace_id, .local_thread_id = t.id }, false, request.intent);
            @constCast(&tx.state.chat.requests[tx.state.chat.requests.len - 1]).reconcile = request.reconcile;
        } else if (eq(code, "revision_expired")) {
            t.cursor = null;
            t.seen_cursors = &.{};
            t.retry_at = (tx.state.now_ms orelse 0) + 1000;
            try tx.setTimer("chat_retry", 1000);
        }
    } else if (request.kind == .tail) {
        if (failure.retryable) {
            t.retry_at = (tx.state.now_ms orelse 0) + 1000;
            if (online(tx)) try tx.setTimer("chat_retry", 1000);
        } else {
            t.retry_at = std.math.maxInt(i64);
            t.reconcile = true;
            if (online(tx) and !t.loading) try page(tx, request.thread, false, "");
        }
        if (t.saved.followup) |f| if (eq(f.delivery, "uncertain")) operation(tx, t.followup_intent, "uncertain", failure);
    } else if (request.kind == .approve) {
        if (t.approval) |*approval| {
            approval.resolution = "failed";
            approval.@"error" = failure;
        }
        t.retry_at = 0;
    } else if (request.kind == .cancel) {
        // Uncertain cancellation remains pending until tail confirms terminal state.
        if (!eq(failure.delivery orelse "", "uncertain") and t.turn != null) t.turn.?.stop_pending = false;
    } else if (request.kind == .steer) {
        if (t.saved.followup) |*f| {
            if (fallback and !f.paused) {
                f.state = "fallback_next_turn";
                f.delivery = "unsent";
            } else {
                const code = failure.rpc_code orelse "";
                f.delivery = if (eq(code, "forbidden") or eq(code, "insufficient_scope") or eq(code, "invalid_params") or eq(code, "not_found")) "unsent" else "uncertain";
            }
            f.@"error" = failure;
            f.can_pull_back = eq(f.delivery, "unsent");
            f.can_retry = true;
            try persist(tx, request.thread);
        }
    } else if (t.send != null and (request.kind == .register or request.kind == .upsert or request.kind == .create or request.kind == .append or request.kind == .commit or request.kind == .start)) {
        if (t.send.?.followup) if (t.saved.followup) |*f| {
            f.delivery = if (eq(failure.delivery orelse "", "uncertain")) "uncertain" else "unsent";
            f.paused = true;
            f.can_pull_back = eq(f.delivery, "unsent");
            f.can_retry = true;
            f.@"error" = failure;
            try persist(tx, request.thread);
        };
        for (t.overlay) |*r| @constCast(r).delivery = "failed";
        t.send = null;
    }
}
fn receiveResult(tx: *h.Transaction, request: Request, result: V) E!void {
    const i = request.thread;
    const t = &tx.state.chat.threads[i];
    t.@"error" = null;
    switch (request.kind) {
        .page, .legacy => {
            t.loading = false;
            try receivePage(tx, request, result);
        },
        .tail => try receiveTail(tx, i, result),
        .register => {
            const id = p.s(result, "client_id");
            if (id.len == 0) return failed(tx, request, err("invalid_client"), false);
            tx.state.chat.client_id = id;
            try upsert(tx, i);
            return;
        },
        .upsert => {
            try uploadNext(tx, i);
            return;
        },
        .create => {
            const send = &t.send.?;
            const id = p.s(result, "attachment_id");
            const chunk = p.uint(p.get(result, "max_chunk_bytes")) orelse 0;
            if (id.len == 0 or chunk == 0) return failed(tx, request, err("invalid_upload"), false);
            const input = send.inputs[send.index];
            try add(m.Attachment, tx.allocator(), &send.attachments, .{ .local_id = input.local_id, .name = input.name, .mime = input.mime, .byte_size = input.byte_size, .attachment_id = id, .status = "uploading" });
            send.offset = 0;
            send.chunk = @min(@as(usize, @intCast(chunk)), @min(@as(usize, 48 * 1024), (tx.state.rpc.limits.max_request_bytes -| 2048) / 4 * 3));
            if (send.chunk == 0) return error.ResourceLimit;
            if (t.overlay.len > 0) @constCast(&t.overlay[0]).attachments = try sendAttachments(tx.allocator(), send.*);
            try uploadChunk(tx, i);
            return;
        },
        .append => {
            const send = &t.send.?;
            const received = p.uint(p.get(result, "received_bytes")) orelse return failed(tx, request, err("invalid_upload_offset"), false);
            if (received != send.offset + send.sent_bytes) return failed(tx, request, err("invalid_upload_offset"), false);
            send.offset = @intCast(received);
            @constCast(&send.attachments[send.index]).uploaded_bytes = try decimal(tx.allocator(), received);
            if (t.overlay.len > 0) @constCast(&t.overlay[0]).attachments = try sendAttachments(tx.allocator(), send.*);
            try uploadChunk(tx, i);
            return;
        },
        .commit => {
            const send = &t.send.?;
            @constCast(&send.attachments[send.index]).status = "uploaded";
            if (t.overlay.len > 0) @constCast(&t.overlay[0]).attachments = try sendAttachments(tx.allocator(), send.*);
            send.index += 1;
            try uploadNext(tx, i);
            return;
        },
        .start => {
            const send = t.send.?;
            if (!eq(p.s(result, "turn_id"), send.turn_id)) return failed(tx, request, rpc.failure(.protocol, "unconfirmed_turn", true), false);
            t.turn = .{ .turn_id = send.turn_id, .status = "running", .started_at_ms = tx.state.wall_time_ms };
            t.events = &.{};
            t.after_seq = 0;
            t.retry_at = 0;
            if (send.followup) {
                t.saved.followup = null;
                t.saved.followup_inputs = &.{};
                t.saved.followup_settings = null;
            } else if (t.saved.revision == send.revision) {
                t.saved.text = "";
                t.saved.inputs = &.{};
                t.saved.revision += 1;
            }
            t.send = null;
            try persist(tx, i);
            try tail(tx, i);
            if (!t.loading) try page(tx, i, false, "");
        },
        .steer => {
            if (!p.yes(p.get(result, "accepted"))) return failed(tx, request, rpc.failure(.protocol, "unconfirmed_steer", true), false);
            if (t.saved.followup) |*f| {
                f.delivery = "accepted";
                f.state = "sent_inline";
                f.can_retry = false;
                f.can_pull_back = false;
                try persist(tx, i);
            }
        },
        .cancel, .approve => {
            t.retry_at = 0;
        },
        .shell => {
            t.reconcile = true;
            if (!t.loading) try page(tx, i, false, "");
        },
        .slash_list => {
            if (request.epoch == t.catalog_epoch) t.slash = result;
        },
        .model_list => {
            if (request.epoch == t.catalog_epoch) t.dynamic_models = result;
        },
        .slash_run => {
            const body = if (p.get(result, "result") == .object) p.get(result, "result") else result;
            if (p.get(body, "handled") != .bool) return failed(tx, request, err("invalid_slash_result"), false);
            if (p.s(body, "transcript_body").len > 0) try add(m.Row, tx.allocator(), &t.rows, .{ .id = request.intent, .role = "system", .author = p.s(body, "transcript_title"), .body = p.s(body, "transcript_body") });
            if (p.s(body, "notice").len > 0) try add(m.Row, tx.allocator(), &t.rows, .{ .id = try std.fmt.allocPrint(tx.allocator(), "{s}:notice", .{request.intent}), .role = "system", .author = "Notice", .body = p.s(body, "notice") });
        },
        .mentions => {
            if (request.epoch == t.search_epoch) {
                t.mentions = &.{};
                for (p.rows(p.get(result, "files"))) |file| {
                    const path = if (file == .string) file.string else p.s(file, "path");
                    if (validMention(path)) try add(m.Mention, tx.allocator(), &t.mentions, .{ .path = path, .label = if (p.s(file, "file_name").len > 0) p.s(file, "file_name") else path });
                }
            }
        },
        .history => unreachable,
    }
    if (request.intent.len > 0) operation(tx, request.intent, if (t.@"error" == null) "succeeded" else "failed", t.@"error");
}
/// Drain only owned RPC outcomes, then schedule eligible reads and durable follow-ups.
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.chat;
    if (s.generation != tx.state.generation) {
        s.generation = tx.state.generation;
        s.client_id = null;
        for (s.threads) |*t| {
            t.confirmation = null;
            t.retry_at = 0;
            if (t.saved.followup) |*f| {
                f.paused = true;
                if (eq(f.delivery, "sending")) f.delivery = "uncertain";
            }
            t.followup_dispatch = false;
        }
    }
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        var owned: ?Request = null;
        for (s.requests, 0..) |request, index| if (request.id == result.id) {
            owned = request;
            const next = try tx.allocator().alloc(Request, s.requests.len - 1);
            @memcpy(next[0..index], s.requests[0..index]);
            @memcpy(next[index..], s.requests[index + 1 ..]);
            s.requests = next;
            break;
        };
        const request = owned orelse {
            try add(rpc.Result, tx.allocator(), &tx.state.rpc.results, result);
            continue;
        };
        tx.changed = true;
        if (request.kind == .history) {
            if (request.epoch != s.history_epoch) {
                operation(tx, request.intent, "succeeded", null);
                continue;
            }
            s.history.loading = false;
            if (result.@"error") |failure| {
                if (eq(failure.rpc_code orelse "", "revision_expired") and s.history_restarts < 3 and online(tx)) {
                    s.history_restarts += 1;
                    s.history.items = &.{};
                    s.history.next_cursor = null;
                    s.history_cursors = &.{};
                    try historyPage(tx, request.intent);
                    continue;
                }
                s.history.@"error" = failure;
                operation(tx, request.intent, "failed", failure);
                continue;
            }
            const v = result.value orelse .null;
            if (p.get(v, "threads") != .array) {
                s.history.@"error" = err("invalid_history");
                operation(tx, request.intent, "failed", s.history.@"error");
                continue;
            }
            for (p.rows(p.get(v, "threads"))) |item| {
                const meta = std.json.parseFromValueLeaky(store.Thread, tx.allocator(), item, .{ .ignore_unknown_fields = true }) catch |e| return h.mapError(e);
                const temp: Thread = .{ .workspace_id = p.s(item, "workspace_id"), .id = meta.local_thread_id, .metadata = meta, .cwd = meta.cwd orelse "" };
                var duplicate = false;
                for (s.history.items) |old| if (eq(old.workspace_id, temp.workspace_id) and eq(old.thread_id, temp.id)) {
                    duplicate = true;
                };
                if (!duplicate) {
                    var item_summary = try summary(tx.allocator(), &temp, tx.state.wall_time_ms);
                    item_summary.open = !(p.get(item, "open") == .bool and !p.yes(p.get(item, "open")));
                    try add(p.ThreadSummary, tx.allocator(), &s.history.items, item_summary);
                }
            }
            const cursor = p.get(v, "next_cursor");
            if (cursor != .null and (cursor != .string or cursor.string.len == 0)) {
                s.history.@"error" = err("invalid_cursor");
                operation(tx, request.intent, "failed", s.history.@"error");
                continue;
            }
            var repeated = false;
            if (cursor == .string) for (s.history_cursors) |seen| if (eq(seen, cursor.string)) {
                repeated = true;
            };
            if (repeated) {
                s.history.@"error" = err("repeated_cursor");
                s.history.next_cursor = null;
            } else {
                s.history.next_cursor = if (cursor == .string) cursor.string else null;
                if (s.history.next_cursor) |next| try add([]const u8, tx.allocator(), &s.history_cursors, next);
            }
            operation(tx, request.intent, if (s.history.@"error" == null) "succeeded" else "failed", s.history.@"error");
            continue;
        }
        if (result.@"error") |failure| try failed(tx, request, failure, result.steer_can_fallback) else try receiveResult(tx, request, result.value orelse .null);
    }
    if (!online(tx)) return;
    if (tx.state.rpc.instance_id) |instance| {
        if (s.instance_id != null and !eq(s.instance_id.?, instance)) {
            for (s.threads) |*t| {
                t.events = &.{};
                t.overlay = &.{};
                t.after_seq = 0;
                if (t.turn) |*turn| turn.after_seq = "0";
                t.reconcile = true;
                t.retry_at = 0;
            }
        }
        s.instance_id = instance;
    }
    for (s.threads, 0..) |*t, i| {
        for (tx.state.sync.catalog) |item| {
            if (!eq(p.s(item, "workspace_id"), t.workspace_id) or !eq(p.s(item, "local_thread_id"), t.id)) continue;
            const latest = std.json.parseFromValueLeaky(store.Thread, tx.allocator(), item, .{ .ignore_unknown_fields = true }) catch |e| return h.mapError(e);
            if (!eq(latest.cwd orelse "", t.metadata.cwd orelse "") or !eq(latest.repository_id orelse "", t.metadata.repository_id orelse "") or !eq(latest.repository_cwd orelse "", t.metadata.repository_cwd orelse "")) {
                t.confirmation = null;
                if (t.saved.followup) |*f| f.paused = true;
                t.metadata = latest;
                t.cwd = latest.cwd orelse t.cwd;
            }
        }
        if (t.turn == null) for (p.rows(p.get(tx.state.sync.snapshot, "turns"))) |turn| {
            if (!eq(p.s(turn, "workspace_id"), t.workspace_id) or !eq(p.s(turn, "local_thread_id"), t.id) or !activeStatus(p.s(turn, "status")) or p.s(turn, "turn_id").len == 0) continue;
            t.turn = .{ .turn_id = p.s(turn, "turn_id"), .status = p.s(turn, "status"), .started_at_ms = p.num(p.get(turn, "started_at_ms")) };
            approvalFromTurn(t, turn);
        };
        if (t.followup_dispatch and t.storage_id == null and t.loaded and t.saved.followup != null) {
            const f = &t.saved.followup.?;
            const eligible = (eq(f.kind, "steer") and eq(f.state, "pending") and active(t)) or (!active(t) and t.turn != null and eq(t.turn.?.status, "completed"));
            if (eligible and !f.paused and eq(f.delivery, "unsent") and eq(t.saved.route, try route(tx.allocator(), t))) {
                f.delivery = "sending";
                f.can_pull_back = false;
                f.can_retry = false;
                try persist(tx, i);
            }
        }
        if (t.retry_at > (tx.state.now_ms orelse 0)) continue;
        if (t.reconcile and !t.loading) try page(tx, i, false, "") else if (active(t) and (t.focused or t.saved.followup != null or t.send_intent != null) and !t.reconcile) try tail(tx, i);
    }
}
/// Receipts chat will still update (queued follow-up, send, unacked storage or
/// open requests) must survive host receipt eviction even while shown settled.
pub fn holdsIntent(state: *const State, id: []const u8) bool {
    for (state.requests) |request| if (eq(request.intent, id)) return true;
    for (state.threads) |t| {
        if (t.saved.followup != null and eq(t.followup_intent, id)) return true;
        if (t.send_intent) |intent_id| if (eq(intent_id, id)) return true;
        if (t.send) |send| if (eq(send.intent, id)) return true;
        for (t.storage_intents) |intent_id| if (eq(intent_id, id)) return true;
    }
    return false;
}
/// Pure query using the revision-1 workspace-qualified identity.
pub fn query(a: A, state: *const h.State, selector: []const u8) E!?V {
    const composer = std.mem.startsWith(u8, selector, "composer:");
    const suffix = if (composer) selector[9..] else if (std.mem.startsWith(u8, selector, "thread:")) selector[7..] else return null;
    const decoded = std.Uri.percentDecodeInPlace(try a.dupe(u8, suffix));
    const identity = h.parse(a, decoded) catch |e| {
        if (e == error.OutOfMemory) return e;
        return null;
    };
    if (identity != .array or identity.array.items.len != 2 or identity.array.items[0] != .string or identity.array.items[1] != .string) return null;
    var selected: ?*const Thread = null;
    for (state.chat.threads) |*t| {
        if (eq(identity.array.items[0].string, t.workspace_id) and eq(identity.array.items[1].string, t.id)) selected = t;
    }
    const t = selected orelse return null;
    if (composer) {
        var op: ?h.Operation = null;
        if (t.send_intent) |intent_id| for (state.receipts) |receipt| if (eq(receipt.operation.intent_id, intent_id)) {
            op = receipt.operation;
        };
        var followup = t.saved.followup;
        if (followup) |*f| {
            f.can_pull_back = eq(f.delivery, "unsent");
            f.can_retry = !eq(f.delivery, "sending") and !eq(f.delivery, "accepted");
        }
        var can_write = false;
        if (state.auth.credential) |credential| for (credential.scopes) |s| if (eq(s, "chat:write")) {
            can_write = true;
        };
        return try value(a, m.ComposerView{ .draft = .{ .revision = try decimal(a, t.saved.revision), .text = t.saved.text, .attachments = if (t.send != null and t.send.?.revision == t.saved.revision) try sendAttachments(a, t.send.?) else try attachments(a, t.saved.inputs), .persisted = t.loaded and !t.dirty and t.storage_id == null }, .selection = t.saved.selection, .catalogs = try c.favorites(a, try c.catalogs(a, t.saved.selection, t.dynamic_models, t.slash), t.saved.selection.provider orelse t.metadata.provider, p.get(state.sync.snapshot, "config")), .mentions = t.mentions, .provider_ready = state.rpc.phase == .ready, .can_send = can_write and state.rpc.bearer != null and state.rpc.phase == .ready and state.lifecycle == .foreground and t.loaded and t.send == null and !active(t), .can_stop = can_write and active(t) and !t.turn.?.stop_pending, .send_operation = op, .followup = followup, .shell_confirmation = t.confirmation, .@"error" = t.@"error" });
    }
    var rows = t.rows;
    for (t.overlay) |overlay| {
        var duplicate = false;
        for (rows) |r| if (eq(r.id, overlay.id)) {
            duplicate = true;
        };
        if (!duplicate) try add(m.Row, a, &rows, overlay);
    }
    var usage_: ?m.Usage = null;
    for (rows) |r| if (eq(r.role, "system")) {
        if (try c.usage(a, r.author, r.body)) |u| usage_ = u;
    };
    var turn = t.turn;
    if (turn) |*v| if (v.started_at_ms) |start| {
        v.elapsed_ms = @intCast(@max(0, @min(std.math.maxInt(i64), @as(i128, state.wall_time_ms) - start)));
    };
    return try value(a, m.ThreadView{ .thread = try summary(a, t, state.wall_time_ms), .rows = rows, .page = .{ .has_older = t.cursor != null, .cursor = t.cursor, .loading = t.loading }, .turn = turn, .approval = t.approval, .usage = usage_, .stale = state.stale, .@"error" = t.@"error" });
}
/// Include precise chat selectors in the coalesced host notification.
pub fn scopes(tx: *h.Transaction) E![]const []const u8 {
    // `hosts`/`operations` are diffed separately by the host commit.
    var out: []const []const u8 = &.{ "home", "workspaces" };
    for (tx.state.chat.threads) |t| {
        try add([]const u8, tx.allocator(), &out, try selectorFor(tx.allocator(), "thread", t.workspace_id, t.id));
        try add([]const u8, tx.allocator(), &out, try selectorFor(tx.allocator(), "composer", t.workspace_id, t.id));
    }
    return out;
}

/// Encode the revision-1 workspace-qualified thread identity exactly once.
pub fn selectorFor(a: A, prefix: []const u8, workspace: []const u8, thread: []const u8) E![]const u8 {
    const json = try h.encode(a, .{ workspace, thread });
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, prefix);
    try out.append(a, ':');
    const hex = "0123456789ABCDEF";
    for (json) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try out.append(a, byte) else try out.appendSlice(a, &.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
    return out.toOwnedSlice(a);
}

fn sendAttachments(a: A, send: Send) E![]const m.Attachment {
    const out = @constCast(try attachments(a, send.inputs));
    for (send.attachments, 0..) |item, i| out[i] = item;
    return out;
}

fn validMention(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\r\n\x00\\") != null or (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':')) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or eq(part, "..")) return false;
    return true;
}

fn validFollowup(f: m.Followup) bool {
    return f.id.len > 0 and f.turn_id.len > 0 and f.steer_id.len > 0 and f.next_turn_id.len > 0 and
        (eq(f.kind, "queue") or eq(f.kind, "steer")) and
        (eq(f.state, "pending") or eq(f.state, "sent_inline") or eq(f.state, "fallback_next_turn")) and
        (eq(f.delivery, "unsent") or eq(f.delivery, "sending") or eq(f.delivery, "uncertain") or eq(f.delivery, "accepted"));
}
