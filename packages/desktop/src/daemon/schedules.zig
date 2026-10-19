//! Daemon-owned scheduled tasks. A schedule sends a prompt into a chat later
//! or on a repeat: into an existing thread, or into a fresh chat opened in a
//! workspace on every run. Every client (CLI, MCP, desktop, phones) manages
//! them through the same `schedule.*` RPC methods; the sessionizer's
//! scheduler loop claims due rows here and delivers them as chat turns.
//!
//! Times are the desktop host's local time. Daily runs go through libc
//! `localtime_r` / `mktime`, so they stay on the wall clock across DST.

const std = @import("std");
const builtin = @import("builtin");
const zqlite = @import("zqlite");
const chat_links = @import("chat_links.zig");

pub const METHOD_LIST = "schedule.list";
pub const METHOD_CREATE = "schedule.create";
pub const METHOD_UPDATE = "schedule.update";
pub const METHOD_DELETE = "schedule.delete";
pub const METHOD_RUN = "schedule.run";

pub const MAX_SCHEDULES: i64 = 200;
pub const MAX_PROMPT_BYTES: usize = 16 * 1024;
pub const MAX_NAME_BYTES: usize = 120;
pub const MAX_LABEL_BYTES: usize = 32;
pub const MIN_INTERVAL_MINUTES: i64 = 5;
pub const MAX_INTERVAL_MINUTES: i64 = 7 * 24 * 60;
/// Scheduler wake period; create/update also wake it immediately.
pub const TICK_MS: i64 = 15 * std.time.ms_per_s;
/// A `once` time this far in the past is a mistake, not a catch-up.
pub const PAST_TOLERANCE_MS: i64 = 60 * std.time.ms_per_s;

/// Side table created at store open (like companion_roster), so no schema
/// version bump strands older binaries on the same database. `pending_*`
/// hold a claimed run that has not reached its chat yet (target busy), so a
/// retry reuses the same turn identity and new-chat thread.
pub const SCHEMA_SQL: [:0]const u8 =
    \\create table if not exists schedules (
    \\ id text primary key,
    \\ name text not null,
    \\ prompt text not null,
    \\ workspace_id text not null,
    \\ target_json text not null,
    \\ repeat_json text not null,
    \\ enabled integer not null default 1,
    \\ parent_workspace_id text,
    \\ parent_thread_id text,
    \\ created_by text,
    \\ next_run_ms integer,
    \\ last_run_ms integer,
    \\ last_status text,
    \\ last_error text,
    \\ last_thread_id text,
    \\ run_count integer not null default 0,
    \\ created_at_ms integer not null,
    \\ updated_at_ms integer not null,
    \\ pending_run_id text,
    \\ pending_late integer not null default 0,
    \\ pending_thread_id text
    \\);
;

pub fn initialize(conn: zqlite.Conn) !void {
    try conn.execNoArgs(SCHEMA_SQL);
}

pub const Target = union(enum) {
    thread: struct { workspace_id: []const u8, thread_id: []const u8 },
    new_chat: struct { workspace_id: []const u8, provider: []const u8, model: ?[]const u8 = null },

    pub fn workspaceId(self: Target) []const u8 {
        return switch (self) {
            inline else => |value| value.workspace_id,
        };
    }
};

pub const Repeat = union(enum) {
    once: struct { at_ms: i64 },
    interval: struct { every_minutes: i64 },
    /// `weekdays` is a bit mask (bit 0 = Sunday); 0 means every day.
    daily: struct { hour: u8, minute: u8, weekdays: u8 = 0 },
};

pub const Schedule = struct {
    id: []const u8,
    name: []const u8,
    prompt: []const u8,
    target: Target,
    repeat: Repeat,
    enabled: bool,
    parent_workspace_id: ?[]const u8,
    parent_thread_id: ?[]const u8,
    created_by: ?[]const u8,
    next_run_ms: ?i64,
    last_run_ms: ?i64,
    last_status: ?[]const u8,
    last_error: ?[]const u8,
    last_thread_id: ?[]const u8,
    run_count: i64,
    created_at_ms: i64,
    updated_at_ms: i64,
    pending_run_id: ?[]const u8,
    pending_late: bool,
    pending_thread_id: ?[]const u8,
};

/// Human message for the `invalid_params` reply.
pub const Diagnostic = struct {
    message: []const u8 = "invalid schedule",

    fn fail(self: *Diagnostic, message: []const u8) error{InvalidParams} {
        self.message = message;
        return error.InvalidParams;
    }
};

pub const CreateInput = struct {
    name: ?[]const u8 = null,
    prompt: []const u8,
    target: Target,
    repeat: Repeat,
    enabled: bool = true,
    parent_workspace_id: ?[]const u8 = null,
    parent_thread_id: ?[]const u8 = null,
    created_by: ?[]const u8 = null,
};

pub const Patch = struct {
    name: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    target: ?Target = null,
    repeat: ?Repeat = null,
    enabled: ?bool = null,
};

// ---- JSON params ------------------------------------------------------------

fn field(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    const value = object.get(name) orelse return null;
    return if (value == .null) null else value;
}

fn stringField(object: std.json.ObjectMap, name: []const u8, diag: *Diagnostic, message: []const u8) !?[]const u8 {
    const value = field(object, name) orelse return null;
    if (value != .string) return diag.fail(message);
    return value.string;
}

fn intField(object: std.json.ObjectMap, name: []const u8, diag: *Diagnostic, message: []const u8) !?i64 {
    const value = field(object, name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .float => |number| if (@floor(number) == number and @abs(number) < 9.0e15) @as(i64, @intFromFloat(number)) else diag.fail(message),
        else => diag.fail(message),
    };
}

pub fn parseTarget(value: std.json.Value, diag: *Diagnostic) !Target {
    if (value != .object) return diag.fail("target must be an object");
    const object = value.object;
    const kind = (try stringField(object, "kind", diag, "target.kind must be a string")) orelse return diag.fail("target.kind is required (thread or new_chat)");
    const workspace_id = (try stringField(object, "workspace_id", diag, "target.workspace_id must be a string")) orelse "";
    if (workspace_id.len == 0) return diag.fail("target.workspace_id is required");
    if (std.mem.eql(u8, kind, "thread")) {
        const thread_id = (try stringField(object, "thread_id", diag, "target.thread_id must be a string")) orelse "";
        if (thread_id.len == 0) return diag.fail("target.thread_id is required for a thread target");
        return .{ .thread = .{ .workspace_id = workspace_id, .thread_id = thread_id } };
    }
    if (std.mem.eql(u8, kind, "new_chat")) {
        const provider = (try stringField(object, "provider", diag, "target.provider must be a string")) orelse "";
        if (provider.len == 0) return diag.fail("target.provider is required for a new_chat target");
        const model = try stringField(object, "model", diag, "target.model must be a string");
        return .{ .new_chat = .{ .workspace_id = workspace_id, .provider = provider, .model = if (model) |text| (if (text.len == 0) null else text) else null } };
    }
    return diag.fail("target.kind must be thread or new_chat");
}

