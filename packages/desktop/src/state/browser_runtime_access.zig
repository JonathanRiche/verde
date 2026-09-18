//! Temporary access to a background browser without changing the presented controller.

const std = @import("std");

/// Owns the presented controller until the synchronous command has serialized its response.
/// No pointers into either controller may escape this scope.
pub fn Scope(comptime Controller: type) type {
    return struct {
        saved: ?Controller = null,
        borrowed_current: bool = false,

        const Self = @This();
        const Runtime = @FieldType(Controller, "runtime");

        pub fn begin(state: anytype, project_index: usize) !Self {
            if (project_index == state.project_controller.selected_index and
                (state.browser_controller.runtime_project_index == null or state.browser_controller.runtime_project_index == project_index)) return .{};
            const controller = &state.browser_controller;
            const host_window = controller.runtime.controller.host_window;
            const borrowed_current = controller.runtime_project_index == project_index;
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
                    temporary.runtime.deinit();
                    const retained = controller.retained_runtimes.orderedRemove(index);
                    temporary.runtime = retained.runtime;
                    temporary.runtime_pane_id = retained.pane_id;
                    break;
                }
            }
            temporary.runtime_project_index = project_index;
            // A lazy runtime inherits host configuration without attaching or showing a surface.
            temporary.runtime.controller.host_window = host_window;
            const saved = controller.*;
            controller.* = temporary;
            return .{ .saved = saved, .borrowed_current = borrowed_current };
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
            } else if (temporary.runtime_project_index) |project_index| {
                saved.retained_runtimes.appendAssumeCapacity(.{
                    .project_index = project_index,
                    .pane_id = temporary.runtime_pane_id,
                    .runtime = temporary.runtime,
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
        var access = try Scope(Owner.State).begin(self, 1);
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

test "H1 retained late eval and lifecycle events drain without desktop UI effects" {
    var state = try TestState.init();
    defer state.deinit();
    try state.command(false);
    _ = TestState.Owner.pollRetainedBrowserRuntimes(&state);
    const runtime = &state.browser_controller.retained_runtimes.items[0].runtime;
    const queue = &runtime.controller.backend.?.stub.queue;
    try queue.push(state.allocator, .{ .eval_result = try state.allocator.dupe(u8, "late-Y-result") });
    try queue.push(state.allocator, .{ .navigated = try state.allocator.dupe(u8, "https://y.example/next") });
    try queue.push(state.allocator, .{ .title_changed = try state.allocator.dupe(u8, "Y title") });
    try queue.push(state.allocator, .document_loaded);
    runtime.suppressNextClosedEvent();
    try queue.push(state.allocator, .closed);
    try queue.push(state.allocator, .{ .context_menu = try state.allocator.dupe(u8, "{}") });
    try queue.push(state.allocator, .{ .js_message = try state.allocator.dupe(u8, "{\"source\":\"verde-browser-clipboard\",\"text\":\"ignored\"}") });
    try queue.push(state.allocator, .{ .cursor_changed = .pointer });
    try std.testing.expect(TestState.Owner.pollRetainedBrowserRuntimes(&state));
    try state.expectPresentedUntouched();
    try std.testing.expectEqualStrings("late-Y-result", runtime.last_eval_result.?);
    try std.testing.expectEqualStrings("https://y.example/next", state.pane.activeTab().?.url.?);
    try std.testing.expectEqualStrings("Y title", state.pane.activeTab().?.title.?);
    try std.testing.expect(!state.pane.activeTab().?.loading);
    try std.testing.expectEqual(.ready, runtime.status);
    runtime.expectSuppressedEvalResult();
    try queue.push(state.allocator, .{ .eval_result = try state.allocator.dupe(u8, "internal") });
    try queue.push(state.allocator, .{ .failed = try state.allocator.dupe(u8, "Y failed") });
    try queue.push(state.allocator, .document_loaded);
    // A backend-less current slot must not starve retained results.
    state.browser_controller.runtime.controller.shutdown();
    try std.testing.expect(TestState.Owner.pollRetainedBrowserRuntimes(&state));
    try std.testing.expectEqualStrings("late-Y-result", runtime.last_eval_result.?);
    try std.testing.expectEqual(.failed, runtime.status);
    try std.testing.expect(state.pane.activeTab().?.load_failed);
    try std.testing.expect(state.browser_controller.pane_focused and state.browser_controller.clipboard_copy_pending);
}

test "H1 newly navigated background backend hides before asynchronous opened is consumed" {
    var state = try TestState.init();
    defer state.deinit();
    {
        var access = try Scope(TestState.Owner.State).begin(&state, 2);
        defer access.end(&state);
        state.browser_controller.runtime.controller.backend = .{ .stub = try TestState.Stub.init(state.allocator) };
        try state.browser_controller.runtime.controller.navigate("https://z.example/");
        // The backend has shown itself; its facade has not polled .opened yet.
        try std.testing.expect(!state.browser_controller.runtime.controller.visible);
        try std.testing.expect(state.browser_controller.runtime.controller.backend.?.stub.visible);
    }
    try state.expectPresentedUntouched();
    try std.testing.expectEqual(@as(usize, 2), state.browser_controller.retained_runtimes.items.len);
    const backend = &state.browser_controller.retained_runtimes.items[1].runtime.controller.backend.?.stub;
    try std.testing.expect(!backend.visible);
    try std.testing.expectEqual(@as(usize, 1), backend.hide_requests);
    try state.command(false);
    try state.expectPresentedUntouched();
}

test "H1 status access preserves binding results and backend visibility without dirtying" {
    var state = try TestState.init();
    defer state.deinit();
    {
        var access = try Scope(TestState.Owner.State).begin(&state, 1);
        defer access.end(&state);
        try std.testing.expectEqual(@as(?u32, 20), state.browser_controller.runtime_pane_id);
        try std.testing.expectEqualStrings("Y-before", state.browser_controller.runtime.last_eval_result.?);
        try std.testing.expect(!state.browser_controller.pane_focused);
        try std.testing.expect(state.browser_controller.surface_suspended_for_layout);
    }
    try state.expectPresentedUntouched();
    const backend = &state.browser_controller.retained_runtimes.items[0].runtime.controller.backend.?.stub;
    try std.testing.expectEqual(@as(usize, 0), backend.show_requests);
    try std.testing.expectEqual(@as(usize, 0), backend.hide_requests);
    try std.testing.expect(!state.dirty);
}
