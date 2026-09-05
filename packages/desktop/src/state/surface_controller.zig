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
pub const GROK_LOGO_BYTES = @embedFile("../assets/grok-logo.png");
pub const AMP_LOGO_BYTES = @embedFile("../assets/amp-logo.png");
pub const PI_LOGO_BYTES = @embedFile("../assets/pi-logo.png");
pub const FX_LOGO_BYTES = @embedFile("../assets/fx-logo.png");
pub const MUSE_LOGO_BYTES = @embedFile("../assets/muse-logo.png");

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

pub const SurfaceStatus = db_types.SurfaceStatus;

pub const SurfaceDurability = enum {
    durable,
    presentation_only,
};

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
    status_changed_at_ms: ?i64 = null,
    completed_at_ms: ?i64 = null,
    /// Only the Live server may select presentation_only, after validating an
    /// exact durable daemon receipt for this mutation.
    durability: SurfaceDurability = .durable,
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
    presentation_generation: u64 = 0,

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
    const previous_status = s.status;
    var status_changed = false;
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
            // FX already maintains a native session/workspace OSC title. Its
            // lifecycle bridge must not pin the generic process label over it.
            if (value == .fx and (update.title == null or update.title.?.len == 0)) {
                try replaceOwnedSlice(self.allocator, &s.title, "");
                _ = surface_dock.clearActiveTabPinnedTitle(self.allocator);
            }
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
                const title_changed = dock.setActiveTabPinnedTitle(self.allocator, value);
                // Provider hooks/plugins can supply authoritative first-turn
                // titles even when submission did not use a local Enter event.
                if (s.provider != null and (title_changed or dock.activeTabAgentHistoryAt() == 0 or
                    (update.status == .working and previous_status != .working)))
                {
                    _ = dock.noteActiveTabAgentHistory(unixTimestampMs());
                }
            }
        }
    }
    s.presentation_generation +%= 1;
    if (update.clear) {
        if (update.durability == .durable) _ = try self.storage.clearSurfaceState(s.session_id);
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
            const now_ms = update.status_changed_at_ms orelse unixTimestampMs();
            if (value != s.status) {
                s.status_changed_at_ms = now_ms;
                status_changed = true;
            }
            s.status = value;
            if (value == .done and !s.completion_pending) {
                s.completion_pending = true;
                s.completed_at_ms = update.completed_at_ms orelse now_ms;
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
            if (update.status != null and update.durability == .durable) _ = try self.storage.clearSurfaceState(s.session_id);
        } else {
            // Every non-idle hook state is durable via the daemon store.
            if (update.durability == .durable) try self.storage.upsertSurfaceState(persistedSurfaceState(s));
        }
    }
    // A completion that arrives while its pane already owns focus has no
    // later focus edge to acknowledge it. Clear it immediately, matching the
    // focused in-app chat completion path.
    if (!update.clear and completion_became_pending and surfaceIsFocused(self, s)) {
        if (clearSurfaceAttentionBySession(self, s.session_id)) completion_became_pending = false;
    }
    // Notify on status edges. Runs on the main thread (live commands are
    // drained from the main loop), so spawning the notifier here is safe.
    if (!update.clear and self.app_config.notifications_enabled) {
        if (completion_became_pending and terminalSurfaceDisplayStatus(self, s) == .done) {
            fireStatusNotification(self, s, .done);
        } else if (status_changed) {
            switch (s.status) {
                .waiting => if (previous_status != .waiting) fireStatusNotification(self, s, .waiting),
                .@"error" => if (previous_status != .@"error") fireStatusNotification(self, s, .@"error"),
                else => {},
            }
        }
    }
    self.markDirty();
    return s;
}

/// Acknowledge a viewed completion even if its event preceded focus or replay.
/// This is level-triggered; waiting/background work is never acknowledged.
pub fn acknowledgeFocusedTerminalCompletion(self: anytype) bool {
    var changed = false;
    for (self.surface_controller.surfaces.items, 0..) |*surface, index| {
        if (surfaceReturnedToShell(self, surface)) {
            if (retireExitedAgentSurface(self, surface)) changed = true;
            continue;
        }
        if (!surfaceIsFocused(self, surface)) continue;
        if (terminalSurfaceDisplayStatus(self, surface) == .done and clearSurfaceAttentionAtIndex(self, index)) changed = true;
    }
    return changed;
}

