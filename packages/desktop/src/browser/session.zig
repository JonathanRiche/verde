//! Per-pane browser session state used by the desktop shell.

const std = @import("std");
const browser_texture = @import("texture.zig");
const browser_types = @import("types.zig");

/// Tracks one browser pane session independently from app-global browser state.
pub const Session = struct {
    allocator: std.mem.Allocator,
    id: browser_types.SessionId,
    width: u32,
    height: u32,
    visible: bool = false,
    title: ?[]u8 = null,
    url: ?[]u8 = null,
    texture: browser_texture.PaneTexture = .{},

    /// Creates a new browser pane session with its initial viewport size.
    pub fn init(allocator: std.mem.Allocator, id: browser_types.SessionId, width: u32, height: u32) Session {
        return .{
            .allocator = allocator,
            .id = id,
            .width = width,
            .height = height,
        };
    }

    /// Releases any owned strings carried by the pane session.
    pub fn deinit(self: *Session) void {
        if (self.title) |value| self.allocator.free(value);
        if (self.url) |value| self.allocator.free(value);
        self.texture.deinit();
    }

    /// Updates the pane viewport to match the latest dock geometry.
    pub fn resize(self: *Session, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
    }

    /// Updates whether the session is actively presented inside the desktop pane.
    pub fn setVisible(self: *Session, visible: bool) void {
        self.visible = visible;
    }

    /// Replaces the last known page title for the session.
    pub fn setTitle(self: *Session, value: ?[]const u8) !void {
        try self.replaceOptionalOwned(&self.title, value);
    }

    /// Replaces the last known page URL for the session.
    pub fn setUrl(self: *Session, value: ?[]const u8) !void {
        try self.replaceOptionalOwned(&self.url, value);
    }

    // Centralizes optional string ownership so session updates stay consistent.
    fn replaceOptionalOwned(self: *Session, slot: *?[]u8, value: ?[]const u8) !void {
        if (slot.*) |owned| self.allocator.free(owned);
        slot.* = if (value) |slice| try self.allocator.dupe(u8, slice) else null;
    }
};
