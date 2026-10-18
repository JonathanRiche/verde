//! SQLite client for persisting app state.

const std = @import("std");
const testing = std.testing;
const zqlite = @import("zqlite");

const schema = @import("schema.zig");
const db_types = @import("types.zig");
const migration_fixture = @import("migration_fixture.zig");
const provider_types = @import("../providers/types.zig");

const LoadedState = db_types.LoadedState;
const PersistedChatCompletion = db_types.PersistedChatCompletion;
const PersistedHerdrWorkspaceLink = db_types.PersistedHerdrWorkspaceLink;
const PersistedImageAttachment = db_types.PersistedImageAttachment;
const PersistedMessage = db_types.PersistedMessage;
const PersistedProject = db_types.PersistedProject;
const PersistedState = db_types.PersistedState;
const PersistedSurfaceState = db_types.PersistedSurfaceState;
const PersistedThread = db_types.PersistedThread;

/// Compare every field in the canonical durable surface representation.
pub fn surfaceStatesEqual(a: PersistedSurfaceState, b: PersistedSurfaceState) bool {
    return std.mem.eql(u8, a.session_id, b.session_id) and
        std.mem.eql(u8, a.workspace_id, b.workspace_id) and
        std.mem.eql(u8, a.workspace_path, b.workspace_path) and
        a.dock_id == b.dock_id and
        a.pane_id == b.pane_id and
        a.provider == b.provider and
        optionalTextEqual(a.provider_thread_id, b.provider_thread_id) and
        std.mem.eql(u8, a.title, b.title) and
        a.status == b.status and
        a.status_changed_at_ms == b.status_changed_at_ms and
        a.completed_at_ms == b.completed_at_ms and
        optionalTextEqual(a.last_event_title, b.last_event_title) and
        optionalTextEqual(a.last_event_body, b.last_event_body);
}

pub const STATE_DB_NAME = "state.sqlite";
pub const TRANSCRIPT_MESSAGE_PAGE_SIZE: usize = 256;
/// First page for a cold thread: enough rows to fill a tall viewport of
/// compact rows, so opening a large historical thread materializes what the
/// user can see instead of a blocking bulk page. Follow-up pages use
/// TRANSCRIPT_MESSAGE_PAGE_SIZE.
pub const TRANSCRIPT_FIRST_PAGE_SIZE: usize = 48;

const ThreadMessages = struct {
    offset: usize,
    messages: []const PersistedMessage,
};

const SchemaCapabilities = struct {
    thread_draft_images: bool,
    thread_cwd: bool,
    thread_runtime_route: bool,
    thread_message_extent: bool,
    message_id: bool,
    message_extra_images: bool,
};

const NoopLoadHook = struct {
    fn afterAppStateRead(_: @This()) !void {}
};

