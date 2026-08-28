//! Loopback-only HTTP and WebSocket gateway for the Solid client.

const std = @import("std");
const headless = @import("headless");

const auth_mod = @import("auth.zig");
const config_mod = @import("config.zig");
const daemon_mod = @import("daemon.zig");
const theme_mod = @import("theme.zig");

const log = std.log.scoped(.web_http);

pub const MAX_CONNECTIONS: usize = 64;
pub const MAX_WEBSOCKETS: usize = 16;
pub const MAX_KEEPALIVE_REQUESTS: usize = 32;
pub const MAX_HEADER_BYTES: usize = 4 * 1024;
pub const MAX_LOGIN_BODY_BYTES: usize = 4 * 1024;
pub const MAX_ACCESS_BODY_BYTES: usize = headless.access_protocol.MAX_PAIR_EXCHANGE_BODY_BYTES;
pub const MAX_RPC_FRAME_BYTES: usize = daemon_mod.MAX_GATEWAY_RPC_BYTES;

const MIN_CHANGES_RETRY_MS: u64 = 250;
const WEB_CHAT_IMAGE_DIR = "web-chat-images";
const MAX_CHAT_IMAGE_BYTES: usize = 10 * 1024 * 1024;
const CSP = "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; worker-src 'self'";

const LOGIN_HTML =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>Sign in to Verde</title>
    \\  <style>
    \\    :root { color-scheme: dark; font-family: ui-sans-serif, system-ui, sans-serif; }
    \\    body { min-height: 100vh; margin: 0; display: grid; place-items: center; background: #0d1213; color: #e7ece8; }
    \\    main { width: min(28rem, calc(100% - 2rem)); }
    \\    form { display: grid; gap: 1rem; padding: 2rem; border: 1px solid #263230; border-radius: 1rem; background: #141c1d; }
    \\    h1 { margin: 0; font-size: 1.5rem; font-weight: 600; }
    \\    p { margin: 0; color: #aebbb6; line-height: 1.5; }
    \\    label { display: grid; gap: .5rem; }
    \\    input, button { box-sizing: border-box; width: 100%; min-height: 2.75rem; border-radius: .6rem; font: inherit; }
    \\    input { border: 1px solid #3a4a47; padding: .65rem .8rem; background: #0b1011; color: inherit; }
    \\    button { border: 0; padding: .65rem .8rem; background: #50c878; color: #06210f; font-weight: 700; cursor: pointer; }
    \\    button:disabled { opacity: .6; cursor: wait; }
    \\    #error { min-height: 1.5rem; color: #ff9b96; }
    \\  </style>
    \\  <script src="/login.js" defer></script>
    \\</head>
    \\<body>
    \\  <main>
    \\    <form id="login" method="post" action="/auth/session">
    \\      <h1>Sign in to Verde</h1>
    \\      <p>Enter the token stored on the remote Verde host. It is exchanged for an HttpOnly browser session and is never put in the URL or browser storage.</p>
    \\      <label>Access token<input id="token" name="token" type="password" autocomplete="off" autocapitalize="none" spellcheck="false" required autofocus></label>
    \\      <button type="submit">Continue</button>
    \\      <p id="error" role="alert" aria-live="polite"></p>
    \\    </form>
    \\  </main>
    \\</body>
    \\</html>
;

const LOGIN_JS =
    \\(() => {
    \\  'use strict';
    \\  const form = document.querySelector('#login');
    \\  const input = document.querySelector('#token');
    \\  const button = form.querySelector('button');
    \\  const error = document.querySelector('#error');
    \\  form.addEventListener('submit', async (event) => {
    \\    event.preventDefault();
    \\    button.disabled = true;
    \\    error.textContent = '';
    \\    const token = input.value;
    \\    input.value = '';
    \\    try {
    \\      const response = await fetch('/auth/session', {
    \\        method: 'POST',
    \\        credentials: 'same-origin',
    \\        headers: { 'content-type': 'application/json' },
    \\        body: JSON.stringify({ token }),
    \\      });
    \\      if (!response.ok) throw new Error(response.status === 429 ? 'Too many attempts. Try again later.' : 'The access token was not accepted.');
    \\      window.location.replace('/');
    \\    } catch (reason) {
    \\      error.textContent = reason instanceof Error ? reason.message : 'Unable to sign in.';
    \\      input.focus();
    \\    } finally {
    \\      button.disabled = false;
    \\    }
    \\  });
    \\})();
;

const BASE_SECURITY_HEADERS = [_]std.http.Header{
    .{ .name = "content-security-policy", .value = CSP },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "cross-origin-resource-policy", .value = "same-origin" },
};

const Runtime = struct {
    connection_slots: std.Io.Semaphore = .{ .permits = MAX_CONNECTIONS },
    active_websockets: std.atomic.Value(usize) = .init(0),

    fn tryAcquireWebSocket(self: *Runtime) bool {
        var active = self.active_websockets.load(.acquire);
        while (active < MAX_WEBSOCKETS) {
            if (self.active_websockets.cmpxchgWeak(
                active,
                active + 1,
                .acq_rel,
                .acquire,
            )) |observed| {
                active = observed;
            } else {
                return true;
            }
        }
        return false;
    }

    fn releaseWebSocket(self: *Runtime) void {
        const previous = self.active_websockets.fetchSub(1, .release);
        std.debug.assert(previous > 0);
    }
};

pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    env_map: *const std.process.Environ.Map,
) !void {
    const bind_host = if (std.ascii.eqlIgnoreCase(config.host, "localhost"))
        "127.0.0.1"
    else
        config.host;
    const address = try std.Io.net.IpAddress.parse(bind_host, config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("verde-web listening on http://{f}/\n", .{listener.socket.address});
    std.debug.print("  daemon socket   {s}\n", .{config.sessionizer_endpoint});
    std.debug.print("  static          {s}\n", .{config.static_dir});
    std.debug.print("  access          SSH tunnel to this loopback listener\n", .{});

    var runtime: Runtime = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        try runtime.connection_slots.wait(io);
        const stream = listener.accept(io) catch |err| switch (err) {
            error.Canceled => {
                runtime.connection_slots.post(io);
                return;
            },
            else => {
                runtime.connection_slots.post(io);
                log.err("accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        group.concurrent(
            io,
            handleConnection,
            .{ allocator, io, config, daemon, auth, env_map, &runtime, stream },
        ) catch |err| {
            runtime.connection_slots.post(io);
            log.err("unable to spawn connection: {s}", .{@errorName(err)});
            var copy = stream;
            copy.close(io);
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    env_map: *const std.process.Environ.Map,
    runtime: *Runtime,
    stream: std.Io.net.Stream,
) void {
    defer runtime.connection_slots.post(io);
    defer {
        var copy = stream;
        copy.close(io);
    }

    // `receiveHead` cannot consume more than this backing buffer, so the
    // advertised 4 KiB header ceiling is also the parser's allocation ceiling.
    var recv_buffer: [MAX_HEADER_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, recv_buffer[0..]);
    var send_buffer: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, send_buffer[0..]);
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    var client_address = stream.socket.address;
    client_address.setPort(0);
    var client_key_buffer: [128]u8 = undefined;
    const client_key = std.fmt.bufPrint(&client_key_buffer, "{f}", .{client_address}) catch "loopback";

    var request_count: usize = 0;
    while (request_count < MAX_KEEPALIVE_REQUESTS) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                log.err("receiveHead: {s}", .{@errorName(err)});
                return;
            },
        };
        request_count += 1;
        if (request_count == MAX_KEEPALIVE_REQUESTS) request.head.keep_alive = false;

        if (request.head_buffer.len > MAX_HEADER_BYTES) {
            request.head.keep_alive = false;
            respondJson(
                &request,
                .request_header_fields_too_large,
                "{\"ok\":false,\"error\":\"headers_too_large\"}",
            ) catch {};
            return;
        }
        if (!requestEnvelopeAllowed(&request)) {
            respondJson(&request, .bad_request, "{\"ok\":false,\"error\":\"invalid_request_origin\"}") catch {};
            if (!request.head.keep_alive) return;
            continue;
        }
        if (request.head.method == .OPTIONS) {
            respondJson(&request, .method_not_allowed, "{\"ok\":false,\"error\":\"options_not_supported\"}") catch {};
            if (!request.head.keep_alive) return;
            continue;
        }

        switch (request.upgradeRequested()) {
            .websocket => |opt_key| {
                handleWebSocketUpgrade(
                    allocator,
                    io,
                    daemon,
                    auth,
                    runtime,
                    client_key,
                    &request,
                    opt_key,
                ) catch |err| log.err("websocket session: {s}", .{@errorName(err)});
                return;
            },
            .other => {
                respondJson(&request, .bad_request, "{\"ok\":false,\"error\":\"unsupported_upgrade\"}") catch {};
                return;
            },
            .none => {
                handleRequest(
                    allocator,
                    io,
                    config,
                    daemon,
                    auth,
                    env_map,
                    client_key,
                    &request,
                ) catch |err| {
                    log.err("request failed: {s}", .{@errorName(err)});
                    return;
                };
            },
        }
        if (!request.head.keep_alive) return;
    }
}

fn handleWebSocketUpgrade(
    allocator: std.mem.Allocator,
    io: std.Io,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    runtime: *Runtime,
    client_key: []const u8,
    request: *std.http.Server.Request,
    opt_key: ?[]const u8,
) !void {
    if (!webSocketTargetAllowed(request.head.method, request.head.target)) {
        try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"websocket_not_found\"}");
        return;
    }
    var auth_context = if (try authenticate(auth, io, request)) |owner|
        try webSocketAuthenticationFromOwner(owner)
    else pair: {
        const now_ms = auth_mod.nowMillis(io);
        if (try auth.ticketPreflight(io, client_key, now_ms) == .rate_limited) {
            try respondJson(request, .too_many_requests, "{\"ok\":false,\"error\":\"ticket_auth_rate_limited\"}");
            return;
        }
        const ticket = parsePairWebSocketProtocols(request) orelse {
            _ = try auth.recordTicketAttempt(io, client_key, false, now_ms);
            try respondUnauthorized(request);
            return;
        };
        defer std.crypto.secureZero(u8, @constCast(ticket));
        var claims = (try auth.pair_credentials.consumeWebSocketTicket(
            io,
            ticket,
            auth_mod.nowMillis(io),
        )) orelse {
            _ = try auth.recordTicketAttempt(io, client_key, false, now_ms);
            try respondUnauthorized(request);
            return;
        };
        _ = try auth.recordTicketAttempt(io, client_key, true, now_ms);
        errdefer claims.clear();
        const bootstrap_mask = headless.access_protocol.webSocketBootstrapScopeMask();
        if (!headless.access_protocol.scopeMaskContains(claims.scope_mask, bootstrap_mask) or
            !authorizePairClaims(allocator, daemon, auth, claims, bootstrap_mask))
        {
            claims.clear();
            try respondJson(request, .forbidden, "{\"ok\":false,\"error\":\"insufficient_scope\"}");
            return;
        }
        break :pair WsAuthentication{ .pair = claims };
    };
    defer auth_context.clear();
    if (!requestOriginAllowed(request, auth_context == .owner_session)) {
        try respondJson(request, .forbidden, "{\"ok\":false,\"error\":\"origin_forbidden\"}");
        return;
    }
    if (!runtime.tryAcquireWebSocket()) {
        try respondJson(request, .service_unavailable, "{\"ok\":false,\"error\":\"websocket_limit\"}");
        return;
    }
    defer runtime.releaseWebSocket();

    const key = opt_key orelse {
        try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"missing_websocket_key\"}");
        return;
    };
    const owner_headers = BASE_SECURITY_HEADERS ++ [_]std.http.Header{
        .{ .name = "cache-control", .value = "no-store" },
    };
    const pair_headers = owner_headers ++ [_]std.http.Header{
        .{ .name = "sec-websocket-protocol", .value = headless.access_protocol.WEBSOCKET_PROTOCOL_NAME },
    };
    var socket = try request.respondWebSocket(.{
        .key = key,
        .extra_headers = if (auth_context == .pair) &pair_headers else &owner_headers,
    });
    try socket.flush();

    // HTTP headers are parsed from a 4 KiB buffer. Only an accepted WebSocket
    // upgrades to the bounded 1 MiB frame buffer, preserving any bytes that
    // arrived in the same packet as the upgrade request.
    const websocket_buffer = try allocator.alloc(u8, MAX_RPC_FRAME_BYTES + 14);
    defer allocator.free(websocket_buffer);
    const unread = socket.input.buffer[socket.input.seek..socket.input.end];
    if (unread.len > websocket_buffer.len) return error.MessageOversize;
    @memcpy(websocket_buffer[0..unread.len], unread);
    socket.input.buffer = websocket_buffer;
    socket.input.seek = 0;
    socket.input.end = unread.len;

    try serveWebSocket(allocator, io, daemon, auth, auth_context, &socket);
}

fn handleRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    env_map: *const std.process.Environ.Map,
    client_key: []const u8,
    request: *std.http.Server.Request,
) !void {
    const split = splitTarget(request.head.target);

    if (std.mem.eql(u8, split.path, "/healthz")) {
        if (request.head.method != .GET) return respondMethodNotAllowed(request);
        try respondJson(request, .ok, "{\"ok\":true}");
        return;
    }

    if (std.mem.eql(u8, split.path, "/auth/session")) {
        if (request.head.method != .POST) return respondMethodNotAllowed(request);
        if (!requestOriginAllowed(request, true)) {
            try respondJson(request, .forbidden, "{\"ok\":false,\"error\":\"origin_forbidden\"}");
            return;
        }
        try handleLogin(allocator, io, auth, client_key, request);
        return;
    }

    if (std.mem.eql(u8, split.path, headless.access_protocol.HTTP_PAIR_EXCHANGE_PATH)) {
        if (request.head.method != .POST) return respondMethodNotAllowed(request);
        if (!requestOriginAllowed(request, false)) {
            try respondJson(request, .forbidden, "{\"ok\":false,\"error\":\"origin_forbidden\"}");
            return;
        }
        try handlePairExchange(allocator, io, daemon, auth, client_key, request);
        return;
    }

    if (std.mem.eql(u8, split.path, headless.access_protocol.HTTP_ACCESS_TOKEN_PATH)) {
        if (request.head.method != .POST) return respondMethodNotAllowed(request);
        if (!requestOriginAllowed(request, false)) {
            try respondJson(request, .forbidden, "{\"ok\":false,\"error\":\"origin_forbidden\"}");
            return;
        }
        try handleAccessToken(allocator, io, daemon, auth, client_key, request);
        return;
    }

    if (std.mem.eql(u8, split.path, headless.access_protocol.HTTP_WEBSOCKET_TICKET_PATH)) {
        if (request.head.method != .POST) return respondMethodNotAllowed(request);
        if (!requestOriginAllowed(request, false)) {
            try respondJson(request, .forbidden, "{\"ok\":false,\"error\":\"origin_forbidden\"}");
            return;
        }
        try handleWebSocketTicket(allocator, io, daemon, auth, client_key, request);
        return;
    }

    if (std.mem.eql(u8, split.path, "/login")) {
        if (request.head.method != .GET and request.head.method != .HEAD) return respondMethodNotAllowed(request);
        try respondAuthAsset(request, "text/html; charset=utf-8", LOGIN_HTML);
        return;
    }

    if (std.mem.eql(u8, split.path, "/login.js")) {
        if (request.head.method != .GET and request.head.method != .HEAD) return respondMethodNotAllowed(request);
        try respondAuthAsset(request, "text/javascript; charset=utf-8", LOGIN_JS);
        return;
    }

    if (isApiPath(split.path)) {
        const auth_context = try authenticateApi(auth, io, request) orelse {
            try respondUnauthorized(request);
            return;
        };
        const state_changing = request.head.method != .GET and request.head.method != .HEAD;
        if (!requestOriginAllowed(request, state_changing and auth_context == .owner_session)) {
            try respondJson(request, .forbidden, "{\"ok\":false,\"error\":\"origin_forbidden\"}");
            return;
        }
        try handleApi(allocator, io, config, daemon, auth, env_map, auth_context, split, request);
        return;
    }

    if (std.mem.eql(u8, split.path, "/ws") or std.mem.startsWith(u8, split.path, "/ws/")) {
        try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"websocket_upgrade_required\"}");
        return;
    }

    // Keep hashed/static assets public so the login and app shells can load,
    // but direct unauthenticated navigation lands on the built-in login flow.
    if ((request.head.method == .GET or request.head.method == .HEAD) and
        !looksLikeAsset(split.path) and
        (try authenticate(auth, io, request)) == null)
    {
        try respondLoginRedirect(request);
        return;
    }

    if (request.head.method == .GET or request.head.method == .HEAD) {
        if (try serveStatic(allocator, io, config.static_dir, split.path, request)) return;
    }
    try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"not_found\"}");
}

