const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Search for "cmd" in the PATH and return the absolute path. This will
/// always allocate if there is a non-null result. The caller must free the
/// resulting value.
///
/// Verde patch: the upstream Windows implementation walked PATH using
/// std.process.getenvW + std.fs.cwd().openFile, both removed in Zig 0.16.
/// The function is only consumed by ghostty's build/Config.zig to default
/// `emit-docs` / `emit-xcframework` on when pandoc / xcodebuild are on PATH.
/// Verde consumes only the ghostty-vt module and never needs either, so we
/// short-circuit Windows to the same null-return behavior the POSIX arm has
/// always had upstream. Restore the original walk if a future Verde feature
/// depends on it.
pub fn expand(alloc: Allocator, cmd: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return try alloc.dupe(u8, cmd);
    }
    return null;
}

// `uname -n` is the *nix equivalent of `hostname.exe` on Windows
test "expand: hostname" {
    const executable = if (builtin.os.tag == .windows) "hostname.exe" else "uname";
    const path = (try expand(testing.allocator, executable)).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len > executable.len);
}

test "expand: does not exist" {
    const path = try expand(testing.allocator, "thisreallyprobablydoesntexist123");
    try testing.expect(path == null);
}

test "expand: slash" {
    const path = (try expand(testing.allocator, "foo/env")).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len == 7);
}
