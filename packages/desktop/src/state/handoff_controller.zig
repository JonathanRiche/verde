//! Cross-provider chat handoff state, preview collection, and target creation.

const std = @import("std");
const chat_handoff = @import("../chat/handoff.zig");
const db_types = @import("../db/types.zig");
const stack_config = @import("../workspace/stack.zig");
const provider_models = @import("provider_models.zig");
const workspace_layout = @import("workspace_layout.zig");

const Provider = provider_models.Provider;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;
const log = std.log.scoped(.native_shell);

fn defaultModelRef(self: anytype, provider: Provider) [:0]const u8 {
    return switch (provider) {
        .codex => provider_models.DEFAULT_CODEX_MODEL,
        .opencode => self.cachedDefaultModelRefForProvider(.opencode),
        .claude => provider_models.DEFAULT_CLAUDE_MODEL,
        .cursor => provider_models.DEFAULT_CURSOR_MODEL,
        .pi => provider_models.DEFAULT_PI_MODEL,
        .fx => provider_models.DEFAULT_FX_MODEL,
        .grok => provider_models.DEFAULT_GROK_MODEL,
        .muse => provider_models.DEFAULT_MUSE_MODEL,
    };
}

/// Providers offered as handoff targets, in menu order. The default target
/// is the entry after the source so a handoff never lands on the same agent.
pub const TARGET_PROVIDERS = [_]Provider{ .codex, .opencode, .claude, .cursor, .pi, .fx, .grok };

pub fn defaultTargetProvider(source: Provider) Provider {
    for (TARGET_PROVIDERS, 0..) |candidate, index| {
        if (candidate == source) return TARGET_PROVIDERS[(index + 1) % TARGET_PROVIDERS.len];
    }
    return TARGET_PROVIDERS[0];
}

test "default handoff target is the next provider in menu order" {
    try std.testing.expectEqual(Provider.opencode, defaultTargetProvider(.codex));
    try std.testing.expectEqual(Provider.codex, defaultTargetProvider(.grok));
    try std.testing.expectEqual(Provider.codex, defaultTargetProvider(.muse));
    for (TARGET_PROVIDERS) |source| try std.testing.expect(defaultTargetProvider(source) != source);
}

pub const TargetSurface = enum {
    gui_chat,
    tui,
};

/// Select menus in the inline handoff sheet; at most one is open.
pub const Menu = enum {
    surface,
    provider,
    thread,
    context,
};

pub const State = struct {
    sheet_open: bool = false,
    menu: ?Menu = null,
    /// Keyboard focus among the sheet's selects, in the sheet's MENUS order.
    focus_index: usize = 0,
    /// Keyboard-highlighted option inside the open menu.
    menu_highlight: usize = 0,
    preview_expanded: bool = false,
    project_index: usize = 0,
    source_pane_id: WorkspacePaneId = 0,
    source_thread_index: ?usize = null,
    source_provider: Provider = .codex,
    target_surface: TargetSurface = .gui_chat,
    target_provider: Provider = .claude,
    use_existing: bool = false,
    target_thread_index: ?usize = null,
    context_mode: chat_handoff.ContextMode = .summary,
    preview: ?[:0]u8 = null,
};

/// Opens the handoff wizard for the currently focused GUI chat or tracked
/// agent TUI. No provider request is made until the prepared target draft
/// is reviewed and submitted by the user.
pub fn beginHandoffFromFocusedPane(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    const project_index = self.project_controller.selected_index;
    const project = &self.project_controller.projects.items[project_index];
    const pane_id = project.workspace_layout.focused_pane_id orelse {
        self.setSidebarNotice("Focus a chat or agent TUI before handing off.");
        return;
    };
    const pane = project.workspace_layout.paneById(pane_id) orelse return;
    switch (pane.ref) {
        .chat => |ref| self.beginThreadHandoff(project_index, ref.thread_index, pane_id),
        .terminal => |ref| {
            const surface = self.projectTerminalSurface(project_index, ref.dock_id) orelse {
                self.setSidebarNotice("This terminal is not a tracked agent TUI.");
                return;
            };
            const provider = surface.provider orelse {
                self.setSidebarNotice("The active TUI provider is unknown.");
                return;
            };
            const chat_provider = chatProviderForSurface(provider) orelse {
                self.setSidebarNotice("This TUI provider does not support GUI handoff yet.");
                return;
            };
            beginHandoff(self, project_index, pane_id, null, chat_provider);
        },
        .browser => self.setSidebarNotice("Focus a chat or agent TUI before handing off."),
    }
}

