//! D-12 authenticated workspace file fetch (`/api/file`, `/api/preview`).
//! The core owns the URL, bearer, TLS pin, lifecycle gate and outcome
//! classification. The platform runs `file_fetch` like `http_request`, but
//! keeps the body in its own memory and reports `http_response` without it,
//! so document bytes never enter core JSON, state or receipts.
const std = @import("std");
const h = @import("host.zig");
const auth = @import("auth.zig");
const V = std.json.Value;
const E = h.ApiError;
const A = std.mem.Allocator;
const eq = h.eq;

/// The gateway serves at most 32 MiB (`MAX_SERVED_FILE_BYTES`).
pub const MAX_FILE_BYTES: u32 = 32 * 1024 * 1024;
pub const MAX_PATH_BYTES = 4096;
/// Concurrent fetches per host; a viewer needs one, a retry may briefly overlap.
pub const MAX_FETCHES = 4;
const FILE_TIMEOUT_MS: u32 = 30_000;
/// Office conversion runs LibreOffice on the host.
const PREVIEW_TIMEOUT_MS: u32 = 120_000;

pub const Kind = enum { file, preview };
const Fetch = struct {
    intent_id: []const u8,
    path: []const u8,
    kind: Kind,
    max_bytes: u32,
    /// Empty while waiting for a bearer (connecting or refreshing after a 401).
    effect_id: []const u8 = "",
    auth_retried: bool = false,
};
pub const State = struct { fetches: []const Fetch = &.{} };

pub fn validate(a: A, event: V) E!void {
    const r = try h.decode(struct { path: []const u8, kind: Kind, max_bytes: u32 }, a, event);
    if (r.max_bytes == 0) return error.InvalidArgument;
}

pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!void {
    if (!eq(tag, "file_open")) return;
    const a = tx.allocator();
    const id = try h.string(event, "intent_id");
    const r = try h.decode(struct { path: []const u8, kind: Kind, max_bytes: u32 }, a, event);
    if (!validPath(r.path)) return settle(tx, id, failure("invalid_path", "This file link can't be opened.", false));
    if (tx.state.files.fetches.len >= MAX_FETCHES) return settle(tx, id, failure("busy", "Too many files are loading.", true));
    if (gate(tx)) |err| return settle(tx, id, err);
    const fetch: Fetch = .{ .intent_id = id, .path = r.path, .kind = r.kind, .max_bytes = @min(r.max_bytes, MAX_FILE_BYTES) };
    try add(tx, fetch);
    operation(tx, id, "pending", null);
    try pump(tx);
}

/// Sends waiting fetches once a bearer is attached; fails orphans whose
/// transport was invalidated (background, network change, sign-out).
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.files;
    if (s.fetches.len == 0) return;
    var kept: std.ArrayList(Fetch) = .empty;
    const a = tx.allocator();
    for (s.fetches) |f| {
        var fetch = f;
        if (fetch.effect_id.len > 0 and !tracked(tx, fetch.effect_id)) {
            operation(tx, fetch.intent_id, "failed", failure("cancelled", "Loading was interrupted.", true));
            continue;
        }
        if (fetch.effect_id.len == 0) {
            if (gate(tx)) |err| {
                operation(tx, fetch.intent_id, "failed", err);
                continue;
            }
            if (tx.state.rpc.bearer != null and tx.state.rpc.spki_sha256 != null) fetch.effect_id = try send(tx, fetch);
        }
        try kept.append(a, fetch);
    }
    s.fetches = kept.items;
}

/// Called after the host matched and removed the pending `http` entry.
pub fn complete(tx: *h.Transaction, p: h.Pending, event: V) E!bool {
    if (p.kind != .http or !eq(p.key, "file")) return false;
    const s = &tx.state.files;
    for (s.fetches, 0..) |f, i| {
        if (!eq(f.effect_id, p.id)) continue;
        const rest = try tx.allocator().alloc(Fetch, s.fetches.len - 1);
        @memcpy(rest[0..i], s.fetches[0..i]);
        @memcpy(rest[i..], s.fetches[i + 1 ..]);
        s.fetches = rest;
        const transport = try h.field(event, "error");
        if (transport != .null) {
            operation(tx, f.intent_id, "failed", transportFailure(try h.string(transport, "kind")));
            return true;
        }
        const status = try h.integer(event, "status");
        if (status == 401 and !f.auth_retried and tx.state.auth.credential != null and !tx.state.auth.blocked) {
            // One refresh-and-retry, like the RPC bridge; the token is re-minted by K-07.
            var retry = f;
            retry.effect_id = "";
            retry.auth_retried = true;
            try add(tx, retry);
            try auth.unauthorized(tx, false);
            return true;
        }
        if (status >= 200 and status < 300) {
            operation(tx, f.intent_id, "succeeded", null);
        } else operation(tx, f.intent_id, "failed", statusFailure(status));
        return true;
    }
    return true;
}

