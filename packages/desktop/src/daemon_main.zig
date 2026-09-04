//! Standalone, noninteractive entry point for the GUI-free Verde daemon.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const headless = @import("headless");

const platform_paths = @import("platform_paths");
const platform_runtime = @import("platform_runtime");
const cli = @import("cli/main.zig");
const sessionizer = @import("terminal/sessionizer.zig");
const access_protocol = headless.access_protocol;
const connect_protocol = headless.connect_protocol;

const NOTIFY_REQUEST_TIMEOUT_MS: u32 = 5_000;
const SIGNAL_WATCH_INTERVAL_MS: i64 = 25;
const SIGNAL_DRAIN_RETRY_MS: i64 = 250;
const SIGNAL_DRAIN_REQUEST_TIMEOUT_MS: u32 = 500;

var termination_signal_requested = std.atomic.Value(bool).init(false);

const TerminationWatcher = if (builtin.os.tag == .windows) struct {
    fn init(_: std.mem.Allocator, _: []const u8) @This() {
        return .{};
    }

    fn start(_: *@This()) !void {}
    fn deinit(_: *@This()) void {}
} else struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    stop_requested: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    previous_interrupt: std.posix.Sigaction = undefined,
    previous_terminate: std.posix.Sigaction = undefined,
    started: bool = false,

    fn init(allocator: std.mem.Allocator, data_dir: []const u8) @This() {
        return .{
            .allocator = allocator,
            .data_dir = data_dir,
        };
    }

    fn start(self: *@This()) !void {
        termination_signal_requested.store(false, .release);
        self.stop_requested.store(false, .release);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleTerminationSignal },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(.INT, &action, &self.previous_interrupt);
        errdefer std.posix.sigaction(.INT, &self.previous_interrupt, null);
        std.posix.sigaction(.TERM, &action, &self.previous_terminate);
        errdefer std.posix.sigaction(.TERM, &self.previous_terminate, null);
        self.thread = try std.Thread.spawn(.{}, watch, .{self});
        self.started = true;
    }

    fn deinit(self: *@This()) void {
        if (!self.started) return;
        self.stop_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        std.posix.sigaction(.TERM, &self.previous_terminate, null);
        std.posix.sigaction(.INT, &self.previous_interrupt, null);
        self.started = false;
    }

    fn handleTerminationSignal(_: std.posix.SIG) callconv(.c) void {
        // Async-signal-safe by construction: no allocation, I/O, or locks.
        termination_signal_requested.store(true, .release);
    }

    fn watch(self: *@This()) void {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        while (!self.stop_requested.load(.acquire)) {
            if (!termination_signal_requested.load(.acquire)) {
                std.Io.sleep(io, .fromMilliseconds(SIGNAL_WATCH_INTERVAL_MS), .awake) catch {};
                continue;
            }

            const accepted = requestPrepareShutdown(self.allocator, self.data_dir) catch false;
            if (accepted) return;
            if (self.stop_requested.load(.acquire)) return;
            std.Io.sleep(io, .fromMilliseconds(SIGNAL_DRAIN_RETRY_MS), .awake) catch {};
        }
    }
};

const Command = enum {
    session_daemon_compat,
    help,
    version,
    init,
    serve,
    status,
    providers_status,
    workspace_show,
    workspace_bind,
    workspace_repository_bind,
    pair_create,
    pair_list,
    pair_revoke,
    device_list,
    device_revoke,
    connect_login,
    connect_link,
    connect_status,
    connect_unlink,
    connect_logout,
    notify,
};

const ConnectOptions = struct {
    control_plane_url: ?[]const u8 = null,
    credential_file: ?[]const u8 = null,
    descriptor_file: ?[]const u8 = null,
};

const PairOptions = struct {
    label: ?[]const u8 = null,
    ttl_seconds: u32 = access_protocol.DEFAULT_PAIRING_TTL_SECONDS,
    expires_set: bool = false,
    id: ?[]const u8 = null,
    scopes: [access_protocol.MAX_SCOPE_COUNT][]const u8 = @splat(""),
    scope_count: usize = 0,
};

const RepositoryBindOptions = struct {
    workspace_id: ?[]const u8 = null,
    repository_id: ?[]const u8 = null,
    label: ?[]const u8 = null,
    root: ?[]const u8 = null,
    vcs_identity: ?[]const u8 = null,
    default_branch: ?[]const u8 = null,
    set_default: bool = false,
};

const NotifyOptions = struct {
    help: bool = false,
    quiet: bool = false,
    clear: bool = false,
    session_id: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
    dock_id: ?u32 = null,
    pane_id: ?u32 = null,
    provider: ?[]const u8 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    status: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

const Options = struct {
    command: Command,
    data_dir: ?[]const u8 = null,
    json: bool = false,
    repository_bind: RepositoryBindOptions = .{},
    pair: PairOptions = .{},
    connect: ConnectOptions = .{},
    notify: NotifyOptions = .{},
};

const ParseError = error{
    DuplicateDataDir,
    DuplicateJson,
    InvalidArguments,
    JsonUnavailable,
    MissingDataDir,
    MissingOptionValue,
    MissingPairCommand,
    MissingDeviceCommand,
    MissingConnectCommand,
    MissingProvidersCommand,
    MissingWorkspaceCommand,
    UnknownCommand,
    UnknownPairCommand,
    UnknownDeviceCommand,
    UnknownConnectCommand,
    UnknownProvidersCommand,
    UnknownWorkspaceCommand,
};

const InitResult = struct {
    ok: bool = true,
    initialized: bool = true,
    daemon_running: bool,
    data_dir: []const u8,
    runtime_id: ?[]const u8 = null,
    instance_id: ?[]const u8 = null,
    store_schema_version: ?u32 = null,
};

const StatusResult = struct {
    ok: bool = true,
    running: bool = true,
    data_dir: []const u8,
    runtime: headless.StatusResult,
    store: ?headless.store_protocol.StoreStatusResult,
};

const ProvidersResult = struct {
    ok: bool = true,
    data_dir: []const u8,
    result: headless.providers_protocol.StatusResult,
};

const RepositoryBindResult = struct {
    ok: bool = true,
    data_dir: []const u8,
    runtime_id: []const u8,
    workspace_id: []const u8,
    repository_id: []const u8,
    root_path: []const u8,
    requested_default: bool,
    store_revision: u64,
};

pub fn main(init: std.process.Init) void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (builtin.mode == .Debug) _ = debug_allocator.deinit();
    }
    const allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    const exit_code = run(allocator, init.io, init.minimal.args) catch |err| blk: {
        writeStderr(init.io, "verde-daemon: {s}\n", .{@errorName(err)}) catch {};
        break :blk @as(u8, 1);
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args) !u8 {
    var iterator = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer iterator.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    while (iterator.next()) |arg| try argv.append(allocator, arg);

    const options = parseArgs(argv.items) catch |err| {
        try writeParseError(io, err);
        try printHelp(io, true);
        return 2;
    };

    if (options.command == .help) {
        try printHelp(io, false);
        return 0;
    }
    if (options.command == .version) {
        if (options.json) {
            try writeJson(io, allocator, .{ .version = build_options.version });
        } else {
            try writeStdout(io, "verde-daemon {s}\n", .{build_options.version});
        }
        return 0;
    }

    if (options.command == .notify) {
        prepareAndHandleNotify(allocator, io, options) catch |err| {
            const target = options.data_dir orelse "inherited VERDE_SESSIONIZER_SOCKET";
            try writeCommandError(io, allocator, options.json, target, err);
            return commandErrorExitCode(err);
        };
        return 0;
    }

    const unresolved_data_dir = try resolveDataDir(allocator, options.data_dir);
    defer allocator.free(unresolved_data_dir);

    prepareAndExecute(allocator, io, options, unresolved_data_dir) catch |err| {
        try writeCommandError(io, allocator, options.json, unresolved_data_dir, err);
        return commandErrorExitCode(err);
    };
    return 0;
}

fn prepareAndExecute(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    unresolved_data_dir: []const u8,
) !void {
    try rejectInheritedSocketOverride(allocator);
    if (options.command == .session_daemon_compat or options.command == .init or options.command == .serve) {
        try std.Io.Dir.cwd().createDirPath(io, unresolved_data_dir);
    }
    const data_dir = try canonicalDataDir(allocator, io, unresolved_data_dir);
    defer allocator.free(data_dir);
    try execute(allocator, io, options, data_dir);
}

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    data_dir: []const u8,
) !void {
    switch (options.command) {
        .session_daemon_compat => try sessionizer.runDaemonWithMcp(allocator, data_dir, cli.handleMcpHttpRequest),
        .init => try handleInit(allocator, io, data_dir, options.json),
        .serve => try handleServe(allocator, io, data_dir),
        .status => try handleStatus(allocator, io, data_dir, options.json),
        .providers_status => try handleProvidersStatus(allocator, io, data_dir, options.json),
        .workspace_show => try handleWorkspaceShow(allocator, io, data_dir, options),
        .workspace_bind => try handleWorkspaceBind(allocator, io, data_dir, options),
        .workspace_repository_bind => try handleWorkspaceRepositoryBind(allocator, io, data_dir, options),
        .pair_create, .pair_list, .pair_revoke, .device_list, .device_revoke => try handleAccessAdministration(allocator, io, data_dir, options),
        .connect_login, .connect_link, .connect_status, .connect_unlink, .connect_logout => try handleConnectAdministration(allocator, io, data_dir, options),
        .help, .version, .notify => unreachable,
    }
}

