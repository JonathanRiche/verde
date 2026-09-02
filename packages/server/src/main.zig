//! Account-free operator CLI for a standalone Verde runtime.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const config = @import("config.zig");
const service = @import("service.zig");
const supervisor = @import("supervisor.zig");
const tailscale = @import("tailscale.zig");
const oidc = @import("oidc.zig");

const VERSION: []const u8 = build_options.version;
const PUBLIC_READINESS_REQUEST_TIMEOUT_MS: u32 = 2_000;
const PUBLIC_READINESS_ATTEMPTS: usize = 15;

const Resolved = struct {
    allocator: std.mem.Allocator,
    artifacts: service.ArtifactPaths,
    runtime: service.RuntimePaths,

    fn deinit(self: *Resolved) void {
        self.allocator.free(self.artifacts.server);
        self.allocator.free(self.artifacts.daemon);
        self.allocator.free(self.artifacts.web);
        self.allocator.free(self.artifacts.static_dir);
        self.allocator.free(self.artifacts.provider_bridge);
        self.allocator.free(self.runtime.data_dir);
        self.allocator.free(self.runtime.token_file);
        self.allocator.free(self.runtime.unit_dir);
        self.allocator.free(self.runtime.state_dir);
    }
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        writeStderr(init.io, "verde-server: {s}\n", .{errorMessage(err)}) catch {};
        std.process.exit(exitCode(err));
    };
}

fn run(init: std.process.Init) !void {
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer iterator.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    while (iterator.next()) |arg| try argv.append(init.gpa, arg);

    var options = try config.parse(init.gpa, argv.items);
    defer config.deinit(&options, init.gpa);
    if (options.command == .help) return printHelp(init.io);
    if (options.command == .version) return writeStdout(init.io, "verde-server {s}\n", .{VERSION});

    var resolved = try resolve(init.gpa, init.io, init.environ_map, options);
    defer resolved.deinit();
    switch (options.command) {
        .init => try runInit(init.io, init.gpa, resolved),
        .serve => try runServe(init.io, init.gpa, resolved, options),
        .status => try runStatus(init.io, init.gpa, resolved, options.json),
        .pair_create, .pair_list, .pair_revoke, .device_list, .device_revoke => try runDelegate(init.io, init.gpa, resolved, options),
        .tailscale_doctor => try runTailscaleDoctor(init.io, init.gpa, resolved, options),
        .connect => try runConnect(init.io, init.gpa, init.environ_map, resolved, options),
        .connect_status => try runConnectLifecycle(init.io, init.gpa, resolved, options),
        .connect_unlink, .connect_logout => try runConnectRemoval(init.io, init.gpa, init.environ_map, resolved, options),
        .service_install => try serviceInstall(init.io, init.gpa, resolved, options),
        .service_status => try serviceStatus(init.io, init.gpa, resolved, options.json),
        .service_update => try serviceUpdate(init.io, init.gpa, resolved),
        .service_uninstall => try serviceUninstall(init.io, init.gpa, resolved),
        .version, .help => unreachable,
    }
}

fn resolve(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, options: config.Options) !Resolved {
    const executable = try std.process.executablePathAlloc(io, allocator);
    errdefer allocator.free(executable);
    const bin_dir = std.fs.path.dirname(executable) orelse return error.InvalidArtifactLayout;
    const root = std.fs.path.dirname(bin_dir) orelse return error.InvalidArtifactLayout;
    const daemon = try std.fs.path.join(allocator, &.{ bin_dir, "verde-daemon" });
    errdefer allocator.free(daemon);
    const web = try std.fs.path.join(allocator, &.{ bin_dir, "verde-web" });
    errdefer allocator.free(web);
    const static_dir = try std.fs.path.join(allocator, &.{ root, "share", "verde", "web" });
    errdefer allocator.free(static_dir);
    const provider_bridge = try std.fs.path.join(allocator, &.{ root, "share", "verde", "provider_bridge.mjs" });
    errdefer allocator.free(provider_bridge);

    const home = env.get("HOME") orelse return error.HomeUnavailable;
    const data_dir = if (options.data_dir) |path|
        try allocator.dupe(u8, path)
    else if (env.get("XDG_DATA_HOME")) |xdg|
        try std.fs.path.join(allocator, &.{ xdg, "verde", "runtime" })
    else
        try std.fs.path.join(allocator, &.{ home, ".local", "share", "verde", "runtime" });
    errdefer allocator.free(data_dir);
    const token_file = if (options.token_file) |path|
        try allocator.dupe(u8, path)
    else if (env.get("XDG_CONFIG_HOME")) |xdg|
        try std.fs.path.join(allocator, &.{ xdg, "verde", "web-token" })
    else
        try std.fs.path.join(allocator, &.{ home, ".config", "verde", "web-token" });
    errdefer allocator.free(token_file);
    const config_home = env.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(allocator, &.{ home, ".config" });
    defer if (env.get("XDG_CONFIG_HOME") == null) allocator.free(config_home);
    const state_home = env.get("XDG_STATE_HOME") orelse try std.fs.path.join(allocator, &.{ home, ".local", "state" });
    defer if (env.get("XDG_STATE_HOME") == null) allocator.free(state_home);
    const unit_dir = if (builtin.os.tag == .macos)
        try std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents" })
    else
        try std.fs.path.join(allocator, &.{ config_home, "systemd", "user" });
    errdefer allocator.free(unit_dir);
    const state_dir = try std.fs.path.join(allocator, &.{ state_home, "verde-server" });
    errdefer allocator.free(state_dir);

    return .{
        .allocator = allocator,
        .artifacts = .{
            .server = executable,
            .daemon = daemon,
            .web = web,
            .static_dir = static_dir,
            .provider_bridge = provider_bridge,
        },
        .runtime = .{
            .data_dir = data_dir,
            .token_file = token_file,
            .unit_dir = unit_dir,
            .state_dir = state_dir,
            .gateway_port = options.gateway_port,
            .trusted_proxy_origin = null,
        },
    };
}

fn runInit(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved) !void {
    try service.validateArtifactPaths(io, resolved.artifacts);
    try service.ensureOwnerOnlyDir(io, resolved.runtime.data_dir);
    if (std.fs.path.dirname(resolved.runtime.token_file)) |parent| try service.ensureOwnerOnlyDir(io, parent);
    try service.ensureOwnerOnlyToken(io, resolved.runtime.token_file);
    const exit_code = try runInherited(io, allocator, &.{ resolved.artifacts.daemon, "init", "--data-dir", resolved.runtime.data_dir });
    if (exit_code != 0) return error.DaemonCommandFailed;
    try writeStdout(io, "Gateway token: {s} (owner-only; value not displayed)\n", .{resolved.runtime.token_file});
}

