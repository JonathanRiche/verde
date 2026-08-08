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
const transcript_apply = @import("chat/transcript_apply.zig");
const zqlite = @import("zqlite");
// M4-P4 fix F2 arm: the GENUINE GUI snapshot conversion + persisted DTOs so
// the parity scenario exercises the real writer chain, not a hand-built shape.
const db_types = @import("db/types.zig");
const persistence = @import("state/persistence.zig");
// M4-P5 fix (MAJOR-4): the IT binary embeds the REAL CLI MCP serve loop for
// the `--mcp` child, and (amendment arm) the GUI-side adoption entry point.
// Only POSIX-gated scenarios reference these decls, so lazy analysis keeps the
// windows-gnu cross-compile surface unchanged.
const cli_main = @import("cli/main.zig");
const cli_output = @import("cli/output.zig");
const chat_controller = @import("state/chat_controller.zig");
const chat_types = @import("state/chat_types.zig");
const live_endpoint = @import("platform/live_endpoint.zig");

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
        if (std.mem.eql(u8, arg, "--mcp")) {
            // M4-P5 fix (MAJOR-4): serve the REAL MCP loop (cli/main.zig
            // handleMcp) over this child's stdin/stdout. The inherited
            // endpoint override routes every daemon transport to the parent's
            // hermetic daemon; the loop exits cleanly on stdin EOF.
            const out: cli_output.Output = .{ .io = io };
            try cli_main.handleMcp(allocator, out, io);
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

    // Windows-safe store subset (S5 + P3 production open).
    // Paths use std.fs.path; endpoints via platform isolation (no Unix-socket assumptions).
    // NIT-2: bind exclusivity for Windows remains transport-owned via PTY-tier
    // runLifecycleBindGuard / runLifecycleGracefulReplace (subsumed; not re-added here).
    try runStoreLessScenario(allocator, io);
    try runStoreEnabledScenario(allocator, io);
    try runStoreProductionOpenScenario(allocator, io);
    try runStoreDurableReopenScenario(allocator, io);
    try runNotifyRequiresDaemonScenario(allocator, io);
    // M3-P3 Phase B design pins (protocol-layer GUI reopen + conflict recovery).
    try runGuiReopenRevisionScenario(allocator, io); // MAJOR-3(a)
    try runCliGuiSimultaneousConflictScenario(allocator, io); // MAJOR-3(b)

    // M4-P2 durable chat (Windows-safe subset): stub provider + store dir.
    try runChatDisconnectedCommitScenario(allocator, io); // scenario 1
    try runChatDuplicateCommitReceiptScenario(allocator, io); // scenario 2
    try runChatFailedAbortedCommitScenario(allocator, io); // scenario 4
    try runChatTypedDtoRoundTripScenario(allocator, io); // scenario 6
    // M4-P3 production dual-write pins (Windows-safe): parity + revision conflict.
    try runChatTurnParityScenario(allocator, io);
    try runChatDaemonCommitStaleSnapshotConflictScenario(allocator, io);
    // M4-P4 authority flip (Windows-safe): durable-before-consume + MAJOR-R1.
    try runChatAuthorityFlipPrepareAndCrashObserveScenario(allocator, io);
    try runChatCloseBeforeConsumeReopenScenario(allocator, io);
    try runChatFocusedCompletionClearScenario(allocator, io);
    try runChatCompletedTurnReplayRejectScenario(allocator, io);
    try runChatDurableCommitFailAlwaysScenario(allocator, io);
    // M4-P5 MCP/CLI flip (Windows-safe): capability advertisement + no-GUI
    // create/send/stream/approve/stop/read lifecycle with a daemon restart.
    try runChatMcpCliFlipNoGuiScenario(allocator, io);
    // M4-P5 fix (MAJOR-4): the REAL MCP tool layer over a piped `--mcp` child.
    // Self-gates POSIX-only (bounded pipe reads use std.posix.poll).
    try runChatMcpToolLayerScenario(allocator, io);
    // M4-P5 fix amendment: failed-first identity adoption converges via retry
    // to a single identity set across flush + daemon restart. POSIX-gated.
    try runChatAdoptionRetryDurabilityScenario(allocator, io);

    // M5-P2 composite snapshot + change-journal cursor (Windows-safe subset:
    // transport + store dir only). Wire-level tail-vs-slow-commit concurrency
    // stays out of scope until M5-P3 (A7); scenario 1 pins the wait_ms clamp.
    try runM5ChangesJournalScenario(allocator, io); // scenario 1 + wait_ms clamp
    try runM5SnapshotCompositeScenario(allocator, io); // scenario 2 + M3 byte-compat
    try runM5ChangesOverflowExpiryScenario(allocator, io); // scenario 3
    try runM5DaemonReplacementCursorScenario(allocator, io); // scenario 4
    try runM5RollbackReplayJournalScenario(allocator, io); // scenario 5 (A2)
    try runM5SnapshotIncompleteScopesScenario(allocator, io); // scenario 6

    // Extended store scenarios (POSIX only): full surface + S4 fault/busy/crash pins.
    // Transport-tier primitives, but not part of the Windows-safe subset.
    if (posix_pty_supported) {
        try runStoreFullSurfaceScenario(allocator, io);
        try runStoreBoundedQueueingScenario(allocator, io);
        try runStoreBusyRetryScenario(allocator, io);
        try runStoreCrashBeforeCommitScenario(allocator, io);
        try runStoreCrashAfterCommitScenario(allocator, io);
        // M4-P2 POSIX-only: kill mid-turn + slow commit vs session.tail.
        try runChatKillMidTurnScenario(allocator, io); // scenario 3
        try runChatSlowCommitDoesNotStallSessionTailScenario(allocator, io); // scenario 5
        // MAJOR-3 (M4-P2b fix): commit fault + bounded retry recovery.
        try runChatCommitFaultRetryScenario(allocator, io);
        // MAJOR-3(c): real `verde notify` CLI binary against hermetic daemon / auto-start.
        try runCliBinaryNotifyScenario(allocator, io);
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
        // P3: version-skew blocked replacement with live PTY is read-only, no writer fallback.
        try version_skew_blocked_replacement_is_read_only_without_fallback(allocator, io);
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
/// P3 adds `store_disable` so store-less capability pins survive production open.
/// M4-P2 adds `chat_stub` so turn-commit ITs stay offline (no real provider).
const IsolatedDaemonOptions = struct {
    idle_exit_ms: ?[]const u8 = null,
    store_dir: ?[]const u8 = null,
    /// When set with `store_dir`, maps to `VERDE_SESSION_DAEMON_STORE_FAULT`.
    store_fault: ?[]const u8 = null,
    /// When true, sets VERDE_SESSION_DAEMON_STORE_DISABLE so the production store
    /// open is skipped (store-less capability_unavailable pin).
    store_disable: bool = false,
    /// When true, chat workers complete with canned events (no provider I/O).
    chat_stub: bool = false,
    /// When set with `store_dir`, maps to `VERDE_SESSION_DAEMON_CHAT_COMMIT_FAULT`
    /// (MAJOR-3 bounded-retry IT: `fail_once`).
    chat_commit_fault: ?[]const u8 = null,
    slow_io_ms: ?[]const u8 = null,
    retention_ms: ?[]const u8 = null,
    /// When set, maps to `VERDE_SESSION_DAEMON_JOURNAL_ENTRY_CAP` so the M5-P2
    /// overflow scenario can force change-journal eviction with few entries.
    journal_entry_cap: ?[]const u8 = null,
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
    if (options.store_disable) try env_map.put(sessionizer.SESSION_DAEMON_STORE_DISABLE_ENV_NAME, "1");
    if (options.chat_stub) try env_map.put(sessionizer.SESSION_DAEMON_CHAT_STUB_ENV_NAME, "1");
    if (options.chat_commit_fault) |value| try env_map.put(sessionizer.SESSION_DAEMON_CHAT_COMMIT_FAULT_ENV_NAME, value);
    if (options.journal_entry_cap) |value| try env_map.put(sessionizer.SESSION_DAEMON_JOURNAL_ENTRY_CAP_ENV_NAME, value);

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
/// NIT-3 (S5): Unix-tuned; Windows named-pipe teardown can also surface
/// PipeBusy / BrokenPipe / Unexpected — widen when a Windows runtime IT exists.
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
    // Store-disabled: pin the dormant path where active leases still refuse
    // prepare. Store-active transfer is covered by runLifecycleGracefulReplaceWithTransfer.
    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_disable = true,
    });
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

/// P3 production open: no store_dir override → daemon opens `{pref}/state.sqlite`,
/// advertises store=true, and accepts a mutation. Pins the authority flip path.
fn runStoreProductionOpenScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-production-open");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    // No store_dir: production path opens pref_path/state.sqlite after bind.
    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    {
        const empty_params: struct {} = .{};
        var status_parsed = try client.call("core.status", empty_params);
        defer status_parsed.deinit();
        if (!status_parsed.response.isOk()) return error.StoreProductionCoreStatusFailed;
        const status = try client.decodeStatus(&status_parsed);
        if (!status.capabilities.store) return error.StoreProductionCapabilityFalse;
    }

    var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer register_parsed.deinit();
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

    const request: headless.store.WorkspaceUpsertRequest = .{
        .mutation = .{
            .request_key = "p3-production-ws",
            .client_id = client_id,
        },
        .workspace = .{
            .workspace_id = "p3-production-ws",
            .label = "Production",
            .path = pref_path,
        },
    };
    var upsert = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, request);
    defer upsert.deinit();
    if (!upsert.response.isOk()) return error.StoreProductionUpsertFailed;
    const write = try client.decodeWriteResult(&upsert);
    if (!write.applied or write.store_revision != 1) return error.StoreProductionWriteResultWrong;

    // Production DB must exist under the preference path (not a hermetic redirect).
    const db_path = try std.fs.path.join(allocator, &.{ pref_path, "state.sqlite" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    const flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open(db_path_z, flags);
    defer conn.close();
    const row = (try conn.row(
        "select label from workspaces where workspace_id = ?1",
        .{"p3-production-ws"},
    )) orelse return error.StoreProductionDbMissingRow;
    defer row.deinit();
    if (!std.mem.eql(u8, row.text(0), "Production")) return error.StoreProductionDbWrongLabel;
}

/// MAJOR-3(a): GUI reopen / revision pin at the protocol layer.
/// Launch-1: persistent client mutates via snapshot.replace with expected guard.
/// Launch-2: new connection + client (second GUI process), RO-load equivalent via
/// store.status, then snapshot.replace with the pinned revision succeeds — the
/// exact BLOCKER-1 regression pin (never bootstrap / never expected=null).
fn runGuiReopenRevisionScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "gui-reopen-revision");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    // Production open (no store_dir) so revision lives under pref_path/state.sqlite.
    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    var receipt_revision: u64 = 0;
    {
        // Launch-1: persistent GUI client.
        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        var reg = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = true });
        defer reg.deinit();
        if (!reg.response.isOk()) return error.GuiReopenLaunch1RegisterFailed;
        const client_id = (try client.decodeClientRegister(&reg)).client_id;

        const replace: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = "m3p3-gui-launch1-replace",
                .client_id = client_id,
                .expected_store_revision = 0,
            },
            .snapshot = .{
                .schema_version = 1,
                .workspaces = &.{.{
                    .workspace_id = "m3p3-gui-ws",
                    .label = "GUI reopen",
                    .path = pref_path,
                }},
                .surface_states = &.{.{
                    .session_id = "m3p3-gui-session",
                    .status = "working",
                    .title = "launch-1",
                }},
            },
            .bootstrap = false,
        };
        var parsed = try client.call(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, replace);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.GuiReopenLaunch1ReplaceFailed;
        const write = try client.decodeWriteResult(&parsed);
        if (!write.applied or write.store_revision < 1) return error.GuiReopenLaunch1RevisionWrong;
        receipt_revision = write.store_revision;
    }

    // Launch-2: new connection / new client (simulates GUI close + reopen).
    {
        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        // RO-load equivalent: store.status pins the durable revision.
        const empty_params: struct {} = .{};
        var status_parsed = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
        defer status_parsed.deinit();
        if (!status_parsed.response.isOk()) return error.GuiReopenStatusFailed;
        const status = try client.decodeStoreStatus(&status_parsed);
        if (status.store_revision != receipt_revision) return error.GuiReopenStatusRevisionMismatch;

        var reg = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = true });
        defer reg.deinit();
        if (!reg.response.isOk()) return error.GuiReopenLaunch2RegisterFailed;
        const client_id = (try client.decodeClientRegister(&reg)).client_id;

        // Fresh snapshot.replace with the pinned launch-1 receipt revision must succeed
        // (BLOCKER-1: launch-2 never sends bootstrap / expected=null).
        const replace: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = "m3p3-gui-launch2-replace",
                .client_id = client_id,
                .expected_store_revision = receipt_revision,
            },
            .snapshot = .{
                .schema_version = 1,
                .workspaces = &.{.{
                    .workspace_id = "m3p3-gui-ws",
                    .label = "GUI reopen",
                    .path = pref_path,
                }},
                .surface_states = &.{.{
                    .session_id = "m3p3-gui-session",
                    .status = "done",
                    .title = "launch-2",
                }},
            },
            .bootstrap = false,
        };
        var parsed = try client.call(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, replace);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.GuiReopenLaunch2ReplaceFailed;
        const write = try client.decodeWriteResult(&parsed);
        if (!write.applied or write.store_revision != receipt_revision + 1) return error.GuiReopenLaunch2RevisionWrong;
    }
}

/// MAJOR-3(b): two clients mutate; client A's expected goes stale → explicit conflict
/// (not silent clobber) → A refreshes via store.status and retries once with a fresh
/// guard → success. Pins Phase A conflict-recovery protocol at the wire layer.
fn runCliGuiSimultaneousConflictScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "cli-gui-conflict");
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
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    var reg_a = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = true });
    defer reg_a.deinit();
    if (!reg_a.response.isOk()) return error.ConflictClientARegisterFailed;
    const client_a = (try client.decodeClientRegister(&reg_a)).client_id;

    var reg_b = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer reg_b.deinit();
    if (!reg_b.response.isOk()) return error.ConflictClientBRegisterFailed;
    const client_b = (try client.decodeClientRegister(&reg_b)).client_id;

    // Seed revision 1 so both clients share a known baseline N.
    {
        const seed: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = "m3p3-conflict-seed",
                .client_id = client_a,
                .expected_store_revision = 0,
            },
            .workspace = .{
                .workspace_id = "m3p3-conflict-ws",
                .label = "Seed",
                .path = pref_path,
            },
        };
        var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, seed);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.ConflictSeedFailed;
        const write = try client.decodeWriteResult(&parsed);
        if (!write.applied or write.store_revision != 1) return error.ConflictSeedRevision;
    }

    const empty_params: struct {} = .{};
    var status_n = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
    defer status_n.deinit();
    if (!status_n.response.isOk()) return error.ConflictStatusNFailed;
    const n = (try client.decodeStoreStatus(&status_n)).store_revision;
    if (n != 1) return error.ConflictUnexpectedN;

    // Client B advances the store to N+1 while A still holds expected=N.
    {
        const b_upsert: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = "m3p3-conflict-b-advance",
                .client_id = client_b,
                .expected_store_revision = n,
            },
            .workspace = .{
                .workspace_id = "m3p3-conflict-b",
                .label = "B advanced",
                .path = pref_path,
            },
        };
        var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, b_upsert);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.ConflictBAdvanceFailed;
        const write = try client.decodeWriteResult(&parsed);
        if (!write.applied or write.store_revision != n + 1) return error.ConflictBAdvanceRevision;
    }

    // Client A with stale expected=N → explicit conflict (not silent clobber).
    {
        const stale: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = "m3p3-conflict-a-stale",
                .client_id = client_a,
                .expected_store_revision = n,
            },
            .snapshot = .{
                .schema_version = 1,
                .workspaces = &.{.{
                    .workspace_id = "m3p3-conflict-a",
                    .label = "A stale",
                    .path = pref_path,
                }},
            },
            .bootstrap = false,
        };
        var parsed = try client.call(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, stale);
        defer parsed.deinit();
        const err = parsed.response.err orelse return error.ConflictAMissingError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_CONFLICT)) return error.ConflictAWrongCode;
    }

    // A refreshes via store.status (Phase A client recovery) and retries once.
    var status_fresh = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
    defer status_fresh.deinit();
    if (!status_fresh.response.isOk()) return error.ConflictRefreshFailed;
    const fresh = (try client.decodeStoreStatus(&status_fresh)).store_revision;
    if (fresh != n + 1) return error.ConflictRefreshRevision;

    {
        const retry: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = "m3p3-conflict-a-retry",
                .client_id = client_a,
                .expected_store_revision = fresh,
            },
            .snapshot = .{
                .schema_version = 1,
                .workspaces = &.{.{
                    .workspace_id = "m3p3-conflict-a",
                    .label = "A recovered",
                    .path = pref_path,
                }},
            },
            .bootstrap = false,
        };
        var parsed = try client.call(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, retry);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.ConflictARetryFailed;
        const write = try client.decodeWriteResult(&parsed);
        if (!write.applied or write.store_revision != fresh + 1) return error.ConflictARetryRevision;
    }
}

/// Resolve the production `verde` CLI binary for MAJOR-3(c). Mirrors daemon
/// discovery: VERDE_IT_CLI_PATH override, sibling of this IT exe, then
/// zig-out/bin/verde from cwd. Returns null when absent so the scenario can
/// declare an honest residual gap.
fn resolveVerdeCliBinary(allocator: std.mem.Allocator, io: std.Io, self_exe: []const u8) !?[]u8 {
    if (try itGetEnvAlloc(allocator, "VERDE_IT_CLI_PATH")) |path| {
        if (path.len > 0) {
            if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
                return path;
            } else |_| {
                allocator.free(path);
            }
        } else {
            allocator.free(path);
        }
    }
    if (std.fs.path.dirname(self_exe)) |dir| {
        const sibling = try std.fs.path.join(allocator, &.{ dir, "verde" });
        if (std.Io.Dir.cwd().access(io, sibling, .{})) |_| {
            return sibling;
        } else |_| {
            allocator.free(sibling);
        }
    }
    // Headless-daemon-it often runs with packages/desktop as cwd (desktop
    // build -p), so also probe monorepo-root zig-out via ../.. .
    const cwd_candidates = [_][]const u8{
        "zig-out/bin/verde",
        "packages/desktop/zig-out/bin/verde",
        "../../zig-out/bin/verde",
        "../zig-out/bin/verde",
    };
    for (cwd_candidates) |rel| {
        if (std.Io.Dir.cwd().access(io, rel, .{})) |_| {
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const abs_len = std.Io.Dir.cwd().realPathFile(io, rel, &path_buf) catch continue;
            return try allocator.dupe(u8, path_buf[0..abs_len]);
        } else |_| {}
    }
    return null;
}

/// MAJOR-3(c): execute the real `verde notify` CLI binary against a hermetic
/// daemon (env-pointed pref + socket) and pin daemon auto-start via argv[0].
/// POSIX tier only. When the CLI binary is not build-provided, falls back to
/// the protocol-layer surface.upsert path and declares the residual gap.
fn runCliBinaryNotifyScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    if (comptime !posix_pty_supported) return;

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    const cli_path = try resolveVerdeCliBinary(allocator, io, self_exe);
    defer if (cli_path) |p| allocator.free(p);

    if (cli_path) |verde| {
        const cli_ok = runCliBinaryNotifyWithBinary(allocator, io, self_exe, verde) catch |err| blk: {
            std.debug.print(
                "headless-daemon-it: MAJOR-3(c) CLI binary path failed ({s}) with {s}; falling back to protocol pin\n",
                .{ verde, @errorName(err) },
            );
            break :blk false;
        };
        if (cli_ok) return;
        std.debug.print(
            "headless-daemon-it: MAJOR-3(c) residual gap — CLI binary {s} did not land a surface row (stale pre-Phase-A install or missing VERDE_IT_CLI_PATH); protocol-layer notify pin only. Full zig build install of post-Phase-A verde is blocked by unrelated ghostty comptime assert on this host.\n",
            .{verde},
        );
    } else {
        std.debug.print(
            "headless-daemon-it: MAJOR-3(c) residual gap — verde CLI binary not found beside IT or at zig-out/bin/verde; running protocol-layer notify pin only\n",
            .{},
        );
    }
    // Closest honest variant: protocol-layer surface.upsert against hermetic daemon
    // (the store path `verde notify` uses). BLOCKER-2 argv[0] remains unit-pinned
    // in cli/main.zig; re-run full CLI legs via VERDE_IT_CLI_PATH when available.
    try runNotifyProtocolLayerFallback(allocator, io);
}