pub fn parseRepeat(value: std.json.Value, diag: *Diagnostic) !Repeat {
    if (value != .object) return diag.fail("repeat must be an object");
    const object = value.object;
    const kind = (try stringField(object, "kind", diag, "repeat.kind must be a string")) orelse return diag.fail("repeat.kind is required (once, interval or daily)");
    if (std.mem.eql(u8, kind, "once")) {
        const at_ms = (try intField(object, "at_ms", diag, "repeat.at_ms must be an integer (UTC epoch milliseconds)")) orelse
            return diag.fail("repeat.at_ms is required for a once schedule");
        if (at_ms <= 0) return diag.fail("repeat.at_ms must be a positive epoch time in milliseconds");
        return .{ .once = .{ .at_ms = at_ms } };
    }
    if (std.mem.eql(u8, kind, "interval")) {
        const minutes = (try intField(object, "every_minutes", diag, "repeat.every_minutes must be an integer")) orelse
            return diag.fail("repeat.every_minutes is required for an interval schedule");
        if (minutes < MIN_INTERVAL_MINUTES or minutes > MAX_INTERVAL_MINUTES) return diag.fail("repeat.every_minutes must be between 5 and 10080 (one week)");
        return .{ .interval = .{ .every_minutes = minutes } };
    }
    if (std.mem.eql(u8, kind, "daily")) {
        const time = (try stringField(object, "time", diag, "repeat.time must be a string")) orelse
            return diag.fail("repeat.time is required for a daily schedule (HH:MM, 24-hour)");
        const clock = parseClock(time) orelse return diag.fail("repeat.time must be HH:MM in 24-hour time, for example 09:00");
        var mask: u8 = 0;
        if (field(object, "weekdays")) |weekdays| {
            if (weekdays != .array) return diag.fail("repeat.weekdays must be an array of integers 0-6 (0 = Sunday)");
            for (weekdays.array.items) |day| {
                if (day != .integer or day.integer < 0 or day.integer > 6) return diag.fail("repeat.weekdays must be an array of integers 0-6 (0 = Sunday)");
                mask |= @as(u8, 1) << @intCast(day.integer);
            }
        }
        if (mask == ALL_DAYS) mask = 0;
        return .{ .daily = .{ .hour = clock.hour, .minute = clock.minute, .weekdays = mask } };
    }
    return diag.fail("repeat.kind must be once, interval or daily");
}

const ALL_DAYS: u8 = 0x7f;

pub fn parseCreate(params: std.json.Value, diag: *Diagnostic) !CreateInput {
    if (params != .object) return diag.fail("params must be an object");
    const object = params.object;
    const prompt = (try stringField(object, "prompt", diag, "prompt must be a string")) orelse return diag.fail("prompt is required");
    const target = parseTarget(field(object, "target") orelse return diag.fail("target is required"), diag) catch |err| return err;
    const repeat = parseRepeat(field(object, "repeat") orelse return diag.fail("repeat is required"), diag) catch |err| return err;
    const enabled = if (field(object, "enabled")) |value| switch (value) {
        .bool => |flag| flag,
        else => return diag.fail("enabled must be a boolean"),
    } else true;
    return .{
        .name = try stringField(object, "name", diag, "name must be a string"),
        .prompt = prompt,
        .target = target,
        .repeat = repeat,
        .enabled = enabled,
        .parent_workspace_id = nonEmpty(try stringField(object, "parent_workspace_id", diag, "parent_workspace_id must be a string")),
        .parent_thread_id = nonEmpty(try stringField(object, "parent_thread_id", diag, "parent_thread_id must be a string")),
        .created_by = nonEmpty(try stringField(object, "created_by", diag, "created_by must be a string")),
    };
}

pub fn parseId(params: std.json.Value, diag: *Diagnostic) ![]const u8 {
    if (params != .object) return diag.fail("params must be an object");
    const id = (try stringField(params.object, "id", diag, "id must be a string")) orelse "";
    if (id.len == 0) return diag.fail("id is required");
    return id;
}

pub fn parsePatch(params: std.json.Value, diag: *Diagnostic) !Patch {
    if (params != .object) return diag.fail("params must be an object");
    const object = params.object;
    var patch: Patch = .{};
    patch.name = try stringField(object, "name", diag, "name must be a string");
    patch.prompt = try stringField(object, "prompt", diag, "prompt must be a string");
    if (field(object, "target")) |value| patch.target = try parseTarget(value, diag);
    if (field(object, "repeat")) |value| patch.repeat = try parseRepeat(value, diag);
    if (field(object, "enabled")) |value| {
        if (value != .bool) return diag.fail("enabled must be a boolean");
        patch.enabled = value.bool;
    }
    return patch;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (std.mem.trim(u8, text, " \t\r\n").len == 0) null else text;
}

// ---- JSON output ------------------------------------------------------------

pub fn writeTarget(s: *std.json.Stringify, target: Target) !void {
    try s.beginObject();
    switch (target) {
        .thread => |value| {
            try s.objectField("kind");
            try s.write("thread");
            try s.objectField("workspace_id");
            try s.write(value.workspace_id);
            try s.objectField("thread_id");
            try s.write(value.thread_id);
        },
        .new_chat => |value| {
            try s.objectField("kind");
            try s.write("new_chat");
            try s.objectField("workspace_id");
            try s.write(value.workspace_id);
            try s.objectField("provider");
            try s.write(value.provider);
            if (value.model) |model| {
                try s.objectField("model");
                try s.write(model);
            }
        },
    }
    try s.endObject();
}

pub fn writeRepeat(s: *std.json.Stringify, repeat: Repeat) !void {
    try s.beginObject();
    switch (repeat) {
        .once => |value| {
            try s.objectField("kind");
            try s.write("once");
            try s.objectField("at_ms");
            try s.write(value.at_ms);
        },
        .interval => |value| {
            try s.objectField("kind");
            try s.write("interval");
            try s.objectField("every_minutes");
            try s.write(value.every_minutes);
        },
        .daily => |value| {
            try s.objectField("kind");
            try s.write("daily");
            try s.objectField("time");
            var buffer: [5]u8 = undefined;
            try s.write(formatClock(&buffer, value.hour, value.minute));
            try s.objectField("weekdays");
            try s.beginArray();
            var day: u3 = 0;
            while (true) : (day += 1) {
                if (value.weekdays & (@as(u8, 1) << day) != 0) try s.write(@as(u8, day));
                if (day == 6) break;
            }
            try s.endArray();
        },
    }
    try s.endObject();
}

