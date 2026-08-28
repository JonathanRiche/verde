//! Desktop-side Verde Connect session: control-plane discovery, OIDC
//! public-client login (PKCE over a loopback redirect, RFC 8628 device flow
//! only when the control plane advertises it), and the principal-scoped
//! runtime inventory. The session runs on one worker thread; the UI polls a
//! secret-free snapshot. The OIDC access token lives only in this process's
//! memory and is zeroed on sign-out or teardown.
//!
//! The session deliberately stops at runtime selection. Presenting a Connect
//! bootstrap grant to a runtime needs a desktop direct HTTPS/WSS data plane
//! with SPKI pinning plus a runtime HTTP surface that consumes the grant;
//! neither exists yet, and `Snapshot.blocker` reports that honestly instead
//! of faking a connected state.

const std = @import("std");
const control_plane = @import("../daemon/connect_client.zig");
const profile = @import("profile.zig");
const utils = @import("../utils.zig");

const log = std.log.scoped(.native_connect_session);

/// Bounded so a hostile control plane cannot grow the picker without limit.
pub const MAX_INVENTORY_ROWS: usize = 32;
/// How long the loopback redirect waits for the browser round trip.
pub const LOGIN_TIMEOUT_MS: i64 = 5 * 60 * 1000;
const STOP_POLL_MS: i64 = 100;
/// Largest browser callback request line + headers we will read.
const MAX_CALLBACK_BYTES: usize = 8 * 1024;
const MAX_TOKEN_RESPONSE_BYTES: usize = 64 * 1024;

pub const Phase = enum {
    idle,
    discovering,
    discovered,
    signing_in,
    signed_in,
    loading_inventory,
    inventory_loaded,
    failed,
};

pub const Failure = enum {
    invalid_url,
    not_reachable,
    invalid_discovery,
    capability_missing,
    /// No registered redirect URI is a loopback address the desktop can bind.
    redirect_unavailable,
    browser_open_failed,
    login_denied,
    login_timeout,
    token_exchange,
    unauthorized,
    rate_limited,
    inventory_invalid,
    canceled,
    resource,

    pub fn message(self: Failure) []const u8 {
        return switch (self) {
            .invalid_url => "Enter an https:// control-plane URL without credentials or fragments.",
            .not_reachable => "The control plane could not be reached (timeout, TLS, or DNS failure).",
            .invalid_discovery => "The control plane's discovery document is not a valid Verde Connect v1 contract.",
            .capability_missing => "The control plane does not advertise every capability the desktop requires.",
            .redirect_unavailable => "No registered sign-in redirect is a loopback URL the desktop can listen on.",
            .browser_open_failed => "Could not open the system browser for sign-in.",
            .login_denied => "Sign-in was denied or the browser returned an invalid callback.",
            .login_timeout => "Sign-in timed out before the browser returned.",
            .token_exchange => "The identity provider rejected the authorization code exchange.",
            .unauthorized => "The control plane rejected the session. Sign in again.",
            .rate_limited => "The control plane is rate limiting this device. Try again shortly.",
            .inventory_invalid => "The runtime inventory response did not match the contract.",
            .canceled => "Canceled.",
            .resource => "Out of memory while talking to the control plane.",
        };
    }
};

/// One linked runtime from the inventory. Never contains credentials.
pub const RuntimeRow = struct {
    link_id: []u8,
    runtime_id: []u8,
    instance_id: []u8,
    https_url: []u8,
    wss_url: []u8,
    spki_sha256: []u8,

    fn deinit(self: *RuntimeRow, allocator: std.mem.Allocator) void {
        allocator.free(self.link_id);
        allocator.free(self.runtime_id);
        allocator.free(self.instance_id);
        allocator.free(self.https_url);
        allocator.free(self.wss_url);
        allocator.free(self.spki_sha256);
        self.* = undefined;
    }
};

