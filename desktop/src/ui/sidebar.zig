//! Project rail rendering for the native shell.

const std = @import("std");
const zgui = @import("zgui");
const theme = @import("theme.zig");
const colors = @import("colors.zig");

/// Renders the full project rail and thread list.
pub fn render(comptime Impl: type, state: *Impl.AppState, width: f32, height: f32) void {
    _ = height;
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 0.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(20.0), theme.scaledUi(20.0) } });
    defer zgui.popStyleVar(.{ .count = 2 });
    const overscan = theme.scaledUi(12.0);
    zgui.setCursorPos(.{ 0.0, 0.0 });
    _ = zgui.beginChild("ProjectsRail", .{
        .w = width + overscan,
        .h = zgui.getContentRegionAvail()[1] + overscan,
        .child_flags = .{ .border = false },
        .window_flags = .{ .no_scrollbar = true },
    });
    defer zgui.endChild();

    // Explicit top-left inset so brand/content doesn't feel cramped
    const pad_left = theme.scaledUi(24.0);
    const pad_top = theme.scaledUi(28.0);
    zgui.setCursorPos(.{ pad_left, pad_top });

    {
        const draw_list = zgui.getWindowDrawList();
        const pos = zgui.getWindowPos();
        const size = zgui.getWindowSize();
        draw_list.addLine(.{
            .p1 = .{ pos[0] + size[0] - 1.0, pos[1] },
            .p2 = .{ pos[0] + size[0] - 1.0, pos[1] + size[1] },
            .col = zgui.colorConvertFloat4ToU32(colors.rgba(48, 50, 56, 255)),
            .thickness = 1.0,
        });
    }

    const project_header_button_width = theme.clampf(width * 0.11, theme.scaledUi(28.0), theme.scaledUi(38.0));
    const rail_inner_width = @max(width - theme.scaledUi(36.0), theme.scaledUi(140.0));
    renderBrand(Impl, state);
    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(2.0) });
    zgui.textColored(theme.COLOR_TEXT_MUTED, "PROJECTS", .{});
    zgui.sameLine(.{ .spacing = 0.0 });
    zgui.setCursorPosX(@max(zgui.getCursorPosX(), width - project_header_button_width - theme.scaledUi(10.0)));
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
        zgui.pushStyleColor4f(.{ .idx = .border, .c = theme.lighten(theme.COLOR_PANEL_MUTED, 0.08) });
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

    for (state.projects.items, 0..) |project, index| {
        zgui.pushIntId(@intCast(index));
        defer zgui.popId();

        const is_selected = state.selected_project_index == index;
        const is_collapsed = state.projects.items[index].collapsed;
        const project_action_width = theme.clampf(width * 0.11, theme.scaledUi(28.0), theme.scaledUi(38.0));
        const row_width = @max(width - project_action_width - theme.scaledUi(22.0), theme.scaledUi(100.0));
        const row_height = theme.scaledUi(28.0);

        {
            const row_pos = zgui.getCursorScreenPos();
            _ = zgui.invisibleButton("##project-row", .{ .w = row_width, .h = row_height });
            const left_clicked = zgui.isItemClicked(.left);
            const hovered = zgui.isItemHovered(.{});
            const dl = zgui.getWindowDrawList();

            if (is_selected or hovered) {
                const bg_col = if (is_selected and hovered)
                    colors.rgba(44, 46, 54, 255)
                else if (is_selected)
                    colors.rgba(38, 40, 48, 255)
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
            var x = row_pos[0] + theme.scaledUi(8.0);
            const chevron_col = zgui.colorConvertFloat4ToU32(if (hovered) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE);
            const cs: f32 = theme.scaledUi(3.5);
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
            x += theme.scaledUi(12.0);

            const folder_col = zgui.colorConvertFloat4ToU32(theme.COLOR_TEXT_SUBTLE);
            const fw = theme.scaledUi(13.0);
            const fh = theme.scaledUi(9.0);
            dl.addRectFilled(.{
                .pmin = .{ x, cy - fh * 0.5 - theme.scaledUi(2.0) },
                .pmax = .{ x + fw * 0.4, cy - fh * 0.5 + theme.scaledUi(1.0) },
                .col = folder_col,
                .rounding = theme.scaledUi(1.0),
            });
            dl.addRectFilled(.{
                .pmin = .{ x, cy - fh * 0.5 },
                .pmax = .{ x + fw, cy + fh * 0.5 },
                .col = folder_col,
                .rounding = theme.scaledUi(1.5),
            });
            x += fw + theme.scaledUi(6.0);

            const text_col = zgui.colorConvertFloat4ToU32(if (is_selected) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED);
            dl.addText(.{ x, cy - zgui.getFontSize() * 0.5 }, text_col, "{s}", .{project.label});

            if (left_clicked) {
                state.selected_project_index = index;
                state.projects.items[index].collapsed = !state.projects.items[index].collapsed;
                state.syncRenameBuffer();
                state.requestTranscriptScrollToBottom();
                state.markDirty();
            }

            if (zgui.beginPopupContextItem()) {
                defer zgui.endPopup();

                state.selected_project_index = index;
                state.syncRenameBuffer();

                if (zgui.menuItem("Rename project", .{})) {
                    state.beginProjectRename(index);
                    zgui.openPopup(Impl.PROJECT_RENAME_MODAL_ID, .{});
                    zgui.closeCurrentPopup();
                }
                if (zgui.menuItem("Remove project", .{})) {
                    state.removeProjectAtIndex(index);
                    zgui.closeCurrentPopup();
                }
            }
        }

        zgui.sameLine(.{ .spacing = theme.scaledUi(6.0) });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
        if (zgui.button("+", .{ .w = project_action_width, .h = row_height })) {
            state.createThreadForProject(index);
        }
        if (zgui.isItemHovered(.{ .delay_normal = true })) {
            _ = zgui.beginTooltip();
            zgui.textUnformatted("Start a new chat");
            zgui.endTooltip();
        }
        zgui.popStyleColor(.{ .count = 3 });

        const active_thread = state.projects.items[index].currentThread();
        if (!is_collapsed) {
            zgui.textDisabled("{d} saved chats", .{project.committedThreadCount()});
        }
        if (is_selected and !is_collapsed) {
            zgui.indent(.{ .indent_w = theme.scaledUi(12.0) });
            var sorted_indices = collectCommittedThreadIndicesSorted(state.allocator, &project) catch blk: {
                break :blk std.ArrayList(usize).empty;
            };
            defer sorted_indices.deinit(state.allocator);

            const show_all_threads = project.thread_list_expanded or sorted_indices.items.len <= Impl.SIDEBAR_VISIBLE_THREAD_LIMIT;
            const visible_count = if (show_all_threads) sorted_indices.items.len else @min(sorted_indices.items.len, Impl.SIDEBAR_VISIBLE_THREAD_LIMIT);

            for (sorted_indices.items[0..visible_count]) |thread_index| {
                const thread = &project.threads.items[thread_index];
                renderThreadRow(state, index, width, thread, thread_index);
            }

            if (sorted_indices.items.len > Impl.SIDEBAR_VISIBLE_THREAD_LIMIT) {
                zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(4.0) });
                if (zgui.button(if (project.thread_list_expanded) "Show less" else "Show more", .{
                    .w = @max(width - theme.scaledUi(36.0), theme.scaledUi(110.0)),
                    .h = theme.scaledUi(28.0),
                })) {
                    state.projects.items[index].thread_list_expanded = !state.projects.items[index].thread_list_expanded;
                    state.markDirty();
                }
                zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(4.0) });
            }
            if (!active_thread.committed) {
                zgui.textColored(theme.COLOR_TEXT_SUBTLE, "New chat will appear here after the first prompt.", .{});
            }
            zgui.unindent(.{ .indent_w = theme.scaledUi(12.0) });
        } else if (!is_collapsed and active_thread.messages.items.len > 0) {
            var time_buf: [24]u8 = undefined;
            const relative_time = formatRelativeTime(&time_buf, active_thread.last_activity_at);
            zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{lastMessagePreview(&project)});
            zgui.textDisabled("{s}", .{relative_time});
        } else if (!is_collapsed and active_thread.committed) {
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{s}", .{active_thread.title});
        } else if (!is_collapsed) {
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, "No saved threads yet", .{});
        }
        if (project.unread_count > 0) {
            zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
            zgui.textColored(theme.COLOR_YELLOW, "{d} pending", .{project.unread_count});
        }
        zgui.spacing();
    }
}

