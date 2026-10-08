//! Read-only file viewer workspace pane (`WorkspacePaneRef.file`).
//!
//! Content comes from `state/file_viewer_controller.zig` (daemon reads on
//! worker threads). By content kind the body is:
//! - text: monospace lines with a line-number gutter and syntax colours,
//!   scrolled both ways, never wrapped; a notice when the daemon truncated;
//! - markdown: rendered with `chat_markdown` into a cached batch;
//! - image: the decoded texture, fitted without upscaling;
//! - binary / external (PDF, Office, SVG) / too large / errors: a placeholder
//!   with "Open externally".
//!
//! Line selection: press or drag on line numbers (Shift extends, Shift+Up/Down
//! from the keyboard); Ctrl+C copies the selected source lines, Ctrl+A selects
//! all, Escape clears. An "Ask agent" chip beside the selection (or Enter)
//! opens `agent_prompt_popover` for those lines.
//!
//! Hook contract with `main.zig` (pointer input arrives through
//! `workspace_panes.zig`, which owns pane geometry and calls `beginFrame`,
//! `renderPane`, `handleMouseDown/Up/Motion`, `handleWheel`, `systemCursorAt`):
//! - `handleKeyDown` runs for every key-down before pane-level bindings and
//!   app shortcuts. It consumes keys only while a file pane is focused;
//!   return false lets the app see them.
//! - `handleTextInput` / `wantsTextInput` forward to the ask-agent popover,
//!   as do the key and pointer handlers while it is open: a fallback until
//!   (and harmless after) `main.zig` routes the popover directly.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");
const file_icons = @import("file_icons.zig");
const chat_markdown = @import("chat_markdown.zig");
const zig_dif = @import("zig_dif");
const platform_runtime = @import("platform_runtime");
const viewer = @import("../state/file_viewer_controller.zig");
const side_panel = @import("side_panel.zig");
const agent_prompt_popover = @import("agent_prompt_popover.zig");

const Document = viewer.Document;
const WorkspacePaneId = runtime.WorkspacePaneId;

// Geometry tokens (CSS px, scaled with `theme.scaledUi`).
const HEADER_HEIGHT_CSS: f32 = 40.0;
/// Shared with workspace_panes' chrome: zoom sits one slot left of the close X.
const CONTROL_SIZE_CSS: f32 = 30.0;
const CONTROL_GAP_CSS: f32 = 6.0;
const RIGHT_MARGIN_CSS: f32 = 10.0;
const HEADER_PAD_CSS: f32 = 12.0;
const HEADER_FONT_CSS: f32 = 13.0;
const HEADER_ICON_CSS: f32 = 14.0;
const CODE_FONT_CSS: f32 = 13.0;
const CODE_LINE_CSS: f32 = 20.0;
const CODE_PAD_Y_CSS: f32 = 6.0;
const GUTTER_PAD_CSS: f32 = 10.0;
const CODE_GAP_CSS: f32 = 12.0;
const NOTICE_HEIGHT_CSS: f32 = 30.0;
const MARKDOWN_FONT_CSS: f32 = 15.0;
const MARKDOWN_PAD_CSS: f32 = 24.0;
const MARKDOWN_MAX_WIDTH_CSS: f32 = 880.0;
const IMAGE_PAD_CSS: f32 = 16.0;
const WHEEL_LINES: f32 = 3.0;
const BUTTON_HEIGHT_CSS: f32 = 30.0;

// Codicons from the bundled Nerd Font (icon role).
const NF_COD_CLOSE = "\u{EA76}";
const NF_COD_REFRESH = "\u{EB37}";
const NF_COD_LINK_EXTERNAL = "\u{EB14}";
const NF_COD_HUBOT = "\u{EB08}";
const ASK_CHIP_H_CSS: f32 = 26.0;
const ASK_CHIP_FONT_CSS: f32 = 12.5;

const Action = enum { close, reload, open_external, retry, ask_agent };

const ButtonHit = struct {
    action: Action,
    rect: palette.Rect,
};

/// Per-frame geometry of one drawn file pane, for input routing.
const PaneGeometry = struct {
    pane_id: WorkspacePaneId,
    rect: palette.Rect,
    body: palette.Rect,
    /// Text documents only (zero rect otherwise).
    gutter: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    line_top: f32 = 0.0,
    line_h: f32 = 1.0,
    line_count: usize = 0,
    max_scroll_y: f32 = 0.0,
    max_scroll_x: f32 = 0.0,
    char_w: f32 = 1.0,
    buttons: [8]ButtonHit = undefined,
    /// "Ask agent" chip next to the line selection, when drawn.
    ask_rect: ?palette.Rect = null,
    button_count: usize = 0,

    fn addButton(self: *PaneGeometry, action: Action, rect: palette.Rect) void {
        if (self.button_count >= self.buttons.len) return;
        self.buttons[self.button_count] = .{ .action = action, .rect = rect };
        self.button_count += 1;
    }

    fn buttonAt(self: *const PaneGeometry, x: f32, y: f32) ?Action {
        for (self.buttons[0..self.button_count]) |hit| {
            if (contains(hit.rect, x, y)) return hit.action;
        }
        return null;
    }

    /// Line under `y`, clamped to the document.
    fn lineAt(self: *const PaneGeometry, y: f32) ?u32 {
        if (self.line_count == 0) return null;
        const offset = (y - self.line_top) / self.line_h;
        const clamped = std.math.clamp(@floor(offset), 0.0, @as(f32, @floatFromInt(self.line_count - 1)));
        return @intFromFloat(clamped);
    }
};

const DragState = struct { pane_id: WorkspacePaneId };
const HoverState = struct { pane_id: WorkspacePaneId, action: Action };

var geometries: [8]PaneGeometry = undefined;
var geometry_count: usize = 0;
var drag: ?DragState = null;
var hovered_button: ?HoverState = null;

/// Called by `workspace_panes` before it draws panes for a frame.
pub fn beginFrame() void {
    geometry_count = 0;
}

