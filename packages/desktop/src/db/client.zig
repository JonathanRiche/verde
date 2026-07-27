//! SQLite client for persisting app state.

const std = @import("std");
const testing = std.testing;
const zqlite = @import("zqlite");

const schema = @import("schema.zig");
const db_types = @import("types.zig");
const provider_types = @import("../providers/types.zig");

const LoadedState = db_types.LoadedState;
const PersistedChatCompletion = db_types.PersistedChatCompletion;
const PersistedHerdrWorkspaceLink = db_types.PersistedHerdrWorkspaceLink;
const PersistedImageAttachment = db_types.PersistedImageAttachment;
const PersistedMessage = db_types.PersistedMessage;
const PersistedProject = db_types.PersistedProject;
const PersistedState = db_types.PersistedState;
const PersistedSurfaceCompletion = db_types.PersistedSurfaceCompletion;
const PersistedThread = db_types.PersistedThread;

pub const STATE_DB_NAME = "state.sqlite";

pub const Client = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    path: [:0]u8,
    conn: zqlite.Conn,

    pub fn pathForPrefPath(allocator: std.mem.Allocator, pref_path: []const u8) ![:0]u8 {
        return std.fs.path.joinZ(allocator, &.{ pref_path, STATE_DB_NAME });
    }

    pub fn init(allocator: std.mem.Allocator, pref_path: []const u8) !Self {
        const path = try pathForPrefPath(allocator, pref_path);
        errdefer allocator.free(path);

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        const conn = try zqlite.open(path, flags);
        errdefer conn.close();

        try schema.initialize(conn);
        return .{
            .allocator = allocator,
            .path = path,
            .conn = conn,
        };
    }

    pub fn deinit(self: *Self) void {
        self.conn.close();
        self.allocator.free(self.path);
    }

    pub fn load(self: *const Self, backing_allocator: std.mem.Allocator) !?LoadedState {
        const row = try self.conn.row(
            "select selected_workspace_index, sidebar_collapsed from app_state where id = 1",
            .{},
        );
        if (row == null) return null;

        var loaded = LoadedState.init(backing_allocator);
        errdefer loaded.deinit();

        {
            var state_row = row.?;
            defer state_row.deinit();
            loaded.value.selected_project_index = @intCast(state_row.int(0));
            loaded.value.sidebar_collapsed = state_row.int(1) != 0;
        }

        const arena = loaded.allocator();
        var workspaces: std.ArrayList(PersistedProject) = .empty;
        defer workspaces.deinit(arena);

        var workspace_rows = try self.conn.rows(
            "select id, workspace_id, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, terminal_docks_json, workspace_layout_json, selected_thread_index, " ++
                "herdr_remote_alias, herdr_session_name, herdr_workspace_id, herdr_local_dir, herdr_remote_cwd, herdr_last_pane_id, herdr_attach_dock_id, herdr_attach_pane_id, herdr_pane_links_json, herdr_updated_at_ms " ++
                "from workspaces order by sort_index",
            .{},
        );
        defer workspace_rows.deinit();

        while (workspace_rows.next()) |workspace_row| {
            const workspace_id = workspace_row.int(0);
            try workspaces.append(arena, .{
                .id = try arena.dupe(u8, workspace_row.text(1)),
                .label = try arena.dupe(u8, workspace_row.text(2)),
                .path = try arena.dupe(u8, workspace_row.text(3)),
                .archived = workspace_row.int(4) != 0,
                .unread_count = @intCast(workspace_row.int(5)),
                .collapsed = workspace_row.int(6) != 0,
                .thread_list_expanded = workspace_row.int(7) != 0,
                .terminal_height = if (workspace_row.nullableFloat(8)) |value| @floatCast(value) else null,
                .terminal_layout_json = try dupeOptionalText(arena, workspace_row.nullableText(9)),
                .terminal_docks_json = try dupeOptionalText(arena, workspace_row.nullableText(10)),
                .workspace_layout_json = try dupeOptionalText(arena, workspace_row.nullableText(11)),
                .selected_thread_index = @intCast(workspace_row.int(12)),
                .herdr_link = try loadOptionalHerdrLink(
                    arena,
                    workspace_row.nullableText(13),
                    workspace_row.nullableText(14),
                    workspace_row.nullableText(15),
                    workspace_row.nullableText(16),
                    workspace_row.nullableText(17),
                    workspace_row.nullableText(18),
                    workspace_row.nullableInt(19),
                    workspace_row.nullableInt(20),
                    workspace_row.nullableText(21),
                    workspace_row.nullableInt(22),
                ),
                .threads = try self.loadThreads(arena, workspace_id),
            });
        }
        if (workspace_rows.err) |err| return err;

        loaded.value.projects = try workspaces.toOwnedSlice(arena);
        loaded.value.surface_completions = try self.loadSurfaceCompletions(arena);
        loaded.value.chat_completions = try self.loadChatCompletions(arena);
        return loaded;
    }

    pub fn upsertSurfaceCompletion(self: *const Self, completion: PersistedSurfaceCompletion) !void {
        try self.conn.exec(
            "insert into surface_completions (session_id, workspace_id, workspace_path, dock_id, pane_id, provider, provider_thread_id, title, completed_at_ms, last_event_title, last_event_body) " ++
                "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) " ++
                "on conflict(session_id) do update set workspace_id = excluded.workspace_id, workspace_path = excluded.workspace_path, dock_id = excluded.dock_id, " ++
                "pane_id = excluded.pane_id, provider = excluded.provider, provider_thread_id = excluded.provider_thread_id, title = excluded.title, " ++
                "completed_at_ms = excluded.completed_at_ms, last_event_title = excluded.last_event_title, last_event_body = excluded.last_event_body",
            .{
                completion.session_id,
                completion.workspace_id,
                completion.workspace_path,
                @as(i64, @intCast(completion.dock_id)),
                if (completion.pane_id) |pane_id| @as(i64, @intCast(pane_id)) else null,
                encodeOptionalEnum(completion.provider),
                completion.provider_thread_id,
                completion.title,
                completion.completed_at_ms,
                completion.last_event_title,
                completion.last_event_body,
            },
        );
    }

    pub fn clearSurfaceCompletion(self: *const Self, session_id: []const u8) !bool {
        try self.conn.exec("delete from surface_completions where session_id = ?1", .{session_id});
        return self.conn.changes() > 0;
    }

    pub fn upsertChatCompletion(self: *const Self, completion: PersistedChatCompletion) !void {
        try self.conn.exec(
            "insert into chat_completions (workspace_id, local_thread_id, completed_at_ms) values (?1, ?2, ?3) " ++
                "on conflict(workspace_id, local_thread_id) do update set completed_at_ms = excluded.completed_at_ms",
            .{ completion.workspace_id, completion.local_thread_id, completion.completed_at_ms },
        );
    }

    pub fn clearChatCompletion(self: *const Self, workspace_id: []const u8, local_thread_id: []const u8) !bool {
        try self.conn.exec(
            "delete from chat_completions where workspace_id = ?1 and local_thread_id = ?2",
            .{ workspace_id, local_thread_id },
        );
        return self.conn.changes() > 0;
    }

    pub fn save(self: *const Self, state: PersistedState) !void {
        try self.conn.transaction();
        errdefer self.conn.rollback();

        try self.conn.execNoArgs(
            \\delete from messages;
            \\delete from threads;
            \\delete from app_state;
            \\delete from workspaces;
        );

        try self.conn.exec(
            "insert into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, ?1, ?2)",
            .{
                @as(i64, @intCast(state.selected_project_index)),
                boolToInt(state.sidebar_collapsed),
            },
        );

        for (state.projects, 0..) |project, project_index| {
            const herdr_link = project.herdr_link;
            try self.conn.exec(
                "insert into workspaces (workspace_id, sort_index, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, terminal_docks_json, workspace_layout_json, selected_thread_index, " ++
                    "herdr_remote_alias, herdr_session_name, herdr_workspace_id, herdr_local_dir, herdr_remote_cwd, herdr_last_pane_id, herdr_attach_dock_id, herdr_attach_pane_id, herdr_pane_links_json, herdr_updated_at_ms) " ++
                    "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23)",
                .{
                    project.id orelse project.path,
                    @as(i64, @intCast(project_index)),
                    project.label,
                    project.path,
                    boolToInt(project.archived),
                    @as(i64, @intCast(project.unread_count)),
                    boolToInt(project.collapsed orelse false),
                    boolToInt(project.thread_list_expanded orelse false),
                    project.terminal_height,
                    project.terminal_layout_json,
                    project.terminal_docks_json,
                    project.workspace_layout_json,
                    @as(i64, @intCast(project.selected_thread_index)),
                    if (herdr_link) |link| link.remote_alias else null,
                    if (herdr_link) |link| link.session_name else null,
                    if (herdr_link) |link| link.workspace_id else null,
                    if (herdr_link) |link| link.local_dir else null,
                    if (herdr_link) |link| link.remote_cwd else null,
                    if (herdr_link) |link| link.last_pane_id else null,
                    if (herdr_link) |link| if (link.attach_dock_id) |dock_id| @as(i64, @intCast(dock_id)) else null else null,
                    if (herdr_link) |link| if (link.attach_pane_id) |pane_id| @as(i64, @intCast(pane_id)) else null else null,
                    if (herdr_link) |link| link.pane_links_json else null,
                    if (herdr_link) |link| link.updated_at_ms else null,
                },
            );
            const workspace_row_id = self.conn.lastInsertedRowId();
            try self.saveWorkspaceThreads(workspace_row_id, state, project, project_index);
        }

        try self.conn.commit();
    }

    fn loadSurfaceCompletions(self: *const Self, allocator: std.mem.Allocator) ![]const PersistedSurfaceCompletion {
        var completions: std.ArrayList(PersistedSurfaceCompletion) = .empty;
        defer completions.deinit(allocator);

        var rows = try self.conn.rows(
            "select session_id, workspace_id, workspace_path, dock_id, pane_id, provider, provider_thread_id, title, completed_at_ms, last_event_title, last_event_body " ++
                "from surface_completions order by completed_at_ms, session_id",
            .{},
        );
        defer rows.deinit();

        while (rows.next()) |row| {
            try completions.append(allocator, .{
                .session_id = try allocator.dupe(u8, row.text(0)),
                .workspace_id = try allocator.dupe(u8, row.text(1)),
                .workspace_path = try allocator.dupe(u8, row.text(2)),
                .dock_id = @intCast(row.int(3)),
                .pane_id = if (row.nullableInt(4)) |value| @intCast(value) else null,
                .provider = decodeOptionalEnum(db_types.SurfaceProvider, row.nullableInt(5)),
                .provider_thread_id = try dupeOptionalText(allocator, row.nullableText(6)),
                .title = try allocator.dupe(u8, row.text(7)),
                .completed_at_ms = row.int(8),
                .last_event_title = try dupeOptionalText(allocator, row.nullableText(9)),
                .last_event_body = try dupeOptionalText(allocator, row.nullableText(10)),
            });
        }
        if (rows.err) |err| return err;
        return try completions.toOwnedSlice(allocator);
    }

    fn loadChatCompletions(self: *const Self, allocator: std.mem.Allocator) ![]const PersistedChatCompletion {
        var completions: std.ArrayList(PersistedChatCompletion) = .empty;
        defer completions.deinit(allocator);

        var rows = try self.conn.rows(
            "select workspace_id, local_thread_id, completed_at_ms from chat_completions " ++
                "order by completed_at_ms, workspace_id, local_thread_id",
            .{},
        );
        defer rows.deinit();

        while (rows.next()) |row| {
            try completions.append(allocator, .{
                .workspace_id = try allocator.dupe(u8, row.text(0)),
                .local_thread_id = try allocator.dupe(u8, row.text(1)),
                .completed_at_ms = row.int(2),
            });
        }
        if (rows.err) |err| return err;
        return try completions.toOwnedSlice(allocator);
    }

    fn loadThreads(self: *const Self, allocator: std.mem.Allocator, project_id: i64) ![]const PersistedThread {
        var threads: std.ArrayList(PersistedThread) = .empty;
        defer threads.deinit(allocator);

        var thread_rows = try self.conn.rows(
            "select id, title, archived, committed, local_thread_id, last_activity_at, provider_thread_id, model_ref, reasoning_effort, reasoning_variant, fast_mode, access_mode, provider, harness, tui_dock_id, draft, draft_image_path, draft_image_mime, draft_image_byte_size " ++
                "from threads where workspace_id = ?1 order by sort_index",
            .{project_id},
        );
        defer thread_rows.deinit();

        while (thread_rows.next()) |thread_row| {
            const thread_id = thread_row.int(0);
            try threads.append(allocator, .{
                .title = try allocator.dupe(u8, thread_row.text(1)),
                .archived = thread_row.int(2) != 0,
                .committed = thread_row.int(3) != 0,
                .local_thread_id = try dupeOptionalText(allocator, thread_row.nullableText(4)),
                .last_activity_at = thread_row.nullableInt(5),
                .provider_thread_id = try dupeOptionalText(allocator, thread_row.nullableText(6)),
                .model_ref = try dupeOptionalText(allocator, thread_row.nullableText(7)),
                .reasoning_effort = decodeOptionalEnum(db_types.ReasoningEffort, thread_row.nullableInt(8)),
                .reasoning_variant = try dupeOptionalText(allocator, thread_row.nullableText(9)),
                .fast_mode = decodeOptionalEnum(db_types.FastMode, thread_row.nullableInt(10)),
                .access_mode = decodeOptionalEnum(db_types.AccessMode, thread_row.nullableInt(11)),
                .provider = decodeEnumOr(db_types.Provider, thread_row.int(12), .opencode),
                .harness = decodeEnumOr(db_types.Harness, thread_row.int(13), .local_cli),
                .tui_dock_id = if (thread_row.nullableInt(14)) |value| @intCast(value) else null,
                .draft = try allocator.dupe(u8, thread_row.text(15)),
                .draft_image = try loadOptionalImage(
                    allocator,
                    thread_row.nullableText(16),
                    thread_row.nullableText(17),
                    thread_row.nullableInt(18),
                ),
                .messages = try self.loadMessages(allocator, thread_id),
            });
        }
        if (thread_rows.err) |err| return err;

        return try threads.toOwnedSlice(allocator);
    }

    fn loadMessages(self: *const Self, allocator: std.mem.Allocator, thread_id: i64) ![]const PersistedMessage {
        var messages: std.ArrayList(PersistedMessage) = .empty;
        defer messages.deinit(allocator);

        var message_rows = try self.conn.rows(
            "select role, author, body, image_path, image_mime, image_byte_size, tool_call_id, tool_call_kind, tool_call_status " ++
                "from messages where thread_id = ?1 order by sort_index",
            .{thread_id},
        );
        defer message_rows.deinit();

        while (message_rows.next()) |message_row| {
            try messages.append(allocator, .{
                .role = decodeEnumOr(db_types.ChatRole, message_row.int(0), .user),
                .author = try allocator.dupe(u8, message_row.text(1)),
                .body = try allocator.dupe(u8, message_row.text(2)),
                .image = try loadOptionalImage(
                    allocator,
                    message_row.nullableText(3),
                    message_row.nullableText(4),
                    message_row.nullableInt(5),
                ),
                .tool_call_id = try dupeOptionalText(allocator, message_row.nullableText(6)),
                .tool_call_kind = decodeOptionalEnum(provider_types.ToolCallKind, message_row.nullableInt(7)),
                .tool_call_status = decodeOptionalEnum(provider_types.ToolCallStatus, message_row.nullableInt(8)),
            });
        }
        if (message_rows.err) |err| return err;

        return try messages.toOwnedSlice(allocator);
    }

    fn saveWorkspaceThreads(
        self: *const Self,
        project_id: i64,
        state: PersistedState,
        project: PersistedProject,
        project_index: usize,
    ) !void {
        if (project.threads) |threads| {
            return self.saveThreads(project_id, threads);
        }

        var synthesized: PersistedThread = .{
            .title = "New thread",
            .archived = project.archived,
            .committed = project.messages.len > 0,
            .last_activity_at = if (project.messages.len > 0) 0 else null,
            .provider = project.provider,
            .harness = project.harness,
            .draft = project.draft,
            .messages = project.messages,
        };

        if (project_index == 0 and project.messages.len == 0 and state.messages != null) {
            synthesized.provider = state.provider orelse synthesized.provider;
            synthesized.harness = state.harness orelse synthesized.harness;
            synthesized.draft = state.draft orelse synthesized.draft;
            synthesized.messages = state.messages.?;
        }

        return self.saveThreads(project_id, &.{synthesized});
    }

    fn saveThreads(self: *const Self, project_id: i64, threads: []const PersistedThread) !void {
        for (threads, 0..) |thread, thread_index| {
            const draft_image = thread.draft_image;
            try self.conn.exec(
                "insert into threads (workspace_id, sort_index, title, archived, committed, local_thread_id, last_activity_at, provider_thread_id, model_ref, reasoning_effort, reasoning_variant, fast_mode, access_mode, provider, harness, tui_dock_id, draft, draft_image_path, draft_image_mime, draft_image_byte_size) " ++
                    "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)",
                .{
                    project_id,
                    @as(i64, @intCast(thread_index)),
                    thread.title,
                    boolToInt(thread.archived),
                    boolToInt(thread.committed),
                    thread.local_thread_id,
                    thread.last_activity_at,
                    thread.provider_thread_id,
                    thread.model_ref,
                    encodeOptionalEnum(thread.reasoning_effort),
                    thread.reasoning_variant,
                    encodeOptionalEnum(thread.fast_mode),
                    encodeOptionalEnum(thread.access_mode),
                    @as(i64, @intFromEnum(thread.provider)),
                    @as(i64, @intFromEnum(thread.harness)),
                    if (thread.tui_dock_id) |dock_id| @as(i64, @intCast(dock_id)) else null,
                    thread.draft,
                    if (draft_image) |image| image.path else null,
                    if (draft_image) |image| image.mime else null,
                    if (draft_image) |image| @as(i64, @intCast(image.byte_size)) else null,
                },
            );
            const thread_row_id = self.conn.lastInsertedRowId();
            try self.saveMessages(thread_row_id, thread.messages);
        }
    }

    fn saveMessages(self: *const Self, thread_id: i64, messages: []const PersistedMessage) !void {
        for (messages, 0..) |message, message_index| {
            const image = message.image;
            try self.conn.exec(
                "insert into messages (thread_id, sort_index, role, author, body, image_path, image_mime, image_byte_size, tool_call_id, tool_call_kind, tool_call_status) " ++
                    "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                .{
                    thread_id,
                    @as(i64, @intCast(message_index)),
                    @as(i64, @intFromEnum(message.role)),
                    message.author,
                    message.body,
                    if (image) |attachment| attachment.path else null,
                    if (image) |attachment| attachment.mime else null,
                    if (image) |attachment| @as(i64, @intCast(attachment.byte_size)) else null,
                    message.tool_call_id,
                    encodeOptionalEnum(message.tool_call_kind),
                    encodeOptionalEnum(message.tool_call_status),
                },
            );
        }
    }
};

