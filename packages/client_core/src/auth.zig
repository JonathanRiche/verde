//! Sans-IO authentication. Secrets occur only in retained private state and
//! explicitly secret-bearing platform effects, never in diagnostics or queries.
const std = @import("std");
const h = @import("host.zig");
const remote = @import("verde_remote");
const access = @import("headless").access_protocol;
const V = std.json.Value;
const E = h.ApiError;
const eq = h.eq;

pub const Pin = struct {
    version: u32 = 1,
    origin: []const u8,
    wss_url: []const u8,
    spki_sha256: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
};
pub const Proposal = @import("wire.zig").TrustProposal;
pub const Credential = struct { version: u32 = 1, runtime_id: []const u8, device_id: []const u8, device_credential: []const u8, scopes: []const []const u8 };
const Pair = struct { origin: []const u8, grant_id: []const u8, code: []const u8, nonce: []const u8, label: []const u8, intent_id: []const u8 };
pub const State = struct {
    profile_loaded: bool = false,
    credential_loaded: bool = false,
    pin: ?Pin = null,
    credential: ?Credential = null,
    proposal: ?Proposal = null,
    candidate: ?Pin = null,
    pair: ?Pair = null,
    phase: []const u8 = "disabled",
    blocked: bool = false,
    stop_pending: bool = false,
    verified: bool = false,
    observed_spki: ?[]const u8 = null,
    idempotent: bool = false,
    token: ?[]const u8 = null,
    expires_at_ms: i64 = 0,
    unauthorized_retried: bool = false,
    need_ticket: bool = true,
    retry: ?[]const u8 = null,
    retry_attempt: u8 = 0,
    retry_at_ms: ?i64 = null,
    trust_intent: ?[]const u8 = null,
    storage_retry: ?h.Pending = null,
};

