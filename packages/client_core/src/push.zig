//! K-17 push: the pure notification opener used by a notification service or
//! extension without a running host, the per-host push key record, and the
//! `push_register` intent that calls `device.push.register`.
//!
//! Secrets never leave this module except inside the secure-store record the
//! core writes itself. Nothing here logs payloads, keys or tokens.
const std = @import("std");
const h = @import("host.zig");
const seal = @import("headless").push_seal;
const rpc = h.rpc;
const A = std.mem.Allocator;
const V = std.json.Value;
const E = h.ApiError;
const b64url = std.base64.url_safe_no_pad;
const X25519 = std.crypto.dh.X25519;

/// Secure-store record name: `vc/1/<host_id>/push`.
pub const RECORD = "push";
/// `vc_push_open` request bound: a few host records plus one envelope.
pub const MAX_OPEN_INPUT = 64 * 1024;
pub const MAX_KEYS = 32;
pub const MAX_RECENT = 256;
pub const MAX_SEND_TOKEN = 4096;
pub const GENERIC_TITLE = "Verde";
pub const GENERIC_BODY = "A Verde chat needs attention";
const MAX_ID = 256;
const MAX_TITLE = 120;
const MAX_SNIPPET = 200;

/// Value of `vc/1/<host_id>/push`. Keys are base64url without padding.
/// `runtime_id` binds the key to the runtime it was registered with.
pub const Record = struct { version: u32 = 1, runtime_id: []const u8, public_key: []const u8, secret_key: []const u8 };

/// One candidate key: `record_base64` is the unmodified secure-store value.
pub const OpenKey = struct { host_id: []const u8, record_base64: []const u8 };
/// `vc_push_open` input. `recent` holds dedupe keys the platform already showed.
pub const OpenRequest = struct { api_version: u32, envelope: []const u8, keys: []const OpenKey, recent: ?[]const []const u8 = null };

/// Typed notification view model. A generic model (`opened == false`) is
/// always safe to display: it carries no decrypted content.
pub const Notification = struct {
    api_version: u32,
    opened: bool,
    update_required: bool,
    /// invalid_envelope, envelope_too_large, unsupported_version,
    /// authentication_failed, no_key or invalid_payload; null when opened.
    @"error": ?[]const u8,
    host_id: ?[]const u8,
    workspace_id: ?[]const u8,
    thread_id: ?[]const u8,
    turn_id: ?[]const u8,
    /// completed, failed, aborted, approval_pending, input_needed, test,
    /// other (unknown daemon kind) or generic.
    kind: []const u8,
    /// Attention the event raises: unread, needs_approval, blocked, failed.
    attention: ?[]const u8,
    /// Platform channel/category: attention or completed.
    channel: []const u8,
    title: []const u8,
    body: []const u8,
    deep_link: []const u8,
    /// Subset of open, approve, deny, reply.
    actions: []const []const u8,
    /// Host-scoped `host_id:turn_id:kind`; also the in-app `notify` id.
    dedupe_key: ?[]const u8,
    duplicate: bool,
};

/// Plaintext sealed by the daemon (A-14 `push.Payload`).
const Payload = struct { runtime_id: []const u8, workspace_id: []const u8 = "", thread_id: []const u8 = "", turn_id: []const u8 = "", kind: []const u8, title: []const u8 = "", snippet: []const u8 = "" };

pub fn generic(code: ?[]const u8) Notification {
    return .{ .api_version = 1, .opened = false, .update_required = false, .@"error" = code, .host_id = null, .workspace_id = null, .thread_id = null, .turn_id = null, .kind = "generic", .attention = null, .channel = "attention", .title = GENERIC_TITLE, .body = GENERIC_BODY, .deep_link = "verde://open", .actions = &.{"open"}, .dedupe_key = null, .duplicate = false };
}

