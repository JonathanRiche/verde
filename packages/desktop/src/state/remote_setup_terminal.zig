//! Carries a provider-setup command's terminal on a remote runtime over that
//! runtime's terminal RPC lane (`session.create/tail/write/resize/kill`).
//!
//! Mirrors client_core's `terminal_pump`: one request in flight, output
//! offsets commit only after the VT applied the bytes, input goes out in
//! UTF-8-safe chunks of at most 4096 bytes and is never replayed after an
//! uncertain delivery. Every wait has a finite deadline, and a stopped
//! command keeps trying to deliver its `session.kill` for a bounded time.

const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const manager = @import("../runtime/manager.zig");

const log = std.log.scoped(.remote_setup_terminal);

pub const RpcTicket = manager.RpcTicket;
pub const RpcCallResult = manager.RpcCallResult;

pub const WRITE_CHUNK_BYTES: usize = 4096;
pub const TAIL_MAX_BYTES: u32 = 64 * 1024;
/// Tail cadence right after output or input, and while the command is idle.
pub const ACTIVE_TAIL_MS: i64 = 150;
pub const IDLE_TAIL_MS: i64 = 700;
pub const INTERACTIVE_WINDOW_MS: i64 = 3_000;
/// A request still unanswered after this is abandoned as undelivered.
pub const REQUEST_DEADLINE_MS: i64 = 45_000;
/// Without one successful round trip for this long the setup gives up.
pub const STALL_DEADLINE_MS: i64 = 60_000;
/// How long a stopped command keeps trying to deliver its `session.kill`.
pub const KILL_DEADLINE_MS: i64 = 15_000;
/// Retry delay when the lane is busy (an SSH relay serves one request).
pub const BUSY_RETRY_MS: i64 = 100;
pub const FAILURE_RETRY_MS: i64 = 1_000;
/// Bound on probe output kept in `Pump.capture`.
pub const CAPTURE_MAX_BYTES: usize = 64 * 1024;

pub const Phase = enum {
    creating,
    running,
    /// The remote process exited and all of its output was applied.
    exited,
    /// The terminal could not be started or reached; see `failure`.
    failed,
    /// A stopped command's kill was delivered, or its deadline passed.
    done,
};

const Request = enum { none, create, tail, write, resize, kill };

