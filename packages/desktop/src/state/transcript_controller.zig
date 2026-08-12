//! Transcript focus, selection, layout cache, and scroll controller state.

const std = @import("std");
const palette = @import("palette");
const chat_types = @import("chat_types.zig");
const provider_models = @import("provider_models.zig");
const diff_view_cache = @import("../ui/diff_view_cache.zig");
const chat_markdown = @import("../ui/chat_markdown.zig");
const theme = @import("../ui/theme.zig");
const workspace_layout = @import("workspace_layout.zig");

const TranscriptBodyKind = chat_types.TranscriptBodyKind;
const TranscriptMarkdownBody = chat_types.TranscriptMarkdownBody;
const ChatRole = provider_models.ChatRole;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;
const TRANSCRIPT_KEYBOARD_LINE_PX: f32 = 29.0;
const log = std.log.scoped(.native_shell);

pub const MarkdownSelectionPoint = struct {
    message_index: usize,
    point: chat_markdown.SelectionPoint,
};

pub const MarkdownSelection = struct {
    anchor: MarkdownSelectionPoint,
    focus: MarkdownSelectionPoint,
};

pub const State = struct {
    focused: bool = false,
    selection_modal_requested: bool = false,
    project_index: ?usize = null,
    thread_index: ?usize = null,
    selection_text: ?[:0]u8 = null,
    markdown_selection_project_index: ?usize = null,
    markdown_selection_thread_index: ?usize = null,
    markdown_selection_anchor: ?MarkdownSelectionPoint = null,
    markdown_selection_focus: ?MarkdownSelectionPoint = null,
    markdown_selection_dragging: bool = false,
    palette_mouse_x: f32 = 0.0,
    palette_mouse_y: f32 = 0.0,
    palette_mouse_in_workspace: bool = false,
    palette_column: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    palette_scroll_y: f32 = 0.0,
    palette_clip: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    markdown_project_index: ?usize = null,
    markdown_thread_index: ?usize = null,
    markdown_entries: std.ArrayList(?*TranscriptMarkdownBody) = .empty,
    diff_view_cache: diff_view_cache.Cache = .{},
    auto_follow_pending: bool = true,
    scroll_to_bottom_frames: u8 = 8,
    pending_scroll_px: f32 = 0.0,
    pending_page_steps: i16 = 0,
    scroll_pending_track_project: usize = std.math.maxInt(usize),
    scroll_pending_track_thread: usize = std.math.maxInt(usize),
};

pub fn closeTranscriptSelectionModal(self: anytype) void {
    self.transcript_controller.selection_modal_requested = false;
    if (self.transcript_controller.selection_text) |text| {
        self.allocator.free(text);
        self.transcript_controller.selection_text = null;
    }
}

pub fn transcriptSelectionBuffer(self: anytype) ?[:0]u8 {
    return self.transcript_controller.selection_text;
}

pub fn consumeTranscriptSelectionModalRequest(self: anytype) bool {
    const requested = self.transcript_controller.selection_modal_requested;
    self.transcript_controller.selection_modal_requested = false;
    return requested;
}

pub fn isTranscriptFocused(self: anytype) bool {
    return self.transcript_controller.focused and !self.composer_controller.focused and !self.terminal_controller.focused and !self.browser_controller.pane_focused;
}

pub fn ensureTranscriptMarkdownSelectionCurrent(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) {
        self.clearTranscriptMarkdownSelection();
        return;
    }

    const project_index = self.project_controller.selected_index;
    const thread_index = self.currentProject().selected_thread_index;
    if (self.transcript_controller.markdown_selection_project_index == project_index and
        self.transcript_controller.markdown_selection_thread_index == thread_index)
    {
        return;
    }

    self.clearTranscriptMarkdownSelection();
}

pub fn transcriptMarkdownSelection(self: anytype) ?MarkdownSelection {
    self.ensureTranscriptMarkdownSelectionCurrent();
    if (self.project_controller.projects.items.len == 0) return null;
    return markdownSelectionForContext(
        &self.transcript_controller,
        self.project_controller.selected_index,
        self.currentProject().selected_thread_index,
    );
}

/// Returns the selection for the temporarily active render context without
/// clearing a selection owned by another scrolling workspace pane.
pub fn peekTranscriptMarkdownSelection(self: anytype) ?MarkdownSelection {
    if (self.project_controller.projects.items.len == 0) return null;
    return markdownSelectionForContext(
        &self.transcript_controller,
        self.project_controller.selected_index,
        self.currentProject().selected_thread_index,
    );
}

