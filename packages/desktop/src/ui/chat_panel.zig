//! Palette-only chat workspace rendering.

const std = @import("std");
const palette = @import("palette");
const zig_dif = @import("zig_dif");

const app_state = @import("../state.zig");
const ai_harness = @import("../providers/harness.zig");
const profiler = @import("../runtime/profiler.zig");
const platform_runtime = @import("platform_runtime");
const utils = @import("../utils.zig");
const browser_panel = @import("browser.zig");
const bang_commands = @import("../workspace/bang_commands.zig");
const chat_types = @import("../state/chat_types.zig");
const chat_markdown = @import("chat_markdown.zig");
const colors = @import("colors.zig");
const composer_pickers = @import("composer_pickers.zig");
const file_icons = @import("file_icons.zig");
const globe_icon = @import("globe_icon.zig");
const runtime = @import("runtime.zig");
const terminal_panel = @import("terminal_panel.zig");
const text_measure = @import("text_measure.zig");
const theme = @import("theme.zig");

const TOP_BAR_HEIGHT: f32 = 57.0; // ~70% of legacy 82px cap
const WORKSPACE_HEADER_ICON_CONTROL_CSS: f32 = 30.0;
const WORKSPACE_HEADER_CHEVRON_CONTROL_CSS: f32 = 22.0;
const WORKSPACE_HEADER_CONTROL_GAP_CSS: f32 = 6.0;
const COMPOSER_HEIGHT: f32 = 220.0;
/// Toolbar logos and drawn icons must sit above `PaletteComposerPrompt` geometry (`z_index` 120) so
/// interleaved SDL_GPU rendering does not paint the composer panel over them.
const COMPOSER_TOOLBAR_OVERLAY_Z: i32 = 130;
/// Hint text in the draft area; above composer content (z 120) but below toolbar chrome (130).
const COMPOSER_FOLLOWUP_HINT_Z: i32 = 128;
/// Draft attachment previews sit above the composer card when they overlap the dock.
const COMPOSER_DRAFT_IMAGE_Z: i32 = 125;
/// Pinned queued/steering follow-up card sits above the composer card (z 120)
/// and draft attachments (125) so the staged prompt stays visible mid-turn.
const COMPOSER_FOLLOWUP_PIN_Z: i32 = 126;
/// Height of the pinned follow-up card shown above the composer while a reply
/// streams and a message is queued/steered. One label line plus two prompt lines.
const FOLLOWUP_PIN_HEIGHT: f32 = 60.0;
const BANG_MODE_BANNER_HEIGHT: f32 = 54.0;
const APPROVAL_CARD_HEIGHT: f32 = 164.0;
/// File mention search must sit above composer chrome and toolbar menus.
const COMPOSER_FILE_SEARCH_Z: i32 = 150;
/// Must match `PaletteComposerPrompt` `pill_padding_x` in `state.zig` so toolbar glyphs align with label insets.
const COMPOSER_TOOLBAR_PILL_PAD_X: f32 = 13.0;
/// Provider logo slot in the model pill.
const COMPOSER_PROVIDER_LOGO_SLOT_CSS: f32 = 26.0;
/// Shared max width for the chat content column. The composer card and the
/// transcript bubble column both clamp to this (via `chatContentColumn`) so
/// they always stay vertically aligned at the same width.
const CHAT_CONTENT_MAX_WIDTH: f32 = 900.0;
const TRANSCRIPT_LINE_HEIGHT: f32 = 22.0;
/// Bubble body text matches the composer's input text exactly (same CSS units,
/// same `uiScaleFactor()`), so reading the thread and typing a prompt share one
/// type size. Line height, glyph estimates, and code sizes all derive from this
/// via `markdownOptions`, so bubble heights track it automatically.
const TRANSCRIPT_MARKDOWN_FONT_SIZE: f32 = app_state.PALETTE_COMPOSER_FONT_SIZE;
/// Direct wheel scroll (no inertia); larger than legacy 64 for faster scanning.
const TRANSCRIPT_WHEEL_PIXELS: f32 = 96.0;
const TRANSCRIPT_PAGE_VIEW_FRAC: f32 = 0.88;
const TOOL_OUTPUT_COLLAPSED_LINES: usize = 18;

const MAX_TRANSCRIPT_HITS = 16;
const TranscriptHit = struct {
    pane_id: ?app_state.WorkspacePaneId = null,
    rect: palette.Rect = .{},
    column: palette.Rect = .{},
    clip: palette.Rect = .{},
    scroll_y: f32 = 0.0,
    track: palette.Rect = .{},
    thumb: palette.Rect = .{},
    max_scroll: f32 = 0.0,
};

var transcript_hit_count: usize = 0;
var transcript_hits: [MAX_TRANSCRIPT_HITS]TranscriptHit = [_]TranscriptHit{.{}} ** MAX_TRANSCRIPT_HITS;

const UsageActionHit = struct {
    rect: palette.Rect = .{},
};

const MAX_USAGE_ACTION_HITS = 16;
var usage_action_hit_count: usize = 0;
var usage_action_hits: [MAX_USAGE_ACTION_HITS]UsageActionHit = [_]UsageActionHit{.{}} ** MAX_USAGE_ACTION_HITS;

const DiffFileOpenHit = struct {
    rect: palette.Rect = .{},
    path: []const u8 = "",
};
const MAX_DIFF_FILE_OPEN_HITS = 64;
var diff_file_open_hit_count: usize = 0;
var diff_file_open_hits: [MAX_DIFF_FILE_OPEN_HITS]DiffFileOpenHit = [_]DiffFileOpenHit{.{}} ** MAX_DIFF_FILE_OPEN_HITS;

const DiffLayoutHit = struct {
    rect: palette.Rect = .{},
    split: bool = false,
};
const MAX_DIFF_LAYOUT_HITS = 32;
var diff_layout_hit_count: usize = 0;
var diff_layout_hits: [MAX_DIFF_LAYOUT_HITS]DiffLayoutHit = [_]DiffLayoutHit{.{}} ** MAX_DIFF_LAYOUT_HITS;
const MAX_BANG_RETRY_HITS = 64;
const BangRetryHit = struct { rect: palette.Rect = .{}, command: []const u8 = "" };
var bang_retry_hit_count: usize = 0;
var bang_retry_hits: [MAX_BANG_RETRY_HITS]BangRetryHit = [_]BangRetryHit{.{}} ** MAX_BANG_RETRY_HITS;
const MAX_TRANSCRIPT_IMAGE_HITS = 64;
const TranscriptImageHit = struct {
    rect: palette.Rect = .{},
    path: [:0]const u8 = "",
};
var transcript_image_hit_count: usize = 0;
var transcript_image_hits: [MAX_TRANSCRIPT_IMAGE_HITS]TranscriptImageHit = [_]TranscriptImageHit{.{}} ** MAX_TRANSCRIPT_IMAGE_HITS;

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

const ApprovalHitCache = struct {
    pane_id: ?app_state.WorkspacePaneId = null,
    copy_rect: palette.Rect = .{},
    approve_rect: palette.Rect = .{},
    deny_rect: palette.Rect = .{},
};
var approval_hits: ApprovalHitCache = .{};

const ApprovalAction = enum {
    copy,
    approve,
    deny,
};

const FileSearchHitCache = struct {
    panel_rect: palette.Rect = .{},
    row_count: usize = 0,
    row_rects: [8]palette.Rect = [_]palette.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 8,
    row_indices: [8]usize = [_]usize{0} ** 8,
};

var file_search_hits: FileSearchHitCache = .{};

const SlashPickerHitCache = struct {
    panel_rect: palette.Rect = .{},
    row_count: usize = 0,
    row_rects: [8]palette.Rect = [_]palette.Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** 8,
    row_indices: [8]usize = [_]usize{0} ** 8,
};

var slash_picker_hits: SlashPickerHitCache = .{};

const WorkspaceHeaderOpenMenuRow = enum {
    folder,
    configured_editor,
    cursor,
    vscode,
    zed,
};

const WorkspaceHeaderHitCache = struct {
    used: bool = false,
    pane_id: ?app_state.WorkspacePaneId = null,
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

const MAX_WORKSPACE_HEADER_HITS = 8;
var workspace_header_hit_count: usize = 0;
var workspace_header_hits: [MAX_WORKSPACE_HEADER_HITS]WorkspaceHeaderHitCache = [_]WorkspaceHeaderHitCache{.{}} ** MAX_WORKSPACE_HEADER_HITS;

pub fn renderWorkspace(state: *app_state.AppState, width: f32, height: f32) void {
    renderWorkspaceAt(state, .{ .x = estimateWorkspaceOriginX(state, width), .y = 0.0, .w = width, .h = height });
}

pub fn resetTranscriptHitCache() void {
    transcript_hit_count = 0;
    usage_action_hit_count = 0;
    diff_file_open_hit_count = 0;
    diff_layout_hit_count = 0;
    bang_retry_hit_count = 0;
    transcript_image_hit_count = 0;
}

/// Keeps scrolling-strip input geometry inside the same viewport as rendering.
pub fn clipTranscriptHitCache(bounds: palette.Rect) void {
    var write_index: usize = 0;
    for (transcript_hits[0..transcript_hit_count]) |hit| {
        var clipped = hit;
        clipped.rect = intersectRect(hit.rect, bounds);
        clipped.clip = intersectRect(hit.clip, bounds);
        clipped.track = intersectRect(hit.track, bounds);
        clipped.thumb = intersectRect(hit.thumb, bounds);
        if (clipped.rect.w <= 0.0 or clipped.rect.h <= 0.0) continue;
        transcript_hits[write_index] = clipped;
        write_index += 1;
    }
    transcript_hit_count = write_index;
}

pub fn renderWorkspaceAt(state: *app_state.AppState, rect: palette.Rect) void {
    resetWorkspaceHeaderHitCache();
    renderWorkspaceAtForPane(state, rect, null);
}

pub fn paneHeaderHeight(rect: palette.Rect) f32 {
    return theme.clampf(rect.h * 0.098, theme.scaledUi(38.0), theme.scaledUi(TOP_BAR_HEIGHT));
}

pub fn renderWorkspaceAtForPane(state: *app_state.AppState, rect: palette.Rect, pane_id: ?app_state.WorkspacePaneId) void {
    renderWorkspaceAtForPaneWithReserve(state, rect, pane_id, 0.0);
}

fn paneOwnsActiveChatState(state: *const app_state.AppState, pane_id: ?app_state.WorkspacePaneId) bool {
    const id = pane_id orelse return true;
    return state.isCurrentProjectWorkspacePaneFocused(id) or state.isCurrentProjectWorkspacePaneMaximized(id);
}

/// Single source of truth for the chat lane's centered content column: the
/// composer card and the transcript bubble column both take their x/width from
/// this formula so they render at exactly the same width on the same axis.
/// Responsive: per-side inset scales with lane width (clamped 16–48px) and the
/// column caps at CHAT_CONTENT_MAX_WIDTH on wide panes. x/w are snapped to
/// whole pixels so both surfaces land on identical device pixels.
fn chatContentColumn(lane_x: f32, lane_w: f32) struct { x: f32, w: f32 } {
    const side_margin = theme.clampf(lane_w * 0.045, theme.scaledUi(16.0), theme.scaledUi(48.0));
    const width = @max(theme.scaledUi(220.0), @min(lane_w - side_margin * 2.0, theme.scaledUi(CHAT_CONTENT_MAX_WIDTH)));
    return .{ .x = @round(lane_x + (lane_w - width) * 0.5), .w = @round(width) };
}

pub fn renderWorkspaceAtForPaneWithReserve(state: *app_state.AppState, rect: palette.Rect, pane_id: ?app_state.WorkspacePaneId, header_right_reserve: f32) void {
    const blocked_by_quick = if (state.currentProjectQuickPane()) |quick|
        quick.visible and pane_id != null and pane_id.? != quick.pane_id
    else
        false;
    const live_composer = !blocked_by_quick and paneOwnsActiveChatState(state, pane_id);
    const restore_thread_index = if (pane_id != null and state.project_controller.projects.items.len > 0)
        state.project_controller.projects.items[state.project_controller.selected_index].selected_thread_index
    else
        null;
    if (pane_id) |id| {
        if (state.workspaceChatThreadIndexByPane(id)) |thread_index| {
            state.project_controller.projects.items[state.project_controller.selected_index].selected_thread_index = thread_index;
        }
    }
    defer {
        if (restore_thread_index) |thread_index| {
            if (state.project_controller.projects.items.len > 0 and thread_index < state.project_controller.projects.items[state.project_controller.selected_index].threads.items.len) {
                state.project_controller.projects.items[state.project_controller.selected_index].selected_thread_index = thread_index;
            }
        }
    }

    if (live_composer) {
        state.invalidateComposerToolbarOverlayHitRects();
        file_search_hits = .{};
    }
    if (pane_id == null) transcript_hit_count = 0;
    queueRect(state, rect, paletteColor(theme.background()));
    if (state.project_controller.projects.items.len == 0) {
        state.workspace_header_open_menu_open = false;
        state.workspace_header_open_menu_pane_id = null;
        renderEmptyProjects(state, rect);
        return;
    }

    // ~30% shorter than the original (0.14 / 54 / 82) clamp: scale each bound by 0.7.
    const header_height = theme.clampf(rect.h * 0.098, theme.scaledUi(38.0), theme.scaledUi(TOP_BAR_HEIGHT));
    const composer_height = theme.clampf(rect.h * 0.29, theme.scaledUi(128.0), theme.scaledUi(COMPOSER_HEIGHT));
    const bottom_margin = theme.clampf(rect.h * 0.018, theme.scaledUi(8.0), theme.scaledUi(14.0));
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
    const bang_mode = live_composer and state.composerInBangCommandMode();
    const bang_mode_reserve = if (bang_mode)
        theme.scaledUi(BANG_MODE_BANNER_HEIGHT) + theme.scaledUi(8.0)
    else
        0.0;

    // Pin the queued/steered follow-up just above the composer (AMP-TUI style) so
    // every provider gets a visible "this is waiting to send" affordance, not just
    // Codex inline steering. Snapshotted once per frame; the prompt copy is freed
    // at the end of this layout pass after `stableText` has duped it into the frame
    // arena for the render commands. Hidden once Codex accepts steering inline
    // (`.sent_inline`), since that prompt then appears in the transcript instead.
    const followup_pin = state.pendingFollowupSnapshot() catch null;
    defer if (followup_pin) |fp| state.allocator.free(fp.prompt);
    const show_followup_pin = !blocked_by_quick and if (followup_pin) |fp| fp.state != .sent_inline else false;
    const followup_reserve = if (show_followup_pin)
        theme.scaledUi(FOLLOWUP_PIN_HEIGHT) + theme.scaledUi(10.0)
    else
        0.0;
    const pending_approval = if (live_composer) state.pendingApprovalSnapshot() catch null else null;
    defer if (pending_approval) |approval| {
        state.allocator.free(approval.call_id);
        state.allocator.free(approval.title);
        state.allocator.free(approval.body);
    };
    const approval_reserve = if (pending_approval != null)
        theme.scaledUi(APPROVAL_CARD_HEIGHT) + theme.scaledUi(10.0)
    else
        0.0;

    const body = palette.Rect{
        .x = rect.x,
        .y = header.y + header.h,
        .w = rect.w,
        .h = @max(composer_y - (header.y + header.h) - attachment_reserve - bang_mode_reserve - followup_reserve - approval_reserve, theme.scaledUi(120.0)),
    };

    const browser_visible = state.isBrowserVisible() and pane_id == null;
    const split_chat_browser = browser_visible and body.w >= theme.scaledUi(900.0);
    const stacked_chat_browser = browser_visible and !split_chat_browser and body.h >= theme.scaledUi(300.0);
    const browser_width = if (split_chat_browser) state.browserPanelWidth(body.w) else 0.0;
    const composer_lane_w = if (split_chat_browser) body.w - browser_width else body.w;
    const composer_lane_x = body.x;

    // Composer shares the transcript's content column so the prompt box and the
    // conversation bubbles are always the same width on the same center axis.
    const composer_column = chatContentColumn(composer_lane_x, composer_lane_w);
    const composer_rect = palette.Rect{
        .x = composer_column.x,
        .y = composer_y,
        .w = composer_column.w,
        .h = composer_height,
    };

    if (split_chat_browser) {
        const chat_rect = palette.Rect{ .x = body.x, .y = body.y, .w = body.w - browser_width, .h = body.h };
        renderTranscript(state, chat_rect, pane_id);
        // Transcript uses only `body` (above composer). The browser column is empty to the right of the
        // composer, so extend the dock through that strip to the same bottom as the composer row.
        const browser_dock_h = composer_bottom - body.y;
        browser_panel.renderDockAt(state, .{
            .x = chat_rect.x + chat_rect.w,
            .y = body.y,
            .w = browser_width,
            .h = @max(browser_dock_h, theme.scaledUi(120.0)),
        });
    } else if (stacked_chat_browser) {
        const browser_gap = theme.scaledUi(10.0);
        const browser_height = @min(state.browserPanelHeight(body.h), body.h * 0.48);
        const chat_h = @max(body.h - browser_height - browser_gap, theme.scaledUi(96.0));
        const chat_rect = palette.Rect{ .x = body.x, .y = body.y, .w = body.w, .h = chat_h };
        renderTranscript(state, chat_rect, pane_id);
        browser_panel.renderDockAt(state, .{
            .x = body.x,
            .y = body.y + chat_h + browser_gap,
            .w = body.w,
            .h = @max(browser_height, theme.scaledUi(120.0)),
        });
    } else {
        renderTranscript(state, body, pane_id);
    }

    // Paint after the transcript so the opaque header strip wins over any scrolled
    // message geometry or GL text that would otherwise overlap the title bar.
    renderHeader(state, header, header_right_reserve, pane_id);

    if (!blocked_by_quick) {
        if (live_composer) {
            renderComposer(state, composer_rect);
        } else {
            renderInactiveComposer(state, composer_rect);
        }
    }

    if (bang_mode) {
        const banner_rect = palette.Rect{
            .x = composer_rect.x,
            .y = composer_rect.y - theme.scaledUi(BANG_MODE_BANNER_HEIGHT) - theme.scaledUi(8.0),
            .w = composer_rect.w,
            .h = theme.scaledUi(BANG_MODE_BANNER_HEIGHT),
        };
        renderBangModeBanner(state, banner_rect);
    }

    // The pin sits above the composer and any draft-image attachments, in the
    // strip reserved by `followup_reserve`. Bottom edge clears the attachments.
    if (show_followup_pin) {
        if (followup_pin) |fp| {
            const pin_rect = palette.Rect{
                .x = composer_rect.x,
                .y = composer_rect.y - bang_mode_reserve - attachment_reserve - theme.scaledUi(FOLLOWUP_PIN_HEIGHT) - theme.scaledUi(8.0),
                .w = composer_rect.w,
                .h = theme.scaledUi(FOLLOWUP_PIN_HEIGHT),
            };
            renderPendingFollowupPin(state, pin_rect, fp, state.currentThread().provider);
            // Register the hit rect so a double-click can pull it back for editing.
            state.setFollowupPinRect(pin_rect);
        } else {
            state.setFollowupPinRect(null);
        }
    } else {
        state.setFollowupPinRect(null);
    }
    if (pending_approval) |approval| {
        const card_rect = palette.Rect{
            .x = composer_rect.x,
            .y = composer_rect.y - bang_mode_reserve - attachment_reserve - followup_reserve - theme.scaledUi(APPROVAL_CARD_HEIGHT) - theme.scaledUi(8.0),
            .w = composer_rect.w,
            .h = theme.scaledUi(APPROVAL_CARD_HEIGHT),
        };
        renderApprovalCard(state, card_rect, approval, pane_id);
    } else if (live_composer) {
        approval_hits = .{};
    }
    if (terminal_height > 0.0) {
        terminal_panel.renderDockAt(state, .{
            .x = rect.x,
            .y = rect.y + rect.h - terminal_height,
            .w = rect.w,
            .h = terminal_height,
        });
    }
    if (live_composer) composer_pickers.render(state);
}

fn estimateWorkspaceOriginX(state: *app_state.AppState, workspace_width: f32) f32 {
    var sidebar_width: f32 = if (state.isSidebarCollapsed()) theme.scaledUi(68.0) else theme.scaledUi(280.0);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const total_width = workspace_width + sidebar_width;
        // Mirror computeRootLayout's expanded-rail ratio/clamps so the
        // estimated workspace origin stays in sync with the real layout.
        sidebar_width = if (state.isSidebarCollapsed())
            theme.clampf(total_width * 0.07, theme.scaledUi(60.0), theme.scaledUi(76.0))
        else
            theme.clampf(total_width * 0.19, theme.scaledUi(260.0), @min(theme.scaledUi(360.0), total_width * 0.32));
    }
    return sidebar_width;
}

pub fn handleWorkspaceHeaderPaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) return false;
    if (state.project_controller.projects.items.len == 0) return false;

    if (workspaceHeaderMenuHit(state)) |menu_hit| {
        if (rectContains(menu_hit.menu_panel_rect, x, y)) {
            var i: usize = 0;
            while (i < menu_hit.menu_row_count) : (i += 1) {
                if (!rectContains(menu_hit.menu_row_rects[i], x, y)) continue;
                state.workspace_header_open_menu_open = false;
                state.workspace_header_open_menu_pane_id = null;
                state.blurPaletteComposer();
                if (menu_hit.pane_id) |pane_id| _ = state.focusCurrentProjectWorkspacePane(pane_id);
                if (!menu_hit.menu_row_enabled[i]) {
                    runtime.log.info(
                        "workspace header open menu row hit (disabled) kind={s} x={d:.1} y={d:.1}",
                        .{ @tagName(menu_hit.menu_row_kind[i]), x, y },
                    );
                    return true;
                }
                runtime.log.info(
                    "workspace header open menu row kind={s} x={d:.1} y={d:.1}",
                    .{ @tagName(menu_hit.menu_row_kind[i]), x, y },
                );
                switch (menu_hit.menu_row_kind[i]) {
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
            state.workspace_header_open_menu_pane_id = null;
            state.blurPaletteComposer();
            runtime.log.info("workspace header open menu panel hit (no row) x={d:.1} y={d:.1}", .{ x, y });
            return true;
        }
    }

    const control_hit = workspaceHeaderControlHit(x, y) orelse {
        if (state.workspace_header_open_menu_open) {
            state.workspace_header_open_menu_open = false;
            state.workspace_header_open_menu_pane_id = null;
            runtime.log.info("workspace header dismissed open menu (click outside controls) x={d:.1} y={d:.1}", .{ x, y });
        }
        return false;
    };

    if (control_hit.pane_id) |pane_id| _ = state.focusCurrentProjectWorkspacePane(pane_id);

    if (rectContains(control_hit.open_main_rect, x, y)) {
        state.workspace_header_open_menu_open = false;
        state.workspace_header_open_menu_pane_id = null;
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
    if (rectContains(control_hit.chevron_rect, x, y)) {
        const was_open_here = state.workspace_header_open_menu_open and paneIdEqual(state.workspace_header_open_menu_pane_id, control_hit.pane_id);
        state.workspace_header_open_menu_open = !was_open_here;
        state.workspace_header_open_menu_pane_id = if (state.workspace_header_open_menu_open) control_hit.pane_id else null;
        state.blurPaletteComposer();
        runtime.log.info(
            "workspace header chevron click menu_open={} x={d:.1} y={d:.1}",
            .{ state.workspace_header_open_menu_open, x, y },
        );
        state.noteInteraction();
        return true;
    }
    if (rectContains(control_hit.browser_rect, x, y)) {
        state.workspace_header_open_menu_open = false;
        state.workspace_header_open_menu_pane_id = null;
        state.blurPaletteComposer();
        state.toggleBrowser();
        state.noteInteraction();
        return true;
    }
    return false;
}

/// True when the mouse rests on a clickable workspace-header control (Open,
/// its chevron, Browser) or an enabled Open-menu row, so the main loop can
/// show a pointer (hand) cursor. Mirrors the precedence of
/// `handleWorkspaceHeaderPaletteMouseButton`.
pub fn workspaceHeaderWantsPointerAt(state: *const app_state.AppState, x: f32, y: f32) bool {
    if (state.project_controller.projects.items.len == 0) return false;
    if (workspaceHeaderMenuHit(state)) |menu_hit| {
        var i: usize = 0;
        while (i < menu_hit.menu_row_count) : (i += 1) {
            // Disabled rows dismiss the menu without acting, so they keep
            // the default cursor.
            if (menu_hit.menu_row_enabled[i] and rectContains(menu_hit.menu_row_rects[i], x, y)) return true;
        }
        // The open menu panel overlays the header controls; non-row panel
        // area only dismisses, so no pointer affordance there.
        if (rectContains(menu_hit.menu_panel_rect, x, y)) return false;
    }
    return workspaceHeaderControlHit(x, y) != null;
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

pub fn handleSlashCommandPaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, down: bool) bool {
    if (!down) return false;
    if (!state.slashCommandPickerActive()) return false;
    if (slash_picker_hits.row_count == 0) return false;
    if (!rectContains(slash_picker_hits.panel_rect, x, y)) return false;

    var index: usize = 0;
    while (index < slash_picker_hits.row_count) : (index += 1) {
        if (rectContains(slash_picker_hits.row_rects[index], x, y)) {
            _ = state.selectSlashCommandPickerRow(slash_picker_hits.row_indices[index]);
            _ = state.activateSlashCommandPickerSelection();
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

/// Readable transcript bodies advertise native text selection. Clickable
/// links and controls are resolved earlier by the main cursor-precedence path.
pub fn transcriptTextWantsIBeamAt(state: *app_state.AppState, x: f32, y: f32) bool {
    return transcriptMarkdownBubbleHit(state, x, y) != null;
}

pub fn transcriptLinkWantsPointerAt(state: *app_state.AppState, x: f32, y: f32) bool {
    return transcriptMarkdownBubbleLinkHit(state, x, y) != null;
}

pub fn transcriptActionWantsPointerAt(x: f32, y: f32) bool {
    return transcriptActionAt(x, y) != null;
}

const TranscriptAction = union(enum) {
    usage,
    diff_file_open: []const u8,
    diff_layout: bool,
    retry_command: []const u8,
    image_open: [:0]const u8,
};

fn transcriptActionAt(x: f32, y: f32) ?TranscriptAction {
    var index: usize = 0;
    while (index < usage_action_hit_count) : (index += 1) {
        if (rectContains(usage_action_hits[index].rect, x, y)) return .usage;
    }
    index = 0;
    while (index < diff_file_open_hit_count) : (index += 1) {
        const hit = diff_file_open_hits[index];
        if (rectContains(hit.rect, x, y)) return .{ .diff_file_open = hit.path };
    }
    index = 0;
    while (index < diff_layout_hit_count) : (index += 1) {
        const hit = diff_layout_hits[index];
        if (rectContains(hit.rect, x, y)) return .{ .diff_layout = hit.split };
    }
    index = 0;
    while (index < bang_retry_hit_count) : (index += 1) {
        const hit = bang_retry_hits[index];
        if (rectContains(hit.rect, x, y)) return .{ .retry_command = hit.command };
    }
    index = 0;
    while (index < transcript_image_hit_count) : (index += 1) {
        const hit = transcript_image_hits[index];
        if (rectContains(hit.rect, x, y)) return .{ .image_open = hit.path };
    }
    return null;
}

test "transcript action hit testing preserves usage and diff open actions" {
    resetTranscriptHitCache();
    defer resetTranscriptHitCache();
    usage_action_hits[0] = .{ .rect = .{ .x = 10.0, .y = 20.0, .w = 30.0, .h = 40.0 } };
    usage_action_hit_count = 1;
    diff_file_open_hits[0] = .{
        .rect = .{ .x = 100.0, .y = 120.0, .w = 30.0, .h = 20.0 },
        .path = "src/main.zig",
    };
    diff_file_open_hit_count = 1;

    const usage = transcriptActionAt(20.0, 30.0) orelse return error.TestExpectedEqual;
    switch (usage) {
        .usage => {},
        else => return error.TestExpectedEqual,
    }

    const open = transcriptActionAt(110.0, 130.0) orelse return error.TestExpectedEqual;
    switch (open) {
        .diff_file_open => |path| try std.testing.expectEqualStrings("src/main.zig", path),
        else => return error.TestExpectedEqual,
    }

    diff_layout_hits[0] = .{
        .rect = .{ .x = 200.0, .y = 220.0, .w = 60.0, .h = 28.0 },
        .split = true,
    };
    diff_layout_hit_count = 1;
    const layout = transcriptActionAt(230.0, 234.0) orelse return error.TestExpectedEqual;
    switch (layout) {
        .diff_layout => |split| try std.testing.expect(split),
        else => return error.TestExpectedEqual,
    }

    transcript_image_hits[0] = .{
        .rect = .{ .x = 300.0, .y = 320.0, .w = 80.0, .h = 60.0 },
        .path = "/tmp/chat-image.png",
    };
    transcript_image_hit_count = 1;
    const image = transcriptActionAt(340.0, 350.0) orelse return error.TestExpectedEqual;
    switch (image) {
        .image_open => |path| try std.testing.expectEqualStrings("/tmp/chat-image.png", path),
        else => return error.TestExpectedEqual,
    }
}

test "transcript action hit testing exposes bang command retry" {
    resetTranscriptHitCache();
    defer resetTranscriptHitCache();
    bang_retry_hits[0] = .{
        .rect = .{ .x = 20.0, .y = 30.0, .w = 60.0, .h = 24.0 },
        .command = "zig build test",
    };
    bang_retry_hit_count = 1;
    const action = transcriptActionAt(40.0, 40.0) orelse return error.TestExpectedEqual;
    switch (action) {
        .retry_command => |command| try std.testing.expectEqualStrings("zig build test", command),
        else => return error.TestExpectedEqual,
    }
}

/// True when the mouse rests on either pending-approval action.
pub fn approvalActionWantsPointerAt(x: f32, y: f32) bool {
    return approvalActionAt(x, y) != null;
}

/// Handles the approval card before pane and transcript routing because the
/// card overlays the strip between those two regions.
pub fn handleApprovalPaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, down: bool) bool {
    const action = approvalActionAt(x, y) orelse return false;
    if (!down) return true;

    if (approval_hits.pane_id) |id| _ = state.focusCurrentProjectWorkspacePane(id);
    switch (action) {
        .copy => {
            _ = state.consumeCodeCopyButtonClick(x, y);
            return true;
        },
        .approve => state.resolvePendingApproval(.approve),
        .deny => state.resolvePendingApproval(.deny),
    }
    approval_hits = .{};
    state.noteInteraction();
    return true;
}

pub fn handleTranscriptPaletteWheel(state: *app_state.AppState, x: f32, y: f32, wheel_y: f32) bool {
    if (wheel_y == 0.0) return false;
    const hit = findTranscriptHit(x, y) orelse return false;
    const pane_id = hit.pane_id;
    scrollTranscriptByWheel(state, pane_id, wheel_y);
    return true;
}

/// Fallback for precise trackpad gestures that begin over the focused chat
/// pane's lower chrome instead of the transcript body. Primary scrollable
/// widgets are offered the event first; this keeps the active transcript
/// responsive without stealing wheel input from text fields, terminals, or the
/// browser pane.
pub fn handleFocusedTranscriptPaletteWheel(state: *app_state.AppState, wheel_y: f32) bool {
    if (wheel_y == 0.0) return false;
    const pane_id = state.focusedWorkspaceChatPaneId() orelse if (state.focusedWorkspacePaneKind() == .chat) null else return false;
    scrollTranscriptByWheel(state, pane_id, wheel_y);
    return true;
}

fn scrollTranscriptByWheel(state: *app_state.AppState, pane_id: ?app_state.WorkspacePaneId, wheel_y: f32) void {
    if (pane_id) |id| _ = state.focusCurrentProjectWorkspacePane(id);
    state.transcript_controller.focused = true;
    _ = state.acknowledgeFocusedChatCompletion();
    const current = currentTranscriptScrollY(state, pane_id) orelse state.transcript_controller.palette_scroll_y;
    const delta = -wheel_y * theme.scaledUi(TRANSCRIPT_WHEEL_PIXELS);
    rememberTranscriptScroll(state, pane_id, snapTranscriptScrollY(current + delta, null));
    state.transcript_controller.auto_follow_pending = false;
    state.transcript_controller.scroll_to_bottom_frames = 0;
    state.markDirty();
}

const TranscriptMarkdownHit = struct {
    message_index: usize,
    point: chat_markdown.SelectionPoint,
};

const TranscriptSelectableBodyKind = enum {
    markdown,
    plain,
};

const TranscriptMarkdownLinkHit = struct {
    href: []const u8,
};

fn transcriptSelectableBodyKind(
    role: app_state.ChatRole,
    author: []const u8,
    body: []const u8,
    muted_body: bool,
    assistant_plain_layout: bool,
) ?TranscriptSelectableBodyKind {
    if (role == .system) {
        if (isSlashCommandResultMessage(author, body)) return .markdown;
        if (shouldRenderPaletteCommandRow(author, body) or
            isDiffSummaryMessage(author, body) or
            isUsageSummaryMessage(author, body) or
            utils.providerFailureActionProvider(body) != null)
        {
            return null;
        }
        return .plain;
    }
    if (role == .assistant and !muted_body and !assistant_plain_layout) return .markdown;
    return .plain;
}

fn transcriptSelectableBodyRect(
    column: palette.Rect,
    y: f32,
    height: f32,
    role: app_state.ChatRole,
    author: []const u8,
    body: []const u8,
) ?palette.Rect {
    if (role == .system and isSlashCommandResultMessage(author, body)) {
        const pad = theme.scaledUi(16.0);
        const body_y = y + pad + theme.scaledUi(46.0) + theme.scaledUi(12.0);
        return .{
            .x = column.x + pad,
            .y = body_y,
            .w = column.w - pad * 2.0,
            .h = @max(y + height - body_y - pad, theme.scaledUi(1.0)),
        };
    }
    if (role == .system and (shouldRenderPaletteCommandRow(author, body) or
        isDiffSummaryMessage(author, body) or
        isUsageSummaryMessage(author, body) or
        utils.providerFailureActionProvider(body) != null))
    {
        return null;
    }
    const bubble_width = if (role == .user) column.w * 0.62 else column.w;
    const bubble_x = if (role == .user) column.x + column.w - bubble_width else column.x;
    return .{
        .x = bubble_x + theme.scaledUi(14.0),
        .y = y + theme.scaledUi(34.0),
        .w = bubble_width - theme.scaledUi(28.0),
        .h = height - theme.scaledUi(42.0),
    };
}

fn buildTranscriptSelectableBodyView(
    allocator: std.mem.Allocator,
    kind: TranscriptSelectableBodyKind,
    body: []const u8,
    streaming: bool,
) !chat_markdown.BodyView {
    return switch (kind) {
        .markdown => if (streaming)
            chat_markdown.buildBodyViewStreaming(allocator, body)
        else
            chat_markdown.buildBodyView(allocator, body),
        .plain => chat_markdown.buildPlainBodyView(allocator, body),
    };
}

fn transcriptSelectableBodyHit(
    state: *app_state.AppState,
    column: palette.Rect,
    y: f32,
    height: f32,
    role: app_state.ChatRole,
    author: []const u8,
    body_raw: []const u8,
    muted_body: bool,
    assistant_plain_layout: bool,
    streaming: bool,
    message_index: usize,
    mouse_x: f32,
    mouse_y: f32,
) ?TranscriptMarkdownHit {
    const kind = transcriptSelectableBodyKind(role, author, body_raw, muted_body, assistant_plain_layout) orelse return null;
    const body_rect = transcriptSelectableBodyRect(column, y, height, role, author, body_raw) orelse return null;
    if (!rectContains(body_rect, mouse_x, mouse_y)) return null;

    const body_text = std.mem.trim(u8, body_raw, "\n\r\t ");
    var view = buildTranscriptSelectableBodyView(state.allocator, kind, body_text, streaming) catch return null;
    defer view.deinit(state.allocator);
    const pt = chat_markdown.hitTestSelectablePaletteBody(
        state.allocator,
        view,
        transcriptSelectableOptions(kind),
        body_rect,
        body_rect.w,
        mouse_x,
        mouse_y,
    ) catch return null;
    const p = pt orelse return null;
    return .{ .message_index = message_index, .point = p };
}

fn assistantTranscriptMarkdownLinkHit(
    state: *app_state.AppState,
    column: palette.Rect,
    y: f32,
    height: f32,
    role: app_state.ChatRole,
    author: []const u8,
    body_raw: []const u8,
    muted_body: bool,
    assistant_plain_layout: bool,
    streaming: bool,
    mouse_x: f32,
    mouse_y: f32,
) ?TranscriptMarkdownLinkHit {
    const kind = transcriptSelectableBodyKind(role, author, body_raw, muted_body, assistant_plain_layout) orelse return null;
    if (kind != .markdown) return null;
    const body_rect = transcriptSelectableBodyRect(column, y, height, role, author, body_raw) orelse return null;
    if (!rectContains(body_rect, mouse_x, mouse_y)) return null;

    const body_text = std.mem.trim(u8, body_raw, "\n\r\t ");
    var view = (if (streaming)
        chat_markdown.buildBodyViewStreaming(state.allocator, body_text)
    else
        chat_markdown.buildBodyView(state.allocator, body_text)) catch return null;
    defer view.deinit(state.allocator);

    const hit = chat_markdown.hitTestLinkPaletteBody(
        view,
        transcriptMarkdownOptions(),
        body_rect,
        body_rect.w,
        mouse_x,
        mouse_y,
    ) orelse return null;
    return .{ .href = hit.href };
}

fn transcriptMarkdownBubbleHit(
    state: *app_state.AppState,
    mouse_x: f32,
    mouse_y: f32,
) ?TranscriptMarkdownHit {
    const transcript_hit = findTranscriptHit(mouse_x, mouse_y) orelse return null;
    activateTranscriptHitGeometry(state, transcript_hit);
    const column = transcript_hit.column;
    const clip = transcript_hit.clip;
    if (column.w <= 0 or !rectContains(clip, mouse_x, mouse_y)) return null;

    const thread = state.currentThread();
    const scroll_y = transcript_hit.scroll_y;
    var content_y = column.y - scroll_y;

    var msg_idx: usize = 0;
    while (msg_idx < thread.messages.items.len) {
        const message = thread.messages.items[msg_idx];
        if (message.role == .system and shouldHideCursorLifecycleSystemEvent(message.author, message.body)) {
            msg_idx += 1;
            continue;
        }
        const group_end = if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body)) toolCallGroupEnd(thread.messages.items, msg_idx) else msg_idx + 1;
        if (group_end - msg_idx >= 2) {
            content_y += toolCallGroupHeight(state, thread.messages.items, msg_idx, group_end, 0, column.w) + theme.scaledUi(12.0);
            msg_idx = group_end;
            continue;
        }
        const item_h = transcriptCommittedMessageHeight(state, msg_idx, message, column.w);
        if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body)) {
            content_y += item_h + theme.scaledUi(12.0);
            msg_idx += 1;
            continue;
        }
        if (transcriptSelectableBodyHit(state, column, content_y, item_h, message.role, message.author, message.body, false, false, false, msg_idx, mouse_x, mouse_y)) |hit| {
            return hit;
        }
        content_y += item_h + theme.scaledUi(12.0);
        msg_idx += 1;
    }

    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return null;

    const base_idx = thread.messages.items.len;
    var pi: usize = 0;
    while (pi < send_state.pending_events.items.len) {
        const event = send_state.pending_events.items[pi];
        if (event.role == .system and shouldHideCursorLifecycleSystemEvent(event.author, event.body)) {
            pi += 1;
            continue;
        }
        const group_end = if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body)) toolCallGroupEnd(send_state.pending_events.items, pi) else pi + 1;
        if (group_end - pi >= 2) {
            content_y += toolCallGroupHeight(state, send_state.pending_events.items, pi, group_end, base_idx, column.w) + theme.scaledUi(12.0);
            pi = group_end;
            continue;
        }
        const pending_msg_idx = base_idx + pi;
        const item_h = transcriptMessageHeight(null, null, event.body, event.role, column.w, event.author, false);
        if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body)) {
            content_y += item_h + theme.scaledUi(12.0);
            pi += 1;
            continue;
        }
        if (transcriptSelectableBodyHit(state, column, content_y, item_h, event.role, event.author, event.body, false, false, false, pending_msg_idx, mouse_x, mouse_y)) |hit| {
            return hit;
        }
        content_y += item_h + theme.scaledUi(12.0);
        pi += 1;
    }

    const stream_text: []const u8 = send_state.partial_text.items;
    const body: []const u8 = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const stream_plain = stream_text.len > 0;
    const assistant_h = transcriptMessageHeightStream(null, null, body, .assistant, column.w, "", stream_plain, stream_text.len > 0);
    const stream_idx = base_idx + send_state.pending_events.items.len;
    return transcriptSelectableBodyHit(state, column, content_y, assistant_h, .assistant, "", body, stream_text.len == 0, stream_plain, true, stream_idx, mouse_x, mouse_y);
}

fn transcriptMarkdownBubbleLinkHit(
    state: *app_state.AppState,
    mouse_x: f32,
    mouse_y: f32,
) ?TranscriptMarkdownLinkHit {
    const transcript_hit = findTranscriptHit(mouse_x, mouse_y) orelse return null;
    activateTranscriptHitGeometry(state, transcript_hit);
    const column = transcript_hit.column;
    const clip = transcript_hit.clip;
    if (column.w <= 0 or !rectContains(clip, mouse_x, mouse_y)) return null;

    const thread = state.currentThread();
    const scroll_y = transcript_hit.scroll_y;
    var content_y = column.y - scroll_y;

    var msg_idx: usize = 0;
    while (msg_idx < thread.messages.items.len) {
        const message = thread.messages.items[msg_idx];
        if (message.role == .system and shouldHideCursorLifecycleSystemEvent(message.author, message.body)) {
            msg_idx += 1;
            continue;
        }
        const group_end = if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body)) toolCallGroupEnd(thread.messages.items, msg_idx) else msg_idx + 1;
        if (group_end - msg_idx >= 2) {
            content_y += toolCallGroupHeight(state, thread.messages.items, msg_idx, group_end, 0, column.w) + theme.scaledUi(12.0);
            msg_idx = group_end;
            continue;
        }
        const item_h = transcriptCommittedMessageHeight(state, msg_idx, message, column.w);
        if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body)) {
            content_y += item_h + theme.scaledUi(12.0);
            msg_idx += 1;
            continue;
        }
        if (assistantTranscriptMarkdownLinkHit(state, column, content_y, item_h, message.role, message.author, message.body, false, false, false, mouse_x, mouse_y)) |hit| {
            return hit;
        }
        content_y += item_h + theme.scaledUi(12.0);
        msg_idx += 1;
    }

    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return null;

    var pi: usize = 0;
    while (pi < send_state.pending_events.items.len) {
        const event = send_state.pending_events.items[pi];
        if (event.role == .system and shouldHideCursorLifecycleSystemEvent(event.author, event.body)) {
            pi += 1;
            continue;
        }
        const group_end = if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body)) toolCallGroupEnd(send_state.pending_events.items, pi) else pi + 1;
        if (group_end - pi >= 2) {
            content_y += toolCallGroupHeight(state, send_state.pending_events.items, pi, group_end, thread.messages.items.len, column.w) + theme.scaledUi(12.0);
            pi = group_end;
            continue;
        }
        const item_h = transcriptMessageHeight(null, null, event.body, event.role, column.w, event.author, false);
        if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body)) {
            content_y += item_h + theme.scaledUi(12.0);
            pi += 1;
            continue;
        }
        if (assistantTranscriptMarkdownLinkHit(state, column, content_y, item_h, event.role, event.author, event.body, false, false, false, mouse_x, mouse_y)) |hit| {
            return hit;
        }
        content_y += item_h + theme.scaledUi(12.0);
        pi += 1;
    }

    const stream_text: []const u8 = send_state.partial_text.items;
    const body: []const u8 = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const stream_plain = stream_text.len > 0;
    const assistant_h = transcriptMessageHeightStream(null, null, body, .assistant, column.w, "", stream_plain, stream_text.len > 0);
    return assistantTranscriptMarkdownLinkHit(state, column, content_y, assistant_h, .assistant, "", body, stream_text.len == 0, stream_plain, true, mouse_x, mouse_y);
}

fn localFileHref(href: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, href, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    if (std.mem.startsWith(u8, trimmed, "file://localhost/") or
        std.mem.startsWith(u8, trimmed, "file:///"))
    {
        return trimmed;
    }
    if (std.mem.startsWith(u8, trimmed, "file://")) return null;
    if (std.mem.indexOf(u8, trimmed, "://") != null) return null;
    if (std.mem.startsWith(u8, trimmed, "mailto:")) return null;
    return trimmed;
}

fn webHref(href: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, href, &std.ascii.whitespace);
    if (std.ascii.startsWithIgnoreCase(trimmed, "https://") or
        std.ascii.startsWithIgnoreCase(trimmed, "http://"))
    {
        return trimmed;
    }
    return null;
}

pub fn handleTranscriptPaletteMouseMotion(state: *app_state.AppState) void {
    if (transcript_scrollbar_drag_active and transcript_scrollbar_max_scroll > 1.0 and transcript_scrollbar_track.h > 0.0) {
        const pane_id = transcript_scrollbar_drag_pane_id;
        const target = scrollFromThumbY(
            transcript_scrollbar_track,
            transcript_scrollbar_thumb.h,
            transcript_scrollbar_max_scroll,
            state.transcript_controller.palette_mouse_y,
            transcript_scrollbar_drag_grab_offset,
        );
        rememberTranscriptScroll(state, pane_id, snapTranscriptScrollY(target, transcript_scrollbar_max_scroll));
        state.transcript_controller.auto_follow_pending = false;
        state.transcript_controller.scroll_to_bottom_frames = 0;
        state.markDirty();
        return;
    }
    if (!state.transcriptMarkdownSelectionDragging()) return;
    const hit = transcriptMarkdownBubbleHit(state, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y) orelse return;
    state.updateTranscriptMarkdownSelection(hit.message_index, hit.point);
}