/// Secret-free view for rendering. Slices borrow from the session and are
/// valid until the next `poll`.
pub const Snapshot = struct {
    phase: Phase,
    failure: ?Failure,
    issuer: ?[]const u8,
    /// True when RFC 8628 device authorization is advertised; the loopback
    /// PKCE flow is still preferred whenever a browser can be opened.
    device_flow_advertised: bool,
    /// Set while the browser sign-in is pending so the UI can show it.
    login_url_open: bool,
    runtimes: []const RuntimeRow,
    runtimes_truncated: usize,
    /// Exact reason the desktop cannot proceed past runtime selection.
    blocker: []const u8,
};

pub const BLOCKER: []const u8 =
    "Selecting a runtime saves its endpoint identity, but connecting is blocked: " ++
    "the desktop has no direct HTTPS/WSS data plane with SPKI pinning and the runtime " ++
    "exposes no HTTP surface that consumes a Connect bootstrap grant.";

const Command = enum { none, discover, login, inventory };

/// Worker-owned state shared with the UI thread under `mutex`.
const Shared = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    stop_requested: std.atomic.Value(bool) = .init(false),
    pending: Command = .none,
    phase: Phase = .idle,
    failure: ?Failure = null,
    control_plane_url: []u8,
    discovery: ?control_plane.OwnedDiscovery = null,
    /// OIDC bearer for the control plane. Memory only; zeroed when replaced.
    access_token: ?[]u8 = null,
    login_url_open: bool = false,
    runtimes: std.ArrayList(RuntimeRow) = .empty,
    runtimes_truncated: usize = 0,
    // Snapshot copies handed to the UI so the worker can mutate freely.
    ui_runtimes: std.ArrayList(RuntimeRow) = .empty,
    ui_issuer: ?[]u8 = null,

    // Critical sections are short (no network inside), so the spin mutex the
    // tunnel supervisor uses is sufficient and keeps the render thread lock-free.
    fn lock(self: *Shared) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Shared) void {
        self.mutex.unlock();
    }

    fn clearToken(self: *Shared) void {
        if (self.access_token) |token| {
            std.crypto.secureZero(u8, token);
            self.allocator.free(token);
        }
        self.access_token = null;
    }

    fn clearRuntimes(self: *Shared) void {
        for (self.runtimes.items) |*row| row.deinit(self.allocator);
        self.runtimes.clearRetainingCapacity();
        self.runtimes_truncated = 0;
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    shared: *Shared,
    worker: ?std.Thread = null,

    /// Starts discovery immediately. The URL is validated with the profile
    /// rules before any network access.
    pub fn start(allocator: std.mem.Allocator, control_plane_url: []const u8) !*Session {
        const sanitized = try profile.sanitizedHttpsUrlAlloc(allocator, control_plane_url);
        errdefer allocator.free(sanitized);
        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);
        shared.* = .{ .allocator = allocator, .control_plane_url = sanitized, .pending = .discover, .phase = .discovering };
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .shared = shared };
        self.worker = try std.Thread.spawn(.{}, workerMain, .{shared});
        return self;
    }

    /// Stops the worker, wipes the token, and frees everything.
    pub fn destroy(self: *Session) void {
        const shared = self.shared;
        shared.stop_requested.store(true, .release);
        if (self.worker) |worker| worker.join();
        shared.clearToken();
        shared.clearRuntimes();
        shared.runtimes.deinit(self.allocator);
        for (shared.ui_runtimes.items) |*row| row.deinit(self.allocator);
        shared.ui_runtimes.deinit(self.allocator);
        if (shared.ui_issuer) |value| self.allocator.free(value);
        if (shared.discovery) |*discovery| discovery.deinit();
        self.allocator.free(shared.control_plane_url);
        self.allocator.destroy(shared);
        self.allocator.destroy(self);
    }

    pub fn controlPlaneUrl(self: *const Session) []const u8 {
        return self.shared.control_plane_url;
    }

    /// Requests the browser sign-in. Only valid once discovery succeeded.
    pub fn signIn(self: *Session) bool {
        return self.request(.login, .discovered);
    }

    pub fn loadInventory(self: *Session) bool {
        return self.request(.inventory, .signed_in);
    }

    /// Forgets the OIDC session without touching persisted profiles.
    pub fn signOut(self: *Session) void {
        const shared = self.shared;
        shared.lock();
        defer shared.unlock();
        shared.clearToken();
        shared.clearRuntimes();
        shared.login_url_open = false;
        shared.failure = null;
        shared.phase = if (shared.discovery != null) .discovered else .idle;
    }

    /// Copies the latest worker state into UI-owned buffers.
    pub fn poll(self: *Session) Snapshot {
        const shared = self.shared;
        shared.lock();
        defer shared.unlock();
        for (shared.ui_runtimes.items) |*row| row.deinit(self.allocator);
        shared.ui_runtimes.clearRetainingCapacity();
        for (shared.runtimes.items) |row| {
            const copy = cloneRow(self.allocator, row) catch break;
            shared.ui_runtimes.append(self.allocator, copy) catch {
                var owned = copy;
                owned.deinit(self.allocator);
                break;
            };
        }
        if (shared.ui_issuer) |value| self.allocator.free(value);
        shared.ui_issuer = if (shared.discovery) |discovery|
            self.allocator.dupe(u8, discovery.value().issuer) catch null
        else
            null;
        return .{
            .phase = shared.phase,
            .failure = shared.failure,
            .issuer = shared.ui_issuer,
            .device_flow_advertised = if (shared.discovery) |discovery| discovery.value().oidc.headless_authorization.supported else false,
            .login_url_open = shared.login_url_open,
            .runtimes = shared.ui_runtimes.items,
            .runtimes_truncated = shared.runtimes_truncated,
            .blocker = BLOCKER,
        };
    }

    fn request(self: *Session, command: Command, required: Phase) bool {
        const shared = self.shared;
        shared.lock();
        defer shared.unlock();
        if (shared.phase != required or shared.pending != .none) return false;
        shared.pending = command;
        shared.failure = null;
        shared.phase = switch (command) {
            .login => .signing_in,
            .inventory => .loading_inventory,
            .discover => .discovering,
            .none => unreachable,
        };
        return true;
    }
};

