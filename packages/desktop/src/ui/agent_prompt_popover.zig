//! "Ask agent" popover: an instruction field floating next to a line
//! selection (file viewer, Changes diff). On send it formats the message
//! every client shares (`verde_remote.selection_prompt`) and delivers it to
//! the focused tab's chat, or the workspace's current chat when that tab has
//! none (file tabs):
//! - idle chat with a clean composer: sent right away;
//! - chat mid-turn with a clean composer: queued as a follow-up (steer for
//!   Codex), the same as queuing from the composer;
//! - otherwise (draft text or images, or a follow-up already queued): the
//!   prompt is appended to the draft, never replacing it.
//!
//! Entry point: `open(state, .{ .anchor, .path, .first_line, .last_line,
//! .side, .selection_text })`. One popover exists at a time; opening again
//! replaces it.
//!
//! Hook contract (`main.zig` routes these before panes and the side panel,
//! after true modals; `layout.zig` calls `render`):
//! - `render(state, width, height)` draws above panes, below modals.
//! - `handleKeyDown` / `handleTextInput` consume every key and text event
//!   while open (Escape cancels, Enter sends, Shift+Enter adds a line).
//! - `handleMouseButton` / `handleMouseMotion` / `handleWheel` consume
//!   events over the card. A press outside closes an empty popover and
//!   passes through; with typed text it is swallowed so nothing is lost.
//! - `wantsTextInput` keeps SDL text input on while open.
//! - `systemCursorAt` picks the pointer over the card.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");
const text_edit = @import("text_edit.zig");
const selection_prompt = @import("verde_remote").selection_prompt;

const AppState = runtime.AppState;
const log = std.log.scoped(.agent_prompt_popover);

pub const Side = selection_prompt.Side;

pub const Request = struct {
    /// Window-space rect the card attaches to (below it, else above).
    anchor: palette.Rect,
    /// Absolute path; for diffs the repository root joined with the path.
    path: []const u8,
    /// 1-based, inclusive.
    first_line: u32,
    last_line: u32,
    /// Diff side, or null outside a diff.
    side: ?Side = null,
    /// Selected source text (copied on open).
    selection_text: []const u8,
};

// Geometry tokens (CSS px).
const CARD_W_UI: f32 = 460.0;
const MARGIN_UI: f32 = 12.0;
const GAP_UI: f32 = 6.0;
const PAD_UI: f32 = 12.0;
const HEADER_H_UI: f32 = 30.0;
const PREVIEW_LINES: usize = 3;
const PREVIEW_FONT_UI: f32 = 12.0;
const PREVIEW_LINE_UI: f32 = 17.0;
const FIELD_FONT_UI: f32 = 13.5;
const FIELD_LINE_UI: f32 = 20.0;
const FIELD_MIN_LINES: f32 = 2.0;
const FIELD_MAX_LINES: f32 = 8.0;
const FIELD_PAD_UI: f32 = 8.0;
const FOOTER_H_UI: f32 = 40.0;
const BUTTON_H_UI: f32 = 28.0;
const RADIUS_UI: f32 = 10.0;
const MAX_INSTRUCTION_BYTES = 8 * 1024;
const MAX_VISUAL_LINES = 1024;
const PALETTE_SHADOW_ALPHA: u8 = 90;

const NF_COD_HUBOT = "\u{EB08}";
const NF_COD_CLOSE = "\u{EA76}";
const NF_COD_ARROW_UP = "\u{EAA1}";

const Hit = enum { none, close, cancel, send, field, card };

const VisualLine = struct { start: usize, end: usize };

// ------------------------------------------------------------------
// State (UI thread only)
// ------------------------------------------------------------------

var is_open: bool = false;
var request_anchor: palette.Rect = .{};
var request_path: std.ArrayList(u8) = .empty;
var request_text: std.ArrayList(u8) = .empty;
var request_first: u32 = 1;
var request_last: u32 = 1;
var request_side: ?Side = null;

var field: text_edit.Field = .{ .multiline = true, .max_bytes = MAX_INSTRUCTION_BYTES };
var field_drag: bool = false;
var field_scroll: f32 = 0.0;
/// Preferred caret x for Up/Down across wrapped lines.
var goal_x: ?f32 = null;

var visual: [MAX_VISUAL_LINES]VisualLine = undefined;
var visual_count: usize = 0;

var card_rect: palette.Rect = .{};
var field_rect: palette.Rect = .{};
var field_text_rect: palette.Rect = .{};
var close_rect: palette.Rect = .{};
var cancel_rect: palette.Rect = .{};
var send_rect: palette.Rect = .{};
var mouse: [2]f32 = .{ -1.0, -1.0 };

