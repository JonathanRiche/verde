//! Scheduled tasks for the `schedules` selector. The daemon owns schedules
//! (`schedule.list/create/update/delete/run`) and fires them itself; the
//! platform only lists and edits them here. Every intent maps 1:1 to one RPC,
//! is validated locally with the daemon's rules so forms get immediate errors,
//! and every finished mutation re-reads the list. Sans-IO: each step is an
//! owned `/api/rpc` call.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const clone = @import("state_clone.zig");
const add = @import("chat_catalogs.zig").append;
const A = std.mem.Allocator;
const V = std.json.Value;
const E = h.ApiError;
const eq = h.eq;

/// Daemon limits (spec: verde scheduled tasks v1); enforced before a write.
pub const MAX_SCHEDULES = 200;
pub const MAX_PROMPT_BYTES = 16384;
pub const MAX_NAME_BYTES = 120;
pub const MIN_EVERY_MINUTES = 5;
pub const MAX_EVERY_MINUTES = 10080;
/// Concurrent create/update/delete/run calls; more fail with `busy`.
pub const MAX_OPS = 8;
const MAX_REF_BYTES = 256;
const MAX_LABEL_BYTES = 32;

/// Where a run sends the prompt, as the RPC takes it. `thread` needs
/// `workspace_id,thread_id`; `new_chat` needs `workspace_id,provider` and
/// optionally `model`.
pub const Target = struct {
    kind: []const u8,
    workspace_id: []const u8,
    thread_id: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
};
/// When it runs, as the RPC takes it (desktop host's local time). `once`
/// needs `at_ms` (UTC epoch ms); `interval` needs `every_minutes` (5–10080);
/// `daily` needs `time` "HH:MM" and optional `weekdays` (0=Sun … 6=Sat,
/// empty = every day).
pub const Repeat = struct {
    kind: []const u8,
    at_ms: ?i64 = null,
    every_minutes: ?u32 = null,
    time: ?[]const u8 = null,
    weekdays: ?[]const u16 = null,
};

/// One schedule, flattened for native lists. Empty strings mean "not set";
/// `repeat_*` fields other than the kind's own are null/empty.
pub const Schedule = struct {
    id: []const u8,
    name: []const u8 = "",
    prompt: []const u8 = "",
    /// `thread` or `new_chat`.
    target_kind: []const u8 = "thread",
    target_workspace_id: []const u8 = "",
    target_thread_id: []const u8 = "",
    target_provider: []const u8 = "",
    target_model: []const u8 = "",
    /// `once`, `interval` or `daily`.
    repeat_kind: []const u8 = "once",
    repeat_at_ms: ?i64 = null,
    repeat_every_minutes: ?u32 = null,
    repeat_time: []const u8 = "",
    repeat_weekdays: []const u16 = &.{},
    enabled: bool = true,
    parent_workspace_id: []const u8 = "",
    parent_thread_id: []const u8 = "",
    created_by: []const u8 = "",
    next_run_ms: ?i64 = null,
    last_run_ms: ?i64 = null,
    /// null (never ran), `ok`, `queued`, `failed` or `late`.
    last_status: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    last_thread_id: []const u8 = "",
    run_count: u32 = 0,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
};
/// The latest successful `schedule_run`: the chat the run used, so the
/// platform can open it.
pub const Run = struct {
    intent_id: []const u8,
    schedule_id: []const u8,
    workspace_id: []const u8 = "",
    thread_id: []const u8 = "",
    turn_id: ?[]const u8 = null,
};
/// `now_ms` is the daemon clock of the last list (0 before one), so "next run
/// in" can be shown without phone/desktop clock skew. `workspace_id` is the
/// last refresh's filter. `busy_ids` are schedules with a mutation in flight.
pub const View = struct {
    loaded: bool = false,
    loading: bool = false,
    saving: bool = false,
    supported: bool = true,
    can_edit: bool = false,
    workspace_id: ?[]const u8 = null,
    now_ms: i64 = 0,
    schedules: []const Schedule = &.{},
    busy_ids: []const []const u8 = &.{},
    last_run: ?Run = null,
    @"error": ?h.LocalError = null,
};

