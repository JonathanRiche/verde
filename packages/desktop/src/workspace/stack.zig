//! Project-local managed stack config parsing.

const std = @import("std");

pub const CONFIG_FILENAMES = [_][]const u8{ "verde.yml", "verde.yaml" };

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

const Section = enum {
    none,
    processes,
    agents,
};

const ListField = enum {
    none,
    watch,
    resources,
    argv,
    argv_windows,
    argv_unix,
};

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
    var config: Config = .{ .path = try allocator.dupe(u8, source_path) };
    errdefer config.deinit(allocator);

    var section: Section = .none;
    var current_index: ?usize = null;
    var list_field: ListField = .none;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line_without_comment = stripYamlComment(raw_line);
        if (std.mem.trim(u8, line_without_comment, " \t\r").len == 0) continue;

        const indent = leadingSpaces(line_without_comment);
        const trimmed = std.mem.trim(u8, line_without_comment, " \t\r");

        if (indent == 0) {
            current_index = null;
            list_field = .none;
            if (std.mem.eql(u8, trimmed, "processes:")) {
                section = .processes;
            } else if (std.mem.eql(u8, trimmed, "agents:")) {
                section = .agents;
            } else {
                section = .none;
            }
            continue;
        }

        if ((section == .processes or section == .agents) and indent == 2 and std.mem.endsWith(u8, trimmed, ":")) {
            const raw_name = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\"'");
            if (raw_name.len == 0) return error.InvalidStackConfig;
            try config.processes.append(allocator, .{
                .name = try allocator.dupe(u8, raw_name),
                .kind = if (section == .agents) .agent else .process,
                .command = try allocator.dupe(u8, ""),
                .command_windows = null,
                .command_unix = null,
                .argv = .empty,
                .argv_windows = .empty,
                .argv_unix = .empty,
                .cwd = try allocator.dupe(u8, "."),
                .restart = if (section == .agents) .manual else .manual,
                .provider = null,
                .revive = .attach_or_create,
                .notify = false,
                .mcp = false,
                .hooks = false,
                .watch = .empty,
                .resources = .empty,
            });
            current_index = config.processes.items.len - 1;
            list_field = .none;
            continue;
        }

        const index = current_index orelse continue;
        var process = &config.processes.items[index];
        if (indent >= 4 and list_field != .none and std.mem.startsWith(u8, trimmed, "-")) {
            const value = try parseScalarAlloc(allocator, std.mem.trim(u8, trimmed[1..], " \t\r"));
            errdefer allocator.free(value);
            switch (list_field) {
                .watch => try process.watch.append(allocator, value),
                .resources => try process.resources.append(allocator, value),
                .argv => try process.argv.append(allocator, value),
                .argv_windows => try process.argv_windows.append(allocator, value),
                .argv_unix => try process.argv_unix.append(allocator, value),
                .none => unreachable,
            }
            continue;
        }

        if (indent < 4) continue;
        const colon_index = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon_index], " \t\r");
        const raw_value = std.mem.trim(u8, trimmed[colon_index + 1 ..], " \t\r");
        list_field = .none;

        if (std.mem.eql(u8, key, "command")) {
            const value = try parseScalarAlloc(allocator, raw_value);
            allocator.free(process.command);
            process.command = value;
        } else if (std.mem.eql(u8, key, "command_windows")) {
            const value = try parseScalarAlloc(allocator, raw_value);
            if (process.command_windows) |old| allocator.free(old);
            process.command_windows = value;
        } else if (std.mem.eql(u8, key, "command_unix")) {
            const value = try parseScalarAlloc(allocator, raw_value);
            if (process.command_unix) |old| allocator.free(old);
            process.command_unix = value;
        } else if (std.mem.eql(u8, key, "argv")) {
            if (raw_value.len != 0) return error.InvalidStackConfig;
            list_field = .argv;
        } else if (std.mem.eql(u8, key, "argv_windows")) {
            if (raw_value.len != 0) return error.InvalidStackConfig;
            list_field = .argv_windows;
        } else if (std.mem.eql(u8, key, "argv_unix")) {
            if (raw_value.len != 0) return error.InvalidStackConfig;
            list_field = .argv_unix;
        } else if (std.mem.eql(u8, key, "cwd")) {
            const value = try parseScalarAlloc(allocator, raw_value);
            allocator.free(process.cwd);
            process.cwd = value;
        } else if (std.mem.eql(u8, key, "restart")) {
            process.restart = parseRestart(raw_value) orelse return error.InvalidStackConfig;
        } else if (std.mem.eql(u8, key, "provider")) {
            process.provider = parseProvider(raw_value) orelse return error.InvalidStackConfig;
        } else if (std.mem.eql(u8, key, "revive")) {
            process.revive = parseRevive(raw_value) orelse return error.InvalidStackConfig;
        } else if (std.mem.eql(u8, key, "notify")) {
            process.notify = parseBool(raw_value) orelse return error.InvalidStackConfig;
        } else if (std.mem.eql(u8, key, "mcp")) {
            process.mcp = parseBool(raw_value) orelse return error.InvalidStackConfig;
        } else if (std.mem.eql(u8, key, "hooks")) {
            process.hooks = parseBool(raw_value) orelse return error.InvalidStackConfig;
        } else if (std.mem.eql(u8, key, "watch")) {
            if (raw_value.len != 0) return error.InvalidStackConfig;
            list_field = .watch;
        } else if (std.mem.eql(u8, key, "resources")) {
            if (raw_value.len != 0) return error.InvalidStackConfig;
            list_field = .resources;
        }
    }

    var index: usize = 0;
    while (index < config.processes.items.len) {
        if (config.processes.items[index].hasAnyLaunch()) {
            index += 1;
            continue;
        }
        var removed = config.processes.orderedRemove(index);
        removed.deinit(allocator);
    }

    return config;
}

