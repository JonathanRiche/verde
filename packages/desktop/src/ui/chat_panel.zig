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

const TOP_BAR_HEIGHT: f32 = 57.0; // ~70% of legacy 82px cap
const COMPOSER_HEIGHT: f32 = 220.0;
const TRANSCRIPT_MAX_WIDTH: f32 = 960.0;
const TRANSCRIPT_LINE_HEIGHT: f32 = 22.0;

var transcript_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

pub fn renderWorkspace(state: *app_state.AppState, width: f32, height: f32) void {
    renderWorkspaceAt(state, .{ .x = estimateWorkspaceOriginX(state, width), .y = 0.0, .w = width, .h = height });
}

pub fn renderWorkspaceAt(state: *app_state.AppState, rect: palette.Rect) void {
    state.invalidateComposerToolbarOverlayHitRects();
    queueRect(state, rect, paletteColor(colors.CHAT_BLACK));
    if (state.projects.items.len == 0) {
        renderEmptyProjects(state, rect);
        return;
    }

    // ~30% shorter than the original (0.14 / 54 / 82) clamp: scale each bound by 0.7.
    const header_height = theme.clampf(rect.h * 0.098, theme.scaledUi(38.0), theme.scaledUi(TOP_BAR_HEIGHT));
    const composer_height = theme.clampf(rect.h * 0.29, theme.scaledUi(128.0), theme.scaledUi(COMPOSER_HEIGHT));
    const bottom_margin = theme.clampf(rect.h * 0.018, theme.scaledUi(8.0), theme.scaledUi(14.0));
    const side_margin = theme.clampf(rect.w * 0.045, theme.scaledUi(16.0), theme.scaledUi(48.0));
    const terminal_visible = state.isTerminalVisible() and !state.isBrowserVisible();
    const terminal_gap = if (terminal_visible) theme.scaledUi(12.0) else 0.0;
    const terminal_height = if (terminal_visible)
        @min(@max((rect.h - header_height - composer_height - bottom_margin) * 0.32, theme.scaledUi(120.0)), theme.scaledUi(260.0))
    else
        0.0;

    const header = palette.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = header_height };

    const composer_bottom = if (terminal_height > 0.0)
        rect.y + rect.h - terminal_height - terminal_gap
    else
        rect.y + rect.h - bottom_margin;
    const composer_y = composer_bottom - composer_height;

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
        .h = @max(composer_y - (header.y + header.h) - attachment_reserve, theme.scaledUi(120.0)),
    };

    const split_chat_browser = state.isBrowserVisible() and body.w >= theme.scaledUi(900.0);
    const browser_width = if (split_chat_browser) state.browserPanelWidth(body.w) else 0.0;
    const composer_lane_w = if (split_chat_browser) body.w - browser_width else body.w;
    const composer_lane_x = body.x;

    const composer_width = @max(theme.scaledUi(220.0), @min(composer_lane_w - side_margin * 2.0, theme.scaledUi(980.0)));
    const composer_rect = palette.Rect{
        .x = composer_lane_x + (composer_lane_w - composer_width) * 0.5,
        .y = composer_y,
        .w = composer_width,
        .h = composer_height,
    };

    if (split_chat_browser) {
        const chat_rect = palette.Rect{ .x = body.x, .y = body.y, .w = body.w - browser_width, .h = body.h };
        renderTranscript(state, chat_rect);
        // Transcript uses only `body` (above composer). The browser column is empty to the right of the
        // composer, so extend the dock through that strip to the same bottom as the composer row.
        const browser_dock_h = composer_bottom - body.y;
        browser_panel.renderDockAt(state, .{
            .x = chat_rect.x + chat_rect.w,
            .y = body.y,
            .w = browser_width,
            .h = @max(browser_dock_h, theme.scaledUi(120.0)),
        });
    } else {
        renderTranscript(state, body);
    }

    // Paint after the transcript so the opaque header strip wins over any scrolled
    // message geometry or GL text that would otherwise overlap the title bar.
    renderHeader(state, header);

    renderComposer(state, composer_rect);
    if (terminal_height > 0.0) {
        terminal_panel.renderDockAt(state, .{
            .x = rect.x,
            .y = rect.y + rect.h - terminal_height,
            .w = rect.w,
            .h = terminal_height,
        });
    }
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

/// True when `(x, y)` lies inside the transcript pane last painted by `renderTranscript`.
pub fn pointerOverTranscript(x: f32, y: f32) bool {
    return rectContains(transcript_rect, x, y);
}