const Op = struct {
    rpc_id: u64,
    intent_id: []const u8,
    /// The intent tag.
    kind: []const u8,
    schedule_id: []const u8 = "",
};

pub const State = struct {
    view: View = .{},
    list_id: ?u64 = null,
    list_intent: []const u8 = "",
    /// A mutation finished while a list was in flight: read again after it.
    list_again: bool = false,
    ops: []const Op = &.{},
};

const tags = [_][]const u8{ "schedule_refresh", "schedule_create", "schedule_update", "schedule_delete", "schedule_run" };
const read: rpc.Options = .{ .mutation = false, .intent_id = "@schedules" };
const write: rpc.Options = .{ .intent_id = "@schedules" };

const Refresh = struct { workspace_id: ?[]const u8 = null };
const Create = struct {
    name: ?[]const u8 = null,
    prompt: []const u8,
    target: Target,
    repeat: Repeat,
    enabled: ?bool = null,
    parent_workspace_id: ?[]const u8 = null,
    parent_thread_id: ?[]const u8 = null,
    created_by: ?[]const u8 = null,
};
const Update = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    target: ?Target = null,
    repeat: ?Repeat = null,
    enabled: ?bool = null,
};
const Id = struct { id: []const u8 };

pub fn owns(tag: []const u8) bool {
    for (tags) |t| if (eq(t, tag)) return true;
    return false;
}

pub fn receiptFields(context: []const u8) ?[]const u8 {
    if (eq(context, "schedule_refresh")) return "workspace_id";
    if (eq(context, "schedule_create")) return "name prompt target repeat enabled parent_workspace_id parent_thread_id created_by";
    if (eq(context, "schedule_update")) return "id name prompt target repeat enabled";
    if (eq(context, "schedule_delete") or eq(context, "schedule_run")) return "id";
    if (eq(context, "target")) return "kind workspace_id thread_id provider model";
    if (eq(context, "repeat")) return "kind at_ms every_minutes time weekdays";
    return null;
}

pub fn validate(a: A, tag: []const u8, event: V) E!void {
    if (eq(tag, "schedule_refresh")) {
        _ = try h.decode(Refresh, a, event);
    } else if (eq(tag, "schedule_create")) {
        _ = try h.decode(Create, a, event);
    } else if (eq(tag, "schedule_update")) {
        _ = try h.decode(Update, a, event);
    } else if (eq(tag, "schedule_delete") or eq(tag, "schedule_run")) {
        _ = try h.decode(Id, a, event);
    }
}

pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!void {
    if (!owns(tag)) return;
    const a = tx.allocator();
    const id = try h.string(event, "intent_id");
    const s = &tx.state.schedules;
    if (!online(&tx.state)) return receipt(tx, id, "failed", failure("offline", "Connect to the host first."));
    if (eq(tag, "schedule_refresh")) {
        if (!scoped(&tx.state, "chat:read")) return receipt(tx, id, "failed", failure("insufficient_scope", "This phone can't read chats on this host."));
        const r = try h.decode(Refresh, a, event);
        if (r.workspace_id) |w| if (!ref(w)) return receipt(tx, id, "failed", failure("invalid_workspace", "Choose a workspace."));
        // Coalesce with a read of the same list in flight; a new filter supersedes it.
        if (s.list_id != null and sameFilter(s.view.workspace_id, r.workspace_id)) return receipt(tx, id, "succeeded", null);
        s.view.workspace_id = r.workspace_id;
        return requestList(tx, id);
    }
    if (!scoped(&tx.state, "chat:write")) return receipt(tx, id, "failed", failure("insufficient_scope", "This phone can't change scheduled tasks on this host."));
    if (!s.view.supported) return receipt(tx, id, "failed", failure("unsupported", "Update verde on the computer to use scheduled tasks."));
    if (s.ops.len >= MAX_OPS) return receipt(tx, id, "failed", failure("busy", "Still saving earlier changes. Try again shortly."));
    var params: std.json.ObjectMap = .empty;
    if (eq(tag, "schedule_create")) {
        const r = try h.decode(Create, a, event);
        if (s.view.loaded and s.view.workspace_id == null and s.view.schedules.len >= MAX_SCHEDULES)
            return receipt(tx, id, "failed", failure("too_many", "Keep at most 200 scheduled tasks."));
        // A blank optional name is omitted, so the daemon names it from the prompt.
        const name = if (r.name) |n| (if (blank(n)) null else n) else null;
        if (name) |n| if (invalidName(n)) |err| return receipt(tx, id, "failed", err);
        if (invalidPrompt(r.prompt)) |err| return receipt(tx, id, "failed", err);
        if (invalidTarget(r.target)) |err| return receipt(tx, id, "failed", err);
        if (invalidRepeat(r.repeat)) |err| return receipt(tx, id, "failed", err);
        if (r.parent_workspace_id) |v| if (!ref(v)) return receipt(tx, id, "failed", failure("invalid_parent", "The parent chat can't be used."));
        if (r.parent_thread_id) |v| if (!ref(v)) return receipt(tx, id, "failed", failure("invalid_parent", "The parent chat can't be used."));
        const created_by = r.created_by orelse "mobile";
        if (created_by.len == 0 or created_by.len > MAX_LABEL_BYTES) return receipt(tx, id, "failed", failure("invalid_params", "This scheduled task can't be saved."));
        if (name) |n| try params.put(a, "name", .{ .string = n });
        try params.put(a, "prompt", .{ .string = r.prompt });
        try params.put(a, "target", try targetParams(a, r.target));
        try params.put(a, "repeat", try repeatParams(a, r.repeat));
        if (r.enabled) |v| try params.put(a, "enabled", .{ .bool = v });
        if (r.parent_workspace_id) |v| try params.put(a, "parent_workspace_id", .{ .string = v });
        if (r.parent_thread_id) |v| try params.put(a, "parent_thread_id", .{ .string = v });
        try params.put(a, "created_by", .{ .string = created_by });
        return started(tx, id, tag, "", try rpc.request(tx, "schedule.create", V{ .object = params }, write));
    }
    if (eq(tag, "schedule_update")) {
        const r = try h.decode(Update, a, event);
        if (!ref(r.id)) return receipt(tx, id, "failed", failure("invalid_schedule", "This scheduled task no longer exists."));
        if (r.name) |n| if (invalidName(n)) |err| return receipt(tx, id, "failed", err);
        if (r.prompt) |v| if (invalidPrompt(v)) |err| return receipt(tx, id, "failed", err);
        if (r.target) |v| if (invalidTarget(v)) |err| return receipt(tx, id, "failed", err);
        if (r.repeat) |v| if (invalidRepeat(v)) |err| return receipt(tx, id, "failed", err);
        try params.put(a, "id", .{ .string = r.id });
        if (r.name) |v| try params.put(a, "name", .{ .string = v });
        if (r.prompt) |v| try params.put(a, "prompt", .{ .string = v });
        if (r.target) |v| try params.put(a, "target", try targetParams(a, v));
        if (r.repeat) |v| try params.put(a, "repeat", try repeatParams(a, v));
        if (r.enabled) |v| try params.put(a, "enabled", .{ .bool = v });
        return started(tx, id, tag, r.id, try rpc.request(tx, "schedule.update", V{ .object = params }, write));
    }
    // schedule_delete / schedule_run
    const r = try h.decode(Id, a, event);
    if (!ref(r.id)) return receipt(tx, id, "failed", failure("invalid_schedule", "This scheduled task no longer exists."));
    try params.put(a, "id", .{ .string = r.id });
    const rpc_id = if (eq(tag, "schedule_delete"))
        try rpc.request(tx, "schedule.delete", V{ .object = params }, write)
    else
        try rpc.request(tx, "schedule.run", V{ .object = params }, write);
    try started(tx, id, tag, r.id, rpc_id);
}

fn started(tx: *h.Transaction, intent_id: []const u8, tag: []const u8, schedule_id: []const u8, rpc_id: u64) E!void {
    try add(Op, tx.allocator(), &tx.state.schedules.ops, .{ .rpc_id = rpc_id, .intent_id = intent_id, .kind = tag, .schedule_id = schedule_id });
    try syncBusy(tx);
    receipt(tx, intent_id, "pending", null);
}

