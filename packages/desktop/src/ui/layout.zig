//! Root native UI composition and modal routing.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const theme = @import("theme.zig");
const colors = @import("colors.zig");
const sidebar = @import("sidebar.zig");
const workspace_panes = @import("workspace_panes.zig");
const runtime = @import("runtime.zig");
const debug_window = @import("debug.zig");
const settings_modal = @import("settings_modal.zig");
const command_palette = @import("command_palette.zig");
const profiler = @import("../profiler.zig");

const RootLayout = struct {
    sidebar: palette.Rect,
    workspace: palette.Rect,
};

const SIDEBAR_ANIM_DURATION_MS: i64 = 180;
/// Above composer overlays (150), pane menus (180), and model cascade (1400).
const PALETTE_MODAL_Z: i32 = 2000;

var sidebar_anim_width: f32 = -1.0;
var sidebar_anim_x: f32 = 0.0;
var sidebar_anim_last_ms: i64 = 0;
var sidebar_animating: bool = false;

/// Updates settings-modal hover using hits from `refreshPaletteModalHits`.
pub fn updateSettingsModalHover(state: *runtime.AppState, x: f32, y: f32) void {
    settings_modal.updateHover(state, x, y);
}

/// Routes wheel input to the settings modal body when it is open.
pub fn handleSettingsModalWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    return settings_modal.handleWheel(state, width, height, x, y, wheel_y);
}

/// Rebuilds palette modal hit targets from the current window size **before** SDL input is
/// processed. `renderRoot` runs after `processEvents`, so hits must not depend on that order.
pub fn refreshPaletteModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    state.palette_modal_hits.clearRetainingCapacity();
    registerProviderOnboardingHits(state, width, height);
    registerMcpOnboardingHits(state, width, height);
    registerImageModalHits(state, width, height);
    registerTranscriptSelectionModalHits(state, width, height);
    registerWorkspaceAddModalHits(state, width, height);
    registerWorkspaceRenameModalHits(state, width, height);
    registerThreadImportModalHits(state, width, height);
    registerHerdrProfilePickerHits(state, width, height);
    settings_modal.registerHits(state, width, height, queueModalHit);
    command_palette.registerHits(state, width, height, queueModalHit);
}

/// Updates command-palette row hover using hits from `refreshPaletteModalHits`.
pub fn updateCommandPaletteHover(state: *runtime.AppState, x: f32, y: f32) void {
    command_palette.updateHover(state, x, y);
}

/// Routes wheel input to the command palette result list when it is open.
pub fn handleCommandPaletteWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    return command_palette.handleWheel(state, width, height, x, y, wheel_y);
}

/// Updates import-modal thread list hover using hits from `refreshPaletteModalHits`.
pub fn updateThreadImportModalHover(state: *runtime.AppState, x: f32, y: f32) void {
    if (state.thread_import_provider == null) {
        if (state.thread_import_hover_index != null) {
            state.thread_import_hover_index = null;
            state.markDirty();
        }
        return;
    }

    var new_hover: ?usize = null;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (hit.action != .thread_import_select) continue;
        if (!rectContainsModalPoint(hit.rect, x, y)) continue;
        new_hover = hit.index;
        break;
    }
    if (new_hover) |hi| {
        if (hi >= state.thread_import_threads.items.len) new_hover = null;
    }

    if (state.thread_import_hover_index == new_hover) return;
    state.thread_import_hover_index = new_hover;
    state.markDirty();
}

/// Updates Herdr profile-picker row hover using hits from `refreshPaletteModalHits`.
pub fn updateHerdrProfilePickerHover(state: *runtime.AppState, x: f32, y: f32) void {
    if (state.herdr_profile_picker_project_index == null) {
        if (state.herdr_profile_hover_index != null) {
            state.herdr_profile_hover_index = null;
            state.markDirty();
        }
        return;
    }

    var new_hover: ?usize = null;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (hit.action != .herdr_profile_select) continue;
        if (!rectContainsModalPoint(hit.rect, x, y)) continue;
        new_hover = hit.index;
        break;
    }
    if (new_hover) |hi| {
        if (hi >= state.herdr_profile_summaries.items.len) new_hover = null;
    }

    if (state.herdr_profile_hover_index == new_hover) return;
    state.herdr_profile_hover_index = new_hover;
    state.markDirty();
}

fn rectContainsModalPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

/// Lays out the root window and routes to the main UI regions.
pub fn renderRoot(state: *runtime.AppState, width: f32, height: f32) void {
    state.resetUiDebugFrame();
    // Re-armed by the sidebar pass when it draws a pulsing pip; the main loop
    // reads the previous frame's value to pace its animation tick.
    state.sidebar_pulse_animating = false;
    const root_layout = computeRootLayout(state, width, height);
    queueRootBackground(state, width, height);
    if (state.isSidebarHidden()) {
        workspace_panes.renderAt(state, root_layout.workspace);
        sidebar.renderPalette(state, root_layout.sidebar);
    } else {
        sidebar.renderPalette(state, root_layout.sidebar);
        workspace_panes.renderAt(state, root_layout.workspace);
    }
    workspace_panes.renderPaneDragPreview(state);
    sidebar.renderFloatingDragPreview(state);
    const modal_z = state.palette_overlay_batch.setZIndex(PALETTE_MODAL_Z);
    defer state.palette_overlay_batch.restoreZIndex(modal_z);
    renderImageModal(state, width, height);
    renderTranscriptSelectionModal(state, width, height);
    renderWorkspaceAddModal(state, width, height);
    renderWorkspaceRenameModal(state, width, height);
    renderThreadImportModal(state, width, height);
    renderHerdrProfilePickerModal(state, width, height);
    renderProviderOnboardingModal(state, width, height);
    renderMcpOnboardingModal(state, width, height);
    settings_modal.render(state, width, height);
    command_palette.render(state, width, height);
    debug_window.render(state, width, height);
}

pub fn isSidebarAnimating() bool {
    return sidebar_animating;
}

fn computeRootLayout(state: *runtime.AppState, width: f32, height: f32) RootLayout {
    const gap: f32 = 0.0;
    const target_sidebar_width = if (state.isSidebarCollapsed())
        theme.clampf(width * 0.07, theme.scaledUi(60.0), theme.scaledUi(76.0))
    else if (width < theme.scaledUi(900.0))
        theme.clampf(width * 0.34, theme.scaledUi(180.0), theme.scaledUi(240.0))
    else
        theme.clampf(width * 0.235, theme.scaledUi(300.0), @min(theme.scaledUi(465.0), width * 0.38));

    const hidden = state.isSidebarHidden();
    const target_sidebar_x = if (hidden and !state.isSidebarHoverRevealed()) -target_sidebar_width else 0.0;
    const now_ms: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    if (sidebar_anim_width < 0.0) {
        sidebar_anim_width = target_sidebar_width;
        sidebar_anim_x = target_sidebar_x;
        sidebar_anim_last_ms = now_ms;
    }
    const dt_ms = @max(now_ms - sidebar_anim_last_ms, 0);
    sidebar_anim_last_ms = now_ms;
    const step = if (SIDEBAR_ANIM_DURATION_MS <= 0)
        1.0
    else
        theme.clampf(@as(f32, @floatFromInt(dt_ms)) / @as(f32, @floatFromInt(SIDEBAR_ANIM_DURATION_MS)), 0.0, 1.0);
    const eased = 1.0 - std.math.pow(f32, 1.0 - step, 3.0);
    sidebar_anim_width = approach(sidebar_anim_width, target_sidebar_width, eased);
    sidebar_anim_x = approach(sidebar_anim_x, target_sidebar_x, eased);
    sidebar_animating = @abs(sidebar_anim_width - target_sidebar_width) > 0.5 or @abs(sidebar_anim_x - target_sidebar_x) > 0.5;

    const layout_sidebar_width = if (hidden) 0.0 else sidebar_anim_width;
    const workspace_width = @max(width - layout_sidebar_width - gap, theme.scaledUi(320.0));
    return .{
        .sidebar = .{ .x = sidebar_anim_x, .y = 0.0, .w = sidebar_anim_width, .h = height },
        .workspace = .{ .x = layout_sidebar_width + gap, .y = 0.0, .w = workspace_width, .h = height },
    };
}

fn approach(current: f32, target: f32, t: f32) f32 {
    return current + (target - current) * t;
}

fn queueRootBackground(state: *runtime.AppState, width: f32, height: f32) void {
    state.palette_overlay_batch.rect(state.allocator, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, paletteColor(theme.background())) catch |err| {
        runtime.log.warn("failed to queue root palette background: {s}", .{@errorName(err)});
    };
}

fn queuePaletteRoundedRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch |err| {
        runtime.log.warn("failed to queue layout palette rounded rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch |err| {
        runtime.log.warn("failed to queue layout palette border: {s}", .{@errorName(err)});
    };
}

fn queuePaletteText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stablePaletteText(state, value) catch |err| {
        runtime.log.warn("failed to retain layout palette text: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.fixedText(
        state.allocator,
        rect,
        stable_value,
        color,
        font_size,
        clip,
        .{},
        font_size * 0.55,
        font_size * 1.25,
        false,
    ) catch |err| {
        runtime.log.warn("failed to queue layout palette text: {s}", .{@errorName(err)});
    };
}