pub const Client = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    path: [:0]u8,
    conn: zqlite.Conn,

    pub fn pathForPrefPath(allocator: std.mem.Allocator, pref_path: []const u8) ![:0]u8 {
        return std.fs.path.joinZ(allocator, &.{ pref_path, STATE_DB_NAME });
    }

    /// Open an existing database without write capability or schema changes.
    pub fn initReadOnly(allocator: std.mem.Allocator, pref_path: []const u8) !Self {
        const path = try pathForPrefPath(allocator, pref_path);
        errdefer allocator.free(path);

        const flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode;
        const conn = try zqlite.open(path, flags);
        errdefer conn.close();

        try conn.busyTimeout(schema.BUSY_TIMEOUT_MS);
        try schema.validateReadOnly(conn);
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

    /// Load a consistent snapshot; do not call this while `self.conn` has an open transaction.
    pub fn load(self: *const Self, backing_allocator: std.mem.Allocator) !?LoadedState {
        return self.loadSnapshot(backing_allocator, NoopLoadHook{}, true);
    }

    /// Load projection metadata without materializing transcript bodies.
    pub fn loadBounded(self: *const Self, backing_allocator: std.mem.Allocator) !?LoadedState {
        return self.loadSnapshot(backing_allocator, NoopLoadHook{}, false);
    }

    /// Load the page of at most `limit` rows immediately preceding
    /// `before_offset` for one durable thread. The caller owns the returned
    /// arena.
    pub fn loadMessagePage(
        self: *const Self,
        backing_allocator: std.mem.Allocator,
        workspace_id: []const u8,
        local_thread_id: []const u8,
        before_offset: usize,
        limit: usize,
    ) !db_types.LoadedMessagePage {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const maybe_row = try self.conn.row(
            "select t.id from threads t join workspaces w on w.id = t.workspace_id " ++
                "where w.workspace_id = ?1 and t.local_thread_id = ?2",
            .{ workspace_id, local_thread_id },
        );
        const row = maybe_row orelse return error.ThreadNotFound;
        defer row.deinit();
        const capabilities = self.schemaCapabilities();
        const page = try self.loadMessages(
            allocator,
            row.int(0),
            before_offset,
            limit,
            capabilities,
        );
        return .{ .arena = arena, .offset = page.offset, .messages = page.messages };
    }

    fn loadSnapshot(
        self: *const Self,
        backing_allocator: std.mem.Allocator,
        hook: anytype,
        load_transcripts: bool,
    ) !?LoadedState {
        try self.conn.transaction();
        errdefer self.conn.rollback();

        const row = try self.conn.row(
            "select selected_workspace_index, sidebar_collapsed from app_state where id = 1",
            .{},
        );
        if (row == null) {
            try self.conn.commit();
            return null;
        }

        var loaded = LoadedState.init(backing_allocator);
        errdefer loaded.deinit();

        {
            var state_row = row.?;
            defer state_row.deinit();
            loaded.value.selected_project_index = @intCast(state_row.int(0));
            loaded.value.sidebar_collapsed = state_row.int(1) != 0;
        }

        try hook.afterAppStateRead();

        const arena = loaded.allocator();
        const capabilities = self.schemaCapabilities();
        var message_offsets: std.AutoHashMapUnmanaged(i64, usize) = .empty;
        defer message_offsets.deinit(arena);
        if (!load_transcripts and !capabilities.thread_message_extent) {
            try self.loadMessageOffsets(arena, &message_offsets);
        }
        var workspaces: std.ArrayList(PersistedProject) = .empty;
        defer workspaces.deinit(arena);
        var workspace_row_ids: std.ArrayList(i64) = .empty;
        defer workspace_row_ids.deinit(arena);

        {
            var workspace_rows = try self.conn.rows(
                "select id, workspace_id, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, terminal_docks_json, workspace_layout_json, selected_thread_index, companion_thread_local_id, " ++
                    "herdr_remote_alias, herdr_session_name, herdr_workspace_id, herdr_local_dir, herdr_remote_cwd, herdr_last_pane_id, herdr_attach_dock_id, herdr_attach_pane_id, herdr_pane_links_json, herdr_updated_at_ms, icon_index, color_index " ++
                    "from workspaces order by sort_index",
                .{},
            );
            defer workspace_rows.deinit();

            while (workspace_rows.next()) |workspace_row| {
                try workspace_row_ids.append(arena, workspace_row.int(0));
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
                    .companion_thread_local_id = try dupeOptionalText(arena, workspace_row.nullableText(13)),
                    .herdr_link = try loadOptionalHerdrLink(
                        arena,
                        workspace_row.nullableText(14),
                        workspace_row.nullableText(15),
                        workspace_row.nullableText(16),
                        workspace_row.nullableText(17),
                        workspace_row.nullableText(18),
                        workspace_row.nullableText(19),
                        workspace_row.nullableInt(20),
                        workspace_row.nullableInt(21),
                        workspace_row.nullableText(22),
                        workspace_row.nullableInt(23),
                    ),
                    .icon_index = if (workspace_row.nullableInt(24)) |value| (if (value >= 0 and value < 16) @as(u8, @intCast(value)) else null) else null,
                    .color_index = if (workspace_row.nullableInt(25)) |value| (if (value >= 0 and value < 8) @as(u8, @intCast(value)) else null) else null,
                    .threads = &.{},
                });
            }
            if (workspace_rows.err) |err| return err;
        }
        try self.loadThreadsForProjects(
            arena,
            workspaces.items,
            workspace_row_ids.items,
            load_transcripts,
            &message_offsets,
            capabilities,
        );

        loaded.value.projects = try workspaces.toOwnedSlice(arena);
        loaded.value.surface_states = try self.loadSurfaceStates(arena);
        loaded.value.chat_completions = try self.loadChatCompletions(arena);
        // Same RO transaction: pin store_revision when the v2+ table exists so
        // GUI sessions reopen with a usable optimistic-concurrency guard.
        if (self.conn.row("select store_revision from store_state where id = 1", .{})) |rev_row_opt| {
            if (rev_row_opt) |rev_row| {
                defer rev_row.deinit();
                loaded.store_revision = @intCast(@max(rev_row.int(0), 0));
            }
        } else |_| {
            // Pre-v2 DBs (or missing table) leave revision 0; daemon migration
            // creates store_state before the first client mutation.
        }
        // Note: `row` returns error when the table is missing — caught above.
        try self.conn.commit();
        return loaded;
    }

    /// Standalone revision read for DBs whose projection is empty (e.g. a
    /// CLI-notify-only history has no app_state row but a real revision).
    pub fn storeRevision(self: *const Self) !u64 {
        if (self.conn.row("select store_revision from store_state where id = 1", .{})) |rev_row_opt| {
            if (rev_row_opt) |rev_row| {
                defer rev_row.deinit();
                return @intCast(@max(rev_row.int(0), 0));
            }
            return 0;
        } else |_| {
            // Pre-v2 DBs / missing table: revision 0.
            return 0;
        }
    }

    /// Verify that one exact mutation fingerprint has a successful durable
    /// receipt at the revision returned to its caller.
    pub fn committedReceiptMatches(
        self: *const Self,
        request_key: []const u8,
        operation: []const u8,
        fingerprint: []const u8,
        store_revision: u64,
    ) !bool {
        const row = (try self.conn.row(
            "select operation, fingerprint, store_revision, response_status from store_receipts where request_key = ?1",
            .{request_key},
        )) orelse return false;
        defer row.deinit();
        if (row.int(2) < 0) return false;
        return std.mem.eql(u8, row.text(0), operation) and
            std.mem.eql(u8, row.text(1), fingerprint) and
            @as(u64, @intCast(row.int(2))) == store_revision and
            row.int(3) == 0;
    }

    /// Compare one canonical surface against the current durable row. Receipt
    /// history alone is insufficient because a later opposite mutation may
    /// have superseded an otherwise valid proof.
    pub fn surfaceStateMatches(self: *const Self, surface: PersistedSurfaceState) !bool {
        const row = (try self.conn.row(
            "select workspace_id, workspace_path, dock_id, pane_id, provider, provider_thread_id, title, status, status_changed_at_ms, completed_at_ms, last_event_title, last_event_body from surface_completions where session_id = ?1",
            .{surface.session_id},
        )) orelse return false;
        defer row.deinit();
        return std.mem.eql(u8, row.text(0), surface.workspace_id) and
            std.mem.eql(u8, row.text(1), surface.workspace_path) and
            row.int(2) == @as(i64, @intCast(surface.dock_id)) and
            optionalIntEqual(row.nullableInt(3), if (surface.pane_id) |value| @as(i64, @intCast(value)) else null) and
            optionalIntEqual(row.nullableInt(4), if (surface.provider) |value| @as(i64, @intFromEnum(value)) else null) and
            optionalTextEqual(row.nullableText(5), surface.provider_thread_id) and
            std.mem.eql(u8, row.text(6), surface.title) and
            row.int(7) == @as(i64, @intFromEnum(surface.status)) and
            row.int(8) == surface.status_changed_at_ms and
            row.int(9) == surface.completed_at_ms and
            optionalTextEqual(row.nullableText(10), surface.last_event_title) and
            optionalTextEqual(row.nullableText(11), surface.last_event_body);
    }

    pub fn surfaceStateAbsent(self: *const Self, session_id: []const u8) !bool {
        const row = try self.conn.row(
            "select 1 from surface_completions where session_id = ?1",
            .{session_id},
        );
        if (row) |present| present.deinit();
        return row == null;
    }

    pub fn surfaceCompletionMatches(self: *const Self, session_id: []const u8, completed_at_ms: i64) !bool {
        const row = (try self.conn.row(
            "select status, completed_at_ms from surface_completions where session_id = ?1",
            .{session_id},
        )) orelse return false;
        defer row.deinit();
        return row.int(0) == @as(i64, @intFromEnum(db_types.SurfaceStatus.done)) and
            row.int(1) == completed_at_ms;
    }

    fn loadSurfaceStates(self: *const Self, allocator: std.mem.Allocator) ![]const PersistedSurfaceState {
        var surfaces: std.ArrayList(PersistedSurfaceState) = .empty;
        defer surfaces.deinit(allocator);

        var rows = try self.conn.rows(
            "select session_id, workspace_id, workspace_path, dock_id, pane_id, provider, provider_thread_id, title, status, status_changed_at_ms, completed_at_ms, last_event_title, last_event_body " ++
                "from surface_completions order by status_changed_at_ms, session_id",
            .{},
        );
        defer rows.deinit();

        while (rows.next()) |row| {
            const status = decodeEnumOr(db_types.SurfaceStatus, row.int(8), .done);
            const completed_at_ms = row.int(10);
            const stored_changed_at_ms = row.int(9);
            try surfaces.append(allocator, .{
                .session_id = try allocator.dupe(u8, row.text(0)),
                .workspace_id = try allocator.dupe(u8, row.text(1)),
                .workspace_path = try allocator.dupe(u8, row.text(2)),
                .dock_id = @intCast(row.int(3)),
                .pane_id = if (row.nullableInt(4)) |value| @intCast(value) else null,
                .provider = decodeOptionalEnum(db_types.SurfaceProvider, row.nullableInt(5)),
                .provider_thread_id = try dupeOptionalText(allocator, row.nullableText(6)),
                .title = try allocator.dupe(u8, row.text(7)),
                .status = status,
                // Existing completion rows predate this column. Their
                // completion timestamp is the authoritative change time.
                .status_changed_at_ms = if (stored_changed_at_ms != 0) stored_changed_at_ms else completed_at_ms,
                .completed_at_ms = completed_at_ms,
                .last_event_title = try dupeOptionalText(allocator, row.nullableText(11)),
                .last_event_body = try dupeOptionalText(allocator, row.nullableText(12)),
            });
        }
        if (rows.err) |err| return err;
        return try surfaces.toOwnedSlice(allocator);
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

    /// Probe for an additive column so a projection written by an older,
    /// not-yet-migrated daemon still loads (mirrors the message_id probe).
    fn hasColumn(self: *const Self, comptime table: []const u8, comptime column: []const u8) bool {
        const probe = self.conn.row(
            "select 1 from pragma_table_info('" ++ table ++ "') where name = '" ++ column ++ "'",
            .{},
        ) catch return false;
        const row = probe orelse return false;
        row.deinit();
        return true;
    }

    fn hasThreadRouteColumns(self: *const Self) bool {
        return self.hasColumn("threads", "profile_id") and
            self.hasColumn("threads", "runtime_id") and
            self.hasColumn("threads", "repository_id") and
            self.hasColumn("threads", "repository_cwd");
    }

    fn schemaCapabilities(self: *const Self) SchemaCapabilities {
        return .{
            .thread_draft_images = self.hasColumn("threads", "draft_images_json"),
            .thread_cwd = self.hasColumn("threads", "cwd"),
            .thread_runtime_route = self.hasThreadRouteColumns(),
            .thread_message_extent = self.hasColumn("threads", "message_extent"),
            .message_id = self.hasColumn("messages", "message_id"),
            .message_extra_images = self.hasColumn("messages", "extra_images_json"),
        };
    }

    fn loadThreadsForProjects(
        self: *const Self,
        allocator: std.mem.Allocator,
        projects: []PersistedProject,
        workspace_row_ids: []const i64,
        load_transcripts: bool,
        message_offsets: *const std.AutoHashMapUnmanaged(i64, usize),
        capabilities: SchemaCapabilities,
    ) !void {
        if (projects.len != workspace_row_ids.len) return error.DatabaseCorrupt;
        var project_index_by_row: std.AutoHashMapUnmanaged(i64, usize) = .empty;
        defer project_index_by_row.deinit(allocator);
        for (workspace_row_ids, 0..) |row_id, project_index| {
            try project_index_by_row.put(allocator, row_id, project_index);
        }

        const PendingThread = struct {
            project_index: usize,
            row_id: i64,
            thread: PersistedThread,
        };
        var pending: std.ArrayList(PendingThread) = .empty;
        defer pending.deinit(allocator);

        const select_prefix = "select t.id, t.title, t.archived, t.committed, t.local_thread_id, t.last_activity_at, t.provider_thread_id, t.model_ref, t.reasoning_effort, t.reasoning_variant, t.fast_mode, t.access_mode, t.provider, t.harness, t.tui_dock_id, t.draft, t.draft_image_path, t.draft_image_mime, t.draft_image_byte_size, ";
        const route_columns = if (capabilities.thread_runtime_route)
            if (capabilities.thread_draft_images and capabilities.thread_cwd)
                "t.draft_images_json, t.cwd, t.profile_id, t.runtime_id, t.repository_id, t.repository_cwd"
            else if (capabilities.thread_draft_images)
                "t.draft_images_json, null, t.profile_id, t.runtime_id, t.repository_id, t.repository_cwd"
            else if (capabilities.thread_cwd)
                "null, t.cwd, t.profile_id, t.runtime_id, t.repository_id, t.repository_cwd"
            else
                "null, null, t.profile_id, t.runtime_id, t.repository_id, t.repository_cwd"
        else if (capabilities.thread_draft_images and capabilities.thread_cwd)
            "t.draft_images_json, t.cwd, null, null, null, null"
        else if (capabilities.thread_draft_images)
            "t.draft_images_json, null, null, null, null, null"
        else if (capabilities.thread_cwd)
            "null, t.cwd, null, null, null, null"
        else
            "null, null, null, null, null, null";
        const extent_column = if (capabilities.thread_message_extent) ", t.message_extent" else ", null";
        const query = try std.mem.concat(allocator, u8, &.{
            select_prefix,
            route_columns,
            extent_column,
            ", t.workspace_id from threads t join workspaces w on w.id = t.workspace_id order by w.sort_index, t.sort_index",
        });
        defer allocator.free(query);
        {
            var thread_rows = try self.conn.rows(query, .{});
            defer thread_rows.deinit();

            while (thread_rows.next()) |thread_row| {
                const thread_id = thread_row.int(0);
                const project_index = project_index_by_row.get(thread_row.int(26)) orelse
                    return error.DatabaseCorrupt;
                try pending.append(allocator, .{
                    .project_index = project_index,
                    .row_id = thread_id,
                    .thread = .{
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
                        .cwd = try dupeOptionalText(allocator, thread_row.nullableText(20)),
                        .profile_id = try dupeOptionalText(allocator, thread_row.nullableText(21)),
                        .runtime_id = try dupeOptionalText(allocator, thread_row.nullableText(22)),
                        .repository_id = try dupeOptionalText(allocator, thread_row.nullableText(23)),
                        .repository_cwd = try dupeOptionalText(allocator, thread_row.nullableText(24)),
                        .draft = try allocator.dupe(u8, thread_row.text(15)),
                        .draft_image = try loadOptionalImage(
                            allocator,
                            thread_row.nullableText(16),
                            thread_row.nullableText(17),
                            thread_row.nullableInt(18),
                        ),
                        .draft_extra_images = try loadExtraImages(allocator, thread_row.nullableText(19)),
                        .message_offset = if (capabilities.thread_message_extent)
                            @intCast(thread_row.int(25))
                        else
                            message_offsets.get(thread_id) orelse 0,
                        .messages = &.{},
                    },
                });
            }
            if (thread_rows.err) |err| return err;
        }

        var thread_lists = try allocator.alloc(std.ArrayList(PersistedThread), projects.len);
        defer allocator.free(thread_lists);
        for (thread_lists) |*list| list.* = .empty;
        defer for (thread_lists) |*list| list.deinit(allocator);

        for (pending.items) |*item| {
            if (load_transcripts) {
                const loaded = try self.loadMessages(
                    allocator,
                    item.row_id,
                    null,
                    std.math.maxInt(usize),
                    capabilities,
                );
                item.thread.message_offset = loaded.offset;
                item.thread.messages = loaded.messages;
            }
            try thread_lists[item.project_index].append(allocator, item.thread);
        }
        for (projects, 0..) |*project, project_index| {
            project.threads = try thread_lists[project_index].toOwnedSlice(allocator);
        }
    }

    /// Load every transcript extent once for a bounded projection. The old
    /// limit=0 path still executed one max(sort_index) statement per thread,
    /// turning projection refresh into an N+1 query across large histories.
    fn loadMessageOffsets(
        self: *const Self,
        allocator: std.mem.Allocator,
        offsets: *std.AutoHashMapUnmanaged(i64, usize),
    ) !void {
        var rows = try self.conn.rows(
            "select thread_id, coalesce(max(sort_index) + 1, 0) from messages group by thread_id",
            .{},
        );
        defer rows.deinit();
        while (rows.next()) |row| {
            try offsets.put(allocator, row.int(0), @intCast(row.int(1)));
        }
        if (rows.err) |err| return err;
    }

    fn loadMessages(
        self: *const Self,
        allocator: std.mem.Allocator,
        thread_id: i64,
        before_offset: ?usize,
        limit: usize,
        capabilities: SchemaCapabilities,
    ) !ThreadMessages {
        var messages: std.ArrayList(PersistedMessage) = .empty;
        defer messages.deinit(allocator);

        const count_row = (try self.conn.row(
            "select coalesce(max(sort_index) + 1, 0) from messages where thread_id = ?1",
            .{thread_id},
        )) orelse return .{ .offset = 0, .messages = &.{} };
        defer count_row.deinit();
        const total: usize = @intCast(count_row.int(0));
        const end = @min(before_offset orelse total, total);
        const offset = end - @min(end, limit);

        // M4-P4 identity round-trip: durable message identities must reload
        // verbatim so the next flush re-carries them instead of re-minting
        // positional ids. Pre-v4 projections (daemon not yet migrated) lack
        // the column; validateReadOnly accepts them, so probe before select.
        var message_rows = try self.conn.rows(
            if (capabilities.message_id and capabilities.message_extra_images)
                "select role, author, body, image_path, image_mime, image_byte_size, tool_call_id, tool_call_kind, tool_call_status, message_id, extra_images_json " ++
                    "from messages where thread_id = ?1 and sort_index >= ?2 and sort_index < ?3 order by sort_index"
            else if (capabilities.message_id)
                "select role, author, body, image_path, image_mime, image_byte_size, tool_call_id, tool_call_kind, tool_call_status, message_id, null " ++
                    "from messages where thread_id = ?1 and sort_index >= ?2 and sort_index < ?3 order by sort_index"
            else
                "select role, author, body, image_path, image_mime, image_byte_size, tool_call_id, tool_call_kind, tool_call_status, null, null " ++
                    "from messages where thread_id = ?1 and sort_index >= ?2 and sort_index < ?3 order by sort_index",
            .{ thread_id, @as(i64, @intCast(offset)), @as(i64, @intCast(end)) },
        );
        defer message_rows.deinit();

        while (message_rows.next()) |message_row| {
            const author = message_row.text(1);
            try messages.append(allocator, .{
                .role = db_types.decodeStoredChatRole(message_row.int(0), author),
                .author = try allocator.dupe(u8, author),
                .body = try allocator.dupe(u8, message_row.text(2)),
                .image = try loadOptionalImage(
                    allocator,
                    message_row.nullableText(3),
                    message_row.nullableText(4),
                    message_row.nullableInt(5),
                ),
                .extra_images = try loadExtraImages(allocator, message_row.nullableText(10)),
                .tool_call_id = try dupeOptionalText(allocator, message_row.nullableText(6)),
                .tool_call_kind = decodeOptionalEnum(provider_types.ToolCallKind, message_row.nullableInt(7)),
                .tool_call_status = decodeOptionalEnum(provider_types.ToolCallStatus, message_row.nullableInt(8)),
                // Empty string normalizes to null: "no identity known".
                .message_id = blk: {
                    const raw = message_row.nullableText(9) orelse break :blk null;
                    if (raw.len == 0) break :blk null;
                    break :blk try allocator.dupe(u8, raw);
                },
            });
        }
        if (message_rows.err) |err| return err;

        return .{ .offset = offset, .messages = try messages.toOwnedSlice(allocator) };
    }
};

