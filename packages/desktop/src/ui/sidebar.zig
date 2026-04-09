//! Project rail rendering for the native shell.

const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");
const colors = @import("colors.zig");
const runtime = @import("runtime.zig");
const native_state = @import("../state.zig");
const Provider = native_state.Provider;

/// Renders the full project rail and thread list.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    _ = height;
    const horiz_pad = theme.scaledUi(25.0);
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 0.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    defer zgui.popStyleVar(.{ .count = 2 });
    zgui.setCursorPos(.{ 0.0, 0.0 });
    _ = zgui.beginChild("ProjectsRail", .{
        .w = width,
        .h = zgui.getContentRegionAvail()[1],
        .child_flags = .{ .border = false },
        .window_flags = .{ .no_scrollbar = true },
    });
    defer zgui.endChild();

    // Use explicit indent for left padding — window_padding doesn't
    // propagate reliably to child window auto-layout in this zgui version.
    zgui.indent(.{ .indent_w = horiz_pad });
    defer zgui.unindent(.{ .indent_w = horiz_pad });

    const pad_top = theme.scaledUi(20.0);
    const rail_width = @max(width - 2 * horiz_pad, theme.scaledUi(100.0));
    zgui.setCursorPos(.{ horiz_pad, pad_top });

    {
        const draw_list = zgui.getWindowDrawList();
        const pos = zgui.getWindowPos();
        const size = zgui.getWindowSize();
        draw_list.addLine(.{
            .p1 = .{ pos[0] + size[0] - 1.0, pos[1] },
            .p2 = .{ pos[0] + size[0] - 1.0, pos[1] + size[1] },
            // .col = zgui.colorConvertFloat4ToU32(colors.rgba(90, 96, 108, 255)),

            .col = zgui.colorConvertFloat4ToU32(colors.DARK_BLUE),
            .thickness = 2.0,
        });
    }

    const project_header_button_width = theme.clampf(rail_width * 0.11, theme.scaledUi(28.0), theme.scaledUi(38.0));
    const rail_inner_width = @max(rail_width, theme.scaledUi(140.0));
    renderBrand(state, width);
    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(18.0) });
    zgui.textColored(theme.COLOR_TEXT_MUTED, "PROJECTS", .{});
    zgui.sameLine(.{ .spacing = 0.0 });
    zgui.setCursorPosX(@max(zgui.getCursorPosX(), width - horiz_pad - project_header_button_width));
    if (state.show_project_creator) {
        zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.06) });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.12) });
        if (zgui.button("x", .{ .w = project_header_button_width, .h = theme.scaledUi(24.0) })) {
            state.show_project_creator = false;
            state.clearImportPath();
            state.setSidebarNotice("");
        }
        zgui.popStyleColor(.{ .count = 3 });
    } else {
        zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_SECONDARY_GREEN });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.10) });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) });
        if (zgui.button("+", .{ .w = project_header_button_width, .h = theme.scaledUi(24.0) })) {
            state.show_project_creator = true;
            state.setSidebarNotice("");
        }
        zgui.popStyleColor(.{ .count = 3 });
    }

    if (state.show_project_creator) {
        const add_button_width = theme.clampf(rail_inner_width * 0.24, theme.scaledUi(60.0), theme.scaledUi(92.0));
        const field_spacing = theme.scaledUi(8.0);
        zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(6.0) });
        zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ theme.scaledUi(12.0), theme.scaledUi(10.0) } });
        zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ field_spacing, field_spacing } });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.05) });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.10) });
        zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
        if (zgui.button("[]  Browse for folder", .{ .w = rail_inner_width, .h = theme.scaledUi(40.0) })) {
            state.browseForProjectDirectory();
        }
        zgui.popStyleColor(.{ .count = 4 });

        zgui.pushItemWidth(@max(rail_inner_width - add_button_width - field_spacing, theme.scaledUi(80.0)));
        _ = zgui.inputTextWithHint("##project-import", .{
            .hint = "/path/to/project",
            .buf = state.importPathBuffer(),
        });
        zgui.popItemWidth();
        zgui.sameLine(.{ .spacing = field_spacing });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_SECONDARY_GREEN });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.10) });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) });
        if (zgui.button("Add", .{ .w = add_button_width, .h = theme.scaledUi(40.0) })) {
            state.importProjectFromInput() catch |err| {
                state.setSidebarNotice(@errorName(err));
            };
        }
        zgui.popStyleColor(.{ .count = 3 });

        if (state.sidebarNotice().len > 0) {
            zgui.textColored(theme.COLOR_YELLOW, "{s}", .{state.sidebarNotice()});
        }
        zgui.popStyleVar(.{ .count = 2 });
        zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(4.0) });
    }

    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(8.0) });

    var index: usize = 0;
    while (index < state.projects.items.len) : (index += 1) {
        const project = &state.projects.items[index];
        zgui.pushIntId(@intCast(index));
        defer zgui.popId();

        const is_selected = state.selected_project_index == index;
        const is_collapsed = state.projects.items[index].collapsed;
        const project_action_width = theme.clampf(rail_width * 0.11, theme.scaledUi(28.0), theme.scaledUi(38.0));
        const row_width = @max(rail_width - project_action_width - theme.scaledUi(6.0), theme.scaledUi(100.0));
        const row_height = theme.scaledUi(28.0);

        {
            const row_pos = zgui.getCursorScreenPos();
            _ = zgui.invisibleButton("##project-row", .{ .w = row_width, .h = row_height });
            const left_clicked = zgui.isItemClicked(.left);
            const hovered = zgui.isItemHovered(.{});
            const dl = zgui.getWindowDrawList();

            if (is_selected or hovered) {
                const bg_col = if (is_selected and hovered)
                    theme.lighten(colors.CHAT_BLACK, 0.06)
                else if (is_selected)
                    colors.CHAT_BLACK
                else
                    colors.rgba(36, 38, 44, 255);
                dl.addRectFilled(.{
                    .pmin = row_pos,
                    .pmax = .{ row_pos[0] + row_width, row_pos[1] + row_height },
                    .col = zgui.colorConvertFloat4ToU32(bg_col),
                    .rounding = theme.scaledUi(6.0),
                });
            }

            const cy = row_pos[1] + row_height * 0.5;
            var x = row_pos[0] + theme.scaledUi(2.0);
            const chevron_col = zgui.colorConvertFloat4ToU32(if (hovered) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE);
            const cs: f32 = theme.scaledUi(4.5);
            if (is_collapsed) {
                dl.addTriangleFilled(.{
                    .p1 = .{ x - cs * 0.3, cy - cs },
                    .p2 = .{ x + cs * 0.8, cy },
                    .p3 = .{ x - cs * 0.3, cy + cs },
                    .col = chevron_col,
                });
            } else {
                dl.addTriangleFilled(.{
                    .p1 = .{ x - cs, cy - cs * 0.3 },
                    .p2 = .{ x + cs, cy - cs * 0.3 },
                    .p3 = .{ x, cy + cs * 0.8 },
                    .col = chevron_col,
                });
            }
            x += theme.scaledUi(8.0);

            // Folder icon: filled green for selected, outline for others
            const fw = theme.scaledUi(13.0);
            const fh = theme.scaledUi(9.0);
            if (is_selected) {
                const folder_fill = zgui.colorConvertFloat4ToU32(theme.COLOR_SECONDARY_GREEN);
                dl.addRectFilled(.{
                    .pmin = .{ x, cy - fh * 0.5 - theme.scaledUi(2.0) },
                    .pmax = .{ x + fw * 0.4, cy - fh * 0.5 + theme.scaledUi(1.0) },
                    .col = folder_fill,
                    .rounding = theme.scaledUi(1.0),
                });
                dl.addRectFilled(.{
                    .pmin = .{ x, cy - fh * 0.5 },
                    .pmax = .{ x + fw, cy + fh * 0.5 },
                    .col = folder_fill,
                    .rounding = theme.scaledUi(1.5),
                });
            } else {
                const folder_outline = zgui.colorConvertFloat4ToU32(theme.COLOR_TEXT_SUBTLE);
                const ft = theme.scaledUi(1.4);
                dl.addRectFilled(.{
                    .pmin = .{ x, cy - fh * 0.5 - theme.scaledUi(2.0) },
                    .pmax = .{ x + fw * 0.4, cy - fh * 0.5 + theme.scaledUi(1.0) },
                    .col = folder_outline,
                    .rounding = theme.scaledUi(1.0),
                });
                dl.addRect(.{
                    .pmin = .{ x, cy - fh * 0.5 },
                    .pmax = .{ x + fw, cy + fh * 0.5 },
                    .col = folder_outline,
                    .rounding = theme.scaledUi(1.5),
                    .thickness = ft,
                });
            }
            x += fw + theme.scaledUi(4.0);

            const text_col = zgui.colorConvertFloat4ToU32(if (is_selected) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED);
            dl.addText(.{ x, cy - zgui.getFontSize() * 0.5 }, text_col, "{s}", .{project.label});

            if (left_clicked) {
                state.noteInteraction();
                state.selected_project_index = index;
                state.projects.items[index].collapsed = !state.projects.items[index].collapsed;
                state.syncRenameBuffer();
                state.requestTranscriptScrollToBottom();
                state.markDirty();
            }

            if (zgui.beginPopupContextItem()) {
                defer zgui.endPopup();

                state.noteInteraction();
                state.selected_project_index = index;
                state.syncRenameBuffer();

                if (zgui.menuItem("Rename project", .{})) {
                    state.beginProjectRename(index);
                    zgui.openPopup(runtime.PROJECT_RENAME_MODAL_ID, .{});
                    zgui.closeCurrentPopup();
                }
                if (zgui.menuItem("Import Codex thread", .{})) {
                    state.beginThreadImport(index, .codex);
                    zgui.openPopup(runtime.THREAD_IMPORT_MODAL_ID, .{});
                    zgui.closeCurrentPopup();
                }
                if (zgui.menuItem("Import OpenCode thread", .{})) {
                    state.beginThreadImport(index, .opencode);
                    zgui.openPopup(runtime.THREAD_IMPORT_MODAL_ID, .{});
                    zgui.closeCurrentPopup();
                }
                if (zgui.menuItem("Archive project", .{})) {
                    state.archiveProjectAtIndex(index);
                    zgui.closeCurrentPopup();
                    break;
                }
            }
        }

        zgui.sameLine(.{});
        zgui.setCursorPosX(width - horiz_pad - project_action_width);
        if (renderThreadEditButton(state, project_action_width, row_height)) {
            state.createThreadForProject(index);
            break;
        }
        if (zgui.isItemHovered(.{ .delay_normal = true })) {
            _ = zgui.beginTooltip();
            zgui.textUnformatted("Start a new chat");
            zgui.endTooltip();
        }

        const active_thread = state.projects.items[index].currentThread();
        const sub_indent = theme.scaledUi(20.0);
        if (!is_collapsed) zgui.indent(.{ .indent_w = sub_indent });
        if (!is_collapsed) {
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{d} saved chats", .{state.projects.items[index].committedThreadCount()});
        }
        if (!is_collapsed) {
            var sorted_indices = collectCommittedThreadIndicesSorted(state.allocator, &state.projects.items[index]) catch blk: {
                break :blk std.ArrayList(usize).empty;
            };
            defer sorted_indices.deinit(state.allocator);

            const show_all_threads = state.projects.items[index].thread_list_expanded or sorted_indices.items.len <= runtime.SIDEBAR_VISIBLE_THREAD_LIMIT;
            const visible_count = if (show_all_threads) sorted_indices.items.len else @min(sorted_indices.items.len, runtime.SIDEBAR_VISIBLE_THREAD_LIMIT);

            for (sorted_indices.items[0..visible_count]) |thread_index| {
                const thread = &state.projects.items[index].threads.items[thread_index];
                renderThreadRow(state, index, rail_width - sub_indent, thread, thread_index);
            }

            if (sorted_indices.items.len > runtime.SIDEBAR_VISIBLE_THREAD_LIMIT) {
                zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(4.0) });
                if (zgui.button(if (state.projects.items[index].thread_list_expanded) "Show less" else "Show more", .{
                    .w = @max(rail_width - sub_indent, theme.scaledUi(110.0)),
                    .h = theme.scaledUi(28.0),
                })) {
                    state.projects.items[index].thread_list_expanded = !state.projects.items[index].thread_list_expanded;
                    state.markDirty();
                }
                zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(4.0) });
            }
            if (sorted_indices.items.len == 0 and is_selected and !active_thread.committed) {
                zgui.textColored(theme.COLOR_TEXT_SUBTLE, "New chat will appear here after the first prompt.", .{});
            } else if (sorted_indices.items.len == 0) {
                zgui.textColored(theme.COLOR_TEXT_SUBTLE, "No saved threads yet", .{});
            }
        }
        if (state.projects.items[index].unread_count > 0) {
            zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
            zgui.textColored(theme.COLOR_YELLOW, "{d} pending", .{state.projects.items[index].unread_count});
        }
        if (!is_collapsed) zgui.unindent(.{ .indent_w = sub_indent });
        zgui.spacing();
    }
}