pub fn transcriptMarkdownSelectionDragging(self: anytype) bool {
    self.ensureTranscriptMarkdownSelectionCurrent();
    return self.transcript_controller.markdown_selection_dragging;
}

pub fn transcriptMarkdownSelectionActive(self: anytype) bool {
    self.ensureTranscriptMarkdownSelectionCurrent();
    return self.transcript_controller.markdown_selection_anchor != null and
        self.transcript_controller.markdown_selection_focus != null;
}

pub fn beginTranscriptMarkdownSelection(self: anytype, message_index: usize, point: chat_markdown.SelectionPoint) void {
    if (self.project_controller.projects.items.len == 0) return;
    const selection_point: MarkdownSelectionPoint = .{
        .message_index = message_index,
        .point = point,
    };
    self.transcript_controller.markdown_selection_project_index = self.project_controller.selected_index;
    self.transcript_controller.markdown_selection_thread_index = self.currentProject().selected_thread_index;
    self.transcript_controller.markdown_selection_anchor = selection_point;
    self.transcript_controller.markdown_selection_focus = selection_point;
    self.transcript_controller.markdown_selection_dragging = true;
}

pub fn updateTranscriptMarkdownSelection(self: anytype, message_index: usize, point: chat_markdown.SelectionPoint) void {
    self.ensureTranscriptMarkdownSelectionCurrent();
    if (self.transcript_controller.markdown_selection_anchor == null) return;
    self.transcript_controller.markdown_selection_focus = .{
        .message_index = message_index,
        .point = point,
    };
}

pub fn endTranscriptMarkdownSelection(self: anytype) void {
    self.transcript_controller.markdown_selection_dragging = false;
}

pub fn notePaletteWorkspaceMouseMotion(self: anytype, x: f32, y: f32) void {
    self.transcript_controller.palette_mouse_x = x;
    self.transcript_controller.palette_mouse_y = y;
    self.transcript_controller.palette_mouse_in_workspace = true;
}

pub fn selectAllTranscriptMarkdownSelection(
    self: anytype,
    first_message_index: usize,
    first: chat_markdown.SelectionPoint,
    last_message_index: usize,
    last: chat_markdown.SelectionPoint,
) void {
    if (self.project_controller.projects.items.len == 0) return;
    self.transcript_controller.markdown_selection_project_index = self.project_controller.selected_index;
    self.transcript_controller.markdown_selection_thread_index = self.currentProject().selected_thread_index;
    self.transcript_controller.markdown_selection_anchor = .{
        .message_index = first_message_index,
        .point = first,
    };
    self.transcript_controller.markdown_selection_focus = .{
        .message_index = last_message_index,
        .point = last,
    };
    self.transcript_controller.markdown_selection_dragging = false;
}

pub fn clearTranscriptMarkdownSelection(self: anytype) void {
    self.transcript_controller.markdown_selection_project_index = null;
    self.transcript_controller.markdown_selection_thread_index = null;
    self.transcript_controller.markdown_selection_anchor = null;
    self.transcript_controller.markdown_selection_focus = null;
    self.transcript_controller.markdown_selection_dragging = false;
}

fn markdownSelectionForContext(controller: *const State, project_index: usize, thread_index: usize) ?MarkdownSelection {
    if (controller.markdown_selection_project_index != project_index or
        controller.markdown_selection_thread_index != thread_index)
    {
        return null;
    }
    const anchor = controller.markdown_selection_anchor orelse return null;
    const focus = controller.markdown_selection_focus orelse return null;
    return .{ .anchor = anchor, .focus = focus };
}

test "render context lookup preserves another pane selection" {
    const controller: State = .{
        .markdown_selection_project_index = 2,
        .markdown_selection_thread_index = 4,
        .markdown_selection_anchor = .{ .message_index = 1, .point = .{ .line_index = 0, .column = 2 } },
        .markdown_selection_focus = .{ .message_index = 3, .point = .{ .line_index = 1, .column = 5 } },
        .markdown_selection_dragging = true,
    };

    try std.testing.expect(markdownSelectionForContext(&controller, 2, 4) != null);
    try std.testing.expect(markdownSelectionForContext(&controller, 2, 5) == null);
    try std.testing.expect(controller.markdown_selection_anchor != null);
    try std.testing.expect(controller.markdown_selection_focus != null);
    try std.testing.expect(controller.markdown_selection_dragging);
}