const NotifyTargetMode = enum {
    data_dir,
    inherited_endpoint,
};

fn selectNotifyTargetMode(has_data_dir: bool, has_endpoint: bool) !NotifyTargetMode {
    if (has_data_dir and has_endpoint) return error.AmbiguousNotifyTarget;
    if (has_data_dir) return .data_dir;
    if (has_endpoint) return .inherited_endpoint;
    return error.MissingNotifyTarget;
}

fn prepareAndHandleNotify(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    if (options.notify.help) {
        try printNotifyHelp(io);
        return;
    }

    const inherited_endpoint = try environmentValueAlloc(
        allocator,
        sessionizer.SESSIONIZER_SOCKET_ENV_NAME,
    );
    defer if (inherited_endpoint) |value| allocator.free(value);

    switch (try selectNotifyTargetMode(options.data_dir != null, inherited_endpoint != null)) {
        .data_dir => {
            const unresolved = try resolveDataDir(allocator, options.data_dir);
            defer allocator.free(unresolved);
            const data_dir = try canonicalDataDir(allocator, io, unresolved);
            defer allocator.free(data_dir);
            try handleNotify(allocator, io, data_dir, options);
        },
        .inherited_endpoint => {
            // HeadlessTransport honors the non-empty process endpoint checked
            // above. The pref path is intentionally absent in endpoint-only mode.
            try handleNotify(allocator, io, "", options);
        },
    }
}

fn handleNotify(
    allocator: std.mem.Allocator,
    io: std.Io,
    pref_path: []const u8,
    options: Options,
) !void {
    const notify = options.notify;
    const session_id = notify.session_id orelse getenvSlice("VERDE_SESSION_ID") orelse
        return error.MissingNotifySession;
    if (session_id.len == 0) return error.MissingNotifySession;

    const status = notify.status;
    if (!notify.clear and status == null) return error.MissingNotifyStatus;
    if (status) |value| if (!validNotifyStatus(value)) return error.InvalidNotifyStatus;

    const provider = notify.provider orelse getenvSlice("VERDE_PROVIDER");
    if (provider) |value| if (!validNotifyProvider(value)) return error.InvalidNotifyProvider;
    const workspace_id = notify.workspace_id orelse getenvSlice("VERDE_WORKSPACE_ID") orelse "";
    const workspace_path = getenvSlice("VERDE_WORKSPACE_PATH") orelse "";
    const env_dock_id = try parseOptionalIdentityU32(getenvSlice("VERDE_DOCK_ID"));
    const env_pane_id = try parseOptionalIdentityU32(getenvSlice("VERDE_PANE_ID"));
    const dock_id = notify.dock_id orelse env_dock_id orelse 0;
    const pane_id = notify.pane_id orelse env_pane_id;
    const changed_at_ms = platform_runtime.unixTimestampMs();
    const effective_status = status orelse "idle";

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const arena = decode_arena.allocator();

    var transport: sessionizer.HeadlessTransport = .{
        .allocator = arena,
        .pref_path = pref_path,
        .timeout_ms = NOTIFY_REQUEST_TIMEOUT_MS,
    };
    var client = sessionizer.headlessClient(arena, &transport);
    var registered = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer registered.deinit();
    const client_id = (try client.decodeClientRegister(&registered)).client_id;

    const request_key = try std.fmt.allocPrint(
        arena,
        "cli:notify:{s}:{d}",
        .{ session_id, changed_at_ms },
    );
    const mutation: headless.store.MutationHeader = .{
        .request_key = request_key,
        .client_id = client_id,
    };
    const clear = notify.clear or std.mem.eql(u8, effective_status, "idle");
    var write_result: headless.store.WriteResult = undefined;
    if (clear) {
        var parsed = try client.call(headless.store.METHOD_SURFACE_CLEAR, headless.store.SurfaceClearRequest{
            .mutation = mutation,
            .session_id = session_id,
        });
        defer parsed.deinit();
        write_result = try client.decodeWriteResult(&parsed);
    } else {
        var parsed = try client.call(headless.store.METHOD_SURFACE_UPSERT, headless.store.SurfaceUpsertRequest{
            .mutation = mutation,
            .surface = .{
                .session_id = session_id,
                .workspace_id = workspace_id,
                .workspace_path = workspace_path,
                .dock_id = dock_id,
                .pane_id = pane_id,
                .provider = provider,
                .provider_thread_id = getenvSlice("VERDE_PROVIDER_THREAD_ID"),
                .title = notify.label orelse notify.title orelse "",
                .status = effective_status,
                .status_changed_at_ms = changed_at_ms,
                .completed_at_ms = if (std.mem.eql(u8, effective_status, "done")) changed_at_ms else 0,
                .last_event_title = notify.title orelse notify.label,
                .last_event_body = notify.body,
            },
        });
        defer parsed.deinit();
        write_result = try client.decodeWriteResult(&parsed);
    }

    if (options.json) {
        try writeJson(io, allocator, .{
            .ok = true,
            .session_id = session_id,
            .cleared = clear,
            .status = effective_status,
            .store_revision = write_result.store_revision,
            .applied = write_result.applied,
            .duplicate = write_result.duplicate,
        });
    } else if (!notify.quiet) {
        try writeStdout(
            io,
            "Updated surface {s}: {s} (store revision {d})\n",
            .{ session_id, if (clear) "idle" else effective_status, write_result.store_revision },
        );
    }
}

fn parseOptionalIdentityU32(value: ?[]const u8) !?u32 {
    const raw = value orelse return null;
    if (raw.len == 0) return null;
    return std.fmt.parseInt(u32, raw, 10) catch error.InvalidNotifyIdentity;
}

fn validNotifyStatus(value: []const u8) bool {
    return stringIn(value, &.{ "idle", "working", "waiting", "done", "error" });
}

fn validNotifyProvider(value: []const u8) bool {
    return stringIn(value, &.{ "codex", "claude", "cursor", "opencode", "amp", "pi", "fx", "grok" });
}

