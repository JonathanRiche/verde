//! Cross-platform browser controller facade.

const builtin = @import("builtin");
const std = @import("std");
const browser_types = @import("types.zig");

const PlatformController = switch (builtin.os.tag) {
    .windows => @import("platform/windows_webview2.zig").Controller,
    .macos => @import("platform/macos_wkwebview.zig").Controller,
    else => @import("platform/linux_webkitgtk.zig").Controller,
};

/// Hides platform-specific browser ownership behind a single Zig API.
pub const Controller = struct {
    platform: PlatformController,

    /// Creates the platform backend selected for the active target OS.
    pub fn init(allocator: std.mem.Allocator) !Controller {
        return .{
            .platform = try PlatformController.init(allocator),
        };
    }

    /// Releases the platform backend and any queued events.
    pub fn deinit(self: *Controller) void {
        self.platform.deinit();
    }

    /// Requests that the platform backend show its native browser surface.
    pub fn show(self: *Controller) !void {
        try self.platform.show();
    }

    /// Requests that the platform backend hide its native browser surface.
    pub fn hide(self: *Controller) !void {
        try self.platform.hide();
    }

    /// Toggles platform browser visibility.
    pub fn toggle(self: *Controller) !void {
        try self.platform.toggle();
    }

    /// Navigates the browser surface to the requested URL.
    pub fn navigate(self: *Controller, url: []const u8) !void {
        try self.platform.navigate(url);
    }

    /// Evaluates JavaScript inside the active browser document.
    pub fn eval(self: *Controller, js: []const u8) !void {
        try self.platform.eval(js);
    }

    /// Sends a host-originated JSON payload into the browser bridge.
    pub fn postJson(self: *Controller, json: []const u8) !void {
        try self.platform.postJson(json);
    }

    /// Drains one pending platform event, if available.
    pub fn pollEvent(self: *Controller) ?browser_types.Event {
        return self.platform.popEvent();
    }
};
