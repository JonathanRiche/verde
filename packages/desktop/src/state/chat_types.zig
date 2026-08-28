//! Chat transcript, attachment, background-task, and send-state ownership.

const std = @import("std");
const palette = @import("palette");
const ai_harness = @import("../providers/harness.zig");
const chat_threads = @import("../chat/threads.zig");
const chat_markdown = @import("../ui/chat_markdown.zig");
const platform_paths = @import("platform_paths");
const platform_process = @import("../platform/process.zig");
const platform_runtime = @import("platform_runtime");
const runtime_log = @import("../runtime/log.zig");
const thread_binding = @import("../runtime/thread_binding.zig");
const provider_models = @import("provider_models.zig");
const state_sync = @import("sync.zig");

const log = std.log.scoped(.native_shell);
const ReasoningEffort = provider_models.ReasoningEffort;
const FastMode = provider_models.FastMode;
const AccessMode = provider_models.AccessMode;
const ChatRole = provider_models.ChatRole;
const Provider = provider_models.Provider;
const Harness = provider_models.Harness;
const DEFAULT_CODEX_MODEL = provider_models.DEFAULT_CODEX_MODEL;
const DEFAULT_CODEX_REASONING_EFFORT = provider_models.DEFAULT_CODEX_REASONING_EFFORT;
const Mutex = state_sync.Mutex;
const Condition = state_sync.Condition;
const ThreadBinding = thread_binding.ThreadBinding;

pub const DRAFT_CAPACITY = 64 * 1024;
pub const LOCAL_RUNTIME_PROFILE_ID: []const u8 = "local";
pub const PRIMARY_REPOSITORY_ID: []const u8 = "primary";

pub const TranscriptBodyKind = enum {
    markdown,
    plain,
};

pub const TranscriptRenderCacheKey = struct {
    width: f32,
    height: f32,
    ui_scale: f32,
    style_hash: u64,
};

pub const TranscriptMarkdownBody = struct {
    owned_body: []u8,
    kind: TranscriptBodyKind,
    view: chat_markdown.BodyView,
    render_cache: palette.RenderBatch,
    render_cache_frame_text: std.ArrayList(u8),
    render_cache_text_arena: std.heap.ArenaAllocator,
    render_cache_key: ?TranscriptRenderCacheKey = null,
    // Copy-button hits recorded while building the cache (origin-relative
    // rects, payload offsets into `render_cache_frame_text`). Replay frames
    // translate and re-register them so fenced-code messages stay
    // replay-cache eligible instead of re-running markdown every frame.
    render_cache_copy_buttons: std.ArrayList(chat_markdown.CodeCopyButtonSink) = .empty,

    pub fn deinit(self: *TranscriptMarkdownBody, allocator: std.mem.Allocator) void {
        self.render_cache.deinit(allocator);
        self.render_cache_frame_text.deinit(allocator);
        self.render_cache_text_arena.deinit();
        self.render_cache_copy_buttons.deinit(allocator);
        self.view.deinit(allocator);
        allocator.free(self.owned_body);
        allocator.destroy(self);
    }
};

pub const TranscriptHeightEntry = struct {
    valid: bool = false,
    role: ChatRole = .assistant,
    assistant_plain_layout: bool = false,
    width: f32 = 0.0,
    body_hash: u64 = 0,
    author_hash: u64 = 0,
    image_present: bool = false,
    height: f32 = 0.0,
};

pub const TranscriptLayoutItem = struct {
    message_index: usize,
    group_end: usize,
    // Negative offset from the estimated committed tail.
    top: f32,
    height: f32,
};

pub const ChatMessage = struct {
    role: ChatRole,
    author: [:0]const u8,
    body: [:0]const u8,
    image: ?ChatImageAttachment = null,
    extra_images: []ChatImageAttachment = &.{},
    tool_call_id: ?[]const u8 = null,
    tool_call_kind: ?ai_harness.ToolCallKind = null,
    tool_call_status: ?ai_harness.ToolCallStatus = null,
    /// Durable transcript identity (M4-P4): the acceptance-staged client id on
    /// user rows, or the daemon-minted id adopted from `chat.thread.get` at
    /// terminal. Null until an identity is known; persistence carries it
    /// verbatim so flushes never rewrite daemon-committed identities.
    message_id: ?[]const u8 = null,
    /// UI-only entrance timestamp for a card appended by a live stream. It is
    /// intentionally absent from persistence and defaults to fully presented.
    transcript_card_started_ms: i64 = 0,
};

pub const ChatImageAttachment = struct {
    path: [:0]const u8,
    file_name: [:0]const u8,
    mime: [:0]const u8,
    byte_size: usize,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, mime: []const u8, byte_size: usize) !ChatImageAttachment {
        const owned_path = try allocator.dupeZ(u8, path);
        errdefer allocator.free(owned_path);
        const owned_file_name = try allocator.dupeZ(u8, std.fs.path.basename(path));
        errdefer allocator.free(owned_file_name);
        return .{
            .path = owned_path,
            .file_name = owned_file_name,
            .mime = try allocator.dupeZ(u8, mime),
            .byte_size = byte_size,
        };
    }

    pub fn deinit(self: ChatImageAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.file_name);
        allocator.free(self.mime);
    }
};

pub const BackgroundTaskStatus = enum {
    running,
    completed,
    failed,
    stopped,
};

