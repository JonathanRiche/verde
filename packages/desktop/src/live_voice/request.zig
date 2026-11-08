//! One draft-independent voice request. All RPCs run on the worker; release /
//! acquire publication lets the GUI collect acceptance and completion separately.
const Self = @This();
const std = @import("std");
const daemon = @import("../daemon/client.zig");
const protocol = @import("protocol.zig");
const wake = @import("loop_wakeup");

allocator: std.mem.Allocator,
worker: ?std.Thread = null,
pref_path: []const u8,
workspace: []const u8,
thread: []const u8,
turn: []const u8,
call_id: []const u8,
prompt: []const u8,
revision: u64,
epoch: u64,
cancel_only: bool = false,
accept_ready: std.atomic.Value(bool) = .init(false),
done: std.atomic.Value(bool) = .init(false),
detach: std.atomic.Value(bool) = .init(false),
cancel: std.atomic.Value(bool) = .init(false),
cancel_done: std.atomic.Value(bool) = .init(false),
// Immutable once the corresponding atomic is published.
accepted: ?bool = null,
accept_error: ?[]const u8 = null,
cancel_ok: bool = false,
reply: ?[]const u8 = null,
status: []const u8 = "uncertain",
// GUI-only fields.
reported: bool = false,
superseded: bool = false,
stop_batch: u64 = 0,

