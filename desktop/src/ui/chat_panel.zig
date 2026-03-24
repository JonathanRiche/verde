//! Chat workspace rendering for the native shell.

const std = @import("std");

const zgui = @import("zgui");

const colors = @import("colors.zig");
const theme = @import("theme.zig");
const app_state = @import("../state.zig");

fn inner_workspace(comptime Impl: type, state: *Impl.AppState) void {
    //INNER UI FOR CHAT WORKSPACE
    const available_width = zgui.getContentRegionAvail();
    // app_state.log.debug("available width: {d}", .{available_width[0]});
    const inner_pad_x =
        if (available_width[0] < theme.scaledUi(1900.0))
            theme.scaledUi(160.0)
        else
            theme.clampf(available_width[0] * 0.32, theme.scaledUi(24.0), theme.scaledUi(480.0));

    // const inner_pad_x = theme.clampf(available_width[0] * 0.14, theme.scaledUi(24.0), theme.scaledUi(200.0));
    const inner_pad_y = theme.scaledUi(18.0);

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ inner_pad_x, inner_pad_y } });

    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(0, 0, 0, 0) });

    defer zgui.popStyleVar(.{ .count = 1 });
    defer zgui.popStyleColor(.{ .count = 1 });
    _ = zgui.beginChild("ChatWorkspaceInner", .{
        .w = 0.0,
        .h = 0.0,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
    });

    defer zgui.endChild();

    if (state.projects.items.len == 0) {
        zgui.textColored(theme.COLOR_WHITE, "No projects yet", .{});
        zgui.textColored(theme.COLOR_TEXT_MUTED, "Use the + button in the left rail, browse to a folder, then add its path here.", .{});
        return;
    }

    // renderHeader(state);
    // zgui.separator();

    const content = zgui.getContentRegionAvail();
    const composer_height = theme.clampf(content[1] * 0.27, theme.scaledUi(168.0), @min(content[1] * 0.42, theme.scaledUi(320.0)));
    const transcript_height = @max(content[1] - composer_height - theme.scaledUi(8.0), theme.scaledUi(120.0));
    renderTranscript(Impl, state, content[0], transcript_height);
    renderComposer(Impl, state, content[0], @max(content[1] - transcript_height - theme.scaledUi(8.0), theme.scaledUi(120.0)));
}

/// Renders the chat workspace shell beside the sidebar.
pub fn renderWorkspace(comptime Impl: type, state: *Impl.AppState, width: f32, height: f32) void {
    _ = width;
    _ = height;
    zgui.setCursorPos(.{ zgui.getCursorPosX(), 0.0 });
    //OUTER UI FOR CHAT WORKSPACE
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 0.0 });
    // zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(30.0), theme.scaledUi(18.0) } });

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.CHAT_BLACK });
    defer zgui.popStyleColor(.{ .count = 1 });
    defer zgui.popStyleVar(.{ .count = 2 });
    _ = zgui.beginChild("ChatWorkspace", .{
        .w = zgui.getContentRegionAvail()[0],
        .h = zgui.getContentRegionAvail()[1],
        .child_flags = .{ .border = false },
    });
    defer zgui.endChild();

    renderHeader(state);
    zgui.separator();
    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(5.0) });
    //END OUTER UI FOR CHAT WORKSPACE
    inner_workspace(Impl, state);
}

/// Renders the current thread title block.
fn renderHeader(state: anytype) void {
    const thread = state.currentThread();
    const header_height = theme.scaledUi(60.0);
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(0, 0, 0, 0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(28.0), theme.scaledUi(18.0) } });

    defer zgui.popStyleVar(.{ .count = 1 });
    defer zgui.popStyleColor(.{ .count = 1 });

    _ = zgui.beginChild("ChatHeader", .{
        .w = 0.0,
        .h = header_height,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_saved_settings = true,
        },
    });
    defer zgui.endChild();
    if (theme.heading_font) |font| {
        zgui.pushFont(font, 18);
        defer zgui.popFont();
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{if (thread.committed) thread.title else "New chat"});
    } else {
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{if (thread.committed) thread.title else "New chat"});
    }
}

/// Renders transcript history plus any in-flight stream state.
fn renderTranscript(comptime Impl: type, state: *Impl.AppState, width: f32, height: f32) void {
    _ = zgui.beginChild("Transcript", .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = false },
    });
    defer zgui.endChild();

    const should_follow_stream = transcriptShouldAutoFollow(state);
    const has_pending_stream = Impl.isSendPending(state);
    if (state.currentThread().messages.items.len == 0 and !has_pending_stream) {
        zgui.textColored(theme.COLOR_WHITE, "No messages yet", .{});
        zgui.textColored(theme.COLOR_TEXT_MUTED, "Choose a provider, type a prompt below, and start the first chat for this directory.", .{});
        return;
    }

    for (state.currentThread().messages.items, 0..) |message, index| {
        renderTranscriptMessage(Impl, state, @intCast(index + 1), message.role, message.author, message.body, message.image);
        zgui.dummy(.{ .w = 0.0, .h = 10.0 });
    }

    if (has_pending_stream) {
        renderPendingApproval(state);
        renderPendingDiffCard(Impl, state);
        renderPendingTimelineEvents(Impl, state);
        renderPendingTranscriptBubble(Impl, state);
        zgui.dummy(.{ .w = 0.0, .h = 6.0 });
    }

    if (state.scroll_transcript_to_bottom) {
        zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
        state.scroll_transcript_to_bottom = false;
    } else if (should_follow_stream) {
        zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
    }
}

