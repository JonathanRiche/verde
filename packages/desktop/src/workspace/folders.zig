//! Workspace folder manifest, provider context, and owned symlink projection.

const std = @import("std");
const toml = @import("toml");

pub const CONFIG_FILENAME = "verde.toml";
pub const MAX_FOLDERS = 32;
const MAX_CONFIG_BYTES = 256 * 1024;

pub const Folder = struct {
    name: []const u8,
    path: []const u8,
    enabled: bool = true,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    folders: []const Folder = &.{},
    default_folder: []const u8 = "",
    links: bool = false,
    configured: bool = false,

    pub fn deinit(self: *Config, _: std.mem.Allocator) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    home: []const u8,
    cwd: []const u8,
    folders: []const Folder,
    roots: []const []const u8,
    context: []const u8,
    links: bool,
    configured: bool = false,

    pub fn deinit(self: *Resolved) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn string(table: *const toml.Table, key: []const u8, default: []const u8) ![]const u8 {
    const value = table.get(key) orelse return default;
    return if (value == .string) value.string else error.InvalidWorkspaceConfig;
}

pub fn boolean(table: *const toml.Table, key: []const u8, default: bool) !bool {
    const value = table.get(key) orelse return default;
    return if (value == .boolean) value.boolean else error.InvalidWorkspaceConfig;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Config {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = try toml.parseSlice(a, source, null);
    if (root.get("version")) |version| {
        if (version != .integer or version.integer.value != 1) return error.UnsupportedWorkspaceConfigVersion;
    }
    var result: Config = .{ .arena = undefined, .configured = root.contains("folders") or root.contains("workspace") };
    if (root.get("workspace")) |workspace| {
        if (workspace != .table) return error.InvalidWorkspaceConfig;
        result.default_folder = try string(workspace.table, "default_folder", "");
        result.links = try boolean(workspace.table, "links", false);
    }
    if (root.get("folders")) |folders| {
        if (folders != .table) return error.InvalidWorkspaceFolders;
        var entries: std.ArrayList(Folder) = .empty;
        var active_count: usize = 0;
        var it = folders.table.iterator();
        while (it.next()) |entry| {
            if (!validName(entry.key_ptr.*) or entry.value_ptr.* != .table) return error.InvalidWorkspaceFolderName;
            const path = try string(entry.value_ptr.table, "path", "");
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidWorkspaceFolderPath;
            const enabled = try boolean(entry.value_ptr.table, "enabled", true);
            if (enabled) active_count += 1;
            if (active_count > MAX_FOLDERS) return error.TooManyWorkspaceFolders;
            try entries.append(a, .{ .name = entry.key_ptr.*, .path = path, .enabled = enabled });
        }
        result.folders = try entries.toOwnedSlice(a);
    }
    if (result.default_folder.len > 0) {
        for (result.folders) |folder| {
            if (folder.enabled and std.mem.eql(u8, folder.name, result.default_folder)) break;
        } else return error.InvalidDefaultWorkspaceFolder;
    }
    result.arena = arena;
    return result;
}

pub fn readSource(allocator: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ home, CONFIG_FILENAME });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_CONFIG_BYTES)) catch |err| switch (err) {
        error.FileNotFound => allocator.dupe(u8, ""),
        else => return err,
    };
}

pub fn sourceHash(allocator: std.mem.Allocator, home: []const u8) !u64 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const source = try readSource(allocator, threaded.io(), home);
    defer allocator.free(source);
    return std.hash.Wyhash.hash(0, source);
}

pub fn load(allocator: std.mem.Allocator, home: []const u8) !Config {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const source = try readSource(allocator, threaded.io(), home);
    defer allocator.free(source);
    return parse(allocator, source);
}

