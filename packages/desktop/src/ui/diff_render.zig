//! Shared unified-diff renderer: stacked and split patch bodies with syntax
//! tokens, word-level change emphasis, line-number gutters and collapsed
//! context rows, plus the Stacked/Split toggle and small action buttons.
//!
//! Used by the transcript's "Changed files" card (`chat_panel.zig`) and the
//! side panel's Changes view (`side_panel_changes.zig`). Parsed views come
//! from `transcript_controller.diff_view_cache`, keyed by patch text and the
//! context collapse, so callers hand over raw patches every frame.

const std = @import("std");
const palette = @import("palette");
const zig_dif = @import("zig_dif");

const runtime = @import("runtime.zig");
const text_measure = @import("text_measure.zig");
const theme = @import("theme.zig");
const diff_view_cache = @import("diff_view_cache.zig");

const AppState = runtime.AppState;
const InlineRange = zig_dif.view.InlineRange;

pub const Layout = enum { stacked, split };

/// Narrower bodies always render stacked; split columns would be unreadable.
pub const SPLIT_MIN_WIDTH_UI: f32 = 620.0;
pub const DEFAULT_CONTEXT_LINES: usize = diff_view_cache.DEFAULT_CONTEXT_LINES;

const NUMBER_W_UI: f32 = 38.0;
const CHANGE_BAR_W_UI: f32 = 3.0;

pub const Point = struct { x: f32, y: f32 };

/// One drawn patch row, reported to `PatchOptions.rows` for hit testing.
pub const Row = struct {
    y: f32,
    h: f32,
    /// Index into the stacked lines or split rows of the rendered view.
    index: usize,
    kind: zig_dif.DisplayLineKind,
    old_line: ?usize = null,
    new_line: ?usize = null,
    /// Lines a context-gap row stands for.
    skipped_lines: usize = 0,
};

/// Caller-owned buffer receiving visible rows; rows past capacity drop.
pub const RowSink = struct {
    rows: []Row,
    len: usize = 0,

    fn push(self: *RowSink, row: Row) void {
        if (self.len >= self.rows.len) return;
        self.rows[self.len] = row;
        self.len += 1;
    }
};

/// Inclusive range of view indices drawn with the selection tint.
pub const Selection = struct { first: usize, last: usize };

pub const PatchOptions = struct {
    font_size: f32,
    line_h: f32,
    layout: Layout,
    clip: palette.Rect,
    /// Unchanged lines kept around changes before a run collapses.
    context_lines: usize = DEFAULT_CONTEXT_LINES,
    /// Pointer position for hover styling, or null when it is elsewhere.
    mouse: ?Point = null,
    /// Hunk headers get a Copy button backed by transcript copy hits; only
    /// surfaces whose clicks go through the transcript handler may enable it.
    hunk_copy: bool = false,
    rows: ?*RowSink = null,
    selection: ?Selection = null,
};

pub fn layoutForWidth(state: ?*AppState, width: f32) Layout {
    if (width < theme.scaledUi(SPLIT_MIN_WIDTH_UI)) return .stacked;
    const app = state orelse return .stacked;
    return if (app.app_config.diff_layout_preference == .split) .split else .stacked;
}

pub fn canSplit(width: f32) bool {
    return width >= theme.scaledUi(SPLIT_MIN_WIDTH_UI);
}

/// Rows the patch occupies in `layout` (2 for an empty patch).
pub fn displayLineCount(state: ?*AppState, patch: []const u8, layout: Layout) usize {
    return displayLineCountWithContext(state, patch, layout, DEFAULT_CONTEXT_LINES);
}

pub fn displayLineCountWithContext(state: ?*AppState, patch: []const u8, layout: Layout, context_lines: usize) usize {
    if (patch.len == 0) return 2;
    switch (layout) {
        .stacked => {
            if (state) |app| {
                const view = app.transcript_controller.diff_view_cache.stackedWithContext(app.allocator, patch, context_lines) orelse
                    return @max(wrappedLineCount(patch, 120), 2);
                return @max(view.lines.len, 1);
            }
            var view = zig_dif.buildPatchViewWithOptions(std.heap.page_allocator, patch, .{ .context_lines = context_lines }) catch
                return @max(wrappedLineCount(patch, 120), 2);
            defer view.deinit();
            return @max(view.lines.len, 1);
        },
        .split => {
            if (state) |app| {
                const view = app.transcript_controller.diff_view_cache.splitWithContext(app.allocator, patch, context_lines) orelse
                    return @max(wrappedLineCount(patch, 120), 2);
                return @max(view.rows.len, 1);
            }
            var view = zig_dif.buildSideBySidePatchViewWithOptions(std.heap.page_allocator, patch, .{ .context_lines = context_lines }) catch
                return displayLineCountWithContext(null, patch, .stacked, context_lines);
            defer view.deinit();
            return @max(view.rows.len, 1);
        },
    }
}

