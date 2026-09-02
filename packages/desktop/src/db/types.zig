//! Shared storage types for SQLite-backed app persistence.

const std = @import("std");
const ai_harness = @import("../providers/harness.zig");

pub const ReasoningEffort = ai_harness.ReasoningEffort;

pub const FastMode = enum(u8) {
    off,
    on,
};

pub const AccessMode = enum(u8) {
    full_access,
    supervised,
};

pub const ChatRole = enum(u8) {
    user = 0,
    assistant = 1,
    system = 2,
};

/// Decodes canonical role integers while repairing rows written by historical
/// codecs. Production stores contain all three integer orderings without codec
/// provenance, so stable Verde authors are the only common discriminator.
pub fn decodeStoredChatRole(raw: i64, author_raw: []const u8) ChatRole {
    const author = std.mem.trim(u8, author_raw, "\n\r\t ");
    if (storedUserAuthor(author)) return .user;
    if (storedAssistantAuthor(author)) return .assistant;

    // Every persisted Verde event/card title is a system author. Prefer that
    // stable contract over an ambiguous integer; only authorless corrupt or
    // third-party rows fall back to the current canonical codec.
    if (author.len > 0) return .system;

    return switch (raw) {
        0 => .user,
        1 => .assistant,
        2 => .system,
        else => .user,
    };
}

fn storedUserAuthor(author: []const u8) bool {
    return std.ascii.eqlIgnoreCase(author, "You") or
        std.ascii.eqlIgnoreCase(author, "User");
}

fn storedAssistantAuthor(author: []const u8) bool {
    // Every provider label emitted by transcript_apply.providerLabel must be
    // listed here, or the daemon decodes its assistant rows as system rows and
    // GUI identity adoption never matches the streamed reply.
    inline for (.{ "Assistant", "Agent", "OpenCode", "Codex", "Claude", "Cursor", "Pi", "FX", "Grok", "Sprout", "Moss", "Vireo" }) |known| {
        if (std.ascii.eqlIgnoreCase(author, known)) return true;
    }
    return false;
}

test "mixed stored chat role codecs retain semantic roles" {
    const Case = struct {
        raw: i64,
        author: []const u8,
        expected: ChatRole,
    };
    const cases = [_]Case{
        // Canonical SQLite rows.
        .{ .raw = 0, .author = "You", .expected = .user },
        .{ .raw = 0, .author = "user", .expected = .user },
        .{ .raw = 1, .author = "Assistant", .expected = .assistant },
        .{ .raw = 1, .author = "Codex", .expected = .assistant },
        .{ .raw = 2, .author = "System", .expected = .system },
        .{ .raw = 2, .author = "Ran command", .expected = .system },
        // Historical daemon rows.
        .{ .raw = 0, .author = "Ran command", .expected = .system },
        .{ .raw = 0, .author = "Changed files", .expected = .system },
        .{ .raw = 1, .author = "You", .expected = .user },
        .{ .raw = 2, .author = "OpenCode", .expected = .assistant },
        .{ .raw = 2, .author = "Codex", .expected = .assistant },
        .{ .raw = 2, .author = "Claude", .expected = .assistant },
        .{ .raw = 2, .author = "Cursor", .expected = .assistant },
        .{ .raw = 2, .author = "Pi", .expected = .assistant },
        .{ .raw = 2, .author = "FX", .expected = .assistant },
        .{ .raw = 2, .author = "Grok", .expected = .assistant },
        .{ .raw = 2, .author = "Sprout", .expected = .assistant },
        // Older desktop projections used assistant=0, system=1, user=2.
        .{ .raw = 0, .author = "Codex", .expected = .assistant },
        .{ .raw = 1, .author = "MCP tool", .expected = .system },
        .{ .raw = 2, .author = "You", .expected = .user },
        // Non-Verde authors cannot be decoded from an ambiguous integer. They
        // degrade to system rows instead of rendering as user/assistant prose.
        .{ .raw = 0, .author = "Custom", .expected = .system },
        .{ .raw = 1, .author = "Custom", .expected = .system },
        .{ .raw = 2, .author = "Custom", .expected = .system },
        // Authorless rows retain deterministic canonical fallback behavior.
        .{ .raw = 0, .author = "", .expected = .user },
        .{ .raw = 1, .author = "", .expected = .assistant },
        .{ .raw = 2, .author = "", .expected = .system },
        .{ .raw = 99, .author = "", .expected = .user },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, decodeStoredChatRole(case.raw, case.author));
    }
}

pub const Provider = enum(u8) {
    opencode = 0,
    codex = 1,
    cursor = 2,
    claude = 3,
    pi = 4,
    fx = 5,
    grok = 6,
};

/// Provider identity attached to terminal surface activity. This stays
/// separate from `Provider`, whose values represent implemented GUI harnesses.
pub const SurfaceProvider = enum(u8) {
    opencode = 0,
    codex = 1,
    cursor = 2,
    claude = 3,
    grok = 4,
    amp = 5,
    pi = 6,
    fx = 7,
};

pub const SurfaceStatus = enum(u8) {
    idle,
    working,
    waiting,
    done,
    @"error",
};

pub const Harness = enum(u8) {
    local_cli,
    remote_session,
};

pub const PersistedImageAttachment = struct {
    path: []const u8,
    mime: []const u8,
    byte_size: usize = 0,
};

pub const PersistedHerdrWorkspaceLink = struct {
    remote_alias: []const u8 = "",
    session_name: []const u8,
    workspace_id: []const u8,
    local_dir: []const u8,
    remote_cwd: ?[]const u8 = null,
    last_pane_id: ?[]const u8 = null,
    attach_dock_id: ?u32 = null,
    attach_pane_id: ?u32 = null,
    pane_links_json: ?[]const u8 = null,
    updated_at_ms: i64 = 0,
};

