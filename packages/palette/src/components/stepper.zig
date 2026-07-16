//! Retained stepped control: an ordered setting rendered as visible steps
//! (segments) instead of a dropdown. Supports click and arrow-key selection
//! and shows a short description for the active (hovered or selected) step.
//! Reusable for reasoning effort, speed tiers, access levels, theme density —
//! any small ordered option set.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const text_layout = @import("../text_layout.zig");

pub const StepTextFn = *const fn (context: ?*anyopaque, index: usize) []const u8;

pub const StepperConfig = struct {
    segment_height: f32 = 30.0,
    segment_gap: f32 = 4.0,
    corner_radius: f32 = 8.0,
    font_size: f32 = 13.0,
    description_font_size: f32 = 12.0,
    description_gap: f32 = 6.0,
    /// When true, `requiredHeight` reserves a line under the segments and the
    /// hovered (else selected) step's description renders there.
    show_description: bool = true,
    /// Duration of the selected-thumb slide between segments; the host must
    /// pump `tick` while `isAnimating`. Zero disables the animation.
    thumb_anim_ms: u32 = 160,
    glyph_width: f32 = 7.0,
    track_color: draw.Color = .{ .r = 0.09, .g = 0.10, .b = 0.12, .a = 1.0 },
    segment_color: draw.Color = .{ .r = 0.14, .g = 0.16, .b = 0.19, .a = 1.0 },
    segment_hover_color: draw.Color = .{ .r = 0.20, .g = 0.23, .b = 0.27, .a = 1.0 },
    segment_selected_color: draw.Color = .{ .r = 0.22, .g = 0.42, .b = 0.30, .a = 1.0 },
    text_color: draw.Color = .{ .r = 0.72, .g = 0.76, .b = 0.82, .a = 1.0 },
    text_selected_color: draw.Color = draw.Color.white,
    description_color: draw.Color = .{ .r = 0.60, .g = 0.64, .b = 0.70, .a = 1.0 },
    font_role: ?draw.FontRole = .ui,
    font_id: ?u32 = null,
    step_label: ?StepTextFn = null,
    step_description: ?StepTextFn = null,
    z_index: i32 = 0,
};

pub const StepperStyle = struct {
    track_color: draw.Color,
    segment_color: draw.Color,
    segment_hover_color: draw.Color,
    segment_selected_color: draw.Color,
    text_color: draw.Color,
    text_selected_color: draw.Color,
    description_color: draw.Color,
};

pub const Key = key_input;

pub const Input = union(enum) {
    key: Key,
    mouse_move: draw.Vec2,
    mouse_down: draw.Vec2,
};

pub const StepperEvent = union(enum) {
    changed: usize,
    hover_changed: ?usize,
};

pub const StepperCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: StepperEvent) void = null,
};

