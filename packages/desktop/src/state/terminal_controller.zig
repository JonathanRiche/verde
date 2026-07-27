//! Terminal ownership, focus, input routing, polling, and agent-TUI metadata.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("zsdl3");
const profiler = @import("../runtime/profiler.zig");
const keybinds = @import("../app/keybinds.zig");
const platform_runtime = @import("platform_runtime");
const stack_config = @import("../workspace/stack.zig");
const terminal = @import("../terminal/terminal.zig");
const workspace_layout = @import("workspace_layout.zig");

const log = std.log.scoped(.native_shell);
const deinitWorkspacePaneRef = workspace_layout.deinitWorkspacePaneRef;

const ACTIVITY_BURST_WINDOW_MS: i64 = 250;
const POLL_INTERVAL_MS: i64 = 16;

fn monotonicMs() i64 {
    return @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

pub const DefaultAgentTui = struct {
    name: []const u8,
    command: []const u8,
    provider: stack_config.AgentProvider,
    notify: bool = false,
    mcp: bool = false,
    hooks: bool = false,
};

pub const OPENCODE_TUI_COMMAND =
    \\candidate=$(find "$HOME/.npm/_npx" -path '*/node_modules/opencode-linux-x64*/bin/opencode' -type f -perm -111 2>/dev/null | sort | tail -n 1)
    \\if [ -n "$candidate" ]; then exec "$candidate"; fi
    \\exec opencode
;
const GROK_TUI_COMMAND = "grok --no-auto-update";

fn opencodeTuiCommandForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) "opencode" else OPENCODE_TUI_COMMAND;
}

pub fn defaultAgentTui(provider: stack_config.AgentProvider) ?DefaultAgentTui {
    return switch (provider) {
        .codex => .{ .name = "codex", .command = "codex", .provider = .codex, .notify = true, .mcp = true, .hooks = true },
        .claude => .{ .name = "claude", .command = "claude", .provider = .claude },
        .opencode => .{ .name = "opencode", .command = opencodeTuiCommandForOs(builtin.os.tag), .provider = .opencode },
        .cursor => .{ .name = "cursor", .command = "agent", .provider = .cursor, .notify = true, .hooks = true },
        .grok => .{ .name = "grok", .command = GROK_TUI_COMMAND, .provider = .grok, .notify = true, .hooks = true },
        .amp => .{ .name = "amp", .command = "amp", .provider = .amp },
        .other => null,
    };
}

pub fn isKnownDefaultAgentTuiCommand(provider: stack_config.AgentProvider, command: []const u8) bool {
    return switch (provider) {
        .codex => std.mem.eql(u8, command, "codex"),
        .claude => std.mem.eql(u8, command, "claude"),
        .opencode => std.mem.eql(u8, command, "opencode") or std.mem.eql(u8, command, OPENCODE_TUI_COMMAND),
        .cursor => std.mem.eql(u8, command, "agent"),
        .grok => std.mem.eql(u8, command, "grok") or std.mem.eql(u8, command, GROK_TUI_COMMAND),
        .amp => std.mem.eql(u8, command, "amp"),
        .other => false,
    };
}

pub fn agentTuiProviderLabel(provider: ?stack_config.AgentProvider) []const u8 {
    return switch (provider orelse return "Agent") {
        .codex => "Codex",
        .claude => "Claude",
        .opencode => "OpenCode",
        .cursor => "Cursor",
        .grok => "Grok",
        .amp => "Amp",
        .other => "Agent",
    };
}

pub fn supportedAgentTuiProviderFromName(name: []const u8) ?stack_config.AgentProvider {
    const provider = std.meta.stringToEnum(stack_config.AgentProvider, name) orelse return null;
    return if (defaultAgentTui(provider) != null) provider else null;
}

pub fn agentTuiProviderFromProcessName(name: []const u8) ?stack_config.AgentProvider {
    if (std.mem.eql(u8, name, "codex")) return .codex;
    if (std.mem.eql(u8, name, "claude")) return .claude;
    if (std.mem.eql(u8, name, "opencode")) return .opencode;
    if (std.mem.eql(u8, name, "agent") or std.mem.startsWith(u8, name, "cursor")) return .cursor;
    if (std.mem.eql(u8, name, "grok")) return .grok;
    if (std.mem.eql(u8, name, "amp")) return .amp;
    return null;
}