fn loadOptionalImage(
    allocator: std.mem.Allocator,
    path: ?[]const u8,
    mime: ?[]const u8,
    byte_size: ?i64,
) !?PersistedImageAttachment {
    const image_path = path orelse return null;
    const image_mime = mime orelse return null;
    return .{
        .path = try allocator.dupe(u8, image_path),
        .mime = try allocator.dupe(u8, image_mime),
        .byte_size = @intCast(byte_size orelse 0),
    };
}

fn loadOptionalHerdrLink(
    allocator: std.mem.Allocator,
    remote_alias: ?[]const u8,
    session_name: ?[]const u8,
    workspace_id: ?[]const u8,
    local_dir: ?[]const u8,
    remote_cwd: ?[]const u8,
    last_pane_id: ?[]const u8,
    attach_dock_id: ?i64,
    attach_pane_id: ?i64,
    pane_links_json: ?[]const u8,
    updated_at_ms: ?i64,
) !?PersistedHerdrWorkspaceLink {
    const session = session_name orelse return null;
    const workspace = workspace_id orelse return null;
    const local = local_dir orelse return null;
    return .{
        .remote_alias = try allocator.dupe(u8, remote_alias orelse ""),
        .session_name = try allocator.dupe(u8, session),
        .workspace_id = try allocator.dupe(u8, workspace),
        .local_dir = try allocator.dupe(u8, local),
        .remote_cwd = try dupeOptionalText(allocator, remote_cwd),
        .last_pane_id = try dupeOptionalText(allocator, last_pane_id),
        .attach_dock_id = if (attach_dock_id) |value| @intCast(value) else null,
        .attach_pane_id = if (attach_pane_id) |value| @intCast(value) else null,
        .pane_links_json = try dupeOptionalText(allocator, pane_links_json),
        .updated_at_ms = updated_at_ms orelse 0,
    };
}

