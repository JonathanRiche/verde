//! Renders the composer-owned popovers: the rich model picker, the working
//! directory picker, and the run-configuration panel (reasoning / speed /
//! access steppers).

const std = @import("std");

const palette = @import("palette");

const native_state = @import("../state.zig");
const settings_modal = @import("settings_modal.zig");
const theme = @import("theme.zig");

const log = std.log.scoped(.composer_pickers);

const AppState = native_state.AppState;

pub fn render(state: *AppState) void {
    renderModelPicker(state);
    renderDirectoryPicker(state);
    renderRuntimePicker(state);
    renderRunConfigPopover(state);
}

// Renders the retained working-directory picker anchored to the composer
// directory pill. Entries are rebuilt once on open; only the anchor tracks
// the toolbar while the popover stays up.
fn renderRuntimePicker(state: *AppState) void {
    if (!state.composer_controller.runtime_picker.isOpen()) return;
    state.setPaletteRuntimePickerBoundsFromToolbar();
    state.composer_controller.runtime_picker.render(state.allocator, &state.palette_overlay_batch) catch |err| {
        log.warn("failed to render runtime picker: {s}", .{@errorName(err)});
    };
}

fn renderDirectoryPicker(state: *AppState) void {
    if (!state.composer_controller.directory_picker.isOpen()) return;
    state.setPaletteDirectoryPickerBoundsFromToolbar();
    state.composer_controller.directory_picker.render(state.allocator, &state.palette_overlay_batch) catch |err| {
        log.warn("failed to render composer directory picker: {s}", .{@errorName(err)});
    };
}

// Renders the retained rich model picker anchored to the composer model pill.
fn renderModelPicker(state: *AppState) void {
    // Syncing rebuilds the entry list; skip the work entirely while closed
    // (openPaletteModelPicker syncs before opening).
    if (!state.composer_controller.model_picker.isOpen()) return;
    state.syncPaletteModelPicker();
    state.composer_controller.model_picker.render(state.allocator, &state.palette_overlay_batch) catch |err| {
        log.warn("failed to render composer model picker: {s}", .{@errorName(err)});
    };
}

fn paletteColor(color: [4]f32) palette.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

fn runConfigRowTitle(layout: AppState.RunConfigLayout, index: usize) []const u8 {
    return switch (layout.row_kinds[index]) {
        .reasoning => "Reasoning",
        .speed => "Speed",
        .access => "Access",
    };
}

// Renders the run-configuration popover above the composer run pill: a panel
// of stepped controls consolidating reasoning effort, speed, and access.
fn renderRunConfigPopover(state: *AppState) void {
    if (!state.composer_controller.run_config_open) return;
    state.syncRunConfigSteppers();
    state.tickRunConfigSteppers();
    const layout = state.layoutRunConfigPopover();
    if (layout.row_count == 0 or layout.panel.w <= 0.0) return;

    const batch = &state.palette_overlay_batch;
    const previous_z = batch.setZIndex(native_state.COMPOSER_RUN_CONFIG_Z);
    defer batch.restoreZIndex(previous_z);

    // Same chrome as the rich pickers (model, directory, runtime): menu
    // elevation shadow, panel_alt fill, panel_muted 1px border, 14px radius.
    renderPopoverElevation(state, layout.panel, theme.scaledUi(14.0));
    batch.panel(
        state.allocator,
        layout.panel,
        paletteColor(theme.COLOR_PANEL_ALT),
        paletteColor(theme.COLOR_PANEL_MUTED),
        theme.scaledUi(14.0),
        @max(@round(theme.scaledUi(1.0)), 1.0),
    ) catch |err| {
        log.warn("failed to render run config panel: {s}", .{@errorName(err)});
        return;
    };

    var index: usize = 0;
    while (index < layout.row_count) : (index += 1) {
        const title_rect = layout.title_rects[index];
        const focused = index == state.composer_controller.run_config_focused_row;
        // The focused row title brightens so keyboard users can tell which
        // stepper left/right arrows will adjust.
        const title_color = if (focused) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
        // Row titles are static literals, so they outlive the batch without a
        // frame-arena copy.
        batch.roleText(
            state.allocator,
            title_rect,
            runConfigRowTitle(layout, index),
            paletteColor(title_color),
            // Rich-picker section headers use 12px too.
            theme.scaledUi(12.0),
            .ui,
            null,
            layout.panel,
        ) catch {};
        const stepper = &state.composer_controller.run_steppers[@intFromEnum(layout.row_kinds[index])];
        stepper.setStyle(runStepperStyle());
        stepper.render(state.allocator, batch) catch |err| {
            log.warn("failed to render run config stepper: {s}", .{@errorName(err)});
        };
        renderTrackBorder(state, stepper);
        renderSelectedSegmentBorder(state, stepper);
        if (focused and state.composer_controller.run_config_focus_visible) renderStepperFocusRing(state, stepper);
    }
}

