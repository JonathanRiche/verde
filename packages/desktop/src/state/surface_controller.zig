//! Terminal surface registry ownership.

const std = @import("std");
const db_types = @import("../db/types.zig");
const notifier = @import("../app/notifier.zig");
const platform_runtime = @import("platform_runtime");
const terminal = @import("../terminal/terminal.zig");
const theme = @import("../ui/theme.zig");

const SurfaceProvider = db_types.SurfaceProvider;
const PersistedSurfaceState = db_types.PersistedSurfaceState;
const log = std.log.scoped(.native_shell);

pub const OPENCODE_LOGO_BYTES = @embedFile("../assets/opencode-logo-dark.png");
pub const CODEX_LOGO_BYTES = @embedFile("../assets/OpenAI-white-monoblossom.png");
pub const CLAUDE_LOGO_BYTES = @embedFile("../assets/claude-logo.png");
pub const CURSOR_LOGO_BYTES = @embedFile("../assets/editor_logos/cursor.png");

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

pub const SurfaceStatus = db_types.SurfaceStatus;

pub const SurfaceUpdate = struct {
    session_id: []const u8,
    workspace_id: ?[]const u8 = null,
    workspace_path: ?[]const u8 = null,
    dock_id: ?u32 = null,
    pane_id: ?u32 = null,
    provider: ?SurfaceProvider = null,
    provider_thread_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    status: ?SurfaceStatus = null,
    progress: ?f32 = null,
    attention: ?bool = null,
    unread_increment: u32 = 0,
    last_event_title: ?[]const u8 = null,
    last_event_body: ?[]const u8 = null,
    clear: bool = false,
};

