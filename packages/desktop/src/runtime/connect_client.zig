//! Desktop-side Verde Connect session: control-plane discovery, OIDC
//! public-client login (PKCE over a loopback redirect, RFC 8628 device flow
//! only when the control plane advertises it), and the principal-scoped
//! runtime inventory. The session runs on one worker thread; the UI polls a
//! secret-free snapshot. The OIDC access token lives only in this process's
//! memory and is zeroed on sign-out or teardown.
//!
//! Runtime selection continues through a signed control-plane bootstrap and
//! the runtime's public `/auth/connect/bootstrap` exchange. Only the resulting
//! runtime-local device credential leaves this session.

const std = @import("std");
const control_plane = @import("../daemon/connect_client.zig");
const connection = @import("connection.zig");
const gateway_transport = @import("gateway_transport.zig");
const headless = @import("headless");
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
    bootstrapping,
    bootstrap_ready,
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
    bootstrap_rejected,
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
            .bootstrap_rejected => "The control plane or runtime rejected the one-time Connect bootstrap.",
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
};

const Command = enum { none, discover, login, inventory, bootstrap };

pub const BootstrapResult = struct {
    allocator: std.mem.Allocator,
    runtime_id: []u8,
    instance_id: []u8,
    device_id: []u8,
    device_credential: []u8,

    pub fn deinit(self: *BootstrapResult) void {
        self.allocator.free(self.runtime_id);
        self.allocator.free(self.instance_id);
        self.allocator.free(self.device_id);
        std.crypto.secureZero(u8, self.device_credential);
        self.allocator.free(self.device_credential);
        self.* = undefined;
    }
};

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
    principal_issuer: ?[]u8 = null,
    principal_subject: ?[]u8 = null,
    login_url_open: bool = false,
    runtimes: std.ArrayList(RuntimeRow) = .empty,
    runtimes_truncated: usize = 0,
    // Snapshot copies handed to the UI so the worker can mutate freely.
    ui_runtimes: std.ArrayList(RuntimeRow) = .empty,
    ui_issuer: ?[]u8 = null,
    bootstrap_index: ?usize = null,
    bootstrap_label: ?[]u8 = null,
    bootstrap_result: ?BootstrapResult = null,

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
        if (self.principal_issuer) |value| self.allocator.free(value);
        if (self.principal_subject) |value| self.allocator.free(value);
        self.principal_issuer = null;
        self.principal_subject = null;
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
        if (shared.bootstrap_label) |value| self.allocator.free(value);
        if (shared.bootstrap_result) |*result| result.deinit();
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

    pub fn bootstrap(self: *Session, index: usize, device_label: []const u8) bool {
        headless.access_protocol.validateDeviceLabel(device_label) catch return false;
        const shared = self.shared;
        shared.lock();
        defer shared.unlock();
        if (shared.phase != .inventory_loaded or shared.pending != .none or index >= shared.runtimes.items.len) return false;
        const label = self.allocator.dupe(u8, device_label) catch return false;
        if (shared.bootstrap_label) |value| self.allocator.free(value);
        shared.bootstrap_label = label;
        shared.bootstrap_index = index;
        shared.pending = .bootstrap;
        shared.failure = null;
        shared.phase = .bootstrapping;
        return true;
    }

    pub fn takeBootstrapResult(self: *Session) ?BootstrapResult {
        const shared = self.shared;
        shared.lock();
        defer shared.unlock();
        const result = shared.bootstrap_result orelse return null;
        shared.bootstrap_result = null;
        return result;
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
            .bootstrap => .bootstrapping,
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
            .bootstrap => runBootstrap(shared, io, transport.transport()),
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
    defer std.crypto.secureZero(u8, &verifier_bytes);
    std.Io.randomSecure(io, &verifier_bytes) catch return fail(shared, .resource, .discovered);
    var verifier: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &verifier_bytes);
    defer std.crypto.secureZero(u8, &verifier);
    var challenge_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&verifier, &challenge_digest, .{});
    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &challenge_digest);
    var state_bytes: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &state_bytes);
    std.Io.randomSecure(io, &state_bytes) catch return fail(shared, .resource, .discovered);
    var state_hex = std.fmt.bytesToHex(state_bytes, .lower);
    defer std.crypto.secureZero(u8, &state_hex);

    // Bind before opening the browser so the callback can never race an
    // unowned port.
    const address = std.Io.net.IpAddress.parse("127.0.0.1", redirect.port) catch
        return fail(shared, .redirect_unavailable, .discovered);
    var listener = address.listen(io, .{ .reuse_address = true }) catch
        return fail(shared, .redirect_unavailable, .discovered);
    defer listener.deinit(io);

    const authorize_url = buildAuthorizeUrlAlloc(allocator, discovery, redirect.uri, &challenge, &state_hex) catch
        return fail(shared, .resource, .discovered);
    defer {
        std.crypto.secureZero(u8, authorize_url);
        allocator.free(authorize_url);
    }
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

    var tokens = exchangeCodeAlloc(allocator, transport, discovery, redirect.uri, code, &verifier) catch |err| {
        log.warn("connect token exchange failed: {s}", .{@errorName(err)});
        return fail(shared, if (err == error.OutOfMemory) .resource else .token_exchange, .discovered);
    };
    defer tokens.deinit(allocator);
    const principal = principalFromIdTokenAlloc(allocator, tokens.id_token) catch
        return fail(shared, .token_exchange, .discovered);
    shared.lock();
    defer shared.unlock();
    shared.clearToken();
    shared.access_token = tokens.access_token;
    tokens.access_token = tokens.access_token[0..0];
    shared.principal_issuer = principal.issuer;
    shared.principal_subject = principal.subject;
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
    errdefer {
        std.crypto.secureZero(u8, out.written());
        out.deinit();
    }
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
    const code = parseCallbackTarget(request.head.target, expected_path, expected_state, code_out) catch |err| {
        request.respond("Verde sign-in was not accepted.", .{
            .status = if (err == error.NotCallback) .not_found else .bad_request,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        }) catch {};
        return err;
    };
    request.respond("Verde sign-in complete. You can close this tab.", .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    }) catch {};
    return code;
}

