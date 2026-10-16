//! Machine-wide Companion overlay: a character dock that summarizes what is
//! running and what needs the user, and an orchestration panel with the
//! needs-you inbox, the companion's crew of delegated chats, the conversation,
//! and the shared composer. Characters are vector art drawn from the theme.

const std = @import("std");
const palette = @import("palette");
const app_config = @import("../app/config.zig");
const controller = @import("../state/companion_controller.zig");
const companion_roster = @import("../state/companion_roster.zig");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");

// Keep settings_modal tests on the registered root suite without editing main.zig.
test {
    _ = @import("settings_modal.zig");
}

const log = std.log.scoped(.companion_ui);

// Logical-unit geometry tokens (multiplied by the display scale).
/// Collapsed bubble diameter; the pill that carries a notification is as tall.
const DOCK_BUBBLE: f32 = 44.0;
/// Inset of the character inside the bubble so it sits inside the ring.
const DOCK_AVATAR_INSET: f32 = 6.0;
/// Notification text in the pill, beside the bubble.
const DOCK_TEXT_FONT: f32 = 11.5;
const DOCK_TEXT_PAD: f32 = 14.0;
const DOCK_TEXT_MAX: f32 = 220.0;
/// Room kept between the bubble and the window edge for its badge and shadow.
const DOCK_EDGE_MARGIN: f32 = 6.0;
const PANEL_WIDTH: f32 = 420.0;
const PANEL_INSET: f32 = 10.0;
const HEADER_HEIGHT: f32 = 64.0;
const FOOTER_HEIGHT: f32 = 116.0;
const CONTENT_INSET: f32 = 14.0;
const SECTION_TITLE_HEIGHT: f32 = 24.0;
const INBOX_ROW_HEIGHT: f32 = 46.0;
const CREW_ROW_HEIGHT: f32 = 40.0;
const ROW_GAP: f32 = 6.0;
const MAX_INBOX_ROWS_SHOWN: usize = 3;
const MAX_CREW_ROWS_SHOWN: usize = 4;
const APPROVAL_HEIGHT: f32 = 104.0;
const ERROR_STRIP_HEIGHT: f32 = 30.0;
const RECAP_HEIGHT: f32 = 42.0;
const HEADER_BUTTON: f32 = 28.0;
const MENU_ROW_HEIGHT: f32 = 40.0;
const MENU_ACTION_HEIGHT: f32 = 34.0;
const BRAIN_ROW_HEIGHT: f32 = 30.0;
const SUGGESTION_HEIGHT: f32 = 36.0;
const BODY_FONT: f32 = 12.5;
const LINE_HEIGHT_FACTOR: f32 = 1.45;
const MAX_WRAP_LINES: usize = 64;
const USER_MAX_LINES: usize = 10;
const ASSISTANT_MAX_LINES: usize = 64;

pub const Geometry = struct {
    window: palette.Rect,
    /// Bubble alone, or the pill (bubble + notification text) when one shows.
    dock: palette.Rect,
    /// The round bubble that holds the character.
    dock_bubble: palette.Rect,
    dock_avatar: palette.Rect,
    /// Notification text area; zero-sized when the bubble shows no text.
    dock_text: palette.Rect,
    panel: palette.Rect,
    header: palette.Rect,
    avatar: palette.Rect,
    name_button: palette.Rect,
    brain_button: palette.Rect,
    prev_button: palette.Rect,
    next_button: palette.Rect,
    new_button: palette.Rect,
    close_button: palette.Rect,
    inbox: palette.Rect,
    crew: palette.Rect,
    conversation: palette.Rect,
    approval: palette.Rect,
    error_strip: palette.Rect,
    recap: palette.Rect,
    footer: palette.Rect,
};

/// Rebuilds Companion-only hits before events are routed.
pub fn refreshHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.isCompanionEnabled()) {
        state.reconcileCompanionAvailability();
        return;
    }
    state.syncCompanionProjection();
    const companion = &state.companion_controller;
    companion.frame_width = width;
    companion.frame_height = height;
    const geometry = computeGeometry(state, width, height);
    if (companion.visibility == .sidecar_open) state.syncCompanionComposer(composerRect(geometry.footer));
    registerHits(state, geometry);
}

fn refreshAfterAction(state: *runtime.AppState) void {
    refreshHits(state, state.companion_controller.frame_width, state.companion_controller.frame_height);
    state.markDirty();
}

/// Routes pointer buttons only when the visible Companion surface is hit.
pub fn handleMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool, clicks: u8) bool {
    if (!state.isCompanionEnabled()) return false;
    const result = state.companion_controller.handlePointerButton(x, y, button, down);
    if (button == 1 and !down) {
        if (state.companion_controller.endDockPress()) |was_click| {
            if (was_click) state.openCompanion();
            refreshAfterAction(state);
            return true;
        }
    }
    if (!result.consumed) return false;
    if (result.action) |action| {
        switch (action) {
            // A bubble press opens on release, unless it turns into a drag.
            .open => if (down) state.companion_controller.beginDockPress(x, y),
            .collapse => {
                state.companion_controller.collapse();
                state.blurCompanionComposer();
            },
            .approve, .deny => {
                const resolved = state.resolveCurrentCompanionApproval(if (action == .approve) .approve else .deny);
                state.companion_controller.ui_error = if (resolved) null else "Approval decision was not accepted.";
            },
            .switch_prev => state.cycleCompanion(false),
            .switch_next => state.cycleCompanion(true),
            .companion_menu => state.companion_controller.openMenu(.companions),
            .brain_menu => state.companion_controller.openMenu(.brain),
            .menu_dismiss => state.companion_controller.closeMenu(),
            .menu_select_companion => state.selectCompanion(result.index),
            .menu_new_companion => state.createCompanion(),
            .menu_rename => state.beginCompanionRename(),
            .menu_orders => state.beginCompanionOrders(),
            .recap => state.sendCompanionRecap(),
            .menu_remove => state.removeActiveCompanion(),
            .menu_new_conversation => state.startNewCompanionConversation(),
            .menu_resume_conversation => state.resumeCompanionConversation(result.index),
            .menu_character => if (characterAt(result.index)) |character| state.setActiveCompanionCharacter(character),
            .brain_provider => state.selectCompanionBrainProvider(result.index),
            .brain_model => state.setCompanionBrain(result.index),
            .brain_reasoning => state.setCompanionReasoning(result.index),
            .crew_open => state.openCompanionChatRow(false, result.index),
            .inbox_open => state.openCompanionChatRow(true, result.index),
            .suggestion => state.sendCompanionSuggestion(result.index),
            .panel, .body => {},
        }
        if (action != .panel and action != .body) refreshAfterAction(state);
    }
    if (button == 1 and state.companion_controller.visibility == .sidecar_open and
        (result.action == null or result.action.? == .panel))
    {
        _ = state.routeCompanionComposerMouseButton(x, y, down, clicks);
    }
    return true;
}

/// Prevents underlying hover routing only inside the dock or panel.
pub fn handleMouseMotion(state: *runtime.AppState, x: f32, y: f32, dragging: bool) bool {
    if (!state.isCompanionEnabled()) return false;
    const companion = &state.companion_controller;
    if (companion.dock_press != null) {
        const bounds = dockBoundsAt(companion.frame_width, companion.frame_height, companionScale());
        if (companion.dragDock(x, y, companionScale(), bounds)) refreshAfterAction(state);
        return true;
    }
    const owned = state.companion_controller.hasPointerCapture() or state.companion_controller.hitAt(x, y) != null;
    if (owned) _ = state.routeCompanionComposerMouseMotion(x, y, dragging);
    return owned;
}

/// Scrolls the brain list or the conversation directly; chrome consumes.
pub fn handleWheel(state: *runtime.AppState, x: f32, y: f32, wheel_y: f32) bool {
    if (!state.isCompanionEnabled()) return false;
    const companion = &state.companion_controller;
    _ = companion.hitAt(x, y) orelse return false;
    if (wheel_y == 0.0) return true;
    const delta = -wheel_y * companionScaled(32.0);
    const geometry = computeGeometry(state, companion.frame_width, companion.frame_height);
    if (companion.menu == .brain) {
        const menu = brainMenuLayout(state, geometry);
        if (pointInRect(menu.list, x, y)) {
            companion.scrollBrain(delta);
            state.markDirty();
        }
        return true;
    }
    if (companion.menu != .none) return true;
    if (state.routeCompanionComposerWheel(x, y, wheel_y)) return true;
    if (pointInRect(geometry.conversation, x, y)) {
        companion.scrollConversation(delta);
        state.markDirty();
    }
    return true;
}

/// Owns one physical Escape sequence; each press peels one layer.
pub fn handleEscapeKey(state: *runtime.AppState, down: bool) bool {
    if (!state.isCompanionEnabled()) return false;
    const was_open = state.companion_controller.visibility == .sidecar_open;
    if (!state.companion_controller.handleEscapeKey(down)) return false;
    if (down and was_open and state.companion_controller.visibility != .sidecar_open) state.blurCompanionComposer();
    refreshAfterAction(state);
    return true;
}

pub fn ownsEscapeKey(state: *const runtime.AppState) bool {
    return state.isCompanionEnabled() and state.companion_controller.ownsEscapeKey();
}

pub fn ownsPointerRelease(state: *const runtime.AppState, button: u8) bool {
    return state.isCompanionEnabled() and state.companion_controller.ownsPointerRelease(button);
}

pub fn resetInputCaptures(state: *runtime.AppState) void {
    state.companion_controller.resetInputCaptures();
}

pub fn hitAt(state: *const runtime.AppState, x: f32, y: f32) ?controller.HitAction {
    if (!state.isCompanionEnabled()) return null;
    return state.companion_controller.hitAt(x, y);
}

/// Renders the Companion above panes and below true modals.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.isCompanionEnabled()) return;
    const geometry = computeGeometry(state, width, height);
    switch (state.companion_controller.visibility) {
        .collapsed_chip => renderDock(state, geometry),
        .sidecar_open => renderPanel(state, geometry),
    }
}

fn characterAt(index: usize) ?app_config.CompanionCharacter {
    const all = [_]app_config.CompanionCharacter{ .sprout, .moss, .vireo };
    return if (index < all.len) all[index] else null;
}

// ---- geometry --------------------------------------------------------------

pub fn computeGeometry(state: *runtime.AppState, width: f32, height: f32) Geometry {
    return computeGeometryAt(state, width, height, companionScale());
}

fn computeGeometryAt(state: *runtime.AppState, width: f32, height: f32, s: f32) Geometry {
    const companion = &state.companion_controller;
    const window: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = @max(width, 0.0), .h = @max(height, 0.0) };

    // Dock: a draggable character bubble. It grows into a pill with one line
    // of text only when something needs the user, extending toward the
    // window's middle so the bubble itself never jumps.
    const bubble_size = @min(DOCK_BUBBLE * s, @min(window.w, window.h));
    const bounds = dockBoundsAt(window.w, window.h, s);
    const dock_bubble: palette.Rect = .{
        .x = @max(window.w - (DOCK_EDGE_MARGIN + std.math.clamp(companion.dock_right, 0.0, bounds.max_right)) * s - bubble_size, 0.0),
        .y = @max(window.h - (DOCK_EDGE_MARGIN + std.math.clamp(companion.dock_bottom, 0.0, bounds.max_bottom)) * s - bubble_size, 0.0),
        .w = bubble_size,
        .h = bubble_size,
    };
    const text_w: f32 = if (dockShowsText(state))
        @min(@min(text_measure.textWidth(.ui_bold, DOCK_TEXT_FONT * s, dockStatus(state).text), DOCK_TEXT_MAX * s), @max(window.w - bubble_size - DOCK_TEXT_PAD * 2.0 * s, 0.0))
    else
        0.0;
    var dock = dock_bubble;
    var dock_text: palette.Rect = .{ .x = dock_bubble.x, .y = dock_bubble.y };
    if (text_w > 0.0) {
        const pill_w = bubble_size + text_w + DOCK_TEXT_PAD * 1.5 * s;
        const extend_left = dock_bubble.x + bubble_size * 0.5 > window.w * 0.5;
        dock.w = pill_w;
        dock.x = if (extend_left) dock_bubble.x + bubble_size - pill_w else dock_bubble.x;
        dock.x = std.math.clamp(dock.x, 0.0, @max(window.w - pill_w, 0.0));
        dock_text = .{
            .x = if (extend_left) dock.x + DOCK_TEXT_PAD * s else dock_bubble.x + bubble_size + DOCK_TEXT_PAD * 0.5 * s,
            .y = dock.y,
            .w = text_w,
            .h = dock.h,
        };
    }
    const avatar_inset = DOCK_AVATAR_INSET * s;
    const dock_avatar: palette.Rect = .{ .x = dock_bubble.x + avatar_inset, .y = dock_bubble.y + avatar_inset, .w = @max(bubble_size - avatar_inset * 2.0, 0.0), .h = @max(bubble_size - avatar_inset * 2.0, 0.0) };

    // Panel: right-side column, full height.
    const inset = @min(PANEL_INSET * s, @min(window.w, window.h) * 0.5);
    const panel_w = @max(@min(PANEL_WIDTH * s, window.w - inset * 2.0), 0.0);
    const panel: palette.Rect = .{ .x = window.w - inset - panel_w, .y = inset, .w = panel_w, .h = @max(window.h - inset * 2.0, 0.0) };
    const header: palette.Rect = .{ .x = panel.x, .y = panel.y, .w = panel.w, .h = @min(HEADER_HEIGHT * s, panel.h) };
    const footer_h = @min(FOOTER_HEIGHT * s, @max(panel.h - header.h, 0.0));
    const footer: palette.Rect = .{ .x = panel.x, .y = panel.y + panel.h - footer_h, .w = panel.w, .h = footer_h };

    const button = HEADER_BUTTON * s;
    const button_y = header.y + (header.h - button) * 0.5;
    const close_button: palette.Rect = .{ .x = header.x + header.w - 12.0 * s - button, .y = button_y, .w = button, .h = button };
    const new_button: palette.Rect = .{ .x = close_button.x - 6.0 * s - button, .y = button_y, .w = button, .h = button };
    const switcher = companion.identity.count > 1;
    const next_button: palette.Rect = if (switcher) .{ .x = new_button.x - 10.0 * s - button, .y = button_y, .w = button, .h = button } else .{};
    const prev_button: palette.Rect = if (switcher) .{ .x = next_button.x - 2.0 * s - button, .y = button_y, .w = button, .h = button } else .{};
    const avatar: palette.Rect = .{ .x = header.x + 12.0 * s, .y = header.y + 9.0 * s, .w = 44.0 * s, .h = 46.0 * s };
    const text_x = avatar.x + avatar.w + 10.0 * s;
    const text_right = (if (switcher) prev_button.x else new_button.x) - 8.0 * s;
    const name_w = @min(text_measure.textWidth(.ui_bold, 15.0 * s, companion.identity.name.slice()) + 22.0 * s, @max(text_right - text_x, 0.0));
    const name_button: palette.Rect = .{ .x = text_x - 4.0 * s, .y = header.y + 10.0 * s, .w = name_w + 4.0 * s, .h = 24.0 * s };
    const brain_w = @min(text_measure.textWidth(.ui, 11.0 * s, companion.identity.brain.slice()) + 30.0 * s, @max(text_right - text_x, 0.0));
    const brain_button: palette.Rect = .{ .x = text_x - 4.0 * s, .y = header.y + 35.0 * s, .w = brain_w + 4.0 * s, .h = 20.0 * s };

    // Body stack between header and footer: inbox, crew, conversation, approval.
    var top = header.y + header.h;
    var bottom = footer.y;
    const inner_x = panel.x + CONTENT_INSET * s;
    const inner_w = @max(panel.w - CONTENT_INSET * 2.0 * s, 0.0);

    const approval_h: f32 = if (companion.presentation.has_approval) APPROVAL_HEIGHT * s else 0.0;
    const approval: palette.Rect = .{ .x = inner_x, .y = bottom - approval_h, .w = inner_w, .h = @max(approval_h - 8.0 * s, 0.0) };
    bottom -= approval_h;
    const error_h: f32 = if (errorMessage(state).len > 0) ERROR_STRIP_HEIGHT * s else 0.0;
    const error_strip: palette.Rect = .{ .x = inner_x, .y = bottom - error_h, .w = inner_w, .h = @max(error_h - 6.0 * s, 0.0) };
    bottom -= error_h;
    const recap_h: f32 = if (companion.recap_available) RECAP_HEIGHT * s else 0.0;
    const recap: palette.Rect = .{ .x = inner_x, .y = bottom - recap_h, .w = inner_w, .h = @max(recap_h - 8.0 * s, 0.0) };
    bottom -= recap_h;

    const inbox_rows = @min(companion.inbox_count, MAX_INBOX_ROWS_SHOWN);
    const inbox_h: f32 = if (inbox_rows == 0) 0.0 else (SECTION_TITLE_HEIGHT + @as(f32, @floatFromInt(inbox_rows)) * (INBOX_ROW_HEIGHT + ROW_GAP) + 6.0) * s;
    const inbox: palette.Rect = .{ .x = inner_x, .y = top + 8.0 * s, .w = inner_w, .h = @min(inbox_h, @max(bottom - top - 8.0 * s, 0.0)) };
    if (inbox_h > 0.0) top = inbox.y + inbox.h;
    const crew_rows = @min(companion.crew_count, MAX_CREW_ROWS_SHOWN);
    const crew_h: f32 = if (crew_rows == 0) 0.0 else (SECTION_TITLE_HEIGHT + @as(f32, @floatFromInt(crew_rows)) * (CREW_ROW_HEIGHT + ROW_GAP) + 6.0) * s;
    const crew: palette.Rect = .{ .x = inner_x, .y = top + 8.0 * s, .w = inner_w, .h = @min(crew_h, @max(bottom - top - 8.0 * s, 0.0)) };
    if (crew_h > 0.0) top = crew.y + crew.h;
    const conversation: palette.Rect = .{ .x = panel.x, .y = top + 4.0 * s, .w = panel.w, .h = @max(bottom - top - 4.0 * s, 0.0) };

    return .{
        .window = window,
        .dock = dock,
        .dock_bubble = dock_bubble,
        .dock_avatar = dock_avatar,
        .dock_text = dock_text,
        .panel = panel,
        .header = header,
        .avatar = avatar,
        .name_button = name_button,
        .brain_button = brain_button,
        .prev_button = prev_button,
        .next_button = next_button,
        .new_button = new_button,
        .close_button = close_button,
        .inbox = inbox,
        .crew = crew,
        .conversation = conversation,
        .approval = approval,
        .error_strip = error_strip,
        .recap = recap,
        .footer = footer,
    };
}

