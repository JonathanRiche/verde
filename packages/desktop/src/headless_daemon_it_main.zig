//! Hermetic headless client ↔ session-daemon integration binary.
//!
//! Spawns an isolated session-daemon subprocess that listens only on a tmp
//! pref dir, then exercises the typed headless client and daemon lifecycle.
//! Never touches the user's live socket, daemon, or DB.
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
            // Optional --parent-pid so a panicked/aborted IT parent cannot leave
            // an orphan daemon (defers are skipped on panic/abort).
            var parent_pid: ?std.posix.pid_t = null;
            while (iterator.next()) |flag| {
                if (std.mem.eql(u8, flag, "--parent-pid")) {
                    const raw = iterator.next() orelse {
                        std.debug.print("headless-daemon-it --daemon --parent-pid requires a pid\n", .{});
                        std.process.exit(2);
                    };
                    parent_pid = std.fmt.parseInt(std.posix.pid_t, raw, 10) catch {
                        std.debug.print("headless-daemon-it: invalid --parent-pid\n", .{});
                        std.process.exit(2);
                    };
                }
            }
            installItDaemonCleanupGuards(parent_pid);
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
    try runLifecycleBindGuard(allocator, io);
    try runLifecyclePrepareShutdownWithLivePty(allocator, io);
    try runLifecycleIdleExitOverride(allocator, io);
    std.debug.print("headless-daemon-it: ok\n", .{});
}

fn makePrefPath(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    const base_tmp = try platform_paths.tempDir(allocator);
    defer allocator.free(base_tmp);
    return std.fmt.allocPrint(allocator, "{s}/verde-headless-it-{s}-{d}", .{
        base_tmp,
        label,
        platform_runtime.processId(),
    });
}

fn spawnIsolatedDaemon(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
) !std.process.Child {
    return spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, null);
}

fn spawnIsolatedDaemonWithEnv(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
    idle_exit_ms: ?[]const u8,
) !std.process.Child {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();
    if (idle_exit_ms) |value| {
        try env_map.put("VERDE_SESSION_DAEMON_IDLE_EXIT_MS", value);
    } else {
        _ = env_map.swapRemove("VERDE_SESSION_DAEMON_IDLE_EXIT_MS");
    }

    // Pass the IT parent pid so the --daemon child can self-terminate if this
    // process panics/aborts (defers do not run). Prefer getpid over getppid in
    // the child so nested wrappers cannot confuse the guard.
    var parent_pid_buf: [32]u8 = undefined;
    const parent_pid_arg = try std.fmt.bufPrint(&parent_pid_buf, "{d}", .{platform_runtime.processId()});

    var child = try std.process.spawn(io, .{
        .argv = &.{ self_exe, "--daemon", pref_path, "--parent-pid", parent_pid_arg },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &env_map,
    });
    errdefer child.kill(io);

    var ready_attempts: usize = 0;
    while (ready_attempts < 250) : (ready_attempts += 1) {
        if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            allocator.free(response);
            return child;
        } else |_| {
            std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
    }
    std.debug.print("headless-daemon-it: daemon did not become ready ({s})\n", .{pref_path});
    return error.SessionDaemonUnavailable;
}

fn currentEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

/// Ensure IT daemon children do not outlive a crashed parent.
///
/// Linux: PR_SET_PDEATHSIG delivers SIGTERM when the parent dies (covers
/// panic/abort where parent defers never run). Portable fallback: a poll
/// thread watches `--parent-pid` via kill(pid, 0) and process.exit's when gone.
/// Empty-daemon idle exit remains a separate env override (see lifecycle tests).
fn installItDaemonCleanupGuards(parent_pid: ?std.posix.pid_t) void {
    if (builtin.os.tag == .linux) {
        // Race: parent may die between fork and prctl; check after arming.
        _ = std.posix.prctl(.SET_PDEATHSIG, .{@as(usize, @intFromEnum(std.posix.SIG.TERM))}) catch {};
        // Parent may have already died between spawn and prctl; reparented to init.
        if (std.posix.getppid() == 1) {
            std.process.exit(0);
        }
    }
    if (parent_pid) |pid| {
        const thread = std.Thread.spawn(.{}, parentDeathWatchThread, .{pid}) catch return;
        thread.detach();
    }
}

fn parentDeathWatchThread(parent_pid: std.posix.pid_t) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    while (true) {
        // Signal 0 only checks liveness (portable parent-death fallback).
        std.posix.kill(parent_pid, @enumFromInt(0)) catch {
            // Parent is gone (or not killable): exit so orphan PTYs die with us.
            std.process.exit(0);
        };
        std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }
}