fn stripYamlComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    for (line, 0..) |byte, index| {
        if (byte == '\'' and !in_double) in_single = !in_single;
        if (byte == '"' and !in_single) in_double = !in_double;
        if (byte == '#' and !in_single and !in_double) return line[0..index];
    }
    return line;
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn parseScalarAlloc(allocator: std.mem.Allocator, raw_value: []const u8) ![]u8 {
    var value = std.mem.trim(u8, raw_value, " \t\r");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        value = value[1 .. value.len - 1];
    }
    return allocator.dupe(u8, value);
}

fn parseRestart(raw_value: []const u8) ?RestartPolicy {
    const value = std.mem.trim(u8, raw_value, " \t\r\"'");
    if (std.mem.eql(u8, value, "manual")) return .manual;
    if (std.mem.eql(u8, value, "on_crash")) return .on_crash;
    if (std.mem.eql(u8, value, "always")) return .always;
    return null;
}

fn parseProvider(raw_value: []const u8) ?AgentProvider {
    const value = std.mem.trim(u8, raw_value, " \t\r\"'");
    if (std.mem.eql(u8, value, "codex")) return .codex;
    if (std.mem.eql(u8, value, "claude")) return .claude;
    if (std.mem.eql(u8, value, "opencode")) return .opencode;
    if (std.mem.eql(u8, value, "cursor")) return .cursor;
    if (std.mem.eql(u8, value, "grok")) return .grok;
    if (std.mem.eql(u8, value, "amp")) return .amp;
    if (std.mem.eql(u8, value, "other")) return .other;
    return null;
}

fn parseRevive(raw_value: []const u8) ?RevivePolicy {
    const value = std.mem.trim(u8, raw_value, " \t\r\"'");
    if (std.mem.eql(u8, value, "attach_or_create")) return .attach_or_create;
    if (std.mem.eql(u8, value, "attach_only")) return .attach_only;
    if (std.mem.eql(u8, value, "restart")) return .restart;
    if (std.mem.eql(u8, value, "manual")) return .manual;
    return null;
}

fn parseBool(raw_value: []const u8) ?bool {
    const value = std.mem.trim(u8, raw_value, " \t\r\"'");
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

test "parse verde stack config" {
    const content =
        \\version: 1
        \\processes:
        \\  web:
        \\    command: "npm run dev"
        \\    cwd: "."
        \\    restart: on_crash
        \\    resources:
        \\      - "build"
        \\      - "port:3000"
        \\    watch:
        \\      - "src/**"
        \\agents:
        \\  codex:
        \\    provider: codex
        \\    command: "codex"
        \\    revive: attach_or_create
        \\    notify: true
        \\    mcp: true
        \\    hooks: false
        \\
    ;
    var config = try parse(std.testing.allocator, content, "verde.yml");
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), config.processes.items.len);
    try std.testing.expectEqualStrings("web", config.processes.items[0].name);
    try std.testing.expectEqual(ProcessKind.process, config.processes.items[0].kind);
    try std.testing.expectEqual(RestartPolicy.on_crash, config.processes.items[0].restart);
    try std.testing.expectEqualStrings("build", config.processes.items[0].resources.items[0]);
    try std.testing.expectEqualStrings("port:3000", config.processes.items[0].resources.items[1]);
    try std.testing.expectEqualStrings("src/**", config.processes.items[0].watch.items[0]);
    try std.testing.expectEqualStrings("codex", config.processes.items[1].name);
    try std.testing.expectEqual(ProcessKind.agent, config.processes.items[1].kind);
    try std.testing.expectEqual(AgentProvider.codex, config.processes.items[1].provider.?);
    try std.testing.expectEqual(RevivePolicy.attach_or_create, config.processes.items[1].revive);
    try std.testing.expect(config.processes.items[1].notify);
    try std.testing.expect(config.processes.items[1].mcp);
    try std.testing.expect(!config.processes.items[1].hooks);
}

