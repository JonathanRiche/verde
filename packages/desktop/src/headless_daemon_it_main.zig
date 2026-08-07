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

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Safety-net idle for every IT daemon so a crashed run cannot leave a
/// permanent daemon+socket when persistent-by-default is enabled.
const IT_SAFETY_IDLE_EXIT_MS = "30000";

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
                    if (comptime builtin.os.tag != .windows) {
                        parent_pid = std.fmt.parseInt(std.posix.pid_t, raw, 10) catch {
                            std.debug.print("headless-daemon-it: invalid --parent-pid\n", .{});
                            std.process.exit(2);
                        };
                    }
                }
            }
            installItDaemonCleanupGuards(parent_pid, pref_path);
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
    try runRegistryFixtureScenario(allocator, io);
    try runStoreFixtureScenario(allocator, io);
    try runLifecycleBindGuard(allocator, io);
    try runLifecyclePrepareShutdownWithLivePty(allocator, io);
    try runLifecycleGracefulReplace(allocator, io);
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

/// Install `VERDE_SESSIONIZER_SOCKET` for both this process and the child so
/// neither can fall through to the user's live daemon endpoint.
const EndpointIsolation = struct {
    endpoint: []u8,
    /// Owned copy of the previous env value (if any); restored on deinit.
    prev_socket: ?[]u8,

    fn install(allocator: std.mem.Allocator, pref_path: []const u8) !EndpointIsolation {
        // Pref-derived path (ignores any ambient override) so isolation is absolute.
        const endpoint = try sessionizer.defaultSocketPath(allocator, pref_path);
        errdefer allocator.free(endpoint);
        const prev_owned: ?[]u8 = if (std.c.getenv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME)) |p|
            try allocator.dupe(u8, std.mem.span(p))
        else
            null;
        errdefer if (prev_owned) |v| allocator.free(v);

        const endpoint_z = try allocator.dupeZ(u8, endpoint);
        defer allocator.free(endpoint_z);
        if (setenv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME, endpoint_z.ptr, 1) != 0) {
            return error.SetEnvFailed;
        }
        return .{
            .endpoint = endpoint,
            .prev_socket = prev_owned,
        };
    }

    fn deinit(self: *EndpointIsolation, allocator: std.mem.Allocator) void {
        if (self.prev_socket) |value| {
            const value_z = allocator.dupeZ(u8, value) catch {
                _ = unsetenv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME);
                allocator.free(value);
                allocator.free(self.endpoint);
                self.* = undefined;
                return;
            };
            defer allocator.free(value_z);
            _ = setenv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME, value_z.ptr, 1);
            allocator.free(value);
        } else {
            _ = unsetenv(sessionizer.SESSIONIZER_SOCKET_ENV_NAME);
        }
        allocator.free(self.endpoint);
        self.* = undefined;
    }
};

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

    // Always set a safety-net idle so a crashed IT cannot leak a permanent daemon.
    // Per-test tighter overrides still win when provided.
    try env_map.put("VERDE_SESSION_DAEMON_IDLE_EXIT_MS", idle_exit_ms orelse IT_SAFETY_IDLE_EXIT_MS);

    // Bind the child to the same isolated endpoint the parent uses.
    const endpoint = try sessionizer.defaultSocketPath(allocator, pref_path);
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
fn installItDaemonCleanupGuards(parent_pid: ?std.posix.pid_t, pref_path: []const u8) void {
    if (comptime builtin.os.tag != .windows) {
        if (parent_pid) |pid| {
            const thread = std.Thread.spawn(.{}, parentDeathWatchThread, .{ pid, pref_path }) catch return;
            thread.detach();
        }
    }
}

