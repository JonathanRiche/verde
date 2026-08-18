//! Authenticated, gateway-local directory listing for the web workspace picker.

const std = @import("std");

const DirectoryEntry = struct {
    name: []u8,
    path: []u8,

    fn deinit(self: DirectoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

/// Handles web.directory.list locally so browsers can navigate the filesystem
/// without receiving browser-forbidden native paths from a file input.
pub fn respond(allocator: std.mem.Allocator, io: std.Io, request_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const method_value = parsed.value.object.get("method") orelse return null;
    if (method_value != .string or !std.mem.eql(u8, method_value.string, "web.directory.list")) return null;

    const id_value = parsed.value.object.get("id") orelse .null;
    const params = parsed.value.object.get("params") orelse
        return try errorResponse(allocator, id_value, "invalid_request", "web.directory.list requires params");
    if (params != .object) return try errorResponse(allocator, id_value, "invalid_request", "params must be an object");
    const path_value = params.object.get("path") orelse
        return try errorResponse(allocator, id_value, "invalid_request", "web.directory.list requires path");
    if (path_value != .string or !std.fs.path.isAbsolute(path_value.string)) {
        return try errorResponse(allocator, id_value, "invalid_request", "directory path must be absolute");
    }

    const path = path_value.string;
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err|
        return try errorResponse(allocator, id_value, "not_found", @errorName(err));
    defer dir.close(io);

    var entries: std.ArrayList(DirectoryEntry) = .empty;
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!std.unicode.utf8ValidateSlice(entry.name)) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        errdefer allocator.free(child_path);
        try entries.append(allocator, .{ .name = name, .path = child_path });
    }
    std.mem.sort(DirectoryEntry, entries.items, {}, lessThanDirectory);
    return try successResponse(allocator, id_value, path, std.fs.path.dirname(path), entries.items);
}

fn lessThanDirectory(_: void, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
    return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
}

fn successResponse(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    path: []const u8,
    parent: ?[]const u8,
    entries: []const DirectoryEntry,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("id");
    try json.write(id_value);
    try json.objectField("ok");
    try json.write(true);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("path");
    try json.write(path);
    try json.objectField("parent");
    if (parent) |value| try json.write(value) else try json.write(null);
    try json.objectField("directories");
    try json.beginArray();
    for (entries) |entry| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(entry.name);
        try json.objectField("path");
        try json.write(entry.path);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try json.endObject();
    return try writer.toOwnedSlice();
}

fn errorResponse(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var json: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try json.beginObject();
    try json.objectField("id");
    try json.write(id_value);
    try json.objectField("ok");
    try json.write(false);
    try json.objectField("error");
    try json.beginObject();
    try json.objectField("code");
    try json.write(code);
    try json.objectField("message");
    try json.write(message);
    try json.endObject();
    try json.endObject();
    return try writer.toOwnedSlice();
}

test "ignores unrelated RPC methods" {
    const response = try respond(std.testing.allocator, std.testing.io, "{\"id\":1,\"method\":\"core.status\",\"params\":{}}");
    try std.testing.expect(response == null);
}

test "rejects relative directory paths" {
    const response = (try respond(std.testing.allocator, std.testing.io, "{\"id\":1,\"method\":\"web.directory.list\",\"params\":{\"path\":\"tmp\"}}")) orelse unreachable;
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "directory path must be absolute") != null);
}
