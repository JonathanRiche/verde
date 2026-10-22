//! Desktop Remote access: one loopback `verde-web` user service in front of
//! the desktop app's own data directory (`~/.local/share/verde/Native`), so
//! paired phones and computers see the chats of the desktop they use. The
//! desktop daemon is owned by the app, so no daemon unit is installed.
//!
//! Never two gateways for one data dir or one port: an existing `verde-web`
//! service for this data dir (including a hand-installed
//! `verde-web-desktop.service`) is adopted and replaced in place, and any
//! other process on the gateway port is reported instead of competing.

const std = @import("std");
const builtin = @import("builtin");

const service = @import("service.zig");
const tailscale = @import("tailscale.zig");

pub const DEFAULT_UNIT = "verde-web-desktop.service";
pub const LAUNCHD_LABEL = "dev.verde.desktop.web";
pub const PLIST = LAUNCHD_LABEL ++ ".plist";
/// The documented bundled-SPA gateway port, distinct from the standalone
/// runtime gateway (7420) so the two can coexist.
pub const DEFAULT_GATEWAY_PORT: u16 = 6783;
/// `verde-web`'s own default when a unit omits `--port`.
const WEB_DEFAULT_PORT: u16 = 7420;
pub const STATE_FILE = "desktop-gateway.json";
const MAX_UNIT_BYTES: usize = 64 * 1024;

/// Gateway flags read from an ExecStart line or a process command line.
pub const WebArgs = struct {
    port: u16 = WEB_DEFAULT_PORT,
    pref_path: ?[]const u8 = null,
    token_file: ?[]const u8 = null,
};

/// Null unless argv runs `verde-web`.
pub fn parseWebArgs(argv: []const []const u8) ?WebArgs {
    if (argv.len == 0 or !std.mem.eql(u8, std.fs.path.basename(argv[0]), "verde-web")) return null;
    var args: WebArgs = .{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        const value = flagValue(argv, &index, arg, "--port") orelse
            flagValue(argv, &index, arg, "--pref-path") orelse
            flagValue(argv, &index, arg, "--token-file") orelse continue;
        if (std.mem.startsWith(u8, arg, "--port")) {
            args.port = std.fmt.parseInt(u16, value, 10) catch return null;
        } else if (std.mem.startsWith(u8, arg, "--pref-path")) {
            args.pref_path = value;
        } else {
            args.token_file = value;
        }
    }
    return args;
}

/// `--flag value` or `--flag=value`.
fn flagValue(argv: []const []const u8, index: *usize, arg: []const u8, comptime flag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, flag)) {
        if (index.* + 1 >= argv.len) return null;
        index.* += 1;
        return argv[index.*];
    }
    if (std.mem.startsWith(u8, arg, flag ++ "=")) return arg[flag.len + 1 ..];
    return null;
}

/// Splits the last `ExecStart=` of a unit (later lines override earlier
/// ones, as in drop-ins). Systemd prefixes (`-`, `@`, `!`, `+`, `:`) are
/// dropped; Verde never writes quoted arguments.
pub fn execStartArgv(allocator: std.mem.Allocator, unit_text: []const u8) !?[][]const u8 {
    var exec: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, unit_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (!std.mem.startsWith(u8, line, "ExecStart=")) continue;
        const value = std.mem.trim(u8, line["ExecStart=".len..], &std.ascii.whitespace);
        exec = if (value.len == 0) null else value;
    }
    const command = std.mem.trimStart(u8, exec orelse return null, "-@!+:");
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    var parts = std.mem.tokenizeAny(u8, command, " \t");
    while (parts.next()) |part| try argv.append(allocator, std.mem.trim(u8, part, "\"'"));
    return try argv.toOwnedSlice(allocator);
}

/// The systemd unit that owns a process, from `/proc/<pid>/cgroup`. Scopes
/// (terminal sessions, app launches) are not services and cannot be adopted.
pub fn unitFromCgroup(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const path_start = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
        const leaf = std.fs.path.basename(std.mem.trim(u8, line[path_start + 1 ..], &std.ascii.whitespace));
        if (!std.mem.endsWith(u8, leaf, ".service")) continue;
        // `user@UID.service` is the user manager itself, not a gateway unit.
        if (std.mem.startsWith(u8, leaf, "user@")) continue;
        return leaf;
    }
    return null;
}