pub const BackgroundTask = struct {
    command: [:0]const u8,
    task_id: ?[:0]const u8 = null,
    item_id: ?[:0]const u8 = null,
    process_id: ?[:0]const u8 = null,
    provider_thread_id: ?[:0]const u8 = null,
    cwd: ?[:0]const u8 = null,
    provider: ?Provider = null,
    pid_path: ?[:0]const u8 = null,
    log_path: ?[:0]const u8 = null,
    pid: ?u32 = null,
    pid_verified: bool = false,
    stop_requested: bool = false,
    status: BackgroundTaskStatus,
    started_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
    last_poll_ms: i64 = 0,
    poll_failure_count: u8 = 0,

    pub fn deinit(self: BackgroundTask, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        if (self.task_id) |value| allocator.free(value);
        if (self.item_id) |value| allocator.free(value);
        if (self.process_id) |value| allocator.free(value);
        if (self.provider_thread_id) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.pid_path) |value| allocator.free(value);
        if (self.log_path) |value| allocator.free(value);
    }

    pub fn matchesEventBody(self: *const BackgroundTask, body_raw: []const u8) bool {
        const task_id = ChatThread.backgroundTaskMetadataValue(body_raw, "Verde task ID:");
        const item_id = ChatThread.backgroundTaskMetadataValue(body_raw, "Codex item ID:");
        const process_id = ChatThread.backgroundTaskMetadataValue(body_raw, "Process ID:");
        const provider_thread_id = ChatThread.backgroundTaskMetadataValue(body_raw, "Provider thread ID:");
        if (task_id != null and self.task_id != null and std.mem.eql(u8, task_id.?, self.task_id.?)) return true;
        if (item_id != null and self.item_id != null and provider_thread_id != null and self.provider_thread_id != null and
            std.mem.eql(u8, item_id.?, self.item_id.?) and std.mem.eql(u8, provider_thread_id.?, self.provider_thread_id.?)) return true;
        if (item_id == null and self.item_id == null and process_id != null and self.process_id != null and
            provider_thread_id != null and self.provider_thread_id != null and std.mem.eql(u8, process_id.?, self.process_id.?) and
            std.mem.eql(u8, provider_thread_id.?, self.provider_thread_id.?)) return true;
        if (task_id == null and item_id == null and process_id == null and self.task_id == null and self.item_id == null and
            self.process_id == null and std.mem.eql(u8, ChatThread.backgroundCommandFromEventBody(body_raw), self.command)) return true;
        return false;
    }
};