pub fn handleTranscriptPaletteWheel(state: *app_state.AppState, x: f32, y: f32, wheel_y: f32) bool {
    if (wheel_y == 0.0 or !rectContains(transcript_rect, x, y)) return false;
    state.transcript_focused = true;
    const current = state.currentTranscriptScrollY() orelse 0.0;
    state.rememberCurrentTranscriptScroll(@max(0.0, current - wheel_y * theme.scaledUi(64.0)));
    state.transcript_auto_follow_pending = false;
    state.scroll_transcript_to_bottom_frames = 0;
    return true;
}

const TranscriptMarkdownHit = struct {
    message_index: usize,
    point: chat_markdown.SelectionPoint,
};

fn assistantTranscriptMarkdownHit(
    state: *app_state.AppState,
    column: palette.Rect,
    y: f32,
    height: f32,
    role: app_state.ChatRole,
    body_raw: []const u8,
    muted_body: bool,
    assistant_plain_layout: bool,
    message_index: usize,
    mouse_x: f32,
    mouse_y: f32,
) ?TranscriptMarkdownHit {
    if (!(role == .assistant and !muted_body and !assistant_plain_layout)) return null;
    const bubble_width = if (role == .user) column.w * 0.62 else column.w;
    const bubble_x = if (role == .user) column.x + column.w - bubble_width else column.x;
    const bubble = palette.Rect{ .x = bubble_x, .y = y, .w = bubble_width, .h = height };

    const body_rect = palette.Rect{
        .x = bubble.x + theme.scaledUi(14.0),
        .y = bubble.y + theme.scaledUi(32.0),
        .w = bubble.w - theme.scaledUi(28.0),
        .h = bubble.h - theme.scaledUi(38.0),
    };
    if (!rectContains(body_rect, mouse_x, mouse_y)) return null;

    const body_text = std.mem.trim(u8, body_raw, "\n\r\t ");
    var view = chat_markdown.buildBodyView(state.allocator, body_text) catch return null;
    defer view.deinit(state.allocator);
    const pt = chat_markdown.hitTestSelectablePaletteBody(
        state.allocator,
        view,
        markdownOptions(theme.scaledUi(16.0)),
        body_rect,
        body_rect.w,
        mouse_x,
        mouse_y,
    ) catch return null;
    const p = pt orelse return null;
    return .{ .message_index = message_index, .point = p };
}

fn transcriptMarkdownBubbleHit(
    state: *app_state.AppState,
    mouse_x: f32,
    mouse_y: f32,
) ?TranscriptMarkdownHit {
    const column = state.transcript_palette_column;
    const clip = state.transcript_palette_clip;
    if (column.w <= 0 or !rectContains(clip, mouse_x, mouse_y)) return null;

    const thread = state.currentThread();
    const scroll_y = state.transcript_palette_scroll_y;
    var content_y = column.y - scroll_y;

    for (thread.messages.items, 0..) |message, msg_idx| {
        const item_h = transcriptMessageHeight(message.body, message.role, column.w, message.author, false);
        if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body)) {
            content_y += item_h + theme.scaledUi(12.0);
            continue;
        }
        if (assistantTranscriptMarkdownHit(state, column, content_y, item_h, message.role, message.body, false, false, msg_idx, mouse_x, mouse_y)) |hit| {
            return hit;
        }
        content_y += item_h + theme.scaledUi(12.0);
    }

    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return null;

    const base_idx = thread.messages.items.len;
    for (send_state.pending_events.items, 0..) |event, pi| {
        const msg_idx = base_idx + pi;
        const item_h = transcriptMessageHeight(event.body, event.role, column.w, event.author, false);
        if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body)) {
            content_y += item_h + theme.scaledUi(12.0);
            continue;
        }
        if (assistantTranscriptMarkdownHit(state, column, content_y, item_h, event.role, event.body, false, false, msg_idx, mouse_x, mouse_y)) |hit| {
            return hit;
        }
        content_y += item_h + theme.scaledUi(12.0);
    }

    const stream_text: []const u8 = send_state.partial_text.items;
    const body: []const u8 = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const stream_plain = stream_text.len > 0;
    const assistant_h = transcriptMessageHeight(body, .assistant, column.w, "", stream_plain);
    const stream_idx = base_idx + send_state.pending_events.items.len;
    return assistantTranscriptMarkdownHit(state, column, content_y, assistant_h, .assistant, body, stream_text.len == 0, stream_plain, stream_idx, mouse_x, mouse_y);
}

pub fn handleTranscriptPaletteMouseMotion(state: *app_state.AppState) void {
    if (!state.transcriptMarkdownSelectionDragging()) return;
    const hit = transcriptMarkdownBubbleHit(state, state.palette_mouse_x, state.palette_mouse_y) orelse return;
    state.updateTranscriptMarkdownSelection(hit.message_index, hit.point);
}