fn cloneRow(allocator: std.mem.Allocator, row: RuntimeRow) !RuntimeRow {
    var out: RuntimeRow = undefined;
    out.link_id = try allocator.dupe(u8, row.link_id);
    errdefer allocator.free(out.link_id);
    out.runtime_id = try allocator.dupe(u8, row.runtime_id);
    errdefer allocator.free(out.runtime_id);
    out.instance_id = try allocator.dupe(u8, row.instance_id);
    errdefer allocator.free(out.instance_id);
    out.https_url = try allocator.dupe(u8, row.https_url);
    errdefer allocator.free(out.https_url);
    out.wss_url = try allocator.dupe(u8, row.wss_url);
    errdefer allocator.free(out.wss_url);
    out.spki_sha256 = try allocator.dupe(u8, row.spki_sha256);
    return out;
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

fn workerMain(shared: *Shared) void {
    var threaded: std.Io.Threaded = .init(shared.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var transport: control_plane.HttpTransport = .{};
    while (!shared.stop_requested.load(.acquire)) {
        const command = takePending(shared);
        switch (command) {
            .none => {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(STOP_POLL_MS), .awake) catch return;
                continue;
            },
            .discover => runDiscover(shared, transport.transport()),
            .login => runLogin(shared, io, transport.transport()),
            .inventory => runInventory(shared, io, transport.transport()),
        }
    }
}

fn takePending(shared: *Shared) Command {
    shared.lock();
    defer shared.unlock();
    const command = shared.pending;
    shared.pending = .none;
    return command;
}

fn fail(shared: *Shared, failure: Failure, fallback: Phase) void {
    shared.lock();
    defer shared.unlock();
    shared.failure = failure;
    shared.phase = fallback;
    shared.login_url_open = false;
}

fn runDiscover(shared: *Shared, transport: control_plane.Transport) void {
    const client = control_plane.Client.init(shared.allocator, transport, shared.control_plane_url) catch {
        return fail(shared, .invalid_url, .failed);
    };
    var discovery = client.discover() catch |err| {
        log.warn("connect discovery failed: {s}", .{@errorName(err)});
        return fail(shared, mapDiscoveryError(err), .failed);
    };
    shared.lock();
    defer shared.unlock();
    if (shared.discovery) |*previous| previous.deinit();
    shared.discovery = discovery;
    shared.phase = .discovered;
    shared.failure = null;
    _ = &discovery;
}

fn mapDiscoveryError(err: anyerror) Failure {
    return switch (err) {
        error.InvalidControlPlaneUrl, error.InvalidControlPlanePath => .invalid_url,
        error.InvalidConnectDiscovery => .invalid_discovery,
        error.ConnectCapabilityMissing => .capability_missing,
        error.ControlPlaneResponseTooLarge, error.ControlPlaneRedirectRejected, error.ControlPlaneRejected, error.ConnectUnavailable => .invalid_discovery,
        error.ConnectRateLimited => .rate_limited,
        error.OutOfMemory => .resource,
        else => .not_reachable,
    };
}

/// One PKCE authorization-code round trip. The verifier and token only ever
/// live in this frame and in `Shared.access_token`.
fn runLogin(shared: *Shared, io: std.Io, transport: control_plane.Transport) void {
    const allocator = shared.allocator;
    const discovery = (shared.discovery orelse return fail(shared, .invalid_discovery, .failed)).value();
    const redirect = pickLoopbackRedirect(discovery.oidc.public_client.redirect_uris) orelse
        return fail(shared, .redirect_unavailable, .discovered);

    var verifier_bytes: [32]u8 = undefined;
    std.Io.randomSecure(io, &verifier_bytes) catch return fail(shared, .resource, .discovered);
    var verifier: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &verifier_bytes);
    defer std.crypto.secureZero(u8, &verifier);
    var challenge_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&verifier, &challenge_digest, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &challenge_digest);
    var state_bytes: [16]u8 = undefined;
    std.Io.randomSecure(io, &state_bytes) catch return fail(shared, .resource, .discovered);
    const state_hex = std.fmt.bytesToHex(state_bytes, .lower);

    // Bind before opening the browser so the callback can never race an
    // unowned port.
    const address = std.Io.net.IpAddress.parse("127.0.0.1", redirect.port) catch
        return fail(shared, .redirect_unavailable, .discovered);
    var listener = address.listen(io, .{ .reuse_address = true }) catch
        return fail(shared, .redirect_unavailable, .discovered);
    defer listener.deinit(io);

    const authorize_url = buildAuthorizeUrlAlloc(allocator, discovery, redirect.uri, &challenge, &state_hex) catch
        return fail(shared, .resource, .discovered);
    defer allocator.free(authorize_url);
    utils.openUrlInDefaultBrowser(allocator, authorize_url) catch
        return fail(shared, .browser_open_failed, .discovered);
    {
        shared.lock();
        defer shared.unlock();
        shared.login_url_open = true;
    }

    var code_buffer: [1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &code_buffer);
    const code = waitForCallback(io, &listener, shared, redirect.path, &state_hex, &code_buffer) catch |err| {
        return fail(shared, switch (err) {
            error.Canceled => .canceled,
            error.LoginTimedOut => .login_timeout,
            else => .login_denied,
        }, .discovered);
    };

    const token = exchangeCodeAlloc(allocator, transport, discovery, redirect.uri, code, &verifier) catch |err| {
        log.warn("connect token exchange failed: {s}", .{@errorName(err)});
        return fail(shared, if (err == error.OutOfMemory) .resource else .token_exchange, .discovered);
    };
    shared.lock();
    defer shared.unlock();
    shared.clearToken();
    shared.access_token = token;
    shared.login_url_open = false;
    shared.phase = .signed_in;
    shared.failure = null;
}