fn send(tx: *h.Transaction, f: Fetch) E![]const u8 {
    const a = tx.allocator();
    const origin = tx.state.config.https_url orelse return error.InvalidLifecycle;
    var url: std.ArrayList(u8) = .empty;
    try url.appendSlice(a, std.mem.trimEnd(u8, origin, "/"));
    try url.appendSlice(a, if (f.kind == .preview) "/api/preview?path=" else "/api/file?path=");
    for (f.path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '/') {
            try url.append(a, c);
        } else try url.print(a, "%{X:0>2}", .{c});
    }
    const id = try tx.emit("file_fetch", .{
        .intent_id = f.intent_id,
        .url = url.items,
        .headers = .{.{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{tx.state.rpc.bearer.?}) }},
        .timeout_ms = if (f.kind == .preview) PREVIEW_TIMEOUT_MS else FILE_TIMEOUT_MS,
        .max_response_bytes = f.max_bytes,
        .tls = .{ .origin = origin, .spki_sha256 = tx.state.rpc.spki_sha256.? },
    });
    try tx.track(.http, id, "file");
    return id;
}

/// Null while a fetch may proceed (now or once auth attaches a bearer).
fn gate(tx: *h.Transaction) ?h.LocalError {
    const s = &tx.state;
    if (!s.network_available) return failure("offline", "You're offline.", true);
    if (s.lifecycle != .foreground) return failure("cancelled", "Loading was interrupted.", true);
    if (s.config.https_url == null or s.auth.blocked or !(eq(s.auth_state, "paired") or eq(s.auth_state, "loading")))
        return failure("unavailable", "This host isn't connected.", true);
    return null;
}

fn tracked(tx: *h.Transaction, id: []const u8) bool {
    for (tx.state.pending) |p| if (p.kind == .http and eq(p.id, id)) return true;
    return false;
}

fn add(tx: *h.Transaction, f: Fetch) E!void {
    const a = tx.allocator();
    const old = tx.state.files.fetches;
    const next = try a.alloc(Fetch, old.len + 1);
    @memcpy(next[0..old.len], old);
    next[old.len] = f;
    tx.state.files.fetches = next;
}

/// Mirrors the gateway's lexical gate: absolute, no NUL/controls, no `..`.
fn validPath(path: []const u8) bool {
    if (path.len < 2 or path.len > MAX_PATH_BYTES or path[0] != '/') return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |c| if (c < 0x20 or c == 0x7f) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (eq(part, "..")) return false;
    return true;
}

fn failure(code: []const u8, message: []const u8, retryable: bool) h.LocalError {
    return .{ .domain = "file", .code = code, .message = message, .retryable = retryable };
}

fn statusFailure(status: i64) h.LocalError {
    return switch (status) {
        401 => failure("unauthorized", "This phone's access was refused.", true),
        403 => failure("forbidden", "This file is outside the host's workspaces.", false),
        404 => failure("not_found", "This file no longer exists on the host.", false),
        413 => failure("too_large", "This file is too large to open on the phone.", false),
        400, 415 => failure("unsupported", "This file type can't be shown.", false),
        501 => failure("preview_unavailable", "Previews need LibreOffice on the host.", false),
        429, 500, 502...599 => failure("server_unavailable", "The host couldn't serve this file.", true),
        else => failure("http_rejected", "The host couldn't serve this file.", false),
    };
}

fn transportFailure(kind: []const u8) h.LocalError {
    if (eq(kind, "resource")) return failure("too_large", "This file is too large to open on the phone.", false);
    if (eq(kind, "tls")) return failure("identity", "The host's identity couldn't be verified.", false);
    if (eq(kind, "timeout")) return failure("timeout", "The host took too long to respond.", true);
    if (eq(kind, "cancelled")) return failure("cancelled", "Loading was interrupted.", true);
    return failure("offline", "The host isn't reachable.", true);
}

fn settle(tx: *h.Transaction, id: []const u8, err: h.LocalError) void {
    operation(tx, id, "failed", err);
}

fn operation(tx: *h.Transaction, id: []const u8, state: []const u8, err: ?h.LocalError) void {
    for (@constCast(tx.state.receipts)) |*r| if (eq(r.operation.intent_id, id)) {
        r.operation.state = state;
        r.operation.@"error" = err;
        if (r.operation.@"error") |*e| e.intent_id = id;
    };
    tx.changed = true;
}