fn parseCallbackTarget(
    target: []const u8,
    expected_path: []const u8,
    expected_state: []const u8,
    code_out: []u8,
) ![]const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (!std.mem.eql(u8, target[0..query_start], expected_path)) return error.NotCallback;
    const query = if (query_start < target.len) target[query_start + 1 ..] else "";
    var code_len: ?usize = null;
    var state_seen = false;
    var state_ok = false;
    var denied = false;
    var key_scratch: [32]u8 = undefined;
    var state_scratch: [256]u8 = undefined;
    var value_scratch: [MAX_CALLBACK_BYTES]u8 = undefined;
    defer {
        std.crypto.secureZero(u8, &state_scratch);
        std.crypto.secureZero(u8, &value_scratch);
    }
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidCallback;
        const raw_key = pair[0..eq];
        const raw_value = pair[eq + 1 ..];
        try validatePercentEncoding(raw_key);
        try validatePercentEncoding(raw_value);
        if (raw_key.len > key_scratch.len) continue;
        @memcpy(key_scratch[0..raw_key.len], raw_key);
        const key = std.Uri.percentDecodeInPlace(key_scratch[0..raw_key.len]);
        if (std.mem.eql(u8, key, "code")) {
            if (code_len != null) return error.InvalidCallback;
            const decoded = try percentDecodeBounded(raw_value, &value_scratch);
            if (decoded.len == 0 or decoded.len > code_out.len) return error.CodeTooLong;
            @memcpy(code_out[0..decoded.len], decoded);
            code_len = decoded.len;
        } else if (std.mem.eql(u8, key, "state")) {
            if (state_seen) return error.InvalidCallback;
            state_seen = true;
            const decoded = try percentDecodeBounded(raw_value, &state_scratch);
            state_ok = std.mem.eql(u8, decoded, expected_state);
        } else if (std.mem.eql(u8, key, "error")) {
            denied = true;
        }
    }
    if (denied or !state_ok or code_len == null) return error.InvalidCallback;
    return code_out[0..code_len.?];
}