/// Resolve targets on the execution runtime, never on the caller's machine.
pub fn resolve(allocator: std.mem.Allocator, home: []const u8) !Resolved {
    var config = try load(allocator, home);
    defer config.deinit(allocator);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const real_home = try std.Io.Dir.cwd().realPathFileAlloc(io, home, a);
    var entries: std.ArrayList(Folder) = .empty;
    var roots: std.ArrayList([]const u8) = .empty;
    try roots.append(a, real_home);
    var default_cwd = real_home;
    for (config.folders) |folder| {
        if (!folder.enabled) continue;
        const candidate = try std.fs.path.resolve(a, &.{ real_home, folder.path });
        const real = try std.Io.Dir.cwd().realPathFileAlloc(io, candidate, a);
        const stat = try std.Io.Dir.cwd().statFile(io, real, .{});
        if (stat.kind != .directory) return error.WorkspaceFolderNotDirectory;
        try entries.append(a, .{ .name = try a.dupe(u8, folder.name), .path = real });
        if (std.mem.eql(u8, folder.name, config.default_folder)) default_cwd = real;
        for (roots.items) |existing| {
            if (std.mem.eql(u8, existing, real)) break;
        } else try roots.append(a, real);
    }
    var text: std.Io.Writer.Allocating = .init(a);
    try text.writer.writeAll("<verde_workspace>\nThis directory map replaces earlier workspace folder maps. Workspace folders are shared live directories. Edits affect the original files.\n");
    try text.writer.print("Workspace home: {s}\nDefault working folder: {s}\n", .{ real_home, default_cwd });
    for (entries.items) |folder| try text.writer.print("- {s}: {s}\n", .{ folder.name, folder.path });
    try text.writer.writeAll("Read the workspace home's instructions and each target folder's AGENTS.md / CLAUDE.md and scoped instructions before working there. Run Git and build commands in the relevant folder. These folders are not isolated worktrees. Follow the provider's existing permission mode.\n</verde_workspace>\n");
    const owned_entries = try entries.toOwnedSlice(a);
    const owned_roots = try roots.toOwnedSlice(a);
    const owned_context = try text.toOwnedSlice();
    return .{
        .arena = arena,
        .home = real_home,
        .cwd = default_cwd,
        .folders = owned_entries,
        .roots = owned_roots,
        .context = owned_context,
        .links = config.links,
        .configured = config.configured,
    };
}

/// Replace just one TOML value; keep comments and unrelated user settings.
pub fn edit(allocator: std.mem.Allocator, home: []const u8, path: []const toml.PathSegment, value: toml.Value) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const source = try readSource(allocator, io, home);
    defer allocator.free(source);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try toml.setValueAtPath(source, path, value, &out.writer, allocator);
    if (out.written().len > MAX_CONFIG_BYTES) return error.WorkspaceConfigTooLarge;
    var checked = try parse(allocator, out.written());
    defer checked.deinit(allocator);
    const config_path = try std.fs.path.join(allocator, &.{ home, CONFIG_FILENAME });
    defer allocator.free(config_path);
    try writeAtomic(allocator, io, config_path, out.written());
}

pub fn add(allocator: std.mem.Allocator, home: []const u8, path: []const u8) !void {
    var config = try load(allocator, home);
    defer config.deinit(allocator);
    var active_count: usize = 0;
    for (config.folders) |folder| {
        if (folder.enabled) active_count += 1;
    }
    if (active_count >= MAX_FOLDERS) return error.TooManyWorkspaceFolders;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const real = try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), path, allocator);
    defer allocator.free(real);
    if ((try std.Io.Dir.cwd().statFile(threaded.io(), real, .{})).kind != .directory) return error.WorkspaceFolderNotDirectory;
    var base: [48]u8 = undefined;
    const basename = std.fs.path.basename(real);
    var len: usize = 0;
    for (basename) |c| {
        if (len == base.len) break;
        base[len] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '-';
        len += 1;
    }
    if (len == 0) {
        @memcpy(base[0..6], "folder");
        len = 6;
    }
    var name_buf: [64]u8 = undefined;
    var suffix: usize = 1;
    const name = outer: while (true) : (suffix += 1) {
        const candidate = if (suffix == 1) base[0..len] else try std.fmt.bufPrint(&name_buf, "{s}-{d}", .{ base[0..len], suffix });
        for (config.folders) |folder| {
            if (std.mem.eql(u8, folder.name, candidate)) break;
        } else break :outer candidate;
    };
    try edit(allocator, home, &.{ .{ .key = "folders" }, .{ .key = name }, .{ .key = "path" } }, .{ .string = real });
    try sync(allocator, home);
}

pub fn setDefault(allocator: std.mem.Allocator, home: []const u8, name: []const u8) !void {
    try edit(allocator, home, &.{ .{ .key = "workspace" }, .{ .key = "default_folder" } }, .{ .string = name });
}

