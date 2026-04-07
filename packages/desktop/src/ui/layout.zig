//! Root native UI composition and modal routing.

const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");
const colors = @import("colors.zig");
const sidebar = @import("sidebar.zig");
const chat_panel = @import("chat_panel.zig");
const runtime = @import("runtime.zig");
const debug_window = @import("debug.zig");

/// Lays out the root window and routes to the main UI regions.
pub fn renderRoot(state: *runtime.AppState, width: f32, height: f32) void {
    state.resetUiDebugFrame();
    zgui.setNextWindowPos(.{ .x = 0.0, .y = 0.0 });
    zgui.setNextWindowSize(.{ .w = width, .h = height });

    const root_flags: zgui.WindowFlags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .no_bring_to_front_on_focus = true,
    };

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ 0.0, 0.0 } });
    defer zgui.popStyleVar(.{ .count = 2 });

    _ = zgui.begin("Verde Chat Shell", .{ .flags = root_flags });
    defer zgui.end();

    const content = zgui.getContentRegionAvail();
    // const gap = theme.clampf(content[0] * 0.012, theme.scaledUi(10.0), theme.scaledUi(18.0));
    const gap = 0;
    const sidebar_width = theme.clampf(content[0] * 0.235, theme.scaledUi(230.0), @min(theme.scaledUi(360.0), content[0] * 0.38));
    const workspace_width = @max(content[0] - sidebar_width - gap, theme.scaledUi(320.0));
    zgui.setCursorPos(.{ 0.0, 0.0 });
    sidebar.render(state, sidebar_width, 0.0);
    zgui.sameLine(.{ .spacing = gap });
    chat_panel.renderWorkspace(state, workspace_width, content[1]);
    renderImageModal(state, width, height);
    renderProjectRenameModal(state, width, height);
    renderCodexImportModal(state, width, height);
    debug_window.render(state, width, height);
}

/// Shows the attachment preview modal for the selected image.
fn renderImageModal(state: *runtime.AppState, width: f32, height: f32) void {
    const modal_path = state.modal_image_path orelse return;
    if (!zgui.isPopupOpen(runtime.IMAGE_MODAL_ID, .{})) {
        zgui.openPopup(runtime.IMAGE_MODAL_ID, .{});
    }

    const modal_padding_x: f32 = 22.0;
    const modal_padding_y: f32 = 20.0;
    const modal_width = @min(width * 0.78, 980.0);
    const modal_height = @min(height * 0.82, 760.0);
    zgui.setNextWindowPos(.{
        .x = width * 0.5,
        .y = height * 0.5,
        .cond = .appearing,
        .pivot_x = 0.5,
        .pivot_y = 0.5,
    });
    zgui.setNextWindowSize(.{
        .w = modal_width,
        .h = modal_height,
        .cond = .appearing,
    });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = 16.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ modal_padding_x, modal_padding_y } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ 10.0, 8.0 } });
    if (!zgui.beginPopupModal(runtime.IMAGE_MODAL_ID, .{
        .flags = .{
            .no_title_bar = true,
            .no_saved_settings = true,
        },
    })) {
        zgui.popStyleVar(.{ .count = 3 });
        return;
    }
    defer {
        zgui.endPopup();
        zgui.popStyleVar(.{ .count = 3 });
    }

    const window_pos = zgui.getWindowPos();
    const window_size = zgui.getWindowSize();
    const mouse_pos = zgui.getMousePos();
    const clicked_outside =
        zgui.isMouseClicked(.left) and
        (mouse_pos[0] < window_pos[0] or
            mouse_pos[1] < window_pos[1] or
            mouse_pos[0] > (window_pos[0] + window_size[0]) or
            mouse_pos[1] > (window_pos[1] + window_size[1]));
    if (clicked_outside) {
        state.closeImageModal();
        zgui.closeCurrentPopup();
        return;
    }

    const texture = state.ensureImageTexture(modal_path);
    const close_size: f32 = 28.0;
    const header_start = zgui.getCursorScreenPos();
    const header_avail = zgui.getContentRegionAvail();
    const header_gap: f32 = 12.0;
    const header_text_width = @max(header_avail[0] - close_size - header_gap, 160.0);
    const close_x = header_start[0] + header_avail[0] - close_size;
    zgui.setCursorScreenPos(.{ close_x, header_start[1] });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.rgba(46, 48, 56, 220) });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.rgba(68, 70, 79, 240) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.rgba(90, 92, 102, 255) });
    if (zgui.button("x", .{ .w = close_size, .h = close_size })) {
        state.closeImageModal();
        zgui.closeCurrentPopup();
        zgui.popStyleColor(.{ .count = 3 });
        return;
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.setCursorScreenPos(header_start);
    zgui.pushTextWrapPos(header_start[0] + header_text_width);
    zgui.textColored(theme.COLOR_WHITE, "{s}", .{std.fs.path.basename(modal_path)});
    zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{modal_path});
    zgui.popTextWrapPos();

    const title_size = zgui.calcTextSize(std.fs.path.basename(modal_path), .{ .wrap_width = header_text_width });
    const path_size = zgui.calcTextSize(modal_path, .{ .wrap_width = header_text_width });
    const header_height = @max(title_size[1] + path_size[1] + 8.0, close_size);
    zgui.setCursorScreenPos(.{ header_start[0], header_start[1] + header_height + 14.0 });
    zgui.separator();
    zgui.dummy(.{ .w = 0.0, .h = 6.0 });

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 16.0, 16.0 } });
    _ = zgui.beginChild("AttachmentPreviewCanvas", .{
        .w = 0.0,
        .h = 0.0,
        .child_flags = .{ .border = true },
        .window_flags = .{},
    });
    defer {
        zgui.endChild();
        zgui.popStyleVar(.{ .count = 1 });
    }

    const avail = zgui.getContentRegionAvail();
    const image_max_w = @max(avail[0], 80.0);
    const image_max_h = @max(avail[1], 80.0);

    if (texture) |cached| {
        const dims = runtime.scaledImageSize(cached.width, cached.height, image_max_w, image_max_h);
        const x_offset = (image_max_w - dims[0]) * 0.5;
        const y_offset = (image_max_h - dims[1]) * 0.5;
        if (y_offset > 0.0) zgui.dummy(.{ .w = 0.0, .h = y_offset });
        if (x_offset > 0.0) zgui.setCursorPosX(zgui.getCursorPosX() + x_offset);
        zgui.image(runtime.textureRefFromGlId(cached.texture_id), .{
            .w = dims[0],
            .h = dims[1],
        });
    } else {
        _ = zgui.button("Preview unavailable", .{ .w = image_max_w, .h = @min(image_max_h, 240.0) });
    }
}

