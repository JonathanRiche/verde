//! FIFO event queue shared by the browser controller and app state.

const std = @import("std");
const browser_types = @import("types.zig");

/// Buffers browser runtime events until the app state polls them on the UI thread.
pub const EventQueue = struct {
    events: std.ArrayList(browser_types.Event) = .empty,

    /// Releases all queued events and their payloads.
    pub fn deinit(self: *EventQueue, allocator: std.mem.Allocator) void {
        for (self.events.items) |event| {
            event.deinit(allocator);
        }
        self.events.deinit(allocator);
    }

    /// Appends a new browser runtime event to the tail of the queue.
    pub fn push(self: *EventQueue, allocator: std.mem.Allocator, event: browser_types.Event) !void {
        try self.events.append(allocator, event);
    }

    /// Removes and returns the oldest queued event, if one exists.
    pub fn pop(self: *EventQueue) ?browser_types.Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }
};