fn stringIn(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn handleServe(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !void {
    try writeStderr(io, "verde-daemon: serving data directory {s}\n", .{data_dir});
    var watcher = TerminationWatcher.init(allocator, data_dir);
    defer watcher.deinit();
    try sessionizer.runDaemonWithReadyCallback(allocator, data_dir, .{
        .context = &watcher,
        .notify = startTerminationWatcher,
    });
}

fn startTerminationWatcher(raw_context: *anyopaque) !void {
    const watcher: *TerminationWatcher = @ptrCast(@alignCast(raw_context));
    try watcher.start();
}

fn requestPrepareShutdown(allocator: std.mem.Allocator, data_dir: []const u8) !bool {
    const response = try sessionizer.requestAllocWithTimeout(
        allocator,
        data_dir,
        "daemon.prepareShutdown",
        .{ .expected_pid = platform_runtime.processId() },
        1,
        SIGNAL_DRAIN_REQUEST_TIMEOUT_MS,
    );
    defer allocator.free(response);
    return prepareShutdownAccepted(allocator, response);
}

fn prepareShutdownAccepted(allocator: std.mem.Allocator, response: []const u8) bool {
    var parsed = headless.parseResponse(allocator, response) catch return false;
    defer parsed.deinit();
    if (!parsed.response.isOk()) return false;
    const result = parsed.response.result orelse return false;
    if (result != .object) return false;
    const accepted = result.object.get("accepted") orelse return false;
    const safe_to_exit = result.object.get("safe_to_exit") orelse return false;
    return accepted == .bool and accepted.bool and
        safe_to_exit == .bool and safe_to_exit.bool;
}

fn handleInit(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, json: bool) !void {
    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const arena = decode_arena.allocator();

    var existing_status: ?headless.StatusResult = queryStatus(arena, data_dir) catch |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => null,
        else => return err,
    };
    var existing_store: ?headless.store_protocol.StoreStatusResult = null;
    if (existing_status) |status| {
        existing_store = try queryStoreStatus(arena, data_dir, status.capabilities);
    } else {
        sessionizer.initializeDaemonData(allocator, data_dir) catch |init_err| {
            // A daemon may have won the endpoint race after our first probe.
            // Accept it only after the same identity and store verification.
            existing_status = queryStatus(arena, data_dir) catch return init_err;
            existing_store = try queryStoreStatus(arena, data_dir, existing_status.?.capabilities);
        };
    }

    const result: InitResult = .{
        .daemon_running = existing_status != null,
        .data_dir = data_dir,
        .runtime_id = if (existing_status) |status| status.runtime_id else null,
        .instance_id = if (existing_status) |status| status.instance_id else null,
        .store_schema_version = if (existing_store) |store| store.schema_version else null,
    };
    if (json) {
        try writeJson(io, allocator, result);
        return;
    }

    try writeStdout(io, "Initialized Verde daemon data at {s}\n", .{data_dir});
    if (result.daemon_running) {
        try writeStdout(io, "Daemon: running\n", .{});
        try writeStdout(io, "Runtime ID: {s}\n", .{result.runtime_id.?});
        try writeStdout(io, "Store schema: {d}\n", .{result.store_schema_version.?});
    } else {
        try writeStdout(io, "Daemon: stopped (identity and store verified)\n", .{});
    }
}

fn handleStatus(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, json: bool) !void {
    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const arena = decode_arena.allocator();

    const status = try queryStatus(arena, data_dir);
    const store = if (status.capabilities.store)
        try queryStoreStatus(arena, data_dir, status.capabilities)
    else
        null;
    const result: StatusResult = .{
        .data_dir = data_dir,
        .runtime = status,
        .store = store,
    };
    if (json) {
        try writeJson(io, allocator, result);
        return;
    }

    try writeStdout(io, "Verde daemon is running\n", .{});
    try writeStdout(io, "Data directory: {s}\n", .{data_dir});
    try writeStdout(io, "Runtime ID: {s}\n", .{status.runtime_id});
    try writeStdout(io, "Instance ID: {s}\n", .{status.instance_id});
    try writeStdout(io, "Version: {s}\n", .{status.server_version});
    try writeStdout(io, "PID: {d}\n", .{status.pid});
    try writeStdout(io, "Sessions: {d}\n", .{status.session_count});
    try writeStdout(io, "Chat turns: {d}\n", .{status.chat_turn_count});
    if (store) |store_status| {
        try writeStdout(
            io,
            "Store: {s} (schema {d}, revision {d})\n",
            .{ store_status.drain_state, store_status.schema_version, store_status.store_revision },
        );
    } else {
        try writeStdout(io, "Store: unavailable\n", .{});
    }
}

fn handleProvidersStatus(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8, json: bool) !void {
    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const arena = decode_arena.allocator();

    var transport: sessionizer.HeadlessTransport = .{
        .allocator = arena,
        .pref_path = data_dir,
    };
    var client = sessionizer.headlessClient(arena, &transport);
    const handshake = try client.handshakeRuntime(null);
    var parsed = try client.callProviderStatus(handshake.status.capabilities);
    defer parsed.deinit();
    const provider_status = try client.decodeProviderStatus(&parsed);
    const result: ProvidersResult = .{
        .data_dir = data_dir,
        .result = provider_status,
    };
    if (json) {
        try writeJson(io, allocator, result);
        return;
    }

    try writeStdout(io, "Provider status for runtime {s}\n", .{provider_status.runtime_id});
    for (provider_status.providers) |provider| {
        try writeStdout(
            io,
            "{s}: {s} (installed={s}, auth={s})\n",
            .{
                provider.label,
                provider.state,
                if (provider.installed) "yes" else "no",
                provider.authentication,
            },
        );
        if (provider.remediation) |remediation| {
            try writeStdout(io, "  Next: {s}\n", .{remediation.label});
        }
    }
}

/// Print the complete bounded repository manifest for one workspace. Absolute
/// checkout paths appear only in this local administrative response.
fn handleWorkspaceShow(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    options: Options,
) !void {
    const workspace_id = options.repository_bind.workspace_id orelse return error.InvalidArguments;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var transport: sessionizer.HeadlessTransport = .{ .allocator = arena, .pref_path = data_dir };
    var client = sessionizer.headlessClient(arena, &transport);
    const handshake = try client.handshakeRuntime(null);
    var parsed = try client.callWorkspaceRepositoryManifest(
        handshake.status.capabilities,
        .{ .workspace_id = workspace_id },
    );
    defer parsed.deinit();
    const manifest = try client.decodeWorkspaceRepositoryManifest(&parsed);
    if (options.json) return writeJson(io, allocator, manifest);

    try writeStdout(
        io,
        "Workspace {s} repositories (default: {s}, store revision {d})\n",
        .{ manifest.workspace_id, manifest.default_repository_id, manifest.store_revision },
    );
    for (manifest.repositories) |repository| {
        const marker = if (std.mem.eql(u8, repository.repository_id, manifest.default_repository_id)) "*" else " ";
        try writeStdout(io, "{s} {s}: {s}\n", .{ marker, repository.repository_id, repository.label });
        if (repository.vcs_identity) |identity| try writeStdout(io, "    VCS: {s}\n", .{identity});
        if (repository.default_branch) |branch| try writeStdout(io, "    Branch: {s}\n", .{branch});
        if (repository.bindings.len == 0) {
            try writeStdout(io, "    No runtime bindings\n", .{});
            continue;
        }
        for (repository.bindings) |binding| {
            try writeStdout(
                io,
                "    {s}: {s} ({s})\n",
                .{ binding.runtime_id, binding.root_path, binding.availability },
            );
        }
    }
}

/// Bind the workspace's stable `primary` repository to an existing checkout
/// on this daemon. The mutation goes through the running sole-writer daemon;
/// this command never opens SQLite or creates/deletes checkout contents.
fn handleWorkspaceBind(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    options: Options,
) !void {
    const binding = options.repository_bind;
    const workspace_id = binding.workspace_id orelse return error.InvalidArguments;
    const label = binding.label orelse return error.InvalidArguments;
    const raw_root = binding.root orelse return error.InvalidArguments;
    const root_path = try canonicalRepositoryRootAlloc(allocator, io, raw_root);
    defer allocator.free(root_path);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var transport: sessionizer.HeadlessTransport = .{ .allocator = arena, .pref_path = data_dir };
    var client = sessionizer.headlessClient(arena, &transport);
    const handshake = try client.handshakeRuntime(null);
    try headless.requireCapability(handshake.status.capabilities, .repository_manifests);
    const client_id = try registerAdministrativeClient(&client);
    const request_key = try std.fmt.allocPrint(
        arena,
        "daemon-cli:workspace-bind:{s}:{d}",
        .{ workspace_id, platform_runtime.unixTimestampMs() },
    );
    var parsed = try client.call(headless.store.METHOD_WORKSPACE_UPSERT, headless.store.WorkspaceUpsertRequest{
        .mutation = .{ .request_key = request_key, .client_id = client_id },
        .workspace = .{
            .workspace_id = workspace_id,
            .label = label,
            .path = root_path,
        },
    });
    defer parsed.deinit();
    const write_result = try client.decodeWriteResult(&parsed);
    try writeRepositoryBindResult(io, allocator, options.json, .{
        .data_dir = data_dir,
        .runtime_id = handshake.status.runtime_id,
        .workspace_id = workspace_id,
        .repository_id = headless.store.PRIMARY_REPOSITORY_ID,
        .root_path = root_path,
        .requested_default = false,
        .store_revision = write_result.store_revision,
    });
}

/// Add or update one non-primary repository definition and bind its checkout
/// to this exact runtime identity. Rerunning after a partial failure is safe:
/// every mutation is an idempotent upsert and checkout data is never touched.
fn handleWorkspaceRepositoryBind(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    options: Options,
) !void {
    const binding = options.repository_bind;
    const workspace_id = binding.workspace_id orelse return error.InvalidArguments;
    const repository_id = binding.repository_id orelse return error.InvalidArguments;
    const label = binding.label orelse return error.InvalidArguments;
    const raw_root = binding.root orelse return error.InvalidArguments;
    const root_path = try canonicalRepositoryRootAlloc(allocator, io, raw_root);
    defer allocator.free(root_path);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var transport: sessionizer.HeadlessTransport = .{ .allocator = arena, .pref_path = data_dir };
    var client = sessionizer.headlessClient(arena, &transport);
    const handshake = try client.handshakeRuntime(null);
    try headless.requireCapability(handshake.status.capabilities, .repository_manifests);
    const client_id = try registerAdministrativeClient(&client);
    const operation_id = platform_runtime.unixTimestampMs();

    var repository_response = try client.callWorkspaceRepositoryUpsert(
        handshake.status.capabilities,
        .{
            .mutation = .{
                .request_key = try std.fmt.allocPrint(arena, "daemon-cli:repository:{s}:{s}:{d}", .{ workspace_id, repository_id, operation_id }),
                .client_id = client_id,
            },
            .workspace_id = workspace_id,
            .repository = .{
                .repository_id = repository_id,
                .label = label,
                .vcs_identity = binding.vcs_identity,
                .default_branch = binding.default_branch,
            },
        },
    );
    defer repository_response.deinit();
    _ = try client.decodeWriteResult(&repository_response);

    var binding_response = try client.callWorkspaceRepositoryBindingUpsert(
        handshake.status.capabilities,
        .{
            .mutation = .{
                .request_key = try std.fmt.allocPrint(arena, "daemon-cli:repository-binding:{s}:{s}:{d}", .{ workspace_id, repository_id, operation_id }),
                .client_id = client_id,
            },
            .workspace_id = workspace_id,
            .repository_id = repository_id,
            .binding = .{
                .runtime_id = handshake.status.runtime_id,
                .root_path = root_path,
                .availability = "available",
            },
        },
    );
    defer binding_response.deinit();
    var final_result = try client.decodeWriteResult(&binding_response);

    if (binding.set_default) {
        var default_response = try client.callWorkspaceRepositoryDefaultSet(
            handshake.status.capabilities,
            .{
                .mutation = .{
                    .request_key = try std.fmt.allocPrint(arena, "daemon-cli:repository-default:{s}:{s}:{d}", .{ workspace_id, repository_id, operation_id }),
                    .client_id = client_id,
                },
                .workspace_id = workspace_id,
                .repository_id = repository_id,
            },
        );
        defer default_response.deinit();
        final_result = try client.decodeWriteResult(&default_response);
    }

    try writeRepositoryBindResult(io, allocator, options.json, .{
        .data_dir = data_dir,
        .runtime_id = handshake.status.runtime_id,
        .workspace_id = workspace_id,
        .repository_id = repository_id,
        .root_path = root_path,
        .requested_default = binding.set_default,
        .store_revision = final_result.store_revision,
    });
}

fn registerAdministrativeClient(client: *headless.Client) ![]const u8 {
    var registered = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = false });
    defer registered.deinit();
    const borrowed = (try client.decodeClientRegister(&registered)).client_id;
    return try client.allocator.dupe(u8, borrowed);
}

