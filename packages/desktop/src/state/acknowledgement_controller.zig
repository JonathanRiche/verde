//! Off-thread persistence for focus-driven completion acknowledgements.

const std = @import("std");

const storage_mod = @import("storage.zig");
const db_types = @import("../db/types.zig");
const platform_runtime = @import("platform_runtime");
const surface_controller = @import("surface_controller.zig");

const Storage = storage_mod.Storage;
const log = std.log.scoped(.native_shell);
const CHAT_RETRY_MIN_MS: i64 = 1_000;
const CHAT_RETRY_MAX_MS: i64 = 30_000;

fn optionalTextEqual(actual: ?[]const u8, expected: ?[]const u8) bool {
    if (actual) |actual_value| {
        return if (expected) |expected_value| std.mem.eql(u8, actual_value, expected_value) else false;
    }
    return expected == null;
}

// Compare every field in the std-only durable surface representation.
fn surfaceStatesEqual(a: db_types.PersistedSurfaceState, b: db_types.PersistedSurfaceState) bool {
    return std.mem.eql(u8, a.session_id, b.session_id) and
        std.mem.eql(u8, a.workspace_id, b.workspace_id) and
        std.mem.eql(u8, a.workspace_path, b.workspace_path) and
        a.dock_id == b.dock_id and
        a.pane_id == b.pane_id and
        a.provider == b.provider and
        optionalTextEqual(a.provider_thread_id, b.provider_thread_id) and
        std.mem.eql(u8, a.title, b.title) and
        a.status == b.status and
        a.status_changed_at_ms == b.status_changed_at_ms and
        a.completed_at_ms == b.completed_at_ms and
        optionalTextEqual(a.last_event_title, b.last_event_title) and
        optionalTextEqual(a.last_event_body, b.last_event_body);
}

const ChatAcknowledgement = struct {
    workspace_id: []u8,
    local_thread_id: []u8,
    completed_at_ms: i64,
    retry_attempts: u8 = 0,
    retry_not_before_ms: i64 = 0,
};

const SurfaceAcknowledgement = struct {
    canonical: db_types.PersistedSurfaceState,
    completion_pending: bool = true,
    attention: bool,
    unread_count: u32,
    consumed_generation: u64,

    fn deinit(self: *SurfaceAcknowledgement, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical.session_id);
        allocator.free(self.canonical.workspace_id);
        allocator.free(self.canonical.workspace_path);
        if (self.canonical.provider_thread_id) |value| allocator.free(value);
        allocator.free(self.canonical.title);
        if (self.canonical.last_event_title) |value| allocator.free(value);
        if (self.canonical.last_event_body) |value| allocator.free(value);
        self.* = undefined;
    }
};

const Acknowledgement = union(enum) {
    chat: ChatAcknowledgement,
    surface: SurfaceAcknowledgement,

    fn deinit(self: *Acknowledgement, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .chat => |ack| {
                allocator.free(ack.workspace_id);
                allocator.free(ack.local_thread_id);
            },
            .surface => |*ack| ack.deinit(allocator),
        }
        self.* = undefined;
    }

    fn matchesChat(self: Acknowledgement, workspace_id: []const u8, local_thread_id: []const u8) bool {
        return switch (self) {
            .chat => |ack| std.mem.eql(u8, ack.workspace_id, workspace_id) and
                std.mem.eql(u8, ack.local_thread_id, local_thread_id),
            .surface => false,
        };
    }

    fn matchesSurfaceCompletion(self: Acknowledgement, canonical: db_types.PersistedSurfaceState) bool {
        return switch (self) {
            .chat => false,
            .surface => |ack| surfaceStatesEqual(ack.canonical, canonical),
        };
    }
};

const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    storage: *const Storage,
    acknowledgement: Acknowledgement,
    success: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const State = struct {
    pending: std.ArrayList(Acknowledgement) = .empty,
    chat_suppressions: std.ArrayList(ChatAcknowledgement) = .empty,
    worker: ?std.Thread = null,
    worker_args: ?*WorkerArgs = null,
};

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |slice| try allocator.dupe(u8, slice) else null;
}