pub fn headerHeight() f32 {
    return theme.scaledUi(HEADER_HEIGHT_CSS);
}

fn geometryFor(pane_id: WorkspacePaneId) ?*PaneGeometry {
    for (geometries[0..geometry_count]) |*geometry| {
        if (geometry.pane_id == pane_id) return geometry;
    }
    return null;
}

fn geometryAt(x: f32, y: f32) ?*PaneGeometry {
    var index = geometry_count;
    while (index > 0) {
        index -= 1;
        if (contains(geometries[index].rect, x, y)) return &geometries[index];
    }
    return null;
}

// ------------------------------------------------------------------
// Rendering
// ------------------------------------------------------------------

pub fn renderPane(state: *runtime.AppState, pane_id: WorkspacePaneId, rect: palette.Rect, viewport_clip: ?palette.Rect) void {
    // File tab: header (icon, name, path, actions) above a kind-specific body.
    const pane_clip = if (viewport_clip) |clip| intersect(rect, clip) else rect;
    if (pane_clip.w <= 0.0 or pane_clip.h <= 0.0) return;
    const doc = state.fileViewerDocument(pane_id) orelse return;
    viewer.noteDocumentRendered(state, doc, platform_runtime.unixTimestampMs());

    if (geometry_count >= geometries.len) return;
    const geometry = &geometries[geometry_count];
    geometry_count += 1;
    const header_h = headerHeight();
    geometry.* = .{
        .pane_id = pane_id,
        .rect = rect,
        .body = .{ .x = rect.x, .y = rect.y + header_h, .w = rect.w, .h = @max(rect.h - header_h, 0.0) },
    };

    queueRect(state, rect, theme.md.code_bg, pane_clip);
    renderHeader(state, doc, geometry, pane_clip);
    const body_clip = intersect(geometry.body, pane_clip);
    if (body_clip.w <= 0.0 or body_clip.h <= 0.0) return;

    if (!doc.has_content) {
        switch (doc.status) {
            .waiting_roots, .loading => renderCenteredNote(state, geometry.body, "Loading…", body_clip),
            .failed => renderPlaceholder(state, doc, geometry, doc.message, true, body_clip),
            .ready => {},
        }
        return;
    }
    switch (doc.loaded.kind) {
        .text => if (doc.loaded.model.lines.len == 0)
            renderPlaceholder(state, doc, geometry, "This file is empty.", false, body_clip)
        else
            renderText(state, doc, geometry, body_clip),
        .markdown => renderMarkdown(state, doc, geometry, body_clip),
        .image => if (doc.texture) |texture|
            renderImage(state, texture, geometry.body, body_clip)
        else
            renderPlaceholder(state, doc, geometry, doc.loaded.image_error orelse "This image cannot be previewed.", false, body_clip),
        .binary => renderPlaceholder(state, doc, geometry, "This looks like a binary file, so it is not shown here.", false, body_clip),
        .external => renderPlaceholder(state, doc, geometry, "This file type is not previewed here.", false, body_clip),
        .too_large => renderPlaceholder(state, doc, geometry, "This file is too large to preview.", false, body_clip),
    }
}

fn renderHeader(state: *runtime.AppState, doc: *Document, geometry: *PaneGeometry, clip: palette.Rect) void {
    const rect = geometry.rect;
    const header: palette.Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = headerHeight() };
    queueRect(state, header, theme.COLOR_PANEL_ALT, clip);
    queueRect(state, .{ .x = header.x, .y = header.y + header.h - 1.0, .w = header.w, .h = 1.0 }, theme.borderMuted(), clip);

    // Right edge: close X in the far slot; workspace_panes draws zoom one slot
    // left of it; open-externally and reload sit left of zoom.
    const control = theme.scaledUi(CONTROL_SIZE_CSS);
    const gap = theme.scaledUi(CONTROL_GAP_CSS);
    const control_y = header.y + (header.h - control) * 0.5;
    const close_rect: palette.Rect = .{ .x = header.x + header.w - theme.scaledUi(RIGHT_MARGIN_CSS) - control, .y = control_y, .w = control, .h = control };
    renderIconButton(state, geometry, .close, close_rect, NF_COD_CLOSE, clip);
    const zoom_x = close_rect.x - gap - control;
    const open_rect: palette.Rect = .{ .x = zoom_x - gap - control, .y = control_y, .w = control, .h = control };
    renderIconButton(state, geometry, .open_external, open_rect, NF_COD_LINK_EXTERNAL, clip);
    const reload_rect: palette.Rect = .{ .x = open_rect.x - gap - control, .y = control_y, .w = control, .h = control };
    renderIconButton(state, geometry, .reload, reload_rect, NF_COD_REFRESH, clip);

    // Left: file-type glyph, name, then the root-relative folder and meta.
    const pad = theme.scaledUi(HEADER_PAD_CSS);
    const icon_size = theme.scaledUi(HEADER_ICON_CSS);
    const font = theme.scaledUi(HEADER_FONT_CSS);
    const text_clip = intersect(clip, .{ .x = header.x, .y = header.y, .w = @max(reload_rect.x - gap - header.x, 0.0), .h = header.h });
    const name = doc.name();
    const icon = file_icons.forFile(name);
    const icon_w = text_measure.textWidth(.icon, icon_size, icon.glyph);
    var x = header.x + pad;
    queueRoleText(state, .{ .x = x, .y = header.y + (header.h - icon_size * 1.3) * 0.5, .w = icon_w, .h = icon_size * 1.3 }, icon.glyph, theme.legibleOn(icon.color, theme.COLOR_PANEL_ALT), icon_size, .icon, text_clip);
    x += icon_w + theme.scaledUi(8.0);
    const text_h = font * 1.4;
    const text_y = header.y + (header.h - text_h) * 0.5;
    const name_w = text_measure.textWidth(.ui_bold, font, name);
    queueRoleText(state, .{ .x = x, .y = text_y, .w = name_w, .h = text_h }, name, theme.COLOR_WHITE, font, .ui_bold, text_clip);
    x += name_w + theme.scaledUi(10.0);

    const arena = state.palette_frame_text_arena.allocator();
    const display: []const u8 = doc.displayPath(arena) catch doc.path;
    const directory = std.fs.path.dirname(display) orelse "";
    const meta: []const u8 = headerMeta(arena, doc) catch "";
    const detail: []const u8 = if (directory.len > 0 and meta.len > 0)
        std.fmt.allocPrint(arena, "{s}  ·  {s}", .{ directory, meta }) catch directory
    else if (directory.len > 0) directory else meta;
    if (detail.len > 0) {
        const detail_w = text_measure.textWidth(.ui, font, detail);
        queueRoleText(state, .{ .x = x, .y = text_y, .w = detail_w, .h = text_h }, detail, theme.COLOR_TEXT_SUBTLE, font, .ui, text_clip);
    }
}