fn stablePaletteText(state: *runtime.AppState, value: []const u8) ![]const u8 {
    return try state.palette_frame_text_arena.allocator().dupe(u8, value);
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn queueModalHit(state: *runtime.AppState, rect: palette.Rect, action: runtime.PaletteModalAction, index: usize) void {
    state.palette_modal_hits.append(state.allocator, .{ .rect = rect, .action = action, .index = index }) catch |err| {
        runtime.log.warn("failed to retain layout modal hit: {s}", .{@errorName(err)});
    };
}

fn drawActionButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, color: [4]f32) void {
    const hovered = pointInRect(state.palette_mouse_x, state.palette_mouse_y, rect);
    const fill = if (hovered) theme.lighten(color, 0.055) else color;
    const border = if (hovered) theme.lighten(color, 0.14) else theme.lighten(color, 0.06);
    queuePaletteRoundedRect(state, rect, paletteColor(fill), theme.scaledUi(7.0));
    queuePaletteBorder(state, rect, paletteColor(border), theme.scaledUi(7.0), theme.scaledUi(if (hovered) 1.5 else 1.0));
    const font_size = theme.scaledUi(14.0);
    const estimated_text_width = @as(f32, @floatFromInt(label.len)) * font_size * 0.52;
    queuePaletteText(state, .{
        .x = rect.x + @max((rect.w - estimated_text_width) * 0.5, theme.scaledUi(4.0)),
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = @max(@min(estimated_text_width + theme.scaledUi(2.0), rect.w - theme.scaledUi(8.0)), theme.scaledUi(8.0)),
        .h = font_size * 1.25,
    }, label, paletteColor(theme.COLOR_WHITE), font_size, rect);
}

fn drawModalChromeVisual(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect) void {
    const scrim: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = width, .h = height };
    queuePaletteRoundedRect(state, scrim, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.68 }, 0.0);
    queuePaletteRoundedRect(state, modal, paletteColor(theme.COLOR_PANEL), theme.scaledUi(12.0));
    queuePaletteBorder(state, modal, paletteColor(theme.withAlpha(theme.borderMuted(), 110)), theme.scaledUi(12.0), theme.scaledUi(1.0));
}

fn registerModalChromeHits(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect, dismissible: bool) void {
    const scrim: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = width, .h = height };
    queueModalHit(state, scrim, if (dismissible) .modal_dismiss else .modal_block, 0);
    queueModalHit(state, modal, .modal_block, 0);
}

fn drawTextField(state: *runtime.AppState, rect: palette.Rect, value: []const u8, hint: []const u8, focused: bool, cursor: usize) void {
    const border = if (focused) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_MUTED;
    queuePaletteRoundedRect(state, rect, paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.03)), theme.scaledUi(7.0));
    queuePaletteBorder(state, rect, paletteColor(border), theme.scaledUi(7.0), theme.scaledUi(1.0));
    const text = if (value.len > 0) value else hint;
    const color = if (value.len > 0) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE;
    const font_size = theme.scaledUi(14.0);
    const text_x = rect.x + theme.scaledUi(10.0);
    const text_y = rect.y + theme.scaledUi(8.0);
    const text_w = rect.w - theme.scaledUi(20.0);

    if (focused) {
        // Cache the input geometry so the mouse/keyboard handlers can
        // hit-test and convert click-x to text offset without re-running
        // the modal layout.
        state.modal_text_input_rect = rect;
        state.modal_text_input_font_size = font_size;
        if (modalSelectionRange(state, value)) |sel| {
            const x0 = text_x + runtime.paletteUiTextPrefixWidth(value, font_size, sel.start);
            const x1 = text_x + runtime.paletteUiTextPrefixWidth(value, font_size, sel.end);
            const clamped_x0 = @max(x0, text_x);
            const clamped_x1 = @min(x1, text_x + text_w);
            if (clamped_x1 > clamped_x0) {
                state.palette_overlay_batch.rect(
                    state.allocator,
                    .{ .x = clamped_x0, .y = text_y, .w = clamped_x1 - clamped_x0, .h = theme.scaledUi(20.0) },
                    paletteColor(theme.withAlpha(theme.selection(), 200)),
                ) catch {};
            }
        }
    }

    const stable_value = stablePaletteText(state, text) catch return;
    state.palette_overlay_batch.roleText(
        state.allocator,
        .{ .x = text_x, .y = text_y, .w = text_w, .h = theme.scaledUi(20.0) },
        stable_value,
        paletteColor(color),
        font_size,
        .ui,
        null,
        rect,
    ) catch {};
    if (focused) {
        const clamped_cursor = @min(cursor, value.len);
        const prefix_w = runtime.paletteUiTextPrefixWidth(value, font_size, clamped_cursor);
        const cursor_x = text_x + prefix_w;
        state.palette_overlay_batch.rect(state.allocator, .{ .x = cursor_x, .y = text_y, .w = theme.scaledUi(1.0), .h = rect.h - theme.scaledUi(16.0) }, paletteColor(theme.COLOR_WHITE)) catch {};
    }
}

const ModalSelectionRange = struct { start: usize, end: usize };

fn modalSelectionRange(state: *runtime.AppState, value: []const u8) ?ModalSelectionRange {
    const anchor = state.modal_text_selection_anchor orelse return null;
    const cursor = focusedCursorReadOnly(state);
    const a = @min(anchor, value.len);
    const c = @min(cursor, value.len);
    if (a == c) return null;
    return .{ .start = @min(a, c), .end = @max(a, c) };
}

fn focusedCursorReadOnly(state: *runtime.AppState) usize {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.project_rename_cursor,
        .thread_import => state.thread_import_cursor,
        .project_import => state.project_import_cursor,
        .command_palette => state.command_palette_cursor,
        .none => 0,
    };
}

fn clearModalSelection(state: *runtime.AppState) void {
    state.modal_text_selection_anchor = null;
}

fn modalOffsetForClickX(value: []const u8, font_size: f32, rel: f32) usize {
    if (value.len == 0 or rel <= 0.0) return 0;
    const total = runtime.paletteUiTextPrefixWidth(value, font_size, value.len);
    if (rel >= total) return value.len;
    var i: usize = 0;
    while (i < value.len) {
        const step = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        const next = @min(i + step, value.len);
        const w_before = runtime.paletteUiTextPrefixWidth(value, font_size, i);
        const w_after = runtime.paletteUiTextPrefixWidth(value, font_size, next);
        if (w_after > rel) {
            return if (rel - w_before <= w_after - rel) i else next;
        }
        i = next;
    }
    return value.len;
}

fn isModalWordChar(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_' or b == '-' or b == '.';
}

fn modalWordBoundsAt(value: []const u8, offset: usize) ModalSelectionRange {
    if (value.len == 0) return .{ .start = 0, .end = 0 };
    var start = @min(offset, value.len);
    var end = start;
    while (start > 0 and isModalWordChar(value[start - 1])) start -= 1;
    while (end < value.len and isModalWordChar(value[end])) end += 1;
    if (start == end and end < value.len) end += 1;
    return .{ .start = start, .end = end };
}

fn focusedValue(state: *runtime.AppState) []const u8 {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.renameInputPublic(),
        .thread_import => state.threadImportThreadId(),
        .project_import => state.importDirectoryDraft(),
        .command_palette => state.commandPaletteQuery(),
        .none => &[_]u8{},
    };
}

/// Removes the active selection from the focused modal buffer, returning true
/// if any bytes were deleted. Cursor is left at the selection's start and the
/// anchor is cleared.
fn deleteModalSelection(state: *runtime.AppState) bool {
    const value = focusedValue(state);
    const sel = modalSelectionRange(state, value) orelse return false;
    const buf = focusedBuffer(state) orelse return false;
    const cursor = focusedCursor(state) orelse return false;
    const current_len = std.mem.sliceTo(buf, 0).len;
    const removed = sel.end - sel.start;
    std.mem.copyForwards(u8, buf[sel.start .. current_len - removed], buf[sel.end..current_len]);
    buf[current_len - removed] = 0;
    cursor.* = sel.start;
    clearModalSelection(state);
    return true;
}

fn copyModalSelection(state: *runtime.AppState) void {
    const value = focusedValue(state);
    const sel = modalSelectionRange(state, value) orelse return;
    const slice = value[sel.start..sel.end];
    if (slice.len == 0) return;
    const z = state.allocator.dupeZ(u8, slice) catch return;
    defer state.allocator.free(z);
    sdl.setClipboardText(z) catch |err| {
        runtime.log.warn("failed to copy modal selection: {s}", .{@errorName(err)});
    };
}

fn pasteIntoModal(state: *runtime.AppState) bool {
    const text = state.readClipboardTextForPaste() orelse return false;
    defer state.allocator.free(text);
    if (text.len == 0) return false;
    _ = deleteModalSelection(state);
    // Modal inputs are single-line; strip control chars from pasted text.
    var sanitized: [4096]u8 = undefined;
    var n: usize = 0;
    for (text) |b| {
        if (b == '\n' or b == '\r' or b == '\t') continue;
        if (n >= sanitized.len) break;
        sanitized[n] = b;
        n += 1;
    }
    if (n == 0) return false;
    const buf = focusedBuffer(state) orelse return false;
    const cursor = focusedCursor(state) orelse return false;
    _ = insertIntoZBuffer(buf, cursor, sanitized[0..n]);
    return true;
}