/// New-thread button using the loaded edit texture, transparent bg with hover highlight.
fn renderThreadEditButton(state: *runtime.AppState, width: f32, height: f32) bool {
    const start = zgui.getCursorScreenPos();
    const clicked = zgui.invisibleButton("##thread-edit-button", .{ .w = width, .h = height });
    const hovered = zgui.isItemHovered(.{});
    const draw_list = zgui.getWindowDrawList();

    // Only show bg on hover
    if (hovered) {
        draw_list.addRectFilled(.{
            .pmin = start,
            .pmax = .{ start[0] + width, start[1] + height },
            .col = zgui.colorConvertFloat4ToU32(theme.lighten(theme.COLOR_PANEL_ALT, 0.10)),
            .rounding = theme.scaledUi(6.0),
        });
    }

    if (state.thread_edit_texture) |cached| {
        const icon_size = theme.clampf(@min(width, height) - theme.scaledUi(8.0), theme.scaledUi(14.0), theme.scaledUi(18.0));
        const image_min = .{
            start[0] + (width - icon_size) * 0.5,
            start[1] + (height - icon_size) * 0.5,
        };
        draw_list.addImage(runtime.textureRefFromGlId(cached.texture_id), .{
            .pmin = image_min,
            .pmax = .{ image_min[0] + icon_size, image_min[1] + icon_size },
        });
    }

    return clicked;
}

