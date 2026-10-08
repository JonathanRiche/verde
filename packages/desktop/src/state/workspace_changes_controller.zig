//! Side panel "Changes" view state: every uncommitted file across the
//! selected workspace's repositories (daemon `git.changes.workspace`) and
//! per-file patches fetched on demand (`git.changes.file_patch`).
//!
//! Read-only. Daemon calls run on short-lived worker threads and are drained
//! on the UI thread by `pollWorkspaceChanges` (called from `pollGitChanges`).
//! The list refreshes when the view becomes visible, after chat activity
//! while it is visible (debounced and coalesced), and on the manual refresh
//! button. There is no polling loop.

const std = @import("std");

const loop_wakeup = @import("loop_wakeup");
const platform_runtime = @import("platform_runtime");
const daemon_client = @import("../daemon/client.zig");
const headless = @import("headless");
const side_panel_controller = @import("side_panel_controller.zig");

const proto = headless.git_changes_protocol;
const Mutex = std.atomic.Mutex;
const page = std.heap.page_allocator;

pub const WorkspaceResult = proto.WorkspaceResult;
pub const WorkspaceRepo = proto.WorkspaceRepo;
pub const WorkspaceFile = proto.WorkspaceFile;
pub const FilePatchResult = proto.FilePatchResult;

/// Chat activity arrives in bursts (`chat.turn` entries around a turn); one
/// list call follows it.
pub const ACTIVITY_REFRESH_DELAY_MS: u64 = 1000;
const LIST_TIMEOUT_MS: u32 = 30_000;
const PATCH_TIMEOUT_MS: u32 = 20_000;
/// Patches kept; least recently drawn ones are dropped first.
pub const MAX_PATCHES: usize = 48;
/// Context lines a normal (collapsed) diff shows; git's default.
pub const BASE_CONTEXT_LINES: usize = 3;
/// Lines each "expand" click reveals around changes.
pub const EXPAND_STEP_LINES: usize = 20;
pub const MAX_EXPAND_LEVEL: u8 = 200;
/// `context_lines` for an expanded file's patch: the whole file.
const FULL_CONTEXT: u32 = 1_000_000;

// ------------------------------------------------------------------
// Pure helpers (unit tested)
// ------------------------------------------------------------------

pub const FilterKind = enum { all, unassigned, thread };

pub const Filter = struct {
    kind: FilterKind = .all,
    /// Chat id for `.thread`.
    thread_id: []const u8 = "",

    pub fn matches(self: Filter, file: WorkspaceFile) bool {
        return switch (self.kind) {
            .all => true,
            .unassigned => file.owners.len == 0,
            .thread => for (file.owners) |owner| {
                if (std.mem.eql(u8, owner.local_thread_id, self.thread_id)) break true;
            } else false,
        };
    }
};

/// One filter chip: All, a chat that claimed files, or Unassigned.
pub const Chip = struct {
    kind: FilterKind,
    thread_id: []const u8 = "",
    title: []const u8 = "",
    files: usize = 0,
};

/// Chips for a listing: All, then chats in first-claim order, then
/// Unassigned (only when some file has no owner). Strings borrow `result`.
pub fn collectChips(allocator: std.mem.Allocator, result: WorkspaceResult) ![]Chip {
    var chips: std.ArrayList(Chip) = .empty;
    errdefer chips.deinit(allocator);
    try chips.append(allocator, .{ .kind = .all });
    var unassigned: usize = 0;
    for (result.repos) |repo| {
        for (repo.files) |file| {
            chips.items[0].files += 1;
            if (file.owners.len == 0) unassigned += 1;
            for (file.owners) |owner| {
                const existing = for (chips.items[1..]) |*chip| {
                    if (std.mem.eql(u8, chip.thread_id, owner.local_thread_id)) break chip;
                } else null;
                if (existing) |chip| {
                    chip.files += 1;
                } else {
                    try chips.append(allocator, .{
                        .kind = .thread,
                        .thread_id = owner.local_thread_id,
                        .title = if (owner.title.len > 0) owner.title else "Chat",
                        .files = 1,
                    });
                }
            }
        }
    }
    if (unassigned > 0) try chips.append(allocator, .{ .kind = .unassigned, .title = "Unassigned", .files = unassigned });
    return chips.toOwnedSlice(allocator);
}

pub const Totals = struct {
    files: usize = 0,
    additions: u64 = 0,
    deletions: u64 = 0,
    repos_with_files: usize = 0,
};

pub fn totals(result: WorkspaceResult, filter: Filter) Totals {
    var out: Totals = .{};
    for (result.repos) |repo| {
        var any = false;
        for (repo.files) |file| {
            if (!filter.matches(file)) continue;
            any = true;
            out.files += 1;
            out.additions += file.additions;
            out.deletions += file.deletions;
        }
        if (any) out.repos_with_files += 1;
    }
    return out;
}

/// zig_dif context collapse for an expand level (0 = git's own hunks).
pub fn viewContextLines(level: u8) usize {
    if (level == 0) return BASE_CONTEXT_LINES;
    if (level >= MAX_EXPAND_LEVEL) return FULL_CONTEXT;
    return BASE_CONTEXT_LINES + EXPAND_STEP_LINES * @as(usize, level);
}