fn chatProviderForSurface(provider: db_types.SurfaceProvider) ?Provider {
    return switch (provider) {
        .opencode => .opencode,
        .codex => .codex,
        .cursor => .cursor,
        .claude => .claude,
        .pi => .pi,
        .fx => .fx,
        .grok => .grok,
        .muse => .muse,
        .amp => null,
    };
}

pub fn beginThreadHandoff(self: anytype, project_index: usize, thread_index: usize, pane_id: WorkspacePaneId) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const project = &self.project_controller.projects.items[project_index];
    if (thread_index >= project.threads.items.len) return;
    beginHandoff(self, project_index, pane_id, thread_index, project.threads.items[thread_index].provider);
}

fn beginHandoff(self: anytype, project_index: usize, pane_id: WorkspacePaneId, thread_index: ?usize, provider: Provider) void {
    self.cancelHandoff();
    self.handoff_controller.sheet_open = true;
    self.handoff_controller.menu = null;
    self.handoff_controller.focus_index = 0;
    self.handoff_controller.menu_highlight = 0;
    self.handoff_controller.preview_expanded = false;
    self.handoff_controller.project_index = project_index;
    self.handoff_controller.source_pane_id = pane_id;
    self.handoff_controller.source_thread_index = thread_index;
    self.handoff_controller.source_provider = provider;
    self.handoff_controller.target_surface = .gui_chat;
    self.handoff_controller.target_provider = defaultTargetProvider(provider);
    self.handoff_controller.use_existing = false;
    self.handoff_controller.target_thread_index = firstCompatibleHandoffTargetThread(self);
    self.handoff_controller.context_mode = .summary;
    self.handoff_controller.preview = buildHandoffPreviewAlloc(self) catch |err| {
        log.warn("failed to build handoff preview: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to collect the handoff context.");
        self.handoff_controller.sheet_open = false;
        return;
    };
    self.closeSidebarContextMenu();
    self.blurPaletteComposer();
    self.markDirty();
}

pub fn cancelHandoff(self: anytype) void {
    self.handoff_controller.sheet_open = false;
    self.handoff_controller.menu = null;
    if (self.handoff_controller.preview) |preview| {
        self.allocator.free(preview);
        self.handoff_controller.preview = null;
    }
    self.markDirty();
}

pub fn setHandoffTargetSurface(self: anytype, surface: TargetSurface) void {
    self.handoff_controller.target_surface = surface;
    validateHandoffExistingTarget(self);
    self.markDirty();
}

pub fn setHandoffTargetProvider(self: anytype, provider: Provider) void {
    self.handoff_controller.target_provider = provider;
    self.handoff_controller.target_thread_index = firstCompatibleHandoffTargetThread(self);
    if (self.handoff_controller.target_thread_index == null) self.handoff_controller.use_existing = false;
    self.markDirty();
}

pub fn setHandoffUseExisting(self: anytype, use_existing: bool) void {
    if (use_existing) {
        validateHandoffExistingTarget(self);
        if (self.handoff_controller.target_thread_index == null) {
            self.setSidebarNotice("No compatible target thread is available for this provider.");
            return;
        }
    }
    self.handoff_controller.use_existing = use_existing;
    self.markDirty();
}

pub fn cycleHandoffExistingTarget(self: anytype) void {
    if (self.handoff_controller.project_index >= self.project_controller.projects.items.len) return;
    const project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    const current = self.handoff_controller.target_thread_index orelse 0;
    var offset: usize = 1;
    while (offset <= project.threads.items.len) : (offset += 1) {
        const index = (current + offset) % project.threads.items.len;
        if (!isCompatibleHandoffTargetThread(self, index)) continue;
        self.handoff_controller.target_thread_index = index;
        self.handoff_controller.use_existing = true;
        self.markDirty();
        return;
    }
}

pub fn setHandoffMenu(self: anytype, menu: ?Menu) void {
    if (self.handoff_controller.menu == menu) return;
    self.handoff_controller.menu = menu;
    self.markDirty();
}

pub fn toggleHandoffPreview(self: anytype) void {
    self.handoff_controller.preview_expanded = !self.handoff_controller.preview_expanded;
    self.markDirty();
}