/// Decode the additive `*_images_json` column (attachments past the primary)
/// into persisted attachments. Malformed JSON degrades to "no extras" rather
/// than failing the whole projection load; the daemon read path warns on the
/// same condition.
fn loadExtraImages(
    allocator: std.mem.Allocator,
    encoded: ?[]const u8,
) ![]const PersistedImageAttachment {
    const text = encoded orelse return &.{};
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        []schema.StoredExtraImage,
        arena_state.allocator(),
        text,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return &.{};
    };
    if (parsed.len == 0) return &.{};
    const out = try allocator.alloc(PersistedImageAttachment, parsed.len);
    for (parsed, 0..) |image, index| {
        out[index] = .{
            .path = try allocator.dupe(u8, image.path),
            .mime = try allocator.dupe(u8, image.mime),
            .byte_size = std.math.cast(usize, image.byte_size) orelse 0,
        };
    }
    return out;
}

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

test "projection load bounds transcript tails and pages older rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    {
        var writer = try testInitMigrated(testing.allocator, pref_path);
        defer writer.deinit();
        try testSeedThread(writer.conn, "paged-workspace", "Paged", "/tmp/paged", "paged-thread", "Paged");
        for (0..TRANSCRIPT_MESSAGE_PAGE_SIZE + 8) |index| {
            const user = index % 2 == 0;
            try testSeedMessage(writer.conn, "paged-thread", index, if (user) 0 else 1, if (user) "You" else "Assistant", if (index < 8) "older" else "tail");
        }
    }

    var reader = try Client.initReadOnly(testing.allocator, pref_path);
    defer reader.deinit();
    var loaded = (try reader.loadBounded(testing.allocator)).?;
    defer loaded.deinit();
    const loaded_thread = loaded.value.projects[0].threads.?[0];
    try testing.expectEqual(TRANSCRIPT_MESSAGE_PAGE_SIZE + 8, loaded_thread.message_offset);
    try testing.expectEqual(@as(usize, 0), loaded_thread.messages.len);

    var tail_page = try reader.loadMessagePage(
        testing.allocator,
        "paged-workspace",
        "paged-thread",
        loaded_thread.message_offset,
        TRANSCRIPT_MESSAGE_PAGE_SIZE,
    );
    defer tail_page.deinit();
    try testing.expectEqual(@as(usize, 8), tail_page.offset);
    try testing.expectEqual(TRANSCRIPT_MESSAGE_PAGE_SIZE, tail_page.messages.len);
    try testing.expectEqualStrings("tail", tail_page.messages[0].body);

    var old_page = try reader.loadMessagePage(
        testing.allocator,
        "paged-workspace",
        "paged-thread",
        tail_page.offset,
        TRANSCRIPT_MESSAGE_PAGE_SIZE,
    );
    defer old_page.deinit();
    try testing.expectEqual(@as(usize, 0), old_page.offset);
    try testing.expectEqual(@as(usize, 8), old_page.messages.len);
    try testing.expectEqualStrings("older", old_page.messages[0].body);

    // Viewport-sized first page: a smaller limit pages in only the newest rows.
    var first_page = try reader.loadMessagePage(
        testing.allocator,
        "paged-workspace",
        "paged-thread",
        loaded_thread.message_offset,
        TRANSCRIPT_FIRST_PAGE_SIZE,
    );
    defer first_page.deinit();
    try testing.expectEqual(loaded_thread.message_offset - TRANSCRIPT_FIRST_PAGE_SIZE, first_page.offset);
    try testing.expectEqual(TRANSCRIPT_FIRST_PAGE_SIZE, first_page.messages.len);
}

