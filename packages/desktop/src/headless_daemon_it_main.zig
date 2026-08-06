//! Hermetic headless client ↔ session-daemon integration binary.
//!
//! Spawns an isolated session-daemon subprocess that listens only on a tmp
//! pref dir, then exercises the typed headless client. Never touches the
//! user's live socket, daemon, or DB.
//!
//! Built as a dedicated step (`headless-daemon-it`) rather than a unit test so
//! the daemon's idle `process.exit` and multi-thread fork hazards stay out of
//! the Zig test runner.

const std = @import("std");
const builtin = @import("builtin");
const headless = @import("headless");
const platform_paths = @import("platform_paths");
const platform_runtime = @import("platform_runtime");
const sessionizer = @import("terminal/sessionizer.zig");

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const io = init.io;

    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iterator.deinit();
    _ = iterator.next(); // executable

    if (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) {
            const pref_path = iterator.next() orelse {
                std.debug.print("headless-daemon-it --daemon requires pref_path\n", .{});
                std.process.exit(2);
            };
            try sessionizer.runDaemon(allocator, pref_path);
            return;
        }
    }

    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => {
            std.debug.print("headless-daemon-it: skip on this OS\n", .{});
            return;
        },
    }

    try runIntegration(allocator, io);
    std.debug.print("headless-daemon-it: ok\n", .{});
}

fn runIntegration(allocator: std.mem.Allocator, io: std.Io) !void {
    // Isolated pref dir under the system temp path (never the user's Verde pref).
    const base_tmp = try platform_paths.tempDir(allocator);
    defer allocator.free(base_tmp);
    const pref_path = try std.fmt.allocPrint(allocator, "{s}/verde-headless-it-{d}", .{
        base_tmp,
        platform_runtime.processId(),
    });
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    // Spawn a dedicated daemon subprocess that listens only under pref_path.
    var child = try std.process.spawn(io, .{
        .argv = &.{ self_exe, "--daemon", pref_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io);
    defer child.kill(io);

    // Wait until the isolated daemon accepts connections.
    var ready_attempts: usize = 0;
    while (ready_attempts < 250) : (ready_attempts += 1) {
        if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            allocator.free(response);
            break;
        } else |_| {
            std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
    } else {
        std.debug.print("headless-daemon-it: daemon did not become ready\n", .{});
        return error.SessionDaemonUnavailable;
    }

    var transport: sessionizer.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(allocator, &transport);
    const session_id = "verde:headless-it:session";
    var session_created = false;
    defer if (session_created) {
        if (client.call("session.kill", .{ .id = session_id })) |parsed_response| {
            var parsed = parsed_response;
            parsed.deinit();
        } else |_| {}
    };

    {
        // Explicit empty object: bare `.{}` can stringify as `[]` and fail params validation.
        const empty_params: struct {} = .{};
        var parsed = try client.call("core.status", empty_params);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.CoreStatusFailed;
        const result = try client.decodeStatus(&parsed);
        if (result.headless_protocol_version != headless.HEADLESS_PROTOCOL_VERSION) return error.InvalidProtocolVersion;
        if (!result.capabilities.terminal_raw) return error.MissingTerminalCapability;
    }

    {
        const empty_params: struct {} = .{};
        var parsed = try client.call("core.capabilities", empty_params);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.CoreCapabilitiesFailed;
        const result = try client.decodeCapabilities(&parsed);
        if (result.headless_protocol_version != headless.HEADLESS_PROTOCOL_VERSION) return error.InvalidProtocolVersion;
        if (!result.capabilities.terminal_raw) return error.MissingTerminalCapability;
    }

    {
        const empty_params: struct {} = .{};
        var parsed = try client.call("core.unknown", empty_params);
        defer parsed.deinit();
        if (parsed.response.isOk()) return error.UnknownMethodUnexpectedlySucceeded;
        const err = parsed.response.err orelse return error.MissingUnknownMethodError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_UNKNOWN_METHOD)) return error.WrongUnknownMethodError;
    }

    {
        var parsed = try client.call("session.create", .{
            .id = session_id,
            .cwd = pref_path,
            .command = &[_][]const u8{"/bin/cat"},
            .cols = sessionizer.DEFAULT_COLS,
            .rows = sessionizer.DEFAULT_ROWS,
        });
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.SessionCreateFailed;
        session_created = true;
    }

    {
        var parsed = try client.call("session.write", .{
            .id = session_id,
            .text = "headless-it-marker\n",
        });
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.SessionWriteFailed;
    }

    var saw_marker = false;
    var tail_attempts: usize = 0;
    while (tail_attempts < 100) : (tail_attempts += 1) {
        var parsed = try client.call("session.tail", .{
            .id = session_id,
            .lines = 40,
        });
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.SessionTailFailed;
        const result = parsed.response.result orelse return error.MissingResult;
        if (result == .object) {
            if (result.object.get("text")) |text_value| {
                if (text_value == .string and std.mem.indexOf(u8, text_value.string, "headless-it-marker") != null) {
                    saw_marker = true;
                    break;
                }
            }
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    if (!saw_marker) return error.MarkerNotObserved;

    {
        var parsed = try client.call("session.kill", .{ .id = session_id });
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.SessionKillFailed;
        session_created = false;
    }

    _ = headless.HEADLESS_PROTOCOL_VERSION;
}