test "Grok TUI defaults disable auto-update and recognize the process" {
    const defaults = defaultAgentTui(.grok).?;
    try std.testing.expectEqualStrings("grok", defaults.name);
    try std.testing.expectEqualStrings("grok --no-auto-update", defaults.command);
    try std.testing.expect(defaults.notify);
    try std.testing.expect(defaults.hooks);
    try std.testing.expect(isKnownDefaultAgentTuiCommand(.grok, "grok"));
    try std.testing.expectEqual(stack_config.AgentProvider.grok, agentTuiProviderFromProcessName("grok").?);
}

pub const State = struct {
    focused: bool = false,
    debug_window_focused: bool = false,
    debug_hitbox_focused: bool = false,
    debug_hitbox_active: bool = false,
    debug_hitbox_clicked: bool = false,
    debug_focus_requested: bool = false,
    debug_last_key_handled: bool = false,
    debug_last_text_handled: bool = false,
    debug_last_scancode: ?sdl.Scancode = null,
    debug_last_text: [32:0]u8 = [_:0]u8{0} ** 32,
    debug_workspace_visible_pane_count: usize = 0,
    last_activity_ms: i64 = 0,
    last_poll_ms: i64 = 0,
    poll_requested: bool = false,
};

pub fn currentProjectTerminal(self: anytype) *const terminal.Dock {
    if (self.focusedWorkspaceTerminalDockId()) |dock_id| {
        if (self.currentProjectTerminalDock(dock_id)) |dock| return dock;
    }
    return &self.currentProject().terminal_dock;
}

pub fn currentProjectTerminalMutable(self: anytype) *terminal.Dock {
    if (self.focusedWorkspaceTerminalDockId()) |dock_id| {
        if (self.currentProjectTerminalDockMutable(dock_id)) |dock| return dock;
    }
    return &self.currentProjectMutable().terminal_dock;
}

pub fn currentProjectTerminalDock(self: anytype, dock_id: u32) ?*const terminal.Dock {
    if (self.project_controller.projects.items.len == 0) return null;
    const project = self.currentProject();
    if (dock_id == 0) return &project.terminal_dock;
    for (project.terminal_docks.items) |*entry| {
        if (entry.id == dock_id) return &entry.dock;
    }
    return null;
}

pub fn currentProjectTerminalDockMutable(self: anytype, dock_id: u32) ?*terminal.Dock {
    if (self.project_controller.projects.items.len == 0) return null;
    var project = self.currentProjectMutable();
    if (dock_id == 0) return &project.terminal_dock;
    for (project.terminal_docks.items) |*entry| {
        if (entry.id == dock_id) return &entry.dock;
    }
    return null;
}

pub fn projectTerminalDock(self: anytype, project_index: usize, dock_id: u32) ?*const terminal.Dock {
    if (project_index >= self.project_controller.projects.items.len) return null;
    const project = &self.project_controller.projects.items[project_index];
    if (dock_id == 0) return &project.terminal_dock;
    for (project.terminal_docks.items) |*entry| {
        if (entry.id == dock_id) return &entry.dock;
    }
    return null;
}

pub fn projectTerminalDockMutable(self: anytype, project_index: usize, dock_id: u32) ?*terminal.Dock {
    if (project_index >= self.project_controller.projects.items.len) return null;
    var project = &self.project_controller.projects.items[project_index];
    if (dock_id == 0) return &project.terminal_dock;
    for (project.terminal_docks.items) |*entry| {
        if (entry.id == dock_id) return &entry.dock;
    }
    return null;
}

/// Returns the supported agent provider explicitly associated with a TUI
/// dock. Generic terminals are deliberately not inferred from their live
/// foreground process, so they never become workspace history entries.
pub fn workspaceAgentTuiProvider(self: anytype, project_index: usize, dock_id: u32) ?stack_config.AgentProvider {
    if (project_index >= self.project_controller.projects.items.len) return null;
    if (self.projectTerminalDock(project_index, dock_id)) |dock| {
        if (dock.activeTabPinnedProvider()) |name| {
            if (supportedAgentTuiProviderFromName(name)) |provider| return provider;
        }
    }
    const project = &self.project_controller.projects.items[project_index];
    for (project.managed_processes.items) |process| {
        if (process.kind != .agent or process.dock_id != dock_id) continue;
        const provider = process.provider orelse continue;
        if (defaultAgentTui(provider) != null) return provider;
    }
    if (self.projectTerminalDock(project_index, dock_id)) |dock| {
        var process_name_buf: [96]u8 = undefined;
        if (dock.activeForegroundProcessName(&process_name_buf)) |name| {
            if (agentTuiProviderFromProcessName(name)) |provider| return provider;
        }
    }
    return null;
}

