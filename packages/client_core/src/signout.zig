//! Core-owned revocation and acknowledged local removal. No platform RPC policy.
const std = @import("std");
const h = @import("host.zig");
const auth = @import("auth.zig");
const V = std.json.Value;
const E = h.ApiError;

pub const State = struct {
    intent_id: ?[]const u8 = null,
    rpc_id: ?u64 = null,
    wiping: bool = false,
    record: enum { credential, profile, sync } = .credential,
    delete_pending: bool = false,
    delete_failed: bool = false,
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
    const key = try std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/{s}", .{ tx.state.config.host_id, @tagName(s.record) });
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
    const removal = tx.state.auth.removal;
    tx.state.auth = .{ .profile_loaded = true, .credential_loaded = true, .blocked = true, .removal = removal };
    tx.state.auth.removal.wiping = true;
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
    if (p.kind != .store_delete or !s.wiping or !s.delete_pending) return false;
    s.delete_pending = false;
    if ((try h.field(event, "error")) != .null) {
        s.delete_failed = true;
        outcome(tx, "failed", .{ .domain = "storage", .code = "sign_out_delete_failed", .message = "Local removal could not complete. Unlock the device and retry.", .retryable = true });
    } else if (s.record != .sync) {
        // K-16's resume checkpoint holds workspace/thread metadata; remove it last.
        s.record = if (s.record == .credential) .profile else .sync;
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