fn applyTranscriptMarkdownMulticlick(state: *app_state.AppState, hit: TranscriptMarkdownHit, clicks: usize) void {
    if (clicks < 2) return;
    const snap = transcriptMarkdownMessageSnapshot(state, hit.message_index) orelse return;
    var view = buildTranscriptSelectableBodyView(state.allocator, snap.kind, snap.body_trim, snap.streaming) catch return;
    defer view.deinit(state.allocator);
    const md = transcriptSelectableOptions(snap.kind);
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

    state.transcript_controller.focused = true;
    _ = state.acknowledgeFocusedChatCompletion();

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
                state.transcript_controller.auto_follow_pending = false;
                state.transcript_controller.scroll_to_bottom_frames = 0;
                state.markDirty();
            }
            return true;
        }
    }

    if (clicks <= 1) {
        if (transcriptActionAt(x, y)) |action| {
            switch (action) {
                .usage => _ = state.showCurrentProviderUsage(),
                .diff_file_open => |path| state.openTranscriptFileReference(path),
                .diff_layout => |split| state.setDiffLayoutPreference(if (split) .split else .stacked),
                .retry_command => |command| state.retryBangCommand(command),
                .image_open => |path| state.openImageModal(path),
            }
            return true;
        }
    }
    if (clicks <= 1 and state.consumeCodeCopyButtonClick(x, y)) {
        return true;
    }
    if (clicks <= 1 and state.consumeBackgroundTaskActionClick(x, y)) {
        return true;
    }
    if (clicks <= 1 and state.consumeCardToggleClick(x, y)) {
        return true;
    }
    if (clicks <= 1) {
        if (transcriptMarkdownBubbleLinkHit(state, x, y)) |link_hit| {
            if (localFileHref(link_hit.href)) |file_href| {
                state.blurPaletteComposer();
                state.clearTranscriptMarkdownSelection();
                state.openTranscriptFileReference(file_href);
                return true;
            }
            if (webHref(link_hit.href)) |web_href| {
                state.blurPaletteComposer();
                state.clearTranscriptMarkdownSelection();
                state.openConfiguredWebLink(web_href);
                return true;
            }
        }
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

// Pending provider approval card above the composer.
fn renderApprovalCard(state: *app_state.AppState, rect: palette.Rect, approval: app_state.PendingApproval, pane_id: ?app_state.WorkspacePaneId) void {
    const pad = theme.scaledUi(16.0);
    const button_h = theme.scaledUi(36.0);
    const button_w = theme.scaledUi(96.0);
    const gap = theme.scaledUi(12.0);
    queueRounded(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(12.0));
    queueBorder(state, rect, paletteColor(theme.COLOR_GREEN), theme.scaledUi(12.0), theme.scaledUi(1.0));
    queueText(state, .{ .x = rect.x + pad, .y = rect.y + theme.scaledUi(12.0), .w = rect.w - pad * 2.0, .h = theme.scaledUi(20.0) }, approval.title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), rect);
    queueText(state, .{ .x = rect.x + pad, .y = rect.y + theme.scaledUi(38.0), .w = rect.w - pad * 2.0, .h = @max(rect.h - button_h - pad * 2.0 - theme.scaledUi(42.0), theme.scaledUi(44.0)) }, approval.body, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), rect);

    const deny_rect = palette.Rect{ .x = rect.x + rect.w - pad - button_w * 2.0 - gap, .y = rect.y + rect.h - pad - button_h, .w = button_w, .h = button_h };
    const approve_rect = palette.Rect{ .x = deny_rect.x + button_w + gap, .y = deny_rect.y, .w = button_w, .h = button_h };
    const copy_rect = palette.Rect{ .x = deny_rect.x - gap - theme.scaledUi(72.0), .y = deny_rect.y, .w = theme.scaledUi(72.0), .h = button_h };
    const copy_hovered = rectContains(copy_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    const deny_hovered = rectContains(deny_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    const approve_hovered = rectContains(approve_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    queueRounded(state, copy_rect, paletteColor(if (copy_hovered) theme.lighten(theme.COLOR_PANEL_MUTED, 0.10) else theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0));
    queueBorder(state, copy_rect, paletteColor(if (copy_hovered) theme.COLOR_TEXT_MUTED else theme.borderMuted()), theme.scaledUi(8.0), theme.scaledUi(1.0));
    queueApprovalButtonLabel(state, copy_rect, "Copy", paletteColor(if (copy_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED));
    state.recordTranscriptCopyHit(copy_rect, approval.body, toolCopyIdentity(@intFromPtr(approval.body.ptr), approval.body));
    queueRounded(state, deny_rect, paletteColor(if (deny_hovered) theme.lighten(theme.COLOR_PANEL_MUTED, 0.10) else theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0));
    queueBorder(state, deny_rect, paletteColor(if (deny_hovered) theme.COLOR_TEXT_MUTED else theme.borderMuted()), theme.scaledUi(8.0), theme.scaledUi(1.0));
    queueApprovalButtonLabel(state, deny_rect, "Decline", paletteColor(if (deny_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED));
    queueRounded(state, approve_rect, paletteColor(if (approve_hovered) theme.lighten(theme.COLOR_GREEN, 0.08) else theme.COLOR_GREEN), theme.scaledUi(8.0));
    queueApprovalButtonLabel(state, approve_rect, "Allow", paletteColor(theme.COLOR_WHITE));
    approval_hits = .{ .pane_id = pane_id, .copy_rect = copy_rect, .approve_rect = approve_rect, .deny_rect = deny_rect };
}

fn approvalActionAt(x: f32, y: f32) ?ApprovalAction {
    if (rectContains(approval_hits.copy_rect, x, y)) return .copy;
    if (rectContains(approval_hits.approve_rect, x, y)) return .approve;
    if (rectContains(approval_hits.deny_rect, x, y)) return .deny;
    return null;
}

test "approval actions use their rendered button rectangles" {
    const previous = approval_hits;
    defer approval_hits = previous;
    approval_hits = .{
        .copy_rect = .{ .x = 212.0, .y = 40.0, .w = 64.0, .h = 36.0 },
        .approve_rect = .{ .x = 120.0, .y = 40.0, .w = 80.0, .h = 36.0 },
        .deny_rect = .{ .x = 28.0, .y = 40.0, .w = 80.0, .h = 36.0 },
    };

    try std.testing.expectEqual(ApprovalAction.copy, approvalActionAt(244.0, 58.0).?);
    try std.testing.expectEqual(ApprovalAction.approve, approvalActionAt(160.0, 58.0).?);
    try std.testing.expectEqual(ApprovalAction.deny, approvalActionAt(68.0, 58.0).?);
    try std.testing.expect(approvalActionAt(114.0, 58.0) == null);
}

test "transcript body selection includes user assistant and ordinary system text" {
    try std.testing.expectEqual(TranscriptSelectableBodyKind.plain, transcriptSelectableBodyKind(.user, "You", "literal *prompt*", false, false).?);
    try std.testing.expectEqual(TranscriptSelectableBodyKind.markdown, transcriptSelectableBodyKind(.assistant, "Assistant", "**answer**", false, false).?);
    try std.testing.expectEqual(TranscriptSelectableBodyKind.plain, transcriptSelectableBodyKind(.system, "Notice", "Connection restored", false, false).?);
    try std.testing.expectEqual(TranscriptSelectableBodyKind.plain, transcriptSelectableBodyKind(.assistant, "Assistant", "stream tail", false, true).?);
}

test "bounded transcript controls stay outside drag selection" {
    try std.testing.expect(transcriptSelectableBodyKind(.system, "Ran command", "Command:\nzig build", false, false) == null);
    try std.testing.expect(transcriptSelectableBodyKind(.system, "Changed files", utils.PERSISTED_DIFF_MARKER, false, false) == null);
}

fn queueApprovalButtonLabel(state: *app_state.AppState, rect: palette.Rect, label: []const u8, color: palette.Color) void {
    const font_size = theme.scaledUi(13.0);
    const label_w = text_measure.textWidth(.ui, font_size, label);
    const label_h = theme.scaledUi(18.0);
    queueChromeLabel(state, .{
        .x = rect.x + @max((rect.w - label_w) * 0.5, 0.0),
        .y = rect.y + @max((rect.h - label_h) * 0.5, 0.0),
        .w = @min(label_w, rect.w),
        .h = label_h,
    }, label, color, font_size, rect);
}

/// Selects every directly selectable transcript body in the current thread.
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

    var last_view = buildTranscriptSelectableBodyView(state.allocator, last_snap.kind, last_snap.body_trim, last_snap.streaming) catch return false;
    defer last_view.deinit(state.allocator);
    const md = transcriptSelectableOptions(last_snap.kind);
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
    kind: TranscriptSelectableBodyKind,
    streaming: bool,
} {
    const column = state.transcript_controller.palette_column;
    if (column.w <= 0.0) return null;

    const thread = state.currentThread();
    const n = thread.messages.items.len;
    if (message_index < n) {
        const m = thread.messages.items[message_index];
        if (m.role == .system and shouldHideCursorLifecycleSystemEvent(m.author, m.body)) return null;
        const kind = transcriptSelectableBodyKind(m.role, m.author, m.body, false, false) orelse return null;
        const body_trim = std.mem.trim(u8, m.body, "\n\r\t ");
        const body_rect = transcriptSelectableBodyRect(column, 0.0, 100000.0, m.role, m.author, m.body) orelse return null;
        return .{ .body_trim = body_trim, .body_inner_w = @max(body_rect.w, theme.scaledUi(80.0)), .kind = kind, .streaming = false };
    }

    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return null;
    const pi = message_index - n;
    if (pi < send_state.pending_events.items.len) {
        const ev = send_state.pending_events.items[pi];
        if (ev.role == .system and shouldHideCursorLifecycleSystemEvent(ev.author, ev.body)) return null;
        const kind = transcriptSelectableBodyKind(ev.role, ev.author, ev.body, false, false) orelse return null;
        const body_trim = std.mem.trim(u8, ev.body, "\n\r\t ");
        const body_rect = transcriptSelectableBodyRect(column, 0.0, 100000.0, ev.role, ev.author, ev.body) orelse return null;
        return .{ .body_trim = body_trim, .body_inner_w = @max(body_rect.w, theme.scaledUi(80.0)), .kind = kind, .streaming = false };
    }
    if (pi != send_state.pending_events.items.len) return null;

    const stream_text: []const u8 = send_state.partial_text.items;
    const body: []const u8 = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const body_trim = std.mem.trim(u8, body, "\n\r\t ");
    const inner = @max(column.w - theme.scaledUi(28.0), theme.scaledUi(80.0));
    return .{
        .body_trim = body_trim,
        .body_inner_w = inner,
        .kind = .plain,
        .streaming = stream_text.len > 0,
    };
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
        var view = try buildTranscriptSelectableBodyView(state.allocator, snap.kind, snap.body_trim, snap.streaming);
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
            transcriptSelectableOptions(snap.kind),
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
            transcriptSelectableOptions(snap.kind),
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

fn paneIdEqual(a: ?app_state.WorkspacePaneId, b: ?app_state.WorkspacePaneId) bool {
    if (a) |left| {
        return if (b) |right| left == right else false;
    }
    return b == null;
}

pub fn resetWorkspaceHeaderHitCache() void {
    workspace_header_hit_count = 0;
}

fn appendWorkspaceHeaderHit(pane_id: ?app_state.WorkspacePaneId, rect: palette.Rect) *WorkspaceHeaderHitCache {
    const index = if (workspace_header_hit_count < workspace_header_hits.len) blk: {
        const next = workspace_header_hit_count;
        workspace_header_hit_count += 1;
        break :blk next;
    } else workspace_header_hits.len - 1;
    workspace_header_hits[index] = .{ .used = true, .pane_id = pane_id, .header_rect = rect };
    return &workspace_header_hits[index];
}

fn workspaceHeaderMenuHit(state: *const app_state.AppState) ?*WorkspaceHeaderHitCache {
    if (!state.workspace_header_open_menu_open) return null;
    var i = workspace_header_hit_count;
    while (i > 0) {
        i -= 1;
        if (!workspace_header_hits[i].used) continue;
        if (paneIdEqual(workspace_header_hits[i].pane_id, state.workspace_header_open_menu_pane_id)) {
            return &workspace_header_hits[i];
        }
    }
    return null;
}

fn workspaceHeaderControlHit(x: f32, y: f32) ?*WorkspaceHeaderHitCache {
    var i = workspace_header_hit_count;
    while (i > 0) {
        i -= 1;
        const hit = &workspace_header_hits[i];
        if (!hit.used) continue;
        if (rectContains(hit.open_main_rect, x, y) or
            rectContains(hit.chevron_rect, x, y) or
            rectContains(hit.browser_rect, x, y))
        {
            return hit;
        }
    }
    return null;
}

fn renderHeader(state: *app_state.AppState, rect: palette.Rect, right_reserve: f32, pane_id: ?app_state.WorkspacePaneId) void {
    const header_hit = appendWorkspaceHeaderHit(pane_id, rect);

    queueRect(state, rect, paletteColor(theme.background()));
    queueRect(state, .{ .x = rect.x, .y = rect.y + rect.h - 1.0, .w = rect.w, .h = 1.0 }, paletteColor(theme.borderMuted()));

    const padding_x = theme.scaledUi(28.0);
    const thread = state.currentThread();
    const title_src: []const u8 = if (thread.committed)
        if (thread.title.len > 0) thread.title else "New chat"
    else
        "New chat";

    const button_h = theme.scaledUi(30.0);
    const button_gap = theme.scaledUi(WORKSPACE_HEADER_CONTROL_GAP_CSS);
    const title_gap = theme.scaledUi(16.0);
    const label_font = theme.scaledUi(14.0);
    const title_font = theme.scaledUi(18.0);

    const open_folder = state.defaultOpenShowsFolderIcon();
    const open_tex = state.defaultOpenIconTexture();
    const open_main_w = theme.scaledUi(WORKSPACE_HEADER_ICON_CONTROL_CSS);
    const chevron_w = theme.scaledUi(WORKSPACE_HEADER_CHEVRON_CONTROL_CSS);
    const browser_w = theme.scaledUi(WORKSPACE_HEADER_ICON_CONTROL_CSS);
    const open_combo_w = open_main_w + chevron_w;
    const actions_w = open_combo_w + button_gap + browser_w;

    const actions_right = rect.x + rect.w - right_reserve - button_gap;
    const actions_x = actions_right - actions_w;
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

    const mx = state.transcript_controller.palette_mouse_x;
    const my = state.transcript_controller.palette_mouse_y;
    const mouse_ok = state.transcript_controller.palette_mouse_in_workspace;

    const actions_y = rect.y + @max((rect.h - button_h) * 0.5, theme.scaledUi(4.0));
    const open_combo_x = actions_x;
    const open_main_rect = palette.Rect{ .x = open_combo_x, .y = actions_y, .w = open_main_w, .h = button_h };
    const chevron_rect = palette.Rect{ .x = open_combo_x + open_main_w, .y = actions_y, .w = chevron_w, .h = button_h };
    const browser_rect = palette.Rect{ .x = open_combo_x + open_combo_w + button_gap, .y = actions_y, .w = browser_w, .h = button_h };

    header_hit.open_main_rect = open_main_rect;
    header_hit.chevron_rect = chevron_rect;
    header_hit.browser_rect = browser_rect;

    const open_main_hover = mouse_ok and rectContains(open_main_rect, mx, my);
    const chevron_hover = mouse_ok and rectContains(chevron_rect, mx, my);
    const browser_hover = mouse_ok and rectContains(browser_rect, mx, my);

    const icon_slot = theme.scaledUi(16.0);
    const icon_x = open_main_rect.x + (open_main_rect.w - icon_slot) * 0.5;
    const icon_cy = open_main_rect.y + button_h * 0.5;
    const text_color_open: palette.Color = paletteColor(if (!state.canRunDefaultOpenAction())
        theme.COLOR_TEXT_MUTED
    else if (open_main_hover)
        theme.COLOR_WHITE
    else
        theme.COLOR_TEXT_MUTED);
    if (open_folder) {
        const folder_w = theme.scaledUi(13.0);
        queueWorkspaceHeaderFolderIcon(state, open_main_rect.x + (open_main_rect.w - folder_w) * 0.5, icon_cy, text_color_open);
    } else if (open_tex) |cached| {
        const scaled = runtime.scaledImageSize(cached.width, cached.height, icon_slot, icon_slot);
        queueImage(state, .{
            .x = icon_x + (icon_slot - scaled[0]) * 0.5,
            .y = open_main_rect.y + (button_h - scaled[1]) * 0.5,
            .w = scaled[0],
            .h = scaled[1],
        }, cached, rect);
    } else {
        queueIconText(state, .{
            .x = open_main_rect.x + (open_main_rect.w - icon_slot) * 0.5,
            .y = open_main_rect.y + (open_main_rect.h - icon_slot) * 0.5,
            .w = icon_slot,
            .h = icon_slot,
        }, NF_COD_LINK_EXTERNAL, text_color_open, icon_slot, rect);
    }

    const chevron_size = theme.scaledUi(12.0);
    queueIconText(state, .{
        .x = chevron_rect.x + (chevron_rect.w - chevron_size) * 0.5,
        .y = chevron_rect.y + (chevron_rect.h - chevron_size) * 0.5,
        .w = chevron_size,
        .h = chevron_size,
    }, NF_COD_CHEVRON_DOWN, paletteColor(if (chevron_hover) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE), chevron_size, rect);

    const globe_size = theme.scaledUi(16.0);
    const browser_cy = browser_rect.y + browser_rect.h * 0.5;
    globe_icon.queue(
        state,
        browser_rect.x + browser_rect.w * 0.5,
        browser_cy,
        globe_size,
        paletteColor(if (browser_hover) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED),
    );

    if (!state.workspace_header_open_menu_open or !paneIdEqual(state.workspace_header_open_menu_pane_id, pane_id)) return;

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
        labels[count] = if (utils.configuredEditorDisplayName()) |name|
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
    header_hit.menu_panel_rect = .{ .x = menu_x, .y = menu_y, .w = menu_w, .h = menu_h };

    const menu_clip = header_hit.menu_panel_rect;
    queueRounded(state, header_hit.menu_panel_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(12.0));
    queueBorder(state, header_hit.menu_panel_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(12.0), theme.scaledUi(1.0));

    header_hit.menu_row_count = count;
    var ri: usize = 0;
    var ry = menu_y + menu_pad;
    while (ri < count) : (ri += 1) {
        header_hit.menu_row_kind[ri] = kinds[ri];
        header_hit.menu_row_enabled[ri] = enabled[ri];

        const rr = palette.Rect{
            .x = menu_x + theme.scaledUi(4.0),
            .y = ry,
            .w = menu_w - theme.scaledUi(8.0),
            .h = menu_row_h,
        };
        header_hit.menu_row_rects[ri] = rr;

        const row_hover = mouse_ok and enabled[ri] and rectContains(rr, mx, my);
        if (row_hover) {
            queueRounded(state, rr, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(8.0));
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
    queueText(state, .{ .x = x, .y = y, .w = rect.w - theme.scaledUi(88.0), .h = theme.scaledUi(38.0) }, "No workspaces yet", paletteColor(theme.COLOR_WHITE), theme.scaledUi(28.0), rect);
    y += theme.scaledUi(42.0);
    queueText(state, .{ .x = x, .y = y, .w = rect.w - theme.scaledUi(88.0), .h = theme.scaledUi(28.0) }, "Use the workspace rail to add a folder and start chatting.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(16.0), rect);
}

/// While the current thread is streaming, keep `transcript_auto_follow_pending` on when the viewport
/// is at (or near) the tail, or during the initial scroll-to-bottom animation. Wheel on the
/// transcript clears the latch; scrolling back within ~72px of the bottom turns it on again.
fn updateTranscriptAutoFollowPalette(state: *app_state.AppState, has_pending_stream: bool, max_scroll: f32, scroll_y: f32) void {
    if (!has_pending_stream) {
        state.transcript_controller.auto_follow_pending = false;
        return;
    }
    if (state.transcript_controller.scroll_to_bottom_frames > 0 or transcriptScrollNearBottom(scroll_y, max_scroll)) {
        state.transcript_controller.auto_follow_pending = true;
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
    return null;
}

fn activateTranscriptHitGeometry(state: *app_state.AppState, hit: TranscriptHit) void {
    state.transcript_controller.palette_column = hit.column;
    state.transcript_controller.palette_clip = hit.clip;
    state.transcript_controller.palette_scroll_y = hit.scroll_y;
}

fn appendTranscriptHit(hit: TranscriptHit) void {
    if (transcript_hit_count >= transcript_hits.len) return;
    transcript_hits[transcript_hit_count] = hit;
    transcript_hit_count += 1;
}

test "transcript hit geometry remains pane-local through scrolling clips" {
    resetTranscriptHitCache();
    defer resetTranscriptHitCache();
    appendTranscriptHit(.{
        .pane_id = 11,
        .rect = .{ .x = 10.0, .y = 20.0, .w = 300.0, .h = 240.0 },
        .column = .{ .x = 30.0, .y = 48.0, .w = 260.0, .h = 190.0 },
        .clip = .{ .x = 10.0, .y = 20.0, .w = 300.0, .h = 240.0 },
        .scroll_y = 72.0,
    });
    appendTranscriptHit(.{
        .pane_id = 12,
        .rect = .{ .x = 10.0, .y = 280.0, .w = 300.0, .h = 240.0 },
        .column = .{ .x = 30.0, .y = 308.0, .w = 260.0, .h = 190.0 },
        .clip = .{ .x = 10.0, .y = 280.0, .w = 300.0, .h = 240.0 },
        .scroll_y = 144.0,
    });

    const first = findTranscriptHit(100.0, 100.0).?;
    try std.testing.expectEqual(@as(?app_state.WorkspacePaneId, 11), first.pane_id);
    try std.testing.expectEqual(@as(f32, 48.0), first.column.y);
    try std.testing.expectEqual(@as(f32, 72.0), first.scroll_y);

    clipTranscriptHitCache(.{ .x = 0.0, .y = 60.0, .w = 400.0, .h = 200.0 });
    try std.testing.expectEqual(@as(usize, 1), transcript_hit_count);
    const clipped = findTranscriptHit(100.0, 100.0).?;
    try std.testing.expectEqual(@as(f32, 48.0), clipped.column.y);
    try std.testing.expectEqual(@as(f32, 60.0), clipped.clip.y);
    try std.testing.expect(findTranscriptHit(100.0, 300.0) == null);
}

fn renderTranscript(state: *app_state.AppState, rect: palette.Rect, pane_id: ?app_state.WorkspacePaneId) void {
    // Bubble column comes from the same shared formula as the composer card so
    // transcript content and the prompt box stay width-aligned at every size.
    const content_column = chatContentColumn(rect.x, rect.w);
    const column = snapRect(palette.Rect{ .x = content_column.x, .y = rect.y + theme.scaledUi(28.0), .w = content_column.w, .h = @max(rect.h - theme.scaledUi(42.0), 1.0) });
    // Clip to full transcript body (same x/w as layout rect) so GL text and bubbles
    // stay below the workspace header when scrolled.
    const clip = rect;
    const active_geometry = paneOwnsActiveChatState(state, pane_id);
    if (active_geometry) {
        state.transcript_controller.palette_column = column;
        state.transcript_controller.palette_clip = clip;
    }

    const thread = state.currentThread();

    if (thread.messages.items.len == 0 and !thread.isSendPendingForUi() and state.currentThreadPendingSlashCommandLabel() == null) {
        if (active_geometry) state.transcript_controller.palette_scroll_y = 0.0;
        rememberTranscriptScroll(state, pane_id, 0.0);
        appendTranscriptHit(.{ .pane_id = pane_id, .rect = rect, .column = column, .clip = clip });
        queueText(state, .{ .x = column.x, .y = column.y, .w = column.w, .h = theme.scaledUi(30.0) }, "No messages yet", paletteColor(theme.COLOR_WHITE), theme.scaledUi(20.0), clip);
        queueText(state, .{ .x = column.x, .y = column.y + theme.scaledUi(32.0), .w = column.w, .h = theme.scaledUi(26.0) }, "Choose a provider, type a prompt below, and start the first chat for this directory.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(15.0), clip);
        return;
    }

    const content_height = transcriptContentHeight(state, thread, column.w);
    const max_scroll = @max(0.0, content_height - column.h);
    const has_pending_stream = state.hasPendingStream() or state.currentThreadPendingSlashCommandLabel() != null;

    var scroll_y = snapTranscriptScrollY(currentTranscriptScrollY(state, pane_id) orelse max_scroll, max_scroll);

    if (paneOwnsActiveChatState(state, pane_id)) {
        const pi = state.project_controller.selected_index;
        const ti = state.currentProject().selected_thread_index;
        if (state.transcript_controller.scroll_pending_track_project != pi or state.transcript_controller.scroll_pending_track_thread != ti) {
            state.transcript_controller.pending_scroll_px = 0;
            state.transcript_controller.pending_page_steps = 0;
            state.transcript_controller.scroll_pending_track_project = pi;
            state.transcript_controller.scroll_pending_track_thread = ti;
        }

        if (state.transcript_controller.pending_scroll_px != 0.0) {
            scroll_y = snapTranscriptScrollY(scroll_y + state.transcript_controller.pending_scroll_px, max_scroll);
            state.transcript_controller.pending_scroll_px = 0.0;
        }
        if (state.transcript_controller.pending_page_steps != 0) {
            const page_h = column.h * TRANSCRIPT_PAGE_VIEW_FRAC;
            scroll_y = snapTranscriptScrollY(scroll_y + @as(f32, @floatFromInt(state.transcript_controller.pending_page_steps)) * page_h, max_scroll);
            state.transcript_controller.pending_page_steps = 0;
        }
    }

    updateTranscriptAutoFollowPalette(state, has_pending_stream, max_scroll, scroll_y);

    if (state.transcript_controller.auto_follow_pending or state.transcript_controller.scroll_to_bottom_frames > 0) {
        scroll_y = max_scroll;
    }
    if (state.transcript_controller.scroll_to_bottom_frames > 0) {
        state.transcript_controller.scroll_to_bottom_frames -= 1;
    }
    if (state.transcript_controller.scroll_to_bottom_frames == 0 and !has_pending_stream) {
        state.transcript_controller.auto_follow_pending = false;
    }
    rememberTranscriptScroll(state, pane_id, scroll_y);
    if (active_geometry) state.transcript_controller.palette_scroll_y = scroll_y;

    var content_y = renderCommittedTranscript(state, thread, column, scroll_y, clip);

    content_y = renderPendingSlashCommand(state, column, content_y, clip);
    renderPendingTranscriptStream(state, thread, column, content_y, clip, thread.messages.items.len);

    if (max_scroll > 1.0) {
        const track = snapRect(palette.Rect{ .x = rect.x + rect.w - theme.scaledUi(12.0), .y = column.y, .w = theme.scaledUi(4.0), .h = column.h });
        const thumb_h = @max(theme.scaledUi(32.0), column.h * (column.h / content_height));
        const thumb_y = track.y + (track.h - thumb_h) * (scroll_y / max_scroll);
        const thumb_rect = snapRect(.{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h });
        queueRounded(state, track, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 160)), theme.scaledUi(2.0));
        queueRounded(state, thumb_rect, paletteColor(theme.withAlpha(theme.COLOR_TEXT_MUTED, 210)), theme.scaledUi(2.0));
        transcript_scrollbar_track = track;
        transcript_scrollbar_thumb = thumb_rect;
        transcript_scrollbar_max_scroll = max_scroll;
        appendTranscriptHit(.{ .pane_id = pane_id, .rect = rect, .column = column, .clip = clip, .scroll_y = scroll_y, .track = track, .thumb = thumb_rect, .max_scroll = max_scroll });
    } else {
        transcript_scrollbar_track = .{};
        transcript_scrollbar_thumb = .{};
        transcript_scrollbar_max_scroll = 0.0;
        appendTranscriptHit(.{ .pane_id = pane_id, .rect = rect, .column = column, .clip = clip, .scroll_y = scroll_y });
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
    const committed_height = if (ensureTranscriptLayout(state, width))
        thread.transcript_layout_committed_height
    else
        transcriptCommittedHeightUncached(state, thread, width);
    var total = theme.scaledUi(4.0) + committed_height;
    total += transcriptPendingSlashCommandHeight(state, width);
    total += transcriptPendingStreamHeight(state, thread, width);
    return total;
}

fn transcriptCommittedHeightUncached(state: *app_state.AppState, thread: anytype, width: f32) f32 {
    var total: f32 = 0.0;
    var message_index: usize = 0;
    while (message_index < thread.messages.items.len) {
        const message = thread.messages.items[message_index];
        if (message.role == .system and shouldHideCursorLifecycleSystemEvent(message.author, message.body)) {
            message_index += 1;
            continue;
        }
        const group_end = if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body))
            toolCallGroupEnd(thread.messages.items, message_index)
        else
            message_index + 1;
        if (group_end - message_index >= 2) {
            total += toolCallGroupHeight(state, thread.messages.items, message_index, group_end, 0, width) + theme.scaledUi(12.0);
            message_index = group_end;
            continue;
        }
        total += transcriptCommittedMessageHeight(state, message_index, message, width) + theme.scaledUi(12.0);
        message_index += 1;
    }
    return total;
}

fn transcriptLayoutVariantHash(state: *app_state.AppState) u64 {
    var hasher = std.hash.Wyhash.init(0x7A4E_5C81_91D2_0B33);
    const tool_group_preference: u8 = @intFromEnum(state.app_config.tool_call_group_preference);
    const diff_layout_preference: u8 = @intFromEnum(state.app_config.diff_layout_preference);
    hasher.update(std.mem.asBytes(&tool_group_preference));
    hasher.update(std.mem.asBytes(&diff_layout_preference));
    hasher.update(std.mem.asBytes(&state.app_config.tool_call_groups_last_expanded));

    var iterator = state.expanded_cards.iterator();
    while (iterator.next()) |entry| {
        hasher.update(std.mem.asBytes(entry.key_ptr));
        hasher.update(std.mem.asBytes(entry.value_ptr));
    }
    return hasher.final();
}

fn ensureTranscriptLayout(state: *app_state.AppState, width: f32) bool {
    const thread = state.currentThreadMutable();
    const scale = theme.uiScaleFactor();
    const variant_hash = transcriptLayoutVariantHash(state);
    if (thread.transcript_layout_valid and
        thread.transcript_layout_message_count == thread.messages.items.len and
        @abs(thread.transcript_layout_width - width) <= 0.5 and
        @abs(thread.transcript_layout_scale - scale) <= 0.001 and
        thread.transcript_layout_variant_hash == variant_hash)
    {
        return true;
    }

    thread.transcript_layout_valid = false;
    thread.transcript_layout_items.clearRetainingCapacity();
    thread.transcript_layout_items.ensureTotalCapacity(state.allocator, thread.messages.items.len) catch return false;

    var top: f32 = 0.0;
    var message_index: usize = 0;
    while (message_index < thread.messages.items.len) {
        const message = thread.messages.items[message_index];
        if (message.role == .system and shouldHideCursorLifecycleSystemEvent(message.author, message.body)) {
            message_index += 1;
            continue;
        }
        const group_end = if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body))
            toolCallGroupEnd(thread.messages.items, message_index)
        else
            message_index + 1;
        const height = if (group_end - message_index >= 2)
            toolCallGroupHeight(state, thread.messages.items, message_index, group_end, 0, width)
        else
            transcriptCommittedMessageHeight(state, message_index, message, width);
        thread.transcript_layout_items.appendAssumeCapacity(.{
            .message_index = message_index,
            .group_end = group_end,
            .top = top,
            .height = height,
        });
        top += height + theme.scaledUi(12.0);
        message_index = group_end;
    }

    thread.transcript_layout_width = width;
    thread.transcript_layout_scale = scale;
    thread.transcript_layout_variant_hash = variant_hash;
    thread.transcript_layout_message_count = thread.messages.items.len;
    thread.transcript_layout_committed_height = top;
    thread.transcript_layout_valid = true;
    return true;
}

fn firstVisibleTranscriptLayoutItem(items: []const chat_types.TranscriptLayoutItem, scroll_y: f32) usize {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const item = items[middle];
        if (item.top + item.height < scroll_y) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

test "transcript layout lookup starts at the first row intersecting the viewport" {
    const items: [3]chat_types.TranscriptLayoutItem = .{
        .{ .message_index = 0, .group_end = 1, .top = 0.0, .height = 40.0 },
        .{ .message_index = 1, .group_end = 2, .top = 52.0, .height = 30.0 },
        .{ .message_index = 2, .group_end = 3, .top = 94.0, .height = 50.0 },
    };
    try std.testing.expectEqual(@as(usize, 0), firstVisibleTranscriptLayoutItem(&items, 40.0));
    try std.testing.expectEqual(@as(usize, 1), firstVisibleTranscriptLayoutItem(&items, 41.0));
    try std.testing.expectEqual(@as(usize, 2), firstVisibleTranscriptLayoutItem(&items, 90.0));
    try std.testing.expectEqual(items.len, firstVisibleTranscriptLayoutItem(&items, 145.0));
}

// Renders the visible committed transcript rows from cached layout positions.
fn renderCommittedTranscript(
    state: *app_state.AppState,
    thread: anytype,
    column: palette.Rect,
    scroll_y: f32,
    clip: palette.Rect,
) f32 {
    if (!ensureTranscriptLayout(state, column.w)) {
        return renderCommittedTranscriptUncached(state, thread, column, scroll_y, clip);
    }

    const items = thread.transcript_layout_items.items;
    var layout_index = firstVisibleTranscriptLayoutItem(items, scroll_y);
    const visible_bottom = scroll_y + column.h;
    while (layout_index < items.len) : (layout_index += 1) {
        const item = items[layout_index];
        if (item.top > visible_bottom) break;
        const content_y = column.y - scroll_y + item.top;
        const message = thread.messages.items[item.message_index];
        if (item.group_end - item.message_index >= 2) {
            const last = thread.messages.items[item.group_end - 1];
            renderToolCallGroup(state, thread.messages.items, item.message_index, item.group_end, 0, column, content_y, item.height, clip, thread.backgroundCommandIsRunning(last.body), null);
        } else {
            renderTranscriptMessage(state, thread, column, content_y, item.height, message, clip, item.message_index);
        }
    }
    return column.y - scroll_y + thread.transcript_layout_committed_height;
}

// Renders committed transcript rows when allocating the layout cache fails.
fn renderCommittedTranscriptUncached(
    state: *app_state.AppState,
    thread: anytype,
    column: palette.Rect,
    scroll_y: f32,
    clip: palette.Rect,
) f32 {
    var content_y = column.y - scroll_y;
    var message_index: usize = 0;
    while (message_index < thread.messages.items.len) {
        const message = thread.messages.items[message_index];
        if (message.role == .system and shouldHideCursorLifecycleSystemEvent(message.author, message.body)) {
            message_index += 1;
            continue;
        }
        const group_end = if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body))
            toolCallGroupEnd(thread.messages.items, message_index)
        else
            message_index + 1;
        const height = if (group_end - message_index >= 2)
            toolCallGroupHeight(state, thread.messages.items, message_index, group_end, 0, column.w)
        else
            transcriptCommittedMessageHeight(state, message_index, message, column.w);
        if (content_y + height >= column.y and content_y <= column.y + column.h) {
            if (group_end - message_index >= 2) {
                const last = thread.messages.items[group_end - 1];
                renderToolCallGroup(state, thread.messages.items, message_index, group_end, 0, column, content_y, height, clip, thread.backgroundCommandIsRunning(last.body), null);
            } else {
                renderTranscriptMessage(state, thread, column, content_y, height, message, clip, message_index);
            }
        }
        content_y += height + theme.scaledUi(12.0);
        message_index = group_end;
    }
    return content_y;
}

fn transcriptPendingSlashCommandHeight(state: *app_state.AppState, column_width: f32) f32 {
    _ = column_width;
    if (state.currentThreadPendingSlashCommand() == null) return 0;
    return theme.scaledUi(66.0) + theme.scaledUi(12.0);
}

/// Renders a transient in-flight slash-command row after committed transcript messages.
fn renderPendingSlashCommand(state: *app_state.AppState, column: palette.Rect, content_y: f32, clip: palette.Rect) f32 {
    const details = state.currentThreadPendingSlashCommand() orelse return content_y;
    const height = theme.scaledUi(66.0);
    if (content_y + height >= column.y and content_y <= column.y + column.h) {
        const bubble = snapRect(palette.Rect{ .x = column.x, .y = content_y, .w = column.w, .h = height });
        const phase = animationPhase(1_250_000_000);
        const pulse = 0.5 + 0.5 * std.math.sin(phase * std.math.tau);
        const border_alpha: u8 = @intFromFloat(135.0 + pulse * 95.0);
        queueRoundedShellClipped(
            state,
            bubble,
            paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 245)),
            paletteColor(theme.withAlpha(theme.COLOR_GREEN, border_alpha)),
            transcriptBubbleCornerRadius(),
            clip,
        );

        const pad_x = theme.scaledUi(14.0);
        const provider_label = utils.providerLabel(details.provider);
        var title_buf: [72]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} slash command", .{provider_label}) catch "Provider slash command";
        var main_buf: [128]u8 = undefined;
        const main_label = std.fmt.bufPrint(&main_buf, "Running {s}", .{details.display_name}) catch "Running command";
        var elapsed_buf: [32]u8 = undefined;
        const elapsed = formatElapsedDuration(&elapsed_buf, details.started_at_ms);

        const status_dia = theme.scaledUi(10.0);
        const status_cx = bubble.x + pad_x + status_dia * 0.5;
        const status_cy = bubble.y + theme.scaledUi(32.0);
        queueRoundedClipped(state, .{
            .x = status_cx - status_dia,
            .y = status_cy - status_dia,
            .w = status_dia * 2.0,
            .h = status_dia * 2.0,
        }, paletteColor(theme.withAlpha(theme.COLOR_GREEN, @intFromFloat(35.0 + pulse * 55.0))), status_dia, clip);
        queueRoundedClipped(state, .{
            .x = status_cx - status_dia * 0.5,
            .y = status_cy - status_dia * 0.5,
            .w = status_dia,
            .h = status_dia,
        }, paletteColor(theme.withAlpha(theme.COLOR_GREEN, @intFromFloat(180.0 + pulse * 60.0))), status_dia * 0.5, clip);

        const text_x = bubble.x + pad_x + status_dia * 2.0 + theme.scaledUi(12.0);
        const right_w = theme.scaledUi(96.0);
        const text_right = bubble.x + bubble.w - pad_x - right_w;
        queueChromeLabel(state, .{
            .x = text_x,
            .y = bubble.y + theme.scaledUi(9.0),
            .w = @max(text_right - text_x, theme.scaledUi(40.0)),
            .h = theme.scaledUi(18.0),
        }, title, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), clip);
        queueText(state, .{
            .x = text_x,
            .y = bubble.y + theme.scaledUi(29.0),
            .w = @max(text_right - text_x, theme.scaledUi(40.0)),
            .h = theme.scaledUi(18.0),
        }, main_label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), clip);
        queueChromeLabel(state, .{
            .x = bubble.x + bubble.w - pad_x - right_w,
            .y = bubble.y + theme.scaledUi(10.0),
            .w = right_w,
            .h = theme.scaledUi(18.0),
        }, elapsed, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), clip);

        renderPendingSlashCommandDots(state, .{
            .x = bubble.x + bubble.w - pad_x - right_w,
            .y = bubble.y + theme.scaledUi(34.0),
            .w = right_w,
            .h = theme.scaledUi(14.0),
        }, phase, clip);

        const rail_h = theme.scaledUi(3.0);
        const rail = palette.Rect{
            .x = bubble.x + pad_x,
            .y = bubble.y + bubble.h - theme.scaledUi(8.0),
            .w = bubble.w - pad_x * 2.0,
            .h = rail_h,
        };
        queueRoundedClipped(state, rail, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 170)), rail_h * 0.5, clip);
        const segment_w = @max(rail.w * 0.26, theme.scaledUi(56.0));
        const segment_x = rail.x + @max(rail.w - segment_w, 0.0) * phase;
        queueRoundedClipped(state, .{
            .x = segment_x,
            .y = rail.y,
            .w = @min(segment_w, rail.w),
            .h = rail.h,
        }, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 220)), rail_h * 0.5, clip);
    }
    return content_y + height + theme.scaledUi(12.0);
}

fn animationPhase(period_ns: i128) f32 {
    const t_ns: i128 = profiler.nowNs();
    return @as(f32, @floatFromInt(@mod(t_ns, period_ns))) / @as(f32, @floatFromInt(period_ns));
}

fn formatElapsedDuration(buf: []u8, started_at_ms: i64) []const u8 {
    const now_ms = unixTimestampMs();
    const elapsed_ms = @max(now_ms - @max(started_at_ms, 0), 0);
    const total_seconds: u64 = @intCast(@divTrunc(elapsed_ms, std.time.ms_per_s));
    const hours = total_seconds / 3600;
    const minutes = (total_seconds / 60) % 60;
    const seconds = total_seconds % 60;

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "0:00";
    }
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ minutes, seconds }) catch "0:00";
}

/// Renders the animated activity dots on the in-flight slash-command row.
fn renderPendingSlashCommandDots(state: *app_state.AppState, rect: palette.Rect, phase: f32, clip: palette.Rect) void {
    const dot = theme.scaledUi(5.0);
    const gap = theme.scaledUi(8.0);
    const total_w = dot * 3.0 + gap * 2.0;
    var x = rect.x + @max(rect.w - total_w, 0.0);
    const y = rect.y + (rect.h - dot) * 0.5;
    var index: usize = 0;
    while (index < 3) : (index += 1) {
        const offset = @as(f32, @floatFromInt(index)) / 3.0;
        const local = @mod(phase + offset, 1.0);
        const wave = 0.5 + 0.5 * std.math.sin(local * std.math.tau);
        const alpha: u8 = @intFromFloat(85.0 + wave * 155.0);
        queueRoundedClipped(state, .{ .x = x, .y = y, .w = dot, .h = dot }, paletteColor(theme.withAlpha(theme.COLOR_GREEN, alpha)), dot * 0.5, clip);
        x += dot + gap;
    }
}