/// Binds the handoff to a specific compatible existing thread.
pub fn selectHandoffExistingTarget(self: anytype, thread_index: usize) void {
    if (!isCompatibleHandoffTargetThread(self, thread_index)) return;
    self.handoff_controller.target_thread_index = thread_index;
    self.handoff_controller.use_existing = true;
    self.markDirty();
}

/// Returns the n-th compatible target thread index for the current target
/// provider, in project thread order, so menus can enumerate them.
pub fn handoffCompatibleTargetThreadAt(self: anytype, n: usize) ?usize {
    if (self.handoff_controller.project_index >= self.project_controller.projects.items.len) return null;
    const project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    var seen: usize = 0;
    for (project.threads.items, 0..) |_, index| {
        if (!isCompatibleHandoffTargetThread(self, index)) continue;
        if (seen == n) return index;
        seen += 1;
    }
    return null;
}

pub fn handoffExistingTargetLabel(self: anytype) []const u8 {
    if (self.handoff_controller.project_index >= self.project_controller.projects.items.len) return "No compatible thread";
    const index = self.handoff_controller.target_thread_index orelse return "No compatible thread";
    const project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    if (index >= project.threads.items.len) return "No compatible thread";
    return project.threads.items[index].title;
}

fn validateHandoffExistingTarget(self: anytype) void {
    if (self.handoff_controller.target_thread_index) |index| {
        if (isCompatibleHandoffTargetThread(self, index)) return;
    }
    self.handoff_controller.target_thread_index = firstCompatibleHandoffTargetThread(self);
    if (self.handoff_controller.target_thread_index == null) self.handoff_controller.use_existing = false;
}

fn firstCompatibleHandoffTargetThread(self: anytype) ?usize {
    if (self.handoff_controller.project_index >= self.project_controller.projects.items.len) return null;
    const project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    var best: ?usize = null;
    for (project.threads.items, 0..) |_, index| {
        if (!isCompatibleHandoffTargetThread(self, index)) continue;
        if (best == null or project.threads.items[index].last_activity_at > project.threads.items[best.?].last_activity_at) best = index;
    }
    return best;
}

fn isCompatibleHandoffTargetThread(self: anytype, index: usize) bool {
    if (self.handoff_controller.project_index >= self.project_controller.projects.items.len) return false;
    const project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    if (index >= project.threads.items.len or self.handoff_controller.source_thread_index == index) return false;
    const thread = &project.threads.items[index];
    return thread.committed and !thread.archived and thread.provider == self.handoff_controller.target_provider and
        thread.provider_thread_id != null and !thread.isSendPendingForUi();
}

pub fn setHandoffContextMode(self: anytype, mode: chat_handoff.ContextMode) void {
    if (self.handoff_controller.context_mode == mode) return;
    self.handoff_controller.context_mode = mode;
    const preview = buildHandoffPreviewAlloc(self) catch |err| {
        log.warn("failed to rebuild handoff preview: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to refresh the handoff preview.");
        return;
    };
    if (self.handoff_controller.preview) |old| self.allocator.free(old);
    self.handoff_controller.preview = preview;
    self.markDirty();
}

pub fn handoffPreviewText(self: anytype) []const u8 {
    return if (self.handoff_controller.preview) |preview| preview else "";
}

pub fn handoffTargetModelLabel(self: anytype) []const u8 {
    if (self.handoff_controller.use_existing) {
        if (self.handoff_controller.target_thread_index) |index| {
            if (self.handoff_controller.project_index < self.project_controller.projects.items.len) {
                const project = &self.project_controller.projects.items[self.handoff_controller.project_index];
                if (index < project.threads.items.len) return project.threads.items[index].model_ref orelse "Provider default";
            }
        }
    }
    return defaultModelRef(self, self.handoff_controller.target_provider);
}

/// Creates the target and fills its input with the preview. It deliberately
/// does not submit the prompt, preserving the required review/edit step.
pub fn prepareHandoffTarget(self: anytype) void {
    if (!self.handoff_controller.sheet_open) return;
    const preview = self.handoff_controller.preview orelse return;
    if (self.handoff_controller.project_index >= self.project_controller.projects.items.len) {
        self.cancelHandoff();
        return;
    }

    const target_pane_id = switch (self.handoff_controller.target_surface) {
        .gui_chat => prepareGuiHandoffTarget(self, preview) catch |err| {
            log.warn("failed to prepare GUI handoff target: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create the handoff chat.");
            return;
        },
        .tui => prepareTuiHandoffTarget(self, preview) catch |err| {
            log.warn("failed to prepare TUI handoff target: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create the handoff TUI.");
            return;
        },
    };
    recordHandoffLink(self, target_pane_id);
    self.cancelHandoff();
    self.setSidebarNotice("Handoff prepared. Review and edit it before sending.");
    self.markDirty();
}

