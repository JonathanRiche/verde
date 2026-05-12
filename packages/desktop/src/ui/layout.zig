//! Root native UI composition and modal routing.

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");
const theme = @import("theme.zig");
const colors = @import("colors.zig");
const sidebar = @import("sidebar.zig");
const chat_panel = @import("chat_panel.zig");
const runtime = @import("runtime.zig");
const debug_window = @import("debug.zig");

const RootLayout = struct {
    sidebar: palette.Rect,
    workspace: palette.Rect,
};

/// Rebuilds palette modal hit targets from the current window size **before** SDL input is
/// processed. `renderRoot` runs after `processEvents`, so hits must not depend on that order.
pub fn refreshPaletteModalHits(state: *runtime.AppState, width: f32, height: f32) void {
    state.palette_modal_hits.clearRetainingCapacity();
    registerImageModalHits(state, width, height);
    registerTranscriptSelectionModalHits(state, width, height);
    registerProjectAddModalHits(state, width, height);
    registerProjectRenameModalHits(state, width, height);
    registerThreadImportModalHits(state, width, height);
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

fn rectContainsModalPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

/// Lays out the root window and routes to the main UI regions.
pub fn renderRoot(state: *runtime.AppState, width: f32, height: f32) void {
    state.resetUiDebugFrame();
    const root_layout = computeRootLayout(state, width, height);
    queueRootBackground(state, width, height);
    sidebar.renderPalette(state, root_layout.sidebar);
    chat_panel.renderWorkspaceAt(state, root_layout.workspace);
    renderImageModal(state, width, height);
    renderTranscriptSelectionModal(state, width, height);
    renderProjectAddModal(state, width, height);
    renderProjectRenameModal(state, width, height);
    renderThreadImportModal(state, width, height);
    debug_window.render(state, width, height);
}

fn computeRootLayout(state: *runtime.AppState, width: f32, height: f32) RootLayout {
    const gap: f32 = 0.0;
    const sidebar_width = if (state.isSidebarCollapsed())
        theme.clampf(width * 0.07, theme.scaledUi(60.0), theme.scaledUi(76.0))
    else if (width < theme.scaledUi(900.0))
        theme.clampf(width * 0.34, theme.scaledUi(180.0), theme.scaledUi(240.0))
    else
        theme.clampf(width * 0.235, theme.scaledUi(300.0), @min(theme.scaledUi(465.0), width * 0.38));
    const workspace_width = @max(width - sidebar_width - gap, theme.scaledUi(320.0));
    return .{
        .sidebar = .{ .x = 0.0, .y = 0.0, .w = sidebar_width, .h = height },
        .workspace = .{ .x = sidebar_width + gap, .y = 0.0, .w = workspace_width, .h = height },
    };
}

fn queueRootBackground(state: *runtime.AppState, width: f32, height: f32) void {
    state.palette_overlay_batch.rect(state.allocator, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, paletteColor(colors.CHAT_BLACK)) catch |err| {
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
    const start = state.palette_frame_text.items.len;
    try state.palette_frame_text.appendSlice(state.allocator, value);
    return state.palette_frame_text.items[start .. start + value.len];
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
    queuePaletteRoundedRect(state, rect, paletteColor(color), theme.scaledUi(7.0));
    queuePaletteBorder(state, rect, paletteColor(theme.lighten(color, 0.06)), theme.scaledUi(7.0), theme.scaledUi(1.0));
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
    queuePaletteRoundedRect(state, scrim, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.46 }, 0.0);
    queuePaletteRoundedRect(state, modal, paletteColor(colors.rgba(24, 25, 30, 248)), theme.scaledUi(16.0));
    queuePaletteBorder(state, modal, paletteColor(colors.rgba(74, 78, 88, 255)), theme.scaledUi(16.0), theme.scaledUi(1.0));
}

fn registerModalChromeHits(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect, dismissible: bool) void {
    const scrim: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = width, .h = height };
    if (dismissible) queueModalHit(state, scrim, .modal_dismiss, 0);
    queueModalHit(state, modal, .modal_block, 0);
}

fn drawTextField(state: *runtime.AppState, rect: palette.Rect, value: []const u8, hint: []const u8, focused: bool, cursor: usize) void {
    const border = if (focused) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_MUTED;
    queuePaletteRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(7.0));
    queuePaletteBorder(state, rect, paletteColor(border), theme.scaledUi(7.0), theme.scaledUi(1.0));
    const text = if (value.len > 0) value else hint;
    const color = if (value.len > 0) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE;
    const font_size = theme.scaledUi(14.0);
    queuePaletteText(state, .{ .x = rect.x + theme.scaledUi(10.0), .y = rect.y + theme.scaledUi(8.0), .w = rect.w - theme.scaledUi(20.0), .h = theme.scaledUi(20.0) }, text, paletteColor(color), font_size, rect);
    if (focused) {
        const clamped_cursor = @min(cursor, value.len);
        const cursor_x = rect.x + theme.scaledUi(10.0) + @as(f32, @floatFromInt(clamped_cursor)) * font_size * 0.55;
        state.palette_overlay_batch.rect(state.allocator, .{ .x = cursor_x, .y = rect.y + theme.scaledUi(8.0), .w = theme.scaledUi(1.0), .h = rect.h - theme.scaledUi(16.0) }, paletteColor(theme.COLOR_WHITE)) catch {};
    }
}