fn handleLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth: *auth_mod.Service,
    client_key: []const u8,
    request: *std.http.Server.Request,
) !void {
    if (!contentTypeIsJson(requestContentType(request))) {
        try respondJson(request, .unsupported_media_type, "{\"ok\":false,\"error\":\"expected_json\"}");
        return;
    }
    if (request.head.content_length) |length| {
        if (length > MAX_LOGIN_BODY_BYTES) {
            request.head.keep_alive = false;
            try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"login_body_too_large\"}");
            return;
        }
    }
    const body_reader = try request.readerExpectContinue(&.{});
    const body = body_reader.allocRemaining(allocator, .limited(MAX_LOGIN_BODY_BYTES)) catch {
        request.head.keep_alive = false;
        try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"login_body_too_large\"}");
        return;
    };
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }

    const LoginBody = struct { token: []const u8 };
    var parsed = std.json.parseFromSlice(LoginBody, allocator, body, .{}) catch {
        try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_login_json\"}");
        return;
    };
    defer {
        std.crypto.secureZero(u8, @constCast(parsed.value.token));
        parsed.deinit();
    }
    if (parsed.value.token.len > auth_mod.TOKEN_MAX_BYTES) {
        try respondJson(request, .unauthorized, "{\"ok\":false,\"error\":\"invalid_credentials\"}");
        return;
    }

    const login = try auth.login(io, client_key, parsed.value.token, auth_mod.nowMillis(io));
    switch (login) {
        .invalid_credentials => try respondJson(
            request,
            .unauthorized,
            "{\"ok\":false,\"error\":\"invalid_credentials\"}",
        ),
        .rate_limited => try respondJson(
            request,
            .too_many_requests,
            "{\"ok\":false,\"error\":\"login_rate_limited\"}",
        ),
        .session => |issued_value| {
            var issued = issued_value;
            defer issued.clear();
            var cookie_buffer: [256]u8 = undefined;
            defer std.crypto.secureZero(u8, cookie_buffer[0..]);
            const cookie = try auth_mod.formatSessionCookie(&cookie_buffer, &issued);
            var body_buffer: [128]u8 = undefined;
            const response_body = try std.fmt.bufPrint(
                &body_buffer,
                "{{\"ok\":true,\"max_age_seconds\":{d}}}",
                .{issued.max_age_seconds},
            );
            const headers = BASE_SECURITY_HEADERS ++ [_]std.http.Header{
                .{ .name = "content-type", .value = "application/json; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "set-cookie", .value = cookie },
            };
            try request.respond(response_body, .{
                .status = .ok,
                .extra_headers = &headers,
            });
        },
    }
}

fn handlePairExchange(
    allocator: std.mem.Allocator,
    io: std.Io,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    client_key: []const u8,
    request: *std.http.Server.Request,
) !void {
    const now_ms = auth_mod.nowMillis(io);
    if (try auth.pairPreflight(io, client_key, now_ms) == .rate_limited) {
        try respondJson(request, .too_many_requests, "{\"ok\":false,\"error\":\"pairing_rate_limited\"}");
        return;
    }
    if (!contentTypeIsJson(requestContentType(request))) {
        try respondJson(request, .unsupported_media_type, "{\"ok\":false,\"error\":\"expected_json\"}");
        return;
    }
    const body = readBoundedSecretBody(allocator, request, MAX_ACCESS_BODY_BYTES) catch |err| switch (err) {
        error.AccessBodyTooLarge => {
            request.head.keep_alive = false;
            try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"access_body_too_large\"}");
            return;
        },
        else => return err,
    };
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    var parsed = headless.access_protocol.parsePairingGrantExchangeRequest(allocator, body) catch {
        _ = try auth.recordPairAttempt(io, client_key, false, now_ms);
        try respondJson(request, .unauthorized, "{\"ok\":false,\"error\":\"invalid_pairing_grant\"}");
        return;
    };
    defer {
        std.crypto.secureZero(u8, @constCast(parsed.value.pairing_token.reveal()));
        parsed.deinit();
    }

    const daemon_result = callPairingExchangeTargetedAfterBootstrap(
        allocator,
        daemon,
        parsed.value,
    ) catch {
        try respondDaemonUnavailable(request);
        return;
    };
    defer {
        std.crypto.secureZero(u8, daemon_result.json);
        allocator.free(daemon_result.json);
    }
    var envelope = headless.parseResponse(allocator, daemon_result.json) catch {
        try respondDaemonUnavailable(request);
        return;
    };
    defer envelope.deinit();
    const result_value = envelope.response.result orelse {
        const invalid = rpcErrorCode(envelope.response.err) orelse "";
        if (std.mem.eql(u8, invalid, "authentication_rejected")) {
            _ = try auth.recordPairAttempt(io, client_key, false, now_ms);
            try respondJson(request, .unauthorized, "{\"ok\":false,\"error\":\"invalid_pairing_grant\"}");
        } else {
            try respondJson(request, .service_unavailable, "{\"ok\":false,\"error\":\"pairing_unavailable\"}");
        }
        return;
    };
    defer eraseJsonStringField(result_value, "device_credential");
    var exchanged = std.json.parseFromValue(
        headless.access_protocol.PairingGrantExchangeResult,
        allocator,
        result_value,
        .{},
    ) catch {
        try respondDaemonUnavailable(request);
        return;
    };
    defer {
        std.crypto.secureZero(u8, @constCast(exchanged.value.device_credential.reveal()));
        exchanged.deinit();
    }
    if (exchanged.value.access_protocol_version != headless.access_protocol.ACCESS_PROTOCOL_VERSION) {
        try respondDaemonUnavailable(request);
        return;
    }
    _ = try auth.recordPairAttempt(io, client_key, true, now_ms);
    try respondPairExchangeResult(allocator, request, exchanged.value);
}

