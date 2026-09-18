//! GUI projection of daemon-linked child chats (MCP-delegated conversations)
//! grouped under their parent conversation. Rows are fetched asynchronously
//! through the lightweight daemon client; this module never touches the
//! daemon store, providers, or the render thread's blocking budget.

const Self = @This();

const std = @import("std");
const loop_wakeup = @import("loop_wakeup");
const daemon_client = @import("../daemon/client.zig");

const log = std.log.scoped(.linked_chats);

pub const METHOD_LINKS_LIST = "chat.links.list";
pub const METHOD_LINKS_CLEAR = "chat.links.clear";

/// Refetch cadence while any child is still working or blocked on input.
const ACTIVE_REFRESH_MS: i64 = 2_500;
/// Cadence once every listed child is settled.
const SETTLED_REFRESH_MS: i64 = 6_000;
/// Cadence for parents whose last list came back empty (most chats).
const EMPTY_REFRESH_MS: i64 = 20_000;
/// Parents not drawn for this long are forgotten so hidden panes stop polling.
const FORGET_AFTER_MS: i64 = 30_000;

pub const Status = enum {
    idle,
    running,
    waiting_approval,
    blocked,
    completed,
    failed,
    aborted,
    interrupted,
    unknown,

    pub fn fromWire(text: []const u8) Status {
        return std.meta.stringToEnum(Status, text) orelse .unknown;
    }

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .idle => "Idle",
            .running => "Running",
            .waiting_approval => "Needs approval",
            .blocked => "Blocked",
            .completed => "Done",
            .failed => "Failed",
            .aborted => "Stopped",
            .interrupted => "Interrupted",
            .unknown => "Unknown",
        };
    }

    /// True once the daemon reports the latest turn as no longer in flight.
    pub fn isFinished(self: Status) bool {
        return switch (self) {
            .completed, .failed, .aborted, .interrupted => true,
            .idle, .running, .waiting_approval, .blocked, .unknown => false,
        };
    }

    pub fn isActive(self: Status) bool {
        return self == .running or self == .waiting_approval or self == .blocked;
    }

    /// Sort rank: what the user must act on first floats to the top.
    fn rank(self: Status) u8 {
        return switch (self) {
            .waiting_approval, .blocked => 0,
            .running => 1,
            .failed, .aborted, .interrupted => 2,
            .completed => 3,
            .idle, .unknown => 4,
        };
    }
};

pub const Entry = struct {
    is_parent: bool = false,
    link_id: []u8,
    local_thread_id: []u8,
    title: []u8,
    provider: []u8,
    status: Status,
    /// Verbatim daemon status for statuses this build does not know.
    status_raw: []u8,
    summary: []u8,
    updated_at_ms: i64,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.link_id);
        allocator.free(self.local_thread_id);
        allocator.free(self.title);
        allocator.free(self.provider);
        allocator.free(self.status_raw);
        allocator.free(self.summary);
    }

    pub fn statusLabel(self: *const Entry) []const u8 {
        if (self.status == .unknown and self.status_raw.len > 0) return self.status_raw;
        return self.status.label();
    }
};

/// Wire shapes owned by the GUI; the daemon may add fields without breaking
/// decoding because unknown fields are ignored and optionals default.
const ListParams = struct {
    workspace_id: []const u8,
    parent_thread_id: []const u8,
};

const ClearOneParams = struct {
    workspace_id: []const u8,
    parent_thread_id: []const u8,
    link_id: []const u8,
};

const ClearCompletedParams = struct {
    workspace_id: []const u8,
    parent_thread_id: []const u8,
    completed_only: bool = true,
};

const WireLink = struct {
    link_id: []const u8,
    local_thread_id: []const u8,
    title: []const u8 = "",
    provider: []const u8 = "",
    status: []const u8 = "idle",
    summary: []const u8 = "",
    turn_id: ?[]const u8 = null,
    updated_at_ms: i64 = 0,
    hidden: bool = false,
};