pub fn transcriptMarkdownBodyView(self: anytype, message_index: usize, body: []const u8) ?*const chat_markdown.BodyView {
    const entry = transcriptBodyEntry(self, message_index, body, .markdown) orelse return null;
    return &entry.view;
}

pub fn transcriptPlainBodyView(self: anytype, message_index: usize, body: []const u8) ?*const chat_markdown.BodyView {
    const entry = transcriptBodyEntry(self, message_index, body, .plain) orelse return null;
    return &entry.view;
}

pub fn cachedTranscriptMessageHeight(
    self: anytype,
    message_index: usize,
    width: f32,
    body: []const u8,
    role: ChatRole,
    author: []const u8,
    assistant_plain_layout: bool,
    image_present: bool,
) ?f32 {
    const thread = self.currentThreadMutable();
    thread.ensureTranscriptHeightEntries(self.allocator);
    if (message_index >= thread.transcript_height_entries.items.len) return null;

    const entry = thread.transcript_height_entries.items[message_index];
    if (!entry.valid) return null;
    if (entry.role != role) return null;
    if (entry.assistant_plain_layout != assistant_plain_layout) return null;
    if (@abs(entry.width - width) > 0.5) return null;
    if (entry.body_hash != std.hash.Wyhash.hash(0, body)) return null;
    if (entry.author_hash != std.hash.Wyhash.hash(0, author)) return null;
    if (entry.image_present != image_present) return null;
    return entry.height;
}

pub fn putTranscriptMessageHeight(
    self: anytype,
    message_index: usize,
    width: f32,
    body: []const u8,
    role: ChatRole,
    author: []const u8,
    assistant_plain_layout: bool,
    image_present: bool,
    height: f32,
) void {
    if (height <= 0.0) return;
    const thread = self.currentThreadMutable();
    thread.ensureTranscriptHeightEntries(self.allocator);
    if (message_index >= thread.transcript_height_entries.items.len) return;

    thread.transcript_height_entries.items[message_index] = .{
        .valid = true,
        .role = role,
        .assistant_plain_layout = assistant_plain_layout,
        .width = width,
        .body_hash = std.hash.Wyhash.hash(0, body),
        .author_hash = std.hash.Wyhash.hash(0, author),
        .image_present = image_present,
        .height = height,
    };
}

pub fn ensureTranscriptMarkdownEntries(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) {
        self.clearTranscriptMarkdownEntries();
        return;
    }

    const project_index = self.project_controller.selected_index;
    const thread_index = self.currentProject().selected_thread_index;
    const message_count = self.currentThread().messages.items.len;
    if (self.transcript_controller.markdown_project_index == project_index and
        self.transcript_controller.markdown_thread_index == thread_index and
        self.transcript_controller.markdown_entries.items.len == message_count)
    {
        return;
    }

    self.clearTranscriptMarkdownEntries();
    self.transcript_controller.markdown_entries.appendNTimes(self.allocator, null, message_count) catch return;
    self.transcript_controller.markdown_project_index = project_index;
    self.transcript_controller.markdown_thread_index = thread_index;
}

pub fn clearTranscriptMarkdownEntries(self: anytype) void {
    for (self.transcript_controller.markdown_entries.items) |entry| {
        if (entry) |owned| owned.deinit(self.allocator);
    }
    self.transcript_controller.markdown_entries.clearRetainingCapacity();
    self.transcript_controller.markdown_project_index = null;
    self.transcript_controller.markdown_thread_index = null;
}

pub fn transcriptBodyEntry(self: anytype, message_index: usize, body: []const u8, kind: TranscriptBodyKind) ?*TranscriptMarkdownBody {
    if (body.len == 0) return null;
    const thread = self.currentThreadMutable();
    thread.ensureTranscriptMarkdownEntries(self.allocator);
    if (message_index >= thread.transcript_markdown_entries.items.len) return null;
    return transcriptBodyEntryForSlot(self, &thread.transcript_markdown_entries.items[message_index], body, kind);
}

