//! Non-blocking supervision for one desktop-owned loopback SSH relay.

const std = @import("std");
const builtin = @import("builtin");
const process = @import("../platform/process.zig");
const gateway_transport = @import("gateway_transport.zig");
const profile = @import("profile.zig");
const ssh_tunnel = @import("ssh_tunnel.zig");

const POLL_INTERVAL_MS: u64 = 10;
const RELAY_KERNEL_BACKLOG: u31 = 2;
const RELAY_TIMEOUT_MS: i64 = gateway_transport.MAX_TIMEOUT_MS + 5_000;
const RELAY_IO_BUFFER_BYTES: usize = 16 * 1024;
const RELAY_DIRECTION_MAX_BYTES: usize = gateway_transport.MAX_RPC_FRAME_BYTES + 64 * 1024;
const RELAY_CHILD_EXIT_POLLS: usize = 50;
const RELAY_CHILD_TERM_POLLS: usize = 50;

const AcceptResult = union(enum) {
    connection: std.Io.net.Server.AcceptError!std.Io.net.Stream,
    stop: std.Io.Cancelable!void,
};

pub const Lifecycle = enum {
    stopped,
    starting,
    running,
    stopping,
    exited,
    failed,
};

pub const Failure = enum {
    spawn,
    readiness,
    wait,
};

pub const Snapshot = struct {
    lifecycle: Lifecycle,
    pid: ?u32 = null,
    term: ?std.process.Child.Term = null,
    failure: ?Failure = null,
};

const Shared = struct {
    allocator: std.mem.Allocator,
    argv: ssh_tunnel.OwnedArgv,
    local_port: u16,
    backend: Backend,
    mutex: std.atomic.Mutex = .unlocked,
    stop_requested: std.atomic.Value(bool) = .init(false),
    bearer_leases: std.atomic.Value(usize) = .init(0),
    accept_permits: std.atomic.Value(usize) = .init(0),
    snapshot: Snapshot = .{ .lifecycle = .starting },
    release_on_exit: bool = false,

    fn lock(self: *Shared) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Shared) void {
        self.mutex.unlock();
    }
};

pub const Outcome = union(enum) {
    stopped,
    exited: std.process.Child.Term,
    failed: Failure,
};

/// Move-only lifetime guard for a bearer-bearing loopback call. While held,
/// stop/deinit may cancel active relay IO but cannot release the bound port.
pub const BearerLease = struct {
    context: ?*anyopaque,

    pub fn release(self: *BearerLease) void {
        const raw_context = self.context orelse return;
        const shared: *Shared = @ptrCast(@alignCast(raw_context));
        // At most one lease exists per profile. If no local connection
        // consumed its one-shot permit, revoke it before releasing lifetime.
        shared.accept_permits.store(0, .release);
        const previous = shared.bearer_leases.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        self.context = null;
    }

    pub fn take(self: *BearerLease) BearerLease {
        const result = self.*;
        self.context = null;
        return result;
    }
};

/// Restricted state channel supplied to an injected tunnel backend.
/// Backends run exclusively on the supervisor worker, never the render thread.
pub const Control = struct {
    shared: *Shared,

    pub fn stopRequested(self: Control) bool {
        return self.shared.stop_requested.load(.acquire);
    }

    pub fn markSpawned(self: Control, pid: u32) void {
        self.shared.lock();
        defer self.shared.unlock();
        self.shared.snapshot.pid = pid;
        const stop_requested = self.stopRequested();
        if (stop_requested) self.shared.snapshot.lifecycle = .stopping;
        // Closes the spawn->publish race: a stop that won just before this
        // publication still signals the newly owned POSIX group immediately.
        if (stop_requested and self.shared.backend.owns_published_process_tree) {
            requestPosixTreeTermination(pid);
        }
    }

    /// Marks the desktop-owned loopback listener ready. Production calls this
    /// only while it continuously owns the exact numeric port; SSH child
    /// liveness is deliberately not used as a readiness proof.
    pub fn markForwardReady(self: Control, pid: ?u32) void {
        self.shared.lock();
        defer self.shared.unlock();
        self.shared.snapshot.pid = pid;
        self.shared.snapshot.lifecycle = if (self.stopRequested()) .stopping else .running;
    }

    pub fn clearActiveChild(self: Control, pid: u32) void {
        self.shared.lock();
        defer self.shared.unlock();
        if (self.shared.snapshot.pid == pid) self.shared.snapshot.pid = null;
    }

    fn pollActiveChild(
        self: Control,
        io: std.Io,
        child: *process.OwnedChild,
        pid: u32,
    ) !?std.process.Child.Term {
        self.shared.lock();
        defer self.shared.unlock();
        // stop() uses this same lock for its numeric signal. OwnedChild.poll
        // keeps an exited POSIX leader unreaped until its group is killed, and
        // this publication is cleared before another thread can signal again.
        const term = try child.poll(io);
        if (term != null and self.shared.snapshot.pid == pid) {
            self.shared.snapshot.pid = null;
        }
        return term;
    }
};

