//! Retained rich picker popover: option rows with labels, descriptions,
//! badges, leading icons, group headers, built-in search, and keyboard
//! navigation. Anchors to a control rect and clamps to a viewport so hosts
//! can reuse it for model pickers, theme pickers, workspace switchers, etc.

const std = @import("std");

const draw = @import("../draw.zig");
const key_input = @import("../input/key.zig");
const scroll = @import("../scroll.zig");
const selection_input = @import("../input/selection.zig");
const text_input_component = @import("text_input.zig");
const text_layout = @import("../text_layout.zig");

/// Returns display text for one option (label / description / badge / group).
/// Empty slices mean "absent" — a row without description stays compact and a
/// row without badge reserves no trailing pill.
pub const ItemTextFn = *const fn (context: ?*anyopaque, index: usize) []const u8;
pub const ItemBoolFn = *const fn (context: ?*anyopaque, index: usize) bool;

pub const RowLeadingRenderFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    batch: *draw.RenderBatch,
    index: usize,
    clip: draw.Rect,
    leading_rect: draw.Rect,
) void;

/// Renders a group icon in the optional left rail. `first_item` is the first
/// item index belonging to that group so hosts can resolve group identity.
pub const RailIconRenderFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    batch: *draw.RenderBatch,
    first_item: usize,
    clip: draw.Rect,
    icon_rect: draw.Rect,
) void;

/// `boxed` draws the search as a bordered rounded field; `underline` draws a
/// borderless field with an optional leading icon and an accent rule beneath.
pub const SearchStyle = enum { boxed, underline };

pub const Placement = enum {
    below,
    above,
    auto,
};

pub const RichPickerConfig = struct {
    width: f32 = 360.0,
    /// Compact row (label only).
    row_height: f32 = 32.0,
    /// Tall row (label + description line).
    row_height_with_description: f32 = 46.0,
    header_row_height: f32 = 26.0,
    /// Rows beyond this scroll inside the popover body.
    max_body_height: f32 = 340.0,
    /// Optional stable scroll viewport height. When set, filtering changes the
    /// rows inside the body without resizing the popover around the pointer.
    fixed_body_height: ?f32 = null,
    padding_x: f32 = 8.0,
    padding_y: f32 = 8.0,
    row_padding_x: f32 = 10.0,
    anchor_gap: f32 = 6.0,
    corner_radius: f32 = 12.0,
    border_width: f32 = 1.0,
    font_size: f32 = 15.0,
    description_font_size: f32 = 12.0,
    header_font_size: f32 = 12.0,
    badge_font_size: f32 = 11.0,
    glyph_width: f32 = 8.0,
    icon_gap: f32 = 8.0,
    badge_padding_x: f32 = 7.0,
    check_icon: []const u8 = "*",
    font_role: ?draw.FontRole = .ui,
    icon_font_role: ?draw.FontRole = .icon,
    font_id: ?u32 = null,
    icon_font_id: ?u32 = null,
    /// Search shows only when the unfiltered item count reaches this many rows.
    search_enabled: bool = true,
    search_min_items: usize = 8,
    search_height: f32 = 34.0,
    search_placeholder: []const u8 = "Search…",
    search_gap: f32 = 6.0,
    row_leading_width: f32 = 0.0,
    row_leading_to_label_gap: f32 = 0.0,
    render_row_leading: ?RowLeadingRenderFn = null,
    item_label: ?ItemTextFn = null,
    item_description: ?ItemTextFn = null,
    item_badge: ?ItemTextFn = null,
    /// Optional trailing row action. Hosts commonly use this for pin/favorite
    /// toggles; activating it emits `.action` without selecting or closing.
    item_action_icon: []const u8 = "",
    item_action_active_icon: []const u8 = "",
    item_action_active: ?ItemBoolFn = null,
    /// Group header text per item; consecutive items sharing the same text
    /// render under one header row. Null/empty disables grouping.
    item_group: ?ItemTextFn = null,
    /// Left group-icon rail ("All" entry + one icon per group). When enabled
    /// the picker never renders group header rows; clicking a rail entry
    /// filters rows to that group instead. The rail collapses automatically
    /// while fewer than two groups exist.
    rail_enabled: bool = false,
    rail_width: f32 = 52.0,
    rail_item_height: f32 = 46.0,
    rail_icon_size: f32 = 24.0,
    /// Glyph for the "all groups" rail entry, drawn with the icon font.
    rail_all_icon: []const u8 = "",
    /// Optional filter for the leading rail entry. When present, that entry
    /// shows only matching items instead of all groups (for example favorites).
    rail_primary_filter: ?ItemBoolFn = null,
    render_rail_icon: ?RailIconRenderFn = null,
    search_style: SearchStyle = .boxed,
    /// Optional glyph rendered at the left edge of the search field.
    search_icon: []const u8 = "",
    /// Draw the selection check right after the label text instead of at the
    /// row's trailing edge.
    check_inline: bool = false,
    /// Draw the row-leading icon small on the description line instead of
    /// spanning the full row height.
    leading_on_description: bool = false,
    /// Show "<shortcut_prefix><n>" chips on the first N visible rows (capped
    /// at 9). Hosts wire the actual key combo to `selectVisibleOrdinal`.
    shortcut_badge_limit: usize = 0,
    shortcut_prefix: []const u8 = "Ctrl+",
    placement: Placement = .above,
    scrollbar_width: f32 = 4.0,
    background_color: draw.Color = .{ .r = 0.07, .g = 0.08, .b = 0.10, .a = 1.0 },
    border_color: draw.Color = .{ .r = 0.24, .g = 0.28, .b = 0.34, .a = 1.0 },
    highlighted_color: draw.Color = .{ .r = 0.20, .g = 0.24, .b = 0.29, .a = 0.86 },
    selected_color: draw.Color = .{ .r = 0.18, .g = 0.31, .b = 0.42, .a = 0.85 },
    text_color: draw.Color = draw.Color.white,
    description_color: draw.Color = .{ .r = 0.62, .g = 0.66, .b = 0.72, .a = 1.0 },
    header_color: draw.Color = .{ .r = 0.55, .g = 0.60, .b = 0.66, .a = 1.0 },
    badge_background_color: draw.Color = .{ .r = 0.22, .g = 0.27, .b = 0.32, .a = 1.0 },
    badge_text_color: draw.Color = .{ .r = 0.72, .g = 0.78, .b = 0.86, .a = 1.0 },
    icon_color: draw.Color = .{ .r = 0.72, .g = 0.78, .b = 0.88, .a = 1.0 },
    scrollbar_track_color: draw.Color = .{ .r = 0.18, .g = 0.20, .b = 0.23, .a = 0.42 },
    scrollbar_thumb_color: draw.Color = .{ .r = 0.62, .g = 0.70, .b = 0.82, .a = 0.78 },
    search_background_color: draw.Color = .{ .r = 0.05, .g = 0.06, .b = 0.08, .a = 1.0 },
    search_border_color: draw.Color = .{ .r = 0.22, .g = 0.26, .b = 0.31, .a = 1.0 },
    search_selection_color: draw.Color = .{ .r = 0.18, .g = 0.42, .b = 0.72, .a = 0.55 },
    /// Inline check, rail active-bar, and the underline search rule.
    accent_color: draw.Color = .{ .r = 0.36, .g = 0.56, .b = 0.98, .a = 1.0 },
    rail_background_color: draw.Color = .{ .r = 0.05, .g = 0.06, .b = 0.08, .a = 1.0 },
    z_index: i32 = 0,
    viewport_rect: ?draw.Rect = null,
    anchor_rect: ?draw.Rect = null,
};

pub const RichPickerStyle = struct {
    background_color: draw.Color,
    border_color: draw.Color,
    highlighted_color: draw.Color,
    selected_color: draw.Color,
    text_color: draw.Color,
    description_color: draw.Color,
    header_color: draw.Color,
    badge_background_color: draw.Color,
    badge_text_color: draw.Color,
    icon_color: draw.Color,
    accent_color: draw.Color,
    rail_background_color: draw.Color,
    search_background_color: draw.Color,
    search_border_color: draw.Color,
    search_selection_color: draw.Color,
    scrollbar_track_color: draw.Color,
    scrollbar_thumb_color: draw.Color,
};

pub const Key = key_input;

pub const MouseButton = struct {
    point: draw.Vec2,
    /// Consecutive-click count from the host (SDL `clicks`); double-click
    /// selects the word under the pointer in the search field, triple-click
    /// selects the whole query.
    clicks: u8 = 1,
};

pub const MouseWheel = struct {
    point: draw.Vec2,
    y: f32,
};

pub const Input = union(enum) {
    open,
    close,
    item_count: usize,
    key: Key,
    text: []const u8,
    mouse_down: MouseButton,
    mouse_move: draw.Vec2,
    mouse_drag: draw.Vec2,
    mouse_up: draw.Vec2,
    mouse_wheel: MouseWheel,
};

pub const RichPickerEvent = union(enum) {
    selected: usize,
    action: usize,
    highlighted: usize,
    open_changed: bool,
};

pub const RichPickerCallbacks = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (context: ?*anyopaque, event: RichPickerEvent) void = null,
    /// Forwarded to the embedded search input so Ctrl/Cmd+V pastes queries.
    get_clipboard: ?*const fn (context: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 = null,
};