fn pointInRect(x: f32, y: f32, rect: palette.Rect) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    if (state.palette_modal_hits.items.len == 0) return false;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (!pointInRect(x, y, hit.rect)) continue;
        if (hit.action == .project_import_browse) {
            runtime.log.info("project import browse hit down={} x={d:.1} y={d:.1}", .{ down, x, y });
            if (!down) state.requestBrowseForProjectDirectory();
            return true;
        }
        if (!down) return true;
        switch (hit.action) {
            .image_close => state.closeImageModal(),
            .project_rename_cancel => state.cancelProjectRename(),
            .project_rename_submit => state.finishProjectRename(),
            .transcript_close => state.closeTranscriptSelectionModal(),
            .thread_import_refresh => state.refreshThreadImportList(),
            .thread_import_cancel => state.cancelThreadImport(),
            .thread_import_submit => state.importSelectedThread(),
            .thread_import_select => state.selectThreadImport(hit.index),
            .project_import_browse => unreachable,
            .project_import_submit => {
                state.importProjectFromInput() catch |err| {
                    runtime.log.warn("project import failed: {s}", .{@errorName(err)});
                    state.setSidebarNotice("Could not add that directory path.");
                };
            },
            .project_import_cancel => state.cancelProjectImport(),
            .modal_dismiss => dismissTopModal(state),
            .modal_block => state.palette_modal_text_focus = .none,
            .project_rename_input => {
                state.palette_modal_text_focus = .project_rename;
                state.project_rename_cursor = state.renameInputPublic().len;
            },
            .thread_import_input => {
                state.palette_modal_text_focus = .thread_import;
                state.thread_import_cursor = state.threadImportThreadId().len;
            },
            .project_import_input => {
                state.palette_modal_text_focus = .project_import;
                state.project_import_cursor = state.importDirectoryDraft().len;
            },
        }
        return true;
    }
    return true;
}

pub fn handlePaletteTextInput(state: *runtime.AppState, text: []const u8) bool {
    return switch (state.palette_modal_text_focus) {
        .project_rename => insertIntoZBuffer(state.renameBuffer(), &state.project_rename_cursor, text),
        .thread_import => insertIntoZBuffer(state.threadImportThreadIdBuffer(), &state.thread_import_cursor, text),
        .project_import => insertIntoZBuffer(state.importPathBuffer(), &state.project_import_cursor, text),
        .none => false,
    };
}

