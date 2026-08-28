//! Runtime-qualified identity keys shared by detached clients.

const std = @import("std");

/// Borrowed identity for one daemon-owned thread.
///
/// `local_thread_id` is unique only within its workspace, and a workspace ID
/// is meaningful only within its runtime. Callers that retain this view must
/// first copy it into `OwnedRuntimeThreadId`.
pub const BorrowedRuntimeThreadId = struct {
    runtime_id: []const u8,
    workspace_id: []const u8,
    local_thread_id: []const u8,

    /// Copy every identity component into caller-owned storage.
    pub fn toOwned(self: BorrowedRuntimeThreadId, allocator: std.mem.Allocator) !OwnedRuntimeThreadId {
        return OwnedRuntimeThreadId.init(allocator, self);
    }

    /// Compare the complete runtime/workspace/thread identity.
    pub fn eql(self: BorrowedRuntimeThreadId, other: BorrowedRuntimeThreadId) bool {
        return std.mem.eql(u8, self.runtime_id, other.runtime_id) and
            std.mem.eql(u8, self.workspace_id, other.workspace_id) and
            std.mem.eql(u8, self.local_thread_id, other.local_thread_id);
    }
};

/// Compatibility name for the borrowed runtime-qualified thread identity.
pub const RuntimeThreadId = BorrowedRuntimeThreadId;

/// Allocator-owned runtime-qualified thread identity for persisted routes and
/// other state that outlives a decoded response or connection buffer.
pub const OwnedRuntimeThreadId = struct {
    runtime_id: []u8,
    workspace_id: []u8,
    local_thread_id: []u8,

    /// Duplicate a borrowed identity with independent storage.
    pub fn init(allocator: std.mem.Allocator, source: BorrowedRuntimeThreadId) !OwnedRuntimeThreadId {
        const runtime_id = try allocator.dupe(u8, source.runtime_id);
        errdefer allocator.free(runtime_id);
        const workspace_id = try allocator.dupe(u8, source.workspace_id);
        errdefer allocator.free(workspace_id);
        const local_thread_id = try allocator.dupe(u8, source.local_thread_id);
        return .{
            .runtime_id = runtime_id,
            .workspace_id = workspace_id,
            .local_thread_id = local_thread_id,
        };
    }

    pub fn deinit(self: *OwnedRuntimeThreadId, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_id);
        allocator.free(self.workspace_id);
        allocator.free(self.local_thread_id);
        self.* = undefined;
    }

    /// Return a view valid only while this owned identity remains alive and
    /// unmodified.
    pub fn borrow(self: *const OwnedRuntimeThreadId) BorrowedRuntimeThreadId {
        return .{
            .runtime_id = self.runtime_id,
            .workspace_id = self.workspace_id,
            .local_thread_id = self.local_thread_id,
        };
    }

    /// Duplicate this identity with independent storage.
    pub fn clone(self: *const OwnedRuntimeThreadId, allocator: std.mem.Allocator) !OwnedRuntimeThreadId {
        return init(allocator, self.borrow());
    }
};

test "runtime thread identity includes runtime and workspace scope" {
    const thread: BorrowedRuntimeThreadId = .{
        .runtime_id = "runtime-a",
        .workspace_id = "workspace-a",
        .local_thread_id = "thread-1",
    };

    try std.testing.expect(thread.eql(.{
        .runtime_id = "runtime-a",
        .workspace_id = "workspace-a",
        .local_thread_id = "thread-1",
    }));
    try std.testing.expect(!thread.eql(.{
        .runtime_id = "runtime-a",
        .workspace_id = "workspace-b",
        .local_thread_id = "thread-1",
    }));
    try std.testing.expect(!thread.eql(.{
        .runtime_id = "runtime-b",
        .workspace_id = "workspace-a",
        .local_thread_id = "thread-1",
    }));
}

test "owned runtime thread identity has independent storage" {
    const allocator = std.testing.allocator;
    var runtime_id = [_]u8{ 'r', '1' };
    var workspace_id = [_]u8{ 'w', '1' };
    var local_thread_id = [_]u8{ 't', '1' };

    var owned = try (BorrowedRuntimeThreadId{
        .runtime_id = &runtime_id,
        .workspace_id = &workspace_id,
        .local_thread_id = &local_thread_id,
    }).toOwned(allocator);
    defer owned.deinit(allocator);

    runtime_id[0] = 'x';
    workspace_id[0] = 'y';
    local_thread_id[0] = 'z';

    const borrowed = owned.borrow();
    try std.testing.expectEqualStrings("r1", borrowed.runtime_id);
    try std.testing.expectEqualStrings("w1", borrowed.workspace_id);
    try std.testing.expectEqualStrings("t1", borrowed.local_thread_id);

    var duplicate = try owned.clone(allocator);
    defer duplicate.deinit(allocator);
    owned.local_thread_id[0] = 'q';
    try std.testing.expectEqualStrings("t1", duplicate.local_thread_id);
}

fn checkOwnedAllocationFailure(allocator: std.mem.Allocator) !void {
    var owned = try OwnedRuntimeThreadId.init(allocator, .{
        .runtime_id = "runtime-a",
        .workspace_id = "workspace-a",
        .local_thread_id = "thread-a",
    });
    defer owned.deinit(allocator);
}

test "owned runtime thread identity cleans up partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOwnedAllocationFailure, .{});
}