pub fn RichPicker(comptime config: RichPickerConfig) type {
    return struct {
        const Component = @This();
        pub const Style = RichPickerStyle;

        const transparent: draw.Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };
        // Underline search draws no field chrome of its own; the picker adds
        // the leading icon and the accent rule around the bare input.
        const search_underline = config.search_style == .underline;
        const SearchInput = text_input_component.TextInput(.{
            .height = config.search_height,
            .padding_x = if (search_underline) 4.0 else 10.0,
            .padding_y = 6.0,
            .background_color = if (search_underline) transparent else config.search_background_color,
            .border_color = if (search_underline) transparent else config.search_border_color,
            .corner_radius = if (search_underline) 0.0 else 8.0,
            .border_width = 1.0,
            .text_color = config.text_color,
            .placeholder_text = config.search_placeholder,
            .font_size = config.font_size,
            .font_role = config.font_role,
            .font_id = config.font_id,
            .submit_on_enter = false,
        });

        /// "Ctrl+1".."Ctrl+9"-style chip labels, built at comptime so the
        /// render batch can hold the slices without copying.
        const shortcut_chip_labels = blk: {
            const count = @min(config.shortcut_badge_limit, 9);
            var labels: [count][]const u8 = undefined;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                labels[i] = config.shortcut_prefix ++ [1]u8{@intCast('1' + i)};
            }
            break :blk labels;
        };

        const Row = struct {
            kind: enum { header, item },
            /// Original item index; for headers, the first item of the group
            /// (used to fetch the group label).
            item: usize,
            /// Offsets relative to the scrolled body content top, pre-scaled.
            y: f32,
            h: f32,
            /// Position among visible item rows; drives shortcut chips and
            /// `selectVisibleOrdinal`. Zero for header rows.
            ordinal: usize = 0,
        };

        item_count: usize = 0,
        open: bool = false,
        rows: std.ArrayList(Row) = .empty,
        filtered: std.ArrayList(usize) = .empty,
        last_query: std.ArrayList(u8) = .empty,
        /// First item index per unique group, in first-appearance order.
        groups: std.ArrayList(usize) = .empty,
        /// Group label the rail is filtering to; empty means "all". Stored as
        /// a copy so the filter survives item-index churn across refreshes.
        active_group_label: std.ArrayList(u8) = .empty,
        hovered_rail: ?usize = null,
        /// Keyboard focus within the rail. Null keeps arrow navigation in the
        /// model rows; otherwise the value is the rail entry index (including
        /// the leading "all groups" entry at zero).
        focused_rail: ?usize = null,
        search: SearchInput = .{},
        highlighted: ?usize = null,
        selected_item: ?usize = null,
        scroll_y: f32 = 0.0,
        dragging_scrollbar: bool = false,
        scrollbar_drag_offset_y: f32 = 0.0,
        rows_dirty: bool = true,
        ui_scale: f32 = 1.0,
        font_metrics: ?text_layout.FontMetrics = null,
        viewport_rect: ?draw.Rect = config.viewport_rect,
        anchor_rect: ?draw.Rect = config.anchor_rect,
        z_index: i32 = config.z_index,
        style: Style = defaultStyle(),
        callbacks: RichPickerCallbacks = .{},

        pub fn init(item_count: usize) Component {
            return .{ .item_count = item_count };
        }

        pub fn deinit(self: *Component, allocator: std.mem.Allocator) void {
            self.rows.deinit(allocator);
            self.filtered.deinit(allocator);
            self.last_query.deinit(allocator);
            self.groups.deinit(allocator);
            self.active_group_label.deinit(allocator);
            self.search.deinit(allocator);
            self.* = undefined;
        }

        pub fn defaultStyle() Style {
            return .{
                .background_color = config.background_color,
                .border_color = config.border_color,
                .highlighted_color = config.highlighted_color,
                .selected_color = config.selected_color,
                .text_color = config.text_color,
                .description_color = config.description_color,
                .header_color = config.header_color,
                .badge_background_color = config.badge_background_color,
                .badge_text_color = config.badge_text_color,
                .icon_color = config.icon_color,
                .accent_color = config.accent_color,
                .rail_background_color = config.rail_background_color,
                .search_background_color = config.search_background_color,
                .search_border_color = config.search_border_color,
                .search_selection_color = config.search_selection_color,
                .scrollbar_track_color = config.scrollbar_track_color,
                .scrollbar_thumb_color = config.scrollbar_thumb_color,
            };
        }

        pub fn setStyle(self: *Component, style: Style) void {
            self.style = style;
            // The embedded search follows the host style too so dynamic
            // theming reaches its text, caret, selection, and placeholder.
            self.search.setStyle(.{
                .background_color = if (search_underline) transparent else style.search_background_color,
                .border_color = if (search_underline) transparent else style.search_border_color,
                .text_color = style.text_color,
                .cursor_color = style.text_color,
                .selection_color = style.search_selection_color,
                .placeholder_color = style.description_color,
            });
        }

        pub fn setCallbacks(self: *Component, callbacks: RichPickerCallbacks) void {
            self.callbacks = callbacks;
            self.search.setCallbacks(.{ .context = callbacks.context, .get_clipboard = callbacks.get_clipboard });
        }

        pub fn setFontMetrics(self: *Component, metrics_value: text_layout.FontMetrics) void {
            self.font_metrics = metrics_value;
            self.search.setFontMetrics(metrics_value);
        }

        pub fn setZIndex(self: *Component, z_index: i32) void {
            self.z_index = z_index;
        }

        /// DPI multiplier applied to every geometry constant in the config so
        /// popovers keep a consistent physical size across display scales.
        pub fn setUiScale(self: *Component, scale: f32) void {
            const clamped = @max(scale, 0.1);
            if (self.ui_scale == clamped) return;
            self.ui_scale = clamped;
            self.rows_dirty = true;
        }

        pub fn setViewportRect(self: *Component, rect_value: draw.Rect) void {
            self.viewport_rect = rect_value;
        }

        pub fn setAnchorRect(self: *Component, rect_value: draw.Rect) void {
            self.anchor_rect = rect_value;
        }

        pub fn setItemCount(self: *Component, count: usize) void {
            if (self.item_count == count) return;
            self.item_count = count;
            self.rows_dirty = true;
            if (self.selected_item) |item| {
                if (item >= count) self.selected_item = null;
            }
        }

        pub fn setSelectedItem(self: *Component, item: ?usize) void {
            self.selected_item = item;
        }

        /// Call when item data changed under an unchanged count (async refresh).
        pub fn invalidateItems(self: *Component) void {
            self.rows_dirty = true;
        }

        pub fn isOpen(self: *const Component) bool {
            return self.open;
        }

        pub fn searchText(self: *const Component) []const u8 {
            return self.search.text();
        }

        /// True when the point rests on a clickable target — an item row, a
        /// rail entry, or the scrollbar — rather than the search field or
        /// padding. Hosts use this to show a pointer (hand) mouse cursor.
        pub fn wantsPointerAt(self: *const Component, point: draw.Vec2) bool {
            if (!self.open) return false;
            if (self.searchActive() and self.searchRect().contains(point)) return false;
            if (self.railItemAtPoint(point) != null) return true;
            if (self.rowAtPoint(point)) |row_index| {
                return self.rows.items[row_index].kind == .item;
            }
            if (self.scrollbarThumbRect()) |thumb| {
                if (thumb.contains(point)) return true;
            }
            return false;
        }

        /// Selects the nth visible item row (0-based). Hosts bind this to the
        /// key combo advertised by the `shortcut_badge_limit` chips (Ctrl+1…).
        pub fn selectVisibleOrdinal(self: *Component, allocator: std.mem.Allocator, ordinal: usize) !bool {
            if (!self.open) return false;
            try self.ensureRows(allocator);
            for (self.rows.items) |row| {
                if (row.kind == .item and row.ordinal == ordinal) {
                    self.selectItem(allocator, row.item);
                    return true;
                }
            }
            return false;
        }

        pub fn handleInput(self: *Component, allocator: std.mem.Allocator, input: Input) !bool {
            switch (input) {
                .open => {
                    try self.openPicker(allocator);
                    return true;
                },
                .close => {
                    self.close(allocator);
                    return true;
                },
                .item_count => |count| {
                    self.setItemCount(count);
                    try self.ensureRows(allocator);
                    return true;
                },
                .key => |key| return try self.handleKey(allocator, key),
                .text => |value| {
                    if (!self.open or !self.searchActive()) return false;
                    self.focused_rail = null;
                    self.search.focused = true;
                    _ = try self.search.handleInput(allocator, .{ .text = value });
                    try self.refilterIfQueryChanged(allocator);
                    return true;
                },
                .mouse_down => |mouse| return try self.handleMouseDown(allocator, mouse.point, mouse.clicks),
                .mouse_move => |point| return try self.handleMouseMove(allocator, point, false),
                .mouse_drag => |point| return try self.handleMouseMove(allocator, point, true),
                .mouse_up => |point| {
                    if (!self.open) return false;
                    const was_dragging = self.dragging_scrollbar;
                    self.dragging_scrollbar = false;
                    _ = try self.search.handleInput(allocator, .{ .mouse_up = point });
                    // The embedded search keeps focus for typing while open even
                    // when a click lands on the list instead of the field.
                    self.search.focused = true;
                    return was_dragging;
                },
                .mouse_wheel => |wheel| {
                    if (!self.open) return false;
                    try self.ensureRows(allocator);
                    if (!self.pickerRect().contains(wheel.point)) return false;
                    self.scrollBy(-wheel.y * self.scaled(config.row_height) * 3.0);
                    return true;
                },
            }
        }

        pub fn render(self: *Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (!self.open) return;
            try self.ensureRows(allocator);
            const previous_z = batch.setZIndex(self.z_index);
            defer batch.restoreZIndex(previous_z);

            const rect = self.pickerRect();
            const inset = @max(config.border_width, 1.0);
            const corner = self.scaled(config.corner_radius);
            try batch.roundedRectClipped(allocator, rect, self.style.border_color, corner, rect);
            if (rect.w > inset * 2.0 and rect.h > inset * 2.0) {
                try batch.roundedRectClipped(allocator, .{
                    .x = rect.x + inset,
                    .y = rect.y + inset,
                    .w = rect.w - inset * 2.0,
                    .h = rect.h - inset * 2.0,
                }, self.style.background_color, @max(corner - inset, 0.0), rect);
            }

            if (self.railActive()) try self.renderRail(allocator, batch, rect);
            if (self.searchActive()) try self.renderSearch(allocator, batch);

            const body = self.bodyRect();
            for (self.rows.items) |row| {
                const row_rect = self.rowRect(row);
                if (row_rect.y + row_rect.h < body.y or row_rect.y > body.y + body.h) continue;
                switch (row.kind) {
                    .header => try self.renderHeaderRow(allocator, batch, row, row_rect, body),
                    .item => try self.renderItemRow(allocator, batch, row, row_rect, body),
                }
            }
            try self.renderScrollbar(allocator, batch);
        }

        pub fn renderPass(_: *const Component, _: *draw.GpuRenderPass) void {}

        // -- geometry -------------------------------------------------------

        fn scaled(self: *const Component, value: f32) f32 {
            return value * self.ui_scale;
        }

        fn searchActive(self: *const Component) bool {
            if (!config.search_enabled) return false;
            // Keep the field once a query filtered the list below the
            // threshold, otherwise typing would dismiss the search box.
            return self.item_count >= config.search_min_items or self.last_query.items.len > 0;
        }

        fn contentHeight(self: *const Component) f32 {
            if (self.rows.items.len == 0) return self.scaled(config.row_height);
            const last = self.rows.items[self.rows.items.len - 1];
            return last.y + last.h;
        }

        pub fn pickerRect(self: *const Component) draw.Rect {
            const width = self.scaled(config.width) + self.railWidth();
            const pad_y = self.scaled(config.padding_y);
            const search_h = if (self.searchActive()) self.scaled(config.search_height) + self.scaled(config.search_gap) else 0.0;
            var body_h = if (config.fixed_body_height) |fixed_height|
                @max(self.scaled(fixed_height), self.scaled(config.row_height))
            else
                @max(@min(self.contentHeight(), self.scaled(config.max_body_height)), self.scaled(config.row_height));
            if (self.viewport_rect) |viewport| {
                // Shrink the scrollable body rather than letting the popover
                // overflow the viewport (e.g. cover the composer on short
                // windows); the body keeps at least one row and scrolls.
                const max_body = viewport.h - pad_y * 2.0 - search_h;
                body_h = @max(@min(body_h, max_body), self.scaled(config.row_height));
            }
            var height = pad_y * 2.0 + search_h + body_h;
            if (self.railActive()) {
                // The rail never scrolls, so the popover must be tall enough
                // for every rail entry (still capped to the viewport).
                var rail_h = pad_y * 2.0 +
                    @as(f32, @floatFromInt(self.groups.items.len + 1)) * self.scaled(config.rail_item_height);
                if (self.viewport_rect) |viewport| rail_h = @min(rail_h, viewport.h);
                height = @max(height, rail_h);
            }
            var rect_value: draw.Rect = .{ .x = 0.0, .y = 0.0, .w = width, .h = height };
            if (self.anchor_rect) |anchor| {
                rect_value.x = anchor.x;
                const gap = self.scaled(config.anchor_gap);
                rect_value.y = switch (config.placement) {
                    .below => anchor.y + anchor.h + gap,
                    .above => anchor.y - height - gap,
                    .auto => self.autoY(anchor, height, gap),
                };
            }
            return self.clampToViewport(rect_value);
        }

        fn autoY(self: *const Component, anchor: draw.Rect, height: f32, gap: f32) f32 {
            if (self.viewport_rect) |viewport| {
                const below_space = viewport.y + viewport.h - (anchor.y + anchor.h);
                const above_space = anchor.y - viewport.y;
                if (above_space >= height or above_space > below_space) return anchor.y - height - gap;
            }
            return anchor.y + anchor.h + gap;
        }

        fn clampToViewport(self: *const Component, rect_value: draw.Rect) draw.Rect {
            var clamped = rect_value;
            const viewport = self.viewport_rect orelse return clamped;
            if (clamped.w <= viewport.w) {
                if (clamped.x < viewport.x) clamped.x = viewport.x;
                if (clamped.x + clamped.w > viewport.x + viewport.w) clamped.x = viewport.x + viewport.w - clamped.w;
            }
            if (clamped.h <= viewport.h) {
                if (clamped.y < viewport.y) clamped.y = viewport.y;
                if (clamped.y + clamped.h > viewport.y + viewport.h) clamped.y = viewport.y + viewport.h - clamped.h;
            }
            return clamped;
        }

        fn railActive(self: *const Component) bool {
            return config.rail_enabled and self.groups.items.len > 1;
        }

        fn railWidth(self: *const Component) f32 {
            return if (self.railActive()) self.scaled(config.rail_width) else 0.0;
        }

        fn railRect(self: *const Component) draw.Rect {
            const rect = self.pickerRect();
            const inset = @max(config.border_width, 1.0);
            return .{
                .x = rect.x + inset,
                .y = rect.y + inset,
                .w = @max(self.railWidth() - inset, 0.0),
                .h = @max(rect.h - inset * 2.0, 0.0),
            };
        }

        /// Rail entry rect; index 0 is the "all groups" entry, then one per
        /// group in first-appearance order.
        fn railItemRect(self: *const Component, index: usize) draw.Rect {
            const rail = self.railRect();
            const item_h = self.scaled(config.rail_item_height);
            return .{
                .x = rail.x,
                .y = rail.y + self.scaled(config.padding_y) + @as(f32, @floatFromInt(index)) * item_h,
                .w = rail.w,
                .h = item_h,
            };
        }

        fn railItemAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            if (!self.railActive()) return null;
            if (!self.railRect().contains(point)) return null;
            var index: usize = 0;
            while (index < self.groups.items.len + 1) : (index += 1) {
                if (self.railItemRect(index).contains(point)) return index;
            }
            return null;
        }

        fn searchRect(self: *const Component) draw.Rect {
            const rect = self.pickerRect();
            return .{
                .x = rect.x + self.railWidth() + self.scaled(config.padding_x),
                .y = rect.y + self.scaled(config.padding_y),
                .w = @max(rect.w - self.railWidth() - self.scaled(config.padding_x) * 2.0, 0.0),
                .h = self.scaled(config.search_height),
            };
        }

        /// The embedded text input's bounds: the search rect minus the space
        /// reserved for the leading icon glyph.
        fn searchInputRect(self: *const Component) draw.Rect {
            var rect = self.searchRect();
            if (config.search_icon.len > 0) {
                const icon_metrics = self.derivedMetrics(self.scaled(config.font_size));
                const inset = icon_metrics.measureSlice(config.search_icon) + self.scaled(config.icon_gap);
                rect.x += inset;
                rect.w = @max(rect.w - inset, 0.0);
            }
            return rect;
        }

        fn bodyRect(self: *const Component) draw.Rect {
            const rect = self.pickerRect();
            const pad_x = self.scaled(config.padding_x);
            const pad_y = self.scaled(config.padding_y);
            const search_h = if (self.searchActive()) self.scaled(config.search_height) + self.scaled(config.search_gap) else 0.0;
            return .{
                .x = rect.x + self.railWidth() + pad_x,
                .y = rect.y + pad_y + search_h,
                .w = @max(rect.w - self.railWidth() - pad_x * 2.0, 0.0),
                .h = @max(rect.h - pad_y * 2.0 - search_h, 0.0),
            };
        }

        fn rowRect(self: *const Component, row: Row) draw.Rect {
            const body = self.bodyRect();
            return .{
                .x = body.x,
                .y = body.y + row.y - self.scroll_y,
                .w = @max(body.w - self.scrollbarGutter(), 0.0),
                .h = row.h,
            };
        }

        fn rowAtPoint(self: *const Component, point: draw.Vec2) ?usize {
            const body = self.bodyRect();
            if (!body.contains(point)) return null;
            const content_y = point.y - body.y + self.scroll_y;
            for (self.rows.items, 0..) |row, index| {
                if (content_y >= row.y and content_y < row.y + row.h) return index;
            }
            return null;
        }

        fn scrollMetrics(self: *const Component) scroll.Metrics {
            return .{
                .enabled = true,
                .content_height = self.contentHeight(),
                .visible_height = self.bodyRect().h,
                .line_height = self.scaled(config.row_height),
                .scrollbar_width = config.scrollbar_width,
            };
        }

        fn scrollbarGutter(self: *const Component) f32 {
            if (scroll.maxOffsetY(self.scrollMetrics()) <= 0.0) return 0.0;
            return config.scrollbar_width + self.scaled(config.icon_gap) * 0.5;
        }

        fn scrollBy(self: *Component, delta_y: f32) void {
            self.scroll_y = scroll.clampOffsetY(self.scroll_y + delta_y, self.scrollMetrics());
        }

        fn scrollbarTrackRect(self: *const Component) draw.Rect {
            const body = self.bodyRect();
            return .{
                .x = body.x + body.w - config.scrollbar_width,
                .y = body.y,
                .w = config.scrollbar_width,
                .h = body.h,
            };
        }

        fn scrollbarThumbRect(self: *const Component) ?draw.Rect {
            return scroll.thumbRect(self.scrollbarTrackRect(), self.scrollMetrics(), self.scroll_y);
        }

        fn ensureRowVisible(self: *Component, row_index: usize) void {
            if (row_index >= self.rows.items.len) return;
            const row = self.rows.items[row_index];
            const visible_height = self.bodyRect().h;
            if (row.y < self.scroll_y) {
                self.scroll_y = row.y;
            } else if (row.y + row.h > self.scroll_y + visible_height) {
                self.scroll_y = row.y + row.h - visible_height;
            }
            self.scroll_y = scroll.clampOffsetY(self.scroll_y, self.scrollMetrics());
        }

        // -- data / filtering -------------------------------------------------

        fn itemText(comptime callback: ?ItemTextFn, context: ?*anyopaque, index: usize) []const u8 {
            if (callback) |resolved| return resolved(context, index);
            return "";
        }

        fn ensureRows(self: *Component, allocator: std.mem.Allocator) !void {
            if (!self.rows_dirty) return;
            try self.rebuildFiltered(allocator);
            try self.rebuildRows(allocator);
            self.rows_dirty = false;
        }

        /// Rebuilds the unique-group list (first item index per group) and
        /// drops a stale rail filter whose group vanished after a refresh.
        fn rebuildGroups(self: *Component, allocator: std.mem.Allocator) !void {
            self.groups.clearRetainingCapacity();
            if (config.item_group == null) return;
            const context = self.callbacks.context;
            var index: usize = 0;
            while (index < self.item_count) : (index += 1) {
                const group = itemText(config.item_group, context, index);
                if (group.len == 0) continue;
                var known = false;
                for (self.groups.items) |first_item| {
                    if (std.mem.eql(u8, itemText(config.item_group, context, first_item), group)) {
                        known = true;
                        break;
                    }
                }
                if (!known) try self.groups.append(allocator, index);
            }
            if (self.active_group_label.items.len > 0 and self.activeGroupIndex() == null) {
                self.active_group_label.clearRetainingCapacity();
            }
        }

        fn activeGroupIndex(self: *const Component) ?usize {
            if (self.active_group_label.items.len == 0) return null;
            const context = self.callbacks.context;
            for (self.groups.items, 0..) |first_item, index| {
                if (std.mem.eql(u8, itemText(config.item_group, context, first_item), self.active_group_label.items)) {
                    return index;
                }
            }
            return null;
        }

        fn itemPassesRailFilter(self: *const Component, index: usize) bool {
            if (self.active_group_label.items.len == 0) {
                if (self.railActive()) {
                    if (config.rail_primary_filter) |filter| return filter(self.callbacks.context, index);
                }
                return true;
            }
            // A collapsed rail (single group) cannot show the filter, so it
            // must not silently hide rows either.
            if (!self.railActive()) return true;
            const group = itemText(config.item_group, self.callbacks.context, index);
            return std.mem.eql(u8, group, self.active_group_label.items);
        }

        fn rebuildFiltered(self: *Component, allocator: std.mem.Allocator) !void {
            self.filtered.clearRetainingCapacity();
            try self.rebuildGroups(allocator);
            const query = self.last_query.items;
            if (query.len == 0) {
                var index: usize = 0;
                while (index < self.item_count) : (index += 1) {
                    if (!self.itemPassesRailFilter(index)) continue;
                    try self.filtered.append(allocator, index);
                }
                return;
            }
            const Scored = struct { item: usize, score: i32 };
            var scored: std.ArrayList(Scored) = .empty;
            defer scored.deinit(allocator);
            var index: usize = 0;
            while (index < self.item_count) : (index += 1) {
                if (!self.itemPassesRailFilter(index)) continue;
                const score = self.matchScore(index, query) orelse continue;
                try scored.append(allocator, .{ .item = index, .score = score });
            }
            std.sort.insertion(Scored, scored.items, {}, struct {
                fn lessThan(_: void, a: Scored, b: Scored) bool {
                    if (a.score != b.score) return a.score > b.score;
                    return a.item < b.item;
                }
            }.lessThan);
            for (scored.items) |entry| try self.filtered.append(allocator, entry.item);
        }

        fn matchScore(self: *const Component, index: usize, query: []const u8) ?i32 {
            if (query.len == 0) return 0;
            const context = self.callbacks.context;
            const label = itemText(config.item_label, context, index);
            if (std.ascii.indexOfIgnoreCase(label, query)) |pos| return 1000 - @as(i32, @intCast(@min(pos, 500)));
            const description = itemText(config.item_description, context, index);
            if (std.ascii.indexOfIgnoreCase(description, query)) |pos| return 500 - @as(i32, @intCast(@min(pos, 400)));
            const group = itemText(config.item_group, context, index);
            if (std.ascii.indexOfIgnoreCase(group, query)) |pos| return 400 - @as(i32, @intCast(@min(pos, 300)));
            if (subsequenceGaps(label, query)) |gaps| return 200 - @as(i32, @intCast(@min(gaps, 150)));
            return null;
        }

        fn rebuildRows(self: *Component, allocator: std.mem.Allocator) !void {
            self.rows.clearRetainingCapacity();
            const context = self.callbacks.context;
            // An active query re-ranks items by score, interleaving groups;
            // headers would repeat between every hit, so search results render
            // as a flat ranked list instead. A rail replaces headers entirely.
            const grouping_active = self.last_query.items.len == 0 and !config.rail_enabled;
            var y: f32 = 0.0;
            var ordinal: usize = 0;
            var previous_group: []const u8 = "";
            var has_previous_group = false;
            for (self.filtered.items) |item| {
                const group = itemText(config.item_group, context, item);
                if (grouping_active and group.len > 0 and (!has_previous_group or !std.mem.eql(u8, group, previous_group))) {
                    const header_h = self.scaled(config.header_row_height);
                    try self.rows.append(allocator, .{ .kind = .header, .item = item, .y = y, .h = header_h });
                    y += header_h;
                }
                previous_group = group;
                has_previous_group = true;
                const description = itemText(config.item_description, context, item);
                const row_h = self.scaled(if (description.len > 0) config.row_height_with_description else config.row_height);
                try self.rows.append(allocator, .{ .kind = .item, .item = item, .y = y, .h = row_h, .ordinal = ordinal });
                ordinal += 1;
                y += row_h;
            }
            self.scroll_y = scroll.clampOffsetY(self.scroll_y, self.scrollMetrics());
            self.normalizeHighlight();
        }

        fn refilterIfQueryChanged(self: *Component, allocator: std.mem.Allocator) !void {
            if (std.mem.eql(u8, self.last_query.items, self.search.text())) return;
            self.last_query.clearRetainingCapacity();
            try self.last_query.appendSlice(allocator, self.search.text());
            self.rows_dirty = true;
            try self.ensureRows(allocator);
            self.scroll_y = 0.0;
            self.highlighted = self.firstItemRow();
            if (self.highlighted) |row| self.emitHighlight(row);
        }

        fn normalizeHighlight(self: *Component) void {
            const row_index = self.highlighted orelse return;
            if (row_index >= self.rows.items.len or self.rows.items[row_index].kind != .item) {
                self.highlighted = self.firstItemRow();
            }
        }

        fn firstItemRow(self: *const Component) ?usize {
            for (self.rows.items, 0..) |row, index| {
                if (row.kind == .item) return index;
            }
            return null;
        }

        fn rowIndexForItem(self: *const Component, item: usize) ?usize {
            for (self.rows.items, 0..) |row, index| {
                if (row.kind == .item and row.item == item) return index;
            }
            return null;
        }

        // -- input ------------------------------------------------------------

        fn openPicker(self: *Component, allocator: std.mem.Allocator) !void {
            if (!self.open) {
                self.open = true;
                self.emit(.{ .open_changed = true });
            }
            try self.clearSearch(allocator);
            self.rows_dirty = true;
            try self.ensureRows(allocator);
            self.scroll_y = 0.0;
            self.focused_rail = null;
            self.search.focused = true;
            self.highlighted = blk: {
                if (self.selected_item) |item| {
                    if (self.rowIndexForItem(item)) |row| break :blk row;
                }
                break :blk self.firstItemRow();
            };
            if (self.highlighted) |row| self.ensureRowVisible(row);
        }

        /// Applies a rail selection: null filters to all groups, otherwise the
        /// group at `group_index` (0-based into `groups`).
        fn setRailGroup(self: *Component, allocator: std.mem.Allocator, group_index: ?usize) !void {
            self.active_group_label.clearRetainingCapacity();
            if (group_index) |index| {
                if (index < self.groups.items.len) {
                    const label = itemText(config.item_group, self.callbacks.context, self.groups.items[index]);
                    try self.active_group_label.appendSlice(allocator, label);
                }
            }
            self.rows_dirty = true;
            try self.ensureRows(allocator);
            self.scroll_y = 0.0;
            self.highlighted = self.firstItemRow();
            if (self.highlighted) |row| self.emitHighlight(row);
        }

        fn close(self: *Component, allocator: std.mem.Allocator) void {
            if (!self.open) return;
            self.open = false;
            self.dragging_scrollbar = false;
            self.hovered_rail = null;
            self.focused_rail = null;
            self.search.focused = false;
            self.clearSearch(allocator) catch {};
            self.emit(.{ .open_changed = false });
        }

        fn clearSearch(self: *Component, allocator: std.mem.Allocator) !void {
            self.search.focused = true;
            if (self.search.text().len > 0) {
                _ = try self.search.handleInput(allocator, .{ .key = .{ .code = .a, .primary = true } });
                _ = try self.search.handleInput(allocator, .{ .key = .{ .code = .backspace } });
            }
            self.search.clearSelection();
            if (self.last_query.items.len > 0) {
                self.last_query.clearRetainingCapacity();
                self.rows_dirty = true;
            }
        }

        fn handleKey(self: *Component, allocator: std.mem.Allocator, key: Key) !bool {
            if (!self.open) return false;
            try self.ensureRows(allocator);
            if (self.focused_rail) |rail_index| {
                switch (key.code) {
                    .up, .down => {
                        const entry_count = self.groups.items.len + 1;
                        const next = if (key.code == .up)
                            rail_index -| 1
                        else
                            @min(rail_index + 1, entry_count - 1);
                        self.focused_rail = next;
                        try self.setRailGroup(allocator, if (next == 0) null else next - 1);
                        return true;
                    },
                    .right => {
                        self.focused_rail = null;
                        self.search.focused = true;
                        return true;
                    },
                    .left => return true,
                    else => {},
                }
            }
            switch (key.code) {
                .escape => {
                    // First Escape clears an active query, second closes.
                    if (self.last_query.items.len > 0) {
                        try self.clearSearch(allocator);
                        try self.ensureRows(allocator);
                        self.scroll_y = 0.0;
                        self.highlighted = self.firstItemRow();
                    } else {
                        self.close(allocator);
                    }
                    return true;
                },
                .down => {
                    self.moveHighlight(1);
                    return true;
                },
                .up => {
                    self.moveHighlight(-1);
                    return true;
                },
                .left => {
                    if (!self.railActive() or self.last_query.items.len > 0) {
                        if (!self.searchActive()) return false;
                        self.search.focused = true;
                        return try self.search.handleInput(allocator, .{ .key = key });
                    }
                    self.focused_rail = self.railIndexForHighlight();
                    self.search.focused = false;
                    return true;
                },
                .page_down => {
                    self.moveHighlight(self.pageStepRows());
                    return true;
                },
                .page_up => {
                    self.moveHighlight(-self.pageStepRows());
                    return true;
                },
                .enter => {
                    if (self.highlighted) |row_index| {
                        if (row_index < self.rows.items.len and self.rows.items[row_index].kind == .item) {
                            self.selectItem(allocator, self.rows.items[row_index].item);
                        }
                    }
                    return true;
                },
                else => {
                    if (!self.searchActive()) return false;
                    self.search.focused = true;
                    const handled = try self.search.handleInput(allocator, .{ .key = key });
                    try self.refilterIfQueryChanged(allocator);
                    return handled;
                },
            }
        }

        fn pageStepRows(self: *const Component) i32 {
            const row_h = self.scaled(config.row_height);
            if (row_h <= 0.0) return 1;
            const rows_per_page = @max(@as(i32, @intFromFloat(self.bodyRect().h / row_h)) - 1, 1);
            return rows_per_page;
        }

        fn railIndexForHighlight(self: *const Component) usize {
            if (self.highlighted) |row_index| {
                if (row_index < self.rows.items.len) {
                    const item = self.rows.items[row_index].item;
                    const group = itemText(config.item_group, self.callbacks.context, item);
                    for (self.groups.items, 0..) |first_item, group_index| {
                        if (std.mem.eql(u8, itemText(config.item_group, self.callbacks.context, first_item), group)) {
                            return group_index + 1;
                        }
                    }
                }
            }
            if (self.activeGroupIndex()) |group_index| return group_index + 1;
            return 0;
        }

        fn moveHighlight(self: *Component, delta: i32) void {
            if (self.rows.items.len == 0) return;
            const count = @as(i32, @intCast(self.rows.items.len));
            var index: i32 = blk: {
                if (self.highlighted) |current| break :blk @intCast(current);
                break :blk if (delta < 0) count else -1;
            };
            var remaining: i32 = if (delta == 0) 1 else @intCast(@abs(delta));
            const step: i32 = if (delta < 0) -1 else 1;
            var last_item: ?usize = self.highlighted;
            while (remaining > 0) {
                index += step;
                if (index < 0 or index >= count) break;
                if (self.rows.items[@intCast(index)].kind == .item) {
                    last_item = @intCast(index);
                    remaining -= 1;
                }
            }
            if (last_item) |row_index| {
                if (self.highlighted != row_index) {
                    self.highlighted = row_index;
                    self.emitHighlight(row_index);
                }
                self.ensureRowVisible(row_index);
            }
        }

        fn handleMouseDown(self: *Component, allocator: std.mem.Allocator, point: draw.Vec2, clicks: u8) !bool {
            if (!self.open) return false;
            try self.ensureRows(allocator);
            if (self.railItemAtPoint(point)) |rail_index| {
                self.focused_rail = null;
                try self.setRailGroup(allocator, if (rail_index == 0) null else rail_index - 1);
                return true;
            }
            if (self.searchActive() and self.searchRect().contains(point)) {
                self.search.setBounds(self.searchInputRect());
                _ = try self.search.handleInput(allocator, .{ .mouse_down = point });
                self.search.focused = true;
                if (clicks >= 3) {
                    self.search.selection_anchor = 0;
                    self.search.selection_focus = self.search.text().len;
                    self.search.cursor = self.search.text().len;
                } else if (clicks == 2) {
                    const range = selection_input.wordRangeAt(self.search.text(), self.search.cursor);
                    self.search.selection_anchor = range.start;
                    self.search.selection_focus = range.end;
                    self.search.cursor = range.end;
                }
                return true;
            }
            if (self.scrollbarThumbRect()) |thumb| {
                if (thumb.contains(point)) {
                    self.dragging_scrollbar = true;
                    self.scrollbar_drag_offset_y = point.y - thumb.y;
                    return true;
                }
            }
            if (self.rowAtPoint(point)) |row_index| {
                const row = self.rows.items[row_index];
                if (row.kind == .item) {
                    if (self.itemActionRect(self.rowRect(row)).contains(point)) {
                        self.emit(.{ .action = row.item });
                        self.rows_dirty = true;
                        try self.ensureRows(allocator);
                        return true;
                    }
                    self.selectItem(allocator, row.item);
                }
                return true;
            }
            if (!self.pickerRect().contains(point)) {
                self.close(allocator);
                return true;
            }
            return true;
        }

        fn handleMouseMove(self: *Component, allocator: std.mem.Allocator, point: draw.Vec2, dragging: bool) !bool {
            if (!self.open) return false;
            self.hovered_rail = self.railItemAtPoint(point);
            if (self.hovered_rail != null and !dragging) return true;
            if (self.dragging_scrollbar and dragging) {
                const track = self.scrollbarTrackRect();
                const thumb = self.scrollbarThumbRect() orelse return true;
                self.scroll_y = scroll.offsetForThumbY(point.y, self.scrollbar_drag_offset_y, track, thumb, self.scrollMetrics());
                return true;
            }
            if (dragging and self.searchActive()) {
                if (try self.search.handleInput(allocator, .{ .mouse_drag = point })) return true;
            }
            if (self.rowAtPoint(point)) |row_index| {
                if (self.rows.items[row_index].kind == .item and self.highlighted != row_index) {
                    self.highlighted = row_index;
                    self.emitHighlight(row_index);
                }
                return true;
            }
            return self.pickerRect().contains(point);
        }

        fn selectItem(self: *Component, allocator: std.mem.Allocator, item: usize) void {
            self.selected_item = item;
            self.emit(.{ .selected = item });
            self.close(allocator);
        }

        // -- rendering ---------------------------------------------------------

        fn metrics(self: *const Component) text_layout.FontMetrics {
            if (self.font_metrics) |metrics_value| return metrics_value;
            const size = self.scaled(config.font_size);
            return text_layout.FontMetrics.fixed(size, self.scaled(config.glyph_width), size * 1.3);
        }

        fn derivedMetrics(_: *const Component, font_size: f32) text_layout.FontMetrics {
            return text_layout.FontMetrics.fixed(font_size, font_size * 0.55, font_size * 1.3);
        }

        // Renders the left group rail: the "all" entry plus one icon per
        // group, with an accent bar on the rail's right edge marking the
        // active filter.
        fn renderRail(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, picker: draw.Rect) !void {
            const rail = self.railRect();
            if (rail.w <= 0.0 or rail.h <= 0.0) return;
            const corner = @max(self.scaled(config.corner_radius) - @max(config.border_width, 1.0), 0.0);
            // Overhang the fill past the rail's right edge so only the left
            // corners round; the clip trims the rounded right side away.
            try batch.roundedRectClipped(allocator, .{
                .x = rail.x,
                .y = rail.y,
                .w = rail.w + corner,
                .h = rail.h,
            }, self.style.rail_background_color, corner, rail);
            const separator_w = @max(config.border_width, 1.0);
            try batch.rectClipped(allocator, .{
                .x = rail.x + rail.w - separator_w,
                .y = rail.y,
                .w = separator_w,
                .h = rail.h,
            }, self.style.border_color, picker);

            const active = self.activeGroupIndex();
            const icon_size = self.scaled(config.rail_icon_size);
            var index: usize = 0;
            while (index < self.groups.items.len + 1) : (index += 1) {
                const item_rect = self.railItemRect(index);
                const is_active = if (index == 0) active == null else active != null and active.? == index - 1;
                if (self.focused_rail == index or (self.hovered_rail == index and !is_active)) {
                    const pad = self.scaled(4.0);
                    try batch.roundedRectClipped(allocator, .{
                        .x = item_rect.x + pad,
                        .y = item_rect.y + pad,
                        .w = @max(item_rect.w - pad * 2.0, 0.0),
                        .h = @max(item_rect.h - pad * 2.0, 0.0),
                    }, self.style.highlighted_color, self.scaled(8.0), rail);
                }
                if (index == 0) {
                    if (config.rail_all_icon.len > 0) {
                        const icon_metrics = self.derivedMetrics(icon_size * 0.8);
                        const color = if (is_active) self.style.text_color else self.style.description_color;
                        try batch.roleText(allocator, .{
                            .x = item_rect.x + @max((item_rect.w - icon_metrics.measureSlice(config.rail_all_icon)) * 0.5, 0.0),
                            .y = item_rect.y + @max((item_rect.h - icon_metrics.line_height) * 0.5, 0.0),
                            .w = item_rect.w,
                            .h = icon_metrics.line_height,
                        }, config.rail_all_icon, color, icon_metrics.font_size, config.icon_font_role, config.icon_font_id, rail);
                    }
                } else if (config.render_rail_icon) |render_icon| {
                    render_icon(self.callbacks.context, allocator, batch, self.groups.items[index - 1], rail, .{
                        .x = item_rect.x + (item_rect.w - icon_size) * 0.5,
                        .y = item_rect.y + (item_rect.h - icon_size) * 0.5,
                        .w = icon_size,
                        .h = icon_size,
                    });
                }
                if (is_active) {
                    const bar_w = @max(self.scaled(3.0), 2.0);
                    try batch.roundedRectClipped(allocator, .{
                        .x = rail.x + rail.w - bar_w,
                        .y = item_rect.y + (item_rect.h - icon_size) * 0.5,
                        .w = bar_w,
                        .h = icon_size,
                    }, self.style.accent_color, bar_w * 0.5, rail);
                }
            }
        }

        // Renders the search area: optional leading icon glyph, the embedded
        // text input, and (in underline style) an accent rule underneath.
        fn renderSearch(self: *Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            const field = self.searchRect();
            if (config.search_icon.len > 0) {
                const icon_metrics = self.derivedMetrics(self.scaled(config.font_size));
                try batch.roleText(allocator, .{
                    .x = field.x,
                    .y = field.y + @max((field.h - icon_metrics.line_height) * 0.5, 0.0),
                    .w = icon_metrics.measureSlice(config.search_icon),
                    .h = icon_metrics.line_height,
                }, config.search_icon, self.style.description_color, icon_metrics.font_size, config.icon_font_role, config.icon_font_id, field);
            }
            self.search.setBounds(self.searchInputRect());
            self.search.z_index = self.z_index + 1;
            try self.search.render(allocator, batch);
            if (search_underline) {
                // The rule sits inside the search gap, separating query from
                // results like the reference design.
                try batch.rect(allocator, .{
                    .x = field.x,
                    .y = field.y + field.h + self.scaled(2.0),
                    .w = field.w,
                    .h = @max(self.scaled(1.5), 1.0),
                }, self.style.accent_color);
            }
        }

        fn renderHeaderRow(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, row: Row, row_rect: draw.Rect, clip: draw.Rect) !void {
            const label = itemText(config.item_group, self.callbacks.context, row.item);
            if (label.len == 0) return;
            const header_metrics = self.derivedMetrics(self.scaled(config.header_font_size));
            try batch.roleText(allocator, .{
                .x = row_rect.x + self.scaled(config.row_padding_x),
                .y = row_rect.y + @max((row_rect.h - header_metrics.line_height) * 0.5, 0.0),
                .w = @max(row_rect.w - self.scaled(config.row_padding_x) * 2.0, 0.0),
                .h = header_metrics.line_height,
            }, label, self.style.header_color, header_metrics.font_size, config.font_role, config.font_id, clip);
        }

        fn renderItemRow(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, row: Row, row_rect: draw.Rect, clip: draw.Rect) !void {
            const context = self.callbacks.context;
            const row_corner = @min(9.0, @max(4.0, row_rect.h * 0.24));
            const is_selected = self.selected_item != null and self.selected_item.? == row.item;
            const is_highlighted = self.highlighted != null and
                self.rows.items[self.highlighted.?].kind == .item and
                self.rows.items[self.highlighted.?].item == row.item;
            // Hover/keyboard highlight wins over the (often subtler) selected
            // fill so keyboard navigation stays visible on the selected row.
            if (is_highlighted) {
                try batch.roundedRectClipped(allocator, row_rect, self.style.highlighted_color, row_corner, clip);
            } else if (is_selected) {
                try batch.roundedRectClipped(allocator, row_rect, self.style.selected_color, row_corner, clip);
            }

            var x = row_rect.x + self.scaled(config.row_padding_x);
            if (config.render_row_leading != null and config.row_leading_width > 0.0 and !config.leading_on_description) {
                const leading_w = self.scaled(config.row_leading_width);
                const leading_rect: draw.Rect = .{
                    .x = x,
                    .y = row_rect.y,
                    .w = @min(leading_w, row_rect.w),
                    .h = row_rect.h,
                };
                config.render_row_leading.?(context, allocator, batch, row.item, clip, leading_rect);
                x += leading_w + self.scaled(config.row_leading_to_label_gap);
            }

            // Trailing cluster, right to left: shortcut chip, badge pill,
            // then a trailing check (unless the check renders inline after
            // the label); the label strip clips before all of them.
            var trailing_right = row_rect.x + row_rect.w - self.scaled(config.row_padding_x);
            const icon_metrics = self.derivedMetrics(self.scaled(config.font_size));
            if (config.item_action_icon.len > 0) {
                const active = if (config.item_action_active) |callback| callback(context, row.item) else false;
                const icon = if (active and config.item_action_active_icon.len > 0) config.item_action_active_icon else config.item_action_icon;
                const action_rect = self.itemActionRect(row_rect);
                const action_w = icon_metrics.measureSlice(icon);
                try batch.roleText(allocator, .{
                    .x = action_rect.x + @max((action_rect.w - action_w) * 0.5, 0.0),
                    .y = action_rect.y + @max((action_rect.h - icon_metrics.line_height) * 0.5, 0.0),
                    .w = action_w,
                    .h = icon_metrics.line_height,
                }, icon, if (active) self.style.accent_color else self.style.description_color, icon_metrics.font_size, config.icon_font_role, config.icon_font_id, clip);
                trailing_right = action_rect.x - self.scaled(config.icon_gap);
            }
            if (shortcut_chip_labels.len > 0 and row.ordinal < shortcut_chip_labels.len) {
                trailing_right = try self.renderShortcutChip(allocator, batch, shortcut_chip_labels[row.ordinal], row_rect, trailing_right, clip);
            }
            if (is_selected and config.check_icon.len > 0 and !config.check_inline) {
                const check_w = icon_metrics.measureSlice(config.check_icon);
                const check_x = trailing_right - check_w;
                try batch.roleText(allocator, .{
                    .x = check_x,
                    .y = row_rect.y + @max((row_rect.h - icon_metrics.line_height) * 0.5, 0.0),
                    .w = check_w,
                    .h = icon_metrics.line_height,
                }, config.check_icon, self.style.icon_color, icon_metrics.font_size, config.icon_font_role, config.icon_font_id, clip);
                trailing_right = check_x - self.scaled(config.icon_gap);
            }
            const badge = itemText(config.item_badge, context, row.item);
            if (badge.len > 0) {
                const badge_metrics = self.derivedMetrics(self.scaled(config.badge_font_size));
                const badge_text_w = badge_metrics.measureSlice(badge);
                const badge_pad = self.scaled(config.badge_padding_x);
                const badge_h = badge_metrics.line_height + self.scaled(4.0);
                const badge_w = badge_text_w + badge_pad * 2.0;
                const badge_rect: draw.Rect = .{
                    .x = trailing_right - badge_w,
                    .y = row_rect.y + (row_rect.h - badge_h) * 0.5,
                    .w = badge_w,
                    .h = badge_h,
                };
                try batch.roundedRectClipped(allocator, badge_rect, self.style.badge_background_color, badge_h * 0.5, clip);
                try batch.roleText(allocator, .{
                    .x = badge_rect.x + badge_pad,
                    .y = badge_rect.y + @max((badge_rect.h - badge_metrics.line_height) * 0.5, 0.0),
                    .w = badge_text_w,
                    .h = badge_metrics.line_height,
                }, badge, self.style.badge_text_color, badge_metrics.font_size, config.font_role, config.font_id, clip);
                trailing_right = badge_rect.x - self.scaled(config.icon_gap);
            }

            const label = itemText(config.item_label, context, row.item);
            const description = itemText(config.item_description, context, row.item);
            const label_w = @max(trailing_right - x, 0.0);
            const label_metrics = self.metrics();
            const label_clip = draw.Rect{ .x = x, .y = clip.y, .w = label_w, .h = clip.h };
            const description_metrics = self.derivedMetrics(self.scaled(config.description_font_size));
            const stack_h = if (description.len > 0)
                label_metrics.line_height + description_metrics.line_height
            else
                label_metrics.line_height;
            const top = row_rect.y + @max((row_rect.h - stack_h) * 0.5, 0.0);
            // An inline check reserves its width up front so a long label
            // truncates before it instead of pushing it past the clip.
            const inline_check = is_selected and config.check_inline and config.check_icon.len > 0;
            const check_w = icon_metrics.measureSlice(config.check_icon);
            const label_area_w = if (inline_check)
                @max(label_w - check_w - self.scaled(config.icon_gap), 0.0)
            else
                label_w;
            try batch.roleText(allocator, .{
                .x = x,
                .y = top,
                .w = label_area_w,
                .h = label_metrics.line_height,
            }, label, self.style.text_color, label_metrics.font_size, config.font_role, config.font_id, .{
                .x = x,
                .y = clip.y,
                .w = label_area_w,
                .h = clip.h,
            });
            if (inline_check) {
                try batch.roleText(allocator, .{
                    .x = x + @min(label_metrics.measureSlice(label), label_area_w) + self.scaled(config.icon_gap),
                    .y = top + (label_metrics.line_height - icon_metrics.line_height) * 0.5,
                    .w = check_w,
                    .h = icon_metrics.line_height,
                }, config.check_icon, self.style.accent_color, icon_metrics.font_size, config.icon_font_role, config.icon_font_id, label_clip);
            }
            if (description.len > 0) {
                var description_x = x;
                const description_y = top + label_metrics.line_height;
                if (config.leading_on_description and config.render_row_leading != null) {
                    // A small square icon (provider logo etc.) leads the
                    // description line, sized to that line's text height.
                    const icon_size = description_metrics.line_height * 0.9;
                    config.render_row_leading.?(context, allocator, batch, row.item, clip, .{
                        .x = description_x,
                        .y = description_y + (description_metrics.line_height - icon_size) * 0.5,
                        .w = icon_size,
                        .h = icon_size,
                    });
                    description_x += icon_size + self.scaled(6.0);
                }
                try batch.roleText(allocator, .{
                    .x = description_x,
                    .y = description_y,
                    .w = @max(trailing_right - description_x, 0.0),
                    .h = description_metrics.line_height,
                }, description, self.style.description_color, description_metrics.font_size, config.font_role, config.font_id, label_clip);
            }
        }

        fn itemActionRect(self: *const Component, row_rect: draw.Rect) draw.Rect {
            if (config.item_action_icon.len == 0) return .{ .x = row_rect.x + row_rect.w, .y = row_rect.y, .w = 0.0, .h = 0.0 };
            const size = self.scaled(26.0);
            return .{
                .x = row_rect.x + row_rect.w - self.scaled(config.row_padding_x) - size,
                .y = row_rect.y + (row_rect.h - size) * 0.5,
                .w = size,
                .h = size,
            };
        }

        // Renders one "Ctrl+n" shortcut chip (outlined pill) at the row's
        // trailing edge and returns the new trailing-right x.
        fn renderShortcutChip(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch, label: []const u8, row_rect: draw.Rect, trailing_right: f32, clip: draw.Rect) !f32 {
            const chip_metrics = self.derivedMetrics(self.scaled(config.badge_font_size));
            const text_w = chip_metrics.measureSlice(label);
            const pad = self.scaled(config.badge_padding_x);
            const chip_h = chip_metrics.line_height + self.scaled(6.0);
            const chip_rect: draw.Rect = .{
                .x = trailing_right - (text_w + pad * 2.0),
                .y = row_rect.y + (row_rect.h - chip_h) * 0.5,
                .w = text_w + pad * 2.0,
                .h = chip_h,
            };
            try batch.rectBorderClipped(allocator, chip_rect, self.style.border_color, self.scaled(5.0), @max(config.border_width, 1.0), clip);
            try batch.roleText(allocator, .{
                .x = chip_rect.x + pad,
                .y = chip_rect.y + @max((chip_rect.h - chip_metrics.line_height) * 0.5, 0.0),
                .w = text_w,
                .h = chip_metrics.line_height,
            }, label, self.style.badge_text_color, chip_metrics.font_size, config.font_role, config.font_id, clip);
            return chip_rect.x - self.scaled(config.icon_gap);
        }

        fn renderScrollbar(self: *const Component, allocator: std.mem.Allocator, batch: *draw.RenderBatch) !void {
            if (config.scrollbar_width <= 0.0 or scroll.maxOffsetY(self.scrollMetrics()) <= 0.0) return;
            const track = self.scrollbarTrackRect();
            try batch.scrollbar(allocator, track, self.style.scrollbar_track_color);
            if (self.scrollbarThumbRect()) |thumb| try batch.scrollbar(allocator, thumb, self.style.scrollbar_thumb_color);
        }

        fn emitHighlight(self: *Component, row_index: usize) void {
            if (row_index < self.rows.items.len and self.rows.items[row_index].kind == .item) {
                self.emit(.{ .highlighted = self.rows.items[row_index].item });
            }
        }

        fn emit(self: *Component, event: RichPickerEvent) void {
            if (self.callbacks.on_event) |callback| callback(self.callbacks.context, event);
        }
    };
}