const page = std.heap.page_allocator;

pub fn isOpen() bool {
    return is_open;
}

/// Opens (or replaces) the popover for a selection. Copies everything.
pub fn open(state: *AppState, request: Request) void {
    if (request.first_line == 0 or request.path.len == 0) return;
    request_path.clearRetainingCapacity();
    request_text.clearRetainingCapacity();
    request_path.appendSlice(page, request.path) catch return;
    const capped = request.selection_text[0..@min(request.selection_text.len, selection_prompt.MAX_SELECTION_BYTES)];
    request_text.appendSlice(page, capped) catch return;
    request_anchor = request.anchor;
    request_first = request.first_line;
    request_last = @max(request.last_line, request.first_line);
    request_side = request.side;
    field.clear();
    field_scroll = 0.0;
    field_drag = false;
    goal_x = null;
    is_open = true;
    state.markDirty();
}

pub fn close(state: *AppState) void {
    if (!is_open) return;
    is_open = false;
    field_drag = false;
    field.clear();
    state.markDirty();
}

// ------------------------------------------------------------------
// Rendering
// ------------------------------------------------------------------

pub fn render(state: *AppState, width: f32, height: f32) void {
    // Card: header (agent glyph, title, location, close), a preview of the
    // selected lines, the instruction field, then target chat + buttons.
    if (!is_open) return;
    const margin = theme.scaledUi(MARGIN_UI);
    const pad = theme.scaledUi(PAD_UI);
    const card_w = @min(theme.scaledUi(CARD_W_UI), @max(width - margin * 2.0, 0.0));
    if (card_w <= pad * 4.0) return;

    const field_font = theme.scaledUi(FIELD_FONT_UI);
    const field_line = theme.scaledUi(FIELD_LINE_UI);
    const field_pad = theme.scaledUi(FIELD_PAD_UI);
    const text_w = @max(card_w - pad * 2.0 - field_pad * 2.0, 1.0);
    layoutVisualLines(field.value(), text_w, field_font);
    const shown_lines = std.math.clamp(@as(f32, @floatFromInt(@max(visual_count, 1))), FIELD_MIN_LINES, FIELD_MAX_LINES);
    const field_h = shown_lines * field_line + field_pad * 2.0;

    const preview_count = @min(previewLineCount(), PREVIEW_LINES);
    const preview_line = theme.scaledUi(PREVIEW_LINE_UI);
    const preview_h = if (preview_count > 0) @as(f32, @floatFromInt(preview_count)) * preview_line + theme.scaledUi(10.0) else 0.0;
    const header_h = theme.scaledUi(HEADER_H_UI);
    const footer_h = theme.scaledUi(FOOTER_H_UI);
    const gap = theme.scaledUi(GAP_UI);
    const card_h = pad + header_h + (if (preview_h > 0) preview_h + gap else 0.0) + field_h + footer_h;

    // Below the anchor when it fits, else above, clamped to the window.
    var x = request_anchor.x;
    var y = request_anchor.y + request_anchor.h + gap;
    if (y + card_h > height - margin and request_anchor.y - gap - card_h >= margin) y = request_anchor.y - gap - card_h;
    x = std.math.clamp(x, margin, @max(width - margin - card_w, margin));
    y = std.math.clamp(y, margin, @max(height - margin - card_h, margin));
    card_rect = snap(.{ .x = x, .y = y, .w = card_w, .h = card_h });
    const window: palette.Rect = .{ .x = 0, .y = 0, .w = width, .h = height };

    // Soft shadow, then one bordered panel.
    const shadow = theme.scaledUi(6.0);
    queueRounded(state, .{ .x = card_rect.x - shadow * 0.5, .y = card_rect.y, .w = card_rect.w + shadow, .h = card_rect.h + shadow }, theme.withAlpha(.{ 0, 0, 0, 1 }, PALETTE_SHADOW_ALPHA), theme.scaledUi(RADIUS_UI) + shadow * 0.5, window);
    state.palette_overlay_batch.panel(state.allocator, card_rect, paletteColor(theme.COLOR_PANEL_ALT), paletteColor(theme.borderMuted()), theme.scaledUi(RADIUS_UI), @max(@round(theme.scaledUi(1.0)), 1.0)) catch {};

    var cy = card_rect.y + pad * 0.5;
    renderHeader(state, .{ .x = card_rect.x + pad, .y = cy, .w = card_w - pad * 2.0, .h = header_h });
    cy += header_h;
    if (preview_h > 0) {
        renderPreview(state, .{ .x = card_rect.x + pad, .y = cy, .w = card_w - pad * 2.0, .h = preview_h }, preview_count);
        cy += preview_h + gap;
    }
    field_rect = .{ .x = card_rect.x + pad, .y = cy, .w = card_w - pad * 2.0, .h = field_h };
    renderField(state, field_font, field_line, field_pad);
    cy += field_h;
    renderFooter(state, .{ .x = card_rect.x + pad, .y = cy, .w = card_w - pad * 2.0, .h = footer_h });
}