fn headerMeta(arena: std.mem.Allocator, doc: *const Document) ![]const u8 {
    if (!doc.has_content) return if (doc.loading) "loading…" else "";
    var size_buf: [32]u8 = undefined;
    const size = formatSize(&size_buf, doc.loaded.size);
    return switch (doc.loaded.kind) {
        .text => try std.fmt.allocPrint(arena, "{d} lines  ·  {s}{s}", .{ doc.loaded.model.lines.len, size, if (doc.loaded.truncated) " (truncated)" else "" }),
        .image => if (doc.texture) |texture|
            try std.fmt.allocPrint(arena, "{d}×{d}  ·  {s}", .{ texture.width, texture.height, size })
        else
            try arena.dupe(u8, size),
        else => try arena.dupe(u8, size),
    };
}

fn renderIconButton(state: *runtime.AppState, geometry: *PaneGeometry, action: Action, rect: palette.Rect, glyph: []const u8, clip: palette.Rect) void {
    geometry.addButton(action, rect);
    const hovered = isHovered(geometry.pane_id, action);
    if (hovered) queueRounded(state, rect, theme.withAlpha(theme.COLOR_WHITE, 26), theme.scaledUi(6.0), clip);
    const size = theme.scaledUi(15.0);
    const glyph_w = text_measure.textWidth(.icon, size, glyph);
    const fill = if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    queueRoleText(state, .{ .x = rect.x + (rect.w - glyph_w) * 0.5, .y = rect.y + (rect.h - size * 1.3) * 0.5, .w = glyph_w, .h = size * 1.3 }, glyph, fill, size, .icon, clip);
}

fn isHovered(pane_id: WorkspacePaneId, action: Action) bool {
    const hover = hovered_button orelse return false;
    return hover.pane_id == pane_id and hover.action == action;
}

/// Scroll offset in drawable px from the pane's persisted CSS value, clamped
/// (the clamp is written back so the saved layout stays in range).
fn scrollY(state: *runtime.AppState, pane_id: WorkspacePaneId, max_scroll: f32) f32 {
    const ref = state.filePaneRef(pane_id) orelse return 0.0;
    const scale = theme.scaledUi(1.0);
    const scroll = std.math.clamp(ref.scroll_y * scale, 0.0, max_scroll);
    ref.scroll_y = scroll / scale;
    return scroll;
}

fn renderText(state: *runtime.AppState, doc: *Document, geometry: *PaneGeometry, clip: palette.Rect) void {
    // Code view: gutter of right-aligned line numbers, then token runs.
    const lines = doc.loaded.model.lines;
    var body = geometry.body;
    if (doc.loaded.truncated) {
        const notice_h = theme.scaledUi(NOTICE_HEIGHT_CSS);
        body.h = @max(body.h - notice_h, 0.0);
        renderTruncationNotice(state, doc, geometry, .{ .x = body.x, .y = body.y + body.h, .w = body.w, .h = notice_h }, clip);
    }
    geometry.body = body;
    const body_clip = intersect(body, clip);
    const font = theme.scaledUi(CODE_FONT_CSS);
    const line_h = theme.scaledUi(CODE_LINE_CSS);
    const pad_y = theme.scaledUi(CODE_PAD_Y_CSS);
    const char_w = @max(text_measure.textWidth(.mono, font, "0"), 1.0);
    var digits: usize = 1;
    var count = lines.len;
    while (count >= 10) : (count /= 10) digits += 1;
    const gutter_w = @as(f32, @floatFromInt(@max(digits, 3))) * char_w + theme.scaledUi(GUTTER_PAD_CSS) * 2.0;
    const code_x = body.x + gutter_w + theme.scaledUi(CODE_GAP_CSS);
    const code_w = @max(body.x + body.w - code_x, 0.0);

    const content_h = @as(f32, @floatFromInt(lines.len)) * line_h + pad_y * 2.0;
    geometry.max_scroll_y = @max(content_h - body.h, 0.0);
    const content_w = @as(f32, @floatFromInt(doc.loaded.model.max_cols)) * char_w + theme.scaledUi(CODE_GAP_CSS);
    geometry.max_scroll_x = @max(content_w - code_w, 0.0);
    doc.scroll_x = std.math.clamp(doc.scroll_x, 0.0, geometry.max_scroll_x);
    const scroll = scrollY(state, geometry.pane_id, geometry.max_scroll_y);
    geometry.gutter = .{ .x = body.x, .y = body.y, .w = gutter_w, .h = body.h };
    geometry.line_top = body.y + pad_y - scroll;
    geometry.line_h = line_h;
    geometry.line_count = lines.len;
    geometry.char_w = char_w;

    queueRect(state, geometry.gutter, theme.COLOR_PANEL_ALT, body_clip);
    queueRect(state, .{ .x = body.x + gutter_w, .y = body.y, .w = 1.0, .h = body.h }, theme.borderMuted(), body_clip);
    const code_clip = intersect(body_clip, .{ .x = body.x + gutter_w + 1.0, .y = body.y, .w = @max(body.w - gutter_w - 1.0, 0.0), .h = body.h });

    const first_visible: usize = @intFromFloat(@max(@floor((scroll - pad_y) / line_h), 0.0));
    const visible_count: usize = @intFromFloat(@ceil(body.h / line_h) + 2.0);
    const last_visible = @min(first_visible + visible_count, lines.len);
    const selection = doc.selection;
    const arena = state.palette_frame_text_arena.allocator();
    var index = first_visible;
    while (index < last_visible) : (index += 1) {
        const line = lines[index];
        const y = geometry.line_top + @as(f32, @floatFromInt(index)) * line_h;
        const selected = if (selection) |range| index >= range.first() and index <= range.last() else false;
        if (selected) {
            queueRect(state, .{ .x = body.x, .y = y, .w = body.w, .h = line_h }, theme.withAlpha(theme.selection(), 70), body_clip);
        }
        // Line number, right-aligned in the gutter.
        const number = std.fmt.allocPrint(arena, "{d}", .{index + 1}) catch continue;
        const number_w = text_measure.textWidth(.mono, font, number);
        queueRoleText(state, .{
            .x = body.x + gutter_w - theme.scaledUi(GUTTER_PAD_CSS) - number_w,
            .y = y,
            .w = number_w,
            .h = line_h,
        }, number, if (selected) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE, font, .mono, body_clip);

        var x = code_x - doc.scroll_x;
        if (line.token_count == 0) {
            if (line.display.len == 0) continue;
            const width = text_measure.textWidth(.mono, font, line.display);
            queueRoleText(state, .{ .x = x, .y = y, .w = @max(width, 1.0), .h = line_h }, line.display, theme.md.tok_plain, font, .mono, code_clip);
            continue;
        }
        const tokens = doc.loaded.model.tokens[line.token_start..][0..line.token_count];
        for (tokens) |token| {
            if (x > code_clip.x + code_clip.w) break;
            const width = text_measure.textWidth(.mono, font, token.text);
            const token_x = x;
            x += width;
            if (token_x + width < code_clip.x or token.text.len == 0 or isBlank(token.text)) continue;
            queueRoleText(state, .{ .x = token_x, .y = y, .w = @max(width, 1.0), .h = line_h }, token.text, tokenColor(token.kind), font, .mono, code_clip);
        }
    }
    if (selection) |range| {
        const dragging = if (drag) |active| active.pane_id == geometry.pane_id else false;
        if (!dragging) renderAskChip(state, geometry, range.first(), range.last(), body_clip);
    }
}

