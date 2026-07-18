//! User-scoped MCP registration for agent providers launched inside Verde.

const std = @import("std");
const platform_paths = @import("platform_paths");
const platform_runtime = @import("platform_runtime");
const process_env = @import("process_env.zig");

const log = std.log.scoped(.provider_mcp);

const MANAGED_ENV_KEY = "VERDE_MCP_MANAGED";
const MANAGED_ENV_VALUE = "1";
const CODEX_BLOCK_BEGIN = "# >>> verde managed mcp >>>";
const CODEX_BLOCK_END = "# <<< verde managed mcp <<<";
const MAX_CONFIG_BYTES = 8 * 1024 * 1024;

pub const Provider = enum {
    codex,
    claude,
    cursor,
    opencode,
    amp,
};

const ALL_PROVIDERS = [_]Provider{ .codex, .claude, .cursor, .opencode, .amp };

pub const RegistrationStatus = enum {
    unavailable,
    not_installed,
    installed,
    conflict,
    failed,
};

pub const Summary = struct {
    codex: RegistrationStatus = .unavailable,
    claude: RegistrationStatus = .unavailable,
    cursor: RegistrationStatus = .unavailable,
    opencode: RegistrationStatus = .unavailable,
    amp: RegistrationStatus = .unavailable,

    pub fn forProvider(self: Summary, provider: Provider) RegistrationStatus {
        return switch (provider) {
            .codex => self.codex,
            .claude => self.claude,
            .cursor => self.cursor,
            .opencode => self.opencode,
            .amp => self.amp,
        };
    }

    pub fn detectedCount(self: Summary) usize {
        var count: usize = 0;
        for (ALL_PROVIDERS) |provider| {
            if (self.forProvider(provider) != .unavailable) count += 1;
        }
        return count;
    }

    pub fn installedCount(self: Summary) usize {
        var count: usize = 0;
        for (ALL_PROVIDERS) |provider| {
            if (self.forProvider(provider) == .installed) count += 1;
        }
        return count;
    }

    pub fn conflictCount(self: Summary) usize {
        var count: usize = 0;
        for (ALL_PROVIDERS) |provider| {
            if (self.forProvider(provider) == .conflict) count += 1;
        }
        return count;
    }

    pub fn failedCount(self: Summary) usize {
        var count: usize = 0;
        for (ALL_PROVIDERS) |provider| {
            if (self.forProvider(provider) == .failed) count += 1;
        }
        return count;
    }

    pub fn allDetectedInstalled(self: Summary) bool {
        const detected = self.detectedCount();
        return detected > 0 and self.installedCount() == detected;
    }
};

const JsonShape = enum {
    command_and_args,
    opencode_command_array,
};

const JsonSpec = struct {
    relative_path: []const u8,
    section_key: []const u8,
    environment_key: []const u8,
    shape: JsonShape,
};

const CLAUDE_SPEC: JsonSpec = .{
    .relative_path = ".claude.json",
    .section_key = "mcpServers",
    .environment_key = "env",
    .shape = .command_and_args,
};
const CURSOR_SPEC: JsonSpec = .{
    .relative_path = ".cursor/mcp.json",
    .section_key = "mcpServers",
    .environment_key = "env",
    .shape = .command_and_args,
};
const OPENCODE_SPEC: JsonSpec = .{
    .relative_path = ".config/opencode/opencode.json",
    .section_key = "mcp",
    .environment_key = "environment",
    .shape = .opencode_command_array,
};
const AMP_SPEC: JsonSpec = .{
    .relative_path = ".config/amp/settings.json",
    .section_key = "amp.mcpServers",
    .environment_key = "env",
    .shape = .command_and_args,
};

/// Returns the current registration state for every provider installed on PATH.
pub fn inspect(allocator: std.mem.Allocator) Summary {
    const home = platform_paths.userHome(allocator) catch return .{};
    defer allocator.free(home);
    return inspectAtHome(allocator, home);
}

/// Returns whether Verde owns the selected provider's current MCP entry.
pub fn isInstalled(allocator: std.mem.Allocator, provider: Provider) bool {
    const home = platform_paths.userHome(allocator) catch return false;
    defer allocator.free(home);
    return inspectProviderAtHome(allocator, home, provider) == .installed;
}

/// Installs or refreshes Verde's user-scoped MCP entry for every detected provider.
pub fn install(allocator: std.mem.Allocator) !Summary {
    const home = try platform_paths.userHome(allocator);
    defer allocator.free(home);
    const executable = try platform_runtime.executablePathAlloc(allocator);
    defer allocator.free(executable);
    return installAtHome(allocator, home, executable, detectedProvidersAtHome(allocator, home));
}

