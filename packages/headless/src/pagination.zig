//! Bounded, revision-bound cursors for durable list pagination.

const std = @import("std");

pub const MAX_CURSOR_BYTES: usize = 96;

const CURSOR_VERSION: []const u8 = "pg1";
const SCOPE_HASH_SEED: u64 = 0x76_65_72_64_65_70_61_67;

pub const Kind = enum {
    workspace,
    thread,

    fn tag(self: Kind) u8 {
        return switch (self) {
            .workspace => 'w',
            .thread => 't',
        };
    }
};

pub const DecodeError = error{
    InvalidCursor,
    StaleCursor,
    QueryMismatch,
};

/// Encode a cursor bound to one store revision and query scope. The scope
/// fingerprint prevents a cursor from being reused for another workspace or
/// filter; it is a consistency guard, not an authorization mechanism.
pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    kind: Kind,
    store_revision: u64,
    query_scope: []const u8,
    offset: usize,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}:{c}:{d}:{x}:{d}",
        .{ CURSOR_VERSION, kind.tag(), store_revision, scopeFingerprint(query_scope), offset },
    );
}

/// Decode a cursor for the current query. An absent cursor starts a fresh page
/// at offset zero. All supplied cursors are length-bounded before parsing.
pub fn decode(
    cursor: ?[]const u8,
    expected_kind: Kind,
    current_store_revision: u64,
    expected_query_scope: []const u8,
) DecodeError!usize {
    const value = cursor orelse return 0;
    if (value.len == 0 or value.len > MAX_CURSOR_BYTES) return error.InvalidCursor;

    var fields = std.mem.splitScalar(u8, value, ':');
    const version = fields.next() orelse return error.InvalidCursor;
    const kind = fields.next() orelse return error.InvalidCursor;
    const revision_text = fields.next() orelse return error.InvalidCursor;
    const scope_text = fields.next() orelse return error.InvalidCursor;
    const offset_text = fields.next() orelse return error.InvalidCursor;
    if (fields.next() != null or
        !std.mem.eql(u8, version, CURSOR_VERSION) or
        kind.len != 1 or
        !isDecimal(revision_text) or
        !isLowerHex(scope_text) or
        !isDecimal(offset_text))
    {
        return error.InvalidCursor;
    }

    const store_revision = std.fmt.parseInt(u64, revision_text, 10) catch return error.InvalidCursor;
    const scope = std.fmt.parseInt(u64, scope_text, 16) catch return error.InvalidCursor;
    const offset = std.fmt.parseInt(usize, offset_text, 10) catch return error.InvalidCursor;

    if (kind[0] != expected_kind.tag() or scope != scopeFingerprint(expected_query_scope)) {
        return error.QueryMismatch;
    }
    if (store_revision != current_store_revision) return error.StaleCursor;
    return offset;
}

fn scopeFingerprint(query_scope: []const u8) u64 {
    return std.hash.Wyhash.hash(SCOPE_HASH_SEED, query_scope);
}

fn isDecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isLowerHex(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

test "page cursor round trips revision scope and offset" {
    const allocator = std.testing.allocator;
    const encoded = try encodeAlloc(allocator, .thread, 42, "workspace-a", 200);
    defer allocator.free(encoded);

    try std.testing.expect(encoded.len <= MAX_CURSOR_BYTES);
    try std.testing.expectEqual(
        @as(usize, 200),
        try decode(encoded, .thread, 42, "workspace-a"),
    );
    try std.testing.expectEqual(@as(usize, 0), try decode(null, .thread, 99, "workspace-a"));
}

test "page cursor rejects stale and mismatched queries" {
    const allocator = std.testing.allocator;
    const encoded = try encodeAlloc(allocator, .thread, 42, "workspace-a", 10);
    defer allocator.free(encoded);

    try std.testing.expectError(error.StaleCursor, decode(encoded, .thread, 43, "workspace-a"));
    try std.testing.expectError(error.QueryMismatch, decode(encoded, .thread, 42, "workspace-b"));
    try std.testing.expectError(error.QueryMismatch, decode(encoded, .workspace, 42, "workspace-a"));
}

test "page cursor rejects legacy malformed oversized and overflowing input" {
    try std.testing.expectError(error.InvalidCursor, decode("o:1", .workspace, 1, "active"));
    try std.testing.expectError(error.InvalidCursor, decode("pg1:w:1:abc:2:extra", .workspace, 1, "active"));
    try std.testing.expectError(error.InvalidCursor, decode("pg1:w:1:ABC:2", .workspace, 1, "active"));
    try std.testing.expectError(error.InvalidCursor, decode("pg1:w:18446744073709551616:0:2", .workspace, 1, "active"));

    var oversized: [MAX_CURSOR_BYTES + 1]u8 = undefined;
    @memset(&oversized, '1');
    try std.testing.expectError(error.InvalidCursor, decode(&oversized, .workspace, 1, "active"));
}