fn transcriptBodyEntryForSlot(self: anytype, slot: *?*TranscriptMarkdownBody, body: []const u8, kind: TranscriptBodyKind) ?*TranscriptMarkdownBody {
    if (slot.*) |entry| {
        if (entry.kind != kind or !std.mem.eql(u8, entry.owned_body, body)) {
            entry.deinit(self.allocator);
            slot.* = null;
        } else {
            return entry;
        }
    }

    const created = createTranscriptBody(self, body, kind) catch return null;
    slot.* = created;
    return created;
}

pub fn transcriptMarkdownBodyEntry(self: anytype, message_index: usize, body: []const u8) ?*TranscriptMarkdownBody {
    return transcriptBodyEntry(self, message_index, body, .markdown);
}

pub fn transcriptPlainBodyEntry(self: anytype, message_index: usize, body: []const u8) ?*TranscriptMarkdownBody {
    return transcriptBodyEntry(self, message_index, body, .plain);
}

/// Returns parsed geometry for the current in-flight assistant text.
pub fn pendingTranscriptPlainBodyEntry(self: anytype, body: []const u8) ?*TranscriptMarkdownBody {
    if (body.len == 0) return null;
    const thread = self.currentThreadMutable();
    return transcriptBodyEntryForSlot(self, &thread.pending_transcript_body, body, .plain);
}

/// Releases parsed/render data retained only for an in-flight assistant row.
pub fn clearPendingTranscriptBody(self: anytype, thread: *chat_types.ChatThread) void {
    if (thread.pending_transcript_body) |entry| entry.deinit(self.allocator);
    thread.pending_transcript_body = null;
}

pub fn createTranscriptBody(self: anytype, body: []const u8, kind: TranscriptBodyKind) !*TranscriptMarkdownBody {
    const entry = try self.allocator.create(TranscriptMarkdownBody);
    errdefer self.allocator.destroy(entry);

    const owned_body = try self.allocator.dupe(u8, body);
    errdefer self.allocator.free(owned_body);
    var view = try buildTranscriptBodyView(self.allocator, owned_body, kind);
    errdefer view.deinit(self.allocator);

    entry.* = .{
        .owned_body = owned_body,
        .kind = kind,
        .view = view,
        .render_cache = .{},
        .render_cache_frame_text = .empty,
        .render_cache_text_arena = std.heap.ArenaAllocator.init(self.allocator),
    };

    return entry;
}

pub fn createTranscriptMarkdownBody(self: anytype, body: []const u8) !*TranscriptMarkdownBody {
    return createTranscriptBody(self, body, .markdown);
}

fn buildTranscriptBodyView(allocator: std.mem.Allocator, body: []const u8, kind: TranscriptBodyKind) !chat_markdown.BodyView {
    return switch (kind) {
        .markdown => chat_markdown.buildBodyView(allocator, body),
        .plain => chat_markdown.buildPlainBodyView(allocator, body),
    };
}

test "transcript body cache preserves markdown and literal plain parsing" {
    const source = "**bold**";
    var markdown = try buildTranscriptBodyView(std.testing.allocator, source, .markdown);
    defer markdown.deinit(std.testing.allocator);
    var plain = try buildTranscriptBodyView(std.testing.allocator, source, .plain);
    defer plain.deinit(std.testing.allocator);

    try std.testing.expect(markdown.document != null);
    try std.testing.expect(plain.document == null);
    try std.testing.expectEqual(@as(usize, 1), plain.blockCount());
    try std.testing.expectEqualStrings(source, plain.blockAt(0).text.text);
}

test "pending transcript body slot reuses unchanged text and replaces changed text" {
    const FakeState = struct {
        allocator: std.mem.Allocator,
    };
    var state: FakeState = .{ .allocator = std.testing.allocator };
    var slot: ?*TranscriptMarkdownBody = null;
    defer if (slot) |entry| entry.deinit(std.testing.allocator);

    const first = transcriptBodyEntryForSlot(&state, &slot, "hello", .plain).?;
    try std.testing.expectEqual(first, transcriptBodyEntryForSlot(&state, &slot, "hello", .plain).?);
    const changed = transcriptBodyEntryForSlot(&state, &slot, "hello world", .plain).?;
    try std.testing.expectEqualStrings("hello world", changed.owned_body);
    try std.testing.expectEqual(TranscriptBodyKind.plain, changed.kind);
}