fn prepareGuiHandoffTarget(self: anytype, preview: []const u8) !WorkspacePaneId {
    if (self.handoff_controller.use_existing) return prepareExistingGuiHandoffTarget(self, preview);
    const result = try self.openWorkspaceChat(self.handoff_controller.project_index, .{
        .provider = self.handoff_controller.target_provider,
        .model_ref = defaultModelRef(self, self.handoff_controller.target_provider),
        .target_pane_id = self.handoff_controller.source_pane_id,
        .axis = .horizontal,
        .focus = true,
    });
    if (!try self.setWorkspaceChatPaneDraftForProject(self.handoff_controller.project_index, result.pane_id, preview, false)) {
        return error.HandoffDraftUnavailable;
    }
    return result.pane_id;
}

fn prepareExistingGuiHandoffTarget(self: anytype, preview: []const u8) !WorkspacePaneId {
    const thread_index = self.handoff_controller.target_thread_index orelse return error.HandoffTargetUnavailable;
    if (!isCompatibleHandoffTargetThread(self, thread_index)) return error.HandoffTargetUnavailable;
    self.project_controller.selected_index = self.handoff_controller.project_index;
    var project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    var pane_id = project.workspace_layout.visibleChatPaneIdForThread(thread_index);
    if (pane_id == null) {
        if (!self.splitCurrentProjectWorkspacePaneWithThread(self.handoff_controller.source_pane_id, thread_index, .horizontal, true)) {
            return error.HandoffTargetUnavailable;
        }
        project = &self.project_controller.projects.items[self.handoff_controller.project_index];
        pane_id = project.workspace_layout.visibleChatPaneIdForThread(thread_index);
    }
    const resolved_pane_id = pane_id orelse return error.HandoffTargetUnavailable;
    self.focusWorkspaceOpenPane(self.handoff_controller.project_index, resolved_pane_id);
    if (!try self.setWorkspaceChatPaneDraftForProject(self.handoff_controller.project_index, resolved_pane_id, preview, false)) {
        return error.HandoffDraftUnavailable;
    }
    return resolved_pane_id;
}

fn prepareTuiHandoffTarget(self: anytype, preview: []const u8) !WorkspacePaneId {
    if (self.handoff_controller.use_existing) return prepareExistingTuiHandoffTarget(self, preview);
    const provider: stack_config.AgentProvider = switch (self.handoff_controller.target_provider) {
        .codex => .codex,
        .opencode => .opencode,
        .claude => .claude,
        .cursor => .cursor,
        // Pi and FX have no agent-TUI stack profile yet; the caller reports the error.
        .pi, .fx => return error.UnsupportedOperation,
        .grok => .grok,
        .muse => .muse,
    };
    if (!try self.openAgentTuiAtPlacement(
        self.handoff_controller.project_index,
        provider,
        self.handoff_controller.source_pane_id,
        .horizontal,
        true,
    )) return error.HandoffTuiUnavailable;
    const project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    const pane_id = project.workspace_layout.focused_pane_id orelse return error.HandoffTuiUnavailable;
    if (!try self.pasteWorkspaceTerminalPaneForProject(self.handoff_controller.project_index, pane_id, preview)) {
        return error.HandoffTuiUnavailable;
    }
    return pane_id;
}

fn prepareExistingTuiHandoffTarget(self: anytype, preview: []const u8) !WorkspacePaneId {
    const thread_index = self.handoff_controller.target_thread_index orelse return error.HandoffTargetUnavailable;
    if (!isCompatibleHandoffTargetThread(self, thread_index)) return error.HandoffTargetUnavailable;
    self.project_controller.selected_index = self.handoff_controller.project_index;
    var project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    if (project.workspace_layout.visibleChatPaneIdForThread(thread_index) == null and
        !self.splitCurrentProjectWorkspacePaneWithThread(self.handoff_controller.source_pane_id, thread_index, .horizontal, true))
    {
        return error.HandoffTargetUnavailable;
    }
    self.openThreadInTui(self.handoff_controller.project_index, thread_index);
    project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    const dock_id = project.threads.items[thread_index].tui_dock_id orelse return error.HandoffTargetUnavailable;
    const pane_id = project.workspace_layout.visibleTerminalPaneIdForDock(dock_id) orelse return error.HandoffTargetUnavailable;
    if (!try self.pasteWorkspaceTerminalPaneForProject(self.handoff_controller.project_index, pane_id, preview)) return error.HandoffTuiUnavailable;
    return pane_id;
}