pub const ChatThread = struct {
    title: [:0]const u8,
    archived: bool = false,
    committed: bool = false,
    local_thread_id: [:0]const u8,
    last_activity_at: i64 = 0,
    provider_thread_id: ?[:0]const u8 = null,
    model_ref: ?[:0]const u8 = null,
    reasoning_effort: ?ReasoningEffort = null,
    /// OpenCode JSON `variant` when the configured model exposes variant keys.
    opencode_reasoning_variant: ?[:0]const u8 = null,
    /// Working-directory override for provider sessions; null follows the
    /// owning project path so ordinary threads need no extra state.
    cwd: ?[:0]const u8 = null,
    fast_mode: FastMode = .off,
    access_mode: AccessMode = .full_access,
    provider: Provider = .opencode,
    harness: Harness = .local_cli,
    /// Runtime/repository routing is independently selectable while this is a
    /// draft. `committed` is the durable-action boundary; route APIs lock the
    /// binding before evaluating changes once that bit is set.
    runtime_route: ThreadBinding,
    tui_dock_id: ?u32 = null,
    completion_pending: bool = false,
    completed_at_ms: i64 = 0,
    /// Durable sort-index boundary before materialized messages.
    persisted_message_offset: usize = 0,
    messages: std.ArrayList(ChatMessage),
    background_tasks: std.ArrayList(BackgroundTask),
    send_state: *SendState,
    title_generation_state: *TitleGenerationState,
    transcript_markdown_entries: std.ArrayList(?*TranscriptMarkdownBody),
    pending_transcript_body: ?*TranscriptMarkdownBody,
    transcript_height_entries: std.ArrayList(TranscriptHeightEntry),
    transcript_layout_items: std.ArrayList(TranscriptLayoutItem),
    transcript_layout_width: f32 = 0.0,
    transcript_layout_scale: f32 = 0.0,
    transcript_layout_variant_hash: u64 = 0,
    transcript_layout_first_message_index: usize = 0,
    transcript_layout_message_count: usize = 0,
    transcript_layout_committed_height: f32 = 0.0,
    transcript_layout_requested_height: f32 = 0.0,
    transcript_layout_visible_ready: bool = false,
    transcript_layout_valid: bool = false,
    transcript_scroll_valid: bool = false,
    transcript_scroll_y: f32 = 0.0,
    draft_image: ?ChatImageAttachment = null,
    draft_extra_images: std.ArrayList(ChatImageAttachment),
    draft_storage: [DRAFT_CAPACITY:0]u8,
    /// UI-only persistence generation of the newest local composer mutation.
    /// Kept until a covering snapshot is acknowledged so delayed projections
    /// cannot resurrect an empty -> text -> empty draft transition.
    draft_mutation_generation: u64 = 0,
    /// Store revision that durably acknowledged `draft_mutation_generation`.
    /// Zero means the mutation has not reached durable state yet.
    draft_mutation_ack_revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, title: []const u8) !ChatThread {
        const send_state = try allocator.create(SendState);
        errdefer allocator.destroy(send_state);
        send_state.* = .{};
        const title_generation_state = try allocator.create(TitleGenerationState);
        errdefer allocator.destroy(title_generation_state);
        title_generation_state.* = .{};
        const local_thread_id = try allocPrintZCompat(allocator, "chat-{d}-{x}", .{ unixTimestampMs(), @intFromPtr(send_state) });
        errdefer allocator.free(local_thread_id);
        var runtime_route = try ThreadBinding.initDraft(allocator, .{
            .profile_id = LOCAL_RUNTIME_PROFILE_ID,
            .repository_id = PRIMARY_REPOSITORY_ID,
        });
        errdefer runtime_route.deinit(allocator);

        return .{
            .title = try allocator.dupeZ(u8, title),
            .local_thread_id = local_thread_id,
            .committed = false,
            .last_activity_at = 0,
            .model_ref = try allocator.dupeZ(u8, DEFAULT_CODEX_MODEL),
            .reasoning_effort = DEFAULT_CODEX_REASONING_EFFORT,
            .fast_mode = .off,
            .access_mode = .full_access,
            .provider = .codex,
            .harness = .local_cli,
            .runtime_route = runtime_route,
            .tui_dock_id = null,
            .completion_pending = false,
            .completed_at_ms = 0,
            .persisted_message_offset = 0,
            .messages = .empty,
            .background_tasks = .empty,
            .send_state = send_state,
            .title_generation_state = title_generation_state,
            .transcript_markdown_entries = .empty,
            .pending_transcript_body = null,
            .transcript_height_entries = .empty,
            .transcript_layout_items = .empty,
            .transcript_scroll_valid = false,
            .transcript_scroll_y = 0.0,
            .draft_image = null,
            .draft_extra_images = .empty,
            .draft_storage = std.mem.zeroes([DRAFT_CAPACITY:0]u8),
        };
    }

    pub fn currentDraft(self: *const ChatThread) []const u8 {
        const slice = self.draft_storage[0..];
        return std.mem.sliceTo(slice, 0);
    }

    pub fn draftBuffer(self: *ChatThread) [:0]u8 {
        return self.draft_storage[0 .. self.draft_storage.len - 1 :0];
    }

    pub fn setDraft(self: *ChatThread, value: []const u8) void {
        const len = @min(value.len, DRAFT_CAPACITY - 1);
        @memcpy(self.draft_storage[0..len], value[0..len]);
        self.draft_storage[len] = 0;
    }

    pub fn clearDraft(self: *ChatThread) void {
        self.draft_storage[0] = 0;
    }

    pub fn setDraftImage(self: *ChatThread, allocator: std.mem.Allocator, path: []const u8, mime: []const u8, byte_size: usize) !void {
        self.clearDraftImage(allocator);
        self.draft_image = try ChatImageAttachment.init(allocator, path, mime, byte_size);
    }

    pub fn addDraftImage(self: *ChatThread, allocator: std.mem.Allocator, path: []const u8, mime: []const u8, byte_size: usize) !void {
        if (self.draft_image == null) {
            self.draft_image = try ChatImageAttachment.init(allocator, path, mime, byte_size);
            return;
        }
        try self.draft_extra_images.append(allocator, try ChatImageAttachment.init(allocator, path, mime, byte_size));
    }

    pub fn clearDraftImage(self: *ChatThread, allocator: std.mem.Allocator) void {
        if (self.draft_image) |*image| {
            image.deinit(allocator);
            self.draft_image = null;
        }
        for (self.draft_extra_images.items) |*image| {
            image.deinit(allocator);
        }
        self.draft_extra_images.clearRetainingCapacity();
    }

    pub fn clearDraftImageAt(self: *ChatThread, allocator: std.mem.Allocator, index: usize) void {
        if (index == 0) {
            if (self.draft_image) |*image| image.deinit(allocator);
            if (self.draft_extra_images.items.len > 0) {
                self.draft_image = self.draft_extra_images.orderedRemove(0);
            } else {
                self.draft_image = null;
            }
            return;
        }
        const extra_index = index - 1;
        if (extra_index >= self.draft_extra_images.items.len) return;
        var image = self.draft_extra_images.orderedRemove(extra_index);
        image.deinit(allocator);
    }

    /// Apply a route choice. Existing durable threads never mutate in place;
    /// callers receive `new_thread_required` for a different selection.
    pub fn selectRuntimeRoute(
        self: *ChatThread,
        allocator: std.mem.Allocator,
        selection: thread_binding.Selection,
    ) !thread_binding.SelectResult {
        if (self.committed) self.runtime_route.lock();
        return self.runtime_route.select(allocator, selection);
    }

    /// Record the verified stable runtime at the first durable-action
    /// boundary. Repeating the same identity is safe; identity drift fails.
    pub fn pinRuntimeRoute(self: *ChatThread, allocator: std.mem.Allocator, runtime_id: []const u8) !void {
        try self.runtime_route.pin(allocator, runtime_id);
    }

    pub fn selectedRuntimeRoute(self: *const ChatThread) thread_binding.Selection {
        return self.runtime_route.selectedRoute();
    }

    pub fn pinnedRuntimeRoute(self: *const ChatThread) ?thread_binding.Pinned {
        return self.runtime_route.pinnedRoute();
    }

    /// Lock the current route at a durable-action boundary without inventing
    /// a runtime identity for migrated or legacy Local work.
    pub fn lockRuntimeRoute(self: *ChatThread) void {
        self.runtime_route.lock();
    }

    pub fn draftImageCount(self: *const ChatThread) usize {
        return (if (self.draft_image != null) @as(usize, 1) else 0) + self.draft_extra_images.items.len;
    }

    pub fn draftImageAt(self: *const ChatThread, index: usize) ?*const ChatImageAttachment {
        if (index == 0) return if (self.draft_image) |*image| image else null;
        const extra_index = index - 1;
        if (extra_index >= self.draft_extra_images.items.len) return null;
        return &self.draft_extra_images.items[extra_index];
    }

    pub fn commitFromPrompt(self: *ChatThread, allocator: std.mem.Allocator, prompt: []const u8) !void {
        self.committed = true;
        self.touch();
        const next_title = try chat_threads.makeThreadTitle(allocator, prompt);
        allocator.free(self.title);
        self.title = next_title;
    }

    pub fn touch(self: *ChatThread) void {
        self.last_activity_at = unixTimestampSeconds();
    }

    pub fn isSendPending(self: *const ChatThread) bool {
        self.send_state.mutex.lock();
        defer self.send_state.mutex.unlock();
        return self.send_state.status == .pending;
    }

    /// True while the async chat.turn.start acceptance receipt is still in
    /// flight for this thread's pending send (7.5). Composer editing,
    /// follow-up queueing, and steer/stop issuance defer on this so rejection
    /// rollback stays lossless and the staged prompt cannot be double-sent.
    pub fn isSendAcceptancePending(self: *const ChatThread) bool {
        self.send_state.mutex.lock();
        defer self.send_state.mutex.unlock();
        return self.send_state.status == .pending and self.send_state.acceptance_pending;
    }

    pub fn isSendPendingForUi(self: *const ChatThread) bool {
        if (!self.send_state.mutex.tryLock()) return true;
        defer self.send_state.mutex.unlock();
        return self.send_state.status == .pending;
    }

    /// Activity state consumed by provider-neutral pane chrome and the ACTIVE
    /// cluster. Approval requests and live background work are waiting, rather
    /// than generic working or a misleading completed state.
    pub fn activityStatusForUi(self: *const ChatThread) ChatActivityStatus {
        if (!self.send_state.mutex.tryLock()) return .working;
        defer self.send_state.mutex.unlock();
        if (self.send_state.status == .pending) {
            return if (self.send_state.pending_approval != null and self.send_state.approval_decision == null) .waiting else .working;
        }
        for (self.background_tasks.items) |task| {
            if (task.status == .running) return .waiting;
        }
        if (self.completion_pending) return .done;
        return if (self.send_state.status == .failed) .@"error" else .idle;
    }

    /// Unix ms when the in-flight send began, or null when no send is pending
    /// (or the worker holds the lock this frame — callers fall back to a
    /// time-less label rather than blocking the render thread).
    pub fn sendStartedAtMsForUi(self: *const ChatThread) ?i64 {
        if (!self.send_state.mutex.tryLock()) return null;
        defer self.send_state.mutex.unlock();
        if (self.send_state.status != .pending) return null;
        return self.send_state.started_at_ms;
    }

    pub fn finishSendThread(self: *ChatThread) void {
        self.send_state.mutex.lock();
        const maybe_worker = self.send_state.worker;
        self.send_state.worker = null;
        const status = self.send_state.status;
        const provider = self.provider;
        self.send_state.mutex.unlock();

        if (maybe_worker) |worker| {
            runtime_log.diagnostic("shutdown joining send thread provider={s} status={s}", .{ @tagName(provider), @tagName(status) });
            worker.join();
            runtime_log.diagnostic("shutdown joined send thread provider={s}", .{@tagName(provider)});
        }
    }

    pub fn finishTitleGenerationThread(self: *ChatThread) void {
        self.title_generation_state.mutex.lock();
        const maybe_worker = self.title_generation_state.worker;
        self.title_generation_state.worker = null;
        self.title_generation_state.mutex.unlock();
        if (maybe_worker) |worker| worker.join();
    }

    pub fn isTitleGenerationPendingForUi(self: *const ChatThread) bool {
        if (!self.title_generation_state.mutex.tryLock()) return true;
        defer self.title_generation_state.mutex.unlock();
        return self.title_generation_state.status == .pending;
    }

    pub fn discardPendingGeneratedTitle(self: *ChatThread) void {
        self.title_generation_state.mutex.lock();
        defer self.title_generation_state.mutex.unlock();
        self.title_generation_state.automatic_suppressed = true;
        switch (self.title_generation_state.status) {
            .pending, .completed => self.title_generation_state.discard_result = true,
            else => {},
        }
    }

    pub fn ensureTranscriptMarkdownEntries(self: *ChatThread, allocator: std.mem.Allocator) void {
        const message_count = self.messages.items.len;
        if (self.transcript_markdown_entries.items.len > message_count) {
            for (self.transcript_markdown_entries.items[message_count..]) |entry| {
                if (entry) |owned| owned.deinit(allocator);
            }
            self.transcript_markdown_entries.shrinkRetainingCapacity(message_count);
        } else if (self.transcript_markdown_entries.items.len < message_count) {
            self.transcript_markdown_entries.appendNTimes(allocator, null, message_count - self.transcript_markdown_entries.items.len) catch return;
        }
    }

    pub fn clearTranscriptMarkdownEntries(self: *ChatThread, allocator: std.mem.Allocator) void {
        for (self.transcript_markdown_entries.items) |entry| {
            if (entry) |owned| owned.deinit(allocator);
        }
        self.transcript_markdown_entries.clearRetainingCapacity();
    }

    pub fn ensureTranscriptHeightEntries(self: *ChatThread, allocator: std.mem.Allocator) void {
        const message_count = self.messages.items.len;
        if (self.transcript_height_entries.items.len > message_count) {
            self.transcript_height_entries.shrinkRetainingCapacity(message_count);
        } else if (self.transcript_height_entries.items.len < message_count) {
            self.transcript_height_entries.appendNTimes(allocator, .{}, message_count - self.transcript_height_entries.items.len) catch return;
        }
    }

    pub fn clearTranscriptHeightEntries(self: *ChatThread) void {
        self.transcript_height_entries.clearRetainingCapacity();
    }

    pub fn backgroundCommandFromEventBody(body_raw: []const u8) []const u8 {
        const body = std.mem.trim(u8, body_raw, "\n\r\t ");
        if (std.mem.find(u8, body, "\n\n")) |index| {
            return std.mem.trim(u8, body[0..index], "\n\r\t ");
        }
        return body;
    }

    pub fn isBackgroundCommandEvent(author: []const u8) bool {
        return std.mem.eql(u8, author, "Background command") or
            std.mem.eql(u8, author, "Backgrounded command");
    }

    pub fn isBackgroundTaskTerminalEvent(author: []const u8) bool {
        const status = backgroundTaskStatusForEvent(author) orelse return false;
        return status != .running;
    }

    pub fn backgroundCommandBodiesMatch(a_body: []const u8, b_body: []const u8) bool {
        const a_task_id = backgroundTaskMetadataValue(a_body, "Verde task ID:");
        const b_task_id = backgroundTaskMetadataValue(b_body, "Verde task ID:");
        if (a_task_id != null and b_task_id != null) return std.mem.eql(u8, a_task_id.?, b_task_id.?);

        const a_item_id = backgroundTaskMetadataValue(a_body, "Codex item ID:");
        const b_item_id = backgroundTaskMetadataValue(b_body, "Codex item ID:");
        const a_thread_id = backgroundTaskMetadataValue(a_body, "Provider thread ID:");
        const b_thread_id = backgroundTaskMetadataValue(b_body, "Provider thread ID:");
        if (a_item_id != null and b_item_id != null and a_thread_id != null and b_thread_id != null) {
            return std.mem.eql(u8, a_item_id.?, b_item_id.?) and std.mem.eql(u8, a_thread_id.?, b_thread_id.?);
        }

        const a_process_id = backgroundTaskMetadataValue(a_body, "Process ID:");
        const b_process_id = backgroundTaskMetadataValue(b_body, "Process ID:");
        if (a_item_id == null and b_item_id == null and a_process_id != null and b_process_id != null and
            a_thread_id != null and b_thread_id != null)
        {
            return std.mem.eql(u8, a_process_id.?, b_process_id.?) and std.mem.eql(u8, a_thread_id.?, b_thread_id.?);
        }

        if (a_task_id == null and b_task_id == null and a_item_id == null and b_item_id == null and
            a_process_id == null and b_process_id == null)
        {
            return std.mem.eql(u8, backgroundCommandFromEventBody(a_body), backgroundCommandFromEventBody(b_body));
        }
        return false;
    }

    pub fn backgroundTaskStatusForEvent(author: []const u8) ?BackgroundTaskStatus {
        if (isBackgroundCommandEvent(author)) return .running;
        if (std.mem.eql(u8, author, "Background task completed")) return .completed;
        if (std.mem.eql(u8, author, "Background task failed")) return .failed;
        if (std.mem.eql(u8, author, "Background task stopped")) return .stopped;
        return null;
    }

    pub fn backgroundTaskMetadataValue(body_raw: []const u8, label: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, body_raw, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, "\r\t ");
            if (!std.mem.startsWith(u8, line, label)) continue;
            return std.mem.trim(u8, line[label.len..], "\r\t ");
        }
        return null;
    }

    pub fn allocPrintZCompat(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
        const raw = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(raw);
        return try allocator.dupeZ(u8, raw);
    }

    pub fn backgroundTaskPidPathForId(allocator: std.mem.Allocator, task_id: []const u8) ![:0]const u8 {
        const temp_dir = try platform_paths.tempDir(allocator);
        defer allocator.free(temp_dir);
        const filename = try std.fmt.allocPrint(allocator, "verde-claude-bg-{s}.pid", .{task_id});
        defer allocator.free(filename);
        const joined = try std.fs.path.join(allocator, &.{ temp_dir, filename });
        defer allocator.free(joined);
        return try allocator.dupeZ(u8, joined);
    }

    pub fn replaceOptionalZ(
        allocator: std.mem.Allocator,
        slot: *?[:0]const u8,
        value: ?[]const u8,
    ) !void {
        const raw = value orelse return;
        if (raw.len == 0) return;
        if (slot.*) |existing| {
            if (std.mem.eql(u8, existing, raw)) return;
            allocator.free(existing);
        }
        slot.* = try allocator.dupeZ(u8, raw);
    }

    pub fn refreshBackgroundTaskMetadata(task: *BackgroundTask, allocator: std.mem.Allocator, body_raw: []const u8) !void {
        const explicit_pid_path = backgroundTaskMetadataValue(body_raw, "PID file:");
        if (backgroundTaskMetadataValue(body_raw, "Verde task ID:")) |task_id| {
            const previous_matches = task.task_id != null and std.mem.eql(u8, task.task_id.?, task_id);
            try replaceOptionalZ(allocator, &task.task_id, task_id);
            if (explicit_pid_path == null and (task.pid_path == null or !previous_matches)) {
                if (task.pid_path) |existing| allocator.free(existing);
                task.pid_path = try backgroundTaskPidPathForId(allocator, task_id);
            }
        }
        try replaceOptionalZ(allocator, &task.pid_path, explicit_pid_path);
        try replaceOptionalZ(allocator, &task.log_path, backgroundTaskMetadataValue(body_raw, "Output log:"));
        try replaceOptionalZ(allocator, &task.item_id, backgroundTaskMetadataValue(body_raw, "Codex item ID:"));
        try replaceOptionalZ(allocator, &task.process_id, backgroundTaskMetadataValue(body_raw, "Process ID:"));
        try replaceOptionalZ(allocator, &task.provider_thread_id, backgroundTaskMetadataValue(body_raw, "Provider thread ID:"));
        try replaceOptionalZ(allocator, &task.cwd, backgroundTaskMetadataValue(body_raw, "CWD:"));
        if (backgroundTaskMetadataValue(body_raw, "Provider:")) |value| {
            task.provider = std.meta.stringToEnum(Provider, value);
        }
    }

    pub fn noteBackgroundTaskEvent(self: *ChatThread, allocator: std.mem.Allocator, author: []const u8, body_raw: []const u8) !void {
        const status = backgroundTaskStatusForEvent(author) orelse return;
        const command = backgroundCommandFromEventBody(body_raw);
        if (command.len == 0) return;

        const task_id = backgroundTaskMetadataValue(body_raw, "Verde task ID:");
        const item_id = backgroundTaskMetadataValue(body_raw, "Codex item ID:");
        const process_id = backgroundTaskMetadataValue(body_raw, "Process ID:");
        const provider_thread_id = backgroundTaskMetadataValue(body_raw, "Provider thread ID:");
        var matched_terminal_task: ?*BackgroundTask = null;
        for (self.background_tasks.items) |*task| {
            const identity_matches = (task_id != null and task.task_id != null and std.mem.eql(u8, task.task_id.?, task_id.?)) or
                (item_id != null and task.item_id != null and provider_thread_id != null and task.provider_thread_id != null and
                    std.mem.eql(u8, task.item_id.?, item_id.?) and std.mem.eql(u8, task.provider_thread_id.?, provider_thread_id.?)) or
                (item_id == null and task.item_id == null and process_id != null and task.process_id != null and
                    provider_thread_id != null and task.provider_thread_id != null and std.mem.eql(u8, task.process_id.?, process_id.?) and
                    std.mem.eql(u8, task.provider_thread_id.?, provider_thread_id.?));
            const legacy_command_matches = task_id == null and item_id == null and process_id == null and task.task_id == null and task.item_id == null and
                task.process_id == null and std.mem.eql(u8, task.command, command);
            if (!identity_matches and !legacy_command_matches) continue;
            // Repeated anonymous commands have no provider identity. A
            // terminal event belongs to the first still-running match; using
            // an already-terminal match forever leaves its sibling waiting.
            if (status != .running and task.status != .running) {
                if (matched_terminal_task == null) matched_terminal_task = task;
                continue;
            }
            task.status = status;
            task.updated_at_ms = unixTimestampMs();
            try refreshBackgroundTaskMetadata(task, allocator, body_raw);
            return;
        }
        if (matched_terminal_task) |task| {
            task.status = status;
            task.updated_at_ms = unixTimestampMs();
            try refreshBackgroundTaskMetadata(task, allocator, body_raw);
            return;
        }

        var task: BackgroundTask = .{
            .command = try allocator.dupeZ(u8, command),
            .status = status,
            .started_at_ms = unixTimestampMs(),
            .updated_at_ms = unixTimestampMs(),
        };
        errdefer task.deinit(allocator);
        try refreshBackgroundTaskMetadata(&task, allocator, body_raw);
        try self.background_tasks.append(allocator, task);
    }

    pub fn rebuildBackgroundTasksFromMessages(self: *ChatThread, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| {
            if (message.role != .system) continue;
            self.noteBackgroundTaskEvent(allocator, message.author, message.body) catch |err| {
                log.warn("failed to restore background task metadata: {s}", .{@errorName(err)});
            };
            if (std.mem.eql(u8, message.author, "Conversation interrupted")) {
                _ = self.stopUnownedBackgroundTasks();
            }
        }
    }

    /// Claude's tracked commands are owned by the query that emitted them and
    /// intentionally have no detached PID or retained provider process id.
    /// Once that query ends, such a row cannot still be live.
    pub fn stopUnownedBackgroundTasks(self: *ChatThread) usize {
        var stopped: usize = 0;
        for (self.background_tasks.items) |*task| {
            if (task.status != .running or task.pid_path != null or task.process_id != null) continue;
            task.status = .stopped;
            task.updated_at_ms = unixTimestampMs();
            stopped += 1;
        }
        return stopped;
    }

    pub fn backgroundCommandIsRunning(self: *const ChatThread, body_raw: []const u8) bool {
        const command = backgroundCommandFromEventBody(body_raw);
        if (command.len == 0) return false;
        const task_id = backgroundTaskMetadataValue(body_raw, "Verde task ID:");
        const item_id = backgroundTaskMetadataValue(body_raw, "Codex item ID:");
        const process_id = backgroundTaskMetadataValue(body_raw, "Process ID:");
        for (self.background_tasks.items) |task| {
            if (task.status != .running) continue;
            if (task_id != null and task.task_id != null and std.mem.eql(u8, task_id.?, task.task_id.?)) return true;
            if (item_id != null and task.item_id != null and std.mem.eql(u8, item_id.?, task.item_id.?)) return true;
            if (process_id != null and task.process_id != null and std.mem.eql(u8, process_id.?, task.process_id.?)) return true;
            if (task_id == null and item_id == null and process_id == null and std.mem.eql(u8, task.command, command)) return true;
        }
        return false;
    }

    pub fn deinitSendState(self: *ChatThread, allocator: std.mem.Allocator) void {
        self.finishSendThread();
        if (self.send_state.result) |result| {
            std.heap.page_allocator.free(result.provider_thread_id);
            std.heap.page_allocator.free(result.reply_text);
            self.send_state.result = null;
        }
        if (self.send_state.error_message) |message| {
            std.heap.page_allocator.free(message);
            self.send_state.error_message = null;
        }
        if (self.send_state.control_error_message) |message| {
            std.heap.page_allocator.free(message);
            self.send_state.control_error_message = null;
        }
        if (self.send_state.provisional_provider_thread_id) |thread_id| {
            std.heap.page_allocator.free(thread_id);
            self.send_state.provisional_provider_thread_id = null;
        }
        if (self.send_state.active_turn_id) |turn_id| {
            std.heap.page_allocator.free(turn_id);
            self.send_state.active_turn_id = null;
        }
        if (self.send_state.daemon_turn_id) |turn_id| {
            std.heap.page_allocator.free(turn_id);
            self.send_state.daemon_turn_id = null;
        }
        // Steer/queue followups are captured on the main thread with the app
        // allocator (see storeDraftDuringSend), unlike the worker-owned
        // page_allocator fields around them; freeing them through
        // page_allocator panics on alignment.
        freePendingFollowup(allocator, &self.send_state.pending_followup);
        self.send_state.partial_text.deinit(std.heap.page_allocator);
        freePendingTimelineEvents(std.heap.page_allocator, &self.send_state.pending_events);
        freePendingDiffFiles(std.heap.page_allocator, &self.send_state.pending_diff_files);
        freePendingApproval(std.heap.page_allocator, &self.send_state.pending_approval);
        if (self.send_state.local_command_text) |value| std.heap.page_allocator.free(value);
        if (self.send_state.local_command_cwd) |value| std.heap.page_allocator.free(value);
        if (self.send_state.local_command_shell) |value| std.heap.page_allocator.free(value);
        allocator.destroy(self.send_state);
    }

    pub fn deinitTitleGenerationState(self: *ChatThread, allocator: std.mem.Allocator) void {
        self.finishTitleGenerationThread();
        if (self.title_generation_state.result) |result| std.heap.page_allocator.free(result);
        if (self.title_generation_state.error_message) |message| std.heap.page_allocator.free(message);
        allocator.destroy(self.title_generation_state);
    }

    pub fn deinit(self: *ChatThread, allocator: std.mem.Allocator) void {
        self.deinitSendState(allocator);
        self.deinitTitleGenerationState(allocator);
        if (self.pending_transcript_body) |entry| entry.deinit(allocator);
        self.pending_transcript_body = null;
        self.clearTranscriptMarkdownEntries(allocator);
        self.transcript_markdown_entries.deinit(allocator);
        self.transcript_height_entries.deinit(allocator);
        self.transcript_layout_items.deinit(allocator);
        allocator.free(self.title);
        allocator.free(self.local_thread_id);
        if (self.provider_thread_id) |thread_id| allocator.free(thread_id);
        if (self.model_ref) |model_ref| allocator.free(model_ref);
        if (self.opencode_reasoning_variant) |variant| allocator.free(variant);
        if (self.cwd) |cwd| allocator.free(cwd);
        self.runtime_route.deinit(allocator);
        for (self.messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
            if (message.tool_call_id) |call_id| allocator.free(call_id);
            if (message.message_id) |message_id| allocator.free(message_id);
            if (message.image) |*image| image.deinit(allocator);
            for (message.extra_images) |*image| image.deinit(allocator);
            allocator.free(message.extra_images);
        }
        self.messages.deinit(allocator);
        for (self.background_tasks.items) |task| task.deinit(allocator);
        self.background_tasks.deinit(allocator);
        self.clearDraftImage(allocator);
        self.draft_extra_images.deinit(allocator);
    }
};

