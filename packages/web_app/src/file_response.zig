//! Bounded-memory HTTP responses from an already-authorized descriptor.
const std = @import("std");

pub const ByteRange = struct { start: u64, length: u64 };

/// A single byte range only. Malformed, multipart and unsatisfiable ranges fail.
pub fn parseRange(value: []const u8, size: u64) !ByteRange {
    if (!std.mem.startsWith(u8, value, "bytes=") or size == 0) return error.InvalidRange;
    const spec = value[6..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return error.InvalidRange;
    const left = spec[0..dash];
    const right = spec[dash + 1 ..];
    if (left.len == 0) {
        const suffix = try decimal(right);
        if (suffix == 0) return error.InvalidRange;
        const length = @min(suffix, size);
        return .{ .start = size - length, .length = length };
    }
    const start = try decimal(left);
    if (start >= size) return error.InvalidRange;
    const end = if (right.len == 0) size - 1 else @min(try decimal(right), size - 1);
    if (end < start) return error.InvalidRange;
    return .{ .start = start, .length = end - start + 1 };
}

fn decimal(value: []const u8) !u64 {
    if (value.len == 0) return error.InvalidRange;
    for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidRange;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidRange;
}

/// IMF-fixdate, at whole-second resolution. Clamp dates outside HTTP's calendar.
pub fn lastModified(buffer: *[64]u8, timestamp: std.Io.Timestamp) []const u8 {
    const seconds: u64 = @intCast(std.math.clamp(timestamp.toSeconds(), 0, 253402300799));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buffer, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekdays[day.day % 7],       month_day.day_index + @as(u8, 1), months[month_day.month.numeric() - 1],
        year_day.year,               time.getHoursIntoDay(),           time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Send only from the confined file, never reopen a path. Memory is 64 KiB
/// regardless of file size; a truncated file/failed read aborts the connection.
pub fn respond(io: std.Io, request: *std.http.Server.Request, file: std.Io.File, stat: std.Io.File.Stat, extra_headers: []const std.http.Header) !void {
    var range_value: ?[]const u8 = null;
    var invalid = false;
    var if_range: ?[]const u8 = null;
    var duplicate_if_range = false;
    var date_buffer: [64]u8 = undefined;
    const modified = lastModified(&date_buffer, stat.mtime);
    var headers_it = request.iterateHeaders();
    while (headers_it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "if-range")) {
            if (if_range != null) duplicate_if_range = true;
            if_range = header.value;
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(header.name, "range")) continue;
        if (range_value != null) invalid = true;
        range_value = header.value;
    }
    // RFC 9110: Range applies to GET; HEAD describes the complete representation.
    var range: ByteRange = .{ .start = 0, .length = stat.size };
    const validator_matches = !duplicate_if_range and (if (if_range) |value| std.mem.eql(u8, value, modified) else true);
    const partial = request.head.method == .GET and range_value != null and validator_matches;
    if (partial and !invalid) range = parseRange(range_value.?, stat.size) catch blk: {
        invalid = true;
        break :blk range;
    };
    var headers: [32]std.http.Header = undefined;
    std.debug.assert(extra_headers.len + 3 <= headers.len);
    @memcpy(headers[0..extra_headers.len], extra_headers);
    var count = extra_headers.len;
    headers[count] = .{ .name = "accept-ranges", .value = "bytes" };
    count += 1;
    headers[count] = .{ .name = "last-modified", .value = modified };
    count += 1;
    var range_buffer: [96]u8 = undefined;
    if (partial) {
        headers[count] = .{ .name = "content-range", .value = if (invalid)
            try std.fmt.bufPrint(&range_buffer, "bytes */{d}", .{stat.size})
        else
            try std.fmt.bufPrint(&range_buffer, "bytes {d}-{d}/{d}", .{ range.start, range.start + range.length - 1, stat.size }) };
        count += 1;
    }
    if (partial and invalid) {
        // Replace the file's MIME type for the short error response.
        for (headers[0..count]) |*header| if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
            header.value = "text/plain; charset=utf-8";
        };
        return request.respond("invalid_range\n", .{ .status = .range_not_satisfiable, .extra_headers = headers[0..count] });
    }
    var buffer: [64 * 1024]u8 = undefined;
    // Discover an initial I/O failure before committing the success headers.
    // Once streaming starts, later failures must close the connection instead.
    const first_n = if (request.head.method != .HEAD and range.length != 0)
        file.readPositional(io, &.{buffer[0..@intCast(@min(range.length, buffer.len))]}, range.start) catch |err| {
            if (err == error.Canceled) return err;
            return request.respond("file_read_failed\n", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                    .{ .name = "cache-control", .value = "no-store" },
                    .{ .name = "x-content-type-options", .value = "nosniff" },
                },
            });
        }
    else
        0;
    if (request.head.method != .HEAD and range.length != 0 and first_n == 0)
        return request.respond("file_changed\n", .{ .status = .internal_server_error });
    var response = try request.respondStreaming(&.{}, .{
        .content_length = range.length,
        .respond_options = .{ .status = if (partial) .partial_content else .ok, .extra_headers = headers[0..count] },
    });
    if (request.head.method == .HEAD) return response.flush();
    try response.writer.writeAll(buffer[0..first_n]);
    var offset = range.start + first_n;
    var remaining = range.length - first_n;
    while (remaining > 0) {
        const chunk = buffer[0..@intCast(@min(remaining, buffer.len))];
        const n = try file.readPositional(io, &.{chunk}, offset);
        if (n == 0) return error.UnexpectedEndOfFile;
        try response.writer.writeAll(chunk[0..n]);
        offset += n;
        remaining -= n;
    }
    try response.end();
}

