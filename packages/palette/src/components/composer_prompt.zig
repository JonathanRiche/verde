//! Renderer-neutral command prompt/composer visual model.

const std = @import("std");

const draw = @import("../draw.zig");
const clipboard = @import("../input/clipboard.zig");
const key_input = @import("../input/key.zig");
const scroll = @import("../scroll.zig");
const selection_input = @import("../input/selection.zig");
const sdl = @import("../sdl.zig");
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
    stop_button_color: draw.Color = .{ .r = 0.78, .g = 0.58, .b = 0.10, .a = 1.0 },
    stop_button_hover_color: draw.Color = .{ .r = 0.90, .g = 0.68, .b = 0.14, .a = 1.0 },
    text_color: draw.Color = draw.Color.white,
    placeholder_color: draw.Color = .{ .r = 0.58, .g = 0.62, .b = 0.68, .a = 0.82 },
    icon_color: draw.Color = .{ .r = 0.78, .g = 0.82, .b = 0.88, .a = 1.0 },
    font_size: f32 = 16.0,
    toolbar_font_size: f32 = 14.0,
    icon_font_size: f32 = 16.0,
    fixed_advance: ?f32 = null,
    toolbar_fixed_advance: ?f32 = null,
    icon_fixed_advance: ?f32 = null,
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
    stop_icon: []const u8 = "x",
    pending_icon: []const u8 = ".",
    cursor_color: draw.Color = draw.Color.white,
    selection_color: draw.Color = .{ .r = 0.18, .g = 0.42, .b = 0.72, .a = 0.55 },
    scrollbar_track_color: draw.Color = .{ .r = 0.18, .g = 0.20, .b = 0.23, .a = 0.42 },
    scrollbar_thumb_color: draw.Color = .{ .r = 0.62, .g = 0.70, .b = 0.82, .a = 0.78 },
    scrollbar_width: f32 = 4.0,
    scroll_enabled: bool = true,
    menu_background_color: draw.Color = .{ .r = 0.07, .g = 0.09, .b = 0.10, .a = 0.98 },
    menu_border_color: draw.Color = .{ .r = 0.25, .g = 0.31, .b = 0.34, .a = 1.0 },
    menu_selected_color: draw.Color = .{ .r = 0.18, .g = 0.34, .b = 0.44, .a = 0.85 },
    menu_hover_color: draw.Color = .{ .r = 0.22, .g = 0.27, .b = 0.30, .a = 0.85 },
    row_height: f32 = 28.0,
    pill_padding_x: f32 = 10.0,
    pill_icon_gap: f32 = 7.0,
    pill_chevron_gap: f32 = 8.0,
    model_min_width: f32 = 0.0,
    model_max_width: f32 = 180.0,
    reasoning_min_width: f32 = 0.0,
    reasoning_max_width: f32 = 150.0,
    fast_min_width: f32 = 0.0,
    fast_max_width: f32 = 120.0,
    access_min_width: f32 = 0.0,
    access_max_width: f32 = 170.0,
    z_index: i32 = 0,
};

pub const ComposerPromptPart = enum {
    model,
    reasoning,
    fast,
    access,
    send,
};

pub const ComposerPromptSendState = enum {
    send,
    stop,
    disabled,
    pending,
};

pub const ComposerPromptOptionTarget = enum {
    model,
    reasoning,
};

pub const ComposerPromptOptionLabelFn = *const fn (context: ?*anyopaque, index: usize) []const u8;

pub const ComposerPromptInput = union(enum) {
    text: []const u8,
    key: key_input,
    mouse_move: draw.Vec2,
    mouse_down: draw.Vec2,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    mouse_wheel: MouseWheel,
    focus: bool,
};

pub const MouseWheel = struct {
    point: draw.Vec2,
    y: f32,
};

const MAX_EDIT_HISTORY = 64;

