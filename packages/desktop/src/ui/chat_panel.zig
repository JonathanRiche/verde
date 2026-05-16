//! Palette-only chat workspace rendering.

const std = @import("std");
const palette = @import("palette");

const app_state = @import("../state.zig");
const profiler = @import("../profiler.zig");
const utils = @import("../utils.zig");
const browser_panel = @import("browser.zig");
const chat_markdown = @import("chat_markdown.zig");
const colors = @import("colors.zig");
const composer_pickers = @import("composer_pickers.zig");
const file_icons = @import("file_icons.zig");
const runtime = @import("runtime.zig");
const terminal_panel = @import("terminal_panel.zig");
const theme = @import("theme.zig");

const TOP_BAR_HEIGHT: f32 = 57.0; // ~70% of legacy 82px cap
const COMPOSER_HEIGHT: f32 = 220.0;
/// Toolbar logos and drawn icons must sit above `PaletteComposerPrompt` geometry (`z_index` 120) so
/// interleaved SDL_GPU rendering does not paint the composer panel over them.
const COMPOSER_TOOLBAR_OVERLAY_Z: i32 = 130;
/// Hint text in the draft area; above composer content (z 120) but below toolbar chrome (130).
const COMPOSER_FOLLOWUP_HINT_Z: i32 = 128;
/// Draft attachment previews sit above the composer card when they overlap the dock.
const COMPOSER_DRAFT_IMAGE_Z: i32 = 125;
/// File mention search must sit above composer chrome and toolbar menus.
const COMPOSER_FILE_SEARCH_Z: i32 = 150;
/// Must match `PaletteComposerPrompt` `pill_padding_x` in `state.zig` so toolbar glyphs align with label insets.
const COMPOSER_TOOLBAR_PILL_PAD_X: f32 = 13.0;
/// Provider logo slot in the model pill.
const COMPOSER_PROVIDER_LOGO_SLOT_CSS: f32 = 26.0;
const TRANSCRIPT_MAX_WIDTH: f32 = 900.0;
const TRANSCRIPT_LINE_HEIGHT: f32 = 22.0;
/// Direct wheel scroll (no inertia); larger than legacy 64 for faster scanning.
const TRANSCRIPT_WHEEL_PIXELS: f32 = 96.0;
const TRANSCRIPT_PAGE_VIEW_FRAC: f32 = 0.88;

var transcript_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var transcript_pane_id: ?app_state.WorkspacePaneId = null;

const MAX_TRANSCRIPT_HITS = 16;
const TranscriptHit = struct {
    pane_id: ?app_state.WorkspacePaneId = null,
    rect: palette.Rect = .{},
    track: palette.Rect = .{},
    thumb: palette.Rect = .{},
    max_scroll: f32 = 0.0,
};

var transcript_hit_count: usize = 0;
var transcript_hits: [MAX_TRANSCRIPT_HITS]TranscriptHit = [_]TranscriptHit{.{}} ** MAX_TRANSCRIPT_HITS;

/// Geometry of the transcript scrollbar from the last paint. Captured during
/// render so the mouse handlers can do hit-testing without rebuilding the
/// layout themselves. `track` is empty when the column is short enough that
/// no scrollbar is shown.
var transcript_scrollbar_track: palette.Rect = .{};
var transcript_scrollbar_thumb: palette.Rect = .{};
var transcript_scrollbar_max_scroll: f32 = 0.0;
/// Distance from the thumb's top edge to the click point at drag start; held
/// constant while dragging so the thumb tracks the cursor without jumping.
var transcript_scrollbar_drag_grab_offset: f32 = 0.0;
var transcript_scrollbar_drag_active: bool = false;
var transcript_scrollbar_drag_pane_id: ?app_state.WorkspacePaneId = null;

const FileSearchHitCache = struct {
    panel_rect: palette.Rect = .{},
    row_count: usize = 0,
    row_rects: [8]palette.Rect = [_]palette.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 8,
    row_indices: [8]usize = [_]usize{0} ** 8,
};

var file_search_hits: FileSearchHitCache = .{};

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

pub fn resetTranscriptHitCache() void {
    transcript_hit_count = 0;
}

pub fn renderWorkspaceAt(state: *app_state.AppState, rect: palette.Rect) void {
    renderWorkspaceAtForPane(state, rect, null);
}

pub fn paneHeaderHeight(rect: palette.Rect) f32 {
    return theme.clampf(rect.h * 0.098, theme.scaledUi(38.0), theme.scaledUi(TOP_BAR_HEIGHT));
}

pub fn renderWorkspaceAtForPane(state: *app_state.AppState, rect: palette.Rect, pane_id: ?app_state.WorkspacePaneId) void {
    renderWorkspaceAtForPaneWithReserve(state, rect, pane_id, 0.0);
}

pub fn renderWorkspaceAtForPaneWithReserve(state: *app_state.AppState, rect: palette.Rect, pane_id: ?app_state.WorkspacePaneId, header_right_reserve: f32) void {
    const restore_thread_index = if (pane_id != null and state.projects.items.len > 0)
        state.projects.items[state.selected_project_index].selected_thread_index
    else
        null;
    if (pane_id) |id| {
        if (state.workspaceChatThreadIndexByPane(id)) |thread_index| {
            state.projects.items[state.selected_project_index].selected_thread_index = thread_index;
        }
    }
    defer {
        if (restore_thread_index) |thread_index| {
            if (state.projects.items.len > 0 and thread_index < state.projects.items[state.selected_project_index].threads.items.len) {
                state.projects.items[state.selected_project_index].selected_thread_index = thread_index;
            }
        }
    }

    state.invalidateComposerToolbarOverlayHitRects();
    file_search_hits = .{};
    if (pane_id == null) transcript_hit_count = 0;
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
    const terminal_visible = state.shouldRenderLegacyTerminalDockInChat() and !state.isBrowserVisible();
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
    const process_strip_height = if (pane_id == null and state.currentProject().managed_processes.items.len > 0)
        theme.scaledUi(52.0)
    else
        0.0;
    const transcript_body = if (process_strip_height > 0.0) palette.Rect{
        .x = body.x,
        .y = body.y + process_strip_height,
        .w = body.w,
        .h = @max(body.h - process_strip_height, theme.scaledUi(96.0)),
    } else body;

    const split_chat_browser = state.isBrowserVisible() and transcript_body.w >= theme.scaledUi(900.0);
    const browser_width = if (split_chat_browser) state.browserPanelWidth(transcript_body.w) else 0.0;
    const composer_lane_w = if (split_chat_browser) transcript_body.w - browser_width else transcript_body.w;
    const composer_lane_x = transcript_body.x;

    const composer_width = @max(theme.scaledUi(220.0), @min(composer_lane_w - side_margin * 2.0, theme.scaledUi(980.0)));
    const composer_rect = palette.Rect{
        .x = composer_lane_x + (composer_lane_w - composer_width) * 0.5,
        .y = composer_y,
        .w = composer_width,
        .h = composer_height,
    };

    if (split_chat_browser) {
        const chat_rect = palette.Rect{ .x = transcript_body.x, .y = transcript_body.y, .w = transcript_body.w - browser_width, .h = transcript_body.h };
        renderTranscript(state, chat_rect, pane_id);
        // Transcript uses only `body` (above composer). The browser column is empty to the right of the
        // composer, so extend the dock through that strip to the same bottom as the composer row.
        const browser_dock_h = composer_bottom - transcript_body.y;
        browser_panel.renderDockAt(state, .{
            .x = chat_rect.x + chat_rect.w,
            .y = transcript_body.y,
            .w = browser_width,
            .h = @max(browser_dock_h, theme.scaledUi(120.0)),
        });
    } else {
        renderTranscript(state, transcript_body, pane_id);
    }

    if (process_strip_height > 0.0) {
        renderProcessDashboard(state, .{
            .x = body.x + side_margin,
            .y = body.y + theme.scaledUi(6.0),
            .w = @max(body.w - side_margin * 2.0, theme.scaledUi(220.0)),
            .h = process_strip_height - theme.scaledUi(10.0),
        });
    }

    // Paint after the transcript so the opaque header strip wins over any scrolled
    // message geometry or GL text that would otherwise overlap the title bar.
    renderHeader(state, header, header_right_reserve);

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

pub fn handleFileSearchPaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) return false;
    if (!state.hasActiveFileSearch()) return false;
    if (file_search_hits.row_count == 0) return false;
    if (!rectContains(file_search_hits.panel_rect, x, y)) return false;

    var index: usize = 0;
    while (index < file_search_hits.row_count) : (index += 1) {
        if (rectContains(file_search_hits.row_rects[index], x, y)) {
            _ = state.selectFileSearchResult(file_search_hits.row_indices[index]);
            return true;
        }
    }
    return true;
}

pub fn handleComposerFileSearchMouseButton(state: *app_state.AppState, x: f32, y: f32, button: u8, down: bool) bool {
    if (button != 1) return false;
    return handleFileSearchPaletteMouseButton(state, x, y, down);
}

/// True when `(x, y)` lies inside the transcript pane last painted by `renderTranscript`.
pub fn pointerOverTranscript(x: f32, y: f32) bool {
    return findTranscriptHit(x, y) != null;
}

