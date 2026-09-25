//! K-17 per-thread attention, ported from web `notify.ts`
//! (`advanceAttention` + `notificationStatus`).
//!
//! Observations come from the sync snapshot's `turns` scope, overridden by the
//! chat engine's live turn/approval for loaded threads, plus forwarded pushes
//! (`push_received`). Existing threads seed silently; only observed work
//! transitions raise attention, and never for the focused (viewed) thread.
//! Entries persist in `vc/1/<host_id>/attention` so unread survives restarts.
const std = @import("std");
const h = @import("host.zig");
const p = @import("projection.zig");
const push = @import("push.zig");
const rpc = h.rpc;
const A = std.mem.Allocator;
const V = std.json.Value;
const E = h.ApiError;
const eq = h.eq;

pub const RECORD = "attention";
pub const MAX_ENTRIES = 1024;
const MAX_NOTIFIED = 64;

pub const Kind = enum { unread, needs_approval, blocked, failed };
pub const Status = enum { idle, working, done, waiting, @"error" };
pub const Entry = struct {
    workspace_id: []const u8,
    thread_id: []const u8,
    turn_id: []const u8 = "",
    status: Status = .idle,
    attention: ?Kind = null,
    since_ms: i64 = 0,
};
const Record = struct { version: u32 = 1, entries: []const Entry = &.{} };
pub const State = struct {
    entries: []const Entry = &.{},
    loaded: bool = false,
    load_id: ?[]const u8 = null,
    save_id: ?[]const u8 = null,
    dirty: bool = false,
    focus_workspace: []const u8 = "",
    focus_thread: []const u8 = "",
    notified: []const []const u8 = &.{},
};

/// `attention` selector item; `kind` is the attention kind.
pub const Item = struct { workspace_id: []const u8, thread_id: []const u8, turn_id: ?[]const u8, kind: Kind, status: Status, since_ms: i64, title: []const u8, deep_link: []const u8 };
pub const View = struct { items: []const Item, count: u32, loading: bool };

fn append(comptime T: type, a: A, slice: *[]const T, item: T) E!void {
    const next = try a.alloc(T, slice.len + 1);
    @memcpy(next[0..slice.len], slice.*);
    next[slice.len] = item;
    slice.* = next;
}
pub fn recordKey(tx: *h.Transaction) E![]const u8 {
    return std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/" ++ RECORD, .{tx.state.config.host_id});
}

/// Web `notificationStatus`: approval → waiting, failed → error,
/// aborted → idle, active → working, anything else (including no turn) → done.
pub fn notificationStatus(turn_status: []const u8, approval: bool) Status {
    if (approval or eq(turn_status, "waiting_approval")) return .waiting;
    if (eq(turn_status, "failed") or eq(turn_status, "interrupted")) return .@"error";
    if (eq(turn_status, "aborted")) return .idle;
    for ([_][]const u8{ "working", "running", "accepted", "waiting" }) |s| if (eq(turn_status, s)) return .working;
    return .done;
}
fn kindFor(status: Status) Kind {
    return switch (status) {
        .waiting => .needs_approval,
        .@"error" => .failed,
        else => .unread,
    };
}
fn pushKind(kind: Kind) []const u8 {
    return switch (kind) {
        .unread => "completed",
        .needs_approval => "approval_pending",
        .blocked => "input_needed",
        .failed => "failed",
    };
}

/// Pure transition for one thread (web `advanceAttention` rules plus a new
/// turn id arriving already settled counting as work observed).
pub fn advance(before: ?Entry, observed: Entry, focused: bool) struct { entry: Entry, raised: bool } {
    var next = observed;
    next.attention = if (before) |b| b.attention else null;
    next.since_ms = if (before) |b| b.since_ms else observed.since_ms;
    const previous: ?Status = if (before) |b| blk: {
        const new_turn = observed.turn_id.len > 0 and !eq(observed.turn_id, b.turn_id);
        break :blk if (new_turn and observed.status != .working and observed.status != .idle) .working else b.status;
    } else null;
    const keep_blocked = next.attention == .blocked and observed.status == .working and before != null and eq(before.?.turn_id, observed.turn_id);
    if (focused or ((observed.status == .working or observed.status == .idle) and !keep_blocked)) next.attention = null;
    const needs = if (previous) |b| (b == .working and (observed.status == .done or observed.status == .waiting or observed.status == .@"error")) or
        (b == .waiting and (observed.status == .done or observed.status == .@"error")) else false;
    if (needs and !focused) {
        next.attention = kindFor(observed.status);
        next.since_ms = observed.since_ms;
        return .{ .entry = next, .raised = true };
    }
    return .{ .entry = next, .raised = false };
}

