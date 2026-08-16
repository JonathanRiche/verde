//! Stable workspace identity keys used by persistence and daemon registries.

const std = @import("std");
const builtin = @import("builtin");
const platform_paths = @import("platform_paths");

/// Derives the persisted workspace ID for a path using the current platform's
/// existing comparison-key rules. Callers own the returned allocation.
pub fn deriveProjectId(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return deriveProjectIdForOs(allocator, builtin.os.tag, path);
}

fn deriveProjectIdForOs(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    path: []const u8,
) ![]u8 {
    const comparison_key = try platform_paths.projectComparisonKeyAllocForOs(allocator, os_tag, path);
    defer allocator.free(comparison_key);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(comparison_key);
    return std.fmt.allocPrint(allocator, "{x}", .{hasher.final()});
}

fn expectProjectIdForOs(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    path: []const u8,
    expected: []const u8,
) !void {
    const id = try deriveProjectIdForOs(allocator, os_tag, path);
    defer allocator.free(id);
    try std.testing.expectEqualStrings(expected, id);
}

fn expectSameProjectIdForOs(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    left: []const u8,
    right: []const u8,
) !void {
    const left_id = try deriveProjectIdForOs(allocator, os_tag, left);
    defer allocator.free(left_id);
    const right_id = try deriveProjectIdForOs(allocator, os_tag, right);
    defer allocator.free(right_id);
    try std.testing.expectEqualStrings(left_id, right_id);
}

fn expectDifferentProjectIdForOs(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    left: []const u8,
    right: []const u8,
) !void {
    const left_id = try deriveProjectIdForOs(allocator, os_tag, left);
    defer allocator.free(left_id);
    const right_id = try deriveProjectIdForOs(allocator, os_tag, right);
    defer allocator.free(right_id);
    try std.testing.expect(!std.mem.eql(u8, left_id, right_id));
}

test "Unix absolute paths preserve legacy workspace IDs byte for byte" {
    const allocator = std.testing.allocator;
    try expectProjectIdForOs(allocator, .linux, "/home/alice/Verde", "6e613665b586a973");
    try expectProjectIdForOs(allocator, .linux, "/repo/Verde", "24eb95fadf65084d");
}

test "Windows path spelling aliases preserve legacy workspace IDs" {
    const allocator = std.testing.allocator;
    try expectProjectIdForOs(allocator, .windows, "C:\\Users\\Alice\\Client Repo\\", "16b72ffe0b2276a3");
    try expectSameProjectIdForOs(allocator, .windows, "C:\\Users\\Alice\\Client Repo\\", "c:/users/alice/client repo");
    try expectSameProjectIdForOs(allocator, .windows, "\\\\?\\C:\\Users\\Alice\\Client Repo", "c:/users/alice/client repo");
    try expectSameProjectIdForOs(allocator, .windows, "\\\\Server\\Share\\Verde", "//server//share/verde/");
}

test "workspace identity retains current platform case sensitivity" {
    const allocator = std.testing.allocator;

    // Unix keys remain byte-sensitive, including ASCII path case.
    try expectProjectIdForOs(allocator, .linux, "/repo/verde", "7a32dda9fbcb8b05");
    try expectDifferentProjectIdForOs(allocator, .linux, "/repo/Verde", "/repo/verde");

    // Windows keys fold ASCII only; differently cased non-ASCII bytes remain distinct.
    try expectSameProjectIdForOs(allocator, .windows, "C:\\Repo\\VERDE", "c:/repo/verde");
    try expectDifferentProjectIdForOs(allocator, .windows, "C:\\Repo\\Zoë", "c:\\repo\\ZOË");
}

test "workspace identity retains current trailing separator behavior" {
    const allocator = std.testing.allocator;

    // Unix does not normalize a trailing separator.
    try expectProjectIdForOs(allocator, .linux, "/home/alice/Verde/", "fc26ec21afff1305");
    try expectDifferentProjectIdForOs(allocator, .linux, "/home/alice/Verde", "/home/alice/Verde/");

    // Windows removes a trailing separator except from drive roots.
    try expectSameProjectIdForOs(allocator, .windows, "C:\\Repo", "C:\\Repo\\");
    try expectDifferentProjectIdForOs(allocator, .windows, "C:", "C:\\");
}
