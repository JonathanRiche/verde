//! Transactional, sans-IO host skeleton. Feature engines plug into Transaction;
//! only a fully encoded batch commits its state and correlation tables.
const std = @import("std");
pub const rpc = @import("rpc.zig");
const auth = @import("auth.zig");
pub const sync = @import("sync.zig");
const terminal = @import("terminal_pump.zig");
pub const chat = @import("chat.zig");
pub const push = @import("push.zig");
pub const attention = @import("attention.zig");
pub const manage = @import("manage.zig");
pub const files = @import("files.zig");
const chat_index = @import("chat_index.zig");
const profile = @import("verde_remote").profile;
const A = std.mem.Allocator;
const V = std.json.Value;
pub const MAX_INPUT = 1024 * 1024;
pub const MAX_HTTP_INPUT = 12 * 1024 * 1024;
/// In-flight receipts (pending, uncertain or held by an engine) are never evicted.
/// Reaching this many rejects new intents with retryable `backpressure`.
pub const MAX_INFLIGHT_RECEIPTS = 1024;
/// Settled receipts kept for replay deduplication; older ones evict first.
pub const RECENT_RECEIPTS = 256;
/// Hard bound on retained receipts: admission never grows the table past it.
pub const MAX_RECEIPTS = MAX_INFLIGHT_RECEIPTS + RECENT_RECEIPTS;
pub const MAX_PENDING = 256;
pub const ApiError = error{ InvalidArgument, UnsupportedVersion, OutOfMemory, InvalidLifecycle, ResourceLimit };
pub const Lifecycle = enum { created, foreground, background, stopped };
pub const TransportFailure = struct {
    kind: enum { network, timeout, cancelled, tls, server_unavailable, resource },
    // Local, deliberately small vocabulary; never accept exception text.
    code: enum { unknown, offline, dns, refused, reset, timeout, cancelled, certificate, hostname, pin_mismatch, unavailable, resource },
};
pub const PlatformFailure = struct { code: enum { unavailable, locked, denied, io, resource } };
pub const LocalError = struct {
    domain: []const u8 = "input",
    code: []const u8,
    message: []const u8,
    failure_kind: ?[]const u8 = null,
    retryable: bool = false,
    retry_after_ms: ?u32 = null,
    intent_id: ?[]const u8 = null,
    rpc_code: ?[]const u8 = null,
    delivery: ?[]const u8 = "rejected",
};
pub const Operation = struct { intent_id: []const u8, state: []const u8 = "failed", @"error": ?LocalError };
/// `backpressure` marks a rejection that ran no engine, so its ID may be re-admitted.
const Receipt = struct { operation: Operation, digest: [32]u8, backpressure: bool = false };
pub const Config = struct {
    api_version: u32,
    host_id: []const u8,
    label: []const u8,
    https_url: ?[]const u8,
    wss_url: ?[]const u8,
    client_revision: u32,
    session_nonce: []const u8,
    jitter_seed: u64,
};
pub const PendingKind = enum { http, socket, timer, store_get, store_put, store_delete, tls, terminal };
pub const Pending = struct {
    id: []const u8,
    generation: u64,
    kind: PendingKind,
    key: []const u8 = "",
    deadline: i64 = 0,
    purpose: []const u8 = "",
};
pub const State = struct {
    config: Config,
    rpc: rpc.State = .{},
    auth: auth.State = .{},
    sync: sync.State = .{},
    terminal: terminal.State = .{},
    chat: chat.State = .{},
    push: push.State = .{},
    attention: attention.State = .{},
    manage: manage.State = .{},
    files: files.State = .{},
    chat_index: chat_index.State = .{},
    lifecycle: Lifecycle = .created,
    revision: u64 = 0,
    generation: u64 = 0,
    next_id: u64 = 1,
    now_ms: ?i64 = null,
    wall_time_ms: i64 = 0,
    network_available: bool = false,
    network_id: []const u8 = "",
    stale: bool = false,
    auth_state: []const u8 = "loading",
    host_error: ?LocalError = null,
    pending: []const Pending = &.{},
    receipts: []const Receipt = &.{},
};