pub const Owner = struct { pid: u32, name: []const u8 };

/// Listener owner from `ss -H -ltnp 'sport = :PORT'`, e.g.
/// `LISTEN 0 4096 127.0.0.1:6783 0.0.0.0:* users:(("verde-web",pid=1234,fd=3))`.
pub fn parseSsOwner(output: []const u8) ?Owner {
    const users = std.mem.indexOf(u8, output, "users:((\"") orelse return null;
    const name_start = users + "users:((\"".len;
    const name_end = std.mem.indexOfScalarPos(u8, output, name_start, '"') orelse return null;
    const pid_key = std.mem.indexOfPos(u8, output, name_end, "pid=") orelse return null;
    var pid_end = pid_key + "pid=".len;
    while (pid_end < output.len and std.ascii.isDigit(output[pid_end])) pid_end += 1;
    const pid = std.fmt.parseInt(u32, output[pid_key + "pid=".len .. pid_end], 10) catch return null;
    return .{ .pid = pid, .name = output[name_start..name_end] };
}

/// A `verde-web` service found in the user unit directory.
pub const Candidate = struct { unit: []const u8, args: WebArgs };

pub const Selection = struct {
    unit: []const u8 = DEFAULT_UNIT,
    port: u16 = DEFAULT_GATEWAY_PORT,
    token_file: ?[]const u8 = null,
    /// An existing gateway service for this data dir is being replaced in place.
    adopted: bool = false,
    /// Further services for this data dir; disabled so only one gateway remains.
    retire: []const []const u8 = &.{},
};

/// Keeps the existing gateway service for this data dir (its unit name, port
/// and token) when there is one, preferring Verde's own unit name.
pub fn selectUnit(allocator: std.mem.Allocator, data_dir: []const u8, default_data_dir: []const u8, candidates: []const Candidate) !Selection {
    var chosen: ?Candidate = null;
    for (candidates) |candidate| {
        if (!servesDataDir(candidate.args, data_dir, default_data_dir)) continue;
        if (chosen == null or std.mem.eql(u8, candidate.unit, DEFAULT_UNIT)) chosen = candidate;
    }
    const keep = chosen orelse return .{};
    var retire: std.ArrayList([]const u8) = .empty;
    errdefer retire.deinit(allocator);
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.unit, keep.unit)) continue;
        if (servesDataDir(candidate.args, data_dir, default_data_dir)) try retire.append(allocator, candidate.unit);
    }
    return .{
        .unit = keep.unit,
        .port = keep.args.port,
        .token_file = keep.args.token_file,
        .adopted = true,
        .retire = try retire.toOwnedSlice(allocator),
    };
}

pub fn servesDataDir(args: WebArgs, data_dir: []const u8, default_data_dir: []const u8) bool {
    const pref = args.pref_path orelse default_data_dir;
    return std.mem.eql(u8, std.mem.trimEnd(u8, pref, "/"), std.mem.trimEnd(u8, data_dir, "/"));
}

/// What is listening on the chosen gateway port.
pub const Listener = struct {
    /// Null when the owner could not be identified (another user, no `ss`).
    process: ?Process = null,

    pub const Process = struct {
        name: []const u8,
        /// Parsed when the process is `verde-web`.
        args: ?WebArgs = null,
        /// Service owning the process, when it runs under one.
        unit: ?[]const u8 = null,
    };
};

pub const BlockCode = enum { gateway_port_in_use, gateway_unmanaged };

pub const Verdict = union(enum) {
    /// Port free: install the selected unit.
    free,
    /// Our gateway already listens there under this unit; restart it in place.
    adopt: []const u8,
    blocked: struct { code: BlockCode, process: ?[]const u8 },
};

/// Decides whether the selected port can be used without a second gateway.
pub fn listenerVerdict(data_dir: []const u8, default_data_dir: []const u8, listener: ?Listener) Verdict {
    const found = listener orelse return .free;
    const process = found.process orelse return .{ .blocked = .{ .code = .gateway_port_in_use, .process = null } };
    const args = process.args orelse return .{ .blocked = .{ .code = .gateway_port_in_use, .process = process.name } };
    // A Verde gateway for another data dir (the standalone runtime, say)
    // must keep its port; replacing it would cut that runtime off.
    if (!servesDataDir(args, data_dir, default_data_dir)) return .{ .blocked = .{ .code = .gateway_port_in_use, .process = process.name } };
    const unit = process.unit orelse return .{ .blocked = .{ .code = .gateway_unmanaged, .process = process.name } };
    return .{ .adopt = unit };
}