pub fn handleTranscriptPaletteWheel(state: *app_state.AppState, x: f32, y: f32, wheel_y: f32) bool {
    if (wheel_y == 0.0) return false;
    const hit = findTranscriptHit(x, y) orelse return false;
    const pane_id = hit.pane_id;
    if (pane_id) |id| _ = state.focusCurrentProjectWorkspacePane(id);
    state.transcript_focused = true;
    const current = currentTranscriptScrollY(state, pane_id) orelse state.transcript_palette_scroll_y;
    const delta = -wheel_y * theme.scaledUi(TRANSCRIPT_WHEEL_PIXELS);
    rememberTranscriptScroll(state, pane_id, snapTranscriptScrollY(current + delta, null));
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
        const item_h = transcriptCommittedMessageHeight(state, msg_idx, message, column.w);
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
        const item_h = transcriptMessageHeight(null, null, event.body, event.role, column.w, event.author, false);
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
    const assistant_h = transcriptMessageHeightStream(null, null, body, .assistant, column.w, "", stream_plain, stream_text.len > 0);
    const stream_idx = base_idx + send_state.pending_events.items.len;
    return assistantTranscriptMarkdownHit(state, column, content_y, assistant_h, .assistant, body, stream_text.len == 0, stream_plain, stream_idx, mouse_x, mouse_y);
}

pub fn handleTranscriptPaletteMouseMotion(state: *app_state.AppState) void {
    if (transcript_scrollbar_drag_active and transcript_scrollbar_max_scroll > 1.0 and transcript_scrollbar_track.h > 0.0) {
        const pane_id = transcript_scrollbar_drag_pane_id;
        const target = scrollFromThumbY(
            transcript_scrollbar_track,
            transcript_scrollbar_thumb.h,
            transcript_scrollbar_max_scroll,
            state.palette_mouse_y,
            transcript_scrollbar_drag_grab_offset,
        );
        rememberTranscriptScroll(state, pane_id, snapTranscriptScrollY(target, transcript_scrollbar_max_scroll));
        state.transcript_auto_follow_pending = false;
        state.scroll_transcript_to_bottom_frames = 0;
        state.markDirty();
        return;
    }
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
        if (transcript_scrollbar_drag_active) {
            transcript_scrollbar_drag_active = false;
            transcript_scrollbar_drag_pane_id = null;
        }
        if (state.transcriptMarkdownSelectionDragging()) {
            state.endTranscriptMarkdownSelection();
        }
        return false;
    }

    const hit = findTranscriptHit(x, y) orelse return false;
    const pane_id = hit.pane_id;
    if (pane_id) |id| _ = state.focusCurrentProjectWorkspacePane(id);

    state.transcript_focused = true;

    // Scrollbar drag: thumb click starts a drag; track click (above/below
    // thumb) page-jumps toward the cursor by one viewport.
    if (hit.max_scroll > 1.0 and hit.track.h > 0.0) {
        const track_hit = expandedScrollbarHit(hit.track);
        if (rectContains(track_hit, x, y)) {
            if (rectContains(expandedScrollbarHit(hit.thumb), x, y)) {
                transcript_scrollbar_drag_active = true;
                transcript_scrollbar_drag_pane_id = pane_id;
                transcript_scrollbar_drag_grab_offset = y - hit.thumb.y;
                transcript_scrollbar_track = hit.track;
                transcript_scrollbar_thumb = hit.thumb;
                transcript_scrollbar_max_scroll = hit.max_scroll;
            } else {
                const target = scrollFromThumbY(
                    hit.track,
                    hit.thumb.h,
                    hit.max_scroll,
                    y,
                    hit.thumb.h * 0.5,
                );
                rememberTranscriptScroll(state, pane_id, snapTranscriptScrollY(target, hit.max_scroll));
                state.transcript_auto_follow_pending = false;
                state.scroll_transcript_to_bottom_frames = 0;
                state.markDirty();
            }
            return true;
        }
    }

    if (clicks <= 1 and state.consumeCodeCopyButtonClick(x, y)) {
        return true;
    }
    if (clicks <= 1 and state.consumeCardToggleClick(x, y)) {
        return true;
    }
    if (transcriptMarkdownBubbleHit(state, x, y)) |markdown_hit| {
        state.blurPaletteComposer();
        if (clicks >= 2) {
            applyTranscriptMarkdownMulticlick(state, markdown_hit, @intCast(clicks));
        } else {
            state.beginTranscriptMarkdownSelection(markdown_hit.message_index, markdown_hit.point);
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
        var scratch_text_arena = std.heap.ArenaAllocator.init(state.allocator);
        defer scratch_text_arena.deinit();

        var ctx = chat_markdown.PaletteRenderContext{
            .allocator = state.allocator,
            .batch = &scratch_batch,
            .frame_text = &scratch_text,
            .text_arena = &scratch_text_arena,
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

fn renderHeader(state: *app_state.AppState, rect: palette.Rect, right_reserve: f32) void {
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

    const header_inner_w = rect.w - padding_x * 2.0 - right_reserve;
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
    queueChromeLabel(state, .{
        .x = text_x,
        .y = open_main_rect.y + (button_h - label_font * 1.25) * 0.5,
        .w = open_main_w - (text_x - open_main_rect.x) - theme.scaledUi(8.0),
        .h = label_font * 1.25,
    }, open_label, text_color_open, label_font, rect);

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
    queuePanel(state, browser_rect, paletteColor(browser_bg), paletteColor(theme.lighten(browser_bg, 0.06)), browser_radius, theme.scaledUi(1.0));

    const browser_label = "Browser";
    const globe_size = theme.scaledUi(14.0);
    const icon_gap = theme.scaledUi(5.0);
    const browser_text_w = @as(f32, @floatFromInt(browser_label.len)) * label_font * 0.52;
    const browser_content_w = globe_size + icon_gap + browser_text_w;
    const browser_start_x = browser_rect.x + (browser_rect.w - browser_content_w) * 0.5;
    const browser_cy = browser_rect.y + browser_rect.h * 0.5;
    queueWorkspaceHeaderGlobe(state, browser_start_x + globe_size * 0.5, browser_cy, globe_size, paletteColor(theme.COLOR_TEXT_MUTED));
    queueChromeLabel(state, .{
        .x = browser_start_x + globe_size + icon_gap,
        .y = browser_rect.y + (browser_rect.h - label_font * 1.25) * 0.5,
        .w = browser_text_w + theme.scaledUi(4.0),
        .h = label_font * 1.25,
    }, browser_label, paletteColor(theme.COLOR_WHITE), label_font, rect);

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

fn renderProcessDashboard(state: *app_state.AppState, rect: palette.Rect) void {
    if (state.projects.items.len == 0) return;
    const project = state.currentProject();
    if (project.managed_processes.items.len == 0) return;

    const clip = snapRect(rect);
    queuePanel(state, rect, paletteColor(colors.rgba(20, 28, 30, 232)), paletteColor(colors.rgba(64, 78, 84, 180)), theme.scaledUi(6.0), theme.scaledUi(1.0));
    queueChromeLabel(state, .{
        .x = rect.x + theme.scaledUi(12.0),
        .y = rect.y + theme.scaledUi(10.0),
        .w = theme.scaledUi(92.0),
        .h = theme.scaledUi(22.0),
    }, "Stack", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), clip);

    var x = rect.x + theme.scaledUi(76.0);
    const row_y = rect.y + theme.scaledUi(7.0);
    const max_items = @min(project.managed_processes.items.len, 5);
    for (project.managed_processes.items[0..max_items]) |process| {
        const item_w = theme.clampf(rect.w * 0.18, theme.scaledUi(120.0), theme.scaledUi(190.0));
        if (x + item_w > rect.x + rect.w - theme.scaledUi(8.0)) break;
        const item = palette.Rect{ .x = x, .y = row_y, .w = item_w, .h = rect.h - theme.scaledUi(14.0) };
        queueRounded(state, item, paletteColor(colors.rgba(13, 18, 19, 210)), theme.scaledUi(5.0));
        const dot = palette.Rect{ .x = item.x + theme.scaledUi(9.0), .y = item.y + theme.scaledUi(12.0), .w = theme.scaledUi(8.0), .h = theme.scaledUi(8.0) };
        queueRounded(state, dot, managedProcessStatusColor(process.status), theme.scaledUi(4.0));
        queueChromeLabel(state, .{
            .x = item.x + theme.scaledUi(24.0),
            .y = item.y + theme.scaledUi(5.0),
            .w = item.w - theme.scaledUi(30.0),
            .h = theme.scaledUi(18.0),
        }, process.name, paletteColor(theme.COLOR_WHITE), theme.scaledUi(12.0), clip);
        var detail_buffer: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buffer, "{s} · {s}", .{ @tagName(process.kind), @tagName(process.status) }) catch @tagName(process.status);
        queueChromeLabel(state, .{
            .x = item.x + theme.scaledUi(24.0),
            .y = item.y + theme.scaledUi(23.0),
            .w = item.w - theme.scaledUi(30.0),
            .h = theme.scaledUi(16.0),
        }, detail, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(11.0), clip);
        x += item_w + theme.scaledUi(8.0);
    }

    if (project.managed_processes.items.len > max_items) {
        var more_buffer: [32]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buffer, "+{d}", .{project.managed_processes.items.len - max_items}) catch "+";
        queueChromeLabel(state, .{
            .x = rect.x + rect.w - theme.scaledUi(42.0),
            .y = rect.y + theme.scaledUi(15.0),
            .w = theme.scaledUi(32.0),
            .h = theme.scaledUi(18.0),
        }, more, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), clip);
    }
}