/// Draws `patch` into `rect` (`displayLineCount * line_h` tall).
pub fn renderPatch(state: *AppState, rect: palette.Rect, patch: []const u8, options: PatchOptions) void {
    switch (options.layout) {
        .stacked => renderStacked(state, rect, patch, options),
        .split => renderSplit(state, rect, patch, options),
    }
}

/// Plain text of view rows `first..last` (inclusive) as `-`/`+`/` ` lines,
/// allocated with `allocator`. Null when the view cannot be built.
pub fn selectionText(
    state: *AppState,
    allocator: std.mem.Allocator,
    patch: []const u8,
    layout: Layout,
    context_lines: usize,
    selection: Selection,
) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (layout) {
        .stacked => {
            const view = state.transcript_controller.diff_view_cache.stackedWithContext(state.allocator, patch, context_lines) orelse return null;
            if (view.lines.len == 0) return null;
            const last = @min(selection.last, view.lines.len - 1);
            var index = @min(selection.first, last);
            while (index <= last) : (index += 1) {
                const line = view.lines[index];
                const prefix = line.prefix() orelse continue;
                appendLine(&out, allocator, prefix, line.tokens) catch return null;
            }
        },
        .split => {
            const view = state.transcript_controller.diff_view_cache.splitWithContext(state.allocator, patch, context_lines) orelse return null;
            if (view.rows.len == 0) return null;
            const last = @min(selection.last, view.rows.len - 1);
            var index = @min(selection.first, last);
            // Old side first, then new side, like a unified hunk.
            while (index <= last) : (index += 1) {
                const cell = view.rows[index].left orelse continue;
                const prefix: u8 = if (cell.kind == .deletion) '-' else if (cell.kind == .context) ' ' else continue;
                appendLine(&out, allocator, prefix, cell.tokens) catch return null;
            }
            index = @min(selection.first, last);
            while (index <= last) : (index += 1) {
                const cell = view.rows[index].right orelse continue;
                if (cell.kind != .addition) continue;
                appendLine(&out, allocator, '+', cell.tokens) catch return null;
            }
        },
    }
    return out.toOwnedSlice(allocator) catch null;
}

/// Old/new source line ranges (1-based, inclusive) covered by view rows
/// `first..last`, including rows scrolled out of sight.
pub const LineRanges = struct { old: ?[2]usize = null, new: ?[2]usize = null };

pub fn selectionLines(state: *AppState, patch: []const u8, layout: Layout, context_lines: usize, selection: Selection) ?LineRanges {
    var ranges: LineRanges = .{};
    switch (layout) {
        .stacked => {
            const view = state.transcript_controller.diff_view_cache.stackedWithContext(state.allocator, patch, context_lines) orelse return null;
            if (view.lines.len == 0) return null;
            const last = @min(selection.last, view.lines.len - 1);
            for (view.lines[@min(selection.first, last) .. last + 1]) |line| {
                if (line.old_line) |number| ranges.old = widenRange(ranges.old, number);
                if (line.new_line) |number| ranges.new = widenRange(ranges.new, number);
            }
        },
        .split => {
            const view = state.transcript_controller.diff_view_cache.splitWithContext(state.allocator, patch, context_lines) orelse return null;
            if (view.rows.len == 0) return null;
            const last = @min(selection.last, view.rows.len - 1);
            for (view.rows[@min(selection.first, last) .. last + 1]) |row| {
                if (row.kind != .code) continue;
                if (row.left) |cell| if (cell.line_number) |number| {
                    ranges.old = widenRange(ranges.old, number);
                };
                if (row.right) |cell| if (cell.line_number) |number| {
                    ranges.new = widenRange(ranges.new, number);
                };
            }
        },
    }
    return ranges;
}