pub fn Stepper(comptime config: StepperConfig) type {
    return struct {
        const Component = @This();
        pub const Style = StepperStyle;

        rect: draw.Rect = .{ .x = 0.0, .y = 0.0, .w = 240.0, .h = config.segment_height },
        count: usize = 0,
        selected: ?usize = null,
        hovered: ?usize = null,
        /// Where the selected thumb is sliding from; null when at rest. The
        /// visual rect (not an index) so retargeting mid-flight stays smooth.
        anim_from_rect: ?draw.Rect = null,
        anim_progress: f32 = 1.0,
        ui_scale: f32 = 1.0,
        z_index: i32 = config.z_index,
        font_metrics: ?text_layout.FontMetrics = null,
        style: Style = defaultStyle(),
        callbacks: StepperCallbacks = .{},

        pub fn init(count: usize) Component {
            return .{ .count = count };
        }

        pub fn defaultStyle() Style {
            return .{
                .track_color = config.track_color,
                .segment_color = config.segment_color,
                .segment_hover_color = config.segment_hover_color,
                .segment_selected_color = config.segment_selected_color,
                .text_color = config.text_color,
                .text_selected_color = config.text_selected_color,
                .description_color = config.description_color,
            };
        }

        pub fn setStyle(self: *Component, style: Style) void {
            self.style = style;
        }

        pub fn setCallbacks(self: *Component, callbacks: StepperCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn setFontMetrics(self: *Component, metrics_value: text_layout.FontMetrics) void {
            self.font_metrics = metrics_value;
        }

        pub fn setUiScale(self: *Component, scale: f32) void {
            self.ui_scale = @max(scale, 0.1);
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.rect = rect;
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn setStepCount(self: *Component, count: usize) void {
            self.count = count;
            if (self.selected) |index| {
                if (index >= count) self.selected = null;
            }
            if (self.hovered) |index| {
                if (index >= count) self.hovered = null;
            }
        }

        /// External sync (host state → control) snaps without animating; only
        /// user selection via `select` slides the thumb.
        pub fn setSelected(self: *Component, index: ?usize) void {
            if (std.meta.eql(self.selected, index)) return;
            self.selected = index;
            self.anim_from_rect = null;
            self.anim_progress = 1.0;
        }

        /// Advances the thumb slide; hosts call this once per frame with the
        /// elapsed wall-clock milliseconds while `isAnimating`.
        pub fn tick(self: *Component, elapsed_ms: u32) void {
            if (self.anim_from_rect == null) return;
            if (config.thumb_anim_ms == 0) {
                self.anim_from_rect = null;
                self.anim_progress = 1.0;
                return;
            }
            self.anim_progress += @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(config.thumb_anim_ms));
            if (self.anim_progress >= 1.0) {
                self.anim_progress = 1.0;
                self.anim_from_rect = null;
            }
        }

        pub fn isAnimating(self: *const Component) bool {
            return self.anim_from_rect != null;
        }

        /// True when the point rests on a clickable segment; hosts use this
        /// to show a pointer (hand) mouse cursor.
        pub fn wantsPointerAt(self: *const Component, point: draw.Vec2) bool {
            return self.segmentAtPoint(point) != null;
        }

        /// Height the host should reserve for `rect`: segment strip plus the
        /// optional description line.
        pub fn requiredHeight(self: *const Component) f32 {
            var height = self.scaled(config.segment_height);
            if (config.show_description and config.step_description != null) {
                height += self.scaled(config.description_gap) + self.descriptionMetrics().line_height;
            }
            return height;
        }

        pub fn handleInput(self: *Component, input: Input) bool {
            switch (input) {
                .key => |key| return self.handleKey(key),
                .mouse_move => |point| {
                    const previous = self.hovered;
                    self.hovered = self.segmentAtPoint(point);
                    if (previous != self.hovered) {
                        self.emit(.{ .hover_changed = self.hovered });
                        return true;
                    }
                    return self.hovered != null;
                },
                .mouse_down => |point| {
                    const index = self.segmentAtPoint(point) orelse return false;
                    self.select(index);
                    return true;
                },
            }
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (self.count == 0) return;
            const previous_z = batch.setZIndex(self.z_index);
            defer batch.restoreZIndex(previous_z);

            const strip = self.stripRect();
            const corner = self.scaled(config.corner_radius);
            try batch.roundedRectClipped(allocator, strip, self.style.track_color, corner, self.rect);

            const metrics_value = self.labelMetrics();
            const segment_corner = @max(corner - 2.0, 2.0);
            // Base fills first, then the sliding selected thumb, then labels
            // on top so the thumb passes beneath the text.
            var index: usize = 0;
            while (index < self.count) : (index += 1) {
                const segment = self.segmentRect(index);
                const is_selected = self.selected != null and self.selected.? == index;
                const is_hovered = self.hovered != null and self.hovered.? == index;
                const fill = if (is_hovered and !is_selected)
                    self.style.segment_hover_color
                else
                    self.style.segment_color;
                try batch.roundedRectClipped(allocator, segment, fill, segment_corner, self.rect);
            }
            if (self.thumbRect()) |thumb| {
                try batch.roundedRectClipped(allocator, thumb, self.style.segment_selected_color, segment_corner, self.rect);
            }
            index = 0;
            while (index < self.count) : (index += 1) {
                const segment = self.segmentRect(index);
                const is_selected = self.selected != null and self.selected.? == index;
                const label = self.stepLabel(index);
                if (label.len == 0) continue;
                const label_w = metrics_value.measureSlice(label);
                const text_color = if (is_selected) self.style.text_selected_color else self.style.text_color;
                try batch.roleText(allocator, .{
                    .x = segment.x + @max((segment.w - label_w) * 0.5, 0.0),
                    .y = segment.y + @max((segment.h - metrics_value.line_height) * 0.5, 0.0),
                    .w = @min(label_w, segment.w),
                    .h = metrics_value.line_height,
                }, label, text_color, metrics_value.font_size, config.font_role, config.font_id, segment);
            }

            if (config.show_description and config.step_description != null) {
                const active = self.hovered orelse self.selected orelse return;
                const description = self.stepDescription(active);
                if (description.len == 0) return;
                const description_metrics = self.descriptionMetrics();
                try batch.roleText(allocator, .{
                    .x = self.rect.x,
                    .y = strip.y + strip.h + self.scaled(config.description_gap),
                    .w = self.rect.w,
                    .h = description_metrics.line_height,
                }, description, self.style.description_color, description_metrics.font_size, config.font_role, config.font_id, self.rect);
            }
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        fn handleKey(self: *Component, key: Key) bool {
            if (self.count == 0) return false;
            switch (key.code) {
                .left => {
                    const current = self.selected orelse 0;
                    if (current > 0) self.select(current - 1);
                    return true;
                },
                .right => {
                    const current = self.selected orelse 0;
                    if (self.selected == null) {
                        self.select(0);
                    } else if (current + 1 < self.count) {
                        self.select(current + 1);
                    }
                    return true;
                },
                .home => {
                    self.select(0);
                    return true;
                },
                .end => {
                    self.select(self.count - 1);
                    return true;
                },
                else => return false,
            }
        }

        fn select(self: *Component, index: usize) void {
            if (index >= self.count) return;
            const changed = self.selected == null or self.selected.? != index;
            if (changed and config.thumb_anim_ms > 0 and self.selected != null) {
                // Capture the thumb's current visual position (may be
                // mid-flight) so back-to-back selections stay continuous.
                self.anim_from_rect = self.thumbRect();
                self.anim_progress = 0.0;
            }
            self.selected = index;
            if (changed) self.emit(.{ .changed = index });
        }

        /// Current rect of the selected-segment thumb, interpolated while a
        /// slide animation is in flight; null when nothing is selected.
        fn thumbRect(self: *const Component) ?draw.Rect {
            const selected = self.selected orelse return null;
            if (selected >= self.count) return null;
            const target = self.segmentRect(selected);
            const from = self.anim_from_rect orelse return target;
            if (self.anim_progress >= 1.0) return target;
            const t = easeOutCubic(std.math.clamp(self.anim_progress, 0.0, 1.0));
            return .{
                .x = from.x + (target.x - from.x) * t,
                .y = from.y + (target.y - from.y) * t,
                .w = from.w + (target.w - from.w) * t,
                .h = from.h + (target.h - from.h) * t,
            };
        }

        fn scaled(self: *const Component, value: f32) f32 {
            return value * self.ui_scale;
        }

        fn stripRect(self: *const Component) draw.Rect {
            return .{
                .x = self.rect.x,
                .y = self.rect.y,
                .w = self.rect.w,
                .h = @min(self.scaled(config.segment_height), self.rect.h),
            };
        }

        pub fn segmentRect(self: *const Component, index: usize) draw.Rect {
            const strip = self.stripRect();
            const count_f = @as(f32, @floatFromInt(@max(self.count, 1)));
            const gap = self.scaled(config.segment_gap);
            const inner_pad = gap;
            const usable = @max(strip.w - inner_pad * 2.0 - gap * (count_f - 1.0), 0.0);
            const segment_w = usable / count_f;
            return .{
                .x = strip.x + inner_pad + @as(f32, @floatFromInt(index)) * (segment_w + gap),
                .y = strip.y + inner_pad * 0.5,
                .w = segment_w,
                .h = @max(strip.h - inner_pad, 0.0),
            };
        }

        fn segmentAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            if (!self.stripRect().contains(point)) return null;
            var index: usize = 0;
            while (index < self.count) : (index += 1) {
                var segment = self.segmentRect(index);
                // Treat the surrounding gap as part of the nearest segment so
                // clicks between pills still land.
                segment.x -= self.scaled(config.segment_gap) * 0.5;
                segment.w += self.scaled(config.segment_gap);
                segment.y = self.stripRect().y;
                segment.h = self.stripRect().h;
                if (segment.contains(point)) return index;
            }
            return null;
        }

        fn stepLabel(self: *const Component, index: usize) []const u8 {
            if (config.step_label) |callback| return callback(self.callbacks.context, index);
            return "";
        }

        fn stepDescription(self: *const Component, index: usize) []const u8 {
            if (config.step_description) |callback| return callback(self.callbacks.context, index);
            return "";
        }

        fn labelMetrics(self: *const Component) text_layout.FontMetrics {
            if (self.font_metrics) |metrics_value| return metrics_value;
            const size = self.scaled(config.font_size);
            return text_layout.FontMetrics.fixed(size, self.scaled(config.glyph_width), size * 1.3);
        }

        fn descriptionMetrics(self: *const Component) text_layout.FontMetrics {
            const size = self.scaled(config.description_font_size);
            return text_layout.FontMetrics.fixed(size, size * 0.55, size * 1.3);
        }

        fn emit(self: *Component, event: StepperEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }
    };
}

fn easeOutCubic(t: f32) f32 {
    const inverse = 1.0 - t;
    return 1.0 - inverse * inverse * inverse;
}

const TestSteps = struct {
    changed: ?usize = null,
    change_count: usize = 0,

    const labels = [_][]const u8{ "Low", "Medium", "High", "Xhigh" };
    const descriptions = [_][]const u8{ "Fastest", "Balanced", "Deeper", "Maximum depth" };

    fn label(_: ?*anyopaque, index: usize) []const u8 {
        return labels[index];
    }

    fn description(_: ?*anyopaque, index: usize) []const u8 {
        return descriptions[index];
    }

    fn onEvent(context: ?*anyopaque, event: StepperEvent) void {
        const self: *TestSteps = @ptrCast(@alignCast(context.?));
        switch (event) {
            .changed => |index| {
                self.changed = index;
                self.change_count += 1;
            },
            .hover_changed => {},
        }
    }
};

const TestStepper = Stepper(.{
    .segment_height = 24,
    .segment_gap = 4,
    .step_label = TestSteps.label,
    .step_description = TestSteps.description,
});

test "stepper selects steps by click and arrow keys" {
    var context: TestSteps = .{};
    var stepper = TestStepper.init(TestSteps.labels.len);
    stepper.setCallbacks(.{ .context = &context, .on_event = TestSteps.onEvent });
    stepper.setBounds(.{ .x = 0, .y = 0, .w = 240, .h = 40 });
    stepper.setSelected(1);

    const third = stepper.segmentRect(2);
    try std.testing.expect(stepper.handleInput(.{ .mouse_down = .{ .x = third.x + 2, .y = third.y + 2 } }));
    try std.testing.expectEqual(@as(?usize, 2), context.changed);

    try std.testing.expect(stepper.handleInput(.{ .key = .{ .code = .right } }));
    try std.testing.expectEqual(@as(?usize, 3), stepper.selected);
    // At the last step, right is consumed but does not wrap or re-emit.
    try std.testing.expect(stepper.handleInput(.{ .key = .{ .code = .right } }));
    try std.testing.expectEqual(@as(?usize, 3), stepper.selected);
    try std.testing.expect(stepper.handleInput(.{ .key = .{ .code = .left } }));
    try std.testing.expectEqual(@as(?usize, 2), stepper.selected);
    try std.testing.expect(stepper.handleInput(.{ .key = .{ .code = .home } }));
    try std.testing.expectEqual(@as(?usize, 0), stepper.selected);
    try std.testing.expect(stepper.handleInput(.{ .key = .{ .code = .end } }));
    try std.testing.expectEqual(@as(?usize, 3), stepper.selected);
}

test "stepper renders all segments plus the active description" {
    var context: TestSteps = .{};
    var stepper = TestStepper.init(TestSteps.labels.len);
    stepper.setCallbacks(.{ .context = &context, .on_event = TestSteps.onEvent });
    stepper.setBounds(.{ .x = 0, .y = 0, .w = 240, .h = stepper.requiredHeight() });
    stepper.setSelected(1);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try stepper.render(std.testing.allocator, &batch);

    var text_commands: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .text) text_commands += 1;
    }
    // 4 segment labels + 1 description line.
    try std.testing.expectEqual(@as(usize, 5), text_commands);
}

