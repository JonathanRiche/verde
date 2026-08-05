//! Fixture-backed native Companion overlay rendering and dedicated hit routing.

const std = @import("std");
const palette = @import("palette");
const app_config = @import("../app/config.zig");
const controller = @import("../state/companion_controller.zig");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");

// Keep settings_modal tests on the registered root suite without editing main.zig.
test {
    _ = @import("settings_modal.zig");
}

const log = std.log.scoped(.companion_ui);

pub const Geometry = struct {
    window: palette.Rect,
    chip: palette.Rect,
    chip_character: palette.Rect,
    chip_hit: palette.Rect,
    sidecar: palette.Rect,
    header: palette.Rect,
    close_button: palette.Rect,
    objective: palette.Rect,
    tabs: palette.Rect,
    body: palette.Rect,
    footer: palette.Rect,
};

/// Rebuilds Companion-only hits before SDL events are routed.
pub fn refreshHits(state: *runtime.AppState, width: f32, height: f32) void {
    state.syncCompanionProjection();
    state.companion_controller.frame_width = width;
    state.companion_controller.frame_height = height;
    const geometry = computeGeometryForState(width, height, companionScale(), &state.companion_controller);
    prepareAndRegisterHits(&state.companion_controller, geometry);
}

/// Routes pointer buttons only when the visible Companion surface is hit.
pub fn handleMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool, clicks: u8) bool {
    const result = state.companion_controller.handlePointerButton(x, y, button, down);
    if (!result.consumed) return false;
    if (result.action) |action| {
        switch (action) {
            .open => state.openCompanion(),
            .collapse => {
                state.companion_controller.collapse();
                state.blurCompanionComposer();
            },
            .approve, .deny => {
                const resolved = if (action == .approve)
                    state.resolveCurrentCompanionApproval(.approve)
                else
                    state.resolveCurrentCompanionApproval(.deny);
                state.companion_controller.ui_error = if (resolved) null else "Approval decision was not accepted.";
                refreshHits(state, state.companion_controller.frame_width, state.companion_controller.frame_height);
            },
            .run_tab, .activity_tab => {
                state.companion_controller.selectTab(if (action == .run_tab) .run else .activity);
                const geometry = computeGeometryForState(
                    state.companion_controller.frame_width,
                    state.companion_controller.frame_height,
                    companionScale(),
                    &state.companion_controller,
                );
                prepareAndRegisterHits(&state.companion_controller, geometry);
            },
            .operation_select => if (result.reference) |reference| {
                state.companion_controller.toggleOperationSelection(reference);
                const geometry = computeGeometryForState(
                    state.companion_controller.frame_width,
                    state.companion_controller.frame_height,
                    companionScale(),
                    &state.companion_controller,
                );
                prepareAndRegisterHits(&state.companion_controller, geometry);
            },
            .operation_stop, .operation_follow_log => if (result.reference) |reference| {
                _ = state.dispatchCompanionOperationAction(
                    reference,
                    if (action == .operation_stop) .stop else .follow_log,
                );
                refreshHits(state, state.companion_controller.frame_width, state.companion_controller.frame_height);
            },
            .panel, .body => {},
        }
        state.markDirty();
    }
    if (button == 1 and state.companion_controller.visibility == .sidecar_open and
        (result.action == null or result.action.? == .panel))
    {
        _ = state.routeCompanionComposerMouseButton(x, y, down, clicks);
    }
    return true;
}

/// Prevents underlying hover routing only inside the chip or sidecar.
pub fn handleMouseMotion(state: *runtime.AppState, x: f32, y: f32, dragging: bool) bool {
    const owned = state.companion_controller.hasPointerCapture() or state.companion_controller.hitAt(x, y) != null;
    if (owned) _ = state.routeCompanionComposerMouseMotion(x, y, dragging);
    return owned;
}

/// Scrolls the sidecar body directly; panel chrome consumes without scrolling.
pub fn handleWheel(state: *runtime.AppState, x: f32, y: f32, wheel_y: f32) bool {
    const action = state.companion_controller.hitAt(x, y) orelse return false;
    if (state.routeCompanionComposerWheel(x, y, wheel_y)) return true;
    const body_rect = bodyHitRect(state.companion_controller.hits[0..state.companion_controller.hit_count]);
    if (pointInRect(body_rect, x, y) and wheel_y != 0.0) {
        const max_scroll = @max(bodyContentHeight(&state.companion_controller, body_rect.w) - body_rect.h, 0.0);
        state.companion_controller.scrollCurrent(-wheel_y * companionScaled(32.0), max_scroll);
        state.markDirty();
    }
    _ = action;
    return true;
}

/// Owns one physical Escape sequence and collapses only on its first key-down.
pub fn handleEscapeKey(state: *runtime.AppState, down: bool) bool {
    if (!state.companion_controller.handleEscapeKey(down)) return false;
    if (down) state.blurCompanionComposer();
    state.markDirty();
    return true;
}

pub fn ownsEscapeKey(state: *const runtime.AppState) bool {
    return state.companion_controller.ownsEscapeKey();
}

pub fn ownsPointerRelease(state: *const runtime.AppState, button: u8) bool {
    return state.companion_controller.ownsPointerRelease(button);
}

pub fn resetInputCaptures(state: *runtime.AppState) void {
    state.companion_controller.resetInputCaptures();
}

pub fn hitAt(state: *const runtime.AppState, x: f32, y: f32) ?controller.HitAction {
    return state.companion_controller.hitAt(x, y);
}

/// Renders the persistent Companion surface above panes and below true modals.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    const geometry = computeGeometryForState(width, height, companionScale(), &state.companion_controller);
    switch (state.companion_controller.visibility) {
        .collapsed_chip => renderChip(state, geometry),
        .sidecar_open => renderSidecar(state, geometry),
    }
}

pub fn computeGeometry(width: f32, height: f32, scale: f32) Geometry {
    var state = controller.init();
    state.applyFixture(.idle);
    return computeGeometryForState(width, height, scale, &state);
}

fn computeGeometryForState(width: f32, height: f32, scale: f32, state: *const controller) Geometry {
    const scaled = struct {
        fn value(raw: f32, factor: f32) f32 {
            return raw * factor;
        }
    }.value;
    const window_width = @max(width, 0.0);
    const window_height = @max(height, 0.0);
    const narrow = window_width < scaled(440.0, scale);
    const desired_inset = scaled(if (narrow) 8.0 else 10.0, scale);
    const side_inset = @min(desired_inset, @min(window_width, window_height) * 0.5);
    const sidecar_width = @max(@min(scaled(404.0, scale), window_width - side_inset * 2.0), 0.0);
    const sidecar_height = @max(window_height - side_inset * 2.0, 0.0);
    const sidecar: palette.Rect = .{
        .x = window_width - side_inset - sidecar_width,
        .y = side_inset,
        .w = sidecar_width,
        .h = sidecar_height,
    };

    const header_h = @min(scaled(44.0, scale), sidecar.h);
    const after_header = @max(sidecar.h - header_h, 0.0);
    const footer_h = @min(scaled(116.0, scale), after_header);
    const chrome_room = @max(after_header - footer_h, 0.0);
    const tabs_h = @min(scaled(45.0, scale), chrome_room);
    const objective_h = @min(scaled(92.0, scale), @max(chrome_room - tabs_h, 0.0));
    const body_h = @max(sidecar.h - header_h - objective_h - tabs_h - footer_h, 0.0);
    const chip_width = @min(chipWidth(state, scale), window_width);
    const chip_height = @min(scaled(36.0, scale), window_height);
    const chip: palette.Rect = .{
        .x = @max(window_width - chip_width, 0.0),
        .y = @max(window_height - @min(scaled(20.0, scale), window_height) - chip_height, 0.0),
        .w = chip_width,
        .h = chip_height,
    };
    const character_width = @min(scaled(46.0, scale), window_width);
    const character_height = @min(scaled(48.0, scale), window_height);
    const character_candidate: palette.Rect = .{
        .x = @min(chip.x + scaled(5.0, scale), window_width),
        .y = chip.y + chip.h - scaled(33.0, scale) - character_height,
        .w = character_width,
        .h = character_height,
    };
    const character = if (rectFitsWindow(character_candidate, window_width, window_height) and
        character_width >= scaled(46.0, scale) and character_height >= scaled(48.0, scale))
        character_candidate
    else
        palette.Rect{ .x = chip.x, .y = chip.y };

    const close_x_inset = @min(scaled(12.0, scale), sidecar.w);
    const close_y_inset = @min(scaled(8.0, scale), header_h);
    const close_width = @min(scaled(27.0, scale), @max(sidecar.w - close_x_inset, 0.0));
    const close_height = @min(scaled(27.0, scale), @max(header_h - close_y_inset, 0.0));

    return .{
        .window = .{ .x = 0.0, .y = 0.0, .w = window_width, .h = window_height },
        .chip = chip,
        .chip_character = character,
        .chip_hit = unionRects(chip, character),
        .sidecar = sidecar,
        .header = .{ .x = sidecar.x, .y = sidecar.y, .w = sidecar.w, .h = header_h },
        .close_button = .{
            .x = sidecar.x + @max(sidecar.w - close_x_inset - close_width, 0.0),
            .y = sidecar.y + close_y_inset,
            .w = close_width,
            .h = close_height,
        },
        .objective = .{ .x = sidecar.x, .y = sidecar.y + header_h, .w = sidecar.w, .h = objective_h },
        .tabs = .{ .x = sidecar.x, .y = sidecar.y + header_h + objective_h, .w = sidecar.w, .h = tabs_h },
        .body = .{ .x = sidecar.x, .y = sidecar.y + header_h + objective_h + tabs_h, .w = sidecar.w, .h = body_h },
        .footer = .{ .x = sidecar.x, .y = sidecar.y + sidecar.h - footer_h, .w = sidecar.w, .h = footer_h },
    };
}

fn chipWidth(state: *const controller, scale: f32) f32 {
    const visual = chipVisual(state);
    var width: f32 = 103.0;
    width += switch (visual.detail) {
        .none => 0.0,
        .working, .failed => 43.0,
        .paused => 48.0,
    };
    if (visual.show_approval) width += 78.0;
    return width * scale;
}

const ChipDetail = enum { none, working, paused, failed };

const ChipVisual = struct {
    detail: ChipDetail,
    show_approval: bool,
    uses_danger: bool,
};

fn chipVisual(state: *const controller) ChipVisual {
    return .{
        .detail = if (state.run_phase == .paused)
            .paused
        else if (state.run_phase == .working)
            .working
        else if (state.has_failure)
            .failed
        else
            .none,
        .show_approval = state.needs_approval,
        .uses_danger = state.has_failure,
    };
}

fn prepareAndRegisterHits(state: *controller, geometry: Geometry) void {
    const max_scroll = @max(bodyContentHeight(state, geometry.body.w) - geometry.body.h, 0.0);
    if (state.selected_tab == .activity)
        state.updateActivityExtent(max_scroll)
    else
        state.body_scroll_y = std.math.clamp(state.body_scroll_y, 0.0, max_scroll);
    registerHits(state, geometry, state.presentation.has_approval);
}

fn registerHits(state: *controller, geometry: Geometry, show_approval: bool) void {
    state.clearHits();
    switch (state.visibility) {
        .collapsed_chip => state.addHit(geometry.chip_hit, .open),
        .sidecar_open => {
            state.addHit(geometry.sidecar, .panel);
            state.addHit(geometry.body, .body);
            const tabs = tabRects(geometry.tabs);
            state.addHit(tabs[0], .run_tab);
            state.addHit(tabs[1], .activity_tab);
            if (show_approval and state.selected_tab == .run) {
                const buttons = approvalButtonRects(geometry.body, state.currentScrollY());
                state.addHit(buttons[0], .deny);
                state.addHit(buttons[1], .approve);
            }
            registerOperationHits(state, geometry.body);
            state.addHit(geometry.close_button, .collapse);
        },
    }
}

fn registerOperationHits(state: *controller, body: palette.Rect) void {
    var y = body.y + companionScaled(12.0) - state.currentScrollY();
    if (state.selected_tab == .activity) {
        for (state.presentation.activity[0..state.presentation.activity_count]) |*item| {
            const reference = activityOperationReference(&state.presentation, item);
            if (reference) |value| registerOperationCardHits(state, body, &y, value, companionScaled(58.0), companionScaled(65.0));
            if (reference == null) y += companionScaled(65.0);
        }
        return;
    }

    const frame = &state.presentation;
    if (frame.has_approval) y += companionScaled(130.0);
    y += resultCardHeight(frame, body.w);
    const counts = frame.activeCounts();
    if (counts.working + counts.pending > 0) {
        y += companionScaled(27.0);
        for (0..frame.operation_count) |index| {
            if (!frame.operations[index].active()) continue;
            if (frame.operationReference(index)) |reference|
                registerOperationCardHits(state, body, &y, reference, companionScaled(72.0), companionScaled(79.0))
            else
                y += companionScaled(79.0);
        }
    }
    if (frame.recentCount() > 0) {
        y += companionScaled(27.0);
        var shown: usize = 0;
        for (0..frame.operation_count) |index| {
            if (frame.operations[index].active() or shown == 5) continue;
            if (frame.operationReference(index)) |reference|
                registerOperationCardHits(state, body, &y, reference, companionScaled(72.0), companionScaled(79.0))
            else
                y += companionScaled(79.0);
            shown += 1;
        }
    }
}

fn registerOperationCardHits(
    state: *controller,
    body: palette.Rect,
    y: *f32,
    reference: controller.OperationReference,
    card_height: f32,
    card_advance: f32,
) void {
    const card: palette.Rect = .{ .x = body.x + companionScaled(12.0), .y = y.*, .w = @max(body.w - companionScaled(24.0), 0.0), .h = card_height };
    if (reference.actions.inspect) if (intersectRects(card, body)) |hit_rect| state.addOperationHit(hit_rect, .operation_select, reference);
    y.* += card_advance;
    if (!state.operationSelected(&reference)) return;
    const operation = state.presentation.operationForReference(&reference) orelse return;
    const inspector: palette.Rect = .{ .x = card.x, .y = y.*, .w = card.w, .h = inspectorHeight(operation) };
    const controls = inspectorControlRects(inspector, reference.actions);
    if (controls.stop) |rect| if (intersectRects(rect, body)) |hit_rect| state.addOperationHit(hit_rect, .operation_stop, reference);
    if (controls.follow_log) |rect| if (intersectRects(rect, body)) |hit_rect| state.addOperationHit(hit_rect, .operation_follow_log, reference);
    y.* += inspector.h + companionScaled(7.0);
}

// Collapsed Companion chip region.
fn renderChip(state: *runtime.AppState, geometry: Geometry) void {
    const scale = companionScale();
    const chrome = theme.companionChrome();
    const character = activeCompanionCharacter(state);
    appendChipChrome(state.allocator, &state.palette_overlay_batch, geometry, scale) catch |err| log.warn("failed to queue chip chrome: {s}", .{@errorName(err)});
    if (geometry.chip.w < 103.0 * scale or geometry.chip.h < 36.0 * scale) return;
    if (geometry.chip_character.w > 0.0 and geometry.chip_character.h > 0.0) {
        renderCompanionCharacter(state, fullCharacterRect(geometry.chip_character, character, scale), state.companion_controller.visualState(), character, .full);
    }
    var x = geometry.chip.x + 54.0 * scale;
    const center_y = geometry.chip.y + 10.0 * scale;
    queueText(state, .{ .x = x, .y = center_y, .w = 42.0 * scale, .h = 17.0 * scale }, companionCharacterName(character), color(chrome.text), 12.0 * scale, geometry.chip);
    x += 46.0 * scale;
    const visual = chipVisual(&state.companion_controller);
    if (visual.detail == .working) {
        const count = framePrint(state, "{d} ops", .{state.companion_controller.operation_count});
        queueMonoText(state, .{ .x = x, .y = center_y + 1.0 * scale, .w = 40.0 * scale, .h = 15.0 * scale }, count, color(chrome.text_subtle), 10.5 * scale, geometry.chip);
        x += 43.0 * scale;
    } else if (visual.detail == .paused) {
        queueMonoText(state, .{ .x = x, .y = center_y + 1.0 * scale, .w = 45.0 * scale, .h = 15.0 * scale }, "paused", color(chrome.text_subtle), 10.5 * scale, geometry.chip);
        x += 48.0 * scale;
    } else if (visual.detail == .failed) {
        queueMonoText(state, .{ .x = x, .y = center_y + 1.0 * scale, .w = 40.0 * scale, .h = 15.0 * scale }, "failed", color(chrome.danger), 10.5 * scale, geometry.chip);
        x += 43.0 * scale;
    }
    if (visual.show_approval) {
        const pill: palette.Rect = .{ .x = x, .y = geometry.chip.y + 9.0 * scale, .w = @max(geometry.chip.x + geometry.chip.w - 12.0 * scale - x, 0.0), .h = 18.0 * scale };
        queueRoundedRect(state, pill, color(chrome.warning), 9.0 * scale);
        const approvals = framePrint(state, "{d} approval", .{state.companion_controller.approval_count});
        queueCenteredText(state, pill, approvals, color(chrome.warning_fg), 10.0 * scale, .ui_bold, pill);
    }
}

// Expanded Companion sidecar region.
fn renderSidecar(state: *runtime.AppState, geometry: Geometry) void {
    if (geometry.sidecar.w <= 0.0 or geometry.sidecar.h <= 0.0) return;
    const scale = companionScale();
    const chrome = theme.companionChrome();
    queueRect(state, geometry.window, color(theme.scrim(0.22)));
    // Soft shadows render as anti-aliased SDF fills clipped to the window; the
    // old triangle-fan meshes had no edge AA and read as faceted arcs.
    queueRoundedRectClipped(state, expandedOffsetRect(geometry.sidecar, 8.0 * scale, 18.0 * scale), color(theme.scrim(0.16)), 18.0 * scale, geometry.window);
    queueRoundedRectClipped(state, offsetRect(geometry.sidecar, 0.0, 4.0 * scale), color(theme.scrim(0.24)), 14.0 * scale, geometry.window);
    queuePanel(state, geometry.sidecar, color(surface()), color(chrome.border), 12.0 * scale, 1.0 * scale);
    renderHeader(state, geometry);
    renderObjective(state, geometry);
    renderTabs(state, geometry);
    renderBody(state, geometry);
    renderFooter(state, geometry);
}

// Sidecar identity and collapse controls region.
fn renderHeader(state: *runtime.AppState, geometry: Geometry) void {
    const scale = companionScale();
    const chrome = theme.companionChrome();
    const character = activeCompanionCharacter(state);
    if (geometry.header.w < 120.0 * scale or geometry.header.h < 44.0 * scale) return;
    const portrait = compactCharacterRect(geometry.header, character, scale);
    renderCompanionCharacter(state, portrait, state.companion_controller.visualState(), character, .compact);
    const title_x = portrait.x + 38.0 * scale;
    queueBoldText(state, .{ .x = title_x, .y = geometry.header.y + 11.0 * scale, .w = 48.0 * scale, .h = 18.0 * scale }, companionCharacterName(character), color(chrome.text), 13.0 * scale, geometry.header);
    const status = headerStatus(state);
    queueMonoText(state, .{ .x = title_x + 52.0 * scale, .y = geometry.header.y + 13.0 * scale, .w = @max(geometry.close_button.x - title_x - 57.0 * scale, 0.0), .h = 16.0 * scale }, status, color(chrome.text_subtle), 10.5 * scale, geometry.header);
    // The collapse affordance fills with the header surface it sits on: border
    // commands without a real fill halo white at every anti-aliased corner
    // because the SDF shader composites border fringes toward the fill color.
    queuePanel(state, geometry.close_button, color(surface()), color(hairline()), 6.0 * scale, 1.0 * scale);
    queueCenteredText(state, geometry.close_button, "−", color(chrome.text_muted), 12.0 * scale, .mono, geometry.close_button);
    // The divider stops short of the sidecar stroke so it cannot notch the
    // panel's side borders.
    const divider_inset = snappedStroke(1.0 * scale);
    queueRect(state, .{ .x = geometry.header.x + divider_inset, .y = geometry.header.y + geometry.header.h - 1.0 * scale, .w = @max(geometry.header.w - divider_inset * 2.0, 0.0), .h = 1.0 * scale }, color(hairline()));
}

// Sidecar objective summary region.
fn renderObjective(state: *runtime.AppState, geometry: Geometry) void {
    const scale = companionScale();
    const chrome = theme.companionChrome();
    if (geometry.objective.w < 180.0 * scale or geometry.objective.h < 70.0 * scale) return;
    const card: palette.Rect = .{ .x = geometry.objective.x + 12.0 * scale, .y = geometry.objective.y + 10.0 * scale, .w = @max(geometry.objective.w - 24.0 * scale, 0.0), .h = @max(geometry.objective.h - 10.0 * scale, 0.0) };
    queuePanel(state, card, color(surfaceDeep()), color(hairline()), 10.0 * scale, 1.0 * scale);
    const content_w = @max(card.w - 102.0 * scale, 0.0);
    queueBoldText(state, .{ .x = card.x + 12.0 * scale, .y = card.y + 10.0 * scale, .w = content_w, .h = 14.0 * scale }, "OBJECTIVE", color(chrome.text_subtle), 10.0 * scale, card);
    const presentation = &state.companion_controller.presentation;
    const objective = singleLineText(state, presentation.objective.slice());
    const title = if (objective.len > 0)
        truncatedText(state, .ui_bold, 13.0 * scale, content_w, objective)
    else
        "No active objective";
    // The subtitle states the run's real posture so the Objective card reads
    // as current status, not a static caption.
    const detail = if (!presentation.has_thread)
        "Start a run from this workspace."
    else if (presentation.has_approval)
        "Waiting on your approval below."
    else if (state.companion_controller.run_phase == .working)
        "Sprout is working on this now."
    else if (presentation.has_failure)
        "The last run needs attention."
    else if (objective.len > 0)
        "Done. Send the next instruction below."
    else
        "Send an instruction below to start.";
    queueBoldText(state, .{ .x = card.x + 12.0 * scale, .y = card.y + 29.0 * scale, .w = content_w, .h = 18.0 * scale }, title, color(chrome.text), 13.0 * scale, card);
    queueText(state, .{ .x = card.x + 12.0 * scale, .y = card.y + 49.0 * scale, .w = content_w, .h = 17.0 * scale }, detail, color(chrome.text_subtle), 11.5 * scale, card);
    const status_rect: palette.Rect = .{ .x = card.x + @max(card.w - 82.0 * scale, 0.0), .y = card.y + 11.0 * scale, .w = @min(70.0 * scale, card.w), .h = 22.0 * scale };
    const paused = state.companion_controller.run_phase == .paused;
    const working = state.companion_controller.run_phase == .working;
    const answered = std.mem.trim(u8, presentation.answer.slice(), " \t\r\n").len > 0;
    // The badge states the run's real outcome, not controller posture: DONE
    // and FAILED appear only once a turn actually resolved that way.
    const verdict = if (paused)
        "PAUSED"
    else if (working)
        "WORKING"
    else if (presentation.answer_failed)
        "FAILED"
    else if (answered)
        "DONE"
    else if (presentation.has_failure)
        "FAILED"
    else
        "READY";
    const badge_failed = !paused and !working and (presentation.answer_failed or (!answered and presentation.has_failure));
    const status_color = if (paused) chrome.warning else if (badge_failed) chrome.danger else chrome.identity_fg;
    queueRoundedRect(state, status_rect, color(if (paused) chrome.approval_card else if (badge_failed) chrome.failure_card else chrome.ready_fill), 6.0 * scale);
    queueCenteredText(state, status_rect, verdict, color(status_color), 10.0 * scale, .ui_bold, status_rect);
}