fn focusedOn(tx: *h.Transaction, ws: []const u8, thread: []const u8) bool {
    const s = &tx.state.attention;
    return tx.state.lifecycle == .foreground and s.focus_thread.len > 0 and eq(s.focus_workspace, ws) and eq(s.focus_thread, thread);
}
fn find(entries: []const Entry, ws: []const u8, thread: []const u8) ?usize {
    for (entries, 0..) |e, i| if (eq(e.workspace_id, ws) and eq(e.thread_id, thread)) return i;
    return null;
}
fn same(x: Entry, y: Entry) bool {
    return eq(x.turn_id, y.turn_id) and x.status == y.status and x.attention == y.attention and x.since_ms == y.since_ms;
}

const Thread = struct { workspace_id: []const u8, thread: V, label: []const u8 };
/// Threads as the projection lists them: catalog when present, else snapshot.
fn threads(a: A, state: *const h.State) E![]const Thread {
    var out: std.ArrayList(Thread) = .empty;
    for (p.rows(p.get(p.get(state.sync.snapshot, "snapshot"), "workspaces"))) |ws| {
        const wid = p.s(ws, "workspace_id");
        const label = if (p.s(ws, "label").len > 0) p.s(ws, "label") else wid;
        if (state.sync.has_catalog) {
            for (state.sync.catalog) |t| if (eq(p.s(t, "workspace_id"), wid)) try out.append(a, .{ .workspace_id = wid, .thread = t, .label = label });
        } else for (p.rows(p.get(ws, "threads"))) |t| try out.append(a, .{ .workspace_id = wid, .thread = t, .label = label });
    }
    return out.items;
}
/// Advance only on a complete view of workspaces and turns.
fn observable(state: *const h.State) bool {
    const snap = state.sync.snapshot;
    if (p.get(snap, "turns") != .array or p.get(p.get(snap, "snapshot"), "workspaces") != .array) return false;
    for (p.rows(p.get(snap, "incomplete_scopes"))) |scope| if (scope == .string and (eq(scope.string, "turns") or eq(scope.string, "workspaces"))) return false;
    return true;
}

fn observe(tx: *h.Transaction, ws: []const u8, thread_id: []const u8) Entry {
    var turn_id: []const u8 = "";
    var status: []const u8 = "";
    var started: i64 = std.math.minInt(i64);
    for (p.rows(p.get(tx.state.sync.snapshot, "turns"))) |turn| {
        if (!eq(p.s(turn, "workspace_id"), ws) or !eq(p.s(turn, "local_thread_id"), thread_id)) continue;
        const at = p.num(p.get(turn, "started_at_ms")) orelse 0;
        if (turn_id.len > 0 and at <= started) continue;
        started = at;
        turn_id = p.s(turn, "turn_id");
        status = p.s(turn, "status");
    }
    var approval = false;
    for (tx.state.chat.threads) |t| {
        if (!eq(t.workspace_id, ws) or !eq(t.id, thread_id)) continue;
        const live = t.turn orelse break;
        // The engine's tail usually leads sync for its own turn, but an idle
        // or stalled tail must not mask a turn sync already saw settle, nor a
        // newer turn started elsewhere.
        const same_turn = eq(live.turn_id, turn_id);
        const settled_by_sync = same_turn and notificationStatus(status, false) != .working and notificationStatus(live.status, false) == .working;
        const later = if (live.started_at_ms) |at| at > started else false;
        if (turn_id.len == 0 or (same_turn and !settled_by_sync) or (!same_turn and later)) {
            turn_id = live.turn_id;
            status = live.status;
            approval = if (t.approval) |pending| eq(pending.turn_id, live.turn_id) else false;
        }
        break;
    }
    return .{ .workspace_id = ws, .thread_id = thread_id, .turn_id = turn_id, .status = notificationStatus(status, approval), .since_ms = tx.state.wall_time_ms };
}

pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.attention;
    if (tx.state.auth.removal.wiping or tx.state.lifecycle == .stopped) return;
    if (!s.loaded) {
        if (s.load_id == null and tx.state.sync.snapshot != .null) {
            const key = try recordKey(tx);
            const id = try tx.emit("secure_store_get", .{ .key = key });
            try tx.track(.store_get, id, key);
            s.load_id = id;
        }
        return;
    }
    // Returning to the foreground on a focused thread counts as viewing it.
    clearFocused(tx);
    if (observable(&tx.state)) try step(tx);
    if (s.dirty and s.save_id == null) try save(tx);
}

fn step(tx: *h.Transaction) E!void {
    const a = tx.allocator();
    const s = &tx.state.attention;
    var next: std.ArrayList(Entry) = .empty;
    var changed = false;
    for (try threads(a, &tx.state)) |t| {
        const thread_id = p.s(t.thread, "local_thread_id");
        if (thread_id.len == 0 or find(next.items, t.workspace_id, thread_id) != null) continue;
        const before_index = find(s.entries, t.workspace_id, thread_id);
        if (before_index == null and next.items.len >= MAX_ENTRIES) continue;
        const before: ?Entry = if (before_index) |i| s.entries[i] else null;
        var observed = observe(tx, t.workspace_id, thread_id);
        // A consumed turn leaves the snapshot; keep attributing to the last turn.
        if (observed.turn_id.len == 0 and before != null) observed.turn_id = before.?.turn_id;
        const result = advance(before, observed, focusedOn(tx, t.workspace_id, thread_id));
        try next.append(a, result.entry);
        if (before == null or !same(before.?, result.entry)) changed = true;
        if (result.raised) try notify(tx, result.entry, t);
    }
    if (next.items.len != s.entries.len) changed = true;
    if (!changed) return;
    s.entries = next.items;
    s.dirty = true;
    tx.changed = true;
}

fn notify(tx: *h.Transaction, entry: Entry, t: Thread) E!void {
    const a = tx.allocator();
    const kind = entry.attention orelse return;
    const s = &tx.state.attention;
    const host_id = tx.state.config.host_id;
    const id = try push.dedupeKey(a, host_id, entry.turn_id, pushKind(kind));
    for (s.notified) |seen| if (eq(seen, id)) return;
    try remember(tx, id);
    const title = p.s(t.thread, "title");
    // Web `notificationBody`.
    const body = switch (kind) {
        .needs_approval => "Needs approval",
        .failed => "Turn failed",
        .blocked => "Needs input",
        .unread => try std.fmt.allocPrint(a, "Reply ready in {s}", .{t.label}),
    };
    const actions: []const []const u8 = switch (kind) {
        .unread, .blocked => &.{ "open", "reply" },
        .needs_approval => &.{ "open", "approve", "deny" },
        .failed => &.{"open"},
    };
    _ = try tx.emit("notify", .{ .notification_id = id, .kind = pushKind(kind), .title = if (title.len > 0) title else push.GENERIC_TITLE, .body = body, .target = .{ .host_id = host_id, .workspace_id = entry.workspace_id, .thread_id = entry.thread_id }, .actions = actions });
}
fn remember(tx: *h.Transaction, id: []const u8) E!void {
    const s = &tx.state.attention;
    if (s.notified.len >= MAX_NOTIFIED) s.notified = s.notified[s.notified.len - MAX_NOTIFIED + 1 ..];
    try append([]const u8, tx.allocator(), &s.notified, id);
}

fn save(tx: *h.Transaction) E!void {
    const s = &tx.state.attention;
    const key = try recordKey(tx);
    const bytes = try h.encode(tx.allocator(), Record{ .entries = s.entries });
    const id = try tx.emit("secure_store_put", .{ .key = key, .value_base64 = try rpc.encodeBase64(tx.allocator(), bytes) });
    try tx.track(.store_put, id, key);
    s.save_id = id;
    s.dirty = false;
}

