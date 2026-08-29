//! Linux systemd-user units and version-pinned activation metadata.

const std = @import("std");
const builtin = @import("builtin");

pub const UNIT_DAEMON = "verde-daemon.service";
pub const UNIT_WEB = "verde-web.service";
pub const LAUNCHD_DAEMON = "dev.verde.runtime.daemon";
pub const LAUNCHD_WEB = "dev.verde.runtime.web";
pub const PLIST_DAEMON = LAUNCHD_DAEMON ++ ".plist";
pub const PLIST_WEB = LAUNCHD_WEB ++ ".plist";
pub const STATE_FILE = "service-state.json";

pub const ArtifactPaths = struct {
    server: []const u8,
    daemon: []const u8,
    web: []const u8,
    static_dir: []const u8,
    provider_bridge: []const u8,
};

pub const RuntimePaths = struct {
    data_dir: []const u8,
    token_file: []const u8,
    unit_dir: []const u8,
    state_dir: []const u8,
    gateway_port: u16,
    trusted_proxy_origin: ?[]const u8 = null,
};

pub const ReleaseState = struct {
    schema_version: u32 = 1,
    active_version: []const u8,
    active_root: []const u8,
    previous_version: ?[]const u8 = null,
    previous_root: ?[]const u8 = null,
    candidate_version: ?[]const u8 = null,
    candidate_root: ?[]const u8 = null,
};

pub fn validateArtifactPaths(io: std.Io, paths: ArtifactPaths) !void {
    try validateSafeAbsolutePath(paths.server);
    try validateSafeAbsolutePath(paths.daemon);
    try validateSafeAbsolutePath(paths.web);
    try validateSafeAbsolutePath(paths.static_dir);
    try validateSafeAbsolutePath(paths.provider_bridge);
    try requireFile(io, paths.server, true);
    try requireFile(io, paths.daemon, true);
    try requireFile(io, paths.web, true);
    try requireFile(io, paths.provider_bridge, false);
    const static_stat = try std.Io.Dir.cwd().statFile(io, paths.static_dir, .{});
    if (static_stat.kind != .directory) return error.NotDir;
}

pub fn validateRuntimePaths(paths: RuntimePaths) !void {
    try validateSafeAbsolutePath(paths.data_dir);
    try validateSafeAbsolutePath(paths.token_file);
    try validateSafeAbsolutePath(paths.unit_dir);
    try validateSafeAbsolutePath(paths.state_dir);
    if (paths.gateway_port == 0) return error.InvalidPort;
    if (paths.trusted_proxy_origin) |origin| {
        if (!std.mem.startsWith(u8, origin, "https://") or std.mem.indexOfAny(u8, origin, "\r\n\t ") != null) {
            return error.InvalidTrustedProxyOrigin;
        }
    }
}

pub fn daemonUnitAlloc(allocator: std.mem.Allocator, artifacts: ArtifactPaths, paths: RuntimePaths) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[Unit]
        \\Description=Verde standalone session daemon
        \\Documentation=https://verdeai.dev/docs/daemon-deployment
        \\
        \\[Service]
        \\Type=simple
        \\UMask=0077
        \\UnsetEnvironment=VERDE_SESSIONIZER_SOCKET VERDE_WEB_TOKEN
        \\ExecStartPre={s} init --data-dir {s}
        \\ExecStart={s} serve --data-dir {s}
        \\Restart=on-failure
        \\RestartSec=2s
        \\KillMode=mixed
        \\TimeoutStopSec=infinity
        \\NoNewPrivileges=true
        \\PrivateTmp=true
        \\ProtectSystem=full
        \\ReadWritePaths={s}
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{ artifacts.daemon, paths.data_dir, artifacts.daemon, paths.data_dir, paths.data_dir });
}

pub fn webUnitAlloc(allocator: std.mem.Allocator, artifacts: ArtifactPaths, paths: RuntimePaths) ![]u8 {
    const proxy_arg = if (paths.trusted_proxy_origin) |origin|
        try std.fmt.allocPrint(allocator, " --trusted-proxy-origin {s}", .{origin})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(proxy_arg);
    return std.fmt.allocPrint(allocator,
        \\[Unit]
        \\Description=Verde authenticated loopback web gateway
        \\Requires=verde-daemon.service
        \\After=verde-daemon.service
        \\
        \\[Service]
        \\Type=simple
        \\UMask=0077
        \\UnsetEnvironment=VERDE_SESSIONIZER_SOCKET VERDE_WEB_TOKEN
        \\ExecStart={s} --host 127.0.0.1 --port {d} --token-file {s} --pref-path {s} --sessionizer {s}/verde-sessionizer.sock --static {s}{s}
        \\Restart=on-failure
        \\RestartSec=2s
        \\NoNewPrivileges=true
        \\PrivateTmp=true
        \\ProtectSystem=strict
        \\ReadOnlyPaths={s}
        \\ReadWritePaths={s}
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{ artifacts.web, paths.gateway_port, paths.token_file, paths.data_dir, paths.data_dir, artifacts.static_dir, proxy_arg, artifacts.static_dir, paths.data_dir });
}

