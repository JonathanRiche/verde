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
/// Direct wheel scroll (no inertia); larger than legacy 64 for faster scanning.
const TRANSCRIPT_WHEEL_PIXELS: f32 = 96.0;
const TRANSCRIPT_PAGE_VIEW_FRAC: f32 = 0.88;

var transcript_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

const WorkspaceHeaderOpenMenuRow = enum {
    folder,
    configured_editor,
    cursor,
    vscode,
    zed,
};

const WorkspaceHeaderHitCache = struct {
    header_rect: palette.Rect = .{},
    open_main_rect: palette.Rect = .{},
    chevron_rect: palette.Rect = .{},
    browser_rect: palette.Rect = .{},
    menu_panel_rect: palette.Rect = .{},
    menu_row_count: usize = 0,
    menu_row_rects: [5]palette.Rect = [_]palette.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 5,
    menu_row_kind: [5]WorkspaceHeaderOpenMenuRow = [_]WorkspaceHeaderOpenMenuRow{.folder} ** 5,
    menu_row_enabled: [5]bool = [_]bool{false} ** 5,
};

var workspace_header_hits: WorkspaceHeaderHitCache = .{};

pub fn renderWorkspace(state: *app_state.AppState, width: f32, height: f32) void {
    renderWorkspaceAt(state, .{ .x = estimateWorkspaceOriginX(state, width), .y = 0.0, .w = width, .h = height });
}

