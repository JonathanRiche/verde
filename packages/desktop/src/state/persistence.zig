//! Persistence snapshot construction and daemon-routed compatibility payloads.
//!
//! Phase 3: the detached SQLite save worker is gone. Snapshot construction
//! remains as the compatibility payload for `state.snapshot.replace`; actual
//! commits run in the endpoint-owning daemon.

const std = @import("std");
const headless = @import("headless");
const db_types = @import("../db/types.zig");
const terminal = @import("../terminal/terminal.zig");
const chat_types = @import("chat_types.zig");
const herdr_types = @import("herdr_types.zig");
const project_state = @import("project.zig");

const log = std.log.scoped(.native_shell);
const LoadedPersistedState = db_types.LoadedState;
const PersistedState = db_types.PersistedState;
const PersistedSurfaceState = db_types.PersistedSurfaceState;
const PersistedChatCompletion = db_types.PersistedChatCompletion;
const PersistedImageAttachment = db_types.PersistedImageAttachment;
const PersistedMessage = db_types.PersistedMessage;
const PersistedProject = db_types.PersistedProject;
const PersistedThread = db_types.PersistedThread;
const ChatImageAttachment = chat_types.ChatImageAttachment;
const ChatMessage = chat_types.ChatMessage;
const ChatThread = chat_types.ChatThread;
const Project = project_state.Project;
const HerdrWorkspaceLink = herdr_types.HerdrWorkspaceLink;

fn replaceOwnedSlice(allocator: std.mem.Allocator, slot: *[]u8, value: []const u8) !void {
    const next = try allocator.dupe(u8, value);
    allocator.free(slot.*);
    slot.* = next;
}

fn replaceOwnedOptionalSlice(allocator: std.mem.Allocator, slot: *?[]u8, value: ?[]const u8) !void {
    const next = if (value) |slice| try allocator.dupe(u8, slice) else null;
    if (slot.*) |existing| allocator.free(existing);
    slot.* = next;
}

pub const SnapshotContext = struct {
    projects: []const Project,
    archived_projects: []const Project,
    selected_project_index: usize,
    sidebar_collapsed: bool,
};

pub fn buildSnapshot(context: SnapshotContext, backing_allocator: std.mem.Allocator) !LoadedPersistedState {
    var loaded = LoadedPersistedState.init(backing_allocator);
    errdefer loaded.deinit();

    const arena = loaded.allocator();
    var projects: std.ArrayList(PersistedProject) = .empty;
    defer projects.deinit(arena);

    for (context.projects) |project| {
        try projects.append(arena, try persistedProjectSnapshot(arena, &project));
    }
    for (context.archived_projects) |project| {
        try projects.append(arena, try persistedProjectSnapshot(arena, &project));
    }

    loaded.value = .{
        .selected_project_index = context.selected_project_index,
        .sidebar_collapsed = context.sidebar_collapsed,
        .projects = try projects.toOwnedSlice(arena),
    };
    return loaded;
}

fn persistedProjectSnapshot(allocator: std.mem.Allocator, project: *const Project) !PersistedProject {
    var threads: std.ArrayList(PersistedThread) = .empty;
    defer threads.deinit(allocator);
    const terminal_layout_json = try project.terminal_dock.persistedLayoutJsonWithContext(allocator, .{
        .project_id = project.id,
        .project_path = project.path,
        .dock_id = 0,
    });
    errdefer if (terminal_layout_json) |value| allocator.free(value);
    const terminal_docks_json = try persistedTerminalDocksJson(allocator, project);
    errdefer if (terminal_docks_json) |value| allocator.free(value);
    const workspace_layout_json = try project.workspace_layout.persistedWorkspaceJson(allocator);
    errdefer allocator.free(workspace_layout_json);

    const retained_thread_index = lastRetainedActiveThreadIndex(project);
    for (project.threads.items, 0..) |thread, thread_index| {
        // Workspace panes and the selected thread persist raw array indexes.
        // Retaining a contiguous prefix keeps those indexes stable while still
        // dropping abandoned trailing drafts that nothing references.
        if (!project.archived and (retained_thread_index == null or thread_index > retained_thread_index.?)) continue;
        try threads.append(allocator, try threadSnapshot(allocator, &thread));
    }
    for (project.archived_threads.items) |thread| {
        try threads.append(allocator, try threadSnapshot(allocator, &thread));
    }

    return .{
        .id = try allocator.dupe(u8, project.id),
        .label = try allocator.dupe(u8, project.label),
        .path = try allocator.dupe(u8, project.path),
        .archived = project.archived,
        .unread_count = project.unread_count,
        .collapsed = project.collapsed,
        .thread_list_expanded = project.thread_list_expanded,
        .terminal_height = project.terminal_dock.preferred_height,
        .terminal_layout_json = terminal_layout_json,
        .terminal_docks_json = terminal_docks_json,
        .workspace_layout_json = workspace_layout_json,
        .selected_thread_index = if (project.threads.items.len == 0) 0 else @min(project.selected_thread_index, project.threads.items.len - 1),
        .companion_thread_local_id = try dupeOptionalSlice(allocator, project.companion_thread_local_id),
        .herdr_link = if (project.herdr_link) |*link| try link.toPersisted(allocator) else null,
        .threads = try threads.toOwnedSlice(allocator),
    };
}