const EditSnapshot = struct {
    text: []u8,
    cursor: usize,
    selection_anchor: ?usize,
    selection_focus: ?usize,

    fn capture(allocator: std.mem.Allocator, component: anytype) !EditSnapshot {
        return .{
            .text = try allocator.dupe(u8, component.buffer.items),
            .cursor = component.cursor,
            .selection_anchor = component.selection_anchor,
            .selection_focus = component.selection_focus,
        };
    }

    fn deinit(self: EditSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const ComposerPromptEvent = union(enum) {
    text_changed: []const u8,
    submitted: []const u8,
    model_clicked,
    model_changed: usize,
    reasoning_clicked,
    reasoning_changed: usize,
    fast_changed: bool,
    access_changed: bool,
    send_clicked,
    focus_changed: bool,
};

pub const ComposerPromptCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: ComposerPromptEvent) void = null,
    get_clipboard: ?*const fn (context: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 = null,

    fn clipboardProvider(self: ComposerPromptCallbacks) clipboard {
        return .{ .context = self.context, .get = self.get_clipboard };
    }
};

const Options = struct {
    context: ?*anyopaque = null,
    count: usize = 0,
    label: ?ComposerPromptOptionLabelFn = null,

    fn labelFor(self: Options, index: usize) ?[]const u8 {
        if (index >= self.count) return null;
        if (self.label) |callback| return callback(self.context, index);
        return null;
    }
};

pub fn ComposerPrompt(comptime config: ComposerPromptConfig) type {
    return struct {
        const Component = @This();

        rect: draw.Rect = .{ .x = config.x, .y = config.y, .w = config.width, .h = config.height },
        buffer: std.ArrayList(u8) = .empty,
        cursor: usize = 0,
        selection_anchor: ?usize = null,
        selection_focus: ?usize = null,
        scroll_y: f32 = 0.0,
        dragging_selection: bool = false,
        placeholder_buffer: std.ArrayList(u8) = .empty,
        model_label_buffer: std.ArrayList(u8) = .empty,
        reasoning_label_buffer: std.ArrayList(u8) = .empty,
        fast_label_buffer: std.ArrayList(u8) = .empty,
        access_label_buffer: std.ArrayList(u8) = .empty,
        model_options: Options = .{},
        reasoning_options: Options = .{},
        model_index: ?usize = null,
        reasoning_index: ?usize = null,
        active_menu: ?ComposerPromptOptionTarget = null,
        hovered_menu_index: ?usize = null,
        hovered_part: ?ComposerPromptPart = null,
        focused: bool = false,
        show_fast_toggle: bool = true,
        fast_enabled: bool = false,
        access_enabled: bool = false,
        send_state: ComposerPromptSendState = .send,
        undo_stack: std.ArrayList(EditSnapshot) = .empty,
        redo_stack: std.ArrayList(EditSnapshot) = .empty,
        font_metrics: ?text_layout.FontMetrics = null,
        toolbar_font_metrics: ?text_layout.FontMetrics = null,
        icon_font_metrics: ?text_layout.FontMetrics = null,
        z_index: i32 = config.z_index,
        callbacks: ComposerPromptCallbacks = .{},

        pub fn setShowFastToggle(self: *Component, show: bool) void {
            self.show_fast_toggle = show;
            if (!show) {
                self.hovered_part = if (self.hovered_part == .fast) null else self.hovered_part;
            }
        }

        pub fn showFastToggle(self: *const Component) bool {
            return self.show_fast_toggle;
        }

        pub fn init() Component {
            return .{};
        }

        pub fn deinit(self: *Component, allocator: std.mem.Allocator) void {
            self.buffer.deinit(allocator);
            self.placeholder_buffer.deinit(allocator);
            self.model_label_buffer.deinit(allocator);
            self.reasoning_label_buffer.deinit(allocator);
            self.fast_label_buffer.deinit(allocator);
            self.access_label_buffer.deinit(allocator);
            self.clearEditHistory(allocator);
            self.undo_stack.deinit(allocator);
            self.redo_stack.deinit(allocator);
            self.* = undefined;
        }

        pub fn setBounds(self: *Component, rect: draw.Rect) void {
            self.rect = rect;
            self.setScrollY(self.scroll_y);
        }

        pub fn bounds(self: *const Component) draw.Rect {
            return self.rect;
        }

        pub fn setCallbacks(self: *Component, callbacks: ComposerPromptCallbacks) void {
            self.callbacks = callbacks;
        }

        pub fn setFontMetrics(self: *Component, metrics: text_layout.FontMetrics) void {
            self.font_metrics = metrics;
            self.setScrollY(self.scroll_y);
        }

        pub fn setToolbarFontMetrics(self: *Component, metrics: text_layout.FontMetrics) void {
            self.toolbar_font_metrics = metrics;
        }

        pub fn setIconFontMetrics(self: *Component, metrics: text_layout.FontMetrics) void {
            self.icon_font_metrics = metrics;
        }

        pub fn setText(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(allocator, value);
            self.cursor = self.buffer.items.len;
            self.selection_anchor = null;
            self.selection_focus = null;
            self.clearEditHistory(allocator);
            self.ensureCursorVisible();
            self.emit(.{ .text_changed = self.buffer.items });
        }

        pub fn text(self: *const Component) []const u8 {
            return self.buffer.items;
        }

        pub fn selection(self: *const Component) ?selection_input.Range {
            const state: selection_input = .{ .anchor = self.selection_anchor, .focus = self.selection_focus };
            return state.normalized(self.buffer.items.len);
        }

        pub fn scrollY(self: *const Component) f32 {
            return self.scroll_y;
        }

        pub fn setScrollY(self: *Component, value: f32) void {
            self.scroll_y = scroll.clampOffsetY(value, self.scrollMetrics());
        }

        pub fn contentHeight(self: *const Component) f32 {
            return text_layout.contentHeight(self.buffer.items, self.textMetrics(), self.textRect().w, true);
        }

        pub fn maxScrollY(self: *const Component) f32 {
            return scroll.maxOffsetY(self.scrollMetrics());
        }

        pub fn setPlaceholder(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            try setOwnedString(allocator, &self.placeholder_buffer, value);
        }

        pub fn setModelLabel(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            try setOwnedString(allocator, &self.model_label_buffer, value);
        }

        pub fn setReasoningLabel(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            try setOwnedString(allocator, &self.reasoning_label_buffer, value);
        }

        pub fn setFastLabel(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            try setOwnedString(allocator, &self.fast_label_buffer, value);
        }

        pub fn setAccessLabel(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            try setOwnedString(allocator, &self.access_label_buffer, value);
        }

        pub fn setSendState(self: *Component, state: ComposerPromptSendState) void {
            self.send_state = state;
        }

        pub fn setModelOptions(self: *Component, context: ?*anyopaque, count: usize, label: ?ComposerPromptOptionLabelFn) void {
            self.model_options = .{ .context = context, .count = count, .label = label };
            if (self.model_index) |index| {
                if (index >= count) self.model_index = null;
            }
        }

        pub fn setReasoningOptions(self: *Component, context: ?*anyopaque, count: usize, label: ?ComposerPromptOptionLabelFn) void {
            self.reasoning_options = .{ .context = context, .count = count, .label = label };
            if (self.reasoning_index) |index| {
                if (index >= count) self.reasoning_index = null;
            }
        }

        pub fn setOptions(self: *Component, target: ComposerPromptOptionTarget, context: ?*anyopaque, count: usize, label: ?ComposerPromptOptionLabelFn) void {
            switch (target) {
                .model => self.setModelOptions(context, count, label),
                .reasoning => self.setReasoningOptions(context, count, label),
            }
        }

        pub fn handleInput(self: *Component, allocator: std.mem.Allocator, input: ComposerPromptInput) !bool {
            switch (input) {
                .text => |value| {
                    if (!self.focused) return false;
                    try self.insertText(allocator, value);
                    return true;
                },
                .key => |key| return try self.handleKey(allocator, key),
                .mouse_move => |point| {
                    const changed = self.updateHover(point);
                    const previous_index = self.hovered_menu_index;
                    self.hovered_menu_index = self.menuIndexAtPoint(point);
                    return changed or previous_index != self.hovered_menu_index;
                },
                .mouse_down => |point| return try self.handleMouseDown(allocator, point),
                .mouse_drag => |point| return self.handleMouseDrag(point),
                .mouse_up => {
                    const was_dragging = self.dragging_selection;
                    self.dragging_selection = false;
                    return was_dragging;
                },
                .mouse_wheel => |wheel| {
                    if (!self.textRect().contains(wheel.point)) return false;
                    self.scrollBy(-wheel.y * self.textMetrics().line_height * 3.0);
                    return true;
                },
                .focus => |focused| {
                    const changed = self.focused != focused;
                    self.setFocused(focused);
                    return changed;
                },
            }
        }

        pub fn update(self: *Component, allocator: std.mem.Allocator, event: *const sdl.Event) !bool {
            switch (event.type) {
                .text_input => return try self.handleInput(allocator, .{ .text = std.mem.span(event.text.text) }),
                .key_down => return try self.handleInput(allocator, .{ .key = key_input.fromSdl(event.key) orelse return false }),
                .mouse_motion => {
                    const point: draw.Vec2 = .{ .x = event.motion.x, .y = event.motion.y };
                    if (self.dragging_selection or event.motion.state.left) return try self.handleInput(allocator, .{ .mouse_drag = point });
                    return try self.handleInput(allocator, .{ .mouse_move = point });
                },
                .mouse_button_down => return try self.handleInput(allocator, .{ .mouse_down = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_button_up => return try self.handleInput(allocator, .{ .mouse_up = .{ .x = event.button.x, .y = event.button.y } }),
                .mouse_wheel => return try self.handleInput(allocator, .{ .mouse_wheel = .{ .point = .{ .x = event.wheel.mouse_x, .y = event.wheel.mouse_y }, .y = event.wheel.y } }),
                else => return false,
            }
        }

        pub fn setSendHovered(self: *Component, hovered: bool) void {
            self.hovered_part = if (hovered) .send else null;
        }

        pub fn setHoveredPart(self: *Component, part: ?ComposerPromptPart) void {
            self.hovered_part = part;
        }

        pub fn updateHover(self: *Component, point: draw.Vec2) bool {
            const previous = self.hovered_part;
            self.hovered_part = self.hitTest(point);
            return previous != self.hovered_part;
        }

        pub fn hitTest(self: *const Component, point: draw.Vec2) ?ComposerPromptPart {
            const geometry = self.toolbarGeometry();
            if (geometry.send.contains(point)) return .send;
            if (geometry.model.contains(point)) return .model;
            if (geometry.reasoning.contains(point)) return .reasoning;
            if (self.show_fast_toggle and geometry.fast.w > 0.0 and geometry.fast.contains(point)) return .fast;
            if (geometry.access.contains(point)) return .access;
            return null;
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
            return self.toolbarGeometry().send;
        }

        pub fn modelRect(self: *const Component) draw.Rect {
            return self.toolbarGeometry().model;
        }

        pub fn reasoningRect(self: *const Component) draw.Rect {
            return self.toolbarGeometry().reasoning;
        }

        pub fn fastRect(self: *const Component) draw.Rect {
            return self.toolbarGeometry().fast;
        }

        pub fn accessRect(self: *const Component) draw.Rect {
            return self.toolbarGeometry().access;
        }

        pub fn render(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const previous_z = batch.setZIndex(self.z_index);
            defer batch.restoreZIndex(previous_z);

            try batch.panel(allocator, self.bounds(), config.background_color, config.border_color, config.corner_radius, config.border_width);
            try self.renderPromptText(allocator, batch);
            try self.renderToolbar(allocator, batch);
            try self.renderMenu(allocator, batch);
            try self.renderScrollbar(allocator, batch);
        }

        fn renderPromptText(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const rect = self.textRect();
            const placeholder = self.placeholderText();
            const value = if (self.buffer.items.len == 0) placeholder else self.buffer.items;
            const color = if (self.buffer.items.len == 0) config.placeholder_color else config.text_color;
            const metrics = self.textMetrics();
            var runs: std.ArrayList(draw.TextRun) = .empty;
            defer runs.deinit(allocator);
            try text_layout.appendRuns(allocator, self.textLayoutOptions(value, color), &runs);
            if (self.selection()) |range| try self.renderSelection(allocator, batch, range);
            try batch.textRuns(allocator, rect, value, runs.items, color, metrics.font_size, rect, metrics.line_height, metrics.fixedAdvance());
            if (self.focused and self.buffer.items.len > 0) {
                const cursor = self.cursorRect();
                if (clippedRect(cursor, rect)) |clipped| try batch.cursor(allocator, clipped, config.cursor_color);
            }
        }

        fn renderToolbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const geometry = self.toolbarGeometry();
            try self.renderPill(allocator, batch, geometry.model, config.model_icon, self.modelLabel(), config.chevron_icon, self.hovered_part == .model or self.active_menu == .model);
            try self.renderSeparator(allocator, batch, separatorX(geometry.model, geometry.reasoning), geometry.toolbar);

            try self.renderPill(allocator, batch, geometry.reasoning, "", self.reasoningLabel(), config.chevron_icon, self.hovered_part == .reasoning or self.active_menu == .reasoning);
            if (self.show_fast_toggle) {
                try self.renderSeparator(allocator, batch, separatorX(geometry.reasoning, geometry.fast), geometry.toolbar);
                try self.renderPill(allocator, batch, geometry.fast, config.fast_icon, self.fastLabel(), "", self.hovered_part == .fast or self.fast_enabled);
                try self.renderSeparator(allocator, batch, separatorX(geometry.fast, geometry.access), geometry.toolbar);
            } else {
                try self.renderSeparator(allocator, batch, separatorX(geometry.reasoning, geometry.access), geometry.toolbar);
            }

            try self.renderPill(allocator, batch, geometry.access, config.access_icon, self.accessLabel(), "", self.hovered_part == .access or self.access_enabled);

            const send_disabled = self.send_state == .disabled or self.send_state == .pending;
            const send_panel_color: draw.Color = blk: {
                if (send_disabled)
                    break :blk draw.Color{ .r = config.send_color.r, .g = config.send_color.g, .b = config.send_color.b, .a = 0.48 };
                if (self.send_state == .stop) {
                    if (self.hovered_part == .send) break :blk config.stop_button_hover_color;
                    break :blk config.stop_button_color;
                }
                if (self.hovered_part == .send) break :blk config.send_hover_color;
                break :blk config.send_color;
            };
            try batch.panel(allocator, geometry.send, send_panel_color, null, geometry.send.h * 0.5, 0.0);
            if (self.send_state == .stop) {
                try renderStopSquare(allocator, batch, geometry.send);
            } else if (self.send_state == .pending) {
                try self.renderCenteredIcon(allocator, batch, geometry.send, self.sendIcon(), draw.Color.white);
            } else {
                try renderSendArrow(allocator, batch, geometry.send);
            }
        }

        fn renderPill(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, rect: draw.Rect, left_icon: []const u8, label: []const u8, right_icon: []const u8, hovered: bool) !void {
            if (rect.w <= 0.0 or rect.h <= 0.0) return;
            try batch.panel(allocator, rect, if (hovered) config.control_hover_color else config.control_background_color, null, rect.h * 0.5, 0.0);
            const text_metrics = self.toolbarMetrics();
            const icon_metrics = self.iconMetrics();
            var runs: [3]draw.TextRun = undefined;
            var count: usize = 0;
            var x = rect.x + config.pill_padding_x;
            if (left_icon.len > 0) {
                runs[count] = iconRun(left_icon, x, rect, icon_metrics, config.icon_color);
                x += icon_metrics.measureSlice(left_icon) + config.pill_icon_gap;
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
                runs[count] = iconRun(right_icon, rect.x + rect.w - config.pill_padding_x - icon_w, rect, icon_metrics, config.icon_color);
                count += 1;
            }
            try batch.textRuns(allocator, rect, label, runs[0..count], config.text_color, text_metrics.font_size, rect, text_metrics.line_height, text_metrics.fixedAdvance());
        }

        fn renderCenteredIcon(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, rect: draw.Rect, icon: []const u8, color: draw.Color) !void {
            if (icon.len == 0) return;
            const metrics = self.iconMetrics();
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

        fn sendGlyphBounds(button: draw.Rect) draw.Rect {
            const m = @min(button.w, button.h);
            const inset = m * 0.125;
            return .{
                .x = button.x + inset,
                .y = button.y + inset,
                .w = @max(button.w - 2.0 * inset, 1.0),
                .h = @max(button.h - 2.0 * inset, 1.0),
            };
        }

        fn renderStopSquare(allocator: std.mem.Allocator, batch: *draw.RenderBatch, button: draw.Rect) !void {
            const inner = sendGlyphBounds(button);
            const m = @min(inner.w, inner.h);
            const side = m * 0.52;
            const cx = inner.x + inner.w * 0.5;
            const cy = inner.y + inner.h * 0.5;
            const cr = @max(side * 0.18, 1.5);
            try batch.roundedRectClipped(allocator, .{
                .x = cx - side * 0.5,
                .y = cy - side * 0.5,
                .w = side,
                .h = side,
            }, draw.Color.white, cr, button);
        }

        /// Send: wide triangular head + narrow stem (same-width stem under an equilateral head reads as a "house").
        fn renderSendArrow(allocator: std.mem.Allocator, batch: *draw.RenderBatch, button: draw.Rect) !void {
            const inner = sendGlyphBounds(button);
            const m = @min(inner.w, inner.h);
            const cx = inner.x + inner.w * 0.5;
            const total_h = m * 0.56;
            const head_h = total_h * 0.52;
            const stem_h = total_h * 0.48;
            const half_w_head = m * 0.175;
            const half_w_stem = @max(m * 0.052, 1.25);
            const y0 = inner.y + (inner.h - total_h) * 0.5;
            // Stem under the head so the junction is a narrow shaft, not a full-width block.
            try batch.rectClipped(allocator, .{
                .x = cx - half_w_stem,
                .y = y0 + head_h,
                .w = half_w_stem * 2.0,
                .h = stem_h,
            }, draw.Color.white, button);
            try batch.triangleClipped(
                allocator,
                .{ .x = cx, .y = y0 },
                .{ .x = cx - half_w_head, .y = y0 + head_h },
                .{ .x = cx + half_w_head, .y = y0 + head_h },
                draw.Color.white,
                button,
            );
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

        fn renderMenu(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const target = self.active_menu orelse return;
            const options = self.optionsFor(target);
            if (options.count == 0) return;
            const rect = self.menuRect(target);
            const previous_z = batch.setZIndex(self.z_index + 1000);
            defer batch.restoreZIndex(previous_z);
            const menu_corner: f32 = 14.0;
            try batch.panel(allocator, rect, config.menu_background_color, config.menu_border_color, menu_corner, 1.0);
            const metrics = self.toolbarMetrics();
            const row_corner = @min(9.0, @max(4.0, metrics.line_height * 0.38));
            var index: usize = 0;
            while (index < options.count) : (index += 1) {
                const row = self.menuRowRect(target, index);
                if (self.selectedIndex(target) == index) {
                    try batch.roundedRectClipped(allocator, row, config.menu_selected_color, row_corner, rect);
                } else if (self.hovered_menu_index == index) {
                    try batch.roundedRectClipped(allocator, row, config.menu_hover_color, row_corner, rect);
                }
                const label = options.labelFor(index) orelse continue;
                const text_rect: draw.Rect = .{
                    .x = row.x + config.pill_padding_x,
                    .y = row.y + @max((row.h - metrics.line_height) * 0.5, 0.0),
                    .w = @max(row.w - config.pill_padding_x * 2.0, 0.0),
                    .h = metrics.line_height,
                };
                const runs = [_]draw.TextRun{.{
                    .text = label,
                    .byte_start = 0,
                    .byte_end = label.len,
                    .x = text_rect.x,
                    .y = text_rect.y,
                    .font_size = metrics.font_size,
                    .line_height = metrics.line_height,
                    .color = config.text_color,
                    .clip = rect,
                    .font_role = config.font_role,
                    .font_id = config.font_id,
                }};
                try batch.textRuns(allocator, text_rect, label, &runs, config.text_color, metrics.font_size, rect, metrics.line_height, metrics.fixedAdvance());
            }
        }

        fn handleKey(self: *Component, allocator: std.mem.Allocator, key: key_input) !bool {
            if (self.active_menu) |target| {
                if (key.code == .escape) {
                    self.active_menu = null;
                    self.hovered_menu_index = null;
                    return true;
                }
                if (key.code == .enter) {
                    if (self.hovered_menu_index) |index| {
                        try self.selectOption(allocator, target, index);
                        return true;
                    }
                }
            }
            if (!self.focused and key.code != .escape) return false;
            switch (key.code) {
                .escape => {
                    self.active_menu = null;
                    self.setFocused(false);
                    return true;
                },
                .backspace => {
                    if (self.selection()) |_| {
                        try self.replaceSelection(allocator, "");
                        return true;
                    }
                    if (self.cursor == 0) return true;
                    const start = selection_input.previousOffset(self.buffer.items, self.cursor);
                    try self.replaceRange(allocator, start, self.cursor, "");
                    return true;
                },
                .delete => {
                    if (self.selection()) |_| {
                        try self.replaceSelection(allocator, "");
                        return true;
                    }
                    if (self.cursor >= self.buffer.items.len) return true;
                    try self.replaceRange(allocator, self.cursor, selection_input.nextOffset(self.buffer.items, self.cursor), "");
                    return true;
                },
                .left => {
                    self.moveCursor(selection_input.previousOffset(self.buffer.items, self.cursor), key.shift);
                    return true;
                },
                .right => {
                    self.moveCursor(selection_input.nextOffset(self.buffer.items, self.cursor), key.shift);
                    return true;
                },
                .home => {
                    self.moveCursor(selection_input.lineStart(self.buffer.items, self.cursor), key.shift);
                    return true;
                },
                .end => {
                    self.moveCursor(selection_input.lineEnd(self.buffer.items, self.cursor), key.shift);
                    return true;
                },
                .enter => {
                    if (key.primary) {
                        self.submit();
                    } else {
                        try self.insertText(allocator, "\n");
                    }
                    return true;
                },
                .v => {
                    if (!key.primary) return false;
                    return try self.pasteClipboard(allocator);
                },
                .z => {
                    if (!key.primary) return false;
                    if (key.shift) try self.redo(allocator) else try self.undo(allocator);
                    return true;
                },
                .y => {
                    if (!key.primary) return false;
                    try self.redo(allocator);
                    return true;
                },
                else => return false,
            }
        }

        fn handleMouseDown(self: *Component, allocator: std.mem.Allocator, point: draw.Vec2) !bool {
            if (self.active_menu) |target| {
                if (self.menuIndexAtPoint(point)) |index| {
                    try self.selectOption(allocator, target, index);
                    return true;
                }
                if (!self.menuRect(target).contains(point)) {
                    self.active_menu = null;
                    self.hovered_menu_index = null;
                }
            }
            if (self.textRect().contains(point)) {
                self.setFocused(true);
                self.cursor = text_layout.offsetForPoint(self.textLayoutOptions(self.buffer.items, config.text_color), point);
                self.selection_anchor = self.cursor;
                self.selection_focus = self.cursor;
                self.dragging_selection = true;
                return true;
            }
            if (self.hitTest(point)) |part| {
                self.setFocused(false);
                self.hovered_part = part;
                switch (part) {
                    .model => {
                        self.toggleMenu(.model);
                        self.emit(.model_clicked);
                    },
                    .reasoning => {
                        self.toggleMenu(.reasoning);
                        self.emit(.reasoning_clicked);
                    },
                    .fast => {
                        self.fast_enabled = !self.fast_enabled;
                        self.emit(.{ .fast_changed = self.fast_enabled });
                    },
                    .access => {
                        self.access_enabled = !self.access_enabled;
                        self.emit(.{ .access_changed = self.access_enabled });
                    },
                    .send => {
                        if (self.send_state != .disabled and self.send_state != .pending) {
                            self.emit(.send_clicked);
                            if (self.send_state == .send) self.submit();
                        }
                    },
                }
                return true;
            }
            self.setFocused(false);
            self.hovered_part = null;
            return false;
        }

        fn handleMouseDrag(self: *Component, point: draw.Vec2) bool {
            if (!self.dragging_selection) return false;
            if (self.selection_anchor == null) self.selection_anchor = self.cursor;
            self.cursor = text_layout.offsetForPoint(self.textLayoutOptions(self.buffer.items, config.text_color), point);
            self.selection_focus = self.cursor;
            self.autoScrollForDrag(point);
            self.ensureCursorVisible();
            return true;
        }

        fn insertText(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            if (value.len == 0) return;
            if (self.selection()) |_| return self.replaceSelection(allocator, value);
            try self.replaceRange(allocator, self.cursor, self.cursor, value);
        }

        fn replaceSelection(self: *Component, allocator: std.mem.Allocator, value: []const u8) !void {
            const range = self.selection() orelse return self.replaceRange(allocator, self.cursor, self.cursor, value);
            try self.replaceRange(allocator, range.start, range.end, value);
        }

        fn pasteClipboard(self: *Component, allocator: std.mem.Allocator) !bool {
            const clipboard_text = self.callbacks.clipboardProvider().read(allocator) orelse return false;
            defer allocator.free(clipboard_text);
            if (clipboard_text.len == 0) return false;
            try self.replaceSelection(allocator, clipboard_text);
            return true;
        }

        fn replaceRange(self: *Component, allocator: std.mem.Allocator, start: usize, end: usize, value: []const u8) !void {
            const safe_start = @min(start, self.buffer.items.len);
            const safe_end = @min(@max(end, safe_start), self.buffer.items.len);
            try self.recordUndoSnapshot(allocator);
            self.buffer.replaceRange(allocator, safe_start, safe_end - safe_start, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            self.clearRedoStack(allocator);
            self.cursor = safe_start + value.len;
            self.selection_anchor = null;
            self.selection_focus = null;
            self.ensureCursorVisible();
            self.emit(.{ .text_changed = self.buffer.items });
        }

        fn undo(self: *Component, allocator: std.mem.Allocator) !void {
            const snapshot = self.undo_stack.pop() orelse return;
            defer snapshot.deinit(allocator);
            try self.redo_stack.append(allocator, try EditSnapshot.capture(allocator, self));
            try self.restoreSnapshot(allocator, snapshot);
        }

        fn redo(self: *Component, allocator: std.mem.Allocator) !void {
            const snapshot = self.redo_stack.pop() orelse return;
            defer snapshot.deinit(allocator);
            try self.undo_stack.append(allocator, try EditSnapshot.capture(allocator, self));
            try self.restoreSnapshot(allocator, snapshot);
        }

        fn restoreSnapshot(self: *Component, allocator: std.mem.Allocator, snapshot: EditSnapshot) !void {
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(allocator, snapshot.text);
            self.cursor = @min(snapshot.cursor, self.buffer.items.len);
            self.selection_anchor = snapshot.selection_anchor;
            self.selection_focus = snapshot.selection_focus;
            self.ensureCursorVisible();
            self.emit(.{ .text_changed = self.buffer.items });
        }

        fn recordUndoSnapshot(self: *Component, allocator: std.mem.Allocator) !void {
            try self.undo_stack.append(allocator, try EditSnapshot.capture(allocator, self));
            while (self.undo_stack.items.len > MAX_EDIT_HISTORY) {
                const dropped = self.undo_stack.orderedRemove(0);
                dropped.deinit(allocator);
            }
        }

        fn clearEditHistory(self: *Component, allocator: std.mem.Allocator) void {
            self.clearUndoStack(allocator);
            self.clearRedoStack(allocator);
        }

        fn clearUndoStack(self: *Component, allocator: std.mem.Allocator) void {
            for (self.undo_stack.items) |snapshot| snapshot.deinit(allocator);
            self.undo_stack.clearRetainingCapacity();
        }

        fn clearRedoStack(self: *Component, allocator: std.mem.Allocator) void {
            for (self.redo_stack.items) |snapshot| snapshot.deinit(allocator);
            self.redo_stack.clearRetainingCapacity();
        }

        fn moveCursor(self: *Component, next: usize, extend_selection: bool) void {
            const old = self.cursor;
            self.cursor = @min(next, self.buffer.items.len);
            if (extend_selection) {
                if (self.selection_anchor == null) self.selection_anchor = old;
                self.selection_focus = self.cursor;
            } else {
                self.selection_anchor = null;
                self.selection_focus = null;
            }
            self.ensureCursorVisible();
        }

        fn autoScrollForDrag(self: *Component, point: draw.Vec2) void {
            const text_rect = self.textRect();
            if (point.y < text_rect.y) {
                self.scrollBy(-self.textMetrics().line_height);
            } else if (point.y > text_rect.y + text_rect.h) {
                self.scrollBy(self.textMetrics().line_height);
            }
        }

        fn submit(self: *Component) void {
            self.emit(.{ .submitted = self.buffer.items });
        }

        fn toggleMenu(self: *Component, target: ComposerPromptOptionTarget) void {
            if (self.active_menu == target) {
                self.active_menu = null;
                self.hovered_menu_index = null;
            } else {
                self.active_menu = target;
                self.hovered_menu_index = self.selectedIndex(target) orelse 0;
            }
        }

        fn selectOption(self: *Component, allocator: std.mem.Allocator, target: ComposerPromptOptionTarget, index: usize) !void {
            const options = self.optionsFor(target);
            if (index >= options.count) return;
            switch (target) {
                .model => {
                    self.model_index = index;
                    if (options.labelFor(index)) |label| try self.setModelLabel(allocator, label);
                    self.emit(.{ .model_changed = index });
                },
                .reasoning => {
                    self.reasoning_index = index;
                    if (options.labelFor(index)) |label| try self.setReasoningLabel(allocator, label);
                    self.emit(.{ .reasoning_changed = index });
                },
            }
            self.active_menu = null;
            self.hovered_menu_index = null;
        }

        fn setFocused(self: *Component, focused: bool) void {
            if (self.focused == focused) return;
            self.focused = focused;
            self.emit(.{ .focus_changed = focused });
        }

        pub fn cursorRect(self: *const Component) draw.Rect {
            const metrics = self.textMetrics();
            const pos = text_layout.positionForOffset(self.textLayoutOptions(self.buffer.items, config.text_color), self.cursor);
            return .{ .x = pos.x, .y = pos.y, .w = 1.5, .h = metrics.line_height };
        }

        fn menuRect(self: *const Component, target: ComposerPromptOptionTarget) draw.Rect {
            const control = switch (target) {
                .model => self.modelRect(),
                .reasoning => self.reasoningRect(),
            };
            const options = self.optionsFor(target);
            const height = @min(@as(f32, @floatFromInt(options.count)) * config.row_height, config.row_height * 6.0);
            return .{ .x = control.x, .y = control.y - height - 6.0, .w = @max(control.w, self.menuContentWidth(target)), .h = height };
        }

        fn menuRowRect(self: *const Component, target: ComposerPromptOptionTarget, index: usize) draw.Rect {
            const menu = self.menuRect(target);
            return .{ .x = menu.x, .y = menu.y + @as(f32, @floatFromInt(index)) * config.row_height, .w = menu.w, .h = config.row_height };
        }

        fn menuIndexAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            const target = self.active_menu orelse return null;
            const menu = self.menuRect(target);
            if (!menu.contains(point)) return null;
            const index: usize = @intFromFloat(@floor((point.y - menu.y) / config.row_height));
            if (index >= self.optionsFor(target).count) return null;
            return index;
        }

        fn selectedIndex(self: *const Component, target: ComposerPromptOptionTarget) ?usize {
            return switch (target) {
                .model => self.model_index,
                .reasoning => self.reasoning_index,
            };
        }

        fn optionsFor(self: *const Component, target: ComposerPromptOptionTarget) Options {
            return switch (target) {
                .model => self.model_options,
                .reasoning => self.reasoning_options,
            };
        }

        fn placeholderText(self: *const Component) []const u8 {
            return if (self.placeholder_buffer.items.len > 0) self.placeholder_buffer.items else config.placeholder;
        }

        fn modelLabel(self: *const Component) []const u8 {
            return if (self.model_label_buffer.items.len > 0) self.model_label_buffer.items else config.model_label;
        }

        fn reasoningLabel(self: *const Component) []const u8 {
            return if (self.reasoning_label_buffer.items.len > 0) self.reasoning_label_buffer.items else config.reasoning_label;
        }

        fn fastLabel(self: *const Component) []const u8 {
            return if (self.fast_label_buffer.items.len > 0) self.fast_label_buffer.items else config.fast_label;
        }

        fn accessLabel(self: *const Component) []const u8 {
            return if (self.access_label_buffer.items.len > 0) self.access_label_buffer.items else config.access_label;
        }

        fn sendIcon(self: *const Component) []const u8 {
            return switch (self.send_state) {
                .send, .disabled => config.send_icon,
                .stop => config.stop_icon,
                .pending => config.pending_icon,
            };
        }

        fn emit(self: *Component, event: ComposerPromptEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }

        fn textMetrics(self: *const Component) text_layout.FontMetrics {
            if (self.font_metrics) |metrics| return metrics;
            return text_layout.FontMetrics.fixed(config.font_size, config.fixed_advance orelse config.font_size * 0.55, config.font_size * 1.25);
        }

        fn toolbarMetrics(self: *const Component) text_layout.FontMetrics {
            if (self.toolbar_font_metrics) |metrics| return metrics;
            return text_layout.FontMetrics.fixed(config.toolbar_font_size, config.toolbar_fixed_advance orelse config.toolbar_font_size * 0.55, config.toolbar_font_size * 1.25);
        }

        fn iconMetrics(self: *const Component) text_layout.FontMetrics {
            if (self.icon_font_metrics) |metrics| return metrics;
            return text_layout.FontMetrics.fixed(config.icon_font_size, config.icon_fixed_advance orelse config.icon_font_size * 0.55, config.icon_font_size * 1.25);
        }

        fn textLayoutOptions(self: *const Component, value: []const u8, color: draw.Color) text_layout.Options {
            return .{
                .rect = self.textRect(),
                .text = value,
                .color = color,
                .metrics = self.textMetrics(),
                .font_role = config.font_role,
                .font_id = config.font_id,
                .wrap = true,
                .scroll = .{ .y = self.scroll_y },
                .clip = self.textRect(),
            };
        }

        fn renderSelection(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, range: selection_input.Range) !void {
            var rects: std.ArrayList(draw.Rect) = .empty;
            defer rects.deinit(allocator);
            try text_layout.appendSelectionRects(allocator, self.textLayoutOptions(self.buffer.items, config.text_color), range, &rects);
            for (rects.items) |rect| try batch.selection(allocator, rect, config.selection_color);
        }

        fn renderScrollbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (!config.scroll_enabled or config.scrollbar_width <= 0.0 or self.maxScrollY() <= 0.0) return;
            const track = self.scrollbarTrackRect();
            try batch.scrollbar(allocator, track, config.scrollbar_track_color);
            if (self.scrollbarThumbRect()) |thumb| try batch.scrollbar(allocator, thumb, config.scrollbar_thumb_color);
        }

        fn scrollbarTrackRect(self: *const Component) draw.Rect {
            const text_rect = self.textRect();
            const track_w = @min(config.scrollbar_width, text_rect.w);
            return .{
                .x = text_rect.x + text_rect.w - track_w,
                .y = text_rect.y,
                .w = track_w,
                .h = text_rect.h,
            };
        }

        fn scrollbarThumbRect(self: *const Component) ?draw.Rect {
            return scroll.thumbRect(self.scrollbarTrackRect(), self.scrollMetrics(), self.scroll_y);
        }

        fn scrollMetrics(self: *const Component) scroll.Metrics {
            return .{
                .enabled = config.scroll_enabled,
                .content_height = self.contentHeight(),
                .visible_height = self.textRect().h,
                .line_height = self.textMetrics().line_height,
                .scrollbar_width = config.scrollbar_width,
            };
        }

        fn scrollBy(self: *Component, delta_y: f32) void {
            self.setScrollY(self.scroll_y + delta_y);
        }

        fn ensureCursorVisible(self: *Component) void {
            if (!config.scroll_enabled) {
                self.scroll_y = 0.0;
                return;
            }
            const cell = text_layout.visualCellForOffset(self.buffer.items, self.cursor, self.textMetrics(), self.textRect().w, true);
            const cursor_top = @as(f32, @floatFromInt(cell.row)) * self.textMetrics().line_height;
            const cursor_bottom = cursor_top + self.textMetrics().line_height;
            const visible_height = self.textRect().h;
            if (cursor_top < self.scroll_y) {
                self.scroll_y = cursor_top;
            } else if (cursor_bottom > self.scroll_y + visible_height) {
                self.scroll_y = cursor_bottom - visible_height;
            }
            self.setScrollY(self.scroll_y);
        }

        fn pillWidth(self: *const Component, left_icon: []const u8, label: []const u8, right_icon: []const u8, min_width: f32, max_width: f32) f32 {
            const text_metrics = self.toolbarMetrics();
            const icon_metrics = self.iconMetrics();
            var width = config.pill_padding_x * 2.0 + text_metrics.measureSlice(label);
            if (left_icon.len > 0) width += icon_metrics.measureSlice(left_icon) + config.pill_icon_gap;
            if (right_icon.len > 0) width += icon_metrics.measureSlice(right_icon) + config.pill_chevron_gap;
            return @min(@max(width, min_width), max_width);
        }

        fn menuContentWidth(self: *const Component, target: ComposerPromptOptionTarget) f32 {
            const options = self.optionsFor(target);
            const metrics = self.toolbarMetrics();
            var width: f32 = 150.0;
            var index: usize = 0;
            while (index < options.count) : (index += 1) {
                if (options.labelFor(index)) |label| {
                    width = @max(width, metrics.measureSlice(label) + config.pill_padding_x * 2.0);
                }
            }
            return width;
        }

        fn toolbarGeometry(self: *const Component) struct {
            toolbar: draw.Rect,
            model: draw.Rect,
            reasoning: draw.Rect,
            fast: draw.Rect,
            access: draw.Rect,
            send: draw.Rect,
        } {
            const toolbar = self.toolbarRect();
            const control_h = @min(toolbar.h, 32.0);
            const y = toolbar.y + (toolbar.h - control_h) * 0.5;
            const send_size = @min(toolbar.h, 40.0);
            const send: draw.Rect = .{
                .x = toolbar.x + toolbar.w - send_size,
                .y = toolbar.y + (toolbar.h - send_size) * 0.5,
                .w = send_size,
                .h = send_size,
            };
            const max_x = send.x - config.control_gap;
            var x = toolbar.x;

            const model_w = @min(self.pillWidth(config.model_icon, self.modelLabel(), config.chevron_icon, config.model_min_width, config.model_max_width), @max(max_x - x, 0.0));
            const model: draw.Rect = .{ .x = x, .y = y, .w = model_w, .h = control_h };
            x += model_w + config.control_gap;

            const reasoning_w = @min(self.pillWidth("", self.reasoningLabel(), config.chevron_icon, config.reasoning_min_width, config.reasoning_max_width), @max(max_x - x, 0.0));
            const reasoning: draw.Rect = .{ .x = x, .y = y, .w = reasoning_w, .h = control_h };
            x += reasoning_w;

            var fast: draw.Rect = undefined;
            if (self.show_fast_toggle) {
                x += config.control_gap;
                const fast_w = @min(self.pillWidth(config.fast_icon, self.fastLabel(), "", config.fast_min_width, config.fast_max_width), @max(max_x - x, 0.0));
                fast = .{ .x = x, .y = y, .w = fast_w, .h = control_h };
                x += fast_w + config.control_gap;
            } else {
                fast = .{ .x = x, .y = y, .w = 0.0, .h = control_h };
                x += config.control_gap;
            }

            const access_w = @min(self.pillWidth(config.access_icon, self.accessLabel(), "", config.access_min_width, config.access_max_width), @max(max_x - x, 0.0));
            const access: draw.Rect = .{ .x = x, .y = y, .w = access_w, .h = control_h };

            return .{
                .toolbar = toolbar,
                .model = model,
                .reasoning = reasoning,
                .fast = fast,
                .access = access,
                .send = send,
            };
        }

        fn separatorX(left: draw.Rect, right: draw.Rect) f32 {
            return (left.x + left.w + right.x) * 0.5;
        }
    };
}

fn setOwnedString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(allocator, value);
}

fn rectContainsY(rect: draw.Rect, y: f32, h: f32) bool {
    return y + h > rect.y and y < rect.y + rect.h;
}

fn clippedRect(rect: draw.Rect, clip: draw.Rect) ?draw.Rect {
    const x0 = @max(rect.x, clip.x);
    const y0 = @max(rect.y, clip.y);
    const x1 = @min(rect.x + rect.w, clip.x + clip.w);
    const y1 = @min(rect.y + rect.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
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

test "composer prompt hit tests toolbar controls" {
    const Prompt = ComposerPrompt(.{});
    var prompt = Prompt.init();

    try std.testing.expectEqual(@as(?ComposerPromptPart, .model), prompt.hitTest(.{ .x = prompt.modelRect().x + 2, .y = prompt.modelRect().y + 2 }));
    try std.testing.expectEqual(@as(?ComposerPromptPart, .reasoning), prompt.hitTest(.{ .x = prompt.reasoningRect().x + 2, .y = prompt.reasoningRect().y + 2 }));
    try std.testing.expectEqual(@as(?ComposerPromptPart, .fast), prompt.hitTest(.{ .x = prompt.fastRect().x + 2, .y = prompt.fastRect().y + 2 }));
    try std.testing.expectEqual(@as(?ComposerPromptPart, .access), prompt.hitTest(.{ .x = prompt.accessRect().x + 2, .y = prompt.accessRect().y + 2 }));
    try std.testing.expectEqual(@as(?ComposerPromptPart, .send), prompt.hitTest(.{ .x = prompt.sendButtonRect().x + 2, .y = prompt.sendButtonRect().y + 2 }));
}

const ComposerProbe = struct {
    text_changed: usize = 0,
    submitted: usize = 0,
    model_changed: usize = 0,
    fast_changed: usize = 0,
    access_changed: usize = 0,
    send_clicked: usize = 0,
};

fn probeComposerEvent(context: ?*anyopaque, event: ComposerPromptEvent) void {
    const probe: *ComposerProbe = @ptrCast(@alignCast(context orelse return));
    switch (event) {
        .text_changed => probe.text_changed += 1,
        .submitted => probe.submitted += 1,
        .model_changed => probe.model_changed += 1,
        .fast_changed => probe.fast_changed += 1,
        .access_changed => probe.access_changed += 1,
        .send_clicked => probe.send_clicked += 1,
        else => {},
    }
}

fn testModelOption(_: ?*anyopaque, index: usize) []const u8 {
    return switch (index) {
        0 => "Default",
        1 => "Deep",
        else => "Fast",
    };
}

test "composer prompt owns text options toggles and send input" {
    const Prompt = ComposerPrompt(.{});
    var prompt = Prompt.init();
    defer prompt.deinit(std.testing.allocator);
    var probe: ComposerProbe = .{};
    prompt.setCallbacks(.{ .context = &probe, .on_event = probeComposerEvent });
    prompt.setModelOptions(null, 3, testModelOption);

    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_down = .{ .x = prompt.textRect().x + 2, .y = prompt.textRect().y + 2 } }));
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .text = "hello" }));
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .key = .{ .code = .enter } }));
    try std.testing.expectEqualStrings("hello\n", prompt.text());
    try std.testing.expectEqual(@as(usize, 2), probe.text_changed);

    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_down = .{ .x = prompt.modelRect().x + 2, .y = prompt.modelRect().y + 2 } }));
    try std.testing.expect(prompt.active_menu == .model);
    const row = prompt.menuRowRect(.model, 1);
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_down = .{ .x = row.x + 2, .y = row.y + 2 } }));
    try std.testing.expectEqual(@as(?usize, 1), prompt.model_index);
    try std.testing.expectEqualStrings("Deep", prompt.modelLabel());

    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_down = .{ .x = prompt.fastRect().x + 2, .y = prompt.fastRect().y + 2 } }));
    try std.testing.expect(prompt.fast_enabled);
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_down = .{ .x = prompt.accessRect().x + 2, .y = prompt.accessRect().y + 2 } }));
    try std.testing.expect(prompt.access_enabled);
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_down = .{ .x = prompt.sendButtonRect().x + 2, .y = prompt.sendButtonRect().y + 2 } }));
    try std.testing.expectEqual(@as(usize, 1), probe.send_clicked);
    try std.testing.expectEqual(@as(usize, 1), probe.submitted);
    try std.testing.expectEqual(@as(usize, 1), probe.model_changed);
    try std.testing.expectEqual(@as(usize, 1), probe.fast_changed);
    try std.testing.expectEqual(@as(usize, 1), probe.access_changed);
}