/// Draws the sidebar brand row with logo and title, centered horizontally.
fn renderBrand(state: *runtime.AppState, sidebar_width: f32) void {
    const start = zgui.getCursorPos();
    const spacing = theme.scaledUi(10.0);
    const fallback_logo_size = theme.scaledUi(28.0);
    const title_text = "verde";

    var text_size = zgui.calcTextSize(title_text, .{});
    if (theme.heading_font) |font| {
        zgui.pushFont(font, theme.heading_font_size);
        text_size = zgui.calcTextSize(title_text, .{});
        zgui.popFont();
    }

    // Measure logo dimensions without rendering
    var logo_width: f32 = 0.0;
    var logo_height: f32 = 0.0;
    if (state.logo_texture) |cached| {
        const target_height = @max(text_size[1] * 1.6, fallback_logo_size);
        const aspect_ratio = @as(f32, @floatFromInt(cached.width)) / @as(f32, @floatFromInt(cached.height));
        logo_height = target_height;
        logo_width = logo_height * aspect_ratio;
    }

    // Left-align the logo+text group with sidebar content
    _ = sidebar_width;
    const brand_x = start[0];
    const row_height = @max(logo_height, text_size[1]);

    if (state.logo_texture) |cached| {
        zgui.setCursorPos(.{ brand_x, start[1] });
        zgui.image(runtime.textureRefFromGlId(cached.texture_id), .{
            .w = logo_width,
            .h = logo_height,
        });
        zgui.sameLine(.{ .spacing = spacing });
    }

    const text_x = brand_x + if (logo_width > 0.0) logo_width + spacing else 0.0;
    const text_y = start[1] + (row_height - text_size[1]) * 0.5;
    zgui.setCursorPos(.{ text_x, text_y });
    if (theme.heading_font) |font| {
        zgui.pushFont(font, theme.heading_font_size);
        zgui.textColored(theme.COLOR_WHITE, title_text, .{});
        zgui.popFont();
    } else {
        zgui.textColored(theme.COLOR_WHITE, title_text, .{});
    }
    // Restore cursor for left-aligned content below
    zgui.setCursorPos(.{ start[0], start[1] + row_height });
}