/// Renders the pending approval prompt from the provider.
fn renderPendingApproval(state: anytype) void {
    var snapshot = state.pendingApprovalSnapshot() catch null;
    defer freePendingApproval(state.allocator, &snapshot);

    if (snapshot) |approval| {
        renderTranscriptBubble(state, "pending-approval-body", .system, approval.title, approval.body, null, false);
        const button_width = theme.clampf(zgui.getContentRegionAvail()[0] * 0.28, theme.scaledUi(108.0), theme.scaledUi(180.0));
        zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(6.0) });
        if (zgui.button("Approve", .{ .w = button_width, .h = theme.scaledUi(34.0) })) {
            state.resolvePendingApproval(.approve);
        }
        zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
        zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.rgba(52, 54, 60, 255) });
        zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.rgba(64, 66, 74, 255) });
        zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.rgba(44, 46, 52, 255) });
        if (zgui.button("Deny", .{ .w = button_width, .h = theme.scaledUi(34.0) })) {
            state.resolvePendingApproval(.deny);
        }
        zgui.popStyleColor(.{ .count = 3 });
        zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(8.0) });
    }
}

/// Renders streamed timeline events while a send is pending.
fn renderPendingTimelineEvents(comptime Impl: type, state: *Impl.AppState) void {
    state.send_state.mutex.lock();
    defer state.send_state.mutex.unlock();

    if (state.send_state.status != .pending) return;
    if (state.send_state.project_index != state.selected_project_index) return;
    if (state.send_state.thread_index != state.currentProject().selected_thread_index) return;

    for (state.send_state.pending_events.items, 0..) |event, index| {
        renderTranscriptMessage(Impl, state, @intCast(50_000 + index), event.role, event.author, event.body, null);
        zgui.dummy(.{ .w = 0.0, .h = 6.0 });
    }
}

/// Renders the live diff summary card for streamed file changes.
fn renderPendingDiffCard(comptime Impl: type, state: *Impl.AppState) void {
    state.send_state.mutex.lock();
    defer state.send_state.mutex.unlock();

    if (state.send_state.status != .pending) return;
    if (state.send_state.project_index != state.selected_project_index) return;
    if (state.send_state.thread_index != state.currentProject().selected_thread_index) return;
    if (state.send_state.pending_diff_files.items.len == 0) return;

    renderPendingDiffCardLocked(&state.send_state.pending_diff_files);
    zgui.dummy(.{ .w = 0.0, .h = 6.0 });
}

/// Draws the pending diff card contents while the send lock is held.
fn renderPendingDiffCardLocked(files: anytype) void {
    const totals = summarizePendingDiffFiles(files.items);
    const card_height = pendingDiffCardHeight(files.items);

    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 12.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 14.0, 10.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(32, 33, 38, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    _ = zgui.beginChild("pending-diff-card", .{
        .w = 0.0,
        .h = card_height,
        .child_flags = .{ .border = true },
        .window_flags = .{ .no_saved_settings = true },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    renderChangedFilesHeader(files.items.len, totals.additions, totals.deletions);
    zgui.sameLine(.{ .spacing = 12.0 });
    if (renderChangedFilesAction("Expand all")) {
        for (files.items) |*file| file.expanded = true;
    }
    zgui.sameLine(.{ .spacing = 8.0 });
    if (renderChangedFilesAction("Collapse all")) {
        for (files.items) |*file| file.expanded = false;
    }
    zgui.dummy(.{ .w = 0.0, .h = 4.0 });

    for (files.items, 0..) |*file, index| {
        renderPendingDiffFile(file, index);
    }
}

/// Renders the streamed assistant bubble placeholder or partial text.
fn renderPendingTranscriptBubble(comptime Impl: type, state: *Impl.AppState) void {
    state.send_state.mutex.lock();
    defer state.send_state.mutex.unlock();

    if (state.send_state.status != .pending) return;
    if (state.send_state.project_index != state.selected_project_index) return;
    if (state.send_state.thread_index != state.currentProject().selected_thread_index) return;

    const stream_text = state.send_state.partial_text.items;
    renderTranscriptBubble(
        state,
        "pending-assistant",
        .assistant,
        Impl.providerLabel(state.currentThread().provider),
        if (stream_text.len > 0) stream_text else "Waiting for streamed output...",
        null,
        stream_text.len == 0,
    );
}

/// Dispatches a transcript item to the right visual treatment.
fn renderTranscriptMessage(comptime Impl: type, state: *Impl.AppState, id: u32, role: Impl.ChatRole, author: []const u8, body: []const u8, image: ?Impl.ChatImageAttachment) void {
    if (role == .system and std.mem.eql(u8, author, "Changed files")) {
        renderChangedFilesCardId(Impl, id, body);
        return;
    }
    if (role == .system and (std.mem.eql(u8, author, "Ran command") or std.mem.eql(u8, author, "Command failed"))) {
        renderCommandEventRowId(id, author, body);
        return;
    }

    const bubble_height = transcriptBubbleHeight(Impl, author, body, image);
    const bubble_theme = transcriptBubbleTheme(role);
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = theme.TRANSCRIPT_BUBBLE_ROUNDING });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.TRANSCRIPT_BUBBLE_PADDING_X, theme.TRANSCRIPT_BUBBLE_PADDING_Y } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = bubble_theme.background });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = bubble_theme.border });
    _ = zgui.beginChildId(id, .{
        .w = 0.0,
        .h = bubble_height,
        .child_flags = .{ .border = true },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_saved_settings = true,
        },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    if (shouldShowBubbleAuthor(author)) {
        zgui.textColored(bubble_theme.author, "{s}", .{author});
        zgui.dummy(.{ .w = 0.0, .h = 2.0 });
    }
    if (image) |attachment| {
        renderImageAttachmentCard(Impl, state, attachment, false);
        if (body.len > 0) {
            zgui.dummy(.{ .w = 0.0, .h = 8.0 });
        }
    }
    zgui.pushTextWrapPos(0.0);
    zgui.textWrapped("{s}", .{body});
    zgui.popTextWrapPos();
}