/// In-order subsequence match; returns the number of gaps between matched
/// bytes (lower = tighter match) or null when the needle is not a subsequence.
fn subsequenceGaps(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var gaps: usize = 0;
    var last_match: ?usize = null;
    var haystack_index: usize = 0;
    for (needle) |byte| {
        const lowered = std.ascii.toLower(byte);
        var found: ?usize = null;
        while (haystack_index < haystack.len) : (haystack_index += 1) {
            if (std.ascii.toLower(haystack[haystack_index]) == lowered) {
                found = haystack_index;
                haystack_index += 1;
                break;
            }
        }
        const match = found orelse return null;
        if (last_match) |previous| {
            gaps += match - previous - 1;
        }
        last_match = match;
    }
    return gaps;
}

const TestContext = struct {
    selected: ?usize = null,
    open_events: usize = 0,
    close_events: usize = 0,
    favorites: [6]bool = .{ false, false, false, false, false, false },

    const labels = [_][]const u8{ "GPT-5.6 Sol", "GPT-5.5", "Claude Opus 4.7", "Claude Sonnet 4.5", "Composer 2", "Auto" };
    const groups = [_][]const u8{ "Codex", "Codex", "Claude", "Claude", "Cursor", "Cursor" };
    const descriptions = [_][]const u8{ "gpt-5.6-sol", "gpt-5.5", "claude-opus-4-7", "claude-sonnet-4-5", "composer-2", "auto" };

    fn label(_: ?*anyopaque, index: usize) []const u8 {
        return labels[index];
    }

    fn group(_: ?*anyopaque, index: usize) []const u8 {
        return groups[index];
    }

    fn description(_: ?*anyopaque, index: usize) []const u8 {
        return descriptions[index];
    }

    fn badge(_: ?*anyopaque, index: usize) []const u8 {
        return if (index == 0) "Default" else "";
    }

    fn favorite(context: ?*anyopaque, index: usize) bool {
        const self: *TestContext = @ptrCast(@alignCast(context.?));
        return self.favorites[index];
    }

    fn onEvent(context: ?*anyopaque, event: RichPickerEvent) void {
        const self: *TestContext = @ptrCast(@alignCast(context.?));
        switch (event) {
            .selected => |index| self.selected = index,
            .action => {},
            .open_changed => |open| if (open) {
                self.open_events += 1;
            } else {
                self.close_events += 1;
            },
            .highlighted => {},
        }
    }
};

