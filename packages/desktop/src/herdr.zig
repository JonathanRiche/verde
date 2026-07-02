//! Shared Herdr integration helpers used by the CLI and desktop app.

const std = @import("std");

const process_env = @import("process_env.zig");

pub const PENDING_DIR_NAME = "herdr";
pub const PENDING_OPEN_FILE_NAME = "pending-open.json";
pub const PROFILES_FILE_NAME = "profiles.json";
pub const SHADOW_WORKSPACES_DIR_NAME = "herdr-workspaces";
/// Relative to the remote user's home. SSH command execution starts there, and
/// Herdr normalizes the relative cwd into an absolute pane cwd on the remote.
pub const REMOTE_WORKSPACES_DIR_NAME = ".local/share/verde/herdr-workspaces";
const REMOTE_CONTROL_TIMEOUT = "20s";

pub const OpenRequest = struct {
    session: []const u8 = "",
    herdr_workspace: []const u8 = "",
    remote: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    remote_cwd: ?[]const u8 = null,
    local_dir: ?[]const u8 = null,
    pane: ?[]const u8 = null,
};

pub const HandoffRequest = struct {
    session: []const u8 = "default",
    remote: ?[]const u8 = null,
    remote_cwd: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    all: bool = false,
    dry_run: bool = false,
};

pub const UnlinkRequest = struct {
    workspace: ?[]const u8 = null,
    all: bool = false,
};

pub const CliTarget = struct {
    session: []const u8 = "default",
    remote: ?[]const u8 = null,
};

pub const Profile = struct {
    name: []const u8,
    ssh_target: []const u8,
    session: []const u8 = "default",
    remote_cwd: ?[]const u8 = null,
    local_dir: ?[]const u8 = null,
    updated_at_ms: i64 = 0,
};

pub const LoadedProfiles = struct {
    arena: std.heap.ArenaAllocator,
    profiles: []Profile = &.{},

    pub fn init(backing_allocator: std.mem.Allocator) LoadedProfiles {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    pub fn allocator(self: *LoadedProfiles) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *LoadedProfiles) void {
        self.arena.deinit();
    }
};

pub const LoadedOpenRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: OpenRequest = .{},

    pub fn init(backing_allocator: std.mem.Allocator) LoadedOpenRequest {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    pub fn allocator(self: *LoadedOpenRequest) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *LoadedOpenRequest) void {
        self.arena.deinit();
    }
};

pub fn validateOpenRequest(request: OpenRequest) !void {
    try validateSessionName(request.session);
    if (std.mem.trim(u8, request.herdr_workspace, &std.ascii.whitespace).len == 0) return error.MissingHerdrWorkspace;
}

pub fn validateHandoffRequest(request: HandoffRequest) !void {
    try validateSessionName(request.session);
    if (request.workspace) |workspace| {
        if (std.mem.trim(u8, workspace, &std.ascii.whitespace).len == 0) return error.EmptyHerdrWorkspaceSelector;
    }
}

pub fn validateUnlinkRequest(request: UnlinkRequest) !void {
    if (request.all and request.workspace != null) return error.AmbiguousHerdrWorkspaceSelector;
    if (request.workspace) |workspace| {
        if (std.mem.trim(u8, workspace, &std.ascii.whitespace).len == 0) return error.EmptyHerdrWorkspaceSelector;
    }
}

pub fn validateProfile(profile: Profile) !void {
    if (std.mem.trim(u8, profile.name, &std.ascii.whitespace).len == 0) return error.MissingHerdrProfileName;
    if (std.mem.trim(u8, profile.ssh_target, &std.ascii.whitespace).len == 0) return error.MissingHerdrProfileSshTarget;
    try validateSessionName(profile.session);
}

fn validateSessionName(session: []const u8) !void {
    if (std.mem.trim(u8, session, &std.ascii.whitespace).len == 0) return error.MissingHerdrSession;
}

pub fn remoteAlias(request: OpenRequest) []const u8 {
    return request.remote orelse "";
}

pub fn pendingOpenPath(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ pref_path, PENDING_DIR_NAME, PENDING_OPEN_FILE_NAME });
}

pub fn profilesPath(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ pref_path, PENDING_DIR_NAME, PROFILES_FILE_NAME });
}

pub fn defaultLocalDir(allocator: std.mem.Allocator, pref_path: []const u8, request: OpenRequest) ![]u8 {
    const name = try safeWorkspaceDirName(allocator, request);
    defer allocator.free(name);
    return try std.fs.path.join(allocator, &.{ pref_path, SHADOW_WORKSPACES_DIR_NAME, name });
}