fn percentDecodeBounded(value: []const u8, scratch: []u8) ![]const u8 {
    if (value.len > scratch.len) return error.CodeTooLong;
    try validatePercentEncoding(value);
    @memcpy(scratch[0..value.len], value);
    return std.Uri.percentDecodeInPlace(scratch[0..value.len]);
}

fn validatePercentEncoding(value: []const u8) !void {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] != '%') continue;
        if (index + 2 >= value.len or !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) {
            return error.InvalidCallback;
        }
        index += 2;
    }
}

const AuthTokens = struct {
    access_token: []u8,
    id_token: []u8,

    fn deinit(self: *AuthTokens, allocator: std.mem.Allocator) void {
        if (self.access_token.len > 0) {
            std.crypto.secureZero(u8, self.access_token);
            allocator.free(self.access_token);
        }
        std.crypto.secureZero(u8, self.id_token);
        allocator.free(self.id_token);
    }
};

fn exchangeCodeAlloc(
    allocator: std.mem.Allocator,
    transport: control_plane.Transport,
    discovery: control_plane.Discovery,
    redirect_uri: []const u8,
    code: []const u8,
    verifier: []const u8,
) !AuthTokens {
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
    const id_token = parsed.value.object.get("id_token") orelse return error.TokenExchangeRejected;
    if (token != .string or token.string.len == 0) return error.TokenExchangeRejected;
    if (id_token != .string or id_token.string.len == 0) return error.TokenExchangeRejected;
    if (parsed.value.object.get("token_type")) |token_type| {
        if (token_type != .string or !std.ascii.eqlIgnoreCase(token_type.string, "Bearer")) return error.TokenExchangeRejected;
    }
    const access_copy = try allocator.dupe(u8, token.string);
    errdefer {
        std.crypto.secureZero(u8, access_copy);
        allocator.free(access_copy);
    }
    return .{ .access_token = access_copy, .id_token = try allocator.dupe(u8, id_token.string) };
}

const Principal = struct { issuer: []u8, subject: []u8 };