/// "Ask agent" chip at the right edge, just below the selection (above it
/// when the selection ends at the bottom of the view).
fn renderAskChip(state: *runtime.AppState, geometry: *PaneGeometry, first: u32, last: u32, clip: palette.Rect) void {
    const font = theme.scaledUi(ASK_CHIP_FONT_CSS);
    const chip_h = theme.scaledUi(ASK_CHIP_H_CSS);
    const gap = theme.scaledUi(4.0);
    const label = "Ask agent";
    const icon_w = theme.scaledUi(16.0);
    const pad_x = theme.scaledUi(10.0);
    const chip_w = pad_x * 2.0 + icon_w + theme.scaledUi(4.0) + text_measure.textWidth(.ui_bold, font, label);
    const body = geometry.body;
    var y = geometry.line_top + @as(f32, @floatFromInt(last + 1)) * geometry.line_h + gap;
    if (y + chip_h > body.y + body.h - gap) y = geometry.line_top + @as(f32, @floatFromInt(first)) * geometry.line_h - chip_h - gap;
    y = std.math.clamp(y, body.y + gap, @max(body.y + body.h - chip_h - gap, body.y + gap));
    const rect: palette.Rect = .{ .x = body.x + body.w - chip_w - theme.scaledUi(16.0), .y = y, .w = chip_w, .h = chip_h };
    if (rect.x < body.x + geometry.gutter.w) return;
    geometry.ask_rect = rect;
    geometry.addButton(.ask_agent, rect);
    const hovered = if (hovered_button) |hover| hover.pane_id == geometry.pane_id and hover.action == .ask_agent else false;
    const fill = if (hovered) theme.raise(theme.accent(), 0.08) else theme.accent();
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, paletteColor(fill), chip_h * 0.5, clip) catch {};
    const on_accent = theme.legibleOn(theme.COLOR_WHITE, theme.accent());
    const glyph_font = theme.scaledUi(13.0);
    const glyph_w = text_measure.textWidth(.icon, glyph_font, NF_COD_HUBOT);
    queueRoleText(state, .{ .x = rect.x + pad_x + (icon_w - glyph_w) * 0.5, .y = rect.y + (chip_h - glyph_font * 1.3) * 0.5, .w = @max(glyph_w, 1.0), .h = glyph_font * 1.3 }, NF_COD_HUBOT, on_accent, glyph_font, .icon, clip);
    const text_h = font * 1.4;
    queueRoleText(state, .{ .x = rect.x + pad_x + icon_w + theme.scaledUi(4.0), .y = rect.y + (chip_h - text_h) * 0.5, .w = chip_w, .h = text_h }, label, on_accent, font, .ui_bold, clip);
}

/// Opens the shared ask-agent popover for the pane's line selection.
fn openAskAgent(state: *runtime.AppState, pane_id: WorkspacePaneId) void {
    const geometry = geometryFor(pane_id) orelse return;
    const doc = state.fileViewerDocument(pane_id) orelse return;
    const selection = doc.selection orelse return;
    if (!doc.has_content or doc.loaded.kind != .text) return;
    const text = viewer.sourceForLines(doc.loaded.text, doc.loaded.model.lines, selection.first(), selection.last());
    const anchor = geometry.ask_rect orelse palette.Rect{
        .x = geometry.body.x + geometry.gutter.w,
        .y = geometry.line_top + @as(f32, @floatFromInt(selection.last())) * geometry.line_h,
        .w = geometry.line_h,
        .h = geometry.line_h,
    };
    agent_prompt_popover.open(state, .{
        .anchor = anchor,
        .path = doc.path,
        .first_line = selection.first() + 1,
        .last_line = selection.last() + 1,
        .selection_text = text,
    });
}

