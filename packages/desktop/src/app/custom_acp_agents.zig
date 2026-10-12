//! User-defined ACP agents (`chat.custom_acp_agents` in verde.json).
//!
//! Each entry names a command that speaks the Agent Client Protocol over
//! stdio, mirroring Zed's custom `agent_servers` (command, args, env). The
//! GUI edits the list through `AppConfig`; the daemon resolves an entry by id
//! when a `custom_acp` thread runs. Threads carry the agent id in their model
//! ref (`<agent-id>` or `<agent-id>/<agent model>`), so neither the store nor
//! the wire protocol needs a separate column. Dependency-light on purpose:
//! both the GUI and the daemon import it.

const std = @import("std");
const platform_paths = @import("platform_paths");

const log = std.log.scoped(.custom_acp_agents);

pub const CONFIG_SECTION = "chat";
pub const CONFIG_KEY = "custom_acp_agents";
pub const MAX_ID_LEN = 48;
pub const MAX_AGENTS = 32;

pub const EnvVar = struct {
    name: []u8,
    value: []u8,
};

pub const Agent = struct {
    /// Stable lowercase slug (`[a-z0-9-]`); never contains '/'.
    id: []u8,
    name: []u8,
    command: []u8,
    args: []const []u8 = &.{},
    env: []const EnvVar = &.{},

    pub fn deinit(self: *Agent, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.command);
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
        for (self.env) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        allocator.free(self.env);
        self.* = undefined;
    }

    pub fn clone(self: Agent, allocator: std.mem.Allocator) !Agent {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const command = try allocator.dupe(u8, self.command);
        errdefer allocator.free(command);
        const args = try dupeArgs(allocator, self.args);
        errdefer freeArgs(allocator, args);
        const env = try dupeEnv(allocator, self.env);
        return .{ .id = id, .name = name, .command = command, .args = args, .env = env };
    }
};

pub fn freeAgents(allocator: std.mem.Allocator, agents: []Agent) void {
    for (agents) |*agent| agent.deinit(allocator);
    allocator.free(agents);
}

pub fn findById(agents: []const Agent, id: []const u8) ?*const Agent {
    for (agents) |*agent| {
        if (std.mem.eql(u8, agent.id, id)) return agent;
    }
    return null;
}

pub const ModelRef = struct {
    agent_id: []const u8,
    /// Agent-side model id; null defers to the agent's own default.
    model: ?[]const u8 = null,
};

/// Splits a thread model ref `<agent-id>[/<model>]`. Agent ids never contain
/// '/', so agent model ids may (e.g. `anthropic/claude-sonnet`).
pub fn parseModelRef(model_ref: []const u8) ?ModelRef {
    const trimmed = std.mem.trim(u8, model_ref, " \t\r\n");
    if (trimmed.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return .{ .agent_id = trimmed };
    if (slash == 0) return null;
    const model = trimmed[slash + 1 ..];
    return .{ .agent_id = trimmed[0..slash], .model = if (model.len == 0) null else model };
}

/// Lowercase slug of `name`, made unique against `existing` with a numeric
/// suffix. Caller owns the result.
pub fn uniqueIdAlloc(allocator: std.mem.Allocator, name: []const u8, existing: []const Agent) ![]u8 {
    var base_buf: [MAX_ID_LEN]u8 = undefined;
    var len: usize = 0;
    var pending_dash = false;
    for (name) |byte| {
        const lower = std.ascii.toLower(byte);
        const keep = std.ascii.isAlphanumeric(lower);
        if (!keep) {
            pending_dash = len > 0;
            continue;
        }
        if (pending_dash and len + 1 < base_buf.len - 4) {
            base_buf[len] = '-';
            len += 1;
        }
        pending_dash = false;
        if (len >= base_buf.len - 4) break;
        base_buf[len] = lower;
        len += 1;
    }
    const base = if (len == 0) "agent" else base_buf[0..len];
    if (findById(existing, base) == null) return allocator.dupe(u8, base);
    var suffix: usize = 2;
    while (suffix < 1000) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ base, suffix });
        if (findById(existing, candidate) == null) return candidate;
        allocator.free(candidate);
    }
    return error.TooManyAgents;
}