pub const PersistedSurfaceState = struct {
    session_id: []const u8,
    workspace_id: []const u8 = "",
    workspace_path: []const u8 = "",
    dock_id: u32 = 0,
    pane_id: ?u32 = null,
    provider: ?SurfaceProvider = null,
    provider_thread_id: ?[]const u8 = null,
    title: []const u8 = "",
    status: SurfaceStatus,
    status_changed_at_ms: i64,
    completed_at_ms: i64 = 0,
    last_event_title: ?[]const u8 = null,
    last_event_body: ?[]const u8 = null,
};

pub const PersistedChatCompletion = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    completed_at_ms: i64,
};

pub const PersistedMessage = struct {
    role: ChatRole,
    author: []const u8,
    body: []const u8,
    image: ?PersistedImageAttachment = null,
    /// Attachments past the primary `image`. Additive (defaults empty) so
    /// legacy persisted states without the field decode cleanly.
    extra_images: []const PersistedImageAttachment = &.{},
    tool_call_id: ?[]const u8 = null,
    tool_call_kind: ?ai_harness.ToolCallKind = null,
    tool_call_status: ?ai_harness.ToolCallStatus = null,
    /// Durable transcript identity (M4-P4). Daemon-minted (`turn:{id}:msg:{n}`)
    /// or client-minted (`gui-msg:...`) ids ride the snapshot verbatim so the
    /// GUI flush never re-mints identities positionally. Null on legacy rows
    /// (old persisted JSON/DB states decode with the default).
    message_id: ?[]const u8 = null,
};

pub const PersistedThread = struct {
    title: []const u8,
    archived: bool = false,
    committed: bool = true,
    local_thread_id: ?[]const u8 = null,
    last_activity_at: ?i64 = null,
    provider_thread_id: ?[]const u8 = null,
    model_ref: ?[]const u8 = null,
    reasoning_effort: ?ReasoningEffort = null,
    /// OpenCode JSON `variant` string when the model exposes variant keys (distinct from Codex `reasoning_effort`).
    reasoning_variant: ?[]const u8 = null,
    fast_mode: ?FastMode = null,
    access_mode: ?AccessMode = null,
    provider: Provider = .opencode,
    harness: Harness = .local_cli,
    tui_dock_id: ?u32 = null,
    /// Per-thread working-directory override; null follows the workspace path.
    cwd: ?[]const u8 = null,
    /// Connection profile selected for this thread. Null is a legacy Local
    /// profile, preserving old persisted JSON without a migration rewrite.
    profile_id: ?[]const u8 = null,
    /// Stable verified daemon identity. Null means it has not yet been learned
    /// (including committed local threads created by older builds).
    runtime_id: ?[]const u8 = null,
    /// Workspace-scoped repository identity. Null is the legacy `primary`.
    repository_id: ?[]const u8 = null,
    /// Runtime-independent path beneath the selected repository root.
    repository_cwd: ?[]const u8 = null,
    draft: []const u8 = "",
    draft_image: ?PersistedImageAttachment = null,
    /// Composer attachments past the primary `draft_image`. Additive
    /// (defaults empty) so legacy persisted states decode cleanly.
    draft_extra_images: []const PersistedImageAttachment = &.{},
    /// Durable sort-index boundary before the bounded `messages` tail.
    message_offset: usize = 0,
    messages: []const PersistedMessage = &.{},
};

pub const PersistedProject = struct {
    id: ?[]const u8 = null,
    label: []const u8,
    path: []const u8,
    archived: bool = false,
    unread_count: u8 = 0,
    collapsed: ?bool = null,
    thread_list_expanded: ?bool = null,
    terminal_height: ?f32 = null,
    terminal_layout_json: ?[]const u8 = null,
    terminal_docks_json: ?[]const u8 = null,
    workspace_layout_json: ?[]const u8 = null,
    selected_thread_index: usize = 0,
    companion_thread_local_id: ?[]const u8 = null,
    herdr_link: ?PersistedHerdrWorkspaceLink = null,
    threads: ?[]const PersistedThread = null,
    provider: Provider = .opencode,
    harness: Harness = .local_cli,
    draft: []const u8 = "",
    messages: []const PersistedMessage = &.{},
};

pub const PersistedState = struct {
    selected_project_index: usize = 0,
    sidebar_collapsed: bool = false,
    projects: []const PersistedProject = &.{},
    surface_states: []const PersistedSurfaceState = &.{},
    chat_completions: []const PersistedChatCompletion = &.{},
    provider: ?Provider = null,
    harness: ?Harness = null,
    draft: ?[]const u8 = null,
    messages: ?[]const PersistedMessage = null,
};

pub const LoadedState = struct {
    arena: std.heap.ArenaAllocator,
    value: PersistedState = .{},
    /// Durable store revision observed inside the same RO load transaction
    /// (0 when store_state is absent, e.g. pre-v2 schemas).
    store_revision: u64 = 0,

    pub fn init(backing_allocator: std.mem.Allocator) LoadedState {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .value = .{},
            .store_revision = 0,
        };
    }

    pub fn allocator(self: *LoadedState) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *LoadedState) void {
        self.arena.deinit();
    }
};

pub const LoadedMessagePage = struct {
    arena: std.heap.ArenaAllocator,
    offset: usize,
    messages: []const PersistedMessage,

    pub fn deinit(self: *LoadedMessagePage) void {
        self.arena.deinit();
    }
};