fn widenRange(range: ?[2]usize, line: usize) [2]usize {
    const value = range orelse return .{ line, line };
    return .{ @min(value[0], line), @max(value[1], line) };
}

fn appendLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, prefix: u8, tokens: []const zig_dif.Token) !void {
    try out.append(allocator, prefix);
    for (tokens) |token| try out.appendSlice(allocator, token.text);
    try out.append(allocator, '\n');
}

// Renders the stacked/split selector; returns the two segment rects
// (stacked, split) for the caller's hit list.
pub fn renderLayoutToggle(
    state: *AppState,
    rect: palette.Rect,
    layout: Layout,
    clip: palette.Rect,
    mouse: ?Point,
) [2]palette.Rect {
    queueRoundedClipped(
        state,
        rect,
        paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 105)),
        theme.scaledUi(7.0),
        clip,
    );
    const inset = theme.scaledUi(2.0);
    const inner = palette.Rect{
        .x = rect.x + inset,
        .y = rect.y + inset,
        .w = rect.w - inset * 2.0,
        .h = rect.h - inset * 2.0,
    };
    const half_w = inner.w * 0.5;
    const stacked_rect = palette.Rect{ .x = inner.x, .y = inner.y, .w = half_w, .h = inner.h };
    const split_rect = palette.Rect{ .x = inner.x + half_w, .y = inner.y, .w = half_w, .h = inner.h };
    renderLayoutOption(state, stacked_rect, "Stacked", layout == .stacked, clip, mouse);
    renderLayoutOption(state, split_rect, "Split", layout == .split, clip, mouse);
    return .{ stacked_rect, split_rect };
}