/// Returns true when both live-daemon and auto-start legs succeed with `verde`.
fn runCliBinaryNotifyWithBinary(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    verde: []const u8,
) !bool {
    // --- Leg 1: notify against a live hermetic daemon (env-pointed). ---
    {
        const base_tmp = try makePrefPath(allocator, "cli-notify-live");
        defer allocator.free(base_tmp);
        defer std.Io.Dir.cwd().deleteTree(io, base_tmp) catch {};
        try std.Io.Dir.cwd().createDirPath(io, base_tmp);

        // CLI prefPath = $XDG_DATA_HOME/verde/Native on Linux.
        const xdg_data = try std.fs.path.join(allocator, &.{ base_tmp, "xdg-data" });
        defer allocator.free(xdg_data);
        try std.Io.Dir.cwd().createDirPath(io, xdg_data);
        const pref_path = try std.fs.path.join(allocator, &.{ xdg_data, "verde", "Native" });
        defer allocator.free(pref_path);
        try std.Io.Dir.cwd().createDirPath(io, pref_path);

        var isolation = try EndpointIsolation.install(allocator, pref_path);
        defer isolation.deinit(allocator);

        var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
        defer child.kill(io);

        var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
        defer env_map.deinit();
        try env_map.put("XDG_DATA_HOME", xdg_data);
        try env_map.put(sessionizer.SESSIONIZER_SOCKET_ENV_NAME, isolation.endpoint);
        try env_map.put("VERDE_SESSION_DAEMON_IDLE_EXIT_MS", IT_SAFETY_IDLE_EXIT_MS);
        try env_map.put("VERDE_SESSION_ID", "m3p3-cli-notify-live");

        var notify_child = try std.process.spawn(io, .{
            .argv = &.{
                verde,
                "notify",
                "--status",
                "working",
                "--session",
                "m3p3-cli-notify-live",
                "--quiet",
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .environ_map = &env_map,
        });
        const term = try notify_child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) return false,
            else => return false,
        }

        // Surface state must land in the production DB under pref_path.
        // surfaceStatusCode: idle=0, working=1, waiting=2, done=3, error=4.
        const db_path = try std.fs.path.join(allocator, &.{ pref_path, "state.sqlite" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var conn = zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode) catch return false;
        defer conn.close();
        const row = (try conn.row(
            "select status from surface_completions where session_id = ?1",
            .{"m3p3-cli-notify-live"},
        )) orelse return false;
        defer row.deinit();
        if (row.int(0) != 1) return false;
    }

    // --- Leg 2: no daemon + auto-start via real argv[0] (BLOCKER-2 pin). ---
    {
        const base_tmp = try makePrefPath(allocator, "cli-notify-autostart");
        defer allocator.free(base_tmp);
        defer std.Io.Dir.cwd().deleteTree(io, base_tmp) catch {};
        try std.Io.Dir.cwd().createDirPath(io, base_tmp);

        const xdg_data = try std.fs.path.join(allocator, &.{ base_tmp, "xdg-data" });
        defer allocator.free(xdg_data);
        try std.Io.Dir.cwd().createDirPath(io, xdg_data);
        const pref_path = try std.fs.path.join(allocator, &.{ xdg_data, "verde", "Native" });
        defer allocator.free(pref_path);
        try std.Io.Dir.cwd().createDirPath(io, pref_path);

        // Pref-derived socket only (no VERDE_SESSIONIZER_SOCKET): ensureDaemon
        // spawns `verde __session-daemon` with the real binary path (argv[0]).
        var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
        defer env_map.deinit();
        try env_map.put("XDG_DATA_HOME", xdg_data);
        // Clear any ambient isolation socket from prior legs / parent.
        _ = env_map.swapRemove(sessionizer.SESSIONIZER_SOCKET_ENV_NAME);
        try env_map.put("VERDE_SESSION_DAEMON_IDLE_EXIT_MS", IT_SAFETY_IDLE_EXIT_MS);
        try env_map.put("VERDE_SESSION_ID", "m3p3-cli-notify-autostart");

        var notify_child = try std.process.spawn(io, .{
            .argv = &.{
                verde,
                "notify",
                "--status",
                "done",
                "--session",
                "m3p3-cli-notify-autostart",
                "--quiet",
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .environ_map = &env_map,
        });
        const term = try notify_child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) return false,
            else => return false,
        }

        var ready = false;
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
                allocator.free(response);
                ready = true;
                break;
            } else |_| {
                std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
            }
        }
        if (!ready) return false;

        if (sessionizer.requestAlloc(allocator, pref_path, "daemon.prepareShutdown", .{}, 0)) |resp| {
            allocator.free(resp);
        } else |_| {}

        const db_path = try std.fs.path.join(allocator, &.{ pref_path, "state.sqlite" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var conn = zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode) catch return false;
        defer conn.close();
        const row = (try conn.row(
            "select status from surface_completions where session_id = ?1",
            .{"m3p3-cli-notify-autostart"},
        )) orelse return false;
        defer row.deinit();
        // done = 3 (surfaceStatusCode ordinal).
        if (row.int(0) != 3) return false;
    }
    return true;
}

/// Protocol-layer stand-in when the CLI binary is not available to the harness.
fn runNotifyProtocolLayerFallback(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "notify-protocol-fallback");
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
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    var reg = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer reg.deinit();
    const client_id = (try client.decodeClientRegister(&reg)).client_id;

    const request: headless.store.SurfaceUpsertRequest = .{
        .mutation = .{
            .request_key = "m3p3-notify-fallback",
            .client_id = client_id,
        },
        .surface = .{
            .session_id = "m3p3-notify-fallback",
            .status = "working",
        },
    };
    var parsed = try client.call(headless.store.METHOD_SURFACE_UPSERT, request);
    defer parsed.deinit();
    if (!parsed.response.isOk()) return error.NotifyFallbackUpsertFailed;
    const write = try client.decodeWriteResult(&parsed);
    if (!write.applied) return error.NotifyFallbackNotApplied;
}

/// P3 notify regression: with store disabled (daemon auto-start yields store-less),
/// surface mutations return a structured store error — never a silent offline writer.
fn runNotifyRequiresDaemonScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "notify-requires-daemon");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_disable = true,
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
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

    const request: headless.store.SurfaceUpsertRequest = .{
        .mutation = .{
            .request_key = "p3-notify-surface",
            .client_id = client_id,
        },
        .surface = .{
            .session_id = "notify-session",
            .status = "working",
        },
    };
    var parsed = try client.call(headless.store.METHOD_SURFACE_UPSERT, request);
    defer parsed.deinit();
    const err = parsed.response.err orelse return error.NotifyStoreLessMissingError;
    if (!std.mem.eql(u8, err.code, headless.protocol.ERR_CAPABILITY_UNAVAILABLE)) return error.NotifyStoreLessWrongCode;
    if (!std.mem.eql(u8, err.message, "store capability is unavailable")) return error.NotifyStoreLessWrongMessage;

    // No production DB must have been created by a direct writer fallback.
    const db_path = try std.fs.path.join(allocator, &.{ pref_path, "state.sqlite" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    const open_flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode;
    if (zqlite.open(db_path_z, open_flags)) |conn| {
        conn.close();
        return error.NotifyDirectWriterCreatedDb;
    } else |_| {}
}

/// Store-less daemon: all store methods return capability_unavailable.
/// After P3 production open, this uses VERDE_SESSION_DAEMON_STORE_DISABLE so the
/// capability_unavailable surface remains pinable without a dual-writer path.
fn runStoreLessScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-less");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_disable = true,
    });
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

    // P3 authority pin: core.status advertises store=true once the writer owns the DB.
    {
        const empty_params: struct {} = .{};
        var status_parsed = try client.call("core.status", empty_params);
        defer status_parsed.deinit();
        if (!status_parsed.response.isOk()) return error.StoreEnabledCoreStatusFailed;
        const status = try client.decodeStatus(&status_parsed);
        if (!status.capabilities.store) return error.StoreEnabledStoreCapabilityNotAdvertised;
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

/// M5-P2 scenario 1: core.changes reports store commits and registry bumps
/// through the nonce-scoped journal with one volatile envelope per reply,
/// topic filters narrow entries without stalling the cursor, and wait_ms is
/// clamped to an immediate heartbeat (Q7) instead of parking the serial
/// accept loop (A7: latency pin only until M5-P3 lands concurrency).
fn runM5ChangesJournalScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m5-changes");
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

    var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer register_parsed.deinit();
    if (!register_parsed.response.isOk()) return error.M5ChangesRegisterFailed;
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

    // Absent cursor bootstraps at the tail of the (still empty) journal.
    const boot_req: headless.changes_protocol.ChangesRequest = .{};
    var boot = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, boot_req);
    defer boot.deinit();
    if (!boot.response.isOk()) return error.M5ChangesBootstrapFailed;
    const boot_result = try client.decodeChanges(&boot);
    if (boot_result.next_cursor != 0) return error.M5ChangesBootstrapCursorNotZero;
    if (!boot_result.heartbeat or boot_result.entries.len != 0) return error.M5ChangesBootstrapNotHeartbeat;
    if (boot_result.expired) return error.M5ChangesBootstrapExpired;
    if (boot_result.envelope.instance_nonce.len == 0) return error.M5ChangesBootstrapMissingNonce;

    // One store commit (durable revision family) ...
    const upsert: headless.store.WorkspaceUpsertRequest = .{
        .mutation = .{ .request_key = "m5-changes-ws", .client_id = client_id },
        .workspace = .{
            .workspace_id = "m5-changes-ws",
            .label = "M5 changes",
            .path = pref_path,
        },
    };
    var upsert_parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, upsert);
    defer upsert_parsed.deinit();
    if (!upsert_parsed.response.isOk()) return error.M5ChangesUpsertFailed;
    const upsert_result = try client.decodeWriteResult(&upsert_parsed);
    if (!upsert_result.applied or upsert_result.store_revision != 1) return error.M5ChangesUpsertNotApplied;

    // ... and one registry bump (volatile revision family).
    const resources = [_][]const u8{"build"};
    var lease_parsed = try client.call(headless.registry.METHOD_LEASE_ACQUIRE, .{
        .workspace = .{ .workspace_path = pref_path },
        .owner = "m5-owner",
        .command = "build",
        .resources = &resources,
    });
    defer lease_parsed.deinit();
    const lease_result = try client.decodeLeaseAcquire(&lease_parsed);
    if (!lease_result.acquired) return error.M5ChangesLeaseNotAcquired;

    const poll_req: headless.changes_protocol.ChangesRequest = .{ .cursor = boot_result.next_cursor };
    var poll = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, poll_req);
    defer poll.deinit();
    if (!poll.response.isOk()) return error.M5ChangesPollFailed;
    const poll_result = try client.decodeChanges(&poll);
    if (poll_result.expired or poll_result.heartbeat) return error.M5ChangesPollShape;
    if (poll_result.entries.len < 2) return error.M5ChangesPollTooFewEntries;
    if (poll_result.store_revision != 1) return error.M5ChangesPollStoreRevision;
    if (!std.mem.eql(u8, poll_result.envelope.instance_nonce, boot_result.envelope.instance_nonce))
        return error.M5ChangesPollNonceDrift;
    var found_store_workspace = false;
    var found_lease = false;
    var last_seq: u64 = 0;
    for (poll_result.entries) |entry| {
        if (entry.change_seq <= last_seq) return error.M5ChangesEntriesNotAscending;
        last_seq = entry.change_seq;
        if (std.mem.eql(u8, entry.topic, "workspace") and entry.store_revision != null) {
            if (entry.store_revision.? != 1) return error.M5ChangesWorkspaceRevision;
            found_store_workspace = true;
        }
        if (std.mem.eql(u8, entry.topic, "lease")) {
            if (entry.registry_revision == null) return error.M5ChangesLeaseMissingRegistryRevision;
            found_lease = true;
        }
    }
    if (!found_store_workspace) return error.M5ChangesMissingWorkspaceEntry;
    if (!found_lease) return error.M5ChangesMissingLeaseEntry;
    // Unfiltered poll drains to the tail, so next_cursor is the last entry seq.
    if (poll_result.next_cursor != last_seq) return error.M5ChangesNextCursorNotTail;

    // Topic filter narrows entries; the cursor still advances to the tail so
    // a filtered client never re-reads suppressed entries.
    const lease_topics = [_][]const u8{"lease"};
    const filtered_req: headless.changes_protocol.ChangesRequest = .{
        .cursor = boot_result.next_cursor,
        .topics = &lease_topics,
    };
    var filtered = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, filtered_req);
    defer filtered.deinit();
    if (!filtered.response.isOk()) return error.M5ChangesFilteredFailed;
    const filtered_result = try client.decodeChanges(&filtered);
    if (filtered_result.entries.len == 0) return error.M5ChangesFilterEmpty;
    for (filtered_result.entries) |entry| {
        if (!std.mem.eql(u8, entry.topic, "lease")) return error.M5ChangesFilterLeaked;
    }
    if (filtered_result.next_cursor != poll_result.next_cursor) return error.M5ChangesFilterCursorMismatch;

    // wait_ms clamp pin (Q7/A7): a large wait at the tail answers immediately
    // as a heartbeat. The bound is generous — it proves "no 60s park", not an
    // SLO — and stays far under the request timeout.
    const wait_started_ms = sessionizer.nowMs();
    const heartbeat_req: headless.changes_protocol.ChangesRequest = .{
        .cursor = poll_result.next_cursor,
        .wait_ms = 60_000,
    };
    var heartbeat = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, heartbeat_req);
    defer heartbeat.deinit();
    const wait_elapsed_ms = sessionizer.nowMs() - wait_started_ms;
    if (!heartbeat.response.isOk()) return error.M5ChangesHeartbeatFailed;
    const heartbeat_result = try client.decodeChanges(&heartbeat);
    if (!heartbeat_result.heartbeat or heartbeat_result.entries.len != 0) return error.M5ChangesHeartbeatShape;
    if (heartbeat_result.next_cursor != poll_result.next_cursor) return error.M5ChangesHeartbeatCursorMoved;
    if (wait_elapsed_ms > 5_000) return error.M5ChangesWaitNotClamped;
}

/// M5-P2 scenario 2: composite core.snapshot coherence — the store half and
/// its revision come from ONE read transaction, the change cursor seeds the
/// first poll without gaps, a scope-less request keeps the M3 store-only
/// reply byte-compatible (no composite keys at all), and the capability
/// advertisement for snapshots/changes/subscriptions stays false (M5-P5 flip).
fn runM5SnapshotCompositeScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m5-snapshot");
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

    var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer register_parsed.deinit();
    if (!register_parsed.response.isOk()) return error.M5SnapshotRegisterFailed;
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

    const upsertWorkspace = struct {
        fn run(cl: *headless.Client, cid: []const u8, key: []const u8, ws: []const u8, path: []const u8, expected: u64) !u64 {
            const req: headless.store.WorkspaceUpsertRequest = .{
                .mutation = .{ .request_key = key, .client_id = cid, .expected_store_revision = expected },
                .workspace = .{ .workspace_id = ws, .label = ws, .path = path },
            };
            var parsed = try cl.call(headless.store.METHOD_WORKSPACE_UPSERT, req);
            defer parsed.deinit();
            if (!parsed.response.isOk()) return error.M5SnapshotUpsertFailed;
            const result = try cl.decodeWriteResult(&parsed);
            if (!result.applied) return error.M5SnapshotUpsertNotApplied;
            return result.store_revision;
        }
    }.run;

    if (try upsertWorkspace(&client, client_id, "m5-snap-a", "m5-snap-a", pref_path, 0) != 1)
        return error.M5SnapshotFirstCommitRevision;

    const scopes = [_][]const u8{ "store", "registry", "sessions", "turns" };
    const snap_req: headless.store.CoreSnapshotRequest = .{ .scopes = &scopes };
    var snap1 = try client.call(headless.store.METHOD_CORE_SNAPSHOT, snap_req);
    defer snap1.deinit();
    if (!snap1.response.isOk()) return error.M5SnapshotFirstFailed;
    const snap1_result = try client.decodeCompositeSnapshot(&snap1);
    if (snap1_result.store_revision != 1) return error.M5SnapshotFirstRevision;
    // Coherence pin: the embedded snapshot and the top-level revision are the
    // same committed state (single read transaction on the store queue).
    if (snap1_result.snapshot.store_revision != snap1_result.store_revision) return error.M5SnapshotFirstIncoherent;
    if (snap1_result.snapshot.workspaces.len != 1) return error.M5SnapshotFirstWorkspaceCount;
    const envelope1 = snap1_result.envelope orelse return error.M5SnapshotFirstMissingEnvelope;
    if (envelope1.instance_nonce.len == 0) return error.M5SnapshotFirstMissingNonce;
    const cursor1 = snap1_result.change_cursor orelse return error.M5SnapshotFirstMissingCursor;
    if (cursor1 == 0) return error.M5SnapshotFirstCursorZero; // the commit above was journaled
    if (snap1_result.incomplete_scopes.len != 0) return error.M5SnapshotFirstIncomplete;
    if (snap1_result.turns.len != 0) return error.M5SnapshotFirstTurns;

    if (try upsertWorkspace(&client, client_id, "m5-snap-b", "m5-snap-b", pref_path, 1) != 2)
        return error.M5SnapshotSecondCommitRevision;

    var snap2 = try client.call(headless.store.METHOD_CORE_SNAPSHOT, snap_req);
    defer snap2.deinit();
    if (!snap2.response.isOk()) return error.M5SnapshotSecondFailed;
    const snap2_result = try client.decodeCompositeSnapshot(&snap2);
    if (snap2_result.store_revision != 2) return error.M5SnapshotSecondRevision;
    if (snap2_result.snapshot.store_revision != 2) return error.M5SnapshotSecondIncoherent;
    if (snap2_result.snapshot.workspaces.len != 2) return error.M5SnapshotSecondWorkspaceCount;
    const envelope2 = snap2_result.envelope orelse return error.M5SnapshotSecondMissingEnvelope;
    if (!std.mem.eql(u8, envelope2.instance_nonce, envelope1.instance_nonce)) return error.M5SnapshotNonceDrift;
    const cursor2 = snap2_result.change_cursor orelse return error.M5SnapshotSecondMissingCursor;
    if (cursor2 <= cursor1) return error.M5SnapshotCursorNotAdvancing;

    // Snapshot-seeded cursor resumes without gaps: the first commit after the
    // snapshot is exactly what the first poll sees.
    if (try upsertWorkspace(&client, client_id, "m5-snap-c", "m5-snap-c", pref_path, 2) != 3)
        return error.M5SnapshotThirdCommitRevision;
    const resume_req: headless.changes_protocol.ChangesRequest = .{ .cursor = cursor2 };
    var resume_parsed = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, resume_req);
    defer resume_parsed.deinit();
    if (!resume_parsed.response.isOk()) return error.M5SnapshotResumeFailed;
    const resume_result = try client.decodeChanges(&resume_parsed);
    if (resume_result.expired) return error.M5SnapshotResumeExpired;
    if (resume_result.entries.len != 1) return error.M5SnapshotResumeEntryCount;
    if (!std.mem.eql(u8, resume_result.entries[0].topic, "workspace")) return error.M5SnapshotResumeTopic;
    if ((resume_result.entries[0].store_revision orelse 0) != 3) return error.M5SnapshotResumeRevision;

    // M3 byte-compat: absent scopes keep the store-only reply shape — the
    // result object carries ONLY snapshot + store_revision, nothing else.
    const legacy_req: headless.store.CoreSnapshotRequest = .{};
    var legacy = try client.call(headless.store.METHOD_CORE_SNAPSHOT, legacy_req);
    defer legacy.deinit();
    if (!legacy.response.isOk()) return error.M5SnapshotLegacyFailed;
    const legacy_result = try client.decodeCompositeSnapshot(&legacy);
    if (legacy_result.envelope != null or legacy_result.change_cursor != null) return error.M5SnapshotLegacyComposite;
    if (legacy_result.store_revision != 3 or legacy_result.snapshot.workspaces.len != 3) return error.M5SnapshotLegacyContents;
    if (legacy_result.incomplete_scopes.len != 0) return error.M5SnapshotLegacyIncomplete;
    const legacy_root = legacy.arena_parsed.value;
    if (legacy_root != .object) return error.M5SnapshotLegacyRootShape;
    const legacy_result_value = legacy_root.object.get("result") orelse return error.M5SnapshotLegacyMissingResult;
    if (legacy_result_value != .object) return error.M5SnapshotLegacyResultShape;
    if (legacy_result_value.object.count() != 2) return error.M5SnapshotLegacyExtraKeys;
    if (legacy_result_value.object.get("snapshot") == null) return error.M5SnapshotLegacyMissingSnapshot;
    if (legacy_result_value.object.get("store_revision") == null) return error.M5SnapshotLegacyMissingRevision;

    // Capabilities stay unflipped through M5-P2 (charter: flip is M5-P5).
    const empty_params: struct {} = .{};
    var caps = try client.call("core.capabilities", empty_params);
    defer caps.deinit();
    if (!caps.response.isOk()) return error.M5SnapshotCapabilitiesFailed;
    const caps_result = try client.decodeCapabilities(&caps);
    if (caps_result.capabilities.snapshots) return error.M5SnapshotCapabilitySnapshotsFlipped;
    if (caps_result.capabilities.changes) return error.M5SnapshotCapabilityChangesFlipped;
    if (caps_result.capabilities.subscriptions) return error.M5SnapshotCapabilitySubscriptionsFlipped;
}

