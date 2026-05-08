//! Palette-only chat workspace rendering.

const std = @import("std");
const palette = @import("palette");

const app_state = @import("../state.zig");
const browser_panel = @import("browser.zig");
const chat_markdown = @import("chat_markdown.zig");
const colors = @import("colors.zig");
const composer_pickers = @import("composer_pickers.zig");
const runtime = @import("runtime.zig");
const terminal_panel = @import("terminal_panel.zig");
const theme = @import("theme.zig");

const TOP_BAR_HEIGHT: f32 = 82.0;
const COMPOSER_HEIGHT: f32 = 220.0;
const TRANSCRIPT_MAX_WIDTH: f32 = 960.0;
const TRANSCRIPT_LINE_HEIGHT: f32 = 22.0;

var transcript_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

pub fn renderWorkspace(state: *app_state.AppState, width: f32, height: f32) void {
    renderWorkspaceAt(state, .{ .x = estimateWorkspaceOriginX(state, width), .y = 0.0, .w = width, .h = height });
}

pub fn renderWorkspaceAt(state: *app_state.AppState, rect: palette.Rect) void {
    queueRect(state, rect, paletteColor(colors.CHAT_BLACK));
    if (state.projects.items.len == 0) {
        renderEmptyProjects(state, rect);
        return;
    }

    const header_height = theme.clampf(rect.h * 0.14, theme.scaledUi(54.0), theme.scaledUi(TOP_BAR_HEIGHT));
    const composer_height = theme.clampf(rect.h * 0.29, theme.scaledUi(128.0), theme.scaledUi(COMPOSER_HEIGHT));
    const bottom_margin = theme.clampf(rect.h * 0.018, theme.scaledUi(8.0), theme.scaledUi(14.0));
    const side_margin = theme.clampf(rect.w * 0.045, theme.scaledUi(16.0), theme.scaledUi(48.0));

    const header = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = header_height };
    renderHeader(state, header);

    const composer_width = @max(theme.scaledUi(220.0), @min(rect.w - side_margin * 2.0, theme.scaledUi(980.0)));
    const composer_rect = palette.Rect{
        .x = rect.x + (rect.w - composer_width) * 0.5,
        .y = rect.y + rect.h - composer_height - bottom_margin,
        .w = composer_width,
        .h = composer_height,
    };
    const attachment_count = state.currentThread().draftImageCount();
    const attachment_rows = if (attachment_count == 0) 0 else (attachment_count + 1) / 2;
    const attachment_reserve = if (attachment_rows > 0)
        theme.scaledUi(12.0) + @as(f32, @floatFromInt(attachment_rows)) * theme.scaledUi(74.0)
    else
        0.0;

    const body = palette.Rect{
        .x = rect.x,
        .y = header.y + header.h,
        .w = rect.w,
        .h = @max(composer_rect.y - (header.y + header.h) - attachment_reserve, theme.scaledUi(120.0)),
    };

    if (state.isBrowserVisible() and body.w >= theme.scaledUi(900.0)) {
        const browser_width = body.w * 0.50;
        const chat_rect = palette.Rect{ .x = body.x, .y = body.y, .w = body.w - browser_width, .h = body.h };
        renderTranscript(state, chat_rect);
        browser_panel.renderDockAt(state, .{ .x = chat_rect.x + chat_rect.w, .y = body.y, .w = browser_width, .h = body.h });
    } else if (state.isTerminalVisible() and body.h >= theme.scaledUi(360.0)) {
        const terminal_height = @min(body.h * 0.32, theme.scaledUi(260.0));
        const chat_rect = palette.Rect{ .x = body.x, .y = body.y, .w = body.w, .h = body.h - terminal_height };
        renderTranscript(state, chat_rect);
        terminal_panel.renderDockAt(state, .{ .x = body.x, .y = chat_rect.y + chat_rect.h, .w = body.w, .h = terminal_height });
    } else {
        renderTranscript(state, body);
    }

    renderComposer(state, composer_rect);
    composer_pickers.render(state);
}