pub const Host = struct {
    allocator: A,
    arena: std.heap.ArenaAllocator,
    state: State,

    pub fn init(allocator: A, input: []const u8) ApiError!Host {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const value = try parse(a, input);
        try version(value);
        const config = try decode(Config, a, value);
        if (!safeComponent(config.host_id) or config.label.len == 0 or config.label.len > 1024 or config.session_nonce.len != 32) return error.InvalidArgument;
        for (config.session_nonce) |c| if (!std.ascii.isHex(c)) return error.InvalidArgument;
        if ((config.https_url == null) != (config.wss_url == null)) return error.InvalidArgument;
        if (config.https_url) |url| profile.validateRuntimeEndpointPair(url, config.wss_url.?) catch return error.InvalidArgument;
        return .{ .allocator = allocator, .arena = arena, .state = .{ .config = config } };
    }

    pub fn deinit(self: *Host) void {
        self.arena.deinit();
    }

    pub fn handle(self: *Host, input: []const u8, output_allocator: A) ApiError![]u8 {
        var tx = try Transaction.init(self);
        defer tx.deinit();
        const event = try parseLimit(tx.allocator(), input, MAX_HTTP_INPUT);
        if (input.len > MAX_INPUT and !eq(try string(event, "type"), "http_response") and !eq(try string(event, "type"), "ws_message")) return error.ResourceLimit;
        try tx.apply(event);
        try sync.pump(&tx);
        try terminal.pump(&tx);
        try chat.pump(&tx);
        try manage.pump(&tx);
        try files.pump(&tx);
        try push.pump(&tx);
        try chat_index.pump(&tx);
        try attention.pump(&tx);
        return tx.commit(self, output_allocator);
    }

    pub fn query(self: *const Host, selector: []const u8, output_allocator: A) ApiError![]u8 {
        if (selector.len > MAX_INPUT) return error.ResourceLimit;
        if (!std.unicode.utf8ValidateSlice(selector)) return error.InvalidArgument;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const s = &self.state;
        var data: V = .null;
        var failure: ?LocalError = null;
        if (eq(selector, "hosts")) {
            const operations = try a.alloc(Operation, s.receipts.len);
            for (s.receipts, operations) |receipt, *op| op.* = receipt.operation;
            data = try valueOf(a, .{ .items = .{.{
                .host_id = s.config.host_id,
                .label = s.config.label,
                .https_url = s.config.https_url,
                .runtime_id = s.rpc.runtime_id orelse if (s.auth.pin) |pin| pin.runtime_id else null,
                .instance_id = s.rpc.instance_id orelse if (s.auth.pin) |pin| pin.instance_id else null,
                .phase = if (s.auth.proposal != null or s.auth.blocked or s.auth.retry != null) s.auth.phase else if (s.rpc.bearer != null) @tagName(s.rpc.phase) else s.auth.phase,
                .lifecycle = @tagName(s.lifecycle),
                .auth_state = s.auth_state,
                .sync_state = if (s.sync.loading) "loading" else if (s.stale) "stale" else if (s.sync.snapshot != .null) "ready" else "empty",
                .capabilities = s.rpc.runtime_capabilities,
                .scopes = if (s.auth.credential) |c| c.scopes else &.{},
                .retry_at_ms = s.auth.retry_at_ms,
                .trust_proposal = s.auth.proposal,
                .update_required = s.rpc.update_required,
                .@"error" = s.host_error,
            }}, .operations = operations });
        } else if (std.mem.startsWith(u8, selector, "terminal:")) {
            data = (try terminal.query(a, s, selector[9..])) orelse .null;
            if (data == .null) failure = .{ .code = "not_found", .message = "Unknown terminal." };
        } else if (eq(selector, "home") or eq(selector, "workspaces")) {
            data = try sync.query(a, s, selector);
            if (eq(selector, "workspaces") and s.chat.history_epoch > 0) try data.object.put(a, "history", try valueOf(a, s.chat.history));
            try attention.annotate(a, s, selector, &data);
        } else if (eq(selector, "manage")) {
            data = try manage.query(a, s);
        } else if (try attention.query(a, s, selector)) |attention_view| {
            data = attention_view;
        } else if (try chat.query(a, s, selector)) |chat_view| {
            data = chat_view;
        } else {
            failure = .{ .code = "not_found", .message = "Unknown selector or resource." };
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, selector, " \t\r\n"), "{")) {
                const utility = try parse(a, selector);
                const rendered = try @import("rendering.zig").query(a, utility);
                data = rendered.data;
                failure = rendered.failure;
            }
        }
        return encode(output_allocator, .{ .api_version = 1, .revision = try decimal(a, s.revision), .data = data, .@"error" = failure });
    }
};