const TestPicker = RichPicker(.{
    .width = 300,
    .row_height = 20,
    .row_height_with_description = 34,
    .header_row_height = 16,
    .max_body_height = 400,
    .search_enabled = true,
    .search_min_items = 3,
    .item_label = TestContext.label,
    .item_description = TestContext.description,
    .item_badge = TestContext.badge,
    .item_group = TestContext.group,
    .placement = .below,
});

fn testRailIcon(_: ?*anyopaque, _: std.mem.Allocator, _: *draw.RenderBatch, _: usize, _: draw.Rect, _: draw.Rect) void {}

const RailTestPicker = RichPicker(.{
    .width = 300,
    .row_height = 20,
    .row_height_with_description = 34,
    .max_body_height = 400,
    .fixed_body_height = 180,
    .search_enabled = true,
    .search_min_items = 3,
    .item_label = TestContext.label,
    .item_description = TestContext.description,
    .item_group = TestContext.group,
    .rail_enabled = true,
    .rail_width = 48,
    .rail_item_height = 40,
    .rail_all_icon = "*",
    .render_rail_icon = testRailIcon,
    .search_style = .underline,
    .search_icon = "?",
    .check_inline = true,
    .leading_on_description = true,
    .shortcut_badge_limit = 9,
    .placement = .below,
});

