//! Ephemeral bearer tokens for configured runtime connections.

const std = @import("std");

pub const MIN_TOKEN_BYTES: usize = 32;
pub const MAX_TOKEN_BYTES: usize = 4 * 1024;
pub const MAX_PROFILE_ID_BYTES: usize = 128;
pub const MAX_ENTRIES: usize = 64;

/// Process-memory-only runtime bearer tokens. Persistent profiles retain only
/// a credential reference; an OS credential backend hydrates this store for
/// the lifetime of the desktop process.
pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            eraseAndFree(self.allocator, entry.value_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Insert or replace one bearer token. The store owns an independent copy
    /// and wipes the previous value before releasing it.
    pub fn put(self: *Store, profile_id: []const u8, token: []const u8) !void {
        try validateProfileId(profile_id);
        try validateToken(token);

        const token_copy = try self.allocator.dupe(u8, token);
        errdefer eraseAndFree(self.allocator, token_copy);

        if (self.entries.getPtr(profile_id)) |existing| {
            const previous = existing.*;
            existing.* = token_copy;
            eraseAndFree(self.allocator, previous);
            return;
        }
        if (self.entries.count() >= MAX_ENTRIES) return error.TooManyRuntimeCredentials;

        const profile_id_copy = try self.allocator.dupe(u8, profile_id);
        errdefer self.allocator.free(profile_id_copy);
        try self.entries.putNoClobber(self.allocator, profile_id_copy, token_copy);
    }

    /// Borrow a token until the next mutation of this store.
    pub fn get(self: *const Store, profile_id: []const u8) ?[]const u8 {
        return self.entries.get(profile_id);
    }

    /// Wipe and remove one token. Returns whether the profile was present.
    pub fn remove(self: *Store, profile_id: []const u8) bool {
        const removed = self.entries.fetchRemove(profile_id) orelse return false;
        self.allocator.free(removed.key);
        eraseAndFree(self.allocator, removed.value);
        return true;
    }

    pub fn count(self: *const Store) usize {
        return self.entries.count();
    }
};

fn validateProfileId(profile_id: []const u8) !void {
    if (profile_id.len == 0) return error.EmptyProfileId;
    if (profile_id.len > MAX_PROFILE_ID_BYTES) return error.ProfileIdTooLong;
    for (profile_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') {
            return error.InvalidProfileId;
        }
    }
}

/// Validates a token before callers perform security-sensitive lifecycle
/// changes such as invalidating an old authenticated generation.
pub fn validateToken(token: []const u8) !void {
    if (token.len < MIN_TOKEN_BYTES) return error.WeakToken;
    if (token.len > MAX_TOKEN_BYTES) return error.TokenTooLong;
    for (token) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidTokenEncoding;
    }
}

fn eraseAndFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

test "ephemeral token store owns, replaces, and removes credentials" {
    const allocator = std.testing.allocator;
    const first = "0123456789abcdef0123456789abcdef";
    const second = "fedcba9876543210fedcba9876543210";
    var store = Store.init(allocator);
    defer store.deinit();

    try store.put("profile-home", first);
    try std.testing.expectEqualStrings(first, store.get("profile-home").?);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    try store.put("profile-home", second);
    try std.testing.expectEqualStrings(second, store.get("profile-home").?);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    try std.testing.expect(store.remove("profile-home"));
    try std.testing.expect(!store.remove("profile-home"));
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "ephemeral token store rejects unsafe identifiers and tokens" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectError(error.EmptyProfileId, store.put("", "0123456789abcdef0123456789abcdef"));
    try std.testing.expectError(error.InvalidProfileId, store.put("profile/one", "0123456789abcdef0123456789abcdef"));
    try std.testing.expectError(error.WeakToken, store.put("profile-one", "short"));
    try std.testing.expectError(
        error.InvalidTokenEncoding,
        store.put("profile-one", "0123456789abcdef0123456789abcde\n"),
    );
}

fn checkStoreAllocationFailure(allocator: std.mem.Allocator) !void {
    var store = Store.init(allocator);
    defer store.deinit();
    try store.put("profile-home", "0123456789abcdef0123456789abcdef");
    try store.put("profile-home", "fedcba9876543210fedcba9876543210");
    try store.put("profile-work", "00112233445566778899aabbccddeeff");
}

test "ephemeral token store cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkStoreAllocationFailure, .{});
}