fn renderTruncationNotice(state: *runtime.AppState, doc: *const Document, geometry: *PaneGeometry, rect: palette.Rect, clip: palette.Rect) void {
    const notice_clip = intersect(rect, clip);
    queueRect(state, rect, theme.COLOR_PANEL_ALT, notice_clip);
    queueRect(state, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1.0 }, theme.borderMuted(), notice_clip);
    var shown_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const shown = formatSize(&shown_buf, @min(@as(u64, doc.loaded.text.len), doc.loaded.size));
    const total = formatSize(&total_buf, doc.loaded.size);
    const arena = state.palette_frame_text_arena.allocator();
    const message = std.fmt.allocPrint(arena, "Showing the first {s} of {s}.", .{ shown, total }) catch return;
    const font = theme.scaledUi(12.5);
    const pad = theme.scaledUi(HEADER_PAD_CSS);
    const text_h = font * 1.4;
    const message_w = text_measure.textWidth(.ui, font, message);
    queueRoleText(state, .{ .x = rect.x + pad, .y = rect.y + (rect.h - text_h) * 0.5, .w = message_w, .h = text_h }, message, theme.COLOR_YELLOW, font, .ui, notice_clip);
    const label = "Open externally";
    const label_w = text_measure.textWidth(.ui_bold, font, label);
    const link: palette.Rect = .{ .x = rect.x + pad + message_w + theme.scaledUi(10.0), .y = rect.y, .w = label_w, .h = rect.h };
    geometry.addButton(.open_external, link);
    const fill = if (isHovered(geometry.pane_id, .open_external)) theme.COLOR_WHITE else theme.md.link;
    queueRoleText(state, .{ .x = link.x, .y = rect.y + (rect.h - text_h) * 0.5, .w = label_w, .h = text_h }, label, fill, font, .ui_bold, notice_clip);
}

fn renderMarkdown(state: *runtime.AppState, doc: *Document, geometry: *PaneGeometry, clip: palette.Rect) void {
    // Rendered markdown: built once per width/scale into the document's
    // origin-relative batch, then replayed translated by the scroll offset.
    if (doc.markdown == null and !doc.markdown_failed) {
        doc.markdown = chat_markdown.buildBodyView(state.allocator, doc.loaded.text) catch blk: {
            doc.markdown_failed = true;
            break :blk null;
        };
    }
    const view = doc.markdown orelse return renderPlaceholder(state, doc, geometry, "This markdown file could not be rendered.", false, clip);
    var body = geometry.body;
    if (doc.loaded.truncated) {
        const notice_h = theme.scaledUi(NOTICE_HEIGHT_CSS);
        body.h = @max(body.h - notice_h, 0.0);
        renderTruncationNotice(state, doc, geometry, .{ .x = body.x, .y = body.y + body.h, .w = body.w, .h = notice_h }, clip);
    }
    geometry.body = body;
    const body_clip = intersect(body, clip);
    const pad = theme.scaledUi(MARKDOWN_PAD_CSS);
    const width = @max(@min(body.w - pad * 2.0, theme.scaledUi(MARKDOWN_MAX_WIDTH_CSS)), theme.scaledUi(120.0));
    const scale = theme.uiScaleFactor();
    const font = theme.scaledUi(MARKDOWN_FONT_CSS);
    const options: chat_markdown.RenderOptions = .{
        .base_font_size = font,
        .line_height = font * 1.5,
        .glyph_width = font * 0.53,
        .code_font_size = font * 0.88,
    };
    if (!doc.md_valid or @abs(doc.md_width - width) > 0.5 or @abs(doc.md_scale - scale) > 0.001) {
        doc.invalidateMarkdownCache();
        var context: chat_markdown.PaletteRenderContext = .{
            .allocator = state.allocator,
            .batch = &doc.md_batch,
            .frame_text = &doc.md_frame_text,
            .text_arena = &doc.md_text_arena,
            .cursor = .{ .x = 0.0, .y = 0.0, .w = width, .h = 1_000_000.0 },
            .available_width = width,
        };
        chat_markdown.renderPaletteBody(&context, view, options);
        doc.md_height = @max(context.cursor.y, chat_markdown.measureBodyHeight(view, width, options));
        doc.md_width = width;
        doc.md_scale = scale;
        doc.md_valid = true;
    }
    geometry.max_scroll_y = @max(doc.md_height + pad * 2.0 - body.h, 0.0);
    geometry.line_h = theme.scaledUi(CODE_LINE_CSS);
    const scroll = scrollY(state, geometry.pane_id, geometry.max_scroll_y);
    const x = body.x + @max((body.w - width) * 0.5, pad);
    state.palette_overlay_batch.appendTranslatedBatch(state.allocator, &doc.md_batch, .{ .x = @round(x), .y = @round(body.y + pad - scroll) }, body_clip) catch {};
}

fn renderImage(state: *runtime.AppState, texture: anytype, body: palette.Rect, clip: palette.Rect) void {
    // Image: natural size when it fits, else scaled down to fit; centred.
    if (!texture.valid or texture.width <= 0 or texture.height <= 0) return;
    const pad = theme.scaledUi(IMAGE_PAD_CSS);
    const max_w = @max(body.w - pad * 2.0, 1.0);
    const max_h = @max(body.h - pad * 2.0, 1.0);
    const width: f32 = @floatFromInt(texture.width);
    const height: f32 = @floatFromInt(texture.height);
    const fit = @min(1.0, @min(max_w / width, max_h / height));
    const w = width * fit;
    const h = height * fit;
    const rect: palette.Rect = .{ .x = body.x + (body.w - w) * 0.5, .y = body.y + (body.h - h) * 0.5, .w = w, .h = h };
    state.palette_overlay_batch.image(
        state.allocator,
        snap(rect),
        palette.TextureId.init(texture.texture_id),
        .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .{},
        clip,
    ) catch {};
}

