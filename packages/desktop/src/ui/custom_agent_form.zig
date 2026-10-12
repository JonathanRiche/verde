//! Overlay form for adding or editing a custom ACP agent: name, the stdio
//! command line that starts its ACP server, and optional environment pairs.
//! Model and persistence live in `state/custom_agent_form.zig`.

const std = @import("std");
const palette = @import("palette");
const theme = @import("theme.zig");
const runtime = @import("runtime.zig");
const form_state = @import("../state/custom_agent_form.zig");

const log = std.log.scoped(.custom_agent_form_ui);

const Field = form_state.Field;

const FIELD_LABELS = [_][]const u8{ "Name", "Command", "Environment (optional)" };
const FIELD_PLACEHOLDERS = [_][]const u8{
    "Gemini CLI",
    "gemini --acp",
    "API_KEY=value OTHER='two words'",
};
const SUBTITLE = "Verde starts this command and talks to it over stdin/stdout using the Agent Client Protocol (ACP).";
const HINT = "Tab switches fields \u{00B7} Enter saves \u{00B7} Esc cancels";

// Geometry, recomputed every frame by `computeLayout`.
var modal_rect: palette.Rect = .{};
var field_rects: [Field.all.len]palette.Rect = @splat(.{});
var label_ys: [Field.all.len]f32 = @splat(0.0);
var cancel_rect: palette.Rect = .{};
var save_rect: palette.Rect = .{};
var footer_y: f32 = 0.0;

pub fn isOpen(state: *const runtime.AppState) bool {
    return state.custom_agent_form.open;
}

fn computeLayout(width: f32, height: f32) void {
    const modal_w = theme.clampf(width * 0.5, theme.scaledUi(480.0), theme.scaledUi(640.0));
    const pad = theme.scaledUi(20.0);
    const label_h = theme.scaledUi(18.0);
    const field_h = theme.scaledUi(36.0);
    const field_gap = theme.scaledUi(14.0);
    const button_h = theme.scaledUi(34.0);
    const header_h = theme.scaledUi(22.0) + theme.scaledUi(8.0) + theme.scaledUi(34.0);
    const fields_h = @as(f32, @floatFromInt(Field.all.len)) * (label_h + theme.scaledUi(4.0) + field_h + field_gap);
    const modal_h = pad * 2.0 + header_h + theme.scaledUi(10.0) + fields_h + button_h;
    modal_rect = .{
        .x = @round((width - modal_w) * 0.5),
        .y = @round(@max((height - modal_h) * 0.5, theme.scaledUi(12.0))),
        .w = @round(modal_w),
        .h = @round(modal_h),
    };
    const inner_x = modal_rect.x + pad;
    const inner_w = modal_rect.w - pad * 2.0;
    var y = modal_rect.y + pad + header_h + theme.scaledUi(10.0);
    for (Field.all, 0..) |_, index| {
        label_ys[index] = y;
        y += label_h + theme.scaledUi(4.0);
        field_rects[index] = .{ .x = inner_x, .y = y, .w = inner_w, .h = field_h };
        y += field_h + field_gap;
    }
    footer_y = modal_rect.y + modal_rect.h - pad - button_h;
    save_rect = .{ .x = inner_x + inner_w - theme.scaledUi(110.0), .y = footer_y, .w = theme.scaledUi(110.0), .h = button_h };
    cancel_rect = .{ .x = save_rect.x - theme.scaledUi(10.0) - theme.scaledUi(96.0), .y = footer_y, .w = theme.scaledUi(96.0), .h = button_h };
}

pub fn registerHits(
    state: *runtime.AppState,
    width: f32,
    height: f32,
    queueHit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    if (!isOpen(state)) return;
    computeLayout(width, height);
    // Outside clicks are swallowed rather than dismissing: a stray click must
    // not discard a half-typed command line.
    queueHit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .custom_agent_block, 0);
    queueHit(state, modal_rect, .custom_agent_block, 0);
    for (field_rects, 0..) |rect, index| queueHit(state, rect, .custom_agent_input, index);
    queueHit(state, cancel_rect, .custom_agent_cancel, 0);
    queueHit(state, save_rect, .custom_agent_save, 0);
}