/// Removes only MCP entries carrying Verde's ownership marker.
pub fn uninstall(allocator: std.mem.Allocator) !Summary {
    const home = try platform_paths.userHome(allocator);
    defer allocator.free(home);
    var failed = [_]bool{false} ** ALL_PROVIDERS.len;
    for (ALL_PROVIDERS, 0..) |provider, index| {
        removeProviderAtHome(allocator, home, provider) catch |err| {
            log.warn("failed to remove {s} MCP registration: {s}", .{ @tagName(provider), @errorName(err) });
            failed[index] = true;
        };
    }
    var summary = inspectAtHome(allocator, home);
    for (ALL_PROVIDERS, 0..) |provider, index| {
        if (failed[index]) setSummaryStatus(&summary, provider, .failed);
    }
    return summary;
}

fn detectedProvidersAtHome(allocator: std.mem.Allocator, home: []const u8) [5]bool {
    var detected = [5]bool{
        process_env.commandExists("codex"),
        process_env.commandExists("claude"),
        process_env.commandExists("agent") or process_env.commandExists("cursor-agent"),
        process_env.commandExists("opencode"),
        process_env.commandExists("amp"),
    };
    for (ALL_PROVIDERS, 0..) |provider, index| {
        detected[index] = detected[index] or providerConfigExistsAtHome(allocator, home, provider);
    }
    return detected;
}

fn inspectAtHome(allocator: std.mem.Allocator, home: []const u8) Summary {
    const detected = detectedProvidersAtHome(allocator, home);
    var summary: Summary = .{};
    for (ALL_PROVIDERS, 0..) |provider, index| {
        const status = inspectProviderAtHome(allocator, home, provider);
        setSummaryStatus(&summary, provider, if (!detected[index] and status == .not_installed) .unavailable else status);
    }
    return summary;
}

fn providerConfigExistsAtHome(allocator: std.mem.Allocator, home: []const u8, provider: Provider) bool {
    const relative_path = switch (provider) {
        .codex => ".codex/config.toml",
        .claude => CLAUDE_SPEC.relative_path,
        .cursor => CURSOR_SPEC.relative_path,
        .opencode => OPENCODE_SPEC.relative_path,
        .amp => AMP_SPEC.relative_path,
    };
    const path = configPathAlloc(allocator, home, relative_path) catch return false;
    defer allocator.free(path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().access(threaded.io(), path, .{}) catch return false;
    return true;
}

fn installAtHome(
    allocator: std.mem.Allocator,
    home: []const u8,
    executable: []const u8,
    detected: [5]bool,
) !Summary {
    var failed = [_]bool{false} ** ALL_PROVIDERS.len;
    for (ALL_PROVIDERS, 0..) |provider, index| {
        if (!detected[index]) continue;
        installProviderAtHome(allocator, home, executable, provider) catch |err| switch (err) {
            error.ProviderMcpConflict => continue,
            else => {
                log.warn("failed to install {s} MCP registration: {s}", .{ @tagName(provider), @errorName(err) });
                failed[index] = true;
                continue;
            },
        };
    }

    var summary: Summary = .{};
    for (ALL_PROVIDERS, 0..) |provider, index| {
        const status = inspectProviderAtHome(allocator, home, provider);
        setSummaryStatus(&summary, provider, if (failed[index])
            .failed
        else if (!detected[index] and status == .not_installed)
            .unavailable
        else
            status);
    }
    return summary;
}

fn setSummaryStatus(summary: *Summary, provider: Provider, status: RegistrationStatus) void {
    switch (provider) {
        .codex => summary.codex = status,
        .claude => summary.claude = status,
        .cursor => summary.cursor = status,
        .opencode => summary.opencode = status,
        .amp => summary.amp = status,
    }
}

fn installProviderAtHome(allocator: std.mem.Allocator, home: []const u8, executable: []const u8, provider: Provider) !void {
    return switch (provider) {
        .codex => installCodexAtHome(allocator, home, executable),
        .claude => installJsonAtHome(allocator, home, executable, CLAUDE_SPEC),
        .cursor => installJsonAtHome(allocator, home, executable, CURSOR_SPEC),
        .opencode => installJsonAtHome(allocator, home, executable, OPENCODE_SPEC),
        .amp => installJsonAtHome(allocator, home, executable, AMP_SPEC),
    };
}

fn removeProviderAtHome(allocator: std.mem.Allocator, home: []const u8, provider: Provider) !void {
    return switch (provider) {
        .codex => removeCodexAtHome(allocator, home),
        .claude => removeJsonAtHome(allocator, home, CLAUDE_SPEC),
        .cursor => removeJsonAtHome(allocator, home, CURSOR_SPEC),
        .opencode => removeJsonAtHome(allocator, home, OPENCODE_SPEC),
        .amp => removeJsonAtHome(allocator, home, AMP_SPEC),
    };
}

fn inspectProviderAtHome(allocator: std.mem.Allocator, home: []const u8, provider: Provider) RegistrationStatus {
    return switch (provider) {
        .codex => inspectCodexAtHome(allocator, home),
        .claude => inspectJsonAtHome(allocator, home, CLAUDE_SPEC),
        .cursor => inspectJsonAtHome(allocator, home, CURSOR_SPEC),
        .opencode => inspectJsonAtHome(allocator, home, OPENCODE_SPEC),
        .amp => inspectJsonAtHome(allocator, home, AMP_SPEC),
    };
}

fn configPathAlloc(allocator: std.mem.Allocator, home: []const u8, relative_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home, relative_path });
}