/// Splits a command line into argv with POSIX-shell-like quoting: whitespace
/// separates words, single quotes are literal, double quotes allow `\"` and
/// `\\`, and a backslash outside quotes escapes the next byte. No expansion.
pub fn splitCommandLineAlloc(allocator: std.mem.Allocator, line: []const u8) ![][]u8 {
    var words: std.ArrayList([]u8) = .empty;
    errdefer {
        for (words.items) |word| allocator.free(word);
        words.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var in_word = false;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const byte = line[index];
        switch (byte) {
            ' ', '\t', '\r', '\n' => {
                if (in_word) {
                    try words.append(allocator, try current.toOwnedSlice(allocator));
                    in_word = false;
                }
            },
            '\'' => {
                in_word = true;
                const end = std.mem.indexOfScalarPos(u8, line, index + 1, '\'') orelse return error.UnterminatedQuote;
                try current.appendSlice(allocator, line[index + 1 .. end]);
                index = end;
            },
            '"' => {
                in_word = true;
                index += 1;
                while (true) : (index += 1) {
                    if (index >= line.len) return error.UnterminatedQuote;
                    const inner = line[index];
                    if (inner == '"') break;
                    if (inner == '\\' and index + 1 < line.len and (line[index + 1] == '"' or line[index + 1] == '\\')) {
                        index += 1;
                        try current.append(allocator, line[index]);
                        continue;
                    }
                    try current.append(allocator, inner);
                }
            },
            '\\' => {
                in_word = true;
                if (index + 1 < line.len) {
                    index += 1;
                    try current.append(allocator, line[index]);
                }
            },
            else => {
                in_word = true;
                try current.append(allocator, byte);
            },
        }
    }
    if (in_word) try words.append(allocator, try current.toOwnedSlice(allocator));
    return words.toOwnedSlice(allocator);
}

/// Renders argv back into a command line `splitCommandLineAlloc` round-trips.
pub fn joinCommandLineAlloc(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeShellWord(&out.writer, command);
    for (args) |arg| {
        try out.writer.writeByte(' ');
        try writeShellWord(&out.writer, arg);
    }
    return out.toOwnedSlice();
}

fn writeShellWord(writer: *std.Io.Writer, word: []const u8) !void {
    const plain = word.len > 0 and for (word) |byte| {
        if (std.ascii.isWhitespace(byte) or byte == '\'' or byte == '"' or byte == '\\') break false;
    } else true;
    if (plain) return writer.writeAll(word);
    try writer.writeByte('\'');
    for (word) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

/// Parses `KEY=VALUE` pairs separated by whitespace or newlines (values may
/// be quoted like command-line words).
pub fn parseEnvLineAlloc(allocator: std.mem.Allocator, line: []const u8) ![]EnvVar {
    const words = try splitCommandLineAlloc(allocator, line);
    defer {
        for (words) |word| allocator.free(word);
        allocator.free(words);
    }
    var env: std.ArrayList(EnvVar) = .empty;
    errdefer {
        for (env.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        env.deinit(allocator);
    }
    for (words) |word| {
        const eq = std.mem.indexOfScalar(u8, word, '=') orelse return error.InvalidEnv;
        if (eq == 0) return error.InvalidEnv;
        const name = try allocator.dupe(u8, word[0..eq]);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, word[eq + 1 ..]);
        errdefer allocator.free(value);
        try env.append(allocator, .{ .name = name, .value = value });
    }
    return env.toOwnedSlice(allocator);
}

pub fn joinEnvLineAlloc(allocator: std.mem.Allocator, env: []const EnvVar) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (env, 0..) |entry, index| {
        if (index > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(entry.name);
        try out.writer.writeByte('=');
        if (entry.value.len == 0) continue;
        try writeShellWord(&out.writer, entry.value);
    }
    return out.toOwnedSlice();
}

/// Parses the agent list from the `chat` section value. Invalid entries are
/// skipped with a warning so one typo cannot hide every other agent.
pub fn parseListAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]Agent {
    if (value != .array) {
        log.warn("chat.custom_acp_agents must be an array", .{});
        return allocator.alloc(Agent, 0);
    }
    var agents: std.ArrayList(Agent) = .empty;
    errdefer {
        for (agents.items) |*agent| agent.deinit(allocator);
        agents.deinit(allocator);
    }
    for (value.array.items) |entry| {
        if (agents.items.len >= MAX_AGENTS) break;
        var agent = (parseAgentAlloc(allocator, entry, agents.items) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                log.warn("skipping invalid custom ACP agent: {s}", .{@errorName(err)});
                continue;
            },
        });
        errdefer agent.deinit(allocator);
        try agents.append(allocator, agent);
    }
    return agents.toOwnedSlice(allocator);
}

