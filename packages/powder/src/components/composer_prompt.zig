//! Renderer-neutral command prompt/composer visual model.

const std = @import("std");

const draw = @import("../draw.zig");
const text_layout = @import("../text_layout.zig");

pub const ComposerPromptConfig = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 640.0,
    height: f32 = 172.0,
    padding_x: f32 = 18.0,
    padding_y: f32 = 16.0,
    toolbar_height: f32 = 36.0,
    toolbar_gap: f32 = 8.0,
    control_gap: f32 = 8.0,
    separator_width: f32 = 1.0,
    corner_radius: f32 = 14.0,
    border_width: f32 = 1.0,
    background_color: draw.Color = .{ .r = 0.10, .g = 0.13, .b = 0.14, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.25, .g = 0.31, .b = 0.34, .a = 1.0 },
    control_background_color: draw.Color = .{ .r = 0.07, .g = 0.09, .b = 0.10, .a = 0.0 },
    control_hover_color: draw.Color = .{ .r = 0.18, .g = 0.22, .b = 0.24, .a = 0.62 },
    separator_color: draw.Color = .{ .r = 0.48, .g = 0.52, .b = 0.58, .a = 0.35 },
    send_color: draw.Color = .{ .r = 0.32, .g = 0.54, .b = 0.39, .a = 1.0 },
    send_hover_color: draw.Color = .{ .r = 0.38, .g = 0.64, .b = 0.47, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
    placeholder_color: draw.Color = .{ .r = 0.58, .g = 0.62, .b = 0.68, .a = 0.82 },
    icon_color: draw.Color = .{ .r = 0.78, .g = 0.82, .b = 0.88, .a = 1.0 },
    font_size: f32 = 16.0,
    toolbar_font_size: f32 = 14.0,
    icon_font_size: f32 = 16.0,
    font_role: ?draw.FontRole = .ui,
    bold_font_role: ?draw.FontRole = .ui_bold,
    icon_font_role: ?draw.FontRole = .icon,
    font_id: ?u32 = null,
    icon_font_id: ?u32 = null,
    placeholder: []const u8 = "Ask anything, or use / to show available commands",
    model_icon: []const u8 = "O",
    model_label: []const u8 = "GPT-5.5",
    reasoning_label: []const u8 = "Low",
    fast_icon: []const u8 = "~",
    fast_label: []const u8 = "Fast",
    access_icon: []const u8 = "L",
    access_label: []const u8 = "Full access",
    chevron_icon: []const u8 = ">",
    send_icon: []const u8 = "^",
    z_index: i32 = 0,
};