/// Disabled entries retain their comments and can be re-enabled by hand.
pub fn remove(allocator: std.mem.Allocator, home: []const u8, name: []const u8) !void {
    var config = try load(allocator, home);
    defer config.deinit(allocator);
    if (std.mem.eql(u8, config.default_folder, name)) try setDefault(allocator, home, "");
    try edit(allocator, home, &.{ .{ .key = "folders" }, .{ .key = name }, .{ .key = "enabled" } }, .{ .boolean = false });
    try sync(allocator, home);
}

pub fn initManaged(allocator: std.mem.Allocator, home: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const path = try std.fs.path.join(allocator, &.{ home, CONFIG_FILENAME });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = "version = 1\n\n[workspace]\nlinks = true\n", .flags = .{ .exclusive = true } });
}

/// Only remove a link if it still points to the exact target Verde recorded.
fn removeOwnedLink(io: std.Io, path: []const u8, target: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().readLink(io, path, &buf) catch |err| switch (err) {
        error.FileNotFound, error.NotLink => return,
        else => return err,
    };
    if (std.mem.eql(u8, buf[0..len], target)) std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Materialize the optional links and generated guidance without touching targets.
pub fn sync(allocator: std.mem.Allocator, home: []const u8) !void {
    var resolved = try resolve(allocator, home);
    defer resolved.deinit();
    const a = resolved.arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const state_dir = try std.fs.path.join(a, &.{ resolved.home, ".verde" });
    try std.Io.Dir.cwd().createDirPath(io, state_dir);
    const records_path = try std.fs.path.join(a, &.{ state_dir, "folder-links.json" });
    const previous = std.Io.Dir.cwd().readFileAlloc(io, records_path, a, .limited(MAX_CONFIG_BYTES)) catch |err| switch (err) {
        error.FileNotFound => "[]",
        else => return err,
    };
    const records = try std.json.parseFromSlice([]Folder, a, previous, .{ .ignore_unknown_fields = true });
    for (records.value) |old| {
        if (!validName(old.name)) return error.InvalidWorkspaceFolderName;
        const keep = if (resolved.links) for (resolved.folders) |folder| {
            if (std.mem.eql(u8, old.name, folder.name) and std.mem.eql(u8, old.path, folder.path)) break true;
        } else false else false;
        if (!keep) try removeOwnedLink(io, try std.fs.path.join(a, &.{ resolved.home, old.name }), old.path);
    }
    var owned_links: std.ArrayList(Folder) = .empty;
    if (resolved.links) for (resolved.folders) |folder| {
        if (std.mem.eql(u8, folder.path, resolved.home)) continue;
        const link = try std.fs.path.join(a, &.{ resolved.home, folder.name });
        var owned = true;
        std.Io.Dir.cwd().symLink(io, folder.path, link, .{ .is_directory = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const len = std.Io.Dir.cwd().readLink(io, link, &buf) catch return error.WorkspaceLinkConflict;
                if (!std.mem.eql(u8, buf[0..len], folder.path)) return error.WorkspaceLinkConflict;
                // A pre-existing user link is usable, but it is not ours to delete.
                owned = for (records.value) |record| {
                    if (std.mem.eql(u8, record.name, folder.name) and std.mem.eql(u8, record.path, folder.path)) break true;
                } else false;
            },
            else => return err,
        };
        if (owned) try owned_links.append(a, folder);
    };
    const json = try std.json.Stringify.valueAlloc(a, owned_links.items, .{});
    try writeAtomic(a, io, records_path, json);
    try writeAtomic(a, io, try std.fs.path.join(a, &.{ state_dir, "WORKSPACE.md" }), resolved.context);
    if (resolved.links) {
        const guidance = "# Workspace folders\n\nRead `.verde/WORKSPACE.md` for the current folder map. Linked folders are shared live directories, not copies. Read each target's own project instructions before editing.\n";
        inline for (.{ "AGENTS.md", "CLAUDE.md" }) |name| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ resolved.home, name }), .data = guidance, .flags = .{ .exclusive = true } }) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
}

fn writeAtomic(allocator: std.mem.Allocator, io: std.Io, path: []const u8, contents: []const u8) !void {
    var random: [8]u8 = undefined;
    io.random(&random);
    const temp = try std.fmt.allocPrint(allocator, "{s}.{s}.tmp", .{ path, std.fmt.bytesToHex(random, .lower) });
    defer allocator.free(temp);
    const file = try std.Io.Dir.cwd().createFile(io, temp, .{ .exclusive = true });
    defer std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    {
        defer file.close(io);
        try file.writeStreamingAll(io, contents);
    }
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, io);
}