/// Pure entry point behind `vc_push_open`: no host, clock, entropy or globals.
/// Request-shape errors return ApiError; every envelope, key or payload
/// failure returns the generic model instead.
pub fn open(a: A, input: []const u8) E!Notification {
    if (input.len > MAX_OPEN_INPUT) return error.ResourceLimit;
    const value = try h.parseLimit(a, input, MAX_OPEN_INPUT);
    if (value != .object or (value.object.get("api_version") orelse V.null) != .integer) return error.InvalidArgument;
    if (value.object.get("api_version").?.integer != 1) return error.UnsupportedVersion;
    const request = try h.decode(OpenRequest, a, value);
    const recent = request.recent orelse &.{};
    if (request.keys.len > MAX_KEYS or recent.len > MAX_RECENT) return error.ResourceLimit;
    var failure: ?[]const u8 = "no_key";
    for (request.keys) |candidate| {
        var secret: [seal.SECRET_KEY_LENGTH]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret);
        const record = decodeRecord(a, candidate.record_base64, &secret) orelse continue;
        const plaintext = seal.open(a, secret, request.envelope) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AuthenticationFailed => {
                failure = "authentication_failed";
                continue;
            },
            // Envelope-level failures do not depend on the key.
            error.UnsupportedVersion => {
                var model = generic("unsupported_version");
                model.update_required = true;
                return model;
            },
            error.EnvelopeTooLarge => return generic("envelope_too_large"),
            error.InvalidEnvelope => return generic("invalid_envelope"),
        };
        defer std.crypto.secureZero(u8, plaintext);
        return notification(a, candidate.host_id, record.runtime_id, plaintext, recent) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => generic("invalid_payload"),
        };
    }
    return generic(failure);
}

/// Scratch bound for one `openJson` call; zeroed afterwards because it held
/// the key records and plaintext. Keeps notification extensions well inside
/// their memory limit.
pub const OPEN_SCRATCH = 512 * 1024;