/// How far (logical units) the bubble may sit from the right/bottom edges.
fn dockBoundsAt(width: f32, height: f32, s: f32) controller.DockBounds {
    const scale = @max(s, 0.01);
    return .{
        .max_right = @max(width / scale - DOCK_BUBBLE - DOCK_EDGE_MARGIN * 2.0, 0.0),
        .max_bottom = @max(height / scale - DOCK_BUBBLE - DOCK_EDGE_MARGIN * 2.0, 0.0),
    };
}

/// Text rides along only for things the user must act on; everything else
/// is a quiet badge on the bubble.
fn dockShowsText(state: *runtime.AppState) bool {
    return switch (dockStatus(state).tone) {
        .attention, .failure => true,
        .quiet, .busy => false,
    };
}

fn composerRect(footer: palette.Rect) palette.Rect {
    const s = companionScale();
    if (footer.w < 180.0 * s or footer.h < 70.0 * s) return .{ .x = footer.x, .y = footer.y };
    return .{ .x = footer.x + 12.0 * s, .y = footer.y + 10.0 * s, .w = footer.w - 24.0 * s, .h = footer.h - 22.0 * s };
}

fn rowRect(section: palette.Rect, index: usize, row_h: f32) palette.Rect {
    const s = companionScale();
    return .{
        .x = section.x,
        .y = section.y + SECTION_TITLE_HEIGHT * s + @as(f32, @floatFromInt(index)) * (row_h + ROW_GAP) * s,
        .w = section.w,
        .h = row_h * s,
    };
}

fn approvalButtons(card: palette.Rect) [2]palette.Rect {
    const s = companionScale();
    const w = 84.0 * s;
    const h = 28.0 * s;
    const y = card.y + card.h - h - 10.0 * s;
    const approve: palette.Rect = .{ .x = card.x + card.w - 12.0 * s - w, .y = y, .w = w, .h = h };
    const deny: palette.Rect = .{ .x = approve.x - 8.0 * s - w, .y = y, .w = w, .h = h };
    return .{ deny, approve };
}

// ---- hits -------------------------------------------------------------------

fn registerHits(state: *runtime.AppState, geometry: Geometry) void {
    const companion = &state.companion_controller;
    companion.clearHits();
    switch (companion.visibility) {
        .collapsed_chip => companion.addHit(geometry.dock, .open),
        .sidecar_open => {
            companion.addHit(geometry.panel, .panel);
            companion.addHit(geometry.conversation, .body);
            companion.addHit(geometry.name_button, .companion_menu);
            companion.addHit(geometry.avatar, .companion_menu);
            companion.addHit(geometry.brain_button, .brain_menu);
            if (companion.identity.count > 1) {
                companion.addHit(geometry.prev_button, .switch_prev);
                companion.addHit(geometry.next_button, .switch_next);
            }
            companion.addHit(geometry.new_button, .menu_new_companion);
            companion.addHit(geometry.close_button, .collapse);
            for (0..@min(companion.inbox_count, MAX_INBOX_ROWS_SHOWN)) |index| {
                const row = rowRect(geometry.inbox, index, INBOX_ROW_HEIGHT);
                if (row.y + row.h <= geometry.inbox.y + geometry.inbox.h + 1.0) companion.addIndexedHit(row, .inbox_open, index);
            }
            for (0..@min(companion.crew_count, MAX_CREW_ROWS_SHOWN)) |index| {
                const row = rowRect(geometry.crew, index, CREW_ROW_HEIGHT);
                if (row.y + row.h <= geometry.crew.y + geometry.crew.h + 1.0) companion.addIndexedHit(row, .crew_open, index);
            }
            if (companion.presentation.activity_count == 0) {
                const layout = emptyStateLayout(geometry.conversation);
                for (layout.suggestions, 0..) |rect, index| {
                    if (rectInside(rect, geometry.conversation)) companion.addIndexedHit(rect, .suggestion, index);
                }
            }
            if (companion.recap_available) companion.addHit(geometry.recap, .recap);
            if (companion.presentation.has_approval and geometry.approval.h > 0.0) {
                const buttons = approvalButtons(geometry.approval);
                companion.addHit(buttons[0], .deny);
                companion.addHit(buttons[1], .approve);
            }
            switch (companion.menu) {
                .none => {},
                .companions => registerCompanionMenuHits(state, geometry),
                .brain => registerBrainMenuHits(state, geometry),
            }
        },
    }
}

// ---- dock -------------------------------------------------------------------

const DockStatus = struct { text: []const u8, tone: enum { quiet, busy, attention, failure } };

fn dockStatus(state: *runtime.AppState) DockStatus {
    const companion = &state.companion_controller;
    const needs_you = dockNeedsYouCount(state);
    if (needs_you > 0) return .{ .text = if (needs_you == 1) "1 thing needs you" else framePrint(state, "{d} things need you", .{needs_you}), .tone = .attention };
    if (companion.presentation.has_failure) return .{ .text = "Needs a look", .tone = .failure };
    if (companion.recap_available) return .{ .text = "Welcome back · catch up?", .tone = .busy };
    const running = companion.crewRunningCount();
    if (companion.presentation.working and running > 0) return .{ .text = framePrint(state, "Working · {d} in crew", .{running}), .tone = .busy };
    if (companion.presentation.working) return .{ .text = "Working…", .tone = .busy };
    if (running > 0) return .{ .text = if (running == 1) "1 chat running" else framePrint(state, "{d} chats running", .{running}), .tone = .busy };
    return .{ .text = "Ready when you are", .tone = .quiet };
}

fn crewNeedsYouCount(companion: *const controller) usize {
    var count: usize = 0;
    for (companion.crew[0..companion.crew_count]) |row| {
        if (row.attention == .approval or row.attention == .blocked) count += 1;
    }
    return count;
}

// Collapsed dock: a round character bubble with a badge; a one-line
// notification rides beside it only when something needs the user.
fn renderDock(state: *runtime.AppState, geometry: Geometry) void {
    const s = companionScale();
    const chrome = theme.companionChrome();
    const dock = geometry.dock;
    const bubble = geometry.dock_bubble;
    if (bubble.w < 24.0 * s or bubble.h < 24.0 * s) return;
    const radius = dock.h * 0.5;
    const dragging = if (state.companion_controller.dock_press) |press| press.dragged else false;
    queueRoundedRectClipped(state, offsetRect(dock, 0.0, @as(f32, if (dragging) 8.0 else 4.0) * s), color(theme.scrim(@as(f32, if (dragging) 0.3 else 0.2))), radius, geometry.window);
    const status = dockStatus(state);
    const status_color = switch (status.tone) {
        .quiet => chrome.text_subtle,
        .busy => chrome.identity_fg,
        .attention => chrome.warning,
        .failure => chrome.danger,
    };
    const ring = switch (status.tone) {
        .attention, .failure => status_color,
        else => chrome.border,
    };
    queuePanel(state, dock, color(surface()), color(ring), radius, 1.0 * s);

    const character = activeCompanionCharacter(state);
    renderCompanionCharacter(state, characterInSlot(geometry.dock_avatar, character), state.companion_controller.visualState(), character, .full);

    if (geometry.dock_text.w > 0.0) {
        const font = DOCK_TEXT_FONT * s;
        const line_h = font * 1.4;
        const text_rect: palette.Rect = .{ .x = geometry.dock_text.x, .y = dock.y + (dock.h - line_h) * 0.5, .w = geometry.dock_text.w, .h = line_h };
        queueBoldText(state, text_rect, truncatedText(state, .ui_bold, font, geometry.dock_text.w, status.text), color(status_color), font, dock);
    }

    // Badge on the bubble's top-right: a count when things need the user,
    // a dot while work runs or a recap is waiting.
    const count = dockNeedsYouCount(state);
    if (count > 0) {
        const label = if (count > 9) "9+" else framePrint(state, "{d}", .{count});
        const badge_font = 9.5 * s;
        const badge_h = 16.0 * s;
        const badge_w = @max(badge_h, text_measure.textWidth(.ui_bold, badge_font, label) + 8.0 * s);
        const badge: palette.Rect = .{ .x = bubble.x + bubble.w - badge_w + 3.0 * s, .y = bubble.y - 3.0 * s, .w = badge_w, .h = badge_h };
        queuePanel(state, badge, color(chrome.warning), color(surface()), badge_h * 0.5, 1.0 * s);
        const label_w = text_measure.textWidth(.ui_bold, badge_font, label);
        queueBoldText(state, .{ .x = badge.x + (badge.w - label_w) * 0.5, .y = badge.y + (badge_h - badge_font * 1.3) * 0.5, .w = label_w + 1.0, .h = badge_font * 1.3 }, label, color(surface()), badge_font, geometry.window);
    } else if (status.tone == .busy or status.tone == .failure) {
        const dot_size = 10.0 * s;
        const dot: palette.Rect = .{ .x = bubble.x + bubble.w - dot_size + 1.0 * s, .y = bubble.y - 1.0 * s, .w = dot_size, .h = dot_size };
        queuePanel(state, dot, color(status_color), color(surface()), dot_size * 0.5, 1.0 * s);
    }
}

fn dockNeedsYouCount(state: *runtime.AppState) usize {
    const companion = &state.companion_controller;
    return companion.inboxNeedsYouCount() + @as(usize, if (companion.presentation.has_approval) 1 else 0) + crewNeedsYouCount(companion);
}

// ---- panel ------------------------------------------------------------------

fn renderPanel(state: *runtime.AppState, geometry: Geometry) void {
    if (geometry.panel.w <= 0.0 or geometry.panel.h <= 0.0) return;
    const s = companionScale();
    const chrome = theme.companionChrome();
    queueRect(state, geometry.window, color(theme.scrim(0.18)));
    queueRoundedRectClipped(state, expandedOffsetRect(geometry.panel, 8.0 * s, 18.0 * s), color(theme.scrim(0.16)), 18.0 * s, geometry.window);
    queueRoundedRectClipped(state, offsetRect(geometry.panel, 0.0, 4.0 * s), color(theme.scrim(0.24)), 14.0 * s, geometry.window);
    queuePanel(state, geometry.panel, color(surface()), color(chrome.border), 14.0 * s, 1.0 * s);
    renderHeader(state, geometry);
    renderConversation(state, geometry);
    renderInbox(state, geometry);
    renderCrew(state, geometry);
    renderErrorStrip(state, geometry);
    renderRecap(state, geometry);
    renderApproval(state, geometry);
    renderFooter(state, geometry);
    switch (state.companion_controller.menu) {
        .none => {},
        .companions => renderCompanionMenu(state, geometry),
        .brain => renderBrainMenu(state, geometry),
    }
}

// Header: who the companion is, its brain, the roster switcher, and controls.
fn renderHeader(state: *runtime.AppState, geometry: Geometry) void {
    const s = companionScale();
    const chrome = theme.companionChrome();
    const header = geometry.header;
    if (header.w < 160.0 * s or header.h < 50.0 * s) return;
    const identity = &state.companion_controller.identity;
    const character = activeCompanionCharacter(state);
    renderCompanionCharacter(state, characterInSlot(geometry.avatar, character), state.companion_controller.visualState(), character, .full);

    const name_rect = geometry.name_button;
    const name_w = @max(name_rect.w - 26.0 * s, 0.0);
    queueBoldText(state, .{ .x = name_rect.x + 4.0 * s, .y = name_rect.y + 2.0 * s, .w = name_w, .h = 20.0 * s }, truncatedText(state, .ui_bold, 15.0 * s, name_w, identity.name.slice()), color(chrome.text), 15.0 * s, header);
    const caret_x = name_rect.x + 4.0 * s + @min(text_measure.textWidth(.ui_bold, 15.0 * s, identity.name.slice()), name_w) + 6.0 * s;
    queueText(state, .{ .x = caret_x, .y = name_rect.y + 4.0 * s, .w = 12.0 * s, .h = 16.0 * s }, "▾", color(chrome.text_subtle), 10.0 * s, header);

    const brain = geometry.brain_button;
    queuePanel(state, brain, color(chrome.surface_deep), color(hairline()), 10.0 * s, 1.0 * s);
    queueRoundedRect(state, .{ .x = brain.x + 8.0 * s, .y = brain.y + (brain.h - 6.0 * s) * 0.5, .w = 6.0 * s, .h = 6.0 * s }, color(chrome.accent), 3.0 * s);
    const brain_w = @max(brain.w - 26.0 * s, 0.0);
    queueText(state, .{ .x = brain.x + 19.0 * s, .y = brain.y + 2.5 * s, .w = brain_w, .h = 15.0 * s }, truncatedText(state, .ui, 11.0 * s, brain_w, identity.brain.slice()), color(chrome.text_muted), 11.0 * s, brain);

    if (identity.count > 1) {
        renderHeaderButton(state, geometry.prev_button, "‹");
        renderHeaderButton(state, geometry.next_button, "›");
    }
    renderHeaderButton(state, geometry.new_button, "+");
    renderHeaderButton(state, geometry.close_button, "−");
    const divider_inset = snappedStroke(1.0 * s);
    queueRect(state, .{ .x = header.x + divider_inset, .y = header.y + header.h - 1.0 * s, .w = @max(header.w - divider_inset * 2.0, 0.0), .h = 1.0 * s }, color(hairline()));
}

fn renderHeaderButton(state: *runtime.AppState, rect: palette.Rect, glyph: []const u8) void {
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    const s = companionScale();
    const chrome = theme.companionChrome();
    queuePanel(state, rect, color(surface()), color(hairline()), 7.0 * s, 1.0 * s);
    queueCenteredText(state, rect, glyph, color(chrome.text_muted), 14.0 * s, .ui_bold, rect);
}

fn attentionColor(chrome: theme.CompanionChrome, attention: controller.Attention) [4]f32 {
    return switch (attention) {
        .approval, .blocked => chrome.warning,
        .failed => chrome.danger,
        .running => chrome.accent,
        .done => chrome.identity_fg,
        .idle => chrome.text_subtle,
    };
}

fn renderSectionTitle(state: *runtime.AppState, section: palette.Rect, title: []const u8) void {
    const s = companionScale();
    const chrome = theme.companionChrome();
    queueBoldText(state, .{ .x = section.x + 2.0 * s, .y = section.y + 2.0 * s, .w = section.w, .h = 16.0 * s }, title, color(chrome.text_subtle), 10.0 * s, section);
}

// Needs-you inbox: every chat on the machine waiting on the user.
fn renderInbox(state: *runtime.AppState, geometry: Geometry) void {
    const companion = &state.companion_controller;
    const shown = @min(companion.inbox_count, MAX_INBOX_ROWS_SHOWN);
    if (shown == 0 or geometry.inbox.h <= 0.0) return;
    const s = companionScale();
    const chrome = theme.companionChrome();
    const title = if (companion.inbox_count > shown)
        framePrint(state, "NEEDS YOU · {d} (showing {d})", .{ companion.inbox_count, shown })
    else
        framePrint(state, "NEEDS YOU · {d}", .{companion.inbox_count});
    renderSectionTitle(state, geometry.inbox, title);
    for (companion.inbox[0..shown], 0..) |*row, index| {
        const rect = rowRect(geometry.inbox, index, INBOX_ROW_HEIGHT);
        if (rect.y + rect.h > geometry.inbox.y + geometry.inbox.h + 1.0) break;
        const accent = attentionColor(chrome, row.attention);
        queuePanel(state, rect, color(opaqueOver(surface(), theme.withAlpha(accent, 22))), color(opaqueOver(surface(), theme.withAlpha(accent, 90))), 10.0 * s, 1.0 * s);
        queueRoundedRect(state, .{ .x = rect.x + 12.0 * s, .y = rect.y + 13.0 * s, .w = 8.0 * s, .h = 8.0 * s }, color(accent), 4.0 * s);
        const pill_w = 54.0 * s;
        const text_x = rect.x + 28.0 * s;
        const text_w = @max(rect.w - (text_x - rect.x) - pill_w - 18.0 * s, 0.0);
        const label = framePrint(state, "{s}: {s}", .{ row.attention.label(), row.title.slice() });
        queueBoldText(state, .{ .x = text_x, .y = rect.y + 6.0 * s, .w = text_w, .h = 17.0 * s }, truncatedText(state, .ui_bold, 12.0 * s, text_w, label), color(chrome.text), 12.0 * s, rect);
        queueText(state, .{ .x = text_x, .y = rect.y + 24.0 * s, .w = text_w, .h = 15.0 * s }, truncatedText(state, .ui, 11.0 * s, text_w, row.detail.slice()), color(chrome.text_subtle), 11.0 * s, rect);
        const pill: palette.Rect = .{ .x = rect.x + rect.w - pill_w - 10.0 * s, .y = rect.y + (rect.h - 24.0 * s) * 0.5, .w = pill_w, .h = 24.0 * s };
        queuePanel(state, pill, color(surface()), color(chrome.border), 8.0 * s, 1.0 * s);
        queueCenteredText(state, pill, "Open", color(chrome.text), 11.0 * s, .ui_bold, pill);
    }
}