const ListResult = struct {
    links: []const WireLink = &.{},
    parents: []const WireLink = &.{},
};

const JobKind = enum { list, clear_one, clear_completed };

/// One daemon round trip on a worker thread. Inputs and the raw result are
/// page-allocated so the job never depends on the app allocator's lifetime.
const Job = struct {
    kind: JobKind,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: ?std.Thread = null,
    pref_path: []u8,
    workspace_id: []u8,
    parent_thread_id: []u8,
    link_id: []u8,
    result_json: ?[]u8 = null,
    failed: bool = false,

    fn destroy(self: *Job) void {
        const page = std.heap.page_allocator;
        page.free(self.pref_path);
        page.free(self.workspace_id);
        page.free(self.parent_thread_id);
        page.free(self.link_id);
        if (self.result_json) |json| page.free(json);
        page.destroy(self);
    }
};

pub const Parent = struct {
    workspace_id: []u8,
    parent_thread_id: []u8,
    entries: std.ArrayList(Entry) = .empty,
    /// User preference for this parent; survives projection rebuilds because
    /// it is keyed by thread identity rather than stored on the ChatThread.
    collapsed: bool = true,
    narrow_expanded: bool = false,
    narrow: bool = false,
    scroll_y: f32 = 0.0,
    last_wanted_ms: i64 = 0,
    last_fetch_started_ms: i64 = 0,
    fetched_once: bool = false,
    refetch_requested: bool = false,
    list_job: ?*Job = null,

    fn deinit(self: *Parent, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        allocator.free(self.workspace_id);
        allocator.free(self.parent_thread_id);
    }

    pub fn hasActive(self: *const Parent) bool {
        for (self.entries.items) |entry| {
            if (entry.status.isActive()) return true;
        }
        return false;
    }

    pub fn hasFinished(self: *const Parent) bool {
        for (self.entries.items) |entry| {
            if (!entry.is_parent and entry.status.isFinished()) return true;
        }
        return false;
    }

    pub fn parentCount(self: *const Parent) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.is_parent) count += 1;
        }
        return count;
    }

    fn refreshIntervalMs(self: *const Parent) i64 {
        if (self.entries.items.len == 0) return EMPTY_REFRESH_MS;
        return if (self.hasActive()) ACTIVE_REFRESH_MS else SETTLED_REFRESH_MS;
    }
};

parents: std.ArrayList(Parent) = .empty,
clear_jobs: std.ArrayList(*Job) = .empty,
last_age_refresh_ms: i64 = 0,

pub fn init() Self {
    return .{};
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.parents.items) |*parent| {
        if (parent.list_job) |job| {
            finishJob(job);
            job.destroy();
        }
        parent.deinit(allocator);
    }
    self.parents.deinit(allocator);
    for (self.clear_jobs.items) |job| {
        finishJob(job);
        job.destroy();
    }
    self.clear_jobs.deinit(allocator);
}

pub fn find(self: *Self, workspace_id: []const u8, parent_thread_id: []const u8) ?*Parent {
    for (self.parents.items) |*parent| {
        if (std.mem.eql(u8, parent.workspace_id, workspace_id) and
            std.mem.eql(u8, parent.parent_thread_id, parent_thread_id)) return parent;
    }
    return null;
}

/// Called by the renderer for every visible parent pane. Registers the parent
/// for polling; the first list arrives on a later frame.
pub fn markWanted(
    self: *Self,
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    parent_thread_id: []const u8,
    now_ms: i64,
) ?*Parent {
    if (self.find(workspace_id, parent_thread_id)) |parent| {
        parent.last_wanted_ms = now_ms;
        return parent;
    }
    const owned_workspace = allocator.dupe(u8, workspace_id) catch return null;
    const owned_parent = allocator.dupe(u8, parent_thread_id) catch {
        allocator.free(owned_workspace);
        return null;
    };
    self.parents.append(allocator, .{
        .workspace_id = owned_workspace,
        .parent_thread_id = owned_parent,
        .last_wanted_ms = now_ms,
    }) catch {
        allocator.free(owned_parent);
        allocator.free(owned_workspace);
        return null;
    };
    return &self.parents.items[self.parents.items.len - 1];
}