pub fn unitAlloc(
    allocator: std.mem.Allocator,
    artifacts: service.ArtifactPaths,
    data_dir: []const u8,
    token_file: []const u8,
    port: u16,
    origin: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[Unit]
        \\Description=Verde desktop Remote access gateway
        \\Documentation=https://verdeai.dev/docs/remote-access
        \\
        \\[Service]
        \\Type=simple
        \\UMask=0077
        \\UnsetEnvironment=VERDE_SESSIONIZER_SOCKET VERDE_WEB_TOKEN
        \\ExecStart={s} --static {s} --host 127.0.0.1 --port {d} --token-file {s} --pref-path {s} --trusted-proxy-origin {s}
        \\Restart=on-failure
        \\RestartSec=2s
        \\NoNewPrivileges=true
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{ artifacts.web, artifacts.static_dir, port, token_file, data_dir, origin });
}

/// Release record read by the desktop's version sync. Field names match
/// `service.ReleaseState` so one reader handles both modes.
pub const State = struct {
    schema_version: u32 = 1,
    unit: []const u8,
    gateway_port: u16,
    data_dir: []const u8,
    token_file: []const u8,
    active_version: []const u8,
    active_root: []const u8,
};

pub fn readState(io: std.Io, allocator: std.mem.Allocator, state_dir: []const u8) !std.json.Parsed(State) {
    const dir = try std.Io.Dir.openDirAbsolute(io, state_dir, .{});
    defer dir.close(io);
    const encoded = try dir.readFileAlloc(io, STATE_FILE, allocator, .limited(64 * 1024));
    defer allocator.free(encoded);
    return std.json.parseFromSlice(State, allocator, encoded, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

pub fn writeState(io: std.Io, allocator: std.mem.Allocator, state_dir: []const u8, state: State) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, state, .{});
    defer allocator.free(encoded);
    try service.writeAtomic(io, state_dir, STATE_FILE, encoded, 0o600);
}

// ---- machine probes (system calls go through the injectable runner) --------

/// Every `verde-web` service in the user unit directory.
pub fn scanUnits(io: std.Io, allocator: std.mem.Allocator, unit_dir: []const u8) ![]Candidate {
    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer candidates.deinit(allocator);
    var dir = std.Io.Dir.openDirAbsolute(io, unit_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return candidates.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".service")) continue;
        const text = dir.readFileAlloc(io, entry.name, allocator, .limited(MAX_UNIT_BYTES)) catch continue;
        const argv = (execStartArgv(allocator, text) catch continue) orelse continue;
        const args = parseWebArgs(argv) orelse continue;
        try candidates.append(allocator, .{ .unit = try allocator.dupe(u8, entry.name), .args = args });
    }
    return candidates.toOwnedSlice(allocator);
}

/// Identifies the process listening on 127.0.0.1:`port`, or null when the
/// port is free. Linux uses `ss` plus `/proc`; elsewhere an occupied port is
/// reported without an owner (never adopted).
pub fn probeListener(io: std.Io, allocator: std.mem.Allocator, runner: tailscale.Runner, port: u16) !?Listener {
    if (!portOccupied(io, port)) return null;
    if (builtin.os.tag != .linux) return .{};
    const filter = try std.fmt.allocPrint(allocator, "sport = :{d}", .{port});
    var result = runner.run(allocator, &.{ "ss", "-H", "-ltnp", filter }) catch return .{};
    defer result.deinit(allocator);
    if (result.code != 0) return .{};
    const owner = parseSsOwner(result.stdout) orelse return .{};
    var process: Listener.Process = .{ .name = try allocator.dupe(u8, owner.name) };
    var path_buffer: [64]u8 = undefined;
    const cmdline_path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/cmdline", .{owner.pid});
    if (std.Io.Dir.cwd().readFileAlloc(io, cmdline_path, allocator, .limited(64 * 1024))) |cmdline| {
        var argv: std.ArrayList([]const u8) = .empty;
        var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cmdline, "\x00"), 0);
        while (parts.next()) |part| try argv.append(allocator, part);
        process.args = parseWebArgs(argv.items);
    } else |_| {}
    const cgroup_path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/cgroup", .{owner.pid});
    if (std.Io.Dir.cwd().readFileAlloc(io, cgroup_path, allocator, .limited(16 * 1024))) |cgroup| {
        if (unitFromCgroup(cgroup)) |unit| process.unit = try allocator.dupe(u8, unit);
    } else |_| {}
    return .{ .process = process };
}