// Crew: chats this companion delegated to, newest attention first.
fn renderCrew(state: *runtime.AppState, geometry: Geometry) void {
    const companion = &state.companion_controller;
    const shown = @min(companion.crew_count, MAX_CREW_ROWS_SHOWN);
    if (shown == 0 or geometry.crew.h <= 0.0) return;
    const s = companionScale();
    const chrome = theme.companionChrome();
    const running = companion.crewRunningCount();
    const title = if (running > 0)
        framePrint(state, "CREW · {d} RUNNING · {d} TOTAL", .{ running, companion.crew_count })
    else
        framePrint(state, "CREW · {d}", .{companion.crew_count});
    renderSectionTitle(state, geometry.crew, title);
    for (companion.crew[0..shown], 0..) |*row, index| {
        const rect = rowRect(geometry.crew, index, CREW_ROW_HEIGHT);
        if (rect.y + rect.h > geometry.crew.y + geometry.crew.h + 1.0) break;
        const accent = attentionColor(chrome, row.attention);
        queuePanel(state, rect, color(chrome.surface_deep), color(hairline()), 9.0 * s, 1.0 * s);
        queueRoundedRect(state, .{ .x = rect.x + 10.0 * s, .y = rect.y + (rect.h - 8.0 * s) * 0.5, .w = 8.0 * s, .h = 8.0 * s }, color(accent), 4.0 * s);
        const status = row.attention.label();
        const status_w = text_measure.textWidth(.ui_bold, 10.0 * s, status) + 16.0 * s;
        const pill: palette.Rect = .{ .x = rect.x + rect.w - status_w - 8.0 * s, .y = rect.y + (rect.h - 20.0 * s) * 0.5, .w = status_w, .h = 20.0 * s };
        queueRoundedRect(state, pill, color(opaqueOver(chrome.surface_deep, theme.withAlpha(accent, 40))), 10.0 * s);
        queueCenteredText(state, pill, status, color(accent), 10.0 * s, .ui_bold, pill);
        const text_x = rect.x + 26.0 * s;
        const text_w = @max(pill.x - text_x - 8.0 * s, 0.0);
        queueBoldText(state, .{ .x = text_x, .y = rect.y + 4.0 * s, .w = text_w, .h = 16.0 * s }, truncatedText(state, .ui_bold, 11.5 * s, text_w, row.title.slice()), color(chrome.text), 11.5 * s, rect);
        const detail = if (row.detail.slice().len > 0) framePrint(state, "{s} · {s}", .{ row.provider.slice(), row.detail.slice() }) else row.provider.slice();
        queueText(state, .{ .x = text_x, .y = rect.y + 21.0 * s, .w = text_w, .h = 14.0 * s }, truncatedText(state, .ui, 10.5 * s, text_w, detail), color(chrome.text_subtle), 10.5 * s, rect);
    }
}

fn errorMessage(state: *runtime.AppState) []const u8 {
    const companion = &state.companion_controller;
    if (companion.ui_error) |message| return message;
    const frame = &companion.presentation;
    if (frame.provider_error.slice().len > 0) return frame.provider_error.slice();
    if (frame.control_error.slice().len > 0) return frame.control_error.slice();
    return "";
}

fn renderErrorStrip(state: *runtime.AppState, geometry: Geometry) void {
    const message = errorMessage(state);
    if (message.len == 0 or geometry.error_strip.h <= 0.0) return;
    const s = companionScale();
    const chrome = theme.companionChrome();
    const rect = geometry.error_strip;
    queuePanel(state, rect, color(opaqueOver(surface(), chrome.failure_card)), color(opaqueOver(surface(), chrome.failure_border)), 8.0 * s, 1.0 * s);
    const text_w = @max(rect.w - 20.0 * s, 0.0);
    queueText(state, .{ .x = rect.x + 10.0 * s, .y = rect.y + (rect.h - 16.0 * s) * 0.5, .w = text_w, .h = 16.0 * s }, truncatedText(state, .ui, 11.0 * s, text_w, singleLineText(state, message)), color(chrome.failure_fg), 11.0 * s, rect);
}

// Welcome-back offer: one click asks the companion for a recap.
fn renderRecap(state: *runtime.AppState, geometry: Geometry) void {
    const companion = &state.companion_controller;
    if (!companion.recap_available or geometry.recap.h <= 0.0) return;
    const s = companionScale();
    const chrome = theme.companionChrome();
    const rect = geometry.recap;
    queuePanel(state, rect, color(opaqueOver(surface(), chrome.ready_fill)), color(opaqueOver(surface(), theme.withAlpha(chrome.accent, 90))), 10.0 * s, 1.0 * s);
    const text_w = @max(rect.w - 120.0 * s, 0.0);
    const label = framePrint(state, "Welcome back · away {d} min", .{companion.recap_minutes});
    queueBoldText(state, .{ .x = rect.x + 12.0 * s, .y = rect.y + (rect.h - 17.0 * s) * 0.5, .w = text_w, .h = 17.0 * s }, truncatedText(state, .ui_bold, 11.5 * s, text_w, label), color(chrome.text), 11.5 * s, rect);
    const pill: palette.Rect = .{ .x = rect.x + rect.w - 108.0 * s, .y = rect.y + (rect.h - 24.0 * s) * 0.5, .w = 98.0 * s, .h = 24.0 * s };
    queueRoundedRect(state, pill, color(chrome.accent), 8.0 * s);
    queueCenteredText(state, pill, "Catch me up", color(chrome.accent_fg), 11.0 * s, .ui_bold, pill);
}

// The companion's own pending approval, pinned above the composer.
fn renderApproval(state: *runtime.AppState, geometry: Geometry) void {
    const frame = &state.companion_controller.presentation;
    if (!frame.has_approval or geometry.approval.h <= 0.0) return;
    const s = companionScale();
    const chrome = theme.companionChrome();
    const card = geometry.approval;
    queuePanel(state, card, color(opaqueOver(surface(), chrome.approval_card)), color(opaqueOver(surface(), chrome.approval_border)), 10.0 * s, 1.0 * s);
    const text_w = @max(card.w - 24.0 * s, 0.0);
    const title = if (frame.approval_title.slice().len > 0) frame.approval_title.slice() else "Approval needed";
    queueBoldText(state, .{ .x = card.x + 12.0 * s, .y = card.y + 9.0 * s, .w = text_w, .h = 17.0 * s }, truncatedText(state, .ui_bold, 12.0 * s, text_w, singleLineText(state, title)), color(chrome.approval_title), 12.0 * s, card);
    queueText(state, .{ .x = card.x + 12.0 * s, .y = card.y + 28.0 * s, .w = text_w, .h = 16.0 * s }, truncatedText(state, .ui, 11.0 * s, text_w, singleLineText(state, frame.approval_body.slice())), color(chrome.approval_body), 11.0 * s, card);
    const buttons = approvalButtons(card);
    queuePanel(state, buttons[0], color(surface()), color(chrome.border), 8.0 * s, 1.0 * s);
    queueCenteredText(state, buttons[0], "Deny", color(chrome.text), 11.5 * s, .ui_bold, buttons[0]);
    queueRoundedRect(state, buttons[1], color(chrome.warning), 8.0 * s);
    queueCenteredText(state, buttons[1], "Approve", color(chrome.warning_fg), 11.5 * s, .ui_bold, buttons[1]);
}

fn renderFooter(state: *runtime.AppState, geometry: Geometry) void {
    const chrome = theme.companionChrome();
    const footer = geometry.footer;
    const composer = composerRect(footer);
    if (composer.w <= 0.0 or composer.h <= 0.0) return;
    const divider_inset = snappedStroke(companionScaled(1.0));
    queueRect(state, .{ .x = footer.x + divider_inset, .y = footer.y, .w = @max(footer.w - divider_inset * 2.0, 0.0), .h = companionScaled(1.0) }, color(hairline()));
    state.syncCompanionComposer(composer);
    // The shared composer defaults to the chat layer; inherit the overlay
    // layer or panes would cover it.
    state.companion_composer.z_index = state.palette_overlay_batch.current_z_index;
    var composer_batch: palette.RenderBatch = .{};
    defer composer_batch.deinit(state.allocator);
    state.companion_composer.render(state.allocator, &composer_batch) catch |err| log.warn("failed to render Companion composer: {s}", .{@errorName(err)});
    state.palette_overlay_batch.appendStableBatch(state.allocator, state.palette_frame_text_arena.allocator(), &composer_batch) catch |err| log.warn("failed to stage Companion composer: {s}", .{@errorName(err)});
    if (state.companion_controller.editingSettings()) {
        const s = companionScale();
        const label = if (state.companion_controller.orders_mode) "STANDING ORDERS · Enter to save, Esc to cancel" else "RENAME · Enter to save, Esc to cancel";
        queueBoldText(state, .{ .x = composer.x + 4.0 * s, .y = footer.y - 18.0 * s, .w = composer.w, .h = 15.0 * s }, label, color(chrome.identity_fg), 10.0 * s, geometry.panel);
    }
}

// ---- conversation -----------------------------------------------------------

const WrappedText = struct {
    lines: [MAX_WRAP_LINES][]const u8 = [_][]const u8{""} ** MAX_WRAP_LINES,
    count: usize = 0,
    truncated: bool = false,
};

/// Measured greedy wrap. Lines are subslices of `text`; embedded newlines
/// force breaks and output is bounded to `max_lines`.
fn wrapText(text: []const u8, max_width: f32, role: palette.FontRole, font_size: f32, max_lines: usize) WrappedText {
    var wrapped: WrappedText = .{};
    const limit = @min(max_lines, MAX_WRAP_LINES);
    if (max_width <= 0.0 or limit == 0) return wrapped;
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |paragraph| {
        var remaining = std.mem.trimEnd(u8, paragraph, " \t\r");
        if (remaining.len == 0) {
            if (wrapped.count > 0 and wrapped.count < limit and wrapped.lines[wrapped.count - 1].len > 0) {
                wrapped.lines[wrapped.count] = "";
                wrapped.count += 1;
            }
            continue;
        }
        while (remaining.len > 0) {
            if (wrapped.count == limit) {
                wrapped.truncated = true;
                return wrapped;
            }
            const break_index = measuredLineBreak(remaining, max_width, role, font_size);
            wrapped.lines[wrapped.count] = std.mem.trimEnd(u8, remaining[0..break_index], " \t");
            wrapped.count += 1;
            remaining = std.mem.trimStart(u8, remaining[break_index..], " \t");
        }
    }
    while (wrapped.count > 0 and wrapped.lines[wrapped.count - 1].len == 0) wrapped.count -= 1;
    return wrapped;
}

fn measuredLineBreak(text: []const u8, max_width: f32, role: palette.FontRole, font_size: f32) usize {
    if (text_measure.textWidth(role, font_size, text) <= max_width) return text.len;
    var low: usize = 0;
    var high: usize = text.len - 1;
    var best: usize = 0;
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const candidate = utf8FloorIndex(text, mid);
        if (text_measure.textWidth(role, font_size, text[0..candidate]) <= max_width) {
            best = @max(best, candidate);
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }
    if (best == 0) {
        var first: usize = 1;
        while (first < text.len and (text[first] & 0xC0) == 0x80) first += 1;
        return first;
    }
    if (std.mem.lastIndexOfScalar(u8, text[0..best], ' ')) |space_index| {
        if (space_index > 0) return space_index;
    }
    return best;
}

/// Light Markdown cleanup for conversational display: drops emphasis and
/// code ticks, heading hashes, and fence lines; turns list dashes into
/// bullets. Content is never rewritten beyond markup.
fn conversationalText(state: *runtime.AppState, text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const buffer = state.palette_frame_text_arena.allocator().alloc(u8, trimmed.len * 2) catch return trimmed;
    var len: usize = 0;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) continue;
        if (!first) {
            buffer[len] = '\n';
            len += 1;
        }
        first = false;
        const leading = line.len - std.mem.trimStart(u8, line, " ").len;
        var body = line[leading..];
        while (body.len > 0 and body[0] == '#') body = body[1..];
        if (body.len != line[leading..].len) body = std.mem.trimStart(u8, body, " ");
        if ((std.mem.startsWith(u8, body, "- ") or std.mem.startsWith(u8, body, "* ")) and body.len > 2) {
            @memcpy(buffer[len..][0..leading], line[0..leading]);
            len += leading;
            const bullet = "• ";
            @memcpy(buffer[len..][0..bullet.len], bullet);
            len += bullet.len;
            body = body[2..];
        } else {
            @memcpy(buffer[len..][0..leading], line[0..leading]);
            len += leading;
        }
        var index: usize = 0;
        while (index < body.len) : (index += 1) {
            const byte = body[index];
            if (byte == '`') continue;
            if ((byte == '*' or byte == '_') and index + 1 < body.len and body[index + 1] == byte) {
                index += 1;
                continue;
            }
            buffer[len] = byte;
            len += 1;
        }
    }
    return buffer[0..len];
}

const ConversationItemLayout = struct {
    height: f32,
};

fn bodyLineHeight() f32 {
    return companionScaled(BODY_FONT) * LINE_HEIGHT_FACTOR;
}

fn conversationWidths(conversation: palette.Rect) struct { text: f32, bubble: f32 } {
    const s = companionScale();
    const text_w = @max(conversation.w - CONTENT_INSET * 2.0 * s, 0.0);
    return .{ .text = text_w, .bubble = @max(text_w * 0.82 - 20.0 * s, 0.0) };
}

/// Height of one conversation item; render and scroll extent share it.
fn conversationItemHeight(state: *runtime.AppState, item: *const controller.ActivityItem, conversation: palette.Rect) f32 {
    const s = companionScale();
    const widths = conversationWidths(conversation);
    return switch (item.kind) {
        .user => blk: {
            const wrapped = wrapText(conversationalText(state, item.body.slice()), widths.bubble, .ui, companionScaled(BODY_FONT), USER_MAX_LINES);
            break :blk @as(f32, @floatFromInt(@max(wrapped.count, 1))) * bodyLineHeight() + 20.0 * s + 10.0 * s;
        },
        .assistant, .streaming => blk: {
            const wrapped = wrapText(conversationalText(state, item.body.slice()), widths.text, .ui, companionScaled(BODY_FONT), ASSISTANT_MAX_LINES);
            if (wrapped.count == 0) break :blk 0.0;
            break :blk @as(f32, @floatFromInt(wrapped.count)) * bodyLineHeight() + 14.0 * s;
        },
        .tool, .process => 24.0 * s,
        .system => if (std.mem.trim(u8, item.body.slice(), " \t\r\n").len == 0) 0.0 else 22.0 * s,
    };
}

fn renderConversation(state: *runtime.AppState, geometry: Geometry) void {
    const conversation = geometry.conversation;
    if (conversation.w <= 0.0 or conversation.h <= 0.0) return;
    const companion = &state.companion_controller;
    const frame = &companion.presentation;
    if (frame.activity_count == 0) return renderEmptyState(state, geometry);
    const s = companionScale();
    const pad = 10.0 * s;
    var total: f32 = pad * 2.0;
    for (frame.activity[0..frame.activity_count]) |*item| total += conversationItemHeight(state, item, conversation);
    companion.updateConversationExtent(@max(total - conversation.h, 0.0));
    var y = conversation.y + pad - companion.conversation_scroll_y;
    for (frame.activity[0..frame.activity_count]) |*item| {
        const height = conversationItemHeight(state, item, conversation);
        if (height > 0.0 and y + height >= conversation.y and y <= conversation.y + conversation.h) {
            renderConversationItem(state, item, conversation, y);
        }
        y += height;
    }
    if (companion.conversation_scroll_y > 1.0) renderFade(state, conversation, true);
    if (companion.conversation_max_scroll - companion.conversation_scroll_y > 1.0) renderFade(state, conversation, false);
}

fn renderFade(state: *runtime.AppState, conversation: palette.Rect, top: bool) void {
    const s = companionScale();
    const h = 14.0 * s;
    const steps = 4;
    for (0..steps) |step| {
        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
        const strip_h = h / @as(f32, @floatFromInt(steps));
        const y = if (top) conversation.y + strip_h * @as(f32, @floatFromInt(step)) else conversation.y + conversation.h - strip_h * @as(f32, @floatFromInt(step + 1));
        const alpha: u8 = @intFromFloat((1.0 - t) * 200.0);
        queueRect(state, .{ .x = conversation.x + 2.0 * s, .y = y, .w = @max(conversation.w - 4.0 * s, 0.0), .h = strip_h }, color(theme.withAlpha(surface(), alpha)));
    }
}