test "file ranges handle starts middles suffixes and invalid input" {
    const t = std.testing;
    try t.expectEqual(ByteRange{ .start = 0, .length = 10 }, try parseRange("bytes=0-9", 100));
    try t.expectEqual(ByteRange{ .start = 40, .length = 10 }, try parseRange("bytes=40-49", 100));
    try t.expectEqual(ByteRange{ .start = 90, .length = 10 }, try parseRange("bytes=-10", 100));
    try t.expectEqual(ByteRange{ .start = 90, .length = 10 }, try parseRange("bytes=90-", 100));
    try t.expectEqual(ByteRange{ .start = 90, .length = 10 }, try parseRange("bytes=90-999", 100));
    for ([_][]const u8{ "bytes=100-", "bytes=9-1", "bytes=-0", "bytes=", "bytes=1-2,4-5", "bytes=+1-2", "items=1-2", "bytes=18446744073709551616-" }) |value|
        try t.expectError(error.InvalidRange, parseRange(value, 100));
    try t.expectError(error.InvalidRange, parseRange("bytes=0-", 0));
    var date: [64]u8 = undefined;
    try t.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", lastModified(&date, .zero));
}

fn testResponse(file: std.Io.File, method: []const u8, range: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const wire = try std.fmt.allocPrint(allocator, "{s} /api/file HTTP/1.1\r\nHost: localhost\r\n{s}\r\n", .{ method, range });
    defer allocator.free(wire);
    var input = std.Io.Reader.fixed(wire);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var server = std.http.Server.init(&input, &output.writer);
    var request = try server.receiveHead();
    try respond(std.testing.io, &request, file, try file.stat(std.testing.io), &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "content-disposition", .value = "inline" },
    });
    return output.toOwnedSlice();
}

test "file HTTP responses preserve small text and implement range and HEAD headers" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "text.txt", .data = "0123456789" });
    const file = try tmp.dir.openFile(io, "text.txt", .{});
    defer file.close(io);
    const cases = .{
        .{ "GET", "", "200 OK", "0123456789", "content-length: 10" },
        .{ "GET", "Range: bytes=0-2\r\n", "206 Partial Content", "012", "content-range: bytes 0-2/10" },
        .{ "GET", "Range: bytes=4-6\r\n", "206 Partial Content", "456", "content-range: bytes 4-6/10" },
        .{ "GET", "Range: bytes=-3\r\n", "206 Partial Content", "789", "content-range: bytes 7-9/10" },
        .{ "GET", "Range: bytes=10-\r\n", "416 Range Not Satisfiable", "invalid_range\n", "content-range: bytes */10" },
        .{ "GET", "Range: bytes=1-2\r\nRange: bytes=3-4\r\n", "416 Range Not Satisfiable", "invalid_range\n", "content-range: bytes */10" },
        .{ "GET", "Range: bytes=1-2\r\nIf-Range: Thu, 01 Jan 1970 00:00:00 GMT\r\n", "200 OK", "0123456789", "content-length: 10" },
        .{ "HEAD", "Range: bytes=1-2\r\n", "200 OK", "", "content-length: 10" },
    };
    inline for (cases) |case| {
        const response = try testResponse(file, case[0], case[1]);
        defer t.allocator.free(response);
        try t.expect(std.mem.indexOf(u8, response, case[2]) != null);
        try t.expect(std.mem.indexOf(u8, response, case[4]) != null);
        try t.expect(std.mem.indexOf(u8, response, "accept-ranges: bytes\r\n") != null);
        try t.expect(std.mem.indexOf(u8, response, "last-modified: ") != null);
        try t.expect(std.mem.indexOf(u8, response, "content-disposition: inline\r\n") != null);
        const body_start = (std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.MissingHeaders) + 4;
        try t.expectEqualStrings(case[3], response[body_start..]);
    }
    var modified_buffer: [64]u8 = undefined;
    const validator = lastModified(&modified_buffer, (try file.stat(io)).mtime);
    const range_headers = try std.fmt.allocPrint(t.allocator, "Range: bytes=2-4\r\nIf-Range: {s}\r\n", .{validator});
    defer t.allocator.free(range_headers);
    const conditional = try testResponse(file, "GET", range_headers);
    defer t.allocator.free(conditional);
    try t.expect(std.mem.indexOf(u8, conditional, "206 Partial Content") != null);
    try t.expect(std.mem.endsWith(u8, conditional, "\r\n\r\n234"));
}

test "file HTTP streams a complete file larger than 32 MiB from its held descriptor" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "large.bin", .{ .read = true });
    defer file.close(io);
    const size = 33 * 1024 * 1024 + 19;
    // Sparse fixture plus boundary markers: compare every byte in the response.
    try file.setLength(io, size);
    try file.writePositionalAll(io, "start", 0);
    try file.writePositionalAll(io, "end", size - 3);
    try tmp.dir.deleteFile(io, "large.bin");
    const response = try testResponse(file, "GET", "");
    defer t.allocator.free(response);
    const body_start = (std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.MissingHeaders) + 4;
    const body = response[body_start..];
    try t.expectEqual(size, body.len);
    try t.expectEqualStrings("start", body[0..5]);
    try t.expectEqualStrings("end", body[size - 3 ..]);
    try t.expect(std.mem.allEqual(u8, body[5 .. size - 3], 0));
}