pub const SurfaceState = struct {
    session_id: []u8,
    workspace_id: []u8 = "",
    workspace_path: []u8 = "",
    dock_id: u32 = 0,
    pane_id: ?u32 = null,
    provider: ?SurfaceProvider = null,
    provider_thread_id: ?[]u8 = null,
    title: []u8 = "",
    status: SurfaceStatus = .idle,
    status_changed_at_ms: i64 = 0,
    completion_pending: bool = false,
    completed_at_ms: i64 = 0,
    progress: ?f32 = null,
    attention: bool = false,
    unread_count: u32 = 0,
    last_event_title: ?[]u8 = null,
    last_event_body: ?[]u8 = null,
    last_event_at_ms: i64 = 0,

    pub fn displayStatus(self: *const SurfaceState) SurfaceStatus {
        return if (self.completion_pending) .done else self.status;
    }

    pub fn deinit(self: *SurfaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.workspace_id);
        allocator.free(self.workspace_path);
        allocator.free(self.title);
        if (self.provider_thread_id) |value| allocator.free(value);
        if (self.last_event_title) |value| allocator.free(value);
        if (self.last_event_body) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const State = struct {
    surfaces: std.ArrayList(SurfaceState) = .empty,
};

pub fn clearSurfaces(self: anytype) void {
    for (self.surface_controller.surfaces.items) |*surface| surface.deinit(self.allocator);
    self.surface_controller.surfaces.clearRetainingCapacity();
}

pub fn surfaceBySessionId(self: anytype, session_id: []const u8) ?*SurfaceState {
    for (self.surface_controller.surfaces.items) |*surface| {
        if (std.mem.eql(u8, surface.session_id, session_id)) return surface;
    }
    return null;
}

pub fn surfaceBySessionIdConst(self: anytype, session_id: []const u8) ?*const SurfaceState {
    for (self.surface_controller.surfaces.items) |*surface| {
        if (std.mem.eql(u8, surface.session_id, session_id)) return surface;
    }
    return null;
}

pub fn updateSurface(self: anytype, update: SurfaceUpdate) !*SurfaceState {
    var surface = self.surfaceBySessionId(update.session_id);
    if (surface == null) {
        try self.surface_controller.surfaces.append(self.allocator, .{
            .session_id = try self.allocator.dupe(u8, update.session_id),
            .workspace_id = try self.allocator.dupe(u8, update.workspace_id orelse ""),
            .workspace_path = try self.allocator.dupe(u8, update.workspace_path orelse ""),
            .dock_id = update.dock_id orelse 0,
            .pane_id = update.pane_id,
            .title = try self.allocator.dupe(u8, update.title orelse ""),
        });
        surface = &self.surface_controller.surfaces.items[self.surface_controller.surfaces.items.len - 1];
    }
    var s = surface.?;
    var completion_became_pending = false;
    if (update.workspace_id) |value| try replaceOwnedSlice(self.allocator, &s.workspace_id, value);
    if (update.workspace_path) |value| try replaceOwnedSlice(self.allocator, &s.workspace_path, value);
    if (update.dock_id) |value| s.dock_id = value;
    if (update.pane_id) |value| s.pane_id = value;
    if (update.provider) |value| {
        const dock = terminalDockForSurface(self, s);
        const pinned_provider = if (dock) |surface_dock| surface_dock.activeTabPinnedProvider() else null;
        if (!surfaceProviderClaimMatchesPin(value, pinned_provider)) {
            // Ignore the whole hook event: its status and title belong to the
            // nested agent too, not only its provider logo.
            log.debug("ignored {s} surface event for terminal pinned to {s}", .{ @tagName(value), pinned_provider.? });
            return s;
        }
        s.provider = value;
        // Pin the provider on the terminal tab so the sidebar can draw the
        // logo after a restart, before the agent process revives.
        if (dock) |surface_dock| {
            _ = surface_dock.setActiveTabPinnedProvider(self.allocator, @tagName(value));
        }
    }
    if (update.provider_thread_id) |value| try replaceOwnedOptionalSlice(self.allocator, &s.provider_thread_id, value);
    if (update.title) |value| {
        try replaceOwnedSlice(self.allocator, &s.title, value);
        // Pin the title on the terminal tab so it survives Codex's
        // folder-name OSC and remains available beyond the completion
        // ledger's acknowledgement lifetime.
        if (value.len > 0) {
            if (terminalDockForSurface(self, s)) |dock| {
                _ = dock.setActiveTabPinnedTitle(self.allocator, value);
                // Codex and Cursor provide titles on their prompt-submit
                // hooks, making this authoritative first-turn activity even
                // when the prompt was submitted without a local Enter event.
                if (s.provider != null) {
                    _ = dock.noteActiveTabAgentHistory(unixTimestampMs());
                }
            }
        }
    }
    if (update.clear) {
        _ = try self.storage.clearSurfaceState(s.session_id);
        if (s.status != .idle) s.status_changed_at_ms = unixTimestampMs();
        s.status = .idle;
        s.completion_pending = false;
        s.completed_at_ms = 0;
        s.progress = null;
        s.attention = false;
        s.unread_count = 0;
        try replaceOwnedOptionalSlice(self.allocator, &s.last_event_title, null);
        try replaceOwnedOptionalSlice(self.allocator, &s.last_event_body, null);
        _ = clearTerminalNotificationBySession(self, update.session_id);
    } else {
        if (update.status) |value| {
            const now_ms = unixTimestampMs();
            if (value != s.status) s.status_changed_at_ms = now_ms;
            s.status = value;
            if (value == .done and !s.completion_pending) {
                s.completion_pending = true;
                s.completed_at_ms = now_ms;
                completion_became_pending = true;
            } else if (value != .done) {
                // A new active/idle state supersedes any older completion.
                // Otherwise displayStatus() would keep showing Done while the
                // reattached TUI is already working again.
                s.completion_pending = false;
                s.completed_at_ms = 0;
            }
        }
        if (update.progress) |value| s.progress = theme.clampf(value, 0.0, 1.0);
        if (update.attention) |value| s.attention = value;
        if (update.unread_increment > 0) s.unread_count +|= update.unread_increment;
        if (update.last_event_title) |value| {
            try replaceOwnedOptionalSlice(self.allocator, &s.last_event_title, value);
            s.last_event_at_ms = unixTimestampMs();
        }
        if (update.last_event_body) |value| {
            try replaceOwnedOptionalSlice(self.allocator, &s.last_event_body, value);
            s.last_event_at_ms = unixTimestampMs();
        }
        if (s.status == .idle) {
            if (update.status != null) _ = try self.storage.clearSurfaceState(s.session_id);
        } else {
            // Every non-idle hook state is durable via the daemon store.
            try self.storage.upsertSurfaceState(persistedSurfaceState(s));
        }
    }
    // Notify on the completion edge. Runs on the main thread (live commands
    // are drained from the main loop), so spawning the notifier here is safe.
    if (!update.clear and self.app_config.notifications_enabled and completion_became_pending) {
        fireCompletionNotification(self, s);
    }
    self.markDirty();
    return s;
}

fn persistedSurfaceState(surface: *const SurfaceState) PersistedSurfaceState {
    return .{
        .session_id = surface.session_id,
        .workspace_id = surface.workspace_id,
        .workspace_path = surface.workspace_path,
        .dock_id = surface.dock_id,
        .pane_id = surface.pane_id,
        .provider = surface.provider,
        .provider_thread_id = surface.provider_thread_id,
        .title = surface.title,
        .status = surface.status,
        .status_changed_at_ms = surface.status_changed_at_ms,
        .completed_at_ms = surface.completed_at_ms,
        .last_event_title = surface.last_event_title,
        .last_event_body = surface.last_event_body,
    };
}

// Resolves the terminal dock that owns a surface (by workspace + dock id),
// so notify-provided metadata can be pinned onto its tab. Pinned tab metadata
// and the latest non-idle surface state persist independently across restarts.
fn terminalDockForSurface(self: anytype, surface: *const SurfaceState) ?*terminal.Dock {
    for (self.project_controller.projects.items, 0..) |*project, idx| {
        const owns = std.mem.eql(u8, surface.workspace_id, project.id) or
            self.projectPathMatches(surface.workspace_path, project.path);
        if (!owns) continue;
        return self.projectTerminalDockMutable(idx, surface.dock_id);
    }
    return null;
}

// Provider hooks inherit terminal environment variables into child commands.
// A nested agent must not claim the parent agent's explicitly pinned surface.
fn surfaceProviderClaimMatchesPin(provider: SurfaceProvider, pinned_provider: ?[]const u8) bool {
    const pinned = pinned_provider orelse return true;
    return std.mem.eql(u8, pinned, @tagName(provider));
}

// Resolves which agent provider a surface belongs to, for the notification
// logo/title. Only trust explicit notify metadata: falling back to a
// workspace chat provider can mislabel one terminal agent as another (for
// example an Amp pane in a workspace whose first saved chat is Codex).
fn resolveSurfaceProvider(self: anytype, surface: *const SurfaceState) ?SurfaceProvider {
    _ = self;
    if (surface.provider) |p| return p;
    return null;
}

// Builds a human-readable title/body from the surface and hands off to the
// cross-platform notifier. Title prefers the surface's own label, then the
// provider name; the body names the workspace directory so multiple agents
// stay distinguishable. The provider also selects the notification logo.
fn fireCompletionNotification(self: anytype, surface: *const SurfaceState) void {
    const provider = resolveSurfaceProvider(self, surface);
    const dir = if (surface.workspace_path.len > 0)
        std.fs.path.basename(surface.workspace_path)
    else
        "";

    var title_buf: [128]u8 = undefined;
    const title = if (surface.title.len > 0)
        surface.title
    else if (provider) |p|
        (std.fmt.bufPrint(&title_buf, "{s} finished", .{surfaceProviderLabel(p)}) catch "Agent finished")
    else
        "Agent finished";

    var body_buf: [256]u8 = undefined;
    const body = if (dir.len > 0)
        (std.fmt.bufPrint(&body_buf, "Completed in {s}", .{dir}) catch "Task completed")
    else
        "Task completed";

    const icon: ?notifier.Icon = if (provider) |p| switch (p) {
        .codex => .{ .key = "codex", .png_bytes = CODEX_LOGO_BYTES },
        .opencode => .{ .key = "opencode", .png_bytes = OPENCODE_LOGO_BYTES },
        .claude => .{ .key = "claude", .png_bytes = CLAUDE_LOGO_BYTES },
        .cursor => .{ .key = "cursor", .png_bytes = CURSOR_LOGO_BYTES },
        .grok, .amp => null,
    } else null;

    notifier.notifyAgentDone(self.allocator, title, body, icon);
}

fn surfaceProviderLabel(provider: SurfaceProvider) []const u8 {
    return switch (provider) {
        .opencode => "OpenCode",
        .codex => "Codex",
        .cursor => "Cursor",
        .claude => "Claude",
        .grok => "Grok",
        .amp => "Amp",
    };
}

pub fn clearSurfaceAttentionBySession(self: anytype, session_id: []const u8) bool {
    for (self.surface_controller.surfaces.items, 0..) |*surface, index| {
        if (std.mem.eql(u8, surface.session_id, session_id)) {
            return clearSurfaceAttentionAtIndex(self, index);
        }
    }
    return clearTerminalNotificationBySession(self, session_id);
}

pub fn clearSurfaceAttentionForDock(self: anytype, project_index: usize, dock_id: u32) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    var changed = false;
    var surface_index: usize = 0;
    while (surface_index < self.surface_controller.surfaces.items.len) : (surface_index += 1) {
        const surface = &self.surface_controller.surfaces.items[surface_index];
        if (surface.dock_id != dock_id or !surfaceBelongsToProject(self, surface, project_index)) continue;
        if (clearSurfaceAttentionAtIndex(self, surface_index)) changed = true;
    }
    return changed;
}

