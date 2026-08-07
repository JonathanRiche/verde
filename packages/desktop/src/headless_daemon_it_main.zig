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
const platform_ipc = @import("platform/ipc.zig");
const platform_paths = @import("platform_paths");
const platform_runtime = @import("platform_runtime");
const sessionizer = @import("terminal/sessionizer.zig");
const zqlite = @import("zqlite");

/// PTY / process-group / Unix-signal scenarios (forkpty, waitpid, kill(pid,0)).
const posix_pty_supported = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};
/// Daemon transport scenarios (Unix socket today; named pipe on Windows).
const daemon_transport_supported = posix_pty_supported or builtin.os.tag == .windows;

// Pinned windows-gnu IT cross-compile (A3 gate). Bare `-Dtarget=…` fails on this
// host without SDL3/WebView2 search paths; use the same dep flags as
// `scripts/dev/build-windows.sh` after `python3 scripts/dev/bootstrap_windows_deps.py --toolchain gnu`:
//
//   deps=$PWD/.zig-cache/windows-deps/gnu
//   zig build headless-daemon-it -Dtarget=x86_64-windows-gnu \
//     -Dbrowser-backend=native_webview -Dterminal_backend=true -Dlocal_ipc=true \
//     -Dwindows_integrations=true -Dfff-cargo-target=x86_64-pc-windows-gnu \
//     -Dsdl3-include-dir=$deps/include -Dsdl3-lib-dir=$deps/lib \
//     -Dsdl3-runtime-lib=$deps/bin/SDL3.dll \
//     -Dsdl3-ttf-include-dir=$deps/include -Dsdl3-ttf-lib-dir=$deps/lib \
//     -Dsdl3-ttf-runtime-lib=$deps/bin/SDL3_ttf.dll \
//     -Dwebview2-include-dir=$deps/include \
//     -Dwebview2-loader-lib=$deps/lib/libWebView2Loader.a \
//     -Dwebview2-loader-dll=$deps/bin/WebView2Loader.dll \
//     --summary all

const c = struct {
    // POSIX process-env mutation (not available on the Windows CRT).
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    // MSVCRT / mingw process-env mutation used by the Windows branch.
    extern "c" fn _putenv_s(varname: [*:0]const u8, value_string: [*:0]const u8) c_int;
};

/// Safety-net idle for every IT daemon so a crashed run cannot leave a
/// permanent daemon+socket when persistent-by-default is enabled.
const IT_SAFETY_IDLE_EXIT_MS = "30000";

/// The Unix accept loop invokes each client callback synchronously
/// (packages/desktop/src/platform/ipc.zig:115-121), so this scenario's second
/// connection cannot reach the fast path during Phase B until M5-P3 lands
/// concurrent transport. Set true when M5-P3 lands concurrent transport.
const CONCURRENT_TRANSPORT_LANDED = false;

// Force semantic analysis for OS-gated helpers whose only runtime callers sit
// behind a comptime-false tier on the other OS (lazy analysis would elide them).
// - POSIX: M5-P3 timing scenario trio (never run on Windows).
// - Windows: waitChildBounded's WaitForSingleObject arm (only caller is PTY-tier
//   lifecycle bind guard, which is elided under windows-gnu).
comptime {
    if (posix_pty_supported) {
        _ = &runSlowConfigDoesNotBlockTailScenario;
        _ = &slowStartThread;
        _ = &spawnIsolatedDaemonWithSlowIo;
    }
    if (builtin.os.tag == .windows) {
        _ = &waitChildBounded;
    }
}

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
            // an orphan daemon (defers are skipped on panic/abort). Parse as the
            // platform pid type on POSIX; Windows ignores the flag (no watcher).
            if (comptime posix_pty_supported) {
                var parent_pid: ?std.posix.pid_t = null;
                while (iterator.next()) |flag| {
                    if (std.mem.eql(u8, flag, "--parent-pid")) {
                        const raw = iterator.next() orelse {
                            std.debug.print("headless-daemon-it --daemon --parent-pid requires a pid\n", .{});
                            std.process.exit(2);
                        };
                        // Reject non-positive values (signed pid_t would otherwise
                        // accept negatives the old u32 parse rejected).
                        const parsed = std.fmt.parseInt(std.posix.pid_t, raw, 10) catch {
                            std.debug.print("headless-daemon-it: invalid --parent-pid\n", .{});
                            std.process.exit(2);
                        };
                        if (parsed <= 0) {
                            std.debug.print("headless-daemon-it: invalid --parent-pid\n", .{});
                            std.process.exit(2);
                        }
                        parent_pid = parsed;
                    }
                }
                installItDaemonCleanupGuards(parent_pid, pref_path);
            } else {
                while (iterator.next()) |flag| {
                    if (std.mem.eql(u8, flag, "--parent-pid")) {
                        _ = iterator.next(); // consume value; watcher is POSIX-only
                    }
                }
            }
            try sessionizer.runDaemon(allocator, pref_path);
            return;
        }
    }

    if (!daemon_transport_supported) {
        std.debug.print("headless-daemon-it: skip on this OS\n", .{});
        return;
    }

    // Transport tier first so a Windows subset exits cleanly without PTY work.
    try runRegistryFixtureScenario(allocator, io);
    try runRegistryCapabilityScenario(allocator, io);
    try runRegistryMethodPresenceScenario(allocator, io);
    try runLeaseConflictScenario(allocator, io);
    try runLeaseRenewReleaseScenario(allocator, io);
    try runForcedAcquireOverTransportScenario(allocator, io);

    // Windows-safe store subset (S5): named-pipe transport parity + store off-Unix.
    // Paths use std.fs.path; endpoints via platform isolation (no Unix-socket assumptions).
    // First-pipe ownership stays the transport's job — reuse bind/replace patterns rather
    // than new pipe code. P3 carry-forwards: capability flip, core.snapshot, real-DB
    // dedupe before partial unique index, concurrent-accept tail IT (see m3_track_specs).
    try runStoreLessScenario(allocator, io);
    try runStoreEnabledScenario(allocator, io);
    try runStoreDurableReopenScenario(allocator, io);

    // Extended store scenarios (POSIX only): full surface + S4 fault/busy/crash pins.
    // Transport-tier primitives, but not part of the Windows-safe subset.
    if (posix_pty_supported) {
        try runStoreFullSurfaceScenario(allocator, io);
        try runStoreBoundedQueueingScenario(allocator, io);
        try runStoreBusyRetryScenario(allocator, io);
        try runStoreCrashBeforeCommitScenario(allocator, io);
        try runStoreCrashAfterCommitScenario(allocator, io);
    }

    // PTY tier: sessions, managed spawn, prepare/stop retention, lifecycle.
    if (posix_pty_supported) {
        try runIntegration(allocator, io);
        try runProcessLifecycleScenario(allocator, io);
        try runManagedProcessScenario(allocator, io);
        if (CONCURRENT_TRANSPORT_LANDED) {
            try runSlowConfigDoesNotBlockTailScenario(allocator, io);
        } else {
            std.debug.print("headless-daemon-it: skip runSlowConfigDoesNotBlockTailScenario (requires concurrent transport; enable when M5-P3 lands)\n", .{});
        }
        try runPrepareGateScenario(allocator, io);
        try runDisconnectedClientRetentionScenario(allocator, io);
        try runScopedStopScenario(allocator, io);
        try runLifecycleBindGuard(allocator, io);
        try runLifecyclePrepareShutdownWithLivePty(allocator, io);
        try runLifecycleGracefulReplace(allocator, io);
        // Store-backed lease/outcome transfer (M2-DT-b). Lifecycle/bind tier:
        // spawns daemons; needs PTY for the finished-terminal-process half.
        try runLifecycleGracefulReplaceWithTransfer(allocator, io);
        try runLifecycleIdleExitOverride(allocator, io);
    }
    std.debug.print("headless-daemon-it: ok\n", .{});
}

fn makePrefPath(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    const base_tmp = try platform_paths.tempDir(allocator);
    defer allocator.free(base_tmp);
    // Forward slashes are fine on Windows path APIs used here; endpoint
    // isolation uses a separate named-pipe name on that OS (see below).
    return std.fmt.allocPrint(allocator, "{s}/verde-headless-it-{s}-{d}", .{
        base_tmp,
        label,
        platform_runtime.processId(),
    });
}

/// Hermetic endpoint for IT parent+child. POSIX: pref-dir Unix socket.
/// Windows: unique named pipe so isolation never collides with the live pipe.
fn isolationEndpoint(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .windows) {
        // Spec shape: \\.\pipe\verde-it-{pid}-{nonce}. Nonce = pref-path hash
        // so concurrent scenarios in one process stay unique.
        const nonce = std.hash.Wyhash.hash(0, pref_path);
        return std.fmt.allocPrint(allocator, "\\\\.\\pipe\\verde-it-{d}-{x:0>16}", .{
            platform_runtime.processId(),
            nonce,
        });
    }
    return sessionizer.defaultSocketPath(allocator, pref_path);
}

fn itSetEnv(name: [*:0]const u8, value: [*:0]const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        // CRT `_putenv_s(name, "")` DELETEs the variable rather than storing an
        // empty value. Callers must never set an empty endpoint; use itUnsetEnv
        // for removal and restore only non-empty previous values.
        if (c._putenv_s(name, value) != 0) return error.SetEnvFailed;
    } else {
        if (c.setenv(name, value, 1) != 0) return error.SetEnvFailed;
    }
}

fn itUnsetEnv(name: [*:0]const u8) void {
    if (comptime builtin.os.tag == .windows) {
        // Empty value is the CRT delete convention (see itSetEnv).
        _ = c._putenv_s(name, "");
    } else {
        _ = c.unsetenv(name);
    }
}

fn itGetEnvAlloc(allocator: std.mem.Allocator, name: [:0]const u8) !?[]u8 {
    if (comptime builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        return environ.getAlloc(allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => null,
            else => return err,
        };
    }
    if (std.c.getenv(name.ptr)) |p| return try allocator.dupe(u8, std.mem.span(p));
    return null;
}

/// Install `VERDE_SESSIONIZER_SOCKET` for both this process and the child so
/// neither can fall through to the user's live daemon endpoint.
const EndpointIsolation = struct {
    endpoint: []u8,
    /// Owned copy of the previous env value (if any); restored on deinit.
    prev_socket: ?[]u8,

    fn install(allocator: std.mem.Allocator, pref_path: []const u8) !EndpointIsolation {
        // Isolation endpoint (ignores ambient override) so IT never binds live.
        const endpoint = try isolationEndpoint(allocator, pref_path);
        errdefer allocator.free(endpoint);
        const prev_owned = try itGetEnvAlloc(allocator, sessionizer.SESSIONIZER_SOCKET_ENV_NAME);
        errdefer if (prev_owned) |v| allocator.free(v);

        const endpoint_z = try allocator.dupeZ(u8, endpoint);
        defer allocator.free(endpoint_z);
        try itSetEnv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME, endpoint_z.ptr);
        return .{
            .endpoint = endpoint,
            .prev_socket = prev_owned,
        };
    }

    fn deinit(self: *EndpointIsolation, allocator: std.mem.Allocator) void {
        if (self.prev_socket) |value| {
            const value_z = allocator.dupeZ(u8, value) catch {
                itUnsetEnv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME);
                allocator.free(value);
                allocator.free(self.endpoint);
                self.* = undefined;
                return;
            };
            defer allocator.free(value_z);
            itSetEnv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME, value_z.ptr) catch {
                itUnsetEnv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME);
            };
            allocator.free(value);
        } else {
            itUnsetEnv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME);
        }
        allocator.free(self.endpoint);
        self.* = undefined;
    }
};

/// Spawn options for hermetic IT daemons. S4 adds `store_fault` (B9 arm names).
const IsolatedDaemonOptions = struct {
    idle_exit_ms: ?[]const u8 = null,
    store_dir: ?[]const u8 = null,
    /// When set with `store_dir`, maps to `VERDE_SESSION_DAEMON_STORE_FAULT`.
    store_fault: ?[]const u8 = null,
    slow_io_ms: ?[]const u8 = null,
    retention_ms: ?[]const u8 = null,
};

fn spawnIsolatedDaemon(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
) !std.process.Child {
    return spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{});
}

fn spawnIsolatedDaemonWithEnv(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
    options: IsolatedDaemonOptions,
) !std.process.Child {
    return spawnIsolatedDaemonWithOptions(allocator, io, self_exe, pref_path, options);
}

fn spawnIsolatedDaemonWithRetention(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
    retention_ms: []const u8,
) !std.process.Child {
    return spawnIsolatedDaemonWithOptions(allocator, io, self_exe, pref_path, .{
        .idle_exit_ms = IT_SAFETY_IDLE_EXIT_MS,
        .retention_ms = retention_ms,
    });
}

fn spawnIsolatedDaemonWithSlowIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
    slow_io_ms: []const u8,
) !std.process.Child {
    return spawnIsolatedDaemonWithOptions(allocator, io, self_exe, pref_path, .{
        .idle_exit_ms = IT_SAFETY_IDLE_EXIT_MS,
        .slow_io_ms = slow_io_ms,
    });
}

fn spawnIsolatedDaemonWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
    options: IsolatedDaemonOptions,
) !std.process.Child {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();

    // Always set a safety-net idle so a crashed IT cannot leak a permanent daemon.
    // Per-test tighter overrides still win when provided.
    try env_map.put("VERDE_SESSION_DAEMON_IDLE_EXIT_MS", options.idle_exit_ms orelse IT_SAFETY_IDLE_EXIT_MS);
    if (options.slow_io_ms) |value| try env_map.put("VERDE_SESSIONIZER_TEST_SLOW_IO_MS", value);
    if (options.retention_ms) |value| try env_map.put("VERDE_SESSIONIZER_TEST_RETENTION_MS", value);
    if (options.store_dir) |value| try env_map.put(sessionizer.SESSION_DAEMON_STORE_DIR_ENV_NAME, value);
    // B9: fault env is only meaningful with the store-dir override.
    if (options.store_fault) |value| try env_map.put(sessionizer.SESSION_DAEMON_STORE_FAULT_ENV_NAME, value);

    // Bind the child to the same isolated endpoint the parent uses.
    const endpoint = try isolationEndpoint(allocator, pref_path);
    defer allocator.free(endpoint);
    try env_map.put(sessionizer.SESSIONIZER_SOCKET_ENV_NAME, endpoint);

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
/// A poll thread watches `--parent-pid` via kill(pid, 0). It deliberately owns
/// parent-death handling on every Unix so Linux does not take an unclean
/// PDEATHSIG exit before the watcher can terminate PTYs and remove IT files.
/// Empty-daemon idle exit remains a separate env override (see lifecycle tests).
///
/// On Windows the watcher is compiled out: kill(pid,0) has no equivalent in
/// the transport-tier subset, and A3's gate is compile+subset rather than a
/// full orphan-reaper on named pipes. Callers on non-POSIX must not invoke this.
fn installItDaemonCleanupGuards(parent_pid: ?std.posix.pid_t, pref_path: []const u8) void {
    if (comptime !posix_pty_supported) return;
    if (parent_pid) |pid| {
        const thread = std.Thread.spawn(.{}, parentDeathWatchThread, .{ pid, pref_path }) catch return;
        thread.detach();
    }
}

fn parentDeathWatchThread(parent_pid: std.posix.pid_t, pref_path: []const u8) void {
    // Body is only referenced from the POSIX install path; keep the kill probe
    // inside a comptime branch so a windows-gnu analysis of the decl (if any)
    // never sees std.posix.kill.
    if (comptime !posix_pty_supported) return;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    while (true) {
        // Signal 0 only checks liveness (portable parent-death fallback).
        std.posix.kill(parent_pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => {
                cleanupAfterItParentDeath(pref_path, io);
                std.process.exit(1);
            },
            // EPERM and unexpected/transient failures do not prove death.
            else => {},
        };
        std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }
}

/// Bound orphan cleanup so a broken daemon endpoint cannot stall the watcher.
fn cleanupAfterItParentDeath(pref_path: []const u8, io: std.Io) void {
    const allocator = std.heap.page_allocator;
    var attempts: usize = 0;
    while (attempts < 25) : (attempts += 1) {
        const response = sessionizer.requestAlloc(allocator, pref_path, "session.list", .{}, 90) catch break;
        defer allocator.free(response);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch break;
        defer parsed.deinit();

        const result = if (parsed.value == .object)
            parsed.value.object.get("result") orelse break
        else
            break;
        const sessions = if (result == .object)
            result.object.get("sessions") orelse break
        else
            break;
        if (sessions != .array or sessions.array.items.len == 0) break;

        for (sessions.array.items) |session| {
            if (session != .object) continue;
            const id_value = session.object.get("id") orelse continue;
            if (id_value != .string) continue;
            const kill_response = sessionizer.requestAlloc(
                allocator,
                pref_path,
                "session.kill",
                .{ .id = id_value.string },
                91,
            ) catch continue;
            allocator.free(kill_response);
        }
        const cleanup_response = sessionizer.requestAlloc(allocator, pref_path, "session.cleanup", .{}, 92) catch null;
        if (cleanup_response) |owned| allocator.free(owned);
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }

    const socket_path = sessionizer.socketPath(allocator, pref_path) catch null;
    if (socket_path) |path| {
        deleteItPath(io, path);
        allocator.free(path);
    }
    const pid_path = sessionizer.pidFilePath(allocator, pref_path) catch null;
    if (pid_path) |path| {
        deleteItPath(io, path);
        allocator.free(path);
    }
}

fn deleteItPath(io: std.Io, path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    } else {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

/// Connect/EOF-class transport errors: the peer is gone or mid-teardown.
/// Matches the durable exit-wait discrimination plus the EOF class seen when
/// prepareShutdown's drain thread tears down the endpoint under a racing probe
/// (ConnectionResetByPeer / ConnectionAborted). Not OOM/protocol/timeouts.
fn isConnectClassError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.FileNotFound,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        => true,
        else => false,
    };
}