/// One status letter for a file row.
pub fn statusLetter(file: WorkspaceFile) []const u8 {
    if (file.untracked) return "U";
    if (std.mem.eql(u8, file.status, "added")) return "A";
    if (std.mem.eql(u8, file.status, "deleted")) return "D";
    return "M";
}

/// Short owner label for a file row: the chat title, "N chats", or "".
pub fn ownerLabel(buf: []u8, file: WorkspaceFile) []const u8 {
    return switch (file.owners.len) {
        0 => "",
        1 => file.owners[0].title,
        else => std.fmt.bufPrint(buf, "{d} chats", .{file.owners.len}) catch "",
    };
}

// ------------------------------------------------------------------
// Worker plumbing
// ------------------------------------------------------------------

const Job = enum { list, patch };

const Status = enum { idle, pending, completed };

const Request = struct {
    job: Job,
    pref_path: []u8,
    params_json: []u8,
    timeout_ms: u32,
    delay_ms: u64 = 0,
    generation: u64,
    /// Workspace id (list) or `root\x00path` (patch).
    tag: []u8,
    /// Patch requested with the whole file as context.
    full: bool = false,

    fn deinit(self: *Request) void {
        page.free(self.pref_path);
        page.free(self.params_json);
        page.free(self.tag);
        page.destroy(self);
    }
};

const Payload = union(enum) {
    none,
    list: std.json.Parsed(WorkspaceResult),
    patch: std.json.Parsed(FilePatchResult),

    fn deinit(self: *Payload) void {
        switch (self.*) {
            .none => {},
            inline else => |*parsed| parsed.deinit(),
        }
        self.* = .none;
    }
};

const Result = struct {
    err_code: ?[]u8 = null,
    err_message: ?[]u8 = null,
    payload: Payload = .none,

    fn deinit(self: *Result) void {
        if (self.err_code) |value| page.free(value);
        if (self.err_message) |value| page.free(value);
        self.payload.deinit();
    }
};

const Lane = struct {
    mutex: Mutex = .unlocked,
    status: Status = .idle,
    worker: ?std.Thread = null,
    request: ?*Request = null,
    result: ?Result = null,

    fn lock(self: *Lane) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn busy(self: *Lane) bool {
        self.lock();
        defer self.mutex.unlock();
        return self.status != .idle;
    }

    fn join(self: *Lane) void {
        if (self.worker) |thread| thread.join();
        self.worker = null;
        if (self.request) |request| request.deinit();
        self.request = null;
        if (self.result) |*result| result.deinit();
        self.result = null;
        self.status = .idle;
    }

    fn takeCompleted(self: *Lane) ?struct { request: *Request, result: Result } {
        self.lock();
        if (self.status != .completed) {
            self.mutex.unlock();
            return null;
        }
        const thread = self.worker.?;
        const request = self.request.?;
        const result = self.result.?;
        self.worker = null;
        self.request = null;
        self.result = null;
        self.status = .idle;
        self.mutex.unlock();
        thread.join();
        return .{ .request = request, .result = result };
    }
};

fn worker(lane: *Lane, request: *Request) void {
    if (request.delay_ms > 0) platform_runtime.sleepMillis(request.delay_ms);
    var result: Result = .{};
    runJob(request, &result);
    lane.lock();
    lane.result = result;
    lane.status = .completed;
    lane.mutex.unlock();
    loop_wakeup.notify();
}

fn setError(result: *Result, code: ?[]const u8, message: []const u8) void {
    result.err_code = if (code) |value| page.dupe(u8, value) catch null else null;
    result.err_message = page.dupe(u8, message) catch null;
}