fn handleAccessToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    client_key: []const u8,
    request: *std.http.Server.Request,
) !void {
    const now_ms = auth_mod.nowMillis(io);
    if (try auth.devicePreflight(io, client_key, now_ms) == .rate_limited) {
        try respondJson(request, .too_many_requests, "{\"ok\":false,\"error\":\"device_auth_rate_limited\"}");
        return;
    }
    const header = switch (uniqueHeaderValue(request, "authorization")) {
        .value => |value| value,
        .invalid => {
            eraseHeaderValues(request, "authorization");
            _ = try auth.recordDeviceAttempt(io, client_key, false, now_ms);
            try respondUnauthorized(request);
            return;
        },
        .none => {
            _ = try auth.recordDeviceAttempt(io, client_key, false, now_ms);
            try respondUnauthorized(request);
            return;
        },
    };
    const device_auth = parseDeviceAuthorization(header) orelse {
        std.crypto.secureZero(u8, @constCast(header));
        _ = try auth.recordDeviceAttempt(io, client_key, false, now_ms);
        try respondUnauthorized(request);
        return;
    };
    defer std.crypto.secureZero(u8, @constCast(device_auth.credential));
    if (!contentTypeIsJson(requestContentType(request))) {
        try respondJson(request, .unsupported_media_type, "{\"ok\":false,\"error\":\"expected_json\"}");
        return;
    }
    const body = readBoundedSecretBody(allocator, request, MAX_ACCESS_BODY_BYTES) catch |err| switch (err) {
        error.AccessBodyTooLarge => {
            request.head.keep_alive = false;
            try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"access_body_too_large\"}");
            return;
        },
        else => return err,
    };
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    var parsed = headless.access_protocol.parseAccessTokenRequest(allocator, body) catch {
        try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_access_request\"}");
        return;
    };
    defer parsed.deinit();
    const params: headless.access_protocol.DeviceAuthenticateRequest = .{
        .access_protocol_version = headless.access_protocol.ACCESS_PROTOCOL_VERSION,
        .device_id = device_auth.device_id,
        .device_credential = .{ .bytes = device_auth.credential },
        .requested_scopes = parsed.value.requested_scopes,
    };
    const daemon_result = callDeviceAuthenticateTargetedAfterBootstrap(
        allocator,
        daemon,
        params,
    ) catch {
        try respondDaemonUnavailable(request);
        return;
    };
    defer allocator.free(daemon_result.json);
    var envelope = headless.parseResponse(allocator, daemon_result.json) catch {
        try respondDaemonUnavailable(request);
        return;
    };
    defer envelope.deinit();
    const result_value = envelope.response.result orelse {
        const code = rpcErrorCode(envelope.response.err) orelse "";
        if (std.mem.eql(u8, code, "authentication_rejected")) {
            _ = try auth.recordDeviceAttempt(io, client_key, false, now_ms);
            try respondUnauthorized(request);
        } else {
            try respondDaemonUnavailable(request);
        }
        return;
    };
    var authorized = std.json.parseFromValue(
        headless.access_protocol.DeviceAuthorizationResult,
        allocator,
        result_value,
        .{},
    ) catch {
        try respondDaemonUnavailable(request);
        return;
    };
    defer authorized.deinit();
    if (authorized.value.access_protocol_version != headless.access_protocol.ACCESS_PROTOCOL_VERSION or
        !std.mem.eql(u8, authorized.value.device_id, device_auth.device_id))
    {
        try respondDaemonUnavailable(request);
        return;
    }
    const scope_mask = headless.access_protocol.scopeMask(authorized.value.scopes) catch {
        try respondDaemonUnavailable(request);
        return;
    };
    if (scope_mask != (headless.access_protocol.scopeMask(parsed.value.requested_scopes) catch unreachable)) {
        try respondDaemonUnavailable(request);
        return;
    }
    _ = try auth.recordDeviceAttempt(io, client_key, true, now_ms);
    var issued = auth.pair_credentials.issueAccessToken(
        io,
        device_auth.device_id,
        scope_mask,
        now_ms,
        auth_mod.unixNowMillis(io),
    ) catch {
        try respondJson(request, .service_unavailable, "{\"ok\":false,\"error\":\"access_token_capacity\"}");
        return;
    };
    defer issued.clear();
    try respondAccessTokenResult(allocator, request, &issued, authorized.value.scopes);
}

fn handleWebSocketTicket(
    allocator: std.mem.Allocator,
    io: std.Io,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    client_key: []const u8,
    request: *std.http.Server.Request,
) !void {
    const now_ms = auth_mod.nowMillis(io);
    if (try auth.ticketPreflight(io, client_key, now_ms) == .rate_limited) {
        try respondJson(request, .too_many_requests, "{\"ok\":false,\"error\":\"ticket_auth_rate_limited\"}");
        return;
    }
    const authorization = switch (uniqueHeaderValue(request, "authorization")) {
        .value => |value| value,
        .invalid => {
            eraseHeaderValues(request, "authorization");
            _ = try auth.recordTicketAttempt(io, client_key, false, now_ms);
            try respondUnauthorized(request);
            return;
        },
        .none => {
            _ = try auth.recordTicketAttempt(io, client_key, false, now_ms);
            try respondUnauthorized(request);
            return;
        },
    };
    const bearer = parseBearer(authorization) orelse {
        std.crypto.secureZero(u8, @constCast(authorization));
        _ = try auth.recordTicketAttempt(io, client_key, false, now_ms);
        try respondUnauthorized(request);
        return;
    };
    defer std.crypto.secureZero(u8, @constCast(bearer));
    var claims = (try auth.pair_credentials.validateAccessToken(
        io,
        bearer,
        now_ms,
    )) orelse {
        _ = try auth.recordTicketAttempt(io, client_key, false, now_ms);
        try respondUnauthorized(request);
        return;
    };
    _ = try auth.recordTicketAttempt(io, client_key, true, now_ms);
    defer claims.clear();
    if (!contentTypeIsJson(requestContentType(request))) {
        try respondJson(request, .unsupported_media_type, "{\"ok\":false,\"error\":\"expected_json\"}");
        return;
    }
    const body = readBoundedSecretBody(allocator, request, MAX_ACCESS_BODY_BYTES) catch |err| switch (err) {
        error.AccessBodyTooLarge => {
            request.head.keep_alive = false;
            try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"access_body_too_large\"}");
            return;
        },
        else => return err,
    };
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    var parsed = headless.access_protocol.parseWebSocketTicketRequest(allocator, body) catch {
        try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_ticket_request\"}");
        return;
    };
    defer parsed.deinit();
    const bootstrap_mask = headless.access_protocol.webSocketBootstrapScopeMask();
    if (!headless.access_protocol.scopeMaskContains(claims.scope_mask, bootstrap_mask) or
        !authorizePairClaims(allocator, daemon, auth, claims, claims.scope_mask))
    {
        try respondJson(request, .forbidden, "{\"ok\":false,\"error\":\"insufficient_scope\"}");
        return;
    }
    var issued = auth.pair_credentials.issueWebSocketTicket(
        io,
        claims,
        auth_mod.nowMillis(io),
        auth_mod.unixNowMillis(io),
    ) catch {
        try respondJson(request, .service_unavailable, "{\"ok\":false,\"error\":\"ticket_capacity\"}");
        return;
    };
    defer issued.clear();
    try respondWebSocketTicketResult(allocator, request, &issued);
}

fn handleApi(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    env_map: *const std.process.Environ.Map,
    auth_context: AuthContext,
    split: SplitTarget,
    request: *std.http.Server.Request,
) !void {
    if (disabledFileApi(split.path)) {
        if (!try authorizeApiContext(
            allocator,
            daemon,
            auth,
            auth_context,
            headless.access_protocol.scopeBit(.repository_read),
            request,
        )) return;
        try respondJson(
            request,
            .not_implemented,
            "{\"ok\":false,\"error\":\"unsupported\",\"feature\":\"remote_workspace_file_access\"}",
        );
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/theme")) {
        if (request.head.method != .GET) return respondMethodNotAllowed(request);
        if (!try authorizeApiContext(allocator, daemon, auth, auth_context, headless.access_protocol.scopeBit(.runtime_read), request)) return;
        const resolved = try theme_mod.resolve(allocator, io, env_map);
        const body = try theme_mod.encodeJson(allocator, resolved);
        defer allocator.free(body);
        try respondJson(request, .ok, body);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/health") or
        std.mem.eql(u8, split.path, "/api/status"))
    {
        if (request.head.method != .GET) return respondMethodNotAllowed(request);
        if (!try authorizeApiContext(allocator, daemon, auth, auth_context, headless.access_protocol.scopeBit(.runtime_read), request)) return;
        try respondDaemonStatus(allocator, daemon, request);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/snapshot")) {
        if (request.head.method != .GET) return respondMethodNotAllowed(request);
        if (!try authorizeApiContext(allocator, daemon, auth, auth_context, headless.access_protocol.webSocketBootstrapScopeMask(), request)) return;
        const result = callMethodTargetedAfterBootstrap(
            allocator,
            daemon,
            "core.snapshot",
            SnapshotParams{},
        ) catch {
            try respondDaemonUnavailable(request);
            return;
        };
        defer allocator.free(result.json);
        try respondJson(request, if (rpcSucceeded(allocator, result.json)) .ok else .service_unavailable, result.json);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/attachment") and request.head.method == .POST) {
        if (!try authorizeApiContext(allocator, daemon, auth, auth_context, headless.access_protocol.scopeBit(.chat_write), request)) return;
        const mime = supportedImageMime(requestContentType(request)) orelse {
            try respondJson(request, .unsupported_media_type, "{\"ok\":false,\"error\":\"unsupported_image_type\"}");
            return;
        };
        const body_reader = try request.readerExpectContinue(&.{});
        const body = body_reader.allocRemaining(allocator, .limited(MAX_CHAT_IMAGE_BYTES)) catch {
            request.head.keep_alive = false;
            try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"image_too_large\"}");
            return;
        };
        defer allocator.free(body);
        if (!imageBytesMatchMime(mime, body)) {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_image\"}");
            return;
        }

        const stored = try storeChatImage(allocator, io, config.pref_path, mime, body);
        defer stored.deinit(allocator);
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try std.json.Stringify.value(.{
            .ok = true,
            .attachment = .{
                .path = stored.path,
                .mime = mime,
                .byte_size = body.len,
                .attachment_id = stored.attachment_id,
            },
        }, .{}, &writer.writer);
        const response = try writer.toOwnedSlice();
        defer allocator.free(response);
        try respondJson(request, .created, response);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/attachment") and
        (request.head.method == .GET or request.head.method == .DELETE))
    {
        const attachment_scope = if (request.head.method == .GET)
            headless.access_protocol.scopeBit(.chat_read)
        else
            headless.access_protocol.scopeBit(.chat_write);
        if (!try authorizeApiContext(allocator, daemon, auth, auth_context, attachment_scope, request)) return;
        const attachment_id = queryValue(split.query, "id") orelse {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"missing_attachment_id\"}");
            return;
        };
        if (!validAttachmentId(attachment_id)) {
            try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_attachment_id\"}");
            return;
        }
        const attachment_mime = attachmentMime(attachment_id) orelse unreachable;
        const path = try std.fs.path.join(allocator, &.{ config.pref_path, WEB_CHAT_IMAGE_DIR, attachment_id });
        defer allocator.free(path);
        if (request.head.method == .DELETE) {
            std.Io.Dir.deleteFileAbsolute(io, path) catch {
                try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"attachment_not_found\"}");
                return;
            };
            try respondJson(request, .ok, "{\"ok\":true}");
            return;
        }
        const bytes = readFileLimited(allocator, io, path) catch {
            try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"attachment_not_found\"}");
            return;
        };
        defer allocator.free(bytes);
        if (!imageBytesMatchMime(attachment_mime, bytes)) {
            try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"attachment_not_found\"}");
            return;
        }
        try respondData(request, .ok, attachment_mime, bytes);
        return;
    }

    if (std.mem.eql(u8, split.path, "/api/rpc")) {
        if (request.head.method != .POST) return respondMethodNotAllowed(request);
        try handleRpc(allocator, daemon, auth, auth_context, request);
        return;
    }

    try respondJson(request, .not_found, "{\"ok\":false,\"error\":\"not_found\"}");
}