/// Wait for a child to exit with a deadline; kill on timeout so a regression
/// fails instead of hanging the IT binary forever.
fn waitChildBounded(child: *std.process.Child, io: std.Io, timeout_ms: u64) !std.process.Child.Term {
    const deadline = sessionizer.nowMs() + @as(i64, @intCast(timeout_ms));
    if (comptime posix_pty_supported) {
        const pid = child.id orelse return error.ChildAlreadyWaited;
        while (sessionizer.nowMs() <= deadline) {
            var status: c_int = 0;
            const rc = std.c.waitpid(pid, &status, @intCast(std.posix.W.NOHANG));
            if (rc == pid) {
                child.id = null;
                const st: u32 = @bitCast(@as(i32, status));
                if (std.posix.W.IFEXITED(st)) return .{ .exited = std.posix.W.EXITSTATUS(st) };
                if (std.posix.W.IFSIGNALED(st)) return .{ .signal = std.posix.W.TERMSIG(st) };
                if (std.posix.W.IFSTOPPED(st)) return .{ .stopped = std.posix.W.STOPSIG(st) };
                return .{ .unknown = st };
            }
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
        }
        child.kill(io);
        return error.ChildTimedOut;
    }
    if (comptime builtin.os.tag == .windows) {
        // Poll the process handle (id is hProcess on Windows). On timeout,
        // Child.kill already waits for TerminateProcess, so we do not need a
        // second bounded wait — tradeoff: kill path is unbounded only by the
        // OS force-terminate latency, not by waitpid-style polling.
        const handle = child.id orelse return error.ChildAlreadyWaited;
        while (sessionizer.nowMs() <= deadline) {
            const wait_rc = WaitForSingleObject(handle, 0);
            if (wait_rc == WAIT_OBJECT_0) {
                return try child.wait(io);
            }
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
        }
        child.kill(io);
        return error.ChildTimedOut;
    }
    return error.UnsupportedOs;
}

// Windows-only symbols for waitChildBounded; referenced only under the
// windows comptime branch so the linux native binary does not need them.
const WaitForSingleObject = if (builtin.os.tag == .windows)
    struct {
        extern "kernel32" fn WaitForSingleObject(handle: std.os.windows.HANDLE, milliseconds: std.os.windows.DWORD) callconv(.winapi) std.os.windows.DWORD;
    }.WaitForSingleObject
else
    struct {
        fn WaitForSingleObject(_: *anyopaque, _: u32) u32 {
            return 0;
        }
    }.WaitForSingleObject;
const WAIT_OBJECT_0: u32 = 0;

/// The existing sessionizer uses this compatibility code for methods that have
/// not reached its dispatcher yet.  `capability_unavailable` is the typed
/// headless error used by optional surfaces; both are valid interim responses
/// while the phase-2 daemon hooks remain unimplemented.
const FIXTURE_METHOD_NOT_FOUND: []const u8 = "method_not_found";

// W6 appends daemon.stop here. Keep this canonical presence list growing.
const DISPATCHED_REGISTRY_METHODS = [_][]const u8{
    headless.registry.METHOD_WORKSPACE_RESOLVE,
    headless.registry.METHOD_PROCESS_LIST,
    headless.registry.METHOD_PROCESS_INSPECT,
    headless.registry.METHOD_PROCESS_WAIT,
    headless.registry.METHOD_PROCESS_LOGS,
    headless.registry.METHOD_PROCESS_START,
    headless.registry.METHOD_PROCESS_STOP,
    headless.registry.METHOD_PROCESS_RESTART,
    headless.registry.METHOD_LEASE_CHECK,
    headless.registry.METHOD_LEASE_ACQUIRE,
    headless.registry.METHOD_LEASE_RENEW,
    headless.registry.METHOD_LEASE_RELEASE,
    headless.registry.METHOD_DAEMON_NOTIFICATIONS,
    headless.registry.METHOD_DAEMON_CLIENT_REGISTER,
    headless.registry.METHOD_DAEMON_CLIENT_HEARTBEAT,
    headless.registry.METHOD_DAEMON_CLIENT_CLOSE,
    headless.registry.METHOD_DAEMON_STOP,
};

/// Shared scenario plumbing. Typed DTOs are passed to Client.call so the
/// normal headless protocol encoder owns the request envelope and JSON.
const FixtureScenario = struct {
    client: *headless.Client,

    /// Encode and send one registry DTO through the hermetic daemon transport.
    fn registryStep(self: *@This(), method: []const u8, params: anytype) !headless.protocol.ParsedResponse {
        return self.client.call(method, params);
    }

    /// Encode and send one store DTO through the hermetic daemon transport.
    fn storeStep(self: *@This(), method: []const u8, params: anytype) !headless.protocol.ParsedResponse {
        return self.client.call(method, params);
    }

    /// Phase-2 placeholder: session create/exit observations will be attached
    /// to the registry fixture here once the daemon owns registry state.
    fn registrySessionObservationHook(_: *@This(), _: []const u8) void {}

    /// Phase-2 placeholder: the store fixture will open a temporary SQLite
    /// database here once the daemon routes store methods in the IT binary.
    fn storeTemporaryDatabaseHook(_: *@This(), _: []const u8) void {}
};

/// Phase-2 registry fixture: exercise a typed process-list request against the
/// daemon and pin the empty snapshot plus its instance/revision envelope.
fn runRegistryFixtureScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "registry-hooks");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var transport: sessionizer.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(allocator, &transport);
    var scenario: FixtureScenario = .{ .client = &client };
    scenario.registrySessionObservationHook("phase-2-registry-observation");

    const request: headless.registry.ProcessListRequest = .{
        .workspace = .{ .workspace_path = pref_path },
        .include_outcomes = true,
        .include_notifications = true,
    };
    var parsed = try scenario.registryStep(headless.registry.METHOD_PROCESS_LIST, request);
    defer parsed.deinit();
    if (!parsed.response.isOk()) return error.RegistryFixtureRequestFailed;
    const result = try client.decodeProcessList(&parsed);
    if (result.instance_nonce.len == 0) return error.RegistryFixtureMissingInstanceNonce;
    if (result.registry_revision == 0) return error.RegistryFixtureMissingRegistryRevision;
    if (result.workspace.id.len == 0 or !std.mem.eql(u8, result.workspace.path, pref_path)) return error.RegistryFixtureWorkspaceMismatch;
    if (result.processes.len != 0 or result.outcomes.len != 0 or result.leases.len != 0 or result.notifications.len != 0) {
        return error.RegistryFixtureExpectedEmpty;
    }
    if (result.workspace.instance_nonce.len == 0 or result.workspace.registry_revision == 0) {
        return error.RegistryFixtureWorkspaceMissingEnvelope;
    }
}

/// Scenario 7: a daemon-direct typed client must reject registry use when the
/// daemon still advertises the phase-1 capability set.
fn runRegistryCapabilityScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "registry-capability");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var transport: sessionizer.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(allocator, &transport);
    const empty_params: struct {} = .{};
    var parsed = try client.call("core.status", empty_params);
    defer parsed.deinit();
    if (!parsed.response.isOk()) return error.RegistryCapabilityStatusFailed;
    const status = try client.decodeStatus(&parsed);
    if (status.capabilities.processes or status.capabilities.leases) return error.RegistryCapabilityUnexpectedlyAdvertised;
    var capability_rejected = false;
    client.requireDaemonDirectCapability(status.capabilities, .processes) catch |err| switch (err) {
        error.CapabilityUnavailable => capability_rejected = true,
    };
    if (!capability_rejected) return error.RegistryCapabilityUnexpectedlyAvailable;
}