pub const Pump = struct {
    profile_id: []u8,
    session_id: []u8,
    /// argv sent to `session.create`; `argv_storage` owns the shell string.
    argv_storage: []u8,
    label: []const u8,
    phase: Phase = .creating,
    ticket: ?RpcTicket = null,
    inflight: Request = .none,
    request_started_ms: i64 = 0,
    create_sent: bool = false,
    /// Next `session.tail` offset; advances only after output was applied.
    offset: u64 = 0,
    tail_due_ms: i64 = 0,
    retry_at_ms: i64 = 0,
    interactive_until_ms: i64 = 0,
    last_success_ms: i64,
    kill_requested: bool = false,
    kill_deadline_ms: i64 = 0,
    /// The process reported exit; one more tail drains its last output.
    exit_seen: bool = false,
    exit_status: ?u32 = null,
    /// Static, user-facing reason when `phase == .failed`.
    failure: ?[]const u8 = null,
    /// Non-interactive probes keep their output here (bounded, never logged)
    /// instead of drawing it; null for setup terminals.
    capture: ?*std.ArrayList(u8) = null,

    pub fn create(
        allocator: std.mem.Allocator,
        profile_id: []const u8,
        session_id: []const u8,
        shell: []const u8,
        label: []const u8,
        now_ms: i64,
    ) !*Pump {
        const self = try allocator.create(Pump);
        errdefer allocator.destroy(self);
        const owned_profile = try allocator.dupe(u8, profile_id);
        errdefer allocator.free(owned_profile);
        const owned_session = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_session);
        const owned_shell = try allocator.dupe(u8, shell);
        self.* = .{
            .profile_id = owned_profile,
            .session_id = owned_session,
            .argv_storage = owned_shell,
            .label = label,
            .last_success_ms = now_ms,
        };
        return self;
    }

    /// Frees the pump. An in-flight ticket is handed back to the lane so its
    /// result never blocks later terminal requests.
    pub fn destroy(self: *Pump, allocator: std.mem.Allocator, service: anytype) void {
        if (self.ticket) |ticket| service.abandonTerminalRpc(ticket);
        allocator.free(self.profile_id);
        allocator.free(self.session_id);
        allocator.free(self.argv_storage);
        allocator.destroy(self);
    }

    /// True once the pump has nothing left to send for a stopped command.
    pub fn finished(self: *const Pump) bool {
        return self.ticket == null and switch (self.phase) {
            .exited, .failed, .done => true,
            .creating, .running => false,
        };
    }

    /// Stops the remote command: sends `session.kill` (after a create still
    /// in flight), bounded by `KILL_DEADLINE_MS`.
    pub fn requestKill(self: *Pump, now_ms: i64) void {
        if (self.kill_requested) return;
        self.kill_requested = true;
        self.kill_deadline_ms = now_ms +| KILL_DEADLINE_MS;
        if (self.phase == .creating and !self.create_sent) self.phase = .done;
    }

    /// One frame of upkeep: collects the finished request, then starts the
    /// next one. `dock` is null once the terminal view is gone (a stopped
    /// command still delivering its kill). Returns true when anything changed.
    pub fn step(self: *Pump, allocator: std.mem.Allocator, service: anytype, dock: ?*terminal.Dock, now_ms: i64) bool {
        var changed = false;
        if (self.ticket) |ticket| {
            const taken = service.takeTerminalRpcResult(ticket) catch |err| blk: {
                log.warn("remote setup terminal result lost: {s}", .{@errorName(err)});
                break :blk @as(?RpcCallResult, .canceled);
            };
            if (taken) |value| {
                var result = value;
                defer result.deinit();
                self.ticket = null;
                const request = self.inflight;
                self.inflight = .none;
                self.handleResult(allocator, request, &result, dock, now_ms);
                changed = true;
            } else if (now_ms -| self.request_started_ms > REQUEST_DEADLINE_MS) {
                service.abandonTerminalRpc(ticket);
                self.ticket = null;
                const request = self.inflight;
                self.inflight = .none;
                self.requestFailed(request, dock, now_ms);
                changed = true;
            } else {
                return false;
            }
        }
        if (self.kill_requested and self.phase != .exited and self.phase != .failed and self.phase != .done and now_ms >= self.kill_deadline_ms) {
            self.phase = .done;
            return true;
        }
        switch (self.phase) {
            .exited, .failed, .done => return changed,
            .creating, .running => {},
        }
        if ((self.phase == .creating or !self.kill_requested) and now_ms -| self.last_success_ms > STALL_DEADLINE_MS) {
            self.fail(dock, "Lost the connection to the runtime.");
            return true;
        }
        if (now_ms < self.retry_at_ms) return changed;
        return self.startNext(allocator, service, dock, now_ms) or changed;
    }

    fn startNext(self: *Pump, allocator: std.mem.Allocator, service: anytype, dock: ?*terminal.Dock, now_ms: i64) bool {
        if (self.phase == .creating) {
            const grid = if (dock) |d| d.activeGridSize() else null;
            if (dock) |d| if (d.remoteIo()) |io| {
                io.resize_pending = false;
            };
            const argv = [_][]const u8{ "bash", "-lc", self.argv_storage };
            return self.begin(service, .create, "session.create", .{
                .id = self.session_id,
                .command = &argv,
                .label = self.label,
                .cols = if (grid) |g| g.cols else 100,
                .rows = if (grid) |g| g.rows else 30,
            }, now_ms);
        }
        if (self.kill_requested) {
            return self.begin(service, .kill, "session.kill", .{ .id = self.session_id }, now_ms);
        }
        const io: ?*terminal.RemoteIo = if (dock) |d| d.remoteIo() else null;
        if (io) |queue| {
            if (queue.resize_pending) {
                if (dock.?.activeGridSize()) |grid| {
                    queue.resize_pending = false;
                    return self.begin(service, .resize, "session.resize", .{
                        .id = self.session_id,
                        .cols = grid.cols,
                        .rows = grid.rows,
                    }, now_ms);
                }
                queue.resize_pending = false;
            }
            if (queue.input.items.len > 0) {
                const chunk_len = utf8ChunkLen(queue.input.items, WRITE_CHUNK_BYTES);
                const chunk = queue.input.items[0..chunk_len];
                if (chunk_len == 0 or !std.unicode.utf8ValidateSlice(chunk)) {
                    // Never send bytes the JSON request cannot carry intact.
                    log.warn("dropping {d} undeliverable remote terminal input bytes", .{queue.input.items.len});
                    queue.input.clearRetainingCapacity();
                    return false;
                }
                const started = self.begin(service, .write, "session.write", .{ .id = self.session_id, .text = chunk }, now_ms);
                // The request carries its own copy; these bytes are never sent twice.
                if (self.ticket != null) queue.input.replaceRangeAssumeCapacity(0, chunk_len, &.{});
                return started;
            }
        }
        if (now_ms < self.tail_due_ms) return false;
        _ = allocator;
        return self.begin(service, .tail, "session.tail", .{
            .id = self.session_id,
            .offset = self.offset,
            .max_bytes = TAIL_MAX_BYTES,
        }, now_ms);
    }

    fn begin(self: *Pump, service: anytype, request: Request, method: []const u8, params: anytype, now_ms: i64) bool {
        const ticket = service.beginTerminalRpc(self.profile_id, method, params) catch |err| {
            const failure: anyerror = err;
            self.retry_at_ms = now_ms +| switch (failure) {
                error.RuntimeRpcBusy, error.RuntimeRpcResultPending => BUSY_RETRY_MS,
                else => FAILURE_RETRY_MS,
            };
            return false;
        };
        self.ticket = ticket;
        self.inflight = request;
        self.request_started_ms = now_ms;
        if (request == .create) self.create_sent = true;
        return false;
    }

    fn handleResult(self: *Pump, allocator: std.mem.Allocator, request: Request, result: *RpcCallResult, dock: ?*terminal.Dock, now_ms: i64) void {
        const response = switch (result.*) {
            .response => |response| response,
            .failed, .canceled => return self.requestFailed(request, dock, now_ms),
        };
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.json, .{}) catch {
            return self.requestFailed(request, dock, now_ms);
        };
        defer parsed.deinit();
        const root = if (parsed.value == .object) parsed.value.object else return self.requestFailed(request, dock, now_ms);
        // Any answer from the runtime proves the channel works.
        self.last_success_ms = now_ms;
        if (root.get("error") != null) return self.requestRejected(request, dock, now_ms);
        const value = root.get("result") orelse return self.requestFailed(request, dock, now_ms);
        switch (request) {
            .none => {},
            .create => {
                const session = objectField(value, "session") orelse return self.fail(dock, "The runtime did not start the terminal.");
                const id = stringField(session, "id") orelse "";
                if (!std.mem.eql(u8, id, self.session_id)) return self.fail(dock, "The runtime did not start the terminal.");
                self.phase = .running;
                self.tail_due_ms = now_ms;
                self.interactive_until_ms = now_ms +| INTERACTIVE_WINDOW_MS;
            },
            .tail => self.applyTail(allocator, value, dock, now_ms),
            .write => {
                if (boolField(value, "accepted") orelse false) {
                    // An accepted key must not wait behind the idle cadence.
                    self.interactive_until_ms = now_ms +| INTERACTIVE_WINDOW_MS;
                    self.tail_due_ms = now_ms;
                } else {
                    self.dropQueuedInput(dock);
                }
            },
            .resize => self.tail_due_ms = now_ms,
            .kill => self.phase = .done,
        }
    }

    fn applyTail(self: *Pump, allocator: std.mem.Allocator, value: std.json.Value, dock: ?*terminal.Dock, now_ms: i64) void {
        const next = uintField(value, "next_offset") orelse return self.fail(dock, "The runtime sent an unreadable terminal update.");
        const text = stringField(value, "text") orelse return self.fail(dock, "The runtime sent an unreadable terminal update.");
        const running = boolField(value, "running") orelse return self.fail(dock, "The runtime sent an unreadable terminal update.");
        // A ring gap (or a restarted ring) skips bytes: replay from a parser
        // boundary without answering its terminal queries again.
        const window_start = uintField(value, "offset") orelse self.offset;
        const gap = next < self.offset or window_start > self.offset;
        if (self.capture) |buffer| {
            const room = CAPTURE_MAX_BYTES -| buffer.items.len;
            buffer.appendSlice(allocator, text[0..@min(text.len, room)]) catch {};
        }
        if (dock) |d| d.applyRemoteOutput(allocator, text, gap) catch |err| {
            log.warn("remote setup terminal output apply failed: {s}", .{@errorName(err)});
        };
        self.offset = next;
        if (!running) {
            if (self.exit_seen or text.len == 0) {
                self.exit_status = if (uintField(value, "exit_status")) |status| std.math.cast(u32, status) else null;
                self.phase = .exited;
                if (dock) |d| d.finishRemoteSession(self.exit_status);
                return;
            }
            self.exit_seen = true;
            self.tail_due_ms = now_ms;
            return;
        }
        const active = text.len > 0 or now_ms < self.interactive_until_ms;
        self.tail_due_ms = now_ms +| if (active) ACTIVE_TAIL_MS else IDLE_TAIL_MS;
    }

    /// The runtime answered with a JSON-RPC error.
    fn requestRejected(self: *Pump, request: Request, dock: ?*terminal.Dock, now_ms: i64) void {
        switch (request) {
            .none, .resize => {},
            .create => self.fail(dock, "The runtime refused to start a terminal for this device."),
            // The session is gone (removed or never started).
            .tail => self.fail(dock, "The terminal on the runtime ended unexpectedly."),
            .write => self.dropQueuedInput(dock),
            .kill => self.phase = .done,
        }
        _ = now_ms;
    }

    /// No answer arrived (transport failure, cancel, or deadline).
    fn requestFailed(self: *Pump, request: Request, dock: ?*terminal.Dock, now_ms: i64) void {
        self.retry_at_ms = now_ms +| FAILURE_RETRY_MS;
        switch (request) {
            // A repeated create with the same id attaches instead of
            // starting a second process, so it is safe to retry.
            .none, .create, .tail, .kill => {},
            // Delivery is uncertain: never send the rest after it.
            .write => self.dropQueuedInput(dock),
            .resize => if (dock) |d| if (d.remoteIo()) |io| {
                io.resize_pending = true;
            },
        }
    }

    fn dropQueuedInput(_: *Pump, dock: ?*terminal.Dock) void {
        const d = dock orelse return;
        const io = d.remoteIo() orelse return;
        io.input.clearRetainingCapacity();
    }

    fn fail(self: *Pump, dock: ?*terminal.Dock, message: []const u8) void {
        self.phase = .failed;
        self.failure = message;
        if (dock) |d| d.finishRemoteSession(null);
    }
};

