//! Shared browser runtime types.

const std = @import("std");

/// Identifies the browser runtime family backing the desktop pane.
pub const RuntimeKind = enum {
    legacy_native,
    cef,
};

/// Controls whether the browser runtime stays resident after the pane is closed.
pub const RuntimeMode = enum {
    keep_warm,
    shutdown_on_close,
};

/// Identifies one browser pane session within the desktop app.
pub const SessionId = u32;

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
    title_changed: []u8,
    document_loaded,
    js_message: []u8,
    eval_result: []u8,
    failed: []u8,

    /// Releases any heap-allocated payloads carried by the event.
    pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
        switch (self) {
            .navigated => |value| allocator.free(value),
            .title_changed => |value| allocator.free(value),
            .js_message => |value| allocator.free(value),
            .eval_result => |value| allocator.free(value),
            .failed => |value| allocator.free(value),
            else => {},
        }
    }
};