fn transcriptPendingStreamHeight(state: *app_state.AppState, thread: *const app_state.ChatThread, column_width: f32) f32 {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending) return 0;

    const base = thread.messages.items.len;
    var total: f32 = 0;
    var pi: usize = 0;
    while (pi < send_state.pending_events.items.len) {
        const event = send_state.pending_events.items[pi];
        if (event.role == .system and shouldHideCursorLifecycleSystemEvent(event.author, event.body)) {
            pi += 1;
            continue;
        }
        const group_end = if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body))
            toolCallGroupEnd(send_state.pending_events.items, pi)
        else
            pi + 1;
        if (group_end - pi >= 2) {
            total += toolCallGroupHeight(state, send_state.pending_events.items, pi, group_end, base, column_width) + theme.scaledUi(12.0);
            pi = group_end;
            continue;
        }
        const msg_idx = base + pi;
        total += transcriptMessageHeight(state, msg_idx, event.body, event.role, column_width, event.author, false) + theme.scaledUi(12.0);
        pi += 1;
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
    var pi: usize = 0;
    while (pi < pending_count) {
        const event = send_state.pending_events.items[pi];
        if (event.role == .system and shouldHideCursorLifecycleSystemEvent(event.author, event.body)) {
            pi += 1;
            continue;
        }
        const group_end = if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body))
            toolCallGroupEnd(send_state.pending_events.items, pi)
        else
            pi + 1;
        if (group_end - pi >= 2) {
            const item_h = toolCallGroupHeight(state, send_state.pending_events.items, pi, group_end, base_message_index, column.w);
            if (y + item_h >= column.y and y <= column.y + column.h) {
                renderToolCallGroup(
                    state,
                    send_state.pending_events.items,
                    pi,
                    group_end,
                    base_message_index,
                    column,
                    y,
                    item_h,
                    clip,
                    group_end == pending_count,
                    send_state.started_at_ms,
                );
            }
            y += item_h + theme.scaledUi(12.0);
            pi = group_end;
            continue;
        }
        const msg_idx = base_message_index + pi;
        const item_h = transcriptMessageHeight(state, msg_idx, event.body, event.role, column.w, event.author, false);
        if (event.role == .system and shouldRenderPaletteCommandRow(event.author, event.body)) {
            const is_last = pi + 1 == pending_count;
            const is_backgrounded = chat_types.ChatThread.isBackgroundCommandEvent(event.author);
            if (y + item_h >= column.y and y <= column.y + column.h) {
                renderCommandEventRow(state, column, y, item_h, event.author, event.body, clip, msg_idx, is_last or is_backgrounded, false, event.tool_call_status);
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
                renderTranscriptBubbleFromParts(state, column, y, item_h, event.role, role_label, event.body, false, false, clip, msg_idx, false, false);
            }
        }
        y += item_h + theme.scaledUi(12.0);
        pi += 1;
    }

    var status_buf: [40]u8 = undefined;
    const working_label = if (send_state.local_command)
        formatPendingCommandLabel(&status_buf, send_state.started_at_ms)
    else
        formatPendingWorkingLabel(&status_buf, send_state.started_at_ms, send_state.thinking);
    const stream_text: []const u8 = send_state.partial_text.items;
    const body: []const u8 = if (stream_text.len > 0) stream_text else "Waiting for streamed output...";
    const stream_plain = stream_text.len > 0;
    const assistant_h = transcriptMessageHeightStream(null, null, body, .assistant, column.w, "", stream_plain, stream_text.len > 0);
    const stream_msg_idx = base_message_index + send_state.pending_events.items.len;
    if (y + assistant_h >= column.y and y <= column.y + column.h) {
        renderTranscriptBubbleFromParts(state, column, y, assistant_h, .assistant, working_label, body, stream_text.len == 0, stream_plain, clip, stream_msg_idx, stream_text.len > 0, true);
    }
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

fn formatPendingWorkingLabel(buf: []u8, started_at_ms: i64, thinking: bool) []const u8 {
    const now_ms = unixTimestampMs();
    const safe_started_at_ms = @max(started_at_ms, 0);
    const elapsed_ms = @max(now_ms - safe_started_at_ms, 0);
    const total_seconds: u64 = @intCast(@divTrunc(elapsed_ms, std.time.ms_per_s));
    const hours = total_seconds / 3600;
    const minutes = (total_seconds / 60) % 60;
    const seconds = total_seconds % 60;

    // Reasoning liveness swaps the verb, keeping the elapsed timer in place.
    const verb: []const u8 = if (thinking) "Thinking" else "Working";
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{s} - {d}:{d:0>2}:{d:0>2}", .{ verb, hours, minutes, seconds }) catch "Working - 0:00";
    }
    return std.fmt.bufPrint(buf, "{s} - {d}:{d:0>2}", .{ verb, minutes, seconds }) catch "Working - 0:00";
}

fn formatPendingCommandLabel(buf: []u8, started_at_ms: i64) []const u8 {
    const elapsed_ms = @max(unixTimestampMs() - @max(started_at_ms, 0), 0);
    const total_seconds: u64 = @intCast(@divTrunc(elapsed_ms, std.time.ms_per_s));
    return std.fmt.bufPrint(buf, "Running command - {d}:{d:0>2}", .{ total_seconds / 60, total_seconds % 60 }) catch "Running command";
}

fn isCommandSystemEvent(author: []const u8) bool {
    return std.mem.eql(u8, author, "Ran command") or
        std.mem.eql(u8, author, "Command failed") or
        chat_types.ChatThread.isBackgroundCommandEvent(author) or
        std.mem.eql(u8, author, "Background task completed") or
        std.mem.eql(u8, author, "Background task failed") or
        std.mem.eql(u8, author, "Background task stopped") or
        std.mem.eql(u8, author, "Failed to background command");
}

fn commandEventFailed(author: []const u8) bool {
    return std.mem.eql(u8, author, "Command failed") or
        std.mem.eql(u8, author, "Background task failed") or
        std.mem.eql(u8, author, "Failed to background command");
}

fn toolCallGroupDefaultExpanded(state: *const app_state.AppState, failed: bool) bool {
    if (failed) return true;
    return switch (state.app_config.tool_call_group_preference) {
        .collapsed => false,
        .expanded => true,
        .remember_last => state.app_config.tool_call_groups_last_expanded,
    };
}

fn toolCallGroupKey(message_index: usize) u64 {
    var hasher = std.hash.Wyhash.init(0x7001CA117001CA11);
    hasher.update(std.mem.asBytes(&message_index));
    hasher.update("tool_call_group");
    return hasher.final();
}

fn toolOutputKey(message_index: usize) u64 {
    var hasher = std.hash.Wyhash.init(0x0A77F00D0A77F00D);
    hasher.update(std.mem.asBytes(&message_index));
    hasher.update("tool_output");
    return hasher.final();
}

fn toolCopyIdentity(message_index: usize, body: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0xC0A17C0A17C0A17);
    hasher.update(std.mem.asBytes(&message_index));
    hasher.update(body);
    return hasher.final();
}

fn toolCallGroupEnd(entries: anytype, start: usize) usize {
    var end = start;
    while (end < entries.len) : (end += 1) {
        const entry = entries[end];
        if (entry.role != .system or !shouldRenderPaletteCommandRow(entry.author, entry.body)) break;
    }
    return end;
}

fn toolCallGroupFailed(entries: anytype, start: usize, end: usize) bool {
    return toolCallGroupFailureCount(entries, start, end) > 0;
}

fn toolCallEntryStatus(entry: anytype) ?ai_harness.ToolCallStatus {
    if (@hasField(@TypeOf(entry), "tool_call_status")) return entry.tool_call_status;
    return null;
}

fn toolCallGroupFailureCount(entries: anytype, start: usize, end: usize) usize {
    var count: usize = 0;
    for (entries[start..end]) |entry| {
        const status_failed = if (toolCallEntryStatus(entry)) |status| status == .failed else false;
        if (status_failed or commandEventFailed(entry.author)) count += 1;
    }
    return count;
}

fn toolCallGroupRunningCount(entries: anytype, start: usize, end: usize, fallback_running: bool) usize {
    var count: usize = 0;
    for (entries[start..end], start..) |entry, index| {
        if (toolCallEntryStatus(entry)) |status| {
            if (status == .pending or status == .in_progress) count += 1;
        } else if (fallback_running and index + 1 == end) {
            count += 1;
        }
    }
    return count;
}

test "tool call groups stop before user-required system events" {
    const Event = struct {
        role: app_state.ChatRole,
        author: []const u8,
        body: []const u8,
        tool_call_status: ?ai_harness.ToolCallStatus = null,
    };
    const entries = [_]Event{
        .{ .role = .system, .author = "Ran command", .body = "git status" },
        .{ .role = .system, .author = "Read", .body = "README.md" },
        .{ .role = .system, .author = "Approval required", .body = "Allow this command?" },
        .{ .role = .system, .author = "Command failed", .body = "exit 1" },
    };

    try std.testing.expectEqual(@as(usize, 2), toolCallGroupEnd(entries[0..], 0));
    try std.testing.expect(!toolCallGroupFailed(entries[0..], 0, 2));
    try std.testing.expect(toolCallGroupFailed(entries[0..], 3, 4));
    try std.testing.expectEqual(@as(usize, 1), toolCallGroupFailureCount(entries[0..], 0, entries.len));
    try std.testing.expectEqual(@as(usize, 1), toolCallGroupRunningCount(entries[0..], 0, 2, true));
}

test "tool call groups use structured lifecycle status" {
    const Event = struct {
        role: app_state.ChatRole = .system,
        author: []const u8,
        body: []const u8,
        tool_call_status: ?ai_harness.ToolCallStatus,
    };
    const entries = [_]Event{
        .{ .author = "Read", .body = "Input", .tool_call_status = .completed },
        .{ .author = "Edit", .body = "Input", .tool_call_status = .in_progress },
        .{ .author = "MCP tool", .body = "Error", .tool_call_status = .failed },
    };

    try std.testing.expectEqual(@as(usize, 1), toolCallGroupRunningCount(entries[0..], 0, entries.len, false));
    try std.testing.expectEqual(@as(usize, 1), toolCallGroupFailureCount(entries[0..], 0, entries.len));
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
    if (isCursorToolSystemEvent(author, body_raw)) return true;
    return isCommandLikeShellBody(body_raw);
}

fn isCursorToolSystemEvent(author_raw: []const u8, body_raw: []const u8) bool {
    const author = std.mem.trim(u8, author_raw, "\n\r\t ");
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    if (author.len == 0 or body.len == 0) return false;
    if (std.mem.eql(u8, author, "System") or
        std.mem.eql(u8, author, "Conversation interrupted") or
        std.mem.eql(u8, author, "Cursor"))
    {
        return false;
    }

    // Older provider builds persisted the provider-specific MCP method as the
    // author. Recognize the shared structured body so those rows still render
    // as bounded tool cards after an upgrade.
    inline for (.{ "Tool:\n", "Input:\n", "Output:\n", "Error:\n", "Locations:\n" }) |prefix| {
        if (std.mem.startsWith(u8, body, prefix)) return true;
    }

    const known_tools = [_][]const u8{
        "Read",
        "Read File",
        "Grep",
        "Glob",
        "Shell",
        "Edit",
        "Write",
        "Delete",
        "Move",
        "LS",
        "List",
        "Search",
        "WebFetch",
        "Web Search",
        "Fetch",
        "Think",
        "Thinking",
        "MCP tool",
        "Cursor tool",
    };
    for (known_tools) |tool| {
        if (std.ascii.eqlIgnoreCase(author, tool)) return true;
    }
    if (std.mem.indexOf(u8, body, "{\"command\"") != null) return true;
    if (std.mem.endsWith(u8, body, ": {}")) return true;
    return false;
}

test "provider-specific MCP authors still render as structured tool cards" {
    try std.testing.expect(isCursorToolSystemEvent(
        "verde.list_panes",
        "Input:\n{}\n\nOutput:\n{\"ok\":true}",
    ));
    try std.testing.expect(!isCursorToolSystemEvent(
        "System",
        "Output:\nordinary system message",
    ));
}

fn shouldHideCursorLifecycleSystemEvent(author: []const u8, body_raw: []const u8) bool {
    _ = author;
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    return std.mem.eql(u8, body, "pending") or
        std.mem.eql(u8, body, "in_progress") or
        std.mem.eql(u8, body, "completed");
}

fn isUsageSummaryBody(body: []const u8, title: []const u8) bool {
    return std.mem.eql(u8, body, title) or
        (body.len > title.len and std.mem.startsWith(u8, body, title) and body[title.len] == '\n');
}

fn isUsageSummaryMessage(author: []const u8, body_raw: []const u8) bool {
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    return std.mem.eql(u8, author, "Usage") and
        (isUsageSummaryBody(body, "Codex usage") or isUsageSummaryBody(body, "Claude usage"));
}

fn isSlashCommandResultMessage(author: []const u8, body_raw: []const u8) bool {
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    if (body.len == 0) return false;
    if (std.mem.eql(u8, author, "Shell")) {
        return std.mem.startsWith(u8, body, "Command:\n") and
            (std.mem.indexOf(u8, body, "\n\nOutput:") != null or
                std.mem.indexOf(u8, body, "\n\nNo output captured.") != null);
    }
    if (std.mem.eql(u8, author, "Claude command")) return true;
    if (std.mem.startsWith(u8, author, "Claude /")) return true;
    if (std.mem.startsWith(u8, author, "Codex /")) return true;
    return std.mem.eql(u8, author, "Review") or
        std.mem.eql(u8, author, "Goal") or
        std.mem.eql(u8, author, "Compact");
}

/// Label shown after `>_` in the compact command row (Codex-native titles preserved; Cursor/shell-like bodies default to "Ran command").
fn paletteCommandRowDisplayAuthor(original_author: []const u8, body_raw: []const u8) []const u8 {
    if (isCommandSystemEvent(original_author)) return original_author;
    if (isCursorToolSystemEvent(original_author, body_raw)) return original_author;
    if (isCommandLikeShellBody(body_raw)) return "Ran command";
    return original_author;
}

fn transcriptCommandEventHeight(
    state: ?*app_state.AppState,
    message_index: ?usize,
    author: []const u8,
    body_raw: []const u8,
    column_width: f32,
    tool_call_status: ?ai_harness.ToolCallStatus,
) f32 {
    const pad_x = theme.scaledUi(14.0);
    const pad_y = theme.scaledUi(9.0);
    const font_size = theme.scaledUi(15.0);
    const line_h = font_size * 1.28;
    const header_h = line_h + pad_y * 2.0;

    const expanded = blk: {
        const app = state orelse break :blk false;
        const idx = message_index orelse break :blk false;
        const failed = commandEventFailed(author) or (tool_call_status orelse .unknown) == .failed;
        break :blk app.isCardExpandedDefault(commandCardKey(idx), failed);
    };
    if (!expanded) return header_h;

    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const inner_w = @max(column_width - pad_x * 2.0, theme.scaledUi(80.0));
    const chars_per_line = @max(@as(usize, @intFromFloat(inner_w / (font_size * 0.52))), 1);
    const line_count = wrappedLineCount(body, chars_per_line);
    const show_all = blk: {
        const app = state orelse break :blk false;
        const idx = message_index orelse break :blk false;
        break :blk app.isCardExpanded(toolOutputKey(idx));
    };
    const visible_lines = if (show_all) line_count else @min(line_count, TOOL_OUTPUT_COLLAPSED_LINES);
    const show_more_h: f32 = if (!show_all and line_count > visible_lines) theme.scaledUi(28.0) else 0.0;
    return header_h + @as(f32, @floatFromInt(visible_lines)) * line_h + show_more_h + pad_y;
}

fn transcriptCommittedMessageHeight(state: *app_state.AppState, message_index: usize, message: app_state.ChatMessage, column_width: f32) f32 {
    const image_present = message.image != null or message.extra_images.len > 0;
    // Command rows and diff cards have per-frame expand/collapse state that the
    // height cache key does not include — bypass the cache so toggles take
    // effect immediately.
    const has_dynamic_collapse = message.role == .system and
        (shouldRenderPaletteCommandRow(message.author, message.body) or isDiffSummaryMessage(message.author, message.body) or isUsageSummaryMessage(message.author, message.body));
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
    if (role == .system and isSlashCommandResultMessage(message_author, body_raw)) {
        return slashCommandResultHeight(state, message_index, body_raw, column_width);
    }
    if (role == .system and shouldRenderPaletteCommandRow(message_author, body_raw)) {
        return transcriptCommandEventHeight(state, message_index, message_author, body_raw, column_width, null);
    }
    if (role == .system and isDiffSummaryMessage(message_author, body_raw)) {
        return diffSummaryHeight(state, message_index, body_raw, column_width);
    }
    if (role == .system and isUsageSummaryMessage(message_author, body_raw)) {
        return usageSummaryHeight(body_raw, column_width);
    }
    if (role == .system and utils.providerFailureActionProvider(body_raw) != null) {
        return providerFailureActionHeight(body_raw, column_width);
    }
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const font_size = theme.scaledUi(TRANSCRIPT_MARKDOWN_FONT_SIZE);
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
    var plain_view = chat_markdown.buildPlainBodyView(std.heap.page_allocator, body) catch {
        const chars_per_line = @max(@as(usize, @intFromFloat(body_inner_width / (font_size * 0.52))), 1);
        const line_count = wrappedLineCount(body, chars_per_line);
        return theme.scaledUi(46.0) + @as(f32, @floatFromInt(line_count)) * font_size * 1.38;
    };
    defer plain_view.deinit(std.heap.page_allocator);
    return theme.scaledUi(46.0) + chat_markdown.measureBodyHeight(plain_view, body_inner_width, transcriptPlainTextOptions(theme.COLOR_WHITE));
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

fn renderTranscriptMessage(state: *app_state.AppState, thread: *const app_state.ChatThread, column: palette.Rect, y: f32, height: f32, message: app_state.ChatMessage, clip: palette.Rect, message_index: usize) void {
    if (message.role == .system and isSlashCommandResultMessage(message.author, message.body)) {
        renderSlashCommandResultCard(state, column, y, height, message.author, message.body, clip, message_index);
        return;
    }
    if (message.role == .system and shouldRenderPaletteCommandRow(message.author, message.body)) {
        renderCommandEventRow(state, column, y, height, message.author, message.body, clip, message_index, thread.backgroundCommandIsRunning(message.body), false, message.tool_call_status);
        return;
    }
    if (message.role == .system and isDiffSummaryMessage(message.author, message.body)) {
        renderDiffSummaryCard(state, column, y, height, message.body, clip, message_index);
        return;
    }
    if (message.role == .system and isUsageSummaryMessage(message.author, message.body)) {
        renderUsageSummaryCard(state, column, y, height, message.body, clip, message_index);
        return;
    }
    if (message.role == .system) {
        if (utils.providerFailureActionProvider(message.body)) |provider| {
            renderProviderFailureActionCard(state, column, y, height, provider, message.body, clip, message_index);
            return;
        }
    }
    const role_label = switch (message.role) {
        .user => "You",
        .assistant => if (message.author.len > 0) message.author else "Assistant",
        .system => if (message.author.len > 0) message.author else "System",
    };
    renderTranscriptBubbleFromParts(state, column, y, height, message.role, role_label, message.body, false, false, clip, message_index, false, false);
    renderTranscriptImages(state, column, y, height, message, clip);
}

fn providerFailureActionHeight(body_raw: []const u8, column_width: f32) f32 {
    const font_size = theme.scaledUi(TRANSCRIPT_MARKDOWN_FONT_SIZE);
    const inner_width = @max(column_width - theme.scaledUi(32.0), theme.scaledUi(80.0));
    const chars_per_line = @max(@as(usize, @intFromFloat(inner_width / (font_size * 0.52))), 1);
    const display_body = utils.providerFailureActionBody(body_raw);
    const line_count = wrappedLineCount(std.mem.trim(u8, display_body, "\n\r\t "), chars_per_line);
    const body_height = @as(f32, @floatFromInt(line_count)) * font_size * 1.38;
    return theme.scaledUi(99.0) + body_height;
}

fn recordUsageActionHit(rect: palette.Rect) void {
    if (usage_action_hit_count >= usage_action_hits.len) return;
    usage_action_hits[usage_action_hit_count] = .{ .rect = rect };
    usage_action_hit_count += 1;
}

// Provider failure region with a direct provider-usage action.
fn renderProviderFailureActionCard(
    state: *app_state.AppState,
    column: palette.Rect,
    y: f32,
    height: f32,
    provider: app_state.Provider,
    body_raw: []const u8,
    clip: palette.Rect,
    message_index: usize,
) void {
    const bubble = snapRect(palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height });
    queueRoundedShellClipped(
        state,
        bubble,
        paletteColor(theme.withAlpha(theme.COLOR_YELLOW, 42)),
        paletteColor(theme.withAlpha(theme.COLOR_YELLOW, 210)),
        transcriptBubbleCornerRadius(),
        clip,
    );

    const pad = theme.scaledUi(16.0);
    var title_buf: [80]u8 = undefined;
    const is_usage_limit = utils.usageLimitProviderForDisplayMessage(body_raw) != null;
    const title = if (is_usage_limit)
        std.fmt.bufPrint(&title_buf, "{s} usage limit reached", .{utils.providerLabel(provider)}) catch "Usage limit reached"
    else
        std.fmt.bufPrint(&title_buf, "{s} request failed", .{utils.providerLabel(provider)}) catch "Provider request failed";
    queueChromeLabel(state, .{
        .x = bubble.x + pad,
        .y = bubble.y + theme.scaledUi(11.0),
        .w = bubble.w - pad * 2.0,
        .h = theme.scaledUi(20.0),
    }, title, paletteColor(theme.COLOR_YELLOW), theme.scaledUi(13.0), clip);

    const font_size = theme.scaledUi(TRANSCRIPT_MARKDOWN_FONT_SIZE);
    const inner_width = @max(bubble.w - pad * 2.0, theme.scaledUi(80.0));
    const chars_per_line = @max(@as(usize, @intFromFloat(inner_width / (font_size * 0.52))), 1);
    const body = std.mem.trim(u8, utils.providerFailureActionBody(body_raw), "\n\r\t ");
    const line_count = wrappedLineCount(body, chars_per_line);
    const body_height = @as(f32, @floatFromInt(line_count)) * font_size * 1.38;
    renderWrappedBody(state, .{
        .x = bubble.x + pad,
        .y = bubble.y + theme.scaledUi(38.0),
        .w = inner_width,
        .h = body_height,
    }, body, paletteColor(theme.COLOR_WHITE), font_size, clip);

    const button = snapRect(palette.Rect{
        .x = bubble.x + pad,
        .y = bubble.y + theme.scaledUi(50.0) + body_height,
        .w = theme.scaledUi(116.0),
        .h = theme.scaledUi(34.0),
    });
    const hovered = rectContains(button, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    const button_fill = if (hovered)
        theme.withAlpha(theme.lighten(theme.COLOR_PANEL_ALT, 0.10), 245)
    else
        theme.withAlpha(theme.COLOR_PANEL_MUTED, 205);
    queueRoundedShellClipped(
        state,
        button,
        paletteColor(button_fill),
        paletteColor(theme.withAlpha(theme.COLOR_GREEN, if (hovered) 230 else 165)),
        theme.scaledUi(8.0),
        clip,
    );
    queueFixedTextLine(state, .{
        .x = button.x + theme.scaledUi(13.0),
        .y = button.y + theme.scaledUi(8.0),
        .w = button.w - theme.scaledUi(26.0),
        .h = theme.scaledUi(18.0),
    }, "View usage", paletteColor(if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), clip);
    if (intersectClipRect(clip, button)) |visible_button| recordUsageActionHit(visible_button);

    const copy_button = snapRect(.{
        .x = button.x + button.w + theme.scaledUi(8.0),
        .y = button.y,
        .w = theme.scaledUi(66.0),
        .h = button.h,
    });
    renderDiffFileActionButton(state, copy_button, "Copy", false, clip);
    state.recordTranscriptCopyHit(copy_button, body, toolCopyIdentity(message_index, body));
}

// Renders clickable attachment previews beneath a committed chat message.
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
        if (intersectClipRect(clip, frame)) |visible_frame| {
            if (transcript_image_hit_count < transcript_image_hits.len) {
                transcript_image_hits[transcript_image_hit_count] = .{ .rect = visible_frame, .path = image.path };
                transcript_image_hit_count += 1;
            }
        }
        queueRoundedShellClipped(
            state,
            frame,
            paletteColor(theme.background()),
            paletteColor(theme.COLOR_PANEL_MUTED),
            theme.scaledUi(9.0),
            clip,
        );
        if (state.ensureImageTexture(image.path)) |cached| {
            const inset = theme.scaledUi(6.0);
            const image_rect = palette.Rect{ .x = frame.x + inset, .y = frame.y + inset, .w = frame.w - inset * 2.0, .h = frame.h - inset * 2.0 };
            const dims = runtime.scaledImageSize(cached.width, cached.height, image_rect.w, image_rect.h);
            const image_clip = intersectClipRect(clip, frame) orelse frame;
            if (image_clip.w > 0.0 and image_clip.h > 0.0) {
                queueImage(state, .{
                    .x = image_rect.x + (image_rect.w - dims[0]) * 0.5,
                    .y = image_rect.y + (image_rect.h - dims[1]) * 0.5,
                    .w = dims[0],
                    .h = dims[1],
                }, cached, image_clip);
            }
        } else {
            queueText(state, .{ .x = frame.x + pad, .y = frame.y + pad, .w = frame.w - pad * 2.0, .h = theme.scaledUi(20.0) }, image.file_name, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), clip);
        }
        image_y += thumb_h + gap;
    }
}

// ----- Provider usage summary card -----

const UsageLimitRow = struct {
    label: []const u8,
    percent_left: i64,
    reset: []const u8,
};

const UsageTextRow = struct {
    label: []const u8,
    value: []const u8,
};

const UsageSummary = struct {
    limits: [8]UsageLimitRow = undefined,
    limit_count: usize = 0,
    stats: [8]UsageTextRow = undefined,
    stat_count: usize = 0,
    recent: [8]UsageTextRow = undefined,
    recent_count: usize = 0,
};

const UsageSection = enum { none, limits, summary, recent };

fn parseUsageSummary(body_raw: []const u8) UsageSummary {
    var result: UsageSummary = .{};
    var section: UsageSection = .none;
    var lines = std.mem.splitScalar(u8, body_raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.eql(u8, line, "Codex usage") or std.mem.eql(u8, line, "Claude usage")) continue;
        if (std.mem.eql(u8, line, "Limits")) {
            section = .limits;
            continue;
        }
        if (std.mem.eql(u8, line, "Summary")) {
            section = .summary;
            continue;
        }
        if (std.mem.eql(u8, line, "Recent daily usage")) {
            section = .recent;
            continue;
        }

        if (!std.mem.startsWith(u8, line, "• ")) continue;
        const item = std.mem.trim(u8, line["• ".len..], " \t\r");
        switch (section) {
            .limits => if (parseUsageLimitRow(item)) |row| {
                if (result.limit_count < result.limits.len) {
                    result.limits[result.limit_count] = row;
                    result.limit_count += 1;
                }
            },
            .summary => if (parseUsageTextRow(item)) |row| {
                if (result.stat_count < result.stats.len) {
                    result.stats[result.stat_count] = row;
                    result.stat_count += 1;
                }
            },
            .recent => if (parseUsageTextRow(item)) |row| {
                if (result.recent_count < result.recent.len) {
                    result.recent[result.recent_count] = row;
                    result.recent_count += 1;
                }
            },
            .none => {},
        }
    }
    return result;
}

fn parseUsageTextRow(item: []const u8) ?UsageTextRow {
    const colon = std.mem.indexOf(u8, item, ":") orelse return null;
    return .{
        .label = std.mem.trim(u8, item[0..colon], " \t"),
        .value = std.mem.trim(u8, item[colon + 1 ..], " \t"),
    };
}

fn parseUsageLimitRow(item: []const u8) ?UsageLimitRow {
    const colon = std.mem.indexOf(u8, item, ":") orelse return null;
    const label = std.mem.trim(u8, item[0..colon], " \t");
    const rest = std.mem.trim(u8, item[colon + 1 ..], " \t");
    const percent_end = std.mem.indexOf(u8, rest, "% left") orelse return null;
    const percent = std.fmt.parseInt(i64, std.mem.trim(u8, rest[0..percent_end], " \t"), 10) catch return null;
    var reset: []const u8 = "";
    const after_percent = std.mem.trim(u8, rest[percent_end + "% left".len ..], " \t");
    if (after_percent.len >= 2 and after_percent[0] == '(' and after_percent[after_percent.len - 1] == ')') {
        reset = after_percent[1 .. after_percent.len - 1];
    }
    return .{ .label = label, .percent_left = percent, .reset = reset };
}