fn canonicalRepositoryRootAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    raw_path: []const u8,
) ![]u8 {
    const expanded = try platform_paths.expandUserPath(allocator, raw_path);
    defer allocator.free(expanded);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.cwd().realPathFile(io, expanded, &path_buffer);
    const absolute = path_buffer[0..path_len];
    var directory = try std.Io.Dir.openDirAbsolute(io, absolute, .{
        .access_sub_paths = true,
        .follow_symlinks = false,
    });
    defer directory.close(io);
    return allocator.dupe(u8, absolute);
}

fn writeRepositoryBindResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    json: bool,
    result: RepositoryBindResult,
) !void {
    if (json) return writeJson(io, allocator, result);
    try writeStdout(
        io,
        "Bound {s}/{s} to {s} on runtime {s} (store revision {d})\n",
        .{ result.workspace_id, result.repository_id, result.root_path, result.runtime_id, result.store_revision },
    );
}

/// Owner-only Pair/device administration through the running sole-writer
/// daemon. These commands do not advertise remote Pair availability.
fn handleAccessAdministration(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    options: Options,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var transport: sessionizer.HeadlessTransport = .{ .allocator = arena, .pref_path = data_dir };
    var probe_client = sessionizer.headlessClient(arena, &transport);
    const handshake = try probe_client.handshakeRuntime(null);
    try headless.requireCapability(handshake.status.capabilities, .store);
    // Every RPC opens a new transport connection. Pin all administration
    // calls to the exact generation that answered the status probe so a
    // replacement between calls fails identity validation before mutation.
    var client = try headless.Client.initTargeted(
        arena,
        &transport,
        sessionizer.HeadlessTransport.send,
        .{
            .runtime_id = handshake.status.runtime_id,
            .instance_id = handshake.status.instance_id,
        },
    );

    switch (options.command) {
        .pair_create => {
            const scopes: []const []const u8 = if (options.pair.scope_count == 0)
                access_protocol.DEFAULT_SCOPE_NAMES[0..]
            else
                options.pair.scopes[0..options.pair.scope_count];
            try access_protocol.validatePairingTtl(options.pair.ttl_seconds);
            try access_protocol.validateScopeNames(scopes);
            if (options.pair.label) |label| try access_protocol.validateDeviceLabel(label);
            var parsed = try client.call(
                access_protocol.METHOD_DAEMON_PAIRING_GRANT_CREATE,
                access_protocol.PairingGrantCreateRequest{
                    .access_protocol_version = access_protocol.ACCESS_PROTOCOL_VERSION,
                    .label = options.pair.label,
                    .ttl_seconds = options.pair.ttl_seconds,
                    .scopes = scopes,
                },
            );
            defer parsed.deinit();
            var result = try client.decodePairingGrantCreate(&parsed);
            defer {
                std.crypto.secureZero(u8, @constCast(result.pairing_token.reveal()));
                result.pairing_token = undefined;
            }
            try verifyAccessIdentity(handshake.status, result.runtime_id, result.instance_id);
            try writePairingGrantCreateOutput(io, allocator, data_dir, options.json, result);
        },
        .pair_list => {
            var parsed = try client.call(
                access_protocol.METHOD_DAEMON_PAIRING_GRANT_LIST,
                access_protocol.PairingGrantListRequest{
                    .access_protocol_version = access_protocol.ACCESS_PROTOCOL_VERSION,
                },
            );
            defer parsed.deinit();
            const result = try client.decodePairingGrantList(&parsed);
            try verifyAccessIdentity(handshake.status, result.runtime_id, result.instance_id);
            if (options.json) {
                return writeJson(io, allocator, .{
                    .ok = true,
                    .data_dir = data_dir,
                    .result = result,
                });
            }
            try writeStdout(io, "Pairing grants for runtime {s}: {d}\n", .{ result.runtime_id, result.grants.len });
            const now_ms = platform_runtime.unixTimestampMs();
            for (result.grants) |grant| {
                const state: []const u8 = if (grant.revoked_at_ms != null)
                    "revoked"
                else if (grant.consumed_at_ms != null)
                    "consumed"
                else if (now_ms >= grant.expires_at_ms)
                    "expired"
                else
                    "active";
                try writeStdout(
                    io,
                    "{s}  {s}  expires={d}  label={s}\n",
                    .{ grant.grant_id, state, grant.expires_at_ms, grant.label orelse "-" },
                );
                try writeScopeLine(io, grant.scopes);
            }
        },
        .pair_revoke => {
            const grant_id = options.pair.id orelse return error.InvalidArguments;
            var parsed = try client.call(
                access_protocol.METHOD_DAEMON_PAIRING_GRANT_REVOKE,
                access_protocol.PairingGrantRevokeRequest{
                    .access_protocol_version = access_protocol.ACCESS_PROTOCOL_VERSION,
                    .grant_id = grant_id,
                },
            );
            defer parsed.deinit();
            const result = try client.decodePairingGrantRevoke(&parsed);
            if (options.json) {
                return writeJson(io, allocator, .{
                    .ok = true,
                    .data_dir = data_dir,
                    .result = result,
                });
            }
            try writeStdout(
                io,
                "Pairing grant {s}: {s}\n",
                .{ result.grant_id, if (result.revoked) "revoked" else "already final or not found" },
            );
        },
        .device_list => {
            var parsed = try client.call(
                access_protocol.METHOD_DAEMON_DEVICE_LIST,
                access_protocol.DeviceListRequest{
                    .access_protocol_version = access_protocol.ACCESS_PROTOCOL_VERSION,
                },
            );
            defer parsed.deinit();
            const result = try client.decodeDeviceList(&parsed);
            try verifyAccessIdentity(handshake.status, result.runtime_id, result.instance_id);
            if (options.json) {
                return writeJson(io, allocator, .{
                    .ok = true,
                    .data_dir = data_dir,
                    .result = result,
                });
            }
            try writeStdout(io, "Paired devices for runtime {s}: {d}\n", .{ result.runtime_id, result.devices.len });
            for (result.devices) |device| {
                try writeStdout(
                    io,
                    "{s}  {s}  label={s}  created={d}\n",
                    .{
                        device.device_id,
                        if (device.revoked_at_ms == null) "active" else "revoked",
                        device.label,
                        device.created_at_ms,
                    },
                );
                try writeScopeLine(io, device.scopes);
            }
        },
        .device_revoke => {
            const device_id = options.pair.id orelse return error.InvalidArguments;
            var parsed = try client.call(
                access_protocol.METHOD_DAEMON_DEVICE_REVOKE,
                access_protocol.DeviceRevokeRequest{
                    .access_protocol_version = access_protocol.ACCESS_PROTOCOL_VERSION,
                    .device_id = device_id,
                },
            );
            defer parsed.deinit();
            const result = try client.decodeDeviceRevoke(&parsed);
            if (options.json) {
                return writeJson(io, allocator, .{
                    .ok = true,
                    .data_dir = data_dir,
                    .result = result,
                });
            }
            try writeStdout(
                io,
                "Device {s}: {s}\n",
                .{ result.device_id, if (result.revoked) "revoked" else "already revoked or not found" },
            );
        },
        else => unreachable,
    }
}

fn verifyAccessIdentity(
    status: headless.StatusResult,
    runtime_id: []const u8,
    instance_id: []const u8,
) !void {
    if (!std.mem.eql(u8, status.runtime_id, runtime_id) or
        !std.mem.eql(u8, status.instance_id, instance_id))
    {
        return error.RuntimeIdentityMismatch;
    }
}

fn writePairingGrantCreateOutput(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    json: bool,
    result: access_protocol.PairingGrantCreateResult,
) !void {
    if (json) {
        const encoded = try std.json.Stringify.valueAlloc(allocator, .{
            .ok = true,
            .data_dir = data_dir,
            .result = .{
                .access_protocol_version = result.access_protocol_version,
                .runtime_id = result.runtime_id,
                .instance_id = result.instance_id,
                .grant_id = result.grant_id,
                // This is the only CLI JSON boundary that deliberately
                // reveals a one-time pairing token.
                .pairing_token = result.pairing_token.reveal(),
                .expires_at_ms = result.expires_at_ms,
                .scopes = result.scopes,
            },
        }, .{ .emit_null_optional_fields = false });
        defer {
            std.crypto.secureZero(u8, encoded);
            allocator.free(encoded);
        }
        return writeSensitiveStdout(io, "{s}\n", .{encoded});
    }

    try writeSensitiveStdout(
        io,
        "Pairing grant created for runtime {s}\nGrant ID: {s}\nExpires: {d}\nPairing token (shown once): {s}\n",
        .{ result.runtime_id, result.grant_id, result.expires_at_ms, result.pairing_token.reveal() },
    );
    try writeScopeLine(io, result.scopes);
}

fn writeScopeLine(io: std.Io, scopes: []const []const u8) !void {
    try writeStdout(io, "  Scopes:", .{});
    for (scopes) |scope| try writeStdout(io, " {s}", .{scope});
    try writeStdout(io, "\n", .{});
}