// Sidecar static section tabs region.
fn renderTabs(state: *runtime.AppState, geometry: Geometry) void {
    const scale = companionScale();
    const chrome = theme.companionChrome();
    if (geometry.tabs.w < 150.0 * scale or geometry.tabs.h < 35.0 * scale) return;
    const track: palette.Rect = .{ .x = geometry.tabs.x + 12.0 * scale, .y = geometry.tabs.y + 10.0 * scale, .w = @max(geometry.tabs.w - 24.0 * scale, 0.0), .h = @max(geometry.tabs.h - 10.0 * scale, 0.0) };
    queuePanel(state, track, color(chrome.surface_deep), color(chrome.border), 8.0 * scale, 1.0 * scale);
    const inner: palette.Rect = .{ .x = track.x + 3.0 * scale, .y = track.y + 3.0 * scale, .w = @max(track.w - 6.0 * scale, 0.0), .h = @max(track.h - 6.0 * scale, 0.0) };
    // Only Run and Activity are real, hit-registered views; unsupported
    // sections are omitted rather than rendered as decorative tabs.
    const tab_w = inner.w / 2.0;
    const selected_index: f32 = if (state.companion_controller.selected_tab == .run) 0.0 else 1.0;
    queueRoundedRect(state, .{ .x = inner.x + tab_w * selected_index, .y = inner.y, .w = tab_w, .h = inner.h }, color(chrome.surface), 6.0 * scale);
    queueCenteredText(state, .{ .x = inner.x, .y = inner.y, .w = tab_w, .h = inner.h }, "Run", color(if (state.companion_controller.selected_tab == .run) chrome.text else chrome.text_subtle), 11.5 * scale, .ui_bold, inner);
    queueCenteredText(state, .{ .x = inner.x + tab_w, .y = inner.y, .w = tab_w, .h = inner.h }, "Activity", color(if (state.companion_controller.selected_tab == .activity) chrome.text else chrome.text_subtle), 11.5 * scale, .ui_bold, inner);
    if (state.companion_controller.needs_approval) {
        queueRoundedRect(state, .{ .x = inner.x + tab_w - 18.0 * scale, .y = inner.y + (inner.h - 6.0 * scale) * 0.5, .w = 6.0 * scale, .h = 6.0 * scale }, color(chrome.warning), 3.0 * scale);
    }
}

// Scrollable Companion activity region.
fn renderBody(state: *runtime.AppState, geometry: Geometry) void {
    if (geometry.body.w <= 0.0 or geometry.body.h <= 0.0) return;
    // The sidecar panel fill already backs this region; a full-width repaint
    // here would overpaint the panel's side borders and rounded corners.
    const max_scroll = @max(bodyContentHeight(&state.companion_controller, geometry.body.w) - geometry.body.h, 0.0);
    if (state.companion_controller.selected_tab == .activity) state.companion_controller.updateActivityExtent(max_scroll);
    const inset = companionScaled(12.0);
    var y = geometry.body.y + inset - state.companion_controller.currentScrollY();
    if (state.companion_controller.selected_tab == .activity)
        renderActivityBody(state, geometry.body, &y)
    else
        renderRunBody(state, geometry.body, &y);
}

// Sidecar shared Companion composer region.
fn renderFooter(state: *runtime.AppState, geometry: Geometry) void {
    const chrome = theme.companionChrome();
    const composer = composerRect(geometry.footer);
    if (composer.w <= 0.0 or composer.h <= 0.0) return;
    // The sidecar panel fill backs the footer; repainting it full-width would
    // erase the side borders and square off the bottom rounded corners. The
    // divider is inset past the panel stroke for the same reason.
    const divider_inset = snappedStroke(companionScaled(1.0));
    queueRect(state, .{ .x = geometry.footer.x + divider_inset, .y = geometry.footer.y, .w = @max(geometry.footer.w - divider_inset * 2.0, 0.0), .h = companionScaled(1.0) }, color(hairline()));
    state.syncCompanionComposer(composer);
    // The shared composer defaults to the chat layer. Companion is rendered
    // above panes, so inherit the active overlay layer or panes cover every
    // composer command while the separately queued accent dot remains visible.
    state.companion_composer.z_index = state.palette_overlay_batch.current_z_index;
    var composer_batch: palette.RenderBatch = .{};
    defer composer_batch.deinit(state.allocator);
    state.companion_composer.render(state.allocator, &composer_batch) catch |err| log.warn("failed to render Companion composer: {s}", .{@errorName(err)});
    state.palette_overlay_batch.appendStableBatch(state.allocator, state.palette_frame_text_arena.allocator(), &composer_batch) catch |err| log.warn("failed to stage Companion composer: {s}", .{@errorName(err)});
    const model = state.companion_composer.modelRect();
    queueRoundedRect(state, .{ .x = model.x + companionScaled(1.0), .y = model.y + @max((model.h - companionScaled(6.0)) * 0.5, 0.0), .w = companionScaled(6.0), .h = companionScaled(6.0) }, color(chrome.accent), companionScaled(3.0));
}

fn composerRect(footer: palette.Rect) palette.Rect {
    return composerRectAtScale(footer, companionScale());
}

fn composerRectAtScale(footer: palette.Rect, scale: f32) palette.Rect {
    const inset = 12.0 * scale;
    const top_bottom = 22.0 * scale;
    if (footer.w < 180.0 * scale or footer.h < 70.0 * scale) return .{ .x = footer.x, .y = footer.y };
    return .{ .x = footer.x + inset, .y = footer.y + 10.0 * scale, .w = footer.w - inset * 2.0, .h = footer.h - top_bottom };
}

fn tabRects(tabs: palette.Rect) [2]palette.Rect {
    const scale = companionScale();
    const track: palette.Rect = .{
        .x = tabs.x + 12.0 * scale,
        .y = tabs.y + 10.0 * scale,
        .w = @max(tabs.w - 24.0 * scale, 0.0),
        .h = @max(tabs.h - 10.0 * scale, 0.0),
    };
    const inner: palette.Rect = .{
        .x = track.x + 3.0 * scale,
        .y = track.y + 3.0 * scale,
        .w = @max(track.w - 6.0 * scale, 0.0),
        .h = @max(track.h - 6.0 * scale, 0.0),
    };
    const tab_w = inner.w / 2.0;
    return .{
        .{ .x = inner.x, .y = inner.y, .w = tab_w, .h = inner.h },
        .{ .x = inner.x + tab_w, .y = inner.y, .w = tab_w, .h = inner.h },
    };
}

fn bodyContentHeight(state: *const controller, body_width: f32) f32 {
    const frame = &state.presentation;
    const inset = companionScaled(24.0);
    if (state.selected_tab == .activity) {
        if (frame.activity_count == 0) return inset + companionScaled(64.0);
        const working_extra: f32 = if (frame.working) companionScaled(28.0) else 0.0;
        var inspector_extra: f32 = 0.0;
        for (frame.activity[0..frame.activity_count]) |*item| {
            const reference = activityOperationReference(frame, item) orelse continue;
            if (!state.operationSelected(&reference)) continue;
            const operation = frame.operationForReference(&reference) orelse continue;
            inspector_extra += inspectorHeight(operation) + companionScaled(7.0);
        }
        return inset + @as(f32, @floatFromInt(frame.activity_count)) * companionScaled(65.0) + inspector_extra + working_extra;
    }
    var height = inset;
    if (frame.has_approval) height += companionScaled(130.0);
    height += resultCardHeight(frame, body_width);
    const active = frame.activeCounts();
    const active_total = active.working + active.pending;
    if (active_total > 0) height += companionScaled(27.0 + 79.0 * @as(f32, @floatFromInt(active_total)));
    const recent = frame.recentCount();
    if (recent > 0) height += companionScaled(27.0 + 79.0 * @as(f32, @floatFromInt(@min(recent, 5))));
    if (state.selected_operation) |*reference| {
        if (state.operationSelected(reference)) {
            var visible = false;
            var recent_shown: usize = 0;
            for (0..frame.operation_count) |index| {
                const operation = &frame.operations[index];
                if (!operation.active() and recent_shown == 5) continue;
                if (!operation.active()) recent_shown += 1;
                const candidate = frame.operationReference(index) orelse continue;
                if (candidate.eql(reference)) {
                    visible = true;
                    break;
                }
            }
            if (visible) {
                if (frame.operationForReference(reference)) |operation| {
                    height += inspectorHeight(operation) + companionScaled(7.0);
                }
            }
        }
    }
    if (active_total == 0 and recent == 0 and !resultCardVisible(frame)) height += companionScaled(79.0);
    if (frame.provider_error.slice().len > 0) height += companionScaled(79.0);
    if (frame.control_error.slice().len > 0) height += companionScaled(79.0);
    if (frame.ui_error.slice().len > 0) height += companionScaled(79.0);
    return height;
}

fn renderSectionHeader(state: *runtime.AppState, clip: palette.Rect, y: *f32, title: []const u8, summary: []const u8) void {
    const chrome = theme.companionChrome();
    queueBoldText(state, .{ .x = clip.x + companionScaled(12.0), .y = y.*, .w = clip.w * 0.5, .h = companionScaled(18.0) }, title, color(chrome.text_subtle), companionScaled(10.0), clip);
    queueMonoText(state, .{ .x = clip.x + clip.w * 0.5, .y = y.*, .w = @max(clip.w * 0.5 - companionScaled(12.0), 0.0), .h = companionScaled(18.0) }, summary, color(chrome.text_subtle), companionScaled(9.5), clip);
    y.* += companionScaled(27.0);
}

fn renderEmptyBody(state: *runtime.AppState, clip: palette.Rect, y: *f32, title: []const u8, detail: []const u8) void {
    const chrome = theme.companionChrome();
    queueBoldText(state, .{ .x = clip.x + companionScaled(12.0), .y = y.* + companionScaled(10.0), .w = @max(clip.w - companionScaled(24.0), 0.0), .h = companionScaled(18.0) }, title, color(chrome.text), companionScaled(12.0), clip);
    queueText(state, .{ .x = clip.x + companionScaled(12.0), .y = y.* + companionScaled(33.0), .w = @max(clip.w - companionScaled(24.0), 0.0), .h = companionScaled(18.0) }, detail, color(chrome.text_subtle), companionScaled(11.0), clip);
    y.* += companionScaled(64.0);
}

fn renderRunBody(state: *runtime.AppState, clip: palette.Rect, y: *f32) void {
    const frame = &state.companion_controller.presentation;
    if (frame.has_approval) renderApproval(state, clip, y, frame.approval_title.slice(), frame.approval_body.slice());
    // The answer leads and operations follow as supporting evidence: the user
    // reads what Sprout says without opening Activity.
    renderResultCard(state, clip, y);
    const counts = frame.activeCounts();
    const active_total = counts.working + counts.pending;
    if (active_total > 0) {
        const summary = framePrint(state, "{d} working · {d} pending", .{ counts.working, counts.pending });
        renderSectionHeader(state, clip, y, "ACTIVE OPERATIONS", summary);
        for (0..frame.operation_count) |index| {
            const operation = &frame.operations[index];
            if (!operation.active()) continue;
            renderFrameOperationCard(state, clip, y, operation, frame.operationReference(index));
        }
    }
    const recent_total = frame.recentCount();
    if (recent_total > 0) {
        const summary = if (recent_total > 5) framePrint(state, "5 of {d}", .{recent_total}) else framePrint(state, "{d}", .{recent_total});
        renderSectionHeader(state, clip, y, "RECENT", summary);
        var shown: usize = 0;
        for (0..frame.operation_count) |index| {
            const operation = &frame.operations[index];
            if (operation.active() or shown == 5) continue;
            renderFrameOperationCard(state, clip, y, operation, frame.operationReference(index));
            shown += 1;
        }
    }
    if (active_total == 0 and recent_total == 0 and !resultCardVisible(frame)) {
        if (frame.latest_body.slice().len > 0)
            renderOperationCard(state, clip, y, "Latest activity", frame.latest_body.slice(), .completed, false, false)
        else
            renderEmptyBody(state, clip, y, "Nothing running", "Send an instruction below to start.");
    }
    if (frame.provider_error.slice().len > 0) renderOperationCard(state, clip, y, "Send failed", frame.provider_error.slice(), .failed, false, false);
    if (frame.control_error.slice().len > 0) renderOperationCard(state, clip, y, "Action failed", frame.control_error.slice(), .failed, false, false);
    if (frame.ui_error.slice().len > 0) renderOperationCard(state, clip, y, "Sprout error", frame.ui_error.slice(), .failed, false, false);
}

// True when the Run tab owes the user a Result region: a run in flight, a
// current-turn answer, or a current-turn failure.
fn resultCardVisible(frame: *const controller.Frame) bool {
    if (frame.working or frame.answer_failed) return true;
    return std.mem.trim(u8, frame.answer.slice(), " \t\r\n").len > 0;
}

// Height the Result card occupies; shared with scroll extents so the direct
// non-inertial scroll math matches the rendered layout exactly.
fn resultCardHeight(frame: *const controller.Frame, body_width: f32) f32 {
    if (!resultCardVisible(frame)) return 0.0;
    const text_w = @max(body_width - companionScaled(48.0), 0.0);
    const wrapped = wrapResultText(std.mem.trim(u8, frame.answer.slice(), " \t\r\n"), text_w);
    const line_count: f32 = @floatFromInt(@max(wrapped.count, 1));
    return companionScaled(42.0) + line_count * companionScaled(17.0) + companionScaled(10.0);
}

// Prominent Result region at the top of Run: Sprout's streaming or final
// answer for the current objective, readable without opening Activity. States
// are truthful — WORKING while the run streams, DONE only for a real reply,
// FAILED only when this turn itself failed.
fn renderResultCard(state: *runtime.AppState, clip: palette.Rect, y: *f32) void {
    const frame = &state.companion_controller.presentation;
    if (!resultCardVisible(frame)) return;
    const scale = companionScale();
    const chrome = theme.companionChrome();
    const failed = frame.answer_failed and !frame.working;
    const answer = std.mem.trim(u8, frame.answer.slice(), " \t\r\n");
    const card_w = @max(clip.w - 24.0 * scale, 0.0);
    const text_w = @max(card_w - 24.0 * scale, 0.0);
    const wrapped = wrapResultText(answer, text_w);
    const line_count: f32 = @floatFromInt(@max(wrapped.count, 1));
    const card: palette.Rect = .{ .x = clip.x + 12.0 * scale, .y = y.*, .w = card_w, .h = 42.0 * scale + line_count * 17.0 * scale };
    const card_fill = if (failed) opaqueOver(surface(), chrome.failure_card) else chrome.surface_deep;
    const card_stroke = opaqueOver(card_fill, if (failed) chrome.failure_border else chrome.hairline);
    queuePanelClipped(state, card, color(card_fill), color(card_stroke), 10.0 * scale, 1.0 * scale, clip);
    const stripe = if (failed) chrome.danger else if (frame.working) chrome.accent_hi else chrome.identity_fg;
    queueRoundedRectClipped(state, .{ .x = card.x, .y = card.y, .w = 3.0 * scale, .h = card.h }, color(stripe), 1.5 * scale, clip);
    const verdict_w = 62.0 * scale;
    queueBoldText(state, .{ .x = card.x + 12.0 * scale, .y = card.y + 10.0 * scale, .w = @max(card.w - verdict_w - 24.0 * scale, 0.0), .h = 15.0 * scale }, "SPROUT SAYS", color(chrome.text_subtle), 10.0 * scale, clip);
    const verdict = if (frame.working) "WORKING" else if (failed) "FAILED" else "DONE";
    const verdict_color = if (frame.working) chrome.accent else if (failed) chrome.danger else chrome.identity_fg;
    queueBoldText(state, .{ .x = card.x + @max(card.w - verdict_w - 12.0 * scale, 0.0), .y = card.y + 10.0 * scale, .w = verdict_w, .h = 15.0 * scale }, verdict, color(verdict_color), 9.5 * scale, clip);
    if (wrapped.count == 0) {
        // Truthful empty states: the run is live but has streamed nothing
        // yet, or it died before producing any reply at all.
        const placeholder = if (frame.working) "Working — no reply yet." else "The run failed before replying.";
        queueText(state, .{ .x = card.x + 12.0 * scale, .y = card.y + 30.0 * scale, .w = text_w, .h = 16.0 * scale }, placeholder, color(if (failed) chrome.failure_fg else chrome.text_subtle), RESULT_FONT_SIZE * scale, clip);
    } else for (wrapped.lines[0..wrapped.count], 0..) |line, index| {
        const last = index + 1 == wrapped.count;
        const value = if (last and wrapped.truncated) framePrint(state, "{s}…", .{line}) else line;
        queueText(state, .{ .x = card.x + 12.0 * scale, .y = card.y + 30.0 * scale + @as(f32, @floatFromInt(index)) * 17.0 * scale, .w = text_w, .h = 16.0 * scale }, value, color(if (failed) chrome.failure_fg else chrome.text), RESULT_FONT_SIZE * scale, clip);
    }
    y.* += card.h + 10.0 * scale;
}

fn renderActivityBody(state: *runtime.AppState, clip: palette.Rect, y: *f32) void {
    const frame = &state.companion_controller.presentation;
    if (frame.activity_count == 0) {
        if (frame.working)
            renderEmptyBody(state, clip, y, "Sprout is working…", "Activity will appear here as the run progresses.")
        else
            renderEmptyBody(state, clip, y, "No activity yet", "Events from this run will appear here.");
        return;
    }
    for (0..frame.activity_count) |index| {
        const item = &frame.activity[index];
        const reference = activityOperationReference(frame, item);
        renderActivityRow(state, clip, y, item, if (reference) |value| state.companion_controller.operationSelected(&value) else false);
        if (reference) |value| if (state.companion_controller.operationSelected(&value)) {
            if (frame.operationForReference(&value)) |operation| renderOperationInspector(state, clip, y, operation, value);
        };
    }
    // A live run keeps a visible pulse at the tail so the newest row is never
    // mistaken for the final word.
    if (frame.working) {
        const chrome = theme.companionChrome();
        queueText(state, .{ .x = clip.x + companionScaled(24.0), .y = y.*, .w = @max(clip.w - companionScaled(36.0), 0.0), .h = companionScaled(16.0) }, "Sprout is working…", color(chrome.text_subtle), companionScaled(10.5), clip);
        y.* += companionScaled(28.0);
    }
}

// One bounded Activity row: kind-colored stripe, author, optional state label,
// and a single-line body so raw command dumps cannot overflow the card.
fn renderActivityRow(state: *runtime.AppState, clip: palette.Rect, y: *f32, item: *const controller.ActivityItem, selected: bool) void {
    const chrome = theme.companionChrome();
    const failed = item.status == .failed;
    const accent = activityAccent(chrome, item);
    const card: palette.Rect = .{ .x = clip.x + companionScaled(12.0), .y = y.*, .w = @max(clip.w - companionScaled(24.0), 0.0), .h = companionScaled(58.0) };
    const card_fill = if (failed) opaqueOver(surface(), chrome.failure_card) else chrome.surface_deep;
    const card_stroke = opaqueOver(card_fill, if (selected) chrome.accent else if (failed) chrome.failure_border else chrome.hairline);
    queuePanelClipped(state, card, color(card_fill), color(card_stroke), companionScaled(9.0), companionScaled(1.0), clip);
    queueRoundedRectClipped(state, .{ .x = card.x, .y = card.y, .w = companionScaled(3.0), .h = card.h }, color(accent), companionScaled(1.5), clip);
    const status_w = companionScaled(52.0);
    const author_w = if (item.status != null) @max(card.w - companionScaled(22.0) - status_w, 0.0) else @max(card.w - companionScaled(22.0), 0.0);
    queueBoldText(state, .{ .x = card.x + companionScaled(11.0), .y = card.y + companionScaled(8.0), .w = author_w, .h = companionScaled(17.0) }, item.author.slice(), color(if (failed) chrome.failure_fg else chrome.text), companionScaled(11.5), clip);
    if (item.status) |status| {
        queueBoldText(state, .{ .x = card.x + @max(card.w - status_w - companionScaled(11.0), 0.0), .y = card.y + companionScaled(9.0), .w = status_w, .h = companionScaled(15.0) }, operationStatusLabel(status), color(operationStatusColor(chrome, status)), companionScaled(9.0), clip);
    }
    // Tool and process rows carry command dumps; show the command preview
    // rather than the raw Input/Output text.
    const raw_body = switch (item.kind) {
        .tool, .process => operationPreview(item.body.slice()).detail,
        else => item.body.slice(),
    };
    const body_w = @max(card.w - companionScaled(22.0), 0.0);
    const body = truncatedText(state, .ui, companionScaled(10.5), body_w, singleLineText(state, raw_body));
    queueText(state, .{ .x = card.x + companionScaled(11.0), .y = card.y + companionScaled(29.0), .w = body_w, .h = companionScaled(18.0) }, body, color(if (failed) chrome.failure_fg else chrome.text_subtle), companionScaled(10.5), clip);
    y.* += companionScaled(65.0);
}