fn renderConversationItem(state: *runtime.AppState, item: *const controller.ActivityItem, conversation: palette.Rect, y: f32) void {
    const s = companionScale();
    const chrome = theme.companionChrome();
    const widths = conversationWidths(conversation);
    const x = conversation.x + CONTENT_INSET * s;
    const line_h = bodyLineHeight();
    const font = companionScaled(BODY_FONT);
    switch (item.kind) {
        .user => {
            const wrapped = wrapText(conversationalText(state, item.body.slice()), widths.bubble, .ui, font, USER_MAX_LINES);
            var widest: f32 = 0.0;
            for (wrapped.lines[0..wrapped.count]) |line| widest = @max(widest, text_measure.textWidth(.ui, font, line));
            const bubble_w = @min(widest + 22.0 * s, widths.bubble + 20.0 * s);
            const bubble_h = @as(f32, @floatFromInt(@max(wrapped.count, 1))) * line_h + 18.0 * s;
            const bubble: palette.Rect = .{ .x = x + widths.text - bubble_w, .y = y + 4.0 * s, .w = bubble_w, .h = bubble_h };
            queuePanelClipped(state, bubble, color(opaqueOver(surface(), chrome.ready_fill)), color(opaqueOver(surface(), theme.withAlpha(chrome.accent, 60))), 12.0 * s, 1.0 * s, conversation);
            for (wrapped.lines[0..wrapped.count], 0..) |line, index| {
                queueText(state, .{ .x = bubble.x + 11.0 * s, .y = bubble.y + 9.0 * s + @as(f32, @floatFromInt(index)) * line_h, .w = widths.bubble + 4.0 * s, .h = line_h }, line, color(chrome.text), font, conversation);
            }
        },
        .assistant, .streaming => {
            const wrapped = wrapText(conversationalText(state, item.body.slice()), widths.text, .ui, font, ASSISTANT_MAX_LINES);
            for (wrapped.lines[0..wrapped.count], 0..) |line, index| {
                const last = index + 1 == wrapped.count;
                const shown = if (last and item.kind == .streaming) framePrint(state, "{s} ▍", .{line}) else if (last and wrapped.truncated) framePrint(state, "{s} …", .{line}) else line;
                queueText(state, .{ .x = x, .y = y + 6.0 * s + @as(f32, @floatFromInt(index)) * line_h, .w = widths.text + 12.0 * s, .h = line_h }, shown, color(chrome.text), font, conversation);
            }
        },
        .tool, .process => {
            const status = item.status orelse .completed;
            const glyph: []const u8 = switch (status) {
                .pending, .in_progress => "●",
                .completed => "✓",
                .failed => "✕",
                .cancelled => "–",
            };
            const glyph_color = switch (status) {
                .pending, .in_progress => chrome.accent,
                .completed => chrome.text_subtle,
                .failed => chrome.danger,
                .cancelled => chrome.text_subtle,
            };
            queueText(state, .{ .x = x + 2.0 * s, .y = y + 4.0 * s, .w = 14.0 * s, .h = 16.0 * s }, glyph, color(glyph_color), 10.5 * s, conversation);
            const label = if (item.body.slice().len > 0)
                framePrint(state, "{s} · {s}", .{ item.author.slice(), singleLineText(state, item.body.slice()) })
            else
                item.author.slice();
            const text_w = @max(widths.text - 20.0 * s, 0.0);
            queueMonoText(state, .{ .x = x + 18.0 * s, .y = y + 4.0 * s, .w = text_w, .h = 16.0 * s }, truncatedText(state, .mono, 10.5 * s, text_w, label), color(chrome.text_subtle), 10.5 * s, conversation);
        },
        .system => {
            const text_w = widths.text;
            queueText(state, .{ .x = x, .y = y + 3.0 * s, .w = text_w, .h = 16.0 * s }, truncatedText(state, .ui, 11.0 * s, text_w, singleLineText(state, item.body.slice())), color(chrome.text_subtle), 11.0 * s, conversation);
        },
    }
}

const EmptyStateLayout = struct {
    avatar: palette.Rect,
    title_y: f32,
    tagline_y: f32,
    pitch_y: f32,
    suggestions: [3]palette.Rect,
};

fn emptyStateLayout(conversation: palette.Rect) EmptyStateLayout {
    const s = companionScale();
    const content_w = @max(conversation.w - CONTENT_INSET * 2.0 * s, 0.0);
    const block_h = 74.0 * s + 22.0 * s + 18.0 * s + 40.0 * s + 3.0 * (SUGGESTION_HEIGHT + 8.0) * s;
    const top = conversation.y + @max((conversation.h - block_h) * 0.4, 12.0 * s);
    const avatar_w = 70.0 * s;
    const avatar: palette.Rect = .{ .x = conversation.x + (conversation.w - avatar_w) * 0.5, .y = top, .w = avatar_w, .h = 72.0 * s };
    const title_y = avatar.y + avatar.h + 10.0 * s;
    const tagline_y = title_y + 24.0 * s;
    const pitch_y = tagline_y + 20.0 * s;
    var suggestions: [3]palette.Rect = undefined;
    var y = pitch_y + 44.0 * s;
    for (&suggestions) |*rect| {
        rect.* = .{ .x = conversation.x + CONTENT_INSET * s, .y = y, .w = content_w, .h = SUGGESTION_HEIGHT * s };
        y += (SUGGESTION_HEIGHT + 8.0) * s;
    }
    return .{ .avatar = avatar, .title_y = title_y, .tagline_y = tagline_y, .pitch_y = pitch_y, .suggestions = suggestions };
}

// Empty conversation: the character introduces itself and offers real
// orchestration prompts.
fn renderEmptyState(state: *runtime.AppState, geometry: Geometry) void {
    const conversation = geometry.conversation;
    const s = companionScale();
    const chrome = theme.companionChrome();
    state.companion_controller.updateConversationExtent(0.0);
    const layout = emptyStateLayout(conversation);
    const character = activeCompanionCharacter(state);
    if (rectInside(layout.avatar, conversation)) {
        renderCompanionCharacter(state, characterInSlot(layout.avatar, character), state.companion_controller.visualState(), character, .full);
    }
    const name = state.companion_controller.identity.name.slice();
    const title = framePrint(state, "Hi, I'm {s}.", .{name});
    queueCenteredText(state, .{ .x = conversation.x, .y = layout.title_y, .w = conversation.w, .h = 22.0 * s }, title, color(chrome.text), 16.0 * s, .ui_bold, conversation);
    queueCenteredText(state, .{ .x = conversation.x, .y = layout.tagline_y, .w = conversation.w, .h = 17.0 * s }, companion_roster.characterTagline(character), color(chrome.identity_fg), 11.0 * s, .ui, conversation);
    const pitch_w = @max(conversation.w - CONTENT_INSET * 4.0 * s, 0.0);
    const pitch = wrapText("I run Verde for you: I delegate work to chats in any workspace, watch them, and tell you when something needs you.", pitch_w, .ui, 11.5 * s, 3);
    for (pitch.lines[0..pitch.count], 0..) |line, index| {
        queueCenteredText(state, .{ .x = conversation.x, .y = layout.pitch_y + @as(f32, @floatFromInt(index)) * 16.0 * s, .w = conversation.w, .h = 16.0 * s }, line, color(chrome.text_subtle), 11.5 * s, .ui, conversation);
    }
    for (layout.suggestions, 0..) |rect, index| {
        if (!rectInside(rect, conversation)) continue;
        queuePanel(state, rect, color(chrome.surface_deep), color(hairline()), 10.0 * s, 1.0 * s);
        const text_w = @max(rect.w - 36.0 * s, 0.0);
        queueText(state, .{ .x = rect.x + 12.0 * s, .y = rect.y + (rect.h - 17.0 * s) * 0.5, .w = text_w, .h = 17.0 * s }, truncatedText(state, .ui, 11.5 * s, text_w, runtime.AppState.COMPANION_SUGGESTIONS[index]), color(chrome.text), 11.5 * s, rect);
        queueText(state, .{ .x = rect.x + rect.w - 22.0 * s, .y = rect.y + (rect.h - 17.0 * s) * 0.5, .w = 14.0 * s, .h = 17.0 * s }, "↗", color(chrome.accent), 11.5 * s, rect);
    }
}

// ---- menus ------------------------------------------------------------------

const CompanionMenuLayout = struct {
    menu: palette.Rect,
    rows: [companion_roster.MAX_COMPANIONS]palette.Rect,
    row_count: usize,
    rename: palette.Rect,
    orders: palette.Rect,
    characters: [3]palette.Rect,
    new_companion: palette.Rect,
    remove: palette.Rect,
    new_conversation: palette.Rect,
    conversations: [controller.MAX_CONVERSATION_ROWS]palette.Rect,
    conversation_count: usize,
};

fn companionMenuLayout(state: *runtime.AppState, geometry: Geometry) CompanionMenuLayout {
    const s = companionScale();
    const companion = &state.companion_controller;
    const menu_w = @min(300.0 * s, geometry.panel.w - 24.0 * s);
    const row_count = companion.roster_row_count;
    var layout: CompanionMenuLayout = undefined;
    layout.row_count = row_count;
    const x = geometry.panel.x + 12.0 * s;
    var y = geometry.header.y + geometry.header.h - 4.0 * s + 8.0 * s;
    for (0..row_count) |index| {
        layout.rows[index] = .{ .x = x + 6.0 * s, .y = y, .w = menu_w - 12.0 * s, .h = MENU_ROW_HEIGHT * s };
        y += MENU_ROW_HEIGHT * s;
    }
    y += 8.0 * s;
    layout.rename = .{ .x = x + 6.0 * s, .y = y, .w = menu_w - 12.0 * s, .h = MENU_ACTION_HEIGHT * s };
    y += MENU_ACTION_HEIGHT * s;
    layout.orders = .{ .x = x + 6.0 * s, .y = y, .w = menu_w - 12.0 * s, .h = MENU_ROW_HEIGHT * s };
    y += MENU_ROW_HEIGHT * s + 4.0 * s;
    const chip_w = (menu_w - 12.0 * s - 12.0 * s) / 3.0;
    for (&layout.characters, 0..) |*rect, index| {
        rect.* = .{ .x = x + 6.0 * s + @as(f32, @floatFromInt(index)) * (chip_w + 6.0 * s), .y = y, .w = chip_w, .h = 52.0 * s };
    }
    y += 52.0 * s + 8.0 * s;
    layout.new_companion = .{ .x = x + 6.0 * s, .y = y, .w = menu_w - 12.0 * s, .h = MENU_ACTION_HEIGHT * s };
    y += MENU_ACTION_HEIGHT * s;
    if (companion.identity.count > 1) {
        layout.remove = .{ .x = x + 6.0 * s, .y = y, .w = menu_w - 12.0 * s, .h = MENU_ACTION_HEIGHT * s };
        y += MENU_ACTION_HEIGHT * s;
    } else {
        layout.remove = .{};
    }
    y += 6.0 * s;
    layout.new_conversation = .{ .x = x + 6.0 * s, .y = y, .w = menu_w - 12.0 * s, .h = MENU_ACTION_HEIGHT * s };
    y += MENU_ACTION_HEIGHT * s;
    layout.conversation_count = companion.conversation_row_count;
    for (0..layout.conversation_count) |index| {
        layout.conversations[index] = .{ .x = x + 6.0 * s, .y = y, .w = menu_w - 12.0 * s, .h = MENU_ROW_HEIGHT * s };
        y += MENU_ROW_HEIGHT * s;
    }
    const menu_top = geometry.header.y + geometry.header.h - 4.0 * s;
    layout.menu = .{ .x = x, .y = menu_top, .w = menu_w, .h = y + 6.0 * s - menu_top };
    return layout;
}

fn registerCompanionMenuHits(state: *runtime.AppState, geometry: Geometry) void {
    const companion = &state.companion_controller;
    const layout = companionMenuLayout(state, geometry);
    companion.addHit(geometry.window, .menu_dismiss);
    companion.addHit(layout.menu, .body);
    for (layout.rows[0..layout.row_count], 0..) |rect, index| companion.addIndexedHit(rect, .menu_select_companion, index);
    companion.addHit(layout.rename, .menu_rename);
    companion.addHit(layout.orders, .menu_orders);
    for (layout.characters, 0..) |rect, index| companion.addIndexedHit(rect, .menu_character, index);
    companion.addHit(layout.new_companion, .menu_new_companion);
    companion.addHit(layout.remove, .menu_remove);
    companion.addHit(layout.new_conversation, .menu_new_conversation);
    for (layout.conversations[0..layout.conversation_count], 0..) |rect, index| companion.addIndexedHit(rect, .menu_resume_conversation, index);
}

fn renderMenuSurface(state: *runtime.AppState, rect: palette.Rect) void {
    const s = companionScale();
    const chrome = theme.companionChrome();
    queueRoundedRect(state, offsetRect(rect, 0.0, 6.0 * s), color(theme.scrim(0.22)), 12.0 * s);
    queuePanel(state, rect, color(chrome.surface_deep), color(chrome.menu_border), 12.0 * s, 1.0 * s);
}

fn renderMenuAction(state: *runtime.AppState, rect: palette.Rect, label: []const u8, danger: bool) void {
    if (rect.w <= 0.0) return;
    const s = companionScale();
    const chrome = theme.companionChrome();
    queueText(state, .{ .x = rect.x + 10.0 * s, .y = rect.y + (rect.h - 17.0 * s) * 0.5, .w = rect.w - 20.0 * s, .h = 17.0 * s }, label, color(if (danger) chrome.danger else chrome.text), 12.0 * s, rect);
}

// Companion picker: switch, rename, pick a character, add, or remove.
fn renderCompanionMenu(state: *runtime.AppState, geometry: Geometry) void {
    const s = companionScale();
    const chrome = theme.companionChrome();
    const companion = &state.companion_controller;
    const layout = companionMenuLayout(state, geometry);
    renderMenuSurface(state, layout.menu);
    for (companion.roster_rows[0..layout.row_count], 0..) |*row, index| {
        const rect = layout.rows[index];
        if (row.active) queueRoundedRect(state, rect, color(opaqueOver(chrome.surface_deep, chrome.menu_selected)), 8.0 * s);
        const slot: palette.Rect = .{ .x = rect.x + 6.0 * s, .y = rect.y + 4.0 * s, .w = 30.0 * s, .h = rect.h - 8.0 * s };
        renderCompanionCharacter(state, characterInSlot(slot, row.character), .{ .pose = .idle, .show_approval = false, .show_failure = false }, row.character, .compact);
        const text_x = rect.x + 46.0 * s;
        const text_w = @max(rect.w - 46.0 * s - 28.0 * s, 0.0);
        queueBoldText(state, .{ .x = text_x, .y = rect.y + 4.0 * s, .w = text_w, .h = 17.0 * s }, truncatedText(state, .ui_bold, 12.5 * s, text_w, row.name.slice()), color(chrome.text), 12.5 * s, rect);
        queueText(state, .{ .x = text_x, .y = rect.y + 21.0 * s, .w = text_w, .h = 15.0 * s }, truncatedText(state, .ui, 10.5 * s, text_w, companion_roster.characterDisplayName(row.character)), color(chrome.text_subtle), 10.5 * s, rect);
        if (row.active) queueText(state, .{ .x = rect.x + rect.w - 22.0 * s, .y = rect.y + 11.0 * s, .w = 14.0 * s, .h = 17.0 * s }, "✓", color(chrome.accent), 12.0 * s, rect);
    }
    const divider_y = layout.rename.y - 5.0 * s;
    queueRect(state, .{ .x = layout.menu.x + 10.0 * s, .y = divider_y, .w = layout.menu.w - 20.0 * s, .h = 1.0 * s }, color(hairline()));
    renderMenuAction(state, layout.rename, framePrint(state, "Rename {s}…", .{companion.identity.name.slice()}), false);
    {
        const rect = layout.orders;
        const text_w = @max(rect.w - 20.0 * s, 0.0);
        queueText(state, .{ .x = rect.x + 10.0 * s, .y = rect.y + 4.0 * s, .w = text_w, .h = 17.0 * s }, "Standing orders…", color(chrome.text), 12.0 * s, rect);
        const orders = companion.identity.orders.slice();
        queueText(state, .{ .x = rect.x + 10.0 * s, .y = rect.y + 21.0 * s, .w = text_w, .h = 15.0 * s }, truncatedText(state, .ui, 10.5 * s, text_w, if (orders.len > 0) orders else "None yet. Rules it follows on every turn."), color(chrome.text_subtle), 10.5 * s, rect);
    }
    for (layout.characters, 0..) |rect, index| {
        const character = characterAt(index).?;
        const selected = character == companion.identity.character;
        queuePanel(state, rect, color(if (selected) opaqueOver(chrome.surface_deep, chrome.menu_selected) else chrome.surface_deep), color(if (selected) chrome.accent else hairline()), 9.0 * s, 1.0 * s);
        const slot: palette.Rect = .{ .x = rect.x + 4.0 * s, .y = rect.y + 4.0 * s, .w = rect.w - 8.0 * s, .h = 28.0 * s };
        renderCompanionCharacter(state, characterInSlot(slot, character), .{ .pose = .idle, .show_approval = false, .show_failure = false }, character, .compact);
        queueCenteredText(state, .{ .x = rect.x, .y = rect.y + 33.0 * s, .w = rect.w, .h = 16.0 * s }, companion_roster.characterDisplayName(character), color(if (selected) chrome.text else chrome.text_subtle), 10.5 * s, .ui_bold, rect);
    }
    renderMenuAction(state, layout.new_companion, "+ New companion", false);
    renderMenuAction(state, layout.remove, framePrint(state, "Remove {s}", .{companion.identity.name.slice()}), true);
    queueRect(state, .{ .x = layout.menu.x + 10.0 * s, .y = layout.new_conversation.y - 4.0 * s, .w = layout.menu.w - 20.0 * s, .h = 1.0 * s }, color(hairline()));
    renderMenuAction(state, layout.new_conversation, "✎ New conversation", false);
    for (companion.conversation_rows[0..layout.conversation_count], 0..) |*row, index| {
        const rect = layout.conversations[index];
        const text_w = @max(rect.w - 20.0 * s, 0.0);
        queueText(state, .{ .x = rect.x + 10.0 * s, .y = rect.y + 4.0 * s, .w = text_w, .h = 17.0 * s }, truncatedText(state, .ui, 12.0 * s, text_w, row.title.slice()), color(chrome.text_muted), 12.0 * s, rect);
        queueText(state, .{ .x = rect.x + 10.0 * s, .y = rect.y + 21.0 * s, .w = text_w, .h = 15.0 * s }, truncatedText(state, .ui, 10.5 * s, text_w, row.detail.slice()), color(chrome.text_subtle), 10.5 * s, rect);
    }
}

