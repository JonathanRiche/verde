//! Lazy CEF-oriented browser backend that uses a Linux helper for the real pane runtime.

const std = @import("std");
const builtin = @import("builtin");
const browser_input = @import("../input.zig");
const browser_bridge = @import("bridge.zig");
const browser_helper = @import("linux_helper.zig");
const browser_platform = @import("platform.zig");
const browser_queue = @import("../queue.zig");
const browser_session = @import("../session.zig");
const browser_texture = @import("../texture.zig");
const browser_types = @import("../types.zig");

const DEFAULT_PANE_WIDTH: u32 = 1280;
const DEFAULT_PANE_HEIGHT: u32 = 720;
const DEFAULT_SESSION_ID: browser_types.SessionId = 1;
/// Backs the desktop browser dock with either the real Linux CEF helper or the preview texture path.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    queue: browser_queue.EventQueue = .{},
    runtime_initialized: bool = false,
    runtime_mode: browser_types.RuntimeMode = .keep_warm,
    runtime_config: browser_platform.RuntimeConfig = browser_platform.defaultRuntimeConfig(),
    bridge_policy: browser_bridge.Policy = .{},
    pane_session: ?browser_session.Session = null,
    helper: ?browser_helper.Controller = null,

    /// Creates the browser backend without starting the heavy runtime yet.
    pub fn init(allocator: std.mem.Allocator) !Backend {
        return .{
            .allocator = allocator,
        };
    }

    /// Releases any queued events, pane textures, and the helper runtime when it was initialized.
    pub fn deinit(self: *Backend) void {
        if (self.helper) |*helper| {
            helper.deinit();
            self.helper = null;
        }
        if (self.pane_session) |*session| {
            session.deinit();
            self.pane_session = null;
        }
        self.queue.deinit(self.allocator);
    }

    /// Returns the runtime family this backend is preparing the desktop app to use.
    pub fn runtimeKind(self: *const Backend) browser_types.RuntimeKind {
        _ = self;
        return .cef;
    }

    /// Returns whether the underlying browser runtime has been initialized yet.
    pub fn isRuntimeInitialized(self: *const Backend) bool {
        return self.runtime_initialized;
    }

    /// Returns the current lifetime policy for the browser runtime.
    pub fn runtimeMode(self: *const Backend) browser_types.RuntimeMode {
        return self.runtime_mode;
    }

    /// Reports whether detached native browser windows are supported yet.
    pub fn supportsPopout(self: *const Backend) bool {
        return self.runtime_config.supports_popout;
    }

    /// Reports whether the build has been pointed at a real CEF SDK yet.
    pub fn sdkConfigured(self: *const Backend) bool {
        return self.runtime_config.sdk_configured;
    }

    /// Reports whether the build is using the in-app CEF preview path without a real SDK.
    pub fn stubPreview(self: *const Backend) bool {
        return self.runtime_config.stub_preview;
    }

    /// Returns the active pane session identifier, if one exists.
    pub fn paneSessionId(self: *const Backend) ?browser_types.SessionId {
        if (self.pane_session) |session| return session.id;
        return null;
    }

    /// Returns the current pane texture metadata, if one exists.
    pub fn paneTexture(self: *const Backend) ?browser_texture.PaneTexture {
        if (self.pane_session) |session| return session.texture;
        return null;
    }

    /// Creates the pane session on demand and marks it visible inside the desktop layout.
    pub fn show(self: *Backend) !void {
        try self.ensureRuntime();
        const pane = try self.ensurePaneSession(DEFAULT_PANE_WIDTH, DEFAULT_PANE_HEIGHT);
        if (pane.visible) return;

        pane.setVisible(true);
        if (self.usingNativeRuntime()) {
            const helper = if (self.helper) |*helper| helper else return error.BrowserUnavailable;
            try helper.show(@max(pane.width, 1), @max(pane.height, 1), pane.url orelse "about:blank");
            return;
        }

        try self.renderPreviewFrame(pane, pane.url orelse "about:blank");
        try self.queue.push(self.allocator, .opened);
    }

    /// Hides the pane session without destroying the warmed browser runtime.
    pub fn hide(self: *Backend) !void {
        const pane = if (self.pane_session) |*pane| pane else return;
        if (!pane.visible) return;

        pane.setVisible(false);
        if (self.helper) |*helper| {
            try helper.hide();
        }
        try self.queue.push(self.allocator, .closed);
    }

    /// Resizes the pane session to match the visible browser viewport in the dock.
    pub fn resizePane(self: *Backend, width: u32, height: u32) !void {
        try self.ensureRuntime();
        const pane = try self.ensurePaneSession(width, height);
        const next_width = @max(width, 1);
        const next_height = @max(height, 1);
        if (pane.width == next_width and pane.height == next_height) return;
        pane.resize(next_width, next_height);

        if (self.usingNativeRuntime()) {
            const helper = if (self.helper) |*helper| helper else return error.BrowserUnavailable;
            try helper.resize(next_width, next_height);
            return;
        }

        try self.renderPreviewFrame(pane, pane.url orelse "about:blank");
    }

    /// Navigates the pane session to the requested URL and keeps the pane visible.
    pub fn navigate(self: *Backend, url: []const u8) !void {
        try self.ensureRuntime();
        const pane = try self.ensurePaneSession(DEFAULT_PANE_WIDTH, DEFAULT_PANE_HEIGHT);
        const was_visible = pane.visible;

        pane.setVisible(true);
        try pane.setUrl(url);

        if (self.usingNativeRuntime()) {
            const helper = if (self.helper) |*helper| helper else return error.BrowserUnavailable;
            try helper.navigate(@max(pane.width, 1), @max(pane.height, 1), url);
            if (!was_visible) return;
            return;
        }

        try pane.setTitle(url);
        try self.renderPreviewFrame(pane, url);
        try self.queue.push(self.allocator, .opened);
        try self.queue.push(self.allocator, .{ .navigated = try self.allocator.dupe(u8, url) });
        try self.queue.push(self.allocator, .{ .title_changed = try self.allocator.dupe(u8, url) });
    }

    /// Evaluates JavaScript inside the active browser document.
    pub fn eval(self: *Backend, js: []const u8) !void {
        try self.ensureRuntime();

        if (self.usingNativeRuntime()) {
            const helper = if (self.helper) |*helper| helper else return error.BrowserUnavailable;
            try helper.eval(js);
            return;
        }

        try self.queue.push(self.allocator, .{
            .eval_result = try self.allocator.dupe(u8, "{\"status\":\"cef-scaffold\"}"),
        });
    }

    /// Sends host-originated JSON into the browser bridge policy path.
    pub fn postJson(self: *Backend, json: []const u8) !void {
        try self.ensureRuntime();
        if (!self.bridge_policy.allowsHostMessaging("app://desktop")) {
            try self.queue.push(self.allocator, .{
                .failed = try self.allocator.dupe(u8, "Browser bridge policy rejected the host message."),
            });
            return;
        }

        if (self.usingNativeRuntime()) {
            const helper = if (self.helper) |*helper| helper else return error.BrowserUnavailable;
            try helper.postJson(json);
            return;
        }

        try self.queue.push(self.allocator, .{
            .js_message = try self.allocator.dupe(u8, json),
        });
    }

    /// Forwards direct pane pointer input into the active native helper runtime.
    pub fn handleMouse(self: *Backend, event: browser_input.MouseEvent) !bool {
        try self.ensureRuntime();
        if (!self.usingNativeRuntime()) return false;
        const helper = if (self.helper) |*helper| helper else return error.BrowserUnavailable;
        return try helper.handleMouse(event);
    }

    /// Forwards direct pane keyboard input into the active native helper runtime.
    pub fn handleKey(self: *Backend, event: browser_input.KeyEvent) !bool {
        try self.ensureRuntime();
        if (!self.usingNativeRuntime()) return false;
        const helper = if (self.helper) |*helper| helper else return error.BrowserUnavailable;
        return try helper.handleKey(event);
    }

    /// Returns the next pending browser event, pumping the native helper first when needed.
    pub fn popEvent(self: *Backend) ?browser_types.Event {
        if (self.usingNativeRuntime() and self.runtime_initialized and self.queue.events.items.len == 0) {
            self.pumpHelperRuntime() catch {
                self.queue.push(self.allocator, .{
                    .failed = self.allocator.dupe(u8, "Embedded browser pane update failed.") catch return self.queue.pop(),
                }) catch {};
            };
        }
        return self.queue.pop();
    }

    // Reports whether this build should use the real Linux helper runtime instead of the synthetic preview.
    fn usingNativeRuntime(self: *const Backend) bool {
        return builtin.os.tag == .linux and self.sdkConfigured() and !self.stubPreview();
    }

    // Warms the runtime once so the browser cost is paid on first open instead of app launch.
    fn ensureRuntime(self: *Backend) !void {
        if (self.runtime_initialized) return;
        if (self.usingNativeRuntime()) {
            self.helper = try browser_helper.Controller.init(self.allocator, self.runtime_config.subprocess_name);
        }
        self.runtime_initialized = true;
    }

    // Creates the pane session lazily so the desktop shell can reason about one in-app browser surface.
    fn ensurePaneSession(self: *Backend, width: u32, height: u32) !*browser_session.Session {
        try self.ensureRuntime();
        if (self.pane_session == null) {
            self.pane_session = browser_session.Session.init(self.allocator, DEFAULT_SESSION_ID, width, height);
        }
        return &self.pane_session.?;
    }

    // Drains helper events and uploads dirty frames into the pane texture.
    fn pumpHelperRuntime(self: *Backend) !void {
        try self.drainHelperEvents();
        try self.captureHelperFrame();
    }

    // Copies helper event payloads into the shared Zig event queue for app-state consumption.
    fn drainHelperEvents(self: *Backend) !void {
        const helper = if (self.helper) |*helper| helper else return;
        while (helper.popEvent()) |event| {
            switch (event) {
                .closed => {
                    if (self.pane_session) |*pane| pane.setVisible(false);
                },
                .navigated => |payload| {
                    if (self.pane_session) |*pane| try pane.setUrl(payload);
                },
                .title_changed => |payload| {
                    if (self.pane_session) |*pane| try pane.setTitle(payload);
                },
                else => {},
            }
            try self.queue.push(self.allocator, event);
        }
    }

    // Uploads the latest helper-owned BGRA frame into the pane texture when a new frame is ready.
    fn captureHelperFrame(self: *Backend) !void {
        const pane = if (self.pane_session) |*pane| pane else return;
        const helper = if (self.helper) |*helper| helper else return;
        try helper.uploadFrame(&pane.texture);
    }

    // Renders a synthetic frame into the pane texture so the in-app path stays testable without a real SDK.
    fn renderPreviewFrame(self: *Backend, pane: *browser_session.Session, url: []const u8) !void {
        const width = @max(pane.width, 1);
        const height = @max(pane.height, 1);
        const pixel_count = @as(usize, width) * @as(usize, height) * 4;
        const pixels = try self.allocator.alloc(u8, pixel_count);
        defer self.allocator.free(pixels);

        const seed = std.hash.Wyhash.hash(0, url);
        const accent_a = colorFromSeed(seed, 0);
        const accent_b = colorFromSeed(seed, 17);
        const accent_c = colorFromSeed(seed, 33);
        const top_bar = @max(height / 7, 26);
        const address_top = @max(top_bar / 4, 6);
        const address_height = @max(top_bar / 2, 14);
        const address_left = @max(width / 12, 10);
        const address_right = width - @max(width / 14, 10);

        for (0..height) |y| {
            for (0..width) |x| {
                const offset = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
                var rgba = if (y < top_bar)
                    [4]u8{ 24, 28, 36, 255 }
                else
                    gradientColor(accent_a, accent_b, accent_c, width, height, x, y);

                if (y >= address_top and y < address_top + address_height and x >= address_left and x < address_right) {
                    rgba = .{ 235, 239, 246, 255 };
                } else if (y >= top_bar) {
                    const band = ((x / @max(width / 9, 1)) + (y / @max(height / 10, 1))) % 2;
                    if (band == 0) {
                        rgba[0] = @min(rgba[0] + 12, 255);
                        rgba[1] = @min(rgba[1] + 12, 255);
                        rgba[2] = @min(rgba[2] + 12, 255);
                    }
                }

                if (x < 2 or y < 2 or x >= width - 2 or y >= height - 2) {
                    rgba = .{ 14, 16, 22, 255 };
                }

                pixels[offset + 0] = rgba[0];
                pixels[offset + 1] = rgba[1];
                pixels[offset + 2] = rgba[2];
                pixels[offset + 3] = rgba[3];
            }
        }

        try pane.texture.uploadRgba(width, height, pixels);
    }
};