fn activityAccent(chrome: theme.CompanionChrome, item: *const controller.ActivityItem) [4]f32 {
    if (item.status) |status| return operationStatusColor(chrome, status);
    return switch (item.kind) {
        .user => chrome.accent,
        .assistant => chrome.identity_fg,
        .streaming => chrome.accent_hi,
        .system => chrome.text_muted,
        .tool, .process => chrome.text_subtle,
    };
}

fn approvalButtonRects(body: palette.Rect, scroll_y: f32) [2]palette.Rect {
    const inset = companionScaled(12.0);
    const gap = companionScaled(8.0);
    const card_width = @max(body.w - inset * 2.0, 0.0);
    const width = @max((card_width - companionScaled(24.0) - gap) * 0.5, 0.0);
    const x = body.x + inset + companionScaled(12.0);
    const y = body.y + inset - scroll_y + companionScaled(76.0);
    return .{
        .{ .x = x + width + gap, .y = y, .w = width, .h = companionScaled(28.0) },
        .{ .x = x, .y = y, .w = width, .h = companionScaled(28.0) },
    };
}

fn renderApproval(state: *runtime.AppState, body: palette.Rect, y: *f32, title: []const u8, detail: []const u8) void {
    const scale = companionScale();
    const chrome = theme.companionChrome();
    const card: palette.Rect = .{ .x = body.x + 12.0 * scale, .y = y.*, .w = @max(body.w - 24.0 * scale, 0.0), .h = 116.0 * scale };
    const card_fill = opaqueOver(surface(), chrome.approval_card);
    const card_stroke = opaqueOver(card_fill, chrome.approval_border);
    queuePanelClipped(state, card, color(card_fill), color(card_stroke), 10.0 * scale, 1.0 * scale, body);
    queueRoundedRectClipped(state, .{ .x = card.x, .y = card.y, .w = 3.0 * scale, .h = card.h }, color(chrome.warning), 1.5 * scale, body);
    queueText(state, .{ .x = card.x + 12.0 * scale, .y = card.y + 10.0 * scale, .w = 16.0 * scale, .h = 18.0 * scale }, "◆", color(chrome.warning), 11.0 * scale, body);
    queueBoldText(state, .{ .x = card.x + 31.0 * scale, .y = card.y + 9.0 * scale, .w = @max(card.w - 43.0 * scale, 0.0), .h = 18.0 * scale }, if (title.len > 0) title else "Permission required", color(chrome.approval_title), 12.0 * scale, body);
    queueText(state, .{ .x = card.x + 12.0 * scale, .y = card.y + 34.0 * scale, .w = @max(card.w - 24.0 * scale, 0.0), .h = 34.0 * scale }, if (detail.len > 0) detail else "Sprout is waiting for your decision before continuing.", color(chrome.approval_body), 12.0 * scale, body);
    const buttons = approvalButtonRects(body, state.companion_controller.currentScrollY());
    queuePanelClipped(state, buttons[0], color(surfaceDeep()), color(chrome.border), 8.0 * scale, 1.0 * scale, body);
    queueRoundedRectClipped(state, buttons[1], color(chrome.accent), 8.0 * scale, body);
    queueCenteredText(state, buttons[0], "Cancel action", color(chrome.text_muted), 11.5 * scale, .ui_bold, body);
    queueCenteredText(state, buttons[1], "Allow once", color(chrome.accent_fg), 11.5 * scale, .ui_bold, body);
    y.* += card.h + 14.0 * scale;
}

// One Frame-backed operation in the Run region. These are real tracked
// executions, so a completed card may truthfully state its completion.
fn renderFrameOperationCard(state: *runtime.AppState, clip: palette.Rect, y: *f32, operation: *const controller.Operation, reference: ?controller.OperationReference) void {
    const selected = if (reference) |value| state.companion_controller.operationSelected(&value) else false;
    renderOperationCard(state, clip, y, operation.title.slice(), operation.detail.slice(), operation.status, true, selected);
    if (selected) renderOperationInspector(state, clip, y, operation, reference.?);
}

// One owner-derived operation card in the scrollable Run region. Raw bodies
// arrive as multi-line "Command:/Input: … Output: …" dumps, so the card shows
// a bounded single-line command preview plus a single-line result preview.
// completion_note allows "Completed successfully" only for cards whose status
// reflects a real tracked execution, never for generic transcript reuse.
fn renderOperationCard(state: *runtime.AppState, clip: palette.Rect, y: *f32, title: []const u8, detail: []const u8, status: controller.OperationStatus, completion_note: bool, selected: bool) void {
    const scale = companionScale();
    const chrome = theme.companionChrome();
    const failed = status == .failed;
    const indicator = operationStatusColor(chrome, status);
    const card: palette.Rect = .{ .x = clip.x + 12.0 * scale, .y = y.*, .w = @max(clip.w - 24.0 * scale, 0.0), .h = 72.0 * scale };
    const card_fill = if (failed) opaqueOver(surface(), chrome.failure_card) else chrome.surface_deep;
    const card_stroke = opaqueOver(card_fill, if (selected) chrome.accent else if (failed) chrome.failure_border else chrome.hairline);
    queuePanelClipped(state, card, color(card_fill), color(card_stroke), 10.0 * scale, 1.0 * scale, clip);
    const avatar: palette.Rect = .{ .x = card.x + 11.0 * scale, .y = card.y + 10.0 * scale, .w = 27.0 * scale, .h = 27.0 * scale };
    queuePanelClipped(state, avatar, color(chrome.surface_deep), color(chrome.border), 7.0 * scale, 1.0 * scale, clip);
    queueCenteredText(state, avatar, if (failed) "!" else "S", color(if (failed) chrome.failure_fg else chrome.identity_fg), 10.0 * scale, .mono, clip);
    const title_w = @max(card.w - 118.0 * scale, 0.0);
    queueBoldText(state, .{ .x = card.x + 48.0 * scale, .y = card.y + 9.0 * scale, .w = title_w, .h = 18.0 * scale }, truncatedText(state, .ui_bold, 12.0 * scale, title_w, singleLineText(state, title)), color(if (failed) chrome.failure_fg else chrome.text), 12.0 * scale, clip);
    const preview = operationPreview(detail);
    const line_w = @max(card.w - 60.0 * scale, 0.0);
    queueMonoText(state, .{ .x = card.x + 48.0 * scale, .y = card.y + 29.0 * scale, .w = line_w, .h = 15.0 * scale }, truncatedText(state, .mono, 10.0 * scale, line_w, singleLineText(state, preview.detail)), color(if (failed) chrome.failure_fg else chrome.text_subtle), 10.0 * scale, clip);
    // Successful cards show real output or a truthful completion note, never
    // a CWD/ExitCode/Duration metadata dump; failure and stop cards keep
    // their full previews because that detail is diagnostic.
    const result_preview: ?[]const u8 = if (preview.result) |result|
        (if (status == .completed) meaningfulResultPreview(result) else result)
    else
        null;
    if (result_preview) |result| {
        queueText(state, .{ .x = card.x + 48.0 * scale, .y = card.y + 47.0 * scale, .w = line_w, .h = 15.0 * scale }, truncatedText(state, .ui, 10.0 * scale, line_w, singleLineText(state, result)), color(if (failed) chrome.failure_fg else chrome.text_muted), 10.0 * scale, clip);
    } else if (completion_note and status == .completed) {
        queueText(state, .{ .x = card.x + 48.0 * scale, .y = card.y + 47.0 * scale, .w = line_w, .h = 15.0 * scale }, "Completed successfully", color(chrome.text_muted), 10.0 * scale, clip);
    }
    if (status == .pending) {
        // Pending renders as a ring: an indicator-colored underlay whose core
        // is refilled with the card color, so no border-only command is needed.
        const ring: palette.Rect = .{ .x = card.x + card.w - 65.0 * scale, .y = card.y + 15.0 * scale, .w = 7.0 * scale, .h = 7.0 * scale };
        queuePanelClipped(state, ring, color(card_fill), color(indicator), 3.5 * scale, 1.0 * scale, clip);
    } else {
        queueRoundedRectClipped(state, .{ .x = card.x + card.w - 65.0 * scale, .y = card.y + 15.0 * scale, .w = 7.0 * scale, .h = 7.0 * scale }, color(indicator), 3.5 * scale, clip);
    }
    queueBoldText(state, .{ .x = card.x + card.w - 54.0 * scale, .y = card.y + 10.0 * scale, .w = 45.0 * scale, .h = 18.0 * scale }, operationStatusLabel(status), color(indicator), 9.5 * scale, clip);
    y.* += card.h + 7.0 * scale;
}

const InspectorControls = struct {
    stop: ?palette.Rect = null,
    follow_log: ?palette.Rect = null,
};

fn activityOperationReference(frame: *const controller.Frame, item: *const controller.ActivityItem) ?controller.OperationReference {
    if (item.kind != .tool and item.kind != .process) return null;
    const identity = item.identity.slice();
    if (identity.len == 0) return null;
    for (frame.operations[0..frame.operation_count], 0..) |*operation, index| {
        if (!std.mem.eql(u8, operation.identity.slice(), identity)) continue;
        return frame.operationReference(index);
    }
    return null;
}

fn inspectorHeight(operation: *const controller.Operation) f32 {
    const row_count = inspectorMetadataRowCount(operation) + @as(usize, if (inspectorOutput(operation) != null) 1 else 0);
    const controls: f32 = if (operation.actions.stop or operation.actions.follow_log) companionScaled(34.0) else 0.0;
    return companionScaled(36.0 + 19.0 * @as(f32, @floatFromInt(row_count))) + controls;
}

fn inspectorMetadataRowCount(operation: *const controller.Operation) usize {
    const inspector = &operation.inspector;
    var count: usize = 0;
    inline for (.{
        inspector.owner.slice(),
        inspector.workspace.slice(),
        inspector.action.slice(),
        inspector.target.slice(),
        inspector.provider.slice(),
        inspector.cwd.slice(),
        inspector.state.slice(),
        inspector.wait_reason.slice(),
        inspector.failure_reason.slice(),
        inspector.locations.slice(),
    }) |value| if (value.len > 0) {
        count += 1;
    };
    for (inspector.files[0..@min(inspector.file_count, inspector.files.len)]) |*value| if (value.slice().len > 0) {
        count += 1;
    };
    for (inspector.resources[0..@min(inspector.resource_count, inspector.resources.len)]) |*value| if (value.slice().len > 0) {
        count += 1;
    };
    if (inspector.started_at_ms != null) count += 1;
    if (inspector.updated_at_ms != null) count += 1;
    if (inspector.elapsed_ms != null) count += 1;
    return count;
}

fn inspectorOutput(operation: *const controller.Operation) ?[]const u8 {
    const output = std.mem.trim(u8, operation.inspector.output.slice(), " \t\r\n");
    return if (output.len > 0) output else null;
}

fn inspectorControlRects(rect: palette.Rect, actions: controller.SupportedActions) InspectorControls {
    const count: usize = @as(usize, @intFromBool(actions.stop)) + @as(usize, @intFromBool(actions.follow_log));
    if (count == 0) return .{};
    const inset = companionScaled(10.0);
    const gap = companionScaled(7.0);
    const total_w = @max(rect.w - inset * 2.0, 0.0);
    const button_w = if (count == 2) @max((total_w - gap) * 0.5, 0.0) else total_w;
    const y = rect.y + rect.h - companionScaled(30.0);
    var x = rect.x + inset;
    var result: InspectorControls = .{};
    if (actions.stop) {
        result.stop = .{ .x = x, .y = y, .w = button_w, .h = companionScaled(24.0) };
        x += button_w + gap;
    }
    if (actions.follow_log) result.follow_log = .{ .x = x, .y = y, .w = button_w, .h = companionScaled(24.0) };
    return result;
}

// Inline operation inspector region beneath its selected Run or Activity row.
fn renderOperationInspector(
    state: *runtime.AppState,
    clip: palette.Rect,
    y: *f32,
    operation: *const controller.Operation,
    reference: controller.OperationReference,
) void {
    const chrome = theme.companionChrome();
    const rect: palette.Rect = .{
        .x = clip.x + companionScaled(12.0),
        .y = y.*,
        .w = @max(clip.w - companionScaled(24.0), 0.0),
        .h = inspectorHeight(operation),
    };
    queuePanelClipped(state, rect, color(chrome.surface_deep), color(chrome.accent), companionScaled(9.0), companionScaled(1.0), clip);
    queueRoundedRectClipped(state, .{ .x = rect.x, .y = rect.y, .w = companionScaled(3.0), .h = rect.h }, color(chrome.accent), companionScaled(1.5), clip);
    const title = if (operation.title.slice().len > 0) operation.title.slice() else "Operation details";
    queueBoldText(state, .{ .x = rect.x + companionScaled(11.0), .y = rect.y + companionScaled(8.0), .w = @max(rect.w - companionScaled(86.0), 0.0), .h = companionScaled(16.0) }, title, color(chrome.text), companionScaled(11.0), clip);
    queueBoldText(state, .{ .x = rect.x + @max(rect.w - companionScaled(67.0), 0.0), .y = rect.y + companionScaled(8.0), .w = companionScaled(56.0), .h = companionScaled(16.0) }, operationStatusLabel(operation.status), color(operationStatusColor(chrome, operation.status)), companionScaled(9.0), clip);

    var row_y = rect.y + companionScaled(29.0);
    if (inspectorOutput(operation)) |value| renderInspectorRow(state, clip, rect, &row_y, "Output", value);
    const inspector = &operation.inspector;
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "Owner", inspector.owner.slice());
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "Workspace", inspector.workspace.slice());
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "Action", inspector.action.slice());
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "Target", inspector.target.slice());
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "Provider", inspector.provider.slice());
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "Cwd", inspector.cwd.slice());
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "State", inspector.state.slice());
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "Waiting", inspector.wait_reason.slice());
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "Failure", inspector.failure_reason.slice());
    renderInspectorRowIfPresent(state, clip, rect, &row_y, "Locations", inspector.locations.slice());
    var file_label = true;
    for (inspector.files[0..@min(inspector.file_count, inspector.files.len)]) |*value| if (value.slice().len > 0) {
        renderInspectorRow(state, clip, rect, &row_y, if (file_label) "Files" else "", value.slice());
        file_label = false;
    };
    var resource_label = true;
    for (inspector.resources[0..@min(inspector.resource_count, inspector.resources.len)]) |*value| if (value.slice().len > 0) {
        renderInspectorRow(state, clip, rect, &row_y, if (resource_label) "Resources" else "", value.slice());
        resource_label = false;
    };
    if (inspector.started_at_ms) |value| renderInspectorRow(state, clip, rect, &row_y, "Started", framePrint(state, "{d} ms", .{value}));
    if (inspector.updated_at_ms) |value| renderInspectorRow(state, clip, rect, &row_y, "Updated", framePrint(state, "{d} ms", .{value}));
    if (inspector.elapsed_ms) |value| renderInspectorRow(state, clip, rect, &row_y, "Elapsed", framePrint(state, "{d} ms", .{value}));

    const controls = inspectorControlRects(rect, reference.actions);
    if (controls.stop) |button| renderInspectorButton(state, clip, button, "Stop");
    if (controls.follow_log) |button| renderInspectorButton(state, clip, button, "Follow log");
    y.* += rect.h + companionScaled(7.0);
}

fn renderInspectorRowIfPresent(state: *runtime.AppState, clip: palette.Rect, card: palette.Rect, y: *f32, label: []const u8, value: []const u8) void {
    if (value.len > 0) renderInspectorRow(state, clip, card, y, label, value);
}

fn renderInspectorRow(state: *runtime.AppState, clip: palette.Rect, card: palette.Rect, y: *f32, label: []const u8, value: []const u8) void {
    const chrome = theme.companionChrome();
    const label_w = companionScaled(70.0);
    queueBoldText(state, .{ .x = card.x + companionScaled(11.0), .y = y.*, .w = label_w, .h = companionScaled(15.0) }, label, color(chrome.text_subtle), companionScaled(9.0), clip);
    const value_x = card.x + companionScaled(11.0) + label_w;
    const value_w = @max(card.x + card.w - companionScaled(11.0) - value_x, 0.0);
    queueText(state, .{ .x = value_x, .y = y.*, .w = value_w, .h = companionScaled(15.0) }, truncatedText(state, .ui, companionScaled(10.0), value_w, singleLineText(state, value)), color(chrome.text), companionScaled(10.0), clip);
    y.* += companionScaled(19.0);
}

fn renderInspectorButton(state: *runtime.AppState, clip: palette.Rect, rect: palette.Rect, label: []const u8) void {
    const chrome = theme.companionChrome();
    queuePanelClipped(state, rect, color(chrome.surface), color(chrome.border), companionScaled(7.0), companionScaled(1.0), clip);
    queueCenteredText(state, rect, label, color(chrome.text), companionScaled(10.0), .ui_bold, clip);
}

fn operationStatusLabel(status: controller.OperationStatus) []const u8 {
    return switch (status) {
        .in_progress => "RUNNING",
        .pending => "PENDING",
        .completed => "DONE",
        .failed => "FAILED",
        .cancelled => "STOPPED",
    };
}

fn operationStatusColor(chrome: theme.CompanionChrome, status: controller.OperationStatus) [4]f32 {
    return switch (status) {
        .in_progress => chrome.accent,
        .pending => chrome.text_subtle,
        .completed => chrome.identity_fg,
        .failed => chrome.danger,
        .cancelled => chrome.text_muted,
    };
}

// Active theme inputs shared by character-specific palette derivations.
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
    return state.app_config.companion_character;
}

fn companionCharacterName(character: app_config.CompanionCharacter) []const u8 {
    return switch (character) {
        .sprout => "Sprout",
        .moss => "Moss",
        .vireo => "Vireo",
    };
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
    const well = theme.lighten(active.background, 0.02);
    const char_surface = theme.lighten(active.background, 0.035);

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
    const char_surface = theme.lighten(active.background, 0.035);
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
    const char_surface = theme.lighten(active.background, 0.035);
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

fn bodyHitRect(hits: []const controller.Hit) palette.Rect {
    for (hits) |hit| if (hit.action == .body) return hit.rect;
    return .{};
}

// Header status states the run posture in words; counts appear only when
// they carry information, so an idle Companion never reads "0 active".
fn headerStatus(state: *runtime.AppState) []const u8 {
    const companion = &state.companion_controller;
    if (companion.needs_approval) return "approval needed";
    if (companion.has_failure) return "needs attention";
    if (companion.run_phase == .paused) return "paused";
    if (companion.run_phase == .working) {
        const counts = companion.presentation.activeCounts();
        const active = counts.working + counts.pending;
        if (active > 0) return framePrint(state, "working · {d} ops", .{active});
        return "working";
    }
    return "ready";
}

fn framePrint(state: *runtime.AppState, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), format, args) catch "";
}

const OperationPreview = struct {
    detail: []const u8,
    result: ?[]const u8,
};

// Splits provider "Command:/Input: … Output: …" transcript bodies into a
// command preview and a result preview. Pure presentation: stored content,
// identity, and status are untouched, and unknown shapes fall back whole.
fn operationPreview(body: []const u8) OperationPreview {
    var detail = body;
    var result: ?[]const u8 = null;
    if (std.mem.indexOf(u8, body, "Output:")) |output_index| {
        const head = std.mem.trim(u8, body[0..output_index], " \t\r\n");
        const tail = std.mem.trim(u8, body[output_index + "Output:".len ..], " \t\r\n");
        if (head.len > 0) {
            detail = head;
            if (tail.len > 0) result = tail;
        } else if (tail.len > 0) {
            detail = tail;
        }
    }
    inline for (.{ "Command:", "Input:" }) |label| {
        if (std.mem.startsWith(u8, detail, label)) {
            const stripped = std.mem.trimStart(u8, detail[label.len..], " \t\r\n");
            if (stripped.len > 0) detail = stripped;
            break;
        }
    }
    return .{ .detail = detail, .result = result };
}

// Successful provider tool output opens with a fixed metadata preamble
// ("CWD:", "Exit code:", "Duration ms:" — see codex.zig formatToolResult).
// Skipping exactly those labeled lines surfaces the first real output as a
// subslice; null means the output carried nothing beyond metadata. This is a
// fixed-label skip, not a heuristic summary, so execution is never misstated.
fn meaningfulResultPreview(result: []const u8) ?[]const u8 {
    var rest = result;
    while (rest.len > 0) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[0..line_end], " \t\r");
        const metadata_only = line.len == 0 or
            std.mem.startsWith(u8, line, "CWD:") or
            std.mem.startsWith(u8, line, "Exit code:") or
            std.mem.startsWith(u8, line, "Duration ms:");
        if (!metadata_only) return std.mem.trim(u8, rest, " \t\r\n");
        if (line_end == rest.len) break;
        rest = rest[line_end + 1 ..];
    }
    return null;
}

// The Result region shows the whole current answer, so it wraps by measured
// width instead of truncating to one row; output stays bounded.
const MAX_RESULT_LINES: usize = 6;
const RESULT_FONT_SIZE: f32 = 11.5;

const ResultLines = struct {
    lines: [MAX_RESULT_LINES][]const u8 = [_][]const u8{""} ** MAX_RESULT_LINES,
    count: usize = 0,
    truncated: bool = false,
};

// Measured greedy wrap for the Result region. Every line is a subslice of the
// input, so Frame-backed storage keeps owning the queued text; embedded
// newlines force breaks and output is bounded to MAX_RESULT_LINES.
fn wrapResultText(text: []const u8, max_width: f32) ResultLines {
    var wrapped: ResultLines = .{};
    if (max_width <= 0.0) return wrapped;
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |paragraph| {
        var remaining = std.mem.trim(u8, paragraph, " \t\r");
        while (remaining.len > 0) {
            if (wrapped.count == MAX_RESULT_LINES) {
                wrapped.truncated = true;
                return wrapped;
            }
            const break_index = measuredLineBreak(remaining, max_width);
            wrapped.lines[wrapped.count] = std.mem.trimEnd(u8, remaining[0..break_index], " \t");
            wrapped.count += 1;
            remaining = std.mem.trimStart(u8, remaining[break_index..], " \t");
        }
    }
    return wrapped;
}