/// Draws a generic transcript bubble with optional muted body text.
fn renderTranscriptBubble(state: anytype, id: [:0]const u8, role: anytype, author: []const u8, body: []const u8, image: anytype, muted_body: bool) void {
    const bubble_height = transcriptBubbleHeightGeneric(author, body, image);
    const bubble_theme = transcriptBubbleTheme(role);
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = theme.TRANSCRIPT_BUBBLE_ROUNDING });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.TRANSCRIPT_BUBBLE_PADDING_X, theme.TRANSCRIPT_BUBBLE_PADDING_Y } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = bubble_theme.background });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = bubble_theme.border });
    _ = zgui.beginChild(id, .{
        .w = 0.0,
        .h = bubble_height,
        .child_flags = .{ .border = true },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_saved_settings = true,
        },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    if (shouldShowBubbleAuthor(author)) {
        zgui.textColored(bubble_theme.author, "{s}", .{author});
        zgui.dummy(.{ .w = 0.0, .h = 2.0 });
    }
    if (image) |attachment| {
        renderImageAttachmentCard(@TypeOf(state.*), state, attachment, false);
        if (body.len > 0) {
            zgui.dummy(.{ .w = 0.0, .h = 8.0 });
        }
    }
    zgui.pushTextWrapPos(0.0);
    if (muted_body) {
        zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{body});
    } else {
        zgui.textWrapped("{s}", .{body});
    }
    zgui.popTextWrapPos();
}

/// Draws a compact system row for command execution events.
fn renderCommandEventRowId(id: u32, author: []const u8, body: []const u8) void {
    const row_height: f32 = 38.0;
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 10.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 14.0, 9.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(28, 29, 34, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    _ = zgui.beginChildId(id, .{
        .w = 0.0,
        .h = row_height,
        .child_flags = .{ .border = true },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_saved_settings = true,
        },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    zgui.textColored(theme.COLOR_TEXT_MUTED, ">_", .{});
    zgui.sameLine(.{ .spacing = 12.0 });
    zgui.textColored(if (std.mem.eql(u8, author, "Command failed")) theme.COLOR_DIFF_REMOVE else theme.COLOR_TEXT_MUTED, "{s}", .{author});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "-", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.pushTextWrapPos(0.0);
    zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{body});
    zgui.popTextWrapPos();
}

/// Renders a persisted changed-files message as a rich card.
fn renderChangedFilesCardId(comptime Impl: type, id: u32, body: []const u8) void {
    var entries = parseChangedFileEntries(Impl, body);
    const totals = summarizeChangedFiles(entries);
    const has_patch_details = changedFilesEntriesHavePatch(entries.items);
    const card_height = if (has_patch_details) detailedChangedFilesCardHeight(entries.items) else changedFilesCardHeight(entries.items.len);
    var open_all = false;
    var close_all = false;

    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 12.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 14.0, 10.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(32, 33, 38, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    _ = zgui.beginChildId(id, .{
        .w = 0.0,
        .h = card_height,
        .child_flags = .{ .border = true },
        .window_flags = .{ .no_saved_settings = true },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
        entries.deinit(std.heap.page_allocator);
    }

    renderChangedFilesHeader(entries.items.len, totals.additions, totals.deletions);
    zgui.sameLine(.{ .spacing = 12.0 });
    if (has_patch_details) {
        if (renderChangedFilesAction("Collapse all")) {
            close_all = true;
        }
        zgui.sameLine(.{ .spacing = 8.0 });
        if (renderChangedFilesAction("View diff")) {
            open_all = true;
        }
    } else {
        _ = renderChangedFilesAction("Collapse all");
        zgui.sameLine(.{ .spacing = 8.0 });
        _ = renderChangedFilesAction("View diff");
    }
    zgui.dummy(.{ .w = 0.0, .h = 4.0 });

    if (has_patch_details) {
        for (entries.items, 0..) |entry, index| {
            renderChangedFilesDetailedEntry(entry, id, index, open_all, close_all);
        }
        return;
    }

    var last_parent: ?[]const u8 = null;
    for (entries.items) |entry| {
        const parent = std.fs.path.dirname(entry.path) orelse ".";
        if (last_parent == null or !std.mem.eql(u8, last_parent.?, parent)) {
            renderChangedFilesFolder(parent);
            last_parent = parent;
        }
        renderChangedFilesEntry(entry);
    }
}

/// Draws the header for changed-file summaries.
fn renderChangedFilesHeader(file_count: usize, additions: i64, deletions: i64) void {
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "CHANGED FILES ({d})", .{file_count});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "•", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_DIFF_ADD, "+{d}", .{additions});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "/", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_DIFF_REMOVE, "-{d}", .{deletions});
}