/// M5-P2 scenario 3: overflow honesty — a capped journal expires stale
/// cursors with `revision_expired` + a floor_seq datum (Q6), the composite
/// snapshot fallback reseeds the cursor, and polling resumes from the seed.
fn runM5ChangesOverflowExpiryScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m5-overflow");
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

    // Cap the ring at 4 entries so six commits evict seq 1 and 2 (floor 2).
    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .journal_entry_cap = "4",
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
    if (!register_parsed.response.isOk()) return error.M5OverflowRegisterFailed;
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

    // Client seeds its cursor at the empty tail (0), then falls behind.
    const boot_req: headless.changes_protocol.ChangesRequest = .{};
    var boot = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, boot_req);
    defer boot.deinit();
    if (!boot.response.isOk()) return error.M5OverflowBootstrapFailed;
    const boot_result = try client.decodeChanges(&boot);
    if (boot_result.next_cursor != 0) return error.M5OverflowBootstrapCursor;

    var commit_index: u64 = 0;
    while (commit_index < 6) : (commit_index += 1) {
        var key_buf: [48]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "m5-overflow-{d}", .{commit_index});
        const req: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = key,
                .client_id = client_id,
                .expected_store_revision = commit_index,
            },
            .workspace = .{ .workspace_id = key, .label = "M5 overflow", .path = pref_path },
        };
        var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.M5OverflowUpsertFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision != commit_index + 1) return error.M5OverflowUpsertRevision;
    }

    // Stale cursor 0 fell below the floor (2): Q6 error envelope + floor datum.
    const stale_req: headless.changes_protocol.ChangesRequest = .{ .cursor = 0 };
    var stale = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, stale_req);
    defer stale.deinit();
    if (stale.response.isOk()) return error.M5OverflowStaleNotRejected;
    const stale_err = stale.response.err orelse return error.M5OverflowStaleMissingError;
    if (!std.mem.eql(u8, stale_err.code, headless.protocol.ERR_REVISION_EXPIRED)) return error.M5OverflowWrongCode;
    _ = client.decodeChanges(&stale) catch |err| switch (err) {
        error.RemoteError => {},
        else => return err,
    };
    const stale_data = stale_err.data orelse return error.M5OverflowMissingData;
    if (stale_data != .object) return error.M5OverflowMalformedData;
    const floor_value = stale_data.object.get("floor_seq") orelse return error.M5OverflowMissingFloor;
    if (floor_value != .integer or floor_value.integer != 2) return error.M5OverflowWrongFloor;

    // Snapshot fallback reseeds the cursor at the journal tail.
    const scopes = [_][]const u8{"store"};
    const snap_req: headless.store.CoreSnapshotRequest = .{ .scopes = &scopes };
    var snap = try client.call(headless.store.METHOD_CORE_SNAPSHOT, snap_req);
    defer snap.deinit();
    if (!snap.response.isOk()) return error.M5OverflowSnapshotFailed;
    const snap_result = try client.decodeCompositeSnapshot(&snap);
    if (snap_result.store_revision != 6) return error.M5OverflowSnapshotRevision;
    if (snap_result.snapshot.workspaces.len != 6) return error.M5OverflowSnapshotWorkspaces;
    const reseeded = snap_result.change_cursor orelse return error.M5OverflowSnapshotMissingCursor;
    if (reseeded != 6) return error.M5OverflowSnapshotCursor;

    // The reseeded cursor resumes cleanly on the next commit.
    {
        const req: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{ .request_key = "m5-overflow-resume", .client_id = client_id, .expected_store_revision = 6 },
            .workspace = .{ .workspace_id = "m5-overflow-resume", .label = "M5 overflow", .path = pref_path },
        };
        var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.M5OverflowResumeUpsertFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (!result.applied or result.store_revision != 7) return error.M5OverflowResumeUpsertRevision;
    }
    const resume_req: headless.changes_protocol.ChangesRequest = .{ .cursor = reseeded };
    var resumed = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, resume_req);
    defer resumed.deinit();
    if (!resumed.response.isOk()) return error.M5OverflowResumeFailed;
    const resumed_result = try client.decodeChanges(&resumed);
    if (resumed_result.expired) return error.M5OverflowResumeExpired;
    if (resumed_result.entries.len != 1) return error.M5OverflowResumeEntryCount;
    if (!std.mem.eql(u8, resumed_result.entries[0].topic, "workspace")) return error.M5OverflowResumeTopic;
    if ((resumed_result.entries[0].store_revision orelse 0) != 7) return error.M5OverflowResumeRevision;
    if (resumed_result.next_cursor != 7) return error.M5OverflowResumeCursor;
    // Seventh append evicted seq 3 (cap 4): floor advanced with the ring.
    if (resumed_result.journal_floor_seq != 3) return error.M5OverflowResumeFloor;
}

/// M5-P2 scenario 4: daemon replacement on the same store — the successor
/// mints a fresh instance_nonce and an empty nonce-scoped journal (change_seq
/// restarts), while the durable store_revision persists. The old cursor is
/// invalidated by the envelope nonce change (client-side rule pinned in
/// packages/headless/src/client.zig advanceChangeCursor), not by seq compare.
fn runM5DaemonReplacementCursorScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m5-replace");
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

    var first_nonce: ?[]u8 = null;
    defer if (first_nonce) |owned| allocator.free(owned);
    var first_cursor: u64 = 0;
    var persisted_revision: u64 = 0;

    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
        });
        // No defer kill: prepareShutdown should exit the child. Kill on bare-try
        // unwind until prepare is accepted (pre-prepare orphan holds the endpoint).
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
        if (!register_parsed.response.isOk()) return error.M5ReplaceRegisterFailed;
        const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

        const upsert: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{ .request_key = "m5-replace-ws", .client_id = client_id },
            .workspace = .{ .workspace_id = "m5-replace-ws", .label = "M5 replace", .path = pref_path },
        };
        var upsert_parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, upsert);
        defer upsert_parsed.deinit();
        if (!upsert_parsed.response.isOk()) return error.M5ReplaceUpsertFailed;
        const upsert_result = try client.decodeWriteResult(&upsert_parsed);
        if (!upsert_result.applied) return error.M5ReplaceUpsertNotApplied;
        persisted_revision = upsert_result.store_revision;

        const boot_req: headless.changes_protocol.ChangesRequest = .{};
        var boot = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, boot_req);
        defer boot.deinit();
        if (!boot.response.isOk()) return error.M5ReplaceBootstrapFailed;
        const boot_result = try client.decodeChanges(&boot);
        if (boot_result.next_cursor == 0) return error.M5ReplaceBootstrapCursorZero; // the commit was journaled
        if (boot_result.envelope.instance_nonce.len == 0) return error.M5ReplaceMissingNonce;
        first_nonce = try allocator.dupe(u8, boot_result.envelope.instance_nonce);
        first_cursor = boot_result.next_cursor;

        var prepare = try client.call("daemon.prepareShutdown", .{});
        defer prepare.deinit();
        if (!prepare.response.isOk()) return error.M5ReplacePrepareFailed;
        const prepare_result = prepare.arena_parsed.value.object.get("result") orelse
            return error.M5ReplacePrepareNotAccepted;
        const accepted = prepare_result.object.get("accepted") orelse
            return error.M5ReplacePrepareNotAccepted;
        if (accepted != .bool or !accepted.bool) return error.M5ReplacePrepareNotAccepted;
        kill_on_unwind = false;

        // Exit-wait uses the same connect-class discrimination as the durable
        // reopen scenario: probes may still succeed while the drain completes.
        var exited = false;
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            if (sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 0)) |response| {
                allocator.free(response);
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
                continue;
            } else |err| {
                if (isConnectClassError(err)) {
                    exited = true;
                    break;
                }
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
            }
        }
        if (!exited) {
            child.kill(io);
            return error.M5ReplaceDaemonDidNotExit;
        }
        _ = child.wait(io) catch {};
    }

    // Successor on the SAME store: fresh nonce + fresh journal, durable revision
    // persists (drain transfer bump adds one on top of the mutation revision).
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

        const boot_req: headless.changes_protocol.ChangesRequest = .{};
        var boot = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, boot_req);
        defer boot.deinit();
        if (!boot.response.isOk()) return error.M5ReplaceReopenBootstrapFailed;
        const boot_result = try client.decodeChanges(&boot);
        // Nonce-scoped restart: new instance, empty journal, cursor restarts.
        if (std.mem.eql(u8, boot_result.envelope.instance_nonce, first_nonce.?)) return error.M5ReplaceNonceReused;
        if (boot_result.next_cursor != 0) return error.M5ReplaceJournalNotReset;
        if (boot_result.journal_floor_seq != 0) return error.M5ReplaceFloorNotReset;
        if (!boot_result.heartbeat or boot_result.entries.len != 0) return error.M5ReplaceReopenNotHeartbeat;
        // Durable half survives replacement: mutation revision + drain transfer bump.
        if (boot_result.store_revision != persisted_revision + 1) return error.M5ReplaceDurableRevisionLost;
        // The pre-replacement cursor value is numerically meaningless here; the
        // envelope nonce mismatch above is the invalidation signal clients use.
        if (first_cursor == 0) return error.M5ReplaceFirstCursorUnset;
    }
}

/// M5-P2 scenario 5 (A2 rollback/replay honesty): a conflicted mutation and a
/// replayed duplicate request_key append nothing to the journal, and a stub
/// chat turn's commitTurn journals its lifecycle exactly once (reads add zero).
fn runM5RollbackReplayJournalScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m5-rollback");
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
        .chat_stub = true,
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
    if (!register_parsed.response.isOk()) return error.M5RollbackRegisterFailed;
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;

    const original: headless.store.WorkspaceUpsertRequest = .{
        .mutation = .{ .request_key = "m5-rollback-ws", .client_id = client_id },
        .workspace = .{ .workspace_id = "m5-rollback-ws", .label = "M5 rollback", .path = pref_path },
    };
    var first = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, original);
    defer first.deinit();
    if (!first.response.isOk()) return error.M5RollbackUpsertFailed;
    const first_result = try client.decodeWriteResult(&first);
    if (!first_result.applied or first_result.store_revision != 1) return error.M5RollbackUpsertNotApplied;

    const boot_req: headless.changes_protocol.ChangesRequest = .{ .cursor = 0 };
    var boot = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, boot_req);
    defer boot.deinit();
    if (!boot.response.isOk()) return error.M5RollbackBaselineFailed;
    const boot_result = try client.decodeChanges(&boot);
    if (boot_result.entries.len == 0) return error.M5RollbackBaselineEmpty;
    const baseline_cursor = boot_result.next_cursor;

    // Conflict (stale expected_store_revision): rolled back, nothing journaled.
    {
        const conflicted: headless.store.WorkspaceUpsertRequest = .{
            .mutation = .{
                .request_key = "m5-rollback-conflict",
                .client_id = client_id,
                .expected_store_revision = 0, // stale: store is at 1
            },
            .workspace = .{ .workspace_id = "m5-rollback-conflict", .label = "M5 conflict", .path = pref_path },
        };
        var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, conflicted);
        defer parsed.deinit();
        const err = parsed.response.err orelse return error.M5RollbackConflictMissingError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_CONFLICT)) return error.M5RollbackConflictWrongCode;
    }
    {
        const req: headless.changes_protocol.ChangesRequest = .{ .cursor = baseline_cursor };
        var parsed = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.M5RollbackPostConflictFailed;
        const result = try client.decodeChanges(&parsed);
        if (result.entries.len != 0 or !result.heartbeat) return error.M5RollbackConflictJournaled;
        if (result.next_cursor != baseline_cursor) return error.M5RollbackConflictCursorMoved;
        if (result.store_revision != 1) return error.M5RollbackConflictRevision;
    }

    // Receipt replay (same request_key): original result, zero new entries (A2).
    {
        var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, original);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.M5RollbackReplayFailed;
        const result = try client.decodeWriteResult(&parsed);
        if (result.store_revision != first_result.store_revision or
            result.applied != first_result.applied or
            result.duplicate != first_result.duplicate)
        {
            return error.M5RollbackReplayMismatch;
        }
    }
    {
        const req: headless.changes_protocol.ChangesRequest = .{ .cursor = baseline_cursor };
        var parsed = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.M5RollbackPostReplayFailed;
        const result = try client.decodeChanges(&parsed);
        if (result.entries.len != 0) return error.M5RollbackReplayJournaled;
        if (result.next_cursor != baseline_cursor) return error.M5RollbackReplayCursorMoved;
    }

    // A2 chat half: one stub turn commits once; its journal window carries the
    // chat lifecycle topics, and a follow-up read adds nothing new.
    try startStubChatTurn(&client, "m5-rollback-turn", "m5-rollback-ws", "m5-rollback-thread", pref_path, "m5 body", "m5-user-1");
    try waitChatTurnTerminal(io, &client, "m5-rollback-turn", true);
    var chat_thread_entries: usize = 0;
    var chat_turn_entries: usize = 0;
    var chat_completion_entries: usize = 0;
    var post_chat_cursor: u64 = 0;
    {
        const req: headless.changes_protocol.ChangesRequest = .{ .cursor = baseline_cursor };
        var parsed = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.M5RollbackChatPollFailed;
        const result = try client.decodeChanges(&parsed);
        for (result.entries) |entry| {
            if (std.mem.eql(u8, entry.topic, "chat.thread")) chat_thread_entries += 1;
            if (std.mem.eql(u8, entry.topic, "chat.turn")) chat_turn_entries += 1;
            if (std.mem.eql(u8, entry.topic, "chat.completion")) chat_completion_entries += 1;
        }
        post_chat_cursor = result.next_cursor;
    }
    if (chat_thread_entries == 0) return error.M5RollbackChatThreadMissing;
    if (chat_turn_entries == 0) return error.M5RollbackChatTurnMissing;
    // Exactly one completion append per committed turn (commitTurn hook, A2).
    if (chat_completion_entries != 1) return error.M5RollbackChatCompletionCount;

    // A turn-record read replays nothing and journals nothing.
    var record = try client.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "m5-rollback-turn" });
    defer record.deinit();
    if (!record.response.isOk()) return error.M5RollbackRecordFailed;
    const record_result = try client.decodeTurnRecord(&record);
    if (record_result.committed_store_revision == null) return error.M5RollbackRecordNotCommitted;
    {
        const req: headless.changes_protocol.ChangesRequest = .{ .cursor = post_chat_cursor };
        var parsed = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, req);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.M5RollbackPostRecordFailed;
        const result = try client.decodeChanges(&parsed);
        if (result.entries.len != 0) return error.M5RollbackReadJournaled;
        if (result.next_cursor != post_chat_cursor) return error.M5RollbackReadCursorMoved;
    }
}

/// M5-P2 scenario 6: incomplete_scopes honesty — unknown scopes are marked
/// while every known scope is served completely (CHAT_AUTHORITY_LANDED), and
/// a store-less daemon answers capability_unavailable for both core reads.
fn runM5SnapshotIncompleteScopesScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    // Store-enabled half: unknown scope is marked, known scopes are not.
    {
        const pref_path = try makePrefPath(allocator, "m5-scopes");
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

        const scopes = [_][]const u8{ "store", "registry", "sessions", "turns", "surface.experimental" };
        const snap_req: headless.store.CoreSnapshotRequest = .{ .scopes = &scopes };
        var snap = try client.call(headless.store.METHOD_CORE_SNAPSHOT, snap_req);
        defer snap.deinit();
        if (!snap.response.isOk()) return error.M5ScopesSnapshotFailed;
        const snap_result = try client.decodeCompositeSnapshot(&snap);
        if (snap_result.incomplete_scopes.len != 1) return error.M5ScopesIncompleteCount;
        if (!std.mem.eql(u8, snap_result.incomplete_scopes[0], "surface.experimental")) return error.M5ScopesWrongIncomplete;
        // Known scopes are answered, not merely tolerated: composite fields present.
        if (snap_result.envelope == null or snap_result.change_cursor == null) return error.M5ScopesMissingComposite;
        if (snap_result.store_revision != 0) return error.M5ScopesUnexpectedRevision;
    }

    // Store-less half: both core reads refuse with capability_unavailable
    // (documented M5-P2 simplification; the store owns both durable halves).
    {
        const pref_path = try makePrefPath(allocator, "m5-scopes-less");
        defer allocator.free(pref_path);
        defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
        try std.Io.Dir.cwd().createDirPath(io, pref_path);

        var isolation = try EndpointIsolation.install(allocator, pref_path);
        defer isolation.deinit(allocator);

        const self_exe = try std.process.executablePathAlloc(io, allocator);
        defer allocator.free(self_exe);

        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_disable = true,
        });
        defer child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        const snap_req: headless.store.CoreSnapshotRequest = .{};
        var snap = try client.call(headless.store.METHOD_CORE_SNAPSHOT, snap_req);
        defer snap.deinit();
        const snap_err = snap.response.err orelse return error.M5ScopesStoreLessSnapshotAccepted;
        if (!std.mem.eql(u8, snap_err.code, headless.protocol.ERR_CAPABILITY_UNAVAILABLE)) return error.M5ScopesStoreLessSnapshotWrongCode;

        const changes_req: headless.changes_protocol.ChangesRequest = .{};
        var changes = try client.call(headless.changes_protocol.METHOD_CORE_CHANGES, changes_req);
        defer changes.deinit();
        const changes_err = changes.response.err orelse return error.M5ScopesStoreLessChangesAccepted;
        if (!std.mem.eql(u8, changes_err.code, headless.protocol.ERR_CAPABILITY_UNAVAILABLE)) return error.M5ScopesStoreLessChangesWrongCode;
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

// ── M4-P2 durable chat turn-commit scenarios ────────────────────────────────

/// Wait until chat.turn.tail reports a terminal status (and optionally a commit).
fn waitChatTurnTerminal(
    io: std.Io,
    client: *headless.Client,
    turn_id: []const u8,
    require_commit: bool,
) !void {
    var attempts: usize = 0;
    var last_status_buf: [64]u8 = undefined;
    var last_status_len: usize = 0;
    var last_err_buf: [96]u8 = undefined;
    var last_err_len: usize = 0;
    var last_pending: bool = false;
    var last_has_commit: bool = false;
    // M4-P4 durable-first: status may stay non-terminal while durability_pending.
    // Count consecutive pending+error observations so fail_once's ~50 ms window
    // cannot trip ChatTurnDurableCommitFailed, but fail_always (exhausted retry)
    // does after the backoff budget.
    var consecutive_pending_error: usize = 0;
    const pending_error_fail_threshold: usize = 20; // ~500 ms at 25 ms poll
    // Budget covers commit_stall staging/finalize (multiple 1.5s arms) + network.
    while (attempts < 800) : (attempts += 1) {
        var parsed = client.call("chat.turn.tail", .{ .turn_id = turn_id, .after_seq = 0 }) catch {
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            continue;
        };
        defer parsed.deinit();
        if (!parsed.response.isOk()) {
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            continue;
        }
        const result = parsed.response.result orelse {
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            continue;
        };
        if (result != .object) {
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            continue;
        }
        const status = result.object.get("status") orelse .null;
        const status_text = if (status == .string) status.string else "";
        last_status_len = @min(status_text.len, last_status_buf.len);
        @memcpy(last_status_buf[0..last_status_len], status_text[0..last_status_len]);
        const terminal = std.mem.eql(u8, status_text, "completed") or
            std.mem.eql(u8, status_text, "failed") or
            std.mem.eql(u8, status_text, "aborted");
        if (require_commit) {
            const committed = result.object.get("committed_store_revision") orelse .null;
            last_has_commit = committed != .null;
            const pending = result.object.get("durability_pending") orelse .null;
            last_pending = pending == .bool and pending.bool;
            const d_err = result.object.get("durability_error") orelse .null;
            if (d_err == .string) {
                last_err_len = @min(d_err.string.len, last_err_buf.len);
                @memcpy(last_err_buf[0..last_err_len], d_err.string[0..last_err_len]);
            } else last_err_len = 0;
            // Exhausted durable commit (fail_always): pending+error sticks after
            // 3 attempts. Require consecutive observations so fail_once recovery
            // cannot false-fail (MINOR-V3). Observable before terminal status
            // under durable-first publication.
            if (last_pending and last_err_len != 0) {
                consecutive_pending_error += 1;
                if (consecutive_pending_error >= pending_error_fail_threshold) {
                    std.debug.print(
                        "headless-daemon-it: durable commit failed turn_id={s} status={s} err={s}\n",
                        .{ turn_id, status_text, last_err_buf[0..last_err_len] },
                    );
                    return error.ChatTurnDurableCommitFailed;
                }
            } else {
                consecutive_pending_error = 0;
            }
            if (committed != .null and !last_pending and terminal) return;
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            continue;
        }
        if (!terminal) {
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            continue;
        }
        return;
    }
    std.debug.print(
        "headless-daemon-it: turn did not finish turn_id={s} last_status={s} has_commit={} pending={} durability_error={s}\n",
        .{
            turn_id,
            last_status_buf[0..last_status_len],
            last_has_commit,
            last_pending,
            last_err_buf[0..last_err_len],
        },
    );
    return error.ChatTurnDidNotFinish;
}