/// `vc_push_open`: returns caller-owned JSON of `Notification`.
pub fn openJson(out: A, input: []const u8) E![]u8 {
    if (input.len > MAX_OPEN_INPUT) return error.ResourceLimit;
    const scratch = try std.heap.page_allocator.alloc(u8, OPEN_SCRATCH);
    defer std.heap.page_allocator.free(scratch);
    defer std.crypto.secureZero(u8, scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const model = try open(fixed.allocator(), input);
    return h.encode(out, model);
}

/// Decode a stored record and copy its secret into `secret`; null if invalid.
fn decodeRecord(a: A, record_base64: []const u8, secret: *[seal.SECRET_KEY_LENGTH]u8) ?Record {
    const bytes = @import("auth.zig").decode64(a, record_base64) catch return null;
    defer std.crypto.secureZero(u8, @constCast(bytes));
    const record = parseRecord(a, bytes) orelse return null;
    decodeKey(record.secret_key, secret) catch return null;
    std.crypto.secureZero(u8, @constCast(record.secret_key));
    return record;
}
pub fn parseRecord(a: A, bytes: []const u8) ?Record {
    const record = std.json.parseFromSliceLeaky(Record, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    if (record.version != 1 or record.runtime_id.len == 0 or record.runtime_id.len > MAX_ID) return null;
    var secret: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    var public: [32]u8 = undefined;
    decodeKey(record.secret_key, &secret) catch return null;
    decodeKey(record.public_key, &public) catch return null;
    const derived = X25519.recoverPublicKey(secret) catch return null;
    if (!std.mem.eql(u8, &derived, &public)) return null;
    return record;
}
fn decodeKey(text: []const u8, out: *[32]u8) error{Invalid}!void {
    if (text.len != 43) return error.Invalid;
    b64url.Decoder.decode(out, text) catch return error.Invalid;
    var canonical: [43]u8 = undefined;
    if (!std.mem.eql(u8, b64url.Encoder.encode(&canonical, out), text)) return error.Invalid;
}

const Kind = struct { name: []const u8, attention: ?[]const u8, channel: []const u8, label: []const u8 };
fn kindOf(kind: []const u8) Kind {
    // "done" and "approval" are older daemon/fixture spellings.
    if (h.eq(kind, "completed") or h.eq(kind, "done")) return .{ .name = "completed", .attention = "unread", .channel = "completed", .label = "Reply ready" };
    if (h.eq(kind, "failed")) return .{ .name = "failed", .attention = "failed", .channel = "attention", .label = "Turn failed" };
    if (h.eq(kind, "aborted")) return .{ .name = "aborted", .attention = null, .channel = "completed", .label = "Turn stopped" };
    if (h.eq(kind, "approval_pending") or h.eq(kind, "approval")) return .{ .name = "approval_pending", .attention = "needs_approval", .channel = "attention", .label = "Needs approval" };
    if (h.eq(kind, "input_needed")) return .{ .name = "input_needed", .attention = "blocked", .channel = "attention", .label = "Needs input" };
    if (h.eq(kind, "test")) return .{ .name = "test", .attention = null, .channel = "completed", .label = "Test notification" };
    return .{ .name = "other", .attention = null, .channel = "attention", .label = GENERIC_BODY };
}

fn notification(a: A, host_id: []const u8, runtime_id: []const u8, plaintext: []const u8, recent: []const []const u8) !Notification {
    const payload = try std.json.parseFromSliceLeaky(Payload, a, plaintext, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (!h.eq(payload.runtime_id, runtime_id)) return error.InvalidPayload;
    if (payload.kind.len == 0 or payload.kind.len > 64) return error.InvalidPayload;
    for ([_][]const u8{ host_id, payload.workspace_id, payload.thread_id, payload.turn_id }) |id| {
        if (id.len > MAX_ID) return error.InvalidPayload;
        for (id) |c| if (c < 0x20 or c == 0x7f) return error.InvalidPayload;
    }
    if (host_id.len == 0) return error.InvalidPayload;
    const kind = kindOf(payload.kind);
    const snippet = try clean(a, payload.snippet, MAX_SNIPPET, true);
    const title = try clean(a, payload.title, MAX_TITLE, false);
    const body = if (h.eq(kind.name, "completed") and snippet.len > 0) snippet else if (snippet.len > 0 and !h.eq(kind.name, "aborted") and !h.eq(kind.name, "other")) try std.fmt.allocPrint(a, "{s}: {s}", .{ kind.label, snippet }) else kind.label;
    const has_thread = payload.workspace_id.len > 0 and payload.thread_id.len > 0;
    var actions: std.ArrayList([]const u8) = .empty;
    try actions.append(a, "open");
    if (has_thread and payload.turn_id.len > 0 and h.eq(kind.name, "approval_pending")) try actions.appendSlice(a, &.{ "approve", "deny" });
    if (has_thread and (h.eq(kind.name, "completed") or h.eq(kind.name, "input_needed"))) try actions.append(a, "reply");
    const dedupe: ?[]const u8 = if (payload.turn_id.len > 0 and !h.eq(kind.name, "test")) try dedupeKey(a, host_id, payload.turn_id, kind.name) else null;
    var duplicate = false;
    if (dedupe) |key| for (recent) |seen| {
        if (h.eq(seen, key)) duplicate = true;
    };
    return .{
        .api_version = 1,
        .opened = true,
        .update_required = false,
        .@"error" = null,
        .host_id = host_id,
        .workspace_id = if (has_thread) payload.workspace_id else null,
        .thread_id = if (has_thread) payload.thread_id else null,
        .turn_id = if (payload.turn_id.len > 0) payload.turn_id else null,
        .kind = kind.name,
        .attention = kind.attention,
        .channel = kind.channel,
        .title = if (title.len > 0) title else GENERIC_TITLE,
        .body = body,
        .deep_link = try deepLink(a, host_id, if (has_thread) payload.workspace_id else null, if (has_thread) payload.thread_id else null),
        .actions = try actions.toOwnedSlice(a),
        .dedupe_key = dedupe,
        .duplicate = duplicate,
    };
}

/// Shared by pushes and in-app `notify` effects so platforms collapse both.
pub fn dedupeKey(a: A, host_id: []const u8, turn_id: []const u8, kind: []const u8) E![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ host_id, turn_id, kind });
}

/// `verde://open?host_id=…[&workspace_id=…&thread_id=…]`, percent-encoded.
pub fn deepLink(a: A, host_id: []const u8, workspace_id: ?[]const u8, thread_id: ?[]const u8) E![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "verde://open?host_id=");
    try percent(a, &out, host_id);
    if (workspace_id != null and thread_id != null) {
        try out.appendSlice(a, "&workspace_id=");
        try percent(a, &out, workspace_id.?);
        try out.appendSlice(a, "&thread_id=");
        try percent(a, &out, thread_id.?);
    }
    return out.toOwnedSlice(a);
}
fn percent(a: A, out: *std.ArrayList(u8), text: []const u8) E!void {
    const hex = "0123456789ABCDEF";
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try out.append(a, byte) else try out.appendSlice(a, &.{ '%', hex[byte >> 4], hex[byte & 15] });
    }
}

