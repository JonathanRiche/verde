//! Temporary platform backend used while native webview shims are being built out.

const std = @import("std");
const browser_input = @import("../input.zig");
const browser_queue = @import("../queue.zig");
const browser_texture = @import("../texture.zig");
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

    /// Accepts the host window handle required by native platform backends.
    pub fn setHostWindow(self: *Controller, handle: ?*anyopaque) !void {
        _ = self;
        _ = handle;
    }

    /// Fully tears down the stub backend.
    pub fn shutdown(self: *Controller) void {
        self.deinit();
    }

    /// Returns the runtime family represented by this backend.
    pub fn runtimeKind(self: *const Controller) browser_types.RuntimeKind {
        _ = self;
        return .stub;
    }

    /// The stub is initialized as soon as it is constructed.
    pub fn isRuntimeInitialized(self: *const Controller) bool {
        _ = self;
        return true;
    }

    /// The stub has no heavy runtime to tear down between closes.
    pub fn runtimeMode(self: *const Controller) browser_types.RuntimeMode {
        _ = self;
        return .keep_warm;
    }

    /// Reports that the stub has no real browser presentation surface.
    pub fn presentationKind(self: *const Controller) browser_types.PresentationKind {
        _ = self;
        return .stub;
    }

    /// The stub cannot host the bundled browser inspector.
    pub fn supportsInspector(self: *const Controller) bool {
        _ = self;
        return false;
    }

    /// The stub does not expose popout windows.
    pub fn supportsPopout(self: *const Controller) bool {
        _ = self;
        return false;
    }

    /// The stub does not use an external browser SDK.
    pub fn sdkConfigured(self: *const Controller) bool {
        _ = self;
        return false;
    }

    /// The stub has no real pane session.
    pub fn paneSessionId(self: *const Controller) ?browser_types.SessionId {
        _ = self;
        return null;
    }

    /// The stub has no browser texture.
    pub fn paneTexture(self: *const Controller) ?browser_texture.PaneTexture {
        _ = self;
        return null;
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

    /// Accepts pane resizes so the stub can satisfy the full browser backend contract.
    pub fn resizePane(self: *Controller, width: u32, height: u32) !void {
        _ = self;
        _ = width;
        _ = height;
    }

    /// Accepts pane bounds so the stub can satisfy the full browser backend contract.
    pub fn setPaneBounds(self: *Controller, bounds: browser_types.PaneBounds) !void {
        try self.resizePane(bounds.width, bounds.height);
    }

    /// Emits a placeholder history result for backend-contract smoke tests.
    pub fn goBack(self: *Controller) !void {
        try self.eval("history.back()");
    }

    /// Emits a placeholder history result for backend-contract smoke tests.
    pub fn goForward(self: *Controller) !void {
        try self.eval("history.forward()");
    }

    /// Emits a placeholder reload result for backend-contract smoke tests.
    pub fn reload(self: *Controller) !void {
        try self.eval("location.reload()");
    }

    /// Stub focus is accepted but has no platform surface to update.
    pub fn focus(self: *Controller) !void {
        _ = self;
    }

    /// Stub blur is accepted but has no platform surface to update.
    pub fn blur(self: *Controller) !void {
        _ = self;
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

    /// Stub context menus are not implemented.
    pub fn activateContextMenuItem(self: *Controller, index: u32) !void {
        _ = self;
        _ = index;
    }

    /// Stub context menus are not implemented.
    pub fn dismissContextMenu(self: *Controller) !void {
        _ = self;
    }

    /// Returns the next queued backend event, if one is available.
    pub fn popEvent(self: *Controller) ?browser_types.Event {
        return self.queue.pop();
    }

    /// Alias used by the shared backend contract.
    pub fn pollEvent(self: *Controller) ?browser_types.Event {
        return self.popEvent();
    }

    // Keeps the stub backend aligned with the last requested URL until the native shims replace it.
    fn replaceCurrentUrl(self: *Controller, value: []const u8) !void {
        if (self.current_url) |url| self.allocator.free(url);
        self.current_url = try self.allocator.dupe(u8, value);
    }
};