fn renderHeader(state: *AppState, rect: palette.Rect) void {
    const font = theme.scaledUi(13.0);
    const text_h = font * 1.4;
    const text_y = rect.y + (rect.h - text_h) * 0.5;
    const icon_w = theme.scaledUi(20.0);
    queueIcon(state, .{ .x = rect.x, .y = rect.y, .w = icon_w, .h = rect.h }, NF_COD_HUBOT, theme.accent(), theme.scaledUi(14.0), card_rect);
    var x = rect.x + icon_w + theme.scaledUi(6.0);
    const title = "Ask agent";
    const title_w = text_measure.textWidth(.ui_bold, font, title);
    queueText(state, .{ .x = x, .y = text_y, .w = title_w + 1.0, .h = text_h }, title, theme.COLOR_WHITE, font, .ui_bold, card_rect);
    x += title_w + theme.scaledUi(10.0);

    const button = theme.scaledUi(24.0);
    close_rect = .{ .x = rect.x + rect.w - button, .y = rect.y + (rect.h - button) * 0.5, .w = button, .h = button };
    const close_hovered = contains(close_rect, mouse[0], mouse[1]);
    if (close_hovered) queueRounded(state, close_rect, theme.withAlpha(theme.COLOR_PANEL_MUTED, 220), theme.scaledUi(6.0), card_rect);
    queueIcon(state, close_rect, NF_COD_CLOSE, if (close_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED, theme.scaledUi(12.0), card_rect);

    const location = locationLabel(state) catch return;
    const small = theme.scaledUi(12.0);
    const max_w = @max(close_rect.x - theme.scaledUi(8.0) - x, 0.0);
    const shown = elideStart(state, location, small, max_w);
    queueText(state, .{ .x = x, .y = rect.y + (rect.h - small * 1.4) * 0.5, .w = max_w, .h = small * 1.4 }, shown, theme.COLOR_TEXT_SUBTLE, small, .ui, card_rect);
}

/// "path · lines A–B (diff, new side)" in the frame arena.
fn locationLabel(state: *AppState) ![]const u8 {
    const arena = state.palette_frame_text_arena.allocator();
    const roots = try promptRoots(arena, state);
    const display = try selection_prompt.displayPath(arena, request_path.items, roots);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s} \u{00B7} ", .{display});
    if (request_first == request_last) {
        try out.print(arena, "line {d}", .{request_first});
    } else try out.print(arena, "lines {d}\u{2013}{d}", .{ request_first, request_last });
    if (request_side) |side| try out.print(arena, " ({s} side)", .{@tagName(side)});
    return out.items;
}

fn previewLineCount() usize {
    const text = std.mem.trimEnd(u8, request_text.items, "\r\n");
    if (text.len == 0) return 0;
    return std.mem.count(u8, text, "\n") + 1;
}

fn renderPreview(state: *AppState, rect: palette.Rect, count: usize) void {
    queueRounded(state, rect, theme.md.code_bg, theme.scaledUi(6.0), card_rect);
    const font = theme.scaledUi(PREVIEW_FONT_UI);
    const line_h = theme.scaledUi(PREVIEW_LINE_UI);
    const inset = theme.scaledUi(8.0);
    const clip = intersect(.{ .x = rect.x + inset, .y = rect.y, .w = rect.w - inset * 2.0, .h = rect.h }, card_rect);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, request_text.items, "\r\n"), '\n');
    var index: usize = 0;
    const total = previewLineCount();
    while (lines.next()) |raw| : (index += 1) {
        if (index >= count) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const y = rect.y + theme.scaledUi(5.0) + @as(f32, @floatFromInt(index)) * line_h;
        const is_last_shown = index + 1 == count and total > count;
        const shown = if (is_last_shown)
            std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "\u{2026} {d} more lines", .{total - count + 1}) catch ""
        else
            expandTabs(state, line);
        const role: palette.FontRole = if (is_last_shown) .ui else .mono;
        const color = if (is_last_shown) theme.COLOR_TEXT_SUBTLE else theme.md.tok_plain;
        const w = text_measure.textWidth(role, font, shown);
        queueText(state, .{ .x = rect.x + inset, .y = y, .w = @max(w, 1.0), .h = line_h }, shown, color, font, role, clip);
    }
}