const LoopbackRedirect = struct { uri: []const u8, port: u16, path: []const u8 };

/// RFC 8252 §7.3: only loopback redirects are safe for a native public
/// client, and only ones the control plane registered.
fn pickLoopbackRedirect(candidates: []const []const u8) ?LoopbackRedirect {
    for (candidates) |candidate| {
        const uri = std.Uri.parse(candidate) catch continue;
        if (!std.mem.eql(u8, uri.scheme, "http")) continue;
        const host = uri.host orelse continue;
        const host_text = switch (host) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        if (!std.mem.eql(u8, host_text, "127.0.0.1") and !std.mem.eql(u8, host_text, "localhost")) continue;
        const port = uri.port orelse continue;
        if (port == 0) continue;
        const path = switch (uri.path) {
            .raw => |raw| raw,
            .percent_encoded => |encoded| encoded,
        };
        return .{ .uri = candidate, .port = port, .path = if (path.len == 0) "/" else path };
    }
    return null;
}

fn buildAuthorizeUrlAlloc(
    allocator: std.mem.Allocator,
    discovery: control_plane.Discovery,
    redirect_uri: []const u8,
    challenge: []const u8,
    state: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(discovery.oidc.authorization_endpoint);
    try w.writeAll(if (std.mem.indexOfScalar(u8, discovery.oidc.authorization_endpoint, '?') == null) "?" else "&");
    try w.writeAll("response_type=code&client_id=");
    try writeFormEncoded(w, discovery.oidc.public_client.client_id);
    try w.writeAll("&redirect_uri=");
    try writeFormEncoded(w, redirect_uri);
    try w.writeAll("&scope=");
    for (discovery.oidc.public_client.scopes, 0..) |scope, index| {
        if (index > 0) try w.writeAll("%20");
        try writeFormEncoded(w, scope);
    }
    try w.writeAll("&code_challenge_method=S256&code_challenge=");
    try w.writeAll(challenge);
    try w.writeAll("&state=");
    try w.writeAll(state);
    return out.toOwnedSlice();
}