const FavoriteRailTestPicker = RichPicker(.{
    .width = 300,
    .row_height = 20,
    .row_height_with_description = 34,
    .max_body_height = 400,
    .fixed_body_height = 180,
    .search_enabled = true,
    .search_min_items = 3,
    .item_label = TestContext.label,
    .item_description = TestContext.description,
    .item_group = TestContext.group,
    .item_action_icon = "+",
    .item_action_active_icon = "*",
    .item_action_active = TestContext.favorite,
    .rail_enabled = true,
    .rail_width = 48,
    .rail_item_height = 40,
    .rail_all_icon = "*",
    .rail_primary_filter = TestContext.favorite,
    .render_rail_icon = testRailIcon,
    .placement = .below,
});

fn openedPickerOf(comptime Picker: type, context: *TestContext) !Picker {
    var picker = Picker.init(TestContext.labels.len);
    picker.setCallbacks(.{ .context = context, .on_event = TestContext.onEvent });
    picker.setAnchorRect(.{ .x = 10, .y = 10, .w = 100, .h = 20 });
    picker.setViewportRect(.{ .x = 0, .y = 0, .w = 800, .h = 900 });
    _ = try picker.handleInput(std.testing.allocator, .open);
    return picker;
}

fn openedTestPicker(context: *TestContext) !TestPicker {
    return openedPickerOf(TestPicker, context);
}

