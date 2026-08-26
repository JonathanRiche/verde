//! Persistent, secret-free MCP call outcomes shared by every transport.

const std = @import("std");
const builtin = @import("builtin");

pub const FILE_NAME = "mcp-events.jsonl";
const MAX_LOG_BYTES: u64 = 16 * 1024 * 1024;
const MAX_REPORT_BYTES: usize = @intCast(MAX_LOG_BYTES);
const MAX_DETAIL_BYTES: usize = 512;

pub const Event = struct {
    transport: []const u8,
    client: []const u8,
    method: []const u8,
    tool: ?[]const u8 = null,
    ok: bool,
    code: ?i64 = null,
    detail: ?[]const u8 = null,
    duration_ms: u64 = 0,
};

pub fn pathAlloc(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ pref_path, FILE_NAME });
}

/// Appends one bounded event under an advisory file lock. No arguments, tool
/// output, authorization headers, or transcript content are persisted.
pub fn append(allocator: std.mem.Allocator, io: std.Io, pref_path: []const u8, event: Event) !void {
    try std.Io.Dir.cwd().createDirPath(io, pref_path);
    const path = try pathAlloc(allocator, pref_path);
    defer allocator.free(path);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("timestamp_ms");
    try stringify.write(unixTimestampMs(io));
    try stringify.objectField("transport");
    try stringify.write(event.transport);
    try stringify.objectField("client");
    try stringify.write(event.client);
    try stringify.objectField("method");
    try stringify.write(event.method);
    if (event.tool) |tool| {
        try stringify.objectField("tool");
        try stringify.write(tool);
    }
    try stringify.objectField("ok");
    try stringify.write(event.ok);
    if (event.code) |code| {
        try stringify.objectField("code");
        try stringify.write(code);
    }
    if (event.detail) |detail| {
        try stringify.objectField("detail");
        try stringify.write(detail[0..@min(detail.len, MAX_DETAIL_BYTES)]);
    }
    try stringify.objectField("duration_ms");
    try stringify.write(event.duration_ms);
    try stringify.endObject();
    try writer.writer.writeByte('\n');

    const private_permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        .default_file
    else
        @enumFromInt(0o600);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .permissions = private_permissions,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    const offset: u64 = if (stat.size + writer.written().len > MAX_LOG_BYTES) blk: {
        try file.setLength(io, 0);
        break :blk 0;
    } else stat.size;
    try file.writePositionalAll(io, writer.written(), offset);
}

pub fn reportAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    pref_path: []const u8,
    include_errors: bool,
) ![]u8 {
    const path = try pathAlloc(allocator, pref_path);
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_REPORT_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return emptyReportAlloc(allocator, path, include_errors),
        else => return err,
    };
    defer allocator.free(bytes);

    var counts = [_]ClientCount{.{}} ** CLIENT_NAMES.len;
    var calls: usize = 0;
    var failures: usize = 0;
    var malformed: usize = 0;
    var errors: std.ArrayListUnmanaged(std.json.Parsed(std.json.Value)) = .empty;
    defer {
        for (errors.items) |*parsed| parsed.deinit();
        errors.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
            malformed += 1;
            continue;
        };
        if (parsed.value != .object) {
            parsed.deinit();
            malformed += 1;
            continue;
        }
        const ok_value = parsed.value.object.get("ok") orelse .null;
        if (ok_value != .bool) {
            parsed.deinit();
            malformed += 1;
            continue;
        }
        const client = jsonString(parsed.value.object.get("client") orelse .null) orelse "unknown";
        const index = clientIndex(client);
        calls += 1;
        counts[index].calls += 1;
        if (!ok_value.bool) {
            failures += 1;
            counts[index].failures += 1;
            if (include_errors) {
                try errors.append(allocator, parsed);
                continue;
            }
        }
        parsed.deinit();
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("ok");
    try stringify.write(true);
    try stringify.objectField("log_path");
    try stringify.write(path);
    try stringify.objectField("calls");
    try stringify.write(calls);
    try stringify.objectField("failures");
    try stringify.write(failures);
    try stringify.objectField("malformed_lines");
    try stringify.write(malformed);
    try stringify.objectField("by_client");
    try stringify.beginArray();
    for (CLIENT_NAMES, counts) |name, count| {
        if (count.calls == 0) continue;
        try stringify.beginObject();
        try stringify.objectField("client");
        try stringify.write(name);
        try stringify.objectField("calls");
        try stringify.write(count.calls);
        try stringify.objectField("failures");
        try stringify.write(count.failures);
        try stringify.endObject();
    }
    try stringify.endArray();
    if (include_errors) {
        try stringify.objectField("errors");
        try stringify.beginArray();
        for (errors.items) |parsed| try stringify.write(parsed.value);
        try stringify.endArray();
    }
    try stringify.endObject();
    return writer.toOwnedSlice();
}

const CLIENT_NAMES = [_][]const u8{ "codex", "claude", "cursor", "opencode", "amp", "pi", "fx", "grok", "stdio", "unknown" };

const ClientCount = struct {
    calls: usize = 0,
    failures: usize = 0,
};

fn clientIndex(client: []const u8) usize {
    for (CLIENT_NAMES, 0..) |name, index| {
        if (std.mem.eql(u8, client, name)) return index;
    }
    return CLIENT_NAMES.len - 1;
}

fn emptyReportAlloc(allocator: std.mem.Allocator, path: []const u8, include_errors: bool) ![]u8 {
    return if (include_errors)
        std.json.Stringify.valueAlloc(allocator, .{
            .ok = true,
            .log_path = path,
            .calls = @as(usize, 0),
            .failures = @as(usize, 0),
            .malformed_lines = @as(usize, 0),
            .by_client = [_]u8{},
            .errors = [_]u8{},
        }, .{})
    else
        std.json.Stringify.valueAlloc(allocator, .{
            .ok = true,
            .log_path = path,
            .calls = @as(usize, 0),
            .failures = @as(usize, 0),
            .malformed_lines = @as(usize, 0),
            .by_client = [_]u8{},
        }, .{});
}

fn unixTimestampMs(io: std.Io) i64 {
    const timestamp = std.Io.Clock.real.now(io);
    return @intCast(@divTrunc(timestamp.nanoseconds, std.time.ns_per_ms));
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

test "telemetry report counts clients and retains only failures on demand" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(pref_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try append(std.testing.allocator, io, pref_path, .{ .transport = "http", .client = "fx", .method = "tools/list", .ok = true });
    try append(std.testing.allocator, io, pref_path, .{ .transport = "http", .client = "fx", .method = "tools/call", .tool = "list_processes", .ok = false, .code = -32000, .detail = "approval denied" });
    const report = try reportAlloc(std.testing.allocator, io, pref_path, true);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"calls\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"failures\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "approval denied") != null);
}