fn managedProcessStatusColor(status: app_state.ManagedProcessStatus) palette.Color {
    return paletteColor(switch (status) {
        .running => colors.rgba(80, 200, 120, 255),
        .starting, .restarting => colors.rgba(236, 178, 70, 255),
        .crashed => colors.rgba(228, 84, 84, 255),
        .stopped => colors.rgba(125, 139, 145, 255),
    });
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

fn currentTranscriptScrollY(state: *const app_state.AppState, pane_id: ?app_state.WorkspacePaneId) ?f32 {
    if (pane_id) |id| return state.workspaceChatTranscriptScrollY(id);
    return state.currentTranscriptScrollY();
}

fn rememberTranscriptScroll(state: *app_state.AppState, pane_id: ?app_state.WorkspacePaneId, scroll_y: f32) void {
    if (pane_id) |id| {
        state.rememberWorkspaceChatTranscriptScroll(id, scroll_y);
    } else {
        state.rememberCurrentTranscriptScroll(scroll_y);
    }
}

fn findTranscriptHit(x: f32, y: f32) ?TranscriptHit {
    var i = transcript_hit_count;
    while (i > 0) {
        i -= 1;
        const hit = transcript_hits[i];
        if (rectContains(hit.rect, x, y)) return hit;
    }
    if (rectContains(transcript_rect, x, y)) {
        return .{
            .pane_id = transcript_pane_id,
            .rect = transcript_rect,
            .track = transcript_scrollbar_track,
            .thumb = transcript_scrollbar_thumb,
            .max_scroll = transcript_scrollbar_max_scroll,
        };
    }
    return null;
}

fn appendTranscriptHit(hit: TranscriptHit) void {
    if (transcript_hit_count >= transcript_hits.len) return;
    transcript_hits[transcript_hit_count] = hit;
    transcript_hit_count += 1;
}

fn renderTranscript(state: *app_state.AppState, rect: palette.Rect, pane_id: ?app_state.WorkspacePaneId) void {
    transcript_rect = rect;
    transcript_pane_id = pane_id;
    const gutter = theme.scaledUi(if (rect.w < theme.scaledUi(760.0)) 32.0 else 64.0);
    const column_width = @min(rect.w - gutter, theme.scaledUi(TRANSCRIPT_MAX_WIDTH));
    const column = snapRect(palette.Rect{ .x = rect.x + (rect.w - column_width) * 0.5, .y = rect.y + theme.scaledUi(28.0), .w = column_width, .h = @max(rect.h - theme.scaledUi(42.0), 1.0) });
    // Clip to full transcript body (same x/w as layout rect) so GL text and bubbles
    // stay below the workspace header when scrolled.
    const clip = rect;
    state.transcript_palette_column = column;
    state.transcript_palette_clip = clip;

    const thread = state.currentThread();

    if (thread.messages.items.len == 0 and !thread.isSendPendingForUi()) {
        state.transcript_palette_scroll_y = 0.0;
        rememberTranscriptScroll(state, pane_id, 0.0);
        appendTranscriptHit(.{ .pane_id = pane_id, .rect = rect });
        queueText(state, .{ .x = column.x, .y = column.y, .w = column.w, .h = theme.scaledUi(30.0) }, "No messages yet", paletteColor(theme.COLOR_WHITE), theme.scaledUi(20.0), clip);
        queueText(state, .{ .x = column.x, .y = column.y + theme.scaledUi(32.0), .w = column.w, .h = theme.scaledUi(26.0) }, "Choose a provider, type a prompt below, and start the first chat for this directory.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(15.0), clip);
        return;
    }

    const content_height = transcriptContentHeight(state, thread, column.w);
    const max_scroll = @max(0.0, content_height - column.h);
    const has_pending_stream = state.hasPendingStream();

    var scroll_y = snapTranscriptScrollY(currentTranscriptScrollY(state, pane_id) orelse max_scroll, max_scroll);

    const pi = state.selected_project_index;
    const ti = state.currentProject().selected_thread_index;
    if (state.transcript_scroll_pending_track_p != pi or state.transcript_scroll_pending_track_t != ti) {
        state.pending_transcript_scroll_px = 0;
        state.pending_transcript_page_steps = 0;
        state.transcript_scroll_pending_track_p = pi;
        state.transcript_scroll_pending_track_t = ti;
    }

    if (state.pending_transcript_scroll_px != 0.0) {
        scroll_y = snapTranscriptScrollY(scroll_y + state.pending_transcript_scroll_px, max_scroll);
        state.pending_transcript_scroll_px = 0.0;
    }
    if (state.pending_transcript_page_steps != 0) {
        const page_h = column.h * TRANSCRIPT_PAGE_VIEW_FRAC;
        scroll_y = snapTranscriptScrollY(scroll_y + @as(f32, @floatFromInt(state.pending_transcript_page_steps)) * page_h, max_scroll);
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
    rememberTranscriptScroll(state, pane_id, scroll_y);
    state.transcript_palette_scroll_y = scroll_y;

    var content_y = column.y - scroll_y;
    for (thread.messages.items, 0..) |message, msg_idx| {
        const item_h = transcriptCommittedMessageHeight(state, msg_idx, message, column.w);
        if (content_y + item_h >= column.y and content_y <= column.y + column.h) {
            renderTranscriptMessage(state, column, content_y, item_h, message, clip, msg_idx);
        }
        content_y += item_h + theme.scaledUi(12.0);
    }

    renderPendingTranscriptStream(state, thread, column, content_y, clip, thread.messages.items.len);

    if (max_scroll > 1.0) {
        const track = snapRect(palette.Rect{ .x = rect.x + rect.w - theme.scaledUi(12.0), .y = column.y, .w = theme.scaledUi(4.0), .h = column.h });
        const thumb_h = @max(theme.scaledUi(32.0), column.h * (column.h / content_height));
        const thumb_y = track.y + (track.h - thumb_h) * (scroll_y / max_scroll);
        const thumb_rect = snapRect(.{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h });
        queueRounded(state, track, paletteColor(colors.rgba(35, 42, 46, 160)), theme.scaledUi(2.0));
        queueRounded(state, thumb_rect, paletteColor(colors.rgba(145, 163, 170, 210)), theme.scaledUi(2.0));
        transcript_scrollbar_track = track;
        transcript_scrollbar_thumb = thumb_rect;
        transcript_scrollbar_max_scroll = max_scroll;
        appendTranscriptHit(.{ .pane_id = pane_id, .rect = rect, .track = track, .thumb = thumb_rect, .max_scroll = max_scroll });
    } else {
        transcript_scrollbar_track = .{};
        transcript_scrollbar_thumb = .{};
        transcript_scrollbar_max_scroll = 0.0;
        appendTranscriptHit(.{ .pane_id = pane_id, .rect = rect });
    }
}

/// Scrollbar hit-area widened by `SCROLLBAR_HIT_PADDING` CSS px on each side
/// so the thin track (4px) is comfortable to grab with a cursor.
const SCROLLBAR_HIT_PADDING_CSS: f32 = 6.0;

fn expandedScrollbarHit(rect: palette.Rect) palette.Rect {
    const pad = theme.scaledUi(SCROLLBAR_HIT_PADDING_CSS);
    return .{ .x = rect.x - pad, .y = rect.y, .w = rect.w + pad * 2.0, .h = rect.h };
}

/// Maps a y-coordinate on the scrollbar track to a scroll position. The
/// `grab_offset` argument is the distance from the thumb's top to the
/// pointer at drag start, so dragging keeps the thumb aligned with the
/// cursor instead of snapping its top to the pointer.
fn scrollFromThumbY(track: palette.Rect, thumb_h: f32, max_scroll: f32, y: f32, grab_offset: f32) f32 {
    const usable = @max(track.h - thumb_h, 1.0);
    const desired_thumb_y = std.math.clamp(y - track.y - grab_offset, 0.0, usable);
    return (desired_thumb_y / usable) * max_scroll;
}

fn snapTranscriptScrollY(value: f32, max_scroll: ?f32) f32 {
    const upper = max_scroll orelse std.math.floatMax(f32);
    return std.math.clamp(@round(@max(value, 0.0)), 0.0, upper);
}

fn transcriptContentHeight(state: *app_state.AppState, thread: anytype, width: f32) f32 {
    var total: f32 = theme.scaledUi(4.0);
    for (thread.messages.items, 0..) |message, message_index| {
        total += transcriptCommittedMessageHeight(state, message_index, message, width) + theme.scaledUi(12.0);
    }
    total += transcriptPendingStreamHeight(state, thread, width);
    return total;
}

fn transcriptPendingStreamHeight(state: *app_state.AppState, thread: *const app_state.ChatThread, column_width: f32) f32 {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return 0;

    const base = thread.messages.items.len;
    var total: f32 = 0;
    for (send_state.pending_events.items, 0..) |event, pi| {
        const msg_idx = base + pi;
        total += transcriptMessageHeight(state, msg_idx, event.body, event.role, column_width, event.author, false) + theme.scaledUi(12.0);
    }
    const stream_text: []const u8 = send_state.partial_text.items;
    const body_for_height = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const stream_plain = stream_text.len > 0;
    total += transcriptMessageHeightStream(null, null, body_for_height, .assistant, column_width, "", stream_plain, stream_text.len > 0) + theme.scaledUi(12.0);
    return total;
}

fn renderPendingTranscriptStream(state: *app_state.AppState, thread: *const app_state.ChatThread, column: palette.Rect, content_y: f32, clip: palette.Rect, base_message_index: usize) void {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return;

    var y = content_y;
    const pending_count = send_state.pending_events.items.len;
    for (send_state.pending_events.items, 0..) |event, pi| {
        const msg_idx = base_message_index + pi;
        const item_h = transcriptMessageHeight(state, msg_idx, event.body, event.role, column.w, event.author, false);
        if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body)) {
            const is_last = pi + 1 == pending_count;
            if (y + item_h >= column.y and y <= column.y + column.h) {
                renderCommandEventRow(state, column, y, item_h, event.author, event.body, clip, msg_idx, is_last);
            }
        } else if (event.role == .system and isDiffSummaryMessage(event.author, event.body)) {
            if (y + item_h >= column.y and y <= column.y + column.h) {
                renderDiffSummaryCard(state, column, y, item_h, event.body, clip, msg_idx);
            }
        } else {
            const role_label: []const u8 = switch (event.role) {
                .user => "You",
                .assistant => if (event.author.len > 0) event.author else "Assistant",
                .system => if (event.author.len > 0) event.author else "System",
            };
            if (y + item_h >= column.y and y <= column.y + column.h) {
                renderTranscriptBubbleFromParts(state, column, y, item_h, event.role, role_label, event.body, false, false, clip, msg_idx, false);
            }
        }
        y += item_h + theme.scaledUi(12.0);
    }

    var status_buf: [40]u8 = undefined;
    const working_label = formatPendingWorkingLabel(&status_buf, send_state.started_at_ms);
    const stream_text: []const u8 = send_state.partial_text.items;
    const body: []const u8 = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const stream_plain = stream_text.len > 0;
    const assistant_h = transcriptMessageHeightStream(null, null, body, .assistant, column.w, "", stream_plain, stream_text.len > 0);
    const stream_msg_idx = base_message_index + send_state.pending_events.items.len;
    if (y + assistant_h >= column.y and y <= column.y + column.h) {
        renderTranscriptBubbleFromParts(state, column, y, assistant_h, .assistant, working_label, body, stream_text.len == 0, stream_plain, clip, stream_msg_idx, stream_text.len > 0);
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

fn transcriptCommandEventHeight(
    state: ?*app_state.AppState,
    message_index: ?usize,
    body_raw: []const u8,
    column_width: f32,
) f32 {
    const pad_x = theme.scaledUi(14.0);
    const pad_y = theme.scaledUi(9.0);
    const font_size = theme.scaledUi(15.0);
    const line_h = font_size * 1.28;
    const header_h = line_h + pad_y * 2.0;

    const expanded = blk: {
        const app = state orelse break :blk false;
        const idx = message_index orelse break :blk false;
        break :blk app.isCardExpanded(commandCardKey(idx));
    };
    if (!expanded) return header_h;

    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const inner_w = @max(column_width - pad_x * 2.0, theme.scaledUi(80.0));
    const chars_per_line = @max(@as(usize, @intFromFloat(inner_w / (font_size * 0.52))), 1);
    const line_count = wrappedLineCount(body, chars_per_line);
    return header_h + @as(f32, @floatFromInt(line_count)) * line_h + pad_y;
}

fn transcriptCommittedMessageHeight(state: *app_state.AppState, message_index: usize, message: app_state.ChatMessage, column_width: f32) f32 {
    const image_present = message.image != null or message.extra_images.len > 0;
    // Command rows and diff cards have per-frame expand/collapse state that the
    // height cache key does not include — bypass the cache so toggles take
    // effect immediately.
    const has_dynamic_collapse = message.role == .system and
        (shouldRenderPaletteCommandRow(message.author, message.body) or isDiffSummaryMessage(message.author, message.body));
    if (!has_dynamic_collapse) {
        if (state.cachedTranscriptMessageHeight(message_index, column_width, message.body, message.role, message.author, false, image_present)) |height| {
            return height;
        }
    }

    var height = transcriptMessageHeight(state, message_index, message.body, message.role, column_width, message.author, false);
    height += transcriptImageBlockHeight(message, column_width);
    if (!has_dynamic_collapse) {
        state.putTranscriptMessageHeight(message_index, column_width, message.body, message.role, message.author, false, image_present, height);
    }
    return height;
}

fn transcriptImageCount(message: app_state.ChatMessage) usize {
    return (if (message.image != null) @as(usize, 1) else 0) + message.extra_images.len;
}

fn transcriptImageAt(message: app_state.ChatMessage, index: usize) ?app_state.ChatImageAttachment {
    if (index == 0) return message.image;
    const extra_index = index - 1;
    if (extra_index >= message.extra_images.len) return null;
    return message.extra_images[extra_index];
}

fn transcriptImageBlockHeight(message: app_state.ChatMessage, column_width: f32) f32 {
    const count = transcriptImageCount(message);
    if (count == 0) return 0.0;
    const bubble_width = if (message.role == .user) column_width * 0.62 else column_width;
    const inner_w = @max(bubble_width - theme.scaledUi(28.0), theme.scaledUi(80.0));
    const thumb_h = @max(@min(inner_w * 0.56, theme.scaledUi(220.0)), theme.scaledUi(96.0));
    const gap = theme.scaledUi(10.0);
    return gap + @as(f32, @floatFromInt(count)) * (thumb_h + gap);
}

fn transcriptMessageHeight(
    state: ?*app_state.AppState,
    message_index: ?usize,
    body_raw: []const u8,
    role: app_state.ChatRole,
    column_width: f32,
    message_author: []const u8,
    assistant_plain_layout: bool,
) f32 {
    return transcriptMessageHeightStream(state, message_index, body_raw, role, column_width, message_author, assistant_plain_layout, false);
}

fn transcriptMessageHeightStream(
    state: ?*app_state.AppState,
    message_index: ?usize,
    body_raw: []const u8,
    role: app_state.ChatRole,
    column_width: f32,
    message_author: []const u8,
    assistant_plain_layout: bool,
    streaming: bool,
) f32 {
    if (role == .system and shouldRenderPaletteCommandRow(message_author, body_raw)) {
        return transcriptCommandEventHeight(state, message_index, body_raw, column_width);
    }
    if (role == .system and isDiffSummaryMessage(message_author, body_raw)) {
        return diffSummaryHeight(state, message_index, body_raw, column_width);
    }
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const font_size = theme.scaledUi(15.5);
    const body_width = if (role == .user) column_width * 0.62 else column_width;
    const body_inner_width = @max(body_width - theme.scaledUi(28.0), theme.scaledUi(80.0));
    if (role == .assistant and !assistant_plain_layout) {
        if (!streaming) {
            if (state) |app| {
                if (message_index) |index| {
                    if (app.transcriptMarkdownBodyView(index, body)) |view| {
                        const measured = chat_markdown.measureBodyHeight(view.*, body_inner_width, markdownOptions(font_size));
                        return theme.scaledUi(44.0) + measured;
                    }
                }
            }
        }
        var view = (if (streaming)
            chat_markdown.buildBodyViewStreaming(std.heap.page_allocator, body)
        else
            chat_markdown.buildBodyView(std.heap.page_allocator, body)) catch {
            const chars_per_line = @max(@as(usize, @intFromFloat(body_inner_width / (font_size * 0.52))), 1);
            const line_count = wrappedLineCount(body, chars_per_line);
            return theme.scaledUi(46.0) + @as(f32, @floatFromInt(line_count)) * font_size * 1.38;
        };
        defer view.deinit(std.heap.page_allocator);
        const measured = chat_markdown.measureBodyHeight(view, body_inner_width, markdownOptions(font_size));
        return theme.scaledUi(46.0) + measured;
    }
    const chars_per_line = @max(@as(usize, @intFromFloat(body_inner_width / (font_size * 0.52))), 1);
    const line_count = wrappedLineCount(body, chars_per_line);
    return theme.scaledUi(46.0) + @as(f32, @floatFromInt(line_count)) * font_size * 1.38;
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
        renderCommandEventRow(state, column, y, height, message.author, message.body, clip, message_index, false);
        return;
    }
    if (message.role == .system and isDiffSummaryMessage(message.author, message.body)) {
        renderDiffSummaryCard(state, column, y, height, message.body, clip, message_index);
        return;
    }
    const role_label = switch (message.role) {
        .user => "You",
        .assistant => if (message.author.len > 0) message.author else "Assistant",
        .system => "System",
    };
    renderTranscriptBubbleFromParts(state, column, y, height, message.role, role_label, message.body, false, false, clip, message_index, false);
    renderTranscriptImages(state, column, y, height, message, clip);
}

fn renderTranscriptImages(state: *app_state.AppState, column: palette.Rect, y: f32, height: f32, message: app_state.ChatMessage, clip: palette.Rect) void {
    const count = transcriptImageCount(message);
    if (count == 0) return;

    const bubble_width = if (message.role == .user) column.w * 0.62 else column.w;
    const bubble_x = if (message.role == .user) column.x + column.w - bubble_width else column.x;
    const pad = theme.scaledUi(14.0);
    const gap = theme.scaledUi(10.0);
    const inner_w = @max(bubble_width - pad * 2.0, theme.scaledUi(80.0));
    const thumb_h = @max(@min(inner_w * 0.56, theme.scaledUi(220.0)), theme.scaledUi(96.0));
    var image_y = y + height - transcriptImageBlockHeight(message, column.w) + gap;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const image = transcriptImageAt(message, index) orelse continue;
        const frame = palette.Rect{
            .x = bubble_x + pad,
            .y = image_y,
            .w = inner_w,
            .h = thumb_h,
        };
        queueRoundedShellClipped(
            state,
            frame,
            paletteColor(colors.rgba(15, 22, 24, 255)),
            paletteColor(colors.rgba(74, 92, 99, 255)),
            theme.scaledUi(9.0),
            clip,
        );
        if (state.ensureImageTexture(image.path)) |cached| {
            const inset = theme.scaledUi(6.0);
            const image_rect = palette.Rect{ .x = frame.x + inset, .y = frame.y + inset, .w = frame.w - inset * 2.0, .h = frame.h - inset * 2.0 };
            const dims = runtime.scaledImageSize(cached.width, cached.height, image_rect.w, image_rect.h);
            queueImage(state, .{
                .x = image_rect.x + (image_rect.w - dims[0]) * 0.5,
                .y = image_rect.y + (image_rect.h - dims[1]) * 0.5,
                .w = dims[0],
                .h = dims[1],
            }, cached, frame);
        } else {
            queueText(state, .{ .x = frame.x + pad, .y = frame.y + pad, .w = frame.w - pad * 2.0, .h = theme.scaledUi(20.0) }, image.file_name, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), clip);
        }
        image_y += thumb_h + gap;
    }
}

