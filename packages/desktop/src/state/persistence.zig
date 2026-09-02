//! Persistence snapshot construction and daemon-routed compatibility payloads.
//!
//! Phase 3: the detached SQLite save worker is gone. Snapshot construction
//! remains as the compatibility payload for `state.snapshot.replace`; actual
//! commits run in the endpoint-owning daemon.

const std = @import("std");
const headless = @import("headless");
const db_types = @import("../db/types.zig");
const thread_binding = @import("../runtime/thread_binding.zig");
const terminal = @import("../terminal/terminal.zig");
const chat_types = @import("chat_types.zig");
const herdr_types = @import("herdr_types.zig");
const project_state = @import("project.zig");

const log = std.log.scoped(.native_shell);
const LoadedPersistedState = db_types.LoadedState;
const PersistedState = db_types.PersistedState;
const PersistedSurfaceState = db_types.PersistedSurfaceState;
const PersistedChatCompletion = db_types.PersistedChatCompletion;
const PersistedHerdrWorkspaceLink = db_types.PersistedHerdrWorkspaceLink;
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

/// Incremental copies of transcript bodies for one compatibility snapshot.
///
/// Message bodies dominate real-world state size. The SDL thread copies them
/// in bounded slices over multiple presented frames, then the persistence
/// worker deep-copies the completed borrowed projection before transport.
/// `dirty_generation` invalidates this capture before another slice can read
/// live storage after any mutation.
pub const IncrementalBodyCapture = struct {
    const Entry = struct {
        source: []const u8,
        copied: []u8,
    };

    allocator: std.mem.Allocator,
    dirty_generation: u64,
    entries: std.ArrayList(Entry) = .empty,
    entry_index: usize = 0,
    entry_offset: usize = 0,
    copied_bytes: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        context: SnapshotContext,
        dirty_generation: u64,
    ) !IncrementalBodyCapture {
        var capture: IncrementalBodyCapture = .{
            .allocator = allocator,
            .dirty_generation = dirty_generation,
        };
        errdefer capture.deinit();

        for (context.projects) |project| try capture.appendProject(&project);
        for (context.archived_projects) |project| try capture.appendProject(&project);
        return capture;
    }

    pub fn deinit(self: *IncrementalBodyCapture) void {
        for (self.entries.items) |entry| self.allocator.free(entry.copied);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Copy at most `byte_budget` bytes. Returns true when every body is stable.
    pub fn advance(self: *IncrementalBodyCapture, byte_budget: usize) bool {
        var remaining = byte_budget;
        while (remaining > 0 and self.entry_index < self.entries.items.len) {
            const entry = &self.entries.items[self.entry_index];
            const available = entry.source.len - self.entry_offset;
            if (available == 0) {
                self.entry_index += 1;
                self.entry_offset = 0;
                continue;
            }
            const count = @min(available, remaining);
            @memcpy(
                entry.copied[self.entry_offset..][0..count],
                entry.source[self.entry_offset..][0..count],
            );
            self.entry_offset += count;
            self.copied_bytes += count;
            remaining -= count;
        }
        while (self.entry_index < self.entries.items.len and
            self.entry_offset == self.entries.items[self.entry_index].source.len)
        {
            self.entry_index += 1;
            self.entry_offset = 0;
        }
        return self.entry_index == self.entries.items.len;
    }

    fn appendProject(self: *IncrementalBodyCapture, project: *const Project) !void {
        const retained_thread_index = lastRetainedActiveThreadIndex(project);
        for (project.threads.items, 0..) |*thread, thread_index| {
            if (!project.archived and (retained_thread_index == null or thread_index > retained_thread_index.?)) continue;
            try self.appendThread(thread);
        }
        for (project.archived_threads.items) |*thread| try self.appendThread(thread);
    }

    fn appendThread(self: *IncrementalBodyCapture, thread: *const ChatThread) !void {
        try self.entries.ensureUnusedCapacity(self.allocator, thread.messages.items.len);
        for (thread.messages.items) |message| {
            const copied = try self.allocator.alloc(u8, message.body.len);
            self.entries.appendAssumeCapacity(.{ .source = message.body, .copied = copied });
        }
    }
};

pub fn buildSnapshot(context: SnapshotContext, backing_allocator: std.mem.Allocator) !LoadedPersistedState {
    return buildSnapshotWithBodies(context, backing_allocator, null);
}

/// Finalize the bounded body capture into a projection whose body slices are
/// borrowed from `body_capture`. The caller must keep the capture alive until
/// the worker has made its deep-owned copy.
pub fn buildSnapshotFromBodyCapture(
    context: SnapshotContext,
    backing_allocator: std.mem.Allocator,
    body_capture: *const IncrementalBodyCapture,
) !LoadedPersistedState {
    std.debug.assert(body_capture.entry_index == body_capture.entries.items.len);
    return buildSnapshotWithBodies(context, backing_allocator, body_capture.entries.items);
}