// Longest measured prefix of one line that fits max_width: prefer the last
// space so words stay whole, and fall back to one whole codepoint so the
// wrap always advances. Every probe goes through shared text metrics.
fn measuredLineBreak(text: []const u8, max_width: f32) usize {
    const font_size = companionScaled(RESULT_FONT_SIZE);
    if (text_measure.textWidth(.ui, font_size, text) <= max_width) return text.len;
    var low: usize = 0;
    var high: usize = text.len - 1;
    var best: usize = 0;
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const candidate = utf8FloorIndex(text, mid);
        if (text_measure.textWidth(.ui, font_size, text[0..candidate]) <= max_width) {
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

// Raw transcript bodies may hold multi-line dumps; Companion rows are
// single-line summaries, so collapse whitespace runs before layout. Clean
// text returns the original slice so Frame-backed lifetimes are preserved.
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

// Collapsed chip chrome. The chip sits flush with the right window edge, so
// both the shadow and the panel extend past that edge by the corner radius and
// clip to the window: the visible right edge stays square while the left
// corners stay round, all through the anti-aliased SDF rect path (the old
// triangle-fan rail had no edge AA and read as faceted arcs).
fn appendChipChrome(allocator: std.mem.Allocator, batch: *palette.RenderBatch, geometry: Geometry, scale: f32) !void {
    if (geometry.chip.w < 2.0 * scale or geometry.chip.h < 2.0 * scale) return;
    const radius = @min(10.0 * scale, @min(geometry.chip.h * 0.5, geometry.chip.w));
    const shadow = offsetRect(geometry.chip, 0.0, 8.0 * scale);
    if (rectFitsWindow(shadow, geometry.window.w, geometry.window.h)) {
        try batch.roundedRectClipped(allocator, extendedRight(shadow, radius), color(theme.scrim(0.20)), radius, geometry.window);
    }
    try appendPanel(allocator, batch, extendedRight(geometry.chip, radius), color(surface()), color(theme.companionChrome().border), radius, 1.0 * scale, geometry.window, true);
}

fn extendedRight(rect: palette.Rect, amount: f32) palette.Rect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w + amount, .h = rect.h };
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

fn expectBatchInsideWindow(batch: *const palette.RenderBatch, window: palette.Rect) !void {
    for (batch.commands.items) |command| {
        if (command.clip) |clip| try std.testing.expect(rectFitsWindow(clip, window.w, window.h));
        if (command.kind == .triangle and command.clip == null) {
            inline for (.{ command.p0, command.p1, command.p2 }) |point| {
                try std.testing.expect(point.x >= window.x and point.x <= window.x + window.w);
                try std.testing.expect(point.y >= window.y and point.y <= window.y + window.h);
            }
            continue;
        }
        if (commandEffectiveRect(command)) |rect| try std.testing.expect(rectFitsWindow(rect, window.w, window.h));
    }
}

fn sameColor(a: palette.Color, b: palette.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

test "sidecar geometry stays in bounds at normal narrow and short sizes" {
    inline for (.{
        .{ @as(f32, 1360.0), @as(f32, 860.0) },
        .{ @as(f32, 390.0), @as(f32, 760.0) },
        .{ @as(f32, 480.0), @as(f32, 260.0) },
        .{ @as(f32, 40.0), @as(f32, 30.0) },
        .{ @as(f32, 1.0), @as(f32, 1.0) },
    }) |size| {
        const scale: f32 = if (size[0] <= 40.0) 3.0 else 1.0;
        const geometry = computeGeometry(size[0], size[1], scale);
        try std.testing.expect(geometry.sidecar.x >= 0.0);
        try std.testing.expect(geometry.sidecar.y >= 0.0);
        try std.testing.expect(geometry.sidecar.x + geometry.sidecar.w <= size[0]);
        try std.testing.expect(geometry.sidecar.y + geometry.sidecar.h <= size[1]);
        try std.testing.expect(geometry.body.h >= 0.0);
        inline for (.{ geometry.window, geometry.chip, geometry.chip_character, geometry.chip_hit, geometry.sidecar, geometry.header, geometry.close_button, geometry.objective, geometry.tabs, geometry.body, geometry.footer }) |rect| {
            try std.testing.expect(rect.x >= 0.0);
            try std.testing.expect(rect.y >= 0.0);
            try std.testing.expect(rect.w >= 0.0);
            try std.testing.expect(rect.h >= 0.0);
            try std.testing.expect(rect.x + rect.w <= size[0]);
            try std.testing.expect(rect.y + rect.h <= size[1]);
        }
        const composer = composerRectAtScale(geometry.footer, scale);
        if (composer.w > 0.0 and composer.h > 0.0) {
            try std.testing.expect(composer.x >= geometry.footer.x);
            try std.testing.expect(composer.y >= geometry.footer.y);
            try std.testing.expect(composer.x + composer.w <= geometry.footer.x + geometry.footer.w);
            try std.testing.expect(composer.y + composer.h <= geometry.footer.y + geometry.footer.h);
        } else {
            try std.testing.expectEqual(@as(f32, 0.0), composer.w);
            try std.testing.expectEqual(@as(f32, 0.0), composer.h);
        }
    }
    try std.testing.expectEqual(@as(f32, 404.0), computeGeometry(1360.0, 860.0, 1.0).sidecar.w);
    try std.testing.expectEqual(@as(f32, 374.0), computeGeometry(390.0, 760.0, 1.0).sidecar.w);
}

test "chip chrome renders clipped SDF panels with a square open right edge" {
    const allocator = std.testing.allocator;
    const normal = computeGeometry(1360.0, 860.0, 1.0);
    var normal_batch: palette.RenderBatch = .{};
    defer normal_batch.deinit(allocator);
    try appendChipChrome(allocator, &normal_batch, normal, 1.0);
    try std.testing.expectEqual(@as(usize, 3), normal_batch.commands.items.len);
    const border = color(theme.companionChrome().border);
    const fill = color(surface());
    var saw_underlay = false;
    var saw_fill = false;
    for (normal_batch.commands.items) |command| {
        try std.testing.expectEqual(palette.draw.CommandKind.rect, command.kind);
        // Border-only commands halo white at corner arcs; chip chrome must be
        // fill-only panel commands.
        try std.testing.expect(command.border_color == null);
        // Every chip rect extends past the flush right window edge and clips
        // to the window, keeping the visible right edge square.
        const clip = command.clip orelse return error.MissingChipClip;
        try std.testing.expect(rectEqual(clip, normal.window));
        try std.testing.expect(command.rect.x + command.rect.w > normal.window.w);
        if (sameColor(command.color, border)) saw_underlay = true;
        if (sameColor(command.color, fill)) saw_fill = true;
    }
    try std.testing.expect(saw_underlay and saw_fill);

    inline for (.{
        .{ @as(f32, 40.0), @as(f32, 30.0), @as(f32, 3.0) },
        .{ @as(f32, 1.0), @as(f32, 1.0), @as(f32, 3.0) },
        .{ @as(f32, 180.0), @as(f32, 72.0), @as(f32, 2.0) },
    }) |fixture| {
        const geometry = computeGeometry(fixture[0], fixture[1], fixture[2]);
        var batch: palette.RenderBatch = .{};
        defer batch.deinit(allocator);
        try appendChipChrome(allocator, &batch, geometry, fixture[2]);
        try expectBatchInsideWindow(&batch, geometry.window);
        if (fixture[0] < 2.0 * fixture[2] or fixture[1] < 2.0 * fixture[2]) try std.testing.expectEqual(@as(usize, 0), batch.commands.items.len);
        try std.testing.expectEqual(@as(f32, 0.0), geometry.chip_character.w);
        try std.testing.expectEqual(@as(f32, 0.0), composerRectAtScale(geometry.footer, fixture[2]).w);
    }
}

test "chip chrome snaps panel edges and stroke to device pixels at fractional scales" {
    const allocator = std.testing.allocator;
    const border = color(theme.companionChrome().border);
    const fill = color(surface());
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5) }) |scale| {
        const geometry = computeGeometry(1360.0, 860.0, scale);
        var batch: palette.RenderBatch = .{};
        defer batch.deinit(allocator);
        try appendChipChrome(allocator, &batch, geometry, scale);
        var underlay: ?palette.draw.Command = null;
        var body: ?palette.draw.Command = null;
        for (batch.commands.items) |command| {
            if (sameColor(command.color, border)) underlay = command;
            if (sameColor(command.color, fill)) body = command;
        }
        const outer = underlay orelse return error.MissingChipUnderlay;
        const inner = body orelse return error.MissingChipFill;
        // Chrome edges land on whole device pixels at every scale…
        inline for (.{ outer, inner }) |command| {
            try std.testing.expectEqual(@round(command.rect.x), command.rect.x);
            try std.testing.expectEqual(@round(command.rect.y), command.rect.y);
            try std.testing.expectEqual(@round(command.rect.w), command.rect.w);
            try std.testing.expectEqual(@round(command.rect.h), command.rect.h);
        }
        // …and the fill sits inside the underlay by a whole-pixel stroke, so
        // the visible border is a continuous ring of constant thickness.
        const stroke = inner.rect.x - outer.rect.x;
        try std.testing.expectEqual(@round(stroke), stroke);
        try std.testing.expect(stroke >= 1.0);
        try std.testing.expectEqual(outer.rect.y + stroke, inner.rect.y);
        try std.testing.expectEqual(outer.rect.h - stroke * 2.0, inner.rect.h);
    }
}

test "production collapsed and expanded overlays stay inside the window" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    inline for (.{
        .{ @as(f32, 1360.0), @as(f32, 860.0), @as(f32, 1.0) },
        .{ @as(f32, 900.0), @as(f32, 700.0), @as(f32, 1.25) },
        .{ @as(f32, 390.0), @as(f32, 760.0), @as(f32, 1.0) },
        .{ @as(f32, 480.0), @as(f32, 260.0), @as(f32, 1.0) },
        .{ @as(f32, 40.0), @as(f32, 30.0), @as(f32, 3.0) },
        .{ @as(f32, 1.0), @as(f32, 1.0), @as(f32, 3.0) },
        .{ @as(f32, 2536.0), @as(f32, 1030.0), @as(f32, 1.0) },
    }) |fixture| {
        theme.applyTheme(fixture[2]);
        var state: runtime.AppState = undefined;
        state.allocator = allocator;
        state.app_config = .{};
        state.project_controller = .{};
        state.companion_controller = controller.init();
        state.companion_controller.applyFixture(.idle);
        state.companion_composer = @TypeOf(state.companion_composer).init();
        state.palette_overlay_batch = .{};
        state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
        defer {
            for (state.project_controller.projects.items) |*project| project.deinit(allocator);
            state.project_controller.projects.deinit(allocator);
            state.companion_composer.deinit(allocator);
            state.palette_overlay_batch.deinit(allocator);
            state.palette_frame_text_arena.deinit();
        }
        var project = try runtime.Project.init(allocator, "overlay-bounds", "Overlay", "/tmp/overlay-bounds", 0);
        state.project_controller.projects.append(allocator, project) catch |err| {
            project.deinit(allocator);
            return err;
        };

        const window: palette.Rect = .{ .w = fixture[0], .h = fixture[1] };
        render(&state, fixture[0], fixture[1]);
        try expectBatchInsideWindow(&state.palette_overlay_batch, window);

        state.palette_overlay_batch.clear();
        state.companion_controller.show();
        render(&state, fixture[0], fixture[1]);
        try expectBatchInsideWindow(&state.palette_overlay_batch, window);
    }
}

test "captured scale public render emits a visible complete Companion composer" {
    const allocator = std.testing.allocator;
    const scale: f32 = 5.0 / 3.0;
    const companion_z: i32 = 1550;
    defer theme.applyTheme(1.0);
    theme.applyTheme(scale);
    const saved_colors = theme.current_colors;
    const saved_white = theme.COLOR_WHITE;
    const saved_muted = theme.COLOR_TEXT_MUTED;
    const saved_subtle = theme.COLOR_TEXT_SUBTLE;
    const saved_green = theme.COLOR_GREEN;
    const saved_yellow = theme.COLOR_YELLOW;
    const saved_panel = theme.COLOR_PANEL;
    const saved_panel_alt = theme.COLOR_PANEL_ALT;
    const saved_panel_muted = theme.COLOR_PANEL_MUTED;
    defer {
        theme.current_colors = saved_colors;
        theme.COLOR_WHITE = saved_white;
        theme.COLOR_TEXT_MUTED = saved_muted;
        theme.COLOR_TEXT_SUBTLE = saved_subtle;
        theme.COLOR_GREEN = saved_green;
        theme.COLOR_YELLOW = saved_yellow;
        theme.COLOR_PANEL = saved_panel;
        theme.COLOR_PANEL_ALT = saved_panel_alt;
        theme.COLOR_PANEL_MUTED = saved_panel_muted;
    }
    const extreme = [4]f32{ 1.0, 0.0, 1.0, 1.0 };
    theme.current_colors = theme.default_colors;
    theme.COLOR_WHITE = extreme;
    theme.COLOR_TEXT_MUTED = extreme;
    theme.COLOR_TEXT_SUBTLE = extreme;
    theme.COLOR_GREEN = extreme;
    theme.COLOR_YELLOW = extreme;
    theme.COLOR_PANEL = extreme;
    theme.COLOR_PANEL_ALT = extreme;
    theme.COLOR_PANEL_MUTED = extreme;

    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_controller.applyFixture(.idle);
    state.companion_controller.show();
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "captured-composer", "Captured", "/tmp/captured-composer", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    const initial_thread_count = state.project_controller.projects.items[0].threads.items.len;
    const chrome = theme.companionChrome();
    var frame: controller.Frame = .{ .has_thread = true, .has_approval = true };
    frame.workspace_id.set("captured-composer");
    frame.thread_id.set("pane-less-companion");
    frame.approval_identity.set("approval-1");
    frame.approval_title.set("Run command");
    frame.approval_body.set("Allow this command?");
    state.companion_controller.setFrame(frame);

    _ = state.palette_overlay_batch.setZIndex(companion_z);
    const geometry = computeGeometryForState(2536.0, 1030.0, scale, &state.companion_controller);
    registerHits(&state.companion_controller, geometry, state.companion_controller.presentation.has_approval);
    const immutable_frame = state.companion_controller.presentation;
    render(&state, 2536.0, 1030.0);
    try std.testing.expectEqualDeep(immutable_frame, state.companion_controller.presentation);
    const approval_buttons = approvalButtonRects(geometry.body, state.companion_controller.currentScrollY());
    try std.testing.expectEqual(controller.HitAction.approve, state.companion_controller.hitAt(approval_buttons[1].x + 1.0, approval_buttons[1].y + 1.0).?);
    const composer = composerRectAtScale(geometry.footer, scale);
    try std.testing.expectApproxEqAbs(@as(f32, 404.0), geometry.sidecar.w / scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), geometry.sidecar.y / scale, 0.001);
    try std.testing.expect(rectFitsWindow(composer, geometry.window.w, geometry.window.h));
    try std.testing.expectEqual(composer, state.companion_composer.bounds());
    try std.testing.expect(pointInRect(composer, state.companion_composer.textRect().x, state.companion_composer.textRect().y));
    try std.testing.expect(pointInRect(composer, state.companion_composer.toolbarRect().x, state.companion_composer.toolbarRect().y));
    const send = state.companion_composer.sendButtonRect();
    try std.testing.expectEqual(palette.ComposerPromptPart.send, state.companion_composer.hitTest(.{ .x = send.x + send.w * 0.5, .y = send.y + send.h * 0.5 }).?);

    var saw_panel = false;
    var saw_placeholder = false;
    var saw_workspace = false;
    var saw_send = false;
    var saw_scope_dot = false;
    var saw_scrim = false;
    var saw_run_pill = false;
    var saw_head_rim = false;
    const tabs_track: palette.Rect = .{ .x = geometry.tabs.x + 12.0 * scale, .y = geometry.tabs.y + 10.0 * scale, .w = geometry.tabs.w - 24.0 * scale, .h = geometry.tabs.h - 10.0 * scale };
    const tabs_inner: palette.Rect = .{ .x = tabs_track.x + 3.0 * scale, .y = tabs_track.y + 3.0 * scale, .w = tabs_track.w - 6.0 * scale, .h = tabs_track.h - 6.0 * scale };
    const run_pill: palette.Rect = .{ .x = tabs_inner.x, .y = tabs_inner.y, .w = tabs_inner.w / 2.0, .h = tabs_inner.h };
    const header_sprout: palette.Rect = .{ .x = geometry.header.x + 12.0 * scale, .y = geometry.header.y + 6.5 * scale, .w = 29.0 * scale, .h = 31.0 * scale };
    const sprout_scale = header_sprout.w / 46.0;
    const sprout_face: palette.Rect = .{ .x = header_sprout.x + 5.0 * sprout_scale, .y = header_sprout.y + 12.0 * sprout_scale, .w = 36.0 * sprout_scale, .h = 27.0 * sprout_scale };
    const expected_rim: palette.Rect = .{ .x = sprout_face.x + 5.0 * sprout_scale, .y = sprout_face.y + 3.0 * sprout_scale, .w = sprout_face.w - 10.0 * sprout_scale, .h = 2.0 * sprout_scale };
    const expected_highlight = deriveSproutPalette(activeCharacterTheme()).highlight;
    for (state.palette_overlay_batch.commands.items) |command| {
        if (command.z_index == 120) return error.TestUnexpectedResult;
        if (command.z_index == companion_z and command.kind == .rect and command.rect.x == composer.x and command.rect.y == composer.y and command.rect.w == composer.w and command.rect.h == composer.h) {
            saw_panel = sameColor(command.color, color(chrome.surface)) and command.border_width > 0.0;
        }
        if (command.kind == .text and std.mem.eql(u8, command.text, "Steer the run…")) saw_placeholder = command.z_index == companion_z;
        if (command.kind == .text and std.mem.eql(u8, command.text, "Workspace · verde")) saw_workspace = command.z_index == companion_z;
        if (command.kind == .rect and command.rect.x == send.x and command.rect.y == send.y and command.rect.w == send.w and command.rect.h == send.h) saw_send = command.z_index == companion_z and sameColor(command.color, color(chrome.accent));
        if (command.kind == .rect and command.rect.w == 6.0 * scale and command.rect.h == 6.0 * scale and sameColor(command.color, color(chrome.accent))) saw_scope_dot = command.z_index == companion_z;
        if (command.kind == .rect and command.rect.w == geometry.window.w and command.rect.h == geometry.window.h and sameColor(command.color, color(theme.scrim(0.22)))) saw_scrim = true;
        if (command.kind == .rect and command.rect.x == run_pill.x and command.rect.y == run_pill.y and command.rect.w == run_pill.w and command.rect.h == run_pill.h and sameColor(command.color, color(chrome.surface))) saw_run_pill = true;
        if (command.kind == .rect and command.rect.x == expected_rim.x and command.rect.y == expected_rim.y and command.rect.w == expected_rim.w and command.rect.h == expected_rim.h and sameColor(command.color, color(expected_highlight))) {
            const clip = command.clip orelse return error.MissingHeadRimClip;
            saw_head_rim = clip.x == sprout_face.x and clip.y == sprout_face.y and clip.w == sprout_face.w and clip.h == sprout_face.h and
                command.rect.x >= sprout_face.x and command.rect.x + command.rect.w <= sprout_face.x + sprout_face.w and
                command.rect.y >= sprout_face.y and command.rect.y + command.rect.h <= sprout_face.y + sprout_face.h * 0.35;
        }
    }
    if (!saw_panel) return error.MissingCompanionPanel;
    if (!saw_placeholder) return error.MissingCompanionPlaceholder;
    if (!saw_workspace) return error.MissingCompanionWorkspace;
    if (!saw_send) return error.MissingCompanionSend;
    if (!saw_scope_dot) return error.MissingCompanionScopeDot;
    if (!saw_scrim) return error.MissingCompanionScrim;
    if (!saw_run_pill) return error.MissingCompanionRunPill;
    if (!saw_head_rim) return error.MissingClippedHeadRim;
    try std.testing.expectEqual(chrome.surface, [4]f32{ state.companion_composer.style.background_color.r, state.companion_composer.style.background_color.g, state.companion_composer.style.background_color.b, state.companion_composer.style.background_color.a });
    try std.testing.expectEqual(chrome.text, [4]f32{ state.companion_composer.style.text_color.r, state.companion_composer.style.text_color.g, state.companion_composer.style.text_color.b, state.companion_composer.style.text_color.a });
    try std.testing.expectEqual(chrome.selection, [4]f32{ state.companion_composer.style.selection_color.r, state.companion_composer.style.selection_color.g, state.companion_composer.style.selection_color.b, state.companion_composer.style.selection_color.a });
    try std.testing.expectEqual(chrome.menu_selected, [4]f32{ state.companion_composer.style.menu_selected_color.r, state.companion_composer.style.menu_selected_color.g, state.companion_composer.style.menu_selected_color.b, state.companion_composer.style.menu_selected_color.a });
    try std.testing.expect(state.project_controller.projects.items[0].companion_thread_local_id == null);
    try std.testing.expectEqual(initial_thread_count, state.project_controller.projects.items[0].threads.items.len);
    state.companion_controller.applyFixture(.needs_approval);
    state.palette_overlay_batch.clear();
    _ = state.palette_overlay_batch.setZIndex(companion_z);
    render(&state, 2536.0, 1030.0);
    var saw_warning = false;
    for (state.palette_overlay_batch.commands.items) |command| {
        saw_warning = saw_warning or sameColor(command.color, color(chrome.warning));
    }
    if (!saw_warning) return error.MissingThemeWarning;

    state.companion_controller.applyFixture(.failed);
    state.palette_overlay_batch.clear();
    _ = state.palette_overlay_batch.setZIndex(companion_z);
    render(&state, 2536.0, 1030.0);
    var saw_theme_danger = false;
    for (state.palette_overlay_batch.commands.items) |command| {
        saw_theme_danger = saw_theme_danger or sameColor(command.color, color(theme.danger()));
    }
    if (!saw_theme_danger) return error.MissingThemeDanger;

    state.companion_controller.applyFixture(.idle);
    state.companion_composer.setCallbacks(.{});
    _ = try state.companion_composer.handleInput(allocator, .{ .focus = true });
    try std.testing.expect(state.companion_composer.focused);
    state.palette_overlay_batch.clear();
    _ = state.palette_overlay_batch.setZIndex(companion_z);
    render(&state, 2536.0, 1030.0);
    try std.testing.expectEqual(composer, state.companion_composer.bounds());
    var saw_focus_border = false;
    for (state.palette_overlay_batch.commands.items) |command| {
        if (command.kind == .rect and command.rect.x == composer.x and command.rect.y == composer.y and command.rect.w == composer.w and command.rect.h == composer.h) {
            saw_focus_border = command.border_color != null and sameColor(command.border_color.?, color(chrome.accent));
        }
    }
    if (!saw_focus_border) return error.MissingFocusBorder;

    theme.applyTheme(1.0);
    state.palette_overlay_batch.clear();
    _ = state.palette_overlay_batch.setZIndex(companion_z);
    render(&state, 100.0, 300.0);
    const tiny_geometry = computeGeometryForState(100.0, 300.0, 1.0, &state.companion_controller);
    try std.testing.expectEqual(@as(f32, 0.0), composerRectAtScale(tiny_geometry.footer, 1.0).w);
    for (state.palette_overlay_batch.commands.items) |command| {
        try std.testing.expect(!(command.kind == .text and (std.mem.eql(u8, command.text, "Steer the run…") or std.mem.eql(u8, command.text, "Workspace · verde"))));
        try std.testing.expect(!(command.kind == .rect and command.rect.w == 6.0 and command.rect.h == 6.0 and sameColor(command.color, color(chrome.accent))));
    }
}