/// Focus target for a click on field `index`; layout's shared modal text
/// handling places the caret.
pub fn focusForInput(index: usize) runtime.PaletteModalTextFocus {
    const field = Field.all[@min(index, Field.all.len - 1)];
    return form_state.focusForField(runtime.PaletteModalTextFocus, field);
}

pub fn handleClick(state: *runtime.AppState, action: runtime.PaletteModalAction) void {
    switch (action) {
        .custom_agent_cancel => form_state.close(state),
        .custom_agent_save => form_state.submit(state),
        else => {},
    }
    state.markDirty();
}

pub fn handleKeyDown(state: *runtime.AppState, event: *const palette.event.KeyEvent) bool {
    if (!isOpen(state)) return false;
    switch (event.key) {
        .escape => form_state.close(state),
        .tab => form_state.cycleField(state, event.mod.shift),
        .@"return", .kp_enter => form_state.submit(state),
        else => return false,
    }
    state.markDirty();
    return true;
}

pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!isOpen(state)) return;
    computeLayout(width, height);
    const form = &state.custom_agent_form;

    queueRect(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, theme.scrim(0.55));
    queuePanel(state, modal_rect, theme.raise(theme.background(), 0.04), theme.COLOR_PANEL_MUTED, theme.scaledUi(14.0), 1.0);

    const pad = theme.scaledUi(20.0);
    const title = if (form.editing_index != null) "Edit custom ACP agent" else "Add custom ACP agent";
    queueText(state, .{ .x = modal_rect.x + pad, .y = modal_rect.y + pad, .w = modal_rect.w - pad * 2.0, .h = theme.scaledUi(22.0) }, title, theme.COLOR_WHITE, theme.scaledUi(17.0), modal_rect);
    const subtitle_size = theme.scaledUi(12.5);
    queueText(state, .{ .x = modal_rect.x + pad, .y = modal_rect.y + pad + theme.scaledUi(30.0), .w = modal_rect.w - pad * 2.0, .h = subtitle_size * 1.3 }, SUBTITLE, theme.COLOR_TEXT_SUBTLE, subtitle_size, modal_rect);

    for (Field.all, 0..) |field, index| {
        const label_size = theme.scaledUi(12.5);
        queueText(state, .{ .x = field_rects[index].x, .y = label_ys[index], .w = field_rects[index].w, .h = label_size * 1.3 }, FIELD_LABELS[index], theme.COLOR_TEXT_MUTED, label_size, modal_rect);
        renderField(state, field, index);
    }

    const size = theme.scaledUi(12.0);
    const info_rect: palette.Rect = .{ .x = modal_rect.x + pad, .y = footer_y, .w = @max(cancel_rect.x - modal_rect.x - pad - theme.scaledUi(12.0), 0.0), .h = cancel_rect.h };
    const notice_text = if (form.notice.len > 0) form.notice else HINT;
    queueText(state, .{ .x = info_rect.x, .y = info_rect.y + (info_rect.h - size * 1.25) * 0.5, .w = info_rect.w, .h = size * 1.25 }, notice_text, if (form.notice.len > 0) theme.COLOR_YELLOW else theme.COLOR_TEXT_SUBTLE, size, info_rect);
    renderButton(state, cancel_rect, "Cancel", false);
    renderButton(state, save_rect, if (form.editing_index != null) "Save" else "Add agent", true);
}

