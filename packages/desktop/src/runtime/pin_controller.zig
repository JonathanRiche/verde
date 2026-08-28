//! Durable first-contact identity transactions for desktop runtime profiles.

const std = @import("std");
const manager_mod = @import("manager.zig");
const profile = @import("profile.zig");
const profile_store = @import("profile_store.zig");

/// The authoritative complete identity reread while the profile lock was
/// held. Both strings are owned so no profile-store borrow crosses the lock.
pub const PersistedPin = struct {
    allocator: std.mem.Allocator,
    runtime_id: []u8,
    instance_id: []u8,
    wrote_profile: bool,
    recovered_after_save_error: bool,

    pub fn deinit(self: *PersistedPin) void {
        self.allocator.free(self.runtime_id);
        self.allocator.free(self.instance_id);
        self.* = undefined;
    }

    pub fn borrowed(self: *const PersistedPin) manager_mod.PersistedIdentity {
        return .{
            .runtime_id = self.runtime_id,
            .instance_id = self.instance_id,
        };
    }
};

pub const CommitResult = struct {
    adoption: manager_mod.PinAdoption,
    wrote_profile: bool,
    recovered_after_save_error: bool,
};

/// Persists a first-contact proposal under one cross-process transaction and
/// returns only the complete pair reread from disk. A complete pair already
/// on disk always wins, including when another writer committed it first.
pub fn persistProposalAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    proposal: *const manager_mod.RuntimePinProposal,
) !PersistedPin {
    var lock = try profile_store.acquireExclusiveAtPath(allocator, io, path);
    defer lock.deinit();

    var loaded = try profile_store.loadAtPath(allocator, io, path);
    defer loaded.deinit(allocator);
    const configured = findProfile(loaded.items, proposal.profile_id) orelse
        return error.UnknownRuntimeProfile;

    const wrote_profile = try shouldPersistProposal(configured, proposal);
    var save_error: ?anyerror = null;
    if (wrote_profile) {
        try configured.setExpectedIdentity(
            allocator,
            proposal.runtime_id,
            proposal.instance_id,
        );
        profile_store.saveAtPath(allocator, io, path, loaded.items) catch |err| {
            // Rename may have succeeded before directory sync reported an
            // error. Only a fresh read can decide whether execution is safe.
            save_error = err;
        };
    }

    var authoritative = profile_store.loadAtPath(allocator, io, path) catch {
        if (save_error != null) return error.RuntimeIdentityPinPersistenceAmbiguous;
        return error.RuntimeIdentityPinRereadFailed;
    };
    defer authoritative.deinit(allocator);
    const persisted_profile = findProfile(authoritative.items, proposal.profile_id) orelse {
        if (save_error) |err| return err;
        return error.UnknownRuntimeProfile;
    };
    const persisted_runtime_id = persisted_profile.expected_runtime_id orelse {
        if (save_error) |err| return err;
        return error.RuntimeIdentityPinNotPersisted;
    };
    const persisted_instance_id = persisted_profile.expected_instance_id orelse {
        if (save_error) |err| return err;
        return error.RuntimeIdentityPinNotPersisted;
    };

    const runtime_id = try allocator.dupe(u8, persisted_runtime_id);
    errdefer allocator.free(runtime_id);
    const instance_id = try allocator.dupe(u8, persisted_instance_id);
    return .{
        .allocator = allocator,
        .runtime_id = runtime_id,
        .instance_id = instance_id,
        .wrote_profile = wrote_profile,
        .recovered_after_save_error = save_error != null,
    };
}

/// Completes the durable transaction before mutating manager state. The
/// manager decides whether the proposal is still current or must reconnect to
/// a different complete pair that won on disk.
pub fn commitProposalAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    runtime_manager: *manager_mod.Manager,
    proposal: *const manager_mod.RuntimePinProposal,
) !CommitResult {
    var persisted = try persistProposalAtPath(allocator, io, path, proposal);
    defer persisted.deinit();
    return .{
        .adoption = try runtime_manager.acknowledgePersistedRuntimePin(
            proposal,
            persisted.borrowed(),
        ),
        .wrote_profile = persisted.wrote_profile,
        .recovered_after_save_error = persisted.recovered_after_save_error,
    };
}

fn findProfile(profiles: []profile.Profile, profile_id: []const u8) ?*profile.Profile {
    for (profiles) |*configured| {
        if (std.mem.eql(u8, configured.id, profile_id)) return configured;
    }
    return null;
}

fn shouldPersistProposal(
    configured: *const profile.Profile,
    proposal: *const manager_mod.RuntimePinProposal,
) !bool {
    if (configured.expected_runtime_id) |runtime_id| {
        if (configured.expected_instance_id != null) return false;
        if (!std.mem.eql(u8, runtime_id, proposal.runtime_id)) {
            return error.RuntimeIdentityPinConflict;
        }
        return true;
    }
    if (configured.expected_instance_id != null) return error.InvalidExpectedIdentityPair;
    return true;
}