pub fn workspaceAgentTuiHistoryAt(self: anytype, project_index: usize, dock_id: u32) i64 {
    const provider = self.workspaceAgentTuiProvider(project_index, dock_id) orelse return 0;
    const dock_snapshot = self.projectTerminalDock(project_index, dock_id) orelse return 0;
    const existing = dock_snapshot.activeTabAgentHistoryAt();
    if (existing != 0) return existing;

    // Prompt-submit hooks persist a title for Codex and Cursor. Use it to
    // migrate panes whose first turn happened before history enrollment.
    if (provider == .codex or provider == .cursor) {
        if (dock_snapshot.activeTabPinnedTitle()) |title| {
            if (title.len > 0) {
                const activity_at = unixTimestampMs();
                const dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return 0;
                if (dock.noteActiveTabAgentHistory(activity_at)) self.markDirty();
                return activity_at;
            }
        }
    }

    // Amp panes created before TUI history had no persisted provider marker.
    // Foreground-process detection is their only identity after restart, so
    // enroll them when first encountered. Newly created panes are pinned and
    // still wait for their first submitted prompt below.
    if (provider != .amp) return 0;
    if (dock_snapshot.activeTabPinnedProvider() == null) {
        const activity_at = unixTimestampMs();
        const dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return 0;
        if (dock.noteActiveTabAgentHistory(activity_at)) self.markDirty();
        return activity_at;
    }

    // Programmatic Amp submissions do not pass through terminal key input.
    // The lifecycle plugin distinguishes startup (`idle`) from a real call.
    const surface = self.projectTerminalSurface(project_index, dock_id) orelse return 0;
    if (surface.status == .idle or surface.status_changed_at_ms == 0) return 0;
    const activity_at = surface.status_changed_at_ms;
    const dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return 0;
    if (dock.noteActiveTabAgentHistory(activity_at)) self.markDirty();
    return activity_at;
}

/// Recreates a workspace pane around a saved agent TUI dock. The dock and
/// its session outlive pane closure, so this reattaches instead of starting
/// a second provider process.
pub fn openWorkspaceAgentTuiHistory(self: anytype, project_index: usize, dock_id: u32) bool {
    if (project_index >= self.project_controller.projects.items.len) return false;
    if (self.workspaceAgentTuiHistoryAt(project_index, dock_id) == 0) return false;
    if (self.projectTerminalDock(project_index, dock_id) == null) return false;

    self.project_controller.selected_index = project_index;
    self.ensureCurrentProjectWorkspace();
    var project = &self.project_controller.projects.items[project_index];
    const pane_id = project.workspace_layout.ensureTerminalPane(self.allocator, dock_id) catch {
        self.setSidebarNotice("Failed to reopen agent TUI.");
        return false;
    };
    project.workspace_layout.maximized_pane_id = null;
    if (project.managedProcessByDockId(dock_id)) |process| process.pane_id = pane_id;
    if (self.projectTerminalDock(project_index, dock_id)) |dock| {
        if (dock.activeSessionId()) |session_id| {
            if (self.surfaceBySessionId(session_id)) |surface| surface.pane_id = pane_id;
        }
    }
    self.requestTerminalDockFocus(dock_id);
    self.setSidebarNotice("Agent TUI reopened from history.");
    self.markDirty();
    return true;
}

pub fn focusedWorkspaceTerminalDockId(self: anytype) ?u32 {
    if (self.project_controller.projects.items.len == 0) return null;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const pane = layout.focusedPane() orelse return null;
    return switch (pane.ref) {
        .terminal => |ref| ref.dock_id,
        else => null,
    };
}

pub fn createCurrentProjectTerminalTab(self: anytype, dock_id: u32, profile: terminal.TerminalLaunchProfile) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    self.createTerminalTabForWorkspaceProfile(self.project_controller.selected_index, dock_id, profile) catch |err| {
        log.warn("failed to create workspace terminal tab: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to create terminal tab.");
        return false;
    };
    self.requestTerminalDockFocus(dock_id);
    self.markDirty();
    return true;
}

