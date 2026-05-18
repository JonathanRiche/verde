//! macOS WKWebView browser backend.

const std = @import("std");
const browser_input = @import("../input.zig");
const browser_texture = @import("../texture.zig");
const browser_types = @import("../types.zig");

const DEFAULT_WIDTH: u32 = 1280;
const DEFAULT_HEIGHT: u32 = 720;

const EventKind = enum(c_int) {
    opened = 1,
    closed = 2,
    navigated = 3,
    title_changed = 4,
    document_loaded = 5,
    js_message = 6,
    eval_result = 7,
    failed = 8,
};

extern fn verde_macos_webview_create(ns_window: ?*anyopaque) ?*anyopaque;
extern fn verde_macos_webview_destroy(handle: ?*anyopaque) void;
extern fn verde_macos_webview_show(handle: ?*anyopaque) c_int;
extern fn verde_macos_webview_hide(handle: ?*anyopaque) c_int;
extern fn verde_macos_webview_set_bounds(handle: ?*anyopaque, x: c_int, y: c_int, width: c_int, height: c_int) c_int;
extern fn verde_macos_webview_navigate(handle: ?*anyopaque, url: [*:0]const u8) c_int;
extern fn verde_macos_webview_eval(handle: ?*anyopaque, js: [*:0]const u8) c_int;
extern fn verde_macos_webview_post_json(handle: ?*anyopaque, json: [*:0]const u8) c_int;
extern fn verde_macos_webview_go_back(handle: ?*anyopaque) c_int;
extern fn verde_macos_webview_go_forward(handle: ?*anyopaque) c_int;
extern fn verde_macos_webview_reload(handle: ?*anyopaque) c_int;
extern fn verde_macos_webview_focus(handle: ?*anyopaque) c_int;
extern fn verde_macos_webview_blur(handle: ?*anyopaque) c_int;
extern fn verde_macos_webview_pop_event(handle: ?*anyopaque, kind: *c_int, payload: *?[*:0]u8) c_int;
extern fn verde_macos_webview_free_string(value: ?[*:0]u8) void;