/// Shows the modal used to rename the active project.
fn renderProjectRenameModal(state: *runtime.AppState, width: f32, height: f32) void {
    const rename_index = state.rename_project_index orelse return;
    if (rename_index >= state.projects.items.len) {
        state.rename_project_index = null;
        return;
    }

    if (!zgui.isPopupOpen(runtime.PROJECT_RENAME_MODAL_ID, .{})) {
        zgui.openPopup(runtime.PROJECT_RENAME_MODAL_ID, .{});
    }

    zgui.setNextWindowPos(.{
        .x = width * 0.5,
        .y = height * 0.5,
        .cond = .appearing,
        .pivot_x = 0.5,
        .pivot_y = 0.5,
    });
    zgui.setNextWindowSize(.{
        .w = theme.clampf(width * 0.28, theme.scaledUi(320.0), theme.scaledUi(420.0)),
        .h = 0.0,
        .cond = .appearing,
    });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = theme.scaledUi(16.0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(18.0), theme.scaledUi(18.0) } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ theme.scaledUi(10.0), theme.scaledUi(10.0) } });
    var modal_open = true;
    if (!zgui.beginPopupModal(runtime.PROJECT_RENAME_MODAL_ID, .{
        .popen = &modal_open,
        .flags = .{ .no_saved_settings = true },
    })) {
        if (!modal_open) state.cancelProjectRename();
        zgui.popStyleVar(.{ .count = 3 });
        return;
    }
    defer {
        zgui.endPopup();
        zgui.popStyleVar(.{ .count = 3 });
    }

    if (zgui.isWindowAppearing()) {
        zgui.setKeyboardFocusHere(0);
    }

    zgui.textColored(theme.COLOR_WHITE, "Rename project", .{});
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{s}", .{state.projects.items[rename_index].path});

    const modal_width = zgui.getContentRegionAvail()[0];
    _ = zgui.inputTextWithHint("##project-rename-modal", .{
        .hint = "Project label",
        .buf = state.renameBuffer(),
    });

    const button_width = @max((modal_width - theme.scaledUi(10.0)) * 0.5, theme.scaledUi(96.0));
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("Cancel", .{ .w = button_width, .h = theme.scaledUi(34.0) })) {
        state.cancelProjectRename();
        zgui.closeCurrentPopup();
        zgui.popStyleColor(.{ .count = 3 });
        return;
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_SECONDARY_GREEN });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.10) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) });
    if (zgui.button("Rename", .{ .w = button_width, .h = theme.scaledUi(34.0) })) {
        state.finishProjectRename();
        zgui.closeCurrentPopup();
        zgui.popStyleColor(.{ .count = 3 });
        return;
    }
    zgui.popStyleColor(.{ .count = 3 });
}