pub const SendStatus = enum {
    idle,
    pending,
    completed,
    aborted,
    failed,
};

pub const ChatActivityStatus = enum {
    idle,
    working,
    waiting,
    done,
    @"error",
};
pub const FollowupKind = enum {
    queue,
    steer,
};
pub const FollowupState = enum {
    pending,
    sent_inline,
    fallback_next_turn,
};
pub const PendingFollowup = struct {
    kind: FollowupKind,
    state: FollowupState = .pending,
    prompt: []u8,
    images: std.ArrayList(ChatImageAttachment) = .empty,

    pub fn deinit(self: *PendingFollowup, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        for (self.images.items) |*image| image.deinit(allocator);
        self.images.deinit(allocator);
        self.* = undefined;
    }
};
pub const SendState = struct {
    mutex: Mutex = .{},
    condition: Condition = .{},
    status: SendStatus = .idle,
    started_at_ms: i64 = 0,
    result: ?SendResultPayload = null,
    error_message: ?[]u8 = null,
    /// Transient failure to transfer an approval/stop action to its owner.
    /// Kept separate from provider terminal failure state.
    control_error_message: ?[]u8 = null,
    provider: ?Provider = null,
    provisional_provider_thread_id: ?[]u8 = null,
    active_turn_id: ?[]u8 = null,
    daemon_turn_id: ?[]u8 = null,
    daemon_last_seq: u64 = 0,
    daemon_last_poll_ms: i64 = -1,
    /// Extra delay before the next chat.turn.tail poll, derived from the last
    /// round trip's measured cost. The tail RPC blocks the render thread, so
    /// a slow/overloaded daemon must not be re-polled 16ms later — that turns
    /// daemon latency into back-to-back frame stalls. Overwritten after every
    /// poll; 0 while the daemon answers fast.
    daemon_poll_backoff_ms: i64 = 0,
    daemon_owned: bool = false,
    /// True from submit until the async chat.turn.start acceptance receipt
    /// commits (M4-P3 semantics preserved off the event thread). While set:
    /// the draft stays in the composer, tail polling and steer/stop issuance
    /// are deferred, and follow-up queueing of the still-staged draft is
    /// blocked so acceptance cannot double-send the same prompt.
    acceptance_pending: bool = false,
    /// Consecutive chat.turn.tail failures while daemon-owned (Amendment-2 F5).
    /// Resets on a successful apply; thresholds to a visible failed send so the
    /// GUI does not spin forever after a mid-turn daemon crash/restart.
    daemon_tail_fail_count: u8 = 0,
    partial_text: std.ArrayListUnmanaged(u8) = .empty,
    /// Memoized measured height of the in-flight streamed assistant body.
    /// `partial_text` is append-only within a turn, so the paired key (length,
    /// width, variant, turn identity) fully discriminates. Guarded by `mutex`;
    /// avoids an O(stream-length) re-measure on every frame. -1 = unmeasured.
    stream_measured_height: f32 = -1.0,
    stream_measured_key: u64 = 0,
    /// True while the provider reports an active content-less reasoning item.
    /// Surfaced as "Thinking - mm:ss" in the pending stream header rather
    /// than as a transcript tool row.
    thinking: bool = false,
    pending_events: std.ArrayListUnmanaged(PendingTimelineEvent) = .empty,
    pending_diff_files: std.ArrayListUnmanaged(PendingDiffFile) = .empty,
    /// Once present, a cumulative turn snapshot owns the changed-files card;
    /// later per-edit lifecycle deltas must not replace it.
    pending_diff_has_turn_snapshot: bool = false,
    pending_approval: ?PendingApproval = null,
    ui_revision: u64 = 0,
    polled_ui_revision: u64 = 0,
    /// Whole-second elapsed value last reported to the UI poll loop for the
    /// pending "Working - mm:ss" label. Tracked so `pollSend` can request a
    /// repaint exactly when the visible seconds counter would change, even
    /// while the provider has not streamed any tokens. -1 means "no value
    /// reported yet" (so the very first pending poll always renders).
    polled_working_seconds: i64 = -1,
    pending_followup: ?PendingFollowup = null,
    pending_followup_signal_sent: bool = false,
    approval_decision: ?ai_harness.ApprovalDecision = null,
    stop_requested: bool = false,
    stop_signal_sent: bool = false,
    worker: ?std.Thread = null,
    /// Published only after the worker has finished all deferred cleanup.
    /// Terminal provider status can become visible before that cleanup ends;
    /// the SDL poll path must not join until this flag is set.
    worker_done: std.atomic.Value(bool) = .init(false),
    /// Local bang commands reuse the chat's single in-flight lane, but never
    /// enter an AI provider or acquire a provider thread id.
    local_command: bool = false,
    local_command_text: ?[]u8 = null,
    local_command_cwd: ?[]u8 = null,
    local_command_shell: ?[]u8 = null,
    active_local_child: ?*platform_process.OwnedChild = null,
};
pub const TitleGenerationStatus = enum {
    idle,
    pending,
    completed,
    failed,
};
pub const TitleGenerationState = struct {
    mutex: Mutex = .{},
    status: TitleGenerationStatus = .idle,
    result: ?[:0]const u8 = null,
    error_message: ?[]u8 = null,
    manual: bool = false,
    discard_result: bool = false,
    automatic_suppressed: bool = false,
    worker: ?std.Thread = null,
    /// Set after the title worker's provider teardown and request cleanup.
    worker_done: std.atomic.Value(bool) = .init(false),
};
pub const OpeningExchange = struct {
    user: *const ChatMessage,
    assistant: *const ChatMessage,
    user_message_count: usize,
};
pub const TitleGenerationRequest = struct {
    state: *TitleGenerationState,
    project_path: []u8,
    prompt: []u8,
    provider: ai_harness.Provider,
    model_ref: []u8,
};
pub const PendingApproval = struct {
    call_id: []u8,
    title: []u8,
    body: []u8,
};