// Renders one segment of the diff-layout selector.
fn renderLayoutOption(
    state: *AppState,
    rect: palette.Rect,
    label: []const u8,
    selected: bool,
    clip: palette.Rect,
    mouse: ?Point,
) void {
    const hovered = pointIn(mouse, rect);
    if (selected or hovered) {
        queueRoundedClipped(
            state,
            rect,
            paletteColor(if (selected)
                theme.withAlpha(theme.COLOR_PANEL_ALT, 245)
            else
                theme.withAlpha(theme.COLOR_PANEL_ALT, 155)),
            theme.scaledUi(5.0),
            clip,
        );
    }
    queueCenteredLabel(
        state,
        rect,
        label,
        paletteColor(if (selected or hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED),
        theme.scaledUi(10.5),
        clip,
    );
}

// Renders one small bordered action button (diff file rows, card headers).
pub fn renderActionButton(
    state: *AppState,
    rect: palette.Rect,
    label: []const u8,
    primary: bool,
    clip: palette.Rect,
    mouse: ?Point,
) void {
    const hovered = pointIn(mouse, rect);
    const background = if (primary and hovered)
        theme.withAlpha(theme.COLOR_YELLOW, 42)
    else if (hovered)
        theme.withAlpha(theme.COLOR_PANEL_MUTED, 220)
    else
        theme.withAlpha(theme.COLOR_PANEL_MUTED, 128);
    const border = if (primary and hovered)
        theme.withAlpha(theme.COLOR_YELLOW, 150)
    else
        theme.withAlpha(theme.COLOR_TEXT_SUBTLE, if (hovered) 150 else 90);
    const text = if (primary and hovered)
        theme.COLOR_YELLOW
    else if (hovered)
        theme.COLOR_WHITE
    else
        theme.COLOR_TEXT_MUTED;
    queueRoundedShellClipped(
        state,
        rect,
        paletteColor(background),
        paletteColor(border),
        theme.scaledUi(6.0),
        clip,
    );
    queueCenteredLabel(state, rect, label, paletteColor(text), theme.scaledUi(11.5), clip);
}

// Renders an aligned old/new patch with independent line-number gutters.
fn renderSplit(state: *AppState, rect: palette.Rect, patch: []const u8, options: PatchOptions) void {
    if (patch.len == 0) {
        renderStacked(state, rect, patch, options);
        return;
    }
    const view = state.transcript_controller.diff_view_cache.splitWithContext(state.allocator, patch, options.context_lines) orelse {
        renderStacked(state, rect, patch, options);
        return;
    };
    const clip = options.clip;
    const line_h = options.line_h;
    const font_size = options.font_size;

    queueRoundedShellClipped(
        state,
        rect,
        paletteColor(theme.md.code_bg),
        paletteColor(theme.md.code_border),
        theme.scaledUi(6.0),
        clip,
    );

    const divider_w = @max(@round(theme.scaledUi(1.0)), 1.0);
    const half_w = (rect.w - divider_w) * 0.5;
    const left_rect = palette.Rect{ .x = rect.x, .y = rect.y, .w = half_w, .h = rect.h };
    const right_rect = palette.Rect{ .x = rect.x + half_w + divider_w, .y = rect.y, .w = half_w, .h = rect.h };
    queueRectClipped(state, .{
        .x = rect.x + half_w,
        .y = rect.y,
        .w = divider_w,
        .h = rect.h,
    }, paletteColor(theme.withAlpha(theme.md.code_border, 235)), clip);

    for (view.rows, 0..) |row, index| {
        const y = rect.y + @as(f32, @floatFromInt(index)) * line_h;
        if (y > clip.y + clip.h or y + line_h < clip.y) continue;
        const row_rect = palette.Rect{ .x = rect.x, .y = y, .w = rect.w, .h = line_h };
        switch (row.kind) {
            .code => {
                renderSplitCell(state, .{
                    .x = left_rect.x,
                    .y = y,
                    .w = left_rect.w,
                    .h = line_h,
                }, row.left, font_size, clip);
                renderSplitCell(state, .{
                    .x = right_rect.x,
                    .y = y,
                    .w = right_rect.w,
                    .h = line_h,
                }, row.right, font_size, clip);
                const display_kind: zig_dif.DisplayLineKind = if (row.left) |cell| cell.kind else if (row.right) |cell| cell.kind else .context;
                if (options.rows) |sink| sink.push(.{
                    .y = y,
                    .h = line_h,
                    .index = index,
                    .kind = display_kind,
                    .old_line = if (row.left) |cell| cell.line_number else null,
                    .new_line = if (row.right) |cell| cell.line_number else null,
                });
            },
            .hunk_header, .context_gap, .file_header, .prelude, .note => {
                const gap_hovered = row.kind == .context_gap and options.rows != null and pointIn(options.mouse, row_rect);
                const fill = switch (row.kind) {
                    .hunk_header, .context_gap => theme.withAlpha(theme.COLOR_PANEL_MUTED, if (gap_hovered) 215 else 155),
                    .file_header, .prelude => theme.withAlpha(theme.COLOR_PANEL_ALT, 230),
                    .note => theme.withAlpha(theme.COLOR_YELLOW, 22),
                    .code => unreachable,
                };
                queueRectClipped(state, row_rect, paletteColor(fill), clip);
                const display_kind: zig_dif.DisplayLineKind = switch (row.kind) {
                    .hunk_header => .hunk_header,
                    .context_gap => .context_gap,
                    .file_header => .file_header,
                    .prelude => .prelude,
                    .note => .note,
                    .code => unreachable,
                };
                renderTokens(
                    state,
                    rect.x + theme.scaledUi(10.0),
                    y,
                    rect.w - theme.scaledUi(20.0),
                    line_h,
                    row.tokens,
                    display_kind,
                    font_size,
                    intersectRect(clip, row_rect),
                );
                if (options.rows) |sink| sink.push(.{
                    .y = y,
                    .h = line_h,
                    .index = index,
                    .kind = display_kind,
                    .skipped_lines = if (row.collapsed_context) |collapsed| collapsed.skipped_lines else 0,
                });
            },
        }
        if (options.selection) |selection| {
            if (index >= selection.first and index <= selection.last) queueSelectionTint(state, row_rect, clip);
        }
    }
}

// Renders one old/new cell, including its blank alignment placeholder.
fn renderSplitCell(
    state: *AppState,
    rect: palette.Rect,
    maybe_cell: ?zig_dif.SideBySideCell,
    font_size: f32,
    clip: palette.Rect,
) void {
    const cell = maybe_cell orelse {
        queueRectClipped(
            state,
            rect,
            paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 155)),
            clip,
        );
        return;
    };

    const change_color: ?[4]f32 = switch (cell.kind) {
        .addition => theme.COLOR_DIFF_ADD,
        .deletion => theme.COLOR_DIFF_REMOVE,
        else => null,
    };
    if (change_color) |color| {
        queueRectClipped(state, rect, paletteColor(theme.withAlpha(color, 34)), clip);
        queueRectClipped(state, .{
            .x = rect.x,
            .y = rect.y,
            .w = theme.scaledUi(CHANGE_BAR_W_UI),
            .h = rect.h,
        }, paletteColor(color), clip);
    }

    const number_w = theme.scaledUi(NUMBER_W_UI);
    const code_pad = theme.scaledUi(9.0);
    const code_x = rect.x + number_w + code_pad;
    queueRectClipped(state, .{
        .x = rect.x + number_w,
        .y = rect.y,
        .w = @max(@round(theme.scaledUi(1.0)), 1.0),
        .h = rect.h,
    }, paletteColor(theme.md.code_border), clip);
    renderLineNumber(state, rect.x, rect.y, number_w, rect.h, cell.line_number, font_size, clip);

    const code_clip = intersectRect(clip, .{
        .x = code_x,
        .y = rect.y,
        .w = @max(rect.w - number_w - code_pad * 2.0, 1.0),
        .h = rect.h,
    });
    if (change_color) |color| {
        renderEmphasis(state, code_x, rect.y, rect.h, font_size, cell.text, cell.emphasis_ranges, color, code_clip);
    }
    renderTokens(
        state,
        code_x,
        rect.y,
        code_clip.w,
        rect.h,
        cell.tokens,
        cell.kind,
        font_size,
        code_clip,
    );
}

