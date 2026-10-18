//! Temporary access to a background browser without changing the presented controller.

const std = @import("std");
const clock = @import("browser_controller.zig");

/// Owns the presented controller until the synchronous command has serialized its response.
/// No pointers into either controller may escape this scope.
pub fn Scope(comptime Controller: type) type {
    return struct {
        saved: ?Controller = null,
        borrowed_current: bool = false,
        /// Pane the command addressed; used to re-retain a runtime that
        /// came up live during the command.
        target_pane_id: ?u32 = null,

        const Self = @This();
        const Runtime = @FieldType(Controller, "runtime");

        /// `pane_id` names the browser pane the command targets; null means
        /// whichever browser the workspace is already running.
        pub fn begin(state: anytype, project_index: usize, pane_id: ?u32) !Self {
            const controller = &state.browser_controller;
            const owns_target = if (controller.runtime_project_index) |runtime_project|
                runtime_project == project_index and
                    (pane_id == null or controller.runtime_pane_id == null or controller.runtime_pane_id.? == pane_id.?)
            else
                false;
            // An agent driving the presented browser counts as use: idle
            // eviction must not close a page it is working in.
            if (owns_target and controller.presented_hidden_since_ms != null) {
                controller.presented_hidden_since_ms = clock.unixTimestampMs();
            }
            if (project_index == state.project_controller.selected_index and
                (owns_target or (controller.runtime_project_index == null and pane_id == null))) return .{};
            const host_window = controller.runtime.controller.host_window;
            const borrowed_current = owns_target;
            // Reserve before moving ownership: restoration must never allocate or fail.
            if (!borrowed_current) try controller.retained_runtimes.ensureUnusedCapacity(state.allocator, 1);
            var temporary = try Controller.init(state.allocator);
            errdefer temporary.deinit(state.allocator);
            temporary.app_window_screen_origin = controller.app_window_screen_origin;
            temporary.app_window_display_scale = controller.app_window_display_scale;
            temporary.surface_suspended_for_layout = true;
            temporary.background_access = true;
            if (borrowed_current) {
                std.mem.swap(Runtime, &temporary.runtime, &controller.runtime);
                temporary.runtime_pane_id = controller.runtime_pane_id;
            } else {
                for (controller.retained_runtimes.items, 0..) |entry, index| {
                    if (entry.project_index != project_index) continue;
                    if (pane_id != null and entry.pane_id != pane_id.?) continue;
                    temporary.runtime.deinit();
                    const retained = controller.retained_runtimes.orderedRemove(index);
                    temporary.runtime = retained.runtime;
                    temporary.runtime_pane_id = retained.pane_id;
                    break;
                }
            }
            temporary.runtime_project_index = project_index;
            // Leave runtime_pane_id unset when no live runtime was found, so
            // an open binds the pane and restores its saved URL and history
            // rather than treating an empty runtime as the restored page.
            // A lazy runtime inherits host configuration without attaching or showing a surface.
            temporary.runtime.controller.host_window = host_window;
            const saved = controller.*;
            controller.* = temporary;
            return .{ .saved = saved, .borrowed_current = borrowed_current, .target_pane_id = pane_id };
        }

        pub fn end(self: *Self, state: anytype) void {
            var saved = self.saved orelse return;
            const temporary = &state.browser_controller;
            // Navigation may show the backend before its asynchronous .opened event
            // updates the facade's visible flag. Use the requested backend state.
            const backend_visible = if (temporary.runtime.controller.backend) |*backend| switch (backend.*) {
                .native_webview => |*value| value.visible,
                .stub => |*value| value.visible,
            } else false;
            if (backend_visible) {
                if (temporary.runtime.controller.hide()) |_| {
                    temporary.runtime.suppressNextClosedEvent();
                } else |_| {
                    temporary.runtime.status = .failed;
                    temporary.runtime.setLastError("Failed to hide background browser surface.") catch {};
                }
            }
            if (self.borrowed_current) {
                std.mem.swap(Runtime, &saved.runtime, &temporary.runtime);
                saved.runtime_pane_id = temporary.runtime_pane_id;
                saved.runtime_project_index = temporary.runtime_project_index;
            } else if (temporary.runtime_project_index != null and
                (temporary.runtime_pane_id orelse self.target_pane_id) != null and
                temporary.runtime.controller.hasBackend())
            {
                // Only live pages are retained. An empty runtime (e.g. status
                // on an evicted pane) would otherwise count toward the cap
                // and push out a real page.
                saved.retained_runtimes.appendAssumeCapacity(.{
                    .project_index = temporary.runtime_project_index.?,
                    .pane_id = (temporary.runtime_pane_id orelse self.target_pane_id).?,
                    .runtime = temporary.runtime,
                    .retained_at_ms = clock.unixTimestampMs(),
                });
                // Transfer ownership, leaving an empty controller safe to destroy.
                temporary.runtime = Runtime.init(state.allocator) catch unreachable;
            }
            temporary.deinit(state.allocator);
            state.browser_controller = saved;
            self.saved = null;
        }
    };
}