/// Draws a small action button used inside diff cards.
fn renderChangedFilesAction(label: [:0]const u8) bool {
    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = 8.0 });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 10.0, 4.0 } });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.rgba(52, 54, 60, 255) });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.rgba(62, 64, 72, 255) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.rgba(68, 70, 78, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 3 });
        zgui.popStyleVar(.{ .count = 2 });
    }
    return zgui.button(label, .{ .h = 26.0 });
}

/// Draws a folder label row inside a changed-files card.
fn renderChangedFilesFolder(path: []const u8) void {
    zgui.textColored(theme.COLOR_TEXT_MUTED, "v  {s}", .{path});
    zgui.dummy(.{ .w = 0.0, .h = 2.0 });
}

/// Draws a single changed file row without patch details.
fn renderChangedFilesEntry(entry: anytype) void {
    const file_name = std.fs.path.basename(entry.path);
    zgui.textColored(theme.COLOR_TEXT_MUTED, "    {s}", .{file_name});
    zgui.sameLine(.{ .spacing = 16.0 });
    zgui.textColored(theme.COLOR_DIFF_ADD, "+{d}", .{entry.additions});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "/", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_DIFF_REMOVE, "-{d}", .{entry.deletions});
    zgui.dummy(.{ .w = 0.0, .h = 2.0 });
}

/// Draws one expandable changed-file row with its patch.
fn renderChangedFilesDetailedEntry(entry: anytype, message_id: u32, index: usize, open_all: bool, close_all: bool) void {
    var header_storage: [512]u8 = undefined;
    const header_label = std.fmt.bufPrintZ(&header_storage, "{s}  +{d} / -{d}##changed-files-{d}-{d}", .{
        entry.path,
        entry.additions,
        entry.deletions,
        message_id,
        index,
    }) catch return;

    if (open_all) {
        zgui.setNextItemOpen(.{ .is_open = true, .cond = .always });
    } else if (close_all) {
        zgui.setNextItemOpen(.{ .is_open = false, .cond = .always });
    }

    if (zgui.collapsingHeader(header_label, .{})) {
        if (entry.patch) |patch| {
            renderPendingDiffPatch(patch, @as(usize, message_id) * 1000 + index);
        } else {
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, "No patch body available.", .{});
        }
        zgui.dummy(.{ .w = 0.0, .h = 6.0 });
    }
}

/// Draws one pending diff file row in the live stream card.
fn renderPendingDiffFile(file: anytype, index: usize) void {
    const toggle_label = if (file.expanded) "v" else ">";
    const file_name = std.fs.path.basename(file.path);
    var toggle_storage: [48]u8 = undefined;
    const toggle_button_label = std.fmt.bufPrintZ(&toggle_storage, "{s}##pending-diff-toggle-{d}", .{ toggle_label, index }) catch return;

    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = 8.0 });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 8.0, 6.0 } });
    defer zgui.popStyleVar(.{ .count = 2 });

    if (zgui.button(toggle_button_label, .{ .w = 28.0, .h = 28.0 })) {
        file.expanded = !file.expanded;
    }
    zgui.sameLine(.{ .spacing = 10.0 });
    zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}", .{file_name});
    zgui.sameLine(.{ .spacing = 10.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "{s}", .{file.path});
    zgui.sameLine(.{ .spacing = 12.0 });
    zgui.textColored(theme.COLOR_DIFF_ADD, "+{d}", .{file.additions});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "/", .{});
    zgui.sameLine(.{ .spacing = 8.0 });
    zgui.textColored(theme.COLOR_DIFF_REMOVE, "-{d}", .{file.deletions});

    if (file.expanded) {
        if (file.patch) |patch| {
            renderPendingDiffPatch(patch, index);
        } else {
            zgui.dummy(.{ .w = 0.0, .h = 6.0 });
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, "No patch body available yet.", .{});
        }
    }

    zgui.dummy(.{ .w = 0.0, .h = 8.0 });
}

/// Draws a syntax-colored patch block.
fn renderPendingDiffPatch(patch: []const u8, index: usize) void {
    const patch_height = pendingDiffPatchHeight(patch);

    zgui.dummy(.{ .w = 0.0, .h = 6.0 });
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 10.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 10.0, 10.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(24, 24, 24, 255) });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    _ = zgui.beginChildId(@intCast(80_000 + index), .{
        .w = 0.0,
        .h = patch_height,
        .child_flags = .{ .border = true },
        .window_flags = .{ .no_saved_settings = true },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    var lines = std.mem.tokenizeScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            zgui.textColored(theme.COLOR_TEXT_SUBTLE, " ", .{});
            continue;
        }

        const color = switch (line[0]) {
            '+' => if (std.mem.startsWith(u8, line, "+++")) theme.COLOR_TEXT_SUBTLE else theme.COLOR_DIFF_ADD,
            '-' => if (std.mem.startsWith(u8, line, "---")) theme.COLOR_TEXT_SUBTLE else theme.COLOR_DIFF_REMOVE,
            '@' => theme.COLOR_YELLOW,
            else => theme.COLOR_TEXT_MUTED,
        };
        zgui.textColored(color, "{s}", .{line});
    }
}