// Renders word-level change emphasis supplied by zig_dif's aligned model.
// Range offsets index the line text, which the tokens concatenate to.
fn renderEmphasis(
    state: *AppState,
    code_x: f32,
    y: f32,
    line_h: f32,
    font_size: f32,
    text: []const u8,
    ranges: []const InlineRange,
    color: [4]f32,
    clip: palette.Rect,
) void {
    for (ranges) |range| {
        if (range.start >= range.end or range.end > text.len) continue;
        // A whole-line range adds nothing over the row tint.
        if (range.start == 0 and range.end == text.len and ranges.len == 1) continue;
        const prefix_w = text_measure.textWidth(.mono, font_size, text[0..range.start]);
        const range_w = text_measure.textWidth(.mono, font_size, text[range.start..range.end]);
        queueRoundedClipped(state, .{
            .x = code_x + prefix_w,
            .y = y + theme.scaledUi(2.0),
            .w = @max(range_w, theme.scaledUi(2.0)),
            .h = @max(line_h - theme.scaledUi(4.0), 1.0),
        }, paletteColor(theme.withAlpha(color, 72)), theme.scaledUi(2.0), clip);
    }
}

fn renderStacked(state: *AppState, rect: palette.Rect, patch: []const u8, options: PatchOptions) void {
    const clip = options.clip;
    const line_h = options.line_h;
    const font_size = options.font_size;
    queueRoundedShellClipped(
        state,
        rect,
        paletteColor(theme.md.code_bg),
        paletteColor(theme.md.code_border),
        theme.scaledUi(6.0),
        clip,
    );

    if (patch.len == 0) {
        renderFallback(state, rect, "No textual patch was supplied for this file.", font_size, line_h, clip);
        return;
    }

    const cache = &state.transcript_controller.diff_view_cache;
    const view = cache.stackedWithContext(state.allocator, patch, options.context_lines) orelse {
        renderFallback(state, rect, patch, font_size, line_h, clip);
        return;
    };
    const emphasis = cache.stackedEmphasis(state.allocator, patch, options.context_lines);

    const number_w = theme.scaledUi(NUMBER_W_UI);
    const gutter_w = number_w * 2.0;
    const stroke = @max(@round(theme.scaledUi(1.0)), 1.0);
    const code_x = rect.x + gutter_w + theme.scaledUi(10.0);
    const code_clip = intersectRect(clip, .{
        .x = code_x,
        .y = rect.y,
        .w = @max(rect.w - (code_x - rect.x) - theme.scaledUi(6.0), 1.0),
        .h = rect.h,
    });

    var hunk_index: usize = 0;
    for (view.lines, 0..) |line, index| {
        const y = rect.y + @as(f32, @floatFromInt(index)) * line_h;
        if (line.kind == .hunk_header) hunk_index += 1;
        if (y > clip.y + clip.h or y + line_h < clip.y) continue;
        const row = palette.Rect{ .x = rect.x, .y = y, .w = rect.w, .h = line_h };
        const change_color: ?[4]f32 = switch (line.kind) {
            .addition => theme.COLOR_DIFF_ADD,
            .deletion => theme.COLOR_DIFF_REMOVE,
            else => null,
        };
        if (change_color) |color| {
            queueRectClipped(state, row, paletteColor(theme.withAlpha(color, 34)), clip);
            queueRectClipped(state, .{ .x = row.x, .y = row.y, .w = theme.scaledUi(CHANGE_BAR_W_UI), .h = row.h }, paletteColor(color), clip);
        } else if (line.kind == .hunk_header or line.kind == .context_gap) {
            const gap_hovered = line.kind == .context_gap and options.rows != null and pointIn(options.mouse, row);
            queueRectClipped(state, row, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, if (gap_hovered) 215 else 145)), clip);
        }
        queueRectClipped(state, .{ .x = rect.x + gutter_w, .y = y, .w = stroke, .h = line_h }, paletteColor(theme.md.code_border), clip);

        renderLineNumber(state, rect.x, y, number_w, line_h, line.old_line, font_size, clip);
        renderLineNumber(state, rect.x + number_w, y, number_w, line_h, line.new_line, font_size, clip);
        if (change_color) |color| {
            if (emphasis) |all| {
                if (index < all.len and all[index].len > 0) {
                    const text = joinedTokens(state, line.tokens);
                    renderEmphasis(state, code_x, y, line_h, font_size, text, all[index], color, code_clip);
                }
            }
        }
        renderTokens(state, code_x, y, code_clip.w, line_h, line.tokens, line.kind, font_size, code_clip);
        if (line.kind == .hunk_header and options.hunk_copy) {
            if (hunkSlice(patch, hunk_index - 1)) |hunk| {
                const copy_rect = palette.Rect{
                    .x = rect.x + rect.w - theme.scaledUi(52.0),
                    .y = y + theme.scaledUi(2.0),
                    .w = theme.scaledUi(46.0),
                    .h = line_h - theme.scaledUi(4.0),
                };
                const hovered = pointIn(options.mouse, copy_rect);
                queueRoundedClipped(
                    state,
                    copy_rect,
                    paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, if (hovered) 255 else 210)),
                    theme.scaledUi(4.0),
                    clip,
                );
                queueCenteredLabel(
                    state,
                    copy_rect,
                    "Copy",
                    paletteColor(if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED),
                    theme.scaledUi(9.5),
                    clip,
                );
                state.recordTranscriptCopyHit(copy_rect, hunk, hunkCopyIdentity(hunk_index - 1, hunk));
            }
        }
        if (options.selection) |selection| {
            if (index >= selection.first and index <= selection.last) queueSelectionTint(state, row, clip);
        }
        if (options.rows) |sink| sink.push(.{
            .y = y,
            .h = line_h,
            .index = index,
            .kind = line.kind,
            .old_line = line.old_line,
            .new_line = line.new_line,
            .skipped_lines = if (line.collapsed_context) |collapsed| collapsed.skipped_lines else 0,
        });
    }
}