// The ID token fields are used only to construct a possession proof which the
// control plane compares against its independently authenticated bearer. They
// are not treated as local authorization evidence.
fn principalFromIdTokenAlloc(allocator: std.mem.Allocator, token: []const u8) !Principal {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidIdToken;
    const payload = parts.next() orelse return error.InvalidIdToken;
    _ = parts.next() orelse return error.InvalidIdToken;
    if (parts.next() != null) return error.InvalidIdToken;
    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload);
    var parsed = try std.json.parseFromSlice(struct { iss: []const u8, sub: []const u8 }, allocator, decoded, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const issuer = try allocator.dupe(u8, parsed.value.iss);
    errdefer allocator.free(issuer);
    return .{ .issuer = issuer, .subject = try allocator.dupe(u8, parsed.value.sub) };
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

const BootstrapGrantResponse = struct {
    contract_version: []const u8,
    request_id: []const u8,
    grant_id: []const u8,
    issuer: []const u8,
    audience: []const u8,
    scopes: []const []const u8,
    expires_at: []const u8,
    grant_jwt: []const u8,
};

const RuntimeBootstrapResponse = struct {
    connect_protocol_version: u32,
    runtime_id: []const u8,
    instance_id: []const u8,
    device_id: []const u8,
    device_credential: []const u8,
    scopes: []const []const u8,
};

fn runBootstrap(shared: *Shared, io: std.Io, transport: control_plane.Transport) void {
    const allocator = shared.allocator;
    const discovery = (shared.discovery orelse return fail(shared, .invalid_discovery, .failed)).value();
    const index = shared.bootstrap_index orelse return fail(shared, .bootstrap_rejected, .inventory_loaded);
    if (index >= shared.runtimes.items.len) return fail(shared, .bootstrap_rejected, .inventory_loaded);
    const row = cloneRow(allocator, shared.runtimes.items[index]) catch
        return fail(shared, .resource, .inventory_loaded);
    defer {
        var owned = row;
        owned.deinit(allocator);
    }
    const token = shared.access_token orelse return fail(shared, .unauthorized, .discovered);
    const principal_issuer = shared.principal_issuer orelse return fail(shared, .token_exchange, .discovered);
    const principal_subject = shared.principal_subject orelse return fail(shared, .token_exchange, .discovered);
    const label = shared.bootstrap_label orelse return fail(shared, .bootstrap_rejected, .inventory_loaded);

    var key_pair = std.crypto.sign.Ed25519.KeyPair.generate(io);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key_pair));
    const public_bytes = key_pair.public_key.toBytes();
    var public_x: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&public_x, &public_bytes);
    var random: [16]u8 = undefined;
    std.Io.randomSecure(io, &random) catch return fail(shared, .resource, .inventory_loaded);
    const random_hex = std.fmt.bytesToHex(random, .lower);
    var request_id_buffer: [36]u8 = undefined;
    const request_id = std.fmt.bufPrint(&request_id_buffer, "req_{s}", .{&random_hex}) catch unreachable;
    std.Io.randomSecure(io, &random) catch return fail(shared, .resource, .inventory_loaded);
    const device_hex = std.fmt.bytesToHex(random, .lower);
    var connect_device_buffer: [36]u8 = undefined;
    const connect_device_id = std.fmt.bufPrint(&connect_device_buffer, "dev_{s}", .{&device_hex}) catch unreachable;
    var kid_buffer: [46]u8 = undefined;
    const kid = std.fmt.bufPrint(&kid_buffer, "verde-desktop-{s}", .{&device_hex}) catch unreachable;
    var nonce_bytes: [32]u8 = undefined;
    std.Io.randomSecure(io, &nonce_bytes) catch return fail(shared, .resource, .inventory_loaded);
    var client_nonce: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&client_nonce, &nonce_bytes);
    var thumbprint: [43]u8 = undefined;
    jwkThumbprint(&thumbprint, &public_x);

    const now_seconds_i64 = std.Io.Clock.real.now(io).toSeconds();
    if (now_seconds_i64 < 0) return fail(shared, .resource, .inventory_loaded);
    const now_seconds: u64 = @intCast(now_seconds_i64);
    var expires_buffer: [32]u8 = undefined;
    const expires_at = formatIso8601(&expires_buffer, now_seconds + 90) catch
        return fail(shared, .resource, .inventory_loaded);
    const request_digest = bootstrapRequestDigestAlloc(
        allocator,
        request_id,
        row,
        connect_device_id,
        &public_x,
        kid,
        &client_nonce,
        expires_at,
    ) catch return fail(shared, .resource, .inventory_loaded);
    defer allocator.free(request_digest);
    const proof = deviceProofJwtAlloc(
        allocator,
        io,
        key_pair,
        kid,
        request_id,
        request_digest,
        connect_device_id,
        &thumbprint,
        principal_issuer,
        principal_subject,
        discovery.issuer,
        now_seconds,
    ) catch return fail(shared, .resource, .inventory_loaded);
    defer {
        std.crypto.secureZero(u8, proof);
        allocator.free(proof);
    }
    const bootstrap_body = bootstrapRequestAlloc(
        allocator,
        request_id,
        row,
        connect_device_id,
        &public_x,
        kid,
        proof,
        &client_nonce,
        expires_at,
    ) catch return fail(shared, .resource, .inventory_loaded);
    defer {
        std.crypto.secureZero(u8, bootstrap_body);
        allocator.free(bootstrap_body);
    }
    const client = control_plane.Client.init(allocator, transport, shared.control_plane_url) catch
        return fail(shared, .invalid_url, .failed);
    var grant_response = client.authenticatedJson(.POST, "/v1/connection-bootstraps", token, bootstrap_body, &.{ .ok, .created }) catch
        return fail(shared, .bootstrap_rejected, .inventory_loaded);
    defer {
        std.crypto.secureZero(u8, grant_response.body);
        grant_response.deinit(allocator);
    }
    var grant = std.json.parseFromSlice(BootstrapGrantResponse, allocator, grant_response.body, .{
        .ignore_unknown_fields = false,
    }) catch return fail(shared, .bootstrap_rejected, .inventory_loaded);
    defer {
        std.crypto.secureZero(u8, @constCast(grant.value.grant_jwt));
        grant.deinit();
    }
    if (!std.mem.eql(u8, grant.value.contract_version, "1") or
        !std.mem.eql(u8, grant.value.request_id, request_id) or
        !std.mem.eql(u8, grant.value.issuer, discovery.issuer) or
        !std.mem.eql(u8, grant.value.audience, row.https_url))
    {
        return fail(shared, .bootstrap_rejected, .inventory_loaded);
    }

    const runtime_body = runtimeBootstrapRequestAlloc(
        allocator,
        grant.value.grant_jwt,
        grant.value.issuer,
        grant.value.audience,
        &client_nonce,
        connect_device_id,
        &thumbprint,
        label,
    ) catch return fail(shared, .resource, .inventory_loaded);
    defer {
        std.crypto.secureZero(u8, runtime_body);
        allocator.free(runtime_body);
    }
    const runtime_url = gateway_transport.endpointUrlAlloc(allocator, row.https_url, "/auth/connect/bootstrap") catch
        return fail(shared, .bootstrap_rejected, .inventory_loaded);
    defer allocator.free(runtime_url);
    var runtime_response = gateway_transport.postHttpsAlloc(allocator, .{
        .url = runtime_url,
        .authorization = null,
        .body = runtime_body,
    }) catch return fail(shared, .bootstrap_rejected, .inventory_loaded);
    defer {
        std.crypto.secureZero(u8, runtime_response.body);
        runtime_response.deinit(allocator);
    }
    if (runtime_response.status != .ok) return fail(shared, .bootstrap_rejected, .inventory_loaded);
    var local = std.json.parseFromSlice(RuntimeBootstrapResponse, allocator, runtime_response.body, .{
        .ignore_unknown_fields = false,
    }) catch return fail(shared, .bootstrap_rejected, .inventory_loaded);
    defer {
        std.crypto.secureZero(u8, @constCast(local.value.device_credential));
        local.deinit();
    }
    if (local.value.connect_protocol_version != 1 or
        !std.mem.eql(u8, local.value.runtime_id, row.runtime_id) or
        !std.mem.eql(u8, local.value.instance_id, row.instance_id))
    {
        return fail(shared, .bootstrap_rejected, .inventory_loaded);
    }
    profile.validateDeviceId(local.value.device_id) catch return fail(shared, .bootstrap_rejected, .inventory_loaded);
    headless.access_protocol.validateSecret(local.value.device_credential) catch
        return fail(shared, .bootstrap_rejected, .inventory_loaded);
    const result = cloneBootstrapResult(allocator, local.value) catch
        return fail(shared, .resource, .inventory_loaded);

    shared.lock();
    defer shared.unlock();
    if (shared.bootstrap_result) |*previous| previous.deinit();
    shared.bootstrap_result = result;
    shared.clearToken();
    if (shared.bootstrap_label) |value| shared.allocator.free(value);
    shared.bootstrap_label = null;
    shared.bootstrap_index = null;
    shared.phase = .bootstrap_ready;
    shared.failure = null;
}