fn testPathAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute_len = try dir.realPath(std.testing.io, &absolute_buffer);
    return std.fs.path.join(allocator, &.{
        absolute_buffer[0..absolute_len],
        profile_store.FILE_NAME,
    });
}

fn testProposal(
    allocator: std.mem.Allocator,
    profile_id: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
) !manager_mod.RuntimePinProposal {
    const owned_profile_id = try allocator.dupe(u8, profile_id);
    errdefer allocator.free(owned_profile_id);
    const owned_runtime_id = try allocator.dupe(u8, runtime_id);
    errdefer allocator.free(owned_runtime_id);
    const owned_instance_id = try allocator.dupe(u8, instance_id);
    return .{
        .allocator = allocator,
        .profile_id = owned_profile_id,
        .generation = 1,
        .runtime_id = owned_runtime_id,
        .instance_id = owned_instance_id,
    };
}

test "first-contact proposal is saved and reread as a complete pair" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var remote = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Build VM",
        null,
        .{ .host = "devbox" },
    );
    defer remote.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{remote});

    var proposal = try testProposal(
        allocator,
        remote.id,
        "0123456789abcdef0123456789abcdef",
        "00112233445566778899aabbccddeeff",
    );
    defer proposal.deinit();
    var persisted = try persistProposalAtPath(
        allocator,
        std.testing.io,
        path,
        &proposal,
    );
    defer persisted.deinit();

    try std.testing.expect(persisted.wrote_profile);
    try std.testing.expect(!persisted.recovered_after_save_error);
    try std.testing.expectEqualStrings(proposal.runtime_id, persisted.runtime_id);
    try std.testing.expectEqualStrings(proposal.instance_id, persisted.instance_id);

    var reloaded = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer reloaded.deinit(allocator);
    try std.testing.expectEqualStrings(
        proposal.instance_id,
        reloaded.items[0].expected_instance_id.?,
    );
}

test "complete disk identity wins without being overwritten" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var remote = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Build VM",
        null,
        .{ .host = "devbox" },
    );
    defer remote.deinit(allocator);
    try remote.setExpectedIdentity(
        allocator,
        "fedcba9876543210fedcba9876543210",
        "ffeeddccbbaa99887766554433221100",
    );
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{remote});

    var proposal = try testProposal(
        allocator,
        remote.id,
        "0123456789abcdef0123456789abcdef",
        "00112233445566778899aabbccddeeff",
    );
    defer proposal.deinit();
    var persisted = try persistProposalAtPath(
        allocator,
        std.testing.io,
        path,
        &proposal,
    );
    defer persisted.deinit();

    try std.testing.expect(!persisted.wrote_profile);
    try std.testing.expectEqualStrings(
        "fedcba9876543210fedcba9876543210",
        persisted.runtime_id,
    );
    try std.testing.expectEqualStrings(
        "ffeeddccbbaa99887766554433221100",
        persisted.instance_id,
    );
}

test "matching legacy runtime-only pin upgrades but conflicting pin stays pending" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPathAlloc(allocator, tmp.dir);
    defer allocator.free(path);

    var remote = try profile.Profile.createSshTunnel(
        allocator,
        std.testing.io,
        "Build VM",
        "0123456789abcdef0123456789abcdef",
        .{ .host = "devbox" },
    );
    defer remote.deinit(allocator);
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{remote});

    var matching = try testProposal(
        allocator,
        remote.id,
        "0123456789abcdef0123456789abcdef",
        "00112233445566778899aabbccddeeff",
    );
    defer matching.deinit();
    var upgraded = try persistProposalAtPath(
        allocator,
        std.testing.io,
        path,
        &matching,
    );
    defer upgraded.deinit();
    try std.testing.expect(upgraded.wrote_profile);

    try remote.setExpectedIdentity(
        allocator,
        "fedcba9876543210fedcba9876543210",
        null,
    );
    try profile_store.saveAtPath(allocator, std.testing.io, path, &.{remote});
    try std.testing.expectError(
        error.RuntimeIdentityPinConflict,
        persistProposalAtPath(allocator, std.testing.io, path, &matching),
    );

    var reloaded = try profile_store.loadAtPath(allocator, std.testing.io, path);
    defer reloaded.deinit(allocator);
    try std.testing.expectEqualStrings(
        "fedcba9876543210fedcba9876543210",
        reloaded.items[0].expected_runtime_id.?,
    );
    try std.testing.expect(reloaded.items[0].expected_instance_id == null);
}
