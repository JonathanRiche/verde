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
    user,
    assistant,
    system,
};

pub const Provider = enum(u8) {
    opencode = 0,
    codex = 1,
    cursor = 2,
    claude = 3,
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
    tool_call_id: ?[]const u8 = null,
    tool_call_kind: ?ai_harness.ToolCallKind = null,
    tool_call_status: ?ai_harness.ToolCallStatus = null,
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
    draft: []const u8 = "",
    draft_image: ?PersistedImageAttachment = null,
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

    pub fn init(backing_allocator: std.mem.Allocator) LoadedState {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .value = .{},
        };
    }

    pub fn allocator(self: *LoadedState) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *LoadedState) void {
        self.arena.deinit();
    }
};
