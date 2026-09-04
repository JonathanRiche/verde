//! Shared terminal-session DTOs and stable client-side identity helpers.
//!
//! This module is std-only so desktop terminal rendering can name daemon
//! sessions without importing the session daemon implementation.

const std = @import("std");

/// Bump whenever a GUI-required daemon method or response contract changes.
pub const PROTOCOL_VERSION: u32 = 28;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 30;

pub const RevivePolicy = enum {
    attach_or_create,
    attach_only,
    restart,
    manual,
};

pub const LayoutContext = struct {
    project_id: []const u8,
    project_path: []const u8 = "",
    dock_id: u32,
};

pub const LeafSessionMetadata = struct {
    session_id: ?[]const u8 = null,
    revive_policy: RevivePolicy = .attach_or_create,
};

pub const SessionStatus = enum {
    missing,
    starting,
    running,
    exited,
};

pub const SessionSummary = struct {
    session_id: []const u8,
    project_id: []const u8 = "",
    project_path: []const u8 = "",
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    label: []const u8 = "",
    status: SessionStatus = .missing,
    created_at_ms: ?i64 = null,
    last_attached_at_ms: ?i64 = null,
};

pub const Method = enum {
    @"session.list",
    @"session.inspect",
    @"session.create",
    @"session.attach",
    @"session.detach",
    @"session.write",
    @"session.resize",
    @"session.tail",
    @"session.tail.batch",
    @"session.screen",
    @"session.kill",
    @"session.cleanup",

    pub fn text(self: Method) []const u8 {
        return @tagName(self);
    }
};

pub const METHOD_NAMES = [_][]const u8{
    "session.list",
    "session.inspect",
    "session.create",
    "session.attach",
    "session.detach",
    "session.write",
    "session.resize",
    "session.tail",
    "session.tail.batch",
    "session.screen",
    "session.kill",
    "session.cleanup",
};

/// Viewport-sized initial transcript page and larger subsequent pages.
pub const TRANSCRIPT_FIRST_PAGE_SIZE: usize = 48;
pub const TRANSCRIPT_MESSAGE_PAGE_SIZE: usize = 256;

pub fn stableSessionId(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    dock_id: u32,
    pane_id: u32,
) ![]u8 {
    var safe_project_id: std.ArrayList(u8) = .empty;
    defer safe_project_id.deinit(allocator);
    try appendSafeComponent(allocator, &safe_project_id, project_id);
    if (safe_project_id.items.len == 0) try safe_project_id.appendSlice(allocator, "project");

    return std.fmt.allocPrint(
        allocator,
        "verde:{s}:dock:{d}:pane:{d}",
        .{ safe_project_id.items, dock_id, pane_id },
    );
}

pub fn sessionIdForLeaf(
    allocator: std.mem.Allocator,
    context: ?LayoutContext,
    pane_id: u32,
    existing_session_id: ?[]const u8,
) !?[]u8 {
    if (existing_session_id) |session_id| return @as(?[]u8, try allocator.dupe(u8, session_id));
    const ctx = context orelse return null;
    return @as(?[]u8, try stableSessionId(allocator, ctx.project_id, ctx.dock_id, pane_id));
}

fn appendSafeComponent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var previous_was_underscore = false;
    for (value) |byte| {
        const next = if (isSafeIdByte(byte)) byte else '_';
        if (next == '_') {
            if (previous_was_underscore) continue;
            previous_was_underscore = true;
        } else {
            previous_was_underscore = false;
        }
        try out.append(allocator, next);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        out.shrinkRetainingCapacity(out.items.len - 1);
    }
}

fn isSafeIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.';
}

test "session tail batching is an additive daemon method" {
    try std.testing.expectEqualStrings("session.tail", METHOD_NAMES[7]);
    try std.testing.expectEqualStrings("session.tail.batch", METHOD_NAMES[8]);
}

test "stable session ids sanitize project identifiers" {
    const id = try stableSessionId(std.testing.allocator, " hello///world ", 2, 3);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("verde:_hello_world:dock:2:pane:3", id);
}
