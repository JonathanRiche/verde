//! Temporary platform backend used while native webview shims are being built out.

const std = @import("std");
const browser_input = @import("../input.zig");
const browser_queue = @import("../queue.zig");
const browser_types = @import("../types.zig");

/// Simulates a browser backend so the desktop-facing state and UI can land first.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    queue: browser_queue.EventQueue = .{},
    visible: bool = false,
    current_url: ?[]u8 = null,

    /// Initializes the temporary browser backend.
    pub fn init(allocator: std.mem.Allocator) !Controller {
        return .{
            .allocator = allocator,
        };
    }

    /// Releases backend-owned state and any queued events.
    pub fn deinit(self: *Controller) void {
        if (self.current_url) |url| self.allocator.free(url);
        self.queue.deinit(self.allocator);
    }

    /// Marks the browser as visible and emits the corresponding lifecycle event.
    pub fn show(self: *Controller) !void {
        if (self.visible) return;
        self.visible = true;
        try self.queue.push(self.allocator, .opened);
    }

    /// Marks the browser as hidden and emits the corresponding lifecycle event.
    pub fn hide(self: *Controller) !void {
        if (!self.visible) return;
        self.visible = false;
        try self.queue.push(self.allocator, .closed);
    }

    /// Toggles the backend visibility without exposing platform details to app state.
    pub fn toggle(self: *Controller) !void {
        if (self.visible) {
            try self.hide();
        } else {
            try self.show();
        }
    }

    /// Records the next URL so state/UI plumbing can be exercised before native shims land.
    pub fn navigate(self: *Controller, url: []const u8) !void {
        try self.replaceCurrentUrl(url);
        if (!self.visible) {
            try self.show();
        }
        try self.queue.push(self.allocator, .{
            .navigated = try self.allocator.dupe(u8, url),
        });
    }

    /// Emits a placeholder eval result so the JS response path can be wired now.
    pub fn eval(self: *Controller, js: []const u8) !void {
        _ = js;
        try self.queue.push(self.allocator, .{
            .eval_result = try self.allocator.dupe(u8, "{\"status\":\"stub\"}"),
        });
    }

    /// Echoes host-originated messages so the bridge path is testable before backend work.
    pub fn postJson(self: *Controller, json: []const u8) !void {
        try self.queue.push(self.allocator, .{
            .js_message = try self.allocator.dupe(u8, json),
        });
    }

    /// Reports that pointer input is not implemented by the stub backend.
    pub fn handleMouse(self: *Controller, event: browser_input.MouseEvent) !bool {
        _ = self;
        _ = event;
        return false;
    }

    /// Reports that keyboard input is not implemented by the stub backend.
    pub fn handleKey(self: *Controller, event: browser_input.KeyEvent) !bool {
        _ = self;
        _ = event;
        return false;
    }

    /// Returns the next queued backend event, if one is available.
    pub fn popEvent(self: *Controller) ?browser_types.Event {
        return self.queue.pop();
    }

    // Keeps the stub backend aligned with the last requested URL until the native shims replace it.
    fn replaceCurrentUrl(self: *Controller, value: []const u8) !void {
        if (self.current_url) |url| self.allocator.free(url);
        self.current_url = try self.allocator.dupe(u8, value);
    }
};