/// Injectable process backend. The production backend launches argv directly;
/// tests can exercise lifecycle behavior without opening SSH or a network.
pub const Backend = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, std.Io, []const []const u8, u16, Control) Outcome,
    /// For a non-null context, retain must keep the pointed storage alive until
    /// the matching release, including after Supervisor.deinit returns.
    retain_context: ?*const fn (?*anyopaque) void = null,
    release_context: ?*const fn (?*anyopaque) void = null,
    /// Production publishes the leader of a process-owned group. Injected
    /// backends leave this false so diagnostic fake PIDs are never signaled.
    owns_published_process_tree: bool = false,

    pub fn system() Backend {
        return .{ .run = runSystem, .owns_published_process_tree = true };
    }

    fn validateLifetime(self: Backend) !void {
        if (self.context == null) return;
        if (self.retain_context == null or self.release_context == null) {
            return error.UnsafeTunnelBackendLifetime;
        }
    }

    fn retainContext(self: Backend) void {
        if (self.retain_context) |retain| retain(self.context);
    }

    fn releaseContext(self: Backend) void {
        if (self.release_context) |release| release(self.context);
    }
};

/// Owns one worker and its SSH child tree. `stop` is non-blocking; the worker
/// performs graceful termination, escalation, and reaping off the UI thread.
pub const Supervisor = struct {
    shared: ?*Shared = null,
    worker: ?std.Thread = null,

    pub fn init() Supervisor {
        return .{};
    }

    /// Starts a tunnel using the production process backend.
    pub fn start(
        self: *Supervisor,
        allocator: std.mem.Allocator,
        io: std.Io,
        ssh: profile.SshTunnel,
        local_port: u16,
    ) !void {
        return self.startWithBackend(allocator, io, ssh, local_port, .system());
    }

    /// Starts with an injected backend for hermetic process-boundary tests.
    /// Non-null contexts must provide retain/release hooks because `deinit` may
    /// hand a non-terminal worker to process-lifetime cleanup.
    pub fn startWithBackend(
        self: *Supervisor,
        allocator: std.mem.Allocator,
        io: std.Io,
        ssh: profile.SshTunnel,
        local_port: u16,
        backend: Backend,
    ) !void {
        _ = allocator;
        _ = io;
        if (self.shared != null or self.worker != null) return error.AlreadyStarted;
        try backend.validateLifetime();

        // A stopped desktop owner may return before a stubborn OS process has
        // been reaped, so worker state cannot depend on the owner's allocator.
        const worker_allocator = std.heap.page_allocator;
        var argv = try ssh_tunnel.buildArgvAlloc(worker_allocator, ssh);
        errdefer argv.deinit(worker_allocator);
        const shared = try worker_allocator.create(Shared);
        errdefer worker_allocator.destroy(shared);
        backend.retainContext();
        errdefer backend.releaseContext();
        shared.* = .{
            .allocator = worker_allocator,
            .argv = argv,
            .local_port = local_port,
            .backend = backend,
        };
        const worker = try std.Thread.spawn(.{}, workerMain, .{shared});
        self.shared = shared;
        self.worker = worker;
    }

    /// Requests termination without waiting for SSH or its descendants.
    pub fn stop(self: *Supervisor) void {
        const shared = self.shared orelse return;
        shared.stop_requested.store(true, .release);
        shared.lock();
        switch (shared.snapshot.lifecycle) {
            .starting, .running => shared.snapshot.lifecycle = .stopping,
            .stopped, .stopping, .exited, .failed => {},
        }
        // This is one non-blocking signal syscall. Reaping and escalation stay
        // on the worker, but deinit no longer depends on that worker running
        // before the desktop process exits. Holding the publication lock makes
        // the numeric signal mutually exclusive with poll/reap/unpublication.
        if (shared.backend.owns_published_process_tree) {
            if (shared.snapshot.pid) |pid| requestPosixTreeTermination(pid);
        }
        shared.unlock();
    }

    pub fn getSnapshot(self: *const Supervisor) Snapshot {
        const shared = self.shared orelse return .{ .lifecycle = .stopped };
        shared.lock();
        defer shared.unlock();
        return shared.snapshot;
    }

    /// Pins the exact desktop listener while a copied bearer can still attempt
    /// a connection. The returned guard must be moved to the bounded worker.
    pub fn acquireBearerLease(self: *Supervisor) !BearerLease {
        const shared = self.shared orelse return error.RelayNotReady;
        shared.lock();
        defer shared.unlock();
        if (shared.stop_requested.load(.acquire) or shared.snapshot.lifecycle != .running) {
            return error.RelayNotReady;
        }
        if (shared.bearer_leases.load(.acquire) != 0) return error.BearerLeaseAlreadyHeld;
        shared.bearer_leases.store(1, .release);
        shared.accept_permits.store(1, .release);
        return .{ .context = shared };
    }

    /// Releases a worker only after it has published a terminal lifecycle.
    /// This is the non-blocking collection path for render-thread owners.
    pub fn collectIfTerminal(self: *Supervisor) bool {
        const lifecycle = self.getSnapshot().lifecycle;
        switch (lifecycle) {
            .stopped, .exited, .failed => {},
            .starting, .running, .stopping => return false,
        }
        self.deinit();
        return true;
    }

    /// Stops and releases ownership without waiting. A non-terminal worker is
    /// detached and frees its argv/state after exact process-tree reaping.
    /// Repeated calls are safe.
    pub fn deinit(self: *Supervisor) void {
        const shared = self.shared orelse return;
        self.stop();
        shared.lock();
        const terminal = switch (shared.snapshot.lifecycle) {
            .stopped, .exited, .failed => true,
            .starting, .running, .stopping => false,
        };
        if (!terminal) shared.release_on_exit = true;
        shared.unlock();

        if (self.worker) |worker| {
            if (terminal) worker.join() else worker.detach();
        }
        if (terminal) releaseShared(shared);
        self.shared = null;
        self.worker = null;
    }
};

