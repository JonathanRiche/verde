//! Native webview backend selector that chooses the platform webview implementation for the target OS.

const builtin = @import("builtin");
const std = @import("std");
const browser_input = @import("input.zig");
const browser_texture = @import("texture.zig");
const browser_types = @import("types.zig");

const DEFAULT_PANE_WIDTH: u32 = 1280;
const DEFAULT_PANE_HEIGHT: u32 = 720;

const log = std.log.scoped(.native_webview);

const PlatformController = switch (builtin.os.tag) {
    .windows => @import("platform/windows_webview2.zig").Controller,
    .macos => @import("platform/macos_wkwebview.zig").Controller,
    else => @import("platform/linux_webkitgtk.zig").Controller,
};

pub fn configuredPresentationKind() browser_types.PresentationKind {
    return switch (builtin.os.tag) {
        .windows, .macos => .native_child_view,
        .linux => @import("platform/linux_webkitgtk.zig").configuredPresentationKind(),
        else => .stub,
    };
}

pub fn configuredSupportsInspector() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

pub fn configuredSupportsPopout() bool {
    return false;
}

fn frameLogEnabled() bool {
    const value = std.c.getenv("VERDE_BROWSER_FRAME_LOG") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

/// Wraps platform-native webview controllers behind the app-facing browser backend contract.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    platform: PlatformController,
    visible: bool = false,
    pane_texture: browser_texture.PaneTexture = .{},
    pane_screen_x: i32 = 0,
    pane_screen_y: i32 = 0,
    pane_width: u32 = DEFAULT_PANE_WIDTH,
    pane_height: u32 = DEFAULT_PANE_HEIGHT,

    /// Creates the native webview browser backend selected for the active target OS.
    pub fn init(allocator: std.mem.Allocator) !Backend {
        return .{
            .allocator = allocator,
            .platform = try PlatformController.init(allocator),
        };
    }

    /// Releases the native platform backend and any queued events.
    pub fn deinit(self: *Backend) void {
        self.platform.deinit();
        self.pane_texture.deinit();
    }

    /// Supplies the native SDL host window handle used by platform child-view backends.
    pub fn setHostWindow(self: *Backend, handle: ?*anyopaque) !void {
        try self.platform.setHostWindow(handle);
    }

    /// Fully tears down the native webview backend.
    pub fn shutdown(self: *Backend) void {
        self.deinit();
    }

    /// Returns the runtime family this backend uses.
    pub fn runtimeKind(self: *const Backend) browser_types.RuntimeKind {
        _ = self;
        return .native_webview;
    }

    /// Reports whether the selected platform webview runtime has been initialized.
    pub fn isRuntimeInitialized(self: *const Backend) bool {
        return self.platform.isRuntimeInitialized();
    }

    /// Returns the current runtime lifetime policy for the native webview backend.
    pub fn runtimeMode(self: *const Backend) browser_types.RuntimeMode {
        _ = self;
        return .keep_warm;
    }

    /// Reports how the platform backend presents browser content in the pane.
    pub fn presentationKind(self: *const Backend) browser_types.PresentationKind {
        return self.platform.presentationKind();
    }

    /// Reports whether detached browser windows are supported on the current platform.
    pub fn supportsPopout(self: *const Backend) bool {
        _ = self;
        return false;
    }

    /// Reports whether this native-webview backend can run the bundled inspector bridge today.
    pub fn supportsInspector(self: *const Backend) bool {
        return self.platform.supportsInspector();
    }

    /// Reports that the native webview backend does not use the CEF SDK.
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

    /// Shows the native browser surface.
    pub fn show(self: *Backend) !void {
        try self.platform.show();
        self.visible = true;
    }

    /// Hides the native browser surface.
    pub fn hide(self: *Backend) !void {
        try self.platform.hide();
        self.visible = false;
    }

    /// Resizes the native browser surface.
    pub fn resizePane(self: *Backend, width: u32, height: u32) !void {
        try self.setPaneBounds(.{
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .width = width,
            .height = height,
        });
    }

    /// Moves and resizes the platform-native browser surface to the Palette-owned pane bounds.
    pub fn setPaneBounds(self: *Backend, bounds: browser_types.PaneBounds) !void {
        const next_width = @max(bounds.width, 1);
        const next_height = @max(bounds.height, 1);
        const next_screen_x = bounds.screen_x;
        const next_screen_y = bounds.screen_y;
        if (self.pane_screen_x == next_screen_x and
            self.pane_screen_y == next_screen_y and
            self.pane_width == next_width and
            self.pane_height == next_height) return;
        self.pane_screen_x = next_screen_x;
        self.pane_screen_y = next_screen_y;
        self.pane_width = next_width;
        self.pane_height = next_height;
        try self.platform.setPaneBounds(.{
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .width = self.pane_width,
            .height = self.pane_height,
        });
    }

    /// Navigates the native browser surface.
    pub fn navigate(self: *Backend, url: []const u8) !void {
        try self.platform.navigate(url);
        if (!self.visible) {
            try self.platform.show();
        }
        self.visible = true;
    }

    /// Evaluates JavaScript inside the native browser surface.
    pub fn eval(self: *Backend, js: []const u8) !void {
        try self.platform.eval(js);
    }

    /// Sends host-originated JSON into the native browser bridge.
    pub fn postJson(self: *Backend, json: []const u8) !void {
        try self.platform.postJson(json);
    }

    /// Navigates backward using the platform API or the shared JavaScript fallback.
    pub fn goBack(self: *Backend) !void {
        try self.platform.goBack();
    }

    /// Navigates forward using the platform API or the shared JavaScript fallback.
    pub fn goForward(self: *Backend) !void {
        try self.platform.goForward();
    }

    /// Reloads the current page using the platform API or the shared JavaScript fallback.
    pub fn reload(self: *Backend) !void {
        try self.platform.reload();
    }

    /// Gives browser content keyboard focus when implemented by the platform backend.
    pub fn focus(self: *Backend) !void {
        try self.platform.focus();
    }

    /// Removes browser content keyboard focus when implemented by the platform backend.
    pub fn blur(self: *Backend) !void {
        try self.platform.blur();
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

    /// Returns the next event from the native platform backend, if available.
    pub fn popEvent(self: *Backend) ?browser_types.Event {
        return self.platform.popEvent();
    }

    /// Uploads at most one pending platform frame for the current app render tick.
    pub fn uploadFrame(self: *Backend) void {
        if (builtin.os.tag != .linux) return;
        const upload_start = monotonicTimestampNs();
        const uploaded = self.platform.uploadFrame(&self.pane_texture) catch |err| {
            log.warn("snapshot render_tick upload failed: {}", .{err});
            return;
        };
        if (!uploaded) return;
        const upload_end = monotonicTimestampNs();
        if (frameLogEnabled()) {
            log.info("snapshot render_tick upload_ms={d:.3}", .{nanosToMillis(upload_end - upload_start)});
        }
    }

    /// Alias used by the shared backend contract.
    pub fn pollEvent(self: *Backend) ?browser_types.Event {
        return self.popEvent();
    }
};

fn nanosToMillis(nanos: i128) f64 {
    return @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn monotonicTimestampNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(i128, @intCast(ts.nsec));
}