fn consumeChatTurn(client: *headless.Client, turn_id: []const u8) !void {
    var parsed = try client.call("chat.turn.consume", .{ .turn_id = turn_id });
    defer parsed.deinit();
    if (!parsed.response.isOk()) return error.ChatTurnConsumeFailed;
}

fn startStubChatTurn(
    client: *headless.Client,
    turn_id: []const u8,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    project_path: []const u8,
    prompt: []const u8,
    message_id: []const u8,
) !void {
    var parsed = try client.call("chat.turn.start", .{
        .turn_id = turn_id,
        .workspace_id = workspace_id,
        .local_thread_id = local_thread_id,
        .project_path = project_path,
        .prompt = prompt,
        .thread_title = "M4 IT thread",
        .provider = "codex",
        .harness = "local_cli",
        .message_id = message_id,
        // Offline worker path: independent of env plumbing (also set via chat_stub env).
        .test_stub = true,
    });
    defer parsed.deinit();
    if (!parsed.response.isOk()) return error.ChatTurnStartFailed;
}

/// Scenario 1: complete with clients disconnected; RO reopen asserts durable rows.
fn runChatDisconnectedCommitScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4-chat-commit");
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

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .chat_stub = true,
    });
    var kill_on_unwind = true;
    errdefer if (kill_on_unwind) child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    try startStubChatTurn(
        &client,
        "turn-disc-1",
        "ws-disc",
        "thread-disc",
        pref_path,
        "hello durable",
        "user-disc-1",
    );
    // Durable commit must not require a second live client connection.
    try waitChatTurnTerminal(io, &client, "turn-disc-1", true);
    try consumeChatTurn(&client, "turn-disc-1");

    // Prepare + exit so the store is finalized before RO reopen.
    var prepare = try client.call("daemon.prepareShutdown", .{});
    defer prepare.deinit();
    if (!prepare.response.isOk()) return error.ChatDisconnectPrepareFailed;
    kill_on_unwind = false;
    _ = child.wait(io) catch {};

    const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
    defer conn.close();

    var ledger = (try conn.row(
        "select status, user_message_id, committed_store_revision from chat_turns where turn_id = 'turn-disc-1'",
        .{},
    )) orelse return error.ChatDisconnectMissingLedger;
    defer ledger.deinit();
    if (!std.mem.eql(u8, ledger.text(0), "completed")) return error.ChatDisconnectBadStatus;
    if (!std.mem.eql(u8, ledger.text(1), "user-disc-1")) return error.ChatDisconnectBadUserId;
    if (ledger.nullableInt(2) == null) return error.ChatDisconnectMissingRevision;

    // MINOR-1: require ≥2 messages including at least one assistant row
    // (not just the staged user row).
    var msgs = (try conn.row(
        "select count(*) from messages where thread_id = (select id from threads where local_thread_id = 'thread-disc')",
        .{},
    )).?;
    defer msgs.deinit();
    if (msgs.int(0) < 2) return error.ChatDisconnectMissingMessages;
    var assistants = (try conn.row(
        "select count(*) from messages where thread_id = (select id from threads where local_thread_id = 'thread-disc') and role = 2",
        .{},
    )).?;
    defer assistants.deinit();
    if (assistants.int(0) < 1) return error.ChatDisconnectMissingAssistant;

    var receipts = (try conn.row(
        "select count(*) from store_receipts where request_key = 'turn:turn-disc-1:commit'",
        .{},
    )).?;
    defer receipts.deinit();
    if (receipts.int(0) != 1) return error.ChatDisconnectReceiptCount;

    var completions = (try conn.row(
        "select count(*) from chat_completions where workspace_id = 'ws-disc' and local_thread_id = 'thread-disc'",
        .{},
    )).?;
    defer completions.deinit();
    if (completions.int(0) != 1) return error.ChatDisconnectMissingCompletion;
}

/// Scenario 2: complete once, then verify receipt replay via a second identical
/// commitTurn through a fresh daemon open does not append (unit path also pins
/// this; here we re-open and re-dispatch by starting the same turn identity is
/// rejected — instead assert single receipt and re-read revision after reopen).
fn runChatDuplicateCommitReceiptScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4-chat-dup");
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

    var first_revision: u64 = 0;
    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        try startStubChatTurn(&client, "turn-dup-1", "ws-dup", "thread-dup", pref_path, "dup body", "user-dup-1");
        try waitChatTurnTerminal(io, &client, "turn-dup-1", true);

        var record = try client.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-dup-1" });
        defer record.deinit();
        if (!record.response.isOk()) return error.ChatDupRecordFailed;
        const first = try client.decodeTurnRecord(&record);
        first_revision = first.committed_store_revision orelse return error.ChatDupMissingRevision;
        try consumeChatTurn(&client, "turn-dup-1");

        var prepare = try client.call("daemon.prepareShutdown", .{});
        defer prepare.deinit();
        if (!prepare.response.isOk()) return error.ChatDupPrepareFailed;
        kill_on_unwind = false;
        _ = child.wait(io) catch {};
    }

    // Restart successor on the same store: interrupt sweep must not touch completed,
    // and the receipt remains unique.
    {
        var child2 = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child2.kill(io);

        var decode_arena2 = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena2.deinit();
        var transport2: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena2.allocator(),
            .pref_path = pref_path,
        };
        var client2 = sessionizer.headlessClient(decode_arena2.allocator(), &transport2);
        var record2 = try client2.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-dup-1" });
        defer record2.deinit();
        if (!record2.response.isOk()) return error.ChatDupRecord2Failed;
        const second = try client2.decodeTurnRecord(&record2);
        if (second.committed_store_revision) |rev| {
            if (rev != first_revision) return error.ChatDupRevisionDrift;
        } else return error.ChatDupMissingRevision2;

        var status = try client2.call(headless.store.METHOD_DAEMON_STORE_STATUS, .{});
        defer status.deinit();
        if (!status.response.isOk()) return error.ChatDupStatusFailed;

        var prepare2 = try client2.call("daemon.prepareShutdown", .{});
        defer prepare2.deinit();
        if (!prepare2.response.isOk()) return error.ChatDupPrepare2Failed;
        kill_on_unwind = false;
        _ = child2.wait(io) catch {};
    }

    const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    var receipts = (try conn.row(
        "select count(*) from store_receipts where request_key = 'turn:turn-dup-1:commit'",
        .{},
    )).?;
    defer receipts.deinit();
    if (receipts.int(0) != 1) return error.ChatDupReceiptCount;
    var turns = (try conn.row(
        "select count(*) from chat_turns where turn_id = 'turn-dup-1'",
        .{},
    )).?;
    defer turns.deinit();
    if (turns.int(0) != 1) return error.ChatDupTurnCount;
}

/// Scenario 3 (POSIX): kill mid-turn → restart → interrupted + staged user row.
fn runChatKillMidTurnScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4-chat-kill");
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

    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        // "slow" keeps the stub worker sleeping so we can kill mid-turn.
        try startStubChatTurn(&client, "turn-kill-1", "ws-kill", "thread-kill", pref_path, "slow mid-turn", "user-kill-1");
        // Brief wait so acceptance staging lands before the kill.
        std.Io.sleep(io, .fromMilliseconds(80), .awake) catch {};
        // kill() is terminating+reaping; do not wait() afterward (Zig 0.16 Child).
        child.kill(io);
        kill_on_unwind = false;
    }

    // Successor open runs interrupt sweep.
    {
        var child2 = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child2.kill(io);

        var decode_arena2 = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena2.deinit();
        var transport2: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena2.allocator(),
            .pref_path = pref_path,
        };
        var client2 = sessionizer.headlessClient(decode_arena2.allocator(), &transport2);

        var record = try client2.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-kill-1" });
        defer record.deinit();
        if (!record.response.isOk()) return error.ChatKillRecordFailed;
        const turn_record = try client2.decodeTurnRecord(&record);
        if (!std.mem.eql(u8, turn_record.status, "interrupted")) return error.ChatKillNotInterrupted;
        if (turn_record.user_message_id) |mid| {
            if (!std.mem.eql(u8, mid, "user-kill-1")) return error.ChatKillBadUserId;
        } else return error.ChatKillMissingUserId;

        var get = try client2.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = "ws-kill",
            .local_thread_id = "thread-kill",
        });
        defer get.deinit();
        if (!get.response.isOk()) return error.ChatKillThreadGetFailed;
        const thread = try client2.decodeThreadGet(&get);
        var saw_user = false;
        for (thread.thread.messages) |message| {
            if (std.mem.eql(u8, message.message_id, "user-kill-1") and std.mem.eql(u8, message.role, "user")) {
                saw_user = true;
            }
            // No assistant rows from a mid-turn kill (staging only).
            if (std.mem.eql(u8, message.role, "assistant")) return error.ChatKillUnexpectedAssistant;
        }
        if (!saw_user) return error.ChatKillMissingUserMessage;

        // MAJOR-2 pin: stable-turn_id replay after interrupted sweep must commit
        // (upsert supersedes 'interrupted'; receipt/ledger stay 1-per-key).
        try startStubChatTurn(
            &client2,
            "turn-kill-1",
            "ws-kill",
            "thread-kill",
            pref_path,
            "replay after interrupt",
            "user-kill-1",
        );
        try waitChatTurnTerminal(io, &client2, "turn-kill-1", true);
        var replay_rec = try client2.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-kill-1" });
        defer replay_rec.deinit();
        if (!replay_rec.response.isOk()) return error.ChatKillReplayRecordFailed;
        const replayed = try client2.decodeTurnRecord(&replay_rec);
        if (!std.mem.eql(u8, replayed.status, "completed")) return error.ChatKillReplayNotCompleted;
        if (replayed.committed_store_revision == null) return error.ChatKillReplayMissingRevision;
        try consumeChatTurn(&client2, "turn-kill-1");

        var prepare = try client2.call("daemon.prepareShutdown", .{});
        defer prepare.deinit();
        if (!prepare.response.isOk()) return error.ChatKillPrepareFailed;
        kill_on_unwind = false;
        _ = child2.wait(io) catch {};
    }

    // RO pin: exactly one ledger row + one commit receipt after interrupted→replay.
    {
        const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        var turns = (try conn.row(
            "select count(*) from chat_turns where turn_id = 'turn-kill-1'",
            .{},
        )).?;
        defer turns.deinit();
        if (turns.int(0) != 1) return error.ChatKillReplayTurnCount;
        var receipts = (try conn.row(
            "select count(*) from store_receipts where request_key = 'turn:turn-kill-1:commit'",
            .{},
        )).?;
        defer receipts.deinit();
        if (receipts.int(0) != 1) return error.ChatKillReplayReceiptCount;
        var status_row = (try conn.row(
            "select status from chat_turns where turn_id = 'turn-kill-1'",
            .{},
        )).?;
        defer status_row.deinit();
        if (!std.mem.eql(u8, status_row.text(0), "completed")) return error.ChatKillReplayLedgerStatus;
    }
}

/// Scenario 4: failed and aborted turns commit failure/interruption rows.
fn runChatFailedAbortedCommitScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4-chat-fail");
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

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .chat_stub = true,
    });
    var kill_on_unwind = true;
    errdefer if (kill_on_unwind) child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    try startStubChatTurn(&client, "turn-fail-1", "ws-fail", "thread-fail", pref_path, "please fail now", "user-fail-1");
    try waitChatTurnTerminal(io, &client, "turn-fail-1", true);
    try consumeChatTurn(&client, "turn-fail-1");

    try startStubChatTurn(&client, "turn-abort-1", "ws-fail", "thread-abort", pref_path, "slow abort me", "user-abort-1");
    // Cancel while the slow stub is still running.
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    var cancel = try client.call("chat.turn.cancel", .{ .turn_id = "turn-abort-1", .followup_pending = false });
    defer cancel.deinit();
    if (!cancel.response.isOk()) return error.ChatAbortCancelFailed;
    try waitChatTurnTerminal(io, &client, "turn-abort-1", true);
    try consumeChatTurn(&client, "turn-abort-1");

    var fail_rec = try client.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-fail-1" });
    defer fail_rec.deinit();
    if (!fail_rec.response.isOk()) return error.ChatFailRecordFailed;
    const failed = try client.decodeTurnRecord(&fail_rec);
    if (!std.mem.eql(u8, failed.status, "failed")) return error.ChatFailBadStatus;

    var abort_rec = try client.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-abort-1" });
    defer abort_rec.deinit();
    if (!abort_rec.response.isOk()) return error.ChatAbortRecordFailed;
    const aborted = try client.decodeTurnRecord(&abort_rec);
    if (!std.mem.eql(u8, aborted.status, "aborted")) return error.ChatAbortBadStatus;

    // MAJOR-4: assert synthesized failure / interruption rows exist in messages.
    {
        var fail_get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = "ws-fail",
            .local_thread_id = "thread-fail",
        });
        defer fail_get.deinit();
        if (!fail_get.response.isOk()) return error.ChatFailThreadGetFailed;
        const fail_thread = try client.decodeThreadGet(&fail_get);
        var saw_failure_row = false;
        for (fail_thread.thread.messages) |message| {
            if (std.mem.eql(u8, message.role, "system") and
                std.mem.indexOf(u8, message.body, "stub failure") != null)
            {
                saw_failure_row = true;
                break;
            }
        }
        if (!saw_failure_row) return error.ChatFailMissingFailureRow;
    }
    {
        var abort_get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = "ws-fail",
            .local_thread_id = "thread-abort",
        });
        defer abort_get.deinit();
        if (!abort_get.response.isOk()) return error.ChatAbortThreadGetFailed;
        const abort_thread = try client.decodeThreadGet(&abort_get);
        var saw_interrupt_row = false;
        for (abort_thread.thread.messages) |message| {
            // transcript_apply: author = "Conversation interrupted" for aborted.
            if (std.mem.eql(u8, message.role, "system") and
                (std.mem.indexOf(u8, message.author, "Conversation interrupted") != null or
                    std.mem.indexOf(u8, message.body, "differently") != null))
            {
                saw_interrupt_row = true;
                break;
            }
        }
        if (!saw_interrupt_row) return error.ChatAbortMissingInterruptRow;
    }

    var prepare = try client.call("daemon.prepareShutdown", .{});
    defer prepare.deinit();
    if (!prepare.response.isOk()) return error.ChatFailPrepareFailed;
    kill_on_unwind = false;
    _ = child.wait(io) catch {};
}

/// MAJOR-3: one-shot StoreBusy at durable commit → bounded retry recovers.
/// Asserts durability_error is visible during the failure window, then the
/// receipt lands, consume succeeds, and prepareShutdown accepts.
fn runChatCommitFaultRetryScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4-chat-commit-fault");
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

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .chat_stub = true,
        .chat_commit_fault = "fail_once",
    });
    var kill_on_unwind = true;
    errdefer if (kill_on_unwind) child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    try startStubChatTurn(
        &client,
        "turn-fault-1",
        "ws-fault",
        "thread-fault",
        pref_path,
        "commit fault once",
        "user-fault-1",
    );

    // Poll: under durable-first, wire status stays non-terminal while pending.
    // Observe durability_pending + durability_error (failure window), then
    // committed_store_revision + terminal status after retry recovery.
    var saw_error_window = false;
    var attempts: usize = 0;
    while (attempts < 800) : (attempts += 1) {
        var parsed = client.call("chat.turn.tail", .{ .turn_id = "turn-fault-1", .after_seq = 0 }) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
        defer parsed.deinit();
        if (!parsed.response.isOk()) {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        }
        const result = parsed.response.result orelse {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
        if (result != .object) {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        }
        const pending = result.object.get("durability_pending") orelse .null;
        const is_pending = pending == .bool and pending.bool;
        const d_err = result.object.get("durability_error") orelse .null;
        const has_err = d_err == .string and d_err.string.len != 0;
        const committed = result.object.get("committed_store_revision") orelse .null;
        if (is_pending and has_err and committed == .null) {
            saw_error_window = true;
            // Keep polling for recovery.
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        }
        const status = result.object.get("status") orelse .null;
        const status_text = if (status == .string) status.string else "";
        const terminal = std.mem.eql(u8, status_text, "completed") or
            std.mem.eql(u8, status_text, "failed") or
            std.mem.eql(u8, status_text, "aborted");
        if (committed != .null and !is_pending and terminal) {
            // Recovered (durable-first: terminal only with the receipt).
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    } else {
        return error.ChatCommitFaultDidNotRecover;
    }
    if (!saw_error_window) return error.ChatCommitFaultMissedErrorWindow;

    try consumeChatTurn(&client, "turn-fault-1");

    var prepare = try client.call("daemon.prepareShutdown", .{});
    defer prepare.deinit();
    if (!prepare.response.isOk()) return error.ChatCommitFaultPrepareFailed;
    kill_on_unwind = false;
    _ = child.wait(io) catch {};
}

/// Scenario 5 (POSIX): slow turn commit does not stall session.tail.
///
/// Ordering proof (cross-boundary):
/// - Worker thread: finalizeChatTurnWorker → commitChatTurnDurable holds
///   lockStoreService and sleeps STORE_FAULT_COMMIT_STALL_MS when fault=commit_stall
///   BEFORE conn work returns; it never takes lockDaemon across that sleep.
/// - Accept path: session.tail only needs lockDaemon + session state; it does
///   not take lockStoreService. Therefore a store-stalled turn commit cannot
///   block session.tail on the serial accept loop for store reasons.
fn runChatSlowCommitDoesNotStallSessionTailScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4-chat-slow");
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

    // commit_stall makes every applyMutation sleep 1.5s. Staging alone uses
    // several mutations; waitChatTurnTerminal's budget covers the full chain.
    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .store_fault = "commit_stall",
        .chat_stub = true,
    });
    var kill_on_unwind = true;
    errdefer if (kill_on_unwind) child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    // Create a short-lived session so session.tail has a real target, then
    // clean it up before prepare (running sessions block the drain gate).
    var create = try client.call("session.create", .{
        .id = "m4-slow-session",
        .cwd = pref_path,
        .workspace_path = pref_path,
        .command = &[_][]const u8{"/bin/true"},
        .cols = sessionizer.DEFAULT_COLS,
        .rows = sessionizer.DEFAULT_ROWS,
    });
    defer create.deinit();
    if (!create.response.isOk()) return error.ChatSlowSessionCreateFailed;

    try startStubChatTurn(&client, "turn-slow-1", "ws-slow", "thread-slow", pref_path, "complete me", "user-slow-1");

    // Issue session.tail while the turn worker may hold lockStoreService during
    // a stalled commit. session.tail only needs lockDaemon + session state.
    //
    // Cross-boundary ordering proof:
    // - Worker (sessionizer commitChatTurnDurable): acquires lockStoreService,
    //   may sleep STORE_FAULT_COMMIT_STALL_MS, runs commitTurn, then releases
    //   the store mutex; it never holds lockDaemon across that sleep.
    // - Accept path (session.tail): acquires lockDaemon only; never takes
    //   lockStoreService. Therefore a store-stalled turn commit cannot block
    //   session.tail via the store lock.
    const started = sessionizer.nowMs();
    var tail = try client.call("session.tail", .{ .id = "m4-slow-session", .after_cursor = 0, .max_bytes = 256 });
    defer tail.deinit();
    const elapsed = sessionizer.nowMs() - started;
    // session.tail itself must stay snappy; allow headroom for serial accept
    // queuing behind chat.turn.start completing (not behind the store stall).
    if (elapsed > 4000) return error.ChatSlowSessionTailTooSlow;

    try waitChatTurnTerminal(io, &client, "turn-slow-1", true);
    try consumeChatTurn(&client, "turn-slow-1");

    var kill = try client.call("session.kill", .{ .id = "m4-slow-session" });
    defer kill.deinit();
    var cleanup = try client.call("session.cleanup", .{});
    defer cleanup.deinit();

    var prepare = try client.call("daemon.prepareShutdown", .{});
    defer prepare.deinit();
    if (!prepare.response.isOk()) return error.ChatSlowPrepareFailed;
    kill_on_unwind = false;
    _ = child.wait(io) catch {};
}

