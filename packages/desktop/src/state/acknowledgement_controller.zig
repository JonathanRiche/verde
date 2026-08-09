//! Off-thread persistence for focus-driven completion acknowledgements.

const std = @import("std");

const storage_mod = @import("storage.zig");

const Storage = storage_mod.Storage;
const log = std.log.scoped(.native_shell);

const ChatAcknowledgement = struct {
    workspace_id: []u8,
    local_thread_id: []u8,
    completed_at_ms: i64,
};

const SurfaceAcknowledgement = struct {
    session_id: []u8,
    status: @import("../db/types.zig").SurfaceStatus,
    completed_at_ms: i64,
    attention: bool,
    unread_count: u32,
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
            .surface => |ack| allocator.free(ack.session_id),
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

    fn matchesSurface(self: Acknowledgement, session_id: []const u8) bool {
        return switch (self) {
            .chat => false,
            .surface => |ack| std.mem.eql(u8, ack.session_id, session_id),
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
    worker: ?std.Thread = null,
    worker_args: ?*WorkerArgs = null,
};

/// Queue a chat completion clear without waiting for the daemon on the UI thread.
pub fn queueChat(
    self: anytype,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    completed_at_ms: i64,
) bool {
    const state = &self.acknowledgement_controller;
    if (containsChat(state, workspace_id, local_thread_id)) return true;
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
    if (containsSurface(state, surface.session_id)) return true;
    const owned_session_id = self.allocator.dupe(u8, surface.session_id) catch return false;
    state.pending.append(self.allocator, .{ .surface = .{
        .session_id = owned_session_id,
        .status = surface.status,
        .completed_at_ms = surface.completed_at_ms,
        .attention = surface.attention,
        .unread_count = surface.unread_count,
    } }) catch {
        self.allocator.free(owned_session_id);
        return false;
    };
    startNext(self);
    return true;
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
    if (!args.success) restoreFailed(self, args.acknowledgement);
    var acknowledgement = args.acknowledgement;
    acknowledgement.deinit(args.allocator);
    args.allocator.destroy(args);
    startNext(self);
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
    state.* = .{};
}

fn startNext(self: anytype) void {
    const state = &self.acknowledgement_controller;
    if (state.worker != null or state.pending.items.len == 0) return;
    const args = self.allocator.create(WorkerArgs) catch return;
    args.* = .{
        .allocator = self.allocator,
        .storage = self.storage,
        .acknowledgement = state.pending.orderedRemove(0),
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
            _ = args.storage.clearChatCompletion(ack.workspace_id, ack.local_thread_id) catch |err| {
                log.err("failed to persist chat completion acknowledgement via daemon: {s}", .{@errorName(err)});
                break :blk false;
            };
            // A missing row is already acknowledged, so `applied=false` is
            // still a successful idempotent clear.
            break :blk true;
        },
        .surface => |ack| blk: {
            _ = args.storage.clearSurfaceState(ack.session_id) catch |err| {
                log.err("failed to persist surface acknowledgement via daemon: {s}", .{@errorName(err)});
                break :blk false;
            };
            break :blk true;
        },
    };
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
            const surface = self.surfaceBySessionId(ack.session_id) orelse return;
            surface.status = ack.status;
            surface.completion_pending = true;
            surface.completed_at_ms = ack.completed_at_ms;
            surface.attention = ack.attention;
            surface.unread_count = ack.unread_count;
            self.markDirty();
        },
    }
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

fn containsSurface(state: *const State, session_id: []const u8) bool {
    if (state.worker_args) |args| {
        if (args.acknowledgement.matchesSurface(session_id)) return true;
    }
    for (state.pending.items) |acknowledgement| {
        if (acknowledgement.matchesSurface(session_id)) return true;
    }
    return false;
}

test "pending acknowledgement matching is identity-specific" {
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
    try std.testing.expect(!containsSurface(&state, "session-a"));
}
