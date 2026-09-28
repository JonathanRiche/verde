//! GUI-owned waiters for chats that reported a blocker on workspace
//! resources (for example another agent's `build` lease). Leases and process
//! conflicts live in the GUI, so the GUI watches them and asks the session
//! daemon to resume the blocked chat once every requested resource is free.
//! Waiters are in-memory only: after a GUI restart the chat must be resumed
//! manually, which the reporting tool tells the agent.

const Self = @This();

const std = @import("std");
const loop_wakeup = @import("loop_wakeup");
const daemon_client = @import("../daemon/client.zig");

const log = std.log.scoped(.resource_waiters);

pub const METHOD_TASKS_RESUME = "chat.tasks.resume";

const CHECK_INTERVAL_MS: i64 = 2_000;
/// Resources must stay free for this long so a release immediately followed
/// by another agent's acquire does not wake the chat into a new conflict.
const SETTLE_MS: i64 = 1_500;
const RETRY_AFTER_FAILURE_MS: i64 = 15_000;
const EXPIRE_AFTER_MS: i64 = 6 * std.time.ms_per_hour;
pub const MAX_WAITERS: usize = 64;
pub const MAX_RESOURCES: usize = 16;

pub const Waiter = struct {
    workspace_id: []u8,
    local_thread_id: []u8,
    reason: []u8,
    resume_id: []u8,
    resources: std.ArrayList([]u8) = .empty,
    created_ms: i64,
    free_since_ms: ?i64 = null,
    next_attempt_ms: i64 = 0,
    job: ?*Job = null,

    fn deinit(self: *Waiter, allocator: std.mem.Allocator) void {
        for (self.resources.items) |resource| allocator.free(resource);
        self.resources.deinit(allocator);
        allocator.free(self.workspace_id);
        allocator.free(self.local_thread_id);
        allocator.free(self.reason);
        allocator.free(self.resume_id);
    }
};

const ResumeParams = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    resume_id: []const u8,
    prompt: []const u8,
};

const Job = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: ?std.Thread = null,
    pref_path: []u8,
    workspace_id: []u8,
    local_thread_id: []u8,
    resume_id: []u8,
    prompt: []u8,
    failed: bool = false,
    /// The daemon rejected the request permanently (unknown thread, etc.).
    rejected: bool = false,

    fn destroy(self: *Job) void {
        const page = std.heap.page_allocator;
        page.free(self.pref_path);
        page.free(self.workspace_id);
        page.free(self.local_thread_id);
        page.free(self.resume_id);
        page.free(self.prompt);
        page.destroy(self);
    }
};

waiters: std.ArrayList(Waiter) = .empty,
last_check_ms: i64 = 0,

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.waiters.items) |*waiter| {
        if (waiter.job) |job| {
            finishJob(job);
            job.destroy();
        }
        waiter.deinit(allocator);
    }
    self.waiters.deinit(allocator);
}

/// Registers (or replaces) the waiter for one chat. A chat waits on at most
/// one resource set; a newer blocker report supersedes the older one.
pub fn register(
    self: *Self,
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    resources: []const []const u8,
    reason: []const u8,
    now_ms: i64,
) !void {
    if (resources.len == 0) return error.ResourcesRequired;
    if (resources.len > MAX_RESOURCES) return error.TooManyResources;
    if (self.findIndex(workspace_id, local_thread_id)) |index| {
        // An in-flight resume keeps its waiter until it completes; replacing
        // the entry underneath it would orphan the job.
        if (self.waiters.items[index].job != null) return error.ResumeInFlight;
        var old = self.waiters.orderedRemove(index);
        old.deinit(allocator);
    }
    if (self.waiters.items.len >= MAX_WAITERS) return error.TooManyWaiters;

    var random_bytes: [8]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&random_bytes);
    const hex = std.fmt.bytesToHex(random_bytes, .lower);

    var waiter: Waiter = .{
        .workspace_id = try allocator.dupe(u8, workspace_id),
        .local_thread_id = undefined,
        .reason = undefined,
        .resume_id = undefined,
        .created_ms = now_ms,
        .next_attempt_ms = now_ms,
    };
    errdefer allocator.free(waiter.workspace_id);
    waiter.local_thread_id = try allocator.dupe(u8, local_thread_id);
    errdefer allocator.free(waiter.local_thread_id);
    waiter.reason = try allocator.dupe(u8, std.mem.trim(u8, reason, " \t\r\n"));
    errdefer allocator.free(waiter.reason);
    waiter.resume_id = try std.fmt.allocPrint(allocator, "{d}-{s}", .{ now_ms, hex[0..] });
    errdefer allocator.free(waiter.resume_id);
    errdefer {
        for (waiter.resources.items) |resource| allocator.free(resource);
        waiter.resources.deinit(allocator);
    }
    for (resources) |resource| {
        const owned = try allocator.dupe(u8, resource);
        waiter.resources.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    try self.waiters.append(allocator, waiter);
}