fn surfaceReturnedToShell(self: anytype, surface: *const SurfaceState) bool {
    for (self.project_controller.projects.items, 0..) |_, index| {
        if (!surfaceBelongsToProject(self, surface, index)) continue;
        const dock = self.projectTerminalDock(index, surface.dock_id) orelse return false;
        const session_id = dock.activeSessionId() orelse return false;
        return std.mem.eql(u8, session_id, surface.session_id) and dock.activeSessionAtShellPrompt(surface.status_changed_at_ms);
    }
    return false;
}

fn retireExitedAgentSurface(self: anytype, surface: *SurfaceState) bool {
    if (surface.status == .idle and !surface.completion_pending and
        !surface.attention and surface.unread_count == 0 and surface.progress == null) return false;
    if (!self.queueSurfaceAcknowledgement(surface)) return false;
    _ = clearTerminalNotificationBySession(self, surface.session_id);
    surface.status = .idle;
    surface.completion_pending = false;
    surface.completed_at_ms = 0;
    surface.progress = null;
    surface.attention = false;
    surface.unread_count = 0;
    surface.presentation_generation +%= 1;
    return true;
}

/// Fires notifications for completion edges first observed through the daemon
/// projection. Native reporters such as FX write directly to the daemon store
/// and therefore do not pass through `notification.update` in the live IPC
/// server, where hook-backed providers normally trigger the notifier.
pub fn notifyProjectedCompletionEdges(self: anytype, previous: *const State) void {
    for (self.surface_controller.surfaces.items, 0..) |*surface, surface_index| {
        if (projectedCompletionBecamePending(previous, surface) and terminalSurfaceDisplayStatus(self, surface) == .done) {
            if (surfaceIsFocused(self, surface) and clearSurfaceAttentionAtIndex(self, surface_index)) continue;
            if (self.app_config.notifications_enabled) fireStatusNotification(self, surface, .done);
        } else if (self.app_config.notifications_enabled and projectedStatusBecame(previous, surface, .waiting)) {
            fireStatusNotification(self, surface, .waiting);
        } else if (self.app_config.notifications_enabled and projectedStatusBecame(previous, surface, .@"error")) {
            fireStatusNotification(self, surface, .@"error");
        }
    }
}

// True only when the exact terminal pane owns focus in the focused window.
// A visible sibling or a pane in another workspace must retain its completion.
fn surfaceIsFocused(self: anytype, surface: *const SurfaceState) bool {
    if (!self.window_input_focus) return false;
    const project_index = self.project_controller.selected_index;
    if (!surfaceBelongsToProject(self, surface, project_index)) return false;
    const layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const focused_pane_id = layout.focused_pane_id orelse return false;
    if (layout.maximized_pane_id) |max_id| {
        if (max_id != focused_pane_id) return false;
    }
    const pane = layout.paneById(focused_pane_id) orelse return false;
    return switch (pane.ref) {
        .terminal => |ref| ref.dock_id == surface.dock_id,
        else => false,
    };
}

fn projectedCompletionBecamePending(previous: *const State, current: *const SurfaceState) bool {
    if (!current.completion_pending) return false;
    for (previous.surfaces.items) |surface| {
        if (!std.mem.eql(u8, surface.session_id, current.session_id)) continue;
        // Native reporters can finish between GUI projection polls, leaving the
        // pending bit true across turns. The timestamp identifies a new edge
        // while an unchanged timestamp still suppresses replay notifications.
        return !surface.completion_pending or
            (current.completed_at_ms > 0 and current.completed_at_ms > surface.completed_at_ms);
    }
    return true;
}

fn projectedStatusBecame(previous: *const State, current: *const SurfaceState, status: SurfaceStatus) bool {
    if (current.status != status) return false;
    for (previous.surfaces.items) |surface| {
        if (!std.mem.eql(u8, surface.session_id, current.session_id)) continue;
        return surface.status != status;
    }
    return true;
}