fn usageSummaryHeight(body_raw: []const u8, column_width: f32) f32 {
    const data = parseUsageSummary(body_raw);
    const pad = theme.scaledUi(16.0);
    const gap = theme.scaledUi(12.0);
    const header_h = theme.scaledUi(54.0);
    const section_h = theme.scaledUi(21.0);
    const limit_h = theme.scaledUi(42.0);
    const tile_h = theme.scaledUi(58.0);
    const recent_h = theme.scaledUi(21.0);

    var total = pad * 2.0 + header_h;
    if (data.limit_count > 0) total += section_h + @as(f32, @floatFromInt(data.limit_count)) * limit_h + gap;

    const stat_cols: usize = if (column_width >= theme.scaledUi(560.0)) 2 else 1;
    const stat_rows = if (data.stat_count == 0) 0 else (data.stat_count + stat_cols - 1) / stat_cols;
    if (stat_rows > 0) total += section_h + @as(f32, @floatFromInt(stat_rows)) * tile_h + gap;

    const recent_cols: usize = if (column_width >= theme.scaledUi(560.0)) 2 else 1;
    const recent_rows = if (data.recent_count == 0) 0 else (data.recent_count + recent_cols - 1) / recent_cols;
    if (recent_rows > 0) total += section_h + @as(f32, @floatFromInt(recent_rows)) * recent_h;
    return total;
}

fn usageSummaryTitle(body_raw: []const u8) []const u8 {
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    if (isUsageSummaryBody(body, "Claude usage")) return "Claude usage";
    return "Codex usage";
}

/// Renders a provider `/usage` transcript row as a structured status card.
fn renderUsageSummaryCard(state: *app_state.AppState, column: palette.Rect, y: f32, height: f32, body_raw: []const u8, clip: palette.Rect, message_index: usize) void {
    const data = parseUsageSummary(body_raw);
    const bubble = snapRect(palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height });
    const rr = transcriptBubbleCornerRadius();
    queueRoundedShellClipped(state, bubble, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 248)), paletteColor(theme.withAlpha(theme.COLOR_GREEN, 150)), rr, clip);

    const pad = theme.scaledUi(16.0);
    const gap = theme.scaledUi(12.0);
    const header_h = theme.scaledUi(54.0);
    var cursor_y = bubble.y + pad;
    renderUsageHeader(state, bubble, cursor_y, header_h, usageSummaryTitle(body_raw), clip);
    const copy_rect = snapRect(palette.Rect{
        .x = bubble.x + bubble.w - pad - theme.scaledUi(66.0),
        .y = bubble.y + pad + theme.scaledUi(3.0),
        .w = theme.scaledUi(66.0),
        .h = theme.scaledUi(24.0),
    });
    renderDiffFileActionButton(state, copy_rect, "Copy", false, clip);
    state.recordTranscriptCopyHit(copy_rect, std.mem.trim(u8, body_raw, "\n\r\t "), toolCopyIdentity(message_index, body_raw));
    cursor_y += header_h;

    if (data.limit_count > 0) {
        renderUsageSectionTitle(state, bubble, cursor_y, "Remaining limits", clip);
        cursor_y += theme.scaledUi(21.0);
        for (data.limits[0..data.limit_count]) |row| {
            renderUsageLimitRow(state, .{ .x = bubble.x + pad, .y = cursor_y, .w = bubble.w - pad * 2.0, .h = theme.scaledUi(42.0) }, row, clip);
            cursor_y += theme.scaledUi(42.0);
        }
        cursor_y += gap;
    }

    if (data.stat_count > 0) {
        renderUsageSectionTitle(state, bubble, cursor_y, "Account activity", clip);
        cursor_y += theme.scaledUi(21.0);
        const cols: usize = if (bubble.w >= theme.scaledUi(560.0)) 2 else 1;
        const tile_gap = theme.scaledUi(10.0);
        const tile_w = (bubble.w - pad * 2.0 - tile_gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
        const tile_h = theme.scaledUi(58.0);
        for (data.stats[0..data.stat_count], 0..) |row, index| {
            const col: usize = @mod(index, cols);
            const row_index: usize = index / cols;
            renderUsageStatTile(state, .{
                .x = bubble.x + pad + @as(f32, @floatFromInt(col)) * (tile_w + tile_gap),
                .y = cursor_y + @as(f32, @floatFromInt(row_index)) * tile_h,
                .w = tile_w,
                .h = tile_h - theme.scaledUi(8.0),
            }, row, clip);
        }
        const stat_rows = (data.stat_count + cols - 1) / cols;
        cursor_y += @as(f32, @floatFromInt(stat_rows)) * tile_h + gap;
    }

    if (data.recent_count > 0) {
        renderUsageSectionTitle(state, bubble, cursor_y, "Recent days", clip);
        cursor_y += theme.scaledUi(21.0);
        const cols: usize = if (bubble.w >= theme.scaledUi(560.0)) 2 else 1;
        const col_gap = theme.scaledUi(18.0);
        const row_h = theme.scaledUi(21.0);
        const col_w = (bubble.w - pad * 2.0 - col_gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
        for (data.recent[0..data.recent_count], 0..) |row, index| {
            const col: usize = @mod(index, cols);
            const row_index: usize = index / cols;
            renderUsageRecentRow(state, .{
                .x = bubble.x + pad + @as(f32, @floatFromInt(col)) * (col_w + col_gap),
                .y = cursor_y + @as(f32, @floatFromInt(row_index)) * row_h,
                .w = col_w,
                .h = row_h,
            }, row, clip);
        }
    }
}

/// Renders the title/subtitle region for the usage card.
fn renderUsageHeader(state: *app_state.AppState, bubble: palette.Rect, y: f32, height: f32, title: []const u8, clip: palette.Rect) void {
    const pad = theme.scaledUi(16.0);
    const icon = theme.scaledUi(30.0);
    const icon_rect = palette.Rect{ .x = bubble.x + pad, .y = y + theme.scaledUi(5.0), .w = icon, .h = icon };
    renderUsageHeaderIcon(state, icon_rect, clip);
    queueChromeLabel(state, .{ .x = icon_rect.x + icon + theme.scaledUi(11.0), .y = y + theme.scaledUi(3.0), .w = bubble.w - pad * 2.0 - icon - theme.scaledUi(11.0), .h = theme.scaledUi(22.0) }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(16.0), clip);
    queueText(state, .{ .x = icon_rect.x + icon + theme.scaledUi(11.0), .y = y + theme.scaledUi(27.0), .w = bubble.w - pad * 2.0 - icon - theme.scaledUi(11.0), .h = theme.scaledUi(18.0) }, "Rate limits, reset windows, and recent token activity", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.5), clip);
    queueRectClipped(state, .{ .x = bubble.x + pad, .y = y + height - 1.0, .w = bubble.w - pad * 2.0, .h = 1.0 }, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 190)), clip);
}

/// Renders a small bar-chart glyph for the usage card header without relying on font symbols.
fn renderUsageHeaderIcon(state: *app_state.AppState, rect: palette.Rect, clip: palette.Rect) void {
    queueRoundedClipped(state, rect, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 42)), rect.w * 0.5, clip);

    const bar_w = theme.scaledUi(3.0);
    const gap = theme.scaledUi(2.5);
    const base_y = rect.y + rect.h - theme.scaledUi(8.0);
    const heights = [_]f32{ theme.scaledUi(8.0), theme.scaledUi(13.0), theme.scaledUi(18.0) };
    const total_w = bar_w * 3.0 + gap * 2.0;
    var x = rect.x + (rect.w - total_w) * 0.5;
    for (heights) |bar_h| {
        queueRoundedClipped(state, .{
            .x = x,
            .y = base_y - bar_h,
            .w = bar_w,
            .h = bar_h,
        }, paletteColor(theme.COLOR_GREEN), bar_w * 0.5, clip);
        x += bar_w + gap;
    }
}

/// Renders a compact all-caps-style section label inside the usage card.
fn renderUsageSectionTitle(state: *app_state.AppState, bubble: palette.Rect, y: f32, title: []const u8, clip: palette.Rect) void {
    queueChromeLabel(state, .{ .x = bubble.x + theme.scaledUi(16.0), .y = y, .w = bubble.w - theme.scaledUi(32.0), .h = theme.scaledUi(18.0) }, title, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), clip);
}

/// Renders one remaining-limit row with text and a percent-left progress bar.
fn renderUsageLimitRow(state: *app_state.AppState, rect: palette.Rect, row: UsageLimitRow, clip: palette.Rect) void {
    const percent = @max(@as(i64, 0), @min(@as(i64, 100), row.percent_left));
    const bar_h = theme.scaledUi(7.0);
    const label_h = theme.scaledUi(19.0);
    const percent_text = std.fmt.allocPrint(state.allocator, "{d}% left", .{percent}) catch "";
    defer if (percent_text.len > 0) state.allocator.free(percent_text);
    queueFixedTextLine(state, .{ .x = rect.x, .y = rect.y, .w = rect.w * 0.54, .h = label_h }, row.label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), clip);
    queueFixedTextLine(state, .{ .x = rect.x + rect.w * 0.56, .y = rect.y, .w = rect.w * 0.18, .h = label_h }, percent_text, paletteColor(usagePercentColor(percent)), theme.scaledUi(13.0), clip);
    if (row.reset.len > 0) {
        queueFixedTextLine(state, .{ .x = rect.x + rect.w * 0.73, .y = rect.y, .w = rect.w * 0.27, .h = label_h }, row.reset, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), clip);
    }
    const bar = palette.Rect{ .x = rect.x, .y = rect.y + theme.scaledUi(25.0), .w = rect.w, .h = bar_h };
    queueRoundedClipped(state, bar, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 210)), bar_h * 0.5, clip);
    queueRoundedClipped(state, .{ .x = bar.x, .y = bar.y, .w = bar.w * @as(f32, @floatFromInt(percent)) / 100.0, .h = bar.h }, paletteColor(usagePercentColor(percent)), bar_h * 0.5, clip);
}

/// Renders one account-activity metric tile in the usage card.
fn renderUsageStatTile(state: *app_state.AppState, rect: palette.Rect, row: UsageTextRow, clip: palette.Rect) void {
    queueRoundedClipped(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 135)), theme.scaledUi(9.0), clip);
    queueText(state, .{ .x = rect.x + theme.scaledUi(11.0), .y = rect.y + theme.scaledUi(8.0), .w = rect.w - theme.scaledUi(22.0), .h = theme.scaledUi(16.0) }, row.label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(11.5), clip);
    queueFixedTextLine(state, .{ .x = rect.x + theme.scaledUi(11.0), .y = rect.y + theme.scaledUi(28.0), .w = rect.w - theme.scaledUi(22.0), .h = theme.scaledUi(19.0) }, row.value, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.5), clip);
}

/// Renders one recent daily usage row in the usage card.
fn renderUsageRecentRow(state: *app_state.AppState, rect: palette.Rect, row: UsageTextRow, clip: palette.Rect) void {
    queueFixedTextLine(state, .{ .x = rect.x, .y = rect.y, .w = rect.w * 0.42, .h = rect.h }, row.label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), clip);
    queueFixedTextLine(state, .{ .x = rect.x + rect.w * 0.44, .y = rect.y, .w = rect.w * 0.56, .h = rect.h }, row.value, paletteColor(theme.COLOR_WHITE), theme.scaledUi(12.0), clip);
}

fn usagePercentColor(percent_left: i64) [4]f32 {
    if (percent_left >= 50) return theme.COLOR_GREEN;
    if (percent_left >= 20) return theme.COLOR_YELLOW;
    return theme.COLOR_DIFF_REMOVE;
}

// ----- Provider slash-command result card -----

fn slashCommandResultHeight(state: ?*app_state.AppState, message_index: ?usize, body_raw: []const u8, column_width: f32) f32 {
    const pad = theme.scaledUi(16.0);
    const header_h = theme.scaledUi(46.0);
    const gap = theme.scaledUi(12.0);
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const body_inner_width = @max(column_width - pad * 2.0, theme.scaledUi(80.0));
    const font_size = theme.scaledUi(TRANSCRIPT_MARKDOWN_FONT_SIZE);

    const measured = blk: {
        if (state) |app| {
            if (message_index) |index| {
                if (app.transcriptMarkdownBodyView(index, body)) |view| {
                    break :blk chat_markdown.measureBodyHeight(view.*, body_inner_width, markdownOptions(font_size));
                }
            }
        }
        var view = chat_markdown.buildBodyView(std.heap.page_allocator, body) catch {
            const chars_per_line = @max(@as(usize, @intFromFloat(body_inner_width / (font_size * 0.52))), 1);
            const line_count = wrappedLineCount(body, chars_per_line);
            break :blk @as(f32, @floatFromInt(line_count)) * font_size * 1.38;
        };
        defer view.deinit(std.heap.page_allocator);
        break :blk chat_markdown.measureBodyHeight(view, body_inner_width, markdownOptions(font_size));
    };

    return pad + header_h + gap + measured + pad;
}

/// Renders a completed provider slash-command result with assistant-style Markdown output.
fn renderSlashCommandResultCard(
    state: *app_state.AppState,
    column: palette.Rect,
    y: f32,
    height: f32,
    author: []const u8,
    body_raw: []const u8,
    clip: palette.Rect,
    message_index: usize,
) void {
    const bubble = snapRect(palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height });
    queueRoundedShellClipped(
        state,
        bubble,
        paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 248)),
        paletteColor(theme.withAlpha(theme.COLOR_GREEN, 135)),
        transcriptBubbleCornerRadius(),
        clip,
    );

    const pad = theme.scaledUi(16.0);
    const header_h = theme.scaledUi(46.0);
    const icon = theme.scaledUi(30.0);
    const icon_rect = palette.Rect{ .x = bubble.x + pad, .y = bubble.y + pad + theme.scaledUi(3.0), .w = icon, .h = icon };
    renderSlashCommandResultIcon(state, icon_rect, clip);

    const pill_w = theme.scaledUi(84.0);
    const title_x = icon_rect.x + icon + theme.scaledUi(11.0);
    const title_w = @max(bubble.w - pad * 2.0 - icon - theme.scaledUi(11.0) - pill_w - theme.scaledUi(10.0), theme.scaledUi(40.0));
    queueChromeLabel(state, .{
        .x = title_x,
        .y = bubble.y + pad + theme.scaledUi(1.0),
        .w = title_w,
        .h = theme.scaledUi(22.0),
    }, author, paletteColor(theme.COLOR_WHITE), theme.scaledUi(15.5), clip);
    queueText(state, .{
        .x = title_x,
        .y = bubble.y + pad + theme.scaledUi(25.0),
        .w = title_w,
        .h = theme.scaledUi(18.0),
    }, "Slash command output", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.5), clip);

    const pill = palette.Rect{ .x = bubble.x + bubble.w - pad - pill_w, .y = bubble.y + pad + theme.scaledUi(8.0), .w = pill_w, .h = theme.scaledUi(24.0) };
    queueRoundedClipped(state, pill, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 48)), pill.h * 0.5, clip);
    queueChromeLabel(state, .{
        .x = pill.x + theme.scaledUi(10.0),
        .y = pill.y + theme.scaledUi(4.0),
        .w = pill.w - theme.scaledUi(20.0),
        .h = theme.scaledUi(16.0),
    }, "completed", paletteColor(theme.COLOR_GREEN), theme.scaledUi(11.5), clip);

    queueRectClipped(state, .{ .x = bubble.x + pad, .y = bubble.y + pad + header_h - 1.0, .w = bubble.w - pad * 2.0, .h = 1.0 }, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 180)), clip);

    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const body_y = bubble.y + pad + header_h + theme.scaledUi(12.0);
    renderMarkdownBody(state, message_index, .{
        .x = bubble.x + pad,
        .y = body_y,
        .w = bubble.w - pad * 2.0,
        .h = @max(bubble.y + bubble.h - body_y - pad, theme.scaledUi(1.0)),
    }, body, clip, false);
}

/// Renders the slash glyph used in completed provider-command result cards.
fn renderSlashCommandResultIcon(state: *app_state.AppState, rect: palette.Rect, clip: palette.Rect) void {
    queueRoundedClipped(state, rect, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 42)), rect.w * 0.5, clip);
    queueChromeLabel(state, .{
        .x = rect.x,
        .y = rect.y + theme.scaledUi(2.0),
        .w = rect.w,
        .h = rect.h,
    }, "/", paletteColor(theme.COLOR_GREEN), theme.scaledUi(18.0), clip);
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
    return utils.isPersistedDiffBody(body_raw);
}

/// Iterator over diff file entries packed in the persisted body. Returns null
/// when the body does not start with `PERSISTED_DIFF_MARKER`.
fn parseDiffSummary(allocator: std.mem.Allocator, body_raw: []const u8) ?[]DiffFileEntry {
    if (std.mem.startsWith(u8, body_raw, utils.PERSISTED_DIFF_MARKER)) {
        return parseDiffSummaryV2(allocator, body_raw[utils.PERSISTED_DIFF_MARKER.len..]);
    }
    if (!std.mem.startsWith(u8, body_raw, utils.PERSISTED_DIFF_MARKER_V1)) return null;
    var rest = body_raw[utils.PERSISTED_DIFF_MARKER_V1.len..];

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

fn parseDiffSummaryV2(allocator: std.mem.Allocator, body: []const u8) ?[]DiffFileEntry {
    var rest = body;
    var files: std.ArrayList(DiffFileEntry) = .empty;
    errdefer files.deinit(allocator);

    while (rest.len > 0) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
        const header = rest[0..line_end];
        rest = rest[line_end + 1 ..];
        if (!std.mem.startsWith(u8, header, "FILE\t")) return null;

        var fields = std.mem.splitScalar(u8, header["FILE\t".len..], '\t');
        const path_len = std.fmt.parseInt(usize, fields.next() orelse return null, 10) catch return null;
        const additions = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
        const deletions = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
        const patch_len = std.fmt.parseInt(usize, fields.next() orelse return null, 10) catch return null;
        if (fields.next() != null or path_len > rest.len or patch_len > rest.len - path_len) return null;

        const path = rest[0..path_len];
        rest = rest[path_len..];
        const patch = rest[0..patch_len];
        rest = rest[patch_len..];
        files.append(allocator, .{
            .path = path,
            .additions = additions,
            .deletions = deletions,
            .patch = patch,
        }) catch return null;
    }
    return files.toOwnedSlice(allocator) catch null;
}

fn diffFileCardKey(message_index: usize, file_path: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0xD1FFD1FFD1FFD1FF);
    hasher.update(std.mem.asBytes(&message_index));
    hasher.update(file_path);
    return hasher.final();
}

fn diffCopyIdentity(message_index: usize, file_path: []const u8, patch: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0xD1FFC0A1D1FFC0A1);
    hasher.update(std.mem.asBytes(&message_index));
    hasher.update(file_path);
    hasher.update(patch);
    return hasher.final();
}

const DiffLayout = enum {
    stacked,
    split,
};

const DIFF_SPLIT_MIN_WIDTH_CSS: f32 = 620.0;

fn diffLayoutForWidth(
    state: ?*app_state.AppState,
    width: f32,
) DiffLayout {
    if (width < theme.scaledUi(DIFF_SPLIT_MIN_WIDTH_CSS)) return .stacked;
    const app = state orelse return .stacked;
    return if (app.app_config.diff_layout_preference == .split) .split else .stacked;
}

fn diffSummaryHeight(state: ?*app_state.AppState, message_index: ?usize, body_raw: []const u8, column_width: f32) f32 {
    const files = parseDiffSummary(std.heap.page_allocator, body_raw) orelse return theme.scaledUi(82.0);
    defer std.heap.page_allocator.free(files);
    return diffSummaryHeightForFiles(state, message_index, files, column_width);
}

fn diffSummaryHeightForFiles(state: ?*app_state.AppState, message_index: ?usize, files: []const DiffFileEntry, column_width: f32) f32 {
    const outer_pad = theme.scaledUi(12.0);
    const summary_h = theme.scaledUi(42.0);
    const file_h = theme.scaledUi(44.0);
    const code_line_h = theme.scaledUi(21.0);
    const layout = diffLayoutForWidth(state, column_width);
    var total = outer_pad + summary_h;
    for (files) |file| {
        total += file_h;
        const expanded = blk: {
            const app = state orelse break :blk false;
            const mi = message_index orelse break :blk false;
            break :blk app.isCardExpanded(diffFileCardKey(mi, file.path));
        };
        if (expanded) {
            const line_count = diffPatchDisplayLineCountForLayout(state, file.patch, layout);
            total += @as(f32, @floatFromInt(line_count)) * code_line_h + theme.scaledUi(20.0);
        }
    }
    if (files.len == 0) total += theme.scaledUi(42.0);
    total += outer_pad;
    return total;
}

fn diffPatchDisplayLineCountForLayout(state: ?*app_state.AppState, patch: []const u8, layout: DiffLayout) usize {
    return switch (layout) {
        .stacked => diffPatchDisplayLineCount(state, patch),
        .split => blk: {
            if (patch.len == 0) break :blk 2;
            if (state) |app| {
                const view = app.transcript_controller.diff_view_cache.split(app.allocator, patch) orelse
                    break :blk @max(wrappedLineCount(patch, 120), 2);
                break :blk @max(view.rows.len, 1);
            }
            var view = zig_dif.buildSideBySidePatchViewWithOptions(std.heap.page_allocator, patch, .{ .context_lines = 4 }) catch
                break :blk diffPatchDisplayLineCount(null, patch);
            defer view.deinit();
            break :blk @max(view.rows.len, 1);
        },
    };
}

fn diffPatchDisplayLineCount(state: ?*app_state.AppState, patch: []const u8) usize {
    if (patch.len == 0) return 2;
    if (state) |app| {
        const view = app.transcript_controller.diff_view_cache.stacked(app.allocator, patch) orelse
            return @max(wrappedLineCount(patch, 120), 2);
        return @max(view.lines.len, 1);
    }
    var view = zig_dif.buildPatchViewWithOptions(std.heap.page_allocator, patch, .{ .context_lines = 4 }) catch
        return @max(wrappedLineCount(patch, 120), 2);
    defer view.deinit();
    return @max(view.lines.len, 1);
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
    const files = parseDiffSummary(state.allocator, body_raw) orelse {
        const bubble = snapRect(palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height });
        queueRoundedShellClipped(
            state,
            bubble,
            paletteColor(theme.COLOR_PANEL_ALT),
            paletteColor(theme.COLOR_DIFF_REMOVE),
            transcriptBubbleCornerRadius(),
            clip,
        );
        queueChromeLabel(state, .{
            .x = bubble.x + theme.scaledUi(14.0),
            .y = bubble.y + theme.scaledUi(12.0),
            .w = bubble.w - theme.scaledUi(28.0),
            .h = theme.scaledUi(22.0),
        }, "Diff could not be decoded", paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), clip);
        queueFixedTextLine(state, .{
            .x = bubble.x + theme.scaledUi(14.0),
            .y = bubble.y + theme.scaledUi(40.0),
            .w = bubble.w - theme.scaledUi(28.0),
            .h = theme.scaledUi(18.0),
        }, "The provider payload was incomplete or malformed.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), clip);
        return;
    };
    defer state.allocator.free(files);

    const bubble = snapRect(palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height });
    const rr = transcriptBubbleCornerRadius();
    const bg = theme.COLOR_PANEL_ALT;
    const border = theme.COLOR_PANEL_MUTED;
    queueRoundedShellClipped(state, bubble, paletteColor(bg), paletteColor(border), rr, clip);

    const pad_x = theme.scaledUi(14.0);
    const pad_y = theme.scaledUi(12.0);
    const header_h = theme.scaledUi(42.0);
    const row_h = theme.scaledUi(44.0);
    const can_split = bubble.w >= theme.scaledUi(DIFF_SPLIT_MIN_WIDTH_CSS);
    const layout = diffLayoutForWidth(state, bubble.w);

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
    const layout_toggle_w = if (can_split) theme.scaledUi(132.0) else 0.0;
    const layout_toggle_gap = if (can_split) theme.scaledUi(10.0) else 0.0;
    const header_counts_w = theme.scaledUi(86.0);
    const layout_toggle_rect = palette.Rect{
        .x = bubble.x + bubble.w - pad_x - layout_toggle_w,
        .y = header_y + theme.scaledUi(6.0),
        .w = layout_toggle_w,
        .h = theme.scaledUi(28.0),
    };
    const counts_x = if (can_split)
        layout_toggle_rect.x - layout_toggle_gap - header_counts_w
    else
        bubble.x + bubble.w - pad_x - header_counts_w;
    queueFixedTextLine(state, snapRect(.{
        .x = bubble.x + pad_x,
        .y = header_y + theme.scaledUi(9.0),
        .w = @max(counts_x - theme.scaledUi(10.0) - (bubble.x + pad_x), theme.scaledUi(80.0)),
        .h = theme.scaledUi(20.0),
    }), header_label orelse "Changed files", paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), clip);

    const counts = std.fmt.allocPrint(state.allocator, "+{d}  -{d}", .{ total_add, total_del }) catch null;
    defer if (counts) |t| state.allocator.free(t);
    queueFixedTextLine(state, snapRect(.{
        .x = counts_x,
        .y = header_y + theme.scaledUi(9.0),
        .w = header_counts_w,
        .h = theme.scaledUi(20.0),
    }), counts orelse "", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), clip);
    if (can_split) {
        renderDiffLayoutToggle(state, layout_toggle_rect, layout, clip);
    }

    // Separator below header
    queueRectClipped(state, snapRect(.{
        .x = bubble.x + pad_x,
        .y = header_y + header_h - 1.0,
        .w = bubble.w - pad_x * 2.0,
        .h = 1.0,
    }), paletteColor(theme.COLOR_PANEL_MUTED), clip);

    var row_y = bubble.y + pad_y + header_h;
    const file_font = theme.scaledUi(13.0);
    const code_font = theme.scaledUi(12.5);
    const code_line_h = theme.scaledUi(21.0);

    if (files.len == 0) {
        queueFixedTextLine(state, .{
            .x = bubble.x + pad_x,
            .y = row_y + theme.scaledUi(10.0),
            .w = bubble.w - pad_x * 2.0,
            .h = theme.scaledUi(20.0),
        }, "Diff data is empty or could not be restored.", paletteColor(theme.COLOR_TEXT_MUTED), file_font, clip);
        return;
    }

    for (files) |file| {
        const key = diffFileCardKey(message_index, file.path);
        const expanded = state.isCardExpanded(key);

        const row_rect = palette.Rect{ .x = bubble.x, .y = row_y, .w = bubble.w, .h = row_h };

        if (state.transcript_controller.palette_mouse_in_workspace and rectContains(row_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y)) {
            queueRectClipped(state, row_rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 90)), clip);
        }
        state.recordCardToggleHit(.{ .rect = row_rect, .key = key, .kind = .diff_file });

        // Chevron at left
        const chev_x = bubble.x + pad_x + theme.scaledUi(6.0);
        const chev_y = row_y + row_h * 0.5;
        queueCardChevron(state, chev_x, chev_y, expanded, paletteColor(theme.COLOR_TEXT_SUBTLE), clip);

        // Path
        const path_x = chev_x + theme.scaledUi(14.0);
        const action_w = theme.scaledUi(54.0);
        const action_h = theme.scaledUi(28.0);
        const action_gap = theme.scaledUi(6.0);
        const counts_w = theme.scaledUi(92.0);
        const actions_w = action_w * 2.0 + action_gap;
        const path_right = bubble.x + bubble.w - pad_x - counts_w - action_gap - actions_w;
        const path_w = @max(path_right - path_x, theme.scaledUi(40.0));
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
        const open_rect = palette.Rect{
            .x = bubble.x + bubble.w - pad_x - action_w,
            .y = row_y + (row_h - action_h) * 0.5,
            .w = action_w,
            .h = action_h,
        };
        const copy_rect = palette.Rect{
            .x = open_rect.x - action_gap - action_w,
            .y = open_rect.y,
            .w = action_w,
            .h = open_rect.h,
        };
        renderDiffFileActionButton(state, copy_rect, "Copy", false, clip);
        renderDiffFileActionButton(state, open_rect, "Open", true, clip);
        state.recordTranscriptCopyHit(copy_rect, file.patch, diffCopyIdentity(message_index, file.path, file.patch));
        if (diff_file_open_hit_count < diff_file_open_hits.len) {
            diff_file_open_hits[diff_file_open_hit_count] = .{ .rect = open_rect, .path = file.path };
            diff_file_open_hit_count += 1;
        }

        const counts_right = copy_rect.x - action_gap;
        const dels_w = counts_w * 0.5;
        const adds_w = counts_w * 0.5;
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

        if (expanded) {
            const patch_x = bubble.x + pad_x;
            const patch_w = bubble.w - pad_x * 2.0;
            const line_count = diffPatchDisplayLineCountForLayout(state, file.patch, layout);
            const patch_h = @as(f32, @floatFromInt(line_count)) * code_line_h;
            renderDiffPatch(state, .{
                .x = patch_x,
                .y = row_y + theme.scaledUi(8.0),
                .w = patch_w,
                .h = patch_h,
            }, file.patch, code_font, code_line_h, layout, clip);
            row_y += @as(f32, @floatFromInt(line_count)) * code_line_h + theme.scaledUi(20.0);
        }
    }
}