test "public Companion render retains Frame-backed Run and Activity text" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_controller.show();
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "frame-text", "Frame text", "/tmp/frame-text", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    var operation_title_buffer: [64]u8 = undefined;
    var operation_detail_buffer: [64]u8 = undefined;
    var user_body_buffer: [64]u8 = undefined;
    var assistant_body_buffer: [64]u8 = undefined;
    const operation_title = try std.fmt.bufPrint(&operation_title_buffer, "Read {s}", .{"README.md"});
    const operation_detail = try std.fmt.bufPrint(&operation_detail_buffer, "{s} first heading", .{"Captured"});
    const user_body = try std.fmt.bufPrint(&user_body_buffer, "{s} README.md", .{"Inspect"});
    const assistant_body = try std.fmt.bufPrint(&assistant_body_buffer, "Heading: {s}", .{"Verde"});
    var frame: controller.Frame = .{ .has_thread = true };
    frame.workspace_id.set("frame-text");
    frame.thread_id.set("pane-less-frame-text");
    var operation: controller.Operation = .{ .status = .completed, .sequence = 1 };
    operation.identity.set("tool:stable");
    operation.title.set(operation_title);
    operation.detail.set(operation_detail);
    frame.upsertOperation(operation);
    var user_activity: controller.ActivityItem = .{ .kind = .user, .sequence = 2 };
    user_activity.author.set("You");
    user_activity.body.set(user_body);
    frame.appendActivity(user_activity);
    var assistant_activity: controller.ActivityItem = .{ .kind = .assistant, .sequence = 3 };
    assistant_activity.author.set("Sprout");
    assistant_activity.body.set(assistant_body);
    frame.appendActivity(assistant_activity);
    @memset(&operation_title_buffer, 0);
    @memset(&operation_detail_buffer, 0);
    @memset(&user_body_buffer, 0);
    @memset(&assistant_body_buffer, 0);
    state.companion_controller.setFrame(frame);
    const immutable_frame = state.companion_controller.presentation;
    const geometry = computeGeometryForState(1360.0, 860.0, 1.0, &state.companion_controller);

    render(&state, 1360.0, 860.0);
    try expectClippedTextCommand(&state.palette_overlay_batch, "RECENT", geometry.body);
    try expectFrameBackedTextCommand(&state.palette_overlay_batch, "Read README.md", &state.companion_controller.presentation.operations[0].title, geometry.body);
    try expectFrameBackedTextCommand(&state.palette_overlay_batch, "Captured first heading", &state.companion_controller.presentation.operations[0].detail, geometry.body);
    try std.testing.expectEqualDeep(immutable_frame, state.companion_controller.presentation);

    state.palette_overlay_batch.clear();
    state.companion_controller.selectTab(.activity);
    render(&state, 1360.0, 860.0);
    try expectFrameBackedTextCommand(&state.palette_overlay_batch, "You", &state.companion_controller.presentation.activity[0].author, geometry.body);
    try expectFrameBackedTextCommand(&state.palette_overlay_batch, "Inspect README.md", &state.companion_controller.presentation.activity[0].body, geometry.body);
    try expectFrameBackedTextCommand(&state.palette_overlay_batch, "Sprout", &state.companion_controller.presentation.activity[1].author, geometry.body);
    try expectFrameBackedTextCommand(&state.palette_overlay_batch, "Heading: Verde", &state.companion_controller.presentation.activity[1].body, geometry.body);
    try std.testing.expectEqualDeep(immutable_frame, state.companion_controller.presentation);
}

test "operation preview splits command dumps without altering unknown shapes" {
    const split = operationPreview("Command:\n/usr/bin/bash -lc 'zig build'\n\nOutput:\nBuild passed\nAll steps ok");
    try std.testing.expectEqualStrings("/usr/bin/bash -lc 'zig build'", split.detail);
    try std.testing.expectEqualStrings("Build passed\nAll steps ok", split.result.?);

    const input_form = operationPreview("Input: rg --files\nOutput: file.zig");
    try std.testing.expectEqualStrings("rg --files", input_form.detail);
    try std.testing.expectEqualStrings("file.zig", input_form.result.?);

    const output_only = operationPreview("Output:\njust results");
    try std.testing.expectEqualStrings("just results", output_only.detail);
    try std.testing.expect(output_only.result == null);

    const plain = operationPreview("Captured first heading");
    try std.testing.expectEqualStrings("Captured first heading", plain.detail);
    try std.testing.expect(plain.result == null);
}

test "public Companion render bounds raw multiline Run and Activity dumps" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_controller.show();
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "bounded", "Bounded", "/tmp/bounded", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    const raw_dump = "Command:\n/usr/bin/bash -lc 'find . -maxdepth 2 -type d | sort'\n\nOutput:\n" ++ ("worktree-path-entry\n" ** 24);
    var frame: controller.Frame = .{ .has_thread = true, .working = true };
    frame.workspace_id.set("bounded");
    frame.thread_id.set("pane-less-bounded");
    var operation: controller.Operation = .{ .status = .completed, .sequence = 1 };
    operation.identity.set("tool:bounded");
    operation.title.set("Ran command");
    operation.detail.set(raw_dump);
    frame.upsertOperation(operation);
    var tool_row: controller.ActivityItem = .{ .kind = .tool, .status = .completed, .sequence = 2 };
    tool_row.identity.set("tool:bounded");
    tool_row.author.set("Ran command");
    tool_row.body.set(raw_dump);
    frame.appendActivity(tool_row);
    var user_row: controller.ActivityItem = .{ .kind = .user, .sequence = 3 };
    user_row.author.set("You");
    user_row.body.set("line one\nline two\nline three");
    frame.appendActivity(user_row);
    state.companion_controller.setFrame(frame);
    const geometry = computeGeometryForState(1360.0, 860.0, 1.0, &state.companion_controller);

    render(&state, 1360.0, 860.0);
    try expectNoMultilineText(&state.palette_overlay_batch);
    try expectNoTextCommand(&state.palette_overlay_batch, "Scope");
    try expectBoundedBodyText(&state.palette_overlay_batch, "find . -maxdepth", geometry.body);
    try expectBoundedBodyText(&state.palette_overlay_batch, "worktree-path-entry", geometry.body);
    try expectClippedTextCommand(&state.palette_overlay_batch, "DONE", geometry.body);

    state.palette_overlay_batch.clear();
    state.companion_controller.selectTab(.activity);
    render(&state, 1360.0, 860.0);
    try expectNoMultilineText(&state.palette_overlay_batch);
    try expectBoundedBodyText(&state.palette_overlay_batch, "find . -maxdepth", geometry.body);
    try expectBoundedBodyText(&state.palette_overlay_batch, "line one line two line three", geometry.body);
    try expectClippedTextCommand(&state.palette_overlay_batch, "DONE", geometry.body);
    try expectClippedTextCommand(&state.palette_overlay_batch, "Sprout is working…", geometry.body);
}

test "public Companion render surfaces streaming final empty and failed Sprout answers in Run" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_controller.show();
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "answer", "Answer", "/tmp/answer", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    // Dynamically populated, non-literal answer text proves Frame-backed
    // lifetime rather than static-string survival.
    var answer_buffer: [96]u8 = undefined;
    const answer_body = try std.fmt.bufPrint(&answer_buffer, "# {s} — native workspace shell", .{"Verde"});
    var frame: controller.Frame = .{ .has_thread = true, .working = true };
    frame.workspace_id.set("answer");
    frame.thread_id.set("pane-less-answer");
    frame.objective.set("Read README.md and report its first heading");
    frame.answer.set(answer_body);
    @memset(&answer_buffer, 0);
    state.companion_controller.setFrame(frame);
    const geometry = computeGeometryForState(1360.0, 860.0, 1.0, &state.companion_controller);

    // Streaming: the in-progress answer is visible and labeled WORKING.
    render(&state, 1360.0, 860.0);
    try expectFrameBackedTextCommand(&state.palette_overlay_batch, "# Verde — native workspace shell", &state.companion_controller.presentation.answer, geometry.body);
    try expectClippedTextCommand(&state.palette_overlay_batch, "SPROUT SAYS", geometry.body);
    try expectBoundedBodyText(&state.palette_overlay_batch, "WORKING", geometry.body);

    // Completion keeps the final answer visible and labels it DONE.
    var done_frame = state.companion_controller.presentation;
    done_frame.working = false;
    state.companion_controller.setFrame(done_frame);
    state.palette_overlay_batch.clear();
    render(&state, 1360.0, 860.0);
    try expectFrameBackedTextCommand(&state.palette_overlay_batch, "# Verde — native workspace shell", &state.companion_controller.presentation.answer, geometry.body);
    try expectBoundedBodyText(&state.palette_overlay_batch, "DONE", geometry.body);

    // A new turn before the first delta shows a truthful placeholder, not the
    // old answer.
    var pending_frame: controller.Frame = .{ .has_thread = true, .working = true };
    pending_frame.workspace_id.set("answer");
    pending_frame.thread_id.set("pane-less-answer");
    pending_frame.objective.set("Now summarize CONTRIBUTING.md");
    state.companion_controller.setFrame(pending_frame);
    state.palette_overlay_batch.clear();
    render(&state, 1360.0, 860.0);
    try expectClippedTextCommand(&state.palette_overlay_batch, "Working — no reply yet.", geometry.body);
    try expectNoTextCommand(&state.palette_overlay_batch, "# Verde — native workspace shell");

    // A failed turn reports FAILED without inventing an answer, while the
    // provider and control errors stay visible as cards.
    var failed_frame: controller.Frame = .{ .has_thread = true, .answer_failed = true, .has_failure = true };
    failed_frame.workspace_id.set("answer");
    failed_frame.thread_id.set("pane-less-answer");
    failed_frame.objective.set("Now summarize CONTRIBUTING.md");
    failed_frame.provider_error.set("Send failed: provider exited");
    failed_frame.control_error.set("Approval decision failed");
    state.companion_controller.setFrame(failed_frame);
    state.palette_overlay_batch.clear();
    render(&state, 1360.0, 860.0);
    try expectClippedTextCommand(&state.palette_overlay_batch, "The run failed before replying.", geometry.body);
    try expectBoundedBodyText(&state.palette_overlay_batch, "FAILED", geometry.body);
    try expectBoundedBodyText(&state.palette_overlay_batch, "provider exited", geometry.body);
    try expectClippedTextCommand(&state.palette_overlay_batch, "Action failed", geometry.body);
    try expectNoTextCommand(&state.palette_overlay_batch, "DONE");
}

test "public Companion render leads with the answer and suppresses metadata-only success detail" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_controller.show();
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "evidence", "Evidence", "/tmp/evidence", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    const metadata_dump = "Command:\n/usr/bin/bash -lc \"sed -n '1,12p' README.md\"\n\nOutput:\nCWD: /home/rtg/development/verde\nExit code: 0\nDuration ms: 0";
    const output_dump = "Command:\n/usr/bin/bash -lc 'cat VERSION'\n\nOutput:\nCWD: /home/rtg/development/verde\nExit code: 0\nDuration ms: 4\n\n0.4.2-dev";
    const failed_dump = "Command:\n/usr/bin/bash -lc 'zig build'\n\nOutput:\nCWD: /tmp\nExit code: 1\nDuration ms: 12";
    var answer_buffer: [64]u8 = undefined;
    const answer_body = try std.fmt.bufPrint(&answer_buffer, "The first heading is {s}", .{"# Verde"});
    var frame: controller.Frame = .{ .has_thread = true };
    frame.workspace_id.set("evidence");
    frame.thread_id.set("pane-less-evidence");
    frame.objective.set("Read README.md and report its first heading");
    frame.answer.set(answer_body);
    @memset(&answer_buffer, 0);
    var metadata_op: controller.Operation = .{ .status = .completed, .sequence = 1 };
    metadata_op.identity.set("tool:metadata");
    metadata_op.title.set("Ran command");
    metadata_op.detail.set(metadata_dump);
    frame.upsertOperation(metadata_op);
    var output_op: controller.Operation = .{ .status = .completed, .sequence = 2 };
    output_op.identity.set("tool:output");
    output_op.title.set("Ran command");
    output_op.detail.set(output_dump);
    frame.upsertOperation(output_op);
    var failed_op: controller.Operation = .{ .status = .failed, .sequence = 3 };
    failed_op.identity.set("tool:failed");
    failed_op.title.set("Command failed");
    failed_op.detail.set(failed_dump);
    frame.upsertOperation(failed_op);
    state.companion_controller.setFrame(frame);
    const geometry = computeGeometryForState(1360.0, 860.0, 1.0, &state.companion_controller);

    render(&state, 1360.0, 860.0);
    // The completed README-like answer is queued in Run, above the evidence.
    try expectFrameBackedTextCommand(&state.palette_overlay_batch, "The first heading is # Verde", &state.companion_controller.presentation.answer, geometry.body);
    try std.testing.expect(try textCommandY(&state.palette_overlay_batch, "SPROUT SAYS") < try textCommandY(&state.palette_overlay_batch, "RECENT"));
    // Metadata-only success reads as a truthful completion, real output and
    // failure diagnostics survive, and successful metadata never renders.
    try expectClippedTextCommand(&state.palette_overlay_batch, "Completed successfully", geometry.body);
    try expectBoundedBodyText(&state.palette_overlay_batch, "0.4.2-dev", geometry.body);
    try expectBoundedBodyText(&state.palette_overlay_batch, "Exit code: 1", geometry.body);
    try expectNoTextCommandContaining(&state.palette_overlay_batch, "Duration ms: 0");
    try expectNoTextCommandContaining(&state.palette_overlay_batch, "Duration ms: 4");
}

test "public Companion render clears stale failure posture while failed evidence remains" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "posture", "Posture", "/tmp/posture", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    // Newer successful turn: global posture is clean even though an older
    // failed operation remains retained as evidence.
    var success_frame: controller.Frame = .{ .has_thread = true };
    success_frame.workspace_id.set("posture");
    success_frame.thread_id.set("pane-less-posture");
    success_frame.objective.set("i meant read teh readme.md and use read tools");
    success_frame.answer.set("The first heading is **Verde**.");
    var old_failure: controller.Operation = .{ .status = .failed, .sequence = 1 };
    old_failure.identity.set("tool:old-failure");
    old_failure.title.set("Command failed");
    old_failure.detail.set("Command:\n/usr/bin/bash -lc \"sed -n '1,12p' redme.md\"\n\nOutput:\nCWD: /tmp\nExit code: 2");
    success_frame.upsertOperation(old_failure);
    state.companion_controller.setFrame(success_frame);

    // Collapsed chip: no stale "failed" detail and no danger accent.
    try std.testing.expectEqual(ChipDetail.none, chipVisual(&state.companion_controller).detail);
    try std.testing.expect(!chipVisual(&state.companion_controller).uses_danger);
    render(&state, 1360.0, 860.0);
    try expectNoTextCommand(&state.palette_overlay_batch, "failed");

    // Expanded header: ready, not needs-attention, while the failed card
    // stays red in Recent and the successful answer leads Run.
    state.companion_controller.show();
    const geometry = computeGeometryForState(1360.0, 860.0, 1.0, &state.companion_controller);
    state.palette_overlay_batch.clear();
    render(&state, 1360.0, 860.0);
    try expectClippedTextCommand(&state.palette_overlay_batch, "ready", geometry.header);
    try expectNoTextCommand(&state.palette_overlay_batch, "needs attention");
    try expectClippedTextCommand(&state.palette_overlay_batch, "FAILED", geometry.body);
    try expectClippedTextCommand(&state.palette_overlay_batch, "The first heading is **Verde**.", geometry.body);

    // A genuinely current failure still reads globally red in the header and
    // on the collapsed chip.
    var failed_frame: controller.Frame = .{ .has_thread = true, .has_failure = true, .answer_failed = true };
    failed_frame.workspace_id.set("posture");
    failed_frame.thread_id.set("pane-less-posture");
    failed_frame.objective.set("i meant read teh readme.md and use read tools");
    failed_frame.provider_error.set("Send failed: provider exited");
    failed_frame.upsertOperation(old_failure);
    state.companion_controller.setFrame(failed_frame);
    state.palette_overlay_batch.clear();
    render(&state, 1360.0, 860.0);
    try expectClippedTextCommand(&state.palette_overlay_batch, "needs attention", geometry.header);
    try expectClippedTextCommand(&state.palette_overlay_batch, "The run failed before replying.", geometry.body);
    state.companion_controller.collapse();
    const chip_geometry = computeGeometryForState(1360.0, 860.0, 1.0, &state.companion_controller);
    state.palette_overlay_batch.clear();
    render(&state, 1360.0, 860.0);
    try expectClippedTextCommand(&state.palette_overlay_batch, "failed", chip_geometry.chip);
}

test "meaningful result preview skips only the fixed metadata preamble" {
    try std.testing.expect(meaningfulResultPreview("CWD: /home/x\nExit code: 0\nDuration ms: 3") == null);
    try std.testing.expectEqualStrings("real output\nsecond line", meaningfulResultPreview("CWD: /home/x\nExit code: 0\nDuration ms: 3\n\nreal output\nsecond line").?);
    try std.testing.expectEqualStrings("Duration measured in weeks", meaningfulResultPreview("Duration measured in weeks").?);
    try std.testing.expect(meaningfulResultPreview("   \n\t\n") == null);
}

fn expectNoTextCommandContaining(batch: *const palette.RenderBatch, forbidden: []const u8) !void {
    for (batch.commands.items) |command| {
        if (command.kind == .text and std.mem.indexOf(u8, command.text, forbidden) != null) return error.UnexpectedTextCommand;
    }
}

fn textCommandY(batch: *const palette.RenderBatch, needle: []const u8) !f32 {
    for (batch.commands.items) |command| {
        if (command.kind == .text and std.mem.eql(u8, command.text, needle)) return command.rect.y;
    }
    return error.MissingExpectedText;
}

fn expectNoMultilineText(batch: *const palette.RenderBatch) !void {
    for (batch.commands.items) |command| {
        if (command.kind != .text) continue;
        try std.testing.expect(std.mem.indexOfScalar(u8, command.text, '\n') == null);
    }
}

fn expectNoTextCommand(batch: *const palette.RenderBatch, forbidden: []const u8) !void {
    for (batch.commands.items) |command| {
        if (command.kind == .text and std.mem.eql(u8, command.text, forbidden)) return error.UnexpectedTextCommand;
    }
}

fn expectBoundedBodyText(batch: *const palette.RenderBatch, needle: []const u8, clip: palette.Rect) !void {
    for (batch.commands.items) |command| {
        if (command.kind != .text or std.mem.indexOf(u8, command.text, needle) == null) continue;
        const command_clip = command.clip orelse continue;
        if (!rectEqual(command_clip, clip)) continue;
        try expectTextCommandInsideClip(command, clip);
        const role = command.font_role orelse return error.MissingTextRole;
        try std.testing.expect(text_measure.textWidth(role, command.font_size, command.text) <= command.rect.w + 0.5);
        return;
    }
    return error.MissingBoundedBodyText;
}

fn expectClippedTextCommand(batch: *const palette.RenderBatch, expected: []const u8, clip: palette.Rect) !void {
    for (batch.commands.items) |command| {
        if (command.kind != .text or !std.mem.eql(u8, command.text, expected)) continue;
        try expectTextCommandInsideClip(command, clip);
        return;
    }
    return error.MissingExpectedText;
}

fn expectFrameBackedTextCommand(batch: *const palette.RenderBatch, expected: []const u8, backing: *const controller.PresentationText, clip: palette.Rect) !void {
    for (batch.commands.items) |command| {
        if (command.kind != .text or !std.mem.eql(u8, command.text, expected)) continue;
        // Chrome may repeat the same string with another clip (header "Sprout"),
        // so select the body-clipped command before asserting Frame backing.
        const command_clip = command.clip orelse continue;
        if (!rectEqual(command_clip, clip)) continue;
        try expectTextCommandInsideClip(command, clip);
        const text_start = @intFromPtr(command.text.ptr);
        const storage_start = @intFromPtr(&backing.storage[0]);
        if (text_start < storage_start) return error.TextStartsBeforeFrameStorage;
        if (text_start + command.text.len > storage_start + backing.storage.len) return error.TextEndsAfterFrameStorage;
        return;
    }
    return error.MissingExpectedFrameText;
}