const TestState = struct {
    const Owner = @import("browser_controller.zig");
    const Runtime = @import("../browser/mod.zig").State;
    const Stub = @import("../browser/platform/stub_backend.zig").Controller;
    const Pane = @import("browser_pane.zig").BrowserPaneRef;

    allocator: std.mem.Allocator = std.testing.allocator,
    browser_controller: Owner.State,
    project_controller: struct { selected_index: usize = 0 } = .{},
    pane: Pane = .{},
    dirty: bool = false,

    fn init() !TestState {
        var self: TestState = .{ .browser_controller = try Owner.State.init(std.testing.allocator) };
        errdefer self.deinit();
        self.browser_controller.runtime_project_index = 0;
        self.browser_controller.runtime_pane_id = 10;
        self.browser_controller.runtime.controller.backend = .{ .stub = try Stub.init(self.allocator) };
        try self.browser_controller.runtime.controller.show();
        try self.browser_controller.runtime.controller.focus();
        self.browser_controller.runtime.setControlsVisible(true);
        self.browser_controller.pane_focused = true;
        self.browser_controller.address_focused = true;
        self.browser_controller.clipboard_copy_pending = true;
        self.browser_controller.context_menu_open = true;
        self.browser_controller.pane_min = .{ 12, 34 };
        self.browser_controller.pane_max = .{ 500, 600 };
        self.browser_controller.surface_suspended_for_palette_overlay = true;
        var background = try Runtime.init(self.allocator);
        errdefer background.deinit();
        background.controller.backend = .{ .stub = try Stub.init(self.allocator) };
        background.status = .ready;
        try background.setLastEvalResult("Y-before");
        _ = try self.pane.ensureTab(self.allocator);
        try self.browser_controller.retained_runtimes.append(self.allocator, .{
            .project_index = 1,
            .pane_id = 20,
            .runtime = background,
        });
        return self;
    }

    fn deinit(self: *TestState) void {
        self.browser_controller.deinit(self.allocator);
        self.pane.deinit(self.allocator);
    }

    pub fn browserPaneRefMutable(self: *TestState, project_index: usize, pane_id: u32) ?*Pane {
        return if (project_index == 1 and pane_id == 20) &self.pane else null;
    }

    pub fn markDirty(self: *TestState) void {
        self.dirty = true;
    }

    fn command(self: *TestState, fail: bool) !void {
        var access = try Scope(Owner.State).begin(self, 1, null);
        defer access.end(self);
        try std.testing.expectEqual(@as(?u32, 20), self.browser_controller.runtime_pane_id);
        self.browser_controller.pane_min = .{ 0, 0 };
        self.browser_controller.address_focused = false;
        self.browser_controller.context_menu_open = false;
        try self.browser_controller.runtime.controller.eval("background action");
        if (fail) return error.TestCommandFailed;
    }

    fn expectPresentedUntouched(self: *TestState) !void {
        const controller = &self.browser_controller;
        try std.testing.expectEqual(@as(usize, 0), self.project_controller.selected_index);
        try std.testing.expectEqual(@as(?usize, 0), controller.runtime_project_index);
        try std.testing.expectEqual(@as(?u32, 10), controller.runtime_pane_id);
        try std.testing.expect(controller.runtime.controls_visible and controller.runtime.controller.visible);
        try std.testing.expect(controller.pane_focused and controller.address_focused and controller.clipboard_copy_pending);
        try std.testing.expect(controller.context_menu_open and controller.surface_suspended_for_palette_overlay);
        try std.testing.expectEqual([2]f32{ 12, 34 }, controller.pane_min);
        try std.testing.expectEqual([2]f32{ 500, 600 }, controller.pane_max);
        const backend = &controller.runtime.controller.backend.?.stub;
        try std.testing.expectEqual(@as(usize, 1), backend.show_requests);
        try std.testing.expectEqual(@as(usize, 1), backend.focus_requests);
        try std.testing.expectEqual(@as(usize, 0), backend.hide_requests);
        try std.testing.expectEqual(@as(usize, 0), backend.blur_requests);
    }
};

test "H1 background access leaves presented surface untouched on success and error" {
    var state = try TestState.init();
    defer state.deinit();
    try state.command(false);
    try state.expectPresentedUntouched();
    try std.testing.expectError(error.TestCommandFailed, state.command(true));
    try state.expectPresentedUntouched();
    try std.testing.expect(TestState.Owner.pollRetainedBrowserRuntimes(&state));
    try state.expectPresentedUntouched();
    try std.testing.expectEqualStrings("{\"status\":\"stub\"}", state.browser_controller.retained_runtimes.items[0].runtime.last_eval_result.?);
    try std.testing.expect(!state.dirty);
}
