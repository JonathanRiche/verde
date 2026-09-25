//! K-07's 401-only RPC retry bridge. Transport failures are never replayed.
const std = @import("std");
const h = @import("host.zig");
const auth = @import("auth.zig");

pub fn intercept(tx: *h.Transaction, effect_id: []const u8, event: std.json.Value) h.ApiError!bool {
    if (tx.state.auth.credential == null or tx.state.auth.blocked) return false;
    const status = try h.field(event, "status");
    if (status != .integer or status.integer != 401) return false;
    for (@constCast(tx.state.rpc.calls)) |*call| {
        if (!h.eq(call.effect_id, effect_id)) continue;
        if (call.auth_retried) {
            // Complete this proven rejection before invalidating other work.
            try h.rpc.complete(tx, effect_id, event);
            try auth.unauthorized(tx, true);
        } else {
            call.auth_retried = true;
            call.awaiting_auth = true;
            try auth.unauthorized(tx, false);
        }
        return true;
    }
    return false;
}

pub fn retryWaiting(tx: *h.Transaction) h.ApiError!void {
    const a = tx.allocator();
    const origin = tx.state.config.https_url orelse return error.InvalidLifecycle;
    for (@constCast(tx.state.rpc.calls)) |*call| {
        if (!call.awaiting_auth) continue;
        const id = try tx.emit("http_request", .{
            .method = "POST",
            .url = try std.fmt.allocPrint(a, "{s}/api/rpc", .{std.mem.trimEnd(u8, origin, "/")}),
            .headers = .{ .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{tx.state.rpc.bearer.?}) }, .{ .name = "Content-Type", .value = "application/json" } },
            .body_base64 = call.body_base64,
            .timeout_ms = call.timeout_ms,
            .max_response_bytes = call.response_cap,
            .tls = .{ .origin = origin, .spki_sha256 = tx.state.rpc.spki_sha256.? },
        });
        try tx.track(.http, id, "rpc");
        call.effect_id = id;
        call.awaiting_auth = false;
    }
}