fn applyTranscriptMarkdownMulticlick(state: *app_state.AppState, hit: TranscriptMarkdownHit, clicks: usize) void {
    if (clicks < 2) return;
    const snap = transcriptMarkdownMessageSnapshot(state, hit.message_index) orelse return;
    var view = chat_markdown.buildBodyView(state.allocator, snap.body_trim) catch return;
    defer view.deinit(state.allocator);
    const md = markdownOptions(theme.scaledUi(16.0));
    const range = chat_markdown.selectionRangeForClickCount(
        state.allocator,
        view,
        snap.body_inner_w,
        md,
        hit.point,
        clicks,
    ) orelse {
        state.beginTranscriptMarkdownSelection(hit.message_index, hit.point);
        return;
    };
    state.selectAllTranscriptMarkdownSelection(
        hit.message_index,
        range.anchor,
        hit.message_index,
        range.focus,
    );
}

pub fn handleTranscriptPaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    if (!down) {
        if (state.transcriptMarkdownSelectionDragging()) {
            state.endTranscriptMarkdownSelection();
        }
        return false;
    }

    if (!rectContains(transcript_rect, x, y)) return false;

    state.transcript_focused = true;
    if (transcriptMarkdownBubbleHit(state, x, y)) |hit| {
        state.blurPaletteComposer();
        if (clicks >= 2) {
            applyTranscriptMarkdownMulticlick(state, hit, @intCast(clicks));
        } else {
            state.beginTranscriptMarkdownSelection(hit.message_index, hit.point);
        }
        return true;
    }
    state.clearTranscriptMarkdownSelection();
    state.blurPaletteComposer();
    return false;
}

/// Selects all assistant markdown in the current thread (persisted messages, pending timeline, and stream tail when present).
pub fn selectAllTranscriptMarkdownInThread(state: *app_state.AppState) bool {
    var list = std.ArrayList(usize).empty;
    defer list.deinit(state.allocator);

    const thread = state.currentThread();
    for (thread.messages.items, 0..) |_, i| {
        if (transcriptMarkdownMessageSnapshot(state, i) == null) continue;
        list.append(state.allocator, i) catch return false;
    }

    const send_state = thread.send_state;
    send_state.mutex.lock();
    const pending_active = send_state.status == .pending;
    const pending_count: usize = if (pending_active) send_state.pending_events.items.len else 0;
    send_state.mutex.unlock();

    const base = thread.messages.items.len;
    if (pending_active) {
        for (0..pending_count) |pi| {
            const idx = base + pi;
            if (transcriptMarkdownMessageSnapshot(state, idx) == null) continue;
            list.append(state.allocator, idx) catch return false;
        }
        const stream_idx = base + pending_count;
        if (transcriptMarkdownMessageSnapshot(state, stream_idx) != null) {
            list.append(state.allocator, stream_idx) catch return false;
        }
    }

    if (list.items.len == 0) return false;
    const first_msg = list.items[0];
    const last_msg = list.items[list.items.len - 1];
    const last_snap = transcriptMarkdownMessageSnapshot(state, last_msg) orelse return false;

    var last_view = chat_markdown.buildBodyView(state.allocator, last_snap.body_trim) catch return false;
    defer last_view.deinit(state.allocator);
    const md = markdownOptions(theme.scaledUi(16.0));
    const last_pt = chat_markdown.lastSelectablePointInBody(
        state.allocator,
        last_view,
        last_snap.body_inner_w,
        md,
    ) catch return false;

    state.selectAllTranscriptMarkdownSelection(
        first_msg,
        .{ .line_index = 0, .column = 0 },
        last_msg,
        last_pt,
    );
    return true;
}

fn transcriptMarkdownMessageSnapshot(state: *app_state.AppState, message_index: usize) ?struct {
    body_trim: []const u8,
    body_inner_w: f32,
    markdown: bool,
} {
    const column = state.transcript_palette_column;
    if (column.w <= 0.0) return null;

    const thread = state.currentThread();
    const n = thread.messages.items.len;
    if (message_index < n) {
        const m = thread.messages.items[message_index];
        if (m.role == .system and shouldRenderPaletteCommandRow(m.author, m.body)) return null;
        if (m.role != .assistant) return null;
        const body_trim = std.mem.trim(u8, m.body, "\n\r\t ");
        const bubble_w = column.w;
        const inner = @max(bubble_w - theme.scaledUi(28.0), theme.scaledUi(80.0));
        return .{ .body_trim = body_trim, .body_inner_w = inner, .markdown = true };
    }

    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return null;
    const pi = message_index - n;
    if (pi < send_state.pending_events.items.len) {
        const ev = send_state.pending_events.items[pi];
        if (ev.role == .system and shouldRenderPaletteCommandRow(ev.author, ev.body)) return null;
        if (ev.role != .assistant) return null;
        const body_trim = std.mem.trim(u8, ev.body, "\n\r\t ");
        const bubble_w = column.w;
        const inner = @max(bubble_w - theme.scaledUi(28.0), theme.scaledUi(80.0));
        return .{ .body_trim = body_trim, .body_inner_w = inner, .markdown = true };
    }
    if (pi != send_state.pending_events.items.len) return null;

    const stream_text: []const u8 = send_state.partial_text.items;
    const body: []const u8 = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const body_trim = std.mem.trim(u8, body, "\n\r\t ");
    const inner = @max(column.w - theme.scaledUi(28.0), theme.scaledUi(80.0));
    return .{ .body_trim = body_trim, .body_inner_w = inner, .markdown = true };
}