/// Drains `@schedules` RPC outcomes.
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.schedules;
    const a = tx.allocator();
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        if (result.intent_id == null or !eq(result.intent_id.?, "@schedules")) {
            try add(rpc.Result, a, &tx.state.rpc.results, result);
            continue;
        }
        tx.changed = true;
        if (s.list_id != null and s.list_id.? == result.id) {
            try listed(tx, result);
            continue;
        }
        for (s.ops, 0..) |op, i| if (op.rpc_id == result.id) {
            const rest = try a.alloc(Op, s.ops.len - 1);
            @memcpy(rest[0..i], s.ops[0..i]);
            @memcpy(rest[i..], s.ops[i + 1 ..]);
            s.ops = rest;
            try syncBusy(tx);
            try mutated(tx, op, result);
            break;
        };
    }
}

/// Signing out or forgetting the host drops the list and any work in flight.
pub fn observe(tx: *h.Transaction) void {
    if (tx.state.auth.credential != null) return;
    const s = &tx.state.schedules;
    if (s.view.loaded or s.view.schedules.len > 0 or s.list_id != null or s.ops.len > 0 or s.view.last_run != null) {
        tx.state.schedules = .{};
        tx.changed = true;
    }
}

pub fn query(a: A, state: *const h.State, selector: []const u8) E!?V {
    if (!eq(selector, "schedules")) return null;
    var view = state.schedules.view;
    view.can_edit = view.supported and view.loaded and online(state) and scoped(state, "chat:write");
    return try h.parseLimit(a, try h.encode(a, view), h.MAX_HTTP_INPUT);
}

pub fn scopes(before: *const h.State, after: *const h.State, host_changed: bool) []const []const u8 {
    if (host_changed or !clone.equal(View, before.schedules.view, after.schedules.view)) return &.{"schedules"};
    return &.{};
}

fn requestList(tx: *h.Transaction, intent_id: []const u8) E!void {
    const s = &tx.state.schedules;
    // A superseded read settles: the new one answers it too.
    if (s.list_id != null and s.list_intent.len > 0 and !eq(s.list_intent, intent_id)) receipt(tx, s.list_intent, "succeeded", null);
    s.list_intent = intent_id;
    s.list_again = false;
    s.view.loading = true;
    const filter: V = if (s.view.workspace_id) |w| blk: {
        var params: std.json.ObjectMap = .empty;
        try params.put(tx.allocator(), "workspace_id", .{ .string = w });
        break :blk .{ .object = params };
    } else .{ .object = .empty };
    s.list_id = try rpc.request(tx, "schedule.list", filter, read);
    tx.changed = true;
    receipt(tx, intent_id, "pending", null);
}

/// Re-reads the list after a mutation, unless the phone can't read or is offline.
fn refreshAfterWrite(tx: *h.Transaction) E!void {
    const s = &tx.state.schedules;
    if (!online(&tx.state) or !scoped(&tx.state, "chat:read")) return;
    if (s.list_id != null) {
        s.list_again = true;
        return;
    }
    try requestList(tx, "");
}

fn listed(tx: *h.Transaction, result: rpc.Result) E!void {
    const s = &tx.state.schedules;
    const id = s.list_intent;
    const again = s.list_again;
    s.list_id = null;
    s.list_intent = "";
    s.list_again = false;
    s.view.loading = false;
    if (result.@"error") |e| {
        if (unsupported(e)) s.view.supported = false;
        s.view.@"error" = named(e);
        receipt(tx, id, "failed", s.view.@"error");
    } else {
        const v = result.value orelse .null;
        if (p.get(v, "schedules") != .array) {
            s.view.@"error" = failure("invalid_schedules", "The host returned an unreadable schedule list.");
            receipt(tx, id, "failed", s.view.@"error");
        } else {
            const a = tx.allocator();
            var list: []const Schedule = &.{};
            for (p.rows(p.get(v, "schedules"))) |row| {
                if (list.len >= MAX_SCHEDULES) break;
                const schedule = try parseSchedule(a, row) orelse continue;
                try add(Schedule, a, &list, schedule);
            }
            s.view.schedules = list;
            s.view.now_ms = p.num(p.get(v, "now_ms")) orelse s.view.now_ms;
            s.view.loaded = true;
            s.view.supported = true;
            s.view.@"error" = null;
            receipt(tx, id, "succeeded", null);
        }
    }
    if (again) try refreshAfterWrite(tx);
}

