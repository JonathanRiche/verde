//! Claude's live footer supplements Stop hooks, which omit background shells.
const std = @import("std");

/// Match a positive shell count in a footer segment, never transcript prose.
pub fn footerHasBackgroundShells(line: []const u8) bool {
    var segments = std.mem.splitSequence(u8, line, "·");
    while (segments.next()) |segment| {
        const text = std.mem.trim(u8, segment, " \t\r\n");
        var digits: usize = 0;
        while (digits < text.len and std.ascii.isDigit(text[digits])) : (digits += 1) {}
        if (digits == 0) continue;
        const count = std.fmt.parseInt(u32, text[0..digits], 10) catch continue;
        if (count == 0) continue;
        const suffix = text[digits..];
        if (std.mem.eql(u8, suffix, " shell") or std.mem.eql(u8, suffix, " shells")) return true;
    }
    return false;
}

test "Claude shell footer accepts live counts and rejects completion prose" {
    const expect = std.testing.expect;
    try expect(footerHasBackgroundShells("bypass permissions on · 1 shell · ← for agents"));
    try expect(footerHasBackgroundShells("? for shortcuts · 12 shells"));
    try expect(footerHasBackgroundShells("1 shell"));
    try expect(!footerHasBackgroundShells("bypass permissions on · 0 shells"));
    try expect(!footerHasBackgroundShells("Sautéed for 16m · done 10:21 AM · 1 shell still running"));
    try expect(!footerHasBackgroundShells("Background command completed (exit code 0)"));
    try expect(!footerHasBackgroundShells("bypass permissions on · 1 shell command completed"));
    try expect(!footerHasBackgroundShells("bypass permissions on · 999999999999999999999 shells"));
}