fn dupeOptionalText(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const text = value orelse return null;
    return try allocator.dupe(u8, text);
}

fn decodeOptionalEnum(comptime Enum: type, raw: ?i64) ?Enum {
    const value = raw orelse return null;
    const enum_value: u8 = @intCast(value);
    inline for (std.meta.fields(Enum)) |field| {
        if (field.value == enum_value) return @enumFromInt(enum_value);
    }
    return null;
}

fn optionalIntEqual(actual: ?i64, expected: ?i64) bool {
    if (actual) |actual_value| return if (expected) |expected_value| actual_value == expected_value else false;
    return expected == null;
}

fn optionalTextEqual(actual: ?[]const u8, expected: ?[]const u8) bool {
    if (actual) |actual_value| return if (expected) |expected_value| std.mem.eql(u8, actual_value, expected_value) else false;
    return expected == null;
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

/// Open a writable connection migrated to the v1 projection schema. Tests
/// stage fixtures through it; production writes go through the daemon store.
fn testInitMigrated(allocator: std.mem.Allocator, pref_path: []const u8) !Client {
    const path = try Client.pathForPrefPath(allocator, pref_path);
    errdefer allocator.free(path);
    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    errdefer conn.close();
    try schema.initialize(conn);
    return .{ .allocator = allocator, .path = path, .conn = conn };
}

/// Insert the singleton app state row (if absent) and append one workspace.
fn testSeedWorkspace(conn: zqlite.Conn, workspace_id: []const u8, label: []const u8, path: []const u8) !void {
    try conn.execNoArgs("insert or ignore into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, 0, 0)");
    try conn.exec(
        "insert into workspaces (workspace_id, sort_index, label, path) values (?1, (select coalesce(max(sort_index) + 1, 0) from workspaces), ?2, ?3)",
        .{ workspace_id, label, path },
    );
}

fn testSeedThread(
    conn: zqlite.Conn,
    workspace_id: []const u8,
    workspace_label: []const u8,
    workspace_path: []const u8,
    local_thread_id: []const u8,
    title: []const u8,
) !void {
    try testSeedWorkspace(conn, workspace_id, workspace_label, workspace_path);
    try conn.exec(
        "insert into threads (workspace_id, sort_index, title, local_thread_id, provider, harness) " ++
            "select id, 0, ?2, ?3, ?4, ?5 from workspaces where workspace_id = ?1",
        .{
            workspace_id,
            title,
            local_thread_id,
            @as(i64, @intFromEnum(db_types.Provider.opencode)),
            @as(i64, @intFromEnum(db_types.Harness.local_cli)),
        },
    );
}

/// `role` is the raw on-disk code so fixtures can reproduce historical rows.
fn testSeedMessage(conn: zqlite.Conn, local_thread_id: []const u8, sort_index: usize, role: i64, author: []const u8, body: []const u8) !void {
    try conn.exec(
        "insert into messages (thread_id, sort_index, role, author, body) " ++
            "select id, ?2, ?3, ?4, ?5 from threads where local_thread_id = ?1",
        .{ local_thread_id, @as(i64, @intCast(sort_index)), role, author, body },
    );
}

fn testOpenDatabase(allocator: std.mem.Allocator, pref_path: []const u8) !zqlite.Conn {
    const path = try Client.pathForPrefPath(allocator, pref_path);
    defer allocator.free(path);
    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    return zqlite.open(path, flags);
}

fn testCreateLegacyFixture(pref_path: []const u8) !void {
    const conn = try testOpenDatabase(testing.allocator, pref_path);
    defer conn.close();
    try conn.execNoArgs(migration_fixture.LEGACY_V0_SQL);
}

fn testExpectShippedFixtureRoleCodes(conn: zqlite.Conn) !void {
    const expected = [_]i64{ 0, 1, 2, 0, 1 };
    var rows = try conn.rows("select role from messages order by id", .{});
    defer rows.deinit();
    var index: usize = 0;
    while (rows.next()) |row| : (index += 1) {
        try testing.expect(index < expected.len);
        try testing.expectEqual(expected[index], row.int(0));
    }
    if (rows.err) |err| return err;
    try testing.expectEqual(expected.len, index);
}

fn testUserVersion(conn: zqlite.Conn) !i64 {
    var row = (try conn.row("pragma user_version", .{})).?;
    defer row.deinit();
    return row.int(0);
}

fn testExpectRowCount(conn: zqlite.Conn, table_name: []const u8, expected: i64) !void {
    var sql_buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrint(&sql_buf, "select count(*) from {s}", .{table_name});
    var row = (try conn.row(sql, .{})).?;
    defer row.deinit();
    try testing.expectEqual(expected, row.int(0));
}

fn testExpectStableId(conn: zqlite.Conn, sql: []const u8, key: []const u8, expected: i64) !void {
    var row = (try conn.row(sql, .{key})).?;
    defer row.deinit();
    try testing.expectEqual(expected, row.int(0));
}

fn testExpectDatabaseChecks(conn: zqlite.Conn) !void {
    var integrity = (try conn.row("pragma integrity_check", .{})).?;
    defer integrity.deinit();
    try testing.expectEqualStrings("ok", integrity.text(0));

    var foreign_keys = try conn.rows("pragma foreign_key_check", .{});
    defer foreign_keys.deinit();
    try testing.expect(foreign_keys.next() == null);
    if (foreign_keys.err) |err| return err;
}

fn testExpectLegacyFixtureState(state: PersistedState, expected_reasoning_variant: ?[]const u8) !void {
    try testing.expectEqual(@as(usize, 1), state.selected_project_index);
    try testing.expect(state.sidebar_collapsed);
    try testing.expectEqual(@as(usize, 2), state.projects.len);

    const active = state.projects[0];
    try testing.expectEqualStrings("workspace-α", active.id.?);
    try testing.expectEqualStrings("Montréal 🚀", active.label);
    try testing.expectEqualStrings("/tmp/verde/équipe", active.path);
    try testing.expect(!active.archived);
    try testing.expectEqual(@as(u8, 7), active.unread_count);
    try testing.expect(active.collapsed.?);
    try testing.expect(active.thread_list_expanded.?);
    try testing.expectEqual(@as(?f32, 384.5), active.terminal_height);
    try testing.expectEqualStrings("{\"root\":\"terminal\"}", active.terminal_layout_json.?);
    try testing.expectEqualStrings("[{\"id\":4}]", active.terminal_docks_json.?);
    try testing.expectEqualStrings("{\"pane\":\"chat\"}", active.workspace_layout_json.?);
    try testing.expectEqual(@as(usize, 0), active.selected_thread_index);
    try testing.expectEqualStrings("thread-archived", active.companion_thread_local_id.?);
    const herdr = active.herdr_link.?;
    try testing.expectEqualStrings("zod.example", herdr.remote_alias);
    try testing.expectEqualStrings("défaut", herdr.session_name);
    try testing.expectEqualStrings("remote-α", herdr.workspace_id);
    try testing.expectEqualStrings("/tmp/verde/équipe", herdr.local_dir);
    try testing.expectEqualStrings("/srv/工程", herdr.remote_cwd.?);
    try testing.expectEqualStrings("pane-九", herdr.last_pane_id.?);
    try testing.expectEqual(@as(?u32, 4), herdr.attach_dock_id);
    try testing.expectEqual(@as(?u32, 9), herdr.attach_pane_id);
    try testing.expectEqualStrings("[{\"verde_pane_id\":9}]", herdr.pane_links_json.?);
    try testing.expectEqual(@as(i64, 1700000000123), herdr.updated_at_ms);

    const active_threads = active.threads.?;
    try testing.expectEqual(@as(usize, 2), active_threads.len);
    const thread = active_threads[0];
    try testing.expectEqualStrings("thread-active", thread.local_thread_id.?);
    try testing.expectEqualStrings("Active café", thread.title);
    try testing.expect(!thread.archived);
    try testing.expect(thread.committed);
    try testing.expectEqual(@as(?i64, 1700000001000), thread.last_activity_at);
    try testing.expectEqualStrings("provider-活", thread.provider_thread_id.?);
    try testing.expectEqualStrings("openai/gpt-5", thread.model_ref.?);
    try testing.expectEqual(db_types.ReasoningEffort.high, thread.reasoning_effort.?);
    if (expected_reasoning_variant) |variant| {
        try testing.expectEqualStrings(variant, thread.reasoning_variant.?);
    } else {
        try testing.expect(thread.reasoning_variant == null);
    }
    try testing.expectEqual(db_types.FastMode.on, thread.fast_mode.?);
    try testing.expectEqual(db_types.AccessMode.full_access, thread.access_mode.?);
    try testing.expectEqual(db_types.Provider.codex, thread.provider);
    try testing.expectEqual(db_types.Harness.local_cli, thread.harness);
    try testing.expectEqual(@as(?u32, 4), thread.tui_dock_id);
    try testing.expectEqualStrings("draft — keep exactly", thread.draft);
    try testing.expectEqualStrings("/tmp/draft-猫.png", thread.draft_image.?.path);
    try testing.expectEqualStrings("image/png", thread.draft_image.?.mime);
    try testing.expectEqual(@as(usize, 4242), thread.draft_image.?.byte_size);
    try testing.expectEqual(@as(usize, 3), thread.messages.len);
    try testing.expectEqual(db_types.ChatRole.user, thread.messages[0].role);
    try testing.expectEqualStrings("You", thread.messages[0].author);
    try testing.expectEqualStrings("Hello, 世界 👋", thread.messages[0].body);
    try testing.expectEqualStrings("/tmp/input-λ.jpg", thread.messages[0].image.?.path);
    try testing.expectEqualStrings("image/jpeg", thread.messages[0].image.?.mime);
    try testing.expectEqual(@as(usize, 12345), thread.messages[0].image.?.byte_size);
    try testing.expectEqual(db_types.ChatRole.assistant, thread.messages[1].role);
    try testing.expectEqualStrings("Codex", thread.messages[1].author);
    try testing.expectEqualStrings("It's persisted — café", thread.messages[1].body);
    try testing.expectEqual(db_types.ChatRole.system, thread.messages[2].role);
    try testing.expectEqualStrings("Ran command", thread.messages[2].author);
    try testing.expectEqualStrings("$ printf '✓'", thread.messages[2].body);
    try testing.expectEqualStrings("call-π", thread.messages[2].tool_call_id.?);
    try testing.expectEqual(provider_types.ToolCallKind.execute, thread.messages[2].tool_call_kind.?);
    try testing.expectEqual(provider_types.ToolCallStatus.completed, thread.messages[2].tool_call_status.?);

    const archived_thread = active_threads[1];
    try testing.expectEqualStrings("thread-archived", archived_thread.local_thread_id.?);
    try testing.expectEqualStrings("Archived thread 🗄️", archived_thread.title);
    try testing.expect(archived_thread.archived);
    try testing.expect(archived_thread.committed);
    try testing.expectEqual(@as(?i64, 1700000002000), archived_thread.last_activity_at);
    try testing.expect(archived_thread.provider_thread_id == null);
    try testing.expectEqualStrings("opencode/model", archived_thread.model_ref.?);
    try testing.expectEqual(db_types.ReasoningEffort.medium, archived_thread.reasoning_effort.?);
    try testing.expectEqual(db_types.FastMode.off, archived_thread.fast_mode.?);
    try testing.expectEqual(db_types.AccessMode.supervised, archived_thread.access_mode.?);
    try testing.expectEqual(db_types.Provider.opencode, archived_thread.provider);
    try testing.expectEqual(db_types.Harness.remote_session, archived_thread.harness);
    try testing.expect(archived_thread.tui_dock_id == null);
    try testing.expectEqualStrings("", archived_thread.draft);
    try testing.expect(archived_thread.draft_image == null);
    try testing.expectEqual(@as(usize, 1), archived_thread.messages.len);
    try testing.expectEqual(db_types.ChatRole.user, archived_thread.messages[0].role);
    try testing.expectEqualStrings("You", archived_thread.messages[0].author);
    try testing.expectEqualStrings("Archived question ¿qué?", archived_thread.messages[0].body);

    const archived_workspace = state.projects[1];
    try testing.expectEqualStrings("workspace-archive", archived_workspace.id.?);
    try testing.expectEqualStrings("Archive Ω", archived_workspace.label);
    try testing.expectEqualStrings("C:/Users/Test/Verde Ω", archived_workspace.path);
    try testing.expect(archived_workspace.archived);
    try testing.expectEqual(@as(u8, 0), archived_workspace.unread_count);
    try testing.expect(!archived_workspace.collapsed.?);
    try testing.expect(!archived_workspace.thread_list_expanded.?);
    try testing.expect(archived_workspace.terminal_height == null);
    try testing.expect(archived_workspace.terminal_layout_json == null);
    try testing.expect(archived_workspace.terminal_docks_json == null);
    try testing.expect(archived_workspace.workspace_layout_json == null);
    try testing.expectEqual(@as(usize, 0), archived_workspace.selected_thread_index);
    try testing.expect(archived_workspace.companion_thread_local_id == null);
    try testing.expect(archived_workspace.herdr_link == null);
    try testing.expectEqual(@as(usize, 1), archived_workspace.threads.?.len);
    const workspace_archived_thread = archived_workspace.threads.?[0];
    try testing.expectEqualStrings("thread-workspace-archive", workspace_archived_thread.local_thread_id.?);
    try testing.expectEqualStrings("Workspace archive thread", workspace_archived_thread.title);
    try testing.expect(workspace_archived_thread.archived);
    try testing.expect(workspace_archived_thread.committed);
    try testing.expectEqual(@as(?i64, 1700000003000), workspace_archived_thread.last_activity_at);
    try testing.expectEqualStrings("provider-old", workspace_archived_thread.provider_thread_id.?);
    try testing.expect(workspace_archived_thread.model_ref == null);
    try testing.expect(workspace_archived_thread.reasoning_effort == null);
    try testing.expect(workspace_archived_thread.fast_mode == null);
    try testing.expect(workspace_archived_thread.access_mode == null);
    try testing.expectEqual(db_types.Provider.cursor, workspace_archived_thread.provider);
    try testing.expectEqual(db_types.Harness.local_cli, workspace_archived_thread.harness);
    try testing.expectEqual(@as(?u32, 12), workspace_archived_thread.tui_dock_id);
    try testing.expectEqualStrings("再開", workspace_archived_thread.draft);
    try testing.expectEqual(@as(usize, 1), workspace_archived_thread.messages.len);
    try testing.expectEqual(db_types.ChatRole.assistant, workspace_archived_thread.messages[0].role);
    try testing.expectEqualStrings("Claude", workspace_archived_thread.messages[0].author);
    try testing.expectEqualStrings("旧 workspace answer", workspace_archived_thread.messages[0].body);

    try testing.expectEqual(@as(usize, 2), state.surface_states.len);
    try testing.expectEqualStrings("session-α", state.surface_states[0].session_id);
    try testing.expectEqualStrings("workspace-α", state.surface_states[0].workspace_id);
    try testing.expectEqualStrings("/tmp/verde/équipe", state.surface_states[0].workspace_path);
    try testing.expectEqual(@as(u32, 4), state.surface_states[0].dock_id);
    try testing.expectEqual(@as(?u32, 9), state.surface_states[0].pane_id);
    try testing.expectEqual(db_types.SurfaceProvider.codex, state.surface_states[0].provider.?);
    try testing.expectEqualStrings("provider-活", state.surface_states[0].provider_thread_id.?);
    try testing.expectEqualStrings("Build ✓", state.surface_states[0].title);
    try testing.expectEqual(db_types.SurfaceStatus.done, state.surface_states[0].status);
    try testing.expectEqual(@as(i64, 1700000004000), state.surface_states[0].status_changed_at_ms);
    try testing.expectEqual(@as(i64, 1700000004000), state.surface_states[0].completed_at_ms);
    try testing.expectEqualStrings("Ran command", state.surface_states[0].last_event_title.?);
    try testing.expectEqualStrings("全部 good", state.surface_states[0].last_event_body.?);
    try testing.expectEqualStrings("session-error", state.surface_states[1].session_id);
    try testing.expectEqualStrings("workspace-archive", state.surface_states[1].workspace_id);
    try testing.expectEqualStrings("C:/Users/Test/Verde Ω", state.surface_states[1].workspace_path);
    try testing.expectEqual(@as(u32, 12), state.surface_states[1].dock_id);
    try testing.expect(state.surface_states[1].pane_id == null);
    try testing.expectEqual(db_types.SurfaceProvider.claude, state.surface_states[1].provider.?);
    try testing.expect(state.surface_states[1].provider_thread_id == null);
    try testing.expectEqualStrings("Failure ⚠", state.surface_states[1].title);
    try testing.expectEqual(db_types.SurfaceStatus.@"error", state.surface_states[1].status);
    try testing.expectEqual(@as(i64, 1700000005000), state.surface_states[1].status_changed_at_ms);
    try testing.expectEqual(@as(i64, 0), state.surface_states[1].completed_at_ms);
    try testing.expectEqualStrings("Command failed", state.surface_states[1].last_event_title.?);
    try testing.expectEqualStrings("exit 2 — Ω", state.surface_states[1].last_event_body.?);

    try testing.expectEqual(@as(usize, 2), state.chat_completions.len);
    try testing.expectEqualStrings("workspace-α", state.chat_completions[0].workspace_id);
    try testing.expectEqualStrings("thread-active", state.chat_completions[0].local_thread_id);
    try testing.expectEqual(@as(i64, 1700000006000), state.chat_completions[0].completed_at_ms);
    try testing.expectEqualStrings("workspace-archive", state.chat_completions[1].workspace_id);
    try testing.expectEqualStrings("thread-workspace-archive", state.chat_completions[1].local_thread_id);
    try testing.expectEqual(@as(i64, 1700000007000), state.chat_completions[1].completed_at_ms);
}

test "read-only open cannot migrate a legacy database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);
    try testCreateLegacyFixture(pref_path);

    try testing.expectError(error.DatabaseSchemaTooOld, Client.initReadOnly(testing.allocator, pref_path));

    const conn = try testOpenDatabase(testing.allocator, pref_path);
    defer conn.close();
    try testing.expectEqual(@as(i64, 0), try testUserVersion(conn));
    try testing.expect(!try schema.testHasColumn(conn, "threads", "reasoning_variant"));
    try testExpectRowCount(conn, "messages", 5);
}