fn handleRpc(
    allocator: std.mem.Allocator,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    auth_context: AuthContext,
    request: *std.http.Server.Request,
) !void {
    if (request.head.content_length) |length| {
        if (length > MAX_RPC_FRAME_BYTES) {
            request.head.keep_alive = false;
            try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"rpc_frame_too_large\"}");
            return;
        }
    }
    const body_reader = try request.readerExpectContinue(&.{});
    const body = body_reader.allocRemaining(allocator, .limited(MAX_RPC_FRAME_BYTES)) catch {
        request.head.keep_alive = false;
        try respondJson(request, .payload_too_large, "{\"ok\":false,\"error\":\"rpc_frame_too_large\"}");
        return;
    };
    defer allocator.free(body);
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);

    var parsed = headless.parseRequest(allocator, trimmed) catch {
        try respondJson(request, .bad_request, "{\"ok\":false,\"error\":\"invalid_rpc\"}");
        return;
    };
    defer parsed.deinit();
    if (blockedRpcMethod(parsed.request.method)) {
        const unsupported = try headless.encodeErrorResponse(
            allocator,
            parsed.request.id,
            "unsupported",
            "method is disabled in remote gateways",
        );
        defer allocator.free(unsupported);
        try respondJson(request, .not_implemented, unsupported);
        return;
    }
    if (auth_context == .pair) {
        const required_mask = headless.access_protocol.requiredScopeMaskForRpc(parsed.request.method) orelse {
            const forbidden = try headless.encodeErrorResponse(
                allocator,
                parsed.request.id,
                "forbidden",
                "method is not available to paired sessions",
            );
            defer allocator.free(forbidden);
            try respondJson(request, .forbidden, forbidden);
            return;
        };
        if (!try authorizeApiContext(allocator, daemon, auth, auth_context, required_mask, request)) return;
    }
    if (rpcRequestMissingRequiredTarget(parsed.request)) {
        const rejected = try headless.encodeErrorResponse(
            allocator,
            parsed.request.id,
            headless.protocol.ERR_RUNTIME_IDENTITY_MISSING,
            "remote RPC requires a runtime target",
        );
        defer allocator.free(rejected);
        try respondJson(request, .ok, rejected);
        return;
    }

    const result = daemon.callRaw(trimmed) catch {
        try respondDaemonUnavailable(request);
        return;
    };
    defer allocator.free(result.json);
    try respondJson(request, .ok, result.json);
}

fn respondDaemonStatus(
    allocator: std.mem.Allocator,
    daemon: *daemon_mod.Daemon,
    request: *std.http.Server.Request,
) !void {
    const result = daemon.callMethod("core.status", daemon_mod.Daemon.EmptyObject{}) catch {
        try respondDaemonUnavailable(request);
        return;
    };
    defer allocator.free(result.json);
    try respondJson(
        request,
        if (rpcSucceeded(allocator, result.json)) .ok else .service_unavailable,
        result.json,
    );
}

fn respondDaemonUnavailable(request: *std.http.Server.Request) !void {
    try respondJson(
        request,
        .service_unavailable,
        "{\"ok\":false,\"error\":\"daemon_unavailable\"}",
    );
}

fn rpcSucceeded(allocator: std.mem.Allocator, json: []const u8) bool {
    var parsed = headless.parseResponse(allocator, json) catch return false;
    defer parsed.deinit();
    return parsed.response.isOk();
}

fn callMethodTargetedAfterBootstrap(
    allocator: std.mem.Allocator,
    daemon: *daemon_mod.Daemon,
    method: []const u8,
    params: anytype,
) !daemon_mod.CallResult {
    const target = try runtimeTargetAfterBootstrap(allocator, daemon);
    return daemon.callMethodTargeted(method, params, target.borrowed());
}

fn callPairingExchangeTargetedAfterBootstrap(
    allocator: std.mem.Allocator,
    daemon: *daemon_mod.Daemon,
    request: headless.access_protocol.PairingGrantExchangeRequest,
) !daemon_mod.CallResult {
    const target = try runtimeTargetAfterBootstrap(allocator, daemon);
    return daemon.callPairingExchangeTargeted(request, target.borrowed());
}

fn callDeviceAuthenticateTargetedAfterBootstrap(
    allocator: std.mem.Allocator,
    daemon: *daemon_mod.Daemon,
    request: headless.access_protocol.DeviceAuthenticateRequest,
) !daemon_mod.CallResult {
    const target = try runtimeTargetAfterBootstrap(allocator, daemon);
    return daemon.callDeviceAuthenticateTargeted(request, target.borrowed());
}

fn runtimeTargetAfterBootstrap(
    allocator: std.mem.Allocator,
    daemon: *daemon_mod.Daemon,
) !SessionRuntimeTarget {
    const status = try daemon.callMethod("core.status", daemon_mod.Daemon.EmptyObject{});
    defer allocator.free(status.json);
    if (!rpcSucceeded(allocator, status.json)) return error.DaemonUnavailable;
    return SessionRuntimeTarget.fromStatusEnvelope(allocator, status.json);
}

fn rpcRequestMissingRequiredTarget(request: headless.protocol.Request) bool {
    return request.target == null and !std.mem.eql(u8, request.method, "core.status");
}

const SessionRuntimeTarget = struct {
    runtime_id: [32]u8,
    instance_id: [32]u8,

    fn fromStatusEnvelope(allocator: std.mem.Allocator, status_json: []const u8) !SessionRuntimeTarget {
        var parsed = try headless.parseResponse(allocator, status_json);
        defer parsed.deinit();
        const result = parsed.response.result orelse return error.InvalidRuntimeStatus;
        if (result != .object) return error.InvalidRuntimeStatus;
        const runtime_id = jsonString(result.object.get("runtime_id") orelse .null) orelse
            return error.InvalidRuntimeStatus;
        const instance_id = jsonString(result.object.get("instance_id") orelse .null) orelse
            return error.InvalidRuntimeStatus;
        const candidate: headless.protocol.RequestTarget = .{
            .runtime_id = runtime_id,
            .instance_id = instance_id,
        };
        try headless.protocol.validateRequestTarget(candidate);
        if (!statusAdvertisesTargetRpc(result)) return error.TargetRpcUnavailable;

        var target: SessionRuntimeTarget = undefined;
        @memcpy(target.runtime_id[0..], runtime_id);
        @memcpy(target.instance_id[0..], instance_id);
        return target;
    }

    fn borrowed(self: *const SessionRuntimeTarget) headless.protocol.RequestTarget {
        return .{
            .runtime_id = &self.runtime_id,
            .instance_id = &self.instance_id,
        };
    }
};

fn statusAdvertisesTargetRpc(result: std.json.Value) bool {
    const capabilities = result.object.get("runtime_capabilities") orelse return false;
    if (capabilities != .array) return false;
    for (capabilities.array.items) |capability| {
        const name = jsonString(capability) orelse continue;
        if (std.mem.eql(u8, name, "rpc.target.v1")) return true;
    }
    return false;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

const WsSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    authentication: WsAuthentication,
    socket: *std.http.Server.WebSocket,
    runtime_target: ?SessionRuntimeTarget = null,
    write_mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),

    fn send(self: *WsSession, payload: []const u8) !void {
        if (payload.len > MAX_RPC_FRAME_BYTES) return error.ResponseTooLarge;
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        try self.socket.writeMessage(payload, .text);
    }

    fn authenticationValid(self: *WsSession) bool {
        return switch (self.authentication) {
            .owner_bearer => true,
            .owner_session => |session_id| self.auth.verifySession(
                self.io,
                session_id[0..],
                auth_mod.nowMillis(self.io),
            ) catch false,
            .pair => |claims| authorizePairClaims(
                self.allocator,
                self.daemon,
                self.auth,
                claims,
                claims.scope_mask,
            ),
        };
    }

    fn rpcAllowed(self: *WsSession, method: []const u8) bool {
        return switch (self.authentication) {
            .owner_bearer, .owner_session => true,
            .pair => |claims| allowed: {
                const required_mask = headless.access_protocol.requiredScopeMaskForRpc(method) orelse
                    break :allowed false;
                if (!headless.access_protocol.scopeMaskContains(claims.scope_mask, required_mask)) {
                    break :allowed false;
                }
                break :allowed authorizePairClaims(
                    self.allocator,
                    self.daemon,
                    self.auth,
                    claims,
                    required_mask,
                );
            },
        };
    }

    fn closeExpired(self: *WsSession) void {
        if (self.closed.swap(true, .acq_rel)) return;
        self.write_mutex.lock(self.io) catch return;
        defer self.write_mutex.unlock(self.io);
        self.socket.writeMessage("", .connection_close) catch {};
    }
};