fn workerMain(shared: *Shared) void {
    // The process-lifetime worker is the sole owner and user of this Io. No
    // caller Io, allocator, or thread-bound driver survives `start`.
    var threaded: std.Io.Threaded = .init(shared.allocator, .{});
    const control: Control = .{ .shared = shared };
    const outcome = shared.backend.run(
        shared.backend.context,
        threaded.io(),
        shared.argv.argv,
        shared.local_port,
        control,
    );
    // Injected backends can finish before a bearer worker. Retaining Shared
    // here makes immediate Manager.deinit safe for every backend, not only the
    // production listener implementation.
    while (shared.bearer_leases.load(.acquire) != 0) {
        std.Io.sleep(threaded.io(), .fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {};
    }
    // Publish a terminal snapshot only after the worker-owned Io has torn
    // down, so collectIfTerminal's join cannot inherit an Io wait.
    threaded.deinit();

    shared.lock();
    shared.snapshot.pid = null;
    shared.snapshot.term = null;
    shared.snapshot.failure = null;
    switch (outcome) {
        .stopped => shared.snapshot.lifecycle = .stopped,
        .exited => |term| {
            shared.snapshot.lifecycle = .exited;
            shared.snapshot.term = term;
        },
        .failed => |failure| {
            shared.snapshot.lifecycle = .failed;
            shared.snapshot.failure = failure;
        },
    }
    const release_on_exit = shared.release_on_exit;
    shared.unlock();
    if (release_on_exit) releaseShared(shared);
}

fn releaseShared(shared: *Shared) void {
    shared.backend.releaseContext();
    shared.argv.deinit(shared.allocator);
    shared.allocator.destroy(shared);
}

fn runSystem(
    _: ?*anyopaque,
    io: std.Io,
    argv: []const []const u8,
    local_port: u16,
    control: Control,
) Outcome {
    if (control.stopRequested()) return .stopped;

    const address = std.Io.net.IpAddress.parse("127.0.0.1", local_port) catch {
        return .{ .failed = .readiness };
    };
    var listener = address.listen(io, .{
        .kernel_backlog = RELAY_KERNEL_BACKLOG,
        .reuse_address = false,
    }) catch return .{ .failed = .readiness };
    defer listener.deinit(io);
    // This defer runs before listener.deinit (LIFO), preserving continuous
    // ownership until every copied bearer has left its bounded worker.
    defer waitForBearerLeases(io, control);
    control.markForwardReady(null);

    while (!control.stopRequested()) {
        var select_buffer: [2]AcceptResult = undefined;
        var select = std.Io.Select(AcceptResult).init(io, &select_buffer);
        select.async(.connection, std.Io.net.Server.accept, .{ &listener, io });
        select.async(.stop, waitForListenerStop, .{ io, control });
        // accept can return an owned Stream, so cancellation must inspect and
        // close a raced result instead of discarding it.
        defer cancelAcceptSelect(&select, io);

        const selected = select.await() catch return .{ .failed = .wait };
        switch (selected) {
            .stop => |stop_result| {
                stop_result catch return .{ .failed = .wait };
                return .stopped;
            },
            .connection => |connection_result| {
                var connection = connection_result catch {
                    if (control.stopRequested()) return .stopped;
                    return .{ .failed = .wait };
                };
                if (!consumeAcceptPermit(control)) {
                    connection.close(io);
                    continue;
                }
                relayConnection(io, argv, &connection, control) catch |err| switch (err) {
                    error.RelaySpawnFailed => return .{ .failed = .spawn },
                    error.Stopped => if (control.stopRequested()) return .stopped,
                    else => {},
                };
            },
        }
    }
    return .stopped;
}

fn cancelAcceptSelect(
    select: *std.Io.Select(AcceptResult),
    io: std.Io,
) void {
    while (select.cancel()) |canceled| {
        switch (canceled) {
            .connection => |connection_result| {
                const connection = connection_result catch continue;
                connection.close(io);
            },
            .stop => {},
        }
    }
}

fn waitForStopRequested(io: std.Io, control: Control) std.Io.Cancelable!void {
    while (!control.stopRequested()) {
        try std.Io.sleep(io, .fromMilliseconds(POLL_INTERVAL_MS), .awake);
    }
}

fn waitForListenerStop(io: std.Io, control: Control) std.Io.Cancelable!void {
    while (!control.stopRequested() or control.shared.bearer_leases.load(.acquire) != 0) {
        try std.Io.sleep(io, .fromMilliseconds(POLL_INTERVAL_MS), .awake);
    }
}

fn waitForBearerLeases(io: std.Io, control: Control) void {
    while (control.shared.bearer_leases.load(.acquire) != 0) {
        std.Io.sleep(io, .fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {};
    }
}

fn consumeAcceptPermit(control: Control) bool {
    return control.shared.accept_permits.cmpxchgStrong(
        1,
        0,
        .acq_rel,
        .acquire,
    ) == null;
}

fn requestPosixTreeTermination(pid: u32) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    process.terminateProcessIdTree(pid) catch {};
}

fn relayConnection(
    io: std.Io,
    argv: []const []const u8,
    connection: *std.Io.net.Stream,
    control: Control,
) !void {
    defer connection.close(io);
    if (control.stopRequested()) return error.Stopped;

    var child = try spawnRelayChild(io, argv);
    defer child.kill(io);
    const pid = child.processId() orelse return error.RelaySpawnFailed;
    control.markSpawned(pid);
    defer control.clearActiveChild(pid);

    var client_read_buffer: [RELAY_IO_BUFFER_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &client_read_buffer);
    var ssh_write_buffer: [RELAY_IO_BUFFER_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &ssh_write_buffer);
    var ssh_read_buffer: [RELAY_IO_BUFFER_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &ssh_read_buffer);
    var client_write_buffer: [RELAY_IO_BUFFER_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &client_write_buffer);

    var client_reader = connection.reader(io, &client_read_buffer);
    var ssh_writer = child.child.stdin.?.writer(io, &ssh_write_buffer);
    var ssh_reader = child.child.stdout.?.reader(io, &ssh_read_buffer);
    var client_writer = connection.writer(io, &client_write_buffer);
    try pumpRelayStreams(
        io,
        &client_reader.interface,
        &ssh_writer.interface,
        &ssh_reader.interface,
        &client_writer.interface,
        RELAY_TIMEOUT_MS,
        control,
        &child,
        closeChildStdin,
    );

    if (child.child.stdin) |stdin| {
        stdin.close(io);
        child.child.stdin = null;
    }
    const finish = try finishRelayChild(
        io,
        &child,
        pid,
        control,
        RELAY_CHILD_EXIT_POLLS,
        RELAY_CHILD_TERM_POLLS,
    );
    return switch (finish) {
        .exited => |term| switch (term) {
            .exited => |code| if (code == 0) {} else error.SshFailed,
            else => error.SshFailed,
        },
        .stopped => error.Stopped,
        .forced => error.SshDidNotExit,
    };
}

fn spawnRelayChild(io: std.Io, argv: []const []const u8) !process.OwnedChild {
    return process.spawn(std.heap.page_allocator, io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        // OpenSSH diagnostics can contain host/user configuration. Ignoring
        // stderr keeps logs both secret-free and strictly bounded at zero.
        .stderr = .ignore,
        .own_process_tree = true,
        .hide_window = true,
    }) catch return error.RelaySpawnFailed;
}

