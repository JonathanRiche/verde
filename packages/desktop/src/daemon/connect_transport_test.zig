//! Actual native HTTPS transport tests, not the fake protocol transport.
const std = @import("std");
const builtin = @import("builtin");
const connect = @import("connect_client.zig");
const tls_fixture = @import("connect_tls_fixture.zig");

const BEARER = "synthetic-connect-fixture-credential-0001";
const BODY = "{\"contract_version\":\"1\",\"request_id\":\"req_11111111111111111111111111111111\"}";

test "native Connect DELETE TLS framing bounds failures and unchanged POST" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    var fixture = try tls_fixture.Fixture.init(allocator, io, directory);
    defer fixture.deinit(allocator, io);
    var native: connect.HttpTransport = .{ .test_ca_file = fixture.ca_file };
    for ([_]std.http.Method{ .DELETE, .POST }) |method| {
        const url = try std.fmt.allocPrint(allocator, "{s}/ok", .{fixture.base_url});
        defer allocator.free(url);
        var response = try native.transport().send(allocator, .{ .method = method, .url = url, .body = BODY, .bearer_token = BEARER });
        defer response.deinit(allocator);
        try std.testing.expectEqual(.ok, response.status);
        try std.testing.expectEqualStrings("{\"ok\":true}", response.body);
    }
    const log = try tmp.dir.readFileAlloc(io, "requests.jsonl", allocator, .limited(8192));
    defer allocator.free(log);
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        const Entry = struct { method: []const u8, path: []const u8, headers: []const [2][]const u8, body: []const u8 };
        var entry = try std.json.parseFromSlice(Entry, allocator, line, .{});
        defer entry.deinit();
        try std.testing.expectEqualStrings(if (count == 0) "DELETE" else "POST", entry.value.method);
        try std.testing.expectEqualStrings("/ok", entry.value.path);
        try std.testing.expectEqualStrings(BODY, entry.value.body);
        var lengths: usize = 0;
        var authorization: usize = 0;
        for (entry.value.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header[0], "content-length")) {
                lengths += 1;
                try std.testing.expectEqual(BODY.len, try std.fmt.parseInt(usize, header[1], 10));
            }
            if (std.ascii.eqlIgnoreCase(header[0], "authorization")) {
                authorization += 1;
                try std.testing.expectEqualStrings("Bearer " ++ BEARER, header[1]);
            }
            try std.testing.expect(!std.ascii.eqlIgnoreCase(header[0], "transfer-encoding"));
            if (std.ascii.eqlIgnoreCase(header[0], "connection")) try std.testing.expectEqualStrings("close", header[1]);
        }
        try std.testing.expectEqual(@as(usize, 1), lengths);
        try std.testing.expectEqual(@as(usize, 1), authorization);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    const url_non200 = try std.fmt.allocPrint(allocator, "{s}/non200", .{fixture.base_url});
    defer allocator.free(url_non200);
    var rejected = try native.transport().send(allocator, .{ .method = .DELETE, .url = url_non200, .body = BODY });
    defer rejected.deinit(allocator);
    try std.testing.expectEqual(.forbidden, rejected.status);
    const protocol_client = try connect.Client.init(allocator, native.transport(), fixture.base_url);
    try std.testing.expectError(error.ConnectAuthenticationRejected, protocol_client.authenticatedJson(.DELETE, "/non200", BEARER, BODY, &.{.ok}));
    for ([_][]const u8{ "/redirect", "/truncated", "/oversize", "/delay" }) |path| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ fixture.base_url, path });
        defer allocator.free(url);
        const started = std.Io.Clock.awake.now(io);
        if (native.transport().send(allocator, .{ .method = .DELETE, .url = url, .body = BODY, .timeout_ms = if (std.mem.eql(u8, path, "/delay")) 50 else 5000 })) |value| {
            var unexpected = value;
            unexpected.deinit(allocator);
            std.debug.print("unexpected native Connect success at {s}\n", .{path});
            return error.UnexpectedNativeConnectSuccess;
        } else |err| {
            if (std.mem.eql(u8, path, "/truncated")) try std.testing.expectEqual(error.ControlPlaneResponseTruncated, err);
            if (std.mem.eql(u8, path, "/oversize")) try std.testing.expectEqual(error.ControlPlaneResponseTooLarge, err);
            if (std.mem.eql(u8, path, "/delay")) try std.testing.expectEqual(error.ControlPlaneTimedOut, err);
        }
        if (std.mem.eql(u8, path, "/delay")) {
            try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds < std.time.ns_per_s * 2);
            const recovery_url = try std.fmt.allocPrint(allocator, "{s}/ok", .{fixture.base_url});
            defer allocator.free(recovery_url);
            var recovery = try native.transport().send(allocator, .{ .method = .DELETE, .url = recovery_url, .body = BODY });
            defer recovery.deinit(allocator);
            try std.testing.expectEqual(.ok, recovery.status);
        }
    }
    const wrong_host = try std.mem.replaceOwned(u8, allocator, fixture.base_url, "localhost", "127.0.0.1");
    defer allocator.free(wrong_host);
    var untrusted: connect.HttpTransport = .{};
    for ([_]*connect.HttpTransport{ &native, &untrusted }, [_][]const u8{ wrong_host, fixture.base_url }) |transport, url| {
        if (transport.transport().send(allocator, .{ .method = .DELETE, .url = url, .body = BODY })) |value| {
            var unexpected = value;
            unexpected.deinit(allocator);
            return error.NativeTlsVerificationBypassed;
        } else |_| {}
    }
    const final_log = try tmp.dir.readFileAlloc(io, "requests.jsonl", allocator, .limited(16384));
    defer allocator.free(final_log);
    var final_lines = std.mem.tokenizeScalar(u8, final_log, '\n');
    var final_count: usize = 0;
    var ok_count: usize = 0;
    while (final_lines.next()) |line| {
        final_count += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.object.get("path").?.string, "/ok")) ok_count += 1;
    }
    // No redirected request, retry, or HTTP request after TLS verification fails.
    try std.testing.expectEqual(@as(usize, 9), final_count);
    try std.testing.expectEqual(@as(usize, 3), ok_count);
}