fn lastRetainedActiveThreadIndex(project: *const Project) ?usize {
    if (project.threads.items.len == 0) return null;

    var retained: ?usize = null;
    for (project.threads.items, 0..) |thread, thread_index| {
        if (thread.committed) retained = if (retained) |current| @max(current, thread_index) else thread_index;
    }

    if (project.selected_thread_index < project.threads.items.len) {
        retained = if (retained) |current| @max(current, project.selected_thread_index) else project.selected_thread_index;
    }
    for (project.workspace_layout.panes.items) |pane| {
        const thread_index = switch (pane.ref) {
            .chat => |ref| ref.thread_index,
            else => continue,
        };
        if (thread_index >= project.threads.items.len) continue;
        retained = if (retained) |current| @max(current, thread_index) else thread_index;
    }
    if (project.companion_thread_local_id) |local_id| {
        for (project.threads.items, 0..) |thread, thread_index| {
            if (!std.mem.eql(u8, thread.local_thread_id, local_id)) continue;
            retained = if (retained) |current| @max(current, thread_index) else thread_index;
            break;
        }
    }
    return retained;
}

test "snapshot retains pane-backed draft threads without shifting indexes" {
    const allocator = std.testing.allocator;
    var projects: [1]Project = .{try Project.init(allocator, "workspace-id", "Workspace", "/tmp/workspace", 0)};
    defer projects[0].deinit(allocator);
    const project = &projects[0];

    project.threads.items[0].committed = true;

    const first_draft_index = try project.addThread(allocator);
    const first_draft_pane = try project.workspace_layout.createChatPane(allocator, first_draft_index);
    try project.workspace_layout.splitPaneWithLeaf(allocator, 1, first_draft_pane, .vertical, true);

    const second_draft_index = try project.addThread(allocator);
    project.threads.items[second_draft_index].setDraft("unfinished prompt");
    const second_draft_pane = try project.workspace_layout.createChatPane(allocator, second_draft_index);
    try project.workspace_layout.splitPaneWithLeaf(allocator, first_draft_pane, second_draft_pane, .horizontal, true);

    _ = try project.addThread(allocator);
    project.selected_thread_index = second_draft_index;

    var snapshot = try buildSnapshot(.{
        .projects = projects[0..],
        .archived_projects = &.{},
        .selected_project_index = 0,
        .sidebar_collapsed = false,
    }, allocator);
    defer snapshot.deinit();

    const persisted_project = snapshot.value.projects[0];
    const persisted_threads = persisted_project.threads.?;
    try std.testing.expectEqual(@as(usize, 3), persisted_threads.len);
    try std.testing.expectEqualStrings("unfinished prompt", persisted_threads[second_draft_index].draft);
    try std.testing.expect(std.mem.indexOf(u8, persisted_project.workspace_layout_json.?, "\"thread\":2") != null);
}

test "snapshot retains pane-less Companion identity and stable thread indexes" {
    const allocator = std.testing.allocator;
    var projects: [1]Project = .{try Project.init(allocator, "workspace-id", "Workspace", "/tmp/workspace", 0)};
    defer projects[0].deinit(allocator);
    const project = &projects[0];
    project.threads.items[0].committed = true;
    const selected_before = project.selected_thread_index;
    const companion = try project.ensureCompanionThread(allocator);

    var snapshot = try buildSnapshot(.{
        .projects = &projects,
        .archived_projects = &.{},
        .selected_project_index = 0,
        .sidebar_collapsed = false,
    }, allocator);
    defer snapshot.deinit();

    const persisted = snapshot.value.projects[0];
    try std.testing.expectEqualStrings(companion.local_thread_id, persisted.companion_thread_local_id.?);
    try std.testing.expectEqual(@as(usize, 2), persisted.threads.?.len);
    try std.testing.expectEqual(selected_before, persisted.selected_thread_index);
    try std.testing.expectEqualStrings(companion.local_thread_id, persisted.threads.?[1].local_thread_id.?);
}

fn persistedTerminalDocksJson(allocator: std.mem.Allocator, project: *const Project) !?[]u8 {
    if (project.terminal_docks.items.len == 0) return null;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginArray();
    for (project.terminal_docks.items) |*entry| {
        const layout_json = try entry.dock.persistedLayoutJsonWithContext(allocator, .{
            .project_id = project.id,
            .project_path = project.path,
            .dock_id = entry.id,
        });
        defer if (layout_json) |value| allocator.free(value);
        if (layout_json == null and !entry.dock.hasRunningSession()) continue;
        try stringify.beginObject();
        try stringify.objectField("id");
        try stringify.write(entry.id);
        try stringify.objectField("layout");
        if (layout_json) |value| {
            try stringify.write(value);
        } else {
            try stringify.write(null);
        }
        try stringify.endObject();
    }
    try stringify.endArray();
    return try writer.toOwnedSlice();
}