pub fn transcriptMarkdownSelectionPlainText(state: *app_state.AppState) std.mem.Allocator.Error!?[]u8 {
    const sel = state.transcriptMarkdownSelection() orelse return null;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(state.allocator);

    const o = chat_markdown.orderTranscriptMarkdownEndpoints(
        sel.anchor.message_index,
        sel.anchor.point,
        sel.focus.message_index,
        sel.focus.point,
    );

    var mi = o.start_msg;
    while (mi <= o.end_msg) : (mi += 1) {
        const snap = transcriptMarkdownMessageSnapshot(state, mi) orelse continue;
        if (!snap.markdown) continue;

        var view = try chat_markdown.buildBodyView(state.allocator, snap.body_trim);
        defer view.deinit(state.allocator);

        const local = try chat_markdown.localMarkdownSelectionRangeForMessage(
            state.allocator,
            sel.anchor.message_index,
            sel.anchor.point,
            sel.focus.message_index,
            sel.focus.point,
            mi,
            view,
            snap.body_inner_w,
            markdownOptions(theme.scaledUi(16.0)),
        ) orelse continue;

        var scratch_batch = palette.RenderBatch{};
        defer scratch_batch.deinit(state.allocator);
        var scratch_text = std.ArrayList(u8).empty;
        defer scratch_text.deinit(state.allocator);

        var ctx = chat_markdown.PaletteRenderContext{
            .allocator = state.allocator,
            .batch = &scratch_batch,
            .frame_text = &scratch_text,
            .cursor = .{ .x = 0.0, .y = 0.0, .w = snap.body_inner_w, .h = 100000.0 },
            .available_width = snap.body_inner_w,
        };
        var sel_out = chat_markdown.renderSelectablePaletteBody(
            &ctx,
            state.allocator,
            view,
            markdownOptions(theme.scaledUi(16.0)),
            local,
            true,
        );
        defer sel_out.deinit(state.allocator);
        if (sel_out.copied_text) |z| {
            const slice = std.mem.sliceTo(z, 0);
            if (slice.len == 0) continue;
            if (out.items.len > 0) try out.append(state.allocator, '\n');
            try out.appendSlice(state.allocator, slice);
        }
    }

    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(state.allocator);
}

fn renderHeader(state: *app_state.AppState, rect: palette.Rect) void {
    queueRect(state, rect, paletteColor(colors.CHAT_BLACK));
    queueRect(state, .{ .x = rect.x, .y = rect.y + rect.h - 1.0, .w = rect.w, .h = 1.0 }, paletteColor(colors.DARK_BLUE));

    const project = state.currentProject();
    const thread = state.currentThread();
    const title = if (thread.title.len > 0) thread.title else project.label;
    const title_line_h = theme.scaledUi(32.0);
    const title_y = rect.y + @max((rect.h - title_line_h) * 0.5, theme.scaledUi(4.0));
    queueText(state, .{
        .x = rect.x + theme.scaledUi(32.0),
        .y = title_y,
        .w = @max(rect.w - theme.scaledUi(64.0), 1.0),
        .h = title_line_h,
    }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(18.0), rect);
}