test "stepper slides the thumb on user selection and snaps on external sync" {
    var context: TestSteps = .{};
    var stepper = TestStepper.init(TestSteps.labels.len);
    stepper.setCallbacks(.{ .context = &context, .on_event = TestSteps.onEvent });
    stepper.setBounds(.{ .x = 0, .y = 0, .w = 240, .h = 40 });

    // External sync never animates.
    stepper.setSelected(0);
    try std.testing.expect(!stepper.isAnimating());

    // A click slides from the previous segment toward the new one.
    const third = stepper.segmentRect(2);
    _ = stepper.handleInput(.{ .mouse_down = .{ .x = third.x + 2, .y = third.y + 2 } });
    try std.testing.expect(stepper.isAnimating());
    stepper.tick(40);
    try std.testing.expect(stepper.isAnimating());
    const mid = stepper.thumbRect().?;
    try std.testing.expect(mid.x > stepper.segmentRect(0).x);
    try std.testing.expect(mid.x < third.x);

    stepper.tick(1000);
    try std.testing.expect(!stepper.isAnimating());
    try std.testing.expectEqual(third.x, stepper.thumbRect().?.x);

    // Re-syncing the same value must not cancel a running animation.
    _ = stepper.handleInput(.{ .mouse_down = .{ .x = stepper.segmentRect(0).x + 2, .y = third.y + 2 } });
    try std.testing.expect(stepper.isAnimating());
    stepper.setSelected(0);
    try std.testing.expect(stepper.isAnimating());
}

test "stepper hover highlights and reports the hovered description target" {
    var context: TestSteps = .{};
    var stepper = TestStepper.init(TestSteps.labels.len);
    stepper.setCallbacks(.{ .context = &context, .on_event = TestSteps.onEvent });
    stepper.setBounds(.{ .x = 0, .y = 0, .w = 240, .h = 40 });

    const second = stepper.segmentRect(1);
    try std.testing.expect(stepper.handleInput(.{ .mouse_move = .{ .x = second.x + 2, .y = second.y + 2 } }));
    try std.testing.expectEqual(@as(?usize, 1), stepper.hovered);
    _ = stepper.handleInput(.{ .mouse_move = .{ .x = -10, .y = -10 } });
    try std.testing.expectEqual(@as(?usize, null), stepper.hovered);
}
