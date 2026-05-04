//! Shared clipboard callback plumbing for components that copy or paste text.

const Self = @This();
const std = @import("std");

context: ?*anyopaque = null,
set: ?*const fn (context: ?*anyopaque, text: []const u8) bool = null,
get: ?*const fn (context: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 = null,

pub fn write(self: Self, text: []const u8) bool {
    const callback = self.set orelse return false;
    return callback(self.context, text);
}

/// Returns an owned clipboard string that the caller must free.
pub fn read(self: Self, allocator: std.mem.Allocator) ?[]u8 {
    const callback = self.get orelse return null;
    return callback(self.context, allocator);
}