fn estimateWorkspaceOriginX(state: *app_state.AppState, workspace_width: f32) f32 {
    var sidebar_width: f32 = if (state.isSidebarCollapsed()) theme.scaledUi(68.0) else theme.scaledUi(280.0);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const total_width = workspace_width + sidebar_width;
        sidebar_width = if (state.isSidebarCollapsed())
            theme.clampf(total_width * 0.07, theme.scaledUi(60.0), theme.scaledUi(76.0))
        else
            theme.clampf(total_width * 0.235, theme.scaledUi(230.0), @min(theme.scaledUi(360.0), total_width * 0.38));
    }
    return sidebar_width;
}

pub fn handleFileSearchPaletteMouseButton(_: *app_state.AppState, _: f32, _: f32, _: bool) bool {
    return false;
}

pub fn handleTranscriptPaletteWheel(state: *app_state.AppState, x: f32, y: f32, wheel_y: f32) bool {
    if (wheel_y == 0.0 or !rectContains(transcript_rect, x, y)) return false;
    const current = state.currentTranscriptScrollY() orelse 0.0;
    state.rememberCurrentTranscriptScroll(@max(0.0, current - wheel_y * theme.scaledUi(64.0)));
    state.transcript_auto_follow_pending = false;
    state.scroll_transcript_to_bottom_frames = 0;
    return true;
}

fn renderHeader(state: *app_state.AppState, rect: palette.Rect) void {
    queueRect(state, rect, paletteColor(colors.CHAT_BLACK));
    queueRect(state, .{ .x = rect.x, .y = rect.y + rect.h - 1.0, .w = rect.w, .h = 1.0 }, paletteColor(colors.DARK_BLUE));

    const project = state.currentProject();
    const thread = state.currentThread();
    const title = if (thread.title.len > 0) thread.title else project.label;
    queueText(state, .{
        .x = rect.x + theme.scaledUi(32.0),
        .y = rect.y + theme.scaledUi(22.0),
        .w = @max(rect.w - theme.scaledUi(64.0), 1.0),
        .h = theme.scaledUi(32.0),
    }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(18.0), rect);
}