/// Same identity the transcript used for hunk copies before the move, so
/// "Copied" feedback keys stay stable.
fn hunkCopyIdentity(hunk_index: usize, body: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0xC0A17C0A17C0A17);
    hasher.update(std.mem.asBytes(&hunk_index));
    hasher.update(body);
    return hasher.final();
}

fn queueSelectionTint(state: *AppState, row: palette.Rect, clip: palette.Rect) void {
    queueRectClipped(state, row, paletteColor(theme.withAlpha(theme.COLOR_YELLOW, 34)), clip);
}

/// The line text behind `tokens`, borrowed when the tokens are contiguous
/// slices of it, else copied into the frame arena.
fn joinedTokens(state: *AppState, tokens: []const zig_dif.Token) []const u8 {
    if (tokens.len == 0) return "";
    const first = tokens[0].text;
    var end_ptr = first.ptr + first.len;
    var contiguous = true;
    for (tokens[1..]) |token| {
        if (token.text.ptr != end_ptr) {
            contiguous = false;
            break;
        }
        end_ptr = token.text.ptr + token.text.len;
    }
    if (contiguous) return first.ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(first.ptr)];
    var out: std.ArrayList(u8) = .empty;
    const arena = state.palette_frame_text_arena.allocator();
    for (tokens) |token| out.appendSlice(arena, token.text) catch return "";
    return out.items;
}