fn runServe(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, options: config.Options) !void {
    if (options.tailscale) return runTailscaleServe(io, allocator, resolved, options);
    try runInit(io, allocator, resolved);
    try writeStdout(io,
        \\Verde server foreground supervision
        \\  daemon:   {s}
        \\  gateway:  {s}
        \\  data:     {s}
        \\  endpoint: http://127.0.0.1:{d}
        \\  static:   {s}
        \\  token:    {s} (value never logged)
        \\
    , .{ resolved.artifacts.daemon, resolved.artifacts.web, resolved.runtime.data_dir, resolved.runtime.gateway_port, resolved.artifacts.static_dir, resolved.runtime.token_file });
    const code = try supervisor.serve(io, .{
        .daemon = resolved.artifacts.daemon,
        .gateway = resolved.artifacts.web,
        .data_dir = resolved.runtime.data_dir,
        .token_file = resolved.runtime.token_file,
        .static_dir = resolved.artifacts.static_dir,
        .gateway_port = resolved.runtime.gateway_port,
    }, null);
    if (code != 0) return error.ChildFailed;
}

// Installs the supervised runtime because a background Tailscale mapping must
// never outlive an unsupervised loopback backend after reboot.
fn runTailscaleServe(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, options: config.Options) !void {
    var lifecycle_lock = try tailscale.LifecycleLock.acquire(io, resolved.runtime.state_dir);
    defer lifecycle_lock.deinit(io);
    var system_runner: tailscale.SystemRunner = .{ .io = io };
    var prepared = try tailscale.prepare(
        allocator,
        system_runner.runner(),
        resolved.runtime.gateway_port,
        options.tailscale_https_port,
    );
    defer prepared.deinit();
    if (prepared.state == .collision) {
        try emitTailscaleDiagnostic(io, allocator, prepared, options.json);
        return error.TailscaleServeConflict;
    }
    var service_ready = false;
    var mutation_cleanup_armed = false;
    errdefer if (mutation_cleanup_armed and !service_ready) {
        protectFailedTailscaleMutation(
            io,
            allocator,
            system_runner.runner(),
            resolved.runtime.state_dir,
            prepared,
        );
    };
    if (prepared.state == .available) {
        _ = try tailscale.writePendingIntent(io, allocator, resolved.runtime.state_dir, prepared);
        mutation_cleanup_armed = true;
    }
    tailscale.apply(allocator, system_runner.runner(), &prepared) catch |err| switch (err) {
        error.TailscaleServeChanged => {
            mutation_cleanup_armed = false;
            std.log.warn("preserved Tailscale intent after CAS conflict", .{});
            return err;
        },
        else => return err,
    };
    try tailscale.writeIntent(io, allocator, resolved.runtime.state_dir, prepared);

    var managed = resolved;
    managed.runtime.trusted_proxy_origin = prepared.origin;
    try runInit(io, allocator, managed);
    try service.install(io, allocator, managed.artifacts, managed.runtime, VERSION);
    try activateServices(io, allocator, managed.runtime.unit_dir, false);
    try waitForGateway(io, managed.runtime.gateway_port);
    try waitForPublicRuntime(io, allocator, prepared.origin);
    service_ready = true;
    try writeStdout(
        io,
        "Verde is installed as a background service and Tailscale terminates HTTPS at {s}.\n",
        .{prepared.origin},
    );
    try printPairGrant(io, allocator, managed, prepared.origin);
}

fn runTailscaleDoctor(
    io: std.Io,
    allocator: std.mem.Allocator,
    resolved: Resolved,
    options: config.Options,
) !void {
    var system_runner: tailscale.SystemRunner = .{ .io = io };
    var prepared = try tailscale.prepare(
        allocator,
        system_runner.runner(),
        resolved.runtime.gateway_port,
        options.tailscale_https_port,
    );
    defer prepared.deinit();
    try emitTailscaleDiagnostic(io, allocator, prepared, options.json);
    if (prepared.state == .collision) return error.TailscaleServeConflict;
}

fn emitTailscaleDiagnostic(
    io: std.Io,
    allocator: std.mem.Allocator,
    prepared: tailscale.Prepared,
    json: bool,
) !void {
    const diagnostic = tailscale.diagnostic(prepared);
    if (json) {
        const encoded = try std.json.Stringify.valueAlloc(allocator, diagnostic, .{});
        defer allocator.free(encoded);
        return writeStdout(io, "{s}\n", .{encoded});
    }
    try writeStdout(
        io,
        "Tailscale Serve listener: {s}\nState: {s}\nRequested backend: {s}\n",
        .{ diagnostic.endpoint, @tagName(diagnostic.state), diagnostic.requested_target },
    );
    if (diagnostic.current_target) |current| {
        try writeStdout(io, "Current root backend: {s}\n", .{current});
    }
    if (prepared.state != .collision) return;
    try writeStdout(io,
        \\Verde did not change this listener because another service or route occupies it.
        \\Safe recovery choices:
        \\  1. Keep the existing listener and retry Verde on another port:
        \\     verde-server serve --tailscale --tailscale-https-port {d}
        \\  2. Keep the existing listener and use the documented SSH recovery path.
        \\  3. If you have independently verified ownership, remove that exact
        \\     listener manually, then rerun Verde. Never use `tailscale serve reset`.
        \\
    , .{diagnostic.suggested_https_port.?});
}

fn printPairGrant(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, origin: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 30) : (attempts += 1) {
        const result = try runCaptured(allocator, io, &.{
            resolved.artifacts.daemon, "pair", "create", "--label", "Tailscale", "--data-dir", resolved.runtime.data_dir, "--json",
        });
        defer {
            std.crypto.secureZero(u8, result.stdout);
            allocator.free(result.stdout);
        }
        defer allocator.free(result.stderr);
        if (termExitCode(result.term) == 0) {
            const Wire = struct {
                ok: bool,
                data_dir: []const u8,
                result: struct {
                    access_protocol_version: u32,
                    runtime_id: []const u8,
                    instance_id: []const u8,
                    grant_id: []const u8,
                    pairing_token: []const u8,
                    expires_at_ms: i64,
                    scopes: []const []const u8,
                },
            };
            var parsed = std.json.parseFromSlice(Wire, allocator, result.stdout, .{ .ignore_unknown_fields = false }) catch
                return error.InvalidPairGrantResponse;
            defer parsed.deinit();
            if (!parsed.value.ok or parsed.value.result.access_protocol_version != 1) return error.PairGrantFailed;
            try validateLowerHex(parsed.value.result.runtime_id, 32);
            try validateLowerHex(parsed.value.result.instance_id, 32);
            const pair_url = try pairUrlAlloc(allocator, origin, parsed.value.result.grant_id, parsed.value.result.pairing_token);
            defer {
                std.crypto.secureZero(u8, pair_url);
                allocator.free(pair_url);
            }
            try writeSensitiveStdout(io,
                \\Open or paste this once in Verde:
                \\{s}
                \\
                \\Manual fallback
                \\Host: {s}
                \\Grant ID: {s}
                \\One-time code: {s}
                \\Runtime: {s} / {s}
                \\Expires: {d}
                \\
            , .{ pair_url, origin, parsed.value.result.grant_id, parsed.value.result.pairing_token, parsed.value.result.runtime_id, parsed.value.result.instance_id, parsed.value.result.expires_at_ms });
            return;
        }
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    }
    return error.PairGrantFailed;
}