fn ownSurfaceAcknowledgement(allocator: std.mem.Allocator, canonical: db_types.PersistedSurfaceState) !db_types.PersistedSurfaceState {
    const session_id = try allocator.dupe(u8, canonical.session_id);
    errdefer allocator.free(session_id);
    const workspace_id = try allocator.dupe(u8, canonical.workspace_id);
    errdefer allocator.free(workspace_id);
    const workspace_path = try allocator.dupe(u8, canonical.workspace_path);
    errdefer allocator.free(workspace_path);
    const provider_thread_id = try dupeOptional(allocator, canonical.provider_thread_id);
    errdefer if (provider_thread_id) |value| allocator.free(value);
    const title = try allocator.dupe(u8, canonical.title);
    errdefer allocator.free(title);
    const last_event_title = try dupeOptional(allocator, canonical.last_event_title);
    errdefer if (last_event_title) |value| allocator.free(value);
    const last_event_body = try dupeOptional(allocator, canonical.last_event_body);
    return .{
        .session_id = session_id,
        .workspace_id = workspace_id,
        .workspace_path = workspace_path,
        .dock_id = canonical.dock_id,
        .pane_id = canonical.pane_id,
        .provider = canonical.provider,
        .provider_thread_id = provider_thread_id,
        .title = title,
        .status = canonical.status,
        .status_changed_at_ms = canonical.status_changed_at_ms,
        .completed_at_ms = canonical.completed_at_ms,
        .last_event_title = last_event_title,
        .last_event_body = last_event_body,
    };
}

fn deinitOwnedCanonical(allocator: std.mem.Allocator, canonical: *db_types.PersistedSurfaceState) void {
    var ack: SurfaceAcknowledgement = .{
        .canonical = canonical.*,
        .attention = false,
        .unread_count = 0,
        .consumed_generation = 0,
    };
    ack.deinit(allocator);
    canonical.* = undefined;
}

/// Queue a chat completion clear without waiting for the daemon on the UI thread.
pub fn queueChat(
    self: anytype,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    completed_at_ms: i64,
) bool {
    const state = &self.acknowledgement_controller;
    if (matchingChatAcknowledgement(state, workspace_id, local_thread_id, completed_at_ms)) return true;
    const outstanding_chat_count = countPendingChats(state);
    state.chat_suppressions.ensureTotalCapacity(
        self.allocator,
        state.chat_suppressions.items.len + outstanding_chat_count + 1,
    ) catch return false;
    const owned_workspace_id = self.allocator.dupe(u8, workspace_id) catch return false;
    const owned_thread_id = self.allocator.dupe(u8, local_thread_id) catch {
        self.allocator.free(owned_workspace_id);
        return false;
    };
    state.pending.append(self.allocator, .{ .chat = .{
        .workspace_id = owned_workspace_id,
        .local_thread_id = owned_thread_id,
        .completed_at_ms = completed_at_ms,
    } }) catch {
        self.allocator.free(owned_workspace_id);
        self.allocator.free(owned_thread_id);
        return false;
    };
    startNext(self);
    return true;
}

/// Queue a terminal-surface clear without waiting for the daemon on the UI thread.
pub fn queueSurface(self: anytype, surface: anytype) bool {
    const state = &self.acknowledgement_controller;
    if (!enqueueSurface(state, self.allocator, surface)) return false;
    startNext(self);
    return true;
}

fn enqueueSurface(state: *State, allocator: std.mem.Allocator, surface: *const surface_controller.SurfaceState) bool {
    const canonical = surface_controller.persistedSurfaceState(surface);
    if (containsSurfaceCompletionState(state, canonical)) return true;
    var owned = ownSurfaceAcknowledgement(allocator, canonical) catch return false;
    state.pending.append(allocator, .{ .surface = .{
        .canonical = owned,
        .completion_pending = surface.completion_pending,
        .attention = surface.attention,
        .unread_count = surface.unread_count,
        .consumed_generation = surface.presentation_generation +% 1,
    } }) catch {
        deinitOwnedCanonical(allocator, &owned);
        return false;
    };
    return true;
}

/// Returns whether the exact completion is awaiting its durable clear.
pub fn containsSurfaceCompletion(self: anytype, canonical: db_types.PersistedSurfaceState) bool {
    return containsSurfaceCompletionState(&self.acknowledgement_controller, canonical);
}