fn readFileIfPresent(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_CONFIG_BYTES)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
}

fn writeFileAtomic(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8) !void {
    try ensureParentDir(io, path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.verde-mcp.tmp", .{path});
    defer allocator.free(tmp_path);
    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

fn inspectCodexAtHome(allocator: std.mem.Allocator, home: []const u8) RegistrationStatus {
    const path = configPathAlloc(allocator, home, ".codex/config.toml") catch return .not_installed;
    defer allocator.free(path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = readFileIfPresent(allocator, threaded.io(), path) catch return .conflict;
    defer if (content) |bytes| allocator.free(bytes);
    const bytes = content orelse return .not_installed;
    if (std.mem.indexOf(u8, bytes, CODEX_BLOCK_BEGIN) != null and std.mem.indexOf(u8, bytes, CODEX_BLOCK_END) != null) return .installed;
    if (std.mem.indexOf(u8, bytes, "[mcp_servers.verde]") != null) return .conflict;
    return .not_installed;
}

fn installCodexAtHome(allocator: std.mem.Allocator, home: []const u8, executable: []const u8) !void {
    const path = try configPathAlloc(allocator, home, ".codex/config.toml");
    defer allocator.free(path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const existing = try readFileIfPresent(allocator, io, path);
    defer if (existing) |bytes| allocator.free(bytes);
    const content = existing orelse "";
    if (std.mem.indexOf(u8, content, "[mcp_servers.verde]") != null and std.mem.indexOf(u8, content, CODEX_BLOCK_BEGIN) == null) {
        return error.ProviderMcpConflict;
    }
    const without_block = try removeCodexBlockAlloc(allocator, content);
    defer allocator.free(without_block);
    const encoded_executable = try std.json.Stringify.valueAlloc(allocator, executable, .{});
    defer allocator.free(encoded_executable);
    const separator = if (without_block.len == 0 or without_block[without_block.len - 1] == '\n') "" else "\n";
    const updated = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}\n[mcp_servers.verde]\ncommand = {s}\nargs = [\"mcp\"]\n{s}\n",
        .{ without_block, separator, CODEX_BLOCK_BEGIN, encoded_executable, CODEX_BLOCK_END },
    );
    defer allocator.free(updated);
    try writeFileAtomic(allocator, io, path, updated);
}

fn removeCodexAtHome(allocator: std.mem.Allocator, home: []const u8) !void {
    const path = try configPathAlloc(allocator, home, ".codex/config.toml");
    defer allocator.free(path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const existing = try readFileIfPresent(allocator, io, path) orelse return;
    defer allocator.free(existing);
    const updated = try removeCodexBlockAlloc(allocator, existing);
    defer allocator.free(updated);
    if (updated.len != existing.len) try writeFileAtomic(allocator, io, path, updated);
}

fn removeCodexBlockAlloc(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const begin = std.mem.indexOf(u8, content, CODEX_BLOCK_BEGIN) orelse return allocator.dupe(u8, content);
    const end_start = std.mem.indexOfPos(u8, content, begin, CODEX_BLOCK_END) orelse return allocator.dupe(u8, content);
    var end = end_start + CODEX_BLOCK_END.len;
    if (end < content.len and content[end] == '\r') end += 1;
    if (end < content.len and content[end] == '\n') end += 1;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(content[0..begin]);
    try writer.writer.writeAll(content[end..]);
    return writer.toOwnedSlice();
}

fn inspectJsonAtHome(allocator: std.mem.Allocator, home: []const u8, spec: JsonSpec) RegistrationStatus {
    const path = configPathAlloc(allocator, home, spec.relative_path) catch return .not_installed;
    defer allocator.free(path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = readFileIfPresent(allocator, threaded.io(), path) catch return .conflict;
    defer if (content) |bytes| allocator.free(bytes);
    const bytes = content orelse return .not_installed;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return .conflict;
    defer parsed.deinit();
    if (parsed.value != .object) return .conflict;
    const section = parsed.value.object.get(spec.section_key) orelse return .not_installed;
    if (section != .object) return .conflict;
    const entry = section.object.get("verde") orelse return .not_installed;
    return if (jsonEntryManaged(entry, spec.environment_key)) .installed else .conflict;
}

fn installJsonAtHome(allocator: std.mem.Allocator, home: []const u8, executable: []const u8, spec: JsonSpec) !void {
    const path = try configPathAlloc(allocator, home, spec.relative_path);
    defer allocator.free(path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const existing = try readFileIfPresent(allocator, io, path);
    defer if (existing) |bytes| allocator.free(bytes);

    var parsed = if (existing) |bytes|
        try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{})
    else
        try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ProviderConfigNotObject;
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;
    if (root.getPtr(spec.section_key)) |section| {
        if (section.* != .object) return error.ProviderMcpSectionNotObject;
    } else {
        try root.put(arena, spec.section_key, .{ .object = .empty });
    }
    const section = &root.getPtr(spec.section_key).?.object;
    if (section.get("verde")) |entry| {
        if (!jsonEntryManaged(entry, spec.environment_key)) return error.ProviderMcpConflict;
    }
    try section.put(arena, "verde", try jsonManagedEntry(arena, executable, spec));

    const encoded = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(encoded);
    try writeFileAtomic(allocator, io, path, encoded);
}

fn removeJsonAtHome(allocator: std.mem.Allocator, home: []const u8, spec: JsonSpec) !void {
    const path = try configPathAlloc(allocator, home, spec.relative_path);
    defer allocator.free(path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const existing = try readFileIfPresent(allocator, io, path) orelse return;
    defer allocator.free(existing);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, existing, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const section_value = parsed.value.object.getPtr(spec.section_key) orelse return;
    if (section_value.* != .object) return;
    const entry = section_value.object.get("verde") orelse return;
    if (!jsonEntryManaged(entry, spec.environment_key)) return;
    _ = section_value.object.orderedRemove("verde");
    const encoded = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(encoded);
    try writeFileAtomic(allocator, io, path, encoded);
}

fn jsonEntryManaged(entry: std.json.Value, environment_key: []const u8) bool {
    if (entry != .object) return false;
    const environment = entry.object.get(environment_key) orelse return false;
    if (environment != .object) return false;
    const marker = environment.object.get(MANAGED_ENV_KEY) orelse return false;
    return marker == .string and std.mem.eql(u8, marker.string, MANAGED_ENV_VALUE);
}

fn jsonManagedEntry(arena: std.mem.Allocator, executable: []const u8, spec: JsonSpec) !std.json.Value {
    var environment: std.json.ObjectMap = .empty;
    try environment.put(arena, MANAGED_ENV_KEY, .{ .string = MANAGED_ENV_VALUE });
    var entry: std.json.ObjectMap = .empty;
    switch (spec.shape) {
        .command_and_args => {
            try entry.put(arena, "command", .{ .string = try arena.dupe(u8, executable) });
            var args = std.json.Array.init(arena);
            try args.append(.{ .string = "mcp" });
            try entry.put(arena, "args", .{ .array = args });
        },
        .opencode_command_array => {
            try entry.put(arena, "type", .{ .string = "local" });
            var command = std.json.Array.init(arena);
            try command.append(.{ .string = try arena.dupe(u8, executable) });
            try command.append(.{ .string = "mcp" });
            try entry.put(arena, "command", .{ .array = command });
            try entry.put(arena, "enabled", .{ .bool = true });
        },
    }
    try entry.put(arena, spec.environment_key, .{ .object = environment });
    return .{ .object = entry };
}

test "managed JSON registration preserves user servers and uninstalls only Verde" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(home);
    const claude_path = try configPathAlloc(std.testing.allocator, home, CLAUDE_SPEC.relative_path);
    defer std.testing.allocator.free(claude_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try writeFileAtomic(std.testing.allocator, threaded.io(), claude_path,
        \\{"mcpServers":{"user-server":{"command":"user-command"}}}
    );
    const detected = [5]bool{ false, true, true, true, true };
    const installed = try installAtHome(std.testing.allocator, home, "/opt/verde/bin/verde", detected);
    try std.testing.expectEqual(RegistrationStatus.installed, installed.claude);
    try std.testing.expectEqual(RegistrationStatus.installed, installed.cursor);
    try std.testing.expectEqual(RegistrationStatus.installed, installed.opencode);
    try std.testing.expectEqual(RegistrationStatus.installed, installed.amp);

    try removeProviderAtHome(std.testing.allocator, home, .claude);
    try std.testing.expectEqual(RegistrationStatus.not_installed, inspectProviderAtHome(std.testing.allocator, home, .claude));
    const remaining = (try readFileIfPresent(std.testing.allocator, threaded.io(), claude_path)).?;
    defer std.testing.allocator.free(remaining);
    try std.testing.expect(std.mem.indexOf(u8, remaining, "user-server") != null);
    try std.testing.expect(std.mem.indexOf(u8, remaining, "user-command") != null);
}

test "Codex managed block is idempotent and preserves surrounding TOML" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(home);
    const path = try configPathAlloc(std.testing.allocator, home, ".codex/config.toml");
    defer std.testing.allocator.free(path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try ensureParentDir(threaded.io(), path);
    try writeFileAtomic(std.testing.allocator, threaded.io(), path, "model = \"gpt-5\"\n");

    try installCodexAtHome(std.testing.allocator, home, "/opt/verde/bin/verde");
    try installCodexAtHome(std.testing.allocator, home, "/new/verde");
    const content = (try readFileIfPresent(std.testing.allocator, threaded.io(), path)).?;
    defer std.testing.allocator.free(content);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, CODEX_BLOCK_BEGIN));
    try std.testing.expect(std.mem.indexOf(u8, content, "model = \"gpt-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/new/verde") != null);

    try removeCodexAtHome(std.testing.allocator, home);
    const removed = (try readFileIfPresent(std.testing.allocator, threaded.io(), path)).?;
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("model = \"gpt-5\"\n", removed);
}

test "unmanaged provider entry is reported as a conflict" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"command":"other","env":{}}
    , .{});
    defer parsed.deinit();
    try std.testing.expect(!jsonEntryManaged(parsed.value, "env"));
}

test "an unmanaged verde entry does not block other providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(home);
    const claude_path = try configPathAlloc(std.testing.allocator, home, CLAUDE_SPEC.relative_path);
    defer std.testing.allocator.free(claude_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try writeFileAtomic(std.testing.allocator, threaded.io(), claude_path,
        \\{"mcpServers":{"verde":{"command":"user-command"}}}
    );

    const summary = try installAtHome(
        std.testing.allocator,
        home,
        "/opt/verde/bin/verde",
        .{ false, true, true, false, false },
    );
    try std.testing.expectEqual(RegistrationStatus.conflict, summary.claude);
    try std.testing.expectEqual(RegistrationStatus.installed, summary.cursor);
}

test "OpenCode registration preserves an existing schema config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(home);
    const path = try configPathAlloc(std.testing.allocator, home, OPENCODE_SPEC.relative_path);
    defer std.testing.allocator.free(path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try writeFileAtomic(std.testing.allocator, threaded.io(), path,
        \\{
        \\  "$schema": "https://opencode.ai/config.json",
        \\  "autoupdate": false,
        \\  "disabled_providers": ["openrouter", "google"]
        \\}
    );

    try installJsonAtHome(std.testing.allocator, home, "/opt/verde/bin/verde", OPENCODE_SPEC);
    try std.testing.expectEqual(RegistrationStatus.installed, inspectJsonAtHome(std.testing.allocator, home, OPENCODE_SPEC));
    const updated = (try readFileIfPresent(std.testing.allocator, threaded.io(), path)).?;
    defer std.testing.allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "disabled_providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "VERDE_MCP_MANAGED") != null);
}

test "existing provider config is detected without relying on PATH" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(home);
    const path = try configPathAlloc(std.testing.allocator, home, OPENCODE_SPEC.relative_path);
    defer std.testing.allocator.free(path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try writeFileAtomic(std.testing.allocator, threaded.io(), path, "{}");

    try std.testing.expect(providerConfigExistsAtHome(std.testing.allocator, home, .opencode));
    try std.testing.expect(!providerConfigExistsAtHome(std.testing.allocator, home, .amp));
}