pub fn createProjectTerminalDock(self: anytype, project_index: usize) !u32 {
    if (project_index >= self.project_controller.projects.items.len) return error.NoProjectSelected;
    var project = &self.project_controller.projects.items[project_index];
    const dock_id = project.next_terminal_dock_id;
    project.next_terminal_dock_id += 1;
    var dock = try terminal.Dock.init(self.allocator);
    dock.setDefaultFontSize(self.app_config.terminal_font_size);
    errdefer dock.deinit(self.allocator);
    try project.terminal_docks.append(self.allocator, .{ .id = dock_id, .dock = dock });
    return dock_id;
}

pub fn createCurrentProjectTerminalDock(self: anytype) !u32 {
    if (self.project_controller.projects.items.len == 0) return error.NoProjectSelected;
    return self.createProjectTerminalDock(self.project_controller.selected_index);
}

pub fn isTerminalVisible(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const project = self.currentProject();
    return project.terminal_dock.visible or
        project.workspace_layout.hasVisiblePaneKind(.terminal) or
        project.workspace_layout.hasVisibleQuickPaneKind(.terminal);
}

pub fn shouldRenderLegacyTerminalDockInChat(self: anytype) bool {
    if (self.project_controller.projects.items.len == 0) return false;
    const project = self.currentProject();
    return project.terminal_dock.visible and !project.workspace_layout.hasVisiblePaneKind(.terminal);
}

pub fn toggleCurrentProjectTerminal(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) {
        self.setSidebarNotice("No workspace selected.");
        return;
    }

    self.ensureCurrentProjectWorkspace();
    var dock = self.currentProjectTerminalMutable();
    if (!dock.hasRunningSession()) {
        self.restartTerminalDockForWorkspace(self.project_controller.selected_index, 0) catch |err| {
            log.err("failed to start terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to start terminal.");
            return;
        };
    }

    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    const terminal_open = layout.visibleTerminalPaneIdForDock(0) != null;

    const pane_id = layout.ensureTerminalPane(self.allocator, 0) catch |err| {
        log.err("failed to open terminal workspace pane: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to open terminal pane.");
        return;
    };
    if (!terminal_open) layout.focusCreatedPane(pane_id);
    dock.visible = false;
    self.requestTerminalFocus();
    self.setSidebarNotice(if (terminal_open) "Terminal focused." else "Terminal opened.");
    self.markDirty();
}

/// True while a visible terminal recently accepted input or produced
/// output; the main loop uses this to render the next echo/chunk promptly.
pub fn terminalActivityBurstActive(self: anytype) bool {
    if (self.terminal_controller.last_activity_ms == 0) return false;
    return monotonicMs() - self.terminal_controller.last_activity_ms < ACTIVITY_BURST_WINDOW_MS;
}

/// Starts a short active-poll window after accepted terminal input. The
/// forced poll preserves the immediate post-event check while the cadence
/// guard prevents high-rate SDL events from opening one pipe RPC each.
pub fn noteTerminalInputActivity(self: anytype) void {
    self.terminal_controller.last_activity_ms = monotonicMs();
    self.terminal_controller.poll_requested = true;
}