fn renderEmptyProjects(state: *app_state.AppState, rect: palette.Rect) void {
    const x = rect.x + theme.scaledUi(44.0);
    var y = rect.y + theme.scaledUi(86.0);
    queueText(state, .{ .x = x, .y = y, .w = rect.w - theme.scaledUi(88.0), .h = theme.scaledUi(38.0) }, "No projects yet", paletteColor(theme.COLOR_WHITE), theme.scaledUi(28.0), rect);
    y += theme.scaledUi(42.0);
    queueText(state, .{ .x = x, .y = y, .w = rect.w - theme.scaledUi(88.0), .h = theme.scaledUi(28.0) }, "Use the project rail to add a folder and start chatting.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(16.0), rect);
}

/// While the current thread is streaming, keep `transcript_auto_follow_pending` on when the viewport
/// is at (or near) the tail, or during the initial scroll-to-bottom animation. Wheel on the
/// transcript clears the latch; scrolling back within ~72px of the bottom turns it on again.
fn updateTranscriptAutoFollowPalette(state: *app_state.AppState, has_pending_stream: bool, max_scroll: f32, scroll_y: f32) void {
    if (!has_pending_stream) {
        state.transcript_auto_follow_pending = false;
        return;
    }
    if (state.scroll_transcript_to_bottom_frames > 0 or transcriptScrollNearBottom(scroll_y, max_scroll)) {
        state.transcript_auto_follow_pending = true;
    }
}

fn transcriptScrollNearBottom(scroll_y: f32, max_scroll: f32) bool {
    if (max_scroll <= 0.0) return true;
    return (max_scroll - scroll_y) <= theme.scaledUi(72.0);
}

fn renderTranscript(state: *app_state.AppState, rect: palette.Rect) void {
    transcript_rect = rect;
    const column_width = @min(rect.w - theme.scaledUi(48.0), theme.scaledUi(TRANSCRIPT_MAX_WIDTH));
    const column = palette.Rect{ .x = rect.x + (rect.w - column_width) * 0.5, .y = rect.y + theme.scaledUi(28.0), .w = column_width, .h = @max(rect.h - theme.scaledUi(42.0), 1.0) };
    // Clip to full transcript body (same x/w as layout rect) so GL text and bubbles
    // stay below the workspace header when scrolled.
    const clip = rect;
    state.transcript_palette_column = column;
    state.transcript_palette_clip = clip;

    const thread = state.currentThread();

    if (thread.messages.items.len == 0 and !thread.isSendPendingForUi()) {
        state.transcript_palette_scroll_y = 0.0;
        queueText(state, .{ .x = column.x, .y = column.y, .w = column.w, .h = theme.scaledUi(30.0) }, "No messages yet", paletteColor(theme.COLOR_WHITE), theme.scaledUi(20.0), clip);
        queueText(state, .{ .x = column.x, .y = column.y + theme.scaledUi(32.0), .w = column.w, .h = theme.scaledUi(26.0) }, "Choose a provider, type a prompt below, and start the first chat for this directory.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(15.0), clip);
        return;
    }

    const content_height = transcriptContentHeight(thread, column.w);
    const max_scroll = @max(0.0, content_height - column.h);
    const has_pending_stream = state.hasPendingStream();

    var scroll_y = std.math.clamp(state.currentTranscriptScrollY() orelse max_scroll, 0.0, max_scroll);
    if (state.pending_transcript_line_scroll_steps != 0) {
        scroll_y = std.math.clamp(scroll_y + @as(f32, @floatFromInt(state.pending_transcript_line_scroll_steps)) * theme.scaledUi(TRANSCRIPT_LINE_HEIGHT), 0.0, max_scroll);
        state.pending_transcript_line_scroll_steps = 0;
    }
    if (state.pending_transcript_page_scroll_steps != 0) {
        scroll_y = std.math.clamp(scroll_y + @as(f32, @floatFromInt(state.pending_transcript_page_scroll_steps)) * column.h * 0.82, 0.0, max_scroll);
        state.pending_transcript_page_scroll_steps = 0;
    }

    updateTranscriptAutoFollowPalette(state, has_pending_stream, max_scroll, scroll_y);

    if (state.transcript_auto_follow_pending or state.scroll_transcript_to_bottom_frames > 0) {
        scroll_y = max_scroll;
    }
    if (state.scroll_transcript_to_bottom_frames > 0) {
        state.scroll_transcript_to_bottom_frames -= 1;
    }
    if (state.scroll_transcript_to_bottom_frames == 0 and !has_pending_stream) {
        state.transcript_auto_follow_pending = false;
    }
    state.rememberCurrentTranscriptScroll(scroll_y);
    state.transcript_palette_scroll_y = scroll_y;

    var content_y = column.y - scroll_y;
    for (thread.messages.items, 0..) |message, msg_idx| {
        const item_h = transcriptMessageHeight(message.body, message.role, column.w, message.author, false);
        if (content_y + item_h >= column.y and content_y <= column.y + column.h) {
            renderTranscriptMessage(state, column, content_y, item_h, message, clip, msg_idx);
        }
        content_y += item_h + theme.scaledUi(12.0);
    }

    renderPendingTranscriptStream(state, thread, column, content_y, clip, thread.messages.items.len);

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
        total += transcriptMessageHeight(message.body, message.role, width, message.author, false) + theme.scaledUi(12.0);
    }
    total += transcriptPendingStreamHeight(thread, width);
    return total;
}

fn transcriptPendingStreamHeight(thread: *const app_state.ChatThread, column_width: f32) f32 {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return 0;

    var total: f32 = 0;
    for (send_state.pending_events.items) |event| {
        total += transcriptMessageHeight(event.body, event.role, column_width, event.author, false) + theme.scaledUi(12.0);
    }
    const stream_text: []const u8 = send_state.partial_text.items;
    const body_for_height = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const stream_plain = stream_text.len > 0;
    total += transcriptMessageHeight(body_for_height, .assistant, column_width, "", stream_plain) + theme.scaledUi(12.0);
    return total;
}

fn renderPendingTranscriptStream(state: *app_state.AppState, thread: *const app_state.ChatThread, column: palette.Rect, content_y: f32, clip: palette.Rect, base_message_index: usize) void {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return;

    var y = content_y;
    for (send_state.pending_events.items, 0..) |event, pi| {
        const msg_idx = base_message_index + pi;
        const item_h = transcriptMessageHeight(event.body, event.role, column.w, event.author, false);
        if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body)) {
            if (y + item_h >= column.y and y <= column.y + column.h) {
                renderCommandEventRow(state, column, y, item_h, event.author, event.body, clip);
            }
        } else {
            const role_label: []const u8 = switch (event.role) {
                .user => "You",
                .assistant => if (event.author.len > 0) event.author else "Assistant",
                .system => if (event.author.len > 0) event.author else "System",
            };
            if (y + item_h >= column.y and y <= column.y + column.h) {
                renderTranscriptBubbleFromParts(state, column, y, item_h, event.role, role_label, event.body, false, false, clip, msg_idx);
            }
        }
        y += item_h + theme.scaledUi(12.0);
    }

    var status_buf: [40]u8 = undefined;
    const working_label = formatPendingWorkingLabel(&status_buf, send_state.started_at_ms);
    const stream_text: []const u8 = send_state.partial_text.items;
    const body: []const u8 = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const stream_plain = stream_text.len > 0;
    const assistant_h = transcriptMessageHeight(body, .assistant, column.w, "", stream_plain);
    const stream_msg_idx = base_message_index + send_state.pending_events.items.len;
    if (y + assistant_h >= column.y and y <= column.y + column.h) {
        renderTranscriptBubbleFromParts(state, column, y, assistant_h, .assistant, working_label, body, stream_text.len == 0, stream_plain, clip, stream_msg_idx);
    }
}