fn mutated(tx: *h.Transaction, op: Op, result: rpc.Result) E!void {
    const s = &tx.state.schedules;
    const a = tx.allocator();
    if (result.@"error") |e| {
        const err = named(e);
        if (unsupported(e)) s.view.supported = false;
        if (eq(err.code, "not_found")) {
            removeRow(tx, op.schedule_id);
            // Deleting something already gone is what the user wanted.
            if (eq(op.kind, "schedule_delete")) receipt(tx, op.intent_id, "succeeded", null) else receipt(tx, op.intent_id, "failed", err);
        } else receipt(tx, op.intent_id, "failed", err);
        return refreshAfterWrite(tx);
    }
    const v = result.value orelse .null;
    if (eq(op.kind, "schedule_delete")) {
        removeRow(tx, op.schedule_id);
    } else if (try parseSchedule(a, p.get(v, "schedule"))) |schedule| {
        try upsertRow(tx, schedule);
        if (eq(op.kind, "schedule_run")) {
            const turn = p.get(v, "turn_id");
            s.view.last_run = .{
                .intent_id = op.intent_id,
                .schedule_id = schedule.id,
                .workspace_id = schedule.target_workspace_id,
                .thread_id = p.s(v, "thread_id"),
                .turn_id = if (turn == .string) turn.string else null,
            };
        }
    }
    receipt(tx, op.intent_id, "succeeded", null);
    try refreshAfterWrite(tx);
}

fn removeRow(tx: *h.Transaction, schedule_id: []const u8) void {
    const s = &tx.state.schedules;
    if (schedule_id.len == 0) return;
    for (s.view.schedules, 0..) |row, i| if (eq(row.id, schedule_id)) {
        const rest = tx.allocator().alloc(Schedule, s.view.schedules.len - 1) catch return;
        @memcpy(rest[0..i], s.view.schedules[0..i]);
        @memcpy(rest[i..], s.view.schedules[i + 1 ..]);
        s.view.schedules = rest;
        tx.changed = true;
        return;
    };
}

/// Shows a confirmed write at once, in the daemon's order (next run first, disabled last).
fn upsertRow(tx: *h.Transaction, schedule: Schedule) E!void {
    const s = &tx.state.schedules;
    const a = tx.allocator();
    const rows = try a.alloc(Schedule, s.view.schedules.len + 1);
    var n: usize = 0;
    for (s.view.schedules) |row| if (!eq(row.id, schedule.id)) {
        rows[n] = row;
        n += 1;
    };
    rows[n] = schedule;
    n += 1;
    std.mem.sort(Schedule, rows[0..n], {}, runsFirst);
    s.view.schedules = rows[0..n];
    tx.changed = true;
}

fn runsFirst(_: void, x: Schedule, y: Schedule) bool {
    if (x.enabled != y.enabled) return x.enabled;
    const xa = x.next_run_ms orelse std.math.maxInt(i64);
    const ya = y.next_run_ms orelse std.math.maxInt(i64);
    if (xa != ya) return xa < ya;
    return std.mem.lessThan(u8, x.id, y.id);
}

fn syncBusy(tx: *h.Transaction) E!void {
    const s = &tx.state.schedules;
    var ids: []const []const u8 = &.{};
    for (s.ops) |op| if (op.schedule_id.len > 0) try add([]const u8, tx.allocator(), &ids, op.schedule_id);
    s.view.busy_ids = ids;
    s.view.saving = s.ops.len > 0;
    tx.changed = true;
}

