//! Core-owned revocation and acknowledged local removal. No platform RPC policy.
const std = @import("std");
const h = @import("host.zig");
const auth = @import("auth.zig");
const chat_index = @import("chat_index.zig");
const V = std.json.Value;
const E = h.ApiError;

pub const State = struct {
    intent_id: ?[]const u8 = null,
    rpc_id: ?u64 = null,
    wiping: bool = false,
    /// Acknowledged removal order. `chat_index_read` is a secure-store read
    /// of the K-17 index; `chat` walks `chat_digests` one record at a time.
    record: enum { credential, profile, sync, attention, push, chat_index_read, chat, chat_index } = .credential,
    delete_pending: bool = false,
    delete_failed: bool = false,
    /// K-10 chat record digests captured before the in-memory state resets.
    chat_digests: []const []const u8 = &.{},
    chat_next: usize = 0,
    index_loaded: bool = false,
};

fn outcome(tx: *h.Transaction, state: []const u8, failure: ?h.LocalError) void {
    const id = tx.state.auth.removal.intent_id orelse return;
    for (@constCast(tx.state.receipts)) |*r| if (h.eq(r.operation.intent_id, id)) {
        r.operation.state = state;
        r.operation.@"error" = failure;
    };
    tx.state.host_error = failure;
    tx.changed = true;
}
fn unconfirmed(tx: *h.Transaction) void {
    tx.state.auth.removal.rpc_id = null;
    outcome(tx, "uncertain", .{ .domain = "auth", .code = "sign_out_unconfirmed", .message = "Remote sign out was not confirmed.", .retryable = true, .delivery = "uncertain" });
}
fn deleteRecord(tx: *h.Transaction) E!void {
    const s = &tx.state.auth.removal;
    const host = tx.state.config.host_id;
    if (s.record == .chat_index_read) {
        // The index is read, not deleted, first: it lists the chat records.
        const key = try std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/{s}", .{ host, chat_index.RECORD });
        const id = try tx.emit("secure_store_get", .{ .key = key });
        try tx.track(.store_get, id, key);
        s.delete_pending = true;
        s.delete_failed = false;
        outcome(tx, "pending", null);
        return;
    }
    const key = if (s.record == .chat)
        try std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/chat/{s}", .{ host, s.chat_digests[s.chat_next] })
    else
        try std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/{s}", .{ host, @tagName(s.record) });
    const id = try tx.emit("secure_store_delete", .{ .key = key });
    try tx.track(.store_delete, id, key);
    s.delete_pending = true;
    s.delete_failed = false;
    outcome(tx, "pending", null);
}
fn wipe(tx: *h.Transaction) E!void {
    tx.state.auth.removal.rpc_id = null;
    auth.suspendSession(tx);
    try tx.invalidateTransport();
    var removal = tx.state.auth.removal;
    // Capture K-10 chat records before the chat engine state is dropped.
    if (!removal.wiping) {
        var digests: std.ArrayList([]const u8) = .empty;
        try digests.appendSlice(tx.allocator(), tx.state.chat_index.digests);
        for (try chat_index.live(tx)) |d| {
            var known = false;
            for (digests.items) |item| known = known or h.eq(item, d);
            if (!known) try digests.append(tx.allocator(), d);
        }
        removal.chat_digests = digests.items;
        removal.chat_next = 0;
        removal.index_loaded = tx.state.chat_index.loaded;
    }
    tx.state.auth = .{ .profile_loaded = true, .credential_loaded = true, .blocked = true, .removal = removal };
    tx.state.auth.removal.wiping = true;
    tx.state.attention = .{};
    tx.state.push = .{};
    tx.state.chat_index = .{};
    tx.state.rpc = .{ .next_id = tx.state.rpc.next_id };
    tx.state.sync = .{};
    tx.state.chat = .{};
    tx.state.terminal = .{};
    tx.state.stale = false;
    tx.state.auth_state = "signing_out";
    try deleteRecord(tx);
}

pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!bool {
    const removal = &tx.state.auth.removal;
    const retry_delete = h.eq(tag, "retry_connection") and removal.wiping and removal.delete_failed;
    if (!h.eq(tag, "sign_out") and !h.eq(tag, "forget_host") and !retry_delete) return false;
    if (!retry_delete and !h.eq(try h.string(event, "host_id"), tx.state.config.host_id)) return error.InvalidArgument;
    if (tx.state.lifecycle == .created or tx.state.lifecycle == .stopped) return error.InvalidLifecycle;
    // Do not race issued credential/profile writes or the initial secure-store reads.
    for (tx.state.pending) |p| if (p.kind == .store_get or p.kind == .store_put or p.kind == .store_delete) return error.InvalidLifecycle;
    if (removal.delete_pending) return error.InvalidLifecycle;
    if (removal.rpc_id != null) {
        // A revoke can stall behind token refresh; explicit local removal must still work.
        if (!h.eq(tag, "forget_host")) return error.InvalidLifecycle;
        unconfirmed(tx);
    }
    removal.intent_id = try h.string(event, "intent_id");
    if (removal.wiping) {
        try deleteRecord(tx);
    } else if (h.eq(tag, "forget_host") or tx.state.auth.credential_invalid or h.eq(tx.state.auth_state, "signed_out") or (tx.state.auth.credential_loaded and tx.state.auth.credential == null)) {
        try wipe(tx);
    } else if (tx.state.lifecycle != .foreground or !tx.state.network_available or tx.state.rpc.bearer == null or tx.state.rpc.phase != .ready) {
        unconfirmed(tx);
    } else {
        removal.rpc_id = try h.rpc.request(tx, "device.self.revoke", .{ .access_protocol_version = 1 }, .{ .intent_id = removal.intent_id });
        outcome(tx, "pending", null);
    }
    return true;
}

/// Consume only our correlated RPC result before other feature pumps see it.
pub fn advance(tx: *h.Transaction) E!void {
    const removal = &tx.state.auth.removal;
    const id = removal.rpc_id orelse return;
    if (tx.state.auth.credential_invalid) return wipe(tx);
    for (tx.state.rpc.results, 0..) |result, index| {
        if (result.id != id) continue;
        const rest = try tx.allocator().alloc(h.rpc.Result, tx.state.rpc.results.len - 1);
        @memcpy(rest[0..index], tx.state.rpc.results[0..index]);
        @memcpy(rest[index..], tx.state.rpc.results[index + 1 ..]);
        tx.state.rpc.results = rest;
        if (result.@"error" == null and result.value != null) {
            const reply = h.decode(@import("headless").access_protocol.DeviceRevokeResult, tx.allocator(), result.value.?) catch |err| {
                if (err == error.OutOfMemory) return err;
                unconfirmed(tx);
                return;
            };
            const credential = tx.state.auth.credential orelse {
                unconfirmed(tx);
                return;
            };
            if (reply.access_protocol_version == 1 and h.eq(reply.device_id, credential.device_id)) {
                try wipe(tx);
                return;
            }
        }
        unconfirmed(tx);
        return;
    }
}

pub fn complete(tx: *h.Transaction, p: h.Pending, event: V) E!bool {
    const s = &tx.state.auth.removal;
    const expected: h.PendingKind = if (s.record == .chat_index_read) .store_get else .store_delete;
    if (p.kind != expected or !s.wiping or !s.delete_pending) return false;
    s.delete_pending = false;
    if ((try h.field(event, "error")) != .null) {
        s.delete_failed = true;
        outcome(tx, "failed", .{ .domain = "storage", .code = "sign_out_delete_failed", .message = "Local removal could not complete. Unlock the device and retry.", .retryable = true });
    } else if (s.record != .chat_index) {
        if (s.record == .chat_index_read) {
            var digests: std.ArrayList([]const u8) = .empty;
            try digests.appendSlice(tx.allocator(), s.chat_digests);
            for (try chat_index.parse(tx, try h.field(event, "value_base64"))) |d| {
                var known = false;
                for (digests.items) |item| known = known or h.eq(item, d);
                if (!known) try digests.append(tx.allocator(), d);
            }
            s.chat_digests = digests.items;
        }
        // Credential first; K-16's checkpoint and K-17's records follow, and the
        // chat index is deleted only after every record it lists.
        s.record = switch (s.record) {
            .credential => .profile,
            .profile => .sync,
            .sync => .attention,
            .attention => .push,
            .push => if (!s.index_loaded) .chat_index_read else if (s.chat_digests.len > 0) .chat else .chat_index,
            .chat_index_read => if (s.chat_digests.len > 0) .chat else .chat_index,
            .chat => blk: {
                s.chat_next += 1;
                break :blk if (s.chat_next < s.chat_digests.len) .chat else .chat_index;
            },
            .chat_index => unreachable,
        };
        try deleteRecord(tx);
    } else {
        s.wiping = false;
        tx.state.auth.blocked = false;
        tx.state.auth_state = "signed_out";
        tx.state.config.https_url = null;
        tx.state.config.wss_url = null;
        outcome(tx, "succeeded", null);
    }
    return true;
}