/// The spec's schedule object.
pub fn writeSchedule(s: *std.json.Stringify, schedule: Schedule) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(schedule.id);
    try s.objectField("name");
    try s.write(schedule.name);
    try s.objectField("prompt");
    try s.write(schedule.prompt);
    try s.objectField("target");
    try writeTarget(s, schedule.target);
    try s.objectField("repeat");
    try writeRepeat(s, schedule.repeat);
    try s.objectField("enabled");
    try s.write(schedule.enabled);
    try s.objectField("parent_workspace_id");
    try s.write(schedule.parent_workspace_id);
    try s.objectField("parent_thread_id");
    try s.write(schedule.parent_thread_id);
    try s.objectField("created_by");
    try s.write(schedule.created_by);
    try s.objectField("next_run_ms");
    try s.write(schedule.next_run_ms);
    try s.objectField("last_run_ms");
    try s.write(schedule.last_run_ms);
    try s.objectField("last_status");
    try s.write(schedule.last_status);
    try s.objectField("last_error");
    try s.write(schedule.last_error);
    try s.objectField("last_thread_id");
    try s.write(schedule.last_thread_id);
    try s.objectField("run_count");
    try s.write(schedule.run_count);
    try s.objectField("created_at_ms");
    try s.write(schedule.created_at_ms);
    try s.objectField("updated_at_ms");
    try s.write(schedule.updated_at_ms);
    try s.endObject();
}

fn encodeAlloc(allocator: std.mem.Allocator, value: anytype, comptime writeFn: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try writeFn(&s, value);
    return try out.toOwnedSlice();
}

/// The user turn a run sends: a short provenance note, then the prompt.
pub fn runPromptAlloc(allocator: std.mem.Allocator, schedule: Schedule) ![]u8 {
    const name = try std.mem.replaceOwned(u8, allocator, schedule.name, "\"", "'");
    defer allocator.free(name);
    return std.fmt.allocPrint(
        allocator,
        "<verde_schedule id=\"{s}\" name=\"{s}\">This turn was started by a Verde scheduled task. Do the task and report the result briefly.</verde_schedule>\n\n{s}",
        .{ schedule.id, name, schedule.prompt },
    );
}

// ---- local time -------------------------------------------------------------

/// Which clock a wall time is read on. Production uses the host's local zone;
/// tests pin a fixed offset so they do not depend on the machine's TZ.
pub const Zone = union(enum) {
    local,
    /// Seconds east of UTC.
    fixed: i32,
};

pub const LocalTime = struct {
    year: i32,
    /// 1-12.
    month: u8,
    /// 1-31.
    day: u8,
    hour: u8,
    minute: u8,
    /// 0 = Sunday.
    weekday: u8,
};

/// libc `struct tm`. The nine standard fields are common to every libc; glibc,
/// musl and the BSDs append `tm_gmtoff`/`tm_zone`, so trailing room lets
/// libc write those without a per-platform layout.
const Tm = extern struct {
    sec: c_int = 0,
    min: c_int = 0,
    hour: c_int = 0,
    mday: c_int = 0,
    mon: c_int = 0,
    year: c_int = 0,
    wday: c_int = 0,
    yday: c_int = 0,
    isdst: c_int = 0,
    reserved: [8]u64 = @splat(0),
};

const libc = if (builtin.os.tag == .windows) struct {
    const Time = i64;
    extern "c" fn _localtime64_s(result: *Tm, timer: *const i64) c_int;
    extern "c" fn _mktime64(tm: *Tm) i64;
    fn localtime(timer: *const Time, result: *Tm) bool {
        return _localtime64_s(result, timer) == 0;
    }
    fn mktime(tm: *Tm) Time {
        return _mktime64(tm);
    }
} else struct {
    const Time = std.c.time_t;
    extern "c" fn localtime_r(timer: *const Time, result: *Tm) ?*Tm;
    extern "c" fn mktime(tm: *Tm) Time;
    fn localtime(timer: *const Time, result: *Tm) bool {
        return localtime_r(timer, result) != null;
    }
};

pub fn toLocal(zone: Zone, epoch_s: i64) ?LocalTime {
    switch (zone) {
        .fixed => |offset| {
            const local_s = epoch_s + offset;
            const days = @divFloor(local_s, std.time.s_per_day);
            const second_of_day = @mod(local_s, std.time.s_per_day);
            const civil = civilFromDays(days);
            return .{
                .year = civil.year,
                .month = civil.month,
                .day = civil.day,
                .hour = @intCast(@divFloor(second_of_day, 3600)),
                .minute = @intCast(@divFloor(@mod(second_of_day, 3600), 60)),
                .weekday = weekdayFromDays(days),
            };
        },
        .local => {
            const timer: libc.Time = std.math.cast(libc.Time, epoch_s) orelse return null;
            var tm: Tm = .{};
            if (!libc.localtime(&timer, &tm)) return null;
            return .{
                .year = @as(i32, tm.year) + 1900,
                .month = @intCast(tm.mon + 1),
                .day = @intCast(tm.mday),
                .hour = @intCast(tm.hour),
                .minute = @intCast(tm.min),
                .weekday = @intCast(tm.wday),
            };
        },
    }
}

pub const Resolved = struct { epoch_s: i64, weekday: u8 };

/// Epoch seconds for a wall time. `day` may run past the month (it
/// normalizes like mktime). Local times inside a DST gap resolve the way
/// libc's mktime does (typically one hour later).
pub fn fromLocal(zone: Zone, year: i32, month: u8, day: i32, hour: u8, minute: u8) ?Resolved {
    switch (zone) {
        .fixed => |offset| {
            const days = daysFromCivil(year, month, 1) + day - 1;
            const local_s = days * std.time.s_per_day + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
            return .{ .epoch_s = local_s - offset, .weekday = weekdayFromDays(days) };
        },
        .local => {
            var tm: Tm = .{
                .year = year - 1900,
                .mon = @as(c_int, month) - 1,
                .mday = std.math.cast(c_int, day) orelse return null,
                .hour = hour,
                .min = minute,
                .isdst = -1,
            };
            const result = libc.mktime(&tm);
            if (result == -1) return null;
            return .{ .epoch_s = @intCast(result), .weekday = @intCast(@mod(tm.wday, 7)) };
        },
    }
}