fn serveWebSocket(
    allocator: std.mem.Allocator,
    io: std.Io,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    authentication: WsAuthentication,
    socket: *std.http.Server.WebSocket,
) !void {
    var session: WsSession = .{
        .allocator = allocator,
        .io = io,
        .daemon = daemon,
        .auth = auth,
        .authentication = authentication,
        .socket = socket,
    };
    defer session.authentication.clear();

    try sendHello(&session);
    var poll_task = try io.concurrent(pollChanges, .{&session});
    defer poll_task.cancel(io);

    while (!session.closed.load(.acquire)) {
        const message = socket.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose, error.EndOfStream => break,
            else => return err,
        };
        switch (message.opcode) {
            .ping => {
                try session.write_mutex.lock(io);
                defer session.write_mutex.unlock(io);
                socket.writeMessage(message.data, .pong) catch {};
            },
            .text, .binary => {
                if (!session.authenticationValid()) {
                    session.closeExpired();
                    break;
                }
                if (message.data.len > MAX_RPC_FRAME_BYTES) return error.MessageOversize;
                const trimmed = std.mem.trim(u8, message.data, &std.ascii.whitespace);
                if (trimmed.len == 0) continue;
                var parsed = headless.parseRequest(allocator, trimmed) catch {
                    const encoded = try headless.encodeErrorResponse(allocator, 0, "invalid_request", "invalid RPC request");
                    defer allocator.free(encoded);
                    session.send(encoded) catch {};
                    continue;
                };
                defer parsed.deinit();
                if (blockedRpcMethod(parsed.request.method)) {
                    const encoded = try headless.encodeErrorResponse(
                        allocator,
                        parsed.request.id,
                        "unsupported",
                        "method is disabled in remote gateways",
                    );
                    defer allocator.free(encoded);
                    session.send(encoded) catch {};
                    continue;
                }
                if (!session.rpcAllowed(parsed.request.method)) {
                    const encoded = try headless.encodeErrorResponse(
                        allocator,
                        parsed.request.id,
                        "forbidden",
                        "method is not authorized for this paired session",
                    );
                    defer allocator.free(encoded);
                    session.send(encoded) catch {};
                    continue;
                }
                if (rpcRequestMissingRequiredTarget(parsed.request)) {
                    const encoded = try headless.encodeErrorResponse(
                        allocator,
                        parsed.request.id,
                        headless.protocol.ERR_RUNTIME_IDENTITY_MISSING,
                        "remote RPC requires a runtime target",
                    );
                    defer allocator.free(encoded);
                    session.send(encoded) catch {};
                    continue;
                }

                const result = session.daemon.callRaw(trimmed) catch {
                    const encoded = try headless.encodeErrorResponse(allocator, 0, "unavailable", "daemon unavailable");
                    defer allocator.free(encoded);
                    session.send(encoded) catch {};
                    continue;
                };
                defer allocator.free(result.json);
                session.send(result.json) catch {};
            },
            else => {},
        }
    }
    session.closed.store(true, .release);
}

fn sendHello(session: *WsSession) !void {
    if (!session.authenticationValid()) {
        session.closeExpired();
        return error.AuthenticationExpired;
    }
    const status = try session.daemon.callMethod("core.status", daemon_mod.Daemon.EmptyObject{});
    defer session.allocator.free(status.json);
    if (!rpcSucceeded(session.allocator, status.json)) return error.DaemonUnavailable;
    session.runtime_target = try SessionRuntimeTarget.fromStatusEnvelope(session.allocator, status.json);

    const hello = try std.fmt.allocPrint(
        session.allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"core.hello\",\"params\":{{\"source\":\"daemon\",\"status_envelope\":{s}}}}}",
        .{status.json},
    );
    defer session.allocator.free(hello);
    if (!session.authenticationValid()) {
        session.closeExpired();
        return error.AuthenticationExpired;
    }
    try session.send(hello);
    pushSnapshot(session) catch {};
}

fn sendNotification(session: *WsSession, method: []const u8, payload: []const u8) !void {
    const note = try std.fmt.allocPrint(
        session.allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, payload },
    );
    defer session.allocator.free(note);
    try session.send(note);
}

fn pollChanges(session: *WsSession) void {
    var cursor: ?u64 = null;
    while (!session.closed.load(.acquire)) {
        if (!session.authenticationValid()) {
            session.closeExpired();
            return;
        }
        const started_ms = monotonicMillis(session.io);
        const target = if (session.runtime_target) |*value| value.borrowed() else return;
        const result = session.daemon.callMethodTargeted("core.changes", changesParams(cursor), target) catch {
            sleepMs(session.io, 1_000) catch return;
            continue;
        };
        defer session.allocator.free(result.json);
        if (!rpcSucceeded(session.allocator, result.json)) {
            session.closeExpired();
            return;
        }
        if (!session.authenticationValid()) {
            session.closeExpired();
            return;
        }

        const note = std.fmt.allocPrint(
            session.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"core.changes\",\"params\":{s}}}",
            .{result.json},
        ) catch continue;
        defer session.allocator.free(note);
        session.send(note) catch {
            session.closed.store(true, .release);
            return;
        };

        cursor = extractNextCursor(result.json) orelse cursor;
        if (!isHeartbeat(result.json)) pushSnapshot(session) catch {};

        const elapsed_ms = monotonicMillis(session.io) -| started_ms;
        if (elapsed_ms < MIN_CHANGES_RETRY_MS) {
            sleepMs(session.io, MIN_CHANGES_RETRY_MS - elapsed_ms) catch return;
        }
    }
}

const SnapshotParams = struct {
    scopes: [5][]const u8 = .{ "workspaces", "registry", "sessions", "turns", "config" },
};

fn pushSnapshot(session: *WsSession) !void {
    if (!session.authenticationValid()) {
        session.closeExpired();
        return error.AuthenticationExpired;
    }
    const target = if (session.runtime_target) |*value| value.borrowed() else return error.TargetRpcUnavailable;
    const snapshot = session.daemon.callMethodTargeted("core.snapshot", SnapshotParams{}, target) catch
        return error.DaemonUnavailable;
    defer session.allocator.free(snapshot.json);
    if (!rpcSucceeded(session.allocator, snapshot.json)) return error.DaemonUnavailable;
    if (!session.authenticationValid()) {
        session.closeExpired();
        return error.AuthenticationExpired;
    }
    try sendNotification(session, "core.snapshot", snapshot.json);
}

fn isHeartbeat(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"heartbeat\":true") != null and
        std.mem.indexOf(u8, json, "\"entries\":[]") != null;
}

const ChangesParams = struct {
    cursor: ?u64 = null,
    wait_ms: u32 = 4_000,
};

fn changesParams(cursor: ?u64) ChangesParams {
    return .{ .cursor = cursor };
}

fn extractNextCursor(json: []const u8) ?u64 {
    const key = "\"next_cursor\":";
    const start = std.mem.indexOf(u8, json, key) orelse return null;
    const rest = json[start + key.len ..];
    var index: usize = 0;
    while (index < rest.len and (rest[index] == ' ' or rest[index] == '\t')) : (index += 1) {}
    var end = index;
    while (end < rest.len and std.ascii.isDigit(rest[end])) : (end += 1) {}
    if (end == index) return null;
    return std.fmt.parseInt(u64, rest[index..end], 10) catch null;
}

fn monotonicMillis(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.awake.now(io).toMilliseconds(), 0));
}

fn sleepMs(io: std.Io, ms: u64) !void {
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
    };
}

const AuthContext = union(enum) {
    owner_bearer,
    owner_session: []const u8,
    pair: auth_mod.PairClaims,
};

fn authenticate(
    auth: *auth_mod.Service,
    io: std.Io,
    request: *const std.http.Server.Request,
) !?AuthContext {
    const authorization = uniqueHeaderValue(request, "authorization");
    switch (authorization) {
        .invalid => {
            eraseHeaderValues(request, "authorization");
            return null;
        },
        .value => |value| {
            const bearer = parseBearer(value) orelse {
                std.crypto.secureZero(u8, @constCast(value));
                return null;
            };
            const valid = auth.verifyBearer(bearer);
            std.crypto.secureZero(u8, @constCast(bearer));
            return if (valid) .owner_bearer else null;
        },
        .none => {},
    }

    const session_id = requestSessionCookie(request) orelse return null;
    return if (try auth.verifySession(io, session_id, auth_mod.nowMillis(io)))
        .{ .owner_session = session_id }
    else
        null;
}

fn authenticateApi(
    auth: *auth_mod.Service,
    io: std.Io,
    request: *const std.http.Server.Request,
) !?AuthContext {
    const authorization = uniqueHeaderValue(request, "authorization");
    switch (authorization) {
        .invalid => {
            eraseHeaderValues(request, "authorization");
            return null;
        },
        .value => |value| {
            const bearer = parseBearer(value) orelse {
                std.crypto.secureZero(u8, @constCast(value));
                return null;
            };
            defer std.crypto.secureZero(u8, @constCast(bearer));
            if (auth.verifyBearer(bearer)) return .owner_bearer;
            if (try auth.pair_credentials.validateAccessToken(
                io,
                bearer,
                auth_mod.nowMillis(io),
            )) |claims| return .{ .pair = claims };
            return null;
        },
        .none => {},
    }

    const session_id = requestSessionCookie(request) orelse return null;
    return if (try auth.verifySession(io, session_id, auth_mod.nowMillis(io)))
        .{ .owner_session = session_id }
    else
        null;
}

const WsAuthentication = union(enum) {
    owner_bearer,
    owner_session: [auth_mod.SESSION_ID_BYTES]u8,
    pair: auth_mod.PairClaims,

    fn clear(self: *WsAuthentication) void {
        switch (self.*) {
            .owner_bearer => {},
            .owner_session => |*session_id| std.crypto.secureZero(u8, session_id[0..]),
            .pair => |*claims| claims.clear(),
        }
        self.* = undefined;
    }
};

fn webSocketAuthenticationFromOwner(owner: AuthContext) !WsAuthentication {
    return switch (owner) {
        .owner_bearer => .owner_bearer,
        .owner_session => |session_id| copied: {
            if (session_id.len != auth_mod.SESSION_ID_BYTES) return error.InvalidSession;
            var copy: [auth_mod.SESSION_ID_BYTES]u8 = undefined;
            @memcpy(copy[0..], session_id);
            std.crypto.secureZero(u8, @constCast(session_id));
            break :copied .{ .owner_session = copy };
        },
        .pair => unreachable,
    };
}

fn authorizeApiContext(
    allocator: std.mem.Allocator,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    context: AuthContext,
    required_mask: u16,
    request: *std.http.Server.Request,
) !bool {
    switch (context) {
        .owner_bearer, .owner_session => return true,
        .pair => |claims| {
            if (!headless.access_protocol.scopeMaskContains(claims.scope_mask, required_mask) or
                !authorizePairClaims(allocator, daemon, auth, claims, required_mask))
            {
                try respondJson(request, .forbidden, "{\"ok\":false,\"error\":\"insufficient_scope\"}");
                return false;
            }
            return true;
        },
    }
}

