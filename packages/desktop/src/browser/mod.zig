//! Browser runtime state shared by the native controller and desktop UI.

const std = @import("std");

pub const Controller = @import("controller.zig").Controller;
pub const Event = @import("types.zig").Event;
pub const Status = @import("types.zig").Status;

pub const ADDRESS_CAPACITY: usize = 2048;

/// Stores browser-facing UI state separately from the rest of the chat shell.
pub const State = struct {
    allocator: std.mem.Allocator,
    controller: Controller,
    controls_visible: bool = false,
    status: Status = .hidden,
    address_storage: [ADDRESS_CAPACITY:0]u8 = std.mem.zeroes([ADDRESS_CAPACITY:0]u8),
    current_url: ?[]u8 = null,
    last_error: ?[]u8 = null,

    /// Initializes browser state and the selected platform controller.
    pub fn init(allocator: std.mem.Allocator) !State {
        return .{
            .allocator = allocator,
            .controller = try Controller.init(allocator),
        };
    }

    /// Releases owned strings and tears down the browser controller.
    pub fn deinit(self: *State) void {
        self.controller.deinit();
        if (self.current_url) |url| self.allocator.free(url);
        if (self.last_error) |message| self.allocator.free(message);
    }

    /// Returns the mutable URL buffer used by the desktop control surface.
    pub fn addressBuffer(self: *State) [:0]u8 {
        return self.address_storage[0 .. self.address_storage.len - 1 :0];
    }

    /// Returns the current URL input as a standard slice.
    pub fn addressInput(self: *const State) []const u8 {
        return std.mem.sliceTo(self.address_storage[0..], 0);
    }

    /// Shows or hides the desktop control surface that drives the browser backend.
    pub fn setControlsVisible(self: *State, visible: bool) void {
        self.controls_visible = visible;
    }

    /// Replaces the editable URL field with a new value.
    pub fn setAddress(self: *State, value: []const u8) void {
        @memset(&self.address_storage, 0);
        const len = @min(value.len, self.address_storage.len - 1);
        @memcpy(self.address_storage[0..len], value[0..len]);
    }

    /// Replaces the last committed URL tracked by app state.
    pub fn setCurrentUrl(self: *State, value: ?[]const u8) !void {
        try self.replaceOptionalOwned(&self.current_url, value);
    }

    /// Replaces the last error message exposed to the desktop UI.
    pub fn setLastError(self: *State, value: ?[]const u8) !void {
        try self.replaceOptionalOwned(&self.last_error, value);
    }

    /// Returns a short, UI-friendly label for the current browser lifecycle state.
    pub fn statusLabel(self: *const State) []const u8 {
        return switch (self.status) {
            .hidden => "Hidden",
            .opening => "Opening",
            .ready => "Ready",
            .failed => "Failed",
        };
    }

    // Centralizes optional string ownership so browser state updates stay consistent.
    fn replaceOptionalOwned(self: *State, slot: *?[]u8, value: ?[]const u8) !void {
        if (slot.*) |owned| self.allocator.free(owned);
        slot.* = if (value) |slice| try self.allocator.dupe(u8, slice) else null;
    }
};