pub fn hunkSlice(patch: []const u8, target_index: usize) ?[]const u8 {
    var found_index: usize = 0;
    var cursor: usize = 0;
    while (cursor < patch.len) {
        const line_end = std.mem.indexOfScalarPos(u8, patch, cursor, '\n') orelse patch.len;
        const line = patch[cursor..line_end];
        if (std.mem.startsWith(u8, line, "@@ ")) {
            if (found_index == target_index) {
                var end = if (line_end < patch.len) line_end + 1 else line_end;
                while (end < patch.len) {
                    const next_end = std.mem.indexOfScalarPos(u8, patch, end, '\n') orelse patch.len;
                    const next_line = patch[end..next_end];
                    if (std.mem.startsWith(u8, next_line, "@@ ") or std.mem.startsWith(u8, next_line, "diff --git ")) break;
                    end = if (next_end < patch.len) next_end + 1 else next_end;
                }
                return patch[cursor..end];
            }
            found_index += 1;
        }
        cursor = if (line_end < patch.len) line_end + 1 else line_end;
    }
    return null;
}

fn renderFallback(
    state: *AppState,
    rect: palette.Rect,
    text: []const u8,
    font_size: f32,
    line_h: f32,
    clip: palette.Rect,
) void {
    const body = if (text.len == 0) "Diff unavailable" else text;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index >= @max(wrappedLineCount(body, 120), 2)) break;
        const y = rect.y + @as(f32, @floatFromInt(index)) * line_h;
        queueFixedTextLine(state, .{
            .x = rect.x + theme.scaledUi(10.0),
            .y = y,
            .w = rect.w - theme.scaledUi(16.0),
            .h = line_h,
        }, line, paletteColor(theme.COLOR_TEXT_MUTED), font_size, clip);
    }
}

fn renderLineNumber(
    state: *AppState,
    x: f32,
    y: f32,
    width: f32,
    line_h: f32,
    number: ?usize,
    font_size: f32,
    clip: palette.Rect,
) void {
    var buf: [32]u8 = undefined;
    const label = if (number) |value| std.fmt.bufPrint(&buf, "{d}", .{value}) catch "" else "";
    queueFixedTextLine(state, .{
        .x = x + theme.scaledUi(3.0),
        .y = y,
        .w = width - theme.scaledUi(8.0),
        .h = line_h,
    }, label, paletteColor(theme.COLOR_TEXT_SUBTLE), font_size * 0.9, clip);
}

fn renderTokens(
    state: *AppState,
    x: f32,
    y: f32,
    width: f32,
    line_h: f32,
    tokens: []const zig_dif.Token,
    line_kind: zig_dif.DisplayLineKind,
    font_size: f32,
    clip: palette.Rect,
) void {
    var cursor_x = x;
    for (tokens) |token| {
        if (cursor_x >= x + width) break;
        const color = tokenColor(token.kind, line_kind);
        const token_w = text_measure.textWidth(.mono, font_size, token.text);
        state.palette_overlay_batch.roleText(
            state.allocator,
            .{ .x = cursor_x, .y = y, .w = @max(token_w, 1.0), .h = line_h },
            stableText(state, token.text),
            paletteColor(color),
            font_size,
            .mono,
            null,
            clip,
        ) catch {};
        cursor_x += token_w;
    }
}

fn tokenColor(kind: zig_dif.TokenKind, line_kind: zig_dif.DisplayLineKind) [4]f32 {
    if (line_kind == .hunk_header or line_kind == .context_gap) return theme.md.link;
    if (line_kind == .file_header or line_kind == .prelude or line_kind == .note) return theme.COLOR_TEXT_MUTED;
    return switch (kind) {
        .plain => theme.md.tok_plain,
        .keyword => theme.md.tok_keyword,
        .string => theme.md.tok_string,
        .number => theme.md.tok_number,
        .comment => theme.md.tok_comment,
        .type_name => theme.md.tok_type,
        .function_name => theme.md.tok_function,
        .property_name => theme.md.tok_property,
        .variable_name => theme.md.tok_variable,
        .constant_name => theme.md.tok_constant,
        .operator, .punctuation => theme.md.tok_punct,
    };
}