/// Longest prefix of `bytes` no longer than `limit` that does not split a
/// UTF-8 sequence.
pub fn utf8ChunkLen(bytes: []const u8, limit: usize) usize {
    var end = @min(bytes.len, limit);
    while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .object) field else null;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn boolField(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .bool) field.bool else null;
}

fn uintField(value: std.json.Value, key: []const u8) ?u64 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .integer => |number| std.math.cast(u64, number),
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

// ---- tests ----------------------------------------------------------------

/// Scripted terminal lane: records each request and answers the next one
/// with a queued result body (or leaves it in flight when none is queued).
const FakeLane = struct {
    allocator: std.mem.Allocator,
    methods: std.ArrayList([]const u8) = .empty,
    params: std.ArrayList([]u8) = .empty,
    replies: std.ArrayList(?[]const u8) = .empty,
    busy: bool = false,
    next_id: u64 = 1,
    inflight: ?u64 = null,
    abandoned: usize = 0,

    fn deinit(self: *FakeLane) void {
        for (self.params.items) |item| self.allocator.free(item);
        self.params.deinit(self.allocator);
        self.methods.deinit(self.allocator);
        self.replies.deinit(self.allocator);
    }

    fn beginTerminalRpc(self: *FakeLane, _: []const u8, method: []const u8, params: anytype) !RpcTicket {
        if (self.busy or self.inflight != null) return error.RuntimeRpcBusy;
        try self.methods.append(self.allocator, method);
        try self.params.append(self.allocator, try std.json.Stringify.valueAlloc(self.allocator, params, .{}));
        self.inflight = self.next_id;
        self.next_id += 1;
        return .{ .id = self.inflight.? };
    }

    fn takeTerminalRpcResult(self: *FakeLane, ticket: RpcTicket) !?RpcCallResult {
        if (self.inflight != ticket.id) return error.UnknownRuntimeRpcTicket;
        if (self.replies.items.len == 0) return null;
        const reply = self.replies.orderedRemove(0);
        self.inflight = null;
        const body = reply orelse return .canceled;
        const json = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},{s}}}", .{ ticket.id, body });
        return .{ .response = .{ .allocator = self.allocator, .json = json } };
    }

    fn abandonTerminalRpc(self: *FakeLane, ticket: RpcTicket) void {
        if (self.inflight == ticket.id) {
            self.inflight = null;
            self.abandoned += 1;
        }
    }

    fn lastMethod(self: *const FakeLane) []const u8 {
        return self.methods.items[self.methods.items.len - 1];
    }

    fn lastParams(self: *const FakeLane) []const u8 {
        return self.params.items[self.params.items.len - 1];
    }
};