fn runIntegration(allocator: std.mem.Allocator, io: std.Io) !void {
    // Isolated pref dir under the system temp path (never the user's Verde pref).
    const pref_path = try makePrefPath(allocator, "core");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

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

/// Live socket must not be stolen; stale socket path may be reclaimed.
fn runLifecycleBindGuard(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "bind");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    // Stale socket file with nothing accepting: daemon must still start.
    const socket = try sessionizer.socketPath(allocator, pref_path);
    defer allocator.free(socket);
    {
        var file = try std.Io.Dir.cwd().createFile(io, socket, .{});
        file.close(io);
    }

    var first = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer first.kill(io);

    // Second daemon on the same pref must refuse (live endpoint), not unlink.
    // No parent-pid guard needed: this process exits immediately on EndpointInUse.
    var second = try std.process.spawn(io, .{
        .argv = &.{ self_exe, "--daemon", pref_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const second_term = try second.wait(io);
    switch (second_term) {
        .exited => |code| {
            if (code == 0) return error.SecondDaemonStoleEndpoint;
        },
        else => {},
    }

    // Original daemon still answers.
    const status = try sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0);
    defer allocator.free(status);
    if (std.mem.indexOf(u8, status, "protocol_version") == null) return error.LiveDaemonLostAfterBindRace;
}

/// Replacement prepareShutdown while a live PTY exists must refuse, not kill.
fn runLifecyclePrepareShutdownWithLivePty(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "prepare");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    const session_id = "verde:headless-it:prepare-pty";
    {
        const create = try sessionizer.requestAlloc(allocator, pref_path, "session.create", .{
            .id = session_id,
            .cwd = pref_path,
            .command = &[_][]const u8{"/bin/cat"},
            .cols = sessionizer.DEFAULT_COLS,
            .rows = sessionizer.DEFAULT_ROWS,
        }, 1);
        defer allocator.free(create);
        if (std.mem.indexOf(u8, create, "\"created\":true") == null and
            std.mem.indexOf(u8, create, "\"created\": true") == null)
        {
            // created may be false only on reuse; first create must succeed.
            if (std.mem.indexOf(u8, create, "\"error\"") != null) return error.SessionCreateFailed;
        }
    }

    const prepare = try sessionizer.requestAlloc(allocator, pref_path, "daemon.prepareShutdown", .{}, 2);
    defer allocator.free(prepare);
    if (std.mem.indexOf(u8, prepare, "\"accepted\":false") == null and
        std.mem.indexOf(u8, prepare, "\"accepted\": false") == null)
    {
        return error.PrepareShutdownShouldRefuseLivePty;
    }
    if (std.mem.indexOf(u8, prepare, "\"safe_to_exit\":false") == null and
        std.mem.indexOf(u8, prepare, "\"safe_to_exit\": false") == null)
    {
        return error.PrepareShutdownShouldNotBeSafeWithLivePty;
    }

    // Daemon still alive with the same session.
    const status = try sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 3);
    defer allocator.free(status);
    if (std.mem.indexOf(u8, status, "protocol_version") == null) return error.DaemonDiedDuringPrepare;
    if (std.mem.indexOf(u8, status, "\"running_session_count\":1") == null and
        std.mem.indexOf(u8, status, "\"running_session_count\": 1") == null)
    {
        // Fall back: session still listable.
        const list = try sessionizer.requestAlloc(allocator, pref_path, "session.list", .{}, 4);
        defer allocator.free(list);
        if (std.mem.indexOf(u8, list, session_id) == null) return error.LivePtyDestroyedOnPrepare;
    }

    _ = try sessionizer.requestAlloc(allocator, pref_path, "session.kill", .{ .id = session_id }, 5);
}

/// Env override enables fast idle exit for hermetic tests; default is persistent.
fn runLifecycleIdleExitOverride(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "idle");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, "100");
    // Do not kill: idle exit should terminate the empty daemon.

    // Confirm the daemon advertised the override before waiting for exit.
    {
        const status = try sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0);
        defer allocator.free(status);
        if (std.mem.indexOf(u8, status, "\"idle_exit_ms\":100") == null and
            std.mem.indexOf(u8, status, "\"idle_exit_ms\": 100") == null)
        {
            child.kill(io);
            std.debug.print("headless-daemon-it: status missing idle override: {s}\n", .{status});
            return error.IdleExitOverrideNotApplied;
        }
    }

    var exited = false;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            allocator.free(response);
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            continue;
        } else |_| {
            exited = true;
            break;
        }
    }
    if (!exited) {
        child.kill(io);
        return error.IdleExitDidNotFire;
    }
    // Reap the exited child to avoid zombies.
    _ = child.wait(io) catch {};
}