/// Composer snapshots (queued follow-up pin, approval card) cached across
/// frames keyed on the owning send-state identity plus its ui_revision, so
/// steady-state rendering stops re-duplicating and freeing them every frame.
pub const PendingUiSnapshotCache = struct {
    followup_send_state: usize = 0,
    followup_revision: u64 = 0,
    followup_valid: bool = false,
    followup: ?PendingFollowup = null,
    approval_send_state: usize = 0,
    approval_revision: u64 = 0,
    approval_valid: bool = false,
    approval: ?PendingApproval = null,

    pub fn deinit(self: *PendingUiSnapshotCache, allocator: std.mem.Allocator) void {
        if (self.followup) |*followup| followup.deinit(allocator);
        if (self.approval) |*approval| {
            allocator.free(approval.call_id);
            allocator.free(approval.title);
            allocator.free(approval.body);
        }
        self.* = .{};
    }
};
pub const PendingDiffFile = struct {
    path: []u8,
    additions: i64,
    deletions: i64,
    patch: ?[]u8 = null,
    expanded: bool = false,
};
pub const PendingTimelineEvent = struct {
    role: ChatRole,
    author: []u8,
    body: []u8,
    /// GUI-authored timeline rows, such as an accepted provider steer, retain
    /// the attachments that were submitted alongside their text.
    images: std.ArrayList(ChatImageAttachment) = .empty,
    /// Daemon payload identity when the event carried one (`message` events);
    /// adopted into the projection row so the persistence flush keeps it.
    message_id: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_call_kind: ?ai_harness.ToolCallKind = null,
    tool_call_status: ?ai_harness.ToolCallStatus = null,
    tool_call_title: ?[]u8 = null,
    tool_call_input: ?[]u8 = null,
    tool_call_output: ?[]u8 = null,
    tool_call_error: ?[]u8 = null,
    tool_call_locations: ?[]u8 = null,
    tool_call_raw: ?[]u8 = null,
    /// Carries the card entrance across pending-to-committed promotion.
    transcript_card_started_ms: i64 = 0,
    /// Memoized measured transcript row height (whole-group height when this
    /// event opens a tool-call group), paired with the key that produced it.
    /// Long tool-heavy turns otherwise re-measure every pending body twice per
    /// frame, so frame cost scales with turn size. Guarded by SendState.mutex;
    /// written only by the chat panel's pending-stream walkers. -1 = unmeasured.
    measured_row_height: f32 = -1.0,
    measured_row_key: u64 = 0,

    pub fn deinit(self: *PendingTimelineEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.author);
        allocator.free(self.body);
        for (self.images.items) |*image| image.deinit(allocator);
        self.images.deinit(allocator);
        if (self.message_id) |value| allocator.free(value);
        if (self.tool_call_id) |value| allocator.free(value);
        if (self.tool_call_title) |value| allocator.free(value);
        if (self.tool_call_input) |value| allocator.free(value);
        if (self.tool_call_output) |value| allocator.free(value);
        if (self.tool_call_error) |value| allocator.free(value);
        if (self.tool_call_locations) |value| allocator.free(value);
        if (self.tool_call_raw) |value| allocator.free(value);
        self.* = undefined;
    }
};
pub const SendResultPayload = struct {
    provider_thread_id: []const u8,
    reply_text: []const u8,
};