/// Collapse control characters and bound display text by code points.
fn clean(a: A, text: []const u8, max: usize, keep_newlines: bool) E![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidArgument;
    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        if (count == max) {
            try out.appendSlice(a, "…");
            break;
        }
        const c = slice[0];
        if (slice.len == 1 and (c < 0x20 or c == 0x7f)) {
            try out.append(a, if (keep_newlines and c == '\n') '\n' else ' ');
        } else try out.appendSlice(a, slice);
        count += 1;
    }
    return std.mem.trim(u8, out.items, " \n");
}

// ---------------------------------------------------------------------------
// Registration flow (host side).

pub const State = struct {
    intent_id: ?[]const u8 = null,
    phase: enum { idle, loading, saving, registering } = .idle,
    platform: []const u8 = "",
    /// Held only until the RPC is issued; never persisted or logged.
    send_token: []const u8 = "",
    seed_base64: []const u8 = "",
    public_key: []const u8 = "",
    store_id: ?[]const u8 = null,
    rpc_id: ?u64 = null,
};

fn operation(tx: *h.Transaction, id: []const u8, state: []const u8, failure: ?h.LocalError) void {
    for (@constCast(tx.state.receipts)) |*receipt| if (h.eq(receipt.operation.intent_id, id)) {
        receipt.operation.state = state;
        receipt.operation.@"error" = failure;
    };
    tx.changed = true;
}
fn finish(tx: *h.Transaction, state: []const u8, failure: ?h.LocalError) void {
    const id = tx.state.push.intent_id orelse return;
    operation(tx, id, state, failure);
    tx.state.push = .{};
}
fn fail(code: []const u8) h.LocalError {
    return .{ .domain = "push", .code = code, .message = "Push notifications could not be registered.", .retryable = true };
}
fn online(tx: *h.Transaction) bool {
    return tx.state.lifecycle == .foreground and tx.state.network_available and tx.state.rpc.phase == .ready and tx.state.rpc.bearer != null and tx.state.rpc.runtime_id != null;
}
fn scope(tx: *h.Transaction, name: []const u8) bool {
    const credential = tx.state.auth.credential orelse return false;
    for (credential.scopes) |s| if (h.eq(s, name)) return true;
    return false;
}
pub fn recordKey(tx: *h.Transaction) E![]const u8 {
    return std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/" ++ RECORD, .{tx.state.config.host_id});
}

/// Shape checks run before the receipt is recorded.
pub fn validate(a: A, event: V) E!void {
    const r = try h.decode(struct { platform: []const u8, send_token: []const u8, key_seed_base64: []const u8 }, a, event);
    if (!h.eq(r.platform, "android") and !h.eq(r.platform, "ios")) return error.InvalidArgument;
    if (r.send_token.len == 0 or r.send_token.len > MAX_SEND_TOKEN) return error.InvalidArgument;
    for (r.send_token) |c| if (c < 0x21 or c > 0x7e) return error.InvalidArgument;
    const seed = try @import("auth.zig").decode64(a, r.key_seed_base64);
    defer std.crypto.secureZero(u8, @constCast(seed));
    if (seed.len != X25519.seed_length) return error.InvalidArgument;
}

pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!bool {
    if (!h.eq(tag, "push_register")) return false;
    const id = try h.string(event, "intent_id");
    const s = &tx.state.push;
    if (s.intent_id != null) {
        operation(tx, id, "failed", fail("registration_in_progress"));
        return true;
    }
    if (!scope(tx, "device:write")) {
        operation(tx, id, "failed", .{ .domain = "push", .code = "insufficient_scope", .message = "This device may not register for push notifications." });
        return true;
    }
    if (!online(tx) or tx.state.auth.removal.wiping) {
        operation(tx, id, "failed", fail("unavailable"));
        return true;
    }
    s.* = .{ .intent_id = id, .phase = .loading, .platform = try h.string(event, "platform"), .send_token = try h.string(event, "send_token"), .seed_base64 = try h.string(event, "key_seed_base64") };
    const key = try recordKey(tx);
    const effect = try tx.emit("secure_store_get", .{ .key = key });
    try tx.track(.store_get, effect, key);
    s.store_id = effect;
    operation(tx, id, "pending", null);
    return true;
}

