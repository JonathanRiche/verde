//! Background calls to the daemon's scheduled tasks (`schedule.list`,
//! `schedule.create`, `schedule.update`, `schedule.delete`, `schedule.run`).
//! Every request runs on a worker thread with page-allocated buffers so the
//! render thread never waits on the daemon; `tick` collects results into the
//! Companion controller, starts queued mutations, and refreshes the list
//! while the panel is open and right after each mutation.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const loop_wakeup = @import("loop_wakeup");
const daemon_client = @import("../daemon/client.zig");
const controller = @import("companion_controller.zig");

const log = std.log.scoped(.schedules_sync);

pub const METHOD_LIST = "schedule.list";
pub const METHOD_CREATE = "schedule.create";
pub const METHOD_UPDATE = "schedule.update";
pub const METHOD_DELETE = "schedule.delete";
pub const METHOD_RUN = "schedule.run";
/// List cadence while the panel is open; mutations refresh at once.
pub const REFRESH_MS: i64 = 10_000;
const REQUEST_TIMEOUT_MS: u32 = 8_000;
const MAX_QUEUED: usize = 8;

const JobKind = enum { list, mutate };

const Job = struct {
    kind: JobKind,
    method: []const u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: ?std.Thread = null,
    pref_path: []u8 = &.{},
    params_json: []u8 = &.{},
    /// Mutation epoch a list started in; older lists are dropped.
    epoch: u64 = 0,
    /// Row a mutation acts on (empty for create).
    target: controller.ScheduleId = .{},
    /// list: page-allocated rows.
    rows: []controller.ScheduleRow = &.{},
    row_count: usize = 0,
    total: usize = 0,
    failed: bool = false,
    unsupported: bool = false,
    message: controller.ShortText = .{},

    fn destroy(self: *Job) void {
        const page = std.heap.page_allocator;
        if (self.worker) |worker| worker.join();
        page.free(self.pref_path);
        page.free(self.params_json);
        if (self.rows.len > 0) page.free(self.rows);
        page.destroy(self);
    }
};

/// Fields for `schedule.create`, as in the shared spec. Null fields are
/// left out of the request.
pub const CreateParams = struct {
    name: ?[]const u8 = null,
    prompt: []const u8,
    target: std.json.Value,
    repeat: std.json.Value,
    enabled: ?bool = null,
    parent_workspace_id: ?[]const u8 = null,
    parent_thread_id: ?[]const u8 = null,
    created_by: []const u8 = "desktop",
};

/// Partial `schedule.update`; only set fields change.
pub const UpdateParams = struct {
    name: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    target: ?std.json.Value = null,
    repeat: ?std.json.Value = null,
    enabled: ?bool = null,
};

pub const TickResult = struct {
    /// The controller changed and the panel should redraw.
    changed: bool = false,
    /// A Run now landed (the caller may tell the user).
    ran: bool = false,
};

list_job: ?*Job = null,
mutation_job: ?*Job = null,
queued: [MAX_QUEUED]*Job = undefined,
queued_count: usize = 0,
last_list_started_ms: i64 = 0,
/// Bumped on every mutation so a list fetched before it cannot undo an
/// optimistic toggle.
epoch: u64 = 0,
/// Set when the list must be fetched on the next tick regardless of age.
refresh_requested: bool = true,
/// Companion was working last tick; a finished turn may have created one.
companion_was_working: bool = false,

pub fn deinit(self: *Self) void {
    if (self.list_job) |job| job.destroy();
    if (self.mutation_job) |job| job.destroy();
    for (self.queued[0..self.queued_count]) |job| job.destroy();
    self.* = .{};
}

/// Fetch the list on the next tick (opening the view, after a mutation).
pub fn requestRefresh(self: *Self) void {
    self.refresh_requested = true;
}

pub fn busy(self: *const Self) bool {
    return self.list_job != null or self.mutation_job != null or self.queued_count > 0;
}