/// Draws one saved thread row under the active project.
fn renderThreadRow(state: anytype, project_index: usize, width: f32, thread: anytype, thread_index: usize) void {
    const project = &state.projects.items[project_index];
    const thread_selected = state.selected_project_index == project_index and project.selected_thread_index == thread_index;
    const row_width = @max(width - theme.scaledUi(42.0), theme.scaledUi(120.0));
    var time_buf: [24]u8 = undefined;
    const relative_time = formatRelativeTime(&time_buf, thread.last_activity_at);
    const timestamp_width = zgui.calcTextSize(relative_time, .{})[0] + theme.scaledUi(6.0);
    const title_width_chars: usize = @intFromFloat(@max((row_width - timestamp_width - theme.scaledUi(30.0)) / @max(zgui.getFontSize() * 0.42, 6.0), 10.0));

    zgui.pushIntId(@intCast(thread_index + 1000));
    defer zgui.popId();

    if (thread_selected) {
        zgui.pushStyleColor4f(.{ .idx = .header, .c = colors.DARK_BLUE });
        zgui.pushStyleColor4f(.{ .idx = .header_hovered, .c = theme.lighten(colors.DARK_BLUE, 0.06) });
        zgui.pushStyleColor4f(.{ .idx = .header_active, .c = theme.lighten(colors.DARK_BLUE, 0.12) });
    }

    // Provider logo drawn before the selectable row
    const chat_icon_space = theme.scaledUi(18.0);
    const row_height = theme.scaledUi(26.0);
    const icon_screen_pos = zgui.getCursorScreenPos();
    const icon_cy = icon_screen_pos[1] + row_height * 0.5;
    drawThreadProviderLogo(zgui.getWindowDrawList(), state, thread.provider, icon_screen_pos[0], icon_cy);

    // Indent the selectable past the icon
    zgui.indent(.{ .indent_w = chat_icon_space });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ theme.scaledUi(8.0), theme.scaledUi(6.0) } });
    var title_buf = std.mem.zeroes([64:0]u8);
    const row_label = truncatedThreadTitle(&title_buf, thread.title, title_width_chars);
    if (zgui.selectable(row_label, .{
        .selected = thread_selected,
        .w = row_width - timestamp_width - chat_icon_space,
        .h = row_height,
    })) {
        state.noteInteraction();
        state.selected_project_index = project_index;
        state.projects.items[project_index].selected_thread_index = thread_index;
        state.syncRenameBuffer();
        state.requestTranscriptScrollToBottom();
    }

    if (zgui.beginPopupContextItem()) {
        defer zgui.endPopup();

        state.noteInteraction();
        state.selected_project_index = project_index;
        state.projects.items[project_index].selected_thread_index = thread_index;
        state.syncRenameBuffer();

        const can_sync = thread.provider_thread_id != null;
        if (zgui.menuItem("Sync thread", .{ .enabled = can_sync })) {
            state.syncThreadFromProvider(project_index, thread_index);
            zgui.closeCurrentPopup();
        }
        if (zgui.menuItem("Archive thread", .{})) {
            state.archiveThreadAtIndex(project_index, thread_index);
            zgui.closeCurrentPopup();
        }
    }
    zgui.popStyleVar(.{ .count = 1 });
    zgui.sameLine(.{ .spacing = theme.scaledUi(8.0) });
    zgui.textColored(colors.TIME_LABEL, "{s}", .{relative_time});
    zgui.unindent(.{ .indent_w = chat_icon_space });

    if (thread_selected) {
        zgui.popStyleColor(.{ .count = 3 });
    }
    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(2.0) });
}