fn findIndex(self: *const Self, workspace_id: []const u8, local_thread_id: []const u8) ?usize {
    for (self.waiters.items, 0..) |waiter, index| {
        if (std.mem.eql(u8, waiter.workspace_id, workspace_id) and
            std.mem.eql(u8, waiter.local_thread_id, local_thread_id)) return index;
    }
    return null;
}

pub fn isEmpty(self: *const Self) bool {
    return self.waiters.items.len == 0;
}

/// Main-thread tick. `checker` must provide
/// `fn busy(checker, workspace_id, owner, resources) ?bool`, returning null
/// when the workspace is no longer open.
pub fn poll(self: *Self, allocator: std.mem.Allocator, pref_path: []const u8, now_ms: i64, checker: anytype) void {
    var index: usize = 0;
    while (index < self.waiters.items.len) {
        const waiter = &self.waiters.items[index];
        if (waiter.job) |job| {
            if (!job.done.load(.acquire)) {
                index += 1;
                continue;
            }
            finishJob(job);
            waiter.job = null;
            const failed = job.failed;
            const rejected = job.rejected;
            job.destroy();
            if (!failed or rejected) {
                if (rejected) log.warn("resume rejected for chat {s}; dropping waiter", .{waiter.local_thread_id});
                var removed = self.waiters.orderedRemove(index);
                removed.deinit(allocator);
                continue;
            }
            log.warn("resume failed for chat {s}; retrying", .{waiter.local_thread_id});
            waiter.next_attempt_ms = now_ms + RETRY_AFTER_FAILURE_MS;
            waiter.free_since_ms = null;
        }
        if (now_ms - waiter.created_ms > EXPIRE_AFTER_MS) {
            log.info("resource wait expired for chat {s}", .{waiter.local_thread_id});
            var removed = self.waiters.orderedRemove(index);
            removed.deinit(allocator);
            continue;
        }
        index += 1;
    }

    if (self.waiters.items.len == 0) return;
    if (now_ms - self.last_check_ms < CHECK_INTERVAL_MS / 4) return;
    self.last_check_ms = now_ms;

    index = 0;
    while (index < self.waiters.items.len) {
        const waiter = &self.waiters.items[index];
        if (waiter.job != null or now_ms < waiter.next_attempt_ms) {
            index += 1;
            continue;
        }
        const busy = checker.busy(waiter.workspace_id, waiter.local_thread_id, waiter.resources.items) orelse {
            var removed = self.waiters.orderedRemove(index);
            removed.deinit(allocator);
            continue;
        };
        if (busy) {
            waiter.free_since_ms = null;
            waiter.next_attempt_ms = now_ms + CHECK_INTERVAL_MS;
            index += 1;
            continue;
        }
        const free_since = waiter.free_since_ms orelse blk: {
            waiter.free_since_ms = now_ms;
            break :blk now_ms;
        };
        if (now_ms - free_since < SETTLE_MS) {
            index += 1;
            continue;
        }
        waiter.job = spawnResume(allocator, pref_path, waiter);
        if (waiter.job == null) waiter.next_attempt_ms = now_ms + RETRY_AFTER_FAILURE_MS;
        index += 1;
    }
}

fn resumePromptAlloc(allocator: std.mem.Allocator, waiter: *const Waiter) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("[Verde resource available]\nThe workspace resources you were waiting for are free again: ");
    for (waiter.resources.items, 0..) |resource, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(resource);
    }
    try w.writeAll(".\n");
    if (waiter.reason.len > 0) {
        try w.writeAll("You were blocked on: ");
        try w.writeAll(waiter.reason);
        try w.writeAll("\n");
    }
    try w.writeAll("Resume the blocked work now. Acquire a lease before running the exclusive command; if another owner took the resource first, report the blocker again.");
    return try out.toOwnedSlice();
}

