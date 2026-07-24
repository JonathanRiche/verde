//! Parsing and policy helpers for shell commands submitted from GUI chats.

const std = @import("std");
const builtin = @import("builtin");

pub const Submission = union(enum) {
    message: []const u8,
    command: []const u8,
};

pub fn isShellMode(input: []const u8) bool {
    return input.len > 0 and input[0] == '!' and (input.len == 1 or input[1] != '!');
}

/// Leaves shell mode without discarding what the user typed.
pub fn escapedShellDraft(input: []const u8) []const u8 {
    if (!isShellMode(input)) return input;
    return std.mem.trimStart(u8, input[1..], &std.ascii.whitespace);
}

/// Classifies a composer value at submit time. `!!` escapes one leading bang.
pub fn classifySubmission(input: []const u8) Submission {
    if (input.len >= 2 and input[0] == '!' and input[1] == '!') {
        return .{ .message = input[1..] };
    }
    if (input.len > 1 and input[0] == '!') {
        const command = std.mem.trim(u8, input[1..], &std.ascii.whitespace);
        if (command.len > 0) return .{ .command = command };
    }
    return .{ .message = input };
}

pub fn shellName() []const u8 {
    return if (builtin.os.tag == .windows) "cmd.exe" else "/bin/sh";
}

pub fn shellArgv(command: []const u8) [3][]const u8 {
    return if (builtin.os.tag == .windows)
        .{ "cmd.exe", "/D/C", command }
    else
        .{ "/bin/sh", "-lc", command };
}

/// Conservative lexical screen used only to decide whether confirmation is
/// mandatory. The shell remains the source of truth when execution is allowed.
pub fn looksDestructive(command: []const u8) bool {
    const needles = [_][]const u8{
        "rm ",             "rm\t",      "rmdir ",      "del ",          "erase ",
        "format ",         "mkfs",      "dd ",         "git reset",     "git clean",
        "git checkout --", "truncate ", "drop table",  "drop database", "delete from",
        "shutdown",        "reboot",    "kill ",       "pkill ",        "taskkill ",
        "chmod -r",        "chown -r",  "remove-item",
    };
    var lower_buffer: [4096]u8 = undefined;
    const inspected = command[0..@min(command.len, lower_buffer.len)];
    const lower = lower_buffer[0..inspected.len];
    for (inspected, 0..) |byte, index| lower[index] = std.ascii.toLower(byte);
    for (needles) |needle| {
        if (std.mem.find(u8, lower, needle) != null) return true;
    }
    return false;
}

test "bang submission detection and escaping happen only on complete values" {
    try std.testing.expectEqualStrings("git status", classifySubmission("!git status").command);
    try std.testing.expectEqualStrings("!literal", classifySubmission("!!literal").message);
    try std.testing.expectEqualStrings("!", classifySubmission("!").message);
    try std.testing.expectEqualStrings(" hello", classifySubmission(" hello").message);
}

test "shell mode can be escaped without losing the draft" {
    try std.testing.expect(isShellMode("!ls -la"));
    try std.testing.expect(isShellMode("!"));
    try std.testing.expect(!isShellMode("!!literal"));
    try std.testing.expectEqualStrings("ls -la", escapedShellDraft("!  ls -la"));
    try std.testing.expectEqualStrings("normal", escapedShellDraft("normal"));
}

test "destructive command classification is conservative and case insensitive" {
    try std.testing.expect(looksDestructive("git clean -fd"));
    try std.testing.expect(looksDestructive("RM -rf build"));
    try std.testing.expect(looksDestructive("echo ok && shutdown now"));
    try std.testing.expect(!looksDestructive("git status"));
    try std.testing.expect(!looksDestructive("zig build test"));
}