pub fn complete(tx: *h.Transaction, p: h.Pending, event: V) E!bool {
    const s = &tx.state.push;
    if (s.store_id == null or !h.eq(s.store_id.?, p.id)) return false;
    s.store_id = null;
    tx.changed = true;
    if ((try h.field(event, "error")) != .null) {
        finish(tx, "failed", .{ .domain = "storage", .code = "push_key_unavailable", .message = "The push key could not be stored. Unlock the device and retry.", .retryable = true });
        return true;
    }
    const a = tx.allocator();
    const runtime = tx.state.rpc.runtime_id orelse {
        finish(tx, "failed", fail("unavailable"));
        return true;
    };
    if (s.phase == .loading) {
        const stored = try h.field(event, "value_base64");
        if (stored == .string) {
            const bytes = @import("auth.zig").decode64(a, stored.string) catch null;
            if (bytes) |b| if (parseRecord(a, b)) |record| if (h.eq(record.runtime_id, runtime)) {
                s.public_key = record.public_key;
                return register(tx);
            };
        }
        // Missing, corrupt or bound to another runtime: replace it.
        var seed: [X25519.seed_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        const decoded = try @import("auth.zig").decode64(a, s.seed_base64);
        @memcpy(&seed, decoded);
        std.crypto.secureZero(u8, @constCast(decoded));
        const pair = X25519.KeyPair.generateDeterministic(seed) catch {
            finish(tx, "failed", fail("invalid_key_seed"));
            return true;
        };
        var public_text: [43]u8 = undefined;
        var secret_text: [43]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret_text);
        const record: Record = .{ .runtime_id = runtime, .public_key = b64url.Encoder.encode(&public_text, &pair.public_key), .secret_key = b64url.Encoder.encode(&secret_text, &pair.secret_key) };
        const bytes = try h.encode(a, record);
        const key = try recordKey(tx);
        const effect = try tx.emit("secure_store_put", .{ .key = key, .value_base64 = try rpc.encodeBase64(a, bytes) });
        std.crypto.secureZero(u8, bytes);
        try tx.track(.store_put, effect, key);
        s.store_id = effect;
        s.public_key = try a.dupe(u8, &public_text);
        s.seed_base64 = "";
        s.phase = .saving;
        return true;
    }
    return register(tx);
}

fn register(tx: *h.Transaction) E!bool {
    const s = &tx.state.push;
    s.seed_base64 = "";
    if (!online(tx)) {
        finish(tx, "failed", fail("unavailable"));
        return true;
    }
    s.rpc_id = rpc.request(tx, "device.push.register", .{ .platform = s.platform, .send_token = s.send_token, .public_key = s.public_key }, .{ .intent_id = s.intent_id }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            finish(tx, "failed", fail("unavailable"));
            return true;
        },
    };
    s.send_token = "";
    s.phase = .registering;
    return true;
}

/// Consume only the correlated registration result.
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.push;
    const id = s.rpc_id orelse return;
    for (tx.state.rpc.results, 0..) |result, index| {
        if (result.id != id) continue;
        const rest = try tx.allocator().alloc(rpc.Result, tx.state.rpc.results.len - 1);
        @memcpy(rest[0..index], tx.state.rpc.results[0..index]);
        @memcpy(rest[index..], tx.state.rpc.results[index + 1 ..]);
        tx.state.rpc.results = rest;
        if (result.@"error") |failure| {
            finish(tx, "failed", failure);
        } else if (result.value != null and result.value.? == .object and (result.value.?.object.get("accepted") orelse V.null) == .bool and result.value.?.object.get("accepted").?.bool) {
            finish(tx, "succeeded", null);
        } else finish(tx, "failed", .{ .domain = "protocol", .code = "invalid_response", .message = "The runtime returned an invalid push registration.", .delivery = "uncertain" });
        return;
    }
}