fn parseTyped(comptime T: type, value: std.json.Value) ?std.json.Parsed(T) {
    return std.json.parseFromValue(T, page, value, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

fn runJob(request: *Request, result: *Result) void {
    var params = std.json.parseFromSlice(std.json.Value, page, request.params_json, .{}) catch {
        setError(result, null, "Could not encode the request.");
        return;
    };
    defer params.deinit();
    var transport: daemon_client.HeadlessTransport = .{
        .allocator = page,
        .pref_path = request.pref_path,
        .timeout_ms = request.timeout_ms,
    };
    var client = daemon_client.headlessClient(page, &transport);
    const method = switch (request.job) {
        .list => proto.METHOD_WORKSPACE,
        .patch => proto.METHOD_FILE_PATCH,
    };
    var parsed = client.call(method, params.value) catch {
        setError(result, null, "Could not reach the Verde daemon, or it took too long to answer.");
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        setError(result, err.code, err.message);
        return;
    }
    const value = parsed.response.result orelse {
        setError(result, null, "The daemon returned an empty response.");
        return;
    };
    result.payload = switch (request.job) {
        .list => if (parseTyped(WorkspaceResult, value)) |typed| .{ .list = typed } else .none,
        .patch => if (parseTyped(FilePatchResult, value)) |typed| .{ .patch = typed } else .none,
    };
    if (result.payload == .none) setError(result, null, "The daemon returned an unexpected response.");
}

fn isUnknownMethod(code: ?[]const u8) bool {
    const value = code orelse return false;
    return std.mem.eql(u8, value, "method_not_found") or std.mem.eql(u8, value, "unknown_method") or std.mem.eql(u8, value, "unsupported");
}

// ------------------------------------------------------------------
// State
// ------------------------------------------------------------------

/// An expanded file row and how far its context is expanded.
pub const Expanded = struct {
    root: []u8,
    path: []u8,
    level: u8 = 0,
    /// The whole-file patch came back truncated; stay on git's hunks.
    full_unavailable: bool = false,

    fn deinit(self: *Expanded) void {
        page.free(self.root);
        page.free(self.path);
    }
};

pub const PatchEntry = struct {
    root: []u8,
    path: []u8,
    full: bool,
    parsed: ?std.json.Parsed(FilePatchResult) = null,
    /// The listing changed since this text was fetched; refetch, but keep
    /// drawing the old text until the new one arrives.
    stale: bool = false,
    in_flight: bool = false,
    err_message: ?[]u8 = null,
    used_tick: u64 = 0,
    /// Display rows per layout (stacked, split) for `counts_context`,
    /// memoized by the view so long lists do not reparse every frame.
    counts_context: usize = 0,
    counts: [2]?usize = .{ null, null },

    fn deinit(self: *PatchEntry) void {
        page.free(self.root);
        page.free(self.path);
        if (self.parsed) |*parsed| parsed.deinit();
        if (self.err_message) |value| page.free(value);
    }

    pub fn result(self: *const PatchEntry) ?FilePatchResult {
        return if (self.parsed) |parsed| parsed.value else null;
    }

    pub fn patchText(self: *const PatchEntry) ?[]const u8 {
        const value = self.result() orelse return null;
        return value.patch;
    }

    pub fn cachedCount(self: *PatchEntry, split: bool, context_lines: usize) ?usize {
        if (self.counts_context != context_lines) return null;
        return self.counts[@intFromBool(split)];
    }

    pub fn storeCount(self: *PatchEntry, split: bool, context_lines: usize, count: usize) void {
        if (self.counts_context != context_lines) {
            self.counts_context = context_lines;
            self.counts = .{ null, null };
        }
        self.counts[@intFromBool(split)] = count;
    }

    fn resetCounts(self: *PatchEntry) void {
        self.counts = .{ null, null };
    }
};

/// Lines picked in a diff for an agent prompt (`agent_prompt_popover`).
/// Line numbers are 1-based and inclusive; null where the range has no
/// lines on that side (pure additions or deletions).
pub const PromptSide = enum { new, old };

/// 1-based inclusive line range on one side of a diff.
pub const PromptLines = struct { side: PromptSide, first: usize, last: usize };

pub const DiffSelection = struct {
    root: []u8,
    path: []u8,
    old_first: ?usize = null,
    old_last: ?usize = null,
    new_first: ?usize = null,
    new_last: ?usize = null,
    /// `-`/`+`/` ` prefixed lines, as in a unified diff.
    text: []u8,

    fn deinit(self: *DiffSelection) void {
        page.free(self.root);
        page.free(self.path);
        page.free(self.text);
    }

    /// Lines an agent prompt cites: the new side whenever the selection
    /// touches a new-side line (additions or context), else the old side
    /// (a deletion-only selection). Null without line numbers.
    pub fn promptLines(self: DiffSelection) ?PromptLines {
        if (self.new_first) |first| return .{ .side = .new, .first = first, .last = self.new_last orelse first };
        if (self.old_first) |first| return .{ .side = .old, .first = first, .last = self.old_last orelse first };
        return null;
    }
};

pub const State = struct {
    list_lane: Lane = .{},
    patch_lane: Lane = .{},
    /// The view is on screen for `workspace_id`.
    shown: bool = false,
    /// Workspace whose data is held (the selected one while shown).
    workspace_id: ?[]u8 = null,
    data: ?std.json.Parsed(WorkspaceResult) = null,
    chips: []Chip = &.{},
    /// Bumps whenever `data` is replaced or dropped, so the view can tell
    /// whether indices it recorded still point at the same listing.
    data_serial: u64 = 0,
    /// Bumps on workspace switches so late results are dropped.
    generation: u64 = 0,
    /// A list call is running or queued.
    loading: bool = false,
    /// Another refresh was requested while one ran.
    list_queued: bool = false,
    list_error: ?[]u8 = null,
    /// The daemon does not know `git.changes.workspace` (older build).
    disabled: bool = false,
    filter_kind: FilterKind = .all,
    filter_thread: ?[]u8 = null,
    expanded: std.ArrayList(Expanded) = .empty,
    patches: std.ArrayList(PatchEntry) = .empty,
    tick: u64 = 0,
    /// List scroll offset, kept across frames (view-owned semantics).
    scroll_y: f32 = 0.0,
    selection: ?DiffSelection = null,

    pub fn deinit(self: *State) void {
        for ([_]*Lane{ &self.list_lane, &self.patch_lane }) |entry| {
            entry.lock();
            entry.mutex.unlock();
            entry.join();
        }
        self.clearData();
        self.clearFiles();
        self.expanded.deinit(page);
        self.patches.deinit(page);
        if (self.workspace_id) |value| page.free(value);
        self.workspace_id = null;
        if (self.list_error) |value| page.free(value);
        self.list_error = null;
        if (self.filter_thread) |value| page.free(value);
        self.filter_thread = null;
    }

    pub fn result(self: *const State) ?WorkspaceResult {
        return if (self.data) |parsed| parsed.value else null;
    }

    pub fn filter(self: *const State) Filter {
        return .{ .kind = self.filter_kind, .thread_id = self.filter_thread orelse "" };
    }

    pub fn errorText(self: *const State) ?[]const u8 {
        if (self.disabled) return "This Verde daemon does not support the Changes view yet. Restart it after updating.";
        return self.list_error;
    }

    pub fn expandedEntry(self: *State, root: []const u8, path: []const u8) ?*Expanded {
        for (self.expanded.items) |*entry| {
            if (std.mem.eql(u8, entry.root, root) and std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    pub fn isExpanded(self: *State, root: []const u8, path: []const u8) bool {
        return self.expandedEntry(root, path) != null;
    }

    fn findPatch(self: *State, root: []const u8, path: []const u8, full: bool) ?*PatchEntry {
        for (self.patches.items) |*entry| {
            if (entry.full == full and std.mem.eql(u8, entry.root, root) and std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    fn clearData(self: *State) void {
        self.data_serial +%= 1;
        if (self.chips.len > 0) page.free(self.chips);
        self.chips = &.{};
        if (self.data) |*parsed| parsed.deinit();
        self.data = null;
    }

    fn clearFiles(self: *State) void {
        for (self.expanded.items) |*entry| entry.deinit();
        self.expanded.clearRetainingCapacity();
        for (self.patches.items) |*entry| entry.deinit();
        self.patches.clearRetainingCapacity();
        self.clearSelection();
    }

    pub fn clearSelection(self: *State) void {
        if (self.selection) |*selection| selection.deinit();
        self.selection = null;
    }

    fn setListError(self: *State, message: ?[]const u8) void {
        if (self.list_error) |value| page.free(value);
        self.list_error = if (message) |value| page.dupe(u8, value) catch null else null;
    }

    fn storeList(self: *State, parsed: std.json.Parsed(WorkspaceResult)) void {
        var incoming = parsed;
        const chips = collectChips(page, incoming.value) catch {
            incoming.deinit();
            return;
        };
        self.clearData();
        self.data = incoming;
        self.chips = chips;
        // Any patch may have changed; visible ones refetch, old text stays
        // on screen meanwhile.
        for (self.patches.items) |*entry| entry.stale = true;
        // Drop expansion of files that are gone.
        var index: usize = 0;
        while (index < self.expanded.items.len) {
            const entry = self.expanded.items[index];
            if (fileInResult(incoming.value, entry.root, entry.path) == null) {
                var removed = self.expanded.orderedRemove(index);
                removed.deinit();
                continue;
            }
            index += 1;
        }
        // A chat filter whose chat no longer owns anything falls back to All.
        if (self.filter_kind == .thread) {
            const still = for (chips) |chip| {
                if (chip.kind == .thread and std.mem.eql(u8, chip.thread_id, self.filter_thread orelse "")) break true;
            } else false;
            if (!still) self.setFilterValue(.all, null);
        } else if (self.filter_kind == .unassigned) {
            const still = for (chips) |chip| {
                if (chip.kind == .unassigned) break true;
            } else false;
            if (!still) self.setFilterValue(.all, null);
        }
    }

    fn setFilterValue(self: *State, kind: FilterKind, thread_id: ?[]const u8) void {
        if (self.filter_thread) |value| page.free(value);
        self.filter_thread = null;
        self.filter_kind = kind;
        if (kind == .thread) {
            self.filter_thread = page.dupe(u8, thread_id orelse "") catch {
                self.filter_kind = .all;
                return;
            };
        }
    }

    fn evictPatches(self: *State) void {
        while (self.patches.items.len > MAX_PATCHES) {
            var oldest: ?usize = null;
            for (self.patches.items, 0..) |entry, index| {
                if (entry.in_flight) continue;
                if (oldest == null or entry.used_tick < self.patches.items[oldest.?].used_tick) oldest = index;
            }
            const index = oldest orelse return;
            var removed = self.patches.orderedRemove(index);
            removed.deinit();
        }
    }
};

pub fn fileInResult(result: WorkspaceResult, root: []const u8, path: []const u8) ?WorkspaceFile {
    for (result.repos) |repo| {
        if (!std.mem.eql(u8, repo.root, root)) continue;
        for (repo.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
    }
    return null;
}

fn spawn(self: anytype, lane: *Lane, job: Job, params: anytype, tag: []const u8, options: struct {
    timeout_ms: u32,
    delay_ms: u64 = 0,
    full: bool = false,
}) bool {
    if (lane.busy()) return false;
    lane.join();
    const params_json = std.json.Stringify.valueAlloc(page, params, .{ .emit_null_optional_fields = false }) catch return false;
    const request = page.create(Request) catch {
        page.free(params_json);
        return false;
    };
    const pref_path = page.dupe(u8, self.storage.pref_path) catch {
        page.free(params_json);
        page.destroy(request);
        return false;
    };
    const owned_tag = page.dupe(u8, tag) catch {
        page.free(params_json);
        page.free(pref_path);
        page.destroy(request);
        return false;
    };
    request.* = .{
        .job = job,
        .pref_path = pref_path,
        .params_json = params_json,
        .timeout_ms = options.timeout_ms,
        .delay_ms = options.delay_ms,
        .generation = self.workspace_changes.generation,
        .tag = owned_tag,
        .full = options.full,
    };
    lane.lock();
    lane.request = request;
    lane.status = .pending;
    lane.worker = std.Thread.spawn(.{}, worker, .{ lane, request }) catch {
        lane.request = null;
        lane.status = .idle;
        lane.mutex.unlock();
        request.deinit();
        return false;
    };
    lane.mutex.unlock();
    return true;
}

// ------------------------------------------------------------------
// AppState-facing API (self is *AppState)
// ------------------------------------------------------------------

fn selectedWorkspaceId(self: anytype) ?[]const u8 {
    const projects = self.project_controller.projects.items;
    if (projects.len == 0) return null;
    const index = @min(self.project_controller.selected_index, projects.len - 1);
    return projects[index].id;
}

/// Workspace whose Changes view is on screen: the focused tab's side panel
/// is open on `.changes`.
fn visibleWorkspaceId(self: anytype) ?[]const u8 {
    const panel = side_panel_controller.currentSidePanel(self) orelse return null;
    if (!panel.open or panel.view != .changes) return null;
    return selectedWorkspaceId(self);
}

fn switchWorkspace(self: anytype, workspace_id: []const u8) void {
    const state = &self.workspace_changes;
    if (state.workspace_id) |current| {
        if (std.mem.eql(u8, current, workspace_id)) return;
        page.free(current);
    }
    state.workspace_id = page.dupe(u8, workspace_id) catch null;
    state.generation +%= 1;
    state.clearData();
    state.clearFiles();
    state.setListError(null);
    state.setFilterValue(.all, null);
    state.scroll_y = 0.0;
    state.list_queued = false;
    state.loading = false;
}

/// Refreshes the listing now (manual button) or after `delay_ms`. Coalesced:
/// a request while one runs queues one more.
pub fn refreshWorkspaceChanges(self: anytype, delay_ms: u64) void {
    const state = &self.workspace_changes;
    if (state.disabled) return;
    const workspace_id = state.workspace_id orelse return;
    state.loading = true;
    if (spawn(self, &state.list_lane, .list, proto.WorkspaceRequest{ .workspace_id = workspace_id }, workspace_id, .{
        .timeout_ms = LIST_TIMEOUT_MS,
        .delay_ms = delay_ms,
    })) return;
    state.list_queued = true;
}

/// Manual refresh: listing now; every patch refetches as it is drawn.
pub fn refreshWorkspaceChangesNow(self: anytype) void {
    refreshWorkspaceChanges(self, 0);
    self.markDirty();
}

/// Chat journal activity: chats may have edited files.
pub fn noteWorkspaceChangesActivity(self: anytype) void {
    if (!self.workspace_changes.shown) return;
    refreshWorkspaceChanges(self, ACTIVITY_REFRESH_DELAY_MS);
}

pub fn setWorkspaceChangesFilter(self: anytype, kind: FilterKind, thread_id: ?[]const u8) void {
    const state = &self.workspace_changes;
    if (state.filter_kind == kind and (kind != .thread or std.mem.eql(u8, state.filter_thread orelse "", thread_id orelse ""))) return;
    state.setFilterValue(kind, thread_id);
    state.scroll_y = 0.0;
    self.markDirty();
}

pub fn toggleWorkspaceChangesFile(self: anytype, root: []const u8, path: []const u8) void {
    const state = &self.workspace_changes;
    for (state.expanded.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.root, root) and std.mem.eql(u8, entry.path, path)) {
            var removed = state.expanded.orderedRemove(index);
            removed.deinit();
            self.markDirty();
            return;
        }
    }
    const owned_root = page.dupe(u8, root) catch return;
    const owned_path = page.dupe(u8, path) catch {
        page.free(owned_root);
        return;
    };
    state.expanded.append(page, .{ .root = owned_root, .path = owned_path }) catch {
        page.free(owned_root);
        page.free(owned_path);
        return;
    };
    self.markDirty();
}

/// Expands every file of the current filter, or collapses all when every
/// one is already expanded.
pub fn toggleAllWorkspaceChangesFiles(self: anytype) void {
    const state = &self.workspace_changes;
    const data = state.result() orelse return;
    const active = state.filter();
    var all_expanded = true;
    for (data.repos) |repo| {
        for (repo.files) |file| {
            if (active.matches(file) and !state.isExpanded(repo.root, file.path)) all_expanded = false;
        }
    }
    if (all_expanded) {
        for (state.expanded.items) |*entry| entry.deinit();
        state.expanded.clearRetainingCapacity();
    } else {
        for (data.repos) |repo| {
            for (repo.files) |file| {
                if (active.matches(file) and !state.isExpanded(repo.root, file.path)) toggleWorkspaceChangesFile(self, repo.root, file.path);
            }
        }
    }
    self.markDirty();
}

/// Reveals more unchanged lines around an expanded file's changes.
pub fn expandWorkspaceChangesContext(self: anytype, root: []const u8, path: []const u8) void {
    const state = &self.workspace_changes;
    const entry = state.expandedEntry(root, path) orelse return;
    if (entry.full_unavailable or entry.level >= MAX_EXPAND_LEVEL) return;
    entry.level += 1;
    self.markDirty();
}

/// Shows the whole file around an expanded file's changes.
pub fn expandWorkspaceChangesFully(self: anytype, root: []const u8, path: []const u8) void {
    const state = &self.workspace_changes;
    const entry = state.expandedEntry(root, path) orelse return;
    if (entry.full_unavailable) return;
    entry.level = MAX_EXPAND_LEVEL;
    self.markDirty();
}

/// Patch to draw for an expanded file, fetching it (or a fresher one) in the
/// background. Returns the best text on hand: the whole-file patch when the
/// file is context-expanded and it has arrived, else git's hunks. The pointer
/// is valid until the next call (entries may be added).
pub fn workspaceChangesPatch(self: anytype, root: []const u8, path: []const u8) ?*PatchEntry {
    const state = &self.workspace_changes;
    state.tick +%= 1;
    const expanded = state.expandedEntry(root, path);
    const want_full = if (expanded) |entry| entry.level > 0 and !entry.full_unavailable else false;
    const wanted = state.findPatch(root, path, want_full) orelse blk: {
        const owned_root = page.dupe(u8, root) catch return null;
        const owned_path = page.dupe(u8, path) catch {
            page.free(owned_root);
            return null;
        };
        state.patches.append(page, .{ .root = owned_root, .path = owned_path, .full = want_full, .stale = true }) catch {
            page.free(owned_root);
            page.free(owned_path);
            return null;
        };
        break :blk &state.patches.items[state.patches.items.len - 1];
    };
    wanted.used_tick = state.tick;
    if (wanted.stale and !wanted.in_flight) requestPatch(self, wanted);
    // `requestPatch` never grows `patches`, so `wanted` stays valid here.
    if (wanted.parsed != null) return wanted;
    if (want_full) {
        // Keep showing git's hunks until the whole-file patch lands.
        if (state.findPatch(root, path, false)) |fallback| {
            if (fallback.parsed != null) {
                fallback.used_tick = state.tick;
                return fallback;
            }
        }
    }
    return wanted;
}

fn requestPatch(self: anytype, entry: *PatchEntry) void {
    const state = &self.workspace_changes;
    const workspace_id = state.workspace_id orelse return;
    var tag_buf: std.ArrayList(u8) = .empty;
    defer tag_buf.deinit(page);
    tag_buf.appendSlice(page, entry.root) catch return;
    tag_buf.append(page, 0) catch return;
    tag_buf.appendSlice(page, entry.path) catch return;
    const request = proto.FilePatchRequest{
        .workspace_id = workspace_id,
        .root = entry.root,
        .path = entry.path,
        .context_lines = if (entry.full) FULL_CONTEXT else null,
    };
    if (spawn(self, &state.patch_lane, .patch, request, tag_buf.items, .{ .timeout_ms = PATCH_TIMEOUT_MS, .full = entry.full })) {
        entry.in_flight = true;
    }
    // Lane busy: the completion repaints and the next draw asks again.
}

/// Replaces the agent-prompt selection (null clears it).
pub fn setWorkspaceChangesSelection(
    self: anytype,
    root: []const u8,
    path: []const u8,
    old_range: ?[2]usize,
    new_range: ?[2]usize,
    text: []const u8,
) void {
    const state = &self.workspace_changes;
    state.clearSelection();
    const owned_root = page.dupe(u8, root) catch return;
    const owned_path = page.dupe(u8, path) catch {
        page.free(owned_root);
        return;
    };
    const owned_text = page.dupe(u8, text) catch {
        page.free(owned_root);
        page.free(owned_path);
        return;
    };
    state.selection = .{
        .root = owned_root,
        .path = owned_path,
        .old_first = if (old_range) |range| range[0] else null,
        .old_last = if (old_range) |range| range[1] else null,
        .new_first = if (new_range) |range| range[0] else null,
        .new_last = if (new_range) |range| range[1] else null,
        .text = owned_text,
    };
    self.markDirty();
}

/// "Commit…": the review sheet of the filtered chat, else the focused chat,
/// else the first chat that claimed files.
pub fn openWorkspaceChangesCommit(self: anytype) void {
    const state = &self.workspace_changes;
    if (state.filter_kind == .thread) {
        if (state.filter_thread) |thread_id| {
            self.openCommitSheetForThreadId(thread_id);
            return;
        }
    }
    if (self.openCommitSheetForFocusedChat()) return;
    for (state.chips) |chip| {
        if (chip.kind != .thread) continue;
        self.openCommitSheetForThreadId(chip.thread_id);
        return;
    }
    self.setSidebarNotice("Open a chat in this workspace to commit its changes.");
}

/// Hook for the Files viewer: opens `root/path` there when the app provides
/// `openFileInViewer(abs_path)`; otherwise says it is unavailable.
pub fn openChangedFileInViewer(self: anytype, root: []const u8, path: []const u8) void {
    const Self = @TypeOf(self.*);
    if (comptime @hasDecl(Self, "openFileInViewer")) {
        const abs_path = std.fs.path.join(page, &.{ root, path }) catch return;
        defer page.free(abs_path);
        self.openFileInViewer(abs_path);
    } else {
        self.setSidebarNotice("The file viewer is not available in this build.");
    }
}

/// Drains finished workers and tracks visibility. Called every main-loop
/// iteration from `pollGitChanges`.
pub fn pollWorkspaceChanges(self: anytype) void {
    const state = &self.workspace_changes;
    if (state.list_lane.takeCompleted()) |done| {
        var result = done.result;
        defer result.deinit();
        defer done.request.deinit();
        if (done.request.generation == state.generation) {
            state.loading = false;
            switch (result.payload) {
                .list => |parsed| {
                    result.payload = .none;
                    state.storeList(parsed);
                    state.setListError(null);
                },
                else => {
                    if (isUnknownMethod(result.err_code)) state.disabled = true;
                    state.setListError(result.err_message orelse "Could not load changes.");
                },
            }
            self.markDirty();
        }
        if (state.list_queued) {
            state.list_queued = false;
            // Nothing on screen yet (workspace switch): no reason to wait.
            refreshWorkspaceChanges(self, if (state.data == null) 0 else ACTIVITY_REFRESH_DELAY_MS);
        }
    }
    if (state.patch_lane.takeCompleted()) |done| {
        var result = done.result;
        defer result.deinit();
        defer done.request.deinit();
        if (done.request.generation == state.generation) applyPatch(self, done.request, &result);
    }

    if (visibleWorkspaceId(self)) |workspace_id| {
        const switched = if (state.workspace_id) |current| !std.mem.eql(u8, current, workspace_id) else true;
        if (switched) switchWorkspace(self, workspace_id);
        if (!state.shown or switched) {
            state.shown = true;
            refreshWorkspaceChanges(self, 0);
        }
    } else {
        state.shown = false;
    }
}

fn applyPatch(self: anytype, request: *Request, result: *Result) void {
    const state = &self.workspace_changes;
    const split = std.mem.indexOfScalar(u8, request.tag, 0) orelse return;
    const root = request.tag[0..split];
    const path = request.tag[split + 1 ..];
    const entry = state.findPatch(root, path, request.full) orelse return;
    entry.in_flight = false;
    switch (result.payload) {
        .patch => |parsed| {
            result.payload = .none;
            if (entry.parsed) |*old| old.deinit();
            entry.parsed = parsed;
            entry.stale = false;
            entry.resetCounts();
            if (entry.err_message) |value| page.free(value);
            entry.err_message = null;
            if (request.full and parsed.value.truncated) {
                if (state.expandedEntry(root, path)) |expanded| {
                    expanded.full_unavailable = true;
                    expanded.level = 0;
                }
            }
        },
        else => {
            entry.stale = false;
            if (entry.err_message) |value| page.free(value);
            entry.err_message = page.dupe(u8, result.err_message orelse "Could not load this diff.") catch null;
        },
    }
    state.evictPatches();
    self.markDirty();
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

fn testResult() WorkspaceResult {
    const S = struct {
        const owner_a = [_]proto.WorkspaceOwner{.{ .local_thread_id = "t-a", .title = "Fix parser" }};
        const owner_b = [_]proto.WorkspaceOwner{.{ .local_thread_id = "t-b", .title = "" }};
        const owner_ab = [_]proto.WorkspaceOwner{ .{ .local_thread_id = "t-a", .title = "Fix parser" }, .{ .local_thread_id = "t-b", .title = "" } };
        const files_one = [_]WorkspaceFile{
            .{ .path = "src/a.zig", .status = "modified", .ownership = "mine", .owners = &owner_a, .additions = 3, .deletions = 1 },
            .{ .path = "src/b.zig", .status = "added", .untracked = true, .ownership = "unassigned", .additions = 10 },
            .{ .path = "src/c.zig", .status = "modified", .ownership = "shared", .owners = &owner_ab, .additions = 1, .deletions = 1 },
        };
        const files_two = [_]WorkspaceFile{
            .{ .path = "README.md", .status = "deleted", .ownership = "mine", .owners = &owner_b, .deletions = 7 },
        };
        const repos = [_]WorkspaceRepo{
            .{ .root = "/w/one", .name = "one", .files = &files_one },
            .{ .root = "/w/two", .name = "two", .files = &files_two },
            .{ .root = "/w/clean", .name = "clean" },
        };
    };
    return .{ .workspace_id = "ws", .repos = &S.repos };
}

test "chips list chats in claim order and unassigned last" {
    const chips = try collectChips(testing.allocator, testResult());
    defer testing.allocator.free(chips);
    try testing.expectEqual(@as(usize, 4), chips.len);
    try testing.expectEqual(FilterKind.all, chips[0].kind);
    try testing.expectEqual(@as(usize, 4), chips[0].files);
    try testing.expectEqualStrings("t-a", chips[1].thread_id);
    try testing.expectEqualStrings("Fix parser", chips[1].title);
    try testing.expectEqual(@as(usize, 2), chips[1].files);
    try testing.expectEqualStrings("t-b", chips[2].thread_id);
    try testing.expectEqualStrings("Chat", chips[2].title);
    try testing.expectEqual(@as(usize, 2), chips[2].files);
    try testing.expectEqual(FilterKind.unassigned, chips[3].kind);
    try testing.expectEqual(@as(usize, 1), chips[3].files);
}

test "filters and totals follow chip choice" {
    const result = testResult();
    const all = totals(result, .{});
    try testing.expectEqual(@as(usize, 4), all.files);
    try testing.expectEqual(@as(u64, 14), all.additions);
    try testing.expectEqual(@as(u64, 9), all.deletions);
    try testing.expectEqual(@as(usize, 2), all.repos_with_files);
    const chat_b = totals(result, .{ .kind = .thread, .thread_id = "t-b" });
    try testing.expectEqual(@as(usize, 2), chat_b.files);
    try testing.expectEqual(@as(usize, 2), chat_b.repos_with_files);
    const unassigned = totals(result, .{ .kind = .unassigned });
    try testing.expectEqual(@as(usize, 1), unassigned.files);
    try testing.expectEqual(@as(u64, 10), unassigned.additions);
}

test "prompt lines prefer the new side unless only deletions are selected" {
    var empty: [0]u8 = .{};
    const base = DiffSelection{ .root = &empty, .path = &empty, .text = &empty };
    var mixed = base;
    mixed.old_first = 10;
    mixed.old_last = 12;
    mixed.new_first = 10;
    mixed.new_last = 14;
    try std.testing.expectEqual(PromptLines{ .side = .new, .first = 10, .last = 14 }, mixed.promptLines().?);
    var deletions = base;
    deletions.old_first = 7;
    deletions.old_last = 9;
    try std.testing.expectEqual(PromptLines{ .side = .old, .first = 7, .last = 9 }, deletions.promptLines().?);
    try std.testing.expect(base.promptLines() == null);
}

test "row labels" {
    const result = testResult();
    try testing.expectEqualStrings("M", statusLetter(result.repos[0].files[0]));
    try testing.expectEqualStrings("U", statusLetter(result.repos[0].files[1]));
    try testing.expectEqualStrings("D", statusLetter(result.repos[1].files[0]));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Fix parser", ownerLabel(&buf, result.repos[0].files[0]));
    try testing.expectEqualStrings("", ownerLabel(&buf, result.repos[0].files[1]));
    try testing.expectEqualStrings("2 chats", ownerLabel(&buf, result.repos[0].files[2]));
    try testing.expect(fileInResult(result, "/w/two", "README.md") != null);
    try testing.expect(fileInResult(result, "/w/one", "README.md") == null);
}

test "expand levels widen context and cap at the whole file" {
    try testing.expectEqual(BASE_CONTEXT_LINES, viewContextLines(0));
    try testing.expectEqual(BASE_CONTEXT_LINES + EXPAND_STEP_LINES, viewContextLines(1));
    try testing.expect(viewContextLines(1) < viewContextLines(2));
    try testing.expectEqual(@as(usize, FULL_CONTEXT), viewContextLines(MAX_EXPAND_LEVEL));
}

test "stored listings drop gone expansions and stale filters" {
    var state: State = .{};
    defer state.deinit();
    state.expanded.append(page, .{ .root = try page.dupe(u8, "/w/one"), .path = try page.dupe(u8, "src/a.zig") }) catch unreachable;
    state.expanded.append(page, .{ .root = try page.dupe(u8, "/w/one"), .path = try page.dupe(u8, "gone.zig") }) catch unreachable;
    state.patches.append(page, .{ .root = try page.dupe(u8, "/w/one"), .path = try page.dupe(u8, "src/a.zig"), .full = false }) catch unreachable;
    state.setFilterValue(.thread, "t-gone");

    const json = try std.json.Stringify.valueAlloc(testing.allocator, testResult(), .{});
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(WorkspaceResult, page, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    state.storeList(parsed);

    try testing.expectEqual(@as(usize, 1), state.expanded.items.len);
    try testing.expectEqualStrings("src/a.zig", state.expanded.items[0].path);
    try testing.expect(state.patches.items[0].stale);
    try testing.expectEqual(FilterKind.all, state.filter_kind);
    try testing.expectEqual(@as(usize, 4), state.chips.len);
}

test "patch eviction keeps in-flight and recent entries" {
    var state: State = .{};
    defer state.deinit();
    var index: usize = 0;
    while (index < MAX_PATCHES + 3) : (index += 1) {
        const path = try std.fmt.allocPrint(page, "f{d}", .{index});
        state.patches.append(page, .{
            .root = try page.dupe(u8, "/r"),
            .path = path,
            .full = false,
            .used_tick = index,
            .in_flight = index == 0,
        }) catch unreachable;
    }
    state.evictPatches();
    try testing.expectEqual(MAX_PATCHES, state.patches.items.len);
    try testing.expect(state.findPatch("/r", "f0", false) != null);
    try testing.expect(state.findPatch("/r", "f1", false) == null);
    try testing.expect(state.findPatch("/r", "f3", false) == null);
    try testing.expect(state.findPatch("/r", "f4", false) != null);
}

test "memoized row counts reset with the context" {
    var empty: [0]u8 = .{};
    var entry: PatchEntry = .{ .root = &empty, .path = &empty, .full = false };
    try testing.expect(entry.cachedCount(false, 3) == null);
    entry.storeCount(false, 3, 12);
    entry.storeCount(true, 3, 9);
    try testing.expectEqual(@as(?usize, 12), entry.cachedCount(false, 3));
    try testing.expectEqual(@as(?usize, 9), entry.cachedCount(true, 3));
    try testing.expect(entry.cachedCount(false, 23) == null);
    entry.storeCount(false, 23, 40);
    try testing.expect(entry.cachedCount(true, 23) == null);
}