pub fn daemonPlistAlloc(allocator: std.mem.Allocator, artifacts: ArtifactPaths, paths: RuntimePaths) ![]u8 {
    return launchdPlistAlloc(allocator, LAUNCHD_DAEMON, &.{
        artifacts.daemon, "serve", "--data-dir", paths.data_dir,
    });
}

pub fn webPlistAlloc(allocator: std.mem.Allocator, artifacts: ArtifactPaths, paths: RuntimePaths) ![]u8 {
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    var port_buffer: [6]u8 = undefined;
    const port = try std.fmt.bufPrint(&port_buffer, "{d}", .{paths.gateway_port});
    const socket = try std.fmt.allocPrint(allocator, "{s}/verde-sessionizer.sock", .{paths.data_dir});
    defer allocator.free(socket);
    try arguments.appendSlice(allocator, &.{
        artifacts.web, "--host", "127.0.0.1", "--port", port,
        "--token-file", paths.token_file, "--pref-path", paths.data_dir,
        "--sessionizer", socket, "--static", artifacts.static_dir,
    });
    if (paths.trusted_proxy_origin) |origin| try arguments.appendSlice(allocator, &.{ "--trusted-proxy-origin", origin });
    return launchdPlistAlloc(allocator, LAUNCHD_WEB, arguments.items);
}

fn launchdPlistAlloc(allocator: std.mem.Allocator, label: []const u8, arguments: []const []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict>
        \\<key>Label</key><string>
    );
    try writeXml(&output.writer, label);
    try output.writer.writeAll("</string>\n<key>ProgramArguments</key><array>\n");
    for (arguments) |argument| {
        try output.writer.writeAll("<string>");
        try writeXml(&output.writer, argument);
        try output.writer.writeAll("</string>\n");
    }
    try output.writer.writeAll(
        \\</array>
        \\<key>RunAtLoad</key><true/>
        \\<key>KeepAlive</key><true/>
        \\<key>ProcessType</key><string>Background</string>
        \\<key>Umask</key><integer>63</integer>
        \\</dict></plist>
    );
    return output.toOwnedSlice();
}

fn writeXml(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        else => try writer.writeByte(byte),
    };
}

pub fn install(io: std.Io, allocator: std.mem.Allocator, artifacts: ArtifactPaths, paths: RuntimePaths, version: []const u8) !void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    try validateArtifactPaths(io, artifacts);
    try validateRuntimePaths(paths);
    try ensureOwnerOnlyDir(io, paths.unit_dir);
    try ensureOwnerOnlyDir(io, paths.state_dir);
    try ensureOwnerOnlyDir(io, paths.data_dir);
    if (std.fs.path.dirname(paths.token_file)) |parent| try ensureOwnerOnlyDir(io, parent);
    try ensureOwnerOnlyToken(io, paths.token_file);

    if (builtin.os.tag == .linux) {
        try writeUnits(io, allocator, artifacts, paths);
    } else {
        try writePlists(io, allocator, artifacts, paths);
    }

    const root = std.fs.path.dirname(std.fs.path.dirname(artifacts.server) orelse return error.InvalidArtifactLayout) orelse
        return error.InvalidArtifactLayout;
    const state: ReleaseState = .{ .active_version = version, .active_root = root };
    try writeState(io, allocator, paths.state_dir, state);
}

pub fn writePlists(io: std.Io, allocator: std.mem.Allocator, artifacts: ArtifactPaths, paths: RuntimePaths) !void {
    const daemon = try daemonPlistAlloc(allocator, artifacts, paths);
    defer allocator.free(daemon);
    const web = try webPlistAlloc(allocator, artifacts, paths);
    defer allocator.free(web);
    try writeAtomic(io, paths.unit_dir, PLIST_DAEMON, daemon, 0o600);
    try writeAtomic(io, paths.unit_dir, PLIST_WEB, web, 0o600);
}

pub fn writeUnits(io: std.Io, allocator: std.mem.Allocator, artifacts: ArtifactPaths, paths: RuntimePaths) !void {
    const daemon_unit = try daemonUnitAlloc(allocator, artifacts, paths);
    defer allocator.free(daemon_unit);
    const web_unit = try webUnitAlloc(allocator, artifacts, paths);
    defer allocator.free(web_unit);
    try writeAtomic(io, paths.unit_dir, UNIT_DAEMON, daemon_unit, 0o600);
    try writeAtomic(io, paths.unit_dir, UNIT_WEB, web_unit, 0o600);
}