pub fn threadSnapshot(allocator: std.mem.Allocator, thread: *const ChatThread) !PersistedThread {
    var messages: std.ArrayList(PersistedMessage) = .empty;
    defer messages.deinit(allocator);

    for (thread.messages.items) |message| {
        try messages.append(allocator, try persistedMessageSnapshot(allocator, &message));
    }

    return .{
        .title = try allocator.dupe(u8, thread.title),
        .archived = thread.archived,
        .committed = thread.committed,
        .local_thread_id = try allocator.dupe(u8, thread.local_thread_id),
        .last_activity_at = if (thread.last_activity_at == 0) null else thread.last_activity_at,
        .provider_thread_id = try dupeOptionalSlice(allocator, thread.provider_thread_id),
        .model_ref = try dupeOptionalSlice(allocator, thread.model_ref),
        .reasoning_effort = thread.reasoning_effort,
        .reasoning_variant = try dupeOptionalSlice(allocator, if (thread.opencode_reasoning_variant) |v| v else null),
        .fast_mode = thread.fast_mode,
        .access_mode = thread.access_mode,
        .provider = thread.provider,
        .harness = thread.harness,
        .tui_dock_id = thread.tui_dock_id,
        .draft = try allocator.dupe(u8, thread.currentDraft()),
        .draft_image = try imageSnapshot(allocator, thread.draft_image),
        .messages = try messages.toOwnedSlice(allocator),
    };
}

fn persistedMessageSnapshot(allocator: std.mem.Allocator, message: *const ChatMessage) !PersistedMessage {
    return .{
        .role = message.role,
        .author = try allocator.dupe(u8, message.author),
        .body = try allocator.dupe(u8, message.body),
        .image = try imageSnapshot(allocator, message.image),
        .tool_call_id = try dupeOptionalSlice(allocator, message.tool_call_id),
        .tool_call_kind = message.tool_call_kind,
        .tool_call_status = message.tool_call_status,
        // Identity carriage (M4-P4): the flush must never re-mint an id the
        // projection already knows (daemon-adopted or client-staged).
        .message_id = try dupeOptionalSlice(allocator, message.message_id),
    };
}

fn imageSnapshot(allocator: std.mem.Allocator, image: ?ChatImageAttachment) !?PersistedImageAttachment {
    const source = image orelse return null;
    return .{
        .path = try allocator.dupe(u8, source.path),
        .mime = try allocator.dupe(u8, source.mime),
        .byte_size = source.byte_size,
    };
}

fn dupeOptionalSlice(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |slice| try allocator.dupe(u8, slice) else null;
}

/// Identity round-trip helper (M4-P4): the wire encodes "no identity" as an
/// empty string; the projection uses null. Never carry an empty id inward.
fn dupeOptionalNonEmptySlice(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const slice = value orelse return null;
    if (slice.len == 0) return null;
    return try allocator.dupe(u8, slice);
}

/// Convert a desktop persisted surface row into the store wire DTO.
pub fn surfaceToProtocol(allocator: std.mem.Allocator, surface: PersistedSurfaceState) !headless.store.SurfaceState {
    return .{
        .session_id = try allocator.dupe(u8, surface.session_id),
        .workspace_id = try allocator.dupe(u8, surface.workspace_id),
        .workspace_path = try allocator.dupe(u8, surface.workspace_path),
        .dock_id = surface.dock_id,
        .pane_id = surface.pane_id,
        .provider = if (surface.provider) |p| try allocator.dupe(u8, @tagName(p)) else null,
        .provider_thread_id = try dupeOptionalSlice(allocator, surface.provider_thread_id),
        .title = try allocator.dupe(u8, surface.title),
        .status = try allocator.dupe(u8, @tagName(surface.status)),
        .status_changed_at_ms = surface.status_changed_at_ms,
        .completed_at_ms = surface.completed_at_ms,
        .last_event_title = try dupeOptionalSlice(allocator, surface.last_event_title),
        .last_event_body = try dupeOptionalSlice(allocator, surface.last_event_body),
    };
}

/// Convert a full desktop snapshot into the store wire snapshot for
/// `state.snapshot.replace` (Phase 3 compatibility bridge).
pub fn persistedStateToProtocolSnapshot(
    allocator: std.mem.Allocator,
    state: PersistedState,
    store_revision: u64,
) !headless.store.Snapshot {
    var workspaces = try allocator.alloc(headless.store.Workspace, state.projects.len);
    for (state.projects, 0..) |project, i| {
        workspaces[i] = try projectToProtocol(allocator, project);
    }

    var surfaces = try allocator.alloc(headless.store.SurfaceState, state.surface_states.len);
    for (state.surface_states, 0..) |surface, i| {
        surfaces[i] = try surfaceToProtocol(allocator, surface);
    }

    var completions = try allocator.alloc(headless.store.ChatCompletion, state.chat_completions.len);
    for (state.chat_completions, 0..) |completion, i| {
        completions[i] = .{
            .workspace_id = try allocator.dupe(u8, completion.workspace_id),
            .local_thread_id = try allocator.dupe(u8, completion.local_thread_id),
            .completed_at_ms = completion.completed_at_ms,
        };
    }

    return .{
        .schema_version = 1,
        .store_revision = store_revision,
        .selected_workspace_index = state.selected_project_index,
        .sidebar_collapsed = state.sidebar_collapsed,
        .workspaces = workspaces,
        .surface_states = surfaces,
        .chat_completions = completions,
        .provider = if (state.provider) |p| try allocator.dupe(u8, @tagName(p)) else null,
        .harness = if (state.harness) |h| try allocator.dupe(u8, @tagName(h)) else null,
        .draft = try dupeOptionalSlice(allocator, state.draft),
        .messages = if (state.messages) |msgs| try messagesToProtocol(allocator, msgs) else null,
    };
}

