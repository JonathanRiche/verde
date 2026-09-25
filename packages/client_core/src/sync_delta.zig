//! K-16 gateway delta feed: opt-in negotiation, scoped refreshes and the
//! per-host resume checkpoint. Legacy sync (sync.zig) remains both the seed
//! and the fallback, so both modes share one set of projection inputs.
const std = @import("std");
const h = @import("host.zig");
const sync = @import("sync.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const changes_protocol = @import("headless").changes_protocol;
const V = std.json.Value;
const eq = h.eq;
const E = h.ApiError;

pub const CAPABILITY = "core.changes.delta.v1";
pub const ACK_TIMER = "sync_delta_ack";
pub const ACK_TIMEOUT_MS: u32 = 10_000;
/// Consecutive recoveries tolerated on one socket before it stays legacy.
pub const MAX_FALLBACKS: u8 = 3;
/// Same per-record bound as K-10's chat records; keeps the completion event
/// (base64 plus framing) under the host's 1 MiB local input limit.
pub const CHECKPOINT_MAX = h.MAX_INPUT / 2;

// Bits index `sync.scopes`: workspaces, registry, sessions, turns, config.
const WORKSPACES: u8 = 1;
const REGISTRY: u8 = 2;
const SESSIONS: u8 = 4;
const TURNS: u8 = 8;
const CONFIG: u8 = 16;
const ALL: u8 = 31;

/// Stored at `vc/1/<host_id>/sync`. A cursor is usable only together with the
/// exact projection inputs it acknowledges, so all of them are saved at once.
/// Decimal strings preserve the local API's 64-bit counter contract.
pub const Checkpoint = struct {
    version: u32 = 1,
    runtime_id: []const u8,
    instance_id: []const u8,
    nonce: []const u8,
    cursor: []const u8,
    snapshot: V,
    catalog: []const V,
};

pub const State = struct {
    // Checkpoint storage; survives sync resets and reconnects.
    loaded: bool = false,
    reading: bool = false,
    writing: bool = false,
    save_again: bool = false,
    /// `instance/nonce/cursor` of the last stored (or deliberately deleted) record.
    saved: []const u8 = "",
    /// Instance whose state the current sync inputs describe.
    instance_id: []const u8 = "",
    // Per WebSocket; cleared by transport invalidation or a new hello.
    socket: ?[]const u8 = null,
    control_id: ?u64 = null,
    requested_cursor: ?u64 = null,
    enabled: bool = false,
    disabled: bool = false,
    fallbacks: u8 = 0,
    // Scoped refresh work. Queued work belongs to the socket that reported it;
    // active work is an HTTP read that incorporates `active_cursor`.
    queued_scopes: u8 = 0,
    queued_catalog: bool = false,
    queued_cursor: ?u64 = null,
    active_cursor: ?u64 = null,
    active_scopes: []const []const u8 = &.{},
    active_catalog: bool = false,
};

pub fn advertised(tx: *const h.Transaction) bool {
    for (tx.state.rpc.runtime_capabilities) |name| if (eq(name, CAPABILITY)) return true;
    return false;
}

/// Transport invalidation. The incorporated cursor survives for resume: any
/// section already refreshed past it is refreshed again by the replay.
/// Active reads are finished by their cancelled RPC results in `sync.pump`.
pub fn invalidate(tx: *h.Transaction) void {
    const d = &tx.state.sync.delta;
    socketReset(d);
}

/// Called when the RPC handshake requests a full resync. Returns true when
/// delta owns the bootstrap: the checkpoint is loading, or the retained
/// inputs can resume at their cursor on this same instance.
pub fn handshake(tx: *h.Transaction) E!bool {
    const s = &tx.state.sync;
    const d = &s.delta;
    if (!advertised(tx)) return false;
    if (!d.loaded) {
        if (!d.reading) {
            const k = try key(tx);
            const id = try tx.emit("secure_store_get", .{ .key = k });
            try tx.track(.store_get, id, k);
            d.reading = true;
        }
        return true;
    }
    const instance = tx.state.rpc.instance_id orelse return false;
    if (resumable(tx) and eq(d.instance_id, instance)) {
        tx.state.stale = true;
        tx.changed = true;
        return true;
    }
    d.instance_id = instance;
    return false;
}

/// Host completion hook for sync-owned storage, the acknowledgement timer and
/// socket closure. Socket closure also belongs to auth, so it returns false.
pub fn complete(tx: *h.Transaction, pending: h.Pending, event: V) E!bool {
    const s = &tx.state.sync;
    const d = &s.delta;
    switch (pending.kind) {
        .timer => {
            if (!eq(pending.purpose, ACK_TIMER)) return false;
            if (d.control_id != null) try fallback(tx, true);
            return true;
        },
        .socket => {
            if (d.socket != null and eq(d.socket.?, pending.id)) socketReset(d);
            return false;
        },
        // Only our own in-flight read/write: D-04's wipe deletes this key too.
        .store_get => if (!d.reading or !eq(pending.key, try key(tx))) return false,
        .store_put, .store_delete => if (!d.writing or !eq(pending.key, try key(tx))) return false,
        else => return false,
    }
    if (pending.kind == .store_get) {
        d.reading = false;
        d.loaded = true;
        // A missing, unreadable or foreign checkpoint only costs a full seed.
        if (p.get(event, "error") == .null and p.get(event, "value_base64") == .string and !resumable(tx)) try restore(tx, p.s(event, "value_base64"));
        if (tx.state.rpc.phase == .ready) tx.state.rpc.full_resync = true;
        tx.changed = true;
        return true;
    }
    d.writing = false;
    if (p.get(event, "error") != .null) {
        // Only cold-start resume depends on this record; retry at the next
        // incorporated cursor instead of failing live sync.
        d.saved = "";
        d.save_again = false;
    } else if (d.save_again) try persist(tx);
    return true;
}

/// Records the socket that delivered `core.hello`, then negotiates.
pub fn hello(tx: *h.Transaction, socket: ?[]const u8) E!void {
    const d = &tx.state.sync.delta;
    const id = socket orelse return;
    if (d.socket == null or !eq(d.socket.?, id)) {
        if (d.control_id != null) try cancelAckTimer(tx);
        socketReset(d);
        d.socket = id;
    }
    try negotiate(tx);
}

/// Sends `core.changes.mode` once incorporated state and the socket are ready.
/// The explicit cursor makes the gateway replay everything after it.
pub fn negotiate(tx: *h.Transaction) E!void {
    const s = &tx.state.sync;
    const d = &s.delta;
    if (!advertised(tx) or d.disabled or d.enabled or d.control_id != null or d.reading) return;
    if (tx.state.rpc.phase != .ready or tx.state.lifecycle != .foreground or !tx.state.network_available) return;
    const socket = d.socket orelse return;
    if (!socketPending(tx, socket) or !resumable(tx)) return;
    const runtime = tx.state.rpc.runtime_id orelse return;
    const instance = tx.state.rpc.instance_id orelse return;
    if (!eq(d.instance_id, instance)) return;
    if (tx.state.rpc.next_id == std.math.maxInt(u64)) return error.ResourceLimit;
    const id = tx.state.rpc.next_id;
    tx.state.rpc.next_id += 1;
    const text = try h.encode(tx.allocator(), .{
        .jsonrpc = "2.0",
        .id = id,
        .method = "core.changes.mode",
        .params = .{ .mode = "delta", .cursor = s.cursor.? },
        .target = .{ .runtime_id = runtime, .instance_id = instance },
    });
    _ = try tx.emit("ws_send", .{ .socket_id = socket, .text = text });
    d.control_id = id;
    d.requested_cursor = s.cursor;
    try tx.setTimer(ACK_TIMER, ACK_TIMEOUT_MS);
}

/// The core sends no other WebSocket requests, so any response-shaped frame
/// while an opt-in is pending (including a null/zero-ID rejection) answers it.
pub fn control(tx: *h.Transaction, note: V) E!bool {
    const d = &tx.state.sync.delta;
    if (d.control_id == null or p.get(note, "method") != .null) return false;
    try cancelAckTimer(tx);
    const result = p.get(note, "result");
    const accepted = p.uint(p.get(note, "id")) == d.control_id and p.get(note, "error") == .null and
        eq(p.s(result, "mode"), "delta") and p.uint(p.get(result, "cursor")) == d.requested_cursor;
    d.control_id = null;
    d.requested_cursor = null;
    if (!accepted) {
        // Pushes were ignored while waiting; the legacy refresh catches up.
        try fallback(tx, true);
        return true;
    }
    d.enabled = true;
    if (!tx.state.sync.loading) tx.state.stale = false;
    tx.changed = true;
    return true;
}

/// True when a feed frame is covered by the pending opt-in's cursor replay.
pub fn ignoreFeed(tx: *const h.Transaction) bool {
    const d = &tx.state.sync.delta;
    return advertised(tx) and d.socket != null and !d.disabled and !d.enabled and (d.control_id != null or tx.state.sync.loading);
}

/// Legacy-seeded recovery. The gateway cannot return to legacy mode, but the
/// K-09 path refreshes on every change notice, so it stays correct either way.
/// Unless disabled, the completed refresh re-negotiates with its new cursor.
pub fn fallback(tx: *h.Transaction, disable: bool) E!void {
    const s = &tx.state.sync;
    const d = &s.delta;
    if (d.control_id != null) try cancelAckTimer(tx);
    d.control_id = null;
    d.requested_cursor = null;
    d.enabled = false;
    clearWork(d);
    d.fallbacks +|= 1;
    if (disable or d.fallbacks >= MAX_FALLBACKS) d.disabled = true;
    s.cursor = null;
    s.snapshot_id = null;
    s.page_id = null;
    s.loading = false;
    s.dirty = false;
    tx.state.stale = true;
    tx.changed = true;
    try sync.refresh(tx);
}

/// Applies one delta `core.changes` notice (the gateway's forwarded response).
pub fn changes(tx: *h.Transaction, params: V) E!void {
    const s = &tx.state.sync;
    const d = &s.delta;
    if (p.get(params, "error") != .null or p.get(params, "result") != .object) return fallback(tx, false);
    const result = std.json.parseFromValueLeaky(changes_protocol.ChangesResult, tx.allocator(), p.get(params, "result"), .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return fallback(tx, false);
    };
    const nonce = result.envelope.instance_nonce;
    if (result.expired or nonce.len == 0 or !eq(nonce, s.nonce)) return fallback(tx, false);
    const previous = d.queued_cursor orelse d.active_cursor orelse s.cursor orelse return fallback(tx, false);
    if (result.next_cursor < previous) return fallback(tx, false);
    var scopes_bits: u8 = 0;
    var catalog = false;
    for (result.entries) |entry| {
        if (entry.change_seq > result.next_cursor) return fallback(tx, false);
        // Replayed entries are already incorporated or already queued.
        if (entry.change_seq <= previous) continue;
        const topic = entry.topic;
        if (eq(topic, "workspace") or eq(topic, "chat.thread") or eq(topic, "chat.completion")) {
            scopes_bits |= WORKSPACES;
            catalog = true;
        } else if (eq(topic, "surface")) {
            scopes_bits |= WORKSPACES;
        } else if (eq(topic, "chat.turn")) {
            scopes_bits |= TURNS;
        } else if (eq(topic, "process") or eq(topic, "lease")) {
            scopes_bits |= REGISTRY;
        } else if (eq(topic, "session")) {
            scopes_bits |= SESSIONS;
        } else if (!eq(topic, "notification")) {
            // Unknown topics refresh everything a legacy change would.
            scopes_bits |= ALL;
            catalog = true;
        }
    }
    if (result.next_cursor == previous) return;
    d.queued_scopes |= scopes_bits;
    d.queued_catalog = d.queued_catalog or catalog;
    d.queued_cursor = result.next_cursor;
    try drain(tx);
}

/// Starts the next coalesced scoped read. Only one sync read is in flight.
pub fn drain(tx: *h.Transaction) E!void {
    const s = &tx.state.sync;
    const d = &s.delta;
    if (!d.enabled or s.loading or s.snapshot_id != null or s.page_id != null) return;
    const cursor = d.queued_cursor orelse return;
    var bits = d.queued_scopes;
    const catalog = d.queued_catalog;
    d.queued_cursor = null;
    d.queued_scopes = 0;
    d.queued_catalog = false;
    if (bits == 0 and !catalog) {
        // Notifications and empty batches advance without a read.
        s.cursor = cursor;
        try persist(tx);
        return;
    }
    // Config is not journaled; legacy refreshes it on every change, so it
    // rides along with every scoped read.
    bits |= CONFIG;
    var selected: std.ArrayList([]const u8) = .empty;
    for (sync.scopes, 0..) |scope, i| {
        if (bits & (@as(u8, 1) << @intCast(i)) != 0) try selected.append(tx.allocator(), scope);
    }
    d.active_cursor = cursor;
    d.active_scopes = try selected.toOwnedSlice(tx.allocator());
    d.active_catalog = catalog;
    try sync.startSnapshot(tx, d.active_scopes);
}

/// Completes a refresh (legacy seed or scoped read) and continues the queue.
pub fn finish(tx: *h.Transaction) E!void {
    const s = &tx.state.sync;
    const d = &s.delta;
    if (d.active_cursor) |cursor| s.cursor = cursor;
    d.active_cursor = null;
    d.active_scopes = &.{};
    d.active_catalog = false;
    s.loading = false;
    tx.changed = true;
    try drain(tx);
    if (s.loading) return;
    try persist(tx);
    try negotiate(tx);
}

/// A transport-cancelled scoped read keeps the cursor for resume.
pub fn abandon(tx: *h.Transaction) void {
    const s = &tx.state.sync;
    clearWork(&s.delta);
    s.loading = false;
    s.snapshot_id = null;
    s.page_id = null;
    tx.state.stale = true;
    tx.changed = true;
}

/// Writes the checkpoint after an incorporated cursor. One write is in flight;
/// later cursors coalesce behind it.
pub fn persist(tx: *h.Transaction) E!void {
    const s = &tx.state.sync;
    const d = &s.delta;
    if (!advertised(tx) or !d.loaded or !resumable(tx) or d.queued_cursor != null) return;
    const runtime = tx.state.rpc.runtime_id orelse return;
    const instance = tx.state.rpc.instance_id orelse return;
    if (!eq(d.instance_id, instance)) return;
    const token = try std.fmt.allocPrint(tx.allocator(), "{s}/{s}/{d}", .{ instance, s.nonce, s.cursor.? });
    if (eq(token, d.saved)) return;
    if (d.writing) {
        d.save_again = true;
        return;
    }
    d.save_again = false;
    const bytes = try h.encode(tx.allocator(), Checkpoint{
        .runtime_id = runtime,
        .instance_id = instance,
        .nonce = s.nonce,
        .cursor = try std.fmt.allocPrint(tx.allocator(), "{d}", .{s.cursor.?}),
        .snapshot = s.snapshot,
        .catalog = s.catalog,
    });
    const k = try key(tx);
    if (bytes.len > CHECKPOINT_MAX) {
        // A stale record is still self-consistent, but do not keep resuming
        // from ever older cursors: delete it once until one fits again.
        if (eq(d.saved, "-")) return;
        const id = try tx.emit("secure_store_delete", .{ .key = k });
        try tx.track(.store_delete, id, k);
        d.saved = "-";
    } else {
        const id = try tx.emit("secure_store_put", .{ .key = k, .value_base64 = try rpc.encodeBase64(tx.allocator(), bytes) });
        try tx.track(.store_put, id, k);
        d.saved = token;
    }
    d.writing = true;
}

pub fn key(tx: *h.Transaction) E![]const u8 {
    return std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/sync", .{tx.state.config.host_id});
}

/// Complete, error-free projection inputs with a cursor and nonce.
fn resumable(tx: *const h.Transaction) bool {
    const s = &tx.state.sync;
    return s.cursor != null and s.has_catalog and s.nonce.len > 0 and s.@"error" == null and
        !s.loading and s.snapshot_id == null and s.page_id == null and s.snapshot == .object;
}

fn restore(tx: *h.Transaction, encoded: []const u8) E!void {
    const s = &tx.state.sync;
    const a = tx.allocator();
    const bytes = @import("auth.zig").decode64(a, encoded) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    const saved = std.json.parseFromSliceLeaky(Checkpoint, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    const cursor = std.fmt.parseInt(u64, saved.cursor, 10) catch return;
    if (saved.version != 1 or saved.nonce.len == 0) return;
    if (!eq(saved.runtime_id, tx.state.rpc.runtime_id orelse "") or !eq(saved.instance_id, tx.state.rpc.instance_id orelse "")) return;
    if (p.get(saved.snapshot, "snapshot") != .object or p.uint(p.get(saved.snapshot, "store_revision")) == null) return;
    if (!eq(p.s(p.get(saved.snapshot, "envelope"), "instance_nonce"), saved.nonce)) return;
    for (saved.catalog) |row| {
        if (p.s(row, "workspace_id").len == 0 or p.s(row, "local_thread_id").len == 0) return;
    }
    const d = s.delta;
    s.* = .{ .delta = d };
    s.snapshot = saved.snapshot;
    s.catalog = saved.catalog;
    s.has_catalog = true;
    s.cursor = cursor;
    s.nonce = saved.nonce;
    s.delta.instance_id = saved.instance_id;
    s.delta.saved = try std.fmt.allocPrint(a, "{s}/{s}/{d}", .{ saved.instance_id, saved.nonce, cursor });
    tx.state.stale = true;
}

fn socketPending(tx: *const h.Transaction, socket: []const u8) bool {
    for (tx.state.pending) |pending| {
        if (pending.kind == .socket and eq(pending.id, socket)) return true;
    }
    return false;
}

fn socketReset(d: *State) void {
    d.socket = null;
    d.control_id = null;
    d.requested_cursor = null;
    d.enabled = false;
    d.disabled = false;
    d.fallbacks = 0;
    // Queued entries are replayed from the incorporated cursor on resume.
    d.queued_scopes = 0;
    d.queued_catalog = false;
    d.queued_cursor = null;
}

pub fn clearWork(d: *State) void {
    d.queued_scopes = 0;
    d.queued_catalog = false;
    d.queued_cursor = null;
    d.active_cursor = null;
    d.active_scopes = &.{};
    d.active_catalog = false;
}

fn cancelAckTimer(tx: *h.Transaction) E!void {
    for (tx.state.pending, 0..) |pending, i| {
        if (pending.kind == .timer and eq(pending.purpose, ACK_TIMER)) {
            _ = try tx.emit("cancel_timer", .{ .timer_id = pending.id });
            try tx.remove(i);
            return;
        }
    }
}