fn proportionalAdvance(_: ?*anyopaque, text: []const u8, byte_offset: usize, _: f32) text_layout.Advance {
    return .{
        .byte_len = 1,
        .width = switch (text[byte_offset]) {
            'W' => 20,
            'i' => 2,
            else => 10,
        },
    };
}

test "composer prompt uses injected metrics for cursor and hit testing" {
    const Prompt = ComposerPrompt(.{ .x = 0, .y = 0, .width = 260, .height = 150 });
    var prompt = Prompt.init();
    defer prompt.deinit(std.testing.allocator);
    prompt.setFontMetrics(.{
        .font_size = 10,
        .line_height = 18,
        .advance = proportionalAdvance,
    });
    try prompt.setText(std.testing.allocator, "Wi");

    try std.testing.expectEqual(@as(f32, prompt.textRect().x + 22), prompt.cursorRect().x);
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_down = .{ .x = prompt.textRect().x + 20.4, .y = prompt.textRect().y + 2 } }));
    try std.testing.expectEqual(@as(usize, 1), prompt.cursor);
    try std.testing.expectEqual(@as(f32, prompt.textRect().x + 20), prompt.cursorRect().x);
}

test "composer prompt sizes toolbar pills from measured content" {
    const Prompt = ComposerPrompt(.{
        .width = 520,
        .height = 150,
        .pill_padding_x = 12,
        .pill_icon_gap = 4,
        .pill_chevron_gap = 3,
        .toolbar_fixed_advance = 5,
        .icon_fixed_advance = 6,
        .model_max_width = 240,
    });
    var prompt = Prompt.init();
    const model = prompt.modelRect();
    const expected = 12 * 2 + 6 + 4 + @as(f32, @floatFromInt("GPT-5.5".len)) * 5 + 3 + 6;
    try std.testing.expectEqual(expected, model.w);
}