fn writeFormEncoded(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try w.writeByte(byte);
        } else {
            try w.print("%{X:0>2}", .{byte});
        }
    }
}

const CallbackError = error{ Canceled, LoginTimedOut, InvalidCallback, CodeTooLong };

const AcceptResult = union(enum) {
    connection: std.Io.net.Server.AcceptError!std.Io.net.Stream,
    stop: std.Io.Cancelable!CallbackError!void,
};

fn waitForCallback(
    io: std.Io,
    listener: *std.Io.net.Server,
    shared: *Shared,
    expected_path: []const u8,
    expected_state: []const u8,
    code_out: []u8,
) CallbackError![]const u8 {
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + LOGIN_TIMEOUT_MS;
    while (true) {
        var select_buffer: [2]AcceptResult = undefined;
        var select = std.Io.Select(AcceptResult).init(io, &select_buffer);
        select.async(.connection, std.Io.net.Server.accept, .{ listener, io });
        select.async(.stop, waitForStop, .{ io, shared, deadline });
        defer cancelAccept(&select, io);
        const selected = select.await() catch return error.Canceled;
        const stream = switch (selected) {
            .connection => |result| result catch continue,
            .stop => |result| {
                const inner = result catch return error.Canceled;
                try inner;
                return error.Canceled;
            },
        };
        defer stream.close(io);
        if (readCallbackCode(io, stream, expected_path, expected_state, code_out)) |code| {
            return code;
        } else |err| switch (err) {
            // Browsers also fetch /favicon.ico; keep waiting for the real hit.
            error.NotCallback => continue,
            else => return error.InvalidCallback,
        }
    }
}

fn waitForStop(io: std.Io, shared: *Shared, deadline_ms: i64) std.Io.Cancelable!CallbackError!void {
    while (true) {
        if (shared.stop_requested.load(.acquire)) return;
        // Nested error union: the timeout is a callback outcome, not a cancel.
        if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline_ms) return @as(CallbackError!void, error.LoginTimedOut);
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(STOP_POLL_MS), .awake);
    }
}