fn buildSnapshotWithBodies(
    context: SnapshotContext,
    backing_allocator: std.mem.Allocator,
    captured_bodies: ?[]const IncrementalBodyCapture.Entry,
) !LoadedPersistedState {
    var loaded = LoadedPersistedState.init(backing_allocator);
    errdefer loaded.deinit();

    const arena = loaded.allocator();
    var projects: std.ArrayList(PersistedProject) = .empty;
    defer projects.deinit(arena);

    var body_index: usize = 0;
    for (context.projects) |project| {
        try projects.append(arena, try persistedProjectSnapshot(arena, &project, captured_bodies, &body_index));
    }
    for (context.archived_projects) |project| {
        try projects.append(arena, try persistedProjectSnapshot(arena, &project, captured_bodies, &body_index));
    }
    if (captured_bodies) |bodies| std.debug.assert(body_index == bodies.len);

    loaded.value = .{
        .selected_project_index = context.selected_project_index,
        .sidebar_collapsed = context.sidebar_collapsed,
        .projects = try projects.toOwnedSlice(arena),
    };
    return loaded;
}

fn persistedProjectSnapshot(
    allocator: std.mem.Allocator,
    project: *const Project,
    captured_bodies: ?[]const IncrementalBodyCapture.Entry,
    body_index: *usize,
) !PersistedProject {
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
        try threads.append(allocator, try threadSnapshotWithBodies(allocator, &thread, captured_bodies, body_index));
    }
    for (project.archived_threads.items) |thread| {
        try threads.append(allocator, try threadSnapshotWithBodies(allocator, &thread, captured_bodies, body_index));
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

test "incremental snapshot body capture is bounded and finalizes exact transcript bytes" {
    const allocator = std.testing.allocator;
    var projects: [1]Project = .{try Project.init(allocator, "workspace-id", "Workspace", "/tmp/workspace", 0)};
    defer projects[0].deinit(allocator);
    const thread = &projects[0].threads.items[0];
    thread.committed = true;
    const author = try allocator.dupeZ(u8, "Assistant");
    errdefer allocator.free(author);
    const body = try allocator.dupeZ(u8, "0123456789abcdef");
    errdefer allocator.free(body);
    const extra_images = try allocator.alloc(ChatImageAttachment, 0);
    errdefer allocator.free(extra_images);
    try thread.messages.append(allocator, .{
        .role = .assistant,
        .author = author,
        .body = body,
        .extra_images = extra_images,
    });

    const context: SnapshotContext = .{
        .projects = &projects,
        .archived_projects = &.{},
        .selected_project_index = 0,
        .sidebar_collapsed = false,
    };
    var capture = try IncrementalBodyCapture.init(allocator, context, 7);
    defer capture.deinit();
    try std.testing.expectEqual(@as(u64, 7), capture.dirty_generation);
    try std.testing.expect(!capture.advance(5));
    try std.testing.expectEqual(@as(usize, 5), capture.copied_bytes);
    try std.testing.expect(capture.advance(64));

    var snapshot = try buildSnapshotFromBodyCapture(context, allocator, &capture);
    defer snapshot.deinit();
    const persisted_body = snapshot.value.projects[0].threads.?[0].messages[0].body;
    try std.testing.expectEqualStrings(body, persisted_body);
    try std.testing.expect(persisted_body.ptr != body.ptr);
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

test "terminal dock snapshot payload round trips through production consumer" {
    const allocator = std.testing.allocator;
    const layout_json =
        \\{"active_tab_index":0,"font_scale":1.125,"tabs":[{"title":"build","active_pane_id":7,"root_node_id":1,"nodes":[{"node_id":1,"kind":"leaf","pane_id":7,"session_id":"session-seven","revive_policy":"attach_or_create"}]}]}
    ;

    var source = try Project.init(allocator, "dock-source", "Dock source", "/tmp/dock-source", 0);
    defer source.deinit(allocator);
    var source_dock = try terminal.Dock.init(allocator);
    try source_dock.applyPersistedLayoutJson(allocator, layout_json);
    source.terminal_docks.append(allocator, .{ .id = 4, .dock = source_dock }) catch |err| {
        source_dock.deinit(allocator);
        return err;
    };

    const source_projects = [_]Project{source};
    var snapshot = try buildSnapshot(.{
        .projects = &source_projects,
        .archived_projects = &.{},
        .selected_project_index = 0,
        .sidebar_collapsed = false,
    }, allocator);
    defer snapshot.deinit();
    const docks_json = snapshot.value.projects[0].terminal_docks_json orelse return error.TestExpectedEqual;

    var restored = try Project.init(allocator, "dock-restored", "Dock restored", "/tmp/dock-restored", 0);
    defer restored.deinit(allocator);
    const Consumer = struct {
        allocator: std.mem.Allocator,
        app_config: struct { terminal_font_size: f32 = 13.0 } = .{},
    };
    var consumer: Consumer = .{ .allocator = allocator };
    try applyPersistedTerminalDocksJson(&consumer, &restored, docks_json);

    try std.testing.expectEqual(@as(usize, 1), restored.terminal_docks.items.len);
    try std.testing.expectEqual(@as(u32, 4), restored.terminal_docks.items[0].id);
    const restored_pane = restored.terminal_docks.items[0].dock.activePaneConst() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 7), restored_pane.id);
    try std.testing.expectEqualStrings("session-seven", restored_pane.session_id.?);
    try std.testing.expectEqual(@as(u32, 5), restored.next_terminal_dock_id);
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
    var body_index: usize = 0;
    return threadSnapshotWithBodies(allocator, thread, null, &body_index);
}