fn dupeOptionalText(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const text = value orelse return null;
    return try allocator.dupe(u8, text);
}

fn boolToInt(value: bool) i64 {
    return if (value) 1 else 0;
}

fn encodeOptionalEnum(value: anytype) ?i64 {
    const enum_value = value orelse return null;
    return @as(i64, @intFromEnum(enum_value));
}

fn decodeOptionalEnum(comptime Enum: type, raw: ?i64) ?Enum {
    const value = raw orelse return null;
    const enum_value: u8 = @intCast(value);
    inline for (std.meta.fields(Enum)) |field| {
        if (field.value == enum_value) return @enumFromInt(enum_value);
    }
    return null;
}

fn decodeEnumOr(comptime Enum: type, raw: i64, fallback: Enum) Enum {
    const enum_value: u8 = @intCast(raw);
    inline for (std.meta.fields(Enum)) |field| {
        if (field.value == enum_value) return @enumFromInt(enum_value);
    }
    return fallback;
}

fn testDirPathAlloc(dir: std.Io.Dir, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(testing.io, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

test "surface completions survive state saves and clear explicitly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();

    try client.save(.{});
    try client.upsertSurfaceCompletion(.{
        .session_id = "session-later",
        .workspace_id = "workspace-2",
        .workspace_path = "/tmp/two",
        .dock_id = 2,
        .pane_id = 12,
        .provider = .cursor,
        .title = "Later",
        .completed_at_ms = 200,
    });
    try client.upsertSurfaceCompletion(.{
        .session_id = "session-first",
        .workspace_id = "workspace-1",
        .workspace_path = "/tmp/one",
        .dock_id = 1,
        .pane_id = 11,
        .provider = .codex,
        .title = "First",
        .completed_at_ms = 100,
    });

    // Ordinary app-state snapshots must not erase the independent completion
    // ledger, including when another process writes the ledger between saves.
    try client.save(.{ .sidebar_collapsed = true });

    var loaded = (try client.load(testing.allocator)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.value.surface_completions.len);
    try testing.expectEqualStrings("session-first", loaded.value.surface_completions[0].session_id);
    try testing.expectEqualStrings("session-later", loaded.value.surface_completions[1].session_id);
    try testing.expect(try client.clearSurfaceCompletion("session-first"));
    try testing.expect(!try client.clearSurfaceCompletion("session-first"));
}

test "chat completions survive state saves and clear explicitly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();

    try client.save(.{});
    try client.upsertChatCompletion(.{
        .workspace_id = "workspace-2",
        .local_thread_id = "chat-later",
        .completed_at_ms = 200,
    });
    try client.upsertChatCompletion(.{
        .workspace_id = "workspace-1",
        .local_thread_id = "chat-first",
        .completed_at_ms = 100,
    });

    try client.save(.{ .sidebar_collapsed = true });

    var loaded = (try client.load(testing.allocator)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.value.chat_completions.len);
    try testing.expectEqualStrings("chat-first", loaded.value.chat_completions[0].local_thread_id);
    try testing.expectEqualStrings("chat-later", loaded.value.chat_completions[1].local_thread_id);
    try testing.expect(try client.clearChatCompletion("workspace-1", "chat-first"));
    try testing.expect(!try client.clearChatCompletion("workspace-1", "chat-first"));
}