// accept can return an owned Stream, so cancellation must inspect and close
// a raced result instead of discarding it.
fn cancelAccept(select: *std.Io.Select(AcceptResult), io: std.Io) void {
    while (select.cancel()) |canceled| {
        switch (canceled) {
            .connection => |result| {
                const stream = result catch continue;
                stream.close(io);
            },
            .stop => {},
        }
    }
}

fn readCallbackCode(
    io: std.Io,
    stream: std.Io.net.Stream,
    expected_path: []const u8,
    expected_state: []const u8,
    code_out: []u8,
) ![]const u8 {
    var receive_buffer: [MAX_CALLBACK_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &receive_buffer);
    var send_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &receive_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return error.InvalidCallback;
    const target = request.head.target;
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (!std.mem.eql(u8, target[0..query_start], expected_path)) {
        request.respond("", .{ .status = .not_found }) catch {};
        return error.NotCallback;
    }
    const query = if (query_start < target.len) target[query_start + 1 ..] else "";
    var code: ?[]const u8 = null;
    var state_ok = false;
    var denied = false;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "code")) {
            code = value;
        } else if (std.mem.eql(u8, key, "state")) {
            state_ok = std.mem.eql(u8, value, expected_state);
        } else if (std.mem.eql(u8, key, "error")) {
            denied = true;
        }
    }
    const accepted = !denied and state_ok and code != null and code.?.len > 0 and code.?.len <= code_out.len;
    request.respond(
        if (accepted) "Verde sign-in complete. You can close this tab." else "Verde sign-in was not accepted.",
        .{ .status = if (accepted) .ok else .bad_request, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} },
    ) catch {};
    if (!accepted) return error.InvalidCallback;
    @memcpy(code_out[0..code.?.len], code.?);
    return code_out[0..code.?.len];
}

fn exchangeCodeAlloc(
    allocator: std.mem.Allocator,
    transport: control_plane.Transport,
    discovery: control_plane.Discovery,
    redirect_uri: []const u8,
    code: []const u8,
    verifier: []const u8,
) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, body.written());
        body.deinit();
    }
    const w = &body.writer;
    try w.writeAll("grant_type=authorization_code&client_id=");
    try writeFormEncoded(w, discovery.oidc.public_client.client_id);
    try w.writeAll("&redirect_uri=");
    try writeFormEncoded(w, redirect_uri);
    try w.writeAll("&code=");
    try writeFormEncoded(w, code);
    try w.writeAll("&code_verifier=");
    try w.writeAll(verifier);
    var response = try transport.send(allocator, .{
        .method = .POST,
        .url = discovery.oidc.token_endpoint,
        .body = body.written(),
        .content_type = "application/x-www-form-urlencoded",
    });
    defer {
        std.crypto.secureZero(u8, response.body);
        response.deinit(allocator);
    }
    if (response.status != .ok) return error.TokenExchangeRejected;
    if (response.body.len > MAX_TOKEN_RESPONSE_BYTES) return error.TokenExchangeRejected;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch return error.TokenExchangeRejected;
    defer parsed.deinit();
    if (parsed.value != .object) return error.TokenExchangeRejected;
    const token = parsed.value.object.get("access_token") orelse return error.TokenExchangeRejected;
    if (token != .string or token.string.len == 0) return error.TokenExchangeRejected;
    if (parsed.value.object.get("token_type")) |token_type| {
        if (token_type != .string or !std.ascii.eqlIgnoreCase(token_type.string, "Bearer")) return error.TokenExchangeRejected;
    }
    return allocator.dupe(u8, token.string);
}