fn expandTabs(state: *AppState, line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '\t') == null) return line;
    return std.mem.replaceOwned(u8, state.palette_frame_text_arena.allocator(), line, "\t", "    ") catch line;
}

fn renderField(state: *AppState, font: f32, line_h: f32, field_pad: f32) void {
    const radius = theme.scaledUi(6.0);
    const stroke = @max(@round(theme.scaledUi(1.0)), 1.0);
    state.palette_overlay_batch.panel(state.allocator, snap(field_rect), paletteColor(theme.COLOR_PANEL), paletteColor(theme.withAlpha(theme.accent(), 200)), radius, stroke) catch {};
    field_text_rect = .{ .x = field_rect.x + field_pad, .y = field_rect.y + field_pad, .w = field_rect.w - field_pad * 2.0, .h = field_rect.h - field_pad * 2.0 };
    const clip = intersect(.{ .x = field_rect.x + stroke, .y = field_text_rect.y, .w = field_rect.w - stroke * 2.0, .h = field_text_rect.h }, card_rect);
    const text = field.value();
    const text_h = font * 1.4;
    const caret_w = @max(@round(theme.scaledUi(1.5)), 1.0);
    if (text.len == 0) {
        queueText(state, .{ .x = field_text_rect.x, .y = field_text_rect.y + (line_h - text_h) * 0.5, .w = field_text_rect.w, .h = text_h }, "Describe the change you want", theme.COLOR_TEXT_SUBTLE, font, .ui, clip);
        queueRect(state, .{ .x = field_text_rect.x, .y = field_text_rect.y + theme.scaledUi(3.0), .w = caret_w, .h = line_h - theme.scaledUi(6.0) }, theme.COLOR_WHITE, clip);
        field_scroll = 0.0;
        return;
    }
    // Keep the caret's visual line inside the field.
    const caret_line = visualLineOf(field.cursor);
    const caret_top = @as(f32, @floatFromInt(caret_line)) * line_h;
    if (caret_top < field_scroll) field_scroll = caret_top;
    if (caret_top + line_h > field_scroll + field_text_rect.h) field_scroll = caret_top + line_h - field_text_rect.h;
    const content_h = @as(f32, @floatFromInt(visual_count)) * line_h;
    field_scroll = std.math.clamp(field_scroll, 0.0, @max(content_h - field_text_rect.h, 0.0));

    const selection = field.selection();
    for (visual[0..visual_count], 0..) |line, index| {
        const y = field_text_rect.y + @as(f32, @floatFromInt(index)) * line_h - field_scroll;
        if (y + line_h < clip.y or y > clip.y + clip.h) continue;
        const slice = text[line.start..line.end];
        if (selection) |range| {
            const start = @max(range.start, line.start);
            const end = @min(range.end, line.end);
            // A selected newline shows as a short tail past the line end.
            const takes_newline = range.end > line.end and range.start <= line.end and line.end < text.len and text[line.end] == '\n';
            if (start < end or takes_newline) {
                const x0 = field_text_rect.x + prefixWidth(slice, start -| line.start, font);
                var x1 = field_text_rect.x + prefixWidth(slice, end -| line.start, font);
                if (takes_newline) x1 += theme.scaledUi(5.0);
                if (start >= end) {
                    const tail_x = field_text_rect.x + prefixWidth(slice, slice.len, font);
                    queueRect(state, .{ .x = tail_x, .y = y, .w = theme.scaledUi(5.0), .h = line_h }, theme.withAlpha(theme.selection(), 140), clip);
                } else queueRect(state, .{ .x = x0, .y = y, .w = x1 - x0, .h = line_h }, theme.withAlpha(theme.selection(), 140), clip);
            }
        }
        if (slice.len > 0) {
            const w = prefixWidth(slice, slice.len, font);
            queueText(state, .{ .x = field_text_rect.x, .y = y + (line_h - text_h) * 0.5, .w = w + 1.0, .h = text_h }, slice, theme.COLOR_WHITE, font, .ui, clip);
        }
        if (index == caret_line) {
            const caret_x = field_text_rect.x + prefixWidth(slice, field.cursor - line.start, font);
            queueRect(state, .{ .x = caret_x, .y = y + theme.scaledUi(3.0), .w = caret_w, .h = line_h - theme.scaledUi(6.0) }, theme.COLOR_WHITE, clip);
        }
    }
}