pub fn complete(tx: *h.Transaction, pending: h.Pending, event: V) E!bool {
    const s = &tx.state.attention;
    if (s.save_id != null and eq(s.save_id.?, pending.id)) {
        s.save_id = null;
        // A failed write is retried with the next change; attention stays in memory.
        if ((try h.field(event, "error")) != .null) s.dirty = true;
        return true;
    }
    if (s.load_id == null or !eq(s.load_id.?, pending.id)) return false;
    s.load_id = null;
    s.loaded = true;
    tx.changed = true;
    const stored = try h.field(event, "value_base64");
    if ((try h.field(event, "error")) != .null or stored != .string) return true;
    const a = tx.allocator();
    const bytes = @import("auth.zig").decode64(a, stored.string) catch return true;
    const record = std.json.parseFromSliceLeaky(Record, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return true;
    };
    if (record.version != 1) return true;
    // Pushes received while loading are newer than the stored copy.
    var merged: std.ArrayList(Entry) = .empty;
    try merged.appendSlice(a, s.entries);
    for (record.entries) |e| {
        if (merged.items.len >= MAX_ENTRIES) break;
        if (e.workspace_id.len == 0 or e.thread_id.len == 0 or find(merged.items, e.workspace_id, e.thread_id) != null) continue;
        try merged.append(a, e);
    }
    s.entries = merged.items;
    return true;
}

/// Observes `focus`/`thread_open`; viewing a thread clears its attention.
pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!void {
    if (!eq(tag, "focus") and !eq(tag, "thread_open")) return;
    const s = &tx.state.attention;
    const thread = p.get(event, "thread_id");
    if (thread != .string or p.get(event, "workspace_id") != .string) {
        if (eq(tag, "focus")) {
            s.focus_workspace = "";
            s.focus_thread = "";
        }
        return;
    }
    s.focus_workspace = p.s(event, "workspace_id");
    s.focus_thread = thread.string;
    clearFocused(tx);
}
fn clearFocused(tx: *h.Transaction) void {
    const s = &tx.state.attention;
    if (s.focus_thread.len == 0 or tx.state.lifecycle != .foreground) return;
    const i = find(s.entries, s.focus_workspace, s.focus_thread) orelse return;
    if (s.entries[i].attention == null) return;
    @constCast(s.entries)[i].attention = null;
    s.dirty = true;
    tx.changed = true;
}

/// A decrypted push forwarded by the platform (`vc_push_open` output).
/// Records the attention without waiting for sync and suppresses a duplicate
/// in-app `notify`. `blocked` (input_needed) is only observable this way.
pub fn received(tx: *h.Transaction, event: V) E!void {
    const r = try h.decode(struct { workspace_id: []const u8, thread_id: []const u8, turn_id: []const u8, kind: []const u8 }, tx.allocator(), event);
    for ([_][]const u8{ r.workspace_id, r.thread_id, r.turn_id, r.kind }) |text| if (text.len == 0 or text.len > 256) return error.InvalidArgument;
    const s = &tx.state.attention;
    if (tx.state.auth.removal.wiping or tx.state.auth.credential == null) return;
    const status: Status, const kind: ?Kind = if (eq(r.kind, "completed")) .{ .done, .unread } else if (eq(r.kind, "failed")) .{ .@"error", .failed } else if (eq(r.kind, "approval_pending")) .{ .waiting, .needs_approval } else if (eq(r.kind, "input_needed")) .{ .working, .blocked } else if (eq(r.kind, "aborted")) .{ .idle, null } else return;
    const focused = focusedOn(tx, r.workspace_id, r.thread_id);
    const entry: Entry = .{ .workspace_id = r.workspace_id, .thread_id = r.thread_id, .turn_id = r.turn_id, .status = status, .attention = if (focused) null else kind, .since_ms = tx.state.wall_time_ms };
    if (kind) |k| try remember(tx, try push.dedupeKey(tx.allocator(), tx.state.config.host_id, r.turn_id, pushKind(k)));
    if (find(s.entries, r.workspace_id, r.thread_id)) |i| {
        @constCast(s.entries)[i] = entry;
    } else {
        if (s.entries.len >= MAX_ENTRIES) return;
        try append(Entry, tx.allocator(), &s.entries, entry);
    }
    s.dirty = true;
    tx.changed = true;
}