pub fn defaultRemoteCwd(allocator: std.mem.Allocator, workspace_label: []const u8, verde_workspace_id: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(REMOTE_WORKSPACES_DIR_NAME);
    try writer.writer.writeByte('/');
    try appendSafePart(&writer.writer, workspace_label);
    try writer.writer.writeByte('-');
    try appendSafePart(&writer.writer, verde_workspace_id);
    return try writer.toOwnedSlice();
}

pub fn runCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: CliTarget,
    args: []const []const u8,
    max_output_bytes: usize,
) !std.process.RunResult {
    try validateSessionName(target.session);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    var remote_command: ?[]u8 = null;
    defer if (remote_command) |command| allocator.free(command);
    var local_executable: ?[]u8 = null;
    defer if (local_executable) |path| allocator.free(path);
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();

    if (target.remote) |remote| {
        remote_command = try remoteHerdrCommandLineAlloc(allocator, target.session, args);
        // Pass the full command as ssh's single remote command string. Splitting
        // this as `bash -lc <command>` loses quoting because OpenSSH joins argv
        // with spaces before the remote shell sees it, which can accidentally run
        // bare `herdr` and require a TTY.
        // `timeout` prevents live IPC calls from hanging forever when SSH or
        // Tailscale needs a fresh interactive approval. Terminal attach remains
        // interactive; this guard is only for request/response control calls.
        try argv.appendSlice(allocator, &.{
            "timeout",
            REMOTE_CONTROL_TIMEOUT,
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "NumberOfPasswordPrompts=0",
            "-o",
            "KbdInteractiveAuthentication=no",
            remote,
            remote_command.?,
        });
    } else {
        local_executable = try localHerdrExecutableAlloc(allocator, io);
        try argv.appendSlice(allocator, &.{ local_executable orelse "herdr", "--session", target.session });
        try argv.appendSlice(allocator, args);
    }

    return std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .environ_map = &env_map,
    });
}

pub fn runRemoteShell(
    allocator: std.mem.Allocator,
    io: std.Io,
    remote: []const u8,
    command: []const u8,
    max_output_bytes: usize,
) !std.process.RunResult {
    if (std.mem.trim(u8, remote, &std.ascii.whitespace).len == 0) return error.MissingHerdrProfileSshTarget;
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    const argv = [_][]const u8{
        "timeout",
        REMOTE_CONTROL_TIMEOUT,
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "NumberOfPasswordPrompts=0",
        "-o",
        "KbdInteractiveAuthentication=no",
        remote,
        command,
    };
    return std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .environ_map = &env_map,
    });
}

pub fn remoteMkdirCommandLineAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("mkdir -p -- ");
    try shellQuote(&writer.writer, path);
    return try writer.toOwnedSlice();
}

pub fn remoteLoginShellCommandLineAlloc(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var script_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer script_writer.deinit();
    try script_writer.writer.writeAll("cd -- ");
    try shellQuote(&script_writer.writer, cwd);
    try script_writer.writer.writeAll(" && exec \"${SHELL:-/bin/bash}\" -l");
    const script = try script_writer.toOwnedSlice();
    defer allocator.free(script);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    // Force bash for the remote command wrapper because Herdr remote hosts may
    // use fish or another non-POSIX login shell. The launched shell is still the
    // user's remote `$SHELL`.
    try writer.writer.writeAll("bash -lc ");
    try shellQuote(&writer.writer, script);
    return try writer.toOwnedSlice();
}

pub fn remoteExecCommandLineAlloc(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    if (args.len == 0) return error.EmptyRemoteCommand;
    var script_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer script_writer.deinit();
    try script_writer.writer.writeAll("cd -- ");
    try shellQuote(&script_writer.writer, cwd);
    try script_writer.writer.writeAll(" && exec ");
    for (args, 0..) |arg, index| {
        if (index > 0) try script_writer.writer.writeByte(' ');
        try shellQuote(&script_writer.writer, arg);
    }
    const script = try script_writer.toOwnedSlice();
    defer allocator.free(script);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("bash -lc ");
    try shellQuote(&writer.writer, script);
    return try writer.toOwnedSlice();
}