/// Scenario 3: a live PTY is mirrored into the daemon registry and produces one
/// bounded outcome when killed, without advertising the phase-1 capability bit.
fn runProcessLifecycleScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "process-lifecycle");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var transport: sessionizer.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(allocator, &transport);
    // Typed process-list decodes use alloc_always. Keep their copies in a
    // scenario-local arena so each response is independent of its parse arena.
    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var typed_transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var typed_client = sessionizer.headlessClient(decode_arena.allocator(), &typed_transport);

    const session_id = "verde:process-lifecycle:session";
    var session_created = false;
    defer if (session_created) {
        if (client.call("session.kill", .{ .id = session_id })) |parsed_response| {
            var parsed = parsed_response;
            parsed.deinit();
        } else |_| {}
        if (client.call("session.cleanup", .{})) |parsed_response| {
            var parsed = parsed_response;
            parsed.deinit();
        } else |_| {}
    };

    {
        const empty_params: struct {} = .{};
        var capabilities = try client.call("core.capabilities", empty_params);
        defer capabilities.deinit();
        if (!capabilities.response.isOk()) return error.ProcessLifecycleCapabilitiesFailed;
        const capability_result = capabilities.response.result orelse return error.MissingResult;
        if (capability_result != .object) return error.MissingResult;
        const capability_set = capability_result.object.get("capabilities") orelse return error.MissingResult;
        if (capability_set != .object) return error.MissingResult;
        const process_capability = capability_set.object.get("processes") orelse return error.MissingResult;
        if (process_capability == .bool and process_capability.bool) return error.ProcessLifecycleCapabilityUnexpectedlyAdvertised;
    }

    {
        var created = try client.call("session.create", .{
            .id = session_id,
            .cwd = pref_path,
            .workspace_path = pref_path,
            .command = &[_][]const u8{"/bin/cat"},
            .cols = sessionizer.DEFAULT_COLS,
            .rows = sessionizer.DEFAULT_ROWS,
        });
        defer created.deinit();
        if (!created.response.isOk()) return error.ProcessLifecycleSessionCreateFailed;
        session_created = true;
    }

    var process_id: []const u8 = "";
    var first_generation: u64 = 0;
    {
        var listed = try typed_client.call(headless.registry.METHOD_PROCESS_LIST, .{
            .workspace = .{ .workspace_path = pref_path },
        });
        defer listed.deinit();
        if (!listed.response.isOk()) return error.ProcessLifecycleListFailed;
        const result = try typed_client.decodeProcessList(&listed);
        if (result.processes.len != 1) return error.ProcessLifecycleExpectedOneTrackedProcess;
        const process = result.processes[0];
        if (process.kind != .tracked_terminal or !std.mem.startsWith(u8, process.id, "term:")) return error.ProcessLifecycleWrongProcessKind;
        if (!std.mem.eql(u8, process.command, "/bin/cat") or !std.mem.eql(u8, process.cwd, pref_path)) return error.ProcessLifecycleProcessMetadataMismatch;
        process_id = process.id;
        first_generation = std.fmt.parseInt(u64, process.id[std.mem.lastIndexOfScalar(u8, process.id, ':').? + 1 ..], 10) catch return error.ProcessLifecycleBadGeneration;
    }

    {
        var waited = try client.call(headless.registry.METHOD_PROCESS_WAIT, .{
            .workspace = .{ .workspace_path = pref_path },
            .process_id = process_id,
            .timeout_ms = 20_000,
        });
        defer waited.deinit();
        if (!waited.response.isOk()) return error.ProcessLifecycleWaitFailed;
        const result = waited.response.result orelse return error.MissingResult;
        if (result != .object) return error.MissingResult;
        const timed_out = result.object.get("timed_out") orelse return error.MissingResult;
        const terminal_state = result.object.get("terminal_state") orelse return error.MissingResult;
        if (timed_out != .bool or !timed_out.bool or terminal_state != .null) return error.ProcessLifecycleWaitDidNotTimeOut;
    }

    {
        var written = try client.call("session.write", .{
            .id = session_id,
            .text = "process-lifecycle-marker\n",
        });
        defer written.deinit();
        if (!written.response.isOk()) return error.ProcessLifecycleSessionWriteFailed;
    }

    var saw_marker = false;
    var log_attempt: usize = 0;
    while (log_attempt < 100) : (log_attempt += 1) {
        var logs = try client.call(headless.registry.METHOD_PROCESS_LOGS, .{
            .workspace = .{ .workspace_path = pref_path },
            .process_id = process_id,
            .after_cursor = 0,
            .max_bytes = 4096,
        });
        defer logs.deinit();
        if (!logs.response.isOk()) return error.ProcessLifecycleLogsFailed;
        const result = logs.response.result orelse return error.MissingResult;
        if (result != .object) return error.MissingResult;
        if (result.object.get("text")) |text| {
            if (text == .string and std.mem.indexOf(u8, text.string, "process-lifecycle-marker") != null) {
                saw_marker = true;
                break;
            }
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    if (!saw_marker) return error.ProcessLifecycleMarkerNotObserved;

    {
        var killed = try client.call("session.kill", .{ .id = session_id });
        defer killed.deinit();
        if (!killed.response.isOk()) return error.ProcessLifecycleSessionKillFailed;
    }

    var saw_cancelled = false;
    var wait_attempt: usize = 0;
    while (wait_attempt < 100) : (wait_attempt += 1) {
        var waited = try client.call(headless.registry.METHOD_PROCESS_WAIT, .{
            .workspace = .{ .workspace_path = pref_path },
            .process_id = process_id,
        });
        defer waited.deinit();
        if (!waited.response.isOk()) return error.ProcessLifecycleWaitAfterKillFailed;
        const result = waited.response.result orelse return error.MissingResult;
        if (result != .object) return error.MissingResult;
        if (result.object.get("terminal_state")) |state| {
            if (state == .string and std.mem.eql(u8, state.string, "cancelled")) {
                saw_cancelled = true;
                break;
            }
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    if (!saw_cancelled) return error.ProcessLifecycleOutcomeNotObserved;

    {
        var listed = try typed_client.call(headless.registry.METHOD_PROCESS_LIST, .{
            .workspace = .{ .workspace_path = pref_path },
            .include_outcomes = true,
        });
        defer listed.deinit();
        if (!listed.response.isOk()) return error.ProcessLifecycleOutcomeListFailed;
        const result = try typed_client.decodeProcessList(&listed);
        var matching_outcomes: usize = 0;
        for (result.outcomes) |outcome| {
            if (std.mem.eql(u8, outcome.session_id, session_id)) matching_outcomes += 1;
        }
        if (matching_outcomes != 1) return error.ProcessLifecycleOutcomeCountMismatch;
    }

    // A stopped duplicate create is replaced after its outcome is published,
    // so the new observation must have a higher daemon-owned generation.
    {
        var recreated = try client.call("session.create", .{
            .id = session_id,
            .cwd = pref_path,
            .workspace_path = pref_path,
            .command = &[_][]const u8{"/bin/cat"},
            .cols = sessionizer.DEFAULT_COLS,
            .rows = sessionizer.DEFAULT_ROWS,
        });
        defer recreated.deinit();
        if (!recreated.response.isOk()) return error.ProcessLifecycleReplacementCreateFailed;
    }
    {
        var listed = try typed_client.call(headless.registry.METHOD_PROCESS_LIST, .{
            .workspace = .{ .workspace_path = pref_path },
            .include_outcomes = true,
        });
        defer listed.deinit();
        if (!listed.response.isOk()) return error.ProcessLifecycleReplacementListFailed;
        const result = try typed_client.decodeProcessList(&listed);
        if (result.processes.len != 1 or result.outcomes.len != 1) return error.ProcessLifecycleReplacementCountsMismatch;
        const generation = result.processes[0].id[std.mem.lastIndexOfScalar(u8, result.processes[0].id, ':').? + 1 ..];
        const next_generation = std.fmt.parseInt(u64, generation, 10) catch return error.ProcessLifecycleBadReplacementGeneration;
        if (next_generation <= first_generation or std.mem.eql(u8, result.processes[0].id, process_id)) return error.ProcessLifecycleGenerationDidNotAdvance;
    }

    // Remove the replacement before exercising the bounded outcome cap.
    {
        var killed = try client.call("session.kill", .{ .id = session_id });
        defer killed.deinit();
        if (!killed.response.isOk()) return error.ProcessLifecycleReplacementKillFailed;
    }
    var replacement_cleaned = false;
    var cleanup_attempt: usize = 0;
    while (cleanup_attempt < 100) : (cleanup_attempt += 1) {
        var cleaned = try client.call("session.cleanup", .{});
        defer cleaned.deinit();
        if (!cleaned.response.isOk()) return error.ProcessLifecycleCleanupFailed;
        if (cleaned.response.result) |result| {
            if (result == .object) {
                if (result.object.get("removed")) |removed| {
                    if (removed == .integer and removed.integer > 0) {
                        replacement_cleaned = true;
                        break;
                    }
                }
            }
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    if (!replacement_cleaned) return error.ProcessLifecycleReplacementNotCleaned;
    session_created = false;

    for (0..35) |index| {
        const short_session_id = try std.fmt.allocPrint(allocator, "verde:process-lifecycle:short:{d}", .{index});
        defer allocator.free(short_session_id);
        var created = try client.call("session.create", .{
            .id = short_session_id,
            .cwd = pref_path,
            .workspace_path = pref_path,
            .command = &[_][]const u8{"/bin/true"},
        });
        defer created.deinit();
        if (!created.response.isOk()) return error.ProcessLifecycleShortCreateFailed;

        var killed = try client.call("session.kill", .{ .id = short_session_id });
        defer killed.deinit();
        if (!killed.response.isOk()) return error.ProcessLifecycleShortKillFailed;

        var completed = false;
        var short_attempt: usize = 0;
        while (short_attempt < 100) : (short_attempt += 1) {
            var cleaned = try client.call("session.cleanup", .{});
            defer cleaned.deinit();
            if (!cleaned.response.isOk()) return error.ProcessLifecycleShortCleanupFailed;
            var listed = try typed_client.call(headless.registry.METHOD_PROCESS_LIST, .{
                .workspace = .{ .workspace_path = pref_path },
                .include_outcomes = true,
            });
            defer listed.deinit();
            if (!listed.response.isOk()) return error.ProcessLifecycleShortListFailed;
            const result = try typed_client.decodeProcessList(&listed);
            for (result.outcomes) |outcome| {
                if (std.mem.eql(u8, outcome.session_id, short_session_id)) {
                    completed = true;
                    break;
                }
            }
            if (completed) break;
            std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
        if (!completed) return error.ProcessLifecycleShortOutcomeMissing;
    }

    {
        var listed = try typed_client.call(headless.registry.METHOD_PROCESS_LIST, .{
            .workspace = .{ .workspace_path = pref_path },
            .include_outcomes = true,
        });
        defer listed.deinit();
        if (!listed.response.isOk()) return error.ProcessLifecycleCapListFailed;
        const result = try typed_client.decodeProcessList(&listed);
        if (result.outcomes.len > 32) return error.ProcessLifecycleOutcomeCapExceeded;
        if (result.processes.len != 0) return error.ProcessLifecycleLiveSessionsRemain;
    }
}

fn writeManagedProcessConfig(io: std.Io, workspace_path: []const u8, command: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, workspace_path);
    const config_path = try std.fs.path.join(std.heap.page_allocator, &.{ workspace_path, "verde.yml" });
    defer std.heap.page_allocator.free(config_path);
    var file = try std.Io.Dir.cwd().createFile(io, config_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "processes:\n  sleeper:\n    command: \"");
    try file.writeStreamingAll(io, command);
    try file.writeStreamingAll(io, "\"\n");
}

fn managedProcessIdFromResponse(response: *const headless.protocol.ParsedResponse, allocator: std.mem.Allocator) ![]u8 {
    const result = response.response.result orelse return error.ManagedProcessMissingResult;
    if (result != .object) return error.ManagedProcessMalformedResult;
    const process = result.object.get("process") orelse return error.ManagedProcessMissingProcess;
    if (process != .object) return error.ManagedProcessMalformedProcess;
    const id = process.object.get("id") orelse return error.ManagedProcessMissingId;
    if (id != .string) return error.ManagedProcessMalformedId;
    return allocator.dupe(u8, id.string);
}

fn expectManagedList(response: *const headless.protocol.ParsedResponse, expected_id: []const u8) !void {
    const result = response.response.result orelse return error.ManagedProcessListMissingResult;
    if (result != .object) return error.ManagedProcessListMalformedResult;
    const processes = result.object.get("processes") orelse return error.ManagedProcessListMissingProcesses;
    if (processes != .array or processes.array.items.len != 1) return error.ManagedProcessListCountMismatch;
    const process = processes.array.items[0];
    if (process != .object) return error.ManagedProcessListMalformedProcess;
    const id = process.object.get("id") orelse return error.ManagedProcessListMissingId;
    if (id != .string or !std.mem.eql(u8, id.string, expected_id)) return error.ManagedProcessListWrongId;
}

/// Scenario 2: daemon-owned managed records are workspace-scoped even when
/// two projects use the same configured process name.
fn runManagedProcessScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "managed-processes");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    const workspace_a = try std.fmt.allocPrint(allocator, "{s}/workspace-a", .{pref_path});
    defer allocator.free(workspace_a);
    const workspace_b = try std.fmt.allocPrint(allocator, "{s}/workspace-b", .{pref_path});
    defer allocator.free(workspace_b);
    try writeManagedProcessConfig(io, workspace_a, "/bin/cat");
    try writeManagedProcessConfig(io, workspace_b, "/bin/cat");

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{ .idle_exit_ms = "500" });
    var child_exited = false;
    defer if (!child_exited) child.kill(io);

    var transport: sessionizer.HeadlessTransport = .{ .allocator = allocator, .pref_path = pref_path };
    var client = sessionizer.headlessClient(allocator, &transport);
    var process_id_a: ?[]u8 = null;
    var process_id_b: ?[]u8 = null;
    defer {
        if (process_id_a) |process_id| {
            if (client.call(headless.registry.METHOD_PROCESS_STOP, .{
                .workspace = .{ .workspace_path = workspace_a },
                .process_id = process_id,
            })) |response| {
                var owned = response;
                owned.deinit();
            } else |_| {}
            allocator.free(process_id);
        }
        if (process_id_b) |process_id| {
            if (client.call(headless.registry.METHOD_PROCESS_STOP, .{
                .workspace = .{ .workspace_path = workspace_b },
                .process_id = process_id,
            })) |response| {
                var owned = response;
                owned.deinit();
            } else |_| {}
            allocator.free(process_id);
        }
    }
    var start_a = try client.call(headless.registry.METHOD_PROCESS_START, .{
        .workspace = .{ .workspace_path = workspace_a },
        .name = "sleeper",
    });
    defer start_a.deinit();
    if (!start_a.response.isOk()) return error.ManagedProcessStartAFailed;
    process_id_a = try managedProcessIdFromResponse(&start_a, allocator);

    var start_b = try client.call(headless.registry.METHOD_PROCESS_START, .{
        .workspace = .{ .workspace_path = workspace_b },
        .name = "sleeper",
    });
    defer start_b.deinit();
    if (!start_b.response.isOk()) return error.ManagedProcessStartBFailed;
    process_id_b = try managedProcessIdFromResponse(&start_b, allocator);
    if (std.mem.eql(u8, process_id_a.?, process_id_b.?) or
        !std.mem.startsWith(u8, process_id_a.?, "proc:") or
        !std.mem.startsWith(u8, process_id_b.?, "proc:") or
        std.mem.eql(u8, process_id_a.?, "proc:sleeper") or
        std.mem.eql(u8, process_id_b.?, "proc:sleeper")) return error.ManagedProcessIdsNotWorkspaceScoped;

    var listed_a = try client.call(headless.registry.METHOD_PROCESS_LIST, .{ .workspace = .{ .workspace_path = workspace_a } });
    defer listed_a.deinit();
    if (!listed_a.response.isOk()) return error.ManagedProcessListAFailed;
    try expectManagedList(&listed_a, process_id_a.?);

    var listed_b = try client.call(headless.registry.METHOD_PROCESS_LIST, .{ .workspace = .{ .workspace_path = workspace_b } });
    defer listed_b.deinit();
    if (!listed_b.response.isOk()) return error.ManagedProcessListBFailed;
    try expectManagedList(&listed_b, process_id_b.?);

    var stop_a = try client.call(headless.registry.METHOD_PROCESS_STOP, .{
        .workspace = .{ .workspace_path = workspace_a },
        .process_id = process_id_a.?,
    });
    defer stop_a.deinit();
    if (!stop_a.response.isOk()) return error.ManagedProcessStopAFailed;
    var stop_b = try client.call(headless.registry.METHOD_PROCESS_STOP, .{
        .workspace = .{ .workspace_path = workspace_b },
        .process_id = process_id_b.?,
    });
    defer stop_b.deinit();
    if (!stop_b.response.isOk()) return error.ManagedProcessStopBFailed;

    var stopped_a = try client.call(headless.registry.METHOD_PROCESS_LIST, .{ .workspace = .{ .workspace_path = workspace_a } });
    defer stopped_a.deinit();
    try expectManagedList(&stopped_a, process_id_a.?);
    const stopped_result = stopped_a.response.result orelse return error.ManagedProcessStoppedMissingResult;
    const stopped_process = stopped_result.object.get("processes").?.array.items[0].object;
    const stopped_status = stopped_process.get("status") orelse return error.ManagedProcessStopStateMissing;
    if (stopped_status != .string or !std.mem.eql(u8, stopped_status.string, "stopped")) return error.ManagedProcessStopStateMissing;

    var exited = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 300)) |response| {
            allocator.free(response);
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
        } else |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => {
                exited = true;
                break;
            },
            else => std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {},
        }
    }
    if (!exited) return error.ManagedProcessDaemonDidNotExit;
    _ = child.wait(io) catch {};
    child_exited = true;
}

const SlowStartThreadContext = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    workspace_path: []const u8,
    response: ?[]u8 = null,
};

fn slowStartThread(context: *SlowStartThreadContext) void {
    context.response = sessionizer.requestAlloc(context.allocator, context.pref_path, headless.registry.METHOD_PROCESS_START, .{
        .workspace = .{ .workspace_path = context.workspace_path },
        .name = "sleeper",
    }, 401) catch null;
}

/// The config/spawn delay is intentionally larger than the tail deadline. A
/// second connection must still reach the locked fast path during Phase B.
fn runSlowConfigDoesNotBlockTailScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "managed-slow-tail");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    const workspace_path = try std.fmt.allocPrint(allocator, "{s}/workspace", .{pref_path});
    defer allocator.free(workspace_path);
    try writeManagedProcessConfig(io, workspace_path, "/bin/cat");

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemonWithSlowIo(allocator, io, self_exe, pref_path, "400");
    defer {
        if (comptime builtin.os.tag == .windows) {
            child.kill(io);
        } else if (child.id != null) {
            _ = child.wait(io) catch {};
        }
    }

    var transport: sessionizer.HeadlessTransport = .{ .allocator = allocator, .pref_path = pref_path };
    var client = sessionizer.headlessClient(allocator, &transport);
    const session_id = "managed-slow-tail-plain";
    var created = try client.call("session.create", .{
        .id = session_id,
        .cwd = workspace_path,
        .workspace_path = workspace_path,
        .command = &[_][]const u8{"/bin/cat"},
    });
    defer created.deinit();
    if (!created.response.isOk()) return error.ManagedSlowTailSessionCreateFailed;
    defer {
        if (client.call("session.kill", .{ .id = session_id })) |response| {
            var owned = response;
            owned.deinit();
        } else |_| {}
        if (client.call("session.cleanup", .{})) |response| {
            var owned = response;
            owned.deinit();
        } else |_| {}
    }

    var context: SlowStartThreadContext = .{
        .allocator = allocator,
        .pref_path = pref_path,
        .workspace_path = workspace_path,
    };
    const thread = try std.Thread.spawn(.{}, slowStartThread, .{&context});
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    const started_at_ms = sessionizer.nowMs();
    var tail = try client.call("session.tail", .{ .id = session_id, .after_cursor = 0, .max_bytes = 1024 });
    defer tail.deinit();
    const elapsed_ms = sessionizer.nowMs() - started_at_ms;
    thread.join();
    const start_response = context.response orelse return error.ManagedSlowTailStartMissingResponse;
    defer allocator.free(start_response);
    var parsed_start = try std.json.parseFromSlice(std.json.Value, allocator, start_response, .{});
    defer parsed_start.deinit();
    if (parsed_start.value.object.get("error")) |error_value| {
        if (error_value.object.get("code")) |code| {
            if (code == .string and std.mem.eql(u8, code.string, "internal_error")) return error.ManagedSlowTailStartInternalError;
        }
    }
    if (parsed_start.value.object.get("result")) |result| {
        if (result == .object) {
            if (result.object.get("process")) |process| {
                if (process == .object) {
                    if (process.object.get("id")) |process_id| {
                        if (process_id == .string) {
                            var stopped = try client.call(headless.registry.METHOD_PROCESS_STOP, .{
                                .workspace = .{ .workspace_path = workspace_path },
                                .process_id = process_id.string,
                            });
                            defer stopped.deinit();
                            if (!stopped.response.isOk()) return error.ManagedSlowTailStopFailed;
                        }
                    }
                }
            }
        }
    }
    var killed = try client.call("session.kill", .{ .id = session_id });
    defer killed.deinit();
    if (!killed.response.isOk()) return error.ManagedSlowTailSessionKillFailed;
    var shutdown = try client.call("daemon.prepareShutdown", .{});
    defer shutdown.deinit();
    if (!shutdown.response.isOk()) return error.ManagedSlowTailShutdownFailed;
    if (elapsed_ms >= 300) return error.ManagedSlowTailBlocked;
}