/// Returns the latest message preview for a project.
fn lastMessagePreview(project: anytype) []const u8 {
    const thread = project.currentThread();
    const message = thread.messages.items[thread.messages.items.len - 1];
    const body = message.body;
    if (body.len <= 44) return body;
    return body[0..44];
}

/// Builds a compact first-message preview for a thread row.
fn formatThreadPreview(buffer: *[72:0]u8, thread: anytype) [:0]const u8 {
    if (thread.messages.items.len == 0) return "Awaiting first prompt";
    const body = thread.messages.items[0].body;
    const max_len = @min(buffer.len - 1, @as(usize, 34));
    const source = std.mem.trim(u8, body, &std.ascii.whitespace);
    const title = std.mem.trim(u8, thread.title, &std.ascii.whitespace);
    var normalized_source_buf = std.mem.zeroes([96]u8);
    var normalized_title_buf = std.mem.zeroes([96]u8);
    const normalized_source = compactComparisonText(&normalized_source_buf, source);
    const normalized_title = compactComparisonText(&normalized_title_buf, title);
    if (std.mem.eql(u8, normalized_source, normalized_title)) return "";
    if (std.mem.startsWith(u8, normalized_source, normalized_title) or std.mem.startsWith(u8, normalized_title, normalized_source)) return "";
    const shared_prefix_len = @min(@min(normalized_source.len, normalized_title.len), @as(usize, 24));
    if (shared_prefix_len >= 16 and std.mem.eql(u8, normalized_source[0..shared_prefix_len], normalized_title[0..shared_prefix_len])) {
        return "";
    }
    if (source.len <= max_len) {
        @memcpy(buffer[0..source.len], source);
        buffer[source.len] = 0;
        return buffer[0..source.len :0];
    }
    if (max_len <= 3) return "...";
    const prefix_len = max_len - 3;
    @memcpy(buffer[0..prefix_len], source[0..prefix_len]);
    @memcpy(buffer[prefix_len..max_len], "...");
    buffer[max_len] = 0;
    return buffer[0..max_len :0];
}