fn clearSurfaceAttentionAtIndex(self: anytype, surface_index: usize) bool {
    if (surface_index >= self.surface_controller.surfaces.items.len) return false;
    const terminal_changed = clearTerminalNotificationBySession(self, self.surface_controller.surfaces.items[surface_index].session_id);
    const surface = &self.surface_controller.surfaces.items[surface_index];
    // Focusing the pane acknowledges a finished turn, so clear the "done"
    // indicator — it shouldn't re-appear in the sidebar once you've come
    // back and looked. Genuine waiting/error states persist (you still need
    // to act on them).
    const done_ack = surface.completion_pending or surface.status == .done;
    if (!surface.attention and surface.unread_count == 0 and !done_ack) return terminal_changed;
    if (done_ack and !self.queueSurfaceAcknowledgement(surface)) return terminal_changed;
    surface.attention = false;
    surface.unread_count = 0;
    if (done_ack) {
        surface.completion_pending = false;
        surface.completed_at_ms = 0;
        if (surface.status == .done) surface.status = .idle;
    }
    // A completed surface is durably removed by the queued targeted clear.
    // Attention-only changes still need the compatibility snapshot path.
    if (!done_ack) self.markDirty();
    return true;
}

fn surfaceBelongsToProject(self: anytype, surface: *const SurfaceState, project_index: usize) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[project_index];
    return std.mem.eql(u8, surface.workspace_id, project.id) or
        self.projectPathMatches(surface.workspace_path, project.path);
}