fn pairUrlAlloc(allocator: std.mem.Allocator, origin: []const u8, grant_id: []const u8, code: []const u8) ![]u8 {
    try validateHttpsOrigin(origin);
    try validateLowerHex(grant_id, 32);
    try validateLowerHex(code, 64);
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    for (origin) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try encoded.writer.writeByte(byte);
        } else {
            const hex = "0123456789ABCDEF";
            try encoded.writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0xf] });
        }
    }
    const host = try encoded.toOwnedSlice();
    defer allocator.free(host);
    return std.fmt.allocPrint(allocator, "verde://pair?host={s}&grant_id={s}#code={s}", .{
        host, grant_id, code,
    });
}

fn validateHttpsOrigin(origin: []const u8) !void {
    const uri = std.Uri.parse(origin) catch return error.InvalidPairOrigin;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or !uri.path.isEmpty() or uri.query != null or uri.fragment != null)
    {
        return error.InvalidPairOrigin;
    }
}

fn validateLowerHex(value: []const u8, expected_length: usize) !void {
    if (value.len != expected_length) return error.InvalidPairGrantResponse;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) {
        return error.InvalidPairGrantResponse;
    };
}

fn waitForGateway(io: std.Io, port: u16) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (gatewayReachable(io, port)) return;
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    }
    return error.GatewayStartupTimedOut;
}

fn waitForPublicRuntime(io: std.Io, allocator: std.mem.Allocator, origin: []const u8) !void {
    const metadata_url = try std.fmt.allocPrint(allocator, "{s}/.well-known/verde-runtime", .{origin});
    defer allocator.free(metadata_url);
    var attempts: usize = 0;
    while (attempts < PUBLIC_READINESS_ATTEMPTS) : (attempts += 1) {
        var http: oidc.HttpTransport = .{ .timeout_ms = PUBLIC_READINESS_REQUEST_TIMEOUT_MS };
        if (http.transport().send(allocator, .GET, metadata_url, null)) |response_value| {
            var response = response_value;
            defer response.deinit(allocator);
            if (response.status == .ok and runtimeMetadataMatches(allocator, response.body, origin)) return;
        } else |_| {}
        try std.Io.sleep(io, .fromMilliseconds(200), .awake);
    }
    return error.PublicGatewayStartupTimedOut;
}

fn runtimeMetadataMatches(allocator: std.mem.Allocator, encoded: []const u8, origin: []const u8) bool {
    const Metadata = struct {
        access_protocol_version: u32,
        runtime_id: []const u8,
        instance_id: []const u8,
        https_url: []const u8,
        wss_url: []const u8,
        capabilities: []const []const u8,
    };
    var parsed = std.json.parseFromSlice(Metadata, allocator, encoded, .{
        .ignore_unknown_fields = false,
    }) catch return false;
    defer parsed.deinit();
    if (parsed.value.access_protocol_version != 1 or
        !std.mem.eql(u8, parsed.value.https_url, origin) or
        parsed.value.capabilities.len != 1 or
        !std.mem.eql(u8, parsed.value.capabilities[0], "access.pair.v1")) return false;
    validateLowerHex(parsed.value.runtime_id, 32) catch return false;
    validateLowerHex(parsed.value.instance_id, 32) catch return false;
    if (!std.mem.startsWith(u8, origin, "https://")) return false;
    const expected_wss = std.fmt.allocPrint(allocator, "wss://{s}/ws", .{origin["https://".len..]}) catch return false;
    defer allocator.free(expected_wss);
    return std.mem.eql(u8, parsed.value.wss_url, expected_wss);
}

fn runStatus(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, json: bool) !void {
    const result = try runCaptured(allocator, io, &.{ resolved.artifacts.daemon, "status", "--data-dir", resolved.runtime.data_dir, "--json" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const daemon_json = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    const daemon_ok = termExitCode(result.term) == 0 and jsonOk(allocator, daemon_json);
    const gateway_ok = gatewayReachable(io, resolved.runtime.gateway_port);
    if (json) {
        try writeStdout(io, "{{\"ok\":{},\"daemon_ok\":{},\"gateway_ok\":{},\"endpoint\":\"http://127.0.0.1:{d}\",\"data_dir\":{f},\"token_file\":{f},\"daemon\":{s}}}\n", .{
            daemon_ok and gateway_ok,                     daemon_ok,                                      gateway_ok,                                       resolved.runtime.gateway_port,
            std.json.fmt(resolved.runtime.data_dir, .{}), std.json.fmt(resolved.runtime.token_file, .{}), if (daemon_json.len > 0) daemon_json else "null",
        });
    } else {
        try writeStdout(io, "Daemon: {s}\nGateway: {s} (http://127.0.0.1:{d})\nData: {s}\nToken file: {s}\n", .{
            if (daemon_ok) "running" else "stopped", if (gateway_ok) "reachable" else "unreachable",
            resolved.runtime.gateway_port,           resolved.runtime.data_dir,
            resolved.runtime.token_file,
        });
        if (result.stderr.len > 0) try writeStderr(io, "{s}", .{result.stderr});
    }
    if (!daemon_ok or !gateway_ok) return error.Unhealthy;
}

fn runDelegate(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, options: config.Options) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, resolved.artifacts.daemon);
    switch (options.command) {
        .pair_create => try args.appendSlice(allocator, &.{ "pair", "create" }),
        .pair_list => try args.appendSlice(allocator, &.{ "pair", "list" }),
        .pair_revoke => try args.appendSlice(allocator, &.{ "pair", "revoke" }),
        .device_list => try args.appendSlice(allocator, &.{ "device", "list" }),
        .device_revoke => try args.appendSlice(allocator, &.{ "device", "revoke" }),
        else => unreachable,
    }
    try args.appendSlice(allocator, options.delegate_args);
    try args.appendSlice(allocator, &.{ "--data-dir", resolved.runtime.data_dir });
    if (options.json) try args.append(allocator, "--json");
    const code = try runInherited(io, allocator, args.items);
    if (code != 0) return error.DaemonCommandFailed;
}