/// Renders the composer card, input, pickers, and send button.
fn renderComposer(comptime Impl: type, state: *Impl.AppState, width: f32, height: f32) void {
    const composer_bg = colors.GREEN_600;
    const composer_rounding = theme.scaledUi(18.0);
    state.composer_focused = false;
    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = composer_rounding });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(18.0), theme.scaledUi(12.0) } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = composer_bg });
    // zgui.pushStyleColor4f(.{ .idx = .border, .c = .{ 0, 0, 0, 0 } });

    zgui.pushStyleColor4f(.{ .idx = .border, .c = colors.DARK_BLUE });
    const composer_screen_pos = zgui.getCursorScreenPos();
    _ = zgui.beginChild("Composer", .{
        .w = width,
        .h = height,
        .child_flags = .{ .border = true },
    });
    defer {
        zgui.endChild();
        zgui.popStyleColor(.{ .count = 2 });
        zgui.popStyleVar(.{ .count = 2 });

        const border_color = colors.DARK_BLUE;
        const draw_list = zgui.getWindowDrawList();
        draw_list.addRect(.{
            .pmin = composer_screen_pos,
            .pmax = .{ composer_screen_pos[0] + width, composer_screen_pos[1] + height },
            .col = zgui.colorConvertFloat4ToU32(border_color),
            .rounding = composer_rounding,
            .thickness = 1.5,
        });
    }

    if (state.currentThread().draft_image) |image| {
        renderComposerAttachmentPreview(Impl, state, image);
        zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(10.0) });
    }

    const attachment_height: f32 = if (state.currentThread().draft_image != null) theme.scaledUi(82.0) else 0.0;
    const content_width = @max(zgui.getContentRegionAvail()[0], theme.scaledUi(120.0));
    const input_h: f32 = @max(height - theme.scaledUi(86.0) - attachment_height, theme.scaledUi(48.0));
    zgui.pushStyleVar1f(.{ .idx = .frame_rounding, .v = 0.0 });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ theme.scaledUi(4.0), theme.scaledUi(6.0) } });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = composer_bg });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_hovered, .c = composer_bg });
    zgui.pushStyleColor4f(.{ .idx = .frame_bg_active, .c = composer_bg });
    zgui.pushStyleColor4f(.{ .idx = .border, .c = .{ 0, 0, 0, 0 } });

    const cursor_before = zgui.getCursorScreenPos();
    const buf = state.draftBuffer();
    const submitted = zgui.inputTextMultiline("##chat-draft", .{
        .buf = buf,
        .w = content_width,
        .h = input_h,
        .flags = .{
            .ctrl_enter_for_new_line = true,
            .enter_returns_true = true,
        },
    });
    state.composer_focused = zgui.isItemFocused();
    zgui.popStyleColor(.{ .count = 4 });
    zgui.popStyleVar(.{ .count = 2 });

    if (buf[0] == 0) {
        const hint_pos = .{ cursor_before[0] + theme.scaledUi(4.0), cursor_before[1] + theme.scaledUi(6.0) };
        const fg_draw_list = zgui.getForegroundDrawList();
        fg_draw_list.addText(hint_pos, zgui.colorConvertFloat4ToU32(colors.rgba(100, 102, 115, 255)), "Ask anything, or use / to show available commands", .{});
    }

    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(2.0) });
    Impl.renderComposerPickers(state);

    const send_btn_size = theme.scaledUi(32.0);
    zgui.sameLine(.{ .spacing = 0.0 });
    const avail = zgui.getContentRegionAvail();
    if (avail[0] > send_btn_size + theme.scaledUi(4.0)) {
        zgui.sameLine(.{ .spacing = avail[0] - send_btn_size - theme.scaledUi(4.0) });
    }

    {
        const pending = Impl.isSendPending(state);
        const btn_pos = zgui.getCursorScreenPos();
        const clicked = zgui.invisibleButton("##send-btn", .{ .w = send_btn_size, .h = send_btn_size });
        const hovered = zgui.isItemHovered(.{});
        const draw_list = zgui.getWindowDrawList();
        const cx = btn_pos[0] + send_btn_size * 0.5;
        const cy = btn_pos[1] + send_btn_size * 0.5;
        const r = send_btn_size * 0.5;

        const circle_color = if (pending)
            colors.rgba(80, 72, 24, 255)
        else if (hovered)
            theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.12)
        else
            theme.COLOR_SECONDARY_GREEN;
        draw_list.addCircleFilled(.{
            .p = .{ cx, cy },
            .r = r,
            .col = zgui.colorConvertFloat4ToU32(circle_color),
        });

        if (pending) {
            const dot_r = theme.scaledUi(2.0);
            const white = zgui.colorConvertFloat4ToU32(theme.COLOR_WHITE);
            draw_list.addCircleFilled(.{ .p = .{ cx - theme.scaledUi(6.0), cy }, .r = dot_r, .col = white });
            draw_list.addCircleFilled(.{ .p = .{ cx, cy }, .r = dot_r, .col = white });
            draw_list.addCircleFilled(.{ .p = .{ cx + theme.scaledUi(6.0), cy }, .r = dot_r, .col = white });
        } else {
            const white = zgui.colorConvertFloat4ToU32(theme.COLOR_WHITE);
            const arrow_half_w = theme.scaledUi(5.5);
            const arrow_top = cy - theme.scaledUi(7.0);
            const arrow_mid = cy - theme.scaledUi(1.0);
            const arrow_bottom = cy + theme.scaledUi(7.0);

            draw_list.addTriangleFilled(.{
                .p1 = .{ cx, arrow_top },
                .p2 = .{ cx - arrow_half_w, arrow_mid },
                .p3 = .{ cx + arrow_half_w, arrow_mid },
                .col = white,
            });
            draw_list.addLine(.{
                .p1 = .{ cx, arrow_mid },
                .p2 = .{ cx, arrow_bottom },
                .col = white,
                .thickness = theme.scaledUi(2.4),
            });
        }

        if ((clicked or submitted) and !pending) {
            state.sendDraft() catch |err| {
                Impl.log.err("failed to send draft: {s}", .{@errorName(err)});
            };
        }
    }
}