fn spawnResume(allocator: std.mem.Allocator, pref_path: []const u8, waiter: *const Waiter) ?*Job {
    const prompt = resumePromptAlloc(allocator, waiter) catch return null;
    defer allocator.free(prompt);
    const page = std.heap.page_allocator;
    const job = page.create(Job) catch return null;
    var built: usize = 0;
    const fields = .{ pref_path, waiter.workspace_id, waiter.local_thread_id, waiter.resume_id, prompt };
    var copies: [5][]u8 = undefined;
    inline for (fields, 0..) |field, i| {
        copies[i] = page.dupe(u8, field) catch {
            for (copies[0..built]) |copy| page.free(copy);
            page.destroy(job);
            return null;
        };
        built += 1;
    }
    job.* = .{
        .pref_path = copies[0],
        .workspace_id = copies[1],
        .local_thread_id = copies[2],
        .resume_id = copies[3],
        .prompt = copies[4],
    };
    job.worker = std.Thread.spawn(.{}, jobWorkerMain, .{job}) catch |err| {
        log.warn("failed to spawn resource-resume worker: {s}", .{@errorName(err)});
        job.destroy();
        return null;
    };
    return job;
}

fn finishJob(job: *Job) void {
    if (job.worker) |worker| {
        worker.join();
        job.worker = null;
    }
}

fn jobWorkerMain(job: *Job) void {
    defer {
        job.done.store(true, .release);
        loop_wakeup.notify();
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var transport: daemon_client.HeadlessTransport = .{ .allocator = allocator, .pref_path = job.pref_path };
    var client = daemon_client.headlessClient(allocator, &transport);
    var parsed = client.call(METHOD_TASKS_RESUME, ResumeParams{
        .workspace_id = job.workspace_id,
        .local_thread_id = job.local_thread_id,
        .resume_id = job.resume_id,
        .prompt = job.prompt,
    }) catch |err| {
        log.debug("chat.tasks.resume request failed: {s}", .{@errorName(err)});
        job.failed = true;
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        job.failed = true;
        // Missing threads and invalid requests never succeed on retry.
        job.rejected = std.mem.indexOf(u8, err.code, "not_found") != null or
            std.mem.indexOf(u8, err.code, "invalid") != null;
        return;
    }
    // `delivered = false` means the chat was mid-transition (finishing); retry.
    const result = parsed.response.result orelse return;
    if (result == .object) {
        if (result.object.get("delivered")) |delivered| {
            if (delivered == .bool and !delivered.bool) job.failed = true;
        }
    }
}

const TestChecker = struct {
    busy_value: ?bool,
    fn busy(self: *const TestChecker, _: []const u8, _: []const u8, _: []const []const u8) ?bool {
        return self.busy_value;
    }
};

test "resource waiters replace per chat and drop when the workspace closes" {
    const allocator = std.testing.allocator;
    var self: Self = .{};
    defer self.deinit(allocator);
    try self.register(allocator, "ws", "chat-a", &.{"build"}, "waiting for build", 0);
    try self.register(allocator, "ws", "chat-a", &.{ "build", "test" }, "waiting again", 10);
    try std.testing.expectEqual(@as(usize, 1), self.waiters.items.len);
    try std.testing.expectEqual(@as(usize, 2), self.waiters.items[0].resources.items.len);
    try std.testing.expectEqualStrings("waiting again", self.waiters.items[0].reason);

    const prompt = try resumePromptAlloc(allocator, &self.waiters.items[0]);
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "build, test") != null);

    const busy: TestChecker = .{ .busy_value = true };
    self.poll(allocator, "/nonexistent", 5_000, &busy);
    try std.testing.expectEqual(@as(usize, 1), self.waiters.items.len);
    try std.testing.expect(self.waiters.items[0].job == null);

    const closed: TestChecker = .{ .busy_value = null };
    self.poll(allocator, "/nonexistent", 10_000, &closed);
    try std.testing.expect(self.isEmpty());
}

test "resource waiters expire" {
    const allocator = std.testing.allocator;
    var self: Self = .{};
    defer self.deinit(allocator);
    try self.register(allocator, "ws", "chat-a", &.{"build"}, "", 0);
    const busy: TestChecker = .{ .busy_value = true };
    self.poll(allocator, "/nonexistent", EXPIRE_AFTER_MS + 1, &busy);
    try std.testing.expect(self.isEmpty());
}