fn runConnect(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    resolved: Resolved,
    options: config.Options,
) !void {
    const control_plane = try resolveControlPlane(allocator, io, env, resolved.runtime.state_dir, options);
    defer allocator.free(control_plane);
    const install_background = options.install_service or
        (!options.headless and try promptInstallService(io));
    const saved_origin = tailscale.savedOrigin(io, allocator, resolved.runtime.state_dir) catch null;
    defer if (saved_origin) |origin| allocator.free(origin);
    const descriptor_origin = if (saved_origin == null and options.descriptor_file != null)
        try descriptorOriginAlloc(io, allocator, options.descriptor_file.?)
    else
        null;
    defer if (descriptor_origin) |origin| allocator.free(origin);
    var managed = resolved;
    managed.runtime.trusted_proxy_origin = saved_origin orelse descriptor_origin;
    if (managed.runtime.trusted_proxy_origin == null) return error.ConnectDescriptorUnavailable;
    if (install_background) {
        try runInit(io, allocator, managed);
        try service.install(io, allocator, managed.artifacts, managed.runtime, VERSION);
        try activateServices(io, allocator, managed.runtime.unit_dir, false);
        try waitForDaemon(io, allocator, managed);
    }
    var owned_token: ?oidc.Token = null;
    defer if (owned_token) |*token| token.deinit();
    const credential_file = if (options.credential_file) |path|
        path
    else credential: {
        var http: oidc.HttpTransport = .{};
        var session = try oidc.start(allocator, http.transport(), control_plane);
        defer session.deinit();
        try writeStdout(io, "Authorize this runtime at: {s}\nCode: {s}\n", .{ session.verification_uri, session.user_code });
        if (!options.headless) openBrowser(io, allocator, session.verification_uri) catch {
            try writeStderr(io, "warning: could not open a browser; open the authorization URL manually\n", .{});
        };
        var interval: u16 = session.interval;
        var elapsed: u32 = 0;
        while (elapsed < session.expires_in) {
            try std.Io.sleep(io, .fromSeconds(interval), .awake);
            elapsed += interval;
            owned_token = oidc.poll(allocator, http.transport(), session) catch |err| switch (err) {
                error.ConnectSlowDown => {
                    interval = @min(interval + 5, 60);
                    continue;
                },
                else => return err,
            };
            if (owned_token != null) break;
        }
        if (owned_token == null) return error.ConnectAuthorizationExpired;
        break :credential try oidc.writeHandoff(io, allocator, resolved.runtime.state_dir, owned_token.?.bytes);
    };
    defer if (options.credential_file == null) {
        oidc.removeFile(io, credential_file);
        allocator.free(credential_file);
    };

    const generated_descriptor = if (options.descriptor_file == null)
        try generateRuntimeDescriptor(io, allocator, managed)
    else
        null;
    defer if (generated_descriptor) |path| {
        oidc.removeFile(io, path);
        allocator.free(path);
    };
    const descriptor = options.descriptor_file orelse generated_descriptor.?;
    if (try runInherited(io, allocator, &.{
        resolved.artifacts.daemon, "connect",       "login",      "--control-plane",         control_plane,
        "--credential-file",       credential_file, "--data-dir", resolved.runtime.data_dir,
    }) != 0) return error.ConnectLoginFailed;
    errdefer removeDaemonConnectToken(io, allocator, resolved.runtime.data_dir);
    if (try runInherited(io, allocator, &.{
        resolved.artifacts.daemon, "connect",                 "link", "--descriptor-file", descriptor,
        "--data-dir",              resolved.runtime.data_dir,
    }) != 0) return error.ConnectLinkFailed;
    removeDaemonConnectToken(io, allocator, resolved.runtime.data_dir);
    try writeConnectIntent(io, allocator, resolved.runtime.state_dir, control_plane);
    try runConnectLifecycle(io, allocator, resolved, .{ .command = .connect_status });
    try writeStdout(io, "Connect intent is durable. The OIDC bearer was removed after linking.\n", .{});
}

fn promptInstallService(io: std.Io) !bool {
    if (!try std.Io.File.stdin().isTty(io)) return false;
    try writeStdout(io, "Install and start Verde as a background user service? [Y/n] ", .{});
    var buffer: [16]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return true,
        else => return err,
    };
    const answer = std.mem.trim(u8, line, &std.ascii.whitespace);
    return answer.len == 0 or std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

fn runConnectLifecycle(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, options: config.Options) !void {
    const subcommand: []const u8 = switch (options.command) {
        .connect_status => "status",
        .connect_unlink => "unlink",
        .connect_logout => "logout",
        else => unreachable,
    };
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ resolved.artifacts.daemon, "connect", subcommand, "--data-dir", resolved.runtime.data_dir });
    if (options.json) try args.append(allocator, "--json");
    if (try runInherited(io, allocator, args.items) != 0) return error.DaemonCommandFailed;
    if (options.command == .connect_unlink or options.command == .connect_logout) {
        removeDaemonConnectToken(io, allocator, resolved.runtime.data_dir);
    }
}

fn runConnectRemoval(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    resolved: Resolved,
    options: config.Options,
) !void {
    const control_plane = try resolveControlPlane(allocator, io, env, resolved.runtime.state_dir, options);
    defer allocator.free(control_plane);
    var authorization = try authorizeConnect(io, allocator, resolved.runtime.state_dir, control_plane, options);
    defer authorization.deinit(io);
    if (try runInherited(io, allocator, &.{
        resolved.artifacts.daemon, "connect",          "login",      "--control-plane",         control_plane,
        "--credential-file",       authorization.path, "--data-dir", resolved.runtime.data_dir,
    }) != 0) return error.ConnectLoginFailed;
    defer removeDaemonConnectToken(io, allocator, resolved.runtime.data_dir);
    try runConnectLifecycle(io, allocator, resolved, options);
}

const ConnectAuthorization = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    owned_path: ?[]u8 = null,
    token: ?oidc.Token = null,

    fn deinit(self: *ConnectAuthorization, io: std.Io) void {
        if (self.token) |*token| token.deinit();
        if (self.owned_path) |path| {
            oidc.removeFile(io, path);
            self.allocator.free(path);
        }
        self.* = undefined;
    }
};

fn authorizeConnect(
    io: std.Io,
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    control_plane: []const u8,
    options: config.Options,
) !ConnectAuthorization {
    if (options.credential_file) |path| return .{ .allocator = allocator, .path = path };
    var http: oidc.HttpTransport = .{};
    var session = try oidc.start(allocator, http.transport(), control_plane);
    defer session.deinit();
    try writeStdout(io, "Authorize this runtime at: {s}\nCode: {s}\n", .{ session.verification_uri, session.user_code });
    if (!options.headless) openBrowser(io, allocator, session.verification_uri) catch {
        try writeStderr(io, "warning: could not open a browser; open the authorization URL manually\n", .{});
    };
    var token: ?oidc.Token = null;
    errdefer if (token) |*value| value.deinit();
    var interval: u16 = session.interval;
    var elapsed: u32 = 0;
    while (elapsed < session.expires_in) {
        try std.Io.sleep(io, .fromSeconds(interval), .awake);
        elapsed += interval;
        token = oidc.poll(allocator, http.transport(), session) catch |err| switch (err) {
            error.ConnectSlowDown => {
                interval = @min(interval + 5, 60);
                continue;
            },
            else => return err,
        };
        if (token != null) break;
    }
    if (token == null) return error.ConnectAuthorizationExpired;
    const path = try oidc.writeHandoff(io, allocator, state_dir, token.?.bytes);
    return .{ .allocator = allocator, .path = path, .owned_path = path, .token = token };
}

