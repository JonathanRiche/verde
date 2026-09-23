//! Project-local managed stack config parsing.

const std = @import("std");
const toml = @import("toml");
pub const folders = @import("folders.zig");

pub const CONFIG_FILENAMES = [_][]const u8{"verde.toml"};

/// Keep config fan-out and launch payloads bounded before daemon-owned PTYs
/// are created. These limits protect both registry snapshots and responses.
pub const MAX_PROCESS_DEFINITIONS: usize = 64;
pub const MAX_PROCESS_COMMAND_BYTES: usize = 8192;

pub const BoundsViolation = struct {
    resource: []const u8,
    limit: usize,
};

pub const ProcessKind = enum {
    process,
    agent,
};

pub const RestartPolicy = enum {
    manual,
    on_crash,
    always,
};

pub const AgentProvider = enum {
    codex,
    claude,
    opencode,
    cursor,
    grok,
    amp,
    muse,
    other,
};

pub const RevivePolicy = enum {
    attach_or_create,
    attach_only,
    restart,
    manual,
};

pub const ProcessDefinition = struct {
    name: []u8,
    kind: ProcessKind,
    command: []u8,
    command_windows: ?[]u8 = null,
    command_unix: ?[]u8 = null,
    argv: std.ArrayList([]u8) = .empty,
    argv_windows: std.ArrayList([]u8) = .empty,
    argv_unix: std.ArrayList([]u8) = .empty,
    cwd: []u8,
    restart: RestartPolicy,
    provider: ?AgentProvider = null,
    revive: RevivePolicy = .attach_or_create,
    notify: bool = false,
    mcp: bool = false,
    hooks: bool = false,
    watch: std.ArrayList([]u8) = .empty,
    resources: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *ProcessDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        if (self.command_windows) |value| allocator.free(value);
        if (self.command_unix) |value| allocator.free(value);
        deinitArgv(allocator, &self.argv);
        deinitArgv(allocator, &self.argv_windows);
        deinitArgv(allocator, &self.argv_unix);
        allocator.free(self.cwd);
        for (self.watch.items) |pattern| allocator.free(pattern);
        self.watch.deinit(allocator);
        for (self.resources.items) |resource| allocator.free(resource);
        self.resources.deinit(allocator);
    }

    /// Selects one launch description without serializing structured argv into
    /// a shell string. Platform-specific entries override portable entries.
    pub fn launchForOs(self: *const ProcessDefinition, comptime os_tag: std.Target.Os.Tag) ?LaunchSpec {
        if (os_tag == .windows) {
            if (self.argv_windows.items.len > 0) return .{ .argv = self.argv_windows.items };
            if (nonEmpty(self.command_windows)) |command| return .{ .command = command };
        } else {
            if (self.argv_unix.items.len > 0) return .{ .argv = self.argv_unix.items };
            if (nonEmpty(self.command_unix)) |command| return .{ .command = command };
        }
        if (self.argv.items.len > 0) return .{ .argv = self.argv.items };
        if (std.mem.trim(u8, self.command, " \t\r\n").len > 0) return .{ .command = self.command };
        return null;
    }

    fn hasAnyLaunch(self: *const ProcessDefinition) bool {
        return self.argv.items.len > 0 or
            self.argv_windows.items.len > 0 or
            self.argv_unix.items.len > 0 or
            std.mem.trim(u8, self.command, " \t\r\n").len > 0 or
            nonEmpty(self.command_windows) != null or
            nonEmpty(self.command_unix) != null;
    }
};

/// A managed process is either a legacy shell command or a structured argv.
/// Keeping these distinct is what makes paths containing spaces portable.
pub const LaunchSpec = union(enum) {
    command: []const u8,
    argv: []const []u8,
};

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const slice = value orelse return null;
    return if (std.mem.trim(u8, slice, " \t\r\n").len == 0) null else slice;
}

fn deinitArgv(allocator: std.mem.Allocator, argv: *std.ArrayList([]u8)) void {
    for (argv.items) |arg| allocator.free(arg);
    argv.deinit(allocator);
}

pub const Config = struct {
    path: []u8,
    processes: std.ArrayList(ProcessDefinition) = .empty,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.processes.items) |*process| process.deinit(allocator);
        self.processes.deinit(allocator);
    }
};

/// Return the first bounded config resource that would exceed daemon limits.
/// This helper is pure; the daemon performs file loading before calling it.
pub fn validateDefinitionBounds(config: *const Config) ?BoundsViolation {
    if (config.processes.items.len > MAX_PROCESS_DEFINITIONS) {
        return .{ .resource = "process_definition", .limit = MAX_PROCESS_DEFINITIONS };
    }
    for (config.processes.items) |*process| {
        var command_bytes: usize = 0;
        const values = [_][]const u8{
            process.command,
            process.command_windows orelse "",
            process.command_unix orelse "",
        };
        for (values) |value| {
            command_bytes = std.math.add(usize, command_bytes, value.len) catch
                return .{ .resource = "process_definition", .limit = MAX_PROCESS_COMMAND_BYTES };
        }
        for ([_][]const []u8{ process.argv.items, process.argv_windows.items, process.argv_unix.items }) |argv| {
            for (argv) |value| {
                command_bytes = std.math.add(usize, command_bytes, value.len) catch
                    return .{ .resource = "process_definition", .limit = MAX_PROCESS_COMMAND_BYTES };
            }
        }
        if (command_bytes > MAX_PROCESS_COMMAND_BYTES) {
            return .{ .resource = "process_definition", .limit = MAX_PROCESS_COMMAND_BYTES };
        }
    }
    return null;
}