fn renderEmptyProjects(state: *app_state.AppState, rect: palette.Rect) void {
    const x = rect.x + theme.scaledUi(44.0);
    var y = rect.y + theme.scaledUi(86.0);
    queueText(state, .{ .x = x, .y = y, .w = rect.w - theme.scaledUi(88.0), .h = theme.scaledUi(38.0) }, "No projects yet", paletteColor(theme.COLOR_WHITE), theme.scaledUi(28.0), rect);
    y += theme.scaledUi(42.0);
    queueText(state, .{ .x = x, .y = y, .w = rect.w - theme.scaledUi(88.0), .h = theme.scaledUi(28.0) }, "Use the project rail to add a folder and start chatting.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(16.0), rect);
}

fn renderTranscript(state: *app_state.AppState, rect: palette.Rect) void {
    transcript_rect = rect;
    const column_width = @min(rect.w - theme.scaledUi(48.0), theme.scaledUi(TRANSCRIPT_MAX_WIDTH));
    const column = palette.Rect{ .x = rect.x + (rect.w - column_width) * 0.5, .y = rect.y + theme.scaledUi(28.0), .w = column_width, .h = @max(rect.h - theme.scaledUi(42.0), 1.0) };
    const thread = state.currentThread();
    const clip = column;

    if (thread.messages.items.len == 0 and !thread.isSendPendingForUi()) {
        queueText(state, .{ .x = column.x, .y = column.y, .w = column.w, .h = theme.scaledUi(30.0) }, "No messages yet", paletteColor(theme.COLOR_WHITE), theme.scaledUi(20.0), clip);
        queueText(state, .{ .x = column.x, .y = column.y + theme.scaledUi(32.0), .w = column.w, .h = theme.scaledUi(26.0) }, "Choose a provider, type a prompt below, and start the first chat for this directory.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(15.0), clip);
        return;
    }

    const content_height = transcriptContentHeight(thread, column.w);
    const max_scroll = @max(0.0, content_height - column.h);
    var scroll_y = std.math.clamp(state.currentTranscriptScrollY() orelse max_scroll, 0.0, max_scroll);
    if (state.pending_transcript_line_scroll_steps != 0) {
        scroll_y = std.math.clamp(scroll_y + @as(f32, @floatFromInt(state.pending_transcript_line_scroll_steps)) * theme.scaledUi(TRANSCRIPT_LINE_HEIGHT), 0.0, max_scroll);
        state.pending_transcript_line_scroll_steps = 0;
    }
    if (state.pending_transcript_page_scroll_steps != 0) {
        scroll_y = std.math.clamp(scroll_y + @as(f32, @floatFromInt(state.pending_transcript_page_scroll_steps)) * column.h * 0.82, 0.0, max_scroll);
        state.pending_transcript_page_scroll_steps = 0;
    }
    if (state.transcript_auto_follow_pending or state.scroll_transcript_to_bottom_frames > 0) {
        scroll_y = max_scroll;
        if (state.scroll_transcript_to_bottom_frames > 0) state.scroll_transcript_to_bottom_frames -= 1;
        if (state.scroll_transcript_to_bottom_frames == 0) state.transcript_auto_follow_pending = false;
    }
    state.rememberCurrentTranscriptScroll(scroll_y);

    var content_y = column.y - scroll_y;
    for (thread.messages.items) |message| {
        const item_h = transcriptMessageHeight(message.body, message.role, column.w);
        if (content_y + item_h >= column.y and content_y <= column.y + column.h) {
            renderTranscriptMessage(state, column, content_y, item_h, message, clip);
        }
        content_y += item_h + theme.scaledUi(12.0);
    }

    if (thread.isSendPendingForUi()) {
        queueText(state, .{ .x = column.x, .y = @min(content_y + theme.scaledUi(8.0), column.y + column.h - theme.scaledUi(24.0)), .w = column.w, .h = theme.scaledUi(24.0) }, "Working...", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(15.0), clip);
    }

    if (max_scroll > 1.0) {
        const track = palette.Rect{ .x = rect.x + rect.w - theme.scaledUi(8.0), .y = column.y, .w = theme.scaledUi(4.0), .h = column.h };
        const thumb_h = @max(theme.scaledUi(32.0), column.h * (column.h / content_height));
        const thumb_y = track.y + (track.h - thumb_h) * (scroll_y / max_scroll);
        queueRounded(state, track, paletteColor(colors.rgba(35, 42, 46, 160)), theme.scaledUi(2.0));
        queueRounded(state, .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, paletteColor(colors.rgba(145, 163, 170, 210)), theme.scaledUi(2.0));
    }
}

fn transcriptContentHeight(thread: anytype, width: f32) f32 {
    var total: f32 = theme.scaledUi(4.0);
    for (thread.messages.items) |message| {
        total += transcriptMessageHeight(message.body, message.role, width) + theme.scaledUi(12.0);
    }
    if (thread.isSendPendingForUi()) total += theme.scaledUi(34.0);
    return total;
}

fn transcriptMessageHeight(body_raw: []const u8, role: app_state.ChatRole, column_width: f32) f32 {
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const font_size = theme.scaledUi(16.0);
    const body_width = if (role == .user) column_width * 0.62 else column_width;
    const body_inner_width = @max(body_width - theme.scaledUi(28.0), theme.scaledUi(80.0));
    if (role == .assistant) {
        var view = chat_markdown.buildBodyView(std.heap.page_allocator, body) catch {
            const chars_per_line = @max(@as(usize, @intFromFloat(body_inner_width / (font_size * 0.52))), 1);
            const line_count = wrappedLineCount(body, chars_per_line);
            return theme.scaledUi(44.0) + @as(f32, @floatFromInt(line_count)) * font_size * 1.28;
        };
        defer view.deinit(std.heap.page_allocator);
        const measured = chat_markdown.measureBodyHeight(view, body_inner_width, markdownOptions(font_size));
        return theme.scaledUi(44.0) + measured;
    }
    const chars_per_line = @max(@as(usize, @intFromFloat(body_inner_width / (font_size * 0.52))), 1);
    const line_count = wrappedLineCount(body, chars_per_line);
    return theme.scaledUi(44.0) + @as(f32, @floatFromInt(line_count)) * font_size * 1.28;
}

fn renderTranscriptMessage(state: *app_state.AppState, column: palette.Rect, y: f32, height: f32, message: app_state.ChatMessage, clip: palette.Rect) void {
    const role_label = switch (message.role) {
        .user => "You",
        .assistant => if (message.author.len > 0) message.author else "Assistant",
        .system => "System",
    };
    const bubble_width = if (message.role == .user) column.w * 0.62 else column.w;
    const bubble_x = if (message.role == .user) column.x + column.w - bubble_width else column.x;
    const bubble = palette.Rect{ .x = bubble_x, .y = y, .w = bubble_width, .h = height };
    const bg = switch (message.role) {
        .user => colors.rgba(31, 48, 46, 255),
        .assistant => colors.rgba(10, 15, 16, 0),
        .system => colors.rgba(57, 43, 9, 235),
    };
    if (message.role != .assistant) {
        queueRounded(state, bubble, paletteColor(bg), theme.scaledUi(8.0));
        queueBorder(state, bubble, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), 1.0);
    }
    queueText(state, .{ .x = bubble.x + theme.scaledUi(14.0), .y = bubble.y + theme.scaledUi(8.0), .w = bubble.w - theme.scaledUi(28.0), .h = theme.scaledUi(20.0) }, role_label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), clip);
    const body_rect = palette.Rect{
        .x = bubble.x + theme.scaledUi(14.0),
        .y = bubble.y + theme.scaledUi(32.0),
        .w = bubble.w - theme.scaledUi(28.0),
        .h = bubble.h - theme.scaledUi(38.0),
    };
    const body_text = std.mem.trim(u8, message.body, "\n\r\t ");
    if (message.role == .assistant) {
        renderMarkdownBody(state, body_rect, body_text, clip);
    } else {
        renderWrappedBody(state, body_rect, body_text, paletteColor(theme.COLOR_WHITE), theme.scaledUi(16.0), clip);
    }
}