/// Queues the daemon call a schedule control asked for.
pub fn submit(self: *Self, intent: controller.ScheduleIntent) bool {
    return switch (intent) {
        .set_enabled => |value| self.requestUpdate(value.id.slice(), .{ .enabled = value.enabled }),
        .run => |id| self.enqueueMutation(METHOD_RUN, &id, .{ .id = id.slice() }),
        .delete => |id| self.enqueueMutation(METHOD_DELETE, &id, .{ .id = id.slice() }),
    };
}

pub fn requestCreate(self: *Self, params: CreateParams) bool {
    return self.enqueueMutation(METHOD_CREATE, &controller.ScheduleId{}, params);
}

pub fn requestUpdate(self: *Self, id: []const u8, fields: UpdateParams) bool {
    var target: controller.ScheduleId = .{};
    if (!target.set(id)) return false;
    return self.enqueueMutation(METHOD_UPDATE, &target, .{
        .id = id,
        .name = fields.name,
        .prompt = fields.prompt,
        .target = fields.target,
        .repeat = fields.repeat,
        .enabled = fields.enabled,
    });
}

/// Collects finished requests into `companion`, starts the next queued
/// mutation, and refreshes the list when it is due. `panel_open` gates the
/// periodic refresh; mutations still land while the panel is closed.
pub fn tick(self: *Self, companion: *controller, pref_path: []const u8, panel_open: bool, now_ms: i64) TickResult {
    var result: TickResult = .{};
    if (self.mutation_job) |job| if (job.done.load(.acquire)) {
        self.mutation_job = null;
        defer job.destroy();
        if (job.target.eql(&companion.schedule_pending)) companion.schedule_pending.clear();
        if (job.failed) {
            companion.setSchedulesError(failureMessage(job));
        } else if (std.mem.eql(u8, job.method, METHOD_RUN)) {
            result.ran = true;
        }
        self.refresh_requested = true;
        result.changed = true;
    };
    if (self.list_job) |job| if (job.done.load(.acquire)) {
        self.list_job = null;
        defer job.destroy();
        if (job.epoch != self.epoch) {
            self.refresh_requested = true;
        } else if (job.failed) {
            companion.setSchedulesError(failureMessage(job));
            // A daemon without the methods stays unsupported until relaunch.
            if (job.unsupported) companion.schedules_loaded = true;
        } else {
            companion.setSchedules(job.rows[0..job.row_count], job.total);
        }
        result.changed = true;
    };
    if (self.mutation_job == null and self.queued_count > 0) {
        const next = self.queued[0];
        std.mem.copyForwards(*Job, self.queued[0 .. self.queued_count - 1], self.queued[1..self.queued_count]);
        self.queued_count -= 1;
        self.mutation_job = next;
        start(next, pref_path);
    }
    // A companion turn that just finished may have created or changed one.
    const working = companion.presentation.working;
    if (self.companion_was_working and !working) self.refresh_requested = true;
    self.companion_was_working = working;
    if (!panel_open or self.list_job != null or self.mutation_job != null) return result;
    if (self.refresh_requested or now_ms - self.last_list_started_ms >= REFRESH_MS) {
        self.refresh_requested = false;
        self.last_list_started_ms = now_ms;
        self.list_job = makeJob(.list, METHOD_LIST, "{}", &controller.ScheduleId{}, self.epoch);
        if (self.list_job) |job| start(job, pref_path);
    }
    return result;
}

fn enqueueMutation(self: *Self, method: []const u8, target: *const controller.ScheduleId, params: anytype) bool {
    if (self.queued_count >= MAX_QUEUED) return false;
    const page = std.heap.page_allocator;
    const params_json = std.json.Stringify.valueAlloc(page, params, .{ .emit_null_optional_fields = false }) catch return false;
    defer page.free(params_json);
    const job = makeJob(.mutate, method, params_json, target, 0) orelse return false;
    self.queued[self.queued_count] = job;
    self.queued_count += 1;
    self.epoch += 1;
    return true;
}

fn makeJob(kind: JobKind, method: []const u8, params_json: []const u8, target: *const controller.ScheduleId, epoch: u64) ?*Job {
    const page = std.heap.page_allocator;
    const job = page.create(Job) catch return null;
    job.* = .{ .kind = kind, .method = method, .epoch = epoch, .target = target.* };
    job.params_json = page.dupe(u8, params_json) catch {
        job.destroy();
        return null;
    };
    if (kind == .list) {
        job.rows = page.alloc(controller.ScheduleRow, controller.MAX_SCHEDULE_ROWS) catch {
            job.destroy();
            return null;
        };
    }
    return job;
}