// ---------------------------------------------------------------------------
// Draw helpers (same conventions as chat_panel.zig)

fn pointIn(mouse: ?Point, rect: palette.Rect) bool {
    const point = mouse orelse return false;
    return point.x >= rect.x and point.y >= rect.y and point.x <= rect.x + rect.w and point.y <= rect.y + rect.h;
}

fn wrappedLineCount(body: []const u8, chars_per_line: usize) usize {
    if (body.len == 0) return 1;
    var count: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        if (i == body.len or body[i] == '\n') {
            const line_len = i - line_start;
            count += @max(@as(usize, 1), (line_len + chars_per_line - 1) / chars_per_line);
            line_start = i + 1;
        }
    }
    return count;
}

fn stableText(state: *AppState, value: []const u8) []const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch "";
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn intersectRect(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x, .y = y, .w = @max(right - x, 0.0), .h = @max(bottom - y, 0.0) };
}

fn snapRect(rect: palette.Rect) palette.Rect {
    return .{ .x = @round(rect.x), .y = @round(rect.y), .w = @round(rect.w), .h = @round(rect.h) };
}

fn queueRectClipped(state: *AppState, rect: palette.Rect, color: palette.Color, clip: palette.Rect) void {
    state.palette_overlay_batch.rectClipped(state.allocator, snapRect(rect), color, clip) catch {};
}

fn queueRoundedClipped(state: *AppState, rect: palette.Rect, color: palette.Color, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, color, radius, clip) catch {};
}

/// Rounded fill with a rounded border ring.
fn queueRoundedShellClipped(
    state: *AppState,
    bounds: palette.Rect,
    fill_color: palette.Color,
    border_color: palette.Color,
    radius: f32,
    clip: palette.Rect,
) void {
    const inset = @max(theme.scaledUi(1.0), 1.0);
    queueRoundedClipped(state, bounds, border_color, radius, clip);
    if (bounds.w > inset * 2.0 and bounds.h > inset * 2.0) {
        queueRoundedClipped(state, .{
            .x = bounds.x + inset,
            .y = bounds.y + inset,
            .w = bounds.w - inset * 2.0,
            .h = bounds.h - inset * 2.0,
        }, fill_color, @max(radius - inset, 0.0), clip);
    }
}

fn queueFixedTextLine(state: *AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.fixedText(state.allocator, rect, stableText(state, value), color, font_size, clip, .{}, font_size * 0.55, font_size * 1.25, false) catch {};
}

fn queueCenteredLabel(state: *AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const label_w = text_measure.textWidth(.ui, font_size, value);
    const label_h = font_size * 1.4;
    const label_rect: palette.Rect = .{
        .x = rect.x + @max((rect.w - label_w) * 0.5, 0.0),
        .y = rect.y + @max((rect.h - label_h) * 0.5, 0.0),
        .w = @min(label_w, rect.w),
        .h = @min(label_h, rect.h),
    };
    state.palette_overlay_batch.roleText(state.allocator, snapRect(label_rect), stableText(state, value), color, font_size, .ui, null, clip) catch {};
}

test "split diff layout aligns replacement rows" {
    const patch =
        \\@@ -1,2 +1,3 @@
        \\-const oldValue = 1;
        \\+const newValue = 2;
        \\+const extraValue = 3;
        \\ context();
    ;
    try std.testing.expectEqual(@as(usize, 5), displayLineCount(null, patch, .stacked));
    try std.testing.expectEqual(@as(usize, 4), displayLineCount(null, patch, .split));
}

test "hunk slices stop at the next hunk" {
    const patch = "diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n@@ -9 +9 @@\n-c\n+d\n";
    try std.testing.expectEqualStrings("@@ -1 +1 @@\n-a\n+b\n", hunkSlice(patch, 0).?);
    try std.testing.expectEqualStrings("@@ -9 +9 @@\n-c\n+d\n", hunkSlice(patch, 1).?);
    try std.testing.expect(hunkSlice(patch, 2) == null);
}