pub fn pollTerminals(self: anytype) bool {
    var visible_changed = false;
    const now_ms = monotonicMs();
    if (!self.terminal_controller.poll_requested and
        self.terminal_controller.last_poll_ms != 0 and
        now_ms - self.terminal_controller.last_poll_ms < POLL_INTERVAL_MS)
    {
        return false;
    }
    self.terminal_controller.poll_requested = false;
    self.terminal_controller.last_poll_ms = now_ms;
    for (self.project_controller.projects.items, 0..) |*project, project_index| {
        const project_selected = project_index == self.project_controller.selected_index;
        const base_visible = project.terminal_dock.visible or project.workspace_layout.hasTerminalDockPane(0);
        if (!project_selected) {
            self.pollManagedProcesses(project_index);
            continue;
        }
        if (project_selected and base_visible and !project.terminal_dock.hasRunningSession() and project.terminal_dock.reserveAutoRestart(now_ms)) {
            const start_result = if (project.terminal_dock.hasRestorableSession())
                project.terminal_dock.ensureSessionPersistent(self.allocator, project.path, self.storage.pref_path, 0)
            else
                self.restartTerminalDockForWorkspace(project_index, 0);
            start_result catch |err| {
                log.err("failed to start visible terminal session: {s}", .{@errorName(err)});
                if (project_index == self.project_controller.selected_index) self.setSidebarNotice("Terminal session failed.");
            };
            if (project_index == self.project_controller.selected_index) {
                visible_changed = true;
            }
        }
        if (base_visible or project.terminal_dock.hasRunningSession()) {
            const changed = project.terminal_dock.poll(self.allocator) catch |err| blk: {
                log.err("failed to poll terminal session: {s}", .{@errorName(err)});
                if (project_index == self.project_controller.selected_index and base_visible) {
                    self.setSidebarNotice("Terminal session failed.");
                }
                break :blk false;
            };
            if (project.terminal_dock.consumeWorkspaceChange()) self.markDirty();
            self.drainTerminalDockNotifications(project_index, 0, &project.terminal_dock) catch |err| {
                log.warn("failed to apply terminal notification: {s}", .{@errorName(err)});
            };
            if (changed and project_index == self.project_controller.selected_index and base_visible) visible_changed = true;
        }
        var exited_editor_dock_id: ?u32 = null;
        for (project.terminal_docks.items) |*entry| {
            const dock_visible = entry.dock.visible or project.workspace_layout.hasTerminalDockPane(entry.id);
            const managed_process_explicitly_stopped = if (project.managedProcessByDockId(entry.id)) |process|
                process.explicit_stop
            else
                false;
            if (dock_visible and !entry.dock.hasRunningSession() and project.workspace_layout.hasEditorTerminalDockPane(entry.id)) {
                exited_editor_dock_id = entry.id;
                break;
            }
            if (project_selected and dock_visible and !managed_process_explicitly_stopped and !entry.dock.hasRunningSession() and entry.dock.reserveAutoRestart(now_ms)) {
                const start_result = if (entry.dock.hasRestorableSession())
                    entry.dock.ensureSessionPersistent(self.allocator, project.path, self.storage.pref_path, entry.id)
                else
                    self.restartTerminalDockForWorkspace(project_index, entry.id);
                start_result catch |err| {
                    log.err("failed to start visible terminal dock {d}: {s}", .{ entry.id, @errorName(err) });
                    if (project_index == self.project_controller.selected_index) self.setSidebarNotice("Terminal session failed.");
                };
                if (project_index == self.project_controller.selected_index) {
                    visible_changed = true;
                }
            }
            if (!dock_visible and !entry.dock.hasRunningSession()) continue;
            const changed = entry.dock.poll(self.allocator) catch |err| blk: {
                log.err("failed to poll terminal dock {d}: {s}", .{ entry.id, @errorName(err) });
                if (project_index == self.project_controller.selected_index and dock_visible) {
                    self.setSidebarNotice("Terminal session failed.");
                }
                break :blk false;
            };
            if (entry.dock.consumeWorkspaceChange()) self.markDirty();
            self.drainTerminalDockNotifications(project_index, entry.id, &entry.dock) catch |err| {
                log.warn("failed to apply terminal dock notification: {s}", .{@errorName(err)});
            };
            if (changed and project_index == self.project_controller.selected_index and dock_visible) visible_changed = true;
        }
        if (exited_editor_dock_id) |dock_id| {
            if (closeExitedEditorTerminalPane(self, project_index, dock_id) and project_index == self.project_controller.selected_index) {
                visible_changed = true;
            }
        }
        self.pollManagedProcesses(project_index);
    }
    visible_changed = self.pollUpdateInstallerTerminal() or visible_changed;
    if (visible_changed) self.terminal_controller.last_activity_ms = monotonicMs();
    return visible_changed;
}