// ----- Diff summary card -----

const DiffFileEntry = struct {
    path: []const u8,
    additions: i64,
    deletions: i64,
    patch: []const u8,
};

/// True when this system message was emitted by `appendPendingDiffSummaryEvent`
/// (author "Changed files", body framed with PERSISTED_DIFF_MARKER).
fn isDiffSummaryMessage(author: []const u8, body_raw: []const u8) bool {
    if (!std.mem.eql(u8, author, "Changed files")) return false;
    return std.mem.startsWith(u8, body_raw, utils.PERSISTED_DIFF_MARKER);
}

/// Iterator over diff file entries packed in the persisted body. Returns null
/// when the body does not start with `PERSISTED_DIFF_MARKER`.
fn parseDiffSummary(allocator: std.mem.Allocator, body_raw: []const u8) ?[]DiffFileEntry {
    if (!std.mem.startsWith(u8, body_raw, utils.PERSISTED_DIFF_MARKER)) return null;
    var rest = body_raw[utils.PERSISTED_DIFF_MARKER.len..];

    var files: std.ArrayList(DiffFileEntry) = .empty;
    errdefer files.deinit(allocator);

    while (rest.len > 0) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
        const header_line = rest[0..line_end];
        rest = rest[line_end + 1 ..];
        if (header_line.len == 0) continue;
        if (!std.mem.startsWith(u8, header_line, "FILE\t")) continue;
        var it = std.mem.splitScalar(u8, header_line["FILE\t".len..], '\t');
        const path = it.next() orelse continue;
        const additions = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch 0;
        const deletions = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch 0;
        const patch_len = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
        if (patch_len > rest.len) break;
        const patch = rest[0..patch_len];
        rest = rest[patch_len..];
        // Skip the trailing newline that separates entries.
        if (rest.len > 0 and rest[0] == '\n') rest = rest[1..];
        files.append(allocator, .{
            .path = path,
            .additions = additions,
            .deletions = deletions,
            .patch = patch,
        }) catch break;
    }
    return files.toOwnedSlice(allocator) catch null;
}

