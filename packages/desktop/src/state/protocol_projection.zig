//! Conversion from std-only daemon storage DTOs to the desktop projection.

const std = @import("std");
const headless = @import("headless");
const db_types = @import("../db/types.zig");

fn snapshotEnum(comptime T: type, value: ?[]const u8, fallback: T) T {
    const text = value orelse return fallback;
    return std.meta.stringToEnum(T, text) orelse fallback;
}

fn snapshotOptionalEnum(comptime T: type, value: ?[]const u8) ?T {
    const text = value orelse return null;
    return std.meta.stringToEnum(T, text);
}

fn snapshotAttachment(source: ?headless.store.Attachment) ?db_types.PersistedImageAttachment {
    const image = source orelse return null;
    return .{ .path = image.path, .mime = image.mime, .byte_size = image.byte_size };
}

fn snapshotAttachmentExtras(
    allocator: std.mem.Allocator,
    images: []const headless.store.Attachment,
) ![]const db_types.PersistedImageAttachment {
    if (images.len <= 1) return &.{};
    const out = try allocator.alloc(db_types.PersistedImageAttachment, images.len - 1);
    for (images[1..], 0..) |image, index| out[index] = snapshotAttachment(image).?;
    return out;
}

fn snapshotMessageToPersisted(
    allocator: std.mem.Allocator,
    message: headless.store.Message,
) !db_types.PersistedMessage {
    const image = if (message.images.len > 0) message.images[0] else message.image;
    return .{
        .role = snapshotEnum(db_types.ChatRole, message.role, .system),
        .author = message.author,
        .body = message.body,
        .image = snapshotAttachment(image),
        .extra_images = try snapshotAttachmentExtras(allocator, message.images),
        .tool_call_id = message.tool_call_id,
        .tool_call_kind = snapshotOptionalEnum(headless.provider_types.ToolCallKind, message.tool_call_kind),
        .tool_call_status = snapshotOptionalEnum(headless.provider_types.ToolCallStatus, message.tool_call_status),
        .message_id = if (message.message_id.len == 0) null else message.message_id,
    };
}

pub fn messagesToPersisted(
    allocator: std.mem.Allocator,
    messages: []const headless.store.Message,
) ![]db_types.PersistedMessage {
    const out = try allocator.alloc(db_types.PersistedMessage, messages.len);
    for (messages, 0..) |message, index| out[index] = try snapshotMessageToPersisted(allocator, message);
    return out;
}

fn snapshotThreadToPersisted(
    allocator: std.mem.Allocator,
    thread: headless.store.Thread,
) !db_types.PersistedThread {
    return .{
        .title = thread.title,
        .archived = thread.archived,
        .committed = thread.committed,
        .local_thread_id = thread.local_thread_id,
        .last_activity_at = thread.last_activity_at,
        .provider_thread_id = thread.provider_thread_id,
        .model_ref = thread.model_ref,
        .reasoning_effort = snapshotOptionalEnum(db_types.ReasoningEffort, thread.reasoning_effort),
        .reasoning_variant = thread.reasoning_variant,
        .fast_mode = snapshotOptionalEnum(db_types.FastMode, thread.fast_mode),
        .access_mode = snapshotOptionalEnum(db_types.AccessMode, thread.access_mode),
        .provider = snapshotEnum(db_types.Provider, thread.provider, .opencode),
        .harness = snapshotEnum(db_types.Harness, thread.harness, .local_cli),
        .tui_dock_id = thread.tui_dock_id,
        .cwd = thread.cwd,
        .profile_id = thread.profile_id,
        .runtime_id = thread.runtime_id,
        .repository_id = thread.repository_id,
        .repository_cwd = thread.repository_cwd,
        .draft = thread.draft,
        .draft_image = snapshotAttachment(thread.draft_image),
        .draft_extra_images = try snapshotAttachmentExtras(allocator, thread.draft_images),
        .message_offset = thread.message_offset,
        .messages = try messagesToPersisted(allocator, thread.messages),
    };
}