fn parseAgentAlloc(allocator: std.mem.Allocator, value: std.json.Value, existing: []const Agent) !Agent {
    if (value != .object) return error.InvalidAgent;
    const raw_name = stringField(value, "name") orelse stringField(value, "id") orelse return error.MissingName;
    const name_trimmed = std.mem.trim(u8, raw_name, &std.ascii.whitespace);
    if (name_trimmed.len == 0) return error.MissingName;
    const raw_command = stringField(value, "command") orelse return error.MissingCommand;
    const command_trimmed = std.mem.trim(u8, raw_command, &std.ascii.whitespace);
    if (command_trimmed.len == 0) return error.MissingCommand;

    const id = blk: {
        if (stringField(value, "id")) |raw_id| {
            if (isValidId(raw_id) and findById(existing, raw_id) == null) break :blk try allocator.dupe(u8, raw_id);
        }
        break :blk try uniqueIdAlloc(allocator, name_trimmed, existing);
    };
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, name_trimmed);
    errdefer allocator.free(name);
    const command = try allocator.dupe(u8, command_trimmed);
    errdefer allocator.free(command);

    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    if (value.object.get("args")) |args_value| {
        if (args_value != .array) return error.InvalidArgs;
        for (args_value.array.items) |arg| {
            if (arg != .string) return error.InvalidArgs;
            try args.append(allocator, try allocator.dupe(u8, arg.string));
        }
    }

    var env: std.ArrayList(EnvVar) = .empty;
    errdefer {
        for (env.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        env.deinit(allocator);
    }
    if (value.object.get("env")) |env_value| {
        if (env_value != .object) return error.InvalidEnv;
        var iterator = env_value.object.iterator();
        while (iterator.next()) |field| {
            if (field.key_ptr.*.len == 0 or field.value_ptr.* != .string) return error.InvalidEnv;
            const env_name = try allocator.dupe(u8, field.key_ptr.*);
            errdefer allocator.free(env_name);
            const env_value_owned = try allocator.dupe(u8, field.value_ptr.*.string);
            errdefer allocator.free(env_value_owned);
            try env.append(allocator, .{ .name = env_name, .value = env_value_owned });
        }
    }

    const owned_args = try args.toOwnedSlice(allocator);
    errdefer freeArgs(allocator, owned_args);
    return .{
        .id = id,
        .name = name,
        .command = command,
        .args = owned_args,
        .env = try env.toOwnedSlice(allocator),
    };
}

/// JSON array value for `chat.custom_acp_agents`, allocated in `allocator`
/// (an arena owning the surrounding config tree).
pub fn toJsonValue(allocator: std.mem.Allocator, agents: []const Agent) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (agents) |agent| {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "id", .{ .string = agent.id });
        try object.put(allocator, "name", .{ .string = agent.name });
        try object.put(allocator, "command", .{ .string = agent.command });
        var args = std.json.Array.init(allocator);
        for (agent.args) |arg| try args.append(.{ .string = arg });
        try object.put(allocator, "args", .{ .array = args });
        var env: std.json.ObjectMap = .empty;
        for (agent.env) |entry| try env.put(allocator, entry.name, .{ .string = entry.value });
        try object.put(allocator, "env", .{ .object = env });
        try array.append(.{ .object = object });
    }
    return .{ .array = array };
}

/// Reads the agent list straight from verde.json. Used by the daemon, which
/// resolves agents per turn so edits apply without a restart.
pub fn loadFromConfigFileAlloc(allocator: std.mem.Allocator) ![]Agent {
    const path = try platform_paths.configPath(allocator);
    defer allocator.free(path);
    var threaded = std.Io.Threaded.init_single_threaded;
    const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Agent, 0),
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return allocator.alloc(Agent, 0);
    defer parsed.deinit();
    const chat = if (parsed.value == .object) parsed.value.object.get(CONFIG_SECTION) else null;
    const list = if (chat) |section| (if (section == .object) section.object.get(CONFIG_KEY) else null) else null;
    return parseListAlloc(allocator, list orelse return allocator.alloc(Agent, 0));
}