fn testDock(allocator: std.mem.Allocator) !*terminal.Dock {
    const dock = try allocator.create(terminal.Dock);
    errdefer allocator.destroy(dock);
    dock.* = try terminal.Dock.init(allocator);
    dock.remote_backend = true;
    try dock.restartWithProfile(allocator, "~", .{ .kind = .custom, .label = "Sign in" });
    return dock;
}

test "remote setup terminal creates, tails with committed offsets, and reports exit" {
    const allocator = std.testing.allocator;
    var lane: FakeLane = .{ .allocator = allocator };
    defer lane.deinit();
    const dock = try testDock(allocator);
    defer {
        dock.deinit(allocator);
        allocator.destroy(dock);
    }
    const pump = try Pump.create(allocator, "cloud", "verde-setup-1", "claude auth login", "Sign in", 0);
    defer pump.destroy(allocator, &lane);

    _ = pump.step(allocator, &lane, dock, 0);
    try std.testing.expectEqualStrings("session.create", lane.lastMethod());
    try std.testing.expect(std.mem.indexOf(u8, lane.lastParams(), "[\"bash\",\"-lc\",\"claude auth login\"]") != null);
    try lane.replies.append(allocator, "\"result\":{\"created\":true,\"session\":{\"id\":\"verde-setup-1\",\"running\":true}}");
    _ = pump.step(allocator, &lane, dock, 10);
    try std.testing.expectEqual(Phase.running, pump.phase);
    try std.testing.expectEqualStrings("session.tail", lane.lastMethod());
    try std.testing.expect(std.mem.indexOf(u8, lane.lastParams(), "\"offset\":0") != null);

    try lane.replies.append(allocator, "\"result\":{\"id\":\"verde-setup-1\",\"running\":true,\"text\":\"Open https://example.test/code\\r\\n\",\"offset\":0,\"next_offset\":32}");
    _ = pump.step(allocator, &lane, dock, 20);
    try std.testing.expectEqual(@as(u64, 32), pump.offset);
    // The frame loop polls the dock, which refreshes what is drawn.
    try std.testing.expect(try dock.poll(allocator));
    const screen = (try dock.activeScreenTextAlloc(allocator)).?;
    defer allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "https://example.test/code") != null);

    // Typed input goes out once, before the next tail, and wakes the tail.
    _ = dock.writeInputToActivePane("ABCD-1234\r") catch unreachable;
    _ = pump.step(allocator, &lane, dock, 1_000);
    try std.testing.expectEqualStrings("session.write", lane.lastMethod());
    try std.testing.expect(std.mem.indexOf(u8, lane.lastParams(), "ABCD-1234") != null);
    try std.testing.expectEqual(@as(usize, 0), dock.remoteIo().?.input.items.len);
    try lane.replies.append(allocator, "\"result\":{\"accepted\":true,\"bytes\":10,\"running\":true}");
    _ = pump.step(allocator, &lane, dock, 1_010);
    try std.testing.expectEqualStrings("session.tail", lane.lastMethod());
    try std.testing.expect(std.mem.indexOf(u8, lane.lastParams(), "\"offset\":32") != null);

    // Exit with trailing output drains once more before reporting the status.
    try lane.replies.append(allocator, "\"result\":{\"id\":\"verde-setup-1\",\"running\":false,\"exit_status\":0,\"text\":\"Done\\r\\n\",\"offset\":32,\"next_offset\":38}");
    _ = pump.step(allocator, &lane, dock, 1_020);
    try std.testing.expectEqual(Phase.running, pump.phase);
    try std.testing.expect(dock.activeSessionSnapshot().?.running);
    try lane.replies.append(allocator, "\"result\":{\"id\":\"verde-setup-1\",\"running\":false,\"exit_status\":0,\"text\":\"\",\"offset\":38,\"next_offset\":38}");
    _ = pump.step(allocator, &lane, dock, 1_030);
    try std.testing.expectEqual(Phase.exited, pump.phase);
    try std.testing.expect(pump.finished());
    const snapshot = dock.activeSessionSnapshot().?;
    try std.testing.expect(!snapshot.running);
    try std.testing.expectEqual(@as(?u32, 0), snapshot.exit_code);
}

