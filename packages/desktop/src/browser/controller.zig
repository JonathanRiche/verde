//! Browser controller facade used by the desktop app.

const std = @import("std");
const builtin = @import("builtin");
const browser_input = @import("input.zig");
const browser_cef = @import("cef/backend.zig");
const browser_native_webview = @import("native_webview_backend.zig");
const browser_stub = @import("platform/stub_backend.zig");
const browser_texture = @import("texture.zig");
const browser_types = @import("types.zig");
const build_options = @import("build_options");

const Backend = union(enum) {
    native_webview: browser_native_webview.Backend,
    cef: browser_cef.Backend,
    stub: browser_stub.Controller,

    /// Releases whichever backend is currently active.
    fn deinit(self: *Backend) void {
        switch (self.*) {
            .native_webview => |*backend| backend.deinit(),
            .cef => |*backend| backend.deinit(),
            .stub => |*backend| backend.deinit(),
        }
    }
};

/// Hides browser-runtime ownership behind a single Zig API for desktop app state and UI.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    backend: ?Backend = null,
    visible: bool = false,
    host_window: ?*anyopaque = null,
    pane_bounds: browser_types.PaneBounds = .{},

    /// Creates a lazy browser controller without touching the heavy browser runtime yet.
    pub fn init(allocator: std.mem.Allocator) !Controller {
        return .{
            .allocator = allocator,
        };
    }

    /// Releases the backend if it was created.
    pub fn deinit(self: *Controller) void {
        if (self.backend) |*backend| {
            backend.deinit();
            self.backend = null;
        }
    }

    /// Records the native OS window handle that platform webviews should attach to.
    pub fn setHostWindow(self: *Controller, handle: ?*anyopaque) !void {
        self.host_window = handle;
        if (self.backend) |*backend| {
            try self.applyHostWindow(backend);
        }
    }

    /// Requests that the browser pane become visible, creating the backend on demand.
    pub fn show(self: *Controller) !void {
        const backend = try self.ensureBackend();
        try self.applyPaneBounds(backend);
        switch (backend.*) {
            .native_webview => |*active| try active.show(),
            .cef => |*active| try active.show(),
            .stub => |*active| try active.show(),
        }
        self.visible = true;
    }

    /// Requests that the browser pane be hidden when one exists.
    pub fn hide(self: *Controller) !void {
        if (self.backend) |*backend| {
            switch (backend.*) {
                .native_webview => |*active| try active.hide(),
                .cef => |*active| try active.hide(),
                .stub => |*active| try active.hide(),
            }
        }
        self.visible = false;
    }

    /// Tears the browser runtime down completely so the next open pays the lazy-init cost again.
    pub fn shutdown(self: *Controller) void {
        if (self.backend) |*backend| {
            backend.deinit();
            self.backend = null;
        }
        self.visible = false;
    }

    /// Toggles platform browser visibility.
    pub fn toggle(self: *Controller) !void {
        if (self.visible) {
            try self.hide();
        } else {
            try self.show();
        }
    }

    /// Navigates the browser pane to the requested URL, creating the backend on demand.
    pub fn navigate(self: *Controller, url: []const u8) !void {
        const backend = try self.ensureBackend();
        try self.applyPaneBounds(backend);
        switch (backend.*) {
            .native_webview => |*active| try active.navigate(url),
            .cef => |*active| try active.navigate(url),
            .stub => |*active| try active.navigate(url),
        }
    }

    /// Evaluates JavaScript inside the active browser document, creating the backend on demand.
    pub fn eval(self: *Controller, js: []const u8) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .native_webview => |*active| try active.eval(js),
            .cef => |*active| try active.eval(js),
            .stub => |*active| try active.eval(js),
        }
    }

    /// Sends a host-originated JSON payload into the browser bridge, creating the backend on demand.
    pub fn postJson(self: *Controller, json: []const u8) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .native_webview => |*active| try active.postJson(json),
            .cef => |*active| try active.postJson(json),
            .stub => |*active| try active.postJson(json),
        }
    }

    /// Navigates backward using the backend's native history API when available.
    pub fn goBack(self: *Controller) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .native_webview => |*active| try active.goBack(),
            .cef => |*active| try active.goBack(),
            .stub => |*active| try active.goBack(),
        }
    }

    /// Navigates forward using the backend's native history API when available.
    pub fn goForward(self: *Controller) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .native_webview => |*active| try active.goForward(),
            .cef => |*active| try active.goForward(),
            .stub => |*active| try active.goForward(),
        }
    }

    /// Reloads the current page through the backend's native API when available.
    pub fn reload(self: *Controller) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .native_webview => |*active| try active.reload(),
            .cef => |*active| try active.reload(),
            .stub => |*active| try active.reload(),
        }
    }

    /// Gives browser content keyboard focus when the platform backend supports it.
    pub fn focus(self: *Controller) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .native_webview => |*active| try active.focus(),
            .cef => |*active| try active.focus(),
            .stub => |*active| try active.focus(),
        }
    }

    /// Removes browser content keyboard focus when the platform backend supports it.
    pub fn blur(self: *Controller) !void {
        if (self.backend) |*backend| {
            switch (backend.*) {
                .native_webview => |*active| try active.blur(),
                .cef => |*active| try active.blur(),
                .stub => |*active| try active.blur(),
            }
        }
    }

    /// Reports whether a platform-native child browser view owns OS keyboard focus.
    pub fn hasNativeFocus(self: *const Controller) bool {
        const backend = if (self.backend) |*backend| backend else return false;
        return switch (backend.*) {
            .native_webview => |*active| active.hasNativeFocus(),
            .cef, .stub => false,
        };
    }

    pub fn macosAppKitDiagnostics(self: *const Controller, allocator: std.mem.Allocator) ?[]u8 {
        const backend = if (self.backend) |*backend| backend else return null;
        return switch (backend.*) {
            .native_webview => |*active| active.macosAppKitDiagnostics(allocator),
            .cef, .stub => null,
        };
    }

    /// Resizes the pane session to match the latest visible dock geometry.
    pub fn resizePane(self: *Controller, width: u32, height: u32) !void {
        self.pane_bounds.width = @max(width, 1);
        self.pane_bounds.height = @max(height, 1);
        if (self.backend) |*backend| {
            try self.applyPaneBounds(backend);
        }
    }

    /// Moves and resizes the native browser surface to the latest Palette-owned content rectangle.
    pub fn setPaneBounds(self: *Controller, bounds: browser_types.PaneBounds) !void {
        self.pane_bounds = .{
            .screen_x = bounds.screen_x,
            .screen_y = bounds.screen_y,
            .width = @max(bounds.width, 1),
            .height = @max(bounds.height, 1),
            .scale = @max(bounds.scale, 0.05),
        };
        if (self.backend) |*backend| {
            try self.applyPaneBounds(backend);
        }
    }

    fn applyPaneBounds(self: *Controller, backend: *Backend) !void {
        switch (backend.*) {
            .native_webview => |*active| try active.setPaneBounds(self.pane_bounds),
            .cef => |*active| try active.setPaneBounds(self.pane_bounds),
            .stub => |*active| try active.setPaneBounds(self.pane_bounds),
        }
    }

    fn applyHostWindow(self: *Controller, backend: *Backend) !void {
        switch (backend.*) {
            .native_webview => |*active| try active.setHostWindow(self.host_window),
            .cef => |*active| try active.setHostWindow(self.host_window),
            .stub => |*active| try active.setHostWindow(self.host_window),
        }
    }

    /// Forwards pointer input into the active browser backend when supported.
    pub fn handleMouse(self: *Controller, event: browser_input.MouseEvent) !bool {
        const backend = try self.ensureBackend();
        return switch (backend.*) {
            .native_webview => |*active| try active.handleMouse(event),
            .cef => |*active| try active.handleMouse(event),
            .stub => |*active| try active.handleMouse(event),
        };
    }

    /// Forwards keyboard input into the active browser backend when supported.
    pub fn handleKey(self: *Controller, event: browser_input.KeyEvent) !bool {
        const backend = try self.ensureBackend();
        return switch (backend.*) {
            .native_webview => |*active| try active.handleKey(event),
            .cef => |*active| try active.handleKey(event),
            .stub => |*active| try active.handleKey(event),
        };
    }

    /// Activates a backend-owned context-menu row, when the platform exposes one.
    pub fn activateContextMenuItem(self: *Controller, index: u32) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .native_webview => |*active| try active.activateContextMenuItem(index),
            .cef, .stub => {},
        }
    }

    /// Dismisses a backend-owned context menu, when the platform exposes one.
    pub fn dismissContextMenu(self: *Controller) !void {
        if (self.backend) |*backend| {
            switch (backend.*) {
                .native_webview => |*active| try active.dismissContextMenu(),
                .cef, .stub => {},
            }
        }
    }

    /// Reports which browser runtime family is currently configured.
    pub fn runtimeKind(self: *const Controller) browser_types.RuntimeKind {
        const backend = if (self.backend) |*backend| backend else {
            return configuredRuntimeKind();
        };
        return switch (backend.*) {
            .native_webview => |*active| active.runtimeKind(),
            .cef => |*active| active.runtimeKind(),
            .stub => .stub,
        };
    }

    /// Reports whether the heavy browser runtime has already been initialized.
    pub fn runtimeInitialized(self: *const Controller) bool {
        const backend = if (self.backend) |*backend| backend else return false;
        return switch (backend.*) {
            .native_webview => |*active| active.isRuntimeInitialized(),
            .cef => |*active| active.isRuntimeInitialized(),
            .stub => true,
        };
    }

    /// Reports whether a browser backend has been created.
    pub fn hasBackend(self: *const Controller) bool {
        return self.backend != null;
    }

    /// Returns the current lifetime policy for the underlying browser runtime.
    pub fn runtimeMode(self: *const Controller) browser_types.RuntimeMode {
        const backend = if (self.backend) |*backend| backend else return .keep_warm;
        return switch (backend.*) {
            .native_webview => |*active| active.runtimeMode(),
            .cef => |*active| active.runtimeMode(),
            .stub => .keep_warm,
        };
    }

    /// Reports how the browser content is presented inside the Palette-owned pane.
    pub fn presentationKind(self: *const Controller) browser_types.PresentationKind {
        const backend = if (self.backend) |*backend| backend else return configuredPresentationKind();
        return switch (backend.*) {
            .native_webview => |*active| active.presentationKind(),
            .cef => |*active| active.presentationKind(),
            .stub => .stub,
        };
    }

    /// Reports whether detached browser windows are implemented by the active backend.
    pub fn supportsPopout(self: *const Controller) bool {
        const backend = if (self.backend) |*backend| backend else {
            return switch (configuredBackendKind()) {
                .native_webview => browser_native_webview.configuredSupportsPopout(),
                .cef => false,
                .stub => false,
            };
        };
        return switch (backend.*) {
            .native_webview => |*active| active.supportsPopout(),
            .cef => |*active| active.supportsPopout(),
            .stub => false,
        };
    }

    /// Reports whether the active backend can run the bundled page inspector bridge.
    pub fn supportsInspector(self: *const Controller) bool {
        const backend = if (self.backend) |*backend| backend else {
            return switch (configuredBackendKind()) {
                .native_webview => browser_native_webview.configuredSupportsInspector(),
                .cef => build_options.cef_sdk_configured,
                .stub => false,
            };
        };
        return switch (backend.*) {
            .native_webview => |*active| active.supportsInspector(),
            .cef => |*active| active.supportsInspector(),
            .stub => false,
        };
    }

    /// Reports whether the build has been configured with a real CEF SDK path.
    pub fn sdkConfigured(self: *const Controller) bool {
        const backend = if (self.backend) |*backend| backend else return build_options.cef_sdk_configured;
        return switch (backend.*) {
            .native_webview => |*active| active.sdkConfigured(),
            .cef => |*active| active.sdkConfigured(),
            .stub => false,
        };
    }

    /// Returns the active pane session identifier, if one has been created.
    pub fn paneSessionId(self: *const Controller) ?browser_types.SessionId {
        const backend = if (self.backend) |*backend| backend else return null;
        return switch (backend.*) {
            .native_webview => |*active| active.paneSessionId(),
            .cef => |*active| active.paneSessionId(),
            .stub => null,
        };
    }

    /// Returns the active pane texture metadata, if a frame has been produced.
    pub fn paneTexture(self: *const Controller) ?browser_texture.PaneTexture {
        const backend = if (self.backend) |*backend| backend else return null;
        return switch (backend.*) {
            .native_webview => |*active| active.paneTexture(),
            .cef => |*active| active.paneTexture(),
            .stub => null,
        };
    }

    /// Drains one pending backend event, if available.
    pub fn pollEvent(self: *Controller) ?browser_types.Event {
        const backend = if (self.backend) |*backend| backend else return null;
        const event = switch (backend.*) {
            .native_webview => |*active| active.popEvent(),
            .cef => |*active| active.popEvent(),
            .stub => |*active| active.popEvent(),
        } orelse return null;
        switch (event) {
            .opened => self.visible = true,
            .closed => self.visible = false,
            else => {},
        }
        return event;
    }

    /// Uploads at most one pending browser frame for this app render tick.
    pub fn uploadFrame(self: *Controller) bool {
        const backend = if (self.backend) |*backend| backend else return false;
        switch (backend.*) {
            .native_webview => |*active| return active.uploadFrame(),
            .cef, .stub => return false,
        }
    }

    /// Alias used by the compile-time backend contract.
    pub fn isRuntimeInitialized(self: *const Controller) bool {
        return self.runtimeInitialized();
    }

    // Creates the backend the first time the browser is actually used.
    fn ensureBackend(self: *Controller) !*Backend {
        if (self.backend == null) {
            self.backend = switch (configuredBackendKind()) {
                .native_webview => .{ .native_webview = try browser_native_webview.Backend.init(self.allocator) },
                .cef => .{ .cef = try browser_cef.Backend.init(self.allocator) },
                .stub => .{ .stub = try browser_stub.Controller.init(self.allocator) },
            };
            try self.applyHostWindow(&self.backend.?);
        }
        return &self.backend.?;
    }
};

fn configuredBackendKind() browser_types.BackendKind {
    return switch (build_options.browser_backend) {
        .native_webview => .native_webview,
        .cef => .cef,
        .stub => .stub,
    };
}

fn configuredRuntimeKind() browser_types.RuntimeKind {
    return switch (configuredBackendKind()) {
        .native_webview => .native_webview,
        .cef => .cef,
        .stub => .stub,
    };
}

fn configuredPresentationKind() browser_types.PresentationKind {
    return switch (configuredBackendKind()) {
        .native_webview => browser_native_webview.configuredPresentationKind(),
        .cef => .offscreen_texture,
        .stub => .stub,
    };
}

test "host window and pane bounds preserve lazy backend startup" {
    var controller = try Controller.init(std.testing.allocator);
    defer controller.deinit();

    try std.testing.expect(!controller.hasBackend());
    try controller.setHostWindow(@ptrFromInt(0x1));
    try controller.setPaneBounds(.{ .screen_x = 10, .screen_y = 20, .width = 640, .height = 360 });
    try controller.resizePane(800, 450);

    try std.testing.expect(!controller.hasBackend());
    try std.testing.expect(!controller.runtimeInitialized());
}