// Renders the stacked/split selector in the diff-card header.
fn renderDiffLayoutToggle(
    state: *app_state.AppState,
    rect: palette.Rect,
    layout: DiffLayout,
    clip: palette.Rect,
) void {
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
    renderDiffLayoutOption(state, stacked_rect, "Stacked", layout == .stacked, clip);
    renderDiffLayoutOption(state, split_rect, "Split", layout == .split, clip);
    if (diff_layout_hit_count + 2 <= diff_layout_hits.len) {
        diff_layout_hits[diff_layout_hit_count] = .{ .rect = stacked_rect, .split = false };
        diff_layout_hits[diff_layout_hit_count + 1] = .{ .rect = split_rect, .split = true };
        diff_layout_hit_count += 2;
    }
}

// Renders one segment of the diff-layout selector.
fn renderDiffLayoutOption(
    state: *app_state.AppState,
    rect: palette.Rect,
    label: []const u8,
    selected: bool,
    clip: palette.Rect,
) void {
    const hovered = state.transcript_controller.palette_mouse_in_workspace and
        rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
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
    queueCenteredChromeLabel(
        state,
        rect,
        label,
        paletteColor(if (selected or hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED),
        theme.scaledUi(10.5),
        clip,
    );
}

// Renders one file-row action in the diff card.
fn renderDiffFileActionButton(
    state: *app_state.AppState,
    rect: palette.Rect,
    label: []const u8,
    primary: bool,
    clip: palette.Rect,
) void {
    const hovered = state.transcript_controller.palette_mouse_in_workspace and
        rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
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
    queueCenteredChromeLabel(state, rect, label, paletteColor(text), theme.scaledUi(11.5), clip);
}

// Selects the expanded file's stacked or split patch renderer.
fn renderDiffPatch(
    state: *app_state.AppState,
    rect: palette.Rect,
    patch: []const u8,
    font_size: f32,
    line_h: f32,
    layout: DiffLayout,
    clip: palette.Rect,
) void {
    switch (layout) {
        .stacked => renderDiffPatchLines(state, rect, patch, font_size, line_h, clip),
        .split => renderDiffSplitPatchLines(state, rect, patch, font_size, line_h, clip),
    }
}

// Renders an aligned old/new patch with independent line-number gutters.
fn renderDiffSplitPatchLines(
    state: *app_state.AppState,
    rect: palette.Rect,
    patch: []const u8,
    font_size: f32,
    line_h: f32,
    clip: palette.Rect,
) void {
    if (patch.len == 0) {
        renderDiffPatchLines(state, rect, patch, font_size, line_h, clip);
        return;
    }

    const view = state.transcript_controller.diff_view_cache.split(state.allocator, patch) orelse {
        renderDiffPatchLines(state, rect, patch, font_size, line_h, clip);
        return;
    };

    queueRoundedShellClipped(
        state,
        rect,
        paletteColor(theme.md.code_bg),
        paletteColor(theme.md.code_border),
        theme.scaledUi(6.0),
        clip,
    );

    const divider_w = @max(theme.scaledUi(1.0), 1.0);
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
        switch (row.kind) {
            .code => {
                renderDiffSplitCell(state, .{
                    .x = left_rect.x,
                    .y = y,
                    .w = left_rect.w,
                    .h = line_h,
                }, row.left, font_size, clip);
                renderDiffSplitCell(state, .{
                    .x = right_rect.x,
                    .y = y,
                    .w = right_rect.w,
                    .h = line_h,
                }, row.right, font_size, clip);
            },
            .hunk_header, .context_gap, .file_header, .prelude, .note => {
                const row_rect = palette.Rect{ .x = rect.x, .y = y, .w = rect.w, .h = line_h };
                const fill = switch (row.kind) {
                    .hunk_header, .context_gap => theme.withAlpha(theme.COLOR_PANEL_MUTED, 155),
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
                renderDiffTokens(
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
            },
        }
    }
}

// Renders one old/new cell, including its blank alignment placeholder.
fn renderDiffSplitCell(
    state: *app_state.AppState,
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
            .w = theme.scaledUi(3.0),
            .h = rect.h,
        }, paletteColor(color), clip);
    }

    const number_w = theme.scaledUi(38.0);
    const code_pad = theme.scaledUi(9.0);
    const code_x = rect.x + number_w + code_pad;
    queueRectClipped(state, .{
        .x = rect.x + number_w,
        .y = rect.y,
        .w = @max(theme.scaledUi(1.0), 1.0),
        .h = rect.h,
    }, paletteColor(theme.md.code_border), clip);
    renderDiffLineNumber(state, rect.x, rect.y, number_w, rect.h, cell.line_number, font_size, clip);

    const code_clip = intersectRect(clip, .{
        .x = code_x,
        .y = rect.y,
        .w = @max(rect.w - number_w - code_pad * 2.0, 1.0),
        .h = rect.h,
    });
    if (change_color) |color| {
        renderDiffSplitEmphasis(state, code_x, rect.y, rect.h, font_size, cell, color, code_clip);
    }
    renderDiffTokens(
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
fn renderDiffSplitEmphasis(
    state: *app_state.AppState,
    code_x: f32,
    y: f32,
    line_h: f32,
    font_size: f32,
    cell: zig_dif.SideBySideCell,
    color: [4]f32,
    clip: palette.Rect,
) void {
    for (cell.emphasis_ranges) |range| {
        if (range.start >= range.end or range.end > cell.text.len) continue;
        const prefix_w = text_measure.textWidth(.mono, font_size, cell.text[0..range.start]);
        const range_w = text_measure.textWidth(.mono, font_size, cell.text[range.start..range.end]);
        queueRoundedClipped(state, .{
            .x = code_x + prefix_w,
            .y = y + theme.scaledUi(2.0),
            .w = @max(range_w, theme.scaledUi(2.0)),
            .h = @max(line_h - theme.scaledUi(4.0), 1.0),
        }, paletteColor(theme.withAlpha(color, 72)), theme.scaledUi(2.0), clip);
    }
}

fn renderDiffPatchLines(
    state: *app_state.AppState,
    rect: palette.Rect,
    patch: []const u8,
    font_size: f32,
    line_h: f32,
    clip: palette.Rect,
) void {
    queueRoundedShellClipped(
        state,
        rect,
        paletteColor(theme.md.code_bg),
        paletteColor(theme.md.code_border),
        theme.scaledUi(6.0),
        clip,
    );

    if (patch.len == 0) {
        renderDiffFallback(state, rect, "No textual patch was supplied for this file.", font_size, line_h, clip);
        return;
    }

    const view = state.transcript_controller.diff_view_cache.stacked(state.allocator, patch) orelse {
        renderDiffFallback(state, rect, patch, font_size, line_h, clip);
        return;
    };

    const number_w = theme.scaledUi(38.0);
    const gutter_w = number_w * 2.0;
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
        if (y > clip.y + clip.h or y + line_h < clip.y) continue;
        const row = palette.Rect{ .x = rect.x, .y = y, .w = rect.w, .h = line_h };
        const change_color: ?[4]f32 = switch (line.kind) {
            .addition => theme.COLOR_DIFF_ADD,
            .deletion => theme.COLOR_DIFF_REMOVE,
            else => null,
        };
        if (change_color) |color| {
            queueRectClipped(state, row, paletteColor(theme.withAlpha(color, 34)), clip);
            queueRectClipped(state, .{ .x = row.x, .y = row.y, .w = theme.scaledUi(3.0), .h = row.h }, paletteColor(color), clip);
        } else if (line.kind == .hunk_header or line.kind == .context_gap) {
            queueRectClipped(state, row, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 145)), clip);
        }
        queueRectClipped(state, .{ .x = rect.x + gutter_w, .y = y, .w = 1.0, .h = line_h }, paletteColor(theme.md.code_border), clip);

        renderDiffLineNumber(state, rect.x, y, number_w, line_h, line.old_line, font_size, clip);
        renderDiffLineNumber(state, rect.x + number_w, y, number_w, line_h, line.new_line, font_size, clip);
        renderDiffTokens(state, code_x, y, code_clip.w, line_h, line.tokens, line.kind, font_size, code_clip);
        if (line.kind == .hunk_header) {
            if (diffHunkSlice(patch, hunk_index)) |hunk| {
                const copy_rect = palette.Rect{
                    .x = rect.x + rect.w - theme.scaledUi(52.0),
                    .y = y + theme.scaledUi(2.0),
                    .w = theme.scaledUi(46.0),
                    .h = line_h - theme.scaledUi(4.0),
                };
                const hovered = state.transcript_controller.palette_mouse_in_workspace and
                    rectContains(copy_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
                queueRoundedClipped(
                    state,
                    copy_rect,
                    paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, if (hovered) 255 else 210)),
                    theme.scaledUi(4.0),
                    clip,
                );
                queueCenteredChromeLabel(
                    state,
                    copy_rect,
                    "Copy",
                    paletteColor(if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED),
                    theme.scaledUi(9.5),
                    clip,
                );
                state.recordTranscriptCopyHit(copy_rect, hunk, toolCopyIdentity(hunk_index, hunk));
            }
            hunk_index += 1;
        }
    }
}