fn snapshotWorkspaceToPersisted(
    allocator: std.mem.Allocator,
    workspace: headless.store.Workspace,
) !db_types.PersistedProject {
    const threads = try allocator.alloc(db_types.PersistedThread, workspace.threads.len);
    for (workspace.threads, 0..) |thread, index| {
        threads[index] = try snapshotThreadToPersisted(allocator, thread);
    }
    const herdr_link: ?db_types.PersistedHerdrWorkspaceLink = if (workspace.herdr_link) |link| .{
        .remote_alias = link.remote_alias,
        .session_name = link.session_name,
        .workspace_id = link.workspace_id,
        .local_dir = link.local_dir,
        .remote_cwd = link.remote_cwd,
        .last_pane_id = link.last_pane_id,
        .attach_dock_id = link.attach_dock_id,
        .attach_pane_id = link.attach_pane_id,
        .pane_links_json = link.pane_links_json,
        .updated_at_ms = link.updated_at_ms,
    } else null;
    return .{
        .id = workspace.workspace_id,
        .label = workspace.label,
        .path = workspace.path,
        .archived = workspace.archived,
        .unread_count = @intCast(@min(workspace.unread_count, std.math.maxInt(u8))),
        .collapsed = workspace.collapsed,
        .thread_list_expanded = workspace.thread_list_expanded,
        .terminal_height = workspace.terminal_height,
        .terminal_layout_json = workspace.terminal_layout_json,
        .terminal_docks_json = workspace.terminal_docks_json,
        .workspace_layout_json = workspace.workspace_layout_json,
        .selected_thread_index = workspace.selected_thread_index,
        .companion_thread_local_id = workspace.companion_thread_local_id,
        .herdr_link = herdr_link,
        .threads = threads,
        .provider = snapshotEnum(db_types.Provider, workspace.provider, .opencode),
        .harness = snapshotEnum(db_types.Harness, workspace.harness, .local_cli),
        .draft = workspace.draft,
        .messages = try messagesToPersisted(allocator, workspace.messages),
    };
}

/// Convert a daemon snapshot into the desktop's in-memory projection shape.
/// String storage remains owned by the decoded RPC response; callers that
/// outlive it must clone or apply the projection before releasing that arena.
pub fn snapshotToPersisted(
    allocator: std.mem.Allocator,
    snapshot: headless.store.Snapshot,
) !db_types.PersistedState {
    const projects = try allocator.alloc(db_types.PersistedProject, snapshot.workspaces.len);
    for (snapshot.workspaces, 0..) |workspace, index| {
        projects[index] = try snapshotWorkspaceToPersisted(allocator, workspace);
    }
    const surfaces = try allocator.alloc(db_types.PersistedSurfaceState, snapshot.surface_states.len);
    for (snapshot.surface_states, 0..) |surface, index| {
        surfaces[index] = .{
            .session_id = surface.session_id,
            .workspace_id = surface.workspace_id,
            .workspace_path = surface.workspace_path,
            .dock_id = surface.dock_id,
            .pane_id = surface.pane_id,
            .provider = snapshotOptionalEnum(db_types.SurfaceProvider, surface.provider),
            .provider_thread_id = surface.provider_thread_id,
            .title = surface.title,
            .status = snapshotEnum(db_types.SurfaceStatus, surface.status, .idle),
            .status_changed_at_ms = surface.status_changed_at_ms,
            .completed_at_ms = surface.completed_at_ms,
            .last_event_title = surface.last_event_title,
            .last_event_body = surface.last_event_body,
        };
    }
    const completions = try allocator.alloc(db_types.PersistedChatCompletion, snapshot.chat_completions.len);
    for (snapshot.chat_completions, 0..) |completion, index| {
        completions[index] = .{
            .workspace_id = completion.workspace_id,
            .local_thread_id = completion.local_thread_id,
            .completed_at_ms = completion.completed_at_ms,
        };
    }
    return .{
        .selected_project_index = snapshot.selected_workspace_index,
        .sidebar_collapsed = snapshot.sidebar_collapsed,
        .projects = projects,
        .surface_states = surfaces,
        .chat_completions = completions,
        .provider = snapshotOptionalEnum(db_types.Provider, snapshot.provider),
        .harness = snapshotOptionalEnum(db_types.Harness, snapshot.harness),
        .draft = snapshot.draft,
        .messages = if (snapshot.messages) |messages| try messagesToPersisted(allocator, messages) else null,
    };
}