const BrainMenuLayout = struct {
    menu: palette.Rect,
    providers: [controller.MAX_BRAIN_PROVIDERS]palette.Rect,
    provider_count: usize,
    list: palette.Rect,
    /// "Reasoning" caption and level chips; empty when the companion's
    /// current model has no levels or another provider tab is browsed.
    reasoning_title: palette.Rect,
    reasoning: [runtime.AppState.MAX_COMPANION_REASONING_LEVELS]palette.Rect,
    reasoning_count: usize,
};

fn brainMenuLayout(state: *runtime.AppState, geometry: Geometry) BrainMenuLayout {
    const s = companionScale();
    const companion = &state.companion_controller;
    var layout: BrainMenuLayout = undefined;
    const x = geometry.panel.x + 12.0 * s;
    const menu_w = geometry.panel.w - 24.0 * s;
    const menu_top = geometry.header.y + geometry.header.h - 4.0 * s;
    var chip_x = x + 10.0 * s;
    var chip_y = menu_top + 46.0 * s;
    layout.provider_count = companion.brain_provider_count;
    for (companion.brain_providers[0..companion.brain_provider_count], 0..) |*provider, index| {
        const chip_w = text_measure.textWidth(.ui_bold, 11.0 * s, provider.label.slice()) + 22.0 * s;
        if (chip_x + chip_w > x + menu_w - 10.0 * s and chip_x > x + 10.0 * s) {
            chip_x = x + 10.0 * s;
            chip_y += 30.0 * s;
        }
        layout.providers[index] = .{ .x = chip_x, .y = chip_y, .w = chip_w, .h = 24.0 * s };
        chip_x += chip_w + 6.0 * s;
    }
    const list_top = chip_y + 34.0 * s;

    // Reasoning chips sit under the model list, for the model in use.
    var levels: [runtime.AppState.MAX_COMPANION_REASONING_LEVELS]runtime.AppState.CompanionReasoningLevel = undefined;
    layout.reasoning_count = if (state.companionBrowsingCurrentProvider()) state.companionReasoningLevels(&levels) else 0;
    var reasoning_h: f32 = 0.0;
    if (layout.reasoning_count > 0) {
        var rx = x + 10.0 * s;
        var rows: f32 = 1.0;
        for (levels[0..layout.reasoning_count], 0..) |level, index| {
            const w = text_measure.textWidth(.ui_bold, 11.0 * s, level.label) + 20.0 * s;
            if (rx + w > x + menu_w - 10.0 * s and rx > x + 10.0 * s) {
                rx = x + 10.0 * s;
                rows += 1.0;
            }
            // y is relative here; shifted below once the list height is known.
            layout.reasoning[index] = .{ .x = rx, .y = (rows - 1.0) * 30.0 * s, .w = w, .h = 24.0 * s };
            rx += w + 6.0 * s;
        }
        reasoning_h = 10.0 * s + 20.0 * s + rows * 30.0 * s;
    }

    const available = @max(geometry.footer.y - list_top - 16.0 * s - reasoning_h, 60.0 * s);
    const options = state.companionBrainModelOptions();
    const list_h = @min(@as(f32, @floatFromInt(@max(options.len, 1))) * BRAIN_ROW_HEIGHT * s, available);
    layout.list = .{ .x = x + 6.0 * s, .y = list_top, .w = menu_w - 12.0 * s, .h = list_h };
    const reasoning_top = list_top + list_h + 10.0 * s;
    layout.reasoning_title = if (layout.reasoning_count > 0) .{ .x = x + 14.0 * s, .y = reasoning_top, .w = menu_w - 28.0 * s, .h = 16.0 * s } else .{ .x = x, .y = reasoning_top };
    for (layout.reasoning[0..layout.reasoning_count]) |*chip| chip.y += reasoning_top + 20.0 * s;
    layout.menu = .{ .x = x, .y = menu_top, .w = menu_w, .h = list_top + list_h + reasoning_h + 8.0 * s - menu_top };
    companion.brain_max_scroll = @max(@as(f32, @floatFromInt(options.len)) * BRAIN_ROW_HEIGHT * s - list_h, 0.0);
    companion.brain_scroll_y = std.math.clamp(companion.brain_scroll_y, 0.0, companion.brain_max_scroll);
    return layout;
}

fn brainRowRect(layout: BrainMenuLayout, index: usize, scroll_y: f32) palette.Rect {
    const s = companionScale();
    return .{ .x = layout.list.x, .y = layout.list.y + @as(f32, @floatFromInt(index)) * BRAIN_ROW_HEIGHT * s - scroll_y, .w = layout.list.w, .h = BRAIN_ROW_HEIGHT * s };
}

fn registerBrainMenuHits(state: *runtime.AppState, geometry: Geometry) void {
    const companion = &state.companion_controller;
    const layout = brainMenuLayout(state, geometry);
    companion.addHit(geometry.window, .menu_dismiss);
    companion.addHit(layout.menu, .body);
    for (layout.providers[0..layout.provider_count], 0..) |rect, index| companion.addIndexedHit(rect, .brain_provider, index);
    const options = state.companionBrainModelOptions();
    for (0..options.len) |index| {
        const row = brainRowRect(layout, index, companion.brain_scroll_y);
        const visible = intersectRects(row, layout.list) orelse continue;
        companion.addIndexedHit(visible, .brain_model, index);
    }
    for (layout.reasoning[0..layout.reasoning_count], 0..) |rect, index| companion.addIndexedHit(rect, .brain_reasoning, index);
}

// Brain picker: any connected provider and model can drive the companion.
fn renderBrainMenu(state: *runtime.AppState, geometry: Geometry) void {
    const s = companionScale();
    const chrome = theme.companionChrome();
    const companion = &state.companion_controller;
    const layout = brainMenuLayout(state, geometry);
    renderMenuSurface(state, layout.menu);
    const title = framePrint(state, "{s}'s brain", .{companion.identity.name.slice()});
    queueBoldText(state, .{ .x = layout.menu.x + 14.0 * s, .y = layout.menu.y + 10.0 * s, .w = layout.menu.w - 28.0 * s, .h = 17.0 * s }, title, color(chrome.text), 12.5 * s, layout.menu);
    queueText(state, .{ .x = layout.menu.x + 14.0 * s, .y = layout.menu.y + 27.0 * s, .w = layout.menu.w - 28.0 * s, .h = 15.0 * s }, "Any connected model works. Switching provider keeps the conversation.", color(chrome.text_subtle), 10.5 * s, layout.menu);
    if (layout.provider_count == 0) {
        queueText(state, .{ .x = layout.menu.x + 14.0 * s, .y = layout.menu.y + 50.0 * s, .w = layout.menu.w - 28.0 * s, .h = 16.0 * s }, "No providers are connected yet. Sign in from Settings → Providers.", color(chrome.text_muted), 11.0 * s, layout.menu);
        return;
    }
    for (layout.providers[0..layout.provider_count], 0..) |rect, index| {
        const provider = &companion.brain_providers[index];
        const browsing = index == companion.brain_provider_index;
        queuePanel(state, rect, color(if (browsing) opaqueOver(chrome.surface_deep, chrome.menu_selected) else chrome.surface_deep), color(if (browsing) chrome.accent else hairline()), 12.0 * s, 1.0 * s);
        queueCenteredText(state, rect, provider.label.slice(), color(if (browsing) chrome.text else chrome.text_muted), 11.0 * s, .ui_bold, rect);
        if (provider.selected) queueRoundedRect(state, .{ .x = rect.x + rect.w - 7.0 * s, .y = rect.y + 2.0 * s, .w = 5.0 * s, .h = 5.0 * s }, color(chrome.accent), 2.5 * s);
    }
    const options = state.companionBrainModelOptions();
    for (options, 0..) |option, index| {
        const row = brainRowRect(layout, index, companion.brain_scroll_y);
        if (row.y + row.h < layout.list.y or row.y > layout.list.y + layout.list.h) continue;
        const selected = state.companionBrainModelSelected(index);
        if (selected) queueRoundedRectClipped(state, row, color(opaqueOver(chrome.surface_deep, chrome.menu_selected)), 7.0 * s, layout.list);
        const text_w = @max(row.w - 40.0 * s, 0.0);
        queueText(state, .{ .x = row.x + 10.0 * s, .y = row.y + (row.h - 17.0 * s) * 0.5, .w = text_w, .h = 17.0 * s }, truncatedText(state, .ui, 12.0 * s, text_w, option.label), color(chrome.text), 12.0 * s, layout.list);
        if (selected) queueText(state, .{ .x = row.x + row.w - 24.0 * s, .y = row.y + (row.h - 17.0 * s) * 0.5, .w = 14.0 * s, .h = 17.0 * s }, "✓", color(chrome.accent), 12.0 * s, layout.list);
    }
    if (layout.reasoning_count > 0) {
        queueBoldText(state, layout.reasoning_title, "REASONING", color(chrome.text_subtle), 10.0 * s, layout.menu);
        var levels: [runtime.AppState.MAX_COMPANION_REASONING_LEVELS]runtime.AppState.CompanionReasoningLevel = undefined;
        const count = @min(state.companionReasoningLevels(&levels), layout.reasoning_count);
        const selected_index = state.companionReasoningSelectedIndex();
        for (levels[0..count], layout.reasoning[0..count], 0..) |level, chip, index| {
            const selected = selected_index != null and selected_index.? == index;
            const fill = if (selected) chrome.accent else chrome.surface_deep;
            queuePanel(state, chip, color(fill), color(if (selected) chrome.accent else chrome.border), chip.h * 0.5, 1.0 * s);
            const label_w = text_measure.textWidth(.ui_bold, 11.0 * s, level.label);
            queueBoldText(state, .{ .x = chip.x + (chip.w - label_w) * 0.5, .y = chip.y + (chip.h - 15.0 * s) * 0.5, .w = label_w + 1.0, .h = 15.0 * s }, level.label, color(if (selected) surface() else chrome.text), 11.0 * s, layout.menu);
        }
    }
}

// ---- shared character helpers ------------------------------------------------

/// Fits a character into a slot, preserving its art aspect and bottom-centering it.
fn characterInSlot(slot: palette.Rect, character: app_config.CompanionCharacter) palette.Rect {
    const size = fullCharacterSize(character);
    const scale = @min(slot.w / size.w, slot.h / size.h);
    if (scale <= 0.0) return .{ .x = slot.x, .y = slot.y };
    const w = size.w * scale;
    const h = size.h * scale;
    return .{ .x = slot.x + (slot.w - w) * 0.5, .y = slot.y + (slot.h - h), .w = w, .h = h };
}

fn rectInside(inner: palette.Rect, outer: palette.Rect) bool {
    return inner.w > 0.0 and inner.h > 0.0 and inner.x >= outer.x and inner.y >= outer.y and
        inner.x + inner.w <= outer.x + outer.w + 0.5 and inner.y + inner.h <= outer.y + outer.h + 0.5;
}

fn framePrint(state: *runtime.AppState, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), format, args) catch "";
}

const CharacterTheme = struct {
    background: [4]f32,
    text: [4]f32,
    text_subtle: [4]f32,
    accent: [4]f32,
    border: [4]f32,
    panel_muted: [4]f32,
    warning: [4]f32,
    danger: [4]f32,
};

const CharacterPresentation = enum { full, compact };

fn activeCompanionCharacter(state: *const runtime.AppState) app_config.CompanionCharacter {
    return state.companion_controller.identity.character;
}

fn fullCharacterSize(character: app_config.CompanionCharacter) struct { w: f32, h: f32 } {
    return switch (character) {
        .sprout => .{ .w = 46.0, .h = 48.0 },
        .moss => .{ .w = 46.0, .h = 46.0 },
        .vireo => .{ .w = 46.0, .h = 42.0 },
    };
}

fn compactCharacterSize(character: app_config.CompanionCharacter) struct { w: f32, h: f32 } {
    return switch (character) {
        .sprout => .{ .w = 29.0, .h = 31.0 },
        .moss => .{ .w = 29.0, .h = 30.0 },
        .vireo => .{ .w = 29.0, .h = 27.0 },
    };
}

fn fullCharacterRect(slot: palette.Rect, character: app_config.CompanionCharacter, scale: f32) palette.Rect {
    const size = fullCharacterSize(character);
    const w = @min(size.w * scale, slot.w);
    const h = @min(size.h * scale, slot.h);
    return .{
        .x = slot.x + @max((slot.w - w) * 0.5, 0.0),
        .y = slot.y + @max(slot.h - h, 0.0),
        .w = w,
        .h = h,
    };
}

fn compactCharacterRect(header: palette.Rect, character: app_config.CompanionCharacter, scale: f32) palette.Rect {
    const size = compactCharacterSize(character);
    return .{
        .x = header.x + 12.0 * scale,
        .y = header.y + 6.5 * scale,
        .w = size.w * scale,
        .h = size.h * scale,
    };
}

fn renderCompanionCharacter(
    state: *runtime.AppState,
    rect: palette.Rect,
    visual: controller.VisualState,
    character: app_config.CompanionCharacter,
    presentation: CharacterPresentation,
) void {
    _ = presentation;
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    switch (character) {
        .sprout => renderSprout(state, rect, visual),
        .moss => renderMoss(state, rect, visual),
        .vireo => renderVireo(state, rect, visual),
    }
}

const SproutPalette = struct {
    pole_light: [4]f32,
    pole_dark: [4]f32,
    head_top: [4]f32,
    head_bottom: [4]f32,
    torso_top: [4]f32,
    torso_bottom: [4]f32,
    feet: [4]f32,
    highlight: [4]f32,
    head_depth: [4]f32,
    torso_depth: [4]f32,
    outline: [4]f32,
    iris_top: [4]f32,
    iris_bottom: [4]f32,
    eye_ring: [4]f32,
    catchlight_primary: [4]f32,
    catchlight_secondary: [4]f32,
    paused_lid: [4]f32,
    stem: [4]f32,
    blade_start: [4]f32,
    blade_end: [4]f32,
    buds: [4]f32,
    mouth: [4]f32,
    char_surface: [4]f32,
    warning: [4]f32,
    warning_foreground: [4]f32,
    danger: [4]f32,
};

fn activeCharacterTheme() CharacterTheme {
    const active = theme.current_colors;
    return .{
        .background = active.background,
        .text = active.text,
        .text_subtle = active.text_subtle,
        .accent = active.accent,
        .border = active.border,
        .panel_muted = active.panel_muted,
        .warning = active.warning,
        .danger = active.diff_remove,
    };
}

fn deriveSproutPalette(active: CharacterTheme) SproutPalette {
    const text_is_lighter = characterLuma(active.text) >= characterLuma(active.background);
    const pole_light = if (text_is_lighter) active.text else active.background;
    const pole_dark = if (text_is_lighter) active.background else active.text;
    const accent_hi = theme.mix(active.accent, pole_light, 0.28);
    const well = theme.raiseAgainst(active.background, 0.02, active.background, active.text);
    const char_surface = theme.raiseAgainst(active.background, 0.035, active.background, active.text);

    var head_top = theme.mix(active.text, accent_hi, 0.45);
    var head_bottom = theme.mix(active.text, active.accent, 0.38);
    var iris_top = theme.mix(active.text, active.danger, 0.76);
    var iris_bottom = theme.mix(well, active.danger, 0.66);
    if (lumaDistance(iris_top, head_top) < 0.18) {
        head_top = theme.mix(head_top, active.text, 0.15);
        head_bottom = theme.mix(head_bottom, active.text, 0.15);
        if (lumaDistance(iris_top, head_top) < 0.18) {
            iris_top = active.danger;
            iris_bottom = active.danger;
        }
    }

    var outline = theme.mix(active.border, active.accent, 0.55);
    if (lumaDistance(outline, char_surface) < 0.10) {
        outline = active.border;
        if (lumaDistance(outline, char_surface) < 0.10) outline = active.text_subtle;
    }

    var stem = theme.mix(char_surface, active.accent, 0.85);
    var blade_start = active.accent;
    var blade_end = theme.mix(active.accent, accent_hi, 0.75);
    const torso_top = theme.mix(active.text, accent_hi, 0.38);
    const torso_bottom = theme.mix(active.text, active.accent, 0.34);
    const body_fill = theme.mix(torso_top, torso_bottom, 0.5);
    if (lumaDistance(theme.mix(blade_start, blade_end, 0.5), body_fill) < 0.06) {
        const growth_fallback = theme.mix(active.accent, pole_dark, 0.15);
        stem = growth_fallback;
        blade_start = growth_fallback;
        blade_end = growth_fallback;
    }

    return .{
        .pole_light = pole_light,
        .pole_dark = pole_dark,
        .head_top = head_top,
        .head_bottom = head_bottom,
        .torso_top = torso_top,
        .torso_bottom = torso_bottom,
        .feet = theme.mix(active.text, active.accent, 0.30),
        .highlight = theme.withAlpha(pole_light, 64),
        .head_depth = theme.withAlpha(pole_dark, 36),
        .torso_depth = theme.withAlpha(pole_dark, 31),
        .outline = outline,
        .iris_top = iris_top,
        .iris_bottom = iris_bottom,
        .eye_ring = theme.mix(well, active.danger, 0.40),
        .catchlight_primary = theme.mix(active.danger, pole_light, 0.90),
        .catchlight_secondary = theme.withAlpha(theme.mix(active.danger, pole_light, 0.70), 204),
        .paused_lid = theme.mix(active.danger, well, 0.70),
        .stem = stem,
        .blade_start = blade_start,
        .blade_end = blade_end,
        .buds = theme.mix(active.panel_muted, active.accent, 0.62),
        .mouth = theme.mix(active.accent, well, 0.65),
        .char_surface = char_surface,
        .warning = active.warning,
        .warning_foreground = characterForegroundOn(active.warning, active.text, active.background),
        .danger = active.danger,
    };
}

fn characterLuma(value: [4]f32) f32 {
    return value[0] * 0.2126 + value[1] * 0.7152 + value[2] * 0.0722;
}