fn moveModalCursorWithShift(state: *runtime.AppState, target: usize, shift: bool) bool {
    const cursor = focusedCursor(state) orelse return false;
    if (shift) {
        if (state.modal_text_selection_anchor == null) {
            state.modal_text_selection_anchor = cursor.*;
        }
    } else {
        clearModalSelection(state);
    }
    cursor.* = target;
    return true;
}

fn pointInRect(x: f32, y: f32, rect: palette.Rect) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    if (!down) {
        if (state.modal_text_drag_active) state.modal_text_drag_active = false;
    }
    if (state.palette_modal_hits.items.len == 0) return false;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (!pointInRect(x, y, hit.rect)) continue;
        if (hit.action == .project_import_browse) {
            runtime.log.info("workspace import browse hit down={} x={d:.1} y={d:.1}", .{ down, x, y });
            if (!down) state.requestBrowseForProjectDirectory();
            return true;
        }
        if (!down) return true;
        switch (hit.action) {
            .mcp_onboarding_not_now => state.completeMcpOnboarding(false),
            .mcp_onboarding_enable => state.completeMcpOnboarding(true),
            .provider_onboarding_close => state.dismissProviderOnboarding(),
            .provider_onboarding_recheck => state.recheckProviderReadiness(),
            .provider_onboarding_open_guide => state.openProviderSetupGuide(),
            .image_close => state.closeImageModal(),
            .project_rename_cancel => state.cancelProjectRename(),
            .project_rename_submit => state.finishProjectRename(),
            .transcript_close => state.closeTranscriptSelectionModal(),
            .thread_import_refresh => state.refreshThreadImportList(),
            .thread_import_cancel => state.cancelThreadImport(),
            .thread_import_submit => state.importSelectedThread(),
            .thread_import_select => state.selectThreadImport(hit.index),
            .herdr_profile_refresh => state.refreshHerdrProfileList(),
            .herdr_profile_cancel => state.cancelHerdrProfilePicker(),
            .herdr_profile_submit => state.handoffProjectToSelectedHerdrProfile(),
            .herdr_profile_select => state.selectHerdrProfile(hit.index),
            .project_import_browse => unreachable,
            .project_import_submit => {
                state.importProjectFromInput() catch |err| {
                    runtime.log.warn("workspace import failed: {s}", .{@errorName(err)});
                    state.setSidebarNotice("Could not add that directory path.");
                };
            },
            .project_import_create_dir => {
                state.createProjectDirectoryFromInput() catch |err| {
                    runtime.log.warn("workspace directory creation failed: {s}", .{@errorName(err)});
                    state.setSidebarNotice("Could not create that directory path.");
                };
            },
            .project_import_cancel => state.cancelProjectImport(),
            .settings_cancel => state.cancelSettingsModal(),
            .settings_close => state.cancelSettingsModal(),
            .settings_save => {
                if (state.saveSettingsModal()) {
                    state.setSidebarNotice("Settings saved.");
                } else |err| {
                    runtime.log.warn("settings save failed: {s}", .{@errorName(err)});
                    state.setSidebarNotice("Could not save settings to verde.json.");
                }
            },
            .settings_control => settings_modal.applyControl(state, hit.index),
            .settings_theme_option => settings_modal.applyThemeOption(state, hit.index),
            .modal_dismiss => dismissTopModal(state),
            .modal_block => {
                state.palette_modal_text_focus = .none;
                if (state.settings_theme_dropdown_open) {
                    state.settings_theme_dropdown_open = false;
                    state.settings_theme_hover_index = null;
                    state.markDirty();
                }
            },
            .project_rename_input => focusModalInput(state, .project_rename, hit.rect, x, clicks),
            .thread_import_input => focusModalInput(state, .thread_import, hit.rect, x, clicks),
            .project_import_input => focusModalInput(state, .project_import, hit.rect, x, clicks),
            .command_palette_input => focusModalInput(state, .command_palette, hit.rect, x, clicks),
            .command_palette_row => command_palette.activateRow(state, hit.index, false),
            .command_palette_action_row => command_palette.runActionRow(state, hit.index),
        }
        return true;
    }
    return true;
}

/// Click into a modal text field: place the cursor at the click x, set the
/// selection anchor, and prime a drag. Double-click selects the word under
/// the pointer; triple-click selects all.
fn focusModalInput(state: *runtime.AppState, focus: runtime.PaletteModalTextFocus, rect: palette.Rect, x: f32, clicks: u8) void {
    if (state.palette_modal_text_focus != focus) {
        state.palette_modal_text_focus = focus;
        clearModalSelection(state);
    }
    const value = focusedValue(state);
    const font_size = theme.scaledUi(14.0);
    const text_x = rect.x + theme.scaledUi(10.0);
    const rel = @max(x - text_x, 0.0);
    const offset = modalOffsetForClickX(value, font_size, rel);
    const cursor = focusedCursor(state) orelse return;
    if (clicks >= 3) {
        state.modal_text_selection_anchor = 0;
        cursor.* = value.len;
        state.modal_text_drag_active = false;
    } else if (clicks == 2) {
        const bounds = modalWordBoundsAt(value, offset);
        state.modal_text_selection_anchor = bounds.start;
        cursor.* = bounds.end;
        state.modal_text_drag_active = false;
    } else {
        cursor.* = offset;
        state.modal_text_selection_anchor = offset;
        state.modal_text_drag_active = true;
    }
}

/// Routes modal pointer motion and reports whether the workspace is occluded.
pub fn handlePaletteMouseMotion(state: *runtime.AppState, x: f32, _: f32) bool {
    if (state.modal_text_drag_active and state.palette_modal_text_focus != .none) {
        const value = focusedValue(state);
        const rect = state.modal_text_input_rect;
        if (rect.w > 0.0) {
            const text_x = rect.x + theme.scaledUi(10.0);
            const rel = @max(x - text_x, 0.0);
            const offset = modalOffsetForClickX(value, state.modal_text_input_font_size, rel);
            if (focusedCursor(state)) |cursor| cursor.* = offset;
        }
    }
    return state.palette_modal_hits.items.len > 0;
}

/// True while any Palette modal owns pointer input for the window.
pub fn hasPaletteModal(state: *const runtime.AppState) bool {
    return state.palette_modal_hits.items.len > 0;
}

pub fn handlePaletteTextInput(state: *runtime.AppState, text: []const u8) bool {
    if (state.palette_modal_text_focus == .none) return false;
    _ = deleteModalSelection(state);
    return switch (state.palette_modal_text_focus) {
        .project_rename => insertIntoZBuffer(state.renameBuffer(), &state.project_rename_cursor, text),
        .thread_import => insertIntoZBuffer(state.threadImportThreadIdBuffer(), &state.thread_import_cursor, text),
        .project_import => insertIntoZBuffer(state.importPathBuffer(), &state.project_import_cursor, text),
        .command_palette => blk: {
            const inserted = insertIntoZBuffer(state.commandPaletteQueryBuffer(), &state.command_palette_cursor, text);
            state.markDirty();
            break :blk inserted;
        },
        .none => false,
    };
}