fn cloneBootstrapResult(allocator: std.mem.Allocator, value: RuntimeBootstrapResponse) !BootstrapResult {
    const runtime_id = try allocator.dupe(u8, value.runtime_id);
    errdefer allocator.free(runtime_id);
    const instance_id = try allocator.dupe(u8, value.instance_id);
    errdefer allocator.free(instance_id);
    const device_id = try allocator.dupe(u8, value.device_id);
    errdefer allocator.free(device_id);
    return .{
        .allocator = allocator,
        .runtime_id = runtime_id,
        .instance_id = instance_id,
        .device_id = device_id,
        .device_credential = try allocator.dupe(u8, value.device_credential),
    };
}

fn jwkThumbprint(out: *[43]u8, public_x: *const [43]u8) void {
    var canonical: [91]u8 = undefined;
    const value = std.fmt.bufPrint(&canonical, "{{\"crv\":\"Ed25519\",\"kty\":\"OKP\",\"x\":\"{s}\"}}", .{public_x}) catch unreachable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &digest);
}

fn writePublicJwk(stringify: *std.json.Stringify, public_x: []const u8, kid: []const u8) !void {
    try stringify.beginObject();
    try stringify.objectField("kty");
    try stringify.write("OKP");
    try stringify.objectField("crv");
    try stringify.write("Ed25519");
    try stringify.objectField("x");
    try stringify.write(public_x);
    try stringify.objectField("kid");
    try stringify.write(kid);
    try stringify.objectField("use");
    try stringify.write("sig");
    try stringify.objectField("alg");
    try stringify.write("EdDSA");
    try stringify.endObject();
}