pub fn loadFromProject(allocator: std.mem.Allocator, project_path: []const u8) !?Config {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    for (CONFIG_FILENAMES) |file_name| {
        const path = try std.fs.path.join(allocator, &.{ project_path, file_name });
        errdefer allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        defer allocator.free(content);

        const config = try parse(allocator, content, path);
        allocator.free(path);
        return config;
    }
    return null;
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8, source_path: []const u8) !Config {
    const root = try toml.parseSlice(allocator, content, null);
    defer toml.deinit(root, allocator);
    // Validate the complete workspace manifest even when only loading its stack.
    var workspace = try folders.parse(allocator, content);
    defer workspace.deinit(allocator);
    var config: Config = .{ .path = try allocator.dupe(u8, source_path) };
    errdefer config.deinit(allocator);
    inline for (.{ "processes", "agents" }, .{ ProcessKind.process, ProcessKind.agent }) |section, kind| {
        if (root.get(section)) |value| {
            if (value != .table) return error.InvalidStackConfig;
            var entries = value.table.iterator();
            while (entries.next()) |entry| {
                if (entry.value_ptr.* != .table) return error.InvalidStackConfig;
                const table = entry.value_ptr.table;
                var pending = true;
                const name = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer if (pending) allocator.free(name);
                const command = try allocator.dupe(u8, try folders.string(table, "command", ""));
                errdefer if (pending) allocator.free(command);
                const cwd = try allocator.dupe(u8, try folders.string(table, "cwd", "."));
                errdefer if (pending) allocator.free(cwd);
                try config.processes.append(allocator, .{
                    .name = name,
                    .command = command,
                    .cwd = cwd,
                    .kind = kind,
                    .restart = try enumValue(RestartPolicy, table, "restart", .manual),
                    .revive = try enumValue(RevivePolicy, table, "revive", .attach_or_create),
                    .provider = if (table.contains("provider")) try enumValue(AgentProvider, table, "provider", .other) else null,
                    .notify = try folders.boolean(table, "notify", false),
                    .mcp = try folders.boolean(table, "mcp", false),
                    .hooks = try folders.boolean(table, "hooks", false),
                });
                pending = false;
                const process = &config.processes.items[config.processes.items.len - 1];
                inline for (.{ "command_windows", "command_unix" }) |key| {
                    if (table.contains(key)) @field(process, key) = try allocator.dupe(u8, try folders.string(table, key, ""));
                }
                inline for (.{ "argv", "argv_windows", "argv_unix", "watch", "resources" }) |key| {
                    if (table.get(key)) |array| {
                        if (array != .array) return error.InvalidStackConfig;
                        for (array.array.items) |item| {
                            if (item != .string) return error.InvalidStackConfig;
                            const owned = try allocator.dupe(u8, item.string);
                            errdefer allocator.free(owned);
                            try @field(process, key).append(allocator, owned);
                        }
                    }
                }
                if (!process.hasAnyLaunch()) return error.InvalidStackConfig;
            }
        }
    }
    return config;
}

fn enumValue(comptime T: type, table: *const toml.Table, key: []const u8, default: T) !T {
    return std.meta.stringToEnum(T, try folders.string(table, key, @tagName(default))) orelse error.InvalidStackConfig;
}

test "TOML stack supports strings arrays providers and platform overrides" {
    var config = try parse(std.testing.allocator,
        \\version = 1
        \\[processes.web]
        \\command = "npm run dev # keep hash"
        \\command_windows = 'pwsh.exe scripts\serve.ps1'
        \\resources = ["build", "port:3000"]
        \\watch = ["src/**"]
        \\restart = "on_crash"
        \\[agents.codex]
        \\provider = "codex"
        \\argv = ["codex", "--add-dir", "a folder"]
        \\notify = true
        \\hooks = true
    , "verde.toml");
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), config.processes.items.len);
    try std.testing.expectEqualStrings("npm run dev # keep hash", config.processes.items[0].launchForOs(.linux).?.command);
    try std.testing.expectEqualStrings("pwsh.exe scripts\\serve.ps1", config.processes.items[0].launchForOs(.windows).?.command);
    try std.testing.expectEqualStrings("port:3000", config.processes.items[0].resources.items[1]);
    try std.testing.expectEqual(RestartPolicy.on_crash, config.processes.items[0].restart);
    try std.testing.expectEqualStrings("a folder", config.processes.items[1].launchForOs(.linux).?.argv[2]);
    try std.testing.expect(config.processes.items[1].hooks);
    try std.testing.expectEqual(AgentProvider.codex, config.processes.items[1].provider.?);
}

test "stack rejects invalid types missing launches and YAML" {
    inline for (.{ "[processes.x]\ncommand = 42", "[agents.x]\nprovider = \"claude\"", "processes:\n  x:\n    command: test" }) |content| {
        if (parse(std.testing.allocator, content, "verde.toml")) |result| {
            var owned = result;
            owned.deinit(std.testing.allocator);
            return error.ExpectedInvalidConfig;
        } else |_| {}
    }
}

test "definition bounds validator names the broken limit" {
    const a = std.testing.allocator;
    const command = try a.alloc(u8, MAX_PROCESS_COMMAND_BYTES + 1);
    defer a.free(command);
    @memset(command, 'x');
    const content = try std.fmt.allocPrint(a, "[processes.x]\ncommand = \"{s}\"", .{command});
    defer a.free(content);
    var config = try parse(a, content, "verde.toml");
    defer config.deinit(a);
    try std.testing.expectEqualStrings("process_definition", validateDefinitionBounds(&config).?.resource);
}