fn handleConnectAdministration(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    options: Options,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var transport: sessionizer.HeadlessTransport = .{ .allocator = arena, .pref_path = data_dir };
    var probe_client = sessionizer.headlessClient(arena, &transport);
    const handshake = try probe_client.handshakeRuntime(null);
    var client = try headless.Client.initTargeted(
        arena,
        &transport,
        sessionizer.HeadlessTransport.send,
        .{
            .runtime_id = handshake.status.runtime_id,
            .instance_id = handshake.status.instance_id,
        },
    );

    var parsed = switch (options.command) {
        .connect_login => try client.call(
            connect_protocol.METHOD_LOGIN,
            connect_protocol.LoginRequest{
                .connect_protocol_version = connect_protocol.CONNECT_PROTOCOL_VERSION,
                .control_plane_url = options.connect.control_plane_url.?,
                .credential_file = options.connect.credential_file.?,
            },
        ),
        .connect_link => link: {
            const descriptor = try readConnectDescriptor(arena, io, options.connect.descriptor_file.?);
            if (!std.mem.eql(u8, descriptor.runtime_id, handshake.status.runtime_id) or
                !std.mem.eql(u8, descriptor.instance_id, handshake.status.instance_id))
            {
                return error.RuntimeIdentityMismatch;
            }
            break :link try client.call(
                connect_protocol.METHOD_LINK,
                connect_protocol.LinkRequest{
                    .connect_protocol_version = connect_protocol.CONNECT_PROTOCOL_VERSION,
                    .provider = "external",
                    .external_descriptor = descriptor,
                },
            );
        },
        .connect_status => try client.call(
            connect_protocol.METHOD_STATUS,
            connect_protocol.StatusRequest{ .connect_protocol_version = connect_protocol.CONNECT_PROTOCOL_VERSION },
        ),
        .connect_unlink => try client.call(
            connect_protocol.METHOD_UNLINK,
            connect_protocol.UnlinkRequest{ .connect_protocol_version = connect_protocol.CONNECT_PROTOCOL_VERSION },
        ),
        .connect_logout => try client.call(
            connect_protocol.METHOD_LOGOUT,
            connect_protocol.LogoutRequest{ .connect_protocol_version = connect_protocol.CONNECT_PROTOCOL_VERSION },
        ),
        else => unreachable,
    };
    defer parsed.deinit();
    const status = try client.decodeConnectStatus(&parsed);
    if (!std.mem.eql(u8, status.runtime_id, handshake.status.runtime_id) or
        !std.mem.eql(u8, status.instance_id, handshake.status.instance_id))
    {
        return error.RuntimeIdentityMismatch;
    }
    if (options.json) {
        return writeJson(io, allocator, .{ .ok = true, .data_dir = data_dir, .result = status });
    }
    try writeStdout(
        io,
        "Connect: {s} (desired={s}, authenticated={s}, connector={s})\n",
        .{
            @tagName(status.state),
            @tagName(status.desired_state),
            if (status.authenticated) "yes" else "no",
            if (status.connector_running) "running" else "stopped",
        },
    );
    if (status.endpoint_https_url) |url| try writeStdout(io, "Endpoint: {s}\n", .{url});
    if (status.next_retry_at_ms) |retry_at| try writeStdout(io, "Retry at: {d}\n", .{retry_at});
}

fn readConnectDescriptor(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !connect_protocol.RuntimeDescriptor {
    const MAX_DESCRIPTOR_BYTES: usize = 64 * 1024;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > MAX_DESCRIPTOR_BYTES) return error.InvalidArguments;
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(MAX_DESCRIPTOR_BYTES));
    return std.json.parseFromSliceLeaky(connect_protocol.RuntimeDescriptor, allocator, bytes, .{});
}

fn queryStatus(allocator: std.mem.Allocator, data_dir: []const u8) !headless.StatusResult {
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = data_dir,
    };
    var client = sessionizer.headlessClient(allocator, &transport);
    const handshake = try client.handshakeRuntime(null);
    return handshake.status;
}

fn queryStoreStatus(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    capabilities: headless.Capabilities,
) !headless.store_protocol.StoreStatusResult {
    if (!capabilities.store) return error.StoreUnavailable;
    var transport: sessionizer.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = data_dir,
    };
    var client = sessionizer.headlessClient(allocator, &transport);
    const empty_params: struct {} = .{};
    var parsed = try client.call(headless.store_protocol.METHOD_DAEMON_STORE_STATUS, empty_params);
    defer parsed.deinit();
    return try client.decodeStoreStatus(&parsed);
}

fn resolveDataDir(allocator: std.mem.Allocator, raw_path: ?[]const u8) ![]u8 {
    if (raw_path) |path| return try platform_paths.expandUserPath(allocator, path);
    return try platform_paths.sdlPrefPathFallback(allocator, "verde", "Native");
}

fn canonicalDataDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    unresolved_data_dir: []const u8,
) ![]u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try std.Io.Dir.cwd().realPathFile(io, unresolved_data_dir, &path_buffer);
    return try allocator.dupe(u8, path_buffer[0..path_len]);
}

fn rejectInheritedSocketOverride(allocator: std.mem.Allocator) !void {
    const inherited_endpoint = try environmentValueAlloc(
        allocator,
        sessionizer.SESSIONIZER_SOCKET_ENV_NAME,
    );
    defer if (inherited_endpoint) |value| allocator.free(value);
    if (inherited_endpoint != null) return error.InheritedSocketOverride;
}