fn unixTimestampMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn formatPendingWorkingLabel(buf: []u8, started_at_ms: i64) []const u8 {
    const now_ms = unixTimestampMs();
    const safe_started_at_ms = @max(started_at_ms, 0);
    const elapsed_ms = @max(now_ms - safe_started_at_ms, 0);
    const total_seconds: u64 = @intCast(@divTrunc(elapsed_ms, std.time.ms_per_s));
    const hours = total_seconds / 3600;
    const minutes = (total_seconds / 60) % 60;
    const seconds = total_seconds % 60;

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "Working - {d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "Working - 0:00";
    }
    return std.fmt.bufPrint(buf, "Working - {d}:{d:0>2}", .{ minutes, seconds }) catch "Working - 0:00";
}

fn isCommandSystemEvent(author: []const u8) bool {
    return std.mem.eql(u8, author, "Ran command") or std.mem.eql(u8, author, "Command failed");
}

/// True when the body looks like an executed shell one-liner (e.g. Codex/OpenCode style `/usr/bin/bash -lc '…'`).
fn isCommandLikeShellBody(body_raw: []const u8) bool {
    const t = std.mem.trim(u8, body_raw, "\n\r\t ");
    if (t.len < 8) return false;
    return std.mem.startsWith(u8, t, "/usr/bin/bash") or
        std.mem.startsWith(u8, t, "/bin/bash") or
        std.mem.startsWith(u8, t, "bash -lc") or
        std.mem.startsWith(u8, t, "/usr/bin/env bash") or
        std.mem.startsWith(u8, t, "/bin/sh -lc") or
        std.mem.startsWith(u8, t, "/usr/bin/sh");
}

fn shouldRenderPaletteCommandRow(author: []const u8, body_raw: []const u8) bool {
    if (isCommandSystemEvent(author)) return true;
    return isCommandLikeShellBody(body_raw);
}

/// Label shown after `>_` in the compact command row (Codex-native titles preserved; shell-like bodies default to "Ran command").
fn paletteCommandRowDisplayAuthor(original_author: []const u8, body_raw: []const u8) []const u8 {
    if (isCommandSystemEvent(original_author)) return original_author;
    if (isCommandLikeShellBody(body_raw)) return "Ran command";
    return original_author;
}