/// Draws the compact attachment preview above the composer.
fn renderComposerAttachmentPreview(comptime Impl: type, state: *Impl.AppState, image: Impl.ChatImageAttachment) void {
    zgui.beginGroup();
    defer zgui.endGroup();

    renderImageAttachmentCard(Impl, state, image, true);
    zgui.sameLine(.{ .spacing = theme.scaledUi(8.0) });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = colors.rgba(52, 54, 61, 255) });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = colors.rgba(74, 76, 84, 255) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = colors.rgba(92, 94, 102, 255) });
    if (zgui.button("x", .{ .w = theme.scaledUi(26.0), .h = theme.scaledUi(26.0) })) {
        state.clearCurrentDraftImage();
    }
    zgui.popStyleColor(.{ .count = 3 });
}

/// Draws an image attachment card in transcript or composer mode.
fn renderImageAttachmentCard(comptime Impl: type, state: *Impl.AppState, image: Impl.ChatImageAttachment, compact: bool) void {
    const avail_width = @max(zgui.getContentRegionAvail()[0], theme.scaledUi(120.0));
    const card_width: f32 = if (compact)
        theme.clampf(avail_width, theme.scaledUi(196.0), theme.scaledUi(320.0))
    else
        theme.clampf(avail_width, theme.scaledUi(220.0), theme.scaledUi(420.0));
    const card_height: f32 = if (compact)
        theme.clampf(card_width * 0.34, theme.scaledUi(68.0), theme.scaledUi(96.0))
    else
        theme.clampf(card_width * 0.74, theme.scaledUi(168.0), theme.scaledUi(260.0));
    const card_padding: f32 = if (compact) theme.scaledUi(8.0) else theme.scaledUi(10.0);
    const preview_width: f32 = if (compact) theme.clampf(card_width * 0.26, theme.scaledUi(50.0), theme.scaledUi(72.0)) else card_width - (card_padding * 2.0);
    const preview_height: f32 = if (compact) card_height - (card_padding * 2.0) else theme.clampf(card_height * 0.62, theme.scaledUi(116.0), theme.scaledUi(180.0));
    const start = zgui.getCursorScreenPos();
    var byte_size_buf = std.mem.zeroes([32:0]u8);
    const byte_size_text = Impl.formatByteSize(&byte_size_buf, image.byte_size);

    zgui.dummy(.{ .w = card_width, .h = card_height });
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{
        .pmin = start,
        .pmax = .{ start[0] + card_width, start[1] + card_height },
        .col = zgui.colorConvertFloat4ToU32(colors.rgba(42, 43, 50, 255)),
        .rounding = theme.scaledUi(12.0),
    });
    draw_list.addRect(.{
        .pmin = start,
        .pmax = .{ start[0] + card_width, start[1] + card_height },
        .col = zgui.colorConvertFloat4ToU32(colors.DARK_BLUE),
        .rounding = theme.scaledUi(12.0),
        .thickness = 1.0,
    });
    draw_list.addRectFilled(.{
        .pmin = .{ start[0] + card_padding, start[1] + card_padding },
        .pmax = .{ start[0] + card_padding + preview_width, start[1] + card_padding + preview_height },
        .col = zgui.colorConvertFloat4ToU32(colors.rgba(24, 25, 31, 255)),
        .rounding = theme.scaledUi(10.0),
    });

    zgui.pushStrIdZ(image.path);
    defer zgui.popId();

    zgui.setCursorScreenPos(.{ start[0] + card_padding, start[1] + card_padding });
    const texture = state.ensureImageTexture(image.path);
    if (texture) |cached| {
        const dims = Impl.scaledImageSize(cached.width, cached.height, preview_width, preview_height);
        const x_offset = (preview_width - dims[0]) * 0.5;
        const y_offset = (preview_height - dims[1]) * 0.5;
        const image_pos = [2]f32{ start[0] + card_padding + x_offset, start[1] + card_padding + y_offset };
        zgui.setCursorScreenPos(image_pos);
        zgui.image(Impl.textureRefFromGlId(cached.texture_id), .{
            .w = dims[0],
            .h = dims[1],
        });
        zgui.setCursorScreenPos(image_pos);
        if (zgui.invisibleButton("##attachment-thumb", .{
            .w = dims[0],
            .h = dims[1],
        })) {
            state.openImageModal(image.path);
        }
        if (zgui.isItemHovered(.{})) {
            draw_list.addRect(.{
                .pmin = .{ image_pos[0], image_pos[1] },
                .pmax = .{ image_pos[0] + dims[0], image_pos[1] + dims[1] },
                .col = zgui.colorConvertFloat4ToU32(colors.DARK_BLUE),
                .rounding = theme.scaledUi(8.0),
                .thickness = 1.0,
            });
        }
    } else {
        if (zgui.button("Image", .{ .w = preview_width, .h = preview_height })) {
            state.openImageModal(image.path);
        }
    }

    if (compact) {
        zgui.setCursorScreenPos(.{ start[0] + card_padding + preview_width + theme.scaledUi(10.0), start[1] + theme.scaledUi(11.0) });
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{image.file_name});
        zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}  {s}", .{ image.mime, byte_size_text });
        zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Clipboard image", .{});
    } else {
        zgui.setCursorScreenPos(.{ start[0] + theme.scaledUi(12.0), start[1] + card_padding + preview_height + theme.scaledUi(10.0) });
        zgui.textColored(theme.COLOR_WHITE, "{s}", .{image.file_name});
        zgui.textColored(theme.COLOR_TEXT_MUTED, "{s}  {s}", .{ image.mime, byte_size_text });
    }
    zgui.setCursorScreenPos(.{ start[0], start[1] + card_height });
}