fn markdownOptions(font_size: f32) chat_markdown.RenderOptions {
    return .{
        .base_font_size = font_size,
        .line_height = font_size * 1.32,
        .glyph_width = font_size * 0.55,
        .code_font_size = font_size * 0.92,
    };
}

fn renderMarkdownBody(state: *app_state.AppState, rect: palette.Rect, body: []const u8, clip: palette.Rect) void {
    if (body.len == 0) return;
    var view = chat_markdown.buildBodyView(state.allocator, body) catch {
        renderWrappedBody(state, rect, body, paletteColor(theme.COLOR_WHITE), theme.scaledUi(16.0), clip);
        return;
    };
    defer view.deinit(state.allocator);
    var context = chat_markdown.PaletteRenderContext{
        .allocator = state.allocator,
        .batch = &state.palette_overlay_batch,
        .frame_text = &state.palette_frame_text,
        .cursor = rect,
        .available_width = rect.w,
        .clip = clip,
    };
    chat_markdown.renderPaletteBody(&context, view, markdownOptions(theme.scaledUi(16.0)));
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

fn renderWrappedBody(state: *app_state.AppState, rect: palette.Rect, body: []const u8, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    if (body.len == 0) return;
    const char_w = font_size * 0.52;
    const line_h = font_size * 1.28;
    const chars_per_line = @max(@as(usize, @intFromFloat(rect.w / char_w)), 1);
    var y = rect.y;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= body.len and y < rect.y + rect.h and y < clip.y + clip.h) : (i += 1) {
        if (i != body.len and body[i] != '\n') continue;
        var chunk_start = line_start;
        const line_end = i;
        if (line_end == chunk_start) {
            if (y + line_h >= clip.y and y <= clip.y + clip.h) {
                queueFixedTextLine(state, .{ .x = rect.x, .y = y, .w = rect.w, .h = line_h }, " ", color, font_size, clip);
            }
            y += line_h;
        } else {
            while (chunk_start < line_end and y < rect.y + rect.h and y < clip.y + clip.h) {
                const remaining = line_end - chunk_start;
                const chunk_len = @min(remaining, chars_per_line);
                const chunk = body[chunk_start .. chunk_start + chunk_len];
                if (y + line_h >= clip.y and y <= clip.y + clip.h) {
                    queueFixedTextLine(state, .{ .x = rect.x, .y = y, .w = rect.w, .h = line_h }, chunk, color, font_size, clip);
                }
                y += line_h;
                chunk_start += chunk_len;
            }
        }
        line_start = i + 1;
    }
}