/// Main-thread tick: consumes finished workers, forgets idle parents, and
/// starts due fetches. Returns true when the UI should render.
pub fn poll(self: *Self, allocator: std.mem.Allocator, pref_path: []const u8, now_ms: i64) bool {
    var changed = false;
    // Relative ages must advance even when the daemon returns unchanged rows.
    if (@divFloor(now_ms, 60_000) != @divFloor(self.last_age_refresh_ms, 60_000)) {
        self.last_age_refresh_ms = now_ms;
        for (self.parents.items) |parent| {
            if (parent.entries.items.len > 0 and now_ms - parent.last_wanted_ms <= FORGET_AFTER_MS) {
                changed = true;
                break;
            }
        }
    }

    var clear_index: usize = 0;
    while (clear_index < self.clear_jobs.items.len) {
        const job = self.clear_jobs.items[clear_index];
        if (!job.done.load(.acquire)) {
            clear_index += 1;
            continue;
        }
        finishJob(job);
        if (job.failed) {
            log.warn("chat.links.clear failed for parent {s}", .{job.parent_thread_id});
        }
        // Reconcile against the daemon either way: a failed clear must bring
        // the optimistically hidden row back.
        if (self.find(job.workspace_id, job.parent_thread_id)) |parent| parent.refetch_requested = true;
        job.destroy();
        _ = self.clear_jobs.swapRemove(clear_index);
    }

    var index: usize = 0;
    while (index < self.parents.items.len) {
        const parent = &self.parents.items[index];
        if (parent.list_job) |job| {
            if (job.done.load(.acquire)) {
                finishJob(job);
                parent.list_job = null;
                if (job.failed) {
                    log.warn("chat.links.list failed for parent {s}", .{parent.parent_thread_id});
                } else if (job.result_json) |json| {
                    changed = applyListResult(allocator, parent, json) or changed;
                }
                parent.fetched_once = true;
                job.destroy();
            }
        }
        const idle = parent.list_job == null;
        if (idle and now_ms - parent.last_wanted_ms > FORGET_AFTER_MS) {
            var removed = self.parents.swapRemove(index);
            changed = changed or removed.entries.items.len > 0;
            removed.deinit(allocator);
            continue;
        }
        if (idle) {
            const due = parent.refetch_requested or
                !parent.fetched_once or
                now_ms - parent.last_fetch_started_ms >= parent.refreshIntervalMs();
            if (due and now_ms - parent.last_wanted_ms <= FORGET_AFTER_MS) {
                parent.refetch_requested = false;
                parent.last_fetch_started_ms = now_ms;
                parent.list_job = spawnJob(.list, pref_path, parent.workspace_id, parent.parent_thread_id, "");
            }
        }
        index += 1;
    }
    return changed;
}

/// Hides one link (or every finished link when `link_id` is null). The row
/// disappears immediately; the daemon clear runs in the background and the
/// next list reconciles. Clearing never cancels or deletes the child chat.
pub fn requestClear(
    self: *Self,
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    workspace_id: []const u8,
    parent_thread_id: []const u8,
    link_id: ?[]const u8,
) void {
    const parent = self.find(workspace_id, parent_thread_id) orelse return;
    var i: usize = 0;
    while (i < parent.entries.items.len) {
        const entry = parent.entries.items[i];
        const remove = if (link_id) |id| std.mem.eql(u8, entry.link_id, id) else entry.status.isFinished();
        if (!entry.is_parent and remove) {
            entry.deinit(allocator);
            _ = parent.entries.orderedRemove(i);
        } else i += 1;
    }
    const job = spawnJob(
        if (link_id != null) .clear_one else .clear_completed,
        pref_path,
        workspace_id,
        parent_thread_id,
        link_id orelse "",
    ) orelse return;
    self.clear_jobs.append(allocator, job) catch {
        finishJob(job);
        job.destroy();
    };
}