test "save clears orphaned threads left behind by manual db edits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();

    const initial_state = PersistedState{
        .selected_project_index = 0,
        .projects = &.{.{
            .id = "project-1",
            .label = "Workspace",
            .path = "/tmp/project",
            .selected_thread_index = 0,
            .threads = &.{.{
                .title = "Original thread",
                .committed = true,
                .provider = .codex,
                .draft = "",
                .messages = &.{.{
                    .role = .user,
                    .author = "You",
                    .body = "hello",
                }},
            }},
        }},
    };
    try client.save(initial_state);

    try client.conn.execNoArgs(
        \\pragma foreign_keys = off;
        \\delete from messages;
        \\delete from threads;
        \\delete from app_state;
        \\delete from workspaces;
        \\insert into threads (
        \\    workspace_id,
        \\    sort_index,
        \\    title,
        \\    committed,
        \\    provider,
        \\    harness,
        \\    draft
        \\) values (
        \\    1,
        \\    0,
        \\    'orphaned thread',
        \\    1,
        \\    1,
        \\    0,
        \\    ''
        \\);
        \\pragma foreign_keys = on;
    );

    const recovered_state = PersistedState{
        .selected_project_index = 0,
        .projects = &.{.{
            .id = "project-1",
            .label = "Workspace",
            .path = "/tmp/project",
            .selected_thread_index = 0,
            .threads = &.{.{
                .title = "Recovered thread",
                .committed = true,
                .provider = .codex,
                .draft = "",
                .messages = &.{.{
                    .role = .user,
                    .author = "You",
                    .body = "fixed",
                }},
            }},
        }},
    };
    try client.save(recovered_state);

    var loaded = try client.load(testing.allocator);
    defer if (loaded) |*state| state.deinit();

    try testing.expect(loaded != null);
    try testing.expectEqual(@as(usize, 1), loaded.?.value.projects.len);
    try testing.expectEqual(@as(usize, 1), loaded.?.value.projects[0].threads.?.len);
    try testing.expectEqualStrings("Recovered thread", loaded.?.value.projects[0].threads.?[0].title);
    try testing.expectEqualStrings("fixed", loaded.?.value.projects[0].threads.?[0].messages[0].body);
}