fn projectToProtocol(allocator: std.mem.Allocator, project: PersistedProject) !headless.store.Workspace {
    const workspace_id = if (project.id) |id| try allocator.dupe(u8, id) else try allocator.dupe(u8, project.path);
    const threads: []const headless.store.Thread = if (project.threads) |src|
        try threadsToProtocol(allocator, src)
    else
        &.{};
    const messages: []const headless.store.Message = try messagesToProtocol(allocator, project.messages);
    return .{
        .workspace_id = workspace_id,
        .label = try allocator.dupe(u8, project.label),
        .path = try allocator.dupe(u8, project.path),
        .archived = project.archived,
        .unread_count = project.unread_count,
        .collapsed = project.collapsed,
        .thread_list_expanded = project.thread_list_expanded,
        .terminal_height = project.terminal_height,
        .terminal_layout_json = try dupeOptionalSlice(allocator, project.terminal_layout_json),
        .terminal_docks_json = try dupeOptionalSlice(allocator, project.terminal_docks_json),
        .workspace_layout_json = try dupeOptionalSlice(allocator, project.workspace_layout_json),
        .selected_thread_index = project.selected_thread_index,
        .companion_thread_local_id = try dupeOptionalSlice(allocator, project.companion_thread_local_id),
        .herdr_link = if (project.herdr_link) |link| try herdrToProtocol(allocator, link) else null,
        .provider = try allocator.dupe(u8, @tagName(project.provider)),
        .harness = try allocator.dupe(u8, @tagName(project.harness)),
        .draft = try allocator.dupe(u8, project.draft),
        .threads = threads,
        .messages = messages,
    };
}

fn threadsToProtocol(allocator: std.mem.Allocator, threads: []const PersistedThread) ![]const headless.store.Thread {
    var out = try allocator.alloc(headless.store.Thread, threads.len);
    for (threads, 0..) |thread, i| {
        out[i] = try threadToProtocol(allocator, thread, i);
    }
    return out;
}

fn threadToProtocol(allocator: std.mem.Allocator, thread: PersistedThread, index: usize) !headless.store.Thread {
    const local_id = if (thread.local_thread_id) |id|
        try allocator.dupe(u8, id)
    else
        try std.fmt.allocPrint(allocator, "thread-{d}", .{index});
    return .{
        .local_thread_id = local_id,
        .title = try allocator.dupe(u8, thread.title),
        .archived = thread.archived,
        .committed = thread.committed,
        .last_activity_at = thread.last_activity_at,
        .provider_thread_id = try dupeOptionalSlice(allocator, thread.provider_thread_id),
        .model_ref = try dupeOptionalSlice(allocator, thread.model_ref),
        .reasoning_effort = if (thread.reasoning_effort) |v| try allocator.dupe(u8, @tagName(v)) else null,
        .reasoning_variant = try dupeOptionalSlice(allocator, thread.reasoning_variant),
        .fast_mode = if (thread.fast_mode) |v| try allocator.dupe(u8, @tagName(v)) else null,
        .access_mode = if (thread.access_mode) |v| try allocator.dupe(u8, @tagName(v)) else null,
        .provider = try allocator.dupe(u8, @tagName(thread.provider)),
        .harness = try allocator.dupe(u8, @tagName(thread.harness)),
        .tui_dock_id = thread.tui_dock_id,
        .draft = try allocator.dupe(u8, thread.draft),
        .draft_image = if (thread.draft_image) |img| try imageToProtocol(allocator, img) else null,
        .messages = try messagesToProtocol(allocator, thread.messages),
    };
}

fn messagesToProtocol(allocator: std.mem.Allocator, messages: []const PersistedMessage) ![]const headless.store.Message {
    var out = try allocator.alloc(headless.store.Message, messages.len);
    for (messages, 0..) |message, i| {
        out[i] = .{
            // Identity carriage (M4-P4): pass a known projection identity
            // through verbatim; mint the positional legacy id only for rows
            // that never had one. Minted ids become sticky on the next load,
            // so a flush never re-mints an id positionally. Positional minting
            // cannot collide with a sticky `snap-msg-{j}`: a sticky id keeps
            // the array index it was minted at (rows only ever append), so a
            // null-id row always sits at a different index than any sticky id.
            .message_id = if (message.message_id) |id|
                try allocator.dupe(u8, id)
            else
                try std.fmt.allocPrint(allocator, "snap-msg-{d}", .{i}),
            .role = try allocator.dupe(u8, @tagName(message.role)),
            .author = try allocator.dupe(u8, message.author),
            .body = try allocator.dupe(u8, message.body),
            .image = if (message.image) |img| try imageToProtocol(allocator, img) else null,
            .tool_call_id = try dupeOptionalSlice(allocator, message.tool_call_id),
            .tool_call_kind = if (message.tool_call_kind) |v| try allocator.dupe(u8, @tagName(v)) else null,
            .tool_call_status = if (message.tool_call_status) |v| try allocator.dupe(u8, @tagName(v)) else null,
        };
    }
    return out;
}