/// Normalizes text so title and preview comparisons stay stable.
fn compactComparisonText(buffer: []u8, value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0 or buffer.len == 0) return "";

    var count: usize = 0;
    var saw_space = false;
    for (trimmed) |char| {
        const normalized = if (std.ascii.isWhitespace(char)) ' ' else std.ascii.toLower(char);
        if (normalized == ' ') {
            if (count == 0 or saw_space) continue;
            saw_space = true;
        } else {
            saw_space = false;
        }
        if (count == buffer.len) break;
        buffer[count] = normalized;
        count += 1;
    }

    while (count > 0 and buffer[count - 1] == ' ') {
        count -= 1;
    }
    return buffer[0..count];
}

/// Truncates a thread title for narrow sidebar rows.
fn truncatedThreadTitle(buffer: *[64:0]u8, value: []const u8, max_len: usize) [:0]const u8 {
    const bounded_max = @min(buffer.len - 1, max_len);
    if (value.len <= bounded_max) return std.fmt.bufPrintZ(buffer, "{s}", .{value}) catch value[0..bounded_max :0];
    if (bounded_max <= 3) return "...";
    const prefix_len = bounded_max - 3;
    @memcpy(buffer[0..prefix_len], value[0..prefix_len]);
    @memcpy(buffer[prefix_len..bounded_max], "...");
    buffer[bounded_max] = 0;
    return buffer[0..bounded_max :0];
}