fn diffFileCardKey(message_index: usize, file_path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0xD1FFD1FFD1FFD1FF);
    hasher.update(std.mem.asBytes(&message_index));
    hasher.update(file_path);
    return hasher.final();
}

fn diffSummaryHeight(state: ?*app_state.AppState, message_index: ?usize, body_raw: []const u8, column_width: f32) f32 {
    const files = parseDiffSummary(std.heap.page_allocator, body_raw) orelse return 0.0;
    defer std.heap.page_allocator.free(files);
    return diffSummaryHeightForFiles(state, message_index, files, column_width);
}

fn diffSummaryHeightForFiles(state: ?*app_state.AppState, message_index: ?usize, files: []const DiffFileEntry, column_width: f32) f32 {
    const pad_y = theme.scaledUi(10.0);
    const header_h = theme.scaledUi(34.0);
    const row_h = theme.scaledUi(30.0);
    var total: f32 = pad_y + header_h + pad_y;
    const inner_w = @max(column_width - theme.scaledUi(28.0), theme.scaledUi(80.0));
    const code_font = theme.scaledUi(13.0);
    const code_line_h = code_font * 1.32;
    const code_char_w = code_font * 0.6;
    const code_inner_w = @max(inner_w - theme.scaledUi(20.0), theme.scaledUi(40.0));
    const code_cols = @max(@as(usize, @intFromFloat(code_inner_w / code_char_w)), 1);
    for (files, 0..) |file, idx| {
        total += row_h;
        const expanded = blk: {
            const app = state orelse break :blk false;
            const mi = message_index orelse break :blk false;
            _ = idx;
            break :blk app.isCardExpanded(diffFileCardKey(mi, file.path));
        };
        if (expanded) {
            const line_count = wrappedLineCount(file.patch, code_cols);
            total += @as(f32, @floatFromInt(line_count)) * code_line_h + theme.scaledUi(12.0);
        }
    }
    total += pad_y;
    return total;
}

