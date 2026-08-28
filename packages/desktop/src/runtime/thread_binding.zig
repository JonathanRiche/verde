//! Immutable runtime and repository routing for one chat thread.

const std = @import("std");

pub const MAX_ROUTE_ID_BYTES: usize = 128;
pub const MAX_RELATIVE_CWD_BYTES: usize = 4 * 1024;
pub const RUNTIME_ID_BYTES: usize = 16;
pub const LOCAL_PROFILE_ID = "local";

/// Borrowed route selected for a not-yet-started thread.
pub const Selection = struct {
    profile_id: []const u8,
    repository_id: []const u8,
    relative_cwd: ?[]const u8 = null,
};

/// Borrowed immutable route after the selected runtime has accepted durable
/// work for the thread.
pub const Pinned = struct {
    profile_id: []const u8,
    /// Null only for a migrated/local thread whose first durable action
    /// predates runtime identity persistence. The next verified handshake may
    /// fill it, but the selected route is already immutable.
    runtime_id: ?[]const u8,
    repository_id: []const u8,
    relative_cwd: ?[]const u8 = null,
};

pub const SelectResult = enum {
    unchanged,
    updated,
    new_thread_required,
};

const OwnedSelection = struct {
    profile_id: []u8,
    repository_id: []u8,
    relative_cwd: ?[]u8,

    fn init(allocator: std.mem.Allocator, selection: Selection) !OwnedSelection {
        try validateSelection(selection);
        const profile_id = try allocator.dupe(u8, selection.profile_id);
        errdefer allocator.free(profile_id);
        const repository_id = try allocator.dupe(u8, selection.repository_id);
        errdefer allocator.free(repository_id);
        const relative_cwd = if (selection.relative_cwd) |cwd|
            try allocator.dupe(u8, cwd)
        else
            null;
        return .{
            .profile_id = profile_id,
            .repository_id = repository_id,
            .relative_cwd = relative_cwd,
        };
    }

    fn deinit(self: *OwnedSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_id);
        allocator.free(self.repository_id);
        if (self.relative_cwd) |cwd| allocator.free(cwd);
        self.* = undefined;
    }

    fn borrow(self: *const OwnedSelection) Selection {
        return .{
            .profile_id = self.profile_id,
            .repository_id = self.repository_id,
            .relative_cwd = self.relative_cwd,
        };
    }
};

const OwnedPinned = struct {
    selection: OwnedSelection,
    runtime_id: ?[]u8,

    fn deinit(self: *OwnedPinned, allocator: std.mem.Allocator) void {
        self.selection.deinit(allocator);
        if (self.runtime_id) |runtime_id| allocator.free(runtime_id);
        self.* = undefined;
    }

    fn borrow(self: *const OwnedPinned) Pinned {
        const selection = self.selection.borrow();
        return .{
            .profile_id = selection.profile_id,
            .runtime_id = self.runtime_id,
            .repository_id = selection.repository_id,
            .relative_cwd = selection.relative_cwd,
        };
    }
};