pub fn handlePaletteKeyDown(state: *runtime.AppState, event: *const sdl.KeyboardEvent) bool {
    const has_modal_open = state.modal_image_path != null or
        state.mcp_onboarding_visible or
        state.provider_onboarding_visible or
        state.rename_project_index != null or
        state.transcriptSelectionBuffer() != null or
        state.thread_import_provider != null or
        state.herdr_profile_picker_project_index != null or
        state.show_project_creator or
        state.show_settings_modal or
        state.command_palette_open;
    if (!has_modal_open) return false;
    // Palette-owned navigation/activation keys; editing keys fall through to
    // the shared modal text path below.
    if (state.command_palette_open and command_palette.handleKeyDown(state, event)) return true;
    if (state.show_settings_modal and settings_modal.handleKeyDown(state, event.key)) return true;
    const primary = (keymodBits(event.mod) & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
    const shift = (keymodBits(event.mod) & sdl.Keymod.shift) != 0;
    switch (event.key) {
        .escape => {
            dismissTopModal(state);
            return true;
        },
        .@"return", .kp_enter => {
            if (state.provider_onboarding_visible) {
                state.recheckProviderReadiness();
                return true;
            }
            if (state.mcp_onboarding_visible) {
                state.completeMcpOnboarding(true);
                return true;
            }
            if (state.palette_modal_text_focus == .project_rename) {
                state.finishProjectRename();
                return true;
            }
            if (state.palette_modal_text_focus == .thread_import) {
                state.importSelectedThread();
                return true;
            }
            if (state.palette_modal_text_focus == .project_import) {
                state.importProjectFromInput() catch |err| {
                    runtime.log.warn("workspace import failed: {s}", .{@errorName(err)});
                    state.setSidebarNotice("Could not add that directory path.");
                };
                return true;
            }
            if (state.herdr_profile_picker_project_index != null) {
                state.handoffProjectToSelectedHerdrProfile();
                return true;
            }
            return false;
        },
        .left => {
            if (state.palette_modal_text_focus == .none) return true;
            const cursor = focusedCursor(state) orelse return true;
            return moveModalCursorWithShift(state, cursor.* -| 1, shift);
        },
        .right => {
            if (state.palette_modal_text_focus == .none) return true;
            const cursor = focusedCursor(state) orelse return true;
            return moveModalCursorWithShift(state, @min(cursor.* + 1, focusedTextLen(state)), shift);
        },
        .home => {
            if (state.palette_modal_text_focus == .none) return true;
            return moveModalCursorWithShift(state, 0, shift);
        },
        .end => {
            if (state.palette_modal_text_focus == .none) return true;
            return moveModalCursorWithShift(state, focusedTextLen(state), shift);
        },
        .backspace => {
            if (state.palette_modal_text_focus != .none and deleteModalSelection(state)) return true;
            return deleteModalText(state, true);
        },
        .delete => {
            if (state.palette_modal_text_focus != .none and deleteModalSelection(state)) return true;
            return deleteModalText(state, false);
        },
        .a => {
            if (primary and state.palette_modal_text_focus != .none) {
                const cursor = focusedCursor(state) orelse return true;
                state.modal_text_selection_anchor = 0;
                cursor.* = focusedTextLen(state);
                return true;
            }
            return true;
        },
        .c => {
            if (primary and state.palette_modal_text_focus != .none) {
                copyModalSelection(state);
                return true;
            }
            if (state.transcriptSelectionBuffer()) |text| {
                if (primary) {
                    const clipboard_text = state.allocator.dupeZ(u8, text) catch return true;
                    defer state.allocator.free(clipboard_text);
                    sdl.setClipboardText(clipboard_text) catch |err| {
                        runtime.log.warn("failed to set transcript selection clipboard text: {s}", .{@errorName(err)});
                    };
                    return true;
                }
            }
            return false;
        },
        .x => {
            if (primary and state.palette_modal_text_focus != .none) {
                copyModalSelection(state);
                _ = deleteModalSelection(state);
                return true;
            }
            return true;
        },
        .v => {
            if (primary and state.palette_modal_text_focus != .none) {
                _ = pasteIntoModal(state);
                return true;
            }
            return true;
        },
        else => return true,
    }
}

fn dismissTopModal(state: *runtime.AppState) void {
    if (state.command_palette_open) {
        state.closeCommandPalette();
        return;
    }
    if (state.provider_onboarding_visible) {
        state.dismissProviderOnboarding();
    } else if (state.mcp_onboarding_visible) {
        state.completeMcpOnboarding(false);
    } else if (state.modal_image_path != null) {
        state.closeImageModal();
    } else if (state.transcriptSelectionBuffer() != null) {
        state.closeTranscriptSelectionModal();
    } else if (state.show_project_creator) {
        state.cancelProjectImport();
    } else if (state.rename_project_index != null) {
        state.cancelProjectRename();
    } else if (state.thread_import_provider != null) {
        state.cancelThreadImport();
    } else if (state.herdr_profile_picker_project_index != null) {
        state.cancelHerdrProfilePicker();
    } else if (state.show_settings_modal) {
        state.cancelSettingsModal();
    }
    state.palette_modal_text_focus = .none;
}

fn keymodBits(modifier_state: sdl.Keymod) u16 {
    return @as(*const u16, @ptrCast(&modifier_state)).*;
}

fn insertIntoZBuffer(buf: [:0]u8, cursor: *usize, text: []const u8) bool {
    const current = std.mem.sliceTo(buf, 0);
    if (text.len == 0 or current.len + text.len >= buf.len) return true;
    const at = @min(cursor.*, current.len);
    std.mem.copyBackwards(u8, buf[at + text.len .. current.len + text.len], buf[at..current.len]);
    @memcpy(buf[at .. at + text.len], text);
    buf[current.len + text.len] = 0;
    cursor.* = at + text.len;
    return true;
}

fn moveModalCursor(state: *runtime.AppState, delta: isize) bool {
    const cursor = focusedCursor(state) orelse return false;
    const len = focusedTextLen(state);
    if (delta < 0) {
        cursor.* -|= 1;
    } else {
        cursor.* = @min(cursor.* + 1, len);
    }
    return true;
}

fn moveModalCursorToEdge(state: *runtime.AppState, start: bool) bool {
    const cursor = focusedCursor(state) orelse return false;
    cursor.* = if (start) 0 else focusedTextLen(state);
    return true;
}

fn deleteModalText(state: *runtime.AppState, backwards: bool) bool {
    const cursor = focusedCursor(state) orelse return false;
    const buf = focusedBuffer(state) orelse return false;
    const len = std.mem.sliceTo(buf, 0).len;
    if (backwards) {
        if (cursor.* == 0 or len == 0) return true;
        const at = cursor.* - 1;
        std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
        buf[len - 1] = 0;
        cursor.* = at;
    } else {
        if (cursor.* >= len) return true;
        std.mem.copyForwards(u8, buf[cursor.* .. len - 1], buf[cursor.* + 1 .. len]);
        buf[len - 1] = 0;
    }
    return true;
}

fn focusedCursor(state: *runtime.AppState) ?*usize {
    return switch (state.palette_modal_text_focus) {
        .project_rename => &state.project_rename_cursor,
        .thread_import => &state.thread_import_cursor,
        .project_import => &state.project_import_cursor,
        .command_palette => &state.command_palette_cursor,
        .none => null,
    };
}

fn focusedBuffer(state: *runtime.AppState) ?[:0]u8 {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.renameBuffer(),
        .thread_import => state.threadImportThreadIdBuffer(),
        .project_import => state.importPathBuffer(),
        .command_palette => state.commandPaletteQueryBuffer(),
        .none => null,
    };
}

fn focusedTextLen(state: *runtime.AppState) usize {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.renameInputPublic().len,
        .thread_import => state.threadImportThreadId().len,
        .project_import => state.importDirectoryDraft().len,
        .command_palette => state.commandPaletteQuery().len,
        .none => 0,
    };
}

fn registerImageModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (state.modal_image_path == null) return;
    const modal_padding_x: f32 = 22.0;
    const modal_padding_y: f32 = 20.0;
    const modal_width = @min(width * 0.78, 980.0);
    const modal_height = @min(height * 0.82, 760.0);
    const modal: palette.Rect = .{ .x = (width - modal_width) * 0.5, .y = (height - modal_height) * 0.5, .w = modal_width, .h = modal_height };
    registerModalChromeHits(state, width, height, modal, true);
    const content: palette.Rect = .{ .x = modal.x + modal_padding_x, .y = modal.y + modal_padding_y, .w = modal.w - modal_padding_x * 2.0, .h = modal.h - modal_padding_y * 2.0 };
    const close_size: f32 = 28.0;
    const close_rect: palette.Rect = .{ .x = content.x + content.w - close_size, .y = content.y, .w = close_size, .h = close_size };
    queueModalHit(state, close_rect, .image_close, 0);
}

fn registerTranscriptSelectionModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (state.transcriptSelectionBuffer() == null) return;
    const modal: palette.Rect = .{ .x = (width - @min(width * 0.76, theme.scaledUi(980.0))) * 0.5, .y = (height - @min(height * 0.8, theme.scaledUi(760.0))) * 0.5, .w = @min(width * 0.76, theme.scaledUi(980.0)), .h = @min(height * 0.8, theme.scaledUi(760.0)) };
    registerModalChromeHits(state, width, height, modal, true);
    const pad = theme.scaledUi(18.0);
    const close_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + modal.h - pad - theme.scaledUi(34.0), .w = theme.scaledUi(112.0), .h = theme.scaledUi(34.0) };
    queueModalHit(state, close_rect, .transcript_close, 0);
}

fn providerOnboardingRect(width: f32, height: f32) palette.Rect {
    const modal_w = theme.clampf(width * 0.54, theme.scaledUi(540.0), theme.scaledUi(720.0));
    const modal_h = theme.clampf(height * 0.78, theme.scaledUi(500.0), theme.scaledUi(620.0));
    return .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
}

fn registerProviderOnboardingHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.provider_onboarding_visible) return;
    const modal = providerOnboardingRect(width, height);
    registerModalChromeHits(state, width, height, modal, false);
    const pad = theme.scaledUi(22.0);
    const button_h = theme.scaledUi(36.0);
    const gap = theme.scaledUi(10.0);
    const close_w = theme.scaledUi(104.0);
    const guide_w = theme.scaledUi(156.0);
    const check_w = theme.scaledUi(126.0);
    const button_y = modal.y + modal.h - pad - button_h;
    queueModalHit(state, .{ .x = modal.x + pad, .y = button_y, .w = close_w, .h = button_h }, .provider_onboarding_close, 0);
    queueModalHit(state, .{ .x = modal.x + modal.w - pad - check_w, .y = button_y, .w = check_w, .h = button_h }, .provider_onboarding_recheck, 0);
    queueModalHit(state, .{ .x = modal.x + modal.w - pad - check_w - gap - guide_w, .y = button_y, .w = guide_w, .h = button_h }, .provider_onboarding_open_guide, 0);
}