fn renderDiffSummaryCard(
    state: *app_state.AppState,
    column: palette.Rect,
    y: f32,
    height: f32,
    body_raw: []const u8,
    clip: palette.Rect,
    message_index: usize,
) void {
    const files = parseDiffSummary(state.allocator, body_raw) orelse return;
    defer state.allocator.free(files);

    const bubble = snapRect(palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height });
    const rr = transcriptBubbleCornerRadius();
    const bg = colors.rgba(24, 26, 32, 255);
    const border = colors.rgba(56, 64, 78, 255);
    queueRoundedShellClipped(state, bubble, paletteColor(bg), paletteColor(border), rr, clip);

    const pad_x = theme.scaledUi(14.0);
    const pad_y = theme.scaledUi(10.0);
    const header_h = theme.scaledUi(34.0);
    const row_h = theme.scaledUi(30.0);

    // Header: "Changed files - N file(s) +A -D"
    var total_add: i64 = 0;
    var total_del: i64 = 0;
    for (files) |f| {
        total_add += f.additions;
        total_del += f.deletions;
    }
    const header_label = std.fmt.allocPrint(state.allocator, "Changed files — {d} file{s}", .{ files.len, if (files.len == 1) "" else "s" }) catch null;
    defer if (header_label) |t| state.allocator.free(t);
    const header_y = bubble.y + pad_y;
    queueFixedTextLine(state, snapRect(.{
        .x = bubble.x + pad_x,
        .y = header_y + theme.scaledUi(6.0),
        .w = bubble.w - pad_x * 2.0 - theme.scaledUi(120.0),
        .h = theme.scaledUi(20.0),
    }), header_label orelse "Changed files", paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.5), clip);

    const counts = std.fmt.allocPrint(state.allocator, "+{d}  -{d}", .{ total_add, total_del }) catch null;
    defer if (counts) |t| state.allocator.free(t);
    queueFixedTextLine(state, snapRect(.{
        .x = bubble.x + bubble.w - pad_x - theme.scaledUi(110.0),
        .y = header_y + theme.scaledUi(6.0),
        .w = theme.scaledUi(110.0),
        .h = theme.scaledUi(20.0),
    }), counts orelse "", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), clip);

    // Separator below header
    queueRect(state, snapRect(.{
        .x = bubble.x + pad_x,
        .y = header_y + header_h - 1.0,
        .w = bubble.w - pad_x * 2.0,
        .h = 1.0,
    }), paletteColor(colors.rgba(46, 52, 64, 255)));

    var row_y = bubble.y + pad_y + header_h;
    const file_font = theme.scaledUi(13.5);
    const code_font = theme.scaledUi(13.0);
    const code_line_h = code_font * 1.32;
    const code_char_w = code_font * 0.6;

    for (files) |file| {
        const key = diffFileCardKey(message_index, file.path);
        const expanded = state.isCardExpanded(key);

        const row_rect = palette.Rect{ .x = bubble.x, .y = row_y, .w = bubble.w, .h = row_h };

        // Hover background (very subtle) — skip for simplicity; just record hit.
        state.recordCardToggleHit(.{ .rect = row_rect, .key = key, .kind = .diff_file });

        // Chevron at left
        const chev_x = bubble.x + pad_x + theme.scaledUi(6.0);
        const chev_y = row_y + row_h * 0.5;
        queueCardChevron(state, chev_x, chev_y, expanded, paletteColor(theme.COLOR_TEXT_SUBTLE));

        // Path
        const path_x = chev_x + theme.scaledUi(14.0);
        const counts_w = theme.scaledUi(110.0);
        const path_w = @max(bubble.w - pad_x * 2.0 - (path_x - bubble.x) - counts_w, theme.scaledUi(40.0));
        const path_display = truncateMonoToWidth(state.allocator, file.path, path_w, file_font);
        defer if (path_display.allocated) state.allocator.free(path_display.text);
        queueFixedTextLine(state, snapRect(.{
            .x = path_x,
            .y = row_y + (row_h - file_font * 1.25) * 0.5,
            .w = path_w,
            .h = file_font * 1.25,
        }), path_display.text, paletteColor(theme.COLOR_WHITE), file_font, clip);

        // Counts on right (green +N, red -M)
        const adds_text = std.fmt.allocPrint(state.allocator, "+{d}", .{file.additions}) catch null;
        defer if (adds_text) |t| state.allocator.free(t);
        const dels_text = std.fmt.allocPrint(state.allocator, "-{d}", .{file.deletions}) catch null;
        defer if (dels_text) |t| state.allocator.free(t);
        const counts_right = bubble.x + bubble.w - pad_x;
        const dels_w = theme.scaledUi(46.0);
        const adds_w = theme.scaledUi(46.0);
        queueFixedTextLine(state, snapRect(.{
            .x = counts_right - dels_w,
            .y = row_y + (row_h - file_font * 1.25) * 0.5,
            .w = dels_w,
            .h = file_font * 1.25,
        }), dels_text orelse "-0", paletteColor(theme.COLOR_DIFF_REMOVE), file_font, clip);
        queueFixedTextLine(state, snapRect(.{
            .x = counts_right - dels_w - adds_w,
            .y = row_y + (row_h - file_font * 1.25) * 0.5,
            .w = adds_w,
            .h = file_font * 1.25,
        }), adds_text orelse "+0", paletteColor(theme.COLOR_DIFF_ADD), file_font, clip);

        row_y += row_h;

        if (expanded and file.patch.len > 0) {
            const patch_inset_x = bubble.x + pad_x + theme.scaledUi(20.0);
            const patch_w = bubble.w - pad_x * 2.0 - theme.scaledUi(20.0);
            const cols = @max(@as(usize, @intFromFloat(patch_w / code_char_w)), 1);
            renderDiffPatchLines(state, .{ .x = patch_inset_x, .y = row_y + theme.scaledUi(4.0), .w = patch_w, .h = bubble.y + bubble.h - row_y }, file.patch, cols, code_font, code_line_h, clip);
            const line_count = wrappedLineCount(file.patch, cols);
            row_y += @as(f32, @floatFromInt(line_count)) * code_line_h + theme.scaledUi(12.0);
        }
    }
}

fn renderDiffPatchLines(
    state: *app_state.AppState,
    rect: palette.Rect,
    patch: []const u8,
    cols: usize,
    font_size: f32,
    line_h: f32,
    clip: palette.Rect,
) void {
    var y = rect.y;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= patch.len and y < clip.y + clip.h) : (i += 1) {
        if (i != patch.len and patch[i] != '\n') continue;
        const line_end = i;
        if (line_start == line_end) {
            y += line_h;
            line_start = i + 1;
            continue;
        }
        const line = patch[line_start..line_end];
        const color: [4]f32 = switch (line[0]) {
            '+' => if (std.mem.startsWith(u8, line, "+++")) [4]f32{ 200.0 / 255.0, 200.0 / 255.0, 200.0 / 255.0, 1.0 } else theme.COLOR_DIFF_ADD,
            '-' => if (std.mem.startsWith(u8, line, "---")) [4]f32{ 200.0 / 255.0, 200.0 / 255.0, 200.0 / 255.0, 1.0 } else theme.COLOR_DIFF_REMOVE,
            '@' => [4]f32{ 122.0 / 255.0, 202.0 / 255.0, 255.0 / 255.0, 1.0 },
            else => theme.COLOR_TEXT_MUTED,
        };
        var chunk_start: usize = 0;
        while (chunk_start < line.len and y < clip.y + clip.h) {
            const remaining = line.len - chunk_start;
            const chunk_len = @min(remaining, cols);
            const chunk = line[chunk_start .. chunk_start + chunk_len];
            if (y + line_h >= clip.y) {
                queueFixedTextLine(state, snapRect(.{ .x = rect.x, .y = y, .w = rect.w, .h = line_h }), chunk, paletteColor(color), font_size, clip);
            }
            y += line_h;
            chunk_start += chunk_len;
        }
        line_start = i + 1;
    }
}

/// Stable key for the command-row expand/collapse state per message index.
fn commandCardKey(message_index: usize) u64 {
    var hasher = std.hash.Wyhash.init(0xC0DEC0DEC0DEC0DE);
    hasher.update(std.mem.asBytes(&message_index));
    hasher.update("command_card");
    return hasher.final();
}

fn renderCommandEventRow(
    state: *app_state.AppState,
    column: palette.Rect,
    y: f32,
    height: f32,
    original_author: []const u8,
    body_raw: []const u8,
    clip: palette.Rect,
    message_index: usize,
    running: bool,
) void {
    const bubble = palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height };
    const rr = transcriptBubbleCornerRadius();
    const failed = std.mem.eql(u8, original_author, "Command failed");
    queueRoundedShellClipped(
        state,
        bubble,
        paletteColor(colors.rgba(28, 29, 34, 255)),
        paletteColor(if (failed) theme.COLOR_DIFF_REMOVE else colors.DARK_BLUE),
        rr,
        clip,
    );

    const pad_x = theme.scaledUi(14.0);
    const pad_y = theme.scaledUi(9.0);
    const font_size = theme.scaledUi(15.0);
    const line_h = font_size * 1.28;
    const header_h = line_h + pad_y * 2.0;

    const key = commandCardKey(message_index);
    const expanded = state.isCardExpanded(key);

    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const label = paletteCommandRowDisplayAuthor(original_author, body_raw);

    const status_dia = theme.scaledUi(8.0);
    const status_cx = bubble.x + pad_x + status_dia * 0.5;
    const status_cy = bubble.y + pad_y + line_h * 0.5;
    const status_color: [4]f32 = blk: {
        if (failed) break :blk theme.COLOR_DIFF_REMOVE;
        if (running) {
            const t_ns: i128 = profiler.nowNs();
            const period_ns: i128 = 1_400_000_000;
            const phase = @as(f32, @floatFromInt(@mod(t_ns, period_ns))) / @as(f32, @floatFromInt(period_ns));
            const sin_t = std.math.sin(phase * std.math.tau);
            const alpha = 0.45 + 0.55 * (sin_t * 0.5 + 0.5);
            break :blk [4]f32{ 122.0 / 255.0, 202.0 / 255.0, 255.0 / 255.0, alpha };
        }
        break :blk [4]f32{ 100.0 / 255.0, 170.0 / 255.0, 130.0 / 255.0, 1.0 };
    };
    queueRounded(state, .{
        .x = status_cx - status_dia * 0.5,
        .y = status_cy - status_dia * 0.5,
        .w = status_dia,
        .h = status_dia,
    }, paletteColor(status_color), status_dia * 0.5);

    const chev_box_w = theme.scaledUi(18.0);
    const chev_cx = bubble.x + bubble.w - pad_x - chev_box_w * 0.5;
    const chev_cy = status_cy;
    queueCardChevron(state, chev_cx, chev_cy, expanded, paletteColor(theme.COLOR_TEXT_SUBTLE));

    const text_x = status_cx + status_dia * 0.5 + theme.scaledUi(10.0);
    const text_w = @max((bubble.x + bubble.w - pad_x - chev_box_w - theme.scaledUi(6.0)) - text_x, theme.scaledUi(40.0));
    const text_color = if (failed) paletteColor(theme.COLOR_DIFF_REMOVE) else paletteColor(theme.COLOR_TEXT_MUTED);

    const header_text = std.fmt.allocPrint(state.allocator, ">_ {s} - {s}", .{ label, body }) catch null;
    defer if (header_text) |t| state.allocator.free(t);

    const display_text = truncateMonoToWidth(state.allocator, header_text orelse body, text_w, font_size);
    defer if (display_text.allocated) state.allocator.free(display_text.text);

    queueFixedTextLine(state, snapRect(.{
        .x = text_x,
        .y = bubble.y + pad_y + (line_h - font_size * 1.25) * 0.5,
        .w = text_w,
        .h = font_size * 1.25,
    }), display_text.text, text_color, font_size, clip);

    state.recordCardToggleHit(.{
        .rect = .{ .x = bubble.x, .y = bubble.y, .w = bubble.w, .h = header_h },
        .key = key,
        .kind = .command_card,
    });

    if (expanded) {
        const inner = palette.Rect{
            .x = bubble.x + pad_x,
            .y = bubble.y + header_h,
            .w = @max(bubble.w - pad_x * 2.0, theme.scaledUi(40.0)),
            .h = @max(bubble.h - header_h - pad_y, theme.scaledUi(1.0)),
        };
        renderWrappedBody(state, inner, body, paletteColor(theme.COLOR_TEXT_MUTED), font_size, clip);
    }
}