fn transcriptCommandEventHeight(original_author: []const u8, body_raw: []const u8, column_width: f32) f32 {
    const label = paletteCommandRowDisplayAuthor(original_author, body_raw);
    const pad_x = theme.scaledUi(14.0);
    const pad_y = theme.scaledUi(9.0);
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const font_size = theme.scaledUi(15.0);
    const inner_w = @max(column_width - pad_x * 2.0, theme.scaledUi(80.0));
    const chars_per_line = @max(@as(usize, @intFromFloat(inner_w / (font_size * 0.52))), 1);

    const combined = std.fmt.allocPrint(std.heap.page_allocator, ">_ {s} - {s}", .{ label, body }) catch {
        const line_count = wrappedLineCount(body, chars_per_line);
        return pad_y * 2.0 + @as(f32, @floatFromInt(1 + line_count)) * font_size * 1.28;
    };
    defer std.heap.page_allocator.free(combined);
    const line_count = wrappedLineCount(combined, chars_per_line);
    return pad_y * 2.0 + @as(f32, @floatFromInt(line_count)) * font_size * 1.28;
}

fn transcriptMessageHeight(body_raw: []const u8, role: app_state.ChatRole, column_width: f32, message_author: []const u8, assistant_plain_layout: bool) f32 {
    if (role == .system and shouldRenderPaletteCommandRow(message_author, body_raw)) {
        return transcriptCommandEventHeight(message_author, body_raw, column_width);
    }
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const font_size = theme.scaledUi(16.0);
    const body_width = if (role == .user) column_width * 0.62 else column_width;
    const body_inner_width = @max(body_width - theme.scaledUi(28.0), theme.scaledUi(80.0));
    if (role == .assistant and !assistant_plain_layout) {
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

/// Corner radius for transcript bubbles (user / assistant / system) and shell command rows.
fn transcriptBubbleCornerRadius() f32 {
    return theme.scaledUi(14.0);
}

/// Rounded fill with a rounded border ring (avoids `rectBorder`, which draws a sharp axis-aligned outline).
fn queueRoundedShellClipped(
    state: *app_state.AppState,
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

fn renderTranscriptMessage(state: *app_state.AppState, column: palette.Rect, y: f32, height: f32, message: app_state.ChatMessage, clip: palette.Rect, message_index: usize) void {
    if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body)) {
        renderCommandEventRow(state, column, y, height, message.author, message.body, clip);
        return;
    }
    const role_label = switch (message.role) {
        .user => "You",
        .assistant => if (message.author.len > 0) message.author else "Assistant",
        .system => "System",
    };
    renderTranscriptBubbleFromParts(state, column, y, height, message.role, role_label, message.body, false, false, clip, message_index);
}

fn renderCommandEventRow(
    state: *app_state.AppState,
    column: palette.Rect,
    y: f32,
    height: f32,
    original_author: []const u8,
    body_raw: []const u8,
    clip: palette.Rect,
) void {
    const bubble = palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height };
    const rr = transcriptBubbleCornerRadius();
    queueRoundedShellClipped(
        state,
        bubble,
        paletteColor(colors.rgba(28, 29, 34, 255)),
        paletteColor(colors.DARK_BLUE),
        rr,
        clip,
    );

    const pad = theme.scaledUi(14.0);
    const pad_y = theme.scaledUi(9.0);
    const inner = palette.Rect{
        .x = bubble.x + pad,
        .y = bubble.y + pad_y,
        .w = @max(bubble.w - pad * 2.0, theme.scaledUi(40.0)),
        .h = @max(bubble.h - pad_y * 2.0, theme.scaledUi(1.0)),
    };
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const label = paletteCommandRowDisplayAuthor(original_author, body_raw);
    const combined = std.fmt.allocPrint(state.allocator, ">_ {s} - {s}", .{ label, body }) catch {
        renderWrappedBody(state, inner, body, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(15.0), clip);
        return;
    };
    defer state.allocator.free(combined);
    const failed = std.mem.eql(u8, original_author, "Command failed");
    const color = if (failed) paletteColor(theme.COLOR_DIFF_REMOVE) else paletteColor(theme.COLOR_TEXT_MUTED);
    renderWrappedBody(state, inner, combined, color, theme.scaledUi(15.0), clip);
}