const ChildFinish = union(enum) {
    exited: std.process.Child.Term,
    stopped,
    forced,
};

fn finishRelayChild(
    io: std.Io,
    child: *process.OwnedChild,
    pid: u32,
    control: Control,
    exit_polls: usize,
    term_polls: usize,
) !ChildFinish {
    var stopping = control.stopRequested();
    for (0..exit_polls) |_| {
        if (try control.pollActiveChild(io, child, pid)) |term| return .{ .exited = term };
        if (control.stopRequested()) {
            stopping = true;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(POLL_INTERVAL_MS), .awake);
    }

    child.terminateTree();
    for (0..term_polls) |_| {
        if (try control.pollActiveChild(io, child, pid)) |term| {
            return if (stopping) .stopped else .{ .exited = term };
        }
        if (control.stopRequested()) stopping = true;
        try std.Io.sleep(io, .fromMilliseconds(POLL_INTERVAL_MS), .awake);
    }
    // Remove numeric publication before OwnedChild's exact KILL+reap. A
    // concurrent stop can no longer target this pid after it becomes reusable.
    control.clearActiveChild(pid);
    child.kill(io);
    return if (stopping) .stopped else .forced;
}

const RequestCompleteFn = *const fn (*anyopaque, std.Io) void;

fn closeChildStdin(raw_context: *anyopaque, io: std.Io) void {
    const child: *process.OwnedChild = @ptrCast(@alignCast(raw_context));
    if (child.child.stdin) |stdin| {
        stdin.close(io);
        child.child.stdin = null;
    }
}