fn threadSnapshotWithBodies(
    allocator: std.mem.Allocator,
    thread: *const ChatThread,
    captured_bodies: ?[]const IncrementalBodyCapture.Entry,
    body_index: *usize,
) !PersistedThread {
    var messages: std.ArrayList(PersistedMessage) = .empty;
    defer messages.deinit(allocator);

    for (thread.messages.items) |message| {
        const captured_body = if (captured_bodies) |bodies| blk: {
            if (body_index.* >= bodies.len) return error.InvalidIncrementalSnapshot;
            const entry = bodies[body_index.*];
            body_index.* += 1;
            if (entry.source.len != message.body.len) return error.InvalidIncrementalSnapshot;
            break :blk entry.copied;
        } else null;
        try messages.append(allocator, try persistedMessageSnapshot(allocator, &message, captured_body));
    }

    const route = thread.selectedRuntimeRoute();
    const pinned_route = thread.pinnedRuntimeRoute();
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
        .cwd = try dupeOptionalSlice(allocator, thread.cwd),
        .profile_id = try allocator.dupe(u8, route.profile_id),
        .runtime_id = try dupeOptionalSlice(
            allocator,
            if (pinned_route) |pinned| pinned.runtime_id else null,
        ),
        .repository_id = try allocator.dupe(u8, route.repository_id),
        .repository_cwd = try dupeOptionalSlice(allocator, route.relative_cwd),
        .draft = try allocator.dupe(u8, thread.currentDraft()),
        .draft_image = try imageSnapshot(allocator, thread.draft_image),
        .draft_extra_images = try imageListSnapshot(allocator, thread.draft_extra_images.items),
        .message_offset = thread.persisted_message_offset,
        .messages = try messages.toOwnedSlice(allocator),
    };
}

fn persistedMessageSnapshot(
    allocator: std.mem.Allocator,
    message: *const ChatMessage,
    captured_body: ?[]const u8,
) !PersistedMessage {
    return .{
        .role = message.role,
        .author = try allocator.dupe(u8, message.author),
        .body = captured_body orelse try allocator.dupe(u8, message.body),
        .image = try imageSnapshot(allocator, message.image),
        .extra_images = try imageListSnapshot(allocator, message.extra_images),
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

pub fn chatImageListFromPersisted(
    allocator: std.mem.Allocator,
    images: []const PersistedImageAttachment,
) ![]ChatImageAttachment {
    if (images.len == 0) return &.{};
    const out = try allocator.alloc(ChatImageAttachment, images.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*image| image.deinit(allocator);
        allocator.free(out);
    }
    for (images) |image| {
        out[built] = try ChatImageAttachment.init(allocator, image.path, image.mime, image.byte_size);
        built += 1;
    }
    return out;
}

fn imageListSnapshot(
    allocator: std.mem.Allocator,
    images: []const ChatImageAttachment,
) ![]const PersistedImageAttachment {
    if (images.len == 0) return &.{};
    const out = try allocator.alloc(PersistedImageAttachment, images.len);
    for (images, 0..) |image, index| {
        out[index] = (try imageSnapshot(allocator, image)).?;
    }
    return out;
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
        .messages = if (state.messages) |msgs| try messagesToProtocol(allocator, msgs, 0) else null,
    };
}

fn projectToProtocol(allocator: std.mem.Allocator, project: PersistedProject) !headless.store.Workspace {
    const workspace_id = if (project.id) |id| try allocator.dupe(u8, id) else try allocator.dupe(u8, project.path);
    const threads: []const headless.store.Thread = if (project.threads) |src|
        try threadsToProtocol(allocator, src)
    else
        &.{};
    const messages: []const headless.store.Message = try messagesToProtocol(allocator, project.messages, 0);
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
        .herdr_link = if (project.herdr_link) |link|
            if (link.remote_alias.len == 0) try herdrToProtocol(allocator, link) else null
        else
            null,
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
        .cwd = if (thread.cwd) |v| try allocator.dupe(u8, v) else null,
        .profile_id = try dupeOptionalSlice(allocator, thread.profile_id),
        .runtime_id = try dupeOptionalSlice(allocator, thread.runtime_id),
        .repository_id = try dupeOptionalSlice(allocator, thread.repository_id),
        .repository_cwd = try dupeOptionalSlice(allocator, thread.repository_cwd),
        .draft = try allocator.dupe(u8, thread.draft),
        .draft_image = if (thread.draft_image) |img| try imageToProtocol(allocator, img) else null,
        .draft_images = try imageListToProtocol(allocator, thread.draft_image, thread.draft_extra_images),
        .message_offset = thread.message_offset,
        .messages = try messagesToProtocol(allocator, thread.messages, thread.message_offset),
    };
}