fn applyListResult(allocator: std.mem.Allocator, parent: *Parent, json: []const u8) bool {
    var parsed = std.json.parseFromSlice(ListResult, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("chat.links.list decode failed: {s}", .{@errorName(err)});
        return false;
    };
    defer parsed.deinit();

    var fresh: std.ArrayList(Entry) = .empty;
    defer {
        for (fresh.items) |entry| entry.deinit(allocator);
        fresh.deinit(allocator);
    }
    for (parsed.value.links) |link| {
        if (link.hidden) continue;
        const entry = dupeEntry(allocator, link) catch return false;
        fresh.append(allocator, entry) catch {
            entry.deinit(allocator);
            return false;
        };
    }
    for (parsed.value.parents) |link| {
        var entry = dupeEntry(allocator, link) catch return false;
        entry.is_parent = true;
        fresh.append(allocator, entry) catch {
            entry.deinit(allocator);
            return false;
        };
    }
    std.mem.sort(Entry, fresh.items, {}, entryLessThan);

    const same = entriesEqual(parent.entries.items, fresh.items);
    if (same) return false;
    for (parent.entries.items) |entry| entry.deinit(allocator);
    parent.entries.deinit(allocator);
    parent.entries = fresh;
    fresh = .empty;
    return true;
}

fn dupeEntry(allocator: std.mem.Allocator, link: WireLink) !Entry {
    const link_id = try allocator.dupe(u8, link.link_id);
    errdefer allocator.free(link_id);
    const local_thread_id = try allocator.dupe(u8, link.local_thread_id);
    errdefer allocator.free(local_thread_id);
    const title = try allocator.dupe(u8, if (link.title.len > 0) link.title else "Untitled chat");
    errdefer allocator.free(title);
    const provider = try allocator.dupe(u8, link.provider);
    errdefer allocator.free(provider);
    const status_raw = try allocator.dupe(u8, link.status);
    errdefer allocator.free(status_raw);
    const summary = try allocator.dupe(u8, firstLine(link.summary));
    errdefer allocator.free(summary);
    return .{
        .link_id = link_id,
        .local_thread_id = local_thread_id,
        .title = title,
        .provider = provider,
        .status = Status.fromWire(link.status),
        .status_raw = status_raw,
        .summary = summary,
        .updated_at_ms = link.updated_at_ms,
    };
}

/// Summaries can be long multi-line results; the drawer shows one line.
fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    return trimmed[0..end];
}

fn entryLessThan(_: void, left: Entry, right: Entry) bool {
    if (left.is_parent != right.is_parent) return left.is_parent;
    const left_rank = left.status.rank();
    const right_rank = right.status.rank();
    if (left_rank != right_rank) return left_rank < right_rank;
    if (left.updated_at_ms != right.updated_at_ms) return left.updated_at_ms > right.updated_at_ms;
    return std.mem.lessThan(u8, left.link_id, right.link_id);
}

fn entriesEqual(left: []const Entry, right: []const Entry) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.is_parent != b.is_parent or a.status != b.status or a.updated_at_ms != b.updated_at_ms) return false;
        if (!std.mem.eql(u8, a.link_id, b.link_id)) return false;
        if (!std.mem.eql(u8, a.local_thread_id, b.local_thread_id)) return false;
        if (!std.mem.eql(u8, a.title, b.title)) return false;
        if (!std.mem.eql(u8, a.provider, b.provider)) return false;
        if (!std.mem.eql(u8, a.status_raw, b.status_raw)) return false;
        if (!std.mem.eql(u8, a.summary, b.summary)) return false;
    }
    return true;
}