pub fn renderWorkspaceAt(state: *app_state.AppState, rect: palette.Rect) void {
    state.invalidateComposerToolbarOverlayHitRects();
    queueRect(state, rect, paletteColor(colors.CHAT_BLACK));
    if (state.projects.items.len == 0) {
        state.workspace_header_open_menu_open = false;
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

pub fn handleWorkspaceHeaderPaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) return false;
    if (state.projects.items.len == 0) return false;

    if (state.workspace_header_open_menu_open and rectContains(workspace_header_hits.menu_panel_rect, x, y)) {
        var i: usize = 0;
        while (i < workspace_header_hits.menu_row_count) : (i += 1) {
            if (!rectContains(workspace_header_hits.menu_row_rects[i], x, y)) continue;
            state.workspace_header_open_menu_open = false;
            state.blurPaletteComposer();
            if (!workspace_header_hits.menu_row_enabled[i]) {
                runtime.log.info(
                    "workspace header open menu row hit (disabled) kind={s} x={d:.1} y={d:.1}",
                    .{ @tagName(workspace_header_hits.menu_row_kind[i]), x, y },
                );
                return true;
            }
            runtime.log.info(
                "workspace header open menu row kind={s} x={d:.1} y={d:.1}",
                .{ @tagName(workspace_header_hits.menu_row_kind[i]), x, y },
            );
            switch (workspace_header_hits.menu_row_kind[i]) {
                .folder => state.openCurrentProjectDirectory(),
                .configured_editor => state.openCurrentProjectEditor(.configured),
                .cursor => state.openCurrentProjectEditor(.cursor),
                .vscode => state.openCurrentProjectEditor(.vscode),
                .zed => state.openCurrentProjectEditor(.zed),
            }
            state.noteInteraction();
            return true;
        }
        state.workspace_header_open_menu_open = false;
        state.blurPaletteComposer();
        runtime.log.info("workspace header open menu panel hit (no row) x={d:.1} y={d:.1}", .{ x, y });
        return true;
    }

    if (rectContains(workspace_header_hits.open_main_rect, x, y)) {
        state.workspace_header_open_menu_open = false;
        state.blurPaletteComposer();
        const can = state.canRunDefaultOpenAction();
        runtime.log.info(
            "workspace header default Open click x={d:.1} y={d:.1} can_run={}",
            .{ x, y, can },
        );
        if (can) {
            state.runDefaultOpenAction();
        } else {
            state.setSidebarNotice(state.defaultOpenTooltip());
        }
        state.noteInteraction();
        return true;
    }
    if (rectContains(workspace_header_hits.chevron_rect, x, y)) {
        state.workspace_header_open_menu_open = !state.workspace_header_open_menu_open;
        state.blurPaletteComposer();
        runtime.log.info(
            "workspace header chevron click menu_open={} x={d:.1} y={d:.1}",
            .{ state.workspace_header_open_menu_open, x, y },
        );
        state.noteInteraction();
        return true;
    }
    if (rectContains(workspace_header_hits.browser_rect, x, y)) {
        state.workspace_header_open_menu_open = false;
        state.blurPaletteComposer();
        state.toggleBrowser();
        state.noteInteraction();
        return true;
    }

    if (state.workspace_header_open_menu_open) {
        state.workspace_header_open_menu_open = false;
        runtime.log.info("workspace header dismissed open menu (click outside controls) x={d:.1} y={d:.1}", .{ x, y });
    }
    return false;
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
    const current = state.currentTranscriptScrollY() orelse state.transcript_palette_scroll_y;
    const delta = -wheel_y * theme.scaledUi(TRANSCRIPT_WHEEL_PIXELS);
    state.rememberCurrentTranscriptScroll(@max(0.0, current + delta));
    state.transcript_auto_follow_pending = false;
    state.scroll_transcript_to_bottom_frames = 0;
    state.markDirty();
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

fn truncateWorkspaceTitle(buf: []u8, title: []const u8, max_width: f32, font_size: f32) []const u8 {
    const gw = font_size * 0.52;
    if (max_width <= 0.0 or buf.len == 0) return "";
    var total: f32 = 0;
    var i: usize = 0;
    while (i < title.len) {
        const seq = std.unicode.utf8ByteSequenceLength(title[i]) catch return title;
        const end = @min(i + seq, title.len);
        total += gw * @max(1.0, @as(f32, @floatFromInt(end - i)));
        i = end;
    }
    if (total <= max_width) {
        const n = @min(title.len, buf.len);
        @memcpy(buf[0..n], title[0..n]);
        return buf[0..n];
    }
    const ellipsis = "...";
    const ellipsis_w = @as(f32, @floatFromInt(ellipsis.len)) * gw;
    if (ellipsis_w > max_width) return "";
    i = 0;
    total = 0;
    while (i < title.len) {
        const seq = std.unicode.utf8ByteSequenceLength(title[i]) catch break;
        const end = @min(i + seq, title.len);
        const adv = gw * @max(1.0, @as(f32, @floatFromInt(end - i)));
        if (total + adv + ellipsis_w > max_width) break;
        total += adv;
        i = end;
    }
    const prefix_len = i;
    if (prefix_len + ellipsis.len > buf.len) return title;
    @memcpy(buf[0..prefix_len], title[0..prefix_len]);
    @memcpy(buf[prefix_len..][0..ellipsis.len], ellipsis);
    return buf[0 .. prefix_len + ellipsis.len];
}

fn queueWorkspaceHeaderFolderIcon(state: *app_state.AppState, x: f32, center_y: f32, color: palette.Color) void {
    const col = color;
    const fw = theme.scaledUi(13.0);
    const fh = theme.scaledUi(9.0);
    queueRounded(state, .{
        .x = x,
        .y = center_y - fh * 0.5 - theme.scaledUi(2.0),
        .w = fw * 0.4,
        .h = theme.scaledUi(3.0),
    }, col, theme.scaledUi(1.0));
    queueRounded(state, .{
        .x = x,
        .y = center_y - fh * 0.5,
        .w = fw,
        .h = fh,
    }, col, theme.scaledUi(1.5));
}

fn queueWorkspaceHeaderChevron(state: *app_state.AppState, cx: f32, cy: f32, color: palette.Color) void {
    const half = theme.scaledUi(4.0);
    queueTriangle(
        state,
        .{ .x = cx - half, .y = cy - half },
        .{ .x = cx, .y = cy },
        .{ .x = cx - half, .y = cy + half },
        color,
    );
}

fn queueWorkspaceHeaderGlobe(state: *app_state.AppState, cx: f32, cy: f32, size: f32, color: palette.Color) void {
    const r = size * 0.5;
    const sq = palette.Rect{ .x = cx - r, .y = cy - r, .w = size, .h = size };
    const stroke = @max(theme.scaledUi(1.05), size * 0.078);
    queueBorder(state, sq, color, r, stroke);

    const eq_w = size - stroke * 1.8;
    queueRect(state, .{
        .x = cx - eq_w * 0.5,
        .y = cy - stroke * 0.5,
        .w = eq_w,
        .h = stroke,
    }, color);

    queueGlobeMeridianArc(state, cx, cy, r, stroke, color, -1.0);
    queueGlobeMeridianArc(state, cx, cy, r, stroke, color, 1.0);
}

fn queueGlobeMeridianArc(
    state: *app_state.AppState,
    cx: f32,
    cy: f32,
    r: f32,
    stroke: f32,
    color: palette.Color,
    sign: f32,
) void {
    const bulge = 0.47;
    const N: usize = 17;
    var i: usize = 0;
    while (i + 1 < N) : (i += 1) {
        const t0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N - 1));
        const t1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(N - 1));
        const y0 = cy - r + t0 * (2 * r);
        const y1 = cy - r + t1 * (2 * r);
        const ym = (y0 + y1) * 0.5;
        const dy = ym - cy;
        const chord_sq = r * r - dy * dy;
        if (chord_sq <= 0) continue;
        const chord = @sqrt(chord_sq);
        const x = cx + sign * chord * bulge;
        const seg_h = y1 - y0;
        if (seg_h <= 0) continue;
        queueRect(state, .{
            .x = x - stroke * 0.5,
            .y = y0,
            .w = stroke,
            .h = seg_h,
        }, color);
    }
}