fn environmentValueAlloc(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const raw = environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn getenvSlice(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn parseArgs(argv: []const []const u8) ParseError!Options {
    if (argv.len <= 1) return .{ .command = .help };
    const first = argv[1];
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        if (argv.len != 2) return error.InvalidArguments;
        return .{ .command = .help };
    }

    var command: Command = undefined;
    var option_start: usize = 2;
    if (std.mem.eql(u8, first, "__session-daemon")) {
        command = .session_daemon_compat;
    } else if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version")) {
        command = .version;
    } else if (std.mem.eql(u8, first, "init")) {
        command = .init;
    } else if (std.mem.eql(u8, first, "serve")) {
        command = .serve;
    } else if (std.mem.eql(u8, first, "status")) {
        command = .status;
    } else if (std.mem.eql(u8, first, "notify")) {
        command = .notify;
    } else if (std.mem.eql(u8, first, "pair")) {
        if (argv.len <= 2) return error.MissingPairCommand;
        if (std.mem.eql(u8, argv[2], "create")) {
            command = .pair_create;
        } else if (std.mem.eql(u8, argv[2], "list")) {
            command = .pair_list;
        } else if (std.mem.eql(u8, argv[2], "revoke")) {
            command = .pair_revoke;
        } else {
            return error.UnknownPairCommand;
        }
        option_start = 3;
    } else if (std.mem.eql(u8, first, "device")) {
        if (argv.len <= 2) return error.MissingDeviceCommand;
        if (std.mem.eql(u8, argv[2], "list")) {
            command = .device_list;
        } else if (std.mem.eql(u8, argv[2], "revoke")) {
            command = .device_revoke;
        } else {
            return error.UnknownDeviceCommand;
        }
        option_start = 3;
    } else if (std.mem.eql(u8, first, "connect")) {
        if (argv.len <= 2) return error.MissingConnectCommand;
        if (std.mem.eql(u8, argv[2], "login")) {
            command = .connect_login;
        } else if (std.mem.eql(u8, argv[2], "link")) {
            command = .connect_link;
        } else if (std.mem.eql(u8, argv[2], "status")) {
            command = .connect_status;
        } else if (std.mem.eql(u8, argv[2], "unlink")) {
            command = .connect_unlink;
        } else if (std.mem.eql(u8, argv[2], "logout")) {
            command = .connect_logout;
        } else {
            return error.UnknownConnectCommand;
        }
        option_start = 3;
    } else if (std.mem.eql(u8, first, "providers")) {
        if (argv.len <= 2) return error.MissingProvidersCommand;
        if (!std.mem.eql(u8, argv[2], "status")) return error.UnknownProvidersCommand;
        command = .providers_status;
        option_start = 3;
    } else if (std.mem.eql(u8, first, "workspace")) {
        if (argv.len <= 2) return error.MissingWorkspaceCommand;
        if (std.mem.eql(u8, argv[2], "show")) {
            command = .workspace_show;
            option_start = 3;
        } else if (std.mem.eql(u8, argv[2], "bind")) {
            command = .workspace_bind;
            option_start = 3;
        } else if (std.mem.eql(u8, argv[2], "repository")) {
            if (argv.len <= 3) return error.MissingWorkspaceCommand;
            if (!std.mem.eql(u8, argv[3], "bind")) return error.UnknownWorkspaceCommand;
            command = .workspace_repository_bind;
            option_start = 4;
        } else {
            return error.UnknownWorkspaceCommand;
        }
    } else {
        return error.UnknownCommand;
    }

    var result: Options = .{ .command = command };
    var index = option_start;
    while (index < argv.len) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (result.json) return error.DuplicateJson;
            result.json = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--data-dir")) {
            if (result.data_dir != null) return error.DuplicateDataDir;
            if (index + 1 >= argv.len or argv[index + 1].len == 0) return error.MissingDataDir;
            result.data_dir = argv[index + 1];
            index += 2;
            continue;
        }
        if (command == .workspace_show or command == .workspace_bind or command == .workspace_repository_bind) {
            if (std.mem.eql(u8, arg, "--default")) {
                if (command != .workspace_repository_bind or result.repository_bind.set_default) {
                    return error.InvalidArguments;
                }
                result.repository_bind.set_default = true;
                index += 1;
                continue;
            }
            const value = try notifyOptionValue(argv, index);
            if (std.mem.eql(u8, arg, "--workspace") or std.mem.eql(u8, arg, "--workspace-id")) {
                if (result.repository_bind.workspace_id != null) return error.InvalidArguments;
                result.repository_bind.workspace_id = value;
            } else if (command != .workspace_show and std.mem.eql(u8, arg, "--label")) {
                if (result.repository_bind.label != null) return error.InvalidArguments;
                result.repository_bind.label = value;
            } else if (command != .workspace_show and std.mem.eql(u8, arg, "--root")) {
                if (result.repository_bind.root != null) return error.InvalidArguments;
                result.repository_bind.root = value;
            } else if (command == .workspace_repository_bind and
                (std.mem.eql(u8, arg, "--repository") or std.mem.eql(u8, arg, "--repository-id")))
            {
                if (result.repository_bind.repository_id != null) return error.InvalidArguments;
                result.repository_bind.repository_id = value;
            } else if (command == .workspace_repository_bind and std.mem.eql(u8, arg, "--vcs-identity")) {
                if (result.repository_bind.vcs_identity != null) return error.InvalidArguments;
                result.repository_bind.vcs_identity = value;
            } else if (command == .workspace_repository_bind and std.mem.eql(u8, arg, "--default-branch")) {
                if (result.repository_bind.default_branch != null) return error.InvalidArguments;
                result.repository_bind.default_branch = value;
            } else {
                return error.InvalidArguments;
            }
            index += 2;
            continue;
        }
        if (command == .pair_create or command == .pair_revoke or
            command == .device_revoke)
        {
            const value = try notifyOptionValue(argv, index);
            if (command == .pair_create and std.mem.eql(u8, arg, "--label")) {
                if (result.pair.label != null) return error.InvalidArguments;
                result.pair.label = value;
            } else if (command == .pair_create and std.mem.eql(u8, arg, "--expires")) {
                if (result.pair.expires_set) return error.InvalidArguments;
                result.pair.ttl_seconds = try parsePairingExpiry(value);
                result.pair.expires_set = true;
            } else if (command == .pair_create and std.mem.eql(u8, arg, "--scope")) {
                if (result.pair.scope_count >= result.pair.scopes.len) return error.InvalidArguments;
                _ = access_protocol.parseScope(value) catch return error.InvalidArguments;
                for (result.pair.scopes[0..result.pair.scope_count]) |existing| {
                    if (std.mem.eql(u8, existing, value)) return error.InvalidArguments;
                }
                result.pair.scopes[result.pair.scope_count] = value;
                result.pair.scope_count += 1;
            } else if ((command == .pair_revoke or command == .device_revoke) and
                std.mem.eql(u8, arg, "--id"))
            {
                if (result.pair.id != null) return error.InvalidArguments;
                result.pair.id = value;
            } else {
                return error.InvalidArguments;
            }
            index += 2;
            continue;
        }
        if (command == .connect_login or command == .connect_link) {
            const value = try notifyOptionValue(argv, index);
            if (command == .connect_login and std.mem.eql(u8, arg, "--control-plane")) {
                if (result.connect.control_plane_url != null) return error.InvalidArguments;
                result.connect.control_plane_url = value;
            } else if (command == .connect_login and std.mem.eql(u8, arg, "--credential-file")) {
                if (result.connect.credential_file != null) return error.InvalidArguments;
                result.connect.credential_file = value;
            } else if (command == .connect_link and std.mem.eql(u8, arg, "--descriptor-file")) {
                if (result.connect.descriptor_file != null) return error.InvalidArguments;
                result.connect.descriptor_file = value;
            } else {
                return error.InvalidArguments;
            }
            index += 2;
            continue;
        }
        if (command == .notify) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                result.notify.help = true;
                index += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--quiet")) {
                result.notify.quiet = true;
                index += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--clear")) {
                result.notify.clear = true;
                index += 1;
                continue;
            }

            const value = try notifyOptionValue(argv, index);
            if (std.mem.eql(u8, arg, "--session") or std.mem.eql(u8, arg, "--session-id")) {
                if (result.notify.session_id != null) return error.InvalidArguments;
                result.notify.session_id = value;
            } else if (std.mem.eql(u8, arg, "--workspace")) {
                if (result.notify.workspace_id != null) return error.InvalidArguments;
                result.notify.workspace_id = value;
            } else if (std.mem.eql(u8, arg, "--dock")) {
                if (result.notify.dock_id != null) return error.InvalidArguments;
                result.notify.dock_id = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments;
            } else if (std.mem.eql(u8, arg, "--pane")) {
                if (result.notify.pane_id != null) return error.InvalidArguments;
                result.notify.pane_id = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments;
            } else if (std.mem.eql(u8, arg, "--provider")) {
                if (result.notify.provider != null or !validNotifyProvider(value)) return error.InvalidArguments;
                result.notify.provider = value;
            } else if (std.mem.eql(u8, arg, "--title")) {
                if (result.notify.title != null) return error.InvalidArguments;
                result.notify.title = value;
            } else if (std.mem.eql(u8, arg, "--body")) {
                if (result.notify.body != null) return error.InvalidArguments;
                result.notify.body = value;
            } else if (std.mem.eql(u8, arg, "--status")) {
                if (result.notify.status != null or !validNotifyStatus(value)) return error.InvalidArguments;
                result.notify.status = value;
            } else if (std.mem.eql(u8, arg, "--label")) {
                if (result.notify.label != null) return error.InvalidArguments;
                result.notify.label = value;
            } else {
                return error.InvalidArguments;
            }
            index += 2;
            continue;
        }
        return error.InvalidArguments;
    }
    if ((command == .session_daemon_compat or command == .serve) and result.json) return error.JsonUnavailable;
    if (command == .workspace_show) {
        if (result.repository_bind.workspace_id == null) return error.InvalidArguments;
    } else if (command == .workspace_bind) {
        if (result.repository_bind.workspace_id == null or result.repository_bind.label == null or
            result.repository_bind.root == null)
        {
            return error.InvalidArguments;
        }
    } else if (command == .workspace_repository_bind) {
        if (result.repository_bind.workspace_id == null or result.repository_bind.repository_id == null or
            result.repository_bind.label == null or result.repository_bind.root == null or
            std.mem.eql(u8, result.repository_bind.repository_id.?, headless.store.PRIMARY_REPOSITORY_ID))
        {
            return error.InvalidArguments;
        }
    } else if (command == .pair_create) {
        if (result.pair.label) |label| {
            access_protocol.validateDeviceLabel(label) catch return error.InvalidArguments;
        }
    } else if (command == .pair_revoke) {
        const grant_id = result.pair.id orelse return error.InvalidArguments;
        access_protocol.validateGrantId(grant_id) catch return error.InvalidArguments;
    } else if (command == .device_revoke) {
        const device_id = result.pair.id orelse return error.InvalidArguments;
        access_protocol.validateDeviceId(device_id) catch return error.InvalidArguments;
    } else if (command == .connect_login) {
        const control_plane_url = result.connect.control_plane_url orelse return error.InvalidArguments;
        const credential_file = result.connect.credential_file orelse return error.InvalidArguments;
        connect_protocol.validateControlPlaneUrl(control_plane_url) catch return error.InvalidArguments;
        connect_protocol.validateCredentialFile(credential_file) catch return error.InvalidArguments;
    } else if (command == .connect_link) {
        if (result.connect.descriptor_file == null) return error.InvalidArguments;
    }
    return result;
}

fn parsePairingExpiry(value: []const u8) ParseError!u32 {
    if (value.len < 2) return error.InvalidArguments;
    const multiplier: u32 = switch (value[value.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 60 * 60,
        else => return error.InvalidArguments,
    };
    const amount = std.fmt.parseInt(u32, value[0 .. value.len - 1], 10) catch
        return error.InvalidArguments;
    const seconds = std.math.mul(u32, amount, multiplier) catch return error.InvalidArguments;
    access_protocol.validatePairingTtl(seconds) catch return error.InvalidArguments;
    return seconds;
}

fn notifyOptionValue(argv: []const []const u8, index: usize) ParseError![]const u8 {
    if (index + 1 >= argv.len or argv[index + 1].len == 0) return error.MissingOptionValue;
    return argv[index + 1];
}

fn writeParseError(io: std.Io, err: ParseError) !void {
    const message = switch (err) {
        error.DuplicateDataDir => "--data-dir may be provided only once",
        error.DuplicateJson => "--json may be provided only once",
        error.InvalidArguments => "invalid command arguments",
        error.JsonUnavailable => "serve does not support --json",
        error.MissingDataDir => "--data-dir requires a non-empty path",
        error.MissingOptionValue => "command option requires a non-empty value",
        error.MissingPairCommand => "pair requires create, list, or revoke",
        error.MissingDeviceCommand => "device requires list or revoke",
        error.MissingConnectCommand => "connect requires login, link, status, unlink, or logout",
        error.MissingProvidersCommand => "providers requires the status command",
        error.MissingWorkspaceCommand => "workspace requires show, bind, or repository bind",
        error.UnknownCommand => "unknown command",
        error.UnknownPairCommand => "unknown pair command",
        error.UnknownDeviceCommand => "unknown device command",
        error.UnknownConnectCommand => "unknown connect command",
        error.UnknownProvidersCommand => "unknown providers command",
        error.UnknownWorkspaceCommand => "unknown workspace command",
    };
    try writeStderr(io, "verde-daemon: {s}\n\n", .{message});
}

fn writeCommandError(
    io: std.Io,
    allocator: std.mem.Allocator,
    json: bool,
    data_dir: []const u8,
    err: anyerror,
) !void {
    const message = commandErrorMessage(err);
    if (json) {
        try writeJson(io, allocator, .{
            .ok = false,
            .error_code = @errorName(err),
            .error_message = message,
            .data_dir = data_dir,
        });
        return;
    }
    try writeStderr(io, "verde-daemon: {s}: {s}\n", .{ message, data_dir });
}

fn commandErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused, error.FileNotFound => "daemon is not running for data directory",
        error.ConnectionTimedOut => "daemon did not respond before the request deadline",
        error.EndpointInUse => "another daemon owns the data directory endpoint",
        error.InheritedSocketOverride => "unset VERDE_SESSIONIZER_SOCKET before using the standalone daemon CLI",
        error.AmbiguousNotifyTarget => "notify accepts either --data-dir or inherited VERDE_SESSIONIZER_SOCKET, not both",
        error.MissingNotifyTarget => "notify requires --data-dir outside a Verde-owned terminal",
        error.MissingNotifySession => "notify requires --session or VERDE_SESSION_ID",
        error.MissingNotifyStatus => "notify requires --status or --clear",
        error.InvalidNotifyStatus => "notify status must be idle, working, waiting, done, or error",
        error.InvalidNotifyProvider => "notify provider is not supported",
        error.InvalidNotifyIdentity => "notify dock or pane identity is invalid",
        error.InvalidArguments => "invalid command arguments",
        error.StoreUnavailable => "daemon store is unavailable",
        error.RuntimeIdentityMissing => "daemon did not return a runtime identity",
        error.RuntimeIdentityMismatch => "daemon runtime identity did not match",
        error.IncompatibleRuntimeProtocol, error.IncompatibleProtocolVersion => "daemon protocol is incompatible",
        error.IncompatibleAccessProtocol => "daemon access protocol is incompatible",
        error.IncompatibleConnectProtocol => "daemon Connect protocol is incompatible",
        error.InvalidAccessResponse => "daemon returned an invalid access administration response",
        error.CapabilityUnavailable => "daemon does not support this command",
        error.RemoteError => "daemon rejected the request",
        else => @errorName(err),
    };
}

