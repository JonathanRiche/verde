//! Browser controller facade used by the desktop app.

const std = @import("std");
const builtin = @import("builtin");
const browser_input = @import("input.zig");
const browser_cef = @import("cef/backend.zig");
const browser_legacy = @import("legacy_backend.zig");
const browser_texture = @import("texture.zig");
const browser_types = @import("types.zig");
const build_options = @import("build_options");

const Backend = union(enum) {
    legacy: browser_legacy.Backend,
    cef: browser_cef.Backend,

    /// Releases whichever backend is currently active.
    fn deinit(self: *Backend) void {
        switch (self.*) {
            .legacy => |*backend| backend.deinit(),
            .cef => |*backend| backend.deinit(),
        }
    }
};

/// Hides browser-runtime ownership behind a single Zig API for desktop app state and UI.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    backend: ?Backend = null,
    visible: bool = false,

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

    /// Requests that the browser pane become visible, creating the backend on demand.
    pub fn show(self: *Controller) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .legacy => |*active| try active.show(),
            .cef => |*active| try active.show(),
        }
        self.visible = true;
    }

    /// Requests that the browser pane be hidden when one exists.
    pub fn hide(self: *Controller) !void {
        if (self.backend) |*backend| {
            switch (backend.*) {
                .legacy => |*active| try active.hide(),
                .cef => |*active| try active.hide(),
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
        switch (backend.*) {
            .legacy => |*active| try active.navigate(url),
            .cef => |*active| try active.navigate(url),
        }
    }

    /// Evaluates JavaScript inside the active browser document, creating the backend on demand.
    pub fn eval(self: *Controller, js: []const u8) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .legacy => |*active| try active.eval(js),
            .cef => |*active| try active.eval(js),
        }
    }

    /// Sends a host-originated JSON payload into the browser bridge, creating the backend on demand.
    pub fn postJson(self: *Controller, json: []const u8) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .legacy => |*active| try active.postJson(json),
            .cef => |*active| try active.postJson(json),
        }
    }

    /// Resizes the pane session to match the latest visible dock geometry.
    pub fn resizePane(self: *Controller, width: u32, height: u32) !void {
        const backend = try self.ensureBackend();
        switch (backend.*) {
            .legacy => |*active| try active.resizePane(width, height),
            .cef => |*active| try active.resizePane(width, height),
        }
    }

    /// Forwards pointer input into the active browser backend when supported.
    pub fn handleMouse(self: *Controller, event: browser_input.MouseEvent) !bool {
        const backend = try self.ensureBackend();
        return switch (backend.*) {
            .legacy => |*active| try active.handleMouse(event),
            .cef => |*active| try active.handleMouse(event),
        };
    }

    /// Forwards keyboard input into the active browser backend when supported.
    pub fn handleKey(self: *Controller, event: browser_input.KeyEvent) !bool {
        const backend = try self.ensureBackend();
        return switch (backend.*) {
            .legacy => |*active| try active.handleKey(event),
            .cef => |*active| try active.handleKey(event),
        };
    }

    /// Reports which browser runtime family is currently configured.
    pub fn runtimeKind(self: *const Controller) browser_types.RuntimeKind {
        const backend = if (self.backend) |*backend| backend else {
            return if (shouldUseCefBackend()) .cef else .legacy_native;
        };
        return switch (backend.*) {
            .legacy => |*active| active.runtimeKind(),
            .cef => |*active| active.runtimeKind(),
        };
    }

    /// Reports whether the heavy browser runtime has already been initialized.
    pub fn runtimeInitialized(self: *const Controller) bool {
        const backend = if (self.backend) |*backend| backend else return false;
        return switch (backend.*) {
            .legacy => |*active| active.isRuntimeInitialized(),
            .cef => |*active| active.isRuntimeInitialized(),
        };
    }

    /// Returns the current lifetime policy for the underlying browser runtime.
    pub fn runtimeMode(self: *const Controller) browser_types.RuntimeMode {
        const backend = if (self.backend) |*backend| backend else return .keep_warm;
        return switch (backend.*) {
            .legacy => |*active| active.runtimeMode(),
            .cef => |*active| active.runtimeMode(),
        };
    }

    /// Reports whether detached browser windows are implemented by the active backend.
    pub fn supportsPopout(self: *const Controller) bool {
        const backend = if (self.backend) |*backend| backend else return !shouldUseCefBackend() and builtin.os.tag == .linux;
        return switch (backend.*) {
            .legacy => |*active| active.supportsPopout(),
            .cef => |*active| active.supportsPopout(),
        };
    }

    /// Reports whether the build has been configured with a real CEF SDK path.
    pub fn sdkConfigured(self: *const Controller) bool {
        const backend = if (self.backend) |*backend| backend else return build_options.cef_sdk_configured;
        return switch (backend.*) {
            .legacy => |*active| active.sdkConfigured(),
            .cef => |*active| active.sdkConfigured(),
        };
    }

    /// Returns the active pane session identifier, if one has been created.
    pub fn paneSessionId(self: *const Controller) ?browser_types.SessionId {
        const backend = if (self.backend) |*backend| backend else return null;
        return switch (backend.*) {
            .legacy => |*active| active.paneSessionId(),
            .cef => |*active| active.paneSessionId(),
        };
    }

    /// Returns the active pane texture metadata, if a frame has been produced.
    pub fn paneTexture(self: *const Controller) ?browser_texture.PaneTexture {
        const backend = if (self.backend) |*backend| backend else return null;
        return switch (backend.*) {
            .legacy => |*active| active.paneTexture(),
            .cef => |*active| active.paneTexture(),
        };
    }

    /// Drains one pending backend event, if available.
    pub fn pollEvent(self: *Controller) ?browser_types.Event {
        const backend = if (self.backend) |*backend| backend else return null;
        const event = switch (backend.*) {
            .legacy => |*active| active.popEvent(),
            .cef => |*active| active.popEvent(),
        } orelse return null;
        switch (event) {
            .opened => self.visible = true,
            .closed => self.visible = false,
            else => {},
        }
        return event;
    }

    // Creates the backend the first time the browser is actually used.
    fn ensureBackend(self: *Controller) !*Backend {
        if (self.backend == null) {
            self.backend = if (shouldUseCefBackend())
                .{ .cef = try browser_cef.Backend.init(self.allocator) }
            else
                .{ .legacy = try browser_legacy.Backend.init(self.allocator) };
        }
        return &self.backend.?;
    }
};

// Chooses the CEF backend when a real SDK is configured or when preview mode is requested explicitly.
fn shouldUseCefBackend() bool {
    if (builtin.os.tag == .linux) {
        return build_options.cef_sdk_configured or build_options.cef_stub_preview;
    }
    return build_options.cef_sdk_configured or build_options.cef_stub_preview;
}