/// Scenario 1: every registry method dispatched by the phase-2 daemon is
/// present on the wire, while the client-facing capability bits stay phase 1.
fn runRegistryMethodPresenceScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "registry-method-presence");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var transport: sessionizer.HeadlessTransport = .{ .allocator = allocator, .pref_path = pref_path };
    var client = sessionizer.headlessClient(allocator, &transport);
    const empty_params: struct {} = .{};
    for (DISPATCHED_REGISTRY_METHODS) |method| {
        var parsed = try client.call(method, empty_params);
        defer parsed.deinit();
        if (parsed.response.err) |err| {
            if (std.mem.eql(u8, err.code, FIXTURE_METHOD_NOT_FOUND)) return error.RegistryMethodPresenceMissing;
        }
    }

    var status_response = try client.call("core.status", empty_params);
    defer status_response.deinit();
    if (!status_response.response.isOk()) return error.RegistryMethodPresenceStatusFailed;
    const status = try client.decodeStatus(&status_response);
    if (status.capabilities.processes or status.capabilities.leases) return error.RegistryMethodPresenceCapabilityChanged;
}

/// Scenario 4: forced lease acquisition preserves the incumbent lease and
/// delivers one pull-only notification to each affected owner.
fn runLeaseConflictScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "lease-conflict");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var transport: sessionizer.HeadlessTransport = .{ .allocator = allocator, .pref_path = pref_path };
    var client = sessionizer.headlessClient(allocator, &transport);
    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var typed_transport: sessionizer.HeadlessTransport = .{ .allocator = decode_arena.allocator(), .pref_path = pref_path };
    var typed_client = sessionizer.headlessClient(decode_arena.allocator(), &typed_transport);
    const resources = [_][]const u8{"build"};

    var first = try typed_client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-a",
        .command = "build",
        .resources = &resources,
    });
    defer first.deinit();
    const first_result = try typed_client.decodeLeaseAcquire(&first);
    if (!first_result.acquired) return error.LeaseConflictInitialAcquireFailed;

    var conflict = try client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-b",
        .command = "build",
        .resources = &resources,
    });
    defer conflict.deinit();
    if (conflict.response.isOk()) return error.LeaseConflictWasNotRejected;
    const conflict_error = conflict.response.err orelse return error.LeaseConflictMissingError;
    if (!std.mem.eql(u8, conflict_error.code, headless.protocol.ERR_CONFLICT)) return error.LeaseConflictWrongError;
    _ = typed_client.decodeLeaseAcquire(&conflict) catch |err| switch (err) {
        error.RemoteError => {},
        else => return err,
    };
    const conflict_data = conflict_error.data orelse return error.LeaseConflictMissingData;
    if (conflict_data != .object or conflict_data.object.get("conflicts") == null) return error.LeaseConflictMalformedData;

    var forced = try typed_client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-b",
        .command = "build",
        .resources = &resources,
        .force = true,
    });
    defer forced.deinit();
    const forced_result = try typed_client.decodeLeaseAcquire(&forced);
    if (!forced_result.acquired or !forced_result.forced) return error.LeaseConflictForcedAcquireFailed;

    var listed = try typed_client.call(headless.registry.METHOD_PROCESS_LIST, .{
        .workspace = .{ .workspace_path = pref_path },
    });
    defer listed.deinit();
    const list_result = try typed_client.decodeProcessList(&listed);
    if (list_result.leases.len != 2) return error.LeaseConflictIncumbentLeaseMissing;

    var notifications = try typed_client.call(headless.registry.METHOD_DAEMON_NOTIFICATIONS, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner_session_id = "owner-a",
    });
    defer notifications.deinit();
    const notification_result = try typed_client.decodeNotifications(&notifications);
    if (notification_result.notifications.len != 1) return error.LeaseConflictNotificationCountMismatch;
    if (!std.mem.eql(u8, notification_result.notifications[0].title, "Conflicting command started")) return error.LeaseConflictNotificationTitleMismatch;

    var second_pull = try typed_client.call(headless.registry.METHOD_DAEMON_NOTIFICATIONS, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner_session_id = "owner-a",
        .after_seq = notification_result.notifications[0].seq,
    });
    defer second_pull.deinit();
    const second_result = try typed_client.decodeNotifications(&second_pull);
    if (second_result.notifications.len != 0) return error.LeaseConflictNotificationWasConsumed;
}

/// Scenario 5: same-owner renewal, explicit renew-by-id, and owner-only
/// release preserve lease identity and idempotence.
fn runLeaseRenewReleaseScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "lease-renew-release");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var typed_transport: sessionizer.HeadlessTransport = .{ .allocator = decode_arena.allocator(), .pref_path = pref_path };
    var typed_client = sessionizer.headlessClient(decode_arena.allocator(), &typed_transport);
    const resources = [_][]const u8{"build"};

    var first = try typed_client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-a",
        .command = "build",
        .resources = &resources,
        .ttl_ms = 5_000,
    });
    defer first.deinit();
    const first_result = try typed_client.decodeLeaseAcquire(&first);
    const lease_id = first_result.lease_id orelse return error.LeaseRenewMissingId;
    const first_expiry = first_result.expires_at_ms orelse return error.LeaseRenewMissingExpiry;

    var reacquired = try typed_client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-a",
        .command = "build",
        .resources = &resources,
        .ttl_ms = 20_000,
    });
    defer reacquired.deinit();
    const reacquired_result = try typed_client.decodeLeaseAcquire(&reacquired);
    if (!reacquired_result.renewed or !std.mem.eql(u8, reacquired_result.lease_id orelse return error.LeaseRenewReacquireMissingId, lease_id)) return error.LeaseRenewReacquireFailed;

    var renewed = try typed_client.call(headless.registry.METHOD_LEASE_RENEW, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-a",
        .lease_id = lease_id,
        .ttl_ms = 30_000,
    });
    defer renewed.deinit();
    const renewed_result = try typed_client.decodeLeaseRenew(&renewed);
    if (!renewed_result.renewed or !std.mem.eql(u8, renewed_result.lease_id, lease_id)) return error.LeaseRenewByIdFailed;
    if ((renewed_result.expires_at_ms orelse 0) <= first_expiry) return error.LeaseRenewExpiryDidNotExtend;

    var wrong_release = try typed_client.call(headless.registry.METHOD_LEASE_RELEASE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-b",
        .lease_id = lease_id,
    });
    defer wrong_release.deinit();
    const wrong_release_result = try typed_client.decodeLeaseRelease(&wrong_release);
    if (wrong_release_result.released or wrong_release_result.released_count != 0) return error.LeaseWrongOwnerReleased;

    var listed = try typed_client.call(headless.registry.METHOD_PROCESS_LIST, .{
        .workspace = .{ .workspace_path = pref_path },
    });
    defer listed.deinit();
    if ((try typed_client.decodeProcessList(&listed)).leases.len != 1) return error.LeaseWrongOwnerLeaseMissing;

    var released = try typed_client.call(headless.registry.METHOD_LEASE_RELEASE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-a",
        .lease_id = lease_id,
    });
    defer released.deinit();
    const released_result = try typed_client.decodeLeaseRelease(&released);
    if (!released_result.released or released_result.released_count != 1) return error.LeaseReleaseFailed;
}

/// Scenario 10: forced-acquire + notification flow over the platform transport
/// only (no sessions/PTYs/posix). Shares the scenario-4 skeleton but asserts
/// extra wire fields scenario 4 does not: notification body (command), zero
/// mailbox for the forcing owner, and cursor progress via next_notification_seq.
fn runForcedAcquireOverTransportScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "forced-acquire-transport");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var transport: sessionizer.HeadlessTransport = .{ .allocator = allocator, .pref_path = pref_path };
    var client = sessionizer.headlessClient(allocator, &transport);
    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var typed_transport: sessionizer.HeadlessTransport = .{ .allocator = decode_arena.allocator(), .pref_path = pref_path };
    var typed_client = sessionizer.headlessClient(decode_arena.allocator(), &typed_transport);
    const resources = [_][]const u8{"build"};

    // Distinct commands so the notification body can discriminate forcer vs incumbent.
    const incumbent_command = "incumbent-build";
    const forcer_command = "cargo test";

    var first = try typed_client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-a",
        .command = incumbent_command,
        .resources = &resources,
    });
    defer first.deinit();
    const first_result = try typed_client.decodeLeaseAcquire(&first);
    if (!first_result.acquired) return error.ForcedTransportInitialAcquireFailed;

    var conflict = try client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-b",
        .command = forcer_command,
        .resources = &resources,
    });
    defer conflict.deinit();
    if (conflict.response.isOk()) return error.ForcedTransportWasNotRejected;
    const conflict_error = conflict.response.err orelse return error.ForcedTransportMissingError;
    if (!std.mem.eql(u8, conflict_error.code, headless.protocol.ERR_CONFLICT)) return error.ForcedTransportWrongError;
    _ = typed_client.decodeLeaseAcquire(&conflict) catch |err| switch (err) {
        error.RemoteError => {},
        else => return err,
    };
    const conflict_data = conflict_error.data orelse return error.ForcedTransportMissingData;
    if (conflict_data != .object or conflict_data.object.get("conflicts") == null) return error.ForcedTransportMalformedData;

    var forced = try typed_client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "owner-b",
        .command = forcer_command,
        .resources = &resources,
        .force = true,
    });
    defer forced.deinit();
    const forced_result = try typed_client.decodeLeaseAcquire(&forced);
    if (!forced_result.acquired or !forced_result.forced) return error.ForcedTransportForcedAcquireFailed;

    var listed = try typed_client.call(headless.registry.METHOD_PROCESS_LIST, .{
        .workspace = .{ .workspace_path = pref_path },
    });
    defer listed.deinit();
    const list_result = try typed_client.decodeProcessList(&listed);
    if (list_result.leases.len != 2) return error.ForcedTransportIncumbentLeaseMissing;

    var notifications = try typed_client.call(headless.registry.METHOD_DAEMON_NOTIFICATIONS, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner_session_id = "owner-a",
    });
    defer notifications.deinit();
    const notification_result = try typed_client.decodeNotifications(&notifications);
    if (notification_result.notifications.len != 1) return error.ForcedTransportNotificationCountMismatch;
    const note = notification_result.notifications[0];
    if (!std.mem.eql(u8, note.title, "Conflicting command started")) return error.ForcedTransportNotificationTitleMismatch;
    // Body/command are the forcing command (registry unit test pins "cargo test").
    // Distinct from incumbent_command so this cannot pass by coincidence.
    if (!std.mem.eql(u8, note.body, forcer_command)) return error.ForcedTransportNotificationBodyMismatch;
    if (!std.mem.eql(u8, note.command, forcer_command)) return error.ForcedTransportNotificationCommandMismatch;
    if (std.mem.eql(u8, note.body, incumbent_command)) return error.ForcedTransportNotificationMatchedIncumbent;
    if (notification_result.next_notification_seq <= note.seq) return error.ForcedTransportNextSeqNotAdvanced;

    // Forcing owner is not an "affected" mailbox recipient.
    var forcer_pull = try typed_client.call(headless.registry.METHOD_DAEMON_NOTIFICATIONS, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner_session_id = "owner-b",
    });
    defer forcer_pull.deinit();
    const forcer_result = try typed_client.decodeNotifications(&forcer_pull);
    if (forcer_result.notifications.len != 0) return error.ForcedTransportForcerReceivedNotification;

    // Cursor via next_notification_seq (scenario 4 uses the entry's seq only).
    var second_pull = try typed_client.call(headless.registry.METHOD_DAEMON_NOTIFICATIONS, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner_session_id = "owner-a",
        .after_seq = notification_result.next_notification_seq,
    });
    defer second_pull.deinit();
    const second_result = try typed_client.decodeNotifications(&second_pull);
    if (second_result.notifications.len != 0) return error.ForcedTransportNotificationWasConsumed;
}

/// Scenario 6: each prepareShutdown live-state gate refuses independently,
/// while the daemon remains fully accepting until the gate is clear.
fn runPrepareGateScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "prepare-gates");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    var child_exited = false;
    defer if (!child_exited) child.kill(io);

    var transport: sessionizer.HeadlessTransport = .{ .allocator = allocator, .pref_path = pref_path };
    var client = sessionizer.headlessClient(allocator, &transport);
    const session_id = "prepare-gate-session";
    var created = try client.call("session.create", .{
        .id = session_id,
        .cwd = pref_path,
        .workspace_path = pref_path,
        .command = &[_][]const u8{"/bin/cat"},
    });
    defer created.deinit();
    if (!created.response.isOk()) return error.PrepareGateSessionCreateFailed;

    var refused = try client.call("daemon.prepareShutdown", .{});
    defer refused.deinit();
    const session_error = refused.response.err orelse return error.PrepareGateSessionNotRefused;
    if (!std.mem.eql(u8, session_error.code, headless.protocol.ERR_INVALID_STATE)) return error.PrepareGateWrongSessionError;
    const session_data = session_error.data orelse return error.PrepareGateMissingSessionData;
    if (session_data != .object or (session_data.object.get("running_sessions") orelse .null) != .integer or session_data.object.get("running_sessions").?.integer < 1) return error.PrepareGateMissingRunningCount;

    var written = try client.call("session.write", .{ .id = session_id, .text = "prepare-gate\n" });
    defer written.deinit();
    if (!written.response.isOk()) return error.PrepareGateWriteFailed;
    var killed = try client.call("session.kill", .{ .id = session_id });
    defer killed.deinit();
    if (!killed.response.isOk()) return error.PrepareGateKillFailed;
    var session_reaped = false;
    var reap_attempt: usize = 0;
    while (reap_attempt < 100) : (reap_attempt += 1) {
        var cleaned = try client.call("session.cleanup", .{});
        defer cleaned.deinit();
        if (!cleaned.response.isOk()) return error.PrepareGateCleanupFailed;
        if (cleaned.response.result) |result| {
            if (result == .object) {
                if ((result.object.get("removed") orelse .null) == .integer and result.object.get("removed").?.integer > 0) {
                    session_reaped = true;
                    break;
                }
            }
        }
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    if (!session_reaped) return error.PrepareGateSessionDidNotReap;

    const resources = [_][]const u8{"build"};
    var lease = try client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "prepare-gate-owner",
        .resources = &resources,
    });
    defer lease.deinit();
    if (!lease.response.isOk()) return error.PrepareGateLeaseAcquireFailed;
    const lease_result = lease.response.result orelse return error.PrepareGateLeaseIdMissing;
    const lease_id = if (lease_result == .object) jsonStringValue(lease_result.object.get("lease_id") orelse .null) else null;
    const owned_lease_id = lease_id orelse return error.PrepareGateLeaseIdMissing;

    var lease_refused = try client.call("daemon.prepareShutdown", .{});
    defer lease_refused.deinit();
    const lease_error = lease_refused.response.err orelse return error.PrepareGateLeaseNotRefused;
    const lease_data = lease_error.data orelse return error.PrepareGateLeaseDataMissing;
    if (lease_data != .object or (lease_data.object.get("leases") orelse .null) != .integer or lease_data.object.get("leases").?.integer < 1) return error.PrepareGateMissingLeaseCount;

    var released = try client.call(headless.registry.METHOD_LEASE_RELEASE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "prepare-gate-owner",
        .lease_id = owned_lease_id,
    });
    defer released.deinit();
    if (!released.response.isOk()) return error.PrepareGateLeaseReleaseFailed;

    // Keep-alive turns remain pinned by the inline gate test; the existing
    // graceful-replace scenario also exercises the empty-daemon success path.
    var accepted = try client.call("daemon.prepareShutdown", .{});
    defer accepted.deinit();
    if (!accepted.response.isOk()) return error.PrepareGateFinalPrepareFailed;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            allocator.free(response);
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
        } else |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => break,
            else => std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {},
        }
    }
    if (attempts >= 100) return error.PrepareGateDaemonDidNotExit;
    _ = child.wait(io) catch {};
    child_exited = true;
}