fn pumpRelayStreams(
    io: std.Io,
    request_reader: *std.Io.Reader,
    request_writer: *std.Io.Writer,
    response_reader: *std.Io.Reader,
    response_writer: *std.Io.Writer,
    timeout_ms: i64,
    control: Control,
    request_context: *anyopaque,
    request_complete: RequestCompleteFn,
) !void {
    const RelayResult = union(enum) {
        request: anyerror!void,
        response: anyerror!void,
        timeout: std.Io.Cancelable!void,
        stop: std.Io.Cancelable!void,
    };
    var select_buffer: [4]RelayResult = undefined;
    var select = std.Io.Select(RelayResult).init(io, &select_buffer);
    select.async(.request, streamBounded, .{
        request_reader,
        request_writer,
        RELAY_DIRECTION_MAX_BYTES,
    });
    select.async(.response, streamBounded, .{
        response_reader,
        response_writer,
        RELAY_DIRECTION_MAX_BYTES,
    });
    select.async(.timeout, std.Io.sleep, .{
        io,
        std.Io.Duration.fromMilliseconds(timeout_ms),
        .awake,
    });
    select.async(.stop, waitForStopRequested, .{ io, control });
    var select_active = true;
    defer if (select_active) select.cancelDiscard();

    while (true) {
        const selected = try select.await();
        switch (selected) {
            .request => |request_result| {
                try request_result;
                request_complete(request_context, io);
            },
            .response => |response_result| {
                try response_result;
                try response_writer.flush();
                // The HTTP client can keep its write side open while waiting
                // for the response. Cancel that request copy before waiting on
                // SSH, otherwise child.wait can deadlock behind live Select IO.
                select.cancelDiscard();
                select_active = false;
                return;
            },
            .timeout => |timeout_result| {
                try timeout_result;
                return error.RelayTimedOut;
            },
            .stop => |stop_result| {
                try stop_result;
                return error.Stopped;
            },
        }
    }
}

fn streamBounded(reader: *std.Io.Reader, writer: *std.Io.Writer, max_bytes: usize) !void {
    var remaining = max_bytes;
    while (remaining > 0) {
        const count = reader.stream(writer, .limited(remaining)) catch |err| switch (err) {
            error.EndOfStream => {
                try writer.flush();
                return;
            },
            else => return err,
        };
        if (count == 0) return error.NoProgress;
        // Both relay writers are deliberately buffered. Flush each copied
        // chunk so a small HTTP message reaches a peer that keeps its write
        // side open while awaiting the opposite direction.
        try writer.flush();
        remaining -= count;
    }
    return error.RelayDirectionTooLarge;
}

const FlushProbeWriter = struct {
    interface: std.Io.Writer = undefined,
    buffer: [16]u8 = undefined,
    flushed: bool = false,

    fn init(self: *FlushProbeWriter) void {
        self.interface = .{
            .vtable = &.{
                .drain = std.Io.Writer.unreachableDrain,
                .flush = flush,
            },
            .buffer = &self.buffer,
        };
    }

    fn flush(raw_writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *FlushProbeWriter = @alignCast(@fieldParentPtr("interface", raw_writer));
        self.flushed = true;
        raw_writer.end = 0;
    }
};