/// Draws the sidebar brand row with logo and title.
fn renderBrand(comptime Impl: type, state: anytype) void {
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

    var logo_width: f32 = 0.0;
    var logo_height: f32 = 0.0;
    if (state.logo_texture) |cached| {
        const target_height = @max(text_size[1] * 1.15, fallback_logo_size);
        const aspect_ratio = @as(f32, @floatFromInt(cached.width)) / @as(f32, @floatFromInt(cached.height));
        logo_height = target_height;
        logo_width = logo_height * aspect_ratio;

        zgui.setCursorPos(start);
        zgui.image(Impl.textureRefFromGlId(cached.texture_id), .{
            .w = logo_width,
            .h = logo_height,
        });
        zgui.sameLine(.{ .spacing = spacing });
    }

    const row_height = @max(logo_height, text_size[1]);
    const text_x = start[0] + if (logo_width > 0.0) logo_width + spacing else 0.0;
    const text_y = start[1] + (row_height - text_size[1]) * 0.5;
    zgui.setCursorPos(.{ text_x, text_y });
    if (theme.heading_font) |font| {
        zgui.pushFont(font, theme.heading_font_size);
        zgui.textColored(theme.COLOR_WHITE, title_text, .{});
        zgui.popFont();
    } else {
        zgui.textColored(theme.COLOR_WHITE, title_text, .{});
    }
    zgui.setCursorPos(.{ start[0], start[1] + row_height });
}