test "terminal surface is focused only for the selected focused pane" {
    const PaneRef = union(enum) {
        chat: void,
        terminal: struct { dock_id: u32 },
        browser: void,
    };
    const Pane = struct {
        id: u32,
        ref: PaneRef,
    };
    const Layout = struct {
        focused_pane_id: ?u32,
        maximized_pane_id: ?u32 = null,
        pane: Pane,

        fn paneById(self: *const @This(), pane_id: u32) ?*const Pane {
            return if (self.pane.id == pane_id) &self.pane else null;
        }
    };
    const Project = struct {
        id: []const u8,
        path: []const u8,
        workspace_layout: Layout,
    };
    const FakeState = struct {
        window_input_focus: bool = true,
        project_controller: struct {
            selected_index: usize = 0,
            projects: struct { items: []Project },
        },

        fn projectPathMatches(_: *@This(), first: []const u8, second: []const u8) bool {
            return std.mem.eql(u8, first, second);
        }
    };

    var projects = [_]Project{.{
        .id = "workspace-a",
        .path = "/tmp/workspace-a",
        .workspace_layout = .{
            .focused_pane_id = 7,
            .pane = .{ .id = 7, .ref = .{ .terminal = .{ .dock_id = 52 } } },
        },
    }};
    var state: FakeState = .{ .project_controller = .{ .projects = .{ .items = &projects } } };
    var surface: SurfaceState = .{
        .session_id = @constCast("session-a"),
        .workspace_id = @constCast("workspace-a"),
        .workspace_path = @constCast("/tmp/workspace-a"),
        .dock_id = 52,
    };

    try std.testing.expect(surfaceIsFocused(&state, &surface));
    surface.dock_id = 53;
    try std.testing.expect(!surfaceIsFocused(&state, &surface));
    surface.dock_id = 52;
    state.window_input_focus = false;
    try std.testing.expect(!surfaceIsFocused(&state, &surface));
    state.window_input_focus = true;
    projects[0].workspace_layout.maximized_pane_id = 8;
    try std.testing.expect(!surfaceIsFocused(&state, &surface));
}