fn renderHeader(state: *app_state.AppState, rect: palette.Rect) void {
    workspace_header_hits = .{};
    workspace_header_hits.header_rect = rect;

    queueRect(state, rect, paletteColor(colors.CHAT_BLACK));
    queueRect(state, .{ .x = rect.x, .y = rect.y + rect.h - 1.0, .w = rect.w, .h = 1.0 }, paletteColor(colors.DARK_BLUE));

    const padding_x = theme.scaledUi(28.0);
    const thread = state.currentThread();
    const title_src: []const u8 = if (thread.committed)
        if (thread.title.len > 0) thread.title else "New chat"
    else
        "New chat";

    const button_h = theme.scaledUi(30.0);
    const button_gap = theme.scaledUi(8.0);
    const title_gap = theme.scaledUi(16.0);
    const label_font = theme.scaledUi(14.0);
    const title_font = theme.scaledUi(18.0);

    const open_label = state.defaultOpenButtonLabel();
    const open_folder = state.defaultOpenShowsFolderIcon();
    const open_tex = state.defaultOpenIconTexture();
    const open_has_icon = open_folder or open_tex != null;
    const label_w = @as(f32, @floatFromInt(open_label.len)) * label_font * 0.52;
    const open_main_w = theme.clampf(
        label_w + theme.scaledUi(if (open_has_icon) 54.0 else 28.0),
        theme.scaledUi(82.0),
        theme.scaledUi(184.0),
    );
    const chevron_w = theme.scaledUi(30.0);
    const browser_w = theme.scaledUi(106.0);
    const open_combo_w = open_main_w + chevron_w;
    const actions_w = open_combo_w + button_gap + browser_w;

    const header_inner_w = rect.w - padding_x * 2.0;
    const actions_x = rect.x + padding_x + @max(theme.scaledUi(180.0), header_inner_w - actions_w);
    const title_max_w = @max(actions_x - rect.x - padding_x - title_gap, theme.scaledUi(96.0));

    var title_buf: [256]u8 = undefined;
    const title_display = truncateWorkspaceTitle(&title_buf, title_src, title_max_w, title_font);
    const title_line_h = theme.scaledUi(32.0);
    const title_y = rect.y + @max((rect.h - title_line_h) * 0.5, theme.scaledUi(4.0));
    queueText(state, .{
        .x = rect.x + padding_x,
        .y = title_y,
        .w = title_max_w,
        .h = title_line_h,
    }, stableText(state, title_display), paletteColor(theme.COLOR_WHITE), title_font, rect);

    const mx = state.palette_mouse_x;
    const my = state.palette_mouse_y;
    const mouse_ok = state.palette_mouse_in_workspace;

    const actions_y = rect.y + @max((rect.h - button_h) * 0.5, theme.scaledUi(4.0));
    const open_combo_x = actions_x;
    const open_main_rect = palette.Rect{ .x = open_combo_x, .y = actions_y, .w = open_main_w, .h = button_h };
    const chevron_rect = palette.Rect{ .x = open_combo_x + open_main_w, .y = actions_y, .w = chevron_w, .h = button_h };
    const browser_rect = palette.Rect{ .x = open_combo_x + open_combo_w + button_gap, .y = actions_y, .w = browser_w, .h = button_h };

    workspace_header_hits.open_main_rect = open_main_rect;
    workspace_header_hits.chevron_rect = chevron_rect;
    workspace_header_hits.browser_rect = browser_rect;

    const open_main_hover = mouse_ok and rectContains(open_main_rect, mx, my);
    const chevron_hover = mouse_ok and rectContains(chevron_rect, mx, my);
    const combo_hover = open_main_hover or chevron_hover;
    const browser_hover = mouse_ok and rectContains(browser_rect, mx, my);

    const combo_base = theme.COLOR_PANEL_ALT;
    const combo_bg = if (combo_hover) theme.lighten(combo_base, 0.08) else combo_base;
    const open_combo_rect = palette.Rect{ .x = open_combo_x, .y = actions_y, .w = open_combo_w, .h = button_h };
    const combo_radius = theme.scaledUi(10.0);
    queueRounded(state, open_combo_rect, paletteColor(combo_bg), combo_radius);

    const sep_col = colors.rgba(22, 24, 28, 110);
    queueRect(state, .{
        .x = chevron_rect.x,
        .y = chevron_rect.y + theme.scaledUi(5.0),
        .w = 1.0,
        .h = button_h - theme.scaledUi(10.0),
    }, paletteColor(sep_col));

    const icon_slot = theme.scaledUi(16.0);
    const icon_x = open_main_rect.x + theme.scaledUi(14.0);
    const icon_cy = open_main_rect.y + button_h * 0.5;
    const text_color_open: palette.Color = paletteColor(if (!state.canRunDefaultOpenAction())
        theme.COLOR_TEXT_MUTED
    else if (combo_hover)
        theme.COLOR_WHITE
    else
        theme.COLOR_TEXT_MUTED);
    if (open_folder) {
        queueWorkspaceHeaderFolderIcon(state, icon_x, icon_cy, text_color_open);
    } else if (open_tex) |cached| {
        const scaled = runtime.scaledImageSize(cached.width, cached.height, icon_slot, icon_slot);
        queueImage(state, .{
            .x = icon_x + (icon_slot - scaled[0]) * 0.5,
            .y = open_main_rect.y + (button_h - scaled[1]) * 0.5,
            .w = scaled[0],
            .h = scaled[1],
        }, cached, rect);
    }
    const text_x = if (open_has_icon)
        icon_x + icon_slot + theme.scaledUi(10.0)
    else
        open_main_rect.x + theme.scaledUi(14.0);
    queueFixedTextLine(state, .{
        .x = text_x,
        .y = open_main_rect.y + (button_h - label_font * 1.25) * 0.5,
        .w = open_main_w - (text_x - open_main_rect.x) - theme.scaledUi(8.0),
        .h = label_font * 1.25,
    }, stableText(state, open_label), text_color_open, label_font, rect);

    const chev_cx = chevron_rect.x + chevron_rect.w * 0.5 + theme.scaledUi(2.0);
    const chev_cy = chevron_rect.y + chevron_rect.h * 0.5;
    queueWorkspaceHeaderChevron(
        state,
        chev_cx,
        chev_cy,
        paletteColor(if (chevron_hover) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE),
    );

    const browser_base = theme.COLOR_PANEL_ALT;
    const browser_bg = if (browser_hover) theme.lighten(browser_base, 0.08) else browser_base;
    const browser_radius = theme.scaledUi(6.0);
    queueRounded(state, browser_rect, paletteColor(browser_bg), browser_radius);
    queueBorder(state, browser_rect, paletteColor(theme.lighten(browser_bg, 0.06)), browser_radius, theme.scaledUi(1.0));

    const browser_label = "Browser";
    const globe_size = theme.scaledUi(14.0);
    const icon_gap = theme.scaledUi(5.0);
    const browser_text_w = @as(f32, @floatFromInt(browser_label.len)) * label_font * 0.52;
    const browser_content_w = globe_size + icon_gap + browser_text_w;
    const browser_start_x = browser_rect.x + (browser_rect.w - browser_content_w) * 0.5;
    const browser_cy = browser_rect.y + browser_rect.h * 0.5;
    queueWorkspaceHeaderGlobe(state, browser_start_x + globe_size * 0.5, browser_cy, globe_size, paletteColor(theme.COLOR_TEXT_MUTED));
    queueFixedTextLine(state, .{
        .x = browser_start_x + globe_size + icon_gap,
        .y = browser_rect.y + (browser_rect.h - label_font * 1.25) * 0.5,
        .w = browser_text_w + theme.scaledUi(4.0),
        .h = label_font * 1.25,
    }, stableText(state, browser_label), paletteColor(theme.COLOR_WHITE), label_font, rect);

    if (!state.workspace_header_open_menu_open) return;

    var kinds: [5]WorkspaceHeaderOpenMenuRow = undefined;
    var enabled: [5]bool = undefined;
    var label_storage: [5][96]u8 = undefined;
    var labels: [5][]const u8 = undefined;
    var count: usize = 0;

    kinds[count] = .folder;
    enabled[count] = state.canOpenCurrentProjectDirectory();
    labels[count] = "Open folder";
    count += 1;

    if (state.canOpenCurrentProjectEditor(.configured)) {
        kinds[count] = .configured_editor;
        enabled[count] = true;
        labels[count] = if (state.configuredEditorDisplayName()) |name|
            std.fmt.bufPrint(&label_storage[count], "Open in {s}", .{name}) catch "Open in configured editor"
        else
            "Open in configured editor";
        count += 1;
    }
    if (state.canOpenCurrentProjectEditor(.cursor)) {
        kinds[count] = .cursor;
        enabled[count] = true;
        labels[count] = "Open in Cursor";
        count += 1;
    }
    if (state.canOpenCurrentProjectEditor(.vscode)) {
        kinds[count] = .vscode;
        enabled[count] = true;
        labels[count] = "Open in VS Code";
        count += 1;
    }
    if (state.canOpenCurrentProjectEditor(.zed)) {
        kinds[count] = .zed;
        enabled[count] = true;
        labels[count] = "Open in Zed";
        count += 1;
    }

    const menu_w = theme.scaledUi(250.0);
    const menu_pad = theme.scaledUi(8.0);
    const menu_row_h = theme.scaledUi(34.0);
    const menu_h = menu_pad * 2.0 + @as(f32, @floatFromInt(count)) * menu_row_h;
    const menu_x = @max(rect.x + theme.scaledUi(12.0), chevron_rect.x + chevron_rect.w - menu_w);
    const menu_y = chevron_rect.y + chevron_rect.h + theme.scaledUi(6.0);
    workspace_header_hits.menu_panel_rect = .{ .x = menu_x, .y = menu_y, .w = menu_w, .h = menu_h };

    const menu_clip = workspace_header_hits.menu_panel_rect;
    queueRounded(state, workspace_header_hits.menu_panel_rect, paletteColor(colors.rgba(26, 28, 34, 255)), theme.scaledUi(12.0));
    queueBorder(state, workspace_header_hits.menu_panel_rect, paletteColor(colors.rgba(66, 68, 78, 255)), theme.scaledUi(12.0), theme.scaledUi(1.0));

    workspace_header_hits.menu_row_count = count;
    var ri: usize = 0;
    var ry = menu_y + menu_pad;
    while (ri < count) : (ri += 1) {
        workspace_header_hits.menu_row_kind[ri] = kinds[ri];
        workspace_header_hits.menu_row_enabled[ri] = enabled[ri];

        const rr = palette.Rect{
            .x = menu_x + theme.scaledUi(4.0),
            .y = ry,
            .w = menu_w - theme.scaledUi(8.0),
            .h = menu_row_h,
        };
        workspace_header_hits.menu_row_rects[ri] = rr;

        const row_hover = mouse_ok and enabled[ri] and rectContains(rr, mx, my);
        if (row_hover) {
            queueRounded(state, rr, paletteColor(colors.rgba(42, 44, 52, 255)), theme.scaledUi(8.0));
        }

        const row_icon_x = rr.x + theme.scaledUi(12.0);
        const row_icon_cy = rr.y + menu_row_h * 0.5;
        const row_text_x = row_icon_x + theme.scaledUi(18.0) + theme.scaledUi(10.0);
        const row_col = paletteColor(if (!enabled[ri])
            theme.COLOR_TEXT_SUBTLE
        else if (row_hover)
            theme.COLOR_WHITE
        else
            theme.COLOR_TEXT_MUTED);

        switch (kinds[ri]) {
            .folder => queueWorkspaceHeaderFolderIcon(state, row_icon_x, row_icon_cy, row_col),
            .configured_editor => {
                if (state.editorLogoTextureForTarget(.configured)) |cached| {
                    const scaled = runtime.scaledImageSize(cached.width, cached.height, theme.scaledUi(18.0), theme.scaledUi(18.0));
                    queueImage(state, .{
                        .x = row_icon_x + (theme.scaledUi(18.0) - scaled[0]) * 0.5,
                        .y = rr.y + (menu_row_h - scaled[1]) * 0.5,
                        .w = scaled[0],
                        .h = scaled[1],
                    }, cached, menu_clip);
                }
            },
            .cursor => {
                if (state.editorLogoTextureForTarget(.cursor)) |cached| {
                    const scaled = runtime.scaledImageSize(cached.width, cached.height, theme.scaledUi(18.0), theme.scaledUi(18.0));
                    queueImage(state, .{
                        .x = row_icon_x + (theme.scaledUi(18.0) - scaled[0]) * 0.5,
                        .y = rr.y + (menu_row_h - scaled[1]) * 0.5,
                        .w = scaled[0],
                        .h = scaled[1],
                    }, cached, menu_clip);
                }
            },
            .vscode => {
                if (state.editorLogoTextureForTarget(.vscode)) |cached| {
                    const scaled = runtime.scaledImageSize(cached.width, cached.height, theme.scaledUi(18.0), theme.scaledUi(18.0));
                    queueImage(state, .{
                        .x = row_icon_x + (theme.scaledUi(18.0) - scaled[0]) * 0.5,
                        .y = rr.y + (menu_row_h - scaled[1]) * 0.5,
                        .w = scaled[0],
                        .h = scaled[1],
                    }, cached, menu_clip);
                }
            },
            .zed => {
                if (state.editorLogoTextureForTarget(.zed)) |cached| {
                    const scaled = runtime.scaledImageSize(cached.width, cached.height, theme.scaledUi(18.0), theme.scaledUi(18.0));
                    queueImage(state, .{
                        .x = row_icon_x + (theme.scaledUi(18.0) - scaled[0]) * 0.5,
                        .y = rr.y + (menu_row_h - scaled[1]) * 0.5,
                        .w = scaled[0],
                        .h = scaled[1],
                    }, cached, menu_clip);
                }
            },
        }

        queueFixedTextLine(state, .{
            .x = row_text_x,
            .y = rr.y + (menu_row_h - label_font * 1.25) * 0.5,
            .w = rr.w - (row_text_x - rr.x) - theme.scaledUi(8.0),
            .h = label_font * 1.25,
        }, stableText(state, labels[ri]), row_col, label_font, menu_clip);

        ry += menu_row_h;
    }
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

    const pi = state.selected_project_index;
    const ti = state.currentProject().selected_thread_index;
    if (state.transcript_scroll_pending_track_p != pi or state.transcript_scroll_pending_track_t != ti) {
        state.pending_transcript_scroll_px = 0;
        state.pending_transcript_page_steps = 0;
        state.transcript_scroll_pending_track_p = pi;
        state.transcript_scroll_pending_track_t = ti;
    }

    if (state.pending_transcript_scroll_px != 0.0) {
        scroll_y = std.math.clamp(scroll_y + state.pending_transcript_scroll_px, 0.0, max_scroll);
        state.pending_transcript_scroll_px = 0.0;
    }
    if (state.pending_transcript_page_steps != 0) {
        const page_h = column.h * TRANSCRIPT_PAGE_VIEW_FRAC;
        scroll_y = std.math.clamp(scroll_y + @as(f32, @floatFromInt(state.pending_transcript_page_steps)) * page_h, 0.0, max_scroll);
        state.pending_transcript_page_steps = 0;
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
