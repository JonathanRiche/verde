//! Transactional HTTP RPC engine. Auth supplies a verified runtime/pin and token;
//! sync consumes `takeResult` and `takeFullResync`. No transport or auth I/O here.
const std = @import("std");
const host = @import("host.zig");
const headless = @import("headless");
const protocol = headless.protocol;
const codec = headless.client.codec;
const connection = @import("verde_remote").connection;
const A = std.mem.Allocator;
const V = std.json.Value;
const eq = std.mem.eql;

pub const State = struct {
    bearer: ?[]const u8 = null,
    spki_sha256: ?[]const u8 = null,
    runtime_id: ?[]const u8 = null,
    instance_id: ?[]const u8 = null,
    next_id: u64 = 1,
    phase: connection.Phase = .disabled,
    limits: protocol.RuntimeLimits = .{},
    update_required: bool = false,
    full_resync: bool = false,
    runtime_capabilities: []const []const u8 = &.{},
    calls: []const Call = &.{},
    results: []const Result = &.{},
};
pub const Call = struct {
    effect_id: []const u8,
    id: u64,
    method: []const u8,
    mutation: bool,
    intent_id: ?[]const u8,
    response_cap: usize,
    body_base64: []const u8 = "",
    timeout_ms: u32 = 15000,
    auth_retried: bool = false,
    awaiting_auth: bool = false,
};
/// D-10: `workspace_busy` error data, the only remote error data kept besides
/// `retry_after_ms`. Counts only; never turn or task identities.
pub const Busy = struct { pending_turns: u32 = 0, running_tasks: u32 = 0 };
pub const Result = struct {
    steer_can_fallback: bool = false,
    busy: ?Busy = null,
    id: u64,
    intent_id: ?[]const u8,
    value: ?V = null,
    @"error": ?host.LocalError = null,
};
pub const Options = struct {
    // Conservative default: callers must explicitly identify safe reads.
    mutation: bool = true,
    intent_id: ?[]const u8 = null,
    parked_wait_ms: u32 = 0,
    page_items: ?u32 = null,
    legacy_snapshot: bool = false,
};

/// K-07 calls only after durable trust and token validation. Values are copied.
/// Updating a token never sends or retries a request by itself.
pub fn attachBearer(tx: *host.Transaction, token: []const u8, runtime_id: []const u8, spki_sha256: []const u8) host.ApiError!void {
    connection.validateRuntimeId(runtime_id) catch return error.InvalidArgument;
    if (token.len == 0 or token.len > 8192 or spki_sha256.len == 0 or spki_sha256.len > 256) return error.InvalidArgument;
    for (token) |c| if (c <= 32 or c >= 127) return error.InvalidArgument;
    const s = &tx.state.rpc;
    if (s.runtime_id) |old| if (!eq(u8, old, runtime_id)) return error.InvalidLifecycle;
    s.bearer = try tx.allocator().dupe(u8, token);
    s.runtime_id = try tx.allocator().dupe(u8, runtime_id);
    s.spki_sha256 = try tx.allocator().dupe(u8, spki_sha256);
}

pub fn clearBearer(tx: *host.Transaction) void {
    tx.state.rpc.bearer = null;
}

/// Reconnect always discovers the current instance before sending targeted work.
pub fn beginHandshake(tx: *host.Transaction) host.ApiError!u64 {
    for (tx.state.rpc.calls) |call| if (eq(u8, call.method, "core.status")) return call.id;
    tx.state.rpc.phase = .handshaking;
    tx.state.rpc.full_resync = false;
    tx.state.stale = true;
    tx.changed = true;
    return request(tx, "core.status", .{}, .{ .mutation = false });
}

