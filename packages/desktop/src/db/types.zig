//! Shared storage types for SQLite-backed app persistence.

const std = @import("std");
const ai_harness = @import("../harness.zig");

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

pub const Harness = enum(u8) {
    local_cli,
    remote_session,
};

pub const PersistedImageAttachment = struct {
    path: []const u8,
    mime: []const u8,
    byte_size: usize = 0,
};

pub const PersistedMessage = struct {
    role: ChatRole,
    author: []const u8,
    body: []const u8,
    image: ?PersistedImageAttachment = null,
};

pub const PersistedThread = struct {
    title: []const u8,
    archived: bool = false,
    committed: bool = true,
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