/// Formats a relative timestamp for sidebar metadata.
fn formatRelativeTime(buffer: []u8, timestamp: i64) []const u8 {
    if (timestamp <= 0) return "now";
    const elapsed = @max(std.time.timestamp() - timestamp, 0);
    if (elapsed < 60) return "now";
    if (elapsed < 3600) {
        const minutes = @divFloor(elapsed, 60);
        return std.fmt.bufPrint(buffer, "{d}m ago", .{minutes}) catch "recent";
    }
    if (elapsed < 86_400) {
        const hours = @divFloor(elapsed, 3600);
        return std.fmt.bufPrint(buffer, "{d}h ago", .{hours}) catch "recent";
    }
    const days = @divFloor(elapsed, 86_400);
    return std.fmt.bufPrint(buffer, "{d}d ago", .{days}) catch "recent";
}

/// Draws the provider logo for a thread row, falling back to a chat bubble if no texture is loaded.
fn drawThreadProviderLogo(draw_list: zgui.DrawList, state: anytype, provider: Provider, x: f32, center_y: f32) void {
    // Keep the logo proportional to the font size so it doesn't dominate the row
    const logo_height = @min(zgui.getFontSize() * 0.85, theme.scaledUi(11.0));
    const cached = switch (provider) {
        .codex => state.codex_logo_texture,
        .opencode => state.opencode_logo_texture,
    };
    if (cached) |tex| {
        const uv = providerLogoUvBounds(provider);
        const visible_w = uv.max[0] - uv.min[0];
        const visible_h = uv.max[1] - uv.min[1];
        const aspect = visible_w / visible_h;
        const logo_width = logo_height * aspect;
        const img_min: [2]f32 = .{ x, center_y - logo_height * 0.5 };
        draw_list.addImage(runtime.textureRefFromGlId(tex.texture_id), .{
            .pmin = img_min,
            .pmax = .{ img_min[0] + logo_width, img_min[1] + logo_height },
            .uvmin = uv.min,
            .uvmax = uv.max,
        });
    } else {
        drawChatBubbleIcon(draw_list, x, center_y, theme.COLOR_TEXT_SUBTLE);
    }
}

/// Returns the UV crop bounds for a provider's logo texture.
fn providerLogoUvBounds(provider: Provider) struct { min: [2]f32, max: [2]f32 } {
    return switch (provider) {
        .codex => .{
            .min = .{ 118.0 / 721.0, 120.0 / 721.0 },
            .max = .{ 603.0 / 721.0, 601.0 / 721.0 },
        },
        .opencode => .{
            .min = .{ 0.0, 0.0 },
            .max = .{ 1.0, 1.0 },
        },
    };
}