/// All requests, including parked tails, are independent HTTP effects.
/// Parameters remain the existing daemon wire shape; bounded options must agree
/// with any explicit `wait_ms`/`limit` parameters (checked below).
pub fn request(tx: *host.Transaction, method: []const u8, params: anytype, options: Options) host.ApiError!u64 {
    const s = &tx.state.rpc;
    const a = tx.allocator();
    if (tx.state.lifecycle != .foreground or !tx.state.network_available or s.bearer == null or s.spki_sha256 == null) return error.InvalidLifecycle;
    const status = eq(u8, method, "core.status");
    if (!status and (s.instance_id == null or (s.phase != .ready and !eq(u8, method, "core.capabilities")))) return error.InvalidLifecycle;
    if (s.calls.len + s.results.len >= host.MAX_PENDING or s.next_id == std.math.maxInt(u64)) return error.ResourceLimit;
    if (method.len == 0 or method.len > 128) return error.InvalidArgument;
    if (options.parked_wait_ms > s.limits.max_parked_wait_ms) return error.ResourceLimit;
    if (options.page_items) |count| if (count == 0 or count > s.limits.max_page_items) return error.ResourceLimit;
    if (options.legacy_snapshot and !eq(u8, method, "core.snapshot")) return error.InvalidArgument;
    const params_bytes = try std.json.Stringify.valueAlloc(a, params, .{});
    var params_value = try host.parse(a, params_bytes);
    if (params_value == .array and params_value.array.items.len == 0) params_value = .{ .object = .empty };
    if (params_value != .object) return error.InvalidArgument;
    inline for (.{ "wait_ms", "limit" }) |key| {
        if (params_value.object.get(key)) |v| {
            if (v != .integer or v.integer < 0) return error.InvalidArgument;
            const cap: u32 = if (comptime eq(u8, key, "wait_ms")) options.parked_wait_ms else options.page_items orelse s.limits.max_page_items;
            if (v.integer > cap) return error.ResourceLimit;
        }
    }
    var c = codec.Codec.init(a);
    if (!status) c.request_target = codec.ConfiguredRequestTarget.init(.{ .runtime_id = s.runtime_id.?, .instance_id = s.instance_id.? }) catch return error.InvalidArgument;
    const id = s.next_id;
    const bytes = c.encodeRequestWithId(id, method, params_value) catch |err| return host.mapError(err);
    if (bytes.len > s.limits.max_request_bytes) return error.ResourceLimit;
    const cap = if (options.legacy_snapshot) protocol.MAX_MESSAGE_BYTES else s.limits.max_response_bytes;
    const origin = tx.state.config.https_url orelse return error.InvalidLifecycle;
    const effect_id = try tx.emit("http_request", .{
        .method = "POST",
        .url = try std.fmt.allocPrint(a, "{s}/api/rpc", .{std.mem.trimEnd(u8, origin, "/")}),
        .headers = .{ .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{s.bearer.?}) }, .{ .name = "Content-Type", .value = "application/json" } },
        .body_base64 = try encodeBase64(a, bytes),
        .timeout_ms = options.parked_wait_ms + 15_000,
        .max_response_bytes = cap,
        .tls = .{ .origin = origin, .spki_sha256 = s.spki_sha256.? },
    });
    try tx.track(.http, effect_id, "rpc");
    try append(Call, a, &s.calls, .{ .effect_id = effect_id, .id = id, .method = try a.dupe(u8, method), .mutation = options.mutation, .intent_id = if (options.intent_id) |intent| try a.dupe(u8, intent) else null, .response_cap = cap, .body_base64 = try encodeBase64(a, bytes), .timeout_ms = options.parked_wait_ms + 15_000 });
    s.next_id += 1;
    return id;
}

/// Results are transaction-owned; a consumer must apply them before commit.
pub fn takeResult(tx: *host.Transaction) ?Result {
    const s = &tx.state.rpc;
    if (s.results.len == 0) return null;
    const result = s.results[0];
    s.results = s.results[1..];
    return result;
}

/// K-09 clears all volatile projections/cursors and starts its full snapshot
/// when this flag is consumed. It is set only after the targeted handshake.
pub fn takeFullResync(tx: *host.Transaction) bool {
    const result = tx.state.rpc.full_resync;
    tx.state.rpc.full_resync = false;
    return result;
}

pub fn invalidate(tx: *host.Transaction) host.ApiError!void {
    const s = &tx.state.rpc;
    for (s.calls) |call| try finish(tx, call, null, failure(.network, "cancelled", call.mutation));
    s.calls = &.{};
    s.full_resync = false;
    s.phase = .disabled;
}

/// Called by the host only after validating HTTP shape and effect/generation.
pub fn complete(tx: *host.Transaction, effect_id: []const u8, event: V) host.ApiError!void {
    const s = &tx.state.rpc;
    for (s.calls, 0..) |call, index| {
        if (!eq(u8, call.effect_id, effect_id)) continue;
        const rest = try tx.allocator().alloc(Call, s.calls.len - 1);
        @memcpy(rest[0..index], s.calls[0..index]);
        @memcpy(rest[index..], s.calls[index + 1 ..]);
        s.calls = rest;
        return receive(tx, call, event);
    }
}