/// Scenario 8: a disconnected non-persistent client eventually loses its
/// owned session, while the daemon remains available for new requests.
fn runDisconnectedClientRetentionScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "disconnected-retention");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemonWithRetention(allocator, io, self_exe, pref_path, "300");
    defer child.kill(io);
    var transport: sessionizer.HeadlessTransport = .{ .allocator = allocator, .pref_path = pref_path };
    var client = sessionizer.headlessClient(allocator, &transport);

    var registered = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer registered.deinit();
    const registered_result = registered.response.result orelse return error.RetentionRegisterMissingResult;
    const client_id = if (registered_result == .object) jsonStringValue(registered_result.object.get("client_id") orelse .null) else null;
    const owned_client_id = client_id orelse return error.RetentionClientIdMissing;

    var created = try client.call("session.create", .{
        .id = "disconnected-session",
        .cwd = pref_path,
        .workspace_path = pref_path,
        .client_id = owned_client_id,
        .command = &[_][]const u8{"/bin/cat"},
    });
    defer created.deinit();
    if (!created.response.isOk()) return error.RetentionSessionCreateFailed;

    var observed = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var listed = try client.call(headless.registry.METHOD_PROCESS_LIST, .{
            .workspace = .{ .workspace_path = pref_path },
            .include_outcomes = true,
        });
        defer listed.deinit();
        if (!listed.response.isOk()) return error.RetentionListFailed;
        const result = listed.response.result orelse return error.RetentionListMissingResult;
        if (result == .object) {
            const processes = result.object.get("processes") orelse .null;
            const outcomes = result.object.get("outcomes") orelse .null;
            if (processes == .array and processes.array.items.len == 0 and outcomes == .array) {
                for (outcomes.array.items) |outcome| {
                    if (outcome == .object and
                        std.mem.eql(u8, jsonStringValue(outcome.object.get("session_id") orelse .null) orelse "", "disconnected-session") and
                        std.mem.eql(u8, jsonStringValue(outcome.object.get("cancellation_reason") orelse .null) orelse "", "orphaned"))
                    {
                        observed = true;
                        break;
                    }
                }
            }
        }
        if (observed) break;
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    if (!observed) return error.RetentionOrphanOutcomeMissing;
    var status = try client.call("status", .{});
    defer status.deinit();
    if (!status.response.isOk()) return error.RetentionDaemonDied;
}

/// Scenario 9: daemon.stop is scoped for ordinary sessions, force-all stops
/// managed processes, and persistent-client sessions survive untouched.
fn runScopedStopScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "scoped-stop");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);
    try writeManagedProcessConfig(io, pref_path, "/bin/cat");

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);
    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);
    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{ .idle_exit_ms = "500" });
    var child_exited = false;
    defer if (!child_exited) child.kill(io);
    var transport: sessionizer.HeadlessTransport = .{ .allocator = allocator, .pref_path = pref_path };
    var client = sessionizer.headlessClient(allocator, &transport);

    var registered_a = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = true });
    defer registered_a.deinit();
    var registered_b = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer registered_b.deinit();
    const a_result = registered_a.response.result orelse return error.ScopedStopRegisterAMissing;
    const b_result = registered_b.response.result orelse return error.ScopedStopRegisterBMissing;
    const client_a = if (a_result == .object) jsonStringValue(a_result.object.get("client_id") orelse .null) else null;
    const client_b = if (b_result == .object) jsonStringValue(b_result.object.get("client_id") orelse .null) else null;
    const owner_a = client_a orelse return error.ScopedStopClientAMissing;
    const owner_b = client_b orelse return error.ScopedStopClientBMissing;

    var created = try client.call("session.create", .{
        .id = "scoped-persistent-session",
        .cwd = pref_path,
        .workspace_path = pref_path,
        .client_id = owner_a,
        .command = &[_][]const u8{"/bin/cat"},
    });
    defer created.deinit();
    if (!created.response.isOk()) return error.ScopedStopSessionCreateFailed;
    var started = try client.call(headless.registry.METHOD_PROCESS_START, .{
        .workspace = .{ .workspace_path = pref_path },
        .client_id = owner_b,
        .name = "sleeper",
    });
    defer started.deinit();
    if (!started.response.isOk()) return error.ScopedStopManagedStartFailed;
    const managed_id = try managedProcessIdFromResponse(&started, allocator);
    defer allocator.free(managed_id);

    var unknown = try client.call(headless.registry.METHOD_DAEMON_STOP, .{ .client_id = "unregistered-client", .force = true });
    defer unknown.deinit();
    if (unknown.response.isOk() or unknown.response.err == null or !std.mem.eql(u8, unknown.response.err.?.code, headless.protocol.ERR_INVALID_STATE)) return error.ScopedStopUnknownClientAccepted;

    var stopped = try client.call(headless.registry.METHOD_DAEMON_STOP, .{ .client_id = owner_b, .force = true });
    defer stopped.deinit();
    if (!stopped.response.isOk()) return error.ScopedStopFailed;
    const stopped_result = try client.decodeDaemonStop(&stopped);
    if (!stopped_result.accepted or stopped_result.stopping) return error.ScopedStopUnexpectedStopping;

    var listed = try client.call(headless.registry.METHOD_PROCESS_LIST, .{ .workspace = .{ .workspace_path = pref_path } });
    defer listed.deinit();
    if (!listed.response.isOk()) return error.ScopedStopListFailed;
    const processes = listed.response.result.?.object.get("processes") orelse return error.ScopedStopMissingProcesses;
    var saw_stopped = false;
    if (processes == .array) for (processes.array.items) |process| {
        if (process == .object and std.mem.eql(u8, jsonStringValue(process.object.get("id") orelse .null) orelse "", managed_id) and
            std.mem.eql(u8, jsonStringValue(process.object.get("status") orelse .null) orelse "", "stopped")) saw_stopped = true;
    };
    if (!saw_stopped) return error.ScopedStopManagedStillRunning;

    var tailed = try client.call("session.tail", .{ .id = "scoped-persistent-session", .after_cursor = 0, .max_bytes = 128 });
    defer tailed.deinit();
    if (!tailed.response.isOk()) return error.ScopedStopPersistentSessionLost;
    var killed = try client.call("session.kill", .{ .id = "scoped-persistent-session" });
    defer killed.deinit();
    if (!killed.response.isOk()) return error.ScopedStopPersistentKillFailed;
    var closed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_CLOSE, .{ .client_id = owner_a });
    defer closed.deinit();
    if (!closed.response.isOk()) return error.ScopedStopClientCloseFailed;

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            allocator.free(response);
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
        } else |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => break,
            else => std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {},
        }
    }
    if (attempts >= 100) return error.ScopedStopDaemonDidNotIdleExit;
    _ = child.wait(io) catch {};
    child_exited = true;
}

fn jsonStringValue(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

/// Store-less daemon: all store methods return capability_unavailable (S3 full surface).
fn runStoreLessScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-less");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var transport: sessionizer.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(allocator, &transport);
    var scenario: FixtureScenario = .{ .client = &client };
    scenario.storeTemporaryDatabaseHook("phase-2-store-temporary-database");

    const mutation: headless.store.MutationHeader = .{
        .request_key = "s3-store-less-workspace-upsert",
        .client_id = "s3-fixture-client",
    };
    const request: headless.store.WorkspaceUpsertRequest = .{
        .mutation = mutation,
        .workspace = .{
            .workspace_id = "s3-fixture-workspace",
            .label = "S3 fixture workspace",
            .path = pref_path,
        },
    };

    const store_methods = [_][]const u8{
        headless.store.METHOD_STATE_SNAPSHOT_REPLACE,
        headless.store.METHOD_WORKSPACE_UPSERT,
        headless.store.METHOD_CHAT_THREAD_UPSERT,
        headless.store.METHOD_CHAT_MESSAGE_APPEND,
        headless.store.METHOD_SURFACE_UPSERT,
        headless.store.METHOD_SURFACE_CLEAR,
        headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT,
        headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR,
    };
    for (store_methods) |method| {
        var parsed = try scenario.storeStep(method, request);
        defer parsed.deinit();
        const err = parsed.response.err orelse return error.StoreLessMissingError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_CAPABILITY_UNAVAILABLE)) return error.StoreLessWrongCode;
        if (!std.mem.eql(u8, err.message, "store capability is unavailable")) return error.StoreLessWrongMessage;
    }
    {
        const empty_params: struct {} = .{};
        var parsed = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
        defer parsed.deinit();
        const err = parsed.response.err orelse return error.StoreLessStatusMissingError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_CAPABILITY_UNAVAILABLE)) return error.StoreLessStatusWrongCode;
        if (!std.mem.eql(u8, err.message, "store capability is unavailable")) return error.StoreLessStatusWrongMessage;
    }
}

/// Store-enabled daemon: receipt replay, client validation, conflict, status,
/// dormancy pin, wire-level natural-duplicate ordering, two-client conflict,
/// and post-drain rejection.
fn runStoreEnabledScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-enabled");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    // Backslash-safe on Windows; same join used for state.sqlite below.
    const store_dir = try std.fs.path.join(allocator, &.{ pref_path, "store" });
    defer allocator.free(store_dir);
    try std.Io.Dir.cwd().createDirPath(io, store_dir);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
    });
    defer child.kill(io);

    // Typed decodes use leaky .alloc_always — must run over a scoped arena
    // (file convention) so DebugAllocator does not report per-scenario leaks.
    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
    var scenario: FixtureScenario = .{ .client = &client };

    // B7: register clients before store mutations.
    // Explicit field: bare `.{}` can stringify as `[]` and fail params validation.
    var register_a = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer register_a.deinit();
    if (!register_a.response.isOk()) return error.StoreEnabledRegisterFailed;
    const client_a = (try client.decodeClientRegister(&register_a)).client_id;

    var register_b = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer register_b.deinit();
    if (!register_b.response.isOk()) return error.StoreEnabledRegisterBFailed;
    const client_b = (try client.decodeClientRegister(&register_b)).client_id;

    const mutation: headless.store.MutationHeader = .{
        .request_key = "s3-store-enabled-workspace-upsert",
        .client_id = client_a,
    };
    const request: headless.store.WorkspaceUpsertRequest = .{
        .mutation = mutation,
        .workspace = .{
            .workspace_id = "s3-enabled-workspace",
            .label = "S3 enabled workspace",
            .path = pref_path,
        },
    };

    var first = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, request);
    defer first.deinit();
    if (!first.response.isOk()) return error.StoreEnabledUpsertFailed;
    const first_result = try client.decodeWriteResult(&first);
    if (!first_result.applied or first_result.duplicate) return error.StoreEnabledUpsertNotApplied;
    if (first_result.store_revision != 1) return error.StoreEnabledUnexpectedRevision;

    var replay = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, request);
    defer replay.deinit();
    if (!replay.response.isOk()) return error.StoreEnabledReplayFailed;
    const replay_result = try client.decodeWriteResult(&replay);
    if (replay_result.store_revision != first_result.store_revision or
        replay_result.applied != first_result.applied or
        replay_result.duplicate != first_result.duplicate)
    {
        return error.StoreEnabledReplayMismatch;
    }

    {
        const unknown: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = "s3-unknown-client",
                .client_id = "not-a-registered-client",
            },
            .workspace = .{
                .workspace_id = "s3-other",
                .label = "Other",
                .path = pref_path,
            },
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, unknown);
        defer parsed.deinit();
        const err = parsed.response.err orelse return error.StoreEnabledUnknownClientMissingError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_INVALID_PARAMS)) return error.StoreEnabledUnknownClientWrongCode;
    }

    {
        const stale: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = "s3-stale-revision",
                .client_id = client_a,
                .expected_store_revision = 0,
            },
            .workspace = .{
                .workspace_id = "s3-stale",
                .label = "Stale",
                .path = pref_path,
            },
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, stale);
        defer parsed.deinit();
        const err = parsed.response.err orelse return error.StoreEnabledConflictMissingError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_CONFLICT)) return error.StoreEnabledConflictWrongCode;
    }

    // Wire-level natural-duplicate ordering pin (mandated): same message identity
    // + identical payload + fresh request_key + stale expected_store_revision
    // still returns applied=false, duplicate=true (wins over the revision guard).
    {
        const thread_req: headless.store.ThreadUpsertRequest = .{
            .mutation = .{
                .request_key = "s3-order-thread",
                .client_id = client_a,
                .expected_store_revision = 1,
            },
            .workspace_id = "s3-enabled-workspace",
            .thread = .{
                .local_thread_id = "s3-order-thread",
                .title = "Order thread",
            },
        };
        var thread_parsed = try scenario.storeStep(headless.store.METHOD_CHAT_THREAD_UPSERT, thread_req);
        defer thread_parsed.deinit();
        if (!thread_parsed.response.isOk()) return error.StoreEnabledOrderThreadFailed;
        const thread_result = try client.decodeWriteResult(&thread_parsed);
        if (thread_result.store_revision != 2) return error.StoreEnabledOrderThreadRevision;

        const message: headless.store.Message = .{
            .message_id = "s3-order-msg",
            .role = "user",
            .author = "You",
            .body = "hello",
        };
        const append_req: headless.store.MessageAppendRequest = .{
            .mutation = .{
                .request_key = "s3-order-append",
                .client_id = client_a,
                .expected_store_revision = 2,
            },
            .workspace_id = "s3-enabled-workspace",
            .thread_id = "s3-order-thread",
            .message = message,
        };
        var append_parsed = try scenario.storeStep(headless.store.METHOD_CHAT_MESSAGE_APPEND, append_req);
        defer append_parsed.deinit();
        if (!append_parsed.response.isOk()) return error.StoreEnabledOrderAppendFailed;
        const append_result = try client.decodeWriteResult(&append_parsed);
        if (!append_result.applied or append_result.store_revision != 3) return error.StoreEnabledOrderAppendNotApplied;
        const original_revision = append_result.store_revision;

        // Advance revision so the original expected revision is stale.
        const advance: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = "s3-order-advance",
                .client_id = client_a,
                .expected_store_revision = 3,
            },
            .workspace = .{
                .workspace_id = "s3-order-advance",
                .label = "Advance",
                .path = pref_path,
            },
        };
        var advance_parsed = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, advance);
        defer advance_parsed.deinit();
        if (!advance_parsed.response.isOk()) return error.StoreEnabledOrderAdvanceFailed;
        const advance_result = try client.decodeWriteResult(&advance_parsed);
        if (advance_result.store_revision != 4) return error.StoreEnabledOrderAdvanceRevision;

        var natural_dup = append_req;
        natural_dup.mutation = .{
            .request_key = "s3-order-append-retry",
            .client_id = client_a,
            .expected_store_revision = original_revision, // stale
        };
        var dup_parsed = try scenario.storeStep(headless.store.METHOD_CHAT_MESSAGE_APPEND, natural_dup);
        defer dup_parsed.deinit();
        if (!dup_parsed.response.isOk()) return error.StoreEnabledOrderDupFailed;
        const dup_result = try client.decodeWriteResult(&dup_parsed);
        if (dup_result.applied or !dup_result.duplicate) return error.StoreEnabledOrderDupNotDuplicate;
        if (dup_result.store_revision != 4) return error.StoreEnabledOrderDupRevision;
    }

    // Two-client conflict: A and B both read N; A applies expected N; B's expected N conflicts.
    // Track the post-A revision so the S2 storeStatus revision pin below stays accurate.
    var expected_store_revision: u64 = 4; // ordering block ends at revision 4
    {
        const empty_params: struct {} = .{};
        var status_parsed = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
        defer status_parsed.deinit();
        if (!status_parsed.response.isOk()) return error.StoreEnabledTwoClientStatusFailed;
        const status = try client.decodeStoreStatus(&status_parsed);
        const n = status.store_revision;
        if (n != expected_store_revision) return error.StoreEnabledTwoClientUnexpectedN;

        const a_upsert: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = "s3-two-client-a",
                .client_id = client_a,
                .expected_store_revision = n,
            },
            .workspace = .{
                .workspace_id = "s3-two-client-a",
                .label = "A",
                .path = pref_path,
            },
        };
        var a_parsed = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, a_upsert);
        defer a_parsed.deinit();
        if (!a_parsed.response.isOk()) return error.StoreEnabledTwoClientAFailed;
        const a_result = try client.decodeWriteResult(&a_parsed);
        if (!a_result.applied or a_result.store_revision != n + 1) return error.StoreEnabledTwoClientANotApplied;
        expected_store_revision = a_result.store_revision;

        const b_snapshot: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = "s3-two-client-b",
                .client_id = client_b,
                .expected_store_revision = n, // stale after A
            },
            .snapshot = .{
                .schema_version = 1,
                .workspaces = &.{.{
                    .workspace_id = "s3-two-client-b",
                    .label = "B",
                    .path = pref_path,
                }},
            },
        };
        var b_parsed = try scenario.storeStep(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, b_snapshot);
        defer b_parsed.deinit();
        const err = b_parsed.response.err orelse return error.StoreEnabledTwoClientBMissingError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_CONFLICT)) return error.StoreEnabledTwoClientBWrongCode;
    }

    {
        const empty_params: struct {} = .{};
        var status_parsed = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
        defer status_parsed.deinit();
        if (!status_parsed.response.isOk()) return error.StoreEnabledStatusFailed;
        const status = try client.decodeStoreStatus(&status_parsed);
        if (!std.mem.eql(u8, status.drain_state, "open")) return error.StoreEnabledDrainStateWrong;
        // S2 pin restored: status revision must match the current expected watermark
        // (advanced past first_result by the ordering + two-client blocks).
        if (status.store_revision != expected_store_revision) return error.StoreEnabledStatusRevisionMismatch;
        if (!status.writer_ready) return error.StoreEnabledWriterNotReady;
    }

    // Dormancy pin (B2/B10): core.status still advertises store=false in P2.
    {
        const empty_params: struct {} = .{};
        var status_parsed = try client.call("core.status", empty_params);
        defer status_parsed.deinit();
        if (!status_parsed.response.isOk()) return error.StoreEnabledCoreStatusFailed;
        const status = try client.decodeStatus(&status_parsed);
        if (status.capabilities.store) return error.StoreEnabledStoreCapabilityAdvertised;
    }
}

