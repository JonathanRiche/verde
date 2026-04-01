//! Shared browser runtime types.

const std = @import("std");

/// Tracks the host-side lifecycle of the native browser runtime.
pub const Status = enum {
    hidden,
    opening,
    ready,
    failed,
};

/// Carries notifications from the platform backend back into app state.
pub const Event = union(enum) {
    opened,
    closed,
    navigated: []u8,
    js_message: []u8,
    eval_result: []u8,
    failed: []u8,

    /// Releases any heap-allocated payloads carried by the event.
    pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
        switch (self) {
            .navigated => |value| allocator.free(value),
            .js_message => |value| allocator.free(value),
            .eval_result => |value| allocator.free(value),
            .failed => |value| allocator.free(value),
            else => {},
        }
    }
};