/// Draws one saved thread row under the active project.
fn renderThreadRow(state: anytype, project_index: usize, width: f32, thread: anytype, thread_index: usize) void {
    const project = &state.projects.items[project_index];
    const thread_selected = project.selected_thread_index == thread_index;
    const row_width = @max(width - theme.scaledUi(42.0), theme.scaledUi(120.0));
    var time_buf: [24]u8 = undefined;
    const relative_time = formatRelativeTime(&time_buf, thread.last_activity_at);
    const timestamp_width = zgui.calcTextSize(relative_time, .{})[0] + theme.scaledUi(6.0);
    const title_width_chars: usize = @intFromFloat(@max((row_width - timestamp_width - theme.scaledUi(12.0)) / @max(zgui.getFontSize() * 0.42, 6.0), 10.0));

    zgui.pushIntId(@intCast(thread_index + 1000));
    defer zgui.popId();

    if (thread_selected) {
        zgui.pushStyleColor4f(.{ .idx = .header, .c = colors.rgba(36, 38, 44, 255) });
        zgui.pushStyleColor4f(.{ .idx = .header_hovered, .c = colors.rgba(42, 44, 50, 255) });
        zgui.pushStyleColor4f(.{ .idx = .header_active, .c = colors.rgba(48, 50, 56, 255) });
    }

    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ theme.scaledUi(8.0), theme.scaledUi(6.0) } });
    var title_buf = std.mem.zeroes([64:0]u8);
    const row_label = truncatedThreadTitle(&title_buf, thread.title, title_width_chars);
    if (zgui.selectable(row_label, .{
        .selected = thread_selected,
        .w = row_width - timestamp_width,
        .h = theme.scaledUi(26.0),
    })) {
        state.selected_project_index = project_index;
        state.projects.items[project_index].selected_thread_index = thread_index;
        state.syncRenameBuffer();
        state.requestTranscriptScrollToBottom();
        state.markDirty();
    }
    zgui.popStyleVar(.{ .count = 1 });

    zgui.sameLine(.{ .spacing = theme.scaledUi(8.0) });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{s}", .{relative_time});

    var preview_buf = std.mem.zeroes([72:0]u8);
    const preview = formatThreadPreview(&preview_buf, thread);
    if (preview.len > 0) {
        zgui.textColored(if (thread_selected) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE, "{s}", .{preview});
    }

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