// Chooses one accent color from the navigation hash so different URLs produce visibly different panes.
fn colorFromSeed(seed: u64, shift: u6) [3]u8 {
    return .{
        @intCast(64 + ((seed >> shift) & 0x5F)),
        @intCast(92 + ((seed >> (shift + 7)) & 0x4F)),
        @intCast(116 + ((seed >> (shift + 13)) & 0x3F)),
    };
}

// Produces a simple three-color gradient that makes the pane rendering path visually obvious.
fn gradientColor(accent_a: [3]u8, accent_b: [3]u8, accent_c: [3]u8, width: u32, height: u32, x: usize, y: usize) [4]u8 {
    const width_f = @as(f32, @floatFromInt(@max(width - 1, 1)));
    const height_f = @as(f32, @floatFromInt(@max(height - 1, 1)));
    const fx = @as(f32, @floatFromInt(x)) / width_f;
    const fy = @as(f32, @floatFromInt(y)) / height_f;
    const blend = (fx + fy) * 0.5;

    const r = mixColorChannel(accent_a[0], accent_b[0], accent_c[0], fx, blend);
    const g = mixColorChannel(accent_a[1], accent_b[1], accent_c[1], fy, blend);
    const b = mixColorChannel(accent_a[2], accent_b[2], accent_c[2], fx, fy);
    return .{ r, g, b, 255 };
}

// Blends three channels without introducing a dependency on a larger color helper module.
fn mixColorChannel(a: u8, b: u8, c: u8, t_primary: f32, t_secondary: f32) u8 {
    const primary = @as(f32, @floatFromInt(a)) * (1.0 - t_primary) + @as(f32, @floatFromInt(b)) * t_primary;
    const mixed = primary * (1.0 - t_secondary) + @as(f32, @floatFromInt(c)) * t_secondary;
    return @intFromFloat(@min(@max(mixed, 0.0), 255.0));
}