fn railItemCenter(picker: *const RailTestPicker, index: usize) draw.Vec2 {
    const rect = picker.railItemRect(index);
    return .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5 };
}

test "rich picker builds group headers and selects an item by mouse" {
    var context: TestContext = .{};
    var picker = try openedTestPicker(&context);
    defer picker.deinit(std.testing.allocator);

    // 6 items + 3 group headers.
    try std.testing.expectEqual(@as(usize, 9), picker.rows.items.len);
    try std.testing.expectEqual(TestPicker.Row{ .kind = .header, .item = 0, .y = 0, .h = 16 }, picker.rows.items[0]);

    const second_row = picker.rowRect(picker.rows.items[2]);
    _ = try picker.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = .{ .x = second_row.x + 4, .y = second_row.y + 4 } } });
    try std.testing.expectEqual(@as(?usize, 1), context.selected);
    try std.testing.expect(!picker.isOpen());
}

test "rich picker search filters, ranks, and enter selects" {
    var context: TestContext = .{};
    var picker = try openedTestPicker(&context);
    defer picker.deinit(std.testing.allocator);

    _ = try picker.handleInput(std.testing.allocator, .{ .text = "sonnet" });
    try picker.ensureRows(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), picker.filtered.items.len);
    try std.testing.expectEqual(@as(usize, 3), picker.filtered.items[0]);

    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .enter } });
    try std.testing.expectEqual(@as(?usize, 3), context.selected);
    try std.testing.expect(!picker.isOpen());
}