const BufferedThenCheckFlushReader = struct {
    interface: std.Io.Reader = undefined,
    payload: [4]u8 = "ping".*,
    flushed: *const bool = undefined,

    fn init(self: *BufferedThenCheckFlushReader, flushed: *const bool) void {
        self.flushed = flushed;
        self.interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = &self.payload,
            .seek = 0,
            .end = self.payload.len,
        };
    }

    fn stream(
        raw_reader: *std.Io.Reader,
        _: *std.Io.Writer,
        _: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *BufferedThenCheckFlushReader = @alignCast(
            @fieldParentPtr("interface", raw_reader),
        );
        if (!self.flushed.*) return error.ReadFailed;
        return error.EndOfStream;
    }
};

test "relay flushes a small chunk before waiting for more input" {
    var writer: FlushProbeWriter = .{};
    writer.init();
    var reader: BufferedThenCheckFlushReader = .{};
    reader.init(&writer.flushed);

    try streamBounded(&reader.interface, &writer.interface, 64);
    try std.testing.expect(writer.flushed);
}

fn waitForLifecycle(supervisor: *const Supervisor, expected: Lifecycle) !void {
    for (0..2_000) |_| {
        if (supervisor.getSnapshot().lifecycle == expected) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestExpectedLifecycle;
}

const BlockingFake = struct {
    observed_argv: std.atomic.Value(bool) = .init(false),
    observed_port: std.atomic.Value(u16) = .init(0),
    stop_observed: std.atomic.Value(bool) = .init(false),
    allow_exit: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    retained: std.atomic.Value(usize) = .init(0),

    fn retain(raw_context: ?*anyopaque) void {
        const self: *BlockingFake = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchAdd(1, .acq_rel);
    }

    fn release(raw_context: ?*anyopaque) void {
        const self: *BlockingFake = @ptrCast(@alignCast(raw_context.?));
        _ = self.retained.fetchSub(1, .acq_rel);
    }

    fn run(
        raw_context: ?*anyopaque,
        io: std.Io,
        argv: []const []const u8,
        local_port: u16,
        control: Control,
    ) Outcome {
        const self: *BlockingFake = @ptrCast(@alignCast(raw_context.?));
        var safe = argv.len > 1 and std.mem.eql(u8, argv[0], "ssh");
        for (argv) |arg| {
            if (std.mem.indexOf(u8, arg, "bearer-secret") != null) safe = false;
            if (std.mem.eql(u8, arg, "-L")) safe = false;
        }
        self.observed_argv.store(safe, .release);
        self.observed_port.store(local_port, .release);
        control.markForwardReady(42_424);
        while (!control.stopRequested()) {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        }
        self.stop_observed.store(true, .release);
        while (!self.allow_exit.load(.acquire)) {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
        }
        self.finished.store(true, .release);
        return .stopped;
    }
};

test "stop is non-blocking and lifecycle is observable" {
    var host = "configured-host".*;
    var user = "verde".*;
    const ssh: profile.SshTunnel = .{
        .host = host[0..],
        .user = user[0..],
        .port = 22,
        .remote_gateway_port = 7420,
    };
    var fake: BlockingFake = .{};
    var supervisor = Supervisor.init();
    defer supervisor.deinit();
    try supervisor.startWithBackend(std.testing.allocator, std.testing.io, ssh, 43_127, .{
        .context = &fake,
        .run = BlockingFake.run,
        .retain_context = BlockingFake.retain,
        .release_context = BlockingFake.release,
    });

    try waitForLifecycle(&supervisor, .running);
    const running = supervisor.getSnapshot();
    try std.testing.expectEqual(@as(?u32, 42_424), running.pid);
    try std.testing.expect(fake.observed_argv.load(.acquire));
    try std.testing.expectEqual(@as(u16, 43_127), fake.observed_port.load(.acquire));

    supervisor.stop();
    supervisor.stop();
    try std.testing.expectEqual(Lifecycle.stopping, supervisor.getSnapshot().lifecycle);
    while (!fake.stop_observed.load(.acquire)) {
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    // The worker is deliberately still running here, proving stop did not join it.
    try std.testing.expectEqual(Lifecycle.stopping, supervisor.getSnapshot().lifecycle);
    fake.allow_exit.store(true, .release);
    try waitForLifecycle(&supervisor, .stopped);
    try std.testing.expectEqual(@as(?u32, null), supervisor.getSnapshot().pid);

    supervisor.deinit();
    supervisor.deinit();
    try std.testing.expectEqual(Lifecycle.stopped, supervisor.getSnapshot().lifecycle);
    try std.testing.expectEqual(@as(usize, 0), fake.retained.load(.acquire));
}

fn exitedFake(_: ?*anyopaque, _: std.Io, _: []const []const u8, _: u16, control: Control) Outcome {
    control.markForwardReady(1234);
    return .{ .exited = .{ .exited = 7 } };
}

test "natural tunnel exit remains distinguishable from an intentional stop" {
    var host = "configured-host".*;
    const ssh: profile.SshTunnel = .{
        .host = host[0..],
        .user = null,
        .port = 22,
        .remote_gateway_port = 7420,
    };
    var supervisor = Supervisor.init();
    defer supervisor.deinit();
    try supervisor.startWithBackend(std.testing.allocator, std.testing.io, ssh, 43_127, .{
        .run = exitedFake,
    });
    try waitForLifecycle(&supervisor, .exited);
    const snapshot = supervisor.getSnapshot();
    try std.testing.expectEqual(@as(?u32, null), snapshot.pid);
    try std.testing.expectEqual(@as(u8, 7), snapshot.term.?.exited);
}

fn failedFake(_: ?*anyopaque, _: std.Io, _: []const []const u8, _: u16, _: Control) Outcome {
    return .{ .failed = .spawn };
}

test "backend failures expose only a bounded category" {
    var host = "configured-host".*;
    const ssh: profile.SshTunnel = .{
        .host = host[0..],
        .user = null,
        .port = 22,
        .remote_gateway_port = 7420,
    };
    var supervisor = Supervisor.init();
    defer supervisor.deinit();
    try supervisor.startWithBackend(std.testing.allocator, std.testing.io, ssh, 43_127, .{
        .run = failedFake,
    });
    try waitForLifecycle(&supervisor, .failed);
    const snapshot = supervisor.getSnapshot();
    try std.testing.expectEqual(Failure.spawn, snapshot.failure.?);
    try std.testing.expectEqual(@as(?std.process.Child.Term, null), snapshot.term);
}

fn testShared() Shared {
    return .{
        .allocator = std.testing.allocator,
        .argv = .{ .argv = &.{} },
        .local_port = 43_127,
        .backend = .{ .run = failedFake },
        .snapshot = .{ .lifecycle = .running },
    };
}

test "accepted relay sockets require and consume one bearer permit" {
    var shared = testShared();
    const control: Control = .{ .shared = &shared };
    try std.testing.expect(!consumeAcceptPermit(control));

    var supervisor: Supervisor = .{ .shared = &shared };
    var lease = try supervisor.acquireBearerLease();
    supervisor.shared = null;
    defer lease.release();
    try std.testing.expect(consumeAcceptPermit(control));
    try std.testing.expect(!consumeAcceptPermit(control));
}

test "missing SSH executable is a spawn failure" {
    try std.testing.expectError(
        error.RelaySpawnFailed,
        spawnRelayChild(std.testing.io, &.{"verde-test-ssh-does-not-exist"}),
    );
}

const BlockingReader = struct {
    io: std.Io = undefined,
    interface: std.Io.Reader = undefined,
    buffer: [1]u8 = undefined,
    canceled: std.atomic.Value(bool) = .init(false),

    fn init(self: *BlockingReader, io: std.Io) void {
        self.io = io;
        self.interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(
        raw_reader: *std.Io.Reader,
        _: *std.Io.Writer,
        _: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *BlockingReader = @alignCast(@fieldParentPtr("interface", raw_reader));
        std.Io.sleep(self.io, .fromSeconds(5), .awake) catch {
            self.canceled.store(true, .release);
            return error.ReadFailed;
        };
        return error.EndOfStream;
    }
};

fn markRequestComplete(raw_context: *anyopaque, _: std.Io) void {
    const completed: *std.atomic.Value(bool) = @ptrCast(@alignCast(raw_context));
    completed.store(true, .release);
}

test "response completion cancels a client request that keeps its write side open" {
    var shared = testShared();
    const control: Control = .{ .shared = &shared };
    var request_reader: BlockingReader = .{};
    request_reader.init(std.testing.io);
    var response_reader = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nok");
    var request_buffer: [8]u8 = undefined;
    var response_buffer: [8]u8 = undefined;
    var request_writer: std.Io.Writer.Discarding = .init(&request_buffer);
    var response_writer: std.Io.Writer.Discarding = .init(&response_buffer);
    var request_completed: std.atomic.Value(bool) = .init(false);

    try pumpRelayStreams(
        std.testing.io,
        &request_reader.interface,
        &request_writer.writer,
        &response_reader,
        &response_writer.writer,
        1_000,
        control,
        &request_completed,
        markRequestComplete,
    );
    try std.testing.expect(request_reader.canceled.load(.acquire));
    try std.testing.expect(!request_completed.load(.acquire));
}

fn expectPumpCanceledBy(stop_immediately: bool) !void {
    var shared = testShared();
    if (stop_immediately) shared.stop_requested.store(true, .release);
    const control: Control = .{ .shared = &shared };
    var request_reader: BlockingReader = .{};
    request_reader.init(std.testing.io);
    var response_reader: BlockingReader = .{};
    response_reader.init(std.testing.io);
    var request_buffer: [8]u8 = undefined;
    var response_buffer: [8]u8 = undefined;
    var request_writer: std.Io.Writer.Discarding = .init(&request_buffer);
    var response_writer: std.Io.Writer.Discarding = .init(&response_buffer);
    var request_completed: std.atomic.Value(bool) = .init(false);

    const result = pumpRelayStreams(
        std.testing.io,
        &request_reader.interface,
        &request_writer.writer,
        &response_reader.interface,
        &response_writer.writer,
        if (stop_immediately) 1_000 else 1,
        control,
        &request_completed,
        markRequestComplete,
    );
    if (stop_immediately) {
        try std.testing.expectError(error.Stopped, result);
    } else {
        try std.testing.expectError(error.RelayTimedOut, result);
    }
    try std.testing.expect(request_reader.canceled.load(.acquire));
    try std.testing.expect(response_reader.canceled.load(.acquire));
}

test "relay timeout cancels both stream operations before cleanup" {
    try expectPumpCanceledBy(false);
}

test "relay stop cancels both stream operations before cleanup" {
    try expectPumpCanceledBy(true);
}

test "stdout EOF cannot wedge a TERM-ignoring relay child" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    var shared = testShared();
    const control: Control = .{ .shared = &shared };
    const script =
        \\trap '' TERM
        \\exec 1>&-
        \\while :; do sleep 1; done
    ;
    var child = try process.spawn(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "sh", "-c", script },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .own_process_tree = true,
    });
    defer if (child.child.id != null) child.kill(std.testing.io);
    const pid = child.processId() orelse return error.TestChildDidNotStart;
    control.markSpawned(pid);
    defer control.clearActiveChild(pid);

    var read_buffer: [8]u8 = undefined;
    var reader = child.child.stdout.?.reader(std.testing.io, &read_buffer);
    var discard_buffer: [8]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buffer);
    while (true) {
        _ = reader.interface.stream(&discard.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
    }

    const finish = try finishRelayChild(std.testing.io, &child, pid, control, 2, 2);
    try std.testing.expect(finish == .forced);
    try std.testing.expect(child.child.id == null);
}