fn resolveControlPlane(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    state_dir: []const u8,
    options: config.Options,
) ![]u8 {
    if (options.control_plane_url) |url| return allocator.dupe(u8, url);
    const saved_path = try std.fs.path.join(allocator, &.{ state_dir, "connect-intent.json" });
    defer allocator.free(saved_path);
    if (std.Io.Dir.cwd().readFileAlloc(io, saved_path, allocator, .limited(16 * 1024))) |encoded| {
        defer allocator.free(encoded);
        const Intent = struct { schema_version: u32, control_plane_url: []const u8 };
        var parsed = std.json.parseFromSlice(Intent, allocator, encoded, .{ .allocate = .alloc_always }) catch
            return error.InvalidConnectIntent;
        defer parsed.deinit();
        if (parsed.value.schema_version != 1) return error.InvalidConnectIntent;
        return allocator.dupe(u8, parsed.value.control_plane_url);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (env.get("VERDE_CONNECT_CONTROL_PLANE")) |url| return allocator.dupe(u8, url);
    if (options.headless or !try std.Io.File.stdin().isTty(io)) return error.ConnectControlPlaneRequired;
    try writeStdout(io, "Connect control-plane HTTPS URL: ", .{});
    var buffer: [2048]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    const line = try reader.interface.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.ConnectControlPlaneRequired;
    return allocator.dupe(u8, trimmed);
}

fn writeConnectIntent(io: std.Io, allocator: std.mem.Allocator, state_dir: []const u8, control_plane: []const u8) !void {
    try service.ensureOwnerOnlyDir(io, state_dir);
    const encoded = try std.json.Stringify.valueAlloc(allocator, .{
        .schema_version = @as(u32, 1),
        .control_plane_url = control_plane,
    }, .{});
    defer allocator.free(encoded);
    const path = try std.fs.path.join(allocator, &.{ state_dir, "connect-intent.json" });
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, encoded);
}

fn removeDaemonConnectToken(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) void {
    const path = std.fs.path.join(allocator, &.{ data_dir, "connect-control-plane.token" }) catch return;
    defer allocator.free(path);
    oidc.removeFile(io, path);
}