/// Draws an edit icon: rounded square with a diagonal pen exiting the top-right corner.
fn drawComposeIcon(draw_list: zgui.DrawList, cx: f32, cy: f32, color: [4]f32) void {
    const col = zgui.colorConvertFloat4ToU32(color);
    const t = theme.scaledUi(1.5);
    const s = theme.scaledUi(5.5); // half-size of the square
    const r = theme.scaledUi(1.5); // corner rounding

    // Rounded square (open at top-right corner where the pen exits)
    const left = cx - s;
    const right = cx + s;
    const top = cy - s;
    const bottom = cy + s;
    const gap = theme.scaledUi(3.5); // how far from corner the square opens

    // Bottom edge
    draw_list.addLine(.{ .p1 = .{ left + r, bottom }, .p2 = .{ right - r, bottom }, .col = col, .thickness = t });
    // Left edge
    draw_list.addLine(.{ .p1 = .{ left, top + r }, .p2 = .{ left, bottom - r }, .col = col, .thickness = t });
    // Right edge (stops short of top for the pen gap)
    draw_list.addLine(.{ .p1 = .{ right, top + gap }, .p2 = .{ right, bottom - r }, .col = col, .thickness = t });
    // Top edge (stops short of right for the pen gap)
    draw_list.addLine(.{ .p1 = .{ left + r, top }, .p2 = .{ right - gap, top }, .col = col, .thickness = t });

    // Diagonal pen line from inside the square out through the top-right
    const pen_len = theme.scaledUi(5.5);
    const pen_start_x = right - gap + theme.scaledUi(0.5);
    const pen_start_y = top + gap - theme.scaledUi(0.5);
    const pen_end_x = pen_start_x + pen_len * 0.707;
    const pen_end_y = pen_start_y - pen_len * 0.707;
    draw_list.addLine(.{ .p1 = .{ pen_start_x, pen_start_y }, .p2 = .{ pen_end_x, pen_end_y }, .col = col, .thickness = t });

    // Small arrowhead/nib at pen tip end
    const arrow = theme.scaledUi(2.5);
    draw_list.addLine(.{ .p1 = .{ pen_end_x, pen_end_y }, .p2 = .{ pen_end_x - arrow, pen_end_y }, .col = col, .thickness = t });
    draw_list.addLine(.{ .p1 = .{ pen_end_x, pen_end_y }, .p2 = .{ pen_end_x, pen_end_y + arrow }, .col = col, .thickness = t });
}

/// Draws a small speech bubble icon for thread rows.
fn drawChatBubbleIcon(draw_list: zgui.DrawList, x: f32, center_y: f32, color: [4]f32) void {
    const col = zgui.colorConvertFloat4ToU32(color);
    const bw = theme.scaledUi(11.0); // bubble width
    const bh = theme.scaledUi(8.0); // bubble height
    const r = theme.scaledUi(2.0); // corner rounding
    const bubble_top = center_y - bh * 0.5 - theme.scaledUi(1.0);

    // Rounded rectangle body
    draw_list.addRectFilled(.{
        .pmin = .{ x, bubble_top },
        .pmax = .{ x + bw, bubble_top + bh },
        .col = col,
        .rounding = r,
    });

    // Small tail triangle at bottom-left
    const tail_x = x + theme.scaledUi(2.5);
    const tail_top = bubble_top + bh - theme.scaledUi(0.5);
    draw_list.addTriangleFilled(.{
        .p1 = .{ tail_x, tail_top },
        .p2 = .{ tail_x + theme.scaledUi(3.0), tail_top },
        .p3 = .{ tail_x, tail_top + theme.scaledUi(3.0) },
        .col = col,
    });
}

/// Collects committed threads and sorts them by recent activity.
fn collectCommittedThreadIndicesSorted(allocator: std.mem.Allocator, project: anytype) !std.ArrayList(usize) {
    var indices: std.ArrayList(usize) = .empty;
    errdefer indices.deinit(allocator);

    for (project.threads.items, 0..) |thread, index| {
        if (!thread.committed) continue;
        try indices.append(allocator, index);
    }

    var i: usize = 1;
    while (i < indices.items.len) : (i += 1) {
        const current = indices.items[i];
        var j = i;
        while (j > 0) : (j -= 1) {
            const left_index = indices.items[j - 1];
            const left = project.threads.items[left_index];
            const right = project.threads.items[current];
            const should_move = if (left.last_activity_at != right.last_activity_at)
                left.last_activity_at < right.last_activity_at
            else
                left_index < current;
            if (!should_move) break;
            indices.items[j] = indices.items[j - 1];
        }
        indices.items[j] = current;
    }

    return indices;
}