/// Build the wire full-list attachment shape ([primary] ++ extras). Empty
/// when there is no primary — extras cannot exist without one.
fn imageListToProtocol(
    allocator: std.mem.Allocator,
    primary: ?PersistedImageAttachment,
    extras: []const PersistedImageAttachment,
) ![]const headless.store.Attachment {
    const first = primary orelse return &.{};
    const out = try allocator.alloc(headless.store.Attachment, 1 + extras.len);
    out[0] = try imageToProtocol(allocator, first);
    for (extras, 0..) |extra, index| {
        out[index + 1] = try imageToProtocol(allocator, extra);
    }
    return out;
}

fn messagesToProtocol(
    allocator: std.mem.Allocator,
    messages: []const PersistedMessage,
    message_offset: usize,
) ![]const headless.store.Message {
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
                try std.fmt.allocPrint(allocator, "snap-msg-{d}", .{message_offset + i}),
            .role = try allocator.dupe(u8, @tagName(message.role)),
            .author = try allocator.dupe(u8, message.author),
            .body = try allocator.dupe(u8, message.body),
            .image = if (message.image) |img| try imageToProtocol(allocator, img) else null,
            .images = try imageListToProtocol(allocator, message.image, message.extra_images),
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

fn restoreThreadRuntimeRoute(
    allocator: std.mem.Allocator,
    thread: *ChatThread,
    persisted: PersistedThread,
) !void {
    const route_absent = persisted.profile_id == null and persisted.runtime_id == null and
        persisted.repository_id == null and persisted.repository_cwd == null;
    if (!route_absent and (persisted.profile_id == null or persisted.repository_id == null)) {
        // Only the all-null pre-routing shape is a legacy Local route. A
        // partial record could otherwise turn a corrupt/remote thread into a
        // locally executable one, so leave the durable projection untouched.
        return error.InvalidPersistedThreadRoute;
    }
    if (persisted.committed and persisted.profile_id != null and
        !std.mem.eql(u8, persisted.profile_id.?, chat_types.LOCAL_RUNTIME_PROFILE_ID) and
        persisted.runtime_id == null)
    {
        return error.InvalidPersistedThreadRoute;
    }
    const selection: thread_binding.Selection = .{
        .profile_id = persisted.profile_id orelse chat_types.LOCAL_RUNTIME_PROFILE_ID,
        .repository_id = persisted.repository_id orelse chat_types.PRIMARY_REPOSITORY_ID,
        .relative_cwd = persisted.repository_cwd,
    };
    const restored = thread_binding.ThreadBinding.initPersisted(
        allocator,
        selection,
        persisted.committed,
        persisted.runtime_id,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        log.err("persisted thread route quarantined err={s}", .{@errorName(err)});
        return error.InvalidPersistedThreadRoute;
    };
    thread.runtime_route.deinit(allocator);
    thread.runtime_route = restored;
}

test "thread runtime route snapshots and restores without migration" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Remote route");
    defer thread.deinit(allocator);
    try std.testing.expectEqual(.updated, try thread.selectRuntimeRoute(allocator, .{
        .profile_id = "profile-remote",
        .repository_id = "repo-api",
        .relative_cwd = "services/api",
    }));
    try thread.pinRuntimeRoute(allocator, "0123456789abcdef0123456789abcdef");
    thread.committed = true;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const persisted = try threadSnapshot(arena_state.allocator(), &thread);
    try std.testing.expectEqualStrings("profile-remote", persisted.profile_id.?);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", persisted.runtime_id.?);
    try std.testing.expectEqualStrings("repo-api", persisted.repository_id.?);
    try std.testing.expectEqualStrings("services/api", persisted.repository_cwd.?);

    var restored = try ChatThread.init(allocator, "Restored route");
    defer restored.deinit(allocator);
    try restoreThreadRuntimeRoute(allocator, &restored, persisted);
    restored.committed = persisted.committed;
    try std.testing.expectEqualStrings("profile-remote", restored.selectedRuntimeRoute().profile_id);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", restored.pinnedRuntimeRoute().?.runtime_id.?);
    try std.testing.expectEqual(.new_thread_required, try restored.selectRuntimeRoute(allocator, .{
        .profile_id = chat_types.LOCAL_RUNTIME_PROFILE_ID,
        .repository_id = chat_types.PRIMARY_REPOSITORY_ID,
    }));
}