fn recordHandoffLink(self: anytype, target_pane_id: WorkspacePaneId) void {
    const source_thread_index = self.handoff_controller.source_thread_index orelse return;
    if (self.handoff_controller.project_index >= self.project_controller.projects.items.len) return;
    var project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    if (source_thread_index >= project.threads.items.len) return;
    const target_thread_index: ?usize = if (self.handoff_controller.use_existing)
        self.handoff_controller.target_thread_index
    else switch (self.handoff_controller.target_surface) {
        .gui_chat => project.workspace_layout.paneById(target_pane_id).?.ref.chat.thread_index,
        .tui => null,
    };
    var body_buf: [512]u8 = undefined;
    const body = if (target_thread_index) |index|
        std.fmt.bufPrint(&body_buf, "Source pane {d} handed off to GUI pane {d} (Verde thread {s}, provider {s}).", .{
            self.handoff_controller.source_pane_id,
            target_pane_id,
            project.threads.items[index].local_thread_id,
            @tagName(self.handoff_controller.target_provider),
        }) catch "Chat handed off to another GUI pane."
    else
        std.fmt.bufPrint(&body_buf, "Source pane {d} handed off to TUI pane {d} (provider {s}).", .{
            self.handoff_controller.source_pane_id,
            target_pane_id,
            @tagName(self.handoff_controller.target_provider),
        }) catch "Chat handed off to a TUI pane.";
    self.appendMessageToThread(&project.threads.items[source_thread_index], .system, "Handoff prepared", body, null, &.{}) catch {};
    if (target_thread_index) |index| {
        project = &self.project_controller.projects.items[self.handoff_controller.project_index];
        var reverse_buf: [512]u8 = undefined;
        const reverse = std.fmt.bufPrint(&reverse_buf, "Prepared from source pane {d} (Verde thread {s}, provider {s}).", .{
            self.handoff_controller.source_pane_id,
            project.threads.items[source_thread_index].local_thread_id,
            @tagName(self.handoff_controller.source_provider),
        }) catch "Prepared from another Verde chat.";
        self.appendMessageToThread(&project.threads.items[index], .system, "Handoff source", reverse, null, &.{}) catch {};
    }
}