fn diffHunkSlice(patch: []const u8, target_index: usize) ?[]const u8 {
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

fn renderDiffFallback(
    state: *app_state.AppState,
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

fn renderDiffLineNumber(
    state: *app_state.AppState,
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

fn renderDiffTokens(
    state: *app_state.AppState,
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
        const color = diffTokenColor(token.kind, line_kind);
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

fn diffTokenColor(kind: zig_dif.TokenKind, line_kind: zig_dif.DisplayLineKind) [4]f32 {
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

/// Stable key for the command-row expand/collapse state per message index.
fn commandCardKey(message_index: usize) u64 {
    return app_state.AppState.commandCardKey(message_index);
}

fn toolCallGroupHeight(
    state: *app_state.AppState,
    entries: anytype,
    start: usize,
    end: usize,
    base_message_index: usize,
    column_width: f32,
) f32 {
    const header_h = theme.scaledUi(48.0);
    const failed_count = toolCallGroupFailureCount(entries, start, end);
    const failed = failed_count > 0;
    const default_expanded = toolCallGroupDefaultExpanded(state, failed);
    if (!state.isCardExpandedDefault(toolCallGroupKey(base_message_index + start), default_expanded)) return header_h;

    const inset = theme.scaledUi(10.0);
    const child_width = @max(column_width - inset * 2.0, theme.scaledUi(80.0));
    var height = header_h + theme.scaledUi(8.0);
    for (entries[start..end], start..) |entry, index| {
        height += transcriptCommandEventHeight(state, base_message_index + index, entry.author, entry.body, child_width, toolCallEntryStatus(entry));
        height += theme.scaledUi(8.0);
    }
    return height + theme.scaledUi(2.0);
}

// Consecutive command/tool events are rendered as one transcript region.
fn renderToolCallGroup(
    state: *app_state.AppState,
    entries: anytype,
    start: usize,
    end: usize,
    base_message_index: usize,
    column: palette.Rect,
    y: f32,
    height: f32,
    clip: palette.Rect,
    fallback_running: bool,
    started_at_ms: ?i64,
) void {
    const failed_count = toolCallGroupFailureCount(entries, start, end);
    const failed = failed_count > 0;
    const running_count = toolCallGroupRunningCount(entries, start, end, fallback_running);
    const running = running_count > 0;
    const count = end - start;
    const completed_count = count -| failed_count -| running_count;
    const default_expanded = toolCallGroupDefaultExpanded(state, failed);
    const key = toolCallGroupKey(base_message_index + start);
    const expanded = state.isCardExpandedDefault(key, default_expanded);
    const bubble = palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height };
    queueRoundedShellClipped(
        state,
        bubble,
        paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 235)),
        // A failed child is identified by the status dot and its own row; the
        // group shell stays neutral so one failure does not tint every call.
        paletteColor(if (running and !failed) theme.COLOR_GREEN else theme.borderMuted()),
        transcriptBubbleCornerRadius(),
        clip,
    );

    const header_h = theme.scaledUi(48.0);
    const pad_x = theme.scaledUi(14.0);
    const status_dia = theme.scaledUi(9.0);
    const status_rect: palette.Rect = .{
        .x = bubble.x + pad_x,
        .y = bubble.y + (header_h - status_dia) * 0.5,
        .w = status_dia,
        .h = status_dia,
    };
    const normal_status_color = if (running) theme.COLOR_GREEN else theme.COLOR_TEXT_MUTED;
    const partial_failure = failed_count > 0 and failed_count < count;
    const status_color = if (failed and !partial_failure) theme.COLOR_DIFF_REMOVE else normal_status_color;
    queueRoundedClipped(state, status_rect, paletteColor(status_color), status_dia * 0.5, clip);
    if (partial_failure) {
        const center: palette.draw.Vec2 = .{ .x = status_rect.x + status_rect.w * 0.5, .y = status_rect.y + status_rect.h * 0.5 };
        const radius = status_dia * 0.5;
        const failed_ratio = @as(f32, @floatFromInt(failed_count)) / @as(f32, @floatFromInt(count));
        const sweep = std.math.tau * failed_ratio;
        const segment_angle = std.math.tau / 24.0;
        var angle: f32 = -std.math.pi / 2.0;
        const end_angle = angle + sweep;
        while (angle < end_angle) {
            const next_angle = @min(angle + segment_angle, end_angle);
            queueTriangleClipped(
                state,
                center,
                .{ .x = center.x + std.math.cos(angle) * radius, .y = center.y + std.math.sin(angle) * radius },
                .{ .x = center.x + std.math.cos(next_angle) * radius, .y = center.y + std.math.sin(next_angle) * radius },
                paletteColor(theme.COLOR_DIFF_REMOVE),
                clip,
            );
            angle = next_angle;
        }
    }

    var summary_buf: [128]u8 = undefined;
    const noun = if (count == 1) "tool call" else "tool calls";
    const summary = if (running) blk: {
        if (started_at_ms == null) {
            if (failed_count > 0) {
                break :blk std.fmt.bufPrint(
                    &summary_buf,
                    "{d} {s}  ·  {d} completed  ·  {d} failed  ·  {d} running",
                    .{ count, noun, completed_count, failed_count, running_count },
                ) catch "Tool calls running";
            }
            break :blk std.fmt.bufPrint(
                &summary_buf,
                "{d} {s}  ·  {d} completed  ·  {d} running",
                .{ count, noun, completed_count, running_count },
            ) catch "Tool calls running";
        }
        var elapsed_buf: [32]u8 = undefined;
        const elapsed = formatElapsedDuration(&elapsed_buf, started_at_ms.?);
        if (failed_count > 0) {
            break :blk std.fmt.bufPrint(
                &summary_buf,
                "{d} {s}  ·  {d} completed  ·  {d} failed  ·  {d} running  ·  {s}",
                .{ count, noun, completed_count, failed_count, running_count, elapsed },
            ) catch "Tool calls running";
        }
        break :blk std.fmt.bufPrint(
            &summary_buf,
            "{d} {s}  ·  {d} completed  ·  {d} running  ·  {s}",
            .{ count, noun, completed_count, running_count, elapsed },
        ) catch "Tool calls running";
    } else if (failed_count > 0)
        std.fmt.bufPrint(
            &summary_buf,
            "{d} {s}  ·  {d} completed  ·  {d} failed",
            .{ count, noun, completed_count, failed_count },
        ) catch "Tool calls completed with failures"
    else
        std.fmt.bufPrint(&summary_buf, "{d} {s}  ·  {d} completed", .{ count, noun, completed_count }) catch "Tool calls completed";

    const chev_w = theme.scaledUi(22.0);
    const text_x = bubble.x + pad_x + status_dia + theme.scaledUi(11.0);
    queueFixedTextLine(state, .{
        .x = text_x,
        .y = bubble.y + theme.scaledUi(14.0),
        .w = @max(bubble.w - (text_x - bubble.x) - pad_x - chev_w, theme.scaledUi(40.0)),
        .h = theme.scaledUi(20.0),
    }, summary, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), clip);
    queueCardChevron(state, bubble.x + bubble.w - pad_x - chev_w * 0.5, bubble.y + header_h * 0.5, expanded, paletteColor(theme.COLOR_TEXT_SUBTLE), clip);
    state.recordCardToggleHit(.{
        .rect = .{ .x = bubble.x, .y = bubble.y, .w = bubble.w, .h = header_h },
        .key = key,
        .kind = .tool_call_group,
        .default_expanded = default_expanded,
    });

    if (!expanded) return;
    const inset = theme.scaledUi(10.0);
    const child_column = palette.Rect{
        .x = column.x + inset,
        .y = column.y,
        .w = @max(column.w - inset * 2.0, theme.scaledUi(80.0)),
        .h = column.h,
    };
    var child_y = y + header_h + theme.scaledUi(8.0);
    for (entries[start..end], start..) |entry, index| {
        const message_index = base_message_index + index;
        const child_h = transcriptCommandEventHeight(state, message_index, entry.author, entry.body, child_column.w, toolCallEntryStatus(entry));
        renderCommandEventRow(
            state,
            child_column,
            child_y,
            child_h,
            entry.author,
            entry.body,
            clip,
            message_index,
            if (toolCallEntryStatus(entry)) |status|
                status == .pending or status == .in_progress
            else
                fallback_running and index + 1 == end,
            true,
            toolCallEntryStatus(entry),
        );
        child_y += child_h + theme.scaledUi(8.0);
    }
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
    grouped: bool,
    tool_call_status: ?ai_harness.ToolCallStatus,
) void {
    // Command transcript card, including controls for tracked background tasks.
    const bubble = palette.Rect{ .x = column.x, .y = y, .w = column.w, .h = height };
    const rr = if (grouped) theme.scaledUi(8.0) else transcriptBubbleCornerRadius();
    const is_running = if (tool_call_status) |status|
        status == .pending or status == .in_progress
    else
        running;
    const failed = commandEventFailed(original_author) or (tool_call_status orelse .unknown) == .failed;
    const stopped = std.mem.eql(u8, original_author, "Background task stopped") or (tool_call_status orelse .unknown) == .cancelled;
    const fill_color = if (grouped) theme.darken(theme.background(), 0.035) else theme.COLOR_PANEL_ALT;
    const resting_border = if (grouped) theme.withAlpha(theme.borderMuted(), 185) else theme.borderMuted();
    queueRoundedShellClipped(
        state,
        bubble,
        paletteColor(fill_color),
        paletteColor(if (failed) theme.COLOR_DIFF_REMOVE else if (stopped) theme.COLOR_YELLOW else resting_border),
        rr,
        clip,
    );

    const pad_x = theme.scaledUi(14.0);
    const pad_y = theme.scaledUi(9.0);
    const font_size = theme.scaledUi(15.0);
    const line_h = font_size * 1.28;
    const header_h = line_h + pad_y * 2.0;

    const key = commandCardKey(message_index);
    const default_expanded = failed;
    const expanded = state.isCardExpandedDefault(key, default_expanded);

    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    const label = paletteCommandRowDisplayAuthor(original_author, body_raw);

    const status_dia = theme.scaledUi(8.0);
    const status_cx = bubble.x + pad_x + status_dia * 0.5;
    const status_cy = bubble.y + pad_y + line_h * 0.5;
    const status_color: [4]f32 = blk: {
        if (failed) break :blk theme.COLOR_DIFF_REMOVE;
        if (stopped) break :blk theme.COLOR_YELLOW;
        if (is_running) {
            const t_ns: i128 = profiler.nowNs();
            const period_ns: i128 = 1_400_000_000;
            const phase = @as(f32, @floatFromInt(@mod(t_ns, period_ns))) / @as(f32, @floatFromInt(period_ns));
            const sin_t = std.math.sin(phase * std.math.tau);
            const alpha = 0.45 + 0.55 * (sin_t * 0.5 + 0.5);
            break :blk theme.withAlpha(theme.COLOR_GREEN, @intFromFloat(alpha * 255.0));
        }
        break :blk theme.COLOR_GREEN;
    };
    queueRoundedClipped(state, .{
        .x = status_cx - status_dia * 0.5,
        .y = status_cy - status_dia * 0.5,
        .w = status_dia,
        .h = status_dia,
    }, paletteColor(status_color), status_dia * 0.5, clip);

    const copy_w = theme.scaledUi(56.0);
    const copy_h = theme.scaledUi(26.0);
    const copy_gap = theme.scaledUi(8.0);
    const chev_box_w = theme.scaledUi(18.0);
    const chev_cx = bubble.x + bubble.w - pad_x - chev_box_w * 0.5;
    const chev_cy = status_cy;
    queueCardChevron(state, chev_cx, chev_cy, expanded, paletteColor(theme.COLOR_TEXT_SUBTLE), clip);

    const text_x = status_cx + status_dia * 0.5 + theme.scaledUi(10.0);
    const backgrounded = chat_types.ChatThread.isBackgroundCommandEvent(original_author);
    const local_bang = (std.mem.eql(u8, original_author, "Ran command") or std.mem.eql(u8, original_author, "Command failed")) and std.mem.startsWith(u8, body, "$ ");
    const command_end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    const retry_command = if (local_bang) std.mem.trim(u8, body[2..command_end], " \t\r") else "";
    const action_w = theme.scaledUi(58.0);
    const action_gap = theme.scaledUi(6.0);
    const show_output = backgrounded and bubble.w >= theme.scaledUi(330.0);
    const output_label = if (std.mem.indexOf(u8, body, "\nOutput log:") != null) "Output" else "Details";
    const show_copy = !backgrounded or !is_running or bubble.w >= theme.scaledUi(210.0);
    const action_right = bubble.x + bubble.w - pad_x - chev_box_w - copy_gap;
    const stop_visible = backgrounded and is_running;
    const stop_rect = snapRect(palette.Rect{
        .x = action_right - action_w,
        .y = bubble.y + (header_h - copy_h) * 0.5,
        .w = action_w,
        .h = copy_h,
    });
    const copy_right = if (stop_visible) stop_rect.x - action_gap else action_right;
    const copy_rect = snapRect(palette.Rect{
        .x = copy_right - copy_w,
        .y = stop_rect.y,
        .w = copy_w,
        .h = copy_h,
    });
    const retry_rect = snapRect(palette.Rect{
        .x = (if (show_copy) copy_rect.x else copy_right) - action_gap - action_w,
        .y = stop_rect.y,
        .w = action_w,
        .h = copy_h,
    });
    const output_right = if (local_bang) retry_rect.x - action_gap else if (show_copy) copy_rect.x - action_gap else if (stop_visible) stop_rect.x - action_gap else action_right;
    const output_rect = snapRect(palette.Rect{
        .x = output_right - action_w,
        .y = stop_rect.y,
        .w = action_w,
        .h = copy_h,
    });
    const leftmost_action_x = if (show_output) output_rect.x else if (local_bang) retry_rect.x else if (show_copy) copy_rect.x else stop_rect.x;
    const text_right = leftmost_action_x - copy_gap;
    const text_w = @max(text_right - text_x, theme.scaledUi(40.0));
    const header_text_clip = intersectClipRect(clip, .{
        .x = text_x,
        .y = bubble.y,
        .w = @max(text_right - text_x, 0.0),
        .h = header_h,
    });
    const text_color = if (failed) paletteColor(theme.COLOR_DIFF_REMOVE) else paletteColor(theme.COLOR_TEXT_MUTED);

    const copy_hovered = show_copy and rectContains(copy_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    // Match the composer model pill: a quiet translucent resting fill that
    // becomes lighter and more opaque when the pointer enters the control.
    const copy_bg = if (copy_hovered)
        theme.withAlpha(theme.lighten(theme.COLOR_PANEL_ALT, 0.08), 210)
    else
        theme.withAlpha(theme.COLOR_PANEL_MUTED, 86);
    const copy_text_color = if (copy_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    const copy_label_h = theme.scaledUi(14.0);
    const copy_payload = if (backgrounded) blk: {
        const end = std.mem.indexOf(u8, body, "\n\n") orelse body.len;
        break :blk std.mem.trim(u8, body[0..end], "\n\r\t ");
    } else body_raw;
    if (show_copy) {
        queueRoundedClipped(state, copy_rect, paletteColor(copy_bg), theme.scaledUi(5.0), clip);
        queueFixedTextLine(state, .{
            .x = copy_rect.x + theme.scaledUi(10.0),
            .y = copy_rect.y + (copy_rect.h - copy_label_h) * 0.5,
            .w = copy_rect.w - theme.scaledUi(20.0),
            .h = copy_label_h,
        }, "Copy", paletteColor(copy_text_color), theme.scaledUi(11.5), clip);
        state.recordTranscriptCopyHit(copy_rect, copy_payload, toolCopyIdentity(message_index, copy_payload));
    }

    if (local_bang and retry_command.len > 0) {
        const retry_hovered = rectContains(retry_rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
        queueRoundedClipped(state, retry_rect, paletteColor(if (retry_hovered) theme.withAlpha(theme.COLOR_GREEN, 72) else theme.withAlpha(theme.COLOR_PANEL_MUTED, 86)), theme.scaledUi(5.0), clip);
        queueFixedTextLine(state, .{
            .x = retry_rect.x + theme.scaledUi(8.0),
            .y = retry_rect.y + (retry_rect.h - copy_label_h) * 0.5,
            .w = retry_rect.w - theme.scaledUi(16.0),
            .h = copy_label_h,
        }, "Retry", paletteColor(if (retry_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(11.5), clip);
        if (bang_retry_hit_count < bang_retry_hits.len) {
            bang_retry_hits[bang_retry_hit_count] = .{ .rect = retry_rect, .command = retry_command };
            bang_retry_hit_count += 1;
        }
    }

    if (backgrounded) {
        if (show_output) {
            queueRoundedClipped(state, output_rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 86)), theme.scaledUi(5.0), clip);
            queueFixedTextLine(state, .{ .x = output_rect.x + theme.scaledUi(7.0), .y = output_rect.y + theme.scaledUi(6.0), .w = output_rect.w - theme.scaledUi(14.0), .h = theme.scaledUi(14.0) }, output_label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(11.5), clip);
            if (intersectClipRect(intersectClipRect(output_rect, bubble), clip)) |clipped_output| {
                state.recordBackgroundTaskActionForMessage(clipped_output, message_index, body_raw, .output);
            }
        }
        if (stop_visible) {
            queueRoundedClipped(state, stop_rect, paletteColor(theme.withAlpha(theme.COLOR_DIFF_REMOVE, 55)), theme.scaledUi(5.0), clip);
            queueFixedTextLine(state, .{ .x = stop_rect.x + theme.scaledUi(14.0), .y = stop_rect.y + theme.scaledUi(6.0), .w = stop_rect.w - theme.scaledUi(28.0), .h = theme.scaledUi(14.0) }, "Stop", paletteColor(theme.COLOR_DIFF_REMOVE), theme.scaledUi(11.5), clip);
            if (intersectClipRect(intersectClipRect(stop_rect, bubble), clip)) |clipped_stop| {
                state.recordBackgroundTaskActionForMessage(clipped_stop, message_index, body_raw, .stop);
            }
        }
    }

    const mono_w = font_size * 0.55;
    const text_y = bubble.y + pad_y + (line_h - font_size * 1.25) * 0.5;
    const icon_text = if (grouped) "$" else ">_";
    const icon_w = @as(f32, @floatFromInt(icon_text.len)) * mono_w;
    const gap = theme.scaledUi(7.0);
    const label_x = text_x + icon_w + gap;
    const label_w = @as(f32, @floatFromInt(label.len)) * mono_w;
    const separator_gap = theme.scaledUi(8.0);
    const separator = "-";
    const separator_w = @as(f32, @floatFromInt(separator.len)) * mono_w;
    const separator_x = label_x + label_w + separator_gap;
    const body_x = separator_x + separator_w + separator_gap;
    const body_w = @max(text_right - body_x, 0.0);

    queueFixedTextLine(state, snapRect(.{
        .x = text_x,
        .y = text_y,
        .w = @min(icon_w, text_w),
        .h = font_size * 1.25,
    }), icon_text, text_color, font_size, header_text_clip);

    if (label_x < text_right) {
        queueFixedTextLine(state, snapRect(.{
            .x = label_x,
            .y = text_y,
            .w = @min(label_w, @max(text_right - label_x, 0.0)),
            .h = font_size * 1.25,
        }), label, text_color, font_size, header_text_clip);
    }

    if (body_w > mono_w * 3.0 and body.len > 0) {
        queueFixedTextLine(state, snapRect(.{
            .x = separator_x,
            .y = text_y,
            .w = @min(separator_w, @max(text_right - separator_x, 0.0)),
            .h = font_size * 1.25,
        }), separator, text_color, font_size, header_text_clip);

        const owned_preview = commandRowPreviewAlloc(state.allocator, body) catch null;
        defer if (owned_preview) |preview| state.allocator.free(preview);
        const preview = owned_preview orelse firstTextLine(body);
        const display_body = truncateMonoToWidth(state.allocator, preview, body_w, font_size);
        defer if (display_body.allocated) state.allocator.free(display_body.text);
        queueFixedTextLine(state, snapRect(.{
            .x = body_x,
            .y = text_y,
            .w = body_w,
            .h = font_size * 1.25,
        }), display_body.text, paletteColor(theme.COLOR_TEXT_SUBTLE), font_size, header_text_clip);
    }

    state.recordCardToggleHit(.{
        .rect = .{ .x = bubble.x, .y = bubble.y, .w = bubble.w, .h = header_h },
        .key = key,
        .kind = .command_card,
        .default_expanded = default_expanded,
    });

    if (expanded) {
        if (grouped) {
            queueRoundedClipped(state, .{
                .x = bubble.x + theme.scaledUi(1.0),
                .y = bubble.y + header_h,
                .w = @max(bubble.w - theme.scaledUi(2.0), 1.0),
                .h = @max(bubble.h - header_h - theme.scaledUi(1.0), 1.0),
            }, paletteColor(theme.darken(theme.background(), 0.065)), theme.scaledUi(6.0), clip);
            queueRoundedClipped(state, .{
                .x = bubble.x + pad_x,
                .y = bubble.y + header_h,
                .w = @max(bubble.w - pad_x * 2.0, 1.0),
                .h = theme.scaledUi(1.0),
            }, paletteColor(theme.withAlpha(theme.borderMuted(), 170)), 0.0, clip);
        }
        const inner = palette.Rect{
            .x = bubble.x + pad_x,
            .y = bubble.y + header_h,
            .w = @max(bubble.w - pad_x * 2.0, theme.scaledUi(40.0)),
            .h = @max(bubble.h - header_h - pad_y, theme.scaledUi(1.0)),
        };
        const chars_per_line = @max(@as(usize, @intFromFloat(inner.w / (font_size * 0.52))), 1);
        const line_count = wrappedLineCount(body, chars_per_line);
        const output_key = toolOutputKey(message_index);
        const show_all = state.isCardExpanded(output_key);
        const visible_lines = if (show_all) line_count else @min(line_count, TOOL_OUTPUT_COLLAPSED_LINES);
        const body_h = @as(f32, @floatFromInt(visible_lines)) * line_h;
        renderWrappedBody(state, .{ .x = inner.x, .y = inner.y, .w = inner.w, .h = body_h }, body, paletteColor(theme.COLOR_TEXT_MUTED), font_size, clip);
        if (!show_all and line_count > visible_lines) {
            const more_label = "Show more";
            const more_font = theme.scaledUi(12.0);
            const more_pad_x = theme.scaledUi(6.0);
            const more_w = @as(f32, @floatFromInt(more_label.len)) * more_font * 0.55 + more_pad_x * 2.0;
            const more_rect = palette.Rect{
                .x = inner.x + inner.w - more_w,
                .y = inner.y + body_h,
                .w = more_w,
                .h = theme.scaledUi(26.0),
            };
            queueFixedTextLine(state, .{
                .x = more_rect.x + more_pad_x,
                .y = more_rect.y,
                .w = more_rect.w - more_pad_x * 2.0,
                .h = more_rect.h,
            }, more_label, paletteColor(theme.COLOR_GREEN), more_font, clip);
            state.recordCardToggleHit(.{ .rect = more_rect, .key = output_key, .kind = .tool_output });
        }
    }
}

fn intersectClipRect(parent: ?palette.Rect, child: palette.Rect) ?palette.Rect {
    const p = parent orelse return child;
    const x = @max(p.x, child.x);
    const y = @max(p.y, child.y);
    const right = @min(p.x + p.w, child.x + child.w);
    const bottom = @min(p.y + p.h, child.y + child.h);
    return .{
        .x = x,
        .y = y,
        .w = @max(right - x, 0.0),
        .h = @max(bottom - y, 0.0),
    };
}

/// Right-pointing triangle when collapsed, down-pointing when expanded.
/// Clipped so rows scrolled out of the transcript never bleed into other panes.
fn queueCardChevron(state: *app_state.AppState, cx: f32, cy: f32, expanded: bool, color: palette.Color, clip: palette.Rect) void {
    const half = theme.scaledUi(4.0);
    if (expanded) {
        queueTriangleClipped(
            state,
            .{ .x = cx - half, .y = cy - half * 0.5 },
            .{ .x = cx + half, .y = cy - half * 0.5 },
            .{ .x = cx, .y = cy + half * 0.7 },
            color,
            clip,
        );
    } else {
        queueTriangleClipped(
            state,
            .{ .x = cx - half * 0.5, .y = cy - half },
            .{ .x = cx + half * 0.7, .y = cy },
            .{ .x = cx - half * 0.5, .y = cy + half },
            color,
            clip,
        );
    }
}

// Transcript message bubble, including the live activity cue for a pending assistant turn.
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
    active: bool,
) void {
    const bubble_width = if (role == .user) column.w * 0.62 else column.w;
    const bubble_x = if (role == .user) column.x + column.w - bubble_width else column.x;
    const bubble = snapRect(palette.Rect{ .x = bubble_x, .y = y, .w = bubble_width, .h = height });
    const bg = switch (role) {
        .user => theme.withAlpha(theme.accent(), 64),
        .assistant => theme.withAlpha(theme.background(), 242),
        .system => theme.withAlpha(theme.COLOR_YELLOW, 54),
    };
    const rr = transcriptBubbleCornerRadius();
    const activity = if (active) theme.activityPulse(profiler.nowNs()) else 0.0;
    const border_color = if (active)
        theme.withAlpha(theme.COLOR_GREEN, @intFromFloat(92.0 + activity * 88.0))
    else
        theme.COLOR_PANEL_MUTED;
    queueRoundedShellClipped(state, bubble, paletteColor(bg), paletteColor(border_color), rr, clip);

    var label_x = bubble.x + theme.scaledUi(14.0);
    if (active) {
        const core_d = theme.scaledUi(5.5);
        const halo_d = core_d + theme.scaledUi(5.0) * activity;
        const center_x = label_x + halo_d * 0.5;
        const center_y = bubble.y + theme.scaledUi(19.0);
        queueRoundedClipped(state, .{
            .x = center_x - halo_d * 0.5,
            .y = center_y - halo_d * 0.5,
            .w = halo_d,
            .h = halo_d,
        }, paletteColor(theme.withAlpha(theme.COLOR_GREEN, @intFromFloat(28.0 + activity * 48.0))), halo_d * 0.5, clip);
        queueRoundedClipped(state, .{
            .x = center_x - core_d * 0.5,
            .y = center_y - core_d * 0.5,
            .w = core_d,
            .h = core_d,
        }, paletteColor(theme.withAlpha(theme.COLOR_GREEN, @intFromFloat(180.0 + activity * 75.0))), core_d * 0.5, clip);
        label_x += halo_d + theme.scaledUi(6.0);
    }
    queueText(state, snapRect(.{
        .x = label_x,
        .y = bubble.y + theme.scaledUi(9.0),
        .w = @max(bubble.x + bubble.w - theme.scaledUi(14.0) - label_x, theme.scaledUi(20.0)),
        .h = theme.scaledUi(20.0),
    }), role_label, paletteColor(if (active) theme.COLOR_GREEN else theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), clip);
    const body_rect = palette.Rect{
        .x = bubble.x + theme.scaledUi(14.0),
        .y = bubble.y + theme.scaledUi(34.0),
        .w = bubble.w - theme.scaledUi(28.0),
        .h = bubble.h - theme.scaledUi(42.0),
    };
    const body_text = std.mem.trim(u8, body_raw, "\n\r\t ");
    if (role == .assistant and !muted_body and !assistant_plain_layout) {
        renderMarkdownBody(state, message_index, body_rect, body_text, clip, streaming);
    } else {
        renderPlainSelectableBody(
            state,
            message_index,
            body_rect,
            body_text,
            if (muted_body) theme.COLOR_TEXT_MUTED else theme.COLOR_WHITE,
            clip,
        );
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

fn transcriptMarkdownOptions() chat_markdown.RenderOptions {
    return markdownOptions(theme.scaledUi(TRANSCRIPT_MARKDOWN_FONT_SIZE));
}

fn transcriptSelectableOptions(kind: TranscriptSelectableBodyKind) chat_markdown.RenderOptions {
    return switch (kind) {
        .markdown => transcriptMarkdownOptions(),
        .plain => transcriptPlainTextOptions(theme.COLOR_WHITE),
    };
}

fn transcriptPlainTextOptions(color: [4]f32) chat_markdown.RenderOptions {
    const font_size = theme.scaledUi(TRANSCRIPT_MARKDOWN_FONT_SIZE);
    return .{
        .base_font_size = font_size,
        .line_height = font_size * 1.38,
        .glyph_width = font_size * 0.52,
        .text_color = color,
    };
}

fn renderMarkdownBody(state: *app_state.AppState, message_index: usize, rect: palette.Rect, body: []const u8, clip: palette.Rect, streaming: bool) void {
    if (body.len == 0) return;
    // Cached path only applies to committed (non-streaming) messages — the
    // stream body changes per frame so the cache key would invalidate anyway.
    if (!streaming) {
        if (state.transcriptMarkdownBodyEntry(message_index, body)) |entry| {
            renderSelectableBodyEntry(state, message_index, rect, entry, clip, transcriptMarkdownOptions(), true);
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
    renderSelectableBodyView(state, message_index, rect, view, clip, transcriptMarkdownOptions(), true);
}

fn renderPlainSelectableBody(state: *app_state.AppState, message_index: usize, rect: palette.Rect, body: []const u8, color: [4]f32, clip: palette.Rect) void {
    if (body.len == 0) return;
    // Committed rows are immutable between transcript mutations. Reuse their
    // parsed selectable geometry; pending stream indices intentionally miss
    // this cache and continue rebuilding from their latest body immediately.
    if (state.transcriptPlainBodyEntry(message_index, body)) |entry| {
        renderSelectableBodyEntry(state, message_index, rect, entry, clip, transcriptPlainTextOptions(color), false);
        return;
    }
    var view = chat_markdown.buildPlainBodyView(state.allocator, body) catch {
        renderWrappedBody(state, rect, body, paletteColor(color), theme.scaledUi(TRANSCRIPT_MARKDOWN_FONT_SIZE), clip);
        return;
    };
    defer view.deinit(state.allocator);
    renderSelectableBodyView(state, message_index, rect, view, clip, transcriptPlainTextOptions(color), false);
}

fn renderSelectableBodyView(
    state: *app_state.AppState,
    message_index: usize,
    rect: palette.Rect,
    view: chat_markdown.BodyView,
    clip: palette.Rect,
    options: chat_markdown.RenderOptions,
    code_copy: bool,
) void {
    const local_sel: ?chat_markdown.SelectionRange = if (state.peekTranscriptMarkdownSelection()) |s| blk: {
        break :blk chat_markdown.localMarkdownSelectionRangeForMessage(
            state.allocator,
            s.anchor.message_index,
            s.anchor.point,
            s.focus.message_index,
            s.focus.point,
            message_index,
            view,
            rect.w,
            options,
        ) catch null;
    } else null;

    const mx = state.transcript_controller.palette_mouse_x;
    const my = state.transcript_controller.palette_mouse_y;
    const hovered = state.transcript_controller.palette_mouse_in_workspace and rectContains(rect, mx, my) and rectContains(clip, mx, my);

    var context = chat_markdown.PaletteRenderContext{
        .allocator = state.allocator,
        .batch = &state.palette_overlay_batch,
        .frame_text = &state.palette_frame_text,
        .text_arena = &state.palette_frame_text_arena,
        .cursor = rect,
        .available_width = rect.w,
        .mouse_pos = if (state.transcript_controller.palette_mouse_in_workspace) .{ mx, my } else .{ -1.0, -1.0 },
        .hovered = hovered,
        .clip = clip,
        .code_copy_recorder = if (code_copy) state.codeCopyButtonRecorder() else null,
    };
    var sel_out = chat_markdown.renderSelectablePaletteBody(
        &context,
        state.allocator,
        view,
        options,
        local_sel,
        false,
    );
    defer sel_out.deinit(state.allocator);
}

fn renderSelectableBodyEntry(
    state: *app_state.AppState,
    message_index: usize,
    rect: palette.Rect,
    entry: *app_state.TranscriptMarkdownBody,
    clip: palette.Rect,
    options: chat_markdown.RenderOptions,
    code_copy: bool,
) void {
    if (transcriptBodyRenderCacheEligible(state, message_index, entry.view, code_copy) and
        replayTranscriptBodyRenderCache(state, rect, entry, clip, options))
    {
        return;
    }
    renderSelectableBodyView(state, message_index, rect, entry.view, clip, options, code_copy);
}

fn transcriptBodyRenderCacheEligible(state: *app_state.AppState, message_index: usize, view: chat_markdown.BodyView, code_copy: bool) bool {
    if (state.peekTranscriptMarkdownSelection()) |selection| {
        if (transcriptMessageIntersectsSelection(message_index, selection)) return false;
    }
    return !code_copy or !transcriptBodyViewHasFencedCode(view);
}

fn transcriptMessageIntersectsSelection(message_index: usize, selection: app_state.TranscriptMarkdownSelection) bool {
    const first = @min(selection.anchor.message_index, selection.focus.message_index);
    const last = @max(selection.anchor.message_index, selection.focus.message_index);
    return message_index >= first and message_index <= last;
}

fn transcriptBodyViewHasFencedCode(view: chat_markdown.BodyView) bool {
    for (view.blocks) |block| {
        if (block.kind() == .fenced_code) return true;
    }
    return false;
}

fn replayTranscriptBodyRenderCache(
    state: *app_state.AppState,
    rect: palette.Rect,
    entry: *app_state.TranscriptMarkdownBody,
    clip: palette.Rect,
    options: chat_markdown.RenderOptions,
) bool {
    const key: chat_types.TranscriptRenderCacheKey = .{
        .width = rect.w,
        .height = rect.h,
        .ui_scale = theme.uiScaleFactor(),
        .style_hash = transcriptBodyRenderStyleHash(entry.kind, options),
    };

    if (entry.render_cache_key == null or !transcriptRenderCacheKeysEqual(entry.render_cache_key.?, key)) {
        entry.render_cache.clear();
        entry.render_cache_frame_text.clearRetainingCapacity();
        _ = entry.render_cache_text_arena.reset(.retain_capacity);

        var context: chat_markdown.PaletteRenderContext = .{
            .allocator = state.allocator,
            .batch = &entry.render_cache,
            .frame_text = &entry.render_cache_frame_text,
            .text_arena = &entry.render_cache_text_arena,
            .cursor = .{ .x = 0.0, .y = 0.0, .w = rect.w, .h = rect.h },
            .available_width = rect.w,
            .mouse_pos = .{ -1.0, -1.0 },
            .hovered = false,
            .clip = null,
            .code_copy_recorder = null,
        };
        var output = chat_markdown.renderSelectablePaletteBody(
            &context,
            state.allocator,
            entry.view,
            options,
            null,
            false,
        );
        output.deinit(state.allocator);
        entry.render_cache_key = key;
    }

    state.palette_overlay_batch.appendTranslatedBatch(
        state.allocator,
        &entry.render_cache,
        .{ .x = rect.x, .y = rect.y },
        clip,
    ) catch return false;
    return true;
}

fn transcriptRenderCacheKeysEqual(a: chat_types.TranscriptRenderCacheKey, b: chat_types.TranscriptRenderCacheKey) bool {
    return @abs(a.width - b.width) <= 0.01 and
        @abs(a.height - b.height) <= 0.01 and
        @abs(a.ui_scale - b.ui_scale) <= 0.001 and
        a.style_hash == b.style_hash;
}

fn transcriptBodyRenderStyleHash(kind: chat_types.TranscriptBodyKind, options: chat_markdown.RenderOptions) u64 {
    var hasher = std.hash.Wyhash.init(0x87A6_41D9_10B3_E52C);
    const kind_value: u8 = @intFromEnum(kind);
    hasher.update(std.mem.asBytes(&kind_value));
    hasher.update(std.mem.asBytes(&theme.current_colors));
    hasher.update(std.mem.asBytes(&options.base_font_size));
    hashOptionalFloat(&hasher, options.heading_font_size);
    hashOptionalFloat(&hasher, options.line_height);
    hashOptionalFloat(&hasher, options.glyph_width);
    hashOptionalFloat(&hasher, options.code_font_size);
    if (options.text_color) |color| hasher.update(std.mem.asBytes(&color));
    return hasher.final();
}

fn hashOptionalFloat(hasher: *std.hash.Wyhash, value: ?f32) void {
    const present: u8 = if (value == null) 0 else 1;
    hasher.update(std.mem.asBytes(&present));
    if (value) |number| hasher.update(std.mem.asBytes(&number));
}

test "transcript render cache key ignores pane translation and viewport clipping" {
    const base: chat_types.TranscriptRenderCacheKey = .{
        .width = 640,
        .height = 220,
        .ui_scale = 1.25,
        .style_hash = 42,
    };
    var moved = base;
    try std.testing.expect(transcriptRenderCacheKeysEqual(base, moved));
    moved.width += 1;
    try std.testing.expect(!transcriptRenderCacheKeysEqual(base, moved));
}

test "transcript render cache excludes fenced code copy controls" {
    var prose = try chat_markdown.buildBodyView(std.testing.allocator, "A paragraph with **formatting**.");
    defer prose.deinit(std.testing.allocator);
    try std.testing.expect(!transcriptBodyViewHasFencedCode(prose));

    var code = try chat_markdown.buildBodyView(std.testing.allocator, "```zig\nconst value = 1;\n```");
    defer code.deinit(std.testing.allocator);
    try std.testing.expect(transcriptBodyViewHasFencedCode(code));
}

test "transcript render cache only invalidates selected messages" {
    const selection: app_state.TranscriptMarkdownSelection = .{
        .anchor = .{ .message_index = 7, .point = .{ .line_index = 0, .column = 2 } },
        .focus = .{ .message_index = 5, .point = .{ .line_index = 1, .column = 4 } },
    };
    try std.testing.expect(!transcriptMessageIntersectsSelection(4, selection));
    try std.testing.expect(transcriptMessageIntersectsSelection(5, selection));
    try std.testing.expect(transcriptMessageIntersectsSelection(6, selection));
    try std.testing.expect(transcriptMessageIntersectsSelection(7, selection));
    try std.testing.expect(!transcriptMessageIntersectsSelection(8, selection));
}

const TruncatedText = struct {
    text: []const u8,
    allocated: bool,
};

fn firstTextLine(text: []const u8) []const u8 {
    for (text, 0..) |byte, index| {
        if (byte == '\n' or byte == '\r') return text[0..index];
    }
    return text;
}

fn commandRowPreviewAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var preview: std.ArrayList(u8) = .empty;
    errdefer preview.deinit(allocator);
    try preview.ensureTotalCapacity(allocator, text.len);

    var pending_space = false;
    for (text) |byte| {
        const whitespace = switch (byte) {
            ' ', '\t', '\n', '\r' => true,
            else => false,
        };
        if (whitespace) {
            pending_space = preview.items.len > 0;
            continue;
        }
        if (pending_space) preview.appendAssumeCapacity(' ');
        preview.appendAssumeCapacity(byte);
        pending_space = false;
    }
    return preview.toOwnedSlice(allocator);
}

test "command row preview includes content after its input label" {
    const preview = try commandRowPreviewAlloc(std.testing.allocator, "Input:\n  {\"cmd\":\"mise run build\"}");
    defer std.testing.allocator.free(preview);
    try std.testing.expectEqualStrings("Input: {\"cmd\":\"mise run build\"}", preview);
}

test "command row preview flattens CRLF without trailing whitespace" {
    const preview = try commandRowPreviewAlloc(std.testing.allocator, "Output:\r\n{\"success\":true}\n\n");
    defer std.testing.allocator.free(preview);
    try std.testing.expectEqualStrings("Output: {\"success\":true}", preview);
}

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
    var composer_batch: palette.RenderBatch = .{};
    defer composer_batch.deinit(state.allocator);
    state.composer_controller.composer.render(state.allocator, &composer_batch) catch |err| {
        app_state.log.warn("failed to render palette composer: {s}", .{@errorName(err)});
    };
    state.palette_overlay_batch.appendStableBatch(state.allocator, state.palette_frame_text_arena.allocator(), &composer_batch) catch |err| {
        app_state.log.warn("failed to stage palette composer render commands: {s}", .{@errorName(err)});
    };
    renderComposerFileSearchResults(state);
    renderComposerSlashCommands(state);
    renderComposerDraftImage(state);
    renderComposerFollowupHint(state);
    renderComposerToolbarIcons(state);
    state.syncComposerToolbarOverlayHitRects();
}

/// Renders the unfocused split-pane prompt preview without touching the shared live composer widget.
fn renderInactiveComposer(state: *app_state.AppState, rect: palette.Rect) void {
    const radius = theme.scaledUi(13.0);
    queuePanel(
        state,
        rect,
        paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 248)),
        paletteColor(theme.COLOR_PANEL_MUTED),
        radius,
        @max(theme.scaledUi(1.0), 1.0),
    );

    const draft = state.currentDraft();
    const text = if (draft.len == 0)
        "Ask anything, or use / to show available commands"
    else if (std.mem.findScalar(u8, draft, '\n')) |newline|
        draft[0..newline]
    else
        draft;
    const color = if (draft.len == 0)
        paletteColor(theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 220))
    else
        paletteColor(theme.COLOR_WHITE);
    const pad = theme.scaledUi(18.0);
    const toolbar_h = theme.scaledUi(42.0);
    queueText(state, .{
        .x = rect.x + pad,
        .y = rect.y + theme.scaledUi(18.0),
        .w = @max(rect.w - pad * 2.0, theme.scaledUi(1.0)),
        .h = @max(rect.h - toolbar_h - theme.scaledUi(24.0), theme.scaledUi(20.0)),
    }, text, color, theme.scaledUi(15.5), rect);

    renderInactiveComposerToolbar(state, rect);
    renderInactiveComposerSubmit(state, rect);
}

// Renders the read-only composer toolbar shown in split panes that do not own live input.
fn renderInactiveComposerToolbar(state: *app_state.AppState, rect: palette.Rect) void {
    const thread = state.currentThread();
    const pad = theme.scaledUi(18.0);
    const gap = theme.scaledUi(8.0);
    const pill_h = theme.scaledUi(28.0);
    const y = rect.y + rect.h - theme.scaledUi(40.0);
    const max_x = rect.x + rect.w - theme.scaledUi(58.0);
    var x = rect.x + pad;

    const model_label = state.currentComposerModelLabel();
    const model_w = inactiveComposerPillWidth(model_label, true);
    if (x + model_w <= max_x) {
        const pill = palette.Rect{ .x = x, .y = y, .w = model_w, .h = pill_h };
        renderInactiveComposerPill(state, pill, model_label, true);
        renderInactiveComposerProviderIcon(state, pill, thread.provider);
        x += model_w + gap;
    }

    // The live composer consolidates reasoning/speed/access into one run
    // pill; the read-only preview mirrors that with the same summary text
    // and the same embedded state glyphs (brain gauge / bolt / lock).
    // Measure the joined label (it spans up to three settings and includes
    // multibyte separators) instead of guessing from byte count.
    var summary_buf: [192]u8 = undefined;
    const summary = state.composerRunSummaryParts(&summary_buf);
    // Slot order mirrors syncPaletteComposerControls: optional reasoning
    // glyph, optional speed glyph, then the always-present access glyph.
    var slots: [3]InactiveRunSlot = undefined;
    var slot_count: usize = 0;
    if (summary.reasoning_offset) |offset| {
        slots[slot_count] = .{ .byte_offset = offset, .kind = .reasoning };
        slot_count += 1;
    }
    if (summary.fast_offset) |offset| {
        slots[slot_count] = .{ .byte_offset = offset, .kind = .speed };
        slot_count += 1;
    }
    slots[slot_count] = .{ .byte_offset = summary.access_offset, .kind = .access };
    slot_count += 1;

    const summary_text_w = text_measure.textWidth(.ui, theme.scaledUi(12.5), summary.text);
    const cells_w = @as(f32, @floatFromInt(slot_count)) * theme.scaledUi(INACTIVE_RUN_PILL_ICON_CELL_CSS);
    const summary_w = theme.clampf(summary_text_w + cells_w + theme.scaledUi(26.0), theme.scaledUi(76.0), theme.scaledUi(340.0));
    if (x + summary_w <= max_x) {
        renderInactiveComposerRunPill(state, .{ .x = x, .y = y, .w = summary_w, .h = pill_h }, summary.text, slots[0..slot_count]);
    }
}

/// One host-drawn state glyph inside the inactive preview's run pill;
/// `byte_offset` splits the summary text exactly like the live pill's
/// ComposerPromptIconSlot.
const InactiveRunSlot = struct {
    byte_offset: usize,
    kind: enum { reasoning, speed, access },
};

/// Glyph cell width inside the inactive run pill; the preview is a scaled-
/// down echo of the live pill (12.5pt vs 15pt labels), so the cell shrinks
/// with it. Same convention as `COMPOSER_RUN_PILL_ICON_CELL`.
const INACTIVE_RUN_PILL_ICON_CELL_CSS: f32 = 24.0;
/// Drawn glyph size inside an inactive run-pill cell (live pill draws 22).
const INACTIVE_RUN_PILL_ICON_SIZE_CSS: f32 = 18.0;

// Renders the inactive preview's run pill: summary text broken around glyph
// cells so brain/bolt/lock land beside the segment each one describes,
// matching the live run pill's walk (including the half-space nudge that
// centers each glyph over the word gap).
fn renderInactiveComposerRunPill(state: *app_state.AppState, pill: palette.Rect, label: []const u8, slots: []const InactiveRunSlot) void {
    queueRounded(state, pill, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 86)), pill.h * 0.5);
    const font = theme.scaledUi(12.5);
    const cell_w = theme.scaledUi(INACTIVE_RUN_PILL_ICON_CELL_CSS);
    const icon_size = theme.scaledUi(INACTIVE_RUN_PILL_ICON_SIZE_CSS);
    const icon_color = paletteColor(.{ 0.82, 0.85, 0.91, 1.0 });
    const label_right = pill.x + pill.w - theme.scaledUi(10.0);
    const label_y = pill.y + (pill.h - theme.scaledUi(15.0)) * 0.5;
    const label_h = theme.scaledUi(16.0);
    var x = pill.x + theme.scaledUi(13.0);
    var byte: usize = 0;
    for (slots) |slot| {
        const offset = @min(slot.byte_offset, label.len);
        if (offset > byte) {
            const seg = label[byte..offset];
            const seg_w = text_measure.textWidth(.ui, font, seg);
            queueChromeLabel(state, .{ .x = x, .y = label_y, .w = seg_w + theme.scaledUi(2.0), .h = label_h }, seg, paletteColor(theme.COLOR_WHITE), font, pill);
            x += seg_w;
            byte = offset;
        }
        // Center the glyph over the word gap: cell spare plus the separator's
        // leading space, mirroring reasoningIconSlotRects.
        var space_end = byte;
        while (space_end < label.len and label[space_end] == ' ') : (space_end += 1) {}
        const gap_shift = text_measure.textWidth(.ui, font, label[byte..space_end]) * 0.5;
        if (x + gap_shift + cell_w > label_right) break;
        const cell = palette.Rect{ .x = x + gap_shift, .y = pill.y, .w = cell_w, .h = pill.h };
        switch (slot.kind) {
            // The brain inks its full em; draw it smaller so the three glyphs
            // read as the same visual weight (matches the live pill).
            .reasoning => drawThinkingIcon(state, composerIconRectInCell(cell, icon_size * 0.85), icon_color),
            .speed => if (state.currentThread().fast_mode == .on)
                drawBoltIcon(state, composerIconRectInCell(cell, icon_size), icon_color)
            else
                drawDefaultModeIcon(state, composerIconRectInCell(cell, icon_size), icon_color),
            .access => drawAccessIcon(state, composerIconRectInCell(cell, icon_size), icon_color),
        }
        x += cell_w;
    }
    if (byte < label.len) {
        const tail = label[byte..];
        queueChromeLabel(state, .{ .x = x, .y = label_y, .w = @max(label_right - x, theme.scaledUi(1.0)), .h = label_h }, tail, paletteColor(theme.COLOR_WHITE), font, pill);
    }
}

fn inactiveComposerPillWidth(label: []const u8, has_icon: bool) f32 {
    const text_w = @as(f32, @floatFromInt(label.len)) * theme.scaledUi(12.5) * 0.54;
    return theme.clampf(text_w + theme.scaledUi(if (has_icon) 50.0 else 26.0), theme.scaledUi(if (has_icon) 92.0 else 76.0), theme.scaledUi(180.0));
}

// Renders a muted toolbar pill for the inactive composer preview.
fn renderInactiveComposerPill(state: *app_state.AppState, rect: palette.Rect, label: []const u8, has_icon: bool) void {
    queueRounded(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 86)), rect.h * 0.5);
    const text_x = rect.x + theme.scaledUi(if (has_icon) 43.0 else 13.0);
    queueChromeLabel(state, .{
        .x = text_x,
        .y = rect.y + (rect.h - theme.scaledUi(15.0)) * 0.5,
        .w = @max(rect.x + rect.w - text_x - theme.scaledUi(10.0), theme.scaledUi(1.0)),
        .h = theme.scaledUi(16.0),
    }, label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(12.5), rect);
}

// Renders the provider mark inside the inactive composer model pill.
fn renderInactiveComposerProviderIcon(state: *app_state.AppState, pill: palette.Rect, provider: app_state.Provider) void {
    const provider_slot = theme.scaledUi(COMPOSER_PROVIDER_LOGO_SLOT_CSS);
    const icon_slot = palette.Rect{
        .x = pill.x + theme.scaledUi(COMPOSER_TOOLBAR_PILL_PAD_X),
        .y = pill.y + (pill.h - provider_slot) * 0.5,
        .w = provider_slot,
        .h = provider_slot,
    };
    const provider_icon = switch (provider) {
        .codex => state.codex_logo_texture,
        .opencode => state.opencode_logo_texture,
        .claude => state.claude_logo_texture,
        .cursor => state.cursor_logo_texture,
    };
    if (provider_icon) |cached| {
        const r = utils.snapImageRectToPixels(utils.imageRectContain(cached.width, cached.height, icon_slot.x, icon_slot.y, icon_slot.w, icon_slot.h));
        queueImage(state, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, cached, pill);
    } else {
        const fallback_label = switch (provider) {
            .codex => "C",
            .opencode => "O",
            .claude => "A",
            .cursor => "R",
        };
        queueText(state, icon_slot, fallback_label, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 175)), theme.scaledUi(13.0), pill);
    }
}