fn authorizePairClaims(
    allocator: std.mem.Allocator,
    daemon: *daemon_mod.Daemon,
    auth: *auth_mod.Service,
    claims: auth_mod.PairClaims,
    required_mask: u16,
) bool {
    if (claims.deadline_ms <= auth_mod.nowMillis(daemon.io)) return false;
    const scope_names = headless.access_protocol.scopeNamesAlloc(allocator, required_mask) catch return false;
    defer allocator.free(scope_names);
    const params: headless.access_protocol.DeviceAuthorizeRequest = .{
        .access_protocol_version = headless.access_protocol.ACCESS_PROTOCOL_VERSION,
        .device_id = claims.device_id[0..],
        .required_scopes = scope_names,
    };
    const result = callMethodTargetedAfterBootstrap(
        allocator,
        daemon,
        headless.access_protocol.METHOD_DAEMON_DEVICE_AUTHORIZE,
        params,
    ) catch return false;
    defer allocator.free(result.json);
    return switch (deviceAuthorizationStatus(
        allocator,
        result.json,
        claims.device_id[0..],
        required_mask,
    )) {
        .authorized => true,
        .rejected => rejected: {
            auth.pair_credentials.clearDeviceCredentials(
                daemon.io,
                claims.device_id[0..],
            ) catch {};
            break :rejected false;
        },
        .unavailable => false,
    };
}

const DeviceAuthorizationStatus = enum { authorized, rejected, unavailable };

fn deviceAuthorizationStatus(
    allocator: std.mem.Allocator,
    json: []const u8,
    expected_device_id: []const u8,
    expected_mask: u16,
) DeviceAuthorizationStatus {
    var parsed = headless.parseResponse(allocator, json) catch return .unavailable;
    defer parsed.deinit();
    const result = parsed.response.result orelse return if (std.mem.eql(
        u8,
        rpcErrorCode(parsed.response.err) orelse "",
        "authentication_rejected",
    )) .rejected else .unavailable;
    var typed = std.json.parseFromValue(
        headless.access_protocol.DeviceAuthorizationResult,
        allocator,
        result,
        .{},
    ) catch return .unavailable;
    defer typed.deinit();
    if (typed.value.access_protocol_version != headless.access_protocol.ACCESS_PROTOCOL_VERSION or
        !std.mem.eql(u8, typed.value.device_id, expected_device_id)) return .unavailable;
    const actual_mask = headless.access_protocol.scopeMask(typed.value.scopes) catch return .unavailable;
    return if (actual_mask == expected_mask) .authorized else .unavailable;
}

fn requestEnvelopeAllowed(request: *const std.http.Server.Request) bool {
    const split = splitTarget(request.head.target);
    if (eraseQueryCredentials(split.query)) return false;
    if (eraseLegacyTokenHeaders(request)) return false;
    return switch (uniqueHeaderValue(request, "host")) {
        .value => |host| validLoopbackAuthority(host),
        else => false,
    };
}

fn requestOriginAllowed(request: *const std.http.Server.Request, required: bool) bool {
    const host = switch (uniqueHeaderValue(request, "host")) {
        .value => |value| value,
        else => return false,
    };
    return switch (uniqueHeaderValue(request, "origin")) {
        .invalid => false,
        .none => !required,
        .value => |origin| sameLoopbackOrigin(host, origin),
    };
}

const HeaderValue = union(enum) {
    none,
    invalid,
    value: []const u8,
};

fn uniqueHeaderValue(request: *const std.http.Server.Request, name: []const u8) HeaderValue {
    var found: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (found != null) return .invalid;
        found = header.value;
    }
    return if (found) |value| .{ .value = value } else .none;
}

fn eraseHeaderValues(request: *const std.http.Server.Request, name: []const u8) void {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        std.crypto.secureZero(u8, @constCast(header.value));
    }
}

fn eraseLegacyTokenHeaders(request: *const std.http.Server.Request) bool {
    var found = false;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "x-verde-token")) continue;
        std.crypto.secureZero(u8, @constCast(header.value));
        found = true;
    }
    return found;
}

fn parseBearer(value: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (value.len <= prefix.len or !std.ascii.startsWithIgnoreCase(value, prefix)) return null;
    const token = value[prefix.len..];
    if (std.mem.indexOfAny(u8, token, " \t\r\n") != null) return null;
    return token;
}

fn requestSessionCookie(request: *const std.http.Server.Request) ?[]const u8 {
    var result: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "cookie")) continue;
        const candidate = cookieValue(header.value, auth_mod.SESSION_COOKIE_NAME) orelse continue;
        if (result != null) return null;
        result = candidate;
    }
    return result;
}

fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var cookies = std.mem.splitScalar(u8, header, ';');
    while (cookies.next()) |raw_cookie| {
        const cookie = std.mem.trim(u8, raw_cookie, " \t");
        const equals = std.mem.indexOfScalar(u8, cookie, '=') orelse continue;
        if (!std.mem.eql(u8, cookie[0..equals], name)) continue;
        if (found != null) return null;
        const value = cookie[equals + 1 ..];
        if (value.len == 0 or std.mem.indexOfAny(u8, value, " \t\r\n,;") != null) return null;
        found = value;
    }
    return found;
}

fn validLoopbackAuthority(authority: []const u8) bool {
    if (authority.len == 0 or !std.mem.eql(u8, authority, std.mem.trim(u8, authority, " \t"))) return false;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        if (!std.ascii.eqlIgnoreCase(authority[1..close], "::1")) return false;
        return validOptionalPort(authority[close + 1 ..]);
    }

    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host = if (colon) |index| authority[0..index] else authority;
    const rest = if (colon) |index| authority[index..] else "";
    if (!std.ascii.eqlIgnoreCase(host, "localhost") and !std.mem.eql(u8, host, "127.0.0.1")) return false;
    return validOptionalPort(rest);
}

fn validOptionalPort(rest: []const u8) bool {
    if (rest.len == 0) return true;
    if (rest.len == 1 or rest[0] != ':') return false;
    const port = std.fmt.parseInt(u16, rest[1..], 10) catch return false;
    return port != 0;
}

fn sameLoopbackOrigin(host: []const u8, origin: []const u8) bool {
    const prefix = "http://";
    if (!std.ascii.startsWithIgnoreCase(origin, prefix)) return false;
    const authority = origin[prefix.len..];
    if (!validLoopbackAuthority(authority)) return false;
    return std.ascii.eqlIgnoreCase(authority, host);
}

fn webSocketTargetAllowed(method: std.http.Method, target: []const u8) bool {
    return method == .GET and std.mem.eql(u8, target, "/ws");
}

fn isApiPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/api") or std.mem.startsWith(u8, path, "/api/");
}

fn disabledFileApi(path: []const u8) bool {
    return std.mem.eql(u8, path, "/api/file") or std.mem.eql(u8, path, "/api/preview");
}

fn blockedRpcMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "web.directory.list") or
        headless.connect_protocol.isMethod(method) or
        std.mem.eql(u8, method, headless.access_protocol.METHOD_DAEMON_PAIRING_GRANT_CREATE) or
        std.mem.eql(u8, method, headless.access_protocol.METHOD_DAEMON_PAIRING_GRANT_LIST) or
        std.mem.eql(u8, method, headless.access_protocol.METHOD_DAEMON_PAIRING_GRANT_REVOKE) or
        std.mem.eql(u8, method, headless.access_protocol.METHOD_DAEMON_DEVICE_LIST) or
        std.mem.eql(u8, method, headless.access_protocol.METHOD_DAEMON_DEVICE_REVOKE) or
        std.mem.eql(u8, method, headless.access_protocol.METHOD_DAEMON_PAIRING_EXCHANGE) or
        std.mem.eql(u8, method, headless.access_protocol.METHOD_DAEMON_DEVICE_AUTHENTICATE) or
        std.mem.eql(u8, method, headless.access_protocol.METHOD_DAEMON_DEVICE_AUTHORIZE);
}

const SplitTarget = struct { path: []const u8, query: []const u8 };

fn splitTarget(target: []const u8) SplitTarget {
    if (std.mem.indexOfScalar(u8, target, '?')) |index| {
        return .{ .path = target[0..index], .query = target[index + 1 ..] };
    }
    return .{ .path = target, .query = "" };
}

fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |equals| {
            if (std.mem.eql(u8, pair[0..equals], key)) return pair[equals + 1 ..];
        } else if (std.mem.eql(u8, pair, key)) {
            return "";
        }
    }
    return null;
}

fn requestContentType(request: *const std.http.Server.Request) ?[]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;
        const value = if (std.mem.indexOfScalar(u8, header.value, ';')) |separator|
            header.value[0..separator]
        else
            header.value;
        return std.mem.trim(u8, value, &std.ascii.whitespace);
    }
    return null;
}

fn contentTypeIsJson(value: ?[]const u8) bool {
    return if (value) |mime| std.ascii.eqlIgnoreCase(mime, "application/json") else false;
}

fn supportedImageMime(value: ?[]const u8) ?[]const u8 {
    const mime = value orelse return null;
    if (std.ascii.eqlIgnoreCase(mime, "image/png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(mime, "image/jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(mime, "image/webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(mime, "image/gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(mime, "image/bmp")) return "image/bmp";
    return null;
}

fn imageExtension(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return "png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/webp")) return "webp";
    if (std.mem.eql(u8, mime, "image/gif")) return "gif";
    if (std.mem.eql(u8, mime, "image/bmp")) return "bmp";
    unreachable;
}

fn imageBytesMatchMime(mime: []const u8, bytes: []const u8) bool {
    if (std.mem.eql(u8, mime, "image/png"))
        return bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n");
    if (std.mem.eql(u8, mime, "image/jpeg"))
        return bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff;
    if (std.mem.eql(u8, mime, "image/webp"))
        return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
    if (std.mem.eql(u8, mime, "image/gif"))
        return bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"));
    if (std.mem.eql(u8, mime, "image/bmp"))
        return bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M';
    return false;
}

fn validAttachmentId(value: []const u8) bool {
    if (value.len == 0 or value.len > 96) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') return false;
    }
    return std.mem.startsWith(u8, value, "web-") and attachmentMime(value) != null;
}

fn attachmentMime(value: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, value, ".png")) return "image/png";
    if (std.mem.endsWith(u8, value, ".jpg") or std.mem.endsWith(u8, value, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, value, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, value, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, value, ".bmp")) return "image/bmp";
    return null;
}

const StoredChatImage = struct {
    path: []u8,
    attachment_id: []u8,

    fn deinit(self: StoredChatImage, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.attachment_id);
    }
};

fn storeChatImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    pref_path: []const u8,
    mime: []const u8,
    bytes: []const u8,
) !StoredChatImage {
    const directory = try std.fs.path.join(allocator, &.{ pref_path, WEB_CHAT_IMAGE_DIR });
    defer allocator.free(directory);
    std.Io.Dir.createDirAbsolute(io, directory, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const timestamp = std.Io.Clock.real.now(io);
    const timestamp_ns: u128 = @intCast(@max(timestamp.nanoseconds, 0));
    const content_hash = std.hash.Wyhash.hash(0, bytes);
    var attempt: usize = 0;
    while (attempt < 256) : (attempt += 1) {
        const attachment_id = if (attempt == 0)
            try std.fmt.allocPrint(allocator, "web-{x}-{x}.{s}", .{ timestamp_ns, content_hash, imageExtension(mime) })
        else
            try std.fmt.allocPrint(allocator, "web-{x}-{x}-{d}.{s}", .{ timestamp_ns, content_hash, attempt, imageExtension(mime) });
        errdefer allocator.free(attachment_id);
        const path = try std.fs.path.join(allocator, &.{ directory, attachment_id });
        errdefer allocator.free(path);

        const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
        if (file) |created| {
            defer created.close(io);
            var write_buffer: [8 * 1024]u8 = undefined;
            var writer = created.writer(io, &write_buffer);
            try writer.interface.writeAll(bytes);
            try writer.interface.flush();
            return .{ .path = path, .attachment_id = attachment_id };
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                allocator.free(attachment_id);
                continue;
            },
            else => return err,
        }
    }
    return error.PathAlreadyExists;
}