fn renderFooter(state: *AppState, rect: palette.Rect) void {
    const font = theme.scaledUi(13.0);
    const button_h = theme.scaledUi(BUTTON_H_UI);
    const button_y = rect.y + (rect.h - button_h) * 0.5 + theme.scaledUi(2.0);
    const radius = theme.scaledUi(6.0);
    const pad_x = theme.scaledUi(12.0);

    // Send: accent pill with an arrow glyph.
    const send_label = "Send";
    const send_w = text_measure.textWidth(.ui_bold, font, send_label) + theme.scaledUi(18.0) + pad_x * 2.0;
    send_rect = .{ .x = rect.x + rect.w - send_w, .y = button_y, .w = send_w, .h = button_h };
    const can_send = std.mem.trim(u8, field.value(), " \t\r\n").len > 0;
    const send_fill = if (!can_send) theme.withAlpha(theme.accent(), 90) else if (contains(send_rect, mouse[0], mouse[1])) theme.raise(theme.accent(), 0.08) else theme.accent();
    queueRounded(state, send_rect, send_fill, radius, card_rect);
    const on_accent = theme.legibleOn(theme.COLOR_WHITE, theme.accent());
    queueIcon(state, .{ .x = send_rect.x + pad_x * 0.6, .y = send_rect.y, .w = theme.scaledUi(16.0), .h = button_h }, NF_COD_ARROW_UP, on_accent, theme.scaledUi(12.0), card_rect);
    const text_h = font * 1.4;
    queueText(state, .{ .x = send_rect.x + pad_x * 0.6 + theme.scaledUi(20.0), .y = send_rect.y + (button_h - text_h) * 0.5, .w = send_w, .h = text_h }, send_label, on_accent, font, .ui_bold, card_rect);

    const cancel_label = "Cancel";
    const cancel_w = text_measure.textWidth(.ui, font, cancel_label) + pad_x * 2.0;
    cancel_rect = .{ .x = send_rect.x - theme.scaledUi(8.0) - cancel_w, .y = button_y, .w = cancel_w, .h = button_h };
    if (contains(cancel_rect, mouse[0], mouse[1])) queueRounded(state, cancel_rect, theme.withAlpha(theme.COLOR_PANEL_MUTED, 220), radius, card_rect);
    queueText(state, .{ .x = cancel_rect.x + pad_x, .y = cancel_rect.y + (button_h - text_h) * 0.5, .w = cancel_w, .h = text_h }, cancel_label, theme.COLOR_TEXT_MUTED, font, .ui, card_rect);

    // Destination chat, so the user knows where the prompt lands.
    const small = theme.scaledUi(12.0);
    const max_w = @max(cancel_rect.x - theme.scaledUi(10.0) - rect.x, 0.0);
    const target = targetLabel(state);
    queueText(state, .{ .x = rect.x, .y = button_y + (button_h - small * 1.4) * 0.5, .w = max_w, .h = small * 1.4 }, elideEnd(state, target, small, max_w), theme.COLOR_TEXT_SUBTLE, small, .ui, card_rect);
}

fn targetLabel(state: *AppState) []const u8 {
    const thread_index = targetThreadIndex(state) orelse return "No chat in this workspace";
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    const title = project.threads.items[thread_index].title;
    const shown = if (title.len > 0) title else "Untitled chat";
    return std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "To: {s}", .{shown}) catch "";
}

// ------------------------------------------------------------------
// Text layout (soft wrap)
// ------------------------------------------------------------------

/// Splits `text` into visual lines no wider than `width`, breaking after
/// spaces when possible. Offsets index `text`; newlines are excluded.
fn layoutVisualLines(text: []const u8, width: f32, font: f32) void {
    visual_count = 0;
    var line_start: usize = 0;
    while (visual_count < visual.len) {
        const line_end = text_edit.lineEnd(text, line_start);
        var start = line_start;
        while (visual_count < visual.len) {
            const rest = text[start..line_end];
            if (rest.len == 0 or prefixWidth(rest, rest.len, font) <= width) {
                visual[visual_count] = .{ .start = start, .end = line_end };
                visual_count += 1;
                break;
            }
            // Longest prefix that fits (widths grow with the prefix).
            var low: usize = 0;
            var high: usize = rest.len;
            while (low < high) {
                const mid = text_edit.prevBoundary(rest, (low + high + 1) / 2);
                if (mid <= low) break;
                if (prefixWidth(rest, mid, font) <= width) low = mid else high = mid - 1;
            }
            var cut = low;
            if (cut == 0) cut = text_edit.nextBoundary(rest, 0);
            if (std.mem.lastIndexOfScalar(u8, rest[0..cut], ' ')) |space| {
                if (space > 0) cut = space + 1;
            }
            visual[visual_count] = .{ .start = start, .end = start + cut };
            visual_count += 1;
            start += cut;
        }
        if (line_end >= text.len) break;
        line_start = line_end + 1;
    }
    if (visual_count == 0) {
        visual[0] = .{ .start = 0, .end = 0 };
        visual_count = 1;
    }
}