fn containsSurfaceCompletionState(state: *const State, canonical: db_types.PersistedSurfaceState) bool {
    if (state.worker_args) |args| {
        if (args.acknowledgement.matchesSurfaceCompletion(canonical)) return true;
    }
    for (state.pending.items) |acknowledgement| {
        if (acknowledgement.matchesSurfaceCompletion(canonical)) return true;
    }
    return false;
}

/// Apply one completed acknowledgement and start the next queued mutation.
pub fn poll(self: anytype) void {
    const state = &self.acknowledgement_controller;
    const args = state.worker_args orelse {
        startNext(self);
        return;
    };
    if (!args.done.load(.acquire)) return;
    state.worker.?.join();
    state.worker = null;
    state.worker_args = null;
    var acknowledgement = args.acknowledgement;
    if (!args.success) {
        if (requeueFailedChat(self, &acknowledgement)) {
            args.allocator.destroy(args);
            startNext(self);
            return;
        }
        restoreFailed(self, acknowledgement);
        acknowledgement.deinit(args.allocator);
    } else switch (acknowledgement) {
        .chat => |ack| state.chat_suppressions.appendAssumeCapacity(ack),
        .surface => acknowledgement.deinit(args.allocator),
    }
    args.allocator.destroy(args);
    startNext(self);
}

/// Keep an acknowledged completion hidden while an older daemon projection
/// can still carry it. A genuinely later completion remains visible.
pub fn applyChatCompletionSuppressions(self: anytype, projects: anytype) void {
    const collections = .{ &projects.projects, &projects.archived_projects };
    inline for (collections) |project_list| {
        for (project_list.items) |*project| {
            clearSuppressedThreads(self, project.id, project.threads.items);
            clearSuppressedThreads(self, project.id, project.archived_threads.items);
        }
    }
}

/// Retire tombstones only after a projection omits the acknowledged row or
/// replaces it with a later completion.
pub fn reconcileChatCompletionSuppressions(self: anytype, completions: anytype) void {
    const state = &self.acknowledgement_controller;
    var index: usize = 0;
    while (index < state.chat_suppressions.items.len) {
        const suppression = state.chat_suppressions.items[index];
        const projected = projectedChatCompletion(completions, suppression.workspace_id, suppression.local_thread_id);
        if (projected != null and projected.?.completed_at_ms <= suppression.completed_at_ms) {
            index += 1;
            continue;
        }
        var removed = state.chat_suppressions.orderedRemove(index);
        self.allocator.free(removed.workspace_id);
        self.allocator.free(removed.local_thread_id);
        removed = undefined;
    }
}

/// Join the one owned request and release queued best-effort work during teardown.
pub fn deinit(self: anytype) void {
    const state = &self.acknowledgement_controller;
    if (state.worker) |worker| {
        worker.join();
        state.worker = null;
    }
    if (state.worker_args) |args| {
        var acknowledgement = args.acknowledgement;
        acknowledgement.deinit(args.allocator);
        args.allocator.destroy(args);
        state.worker_args = null;
    }
    for (state.pending.items) |*acknowledgement| acknowledgement.deinit(self.allocator);
    state.pending.deinit(self.allocator);
    for (state.chat_suppressions.items) |suppression| {
        self.allocator.free(suppression.workspace_id);
        self.allocator.free(suppression.local_thread_id);
    }
    state.chat_suppressions.deinit(self.allocator);
    state.* = .{};
}

fn startNext(self: anytype) void {
    const state = &self.acknowledgement_controller;
    if (state.worker != null or state.pending.items.len == 0) return;
    const ready_index = nextReadyIndex(state, platform_runtime.unixTimestampMs()) orelse return;
    const args = self.allocator.create(WorkerArgs) catch return;
    args.* = .{
        .allocator = self.allocator,
        .storage = self.storage,
        .acknowledgement = state.pending.orderedRemove(ready_index),
    };
    const worker = std.Thread.spawn(.{}, workerMain, .{args}) catch |err| {
        log.warn("failed to start completion acknowledgement worker: {s}", .{@errorName(err)});
        state.pending.insert(self.allocator, 0, args.acknowledgement) catch {
            var acknowledgement = args.acknowledgement;
            acknowledgement.deinit(self.allocator);
        };
        self.allocator.destroy(args);
        return;
    };
    state.worker_args = args;
    state.worker = worker;
}