pub fn handlePaletteKeyDown(state: *runtime.AppState, event: *const sdl.KeyboardEvent) bool {
    if (state.modal_image_path == null and state.rename_project_index == null and state.transcriptSelectionBuffer() == null and state.thread_import_provider == null and !state.show_project_creator) return false;
    switch (event.key) {
        .escape => {
            dismissTopModal(state);
            return true;
        },
        .@"return", .kp_enter => {
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
                    runtime.log.warn("project import failed: {s}", .{@errorName(err)});
                    state.setSidebarNotice("Could not add that directory path.");
                };
                return true;
            }
            return false;
        },
        .left => return moveModalCursor(state, -1),
        .right => return moveModalCursor(state, 1),
        .home => return moveModalCursorToEdge(state, true),
        .end => return moveModalCursorToEdge(state, false),
        .backspace => return deleteModalText(state, true),
        .delete => return deleteModalText(state, false),
        .c => {
            if (state.transcriptSelectionBuffer()) |text| {
                if ((keymodBits(event.mod) & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0) {
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
        else => return true,
    }
}

fn dismissTopModal(state: *runtime.AppState) void {
    if (state.modal_image_path != null) {
        state.closeImageModal();
    } else if (state.transcriptSelectionBuffer() != null) {
        state.closeTranscriptSelectionModal();
    } else if (state.show_project_creator) {
        state.cancelProjectImport();
    } else if (state.rename_project_index != null) {
        state.cancelProjectRename();
    } else if (state.thread_import_provider != null) {
        state.cancelThreadImport();
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
        .none => null,
    };
}

fn focusedBuffer(state: *runtime.AppState) ?[:0]u8 {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.renameBuffer(),
        .thread_import => state.threadImportThreadIdBuffer(),
        .project_import => state.importPathBuffer(),
        .none => null,
    };
}

fn focusedTextLen(state: *runtime.AppState) usize {
    return switch (state.palette_modal_text_focus) {
        .project_rename => state.renameInputPublic().len,
        .thread_import => state.threadImportThreadId().len,
        .project_import => state.importDirectoryDraft().len,
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

fn registerProjectAddModalHits(state: *runtime.AppState, width: f32, height: f32) void {
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
    const browse_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(36.0) };
    queueModalHit(state, browse_rect, .project_import_browse, 0);
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

fn registerProjectRenameModalHits(state: *runtime.AppState, width: f32, height: f32) void {
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

/// Shows the attachment preview modal for the selected image.
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
    drawActionButton(state, close_rect, "x", colors.rgba(46, 48, 56, 220));
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

/// Shows the modal used to rename the active project.
fn renderProjectRenameModal(state: *runtime.AppState, width: f32, height: f32) void {
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
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + pad, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "Rename project", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(44.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(20.0) }, state.projects.items[rename_index].path, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = modal.y + theme.scaledUi(76.0), .w = modal.w - pad * 2.0, .h = theme.scaledUi(34.0) };
    drawTextField(state, input_rect, state.renameInputPublic(), "Project label", state.palette_modal_text_focus == .project_rename, state.project_rename_cursor);
    const gap = theme.scaledUi(10.0);
    const button_w = (input_rect.w - gap) * 0.5;
    const cancel_rect: palette.Rect = .{ .x = input_rect.x, .y = modal.y + modal.h - pad - theme.scaledUi(34.0), .w = button_w, .h = theme.scaledUi(34.0) };
    const submit_rect: palette.Rect = .{ .x = cancel_rect.x + cancel_rect.w + gap, .y = cancel_rect.y, .w = button_w, .h = cancel_rect.h };
    drawActionButton(state, cancel_rect, "Cancel", theme.COLOR_PANEL_ALT);
    drawActionButton(state, submit_rect, "Rename", theme.COLOR_SECONDARY_GREEN);
}

fn renderProjectAddModal(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.show_project_creator) return;
    const modal_w = theme.clampf(width * 0.34, theme.scaledUi(360.0), theme.scaledUi(500.0));
    const notice = state.sidebarNotice();
    const notice_h: f32 = if (notice.len > 0) theme.scaledUi(24.0) else 0.0;
    const modal_h = theme.scaledUi(252.0) + notice_h;
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    drawModalChromeVisual(state, width, height, modal);
    const pad = theme.scaledUi(18.0);
    var y = modal.y + pad;
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "Add project", paletteColor(theme.COLOR_WHITE), theme.scaledUi(17.0), modal);
    y += theme.scaledUi(30.0);
    queuePaletteText(state, .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(40.0) }, "Choose a directory for a new workspace, or paste a path below.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), modal);
    y += theme.scaledUi(48.0);
    const browse_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0, .h = theme.scaledUi(36.0) };
    drawActionButton(state, browse_rect, "Browse for folder", theme.COLOR_PANEL_ALT);
    y += theme.scaledUi(44.0);
    const add_w = theme.scaledUi(76.0);
    const row_gap = theme.scaledUi(10.0);
    const input_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = modal.w - pad * 2.0 - add_w - row_gap, .h = theme.scaledUi(34.0) };
    const add_rect: palette.Rect = .{ .x = input_rect.x + input_rect.w + row_gap, .y = y, .w = add_w, .h = theme.scaledUi(34.0) };
    drawTextField(state, input_rect, state.importDirectoryDraft(), "/path/to/project", state.palette_modal_text_focus == .project_import, state.project_import_cursor);
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
    drawActionButton(state, refresh_rect, "Refresh list", theme.COLOR_PANEL_ALT);
    y += theme.scaledUi(42.0);
    const notice_h = if (state.threadImportNotice().len > 0) theme.scaledUi(24.0) else 0.0;
    const button_h = theme.scaledUi(34.0);
    const list_rect: palette.Rect = .{ .x = modal.x + pad, .y = y, .w = input_rect.w, .h = modal.y + modal.h - pad - button_h - notice_h - theme.scaledUi(16.0) - y };
    queuePaletteRoundedRect(state, list_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(8.0));
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
                queuePaletteRoundedRect(state, row, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.14)), theme.scaledUi(6.0));
                queuePaletteBorder(state, row, paletteColor(theme.lighten(colors.DARK_BLUE, 0.02)), theme.scaledUi(6.0), theme.scaledUi(1.0));
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
    drawActionButton(state, cancel_rect, "Cancel", theme.COLOR_PANEL_ALT);
    drawActionButton(state, submit_rect, "Import", theme.COLOR_SECONDARY_GREEN);
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
        .codex => "Import loads the existing Codex transcript into this project and binds future turns to the same thread.",
        .opencode => "Import loads the existing OpenCode transcript into this project and binds future turns to the same thread.",
        .claude => "Import loads the existing Claude transcript into this project and binds future turns to the same thread.",
        .cursor => "Import loads the existing Cursor transcript into this project and binds future turns to the same thread.",
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