/// Right-pointing triangle when collapsed, down-pointing when expanded.
fn queueCardChevron(state: *app_state.AppState, cx: f32, cy: f32, expanded: bool, color: palette.Color) void {
    const half = theme.scaledUi(4.0);
    if (expanded) {
        queueTriangle(
            state,
            .{ .x = cx - half, .y = cy - half * 0.5 },
            .{ .x = cx + half, .y = cy - half * 0.5 },
            .{ .x = cx, .y = cy + half * 0.7 },
            color,
        );
    } else {
        queueTriangle(
            state,
            .{ .x = cx - half * 0.5, .y = cy - half },
            .{ .x = cx + half * 0.7, .y = cy },
            .{ .x = cx - half * 0.5, .y = cy + half },
            color,
        );
    }
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
    streaming: bool,
) void {
    const bubble_width = if (role == .user) column.w * 0.62 else column.w;
    const bubble_x = if (role == .user) column.x + column.w - bubble_width else column.x;
    const bubble = snapRect(palette.Rect{ .x = bubble_x, .y = y, .w = bubble_width, .h = height });
    const bg = switch (role) {
        .user => colors.rgba(31, 48, 46, 255),
        .assistant => colors.rgba(22, 30, 32, 242),
        .system => colors.rgba(57, 43, 9, 235),
    };
    const rr = transcriptBubbleCornerRadius();
    queueRoundedShellClipped(state, bubble, paletteColor(bg), paletteColor(theme.COLOR_PANEL_MUTED), rr, clip);
    queueText(state, snapRect(.{ .x = bubble.x + theme.scaledUi(14.0), .y = bubble.y + theme.scaledUi(9.0), .w = bubble.w - theme.scaledUi(28.0), .h = theme.scaledUi(20.0) }), role_label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), clip);
    const body_rect = palette.Rect{
        .x = bubble.x + theme.scaledUi(14.0),
        .y = bubble.y + theme.scaledUi(34.0),
        .w = bubble.w - theme.scaledUi(28.0),
        .h = bubble.h - theme.scaledUi(42.0),
    };
    const body_text = std.mem.trim(u8, body_raw, "\n\r\t ");
    const body_color = if (muted_body) paletteColor(theme.COLOR_TEXT_MUTED) else paletteColor(theme.COLOR_WHITE);
    if (role == .assistant and !muted_body and !assistant_plain_layout) {
        renderMarkdownBody(state, message_index, body_rect, body_text, clip, streaming);
    } else {
        renderWrappedBody(state, body_rect, body_text, body_color, theme.scaledUi(15.5), clip);
    }
}

fn markdownOptions(font_size: f32) chat_markdown.RenderOptions {
    return .{
        .base_font_size = font_size,
        .line_height = font_size * 1.43,
        .glyph_width = font_size * 0.53,
        .code_font_size = font_size * 0.88,
    };
}

fn renderMarkdownBody(state: *app_state.AppState, message_index: usize, rect: palette.Rect, body: []const u8, clip: palette.Rect, streaming: bool) void {
    if (body.len == 0) return;
    // Cached path only applies to committed (non-streaming) messages — the
    // stream body changes per frame so the cache key would invalidate anyway.
    if (!streaming) {
        if (state.transcriptMarkdownBodyView(message_index, body)) |view| {
            renderMarkdownBodyView(state, message_index, rect, view.*, clip);
            return;
        }
    }

    var view = (if (streaming)
        chat_markdown.buildBodyViewStreaming(state.allocator, body)
    else
        chat_markdown.buildBodyView(state.allocator, body)) catch {
        renderWrappedBody(state, rect, body, paletteColor(theme.COLOR_WHITE), theme.scaledUi(16.0), clip);
        return;
    };
    defer view.deinit(state.allocator);
    renderMarkdownBodyView(state, message_index, rect, view, clip);
}

fn renderMarkdownBodyView(state: *app_state.AppState, message_index: usize, rect: palette.Rect, view: chat_markdown.BodyView, clip: palette.Rect) void {
    const font_size = theme.scaledUi(15.5);
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
        .text_arena = &state.palette_frame_text_arena,
        .cursor = rect,
        .available_width = rect.w,
        .mouse_pos = if (state.palette_mouse_in_workspace) .{ mx, my } else .{ -1.0, -1.0 },
        .hovered = hovered,
        .clip = clip,
        .code_copy_recorder = state.codeCopyButtonRecorder(),
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

const TruncatedText = struct {
    text: []const u8,
    allocated: bool,
};

/// Truncates `text` so it fits in `max_width` pixels at `font_size` using the
/// fixed-mono advance (~0.55em). Appends "…" when truncated. Returns a borrowed
/// slice when no truncation was needed.
fn truncateMonoToWidth(allocator: std.mem.Allocator, text: []const u8, max_width: f32, font_size: f32) TruncatedText {
    const char_w = font_size * 0.55;
    if (char_w <= 0.0 or max_width <= 0.0) return .{ .text = text, .allocated = false };
    const fits: usize = @intFromFloat(@max(max_width / char_w, 0.0));
    if (text.len <= fits) return .{ .text = text, .allocated = false };
    if (fits <= 1) return .{ .text = "…", .allocated = false };
    const keep = fits - 1;
    const buf = allocator.alloc(u8, keep + "…".len) catch return .{ .text = text[0..@min(text.len, fits)], .allocated = false };
    @memcpy(buf[0..keep], text[0..keep]);
    @memcpy(buf[keep..], "…");
    return .{ .text = buf, .allocated = true };
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
    state.updateFileSearch();
    state.palette_composer.render(state.allocator, &state.palette_overlay_batch) catch |err| {
        app_state.log.warn("failed to render palette composer: {s}", .{@errorName(err)});
    };
    renderComposerFileSearchResults(state);
    renderComposerDraftImage(state);
    renderComposerFollowupHint(state);
    renderComposerToolbarIcons(state);
    state.syncComposerToolbarOverlayHitRects();
}

fn renderComposerFileSearchResults(state: *app_state.AppState) void {
    file_search_hits = .{};
    if (!state.hasActiveFileSearch()) return;

    const composer = state.palette_composer.bounds();
    if (composer.w <= theme.scaledUi(160.0)) return;

    const results = state.fileSearchResults();
    const row_height = theme.scaledUi(42.0);
    const max_rows: usize = @min(results.len, file_search_hits.row_rects.len);
    const visible_rows: usize = if (results.len == 0) 1 else @max(@as(usize, 1), @min(max_rows, 6));
    const pad = theme.scaledUi(8.0);
    const gap = theme.scaledUi(8.0);
    const panel_w = @min(composer.w, theme.scaledUi(720.0));
    const panel_h = pad * 2.0 + row_height * @as(f32, @floatFromInt(visible_rows));
    const panel = palette.Rect{
        .x = composer.x,
        .y = @max(theme.scaledUi(8.0), composer.y - gap - panel_h),
        .w = panel_w,
        .h = panel_h,
    };
    file_search_hits.panel_rect = panel;

    const previous_z = state.palette_overlay_batch.setZIndex(COMPOSER_FILE_SEARCH_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    queueRoundedShellClipped(
        state,
        panel,
        paletteColor(colors.rgba(16, 21, 23, 250)),
        paletteColor(colors.rgba(76, 95, 101, 255)),
        theme.scaledUi(12.0),
        panel,
    );

    if (results.len == 0) {
        const message = if (state.fileSearchIsScanning()) "Indexing project files..." else "No matching files";
        queueText(state, .{
            .x = panel.x + theme.scaledUi(14.0),
            .y = panel.y + pad + theme.scaledUi(9.0),
            .w = panel.w - theme.scaledUi(28.0),
            .h = row_height,
        }, message, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), panel);
        return;
    }

    const mouse_ok = state.palette_mouse_in_workspace;
    const mx = state.palette_mouse_x;
    const my = state.palette_mouse_y;
    const selected_index = state.fileSearchSelectedIndex();
    const first_index = if (selected_index >= visible_rows) selected_index + 1 - visible_rows else 0;
    const end_index = @min(first_index + visible_rows, results.len);

    var visible_index: usize = 0;
    var result_index = first_index;
    while (result_index < end_index) : ({
        result_index += 1;
        visible_index += 1;
    }) {
        const row = palette.Rect{
            .x = panel.x + pad,
            .y = panel.y + pad + @as(f32, @floatFromInt(visible_index)) * row_height,
            .w = panel.w - pad * 2.0,
            .h = row_height,
        };
        file_search_hits.row_rects[visible_index] = row;
        file_search_hits.row_indices[visible_index] = result_index;
        file_search_hits.row_count = visible_index + 1;

        const hovered = mouse_ok and rectContains(row, mx, my);
        if (result_index == selected_index or hovered) {
            queueRounded(state, row, paletteColor(if (result_index == selected_index) colors.rgba(42, 73, 85, 230) else colors.rgba(38, 46, 50, 230)), theme.scaledUi(8.0));
        }

        const result = results[result_index];
        const icon = file_icons.forFile(result.file_name);
        const icon_w = theme.scaledUi(28.0);
        queueIconText(state, .{
            .x = row.x + theme.scaledUi(10.0),
            .y = row.y + theme.scaledUi(9.0),
            .w = icon_w,
            .h = row.h,
        }, icon.glyph, paletteColor(icon.color), theme.scaledUi(17.0), row);

        const text_x = row.x + theme.scaledUi(10.0) + icon_w;
        queueText(state, .{
            .x = text_x,
            .y = row.y + theme.scaledUi(6.0),
            .w = row.w - (text_x - row.x) - theme.scaledUi(12.0),
            .h = theme.scaledUi(18.0),
        }, result.file_name, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), row);
        queueText(state, .{
            .x = text_x,
            .y = row.y + theme.scaledUi(24.0),
            .w = row.w - (text_x - row.x) - theme.scaledUi(12.0),
            .h = theme.scaledUi(16.0),
        }, result.relative_path, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), row);
    }
}