fn respondMethodNotAllowed(request: *std.http.Server.Request) !void {
    try respondJson(request, .method_not_allowed, "{\"ok\":false,\"error\":\"method_not_allowed\"}");
}

fn respondUnauthorized(request: *std.http.Server.Request) !void {
    const headers = BASE_SECURITY_HEADERS ++ [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "www-authenticate", .value = "Bearer" },
    };
    try request.respond("{\"ok\":false,\"error\":\"unauthorized\"}", .{
        .status = .unauthorized,
        .extra_headers = &headers,
    });
}

fn respondLoginRedirect(request: *std.http.Server.Request) !void {
    const headers = BASE_SECURITY_HEADERS ++ [_]std.http.Header{
        .{ .name = "location", .value = "/login" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond("", .{
        .status = .found,
        .extra_headers = &headers,
    });
}

fn respondAuthAsset(
    request: *std.http.Server.Request,
    content_type: []const u8,
    body: []const u8,
) !void {
    const headers = BASE_SECURITY_HEADERS ++ [_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    const headers = BASE_SECURITY_HEADERS ++ [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond(body, .{
        .status = status,
        .extra_headers = &headers,
    });
}

fn respondData(
    request: *std.http.Server.Request,
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
) !void {
    const headers = BASE_SECURITY_HEADERS ++ [_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond(body, .{
        .status = status,
        .extra_headers = &headers,
    });
}

fn respondStatic(
    request: *std.http.Server.Request,
    content_type: []const u8,
    body: []const u8,
) !void {
    const headers = BASE_SECURITY_HEADERS ++ [_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn serveStatic(
    allocator: std.mem.Allocator,
    io: std.Io,
    static_dir: []const u8,
    request_path: []const u8,
    request: *std.http.Server.Request,
) !bool {
    if (static_dir.len == 0) return false;
    const rel = staticRelPath(request_path) orelse return false;
    const full = try std.fs.path.join(allocator, &.{ static_dir, rel });
    defer allocator.free(full);

    if (readFileLimited(allocator, io, full)) |bytes| {
        defer allocator.free(bytes);
        try respondStatic(request, mimeType(full), bytes);
        return true;
    } else |_| {}

    if (!looksLikeAsset(request_path)) {
        const index_path = try std.fs.path.join(allocator, &.{ static_dir, "index.html" });
        defer allocator.free(index_path);
        if (readFileLimited(allocator, io, index_path)) |bytes| {
            defer allocator.free(bytes);
            try respondStatic(request, "text/html; charset=utf-8", bytes);
            return true;
        } else |_| {}
    }
    return false;
}

fn staticRelPath(request_path: []const u8) ?[]const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return null;
    if (std.mem.indexOf(u8, request_path, "..") != null) return null;
    if (std.mem.eql(u8, request_path, "/")) return "index.html";
    return request_path[1..];
}

fn looksLikeAsset(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '.') != null;
}

fn readFileLimited(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
}

const DeviceAuthorization = struct {
    device_id: []const u8,
    credential: []const u8,
};

fn parseDeviceAuthorization(value: []const u8) ?DeviceAuthorization {
    const prefix = headless.access_protocol.DEVICE_AUTHORIZATION_SCHEME ++ " ";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const payload = value[prefix.len..];
    if (std.mem.indexOfAny(u8, payload, " \t\r\n") != null) return null;
    const separator = std.mem.indexOfScalar(u8, payload, '.') orelse return null;
    if (std.mem.findScalarPos(u8, payload, separator + 1, '.') != null) return null;
    const device_id = payload[0..separator];
    const credential = payload[separator + 1 ..];
    headless.access_protocol.validateDeviceId(device_id) catch return null;
    headless.access_protocol.validateSecret(credential) catch return null;
    return .{ .device_id = device_id, .credential = credential };
}

fn parsePairWebSocketProtocols(request: *const std.http.Server.Request) ?[]const u8 {
    const value = switch (uniqueHeaderValue(request, "sec-websocket-protocol")) {
        .value => |header| header,
        .invalid => {
            eraseHeaderValues(request, "sec-websocket-protocol");
            return null;
        },
        .none => return null,
    };
    const ticket = parsePairWebSocketProtocolValue(value);
    if (ticket == null) eraseWebSocketProtocolSecrets(value);
    return ticket;
}

fn parsePairWebSocketProtocolValue(value: []const u8) ?[]const u8 {
    var saw_protocol = false;
    var ticket: ?[]const u8 = null;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw| {
        count += 1;
        const part = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, part, headless.access_protocol.WEBSOCKET_PROTOCOL_NAME)) {
            if (saw_protocol) return null;
            saw_protocol = true;
            continue;
        }
        if (std.mem.startsWith(u8, part, headless.access_protocol.WEBSOCKET_TICKET_PROTOCOL_PREFIX)) {
            if (ticket != null) return null;
            const candidate = part[headless.access_protocol.WEBSOCKET_TICKET_PROTOCOL_PREFIX.len..];
            if (candidate.len != auth_mod.PAIR_TOKEN_BYTES) return null;
            for (candidate) |byte| {
                if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
            }
            ticket = candidate;
            continue;
        }
        return null;
    }
    return if (count == 2 and saw_protocol) ticket else null;
}

fn eraseWebSocketProtocolSecrets(value: []const u8) void {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (!std.mem.startsWith(u8, part, headless.access_protocol.WEBSOCKET_TICKET_PROTOCOL_PREFIX)) continue;
        std.crypto.secureZero(
            u8,
            @constCast(part[headless.access_protocol.WEBSOCKET_TICKET_PROTOCOL_PREFIX.len..]),
        );
    }
}

fn eraseQueryCredentials(query: []const u8) bool {
    var found = false;
    const names = [_][]const u8{ "token", "access_token", "pairing_token", "device_credential", "ticket" };
    for (names) |name| {
        if (queryValue(query, name)) |value| {
            std.crypto.secureZero(u8, @constCast(value));
            found = true;
        }
    }
    return found;
}

fn readBoundedSecretBody(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    limit: usize,
) ![]u8 {
    if (request.head.content_length) |length| if (length > limit) return error.AccessBodyTooLarge;
    const reader = try request.readerExpectContinue(&.{});
    return reader.allocRemaining(allocator, .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => error.AccessBodyTooLarge,
        else => err,
    };
}

fn rpcErrorCode(value: ?headless.protocol.Error) ?[]const u8 {
    return if (value) |rpc_error| rpc_error.code else null;
}

fn eraseJsonStringField(value: std.json.Value, field: []const u8) void {
    if (value != .object) return;
    const candidate = value.object.get(field) orelse return;
    if (candidate == .string) std.crypto.secureZero(u8, @constCast(candidate.string));
}

fn respondPairExchangeResult(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    result: headless.access_protocol.PairingGrantExchangeResult,
) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, writer.written());
        writer.deinit();
    }
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("access_protocol_version");
    try json.write(result.access_protocol_version);
    try json.objectField("runtime_id");
    try json.write(result.runtime_id);
    try json.objectField("instance_id");
    try json.write(result.instance_id);
    try json.objectField("device_id");
    try json.write(result.device_id);
    try json.objectField("device_credential");
    try json.write(result.device_credential.reveal());
    try json.objectField("scopes");
    try json.write(result.scopes);
    try json.endObject();
    const body = try writer.toOwnedSlice();
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    try respondJson(request, .ok, body);
}

fn respondAccessTokenResult(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    issued: *const auth_mod.IssuedPairCredential,
    scopes: []const []const u8,
) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, writer.written());
        writer.deinit();
    }
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("access_protocol_version");
    try json.write(headless.access_protocol.ACCESS_PROTOCOL_VERSION);
    try json.objectField("access_token");
    try json.write(issued.value[0..]);
    try json.objectField("token_type");
    try json.write(headless.access_protocol.ACCESS_TOKEN_TYPE);
    try json.objectField("expires_at_ms");
    try json.write(issued.expires_at_ms);
    try json.objectField("scopes");
    try json.write(scopes);
    try json.endObject();
    const body = try writer.toOwnedSlice();
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    try respondJson(request, .ok, body);
}

fn respondWebSocketTicketResult(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    issued: *const auth_mod.IssuedPairCredential,
) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, writer.written());
        writer.deinit();
    }
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("access_protocol_version");
    try json.write(headless.access_protocol.ACCESS_PROTOCOL_VERSION);
    try json.objectField("ticket");
    try json.write(issued.value[0..]);
    try json.objectField("expires_at_ms");
    try json.write(issued.expires_at_ms);
    try json.endObject();
    const body = try writer.toOwnedSlice();
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    try respondJson(request, .ok, body);
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".bmp")) return "image/bmp";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, path, ".ttf")) return "font/ttf";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".map")) return "application/json";
    if (std.mem.endsWith(u8, path, ".webmanifest")) return "application/manifest+json";
    return "application/octet-stream";
}

test "every api route and exact websocket target require authentication" {
    const protected = [_][]const u8{
        "/api/theme",
        "/api/health",
        "/api/status",
        "/api/snapshot",
        "/api/attachment",
        "/api/file",
        "/api/preview",
        "/api/rpc",
        "/api/future",
    };
    for (protected) |path| try std.testing.expect(isApiPath(path));
    try std.testing.expect(!isApiPath("/healthz"));
    try std.testing.expect(webSocketTargetAllowed(.GET, "/ws"));
    try std.testing.expect(!webSocketTargetAllowed(.POST, "/ws"));
    try std.testing.expect(!webSocketTargetAllowed(.GET, "/ws/"));
    try std.testing.expect(!webSocketTargetAllowed(.GET, "/ws?token=secret"));
}