test "rich picker escape clears query first then closes" {
    var context: TestContext = .{};
    var picker = try openedTestPicker(&context);
    defer picker.deinit(std.testing.allocator);

    _ = try picker.handleInput(std.testing.allocator, .{ .text = "opus" });
    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .escape } });
    try std.testing.expect(picker.isOpen());
    try std.testing.expectEqual(@as(usize, 0), picker.searchText().len);

    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .escape } });
    try std.testing.expect(!picker.isOpen());
    try std.testing.expectEqual(@as(usize, 1), context.close_events);
}

test "rich picker keyboard navigation skips headers" {
    var context: TestContext = .{};
    var picker = try openedTestPicker(&context);
    defer picker.deinit(std.testing.allocator);

    picker.setSelectedItem(0);
    _ = try picker.handleInput(std.testing.allocator, .close);
    _ = try picker.handleInput(std.testing.allocator, .open);
    // Highlight starts at the selected item's row (row 1: header + item).
    try std.testing.expectEqual(@as(?usize, 1), picker.highlighted);
    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .down } });
    try std.testing.expectEqual(@as(?usize, 2), picker.highlighted);
    // Next down crosses the "Claude" header row (index 3) onto item row 4.
    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .down } });
    try std.testing.expectEqual(@as(?usize, 4), picker.highlighted);
    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .up } });
    try std.testing.expectEqual(@as(?usize, 2), picker.highlighted);
}