fn commandErrorExitCode(err: anyerror) u8 {
    return switch (err) {
        error.CapabilityUnavailable,
        error.RemoteError,
        error.RuntimeIdentityMissing,
        error.RuntimeIdentityMismatch,
        error.IncompatibleRuntimeProtocol,
        error.IncompatibleProtocolVersion,
        error.IncompatibleAccessProtocol,
        error.IncompatibleConnectProtocol,
        error.InvalidAccessResponse,
        error.StoreUnavailable,
        error.InheritedSocketOverride,
        => 4,
        error.AmbiguousNotifyTarget,
        error.MissingNotifyTarget,
        error.MissingNotifySession,
        error.MissingNotifyStatus,
        error.InvalidNotifyStatus,
        error.InvalidNotifyProvider,
        error.InvalidNotifyIdentity,
        error.InvalidArguments,
        => 2,
        else => 3,
    };
}

fn printHelp(io: std.Io, stderr: bool) !void {
    const help =
        \\Usage:
        \\  verde-daemon init [--data-dir PATH] [--json]
        \\  verde-daemon serve [--data-dir PATH]
        \\  verde-daemon status [--data-dir PATH] [--json]
        \\  verde-daemon providers status [--data-dir PATH] [--json]
        \\  verde-daemon workspace show --workspace ID [--data-dir PATH] [--json]
        \\  verde-daemon workspace bind --workspace ID --label LABEL --root PATH [--data-dir PATH] [--json]
        \\  verde-daemon workspace repository bind --workspace ID --repository ID --label LABEL --root PATH [options]
        \\  verde-daemon pair create [--expires 10m] [--label TEXT] [--scope SCOPE]... [--data-dir PATH] [--json]
        \\  verde-daemon pair list [--data-dir PATH] [--json]
        \\  verde-daemon pair revoke --id ID [--data-dir PATH] [--json]
        \\  verde-daemon device list [--data-dir PATH] [--json]
        \\  verde-daemon device revoke --id ID [--data-dir PATH] [--json]
        \\  verde-daemon connect login --control-plane URL --credential-file PATH [--data-dir PATH] [--json]
        \\  verde-daemon connect link --descriptor-file PATH [--data-dir PATH] [--json]
        \\  verde-daemon connect status|unlink|logout [--data-dir PATH] [--json]
        \\  verde-daemon notify --status STATUS [options]
        \\  verde-daemon version [--json]
        \\  verde-daemon --help
        \\
        \\Exit codes:
        \\  0  Success
        \\  2  Invalid command or options
        \\  3  Startup or transport failure
        \\  4  Runtime protocol, capability, or store failure
        \\
        \\VERDE_SESSIONIZER_SOCKET must be unset for administrative commands.
        \\Notify accepts that inherited endpoint only inside a Verde-owned terminal;
        \\otherwise notify requires an explicit --data-dir.
        \\Workspace commands require a running daemon; binding requires an existing checkout.
        \\Pair/device commands require a running daemon. A created pairing token is
        \\printed exactly once; store it as a secret. Omitting --scope grants the
        \\documented single-user default scope set. Expiry accepts s, m, or h (max 1h).
        \\Repository bind options: --vcs-identity URL, --default-branch NAME,
        \\--default, --data-dir PATH, and --json. No checkout data is modified.
        \\Connect login imports a token from an owner-only file; credentials are
        \\never accepted directly in argv. Link consumes a public endpoint descriptor.
        \\
    ;
    if (stderr) return writeStderr(io, "{s}", .{help});
    return writeStdout(io, "{s}", .{help});
}

fn printNotifyHelp(io: std.Io) !void {
    try writeStdout(io,
        \\Usage:
        \\  verde-daemon notify --status idle|working|waiting|done|error [options]
        \\  verde-daemon notify --clear [options]
        \\
        \\Options:
        \\  --quiet                 Suppress successful human-readable output
        \\  --json                  Print a JSON mutation receipt
        \\  --title TEXT            Record the provider event title
        \\  --body TEXT             Record the provider event body
        \\  --provider NAME         codex|claude|cursor|opencode|amp|pi|fx|grok
        \\  --session ID            Override VERDE_SESSION_ID
        \\  --workspace ID          Override VERDE_WORKSPACE_ID
        \\  --dock ID               Override VERDE_DOCK_ID
        \\  --pane ID               Override VERDE_PANE_ID
        \\  --data-dir PATH         Target a daemon explicitly outside its terminal
        \\
        \\A Verde-owned terminal supplies VERDE_SESSIONIZER_SOCKET automatically.
        \\Outside one, --data-dir is required; no desktop/default endpoint is inferred.
        \\
    , .{});
}

fn writeJson(io: std.Io, allocator: std.mem.Allocator, value: anytype) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
    defer allocator.free(encoded);
    try writeStdout(io, "{s}\n", .{encoded});
}