test "folder manifest validates names defaults types and duplicate keys" {
    const a = std.testing.allocator;
    var config = try parse(a, "version=1\n[workspace]\ndefault_folder='api'\n[folders.api]\npath='../api'\n");
    defer config.deinit(a);
    try std.testing.expectEqualStrings("../api", config.folders[0].path);
    try std.testing.expectError(error.InvalidDefaultWorkspaceFolder, parse(a, "[workspace]\ndefault_folder='missing'"));
    try std.testing.expectError(error.InvalidWorkspaceFolderName, parse(a, "[folders.'../oops']\npath='x'"));
    try std.testing.expectError(error.InvalidWorkspaceConfig, parse(a, "[folders.api]\npath=42"));
    if (parse(a, "version=1\nversion=1")) |value| {
        var c = value;
        c.deinit(a);
        return error.ExpectedDuplicateRejection;
    } else |_| {}
}

test "folder editing preserves comments resolves paths and removes only owned links" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "target");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const home = try std.fs.path.join(a, &.{ root, "home" });
    defer a.free(home);
    try tmp.dir.writeFile(io, .{ .sub_path = "home/verde.toml", .data = "# retain me\nversion=1\n[workspace]\nlinks=true\n[folders.api]\npath='../target' # keep this too\n" });
    try setDefault(a, home, "api");
    try sync(a, home);
    var resolved = try resolve(a, home);
    defer resolved.deinit();
    try std.testing.expectEqualStrings(resolved.folders[0].path, resolved.cwd);
    try tmp.dir.writeFile(io, .{ .sub_path = "target/keep", .data = "original" });
    try remove(a, home, "api");
    const source = try readSource(a, io, home);
    defer a.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "# retain me") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "# keep this too") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "home/api", .{}));
    var cleared = try resolve(a, home);
    defer cleared.deinit();
    try std.testing.expect(cleared.configured);
    try std.testing.expectEqual(@as(usize, 1), cleared.roots.len);
    try std.testing.expectEqual(@as(usize, 0), cleared.folders.len);
    _ = try tmp.dir.statFile(io, "target/keep", .{});
}

/// Extra arguments for providers with documented directory/context options.
/// Returned strings live in the resolved workspace's arena.
fn agentArgs(workspace: *Resolved, executable: []const u8) ![]const []const u8 {
    const a = workspace.arena.allocator();
    const base = std.fs.path.basename(executable);
    const codex = std.mem.eql(u8, base, "codex") or std.mem.eql(u8, base, "codex.exe");
    const claude = std.mem.eql(u8, base, "claude") or std.mem.eql(u8, base, "claude.exe");
    const pi = std.mem.eql(u8, base, "pi");
    var args: std.ArrayList([]const u8) = .empty;
    if (codex or claude) {
        for (workspace.roots) |root| {
            try args.appendSlice(a, &.{ "--add-dir", root });
        }
    }
    if (codex) {
        const quoted = try std.json.Stringify.valueAlloc(a, workspace.context, .{});
        try args.appendSlice(a, &.{ "-c", try std.fmt.allocPrint(a, "developer_instructions={s}", .{quoted}) });
    } else if (claude or pi) {
        try args.appendSlice(a, &.{ "--append-system-prompt", workspace.context });
    }
    return try args.toOwnedSlice(a);
}

/// Expand known agent launches, including shell-wrapped startup/resume. Never
/// append flags to arbitrary shell pipelines or guess unsupported CLI options.
pub fn terminalCommand(workspace: *Resolved, command: []const []const u8) ![]const []const u8 {
    if (workspace.folders.len == 0 or command.len == 0) return command;
    const a = workspace.arena.allocator();
    var shell_index: ?usize = null;
    for (command, 0..) |arg, i| {
        if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "-lc") or std.ascii.eqlIgnoreCase(arg, "-Command")) and i + 1 < command.len) {
            const shell = std.fs.path.basename(command[0]);
            if (std.mem.eql(u8, shell, "sh") or std.mem.eql(u8, shell, "bash") or std.mem.eql(u8, shell, "zsh") or std.ascii.eqlIgnoreCase(shell, "powershell.exe") or std.ascii.eqlIgnoreCase(shell, "pwsh.exe")) shell_index = i + 1;
            break;
        }
    }
    if (shell_index) |index| {
        const original = std.mem.trimStart(u8, command[index], " \t");
        const prefix: usize = if (std.mem.startsWith(u8, original, "exec ")) 5 else 0;
        const end = prefix + (std.mem.indexOfAny(u8, original[prefix..], " \t") orelse original[prefix..].len);
        const extra = try agentArgs(workspace, original[prefix..end]);
        if (extra.len == 0) return command;
        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeAll(original[0..end]);
        for (extra) |arg| {
            try out.writer.writeAll(" '");
            for (arg) |c| {
                if (c == '\'') try out.writer.writeAll(if (@import("builtin").os.tag == .windows) "''" else "'\\''") else try out.writer.writeByte(c);
            }
            try out.writer.writeByte('\'');
        }
        try out.writer.writeAll(original[end..]);
        const result = try a.dupe([]const u8, command);
        result[index] = try out.toOwnedSlice();
        return result;
    }
    const extra = try agentArgs(workspace, command[0]);
    if (extra.len == 0) return command;
    var result: std.ArrayList([]const u8) = .empty;
    try result.append(a, command[0]);
    try result.appendSlice(a, extra);
    try result.appendSlice(a, command[1..]);
    return try result.toOwnedSlice(a);
}