fn renderComposer(state: *app_state.AppState, rect: palette.Rect) void {
    state.syncPaletteComposerFromDraft();
    state.syncPaletteComposerControls();
    state.setPaletteComposerBounds(.{ rect.x, rect.y }, .{ rect.x + rect.w, rect.y + rect.h });
    state.palette_composer.render(state.allocator, &state.palette_overlay_batch) catch |err| {
        app_state.log.warn("failed to render palette composer: {s}", .{@errorName(err)});
    };
    renderComposerDraftImage(state);
    renderComposerToolbarIcons(state);
    renderComposerSendIcon(state);
}

fn renderComposerDraftImage(state: *app_state.AppState) void {
    const count = state.currentThread().draftImageCount();
    if (count == 0) {
        state.setComposerDraftImageClearRect(null);
        return;
    }
    const previous_z = state.palette_overlay_batch.setZIndex(10);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    const composer = state.palette_composer.bounds();
    if (composer.w <= theme.scaledUi(140.0)) {
        state.setComposerDraftImageClearRect(null);
        return;
    }

    const preview_h = theme.scaledUi(68.0);
    const thumb_max: f32 = theme.scaledUi(56.0);
    const gap = theme.scaledUi(10.0);
    const max_preview_w = if (composer.w >= theme.scaledUi(700.0)) theme.scaledUi(330.0) else composer.w - theme.scaledUi(48.0);
    const preview_w = @min(max_preview_w, (composer.w - theme.scaledUi(48.0) - gap) * 0.5);
    const per_row: usize = if (composer.w >= theme.scaledUi(700.0)) 2 else 1;
    const start_x = composer.x + theme.scaledUi(24.0);
    const rows = (count + per_row - 1) / per_row;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const image = state.currentThread().draftImageAt(index) orelse continue;
        const row = index / per_row;
        const col = index % per_row;
        const preview = palette.Rect{
            .x = start_x + @as(f32, @floatFromInt(col)) * (preview_w + gap),
            .y = composer.y - @as(f32, @floatFromInt(rows - row)) * (preview_h + gap),
            .w = preview_w,
            .h = preview_h,
        };
        renderComposerDraftImageChip(state, image.*, index, preview, thumb_max);
    }
}

fn renderComposerDraftImageChip(state: *app_state.AppState, image: app_state.ChatImageAttachment, index: usize, preview: palette.Rect, thumb_max: f32) void {
    queueRounded(state, preview, paletteColor(colors.rgba(7, 13, 14, 255)), theme.scaledUi(9.0));
    queueBorder(state, preview, paletteColor(colors.rgba(76, 95, 101, 255)), theme.scaledUi(9.0), theme.scaledUi(1.0));

    const thumb = palette.Rect{ .x = preview.x + theme.scaledUi(6.0), .y = preview.y + (preview.h - thumb_max) * 0.5, .w = thumb_max, .h = thumb_max };
    queueRounded(state, thumb, paletteColor(colors.rgba(17, 24, 26, 255)), theme.scaledUi(8.0));
    if (state.ensureImageTexture(image.path)) |cached| {
        const dims = runtime.scaledImageSize(cached.width, cached.height, thumb.w, thumb.h);
        queueImage(state, .{ .x = thumb.x + (thumb.w - dims[0]) * 0.5, .y = thumb.y + (thumb.h - dims[1]) * 0.5, .w = dims[0], .h = dims[1] }, cached, thumb);
    }

    var size_buf: [32:0]u8 = undefined;
    const size_label = runtime.formatByteSize(&size_buf, image.byte_size);
    const clear_size = theme.scaledUi(22.0);
    const clear_rect = palette.Rect{ .x = preview.x + preview.w - clear_size - theme.scaledUi(8.0), .y = preview.y + theme.scaledUi(8.0), .w = clear_size, .h = clear_size };
    state.setComposerDraftImageClearRectAt(clear_rect, index);
    const label_x = thumb.x + thumb.w + theme.scaledUi(12.0);
    const label_w = @max(clear_rect.x - label_x - theme.scaledUi(12.0), theme.scaledUi(1.0));
    queueText(state, .{ .x = label_x, .y = preview.y + theme.scaledUi(15.0), .w = label_w, .h = theme.scaledUi(20.0) }, image.file_name, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), preview);
    queueText(state, .{ .x = label_x, .y = preview.y + theme.scaledUi(39.0), .w = label_w, .h = theme.scaledUi(18.0) }, size_label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), preview);
    queueRounded(state, clear_rect, paletteColor(colors.rgba(35, 42, 46, 255)), clear_size * 0.5);
    queueBorder(state, clear_rect, paletteColor(colors.rgba(86, 105, 112, 255)), clear_size * 0.5, theme.scaledUi(1.0));
    queueText(state, .{ .x = clear_rect.x + clear_rect.w * 0.34, .y = clear_rect.y + clear_rect.h * 0.10, .w = clear_rect.w * 0.5, .h = clear_rect.h * 0.8 }, "x", paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), clear_rect);
}