fn spawnJob(
    kind: JobKind,
    pref_path: []const u8,
    workspace_id: []const u8,
    parent_thread_id: []const u8,
    link_id: []const u8,
) ?*Job {
    const page = std.heap.page_allocator;
    const job = page.create(Job) catch return null;
    job.* = .{
        .kind = kind,
        .pref_path = page.dupe(u8, pref_path) catch {
            page.destroy(job);
            return null;
        },
        .workspace_id = page.dupe(u8, workspace_id) catch {
            page.free(job.pref_path);
            page.destroy(job);
            return null;
        },
        .parent_thread_id = page.dupe(u8, parent_thread_id) catch {
            page.free(job.workspace_id);
            page.free(job.pref_path);
            page.destroy(job);
            return null;
        },
        .link_id = page.dupe(u8, link_id) catch {
            page.free(job.parent_thread_id);
            page.free(job.workspace_id);
            page.free(job.pref_path);
            page.destroy(job);
            return null;
        },
    };
    job.worker = std.Thread.spawn(.{}, jobWorkerMain, .{job}) catch |err| {
        log.warn("failed to spawn linked-chats worker: {s}", .{@errorName(err)});
        job.destroy();
        return null;
    };
    return job;
}

/// Joins a job whose `done` flag is set (or blocks until it is during teardown).
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
    var parsed = (switch (job.kind) {
        .list => client.call(METHOD_LINKS_LIST, ListParams{
            .workspace_id = job.workspace_id,
            .parent_thread_id = job.parent_thread_id,
        }),
        .clear_one => client.call(METHOD_LINKS_CLEAR, ClearOneParams{
            .workspace_id = job.workspace_id,
            .parent_thread_id = job.parent_thread_id,
            .link_id = job.link_id,
        }),
        .clear_completed => client.call(METHOD_LINKS_CLEAR, ClearCompletedParams{
            .workspace_id = job.workspace_id,
            .parent_thread_id = job.parent_thread_id,
        }),
    }) catch |err| {
        log.debug("linked-chats request failed: {s}", .{@errorName(err)});
        job.failed = true;
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err != null) {
        job.failed = true;
        return;
    }
    if (job.kind != .list) return;
    const result = parsed.response.result orelse {
        job.failed = true;
        return;
    };
    job.result_json = std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{}) catch {
        job.failed = true;
        return;
    };
}

test "linked chat list results decode, filter hidden rows, and sort by urgency" {
    const allocator = std.testing.allocator;
    var parent: Parent = .{
        .workspace_id = try allocator.dupe(u8, "ws"),
        .parent_thread_id = try allocator.dupe(u8, "chat-parent"),
    };
    defer parent.deinit(allocator);
    const json =
        \\{"links":[
        \\ {"link_id":"a","local_thread_id":"chat-a","title":"Done one","provider":"codex","status":"completed","summary":"ok\nmore","updated_at_ms":10,"hidden":false,"extra":1},
        \\ {"link_id":"b","local_thread_id":"chat-b","title":"Blocked","provider":"claude","status":"waiting_approval","summary":"needs approval","updated_at_ms":5},
        \\ {"link_id":"c","local_thread_id":"chat-c","title":"Gone","provider":"claude","status":"completed","updated_at_ms":9,"hidden":true},
        \\ {"link_id":"d","local_thread_id":"chat-d","status":"future_state","updated_at_ms":1}
        \\]}
    ;
    try std.testing.expect(applyListResult(allocator, &parent, json));
    try std.testing.expectEqual(@as(usize, 3), parent.entries.items.len);
    try std.testing.expectEqualStrings("b", parent.entries.items[0].link_id);
    try std.testing.expectEqualStrings("a", parent.entries.items[1].link_id);
    try std.testing.expectEqualStrings("ok", parent.entries.items[1].summary);
    try std.testing.expectEqualStrings("Untitled chat", parent.entries.items[2].title);
    try std.testing.expectEqualStrings("future_state", parent.entries.items[2].statusLabel());
    try std.testing.expect(parent.hasActive());
    try std.testing.expect(parent.hasFinished());
    // Identical payloads do not report a change.
    try std.testing.expect(!applyListResult(allocator, &parent, json));
}