fn renderComposerDraftImage(state: *app_state.AppState) void {
    const count = state.currentThread().draftImageCount();
    if (count == 0) {
        state.setComposerDraftImageClearRect(null);
        return;
    }
    const previous_z = state.palette_overlay_batch.setZIndex(COMPOSER_DRAFT_IMAGE_Z);
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

/// While a reply is streaming, show Tab queue/steer hint once the user has typed a non-empty draft (matches `handlePendingThreadFollowupShortcut`).
fn renderComposerFollowupHint(state: *app_state.AppState) void {
    if (!state.hasPendingStream()) return;
    if (state.currentThread().draftImageCount() != 0) return;
    const hint = state.pendingFollowupHint() orelse return;
    const draft = state.palette_composer.text();
    if (std.mem.trim(u8, draft, &std.ascii.whitespace).len == 0) return;

    const previous_z = state.palette_overlay_batch.setZIndex(COMPOSER_FOLLOWUP_HINT_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    const tr = state.palette_composer.textRect();
    const clip: palette.Rect = .{ .x = tr.x, .y = tr.y, .w = tr.w, .h = tr.h };
    const pad = theme.scaledUi(7.0);
    const font = theme.scaledUi(13.0);
    const est_w = @as(f32, @floatFromInt(hint.len)) * font * 0.52;
    const max_w = @max(tr.w - pad * 2.0, theme.scaledUi(1.0));
    const label_w = @min(est_w, max_w);
    queueText(state, .{
        .x = tr.x + tr.w - label_w - pad,
        .y = tr.y + tr.h - font - pad,
        .w = label_w,
        .h = font,
    }, hint, paletteColor(theme.COLOR_TEXT_MUTED), font, clip);
}

fn snapIconRectOrigin(rect: palette.Rect) palette.Rect {
    return .{
        .x = @round(rect.x * 2.0) * 0.5,
        .y = @round(rect.y * 2.0) * 0.5,
        .w = rect.w,
        .h = rect.h,
    };
}

fn renderComposerToolbarIcons(state: *app_state.AppState) void {
    const previous_z = state.palette_overlay_batch.setZIndex(COMPOSER_TOOLBAR_OVERLAY_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    const icon_color = paletteColor(.{ 0.82, 0.85, 0.91, 1.0 });
    const model_rect = state.palette_composer.modelRect();
    const fast_rect = state.palette_composer.fastRect();
    const access_rect = state.palette_composer.accessRect();
    const icon_size = theme.scaledUi(22.0);
    const provider_slot = theme.scaledUi(COMPOSER_PROVIDER_LOGO_SLOT_CSS);
    const model_icon_slot = palette.Rect{
        .x = model_rect.x + COMPOSER_TOOLBAR_PILL_PAD_X,
        .y = model_rect.y + (model_rect.h - provider_slot) * 0.5,
        .w = provider_slot,
        .h = provider_slot,
    };

    const provider_icon = switch (state.currentThread().provider) {
        .codex => state.codex_logo_texture,
        .opencode => state.opencode_logo_texture,
        .claude => state.claude_logo_texture,
        .cursor => state.cursor_logo_texture,
    };
    if (provider_icon) |cached| {
        const r = utils.snapImageRectToPixels(utils.imageRectContain(cached.width, cached.height, model_icon_slot.x, model_icon_slot.y, model_icon_slot.w, model_icon_slot.h));
        queueImage(state, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, cached, model_rect);
    }

    if (state.currentThread().provider == .codex) {
        const fast_icon_rect = snapIconRectOrigin(palette.Rect{
            .x = fast_rect.x + COMPOSER_TOOLBAR_PILL_PAD_X,
            .y = fast_rect.y + (fast_rect.h - icon_size) * 0.5,
            .w = icon_size,
            .h = icon_size,
        });
        if (state.currentThread().fast_mode == .on) {
            drawBoltIcon(state, fast_icon_rect, icon_color);
        } else {
            drawDefaultModeIcon(state, fast_icon_rect, icon_color);
        }
    }

    drawAccessIcon(state, snapIconRectOrigin(palette.Rect{
        .x = access_rect.x + COMPOSER_TOOLBAR_PILL_PAD_X,
        .y = access_rect.y + (access_rect.h - icon_size) * 0.5,
        .w = icon_size,
        .h = icon_size,
    }), icon_color);
}

// Nerd Font Symbols glyphs used for composer-toolbar icons. Rendering them
// through SDL_ttf gets us crisp, antialiased shapes at any DPI — much nicer
// than the hand-drawn triangles we used while the icon font was being wired
// up. Codepoints verified against SymbolsNerdFontMono-Regular.ttf's cmap.
const NF_FA_FLASH = "\u{F0E7}"; // lightning bolt
const NF_COD_LOCK = "\u{EA75}";
const NF_COD_UNLOCK = "\u{EB74}";
const NF_COD_CIRCLE = "\u{EABC}"; // hollow circle — reads as "inactive / default" next to the bolt

/// Renders a single codicon glyph centered inside `rect` using the icon font.
/// SDL_ttf rasterizes the glyph with proper antialiasing at the requested
/// pixel size so it stays crisp on HiDPI displays.
fn queueComposerIcon(state: *app_state.AppState, rect: palette.Rect, glyph: []const u8, color: palette.Color) void {
    // Glyph cell rendered slightly under the full rect height to leave the
    // codicon's drawn extent visually balanced with adjacent label text.
    const font_size = rect.h * 0.96;
    state.palette_overlay_batch.roleText(
        state.allocator,
        snapRect(rect),
        stableText(state, glyph),
        color,
        font_size,
        .icon,
        null,
        null,
    ) catch {};
}

fn drawBoltIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    queueComposerIcon(state, rect, NF_FA_FLASH, color);
}

fn drawDefaultModeIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    // Default mode: hollow circle — reads as "off / standard" against the
    // filled lightning bolt that marks Fast.
    queueComposerIcon(state, rect, NF_COD_CIRCLE, color);
}

fn drawAccessIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    const glyph = if (state.currentThread().access_mode == .full_access) NF_COD_UNLOCK else NF_COD_LOCK;
    queueComposerIcon(state, rect, glyph, color);
}

fn stableText(state: *app_state.AppState, value: []const u8) []const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch "";
}

fn queueRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, snapRect(rect), color) catch {};
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

/// Single-pass fill + border via the SDF panel command. Avoids the double-AA
/// fringe artifacts you get from drawing a filled rounded rect and an
/// overlapping `rectBorder` separately — the shader computes both regions
/// from one signed-distance evaluation per fragment.
fn queuePanel(state: *app_state.AppState, rect: palette.Rect, fill: palette.Color, border: palette.Color, radius: f32, border_width: f32) void {
    state.palette_overlay_batch.panel(state.allocator, snapRect(rect), fill, border, radius, border_width) catch {};
}

fn queueRoundedClipped(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, color, radius, clip) catch {};
}

fn queueImage(state: *app_state.AppState, rect: palette.Rect, texture: app_state.CachedImageTexture, clip: ?palette.Rect) void {
    if (!texture.valid or texture.texture_id == 0) return;
    state.palette_overlay_batch.image(state.allocator, snapRect(rect), palette.TextureId.init(texture.texture_id), .{
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

/// Chrome label rendered through the `.ui` font role (CalSans-Regular). Use
/// this for workspace header buttons / sidebar labels so they share the same
/// typeface as the composer prompt and selector pills.
fn queueChromeLabel(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.roleText(
        state.allocator,
        snapRect(rect),
        stableText(state, value),
        color,
        font_size,
        .ui,
        null,
        clip,
    ) catch {};
}

fn queueIconText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    state.palette_overlay_batch.roleText(state.allocator, rect, stableText(state, value), color, font_size, .icon, null, clip) catch {};
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn snapRect(rect: palette.Rect) palette.Rect {
    return .{
        .x = @round(rect.x),
        .y = @round(rect.y),
        .w = @round(rect.w),
        .h = @round(rect.h),
    };
}
