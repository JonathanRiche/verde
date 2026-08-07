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

/// The Unix accept loop invokes each client callback synchronously
/// (packages/desktop/src/platform/ipc.zig:115-121), so this scenario's second
/// connection cannot reach the fast path during Phase B until M5-P3 lands
/// concurrent transport. Set true when M5-P3 lands concurrent transport.
const CONCURRENT_TRANSPORT_LANDED = false;

// Force semantic analysis while the compile-time gate is false so the M5-P3
// timing scenario cannot type-rot before concurrent transport lands.
comptime {
    _ = &runSlowConfigDoesNotBlockTailScenario;
    _ = &slowStartThread;
    _ = &spawnIsolatedDaemonWithSlowIo;
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
    try runRegistryCapabilityScenario(allocator, io);
    try runProcessLifecycleScenario(allocator, io);
    try runManagedProcessScenario(allocator, io);
    if (CONCURRENT_TRANSPORT_LANDED) {
        try runSlowConfigDoesNotBlockTailScenario(allocator, io);
    } else {
        std.debug.print("headless-daemon-it: skip runSlowConfigDoesNotBlockTailScenario (requires concurrent transport; enable when M5-P3 lands)\n", .{});
    }
    try runRegistryMethodPresenceScenario(allocator, io);
    try runLeaseConflictScenario(allocator, io);
    try runLeaseRenewReleaseScenario(allocator, io);
    try runPrepareGateScenario(allocator, io);
    try runDisconnectedClientRetentionScenario(allocator, io);
    try runScopedStopScenario(allocator, io);
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
    return spawnIsolatedDaemonWithOptions(allocator, io, self_exe, pref_path, idle_exit_ms, null, null);
}

fn spawnIsolatedDaemonWithRetention(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
    retention_ms: []const u8,
) !std.process.Child {
    return spawnIsolatedDaemonWithOptions(allocator, io, self_exe, pref_path, IT_SAFETY_IDLE_EXIT_MS, null, retention_ms);
}

fn spawnIsolatedDaemonWithSlowIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
    slow_io_ms: []const u8,
) !std.process.Child {
    return spawnIsolatedDaemonWithOptions(allocator, io, self_exe, pref_path, IT_SAFETY_IDLE_EXIT_MS, slow_io_ms, null);
}

fn spawnIsolatedDaemonWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    pref_path: []const u8,
    idle_exit_ms: ?[]const u8,
    slow_io_ms: ?[]const u8,
    retention_ms: ?[]const u8,
) !std.process.Child {
    var env_map = try std.process.Environ.createMap(currentEnviron(), allocator);
    defer env_map.deinit();

    // Always set a safety-net idle so a crashed IT cannot leak a permanent daemon.
    // Per-test tighter overrides still win when provided.
    try env_map.put("VERDE_SESSION_DAEMON_IDLE_EXIT_MS", idle_exit_ms orelse IT_SAFETY_IDLE_EXIT_MS);
    if (slow_io_ms) |value| try env_map.put("VERDE_SESSIONIZER_TEST_SLOW_IO_MS", value);
    if (retention_ms) |value| try env_map.put("VERDE_SESSIONIZER_TEST_RETENTION_MS", value);

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
    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, "500");
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
    var child = try spawnIsolatedDaemonWithEnv(allocator, io, self_exe, pref_path, "500");
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