pub fn isValidId(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_ID_LEN) return false;
    for (id) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-' or byte == '_')) return false;
    }
    return true;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn dupeArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []u8 {
    const out = try allocator.alloc([]u8, args.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |arg| allocator.free(arg);
        allocator.free(out);
    }
    for (args, 0..) |arg, index| {
        out[index] = try allocator.dupe(u8, arg);
        done += 1;
    }
    return out;
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn dupeEnv(allocator: std.mem.Allocator, env: []const EnvVar) ![]const EnvVar {
    const out = try allocator.alloc(EnvVar, env.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        allocator.free(out);
    }
    for (env, 0..) |entry, index| {
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        out[index] = .{ .name = name, .value = try allocator.dupe(u8, entry.value) };
        done += 1;
    }
    return out;
}

test "parseModelRef splits agent id from agent model" {
    const plain = parseModelRef("gemini").?;
    try std.testing.expectEqualStrings("gemini", plain.agent_id);
    try std.testing.expect(plain.model == null);
    const nested = parseModelRef("my-agent/anthropic/claude").?;
    try std.testing.expectEqualStrings("my-agent", nested.agent_id);
    try std.testing.expectEqualStrings("anthropic/claude", nested.model.?);
    try std.testing.expect(parseModelRef("") == null);
    try std.testing.expect(parseModelRef("/x") == null);
}

test "splitCommandLineAlloc handles quotes and escapes" {
    const allocator = std.testing.allocator;
    const words = try splitCommandLineAlloc(allocator, "npx -y '@scope/agent acp' --flag=\"a \\\"b\\\"\" c\\ d");
    defer {
        for (words) |word| allocator.free(word);
        allocator.free(words);
    }
    try std.testing.expectEqual(@as(usize, 5), words.len);
    try std.testing.expectEqualStrings("npx", words[0]);
    try std.testing.expectEqualStrings("@scope/agent acp", words[2]);
    try std.testing.expectEqualStrings("--flag=a \"b\"", words[3]);
    try std.testing.expectEqualStrings("c d", words[4]);
    try std.testing.expectError(error.UnterminatedQuote, splitCommandLineAlloc(allocator, "a 'b"));

    const joined = try joinCommandLineAlloc(allocator, words[0], words[1..]);
    defer allocator.free(joined);
    const again = try splitCommandLineAlloc(allocator, joined);
    defer {
        for (again) |word| allocator.free(word);
        allocator.free(again);
    }
    try std.testing.expectEqual(words.len, again.len);
    for (words, again) |left, right| try std.testing.expectEqualStrings(left, right);
}

test "parseListAlloc validates entries and derives unique ids" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[{"name":"My Agent","command":"node","args":["agent.js","--acp"],"env":{"TOKEN":"x"}},
        \\ {"name":"My Agent","command":"other"},
        \\ {"name":"No command"},
        \\ {"id":"Bad/Id","name":"Named","command":"bin"}]
    , .{});
    defer parsed.deinit();
    const agents = try parseListAlloc(allocator, parsed.value);
    defer freeAgents(allocator, agents);
    try std.testing.expectEqual(@as(usize, 3), agents.len);
    try std.testing.expectEqualStrings("my-agent", agents[0].id);
    try std.testing.expectEqualStrings("my-agent-2", agents[1].id);
    try std.testing.expectEqualStrings("named", agents[2].id);
    try std.testing.expectEqualStrings("--acp", agents[0].args[1]);
    try std.testing.expectEqualStrings("TOKEN", agents[0].env[0].name);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const json = try toJsonValue(arena.allocator(), agents);
    const reparsed = try parseListAlloc(allocator, json);
    defer freeAgents(allocator, reparsed);
    try std.testing.expectEqual(agents.len, reparsed.len);
    try std.testing.expectEqualStrings(agents[1].id, reparsed[1].id);
}

test "parseEnvLineAlloc reads KEY=VALUE pairs" {
    const allocator = std.testing.allocator;
    const env = try parseEnvLineAlloc(allocator, "API_KEY=abc  LABEL='two words' EMPTY=");
    defer {
        for (env) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        allocator.free(env);
    }
    try std.testing.expectEqual(@as(usize, 3), env.len);
    try std.testing.expectEqualStrings("two words", env[1].value);
    try std.testing.expectEqualStrings("", env[2].value);
    try std.testing.expectError(error.InvalidEnv, parseEnvLineAlloc(allocator, "NOEQUALS"));
    const joined = try joinEnvLineAlloc(allocator, env);
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("API_KEY=abc LABEL='two words' EMPTY=", joined);
}