test "rich picker places below anchor and clamps to viewport" {
    var context: TestContext = .{};
    var picker = try openedTestPicker(&context);
    defer picker.deinit(std.testing.allocator);

    const rect = picker.pickerRect();
    try std.testing.expectEqual(@as(f32, 10), rect.x);
    try std.testing.expect(rect.y >= 30.0);

    // Anchor near the right edge: the popover must slide left to stay inside.
    picker.setAnchorRect(.{ .x = 280, .y = 10, .w = 100, .h = 20 });
    picker.setViewportRect(.{ .x = 0, .y = 0, .w = 320, .h = 900 });
    const clamped = picker.pickerRect();
    try std.testing.expect(clamped.x + clamped.w <= 320.0);
}

test "rich picker rail filters by group without headers" {
    var context: TestContext = .{};
    var picker = try openedPickerOf(RailTestPicker, &context);
    defer picker.deinit(std.testing.allocator);

    // Rail mode renders no header rows even though every item has a group.
    try std.testing.expectEqual(@as(usize, TestContext.labels.len), picker.rows.items.len);
    try std.testing.expectEqual(@as(usize, 3), picker.groups.items.len);
    const picker_height = picker.pickerRect().h;

    // Rail entry 0 is "All"; entry 2 is the second group ("Claude").
    _ = try picker.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = railItemCenter(&picker, 2) } });
    try std.testing.expect(picker.isOpen());
    try std.testing.expectEqual(@as(usize, 2), picker.rows.items.len);
    try std.testing.expectEqual(@as(usize, 2), picker.rows.items[0].item);
    try std.testing.expectEqual(@as(usize, 3), picker.rows.items[1].item);
    try std.testing.expectEqual(picker_height, picker.pickerRect().h);

    _ = try picker.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = railItemCenter(&picker, 0) } });
    try std.testing.expectEqual(@as(usize, TestContext.labels.len), picker.rows.items.len);
}

test "rich picker primary rail entry filters to marked items" {
    var context: TestContext = .{};
    context.favorites[1] = true;
    context.favorites[4] = true;
    var picker = try openedPickerOf(FavoriteRailTestPicker, &context);
    defer picker.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), picker.filtered.items.len);
    try std.testing.expectEqual(@as(usize, 1), picker.filtered.items[0]);
    try std.testing.expectEqual(@as(usize, 4), picker.filtered.items[1]);

    const codex_rail = picker.railItemRect(1);
    _ = try picker.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = .{ .x = codex_rail.x + codex_rail.w * 0.5, .y = codex_rail.y + codex_rail.h * 0.5 } } });
    try std.testing.expectEqual(@as(usize, 2), picker.filtered.items.len);
    try std.testing.expectEqual(@as(usize, 0), picker.filtered.items[0]);
    try std.testing.expectEqual(@as(usize, 1), picker.filtered.items[1]);
}

test "rich picker arrows move between model rows and provider rail" {
    var context: TestContext = .{};
    var picker = try openedPickerOf(RailTestPicker, &context);
    defer picker.deinit(std.testing.allocator);

    // Left enters the rail at the provider of the highlighted model.
    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .left } });
    try std.testing.expectEqual(@as(?usize, 1), picker.focused_rail);
    try std.testing.expect(!picker.search.focused);

    // Vertical movement chooses and filters to the adjacent provider.
    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .down } });
    try std.testing.expectEqual(@as(?usize, 2), picker.focused_rail);
    try std.testing.expectEqual(@as(usize, 2), picker.rows.items.len);
    try std.testing.expectEqual(@as(usize, 2), picker.rows.items[0].item);

    // Right returns focus to the model list, where vertical navigation works
    // as before.
    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .right } });
    try std.testing.expectEqual(@as(?usize, null), picker.focused_rail);
    try std.testing.expect(picker.search.focused);
    _ = try picker.handleInput(std.testing.allocator, .{ .key = .{ .code = .down } });
    try std.testing.expectEqual(@as(?usize, 1), picker.highlighted);
}

test "rich picker shortcut ordinal selects within the rail filter" {
    var context: TestContext = .{};
    var picker = try openedPickerOf(RailTestPicker, &context);
    defer picker.deinit(std.testing.allocator);

    _ = try picker.handleInput(std.testing.allocator, .{ .mouse_down = .{ .point = railItemCenter(&picker, 2) } });
    // Ordinal 1 of the filtered view is the group's second item (item 3).
    try std.testing.expect(try picker.selectVisibleOrdinal(std.testing.allocator, 1));
    try std.testing.expectEqual(@as(?usize, 3), context.selected);
    try std.testing.expect(!picker.isOpen());
}

test "rich picker rail mode renders rail, chips, and underline" {
    var context: TestContext = .{};
    var picker = try openedPickerOf(RailTestPicker, &context);
    defer picker.deinit(std.testing.allocator);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try picker.render(std.testing.allocator, &batch);

    var text_commands: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .text) text_commands += 1;
    }
    // Labels + descriptions + shortcut chips + rail "all" glyph + search icon.
    try std.testing.expect(text_commands >= TestContext.labels.len * 3 + 2);
    // The picker widens by the rail and the body starts right of it.
    try std.testing.expect(picker.bodyRect().x >= picker.pickerRect().x + 48.0);
}

test "rich picker renders labels, descriptions, badges, and search" {
    var context: TestContext = .{};
    var picker = try openedTestPicker(&context);
    defer picker.deinit(std.testing.allocator);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try picker.render(std.testing.allocator, &batch);

    var text_commands: usize = 0;
    var rect_commands: usize = 0;
    for (batch.commands.items) |command| {
        switch (command.kind) {
            .text => text_commands += 1,
            .rect => rect_commands += 1,
            else => {},
        }
    }
    try std.testing.expect(text_commands >= TestContext.labels.len * 2);
    try std.testing.expect(rect_commands >= 2);
}