fn portOccupied(io: std.Io, port: u16) bool {
    var address = std.Io.net.IpAddress.parseLiteral("127.0.0.1") catch return false;
    address.setPort(port);
    const stream = address.connect(io, .{ .mode = .stream, .timeout = .none }) catch return false;
    stream.close(io);
    return true;
}

/// Default desktop data dir, matching `verde-web` and the desktop app.
pub fn defaultDataDirAlloc(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| {
        const trimmed = std.mem.trim(u8, xdg, &std.ascii.whitespace);
        if (trimmed.len > 0) return std.fs.path.join(allocator, &.{ trimmed, "verde", "Native" });
    }
    const home = env.get("HOME") orelse return error.HomeUnavailable;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "verde", "Native" });
}

/// `<verde data root>/web/token`, beside the desktop data dir, as in the
/// documented hand-installed gateway.
pub fn defaultTokenFileAlloc(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    const root = std.fs.path.dirname(std.mem.trimEnd(u8, data_dir, "/")) orelse return error.InvalidArtifactLayout;
    return std.fs.path.join(allocator, &.{ root, "web", "token" });
}

// ---- tests --------------------------------------------------------------------

test "ExecStart and command lines yield verde-web flags" {
    const unit =
        \\[Service]
        \\ExecStart=/opt/verde/bin/verde-daemon serve
        \\ExecStart=-/home/u/bin/verde-web --static /home/u/dist --host 127.0.0.1 --port 6783 --token-file /home/u/.local/share/verde/web/token --pref-path /home/u/.local/share/verde/Native --trusted-proxy-origin https://box.ts.net
    ;
    const argv = (try execStartArgv(std.testing.allocator, unit)).?;
    defer std.testing.allocator.free(argv);
    const args = parseWebArgs(argv).?;
    try std.testing.expectEqual(@as(u16, 6783), args.port);
    try std.testing.expectEqualStrings("/home/u/.local/share/verde/Native", args.pref_path.?);
    try std.testing.expectEqualStrings("/home/u/.local/share/verde/web/token", args.token_file.?);
    try std.testing.expect(parseWebArgs(&.{ "/opt/verde/bin/verde-daemon", "serve" }) == null);
    const defaults = parseWebArgs(&.{ "verde-web", "--port=7000" }).?;
    try std.testing.expectEqual(@as(u16, 7000), defaults.port);
    try std.testing.expect(defaults.pref_path == null);
}

