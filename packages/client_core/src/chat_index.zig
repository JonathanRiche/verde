//! K-17 index of per-thread chat records (K-10 drafts and follow-ups) so an
//! acknowledged sign-out can delete them. Chat records are keyed by a digest
//! and the secure store has no listing API, so the core records every digest
//! it may have written in `vc/1/<host_id>/chat_index`.
//!
//! A digest is indexed as soon as the thread's record is first read, which is
//! always before its first write. The index write is not awaited, so a process
//! death between the two writes can leave one record unindexed (auth.md).
const std = @import("std");
const h = @import("host.zig");
const chat = @import("chat.zig");
const rpc = h.rpc;
const V = std.json.Value;
const E = h.ApiError;
const eq = h.eq;

pub const RECORD = "chat_index";
pub const MAX = 4096;
const Record = struct { version: u32 = 1, digests: []const []const u8 = &.{} };
pub const State = struct {
    digests: []const []const u8 = &.{},
    loaded: bool = false,
    load_id: ?[]const u8 = null,
    save_id: ?[]const u8 = null,
    dirty: bool = false,
};

pub fn recordKey(tx: *h.Transaction) E![]const u8 {
    return std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/" ++ RECORD, .{tx.state.config.host_id});
}
fn validDigest(d: []const u8) bool {
    if (d.len != 64) return false;
    for (d) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
fn contains(list: []const []const u8, d: []const u8) bool {
    for (list) |item| if (eq(item, d)) return true;
    return false;
}
fn add(tx: *h.Transaction, list: *[]const []const u8, d: []const u8) E!bool {
    if (contains(list.*, d) or list.len >= MAX) return false;
    const next = try tx.allocator().alloc([]const u8, list.len + 1);
    @memcpy(next[0..list.len], list.*);
    next[list.len] = d;
    list.* = next;
    return true;
}

/// Digests of chat threads that may have a stored record right now.
pub fn live(tx: *h.Transaction) E![]const []const u8 {
    var out: []const []const u8 = &.{};
    for (tx.state.chat.threads) |*t| {
        if (!t.loaded and t.storage_id == null) continue;
        const key = try chat.recordKey(tx, t);
        _ = try add(tx, &out, key[std.mem.lastIndexOfScalar(u8, key, '/').? + 1 ..]);
    }
    return out;
}

/// Parse a stored index value; corrupt input yields no digests.
pub fn parse(tx: *h.Transaction, value_base64: V) E![]const []const u8 {
    if (value_base64 != .string) return &.{};
    const bytes = @import("auth.zig").decode64(tx.allocator(), value_base64.string) catch |err| {
        if (err == error.OutOfMemory) return err;
        return &.{};
    };
    const record = std.json.parseFromSliceLeaky(Record, tx.allocator(), bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return &.{};
    };
    if (record.version != 1) return &.{};
    var out: []const []const u8 = &.{};
    for (record.digests) |d| if (validDigest(d)) {
        _ = try add(tx, &out, d);
    };
    return out;
}

pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.chat_index;
    if (tx.state.auth.removal.wiping or tx.state.lifecycle == .stopped) return;
    for (try live(tx)) |d| if (try add(tx, &s.digests, d)) {
        s.dirty = true;
    };
    if (!s.loaded) {
        if (s.dirty and s.load_id == null) {
            const key = try recordKey(tx);
            const id = try tx.emit("secure_store_get", .{ .key = key });
            try tx.track(.store_get, id, key);
            s.load_id = id;
        }
        return;
    }
    if (s.dirty and s.save_id == null) {
        const key = try recordKey(tx);
        const bytes = try h.encode(tx.allocator(), Record{ .digests = s.digests });
        const id = try tx.emit("secure_store_put", .{ .key = key, .value_base64 = try rpc.encodeBase64(tx.allocator(), bytes) });
        try tx.track(.store_put, id, key);
        s.save_id = id;
        s.dirty = false;
    }
}

pub fn complete(tx: *h.Transaction, pending: h.Pending, event: V) E!bool {
    const s = &tx.state.chat_index;
    if (s.save_id != null and eq(s.save_id.?, pending.id)) {
        s.save_id = null;
        if ((try h.field(event, "error")) != .null) s.dirty = true;
        return true;
    }
    if (s.load_id == null or !eq(s.load_id.?, pending.id)) return false;
    s.load_id = null;
    // An unreadable index must not be overwritten with a partial list; retry
    // the read when the next chat record appears instead of on every event.
    if ((try h.field(event, "error")) != .null) {
        s.dirty = false;
        return true;
    }
    s.loaded = true;
    for (try parse(tx, try h.field(event, "value_base64"))) |d| {
        _ = try add(tx, &s.digests, d);
    }
    s.dirty = true;
    return true;
}