fn imageToProtocol(allocator: std.mem.Allocator, image: PersistedImageAttachment) !headless.store.Attachment {
    return .{
        .path = try allocator.dupe(u8, image.path),
        .mime = try allocator.dupe(u8, image.mime),
        .byte_size = image.byte_size,
    };
}

fn herdrToProtocol(allocator: std.mem.Allocator, link: db_types.PersistedHerdrWorkspaceLink) !headless.store.HerdrWorkspaceLink {
    return .{
        .remote_alias = try allocator.dupe(u8, link.remote_alias),
        .session_name = try allocator.dupe(u8, link.session_name),
        .workspace_id = try allocator.dupe(u8, link.workspace_id),
        .local_dir = try allocator.dupe(u8, link.local_dir),
        .remote_cwd = try dupeOptionalSlice(allocator, link.remote_cwd),
        .last_pane_id = try dupeOptionalSlice(allocator, link.last_pane_id),
        .attach_dock_id = link.attach_dock_id,
        .attach_pane_id = link.attach_pane_id,
        .pane_links_json = try dupeOptionalSlice(allocator, link.pane_links_json),
        .updated_at_ms = link.updated_at_ms,
    };
}

pub fn applyPersisted(self: anytype, persisted: PersistedState) !void {
    var cleaned_legacy_companion = false;
    self.sidebar_collapsed = persisted.sidebar_collapsed;
    if (persisted.projects.len == 0) {
        try self.restorePersistedSurfaceStates(persisted.surface_states);
        self.project_controller.selected_index = 0;
        self.project_controller.next_project_number = 1;
        self.syncRenameBuffer();
        self.lifecycle.dirty = false;
        return;
    }

    for (persisted.projects, 0..) |project, index| {
        const project_id = if (project.id) |persisted_id|
            try self.allocator.dupe(u8, persisted_id)
        else
            try self.deriveProjectId(project.path);
        defer self.allocator.free(project_id);

        var loaded = try Project.init(self.allocator, project_id, project.label, project.path, project.unread_count);
        var loaded_owned = true;
        errdefer if (loaded_owned) loaded.deinit(self.allocator);
        if (project.companion_thread_local_id) |local_id| {
            loaded.companion_thread_local_id = try self.allocator.dupeZ(u8, local_id);
        }
        loaded.archived = project.archived;
        loaded.collapsed = project.collapsed orelse false;
        loaded.thread_list_expanded = project.thread_list_expanded orelse false;
        if (project.herdr_link) |link| {
            loaded.herdr_link = try HerdrWorkspaceLink.initFromPersisted(self.allocator, link);
        }
        if (project.terminal_height) |height| {
            loaded.terminal_dock.preferred_height = terminal.clampPreferredHeight(height);
        }
        loaded.applyDefaultTerminalFontSize(self.app_config.terminal_font_size);
        if (project.terminal_layout_json) |layout_json| {
            loaded.terminal_dock.applyPersistedLayoutJson(self.allocator, layout_json) catch |err| {
                log.warn("failed to restore terminal layout: {s}", .{@errorName(err)});
            };
        }
        if (project.workspace_layout_json) |layout_json| {
            loaded.workspace_layout.applyPersistedWorkspaceJson(self.allocator, layout_json) catch |err| {
                log.warn("failed to restore workspace layout: {s}", .{@errorName(err)});
            };
        }
        if (project.terminal_docks_json) |docks_json| {
            self.applyPersistedTerminalDocksJson(&loaded, docks_json) catch |err| {
                log.warn("failed to restore terminal docks: {s}", .{@errorName(err)});
            };
        }
        for (loaded.threads.items) |*thread| {
            thread.deinit(self.allocator);
        }
        loaded.threads.clearRetainingCapacity();

        if (project.threads) |threads| {
            for (threads) |persisted_thread| {
                var thread = try ChatThread.init(self.allocator, persisted_thread.title);
                thread.archived = persisted_thread.archived;
                thread.committed = persisted_thread.committed;
                if (persisted_thread.local_thread_id) |local_thread_id| {
                    self.allocator.free(thread.local_thread_id);
                    thread.local_thread_id = try self.allocator.dupeZ(u8, local_thread_id);
                }
                thread.last_activity_at = persisted_thread.last_activity_at orelse 0;
                thread.provider_thread_id = if (persisted_thread.provider_thread_id) |thread_id|
                    try self.allocator.dupeZ(u8, thread_id)
                else
                    null;
                if (thread.model_ref) |model_ref| {
                    self.allocator.free(model_ref);
                }
                thread.model_ref = if (persisted_thread.model_ref) |model_ref|
                    try self.allocator.dupeZ(u8, model_ref)
                else
                    null;
                thread.reasoning_effort = persisted_thread.reasoning_effort;
                if (thread.opencode_reasoning_variant) |v| self.allocator.free(v);
                thread.opencode_reasoning_variant = if (persisted_thread.reasoning_variant) |rv|
                    try self.allocator.dupeZ(u8, rv)
                else
                    null;
                thread.fast_mode = persisted_thread.fast_mode orelse .off;
                thread.access_mode = persisted_thread.access_mode orelse .full_access;
                thread.provider = persisted_thread.provider;
                thread.harness = persisted_thread.harness;
                thread.tui_dock_id = persisted_thread.tui_dock_id;
                thread.setDraft(persisted_thread.draft);
                if (persisted_thread.draft_image) |image| {
                    try thread.setDraftImage(self.allocator, image.path, image.mime, image.byte_size);
                }
                for (persisted_thread.messages) |message| {
                    try thread.messages.append(self.allocator, .{
                        .role = message.role,
                        .author = try self.dupeZ(message.author),
                        .body = try self.dupeZ(message.body),
                        .image = if (message.image) |image|
                            try ChatImageAttachment.init(self.allocator, image.path, image.mime, image.byte_size)
                        else
                            null,
                        .tool_call_id = try dupeOptionalSlice(self.allocator, message.tool_call_id),
                        .tool_call_kind = message.tool_call_kind,
                        .tool_call_status = message.tool_call_status,
                        .message_id = try dupeOptionalNonEmptySlice(self.allocator, message.message_id),
                    });
                }
                thread.rebuildBackgroundTasksFromMessages(self.allocator);
                if (thread.last_activity_at == 0 and thread.messages.items.len > 0) {
                    thread.touch();
                }
                if (thread.archived) {
                    try loaded.archived_threads.append(self.allocator, thread);
                } else {
                    try loaded.threads.append(self.allocator, thread);
                }
            }
            if (!loaded.archived and loaded.threads.items.len == 0) {
                _ = try loaded.addThread(self.allocator);
            }
            if (loaded.threads.items.len == 0) {
                loaded.selected_thread_index = 0;
            } else {
                loaded.selected_thread_index = @min(project.selected_thread_index, loaded.threads.items.len - 1);
            }
        } else {
            var thread = try ChatThread.init(self.allocator, "New thread");
            thread.archived = project.archived;
            thread.committed = project.messages.len > 0;
            thread.last_activity_at = 0;
            thread.provider = project.provider;
            thread.harness = project.harness;
            thread.setDraft(project.draft);
            for (project.messages) |message| {
                try thread.messages.append(self.allocator, .{
                    .role = message.role,
                    .author = try self.dupeZ(message.author),
                    .body = try self.dupeZ(message.body),
                    .image = if (message.image) |image|
                        try ChatImageAttachment.init(self.allocator, image.path, image.mime, image.byte_size)
                    else
                        null,
                    .tool_call_id = try dupeOptionalSlice(self.allocator, message.tool_call_id),
                    .tool_call_kind = message.tool_call_kind,
                    .tool_call_status = message.tool_call_status,
                    .message_id = try dupeOptionalNonEmptySlice(self.allocator, message.message_id),
                });
            }
            thread.rebuildBackgroundTasksFromMessages(self.allocator);
            if (thread.archived) {
                try loaded.archived_threads.append(self.allocator, thread);
            } else {
                try loaded.threads.append(self.allocator, thread);
                loaded.selected_thread_index = 0;
            }
        }

        if (!loaded.archived and index == 0 and project.messages.len == 0 and project.threads == null and persisted.messages != null) {
            var fallback_thread = loaded.currentThreadMutable();
            fallback_thread.provider = persisted.provider orelse fallback_thread.provider;
            fallback_thread.harness = persisted.harness orelse fallback_thread.harness;
            if (persisted.draft) |draft| fallback_thread.setDraft(draft);
            for (persisted.messages.?) |message| {
                try fallback_thread.messages.append(self.allocator, .{
                    .role = message.role,
                    .author = try self.dupeZ(message.author),
                    .body = try self.dupeZ(message.body),
                    .image = if (message.image) |image|
                        try ChatImageAttachment.init(self.allocator, image.path, image.mime, image.byte_size)
                    else
                        null,
                    .tool_call_id = try dupeOptionalSlice(self.allocator, message.tool_call_id),
                    .tool_call_kind = message.tool_call_kind,
                    .tool_call_status = message.tool_call_status,
                    .message_id = try dupeOptionalNonEmptySlice(self.allocator, message.message_id),
                });
            }
            fallback_thread.rebuildBackgroundTasksFromMessages(self.allocator);
        }

        cleaned_legacy_companion = loaded.cleanupPristineLegacyCompanion(self.allocator) or cleaned_legacy_companion;
        try loaded.normalize(self.allocator, self.app_config.terminal_font_size);

        if (loaded.archived) {
            try self.project_controller.archived_projects.append(self.allocator, loaded);
        } else {
            try self.project_controller.projects.append(self.allocator, loaded);
        }
        loaded_owned = false;
    }

    if (self.project_controller.projects.items.len == 0) {
        self.project_controller.selected_index = 0;
    } else {
        self.project_controller.selected_index = @min(persisted.selected_project_index, self.project_controller.projects.items.len - 1);
    }
    self.project_controller.next_project_number = self.project_controller.projects.items.len + self.project_controller.archived_projects.items.len + 1;
    try self.restorePersistedSurfaceStates(persisted.surface_states);
    self.restorePersistedChatCompletions(persisted.chat_completions);
    self.syncRenameBuffer();
    self.requestTranscriptScrollToBottom();
    self.lifecycle.dirty = cleaned_legacy_companion;
}