fn workerMain(args: *WorkerArgs) void {
    defer args.done.store(true, .release);
    args.success = switch (args.acknowledgement) {
        .chat => |ack| blk: {
            _ = args.storage.clearChatCompletion(ack.workspace_id, ack.local_thread_id, ack.completed_at_ms) catch |err| {
                log.err("failed to persist chat completion acknowledgement via daemon: {s}", .{@errorName(err)});
                break :blk false;
            };
            // A missing row is already acknowledged, so `applied=false` is
            // still a successful idempotent clear.
            break :blk true;
        },
        .surface => |ack| blk: {
            _ = args.storage.clearObservedSurfaceState(ack.canonical) catch |err| {
                log.err("failed to persist surface acknowledgement via daemon: {s}", .{@errorName(err)});
                break :blk false;
            };
            break :blk true;
        },
    };
}

// Keep a user's acknowledgement hidden after a transient daemon failure and
// retry it at a paced cadence. The timestamp-guarded store mutation makes an
// old retry harmless if the same thread completes again in the meantime.
fn requeueFailedChat(self: anytype, acknowledgement: *Acknowledgement) bool {
    switch (acknowledgement.*) {
        .surface => return false,
        .chat => |*ack| {
            scheduleChatRetry(ack, platform_runtime.unixTimestampMs());
        },
    }
    self.acknowledgement_controller.pending.append(self.allocator, acknowledgement.*) catch return false;
    return true;
}

fn scheduleChatRetry(ack: *ChatAcknowledgement, now_ms: i64) void {
    ack.retry_attempts +|= 1;
    ack.retry_not_before_ms = now_ms + chatRetryDelayMs(ack.retry_attempts);
}

fn chatRetryDelayMs(attempts: u8) i64 {
    var delay_ms = CHAT_RETRY_MIN_MS;
    var remaining = attempts;
    while (remaining > 1 and delay_ms < CHAT_RETRY_MAX_MS) : (remaining -= 1) {
        delay_ms = @min(delay_ms * 2, CHAT_RETRY_MAX_MS);
    }
    return delay_ms;
}

fn nextReadyIndex(state: *const State, now_ms: i64) ?usize {
    for (state.pending.items, 0..) |acknowledgement, index| switch (acknowledgement) {
        .chat => |ack| if (ack.retry_not_before_ms <= now_ms) return index,
        .surface => return index,
    };
    return null;
}

fn restoreFailed(self: anytype, acknowledgement: Acknowledgement) void {
    switch (acknowledgement) {
        .chat => |ack| {
            for (self.project_controller.projects.items) |*project| {
                if (restoreChatInProject(project, ack)) {
                    self.markDirty();
                    return;
                }
            }
            for (self.project_controller.archived_projects.items) |*project| {
                if (restoreChatInProject(project, ack)) {
                    self.markDirty();
                    return;
                }
            }
        },
        .surface => |ack| {
            const surface = self.surfaceBySessionId(ack.canonical.session_id) orelse return;
            if (!restoreSurfaceFailed(surface, ack)) return;
            self.markDirty();
        },
    }
}

fn restoreSurfaceFailed(surface: anytype, ack: SurfaceAcknowledgement) bool {
    if (surface.presentation_generation != ack.consumed_generation) return false;
    if (surface.status != .idle or surface.completion_pending or surface.completed_at_ms != 0) return false;
    surface.status = ack.canonical.status;
    surface.completion_pending = ack.completion_pending;
    surface.completed_at_ms = ack.canonical.completed_at_ms;
    surface.attention = ack.attention;
    surface.unread_count = ack.unread_count;
    surface.presentation_generation +%= 1;
    return true;
}

fn restoreChatInProject(project: anytype, ack: ChatAcknowledgement) bool {
    if (!std.mem.eql(u8, project.id, ack.workspace_id)) return false;
    for (project.threads.items) |*thread| {
        if (!std.mem.eql(u8, thread.local_thread_id, ack.local_thread_id)) continue;
        thread.completion_pending = true;
        thread.completed_at_ms = ack.completed_at_ms;
        return true;
    }
    for (project.archived_threads.items) |*thread| {
        if (!std.mem.eql(u8, thread.local_thread_id, ack.local_thread_id)) continue;
        thread.completion_pending = true;
        thread.completed_at_ms = ack.completed_at_ms;
        return true;
    }
    return false;
}