fn bootstrapRequestDigestAlloc(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    row: RuntimeRow,
    device_id: []const u8,
    public_x: []const u8,
    kid: []const u8,
    client_nonce: []const u8,
    expires_at: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    // RFC 8785 ordering for this fixed schema, including the nested JWK.
    const w = &out.writer;
    try w.writeAll("{\"audience\":");
    try std.json.Stringify.value(row.https_url, .{}, w);
    try w.writeAll(",\"client_nonce\":");
    try std.json.Stringify.value(client_nonce, .{}, w);
    try w.writeAll(",\"contract_version\":\"1\",\"device_id\":");
    try std.json.Stringify.value(device_id, .{}, w);
    try w.writeAll(",\"device_signing_jwk\":{\"alg\":\"EdDSA\",\"crv\":\"Ed25519\",\"kid\":");
    try std.json.Stringify.value(kid, .{}, w);
    try w.writeAll(",\"kty\":\"OKP\",\"use\":\"sig\",\"x\":");
    try std.json.Stringify.value(public_x, .{}, w);
    try w.writeAll("},\"expires_at\":");
    try std.json.Stringify.value(expires_at, .{}, w);
    try w.writeAll(",\"instance_id\":");
    try std.json.Stringify.value(row.instance_id, .{}, w);
    try w.writeAll(",\"request_id\":");
    try std.json.Stringify.value(request_id, .{}, w);
    try w.writeAll(",\"runtime_id\":");
    try std.json.Stringify.value(row.runtime_id, .{}, w);
    try w.writeAll(",\"scopes\":");
    try std.json.Stringify.value(&headless.access_protocol.DEFAULT_SCOPE_NAMES, .{}, w);
    try w.writeByte('}');
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
    const encoded = try allocator.alloc(u8, 43);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &digest);
    return encoded;
}

fn bootstrapRequestAlloc(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    row: RuntimeRow,
    device_id: []const u8,
    public_x: []const u8,
    kid: []const u8,
    proof: []const u8,
    client_nonce: []const u8,
    expires_at: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    inline for (.{ "contract_version", "request_id", "runtime_id", "instance_id", "device_id" }) |name| {
        try stringify.objectField(name);
        try stringify.write(if (std.mem.eql(u8, name, "contract_version")) "1" else if (std.mem.eql(u8, name, "request_id")) request_id else if (std.mem.eql(u8, name, "runtime_id")) row.runtime_id else if (std.mem.eql(u8, name, "instance_id")) row.instance_id else device_id);
    }
    try stringify.objectField("device_signing_jwk");
    try writePublicJwk(&stringify, public_x, kid);
    try stringify.objectField("device_proof_jwt");
    try stringify.write(proof);
    try stringify.objectField("audience");
    try stringify.write(row.https_url);
    try stringify.objectField("client_nonce");
    try stringify.write(client_nonce);
    try stringify.objectField("scopes");
    try stringify.write(&headless.access_protocol.DEFAULT_SCOPE_NAMES);
    try stringify.objectField("expires_at");
    try stringify.write(expires_at);
    try stringify.endObject();
    return out.toOwnedSlice();
}