fn lumaDistance(left: [4]f32, right: [4]f32) f32 {
    return @abs(characterLuma(left) - characterLuma(right));
}

fn characterForegroundOn(fill: [4]f32, text: [4]f32, background: [4]f32) [4]f32 {
    return if (lumaDistance(fill, text) >= lumaDistance(fill, background)) text else background;
}

// Static Sprout character region; semantic state changes pose and badges only.
fn renderSprout(state: *runtime.AppState, rect: palette.Rect, visual: controller.VisualState) void {
    const s = rect.w / 46.0;
    const sprout = deriveSproutPalette(activeCharacterTheme());
    // Palette rounded rectangles are flat-color primitives, so sample each
    // specified two-stop character gradient at its center without changing
    // the approved geometry or introducing a new renderer contract.
    const head_fill = theme.mix(sprout.head_top, sprout.head_bottom, 0.5);
    const torso_fill = theme.mix(sprout.torso_top, sprout.torso_bottom, 0.5);

    // Signature crown leaf: one short stem and a 29×13 blade sweeping right at −14°.
    queueRoundedRect(state, .{ .x = rect.x + 17.0 * s, .y = rect.y + 7.0 * s, .w = 3.0 * s, .h = 9.0 * s }, color(sprout.stem), 1.5 * s);
    const leaf_color = color(theme.mix(sprout.blade_start, sprout.blade_end, 0.5));
    const droop = if (visual.pose == .paused) 4.0 * s else 0.0;
    const leaf = sproutLeafPoints(rect, droop);
    queueTriangle(state, leaf[0], leaf[1], leaf[2], leaf_color);
    queueTriangle(state, leaf[0], leaf[2], leaf[3], leaf_color);

    // Small torso and two 7×4 perch feet beneath the oversized head.
    const torso: palette.Rect = .{ .x = rect.x + 12.0 * s, .y = rect.y + 35.0 * s, .w = 22.0 * s, .h = 13.0 * s };
    queueRoundedRect(state, offsetRect(torso, 0.0, 3.0 * s), color(sprout.torso_depth), 6.0 * s);
    queueCharacterPanel(state, torso, color(torso_fill), color(sprout.outline), 6.0 * s, 1.0 * s);
    queueRoundedRect(state, .{ .x = torso.x + 0.5 * s, .y = torso.y + torso.h - 2.0 * s, .w = 7.0 * s, .h = 4.0 * s }, color(sprout.feet), 2.0 * s);
    queueRoundedRect(state, .{ .x = torso.x + torso.w - 7.5 * s, .y = torso.y + torso.h - 2.0 * s, .w = 7.0 * s, .h = 4.0 * s }, color(sprout.feet), 2.0 * s);

    // The 36×27 hatchling head has no backing disc.
    const face: palette.Rect = .{ .x = rect.x + 5.0 * s, .y = rect.y + 12.0 * s, .w = 36.0 * s, .h = 27.0 * s };
    queueRoundedRect(state, offsetRect(face, 0.0, 3.0 * s), color(sprout.head_depth), 13.0 * s);
    queueCharacterPanel(state, face, color(head_fill), color(sprout.outline), 13.0 * s, 1.0 * s);
    const head_rim: palette.Rect = .{ .x = face.x + 5.0 * s, .y = face.y + 3.0 * s, .w = face.w - 10.0 * s, .h = 2.0 * s };
    queueRoundedRectClipped(state, head_rim, color(sprout.highlight), 1.0 * s, face);

    const eye_y = face.y + 7.0 * s;
    inline for (.{ face.x + 8.0 * s, face.x + 19.5 * s }) |eye_x| {
        if (visual.pose == .paused) {
            queueRoundedRect(state, .{ .x = eye_x, .y = eye_y + 4.0 * s, .w = 8.5 * s, .h = 2.0 * s }, color(sprout.paused_lid), 1.0 * s);
        } else {
            const eye: palette.Rect = .{ .x = eye_x, .y = eye_y, .w = 8.5 * s, .h = 9.0 * s };
            queueCharacterPanel(state, eye, color(theme.mix(sprout.iris_top, sprout.iris_bottom, 0.5)), color(sprout.eye_ring), 4.25 * s, 1.0 * s);
            const gaze = if (visual.pose == .approval) 2.0 * s else 0.0;
            queueRoundedRect(state, .{ .x = eye.x + 2.5 * s + gaze, .y = eye.y + 3.0 * s, .w = 3.5 * s, .h = 4.0 * s }, color(sprout.eye_ring), 1.7 * s);
            queueRoundedRect(state, .{ .x = eye.x + 1.7 * s, .y = eye.y + 1.4 * s, .w = 3.0 * s, .h = 3.0 * s }, color(sprout.catchlight_primary), 1.5 * s);
            queueRoundedRect(state, .{ .x = eye.x + 5.4 * s, .y = eye.y + 5.9 * s, .w = 1.7 * s, .h = 1.7 * s }, color(sprout.catchlight_secondary), 0.85 * s);
        }
    }

    const bud_color = color(sprout.buds);
    inline for (.{ -5.5, 0.0, 5.5 }) |offset| queueRoundedRect(state, .{ .x = face.x + face.w * 0.5 + offset * s - 1.5 * s, .y = face.y + face.h - 2.0 * s, .w = 3.0 * s, .h = 3.0 * s }, bud_color, 1.5 * s);
    const mouth_color = color(sprout.mouth);
    queueLine(state, .{ .x = face.x + 14.5 * s, .y = face.y + 20.5 * s }, .{ .x = face.x + 18.0 * s, .y = face.y + 22.0 * s }, 1.2 * s, mouth_color);
    queueLine(state, .{ .x = face.x + 18.0 * s, .y = face.y + 22.0 * s }, .{ .x = face.x + 21.5 * s, .y = face.y + 20.5 * s }, 1.2 * s, mouth_color);

    if (visual.show_failure) {
        queueRoundedRect(state, .{ .x = rect.x - 4.0 * s, .y = rect.y - 2.0 * s, .w = 11.0 * s, .h = 11.0 * s }, color(sprout.char_surface), 5.5 * s);
        queueRoundedRect(state, .{ .x = rect.x - 2.0 * s, .y = rect.y, .w = 7.0 * s, .h = 7.0 * s }, color(sprout.danger), 3.5 * s);
    }
}

fn sproutLeafPoints(rect: palette.Rect, droop: f32) [4]palette.draw.Vec2 {
    const s = rect.w / 46.0;
    return .{
        .{ .x = rect.x + 19.0 * s, .y = rect.y + 10.0 * s + droop },
        .{ .x = rect.x + 48.0 * s, .y = rect.y + 3.0 * s + droop },
        .{ .x = rect.x + 45.0 * s, .y = rect.y + 14.0 * s + droop },
        .{ .x = rect.x + 23.0 * s, .y = rect.y + 16.0 * s + droop },
    };
}

const MossPalette = struct {
    body: [4]f32,
    body_depth: [4]f32,
    outline: [4]f32,
    moss_deep: [4]f32,
    moss_mid: [4]f32,
    moss_lit: [4]f32,
    port: [4]f32,
    port_ring: [4]f32,
    pupil: [4]f32,
    seam: [4]f32,
    flower: [4]f32,
    flower_core: [4]f32,
    paused_lid: [4]f32,
    char_surface: [4]f32,
    warning: [4]f32,
    warning_foreground: [4]f32,
    danger: [4]f32,
};

const VireoPalette = struct {
    body_back: [4]f32,
    body_breast: [4]f32,
    wing: [4]f32,
    wingtip: [4]f32,
    tail: [4]f32,
    head: [4]f32,
    crown: [4]f32,
    brow: [4]f32,
    eyeline: [4]f32,
    eye: [4]f32,
    pupil: [4]f32,
    beak: [4]f32,
    leg: [4]f32,
    outline: [4]f32,
    paused_lid: [4]f32,
    char_surface: [4]f32,
    warning: [4]f32,
    warning_foreground: [4]f32,
    danger: [4]f32,
};

fn deriveMossPalette(active: CharacterTheme) MossPalette {
    const text_is_lighter = characterLuma(active.text) >= characterLuma(active.background);
    const pole_light = if (text_is_lighter) active.text else active.background;
    const pole_dark = if (text_is_lighter) active.background else active.text;
    const surface_deep = theme.mix(active.background, pole_dark, 0.18);
    const panel = theme.mix(active.background, active.panel_muted, 0.55);
    const bronze = theme.mix(active.panel_muted, theme.mix(active.accent, active.warning, 0.30), 0.16);
    var outline = theme.mix(active.border, theme.mix(active.accent, active.warning, 0.30), 0.22);
    const char_surface = theme.raiseAgainst(active.background, 0.035, active.background, active.text);
    if (lumaDistance(outline, bronze) < 0.10) {
        outline = active.border;
        if (lumaDistance(outline, bronze) < 0.10) outline = active.text_subtle;
    }
    const moss_deep = theme.mix(active.accent, surface_deep, 0.28);
    const moss_mid = theme.mix(active.accent, panel, 0.12);
    const moss_lit = theme.mix(theme.mix(active.accent, pole_light, 0.28), active.accent, 0.42);
    return .{
        .body = bronze,
        .body_depth = theme.withAlpha(pole_dark, 34),
        .outline = outline,
        .moss_deep = moss_deep,
        .moss_mid = moss_mid,
        .moss_lit = moss_lit,
        .port = theme.mix(active.warning, surface_deep, 0.94),
        .port_ring = theme.mix(surface_deep, active.warning, 0.28),
        .pupil = theme.mix(active.warning, pole_light, 0.22),
        .seam = theme.mix(surface_deep, active.warning, 0.20),
        .flower = theme.mix(pole_light, active.warning, 0.18),
        .flower_core = active.warning,
        .paused_lid = theme.mix(surface_deep, active.warning, 0.35),
        .char_surface = char_surface,
        .warning = active.warning,
        .warning_foreground = characterForegroundOn(active.warning, active.text, active.background),
        .danger = active.danger,
    };
}

fn deriveVireoPalette(active: CharacterTheme) VireoPalette {
    const text_is_lighter = characterLuma(active.text) >= characterLuma(active.background);
    const pole_light = if (text_is_lighter) active.text else active.background;
    const pole_dark = if (text_is_lighter) active.background else active.text;
    const panel = theme.mix(active.background, active.panel_muted, 0.42);
    const olive = theme.mix(theme.mix(active.accent, active.warning, 0.45), panel, 0.42);
    const breast = theme.mix(pole_light, active.accent, 0.12);
    var outline = theme.mix(active.border, active.accent, 0.35);
    const char_surface = theme.raiseAgainst(active.background, 0.035, active.background, active.text);
    if (lumaDistance(outline, olive) < 0.10) {
        outline = active.border;
        if (lumaDistance(outline, olive) < 0.10) outline = active.text_subtle;
    }
    return .{
        .body_back = olive,
        .body_breast = breast,
        .wing = theme.mix(theme.mix(active.accent, active.warning, 0.45), panel, 0.40),
        .wingtip = theme.mix(theme.mix(active.accent, active.warning, 0.45), active.panel_muted, 0.65),
        .tail = theme.mix(theme.mix(active.accent, active.warning, 0.45), panel, 0.48),
        .head = theme.mix(olive, panel, 0.18),
        .crown = theme.mix(active.panel_muted, pole_dark, 0.26),
        .brow = theme.mix(pole_light, active.accent, 0.20),
        .eyeline = theme.mix(pole_dark, active.warning, 0.28),
        .eye = theme.mix(active.danger, pole_light, 0.12),
        .pupil = theme.mix(active.background, pole_dark, 0.35),
        .beak = theme.mix(pole_dark, active.panel_muted, 0.22),
        .leg = theme.mix(active.panel_muted, pole_dark, 0.30),
        .outline = outline,
        .paused_lid = theme.mix(theme.mix(active.background, pole_dark, 0.35), active.danger, 0.30),
        .char_surface = char_surface,
        .warning = active.warning,
        .warning_foreground = characterForegroundOn(active.warning, active.text, active.background),
        .danger = active.danger,
    };
}

// Static Moss guardian bust; pose shifts ports, head tilt, and the shared failure badge.
fn renderMoss(state: *runtime.AppState, rect: palette.Rect, visual: controller.VisualState) void {
    const s = rect.w / 46.0;
    const moss = deriveMossPalette(activeCharacterTheme());
    const approval_tilt = if (visual.pose == .approval) 1.2 * s else 0.0;
    const paused_drop = if (visual.pose == .paused) 1.0 * s else 0.0;

    // Broad shoulder mound and resting hands.
    const torso: palette.Rect = .{ .x = rect.x, .y = rect.y + 26.0 * s, .w = 46.0 * s, .h = 20.0 * s };
    queueRoundedRect(state, offsetRect(torso, 0.0, 2.0 * s), color(moss.body_depth), 10.0 * s);
    queueCharacterPanel(state, torso, color(moss.body), color(moss.outline), 10.0 * s, 1.0 * s);
    queueRoundedRect(state, .{ .x = torso.x + 3.0 * s, .y = torso.y + torso.h - 3.0 * s, .w = 9.0 * s, .h = 6.0 * s }, color(moss.body), 4.0 * s);
    queueRoundedRect(state, .{ .x = torso.x + torso.w - 12.0 * s, .y = torso.y + torso.h - 3.0 * s, .w = 9.0 * s, .h = 6.0 * s }, color(moss.body), 4.0 * s);

    // Shoulder moss carpet with irregular clumps.
    const cap: palette.Rect = .{ .x = rect.x + 2.0 * s, .y = rect.y + 20.0 * s + paused_drop, .w = 42.0 * s, .h = 11.0 * s };
    queueRoundedRect(state, cap, color(moss.moss_mid), 6.0 * s);
    queueRoundedRect(state, .{ .x = cap.x + 4.0 * s, .y = cap.y + 1.0 * s, .w = 10.0 * s, .h = 7.0 * s }, color(moss.moss_lit), 4.0 * s);
    queueRoundedRect(state, .{ .x = cap.x + 18.0 * s, .y = cap.y - 1.0 * s, .w = 12.0 * s, .h = 8.0 * s }, color(moss.moss_deep), 5.0 * s);
    queueRoundedRect(state, .{ .x = cap.x + 30.0 * s, .y = cap.y + 2.0 * s, .w = 9.0 * s, .h = 7.0 * s }, color(moss.moss_lit), 4.0 * s);
    queueRoundedRect(state, .{ .x = cap.x + 5.0 * s, .y = cap.y + 6.0 * s, .w = 7.0 * s, .h = 6.0 * s }, color(moss.moss_mid), 3.5 * s);
    queueRoundedRect(state, .{ .x = cap.x + 29.0 * s, .y = cap.y + 6.0 * s, .w = 9.0 * s, .h = 8.0 * s }, color(moss.moss_deep), 4.0 * s);

    // Sprig and tiny flower from the shoulder carpet.
    queueRoundedRect(state, .{ .x = rect.x + 8.0 * s, .y = rect.y + 12.0 * s + paused_drop, .w = 1.5 * s, .h = 8.0 * s }, color(moss.moss_deep), 0.8 * s);
    queueRoundedRect(state, .{ .x = rect.x + 4.5 * s, .y = rect.y + 12.0 * s + paused_drop, .w = 5.0 * s, .h = 3.5 * s }, color(moss.moss_lit), 1.8 * s);
    queueRoundedRect(state, .{ .x = rect.x + 8.5 * s, .y = rect.y + 13.5 * s + paused_drop, .w = 4.0 * s, .h = 3.0 * s }, color(moss.moss_mid), 1.5 * s);
    queueRoundedRect(state, .{ .x = rect.x + 36.0 * s, .y = rect.y + 15.0 * s + paused_drop, .w = 4.0 * s, .h = 4.0 * s }, color(moss.flower), 2.0 * s);
    queueRoundedRect(state, .{ .x = rect.x + 37.0 * s, .y = rect.y + 16.0 * s + paused_drop, .w = 2.0 * s, .h = 2.0 * s }, color(moss.flower_core), 1.0 * s);

    // Egg-shaped head with neck, crown moss, ports, and mouth slot.
    const head_x = rect.x + 14.0 * s + approval_tilt;
    const head_y = rect.y + 1.0 * s + paused_drop;
    const neck: palette.Rect = .{ .x = head_x + 6.0 * s, .y = head_y + 17.0 * s, .w = 5.0 * s, .h = 8.0 * s };
    queueRoundedRect(state, neck, color(moss.body), 2.0 * s);
    const head: palette.Rect = .{ .x = head_x, .y = head_y, .w = 17.0 * s, .h = 20.0 * s };
    queueRoundedRect(state, offsetRect(head, 0.0, 2.0 * s), color(moss.body_depth), 8.5 * s);
    queueCharacterPanel(state, head, color(moss.body), color(moss.outline), 8.5 * s, 1.0 * s);
    queueRoundedRect(state, .{ .x = head.x - 3.0 * s, .y = head.y - 2.0 * s, .w = 19.0 * s, .h = 8.0 * s }, color(moss.moss_mid), 4.0 * s);
    queueRoundedRect(state, .{ .x = head.x - 1.0 * s, .y = head.y - 1.0 * s, .w = 7.0 * s, .h = 5.0 * s }, color(moss.moss_lit), 2.5 * s);
    queueRoundedRect(state, .{ .x = head.x + 11.0 * s, .y = head.y + 1.0 * s, .w = 6.0 * s, .h = 7.0 * s }, color(moss.moss_deep), 3.0 * s);

    const eye_y = head.y + 6.0 * s;
    const gaze = if (visual.pose == .approval) 1.5 * s else 0.0;
    inline for (.{ head.x + 3.0 * s, head.x + 9.0 * s }) |eye_x| {
        if (visual.pose == .paused) {
            queueRoundedRect(state, .{ .x = eye_x, .y = eye_y + 2.0 * s, .w = 5.5 * s, .h = 2.0 * s }, color(moss.paused_lid), 1.0 * s);
        } else {
            const eye: palette.Rect = .{ .x = eye_x, .y = eye_y, .w = 5.5 * s, .h = 5.5 * s };
            queueCharacterPanel(state, eye, color(moss.port), color(moss.port_ring), 2.75 * s, 1.0 * s);
            queueRoundedRect(state, .{ .x = eye.x + 1.8 * s + gaze, .y = eye.y + 1.8 * s, .w = 2.0 * s, .h = 2.0 * s }, color(moss.pupil), 1.0 * s);
        }
    }
    queueRoundedRect(state, .{ .x = head.x + 6.0 * s, .y = head.y + 14.5 * s, .w = 5.0 * s, .h = 2.0 * s }, color(moss.seam), 1.0 * s);

    if (visual.show_failure) {
        queueRoundedRect(state, .{ .x = rect.x - 4.0 * s, .y = rect.y - 2.0 * s, .w = 11.0 * s, .h = 11.0 * s }, color(moss.char_surface), 5.5 * s);
        queueRoundedRect(state, .{ .x = rect.x - 2.0 * s, .y = rect.y, .w = 7.0 * s, .h = 7.0 * s }, color(moss.danger), 3.5 * s);
    }
}