fn expectTextCommandInsideClip(command: palette.draw.Command, expected_clip: palette.Rect) !void {
    const clip = command.clip orelse return error.MissingExpectedTextClip;
    if (!rectEqual(clip, expected_clip)) return error.UnexpectedTextClip;
    if (command.rect.x < clip.x or command.rect.y < clip.y) return error.TextStartsOutsideClip;
    if (command.rect.x + command.rect.w > clip.x + clip.w) return error.TextEndsOutsideClip;
    if (command.rect.y + command.rect.h > clip.y + clip.h) return error.TextEndsBelowClip;
}

test "public Companion render repaints active chrome without reconstructing state" {
    const allocator = std.testing.allocator;
    const saved_colors = theme.current_colors;
    defer theme.current_colors = saved_colors;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);

    var first = theme.default_colors;
    first.background = testRgb(0x18, 0x13, 0x27);
    first.text = testRgb(0xee, 0xe8, 0xfb);
    first.text_muted = testRgb(0xb2, 0xa7, 0xc4);
    first.text_subtle = testRgb(0x86, 0x7a, 0x96);
    first.accent = testRgb(0xa2, 0x70, 0xe2);
    first.border = testRgb(0x69, 0x50, 0x7e);
    first.border_muted = testRgb(0x4d, 0x40, 0x59);
    first.warning = testRgb(0xea, 0xb3, 0x4a);
    first.diff_remove = testRgb(0xe7, 0x5b, 0x72);

    var second = theme.default_colors;
    second.background = testRgb(0xe9, 0xee, 0xe7);
    second.text = testRgb(0x22, 0x35, 0x31);
    second.text_muted = testRgb(0x55, 0x69, 0x63);
    second.text_subtle = testRgb(0x73, 0x82, 0x7d);
    second.accent = testRgb(0xbd, 0x45, 0x5b);
    second.border = testRgb(0x70, 0x92, 0x8b);
    second.border_muted = testRgb(0x9b, 0xad, 0xa8);
    second.warning = second.accent;
    second.diff_remove = second.accent;

    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "chrome-repaint", "Chrome", "/tmp/chrome-repaint", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    state.companion_controller.presentation.has_thread = true;
    state.companion_controller.presentation.latest_body.set("Active operation");
    state.companion_controller.applyFixture(.working);

    theme.current_colors = first;
    const first_chrome = theme.companionChrome();
    render(&state, 1360.0, 860.0);
    try expectBatchColor(&state.palette_overlay_batch, .rect, first_chrome.surface);
    state.palette_overlay_batch.clear();
    state.companion_controller.show();
    render(&state, 1360.0, 860.0);
    const geometry = computeGeometryForState(1360.0, 860.0, 1.0, &state.companion_controller);
    try expectExpandedChrome(&state, geometry, first_chrome, false);

    theme.current_colors = second;
    const second_chrome = theme.companionChrome();
    try std.testing.expect(!colorsEqual(first_chrome.surface, second_chrome.surface));
    try std.testing.expect(!colorsEqual(first_chrome.surface_deep, second_chrome.surface_deep));
    state.palette_overlay_batch.clear();
    state.companion_controller.collapse();
    render(&state, 1360.0, 860.0);
    try expectBatchColor(&state.palette_overlay_batch, .rect, second_chrome.surface);
    state.palette_overlay_batch.clear();
    state.companion_controller.show();
    render(&state, 1360.0, 860.0);
    try expectExpandedChrome(&state, geometry, second_chrome, false);

    state.palette_overlay_batch.clear();
    var failed_frame: controller.Frame = .{ .has_thread = true, .has_failure = true };
    var failed_operation: controller.Operation = .{ .status = .failed };
    failed_operation.identity.set("chrome-repaint-failure");
    failed_operation.title.set("Command failed");
    failed_operation.detail.set("Active operation");
    failed_frame.upsertOperation(failed_operation);
    state.companion_controller.setFrame(failed_frame);
    render(&state, 1360.0, 860.0);
    try expectExpandedChrome(&state, geometry, second_chrome, true);
}

test "Companion chrome derives from default active tokens while Sprout geometry stays unchanged" {
    const chrome = theme.companionChromeFor(theme.default_colors);
    try expectColorApprox(theme.mix(theme.default_colors.background, theme.default_colors.text, 0.045), chrome.surface, 2.0 / 255.0);
    try expectColorApprox(theme.mix(theme.default_colors.background, theme.default_colors.text, 0.025), chrome.surface_deep, 2.0 / 255.0);
    try expectColorApprox(theme.mix(theme.default_colors.background, theme.default_colors.text, 0.12), chrome.hairline, 2.0 / 255.0);
    try std.testing.expectEqual(theme.default_colors.accent, chrome.accent);
    try std.testing.expectEqual(theme.default_colors.warning, chrome.warning);
    try std.testing.expectEqual(theme.default_colors.diff_remove, chrome.danger);
    const rect: palette.Rect = .{ .x = 100.0, .y = 50.0, .w = 46.0, .h = 48.0 };
    const leaf = sproutLeafPoints(rect, 0.0);
    try std.testing.expectEqual(@as(f32, 29.0), leaf[1].x - leaf[0].x);
    try std.testing.expectEqual(@as(f32, 13.0), leaf[3].y - leaf[1].y);
    try std.testing.expect(leaf[1].x > leaf[0].x and leaf[1].y < leaf[0].y);
}

test "arbitrary active token sets produce distinct adaptive Companion chrome" {
    var first = theme.default_colors;
    first.background = testRgb(0x17, 0x12, 0x25);
    first.text = testRgb(0xf0, 0xe9, 0xff);
    first.text_muted = testRgb(0xb3, 0xa7, 0xc8);
    first.text_subtle = testRgb(0x87, 0x7b, 0x9a);
    first.accent = testRgb(0xa4, 0x70, 0xe5);
    first.border = testRgb(0x68, 0x4d, 0x80);
    first.border_muted = testRgb(0x4b, 0x3d, 0x59);
    first.warning = testRgb(0xec, 0xb4, 0x4b);
    first.diff_remove = testRgb(0xe9, 0x5b, 0x72);

    var second = theme.default_colors;
    second.background = testRgb(0xf2, 0xee, 0xdf);
    second.text = testRgb(0x24, 0x34, 0x30);
    second.text_muted = testRgb(0x58, 0x6a, 0x65);
    second.text_subtle = testRgb(0x72, 0x80, 0x7b);
    second.accent = testRgb(0x1c, 0x82, 0x79);
    second.border = testRgb(0x69, 0x8e, 0x87);
    second.border_muted = testRgb(0x9b, 0xad, 0xa8);
    second.warning = testRgb(0xb5, 0x70, 0x18);
    second.diff_remove = testRgb(0xc8, 0x40, 0x56);

    const first_chrome = theme.companionChromeFor(first);
    const second_chrome = theme.companionChromeFor(second);
    try std.testing.expect(!colorsEqual(first_chrome.surface, second_chrome.surface));
    try std.testing.expect(!colorsEqual(first_chrome.border, second_chrome.border));
    try std.testing.expect(!colorsEqual(first_chrome.accent_hi, second_chrome.accent_hi));
    try std.testing.expect(!colorsEqual(first_chrome.accent, second_chrome.accent));
    try expectChromeContrast(first_chrome);
    try expectChromeContrast(second_chrome);
    try std.testing.expectEqual(first.warning, first_chrome.warning);
    try std.testing.expectEqual(first.diff_remove, first_chrome.danger);
}

test "Companion chrome accepts representative existing dark and light theme tokens" {
    var kanagawa = theme.default_colors;
    kanagawa.background = testRgb(0x1f, 0x1f, 0x28);
    kanagawa.text = testRgb(0xdc, 0xd7, 0xba);
    kanagawa.text_muted = testRgb(0xaa, 0xa3, 0x80);
    kanagawa.text_subtle = testRgb(0x7a, 0x77, 0x6e);
    kanagawa.accent = testRgb(0x7e, 0x9c, 0xd8);
    kanagawa.border = testRgb(0x54, 0x65, 0x8b);
    kanagawa.border_muted = testRgb(0x72, 0x71, 0x69);
    kanagawa.warning = testRgb(0xc0, 0xa3, 0x6e);
    kanagawa.diff_remove = testRgb(0xc3, 0x40, 0x43);

    var light = theme.default_colors;
    light.background = testRgb(0xe1, 0xe2, 0xe7);
    light.text = testRgb(0x37, 0x60, 0xbf);
    light.text_muted = testRgb(0x5e, 0x72, 0xa5);
    light.text_subtle = testRgb(0x79, 0x87, 0xa8);
    light.accent = testRgb(0x2e, 0x7d, 0xe9);
    light.border = testRgb(0x82, 0xa1, 0xd8);
    light.border_muted = testRgb(0xa1, 0xa6, 0xc5);
    light.warning = testRgb(0x8c, 0x6c, 0x3e);
    light.diff_remove = testRgb(0xf5, 0x2a, 0x65);

    inline for (.{ kanagawa, light }) |fixture| {
        const chrome = theme.companionChromeFor(fixture);
        try std.testing.expectEqual(theme.mix(fixture.background, fixture.text, 0.045), chrome.surface);
        try std.testing.expectEqual(fixture.accent, chrome.accent);
        try std.testing.expectEqual(fixture.warning, chrome.warning);
        try std.testing.expectEqual(fixture.diff_remove, chrome.danger);
        try expectChromeContrast(chrome);
    }
}

test "Companion chrome applies bounded contrast fallbacks" {
    var fixture = theme.default_colors;
    fixture.background = testRgb(0x10, 0x10, 0x10);
    fixture.text = testRgb(0xf0, 0xf0, 0xf0);
    fixture.text_subtle = fixture.text;
    fixture.border = fixture.background;
    fixture.border_muted = fixture.background;
    fixture.accent = fixture.background;
    fixture.warning = fixture.background;
    fixture.diff_remove = fixture.background;
    const chrome = theme.companionChromeFor(fixture);
    try expectChromeContrast(chrome);
    try std.testing.expectEqual(fixture.text_subtle, chrome.border);
    try std.testing.expectEqual(fixture.text_subtle, chrome.menu_border);
}

test "Sprout palette derives from representative active dark blue and light themes" {
    var tokyo_night = theme.default_colors;
    tokyo_night.background = testRgb(0x1a, 0x1b, 0x26);
    tokyo_night.panel_muted = testRgb(0x44, 0x4b, 0x6a);
    tokyo_night.text = testRgb(0xa9, 0xb1, 0xd6);
    tokyo_night.text_subtle = theme.mix(tokyo_night.text, tokyo_night.background, 0.52);
    tokyo_night.accent = testRgb(0x7a, 0xa2, 0xf7);
    tokyo_night.border = theme.mix(tokyo_night.accent, tokyo_night.background, 0.44);
    tokyo_night.warning = testRgb(0xe0, 0xaf, 0x68);
    tokyo_night.diff_remove = testRgb(0xf7, 0x76, 0x8e);

    var tokyo_day = theme.default_colors;
    tokyo_day.background = testRgb(0xe1, 0xe2, 0xe7);
    tokyo_day.panel_muted = testRgb(0xa1, 0xa6, 0xc5);
    tokyo_day.text = testRgb(0x37, 0x60, 0xbf);
    tokyo_day.text_subtle = theme.mix(tokyo_day.text, tokyo_day.background, 0.52);
    tokyo_day.accent = testRgb(0x2e, 0x7d, 0xe9);
    tokyo_day.border = theme.mix(tokyo_day.accent, tokyo_day.background, 0.44);
    tokyo_day.warning = testRgb(0x8c, 0x6c, 0x3e);
    tokyo_day.diff_remove = testRgb(0xf5, 0x2a, 0x65);

    inline for (.{ theme.default_colors, tokyo_night, tokyo_day }) |fixture| {
        const source = characterThemeFromColors(fixture);
        try expectSproutPaletteValid(source, deriveSproutPalette(source));
    }
}

test "arbitrary active token sets produce distinct valid Sprout paint" {
    const first: CharacterTheme = .{
        .background = testRgb(0x18, 0x12, 0x26),
        .text = testRgb(0xf1, 0xe9, 0xff),
        .text_subtle = testRgb(0x9d, 0x92, 0xb0),
        .accent = testRgb(0xa5, 0x72, 0xe8),
        .border = testRgb(0x61, 0x48, 0x78),
        .panel_muted = testRgb(0x47, 0x3c, 0x56),
        .warning = testRgb(0xf2, 0xb8, 0x4b),
        .danger = testRgb(0xec, 0x58, 0x71),
    };
    const second: CharacterTheme = .{
        .background = testRgb(0xf3, 0xee, 0xdf),
        .text = testRgb(0x24, 0x35, 0x31),
        .text_subtle = testRgb(0x68, 0x75, 0x70),
        .accent = testRgb(0x1b, 0x82, 0x79),
        .border = testRgb(0x6b, 0x8f, 0x89),
        .panel_muted = testRgb(0xb8, 0xc4, 0xbe),
        .warning = testRgb(0xb8, 0x70, 0x16),
        .danger = testRgb(0xc9, 0x3f, 0x56),
    };
    const first_paint = deriveSproutPalette(first);
    const second_paint = deriveSproutPalette(second);
    try expectSproutPaletteValid(first, first_paint);
    try expectSproutPaletteValid(second, second_paint);
    try std.testing.expect(!colorsEqual(first_paint.head_top, second_paint.head_top));
    try std.testing.expect(!colorsEqual(first_paint.blade_start, second_paint.blade_start));
    try std.testing.expect(!colorsEqual(first_paint.iris_top, second_paint.iris_top));
}

test "Sprout contrast fallbacks use top eye stop and character surface backing" {
    const top_stop_fixture: CharacterTheme = .{
        .background = testRgb(81, 14, 53),
        .text = testRgb(186, 248, 191),
        .text_subtle = testRgb(112, 92, 108),
        .accent = testRgb(224, 208, 104),
        .border = testRgb(90, 72, 84),
        .panel_muted = testRgb(102, 82, 98),
        .warning = testRgb(224, 170, 52),
        .danger = testRgb(18, 224, 232),
    };
    const top_accent_hi = theme.mix(top_stop_fixture.accent, top_stop_fixture.text, 0.28);
    const raw_head_top = theme.mix(top_stop_fixture.text, top_accent_hi, 0.45);
    const raw_head_bottom = theme.mix(top_stop_fixture.text, top_stop_fixture.accent, 0.38);
    const raw_iris_top = theme.mix(top_stop_fixture.text, top_stop_fixture.danger, 0.76);
    const raw_iris_bottom = theme.mix(theme.lighten(top_stop_fixture.background, 0.02), top_stop_fixture.danger, 0.66);
    try std.testing.expect(lumaDistance(raw_iris_top, raw_head_top) < 0.18);
    try std.testing.expect(lumaDistance(theme.mix(raw_iris_top, raw_iris_bottom, 0.5), theme.mix(raw_head_top, raw_head_bottom, 0.5)) >= 0.18);
    const top_result = deriveSproutPalette(top_stop_fixture);
    try std.testing.expectEqual(top_stop_fixture.danger, top_result.iris_top);
    try std.testing.expectEqual(top_stop_fixture.danger, top_result.iris_bottom);

    const backing_fixture: CharacterTheme = .{
        .background = testRgb(18, 52, 108),
        .text = testRgb(184, 133, 139),
        .text_subtle = testRgb(120, 122, 135),
        .accent = testRgb(106, 15, 107),
        .border = testRgb(186, 81, 59),
        .panel_muted = testRgb(78, 82, 116),
        .warning = testRgb(190, 132, 42),
        .danger = testRgb(220, 74, 94),
    };
    const backing_accent_hi = theme.mix(backing_fixture.accent, backing_fixture.text, 0.28);
    const backing_head = theme.mix(
        theme.mix(backing_fixture.text, backing_accent_hi, 0.45),
        theme.mix(backing_fixture.text, backing_fixture.accent, 0.38),
        0.5,
    );
    const backing_surface = theme.lighten(backing_fixture.background, 0.035);
    const raw_outline = theme.mix(backing_fixture.border, backing_fixture.accent, 0.55);
    try std.testing.expect(lumaDistance(raw_outline, backing_surface) < 0.10);
    try std.testing.expect(lumaDistance(raw_outline, backing_head) >= 0.10);
    const backing_result = deriveSproutPalette(backing_fixture);
    try std.testing.expectEqual(backing_fixture.border, backing_result.outline);
}

fn characterThemeFromColors(active: theme.ThemeColors) CharacterTheme {
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

fn expectSproutPaletteValid(source: CharacterTheme, sprout: SproutPalette) !void {
    try std.testing.expect(lumaDistance(sprout.head_top, sprout.iris_top) >= 0.18 or
        (colorsEqual(sprout.iris_top, source.danger) and colorsEqual(sprout.iris_bottom, source.danger)));
    try std.testing.expect(lumaDistance(sprout.outline, sprout.char_surface) >= 0.10 or colorsEqual(sprout.outline, source.text_subtle));
    const body = theme.mix(sprout.torso_top, sprout.torso_bottom, 0.5);
    const growth = theme.mix(sprout.blade_start, sprout.blade_end, 0.5);
    try std.testing.expect(lumaDistance(growth, body) >= 0.06 or colorsEqual(growth, theme.mix(source.accent, sprout.pole_dark, 0.15)));
    try std.testing.expectEqual(source.warning, sprout.warning);
    try std.testing.expectEqual(characterForegroundOn(source.warning, source.text, source.background), sprout.warning_foreground);
    try std.testing.expectEqual(source.danger, sprout.danger);
    try std.testing.expectEqual(theme.mix(theme.lighten(source.background, 0.02), source.danger, 0.40), sprout.eye_ring);
}

fn testRgb(r: u8, g: u8, b: u8) [4]f32 {
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        1.0,
    };
}

fn compositeTest(foreground: [4]f32, background: [4]f32) [4]f32 {
    return theme.mix(background, .{ foreground[0], foreground[1], foreground[2], 1.0 }, foreground[3]);
}

fn expectColorApprox(expected: [4]f32, actual: [4]f32, tolerance: f32) !void {
    for (expected, actual) |expected_channel, actual_channel| {
        try std.testing.expectApproxEqAbs(expected_channel, actual_channel, tolerance);
    }
}

fn expectChromeContrast(chrome: theme.CompanionChrome) !void {
    try std.testing.expect(lumaDistance(chrome.border, chrome.surface) >= 0.10);
    try std.testing.expect(lumaDistance(chrome.menu_border, chrome.surface_deep) >= 0.10);
    try std.testing.expect(lumaDistance(chrome.identity_fg, compositeTest(chrome.ready_fill, chrome.surface_deep)) >= 0.22);
    const approval_backing = compositeTest(chrome.approval_card, chrome.surface);
    try std.testing.expect(lumaDistance(chrome.approval_title, approval_backing) >= 0.30);
    try std.testing.expect(lumaDistance(chrome.approval_body, approval_backing) >= 0.30);
    try std.testing.expect(lumaDistance(chrome.failure_fg, compositeTest(chrome.failure_card, chrome.surface)) >= 0.30);
}

fn expectBatchColor(batch: *const palette.RenderBatch, kind: palette.draw.CommandKind, expected: [4]f32) !void {
    for (batch.commands.items) |command| {
        if (command.kind == kind and sameColor(command.color, color(expected))) return;
    }
    return error.MissingExpectedColor;
}

fn expectExpandedChrome(state: *runtime.AppState, geometry: Geometry, chrome: theme.CompanionChrome, failed: bool) !void {
    const tabs_track: palette.Rect = .{ .x = geometry.tabs.x + 12.0, .y = geometry.tabs.y + 10.0, .w = geometry.tabs.w - 24.0, .h = geometry.tabs.h - 10.0 };
    const tabs_inner: palette.Rect = .{ .x = tabs_track.x + 3.0, .y = tabs_track.y + 3.0, .w = tabs_track.w - 6.0, .h = tabs_track.h - 6.0 };
    const run_pill: palette.Rect = .{ .x = tabs_inner.x, .y = tabs_inner.y, .w = tabs_inner.w / 2.0, .h = tabs_inner.h };
    const card_fill = if (failed) opaqueOver(chrome.surface, chrome.failure_card) else chrome.surface_deep;
    var saw_panel_border = false;
    var saw_panel = false;
    var saw_tabs = false;
    var saw_run = false;
    var saw_card = false;
    var saw_footer_divider = false;
    var saw_scrim = false;
    var saw_broad_shadow = false;
    var saw_near_shadow = false;
    for (state.palette_overlay_batch.commands.items) |command| {
        if (command.kind != .rect) continue;
        if (rectEqual(command.rect, geometry.sidecar) and sameColor(command.color, color(chrome.border))) saw_panel_border = true;
        if (rectEqual(command.rect, insetRect(geometry.sidecar, 1.0)) and sameColor(command.color, color(chrome.surface))) saw_panel = true;
        if (rectEqual(command.rect, insetRect(tabs_track, 1.0)) and sameColor(command.color, color(chrome.surface_deep))) saw_tabs = true;
        if (rectEqual(command.rect, run_pill) and sameColor(command.color, color(chrome.surface))) saw_run = true;
        if (command.rect.x == geometry.body.x + 13.0 and command.rect.w == geometry.body.w - 26.0 and command.rect.h == 70.0 and sameColor(command.color, color(card_fill))) saw_card = true;
        if (command.rect.y == geometry.footer.y and command.rect.h == 1.0 and command.rect.x >= geometry.footer.x + 1.0 and command.rect.x + command.rect.w <= geometry.footer.x + geometry.footer.w - 1.0 and sameColor(command.color, color(chrome.hairline))) saw_footer_divider = true;
        if (rectEqual(command.rect, geometry.window) and sameColor(command.color, color(theme.scrim(0.22)))) saw_scrim = true;
        if (sameColor(command.color, color(theme.scrim(0.16)))) saw_broad_shadow = true;
        if (sameColor(command.color, color(theme.scrim(0.24)))) saw_near_shadow = true;
    }
    try std.testing.expect(saw_panel_border and saw_panel and saw_tabs and saw_run and saw_card and saw_footer_divider);
    try std.testing.expect(saw_scrim and saw_broad_shadow and saw_near_shadow);
    try std.testing.expect(state.companion_composer.style.focus_border_color != null);
    try std.testing.expect(sameColor(state.companion_composer.style.focus_border_color.?, color(chrome.accent)));
    try std.testing.expect(sameColor(state.companion_composer.style.send_color, color(chrome.accent)));
    try std.testing.expect(sameColor(state.companion_composer.style.selection_color, color(chrome.selection)));
    try std.testing.expect(sameColor(state.companion_composer.style.menu_background_color, color(chrome.surface_deep)));
    try std.testing.expect(sameColor(state.companion_composer.style.menu_border_color, color(chrome.menu_border)));
    try std.testing.expect(sameColor(state.companion_composer.style.menu_selected_color, color(chrome.menu_selected)));
}