test "remote setup terminal never replays input after an uncertain write" {
    const allocator = std.testing.allocator;
    var lane: FakeLane = .{ .allocator = allocator };
    defer lane.deinit();
    const dock = try testDock(allocator);
    defer {
        dock.deinit(allocator);
        allocator.destroy(dock);
    }
    const pump = try Pump.create(allocator, "cloud", "verde-setup-2", "codex login", "Sign in", 0);
    defer pump.destroy(allocator, &lane);
    _ = pump.step(allocator, &lane, dock, 0);
    try lane.replies.append(allocator, "\"result\":{\"created\":true,\"session\":{\"id\":\"verde-setup-2\",\"running\":true}}");
    _ = pump.step(allocator, &lane, dock, 1);
    try lane.replies.append(allocator, "\"result\":{\"running\":true,\"text\":\"\",\"offset\":0,\"next_offset\":0}");
    _ = pump.step(allocator, &lane, dock, 2);

    // 5000 bytes with a multi-byte character straddling the 4096 boundary.
    var paste: [5000]u8 = @splat('a');
    @memcpy(paste[4095..4098], "\u{20ac}");
    _ = try dock.writeInputToActivePane(&paste);
    _ = pump.step(allocator, &lane, dock, 3_000);
    try std.testing.expectEqualStrings("session.write", lane.lastMethod());
    try std.testing.expectEqual(@as(usize, 5000 - 4095), dock.remoteIo().?.input.items.len);
    // No answer: the rest of the paste is dropped, never sent after it.
    try lane.replies.append(allocator, null);
    _ = pump.step(allocator, &lane, dock, 3_010);
    try std.testing.expectEqual(@as(usize, 0), dock.remoteIo().?.input.items.len);
    try std.testing.expectEqual(Phase.running, pump.phase);
}