pub fn restorePersistedSurfaceStates(self: anytype, persisted_surfaces: []const PersistedSurfaceState) !void {
    // Hook events can arrive while the async app-state load is still in
    // flight. Only let the durable snapshot replace an in-memory state when
    // it is at least as recent as the live event.
    for (persisted_surfaces) |persisted| {
        const surface = self.surfaceBySessionId(persisted.session_id);
        if (surface == null) {
            try self.surface_controller.surfaces.append(self.allocator, .{
                .session_id = try self.allocator.dupe(u8, persisted.session_id),
                .workspace_id = try self.allocator.dupe(u8, persisted.workspace_id),
                .workspace_path = try self.allocator.dupe(u8, persisted.workspace_path),
                .dock_id = persisted.dock_id,
                .pane_id = persisted.pane_id,
                .provider = persisted.provider,
                .provider_thread_id = if (persisted.provider_thread_id) |value| try self.allocator.dupe(u8, value) else null,
                .title = try self.allocator.dupe(u8, persisted.title),
                .status = persisted.status,
                .status_changed_at_ms = persisted.status_changed_at_ms,
                .completion_pending = persisted.status == .done,
                .completed_at_ms = if (persisted.status == .done) persisted.completed_at_ms else 0,
                .last_event_title = if (persisted.last_event_title) |value| try self.allocator.dupe(u8, value) else null,
                .last_event_body = if (persisted.last_event_body) |value| try self.allocator.dupe(u8, value) else null,
                .last_event_at_ms = persisted.status_changed_at_ms,
            });
            continue;
        }

        var restored = surface.?;
        if (restored.status_changed_at_ms > persisted.status_changed_at_ms) continue;
        try replaceOwnedSlice(self.allocator, &restored.workspace_id, persisted.workspace_id);
        try replaceOwnedSlice(self.allocator, &restored.workspace_path, persisted.workspace_path);
        restored.dock_id = persisted.dock_id;
        restored.pane_id = persisted.pane_id;
        restored.provider = persisted.provider;
        try replaceOwnedOptionalSlice(self.allocator, &restored.provider_thread_id, persisted.provider_thread_id);
        try replaceOwnedSlice(self.allocator, &restored.title, persisted.title);
        try replaceOwnedOptionalSlice(self.allocator, &restored.last_event_title, persisted.last_event_title);
        try replaceOwnedOptionalSlice(self.allocator, &restored.last_event_body, persisted.last_event_body);
        restored.status = persisted.status;
        restored.status_changed_at_ms = persisted.status_changed_at_ms;
        restored.completion_pending = persisted.status == .done;
        restored.completed_at_ms = if (persisted.status == .done) persisted.completed_at_ms else 0;
        restored.last_event_at_ms = persisted.status_changed_at_ms;
    }
}

