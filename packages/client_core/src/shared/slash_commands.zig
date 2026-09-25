//! Parser and shared metadata helpers for GUI chat slash commands.

const std = @import("std");
const provider_types = @import("headless").provider_types;

pub const LocalSlashCommandId = enum(u8) {
    handoff,
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
        .id = .handoff,
        .name = "/handoff",
        .summary = "Hand this chat off to another GUI chat or agent TUI.",
        .usage = "/handoff",
    },
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

/// Returns whether submission may need provider slash-command metadata.
pub fn isSlashInput(raw_text: []const u8) bool {
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    return std.mem.startsWith(u8, text, "/");
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

test "parse classifies provider, local, literal, unknown, and ordinary input" {
    const provider_cases = [_]struct { input: []const u8, id: provider_types.ProviderSlashCommandId, args: []const u8 }{
        .{ .input = " /goal complete ", .id = .goal, .args = "complete" },
        .{ .input = "/goal clear", .id = .goal, .args = "clear" },
        .{ .input = "/compact", .id = .compact, .args = "" },
        .{ .input = "/usage", .id = .usage, .args = "" },
    };
    for (provider_cases) |case| {
        const parsed = parse(case.input, TEST_PROVIDER_COMMANDS[0..]);
        try std.testing.expect(parsed == .provider);
        try std.testing.expectEqual(case.id, parsed.provider.command.id);
        try std.testing.expectEqualStrings(case.args, parsed.provider.args);
    }

    const local = parse("/stack status", TEST_PROVIDER_COMMANDS[0..]);
    try std.testing.expect(local == .local);
    try std.testing.expectEqual(LocalSlashCommandId.stack, local.local.command.id);
    try std.testing.expectEqualStrings("status", local.local.args);
    const handoff = parse("/handoff", TEST_PROVIDER_COMMANDS[0..]);
    try std.testing.expectEqual(LocalSlashCommandId.handoff, handoff.local.command.id);
    try std.testing.expectEqualStrings("", handoff.local.args);

    const literal = parse("//literal slash", TEST_PROVIDER_COMMANDS[0..]);
    try std.testing.expect(literal == .literal_prompt);
    try std.testing.expectEqualStrings("/literal slash", literal.literal_prompt);

    const unknown = parse("/unknown arg", TEST_PROVIDER_COMMANDS[0..]);
    try std.testing.expect(unknown == .unknown);
    try std.testing.expectEqualStrings("/unknown", unknown.unknown.name);
    try std.testing.expectEqualStrings("arg", unknown.unknown.args);

    try std.testing.expect(parse("please do /something", TEST_PROVIDER_COMMANDS[0..]) == .not_slash);
}

test "ordinary prompts do not need provider slash metadata" {
    try std.testing.expect(!isSlashInput("reply exactly READY"));
    try std.testing.expect(!isSlashInput("  mention /compact in prose  "));
    try std.testing.expect(isSlashInput("  /compact  "));
}