/// Visual line holding `offset`: the last one starting at or before it.
fn visualLineOf(offset: usize) usize {
    var index: usize = 0;
    for (visual[0..visual_count], 0..) |line, i| {
        if (line.start <= offset) index = i else break;
    }
    return index;
}

fn offsetInLine(index: usize, x: f32) usize {
    const line = visual[@min(index, visual_count - 1)];
    const text = field.value();
    const font = theme.scaledUi(FIELD_FONT_UI);
    const local = text_edit.offsetAtX(text[line.start..line.end], x, font, measurePrefix);
    return line.start + local;
}

fn offsetAtPoint(x: f32, y: f32) usize {
    if (visual_count == 0) return 0;
    const line_h = theme.scaledUi(FIELD_LINE_UI);
    const row = (y - field_text_rect.y + field_scroll) / line_h;
    const index: usize = if (row <= 0) 0 else @min(@as(usize, @intFromFloat(@floor(row))), visual_count - 1);
    return offsetInLine(index, x - field_text_rect.x);
}

fn caretX() f32 {
    const line = visual[visualLineOf(field.cursor)];
    const text = field.value();
    return prefixWidth(text[line.start..line.end], field.cursor - line.start, theme.scaledUi(FIELD_FONT_UI));
}

// ------------------------------------------------------------------
// Input
// ------------------------------------------------------------------