pub fn encode64(a: std.mem.Allocator, bytes: []const u8) E![]const u8 {
    const out = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    return std.base64.standard.Encoder.encode(out, bytes);
}
pub fn decode64(a: std.mem.Allocator, bytes: []const u8) E![]const u8 {
    const n = std.base64.standard.Decoder.calcSizeForSlice(bytes) catch return error.InvalidArgument;
    if (n > 64 * 1024) return error.ResourceLimit;
    const out = try a.alloc(u8, n);
    std.base64.standard.Decoder.decode(out, bytes) catch return error.InvalidArgument;
    return out;
}
fn hex(s: []const u8, n: usize) bool {
    if (s.len != n) return false;
    for (s) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
fn component(a: std.mem.Allocator, s: []const u8) E![]const u8 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len or !std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return error.InvalidArgument;
            i += 2;
        }
    }
    return std.Uri.percentDecodeInPlace(try a.dupe(u8, s));
}
/// Only the exact native route or HTTPS App Link route is accepted. Fragment
/// secrets never become an HTTP URL, query parameter, or persisted profile.
pub fn parseLink(a: std.mem.Allocator, link: []const u8) E!struct { origin: []const u8, grant_id: []const u8, code: []const u8 } {
    const prefixes = [_][]const u8{ "verde://pair?", "https://verdeai.dev/pair?" };
    var rest: ?[]const u8 = null;
    for (prefixes) |prefix| if (std.mem.startsWith(u8, link, prefix)) {
        rest = link[prefix.len..];
        break;
    };
    const s = rest orelse return error.InvalidArgument;
    const fragment = std.mem.indexOfScalar(u8, s, '#') orelse return error.InvalidArgument;
    const secret = s[fragment + 1 ..];
    if (!std.mem.startsWith(u8, secret, "code=")) return error.InvalidArgument;
    const code = try component(a, secret[5..]);
    if (!hex(code, 64)) return error.InvalidArgument;
    var host: ?[]const u8 = null;
    var grant: ?[]const u8 = null;
    var parts = std.mem.splitScalar(u8, s[0..fragment], '&');
    while (parts.next()) |part| {
        const split = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidArgument;
        const key = part[0..split];
        const value = try component(a, part[split + 1 ..]);
        if (eq(key, "host") and host == null) host = value else if (eq(key, "grant_id") and grant == null) grant = value else return error.InvalidArgument;
    }
    const origin = host orelse return error.InvalidArgument;
    const id = grant orelse return error.InvalidArgument;
    if (!hex(id, 32)) return error.InvalidArgument;
    const normalized = remote.profile.sanitizedRuntimeHttpsOriginAlloc(a, origin) catch |err| return h.mapError(err);
    if (!eq(normalized, origin)) return error.InvalidArgument;
    return .{ .origin = origin, .grant_id = id, .code = code };
}
fn operation(tx: *h.Transaction, id: []const u8, state: []const u8, failure: ?h.LocalError) void {
    for (@constCast(tx.state.receipts)) |*receipt| if (eq(receipt.operation.intent_id, id)) {
        receipt.operation.state = state;
        receipt.operation.@"error" = failure;
        tx.changed = true;
        return;
    };
}
fn fail(tx: *h.Transaction, code: []const u8, retryable: bool) void {
    tx.state.host_error = .{ .domain = "auth", .code = code, .message = "Authentication could not complete.", .retryable = retryable };
    tx.state.auth.phase = "failed";
    tx.state.auth.blocked = !retryable;
    if (!retryable) {
        tx.state.auth.stop_pending = true;
        if (tx.state.auth.pair) |pair| operation(tx, pair.intent_id, "failed", tx.state.host_error);
        tx.state.auth.pair = null;
    }
    tx.changed = true;
}
fn has(tx: *h.Transaction, key: []const u8) bool {
    for (tx.state.pending) |p| if (eq(p.key, key) or eq(p.purpose, key)) return true;
    return false;
}
fn storagePending(tx: *h.Transaction) bool {
    for (tx.state.pending) |p| if (p.kind == .store_put or p.kind == .store_get or p.kind == .store_delete) return true;
    return false;
}
fn store(tx: *h.Transaction, record: []const u8, value: anytype) E!void {
    const a = tx.allocator();
    const key = try std.fmt.allocPrint(a, "vc/1/{s}/{s}", .{ tx.state.config.host_id, record });
    const id = try tx.emit("secure_store_put", .{ .key = key, .value_base64 = try encode64(a, try h.encode(a, value)) });
    try tx.track(.store_put, id, key);
}
pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!bool {
    const s = &tx.state.auth;
    const id = try h.string(event, "intent_id");
    if (eq(tag, "pair")) {
        if (!s.profile_loaded or !s.credential_loaded or storagePending(tx) or tx.state.lifecycle != .foreground) return error.InvalidLifecycle;
        const link = try parseLink(tx.allocator(), try h.string(event, "link"));
        const nonce = try h.string(event, "client_nonce");
        const label = try h.string(event, "device_label");
        if (!hex(nonce, 32)) return error.InvalidArgument;
        access.validateDeviceLabel(label) catch return error.InvalidArgument;
        if (s.pair != null) return error.InvalidLifecycle;
        suspendSession(tx);
        try tx.invalidateTransport();
        s.pair = .{ .origin = link.origin, .grant_id = link.grant_id, .code = link.code, .nonce = nonce, .label = label, .intent_id = id };
        s.blocked = false;
        s.token = null;
        s.unauthorized_retried = false;
        tx.state.host_error = null;
        operation(tx, id, "pending", null);
    } else if (eq(tag, "trust_decision")) {
        const proposal = s.proposal orelse return error.InvalidArgument;
        if (!eq(proposal.id, try h.string(event, "proposal_id"))) return error.InvalidArgument;
        s.proposal = null;
        if (!try h.boolean(event, "accept")) {
            s.blocked = true;
            s.phase = "disabled";
            if (s.pair) |pair| operation(tx, pair.intent_id, "failed", .{ .domain = "tls", .code = "trust_denied", .message = "Host trust was denied." });
            s.pair = null;
            s.candidate = null;
            operation(tx, id, "succeeded", null);
        } else {
            s.trust_intent = id;
            operation(tx, id, "pending", null);
            try store(tx, "profile", s.candidate.?);
        }
    } else if (eq(tag, "retry_connection")) {
        if (s.storage_retry) |pending| {
            s.storage_retry = null;
            s.blocked = false;
            if (pending.kind == .store_get) {
                for ([_][]const u8{ "profile", "credential" }, [_]bool{ s.profile_loaded, s.credential_loaded }) |record, loaded| {
                    if (loaded) continue;
                    const key = try std.fmt.allocPrint(tx.allocator(), "vc/1/{s}/{s}", .{ tx.state.config.host_id, record });
                    if (has(tx, key)) continue;
                    const effect_id = try tx.emit("secure_store_get", .{ .key = key });
                    try tx.track(.store_get, effect_id, key);
                }
            } else if (std.mem.endsWith(u8, pending.key, "/profile")) {
                try store(tx, "profile", s.candidate.?);
            } else try store(tx, "credential", s.credential.?);
        } else if (s.blocked or (!s.profile_loaded and !s.credential_loaded)) return false;
        s.retry = null;
        tx.state.host_error = null;
        operation(tx, id, "succeeded", null);
    } else return false;
    tx.changed = true;
    return true;
}
/// External lifecycle/trust changes require another probe and clear RPC auth.
pub fn suspendSession(tx: *h.Transaction) void {
    tx.state.auth.verified = false;
    tx.state.auth.observed_spki = null;
    tx.state.auth.token = null;
    h.rpc.clearBearer(tx);
}
pub fn invalidated(tx: *h.Transaction) void {
    const s = &tx.state.auth;
    if (s.pair != null and has(tx, "auth_exchange") and !s.idempotent) {
        operation(tx, s.pair.?.intent_id, "uncertain", .{ .domain = "auth", .code = "exchange_uncertain", .message = "Create a new pairing grant.", .delivery = "uncertain" });
        s.pair = null;
        s.blocked = true;
    }
    s.proposal = null;
    // A pending profile write retains its candidate across backgrounding.
    if (!storagePending(tx)) s.candidate = null;
    s.need_ticket = true;
    s.retry = null;
    s.retry_at_ms = null;
    s.phase = "disabled";
}
fn endpoint(tx: *h.Transaction) ?[]const u8 {
    if (tx.state.auth.pair) |pair| return pair.origin;
    if (tx.state.auth.pin) |pin| return pin.origin;
    return null;
}
fn request(tx: *h.Transaction, kind: []const u8, path: []const u8, body: ?[]const u8, authorization: ?[]const u8) E!void {
    const a = tx.allocator();
    const s = &tx.state.auth;
    const Header = struct { name: []const u8, value: []const u8 };
    var headers: std.ArrayList(Header) = .empty;
    if (body != null) try headers.append(a, .{ .name = "Content-Type", .value = "application/json" });
    if (authorization) |value| try headers.append(a, .{ .name = "Authorization", .value = value });
    const id = try tx.emit("http_request", .{ .method = if (body == null) "GET" else "POST", .url = try std.fmt.allocPrint(a, "{s}{s}", .{ endpoint(tx).?, path }), .headers = headers.items, .body_base64 = if (body) |b| try encode64(a, b) else null, .timeout_ms = 15000, .max_response_bytes = 65536, .tls = .{ .origin = endpoint(tx).?, .spki_sha256 = s.observed_spki.? } });
    try tx.track(.http, id, kind);
}
fn mint(tx: *h.Transaction) E!void {
    if (has(tx, "auth_token")) return;
    const a = tx.allocator();
    const c = tx.state.auth.credential orelse return;
    var index: usize = 0;
    while (index < tx.state.pending.len) {
        const pending = tx.state.pending[index];
        if (pending.kind == .http and eq(pending.key, "auth_ticket")) {
            _ = try tx.emit("http_cancel", .{ .request_id = pending.id });
            try tx.remove(index);
        } else index += 1;
    }
    const authorization = remote.pair_client.deviceAuthorizationAlloc(a, c.device_id, c.device_credential) catch |err| return h.mapError(err);
    try request(tx, "auth_token", access.HTTP_ACCESS_TOKEN_PATH, try h.encode(a, .{ .access_protocol_version = 1, .requested_scopes = c.scopes }), authorization);
}
/// Single-flight entry for HTTP consumers. Only a proven 401 may call this;
/// the consumer retains its request and retries once after a new token arrives.
pub fn unauthorized(tx: *h.Transaction, already_retried: bool) E!void {
    if (already_retried) return repair(tx);
    tx.state.auth.token = null;
    h.rpc.clearBearer(tx);
    tx.state.auth.expires_at_ms = 0;
    if (tx.state.auth.verified and !tx.state.auth.blocked and tx.state.lifecycle == .foreground and tx.state.network_available) try mint(tx);
}
fn repair(tx: *h.Transaction) E!void {
    suspendSession(tx);
    try tx.invalidateTransport();
    tx.state.auth.pair = null;
    tx.state.auth.blocked = true;
    tx.state.auth_state = "repair_required";
    fail(tx, "repair_required", false);
}
pub fn advance(tx: *h.Transaction) E!void {
    const s = &tx.state.auth;
    if (tx.state.lifecycle == .stopped) {
        s.* = .{};
        return;
    }
    if (s.blocked) {
        h.rpc.clearBearer(tx);
        if (!s.stop_pending) return;
        s.stop_pending = false;
        for (tx.state.pending) |pending| {
            if (pending.kind == .http or pending.kind == .socket or pending.kind == .timer or pending.kind == .tls) {
                const phase = s.phase;
                suspendSession(tx);
                try tx.invalidateTransport();
                s.phase = phase;
                break;
            }
        }
        return;
    }
    if (tx.state.lifecycle != .foreground or !tx.state.network_available or !s.profile_loaded or !s.credential_loaded or storagePending(tx) or s.proposal != null or s.retry != null) return;
    if (endpoint(tx) == null or (s.pair == null and s.credential == null)) return;
    if (tx.state.rpc.phase == .failed or tx.state.rpc.phase == .awaiting_trust) {
        if (tx.state.host_error) |failure| {
            suspendSession(tx);
            try tx.invalidateTransport();
            if (failure.retryable) try retry(tx, "auth_rpc") else fail(tx, failure.code, false);
            return;
        }
    }
    if (!s.verified) {
        if (has(tx, "auth_probe") or has(tx, "auth_discovery")) return;
        const id = try tx.emit("tls_probe", .{ .origin = endpoint(tx).? });
        try tx.track(.tls, id, "auth_probe");
        s.phase = "connecting";
        tx.changed = true;
        return;
    }
    if (s.pair) |pair| {
        if (!has(tx, "auth_exchange")) try request(tx, "auth_exchange", access.HTTP_PAIR_EXCHANGE_PATH, try h.encode(tx.allocator(), .{ .access_protocol_version = 1, .grant_id = pair.grant_id, .pairing_token = pair.code, .device_label = pair.label, .client_nonce = pair.nonce }), null);
    } else if (s.credential != null) {
        if (s.token == null or tx.state.wall_time_ms >= s.expires_at_ms -| 120000) {
            try mint(tx);
        } else if (s.need_ticket and !has(tx, "auth_ticket")) {
            try request(tx, "auth_ticket", access.HTTP_WEBSOCKET_TICKET_PATH, "{\"access_protocol_version\":1}", try std.fmt.allocPrint(tx.allocator(), "Bearer {s}", .{s.token.?}));
        }
        if (s.token != null and tx.state.rpc.bearer != null and tx.state.rpc.phase == .disabled) _ = try h.rpc.beginHandshake(tx);
        if (s.token != null and !has(tx, "auth_refresh") and s.expires_at_ms -| 120000 > tx.state.wall_time_ms) try tx.setTimer("auth_refresh", @intCast(@min(s.expires_at_ms -| 120000 -| tx.state.wall_time_ms, std.math.maxInt(u32))));
    }
}
fn retry(tx: *h.Transaction, kind: []const u8) E!void {
    const s = &tx.state.auth;
    if (eq(kind, "auth_exchange") and !s.idempotent) {
        if (s.pair) |pair| operation(tx, pair.intent_id, "uncertain", .{ .domain = "auth", .code = "exchange_uncertain", .message = "Create a new pairing grant.", .delivery = "uncertain" });
        s.pair = null;
        fail(tx, "exchange_uncertain", false);
        return;
    }
    s.retry = kind;
    fail(tx, "network_unavailable", true);
    s.retry_attempt +|= 1;
    const jitter: u32 = @intCast((tx.state.config.jitter_seed +% tx.state.next_id) % (remote.connection.RECONNECT_MAX_JITTER_MS + 1));
    const delay = remote.connection.reconnectDelayMs(s.retry_attempt, jitter) catch return error.InvalidArgument;
    try tx.setTimer("auth_retry", @intCast(delay));
    s.retry_at_ms = tx.state.now_ms.? +| @as(i64, @intCast(delay));
    s.phase = "reconnecting";
}
fn validatePin(pin: Pin) E!void {
    if (pin.version != 1 or !hex(pin.spki_sha256, 64) or !hex(pin.runtime_id, 32) or !hex(pin.instance_id, 32)) return error.InvalidArgument;
    remote.profile.validateRuntimeEndpointPair(pin.origin, pin.wss_url) catch return error.InvalidArgument;
}
fn validateCredential(c: Credential) E!void {
    if (c.version != 1 or !hex(c.runtime_id, 32) or !hex(c.device_id, 32) or !hex(c.device_credential, 64)) return error.InvalidArgument;
    access.validateScopeNames(c.scopes) catch return error.InvalidArgument;
}
fn readPin(a: std.mem.Allocator, encoded: []const u8) E!Pin {
    const value = try h.decode(Pin, a, try h.parse(a, try decode64(a, encoded)));
    try validatePin(value);
    return value;
}
fn readCredential(a: std.mem.Allocator, encoded: []const u8) E!Credential {
    const value = try h.decode(Credential, a, try h.parse(a, try decode64(a, encoded)));
    try validateCredential(value);
    return value;
}
fn needsIdentityPersistence(tx: *h.Transaction, pin: Pin) E!bool {
    const a = tx.allocator();
    const old = tx.state.auth.pin;
    const configured: remote.profile.Profile = .{
        .id = try a.dupe(u8, tx.state.config.host_id),
        .label = try a.dupe(u8, tx.state.config.label),
        .expected_runtime_id = if (old) |p| try a.dupe(u8, p.runtime_id) else null,
        .expected_instance_id = if (old) |p| try a.dupe(u8, p.instance_id) else null,
        .transport = .{ .direct_https = .{ .https_url = try a.dupe(u8, pin.origin), .wss_url = try a.dupe(u8, pin.wss_url) } },
    };
    const proposal: remote.pin_controller.RuntimePinProposal = .{
        .allocator = a,
        .profile_id = configured.id,
        .generation = tx.state.generation,
        .runtime_id = try a.dupe(u8, pin.runtime_id),
        .instance_id = try a.dupe(u8, pin.instance_id),
    };
    return remote.pin_controller.shouldPersistProposal(&configured, &proposal) catch |err| return h.mapError(err);
}
fn adopt(tx: *h.Transaction) E!void {
    const s = &tx.state.auth;
    const pin = s.candidate.?;
    if (s.pin) |old| if (!eq(old.runtime_id, pin.runtime_id)) {
        h.rpc.clearBearer(tx);
        tx.state.rpc.runtime_id = null;
        tx.state.rpc.instance_id = null;
    };
    s.pin = pin;
    tx.state.config.https_url = pin.origin;
    tx.state.config.wss_url = pin.wss_url;
    s.candidate = null;
    if (s.credential) |c| if (!eq(c.runtime_id, pin.runtime_id)) {
        s.credential = null;
        tx.state.auth_state = "repair_required";
    };
    if (s.trust_intent) |id| operation(tx, id, "succeeded", null);
    s.trust_intent = null;
    tx.changed = true;
}