fn deviceProofJwtAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    key_pair: std.crypto.sign.Ed25519.KeyPair,
    kid: []const u8,
    request_id: []const u8,
    request_digest: []const u8,
    device_id: []const u8,
    thumbprint: []const u8,
    principal_issuer: []const u8,
    principal_subject: []const u8,
    control_plane_audience: []const u8,
    now_seconds: u64,
) ![]u8 {
    var header: std.Io.Writer.Allocating = .init(allocator);
    defer header.deinit();
    try header.writer.print("{{\"alg\":\"EdDSA\",\"kid\":{},\"typ\":\"verde-connect-device-proof+jwt\"}}", .{std.json.fmt(kid, .{})});
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    var stringify: std.json.Stringify = .{ .writer = &payload.writer };
    try stringify.beginObject();
    const fields = .{
        .{ "contract_version", "1" },
        .{ "request_id", request_id },
        .{ "request_digest", request_digest },
        .{ "device_id", device_id },
        .{ "device_key_thumbprint", thumbprint },
    };
    inline for (fields) |field| {
        try stringify.objectField(field[0]);
        try stringify.write(field[1]);
    }
    try stringify.objectField("principal");
    try stringify.beginObject();
    try stringify.objectField("issuer");
    try stringify.write(principal_issuer);
    try stringify.objectField("subject");
    try stringify.write(principal_subject);
    try stringify.endObject();
    var issuer_buffer: [80]u8 = undefined;
    const device_issuer = std.fmt.bufPrint(&issuer_buffer, "urn:verde:connect-device:{s}", .{device_id}) catch unreachable;
    try stringify.objectField("iss");
    try stringify.write(device_issuer);
    try stringify.objectField("sub");
    try stringify.write(device_id);
    try stringify.objectField("aud");
    try stringify.write(control_plane_audience);
    try stringify.objectField("jti");
    try stringify.write(request_id);
    for ([_][]const u8{ "iat", "nbf" }) |name| {
        try stringify.objectField(name);
        try stringify.write(now_seconds);
    }
    try stringify.objectField("exp");
    try stringify.write(now_seconds + 90);
    try stringify.endObject();

    const header_b64 = try base64UrlAlloc(allocator, header.written());
    defer allocator.free(header_b64);
    const payload_b64 = try base64UrlAlloc(allocator, payload.written());
    defer allocator.free(payload_b64);
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signing_input);
    var noise: [std.crypto.sign.Ed25519.noise_length]u8 = undefined;
    std.Io.randomSecure(io, &noise) catch return error.OutOfMemory;
    const signature = try key_pair.sign(signing_input, noise);
    const signature_b64 = try base64UrlAlloc(allocator, &signature.toBytes());
    defer allocator.free(signature_b64);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, signature_b64 });
}

fn base64UrlAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(source.len);
    const encoded = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, source);
    return encoded;
}

fn runtimeBootstrapRequestAlloc(
    allocator: std.mem.Allocator,
    grant_jwt: []const u8,
    issuer: []const u8,
    audience: []const u8,
    client_nonce: []const u8,
    connect_device_id: []const u8,
    thumbprint: []const u8,
    device_label: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("connect_protocol_version");
    try stringify.write(1);
    const fields = .{
        .{ "grant_jwt", grant_jwt },
        .{ "expected_issuer", issuer },
        .{ "expected_audience", audience },
        .{ "client_nonce", client_nonce },
        .{ "connect_device_id", connect_device_id },
        .{ "device_key_thumbprint", thumbprint },
        .{ "device_label", device_label },
    };
    inline for (fields) |field| {
        try stringify.objectField(field[0]);
        try stringify.write(field[1]);
    }
    try stringify.endObject();
    return out.toOwnedSlice();
}