fn renderTranscriptBubbleFromParts(
    state: *app_state.AppState,
    column: palette.Rect,
    y: f32,
    height: f32,
    role: app_state.ChatRole,
    role_label: []const u8,
    body_raw: []const u8,
    muted_body: bool,
    assistant_plain_layout: bool,
    clip: palette.Rect,
    message_index: usize,
) void {
    const bubble_width = if (role == .user) column.w * 0.62 else column.w;
    const bubble_x = if (role == .user) column.x + column.w - bubble_width else column.x;
    const bubble = palette.Rect{ .x = bubble_x, .y = y, .w = bubble_width, .h = height };
    const bg = switch (role) {
        .user => colors.rgba(31, 48, 46, 255),
        .assistant => colors.rgba(22, 30, 32, 242),
        .system => colors.rgba(57, 43, 9, 235),
    };
    const rr = transcriptBubbleCornerRadius();
    queueRoundedShellClipped(state, bubble, paletteColor(bg), paletteColor(theme.COLOR_PANEL_MUTED), rr, clip);
    queueText(state, .{ .x = bubble.x + theme.scaledUi(14.0), .y = bubble.y + theme.scaledUi(8.0), .w = bubble.w - theme.scaledUi(28.0), .h = theme.scaledUi(20.0) }, role_label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), clip);
    const body_rect = palette.Rect{
        .x = bubble.x + theme.scaledUi(14.0),
        .y = bubble.y + theme.scaledUi(32.0),
        .w = bubble.w - theme.scaledUi(28.0),
        .h = bubble.h - theme.scaledUi(38.0),
    };
    const body_text = std.mem.trim(u8, body_raw, "\n\r\t ");
    const body_color = if (muted_body) paletteColor(theme.COLOR_TEXT_MUTED) else paletteColor(theme.COLOR_WHITE);
    if (role == .assistant and !muted_body and !assistant_plain_layout) {
        renderMarkdownBody(state, message_index, body_rect, body_text, clip);
    } else {
        renderWrappedBody(state, body_rect, body_text, body_color, theme.scaledUi(16.0), clip);
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

fn renderMarkdownBody(state: *app_state.AppState, message_index: usize, rect: palette.Rect, body: []const u8, clip: palette.Rect) void {
    if (body.len == 0) return;
    var view = chat_markdown.buildBodyView(state.allocator, body) catch {
        renderWrappedBody(state, rect, body, paletteColor(theme.COLOR_WHITE), theme.scaledUi(16.0), clip);
        return;
    };
    defer view.deinit(state.allocator);
    const font_size = theme.scaledUi(16.0);
    const md_opts = markdownOptions(font_size);
    const local_sel: ?chat_markdown.SelectionRange = if (state.transcriptMarkdownSelection()) |s| blk: {
        break :blk chat_markdown.localMarkdownSelectionRangeForMessage(
            state.allocator,
            s.anchor.message_index,
            s.anchor.point,
            s.focus.message_index,
            s.focus.point,
            message_index,
            view,
            rect.w,
            md_opts,
        ) catch null;
    } else null;

    const mx = state.palette_mouse_x;
    const my = state.palette_mouse_y;
    const hovered = state.palette_mouse_in_workspace and rectContains(rect, mx, my) and rectContains(clip, mx, my);

    var context = chat_markdown.PaletteRenderContext{
        .allocator = state.allocator,
        .batch = &state.palette_overlay_batch,
        .frame_text = &state.palette_frame_text,
        .cursor = rect,
        .available_width = rect.w,
        .mouse_pos = if (state.palette_mouse_in_workspace) .{ mx, my } else .{ -1.0, -1.0 },
        .hovered = hovered,
        .clip = clip,
    };
    var sel_out = chat_markdown.renderSelectablePaletteBody(
        &context,
        state.allocator,
        view,
        md_opts,
        local_sel,
        false,
    );
    defer sel_out.deinit(state.allocator);
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
    state.syncComposerToolbarOverlayHitRects();
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
    queueRoundedShellClipped(
        state,
        preview,
        paletteColor(colors.rgba(7, 13, 14, 255)),
        paletteColor(colors.rgba(76, 95, 101, 255)),
        theme.scaledUi(9.0),
        preview,
    );

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
    queueRoundedShellClipped(
        state,
        clear_rect,
        paletteColor(colors.rgba(35, 42, 46, 255)),
        paletteColor(colors.rgba(86, 105, 112, 255)),
        clear_size * 0.5,
        clear_rect,
    );
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

    if (state.currentThread().provider == .codex) {
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
    }

    drawAccessIcon(state, .{
        .x = access_rect.x + theme.scaledUi(17.0),
        .y = access_rect.y + (access_rect.h - icon_size) * 0.5,
        .w = icon_size,
        .h = icon_size,
    }, icon_color);
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

fn queueRoundedClipped(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, color, radius, clip) catch {};
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