test "load holds one WAL snapshot across all reads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var writer = try testInitMigrated(testing.allocator, pref_path);
    defer writer.deinit();
    try testSeedWorkspace(writer.conn, "workspace-1", "before", "/tmp/workspace");

    var reader = try Client.initReadOnly(testing.allocator, pref_path);
    defer reader.deinit();
    const UpdateAfterFirstRead = struct {
        conn: zqlite.Conn,

        fn afterAppStateRead(self: @This()) !void {
            try self.conn.transaction();
            errdefer self.conn.rollback();
            try self.conn.execNoArgs(
                \\update app_state set selected_workspace_index = 1 where id = 1;
                \\update workspaces set label = 'after' where workspace_id = 'workspace-1';
            );
            try self.conn.commit();
        }
    };

    var loaded = (try reader.loadSnapshot(testing.allocator, UpdateAfterFirstRead{ .conn = writer.conn }, true)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 0), loaded.value.selected_project_index);
    try testing.expectEqualStrings("before", loaded.value.projects[0].label);

    var current = (try writer.load(testing.allocator)).?;
    defer current.deinit();
    try testing.expectEqual(@as(usize, 1), current.value.selected_project_index);
    try testing.expectEqualStrings("after", current.value.projects[0].label);
}

test "pre-versioning fixture migrates without transcript or ledger loss" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);
    try testCreateLegacyFixture(pref_path);

    var client = try testInitMigrated(testing.allocator, pref_path);
    defer client.deinit();
    try testing.expectEqual(schema.CURRENT_VERSION, try testUserVersion(client.conn));
    try testing.expect(try schema.testHasColumn(client.conn, "threads", "reasoning_variant"));
    try testExpectRowCount(client.conn, "workspaces", 2);
    try testExpectRowCount(client.conn, "threads", 3);
    try testExpectRowCount(client.conn, "messages", 5);
    try testExpectRowCount(client.conn, "surface_completions", 2);
    try testExpectRowCount(client.conn, "chat_completions", 2);
    try testExpectStableId(client.conn, "select id from workspaces where workspace_id = ?1", "workspace-α", 101);
    try testExpectStableId(client.conn, "select id from workspaces where workspace_id = ?1", "workspace-archive", 202);
    try testExpectStableId(client.conn, "select id from threads where local_thread_id = ?1", "thread-active", 1001);
    try testExpectStableId(client.conn, "select id from threads where local_thread_id = ?1", "thread-archived", 1002);
    try testExpectStableId(client.conn, "select id from threads where local_thread_id = ?1", "thread-workspace-archive", 2001);
    try testExpectStableId(client.conn, "select id from messages where body = ?1", "Hello, 世界 👋", 5001);
    try testExpectStableId(client.conn, "select id from messages where body = ?1", "It's persisted — café", 5002);
    try testExpectStableId(client.conn, "select id from messages where body = ?1", "$ printf '✓'", 5003);
    try testExpectStableId(client.conn, "select id from messages where body = ?1", "Archived question ¿qué?", 5004);
    try testExpectStableId(client.conn, "select id from messages where body = ?1", "旧 workspace answer", 5005);
    try testExpectShippedFixtureRoleCodes(client.conn);

    var loaded = (try client.load(testing.allocator)).?;
    defer loaded.deinit();
    try testExpectLegacyFixtureState(loaded.value, null);
    try testExpectDatabaseChecks(client.conn);
}