/// Lenient read of one daemon schedule: unknown fields are ignored and a row
/// without an id is dropped rather than failing the whole list.
pub fn parseSchedule(a: A, v: V) E!?Schedule {
    if (v != .object) return null;
    const id = p.s(v, "id");
    if (id.len == 0) return null;
    const target = p.get(v, "target");
    const repeat = p.get(v, "repeat");
    var weekdays: []const u16 = &.{};
    for (p.rows(p.get(repeat, "weekdays"))) |day| {
        const d = p.num(day) orelse continue;
        if (d < 0 or d > 6 or weekdays.len >= 7) continue;
        try add(u16, a, &weekdays, @intCast(d));
    }
    const every = p.num(p.get(repeat, "every_minutes"));
    const target_kind = p.s(target, "kind");
    const repeat_kind = p.s(repeat, "kind");
    return .{
        .id = id,
        .name = p.s(v, "name"),
        .prompt = p.s(v, "prompt"),
        .target_kind = if (target_kind.len > 0) target_kind else "thread",
        .target_workspace_id = p.s(target, "workspace_id"),
        .target_thread_id = p.s(target, "thread_id"),
        .target_provider = p.s(target, "provider"),
        .target_model = p.s(target, "model"),
        .repeat_kind = if (repeat_kind.len > 0) repeat_kind else "once",
        .repeat_at_ms = p.num(p.get(repeat, "at_ms")),
        .repeat_every_minutes = if (every) |m| std.math.cast(u32, m) else null,
        .repeat_time = p.s(repeat, "time"),
        .repeat_weekdays = weekdays,
        .enabled = p.get(v, "enabled") != .bool or p.yes(p.get(v, "enabled")),
        .parent_workspace_id = p.s(v, "parent_workspace_id"),
        .parent_thread_id = p.s(v, "parent_thread_id"),
        .created_by = p.s(v, "created_by"),
        .next_run_ms = p.num(p.get(v, "next_run_ms")),
        .last_run_ms = p.num(p.get(v, "last_run_ms")),
        .last_status = optional(p.get(v, "last_status")),
        .last_error = optional(p.get(v, "last_error")),
        .last_thread_id = p.s(v, "last_thread_id"),
        .run_count = if (p.uint(p.get(v, "run_count"))) |c| std.math.cast(u32, c) orelse std.math.maxInt(u32) else 0,
        .created_at_ms = p.num(p.get(v, "created_at_ms")) orelse 0,
        .updated_at_ms = p.num(p.get(v, "updated_at_ms")) orelse 0,
    };
}

fn optional(v: V) ?[]const u8 {
    return if (v == .string) v.string else null;
}

fn targetParams(a: A, t: Target) E!V {
    var out: std.json.ObjectMap = .empty;
    try out.put(a, "kind", .{ .string = t.kind });
    try out.put(a, "workspace_id", .{ .string = t.workspace_id });
    if (eq(t.kind, "thread")) {
        try out.put(a, "thread_id", .{ .string = t.thread_id.? });
    } else {
        try out.put(a, "provider", .{ .string = t.provider.? });
        if (t.model) |m| if (m.len > 0) try out.put(a, "model", .{ .string = m });
    }
    return .{ .object = out };
}

fn repeatParams(a: A, r: Repeat) E!V {
    var out: std.json.ObjectMap = .empty;
    try out.put(a, "kind", .{ .string = r.kind });
    if (eq(r.kind, "once")) {
        try out.put(a, "at_ms", .{ .integer = r.at_ms.? });
    } else if (eq(r.kind, "interval")) {
        try out.put(a, "every_minutes", .{ .integer = r.every_minutes.? });
    } else {
        try out.put(a, "time", .{ .string = r.time.? });
        const list = r.weekdays orelse &.{};
        var days = try std.json.Array.initCapacity(a, list.len);
        for (list) |d| days.appendAssumeCapacity(.{ .integer = d });
        try out.put(a, "weekdays", .{ .array = days });
    }
    return .{ .object = out };
}

fn invalidName(name: []const u8) ?h.LocalError {
    if (blank(name) or name.len > MAX_NAME_BYTES) return failure("invalid_name", "Use a name between 1 and 120 bytes.");
    return null;
}

fn invalidPrompt(prompt: []const u8) ?h.LocalError {
    if (blank(prompt)) return failure("invalid_prompt", "Write what the task should do.");
    if (prompt.len > MAX_PROMPT_BYTES) return failure("invalid_prompt", "Keep the prompt under 16 KiB.");
    return null;
}