test "composer prompt scrolls overflowing text and renders scrollbar" {
    const Prompt = ComposerPrompt(.{ .width = 260, .height = 122, .font_size = 10, .fixed_advance = 5, .scrollbar_width = 4 });
    var prompt = Prompt.init();
    defer prompt.deinit(std.testing.allocator);
    try prompt.setText(std.testing.allocator, "line 1\nline 2\nline 3\nline 4\nline 5\nline 6");
    prompt.focused = true;
    prompt.cursor = prompt.text().len;
    prompt.ensureCursorVisible();

    try std.testing.expect(prompt.scrollY() > 0);
    const before = prompt.scrollY();
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_wheel = .{ .point = .{ .x = prompt.textRect().x + 2, .y = prompt.textRect().y + 2 }, .y = 1 } }));
    try std.testing.expect(prompt.scrollY() < before);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try prompt.render(std.testing.allocator, &batch);
    var scrollbar_count: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .scrollbar) scrollbar_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), scrollbar_count);
}

test "composer prompt selects and replaces text" {
    const Prompt = ComposerPrompt(.{ .width = 320, .height = 150, .font_size = 10, .fixed_advance = 10 });
    var prompt = Prompt.init();
    defer prompt.deinit(std.testing.allocator);
    try prompt.setText(std.testing.allocator, "hello world");
    prompt.focused = true;
    prompt.cursor = 5;

    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .key = .{ .code = .left, .shift = true } }));
    try std.testing.expect(prompt.selection() != null);
    try std.testing.expectEqualStrings("o", prompt.text()[prompt.selection().?.start..prompt.selection().?.end]);
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .text = "O" }));
    try std.testing.expectEqualStrings("hellO world", prompt.text());

    const start = prompt.textRect();
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_down = .{ .x = start.x + 0, .y = start.y + 2 } }));
    try std.testing.expect(try prompt.handleInput(std.testing.allocator, .{ .mouse_drag = .{ .x = start.x + 50, .y = start.y + 2 } }));
    try std.testing.expect(prompt.selection() != null);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try prompt.render(std.testing.allocator, &batch);
    var selection_count: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .selection) selection_count += 1;
    }
    try std.testing.expect(selection_count > 0);
}