const TranscriptBubbleTheme = struct {
    background: [4]f32,
    border: [4]f32,
    author: [4]f32,
};

/// Returns the bubble colors for a transcript role.
fn transcriptBubbleTheme(role: anytype) TranscriptBubbleTheme {
    if (role == .user) return .{
        // .background = colors.rgba(18, 62, 42, 255),
        .background = colors.rgba(0x20, 0x27, 0x2A, 255),
        .border = colors.DARK_BLUE,
        .author = colors.rgba(130, 255, 180, 255),
    };
    if (role == .assistant) return .{
        // .background = colors.rgba(38, 39, 44, 255),

        .background = colors.rgba(0x0D, 0x12, 0x13, 255),
        // .border = colors.DARK_BLUE,
        .border = colors.rgba(0, 0, 0, 0),
        .author = colors.rgba(180, 185, 200, 255),
    };
    return .{
        .background = colors.rgba(52, 42, 18, 255),
        .border = colors.DARK_BLUE,
        .author = colors.rgba(255, 230, 150, 255),
    };
}

/// Decides whether streamed output should keep auto-scrolling.
fn transcriptShouldAutoFollow(state: anytype) bool {
    if (!state.hasPendingStream()) return false;
    const scroll_max_y = zgui.getScrollMaxY();
    if (scroll_max_y <= 0.0) return true;
    const scroll_y = zgui.getScrollY();
    return (scroll_max_y - scroll_y) <= theme.scaledUi(72.0);
}

/// Adapts typed transcript height calculation to the generic helper.
fn transcriptBubbleHeight(comptime Impl: type, author: []const u8, body: []const u8, image: ?Impl.ChatImageAttachment) f32 {
    return transcriptBubbleHeightGeneric(author, body, image);
}

/// Measures the height needed for a transcript bubble.
fn transcriptBubbleHeightGeneric(author: []const u8, body: []const u8, image: anytype) f32 {
    const style = zgui.getStyle();
    const avail = zgui.getContentRegionAvail();
    const inner_width = @max(avail[0] - (theme.TRANSCRIPT_BUBBLE_PADDING_X * 2.0), 64.0);
    const author_size = if (shouldShowBubbleAuthor(author)) zgui.calcTextSize(author, .{}) else .{ 0.0, 0.0 };
    const body_size = zgui.calcTextSize(body, .{ .wrap_width = inner_width });
    const image_height: f32 = if (image != null) theme.clampf(inner_width * 0.46, theme.scaledUi(132.0), theme.scaledUi(220.0)) else 0.0;
    const image_gap: f32 = if (image != null and body.len > 0) theme.scaledUi(8.0) else 0.0;
    const vertical_padding = theme.TRANSCRIPT_BUBBLE_PADDING_Y * 2.0;
    const text_gap = if (shouldShowBubbleAuthor(author)) 2.0 + style.item_spacing[1] else 0.0;
    const border_allowance = 4.0;
    return @max(author_size[1] + body_size[1] + image_height + image_gap + vertical_padding + text_gap + border_allowance, theme.scaledUi(56.0));
}

fn shouldShowBubbleAuthor(author: []const u8) bool {
    return !std.mem.eql(u8, author, "You") and !std.mem.eql(u8, author, "Codex");
}

/// Returns the compact height for a simple changed-files card.
fn changedFilesCardHeight(file_count: usize) f32 {
    return 52.0 + (@as(f32, @floatFromInt(file_count)) * 26.0);
}