fn rectEqual(left: palette.Rect, right: palette.Rect) bool {
    return left.x == right.x and left.y == right.y and left.w == right.w and left.h == right.h;
}

fn insetRect(rect: palette.Rect, amount: f32) palette.Rect {
    return .{ .x = rect.x + amount, .y = rect.y + amount, .w = @max(rect.w - amount * 2.0, 0.0), .h = @max(rect.h - amount * 2.0, 0.0) };
}

test "prototype geometry fixes chip rail sidecar chrome and composer footer" {
    const normal = computeGeometry(1360.0, 860.0, 1.0);
    try std.testing.expectEqual(@as(f32, 946.0), normal.sidecar.x);
    try std.testing.expectEqual(@as(f32, 10.0), normal.sidecar.y);
    try std.testing.expectEqual(@as(f32, 404.0), normal.sidecar.w);
    try std.testing.expectEqual(@as(f32, 840.0), normal.sidecar.h);
    try std.testing.expectEqual(@as(f32, 44.0), normal.header.h);
    try std.testing.expectEqual(@as(f32, 116.0), normal.footer.h);
    try std.testing.expectEqual(normal.sidecar.y + normal.sidecar.h, normal.footer.y + normal.footer.h);
    try std.testing.expectEqual(@as(f32, 36.0), normal.chip.h);
    try std.testing.expectEqual(@as(f32, 20.0), normal.window.h - normal.chip.y - normal.chip.h);
    try std.testing.expectEqual(normal.window.w, normal.chip.x + normal.chip.w);
    try std.testing.expectEqual(@as(f32, 46.0), normal.chip_character.w);
    try std.testing.expectEqual(@as(f32, 48.0), normal.chip_character.h);
    const composer = composerRect(normal.footer);
    try std.testing.expectEqual(@as(f32, 380.0), composer.w);
    try std.testing.expectEqual(@as(f32, 94.0), composer.h);
    try std.testing.expect(pointInRect(normal.sidecar, composer.x, composer.y));

    const captured = computeGeometry(2536.0, 1030.0, 1.0);
    try std.testing.expectEqual(@as(f32, 103.0), captured.chip.w);
    try std.testing.expectEqual(@as(f32, 2433.0), captured.chip.x);
    try std.testing.expectEqual(@as(f32, 974.0), captured.chip.y);
    // The old 176×44 rail covered the captured terminal status; the accepted
    // idle rail occupies only its intrinsic 103×36 bottom-right footprint.
    try std.testing.expect(captured.chip.x > 2536.0 - 176.0);

    const narrow = computeGeometry(390.0, 260.0, 1.0);
    try std.testing.expectEqual(@as(f32, 8.0), narrow.sidecar.x);
    try std.testing.expectEqual(@as(f32, 8.0), narrow.sidecar.y);
    try std.testing.expect(narrow.footer.h > 0.0);
    const high_scale = computeGeometry(1000.0, 900.0, 2.0);
    try std.testing.expectEqual(@as(f32, 808.0), high_scale.sidecar.w);
    try std.testing.expectEqual(@as(f32, 88.0), high_scale.header.h);
}

test "chip semantic copy reserves amber approval and danger only for failure" {
    var state = controller.init();
    state.applyFixture(.idle);
    try std.testing.expectEqual(ChipDetail.none, chipVisual(&state).detail);
    try std.testing.expect(!chipVisual(&state).show_approval);
    try std.testing.expect(!chipVisual(&state).uses_danger);
    try std.testing.expectEqual(@as(f32, 103.0), chipWidth(&state, 1.0));

    state.applyFixture(.working);
    try std.testing.expectEqual(ChipDetail.working, chipVisual(&state).detail);
    try std.testing.expect(!chipVisual(&state).uses_danger);
    state.applyFixture(.needs_approval);
    try std.testing.expectEqual(ChipDetail.working, chipVisual(&state).detail);
    try std.testing.expect(chipVisual(&state).show_approval);
    try std.testing.expect(!chipVisual(&state).uses_danger);
    state.applyFixture(.paused);
    try std.testing.expectEqual(ChipDetail.paused, chipVisual(&state).detail);
    try std.testing.expect(chipVisual(&state).show_approval);
    try std.testing.expect(!chipVisual(&state).uses_danger);
    state.applyFixture(.failed);
    try std.testing.expectEqual(ChipDetail.failed, chipVisual(&state).detail);
    try std.testing.expect(!chipVisual(&state).show_approval);
    try std.testing.expect(chipVisual(&state).uses_danger);
}

test "dedicated hits include Sprout overflow and preserve outside pass through" {
    const geometry = computeGeometry(900.0, 700.0, 1.0);
    var state = controller.init();
    registerHits(&state, geometry, false);
    try std.testing.expectEqual(@as(usize, 1), state.hit_count);
    try std.testing.expect(state.hitAt(geometry.chip_character.x + 2.0, geometry.chip_character.y + 2.0) == .open);
    try std.testing.expect(state.hitAt(10.0, 10.0) == null);

    state.show();
    registerHits(&state, geometry, false);
    try std.testing.expectEqual(@as(usize, 5), state.hit_count);
    try std.testing.expect(state.hitAt(geometry.sidecar.x + 2.0, geometry.sidecar.y + geometry.header.h + 2.0) == .panel);
    try std.testing.expect(state.hitAt(geometry.body.x + 2.0, geometry.body.y + 2.0) == .body);
    try std.testing.expect(state.hitAt(10.0, 10.0) == null);
    try std.testing.expect(!pointInRect(geometry.sidecar, 10.0, 10.0));

    registerHits(&state, geometry, true);
    try std.testing.expectEqual(@as(usize, 7), state.hit_count);
    const buttons = approvalButtonRects(geometry.body, state.currentScrollY());
    try std.testing.expect(state.hitAt(buttons[1].x + 1.0, buttons[1].y + 1.0) == .approve);
}

test "production hit refresh follows one approval projection snapshot" {
    const allocator = std.testing.allocator;
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.companion_controller = controller.init();
    state.companion_controller.show();
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }
    var project = try runtime.Project.init(allocator, "approval-hits", "Approval", "/tmp/approval-hits", 0);
    const thread = try project.ensureCompanionThread(allocator);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    refreshHits(&state, 900.0, 700.0);
    try std.testing.expectEqual(@as(usize, 5), state.companion_controller.hit_count);

    thread.send_state.status = .pending;
    thread.send_state.pending_approval = .{
        .call_id = try std.heap.page_allocator.dupe(u8, "call"),
        .title = try std.heap.page_allocator.dupe(u8, "Approve"),
        .body = try std.heap.page_allocator.dupe(u8, "Proceed?"),
    };
    refreshHits(&state, 900.0, 700.0);
    try std.testing.expectEqual(@as(usize, 7), state.companion_controller.hit_count);

    thread.send_state.approval_decision = .approve;
    refreshHits(&state, 900.0, 700.0);
    try std.testing.expectEqual(@as(usize, 5), state.companion_controller.hit_count);

    thread.send_state.approval_decision = null;
    thread.send_state.control_error_message = try std.heap.page_allocator.dupe(u8, "rejected");
    refreshHits(&state, 900.0, 700.0);
    try std.testing.expectEqual(@as(usize, 7), state.companion_controller.hit_count);
    try std.testing.expect(state.companion_controller.has_failure);

    const stale_title = state.companion_controller.presentation.approval_title;
    thread.send_state.mutex.lock();
    thread.send_state.approval_decision = .approve;
    refreshHits(&state, 900.0, 700.0);
    try std.testing.expectEqualStrings(stale_title.slice(), state.companion_controller.presentation.approval_title.slice());
    try std.testing.expectEqual(@as(usize, 7), state.companion_controller.hit_count);
    thread.send_state.mutex.unlock();

    refreshHits(&state, 900.0, 700.0);
    try std.testing.expectEqual(@as(usize, 5), state.companion_controller.hit_count);
}

test "production hit refresh clears cross-owner approval under contention and retains same owner frame" {
    const allocator = std.testing.allocator;
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.companion_controller = controller.init();
    state.companion_controller.show();
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }
    var project_a = try runtime.Project.init(allocator, "owner-a", "Owner A", "/tmp/owner-a", 0);
    _ = try project_a.ensureCompanionThread(allocator);
    state.project_controller.projects.append(allocator, project_a) catch |err| {
        project_a.deinit(allocator);
        return err;
    };
    var project_b = try runtime.Project.init(allocator, "owner-b", "Owner B", "/tmp/owner-b", 1);
    _ = try project_b.ensureCompanionThread(allocator);
    state.project_controller.projects.append(allocator, project_b) catch |err| {
        project_b.deinit(allocator);
        return err;
    };
    const thread_a = state.threadByLocalId("owner-a", state.project_controller.projects.items[0].companion_thread_local_id.?).?;
    thread_a.send_state.status = .pending;
    thread_a.send_state.pending_approval = .{
        .call_id = try std.heap.page_allocator.dupe(u8, "approval-a"),
        .title = try std.heap.page_allocator.dupe(u8, "Owner A approval"),
        .body = try std.heap.page_allocator.dupe(u8, "Approve A?"),
    };
    refreshHits(&state, 900.0, 700.0);
    try std.testing.expectEqualStrings("owner-a", state.companion_controller.presentation.workspace_id.slice());
    try std.testing.expectEqual(@as(usize, 7), state.companion_controller.hit_count);

    state.companion_controller.selectTab(.activity);
    state.companion_controller.activity_scroll_y = 40.0;
    state.project_controller.selected_index = 1;
    try std.testing.expect(!state.resolveCurrentCompanionApproval(.approve));
    const thread_b = state.threadByLocalId("owner-b", state.project_controller.projects.items[1].companion_thread_local_id.?).?;
    try std.testing.expect(thread_b.send_state.approval_decision == null);
    thread_b.send_state.mutex.lock();
    refreshHits(&state, 900.0, 700.0);
    try std.testing.expectEqualStrings("owner-b", state.companion_controller.presentation.workspace_id.slice());
    try std.testing.expect(!state.companion_controller.presentation.has_approval);
    try std.testing.expectEqual(controller.Tab.run, state.companion_controller.selected_tab);
    try std.testing.expectEqual(@as(f32, 0.0), state.companion_controller.activity_scroll_y);
    try std.testing.expectEqual(@as(usize, 5), state.companion_controller.hit_count);
    thread_b.send_state.mutex.unlock();

    thread_b.send_state.status = .pending;
    thread_b.send_state.pending_approval = .{
        .call_id = try std.heap.page_allocator.dupe(u8, "approval-b"),
        .title = try std.heap.page_allocator.dupe(u8, "Owner B approval"),
        .body = try std.heap.page_allocator.dupe(u8, "Approve B?"),
    };
    refreshHits(&state, 900.0, 700.0);
    const owner_b_frame = state.companion_controller.presentation;
    const owner_b_hit_count = state.companion_controller.hit_count;
    thread_b.send_state.mutex.lock();
    refreshHits(&state, 900.0, 700.0);
    try std.testing.expectEqualDeep(owner_b_frame, state.companion_controller.presentation);
    try std.testing.expectEqual(owner_b_hit_count, state.companion_controller.hit_count);
    thread_b.send_state.mutex.unlock();
}

// Only the shared composer inside the footer may emit Palette border
// commands; all companion-authored chrome must land as filled panel commands.
fn expectNoBorderOnlyChrome(state: *runtime.AppState, width: f32, height: f32) !void {
    const geometry = computeGeometryForState(width, height, companionScale(), &state.companion_controller);
    for (state.palette_overlay_batch.commands.items) |command| {
        if (command.border_color == null) continue;
        try std.testing.expect(command.rect.x >= geometry.footer.x);
        try std.testing.expect(command.rect.y >= geometry.footer.y);
    }
}

// Regression for the white-fringe defect behind the "chopped borders"
// screenshot: Palette border-only commands carry a transparent-white fill and
// the SDF shader composites every anti-aliased border fringe toward that
// fill, so bare strokes halo white along all corner arcs. Every bordered
// companion path must therefore render as filled panel underlays.
test "companion chrome draws no border-only commands outside the shared composer" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25) }) |scale| {
        theme.applyTheme(scale);
        var state: runtime.AppState = undefined;
        state.allocator = allocator;
        state.app_config = .{};
        state.project_controller = .{};
        state.companion_controller = controller.init();
        state.companion_composer = @TypeOf(state.companion_composer).init();
        state.palette_overlay_batch = .{};
        state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
        defer {
            for (state.project_controller.projects.items) |*project| project.deinit(allocator);
            state.project_controller.projects.deinit(allocator);
            state.companion_composer.deinit(allocator);
            state.palette_overlay_batch.deinit(allocator);
            state.palette_frame_text_arena.deinit();
        }
        var project = try runtime.Project.init(allocator, "border-free", "Borders", "/tmp/border-free", 0);
        state.project_controller.projects.append(allocator, project) catch |err| {
            project.deinit(allocator);
            return err;
        };
        // One rich frame reaches every bordered path at once: result card,
        // completed/pending/failed operation cards with avatars and the
        // pending status ring, plus the approval card and its buttons.
        var frame: controller.Frame = .{ .has_thread = true, .has_approval = true };
        frame.workspace_id.set("border-free");
        frame.thread_id.set("pane-less-border-free");
        frame.objective.set("Exercise every bordered chrome path");
        frame.answer.set("A reply that renders the result card.");
        frame.approval_identity.set("approval-borders");
        frame.approval_title.set("Permission required");
        frame.approval_body.set("Approve?");
        var completed: controller.Operation = .{ .status = .completed, .sequence = 1 };
        completed.identity.set("op-completed");
        completed.title.set("MCP tool");
        completed.detail.set("verde.list_panes");
        frame.upsertOperation(completed);
        var pending: controller.Operation = .{ .status = .pending, .sequence = 2 };
        pending.identity.set("op-pending");
        pending.title.set("Queued step");
        pending.detail.set("waiting");
        frame.upsertOperation(pending);
        var failed_op: controller.Operation = .{ .status = .failed, .sequence = 3 };
        failed_op.identity.set("op-failed");
        failed_op.title.set("Command failed");
        failed_op.detail.set("exit 1");
        frame.upsertOperation(failed_op);
        state.companion_controller.setFrame(frame);

        render(&state, 2536.0, 1030.0);
        try expectNoBorderOnlyChrome(&state, 2536.0, 1030.0);

        state.palette_overlay_batch.clear();
        state.companion_controller.show();
        render(&state, 2536.0, 1030.0);
        try expectNoBorderOnlyChrome(&state, 2536.0, 1030.0);

        state.companion_controller.selectTab(.activity);
        state.palette_overlay_batch.clear();
        render(&state, 2536.0, 1030.0);
        try expectNoBorderOnlyChrome(&state, 2536.0, 1030.0);
    }
}

// Regression: fractional display scales produce non-integral chrome geometry.
// Panels must land on whole device pixels with the dividers inset inside the
// side borders, so the sidecar outline reads as one continuous crisp ring.
test "expanded sidecar chrome snaps to device pixels at a fractional scale" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.25);
    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_controller.applyFixture(.idle);
    state.companion_controller.show();
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "snap-scale", "Snap", "/tmp/snap-scale", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    render(&state, 1360.0, 860.0);
    const chrome = theme.companionChrome();
    const geometry = computeGeometryForState(1360.0, 860.0, 1.25, &state.companion_controller);
    const outer = snappedRect(geometry.sidecar);
    // The raw geometry really is fractional at this scale, so the assertions
    // below prove snapping rather than restating integral inputs.
    try std.testing.expect(geometry.sidecar.x != outer.x or geometry.sidecar.y != outer.y);
    var saw_outer = false;
    var saw_inner = false;
    var saw_divider = false;
    for (state.palette_overlay_batch.commands.items) |command| {
        if (command.kind != .rect) continue;
        if (rectEqual(command.rect, outer) and sameColor(command.color, color(chrome.border))) saw_outer = true;
        if (rectEqual(command.rect, insetRect(outer, 1.0)) and sameColor(command.color, color(chrome.surface))) saw_inner = true;
        // Hairline dividers are the wide short strips; they must be integral
        // and stay strictly between the panel's side borders.
        if (sameColor(command.color, color(chrome.hairline)) and command.rect.w >= outer.w - 4.0 and command.rect.h <= 2.0) {
            try std.testing.expectEqual(@round(command.rect.x), command.rect.x);
            try std.testing.expectEqual(@round(command.rect.y), command.rect.y);
            try std.testing.expectEqual(@round(command.rect.w), command.rect.w);
            try std.testing.expect(command.rect.x >= outer.x + 1.0);
            try std.testing.expect(command.rect.x + command.rect.w <= outer.x + outer.w - 1.0);
            saw_divider = true;
        }
    }
    try std.testing.expect(saw_outer and saw_inner and saw_divider);
}

test "saved companion character changes chip and header labels and render batches" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);
    theme.current_colors = theme.default_colors;

    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{};
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_controller.applyFixture(.idle);
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "character-switch", "Character", "/tmp/character-switch", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    const characters = [_]app_config.CompanionCharacter{ .sprout, .moss, .vireo };
    const names = [_][]const u8{ "Sprout", "Moss", "Vireo" };
    var collapsed_counts: [3]usize = undefined;
    var expanded_counts: [3]usize = undefined;

    inline for (characters, 0..) |character, index| {
        state.app_config.companion_character = character;
        state.companion_controller.collapse();
        state.palette_overlay_batch.clear();
        _ = state.palette_frame_text_arena.reset(.retain_capacity);
        render(&state, 1360.0, 860.0);
        collapsed_counts[index] = state.palette_overlay_batch.commands.items.len;
        try expectBatchText(&state.palette_overlay_batch, names[index]);
        if (index > 0) try std.testing.expect(collapsed_counts[index] != collapsed_counts[0] or !std.mem.eql(u8, names[index], names[0]));

        state.companion_controller.show();
        state.palette_overlay_batch.clear();
        _ = state.palette_frame_text_arena.reset(.retain_capacity);
        render(&state, 1360.0, 860.0);
        expanded_counts[index] = state.palette_overlay_batch.commands.items.len;
        try expectBatchText(&state.palette_overlay_batch, names[index]);
    }

    try std.testing.expect(collapsed_counts[0] != collapsed_counts[1] or collapsed_counts[1] != collapsed_counts[2]);
    try std.testing.expect(expanded_counts[0] != expanded_counts[1] or expanded_counts[1] != expanded_counts[2]);
}

test "companion characters produce distinct collapsed and expanded batches at 1.0 and 1.25 scales" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.current_colors = theme.default_colors;

    inline for (.{ @as(f32, 1.0), @as(f32, 1.25) }) |scale| {
        theme.applyTheme(scale);
        var state: runtime.AppState = undefined;
        state.allocator = allocator;
        state.app_config = .{};
        state.project_controller = .{};
        state.companion_controller = controller.init();
        state.companion_controller.applyFixture(.idle);
        state.companion_composer = @TypeOf(state.companion_composer).init();
        state.palette_overlay_batch = .{};
        state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
        defer {
            for (state.project_controller.projects.items) |*project| project.deinit(allocator);
            state.project_controller.projects.deinit(allocator);
            state.companion_composer.deinit(allocator);
            state.palette_overlay_batch.deinit(allocator);
            state.palette_frame_text_arena.deinit();
        }
        var project = try runtime.Project.init(allocator, "scale-chars", "Scale", "/tmp/scale-chars", 0);
        state.project_controller.projects.append(allocator, project) catch |err| {
            project.deinit(allocator);
            return err;
        };

        var collapsed: [3]usize = undefined;
        var expanded: [3]usize = undefined;
        inline for (.{ app_config.CompanionCharacter.sprout, .moss, .vireo }, 0..) |character, index| {
            state.app_config.companion_character = character;
            state.companion_controller.collapse();
            state.palette_overlay_batch.clear();
            render(&state, 1360.0 * scale, 860.0 * scale);
            collapsed[index] = state.palette_overlay_batch.commands.items.len;
            try std.testing.expect(collapsed[index] > 0);

            state.companion_controller.show();
            state.palette_overlay_batch.clear();
            render(&state, 1360.0 * scale, 860.0 * scale);
            expanded[index] = state.palette_overlay_batch.commands.items.len;
            try std.testing.expect(expanded[index] > collapsed[index]);
        }
        try std.testing.expect(collapsed[0] != collapsed[1] or collapsed[1] != collapsed[2]);
        try std.testing.expect(expanded[0] != expanded[1] or expanded[1] != expanded[2]);
    }
}

test "compact and full character bounds cover chip and header hit targets" {
    const geometry = computeGeometry(1360.0, 860.0, 1.0);
    inline for (.{ app_config.CompanionCharacter.sprout, .moss, .vireo }) |character| {
        const full = fullCharacterRect(geometry.chip_character, character, 1.0);
        const size = fullCharacterSize(character);
        try std.testing.expectApproxEqAbs(size.w, full.w, 0.001);
        try std.testing.expectApproxEqAbs(size.h, full.h, 0.001);
        try std.testing.expect(pointInRect(geometry.chip_hit, full.x + full.w * 0.5, full.y + full.h * 0.5));

        const compact = compactCharacterRect(geometry.header, character, 1.0);
        const compact_size = compactCharacterSize(character);
        try std.testing.expectApproxEqAbs(compact_size.w, compact.w, 0.001);
        try std.testing.expectApproxEqAbs(compact_size.h, compact.h, 0.001);
        try std.testing.expect(pointInRect(geometry.header, compact.x + 1.0, compact.y + 1.0));
    }
}