/// Epoch milliseconds for "YYYY-MM-DD HH:MM" (or "YYYY-MM-DDTHH:MM") in `zone`.
pub fn parseLocalDateTime(zone: Zone, text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len != 16 or trimmed[4] != '-' or trimmed[7] != '-' or (trimmed[10] != ' ' and trimmed[10] != 'T')) return null;
    const year = std.fmt.parseInt(i32, trimmed[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, trimmed[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, trimmed[8..10], 10) catch return null;
    const clock = parseClock(trimmed[11..]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    const resolved = fromLocal(zone, year, month, day, clock.hour, clock.minute) orelse return null;
    return resolved.epoch_s * std.time.ms_per_s;
}

/// Next time after `now_ms` (strictly) that the wall clock in `zone` reads
/// hour:minute on an allowed weekday.
pub fn nextDailyMs(zone: Zone, now_ms: i64, hour: u8, minute: u8, weekdays: u8) ?i64 {
    const today = toLocal(zone, @divFloor(now_ms, std.time.ms_per_s)) orelse return null;
    var offset: i32 = 0;
    // Eight days covers "today already passed" plus a full week.
    while (offset <= 8) : (offset += 1) {
        const candidate = fromLocal(zone, today.year, today.month, @as(i32, today.day) + offset, hour, minute) orelse continue;
        const candidate_ms = candidate.epoch_s * std.time.ms_per_s;
        if (candidate_ms <= now_ms) continue;
        if (weekdays != 0 and weekdays & (@as(u8, 1) << @intCast(candidate.weekday)) == 0) continue;
        return candidate_ms;
    }
    return null;
}

/// When an enabled schedule should next fire, counted from `now_ms` so missed
/// runs never stack up. A `once` keeps its own time, even when that is past
/// (it then fires immediately, for example on catch-up after downtime).
pub fn nextRunMs(zone: Zone, repeat: Repeat, now_ms: i64) ?i64 {
    return switch (repeat) {
        .once => |value| value.at_ms,
        .interval => |value| now_ms + value.every_minutes * std.time.ms_per_min,
        .daily => |value| nextDailyMs(zone, now_ms, value.hour, value.minute, value.weekdays),
    };
}

fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(days: i64) struct { year: i32, month: u8, day: u8 } {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year = yoe + era * 400 + @intFromBool(month <= 2);
    return .{ .year = @intCast(year), .month = month, .day = day };
}

fn weekdayFromDays(days: i64) u8 {
    // 1970-01-01 was a Thursday.
    return @intCast(@mod(days + 4, 7));
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub const Clock = struct { hour: u8, minute: u8 };

/// "HH:MM" (or "H:MM") in 24-hour time.
pub fn parseClock(text: []const u8) ?Clock {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    if (colon == 0 or colon > 2 or text.len != colon + 3) return null;
    const hour = std.fmt.parseInt(u8, text[0..colon], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[colon + 1 ..], 10) catch return null;
    if (hour > 23 or minute > 59) return null;
    return .{ .hour = hour, .minute = minute };
}

fn formatClock(buffer: *[5]u8, hour: u8, minute: u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{ hour, minute }) catch unreachable;
}

const DAY_NAMES = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
const DAY_LABELS = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

fn parseDay(token: []const u8) ?u3 {
    if (token.len == 1 and token[0] >= '0' and token[0] <= '6') return @intCast(token[0] - '0');
    if (token.len < 3) return null;
    for (DAY_NAMES, 0..) |name, index| {
        if (std.ascii.eqlIgnoreCase(token[0..3], name)) return @intCast(index);
    }
    return null;
}

/// Weekday mask from CLI text: "mon-fri", "sun,sat", "weekdays", "weekends",
/// "fri-mon" (ranges wrap), or digits 0-6. Returns null on bad input.
pub fn parseWeekdays(text: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (std.ascii.eqlIgnoreCase(trimmed, "weekdays")) return 0b0111110;
    if (std.ascii.eqlIgnoreCase(trimmed, "weekends")) return 0b1000001;
    if (std.ascii.eqlIgnoreCase(trimmed, "daily") or std.ascii.eqlIgnoreCase(trimmed, "all") or std.ascii.eqlIgnoreCase(trimmed, "every")) return ALL_DAYS;
    var mask: u8 = 0;
    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) return null;
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const first = parseDay(std.mem.trim(u8, part[0..dash], " ")) orelse return null;
            const last = parseDay(std.mem.trim(u8, part[dash + 1 ..], " ")) orelse return null;
            var day: u3 = first;
            while (true) {
                mask |= @as(u8, 1) << day;
                if (day == last) break;
                day = if (day == 6) 0 else day + 1;
            }
        } else {
            mask |= @as(u8, 1) << (parseDay(part) orelse return null);
        }
    }
    return if (mask == 0) null else mask;
}

/// Minutes from "30m", "2h", "1d", "1h30m" or a bare number of minutes.
pub fn parseDurationMinutes(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    var total: i64 = 0;
    var index: usize = 0;
    while (index < trimmed.len) {
        const start = index;
        while (index < trimmed.len and std.ascii.isDigit(trimmed[index])) index += 1;
        if (index == start) return null;
        const amount = std.fmt.parseInt(i64, trimmed[start..index], 10) catch return null;
        const unit: i64 = if (index == trimmed.len) 1 else switch (std.ascii.toLower(trimmed[index])) {
            'm' => 1,
            'h' => 60,
            'd' => 24 * 60,
            'w' => 7 * 24 * 60,
            else => return null,
        };
        if (index < trimmed.len) index += 1;
        total = std.math.add(i64, total, std.math.mul(i64, amount, unit) catch return null) catch return null;
    }
    return if (total > 0) total else null;
}