/// Returns the collapsed height for detailed changed-file entries.
fn detailedChangedFilesCardHeight(entries: anytype) f32 {
    return 52.0 + (@as(f32, @floatFromInt(entries.len)) * 28.0);
}

/// Estimates the current live diff card height.
fn pendingDiffCardHeight(files: anytype) f32 {
    var height: f32 = 52.0;
    for (files) |file| {
        height += 30.0;
        if (file.expanded) {
            const patch_height = if (file.patch) |patch| pendingDiffPatchHeight(patch) else 44.0;
            height += patch_height + 8.0;
        }
    }
    return @min(height, 620.0);
}

/// Estimates the viewport height for a patch block.
fn pendingDiffPatchHeight(patch: []const u8) f32 {
    const line_count = countTextLines(patch);
    return @min(28.0 + (@as(f32, @floatFromInt(line_count)) * 18.0), 240.0);
}

/// Parses changed-file text from legacy or streamed bodies.
fn parseChangedFileEntries(comptime Impl: type, body: []const u8) std.ArrayListUnmanaged(Impl.ChangedFileEntry) {
    if (std.mem.startsWith(u8, body, Impl.PERSISTED_DIFF_MARKER)) {
        return parsePersistedDiffEntries(Impl, body);
    }

    var entries: std.ArrayListUnmanaged(Impl.ChangedFileEntry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const plus_index = std.mem.lastIndexOf(u8, trimmed, " +") orelse continue;
        const path = std.mem.trimRight(u8, trimmed[0..plus_index], &std.ascii.whitespace);
        const counts = trimmed[plus_index + 2 ..];
        const slash_index = std.mem.indexOf(u8, counts, " / -") orelse continue;
        const add_slice = counts[0..slash_index];
        const del_slice = counts[slash_index + 5 ..];
        const additions = std.fmt.parseInt(i64, add_slice, 10) catch 0;
        const deletions = std.fmt.parseInt(i64, del_slice, 10) catch 0;

        entries.append(std.heap.page_allocator, .{
            .path = path,
            .additions = additions,
            .deletions = deletions,
            .patch = null,
        }) catch break;
    }
    return entries;
}

/// Parses the persisted diff wire format into file entries.
fn parsePersistedDiffEntries(comptime Impl: type, body: []const u8) std.ArrayListUnmanaged(Impl.ChangedFileEntry) {
    var entries: std.ArrayListUnmanaged(Impl.ChangedFileEntry) = .empty;
    var cursor: usize = Impl.PERSISTED_DIFF_MARKER.len;

    while (cursor < body.len) {
        const line_end_rel = std.mem.indexOfScalarPos(u8, body, cursor, '\n') orelse break;
        const header = body[cursor..line_end_rel];
        cursor = line_end_rel + 1;
        if (!std.mem.startsWith(u8, header, "FILE\t")) break;

        var parts = std.mem.splitScalar(u8, header, '\t');
        _ = parts.next();
        const path = parts.next() orelse break;
        const additions_text = parts.next() orelse break;
        const deletions_text = parts.next() orelse break;
        const patch_len_text = parts.next() orelse break;

        const additions = std.fmt.parseInt(i64, additions_text, 10) catch 0;
        const deletions = std.fmt.parseInt(i64, deletions_text, 10) catch 0;
        const patch_len = std.fmt.parseInt(usize, patch_len_text, 10) catch 0;
        if (cursor + patch_len > body.len) break;

        const patch = if (patch_len > 0) body[cursor .. cursor + patch_len] else null;
        cursor += patch_len;
        if (cursor < body.len and body[cursor] == '\n') cursor += 1;

        entries.append(std.heap.page_allocator, .{
            .path = path,
            .additions = additions,
            .deletions = deletions,
            .patch = patch,
        }) catch break;
    }

    return entries;
}

/// Totals additions and deletions for parsed changed files.
fn summarizeChangedFiles(entries: anytype) struct { additions: i64, deletions: i64 } {
    var additions: i64 = 0;
    var deletions: i64 = 0;
    for (entries.items) |entry| {
        additions += entry.additions;
        deletions += entry.deletions;
    }
    return .{ .additions = additions, .deletions = deletions };
}

/// Reports whether any changed-file entry includes a patch body.
fn changedFilesEntriesHavePatch(entries: anytype) bool {
    for (entries) |entry| {
        if (entry.patch != null) return true;
    }
    return false;
}

/// Totals additions and deletions for pending diff files.
fn summarizePendingDiffFiles(files: anytype) struct { additions: i64, deletions: i64 } {
    var additions: i64 = 0;
    var deletions: i64 = 0;
    for (files) |file| {
        additions += file.additions;
        deletions += file.deletions;
    }
    return .{ .additions = additions, .deletions = deletions };
}

/// Counts newline-delimited lines for patch sizing.
fn countTextLines(text: []const u8) usize {
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |char| {
        if (char == '\n') count += 1;
    }
    return count;
}

/// Frees a copied approval snapshot after rendering.
fn freePendingApproval(allocator: std.mem.Allocator, approval: anytype) void {
    if (approval.*) |snapshot| {
        allocator.free(snapshot.call_id);
        allocator.free(snapshot.title);
        allocator.free(snapshot.body);
        approval.* = null;
    }
}