fn mcpOnboardingRect(width: f32, height: f32) palette.Rect {
    const modal_w = theme.clampf(width * 0.5, theme.scaledUi(520.0), theme.scaledUi(680.0));
    const modal_h = theme.clampf(height * 0.56, theme.scaledUi(400.0), theme.scaledUi(440.0));
    return .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
}

fn registerMcpOnboardingHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.mcp_onboarding_visible or state.provider_onboarding_visible) return;
    const modal = mcpOnboardingRect(width, height);
    registerModalChromeHits(state, width, height, modal, false);
    const pad = theme.scaledUi(22.0);
    const button_h = theme.scaledUi(36.0);
    const skip_w = theme.scaledUi(104.0);
    const enable_w = theme.scaledUi(176.0);
    const button_y = modal.y + modal.h - pad - button_h;
    queueModalHit(state, .{ .x = modal.x + pad, .y = button_y, .w = skip_w, .h = button_h }, .mcp_onboarding_not_now, 0);
    queueModalHit(state, .{ .x = modal.x + modal.w - pad - enable_w, .y = button_y, .w = enable_w, .h = button_h }, .mcp_onboarding_enable, 0);
}

fn registerWorkspaceAddModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.show_project_creator) return;
    const modal_w = theme.clampf(width * 0.34, theme.scaledUi(360.0), theme.scaledUi(500.0));
    const notice_h: f32 = if (state.sidebarNotice().len > 0) theme.scaledUi(24.0) else 0.0;
    const modal_h = theme.scaledUi(252.0) + notice_h;
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    registerModalChromeHits(state, width, height, modal, false);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    y += theme.scaledUi(30.0);
    y += theme.scaledUi(48.0);
    const button_gap = theme.scaledUi(10.0);
    const browse_w = (modal.w - pad * 2.0 - button_gap) * 0.5;
    const browse_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = browse_w, .h = theme.scaledUi(36.0) };
    const create_rect: palette.Rect = .{ .x = browse_rect.x + browse_rect.w + button_gap, .y = y, .w = browse_w, .h = browse_rect.h };
    queueModalHit(state, browse_rect, .project_import_browse, 0);
    queueModalHit(state, create_rect, .project_import_create_dir, 0);
    y += theme.scaledUi(44.0);
    const add_w = theme.scaledUi(76.0);
    const row_gap = theme.scaledUi(10.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0 - add_w - row_gap, .h = theme.scaledUi(34.0) };
    const add_rect: palette.Rect = .{ .x = input_rect.x + input_rect.w + row_gap, .y = y, .w = add_w, .h = theme.scaledUi(34.0) };
    queueModalHit(state, input_rect, .project_import_input, 0);
    queueModalHit(state, add_rect, .project_import_submit, 0);
    y += theme.scaledUi(46.0);
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = theme.scaledUi(120.0), .h = theme.scaledUi(34.0) };
    queueModalHit(state, cancel_rect, .project_import_cancel, 0);
}

fn registerWorkspaceRenameModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    const rename_index = state.rename_project_index orelse return;
    if (rename_index >= state.projects.items.len) return;
    const modal_w = theme.clampf(width * 0.28, theme.scaledUi(320.0), theme.scaledUi(420.0));
    const modal_h = theme.scaledUi(188.0);
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    registerModalChromeHits(state, width, height, modal, true);
    const pad = theme.scaledUi(18.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(76.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    const gap = theme.scaledUi(10.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = input_rect.x, .y = modal.y + modal.h - pad - theme.scaledUi(34.0), .w = button_w, .h = theme.scaledUi(34.0) };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + cancel_rect.w + gap, .y = cancel_rect.y, .w = button_w, .h = cancel_rect.h };
    queueModalHit(state, input_rect, .project_rename_input, 0);
    queueModalHit(state, cancel_rect, .project_rename_cancel, 0);
    queueModalHit(state, submit_rect, .project_rename_submit, 0);
}

fn registerThreadImportModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (state.thread_import_provider == null) return;
    const project_index = state.thread_import_project_index orelse return;
    if (project_index >= state.projects.items.len) return;
    const modal_w = theme.clampf(width * 0.42, theme.scaledUi(460.0), theme.scaledUi(640.0));
    const modal_h = theme.clampf(height * 0.66, theme.scaledUi(420.0), theme.scaledUi(620.0));
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    registerModalChromeHits(state, width, height, modal, true);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    y += theme.scaledUi(26.0);
    y += theme.scaledUi(20.0);
    y += theme.scaledUi(24.0);
    y += theme.scaledUi(48.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    queueModalHit(state, input_rect, .thread_import_input, 0);
    y += theme.scaledUi(44.0);
    const refresh_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = @max(theme.scaledUi(112.0), input_rect.w * 0.28), .h = theme.scaledUi(32.0) };
    queueModalHit(state, refresh_rect, .thread_import_refresh, 0);
    y += theme.scaledUi(42.0);
    const notice_h = if (state.threadImportNotice().len > 0) theme.scaledUi(24.0) else 0.0;
    const button_h = theme.scaledUi(34.0);
    const list_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = input_rect.w, .h = modal.y + modal.h - pad - button_h - notice_h - theme.scaledUi(16.0) - y };
    if (state.thread_import_threads.items.len != 0) {
        const row_h = theme.scaledUi(42.0);
        for (state.thread_import_threads.items, 0..) |_, index| {
            const row: palette.Rect = .{ .x = list_rect.x + theme.scaledUi(6.0), .y = list_rect.y + theme.scaledUi(6.0) + @as(f32, @floatFromInt(index)) * row_h, .w = list_rect.w - theme.scaledUi(12.0), .h = row_h - theme.scaledUi(2.0) };
            if (row.y + row.h > list_rect.y + list_rect.h) break;
            queueModalHit(state, row, .thread_import_select, index);
        }
    }
    const button_y = modal.y + modal.h - pad - button_h;
    const gap = theme.scaledUi(10.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + button_w + gap, .y = button_y, .w = button_w, .h = button_h };
    queueModalHit(state, cancel_rect, .thread_import_cancel, 0);
    queueModalHit(state, submit_rect, .thread_import_submit, 0);
}

fn registerHerdrProfilePickerHits(state: *runtime.AppState, width: f32, height: f32) void {
    if (state.herdr_profile_picker_project_index == null) return;
    const modal_w = theme.clampf(width * 0.42, theme.scaledUi(460.0), theme.scaledUi(640.0));
    const modal_h = theme.clampf(height * 0.58, theme.scaledUi(360.0), theme.scaledUi(540.0));
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    registerModalChromeHits(state, width, height, modal, true);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    y += theme.scaledUi(28.0);
    y += theme.scaledUi(42.0);
    const refresh_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = @max(theme.scaledUi(112.0), (modal.w - pad * 2.0) * 0.28), .h = theme.scaledUi(32.0) };
    queueModalHit(state, refresh_rect, .herdr_profile_refresh, 0);
    y += theme.scaledUi(42.0);
    const button_h = theme.scaledUi(34.0);
    const notice_h = if (state.herdrProfileNotice().len > 0) theme.scaledUi(24.0) else 0.0;
    const list_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = modal.y + modal.h - pad - button_h - notice_h - theme.scaledUi(16.0) - y };
    if (state.herdr_profile_summaries.items.len != 0) {
        const row_h = theme.scaledUi(50.0);
        for (state.herdr_profile_summaries.items, 0..) |_, index| {
            const row: palette.Rect = .{ .x = list_rect.x + theme.scaledUi(6.0), .y = list_rect.y + theme.scaledUi(6.0) + @as(f32, @floatFromInt(index)) * row_h, .w = list_rect.w - theme.scaledUi(12.0), .h = row_h - theme.scaledUi(2.0) };
            if (row.y + row.h > list_rect.y + list_rect.h) break;
            queueModalHit(state, row, .herdr_profile_select, index);
        }
    }
    const button_y = modal.y + modal.h - pad - button_h;
    const gap = theme.scaledUi(10.0);
    const button_w = (modal.w - pad * 2.0 - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + button_w + gap, .y = button_y, .w = button_w, .h = button_h };
    queueModalHit(state, cancel_rect, .herdr_profile_cancel, 0);
    queueModalHit(state, submit_rect, .herdr_profile_submit, 0);
}