pub fn freePendingFollowup(allocator: std.mem.Allocator, followup: *?PendingFollowup) void {
    if (followup.*) |*pending| {
        pending.deinit(allocator);
        followup.* = null;
    }
}

pub fn freePendingApproval(allocator: std.mem.Allocator, approval: *?PendingApproval) void {
    if (approval.*) |pending| {
        allocator.free(pending.call_id);
        allocator.free(pending.title);
        allocator.free(pending.body);
        approval.* = null;
    }
}

fn freePendingTimelineEvent(allocator: std.mem.Allocator, event: PendingTimelineEvent) void {
    var owned = event;
    owned.deinit(allocator);
}

fn freePendingTimelineEvents(allocator: std.mem.Allocator, events: *std.ArrayListUnmanaged(PendingTimelineEvent)) void {
    for (events.items) |event| freePendingTimelineEvent(allocator, event);
    events.deinit(allocator);
    events.* = .empty;
}

fn freePendingDiffFiles(allocator: std.mem.Allocator, files: *std.ArrayListUnmanaged(PendingDiffFile)) void {
    for (files.items) |file| {
        allocator.free(file.path);
        if (file.patch) |patch| allocator.free(patch);
    }
    files.deinit(allocator);
    files.* = .empty;
}

fn unixTimestampSeconds() i64 {
    return @divTrunc(unixTimestampMs(), std.time.ms_per_s);
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

test "chat activity distinguishes approval waiting from working" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Activity");
    defer thread.deinit(allocator);

    try std.testing.expectEqual(ChatActivityStatus.idle, thread.activityStatusForUi());
    thread.send_state.status = .pending;
    try std.testing.expectEqual(ChatActivityStatus.working, thread.activityStatusForUi());

    thread.send_state.pending_approval = .{
        .call_id = try std.heap.page_allocator.dupe(u8, "call-1"),
        .title = try std.heap.page_allocator.dupe(u8, "Approval"),
        .body = try std.heap.page_allocator.dupe(u8, "Run command?"),
    };
    try std.testing.expectEqual(ChatActivityStatus.waiting, thread.activityStatusForUi());
    freePendingApproval(std.heap.page_allocator, &thread.send_state.pending_approval);

    thread.send_state.status = .failed;
    try std.testing.expectEqual(ChatActivityStatus.@"error", thread.activityStatusForUi());
    thread.completion_pending = true;
    try std.testing.expectEqual(ChatActivityStatus.done, thread.activityStatusForUi());
}