test "a stopped remote setup command delivers its kill within a deadline" {
    const allocator = std.testing.allocator;
    var lane: FakeLane = .{ .allocator = allocator };
    defer lane.deinit();
    const pump = try Pump.create(allocator, "cloud", "verde-setup-3", "codex login", "Sign in", 0);
    defer pump.destroy(allocator, &lane);
    // Never started: nothing to kill.
    pump.requestKill(0);
    try std.testing.expect(pump.finished());

    const running = try Pump.create(allocator, "cloud", "verde-setup-4", "codex login", "Sign in", 0);
    defer running.destroy(allocator, &lane);
    _ = running.step(allocator, &lane, null, 0);
    try lane.replies.append(allocator, "\"result\":{\"created\":true,\"session\":{\"id\":\"verde-setup-4\",\"running\":true}}");
    running.requestKill(5);
    _ = running.step(allocator, &lane, null, 10);
    try std.testing.expectEqualStrings("session.kill", lane.lastMethod());
    // The lane stays busy past the deadline: the pump gives up, bounded.
    _ = running.step(allocator, &lane, null, 10 + REQUEST_DEADLINE_MS + 1);
    try std.testing.expectEqual(@as(usize, 1), lane.abandoned);
    lane.busy = true;
    _ = running.step(allocator, &lane, null, 10 + KILL_DEADLINE_MS + REQUEST_DEADLINE_MS + 2);
    try std.testing.expect(running.finished());
}

test "UTF-8 chunking never splits a sequence" {
    try std.testing.expectEqual(@as(usize, 3), utf8ChunkLen("abc", 4096));
    try std.testing.expectEqual(@as(usize, 1), utf8ChunkLen("a\u{20ac}", 2));
    try std.testing.expectEqual(@as(usize, 4), utf8ChunkLen("a\u{20ac}b", 4));
}

test "setup terminal font shrinks to fit a QR-sized grid and resizes the remote PTY" {
    const allocator = std.testing.allocator;
    const dock = try testDock(allocator);
    defer {
        dock.deinit(allocator);
        allocator.destroy(dock);
    }
    dock.setDefaultFontSize(32.0);
    try std.testing.expect(dock.fitFontToArea(1400.0, 1000.0, 110, 48, 32.0));
    // Already fitted: nothing changes on the next frame.
    try std.testing.expect(!dock.fitFontToArea(1400.0, 1000.0, 110, 48, 32.0));
    try dock.resizePaneToFit(allocator, dock.activePane().?.id, 1400.0, 1000.0);
    const grid = dock.activeGridSize().?;
    try std.testing.expect(grid.cols >= 110 and grid.rows >= 48);
    try std.testing.expect(dock.remoteIo().?.resize_pending);
    // Never larger than the user's own terminal font.
    _ = dock.fitFontToArea(4000.0, 4000.0, 110, 48, 24.0);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0 / 18.0), dock.font_scale, 0.001);
}