fn closeExitedEditorTerminalPane(self: anytype, project_index: usize, dock_id: u32) bool {
    // The updater is an interactive one-shot command whose final output
    // must remain visible instead of being auto-closed like editor tasks.
    if (self.isUpdateInstallerTerminal(project_index, dock_id)) return false;
    if (project_index >= self.project_controller.projects.items.len) return false;
    var project = &self.project_controller.projects.items[project_index];
    var layout = &project.workspace_layout;
    const pane_id = layout.visibleTerminalPaneIdForDock(dock_id) orelse return false;
    const pane = layout.paneById(pane_id) orelse return false;
    const terminal_ref = switch (pane.ref) {
        .terminal => |ref| ref,
        else => return false,
    };
    if (terminal_ref.purpose != .editor) return false;
    if (layout.visiblePaneCount() <= 1) return false;

    if (project.terminalDockEntryById(dock_id)) |entry| {
        entry.dock.terminateAllSessions();
        _ = project.removeTerminalDockById(self.allocator, dock_id);
    }
    var removed_ref = layout.closePane(self.allocator, pane_id) orelse return false;
    defer deinitWorkspacePaneRef(&removed_ref, self.allocator);
    if (self.project_controller.selected_index == project_index and !layout.hasVisiblePaneKind(.terminal)) self.terminal_controller.focused = false;
    self.setSidebarNotice("Editor pane closed.");
    self.markDirty();
    return true;
}

pub fn drainTerminalDockNotifications(self: anytype, project_index: usize, dock_id: u32, dock: *terminal.Dock) !void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const event = dock.takeActiveNotification() orelse return;
    const project = &self.project_controller.projects.items[project_index];
    _ = try self.updateSurface(.{
        .session_id = event.session_id,
        .workspace_id = project.id,
        .workspace_path = project.path,
        .dock_id = dock_id,
        .pane_id = event.pane_id,
        .attention = event.attention,
        .unread_increment = 1,
        .last_event_title = if (event.title.len > 0) event.title else "Terminal",
        .last_event_body = event.body,
    });
}

pub fn handleTerminalKeyDown(
    self: anytype,
    keyboard: *const keybinds.NativeKeyboardConfig,
    event: *const sdl.KeyboardEvent,
) bool {
    if (!canRouteTerminalInput(self)) return false;
    const dock_id = terminalInputDockId(self) orelse return false;
    if (keyboard.terminalActionForEvent(event)) |action| {
        switch (action) {
            .new_tab => return self.createCurrentProjectTerminalTab(dock_id, .{}),
            .split_up => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.horizontal, false),
            .split_down => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.horizontal, true),
            .split_left => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.vertical, false),
            .split_right => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.vertical, true),
            else => {},
        }
    }
    const is_agent_tui = self.workspaceAgentTuiProvider(self.project_controller.selected_index, dock_id) != null;
    var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return false;
    const handled = dock.handleKeyDown(self.allocator, keyboard, event);
    if (handled and is_agent_tui and (event.key == .@"return" or event.key == .kp_enter)) {
        if (dock.noteActiveTabAgentHistory(unixTimestampMs())) self.markDirty();
    }
    if (dock.consumeWorkspaceChange()) self.markDirty();
    if (handled) self.noteTerminalInputActivity();
    return handled;
}

pub fn handleTerminalTextInput(self: anytype, text: [*c]const u8) bool {
    if (!canRouteTerminalInput(self)) return false;
    const dock_id = terminalInputDockId(self) orelse return false;
    var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return false;
    const handled = dock.handleTextInput(std.mem.sliceTo(text, 0));
    if (handled) self.noteTerminalInputActivity();
    return handled;
}

pub fn requestTerminalFocus(self: anytype) void {
    self.focusCurrentProjectWorkspaceTerminalPane();
    finishTerminalFocusRequest(self);
}

pub fn requestTerminalDockFocus(self: anytype, dock_id: u32) void {
    self.focusCurrentProjectWorkspaceTerminalDock(dock_id);
    finishTerminalFocusRequest(self);
}

fn finishTerminalFocusRequest(self: anytype) void {
    self.terminal_controller.focused = true;
    self.composer_controller.focused = false;
    self.composer_controller.composer.focused = false;
    self.unfocusBrowserPane();
    self.browser_controller.address_focused = false;
    self.palette_modal_text_focus = .none;
    if (self.focusedWorkspaceTerminalDockId()) |dock_id| {
        _ = self.clearSurfaceAttentionForDock(self.project_controller.selected_index, dock_id);
    }
}

fn canRouteTerminalInput(self: anytype) bool {
    if (!self.terminal_controller.focused or !self.isTerminalVisible()) return false;
    if (self.shouldRenderLegacyTerminalDockInChat()) return true;
    return self.focusedWorkspacePaneKind() == .terminal;
}

fn terminalInputDockId(self: anytype) ?u32 {
    if (self.shouldRenderLegacyTerminalDockInChat()) return 0;
    return self.focusedWorkspaceTerminalDockId();
}