test "save and load preserve archived projects and threads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();

    const archived_state = PersistedState{
        .selected_project_index = 0,
        .projects = &.{
            .{
                .id = "project-active",
                .label = "Active Workspace",
                .path = "/tmp/project-active",
                .selected_thread_index = 0,
                .threads = &.{
                    .{
                        .title = "Visible thread",
                        .committed = true,
                        .provider = .codex,
                        .draft = "",
                        .messages = &.{.{
                            .role = .user,
                            .author = "You",
                            .body = "active",
                        }},
                    },
                    .{
                        .title = "Archived thread",
                        .archived = true,
                        .committed = true,
                        .provider = .codex,
                        .draft = "",
                        .messages = &.{.{
                            .role = .user,
                            .author = "You",
                            .body = "archived-thread",
                        }},
                    },
                },
            },
            .{
                .id = "project-archived",
                .label = "Archived Workspace",
                .path = "/tmp/project-archived",
                .archived = true,
                .selected_thread_index = 0,
                .threads = &.{.{
                    .title = "Archived project thread",
                    .archived = true,
                    .committed = true,
                    .provider = .opencode,
                    .draft = "",
                    .messages = &.{.{
                        .role = .user,
                        .author = "You",
                        .body = "archived-project",
                    }},
                }},
            },
        },
    };
    try client.save(archived_state);

    var loaded = try client.load(testing.allocator);
    defer if (loaded) |*state| state.deinit();

    try testing.expect(loaded != null);
    try testing.expectEqual(@as(usize, 2), loaded.?.value.projects.len);
    try testing.expect(!loaded.?.value.projects[0].archived);
    try testing.expectEqual(@as(usize, 2), loaded.?.value.projects[0].threads.?.len);
    try testing.expect(!loaded.?.value.projects[0].threads.?[0].archived);
    try testing.expect(loaded.?.value.projects[0].threads.?[1].archived);
    try testing.expect(loaded.?.value.projects[1].archived);
    try testing.expectEqual(@as(usize, 1), loaded.?.value.projects[1].threads.?.len);
    try testing.expect(loaded.?.value.projects[1].threads.?[0].archived);
}