fn formatIso8601(buffer: *[32]u8, seconds: u64) ![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
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
        try profile.validateRuntimeEndpointPair(https_url, wss_url);
        try profile.validateSpkiSha256(spki);
        try connection.validateRuntimeId(runtime_id);
        try connection.validateRuntimeId(instance_id);
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

test "OAuth callback percent-decodes opaque code and state" {
    var code_buffer: [128]u8 = undefined;
    defer std.crypto.secureZero(u8, &code_buffer);
    const code = try parseCallbackTarget(
        "/callback?code=opaque%2Fvalue%2Bpart&state=expected%2Dstate",
        "/callback",
        "expected-state",
        &code_buffer,
    );
    try std.testing.expectEqualStrings("opaque/value+part", code);

    const reversed = try parseCallbackTarget(
        "/callback?state=expected%2Dstate&code=second%2Fcode",
        "/callback",
        "expected-state",
        &code_buffer,
    );
    try std.testing.expectEqualStrings("second/code", reversed);
}

test "OAuth callback rejects malformed percent escapes" {
    var code_buffer: [128]u8 = undefined;
    defer std.crypto.secureZero(u8, &code_buffer);
    try std.testing.expectError(
        error.InvalidCallback,
        parseCallbackTarget("/callback?code=opaque%2&state=expected", "/callback", "expected", &code_buffer),
    );
}

test "OAuth callback rejects duplicate state" {
    var code_buffer: [128]u8 = undefined;
    defer std.crypto.secureZero(u8, &code_buffer);
    try std.testing.expectError(
        error.InvalidCallback,
        parseCallbackTarget("/callback?code=opaque&state=expected&state=expected", "/callback", "expected", &code_buffer),
    );
}

test "OAuth callback rejects duplicate code and ignores favicon requests" {
    var code_buffer: [128]u8 = undefined;
    defer std.crypto.secureZero(u8, &code_buffer);
    try std.testing.expectError(
        error.InvalidCallback,
        parseCallbackTarget("/callback?code=first&state=expected&code=second", "/callback", "expected", &code_buffer),
    );
    try std.testing.expectError(
        error.NotCallback,
        parseCallbackTarget("/favicon.ico", "/callback", "expected", &code_buffer),
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
        "{\"contract_version\":\"1\",\"request_id\":\"req_0\",\"runtimes\":[{\"link_id\":\"lnk_" ++ "0" ** 32 ++ "\",\"status\":\"ready\",\"linked_at\":\"x\",\"descriptor\":{\"runtime_id\":\"" ++ "1" ** 32 ++ "\",\"instance_id\":\"" ++ "2" ** 32 ++ "\",\"https_url\":\"https://rt.test\",\"wss_url\":\"wss://rt.test/ws\",\"tls_identity\":{\"kind\":\"spki_sha256\",\"sha256\":\"" ++ spki ++ "\"}}}]}";
    try parseInventory(&shared, good);
    try std.testing.expectEqual(@as(usize, 1), shared.runtimes.items.len);
    try std.testing.expectEqualStrings("https://rt.test", shared.runtimes.items[0].https_url);
    shared.clearRuntimes();
    const bad =
        "{\"runtimes\":[{\"link_id\":\"lnk_" ++ "0" ** 32 ++ "\",\"descriptor\":{\"runtime_id\":\"" ++ "1" ** 32 ++ "\",\"instance_id\":\"" ++ "2" ** 32 ++ "\",\"https_url\":\"http://rt.test\",\"wss_url\":\"wss://rt.test/ws\",\"tls_identity\":{\"kind\":\"spki_sha256\",\"sha256\":\"" ++ spki ++ "\"}}}]}";
    try std.testing.expectError(error.InvalidUrl, parseInventory(&shared, bad));
}