fn containsChat(state: *const State, workspace_id: []const u8, local_thread_id: []const u8) bool {
    if (state.worker_args) |args| {
        if (args.acknowledgement.matchesChat(workspace_id, local_thread_id)) return true;
    }
    for (state.pending.items) |acknowledgement| {
        if (acknowledgement.matchesChat(workspace_id, local_thread_id)) return true;
    }
    return false;
}

fn countPendingChats(state: *const State) usize {
    var count: usize = 0;
    if (state.worker_args) |args| switch (args.acknowledgement) {
        .chat => count += 1,
        .surface => {},
    };
    for (state.pending.items) |acknowledgement| switch (acknowledgement) {
        .chat => count += 1,
        .surface => {},
    };
    return count;
}

fn matchingChatAcknowledgement(
    state: *const State,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    completed_at_ms: i64,
) bool {
    if (state.worker_args) |args| switch (args.acknowledgement) {
        .chat => |ack| if (chatAcknowledgementCovers(ack, workspace_id, local_thread_id, completed_at_ms)) return true,
        .surface => {},
    };
    for (state.pending.items) |acknowledgement| switch (acknowledgement) {
        .chat => |ack| if (chatAcknowledgementCovers(ack, workspace_id, local_thread_id, completed_at_ms)) return true,
        .surface => {},
    };
    for (state.chat_suppressions.items) |ack| {
        if (chatAcknowledgementCovers(ack, workspace_id, local_thread_id, completed_at_ms)) return true;
    }
    return false;
}

fn chatAcknowledgementCovers(
    ack: ChatAcknowledgement,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    completed_at_ms: i64,
) bool {
    return std.mem.eql(u8, ack.workspace_id, workspace_id) and
        std.mem.eql(u8, ack.local_thread_id, local_thread_id) and
        completed_at_ms <= ack.completed_at_ms;
}

fn clearSuppressedThreads(self: anytype, workspace_id: []const u8, threads: anytype) void {
    for (threads) |*thread| {
        if (!thread.completion_pending) continue;
        if (!matchingChatAcknowledgement(
            &self.acknowledgement_controller,
            workspace_id,
            thread.local_thread_id,
            thread.completed_at_ms,
        )) continue;
        thread.completion_pending = false;
        thread.completed_at_ms = 0;
    }
}

fn projectedChatCompletion(completions: anytype, workspace_id: []const u8, local_thread_id: []const u8) ?@TypeOf(completions[0]) {
    for (completions) |completion| {
        if (std.mem.eql(u8, completion.workspace_id, workspace_id) and
            std.mem.eql(u8, completion.local_thread_id, local_thread_id)) return completion;
    }
    return null;
}

test "chat acknowledgement retries stay hidden, paced, and completion-scoped" {
    const ThreadStub = struct {
        local_thread_id: []const u8,
        completion_pending: bool,
        completed_at_ms: i64,
    };
    const FakeState = struct {
        acknowledgement_controller: State = .{},
    };

    var state: FakeState = .{};
    defer {
        for (state.acknowledgement_controller.pending.items) |*acknowledgement| acknowledgement.deinit(std.testing.allocator);
        state.acknowledgement_controller.pending.deinit(std.testing.allocator);
    }
    try state.acknowledgement_controller.pending.append(std.testing.allocator, .{ .chat = .{
        .workspace_id = try std.testing.allocator.dupe(u8, "workspace-a"),
        .local_thread_id = try std.testing.allocator.dupe(u8, "thread-a"),
        .completed_at_ms = 100,
    } });

    var acknowledged = [_]ThreadStub{.{
        .local_thread_id = "thread-a",
        .completion_pending = true,
        .completed_at_ms = 100,
    }};
    clearSuppressedThreads(&state, "workspace-a", &acknowledged);
    try std.testing.expect(!acknowledged[0].completion_pending);

    var newer = [_]ThreadStub{.{
        .local_thread_id = "thread-a",
        .completion_pending = true,
        .completed_at_ms = 101,
    }};
    clearSuppressedThreads(&state, "workspace-a", &newer);
    try std.testing.expect(newer[0].completion_pending);

    const pending = &state.acknowledgement_controller.pending.items[0].chat;
    scheduleChatRetry(pending, 1_000);
    try std.testing.expectEqual(@as(u8, 1), pending.retry_attempts);
    try std.testing.expectEqual(@as(i64, 2_000), pending.retry_not_before_ms);
    try std.testing.expect(nextReadyIndex(&state.acknowledgement_controller, 1_999) == null);
    try std.testing.expectEqual(@as(?usize, 0), nextReadyIndex(&state.acknowledgement_controller, 2_000));

    scheduleChatRetry(pending, 2_000);
    try std.testing.expectEqual(@as(i64, 4_000), pending.retry_not_before_ms);
    try std.testing.expectEqual(CHAT_RETRY_MAX_MS, chatRetryDelayMs(20));
}