pub fn restorePersistedChatCompletions(self: anytype, completions: []const PersistedChatCompletion) void {
    for (self.project_controller.projects.items) |*project| {
        clearProjectChatCompletionFlags(project);
        restoreProjectChatCompletions(project, completions);
    }
    for (self.project_controller.archived_projects.items) |*project| {
        clearProjectChatCompletionFlags(project);
        restoreProjectChatCompletions(project, completions);
    }
}

pub fn clearProjectChatCompletionFlags(project: *Project) void {
    for (project.threads.items) |*thread| {
        thread.completion_pending = false;
        thread.completed_at_ms = 0;
    }
    for (project.archived_threads.items) |*thread| {
        thread.completion_pending = false;
        thread.completed_at_ms = 0;
    }
}

pub fn restoreProjectChatCompletions(project: *Project, completions: []const PersistedChatCompletion) void {
    for (completions) |completion| {
        if (!std.mem.eql(u8, project.id, completion.workspace_id)) continue;
        for (project.threads.items) |*thread| {
            if (!std.mem.eql(u8, thread.local_thread_id, completion.local_thread_id)) continue;
            thread.completion_pending = true;
            thread.completed_at_ms = completion.completed_at_ms;
            break;
        }
        for (project.archived_threads.items) |*thread| {
            if (!std.mem.eql(u8, thread.local_thread_id, completion.local_thread_id)) continue;
            thread.completion_pending = true;
            thread.completed_at_ms = completion.completed_at_ms;
            break;
        }
    }
}

pub fn buildPersistedState(self: anytype, backing_allocator: std.mem.Allocator) !LoadedPersistedState {
    return buildSnapshot(.{
        .projects = self.project_controller.projects.items,
        .archived_projects = self.project_controller.archived_projects.items,
        .selected_project_index = self.project_controller.selected_index,
        .sidebar_collapsed = self.sidebar_collapsed,
    }, backing_allocator);
}

/// Deep-copy a persistence projection into one arena. Conflict recovery keeps
/// the last daemon projection as its three-way merge baseline while frame
/// state continues to mutate independently.
pub fn clonePersistedState(
    backing_allocator: std.mem.Allocator,
    source: PersistedState,
) !LoadedPersistedState {
    var loaded = LoadedPersistedState.init(backing_allocator);
    errdefer loaded.deinit();
    const arena = loaded.allocator();
    const encoded = try std.json.Stringify.valueAlloc(arena, source, .{});
    loaded.value = try std.json.parseFromSliceLeaky(PersistedState, arena, encoded, .{
        .allocate = .alloc_always,
    });
    return loaded;
}