fn runInventory(shared: *Shared, io: std.Io, transport: control_plane.Transport) void {
    const allocator = shared.allocator;
    const client = control_plane.Client.init(allocator, transport, shared.control_plane_url) catch
        return fail(shared, .invalid_url, .failed);
    var request_bytes: [16]u8 = undefined;
    std.Io.randomSecure(io, &request_bytes) catch return fail(shared, .resource, .signed_in);
    var body_buffer: [128]u8 = undefined;
    const request_hex = std.fmt.bytesToHex(request_bytes, .lower);
    const body = std.fmt.bufPrint(&body_buffer, "{{\"contract_version\":\"1\",\"request_id\":\"req_{s}\"}}", .{&request_hex}) catch unreachable;
    const token = blk: {
        shared.lock();
        defer shared.unlock();
        break :blk shared.access_token orelse return fail(shared, .unauthorized, .discovered);
    };
    var response = client.authenticatedJson(.POST, "/v1/runtime-inventory/query", token, body, &.{.ok}) catch |err| {
        log.warn("connect inventory query failed: {s}", .{@errorName(err)});
        return fail(shared, switch (err) {
            error.OutOfMemory => .resource,
            error.ConnectAuthenticationRejected => .unauthorized,
            error.ConnectRateLimited => .rate_limited,
            error.ControlPlaneRejected, error.ConnectConflict, error.ControlPlaneResponseTooLarge, error.ControlPlaneRedirectRejected => .inventory_invalid,
            else => .not_reachable,
        }, .signed_in);
    };
    defer response.deinit(allocator);
    shared.lock();
    defer shared.unlock();
    shared.clearRuntimes();
    parseInventory(shared, response.body) catch |err| {
        shared.clearRuntimes();
        shared.failure = if (err == error.OutOfMemory) .resource else .inventory_invalid;
        shared.phase = .signed_in;
        return;
    };
    shared.phase = .inventory_loaded;
    shared.failure = null;
}