pub fn buildCurrentTranscriptSelectionText(self: anytype) ![:0]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(self.allocator);

    const thread = self.currentThread();
    for (thread.messages.items, 0..) |message, index| {
        if (index > 0) {
            try buffer.appendSlice(self.allocator, "\n\n");
        }
        try buffer.appendSlice(self.allocator, message.author);

        if (message.image) |image| {
            const image_label = try std.fmt.allocPrint(self.allocator, "\n[Image: {s}]", .{image.file_name});
            defer self.allocator.free(image_label);
            try buffer.appendSlice(self.allocator, image_label);
        }
        for (message.extra_images) |image| {
            const image_label = try std.fmt.allocPrint(self.allocator, "\n[Image: {s}]", .{image.file_name});
            defer self.allocator.free(image_label);
            try buffer.appendSlice(self.allocator, image_label);
        }
        if (message.body.len > 0) {
            try buffer.append(self.allocator, '\n');
            try buffer.appendSlice(self.allocator, message.body);
        }
    }

    if (buffer.items.len == 0) {
        try buffer.appendSlice(self.allocator, "No messages yet.");
    }

    return try self.allocator.dupeZ(u8, buffer.items);
}

pub fn requestTranscriptScrollToBottom(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    // Drop any saved offset so the next transcript layout uses the fresh tail height
    // (e.g. right after appending the user message and starting a stream).
    const thread_index = self.currentProject().selected_thread_index;
    self.currentThreadMutable().transcript_scroll_valid = false;
    self.currentProjectMutable().workspace_layout.resetChatTranscriptScrollForThread(thread_index);
    self.transcript_controller.auto_follow_pending = true;
    self.transcript_controller.scroll_to_bottom_frames = 8;
    self.transcript_controller.pending_scroll_px = 0;
    self.transcript_controller.pending_page_steps = 0;
}

pub fn requestTranscriptLineScroll(self: anytype, delta: i16) void {
    if (delta == 0) return;
    self.noteInteraction();
    self.transcript_controller.auto_follow_pending = false;
    self.transcript_controller.scroll_to_bottom_frames = 0;
    self.transcript_controller.pending_scroll_px += @as(f32, @floatFromInt(delta)) * theme.scaledUi(TRANSCRIPT_KEYBOARD_LINE_PX);
    self.markDirty();
}

pub fn requestTranscriptPageScroll(self: anytype, delta: i16) void {
    if (delta == 0) return;
    self.noteInteraction();
    self.transcript_controller.auto_follow_pending = false;
    self.transcript_controller.scroll_to_bottom_frames = 0;
    const next = @as(i32, self.transcript_controller.pending_page_steps) + @as(i32, delta);
    self.transcript_controller.pending_page_steps = @intCast(std.math.clamp(next, -12, 12));
    self.markDirty();
}

pub fn currentThreadMutable(self: anytype) *chat_types.ChatThread {
    return self.currentProjectMutable().currentThreadMutable();
}

pub fn rememberCurrentTranscriptScroll(self: anytype, scroll_y: f32) void {
    const thread = self.currentThreadMutable();
    thread.transcript_scroll_valid = true;
    thread.transcript_scroll_y = @max(scroll_y, 0.0);
}

pub fn rememberWorkspaceChatTranscriptScroll(self: anytype, pane_id: WorkspacePaneId, scroll_y: f32) void {
    if (self.project_controller.projects.items.len == 0) return;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane = layout.paneByIdMutable(pane_id) orelse return;
    switch (pane.ref) {
        .chat => |*ref| {
            ref.transcript_scroll_valid = true;
            ref.transcript_scroll_y = @max(scroll_y, 0.0);
        },
        else => {},
    }
}

/// Rebases every saved transcript offset for the current thread by `delta`.
/// Offsets are stored relative to the estimated top of the thread's content;
/// when lazy layout materializes older rows that estimate changes, so anchors
/// must move by the same amount to keep the rows they point at on screen.
/// Threads/panes in tail-follow (no saved offset) are left untouched.
pub fn shiftCurrentTranscriptScroll(self: anytype, delta: f32) void {
    if (self.project_controller.projects.items.len == 0) return;
    const thread = self.currentThreadMutable();
    if (thread.transcript_scroll_valid) {
        thread.transcript_scroll_y = @max(thread.transcript_scroll_y + delta, 0.0);
    }
    const thread_index = self.currentProject().selected_thread_index;
    self.currentProjectMutable().workspace_layout.shiftChatTranscriptScrollForThread(thread_index, delta);
}