fn clearTerminalNotificationBySession(self: anytype, session_id: []const u8) bool {
    var changed = false;
    for (self.project_controller.projects.items) |*project| {
        if (project.terminal_dock.clearNotificationForSession(session_id)) changed = true;
        for (project.terminal_docks.items) |*entry| {
            if (entry.dock.clearNotificationForSession(session_id)) changed = true;
        }
    }
    return changed;
}

pub fn terminalDockSurfaceAttention(self: anytype, project_index: usize, dock_id: u32) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    const surface = self.projectTerminalSurface(project_index, dock_id) orelse return false;
    return surface.completion_pending or surface.attention or surface.unread_count > 0 or surface.status == .waiting or surface.status == .@"error";
}

/// True when (project_index, dock_id) is the terminal pane the user is
/// currently focused in — used to suppress its own sidebar status/attention
/// indicators (you're already looking at it).
pub fn isFocusedTerminalSurface(self: anytype, project_index: usize, dock_id: u32) bool {
    if (!self.terminal_controller.focused) return false;
    if (project_index != self.project_controller.selected_index) return false;
    if (project_index >= self.project_controller.projects.items.len) return false;
    const layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const pane_id = layout.focused_pane_id orelse return false;
    const pane = layout.paneById(pane_id) orelse return false;
    return switch (pane.ref) {
        .terminal => |ref| ref.dock_id == dock_id,
        else => false,
    };
}