pub fn ComposerPrompt(comptime config: ComposerPromptConfig) type {
    return struct {
        const Component = @This();

        rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height },
        text_value: []const u8 = "",
        send_hovered: bool = false,
        z_index: i32 = config.z_index,

        pub fn init() Component {
            return .{};
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.rect = rect;
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn setText(self: *Component, value: []const u8) void {
            self.text_value = value;
        }

        pub fn setSendHovered(self: *Component, hovered: bool) void {
            self.send_hovered = hovered;
        }

        pub fn textRect(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            return .{
                .x = bounds_rect.x + config.padding_x,
                .y = bounds_rect.y + config.padding_y,
                .w = @max(bounds_rect.w - config.padding_x * 2.0, 0.0),
                .h = @max(bounds_rect.h - config.padding_y * 2.0 - config.toolbar_height - config.toolbar_gap, 0.0),
            };
        }

        pub fn toolbarRect(self: *const Component) draw.Rect {
            const bounds_rect = self.bounds();
            return .{
                .x = bounds_rect.x + config.padding_x,
                .y = bounds_rect.y + bounds_rect.h - config.padding_y - config.toolbar_height,
                .w = @max(bounds_rect.w - config.padding_x * 2.0, 0.0),
                .h = config.toolbar_height,
            };
        }

        pub fn sendButtonRect(self: *const Component) draw.Rect {
            const toolbar = self.toolbarRect();
            const size = @min(toolbar.h, 36.0);
            return .{
                .x = toolbar.x + toolbar.w - size,
                .y = toolbar.y + (toolbar.h - size) * 0.5,
                .w = size,
                .h = size,
            };
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const previous_z = batch.setZIndex(self.z_index);
            defer batch.restoreZIndex(previous_z);

            try batch.panel(allocator, self.bounds(), config.background_color, config.border_color, config.corner_radius, config.border_width);
            try self.renderPromptText(allocator, batch);
            try self.renderToolbar(allocator, batch);
        }

        fn renderPromptText(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const rect = self.textRect();
            const value = if (self.text_value.len == 0) config.placeholder else self.text_value;
            const color = if (self.text_value.len == 0) config.placeholder_color else config.text_color;
            const metrics = text_layout.FontMetrics.fallback(config.font_size);
            const runs = [_]draw.TextRun{.{
                .text = value,
                .byte_start = 0,
                .byte_end = value.len,
                .x = rect.x,
                .y = rect.y,
                .font_size = metrics.font_size,
                .line_height = metrics.line_height,
                .color = color,
                .clip = rect,
                .font_role = config.font_role,
                .font_id = config.font_id,
            }};
            try batch.textRuns(allocator, rect, value, &runs, color, metrics.font_size, rect, metrics.line_height, metrics.fixedAdvance());
        }

        fn renderToolbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const toolbar = self.toolbarRect();
            const send = self.sendButtonRect();
            const control_h = @min(toolbar.h, 32.0);
            var x = toolbar.x;
            const y = toolbar.y + (toolbar.h - control_h) * 0.5;
            const max_x = send.x - config.control_gap;

            const model_w = @min(140.0, @max(max_x - x, 0.0));
            try self.renderPill(allocator, batch, .{ .x = x, .y = y, .w = model_w, .h = control_h }, config.model_icon, config.model_label, config.chevron_icon);
            x += model_w + config.control_gap;
            try self.renderSeparator(allocator, batch, x - config.control_gap * 0.5, toolbar);

            const reasoning_w = @min(78.0, @max(max_x - x, 0.0));
            try self.renderPill(allocator, batch, .{ .x = x, .y = y, .w = reasoning_w, .h = control_h }, "", config.reasoning_label, config.chevron_icon);
            x += reasoning_w + config.control_gap;
            try self.renderSeparator(allocator, batch, x - config.control_gap * 0.5, toolbar);

            const fast_w = @min(70.0, @max(max_x - x, 0.0));
            try self.renderPill(allocator, batch, .{ .x = x, .y = y, .w = fast_w, .h = control_h }, config.fast_icon, config.fast_label, "");
            x += fast_w + config.control_gap;
            try self.renderSeparator(allocator, batch, x - config.control_gap * 0.5, toolbar);

            const access_w = @min(122.0, @max(max_x - x, 0.0));
            try self.renderPill(allocator, batch, .{ .x = x, .y = y, .w = access_w, .h = control_h }, config.access_icon, config.access_label, "");

            try batch.panel(allocator, send, if (self.send_hovered) config.send_hover_color else config.send_color, null, send.h * 0.5, 0.0);
            try self.renderCenteredIcon(allocator, batch, send, config.send_icon, draw.Color.white);
        }

        fn renderPill(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, rect: draw.Rect, left_icon: []const u8, label: []const u8, right_icon: []const u8) !void {
            _ = self;
            if (rect.w <= 0.0 or rect.h <= 0.0) return;
            try batch.panel(allocator, rect, config.control_background_color, null, rect.h * 0.5, 0.0);
            const text_metrics = text_layout.FontMetrics.fallback(config.toolbar_font_size);
            const icon_metrics = text_layout.FontMetrics.fallback(config.icon_font_size);
            var runs: [3]draw.TextRun = undefined;
            var count: usize = 0;
            var x = rect.x + 10.0;
            if (left_icon.len > 0) {
                runs[count] = iconRun(left_icon, x, rect, icon_metrics, config.icon_color);
                x += icon_metrics.measureSlice(left_icon) + 7.0;
                count += 1;
            }
            runs[count] = .{
                .text = label,
                .byte_start = 0,
                .byte_end = label.len,
                .x = x,
                .y = rect.y + @max((rect.h - text_metrics.line_height) * 0.5, 0.0),
                .font_size = text_metrics.font_size,
                .line_height = text_metrics.line_height,
                .color = config.text_color,
                .clip = rect,
                .font_role = config.bold_font_role,
                .font_id = config.font_id,
            };
            count += 1;
            if (right_icon.len > 0) {
                const icon_w = icon_metrics.measureSlice(right_icon);
                runs[count] = iconRun(right_icon, rect.x + rect.w - 10.0 - icon_w, rect, icon_metrics, config.icon_color);
                count += 1;
            }
            try batch.textRuns(allocator, rect, label, runs[0..count], config.text_color, text_metrics.font_size, rect, text_metrics.line_height, text_metrics.fixedAdvance());
        }

        fn renderCenteredIcon(_: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, rect: draw.Rect, icon: []const u8, color: draw.Color) !void {
            const metrics = text_layout.FontMetrics.fallback(config.icon_font_size);
            const width = metrics.measureSlice(icon);
            const runs = [_]draw.TextRun{.{
                .text = icon,
                .byte_start = 0,
                .byte_end = icon.len,
                .x = rect.x + (rect.w - width) * 0.5,
                .y = rect.y + (rect.h - metrics.line_height) * 0.5,
                .font_size = metrics.font_size,
                .line_height = metrics.line_height,
                .color = color,
                .clip = rect,
                .font_role = config.icon_font_role,
                .font_id = config.icon_font_id,
            }};
            try batch.textRuns(allocator, rect, icon, &runs, color, metrics.font_size, rect, metrics.line_height, metrics.fixedAdvance());
        }

        fn renderSeparator(_: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, x: f32, toolbar: draw.Rect) !void {
            try batch.rect(allocator, .{
                .x = x - config.separator_width * 0.5,
                .y = toolbar.y + 9.0,
                .w = config.separator_width,
                .h = @max(toolbar.h - 18.0, 0.0),
            }, config.separator_color);
        }

        fn iconRun(value: []const u8, x: f32, rect: draw.Rect, metrics: text_layout.FontMetrics, color: draw.Color) draw.TextRun {
            return .{
                .text = value,
                .byte_start = 0,
                .byte_end = value.len,
                .x = x,
                .y = rect.y + @max((rect.h - metrics.line_height) * 0.5, 0.0),
                .font_size = metrics.font_size,
                .line_height = metrics.line_height,
                .color = color,
                .clip = rect,
                .font_role = config.icon_font_role,
                .font_id = config.icon_font_id,
            };
        }
    };
}

test "composer prompt emits styled font-role commands" {
    const Prompt = ComposerPrompt(.{});
    var prompt = Prompt.init();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);

    try prompt.render(std.testing.allocator, &batch);

    var icon_runs: usize = 0;
    var rounded_send = false;
    for (batch.commands.items) |command| {
        if (command.kind == .text) {
            for (command.text_runs) |run| {
                if (run.font_role == .icon) icon_runs += 1;
            }
        }
        if (command.kind == .rect and command.radius >= 16.0 and command.color.g > 0.4) rounded_send = true;
    }
    try std.testing.expect(icon_runs >= 4);
    try std.testing.expect(rounded_send);
}