pub fn persistedSurfaceState(surface: *const SurfaceState) PersistedSurfaceState {
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
fn fireStatusNotification(self: anytype, surface: *const SurfaceState, chime: notifier.Chime) void {
    const provider = resolveSurfaceProvider(self, surface);
    const dir = if (surface.workspace_path.len > 0)
        std.fs.path.basename(surface.workspace_path)
    else
        "";

    var title_buf: [128]u8 = undefined;
    const title = if (surface.title.len > 0)
        surface.title
    else if (provider) |p|
        (std.fmt.bufPrint(&title_buf, "{s} {s}", .{ surfaceProviderLabel(p), statusVerb(chime) }) catch statusFallbackTitle(chime))
    else
        statusFallbackTitle(chime);

    var body_buf: [256]u8 = undefined;
    const body = if (dir.len > 0)
        (std.fmt.bufPrint(&body_buf, "{s} in {s}", .{ statusBodyVerb(chime), dir }) catch statusFallbackBody(chime))
    else
        statusFallbackBody(chime);

    const icon = if (provider) |p| completionNotificationIcon(p) else null;

    notifier.notifyAgent(self.allocator, title, body, icon, chime);
}

fn statusVerb(chime: notifier.Chime) []const u8 {
    return switch (chime) {
        .done => "finished",
        .waiting => "needs input",
        .@"error" => "failed",
    };
}

fn statusFallbackTitle(chime: notifier.Chime) []const u8 {
    return switch (chime) {
        .done => "Agent finished",
        .waiting => "Agent needs input",
        .@"error" => "Agent failed",
    };
}

fn statusBodyVerb(chime: notifier.Chime) []const u8 {
    return switch (chime) {
        .done => "Completed",
        .waiting => "Waiting",
        .@"error" => "Failed",
    };
}

fn statusFallbackBody(chime: notifier.Chime) []const u8 {
    return switch (chime) {
        .done => "Task completed",
        .waiting => "Needs your input",
        .@"error" => "Agent error",
    };
}

fn completionNotificationIcon(provider: SurfaceProvider) ?notifier.Icon {
    return switch (provider) {
        .codex => .{ .key = "codex", .png_bytes = CODEX_LOGO_BYTES },
        .opencode => .{ .key = "opencode", .png_bytes = OPENCODE_LOGO_BYTES },
        .claude => .{ .key = "claude", .png_bytes = CLAUDE_LOGO_BYTES },
        .cursor => .{ .key = "cursor", .png_bytes = CURSOR_LOGO_BYTES },
        .grok => .{ .key = "grok", .png_bytes = GROK_LOGO_BYTES },
        .amp => .{ .key = "amp", .png_bytes = AMP_LOGO_BYTES },
        .pi => .{ .key = "pi", .png_bytes = PI_LOGO_BYTES },
        .fx => .{ .key = "fx", .png_bytes = FX_LOGO_BYTES },
        .muse => .{ .key = "muse", .png_bytes = MUSE_LOGO_BYTES },
    };
}

test "projected completion edge ignores an already presented completion" {
    var previous: State = .{};
    defer previous.surfaces.deinit(std.testing.allocator);
    try previous.surfaces.append(std.testing.allocator, .{
        .session_id = @constCast("fx-session"),
        .title = @constCast("FX task"),
        .status = .working,
    });

    var current: SurfaceState = .{
        .session_id = @constCast("fx-session"),
        .title = @constCast("FX task"),
        .status = .done,
        .completion_pending = true,
        .completed_at_ms = 100,
    };
    try std.testing.expect(projectedCompletionBecamePending(&previous, &current));

    previous.surfaces.items[0].status = .done;
    previous.surfaces.items[0].completion_pending = true;
    previous.surfaces.items[0].completed_at_ms = current.completed_at_ms;
    try std.testing.expect(!projectedCompletionBecamePending(&previous, &current));

    current.completed_at_ms += 1;
    try std.testing.expect(projectedCompletionBecamePending(&previous, &current));

    current.completion_pending = false;
    try std.testing.expect(!projectedCompletionBecamePending(&previous, &current));
}

test "projected waiting and error edges fire once per transition" {
    var previous: State = .{};
    defer previous.surfaces.deinit(std.testing.allocator);
    try previous.surfaces.append(std.testing.allocator, .{
        .session_id = @constCast("fx-session"),
        .title = @constCast("FX task"),
        .status = .working,
    });

    var current: SurfaceState = .{
        .session_id = @constCast("fx-session"),
        .title = @constCast("FX task"),
        .status = .waiting,
    };
    try std.testing.expect(projectedStatusBecame(&previous, &current, .waiting));
    try std.testing.expect(!projectedStatusBecame(&previous, &current, .@"error"));

    previous.surfaces.items[0].status = .waiting;
    try std.testing.expect(!projectedStatusBecame(&previous, &current, .waiting));

    current.status = .@"error";
    try std.testing.expect(projectedStatusBecame(&previous, &current, .@"error"));
    previous.surfaces.items[0].status = .@"error";
    try std.testing.expect(!projectedStatusBecame(&previous, &current, .@"error"));
}

fn surfaceProviderLabel(provider: SurfaceProvider) []const u8 {
    return switch (provider) {
        .opencode => "OpenCode",
        .codex => "Codex",
        .cursor => "Cursor",
        .claude => "Claude",
        .grok => "Grok",
        .amp => "Amp",
        .pi => "Pi",
        .fx => "FX",
        .muse => "Muse",
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
    const done_ack = terminalSurfaceDisplayStatus(self, surface) == .done;
    if (!surface.attention and surface.unread_count == 0 and !done_ack) return terminal_changed;
    if (done_ack and !self.queueSurfaceAcknowledgement(surface)) return terminal_changed;
    surface.attention = false;
    surface.unread_count = 0;
    if (done_ack) {
        surface.completion_pending = false;
        surface.completed_at_ms = 0;
        if (surface.status == .done) surface.status = .idle;
    }
    surface.presentation_generation +%= 1;
    // Completion durability is owned by the targeted clear. Attention and
    // unread counts are volatile daemon/session projections and are not fields
    // in PersistedSurfaceState, so a compatibility snapshot cannot durably
    // represent their focus acknowledgement; dirtying 136 MiB here only made
    // workspace focus schedule redundant full-state work.
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

/// Supplement Claude Stop hooks with its live background-shell footer.
/// Keep the hook state intact so completion appears when the footer clears.
pub fn terminalSurfaceDisplayStatus(self: anytype, surface: *const SurfaceState) SurfaceStatus {
    const status = surface.displayStatus();
    if (surface.provider != .claude or (status != .done and status != .idle)) return status;
    for (self.project_controller.projects.items, 0..) |project, index| {
        if (!std.mem.eql(u8, surface.workspace_id, project.id) and
            !self.projectPathMatches(surface.workspace_path, project.path)) continue;
        const dock = self.projectTerminalDock(index, surface.dock_id) orelse return status;
        const session_id = dock.activeSessionId() orelse return status;
        if (!std.mem.eql(u8, surface.session_id, session_id)) return status;
        if (dock.activeClaudeBackgroundShells()) return .waiting;
        return status;
    }
    return status;
}

/// Returns the terminal surface bound to a workspace dock.
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

test "Grok and Amp completion notifications use provider logos" {
    inline for (.{ SurfaceProvider.grok, SurfaceProvider.amp }) |provider| {
        const icon = completionNotificationIcon(provider).?;
        try std.testing.expectEqualStrings(@tagName(provider), icon.key);
        try std.testing.expect(icon.png_bytes.len > 0);
    }
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

        fn projectPathMatches(_: *@This(), a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }

        fn projectTerminalDock(_: *@This(), _: usize, _: u32) ?*const terminal.Dock {
            return null;
        }

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

test "Claude background shells override completion without overriding active hook states" {
    const FakeDock = struct {
        shells: bool = true,
        session: []const u8 = "session-a",
        fn activeSessionId(self: *const @This()) ?[]const u8 {
            return self.session;
        }
        fn activeClaudeBackgroundShells(self: *const @This()) bool {
            return self.shells;
        }
    };
    const Project = struct { id: []const u8 = "workspace-a", path: []const u8 = "/workspace-a" };
    const FakeState = struct {
        project_controller: struct { projects: struct { items: []const Project } },
        dock: FakeDock = .{},
        fn projectPathMatches(_: *const @This(), a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
        fn projectTerminalDock(self: *const @This(), _: usize, _: u32) ?*const FakeDock {
            return &self.dock;
        }
    };
    const projects = [_]Project{.{}};
    var state: FakeState = .{ .project_controller = .{ .projects = .{ .items = &projects } } };
    var surface: SurfaceState = .{ .session_id = @constCast("session-a"), .workspace_id = @constCast("workspace-a"), .provider = .claude, .status = .done, .completion_pending = true };
    try std.testing.expectEqual(.waiting, terminalSurfaceDisplayStatus(&state, &surface));
    try std.testing.expect(surface.completion_pending);
    state.dock.shells = false;
    try std.testing.expectEqual(.done, terminalSurfaceDisplayStatus(&state, &surface));
    state.dock.shells = true;
    surface.completion_pending = false;
    inline for (.{ SurfaceStatus.working, SurfaceStatus.waiting, SurfaceStatus.@"error" }) |status| {
        surface.status = status;
        try std.testing.expectEqual(status, terminalSurfaceDisplayStatus(&state, &surface));
    }
    surface.status = .idle;
    try std.testing.expectEqual(.waiting, terminalSurfaceDisplayStatus(&state, &surface));
    surface.status = .done;
    surface.provider = .codex;
    try std.testing.expectEqual(.done, terminalSurfaceDisplayStatus(&state, &surface));
    surface.provider = .claude;
    state.dock.session = "different-session";
    try std.testing.expectEqual(.done, terminalSurfaceDisplayStatus(&state, &surface));
}

test "focused terminal acknowledges replayed Done but preserves unseen and waiting work" {
    const FakeDock = struct {
        shells: bool = false,
        at_shell: bool = false,
        fn activeSessionAtShellPrompt(self: *const @This(), _: i64) bool {
            return self.at_shell;
        }
        fn clearNotificationForSession(_: *@This(), _: []const u8) bool {
            return false;
        }
        fn activeSessionId(_: *const @This()) ?[]const u8 {
            return "session-a";
        }
        fn activeClaudeBackgroundShells(self: *const @This()) bool {
            return self.shells;
        }
    };
    const Pane = struct { ref: union(enum) { terminal: struct { dock_id: u32 = 54 }, chat: void } = .{ .terminal = .{} } };
    const Layout = struct {
        focused_pane_id: ?u32 = 7,
        maximized_pane_id: ?u32 = null,
        pane: Pane = .{},
        fn paneById(self: *const @This(), id: u32) ?*const Pane {
            return if (id == 7) &self.pane else null;
        }
    };
    const Project = struct {
        id: []const u8 = "workspace-a",
        path: []const u8 = "/workspace-a",
        workspace_layout: Layout = .{},
        terminal_dock: FakeDock = .{},
        terminal_docks: struct { items: []struct { dock: FakeDock } = &.{} } = .{},
    };
    const FakeState = struct {
        window_input_focus: bool = false,
        surface_controller: State,
        project_controller: struct { selected_index: usize = 0, projects: struct { items: []Project } },
        queued: usize = 0,
        accept_ack: bool = true,
        fn projectPathMatches(_: *@This(), a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
        fn projectTerminalDock(self: *@This(), index: usize, _: u32) ?*const FakeDock {
            return &self.project_controller.projects.items[index].terminal_dock;
        }
        fn queueSurfaceAcknowledgement(self: *@This(), _: *const SurfaceState) bool {
            if (!self.accept_ack) return false;
            self.queued += 1;
            return true;
        }
    };
    var projects = [_]Project{.{}};
    var surfaces = [_]SurfaceState{.{ .session_id = @constCast("session-a"), .workspace_id = @constCast("workspace-a"), .provider = .codex, .dock_id = 54, .status = .done, .completion_pending = true }};
    var state: FakeState = .{ .surface_controller = .{ .surfaces = .{ .items = &surfaces, .capacity = 1 } }, .project_controller = .{ .projects = .{ .items = &projects } } };
    try std.testing.expect(!acknowledgeFocusedTerminalCompletion(&state));
    state.window_input_focus = true;
    projects[0].workspace_layout.pane.ref = .{ .chat = {} };
    try std.testing.expect(!acknowledgeFocusedTerminalCompletion(&state));
    projects[0].workspace_layout.pane.ref = .{ .terminal = .{} };
    state.accept_ack = false;
    try std.testing.expect(!acknowledgeFocusedTerminalCompletion(&state));
    try std.testing.expect(surfaces[0].completion_pending);
    state.accept_ack = true;
    try std.testing.expect(acknowledgeFocusedTerminalCompletion(&state));
    try std.testing.expectEqual(.idle, surfaces[0].status);
    try std.testing.expect(!surfaces[0].completion_pending);
    try std.testing.expect(!acknowledgeFocusedTerminalCompletion(&state));
    try std.testing.expectEqual(@as(usize, 1), state.queued);
    surfaces[0].status = .waiting;
    try std.testing.expect(!acknowledgeFocusedTerminalCompletion(&state));
    surfaces[0].provider = .claude;
    surfaces[0].status = .done;
    surfaces[0].completion_pending = true;
    projects[0].terminal_dock.shells = true;
    try std.testing.expect(!acknowledgeFocusedTerminalCompletion(&state));
    projects[0].terminal_dock.shells = false;
    try std.testing.expect(acknowledgeFocusedTerminalCompletion(&state));
    // Returning to the shell retires every lifecycle without requiring focus.
    state.window_input_focus = false;
    projects[0].terminal_dock.at_shell = true;
    for ([_]SurfaceStatus{ .working, .waiting, .done, .@"error" }) |status| {
        surfaces[0].status = status;
        surfaces[0].attention = true;
        try std.testing.expect(acknowledgeFocusedTerminalCompletion(&state));
        try std.testing.expectEqual(.idle, surfaces[0].status);
        try std.testing.expect(!surfaces[0].attention);
        try std.testing.expect(!acknowledgeFocusedTerminalCompletion(&state));
    }
}