fn generateRuntimeDescriptor(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved) ![]u8 {
    const origin = tailscale.savedOrigin(io, allocator, resolved.runtime.state_dir) catch
        return error.ConnectDescriptorUnavailable;
    defer allocator.free(origin);
    const metadata_url = try std.fmt.allocPrint(allocator, "{s}/.well-known/verde-runtime", .{origin});
    defer allocator.free(metadata_url);
    var http: oidc.HttpTransport = .{};
    var response = try http.transport().send(allocator, .GET, metadata_url, null);
    defer response.deinit(allocator);
    if (response.status != .ok) return error.ConnectDescriptorUnavailable;
    const Metadata = struct {
        access_protocol_version: u32,
        runtime_id: []const u8,
        instance_id: []const u8,
        https_url: []const u8,
        wss_url: []const u8,
        capabilities: []const []const u8,
    };
    var metadata = std.json.parseFromSlice(Metadata, allocator, response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.ConnectDescriptorUnavailable;
    defer metadata.deinit();
    if (metadata.value.access_protocol_version != 1 or
        !std.mem.eql(u8, metadata.value.https_url, origin) or
        metadata.value.runtime_id.len != 32 or metadata.value.instance_id.len != 32)
    {
        return error.ConnectDescriptorUnavailable;
    }
    var system_runner: tailscale.SystemRunner = .{ .io = io };
    const spki = try tailscale.spkiSha256(
        io,
        allocator,
        system_runner.runner(),
        resolved.runtime.state_dir,
        origin,
    );
    const encoded = try std.json.Stringify.valueAlloc(allocator, .{
        .contract_version = "1",
        .runtime_id = metadata.value.runtime_id,
        .instance_id = metadata.value.instance_id,
        .https_url = metadata.value.https_url,
        .wss_url = metadata.value.wss_url,
        .tls_identity = .{ .kind = "spki_sha256", .sha256 = &spki },
        .protocol = .{ .major = @as(u16, 1), .minor = @as(u16, 0) },
        .capabilities = metadata.value.capabilities,
    }, .{});
    defer allocator.free(encoded);
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const path = try std.fmt.allocPrint(allocator, "{s}/.connect-descriptor-{s}.json", .{
        resolved.runtime.state_dir, @as([]const u8, &suffix),
    });
    errdefer allocator.free(path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    defer file.close(io);
    try file.writeStreamingAll(io, encoded);
    try file.sync(io);
    return path;
}

fn descriptorOriginAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const encoded = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(encoded);
    const Descriptor = struct { https_url: []const u8 };
    var parsed = std.json.parseFromSlice(Descriptor, allocator, encoded, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.ConnectDescriptorUnavailable;
    defer parsed.deinit();
    try validateHttpsOrigin(parsed.value.https_url);
    return allocator.dupe(u8, parsed.value.https_url);
}

fn openBrowser(io: std.Io, allocator: std.mem.Allocator, url: []const u8) !void {
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "open", url }
    else
        &.{ "xdg-open", url };
    if (try runInherited(io, allocator, argv) != 0) return error.BrowserOpenFailed;
}

fn waitForDaemon(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const result = try runCaptured(allocator, io, &.{
            resolved.artifacts.daemon, "status", "--data-dir", resolved.runtime.data_dir, "--json",
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (termExitCode(result.term) == 0 and jsonOk(allocator, result.stdout)) return;
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    }
    return error.DaemonStartupTimedOut;
}

fn serviceInstall(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, options: config.Options) !void {
    var managed = resolved;
    var prepared: ?tailscale.Prepared = null;
    defer if (prepared) |*value| value.deinit();
    var lifecycle_lock: ?tailscale.LifecycleLock = null;
    defer if (lifecycle_lock) |*value| value.deinit(io);
    var installed = false;
    var mutation_cleanup_armed = false;
    errdefer if (prepared) |value| if (mutation_cleanup_armed and !installed) {
        var cleanup_runner: tailscale.SystemRunner = .{ .io = io };
        protectFailedTailscaleMutation(
            io,
            allocator,
            cleanup_runner.runner(),
            resolved.runtime.state_dir,
            value,
        );
    };
    if (options.tailscale) {
        lifecycle_lock = try tailscale.LifecycleLock.acquire(io, resolved.runtime.state_dir);
        var system_runner: tailscale.SystemRunner = .{ .io = io };
        prepared = try tailscale.prepare(
            allocator,
            system_runner.runner(),
            resolved.runtime.gateway_port,
            options.tailscale_https_port,
        );
        if (prepared.?.state == .collision) {
            try emitTailscaleDiagnostic(io, allocator, prepared.?, options.json);
            return error.TailscaleServeConflict;
        }
        if (prepared.?.state == .available) {
            _ = try tailscale.writePendingIntent(io, allocator, resolved.runtime.state_dir, prepared.?);
            mutation_cleanup_armed = true;
        }
        tailscale.apply(allocator, system_runner.runner(), &prepared.?) catch |err| switch (err) {
            error.TailscaleServeChanged => {
                mutation_cleanup_armed = false;
                std.log.warn("preserved Tailscale intent after CAS conflict", .{});
                return err;
            },
            else => return err,
        };
        try tailscale.writeIntent(io, allocator, resolved.runtime.state_dir, prepared.?);
        managed.runtime.trusted_proxy_origin = prepared.?.origin;
    }
    try runInit(io, allocator, managed);
    try service.install(io, allocator, managed.artifacts, managed.runtime, VERSION);
    try activateServices(io, allocator, managed.runtime.unit_dir, options.no_start);
    installed = true;
    try writeStdout(io, "Installed Verde user services in {s}\nArtifacts: {s}\n", .{ resolved.runtime.unit_dir, std.fs.path.dirname(std.fs.path.dirname(resolved.artifacts.server).?).? });
    if (builtin.os.tag == .linux) try printLingerGuidance(io, allocator);
}

fn activateServices(io: std.Io, allocator: std.mem.Allocator, unit_dir: []const u8, no_start: bool) !void {
    if (builtin.os.tag == .linux) {
        var system_runner: tailscale.SystemRunner = .{ .io = io };
        try activateLinuxServices(allocator, system_runner.runner(), no_start);
        return;
    }
    if (builtin.os.tag != .macos or no_start) return;
    const uid = try std.fmt.allocPrint(allocator, "gui/{d}", .{std.c.geteuid()});
    defer allocator.free(uid);
    const daemon_plist = try std.fs.path.join(allocator, &.{ unit_dir, service.PLIST_DAEMON });
    defer allocator.free(daemon_plist);
    const web_plist = try std.fs.path.join(allocator, &.{ unit_dir, service.PLIST_WEB });
    defer allocator.free(web_plist);
    _ = runInherited(io, allocator, &.{ "launchctl", "bootout", uid, web_plist }) catch {};
    _ = runInherited(io, allocator, &.{ "launchctl", "bootout", uid, daemon_plist }) catch {};
    if (try runInherited(io, allocator, &.{ "launchctl", "bootstrap", uid, daemon_plist }) != 0) return error.LaunchctlFailed;
    if (try runInherited(io, allocator, &.{ "launchctl", "bootstrap", uid, web_plist }) != 0) return error.LaunchctlFailed;
}

fn activateLinuxServices(allocator: std.mem.Allocator, runner: tailscale.Runner, no_start: bool) !void {
    try runChecked(allocator, runner, &.{ "systemctl", "--user", "daemon-reload" });
    if (no_start) return;
    // `enable --now` does not restart an already-running unit after its file is
    // replaced. Enable first, then restart the exact pair; restart also starts
    // inactive units and deterministically loads the new gateway argv.
    try runChecked(allocator, runner, &.{
        "systemctl", "--user", "enable", service.UNIT_DAEMON, service.UNIT_WEB,
    });
    try runChecked(allocator, runner, &.{
        "systemctl", "--user", "restart", service.UNIT_DAEMON, service.UNIT_WEB,
    });
}

fn runChecked(allocator: std.mem.Allocator, runner: tailscale.Runner, argv: []const []const u8) !void {
    var result = try runner.run(allocator, argv);
    defer result.deinit(allocator);
    if (result.code != 0) return error.SystemctlFailed;
}

fn serviceStatus(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, json: bool) !void {
    const daemon_active = try serviceActive(io, allocator, service.UNIT_DAEMON, service.LAUNCHD_DAEMON);
    const web_active = try serviceActive(io, allocator, service.UNIT_WEB, service.LAUNCHD_WEB);
    const gateway_ok = gatewayReachable(io, resolved.runtime.gateway_port);
    if (json) {
        try writeStdout(io, "{{\"ok\":{},\"daemon_unit_active\":{},\"web_unit_active\":{},\"gateway_ok\":{},\"endpoint\":\"http://127.0.0.1:{d}\"}}\n", .{
            daemon_active and web_active and gateway_ok, daemon_active, web_active, gateway_ok, resolved.runtime.gateway_port,
        });
    } else {
        try writeStdout(io, "{s}: {s}\n{s}: {s}\nGateway: {s} at http://127.0.0.1:{d}\n", .{
            service.UNIT_DAEMON,                            if (daemon_active) "active" else "inactive",
            service.UNIT_WEB,                               if (web_active) "active" else "inactive",
            if (gateway_ok) "reachable" else "unreachable", resolved.runtime.gateway_port,
        });
        if (builtin.os.tag == .linux) try printLingerGuidance(io, allocator);
    }
    if (!daemon_active or !web_active or !gateway_ok) return error.Unhealthy;
}

fn serviceUpdate(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved) !void {
    var parsed = service.readState(io, allocator, resolved.runtime.state_dir) catch |err| switch (err) {
        error.FileNotFound => return error.ServiceNotInstalled,
        else => return err,
    };
    defer parsed.deinit();
    const root = std.fs.path.dirname(std.fs.path.dirname(resolved.artifacts.server).?).?;
    try service.requireVerifiedCandidate(parsed.value, VERSION, root);
    try writeStdout(io, "verde-server {s} is already the active verified release at {s}\n", .{ VERSION, root });
}

fn serviceUninstall(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved) !void {
    var lifecycle_lock = try tailscale.LifecycleLock.acquire(io, resolved.runtime.state_dir);
    defer lifecycle_lock.deinit(io);
    if (builtin.os.tag == .linux) {
        _ = runInherited(io, allocator, &.{ "systemctl", "--user", "disable", "--now", service.UNIT_WEB, service.UNIT_DAEMON }) catch {};
    } else if (builtin.os.tag == .macos) {
        const uid = try std.fmt.allocPrint(allocator, "gui/{d}", .{std.c.geteuid()});
        defer allocator.free(uid);
        const web_target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ uid, service.LAUNCHD_WEB });
        defer allocator.free(web_target);
        const daemon_target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ uid, service.LAUNCHD_DAEMON });
        defer allocator.free(daemon_target);
        _ = runInherited(io, allocator, &.{ "launchctl", "bootout", web_target }) catch {};
        _ = runInherited(io, allocator, &.{ "launchctl", "bootout", daemon_target }) catch {};
    }
    try service.uninstall(io, resolved.runtime);
    if (builtin.os.tag == .linux) try runSystemctl(io, allocator, &.{"daemon-reload"});
    var system_runner: tailscale.SystemRunner = .{ .io = io };
    const cleanup = tailscale.cleanupSaved(io, allocator, system_runner.runner(), resolved.runtime.state_dir) catch |err| {
        try writeStderr(
            io,
            "error: preserved Tailscale ownership intent because cleanup failed: {s}\n",
            .{@errorName(err)},
        );
        return err;
    };
    switch (cleanup) {
        .removed, .missing => try tailscale.removeIntent(io, resolved.runtime.state_dir),
        .preserved_changed => {
            try writeStderr(io, "error: preserved Tailscale ownership intent because the listener no longer exactly matches Verde's saved mapping\n", .{});
            return error.TailscaleServeCleanupPreserved;
        },
        .not_owned => try writeStderr(
            io,
            "warning: retained non-owning Tailscale intent; no listener was removed\n",
            .{},
        ),
    }
    try writeStdout(io, "Removed Verde user services. Runtime data, token, credentials, and release metadata were retained.\n", .{});
}