pub fn handleKeyDown(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    if (!is_open) return false;
    if (!event.down) return true;
    const mod = text_edit.modBits(event.mod);
    const shift = (mod & sdl.Keymod.shift) != 0;
    const primary = (mod & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
    switch (event.key) {
        .escape => {
            close(state);
            return true;
        },
        .up, .down => if (!primary) {
            // Visual-line motion over the wrapped layout.
            const current = visualLineOf(field.cursor);
            const x = goal_x orelse caretX();
            const target: usize = if (event.key == .up)
                (if (current == 0) 0 else offsetInLine(current - 1, x))
            else if (current + 1 >= visual_count)
                field.value().len
            else
                offsetInLine(current + 1, x);
            field.moveTo(target, shift);
            goal_x = x;
            state.markDirty();
            return true;
        },
        else => {},
    }
    goal_x = null;
    const result = field.handleKeyWithClipboard(state, event.key, event.mod) catch return true;
    switch (result) {
        .submit => submit(state),
        .cancel => close(state),
        .changed, .moved => state.markDirty(),
        .unhandled => {},
    }
    return true;
}

pub fn handleTextInput(state: *AppState, text: []const u8) bool {
    if (!is_open) return false;
    goal_x = null;
    if (field.insert(state.allocator, text) catch false) state.markDirty();
    return true;
}

pub fn wantsTextInput() bool {
    return is_open;
}

pub fn handleMouseButton(state: *AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    if (!is_open) return false;
    mouse = .{ x, y };
    if (!down) {
        const was_dragging = field_drag;
        field_drag = false;
        return was_dragging or contains(card_rect, x, y);
    }
    switch (hitAt(x, y)) {
        .close, .cancel => close(state),
        .send => submit(state),
        .field => {
            goal_x = null;
            const offset = offsetAtPoint(x, y);
            if (clicks >= 3) {
                field.selectLineAt(offset);
            } else if (clicks == 2) {
                field.selectWordAt(offset);
            } else {
                field.moveTo(offset, false);
                field.anchor = offset;
                field_drag = true;
            }
            state.markDirty();
        },
        .card => {},
        .none => {
            // Outside: an empty popover closes and lets the press through;
            // typed text is kept, so the press is swallowed instead.
            if (std.mem.trim(u8, field.value(), " \t\r\n").len == 0) {
                close(state);
                return false;
            }
        },
    }
    return true;
}

/// Ends a field drag-select; true when one was active.
pub fn endDrag() bool {
    const was_dragging = field_drag;
    field_drag = false;
    return was_dragging;
}

pub fn handleMouseMotion(state: *AppState, x: f32, y: f32) bool {
    if (!is_open) return false;
    const previous = hitAt(mouse[0], mouse[1]);
    mouse = .{ x, y };
    if (field_drag) {
        field.moveTo(offsetAtPoint(x, y), true);
        state.markDirty();
        return true;
    }
    const current = hitAt(x, y);
    if (current != previous) state.markDirty();
    return current != .none;
}

pub fn handleWheel(state: *AppState, x: f32, y: f32, wheel_y: f32) bool {
    if (!is_open or !contains(card_rect, x, y)) return false;
    if (contains(field_rect, x, y)) {
        const line_h = theme.scaledUi(FIELD_LINE_UI);
        const content_h = @as(f32, @floatFromInt(visual_count)) * line_h;
        const next = std.math.clamp(field_scroll - wheel_y * line_h * 3.0, 0.0, @max(content_h - field_text_rect.h, 0.0));
        if (next != field_scroll) {
            field_scroll = next;
            state.markDirty();
        }
    }
    return true;
}

pub fn systemCursorAt(x: f32, y: f32) ?sdl.SystemCursor {
    if (!is_open) return null;
    return switch (hitAt(x, y)) {
        .close, .cancel, .send => .pointer,
        .field => .text,
        .card => .default,
        .none => null,
    };
}

fn hitAt(x: f32, y: f32) Hit {
    if (!is_open or !contains(card_rect, x, y)) return .none;
    if (contains(close_rect, x, y)) return .close;
    if (contains(cancel_rect, x, y)) return .cancel;
    if (contains(send_rect, x, y)) return .send;
    if (contains(field_rect, x, y)) return .field;
    return .card;
}

// ------------------------------------------------------------------
// Sending
// ------------------------------------------------------------------

/// Index of the chat the prompt goes to: the focused tab's chat pane, else
/// the workspace's current chat.
fn targetThreadIndex(state: *AppState) ?usize {
    if (state.project_controller.projects.items.len == 0) return null;
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    if (project.threads.items.len == 0) return null;
    if (state.sidePanelChatPaneId()) |pane_id| {
        if (state.workspaceChatThreadIndexByPane(pane_id)) |index| {
            if (index < project.threads.items.len) return index;
        }
    }
    return @min(project.selected_thread_index, project.threads.items.len - 1);
}

fn promptRoots(allocator: std.mem.Allocator, state: *AppState) ![]const selection_prompt.Root {
    const roots = state.fileViewerRoots();
    const out = try allocator.alloc(selection_prompt.Root, roots.len);
    for (roots, out) |root, *slot| slot.* = .{ .name = root.name, .path = root.path, .home = std.mem.eql(u8, root.id, "home") };
    return out;
}

fn submit(state: *AppState) void {
    const instruction = std.mem.trim(u8, field.value(), " \t\r\n");
    if (instruction.len == 0) {
        state.setSidebarNotice("Type what you want the agent to do first.");
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(state.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const roots = promptRoots(allocator, state) catch {
        state.setSidebarNotice("Could not prepare the prompt.");
        return;
    };
    const text = selection_prompt.format(allocator, .{
        .path = request_path.items,
        .roots = roots,
        .start_line = request_first,
        .end_line = request_last,
        .side = request_side,
        .text = request_text.items,
        .instruction = instruction,
    }) catch |err| {
        log.warn("selection prompt format failed: {s}", .{@errorName(err)});
        state.setSidebarNotice("Could not prepare the prompt.");
        return;
    };
    if (deliver(state, text)) close(state);
}

/// Delivers `text` to the target chat. False keeps the popover open.
fn deliver(state: *AppState, text: []const u8) bool {
    const thread_index = targetThreadIndex(state) orelse {
        state.setSidebarNotice("No chat to send to. Open a chat in this workspace first.");
        return false;
    };
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    if (project.selected_thread_index != thread_index) {
        project.selected_thread_index = thread_index;
        state.syncPaletteComposerFromDraft();
    }
    const thread = state.currentThreadMutable();
    const draft = std.mem.trim(u8, state.currentDraft(), &std.ascii.whitespace);
    const busy = thread.isSendPending();
    const dirty = draft.len != 0 or thread.draftImageCount() != 0;

    if (busy and !dirty and !AppState.threadHasPendingFollowup(thread)) {
        // Mid-turn with a clean composer: queue like the composer would.
        state.setDraft(text);
        state.queueOrSteerDraftDuringSend();
        if (state.currentDraft().len == 0) {
            state.setSidebarNotice("Queued for the agent after its current reply.");
            return true;
        }
        // Could not queue; the text stays in the (otherwise empty) draft.
        state.syncPaletteComposerFromDraft();
        state.requestComposerFocus();
        state.setSidebarNotice("Added to the chat draft.");
        return true;
    }
    if (busy or dirty) {
        // Never replace what the user is writing: append below it.
        const current = state.currentDraft();
        const next = if (current.len == 0)
            state.allocator.dupe(u8, text)
        else
            std.fmt.allocPrint(state.allocator, "{s}\n\n{s}", .{ current, text });
        const value = next catch {
            state.setSidebarNotice("Could not add the prompt to the draft.");
            return false;
        };
        defer state.allocator.free(value);
        state.setDraft(value);
        state.syncPaletteComposerFromDraft();
        state.requestComposerFocus();
        state.setSidebarNotice(if (busy) "Added to the chat draft; the agent is still replying." else "Added below your chat draft.");
        return true;
    }
    state.setDraft(text);
    state.sendDraft() catch |err| {
        log.warn("ask agent send failed: {s}", .{@errorName(err)});
        state.syncPaletteComposerFromDraft();
        state.requestComposerFocus();
        state.setSidebarNotice("Could not send; the prompt is in the chat draft.");
        return true;
    };
    if (state.currentThread().isSendPending()) {
        state.setSidebarNotice("Sent to the agent.");
    } else {
        // sendDraft did not start (e.g. no provider); the text is drafted.
        state.syncPaletteComposerFromDraft();
        state.requestComposerFocus();
        state.setSidebarNotice("The prompt is in the chat draft.");
    }
    return true;
}

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

fn measurePrefix(font: f32, text: []const u8, end: usize) f32 {
    return prefixWidth(text, end, font);
}

fn prefixWidth(text: []const u8, end: usize, font: f32) f32 {
    if (end == 0) return 0.0;
    return text_measure.textPrefixWidth(.ui, text, font, @min(end, text.len));
}

fn elideEnd(state: *AppState, value: []const u8, font: f32, max_w: f32) []const u8 {
    if (max_w <= 0.0) return "";
    if (text_measure.textWidth(.ui, font, value) <= max_w) return value;
    const ellipsis = "\u{2026}";
    const budget = max_w - text_measure.textWidth(.ui, font, ellipsis);
    var end: usize = 0;
    var fit: usize = 0;
    while (end < value.len) {
        end = text_edit.nextBoundary(value, end);
        if (text_measure.textPrefixWidth(.ui, value, font, end) > budget) break;
        fit = end;
    }
    return std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s}{s}", .{ value[0..fit], ellipsis }) catch value;
}

fn elideStart(state: *AppState, value: []const u8, font: f32, max_w: f32) []const u8 {
    if (max_w <= 0.0) return "";
    if (text_measure.textWidth(.ui, font, value) <= max_w) return value;
    const ellipsis = "\u{2026}";
    const budget = max_w - text_measure.textWidth(.ui, font, ellipsis);
    var start: usize = value.len;
    while (start > 0) {
        const previous = text_edit.prevBoundary(value, start);
        if (text_measure.textWidth(.ui, font, value[previous..]) > budget) break;
        start = previous;
    }
    return std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s}{s}", .{ ellipsis, value[start..] }) catch value;
}

fn contains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}