pub fn currentTranscriptScrollY(self: anytype) ?f32 {
    const thread = self.currentThread();
    if (!thread.transcript_scroll_valid) return null;
    return thread.transcript_scroll_y;
}

pub fn workspaceChatTranscriptScrollY(self: anytype, pane_id: WorkspacePaneId) ?f32 {
    if (self.project_controller.projects.items.len == 0) return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane = layout.paneById(pane_id) orelse return null;
    return switch (pane.ref) {
        .chat => |ref| if (ref.transcript_scroll_valid) ref.transcript_scroll_y else null,
        else => null,
    };
}

pub fn acknowledgeFocusedChatCompletion(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const project = &self.project_controller.projects.items[self.project_controller.selected_index];
    const pane_id = project.workspace_layout.focused_pane_id orelse return false;
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    const thread_index = switch (pane.ref) {
        .chat => |ref| ref.thread_index,
        else => return false,
    };
    return clearChatCompletion(self, self.project_controller.selected_index, thread_index);
}

pub fn acknowledgeFocusedPaneCompletion(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const project_index = self.project_controller.selected_index;
    const project = &self.project_controller.projects.items[project_index];
    const pane_id = project.workspace_layout.focused_pane_id orelse return false;
    const pane = project.workspace_layout.paneById(pane_id) orelse return false;
    return switch (pane.ref) {
        .chat => |ref| clearChatCompletion(self, project_index, ref.thread_index),
        .terminal => |ref| self.clearSurfaceAttentionForDock(project_index, ref.dock_id),
        .browser => false,
    };
}

pub fn clearChatCompletion(self: anytype, project_index: usize, thread_index: usize) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    if (thread_index >= project.threads.items.len) return false;
    const thread = &project.threads.items[thread_index];
    // M4-P4 / Q3 focused-clear: the daemon upserts `chat_completions` in the
    // turn commit unconditionally. The local `completion_pending` flag stays
    // the storage-clear gate for every focus route; the daemon-owned focused
    // completion path arms it in `noteChatCompletion` before routing here so
    // the daemon-written row is cleared within one poll cycle without turning
    // every pane focus into a storage round-trip.
    if (!thread.completion_pending) return false;
    if (!self.queueChatCompletionAcknowledgement(project.id, thread.local_thread_id, thread.completed_at_ms)) return false;
    thread.completion_pending = false;
    thread.completed_at_ms = 0;
    // The acknowledgement worker owns the durable targeted clear. Marking
    // the compatibility projection dirty here made a tiny focus-only change
    // recapture every transcript on close.
    return true;
}

test "chat completion focus clear queues persistence and updates local state immediately" {
    const ProjectStub = struct {
        id: []const u8,
        threads: std.ArrayList(chat_types.ChatThread) = .empty,
    };
    const FakeState = struct {
        allocator: std.mem.Allocator,
        project_controller: struct {
            projects: std.ArrayList(ProjectStub) = .empty,
        } = .{},
        queued: bool = false,
        dirty: bool = false,

        fn queueChatCompletionAcknowledgement(
            self: *@This(),
            workspace_id: []const u8,
            local_thread_id: []const u8,
            completed_at_ms: i64,
        ) bool {
            self.queued = std.mem.eql(u8, workspace_id, "workspace-a") and
                local_thread_id.len > 0 and completed_at_ms == 42;
            return true;
        }

        fn markDirty(self: *@This()) void {
            self.dirty = true;
        }
    };

    var state: FakeState = .{ .allocator = std.testing.allocator };
    defer state.project_controller.projects.deinit(state.allocator);
    var project: ProjectStub = .{ .id = "workspace-a" };
    var thread = try chat_types.ChatThread.init(state.allocator, "Done");
    thread.completion_pending = true;
    thread.completed_at_ms = 42;
    try project.threads.append(state.allocator, thread);
    defer {
        for (project.threads.items) |*item| item.deinit(state.allocator);
        project.threads.deinit(state.allocator);
    }
    try state.project_controller.projects.append(state.allocator, project);

    try std.testing.expect(clearChatCompletion(&state, 0, 0));
    try std.testing.expect(state.queued);
    try std.testing.expect(!state.dirty);
    try std.testing.expect(!project.threads.items[0].completion_pending);
    try std.testing.expectEqual(@as(i64, 0), project.threads.items[0].completed_at_ms);
}