fn receive(tx: *host.Transaction, call: Call, event: V) host.ApiError!void {
    const a = tx.allocator();
    const transport = event.object.get("error").?;
    if (transport != .null) {
        const kind = transport.object.get("kind").?.string;
        const class: connection.FailureKind = if (eq(u8, kind, "tls")) .identity else if (eq(u8, kind, "resource")) .resource else if (eq(u8, kind, "server_unavailable")) .server_unavailable else .network;
        var err = failure(class, kind, call.mutation);
        if (eq(u8, kind, "cancelled")) err.retryable = false;
        return finish(tx, call, null, err);
    }
    const status = event.object.get("status").?.integer;
    if (status < 200 or status >= 300) {
        const class: connection.FailureKind = if (status == 401) .authentication else if (status == 403) .authentication else if (status == 429 or status >= 500) .server_unavailable else .wrong_service;
        var err = failure(class, if (status == 403) "scope_denied" else "http_rejected", call.mutation and status >= 500);
        if (status == 403) {
            err.domain = "rpc";
            err.failure_kind = null;
        }
        return finish(tx, call, null, err);
    }
    const body = event.object.get("body_base64").?;
    if (body != .string) return finish(tx, call, null, failure(.protocol, "missing_body", call.mutation));
    const size = std.base64.standard.Decoder.calcSizeForSlice(body.string) catch return error.InvalidArgument;
    if (size > call.response_cap) return finish(tx, call, null, failure(.resource, "response_limit", call.mutation));
    const bytes = try a.alloc(u8, size);
    std.base64.standard.Decoder.decode(bytes, body.string) catch return error.InvalidArgument;
    var c = codec.Codec.init(a);
    var parsed = c.parseResponseWithId(call.id, bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return finish(tx, call, null, failure(.protocol, "invalid_response", call.mutation));
    };
    defer parsed.deinit();
    // Unlike the generic codec, HTTP RPC requires numeric correlation even for errors.
    if (parsed.response.id == null) return finish(tx, call, null, failure(.protocol, "missing_response_id", call.mutation));
    if (parsed.response.err) |remote| {
        if (eq(u8, remote.code, protocol.ERR_PROTOCOL_INCOMPATIBLE)) {
            try tx.invalidateTransport();
            return handshakeFailure(tx, call, .protocol, "update_required");
        }
        if (eq(u8, remote.code, protocol.ERR_RUNTIME_IDENTITY_MISMATCH) and !eq(u8, call.method, "core.status")) {
            // A target rejection proves this call did not run. Rediscover, but do
            // not replay it: the new instance may have different state.
            try finish(tx, call, null, rpcError(remote));
            try tx.invalidateTransport();
            tx.state.stale = true;
            _ = try beginHandshake(tx);
            return;
        }
        try finish(tx, call, null, rpcError(remote));
        if (eq(u8, remote.code, "workspace_busy")) @constCast(&tx.state.rpc.results[tx.state.rpc.results.len - 1]).busy = busyData(remote.data);
        if (eq(u8, call.method, "chat.turn.steer") and eq(u8, remote.code, "invalid_state")) {
            inline for (.{ "provider does not support daemon steering", "turn cannot accept steering now", "provider thread is not ready", "Codex active turn is not ready" }) |message| {
                if (eq(u8, remote.message, message)) @constCast(&tx.state.rpc.results[tx.state.rpc.results.len - 1]).steer_can_fallback = true;
            }
        }
        return;
    }
    if (eq(u8, call.method, "core.status")) {
        const status_result = c.decodeStatus(&parsed) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return handshakeFailure(tx, call, .protocol, "incompatible_protocol");
        };
        return acceptStatus(tx, call, status_result);
    }
    if (eq(u8, call.method, "core.capabilities") and tx.state.rpc.phase == .handshaking) {
        const caps = c.decodeCapabilities(&parsed) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return handshakeFailure(tx, call, .protocol, "invalid_capabilities");
        };
        if (!eq(u8, caps.runtime_id, tx.state.rpc.runtime_id.?)) return handshakeFailure(tx, call, .identity, "runtime_changed");
        if (!eq(u8, caps.instance_id, tx.state.rpc.instance_id.?)) {
            try tx.invalidateTransport();
            _ = try beginHandshake(tx);
            return;
        }
        if (caps.mobile.min_client > tx.state.config.client_revision or caps.protocol.major != protocol.RUNTIME_PROTOCOL_MAJOR) return handshakeFailure(tx, call, .protocol, "update_required");
        const names = try a.alloc([]const u8, caps.runtime_capabilities.len);
        for (caps.runtime_capabilities, names) |name, *copy| copy.* = try a.dupe(u8, name);
        tx.state.rpc.runtime_capabilities = names;
        tx.state.rpc.phase = .ready;
        tx.state.rpc.full_resync = true;
        tx.state.host_error = null;
        tx.changed = true;
        return;
    }
    // The response DOM is freed below; copy it into the transaction arena.
    const value = if (parsed.response.result) |v| (std.json.parseFromSliceLeaky(V, a, try std.json.Stringify.valueAlloc(a, v, .{}), .{ .allocate = .alloc_always }) catch |err| return host.mapError(err)) else .null;
    try finish(tx, call, value, null);
}

