//! Project-local managed stack config parsing.

const std = @import("std");

pub const CONFIG_FILENAMES = [_][]const u8{ "verde.yml", "verde.yaml" };

pub const ProcessKind = enum {
    process,
    agent,
};

pub const RestartPolicy = enum {
    manual,
    on_crash,
    always,
};

pub const ProcessDefinition = struct {
    name: []u8,
    kind: ProcessKind,
    command: []u8,
    cwd: []u8,
    restart: RestartPolicy,
    watch: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *ProcessDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        allocator.free(self.cwd);
        for (self.watch.items) |pattern| allocator.free(pattern);
        self.watch.deinit(allocator);
    }
};

pub const Config = struct {
    path: []u8,
    processes: std.ArrayList(ProcessDefinition) = .empty,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.processes.items) |*process| process.deinit(allocator);
        self.processes.deinit(allocator);
    }
};

const Section = enum {
    none,
    processes,
    agents,
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
    var in_watch_list = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line_without_comment = stripYamlComment(raw_line);
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;

        const indent = leadingSpaces(line);
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (indent == 0) {
            current_index = null;
            in_watch_list = false;
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
                .cwd = try allocator.dupe(u8, "."),
                .restart = if (section == .agents) .manual else .manual,
                .watch = .empty,
            });
            current_index = config.processes.items.len - 1;
            in_watch_list = false;
            continue;
        }

        const index = current_index orelse continue;
        var process = &config.processes.items[index];
        if (indent >= 4 and in_watch_list and std.mem.startsWith(u8, trimmed, "-")) {
            const value = try parseScalarAlloc(allocator, std.mem.trim(u8, trimmed[1..], " \t\r"));
            errdefer allocator.free(value);
            try process.watch.append(allocator, value);
            continue;
        }

        if (indent < 4) continue;
        const colon_index = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon_index], " \t\r");
        const raw_value = std.mem.trim(u8, trimmed[colon_index + 1 ..], " \t\r");
        in_watch_list = std.mem.eql(u8, key, "watch");

        if (std.mem.eql(u8, key, "command")) {
            const value = try parseScalarAlloc(allocator, raw_value);
            allocator.free(process.command);
            process.command = value;
        } else if (std.mem.eql(u8, key, "cwd")) {
            const value = try parseScalarAlloc(allocator, raw_value);
            allocator.free(process.cwd);
            process.cwd = value;
        } else if (std.mem.eql(u8, key, "restart")) {
            process.restart = parseRestart(raw_value) orelse return error.InvalidStackConfig;
        }
    }

    var index: usize = 0;
    while (index < config.processes.items.len) {
        if (std.mem.trim(u8, config.processes.items[index].command, " \t\r").len != 0) {
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

test "parse verde stack config" {
    const content =
        \\version: 1
        \\processes:
        \\  web:
        \\    command: "npm run dev"
        \\    cwd: "."
        \\    restart: on_crash
        \\    watch:
        \\      - "src/**"
        \\agents:
        \\  codex:
        \\    command: "codex"
        \\
    ;
    var config = try parse(std.testing.allocator, content, "verde.yml");
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), config.processes.items.len);
    try std.testing.expectEqualStrings("web", config.processes.items[0].name);
    try std.testing.expectEqual(ProcessKind.process, config.processes.items[0].kind);
    try std.testing.expectEqual(RestartPolicy.on_crash, config.processes.items[0].restart);
    try std.testing.expectEqualStrings("src/**", config.processes.items[0].watch.items[0]);
    try std.testing.expectEqualStrings("codex", config.processes.items[1].name);
    try std.testing.expectEqual(ProcessKind.agent, config.processes.items[1].kind);
}