pub fn create(a: std.mem.Allocator, pref: []const u8, workspace: []const u8, thread: []const u8, turn: []const u8, call_id: []const u8, prompt: []const u8, revision: u64, epoch: u64, cancel_only: bool) !*Self {
    const job = try a.create(Self);
    job.* = .{ .allocator = a, .pref_path = "", .workspace = "", .thread = "", .turn = "", .call_id = "", .prompt = "", .revision = revision, .epoch = epoch, .cancel_only = cancel_only };
    errdefer job.destroy();
    inline for (.{ "pref_path", "workspace", "thread", "turn", "call_id", "prompt" }, .{ pref, workspace, thread, turn, call_id, prompt }) |key, value| @field(job, key) = try a.dupe(u8, value);
    job.worker = try std.Thread.spawn(.{}, run, .{job});
    return job;
}
pub fn destroy(self: *Self) void {
    self.detach.store(true, .release);
    if (self.worker) |worker| worker.join();
    const a = self.allocator;
    inline for (.{ "pref_path", "workspace", "thread", "turn", "call_id", "prompt" }) |key| a.free(@field(self, key));
    if (self.reply) |text| a.free(text);
    if (self.accept_error) |text| a.free(text);
    a.destroy(self);
}
fn field(v: std.json.Value, name: []const u8) std.json.Value {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}
fn string(v: std.json.Value, name: []const u8) []const u8 {
    return protocol.stringOf(field(v, name)) orelse "";
}
fn fail(self: *Self, code: []const u8, accepted: ?bool) void {
    self.accepted = accepted;
    self.accept_error = self.allocator.dupe(u8, code) catch null;
}
fn run(self: *Self) void {
    defer {
        self.accept_ready.store(true, .release);
        self.done.store(true, .release);
        wake.notify();
    }
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var transport: daemon.HeadlessTransport = .{ .allocator = a, .pref_path = self.pref_path, .timeout_ms = 15000 };
    var client = daemon.headlessClient(a, &transport);
    if (self.cancel_only) {
        self.stop(&client);
        return;
    }
    var settings = client.call("chat.thread.get", .{ .workspace_id = self.workspace, .local_thread_id = self.thread, .message_limit = @as(u32, 0) }) catch return self.fail("thread_unavailable", false);
    defer settings.deinit();
    if (settings.response.err) |err| return self.fail(err.code, false);
    const t = field(settings.response.result orelse .null, "thread");
    if (string(t, "provider").len == 0 or field(t, "archived") == .bool and field(t, "archived").bool) return self.fail("thread_unavailable", false);
    if (self.cancel.load(.acquire)) {
        self.cancel_ok = true;
        self.cancel_done.store(true, .release);
        return self.fail("cancelled_before_send", false);
    }
    var started = client.call("chat.turn.start", .{
        .turn_id = self.turn,
        .workspace_id = self.workspace,
        .local_thread_id = self.thread,
        .prompt = self.prompt,
        .task_owner = "voice",
        .orchestration_note = "<voice_turn>The user spoke this request and will hear the reply read aloud. Keep the answer conversational and concise, preserving qualifications and failures. Use the Verde tools for actions and verify results before claiming success.</voice_turn>",
        .provider = string(t, "provider"),
        .harness = string(t, "harness"),
        .thread_title = string(t, "title"),
        .model_ref = field(t, "model_ref"),
        .provider_thread_id = field(t, "provider_thread_id"),
        .reasoning_effort = field(t, "reasoning_effort"),
        .opencode_reasoning_variant = field(t, "reasoning_variant"),
        .access_mode = field(t, "access_mode"),
        .fast_mode = std.mem.eql(u8, string(t, "fast_mode"), "on"),
        .repository_id = if (string(t, "repository_id").len > 0) string(t, "repository_id") else "primary",
        .relative_cwd = field(t, "repository_cwd"),
    }) catch return self.fail("delivery_uncertain", null);
    defer started.deinit();
    if (started.response.err) |err| return self.fail(err.code, false);
    if (!std.mem.eql(u8, string(started.response.result orelse .null, "turn_id"), self.turn)) return self.fail("delivery_uncertain", null);
    self.accepted = true;
    self.accept_ready.store(true, .release);
    wake.notify();
    const io = std.Io.Threaded.global_single_threaded.io();
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 30 * 60 * 1000;
    var after: u64 = 0;
    while (!self.detach.load(.acquire) and std.Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        if (self.cancel.load(.acquire)) {
            self.stop(&client);
            return;
        }
        // Each response arena is reclaimed; a long call must not retain every tail.
        var page = std.heap.ArenaAllocator.init(self.allocator);
        defer page.deinit();
        var tail_transport: daemon.HeadlessTransport = .{ .allocator = page.allocator(), .pref_path = self.pref_path, .timeout_ms = 5000 };
        var reader = daemon.headlessClient(page.allocator(), &tail_transport);
        var response = reader.call("chat.turn.tail", .{ .turn_id = self.turn, .after_seq = after, .wait_ms = @as(u32, 1000), .max_bytes = @as(u32, 262144) }) catch {
            std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
            continue;
        };
        defer response.deinit();
        if (response.response.err != null) {
            // Accepted queued requests have no tail until dispatch starts them.
            std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
            continue;
        }
        const result = response.response.result orelse .null;
        const events = field(result, "events");
        if (events == .array) for (events.array.items) |event| {
            const seq = field(event, "seq");
            if (seq == .integer and seq.integer >= 0) after = @max(after, @as(u64, @intCast(seq.integer)));
        };
        const more = field(result, "has_more_events");
        if (more == .bool and more.bool) continue;
        const status = string(result, "status");
        inline for (.{ "completed", "failed", "aborted", "interrupted" }) |terminal| {
            if (std.mem.eql(u8, status, terminal)) {
                self.status = terminal;
                self.reply = self.allocator.dupe(u8, string(result, "result_reply_text")) catch null;
                return;
            }
        }
        // Over-cap long polls can return immediately: pace every heartbeat.
        std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    }
}
fn stop(self: *Self, client: anytype) void {
    defer {
        self.cancel_done.store(true, .release);
        wake.notify();
    }
    var result = client.call("chat.turn.cancel", .{ .turn_id = self.turn }) catch return;
    defer result.deinit();
    const accepted = field(result.response.result orelse .null, "accepted");
    self.cancel_ok = result.response.err == null and accepted == .bool and accepted.bool;
    if (self.cancel_ok) self.status = "aborted";
}