/// Full store mutation surface over the wire with monotone revisions.
fn runStoreFullSurfaceScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-full-surface");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    // Backslash-safe on Windows; same join used for state.sqlite below.
    const store_dir = try std.fs.path.join(allocator, &.{ pref_path, "store" });
    defer allocator.free(store_dir);
    try std.Io.Dir.cwd().createDirPath(io, store_dir);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
    });
    defer child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
    var scenario: FixtureScenario = .{ .client = &client };

    var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer register_parsed.deinit();
    if (!register_parsed.response.isOk()) return error.StoreFullRegisterFailed;
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

    var last_revision: u64 = 0;

    {
        const req: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{ .request_key = "s3-full-ws", .client_id = client_id },
            .workspace = .{
                .workspace_id = "s3-full-ws",
                .label = "Full",
                .path = pref_path,
            },
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.StoreFullWorkspaceFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision != 1) return error.StoreFullWorkspaceRevision;
        last_revision = result.store_revision;
    }
    {
        const req: headless.store.ThreadUpsertRequest = .{
            .mutation = .{
                .request_key = "s3-full-thread",
                .client_id = client_id,
                .expected_store_revision = last_revision,
            },
            .workspace_id = "s3-full-ws",
            .thread = .{ .local_thread_id = "s3-full-t", .title = "Full thread" },
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_CHAT_THREAD_UPSERT, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.StoreFullThreadFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision <= last_revision) return error.StoreFullThreadRevision;
        last_revision = result.store_revision;
    }
    {
        const req: headless.store.MessageAppendRequest = .{
            .mutation = .{
                .request_key = "s3-full-msg",
                .client_id = client_id,
                .expected_store_revision = last_revision,
            },
            .workspace_id = "s3-full-ws",
            .thread_id = "s3-full-t",
            .message = .{
                .message_id = "s3-full-m",
                .role = "user",
                .author = "You",
                .body = "full surface",
            },
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_CHAT_MESSAGE_APPEND, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.StoreFullMessageFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision <= last_revision) return error.StoreFullMessageRevision;
        last_revision = result.store_revision;
    }
    {
        const req: headless.store.SurfaceUpsertRequest = .{
            .mutation = .{
                .request_key = "s3-full-surface",
                .client_id = client_id,
                .expected_store_revision = last_revision,
            },
            .surface = .{ .session_id = "s3-full-s", .status = "done" },
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_SURFACE_UPSERT, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.StoreFullSurfaceFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision <= last_revision) return error.StoreFullSurfaceRevision;
        last_revision = result.store_revision;
    }
    {
        const req: headless.store.NotificationChatCompletionUpsertRequest = .{
            .mutation = .{
                .request_key = "s3-full-completion",
                .client_id = client_id,
                .expected_store_revision = last_revision,
            },
            .completion = .{
                .workspace_id = "s3-full-ws",
                .local_thread_id = "s3-full-t",
                .completed_at_ms = 99,
            },
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.StoreFullCompletionFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision <= last_revision) return error.StoreFullCompletionRevision;
        last_revision = result.store_revision;
    }
    {
        const req: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = "s3-full-snapshot",
                .client_id = client_id,
                .expected_store_revision = last_revision,
            },
            .snapshot = .{
                .schema_version = 1,
                .workspaces = &.{.{
                    .workspace_id = "s3-full-snap",
                    .label = "Snap",
                    .path = pref_path,
                }},
                .surface_states = &.{.{ .session_id = "s3-full-snap-s", .status = "idle" }},
                .chat_completions = &.{.{
                    .workspace_id = "s3-full-snap",
                    .local_thread_id = "s3-full-snap-t",
                    .completed_at_ms = 1,
                }},
            },
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.StoreFullSnapshotFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision <= last_revision) return error.StoreFullSnapshotRevision;
        last_revision = result.store_revision;
    }
    {
        const req: headless.store.SurfaceClearRequest = .{
            .mutation = .{
                .request_key = "s3-full-surface-clear",
                .client_id = client_id,
                .expected_store_revision = last_revision,
            },
            .session_id = "s3-full-snap-s",
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_SURFACE_CLEAR, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.StoreFullSurfaceClearFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision <= last_revision) return error.StoreFullSurfaceClearRevision;
        last_revision = result.store_revision;
    }
    {
        const req: headless.store.NotificationChatCompletionClearRequest = .{
            .mutation = .{
                .request_key = "s3-full-completion-clear",
                .client_id = client_id,
                .expected_store_revision = last_revision,
            },
            .workspace_id = "s3-full-snap",
            .local_thread_id = "s3-full-snap-t",
        };
        var parsed = try scenario.storeStep(headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.StoreFullCompletionClearFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision <= last_revision) return error.StoreFullCompletionClearRevision;
    }
}

/// Durable reopen: mutate → prepareShutdown → exit → direct SQLite check →
/// respawn on same store_dir → status + receipt replay.
/// Prepare drain always commits a transfer snapshot (M2-DT-b), so the durable
/// store_revision advances one more time after the last mutation receipt.
fn runStoreDurableReopenScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-durable");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    // Backslash-safe on Windows; same join used for state.sqlite below.
    const store_dir = try std.fs.path.join(allocator, &.{ pref_path, "store" });
    defer allocator.free(store_dir);
    try std.Io.Dir.cwd().createDirPath(io, store_dir);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    const receipt_key = "s3-durable-workspace";
    var persisted_revision: u64 = 0;

    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
        });
        // No defer kill: prepareShutdown should exit the child. Kill on bare-try
        // unwind until prepare is accepted (pre-prepare orphan would hold the endpoint).
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
        var scenario: FixtureScenario = .{ .client = &client };

        var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
        defer register_parsed.deinit();
        if (!register_parsed.response.isOk()) return error.StoreDurableRegisterFailed;
        const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

        const upsert: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = receipt_key,
                .client_id = client_id,
            },
            .workspace = .{
                .workspace_id = "s3-durable-ws",
                .label = "Durable",
                .path = pref_path,
            },
        };
        var first = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, upsert);
        defer first.deinit();
        if (!first.response.isOk()) return error.StoreDurableUpsertFailed;
        const first_result = try client.decodeWriteResult(&first);
        if (!first_result.applied) return error.StoreDurableUpsertNotApplied;
        persisted_revision = first_result.store_revision;

        var prepare_parsed = try client.call("daemon.prepareShutdown", .{});
        defer prepare_parsed.deinit();
        if (!prepare_parsed.response.isOk()) return error.StoreDurablePrepareNotAccepted;
        const prepare_result = prepare_parsed.arena_parsed.value.object.get("result") orelse
            return error.StoreDurablePrepareNotAccepted;
        const accepted = prepare_result.object.get("accepted") orelse
            return error.StoreDurablePrepareNotAccepted;
        if (accepted != .bool or !accepted.bool) return error.StoreDurablePrepareNotAccepted;

        // Prepare accepted: daemon will self-exit via the drain path.
        kill_on_unwind = false;

        // Post-drain rejection on a still-live daemon: mutator → invalid_state;
        // storeStatus still answers with drain_state=draining. The drain thread
        // may race exit after prepare; only connect/EOF-class errors mean "already
        // gone". Other errors (OOM, protocol, unexpected success shape) propagate.
        // Unit tests hard-pin the non-race invalid_state path.
        {
            const post_drain: headless.store.WorkspaceUpsertRequest = .{
                .mutation = .{
                    .request_key = "s3-post-drain",
                    .client_id = client_id,
                },
                .workspace = .{
                    .workspace_id = "s3-post-drain",
                    .label = "Post drain",
                    .path = pref_path,
                },
            };
            if (scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, post_drain)) |post_owned| {
                var post_parsed = post_owned;
                defer post_parsed.deinit();
                const err = post_parsed.response.err orelse return error.StoreDurablePostDrainMissingError;
                if (!std.mem.eql(u8, err.code, headless.protocol.ERR_INVALID_STATE)) return error.StoreDurablePostDrainWrongCode;
            } else |err| {
                if (!isConnectClassError(err)) return err;
            }

            const empty_params: struct {} = .{};
            if (client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params)) |status_owned| {
                var status_parsed = status_owned;
                defer status_parsed.deinit();
                if (status_parsed.response.isOk()) {
                    const status = try client.decodeStoreStatus(&status_parsed);
                    if (!std.mem.eql(u8, status.drain_state, "draining")) return error.StoreDurablePostDrainStateWrong;
                    if (status.writer_ready) return error.StoreDurablePostDrainWriterReady;
                }
            } else |err| {
                if (!isConnectClassError(err)) return err;
            }
        }

        var exited = false;
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
                allocator.free(response);
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
                continue;
            } else |err| {
                // Exit-wait uses the same connect-class discrimination as the probes.
                if (isConnectClassError(err)) {
                    exited = true;
                    break;
                }
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
            }
        }
        if (!exited) {
            child.kill(io);
            return error.StoreDurableDaemonDidNotExit;
        }
        const term = child.wait(io) catch {
            return error.StoreDurableWaitFailed;
        };
        switch (term) {
            .exited => |code| if (code != 0) return error.StoreDurableNonZeroExit,
            else => return error.StoreDurableAbnormalExit,
        }
    }

    // Direct read-only SQLite verification from the IT parent (never write/migrate).
    {
        const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
        defer allocator.free(db_path);
        // Confirm the file exists before open so a missing-store failure is explicit.
        std.Io.Dir.cwd().access(io, db_path, .{}) catch {
            std.debug.print("headless-daemon-it: durable store file missing at {s}\n", .{db_path});
            return error.StoreDurableSqliteMissing;
        };
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var conn = zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode) catch |err| {
            std.debug.print("headless-daemon-it: durable sqlite open failed at {s}: {s}\n", .{ db_path, @errorName(err) });
            return err;
        };
        defer conn.close();

        // Drain-time transfer always bumps once (possibly empty snapshot).
        const after_transfer_revision = persisted_revision + 1;
        const rev_row = (try conn.row("select store_revision from store_state where id = 1", .{})) orelse
            return error.StoreDurableMissingStoreState;
        defer rev_row.deinit();
        if (@as(u64, @intCast(rev_row.int(0))) != after_transfer_revision) return error.StoreDurableSqliteRevisionMismatch;

        const ws_row = (try conn.row("select count(*) from workspaces", .{})) orelse
            return error.StoreDurableMissingWorkspaces;
        defer ws_row.deinit();
        if (ws_row.int(0) < 1) return error.StoreDurableNoWorkspaceRows;

        // Receipt still records the mutation revision, not the transfer bump.
        const receipt_row = (try conn.row(
            "select store_revision from store_receipts where request_key = ?1",
            .{receipt_key},
        )) orelse return error.StoreDurableMissingReceipt;
        defer receipt_row.deinit();
        if (@as(u64, @intCast(receipt_row.int(0))) != persisted_revision) return error.StoreDurableReceiptRevisionMismatch;
    }

    // Respawn on the SAME store_dir: status shows post-transfer revision; receipt replay works.
    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
        });
        defer child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
        var scenario: FixtureScenario = .{ .client = &client };

        const after_transfer_revision = persisted_revision + 1;
        const empty_params: struct {} = .{};
        var status_parsed = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
        defer status_parsed.deinit();
        if (!status_parsed.response.isOk()) return error.StoreDurableReopenStatusFailed;
        const status = try client.decodeStoreStatus(&status_parsed);
        if (status.store_revision != after_transfer_revision) return error.StoreDurableReopenRevisionMismatch;
        if (!std.mem.eql(u8, status.drain_state, "open")) return error.StoreDurableReopenDrainStateWrong;
        if (!status.writer_ready) return error.StoreDurableReopenWriterNotReady;

        var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
        defer register_parsed.deinit();
        if (!register_parsed.response.isOk()) return error.StoreDurableReopenRegisterFailed;
        const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

        // Replay the OLD request_key — receipt is durable across restart.
        // client_id is not part of receipt identity; the key alone is enough.
        const replay: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = receipt_key,
                .client_id = client_id,
            },
            .workspace = .{
                .workspace_id = "s3-durable-ws",
                .label = "Durable",
                .path = pref_path,
            },
        };
        var replay_parsed = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, replay);
        defer replay_parsed.deinit();
        if (!replay_parsed.response.isOk()) return error.StoreDurableReceiptReplayFailed;
        const replay_result = try client.decodeWriteResult(&replay_parsed);
        if (replay_result.store_revision != persisted_revision) return error.StoreDurableReceiptReplayRevision;
        if (!replay_result.applied or replay_result.duplicate) return error.StoreDurableReceiptReplayShape;
    }
}