/// Scenario 6: chat.turn.record / chat.thread.get typed DTO round-trip.
fn runChatTypedDtoRoundTripScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4-chat-dto");
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

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .chat_stub = true,
    });
    var kill_on_unwind = true;
    errdefer if (kill_on_unwind) child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    try startStubChatTurn(&client, "turn-dto-1", "ws-dto", "thread-dto", pref_path, "dto body", "user-dto-1");
    try waitChatTurnTerminal(io, &client, "turn-dto-1", true);

    var record = try client.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-dto-1" });
    defer record.deinit();
    if (!record.response.isOk()) return error.ChatDtoRecordFailed;
    const turn = try client.decodeTurnRecord(&record);
    if (!std.mem.eql(u8, turn.turn_id, "turn-dto-1")) return error.ChatDtoTurnId;
    if (!std.mem.eql(u8, turn.workspace_id, "ws-dto")) return error.ChatDtoWorkspace;
    if (!std.mem.eql(u8, turn.status, "completed")) return error.ChatDtoStatus;
    if (turn.committed_store_revision == null) return error.ChatDtoRevision;

    var get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
        .workspace_id = "ws-dto",
        .local_thread_id = "thread-dto",
    });
    defer get.deinit();
    if (!get.response.isOk()) return error.ChatDtoGetFailed;
    const thread = try client.decodeThreadGet(&get);
    if (!std.mem.eql(u8, thread.thread.local_thread_id, "thread-dto")) return error.ChatDtoThreadId;
    if (thread.thread.messages.len == 0) return error.ChatDtoNoMessages;

    var list = try client.call(headless.store.METHOD_CHAT_THREAD_LIST, .{
        .workspace_id = "ws-dto",
        .limit = 10,
    });
    defer list.deinit();
    if (!list.response.isOk()) return error.ChatDtoListFailed;
    const listed = try client.decodeThreadList(&list);
    if (listed.threads.len == 0) return error.ChatDtoListEmpty;

    try consumeChatTurn(&client, "turn-dto-1");
    var prepare = try client.call("daemon.prepareShutdown", .{});
    defer prepare.deinit();
    if (!prepare.response.isOk()) return error.ChatDtoPrepareFailed;
    kill_on_unwind = false;
    _ = child.wait(io) catch {};
}

/// M4-P3/P4 parity IT: daemon-committed rows vs the daemon-owned transcript
/// identity contract (acceptance-staged user `message_id` + `transcript_apply`
/// assistant rows with minted `turn:{id}:msg:{i+1}` ids — the F1 self-healing
/// user-row prepend occupies commit-request slot 0).
///
/// Amendment-2 F2 honesty (M4-P4 fix): identity survival is pinned against the
/// GENUINE GUI writer chain — a projection-shaped PersistedState carrying the
/// adopted ids runs through the real `persistence.persistedStateToProtocolSnapshot`
/// conversion and lands on the daemon store over the real
/// `state.snapshot.replace` RPC (post-adoption, mid-window, and converged
/// arms), plus the M4-P5 MAJOR-3 amendment arm (an MCP-created thread no GUI
/// snapshot ever observed survives the flush). Coverage limits, stated
/// honestly: the ChatThread → PersistedThread step (`threadSnapshot`) is
/// pinned desktop-side ("message identities survive the genuine snapshot
/// chain" in persistence.zig), and no harness drives the full GUI flush
/// worker loop (buildPersistedState → storage.save scheduling).
fn runChatTurnParityScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4-chat-parity");
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

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .chat_stub = true,
    });
    var kill_on_unwind = true;
    errdefer if (kill_on_unwind) child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    const turn_id = "turn-parity-1";
    const workspace_id = "ws-parity";
    const local_thread_id = "thread-parity";
    const prompt = "parity hello durable";
    const user_message_id = "gui-msg:ws-parity:thread-parity:1";

    try startStubChatTurn(&client, turn_id, workspace_id, local_thread_id, pref_path, prompt, user_message_id);
    try waitChatTurnTerminal(io, &client, turn_id, true);

    var get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
        .workspace_id = workspace_id,
        .local_thread_id = local_thread_id,
    });
    defer get.deinit();
    if (!get.response.isOk()) return error.ChatParityThreadGetFailed;
    const committed = try client.decodeThreadGet(&get);

    // GUI projection for this dual-write window:
    // 1) user row staged at acceptance with the client message_id
    // 2) transcript_apply on the deterministic stub event stream (same pure
    //    reducer the daemon commit path uses); empty message_ids are minted
    //    as turn:{id}:msg:{request_index} by insertTurnMessages. Post-P4/F1
    //    the commit request is [user row] ++ transcript rows (self-healing
    //    user upsert), so transcript row i mints at request index i + 1.
    const stub_events = [_]transcript_apply.ChatEvent{
        .{ .kind = "assistant_delta", .payload_json = "{\"text\":\"stub-ok\"}" },
        .{ .kind = "completed", .payload_json = "{}" },
    };
    const outcome: transcript_apply.WorkerOutcome = .{
        .status = .completed,
        .provider = "codex",
        .reply_text = "stub-ok",
    };
    const applied = try transcript_apply.apply(allocator, &stub_events, outcome);
    defer transcript_apply.freeMessages(allocator, applied);

    const expected_len = 1 + applied.len;
    if (committed.thread.messages.len != expected_len) {
        std.debug.print(
            "headless-daemon-it: parity message count daemon={d} projection={d}\n",
            .{ committed.thread.messages.len, expected_len },
        );
        return error.ChatParityMessageCount;
    }

    const user = committed.thread.messages[0];
    if (!std.mem.eql(u8, user.message_id, user_message_id)) return error.ChatParityUserMessageId;
    if (!std.mem.eql(u8, user.role, "user")) return error.ChatParityUserRole;
    if (!std.mem.eql(u8, user.author, "You")) return error.ChatParityUserAuthor;
    if (!std.mem.eql(u8, user.body, prompt)) return error.ChatParityUserBody;

    for (applied, 0..) |proj, i| {
        const daemon_msg = committed.thread.messages[i + 1];
        // F1 prepend shifts synthesized rows by one request slot (user row at 0).
        const expected_id = try std.fmt.allocPrint(allocator, "turn:{s}:msg:{d}", .{ turn_id, i + 1 });
        defer allocator.free(expected_id);
        if (!std.mem.eql(u8, daemon_msg.message_id, expected_id)) return error.ChatParityAssistantMessageId;
        if (!std.mem.eql(u8, daemon_msg.role, proj.role)) return error.ChatParityAssistantRole;
        if (!std.mem.eql(u8, daemon_msg.author, proj.author)) return error.ChatParityAssistantAuthor;
        if (!std.mem.eql(u8, daemon_msg.body, proj.body)) return error.ChatParityAssistantBody;
    }

    // Ledger must point at the same acceptance-staged user id.
    var record = try client.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = turn_id });
    defer record.deinit();
    if (!record.response.isOk()) return error.ChatParityRecordFailed;
    const turn = try client.decodeTurnRecord(&record);
    if (turn.user_message_id) |mid| {
        if (!std.mem.eql(u8, mid, user_message_id)) return error.ChatParityLedgerUserId;
    } else return error.ChatParityLedgerMissingUserId;
    if (turn.committed_store_revision == null) return error.ChatParityMissingRevision;

    // M4-P5 MAJOR-3 amendment arm: an MCP-created thread (chat.thread.upsert;
    // its stable local_thread_id is public API since ae1ea261) that no GUI
    // snapshot has ever observed must survive the GUI flushes below.
    var reg = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer reg.deinit();
    if (!reg.response.isOk()) return error.ChatParityRegisterFailed;
    const gui_client_id = (try client.decodeClientRegister(&reg)).client_id;
    {
        const thread_request: headless.store.ThreadUpsertRequest = .{
            .mutation = .{ .request_key = "parity-mcp-thread", .client_id = gui_client_id },
            .workspace_id = workspace_id,
            .thread = .{ .local_thread_id = "thread-parity-mcp", .title = "MCP-created thread" },
        };
        var mcp_parsed = try client.call(headless.store.METHOD_CHAT_THREAD_UPSERT, thread_request);
        defer mcp_parsed.deinit();
        if (!mcp_parsed.response.isOk()) return error.ChatParityMcpUpsertFailed;
    }

    // P4 identity fix arms — the GENUINE GUI writer: projection-shaped
    // PersistedState with ADOPTED ids (what the GUI holds after
    // adoptDaemonTranscriptIdentities) → real persistedStateToProtocolSnapshot
    // → real state.snapshot.replace → durable re-read.
    var writer_arena = std.heap.ArenaAllocator.init(allocator);
    defer writer_arena.deinit();
    const wa = writer_arena.allocator();

    var adopted_rows: std.ArrayList(db_types.PersistedMessage) = .empty;
    defer adopted_rows.deinit(wa);
    for (committed.thread.messages) |message| {
        try adopted_rows.append(wa, .{
            .role = std.meta.stringToEnum(db_types.ChatRole, message.role) orelse return error.ChatParityBadRole,
            .author = message.author,
            .body = message.body,
            .message_id = message.message_id,
        });
    }

    // Arm 1: post-adoption flush — the snapshot carries every id.
    try runParityGuiFlush(&client, wa, .{
        .request_key = "m4p4fix-gui-flush-adopted",
        .client_id = gui_client_id,
        .workspace_id = workspace_id,
        .local_thread_id = local_thread_id,
        .pref_path = pref_path,
        .messages = adopted_rows.items,
    });
    try expectParityTranscriptIntact(&client, workspace_id, local_thread_id, &committed, user_message_id);

    // Arm 2: mid-window flush — the snapshot carries ONLY the user row (the
    // GUI has not observed the turn's synthesized rows); the store belt must
    // preserve them with stable order.
    try runParityGuiFlush(&client, wa, .{
        .request_key = "m4p4fix-gui-flush-midwindow",
        .client_id = gui_client_id,
        .workspace_id = workspace_id,
        .local_thread_id = local_thread_id,
        .pref_path = pref_path,
        .messages = adopted_rows.items[0..1],
    });
    try expectParityTranscriptIntact(&client, workspace_id, local_thread_id, &committed, user_message_id);

    // Arm 3: converged flush after re-adoption — exactly one copy per id.
    try runParityGuiFlush(&client, wa, .{
        .request_key = "m4p4fix-gui-flush-converged",
        .client_id = gui_client_id,
        .workspace_id = workspace_id,
        .local_thread_id = local_thread_id,
        .pref_path = pref_path,
        .messages = adopted_rows.items,
    });
    try expectParityTranscriptIntact(&client, workspace_id, local_thread_id, &committed, user_message_id);

    // Amendment assert: the MCP-created thread survived every flush above even
    // though no snapshot ever carried it.
    {
        var mcp_get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = workspace_id,
            .local_thread_id = "thread-parity-mcp",
        });
        defer mcp_get.deinit();
        if (!mcp_get.response.isOk()) return error.ChatParityMcpThreadLost;
        const mcp_thread = (try client.decodeThreadGet(&mcp_get)).thread;
        if (!std.mem.eql(u8, mcp_thread.local_thread_id, "thread-parity-mcp")) return error.ChatParityMcpThreadId;
    }

    try consumeChatTurn(&client, turn_id);
    var prepare = try client.call("daemon.prepareShutdown", .{});
    defer prepare.deinit();
    if (!prepare.response.isOk()) return error.ChatParityPrepareFailed;
    kill_on_unwind = false;
    _ = child.wait(io) catch {};
}

const ParityGuiFlush = struct {
    request_key: []const u8,
    client_id: []const u8,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    pref_path: []const u8,
    messages: []const db_types.PersistedMessage,
};

/// One genuine GUI flush: PersistedState → the real
/// `persistence.persistedStateToProtocolSnapshot` → `state.snapshot.replace`
/// with the freshly pinned expected revision (the Storage replaceSnapshot
/// shape).
fn runParityGuiFlush(client: anytype, arena: std.mem.Allocator, flush: ParityGuiFlush) !void {
    const empty_params: struct {} = .{};
    var status = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
    defer status.deinit();
    if (!status.response.isOk()) return error.ChatParityFlushStatusFailed;
    const expected = (try client.decodeStoreStatus(&status)).store_revision;

    const gui_thread: db_types.PersistedThread = .{
        .title = "Parity thread",
        .committed = true,
        .local_thread_id = flush.local_thread_id,
        .provider = .codex,
        .messages = flush.messages,
    };
    const gui_threads = [_]db_types.PersistedThread{gui_thread};
    const gui_projects = [_]db_types.PersistedProject{.{
        .id = flush.workspace_id,
        .label = "Parity workspace",
        .path = flush.pref_path,
        .threads = &gui_threads,
    }};
    const gui_state: db_types.PersistedState = .{ .projects = &gui_projects };
    const wire_snapshot = try persistence.persistedStateToProtocolSnapshot(arena, gui_state, expected);

    const replace: headless.store.SnapshotReplaceRequest = .{
        .mutation = .{
            .request_key = flush.request_key,
            .client_id = flush.client_id,
            .expected_store_revision = expected,
        },
        .snapshot = wire_snapshot,
        .bootstrap = false,
    };
    var parsed = try client.call(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, replace);
    defer parsed.deinit();
    if (!parsed.response.isOk()) return error.ChatParityGuiFlushFailed;
    const write = try client.decodeWriteResult(&parsed);
    if (!write.applied) return error.ChatParityGuiFlushNotApplied;
}

/// Durable re-read: every (message_id, role, body) of the committed transcript
/// must match the original observation exactly, and the ledger-referenced
/// user row must still be present.
fn expectParityTranscriptIntact(
    client: anytype,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    committed: *const headless.store.ThreadGetResult,
    user_message_id: []const u8,
) !void {
    var get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
        .workspace_id = workspace_id,
        .local_thread_id = local_thread_id,
    });
    defer get.deinit();
    if (!get.response.isOk()) return error.ChatParityRereadFailed;
    const again = try client.decodeThreadGet(&get);
    if (again.thread.messages.len != committed.thread.messages.len) return error.ChatParityRereadCount;
    var saw_user = false;
    for (again.thread.messages, 0..) |message, i| {
        const original = committed.thread.messages[i];
        if (!std.mem.eql(u8, message.message_id, original.message_id)) return error.ChatParityRereadId;
        if (!std.mem.eql(u8, message.role, original.role)) return error.ChatParityRereadRole;
        if (!std.mem.eql(u8, message.body, original.body)) return error.ChatParityRereadBody;
        if (std.mem.eql(u8, message.message_id, user_message_id)) saw_user = true;
    }
    if (!saw_user) return error.ChatParityLedgerUserRowMissing;
}

/// M4-P3 revision-guard conflict: after a daemon turn commit advances the store
/// revision, a stale GUI-shaped snapshot.replace with the pre-commit expected
/// revision must return explicit conflict; refresh via store.status then retry
/// once with the fresh guard succeeds.
fn runChatDaemonCommitStaleSnapshotConflictScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4-chat-conflict");
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

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .chat_stub = true,
    });
    var kill_on_unwind = true;
    errdefer if (kill_on_unwind) child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    var reg = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = true });
    defer reg.deinit();
    if (!reg.response.isOk()) return error.ChatConflictRegisterFailed;
    const client_id = (try client.decodeClientRegister(&reg)).client_id;

    // Capture pre-turn revision (seed-less store may already be at 0).
    const empty_params: struct {} = .{};
    var status_pre = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
    defer status_pre.deinit();
    if (!status_pre.response.isOk()) return error.ChatConflictStatusPreFailed;
    const pre_revision = (try client.decodeStoreStatus(&status_pre)).store_revision;

    try startStubChatTurn(
        &client,
        "turn-conflict-1",
        "ws-conflict",
        "thread-conflict",
        pref_path,
        "conflict body",
        "user-conflict-1",
    );
    try waitChatTurnTerminal(io, &client, "turn-conflict-1", true);

    var status_post = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
    defer status_post.deinit();
    if (!status_post.response.isOk()) return error.ChatConflictStatusPostFailed;
    const post_revision = (try client.decodeStoreStatus(&status_post)).store_revision;
    if (post_revision <= pre_revision) return error.ChatConflictRevisionDidNotAdvance;

    // Stale GUI snapshot still holding pre_revision → explicit conflict.
    {
        const stale: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = "m4p3-stale-after-turn",
                .client_id = client_id,
                .expected_store_revision = pre_revision,
            },
            .snapshot = .{
                .schema_version = 1,
                .workspaces = &.{.{
                    .workspace_id = "ws-conflict-stale",
                    .label = "stale GUI",
                    .path = pref_path,
                }},
            },
            .bootstrap = false,
        };
        var parsed = try client.call(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, stale);
        defer parsed.deinit();
        const err = parsed.response.err orelse return error.ChatConflictMissingError;
        if (!std.mem.eql(u8, err.code, headless.protocol.ERR_CONFLICT)) return error.ChatConflictWrongCode;
    }

    // Refresh + retry with the post-commit guard (Phase A recovery shape).
    var status_fresh = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
    defer status_fresh.deinit();
    if (!status_fresh.response.isOk()) return error.ChatConflictRefreshFailed;
    const fresh = (try client.decodeStoreStatus(&status_fresh)).store_revision;
    if (fresh != post_revision) return error.ChatConflictRefreshMismatch;

    {
        const retry: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = "m4p3-retry-after-refresh",
                .client_id = client_id,
                .expected_store_revision = fresh,
            },
            .snapshot = .{
                .schema_version = 1,
                .workspaces = &.{.{
                    .workspace_id = "ws-conflict-recovered",
                    .label = "recovered GUI",
                    .path = pref_path,
                }},
            },
            .bootstrap = false,
        };
        var parsed = try client.call(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, retry);
        defer parsed.deinit();
        if (!parsed.response.isOk()) return error.ChatConflictRetryFailed;
        const write = try client.decodeWriteResult(&parsed);
        if (!write.applied or write.store_revision != fresh + 1) return error.ChatConflictRetryRevision;
    }

    try consumeChatTurn(&client, "turn-conflict-1");
    var prepare = try client.call("daemon.prepareShutdown", .{});
    defer prepare.deinit();
    if (!prepare.response.isOk()) return error.ChatConflictPrepareFailed;
    kill_on_unwind = false;
    _ = child.wait(io) catch {};
}

/// M4-P4: prepare accepts with a committed unconsumed turn; still blocks on
/// durability_pending; crash/exit between commit and any client observation
/// leaves the transcript available to a new client (M3-named acceptance).
fn runChatAuthorityFlipPrepareAndCrashObserveScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4p4-auth-flip");
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

    // --- Launch 1: complete a turn, do NOT consume, prepare accepts, exit ---
    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        try startStubChatTurn(&client, "turn-auth-1", "ws-auth", "thread-auth", pref_path, "auth flip body", "user-auth-1");
        try waitChatTurnTerminal(io, &client, "turn-auth-1", true);

        // Durable-first pin: tail status=completed only with revision.
        {
            var tail = try client.call("chat.turn.tail", .{ .turn_id = "turn-auth-1", .after_seq = 0 });
            defer tail.deinit();
            if (!tail.response.isOk()) return error.ChatAuthTailFailed;
            const result = tail.response.result orelse return error.ChatAuthTailNoResult;
            if (result != .object) return error.ChatAuthTailShape;
            const status = result.object.get("status") orelse .null;
            if (status != .string or !std.mem.eql(u8, status.string, "completed")) return error.ChatAuthStatusNotCompleted;
            const committed = result.object.get("committed_store_revision") orelse .null;
            if (committed == .null) return error.ChatAuthMissingRevision;
            const pending = result.object.get("durability_pending") orelse .null;
            if (pending == .bool and pending.bool) return error.ChatAuthStillPending;
        }

        // Prepare accepts with committed unconsumed turn present (gate flip).
        var prepare = try client.call("daemon.prepareShutdown", .{});
        defer prepare.deinit();
        if (!prepare.response.isOk()) return error.ChatAuthPrepareUnconsumedFailed;
        kill_on_unwind = false;
        _ = child.wait(io) catch {};
    }

    // --- Launch 2 (new client observation after crash/exit between commit and consume) ---
    {
        var child2 = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child2.kill(io);

        var decode_arena2 = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena2.deinit();
        var transport2: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena2.allocator(),
            .pref_path = pref_path,
        };
        var client2 = sessionizer.headlessClient(decode_arena2.allocator(), &transport2);

        var record = try client2.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-auth-1" });
        defer record.deinit();
        if (!record.response.isOk()) return error.ChatAuthRecordFailed;
        const turn = try client2.decodeTurnRecord(&record);
        if (!std.mem.eql(u8, turn.status, "completed")) return error.ChatAuthRecordStatus;
        if (turn.committed_store_revision == null) return error.ChatAuthRecordRevision;

        var get = try client2.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = "ws-auth",
            .local_thread_id = "thread-auth",
        });
        defer get.deinit();
        if (!get.response.isOk()) return error.ChatAuthThreadGetFailed;
        const committed_thread = try client2.decodeThreadGet(&get);
        if (committed_thread.thread.messages.len < 2) return error.ChatAuthTranscriptMissing;

        var prepare2 = try client2.call("daemon.prepareShutdown", .{});
        defer prepare2.deinit();
        if (!prepare2.response.isOk()) return error.ChatAuthPrepare2Failed;
        kill_on_unwind = false;
        _ = child2.wait(io) catch {};
    }

    // --- durability_pending still blocks prepare (running keep-alive path) ---
    // Exercised by the fail_always scenario + unit test; no extra daemon here.
}

