//! Shared provider background-task reducer used by GUI hydration and daemon close.
const std = @import("std");
const Provider = @import("../db/types.zig").Provider;
const platform_paths = @import("platform_paths");
const platform_runtime = @import("platform_runtime");

pub const BackgroundTaskStatus = enum {
    running,
    completed,
    failed,
    stopped,
};

pub const BackgroundTask = struct {
    command: [:0]const u8,
    task_id: ?[:0]const u8 = null,
    item_id: ?[:0]const u8 = null,
    process_id: ?[:0]const u8 = null,
    provider_thread_id: ?[:0]const u8 = null,
    cwd: ?[:0]const u8 = null,
    provider: ?Provider = null,
    pid_path: ?[:0]const u8 = null,
    log_path: ?[:0]const u8 = null,
    pid: ?u32 = null,
    pid_verified: bool = false,
    stop_requested: bool = false,
    status: BackgroundTaskStatus,
    started_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
    last_poll_ms: i64 = 0,
    poll_failure_count: u8 = 0,

    pub fn deinit(self: BackgroundTask, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        if (self.task_id) |value| allocator.free(value);
        if (self.item_id) |value| allocator.free(value);
        if (self.process_id) |value| allocator.free(value);
        if (self.provider_thread_id) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.pid_path) |value| allocator.free(value);
        if (self.log_path) |value| allocator.free(value);
    }

    pub fn matchesEventBody(self: *const BackgroundTask, body_raw: []const u8) bool {
        const task_id = backgroundTaskMetadataValue(body_raw, "Verde task ID:");
        const item_id = backgroundTaskMetadataValue(body_raw, "Codex item ID:");
        const process_id = backgroundTaskMetadataValue(body_raw, "Process ID:");
        const provider_thread_id = backgroundTaskMetadataValue(body_raw, "Provider thread ID:");
        if (task_id != null and self.task_id != null and std.mem.eql(u8, task_id.?, self.task_id.?)) return true;
        if (item_id != null and self.item_id != null and provider_thread_id != null and self.provider_thread_id != null and
            std.mem.eql(u8, item_id.?, self.item_id.?) and std.mem.eql(u8, provider_thread_id.?, self.provider_thread_id.?)) return true;
        if (item_id == null and self.item_id == null and process_id != null and self.process_id != null and
            provider_thread_id != null and self.provider_thread_id != null and std.mem.eql(u8, process_id.?, self.process_id.?) and
            std.mem.eql(u8, provider_thread_id.?, self.provider_thread_id.?)) return true;
        if (task_id == null and item_id == null and process_id == null and self.task_id == null and self.item_id == null and
            self.process_id == null and std.mem.eql(u8, backgroundCommandFromEventBody(body_raw), self.command)) return true;
        return false;
    }
};

pub fn backgroundCommandFromEventBody(body_raw: []const u8) []const u8 {
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    if (std.mem.find(u8, body, "\n\n")) |index| {
        return std.mem.trim(u8, body[0..index], "\n\r\t ");
    }
    return body;
}

pub fn isBackgroundCommandEvent(author: []const u8) bool {
    return std.mem.eql(u8, author, "Background command") or
        std.mem.eql(u8, author, "Backgrounded command");
}

/// Codex emits this marker after each turn listing the retained background
/// terminals of one provider thread. It is committed to the transcript and
/// hidden at render time.
pub const CODEX_BACKGROUND_SNAPSHOT_AUTHOR = "__verde_codex_background_snapshot";

pub fn isCodexBackgroundSnapshotEvent(author: []const u8) bool {
    return std.mem.eql(u8, author, CODEX_BACKGROUND_SNAPSHOT_AUTHOR);
}

/// True when `task` is a running Codex terminal of the snapshot's provider
/// thread that the snapshot no longer lists, meaning Codex has released it.
pub fn codexBackgroundTaskAbsentFromSnapshot(task: *const BackgroundTask, snapshot_body: []const u8) bool {
    const provider_thread_id = backgroundTaskMetadataValue(snapshot_body, "Provider thread ID:") orelse return false;
    if (task.status != .running or task.provider != .codex or task.item_id == null or task.provider_thread_id == null) return false;
    if (!std.mem.eql(u8, task.provider_thread_id.?, provider_thread_id)) return false;
    var lines = std.mem.splitScalar(u8, snapshot_body, '\n');
    while (lines.next()) |line| {
        const prefix = "Codex item ID:";
        if (std.mem.startsWith(u8, line, prefix) and std.mem.eql(u8, std.mem.trim(u8, line[prefix.len..], " \t"), task.item_id.?)) {
            return false;
        }
    }
    return true;
}

/// Marks running Codex tasks the snapshot omits as completed. Returns the
/// number of tasks that changed.
pub fn applyCodexBackgroundSnapshot(self: anytype, snapshot_body: []const u8) usize {
    var completed: usize = 0;
    for (self.background_tasks.items) |*task| {
        if (!codexBackgroundTaskAbsentFromSnapshot(task, snapshot_body)) continue;
        task.status = .completed;
        task.updated_at_ms = unixTimestampMs();
        completed += 1;
    }
    return completed;
}