test "only fully absent legacy route defaults to locked local primary" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Legacy route");
    defer thread.deinit(allocator);
    const legacy: PersistedThread = .{
        .title = "Legacy route",
        .committed = true,
    };
    try restoreThreadRuntimeRoute(allocator, &thread, legacy);
    thread.committed = true;
    const route = thread.selectedRuntimeRoute();
    try std.testing.expectEqualStrings(chat_types.LOCAL_RUNTIME_PROFILE_ID, route.profile_id);
    try std.testing.expectEqualStrings(chat_types.PRIMARY_REPOSITORY_ID, route.repository_id);
    try std.testing.expect(thread.pinnedRuntimeRoute().?.runtime_id == null);
    try std.testing.expectEqual(.new_thread_required, try thread.selectRuntimeRoute(allocator, .{
        .profile_id = "remote-box",
        .repository_id = chat_types.PRIMARY_REPOSITORY_ID,
    }));

    const explicit_local: PersistedThread = .{
        .title = "Explicit local",
        .committed = true,
        .profile_id = chat_types.LOCAL_RUNTIME_PROFILE_ID,
        .repository_id = chat_types.PRIMARY_REPOSITORY_ID,
    };
    try restoreThreadRuntimeRoute(allocator, &thread, explicit_local);
    try std.testing.expect(thread.pinnedRuntimeRoute().?.runtime_id == null);
}

test "partial or malformed committed routes stay quarantined" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "Quarantined route");
    defer thread.deinit(allocator);
    try std.testing.expectEqual(.updated, try thread.selectRuntimeRoute(allocator, .{
        .profile_id = "quarantine-sentinel",
        .repository_id = "opaque-repository",
    }));
    try thread.pinRuntimeRoute(allocator, "fedcba9876543210fedcba9876543210");

    const partial: PersistedThread = .{
        .title = "Partial",
        .committed = true,
        .profile_id = "unknown-remote",
    };
    try std.testing.expectError(
        error.InvalidPersistedThreadRoute,
        restoreThreadRuntimeRoute(allocator, &thread, partial),
    );
    try std.testing.expectEqualStrings("quarantine-sentinel", thread.selectedRuntimeRoute().profile_id);
    try std.testing.expectEqualStrings(
        "fedcba9876543210fedcba9876543210",
        thread.pinnedRuntimeRoute().?.runtime_id.?,
    );

    const malformed: PersistedThread = .{
        .title = "Malformed",
        .committed = true,
        .profile_id = "unknown-remote",
        .runtime_id = "not-a-runtime-id",
        .repository_id = "primary",
    };
    try std.testing.expectError(
        error.InvalidPersistedThreadRoute,
        restoreThreadRuntimeRoute(allocator, &thread, malformed),
    );
    try std.testing.expectEqualStrings("quarantine-sentinel", thread.selectedRuntimeRoute().profile_id);
    try std.testing.expectEqualStrings(
        "fedcba9876543210fedcba9876543210",
        thread.pinnedRuntimeRoute().?.runtime_id.?,
    );

    const unpinned_remote: PersistedThread = .{
        .title = "Unpinned remote",
        .committed = true,
        .profile_id = "unknown-remote",
        .repository_id = "primary",
    };
    try std.testing.expectError(
        error.InvalidPersistedThreadRoute,
        restoreThreadRuntimeRoute(allocator, &thread, unpinned_remote),
    );
    try std.testing.expectEqualStrings("quarantine-sentinel", thread.selectedRuntimeRoute().profile_id);

    const unknown: PersistedThread = .{
        .title = "Unknown",
        .committed = true,
        .profile_id = "unknown-remote",
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .repository_id = "primary",
    };
    try restoreThreadRuntimeRoute(allocator, &thread, unknown);
    thread.committed = true;
    try std.testing.expectEqualStrings("unknown-remote", thread.selectedRuntimeRoute().profile_id);
    try std.testing.expectEqual(.new_thread_required, try thread.selectRuntimeRoute(allocator, .{
        .profile_id = chat_types.LOCAL_RUNTIME_PROFILE_ID,
        .repository_id = chat_types.PRIMARY_REPOSITORY_ID,
    }));
}

