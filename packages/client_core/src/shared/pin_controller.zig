//! Pure first-contact identity data and persistence decisions.

const std = @import("std");
const profile = @import("profile.zig");

/// Owned first-contact identity proposal. Controllers persist under the
/// profile-store lock, reread the authoritative pair, then acknowledge this
/// exact generation. No borrowed manager state crosses that transaction.
pub const RuntimePinProposal = struct {
    allocator: std.mem.Allocator,
    profile_id: []u8,
    generation: u64,
    runtime_id: []u8,
    instance_id: []u8,

    pub fn deinit(self: *RuntimePinProposal) void {
        self.allocator.free(self.profile_id);
        self.allocator.free(self.runtime_id);
        self.allocator.free(self.instance_id);
        self.* = undefined;
    }
};

pub const PersistedIdentity = struct {
    runtime_id: []const u8,
    instance_id: []const u8,
};

pub const PinAdoption = enum {
    committed_current,
    reconnect_required,
    installed_disabled,
};

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

    pub fn borrowed(self: *const PersistedPin) PersistedIdentity {
        return .{
            .runtime_id = self.runtime_id,
            .instance_id = self.instance_id,
        };
    }
};

pub const CommitResult = struct {
    adoption: PinAdoption,
    wrote_profile: bool,
    recovered_after_save_error: bool,
};

pub fn shouldPersistProposal(
    configured: *const profile.Profile,
    proposal: *const RuntimePinProposal,
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

test "first-contact decision preserves complete pins and upgrades only matching legacy pins" {
    const allocator = std.testing.allocator;
    var configured = try profile.decodeAlloc(allocator,
        \\{"version":1,"profiles":[{"id":"profile-0123456789abcdef0123456789abcdef","label":"VM","transport":{"kind":"ssh_tunnel","host":"vm"}}]}
    );
    defer configured.deinit(allocator);
    const runtime_id = "0123456789abcdef0123456789abcdef";
    const instance_id = "00112233445566778899aabbccddeeff";
    var proposal: RuntimePinProposal = .{
        .allocator = allocator,
        .profile_id = try allocator.dupe(u8, configured.items[0].id),
        .generation = 1,
        .runtime_id = try allocator.dupe(u8, runtime_id),
        .instance_id = try allocator.dupe(u8, instance_id),
    };
    defer proposal.deinit();
    const current = &configured.items[0];
    try std.testing.expect(try shouldPersistProposal(current, &proposal));
    try current.setExpectedIdentity(allocator, runtime_id, null);
    try std.testing.expect(try shouldPersistProposal(current, &proposal));
    try current.setExpectedIdentity(allocator, "fedcba9876543210fedcba9876543210", null);
    try std.testing.expectError(error.RuntimeIdentityPinConflict, shouldPersistProposal(current, &proposal));
    try current.setExpectedIdentity(allocator, "fedcba9876543210fedcba9876543210", instance_id);
    try std.testing.expect(!try shouldPersistProposal(current, &proposal));
    allocator.free(current.expected_runtime_id.?);
    current.expected_runtime_id = null;
    try std.testing.expectError(error.InvalidExpectedIdentityPair, shouldPersistProposal(current, &proposal));
}