fn parentDeathWatchThread(parent_pid: std.posix.pid_t, pref_path: []const u8) void {
    if (comptime builtin.os.tag == .windows) return;
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

/// Wait for a child to exit with a deadline; kill on timeout so a regression
/// fails instead of hanging the IT binary forever.
fn waitChildBounded(child: *std.process.Child, io: std.Io, timeout_ms: u64) !std.process.Child.Term {
    const pid = child.id orelse return error.ChildAlreadyWaited;
    const deadline = sessionizer.nowMs() + @as(i64, @intCast(timeout_ms));
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

/// The existing sessionizer uses this compatibility code for methods that have
/// not reached its dispatcher yet.  `capability_unavailable` is the typed
/// headless error used by optional surfaces; both are valid interim responses
/// while the phase-2 daemon hooks remain unimplemented.
const FIXTURE_METHOD_NOT_FOUND: []const u8 = "method_not_found";

const FixtureSurface = enum {
    registry,
    store,
};

/// Shared phase-1 scenario plumbing. Typed DTOs are passed to Client.call so
/// the normal headless protocol encoder owns the request envelope and JSON.
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

    /// Assert the tolerant phase-1 response contract for a not-yet-dispatched
    /// method. Optional error data is intentionally accepted by parseResponse.
    fn expectInterimError(_: *@This(), surface: FixtureSurface, parsed: *const headless.protocol.ParsedResponse) !void {
        if (parsed.response.isOk()) return switch (surface) {
            .registry => error.RegistryFixtureMethodUnexpectedlySucceeded,
            .store => error.StoreFixtureMethodUnexpectedlySucceeded,
        };

        const err = parsed.response.err orelse return switch (surface) {
            .registry => error.RegistryFixtureMissingError,
            .store => error.StoreFixtureMissingError,
        };
        const method_not_found = std.mem.eql(u8, err.code, FIXTURE_METHOD_NOT_FOUND);
        const capability_unavailable = std.mem.eql(u8, err.code, headless.protocol.ERR_CAPABILITY_UNAVAILABLE);
        if (!method_not_found and !capability_unavailable) return switch (surface) {
            .registry => error.RegistryFixtureUnexpectedErrorCode,
            .store => error.StoreFixtureUnexpectedErrorCode,
        };
        if (err.message.len == 0) return switch (surface) {
            .registry => error.RegistryFixtureMissingErrorMessage,
            .store => error.StoreFixtureMissingErrorMessage,
        };
    }
};

/// Phase-1 registry fixture: exercise a typed process-list request against the
/// daemon and pin its current unimplemented response shape for phase 2.
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
    try scenario.expectInterimError(.registry, &parsed);
}

/// Phase-1 store fixture: exercise a typed workspace-upsert request against
/// the daemon and pin its current unimplemented response shape for phase 2.
fn runStoreFixtureScenario(allocator: std.mem.Allocator, io: std.Io) !void {
    const pref_path = try makePrefPath(allocator, "store-hooks");
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
        .request_key = "w7-store-fixture-workspace-upsert",
        .client_id = "w7-fixture-client",
    };
    const request: headless.store.WorkspaceUpsertRequest = .{
        .mutation = mutation,
        .workspace = .{
            .workspace_id = "w7-fixture-workspace",
            .label = "W7 fixture workspace",
            .path = pref_path,
        },
    };
    var parsed = try scenario.storeStep(headless.store.METHOD_WORKSPACE_UPSERT, request);
    defer parsed.deinit();
    try scenario.expectInterimError(.store, &parsed);
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
    // Refused prepare must leave the daemon accepting mutations.
    if (std.mem.indexOf(u8, prepare, "\"accepting_mutations\":true") == null and
        std.mem.indexOf(u8, prepare, "\"accepting_mutations\": true") == null)
    {
        const status_after = try sessionizer.requestAlloc(allocator, pref_path, "status", .{}, 6);
        defer allocator.free(status_after);
        if (std.mem.indexOf(u8, status_after, "\"accepting_mutations\":false") != null or
            std.mem.indexOf(u8, status_after, "\"accepting_mutations\": false") != null)
        {
            return error.AcceptingMutationsClearedOnRefusedPrepare;
        }
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
    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, "500");
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