test "moss and vireo apply approval paused and failed semantic treatments" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.0);
    theme.current_colors = theme.default_colors;
    const chrome = theme.companionChrome();

    inline for (.{ app_config.CompanionCharacter.moss, .vireo }) |character| {
        var state: runtime.AppState = undefined;
        state.allocator = allocator;
        state.app_config = .{ .companion_character = character };
        state.project_controller = .{};
        state.companion_controller = controller.init();
        state.companion_composer = @TypeOf(state.companion_composer).init();
        state.palette_overlay_batch = .{};
        state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
        defer {
            for (state.project_controller.projects.items) |*project| project.deinit(allocator);
            state.project_controller.projects.deinit(allocator);
            state.companion_composer.deinit(allocator);
            state.palette_overlay_batch.deinit(allocator);
            state.palette_frame_text_arena.deinit();
        }
        var project = try runtime.Project.init(allocator, "pose-chars", "Pose", "/tmp/pose-chars", 0);
        state.project_controller.projects.append(allocator, project) catch |err| {
            project.deinit(allocator);
            return err;
        };

        state.companion_controller.applyFixture(.needs_approval);
        state.companion_controller.collapse();
        state.palette_overlay_batch.clear();
        render(&state, 1360.0, 860.0);
        try expectBatchColor(&state.palette_overlay_batch, .rect, chrome.warning);

        state.companion_controller.applyFixture(.paused);
        state.palette_overlay_batch.clear();
        render(&state, 1360.0, 860.0);
        try std.testing.expect(state.palette_overlay_batch.commands.items.len > 0);

        state.companion_controller.applyFixture(.failed);
        state.palette_overlay_batch.clear();
        render(&state, 1360.0, 860.0);
        try expectBatchColor(&state.palette_overlay_batch, .rect, chrome.danger);
        try expectBatchColor(&state.palette_overlay_batch, .rect, theme.danger());
    }
}

test "moss and vireo palettes adapt under default and contrasting themes" {
    const default_theme = characterThemeFromColors(theme.default_colors);
    var contrast = theme.default_colors;
    contrast.background = testRgb(0xf2, 0xee, 0xdf);
    contrast.text = testRgb(0x24, 0x34, 0x30);
    contrast.text_subtle = testRgb(0x72, 0x80, 0x7b);
    contrast.accent = testRgb(0x1c, 0x82, 0x79);
    contrast.border = testRgb(0x69, 0x8e, 0x87);
    contrast.panel_muted = testRgb(0xb8, 0xc4, 0xbe);
    contrast.warning = testRgb(0xb5, 0x70, 0x18);
    contrast.diff_remove = testRgb(0xc8, 0x40, 0x56);
    const contrast_theme = characterThemeFromColors(contrast);

    const moss_default = deriveMossPalette(default_theme);
    const moss_contrast = deriveMossPalette(contrast_theme);
    try std.testing.expect(!colorsEqual(moss_default.moss_mid, moss_contrast.moss_mid));
    try std.testing.expect(!colorsEqual(moss_default.body, moss_contrast.body));
    try std.testing.expectEqual(default_theme.warning, moss_default.warning);
    try std.testing.expectEqual(default_theme.danger, moss_default.danger);
    try std.testing.expectEqual(contrast_theme.warning, moss_contrast.warning);
    try std.testing.expectEqual(contrast_theme.danger, moss_contrast.danger);

    const vireo_default = deriveVireoPalette(default_theme);
    const vireo_contrast = deriveVireoPalette(contrast_theme);
    try std.testing.expect(!colorsEqual(vireo_default.body_back, vireo_contrast.body_back));
    try std.testing.expect(!colorsEqual(vireo_default.eye, vireo_contrast.eye));
    try std.testing.expectEqual(default_theme.danger, vireo_default.danger);
    try std.testing.expectEqual(contrast_theme.danger, vireo_contrast.danger);
}

fn expectBatchText(batch: *const palette.RenderBatch, expected: []const u8) !void {
    for (batch.commands.items) |command| {
        if (command.kind == .text and std.mem.eql(u8, command.text, expected)) return;
    }
    return error.MissingExpectedText;
}

test "exact Run and matching Activity operation hits share one reference" {
    var frame: controller.Frame = .{ .has_thread = true, .working = true };
    try std.testing.expect(frame.setOwner("workspace:inspector", "thread:inspector"));
    var task_id: controller.ExactText = .{};
    try std.testing.expect(task_id.set("task:one"));
    var command: controller.ExactText = .{};
    try std.testing.expect(command.set("run exact task"));
    var target: controller.BackgroundTarget = .{ .identity = .{ .task_id = task_id }, .command = command };
    try std.testing.expect(target.log_path.set("/tmp/exact-task.log"));
    var operation: controller.Operation = .{
        .category = .background_task,
        .status = .in_progress,
        .target = .{ .background_task = target },
        .actions = .{ .inspect = true, .stop = true, .follow_log = true },
    };
    operation.identity.set("operation:one");
    operation.title.set("Run exact operation");
    frame.upsertOperation(operation);
    var matching: controller.ActivityItem = .{ .kind = .tool, .status = .in_progress, .sequence = 1 };
    matching.identity.set("operation:one");
    matching.author.set("Tool");
    matching.body.set("exact activity");
    frame.appendActivity(matching);
    var unrelated: controller.ActivityItem = .{ .kind = .process, .status = .in_progress, .sequence = 2 };
    unrelated.identity.set("operation:other");
    unrelated.author.set("Process");
    unrelated.body.set("unrelated activity");
    frame.appendActivity(unrelated);

    var state = controller.init();
    state.show();
    state.setFrame(frame);
    const reference = frame.operationReference(0).?;
    const geometry = computeGeometryForState(1000.0, 820.0, 1.0, &state);
    prepareAndRegisterHits(&state, geometry);
    var run_selects: usize = 0;
    for (state.hits[0..state.hit_count]) |hit| if (hit.action == .operation_select) {
        run_selects += 1;
        try std.testing.expect(hit.reference.?.eql(&reference));
    };
    try std.testing.expectEqual(@as(usize, 1), run_selects);

    state.toggleOperationSelection(reference);
    const run_height = bodyContentHeight(&state, geometry.body.w);
    prepareAndRegisterHits(&state, geometry);
    var stop_hits: usize = 0;
    var follow_hits: usize = 0;
    for (state.hits[0..state.hit_count]) |hit| switch (hit.action) {
        .operation_stop => {
            stop_hits += 1;
            try std.testing.expect(hit.reference.?.eql(&reference));
        },
        .operation_follow_log => {
            follow_hits += 1;
            try std.testing.expect(hit.reference.?.eql(&reference));
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), stop_hits);
    try std.testing.expectEqual(@as(usize, 1), follow_hits);
    try std.testing.expect(run_height > companionScaled(24.0 + 27.0 + 79.0));

    state.selectTab(.activity);
    prepareAndRegisterHits(&state, geometry);
    var activity_selects: usize = 0;
    stop_hits = 0;
    follow_hits = 0;
    for (state.hits[0..state.hit_count]) |hit| switch (hit.action) {
        .operation_select => {
            activity_selects += 1;
            try std.testing.expect(hit.reference.?.eql(&reference));
        },
        .operation_stop => stop_hits += 1,
        .operation_follow_log => follow_hits += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), activity_selects);
    try std.testing.expectEqual(@as(usize, 1), stop_hits);
    try std.testing.expectEqual(@as(usize, 1), follow_hits);
    try std.testing.expect(state.operationSelected(&reference));

    var inspect_only = frame;
    inspect_only.operations[0].actions = .{ .inspect = true, .reveal = true, .redirect = true };
    state.setFrame(inspect_only);
    const inspect_reference = inspect_only.operationReference(0).?;
    state.toggleOperationSelection(inspect_reference);
    state.selectTab(.run);
    prepareAndRegisterHits(&state, geometry);
    for (state.hits[0..state.hit_count]) |hit| {
        try std.testing.expect(hit.action != .operation_stop);
        try std.testing.expect(hit.action != .operation_follow_log);
    }
}

test "selected inspector renders exact output and omits empty process output" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25) }) |scale| {
        theme.applyTheme(scale);
        var state: runtime.AppState = undefined;
        state.allocator = allocator;
        state.app_config = .{};
        state.project_controller = .{};
        state.companion_controller = controller.init();
        state.lifecycle = .{};
        state.companion_controller.show();
        state.companion_composer = @TypeOf(state.companion_composer).init();
        state.palette_overlay_batch = .{};
        state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
        defer {
            for (state.project_controller.projects.items) |*project| project.deinit(allocator);
            state.project_controller.projects.deinit(allocator);
            state.companion_composer.deinit(allocator);
            state.palette_overlay_batch.deinit(allocator);
            state.palette_frame_text_arena.deinit();
        }
        var project = try runtime.Project.init(allocator, "inspector", "Inspector", "/tmp/inspector", 0);
        state.project_controller.projects.append(allocator, project) catch |err| {
            project.deinit(allocator);
            return err;
        };

        var frame: controller.Frame = .{ .has_thread = true, .working = true };
        try std.testing.expect(frame.setOwner("inspector", "thread:one"));
        var call_id: controller.ExactText = .{};
        try std.testing.expect(call_id.set("call:one"));
        var operation: controller.Operation = .{ .status = .in_progress, .target = .{ .tool_call = call_id } };
        operation.identity.set("operation:one");
        operation.title.set("Inspect operation");
        operation.inspector.output.set("structured output");
        operation.inspector.owner.set("exact owner");
        operation.inspector.workspace.set("exact workspace");
        operation.inspector.action.set("exact action");
        operation.inspector.target.set("exact target");
        operation.inspector.provider.set("exact provider");
        operation.inspector.cwd.set("/tmp/exact cwd");
        operation.inspector.state.set("running");
        operation.inspector.wait_reason.set("waiting reason");
        operation.inspector.failure_reason.set("failure reason");
        operation.inspector.locations.set("line 7");
        operation.inspector.input.set("unsupported input row");
        operation.inspector.raw.set("unsupported raw row");
        operation.inspector.files[0].set("exact-file.zig");
        operation.inspector.file_count = 1;
        operation.inspector.resources[0].set("lease:build");
        operation.inspector.resource_count = 1;
        operation.inspector.started_at_ms = 10;
        operation.inspector.updated_at_ms = 20;
        operation.inspector.elapsed_ms = 30;
        frame.upsertOperation(operation);
        state.companion_controller.setFrame(frame);
        const reference = frame.operationReference(0).?;
        state.companion_controller.toggleOperationSelection(reference);

        render(&state, 1500.0, 1200.0);
        inline for (.{
            "Inspect operation",
            "RUNNING",
            "Output",
            "structured output",
            "Owner",
            "exact owner",
            "Workspace",
            "exact workspace",
            "Action",
            "exact action",
            "Target",
            "exact target",
            "Provider",
            "exact provider",
            "Cwd",
            "/tmp/exact cwd",
            "State",
            "running",
            "Waiting",
            "waiting reason",
            "Failure",
            "failure reason",
            "Locations",
            "line 7",
            "Files",
            "exact-file.zig",
            "Resources",
            "lease:build",
            "Started",
            "10 ms",
            "Updated",
            "20 ms",
            "Elapsed",
            "30 ms",
        }) |expected| try expectBatchText(&state.palette_overlay_batch, expected);
        try expectNoTextCommand(&state.palette_overlay_batch, "unsupported input row");
        try expectNoTextCommand(&state.palette_overlay_batch, "unsupported raw row");
        try expectInspectorBackedTextCommand(&state.palette_overlay_batch, "structured output", &state.companion_controller.presentation.operations[0].inspector.output);
        var saw_selected_card = false;
        const accent = color(theme.companionChrome().accent);
        for (state.palette_overlay_batch.commands.items) |command| {
            if (command.kind == .rect and sameColor(command.color, accent) and
                @abs(command.rect.h - companionScaled(72.0)) <= companionScaled(2.0))
            {
                saw_selected_card = true;
            }
        }
        try std.testing.expect(saw_selected_card);

        var provider_thread_id: controller.ExactText = .{};
        try std.testing.expect(provider_thread_id.set("provider:thread"));
        var process_id: controller.ExactText = .{};
        try std.testing.expect(process_id.set("process:one"));
        var command: controller.ExactText = .{};
        try std.testing.expect(command.set("process-command"));
        var process_target: controller.BackgroundTarget = .{
            .identity = .{ .process = .{
                .provider_thread_id = provider_thread_id,
                .process_id = process_id,
            } },
            .command = command,
            .provider_owned = true,
        };
        try std.testing.expect(process_target.provider_thread_id.set("provider:thread"));
        try std.testing.expect(process_target.process_id.set("process:one"));
        var process_operation: controller.Operation = .{
            .category = .background_task,
            .target = .{ .background_task = process_target },
            .actions = .{ .inspect = true, .stop = true },
            .status = .in_progress,
            .process = true,
        };
        process_operation.identity.set("background:process:one");
        process_operation.title.set("Process operation");
        process_operation.detail.set("process-command");
        process_operation.inspector.action.set("Run process");
        process_operation.inspector.target.set("process:one");
        process_operation.inspector.state.set("running");

        frame.operation_count = 0;
        frame.upsertOperation(process_operation);
        state.companion_controller.setFrame(frame);
        const process_reference = frame.operationReference(0).?;
        state.companion_controller.toggleOperationSelection(process_reference);
        const empty_height = inspectorHeight(&state.companion_controller.presentation.operations[0]);
        const empty_content_height = bodyContentHeight(&state.companion_controller, 404.0 * scale);

        var frame_with_output = frame;
        frame_with_output.operations[0].inspector.output.set("real process output");
        state.companion_controller.setFrame(frame_with_output);
        try std.testing.expectApproxEqAbs(
            empty_height + companionScaled(19.0),
            inspectorHeight(&state.companion_controller.presentation.operations[0]),
            0.001,
        );
        try std.testing.expectApproxEqAbs(
            empty_content_height + companionScaled(19.0),
            bodyContentHeight(&state.companion_controller, 404.0 * scale),
            0.001,
        );

        state.companion_controller.setFrame(frame);
        try std.testing.expect(state.companion_controller.operationSelected(&process_reference));
        const viewport_width = 1500.0;
        const viewport_height = 500.0 * scale;
        const geometry = computeGeometryForState(viewport_width, viewport_height, scale, &state.companion_controller);
        prepareAndRegisterHits(&state.companion_controller, geometry);
        const max_scroll = bodyContentHeight(&state.companion_controller, geometry.body.w) - geometry.body.h;
        try std.testing.expect(max_scroll > 0.0);
        try std.testing.expect(handleWheel(
            &state,
            geometry.body.x + companionScaled(4.0),
            geometry.body.y + companionScaled(4.0),
            -4.0,
        ));
        try std.testing.expectApproxEqAbs(companionScaled(128.0), state.companion_controller.body_scroll_y, 0.001);
        prepareAndRegisterHits(&state.companion_controller, geometry);

        const inspector_rect: palette.Rect = .{
            .x = geometry.body.x + companionScaled(12.0),
            .y = geometry.body.y + companionScaled(12.0) - state.companion_controller.body_scroll_y +
                resultCardHeight(&state.companion_controller.presentation, geometry.body.w) + companionScaled(27.0 + 79.0),
            .w = @max(geometry.body.w - companionScaled(24.0), 0.0),
            .h = empty_height,
        };
        const expected_stop = intersectRects(inspectorControlRects(inspector_rect, process_reference.actions).stop.?, geometry.body).?;
        var saw_stop_hit = false;
        for (state.companion_controller.hits[0..state.companion_controller.hit_count]) |hit| {
            if (hit.action != .operation_stop) continue;
            saw_stop_hit = true;
            try std.testing.expect(hit.reference.?.eql(&process_reference));
            try std.testing.expect(rectEqual(expected_stop, hit.rect));
            try std.testing.expect(intersectRects(hit.rect, geometry.body) != null);
        }
        try std.testing.expect(saw_stop_hit);

        state.palette_overlay_batch.clear();
        _ = state.palette_frame_text_arena.reset(.retain_capacity);
        render(&state, viewport_width, viewport_height);
        try expectNoTextCommand(&state.palette_overlay_batch, "Output");
        try expectNoTextCommand(&state.palette_overlay_batch, "No detail yet.");
        try std.testing.expectEqual(@as(usize, 1), textCommandCount(&state.palette_overlay_batch, "process-command"));
    }
}

fn textCommandCount(batch: *const palette.RenderBatch, expected: []const u8) usize {
    var count: usize = 0;
    for (batch.commands.items) |command| {
        if (command.kind == .text and std.mem.eql(u8, command.text, expected)) count += 1;
    }
    return count;
}

fn expectInspectorBackedTextCommand(batch: *const palette.RenderBatch, expected: []const u8, backing: *const controller.InspectorText) !void {
    for (batch.commands.items) |command| {
        if (command.kind != .text or !std.mem.eql(u8, command.text, expected)) continue;
        const text_start = @intFromPtr(command.text.ptr);
        const storage_start = @intFromPtr(&backing.storage[0]);
        if (text_start < storage_start) return error.TextStartsBeforeInspectorStorage;
        if (text_start + command.text.len > storage_start + backing.storage.len) return error.TextEndsAfterInspectorStorage;
        return;
    }
    return error.MissingExpectedInspectorText;
}

test "Vireo brow arcs instead of a flat bar and pupil rests viewer-left" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25) }) |scale| {
        // Design-space scale matches renderVireo: head is 24 units of a 46-wide portrait.
        const unit = scale;
        const head: palette.Rect = .{ .x = 100.0 * unit, .y = 40.0 * unit, .w = 24.0 * unit, .h = 16.0 * unit };
        const brow = vireoBrowArcPoints(head, unit);
        // Midpoints rise above the ends — the prototype arched supercilium, not a flat ridge.
        try std.testing.expect(brow[1].y < brow[0].y);
        try std.testing.expect(brow[2].y < brow[3].y);
        try std.testing.expect(brow[1].y < brow[0].y - 1.2 * unit);
        try std.testing.expect(brow[2].x > brow[1].x);
        // Front of the arc is still lower than the peak so it reads as an eyebrow, not a straight slash.
        try std.testing.expect(brow[3].y > brow[2].y);

        const eye: palette.Rect = .{ .x = head.x + 14.5 * unit, .y = head.y + 6.7 * unit, .w = 5.5 * unit, .h = 5.5 * unit };
        const pupil = vireoPupilRect(eye, .idle, unit);
        const eye_center_x = eye.x + eye.w * 0.5;
        const pupil_center_x = pupil.x + pupil.w * 0.5;
        // Profile faces right; viewer-left sits left of the eye center (toward the user).
        try std.testing.expect(pupil_center_x < eye_center_x - 0.4 * unit);

        const approval = vireoPupilRect(eye, .approval, unit);
        const approval_center_x = approval.x + approval.w * 0.5;
        try std.testing.expect(approval_center_x > pupil_center_x);
        // Approval may ease toward the badge but must not flip into a hard look-away past center.
        try std.testing.expect(approval_center_x <= eye_center_x + 0.15 * unit);
    }
}

test "Vireo render emits arched brow strokes and viewer-left pupil at fractional scale" {
    const allocator = std.testing.allocator;
    defer theme.applyTheme(1.0);
    theme.applyTheme(1.25);
    theme.current_colors = theme.default_colors;

    var state: runtime.AppState = undefined;
    state.allocator = allocator;
    state.app_config = .{ .companion_character = .vireo };
    state.project_controller = .{};
    state.companion_controller = controller.init();
    state.companion_controller.applyFixture(.idle);
    state.companion_composer = @TypeOf(state.companion_composer).init();
    state.palette_overlay_batch = .{};
    state.palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.companion_composer.deinit(allocator);
        state.palette_overlay_batch.deinit(allocator);
        state.palette_frame_text_arena.deinit();
    }
    var project = try runtime.Project.init(allocator, "vireo-gaze", "Vireo", "/tmp/vireo-gaze", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    state.companion_controller.collapse();
    render(&state, 1360.0 * 1.25, 860.0 * 1.25);
    const geometry = computeGeometryForState(1360.0 * 1.25, 860.0 * 1.25, 1.25, &state.companion_controller);
    const full = fullCharacterRect(geometry.chip_character, .vireo, 1.25);
    const s = full.w / 46.0;
    const head: palette.Rect = .{
        .x = full.x + 22.0 * s,
        .y = full.y + 1.0 * s,
        .w = 24.0 * s,
        .h = 16.0 * s,
    };
    const eye: palette.Rect = .{ .x = head.x + 14.5 * s, .y = head.y + 6.7 * s, .w = 5.5 * s, .h = 5.5 * s };
    const expected_pupil = vireoPupilRect(eye, .idle, s);
    const brow = vireoBrowArcPoints(head, s);
    const paint = deriveVireoPalette(activeCharacterTheme());

    var saw_pupil = false;
    var saw_brow_segment = false;
    for (state.palette_overlay_batch.commands.items) |command| {
        if (command.kind == .rect and rectEqual(command.rect, expected_pupil) and sameColor(command.color, color(paint.pupil))) {
            saw_pupil = true;
        }
        // Arc segments are triangle-fans from queueLine; any brow-colored triangle
        // whose points sit near the arched brow path proves the ridge is stroked.
        if (command.kind == .triangle and sameColor(command.color, color(paint.brow))) {
            const mid_x = (command.p0.x + command.p1.x + command.p2.x) / 3.0;
            const mid_y = (command.p0.y + command.p1.y + command.p2.y) / 3.0;
            if (mid_x >= brow[0].x - 2.0 * s and mid_x <= brow[3].x + 2.0 * s and
                mid_y >= brow[2].y - 3.0 * s and mid_y <= brow[0].y + 3.0 * s)
            {
                saw_brow_segment = true;
            }
        }
    }
    try std.testing.expect(saw_pupil);
    try std.testing.expect(saw_brow_segment);
    try std.testing.expect(expected_pupil.x + expected_pupil.w * 0.5 < eye.x + eye.w * 0.5);
}