test "terminal relay poll unpublishes its pid before returning" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    var shared = testShared();
    const control: Control = .{ .shared = &shared };
    var child = try process.spawn(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .own_process_tree = true,
    });
    defer if (child.child.id != null) child.kill(std.testing.io);
    const pid = child.processId() orelse return error.TestChildDidNotStart;
    control.markSpawned(pid);
    defer control.clearActiveChild(pid);

    for (0..2_000) |_| {
        if (try control.pollActiveChild(std.testing.io, &child, pid)) |_| {
            try std.testing.expectEqual(@as(?u32, null), shared.snapshot.pid);
            return;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestChildDidNotExit;
}

test "deinit hands a non-terminal worker exact cleanup without joining" {
    var host = "configured-host".*;
    const ssh: profile.SshTunnel = .{
        .host = host[0..],
        .user = null,
        .port = 22,
        .remote_gateway_port = 7420,
    };
    var fake: BlockingFake = .{};
    var supervisor = Supervisor.init();
    try supervisor.startWithBackend(std.testing.allocator, std.testing.io, ssh, 43_127, .{
        .context = &fake,
        .run = BlockingFake.run,
        .retain_context = BlockingFake.retain,
        .release_context = BlockingFake.release,
    });
    try waitForLifecycle(&supervisor, .running);

    // The fake refuses to finish until after deinit returns.
    supervisor.deinit();
    try std.testing.expectEqual(Lifecycle.stopped, supervisor.getSnapshot().lifecycle);
    while (!fake.stop_observed.load(.acquire)) {
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    fake.allow_exit.store(true, .release);
    while (!fake.finished.load(.acquire)) {
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    for (0..2_000) |_| {
        if (fake.retained.load(.acquire) == 0) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, 0), fake.retained.load(.acquire));
}

test "detachable backend contexts require an owned lifetime" {
    var host = "configured-host".*;
    const ssh: profile.SshTunnel = .{
        .host = host[0..],
        .user = null,
        .port = 22,
        .remote_gateway_port = 7420,
    };
    var fake: BlockingFake = .{};
    var supervisor = Supervisor.init();
    defer supervisor.deinit();
    try std.testing.expectError(
        error.UnsafeTunnelBackendLifetime,
        supervisor.startWithBackend(std.testing.allocator, std.testing.io, ssh, 43_127, .{
            .context = &fake,
            .run = BlockingFake.run,
        }),
    );
}