// Curved white supercilium in head-local units: rear low, mid peak, front soft drop —
// the prototype CSS arc (border-radius brow), not a flat bar.
fn vireoBrowArcPoints(head: palette.Rect, s: f32) [4]palette.draw.Vec2 {
    return .{
        .{ .x = head.x + 5.5 * s, .y = head.y + 5.8 * s },
        .{ .x = head.x + 10.2 * s, .y = head.y + 3.6 * s },
        .{ .x = head.x + 16.0 * s, .y = head.y + 3.3 * s },
        .{ .x = head.x + 22.5 * s, .y = head.y + 4.9 * s },
    };
}

// Dark eye-line tracks the same arc a little below the brow ridge.
fn vireoEyelineArcPoints(head: palette.Rect, s: f32) [4]palette.draw.Vec2 {
    return .{
        .{ .x = head.x + 6.0 * s, .y = head.y + 7.2 * s },
        .{ .x = head.x + 10.6 * s, .y = head.y + 5.4 * s },
        .{ .x = head.x + 16.2 * s, .y = head.y + 5.2 * s },
        .{ .x = head.x + 21.8 * s, .y = head.y + 6.6 * s },
    };
}

/// Profile faces right. Resting pupil sits viewer-left (toward the user/camera);
/// approval nudges slightly toward the badge without flipping to a look-away.
fn vireoPupilOffset(pose: controller.Pose, s: f32) struct { x: f32, y: f32 } {
    // Eye is 5.5 design units with a 2.2 pupil; geometric center offset is ~1.65.
    const rest_x = 0.55 * s;
    const rest_y = 1.55 * s;
    return switch (pose) {
        .approval => .{ .x = rest_x + 0.85 * s, .y = rest_y + 0.45 * s },
        else => .{ .x = rest_x, .y = rest_y },
    };
}

fn vireoPupilRect(eye: palette.Rect, pose: controller.Pose, s: f32) palette.Rect {
    const offset = vireoPupilOffset(pose, s);
    return .{
        .x = eye.x + offset.x,
        .y = eye.y + offset.y,
        .w = 2.2 * s,
        .h = 2.2 * s,
    };
}

fn queueVireoArc(state: *runtime.AppState, points: [4]palette.draw.Vec2, width: f32, fill: palette.Color) void {
    queueLine(state, points[0], points[1], width, fill);
    queueLine(state, points[1], points[2], width, fill);
    queueLine(state, points[2], points[3], width, fill);
    // Soft end caps so the stroke reads as a continuous ridge, not three hard joins.
    const cap = width * 0.55;
    inline for (.{ points[0], points[3] }) |tip| {
        queueRoundedRect(state, .{ .x = tip.x - cap, .y = tip.y - cap, .w = cap * 2.0, .h = cap * 2.0 }, fill, cap);
    }
}

// Static Vireo side-profile songbird; pose shifts head/tail and the shared failure badge.
fn renderVireo(state: *runtime.AppState, rect: palette.Rect, visual: controller.VisualState) void {
    const s = rect.w / 46.0;
    const vireo = deriveVireoPalette(activeCharacterTheme());
    const approval_tilt = if (visual.pose == .approval) 1.4 * s else 0.0;
    const paused_drop = if (visual.pose == .paused) 2.0 * s else 0.0;
    const tail_droop = if (visual.pose == .paused) 2.0 * s else 0.0;

    // Tail swept back off the perch, then slender body, legs, and wing.
    const tail: palette.Rect = .{
        .x = rect.x - 9.0 * s,
        .y = rect.y + 23.0 * s + tail_droop,
        .w = 21.0 * s,
        .h = 5.0 * s,
    };
    queueRoundedRect(state, tail, color(vireo.tail), 2.5 * s);

    const body: palette.Rect = .{ .x = rect.x + 5.0 * s, .y = rect.y + 17.0 * s, .w = 33.0 * s, .h = 18.0 * s };
    queueRoundedRect(state, offsetRect(body, 0.0, 2.0 * s), color(theme.withAlpha(vireo.outline, 40)), 9.0 * s);
    queueCharacterPanel(state, body, color(vireo.body_back), color(vireo.outline), 9.0 * s, 1.0 * s);
    queueRoundedRect(state, .{ .x = body.x + 10.0 * s, .y = body.y + 8.0 * s, .w = 20.0 * s, .h = 9.0 * s }, color(vireo.body_breast), 5.0 * s);
    queueRoundedRect(state, .{ .x = body.x + 13.0 * s, .y = body.y + body.h - 1.0 * s, .w = 1.8 * s, .h = 8.0 * s }, color(vireo.leg), 0.9 * s);
    queueRoundedRect(state, .{ .x = body.x + body.w - 13.8 * s, .y = body.y + body.h - 1.0 * s, .w = 1.8 * s, .h = 8.0 * s }, color(vireo.leg), 0.9 * s);

    const wing: palette.Rect = .{ .x = body.x + 1.0 * s, .y = body.y + 2.5 * s, .w = 21.0 * s, .h = 10.0 * s };
    queueRoundedRect(state, wing, color(vireo.wing), 5.0 * s);
    queueRoundedRect(state, .{ .x = wing.x - 2.0 * s, .y = wing.y + 5.0 * s, .w = 10.0 * s, .h = 4.5 * s }, color(vireo.wingtip), 2.2 * s);

    // Profile head with crown, arched supercilium, red eye, and pointed beak.
    const head: palette.Rect = .{
        .x = rect.x + 22.0 * s + approval_tilt,
        .y = rect.y + 1.0 * s + paused_drop,
        .w = 24.0 * s,
        .h = 16.0 * s,
    };
    queueCharacterPanel(state, head, color(vireo.head), color(vireo.outline), 7.0 * s, 1.0 * s);
    queueRoundedRect(state, .{ .x = head.x + 2.0 * s, .y = head.y, .w = 18.0 * s, .h = 6.0 * s }, color(vireo.crown), 4.0 * s);
    queueVireoArc(state, vireoBrowArcPoints(head, s), 1.55 * s, color(vireo.brow));
    queueVireoArc(state, vireoEyelineArcPoints(head, s), 1.15 * s, color(vireo.eyeline));

    const eye: palette.Rect = .{ .x = head.x + 14.5 * s, .y = head.y + 6.7 * s, .w = 5.5 * s, .h = if (visual.pose == .paused) 2.5 * s else 5.5 * s };
    if (visual.pose == .paused) {
        queueRoundedRect(state, eye, color(vireo.paused_lid), 1.2 * s);
    } else {
        queueCharacterPanel(state, eye, color(vireo.eye), color(vireo.brow), 2.75 * s, 1.0 * s);
        const pupil = vireoPupilRect(eye, visual.pose, s);
        queueRoundedRect(state, pupil, color(vireo.pupil), 1.1 * s);
    }
    queueRoundedRect(state, .{ .x = head.x + head.w - 3.0 * s, .y = head.y + 7.0 * s, .w = 10.0 * s, .h = 3.0 * s }, color(vireo.beak), 1.5 * s);

    if (visual.show_failure) {
        queueRoundedRect(state, .{ .x = rect.x - 4.0 * s, .y = rect.y - 2.0 * s, .w = 11.0 * s, .h = 11.0 * s }, color(vireo.char_surface), 5.5 * s);
        queueRoundedRect(state, .{ .x = rect.x - 2.0 * s, .y = rect.y, .w = 7.0 * s, .h = 7.0 * s }, color(vireo.danger), 3.5 * s);
    }
}

fn singleLineText(state: *runtime.AppState, text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var needs_copy = false;
    for (trimmed, 0..) |byte, index| {
        if (byte == '\n' or byte == '\r' or byte == '\t' or
            (byte == ' ' and index + 1 < trimmed.len and trimmed[index + 1] == ' '))
        {
            needs_copy = true;
            break;
        }
    }
    if (!needs_copy) return trimmed;
    const buffer = state.palette_frame_text_arena.allocator().alloc(u8, trimmed.len) catch return trimmed;
    var length: usize = 0;
    var pending_space = false;
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
            pending_space = length > 0;
            continue;
        }
        if (pending_space) {
            buffer[length] = ' ';
            length += 1;
            pending_space = false;
        }
        buffer[length] = byte;
        length += 1;
    }
    return buffer[0..length];
}

// Measured single-line truncation: binary-search the widest UTF-8-safe prefix
// that fits beside an ellipsis. Guessed character widths are banned, so every
// probe goes through the shared text metrics.
fn truncatedText(state: *runtime.AppState, role: palette.FontRole, font_size: f32, max_width: f32, text: []const u8) []const u8 {
    if (text.len == 0 or max_width <= 0.0) return text;
    if (text_measure.textWidth(role, font_size, text) <= max_width) return text;
    const ellipsis = "…";
    const ellipsis_width = text_measure.textWidth(role, font_size, ellipsis);
    var low: usize = 0;
    var high: usize = text.len - 1;
    var best: usize = 0;
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const candidate = utf8FloorIndex(text, mid);
        if (text_measure.textWidth(role, font_size, text[0..candidate]) + ellipsis_width <= max_width) {
            best = @max(best, candidate);
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }
    if (best == 0) return ellipsis;
    return framePrint(state, "{s}{s}", .{ text[0..best], ellipsis });
}

// Steps an index back to the nearest UTF-8 sequence start so truncation never
// splits a codepoint.
fn utf8FloorIndex(text: []const u8, index: usize) usize {
    var floor = index;
    while (floor > 0 and (text[floor] & 0xC0) == 0x80) floor -= 1;
    return floor;
}

fn companionScale() f32 {
    return theme.displayScaleFactor();
}

fn companionScaled(value: f32) f32 {
    return value * companionScale();
}

fn surface() [4]f32 {
    return theme.companionChrome().surface;
}

fn surfaceDeep() [4]f32 {
    return theme.companionChrome().surface_deep;
}

fn hairline() [4]f32 {
    return theme.companionChrome().hairline;
}

fn accentBright() [4]f32 {
    return theme.companionChrome().accent_hi;
}

fn colorsEqual(a: [4]f32, b: [4]f32) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn offsetRect(rect: palette.Rect, x: f32, y: f32) palette.Rect {
    return .{ .x = rect.x + x, .y = rect.y + y, .w = rect.w, .h = rect.h };
}

fn expandedOffsetRect(rect: palette.Rect, spread: f32, y: f32) palette.Rect {
    return .{ .x = rect.x - spread, .y = rect.y + y - spread, .w = rect.w + spread * 2.0, .h = rect.h + spread * 2.0 };
}

fn unionRects(a: palette.Rect, b: palette.Rect) palette.Rect {
    if (b.w <= 0.0 or b.h <= 0.0) return a;
    if (a.w <= 0.0 or a.h <= 0.0) return b;
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{ .x = x, .y = y, .w = @max(a.x + a.w, b.x + b.w) - x, .h = @max(a.y + a.h, b.y + b.h) - y };
}

fn rectFitsWindow(rect: palette.Rect, width: f32, height: f32) bool {
    return rect.w > 0.0 and rect.h > 0.0 and rect.x >= 0.0 and rect.y >= 0.0 and rect.x + rect.w <= width and rect.y + rect.h <= height;
}

fn color(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn queueRect(state: *runtime.AppState, rect: palette.Rect, fill: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, snappedRect(nonNegativeRect(rect)), fill) catch |err| log.warn("failed to queue rect: {s}", .{@errorName(err)});
}

fn queueRoundedRect(state: *runtime.AppState, rect: palette.Rect, fill: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, nonNegativeRect(rect), fill, radius) catch |err| log.warn("failed to queue rounded rect: {s}", .{@errorName(err)});
}

fn queueRoundedRectClipped(state: *runtime.AppState, rect: palette.Rect, fill: palette.Color, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, nonNegativeRect(rect), fill, radius, nonNegativeRect(clip)) catch |err| log.warn("failed to queue clipped rect: {s}", .{@errorName(err)});
}

// Bordered chrome primitive. Palette border-only commands carry a
// transparent-white fill, and the SDF shader composites every anti-aliased
// border fringe toward that fill color, so bare strokes halo white along all
// corner arcs. Panels instead draw the stroke as a filled underlay with the
// fill inset by the stroke width — two plain fills with correct edge AA.
// Chrome panels snap edges and stroke to whole device pixels so fractional
// display scales cannot smear one-pixel borders across two pixel rows;
// character art passes snap=false to keep its sub-pixel geometry.
fn appendPanel(allocator: std.mem.Allocator, batch: *palette.RenderBatch, rect_in: palette.Rect, fill: palette.Color, stroke: palette.Color, radius_in: f32, width_in: f32, clip_in: ?palette.Rect, snap: bool) !void {
    const rect = if (snap) snappedRect(nonNegativeRect(rect_in)) else nonNegativeRect(rect_in);
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    const width = @min(if (snap) snappedStroke(width_in) else width_in, @min(rect.w, rect.h) * 0.5);
    const radius = @min(radius_in, @min(rect.w, rect.h) * 0.5);
    const inner: palette.Rect = .{ .x = rect.x + width, .y = rect.y + width, .w = @max(rect.w - width * 2.0, 0.0), .h = @max(rect.h - width * 2.0, 0.0) };
    const inner_radius = @max(radius - width, 0.0);
    if (clip_in) |clip_value| {
        const clip = if (snap) snappedRect(nonNegativeRect(clip_value)) else nonNegativeRect(clip_value);
        if (clip.w <= 0.0 or clip.h <= 0.0) return;
        try batch.roundedRectClipped(allocator, rect, stroke, radius, clip);
        if (inner.w > 0.0 and inner.h > 0.0) try batch.roundedRectClipped(allocator, inner, fill, inner_radius, clip);
    } else {
        try batch.roundedRect(allocator, rect, stroke, radius);
        if (inner.w > 0.0 and inner.h > 0.0) try batch.roundedRect(allocator, inner, fill, inner_radius);
    }
}

fn queuePanel(state: *runtime.AppState, rect: palette.Rect, fill: palette.Color, stroke: palette.Color, radius: f32, width: f32) void {
    appendPanel(state.allocator, &state.palette_overlay_batch, rect, fill, stroke, radius, width, null, true) catch |err| log.warn("failed to queue panel: {s}", .{@errorName(err)});
}

fn queuePanelClipped(state: *runtime.AppState, rect: palette.Rect, fill: palette.Color, stroke: palette.Color, radius: f32, width: f32, clip: palette.Rect) void {
    appendPanel(state.allocator, &state.palette_overlay_batch, rect, fill, stroke, radius, width, clip, true) catch |err| log.warn("failed to queue clipped panel: {s}", .{@errorName(err)});
}

// Sprout is drawn at fractional character units, so its panels stay unsnapped:
// rounding a sub-pixel-scaled feature would visibly distort the character, and
// SDF AA renders the fractional edges smoothly.
fn queueCharacterPanel(state: *runtime.AppState, rect: palette.Rect, fill: palette.Color, stroke: palette.Color, radius: f32, width: f32) void {
    appendPanel(state.allocator, &state.palette_overlay_batch, rect, fill, stroke, radius, width, null, false) catch |err| log.warn("failed to queue character panel: {s}", .{@errorName(err)});
}

// Translucent theme washes assumed painter-order compositing over the surface
// beneath them; panels draw the stroke below the fill, so each layer is
// pre-flattened to its equivalent opaque color. Visual output is unchanged and
// warning/danger hues are preserved exactly.
fn opaqueOver(backdrop: [4]f32, layer: [4]f32) [4]f32 {
    return theme.mix(backdrop, .{ layer[0], layer[1], layer[2], 1.0 }, layer[3]);
}

// Edges snap independently (rather than snapping width and height) so
// adjacent chrome stays gap-free when fractional display scales produce
// non-integral coordinates.
fn snappedRect(rect: palette.Rect) palette.Rect {
    const x = @round(rect.x);
    const y = @round(rect.y);
    return .{ .x = x, .y = y, .w = @max(@round(rect.x + rect.w) - x, 0.0), .h = @max(@round(rect.y + rect.h) - y, 0.0) };
}

fn snappedStroke(width: f32) f32 {
    return @max(@round(width), 1.0);
}

fn queueText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, fill: palette.Color, font_size: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roleText(state.allocator, nonNegativeRect(rect), value, fill, font_size, .ui, null, nonNegativeRect(clip)) catch |err| log.warn("failed to queue text: {s}", .{@errorName(err)});
}