test "newer schema version is rejected without touching the database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    // Keep this fixture in rollback-journal mode so byte-for-byte comparison remains meaningful.
    {
        const conn = try testOpenDatabase(testing.allocator, pref_path);
        defer conn.close();
        // Derive the future version so schema-chain growth can't stale this fixture.
        try conn.execNoArgs(std.fmt.comptimePrint(
            \\create table future_marker (id integer primary key, value text not null);
            \\insert into future_marker (id, value) values (1, 'future data Ω');
            \\pragma user_version = {d};
        , .{schema.MAX_SUPPORTED_VERSION + 1}));
    }
    const before = try tmp.dir.readFileAlloc(testing.io, STATE_DB_NAME, testing.allocator, .unlimited);
    defer testing.allocator.free(before);

    try testing.expectError(error.DatabaseSchemaTooNew, Client.initReadOnly(testing.allocator, pref_path));
    try testing.expectError(error.DatabaseSchemaTooNew, testInitMigrated(testing.allocator, pref_path));

    const after = try tmp.dir.readFileAlloc(testing.io, STATE_DB_NAME, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);

    const conn = try testOpenDatabase(testing.allocator, pref_path);
    defer conn.close();
    try testing.expectEqual(schema.MAX_SUPPORTED_VERSION + 1, try testUserVersion(conn));
    var marker = (try conn.row("select value from future_marker where id = 1", .{})).?;
    defer marker.deinit();
    try testing.expectEqualStrings("future data Ω", marker.text(0));
    try testing.expect(!try schema.testHasColumn(conn, "future_marker", "reasoning_variant"));
}