fn localHerdrExecutableAlloc(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (std.c.getenv("HERDR_BIN")) |value| {
        return try allocator.dupe(u8, std.mem.sliceTo(value, 0));
    }
    const home = std.c.getenv("HOME") orelse return null;
    const local_path = try std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), ".local", "bin", "herdr" });
    errdefer allocator.free(local_path);
    std.Io.Dir.accessAbsolute(io, local_path, .{ .follow_symlinks = true, .read = true, .write = false, .execute = true }) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(local_path);
            return null;
        },
        else => return err,
    };
    return local_path;
}

pub fn remoteHerdrCommandLineAlloc(allocator: std.mem.Allocator, session: []const u8, args: []const []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("$HOME/.local/bin/herdr --session ");
    try shellQuote(&writer.writer, session);
    for (args) |arg| {
        try writer.writer.writeByte(' ');
        try shellQuote(&writer.writer, arg);
    }
    return try writer.toOwnedSlice();
}

pub fn findJsonString(value: std.json.Value, key: []const u8) ?[]const u8 {
    switch (value) {
        .object => |object| {
            if (object.get(key)) |field| {
                if (field == .string) return field.string;
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (findJsonString(entry.value_ptr.*, key)) |found| return found;
            }
            return null;
        },
        .array => |array| {
            for (array.items) |item| {
                if (findJsonString(item, key)) |found| return found;
            }
            return null;
        },
        else => return null,
    }
}

pub fn writePendingOpen(allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8, request: OpenRequest) !void {
    try validateOpenRequest(request);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const fs_io = threaded.io();

    try std.Io.Dir.cwd().createDirPath(fs_io, pref_path);
    const pending_dir = try std.fs.path.join(allocator, &.{ pref_path, PENDING_DIR_NAME });
    defer allocator.free(pending_dir);
    try std.Io.Dir.cwd().createDirPath(fs_io, pending_dir);

    const path = try pendingOpenPath(allocator, pref_path);
    defer allocator.free(path);

    const encoded = try std.json.Stringify.valueAlloc(allocator, request, .{});
    defer allocator.free(encoded);
    var file = try std.Io.Dir.createFileAbsolute(fs_io, path, .{ .truncate = true });
    defer file.close(fs_io);
    try file.writeStreamingAll(fs_io, encoded);
    try file.writeStreamingAll(fs_io, "\n");
    _ = io;
}

pub fn readPendingOpen(backing_allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8) !?LoadedOpenRequest {
    var threaded: std.Io.Threaded = .init(backing_allocator, .{});
    defer threaded.deinit();
    const fs_io = threaded.io();

    const pending_dir = try std.fs.path.join(backing_allocator, &.{ pref_path, PENDING_DIR_NAME });
    defer backing_allocator.free(pending_dir);
    var dir = std.Io.Dir.openDirAbsolute(fs_io, pending_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(fs_io);

    const bytes = dir.readFileAlloc(fs_io, PENDING_OPEN_FILE_NAME, backing_allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer backing_allocator.free(bytes);

    var loaded = LoadedOpenRequest.init(backing_allocator);
    errdefer loaded.deinit();
    loaded.value = try std.json.parseFromSliceLeaky(OpenRequest, loaded.allocator(), bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    try validateOpenRequest(loaded.value);
    _ = io;
    return loaded;
}

pub fn deletePendingOpen(allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8) void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const path = pendingOpenPath(allocator, pref_path) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(threaded.io(), path) catch {};
    _ = io;
}

pub fn loadProfiles(backing_allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8) !LoadedProfiles {
    var loaded = LoadedProfiles.init(backing_allocator);
    errdefer loaded.deinit();

    var threaded: std.Io.Threaded = .init(backing_allocator, .{});
    defer threaded.deinit();
    const path = try profilesPath(backing_allocator, pref_path);
    defer backing_allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, backing_allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return loaded,
        else => return err,
    };
    defer backing_allocator.free(bytes);
    loaded.profiles = try std.json.parseFromSliceLeaky([]Profile, loaded.allocator(), bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    for (loaded.profiles) |profile| try validateProfile(profile);
    _ = io;
    return loaded;
}

pub fn saveProfiles(allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8, profiles: []const Profile) !void {
    for (profiles) |profile| try validateProfile(profile);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const fs_io = threaded.io();
    try std.Io.Dir.cwd().createDirPath(fs_io, pref_path);
    const pending_dir = try std.fs.path.join(allocator, &.{ pref_path, PENDING_DIR_NAME });
    defer allocator.free(pending_dir);
    try std.Io.Dir.cwd().createDirPath(fs_io, pending_dir);
    const path = try profilesPath(allocator, pref_path);
    defer allocator.free(path);
    const encoded = try std.json.Stringify.valueAlloc(allocator, profiles, .{ .whitespace = .indent_2 });
    defer allocator.free(encoded);
    var file = try std.Io.Dir.createFileAbsolute(fs_io, path, .{ .truncate = true });
    defer file.close(fs_io);
    try file.writeStreamingAll(fs_io, encoded);
    try file.writeStreamingAll(fs_io, "\n");
    _ = io;
}

pub fn profileIndex(profiles: []const Profile, name: []const u8) ?usize {
    for (profiles, 0..) |profile, index| {
        if (std.mem.eql(u8, profile.name, name)) return index;
    }
    return null;
}

fn safeWorkspaceDirName(allocator: std.mem.Allocator, request: OpenRequest) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try appendSafePart(&writer.writer, if (remoteAlias(request).len > 0) remoteAlias(request) else "local");
    try writer.writer.writeByte('-');
    try appendSafePart(&writer.writer, request.session);
    try writer.writer.writeByte('-');
    try appendSafePart(&writer.writer, request.herdr_workspace);
    return try writer.toOwnedSlice();
}

fn appendSafePart(writer: *std.Io.Writer, value: []const u8) !void {
    var wrote = false;
    for (value) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
        try writer.writeByte(if (safe) byte else '_');
        wrote = true;
    }
    if (!wrote) try writer.writeAll("default");
}