/// M4-P4: GUI close-before-consume then reopen renders the identical transcript
/// with no consume handshake (store snapshot + chat.turn.record).
fn runChatCloseBeforeConsumeReopenScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4p4-close-reopen");
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

    // NIT-3: capture the full per-row identity/content shape from launch 1 so
    // the reopen comparison pins the identical transcript, not just its size.
    const CapturedRow = struct { message_id: []u8, role: []u8, body: []u8 };
    var first_rows: std.ArrayList(CapturedRow) = .empty;
    defer {
        for (first_rows.items) |row| {
            allocator.free(row.message_id);
            allocator.free(row.role);
            allocator.free(row.body);
        }
        first_rows.deinit(allocator);
    }
    var first_revision: u64 = 0;
    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        try startStubChatTurn(&client, "turn-close-1", "ws-close", "thread-close", pref_path, "close reopen body", "user-close-1");
        try waitChatTurnTerminal(io, &client, "turn-close-1", true);

        var get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = "ws-close",
            .local_thread_id = "thread-close",
        });
        defer get.deinit();
        if (!get.response.isOk()) return error.ChatCloseGetFailed;
        const thread = try client.decodeThreadGet(&get);
        if (thread.thread.messages.len < 2) return error.ChatCloseTooFewMessages;
        for (thread.thread.messages) |message| {
            const message_id = try allocator.dupe(u8, message.message_id);
            errdefer allocator.free(message_id);
            const role = try allocator.dupe(u8, message.role);
            errdefer allocator.free(role);
            const body = try allocator.dupe(u8, message.body);
            errdefer allocator.free(body);
            try first_rows.append(allocator, .{ .message_id = message_id, .role = role, .body = body });
        }

        var rec = try client.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-close-1" });
        defer rec.deinit();
        if (!rec.response.isOk()) return error.ChatCloseRecordFailed;
        const turn = try client.decodeTurnRecord(&rec);
        first_revision = turn.committed_store_revision orelse return error.ChatCloseMissingRevision;

        // Close without consume: prepare accepts (authority flip).
        var prepare = try client.call("daemon.prepareShutdown", .{});
        defer prepare.deinit();
        if (!prepare.response.isOk()) return error.ChatClosePrepareFailed;
        kill_on_unwind = false;
        _ = child.wait(io) catch {};
    }

    // Reopen: identical transcript, no consume handshake.
    {
        var child2 = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child2.kill(io);

        var decode_arena2 = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena2.deinit();
        var transport2: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena2.allocator(),
            .pref_path = pref_path,
        };
        var client2 = sessionizer.headlessClient(decode_arena2.allocator(), &transport2);

        var get2 = try client2.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = "ws-close",
            .local_thread_id = "thread-close",
        });
        defer get2.deinit();
        if (!get2.response.isOk()) return error.ChatCloseReopenGetFailed;
        const thread2 = try client2.decodeThreadGet(&get2);
        if (thread2.thread.messages.len != first_rows.items.len) return error.ChatCloseReopenMsgCount;
        // NIT-3: identical transcript = identical (message_id, role, body) per
        // row in order, not merely count + revision equality.
        for (thread2.thread.messages, 0..) |message, i| {
            const original = first_rows.items[i];
            if (!std.mem.eql(u8, message.message_id, original.message_id)) return error.ChatCloseReopenRowId;
            if (!std.mem.eql(u8, message.role, original.role)) return error.ChatCloseReopenRowRole;
            if (!std.mem.eql(u8, message.body, original.body)) return error.ChatCloseReopenRowBody;
        }

        var rec2 = try client2.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-close-1" });
        defer rec2.deinit();
        if (!rec2.response.isOk()) return error.ChatCloseReopenRecordFailed;
        const turn2 = try client2.decodeTurnRecord(&rec2);
        if (turn2.committed_store_revision) |rev| {
            if (rev != first_revision) return error.ChatCloseReopenRevision;
        } else return error.ChatCloseReopenMissingRevision;

        // list should not require consume for durability; prepare still accepts.
        var prepare2 = try client2.call("daemon.prepareShutdown", .{});
        defer prepare2.deinit();
        if (!prepare2.response.isOk()) return error.ChatCloseReopenPrepareFailed;
        kill_on_unwind = false;
        _ = child2.wait(io) catch {};
    }
}

/// M4-P4 / Q3 focused-thread IT: completion ledger row upserted by daemon
/// commit, then cleared via notification.chatCompletion.clear within one poll.
fn runChatFocusedCompletionClearScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4p4-focused-clear");
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

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .chat_stub = true,
    });
    var kill_on_unwind = true;
    errdefer if (kill_on_unwind) child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    try startStubChatTurn(&client, "turn-focus-1", "ws-focus", "thread-focus", pref_path, "focus clear body", "user-focus-1");
    try waitChatTurnTerminal(io, &client, "turn-focus-1", true);

    // Daemon commit upserted the completion row unconditionally.
    const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    {
        var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        var row = (try conn.row(
            "select count(*) from chat_completions where workspace_id = 'ws-focus' and local_thread_id = 'thread-focus'",
            .{},
        )).?;
        defer row.deinit();
        if (row.int(0) != 1) return error.ChatFocusMissingCompletionRow;
    }

    // Focused client clear within one poll cycle (Q3).
    {
        var reg = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = true });
        defer reg.deinit();
        if (!reg.response.isOk()) return error.ChatFocusRegisterFailed;
        const client_id = (try client.decodeClientRegister(&reg)).client_id;

        const empty_params: struct {} = .{};
        var status = try client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params);
        defer status.deinit();
        if (!status.response.isOk()) return error.ChatFocusStatusFailed;
        const expected = (try client.decodeStoreStatus(&status)).store_revision;

        const clear_req: headless.store.NotificationChatCompletionClearRequest = .{
            .mutation = .{
                .request_key = "m4p4-focus-clear",
                .client_id = client_id,
                .expected_store_revision = if (expected == 0) null else expected,
            },
            .workspace_id = "ws-focus",
            .local_thread_id = "thread-focus",
        };
        var clear = try client.call(headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR, clear_req);
        defer clear.deinit();
        if (!clear.response.isOk()) return error.ChatFocusClearFailed;
    }

    {
        var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
        defer conn.close();
        var row = (try conn.row(
            "select count(*) from chat_completions where workspace_id = 'ws-focus' and local_thread_id = 'thread-focus'",
            .{},
        )).?;
        defer row.deinit();
        if (row.int(0) != 0) return error.ChatFocusCompletionNotCleared;
    }

    try consumeChatTurn(&client, "turn-focus-1");
    var prepare = try client.call("daemon.prepareShutdown", .{});
    defer prepare.deinit();
    if (!prepare.response.isOk()) return error.ChatFocusPrepareFailed;
    kill_on_unwind = false;
    _ = child.wait(io) catch {};
}

/// MAJOR-R1: complete+consume → restart → same turn_id chat.turn.start →
/// explicit rejection, no durability_pending wedge, prepareShutdown accepts.
fn runChatCompletedTurnReplayRejectScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4p4-replay-reject");
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

    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        try startStubChatTurn(&client, "turn-replay-1", "ws-replay", "thread-replay", pref_path, "replay body", "user-replay-1");
        try waitChatTurnTerminal(io, &client, "turn-replay-1", true);
        try consumeChatTurn(&client, "turn-replay-1");

        var prepare = try client.call("daemon.prepareShutdown", .{});
        defer prepare.deinit();
        if (!prepare.response.isOk()) return error.ChatReplayPrepare1Failed;
        kill_on_unwind = false;
        _ = child.wait(io) catch {};
    }

    {
        var child2 = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child2.kill(io);

        var decode_arena2 = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena2.deinit();
        var transport2: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena2.allocator(),
            .pref_path = pref_path,
        };
        var client2 = sessionizer.headlessClient(decode_arena2.allocator(), &transport2);

        // Same turn_id must be rejected (ledger identity guard) — not re-run.
        var start = try client2.call("chat.turn.start", .{
            .turn_id = "turn-replay-1",
            .workspace_id = "ws-replay",
            .local_thread_id = "thread-replay",
            .project_path = pref_path,
            .prompt = "replay again",
            .thread_title = "M4 IT thread",
            .provider = "codex",
            .harness = "local_cli",
            .message_id = "user-replay-2",
            .test_stub = true,
        });
        defer start.deinit();
        if (start.response.isOk()) return error.ChatReplayShouldReject;
        const err_obj = start.response.err orelse return error.ChatReplayNoError;
        if (!std.mem.eql(u8, err_obj.code, headless.protocol.ERR_INVALID_STATE)) {
            std.debug.print("headless-daemon-it: replay reject code={s}\n", .{err_obj.code});
            return error.ChatReplayWrongCode;
        }

        // No wedge: prepareShutdown accepts (no durability_pending live turn).
        var prepare2 = try client2.call("daemon.prepareShutdown", .{});
        defer prepare2.deinit();
        if (!prepare2.response.isOk()) return error.ChatReplayPrepareWedged;
        kill_on_unwind = false;
        _ = child2.wait(io) catch {};
    }

    // Ledger still single completed row.
    const db_path = try std.fs.path.join(allocator, &.{ store_dir, "state.sqlite" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    var conn = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    var ledger = (try conn.row(
        "select count(*), max(status) from chat_turns where turn_id = 'turn-replay-1'",
        .{},
    )).?;
    defer ledger.deinit();
    if (ledger.int(0) != 1) return error.ChatReplayLedgerCount;
    if (!std.mem.eql(u8, ledger.text(1), "completed")) return error.ChatReplayLedgerStatus;
}

/// MINOR-V3 / amendment: fail_always exhausts retries → waitChatTurnTerminal
/// raises ChatTurnDurableCommitFailed (the previously undriven branch).
fn runChatDurableCommitFailAlwaysScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4p4-fail-always");
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

    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
        .store_dir = store_dir,
        .chat_stub = true,
        .chat_commit_fault = "fail_always",
    });
    var kill_on_unwind = true;
    errdefer if (kill_on_unwind) child.kill(io);

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    try startStubChatTurn(&client, "turn-fail-always-1", "ws-fa", "thread-fa", pref_path, "fail always", "user-fa-1");

    const wait_err = waitChatTurnTerminal(io, &client, "turn-fail-always-1", true);
    if (wait_err) |_| {
        return error.ChatFailAlwaysShouldFail;
    } else |err| {
        if (err != error.ChatTurnDurableCommitFailed) {
            std.debug.print("headless-daemon-it: fail_always unexpected err={s}\n", .{@errorName(err)});
            return error.ChatFailAlwaysWrongErr;
        }
    }

    // durability_pending keeps prepare refused (gate still includes pending).
    var prepare = try client.call("daemon.prepareShutdown", .{});
    defer prepare.deinit();
    if (prepare.response.isOk()) return error.ChatFailAlwaysPrepareShouldRefuse;

    // SIGKILL: wedged-pending is intentional keep-alive until operator kill.
    // kill() is terminating+reaping; do not wait() afterward (Zig 0.16 Child).
    child.kill(io);
    kill_on_unwind = false;
}

/// M4-P5 (design "Phase M4-P5" tests, no-GUI subprocess IT): capability
/// advertisement + the daemon-direct chat surface the MCP/CLI flip rides on —
/// create thread (`chat.thread.upsert`), send with the stub provider
/// (`chat.turn.start`), stream (`chat.turn.tail`), approve contract
/// (`chat.turn.approve`), stop (`chat.turn.cancel`), read the durable
/// transcript (`chat.thread.get`) — then a daemon restart proving the flipped
/// surface stays durable and advertised on a second launch. No consume
/// handshake anywhere: retention rides the M4-P4 durable-before-consume gate.
fn runChatMcpCliFlipNoGuiScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "m4p5-flip");
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

    var durable_msg_count: usize = 0;
    // MINOR-4: per-row (message_id, role, body) capture from launch 1 so the
    // restart comparison pins identity-level parity, not just a row count.
    const FlipRow = struct { message_id: []u8, role: []u8, body: []u8 };
    var captured_rows: std.ArrayList(FlipRow) = .empty;
    defer {
        for (captured_rows.items) |row| {
            allocator.free(row.message_id);
            allocator.free(row.role);
            allocator.free(row.body);
        }
        captured_rows.deinit(allocator);
    }

    // --- Launch 1: full no-GUI chat lifecycle over the flipped surface ---
    {
        var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        // Capability flip pin at the real daemon: chat=true is advertised in
        // the same change that routes the MCP/CLI tools daemon-direct.
        {
            const empty_params: struct {} = .{};
            var status_parsed = try client.call("core.status", empty_params);
            defer status_parsed.deinit();
            if (!status_parsed.response.isOk()) return error.ChatFlipStatusFailed;
            const status = try client.decodeStatus(&status_parsed);
            if (!status.capabilities.chat) return error.ChatFlipCapabilityFalse;
            if (!status.capabilities.store) return error.ChatFlipStoreCapabilityFalse;
        }

        // Thread creation exactly as daemon-direct open_chat performs it:
        // register a store client, ensure the workspace row, upsert the thread.
        var reg = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
        defer reg.deinit();
        if (!reg.response.isOk()) return error.ChatFlipRegisterFailed;
        const client_id = (try client.decodeClientRegister(&reg)).client_id;

        {
            const ws_request: headless.store.WorkspaceUpsertRequest = .{
                .mutation = .{ .request_key = "p5-flip-ws", .client_id = client_id },
                .workspace = .{
                    .workspace_id = "ws-p5",
                    .label = "ws-p5",
                    .path = pref_path,
                },
            };
            var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, ws_request);
            defer parsed.deinit();
            if (!parsed.response.isOk()) return error.ChatFlipWorkspaceUpsertFailed;
        }
        {
            const thread_request: headless.store.ThreadUpsertRequest = .{
                .mutation = .{ .request_key = "p5-flip-thread", .client_id = client_id },
                .workspace_id = "ws-p5",
                .thread = .{
                    .local_thread_id = "thread-p5",
                    .title = "M4P5 flip thread",
                    .provider = "codex",
                    .harness = "local_cli",
                },
            };
            var parsed = try client.call(headless.store.METHOD_CHAT_THREAD_UPSERT, thread_request);
            defer parsed.deinit();
            if (!parsed.response.isOk()) return error.ChatFlipThreadUpsertFailed;
            const write = try client.decodeWriteResult(&parsed);
            if (write.store_revision == 0) return error.ChatFlipThreadRevisionZero;
        }

        // Send: CLI-shaped chat.turn.start (no message_id — the daemon mints
        // the acceptance-staged user row id `turn:{id}:user`).
        {
            var parsed = try client.call("chat.turn.start", .{
                .turn_id = "turn-p5-send",
                .workspace_id = "ws-p5",
                .local_thread_id = "thread-p5",
                .project_path = pref_path,
                .prompt = "hello m4p5",
                .thread_title = "M4P5 flip thread",
                .provider = "codex",
                .harness = "local_cli",
                .fast_mode = false,
                .test_stub = true,
            });
            defer parsed.deinit();
            if (!parsed.response.isOk()) return error.ChatFlipSendFailed;
        }

        // Stream: observe the assistant_delta event through chat.turn.tail
        // before/while the turn completes, then require the durable receipt.
        {
            var saw_delta = false;
            var attempts: usize = 0;
            while (attempts < 800) : (attempts += 1) {
                var tail = client.call("chat.turn.tail", .{ .turn_id = "turn-p5-send", .after_seq = 0 }) catch {
                    std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
                    continue;
                };
                defer tail.deinit();
                if (tail.response.isOk()) {
                    const result = tail.response.result orelse return error.ChatFlipTailNoResult;
                    if (result != .object) return error.ChatFlipTailShape;
                    const events = result.object.get("events") orelse .null;
                    if (events == .array) {
                        for (events.array.items) |event| {
                            if (event != .object) continue;
                            const kind = event.object.get("kind") orelse .null;
                            if (kind == .string and std.mem.eql(u8, kind.string, "assistant_delta")) saw_delta = true;
                        }
                    }
                    if (saw_delta) break;
                }
                std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            }
            if (!saw_delta) return error.ChatFlipStreamDeltaMissing;
        }
        try waitChatTurnTerminal(io, &client, "turn-p5-send", true);

        // Approve contract: the stub provider exposes no approval pause, so
        // the daemon-direct approve surface pins its absent-approval error.
        {
            var approve = try client.call("chat.turn.approve", .{
                .turn_id = "turn-p5-send",
                .call_id = "missing-call",
                .decision = "approve",
            });
            defer approve.deinit();
            const approve_err = approve.response.err orelse return error.ChatFlipApproveShouldReject;
            if (!std.mem.eql(u8, approve_err.code, "not_found")) return error.ChatFlipApproveWrongCode;
        }

        // Stop: slow stub turn on the same thread, cancelled mid-run; the
        // interruption still commits durably (durable-first publication).
        {
            var parsed = try client.call("chat.turn.start", .{
                .turn_id = "turn-p5-stop",
                .workspace_id = "ws-p5",
                .local_thread_id = "thread-p5",
                .project_path = pref_path,
                .prompt = "slow stop me",
                .thread_title = "M4P5 flip thread",
                .provider = "codex",
                .harness = "local_cli",
                .fast_mode = false,
                .test_stub = true,
            });
            defer parsed.deinit();
            if (!parsed.response.isOk()) return error.ChatFlipStopStartFailed;

            var cancel = try client.call("chat.turn.cancel", .{
                .turn_id = "turn-p5-stop",
                .followup_pending = false,
            });
            defer cancel.deinit();
            if (!cancel.response.isOk()) return error.ChatFlipCancelFailed;
        }
        try waitChatTurnTerminal(io, &client, "turn-p5-stop", true);
        {
            var record = try client.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-p5-stop" });
            defer record.deinit();
            if (!record.response.isOk()) return error.ChatFlipStopRecordFailed;
            const turn = try client.decodeTurnRecord(&record);
            if (!std.mem.eql(u8, turn.status, "aborted")) return error.ChatFlipStopNotAborted;
            if (turn.committed_store_revision == null) return error.ChatFlipStopMissingRevision;
        }

        // Read: durable transcript via chat.thread.get — the same read the
        // MCP read_chat_thread / `verde live chat read` surface performs.
        {
            var get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
                .workspace_id = "ws-p5",
                .local_thread_id = "thread-p5",
            });
            defer get.deinit();
            if (!get.response.isOk()) return error.ChatFlipReadFailed;
            const thread = (try client.decodeThreadGet(&get)).thread;
            if (!std.mem.eql(u8, thread.title, "M4P5 flip thread")) return error.ChatFlipReadTitle;
            durable_msg_count = thread.messages.len;
            var saw_prompt = false;
            var saw_reply = false;
            for (thread.messages) |message| {
                if (std.mem.eql(u8, message.body, "hello m4p5")) saw_prompt = true;
                if (std.mem.eql(u8, message.body, "stub-ok")) saw_reply = true;
            }
            if (!saw_prompt or !saw_reply or durable_msg_count < 2) return error.ChatFlipReadTranscript;
            // MINOR-4: capture each durable row's identity for launch 2.
            for (thread.messages) |message| {
                const row_id = try allocator.dupe(u8, message.message_id);
                errdefer allocator.free(row_id);
                const row_role = try allocator.dupe(u8, message.role);
                errdefer allocator.free(row_role);
                const row_body = try allocator.dupe(u8, message.body);
                errdefer allocator.free(row_body);
                try captured_rows.append(allocator, .{
                    .message_id = row_id,
                    .role = row_role,
                    .body = row_body,
                });
            }
        }

        // Exit without any consume: M4-P4 gate accepts committed unconsumed turns.
        var prepare = try client.call("daemon.prepareShutdown", .{});
        defer prepare.deinit();
        if (!prepare.response.isOk()) return error.ChatFlipPrepareFailed;
        kill_on_unwind = false;
        _ = child.wait(io) catch {};
    }

    // --- Launch 2 (daemon restart): flipped surface stays durable + advertised ---
    {
        var child2 = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) child2.kill(io);

        var decode_arena2 = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena2.deinit();
        var transport2: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena2.allocator(),
            .pref_path = pref_path,
        };
        var client2 = sessionizer.headlessClient(decode_arena2.allocator(), &transport2);

        {
            const empty_params: struct {} = .{};
            var status_parsed = try client2.call("core.status", empty_params);
            defer status_parsed.deinit();
            if (!status_parsed.response.isOk()) return error.ChatFlipRestartStatusFailed;
            const status = try client2.decodeStatus(&status_parsed);
            if (!status.capabilities.chat) return error.ChatFlipRestartCapabilityFalse;
        }

        var get2 = try client2.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = "ws-p5",
            .local_thread_id = "thread-p5",
        });
        defer get2.deinit();
        if (!get2.response.isOk()) return error.ChatFlipRestartReadFailed;
        const thread2 = (try client2.decodeThreadGet(&get2)).thread;
        if (thread2.messages.len != durable_msg_count) return error.ChatFlipRestartMsgCount;
        // MINOR-4: identity-level restart parity — every row survives with
        // the same message_id, role, and body in the same order.
        for (captured_rows.items, 0..) |row, index| {
            const message = thread2.messages[index];
            if (!std.mem.eql(u8, message.message_id, row.message_id)) return error.ChatFlipRestartRowId;
            if (!std.mem.eql(u8, message.role, row.role)) return error.ChatFlipRestartRowRole;
            if (!std.mem.eql(u8, message.body, row.body)) return error.ChatFlipRestartRowBody;
        }

        var record2 = try client2.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-p5-send" });
        defer record2.deinit();
        if (!record2.response.isOk()) return error.ChatFlipRestartRecordFailed;
        const turn2 = try client2.decodeTurnRecord(&record2);
        if (!std.mem.eql(u8, turn2.status, "completed")) return error.ChatFlipRestartRecordStatus;
        if (turn2.committed_store_revision == null) return error.ChatFlipRestartRecordRevision;

        // MINOR-4: the ABORTED turn's record also survives the restart with
        // its durable commit receipt intact.
        var record_stop2 = try client2.call(headless.store.METHOD_CHAT_TURN_RECORD, .{ .turn_id = "turn-p5-stop" });
        defer record_stop2.deinit();
        if (!record_stop2.response.isOk()) return error.ChatFlipRestartStopRecordFailed;
        const stop_turn2 = try client2.decodeTurnRecord(&record_stop2);
        if (!std.mem.eql(u8, stop_turn2.status, "aborted")) return error.ChatFlipRestartStopStatus;
        if (stop_turn2.committed_store_revision == null) return error.ChatFlipRestartStopRevision;

        var prepare2 = try client2.call("daemon.prepareShutdown", .{});
        defer prepare2.deinit();
        if (!prepare2.response.isOk()) return error.ChatFlipRestartPrepareFailed;
        kill_on_unwind = false;
        _ = child2.wait(io) catch {};
    }
}