test "save and load preserve Herdr workspace links" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();

    const state = PersistedState{
        .selected_project_index = 0,
        .projects = &.{.{
            .id = "project-herdr",
            .label = "Herdr Workspace",
            .path = "/tmp/herdr-shadow",
            .herdr_link = .{
                .remote_alias = "zod.tailc28f01.ts.net",
                .session_name = "default",
                .workspace_id = "w1",
                .local_dir = "/tmp/herdr-shadow",
                .remote_cwd = "/home/rtg/project",
                .last_pane_id = "w1:p1",
                .attach_dock_id = 7,
                .attach_pane_id = 3,
                .pane_links_json = "[{\"verde_pane_id\":3,\"herdr_pane_id\":\"w1:p1\",\"provider\":\"codex\",\"presentation\":\"gui_chat\"}]",
                .updated_at_ms = 1234,
            },
            .threads = &.{.{
                .title = "New thread",
                .committed = false,
                .draft = "",
            }},
        }},
    };
    try client.save(state);

    var loaded = try client.load(testing.allocator);
    defer if (loaded) |*value| value.deinit();

    try testing.expect(loaded != null);
    const link = loaded.?.value.projects[0].herdr_link orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("zod.tailc28f01.ts.net", link.remote_alias);
    try testing.expectEqualStrings("default", link.session_name);
    try testing.expectEqualStrings("w1", link.workspace_id);
    try testing.expectEqualStrings("/tmp/herdr-shadow", link.local_dir);
    try testing.expectEqualStrings("/home/rtg/project", link.remote_cwd.?);
    try testing.expectEqualStrings("w1:p1", link.last_pane_id.?);
    try testing.expectEqual(@as(?u32, 7), link.attach_dock_id);
    try testing.expectEqual(@as(?u32, 3), link.attach_pane_id);
    try testing.expectEqualStrings("[{\"verde_pane_id\":3,\"herdr_pane_id\":\"w1:p1\",\"provider\":\"codex\",\"presentation\":\"gui_chat\"}]", link.pane_links_json.?);
    try testing.expectEqual(@as(i64, 1234), link.updated_at_ms);
}