fn renderField(state: *runtime.AppState, field: Field, index: usize) void {
    const form = &state.custom_agent_form;
    const rect = field_rects[index];
    const focused = form_state.focusedField(state.palette_modal_text_focus) == field;
    const value = form.value(field);
    const cursor = @min(form.cursor(field).*, value.len);
    queuePanel(state, rect, theme.background(), if (focused) theme.accent() else theme.COLOR_PANEL_MUTED, theme.scaledUi(7.0), 1.0);

    const font_size = theme.scaledUi(14.0);
    const line_height = font_size * 1.25;
    const text_x = rect.x + theme.scaledUi(10.0);
    const text_y = rect.y + (rect.h - line_height) * 0.5;
    const text_w = rect.w - theme.scaledUi(20.0);
    if (focused) {
        state.modal_text_input_rect = rect;
        state.modal_text_input_font_size = font_size;
        if (state.modal_text_selection_anchor) |anchor| {
            const a = @min(anchor, value.len);
            if (a != cursor) {
                const x0 = @max(text_x + runtime.paletteUiTextPrefixWidth(value, font_size, @min(a, cursor)), text_x);
                const x1 = @min(text_x + runtime.paletteUiTextPrefixWidth(value, font_size, @max(a, cursor)), text_x + text_w);
                if (x1 > x0) queueRect(state, .{ .x = x0, .y = text_y, .w = x1 - x0, .h = line_height }, theme.withAlpha(theme.selection(), 200));
            }
        }
    }
    const shown = if (value.len > 0) value else FIELD_PLACEHOLDERS[index];
    queueText(state, .{ .x = text_x, .y = text_y, .w = text_w, .h = line_height }, shown, if (value.len > 0) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE, font_size, rect);
    if (focused) {
        const cursor_x = @min(text_x + runtime.paletteUiTextPrefixWidth(value, font_size, cursor), text_x + text_w);
        queueRect(state, .{ .x = @round(cursor_x), .y = text_y, .w = @max(@round(theme.scaledUi(1.0)), 1.0), .h = line_height }, theme.COLOR_WHITE);
    }
}

fn renderButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, primary: bool) void {
    const hovered = rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    const base = if (primary) theme.accent() else theme.raise(theme.background(), 0.08);
    const fill = if (hovered) theme.raise(base, 0.06) else base;
    queuePanel(state, rect, fill, if (primary) fill else theme.COLOR_PANEL_MUTED, theme.scaledUi(7.0), 1.0);
    const font_size = theme.scaledUi(13.5);
    const max_w = rect.w - theme.scaledUi(20.0);
    const label_w = @min(runtime.paletteUiTextPrefixWidth(label, font_size, label.len), max_w);
    queueText(state, .{ .x = rect.x + (rect.w - label_w) * 0.5, .y = rect.y + (rect.h - font_size * 1.25) * 0.5, .w = label_w, .h = font_size * 1.25 }, label, if (primary) theme.foregroundOn(fill) else theme.COLOR_WHITE, font_size, rect);
}

// ---------------------------------------------------------------------------
// Draw helpers
// ---------------------------------------------------------------------------

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn intersect(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
}

fn stableText(state: *runtime.AppState, value: []const u8) ?[]const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch |err| {
        log.warn("failed to retain custom agent form text: {s}", .{@errorName(err)});
        return null;
    };
}

fn queueRect(state: *runtime.AppState, rect: palette.Rect, color: [4]f32) void {
    state.palette_overlay_batch.rect(state.allocator, rect, paletteColor(color)) catch {};
}

/// One bordered surface per Palette's crisp-chrome rules: a single `panel`
/// command on pixel-snapped edges with a whole-pixel stroke.
fn queuePanel(state: *runtime.AppState, rect: palette.Rect, fill: [4]f32, border: [4]f32, radius: f32, width_ui: f32) void {
    const left = @round(rect.x);
    const top = @round(rect.y);
    const snapped: palette.Rect = .{ .x = left, .y = top, .w = @round(rect.x + rect.w) - left, .h = @round(rect.y + rect.h) - top };
    const stroke = @max(@round(theme.scaledUi(width_ui)), 1.0);
    state.palette_overlay_batch.panel(state.allocator, snapped, paletteColor(fill), paletteColor(border), radius, stroke) catch {};
}

fn queueText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: [4]f32, font_size: f32, clip: palette.Rect) void {
    const stable_value = stableText(state, value) orelse return;
    const effective_clip = intersect(.{ .x = rect.x, .y = clip.y, .w = rect.w, .h = clip.h }, clip);
    if (effective_clip.w <= 0.0 or effective_clip.h <= 0.0) return;
    state.palette_overlay_batch.roleText(state.allocator, rect, stable_value, paletteColor(color), font_size, .ui, null, effective_clip) catch {};
}