pub fn readState(io: std.Io, allocator: std.mem.Allocator, state_dir: []const u8) !std.json.Parsed(ReleaseState) {
    const dir = try std.Io.Dir.openDirAbsolute(io, state_dir, .{});
    defer dir.close(io);
    const encoded = try dir.readFileAlloc(io, STATE_FILE, allocator, .limited(64 * 1024));
    defer allocator.free(encoded);
    return std.json.parseFromSlice(ReleaseState, allocator, encoded, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
}

pub fn uninstall(io: std.Io, paths: RuntimePaths) !void {
    try deleteIfExists(io, paths.unit_dir, UNIT_WEB);
    try deleteIfExists(io, paths.unit_dir, UNIT_DAEMON);
    try deleteIfExists(io, paths.unit_dir, PLIST_WEB);
    try deleteIfExists(io, paths.unit_dir, PLIST_DAEMON);
    // Runtime data, provider credentials, token, and release state are retained.
}

pub fn writeState(io: std.Io, allocator: std.mem.Allocator, state_dir: []const u8, state: ReleaseState) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, state, .{ .emit_null_optional_fields = false });
    defer allocator.free(encoded);
    try writeAtomic(io, state_dir, STATE_FILE, encoded, 0o600);
}

pub fn beginCandidate(current: ReleaseState, version: []const u8, root: []const u8) ReleaseState {
    return .{
        .active_version = current.active_version,
        .active_root = current.active_root,
        .previous_version = current.previous_version,
        .previous_root = current.previous_root,
        .candidate_version = version,
        .candidate_root = root,
    };
}

pub fn requireVerifiedCandidate(current: ReleaseState, version: []const u8, root: []const u8) !void {
    // A future signed release manifest can widen this allowlist. Until then,
    // only the exact artifact set recorded by install is safe to execute.
    if (!std.mem.eql(u8, current.active_version, version) or
        !std.mem.eql(u8, current.active_root, root)) return error.UnverifiedCandidate;
}

pub fn activateCandidate(state: ReleaseState) !ReleaseState {
    return .{
        .active_version = state.candidate_version orelse return error.NoCandidate,
        .active_root = state.candidate_root orelse return error.NoCandidate,
        .previous_version = state.active_version,
        .previous_root = state.active_root,
    };
}

pub fn rollback(state: ReleaseState) !ReleaseState {
    return .{
        .active_version = state.previous_version orelse return error.NoRollback,
        .active_root = state.previous_root orelse return error.NoRollback,
        .previous_version = state.active_version,
        .previous_root = state.active_root,
    };
}

pub fn redactedCommand(command: []const u8) []const u8 {
    if (std.mem.indexOf(u8, command, "--token") != null or
        std.mem.indexOf(u8, command, "Authorization:") != null or
        std.mem.indexOf(u8, command, "VerdeDevice ") != null) return "[redacted]";
    return command;
}

fn validateSafeAbsolutePath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.PathMustBeAbsolute;
    if (std.mem.indexOfAny(u8, path, "\r\n\t ") != null) return error.UnsafeSystemdPath;
}

fn requireFile(io: std.Io, path: []const u8, executable: bool) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file) return error.NotAFile;
    if (executable and builtin.os.tag != .windows and stat.permissions.toMode() & 0o111 == 0) return error.NotExecutable;
}

pub fn ensureOwnerOnlyToken(io: std.Io, path: []const u8) !void {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return createToken(io, path),
        error.SymLinkLoop => return error.TokenFileSymlink,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.TokenFileNotRegular;
    if (builtin.os.tag != .windows and stat.permissions.toMode() & 0o077 != 0) return error.InsecureTokenFilePermissions;
    try validateOwner(file);
}

pub fn ensureOwnerOnlyDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .directory) return error.NotDir;
    if (builtin.os.tag != .windows and std.posix.mode_t != u0) {
        try std.Io.Dir.cwd().setFilePermissions(io, path, @enumFromInt(0o700), .{ .follow_symlinks = false });
    }
}

fn createToken(io: std.Io, path: []const u8) !void {
    var entropy: [32]u8 = undefined;
    io.random(&entropy);
    defer std.crypto.secureZero(u8, &entropy);
    var encoded: [65]u8 = undefined;
    const hex = std.fmt.bytesToHex(entropy, .lower);
    @memcpy(encoded[0..64], &hex);
    encoded[64] = '\n';
    defer std.crypto.secureZero(u8, &encoded);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const name = std.fs.path.basename(path);
    const dir = try std.Io.Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = name, .data = &encoded, .flags = .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    } });
}

