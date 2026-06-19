//! Parser and shared metadata helpers for GUI chat slash commands.

const std = @import("std");
const provider_types = @import("provider_types.zig");

pub const LocalSlashCommandId = enum(u8) {
    stack,
    process,
};

pub const LocalSlashCommand = struct {
    id: LocalSlashCommandId,
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
};

pub const LOCAL_COMMANDS = [_]LocalSlashCommand{
    .{
        .id = .stack,
        .name = "/stack",
        .summary = "Start, stop, restart, or inspect configured workspace processes.",
        .usage = "/stack start|stop|restart|status",
    },
    .{
        .id = .process,
        .name = "/process",
        .summary = "Control or focus a named managed process.",
        .usage = "/process start|stop|restart|focus|crashed <name>",
    },
};

pub const ParsedSlashCommand = union(enum) {
    not_slash,
    literal_prompt: []const u8,
    local: struct {
        command: LocalSlashCommand,
        args: []const u8,
    },
    provider: struct {
        command: provider_types.ProviderSlashCommand,
        args: []const u8,
    },
    unknown: struct {
        name: []const u8,
        args: []const u8,
    },
};

pub fn parse(
    raw_text: []const u8,
    provider_commands: []const provider_types.ProviderSlashCommand,
) ParsedSlashCommand {
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    if (!std.mem.startsWith(u8, text, "/")) return .not_slash;
    if (std.mem.startsWith(u8, text, "//")) return .{ .literal_prompt = text[1..] };

    const root_end = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
    const root = text[0..root_end];
    const args = std.mem.trim(u8, text[root_end..], " \t\r\n");

    if (findLocalCommand(root)) |command| {
        return .{ .local = .{ .command = command, .args = args } };
    }
    if (findProviderCommand(provider_commands, root)) |command| {
        return .{ .provider = .{ .command = command, .args = args } };
    }
    return .{ .unknown = .{ .name = root, .args = args } };
}

pub fn findLocalCommand(name: []const u8) ?LocalSlashCommand {
    for (LOCAL_COMMANDS) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

pub fn findProviderCommand(
    commands: []const provider_types.ProviderSlashCommand,
    name: []const u8,
) ?provider_types.ProviderSlashCommand {
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

const TEST_PROVIDER_COMMANDS = [_]provider_types.ProviderSlashCommand{
    .{
        .id = .compact,
        .name = "/compact",
        .summary = "Compact context.",
        .usage = "/compact",
        .requires_thread = true,
    },
    .{
        .id = .goal,
        .name = "/goal",
        .summary = "Manage goal.",
        .usage = "/goal [status|clear|<objective>]",
        .requires_thread = true,
    },
    .{
        .id = .usage,
        .name = "/usage",
        .summary = "Show usage.",
        .usage = "/usage",
        .requires_thread = false,
    },
};

test "parse recognizes provider slash commands and args" {
    const parsed = parse(" /goal complete ", TEST_PROVIDER_COMMANDS[0..]);
    try std.testing.expect(parsed == .provider);
    try std.testing.expectEqual(provider_types.ProviderSlashCommandId.goal, parsed.provider.command.id);
    try std.testing.expectEqualStrings("complete", parsed.provider.args);
}

test "parse recognizes local slash commands" {
    const parsed = parse("/stack status", TEST_PROVIDER_COMMANDS[0..]);
    try std.testing.expect(parsed == .local);
    try std.testing.expectEqual(LocalSlashCommandId.stack, parsed.local.command.id);
    try std.testing.expectEqualStrings("status", parsed.local.args);
}

test "parse recognizes literal slash escape" {
    const parsed = parse("//literal slash", TEST_PROVIDER_COMMANDS[0..]);
    try std.testing.expect(parsed == .literal_prompt);
    try std.testing.expectEqualStrings("/literal slash", parsed.literal_prompt);
}

test "parse reports unknown slash commands" {
    const parsed = parse("/unknown arg", TEST_PROVIDER_COMMANDS[0..]);
    try std.testing.expect(parsed == .unknown);
    try std.testing.expectEqualStrings("/unknown", parsed.unknown.name);
    try std.testing.expectEqualStrings("arg", parsed.unknown.args);
}

test "parse ignores ordinary prompts" {
    const parsed = parse("please do /something", TEST_PROVIDER_COMMANDS[0..]);
    try std.testing.expect(parsed == .not_slash);
}