fn protectFailedTailscaleMutation(
    io: std.Io,
    allocator: std.mem.Allocator,
    runner: tailscale.Runner,
    state_dir: []const u8,
    prepared: tailscale.Prepared,
) void {
    const cleanup = tailscale.rollbackExact(
        allocator,
        runner,
        prepared.origin,
        prepared.target,
        prepared.https_port,
        prepared.owned_etag,
    ) catch |err| {
        std.log.err(
            "preserved Tailscale ownership intent because rollback failed: {s}",
            .{@errorName(err)},
        );
        return;
    };
    switch (cleanup) {
        .removed, .missing => {
            tailscale.removeIntent(io, state_dir) catch |err| {
                std.log.err("preserved Tailscale intent because local cleanup failed: {s}", .{@errorName(err)});
                return;
            };
        },
        .preserved_changed => std.log.err(
            "preserved Tailscale ownership intent because rollback found changed configuration",
            .{},
        ),
        .not_owned => std.log.err(
            "preserved non-owning Tailscale intent during failed setup",
            .{},
        ),
    }
}

fn runSystemctl(io: std.Io, allocator: std.mem.Allocator, tail: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "systemctl", "--user" });
    try args.appendSlice(allocator, tail);
    if (try runInherited(io, allocator, args.items) != 0) return error.SystemctlFailed;
}

fn systemctlActive(io: std.Io, allocator: std.mem.Allocator, unit: []const u8) !bool {
    return try runInherited(io, allocator, &.{ "systemctl", "--user", "is-active", "--quiet", unit }) == 0;
}

fn serviceActive(io: std.Io, allocator: std.mem.Allocator, systemd_unit: []const u8, launchd_label: []const u8) !bool {
    if (builtin.os.tag == .linux) return systemctlActive(io, allocator, systemd_unit);
    if (builtin.os.tag == .macos) {
        const target = try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ std.c.geteuid(), launchd_label });
        defer allocator.free(target);
        return try runInherited(io, allocator, &.{ "launchctl", "print", target }) == 0;
    }
    return error.UnsupportedPlatform;
}

fn printLingerGuidance(io: std.Io, allocator: std.mem.Allocator) !void {
    const uid = if (@import("builtin").os.tag == .windows) "" else try std.fmt.allocPrint(allocator, "{d}", .{std.c.geteuid()});
    defer if (uid.len > 0) allocator.free(uid);
    if (uid.len == 0) return;
    const result = runCaptured(allocator, io, &.{ "loginctl", "show-user", uid, "--property=Linger", "--value" }) catch {
        try writeStdout(io, "Lingering: unknown. Ask an administrator about `loginctl enable-linger` if boot-before-login is required.\n", .{});
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const enabled = std.mem.eql(u8, std.mem.trim(u8, result.stdout, &std.ascii.whitespace), "yes");
    try writeStdout(io, "Lingering: {s}. Verde never changes this privilege policy automatically.\n", .{if (enabled) "enabled" else "disabled"});
}

fn gatewayReachable(io: std.Io, port: u16) bool {
    var address = std.Io.net.IpAddress.parseLiteral("127.0.0.1") catch return false;
    address.setPort(port);
    const stream = address.connect(io, .{
        .mode = .stream,
        .timeout = .none,
    }) catch return false;
    stream.close(io);
    return true;
}

fn runInherited(io: std.Io, _: std.mem.Allocator, argv: []const []const u8) !u8 {
    var child = try std.process.spawn(io, .{ .argv = argv });
    return termExitCode(try child.wait(io));
}

fn runCaptured(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(256 * 1024) });
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn jsonOk(allocator: std.mem.Allocator, encoded: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, encoded, .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const value = object.get("ok") orelse return false;
    return switch (value) {
        .bool => |ok| ok,
        else => false,
    };
}

fn printHelp(io: std.Io) !void {
    try writeStdout(io,
        \\verde-server — account-free Verde runtime operator
        \\
        \\Usage:
        \\  verde-server init [--data-dir PATH] [--token-file PATH]
        \\  verde-server serve [--tailscale] [--tailscale-https-port PORT] [--data-dir PATH] [--token-file PATH] [--gateway-port PORT]
        \\  verde-server status [--json]
        \\  verde-server tailscale doctor|status [--tailscale-https-port PORT] [--json]
        \\  verde-server pair create|list|revoke [daemon pair options]
        \\  verde-server device list|revoke [daemon device options]
        \\  verde-server connect [--headless] [--install-service]
        \\  verde-server connect status|unlink|logout [--json]
        \\  verde-server service install [--tailscale] [--tailscale-https-port PORT] [--no-start]
        \\  verde-server service status [--json]
        \\  verde-server service update
        \\  verde-server service uninstall
        \\  verde-server version
        \\
        \\All paths passed to services are absolute. Pair/device operations delegate
        \\to the owner-only daemon transport. Raw tokens are never accepted in argv.
        \\The production gateway port defaults to 7420. `serve --tailscale`
        \\keeps verde-web on loopback, installs the user service, and configures
        \\only the requested unoccupied Tailscale HTTPS listener. It never replaces
        \\another route. Use `tailscale doctor --json` before setup or select a
        \\dedicated listener with `--tailscale-https-port`; Pair uses that exact URL.
        \\`connect` discovers its saved or environment-configured control plane,
        \\uses OIDC device authorization, and removes the provider bearer after
        \\linking. --control-plane, --descriptor-file, and --credential-file are
        \\advanced/testing overrides.
        \\
    , .{});
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArguments, error.UnknownCommand => "invalid command or options; run `verde-server help`",
        error.PathMustBeAbsolute => "service and runtime paths must be absolute",
        error.UnsafeSystemdPath => "systemd service paths cannot contain whitespace or control characters",
        error.InsecureTokenFilePermissions => "gateway token file must be owner-only",
        error.TokenFileSymlink => "gateway token file must not be a symlink",
        error.ServiceNotInstalled => "service is not installed; run `verde-server service install`",
        error.UpdateRolledBack => "candidate failed health checks and the previous release was restored",
        error.UpdateRollbackFailed => "candidate failed and automatic rollback also failed; inspect systemd-user units",
        error.UnverifiedCandidate => "no Verde-verified update candidate is available; refusing supplied URLs, versions, and replacement directories",
        error.Unhealthy => "one or more runtime components are unhealthy",
        error.TailscaleCliMissing, error.TailscaleCliUnavailable => "the `tailscale` CLI is required and must be executable",
        error.TailscaleNotRunning, error.TailscaleNotLoggedIn => "Tailscale must be running and logged in on this device",
        error.TailscaleServeConflict => "the requested Tailscale Serve listener is occupied; Verde made no change (see the diagnostic above)",
        error.TailscaleServeChanged => "Tailscale Serve changed concurrently; Verde's compare-and-set made no change",
        error.TailscaleServeCasUnavailable => "Tailscale's local compare-and-set API is unavailable; Verde refused to mutate Serve configuration",
        error.TailscaleLifecycleLockFailed => "the Tailscale lifecycle lock could not be acquired; Verde refused to change services, Serve configuration, or ownership intent",
        error.TailscaleServePostwriteUnverified => "Tailscale accepted the Serve update, but its resulting version could not be verified; Verde preserved recovery intent and will not claim or automatically remove it",
        error.TailscaleServeCleanupPreserved => "Tailscale cleanup was not exact; the listener and recoverable ownership intent were preserved",
        error.TailscaleIntentConflict => "a different Tailscale ownership intent already exists; Verde preserved it and refused to mutate Serve configuration",
        error.ConnectControlPlaneRequired => "no Connect control plane is configured; set VERDE_CONNECT_CONTROL_PLANE or pass --control-plane URL",
        error.ConnectDescriptorUnavailable => "no runtime descriptor could be derived; configure Tailscale Serve first or use advanced --descriptor-file PATH",
        error.ConnectDeviceFlowUnavailable => "the configured OIDC provider does not advertise RFC 8628 device authorization",
        error.OidcRequestTimedOut => "the OIDC or control-plane HTTPS request timed out",
        error.PublicGatewayStartupTimedOut => "the public Tailscale HTTPS runtime endpoint did not become ready in time",
        else => @errorName(err),
    };
}

fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidArguments, error.UnknownCommand => 2,
        error.Unhealthy, error.ChildFailed, error.DaemonCommandFailed, error.SystemctlFailed, error.TailscaleServeConflict => 3,
        else => 4,
    };
}

fn writeStdout(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print(fmt, args);
}

fn writeStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print(fmt, args);
}

fn writeSensitiveStdout(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print(fmt, args);
}

test {
    std.testing.refAllDecls(@This());
    _ = config;
    _ = service;
    _ = supervisor;
    _ = tailscale;
    _ = oidc;
}

test "status requires semantic JSON ok" {
    try std.testing.expect(jsonOk(std.testing.allocator, "{\"ok\":true}"));
    try std.testing.expect(!jsonOk(std.testing.allocator, "{\"ok\":false}"));
    try std.testing.expect(!jsonOk(std.testing.allocator, "[]"));
    try std.testing.expect(!jsonOk(std.testing.allocator, "not-json"));
}

test "Pair URL keeps the one-time code in the fragment" {
    const url = try pairUrlAlloc(
        std.testing.allocator,
        "https://runtime.tail.ts.net",
        "0123456789abcdef0123456789abcdef",
        "ab" ** 32,
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "verde://pair?host=https%3A%2F%2Fruntime.tail.ts.net&grant_id=0123456789abcdef0123456789abcdef#code=" ++ "ab" ** 32,
        url,
    );
    const query_end = std.mem.indexOfScalar(u8, url, '#').?;
    try std.testing.expect(std.mem.indexOf(u8, url[0..query_end], "ab" ** 8) == null);
}

test "Pair URL preserves a dedicated Tailscale HTTPS port" {
    const url = try pairUrlAlloc(
        std.testing.allocator,
        "https://runtime.tail.ts.net:8443",
        "0123456789abcdef0123456789abcdef",
        "cd" ** 32,
    );
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(
        u8,
        url,
        "verde://pair?host=https%3A%2F%2Fruntime.tail.ts.net%3A8443&grant_id=",
    ));
    const fragment = std.mem.indexOfScalar(u8, url, '#').?;
    try std.testing.expect(std.mem.indexOf(u8, url[0..fragment], "cd" ** 8) == null);
}

test "Linux activation reloads enables and restarts exact units" {
    var fake: ActivationFake = .{};
    defer fake.deinit();
    try activateLinuxServices(std.testing.allocator, fake.runner(), false);
    try std.testing.expectEqual(@as(usize, 3), fake.calls.items.len);
    try std.testing.expectEqualStrings("systemctl\x1f--user\x1fdaemon-reload", fake.calls.items[0]);
    try std.testing.expectEqualStrings(
        "systemctl\x1f--user\x1fenable\x1fverde-daemon.service\x1fverde-web.service",
        fake.calls.items[1],
    );
    try std.testing.expectEqualStrings(
        "systemctl\x1f--user\x1frestart\x1fverde-daemon.service\x1fverde-web.service",
        fake.calls.items[2],
    );
}

test "Linux no-start activation only reloads units" {
    var fake: ActivationFake = .{};
    defer fake.deinit();
    try activateLinuxServices(std.testing.allocator, fake.runner(), true);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try std.testing.expectEqualStrings("systemctl\x1f--user\x1fdaemon-reload", fake.calls.items[0]);
}

test "public readiness requires the frozen runtime metadata" {
    const origin = "https://runtime.tail.ts.net";
    const valid =
        \\{"access_protocol_version":1,"runtime_id":"0123456789abcdef0123456789abcdef","instance_id":"00112233445566778899aabbccddeeff","https_url":"https://runtime.tail.ts.net","wss_url":"wss://runtime.tail.ts.net/ws","capabilities":["access.pair.v1"]}
    ;
    try std.testing.expect(runtimeMetadataMatches(std.testing.allocator, valid, origin));
    try std.testing.expect(!runtimeMetadataMatches(std.testing.allocator, valid, "https://other.tail.ts.net"));
    try std.testing.expect(!runtimeMetadataMatches(std.testing.allocator,
        \\{"access_protocol_version":1,"runtime_id":"0123456789abcdef0123456789abcdef","instance_id":"00112233445566778899aabbccddeeff","https_url":"https://runtime.tail.ts.net","wss_url":"wss://runtime.tail.ts.net/ws","capabilities":[]}
    , origin));
}

const ActivationFake = struct {
    calls: std.ArrayList([]u8) = .empty,

    fn runner(self: *ActivationFake) tailscale.Runner {
        return .{ .context = self, .run_fn = fakeRun };
    }

    fn deinit(self: *ActivationFake) void {
        for (self.calls.items) |call| std.testing.allocator.free(call);
        self.calls.deinit(std.testing.allocator);
    }

    fn fakeRun(context: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8) !tailscale.CommandResult {
        const self: *ActivationFake = @ptrCast(@alignCast(context));
        const joined = try std.mem.join(allocator, "\x1f", argv);
        try self.calls.append(std.testing.allocator, joined);
        return .{
            .code = 0,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, ""),
        };
    }
};
