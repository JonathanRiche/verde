//! Account-free operator CLI for a standalone Verde runtime.

const std = @import("std");
const build_options = @import("build_options");

const config = @import("config.zig");
const service = @import("service.zig");
const supervisor = @import("supervisor.zig");

const VERSION: []const u8 = build_options.version;

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
        .serve => try runServe(init.io, init.gpa, resolved),
        .status => try runStatus(init.io, init.gpa, resolved, options.json),
        .pair_create, .pair_list, .pair_revoke, .device_list, .device_revoke => try runDelegate(init.io, init.gpa, resolved, options),
        .service_install => try serviceInstall(init.io, init.gpa, resolved, options.no_start),
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
    const unit_dir = try std.fs.path.join(allocator, &.{ config_home, "systemd", "user" });
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

fn runServe(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved) !void {
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
    });
    if (code != 0) return error.ChildFailed;
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

fn serviceInstall(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, no_start: bool) !void {
    try service.install(io, allocator, resolved.artifacts, resolved.runtime, VERSION);
    try runSystemctl(io, allocator, &.{"daemon-reload"});
    if (!no_start) try runSystemctl(io, allocator, &.{ "enable", "--now", service.UNIT_DAEMON, service.UNIT_WEB });
    try writeStdout(io, "Installed systemd-user units in {s}\nArtifacts: {s}\n", .{ resolved.runtime.unit_dir, std.fs.path.dirname(std.fs.path.dirname(resolved.artifacts.server).?).? });
    try printLingerGuidance(io, allocator);
}

fn serviceStatus(io: std.Io, allocator: std.mem.Allocator, resolved: Resolved, json: bool) !void {
    const daemon_active = try systemctlActive(io, allocator, service.UNIT_DAEMON);
    const web_active = try systemctlActive(io, allocator, service.UNIT_WEB);
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
        try printLingerGuidance(io, allocator);
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
    _ = runInherited(io, allocator, &.{ "systemctl", "--user", "disable", "--now", service.UNIT_WEB, service.UNIT_DAEMON }) catch {};
    try service.uninstall(io, resolved.runtime);
    try runSystemctl(io, allocator, &.{"daemon-reload"});
    try writeStdout(io, "Removed Verde systemd-user units. Runtime data, token, credentials, and release metadata were retained.\n", .{});
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
        \\  verde-server serve [--data-dir PATH] [--token-file PATH] [--gateway-port PORT]
        \\  verde-server status [--json]
        \\  verde-server pair create|list|revoke [daemon pair options]
        \\  verde-server device list|revoke [daemon device options]
        \\  verde-server service install [--no-start]
        \\  verde-server service status [--json]
        \\  verde-server service update
        \\  verde-server service uninstall
        \\  verde-server version
        \\
        \\All paths passed to services are absolute. Pair/device operations delegate
        \\to the owner-only daemon transport. Raw tokens are never accepted in argv.
        \\The production gateway port defaults to 7420.
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
        else => @errorName(err),
    };
}

fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidArguments, error.UnknownCommand => 2,
        error.Unhealthy, error.ChildFailed, error.DaemonCommandFailed, error.SystemctlFailed => 3,
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

test {
    std.testing.refAllDecls(@This());
    _ = config;
    _ = service;
    _ = supervisor;
}

test "status requires semantic JSON ok" {
    try std.testing.expect(jsonOk(std.testing.allocator, "{\"ok\":true}"));
    try std.testing.expect(!jsonOk(std.testing.allocator, "{\"ok\":false}"));
    try std.testing.expect(!jsonOk(std.testing.allocator, "[]"));
    try std.testing.expect(!jsonOk(std.testing.allocator, "not-json"));
}
