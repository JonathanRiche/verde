//! SQLite client for persisting app state.

const std = @import("std");
const testing = std.testing;
const zqlite = @import("zqlite");

const schema = @import("schema.zig");
const db_types = @import("types.zig");

const LoadedState = db_types.LoadedState;
const PersistedImageAttachment = db_types.PersistedImageAttachment;
const PersistedMessage = db_types.PersistedMessage;
const PersistedProject = db_types.PersistedProject;
const PersistedState = db_types.PersistedState;
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
            "select selected_project_index, sidebar_collapsed from app_state where id = 1",
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
        var projects: std.ArrayList(PersistedProject) = .empty;
        defer projects.deinit(arena);

        var project_rows = try self.conn.rows(
            "select id, project_id, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, selected_thread_index " ++
                "from projects order by sort_index",
            .{},
        );
        defer project_rows.deinit();

        while (project_rows.next()) |project_row| {
            const project_id = project_row.int(0);
            try projects.append(arena, .{
                .id = try arena.dupe(u8, project_row.text(1)),
                .label = try arena.dupe(u8, project_row.text(2)),
                .path = try arena.dupe(u8, project_row.text(3)),
                .archived = project_row.int(4) != 0,
                .unread_count = @intCast(project_row.int(5)),
                .collapsed = project_row.int(6) != 0,
                .thread_list_expanded = project_row.int(7) != 0,
                .terminal_height = if (project_row.nullableFloat(8)) |value| @floatCast(value) else null,
                .terminal_layout_json = try dupeOptionalText(arena, project_row.nullableText(9)),
                .selected_thread_index = @intCast(project_row.int(10)),
                .threads = try self.loadThreads(arena, project_id),
            });
        }
        if (project_rows.err) |err| return err;

        loaded.value.projects = try projects.toOwnedSlice(arena);
        return loaded;
    }

    pub fn save(self: *const Self, state: PersistedState) !void {
        try self.conn.transaction();
        errdefer self.conn.rollback();

        try self.conn.execNoArgs(
            \\delete from messages;
            \\delete from threads;
            \\delete from app_state;
            \\delete from projects;
        );

        try self.conn.exec(
            "insert into app_state (id, selected_project_index, sidebar_collapsed) values (1, ?1, ?2)",
            .{
                @as(i64, @intCast(state.selected_project_index)),
                boolToInt(state.sidebar_collapsed),
            },
        );

        for (state.projects, 0..) |project, project_index| {
            try self.conn.exec(
                "insert into projects (project_id, sort_index, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, selected_thread_index) " ++
                    "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
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
                    @as(i64, @intCast(project.selected_thread_index)),
                },
            );
            const project_row_id = self.conn.lastInsertedRowId();
            try self.saveProjectThreads(project_row_id, state, project, project_index);
        }

        try self.conn.commit();
    }

    fn loadThreads(self: *const Self, allocator: std.mem.Allocator, project_id: i64) ![]const PersistedThread {
        var threads: std.ArrayList(PersistedThread) = .empty;
        defer threads.deinit(allocator);

        var thread_rows = try self.conn.rows(
            "select id, title, archived, committed, last_activity_at, provider_thread_id, model_ref, reasoning_effort, reasoning_variant, fast_mode, access_mode, provider, harness, draft, draft_image_path, draft_image_mime, draft_image_byte_size " ++
                "from threads where project_id = ?1 order by sort_index",
            .{project_id},
        );
        defer thread_rows.deinit();

        while (thread_rows.next()) |thread_row| {
            const thread_id = thread_row.int(0);
            try threads.append(allocator, .{
                .title = try allocator.dupe(u8, thread_row.text(1)),
                .archived = thread_row.int(2) != 0,
                .committed = thread_row.int(3) != 0,
                .last_activity_at = thread_row.nullableInt(4),
                .provider_thread_id = try dupeOptionalText(allocator, thread_row.nullableText(5)),
                .model_ref = try dupeOptionalText(allocator, thread_row.nullableText(6)),
                .reasoning_effort = decodeOptionalEnum(db_types.ReasoningEffort, thread_row.nullableInt(7)),
                .reasoning_variant = try dupeOptionalText(allocator, thread_row.nullableText(8)),
                .fast_mode = decodeOptionalEnum(db_types.FastMode, thread_row.nullableInt(9)),
                .access_mode = decodeOptionalEnum(db_types.AccessMode, thread_row.nullableInt(10)),
                .provider = decodeEnumOr(db_types.Provider, thread_row.int(11), .opencode),
                .harness = decodeEnumOr(db_types.Harness, thread_row.int(12), .local_cli),
                .draft = try allocator.dupe(u8, thread_row.text(13)),
                .draft_image = try loadOptionalImage(
                    allocator,
                    thread_row.nullableText(14),
                    thread_row.nullableText(15),
                    thread_row.nullableInt(16),
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
            "select role, author, body, image_path, image_mime, image_byte_size " ++
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
            });
        }
        if (message_rows.err) |err| return err;

        return try messages.toOwnedSlice(allocator);
    }

    fn saveProjectThreads(
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
                "insert into threads (project_id, sort_index, title, archived, committed, last_activity_at, provider_thread_id, model_ref, reasoning_effort, reasoning_variant, fast_mode, access_mode, provider, harness, draft, draft_image_path, draft_image_mime, draft_image_byte_size) " ++
                    "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
                .{
                    project_id,
                    @as(i64, @intCast(thread_index)),
                    thread.title,
                    boolToInt(thread.archived),
                    boolToInt(thread.committed),
                    thread.last_activity_at,
                    thread.provider_thread_id,
                    thread.model_ref,
                    encodeOptionalEnum(thread.reasoning_effort),
                    thread.reasoning_variant,
                    encodeOptionalEnum(thread.fast_mode),
                    encodeOptionalEnum(thread.access_mode),
                    @as(i64, @intFromEnum(thread.provider)),
                    @as(i64, @intFromEnum(thread.harness)),
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
                "insert into messages (thread_id, sort_index, role, author, body, image_path, image_mime, image_byte_size) " ++
                    "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                .{
                    thread_id,
                    @as(i64, @intCast(message_index)),
                    @as(i64, @intFromEnum(message.role)),
                    message.author,
                    message.body,
                    if (image) |attachment| attachment.path else null,
                    if (image) |attachment| attachment.mime else null,
                    if (image) |attachment| @as(i64, @intCast(attachment.byte_size)) else null,
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

test "save clears orphaned threads left behind by manual db edits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pref_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();

    const initial_state = PersistedState{
        .selected_project_index = 0,
        .projects = &.{.{
            .id = "project-1",
            .label = "Project",
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
        \\delete from app_state;
        \\delete from projects;
        \\insert into threads (
        \\    project_id,
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
            .label = "Project",
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

    const loaded = try client.load(testing.allocator);
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

    const pref_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();

    const archived_state = PersistedState{
        .selected_project_index = 0,
        .projects = &.{
            .{
                .id = "project-active",
                .label = "Active Project",
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
                .label = "Archived Project",
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

    const loaded = try client.load(testing.allocator);
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