pub fn applyPersisted(self: anytype, persisted: PersistedState) !void {
    var cleaned_legacy_companion = false;
    var cleaned_legacy_remote_herdr = false;
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
            if (link.remote_alias.len == 0) {
                loaded.herdr_link = try HerdrWorkspaceLink.initFromPersisted(self.allocator, link);
            } else {
                // Remote Herdr links from older builds are intentionally
                // unlinked. Preserve the workspace itself and persist the
                // cleanup without attempting SSH or treating remote paths as local.
                cleaned_legacy_remote_herdr = true;
            }
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
                var thread_owned = true;
                errdefer if (thread_owned) thread.deinit(self.allocator);
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
                if (thread.cwd) |v| self.allocator.free(v);
                thread.cwd = if (persisted_thread.cwd) |cwd|
                    try self.allocator.dupeZ(u8, cwd)
                else
                    null;
                try restoreThreadRuntimeRoute(self.allocator, &thread, persisted_thread);
                thread.persisted_message_offset = persisted_thread.message_offset;
                thread.setDraft(persisted_thread.draft);
                if (persisted_thread.draft_image) |image| {
                    try thread.setDraftImage(self.allocator, image.path, image.mime, image.byte_size);
                    for (persisted_thread.draft_extra_images) |extra| {
                        try thread.addDraftImage(self.allocator, extra.path, extra.mime, extra.byte_size);
                    }
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
                        .extra_images = try chatImageListFromPersisted(self.allocator, message.extra_images),
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
                thread_owned = false;
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
                    .extra_images = try chatImageListFromPersisted(self.allocator, message.extra_images),
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
    self.lifecycle.dirty = cleaned_legacy_companion or cleaned_legacy_remote_herdr;
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

fn cloneOptionalSlice(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |slice| try allocator.dupe(u8, slice) else null;
}

fn cloneImage(allocator: std.mem.Allocator, value: ?PersistedImageAttachment) !?PersistedImageAttachment {
    const image = value orelse return null;
    return .{
        .path = try allocator.dupe(u8, image.path),
        .mime = try allocator.dupe(u8, image.mime),
        .byte_size = image.byte_size,
    };
}

fn cloneImageList(
    allocator: std.mem.Allocator,
    images: []const PersistedImageAttachment,
) ![]const PersistedImageAttachment {
    if (images.len == 0) return &.{};
    const cloned = try allocator.alloc(PersistedImageAttachment, images.len);
    for (images, 0..) |image, index| {
        cloned[index] = (try cloneImage(allocator, image)).?;
    }
    return cloned;
}

fn cloneMessages(allocator: std.mem.Allocator, messages: []const PersistedMessage) ![]const PersistedMessage {
    const cloned = try allocator.alloc(PersistedMessage, messages.len);
    for (messages, 0..) |message, index| {
        cloned[index] = .{
            .role = message.role,
            .author = try allocator.dupe(u8, message.author),
            .body = try allocator.dupe(u8, message.body),
            .image = try cloneImage(allocator, message.image),
            .extra_images = try cloneImageList(allocator, message.extra_images),
            .tool_call_id = try cloneOptionalSlice(allocator, message.tool_call_id),
            .tool_call_kind = message.tool_call_kind,
            .tool_call_status = message.tool_call_status,
            .message_id = try cloneOptionalSlice(allocator, message.message_id),
        };
    }
    return cloned;
}

fn cloneThreads(
    allocator: std.mem.Allocator,
    threads: ?[]const PersistedThread,
    include_messages: bool,
) !?[]const PersistedThread {
    const source = threads orelse return null;
    const cloned = try allocator.alloc(PersistedThread, source.len);
    for (source, 0..) |thread, index| {
        cloned[index] = .{
            .title = try allocator.dupe(u8, thread.title),
            .archived = thread.archived,
            .committed = thread.committed,
            .local_thread_id = try cloneOptionalSlice(allocator, thread.local_thread_id),
            .last_activity_at = thread.last_activity_at,
            .provider_thread_id = try cloneOptionalSlice(allocator, thread.provider_thread_id),
            .model_ref = try cloneOptionalSlice(allocator, thread.model_ref),
            .reasoning_effort = thread.reasoning_effort,
            .reasoning_variant = try cloneOptionalSlice(allocator, thread.reasoning_variant),
            .fast_mode = thread.fast_mode,
            .access_mode = thread.access_mode,
            .provider = thread.provider,
            .harness = thread.harness,
            .tui_dock_id = thread.tui_dock_id,
            .cwd = try cloneOptionalSlice(allocator, thread.cwd),
            .profile_id = try cloneOptionalSlice(allocator, thread.profile_id),
            .runtime_id = try cloneOptionalSlice(allocator, thread.runtime_id),
            .repository_id = try cloneOptionalSlice(allocator, thread.repository_id),
            .repository_cwd = try cloneOptionalSlice(allocator, thread.repository_cwd),
            .draft = try allocator.dupe(u8, thread.draft),
            .draft_image = try cloneImage(allocator, thread.draft_image),
            .draft_extra_images = try cloneImageList(allocator, thread.draft_extra_images),
            .message_offset = if (include_messages)
                thread.message_offset
            else
                thread.message_offset + thread.messages.len,
            .messages = if (include_messages) try cloneMessages(allocator, thread.messages) else &.{},
        };
    }
    return cloned;
}

fn cloneHerdrLink(allocator: std.mem.Allocator, value: ?PersistedHerdrWorkspaceLink) !?PersistedHerdrWorkspaceLink {
    const link = value orelse return null;
    return .{
        .remote_alias = try allocator.dupe(u8, link.remote_alias),
        .session_name = try allocator.dupe(u8, link.session_name),
        .workspace_id = try allocator.dupe(u8, link.workspace_id),
        .local_dir = try allocator.dupe(u8, link.local_dir),
        .remote_cwd = try cloneOptionalSlice(allocator, link.remote_cwd),
        .last_pane_id = try cloneOptionalSlice(allocator, link.last_pane_id),
        .attach_dock_id = link.attach_dock_id,
        .attach_pane_id = link.attach_pane_id,
        .pane_links_json = try cloneOptionalSlice(allocator, link.pane_links_json),
        .updated_at_ms = link.updated_at_ms,
    };
}

fn cloneProjects(
    allocator: std.mem.Allocator,
    projects: []const PersistedProject,
    include_messages: bool,
) ![]const PersistedProject {
    const cloned = try allocator.alloc(PersistedProject, projects.len);
    for (projects, 0..) |project, index| {
        cloned[index] = .{
            .id = try cloneOptionalSlice(allocator, project.id),
            .label = try allocator.dupe(u8, project.label),
            .path = try allocator.dupe(u8, project.path),
            .archived = project.archived,
            .unread_count = project.unread_count,
            .collapsed = project.collapsed,
            .thread_list_expanded = project.thread_list_expanded,
            .terminal_height = project.terminal_height,
            .terminal_layout_json = try cloneOptionalSlice(allocator, project.terminal_layout_json),
            .terminal_docks_json = try cloneOptionalSlice(allocator, project.terminal_docks_json),
            .workspace_layout_json = try cloneOptionalSlice(allocator, project.workspace_layout_json),
            .selected_thread_index = project.selected_thread_index,
            .companion_thread_local_id = try cloneOptionalSlice(allocator, project.companion_thread_local_id),
            .herdr_link = try cloneHerdrLink(allocator, project.herdr_link),
            .threads = try cloneThreads(allocator, project.threads, include_messages),
            .provider = project.provider,
            .harness = project.harness,
            .draft = try allocator.dupe(u8, project.draft),
            .messages = if (include_messages) try cloneMessages(allocator, project.messages) else &.{},
        };
    }
    return cloned;
}

fn cloneSurfaces(allocator: std.mem.Allocator, source: []const PersistedSurfaceState) ![]const PersistedSurfaceState {
    const cloned = try allocator.alloc(PersistedSurfaceState, source.len);
    for (source, 0..) |surface, index| {
        cloned[index] = .{
            .session_id = try allocator.dupe(u8, surface.session_id),
            .workspace_id = try allocator.dupe(u8, surface.workspace_id),
            .workspace_path = try allocator.dupe(u8, surface.workspace_path),
            .dock_id = surface.dock_id,
            .pane_id = surface.pane_id,
            .provider = surface.provider,
            .provider_thread_id = try cloneOptionalSlice(allocator, surface.provider_thread_id),
            .title = try allocator.dupe(u8, surface.title),
            .status = surface.status,
            .status_changed_at_ms = surface.status_changed_at_ms,
            .completed_at_ms = surface.completed_at_ms,
            .last_event_title = try cloneOptionalSlice(allocator, surface.last_event_title),
            .last_event_body = try cloneOptionalSlice(allocator, surface.last_event_body),
        };
    }
    return cloned;
}

fn cloneCompletions(allocator: std.mem.Allocator, source: []const PersistedChatCompletion) ![]const PersistedChatCompletion {
    const cloned = try allocator.alloc(PersistedChatCompletion, source.len);
    for (source, 0..) |completion, index| {
        cloned[index] = .{
            .workspace_id = try allocator.dupe(u8, completion.workspace_id),
            .local_thread_id = try allocator.dupe(u8, completion.local_thread_id),
            .completed_at_ms = completion.completed_at_ms,
        };
    }
    return cloned;
}

fn clonePersistedStateWithMessages(
    backing_allocator: std.mem.Allocator,
    source: PersistedState,
    include_messages: bool,
) !LoadedPersistedState {
    var loaded = LoadedPersistedState.init(backing_allocator);
    errdefer loaded.deinit();
    const allocator = loaded.allocator();
    loaded.value = .{
        .selected_project_index = source.selected_project_index,
        .sidebar_collapsed = source.sidebar_collapsed,
        .projects = try cloneProjects(allocator, source.projects, include_messages),
        .surface_states = try cloneSurfaces(allocator, source.surface_states),
        .chat_completions = try cloneCompletions(allocator, source.chat_completions),
        .provider = source.provider,
        .harness = source.harness,
        .draft = try cloneOptionalSlice(allocator, source.draft),
        .messages = if (include_messages and source.messages != null)
            try cloneMessages(allocator, source.messages.?)
        else if (source.messages != null)
            &.{}
        else
            null,
    };
    return loaded;
}

/// Deep-copy a persistence projection without retaining a serialized JSON
/// copy in the destination arena.
pub fn clonePersistedState(
    backing_allocator: std.mem.Allocator,
    source: PersistedState,
) !LoadedPersistedState {
    return clonePersistedStateWithMessages(backing_allocator, source, true);
}

/// Conflict baselines compare only workspace/thread metadata and identities.
/// Keeping transcript bodies here doubled live history memory for no merge
/// benefit, so baseline snapshots intentionally omit every message payload.
pub fn clonePersistedBaseline(
    backing_allocator: std.mem.Allocator,
    source: PersistedState,
) !LoadedPersistedState {
    return clonePersistedStateWithMessages(backing_allocator, source, false);
}

fn persistedProjectIndexById(projects: []const PersistedProject, id: []const u8) ?usize {
    for (projects, 0..) |project, index| {
        if (project.id) |candidate| if (std.mem.eql(u8, candidate, id)) return index;
    }
    return null;
}

fn persistedThreadIndexById(threads: []const PersistedThread, id: []const u8) ?usize {
    for (threads, 0..) |thread, index| {
        if (thread.local_thread_id) |candidate| if (std.mem.eql(u8, candidate, id)) return index;
    }
    return null;
}

/// Build the close sidecar's local overlay. Existing durable identities need
/// metadata only for the three-way merge; transcript payloads are retained
/// solely for locally added workspaces/threads that have no durable owner yet.
pub fn clonePersistedSpoolDelta(
    backing_allocator: std.mem.Allocator,
    current: PersistedState,
    baseline: ?PersistedState,
) !LoadedPersistedState {
    const base = baseline orelse return clonePersistedState(backing_allocator, current);
    var loaded = try clonePersistedBaseline(backing_allocator, current);
    errdefer loaded.deinit();
    const allocator = loaded.allocator();
    const loaded_projects = @constCast(loaded.value.projects);

    for (current.projects, 0..) |project, project_index| {
        const project_id = project.id orelse {
            loaded_projects[project_index].messages = try cloneMessages(allocator, project.messages);
            continue;
        };
        const base_project_index = persistedProjectIndexById(base.projects, project_id) orelse {
            loaded_projects[project_index].messages = try cloneMessages(allocator, project.messages);
            if (project.threads) |threads| {
                const loaded_threads = @constCast(loaded_projects[project_index].threads.?);
                for (threads, 0..) |thread, thread_index| {
                    loaded_threads[thread_index].messages = try cloneMessages(allocator, thread.messages);
                }
            }
            continue;
        };
        const base_threads = base.projects[base_project_index].threads orelse &.{};
        if (project.threads) |threads| {
            const loaded_threads = @constCast(loaded_projects[project_index].threads.?);
            for (threads, 0..) |thread, thread_index| {
                const thread_id = thread.local_thread_id orelse {
                    loaded_threads[thread_index].messages = try cloneMessages(allocator, thread.messages);
                    continue;
                };
                const base_thread_index = persistedThreadIndexById(base_threads, thread_id);
                if (base_thread_index == null) {
                    loaded_threads[thread_index].messages = try cloneMessages(allocator, thread.messages);
                } else {
                    const base_thread = base_threads[base_thread_index.?];
                    const baseline_end = base_thread.message_offset + base_thread.messages.len;
                    const current_end = thread.message_offset + thread.messages.len;
                    if (current_end > baseline_end) {
                        const suffix_start = @max(baseline_end, thread.message_offset);
                        loaded_threads[thread_index].message_offset = suffix_start;
                        loaded_threads[thread_index].messages = try cloneMessages(
                            allocator,
                            thread.messages[suffix_start - thread.message_offset ..],
                        );
                    }
                }
            }
        }
    }
    return loaded;
}

test "compact baseline and spool delta omit durable transcript bodies" {
    const old_messages = [_]PersistedMessage{.{ .role = .assistant, .author = "Assistant", .body = "large durable body" }};
    const extended_messages = [_]PersistedMessage{
        .{ .role = .assistant, .author = "Assistant", .body = "large durable body" },
        .{ .role = .user, .author = "You", .body = "new suffix" },
    };
    const new_messages = [_]PersistedMessage{.{ .role = .user, .author = "You", .body = "local-only body" }};
    const baseline_threads = [_]PersistedThread{.{
        .title = "Durable",
        .local_thread_id = "durable-thread",
        .messages = &old_messages,
    }};
    const current_threads = [_]PersistedThread{
        .{ .title = "Renamed", .local_thread_id = "durable-thread", .messages = &extended_messages },
        .{ .title = "Local", .local_thread_id = "local-thread", .messages = &new_messages },
    };
    const baseline_projects = [_]PersistedProject{.{
        .id = "workspace",
        .label = "Before",
        .path = "/tmp/workspace",
        .threads = &baseline_threads,
    }};
    const current_projects = [_]PersistedProject{.{
        .id = "workspace",
        .label = "After",
        .path = "/tmp/workspace",
        .threads = &current_threads,
    }};
    const baseline_state: PersistedState = .{ .projects = &baseline_projects };
    const current_state: PersistedState = .{ .projects = &current_projects };

    var compact = try clonePersistedBaseline(std.testing.allocator, baseline_state);
    defer compact.deinit();
    try std.testing.expectEqual(@as(usize, 0), compact.value.projects[0].threads.?[0].messages.len);

    var delta = try clonePersistedSpoolDelta(std.testing.allocator, current_state, baseline_state);
    defer delta.deinit();
    try std.testing.expectEqualStrings("After", delta.value.projects[0].label);
    try std.testing.expectEqual(@as(usize, 1), delta.value.projects[0].threads.?[0].message_offset);
    try std.testing.expectEqual(@as(usize, 1), delta.value.projects[0].threads.?[0].messages.len);
    try std.testing.expectEqualStrings("new suffix", delta.value.projects[0].threads.?[0].messages[0].body);
    try std.testing.expectEqual(@as(usize, 1), delta.value.projects[0].threads.?[1].messages.len);
    try std.testing.expectEqualStrings("local-only body", delta.value.projects[0].threads.?[1].messages[0].body);
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