fn shellQuote(writer: *std.Io.Writer, arg: []const u8) !void {
    if (arg.len == 0) return writer.writeAll("''");
    var needs_quote = false;
    for (arg) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '.' or byte == '_' or byte == '-' or byte == ':' or byte == '=')) {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) return writer.writeAll(arg);
    try writer.writeByte('\'');
    for (arg) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

test "default local dir encodes Herdr identity safely" {
    const request: OpenRequest = .{
        .session = "default",
        .herdr_workspace = "w1:p1",
        .remote = "zod.tailc28f01.ts.net",
    };
    const path = try defaultLocalDir(std.testing.allocator, "/tmp/verde", request);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/verde/herdr-workspaces/zod.tailc28f01.ts.net-default-w1_p1", path);
}

test "default remote cwd encodes Verde workspace identity safely" {
    const path = try defaultRemoteCwd(std.testing.allocator, "client repo", "abc/123");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(".local/share/verde/herdr-workspaces/client_repo-abc_123", path);
}

test "remote command line quotes arguments" {
    const command = try remoteHerdrCommandLineAlloc(std.testing.allocator, "default", &.{ "workspace", "create", "--cwd", "/tmp/has space" });
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("$HOME/.local/bin/herdr --session default workspace create --cwd '/tmp/has space'", command);
}

test "remote mkdir command line quotes path" {
    const command = try remoteMkdirCommandLineAlloc(std.testing.allocator, ".local/share/verde/herdr-workspaces/has space");
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("mkdir -p -- '.local/share/verde/herdr-workspaces/has space'", command);
}

test "remote login shell command line starts in cwd" {
    const command = try remoteLoginShellCommandLineAlloc(std.testing.allocator, ".local/share/verde/herdr-workspaces/has space");
    defer std.testing.allocator.free(command);
    const expected =
        \\bash -lc 'cd -- '\''.local/share/verde/herdr-workspaces/has space'\'' && exec "${SHELL:-/bin/bash}" -l'
    ;
    try std.testing.expectEqualStrings(expected, command);
}

test "remote exec command line quotes cwd and argv" {
    const command = try remoteExecCommandLineAlloc(std.testing.allocator, ".local/share/verde/herdr-workspaces/has space", &.{ "/bin/sh", "-lc", "printf 'hi there'" });
    defer std.testing.allocator.free(command);
    const expected =
        \\bash -lc 'cd -- '\''.local/share/verde/herdr-workspaces/has space'\'' && exec /bin/sh -lc '\''printf '\''\'\'''\''hi there'\''\'\'''\'''\'''
    ;
    try std.testing.expectEqualStrings(expected, command);
}

test "unlink request rejects ambiguous workspace selector" {
    try std.testing.expectError(error.AmbiguousHerdrWorkspaceSelector, validateUnlinkRequest(.{
        .workspace = "current",
        .all = true,
    }));
}

test "profile validation requires ssh alias" {
    try std.testing.expectError(error.MissingHerdrProfileSshTarget, validateProfile(.{
        .name = "workbox",
        .ssh_target = "",
    }));
}