// Renders the one-time opt-in for provider-native Verde MCP registration.
fn renderMcpOnboardingModal(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.mcp_onboarding_visible or state.provider_onboarding_visible) return;
    const modal = mcpOnboardingRect(width, height);
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(22.0);
    const clip = modal;
    var y = modal.y + pad;

    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(28.0) }, "Make Verde work better with your agents", paletteColor(theme.COLOR_WHITE), theme.scaledUi(22.0), clip);
    y += theme.scaledUi(36.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(40.0) }, "Enable Verde's MCP tools for agents you start in terminal panes or use through Verde.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.5), clip);
    y += theme.scaledUi(54.0);

    const benefit_h = theme.scaledUi(52.0);
    const benefit_gap = theme.scaledUi(7.0);
    renderMcpBenefitRow(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = benefit_h }, "Test apps", "Inspect and interact with Verde's embedded browser.", clip);
    y += benefit_h + benefit_gap;
    renderMcpBenefitRow(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = benefit_h }, "Work with processes", "Start configured services and read their logs.", clip);
    y += benefit_h + benefit_gap;
    renderMcpBenefitRow(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = benefit_h }, "Understand the workspace", "Use the current Verde workspace and its panes automatically.", clip);
    const benefits_bottom = y + benefit_h;

    const button_h = theme.scaledUi(36.0);
    const button_y = modal.y + modal.h - pad - button_h;
    queuePaletteText(state, .{ .x = modal.x + pad, .y = benefits_bottom + theme.scaledUi(16.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(28.0) }, "Updates detected providers' user settings and preserves existing servers. Remove it any time in Settings.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), clip);
    drawActionButton(state, .{ .x = modal.x + pad, .y = button_y, .w = theme.scaledUi(104.0), .h = button_h }, "Not now", theme.COLOR_PANEL_ALT);
    drawActionButton(state, .{ .x = modal.x + modal.w - pad - theme.scaledUi(176.0), .y = button_y, .w = theme.scaledUi(176.0), .h = button_h }, "Enable Verde tools", theme.COLOR_SECONDARY_GREEN);
}

// Renders one capability included with Verde's MCP server.
fn renderMcpBenefitRow(state: *runtime.AppState, rect: palette.Rect, title: []const u8, detail: []const u8, clip: palette.Rect) void {
    queuePaletteRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 105)), theme.scaledUi(9.0));
    queuePaletteBorder(state, rect, paletteColor(theme.withAlpha(theme.borderMuted(), 90)), theme.scaledUi(9.0), theme.scaledUi(1.0));
    const text_x = rect.x + theme.scaledUi(14.0);
    queuePaletteText(state, .{ .x = text_x, .y = rect.y + theme.scaledUi(7.0), .w = rect.w - theme.scaledUi(28.0), .h = theme.scaledUi(18.0) }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.5), clip);
    queuePaletteText(state, .{ .x = text_x, .y = rect.y + theme.scaledUi(27.0), .w = rect.w - theme.scaledUi(28.0), .h = theme.scaledUi(17.0) }, detail, paletteColor(theme.lighten(theme.COLOR_TEXT_SUBTLE, 0.1)), theme.scaledUi(12.5), clip);
}

/// Shows the attachment preview modal for the selected image.
// Renders the first-run provider checklist when no authenticated GUI provider is available.
fn renderProviderOnboardingModal(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.provider_onboarding_visible) return;
    const modal = providerOnboardingRect(width, height);
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(22.0);
    const clip = modal;
    var y = modal.y + pad;

    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(28.0) }, "Connect an AI provider", paletteColor(theme.COLOR_WHITE), theme.scaledUi(22.0), clip);
    y += theme.scaledUi(34.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(42.0) }, "Verde uses coding-agent accounts already installed on this computer. Set up any one provider to start chatting; Verde does not require its own subscription.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.5), clip);
    y += theme.scaledUi(52.0);

    const snapshot = state.providerReadinessSnapshot();
    const providers = [_]runtime.Provider{ .codex, .opencode, .claude, .cursor };
    const button_h = theme.scaledUi(36.0);
    const button_y = modal.y + modal.h - pad - button_h;
    const rows_bottom = button_y - theme.scaledUi(18.0);
    const row_gap = theme.scaledUi(8.0);
    const row_h = @max((rows_bottom - y - row_gap * 3.0) / 4.0, theme.scaledUi(58.0));
    for (providers) |provider| {
        const row: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = row_h };
        renderProviderReadinessRow(state, row, provider, snapshot.forProvider(provider), clip);
        y += row_h + row_gap;
    }

    const gap = theme.scaledUi(10.0);
    const close_w = theme.scaledUi(104.0);
    const guide_w = theme.scaledUi(156.0);
    const check_w = theme.scaledUi(126.0);
    drawActionButton(state, .{ .x = modal.x + pad, .y = button_y, .w = close_w, .h = button_h }, "Not now", theme.COLOR_PANEL_ALT);
    drawActionButton(state, .{ .x = modal.x + modal.w - pad - check_w - gap - guide_w, .y = button_y, .w = guide_w, .h = button_h }, "Open setup guide", theme.COLOR_PANEL_MUTED);
    const checking = snapshot.codex == .checking and snapshot.opencode == .checking and snapshot.claude == .checking and snapshot.cursor == .checking;
    drawActionButton(state, .{ .x = modal.x + modal.w - pad - check_w, .y = button_y, .w = check_w, .h = button_h }, if (checking) "Checking..." else "Check again", theme.COLOR_SECONDARY_GREEN);
}

// Renders one provider's executable/auth status and its shortest recovery step.
fn renderProviderReadinessRow(state: *runtime.AppState, rect: palette.Rect, provider: runtime.Provider, readiness: runtime.ProviderReadiness, clip: palette.Rect) void {
    queuePaletteRoundedRect(state, rect, paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.025)), theme.scaledUi(9.0));
    queuePaletteBorder(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 190)), theme.scaledUi(9.0), theme.scaledUi(1.0));

    const dot_color = switch (readiness) {
        .ready => theme.COLOR_SECONDARY_GREEN,
        .signed_out => theme.COLOR_YELLOW,
        .missing => theme.COLOR_DIFF_REMOVE,
        .checking => theme.COLOR_TEXT_MUTED,
        .unavailable => theme.COLOR_YELLOW,
    };
    const dot = theme.scaledUi(8.0);
    queuePaletteRoundedRect(state, .{ .x = rect.x + theme.scaledUi(14.0), .y = rect.y + theme.scaledUi(16.0), .w = dot, .h = dot }, paletteColor(dot_color), dot * 0.5);

    const title = switch (provider) {
        .codex => "Codex",
        .opencode => "OpenCode",
        .claude => "Claude Code",
        .cursor => "Cursor",
    };
    const status = switch (readiness) {
        .checking => "Checking...",
        .missing => "CLI not found",
        .signed_out => "Sign-in needed",
        .ready => "Ready",
        .unavailable => "Could not verify",
    };
    const step = providerReadinessStep(provider, readiness);
    const text_x = rect.x + theme.scaledUi(34.0);
    const status_w = theme.scaledUi(116.0);
    queuePaletteText(state, .{ .x = text_x, .y = rect.y + theme.scaledUi(8.0), .w = rect.w - status_w - theme.scaledUi(48.0), .h = theme.scaledUi(20.0) }, title, paletteColor(theme.COLOR_WHITE), theme.scaledUi(14.5), clip);
    queuePaletteText(state, .{ .x = rect.x + rect.w - status_w - theme.scaledUi(12.0), .y = rect.y + theme.scaledUi(9.0), .w = status_w, .h = theme.scaledUi(18.0) }, status, paletteColor(dot_color), theme.scaledUi(12.0), clip);
    queuePaletteText(state, .{ .x = text_x, .y = rect.y + theme.scaledUi(31.0), .w = rect.w - theme.scaledUi(48.0), .h = @max(rect.h - theme.scaledUi(36.0), theme.scaledUi(18.0)) }, step, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), clip);
}

fn providerReadinessStep(provider: runtime.Provider, readiness: runtime.ProviderReadiness) []const u8 {
    if (readiness == .ready) return "Installed and authenticated. You can select this provider in the composer.";
    if (readiness == .checking) return "Checking the local CLI and account session...";
    return switch (provider) {
        .codex => if (readiness == .missing) "Install the Codex CLI, then run: codex login" else "Run codex login, then return here and check again.",
        .opencode => if (readiness == .missing) "Install OpenCode, then run: opencode" else "Open opencode, connect a model provider, then check again.",
        .claude => if (readiness == .missing) "Install Claude Code, then run: claude" else "Open claude, complete sign-in, then check again.",
        .cursor => if (readiness == .missing) "Install the Cursor CLI, then run: agent login" else "Run agent login, then return here and check again.",
    };
}