fn acceptStatus(tx: *host.Transaction, call: Call, status: protocol.StatusResult) host.ApiError!void {
    protocol.validateRequestTarget(.{ .runtime_id = status.runtime_id, .instance_id = status.instance_id }) catch return handshakeFailure(tx, call, .identity, "invalid_identity");
    if (!eq(u8, status.runtime_id, tx.state.rpc.runtime_id.?)) return handshakeFailure(tx, call, .identity, "runtime_changed");
    connection.validateRuntimeStatus(status) catch return handshakeFailure(tx, call, .protocol, "invalid_limits");
    if (status.protocol.major != protocol.RUNTIME_PROTOCOL_MAJOR or status.mobile.min_client > tx.state.config.client_revision) return handshakeFailure(tx, call, .protocol, "update_required");
    if (tx.state.rpc.instance_id) |old| {
        if (!eq(u8, old, status.instance_id)) {
            try tx.invalidateTransport();
            tx.state.stale = true;
        }
    }
    tx.state.rpc.instance_id = try tx.allocator().dupe(u8, status.instance_id);
    tx.state.rpc.limits = status.limits;
    tx.state.rpc.phase = .handshaking;
    tx.state.rpc.update_required = false;
    tx.state.host_error = null;
    tx.changed = true;
    _ = try request(tx, "core.capabilities", .{}, .{ .mutation = false });
}

fn handshakeFailure(tx: *host.Transaction, call: Call, kind: connection.FailureKind, code: []const u8) host.ApiError!void {
    tx.state.rpc.phase = if (kind == .identity) .awaiting_trust else .failed;
    tx.state.rpc.update_required = kind == .protocol;
    tx.state.host_error = failure(kind, code, false);
    try finish(tx, call, null, tx.state.host_error);
}

fn finish(tx: *host.Transaction, call: Call, value: ?V, err: ?host.LocalError) host.ApiError!void {
    var local = err;
    if (local) |*e| {
        e.intent_id = call.intent_id;
        if (e.rpc_code) |code| e.rpc_code = try tx.allocator().dupe(u8, code);
    }
    try append(Result, tx.allocator(), &tx.state.rpc.results, .{ .id = call.id, .intent_id = call.intent_id, .value = value, .@"error" = local });
    if (err != null and (eq(u8, call.method, "core.status") or eq(u8, call.method, "core.capabilities"))) {
        tx.state.host_error = local;
        if (tx.state.rpc.phase == .handshaking) tx.state.rpc.phase = .failed;
    }
    tx.changed = true;
}

pub fn failure(kind: connection.FailureKind, code: []const u8, uncertain: bool) host.LocalError {
    return .{ .domain = switch (kind) {
        .authentication => "auth",
        .identity => "identity",
        .protocol, .wrong_service => "protocol",
        .resource => "resource",
        else => "transport",
    }, .code = code, .message = "The runtime request could not be completed.", .failure_kind = @tagName(kind), .retryable = kind.retryable(), .delivery = if (uncertain) "uncertain" else "rejected" };
}
fn rpcError(remote: protocol.Error) host.LocalError {
    var err: host.LocalError = .{ .domain = "rpc", .code = "remote_error", .message = "The runtime rejected the request.", .rpc_code = remote.code };
    if (eq(u8, remote.code, protocol.ERR_PROTOCOL_INCOMPATIBLE)) {
        err.failure_kind = "protocol";
    } else if (eq(u8, remote.code, protocol.ERR_RUNTIME_IDENTITY_MISMATCH) or eq(u8, remote.code, protocol.ERR_RUNTIME_IDENTITY_MISSING)) {
        err.failure_kind = "identity";
    } else if (eq(u8, remote.code, protocol.ERR_STORE_BUSY) or eq(u8, remote.code, protocol.ERR_STORE_UNAVAILABLE)) {
        err.failure_kind = "server_unavailable";
        err.retryable = connection.FailureKind.server_unavailable.retryable();
    }
    if (remote.data) |data| {
        if (data == .object) {
            if (data.object.get("retry_after_ms")) |delay| {
                if (delay == .integer and delay.integer >= 0 and delay.integer <= 60_000) err.retry_after_ms = @intCast(delay.integer);
            }
        }
    }
    return err;
}
fn busyData(data: ?V) Busy {
    var out: Busy = .{};
    const object = data orelse return out;
    if (object != .object) return out;
    inline for (.{ "pending_turns", "running_tasks" }) |name| {
        if (object.object.get(name)) |count| {
            if (count == .integer and count.integer >= 0) @field(out, name) = std.math.cast(u32, count.integer) orelse std.math.maxInt(u32);
        }
    }
    return out;
}
fn append(comptime T: type, a: A, slice: *[]const T, item: T) host.ApiError!void {
    const next = try a.alloc(T, slice.len + 1);
    @memcpy(next[0..slice.len], slice.*);
    next[slice.len] = item;
    slice.* = next;
}
pub fn encodeBase64(a: A, bytes: []const u8) host.ApiError![]const u8 {
    const out = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    return std.base64.standard.Encoder.encode(out, bytes);
}