/// Validates every field the desktop will later persist, so a hostile
/// inventory cannot plant an unpinnable or non-https endpoint in a profile.
fn parseInventory(shared: *Shared, json: []const u8) !void {
    const allocator = shared.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInventory;
    const runtimes = parsed.value.object.get("runtimes") orelse return error.InvalidInventory;
    if (runtimes != .array) return error.InvalidInventory;
    for (runtimes.array.items) |item| {
        if (item != .object) return error.InvalidInventory;
        if (shared.runtimes.items.len >= MAX_INVENTORY_ROWS) {
            shared.runtimes_truncated += 1;
            continue;
        }
        const link_id = jsonString(item.object, "link_id") orelse return error.InvalidInventory;
        try profile.validateLinkId(link_id);
        const descriptor_value = item.object.get("descriptor") orelse return error.InvalidInventory;
        if (descriptor_value != .object) return error.InvalidInventory;
        const descriptor = descriptor_value.object;
        const runtime_id = jsonString(descriptor, "runtime_id") orelse return error.InvalidInventory;
        const instance_id = jsonString(descriptor, "instance_id") orelse return error.InvalidInventory;
        const https_url = jsonString(descriptor, "https_url") orelse return error.InvalidInventory;
        const wss_url = jsonString(descriptor, "wss_url") orelse return error.InvalidInventory;
        const tls_value = descriptor.get("tls_identity") orelse return error.InvalidInventory;
        if (tls_value != .object) return error.InvalidInventory;
        const kind = jsonString(tls_value.object, "kind") orelse return error.InvalidInventory;
        if (!std.mem.eql(u8, kind, "spki_sha256")) return error.InvalidInventory;
        const spki = jsonString(tls_value.object, "sha256") orelse return error.InvalidInventory;
        try profile.validateHttpsUrl(https_url);
        try profile.validateWssUrl(wss_url);
        try profile.validateSpkiSha256(spki);
        if (runtime_id.len == 0 or instance_id.len == 0) return error.InvalidInventory;
        var row: RuntimeRow = try cloneRow(allocator, .{
            .link_id = @constCast(link_id),
            .runtime_id = @constCast(runtime_id),
            .instance_id = @constCast(instance_id),
            .https_url = @constCast(https_url),
            .wss_url = @constCast(wss_url),
            .spki_sha256 = @constCast(spki),
        });
        errdefer row.deinit(allocator);
        try shared.runtimes.append(allocator, row);
    }
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "loopback redirect selection accepts only registered loopback http URIs" {
    const picked = pickLoopbackRedirect(&.{ "https://example.test/cb", "http://127.0.0.1:48123/callback" }).?;
    try std.testing.expectEqual(@as(u16, 48123), picked.port);
    try std.testing.expectEqualStrings("/callback", picked.path);
    try std.testing.expect(pickLoopbackRedirect(&.{"http://10.0.0.1:9/cb"}) == null);
    try std.testing.expect(pickLoopbackRedirect(&.{"http://127.0.0.1/cb"}) == null);
}

test "authorize URL form-encodes client id, redirect, and scopes" {
    const allocator = std.testing.allocator;
    const discovery: control_plane.Discovery = .{
        .contract_version = "1",
        .issuer = "https://c.test",
        .api_base_url = "https://c.test",
        .oidc = .{
            .issuer = "https://id.test",
            .authorization_endpoint = "https://id.test/auth",
            .token_endpoint = "https://id.test/token",
            .code_challenge_methods_supported = &.{"S256"},
            .public_client = .{
                .client_id = "verde desktop",
                .scopes = &.{ "openid", "verde:runtime" },
                .redirect_uris = &.{"http://127.0.0.1:48123/callback"},
                .response_type = "code",
                .token_endpoint_auth_method = "none",
            },
            .headless_authorization = .{ .supported = false },
        },
        .jwks_uri = "https://c.test/jwks",
        .signer_metadata_url = "https://c.test/signer",
        .capabilities = &.{},
    };
    const url = try buildAuthorizeUrlAlloc(allocator, discovery, "http://127.0.0.1:48123/callback", "CHALLENGE", "STATE");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://id.test/auth?response_type=code&client_id=verde%20desktop&redirect_uri=http%3A%2F%2F127.0.0.1%3A48123%2Fcallback&scope=openid%20verde%3Aruntime&code_challenge_method=S256&code_challenge=CHALLENGE&state=STATE",
        url,
    );
}

test "inventory parsing rejects unpinnable endpoints and keeps valid rows" {
    const allocator = std.testing.allocator;
    var shared: Shared = .{ .allocator = allocator, .control_plane_url = @constCast("https://c.test") };
    defer {
        shared.clearRuntimes();
        shared.runtimes.deinit(allocator);
    }
    const spki = "A" ** 43;
    const good =
        "{\"contract_version\":\"1\",\"request_id\":\"req_0\",\"runtimes\":[{\"link_id\":\"lnk_" ++ "0" ** 32 ++ "\",\"status\":\"ready\",\"linked_at\":\"x\",\"descriptor\":{\"runtime_id\":\"rt\",\"instance_id\":\"in\",\"https_url\":\"https://rt.test\",\"wss_url\":\"wss://rt.test\",\"tls_identity\":{\"kind\":\"spki_sha256\",\"sha256\":\"" ++ spki ++ "\"}}}]}";
    try parseInventory(&shared, good);
    try std.testing.expectEqual(@as(usize, 1), shared.runtimes.items.len);
    try std.testing.expectEqualStrings("https://rt.test", shared.runtimes.items[0].https_url);
    shared.clearRuntimes();
    const bad =
        "{\"runtimes\":[{\"link_id\":\"lnk_" ++ "0" ** 32 ++ "\",\"descriptor\":{\"runtime_id\":\"rt\",\"instance_id\":\"in\",\"https_url\":\"http://rt.test\",\"wss_url\":\"wss://rt.test\",\"tls_identity\":{\"kind\":\"spki_sha256\",\"sha256\":\"" ++ spki ++ "\"}}}]}";
    try std.testing.expectError(error.InvalidUrl, parseInventory(&shared, bad));
}