fn queueBoldText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, fill: palette.Color, font_size: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roleText(state.allocator, nonNegativeRect(rect), value, fill, font_size, .ui_bold, null, nonNegativeRect(clip)) catch |err| log.warn("failed to queue bold text: {s}", .{@errorName(err)});
}

fn queueMonoText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, fill: palette.Color, font_size: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roleText(state.allocator, nonNegativeRect(rect), value, fill, font_size, .mono, null, nonNegativeRect(clip)) catch |err| log.warn("failed to queue mono text: {s}", .{@errorName(err)});
}

fn queueCenteredText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, fill: palette.Color, font_size: f32, role: palette.FontRole, clip: palette.Rect) void {
    const text_w = text_measure.textWidth(role, font_size, value);
    const text_h = font_size * 1.4;
    const centered: palette.Rect = .{
        .x = rect.x + @max((rect.w - text_w) * 0.5, 0.0),
        .y = rect.y + @max((rect.h - text_h) * 0.5, 0.0),
        .w = @min(text_w + 1.0, rect.w),
        .h = @min(text_h, rect.h),
    };
    state.palette_overlay_batch.roleText(state.allocator, nonNegativeRect(centered), value, fill, font_size, role, null, nonNegativeRect(clip)) catch |err| log.warn("failed to queue centered text: {s}", .{@errorName(err)});
}

fn queueTriangle(state: *runtime.AppState, p0: palette.draw.Vec2, p1: palette.draw.Vec2, p2: palette.draw.Vec2, fill: palette.Color) void {
    state.palette_overlay_batch.triangle(state.allocator, p0, p1, p2, fill) catch |err| log.warn("failed to queue triangle: {s}", .{@errorName(err)});
}

fn queueLine(state: *runtime.AppState, from: palette.draw.Vec2, to: palette.draw.Vec2, width: f32, fill: palette.Color) void {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length <= 0.0) return;
    const nx = -dy / length * width * 0.5;
    const ny = dx / length * width * 0.5;
    const a: palette.draw.Vec2 = .{ .x = from.x + nx, .y = from.y + ny };
    const b: palette.draw.Vec2 = .{ .x = to.x + nx, .y = to.y + ny };
    const c: palette.draw.Vec2 = .{ .x = to.x - nx, .y = to.y - ny };
    const d: palette.draw.Vec2 = .{ .x = from.x - nx, .y = from.y - ny };
    queueTriangle(state, a, b, c, fill);
    queueTriangle(state, a, c, d, fill);
}

fn nonNegativeRect(rect: palette.Rect) palette.Rect {
    return .{ .x = rect.x, .y = rect.y, .w = @max(rect.w, 0.0), .h = @max(rect.h, 0.0) };
}

fn pointInRect(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn intersectRects(a: palette.Rect, b: palette.Rect) ?palette.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    if (right <= x or bottom <= y) return null;
    return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
}

fn commandEffectiveRect(command: palette.draw.Command) ?palette.Rect {
    if (command.kind == .triangle) return null;
    if (command.clip) |clip| return intersectRects(command.rect, clip);
    if (command.rect.w <= 0.0 or command.rect.h <= 0.0) return null;
    return command.rect;
}

// ---- tests ------------------------------------------------------------------

fn testState(allocator: std.mem.Allocator, state: *runtime.AppState) !void {
    // Fields read by modal key/text routing and new-chat defaults.
    state.folder_browser = .{};
    state.custom_agent_form = .{};
    state.settings_controller.provider_setup = .{};
    state.provider_controller = .{};
    state.allocator = allocator;
    state.app_config = .{ .companion_enabled = true };
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_roster = .{};
    state.companion_controller.identity.name.set("Juniper");
    state.companion_controller.identity.brain.set("Claude · Opus");
    state.companion_controller.identity.count = 1;
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    var project = try runtime.Project.init(allocator, "companion-ui", "Companion UI", "/tmp/companion-ui", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
}

fn deinitTestState(allocator: std.mem.Allocator, state: *runtime.AppState) void {
    for (state.project_controller.projects.items) |*project| project.deinit(allocator);
    state.project_controller.projects.deinit(allocator);
    state.companion_composer.deinit(allocator);
    state.palette_overlay_batch.deinit(allocator);
    state.palette_frame_text_arena.deinit();
}

fn expectBatchInsideWindow(batch: *const palette.RenderBatch, window: palette.Rect) !void {
    for (batch.commands.items) |command| {
        if (command.clip) |clip| try std.testing.expect(rectFitsWindow(clip, window.w, window.h));
        if (command.kind == .triangle) continue;
        if (commandEffectiveRect(command)) |rect| try std.testing.expect(rectFitsWindow(rect, window.w + 0.5, window.h + 0.5));
    }
}

fn batchHasText(batch: *const palette.RenderBatch, needle: []const u8) bool {
    for (batch.commands.items) |command| {
        if (command.kind != .text) continue;
        if (std.mem.indexOf(u8, command.text, needle) != null) return true;
    }
    return false;
}

test "dock and panel stay inside the window across sizes and scales" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    inline for (.{
        .{ @as(f32, 1360.0), @as(f32, 860.0), @as(f32, 1.0) },
        .{ @as(f32, 900.0), @as(f32, 700.0), @as(f32, 1.25) },
        .{ @as(f32, 390.0), @as(f32, 760.0), @as(f32, 1.0) },
        .{ @as(f32, 2536.0), @as(f32, 1030.0), @as(f32, 1.5) },
    }) |fixture| {
        theme.applyTheme(fixture[2]);
        var state: runtime.AppState = undefined;
        try testState(allocator, &state);
        defer deinitTestState(allocator, &state);
        const window: palette.Rect = .{ .w = fixture[0], .h = fixture[1] };

        render(&state, fixture[0], fixture[1]);
        try expectBatchInsideWindow(&state.palette_overlay_batch, window);
        // A quiet bubble carries no text at all.
        try std.testing.expect(!batchHasText(&state.palette_overlay_batch, "Juniper"));
        try std.testing.expect(!batchHasText(&state.palette_overlay_batch, "Ready when you are"));

        state.palette_overlay_batch.clear();
        state.companion_controller.show();
        render(&state, fixture[0], fixture[1]);
        try expectBatchInsideWindow(&state.palette_overlay_batch, window);
        try std.testing.expect(batchHasText(&state.palette_overlay_batch, "Hi, I'm Juniper."));
    }
}

test "panel shows the inbox, the crew, and a status that counts what needs the user" {
    const allocator = std.testing.allocator;
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    try testState(allocator, &state);
    defer deinitTestState(allocator, &state);

    var inbox: [1]controller.ChatRow = .{.{ .attention = .approval }};
    inbox[0].title.set("Fix auth tests");
    inbox[0].detail.set("verde · Run zig build test");
    state.companion_controller.setInbox(&inbox);
    var crew: [2]controller.ChatRow = .{ .{ .attention = .running }, .{ .attention = .done } };
    crew[0].title.set("Update docs");
    crew[0].provider.set("codex");
    crew[1].title.set("Bump deps");
    state.companion_controller.setCrew(&crew);

    render(&state, 1360.0, 860.0);
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "1 thing needs you"));
    try std.testing.expectEqual(controller.Pose.approval, state.companion_controller.visualState().pose);

    state.palette_overlay_batch.clear();
    state.companion_controller.show();
    render(&state, 1360.0, 860.0);
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "NEEDS YOU · 1"));
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "Needs approval: Fix auth tests"));
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "CREW · 1 RUNNING · 2 TOTAL"));
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "Update docs"));

    const geometry = computeGeometry(&state, 1360.0, 860.0);
    registerHits(&state, geometry);
    const inbox_row = rowRect(geometry.inbox, 0, INBOX_ROW_HEIGHT);
    const hit = state.companion_controller.hitEntryAt(inbox_row.x + 4.0, inbox_row.y + 4.0).?;
    try std.testing.expectEqual(controller.HitAction.inbox_open, hit.action);
    const crew_row = rowRect(geometry.crew, 1, CREW_ROW_HEIGHT);
    const crew_hit = state.companion_controller.hitEntryAt(crew_row.x + 4.0, crew_row.y + 4.0).?;
    try std.testing.expectEqual(controller.HitAction.crew_open, crew_hit.action);
    try std.testing.expectEqual(@as(usize, 1), crew_hit.index);
    try std.testing.expect(geometry.conversation.y >= geometry.crew.y + geometry.crew.h);
}

test "conversation renders user bubbles, wrapped replies, and tool lines" {
    const allocator = std.testing.allocator;
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    try testState(allocator, &state);
    defer deinitTestState(allocator, &state);
    state.companion_controller.show();
    var frame: controller.Frame = .{ .has_thread = true };
    _ = frame.setOwner("companion-ui", "chat-1");
    var user: controller.ActivityItem = .{ .kind = .user, .sequence = 1 };
    user.body.set("Get the web app building again");
    frame.appendActivity(user);
    var tool: controller.ActivityItem = .{ .kind = .tool, .status = .completed, .sequence = 2 };
    tool.author.set("open_chat");
    tool.body.set("codex in verde");
    frame.appendActivity(tool);
    var reply: controller.ActivityItem = .{ .kind = .assistant, .sequence = 3 };
    reply.body.set("**On it.** I opened a `codex` chat in verde.\n\n- It is running the build\n- I will report back");
    frame.appendActivity(reply);
    state.companion_controller.setFrame(frame);

    render(&state, 1360.0, 860.0);
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "Get the web app building again"));
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "On it. I opened a codex chat in verde."));
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "• It is running the build"));
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "open_chat · codex in verde"));
    try std.testing.expect(!batchHasText(&state.palette_overlay_batch, "**"));
}

test "menus register their rows above a dismiss layer" {
    const allocator = std.testing.allocator;
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    try testState(allocator, &state);
    defer deinitTestState(allocator, &state);
    state.companion_controller.show();
    state.companion_controller.roster_row_count = 2;
    state.companion_controller.roster_rows[0] = .{ .active = true };
    state.companion_controller.roster_rows[0].name.set("Juniper");
    state.companion_controller.roster_rows[1] = .{ .character = .vireo };
    state.companion_controller.roster_rows[1].name.set("Wren");
    state.companion_controller.identity.count = 2;
    state.companion_controller.openMenu(.companions);

    const geometry = computeGeometry(&state, 1360.0, 860.0);
    registerHits(&state, geometry);
    const layout = companionMenuLayout(&state, geometry);
    const row_hit = state.companion_controller.hitEntryAt(layout.rows[1].x + 4.0, layout.rows[1].y + 4.0).?;
    try std.testing.expectEqual(controller.HitAction.menu_select_companion, row_hit.action);
    try std.testing.expectEqual(@as(usize, 1), row_hit.index);
    const vireo_hit = state.companion_controller.hitEntryAt(layout.characters[2].x + 4.0, layout.characters[2].y + 4.0).?;
    try std.testing.expectEqual(controller.HitAction.menu_character, vireo_hit.action);
    try std.testing.expectEqual(app_config.CompanionCharacter.vireo, characterAt(vireo_hit.index).?);
    try std.testing.expectEqual(controller.HitAction.menu_remove, state.companion_controller.hitAt(layout.remove.x + 4.0, layout.remove.y + 4.0).?);
    try std.testing.expectEqual(controller.HitAction.menu_dismiss, state.companion_controller.hitAt(5.0, 5.0).?);

    render(&state, 1360.0, 860.0);
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "Wren"));
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "+ New companion"));
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "✎ New conversation"));
}

test "companion menu lists remembered conversations and routes resume" {
    const allocator = std.testing.allocator;
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    try testState(allocator, &state);
    defer deinitTestState(allocator, &state);
    state.companion_controller.show();
    state.companion_controller.roster_row_count = 1;
    state.companion_controller.roster_rows[0] = .{ .active = true };
    state.companion_controller.roster_rows[0].name.set("Juniper");
    state.companion_controller.conversation_row_count = 2;
    state.companion_controller.conversation_rows[0].title.set("ACP review");
    state.companion_controller.conversation_rows[0].detail.set("claude · haiku");
    state.companion_controller.conversation_rows[1].title.set("Muse rollout");
    state.companion_controller.openMenu(.companions);
    const geometry = computeGeometry(&state, 1360.0, 860.0);
    registerHits(&state, geometry);
    const layout = companionMenuLayout(&state, geometry);
    const hit = state.companion_controller.hitEntryAt(layout.conversations[1].x + 4.0, layout.conversations[1].y + 4.0).?;
    try std.testing.expectEqual(controller.HitAction.menu_resume_conversation, hit.action);
    try std.testing.expectEqual(@as(usize, 1), hit.index);
    try std.testing.expectEqual(controller.HitAction.menu_new_conversation, state.companion_controller.hitAt(layout.new_conversation.x + 4.0, layout.new_conversation.y + 4.0).?);
    render(&state, 1360.0, 860.0);
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "ACP review"));
}

test "measured wrap keeps words whole and bounds line count" {
    const wrapped = wrapText("one two three four five six seven eight nine ten", 60.0, .ui, 12.0, 3);
    try std.testing.expectEqual(@as(usize, 3), wrapped.count);
    try std.testing.expect(wrapped.truncated);
    for (wrapped.lines[0..wrapped.count]) |line| {
        try std.testing.expect(line.len > 0);
        try std.testing.expect(line[0] != ' ' and line[line.len - 1] != ' ');
    }
    const paragraphs = wrapText("first\n\nsecond", 500.0, .ui, 12.0, 8);
    try std.testing.expectEqual(@as(usize, 3), paragraphs.count);
    try std.testing.expectEqualStrings("", paragraphs.lines[1]);
}

test "characters fit their slots without distortion" {
    const slot: palette.Rect = .{ .x = 10.0, .y = 20.0, .w = 100.0, .h = 40.0 };
    inline for (.{ app_config.CompanionCharacter.sprout, .moss, .vireo }) |character| {
        const rect = characterInSlot(slot, character);
        const size = fullCharacterSize(character);
        try std.testing.expect(rectInside(rect, slot));
        try std.testing.expectApproxEqAbs(size.w / size.h, rect.w / rect.h, 0.001);
        try std.testing.expectApproxEqAbs(slot.y + slot.h, rect.y + rect.h, 0.001);
    }
}

test "recap offer renders and routes to its own action" {
    const allocator = std.testing.allocator;
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    try testState(allocator, &state);
    defer deinitTestState(allocator, &state);
    state.companion_controller.noteReturn(45 * 60 * 1000);
    render(&state, 1360.0, 860.0);
    // The collapsed bubble only badges a recap; the panel offers it.
    try std.testing.expect(!batchHasText(&state.palette_overlay_batch, "Welcome back · catch up?"));
    state.palette_overlay_batch.clear();
    state.companion_controller.show();
    render(&state, 1360.0, 860.0);
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "Welcome back · away 45 min"));
    const geometry = computeGeometry(&state, 1360.0, 860.0);
    registerHits(&state, geometry);
    try std.testing.expectEqual(controller.HitAction.recap, state.companion_controller.hitAt(geometry.recap.x + 4.0, geometry.recap.y + 4.0).?);
}

test "bubble stays compact, grows a pill only for notifications, and drags inside the window" {
    const allocator = std.testing.allocator;
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    try testState(allocator, &state);
    defer deinitTestState(allocator, &state);
    const window: palette.Rect = .{ .w = 1360.0, .h = 860.0 };

    var geometry = computeGeometry(&state, window.w, window.h);
    try std.testing.expectEqual(geometry.dock_bubble.w, geometry.dock.w);
    try std.testing.expectEqual(@as(f32, 0.0), geometry.dock_text.w);
    try std.testing.expect(rectInside(geometry.dock_avatar, geometry.dock_bubble));

    var inbox: [1]controller.ChatRow = .{.{ .attention = .approval }};
    inbox[0].title.set("Fix auth tests");
    state.companion_controller.setInbox(&inbox);
    geometry = computeGeometry(&state, window.w, window.h);
    try std.testing.expect(geometry.dock.w > geometry.dock_bubble.w);
    // Bottom-right bubble: the pill grows leftward and the bubble stays put.
    try std.testing.expectApproxEqAbs(geometry.dock.x + geometry.dock.w, geometry.dock_bubble.x + geometry.dock_bubble.w, 0.01);
    render(&state, window.w, window.h);
    try std.testing.expect(batchHasText(&state.palette_overlay_batch, "1 thing needs you"));
    try expectBatchInsideWindow(&state.palette_overlay_batch, window);

    // Drag to the top-left corner: a press that moves past the threshold.
    const companion = &state.companion_controller;
    companion.beginDockPress(geometry.dock_bubble.x + 10.0, geometry.dock_bubble.y + 10.0);
    try std.testing.expect(companion.dragDock(-5000.0, -5000.0, 1.0, dockBoundsAt(window.w, window.h, 1.0)));
    try std.testing.expectEqual(@as(?bool, false), companion.endDockPress());
    try std.testing.expectEqual(controller.Visibility.collapsed_chip, companion.visibility);
    geometry = computeGeometry(&state, window.w, window.h);
    try std.testing.expectApproxEqAbs(DOCK_EDGE_MARGIN, geometry.dock_bubble.x, 0.01);
    try std.testing.expectApproxEqAbs(DOCK_EDGE_MARGIN, geometry.dock_bubble.y, 0.01);
    // Left-side bubble: the pill grows rightward.
    try std.testing.expectApproxEqAbs(geometry.dock.x, geometry.dock_bubble.x, 0.01);
    state.palette_overlay_batch.clear();
    render(&state, window.w, window.h);
    try expectBatchInsideWindow(&state.palette_overlay_batch, window);

    // The bubble's hit still routes to the open action.
    registerHits(&state, geometry);
    try std.testing.expectEqual(controller.HitAction.open, companion.hitAt(geometry.dock_bubble.x + 10.0, geometry.dock_bubble.y + 10.0).?);
}
