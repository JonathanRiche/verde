//! Legacy browser backend selector that preserves the currently working native-helper path until CEF is integrated.

const builtin = @import("builtin");
const std = @import("std");
const browser_input = @import("input.zig");
const browser_texture = @import("texture.zig");
const browser_types = @import("types.zig");

const DEFAULT_PANE_WIDTH: u32 = 1280;
const DEFAULT_PANE_HEIGHT: u32 = 720;

const PlatformController = switch (builtin.os.tag) {
    .windows => @import("platform/windows_webview2.zig").Controller,
    .macos => @import("platform/macos_wkwebview.zig").Controller,
    else => @import("platform/linux_webkitgtk.zig").Controller,
};

/// Wraps the pre-CEF backend so the desktop app can stay testable during the migration.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    platform: PlatformController,
    visible: bool = false,
    pane_texture: browser_texture.PaneTexture = .{},
    pane_width: u32 = DEFAULT_PANE_WIDTH,
    pane_height: u32 = DEFAULT_PANE_HEIGHT,

    /// Creates the legacy browser backend selected for the active target OS.
    pub fn init(allocator: std.mem.Allocator) !Backend {
        return .{
            .allocator = allocator,
            .platform = try PlatformController.init(allocator),
        };
    }

    /// Releases the legacy platform backend and any queued events.
    pub fn deinit(self: *Backend) void {
        self.platform.deinit();
        self.pane_texture.deinit();
    }

    /// Returns the runtime family this backend uses.
    pub fn runtimeKind(self: *const Backend) browser_types.RuntimeKind {
        _ = self;
        return .legacy_native;
    }

    /// Reports that the legacy backend is warmed as soon as it exists.
    pub fn isRuntimeInitialized(self: *const Backend) bool {
        _ = self;
        return true;
    }

    /// Returns the current runtime lifetime policy for the legacy backend.
    pub fn runtimeMode(self: *const Backend) browser_types.RuntimeMode {
        _ = self;
        return .keep_warm;
    }

    /// Reports whether detached browser windows are supported on the current platform.
    pub fn supportsPopout(self: *const Backend) bool {
        _ = self;
        return false;
    }

    /// Reports that the legacy backend does not use the CEF SDK.
    pub fn sdkConfigured(self: *const Backend) bool {
        _ = self;
        return false;
    }

    /// Returns the active pane session identifier if the browser has been shown.
    pub fn paneSessionId(self: *const Backend) ?browser_types.SessionId {
        if (!self.visible) return null;
        return 1;
    }

    /// Returns the current pane texture on Linux when an offscreen frame exists.
    pub fn paneTexture(self: *const Backend) ?browser_texture.PaneTexture {
        if (builtin.os.tag != .linux) return null;
        return self.pane_texture;
    }

    /// Shows the legacy browser surface.
    pub fn show(self: *Backend) !void {
        try self.platform.show();
        self.visible = true;
    }

    /// Hides the legacy browser surface.
    pub fn hide(self: *Backend) !void {
        try self.platform.hide();
        self.visible = false;
    }

    /// Resizes the pane placeholder without forwarding anything into the legacy backend.
    pub fn resizePane(self: *Backend, width: u32, height: u32) !void {
        const next_width = @max(width, 1);
        const next_height = @max(height, 1);
        if (self.pane_width == next_width and self.pane_height == next_height) return;
        self.pane_width = next_width;
        self.pane_height = next_height;
        if (builtin.os.tag == .linux) {
            try self.platform.resizePane(self.pane_width, self.pane_height);
        }
    }

    /// Navigates the legacy browser surface.
    pub fn navigate(self: *Backend, url: []const u8) !void {
        try self.platform.navigate(url);
        self.visible = true;
    }

    /// Evaluates JavaScript inside the legacy browser surface.
    pub fn eval(self: *Backend, js: []const u8) !void {
        try self.platform.eval(js);
    }

    /// Sends host-originated JSON into the legacy browser bridge.
    pub fn postJson(self: *Backend, json: []const u8) !void {
        try self.platform.postJson(json);
    }

    /// Forwards pointer input into the Linux pane backend when it exists.
    pub fn handleMouse(self: *Backend, event: browser_input.MouseEvent) !bool {
        if (builtin.os.tag != .linux) return false;
        return self.platform.handleMouse(event);
    }

    /// Forwards keyboard input into the Linux pane backend when it exists.
    pub fn handleKey(self: *Backend, event: browser_input.KeyEvent) !bool {
        if (builtin.os.tag != .linux) return false;
        return self.platform.handleKey(event);
    }

    /// Returns the next event from the legacy platform backend, if available.
    pub fn popEvent(self: *Backend) ?browser_types.Event {
        if (builtin.os.tag == .linux) {
            self.platform.uploadFrame(&self.pane_texture) catch {};
        }
        return self.platform.popEvent();
    }
};