pub fn applyPersistedTerminalDocksJson(self: anytype, project: *Project, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return;
    for (parsed.value.array.items) |entry_value| {
        if (entry_value != .object) continue;
        const dock_id: u32 = @intCast(appJsonInt(entry_value.object.get("id") orelse .null) orelse continue);
        if (dock_id == 0) continue;
        var entry = project.terminalDockEntryById(dock_id);
        if (entry == null) {
            var dock = try terminal.Dock.init(self.allocator);
            dock.setDefaultFontSize(self.app_config.terminal_font_size);
            errdefer dock.deinit(self.allocator);
            try project.terminal_docks.append(self.allocator, .{ .id = dock_id, .dock = dock });
            entry = &project.terminal_docks.items[project.terminal_docks.items.len - 1];
        }
        if (entry_value.object.get("layout")) |layout_value| {
            if (appJsonString(layout_value)) |layout_json| {
                entry.?.dock.applyPersistedLayoutJson(self.allocator, layout_json) catch |err| {
                    log.warn("failed to restore terminal dock {d} layout: {s}", .{ dock_id, @errorName(err) });
                };
            }
        }
        if (project.next_terminal_dock_id <= dock_id) project.next_terminal_dock_id = dock_id + 1;
    }
}

pub fn appJsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

pub fn appJsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

test "message identities survive the genuine snapshot chain into a real store" {
    // M4-P4 fix: the REAL GUI writer chain — projection ChatThread (adopted
    // ids) → threadSnapshot → persistedStateToProtocolSnapshot → daemon store
    // applySnapshot — must preserve daemon-minted and client identities and
    // mint `snap-msg-{i}` only for legacy id-less rows.
    const store_mod = @import("../daemon/store.zig");
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.joinZ(allocator, &.{ path_buf[0..path_len], "state.sqlite" });
    defer allocator.free(db_path);

    var thread = try ChatThread.init(allocator, "Identity thread");
    defer thread.deinit(allocator);
    thread.committed = true;
    try thread.messages.append(allocator, .{
        .role = .user,
        .author = try allocator.dupeZ(u8, "You"),
        .body = try allocator.dupeZ(u8, "hello"),
        .message_id = try allocator.dupe(u8, "gui-msg:ws-id:t:1"),
    });
    try thread.messages.append(allocator, .{
        .role = .assistant,
        .author = try allocator.dupeZ(u8, "Codex"),
        .body = try allocator.dupeZ(u8, "reply"),
        .message_id = try allocator.dupe(u8, "turn:turn-x:msg:1"),
    });
    try thread.messages.append(allocator, .{
        .role = .system,
        .author = try allocator.dupeZ(u8, "System"),
        .body = try allocator.dupeZ(u8, "legacy row"),
    });

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const persisted_thread = try threadSnapshot(arena, &thread);
    const persisted_threads = [_]PersistedThread{persisted_thread};
    const projects = [_]PersistedProject{.{
        .id = "ws-id",
        .label = "Identity workspace",
        .path = "/tmp/ws-id",
        .threads = &persisted_threads,
    }};
    const state: PersistedState = .{ .projects = &projects };
    const snapshot = try persistedStateToProtocolSnapshot(arena, state, 0);
    const wire_messages = snapshot.workspaces[0].threads[0].messages;
    try std.testing.expectEqual(@as(usize, 3), wire_messages.len);
    try std.testing.expectEqualStrings("gui-msg:ws-id:t:1", wire_messages[0].message_id);
    try std.testing.expectEqualStrings("turn:turn-x:msg:1", wire_messages[1].message_id);
    try std.testing.expectEqualStrings("snap-msg-2", wire_messages[2].message_id);

    var writer = try store_mod.Store.init(allocator, db_path);
    defer writer.deinit();
    _ = try writer.replaceSnapshot(.{
        .mutation = .{
            .request_key = "identity-chain-flush",
            .client_id = "test-client",
            // Non-bootstrap snapshots require an explicit guard; a fresh
            // store sits at revision 0.
            .expected_store_revision = 0,
        },
        .snapshot = snapshot,
        .bootstrap = false,
    });

    var rows = try writer.conn.rows("select message_id from messages order by sort_index", .{});
    defer rows.deinit();
    const expected_ids = [_][]const u8{ "gui-msg:ws-id:t:1", "turn:turn-x:msg:1", "snap-msg-2" };
    var row_count: usize = 0;
    while (rows.next()) |row| : (row_count += 1) {
        try std.testing.expect(row_count < expected_ids.len);
        try std.testing.expectEqualStrings(expected_ids[row_count], row.text(0));
    }
    if (rows.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 3), row_count);
}

pub fn seedDefaultState(self: anytype) !void {
    self.project_controller.selected_index = 0;
    self.project_controller.next_project_number = 1;
    self.syncRenameBuffer();
    self.requestTranscriptScrollToBottom();
    self.lifecycle.dirty = false;
}