/// Returns the terminal surface (if any) bound to a given dock within a
/// workspace, so the sidebar can render per-pane agent status.
pub fn projectTerminalSurface(self: anytype, project_index: usize, dock_id: u32) ?*const SurfaceState {
    if (project_index >= self.project_controller.projects.items.len) return null;
    const project = &self.project_controller.projects.items[project_index];
    const active_session_id = if (self.projectTerminalDock(project_index, dock_id)) |dock| dock.activeSessionId() else null;
    var fallback: ?*const SurfaceState = null;
    for (self.surface_controller.surfaces.items) |*surface| {
        if (surface.dock_id != dock_id) continue;
        if (std.mem.eql(u8, surface.workspace_id, project.id) or self.projectPathMatches(surface.workspace_path, project.path)) {
            if (surface.completion_pending) return surface;
            if (active_session_id) |session_id| {
                if (std.mem.eql(u8, surface.session_id, session_id)) return surface;
            }
            fallback = surface;
        }
    }
    return fallback;
}

fn replaceOwnedSlice(allocator: std.mem.Allocator, dest: *[]u8, value: []const u8) !void {
    const next = try allocator.dupe(u8, value);
    allocator.free(dest.*);
    dest.* = next;
}

fn replaceOwnedOptionalSlice(allocator: std.mem.Allocator, dest: *?[]u8, value: ?[]const u8) !void {
    const next = if (value) |v| try allocator.dupe(u8, v) else null;
    if (dest.*) |old| allocator.free(old);
    dest.* = next;
}

test "nested provider cannot claim a terminal pinned to another agent" {
    try std.testing.expect(surfaceProviderClaimMatchesPin(.cursor, null));
    try std.testing.expect(surfaceProviderClaimMatchesPin(.cursor, "cursor"));
    try std.testing.expect(!surfaceProviderClaimMatchesPin(.cursor, "amp"));
}

test "surface focus clear queues persistence and updates local state immediately" {
    const project_state = @import("project.zig");
    const FakeState = struct {
        allocator: std.mem.Allocator,
        surface_controller: State = .{},
        project_controller: struct {
            projects: std.ArrayList(project_state.Project) = .empty,
        } = .{},
        queued: bool = false,
        dirty: bool = false,

        fn queueSurfaceAcknowledgement(self: *@This(), surface: *const SurfaceState) bool {
            self.queued = std.mem.eql(u8, surface.session_id, "session-a");
            return true;
        }

        fn markDirty(self: *@This()) void {
            self.dirty = true;
        }
    };

    var state: FakeState = .{ .allocator = std.testing.allocator };
    defer state.project_controller.projects.deinit(state.allocator);
    try state.surface_controller.surfaces.append(state.allocator, .{
        .session_id = try state.allocator.dupe(u8, "session-a"),
        .workspace_id = try state.allocator.dupe(u8, "workspace-a"),
        .workspace_path = try state.allocator.dupe(u8, "/workspace-a"),
        .title = try state.allocator.dupe(u8, "Done"),
        .status = .done,
        .completion_pending = true,
        .completed_at_ms = 42,
        .attention = true,
        .unread_count = 3,
    });
    defer {
        for (state.surface_controller.surfaces.items) |*surface| surface.deinit(state.allocator);
        state.surface_controller.surfaces.deinit(state.allocator);
    }

    try std.testing.expect(clearSurfaceAttentionBySession(&state, "session-a"));
    const surface = &state.surface_controller.surfaces.items[0];
    try std.testing.expect(state.queued);
    try std.testing.expect(!state.dirty);
    try std.testing.expectEqual(SurfaceStatus.idle, surface.status);
    try std.testing.expect(!surface.completion_pending);
    try std.testing.expect(!surface.attention);
    try std.testing.expectEqual(@as(u32, 0), surface.unread_count);
}