fn renderCodexImportModal(state: *runtime.AppState, width: f32, height: f32) void {
    const project_index = state.codex_import_project_index orelse return;
    if (project_index >= state.projects.items.len) {
        state.cancelCodexThreadImport();
        return;
    }

    if (!zgui.isPopupOpen(runtime.CODEX_IMPORT_MODAL_ID, .{})) {
        zgui.openPopup(runtime.CODEX_IMPORT_MODAL_ID, .{});
    }

    zgui.setNextWindowPos(.{
        .x = width * 0.5,
        .y = height * 0.5,
        .cond = .appearing,
        .pivot_x = 0.5,
        .pivot_y = 0.5,
    });
    zgui.setNextWindowSize(.{
        .w = theme.clampf(width * 0.42, theme.scaledUi(460.0), theme.scaledUi(640.0)),
        .h = theme.clampf(height * 0.66, theme.scaledUi(420.0), theme.scaledUi(620.0)),
        .cond = .appearing,
    });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = theme.scaledUi(16.0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(18.0), theme.scaledUi(18.0) } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ theme.scaledUi(10.0), theme.scaledUi(10.0) } });
    var modal_open = true;
    if (!zgui.beginPopupModal(runtime.CODEX_IMPORT_MODAL_ID, .{
        .popen = &modal_open,
        .flags = .{ .no_saved_settings = true },
    })) {
        if (!modal_open) state.cancelCodexThreadImport();
        zgui.popStyleVar(.{ .count = 3 });
        return;
    }
    defer {
        zgui.endPopup();
        zgui.popStyleVar(.{ .count = 3 });
    }

    if (zgui.isWindowAppearing()) {
        zgui.setKeyboardFocusHere(0);
    }

    const project = &state.projects.items[project_index];
    zgui.textColored(theme.COLOR_WHITE, "Import Codex thread", .{});
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Project: {s}", .{project.label});
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{s}", .{project.path});
    zgui.textWrapped("Import loads the existing Codex transcript into this project and binds future turns to the same thread.", .{});

    _ = zgui.inputTextWithHint("##codex-thread-id", .{
        .hint = "Paste a Codex thread ID",
        .buf = state.codexImportThreadIdBuffer(),
    });

    const actions_width = zgui.getContentRegionAvail()[0];
    const refresh_width = @max(theme.scaledUi(104.0), actions_width * 0.28);
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("Refresh list", .{ .w = refresh_width, .h = theme.scaledUi(32.0) })) {
        state.refreshCodexThreadImportList();
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.separator();
    _ = zgui.beginChild("CodexImportThreadList", .{
        .w = 0.0,
        .h = -theme.scaledUi(92.0),
        .child_flags = .{ .border = true },
        .window_flags = .{},
    });

    if (state.codex_import_threads.items.len == 0) {
        zgui.textColored(theme.COLOR_TEXT_SUBTLE, "No cached Codex threads to show.", .{});
    } else {
        for (state.codex_import_threads.items, 0..) |thread, index| {
            zgui.pushIntId(@intCast(index + 4000));
            defer zgui.popId();

            const selected = state.codex_import_selected_index != null and state.codex_import_selected_index.? == index;
            if (zgui.selectable(thread.title, .{
                .selected = selected,
                .w = 0.0,
                .h = theme.scaledUi(26.0),
            })) {
                state.selectCodexImportThread(index);
            }
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{s}", .{thread.id});
            if (index + 1 < state.codex_import_threads.items.len) {
                zgui.separator();
            }
        }
    }
    zgui.endChild();

    if (state.codexImportNotice().len > 0) {
        zgui.textColored(theme.COLOR_YELLOW, "{s}", .{state.codexImportNotice()});
    }

    const button_width = @max((zgui.getContentRegionAvail()[0] - theme.scaledUi(10.0)) * 0.5, theme.scaledUi(120.0));
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("Cancel", .{ .w = button_width, .h = theme.scaledUi(34.0) })) {
        state.cancelCodexThreadImport();
        zgui.closeCurrentPopup();
        zgui.popStyleColor(.{ .count = 3 });
        return;
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_SECONDARY_GREEN });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.10) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) });
    if (zgui.button("Import", .{ .w = button_width, .h = theme.scaledUi(34.0) })) {
        state.importSelectedCodexThread();
        if (state.codex_import_project_index == null) {
            zgui.closeCurrentPopup();
            zgui.popStyleColor(.{ .count = 3 });
            return;
        }
    }
    zgui.popStyleColor(.{ .count = 3 });
}