fn titleOf(state: *const h.State, ws: []const u8, thread: []const u8) []const u8 {
    if (state.sync.has_catalog) {
        for (state.sync.catalog) |t| if (eq(p.s(t, "workspace_id"), ws) and eq(p.s(t, "local_thread_id"), thread)) return p.s(t, "title");
    }
    for (p.rows(p.get(p.get(state.sync.snapshot, "snapshot"), "workspaces"))) |w| {
        if (!eq(p.s(w, "workspace_id"), ws)) continue;
        for (p.rows(p.get(w, "threads"))) |t| if (eq(p.s(t, "local_thread_id"), thread)) return p.s(t, "title");
    }
    return "";
}

fn newer(_: void, l: Item, r: Item) bool {
    if (l.since_ms != r.since_ms) return l.since_ms > r.since_ms;
    const order = std.mem.order(u8, l.workspace_id, r.workspace_id);
    return if (order == .eq) std.mem.lessThan(u8, l.thread_id, r.thread_id) else order == .lt;
}
pub fn view(a: A, state: *const h.State) E!View {
    var items: std.ArrayList(Item) = .empty;
    for (state.attention.entries) |e| {
        const kind = e.attention orelse continue;
        const title = titleOf(state, e.workspace_id, e.thread_id);
        try items.append(a, .{ .workspace_id = e.workspace_id, .thread_id = e.thread_id, .turn_id = if (e.turn_id.len > 0) e.turn_id else null, .kind = kind, .status = e.status, .since_ms = e.since_ms, .title = if (title.len > 0) title else "Chat", .deep_link = try push.deepLink(a, state.config.host_id, e.workspace_id, e.thread_id) });
    }
    std.mem.sort(Item, items.items, {}, newer);
    return .{ .items = items.items, .count = @intCast(items.items.len), .loading = !state.attention.loaded };
}

pub fn query(a: A, state: *const h.State, selector: []const u8) E!?V {
    if (!eq(selector, "attention")) return null;
    return try h.parseLimit(a, try h.encode(a, try view(a, state)), h.MAX_HTTP_INPUT);
}

/// Mark chat panes with their attention kind; Home also lists unread panes.
pub fn annotate(a: A, state: *const h.State, selector: []const u8, data: *V) E!void {
    if (state.attention.entries.len == 0) return;
    if (eq(selector, "workspaces")) {
        for (p.rows(p.get(data.*, "items"))) |ws| for (@constCast(p.rows(p.get(ws, "panes")))) |*pane| {
            _ = try mark(a, state, pane);
        };
        return;
    }
    if (!eq(selector, "home")) return;
    var items = p.get(data.*, "items");
    if (items != .array) return;
    for (items.array.items) |*pane| _ = try mark(a, state, pane);
    const all = try @import("sync.zig").query(a, state, "workspaces");
    for (p.rows(p.get(all, "items"))) |ws| {
        if (!p.yes(p.get(ws, "open"))) continue;
        for (@constCast(p.rows(p.get(ws, "panes")))) |*pane| {
            if (!try mark(a, state, pane)) continue;
            var listed = false;
            for (items.array.items) |existing| if (eq(p.s(existing, "id"), p.s(pane.*, "id"))) {
                listed = true;
            };
            if (!listed) try items.array.append(pane.*);
        }
    }
    std.mem.sort(V, items.array.items, {}, struct {
        fn less(_: void, l: V, r: V) bool {
            const x = p.yes(p.get(l, "attention"));
            if (x != p.yes(p.get(r, "attention"))) return x;
            return std.mem.lessThan(u8, p.s(l, "id"), p.s(r, "id"));
        }
    }.less);
    try data.object.put(a, "items", items);
}
fn mark(a: A, state: *const h.State, pane: *V) E!bool {
    if (pane.* != .object or !eq(p.s(pane.*, "kind"), "chat")) return false;
    const i = find(state.attention.entries, p.s(pane.*, "workspace_id"), p.s(pane.*, "thread_id")) orelse return false;
    const kind = state.attention.entries[i].attention orelse return false;
    try pane.object.put(a, "attention", .{ .bool = true });
    try pane.object.put(a, "attention_kind", .{ .string = @tagName(kind) });
    return true;
}