test "terminal launches preserve resume args and quote folder paths as data" {
    const arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var workspace: Resolved = .{
        .arena = arena,
        .home = "/home/work",
        .cwd = "/home/work",
        .folders = &.{.{ .name = "api", .path = "/tmp/api's $(touch nope)" }},
        .roots = &.{"/tmp/api's $(touch nope)"},
        .context = "Read project instructions.",
        .links = true,
    };
    defer workspace.deinit();
    const argv = try terminalCommand(&workspace, &.{ "codex", "resume", "thread-id" });
    try std.testing.expectEqualStrings("--add-dir", argv[1]);
    try std.testing.expectEqualStrings(workspace.roots[0], argv[2]);
    try std.testing.expectEqualStrings("thread-id", argv[argv.len - 1]);
    const shell = try terminalCommand(&workspace, &.{ "/bin/sh", "-lc", "claude --resume 'thread-id'" });
    try std.testing.expect(std.mem.endsWith(u8, shell[2], " --resume 'thread-id'"));
    if (@import("builtin").os.tag != .windows)
        try std.testing.expect(std.mem.indexOf(u8, shell[2], "api'\\''s $(touch nope)") != null);
    const plain = [_][]const u8{ "npm", "run", "dev" };
    try std.testing.expectEqualSlices([]const u8, &plain, try terminalCommand(&workspace, &plain));
}

test "user links and instructions survive adding and removing matching folders" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "target");
    const home = try tmp.dir.realPathFileAlloc(io, "home", a);
    defer a.free(home);
    const target = try tmp.dir.realPathFileAlloc(io, "target", a);
    defer a.free(target);
    try tmp.dir.symLink(io, target, "home/api", .{ .is_directory = true });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/AGENTS.md", .data = "User instructions" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/verde.toml", .data = "[workspace]\nlinks=true\n[folders.api]\npath='../target'\n" });
    try sync(a, home);
    try remove(a, home, "api");
    _ = try tmp.dir.statFile(io, "home/api", .{});
    const instructions = try tmp.dir.readFileAlloc(io, "home/AGENTS.md", a, .limited(1024));
    defer a.free(instructions);
    try std.testing.expectEqualStrings("User instructions", instructions);
}

test "folder picker additions retain process config and reject occupied link paths" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "target");
    const home = try tmp.dir.realPathFileAlloc(io, "home", a);
    defer a.free(home);
    const target = try tmp.dir.realPathFileAlloc(io, "target", a);
    defer a.free(target);
    try tmp.dir.writeFile(io, .{ .sub_path = "home/verde.toml", .data = "# keep process\n[processes.dev]\ncommand='npm run dev'\n[workspace]\nlinks=true\n" });
    try add(a, home, target);
    var config = try load(a, home);
    defer config.deinit(a);
    try std.testing.expectEqualStrings("target", config.folders[0].name);
    const source = try readSource(a, io, home);
    defer a.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "command='npm run dev'") != null);
    try tmp.dir.deleteFile(io, "home/target");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/target", .data = "user file" });
    try std.testing.expectError(error.WorkspaceLinkConflict, sync(a, home));
    try remove(a, home, "target");
    const kept = try tmp.dir.readFileAlloc(io, "home/target", a, .limited(1024));
    defer a.free(kept);
    try std.testing.expectEqualStrings("user file", kept);
}