/// Owns a WKWebView child view attached to the SDL-created NSWindow.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    host_window: ?*anyopaque = null,
    handle: ?*anyopaque = null,
    pane_bounds: browser_types.PaneBounds = .{ .width = DEFAULT_WIDTH, .height = DEFAULT_HEIGHT },

    pub fn init(allocator: std.mem.Allocator) !Controller {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Controller) void {
        if (self.handle) |handle| {
            verde_macos_webview_destroy(handle);
            self.handle = null;
        }
    }

    pub fn shutdown(self: *Controller) void {
        self.deinit();
    }

    pub fn runtimeKind(self: *const Controller) browser_types.RuntimeKind {
        _ = self;
        return .native_webview;
    }

    pub fn isRuntimeInitialized(self: *const Controller) bool {
        return self.handle != null;
    }

    pub fn runtimeMode(self: *const Controller) browser_types.RuntimeMode {
        _ = self;
        return .keep_warm;
    }

    pub fn supportsInspector(self: *const Controller) bool {
        _ = self;
        return true;
    }

    pub fn supportsPopout(self: *const Controller) bool {
        _ = self;
        return false;
    }

    pub fn sdkConfigured(self: *const Controller) bool {
        _ = self;
        return false;
    }

    pub fn paneSessionId(self: *const Controller) ?browser_types.SessionId {
        if (self.handle == null) return null;
        return 1;
    }

    pub fn paneTexture(self: *const Controller) ?browser_texture.PaneTexture {
        _ = self;
        return null;
    }

    pub fn setHostWindow(self: *Controller, handle: ?*anyopaque) !void {
        self.host_window = handle;
    }

    pub fn show(self: *Controller) !void {
        const handle = try self.ensureWebView();
        try self.applyBounds(handle);
        if (verde_macos_webview_show(handle) == 0) return error.BrowserUnavailable;
    }

    pub fn hide(self: *Controller) !void {
        if (self.handle) |handle| {
            if (verde_macos_webview_hide(handle) == 0) return error.BrowserUnavailable;
        }
    }

    pub fn resizePane(self: *Controller, width: u32, height: u32) !void {
        try self.setPaneBounds(.{
            .screen_x = self.pane_bounds.screen_x,
            .screen_y = self.pane_bounds.screen_y,
            .width = width,
            .height = height,
        });
    }

    pub fn setPaneBounds(self: *Controller, bounds: browser_types.PaneBounds) !void {
        self.pane_bounds = .{
            .screen_x = bounds.screen_x,
            .screen_y = bounds.screen_y,
            .width = @max(bounds.width, 1),
            .height = @max(bounds.height, 1),
        };
        if (self.handle) |handle| try self.applyBounds(handle);
    }

    pub fn navigate(self: *Controller, url: []const u8) !void {
        const handle = try self.ensureWebView();
        const z = try self.allocator.dupeZ(u8, url);
        defer self.allocator.free(z);
        if (verde_macos_webview_navigate(handle, z.ptr) == 0) return error.NavigateFailed;
    }

    pub fn eval(self: *Controller, js: []const u8) !void {
        const handle = try self.ensureWebView();
        const z = try self.allocator.dupeZ(u8, js);
        defer self.allocator.free(z);
        if (verde_macos_webview_eval(handle, z.ptr) == 0) return error.EvalFailed;
    }

    pub fn postJson(self: *Controller, json: []const u8) !void {
        const handle = try self.ensureWebView();
        const z = try self.allocator.dupeZ(u8, json);
        defer self.allocator.free(z);
        if (verde_macos_webview_post_json(handle, z.ptr) == 0) return error.EvalFailed;
    }

    pub fn goBack(self: *Controller) !void {
        const handle = try self.ensureWebView();
        if (verde_macos_webview_go_back(handle) == 0) return error.BrowserUnavailable;
    }

    pub fn goForward(self: *Controller) !void {
        const handle = try self.ensureWebView();
        if (verde_macos_webview_go_forward(handle) == 0) return error.BrowserUnavailable;
    }

    pub fn reload(self: *Controller) !void {
        const handle = try self.ensureWebView();
        if (verde_macos_webview_reload(handle) == 0) return error.BrowserUnavailable;
    }

    pub fn focus(self: *Controller) !void {
        const handle = try self.ensureWebView();
        if (verde_macos_webview_focus(handle) == 0) return error.BrowserUnavailable;
    }

    pub fn blur(self: *Controller) !void {
        if (self.handle) |handle| {
            if (verde_macos_webview_blur(handle) == 0) return error.BrowserUnavailable;
        }
    }

    pub fn presentationKind(self: *const Controller) browser_types.PresentationKind {
        _ = self;
        return .native_child_view;
    }

    pub fn handleMouse(self: *Controller, event: browser_input.MouseEvent) !bool {
        _ = self;
        _ = event;
        return false;
    }

    pub fn handleKey(self: *Controller, event: browser_input.KeyEvent) !bool {
        _ = self;
        _ = event;
        return false;
    }

    pub fn popEvent(self: *Controller) ?browser_types.Event {
        const handle = self.handle orelse return null;
        var kind_int: c_int = 0;
        var payload_ptr: ?[*:0]u8 = null;
        if (verde_macos_webview_pop_event(handle, &kind_int, &payload_ptr) == 0) return null;
        defer verde_macos_webview_free_string(payload_ptr);

        const payload = if (payload_ptr) |ptr| std.mem.span(ptr) else "";
        const kind: EventKind = @enumFromInt(kind_int);
        return switch (kind) {
            .opened => .opened,
            .closed => .closed,
            .navigated => .{ .navigated = self.allocator.dupe(u8, payload) catch return null },
            .title_changed => .{ .title_changed = self.allocator.dupe(u8, payload) catch return null },
            .document_loaded => .document_loaded,
            .js_message => .{ .js_message = self.allocator.dupe(u8, payload) catch return null },
            .eval_result => .{ .eval_result = self.allocator.dupe(u8, payload) catch return null },
            .failed => .{ .failed = self.allocator.dupe(u8, payload) catch return null },
        };
    }

    pub fn pollEvent(self: *Controller) ?browser_types.Event {
        return self.popEvent();
    }

    pub fn uploadFrame(self: *Controller, texture: *browser_texture.PaneTexture) !void {
        _ = self;
        _ = texture;
    }

    fn ensureWebView(self: *Controller) !*anyopaque {
        if (self.handle) |handle| return handle;
        const host_window = self.host_window orelse return error.BrowserUnavailable;
        const handle = verde_macos_webview_create(host_window) orelse return error.BrowserUnavailable;
        self.handle = handle;
        try self.applyBounds(handle);
        return handle;
    }

    fn applyBounds(self: *Controller, handle: *anyopaque) !void {
        if (verde_macos_webview_set_bounds(
            handle,
            @intCast(self.pane_bounds.screen_x),
            @intCast(self.pane_bounds.screen_y),
            @intCast(self.pane_bounds.width),
            @intCast(self.pane_bounds.height),
        ) == 0) return error.BrowserUnavailable;
    }
};