/// A draft route may be replaced freely. Once pinned, the route is immutable;
/// a different picker choice tells the caller to create a new thread instead.
pub const ThreadBinding = union(enum) {
    draft: OwnedSelection,
    pinned: OwnedPinned,

    pub fn initDraft(allocator: std.mem.Allocator, selection: Selection) !ThreadBinding {
        return .{ .draft = try OwnedSelection.init(allocator, selection) };
    }

    /// Restore a persisted route. `locked` is normally the thread's durable
    /// committed bit; a stored runtime identity also implies a locked route.
    /// This preserves the immutability of legacy committed threads even when
    /// they were written before runtime IDs existed.
    pub fn initPersisted(
        allocator: std.mem.Allocator,
        selection: Selection,
        locked: bool,
        runtime_id: ?[]const u8,
    ) !ThreadBinding {
        if (locked and runtime_id == null and
            !std.mem.eql(u8, selection.profile_id, LOCAL_PROFILE_ID))
        {
            return error.MissingRuntimeIdentity;
        }
        var binding = try initDraft(allocator, selection);
        errdefer binding.deinit(allocator);
        if (locked or runtime_id != null) binding.lock();
        if (runtime_id) |identity| try binding.pin(allocator, identity);
        return binding;
    }

    pub fn deinit(self: *ThreadBinding, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .draft => |*draft| draft.deinit(allocator),
            .pinned => |*pinned| pinned.deinit(allocator),
        }
        self.* = undefined;
    }

    /// Apply a picker choice without ever modifying a pinned route.
    pub fn select(
        self: *ThreadBinding,
        allocator: std.mem.Allocator,
        selection: Selection,
    ) !SelectResult {
        try validateSelection(selection);
        switch (self.*) {
            .draft => |*draft| {
                if (selectionEql(draft.borrow(), selection)) return .unchanged;
                const replacement = try OwnedSelection.init(allocator, selection);
                draft.deinit(allocator);
                self.* = .{ .draft = replacement };
                return .updated;
            },
            .pinned => |*pinned| {
                return if (selectionEql(pinned.selection.borrow(), selection))
                    .unchanged
                else
                    .new_thread_required;
            },
        }
    }

    /// Lock the selected route without inventing a runtime identity. This is
    /// the migration path for durable threads created before handshakes were
    /// persisted; it is also useful at the exact durable-acceptance boundary.
    pub fn lock(self: *ThreadBinding) void {
        switch (self.*) {
            .draft => |draft| self.* = .{ .pinned = .{
                .selection = draft,
                .runtime_id = null,
            } },
            .pinned => {},
        }
    }

    /// Pin the selected route to the stable identity returned by the runtime
    /// handshake. Repeating the same pin is idempotent; a different identity
    /// is an explicit mismatch rather than a silent move.
    pub fn pin(self: *ThreadBinding, allocator: std.mem.Allocator, runtime_id: []const u8) !void {
        try validateRuntimeId(runtime_id);
        switch (self.*) {
            .draft => |draft| {
                const owned_runtime_id = try allocator.dupe(u8, runtime_id);
                self.* = .{ .pinned = .{
                    .selection = draft,
                    .runtime_id = owned_runtime_id,
                } };
            },
            .pinned => |pinned| {
                if (pinned.runtime_id == null) {
                    self.pinned.runtime_id = try allocator.dupe(u8, runtime_id);
                } else if (!std.mem.eql(u8, pinned.runtime_id.?, runtime_id)) {
                    return error.RuntimeIdentityMismatch;
                }
            },
        }
    }

    pub fn selectedRoute(self: *const ThreadBinding) Selection {
        return switch (self.*) {
            .draft => |*draft| draft.borrow(),
            .pinned => |*pinned| pinned.selection.borrow(),
        };
    }

    pub fn pinnedRoute(self: *const ThreadBinding) ?Pinned {
        return switch (self.*) {
            .draft => null,
            .pinned => |*value| value.borrow(),
        };
    }
};

fn selectionEql(left: Selection, right: Selection) bool {
    return std.mem.eql(u8, left.profile_id, right.profile_id) and
        std.mem.eql(u8, left.repository_id, right.repository_id) and
        optionalEql(left.relative_cwd, right.relative_cwd);
}

fn optionalEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// Validate a borrowed persisted or draft route without taking ownership.
pub fn validateSelection(selection: Selection) !void {
    try validateRouteId(selection.profile_id, error.InvalidProfileId);
    try validateRouteId(selection.repository_id, error.InvalidRepositoryId);
    if (selection.relative_cwd) |cwd| try validateRelativeCwd(cwd);
}

fn validateRouteId(value: []const u8, invalid: anyerror) !void {
    if (value.len == 0 or value.len > MAX_ROUTE_ID_BYTES) return invalid;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') {
            return invalid;
        }
    }
}

/// Validate the stable lowercase-hex identity returned by a runtime handshake.
pub fn validateRuntimeId(value: []const u8) !void {
    if (value.len != RUNTIME_ID_BYTES * 2) return error.InvalidRuntimeId;
    for (value) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidRuntimeId;
    }
}

fn validateRelativeCwd(value: []const u8) !void {
    if (value.len == 0 or value.len > MAX_RELATIVE_CWD_BYTES or
        value[0] == '/' or !std.unicode.utf8ValidateSlice(value))
    {
        return error.InvalidRelativeCwd;
    }
    for (value) |byte| {
        if (byte == '\\' or byte == ':' or std.ascii.isControl(byte)) {
            return error.InvalidRelativeCwd;
        }
    }
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or
            std.mem.eql(u8, segment, ".."))
        {
            return error.InvalidRelativeCwd;
        }
    }
}