pub fn complete(tx: *h.Transaction, p: h.Pending, event: V) E!bool {
    const s = &tx.state.auth;
    const a = tx.allocator();
    if (p.kind == .store_get or p.kind == .store_put) {
        const is_profile = std.mem.endsWith(u8, p.key, "/profile");
        const is_credential = std.mem.endsWith(u8, p.key, "/credential");
        if (!is_profile and !is_credential) return false;
        if ((try h.field(event, "error")) != .null) {
            tx.state.host_error = .{ .domain = "storage", .code = try h.string(try h.field(event, "error"), "code"), .message = "Secure storage is unavailable.", .retryable = true };
            s.blocked = true;
            s.storage_retry = p;
            tx.changed = true;
            return true;
        }
        if (p.kind == .store_get) {
            const value = try h.field(event, "value_base64");
            if (is_profile) {
                if (value != .null) {
                    const pin = readPin(a, value.string) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        s.profile_loaded = true;
                        fail(tx, "stored_profile_invalid", false);
                        return true;
                    };
                    s.pin = pin;
                    tx.state.config.https_url = pin.origin;
                    tx.state.config.wss_url = pin.wss_url;
                }
                s.profile_loaded = true;
            } else {
                if (value != .null) {
                    const c = readCredential(a, value.string) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        s.credential_loaded = true;
                        tx.state.auth_state = "repair_required";
                        fail(tx, "stored_credential_invalid", false);
                        return true;
                    };
                    s.credential = c;
                }
                s.credential_loaded = true;
                tx.state.auth_state = if (s.credential == null) "unpaired" else "paired";
            }
            if (s.profile_loaded and s.credential_loaded and s.credential != null and (s.pin == null or !eq(s.credential.?.runtime_id, s.pin.?.runtime_id))) try repair(tx);
        } else if (is_profile) {
            if (s.candidate != null) try adopt(tx);
        } else {
            tx.state.auth_state = "paired";
            if (s.pair) |pair| operation(tx, pair.intent_id, "succeeded", null);
            s.pair = null;
        }
        tx.changed = true;
        return true;
    }
    if (p.kind == .tls and eq(p.key, "auth_probe")) {
        if (!eq(try h.string(event, "origin"), endpoint(tx).?) or !try h.boolean(event, "system_trusted")) {
            fail(tx, "tls_rejected", false);
            return true;
        }
        const spki = try h.string(event, "spki_sha256");
        if (!hex(spki, 64)) return error.InvalidArgument;
        s.observed_spki = spki;
        try request(tx, "auth_discovery", "/.well-known/verde-runtime", null, null);
        return true;
    }
    if (p.kind == .timer and (eq(p.purpose, "auth_refresh") or eq(p.purpose, "auth_retry"))) {
        s.retry = null;
        s.retry_at_ms = null;
        // A wall-clock rollback does not create an early refresh loop.
        if (eq(p.purpose, "auth_refresh") and s.expires_at_ms -| 120000 > tx.state.wall_time_ms) try tx.setTimer("auth_refresh", @intCast(@min(s.expires_at_ms -| 120000 -| tx.state.wall_time_ms, std.math.maxInt(u32))));
        return true;
    }
    if (p.kind == .socket and eq(p.key, "auth_socket")) {
        s.need_ticket = true;
        try retry(tx, "auth_ticket");
        return true;
    }
    if (p.kind != .http or !std.mem.startsWith(u8, p.key, "auth_")) return false;
    if ((try h.field(event, "error")) != .null) {
        const kind = try h.string(try h.field(event, "error"), "kind");
        if (eq(kind, "tls")) fail(tx, "tls_rejected", false) else try retry(tx, p.key);
        return true;
    }
    const status = try h.integer(event, "status");
    if (status == 401 and (eq(p.key, "auth_ticket") or eq(p.key, "auth_token"))) {
        if (s.unauthorized_retried) try repair(tx) else {
            s.unauthorized_retried = true;
            try unauthorized(tx, false);
        }
        return true;
    }
    if (status == 429 or status >= 500) {
        try retry(tx, p.key);
        return true;
    }
    if (status != 200) {
        if (eq(p.key, "auth_exchange")) {
            if (s.pair) |pair| operation(tx, pair.intent_id, "failed", .{ .domain = "auth", .code = "grant_rejected", .message = "Create a new pairing grant." });
            s.pair = null;
            tx.state.auth_state = "unpaired";
        }
        fail(tx, "auth_rejected", false);
        return true;
    }
    finishResponse(tx, p, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        fail(tx, "protocol_rejected", false);
    };
    return true;
}
fn finishResponse(tx: *h.Transaction, p: h.Pending, event: V) E!void {
    const a = tx.allocator();
    const s = &tx.state.auth;
    const body = try decode64(a, try h.string(event, "body_base64"));
    const value = try h.parse(a, body);
    s.retry_attempt = 0;
    if (try h.integer(value, "access_protocol_version") != 1) {
        fail(tx, "protocol_rejected", false);
        return;
    }
    if (eq(p.key, "auth_discovery")) {
        remote.pair_client.validateDirectDiscovery(a, endpoint(tx).?, body) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            fail(tx, "discovery_rejected", false);
            return;
        };
        const pin: Pin = .{ .origin = try h.string(value, "https_url"), .wss_url = try h.string(value, "wss_url"), .spki_sha256 = s.observed_spki.?, .runtime_id = try h.string(value, "runtime_id"), .instance_id = try h.string(value, "instance_id") };
        try validatePin(pin);
        s.idempotent = false;
        for ((try h.field(value, "capabilities")).array.items) |cap| if (cap == .string and eq(cap.string, "access.pair.idempotent.v1")) {
            s.idempotent = true;
        };
        s.verified = true;
        const matches = if (s.pin) |old| eq(old.origin, pin.origin) and eq(old.runtime_id, pin.runtime_id) and eq(old.spki_sha256, pin.spki_sha256) else false;
        const first_contact = try needsIdentityPersistence(tx, pin);
        if (!matches or first_contact) {
            s.candidate = pin;
            s.proposal = .{ .id = p.id, .origin = pin.origin, .spki_sha256 = pin.spki_sha256, .runtime_id = pin.runtime_id };
            s.phase = "awaiting_trust";
        } else if (!eq(s.pin.?.instance_id, pin.instance_id)) {
            s.candidate = pin;
            try store(tx, "profile", pin);
        }
        tx.changed = true;
    } else if (eq(p.key, "auth_exchange")) {
        const c: Credential = .{ .runtime_id = try h.string(value, "runtime_id"), .device_id = try h.string(value, "device_id"), .device_credential = try h.string(value, "device_credential"), .scopes = try h.decode([]const []const u8, a, try h.field(value, "scopes")) };
        try validateCredential(c);
        if (!eq(c.runtime_id, s.pin.?.runtime_id) or !eq(try h.string(value, "instance_id"), s.pin.?.instance_id)) {
            fail(tx, "identity_rejected", false);
            return;
        }
        s.credential = c;
        try store(tx, "credential", c);
    } else if (eq(p.key, "auth_token")) {
        const token = try h.string(value, "access_token");
        const expires = try h.integer(value, "expires_at_ms");
        if (!hex(token, 64) or !eq(try h.string(value, "token_type"), "Bearer") or expires -| tx.state.wall_time_ms <= 120000) {
            fail(tx, "token_rejected", false);
            return;
        }
        const scopes = try h.decode([]const []const u8, a, try h.field(value, "scopes"));
        access.validateScopeNames(scopes) catch return error.InvalidArgument;
        const granted = access.scopeMask(scopes) catch return error.InvalidArgument;
        const requested = access.scopeMask(s.credential.?.scopes) catch return error.InvalidArgument;
        if (granted != requested) {
            fail(tx, "scope_rejected", false);
            return;
        }
        // Minting replaces the device's live token. Retire the old socket and
        // obtain a fresh single-use ticket for the replacement session.
        var index: usize = 0;
        while (index < tx.state.pending.len) {
            const pending = tx.state.pending[index];
            if (pending.kind == .socket and eq(pending.key, "auth_socket")) {
                _ = try tx.emit("ws_close", .{ .socket_id = pending.id, .code = 1000 });
                try tx.remove(index);
            } else index += 1;
        }
        if (!s.need_ticket) s.unauthorized_retried = false;
        s.need_ticket = true;
        s.token = token;
        try h.rpc.attachBearer(tx, token, s.pin.?.runtime_id, s.pin.?.spki_sha256);
        try @import("auth_rpc.zig").retryWaiting(tx);
        s.expires_at_ms = expires;
        s.phase = "handshaking";
        tx.state.host_error = null;
        try tx.setTimer("auth_refresh", @intCast(@min(expires -| tx.state.wall_time_ms -| 120000, std.math.maxInt(u32))));
        tx.changed = true;
    } else if (eq(p.key, "auth_ticket")) {
        const ticket = try h.string(value, "ticket");
        if (!hex(ticket, 64) or try h.integer(value, "expires_at_ms") <= tx.state.wall_time_ms) {
            fail(tx, "ticket_rejected", false);
            return;
        }
        const id = try tx.emit("ws_open", .{ .url = s.pin.?.wss_url, .protocols = [_][]const u8{ "verde.v1", try std.fmt.allocPrint(a, "verde.ticket.{s}", .{ticket}) }, .tls = .{ .origin = s.pin.?.origin, .spki_sha256 = s.pin.?.spki_sha256 }, .max_message_bytes = 1024 * 1024 });
        try tx.track(.socket, id, "auth_socket");
        s.need_ticket = false;
        s.unauthorized_retried = false;
    }
    return;
}