// Renders the inactive composer submit/stop affordance without registering hit state.
fn renderInactiveComposerSubmit(state: *app_state.AppState, rect: palette.Rect) void {
    const size = theme.scaledUi(28.0);
    const button = palette.Rect{
        .x = rect.x + rect.w - theme.scaledUi(18.0) - size,
        .y = rect.y + rect.h - theme.scaledUi(40.0),
        .w = size,
        .h = size,
    };
    if (state.currentThread().isSendPendingForUi()) {
        const pulse = theme.activityPulse(profiler.nowNs());
        queueRounded(state, button, paletteColor(theme.withAlpha(theme.COLOR_YELLOW, @intFromFloat(188.0 + pulse * 67.0))), size * 0.5);
        const stop_side = size * (0.29 + pulse * 0.06);
        const stop = palette.Rect{
            .x = button.x + (size - stop_side) * 0.5,
            .y = button.y + (size - stop_side) * 0.5,
            .w = stop_side,
            .h = stop_side,
        };
        queueRounded(state, stop, paletteColor(theme.withAlpha(theme.background(), 230)), theme.scaledUi(2.0));
    } else {
        // This preview is read-only; keep the send affordance disabled so it
        // does not imply that clicks/keystrokes will be handled by this pane.
        queueRounded(state, button, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 122)), size * 0.5);
        drawInactiveComposerSendArrow(state, button, paletteColor(theme.withAlpha(theme.foregroundOn(theme.COLOR_GREEN), 135)));
    }
}

// Draws the same submit-arrow shape as PaletteComposerPrompt without depending on a font glyph.
fn drawInactiveComposerSendArrow(state: *app_state.AppState, button: palette.Rect, color: palette.Color) void {
    const m_button = @min(button.w, button.h);
    const inset = m_button * 0.125;
    const inner = snapRect(.{
        .x = button.x + inset,
        .y = button.y + inset,
        .w = @max(button.w - 2.0 * inset, 1.0),
        .h = @max(button.h - 2.0 * inset, 1.0),
    });
    const m = @min(inner.w, inner.h);
    const cx = inner.x + inner.w * 0.5;
    const total_h = m * 0.56;
    const head_h = total_h * 0.52;
    const stem_h = total_h * 0.48;
    const half_w_head = m * 0.175;
    const half_w_stem = @max(m * 0.052, 1.25);
    const y0 = inner.y + (inner.h - total_h) * 0.5;
    queueRect(state, .{
        .x = cx - half_w_stem,
        .y = y0 + head_h,
        .w = half_w_stem * 2.0,
        .h = stem_h,
    }, color);
    queueTriangle(
        state,
        .{ .x = @round(cx), .y = @round(y0) },
        .{ .x = @round(cx - half_w_head), .y = @round(y0 + head_h) },
        .{ .x = @round(cx + half_w_head), .y = @round(y0 + head_h) },
        color,
    );
}

fn renderComposerFileSearchResults(state: *app_state.AppState) void {
    file_search_hits = .{};
    if (!state.hasActiveFileSearch()) return;

    const composer = state.composer_controller.composer.bounds();
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
        paletteColor(theme.withAlpha(theme.background(), 250)),
        paletteColor(theme.COLOR_PANEL_MUTED),
        theme.scaledUi(12.0),
        panel,
    );

    if (results.len == 0) {
        const message = if (state.fileSearchIsScanning()) "Indexing workspace files..." else "No matching files";
        queueText(state, .{
            .x = panel.x + theme.scaledUi(14.0),
            .y = panel.y + pad + theme.scaledUi(9.0),
            .w = panel.w - theme.scaledUi(28.0),
            .h = row_height,
        }, message, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), panel);
        return;
    }

    const mouse_ok = state.transcript_controller.palette_mouse_in_workspace;
    const mx = state.transcript_controller.palette_mouse_x;
    const my = state.transcript_controller.palette_mouse_y;
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
            queueRounded(state, row, paletteColor(if (result_index == selected_index) theme.withAlpha(theme.selection(), 230) else theme.withAlpha(theme.COLOR_PANEL_MUTED, 230)), theme.scaledUi(8.0));
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

fn renderComposerSlashCommands(state: *app_state.AppState) void {
    slash_picker_hits = .{};
    if (!state.slashCommandPickerActive()) return;

    const total = state.slashCommandPickerRowCount();
    if (total == 0) return;

    const composer = state.composer_controller.composer.bounds();
    if (composer.w <= theme.scaledUi(160.0)) return;

    const row_height = theme.scaledUi(46.0);
    const visible_rows: usize = @min(total, slash_picker_hits.row_rects.len - 1, 7);
    const pad = theme.scaledUi(8.0);
    const gap = theme.scaledUi(8.0);
    const panel_w = @min(composer.w, theme.scaledUi(760.0));
    const panel_h = pad * 2.0 + row_height * @as(f32, @floatFromInt(visible_rows));
    const panel = palette.Rect{
        .x = composer.x,
        .y = @max(theme.scaledUi(8.0), composer.y - gap - panel_h),
        .w = panel_w,
        .h = panel_h,
    };
    slash_picker_hits.panel_rect = panel;

    const previous_z = state.palette_overlay_batch.setZIndex(COMPOSER_FILE_SEARCH_Z + 1);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    queueRoundedShellClipped(
        state,
        panel,
        paletteColor(theme.withAlpha(theme.background(), 252)),
        paletteColor(theme.COLOR_PANEL_MUTED),
        theme.scaledUi(12.0),
        panel,
    );

    const selected = state.slashCommandPickerSelectedIndex();
    const first_index = if (selected >= visible_rows) selected + 1 - visible_rows else 0;
    const end_index = @min(first_index + visible_rows, total);
    const mouse_ok = state.transcript_controller.palette_mouse_in_workspace;
    const mx = state.transcript_controller.palette_mouse_x;
    const my = state.transcript_controller.palette_mouse_y;

    var visible_index: usize = 0;
    var row_index = first_index;
    while (row_index < end_index) : ({
        row_index += 1;
        visible_index += 1;
    }) {
        const data = state.slashCommandPickerRow(row_index) orelse continue;
        const row = palette.Rect{
            .x = panel.x + pad,
            .y = panel.y + pad + @as(f32, @floatFromInt(visible_index)) * row_height,
            .w = panel.w - pad * 2.0,
            .h = row_height,
        };
        slash_picker_hits.row_rects[visible_index] = row;
        slash_picker_hits.row_indices[visible_index] = row_index;
        slash_picker_hits.row_count = visible_index + 1;

        const hovered = mouse_ok and rectContains(row, mx, my);
        if (row_index == selected or hovered) {
            queueRounded(state, row, paletteColor(if (row_index == selected) theme.withAlpha(theme.selection(), 230) else theme.withAlpha(theme.COLOR_PANEL_MUTED, 230)), theme.scaledUi(8.0));
        }

        const text_color = paletteColor(if (data.disabled) theme.COLOR_TEXT_MUTED else theme.COLOR_WHITE);
        const meta_color = paletteColor(theme.COLOR_TEXT_MUTED);
        queueChromeLabel(state, .{
            .x = row.x + theme.scaledUi(12.0),
            .y = row.y + theme.scaledUi(6.0),
            .w = theme.scaledUi(140.0),
            .h = theme.scaledUi(18.0),
        }, data.name, text_color, theme.scaledUi(14.5), row);
        queueText(state, .{
            .x = row.x + theme.scaledUi(156.0),
            .y = row.y + theme.scaledUi(7.0),
            .w = @max(row.w - theme.scaledUi(250.0), theme.scaledUi(80.0)),
            .h = theme.scaledUi(18.0),
        }, data.summary, text_color, theme.scaledUi(13.0), row);
        queueText(state, .{
            .x = row.x + theme.scaledUi(12.0),
            .y = row.y + theme.scaledUi(25.0),
            .w = row.w - theme.scaledUi(120.0),
            .h = theme.scaledUi(16.0),
        }, data.usage, meta_color, theme.scaledUi(11.5), row);
        const badge = if (data.disabled) "Unavailable" else data.provider_label;
        queueText(state, .{
            .x = row.x + row.w - theme.scaledUi(104.0),
            .y = row.y + theme.scaledUi(16.0),
            .w = theme.scaledUi(92.0),
            .h = theme.scaledUi(16.0),
        }, badge, meta_color, theme.scaledUi(11.5), row);
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

    const composer = state.composer_controller.composer.bounds();
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
    const top_offset = if (state.composerInBangCommandMode())
        theme.scaledUi(BANG_MODE_BANNER_HEIGHT) + theme.scaledUi(8.0)
    else
        0.0;
    const rows = (count + per_row - 1) / per_row;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const image = state.currentThread().draftImageAt(index) orelse continue;
        const row = index / per_row;
        const col = index % per_row;
        const preview = palette.Rect{
            .x = start_x + @as(f32, @floatFromInt(col)) * (preview_w + gap),
            .y = composer.y - top_offset - @as(f32, @floatFromInt(rows - row)) * (preview_h + gap),
            .w = preview_w,
            .h = preview_h,
        };
        renderComposerDraftImageChip(state, image.*, index, preview, thumb_max);
    }
}

// Shell-mode banner above the composer, making local command execution explicit.
fn renderBangModeBanner(state: *app_state.AppState, rect: palette.Rect) void {
    const radius = theme.scaledUi(10.0);
    queuePanel(
        state,
        rect,
        paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 248)),
        paletteColor(theme.withAlpha(theme.COLOR_GREEN, 185)),
        radius,
        @max(theme.scaledUi(1.0), 1.0),
    );

    const pad = theme.scaledUi(14.0);
    const title_font = theme.scaledUi(12.5);
    queueText(state, .{
        .x = rect.x + pad,
        .y = rect.y + theme.scaledUi(7.0),
        .w = @max(rect.w - pad * 2.0 - theme.scaledUi(150.0), theme.scaledUi(80.0)),
        .h = theme.scaledUi(17.0),
    }, ">_  SHELL COMMAND", paletteColor(theme.COLOR_GREEN), title_font, rect);

    const escape_hint = "Esc: return to chat";
    const escape_w = theme.scaledUi(132.0);
    if (rect.w >= theme.scaledUi(360.0)) {
        queueText(state, .{
            .x = rect.x + rect.w - pad - escape_w,
            .y = rect.y + theme.scaledUi(7.0),
            .w = escape_w,
            .h = theme.scaledUi(17.0),
        }, escape_hint, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(11.5), rect);
    }

    var detail_buffer: [512]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buffer, "{s}  ·  {s}  ·  everything after ! runs in the shell  ·  !! sends a literal !", .{
        bang_commands.shellName(),
        state.currentWorkspacePath(),
    }) catch "Everything after ! runs in the shell";
    queueText(state, .{
        .x = rect.x + pad,
        .y = rect.y + theme.scaledUi(29.0),
        .w = rect.w - pad * 2.0,
        .h = theme.scaledUi(17.0),
    }, detail, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(11.5), rect);
}

fn renderComposerDraftImageChip(state: *app_state.AppState, image: app_state.ChatImageAttachment, index: usize, preview: palette.Rect, thumb_max: f32) void {
    queueRoundedShellClipped(
        state,
        preview,
        paletteColor(theme.background()),
        paletteColor(theme.COLOR_PANEL_MUTED),
        theme.scaledUi(9.0),
        preview,
    );

    const thumb = palette.Rect{ .x = preview.x + theme.scaledUi(6.0), .y = preview.y + (preview.h - thumb_max) * 0.5, .w = thumb_max, .h = thumb_max };
    queueRounded(state, thumb, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(8.0));
    if (state.ensureImageTexture(image.path)) |cached| {
        const dims = runtime.scaledImageSize(cached.width, cached.height, thumb.w, thumb.h);
        queueImage(state, .{ .x = thumb.x + (thumb.w - dims[0]) * 0.5, .y = thumb.y + (thumb.h - dims[1]) * 0.5, .w = dims[0], .h = dims[1] }, cached, thumb);
    }

    var size_buf: [32:0]u8 = undefined;
    const size_label = runtime.formatByteSize(&size_buf, image.byte_size);
    const clear_size = theme.scaledUi(22.0);
    const clear_rect = palette.Rect{ .x = preview.x + preview.w - clear_size - theme.scaledUi(8.0), .y = preview.y + theme.scaledUi(8.0), .w = clear_size, .h = clear_size };
    const clear_hit_pad = theme.scaledUi(8.0);
    state.setComposerDraftImageClearRectAt(.{
        .x = clear_rect.x - clear_hit_pad,
        .y = clear_rect.y - clear_hit_pad,
        .w = clear_rect.w + clear_hit_pad * 2.0,
        .h = clear_rect.h + clear_hit_pad * 2.0,
    }, index);
    const label_x = thumb.x + thumb.w + theme.scaledUi(12.0);
    const label_w = @max(clear_rect.x - label_x - theme.scaledUi(12.0), theme.scaledUi(1.0));
    queueText(state, .{ .x = label_x, .y = preview.y + theme.scaledUi(15.0), .w = label_w, .h = theme.scaledUi(20.0) }, image.file_name, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), preview);
    queueText(state, .{ .x = label_x, .y = preview.y + theme.scaledUi(39.0), .w = label_w, .h = theme.scaledUi(18.0) }, size_label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), preview);
    queueRoundedShellClipped(
        state,
        clear_rect,
        paletteColor(theme.COLOR_PANEL_MUTED),
        paletteColor(theme.lighten(theme.COLOR_PANEL_MUTED, 0.08)),
        clear_size * 0.5,
        clear_rect,
    );
    queueText(state, .{ .x = clear_rect.x + clear_rect.w * 0.34, .y = clear_rect.y + clear_rect.h * 0.10, .w = clear_rect.w * 0.5, .h = clear_rect.h * 0.8 }, "x", paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.0), clear_rect);
}

/// While a reply is streaming, show the provider's queue/steer shortcuts once
/// the user has typed a non-empty draft.
fn renderComposerFollowupHint(state: *app_state.AppState) void {
    if (!state.hasPendingStream()) return;
    const hint = state.pendingFollowupHint() orelse return;
    const draft = state.composer_controller.composer.text();
    if (std.mem.trim(u8, draft, &std.ascii.whitespace).len == 0) return;

    const previous_z = state.palette_overlay_batch.setZIndex(COMPOSER_FOLLOWUP_HINT_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    const tr = state.composer_controller.composer.textRect();
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

/// Returns the short status label shown at the top of the pinned follow-up card.
fn pendingFollowupPinLabel(
    kind: app_state.FollowupKind,
    fstate: app_state.FollowupState,
    provider: app_state.Provider,
) []const u8 {
    if (fstate == .fallback_next_turn) return "Sends after the current reply";
    return switch (kind) {
        .queue => "Queued \u{00B7} sends after this reply",
        .steer => switch (provider) {
            .codex => "Steering \u{00B7} waiting for Codex to accept",
            else => "Steering current turn",
        },
    };
}

/// Renders the pinned follow-up card above the composer. Mirrors the AMP TUI:
/// the queued/steered prompt stays pinned ("waiting to send") for every provider
/// until it is dispatched as the next turn (or accepted inline by Codex, which
/// removes the pin and shows it in the transcript instead). Reuses the amber tint
/// of the transcript steering bubble (`COLOR_YELLOW`) for visual continuity.
fn renderPendingFollowupPin(
    state: *app_state.AppState,
    rect: palette.Rect,
    followup: app_state.PendingFollowup,
    provider: app_state.Provider,
) void {
    const previous_z = state.palette_overlay_batch.setZIndex(COMPOSER_FOLLOWUP_PIN_Z);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);

    const radius = theme.scaledUi(11.0);
    queuePanel(
        state,
        rect,
        paletteColor(theme.withAlpha(theme.COLOR_YELLOW, 54)),
        paletteColor(theme.withAlpha(theme.COLOR_YELLOW, 150)),
        radius,
        @max(theme.scaledUi(1.0), 1.0),
    );

    const pad_x = theme.scaledUi(14.0);
    const inner_w = @max(rect.w - pad_x * 2.0, theme.scaledUi(1.0));

    const label = pendingFollowupPinLabel(followup.kind, followup.state, provider);
    const label_font = theme.scaledUi(12.0);

    // Right-aligned "note" hinting the double-click edit affordance. Hidden on
    // narrow cards so it never collides with the status label on the left.
    const note = "Double-click to edit";
    const note_font = theme.scaledUi(11.0);
    const note_w = @as(f32, @floatFromInt(note.len)) * note_font * 0.52;
    const label_room = if (rect.w >= theme.scaledUi(360.0)) inner_w - note_w - theme.scaledUi(10.0) else inner_w;

    queueText(state, .{
        .x = rect.x + pad_x,
        .y = rect.y + theme.scaledUi(8.0),
        .w = @max(label_room, theme.scaledUi(1.0)),
        .h = label_font + theme.scaledUi(2.0),
    }, label, paletteColor(theme.lighten(theme.COLOR_YELLOW, 0.18)), label_font, rect);

    if (rect.w >= theme.scaledUi(360.0)) {
        queueText(state, .{
            .x = rect.x + rect.w - pad_x - note_w,
            .y = rect.y + theme.scaledUi(9.0),
            .w = note_w,
            .h = note_font + theme.scaledUi(2.0),
        }, note, paletteColor(theme.withAlpha(theme.COLOR_TEXT_MUTED, 220)), note_font, rect);
    }

    // Preview only the first line so the pinned card stays compact; the renderer
    // truncates to the available width for us.
    const prompt = if (std.mem.findScalar(u8, followup.prompt, '\n')) |nl|
        followup.prompt[0..nl]
    else
        followup.prompt;
    const body_font = theme.scaledUi(14.0);
    queueText(state, .{
        .x = rect.x + pad_x,
        .y = rect.y + theme.scaledUi(26.0),
        .w = inner_w,
        .h = @max(rect.h - theme.scaledUi(30.0), body_font),
    }, prompt, paletteColor(theme.COLOR_WHITE), body_font, rect);
}

// Vertical nudge from the pill's geometric center to the label text's optical
// midline. The run labels are lowercase-heavy ("Full access"), so their ink
// mass sits below center — negative drops the glyphs onto it. Measured from
// screenshots at 1.667x display scale: glyph ink centered ~3px above the
// cap-band midline at +1.0, so -1.0 (a ~3.3px swing) lands brain/lock on it.
const RUN_PILL_ICON_OPTICAL_LIFT: f32 = -1.0;

// Centers a square glyph box of `size` inside a reserved run-pill label cell;
// the cell's spare width splits evenly into the word-side and separator-side
// gaps, and the box is lifted to the label text's optical midline.
fn composerIconRectInCell(cell: palette.Rect, size: f32) palette.Rect {
    return snapIconRectOrigin(.{
        .x = cell.x + @max((cell.w - size) * 0.5, 0.0),
        .y = cell.y + (cell.h - size) * 0.5 - theme.scaledUi(RUN_PILL_ICON_OPTICAL_LIFT),
        .w = size,
        .h = size,
    });
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
    const model_rect = state.composer_controller.composer.modelRect();
    const fast_rect = state.composer_controller.composer.fastRect();
    const access_rect = state.composer_controller.composer.accessRect();
    const icon_size = theme.scaledUi(22.0);
    const provider_slot = theme.scaledUi(COMPOSER_PROVIDER_LOGO_SLOT_CSS);
    // Pad must match the composer's scaled `pill_padding_x` so the logo sits
    // inside the pill's scaled leading reserve instead of over the label.
    const model_icon_slot = palette.Rect{
        .x = model_rect.x + theme.scaledUi(COMPOSER_TOOLBAR_PILL_PAD_X),
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

    // The run pill embeds the fast-mode and access state glyphs beside the
    // label segment each one describes; the composer reserves the cells via
    // `setReasoningIconSlots` and reports their rects so the glyphs track
    // label layout and truncation. Each glyph is centered in its cell so the
    // word→glyph and glyph→separator gaps stay balanced. Slot order matches
    // `syncPaletteComposerControls`: optional reasoning glyph, then optional
    // speed glyph, then access.
    if (state.composer_controller.composer.showReasoningToggle()) {
        const slots = state.composer_controller.composer.reasoningIconSlotRects();
        var slot_index: usize = 0;
        if (state.currentComposerShowsReasoningSegment() and slot_index < slots.count) {
            const cell = slots.rects[slot_index];
            slot_index += 1;
            // The brain glyph inks its full em square while the bolt/lock
            // carry ~7-12% built-in side bearings; draw it smaller so the
            // three glyphs read as the same visual weight.
            drawThinkingIcon(state, composerIconRectInCell(cell, icon_size * 0.85), icon_color);
        }
        if (state.currentComposerShowsFastToggle() and slot_index < slots.count) {
            const cell = slots.rects[slot_index];
            slot_index += 1;
            const fast_icon_rect = composerIconRectInCell(cell, icon_size);
            if (state.currentThread().fast_mode == .on) {
                drawBoltIcon(state, fast_icon_rect, icon_color);
            } else {
                drawDefaultModeIcon(state, fast_icon_rect, icon_color);
            }
        }
        if (slot_index < slots.count) {
            const cell = slots.rects[slot_index];
            drawAccessIcon(state, composerIconRectInCell(cell, icon_size), icon_color);
        }
    }

    if (state.composer_controller.composer.showFastToggle()) {
        const fast_icon_rect = snapIconRectOrigin(palette.Rect{
            .x = fast_rect.x + theme.scaledUi(COMPOSER_TOOLBAR_PILL_PAD_X),
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

    // Fast/access consolidated into the run-config popover; the access pill
    // (and its lock glyph) only draws when a host re-enables the toggle.
    if (state.composer_controller.composer.showAccessToggle()) {
        drawAccessIcon(state, snapIconRectOrigin(palette.Rect{
            .x = access_rect.x + theme.scaledUi(COMPOSER_TOOLBAR_PILL_PAD_X),
            .y = access_rect.y + (access_rect.h - icon_size) * 0.5,
            .w = icon_size,
            .h = icon_size,
        }), icon_color);
    }
}

// Nerd Font Symbols glyphs used for composer-toolbar icons. Rendering them
// through SDL_ttf gets us crisp, antialiased shapes at any DPI — much nicer
// than the hand-drawn triangles we used while the icon font was being wired
// up. Codepoints verified against SymbolsNerdFontMono-Regular.ttf's cmap.
const NF_FA_FLASH = "\u{F0E7}"; // lightning bolt
const NF_COD_LOCK = "\u{EA75}";
const NF_COD_UNLOCK = "\u{EB74}";
const NF_COD_CIRCLE = "\u{EABC}"; // hollow circle — reads as "inactive / default" next to the bolt
const NF_COD_CHEVRON_DOWN = "\u{EAB4}";
const NF_COD_LINK_EXTERNAL = "\u{EB14}";
const NF_MD_BRAIN = "\u{F09D1}"; // brain — reasoning/thinking level on the run pill

/// Renders a single codicon glyph centered inside `rect` using the icon font.
/// SDL_ttf rasterizes the glyph with proper antialiasing at the requested
/// pixel size so it stays crisp on HiDPI displays. `clip` trims the drawn
/// glyph (renderer pixel space) for partial-fill effects.
fn queueComposerIcon(state: *app_state.AppState, rect: palette.Rect, glyph: []const u8, color: palette.Color, clip: ?palette.Rect) void {
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
        clip,
    ) catch {};
}

fn drawBoltIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    queueComposerIcon(state, rect, NF_FA_FLASH, color, null);
}

fn drawDefaultModeIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    // Default mode: hollow circle — reads as "off / standard" against the
    // filled lightning bolt that marks Fast.
    queueComposerIcon(state, rect, NF_COD_CIRCLE, color, null);
}

fn drawAccessIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    const glyph = if (state.currentThread().access_mode == .full_access) NF_COD_UNLOCK else NF_COD_LOCK;
    queueComposerIcon(state, rect, glyph, color, null);
}

/// Faint fraction of the brain silhouette that stays visible above the fill,
/// keeping the glyph's outline readable at low reasoning levels.
const THINKING_ICON_EMPTY_ALPHA: f32 = 0.32;

fn drawThinkingIcon(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    // Reasoning gauge: the brain fills bottom-up with the selected level — a
    // faint full silhouette underneath, and the bright glyph clipped to the
    // bottom `ratio` of the box on top, so Low shows a sliver and the top
    // level a solid brain.
    const ratio = std.math.clamp(state.currentComposerReasoningFillRatio(), 0.0, 1.0);
    if (ratio >= 1.0) {
        queueComposerIcon(state, rect, NF_MD_BRAIN, color, null);
        return;
    }
    var faint = color;
    faint.a *= THINKING_ICON_EMPTY_ALPHA;
    queueComposerIcon(state, rect, NF_MD_BRAIN, faint, null);
    if (ratio <= 0.0) return;
    const snapped = snapRect(rect);
    const fill_h = @round(snapped.h * ratio);
    queueComposerIcon(state, rect, NF_MD_BRAIN, color, .{
        .x = snapped.x,
        .y = snapped.y + snapped.h - fill_h,
        .w = snapped.w,
        .h = fill_h,
    });
}

fn stableText(state: *app_state.AppState, value: []const u8) []const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch "";
}

fn queueRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, snapRect(rect), color) catch {};
}

fn queueRectClipped(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, clip: palette.Rect) void {
    state.palette_overlay_batch.rectClipped(state.allocator, snapRect(rect), color, clip) catch {};
}

fn queueRounded(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch {};
}

fn queueTriangleClipped(state: *app_state.AppState, p0: palette.draw.Vec2, p1: palette.draw.Vec2, p2: palette.draw.Vec2, color: palette.Color, clip: palette.Rect) void {
    state.palette_overlay_batch.triangleClipped(state.allocator, p0, p1, p2, color, clip) catch {};
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

/// Centers a short UI-font label inside a button or badge rectangle.
fn queueCenteredChromeLabel(
    state: *app_state.AppState,
    rect: palette.Rect,
    value: []const u8,
    color: palette.Color,
    font_size: f32,
    clip: ?palette.Rect,
) void {
    const label_w = text_measure.textWidth(.ui, font_size, value);
    const label_h = font_size * 1.4;
    queueChromeLabel(state, centeredLabelRect(rect, label_w, label_h), value, color, font_size, clip);
}

fn centeredLabelRect(container: palette.Rect, label_w: f32, label_h: f32) palette.Rect {
    return .{
        .x = container.x + @max((container.w - label_w) * 0.5, 0.0),
        .y = container.y + @max((container.h - label_h) * 0.5, 0.0),
        .w = @min(label_w, container.w),
        .h = @min(label_h, container.h),
    };
}

test "centered label geometry balances button padding" {
    const label = centeredLabelRect(
        .{ .x = 10.0, .y = 20.0, .w = 54.0, .h = 28.0 },
        24.0,
        14.0,
    );
    try std.testing.expectEqual(@as(f32, 25.0), label.x);
    try std.testing.expectEqual(@as(f32, 27.0), label.y);
    try std.testing.expectEqual(@as(f32, 24.0), label.w);
    try std.testing.expectEqual(@as(f32, 14.0), label.h);
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

fn intersectRect(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    return .{
        .x = x,
        .y = y,
        .w = @max(right - x, 0.0),
        .h = @max(bottom - y, 0.0),
    };
}

fn snapRect(rect: palette.Rect) palette.Rect {
    return .{
        .x = @round(rect.x),
        .y = @round(rect.y),
        .w = @round(rect.w),
        .h = @round(rect.h),
    };
}

test "diff summary v2 round trips delimiter characters and multiple files" {
    const body =
        utils.PERSISTED_DIFF_MARKER ++
        "FILE\t16\t1\t1\t21\n" ++
        "src/with\ttab.zig" ++
        "@@ -1 +1 @@\n-old\n+new" ++
        "FILE\t10\t2\t0\t0\n" ++
        "README.md\n";
    const files = parseDiffSummary(std.testing.allocator, body) orelse return error.TestUnexpectedNull;
    defer std.testing.allocator.free(files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("src/with\ttab.zig", files[0].path);
    try std.testing.expectEqualStrings("@@ -1 +1 @@\n-old\n+new", files[0].patch);
    try std.testing.expectEqualStrings("README.md\n", files[1].path);
}

test "diff summary v2 rejects truncated payloads" {
    const body = utils.PERSISTED_DIFF_MARKER ++ "FILE\t4\t1\t0\t99\nmain";
    try std.testing.expect(parseDiffSummary(std.testing.allocator, body) == null);
}

test "split diff layout aligns replacement rows" {
    const patch =
        \\@@ -1,2 +1,3 @@
        \\-const oldValue = 1;
        \\+const newValue = 2;
        \\+const extraValue = 3;
        \\ context();
    ;
    const stacked_lines = diffPatchDisplayLineCountForLayout(null, patch, .stacked);
    const split_lines = diffPatchDisplayLineCountForLayout(null, patch, .split);
    try std.testing.expectEqual(@as(usize, 5), stacked_lines);
    try std.testing.expectEqual(@as(usize, 4), split_lines);
}