fn renderComposerToolbarIcons(state: *app_state.AppState) void {
    const icon_color = paletteColor(.{ 0.82, 0.85, 0.91, 1.0 });
    const model_rect = state.palette_composer.modelRect();
    const fast_rect = state.palette_composer.fastRect();
    const access_rect = state.palette_composer.accessRect();
    const icon_size = theme.scaledUi(22.0);

    const provider_icon = switch (state.currentThread().provider) {
        .codex => state.codex_logo_texture,
        .opencode => state.opencode_logo_texture,
    };
    if (provider_icon) |cached| {
        queueImage(state, .{
            .x = model_rect.x + theme.scaledUi(17.0),
            .y = model_rect.y + (model_rect.h - icon_size) * 0.5,
            .w = icon_size,
            .h = icon_size,
        }, cached, model_rect);
    }

    const fast_icon_rect = palette.Rect{
        .x = fast_rect.x + theme.scaledUi(17.0),
        .y = fast_rect.y + (fast_rect.h - icon_size) * 0.5,
        .w = icon_size,
        .h = icon_size,
    };
    if (state.currentThread().fast_mode == .on) {
        drawBoltIcon(state, fast_icon_rect, icon_color);
    } else {
        drawDefaultModeIcon(state, fast_icon_rect, icon_color);
    }

    drawAccessIcon(state, .{
        .x = access_rect.x + theme.scaledUi(17.0),
        .y = access_rect.y + (access_rect.h - icon_size) * 0.5,
        .w = icon_size,
        .h = icon_size,
    }, icon_color);
}

fn renderComposerSendIcon(state: *app_state.AppState) void {
    const rect = state.palette_composer.sendButtonRect();
    const color = paletteColor(theme.COLOR_WHITE);
    const cx = rect.x + rect.w * 0.5;
    const cy = rect.y + rect.h * 0.5;
    const shaft_w = @max(rect.w * 0.10, theme.scaledUi(2.0));
    const shaft_h = rect.h * 0.32;
    const head_w = rect.w * 0.36;
    queueRect(state, .{
        .x = cx - shaft_w * 0.5,
        .y = cy - shaft_h * 0.10,
        .w = shaft_w,
        .h = shaft_h,
    }, color);
    queueTriangle(
        state,
        .{ .x = cx, .y = cy - shaft_h * 0.62 },
        .{ .x = cx - head_w * 0.5, .y = cy - shaft_h * 0.10 },
        .{ .x = cx + head_w * 0.5, .y = cy - shaft_h * 0.10 },
        color,
    );
}

fn drawBoltIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    const p = [_]palette.draw.Vec2{
        .{ .x = rect.x + rect.w * 0.58, .y = rect.y + rect.h * 0.06 },
        .{ .x = rect.x + rect.w * 0.24, .y = rect.y + rect.h * 0.54 },
        .{ .x = rect.x + rect.w * 0.47, .y = rect.y + rect.h * 0.54 },
        .{ .x = rect.x + rect.w * 0.35, .y = rect.y + rect.h * 0.94 },
        .{ .x = rect.x + rect.w * 0.76, .y = rect.y + rect.h * 0.42 },
        .{ .x = rect.x + rect.w * 0.51, .y = rect.y + rect.h * 0.42 },
    };
    queueTriangle(state, p[0], p[1], p[2], color);
    queueTriangle(state, p[0], p[2], p[5], color);
    queueTriangle(state, p[5], p[3], p[4], color);
    queueTriangle(state, p[5], p[2], p[3], color);
}