fn writeStdout(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const stdout_file = std.Io.File.stdout();
    var buffer: [16 * 1024]u8 = undefined;
    var writer = stdout_file.writerStreaming(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print(fmt, args);
}

/// Write an explicitly secret-bearing one-time result and clear the complete
/// staging buffer after flush. Ordinary output must continue through
/// `writeStdout` so secret output remains an auditable boundary.
fn writeSensitiveStdout(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const stdout_file = std.Io.File.stdout();
    var buffer: [16 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, buffer[0..]);
    var writer = stdout_file.writerStreaming(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn writeStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const stderr_file = std.Io.File.stderr();
    var buffer: [4 * 1024]u8 = undefined;
    var writer = stderr_file.writerStreaming(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print(fmt, args);
}

test "daemon CLI parses every public command" {
    const compat_options = try parseArgs(&.{ "verde-daemon", "__session-daemon", "--data-dir", "/srv/verde" });
    try std.testing.expectEqual(Command.session_daemon_compat, compat_options.command);

    const init_options = try parseArgs(&.{ "verde-daemon", "init", "--data-dir", "/srv/verde", "--json" });
    try std.testing.expectEqual(Command.init, init_options.command);
    try std.testing.expectEqualStrings("/srv/verde", init_options.data_dir.?);
    try std.testing.expect(init_options.json);

    const serve_options = try parseArgs(&.{ "verde-daemon", "serve", "--data-dir", "/srv/verde" });
    try std.testing.expectEqual(Command.serve, serve_options.command);
    try std.testing.expect(!serve_options.json);

    const status_options = try parseArgs(&.{ "verde-daemon", "status", "--json" });
    try std.testing.expectEqual(Command.status, status_options.command);
    try std.testing.expect(status_options.json);

    const provider_options = try parseArgs(&.{ "verde-daemon", "providers", "status", "--json" });
    try std.testing.expectEqual(Command.providers_status, provider_options.command);
    try std.testing.expect(provider_options.json);

    const pair_create = try parseArgs(&.{
        "verde-daemon",
        "pair",
        "create",
        "--expires",
        "10m",
        "--label",
        "Laptop",
        "--scope",
        "runtime:read",
        "--scope",
        "chat:write",
        "--json",
    });
    try std.testing.expectEqual(Command.pair_create, pair_create.command);
    try std.testing.expectEqual(@as(u32, 600), pair_create.pair.ttl_seconds);
    try std.testing.expectEqualStrings("Laptop", pair_create.pair.label.?);
    try std.testing.expectEqual(@as(usize, 2), pair_create.pair.scope_count);
    try std.testing.expect(pair_create.json);

    const grant_id = "0123456789abcdef0123456789abcdef";
    const pair_revoke = try parseArgs(&.{ "verde-daemon", "pair", "revoke", "--id", grant_id });
    try std.testing.expectEqual(Command.pair_revoke, pair_revoke.command);
    try std.testing.expectEqualStrings(grant_id, pair_revoke.pair.id.?);
    try std.testing.expectEqual(Command.pair_list, (try parseArgs(&.{ "verde-daemon", "pair", "list" })).command);

    const device_id = "fedcba9876543210fedcba9876543210";
    const device_revoke = try parseArgs(&.{ "verde-daemon", "device", "revoke", "--id", device_id });
    try std.testing.expectEqual(Command.device_revoke, device_revoke.command);
    try std.testing.expectEqualStrings(device_id, device_revoke.pair.id.?);
    try std.testing.expectEqual(Command.device_list, (try parseArgs(&.{ "verde-daemon", "device", "list" })).command);

    const connect_login = try parseArgs(&.{
        "verde-daemon",
        "connect",
        "login",
        "--control-plane",
        "https://connect.example.test",
        "--credential-file",
        "/run/user/1000/verde-connect-token",
        "--json",
    });
    try std.testing.expectEqual(Command.connect_login, connect_login.command);
    try std.testing.expectEqualStrings("https://connect.example.test", connect_login.connect.control_plane_url.?);
    try std.testing.expectEqualStrings("/run/user/1000/verde-connect-token", connect_login.connect.credential_file.?);
    try std.testing.expectEqual(Command.connect_link, (try parseArgs(&.{
        "verde-daemon", "connect", "link", "--descriptor-file", "/tmp/runtime-descriptor.json",
    })).command);
    try std.testing.expectEqual(Command.connect_status, (try parseArgs(&.{ "verde-daemon", "connect", "status" })).command);
    try std.testing.expectEqual(Command.connect_unlink, (try parseArgs(&.{ "verde-daemon", "connect", "unlink" })).command);
    try std.testing.expectEqual(Command.connect_logout, (try parseArgs(&.{ "verde-daemon", "connect", "logout" })).command);

    const workspace_show = try parseArgs(&.{
        "verde-daemon",
        "workspace",
        "show",
        "--workspace",
        "workspace-1",
        "--json",
    });
    try std.testing.expectEqual(Command.workspace_show, workspace_show.command);
    try std.testing.expectEqualStrings("workspace-1", workspace_show.repository_bind.workspace_id.?);
    try std.testing.expect(workspace_show.json);

    const workspace_bind = try parseArgs(&.{
        "verde-daemon",
        "workspace",
        "bind",
        "--workspace",
        "workspace-1",
        "--label",
        "Workspace one",
        "--root",
        "/workspace/one",
        "--json",
    });
    try std.testing.expectEqual(Command.workspace_bind, workspace_bind.command);
    try std.testing.expectEqualStrings("workspace-1", workspace_bind.repository_bind.workspace_id.?);
    try std.testing.expectEqualStrings("Workspace one", workspace_bind.repository_bind.label.?);
    try std.testing.expectEqualStrings("/workspace/one", workspace_bind.repository_bind.root.?);

    const repository_bind = try parseArgs(&.{
        "verde-daemon",
        "workspace",
        "repository",
        "bind",
        "--workspace-id",
        "workspace-1",
        "--repository-id",
        "repo-api",
        "--label",
        "API",
        "--root",
        "/workspace/api",
        "--vcs-identity",
        "https://example.com/org/api.git",
        "--default-branch",
        "main",
        "--default",
    });
    try std.testing.expectEqual(Command.workspace_repository_bind, repository_bind.command);
    try std.testing.expectEqualStrings("repo-api", repository_bind.repository_bind.repository_id.?);
    try std.testing.expect(repository_bind.repository_bind.set_default);

    const notify_options = try parseArgs(&.{
        "verde-daemon",
        "notify",
        "--quiet",
        "--status",
        "working",
        "--title",
        "Running tests",
        "--provider",
        "codex",
    });
    try std.testing.expectEqual(Command.notify, notify_options.command);
    try std.testing.expect(notify_options.notify.quiet);
    try std.testing.expectEqualStrings("working", notify_options.notify.status.?);
    try std.testing.expectEqualStrings("Running tests", notify_options.notify.title.?);
    try std.testing.expectEqualStrings("codex", notify_options.notify.provider.?);
}

test "daemon CLI rejects ambiguous or unsupported options" {
    try std.testing.expectError(
        error.DuplicateDataDir,
        parseArgs(&.{ "verde-daemon", "status", "--data-dir", "a", "--data-dir", "b" }),
    );
    try std.testing.expectError(error.MissingDataDir, parseArgs(&.{ "verde-daemon", "init", "--data-dir" }));
    try std.testing.expectError(error.MissingProvidersCommand, parseArgs(&.{ "verde-daemon", "providers" }));
    try std.testing.expectError(error.MissingWorkspaceCommand, parseArgs(&.{ "verde-daemon", "workspace" }));
    try std.testing.expectError(error.MissingPairCommand, parseArgs(&.{ "verde-daemon", "pair" }));
    try std.testing.expectError(error.MissingDeviceCommand, parseArgs(&.{ "verde-daemon", "device" }));
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "verde-daemon", "workspace", "show", "--label", "No workspace" }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "verde-daemon", "workspace", "bind", "--workspace", "workspace-1" }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{
            "verde-daemon",
            "workspace",
            "repository",
            "bind",
            "--workspace",
            "workspace-1",
            "--repository",
            "primary",
            "--label",
            "Primary",
            "--root",
            "/workspace/one",
        }),
    );
    try std.testing.expectError(error.JsonUnavailable, parseArgs(&.{ "verde-daemon", "serve", "--json" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "verde-daemon", "status", "--wat" }));
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "verde-daemon", "pair", "create", "--expires", "61m" }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{
            "verde-daemon",
            "pair",
            "create",
            "--scope",
            "runtime:read",
            "--scope",
            "runtime:read",
        }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "verde-daemon", "pair", "revoke", "--id", "not-an-id" }),
    );
    try std.testing.expectError(
        error.MissingOptionValue,
        parseArgs(&.{ "verde-daemon", "notify", "--status" }),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        parseArgs(&.{ "verde-daemon", "notify", "--status", "busy" }),
    );
}

test "daemon notify parses explicit identity and data directory" {
    const options = try parseArgs(&.{
        "verde-daemon",
        "notify",
        "--data-dir",
        "/srv/verde",
        "--session-id",
        "opaque:session/id",
        "--workspace",
        "workspace-1",
        "--dock",
        "4",
        "--pane",
        "9",
        "--status",
        "done",
        "--provider",
        "fx",
        "--json",
    });
    try std.testing.expectEqualStrings("/srv/verde", options.data_dir.?);
    try std.testing.expectEqualStrings("opaque:session/id", options.notify.session_id.?);
    try std.testing.expectEqualStrings("workspace-1", options.notify.workspace_id.?);
    try std.testing.expectEqual(@as(?u32, 4), options.notify.dock_id);
    try std.testing.expectEqual(@as(?u32, 9), options.notify.pane_id);
    try std.testing.expectEqualStrings("done", options.notify.status.?);
    try std.testing.expectEqualStrings("fx", options.notify.provider.?);
    try std.testing.expect(options.json);
}

test "daemon notify target never falls back implicitly" {
    try std.testing.expectEqual(NotifyTargetMode.data_dir, try selectNotifyTargetMode(true, false));
    try std.testing.expectEqual(NotifyTargetMode.inherited_endpoint, try selectNotifyTargetMode(false, true));
    try std.testing.expectError(error.MissingNotifyTarget, selectNotifyTargetMode(false, false));
    try std.testing.expectError(error.AmbiguousNotifyTarget, selectNotifyTargetMode(true, true));
}

test "daemon notify recognizes all lifecycle providers and statuses" {
    const providers = [_][]const u8{ "codex", "claude", "cursor", "opencode", "amp", "pi", "fx", "grok" };
    for (providers) |provider| {
        try std.testing.expect(validNotifyProvider(provider));
    }
    const statuses = [_][]const u8{ "idle", "working", "waiting", "done", "error" };
    for (statuses) |status| {
        try std.testing.expect(validNotifyStatus(status));
    }
    try std.testing.expect(!validNotifyProvider("unknown"));
    try std.testing.expect(!validNotifyStatus("busy"));
}

test "signal watcher recognizes only an accepted prepare-shutdown result" {
    const accepted =
        \\{"jsonrpc":"2.0","id":1,"result":{"accepted":true,"safe_to_exit":true}}
    ;
    const refused =
        \\{"jsonrpc":"2.0","id":1,"result":{"accepted":false,"safe_to_exit":false}}
    ;
    const inconsistent =
        \\{"jsonrpc":"2.0","id":1,"result":{"accepted":true,"safe_to_exit":false}}
    ;
    const remote_error =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":"invalid_state","message":"busy"}}
    ;
    try std.testing.expect(prepareShutdownAccepted(std.testing.allocator, accepted));
    try std.testing.expect(!prepareShutdownAccepted(std.testing.allocator, refused));
    try std.testing.expect(!prepareShutdownAccepted(std.testing.allocator, inconsistent));
    try std.testing.expect(!prepareShutdownAccepted(std.testing.allocator, remote_error));
    try std.testing.expect(!prepareShutdownAccepted(std.testing.allocator, "not json"));
}