pub fn isBackgroundTaskTerminalEvent(author: []const u8) bool {
    const status = backgroundTaskStatusForEvent(author) orelse return false;
    return status != .running;
}

pub fn backgroundCommandBodiesMatch(a_body: []const u8, b_body: []const u8) bool {
    const a_task_id = backgroundTaskMetadataValue(a_body, "Verde task ID:");
    const b_task_id = backgroundTaskMetadataValue(b_body, "Verde task ID:");
    if (a_task_id != null and b_task_id != null) return std.mem.eql(u8, a_task_id.?, b_task_id.?);

    const a_item_id = backgroundTaskMetadataValue(a_body, "Codex item ID:");
    const b_item_id = backgroundTaskMetadataValue(b_body, "Codex item ID:");
    const a_thread_id = backgroundTaskMetadataValue(a_body, "Provider thread ID:");
    const b_thread_id = backgroundTaskMetadataValue(b_body, "Provider thread ID:");
    if (a_item_id != null and b_item_id != null and a_thread_id != null and b_thread_id != null) {
        return std.mem.eql(u8, a_item_id.?, b_item_id.?) and std.mem.eql(u8, a_thread_id.?, b_thread_id.?);
    }

    const a_process_id = backgroundTaskMetadataValue(a_body, "Process ID:");
    const b_process_id = backgroundTaskMetadataValue(b_body, "Process ID:");
    if (a_item_id == null and b_item_id == null and a_process_id != null and b_process_id != null and
        a_thread_id != null and b_thread_id != null)
    {
        return std.mem.eql(u8, a_process_id.?, b_process_id.?) and std.mem.eql(u8, a_thread_id.?, b_thread_id.?);
    }

    if (a_task_id == null and b_task_id == null and a_item_id == null and b_item_id == null and
        a_process_id == null and b_process_id == null)
    {
        return std.mem.eql(u8, backgroundCommandFromEventBody(a_body), backgroundCommandFromEventBody(b_body));
    }
    return false;
}

pub fn backgroundTaskStatusForEvent(author: []const u8) ?BackgroundTaskStatus {
    if (isBackgroundCommandEvent(author)) return .running;
    if (std.mem.eql(u8, author, "Background task completed")) return .completed;
    if (std.mem.eql(u8, author, "Background task failed")) return .failed;
    if (std.mem.eql(u8, author, "Background task stopped")) return .stopped;
    return null;
}

pub fn backgroundTaskMetadataValue(body_raw: []const u8, label: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body_raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, "\r\t ");
        if (!std.mem.startsWith(u8, line, label)) continue;
        return std.mem.trim(u8, line[label.len..], "\r\t ");
    }
    return null;
}

pub fn allocPrintZCompat(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const raw = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(raw);
    return try allocator.dupeZ(u8, raw);
}

pub fn backgroundTaskPidPathForId(allocator: std.mem.Allocator, task_id: []const u8) ![:0]const u8 {
    const temp_dir = try platform_paths.tempDir(allocator);
    defer allocator.free(temp_dir);
    const filename = try std.fmt.allocPrint(allocator, "verde-claude-bg-{s}.pid", .{task_id});
    defer allocator.free(filename);
    const joined = try std.fs.path.join(allocator, &.{ temp_dir, filename });
    defer allocator.free(joined);
    return try allocator.dupeZ(u8, joined);
}

pub fn replaceOptionalZ(
    allocator: std.mem.Allocator,
    slot: *?[:0]const u8,
    value: ?[]const u8,
) !void {
    const raw = value orelse return;
    if (raw.len == 0) return;
    if (slot.*) |existing| {
        if (std.mem.eql(u8, existing, raw)) return;
        allocator.free(existing);
    }
    slot.* = try allocator.dupeZ(u8, raw);
}

pub fn refreshBackgroundTaskMetadata(task: *BackgroundTask, allocator: std.mem.Allocator, body_raw: []const u8) !void {
    const explicit_pid_path = backgroundTaskMetadataValue(body_raw, "PID file:");
    if (backgroundTaskMetadataValue(body_raw, "Verde task ID:")) |task_id| {
        const previous_matches = task.task_id != null and std.mem.eql(u8, task.task_id.?, task_id);
        try replaceOptionalZ(allocator, &task.task_id, task_id);
        if (explicit_pid_path == null and (task.pid_path == null or !previous_matches)) {
            if (task.pid_path) |existing| allocator.free(existing);
            task.pid_path = try backgroundTaskPidPathForId(allocator, task_id);
        }
    }
    try replaceOptionalZ(allocator, &task.pid_path, explicit_pid_path);
    try replaceOptionalZ(allocator, &task.log_path, backgroundTaskMetadataValue(body_raw, "Output log:"));
    try replaceOptionalZ(allocator, &task.item_id, backgroundTaskMetadataValue(body_raw, "Codex item ID:"));
    try replaceOptionalZ(allocator, &task.process_id, backgroundTaskMetadataValue(body_raw, "Process ID:"));
    try replaceOptionalZ(allocator, &task.provider_thread_id, backgroundTaskMetadataValue(body_raw, "Provider thread ID:"));
    try replaceOptionalZ(allocator, &task.cwd, backgroundTaskMetadataValue(body_raw, "CWD:"));
    if (backgroundTaskMetadataValue(body_raw, "Provider:")) |value| {
        task.provider = std.meta.stringToEnum(Provider, value);
    }
}