fn invalidTarget(t: Target) ?h.LocalError {
    if (!ref(t.workspace_id)) return failure("invalid_target", "Choose a workspace.");
    if (eq(t.kind, "thread")) {
        const thread = t.thread_id orelse "";
        if (!ref(thread)) return failure("invalid_target", "Choose a chat.");
        return null;
    }
    if (!eq(t.kind, "new_chat")) return failure("invalid_target", "Choose an existing chat or a new chat.");
    const provider = t.provider orelse "";
    if (!ref(provider) or provider.len > 64) return failure("invalid_provider", "Choose a provider for the new chat.");
    if (t.model) |m| if (m.len > MAX_REF_BYTES) return failure("invalid_model", "That model name is too long.");
    return null;
}

fn invalidRepeat(r: Repeat) ?h.LocalError {
    if (eq(r.kind, "once")) {
        const at = r.at_ms orelse 0;
        if (at <= 0) return failure("invalid_repeat", "Choose when it should run.");
        return null;
    }
    if (eq(r.kind, "interval")) {
        const every = r.every_minutes orelse 0;
        if (every < MIN_EVERY_MINUTES or every > MAX_EVERY_MINUTES) return failure("invalid_repeat", "Repeat every 5 minutes to 7 days.");
        return null;
    }
    if (!eq(r.kind, "daily")) return failure("invalid_repeat", "Choose once, every few minutes or hours, or daily.");
    if (!validTime(r.time orelse "")) return failure("invalid_repeat", "Use a time like 09:00.");
    const days = r.weekdays orelse &.{};
    if (days.len > 7) return failure("invalid_repeat", "Choose up to 7 weekdays.");
    for (days) |d| if (d > 6) return failure("invalid_repeat", "Weekdays run from 0 (Sunday) to 6 (Saturday).");
    return null;
}

/// 24-hour "HH:MM".
pub fn validTime(time: []const u8) bool {
    if (time.len != 5 or time[2] != ':') return false;
    for ([_]usize{ 0, 1, 3, 4 }) |i| if (!std.ascii.isDigit(time[i])) return false;
    const hours = (time[0] - '0') * 10 + (time[1] - '0');
    const minutes = (time[3] - '0') * 10 + (time[4] - '0');
    return hours <= 23 and minutes <= 59;
}

fn blank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

fn sameFilter(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return eq(x.?, y.?);
}

fn ref(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_REF_BYTES) return false;
    for (id) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn unsupported(e: h.LocalError) bool {
    const code = e.rpc_code orelse e.code;
    return eq(code, "method_not_found") or eq(code, "unknown_method") or eq(code, "scope_denied");
}

/// Daemon codes the platform acts on become the local code; messages never
/// carry host text.
fn named(e: h.LocalError) h.LocalError {
    const code = e.rpc_code orelse e.code;
    var out: h.LocalError = .{ .domain = "schedules", .code = code, .message = "The host couldn't update scheduled tasks.", .retryable = e.retryable, .delivery = e.delivery, .rpc_code = e.rpc_code };
    if (eq(code, "not_found")) {
        out.message = "This scheduled task no longer exists.";
    } else if (unsupported(e)) {
        out.message = "Update verde on the computer to use scheduled tasks.";
    } else if (eq(code, "invalid_params")) {
        out.message = "The host rejected this scheduled task.";
    } else if (eq(code, "cancelled") or eq(code, "offline") or eq(e.domain, "transport")) {
        out.message = "Connect to the host to refresh scheduled tasks.";
    }
    return out;
}

fn failure(code: []const u8, message: []const u8) h.LocalError {
    return .{ .domain = "schedules", .code = code, .message = message };
}

fn receipt(tx: *h.Transaction, id: []const u8, state: []const u8, err: ?h.LocalError) void {
    if (id.len == 0) return;
    for (@constCast(tx.state.receipts)) |*r| if (eq(r.operation.intent_id, id)) {
        r.operation.state = state;
        r.operation.@"error" = err;
    };
    tx.changed = true;
}

fn scoped(s: *const h.State, name: []const u8) bool {
    const credential = s.auth.credential orelse return false;
    for (credential.scopes) |scope| if (eq(scope, name)) return true;
    return false;
}

fn online(s: *const h.State) bool {
    return s.lifecycle == .foreground and s.network_available and s.rpc.phase == .ready and s.rpc.bearer != null;
}
