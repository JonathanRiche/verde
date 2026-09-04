//! Workspace-process polling shared by the CLI and GUI IPC contract tests.

const std = @import("std");
const platform_runtime = @import("platform_runtime");

pub const Transport = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque, std.mem.Allocator, std.Io, ?[]const u8) anyerror![]u8,
};

pub const Outcome = enum { active, completed, replaced, gone };

pub const Poll = struct {
    outcome: Outcome,
    snapshot: ?std.json.Value = null,
};

pub fn waitAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: ?[]const u8,
    process_id: []const u8,
    timeout_ms: u32,
    transport: Transport,
    poll_interval_ms: u32,
) ![]u8 {
    const started_ns = platform_runtime.monotonicTimestampNs();
    while (true) {
        const response = try transport.request(transport.context, allocator, io, workspace);
        defer allocator.free(response);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        if (!responseOk(parsed.value)) return error.WorkspaceProcessPollRejected;
        const result = poll(parsed.value, process_id);
        const elapsed_ms: u64 = @intCast(@divTrunc(platform_runtime.monotonicTimestampNs() - started_ns, std.time.ns_per_ms));
        if (result.outcome != .active) {
            return waitResultAlloc(allocator, process_id, @tagName(result.outcome), false, elapsed_ms, result.snapshot);
        }
        if (elapsed_ms >= timeout_ms) {
            return waitResultAlloc(allocator, process_id, "timed_out", true, elapsed_ms, result.snapshot);
        }
        const remaining_ms: u64 = timeout_ms - elapsed_ms;
        try std.Io.sleep(io, .fromMilliseconds(@min(remaining_ms, poll_interval_ms)), .awake);
    }
}

pub fn poll(root: std.json.Value, process_id: []const u8) Poll {
    if (root != .object) return .{ .outcome = .gone };
    const result = root.object.get("result") orelse return .{ .outcome = .gone };
    if (result != .object) return .{ .outcome = .gone };
    const processes = result.object.get("processes") orelse return .{ .outcome = .gone };
    if (processes != .array) return .{ .outcome = .gone };
    const terminal_prefix = terminalProcessIdPrefix(process_id);
    var replaced = false;
    for (processes.array.items) |process| {
        if (process != .object) continue;
        const candidate_id = jsonString(process.object.get("id") orelse .null) orelse continue;
        if (std.mem.eql(u8, candidate_id, process_id)) {
            const status = jsonString(process.object.get("status") orelse .null) orelse "unknown";
            return .{
                .outcome = if (statusActive(status)) .active else .completed,
                .snapshot = process,
            };
        }
        if (terminal_prefix) |prefix| {
            if (std.mem.startsWith(u8, candidate_id, prefix)) replaced = true;
        }
    }
    return .{ .outcome = if (replaced) .replaced else .gone };
}

pub fn responseOk(root: std.json.Value) bool {
    if (root != .object) return false;
    return switch (root.object.get("ok") orelse .null) {
        .bool => |value| value,
        else => false,
    };
}

fn terminalProcessIdPrefix(process_id: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, process_id, "term:")) return null;
    const separator = std.mem.lastIndexOfScalar(u8, process_id, ':') orelse return null;
    return process_id[0 .. separator + 1];
}

fn statusActive(status: []const u8) bool {
    return std.mem.eql(u8, status, "starting") or
        std.mem.eql(u8, status, "running") or
        std.mem.eql(u8, status, "stopping") or
        std.mem.eql(u8, status, "restarting") or
        std.mem.eql(u8, status, "waiting") or
        std.mem.eql(u8, status, "pending");
}

fn waitResultAlloc(
    allocator: std.mem.Allocator,
    process_id: []const u8,
    outcome: []const u8,
    timed_out: bool,
    elapsed_ms: u64,
    snapshot: ?std.json.Value,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("process_id");
    try stringify.write(process_id);
    try stringify.objectField("outcome");
    try stringify.write(outcome);
    try stringify.objectField("timed_out");
    try stringify.write(timed_out);
    try stringify.objectField("elapsed_ms");
    try stringify.write(elapsed_ms);
    try stringify.objectField("process");
    if (snapshot) |value| try writeJsonValue(&stringify, value) else try stringify.write(null);
    try stringify.endObject();
    return writer.toOwnedSlice();
}

fn writeJsonValue(stringify: *std.json.Stringify, value: std.json.Value) !void {
    switch (value) {
        .integer => |item| try stringify.write(item),
        .float => |item| try stringify.write(item),
        .number_string => |item| try stringify.write(item),
        .string => |item| try stringify.write(item),
        .bool => |item| try stringify.write(item),
        .null => try stringify.write(null),
        .array => |array| {
            try stringify.beginArray();
            for (array.items) |item| try writeJsonValue(stringify, item);
            try stringify.endArray();
        },
        .object => |object| {
            try stringify.beginObject();
            var fields = object.iterator();
            while (fields.next()) |field| {
                try stringify.objectField(field.key_ptr.*);
                try writeJsonValue(stringify, field.value_ptr.*);
            }
            try stringify.endObject();
        },
    }
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}