/// Human repeat summary: "Weekdays at 09:00", "Every 2 hours", "Once · Tue 14:30".
pub fn describeRepeat(writer: *std.Io.Writer, zone: Zone, repeat: Repeat) !void {
    switch (repeat) {
        .once => |value| {
            const local = toLocal(zone, @divFloor(value.at_ms, std.time.ms_per_s)) orelse return writer.writeAll("Once");
            try writer.print("Once · {s} {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ DAY_LABELS[local.weekday], local.year, local.month, local.day, local.hour, local.minute });
        },
        .interval => |value| {
            const minutes = value.every_minutes;
            if (@mod(minutes, 24 * 60) == 0) {
                const days = @divExact(minutes, 24 * 60);
                if (days == 1) try writer.writeAll("Every day") else try writer.print("Every {d} days", .{days});
            } else if (@mod(minutes, 60) == 0) {
                const hours = @divExact(minutes, 60);
                if (hours == 1) try writer.writeAll("Every hour") else try writer.print("Every {d} hours", .{hours});
            } else try writer.print("Every {d} minutes", .{minutes});
        },
        .daily => |value| {
            var buffer: [5]u8 = undefined;
            const clock = formatClock(&buffer, value.hour, value.minute);
            switch (value.weekdays) {
                0, ALL_DAYS => try writer.print("Daily at {s}", .{clock}),
                0b0111110 => try writer.print("Weekdays at {s}", .{clock}),
                0b1000001 => try writer.print("Weekends at {s}", .{clock}),
                else => {
                    var first = true;
                    for (DAY_LABELS, 0..) |label, index| {
                        if (value.weekdays & (@as(u8, 1) << @intCast(index)) == 0) continue;
                        if (!first) try writer.writeAll(", ");
                        first = false;
                        try writer.writeAll(label);
                    }
                    try writer.print(" at {s}", .{clock});
                },
            }
        },
    }
}

// ---- store ------------------------------------------------------------------

const COLUMNS = "id,name,prompt,target_json,repeat_json,enabled,parent_workspace_id,parent_thread_id,created_by," ++
    "next_run_ms,last_run_ms,last_status,last_error,last_thread_id,run_count,created_at_ms,updated_at_ms," ++
    "pending_run_id,pending_late,pending_thread_id";

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn fromRow(arena: std.mem.Allocator, row: zqlite.Row) !Schedule {
    var diag: Diagnostic = .{};
    const target_value = std.json.parseFromSliceLeaky(std.json.Value, arena, row.text(3), .{ .allocate = .alloc_always }) catch return error.StoreCorrupt;
    const repeat_value = std.json.parseFromSliceLeaky(std.json.Value, arena, row.text(4), .{ .allocate = .alloc_always }) catch return error.StoreCorrupt;
    return .{
        .id = try arena.dupe(u8, row.text(0)),
        .name = try arena.dupe(u8, row.text(1)),
        .prompt = try arena.dupe(u8, row.text(2)),
        .target = parseTarget(target_value, &diag) catch return error.StoreCorrupt,
        .repeat = parseRepeat(repeat_value, &diag) catch return error.StoreCorrupt,
        .enabled = row.int(5) != 0,
        .parent_workspace_id = try dupeOptional(arena, row.nullableText(6)),
        .parent_thread_id = try dupeOptional(arena, row.nullableText(7)),
        .created_by = try dupeOptional(arena, row.nullableText(8)),
        .next_run_ms = row.nullableInt(9),
        .last_run_ms = row.nullableInt(10),
        .last_status = try dupeOptional(arena, row.nullableText(11)),
        .last_error = try dupeOptional(arena, row.nullableText(12)),
        .last_thread_id = try dupeOptional(arena, row.nullableText(13)),
        .run_count = row.int(14),
        .created_at_ms = row.int(15),
        .updated_at_ms = row.int(16),
        .pending_run_id = try dupeOptional(arena, row.nullableText(17)),
        .pending_late = row.int(18) != 0,
        .pending_thread_id = try dupeOptional(arena, row.nullableText(19)),
    };
}

pub fn get(conn: zqlite.Conn, arena: std.mem.Allocator, id: []const u8) !?Schedule {
    var row = (try conn.row("select " ++ COLUMNS ++ " from schedules where id=?", .{id})) orelse return null;
    defer row.deinit();
    return try fromRow(arena, row);
}

/// Every schedule, soonest first and disabled last. `workspace_id` keeps
/// those that target that workspace or report to a chat in it.
pub fn list(conn: zqlite.Conn, arena: std.mem.Allocator, workspace_id: ?[]const u8) ![]Schedule {
    var out: std.ArrayList(Schedule) = .empty;
    var rows = if (workspace_id) |workspace|
        try conn.rows("select " ++ COLUMNS ++ " from schedules where workspace_id=?1 or parent_workspace_id=?1 order by enabled desc, next_run_ms is null, next_run_ms, created_at_ms, id", .{workspace})
    else
        try conn.rows("select " ++ COLUMNS ++ " from schedules order by enabled desc, next_run_ms is null, next_run_ms, created_at_ms, id", .{});
    defer rows.deinit();
    while (rows.next()) |row| try out.append(arena, try fromRow(arena, row));
    if (rows.err) |err| return err;
    return out.toOwnedSlice(arena);
}

fn defaultNameAlloc(arena: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    const first_line = std.mem.trim(u8, trimmed[0 .. std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len], " \t");
    if (first_line.len <= MAX_NAME_BYTES) return arena.dupe(u8, first_line);
    var end: usize = MAX_NAME_BYTES - "…".len;
    while (end > 0 and (first_line[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}…", .{std.mem.trimEnd(u8, first_line[0..end], " \t")});
}

fn validateText(prompt: []const u8, name: []const u8, diag: *Diagnostic) !void {
    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) return diag.fail("prompt cannot be empty");
    if (prompt.len > MAX_PROMPT_BYTES) return diag.fail("prompt must be at most 16384 bytes");
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return diag.fail("name cannot be empty");
    if (name.len > MAX_NAME_BYTES) return diag.fail("name must be at most 120 bytes");
    if (std.mem.indexOfAny(u8, name, "\r\n") != null) return diag.fail("name must be a single line");
}

fn validateRepeatTime(repeat: Repeat, now_ms: i64, diag: *Diagnostic) !void {
    switch (repeat) {
        .once => |value| if (value.at_ms < now_ms - PAST_TOLERANCE_MS) return diag.fail("repeat.at_ms is in the past; pick a future time"),
        else => {},
    }
}

fn validateTarget(conn: zqlite.Conn, target: Target, diag: *Diagnostic) !void {
    var workspace = (try conn.row("select archived from workspaces where workspace_id=?", .{target.workspaceId()})) orelse
        return diag.fail("target workspace not found");
    defer workspace.deinit();
    if (workspace.int(0) != 0) return diag.fail("target workspace is archived");
    switch (target) {
        .thread => |value| {
            var thread = (try conn.row("select t.archived from threads t join workspaces w on w.id=t.workspace_id where w.workspace_id=? and t.local_thread_id=?", .{ value.workspace_id, value.thread_id })) orelse
                return diag.fail("target thread not found in that workspace");
            defer thread.deinit();
            if (thread.int(0) != 0) return diag.fail("target thread is archived");
        },
        .new_chat => {},
    }
}

fn mintId(arena: std.mem.Allocator, now_ms: i64) ![]const u8 {
    var random_bytes: [2]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&random_bytes);
    return std.fmt.allocPrint(arena, "sch-{d}-{s}", .{ now_ms, std.fmt.bytesToHex(random_bytes, .lower) });
}

/// Validates and stores a new schedule. Provider names are checked by the
/// caller (it owns the provider registry).
pub fn create(conn: zqlite.Conn, arena: std.mem.Allocator, zone: Zone, input: CreateInput, now_ms: i64, diag: *Diagnostic) !Schedule {
    {
        var count = (try conn.row("select count(*) from schedules", .{})).?;
        defer count.deinit();
        if (count.int(0) >= MAX_SCHEDULES) return diag.fail("at most 200 scheduled tasks; delete one first");
    }
    const name = if (input.name) |text| std.mem.trim(u8, text, " \t") else try defaultNameAlloc(arena, input.prompt);
    try validateText(input.prompt, name, diag);
    if (input.created_by) |label| if (label.len > MAX_LABEL_BYTES) return diag.fail("created_by must be at most 32 bytes");
    if (input.enabled) try validateRepeatTime(input.repeat, now_ms, diag);
    try validateTarget(conn, input.target, diag);
    var parent_workspace_id = input.parent_workspace_id;
    if (input.parent_thread_id) |parent| {
        const hint = input.parent_workspace_id orelse input.target.workspaceId();
        parent_workspace_id = (try chat_links.resolveParentWorkspace(conn, arena, hint, parent)) orelse
            return diag.fail("parent thread not found");
    } else if (input.parent_workspace_id != null) return diag.fail("parent_workspace_id needs parent_thread_id");

    const id = try mintId(arena, now_ms);
    const target_json = try encodeAlloc(arena, input.target, writeTarget);
    const repeat_json = try encodeAlloc(arena, input.repeat, writeRepeat);
    const next_run_ms: ?i64 = if (input.enabled) nextRunMs(zone, input.repeat, now_ms) else null;
    try conn.exec(
        "insert into schedules(id,name,prompt,workspace_id,target_json,repeat_json,enabled,parent_workspace_id,parent_thread_id,created_by,next_run_ms,created_at_ms,updated_at_ms) values(?,?,?,?,?,?,?,?,?,?,?,?,?)",
        .{ id, name, input.prompt, input.target.workspaceId(), target_json, repeat_json, @as(i64, @intFromBool(input.enabled)), parent_workspace_id, input.parent_thread_id, input.created_by, next_run_ms, now_ms, now_ms },
    );
    return (try get(conn, arena, id)).?;
}

/// Applies a partial edit. `next_run_ms` is recomputed when the repeat or the
/// enabled flag changes; a disable or a new target drops any run still
/// waiting for its chat.
pub fn update(conn: zqlite.Conn, arena: std.mem.Allocator, zone: Zone, id: []const u8, patch: Patch, now_ms: i64, diag: *Diagnostic) !Schedule {
    const current = (try get(conn, arena, id)) orelse return error.NotFound;
    const prompt = patch.prompt orelse current.prompt;
    const name = if (patch.name) |text| std.mem.trim(u8, text, " \t") else current.name;
    try validateText(prompt, name, diag);
    const target = patch.target orelse current.target;
    if (patch.target != null) try validateTarget(conn, target, diag);
    const repeat = patch.repeat orelse current.repeat;
    const enabled = patch.enabled orelse current.enabled;
    const reschedule = patch.repeat != null or (patch.enabled != null and patch.enabled.? != current.enabled);
    if (reschedule and enabled) try validateRepeatTime(repeat, now_ms, diag);
    const next_run_ms: ?i64 = if (!enabled) null else if (reschedule) nextRunMs(zone, repeat, now_ms) else current.next_run_ms;
    const drop_pending = !enabled or patch.target != null;
    try conn.exec(
        "update schedules set name=?,prompt=?,workspace_id=?,target_json=?,repeat_json=?,enabled=?,next_run_ms=?,updated_at_ms=?," ++
            "pending_run_id=case when ? then null else pending_run_id end,pending_thread_id=case when ? then null else pending_thread_id end where id=?",
        .{
            name,                                        prompt,
            target.workspaceId(),                        try encodeAlloc(arena, target, writeTarget),
            try encodeAlloc(arena, repeat, writeRepeat), @as(i64, @intFromBool(enabled)),
            next_run_ms,                                 now_ms,
            @as(i64, @intFromBool(drop_pending)),        @as(i64, @intFromBool(drop_pending)),
            id,
        },
    );
    return (try get(conn, arena, id)).?;
}

pub fn delete(conn: zqlite.Conn, id: []const u8) !bool {
    try conn.exec("delete from schedules where id=?", .{id});
    return conn.changes() > 0;
}

/// Claims every enabled schedule that is due: records a pending run keyed by
/// its due time (a stable turn identity across retries and restarts) and
/// moves `next_run_ms` on from now. A `once` is disabled once claimed.
/// `late` marks runs found due on the daemon's startup catch-up.
pub fn claimDue(conn: zqlite.Conn, arena: std.mem.Allocator, zone: Zone, now_ms: i64, late: bool) !usize {
    var due: std.ArrayList(Schedule) = .empty;
    {
        var rows = try conn.rows("select " ++ COLUMNS ++ " from schedules where enabled=1 and pending_run_id is null and next_run_ms is not null and next_run_ms<=? order by next_run_ms", .{now_ms});
        defer rows.deinit();
        while (rows.next()) |row| try due.append(arena, try fromRow(arena, row));
        if (rows.err) |err| return err;
    }
    for (due.items) |schedule| {
        const run_id = try std.fmt.allocPrint(arena, "schedule:{s}:{d}", .{ schedule.id, schedule.next_run_ms.? });
        const is_once = schedule.repeat == .once;
        const next: ?i64 = if (is_once) null else nextRunMs(zone, schedule.repeat, now_ms);
        try conn.exec(
            "update schedules set pending_run_id=?,pending_late=?,pending_thread_id=null,next_run_ms=?,enabled=case when ? then 0 else enabled end where id=? and pending_run_id is null",
            .{ run_id, @as(i64, @intFromBool(late)), next, @as(i64, @intFromBool(is_once)), schedule.id },
        );
    }
    return due.items.len;
}

/// Starts a manual run now. It leaves `next_run_ms` alone except that a
/// `once` is used up. When a run is already waiting for its chat, that run
/// is retried instead of adding a second.
pub fn beginManualRun(conn: zqlite.Conn, arena: std.mem.Allocator, id: []const u8, now_ms: i64) !Schedule {
    const current = (try get(conn, arena, id)) orelse return error.NotFound;
    if (current.pending_run_id == null) {
        const run_id = try std.fmt.allocPrint(arena, "schedule:{s}:run-{d}", .{ id, now_ms });
        const is_once = current.repeat == .once;
        try conn.exec(
            "update schedules set pending_run_id=?,pending_late=0,pending_thread_id=null," ++
                "enabled=case when ? then 0 else enabled end,next_run_ms=case when ? then null else next_run_ms end where id=?",
            .{ run_id, @as(i64, @intFromBool(is_once)), @as(i64, @intFromBool(is_once)), id },
        );
    }
    return (try get(conn, arena, id)).?;
}

/// Runs that were claimed but have not reached their chat yet.
pub fn pending(conn: zqlite.Conn, arena: std.mem.Allocator) ![]Schedule {
    var out: std.ArrayList(Schedule) = .empty;
    var rows = try conn.rows("select " ++ COLUMNS ++ " from schedules where pending_run_id is not null order by created_at_ms, id", .{});
    defer rows.deinit();
    while (rows.next()) |row| try out.append(arena, try fromRow(arena, row));
    if (rows.err) |err| return err;
    return out.toOwnedSlice(arena);
}

/// Remembers the chat a pending new_chat run created, so a retry reuses it.
pub fn setPendingThread(conn: zqlite.Conn, id: []const u8, run_id: []const u8, thread_id: []const u8) !void {
    try conn.exec("update schedules set pending_thread_id=? where id=? and pending_run_id=?", .{ thread_id, id, run_id });
}

pub const RunResult = struct {
    /// "ok", "late", "queued" or "failed".
    status: []const u8,
    err: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
};

/// Records a finished run (delivered or failed) and clears the pending run.
/// Guarded by the run id, so an edit that dropped the run wins.
pub fn finishRun(conn: zqlite.Conn, id: []const u8, run_id: []const u8, result: RunResult, now_ms: i64) !void {
    try conn.exec(
        "update schedules set last_run_ms=?,last_status=?,last_error=?,last_thread_id=coalesce(?,last_thread_id),run_count=run_count+1," ++
            "pending_run_id=null,pending_late=0,pending_thread_id=null where id=? and pending_run_id=?",
        .{ now_ms, result.status, result.err, result.thread_id, id, run_id },
    );
}

/// The target is busy: the run stays pending and is retried on the next tick.
pub fn markWaiting(conn: zqlite.Conn, id: []const u8, run_id: []const u8, thread_id: []const u8) !void {
    try conn.exec(
        "update schedules set last_status='queued',last_error=null,last_thread_id=? where id=? and pending_run_id=?",
        .{ thread_id, id, run_id },
    );
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;
const MS_PER_HOUR: i64 = std.time.ms_per_hour;
const MS_PER_DAY: i64 = std.time.ms_per_day;

fn utcMs(year: i32, month: u8, day: u8, hour: u8, minute: u8) i64 {
    return fromLocal(.{ .fixed = 0 }, year, month, day, hour, minute).?.epoch_s * std.time.ms_per_s;
}

test "calendar math round-trips and knows the weekday" {
    // 2026-10-19 is a Monday.
    const monday = utcMs(2026, 10, 19, 0, 0);
    const local = toLocal(.{ .fixed = 0 }, @divFloor(monday, 1000)).?;
    try testing.expectEqual(@as(u8, 1), local.weekday);
    try testing.expectEqual(@as(i32, 2026), local.year);
    try testing.expectEqual(@as(u8, 10), local.month);
    try testing.expectEqual(@as(u8, 19), local.day);
    // Day overflow normalizes across month and year ends.
    try testing.expectEqual(utcMs(2027, 1, 1, 9, 0), fromLocal(.{ .fixed = 0 }, 2026, 12, 32, 9, 0).?.epoch_s * 1000);
    try testing.expectEqual(utcMs(2028, 3, 1, 0, 0), fromLocal(.{ .fixed = 0 }, 2028, 2, 30, 0, 0).?.epoch_s * 1000);
    try testing.expectEqual(@as(i64, 0), utcMs(1970, 1, 1, 0, 0));
}

test "interval runs count from now" {
    const now = utcMs(2026, 10, 19, 8, 7);
    try testing.expectEqual(now + 2 * MS_PER_HOUR, nextRunMs(.{ .fixed = 0 }, .{ .interval = .{ .every_minutes = 120 } }, now).?);
    try testing.expectEqual(now + 5 * std.time.ms_per_min, nextRunMs(.local, .{ .interval = .{ .every_minutes = 5 } }, now).?);
}

test "daily runs later today, else tomorrow, across the local day boundary" {
    const zone: Zone = .{ .fixed = -5 * 3600 }; // UTC-5
    // 08:00 local on Monday 2026-10-19 = 13:00 UTC.
    const morning = utcMs(2026, 10, 19, 13, 0);
    try testing.expectEqual(utcMs(2026, 10, 19, 14, 0), nextDailyMs(zone, morning, 9, 0, 0).?);
    // Exactly at the run time the next one is tomorrow (strictly after now).
    try testing.expectEqual(utcMs(2026, 10, 20, 14, 0), nextDailyMs(zone, utcMs(2026, 10, 19, 14, 0), 9, 0, 0).?);
    // 23:30 local Monday is 04:30 UTC Tuesday; 23:45 local is still Monday.
    const late_evening = utcMs(2026, 10, 20, 4, 30);
    try testing.expectEqual(utcMs(2026, 10, 20, 4, 45), nextDailyMs(zone, late_evening, 23, 45, 0).?);
    // 00:15 local the next day is Tuesday's date even though UTC already is.
    try testing.expectEqual(utcMs(2026, 10, 20, 5, 15), nextDailyMs(zone, late_evening, 0, 15, 0).?);
    // A zone east of UTC: 07:00 UTC Monday is 12:30 Monday in UTC+5:30, so
    // 06:00 local next runs Tuesday 06:00 local = 00:30 UTC Tuesday.
    try testing.expectEqual(utcMs(2026, 10, 20, 0, 30), nextDailyMs(.{ .fixed = 5 * 3600 + 1800 }, utcMs(2026, 10, 19, 7, 0), 6, 0, 0).?);
}

test "daily weekday masks skip to the next allowed day" {
    const zone: Zone = .{ .fixed = 0 };
    const weekdays = parseWeekdays("mon-fri").?;
    // Friday 2026-10-23 at 10:00, after the 09:00 run: next is Monday 10-26.
    try testing.expectEqual(utcMs(2026, 10, 26, 9, 0), nextDailyMs(zone, utcMs(2026, 10, 23, 10, 0), 9, 0, weekdays).?);
    // Saturday morning before the run time still waits for Monday.
    try testing.expectEqual(utcMs(2026, 10, 26, 9, 0), nextDailyMs(zone, utcMs(2026, 10, 24, 7, 0), 9, 0, weekdays).?);
    // Weekends only: from Monday the next is Saturday.
    try testing.expectEqual(utcMs(2026, 10, 24, 9, 0), nextDailyMs(zone, utcMs(2026, 10, 19, 7, 0), 9, 0, parseWeekdays("sat,sun").?).?);
    // A single day already passed this week comes round a week later.
    try testing.expectEqual(utcMs(2026, 10, 26, 9, 0), nextDailyMs(zone, utcMs(2026, 10, 19, 9, 30), 9, 0, parseWeekdays("mon").?).?);
}

test "a once keeps its time even when it is already past" {
    const now = utcMs(2026, 10, 19, 12, 0);
    const past = now - 3 * MS_PER_DAY;
    try testing.expectEqual(past, nextRunMs(.local, .{ .once = .{ .at_ms = past } }, now).?);
    try testing.expect(nextRunMs(.local, .{ .once = .{ .at_ms = past } }, now).? <= now);
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidParams, validateRepeatTime(.{ .once = .{ .at_ms = past } }, now, &diag));
    try validateRepeatTime(.{ .once = .{ .at_ms = now + MS_PER_HOUR } }, now, &diag);
}

test "host local time agrees with libc for a daily run" {
    const now = std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
    const next = nextDailyMs(.local, now, 9, 30, 0).?;
    try testing.expect(next > now);
    try testing.expect(next <= now + 26 * MS_PER_HOUR);
    const local = toLocal(.local, @divFloor(next, 1000)).?;
    try testing.expectEqual(@as(u8, 30), local.minute);
    const at = parseLocalDateTime(.local, "2026-10-20 14:30").?;
    const back = toLocal(.local, @divFloor(at, 1000)).?;
    try testing.expectEqual(@as(u8, 14), back.hour);
    try testing.expectEqual(@as(u8, 20), back.day);
}

test "CLI text parsers" {
    try testing.expectEqual(@as(u8, 0b0111110), parseWeekdays("mon-fri").?);
    try testing.expectEqual(@as(u8, 0b1000001), parseWeekdays("sun,sat").?);
    try testing.expectEqual(@as(u8, 0b1100011), parseWeekdays("fri-mon").?);
    try testing.expectEqual(@as(u8, 0b0101010), parseWeekdays("Monday, wed,5").?);
    try testing.expect(parseWeekdays("funday") == null);
    try testing.expectEqual(@as(i64, 30), parseDurationMinutes("30m").?);
    try testing.expectEqual(@as(i64, 120), parseDurationMinutes("2h").?);
    try testing.expectEqual(@as(i64, 90), parseDurationMinutes("1h30m").?);
    try testing.expectEqual(@as(i64, 1440), parseDurationMinutes("1d").?);
    try testing.expectEqual(@as(i64, 45), parseDurationMinutes("45").?);
    try testing.expect(parseDurationMinutes("soon") == null);
    try testing.expectEqual(utcMs(2026, 10, 20, 14, 30), parseLocalDateTime(.{ .fixed = 0 }, "2026-10-20 14:30").?);
    try testing.expect(parseLocalDateTime(.{ .fixed = 0 }, "2026-02-30 14:30") == null);
    try testing.expect(parseClock("24:00") == null);
    try testing.expectEqual(@as(u8, 7), parseClock("7:05").?.hour);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try describeRepeat(&writer, .{ .fixed = 0 }, .{ .daily = .{ .hour = 9, .minute = 0, .weekdays = 0b0111110 } });
    try testing.expectEqualStrings("Weekdays at 09:00", writer.buffered());
    writer = .fixed(&buffer);
    try describeRepeat(&writer, .{ .fixed = 0 }, .{ .interval = .{ .every_minutes = 120 } });
    try testing.expectEqualStrings("Every 2 hours", writer.buffered());
    writer = .fixed(&buffer);
    try describeRepeat(&writer, .{ .fixed = 0 }, .{ .once = .{ .at_ms = utcMs(2026, 10, 20, 14, 30) } });
    try testing.expectEqualStrings("Once · Tue 2026-10-20 14:30", writer.buffered());
}

fn testConn() !zqlite.Conn {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    try initialize(conn);
    try conn.execNoArgs("create table workspaces (id integer primary key, workspace_id text unique, archived integer not null default 0)");
    try conn.execNoArgs("create table threads (id integer primary key, workspace_id integer, local_thread_id text, archived integer not null default 0)");
    try conn.execNoArgs("insert into workspaces(id,workspace_id) values(1,'ws')");
    try conn.execNoArgs("insert into threads(workspace_id,local_thread_id) values(1,'companion')");
    return conn;
}

test "store validates, claims due runs once, and records results" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var conn = try testConn();
    defer conn.close();
    const zone: Zone = .{ .fixed = 0 };
    const now = utcMs(2026, 10, 19, 8, 0);
    var diag: Diagnostic = .{};

    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"prompt":"Check CI\nfor every workspace","target":{"kind":"thread","workspace_id":"ws","thread_id":"companion"},
        \\ "repeat":{"kind":"daily","time":"09:00","weekdays":[1,2,3,4,5]},"created_by":"cli"}
    , .{});
    const created = try create(conn, arena, zone, try parseCreate(params, &diag), now, &diag);
    try testing.expectEqualStrings("Check CI", created.name);
    try testing.expectEqual(utcMs(2026, 10, 19, 9, 0), created.next_run_ms.?);

    const missing = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"prompt":"x","target":{"kind":"thread","workspace_id":"ws","thread_id":"nope"},"repeat":{"kind":"interval","every_minutes":60}}
    , .{});
    try testing.expectError(error.InvalidParams, create(conn, arena, zone, try parseCreate(missing, &diag), now, &diag));
    try testing.expectEqualStrings("target thread not found in that workspace", diag.message);
    const too_often = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"prompt":"x","target":{"kind":"new_chat","workspace_id":"ws","provider":"codex"},"repeat":{"kind":"interval","every_minutes":2}}
    , .{});
    try testing.expectError(error.InvalidParams, parseCreate(too_often, &diag));

    // Not due yet: nothing claimed.
    try testing.expectEqual(@as(usize, 0), try claimDue(conn, arena, zone, now, false));
    // Due: claimed once, next run moves to tomorrow, retries do not re-claim.
    const nine = utcMs(2026, 10, 19, 9, 0);
    try testing.expectEqual(@as(usize, 1), try claimDue(conn, arena, zone, nine + 5_000, true));
    try testing.expectEqual(@as(usize, 0), try claimDue(conn, arena, zone, nine + 20_000, false));
    var claimed = (try get(conn, arena, created.id)).?;
    try testing.expectEqual(utcMs(2026, 10, 20, 9, 0), claimed.next_run_ms.?);
    try testing.expect(claimed.pending_late);
    const run_id = claimed.pending_run_id.?;
    try testing.expectEqual(@as(usize, 1), (try pending(conn, arena)).len);

    try markWaiting(conn, created.id, run_id, "companion");
    try testing.expectEqualStrings("queued", (try get(conn, arena, created.id)).?.last_status.?);
    try finishRun(conn, created.id, run_id, .{ .status = "late", .thread_id = "companion" }, nine + 30_000);
    claimed = (try get(conn, arena, created.id)).?;
    try testing.expectEqualStrings("late", claimed.last_status.?);
    try testing.expectEqual(@as(i64, 1), claimed.run_count);
    try testing.expect(claimed.pending_run_id == null);

    // A manual run of a once uses it up without a second pending run.
    const once_params = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"name":"Ping","prompt":"ping","target":{"kind":"new_chat","workspace_id":"ws","provider":"codex"},"repeat":{"kind":"once","at_ms":1792500000000}}
    , .{});
    const once = try create(conn, arena, zone, try parseCreate(once_params, &diag), now, &diag);
    const manual = try beginManualRun(conn, arena, once.id, now);
    try testing.expect(!manual.enabled);
    try testing.expect(manual.next_run_ms == null);
    try testing.expectEqualStrings(manual.pending_run_id.?, (try beginManualRun(conn, arena, once.id, now + 1)).pending_run_id.?);

    // Disabling drops the waiting run; re-enabling recomputes from now.
    const disabled = try update(conn, arena, zone, created.id, .{ .enabled = false }, now, &diag);
    try testing.expect(disabled.next_run_ms == null);
    const enabled = try update(conn, arena, zone, created.id, .{ .enabled = true, .name = "Morning CI" }, now, &diag);
    try testing.expectEqual(utcMs(2026, 10, 19, 9, 0), enabled.next_run_ms.?);
    try testing.expectEqualStrings("Morning CI", enabled.name);
    try testing.expectError(error.NotFound, update(conn, arena, zone, "sch-missing", .{}, now, &diag));

    const listed = try list(conn, arena, "ws");
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expect(listed[0].enabled and !listed[1].enabled);
    try testing.expect(try delete(conn, once.id));
    try testing.expect(!try delete(conn, once.id));
}