/// Bounded serial queueing under a slow store commit (commit_stall).
/// True mid-stall responsiveness is blocked on accept-loop concurrency
/// (packages/desktop/src/platform/ipc.zig serial handleUnixClient); this pin
/// only asserts no deadlock and both requests complete within stall+timeout.
fn runStoreBoundedQueueingScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-queue");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    // Backslash-safe on Windows; same join used for state.sqlite below.
    const store_dir = try std.fs.path.join(allocator, &.{ pref_path, "store" });
    defer allocator.free(store_dir);
    try std.Io.Dir.cwd().createDirPath(io, store_dir);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .store_fault = "commit_stall",
    });
    defer child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer register_parsed.deinit();
    if (!register_parsed.response.isOk()) return error.StoreQueueRegisterFailed;
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

    const SlowMutationCtx = struct {
        allocator: std.mem.Allocator,
        pref_path: []const u8,
        client_id: []const u8,
        err: ?anyerror = null,
        applied: bool = false,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var mut_ctx: SlowMutationCtx = .{
        .allocator = allocator,
        .pref_path = pref_path,
        .client_id = client_id,
    };
    const slowThread = struct {
        fn run(ctx: *SlowMutationCtx) void {
            defer ctx.done.store(true, .release);
            var arena = std.heap.ArenaAllocator.init(ctx.allocator);
            defer arena.deinit();
            var t: sessionizer.HeadlessTransport = .{
                .allocator = arena.allocator(),
                .pref_path = ctx.pref_path,
            };
            var mut_client = sessionizer.headlessClient(arena.allocator(), &t);
            const upsert: headless.store.WorkspaceUpsertRequest = .{
                .mutation = .{
                    .request_key = "s4-queue-upsert",
                    .client_id = ctx.client_id,
                },
                .workspace = .{
                    .workspace_id = "s4-queue-ws",
                    .label = "Queue",
                    .path = ctx.pref_path,
                },
            };
            var parsed = mut_client.call(headless.store.METHOD_WORKSPACE_UPSERT, upsert) catch |err| {
                ctx.err = err;
                return;
            };
            defer parsed.deinit();
            if (!parsed.response.isOk()) {
                ctx.err = error.StoreQueueMutationFailed;
                return;
            }
            const result = mut_client.decodeWriteResult(&parsed) catch |err| {
                ctx.err = err;
                return;
            };
            ctx.applied = result.applied;
        }
    }.run;
    const worker = try std.Thread.spawn(.{}, slowThread, .{&mut_ctx});
    // Join on every path so a fallible concurrent read cannot leave the
    // mutation thread writing into a dead stack frame.
    var worker_joined = false;
    defer if (!worker_joined) worker.join();

    // Issue the read immediately after the mutation thread starts. With a serial
    // accept loop it queues behind the stalled commit; both must still finish.
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    const read_started = sessionizer.nowMs();
    const list_req: headless.registry.ProcessListRequest = .{
        .workspace = .{ .workspace_path = pref_path },
    };
    var list_parsed = try client.call(headless.registry.METHOD_PROCESS_LIST, list_req);
    defer list_parsed.deinit();
    const read_elapsed = sessionizer.nowMs() - read_started;

    // The worker must be joined before its results are read: the defer above
    // covers only unwind paths, and these loads would otherwise race the
    // thread's final writes.
    worker.join();
    worker_joined = true;

    if (mut_ctx.err) |err| return err;
    if (!mut_ctx.applied) return error.StoreQueueMutationNotApplied;
    if (!list_parsed.response.isOk()) return error.StoreQueueReadFailed;
    // stall(1500) + transport timeout budget — no deadlock, bounded queueing.
    if (read_elapsed > 8000) return error.StoreQueueReadTooSlow;
}

/// Parent holds BEGIN IMMEDIATE so the daemon writer hits the busy timeout →
/// store_busy; after release, same request_key applies once and replays.
fn runStoreBusyRetryScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-busy");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    // Backslash-safe on Windows; same join used for state.sqlite below.
    const store_dir = try std.fs.path.join(allocator, &.{ pref_path, "store" });
    defer allocator.free(store_dir);
    try std.Io.Dir.cwd().createDirPath(io, store_dir);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
    });
    defer child.kill(io);

    // BusyTimeout on the store is schema.BUSY_TIMEOUT_MS (5000); budget the IT.
    const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    var parent_conn = zqlite.open(db_path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode) catch |err| {
        std.debug.print("headless-daemon-it: busy parent sqlite open failed: {s}\n", .{@errorName(err)});
        return err;
    };
    // Single-owner close: one errdefer + flag; never close twice on success or
    // assertion-failure paths (spec trap #7 / S4 (f)).
    var conn_open = true;
    errdefer if (conn_open) parent_conn.close();
    // Parent acquires immediately; do not compete with the daemon's 5s busy wait.
    parent_conn.busyTimeout(0) catch {};
    try parent_conn.execNoArgs("begin immediate");
    var txn_open = true;
    errdefer if (txn_open) parent_conn.rollback();

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
    var scenario: FixtureScenario = .{ .client = &client };

    var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer register_parsed.deinit();
    if (!register_parsed.response.isOk()) return error.StoreBusyRegisterFailed;
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

    const receipt_key = "s4-busy-upsert";
    const upsert: headless.store.WorkspaceUpsertRequest = .{
        .mutation = .{
            .request_key = receipt_key,
            .client_id = client_id,
        },
        .workspace = .{
            .workspace_id = "s4-busy-ws",
            .label = "Busy",
            .path = pref_path,
        },
    };

    // Client default timeout is 5s; store busyTimeout is also 5s. Use a longer
    // transport budget so the busy mapping arrives before the read deadline.
    {
        const encoded = try client.encodeRequest(headless.store.METHOD_WORKSPACE_UPSERT, upsert);
        defer client.allocator.free(encoded.json);
        const endpoint = try sessionizer.socketPath(allocator, pref_path);
        defer allocator.free(endpoint);
        const raw = try platform_ipc.requestAlloc(allocator, endpoint, encoded.json, .{
            .max_message_bytes = sessionizer.MAX_RESPONSE_BYTES,
            .max_response_bytes = sessionizer.MAX_RESPONSE_BYTES,
            .timeout_ms = 15000,
        });
        defer allocator.free(raw);
        var busy_parsed = try client.parseResponse(raw);
        defer busy_parsed.deinit();
        const err = busy_parsed.response.err orelse return error.StoreBusyMissingError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_STORE_BUSY)) return error.StoreBusyWrongCode;
    }

    parent_conn.rollback();
    txn_open = false;
    parent_conn.close();
    conn_open = false;

    var applied_revision: u64 = 0;
    {
        var applied_parsed = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, upsert);
        defer applied_parsed.deinit();
        if (!applied_parsed.response.isOk()) return error.StoreBusyRetryFailed;
        const result = try client.decodeWriteResult(&applied_parsed);
        if (!result.applied or result.duplicate) return error.StoreBusyRetryNotApplied;
        applied_revision = result.store_revision;
    }

    {
        var replay_parsed = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, upsert);
        defer replay_parsed.deinit();
        if (!replay_parsed.response.isOk()) return error.StoreBusyReplayFailed;
        const result = try client.decodeWriteResult(&replay_parsed);
        // Receipt replay: original shape AND no extra revision bump (exactly-once).
        if (!result.applied or result.duplicate) return error.StoreBusyReplayShape;
        if (result.store_revision != applied_revision) return error.StoreBusyReplayRevisionBumped;
    }
}

/// Crash before commit: mutation absent, recovery clean, same key applies once.
fn runStoreCrashBeforeCommitScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-crash-before");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    // Backslash-safe on Windows; same join used for state.sqlite below.
    const store_dir = try std.fs.path.join(allocator, &.{ pref_path, "store" });
    defer allocator.free(store_dir);
    try std.Io.Dir.cwd().createDirPath(io, store_dir);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    const receipt_key = "s4-crash-before";
    // Seed revision 0 DB and capture baseline, then crash a mutation.
    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .store_fault = "crash_before_commit",
        });
        // Kill on bare-try unwind until the abort arm owns teardown (S3 fix pattern).
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
        defer register_parsed.deinit();
        if (!register_parsed.response.isOk()) return error.StoreCrashBeforeRegisterFailed;
        const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

        const upsert: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = receipt_key,
                .client_id = client_id,
            },
            .workspace = .{
                .workspace_id = "s4-crash-before-ws",
                .label = "CrashBefore",
                .path = pref_path,
            },
        };
        // Transport error/EOF expected when the daemon aborts mid-request.
        if (client.call(headless.store.METHOD_WORKSPACE_UPSERT, upsert)) |owned| {
            var parsed = owned;
            defer parsed.deinit();
            // If a response arrived, treat success as a failure of the crash arm.
            if (parsed.response.isOk()) return error.StoreCrashBeforeUnexpectedSuccess;
        } else |_| {}

        // Abort/exit owns teardown from here; waitChildBounded kills on hang.
        const term = waitChildBounded(&child, io, 10000) catch {
            kill_on_unwind = false;
            return error.StoreCrashBeforeDidNotExit;
        };
        kill_on_unwind = false;
        switch (term) {
            .exited => |code| if (code == 0) return error.StoreCrashBeforeCleanExit,
            .signal => {}, // abort → signal is the expected abnormal path
            else => {},
        }
    }

    // Direct read-only integrity: mutation ABSENT, revision unchanged, no receipt.
    {
        const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
        defer conn.close();

        const integrity = (try conn.row("pragma integrity_check", .{})).?;
        defer integrity.deinit();
        if (!std.mem.eql(u8, integrity.text(0), "ok")) return error.StoreCrashBeforeIntegrityFailed;

        const fk = (try conn.row("pragma foreign_key_check", .{}));
        if (fk) |row| {
            defer row.deinit();
            return error.StoreCrashBeforeFkFailed;
        }

        const rev_row = (try conn.row("select store_revision from store_state where id = 1", .{})) orelse
            return error.StoreCrashBeforeMissingState;
        defer rev_row.deinit();
        if (rev_row.int(0) != 0) return error.StoreCrashBeforeRevisionBumped;

        const ws_row = (try conn.row(
            "select count(*) from workspaces where workspace_id = 's4-crash-before-ws'",
            .{},
        )).?;
        defer ws_row.deinit();
        if (ws_row.int(0) != 0) return error.StoreCrashBeforeMutationPresent;

        const receipt_row = (try conn.row(
            "select count(*) from store_receipts where request_key = ?1",
            .{receipt_key},
        )).?;
        defer receipt_row.deinit();
        if (receipt_row.int(0) != 0) return error.StoreCrashBeforeReceiptPresent;
    }

    // Respawn fault-none; same request_key applies exactly once.
    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
        });
        defer child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
        var scenario: FixtureScenario = .{ .client = &client };

        var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
        defer register_parsed.deinit();
        if (!register_parsed.response.isOk()) return error.StoreCrashBeforeReopenRegisterFailed;
        const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

        const upsert: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = receipt_key,
                .client_id = client_id,
            },
            .workspace = .{
                .workspace_id = "s4-crash-before-ws",
                .label = "CrashBefore",
                .path = pref_path,
            },
        };
        var applied = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, upsert);
        defer applied.deinit();
        if (!applied.response.isOk()) return error.StoreCrashBeforeReopenApplyFailed;
        const result = try client.decodeWriteResult(&applied);
        if (!result.applied or result.duplicate) return error.StoreCrashBeforeReopenNotApplied;

        // Counts via zqlite: one workspace row + one receipt for the key.
        const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        // Close the daemon writer before parent RO open for a clean snapshot.
        // The store is still open on the daemon; RO open of WAL is fine.
        var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        const ws_row = (try conn.row(
            "select count(*) from workspaces where workspace_id = 's4-crash-before-ws'",
            .{},
        )).?;
        defer ws_row.deinit();
        if (ws_row.int(0) != 1) return error.StoreCrashBeforeCountMismatch;
        const receipt_row = (try conn.row(
            "select count(*) from store_receipts where request_key = ?1",
            .{receipt_key},
        )).?;
        defer receipt_row.deinit();
        if (receipt_row.int(0) != 1) return error.StoreCrashBeforeReceiptCountMismatch;
    }
}

/// Crash after commit: mutation PRESENT with bumped revision; same key replays.
fn runStoreCrashAfterCommitScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-crash-after");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    // Backslash-safe on Windows; same join used for state.sqlite below.
    const store_dir = try std.fs.path.join(allocator, &.{ pref_path, "store" });
    defer allocator.free(store_dir);
    try std.Io.Dir.cwd().createDirPath(io, store_dir);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    const receipt_key = "s4-crash-after";
    var committed_revision: u64 = 0;
    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .store_fault = "crash_after_commit",
        });
        // Kill on bare-try unwind until the abort arm owns teardown (S3 fix pattern).
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
        defer register_parsed.deinit();
        if (!register_parsed.response.isOk()) return error.StoreCrashAfterRegisterFailed;
        const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

        const upsert: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = receipt_key,
                .client_id = client_id,
            },
            .workspace = .{
                .workspace_id = "s4-crash-after-ws",
                .label = "CrashAfter",
                .path = pref_path,
            },
        };
        if (client.call(headless.store.METHOD_WORKSPACE_UPSERT, upsert)) |owned| {
            var parsed = owned;
            defer parsed.deinit();
            // Response may race abort after commit; either transport error or a
            // partial/ok response is acceptable. Success is verified via SQLite.
            if (parsed.response.isOk()) {
                if (client.decodeWriteResult(&parsed)) |result| {
                    committed_revision = result.store_revision;
                } else |_| {}
            }
        } else |_| {}

        // Abort/exit owns teardown from here; waitChildBounded kills on hang.
        const term = waitChildBounded(&child, io, 10000) catch {
            kill_on_unwind = false;
            return error.StoreCrashAfterDidNotExit;
        };
        kill_on_unwind = false;
        switch (term) {
            .exited => |code| if (code == 0) return error.StoreCrashAfterCleanExit,
            .signal => {},
            else => {},
        }
    }

    {
        const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
        defer conn.close();

        const integrity = (try conn.row("pragma integrity_check", .{})).?;
        defer integrity.deinit();
        if (!std.mem.eql(u8, integrity.text(0), "ok")) return error.StoreCrashAfterIntegrityFailed;

        const rev_row = (try conn.row("select store_revision from store_state where id = 1", .{})) orelse
            return error.StoreCrashAfterMissingState;
        defer rev_row.deinit();
        const rev: u64 = @intCast(rev_row.int(0));
        if (rev == 0) return error.StoreCrashAfterRevisionUnchanged;
        if (committed_revision == 0) committed_revision = rev;
        if (rev != committed_revision) return error.StoreCrashAfterRevisionMismatch;

        const ws_row = (try conn.row(
            "select count(*) from workspaces where workspace_id = 's4-crash-after-ws'",
            .{},
        )).?;
        defer ws_row.deinit();
        if (ws_row.int(0) != 1) return error.StoreCrashAfterMutationMissing;

        const receipt_row = (try conn.row(
            "select count(*) from store_receipts where request_key = ?1",
            .{receipt_key},
        )).?;
        defer receipt_row.deinit();
        if (receipt_row.int(0) != 1) return error.StoreCrashAfterReceiptMissing;
    }

    // Respawn: same request_key → receipt replay; pin counts (no second row).
    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
        });
        defer child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
        var scenario: FixtureScenario = .{ .client = &client };

        var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
        defer register_parsed.deinit();
        if (!register_parsed.response.isOk()) return error.StoreCrashAfterReopenRegisterFailed;
        const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

        const upsert: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = receipt_key,
                .client_id = client_id,
            },
            .workspace = .{
                .workspace_id = "s4-crash-after-ws",
                .label = "CrashAfter",
                .path = pref_path,
            },
        };
        var replay = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, upsert);
        defer replay.deinit();
        if (!replay.response.isOk()) return error.StoreCrashAfterReplayFailed;
        const result = try client.decodeWriteResult(&replay);
        if (result.store_revision != committed_revision) return error.StoreCrashAfterReplayRevision;
        if (!result.applied or result.duplicate) return error.StoreCrashAfterReplayShape;

        const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        const ws_row = (try conn.row(
            "select count(*) from workspaces where workspace_id = 's4-crash-after-ws'",
            .{},
        )).?;
        defer ws_row.deinit();
        if (ws_row.int(0) != 1) return error.StoreCrashAfterReplayCountMismatch;
        const receipt_row = (try conn.row(
            "select count(*) from store_receipts where request_key = ?1",
            .{receipt_key},
        )).?;
        defer receipt_row.deinit();
        if (receipt_row.int(0) != 1) return error.StoreCrashAfterReplayReceiptCount;
    }
}

