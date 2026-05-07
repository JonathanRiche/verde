//! Retained modal/popup surface primitive.

const std = @import("std");

const draw = @import("../draw.zig");
const Key = @import("../input/key.zig");
const sdl = @import("../sdl.zig");

pub const ModalConfig = struct {
    x: f32 = 120.0,
    y: f32 = 80.0,
    width: f32 = 360.0,
    height: f32 = 220.0,
    backdrop_color: draw.Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.42 },
    surface_color: draw.Color = .{ .r = 0.08, .g = 0.09, .b = 0.11, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.28, .g = 0.32, .b = 0.38, .a = 1.0 },
    dismiss_on_outside_click: bool = true,
    dismiss_on_escape: bool = true,
};

pub const Input = union(enum) {
    key: Key,
    mouse_down: draw.Vec2,
    open,
    close,
};

pub const ModalEvent = union(enum) {
    open_changed: bool,
    dismissed,
};

pub const ModalCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: ModalEvent) void = null,
};

pub fn Modal(comptime config: ModalConfig) type {
    return struct {
        const Component = @This();

        open: bool = false,
        callbacks: ModalCallbacks = .{},

        pub fn init(open: bool) Component {
            return .{ .open = open };
        }

        pub fn setCallbacks(self: *Component, callbacks: ModalCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn update(self: *Component, event: *const sdl.Event) !bool {
            switch (event.type) {
                .key_down => return self.handleInput(.{ .key = Key.fromSdl(event.key) orelse return false }),
                .mouse_button_down => return self.handleInput(.{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } }),
                else => return false,
            }
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            switch (input) {
                .open => {
                    self.setOpen(true);
                    return true;
                },
                .close => {
                    self.dismiss();
                    return true;
                },
                .key => |key| {
                    if (!self.open or !config.dismiss_on_escape or key.code != .escape) return false;
                    self.dismiss();
                    return true;
                },
                .mouse_down => |point| {
                    if (!self.open) return false;
                    if (Component.surfaceRect().contains(point)) return true;
                    if (!config.dismiss_on_outside_click) return true;
                    self.dismiss();
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (!self.open) return;
            try batch.rect(allocator, .{ .x = 0, .y = 0, .w = 100000, .h = 100000 }, config.backdrop_color);
            try batch.rect(allocator, Component.surfaceRect(), config.surface_color);
            try batch.rect(allocator, .{ .x = config.x, .y = config.y, .w = config.width, .h = 1.0 }, config.border_color);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn dismiss(self: *Component) void {
            if (!self.open) return;
            self.open = false;
            self.emit(.dismissed);
            self.emit(.{ .open_changed = false });
        }

        fn setOpen(self: *Component, open: bool) void {
            if (self.open == open) return;
            self.open = open;
            self.emit(.{ .open_changed = open });
        }

        fn emit(self: *Component, event: ModalEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }

        fn surfaceRect() draw.Rect {
            return .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height };
        }
    };
}

test "modal dismisses on outside click and escape" {
    const Dialog = Modal(.{ .x = 10, .y = 10, .width = 100, .height = 80 });
    var modal = Dialog.init(true);

    try std.testing.expect(modal.handleInput(.{ .mouse_down = .{ .x = 20, .y = 20 } }));
    try std.testing.expect(modal.open);
    try std.testing.expect(modal.handleInput(.{ .mouse_down = .{ .x = 200, .y = 20 } }));
    try std.testing.expect(!modal.open);
    try std.testing.expect(modal.handleInput(.open));
    try std.testing.expect(modal.handleInput(.{ .key = .{ .code = .escape } }));
    try std.testing.expect(!modal.open);
}