test "surface acknowledgement queue coalesces exact identity but orders same-session replacement" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer {
        for (state.pending.items) |*acknowledgement| acknowledgement.deinit(allocator);
        state.pending.deinit(allocator);
    }
    try state.pending.append(allocator, .{ .chat = .{
        .workspace_id = try allocator.dupe(u8, "workspace-a"),
        .local_thread_id = try allocator.dupe(u8, "thread-a"),
        .completed_at_ms = 1,
    } });
    try std.testing.expect(containsChat(&state, "workspace-a", "thread-a"));
    try std.testing.expect(!containsChat(&state, "workspace-a", "thread-b"));
    var original: surface_controller.SurfaceState = .{
        .session_id = @constCast("session-a"),
        .workspace_id = @constCast("workspace-a"),
        .workspace_path = @constCast("/workspace-a"),
        .title = @constCast("old title"),
        .status = .done,
        .status_changed_at_ms = 90,
        .completed_at_ms = 100,
        .last_event_body = @constCast("old body"),
    };
    const original_canonical = surface_controller.persistedSurfaceState(&original);
    try std.testing.expect(!containsSurfaceCompletionState(&state, original_canonical));
    try std.testing.expect(enqueueSurface(&state, allocator, &original));
    try std.testing.expect(enqueueSurface(&state, allocator, &original));
    try std.testing.expectEqual(@as(usize, 2), state.pending.items.len);
    try std.testing.expect(containsSurfaceCompletionState(&state, original_canonical));
    const old = state.pending.items[1].surface.canonical;
    try std.testing.expect(state.pending.items[1].matchesSurfaceCompletion(old));
    original.status_changed_at_ms = 91;
    original.title = @constCast("new title");
    original.last_event_body = @constCast("new body");
    const newer = surface_controller.persistedSurfaceState(&original);
    try std.testing.expect(!containsSurfaceCompletionState(&state, newer));
    try std.testing.expect(enqueueSurface(&state, allocator, &original));
    try std.testing.expectEqual(@as(usize, 3), state.pending.items.len);
    try std.testing.expect(state.pending.items[1].matchesSurfaceCompletion(old));
    try std.testing.expect(state.pending.items[2].matchesSurfaceCompletion(newer));
}

test "surface failure restoration is conditional on the consumed presentation generation" {
    const SurfaceState = @import("surface_controller.zig").SurfaceState;
    const ack: SurfaceAcknowledgement = .{
        .canonical = .{ .session_id = "session-a", .status = .done, .status_changed_at_ms = 90, .completed_at_ms = 100 },
        .attention = true,
        .unread_count = 2,
        .consumed_generation = 8,
    };
    var consumed: SurfaceState = .{ .session_id = @constCast("session-a"), .presentation_generation = 8 };
    try std.testing.expect(restoreSurfaceFailed(&consumed, ack));
    try std.testing.expectEqual(@import("../db/types.zig").SurfaceStatus.done, consumed.status);
    try std.testing.expectEqual(@as(i64, 100), consumed.completed_at_ms);

    inline for (.{
        SurfaceState{ .session_id = @constCast("session-a"), .status = .done, .completion_pending = true, .completed_at_ms = 200, .presentation_generation = 9 },
        SurfaceState{ .session_id = @constCast("session-a"), .status = .working, .presentation_generation = 9 },
        SurfaceState{ .session_id = @constCast("session-a"), .presentation_generation = 9 },
    }) |initial| {
        var newer = initial;
        try std.testing.expect(!restoreSurfaceFailed(&newer, ack));
        try std.testing.expectEqual(initial.status, newer.status);
        try std.testing.expectEqual(initial.completed_at_ms, newer.completed_at_ms);
    }
}