test "chat activity waits for running background work" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Background activity");
    defer thread.deinit(allocator);
    try thread.background_tasks.append(allocator, .{
        .command = try allocator.dupeZ(u8, "background task"),
        .status = .running,
    });

    thread.completion_pending = true;
    try std.testing.expectEqual(ChatActivityStatus.waiting, thread.activityStatusForUi());

    thread.send_state.status = .pending;
    try std.testing.expectEqual(ChatActivityStatus.working, thread.activityStatusForUi());

    thread.send_state.status = .completed;
    thread.background_tasks.items[0].status = .completed;
    try std.testing.expectEqual(ChatActivityStatus.done, thread.activityStatusForUi());
}

test "interrupted transcript rebuild stops unowned background work" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Interrupted background");
    defer thread.deinit(allocator);
    try thread.messages.append(allocator, .{
        .role = .system,
        .author = try allocator.dupeZ(u8, "Background command"),
        .body = try allocator.dupeZ(u8, "wait forever"),
    });
    try thread.messages.append(allocator, .{
        .role = .system,
        .author = try allocator.dupeZ(u8, "Conversation interrupted"),
        .body = try allocator.dupeZ(u8, "Tell the model what to do differently."),
    });

    thread.rebuildBackgroundTasksFromMessages(allocator);

    try std.testing.expectEqual(@as(usize, 1), thread.background_tasks.items.len);
    try std.testing.expectEqual(BackgroundTaskStatus.stopped, thread.background_tasks.items[0].status);
    try std.testing.expectEqual(ChatActivityStatus.idle, thread.activityStatusForUi());
}

test "terminal events resolve repeated anonymous background commands in order" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Repeated background");
    defer thread.deinit(allocator);

    try thread.background_tasks.append(allocator, .{
        .command = try allocator.dupeZ(u8, "same command"),
        .status = .running,
    });
    try thread.background_tasks.append(allocator, .{
        .command = try allocator.dupeZ(u8, "same command"),
        .status = .running,
    });
    try thread.noteBackgroundTaskEvent(allocator, "Background task stopped", "same command");
    try thread.noteBackgroundTaskEvent(allocator, "Background task stopped", "same command");

    try std.testing.expectEqual(@as(usize, 2), thread.background_tasks.items.len);
    try std.testing.expectEqual(BackgroundTaskStatus.stopped, thread.background_tasks.items[0].status);
    try std.testing.expectEqual(BackgroundTaskStatus.stopped, thread.background_tasks.items[1].status);
}

test "background command events accept current and legacy labels" {
    try std.testing.expectEqual(BackgroundTaskStatus.running, ChatThread.backgroundTaskStatusForEvent("Background command").?);
    try std.testing.expectEqual(BackgroundTaskStatus.running, ChatThread.backgroundTaskStatusForEvent("Backgrounded command").?);
}