test "query token and disabled file surfaces are rejected by policy" {
    const split = splitTarget("/ws?token=abc&x=1");
    try std.testing.expectEqualStrings("/ws", split.path);
    try std.testing.expectEqualStrings("abc", queryValue(split.query, "token").?);
    try std.testing.expect(disabledFileApi("/api/file"));
    try std.testing.expect(disabledFileApi("/api/preview"));
    try std.testing.expect(blockedRpcMethod("web.directory.list"));
    try std.testing.expect(blockedRpcMethod(headless.access_protocol.METHOD_DAEMON_PAIRING_GRANT_CREATE));
    try std.testing.expect(blockedRpcMethod(headless.access_protocol.METHOD_DAEMON_PAIRING_GRANT_LIST));
    try std.testing.expect(blockedRpcMethod(headless.access_protocol.METHOD_DAEMON_PAIRING_GRANT_REVOKE));
    try std.testing.expect(blockedRpcMethod(headless.access_protocol.METHOD_DAEMON_DEVICE_LIST));
    try std.testing.expect(blockedRpcMethod(headless.access_protocol.METHOD_DAEMON_DEVICE_REVOKE));
    try std.testing.expect(blockedRpcMethod(headless.access_protocol.METHOD_DAEMON_PAIRING_EXCHANGE));
    try std.testing.expect(blockedRpcMethod(headless.access_protocol.METHOD_DAEMON_DEVICE_AUTHENTICATE));
    try std.testing.expect(blockedRpcMethod(headless.access_protocol.METHOD_DAEMON_DEVICE_AUTHORIZE));
    try std.testing.expect(blockedRpcMethod(headless.connect_protocol.METHOD_LOGIN));
    try std.testing.expect(blockedRpcMethod(headless.connect_protocol.METHOD_BOOTSTRAP_CONSUME));
    try std.testing.expect(!blockedRpcMethod("core.status"));
}

test "device authorization and WebSocket ticket headers are exact" {
    const device_id = "0123456789abcdef0123456789abcdef";
    const credential = "a" ** headless.access_protocol.SECRET_HEX_BYTES;
    const value = headless.access_protocol.DEVICE_AUTHORIZATION_SCHEME ++ " " ++ device_id ++ "." ++ credential;
    const parsed = parseDeviceAuthorization(value).?;
    try std.testing.expectEqualStrings(device_id, parsed.device_id);
    try std.testing.expectEqualStrings(credential, parsed.credential);
    try std.testing.expect(parseDeviceAuthorization("verdedevice " ++ device_id ++ "." ++ credential) == null);
    try std.testing.expect(parseDeviceAuthorization(headless.access_protocol.DEVICE_AUTHORIZATION_SCHEME ++ "  " ++ device_id ++ "." ++ credential) == null);

    const ticket = "b" ** auth_mod.PAIR_TOKEN_BYTES;
    const protocols = headless.access_protocol.WEBSOCKET_PROTOCOL_NAME ++ ", " ++
        headless.access_protocol.WEBSOCKET_TICKET_PROTOCOL_PREFIX ++ ticket;
    try std.testing.expectEqualStrings(ticket, parsePairWebSocketProtocolValue(protocols).?);
    try std.testing.expect(parsePairWebSocketProtocolValue(protocols ++ ", extra") == null);
    try std.testing.expect(parsePairWebSocketProtocolValue(
        headless.access_protocol.WEBSOCKET_TICKET_PROTOCOL_PREFIX ++ ticket,
    ) == null);
    try std.testing.expect(parsePairWebSocketProtocolValue(
        headless.access_protocol.WEBSOCKET_PROTOCOL_NAME ++ ", " ++
            headless.access_protocol.WEBSOCKET_TICKET_PROTOCOL_PREFIX ++ ("B" ** auth_mod.PAIR_TOKEN_BYTES),
    ) == null);
}

test "paired scope policy is shared by HTTP and WebSocket forwarding" {
    try std.testing.expectEqual(
        headless.access_protocol.scopeBit(.chat_write),
        headless.access_protocol.requiredScopeMaskForRpc("chat.turn.start").?,
    );
    try std.testing.expect(headless.access_protocol.requiredScopeMaskForRpc("daemon.stop") == null);
    try std.testing.expect(headless.access_protocol.requiredScopeMaskForRpc("web.directory.list") == null);
}

test "durable device rejection is distinguished from daemon failure" {
    const rejected = try headless.encodeErrorResponse(
        std.testing.allocator,
        1,
        "authentication_rejected",
        "access credential was not accepted",
    );
    defer std.testing.allocator.free(rejected);
    try std.testing.expectEqual(
        DeviceAuthorizationStatus.rejected,
        deviceAuthorizationStatus(
            std.testing.allocator,
            rejected,
            "0123456789abcdef0123456789abcdef",
            headless.access_protocol.scopeBit(.runtime_read),
        ),
    );
    try std.testing.expectEqual(
        DeviceAuthorizationStatus.unavailable,
        deviceAuthorizationStatus(
            std.testing.allocator,
            "not-json",
            "0123456789abcdef0123456789abcdef",
            headless.access_protocol.scopeBit(.runtime_read),
        ),
    );
}

test "network RPC requires a target after bootstrap status" {
    const untargeted_status: headless.protocol.Request = .{
        .id = 1,
        .method = "core.status",
    };
    try std.testing.expect(!rpcRequestMissingRequiredTarget(untargeted_status));

    const untargeted_mutation: headless.protocol.Request = .{
        .id = 2,
        .method = "chat.turn.start",
    };
    try std.testing.expect(rpcRequestMissingRequiredTarget(untargeted_mutation));

    const targeted_mutation: headless.protocol.Request = .{
        .id = 3,
        .method = "chat.turn.start",
        .target = .{
            .runtime_id = "0123456789abcdef0123456789abcdef",
            .instance_id = "00112233445566778899aabbccddeeff",
        },
    };
    try std.testing.expect(!rpcRequestMissingRequiredTarget(targeted_mutation));
}

test "websocket session target is copied from a capable status envelope" {
    const status_json = try headless.encodeOkResponse(std.testing.allocator, 1, .{
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .instance_id = "00112233445566778899aabbccddeeff",
        .runtime_capabilities = &.{ "rpc.target.v1", "core.snapshot.v1" },
    });
    defer std.testing.allocator.free(status_json);

    const target = try SessionRuntimeTarget.fromStatusEnvelope(std.testing.allocator, status_json);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef",
        target.borrowed().runtime_id,
    );
    try std.testing.expectEqualStrings(
        "00112233445566778899aabbccddeeff",
        target.borrowed().instance_id,
    );

    const incapable_json = try headless.encodeOkResponse(std.testing.allocator, 2, .{
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .instance_id = "00112233445566778899aabbccddeeff",
        .runtime_capabilities = &.{"core.snapshot.v1"},
    });
    defer std.testing.allocator.free(incapable_json);
    try std.testing.expectError(
        error.TargetRpcUnavailable,
        SessionRuntimeTarget.fromStatusEnvelope(std.testing.allocator, incapable_json),
    );
}

test "loopback Host and exact HTTP Origin validation" {
    try std.testing.expect(validLoopbackAuthority("127.0.0.1:7420"));
    try std.testing.expect(validLoopbackAuthority("localhost:6783"));
    try std.testing.expect(validLoopbackAuthority("[::1]:7420"));
    try std.testing.expect(!validLoopbackAuthority("0.0.0.0:7420"));
    try std.testing.expect(!validLoopbackAuthority("verde.example:7420"));
    try std.testing.expect(!validLoopbackAuthority("127.0.0.1:0"));
    try std.testing.expect(sameLoopbackOrigin("127.0.0.1:7420", "http://127.0.0.1:7420"));
    try std.testing.expect(sameLoopbackOrigin("LOCALHOST:6783", "http://localhost:6783"));
    try std.testing.expect(!sameLoopbackOrigin("127.0.0.1:7420", "http://127.0.0.1:6783"));
    try std.testing.expect(!sameLoopbackOrigin("127.0.0.1:7420", "https://127.0.0.1:7420"));
}

test "session cookie parsing is exact and rejects duplicates" {
    try std.testing.expectEqualStrings(
        "abc123",
        cookieValue("theme=dark; verde_session=abc123; x=y", "verde_session").?,
    );
    try std.testing.expect(cookieValue("verde_sessionish=no", "verde_session") == null);
    try std.testing.expect(cookieValue("verde_session=one; verde_session=two", "verde_session") == null);
    try std.testing.expect(cookieValue("verde_session=bad value", "verde_session") == null);
}

test "built-in login flow keeps credentials out of URLs and browser storage" {
    try std.testing.expect(std.mem.indexOf(u8, LOGIN_HTML, "action=\"/auth/session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, LOGIN_HTML, "autocomplete=\"off\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, LOGIN_JS, "fetch('/auth/session'") != null);
    try std.testing.expect(std.mem.indexOf(u8, LOGIN_JS, "JSON.stringify({ token })") != null);
    try std.testing.expect(std.mem.indexOf(u8, LOGIN_JS, "window.location.replace('/')") != null);
    try std.testing.expect(std.mem.indexOf(u8, LOGIN_JS, "localStorage") == null);
    try std.testing.expect(std.mem.indexOf(u8, LOGIN_JS, "sessionStorage") == null);
    try std.testing.expect(std.mem.indexOf(u8, LOGIN_JS, "URLSearchParams") == null);
}

test "security headers omit CORS and constrain active content" {
    var saw_csp = false;
    var saw_nosniff = false;
    var saw_referrer = false;
    for (BASE_SECURITY_HEADERS) |header| {
        try std.testing.expect(!std.ascii.startsWithIgnoreCase(header.name, "access-control-"));
        if (std.ascii.eqlIgnoreCase(header.name, "content-security-policy")) {
            saw_csp = true;
            try std.testing.expect(std.mem.indexOf(u8, header.value, "object-src 'none'") != null);
            try std.testing.expect(std.mem.indexOf(u8, header.value, "frame-ancestors 'none'") != null);
        }
        if (std.ascii.eqlIgnoreCase(header.name, "x-content-type-options")) saw_nosniff = true;
        if (std.ascii.eqlIgnoreCase(header.name, "referrer-policy")) saw_referrer = true;
    }
    try std.testing.expect(saw_csp and saw_nosniff and saw_referrer);
}

test "web chat image upload validation accepts supported signatures only" {
    try std.testing.expectEqualStrings("image/jpeg", supportedImageMime("IMAGE/JPEG").?);
    try std.testing.expect(supportedImageMime("application/pdf") == null);
    try std.testing.expect(imageBytesMatchMime("image/png", "\x89PNG\r\n\x1a\nrest"));
    try std.testing.expect(imageBytesMatchMime("image/webp", "RIFF1234WEBPrest"));
    try std.testing.expect(!imageBytesMatchMime("image/png", "not an image"));
    try std.testing.expect(validAttachmentId("web-abc-123.png"));
    try std.testing.expect(!validAttachmentId("../state.sqlite"));
    try std.testing.expect(!validAttachmentId("web-a/b.png"));
    try std.testing.expect(!validAttachmentId("web-user.svg"));
    try std.testing.expect(!validAttachmentId("web-user.html"));
}

test "gateway resource policies stay explicitly bounded" {
    try std.testing.expectEqual(@as(usize, 64), MAX_CONNECTIONS);
    try std.testing.expectEqual(@as(usize, 16), MAX_WEBSOCKETS);
    try std.testing.expectEqual(@as(usize, 32), MAX_KEEPALIVE_REQUESTS);
    try std.testing.expectEqual(@as(usize, 4 * 1024), MAX_HEADER_BYTES);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), MAX_RPC_FRAME_BYTES);
}