/// Spawns the worker. The daemon path is bound here, not at submit, so a
/// queued mutation needs no state beyond the controller.
fn start(job: *Job, pref_path: []const u8) void {
    job.pref_path = std.heap.page_allocator.dupe(u8, pref_path) catch {
        job.failed = true;
        job.done.store(true, .release);
        return;
    };
    job.worker = std.Thread.spawn(.{}, workerMain, .{job}) catch {
        job.worker = null;
        job.failed = true;
        job.message.set("Could not start a background request.");
        job.done.store(true, .release);
        return;
    };
}

fn failureMessage(job: *const Job) []const u8 {
    if (job.unsupported) return "Scheduled tasks need a newer Verde daemon. Relaunch Verde to use them.";
    const message = job.message.slice();
    return if (message.len > 0) message else "Couldn't reach the Verde daemon.";
}

fn workerMain(job: *Job) void {
    defer {
        job.done.store(true, .release);
        loop_wakeup.notify();
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const params = std.json.parseFromSliceLeaky(std.json.Value, allocator, job.params_json, .{}) catch {
        job.failed = true;
        return;
    };
    var transport: daemon_client.HeadlessTransport = .{ .allocator = allocator, .pref_path = job.pref_path, .timeout_ms = REQUEST_TIMEOUT_MS };
    var client = daemon_client.headlessClient(allocator, &transport);
    var parsed = client.call(job.method, params) catch |err| {
        log.debug("{s} failed: {s}", .{ job.method, @errorName(err) });
        job.failed = true;
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        job.failed = true;
        job.unsupported = std.mem.eql(u8, err.code, "unknown_method") or std.mem.eql(u8, err.code, "method_not_found");
        job.message.set(err.message);
        return;
    }
    const result = parsed.response.result orelse {
        job.failed = true;
        return;
    };
    if (job.kind == .list) {
        const parsed_list = parseList(result, job.rows, unixTimestampMs());
        job.row_count = parsed_list.count;
        job.total = parsed_list.total;
        job.failed = !parsed_list.ok;
    }
}

const ParsedList = struct { ok: bool, count: usize, total: usize };

/// Reads `{ schedules: [...] }` into `rows`, keeping the daemon's order.
/// Rows that do not parse are skipped rather than failing the whole list.
fn parseList(result: std.json.Value, rows: []controller.ScheduleRow, now_ms: i64) ParsedList {
    if (result != .object) return .{ .ok = false, .count = 0, .total = 0 };
    const list = result.object.get("schedules") orelse return .{ .ok = false, .count = 0, .total = 0 };
    if (list != .array) return .{ .ok = false, .count = 0, .total = 0 };
    var count: usize = 0;
    for (list.array.items) |item| {
        if (count == rows.len) break;
        if (parseRow(item, &rows[count], now_ms)) count += 1;
    }
    return .{ .ok = true, .count = count, .total = list.array.items.len };
}

fn parseRow(value: std.json.Value, row: *controller.ScheduleRow, now_ms: i64) bool {
    if (value != .object) return false;
    const object = value.object;
    row.* = .{};
    if (!row.id.set(stringField(object, "id") orelse return false)) return false;
    row.name.set(stringField(object, "name") orelse "");
    const prompt = stringField(object, "prompt") orelse "";
    row.prompt.set(prompt);
    row.prompt_truncated = row.prompt.slice().len < prompt.len;
    if (row.name.slice().len == 0) row.name.set(firstLine(prompt));
    row.enabled = boolField(object, "enabled") orelse true;
    row.next_run_ms = intField(object, "next_run_ms");
    row.last_run_ms = intField(object, "last_run_ms");
    row.last_status = controller.ScheduleStatus.fromDaemon(stringField(object, "last_status"));
    row.last_error.set(stringField(object, "last_error") orelse "");
    row.repeat = parseRepeat(object.get("repeat") orelse .null, now_ms);
    var buffer: [96]u8 = undefined;
    row.repeat_text.set(controller.formatScheduleRepeat(&buffer, row.repeat));
    return true;
}

fn parseRepeat(value: std.json.Value, now_ms: i64) controller.ScheduleRepeat {
    if (value != .object) return .unknown;
    const object = value.object;
    const kind = stringField(object, "kind") orelse return .unknown;
    if (std.mem.eql(u8, kind, "once")) {
        const at_ms = intField(object, "at_ms") orelse return .unknown;
        const local = localStamp(at_ms) orelse return .unknown;
        const week_ms: i64 = 6 * std.time.ms_per_day;
        return .{ .once = .{ .at_ms = at_ms, .local = local, .this_week = at_ms >= now_ms - std.time.ms_per_day and at_ms - now_ms < week_ms } };
    }
    if (std.mem.eql(u8, kind, "interval")) {
        const minutes = intField(object, "every_minutes") orelse return .unknown;
        if (minutes <= 0 or minutes > std.math.maxInt(u32)) return .unknown;
        return .{ .interval = @intCast(minutes) };
    }
    if (std.mem.eql(u8, kind, "daily")) {
        const time = stringField(object, "time") orelse return .unknown;
        const clock = parseClock(time) orelse return .unknown;
        var weekdays: u7 = 0;
        if (object.get("weekdays")) |days| if (days == .array) for (days.array.items) |day| {
            if (day == .integer and day.integer >= 0 and day.integer <= 6) weekdays |= @as(u7, 1) << @intCast(day.integer);
        };
        return .{ .daily = .{ .hour = clock.hour, .minute = clock.minute, .weekdays = weekdays } };
    }
    return .unknown;
}

fn parseClock(text: []const u8) ?struct { hour: u8, minute: u8 } {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const hour = std.fmt.parseInt(u8, text[0..colon], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[colon + 1 ..], 10) catch return null;
    if (hour > 23 or minute > 59) return null;
    return .{ .hour = hour, .minute = minute };
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    return trimmed[0..end];
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (object.get(name) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn intField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (object.get(name) orelse return null) {
        .integer => |value| value,
        .float => |value| if (std.math.isFinite(value)) @intFromFloat(value) else null,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
    return switch (object.get(name) orelse return null) {
        .bool => |value| value,
        else => null,
    };
}

fn unixTimestampMs() i64 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const timestamp = std.Io.Clock.real.now(threaded.io());
    return @intCast(@divTrunc(timestamp.nanoseconds, std.time.ns_per_ms));
}

// ---- host-local time ---------------------------------------------------------

/// Leading fields of C `struct tm`; the tail pads past every libc's
/// `tm_gmtoff` / `tm_zone` so `localtime_r` never writes out of bounds.
const CTm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tail: [32]u8,
};

extern "c" fn localtime_r(timer: *const std.c.time_t, result: *CTm) ?*CTm;
extern "c" fn _localtime64_s(result: *CTm, timer: *const i64) c_int;

/// Converts epoch ms to the host's local wall clock (as the daemon fires
/// schedules in host-local time). Null without libc.
fn localStamp(ms: i64) ?controller.LocalStamp {
    if (!builtin.link_libc) return null;
    var tm: CTm = undefined;
    const seconds = @divFloor(ms, std.time.ms_per_s);
    if (builtin.os.tag == .windows) {
        const timer: i64 = seconds;
        if (_localtime64_s(&tm, &timer) != 0) return null;
    } else {
        const timer: std.c.time_t = @intCast(seconds);
        if (localtime_r(&timer, &tm) == null) return null;
    }
    return .{
        .month = @intCast(std.math.clamp(tm.tm_mon + 1, 1, 12)),
        .day = @intCast(std.math.clamp(tm.tm_mday, 1, 31)),
        .weekday = @intCast(std.math.clamp(tm.tm_wday, 0, 6)),
        .hour = @intCast(std.math.clamp(tm.tm_hour, 0, 23)),
        .minute = @intCast(std.math.clamp(tm.tm_min, 0, 59)),
    };
}

// ---- tests ---------------------------------------------------------------------

test "schedule list parses rows, repeats, and status in daemon order" {
    const json =
        \\{"schedules":[
        \\ {"id":"sch-1","name":"Morning CI check","prompt":"Check CI for every workspace.","repeat":{"kind":"daily","time":"09:00","weekdays":[1,2,3,4,5]},
        \\  "enabled":true,"next_run_ms":1792470000000,"last_run_ms":1792383600000,"last_status":"ok","last_error":null},
        \\ {"id":"sch-2","name":"","prompt":"Ping the deploy\nand report","repeat":{"kind":"interval","every_minutes":120},"enabled":false,"next_run_ms":null,"last_status":"failed","last_error":"provider offline"},
        \\ {"name":"no id, skipped","prompt":"x","repeat":{"kind":"daily","time":"9:00"}},
        \\ {"id":"sch-3","name":"Odd","prompt":"x","repeat":{"kind":"cron"},"enabled":true}
        \\],"now_ms":1792430000000}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    var rows: [4]controller.ScheduleRow = undefined;
    const list = parseList(parsed.value, &rows, 1_792_430_000_000);
    try std.testing.expect(list.ok);
    try std.testing.expectEqual(@as(usize, 3), list.count);
    try std.testing.expectEqual(@as(usize, 4), list.total);
    try std.testing.expectEqualStrings("sch-1", rows[0].id.slice());
    try std.testing.expectEqualStrings("Weekdays at 09:00", rows[0].repeat_text.slice());
    try std.testing.expectEqual(controller.ScheduleStatus.ok, rows[0].last_status);
    try std.testing.expectEqual(@as(?i64, 1792470000000), rows[0].next_run_ms);
    try std.testing.expect(rows[0].enabled);
    // A missing name falls back to the prompt's first line.
    try std.testing.expectEqualStrings("Ping the deploy", rows[1].name.slice());
    try std.testing.expectEqualStrings("Every 2 hours", rows[1].repeat_text.slice());
    try std.testing.expect(!rows[1].enabled);
    try std.testing.expectEqual(@as(?i64, null), rows[1].next_run_ms);
    try std.testing.expectEqualStrings("provider offline", rows[1].last_error.slice());
    try std.testing.expectEqualStrings("Custom schedule", rows[2].repeat_text.slice());
    try std.testing.expect(!parseList(.null, &rows, 0).ok);
}

test "schedule once repeats name the weekday only within the week" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const now: i64 = 1_792_430_000_000;
    const soon = parseRepeat(try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"kind\":\"once\",\"at_ms\":1792440000000}", .{}), now);
    try std.testing.expect(soon.once.this_week);
    const later = parseRepeat(try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"kind\":\"once\",\"at_ms\":1793430000000}", .{}), now);
    try std.testing.expect(!later.once.this_week);
    const local = localStamp(1_792_440_000_000).?;
    try std.testing.expect(local.weekday <= 6 and local.hour <= 23 and local.month >= 1);
    try std.testing.expect(parseClock("24:00") == null);
    try std.testing.expectEqual(@as(u8, 7), parseClock("07:45").?.hour);
}

test "schedule mutations queue in order and bump the list epoch" {
    var sync: Self = .{};
    defer sync.deinit();
    var id: controller.ScheduleId = .{};
    try std.testing.expect(id.set("sch-1"));
    try std.testing.expect(sync.submit(.{ .set_enabled = .{ .id = id, .enabled = false } }));
    try std.testing.expect(sync.submit(.{ .run = id }));
    try std.testing.expect(sync.submit(.{ .delete = id }));
    try std.testing.expectEqual(@as(usize, 3), sync.queued_count);
    try std.testing.expectEqual(@as(u64, 3), sync.epoch);
    try std.testing.expectEqualStrings(METHOD_UPDATE, sync.queued[0].method);
    try std.testing.expectEqualStrings("{\"id\":\"sch-1\",\"enabled\":false}", sync.queued[0].params_json);
    try std.testing.expectEqualStrings(METHOD_RUN, sync.queued[1].method);
    try std.testing.expectEqualStrings("{\"id\":\"sch-1\"}", sync.queued[2].params_json);
    try std.testing.expect(sync.busy());
}