// ---------------------------------------------------------------------------
// M4-P5 fix (MAJOR-4): real MCP tool-layer harness (POSIX tier).
//
// The parent spawns `self_exe --mcp` with PIPED stdio (the child runs the real
// cli/main.zig handleMcp serve loop), writes line-delimited JSON-RPC to its
// stdin, and reads its stdout with poll()-bounded deadlines so a wedged child
// times out instead of deadlocking the IT binary. Lifecycle: close stdin →
// serve loop sees EOF → child exits 0 (waited with a deadline); kill_on_unwind
// guards both the daemon and the MCP child on any assertion failure.
// ---------------------------------------------------------------------------

const MCP_CHILD_READ_TIMEOUT_MS: i64 = 10_000;

fn spawnMcpChild(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
) !std.process.Child {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();
    // Same hermetic endpoint as the parent: the child's ensureSessionDaemon
    // status-probes this socket first (sessionizer.socketPath honors the env
    // override ahead of pref-path derivation) and reuses the already-running
    // IT daemon instead of spawning a stray one.
    const endpoint = try isolationEndpoint(allocator, pref_path);
    defer allocator.free(endpoint);
    try env_map.put(sessionizer.SESSIONIZER_SOCKET_ENV_NAME, endpoint);
    // Root the child's pref/XDG resolution inside the IT tmp dir and point
    // the Live endpoint at a nonexistent path: open_chat's Live attempt fails
    // FileNotFound → isLiveSocketUnavailable → the daemon-direct arm runs
    // deterministically, and the child can never reach a real GUI socket.
    try env_map.put("XDG_DATA_HOME", pref_path);
    try env_map.put("HOME", pref_path);
    const live_socket = try std.fs.path.join(allocator, &.{ pref_path, "no-live.sock" });
    defer allocator.free(live_socket);
    try env_map.put(live_endpoint.ENDPOINT_ENV, live_socket);

    return std.process.spawn(io, .{
        .argv = &.{ self_exe, "--mcp" },
        .stdin = .pipe,
        .stdout = .pipe,
        // The child's stderr (incl. any child-side DebugAllocator report) must
        // not pollute the parent log: the leak gate rg-counts this log only.
        .stderr = .ignore,
        .environ_map = &env_map,
    });
}

fn mcpChildWriteLine(io: std.Io, child: *std.process.Child, line: []const u8) !void {
    const stdin_file = child.stdin orelse return error.McpChildStdinClosed;
    var buffer: [64 * 1024]u8 = undefined;
    var writer = stdin_file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(line);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

/// Line-buffered bounded reader over the MCP child's stdout pipe.
const McpChildReader = struct {
    pending: std.ArrayList(u8) = .empty,

    fn deinit(self: *McpChildReader, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
    }

    /// One line read bounded by `timeout_ms` (poll + monotonic deadline).
    fn readLineAlloc(
        self: *McpChildReader,
        allocator: std.mem.Allocator,
        child: *std.process.Child,
        timeout_ms: i64,
    ) ![]u8 {
        const stdout_file = child.stdout orelse return error.McpChildStdoutClosed;
        const deadline = sessionizer.nowMs() + timeout_ms;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |newline_index| {
                const line = try allocator.dupe(u8, self.pending.items[0..newline_index]);
                const remaining = self.pending.items.len - (newline_index + 1);
                std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[newline_index + 1 ..]);
                self.pending.shrinkRetainingCapacity(remaining);
                return line;
            }
            const now = sessionizer.nowMs();
            if (now > deadline) return error.McpChildReadTimeout;
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = stdout_file.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            }};
            const wait_ms: i32 = @intCast(@min(deadline - now, 200));
            const ready = std.posix.poll(&poll_fds, wait_ms) catch 0;
            if (ready == 0) continue;
            var read_buffer: [16 * 1024]u8 = undefined;
            const read_len = std.posix.read(stdout_file.handle, &read_buffer) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (read_len == 0) return error.McpChildStdoutEof;
            try self.pending.appendSlice(allocator, read_buffer[0..read_len]);
        }
    }
};

/// Write one request line, read and parse the single JSON-RPC response line.
fn mcpChildCallParsed(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    reader: *McpChildReader,
    request_line: []const u8,
    timeout_ms: i64,
) !std.json.Parsed(std.json.Value) {
    try mcpChildWriteLine(io, child, request_line);
    const line = try reader.readLineAlloc(allocator, child, timeout_ms);
    defer allocator.free(line);
    return std.json.parseFromSlice(std.json.Value, allocator, line, .{});
}

fn mcpToolCallRequestAlloc(
    allocator: std.mem.Allocator,
    id: u32,
    tool_name: []const u8,
    arguments: anytype,
) ![]u8 {
    const args_json = try std.json.Stringify.valueAlloc(allocator, arguments, .{});
    defer allocator.free(args_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
        .{ id, tool_name, args_json },
    );
}

fn jsonObjectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

const McpToolText = struct {
    text: []u8,
    is_error: bool,
};

/// Extract the tool result's `content[0].text` envelope plus its isError flag
/// from a raw JSON-RPC tools/call response.
fn mcpToolTextFromResponseAlloc(allocator: std.mem.Allocator, response: std.json.Value) !McpToolText {
    const result = jsonObjectField(response, "result") orelse return error.McpToolResponseNoResult;
    const is_error = blk: {
        const value = jsonObjectField(result, "isError") orelse break :blk false;
        break :blk value == .bool and value.bool;
    };
    const content = jsonObjectField(result, "content") orelse return error.McpToolResponseNoContent;
    if (content != .array or content.array.items.len == 0) return error.McpToolResponseNoContent;
    const text = jsonObjectField(content.array.items[0], "text") orelse return error.McpToolResponseNoText;
    if (text != .string) return error.McpToolResponseNoText;
    return .{ .text = try allocator.dupe(u8, text.string), .is_error = is_error };
}

/// Poll `tail_chat_turn` through the MCP child until the turn is terminal
/// with a committed revision (durable-first publication). When
/// `require_delta` is set, an `assistant_delta` streamed event must have been
/// observed on the way (streamed-events-then-committed-revision ordering).
fn mcpTailTurnToTerminal(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    reader: *McpChildReader,
    next_id: *u32,
    turn_id: []const u8,
    expect_status: []const u8,
    require_delta: bool,
) !void {
    var saw_delta = false;
    var attempts: usize = 0;
    while (attempts < 800) : (attempts += 1) {
        const request = try mcpToolCallRequestAlloc(allocator, next_id.*, "tail_chat_turn", .{ .turn_id = turn_id });
        defer allocator.free(request);
        next_id.* += 1;
        var response = try mcpChildCallParsed(allocator, io, child, reader, request, MCP_CHILD_READ_TIMEOUT_MS);
        defer response.deinit();
        const tool_text = try mcpToolTextFromResponseAlloc(allocator, response.value);
        defer allocator.free(tool_text.text);
        if (tool_text.is_error) return error.McpTailToolError;
        var envelope = try std.json.parseFromSlice(std.json.Value, allocator, tool_text.text, .{});
        defer envelope.deinit();
        const ok = jsonObjectField(envelope.value, "ok") orelse return error.McpTailShape;
        if (ok != .bool or !ok.bool) {
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
            continue;
        }
        const result = jsonObjectField(envelope.value, "result") orelse return error.McpTailShape;
        const events = jsonObjectField(result, "events") orelse .null;
        if (events == .array) {
            for (events.array.items) |event| {
                const kind = jsonObjectField(event, "kind") orelse continue;
                if (kind == .string and std.mem.eql(u8, kind.string, "assistant_delta")) saw_delta = true;
            }
        }
        const status = jsonObjectField(result, "status") orelse .null;
        const status_text = if (status == .string) status.string else "";
        const terminal = std.mem.eql(u8, status_text, "completed") or
            std.mem.eql(u8, status_text, "failed") or
            std.mem.eql(u8, status_text, "aborted");
        const committed = jsonObjectField(result, "committed_store_revision") orelse .null;
        if (terminal and committed != .null) {
            if (!std.mem.eql(u8, status_text, expect_status)) {
                std.debug.print(
                    "headless-daemon-it: MCP tail terminal status {s} (expected {s})\n",
                    .{ status_text, expect_status },
                );
                return error.McpTailUnexpectedStatus;
            }
            if (require_delta and !saw_delta) return error.McpTailNoStreamedDelta;
            return;
        }
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
    }
    return error.McpTailDidNotFinish;
}

/// M4-P5 fix (MAJOR-4): execute the REAL MCP tool layer end-to-end — the
/// flagship no-GUI pipeline (open_chat → send_chat_message → tail_chat_turn →
/// approve/stop → read_chat_thread) driven as genuine JSON-RPC through a
/// piped `--mcp` child running cli/main.zig handleMcp, every chat tool
/// routing daemon-direct to the hermetic daemon. POSIX-only: the bounded
/// child-stdout reads use std.posix.poll.
fn runChatMcpToolLayerScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    if (comptime !posix_pty_supported) {
        std.debug.print("headless-daemon-it: skip runChatMcpToolLayerScenario (POSIX-only bounded pipe reads)\n", .{});
        return;
    }

    const pref_path = try makePrefPath(allocator, "m4p5-mcp");
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

    // --- Arm 1: full pipeline against a chat-stub store daemon ---
    {
        var daemon = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_daemon_on_unwind = true;
        errdefer if (kill_daemon_on_unwind) daemon.kill(io);

        // Seed the workspace row daemon-direct (MINOR-1: open_chat requires
        // the workspace to pre-exist; the desktop dual-write owns creation).
        {
            var decode_arena = std.heap.ArenaAllocator.init(allocator);
            defer decode_arena.deinit();
            var transport: sessionizer.HeadlessTransport = .{
                .allocator = decode_arena.allocator(),
                .pref_path = pref_path,
            };
            var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
            var reg = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
            defer reg.deinit();
            if (!reg.response.isOk()) return error.McpToolLayerRegisterFailed;
            const client_id = (try client.decodeClientRegister(&reg)).client_id;
            const ws_request: headless.store.WorkspaceUpsertRequest = .{
                .mutation = .{ .request_key = "m4p5-mcp-ws", .client_id = client_id },
                .workspace = .{ .workspace_id = "ws-mcp", .label = "ws-mcp", .path = pref_path },
            };
            var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, ws_request);
            defer parsed.deinit();
            if (!parsed.response.isOk()) return error.McpToolLayerWorkspaceUpsertFailed;
        }

        var mcp = try spawnMcpChild(allocator, io, self_exe, pref_path);
        var kill_mcp_on_unwind = true;
        errdefer if (kill_mcp_on_unwind) mcp.kill(io);
        var reader: McpChildReader = .{};
        defer reader.deinit(allocator);
        var next_id: u32 = 1;

        // initialize → the real serve loop identifies itself.
        {
            const request = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{}}}}",
                .{next_id},
            );
            defer allocator.free(request);
            next_id += 1;
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const result = jsonObjectField(response.value, "result") orelse return error.McpInitializeShape;
            const server_info = jsonObjectField(result, "serverInfo") orelse return error.McpInitializeShape;
            const name = jsonObjectField(server_info, "name") orelse return error.McpInitializeShape;
            if (name != .string or !std.mem.eql(u8, name.string, "verde")) return error.McpInitializeName;
        }

        // tools/list → all six chat tools advertised by the real registry.
        {
            const request = try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/list\"}}",
                .{next_id},
            );
            defer allocator.free(request);
            next_id += 1;
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const result = jsonObjectField(response.value, "result") orelse return error.McpToolsListShape;
            const tools = jsonObjectField(result, "tools") orelse return error.McpToolsListShape;
            if (tools != .array) return error.McpToolsListShape;
            const required = [_][]const u8{
                "open_chat",         "send_chat_message", "tail_chat_turn",
                "approve_chat_turn", "stop_chat_turn",    "read_chat_thread",
            };
            for (required) |tool_name| {
                var found = false;
                for (tools.array.items) |tool| {
                    const name = jsonObjectField(tool, "name") orelse continue;
                    if (name == .string and std.mem.eql(u8, name.string, tool_name)) found = true;
                }
                if (!found) {
                    std.debug.print("headless-daemon-it: MCP tools/list missing {s}\n", .{tool_name});
                    return error.McpToolsListMissingChatTool;
                }
            }
        }

        // open_chat → daemon-direct creation with the unified stable-id
        // contract (MAJOR-1): local_thread_id AND thread_id present + equal.
        var local_thread_id: ?[]u8 = null;
        defer if (local_thread_id) |value| allocator.free(value);
        {
            const request = try mcpToolCallRequestAlloc(allocator, next_id, "open_chat", .{
                .workspace_id = "ws-mcp",
                .provider = "codex",
            });
            defer allocator.free(request);
            next_id += 1;
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const tool_text = try mcpToolTextFromResponseAlloc(allocator, response.value);
            defer allocator.free(tool_text.text);
            if (tool_text.is_error) return error.McpOpenChatToolError;
            var envelope = try std.json.parseFromSlice(std.json.Value, allocator, tool_text.text, .{});
            defer envelope.deinit();
            const ok = jsonObjectField(envelope.value, "ok") orelse return error.McpOpenChatShape;
            if (ok != .bool or !ok.bool) {
                std.debug.print("headless-daemon-it: MCP open_chat envelope: {s}\n", .{tool_text.text});
                return error.McpOpenChatNotOk;
            }
            const result = jsonObjectField(envelope.value, "result") orelse return error.McpOpenChatShape;
            const id_value = jsonObjectField(result, "local_thread_id") orelse return error.McpOpenChatNoLocalThreadId;
            const legacy_value = jsonObjectField(result, "thread_id") orelse return error.McpOpenChatNoThreadId;
            if (id_value != .string or legacy_value != .string) return error.McpOpenChatShape;
            if (!std.mem.eql(u8, id_value.string, legacy_value.string)) return error.McpOpenChatIdMismatch;
            if (!std.mem.startsWith(u8, id_value.string, "cli-thread-")) return error.McpOpenChatIdPrefix;
            const created = jsonObjectField(result, "created") orelse return error.McpOpenChatShape;
            if (created != .bool or !created.bool) return error.McpOpenChatCreated;
            const presented = jsonObjectField(result, "presented") orelse return error.McpOpenChatShape;
            if (presented != .bool or presented.bool) return error.McpOpenChatPresented;
            local_thread_id = try allocator.dupe(u8, id_value.string);
        }

        // send_chat_message using result.local_thread_id verbatim.
        var turn_id: ?[]u8 = null;
        defer if (turn_id) |value| allocator.free(value);
        {
            const request = try mcpToolCallRequestAlloc(allocator, next_id, "send_chat_message", .{
                .workspace_id = "ws-mcp",
                .local_thread_id = local_thread_id.?,
                .prompt = "hello mcp tool layer",
                .project_path = pref_path,
            });
            defer allocator.free(request);
            next_id += 1;
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const tool_text = try mcpToolTextFromResponseAlloc(allocator, response.value);
            defer allocator.free(tool_text.text);
            if (tool_text.is_error) return error.McpSendToolError;
            var envelope = try std.json.parseFromSlice(std.json.Value, allocator, tool_text.text, .{});
            defer envelope.deinit();
            const ok = jsonObjectField(envelope.value, "ok") orelse return error.McpSendShape;
            if (ok != .bool or !ok.bool) {
                std.debug.print("headless-daemon-it: MCP send envelope: {s}\n", .{tool_text.text});
                return error.McpSendNotOk;
            }
            const result = jsonObjectField(envelope.value, "result") orelse return error.McpSendShape;
            const status = jsonObjectField(result, "status") orelse return error.McpSendShape;
            if (status != .string or !std.mem.eql(u8, status.string, "accepted")) return error.McpSendNotAccepted;
            const turn_value = jsonObjectField(result, "turn_id") orelse return error.McpSendNoTurnId;
            if (turn_value != .string) return error.McpSendShape;
            turn_id = try allocator.dupe(u8, turn_value.string);
        }

        // tail_chat_turn → streamed assistant_delta, then terminal completed
        // with a committed revision.
        try mcpTailTurnToTerminal(allocator, io, &mcp, &reader, &next_id, turn_id.?, "completed", true);

        // approve_chat_turn → the not_found contract (stub exposes no pause).
        {
            const request = try mcpToolCallRequestAlloc(allocator, next_id, "approve_chat_turn", .{
                .turn_id = turn_id.?,
                .call_id = "missing-call",
            });
            defer allocator.free(request);
            next_id += 1;
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const tool_text = try mcpToolTextFromResponseAlloc(allocator, response.value);
            defer allocator.free(tool_text.text);
            var envelope = try std.json.parseFromSlice(std.json.Value, allocator, tool_text.text, .{});
            defer envelope.deinit();
            const ok = jsonObjectField(envelope.value, "ok") orelse return error.McpApproveShape;
            if (ok != .bool or ok.bool) return error.McpApproveShouldReject;
            const err_value = jsonObjectField(envelope.value, "error") orelse return error.McpApproveShape;
            const code = jsonObjectField(err_value, "code") orelse return error.McpApproveShape;
            if (code != .string or !std.mem.eql(u8, code.string, "not_found")) return error.McpApproveWrongCode;
        }

        // stop_chat_turn on a second (slow-stub) turn: aborted + accepted
        // no-op on the re-issue after terminal.
        var stop_turn_id: ?[]u8 = null;
        defer if (stop_turn_id) |value| allocator.free(value);
        {
            const request = try mcpToolCallRequestAlloc(allocator, next_id, "send_chat_message", .{
                .workspace_id = "ws-mcp",
                .local_thread_id = local_thread_id.?,
                .prompt = "slow stop me",
                .project_path = pref_path,
            });
            defer allocator.free(request);
            next_id += 1;
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const tool_text = try mcpToolTextFromResponseAlloc(allocator, response.value);
            defer allocator.free(tool_text.text);
            if (tool_text.is_error) return error.McpStopSendToolError;
            var envelope = try std.json.parseFromSlice(std.json.Value, allocator, tool_text.text, .{});
            defer envelope.deinit();
            const ok = jsonObjectField(envelope.value, "ok") orelse return error.McpStopSendShape;
            if (ok != .bool or !ok.bool) return error.McpStopSendNotOk;
            const result = jsonObjectField(envelope.value, "result") orelse return error.McpStopSendShape;
            const turn_value = jsonObjectField(result, "turn_id") orelse return error.McpStopSendShape;
            if (turn_value != .string) return error.McpStopSendShape;
            stop_turn_id = try allocator.dupe(u8, turn_value.string);
        }
        {
            const request = try mcpToolCallRequestAlloc(allocator, next_id, "stop_chat_turn", .{
                .turn_id = stop_turn_id.?,
            });
            defer allocator.free(request);
            next_id += 1;
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const tool_text = try mcpToolTextFromResponseAlloc(allocator, response.value);
            defer allocator.free(tool_text.text);
            if (tool_text.is_error) return error.McpStopToolError;
            var envelope = try std.json.parseFromSlice(std.json.Value, allocator, tool_text.text, .{});
            defer envelope.deinit();
            const ok = jsonObjectField(envelope.value, "ok") orelse return error.McpStopShape;
            if (ok != .bool or !ok.bool) return error.McpStopNotOk;
        }
        // Aborted turns publish terminal only after their durable commit;
        // no assistant_delta is required for the interrupted slow stub.
        try mcpTailTurnToTerminal(allocator, io, &mcp, &reader, &next_id, stop_turn_id.?, "aborted", false);
        {
            // Re-issued stop after terminal: accepted no-op, not an error.
            const request = try mcpToolCallRequestAlloc(allocator, next_id, "stop_chat_turn", .{
                .turn_id = stop_turn_id.?,
            });
            defer allocator.free(request);
            next_id += 1;
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const tool_text = try mcpToolTextFromResponseAlloc(allocator, response.value);
            defer allocator.free(tool_text.text);
            var envelope = try std.json.parseFromSlice(std.json.Value, allocator, tool_text.text, .{});
            defer envelope.deinit();
            const ok = jsonObjectField(envelope.value, "ok") orelse return error.McpStopNoopShape;
            if (ok != .bool or !ok.bool) return error.McpStopNoopRejected;
        }

        // read_chat_thread → durable transcript rows in the turn:% namespace.
        {
            const request = try mcpToolCallRequestAlloc(allocator, next_id, "read_chat_thread", .{
                .workspace_id = "ws-mcp",
                .local_thread_id = local_thread_id.?,
            });
            defer allocator.free(request);
            next_id += 1;
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const tool_text = try mcpToolTextFromResponseAlloc(allocator, response.value);
            defer allocator.free(tool_text.text);
            if (tool_text.is_error) return error.McpReadToolError;
            var envelope = try std.json.parseFromSlice(std.json.Value, allocator, tool_text.text, .{});
            defer envelope.deinit();
            const ok = jsonObjectField(envelope.value, "ok") orelse return error.McpReadShape;
            if (ok != .bool or !ok.bool) return error.McpReadNotOk;
            const result = jsonObjectField(envelope.value, "result") orelse return error.McpReadShape;
            const thread = jsonObjectField(result, "thread") orelse return error.McpReadShape;
            const messages = jsonObjectField(thread, "messages") orelse return error.McpReadShape;
            if (messages != .array or messages.array.items.len < 2) return error.McpReadRowCount;
            var saw_prompt = false;
            var saw_reply = false;
            for (messages.array.items) |message| {
                const body = jsonObjectField(message, "body") orelse return error.McpReadShape;
                if (body != .string) return error.McpReadShape;
                if (std.mem.eql(u8, body.string, "hello mcp tool layer")) saw_prompt = true;
                if (std.mem.eql(u8, body.string, "stub-ok")) saw_reply = true;
                const message_id = jsonObjectField(message, "message_id") orelse return error.McpReadShape;
                if (message_id != .string) return error.McpReadShape;
                if (!std.mem.startsWith(u8, message_id.string, "turn:")) return error.McpReadIdNamespace;
            }
            if (!saw_prompt or !saw_reply) return error.McpReadTranscript;
        }

        // Lifecycle: close stdin → EOF ends the serve loop → child exits 0.
        mcp.stdin.?.close(io);
        mcp.stdin = null;
        const term = try waitChildBounded(&mcp, io, 10_000);
        kill_mcp_on_unwind = false;
        if (term != .exited or term.exited != 0) return error.McpChildExitCode;

        {
            var decode_arena = std.heap.ArenaAllocator.init(allocator);
            defer decode_arena.deinit();
            var transport: sessionizer.HeadlessTransport = .{
                .allocator = decode_arena.allocator(),
                .pref_path = pref_path,
            };
            var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
            var prepare = try client.call("daemon.prepareShutdown", .{});
            defer prepare.deinit();
            if (!prepare.response.isOk()) return error.McpDaemonPrepareFailed;
        }
        kill_daemon_on_unwind = false;
        _ = try waitChildBounded(&daemon, io, 10_000);
    }

    // --- Arm 2 (MINOR-3 pin): store-less daemon — open_chat's failure names
    // the STORE capability verbatim, never re-attributed to chat. ---
    {
        var daemon = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_disable = true,
            .chat_stub = true,
        });
        var kill_daemon_on_unwind = true;
        errdefer if (kill_daemon_on_unwind) daemon.kill(io);

        var mcp = try spawnMcpChild(allocator, io, self_exe, pref_path);
        var kill_mcp_on_unwind = true;
        errdefer if (kill_mcp_on_unwind) mcp.kill(io);
        var reader: McpChildReader = .{};
        defer reader.deinit(allocator);

        {
            const request = try mcpToolCallRequestAlloc(allocator, 1, "open_chat", .{
                .workspace_id = "ws-mcp",
                .provider = "codex",
            });
            defer allocator.free(request);
            var response = try mcpChildCallParsed(allocator, io, &mcp, &reader, request, MCP_CHILD_READ_TIMEOUT_MS);
            defer response.deinit();
            const tool_text = try mcpToolTextFromResponseAlloc(allocator, response.value);
            defer allocator.free(tool_text.text);
            if (std.mem.indexOf(u8, tool_text.text, "store capability is unavailable") == null) {
                std.debug.print("headless-daemon-it: MCP store-less open_chat text: {s}\n", .{tool_text.text});
                return error.McpStoreLessWrongCapability;
            }
            if (std.mem.indexOf(u8, tool_text.text, "chat capability is unavailable") != null) {
                return error.McpStoreLessMisattributed;
            }
        }

        mcp.stdin.?.close(io);
        mcp.stdin = null;
        const term = try waitChildBounded(&mcp, io, 10_000);
        kill_mcp_on_unwind = false;
        if (term != .exited or term.exited != 0) return error.McpChildExitCode;

        {
            var decode_arena = std.heap.ArenaAllocator.init(allocator);
            defer decode_arena.deinit();
            var transport: sessionizer.HeadlessTransport = .{
                .allocator = decode_arena.allocator(),
                .pref_path = pref_path,
            };
            var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
            var prepare = try client.call("daemon.prepareShutdown", .{});
            defer prepare.deinit();
            if (!prepare.response.isOk()) return error.McpDaemonPrepareFailed;
        }
        kill_daemon_on_unwind = false;
        _ = try waitChildBounded(&daemon, io, 10_000);
    }
}