fn renderCenteredNote(state: *runtime.AppState, body: palette.Rect, message: []const u8, clip: palette.Rect) void {
    const font = theme.scaledUi(13.0);
    const width = text_measure.textWidth(.ui, font, message);
    const h = font * 1.4;
    queueRoleText(state, .{ .x = body.x + (body.w - width) * 0.5, .y = body.y + (body.h - h) * 0.5, .w = width, .h = h }, message, theme.COLOR_TEXT_MUTED, font, .ui, clip);
}

fn renderPlaceholder(state: *runtime.AppState, doc: *const Document, geometry: *PaneGeometry, message: []const u8, retry: bool, clip: palette.Rect) void {
    // Placeholder: large file glyph, message, size, and action buttons, as
    // one centred column.
    const body = geometry.body;
    const icon_size = theme.scaledUi(40.0);
    const font = theme.scaledUi(13.5);
    const line_h = font * 1.5;
    const button_h = theme.scaledUi(BUTTON_HEIGHT_CSS);
    const gap = theme.scaledUi(12.0);
    const column_h = icon_size * 1.3 + gap + line_h * 2.0 + gap + button_h;
    var y = body.y + @max((body.h - column_h) * 0.5, gap);
    const cx = body.x + body.w * 0.5;

    const icon = file_icons.forFile(doc.name());
    const icon_w = text_measure.textWidth(.icon, icon_size, icon.glyph);
    queueRoleText(state, .{ .x = cx - icon_w * 0.5, .y = y, .w = icon_w, .h = icon_size * 1.3 }, icon.glyph, theme.legibleOn(icon.color, theme.md.code_bg), icon_size, .icon, clip);
    y += icon_size * 1.3 + gap;
    const message_w = text_measure.textWidth(.ui, font, message);
    queueRoleText(state, .{ .x = cx - message_w * 0.5, .y = y, .w = message_w, .h = line_h }, message, theme.COLOR_WHITE, font, .ui, clip);
    y += line_h;
    if (doc.has_content) {
        var size_buf: [32]u8 = undefined;
        const arena = state.palette_frame_text_arena.allocator();
        const detail = std.fmt.allocPrint(arena, "{s}{s}{s}", .{
            formatSize(&size_buf, doc.loaded.size),
            if (doc.loaded.mime != null) "  ·  " else "",
            doc.loaded.mime orelse "",
        }) catch "";
        const detail_w = text_measure.textWidth(.ui, font, detail);
        queueRoleText(state, .{ .x = cx - detail_w * 0.5, .y = y, .w = detail_w, .h = line_h }, detail, theme.COLOR_TEXT_SUBTLE, font, .ui, clip);
    }
    y += line_h + gap;

    const open_label = "Open externally";
    const retry_label = "Retry";
    const button_pad = theme.scaledUi(14.0);
    const open_w = text_measure.textWidth(.ui_bold, font, open_label) + button_pad * 2.0;
    const retry_w = if (retry) text_measure.textWidth(.ui_bold, font, retry_label) + button_pad * 2.0 else 0.0;
    const total_w = open_w + if (retry) retry_w + gap else 0.0;
    var x = cx - total_w * 0.5;
    if (retry) {
        renderTextButton(state, geometry, .retry, .{ .x = x, .y = y, .w = retry_w, .h = button_h }, retry_label, font, clip);
        x += retry_w + gap;
    }
    renderTextButton(state, geometry, .open_external, .{ .x = x, .y = y, .w = open_w, .h = button_h }, open_label, font, clip);
}

fn renderTextButton(state: *runtime.AppState, geometry: *PaneGeometry, action: Action, rect: palette.Rect, label: []const u8, font: f32, clip: palette.Rect) void {
    geometry.addButton(action, rect);
    const hovered = isHovered(geometry.pane_id, action);
    const radius = theme.scaledUi(6.0);
    const inset = @max(theme.scaledUi(1.0), 1.0);
    // Bordered pill: border-coloured shape with the fill inset by 1px.
    queueRounded(state, rect, theme.borderMuted(), radius, clip);
    const fill = if (hovered) theme.COLOR_PANEL_MUTED else theme.COLOR_PANEL_ALT;
    queueRounded(state, .{ .x = rect.x + inset, .y = rect.y + inset, .w = rect.w - inset * 2.0, .h = rect.h - inset * 2.0 }, fill, @max(radius - inset, 0.0), clip);
    const label_w = text_measure.textWidth(.ui_bold, font, label);
    const h = font * 1.4;
    queueRoleText(state, .{ .x = rect.x + (rect.w - label_w) * 0.5, .y = rect.y + (rect.h - h) * 0.5, .w = label_w, .h = h }, label, theme.COLOR_WHITE, font, .ui_bold, clip);
}

// ------------------------------------------------------------------
// Input
// ------------------------------------------------------------------

pub fn handleMouseDown(state: *runtime.AppState, pane_id: WorkspacePaneId, x: f32, y: f32, shift: bool) bool {
    if (agent_prompt_popover.isOpen() and agent_prompt_popover.handleMouseButton(state, x, y, true, 1)) return true;
    const geometry = geometryFor(pane_id) orelse return false;
    if (!contains(geometry.rect, x, y)) return false;
    state.focusFilePane();
    if (geometry.buttonAt(x, y)) |action| {
        activate(state, pane_id, action);
        return true;
    }
    const doc = state.fileViewerDocument(pane_id) orelse return true;
    if (geometry.line_count > 0 and contains(geometry.gutter, x, y)) {
        const line = geometry.lineAt(y) orelse return true;
        if (shift and doc.selection != null) {
            doc.selection.?.head = line;
        } else {
            doc.selection = .{ .anchor = line, .head = line };
        }
        drag = .{ .pane_id = pane_id };
        state.markDirty();
        return true;
    }
    if (doc.selection != null and contains(geometry.body, x, y)) {
        doc.selection = null;
        state.markDirty();
    }
    return true;
}