pub const Transaction = struct {
    arena: std.heap.ArenaAllocator,
    state: State,
    effects: std.ArrayList(V) = .empty,
    changed: bool = false,
    completion_matched: bool = false,

    pub fn init(host: *const Host) ApiError!Transaction {
        var arena = std.heap.ArenaAllocator.init(host.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const bytes = try encode(a, host.state);
        const state = std.json.parseFromSliceLeaky(State, a, bytes, .{ .allocate = .alloc_always }) catch |err| return mapError(err);
        return .{ .arena = arena, .state = state };
    }
    pub fn deinit(self: *Transaction) void {
        self.arena.deinit();
    }
    pub fn allocator(self: *Transaction) A {
        return self.arena.allocator();
    }

    pub fn emit(self: *Transaction, tag: []const u8, payload: anytype) ApiError![]const u8 {
        const s = &self.state;
        if (s.next_id == std.math.maxInt(u64) or self.effects.items.len >= MAX_PENDING * 2 + 1) return error.ResourceLimit;
        const a = self.allocator();
        const id = try std.fmt.allocPrint(a, "{s}:{d}", .{ s.config.session_nonce, s.next_id });
        s.next_id += 1;
        var value = try valueOf(a, payload);
        if (value == .array and value.array.items.len == 0) value = .{ .object = .empty };
        if (value != .object) return error.InvalidArgument;
        try value.object.put(a, "type", .{ .string = tag });
        try value.object.put(a, "effect_id", .{ .string = id });
        try value.object.put(a, "generation", .{ .string = try decimal(a, s.generation) });
        try self.effects.append(a, value);
        return id;
    }

    pub fn track(self: *Transaction, kind: PendingKind, id: []const u8, key: []const u8) ApiError!void {
        if (self.state.pending.len == MAX_PENDING) return error.ResourceLimit;
        try append(Pending, self.allocator(), &self.state.pending, .{ .id = id, .generation = self.state.generation, .kind = kind, .key = key });
    }

    /// Replacing a purpose always cancels the old timer and allocates a fresh ID.
    pub fn setTimer(self: *Transaction, purpose: []const u8, delay_ms: u32) ApiError!void {
        var i: usize = 0;
        while (i < self.state.pending.len) {
            const p = self.state.pending[i];
            if (p.kind == .timer and eq(p.purpose, purpose)) {
                _ = try self.emit("cancel_timer", .{ .timer_id = p.id });
                try self.remove(i);
            } else i += 1;
        }
        const deadline = std.math.add(i64, self.state.now_ms orelse 0, delay_ms) catch return error.ResourceLimit;
        // Timer IDs and effect IDs share the monotonic namespace, but differ on re-arm.
        const id = try self.emit("set_timer", .{ .timer_id = "", .delay_ms = delay_ms, .purpose = purpose });
        try self.effects.items[self.effects.items.len - 1].object.put(self.allocator(), "timer_id", .{ .string = id });
        if (self.state.pending.len == MAX_PENDING) return error.ResourceLimit;
        try append(Pending, self.allocator(), &self.state.pending, .{ .id = id, .generation = self.state.generation, .kind = .timer, .deadline = deadline, .purpose = purpose });
    }

    pub fn invalidateTransport(self: *Transaction) ApiError!void {
        if (self.state.generation == std.math.maxInt(u64)) return error.ResourceLimit;
        try rpc.invalidate(self);
        terminal.invalidate(self);
        sync.delta.invalidate(self);
        self.state.generation += 1;
        auth.invalidated(self);
        var i: usize = 0;
        while (i < self.state.pending.len) {
            const p = self.state.pending[i];
            switch (p.kind) {
                .store_get, .store_put, .store_delete => {
                    i += 1;
                    continue;
                },
                .http => {
                    _ = try self.emit("http_cancel", .{ .request_id = p.id });
                },
                .socket => {
                    _ = try self.emit("ws_close", .{ .socket_id = p.id, .code = 1000 });
                },
                .timer => {
                    _ = try self.emit("cancel_timer", .{ .timer_id = p.id });
                },
                else => {},
            }
            try self.remove(i);
        }
    }

    pub fn remove(self: *Transaction, index: usize) ApiError!void {
        const old = self.state.pending;
        const next = try self.allocator().alloc(Pending, old.len - 1);
        @memcpy(next[0..index], old[0..index]);
        @memcpy(next[index..], old[index + 1 ..]);
        self.state.pending = next;
    }

    pub fn apply(self: *Transaction, event: V) ApiError!void {
        self.completion_matched = false;
        try version(event);
        const tag = try string(event, "type");
        const now = try integer(event, "now_ms");
        const wall = try integer(event, "wall_time_ms");
        if (self.state.lifecycle == .stopped) {
            if (!eq(tag, "shutdown")) return error.InvalidLifecycle;
            return;
        }
        if (now < 0 or (self.state.now_ms != null and now < self.state.now_ms.?)) return error.InvalidArgument;
        const s = &self.state;
        s.now_ms = now;
        s.wall_time_ms = wall;
        if (eq(tag, "start")) {
            const fg = try boolean(event, "foreground");
            const net = try boolean(event, "network_available");
            if (s.lifecycle != .created) return error.InvalidLifecycle;
            s.lifecycle = if (fg) .foreground else .background;
            s.network_available = net;
            // Profile owns the receipt index; K-07/K-10 decode the records.
            for ([_][]const u8{ "profile", "credential" }) |record| {
                const key = try std.fmt.allocPrint(self.allocator(), "vc/1/{s}/{s}", .{ s.config.host_id, record });
                const id = try self.emit("secure_store_get", .{ .key = key });
                try self.track(.store_get, id, key);
            }
            self.changed = true;
        } else if (eq(tag, "shutdown")) {
            auth.suspendSession(self);
            try self.invalidateTransport();
            s.pending = &.{};
            s.lifecycle = .stopped;
            s.stale = true;
            self.changed = true;
        } else if (eq(tag, "foreground") or eq(tag, "background")) {
            if (s.lifecycle == .created) return error.InvalidLifecycle;
            const next: Lifecycle = if (eq(tag, "foreground")) .foreground else .background;
            if (s.lifecycle != next) {
                if (next == .background) {
                    auth.suspendSession(self);
                    try self.invalidateTransport();
                    s.stale = true;
                }
                s.lifecycle = next;
                self.changed = true;
            }
        } else if (eq(tag, "network_changed")) {
            const available = try boolean(event, "available");
            const id = try string(event, "network_id");
            if (s.lifecycle == .created) return error.InvalidLifecycle;
            if (s.network_available != available or !eq(s.network_id, id)) {
                auth.suspendSession(self);
                try self.invalidateTransport();
                s.network_available = available;
                s.network_id = id;
                s.stale = true;
                self.changed = true;
            }
        } else if (isIntent(tag)) {
            const id = try string(event, "intent_id");
            if (id.len == 0 or id.len > 256) return error.InvalidArgument;
            try validateIntent(self.allocator(), tag, event);
            const digest = try intentDigest(self.allocator(), event);
            for (s.receipts, 0..) |r, i| if (eq(r.operation.intent_id, id)) {
                if (!std.mem.eql(u8, &r.digest, &digest)) return error.InvalidArgument;
                if (!r.backpressure) return;
                // Nothing ran for a backpressure rejection; retrying the same ID is safe.
                try self.dropReceipt(i);
                break;
            };
            if (!try self.admitReceipt(id, digest)) return;
            _ = try auth.intent(self, tag, event);
            _ = try terminal.intent(self, tag, event);
            _ = try chat.intent(self, tag, event);
            _ = try manage.intent(self, tag, event);
            try files.intent(self, tag, event);
            _ = try push.intent(self, tag, event);
            try attention.intent(self, tag, event);
            // Pull-to-refresh: an explicit retry also re-reads a ready connection's snapshot and catalog.
            if (eq(tag, "retry_connection")) try sync.refresh(self);
            self.changed = true;
        } else if (eq(tag, "terminal_reply")) {
            _ = try string(event, "terminal_id");
            try base64(try string(event, "bytes_base64"));
            try terminal.reply(self, event);
        } else if (eq(tag, "push_received")) {
            if (s.lifecycle == .created) return error.InvalidLifecycle;
            try attention.received(self, event);
        } else {
            try self.complete(tag, event);
            if (!self.completion_matched) return;
        }
        try auth.advance(self);
    }

    /// Bounds the receipt table without evicting anything a replay could resend.
    /// Returns false when the intent was rejected for backpressure instead.
    fn admitReceipt(self: *Transaction, id: []const u8, digest: [32]u8) ApiError!bool {
        const s = &self.state;
        var in_flight: usize = 0;
        for (s.receipts) |r| {
            if (inFlight(s, r)) in_flight += 1;
        }
        var settled = s.receipts.len - in_flight;
        var i: usize = 0;
        // Oldest settled receipts go first; in-flight ones keep their dedupe forever.
        while (settled >= RECENT_RECEIPTS and i < s.receipts.len) {
            if (inFlight(s, s.receipts[i])) {
                i += 1;
            } else {
                try self.dropReceipt(i);
                settled -= 1;
            }
        }
        self.changed = true;
        if (in_flight >= MAX_INFLIGHT_RECEIPTS) {
            try append(Receipt, self.allocator(), &s.receipts, .{ .digest = digest, .backpressure = true, .operation = .{ .intent_id = id, .@"error" = .{
                .domain = "resource",
                .code = "backpressure",
                .message = "Too many actions are still in progress. Try again shortly.",
                .failure_kind = "resource",
                .retryable = true,
                .intent_id = id,
            } } });
            return false;
        }
        try append(Receipt, self.allocator(), &s.receipts, .{ .digest = digest, .operation = .{ .intent_id = id, .@"error" = .{ .code = "unsupported", .message = "Intent is not implemented.", .intent_id = id } } });
        return true;
    }

    fn dropReceipt(self: *Transaction, index: usize) ApiError!void {
        const old = self.state.receipts;
        const next = try self.allocator().alloc(Receipt, old.len - 1);
        @memcpy(next[0..index], old[0..index]);
        @memcpy(next[index..], old[index + 1 ..]);
        self.state.receipts = next;
    }

    fn complete(self: *Transaction, tag: []const u8, event: V) ApiError!void {
        const a = self.allocator();
        var kind: PendingKind = undefined;
        var id_field: []const u8 = "effect_id";
        if (eq(tag, "http_response")) {
            kind = .http;
            const Response = struct { status: ?u16, headers: []const struct { name: []const u8, value: []const u8 }, body_base64: ?[]const u8, @"error": ?TransportFailure };
            const r = try decode(Response, a, event);
            if ((r.status == null) == (r.@"error" == null)) return error.InvalidArgument;
            if (r.status) |status| {
                if (status < 100 or status > 599) return error.InvalidArgument;
            }
            if (r.@"error" != null and (r.body_base64 != null or r.headers.len != 0)) return error.InvalidArgument;
            if (r.body_base64) |body| try base64(body);
        } else if (eq(tag, "ws_open")) {
            kind = .socket;
            id_field = "socket_id";
            _ = try string(event, "protocol");
        } else if (eq(tag, "ws_message")) {
            kind = .socket;
            id_field = "socket_id";
            _ = try string(event, "text");
        } else if (eq(tag, "ws_closed")) {
            kind = .socket;
            id_field = "socket_id";
            _ = try decode(struct { code: ?u16, clean: bool, @"error": ?TransportFailure }, a, event);
        } else if (eq(tag, "timer_fired")) {
            kind = .timer;
            id_field = "timer_id";
        } else if (eq(tag, "secure_store_value")) {
            kind = .store_get;
            const r = try decode(struct { key: []const u8, value_base64: ?[]const u8, @"error": ?PlatformFailure }, a, event);
            if (r.@"error" != null and r.value_base64 != null) return error.InvalidArgument;
            if (r.value_base64) |body| try base64(body);
        } else if (eq(tag, "secure_store_done")) {
            kind = .store_put;
            _ = try decode(struct { key: []const u8, @"error": ?PlatformFailure }, a, event);
        } else if (eq(tag, "tls_peer")) {
            kind = .tls;
            _ = try decode(struct { origin: []const u8, spki_sha256: []const u8, system_trusted: bool }, a, event);
        } else if (eq(tag, "terminal_applied")) {
            kind = .terminal;
            _ = try decode(struct { terminal_id: []const u8, grid_revision: []const u8, @"error": ?PlatformFailure }, a, event);
            _ = try counter(try string(event, "grid_revision"));
        } else return error.InvalidArgument;
        const id = try string(event, id_field);
        const generation = try counter(try string(event, "generation"));
        for (self.state.pending, 0..) |p, i| {
            if (!eq(p.id, id) or p.generation != generation) continue;
            if (p.kind != kind and !(kind == .store_put and p.kind == .store_delete)) return;
            if (kind == .store_get or kind == .store_put) {
                if (!eq(p.key, try string(event, "key"))) return;
            }
            self.completion_matched = true;
            if (kind == .socket and !eq(tag, "ws_closed")) {
                if (eq(tag, "ws_message")) try sync.pushFrom(self, p.id, try string(event, "text"));
                return;
            }
            try self.remove(i);
            if (kind == .http and eq(p.key, "rpc")) {
                if (!try @import("auth_rpc.zig").intercept(self, id, event)) try rpc.complete(self, id, event);
            }
            if (kind == .timer and self.state.now_ms.? < p.deadline) {
                // Replacement gives an early delivery a new ID; duplicate early callbacks are stale.
                try self.setTimer(p.purpose, @intCast(p.deadline - self.state.now_ms.?));
                return;
            }
            if (try sync.delta.complete(self, p, event)) return;
            if (try auth.complete(self, p, event)) return;
            if (try terminal.complete(self, p, event)) return;
            if (try chat.complete(self, p, event)) return;
            if (try push.complete(self, p, event)) return;
            if (try attention.complete(self, p, event)) return;
            if (try chat_index.complete(self, p, event)) return;
            if (try files.complete(self, p, event)) return;
            if (kind == .store_get) {
                if ((try field(event, "error")) != .null) {
                    self.state.host_error = .{ .domain = "storage", .code = try string(try field(event, "error"), "code"), .message = "Stored profile could not be loaded.", .retryable = true };
                    self.changed = true;
                } else if (std.mem.endsWith(u8, p.key, "/credential") and (try field(event, "value_base64")) == .null) {
                    self.state.auth_state = "unpaired";
                    self.changed = true;
                }
                // Never infer paired/authenticated from opaque bytes: K-07 validates them.
            }
            return;
        }
    }

    pub fn commit(self: *Transaction, host: *Host, output_allocator: A) ApiError![]u8 {
        if (self.changed) {
            if (self.state.revision == std.math.maxInt(u64)) return error.ResourceLimit;
            self.state.revision += 1;
            _ = try self.emit("state_changed", .{ .revision = try decimal(self.allocator(), self.state.revision), .scopes = try withAttention(self) });
            try terminal.queryScopes(self);
        }
        // Retain only state, never the call's decoded secrets or effect payloads.
        var retained = std.heap.ArenaAllocator.init(host.allocator);
        errdefer retained.deinit();
        const state_bytes = try encode(self.allocator(), self.state);
        const next = std.json.parseFromSliceLeaky(State, retained.allocator(), state_bytes, .{ .allocate = .alloc_always }) catch |err| return mapError(err);
        const output = try encode(output_allocator, .{ .api_version = 1, .revision = try decimal(self.allocator(), self.state.revision), .effects = self.effects.items });
        host.arena.deinit();
        host.arena = retained;
        host.state = next;
        return output;
    }
};

/// Unresolved outcomes, and receipts an engine will still update, are in flight.
fn inFlight(s: *const State, r: Receipt) bool {
    const state = r.operation.state;
    return eq(state, "pending") or eq(state, "uncertain") or chat.holdsIntent(&s.chat, r.operation.intent_id);
}
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn safeComponent(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}
pub fn mapError(err: anyerror) ApiError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArgument,
    };
}
pub fn parse(a: A, input: []const u8) ApiError!V {
    return parseLimit(a, input, MAX_INPUT);
}
pub fn parseLimit(a: A, input: []const u8, limit: usize) ApiError!V {
    if (input.len > limit) return error.ResourceLimit;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidArgument;
    // Bound recursive canonicalization and encoding before creating a DOM.
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (input) |c| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                quoted = false;
            }
        } else if (c == '"') {
            quoted = true;
        } else if (c == '{' or c == '[') {
            depth += 1;
            if (depth > 64) return error.ResourceLimit;
        } else if (c == '}' or c == ']') {
            if (depth == 0) return error.InvalidArgument;
            depth -= 1;
        }
    }
    return std.json.parseFromSliceLeaky(V, a, input, .{ .allocate = .alloc_always, .max_value_len = limit }) catch |err| return mapError(err);
}
pub fn decode(comptime T: type, a: A, value: V) ApiError!T {
    try validateShape(T, value);
    return std.json.parseFromValueLeaky(T, a, value, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| return mapError(err);
}
// std.json also accepts byte arrays as strings and numeric strings as numbers.
// The local wire contract deliberately does not use those coercions.
fn validateShape(comptime T: type, value: V) ApiError!void {
    switch (@typeInfo(T)) {
        .optional => |info| if (value != .null) {
            try validateShape(info.child, value);
        },
        .@"struct" => |info| {
            if (value != .object) return error.InvalidArgument;
            inline for (info.fields) |f| {
                if (value.object.get(f.name)) |v| try validateShape(f.type, v);
            }
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("wire pointers must be slices");
            if (info.child == u8) {
                if (value != .string) return error.InvalidArgument;
            } else {
                if (value != .array) return error.InvalidArgument;
                for (value.array.items) |v| try validateShape(info.child, v);
            }
        },
        .int => {
            if (value == .number_string) {
                _ = std.fmt.parseInt(T, value.number_string, 10) catch return error.InvalidArgument;
            } else if (value != .integer) return error.InvalidArgument;
        },
        .bool => if (value != .bool) {
            return error.InvalidArgument;
        },
        .@"enum" => if (value != .string) {
            return error.InvalidArgument;
        },
        else => @compileError("unsupported wire schema type"),
    }
}
pub fn encode(a: A, value: anytype) ApiError![]u8 {
    return std.json.Stringify.valueAlloc(a, value, .{}) catch |err| return mapError(err);
}
fn valueOf(a: A, value: anytype) ApiError!V {
    return parse(a, try encode(a, value));
}
fn decimal(a: A, n: u64) ApiError![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}
fn counter(s: []const u8) ApiError!u64 {
    if (s.len == 0 or (s.len > 1 and s[0] == '0')) return error.InvalidArgument;
    for (s) |c| if (!std.ascii.isDigit(c)) return error.InvalidArgument;
    return std.fmt.parseInt(u64, s, 10) catch return error.InvalidArgument;
}
fn version(v: V) ApiError!void {
    if (try integer(v, "api_version") != 1) return error.UnsupportedVersion;
}
pub fn field(v: V, key: []const u8) ApiError!V {
    if (v != .object) return error.InvalidArgument;
    return v.object.get(key) orelse error.InvalidArgument;
}
pub fn string(v: V, key: []const u8) ApiError![]const u8 {
    const f = try field(v, key);
    return if (f == .string) f.string else error.InvalidArgument;
}
pub fn integer(v: V, key: []const u8) ApiError!i64 {
    const f = try field(v, key);
    return if (f == .integer) f.integer else error.InvalidArgument;
}
pub fn boolean(v: V, key: []const u8) ApiError!bool {
    const f = try field(v, key);
    return if (f == .bool) f.bool else error.InvalidArgument;
}
fn base64(s: []const u8) ApiError!void {
    _ = std.base64.standard.Decoder.calcSizeForSlice(s) catch return error.InvalidArgument;
    var padding: usize = 0;
    for (s) |c| {
        if (c == '=') {
            padding += 1;
            if (padding > 2) return error.InvalidArgument;
        } else if (padding != 0 or (!std.ascii.isAlphanumeric(c) and c != '+' and c != '/')) return error.InvalidArgument;
    }
}

fn withAttention(tx: *Transaction) ApiError![]const []const u8 {
    var scopes = try chat.scopes(tx);
    try append([]const u8, tx.allocator(), &scopes, "attention");
    try append([]const u8, tx.allocator(), &scopes, "manage");
    return scopes;
}
fn append(comptime T: type, a: A, slice: *[]const T, item: T) ApiError!void {
    const next = try a.alloc(T, slice.len + 1);
    @memcpy(next[0..slice.len], slice.*);
    next[slice.len] = item;
    slice.* = next;
}
const intents = [_][]const u8{ "sign_out", "forget_host", "pair", "trust_decision", "retry_connection", "focus", "thread_open", "thread_load_older", "history_search", "history_load_more", "draft_set", "composer_select", "send", "turn_cancel", "followup_submit", "followup_retry", "followup_pull_back", "followup_cancel", "approval_decide", "shell_prepare", "shell_confirm", "slash_search", "slash_run", "mention_search", "terminal_create", "terminal_attach", "terminal_detach", "terminal_input", "terminal_resize", "terminal_kill", "push_register", "thread_create", "new_chat_select", "workspace_create", "workspace_rename", "workspace_archive", "workspace_close", "directory_list", "file_open" };
fn isIntent(tag: []const u8) bool {
    for (intents) |intent| if (eq(tag, intent)) return true;
    return false;
}

fn validateIntent(a: A, tag: []const u8, event: V) ApiError!void {
    if (eq(tag, "sign_out") or eq(tag, "forget_host")) {
        _ = try string(event, "host_id");
    } else if (eq(tag, "pair")) {
        _ = try decode(struct { link: []const u8, device_label: []const u8, client_nonce: []const u8 }, a, event);
    } else if (eq(tag, "trust_decision")) {
        _ = try decode(struct { proposal_id: []const u8, accept: bool }, a, event);
    } else if (eq(tag, "focus")) {
        _ = try decode(struct { workspace_id: ?[]const u8, thread_id: ?[]const u8, terminal_id: ?[]const u8 }, a, event);
    } else if (eq(tag, "history_search")) {
        _ = try decode(struct { query: []const u8, workspace_id: ?[]const u8 }, a, event);
    } else if (eq(tag, "shell_confirm")) {
        _ = try decode(struct { confirmation_id: []const u8, accept: bool }, a, event);
    } else if (eq(tag, "push_register")) {
        try push.validate(a, event);
    } else if (manage.owns(tag)) {
        try manage.validate(a, tag, event);
    } else if (eq(tag, "file_open")) {
        try files.validate(a, event);
    } else if (eq(tag, "terminal_create")) {
        _ = try decode(struct { workspace_id: []const u8, cwd: ?[]const u8, cols: u16, rows: u16 }, a, event);
    } else if (std.mem.startsWith(u8, tag, "terminal_")) {
        _ = try string(event, "terminal_id");
        if (eq(tag, "terminal_resize")) {
            _ = try decode(struct { cols: u16, rows: u16 }, a, event);
        }
        if (eq(tag, "terminal_input")) {
            _ = try decode(struct { vt_modes: struct { application_cursor: bool, bracketed_paste: bool }, input: struct { kind: enum { text, key, paste }, text: ?[]const u8 = null, key: ?[]const u8 = null, ctrl: bool, alt: bool, shift: bool } }, a, event);
        }
    } else if (!eq(tag, "retry_connection") and !eq(tag, "history_load_more")) {
        _ = try string(event, "workspace_id");
        _ = try string(event, "thread_id");
        if (eq(tag, "draft_set")) {
            _ = try decode(struct { text: []const u8, attachments: []const struct { local_id: []const u8, name: []const u8, mime: []const u8, byte_size: []const u8, bytes_base64: []const u8 } }, a, event);
        }
        if (eq(tag, "composer_select")) {
            _ = try decode(struct { provider: ?[]const u8, model: ?[]const u8, effort: ?[]const u8, access: ?[]const u8, speed: ?[]const u8 }, a, event);
        }
        if (eq(tag, "send") or eq(tag, "followup_submit")) _ = try counter(try string(event, "draft_revision"));
        if (eq(tag, "followup_submit")) {
            _ = try decode(struct { kind: enum { queue, steer } }, a, event);
        }
        if (eq(tag, "turn_cancel") or eq(tag, "approval_decide")) _ = try string(event, "turn_id");
        if (eq(tag, "approval_decide")) {
            _ = try decode(struct { call_id: []const u8, decision: enum { approve, deny } }, a, event);
        }
        if (eq(tag, "followup_retry") or eq(tag, "followup_pull_back") or eq(tag, "followup_cancel")) _ = try string(event, "followup_id");
        if (eq(tag, "shell_prepare") or eq(tag, "slash_run")) _ = try string(event, "command");
        if (eq(tag, "slash_run")) _ = try string(event, "args");
        if (eq(tag, "slash_search") or eq(tag, "mention_search")) _ = try string(event, "query");
    }
}

// Sort object keys recursively so key order and injected times do not alter
// intent identity. Hash content instead of retaining secrets/attachment bytes.
fn canonical(a: A, value: V, context: []const u8, top: bool) ApiError!V {
    var v = value;
    if (v == .object) {
        var keys: std.ArrayList([]const u8) = .empty;
        var it = v.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!receiptField(context, key, top)) continue;
            try keys.append(a, key);
        }
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        var object: std.json.ObjectMap = .empty;
        for (keys.items) |key| try object.put(a, key, try canonical(a, v.object.get(key).?, key, false));
        v = .{ .object = object };
    } else if (v == .array) {
        for (v.array.items) |*item| item.* = try canonical(a, item.*, context, false);
    }
    return v;
}
fn intentDigest(a: A, event: V) ApiError![32]u8 {
    const bytes = try encode(a, try canonical(a, event, try string(event, "type"), true));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

// The same forward-compatible unknown-field rule applies to receipt identity.
fn receiptField(context: []const u8, key: []const u8, top: bool) bool {
    if (top and (eq(key, "type") or eq(key, "api_version") or eq(key, "intent_id"))) return true;
    const fields: []const u8 = blk: {
        if (eq(context, "sign_out") or eq(context, "forget_host")) break :blk "host_id";
        if (eq(context, "pair")) break :blk "link device_label client_nonce";
        if (eq(context, "trust_decision")) break :blk "proposal_id accept";
        if (eq(context, "retry_connection")) break :blk "";
        if (eq(context, "focus")) break :blk "workspace_id thread_id terminal_id";
        if (eq(context, "thread_open")) break :blk "workspace_id thread_id";
        if (eq(context, "thread_load_older")) break :blk "workspace_id thread_id";
        if (eq(context, "history_search")) break :blk "query workspace_id";
        if (eq(context, "history_load_more")) break :blk "";
        if (eq(context, "draft_set")) break :blk "workspace_id thread_id text attachments";
        if (eq(context, "composer_select")) break :blk "workspace_id thread_id provider model effort access speed";
        if (eq(context, "send")) break :blk "workspace_id thread_id draft_revision";
        if (eq(context, "turn_cancel")) break :blk "workspace_id thread_id turn_id";
        if (eq(context, "followup_submit")) break :blk "workspace_id thread_id draft_revision kind";
        if (eq(context, "approval_decide")) break :blk "workspace_id thread_id turn_id call_id decision";
        if (eq(context, "shell_prepare")) break :blk "workspace_id thread_id command";
        if (eq(context, "shell_confirm")) break :blk "confirmation_id accept";
        if (eq(context, "slash_search")) break :blk "workspace_id thread_id query";
        if (eq(context, "slash_run")) break :blk "workspace_id thread_id command args";
        if (eq(context, "mention_search")) break :blk "workspace_id thread_id query";
        if (eq(context, "terminal_create")) break :blk "workspace_id cwd cols rows";
        if (eq(context, "terminal_input")) break :blk "terminal_id vt_modes input";
        if (eq(context, "terminal_resize")) break :blk "terminal_id cols rows";
        if (eq(context, "attachments")) break :blk "local_id name mime byte_size bytes_base64";
        if (eq(context, "vt_modes")) break :blk "application_cursor bracketed_paste";
        if (eq(context, "input")) break :blk "kind text key ctrl alt shift";
        if (eq(context, "followup_retry")) break :blk "workspace_id thread_id followup_id";
        if (eq(context, "followup_pull_back")) break :blk "workspace_id thread_id followup_id";
        if (eq(context, "followup_cancel")) break :blk "workspace_id thread_id followup_id";
        if (eq(context, "terminal_attach")) break :blk "terminal_id";
        if (eq(context, "terminal_detach")) break :blk "terminal_id";
        if (eq(context, "terminal_kill")) break :blk "terminal_id";
        if (eq(context, "push_register")) break :blk "platform send_token key_seed_base64";
        if (manage.receiptFields(context)) |fields| break :blk fields;
        if (eq(context, "file_open")) break :blk "path kind max_bytes";
        break :blk "";
    };
    var names = std.mem.tokenizeScalar(u8, fields, ' ');
    while (names.next()) |name| if (eq(name, key)) return true;
    return false;
}