fn runIntegration(allocator: std.mem.Allocator, io: std.Io) !void {
    // Isolated pref dir under the system temp path (never the user's Verde pref).
    const pref_path = try makePrefPath(allocator, "core");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

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

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    // Stale socket file with nothing accepting: daemon must still start.
    {
        var file = try std.Io.Dir.cwd().createFile(io, isolation.endpoint, .{});
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
    // Bound wait: a hang regression fails instead of blocking CI forever.
    const second_term = waitChildBounded(&second, io, 5000) catch |err| {
        if (err == error.ChildTimedOut) return error.SecondDaemonDidNotExit;
        return err;
    };
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

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

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
    if (std.mem.indexOf(u8, prepare, "\"code\":\"invalid_state\"") == null and
        std.mem.indexOf(u8, prepare, "\"code\": \"invalid_state\"") == null)
    {
        return error.PrepareShutdownShouldRefuseLivePty;
    }
    if (std.mem.indexOf(u8, prepare, "\"running_sessions\":1") == null and
        std.mem.indexOf(u8, prepare, "\"running_sessions\": 1") == null)
    {
        return error.PrepareShutdownMissingRunningCount;
    }
    // Refused prepare must leave the daemon accepting mutations.
    const status_after = try sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 6);
    defer allocator.free(status_after);
    if (std.mem.indexOf(u8, status_after, "\"accepting_mutations\":false") != null or
        std.mem.indexOf(u8, status_after, "\"accepting_mutations\": false") != null)
    {
        return error.AcceptingMutationsClearedOnRefusedPrepare;
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

    const kill_response = try sessionizer.requestAlloc(allocator, pref_path, "session.kill", .{ .id = session_id }, 5);
    defer allocator.free(kill_response);
}

/// Store-active graceful replace: two leases (one short-expiry) + finished
/// terminal process transfer to the successor with same lease_id; expired
/// lease pruned; store_revision advances exactly once for the drain commit.
fn runLifecycleGracefulReplaceWithTransfer(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "graceful-xfer");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    const store_dir = try std.fs.path.join(allocator, &.{ pref_path, "store" });
    defer allocator.free(store_dir);
    try std.Io.Dir.cwd().createDirPath(io, store_dir);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var keep_lease_id: ?[]const u8 = null;
    defer if (keep_lease_id) |id| allocator.free(id);
    var expired_lease_id: ?[]const u8 = null;
    defer if (expired_lease_id) |id| allocator.free(id);
    var finished_session_id: ?[]const u8 = null;
    defer if (finished_session_id) |id| allocator.free(id);
    var baseline_revision: u64 = 0;

    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
        });
        // No defer kill: prepareShutdown should exit. Kill only on bare-try unwind.
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
        defer register_parsed.deinit();
        if (!register_parsed.response.isOk()) return error.TransferRegisterFailed;

        // Finished terminal process → durable outcome for transfer.
        const session_id = "verde:headless-it:xfer-session";
        var created = try client.call("session.create", .{
            .id = session_id,
            .cwd = pref_path,
            .workspace_path = pref_path,
            .command = &[_][]const u8{"/bin/cat"},
            .cols = sessionizer.DEFAULT_COLS,
            .rows = sessionizer.DEFAULT_ROWS,
        });
        defer created.deinit();
        if (!created.response.isOk()) return error.TransferSessionCreateFailed;

        var killed = try client.call("session.kill", .{ .id = session_id });
        defer killed.deinit();
        if (!killed.response.isOk()) return error.TransferSessionKillFailed;

        // Wait for the outcome to land in the registry (drain poll).
        var saw_outcome = false;
        var outcome_attempt: usize = 0;
        while (outcome_attempt < 100) : (outcome_attempt += 1) {
            var listed = try client.call(headless.registry.METHOD_PROCESS_LIST, .{
                .workspace = .{ .workspace_path = pref_path },
                .include_outcomes = true,
            });
            defer listed.deinit();
            if (listed.response.isOk()) {
                const result = try client.decodeProcessList(&listed);
                for (result.outcomes) |outcome| {
                    if (std.mem.eql(u8, outcome.session_id, session_id)) {
                        saw_outcome = true;
                        break;
                    }
                }
                if (saw_outcome) break;
            }
            // Reap finished session so prepare is not blocked by a live PTY.
            var cleanup = try client.call("session.cleanup", .{});
            defer cleanup.deinit();
            std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
        if (!saw_outcome) return error.TransferOutcomeMissing;
        finished_session_id = try allocator.dupe(u8, session_id);

        // Ensure the PTY session is gone before prepare (live PTY still blocks).
        var session_reaped = false;
        var reap_attempt: usize = 0;
        while (reap_attempt < 100) : (reap_attempt += 1) {
            var cleanup = try client.call("session.cleanup", .{});
            defer cleanup.deinit();
            var status = try client.call("status", .{});
            defer status.deinit();
            if (status.response.result) |result| {
                if (result == .object) {
                    const running = result.object.get("running_session_count") orelse .null;
                    if (running == .integer and running.integer == 0) {
                        session_reaped = true;
                        break;
                    }
                }
            }
            std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        }
        if (!session_reaped) return error.TransferSessionDidNotReap;

        const resources_keep = [_][]const u8{"build"};
        const resources_exp = [_][]const u8{"test"};

        // Short-expiry lease (min TTL = 1s) and a long-lived lease.
        var short_parsed = try client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
            .workspace = .{ .workspace_path = pref_path },
            .owner = "owner-short",
            .command = "test",
            .resources = &resources_exp,
            .ttl_ms = 1_000,
        });
        defer short_parsed.deinit();
        if (!short_parsed.response.isOk()) return error.TransferShortLeaseFailed;
        const short_result = try client.decodeLeaseAcquire(&short_parsed);
        const short_id = short_result.lease_id orelse return error.TransferShortLeaseIdMissing;
        expired_lease_id = try allocator.dupe(u8, short_id);

        var long_parsed = try client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
            .workspace = .{ .workspace_path = pref_path },
            .owner = "owner-keep",
            .command = "build",
            .resources = &resources_keep,
            .ttl_ms = 60_000,
        });
        defer long_parsed.deinit();
        if (!long_parsed.response.isOk()) return error.TransferLongLeaseFailed;
        const long_result = try client.decodeLeaseAcquire(&long_parsed);
        const long_id = long_result.lease_id orelse return error.TransferLongLeaseIdMissing;
        keep_lease_id = try allocator.dupe(u8, long_id);

        // Baseline: no store mutations yet → revision 0.
        const empty_params: struct {} = .{};
        var status_parsed = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
        defer status_parsed.deinit();
        if (!status_parsed.response.isOk()) return error.TransferStoreStatusFailed;
        const status = try client.decodeStoreStatus(&status_parsed);
        baseline_revision = status.store_revision;
        if (baseline_revision != 0) return error.TransferUnexpectedBaselineRevision;

        // Wait for the short lease to expire so successor import prunes it.
        std.Io.sleep(io, .fromMilliseconds(1_100), .awake) catch {};

        // Store active + unexpired lease must NOT block prepare (transfer path).
        var prepare_parsed = try client.call("daemon.prepareShutdown", .{});
        defer prepare_parsed.deinit();
        if (!prepare_parsed.response.isOk()) return error.TransferPrepareNotAccepted;
        const prepare_result = prepare_parsed.arena_parsed.value.object.get("result") orelse
            return error.TransferPrepareNotAccepted;
        const accepted = prepare_result.object.get("accepted") orelse
            return error.TransferPrepareNotAccepted;
        if (accepted != .bool or !accepted.bool) return error.TransferPrepareNotAccepted;

        kill_on_unwind = false;

        var exited = false;
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
                allocator.free(response);
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
                continue;
            } else |err| {
                if (err == error.ConnectionRefused or err == error.FileNotFound) {
                    exited = true;
                    break;
                }
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
            }
        }
        if (!exited) {
            child.kill(io);
            return error.TransferDaemonDidNotExit;
        }
        _ = child.wait(io) catch {};
    }

    // Successor opens the same store_dir after endpoint ownership.
    var second = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
    });
    defer second.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    // store_revision advanced exactly once for the transfer commit.
    const empty_params: struct {} = .{};
    var status_parsed = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
    defer status_parsed.deinit();
    if (!status_parsed.response.isOk()) return error.TransferSuccessorStatusFailed;
    const status = try client.decodeStoreStatus(&status_parsed);
    if (status.store_revision != baseline_revision + 1) return error.TransferRevisionNotAdvancedOnce;

    var listed = try client.call(headless.registry.METHOD_PROCESS_LIST, .{
        .workspace = .{ .workspace_path = pref_path },
        .include_outcomes = true,
    });
    defer listed.deinit();
    if (!listed.response.isOk()) return error.TransferSuccessorListFailed;
    const list_result = try client.decodeProcessList(&listed);

    const keep_id = keep_lease_id orelse return error.TransferKeepIdMissing;
    const exp_id = expired_lease_id orelse return error.TransferExpIdMissing;
    const session_id = finished_session_id orelse return error.TransferSessionIdMissing;

    if (list_result.leases.len != 1) return error.TransferLeaseCountMismatch;
    if (!std.mem.eql(u8, list_result.leases[0].id, keep_id)) return error.TransferLeaseIdMismatch;
    for (list_result.leases) |lease| {
        if (std.mem.eql(u8, lease.id, exp_id)) return error.TransferExpiredLeaseResurrected;
    }

    var found_outcome = false;
    for (list_result.outcomes) |outcome| {
        if (std.mem.eql(u8, outcome.session_id, session_id)) {
            found_outcome = true;
            break;
        }
    }
    if (!found_outcome) return error.TransferOutcomeNotImported;
}

/// Empty daemon: prepareShutdown accepts → daemon exits → replacement binds.
fn runLifecycleGracefulReplace(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "graceful");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var first = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    // Do not kill: prepareShutdown acceptance should drain and exit.

    {
        const status = try sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0);
        defer allocator.free(status);
        if (std.mem.indexOf(u8, status, "\"accepting_mutations\":true") == null and
            std.mem.indexOf(u8, status, "\"accepting_mutations\": true") == null)
        {
            first.kill(io);
            return error.StatusMissingAcceptingMutations;
        }
    }

    const prepare = try sessionizer.requestAlloc(allocator, pref_path, "daemon.prepareShutdown", .{}, 1);
    defer allocator.free(prepare);
    if (std.mem.indexOf(u8, prepare, "\"accepted\":true") == null and
        std.mem.indexOf(u8, prepare, "\"accepted\": true") == null)
    {
        first.kill(io);
        std.debug.print("headless-daemon-it: prepareShutdown not accepted on empty daemon: {s}\n", .{prepare});
        return error.PrepareShutdownShouldAcceptEmpty;
    }
    if (std.mem.indexOf(u8, prepare, "\"safe_to_exit\":true") == null and
        std.mem.indexOf(u8, prepare, "\"safe_to_exit\": true") == null)
    {
        first.kill(io);
        return error.PrepareShutdownShouldBeSafeEmpty;
    }
    if (std.mem.indexOf(u8, prepare, "\"accepting_mutations\":false") == null and
        std.mem.indexOf(u8, prepare, "\"accepting_mutations\": false") == null)
    {
        first.kill(io);
        return error.PrepareShouldStopAcceptingMutations;
    }
    if (std.mem.indexOf(u8, prepare, "\"shutdown_requested\":true") == null and
        std.mem.indexOf(u8, prepare, "\"shutdown_requested\": true") == null)
    {
        first.kill(io);
        return error.PrepareShouldRequestShutdown;
    }

    // Daemon must exit after accepted prepare through the joined drain path.
    var exited = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
            allocator.free(response);
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
            continue;
        } else |err| {
            // Only treat connect-class as gone (mirrors production replacement).
            if (err == error.ConnectionRefused or err == error.FileNotFound) {
                exited = true;
                break;
            }
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
        }
    }
    if (!exited) {
        first.kill(io);
        return error.DaemonDidNotExitAfterPrepare;
    }
    _ = first.wait(io) catch {};

    // New daemon must bind the same endpoint after the previous process exited.
    var second = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer second.kill(io);

    const status = try sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 2);
    defer allocator.free(status);
    if (std.mem.indexOf(u8, status, "protocol_version") == null) return error.ReplacementDaemonStatusFailed;
    if (std.mem.indexOf(u8, status, "\"accepting_mutations\":true") == null and
        std.mem.indexOf(u8, status, "\"accepting_mutations\": true") == null)
    {
        return error.ReplacementDaemonNotAcceptingMutations;
    }
    if (std.mem.indexOf(u8, status, "\"shutdown_requested\":true") != null or
        std.mem.indexOf(u8, status, "\"shutdown_requested\": true") != null)
    {
        return error.ReplacementDaemonUnexpectedlyShuttingDown;
    }
}

/// Env override enables fast idle exit for hermetic tests; default is persistent.
fn runLifecycleIdleExitOverride(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "idle");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    // >=500ms: 100ms raced on loaded CI before the status probe observed exit.
    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{ .idle_exit_ms = "500" });
    // Do not kill: idle exit should terminate the empty daemon.

    // Confirm the daemon advertised the override before waiting for exit.
    {
        const status = try sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0);
        defer allocator.free(status);
        if (std.mem.indexOf(u8, status, "\"idle_exit_ms\":500") == null and
            std.mem.indexOf(u8, status, "\"idle_exit_ms\": 500") == null)
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
        } else |err| {
            if (err == error.ConnectionRefused or err == error.FileNotFound) {
                exited = true;
                break;
            }
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
        }
    }
    if (!exited) {
        child.kill(io);
        return error.IdleExitDidNotFire;
    }
    // Reap the exited child to avoid zombies.
    _ = child.wait(io) catch {};
}