// Renders the full-size image preview modal over the workspace.
fn renderImageModal(state: *runtime.AppState, width: f32, height: f32) void {
    const modal_path = state.modal_image_path orelse return;
    const modal_padding_x: f32 = 22.0;
    const modal_padding_y: f32 = 20.0;
    const modal_width = @min(width * 0.78, 980.0);
    const modal_height = @min(height * 0.82, 760.0);
    const modal: palette.Rect = .{ .x = (width - modal_width) * 0.5, .y = (height - modal_height) * 0.5, .w = modal_width, .h = modal_height };
    drawModalChromeVisual(state, width, height, modal);

    const texture = state.ensureImageTexture(modal_path);
    const close_size: f32 = 28.0;
    const header_gap: f32 = 12.0;
    const content: palette.Rect = .{ .x = modal.x + modal_padding_x, .y = modal.y + modal_padding_y, .w = modal.w - modal_padding_x * 2.0, .h = modal.h - modal_padding_y * 2.0 };
    const header_text_width = @max(content.w - close_size - header_gap, 160.0);
    const close_rect: palette.Rect = .{ .x = content.x + content.w - close_size, .y = content.y, .w = close_size, .h = close_size };
    drawActionButton(state, close_rect, "x", theme.withAlpha(theme.COLOR_PANEL_MUTED, 220));
    queuePaletteText(state, .{ .x = content.x, .y = content.y, .w = header_text_width, .h = theme.scaledUi(22.0) }, std.fs.path.basename(modal_path), paletteColor(theme.COLOR_WHITE), theme.scaledUi(16.0), modal);
    queuePaletteText(state, .{ .x = content.x, .y = content.y + theme.scaledUi(24.0), .w = header_text_width, .h = theme.scaledUi(20.0) }, modal_path, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), modal);

    const canvas: palette.Rect = .{ .x = content.x, .y = content.y + theme.scaledUi(62.0), .w = content.w, .h = content.h - theme.scaledUi(62.0) };
    queuePaletteRoundedRect(state, canvas, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(10.0));
    queuePaletteBorder(state, canvas, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(10.0), theme.scaledUi(1.0));
    const image_max_w = @max(canvas.w - theme.scaledUi(32.0), 80.0);
    const image_max_h = @max(canvas.h - theme.scaledUi(32.0), 80.0);

    if (texture) |cached| {
        const dims = runtime.scaledImageSize(cached.width, cached.height, image_max_w, image_max_h);
        state.palette_overlay_batch.image(
            state.allocator,
            .{ .x = canvas.x + (canvas.w - dims[0]) * 0.5, .y = canvas.y + (canvas.h - dims[1]) * 0.5, .w = dims[0], .h = dims[1] },
            palette.TextureId.init(cached.texture_id),
            .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 },
            paletteColor(theme.COLOR_WHITE),
            canvas,
        ) catch {};
    } else {
        const unavailable_rect: palette.Rect = .{ .x = canvas.x + theme.scaledUi(16.0), .y = canvas.y + theme.scaledUi(16.0), .w = image_max_w, .h = @min(image_max_h, 240.0) };
        queuePaletteRoundedRect(state, unavailable_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(10.0));
        queuePaletteBorder(state, unavailable_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(10.0), theme.scaledUi(1.0));
        queuePaletteText(state, .{
            .x = unavailable_rect.x + theme.scaledUi(16.0),
            .y = unavailable_rect.y + (unavailable_rect.h - theme.scaledUi(18.0)) * 0.5,
            .w = unavailable_rect.w - theme.scaledUi(32.0),
            .h = theme.scaledUi(22.0),
        }, "Preview unavailable", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(16.0), unavailable_rect);
    }
}

/// Shows the modal used to rename the active workspace.
fn renderWorkspaceRenameModal(state: *runtime.AppState, width: f32, height: f32) void {
    const rename_index = state.rename_project_index orelse return;
    if (rename_index >= state.projects.items.len) {
        state.rename_project_index = null;
        return;
    }
    const modal_w = theme.clampf(width * 0.28, theme.scaledUi(320.0), theme.scaledUi(420.0));
    const modal_h = theme.scaledUi(188.0);
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + pad, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "Rename workspace", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(44.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(20.0) }, state.projects.items[rename_index].path, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(76.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    drawTextField(state, input_rect, state.renameInputPublic(), "Workspace label", state.palette_modal_text_focus == .project_rename, state.project_rename_cursor);
    const gap = theme.scaledUi(10.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = input_rect.x, .y = modal.y + modal.h - pad - theme.scaledUi(34.0), .w = button_w, .h = theme.scaledUi(34.0) };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + cancel_rect.w + gap, .y = cancel_rect.y, .w = button_w, .h = cancel_rect.h };
    drawActionButton(state, cancel_rect, "Cancel", theme.COLOR_PANEL_ALT);
    drawActionButton(state, submit_rect, "Rename", theme.COLOR_SECONDARY_GREEN);
}

fn renderWorkspaceAddModal(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.show_project_creator) return;
    const modal_w = theme.clampf(width * 0.34, theme.scaledUi(360.0), theme.scaledUi(500.0));
    const notice = state.sidebarNotice();
    const notice_h: f32 = if (notice.len > 0) theme.scaledUi(24.0) else 0.0;
    const modal_h = theme.scaledUi(252.0) + notice_h;
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "Add workspace", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    y += theme.scaledUi(30.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(40.0) }, "Open an existing folder, or pick a parent and type a new folder name.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(48.0);
    const button_gap = theme.scaledUi(10.0);
    const browse_w = (modal.w - pad * 2.0 - button_gap) * 0.5;
    const browse_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = browse_w, .h = theme.scaledUi(36.0) };
    const create_rect: palette.Rect = .{ .x = browse_rect.x + browse_rect.w + button_gap, .y = y, .w = browse_w, .h = browse_rect.h };
    drawActionButton(state, browse_rect, "Open existing folder", theme.COLOR_PANEL_ALT);
    drawActionButton(state, create_rect, "New folder...", theme.COLOR_GREEN);
    y += theme.scaledUi(44.0);
    const add_w = theme.scaledUi(76.0);
    const row_gap = theme.scaledUi(10.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0 - add_w - row_gap, .h = theme.scaledUi(34.0) };
    const add_rect: palette.Rect = .{ .x = input_rect.x + input_rect.w + row_gap, .y = y, .w = add_w, .h = theme.scaledUi(34.0) };
    drawTextField(state, input_rect, state.importDirectoryDraft(), "/path/to/workspace", state.palette_modal_text_focus == .project_import, state.project_import_cursor);
    drawActionButton(state, add_rect, "Add", theme.COLOR_SECONDARY_GREEN);
    y += theme.scaledUi(46.0);
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = theme.scaledUi(120.0), .h = theme.scaledUi(34.0) };
    drawActionButton(state, cancel_rect, "Cancel", theme.COLOR_PANEL_ALT);
    if (notice.len > 0) {
        y += theme.scaledUi(42.0);
        queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(20.0) }, notice, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), modal);
    }
}

fn renderTranscriptSelectionModal(state: *runtime.AppState, width: f32, height: f32) void {
    const transcript_text = state.transcriptSelectionBuffer() orelse return;
    _ = state.consumeTranscriptSelectionModalRequest();
    const modal: palette.Rect = .{ .x = (width - @min(width * 0.76, theme.scaledUi(980.0))) * 0.5, .y = (height - @min(height * 0.8, theme.scaledUi(760.0))) * 0.5, .w = @min(width * 0.76, theme.scaledUi(980.0)), .h = @min(height * 0.8, theme.scaledUi(760.0)) };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + pad, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "Thread text", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(44.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(20.0) }, "Ctrl+C copies the modal text.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    const close_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + modal.h - pad - theme.scaledUi(34.0), .w = theme.scaledUi(112.0), .h = theme.scaledUi(34.0) };
    const text_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(74.0), .w = modal.w - pad * 2.0, .h = close_rect.y - modal.y - theme.scaledUi(86.0) };
    queuePaletteRoundedRect(state, text_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(8.0));
    queuePaletteBorder(state, text_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), theme.scaledUi(1.0));
    queuePaletteText(state, .{ .x = text_rect.x + theme.scaledUi(12.0), .y = text_rect.y + theme.scaledUi(10.0), .w = text_rect.w - theme.scaledUi(24.0), .h = text_rect.h - theme.scaledUi(20.0) }, transcript_text, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), text_rect);
    drawActionButton(state, close_rect, "Close", theme.COLOR_PANEL_ALT);
}

