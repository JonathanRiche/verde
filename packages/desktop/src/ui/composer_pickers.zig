//! Renders the composer-owned popovers: the rich model picker, the working
//! directory picker, and the run-configuration panel (reasoning / speed /
//! access steppers).

const std = @import("std");

const palette = @import("palette");

const native_state = @import("../state.zig");
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

    batch.panel(
        state.allocator,
        layout.panel,
        paletteColor(theme.COLOR_PANEL_ALT),
        paletteColor(theme.COLOR_PANEL_MUTED),
        theme.scaledUi(14.0),
        @max(theme.scaledUi(1.0), 1.0),
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
            theme.scaledUi(12.5),
            .ui,
            null,
            layout.panel,
        ) catch {};
        const stepper = &state.composer_controller.run_steppers[@intFromEnum(layout.row_kinds[index])];
        stepper.render(state.allocator, batch) catch |err| {
            log.warn("failed to render run config stepper: {s}", .{@errorName(err)});
        };
    }
}