test "listener owner and owning service come from ss and cgroup" {
    const owner = parseSsOwner("LISTEN 0 4096 127.0.0.1:6783 0.0.0.0:* users:((\"verde-web\",pid=4242,fd=3))\n").?;
    try std.testing.expectEqual(@as(u32, 4242), owner.pid);
    try std.testing.expectEqualStrings("verde-web", owner.name);
    try std.testing.expect(parseSsOwner("LISTEN 0 4096 127.0.0.1:6783 0.0.0.0:*\n") == null);
    try std.testing.expectEqualStrings("verde-web-desktop.service", unitFromCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/verde-web-desktop.service\n").?);
    // A gateway started from a terminal lives in a scope, not a service.
    try std.testing.expect(unitFromCgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-foot-1234.scope\n") == null);
    try std.testing.expect(unitFromCgroup("0::/user.slice/user-1000.slice/user@1000.service\n") == null);
}

test "an existing gateway service for this data dir is adopted, others are left alone" {
    const native = "/home/u/.local/share/verde/Native";
    const candidates = [_]Candidate{
        .{ .unit = "verde-web.service", .args = .{ .port = 7420, .pref_path = "/home/u/.local/share/verde/runtime" } },
        .{ .unit = "my-gateway.service", .args = .{ .port = 6790, .pref_path = native ++ "/" } },
        .{ .unit = DEFAULT_UNIT, .args = .{ .port = 6783, .pref_path = native, .token_file = "/home/u/.local/share/verde/web/token" } },
    };
    const selection = try selectUnit(std.testing.allocator, native, native, &candidates);
    defer std.testing.allocator.free(selection.retire);
    try std.testing.expect(selection.adopted);
    try std.testing.expectEqualStrings(DEFAULT_UNIT, selection.unit);
    try std.testing.expectEqual(@as(u16, 6783), selection.port);
    try std.testing.expectEqualStrings("/home/u/.local/share/verde/web/token", selection.token_file.?);
    // The duplicate gateway for the same data dir is retired; the standalone
    // runtime's gateway is not.
    try std.testing.expectEqual(@as(usize, 1), selection.retire.len);
    try std.testing.expectEqualStrings("my-gateway.service", selection.retire[0]);

    const fresh = try selectUnit(std.testing.allocator, native, native, candidates[0..1]);
    try std.testing.expect(!fresh.adopted);
    try std.testing.expectEqual(DEFAULT_GATEWAY_PORT, fresh.port);
    // A unit without --pref-path serves verde-web's default, the desktop dir.
    const implicit = [_]Candidate{.{ .unit = "hand.service", .args = .{ .port = 6783 } }};
    const adopted = try selectUnit(std.testing.allocator, native, native, &implicit);
    defer std.testing.allocator.free(adopted.retire);
    try std.testing.expectEqualStrings("hand.service", adopted.unit);
}

test "the gateway port is shared with nothing but our own service" {
    const native = "/home/u/.local/share/verde/Native";
    try std.testing.expectEqual(Verdict.free, listenerVerdict(native, native, null));
    const ours = listenerVerdict(native, native, .{ .process = .{ .name = "verde-web", .args = .{ .port = 6783, .pref_path = native }, .unit = "verde-web-desktop.service" } });
    try std.testing.expectEqualStrings("verde-web-desktop.service", ours.adopt);
    const by_hand = listenerVerdict(native, native, .{ .process = .{ .name = "verde-web", .args = .{ .port = 6783, .pref_path = native } } });
    try std.testing.expectEqual(BlockCode.gateway_unmanaged, by_hand.blocked.code);
    const runtime = listenerVerdict(native, native, .{ .process = .{ .name = "verde-web", .args = .{ .port = 6783, .pref_path = "/srv/runtime" }, .unit = "verde-web.service" } });
    try std.testing.expectEqual(BlockCode.gateway_port_in_use, runtime.blocked.code);
    const vite = listenerVerdict(native, native, .{ .process = .{ .name = "node" } });
    try std.testing.expectEqual(BlockCode.gateway_port_in_use, vite.blocked.code);
    try std.testing.expectEqualStrings("node", vite.blocked.process.?);
    const unknown = listenerVerdict(native, native, .{});
    try std.testing.expect(unknown.blocked.process == null);
}

test "desktop gateway unit serves the desktop data dir without a daemon unit" {
    const unit = try unitAlloc(std.testing.allocator, .{
        .server = "/opt/verde/bin/verde-server",
        .daemon = "/opt/verde/bin/verde-daemon",
        .web = "/opt/verde/bin/verde-web",
        .static_dir = "/opt/verde/share/verde/web",
        .provider_bridge = "/opt/verde/share/verde/provider_bridge.mjs",
    }, "/home/u/.local/share/verde/Native", "/home/u/.local/share/verde/web/token", 6783, "https://box.ts.net");
    defer std.testing.allocator.free(unit);
    try std.testing.expect(std.mem.indexOf(u8, unit, "--pref-path /home/u/.local/share/verde/Native --trusted-proxy-origin https://box.ts.net") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "--host 127.0.0.1 --port 6783") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "verde-daemon") == null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Requires=") == null);
    const token = try defaultTokenFileAlloc(std.testing.allocator, "/home/u/.local/share/verde/Native/");
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("/home/u/.local/share/verde/web/token", token);
}