pub fn handleMouseUp(state: *runtime.AppState) bool {
    if (agent_prompt_popover.endDrag()) return true;
    _ = state;
    if (drag == null) return false;
    drag = null;
    return true;
}

pub fn handleMouseMotion(state: *runtime.AppState, x: f32, y: f32) bool {
    if (agent_prompt_popover.isOpen() and agent_prompt_popover.handleMouseMotion(state, x, y)) return true;
    if (drag) |active| {
        const geometry = geometryFor(active.pane_id) orelse {
            drag = null;
            return false;
        };
        const doc = state.fileViewerDocument(active.pane_id) orelse return true;
        const line = geometry.lineAt(y) orelse return true;
        if (doc.selection) |*selection| {
            if (selection.head != line) {
                selection.head = line;
                state.markDirty();
            }
        }
        // Dragging past the body edge scrolls toward the pointer.
        if (y < geometry.body.y or y > geometry.body.y + geometry.body.h) {
            const direction: f32 = if (y < geometry.body.y) 1.0 else -1.0;
            _ = scrollBy(state, active.pane_id, geometry, 0.0, direction);
        }
        return true;
    }
    // Hover feedback for header and placeholder buttons.
    var next: ?HoverState = null;
    if (geometryAt(x, y)) |geometry| {
        if (geometry.buttonAt(x, y)) |action| next = .{ .pane_id = geometry.pane_id, .action = action };
    }
    const changed = if (next) |value|
        if (hovered_button) |current| current.pane_id != value.pane_id or current.action != value.action else true
    else
        hovered_button != null;
    if (changed) {
        hovered_button = next;
        state.markDirty();
    }
    return false;
}

pub fn handleWheel(state: *runtime.AppState, pane_id: WorkspacePaneId, x: f32, y: f32, wheel_x: f32, wheel_y: f32) bool {
    const geometry = geometryFor(pane_id) orelse return false;
    if (!contains(geometry.body, x, y)) return false;
    _ = scrollBy(state, pane_id, geometry, wheel_x * WHEEL_LINES, wheel_y * WHEEL_LINES);
    return true;
}

/// Scrolls by whole lines (positive `lines_y` moves toward the top, like
/// the wheel). Returns true when the offset changed.
fn scrollBy(state: *runtime.AppState, pane_id: WorkspacePaneId, geometry: *const PaneGeometry, lines_x: f32, lines_y: f32) bool {
    const ref = state.filePaneRef(pane_id) orelse return false;
    const step = theme.scaledUi(CODE_LINE_CSS);
    const scale = theme.scaledUi(1.0);
    var changed = false;
    if (lines_y != 0.0) {
        const current = ref.scroll_y * scale;
        const next = std.math.clamp(current - lines_y * step, 0.0, geometry.max_scroll_y);
        if (@abs(next - current) > 0.01) {
            ref.scroll_y = next / scale;
            changed = true;
        }
    }
    if (lines_x != 0.0) {
        if (state.fileViewerDocument(pane_id)) |doc| {
            const next = std.math.clamp(doc.scroll_x + lines_x * geometry.char_w * 4.0, 0.0, geometry.max_scroll_x);
            if (@abs(next - doc.scroll_x) > 0.01) {
                doc.scroll_x = next;
                changed = true;
            }
        }
    }
    if (changed) state.markDirty();
    return changed;
}

fn scrollTo(state: *runtime.AppState, pane_id: WorkspacePaneId, geometry: *const PaneGeometry, offset: f32) void {
    const ref = state.filePaneRef(pane_id) orelse return;
    const scale = theme.scaledUi(1.0);
    ref.scroll_y = std.math.clamp(offset, 0.0, geometry.max_scroll_y) / scale;
    state.markDirty();
}

/// Keeps `line` inside the visible body.
fn revealLine(state: *runtime.AppState, pane_id: WorkspacePaneId, geometry: *const PaneGeometry, line: u32) void {
    const ref = state.filePaneRef(pane_id) orelse return;
    const scale = theme.scaledUi(1.0);
    const scroll = ref.scroll_y * scale;
    // Content-space top of the line (line_top already includes -scroll).
    const top = geometry.line_top + scroll - geometry.body.y + @as(f32, @floatFromInt(line)) * geometry.line_h;
    if (top < scroll) {
        scrollTo(state, pane_id, geometry, top);
    } else if (top + geometry.line_h > scroll + geometry.body.h) {
        scrollTo(state, pane_id, geometry, top + geometry.line_h - geometry.body.h);
    }
}

fn activate(state: *runtime.AppState, pane_id: WorkspacePaneId, action: Action) void {
    hovered_button = null;
    switch (action) {
        .close => _ = state.closeCurrentProjectWorkspacePane(pane_id),
        .reload, .retry => state.reloadFileViewerDocument(pane_id),
        .open_external => state.openFileViewerExternally(pane_id),
        .ask_agent => openAskAgent(state, pane_id),
    }
    state.markDirty();
}

pub fn systemCursorAt(x: f32, y: f32) ?sdl.SystemCursor {
    if (drag != null) return .pointer;
    const geometry = geometryAt(x, y) orelse return null;
    if (geometry.buttonAt(x, y) != null) return .pointer;
    if (geometry.line_count > 0 and contains(geometry.gutter, x, y)) return .pointer;
    return null;
}