pub fn noteBackgroundTaskEvent(self: anytype, allocator: std.mem.Allocator, author: []const u8, body_raw: []const u8) !void {
    const status = backgroundTaskStatusForEvent(author) orelse return;
    const command = backgroundCommandFromEventBody(body_raw);
    if (command.len == 0) return;

    const task_id = backgroundTaskMetadataValue(body_raw, "Verde task ID:");
    const item_id = backgroundTaskMetadataValue(body_raw, "Codex item ID:");
    const process_id = backgroundTaskMetadataValue(body_raw, "Process ID:");
    const provider_thread_id = backgroundTaskMetadataValue(body_raw, "Provider thread ID:");
    var matched_terminal_task: ?*BackgroundTask = null;
    for (self.background_tasks.items) |*task| {
        const identity_matches = (task_id != null and task.task_id != null and std.mem.eql(u8, task.task_id.?, task_id.?)) or
            (item_id != null and task.item_id != null and provider_thread_id != null and task.provider_thread_id != null and
                std.mem.eql(u8, task.item_id.?, item_id.?) and std.mem.eql(u8, task.provider_thread_id.?, provider_thread_id.?)) or
            (item_id == null and task.item_id == null and process_id != null and task.process_id != null and
                provider_thread_id != null and task.provider_thread_id != null and std.mem.eql(u8, task.process_id.?, process_id.?) and
                std.mem.eql(u8, task.provider_thread_id.?, provider_thread_id.?));
        const legacy_command_matches = task_id == null and item_id == null and process_id == null and task.task_id == null and task.item_id == null and
            task.process_id == null and std.mem.eql(u8, task.command, command);
        if (!identity_matches and !legacy_command_matches) continue;
        // Repeated anonymous commands have no provider identity. A
        // terminal event belongs to the first still-running match; using
        // an already-terminal match forever leaves its sibling waiting.
        if (status != .running and task.status != .running) {
            if (matched_terminal_task == null) matched_terminal_task = task;
            continue;
        }
        task.status = status;
        task.updated_at_ms = unixTimestampMs();
        try refreshBackgroundTaskMetadata(task, allocator, body_raw);
        return;
    }
    if (matched_terminal_task) |task| {
        task.status = status;
        task.updated_at_ms = unixTimestampMs();
        try refreshBackgroundTaskMetadata(task, allocator, body_raw);
        return;
    }

    var task: BackgroundTask = .{
        .command = try allocator.dupeZ(u8, command),
        .status = status,
        .started_at_ms = unixTimestampMs(),
        .updated_at_ms = unixTimestampMs(),
    };
    errdefer task.deinit(allocator);
    try refreshBackgroundTaskMetadata(&task, allocator, body_raw);
    try self.background_tasks.append(allocator, task);
}

/// Claude's tracked commands are owned by the query that emitted them and
/// intentionally have no detached PID or retained provider process id.
/// Once that query ends, such a row cannot still be live.
pub fn stopUnownedBackgroundTasks(self: anytype) usize {
    var stopped: usize = 0;
    for (self.background_tasks.items) |*task| {
        if (task.status != .running or task.pid_path != null or task.process_id != null) continue;
        task.status = .stopped;
        task.updated_at_ms = unixTimestampMs();
        stopped += 1;
    }
    return stopped;
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

pub const Replay = struct {
    background_tasks: std.ArrayList(BackgroundTask) = .empty,

    pub fn deinit(self: *Replay, allocator: std.mem.Allocator) void {
        for (self.background_tasks.items) |task| task.deinit(allocator);
        self.background_tasks.deinit(allocator);
    }

    /// Keep the author filter in daemon Store.runningBackgroundTaskCount in
    /// sync when this reducer learns a new event author.
    pub fn apply(self: *Replay, allocator: std.mem.Allocator, author: []const u8, body: []const u8) !void {
        try noteBackgroundTaskEvent(self, allocator, author, body);
        if (std.mem.eql(u8, author, "Conversation interrupted")) _ = stopUnownedBackgroundTasks(self);
        if (isCodexBackgroundSnapshotEvent(author)) _ = applyCodexBackgroundSnapshot(self, body);
    }

    pub fn runningCount(self: *const Replay) usize {
        var count: usize = 0;
        for (self.background_tasks.items) |task| if (task.status == .running) {
            count += 1;
        };
        return count;
    }
};