test "draft route changes but the first durable action pins it" {
    const allocator = std.testing.allocator;
    const runtime_id = "0123456789abcdef0123456789abcdef";
    var binding = try ThreadBinding.initDraft(allocator, .{
        .profile_id = "local",
        .repository_id = "primary",
    });
    defer binding.deinit(allocator);

    try std.testing.expectEqual(SelectResult.updated, try binding.select(allocator, .{
        .profile_id = "profile-0123456789abcdef0123456789abcdef",
        .repository_id = "repo-api",
        .relative_cwd = "services/api",
    }));
    try binding.pin(allocator, runtime_id);
    try std.testing.expectEqualStrings(runtime_id, binding.pinnedRoute().?.runtime_id.?);

    try std.testing.expectEqual(SelectResult.unchanged, try binding.select(allocator, .{
        .profile_id = "profile-0123456789abcdef0123456789abcdef",
        .repository_id = "repo-api",
        .relative_cwd = "services/api",
    }));
    try std.testing.expectEqual(SelectResult.new_thread_required, try binding.select(allocator, .{
        .profile_id = "local",
        .repository_id = "primary",
    }));
    try std.testing.expectEqualStrings(runtime_id, binding.pinnedRoute().?.runtime_id.?);
}

test "runtime pin is idempotent and rejects identity drift" {
    const allocator = std.testing.allocator;
    var binding = try ThreadBinding.initDraft(allocator, .{
        .profile_id = "local",
        .repository_id = "primary",
    });
    defer binding.deinit(allocator);

    try binding.pin(allocator, "0123456789abcdef0123456789abcdef");
    try binding.pin(allocator, "0123456789abcdef0123456789abcdef");
    try std.testing.expectError(
        error.RuntimeIdentityMismatch,
        binding.pin(allocator, "fedcba9876543210fedcba9876543210"),
    );
}

test "migrated committed route stays immutable before runtime identity is known" {
    const allocator = std.testing.allocator;
    var binding = try ThreadBinding.initPersisted(allocator, .{
        .profile_id = "local",
        .repository_id = "primary",
    }, true, null);
    defer binding.deinit(allocator);

    try std.testing.expect(binding.pinnedRoute().?.runtime_id == null);
    try std.testing.expectEqual(SelectResult.new_thread_required, try binding.select(allocator, .{
        .profile_id = "remote-one",
        .repository_id = "primary",
    }));
    try binding.pin(allocator, "0123456789abcdef0123456789abcdef");
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef",
        binding.pinnedRoute().?.runtime_id.?,
    );
}

test "committed non-local persisted route requires runtime identity" {
    try std.testing.expectError(error.MissingRuntimeIdentity, ThreadBinding.initPersisted(
        std.testing.allocator,
        .{ .profile_id = "remote-box", .repository_id = "primary" },
        true,
        null,
    ));
    var draft = try ThreadBinding.initPersisted(
        std.testing.allocator,
        .{ .profile_id = "remote-box", .repository_id = "primary" },
        false,
        null,
    );
    defer draft.deinit(std.testing.allocator);
    try std.testing.expect(draft.pinnedRoute() == null);
}

test "route validation rejects ambiguous paths and identifiers" {
    try std.testing.expectError(error.InvalidProfileId, ThreadBinding.initDraft(
        std.testing.allocator,
        .{ .profile_id = "profile/one", .repository_id = "primary" },
    ));
    try std.testing.expectError(error.InvalidRelativeCwd, ThreadBinding.initDraft(
        std.testing.allocator,
        .{ .profile_id = "local", .repository_id = "primary", .relative_cwd = "../secret" },
    ));
    try std.testing.expectError(error.InvalidRelativeCwd, ThreadBinding.initDraft(
        std.testing.allocator,
        .{ .profile_id = "local", .repository_id = "primary", .relative_cwd = "/absolute" },
    ));
}

fn checkBindingAllocationFailure(allocator: std.mem.Allocator) !void {
    var binding = try ThreadBinding.initDraft(allocator, .{
        .profile_id = "local",
        .repository_id = "primary",
    });
    defer binding.deinit(allocator);
    _ = try binding.select(allocator, .{
        .profile_id = "profile-0123456789abcdef0123456789abcdef",
        .repository_id = "repo-api",
        .relative_cwd = "services/api",
    });
    try binding.pin(allocator, "0123456789abcdef0123456789abcdef");
}

test "thread binding cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkBindingAllocationFailure, .{});
}
