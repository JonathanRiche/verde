//! Snapshot/push sync. Cursors advance only after snapshot and catalog commit.
//! K-16 delta mode (sync_delta.zig) reuses this seed, merge and projection path.
pub const delta = @import("sync_delta.zig");
const std = @import("std");
const host = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const store = @import("headless").store_protocol;
const V = std.json.Value;
const eq = host.eq;
pub const State = struct {
    delta: delta.State = .{},
    snapshot: V = .null,
    catalog: []const V = &.{},
    has_catalog: bool = false,
    snapshot_id: ?u64 = null,
    page_id: ?u64 = null,
    staged: []const V = &.{},
    page_revision: ?u64 = null,
    page_restarts: u8 = 0,
    seen_cursors: []const []const u8 = &.{},
    cursor: ?u64 = null,
    nonce: []const u8 = "",
    dirty: bool = false,
    loading: bool = false,
    @"error": ?host.LocalError = null,
};
pub const scopes = [_][]const u8{ "workspaces", "registry", "sessions", "turns", "config" };
fn append(comptime T: type, tx: *host.Transaction, dest: *[]const T, item: T) !void {
    const next = try tx.allocator().alloc(T, dest.len + 1);
    @memcpy(next[0..dest.len], dest.*);
    next[dest.len] = item;
    dest.* = next;
}
pub fn refresh(tx: *host.Transaction) host.ApiError!void {
    const s = &tx.state.sync;
    if (s.snapshot_id != null or s.page_id != null) {
        s.dirty = true;
        return;
    }
    if (tx.state.rpc.phase != .ready or tx.state.lifecycle != .foreground or !tx.state.network_available) return;
    try startSnapshot(tx, &scopes);
}
/// Issues the owned snapshot read; K-16 passes a subset for scoped refreshes.
pub fn startSnapshot(tx: *host.Transaction, requested: []const []const u8) host.ApiError!void {
    const s = &tx.state.sync;
    s.snapshot_id = try rpc.request(tx, "core.snapshot", .{ .scopes = requested }, .{ .mutation = false, .legacy_snapshot = true, .intent_id = "@sync" });
    s.loading = true;
    s.dirty = false;
    s.@"error" = null;
    tx.changed = true;
}
/// Clears sync inputs but keeps delta checkpoint/socket bookkeeping.
pub fn reset(tx: *host.Transaction) void {
    const d = tx.state.sync.delta;
    tx.state.sync = .{ .delta = d };
    delta.clearWork(&tx.state.sync.delta);
}
fn page(tx: *host.Transaction, cursor: ?[]const u8) host.ApiError!void {
    const limit = @min(@as(u32, 100), tx.state.rpc.limits.max_page_items);
    tx.state.sync.page_id = try rpc.request(tx, "chat.thread.list", .{ .workspace_id = "", .limit = limit, .cursor = cursor }, .{ .mutation = false, .page_items = limit, .intent_id = "@sync" });
}
fn errorState(tx: *host.Transaction, err: host.LocalError) void {
    tx.state.sync.@"error" = err;
    tx.state.sync.loading = false;
    tx.state.stale = true;
    tx.changed = true;
}
fn protocolError(tx: *host.Transaction) void {
    errorState(tx, rpc.failure(.protocol, "invalid_sync_response", false));
}
fn unwrap(value: V) V {
    return if (p.get(value, "result") != .null) p.get(value, "result") else value;
}
/// Merge only fields actually delivered; absent scopes retain their cached sections.
pub fn applySnapshot(tx: *host.Transaction, value: V) host.ApiError!void {
    return applySnapshotScopes(tx, value, &scopes);
}
/// The wire emits empty defaults even for unrequested scopes; use request metadata.
pub fn applySnapshotScopes(tx: *host.Transaction, value: V, requested: []const []const u8) host.ApiError!void {
    const incoming = unwrap(value);
    if (incoming != .object or p.get(incoming, "snapshot") != .object or p.uint(p.get(incoming, "store_revision")) == null) {
        protocolError(tx);
        return;
    }
    _ = std.json.parseFromValueLeaky(store.CoreSnapshotResult, tx.allocator(), incoming, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        protocolError(tx);
        return;
    };
    const s = &tx.state.sync;
    const nonce = p.s(p.get(incoming, "envelope"), "instance_nonce");
    if (nonce.len > 0 and s.nonce.len > 0 and !eq(nonce, s.nonce)) {
        s.catalog = &.{};
        s.has_catalog = false;
        s.cursor = null;
        s.snapshot = .null;
    }
    if (nonce.len > 0) s.nonce = nonce;
    // Ignore reordered older durable snapshots within the same namespace.
    if ((p.uint(p.get(incoming, "store_revision")) orelse 0) < (p.uint(p.get(s.snapshot, "store_revision")) orelse 0)) return;
    if (p.uint(p.get(incoming, "store_revision")) == p.uint(p.get(s.snapshot, "store_revision")) and
        (p.uint(p.get(p.get(incoming, "envelope"), "registry_revision")) orelse 0) <
            (p.uint(p.get(p.get(s.snapshot, "envelope"), "registry_revision")) orelse 0)) return;
    var merged = if (s.snapshot == .object) s.snapshot else V{ .object = .empty };
    var iter = incoming.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const scope = if (eq(key, "snapshot")) "workspaces" else if (eq(key, "processes") or eq(key, "leases")) "registry" else if (eq(key, "sessions") or eq(key, "turns") or eq(key, "config")) key else "";
        if (scope.len > 0) {
            var included = false;
            for (requested) |item| {
                if (eq(scope, item)) included = true;
            }
            if (!included) continue;
        }
        if (eq(key, "incomplete_scopes") and requested.len < scopes.len) {
            // A scoped read reports only its own scopes; keep the others' flags.
            var incomplete: std.array_list.Managed(V) = .init(tx.allocator());
            for (p.rows(p.get(merged, key))) |old| {
                var keep = false;
                for (scopes) |known| {
                    if (old == .string and eq(old.string, known)) keep = true;
                }
                for (requested) |item| {
                    if (old == .string and eq(old.string, item)) keep = false;
                }
                if (keep) try incomplete.append(old);
            }
            for (p.rows(entry.value_ptr.*)) |item| try incomplete.append(item);
            try merged.object.put(tx.allocator(), key, .{ .array = incomplete });
        } else if (eq(entry.key_ptr.*, "snapshot") and p.get(merged, "snapshot") == .object) {
            var durable = p.get(merged, "snapshot");
            var fields = entry.value_ptr.object.iterator();
            while (fields.next()) |f| try durable.object.put(tx.allocator(), f.key_ptr.*, f.value_ptr.*);
            try merged.object.put(tx.allocator(), "snapshot", durable);
        } else try merged.object.put(tx.allocator(), entry.key_ptr.*, entry.value_ptr.*);
    }
    s.snapshot = merged;
    s.@"error" = null;
    tx.changed = true;
}
fn sourceThread(snapshot: V, ws: []const u8, id: []const u8) V {
    for (p.rows(p.get(p.get(snapshot, "snapshot"), "workspaces"))) |w| {
        if (!eq(p.s(w, "workspace_id"), ws)) continue;
        for (p.rows(p.get(w, "threads"))) |t| {
            if (eq(p.s(t, "local_thread_id"), id)) return t;
        }
    }
    return .null;
}
fn oldThread(catalog: []const V, ws: []const u8, id: []const u8) V {
    for (catalog) |t| {
        if (eq(p.s(t, "workspace_id"), ws) and eq(p.s(t, "local_thread_id"), id)) return t;
    }
    return .null;
}
fn restartPages(tx: *host.Transaction) host.ApiError!void {
    const s = &tx.state.sync;
    if (s.page_restarts >= 3) {
        errorState(tx, .{ .domain = "rpc", .code = "catalog_changed", .message = "The thread catalog changed during loading.", .retryable = true });
        return;
    }
    s.page_restarts += 1;
    s.staged = &.{};
    s.seen_cursors = &.{};
    s.page_revision = null;
    try page(tx, null);
}
fn receivePage(tx: *host.Transaction, value: V) host.ApiError!void {
    const s = &tx.state.sync;
    const revision = p.uint(p.get(value, "store_revision"));
    if (value != .object or p.get(value, "threads") != .array or revision == null) {
        protocolError(tx);
        return;
    }
    if (s.page_revision) |old| {
        if (old != revision.?) {
            try restartPages(tx);
            return;
        }
    }
    _ = std.json.parseFromValueLeaky(store.ThreadListResult, tx.allocator(), value, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        protocolError(tx);
        return;
    };
    s.page_revision = revision;
    for (p.rows(p.get(value, "threads"))) |t| {
        const ws = p.s(t, "workspace_id");
        const id = p.s(t, "local_thread_id");
        if (ws.len == 0 or id.len == 0) {
            protocolError(tx);
            return;
        }
        const merged = try p.mergeThreadCatalogSettings(tx.allocator(), t, sourceThread(s.snapshot, ws, id), oldThread(s.catalog, ws, id));
        var duplicate = false;
        for (s.staged, 0..) |row, i| {
            if (eq(p.s(row, "workspace_id"), ws) and eq(p.s(row, "local_thread_id"), id)) {
                const next = try tx.allocator().dupe(V, s.staged);
                next[i] = merged;
                s.staged = next;
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            if (s.staged.len >= 100_000) return error.ResourceLimit;
            try append(V, tx, &s.staged, merged);
        }
    }
    const cursor = p.get(value, "next_cursor");
    if (cursor != .null) {
        if (cursor != .string or cursor.string.len == 0 or s.seen_cursors.len >= 10_000) {
            protocolError(tx);
            return;
        }
        for (s.seen_cursors) |seen| {
            if (eq(seen, cursor.string)) {
                protocolError(tx);
                return;
            }
        }
        try append([]const u8, tx, &s.seen_cursors, cursor.string);
        try page(tx, cursor.string);
        return;
    }
    s.catalog = s.staged;
    s.has_catalog = true;
    s.staged = &.{};
    s.loading = false;
    s.cursor = s.delta.active_cursor orelse p.uint(p.get(s.snapshot, "change_cursor"));
    tx.state.stale = s.dirty;
    tx.changed = true;
    if (s.dirty) try refresh(tx) else try delta.finish(tx);
}
/// Drain only owned result IDs; other feature engines retain their outcomes.
pub fn pump(tx: *host.Transaction) host.ApiError!void {
    const s = &tx.state.sync;
    if (rpc.takeFullResync(tx) and !try delta.handshake(tx)) {
        reset(tx);
        tx.state.stale = true;
        try refresh(tx);
    }
    try delta.negotiate(tx);
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        const snapshot = s.snapshot_id != null and s.snapshot_id.? == result.id;
        const catalog = s.page_id != null and s.page_id.? == result.id;
        if (!snapshot and !catalog) {
            if (result.intent_id != null and eq(result.intent_id.?, "@sync")) continue;
            try append(rpc.Result, tx, &tx.state.rpc.results, result);
            continue;
        }
        if (snapshot) s.snapshot_id = null else s.page_id = null;
        const scoped = s.delta.active_cursor != null;
        if (result.@"error") |err| {
            if (catalog and err.rpc_code != null and eq(err.rpc_code.?, "revision_expired") and tx.state.rpc.phase == .ready) {
                try restartPages(tx);
            } else if (scoped and tx.state.rpc.phase != .ready) {
                delta.abandon(tx);
            } else if (scoped) {
                try delta.fallback(tx, false);
                if (s.snapshot_id == null) errorState(tx, err);
            } else errorState(tx, err);
            continue;
        }
        if (snapshot) {
            const value = result.value orelse .null;
            const nonce = p.s(p.get(unwrap(value), "envelope"), "instance_nonce");
            if (scoped and nonce.len > 0 and !eq(nonce, s.nonce)) {
                try delta.fallback(tx, false);
                continue;
            }
            try applySnapshotScopes(tx, value, if (scoped) s.delta.active_scopes else &scopes);
            if (s.@"error" != null) {
                if (scoped) try delta.fallback(tx, false);
                continue;
            }
            if (scoped and !s.delta.active_catalog) {
                try delta.finish(tx);
                continue;
            }
            s.staged = &.{};
            s.page_revision = null;
            s.page_restarts = 0;
            s.seen_cursors = &.{};
            try page(tx, null);
        } else try receivePage(tx, result.value orelse .null);
    }
}
/// Called only after host socket ID and generation validation. The only WS
/// request is K-16's `core.changes.mode`; everything else is push-only.
pub fn push(tx: *host.Transaction, text: []const u8) host.ApiError!void {
    return pushFrom(tx, null, text);
}
pub fn pushFrom(tx: *host.Transaction, socket: ?[]const u8, text: []const u8) host.ApiError!void {
    const note = host.parseLimit(tx.allocator(), text, 8 * 1024 * 1024) catch |err| {
        if (err == error.OutOfMemory) return err;
        try tx.invalidateTransport();
        protocolError(tx);
        tx.state.rpc.phase = .failed;
        return;
    };
    if (try delta.control(tx, note)) return;
    const method = p.s(note, "method");
    const params = p.get(note, "params");
    const value = unwrap(params);
    if (eq(method, "core.hello")) {
        const status = unwrap(p.get(params, "status_envelope"));
        const runtime = p.s(status, "runtime_id");
        const instance = p.s(status, "instance_id");
        if (tx.state.rpc.runtime_id) |expected| {
            if (!eq(expected, runtime)) {
                try tx.invalidateTransport();
                tx.state.rpc.phase = .awaiting_trust;
                tx.state.host_error = rpc.failure(.identity, "runtime_changed", false);
                return;
            }
        }
        if (tx.state.rpc.instance_id) |expected| {
            if (!eq(expected, instance)) {
                try tx.invalidateTransport();
                reset(tx);
                _ = try rpc.beginHandshake(tx);
                return;
            }
        }
        try delta.hello(tx, socket);
    } else if (eq(method, "core.snapshot")) {
        // Delta recovery snapshots and pre-opt-in pushes are covered by the
        // cursor replay; the core refreshes over HTTP instead.
        if (tx.state.sync.delta.enabled or delta.ignoreFeed(tx)) return;
        // An in-flight HTTP snapshot/catalog owns the refresh boundary. A push
        // cannot cancel it or move its cursor; schedule a follow-up instead.
        if (tx.state.sync.loading) {
            tx.state.sync.dirty = true;
            return;
        }
        try applySnapshot(tx, value);
        if (tx.state.sync.@"error" == null and tx.state.rpc.phase == .ready) {
            tx.state.sync.loading = true;
            tx.state.sync.staged = &.{};
            tx.state.sync.page_revision = null;
            tx.state.sync.page_restarts = 0;
            tx.state.sync.seen_cursors = &.{};
            try page(tx, null);
        }
    } else if (eq(method, "core.changes")) {
        if (delta.ignoreFeed(tx)) return;
        if (tx.state.sync.delta.enabled) return delta.changes(tx, params);
        const nonce = p.s(p.get(value, "envelope"), "instance_nonce");
        const changed = nonce.len > 0 and tx.state.sync.nonce.len > 0 and !eq(nonce, tx.state.sync.nonce);
        if (changed or p.yes(p.get(value, "expired")) or eq(p.s(p.get(params, "error"), "code"), "revision_expired")) {
            if (tx.state.sync.loading and !changed) {
                tx.state.sync.dirty = true;
                tx.state.sync.cursor = null;
                tx.state.stale = true;
                return;
            }
            reset(tx);
            if (changed) tx.state.sync.nonce = nonce;
            tx.state.stale = true;
        }
        if (changed or p.yes(p.get(value, "expired")) or p.rows(p.get(value, "entries")).len > 0 or p.get(params, "error") != .null) try refresh(tx);
    }
}
pub fn query(a: std.mem.Allocator, state: *const host.State, selector: []const u8) host.ApiError!V {
    const s = &state.sync;
    const models = try p.project(a, s.snapshot, s.catalog, s.has_catalog, state.wall_time_ms);
    const bytes = if (eq(selector, "home")) try std.json.Stringify.valueAlloc(a, .{ .items = models.active, .loading = s.loading, .stale = state.stale, .incomplete_scopes = if (p.get(s.snapshot, "incomplete_scopes") == .array) p.get(s.snapshot, "incomplete_scopes") else V{ .array = std.array_list.Managed(V).init(a) }, .@"error" = s.@"error" }, .{}) else try std.json.Stringify.valueAlloc(a, .{ .items = models.workspaces, .loading = s.loading, .stale = state.stale, .@"error" = s.@"error", .history = .{ .query = "", .items = models.history, .next_cursor = @as(?[]const u8, null), .loading = s.loading, .@"error" = s.@"error" } }, .{});
    return host.parse(a, bytes);
}