// Keyboard focus ring around the focused row's whole strip, shown only after
// keyboard input (see `run_config_focus_visible`).
fn renderStepperFocusRing(state: *AppState, stepper: anytype) void {
    if (stepper.count == 0) return;
    const first = stepper.segmentRect(0);
    const last = stepper.segmentRect(stepper.count - 1);
    const pad = theme.scaledUi(4.0) + theme.scaledUi(2.0);
    const ring_w = @max(@round(theme.scaledUi(2.0)), 1.0);
    const left = @round(first.x - pad);
    const top = @round(first.y - pad);
    const ring: palette.Rect = .{ .x = left, .y = top, .w = @round(last.x + last.w + pad) - left, .h = @round(first.y + first.h + pad) - top };
    const batch = &state.palette_overlay_batch;
    const previous_z = batch.setZIndex(stepper.z_index);
    defer batch.restoreZIndex(previous_z);
    batch.panel(state.allocator, ring, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 }, paletteColor(theme.accent()), theme.scaledUi(9.0) + pad - 2.0, ring_w) catch |err| {
        log.warn("failed to render run config focus ring: {s}", .{@errorName(err)});
    };
}

/// The context menus' layered drop shadow (`context_menu.queuePanel`), so the
/// popover reads as a layer above the transcript; lighter on light palettes.
fn renderPopoverElevation(state: *AppState, rect: palette.Rect, radius: f32) void {
    const Shadow = struct { spread: f32, drop: f32, alpha: f32 };
    const dark = [_]Shadow{ .{ .spread = 6.0, .drop = 6.0, .alpha = 0.10 }, .{ .spread = 2.0, .drop = 2.0, .alpha = 0.16 } };
    const light = [_]Shadow{.{ .spread = 0.0, .drop = 2.0, .alpha = 0.06 }};
    const layers: []const Shadow = if (theme.isLightPalette()) &light else &dark;
    for (layers) |layer| {
        const spread = theme.scaledUi(layer.spread);
        state.palette_overlay_batch.roundedRect(state.allocator, .{
            .x = rect.x - spread,
            .y = rect.y - spread + theme.scaledUi(layer.drop),
            .w = rect.w + spread * 2.0,
            .h = rect.h + spread * 2.0,
        }, paletteColor(theme.scrim(layer.alpha)), radius + spread) catch {};
    }
}

// Identical to the Settings segmented controls (`settings_modal.drawSegmented`):
// the shared theme track / hover / selected tokens, a 1px track border and
// accent-bordered thumb (drawn after the stepper), and theme text colour.
fn runStepperStyle() palette.StepperStyle {
    const track = theme.segmentedTrackFill();
    return .{
        .track_color = paletteColor(track),
        // Idle segments melt into the track so every row reads as one joined
        // control; hover and the selected thumb mark individual segments.
        .segment_color = paletteColor(track),
        .segment_hover_color = paletteColor(theme.segmentedHoverFill()),
        .segment_selected_color = paletteColor(theme.segmentedSelectedFill(track)),
        .text_color = paletteColor(theme.COLOR_TEXT_MUTED),
        .text_selected_color = paletteColor(theme.COLOR_WHITE),
        .description_color = paletteColor(theme.COLOR_TEXT_MUTED),
    };
}

// The stepper paints its track without a border; Settings' segmented track
// has a 1px edge, so outline the strip the same way (the strip is the
// segments plus the stepper's 4px inner padding).
fn renderTrackBorder(state: *AppState, stepper: anytype) void {
    if (stepper.count == 0) return;
    const first = stepper.segmentRect(0);
    const last = stepper.segmentRect(stepper.count - 1);
    const pad = theme.scaledUi(4.0);
    const left = @round(first.x - pad);
    const top = @round(first.y - pad);
    const strip: palette.Rect = .{ .x = left, .y = top, .w = @round(last.x + last.w + pad) - left, .h = @round(first.y + first.h + pad) - top };
    const batch = &state.palette_overlay_batch;
    const previous_z = batch.setZIndex(stepper.z_index);
    defer batch.restoreZIndex(previous_z);
    const track = theme.segmentedTrackFill();
    batch.panel(state.allocator, strip, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 }, paletteColor(theme.segmentedTrackBorder(track)), settings_modal.segmentedTrackRadius(), @max(@round(theme.scaledUi(1.0)), 1.0)) catch |err| {
        log.warn("failed to render run config track border: {s}", .{@errorName(err)});
    };
}

// The stepper paints its thumb without a border; outline the selected
// segment once the thumb has settled (mid-slide it follows the fill alone).
fn renderSelectedSegmentBorder(state: *AppState, stepper: anytype) void {
    if (stepper.isAnimating()) return;
    const selected = stepper.selected orelse return;
    if (selected >= stepper.count) return;
    const segment = stepper.segmentRect(selected);
    const left = @round(segment.x);
    const top = @round(segment.y);
    const snapped: palette.Rect = .{ .x = left, .y = top, .w = @round(segment.x + segment.w) - left, .h = @round(segment.y + segment.h) - top };
    const batch = &state.palette_overlay_batch;
    const previous_z = batch.setZIndex(stepper.z_index);
    defer batch.restoreZIndex(previous_z);
    batch.panel(
        state.allocator,
        snapped,
        .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
        paletteColor(theme.segmentedSelectedBorder(theme.segmentedTrackFill())),
        settings_modal.segmentedThumbRadius(),
        @max(@round(theme.scaledUi(1.0)), 1.0),
    ) catch |err| {
        log.warn("failed to render run config selection border: {s}", .{@errorName(err)});
    };
}