fn renderThreadImportModal(state: *runtime.AppState, width: f32, height: f32) void {
    const provider = state.thread_import_provider orelse return;
    const project_index = state.thread_import_project_index orelse return;
    if (project_index >= state.projects.items.len) {
        state.cancelThreadImport();
        return;
    }
    const modal_w = theme.clampf(width * 0.42, theme.scaledUi(460.0), theme.scaledUi(640.0));
    const modal_h = theme.clampf(height * 0.66, theme.scaledUi(420.0), theme.scaledUi(620.0));
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    const project = &state.projects.items[project_index];
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, threadImportHeading(provider), paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    y += theme.scaledUi(26.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, project.label, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(20.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(18.0) }, project.path, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(24.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(40.0) }, threadImportDescription(provider), paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(48.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    drawTextField(state, input_rect, state.threadImportThreadId(), threadImportHint(provider), state.palette_modal_text_focus == .thread_import, state.thread_import_cursor);
    y += theme.scaledUi(44.0);
    const refresh_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = @max(theme.scaledUi(112.0), input_rect.w * 0.28), .h = theme.scaledUi(32.0) };
    drawActionButton(state, refresh_rect, "Refresh list", theme.COLOR_PANEL_MUTED);
    y += theme.scaledUi(42.0);
    const notice_h = if (state.threadImportNotice().len > 0) theme.scaledUi(24.0) else 0.0;
    const button_h = theme.scaledUi(34.0);
    const list_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = input_rect.w, .h = modal.y + modal.h - pad - button_h - notice_h - theme.scaledUi(16.0) - y };
    queuePaletteRoundedRect(state, list_rect, paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.03)), theme.scaledUi(8.0));
    queuePaletteBorder(state, list_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), theme.scaledUi(1.0));
    if (state.thread_import_threads.items.len == 0) {
        queuePaletteText(state, .{ .x = list_rect.x + theme.scaledUi(12.0), .y = list_rect.y + theme.scaledUi(12.0), .w = list_rect.w - theme.scaledUi(24.0), .h = theme.scaledUi(20.0) }, emptyThreadImportListNotice(provider), paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), list_rect);
    } else {
        const row_h = theme.scaledUi(42.0);
        for (state.thread_import_threads.items, 0..) |thread, index| {
            const row: palette.Rect = .{ .x = list_rect.x + theme.scaledUi(6.0), .y = list_rect.y + theme.scaledUi(6.0) + @as(f32, @floatFromInt(index)) * row_h, .w = list_rect.w - theme.scaledUi(12.0), .h = row_h - theme.scaledUi(2.0) };
            if (row.y + row.h > list_rect.y + list_rect.h) break;
            const selected = state.thread_import_selected_index != null and state.thread_import_selected_index.? == index;
            const row_hovered = state.thread_import_hover_index != null and state.thread_import_hover_index.? == index;
            if (selected) {
                const sel_bg = if (row_hovered)
                    paletteColor(theme.lighten(theme.COLOR_PANEL_MUTED, 0.10))
                else
                    paletteColor(theme.COLOR_PANEL_MUTED);
                queuePaletteRoundedRect(state, row, sel_bg, theme.scaledUi(6.0));
            } else if (row_hovered) {
                queuePaletteRoundedRect(state, row, paletteColor(theme.lighten(theme.COLOR_PANEL_MUTED, 0.06)), theme.scaledUi(6.0));
                queuePaletteBorder(state, row, paletteColor(theme.lighten(theme.borderMuted(), 0.02)), theme.scaledUi(6.0), theme.scaledUi(1.0));
            }
            const title_col = paletteColor(theme.COLOR_WHITE);
            const id_col = paletteColor(if (row_hovered) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE);
            queuePaletteText(state, .{ .x = row.x + theme.scaledUi(8.0), .y = row.y + theme.scaledUi(4.0), .w = row.w - theme.scaledUi(16.0), .h = theme.scaledUi(18.0) }, thread.title, title_col, theme.scaledUi(13.0), list_rect);
            queuePaletteText(state, .{ .x = row.x + theme.scaledUi(8.0), .y = row.y + theme.scaledUi(22.0), .w = row.w - theme.scaledUi(16.0), .h = theme.scaledUi(16.0) }, thread.id, id_col, theme.scaledUi(12.0), list_rect);
        }
    }

    const button_y = modal.y + modal.h - pad - button_h;
    if (state.threadImportNotice().len > 0) {
        queuePaletteText(state, .{ .x = modal.x + pad, .y = button_y - theme.scaledUi(26.0), .w = input_rect.w, .h = theme.scaledUi(20.0) }, state.threadImportNotice(), paletteColor(theme.COLOR_YELLOW), theme.scaledUi(13.0), modal);
    }
    const gap = theme.scaledUi(10.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + button_w + gap, .y = button_y, .w = button_w, .h = button_h };
    drawActionButton(state, cancel_rect, "Cancel", theme.COLOR_PANEL_MUTED);
    drawActionButton(state, submit_rect, "Import", theme.COLOR_GREEN);
}

/// Shows the modal used to choose a saved Herdr remote profile for workspace handoff.
fn renderHerdrProfilePickerModal(state: *runtime.AppState, width: f32, height: f32) void {
    const project_index = state.herdr_profile_picker_project_index orelse return;
    if (project_index >= state.projects.items.len) {
        state.cancelHerdrProfilePicker();
        return;
    }
    const modal_w = theme.clampf(width * 0.42, theme.scaledUi(460.0), theme.scaledUi(640.0));
    const modal_h = theme.clampf(height * 0.58, theme.scaledUi(360.0), theme.scaledUi(540.0));
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    const project = &state.projects.items[project_index];
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "Handoff to remote Herdr", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    y += theme.scaledUi(28.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(38.0) }, project.path, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(42.0);
    const refresh_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = @max(theme.scaledUi(112.0), (modal.w - pad * 2.0) * 0.28), .h = theme.scaledUi(32.0) };
    drawActionButton(state, refresh_rect, "Refresh profiles", theme.COLOR_PANEL_MUTED);
    y += theme.scaledUi(42.0);

    const button_h = theme.scaledUi(34.0);
    const notice = state.herdrProfileNotice();
    const notice_h = if (notice.len > 0) theme.scaledUi(24.0) else 0.0;
    const list_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = modal.y + modal.h - pad - button_h - notice_h - theme.scaledUi(16.0) - y };
    queuePaletteRoundedRect(state, list_rect, paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.03)), theme.scaledUi(8.0));
    queuePaletteBorder(state, list_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), theme.scaledUi(1.0));
    if (state.herdr_profile_summaries.items.len == 0) {
        queuePaletteText(state, .{ .x = list_rect.x + theme.scaledUi(12.0), .y = list_rect.y + theme.scaledUi(12.0), .w = list_rect.w - theme.scaledUi(24.0), .h = theme.scaledUi(20.0) }, "No profiles found. Add one with `verde herdr profiles add`.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), list_rect);
    } else {
        const row_h = theme.scaledUi(50.0);
        for (state.herdr_profile_summaries.items, 0..) |profile, index| {
            const row: palette.Rect = .{ .x = list_rect.x + theme.scaledUi(6.0), .y = list_rect.y + theme.scaledUi(6.0) + @as(f32, @floatFromInt(index)) * row_h, .w = list_rect.w - theme.scaledUi(12.0), .h = row_h - theme.scaledUi(2.0) };
            if (row.y + row.h > list_rect.y + list_rect.h) break;
            const selected = state.herdr_profile_selected_index != null and state.herdr_profile_selected_index.? == index;
            const row_hovered = state.herdr_profile_hover_index != null and state.herdr_profile_hover_index.? == index;
            if (selected) {
                const sel_bg = if (row_hovered)
                    paletteColor(theme.lighten(theme.COLOR_PANEL_MUTED, 0.10))
                else
                    paletteColor(theme.COLOR_PANEL_MUTED);
                queuePaletteRoundedRect(state, row, sel_bg, theme.scaledUi(6.0));
            } else if (row_hovered) {
                queuePaletteRoundedRect(state, row, paletteColor(theme.lighten(theme.COLOR_PANEL_MUTED, 0.06)), theme.scaledUi(6.0));
                queuePaletteBorder(state, row, paletteColor(theme.lighten(theme.borderMuted(), 0.02)), theme.scaledUi(6.0), theme.scaledUi(1.0));
            }
            const cwd_label = profile.remote_cwd orelse "default Verde remote workspace dir";
            queuePaletteText(state, .{ .x = row.x + theme.scaledUi(8.0), .y = row.y + theme.scaledUi(5.0), .w = row.w - theme.scaledUi(16.0), .h = theme.scaledUi(18.0) }, profile.name, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), list_rect);
            queuePaletteText(state, .{ .x = row.x + theme.scaledUi(8.0), .y = row.y + theme.scaledUi(24.0), .w = row.w - theme.scaledUi(16.0), .h = theme.scaledUi(16.0) }, profile.ssh_target, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), list_rect);
            queuePaletteText(state, .{ .x = row.x + row.w * 0.56, .y = row.y + theme.scaledUi(24.0), .w = row.w * 0.42, .h = theme.scaledUi(16.0) }, cwd_label, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), list_rect);
        }
    }

    const button_y = modal.y + modal.h - pad - button_h;
    if (notice.len > 0) {
        queuePaletteText(state, .{ .x = modal.x + pad, .y = button_y - theme.scaledUi(26.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(20.0) }, notice, paletteColor(theme.COLOR_YELLOW), theme.scaledUi(13.0), modal);
    }
    const gap = theme.scaledUi(10.0);
    const button_w = (modal.w - pad * 2.0 - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = modal.x + pad, .y = button_y, .w = button_w, .h = button_h };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + button_w + gap, .y = button_y, .w = button_w, .h = button_h };
    drawActionButton(state, cancel_rect, "Cancel", theme.COLOR_PANEL_MUTED);
    drawActionButton(state, submit_rect, "Handoff", theme.COLOR_GREEN);
}

fn threadImportHeading(provider: runtime.Provider) []const u8 {
    return switch (provider) {
        .codex => "Import Codex thread",
        .opencode => "Import OpenCode thread",
        .claude => "Import Claude thread",
        .cursor => "Import Cursor thread",
    };
}

fn threadImportDescription(provider: runtime.Provider) []const u8 {
    return switch (provider) {
        .codex => "Import loads the existing Codex transcript into this workspace and binds future turns to the same thread.",
        .opencode => "Import loads the existing OpenCode transcript into this workspace and binds future turns to the same thread.",
        .claude => "Import loads the existing Claude transcript into this workspace and binds future turns to the same thread.",
        .cursor => "Import loads the existing Cursor transcript into this workspace and binds future turns to the same thread.",
    };
}

fn threadImportHint(provider: runtime.Provider) [:0]const u8 {
    return switch (provider) {
        .codex => "Paste a Codex thread ID",
        .opencode => "Paste an OpenCode thread ID",
        .claude => "Paste a Claude thread ID",
        .cursor => "Paste a Cursor thread ID",
    };
}

fn emptyThreadImportListNotice(provider: runtime.Provider) []const u8 {
    return switch (provider) {
        .codex => "No cached Codex threads to show.",
        .opencode => "No cached OpenCode threads to show.",
        .claude => "No cached Claude threads to show.",
        .cursor => "No cached Cursor threads to show.",
    };
}