fn validateOwner(file: std.Io.File) !void {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var native_stat: linux.Statx = undefined;
        const result = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .UID = true }, &native_stat);
        if (linux.errno(result) != .SUCCESS or !native_stat.mask.UID) return error.OwnerCheckFailed;
        if (native_stat.uid != linux.geteuid()) return error.OwnerMismatch;
    } else if (comptime builtin.os.tag == .macos) {
        var native_stat: std.c.Stat = undefined;
        if (std.c.fstat(file.handle, &native_stat) != 0) return error.OwnerCheckFailed;
        if (native_stat.uid != std.c.geteuid()) return error.OwnerMismatch;
    }
}

fn writeAtomic(io: std.Io, dir_path: []const u8, name: []const u8, data: []const u8, permissions: u16) !void {
    const dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    var random: [8]u8 = undefined;
    io.random(&random);
    var tmp_buffer: [128]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buffer, ".{s}.{x}.tmp", .{ name, random });
    errdefer dir.deleteFile(io, tmp) catch {};
    try dir.writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{
        .exclusive = true,
        .permissions = @enumFromInt(permissions),
    } });
    try dir.rename(tmp, dir, name, io);
}

fn deleteIfExists(io: std.Io, dir_path: []const u8, name: []const u8) !void {
    const dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "units use exact foreground boundaries and no raw secret" {
    const artifacts: ArtifactPaths = .{
        .server = "/opt/verde/releases/1/bin/verde-server",
        .daemon = "/opt/verde/releases/1/bin/verde-daemon",
        .web = "/opt/verde/releases/1/bin/verde-web",
        .static_dir = "/opt/verde/releases/1/share/verde/web",
        .provider_bridge = "/opt/verde/releases/1/share/verde/provider_bridge.mjs",
    };
    const paths: RuntimePaths = .{
        .data_dir = "/home/verde/.local/share/verde/runtime",
        .token_file = "/home/verde/.config/verde/web-token",
        .unit_dir = "/home/verde/.config/systemd/user",
        .state_dir = "/home/verde/.local/state/verde-server",
        .gateway_port = 7420,
        .trusted_proxy_origin = "https://runtime.tail.ts.net",
    };
    const daemon = try daemonUnitAlloc(std.testing.allocator, artifacts, paths);
    defer std.testing.allocator.free(daemon);
    const web = try webUnitAlloc(std.testing.allocator, artifacts, paths);
    defer std.testing.allocator.free(web);
    try std.testing.expect(std.mem.indexOf(u8, daemon, "Type=simple") != null);
    try std.testing.expect(std.mem.indexOf(u8, daemon, "KillMode=mixed") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "--token-file /home/verde/.config/verde/web-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "--port 7420") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "--trusted-proxy-origin https://runtime.tail.ts.net") != null);
    try std.testing.expect(std.mem.indexOf(u8, web, "VERDE_WEB_TOKEN=") == null);

    const daemon_plist = try daemonPlistAlloc(std.testing.allocator, artifacts, paths);
    defer std.testing.allocator.free(daemon_plist);
    const web_plist = try webPlistAlloc(std.testing.allocator, artifacts, paths);
    defer std.testing.allocator.free(web_plist);
    try std.testing.expect(std.mem.indexOf(u8, daemon_plist, "dev.verde.runtime.daemon") != null);
    try std.testing.expect(std.mem.indexOf(u8, web_plist, "--trusted-proxy-origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, web_plist, "https://runtime.tail.ts.net") != null);
}

test "activation and rollback retain exact version roots" {
    const current: ReleaseState = .{ .active_version = "1.0.0", .active_root = "/opt/verde/releases/1.0.0" };
    const pending = beginCandidate(current, "1.1.0", "/opt/verde/releases/1.1.0");
    const active = try activateCandidate(pending);
    try std.testing.expectEqualStrings("1.1.0", active.active_version);
    const restored = try rollback(active);
    try std.testing.expectEqualStrings("1.0.0", restored.active_version);
    try std.testing.expectEqualStrings("/opt/verde/releases/1.0.0", restored.active_root);
    try requireVerifiedCandidate(current, "1.0.0", "/opt/verde/releases/1.0.0");
    try std.testing.expectError(error.UnverifiedCandidate, requireVerifiedCandidate(current, "1.1.0", "/tmp/download"));
}

test "path validation and redaction fail closed" {
    try std.testing.expectError(error.PathMustBeAbsolute, validateSafeAbsolutePath("relative/bin"));
    try std.testing.expectError(error.UnsafeSystemdPath, validateSafeAbsolutePath("/opt/verde bad/bin"));
    try std.testing.expectEqualStrings("[redacted]", redactedCommand("curl --token secret"));
    try std.testing.expectEqualStrings("systemctl --user status", redactedCommand("systemctl --user status"));
}

test "atomic unit writes are idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    try writeAtomic(std.testing.io, path, "verde.service", "unit-v1\n", 0o600);
    try writeAtomic(std.testing.io, path, "verde.service", "unit-v1\n", 0o600);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "verde.service", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("unit-v1\n", contents);
}