test "parse amp agent provider" {
    const content =
        \\version: 1
        \\agents:
        \\  amp:
        \\    provider: amp
        \\    command: "amp"
        \\
    ;
    var config = try parse(std.testing.allocator, content, "verde.yml");
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), config.processes.items.len);
    try std.testing.expectEqualStrings("amp", config.processes.items[0].name);
    try std.testing.expectEqual(ProcessKind.agent, config.processes.items[0].kind);
    try std.testing.expectEqual(AgentProvider.amp, config.processes.items[0].provider.?);
}

test "parse grok agent provider" {
    const content =
        \\version: 1
        \\agents:
        \\  grok:
        \\    provider: grok
        \\    command: "grok --no-auto-update"
        \\
    ;
    var config = try parse(std.testing.allocator, content, "verde.yml");
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), config.processes.items.len);
    try std.testing.expectEqualStrings("grok", config.processes.items[0].name);
    try std.testing.expectEqual(ProcessKind.agent, config.processes.items[0].kind);
    try std.testing.expectEqual(AgentProvider.grok, config.processes.items[0].provider.?);
}

test "platform commands override legacy command without changing Unix semantics" {
    const content =
        \\version: 1
        \\processes:
        \\  web:
        \\    command: "npm run dev"
        \\    command_windows: "npm.cmd run dev:windows"
        \\    command_unix: "exec npm run dev:unix"
        \\
    ;
    var config = try parse(std.testing.allocator, content, "verde.yml");
    defer config.deinit(std.testing.allocator);

    const definition = &config.processes.items[0];
    try std.testing.expectEqualStrings("npm.cmd run dev:windows", definition.launchForOs(.windows).?.command);
    try std.testing.expectEqualStrings("exec npm run dev:unix", definition.launchForOs(.linux).?.command);
    try std.testing.expectEqualStrings("exec npm run dev:unix", definition.launchForOs(.macos).?.command);
}

test "structured argv preserves spaces and supports platform overrides" {
    const content =
        \\version: 1
        \\processes:
        \\  worker:
        \\    argv:
        \\      - "node"
        \\      - "scripts/worker task.mjs"
        \\      - "--label=client repo"
        \\    argv_windows:
        \\      - "node.exe"
        \\      - "scripts\worker task.mjs"
        \\
    ;
    var config = try parse(std.testing.allocator, content, "verde.yml");
    defer config.deinit(std.testing.allocator);

    const windows_launch = config.processes.items[0].launchForOs(.windows).?.argv;
    try std.testing.expectEqual(@as(usize, 2), windows_launch.len);
    try std.testing.expectEqualStrings("node.exe", windows_launch[0]);
    try std.testing.expectEqualStrings("scripts\\worker task.mjs", windows_launch[1]);

    const unix_launch = config.processes.items[0].launchForOs(.linux).?.argv;
    try std.testing.expectEqual(@as(usize, 3), unix_launch.len);
    try std.testing.expectEqualStrings("scripts/worker task.mjs", unix_launch[1]);
    try std.testing.expectEqualStrings("--label=client repo", unix_launch[2]);
}

test "platform-only managed process is retained" {
    const content =
        \\processes:
        \\  windows-only:
        \\    command_windows: "pwsh.exe -File scripts\serve.ps1"
        \\
    ;
    var config = try parse(std.testing.allocator, content, "verde.yml");
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), config.processes.items.len);
    try std.testing.expect(config.processes.items[0].launchForOs(.linux) == null);
    try std.testing.expectEqualStrings("pwsh.exe -File scripts\\serve.ps1", config.processes.items[0].launchForOs(.windows).?.command);
}

test "definition bounds validator names the broken limit" {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    try content.appendSlice(
        std.testing.allocator,
        "processes:\n  oversized:\n    command: \"",
    );
    try content.appendNTimes(std.testing.allocator, 'x', MAX_PROCESS_COMMAND_BYTES + 1);
    try content.appendSlice(std.testing.allocator, "\"\n");
    var config = try parse(std.testing.allocator, content.items, "verde.yml");
    defer config.deinit(std.testing.allocator);
    const violation = validateDefinitionBounds(&config) orelse return error.ExpectedBoundsViolation;
    try std.testing.expectEqualStrings("process_definition", violation.resource);
    try std.testing.expectEqual(MAX_PROCESS_COMMAND_BYTES, violation.limit);
}