pub fn handleKeyDown(state: *runtime.AppState, event: *const sdl.KeyboardEvent) bool {
    // Fallback routing for the ask-agent popover (main.zig routes it first
    // once hooked; then it is closed or has already consumed the key).
    if (agent_prompt_popover.isOpen()) return agent_prompt_popover.handleKeyDown(state, event);
    if (!event.down) return false;
    const pane_id = state.focusedFilePaneId() orelse return false;
    // Another surface holds a caret (composer, terminal, address bar).
    if (state.composer_controller.focused or state.terminal_controller.focused or state.browser_controller.address_focused) return false;
    // The side panel body (explorer filter, tree) owns the keyboard.
    if (side_panel.bodyHasKeyboard(state)) return false;
    const geometry = geometryFor(pane_id) orelse return false;
    const doc = state.fileViewerDocument(pane_id) orelse return false;
    const primary = isPrimaryModifierPressed(event.mod);
    const shift = isShiftPressed(event.mod);
    const page_lines = @max(@floor(geometry.body.h / geometry.line_h) - 1.0, 1.0);
    switch (event.key) {
        .up, .down => {
            if (primary) return false;
            const delta: i64 = if (event.key == .up) -1 else 1;
            if (shift and geometry.line_count > 0) {
                const max_line: i64 = @intCast(geometry.line_count - 1);
                if (doc.selection) |current| {
                    const head: u32 = @intCast(std.math.clamp(@as(i64, current.head) + delta, 0, max_line));
                    doc.selection = .{ .anchor = current.anchor, .head = head };
                    revealLine(state, pane_id, geometry, head);
                } else {
                    const start = firstVisibleLine(geometry);
                    doc.selection = .{ .anchor = start, .head = start };
                }
                state.markDirty();
                return true;
            }
            _ = scrollBy(state, pane_id, geometry, 0.0, @floatFromInt(-delta));
        },
        .pageup => _ = scrollBy(state, pane_id, geometry, 0.0, page_lines),
        .pagedown => _ = scrollBy(state, pane_id, geometry, 0.0, -page_lines),
        .home => {
            if (!primary and doc.scroll_x > 0.0) {
                doc.scroll_x = 0.0;
                state.markDirty();
            } else scrollTo(state, pane_id, geometry, 0.0);
        },
        .end => scrollTo(state, pane_id, geometry, geometry.max_scroll_y),
        .left, .right => {
            if (primary) return false;
            _ = scrollBy(state, pane_id, geometry, if (event.key == .left) -1.0 else 1.0, 0.0);
        },
        .escape => {
            if (doc.selection == null) return false;
            doc.selection = null;
            state.markDirty();
        },
        .f5 => state.reloadFileViewerDocument(pane_id),
        .@"return", .kp_enter => {
            if (primary or doc.selection == null) return false;
            openAskAgent(state, pane_id);
        },
        .a => {
            if (!primary or geometry.line_count == 0) return false;
            doc.selection = .{ .anchor = 0, .head = @intCast(geometry.line_count - 1) };
            state.markDirty();
        },
        .c => {
            if (!primary) return false;
            const selection = doc.selection orelse return false;
            const text = viewer.sourceForLines(doc.loaded.text, doc.loaded.model.lines, selection.first(), selection.last());
            copyToClipboard(state, text);
        },
        else => return false,
    }
    return true;
}

fn firstVisibleLine(geometry: *const PaneGeometry) u32 {
    return geometry.lineAt(geometry.body.y + 1.0) orelse 0;
}

fn copyToClipboard(state: *runtime.AppState, text: []const u8) void {
    const terminated = state.allocator.dupeZ(u8, text) catch return;
    defer state.allocator.free(terminated);
    sdl.setClipboardText(terminated) catch {
        state.setSidebarNotice("Could not copy the selected lines.");
        return;
    };
    state.setSidebarNotice("Copied the selected lines.");
}

pub fn handleTextInput(state: *runtime.AppState, text: []const u8) bool {
    return agent_prompt_popover.handleTextInput(state, text);
}

pub fn wantsTextInput(state: *runtime.AppState) bool {
    _ = state;
    return agent_prompt_popover.wantsTextInput();
}

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

/// "12 B", "3.4 KB", "2.0 MB" (1024-based, matching web/mobile).
fn formatSize(buffer: []u8, bytes: u64) []const u8 {
    const value: f64 = @floatFromInt(bytes);
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "";
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buffer, "{d:.1} KB", .{value / 1024.0}) catch "";
    if (bytes < 1024 * 1024 * 1024) return std.fmt.bufPrint(buffer, "{d:.1} MB", .{value / (1024.0 * 1024.0)}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.1} GB", .{value / (1024.0 * 1024.0 * 1024.0)}) catch "";
}

fn tokenColor(kind: zig_dif.TokenKind) [4]f32 {
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

fn isBlank(text: []const u8) bool {
    for (text) |byte| if (byte != ' ') return false;
    return true;
}

fn isPrimaryModifierPressed(modifier_state: sdl.Keymod) bool {
    const bits = @as(*const u16, @ptrCast(&modifier_state)).*;
    return (bits & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
}

fn isShiftPressed(modifier_state: sdl.Keymod) bool {
    const bits = @as(*const u16, @ptrCast(&modifier_state)).*;
    return (bits & sdl.Keymod.shift) != 0;
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

fn queueRect(state: *runtime.AppState, rect: palette.Rect, fill: [4]f32, clip: palette.Rect) void {
    state.palette_overlay_batch.rectClipped(state.allocator, snap(rect), paletteColor(fill), clip) catch {};
}

fn queueRounded(state: *runtime.AppState, rect: palette.Rect, fill: [4]f32, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, snap(rect), paletteColor(fill), radius, clip) catch {};
}

fn queueRoleText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, fill: [4]f32, font_size: f32, role: palette.FontRole, clip: palette.Rect) void {
    if (value.len == 0) return;
    // Batches outlive this call; a reload can swap document memory before
    // the frame is drawn, so text is copied into the frame arena.
    const stable = state.palette_frame_text_arena.allocator().dupe(u8, value) catch return;
    state.palette_overlay_batch.roleText(state.allocator, rect, stable, paletteColor(fill), font_size, role, null, clip) catch {};
}

test "format size matches the shared 1024-based labels" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12 B", formatSize(&buffer, 12));
    try std.testing.expectEqualStrings("1.5 KB", formatSize(&buffer, 1536));
    try std.testing.expectEqualStrings("2.0 MB", formatSize(&buffer, 2 * 1024 * 1024));
}
