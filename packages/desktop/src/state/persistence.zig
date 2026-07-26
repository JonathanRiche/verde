//! Persistence snapshot construction and asynchronous schema writes.

const std = @import("std");
const db_client = @import("../db/client.zig");
const db_types = @import("../db/types.zig");
const chat_types = @import("chat_types.zig");
const project_state = @import("project.zig");

const log = std.log.scoped(.native_shell);
const LoadedPersistedState = db_types.LoadedState;
const PersistedImageAttachment = db_types.PersistedImageAttachment;
const PersistedMessage = db_types.PersistedMessage;
const PersistedProject = db_types.PersistedProject;
const PersistedThread = db_types.PersistedThread;
const ChatImageAttachment = chat_types.ChatImageAttachment;
const ChatMessage = chat_types.ChatMessage;
const ChatThread = chat_types.ChatThread;
const Project = project_state.Project;

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

    for (project.threads.items) |thread| {
        if (!project.archived and !thread.committed) continue;
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
        .herdr_link = if (project.herdr_link) |*link| try link.toPersisted(allocator) else null,
        .threads = try threads.toOwnedSlice(allocator),
    };
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

pub fn saveWorker(pref_path: []u8, loaded_state: LoadedPersistedState) void {
    var loaded = loaded_state;
    defer loaded.deinit();
    defer std.heap.page_allocator.free(pref_path);

    var client = db_client.Client.init(std.heap.page_allocator, pref_path) catch |err| {
        log.err("failed to initialize async native state save: {s}", .{@errorName(err)});
        return;
    };
    defer client.deinit();

    client.save(loaded.value) catch |err| {
        log.err("failed to save native state: {s}", .{@errorName(err)});
    };
}