fn drawDefaultModeIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    const stroke = @max(rect.w * 0.11, 1.5);
    queueBorder(state, .{
        .x = rect.x + rect.w * 0.18,
        .y = rect.y + rect.h * 0.18,
        .w = rect.w * 0.64,
        .h = rect.h * 0.64,
    }, color, rect.w * 0.32, stroke);
    queueRect(state, .{
        .x = rect.x + rect.w * 0.48,
        .y = rect.y + rect.h * 0.30,
        .w = stroke,
        .h = rect.h * 0.24,
    }, color);
    queueRect(state, .{
        .x = rect.x + rect.w * 0.48,
        .y = rect.y + rect.h * 0.48,
        .w = rect.w * 0.20,
        .h = stroke,
    }, color);
}

fn drawAccessIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    const stroke = @max(rect.w * 0.12, 1.5);
    const body = palette.Rect{
        .x = rect.x + rect.w * 0.18,
        .y = rect.y + rect.h * 0.42,
        .w = rect.w * 0.64,
        .h = rect.h * 0.42,
    };
    queueBorder(state, body, color, theme.scaledUi(3.0), stroke);
    if (state.currentThread().access_mode == .full_access) {
        queueRect(state, .{ .x = rect.x + rect.w * 0.70, .y = rect.y + rect.h * 0.30, .w = stroke, .h = rect.h * 0.16 }, color);
        queueRect(state, .{ .x = rect.x + rect.w * 0.44, .y = rect.y + rect.h * 0.22, .w = rect.w * 0.28, .h = stroke }, color);
        queueRect(state, .{ .x = rect.x + rect.w * 0.44, .y = rect.y + rect.h * 0.22, .w = stroke, .h = rect.h * 0.16 }, color);
    } else {
        queueRect(state, .{ .x = rect.x + rect.w * 0.28, .y = rect.y + rect.h * 0.30, .w = stroke, .h = rect.h * 0.23 }, color);
        queueRect(state, .{ .x = rect.x + rect.w * 0.28, .y = rect.y + rect.h * 0.22, .w = rect.w * 0.44, .h = stroke }, color);
        queueRect(state, .{ .x = rect.x + rect.w * 0.72 - stroke, .y = rect.y + rect.h * 0.30, .w = stroke, .h = rect.h * 0.23 }, color);
    }
}

fn stableText(state: *app_state.AppState, value: []const u8) []const u8 {
    const start = state.palette_frame_text.items.len;
    state.palette_frame_text.appendSlice(state.allocator, value) catch return "";
    return state.palette_frame_text.items[start .. start + value.len];
}

fn queueRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch {};
}

fn queueRounded(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch {};
}

fn queueTriangle(state: *app_state.AppState, p0: palette.draw.Vec2, p1: palette.draw.Vec2, p2: palette.draw.Vec2, color: palette.Color) void {
    state.palette_overlay_batch.triangle(state.allocator, p0, p1, p2, color) catch {};
}

fn queueBorder(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch {};
}

fn queueImage(state: *app_state.AppState, rect: palette.Rect, texture: app_state.CachedImageTexture, clip: ?palette.Rect) void {
    if (!texture.valid or texture.texture_id == 0) return;
    state.palette_overlay_batch.image(state.allocator, rect, palette.TextureId.init(texture.texture_id), .{
        .x = 0.0,
        .y = 0.0,
        .w = 1.0,
        .h = 1.0,
    }, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }, clip) catch {};
}

fn queueText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.text(state.allocator, rect, stableText(state, value), color, font_size, clip) catch {};
}

fn queueFixedText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.fixedText(state.allocator, rect, stableText(state, value), color, font_size, clip, .{}, font_size * 0.55, font_size * 1.25, true) catch {};
}

fn queueFixedTextLine(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.fixedText(state.allocator, rect, stableText(state, value), color, font_size, clip, .{}, font_size * 0.55, font_size * 1.25, false) catch {};
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}