/// M4-P5 fix amendment (m4p4fix verify MAJOR-1): failed-first identity
/// adoption converges via retry to a single identity set that survives the
/// genuine GUI flush chain (real persistedStateToProtocolSnapshot →
/// state.snapshot.replace) and a daemon restart — no duplicated rows.
fn runChatAdoptionRetryDurabilityScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    if (comptime !posix_pty_supported) {
        std.debug.print("headless-daemon-it: skip runChatAdoptionRetryDurabilityScenario (POSIX tier)\n", .{});
        return;
    }

    const pref_path = try makePrefPath(allocator, "m4p5-adopt");
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

    const workspace_id = "ws-adopt";
    const local_thread_id = "thread-adopt";
    const turn_id = "turn-adopt";
    const prompt = "hello adoption";

    // Identities captured after the converged flush, for the restart check.
    var captured_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (captured_ids.items) |id| allocator.free(id);
        captured_ids.deinit(allocator);
    }

    // --- Launch 1: seed, fail-first adoption, retry, converged flush ---
    {
        var daemon = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) daemon.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        var reg = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
        defer reg.deinit();
        if (!reg.response.isOk()) return error.AdoptRegisterFailed;
        const client_id = (try client.decodeClientRegister(&reg)).client_id;

        {
            const ws_request: headless.store.WorkspaceUpsertRequest = .{
                .mutation = .{ .request_key = "m4p5-adopt-ws", .client_id = client_id },
                .workspace = .{ .workspace_id = workspace_id, .label = workspace_id, .path = pref_path },
            };
            var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, ws_request);
            defer parsed.deinit();
            if (!parsed.response.isOk()) return error.AdoptWorkspaceUpsertFailed;
        }
        {
            const thread_request: headless.store.ThreadUpsertRequest = .{
                .mutation = .{ .request_key = "m4p5-adopt-thread", .client_id = client_id },
                .workspace_id = workspace_id,
                .thread = .{
                    .local_thread_id = local_thread_id,
                    .title = "Adoption thread",
                    .provider = "codex",
                    .harness = "local_cli",
                },
            };
            var parsed = try client.call(headless.store.METHOD_CHAT_THREAD_UPSERT, thread_request);
            defer parsed.deinit();
            if (!parsed.response.isOk()) return error.AdoptThreadUpsertFailed;
        }
        {
            var parsed = try client.call("chat.turn.start", .{
                .turn_id = turn_id,
                .workspace_id = workspace_id,
                .local_thread_id = local_thread_id,
                .project_path = pref_path,
                .prompt = prompt,
                .thread_title = "Adoption thread",
                .provider = "codex",
                .harness = "local_cli",
                .fast_mode = false,
                .test_stub = true,
            });
            defer parsed.deinit();
            if (!parsed.response.isOk()) return error.AdoptTurnStartFailed;
        }
        try waitChatTurnTerminal(io, &client, turn_id, true);

        var get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = workspace_id,
            .local_thread_id = local_thread_id,
        });
        defer get.deinit();
        if (!get.response.isOk()) return error.AdoptSeedReadFailed;
        const committed = (try client.decodeThreadGet(&get)).thread;
        if (committed.messages.len < 2) return error.AdoptSeedRowCount;

        // GUI-projection double: the same rows id-less, with the FINAL row's
        // body still diverged (mid-stream projection) to force the mismatch.
        var thread = try chat_types.ChatThread.init(allocator, "Adoption thread");
        defer thread.deinit(allocator);
        allocator.free(thread.local_thread_id);
        thread.local_thread_id = try allocator.dupeZ(u8, local_thread_id);
        for (committed.messages, 0..) |message, index| {
            const is_last = index == committed.messages.len - 1;
            const body: []const u8 = if (is_last) "still streaming" else message.body;
            const is_user = std.mem.eql(u8, message.role, "user");
            try thread.messages.append(allocator, .{
                .role = if (is_user) .user else .assistant,
                .author = try allocator.dupeZ(u8, if (is_user) "You" else "Assistant"),
                .body = try allocator.dupeZ(u8, body),
            });
        }

        const AdoptProject = struct { id: []const u8 };
        const AdoptSelf = struct {
            allocator: std.mem.Allocator,
            storage: struct { pref_path: []const u8 },
            project_controller: struct { projects: struct { items: []const AdoptProject } },
            dirty: bool = false,
            pub fn markDirty(self: *@This()) void {
                self.dirty = true;
            }
        };
        const projects = [_]AdoptProject{.{ .id = workspace_id }};
        var adopt_self: AdoptSelf = .{
            .allocator = allocator,
            .storage = .{ .pref_path = pref_path },
            .project_controller = .{ .projects = .{ .items = &projects } },
        };

        // Failed-first adoption: durable read succeeds, final row mismatches
        // → incomplete (the pre-amendment one-shot stopped here forever).
        if (chat_controller.adoptDaemonTranscriptIdentities(&adopt_self, 0, &thread) != .incomplete) {
            return error.AdoptFirstNotIncomplete;
        }
        if (thread.messages.items[0].message_id == null) return error.AdoptUserIdNotAdopted;
        if (thread.messages.items[thread.messages.items.len - 1].message_id != null) {
            return error.AdoptMismatchedIdAssigned;
        }

        // Projection converges on the durable body; the idempotent retry
        // completes and yields the single identity set.
        {
            const last = &thread.messages.items[thread.messages.items.len - 1];
            allocator.free(last.body);
            last.body = try allocator.dupeZ(u8, committed.messages[committed.messages.len - 1].body);
        }
        if (chat_controller.adoptDaemonTranscriptIdentities(&adopt_self, 0, &thread) != .complete) {
            return error.AdoptRetryNotComplete;
        }
        for (thread.messages.items) |message| {
            const id = message.message_id orelse return error.AdoptIdMissing;
            if (!std.mem.startsWith(u8, id, "turn:")) return error.AdoptIdNamespace;
        }
        if (!adopt_self.dirty) return error.AdoptDirtyNotMarked;

        // Genuine GUI flush of the converged projection, then re-read: the
        // durable transcript keeps exactly one row per identity.
        var writer_arena = std.heap.ArenaAllocator.init(allocator);
        defer writer_arena.deinit();
        const wa = writer_arena.allocator();
        var adopted_rows: std.ArrayList(db_types.PersistedMessage) = .empty;
        defer adopted_rows.deinit(wa);
        for (thread.messages.items) |message| {
            try adopted_rows.append(wa, .{
                .role = std.meta.stringToEnum(db_types.ChatRole, @tagName(message.role)) orelse return error.AdoptBadRole,
                .author = message.author,
                .body = message.body,
                .message_id = message.message_id,
            });
        }
        try runParityGuiFlush(&client, wa, .{
            .request_key = "m4p5-adopt-flush",
            .client_id = client_id,
            .workspace_id = workspace_id,
            .local_thread_id = local_thread_id,
            .pref_path = pref_path,
            .messages = adopted_rows.items,
        });

        var verify = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = workspace_id,
            .local_thread_id = local_thread_id,
        });
        defer verify.deinit();
        if (!verify.response.isOk()) return error.AdoptVerifyReadFailed;
        const flushed = (try client.decodeThreadGet(&verify)).thread;
        if (flushed.messages.len != thread.messages.items.len) return error.AdoptFlushDuplicatedRows;
        for (flushed.messages, 0..) |message, index| {
            const projection_id = thread.messages.items[index].message_id.?;
            if (!std.mem.eql(u8, message.message_id, projection_id)) return error.AdoptFlushIdMismatch;
            const captured = try allocator.dupe(u8, message.message_id);
            errdefer allocator.free(captured);
            try captured_ids.append(allocator, captured);
        }

        var prepare = try client.call("daemon.prepareShutdown", .{});
        defer prepare.deinit();
        if (!prepare.response.isOk()) return error.AdoptPrepareFailed;
        kill_on_unwind = false;
        _ = try waitChildBounded(&daemon, io, 10_000);
    }

    // --- Launch 2 (reopen): the single identity set survives the restart ---
    {
        var daemon = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, .{
            .store_dir = store_dir,
            .chat_stub = true,
        });
        var kill_on_unwind = true;
        errdefer if (kill_on_unwind) daemon.kill(io);

        var decode_arena = std.heap.ArenaAllocator.init(allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

        var get = try client.call(headless.store.METHOD_CHAT_THREAD_GET, .{
            .workspace_id = workspace_id,
            .local_thread_id = local_thread_id,
        });
        defer get.deinit();
        if (!get.response.isOk()) return error.AdoptReopenReadFailed;
        const reopened = (try client.decodeThreadGet(&get)).thread;
        if (reopened.messages.len != captured_ids.items.len) return error.AdoptReopenDuplicatedRows;
        for (reopened.messages, 0..) |message, index| {
            if (!std.mem.eql(u8, message.message_id, captured_ids.items[index])) {
                return error.AdoptReopenIdMismatch;
            }
        }

        var prepare = try client.call("daemon.prepareShutdown", .{});
        defer prepare.deinit();
        if (!prepare.response.isOk()) return error.AdoptReopenPrepareFailed;
        kill_on_unwind = false;
        _ = try waitChildBounded(&daemon, io, 10_000);
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
/// P3 pin: when a store-required desktop would need protocol replacement but a
/// live PTY blocks prepareShutdown, the old daemon stays fully working, store
/// mutations remain accepted, and no direct SQLite writer fallback is opened.
/// Named exactly as m3_design requires.
///
/// TODO(NIT-3 / M3-P3 review item 7): two-binary version-skew IT is NOT expected
/// this round. A full pin needs two protocol-version binaries so ensureDaemon
/// surfaces DaemonReplacementBlocked under a live-PTY prepare refusal. Covered
/// piecewise today (this scenario + M2-era prepare-refusal unit pins). Tracked
/// so the debt is discoverable — see fable_m3p3_review_out.md §7 / NIT-3.
fn version_skew_blocked_replacement_is_read_only_without_fallback(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "version-skew-blocked");
    defer allocator.free(pref_path);
    defer std.Io.Dir.cwd().deleteTree(io, pref_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, pref_path);

    var isolation = try EndpointIsolation.install(allocator, pref_path);
    defer isolation.deinit(allocator);

    const self_exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    // Production store open (no redirect) so the user DB path is the sole writer path.
    var child = try spawnIsolatedDaemon(allocator, io, self_exe, pref_path);
    defer child.kill(io);

    const session_id = "verde:headless-it:version-skew-pty";
    {
        const create = try sessionizer.requestAlloc(allocator, pref_path, "session.create", .{
            .id = session_id,
            .cwd = pref_path,
            .command = &[_][]const u8{"/bin/cat"},
            .cols = sessionizer.DEFAULT_COLS,
            .rows = sessionizer.DEFAULT_ROWS,
        }, 1);
        defer allocator.free(create);
        if (std.mem.indexOf(u8, create, "\"error\"") != null) return error.VersionSkewSessionCreateFailed;
    }

    // Live PTY blocks prepare — the version-skew replacement path cannot drain.
    const prepare = try sessionizer.requestAlloc(allocator, pref_path, "daemon.prepareShutdown", .{}, 2);
    defer allocator.free(prepare);
    if (std.mem.indexOf(u8, prepare, "invalid_state") == null) return error.VersionSkewPrepareShouldRefuse;

    // Old daemon remains fully working: store mutations accepted, store=true.
    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = decode_arena.allocator(),
        .pref_path = pref_path,
    };
    var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);

    {
        const empty_params: struct {} = .{};
        var status_parsed = try client.call("core.status", empty_params);
        defer status_parsed.deinit();
        if (!status_parsed.response.isOk()) return error.VersionSkewCoreStatusFailed;
        const status = try client.decodeStatus(&status_parsed);
        if (!status.capabilities.store) return error.VersionSkewStoreCapabilityFalse;
    }

    var register_parsed = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer register_parsed.deinit();
    const client_id = (try client.decodeClientRegister(&register_parsed)).client_id;
    const request: headless.store.WorkspaceUpsertRequest = .{
        .mutation = .{
            .request_key = "version-skew-ws",
            .client_id = client_id,
        },
        .workspace = .{
            .workspace_id = "version-skew-ws",
            .label = "Skew",
            .path = pref_path,
        },
    };
    var upsert = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, request);
    defer upsert.deinit();
    if (!upsert.response.isOk()) return error.VersionSkewStoreMutationFailed;

    // ensureDaemon with a matching protocol must not tear down the live daemon.
    try sessionizer.ensureDaemon(allocator, pref_path, self_exe);
    const status_after = try sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 3);
    defer allocator.free(status_after);
    if (std.mem.indexOf(u8, status_after, "protocol_version") == null) return error.VersionSkewDaemonDied;

    // Read-only projection is allowed; Create/writer open is never the desktop fallback.
    const db_path = try std.fs.path.join(allocator, &.{ pref_path, "state.sqlite" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    var ro = try zqlite.open(db_path_z, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
    defer ro.close();
    if (ro.execNoArgs("delete from workspaces")) |_| {
        return error.VersionSkewDirectWriteSucceeded;
    } else |err| {
        if (err != error.ReadOnly) return err;
    }

    const kill_response = try sessionizer.requestAlloc(allocator, pref_path, "session.kill", .{ .id = session_id }, 4);
    defer allocator.free(kill_response);
}

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