fn buildHandoffPreviewAlloc(self: anytype) ![:0]u8 {
    if (self.handoff_controller.project_index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
    const project = &self.project_controller.projects.items[self.handoff_controller.project_index];
    const pane = project.workspace_layout.paneById(self.handoff_controller.source_pane_id) orelse return error.TargetPaneNotFound;

    var message_views: []chat_handoff.MessageView = &.{};
    defer if (message_views.len > 0) self.allocator.free(message_views);
    var attachment_views: []chat_handoff.AttachmentView = &.{};
    defer if (attachment_views.len > 0) self.allocator.free(attachment_views);
    var terminal_history: ?[]u8 = null;
    defer if (terminal_history) |history| self.allocator.free(history);
    var verde_thread_id: ?[]const u8 = null;
    var verde_session_id: ?[]const u8 = null;
    var provider_thread_id: ?[]const u8 = null;
    var title: []const u8 = "Agent TUI";
    var source_surface: chat_handoff.Surface = .tui;

    if (self.handoff_controller.source_thread_index) |thread_index| {
        if (thread_index >= project.threads.items.len) return error.ThreadNotFound;
        const thread = &project.threads.items[thread_index];
        message_views = try self.allocator.alloc(chat_handoff.MessageView, thread.messages.items.len);
        var attachment_count: usize = 0;
        for (thread.messages.items) |message| {
            if (message.image != null) attachment_count += 1;
            attachment_count += message.extra_images.len;
        }
        attachment_views = try self.allocator.alloc(chat_handoff.AttachmentView, attachment_count);
        var attachment_index: usize = 0;
        for (thread.messages.items, 0..) |message, index| {
            message_views[index] = .{
                .role = switch (message.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .system => .system,
                },
                .author = message.author,
                .body = message.body,
            };
            if (message.image) |image| {
                attachment_views[attachment_index] = .{ .file_name = image.file_name, .mime = image.mime, .byte_size = image.byte_size };
                attachment_index += 1;
            }
            for (message.extra_images) |image| {
                attachment_views[attachment_index] = .{ .file_name = image.file_name, .mime = image.mime, .byte_size = image.byte_size };
                attachment_index += 1;
            }
        }
        verde_thread_id = thread.local_thread_id;
        provider_thread_id = thread.provider_thread_id;
        title = thread.title;
        source_surface = .gui_chat;
    } else {
        const dock_id = switch (pane.ref) {
            .terminal => |ref| ref.dock_id,
            else => return error.TargetPaneNotFound,
        };
        const surface = self.projectTerminalSurface(self.handoff_controller.project_index, dock_id);
        if (surface) |value| {
            verde_session_id = value.session_id;
            provider_thread_id = value.provider_thread_id;
            if (value.title.len > 0) title = value.title;
        }
        terminal_history = try self.terminalPaneScreenTextForProject(self.handoff_controller.project_index, self.handoff_controller.source_pane_id);
    }

    const git_context = try collectHandoffGitContextAlloc(self, project.path);
    defer self.allocator.free(git_context);
    const process_context = try collectHandoffProcessContextAlloc(self, self.handoff_controller.project_index);
    defer self.allocator.free(process_context);

    return try chat_handoff.buildAlloc(self.allocator, .{
        .workspace_id = project.id,
        .workspace_label = project.label,
        .workspace_path = project.path,
        .pane_id = self.handoff_controller.source_pane_id,
        .source_surface = source_surface,
        .source_provider = @tagName(self.handoff_controller.source_provider),
        .verde_session_id = verde_session_id,
        .verde_thread_index = self.handoff_controller.source_thread_index,
        .verde_thread_id = verde_thread_id,
        .provider_thread_id = provider_thread_id,
        .title = title,
        .messages = message_views,
        .attachments = attachment_views,
        .terminal_history = terminal_history orelse "",
        .git_context = git_context,
        .process_context = process_context,
        .context_mode = self.handoff_controller.context_mode,
    });
}

fn collectHandoffGitContextAlloc(self: anytype, project_path: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(self.allocator);
    var threaded: std.Io.Threaded = .init(self.allocator, .{});
    defer threaded.deinit();
    const commands = [_][]const []const u8{
        &.{ "git", "status", "--short", "--branch" },
        &.{ "git", "diff", "--stat" },
        &.{ "git", "diff", "--no-ext-diff", "--" },
    };
    for (commands) |argv| {
        const result = std.process.run(self.allocator, threaded.io(), .{
            .argv = argv,
            .cwd = .{ .path = project_path },
            .stdout_limit = .limited(24 * 1024),
            .stderr_limit = .limited(4 * 1024),
        }) catch continue;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) try output.appendSlice(self.allocator, result.stdout),
            else => {},
        }
        if (output.items.len > 24 * 1024) break;
    }
    if (output.items.len == 0) try output.appendSlice(self.allocator, "Git state unavailable or this workspace is not a Git repository.\n");
    return try self.allocator.dupe(u8, output.items);
}

fn collectHandoffProcessContextAlloc(self: anytype, project_index: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(self.allocator);
    const project = &self.project_controller.projects.items[project_index];
    for (project.managed_processes.items) |process| {
        if (process.status != .running and process.status != .starting and process.status != .restarting) continue;
        const line = try std.fmt.allocPrint(self.allocator, "- {s}: {s} ({s})\n", .{ process.name, process.command, @tagName(process.status) });
        defer self.allocator.free(line);
        try output.appendSlice(self.allocator, line);
    }
    const dock_id = switch (project.workspace_layout.paneById(self.handoff_controller.source_pane_id).?.ref) {
        .terminal => |ref| ref.dock_id,
        else => null,
    };
    if (dock_id) |id| {
        if (self.projectTerminalDock(project_index, id)) |dock| {
            if (dock.activeRuntimeProcessSnapshot()) |snapshot| {
                const line = try std.fmt.allocPrint(self.allocator, "- Active pane process: pid={?d}, foreground={}, running={}\n", .{ snapshot.pid, snapshot.foreground, snapshot.running });
                defer self.allocator.free(line);
                try output.appendSlice(self.allocator, line);
            }
        }
    }
    if (output.items.len == 0) try output.appendSlice(self.allocator, "No active managed processes were reported.\n");
    return try self.allocator.dupe(u8, output.items);
}