fn intersect(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
}

fn snap(rect: palette.Rect) palette.Rect {
    return .{ .x = @round(rect.x), .y = @round(rect.y), .w = @round(rect.w), .h = @round(rect.h) };
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn queueRect(state: *AppState, rect: palette.Rect, fill: [4]f32, clip: palette.Rect) void {
    state.palette_overlay_batch.rectClipped(state.allocator, snap(rect), paletteColor(fill), clip) catch {};
}

fn queueRounded(state: *AppState, rect: palette.Rect, fill: [4]f32, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, snap(rect), paletteColor(fill), radius, clip) catch {};
}

fn queueText(state: *AppState, rect: palette.Rect, value: []const u8, fill: [4]f32, font: f32, role: palette.FontRole, clip: palette.Rect) void {
    if (value.len == 0 or rect.w <= 0.0) return;
    const stable = state.palette_frame_text_arena.allocator().dupe(u8, value) catch return;
    state.palette_overlay_batch.roleText(state.allocator, rect, stable, paletteColor(fill), font, role, null, clip) catch {};
}

fn queueIcon(state: *AppState, rect: palette.Rect, glyph: []const u8, fill: [4]f32, font: f32, clip: palette.Rect) void {
    const glyph_w = text_measure.textWidth(.icon, font, glyph);
    const glyph_h = font * 1.3;
    queueText(state, .{
        .x = rect.x + (rect.w - glyph_w) * 0.5,
        .y = rect.y + (rect.h - glyph_h) * 0.5,
        .w = @max(glyph_w, 1.0),
        .h = glyph_h,
    }, glyph, fill, font, .icon, clip);
}