test "native Connect DELETE completes compressed framing and refuses missing terminators" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    var fixture = try tls_fixture.Fixture.init(allocator, io, directory);
    defer fixture.deinit(allocator, io);
    var native: connect.HttpTransport = .{ .test_ca_file = fixture.ca_file };
    for ([_][]const u8{ "/gzip-length", "/gzip-chunked", "/chunked" }) |path| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ fixture.base_url, path });
        defer allocator.free(url);
        var response = try native.transport().send(allocator, .{ .method = .DELETE, .url = url, .body = BODY });
        defer response.deinit(allocator);
        try std.testing.expectEqual(.ok, response.status);
        try std.testing.expectEqualStrings("{\"ok\":true}", response.body);
    }
    for ([_][]const u8{ "/gzip-truncated-length", "/gzip-truncated-chunk", "/gzip-delay-terminator" }) |path| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ fixture.base_url, path });
        defer allocator.free(url);
        const started = std.Io.Clock.awake.now(io);
        const expected = if (std.mem.eql(u8, path, "/gzip-delay-terminator")) error.ControlPlaneTimedOut else if (std.mem.eql(u8, path, "/gzip-truncated-chunk")) error.HttpChunkTruncated else error.ControlPlaneResponseTruncated;
        try std.testing.expectError(expected, native.transport().send(allocator, .{ .method = .DELETE, .url = url, .body = BODY, .timeout_ms = if (expected == error.ControlPlaneTimedOut) 50 else 5000 }));
        try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds < std.time.ns_per_s * 2);
    }
}
